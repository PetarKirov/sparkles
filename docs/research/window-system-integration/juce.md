# JUCE (C++)

The dominant cross-platform C++ framework for audio software: a hand-rolled native-window abstraction (`ComponentPeer`) over Win32, AppKit/Cocoa, and **X11 only** on Linux — with **no Wayland backend** — designed first and foremost to live _inside_ a DAW's message pump as an audio-plugin GUI, and only secondarily to own its own event loop as a standalone app.

| Field             | Value                                                                                                            |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| Version studied   | JUCE `8.0.13` (commit [`3ba67d4`][commit])                                                                       |
| Language          | C++17 (with Objective-C++ on Apple platforms)                                                                    |
| License           | Dual: [AGPLv3] or commercial [JUCE 8 licence][juce-licence]                                                      |
| Repository        | [juce-framework/JUCE]                                                                                            |
| Documentation     | [JUCE API docs][juce-docs] / [JUCE tutorials][juce-tutorials]                                                    |
| Category          | Audio-focused GUI framework (also a full app/DSP/plugin framework)                                               |
| Platforms covered | Windows (Win32), macOS (AppKit), Linux/BSD (**X11 only**), iOS (UIKit), Android                                  |
| Loop ownership    | **Hybrid** — owns the loop as a standalone app; **cedes it to the host** when running as a plugin                |
| Coordinate unit   | Logical pixels (`Component` space); `ComponentPeer` bridges to physical pixels per platform                      |
| Repo paths        | `modules/juce_gui_basics/native/juce_{NSViewComponentPeer_mac.mm,Windowing_windows.cpp,XWindowSystem_linux.cpp}` |

---

## Overview

### What it solves

JUCE is a batteries-included C++ application framework whose centre of gravity is **audio**: synthesizers, effects, DAWs, and — critically — audio _plugins_ (VST3, AU, AAX, LV2) that must render a GUI inside a host process JUCE does not control. The windowing layer's job is to map JUCE's portable `Component` tree onto a real OS window, whether that window is a top-level application window or a child surface handed to it by a host.

The abstraction is `ComponentPeer`. Its header states the contract plainly:

> The Component class uses a ComponentPeer internally to create and manage a real
> operating-system window.
>
> This is an abstract base class - the platform specific code contains implementations of
> it for the various platforms.
>
> User-code should very rarely need to have any involvement with this class.

— [`juce_ComponentPeer.h`][peer-h] (class doc comment, lines 39-46)

Every desktop platform provides one concrete subclass: `NSViewComponentPeer` (macOS, in [`juce_NSViewComponentPeer_mac.mm`][mac-peer]), `HWNDComponentPeer` (Windows, in [`juce_Windowing_windows.cpp`][win-peer]), and `LinuxComponentPeer` (X11, in [`juce_Windowing_linux.cpp`][linux-peer]). `Component::createNewPeer` is the per-platform factory — its body is compiled differently in each native translation unit (e.g. `return new HWNDComponentPeer { … }` at [`juce_Windowing_windows.cpp:4658`][win-peer]).

### Design philosophy

- **One thin C++ virtual interface, N hand-written native backends.** JUCE does not wrap GTK, Qt, or SDL. Each platform's window is built directly against the native API (`CreateWindowEx`, `NSWindow`, `XCreateWindow`), and `ComponentPeer`'s ~50 pure-virtual methods are the seam. This keeps binary dependencies minimal — important for a plugin that must load inside arbitrary hosts.
- **The host may own the loop.** Because a plugin's window is a child of the host's window and the host runs the message pump, JUCE's event-loop code is written to work both ways: as a standalone `[NSApp run]` / `GetMessage` pump, _and_ as a set of FD callbacks or idle hooks the host drives. This duality shapes every loop decision (see [§2](#_2-event-loop)).
- **Logical-pixel `Component` space, physical-pixel peers.** Application code works in resolution-independent logical coordinates; the peer converts to/from physical device pixels using a per-window scale factor. See [logical vs physical coordinates][logical-vs-physical-coords].
- **X11 is the Linux story.** There is no Wayland backend (see [§4](#_4-wayland-specifics)); JUCE on "Wayland" means JUCE under XWayland. Layout itself is out of scope here — see the [UI-layout survey][ui-layout] — except where the scale-factor and coordinate models constrain it.

---

## How it works

### The `ComponentPeer` interface

`ComponentPeer` ([`juce_ComponentPeer.h`][peer-h]) is the whole portable surface of the windowing layer. It carries:

- **A `StyleFlags` bitset** chosen at creation (`windowHasTitleBar`, `windowIsResizable`, `windowAppearsOnTaskbar`, `windowIsTemporary`, `windowIsSemiTransparent`, `windowIgnoresMouseClicks`, …) that each backend translates into native window attributes.
- **Pure-virtual lifecycle/geometry methods** the backend must implement: `setVisible`, `setBounds`, `getBounds`, `setMinimised`, `setFullScreen`, `setAlwaysOnTop`, `toFront`, `toBehind`, `setIcon`, `setAlpha`, `repaint`, `performAnyPendingRepaintsNow`, `getNativeHandle`.
- **Non-virtual `handle*` callbacks** the backend calls _into_ when the OS delivers an event: `handleMouseEvent`, `handleMouseWheel`, `handleKeyPress`, `handleMovedOrResized`, `handlePaint`, `handleUserClosingWindow`, `handleFocusGain/Loss`, `handleDragMove/Exit/Drop`.

```cpp
// modules/juce_gui_basics/windows/juce_ComponentPeer.h  (the native-handle escape hatch)
/** Returns the raw handle to whatever kind of window is being used.

    On windows, this is probably a HWND, on the mac, it's likely to be a WindowRef,
    but remember there's no guarantees what you'll get back.
*/
virtual void* getNativeHandle() const = 0;
```

Two listener interfaces nested in the class are central to JUCE's frame model: `ScaleFactorListener` (DPI changes, see [§5](#_5-dpi-scaling)) and `VBlankListener` (display-refresh callbacks, see [§2](#_2-event-loop)).

### The loop: `MessageManager` + a per-platform queue

A single `MessageManager` ([`juce_MessageManager.h`][mm-h]) owns the notion of "the message thread" and dispatches cross-thread callbacks. The actual pump is per platform:

- **macOS** — `MessageManager::runDispatchLoop` simply calls `[NSApp run]` ([`juce_MessageManager_mac.mm:323`][mac-mm]); a `CFRunLoopSource` ([`juce_MessageQueue_mac.h`][mac-queue]) drains JUCE's own posted-message queue.
- **Windows** — a hidden message-only window receives a custom `WM_USER + 123` wakeup; `dispatchNextMessage` does the classic `GetMessage` / `TranslateMessage` / `DispatchMessage` pump ([`juce_Messaging_windows.cpp:114`][win-msg]).
- **Linux/X11** — a `poll(2)` over a set of file descriptors (a `socketpair` for posted messages plus the X11 connection FD), in `InternalRunLoop` ([`juce_Messaging_linux.cpp:138`][linux-msg]).

The rest of this document walks the ten-dimension spine, citing each backend.

---

## 1. Window creation & lifecycle

**The exact native calls, per platform:**

- **macOS** — `NSViewComponentPeer` allocates an `NSView` then an `NSWindow` via `initWithContentRect:styleMask:backing:defer:`, with `NSBackingStoreBuffered` ([`juce_NSViewComponentPeer_mac.mm:248`][mac-peer-create]). `StyleFlags` map to an `NSWindowStyleMask` in `getNSWindowStyleMask` ([line 1460][mac-stylemask]): `windowHasTitleBar` → `NSWindowStyleMaskTitled`, else `NSWindowStyleMaskBorderless`; `windowIsResizable` → `NSWindowStyleMaskResizable`, etc. When attaching to an existing view (the plugin case, `viewToAttachTo != nil`), it adds itself as a subview instead of creating a window.
- **Windows** — `HWNDComponentPeer` calls `CreateWindowEx` from the message thread ([`juce_Windowing_windows.cpp:2239`][win-create]); the extended style is `WS_EX_APPWINDOW` for taskbar windows or `WS_EX_TOOLWINDOW` for temporary ones. The window class is registered once in `WindowClassHolder` via `RegisterClassEx` ([line 2121][win-regclass]). Transparency uses `WS_EX_LAYERED` (`SetWindowLongPtr … GWL_EXSTYLE`, [line 2446][win-layered]).
- **X11** — `XWindowSystem::createWindow` calls `XCreateWindow` ([`juce_XWindowSystem_linux.cpp:1556`][x11-create]) on a 1×1 rect, then sets WM hints (`XSetWMHints`), class hints, `_NET_WM_*` window-type atoms, and `_MOTIF_WM_HINTS` for decorations. Crucially, `windowIsTemporary` sets `swa.override_redirect = True` — JUCE's mechanism for menus/tooltips (see [override-redirect vs xdg_popup grab][override-redirect-vs-xdg-popup-grab]).

```cpp
// modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp  (createWindow, abridged)
swa.override_redirect = ((styleFlags & ComponentPeer::windowIsTemporary) != 0) ? True : False;
swa.event_mask        = getAllEventsMask (styleFlags & ComponentPeer::windowIgnoresMouseClicks);

auto windowH = X11Symbols::getInstance()->xCreateWindow (display, parentToAddTo != 0 ? parentToAddTo : root,
                                                         0, 0, 1, 1,
                                                         0, visualAndDepth.depth, InputOutput, visualAndDepth.visual,
                                                         CWBorderPixel | CWColormap | CWBackPixmap | CWEventMask | CWOverrideRedirect,
                                                         &swa);
```

**Window-attributes model & silent gaps.** The `StyleFlags` enum is the portable attribute model. Several attributes are explicitly best-effort: the `windowHasDropShadow` doc says it "may not be possible on all platforms"; `windowIgnoresMouseClicks` "may not be possible on some platforms" ([`juce_ComponentPeer.h:75,63`][peer-h]). `setAlwaysOnTop`, `setMinimised`, `setFullScreen` are pure-virtual and may return `false` / no-op where unsupported.

**Initial-frame handling.** X11 and Win32 map the window immediately (X11's `_NET_WM` mapping; Win32's `CreateWindowEx`), so there is no [no-buffer-no-window][no-buffer-no-window] constraint — that is a Wayland property JUCE never has to satisfy because it has no Wayland backend. On X11, the window is created 1×1 and resized afterward; the frame (border) size is unknown for a short transient, which is why `getFrameSizeIfPresent` returns an `OptionalBorderSize` whose doc warns: "A missing value may be returned on Linux for a short time after window creation" ([`juce_ComponentPeer.h:97`][peer-h]).

**Surface/handle exposure for rendering.** `getNativeHandle` returns the `HWND`, `NSView*`, or X11 `Window` ID (Linux: `reinterpret_cast<void*> (getWindowHandle())`, [`juce_Windowing_linux.cpp:95`][linux-native-handle]). On Windows, JUCE 8 added a Direct2D rendering backend (`D2DRenderContext`, [`juce_Windowing_windows.cpp:5013`][win-d2d]) alongside the legacy GDI path; `getAvailableRenderingEngines` reports `"GDI"` and `"Direct2D"`. On macOS the view is layer-backed and can drive a Metal layer (`CoreGraphicsMetalLayerRenderer`, [`juce_NSViewComponentPeer_mac.mm:218`][mac-peer-create]).

**Destruction-ordering hazards.** Both `LinuxComponentPeer`'s constructor and destructor assert `JUCE_ASSERT_MESSAGE_MANAGER_IS_LOCKED` with the comment "it's dangerous to create/delete a window on a thread other than the message thread" ([`juce_Windowing_linux.cpp:46,74`][linux-peer]). On macOS the window is created with `setReleasedWhenClosed: YES` _and_ explicitly retained, with a code comment explaining the dance: "plugin hosts can unexpectedly close the window for us, and also tend to … cause trouble if setReleasedWhenClosed is NO" ([`juce_NSViewComponentPeer_mac.mm:274`][mac-peer-create]) — a destruction-ordering hazard born directly from the plugin-embedding use case.

---

## 2. Event loop

> [!IMPORTANT]
> **Who owns the loop is the defining JUCE windowing question.** As a _standalone app_ JUCE owns the loop (`[NSApp run]`, `GetMessage`, or `poll`). As a _plugin_ the host owns it, and JUCE integrates as a guest. The Linux backend's source documents this split most explicitly.

**Standalone-app loop, per platform:**

- **macOS** — `runDispatchLoop` calls `[NSApp run]`, so AppKit's `CFRunLoop` _is_ the loop. JUCE's own posted messages are delivered through a `CFRunLoopSource` whose `perform` callback drains the queue; `wakeUp` does `CFRunLoopSourceSignal` + `CFRunLoopWakeUp` ([`juce_MessageQueue_mac.h:76`][mac-queue]).
- **Windows** — a message-only `HiddenMessageWindow` is the wakeup target. `postMessage` posts a `WM_USER + 123` to it (or `SendNotifyMessage` under Unity); the pump translates/dispatches all messages and routes the custom message to `dispatchMessages` ([`juce_Messaging_windows.cpp:91,128`][win-msg]).
- **Linux/X11** — `InternalRunLoop` keeps a sorted `std::vector<pollfd>` of registered FDs and `poll`s them; the message queue is a `socketpair` (`AF_LOCAL, SOCK_STREAM`) whose read end is registered as an FD callback ([`juce_Messaging_linux.cpp:44`][linux-msg]). `dispatchNextMessageOnSystemQueue` calls `runLoop->dispatchPendingEvents()` then `sleepUntilNextEvent(2000)`.

```cpp
// modules/juce_events/native/juce_Messaging_linux.cpp  (the poll-based core)
bool sleepUntilNextEvent (int timeoutMs)
{
    const ScopedLock sl (lock);
    return poll (pfds.data(), static_cast<nfds_t> (pfds.size()), timeoutMs) != 0;
}
```

**Plugin-host integration (the loop JUCE does NOT own).** The Linux event-loop file carries an unusually candid block comment describing how JUCE rides each plugin format's host loop — this is the clearest statement in the tree of JUCE's loop-cession stance:

> For plugins, the host (generally) provides some kind of run loop mechanism instead.
>
> - In VST2 plugins, the host should call effEditIdle at regular intervals, and plugins can dispatch all pending events inside this callback. …
> - In VST3 plugins, it's possible to register each FD individually with the host. … the host can be notified whenever the set of FDs changes. The host will call onFDIsSet whenever a particular FD has data ready.

— [`juce_Messaging_linux.cpp:126-136`][linux-msg]

That second path is exposed as `LinuxEventLoopInternal` (`registerLinuxEventLoopListener`, `invokeEventLoopCallbackForFd`), so the VST3 wrapper can hand the host JUCE's FD set and forward the host's readiness notifications back into `InternalRunLoop::dispatchEvent`. This is a **readiness-style** integration with the host (see [readiness vs completion for windowing][readiness-vs-completion-windowing]).

**Win32 modal resize/move loop.** Windows enters a [modal resize/move loop][win32-modal-resize-loop] inside `DefWindowProc` on `WM_ENTERSIZEMOVE` and exits on `WM_EXITSIZEMOVE`; JUCE tracks this with a `sizing` flag and special-cases `WM_WINDOWPOSCHANGING` while sizing ([`juce_Windowing_windows.cpp:3899-3918`][win-sizemove]). During this nested loop the host's normal pump is blocked — a long-standing source of plugin redraw stalls.

**Timers, wakeups, user-event injection.** Cross-thread work is posted via `MessageManager::callAsync` / `postMessageToSystemQueue`. From another thread the wakeup is: signal the `CFRunLoopSource` (mac), `PostMessage` to the hidden window (Win32), or `write` one byte to the `socketpair` (Linux). `MessageManager::callFunctionOnMessageThread` and the `MessageManagerLock` (see [§7](#_7-threading)) marshal arbitrary callables onto the message thread.

**Frame pacing & vsync.** JUCE drives repaints from a `VBlankListener` callback, with a different vsync source per platform:

| Platform  | VSync source                 | Mechanism                                                                                                                                                                                  |
| --------- | ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| macOS     | `CVDisplayLink` (per screen) | `PerScreenDisplayLinks` creates one `CVDisplayLinkRef` per `CGDisplay` ([`juce_PerScreenDisplayLinks_mac.h:63`][mac-vblank])                                                               |
| Windows   | `IDXGIOutput::WaitForVBlank` | a dedicated highest-priority `VBlankThread` blocks on `WaitForVBlank`, then `triggerAsyncUpdate` marshals the callback to the message thread ([`juce_VBlank_windows.cpp:116`][win-vblank]) |
| Linux/X11 | **a timer at refresh rate**  | no true vblank; a `TimedCallback` fires `onVBlank` ([`juce_Windowing_linux.cpp:635`][linux-vblank])                                                                                        |

The `VBlankListener` doc itself admits the Linux limitation: "On Linux this is currently limited to receiving callbacks from a timer approximately at display refresh rate" ([`juce_ComponentPeer.h:526`][peer-h]). See [frame-callback / vsync][frame-callback-vsync]. Repaints are coalesced: `repaint` only invalidates a region; the actual paint happens on the next vblank tick via `performAnyPendingRepaintsNow`.

> [!NOTE]
> Audio-specific consequence: because plugin GUIs run inside a host pump JUCE cannot pace, JUCE leans on its _own_ vblank thread/displaylink rather than the host's frame timing, decoupling GUI redraw from the host loop. The Windows `VBlankThread` running at `Priority::highest` is a deliberate latency choice.

---

## 3. Input

**Keyboard model.** JUCE normalises everything to a single `KeyPress` carrying a portable key code plus a Unicode `juce_wchar` text character — it does not expose raw scancodes to application code (contrast [scancode / keysym / virtual-key][scancode-keysym-virtualkey]). The translation differs sharply by platform:

- **X11** — `handleKeyPressEvent` calls the legacy `XLookupString` (after a `setlocale` dance) for the text byte, and falls back to `XkbKeycodeToKeysym` for control keys, then hand-maps keypad and function keys ([`juce_XWindowSystem_linux.cpp:3449-3539`][x11-key]). It does **not** use `xkbcommon` for a full layout state machine, nor `XmbLookupString`/`XIM`.
- **Windows** — `WM_KEYDOWN`/`WM_SYSKEYDOWN` → `doKeyDown`; text arrives separately via `WM_CHAR` → `doKeyChar` ([`juce_Windowing_windows.cpp:3935-3953`][win-key]). This is the standard Win32 virtual-key + `TranslateMessage` split.
- **macOS** — key events go through AppKit's `interpretKeyEvents:` so the `NSTextInputClient` protocol produces text; raw key codes come from the `NSEvent`.

**Key repeat.** On X11, JUCE detects synthetic auto-repeat by **peeking the next event**: a key-release immediately followed by a key-press with the _same keycode and timestamp_ is treated as auto-repeat and suppressed ([`juce_XWindowSystem_linux.cpp:3557-3571`][x11-key]). (This is the X11 analogue of the Wayland design where the client must synthesize repeat itself.)

**Dead keys / compose.** Handled implicitly by `XLookupString` (X11), `WM_CHAR` (Win32), and `interpretKeyEvents:` (macOS); JUCE adds no compose machinery of its own.

**IME / text input** (studied closely — see [pre-edit / composition][pre-edit-composition]):

- **macOS** — full `NSTextInputClient` implementation. The view declares `@protocol(NSTextInputClient)` ([`juce_NSViewComponentPeer_mac.mm:2663`][mac-ime]) and implements `setMarkedText:selectedRange:replacementRange:`, `insertText:replacementRange:`, `unmarkText`, `hasMarkedText`, and `firstRectForCharacterRange:actualRange:` for candidate-window positioning. Composition state is tracked in `stringBeingComposed` / `startOfMarkedTextInTextInputTarget`, with explicit handling for the Korean IME's "three calls to setMarkedText: followed by a call to insertText:" pattern ([line 2415][mac-ime]).
- **Windows** — **legacy IMM32, not TSF.** `WM_IME_STARTCOMPOSITION` / `WM_IME_COMPOSITION` / `WM_IME_ENDCOMPOSITION` are handled via an `IMEHandler` using `ImmGetContext`, `ImmGetCompositionString` (`GCS_COMPSTR`, `GCS_CURSORPOS`, `GCS_COMPATTR`, `GCS_COMPCLAUSE`), and `ImmSetCompositionWindow` for candidate positioning ([`juce_Windowing_windows.cpp:4207-4505`][win-ime]). There is no Text Services Framework (`ITfThreadMgr`) path.
- **X11** — **effectively none.** Because text comes only from `XLookupString` with no `XIM`/`XmbLookupString`/`zwp_text_input` integration, composition-based input methods (CJK, etc.) are not supported on JUCE's X11 backend. This is a real gap, recorded as a finding rather than glossed.

> [!WARNING]
> JUCE's X11 backend has no input-method (IME) support: `XLookupString` returns only direct Latin-1/UTF-8 bytes, with no `XIM` context. CJK/Indic composition does not work on Linux/X11 the way it does on macOS (`NSTextInputClient`) and Windows (IMM32).

**Pointer.** Absolute motion is the norm; JUCE delivers `handleMouseEvent` with a position in peer coordinates. High-resolution scroll handling is platform-specific:

- **Windows** — `doMouseWheel` takes the raw `HIWORD(wParam)` (`WHEEL_DELTA` units), scales by `0.5/256`, and does **not** accumulate sub-`WHEEL_DELTA` fractions across messages ([`juce_Windowing_windows.cpp:2748`][win-wheel]).
- **macOS** — honours precise/momentum scroll: `wheel.isInertial = ([ev momentumPhase] != NSEventPhaseNone)` and `hasPreciseScrollingDeltas` selects the smooth path (`isSmooth = true`) ([`juce_NSViewComponentPeer_mac.mm:810-819`][mac-wheel]). This is JUCE's richest scroll path.
- **X11** — wheel arrives as button-press events (buttons 4–7) converted to a fixed `deltaY` amount ([`juce_XWindowSystem_linux.cpp:3594`][x11-key]); no high-resolution axis. See [raw vs accelerated pointer][raw-vs-accelerated-pointer].

**Touch & gestures.** Windows handles `WM_TOUCH` and the newer `WM_POINTER*` family, plus `GID_ZOOM` magnify gestures via `doGestureEvent` → `handleMagnifyGesture` ([`juce_Windowing_windows.cpp:2769`][win-wheel]). macOS forwards magnify gestures similarly. X11 has no native multi-touch path. A `MultiTouchMapper` ([`native/juce_MultiTouchMapper.h`][multitouch]) assigns stable touch indices.

**Cursor.** Client-driven: X11 calls `showCursor` with an X cursor on the native window ([`juce_Windowing_linux.cpp:831`][linux-cursor]); there is no `cursor_shape_v1` because there is no Wayland backend.

---

## 4. Wayland specifics

> [!IMPORTANT]
> **JUCE has no Wayland backend.** A repository-wide search for `wayland` in `modules/` returns exactly two hits, _neither_ in JUCE's own windowing code: one in `juce_WebBrowserComponent_linux.cpp` (a WebKitGTK detail), and one in the bundled VST3 SDK header `iplugview.h` (`kPlatformTypeWaylandSurfaceID`, for hosts that pass a Wayland surface to a plugin). JUCE's Linux/BSD windowing is implemented entirely against **Xlib** in `juce_XWindowSystem_linux.cpp`.

Consequences for every Wayland sub-question:

- **Decorations** — N/A in the Wayland sense. On X11, JUCE chooses **server-side decorations** by default (it sets `_MOTIF_WM_HINTS` and `_NET_WM` window-type/allowed-actions atoms, [`juce_XWindowSystem_linux.cpp:2946-3041`][x11-create]); for borderless windows it removes decorations via `_MOTIF_WM_HINTS`. There is no `libdecor`, no client-side-decoration fallback, and no `xdg-decoration` negotiation. See [client vs server decoration][client-vs-server-decoration] and [CSD vs SSD][csd-vs-ssd].
- **Protocol coverage** (`fractional-scale-v1`, `viewporter`, `xdg-activation`, `idle-inhibit`, `layer-shell`) — **none**, because there is no Wayland code at all. Layer-shell-style "always on top" is done on X11 via `_NET_WM_STATE` atoms instead.
- **Compositor-specific workarounds** — JUCE works under Wayland only through **XWayland**, inheriting XWayland's limitations (no per-surface fractional scale, integer-only `_XSETTINGS` scaling, legacy clipboard). There are no `mutter`/`kwin`/`sway`-specific code paths.

Running a JUCE app on a Wayland desktop therefore means: X11 client → XWayland → compositor. Native Wayland support has been a long-standing community request (see [§10](#_10-history-redesigns-known-regrets)).

---

## 5. DPI & scaling

**Scale-factor model.** Application code lives in **logical pixels** (`Component` coordinates). The peer holds a `getPlatformScaleFactor()` and converts to physical pixels at the OS boundary. The `setBounds` doc spells out the conversion with a worked example: a logical `{10,20,30,40}` at scale 1.5 becomes physical `{15,30,45,60}` ([`juce_ComponentPeer.h:199`][peer-h]). See [scale factor][scale-factor] and [logical vs physical coords][logical-vs-physical-coords].

**Windows — per-monitor v2.** At startup JUCE tries, in order: `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`, then `SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE)`, then system-aware ([`juce_Windowing_windows.cpp:349-359`][win-dpi]). Per-window DPI changes arrive as [`WM_DPICHANGED`][win32-modal-resize-loop] → `handleDPIChanging`, which recomputes `scaleFactor = newDPI / USER_DEFAULT_SCREEN_DPI`, repositions the window to the OS-suggested rect, guards against re-entrancy, and notifies `ScaleFactorListener`s ([`juce_Windowing_windows.cpp:3398`][win-dpichanging]). A `ScopedThreadDPIAwarenessSetter` lets specific code run in a chosen awareness context (e.g. plugin wrappers).

```cpp
// modules/juce_gui_basics/native/juce_Windowing_windows.cpp  (handleDPIChanging, abridged)
LRESULT handleDPIChanging (int newDPI, RECT newRect)
{
    const auto newScale = (double) newDPI / USER_DEFAULT_SCREEN_DPI;
    if (approximatelyEqual (scaleFactor, newScale))
        return 0;
    scaleFactor = newScale;
    SetWindowPos (hwnd, nullptr, newRect.left, newRect.top,
                  newRect.right - newRect.left, newRect.bottom - newRect.top,
                  SWP_NOZORDER | SWP_NOACTIVATE);
    scaleFactorListeners.call ([this] (ScaleFactorListener& l) { l.nativeScaleFactorChanged (scaleFactor); });
    return 0;
}
```

**macOS — backing scale.** The window uses `[NSScreen backingScaleFactor]`; coordinates are AppKit points (logical), so JUCE largely defers to AppKit's HiDPI model. `getPlatformScaleFactor()` returns `1.0` on macOS by default (the `NSView` layer handles the backing-store scale).

**Linux/X11 — integer-only, scraped from settings.** `DisplayHelpers::getDisplayScale` reads `_XSETTINGS` (`Gdk/WindowScalingFactor`), and if absent will literally **shell out to `dconf`** to read Ubuntu's `/com/ubuntu/user-interface/scale-factor` ([`juce_XWindowSystem_linux.cpp:1145`][x11-scale]). The XSETTINGS value is an _integer_ scale, so X11 cannot express fractional scaling — and there is no `wp-fractional-scale-v1` because there is no Wayland backend.

**The "created-at-wrong-scale-then-rescaled" problem.** On Windows this is handled by `WM_DPICHANGED` after creation; on X11, `updateScaleFactorFromNewBounds` recomputes the scale whenever the window moves between monitors ([`juce_Windowing_linux.cpp:111`][linux-peer]). Window migration between monitors thus triggers a scale-factor listener notification on Windows and Linux; macOS handles it inside AppKit.

---

## 6. Multi-window & popups

**Menus, tooltips, temporary windows.** The `windowIsTemporary` style flag drives popup behaviour. On X11 it sets `override_redirect = True` ([§1](#_1-window-creation-lifecycle)), bypassing the window manager entirely — the classic X11 menu/tooltip technique (see [override-redirect vs xdg_popup grab][override-redirect-vs-xdg-popup-grab]). On Windows temporary windows become `WS_EX_TOOLWINDOW`, excluded from the taskbar; on macOS they get `setExcludedFromWindowsMenu: YES`.

**Modal dialogs.** JUCE runs modal loops via `Component::runModalLoop` / `MessageManager::runDispatchLoopUntil` (guarded by `JUCE_MODAL_LOOPS_PERMITTED`). On macOS `runDispatchLoopUntil` spins `CFRunLoopRunInMode` plus `[NSApp nextEventMatchingMask:]`, filtering events blocked by modal components ([`juce_MessageManager_mac.mm:379`][mac-mm]). Because plugins generally must _not_ block the host, modal loops are frequently disabled in plugin builds — JUCE instead uses async (`enterModalState` with a callback).

**Parent/child stacking & groups.** `toFront`, `toBehind(ComponentPeer*)`, and `setAlwaysOnTop` give portable stacking control; each backend maps to native restacking (`orderWindow:` on macOS, `SetWindowPos` on Win32, `_NET_WM_STATE_ABOVE` / `XRaiseWindow` on X11). JUCE tracks the count of always-on-top peers (`numAlwaysOnTopPeers`) to coordinate stacking.

---

## 7. Threading

> [!IMPORTANT]
> JUCE has a single **message thread** (the thread that ran `MessageManager`). Windows must be created on it, and all UI events are delivered on it. The constraint is driven by macOS — AppKit is main-thread-only — but JUCE enforces it uniformly across platforms.

- **Window creation must be on the message thread.** `LinuxComponentPeer`'s ctor/dtor assert `JUCE_ASSERT_MESSAGE_MANAGER_IS_LOCKED` with the "dangerous to create a window on a thread other than the message thread" comment ([`juce_Windowing_linux.cpp:46`][linux-peer]). On Windows, `CreateWindowEx` is explicitly marshalled to the message thread (`createWindowOnMessageThread`, [`juce_Windowing_windows.cpp:2222`][win-create]).
- **Events are delivered on the message thread.** All `ComponentPeer::handle*` callbacks fire there.
- **Off-thread rendering.** Background threads must take a `MessageManagerLock` before touching components. JUCE's `OpenGLContext` and the Windows `VBlankThread` do their blocking work off-thread but marshal the actual paint/notify back via `triggerAsyncUpdate` / the message queue ([`juce_VBlank_windows.cpp:144`][win-vblank]). The macOS Metal/CoreGraphics layer renders asynchronously (`drawsAsynchronously = YES`, [`juce_NSViewComponentPeer_mac.mm:227`][mac-peer-create]) but is still set up on the main thread.
- **`MessageManager::getInstance()->isThisTheMessageThread()`** is the canonical guard; `callAsync` / `callFunctionOnMessageThread` / `MessageManagerLock` are the marshalling primitives ([`juce_MessageManager.h`][mm-h]).

The per-platform constraint that forced this model is, as elsewhere, **macOS main-thread AppKit** — the `getNativeRealtimeModifiers` lambda, window creation, and `[NSApp run]` all assume the main thread.

---

## 8. Clipboard & DnD

**macOS** — `SystemClipboard` writes to `[NSPasteboard generalPasteboard]` with `NSPasteboardTypeString` ([`juce_Windowing_mac.mm:642`][mac-clip]). Drag sources use `NSDraggingSource` / `NSPasteboardItemDataProvider`, providing data lazily on request ([`juce_Windowing_mac.mm:65`][mac-clip]) — the Cocoa form of delayed rendering.

**Windows** — `OpenClipboard` / `SetClipboardData(CF_UNICODETEXT, …)` / `GetClipboardData(CF_UNICODETEXT)` ([`juce_Windowing_windows.cpp:5683-5714`][win-clip]). Drag-and-drop uses OLE (`OleInitialize`, an `IDropTarget` / `FileDropTarget`, with `DroppedData` reading `CF_UNICODETEXT` / `CF_HDROP`, [line 1888][win-drop]). JUCE's clipboard path uses immediate (not delayed) rendering for text.

**X11 — selections, but no INCR.** JUCE owns the `PRIMARY` and `CLIPBOARD` selections via `XSetSelectionOwner`, answers `SelectionRequest` events in `handleSelection`, and on paste tries `CLIPBOARD` first then `PRIMARY` ([`juce_XWindowSystem_linux.cpp:1367,2820-2834`][x11-clip]). Large transfers via the `INCR` protocol are **deliberately not implemented**, capped at ~1 MB, with a candid source comment:

> for very big chunks of data, we should use the "INCR" protocol , which is a pain in the \*ss

— [`juce_XWindowSystem_linux.cpp:1425`][x11-clip]

So on X11, clipboard payloads over `maxReasonableSelectionSize` (1,000,000 items) silently fail to transfer. See the X11 selection model and the contrast with the Wayland `wl_data_device` selection model.

---

## 9. Escape hatches

JUCE's abstraction leaks deliberately at well-known points:

- **`ComponentPeer::getNativeHandle()`** — returns the raw `HWND` / `NSView*` / X11 `Window` ([§1](#_1-window-creation-lifecycle)). The doc warns "there's no guarantees what you'll get back" ([`juce_ComponentPeer.h:164`][peer-h]).
- **`getAvailableRenderingEngines` / `setCurrentRenderingEngine`** — pick GDI vs Direct2D on Windows, or the software/CoreGraphics/Metal path ([`juce_Windowing_windows.cpp:2471`][win-d2d]).
- **`LinuxEventLoop` / `LinuxEventLoopInternal`** — register arbitrary FD callbacks into JUCE's `poll` loop, _and_ let a VST3 host observe JUCE's FD set and pump it ([`juce_Messaging_linux.cpp:365-394`][linux-msg]). This is the deepest escape hatch — the entire plugin-in-host loop model rides on it.
- **`setCustomPlatformScaleFactor`** — overrides the OS-reported scale, explicitly "intended for use by plugin wrappers, where hosts may attempt to set a scale factor different from the platform scale" ([`juce_ComponentPeer.h:561`][peer-h]).
- **`startHostManagedResize`** — on X11 sends a `_NET_WM_MOVERESIZE` client message to let the WM drive interactive resize ([`juce_XWindowSystem_linux.cpp:1807`][x11-resize]); a no-op elsewhere.
- **`addToDesktop(flags, nativeWindowToAttachTo)`** — the entry point a host uses to parent JUCE's window into the host's `HWND`/`NSView`/`Window`.

These hatches cluster around plugin embedding and DPI/scale — exactly where the portable abstraction is known to leak.

---

## 10. History, redesigns & known regrets

- **`ComponentPeer` evolution.** The path itself drifted: the header lives at `modules/juce_gui_basics/windows/juce_ComponentPeer.h` (not the `components/` path one might expect). `getFrameSize()` is now `[[deprecated]]` on Linux/BSD in favour of the `OptionalBorderSize`-returning `getFrameSizeIfPresent()` ([`juce_ComponentPeer.h:330`][peer-h]) — a redesign forced by X11's transient "frame size unknown after creation" window.
- **Plugin-embedding constraints on the loop.** The VST2-vs-VST3 idle/FD comment in [`juce_Messaging_linux.cpp`][linux-msg] is effectively a design note: VST2 hosts only offer a periodic `effEditIdle`, giving "a bit of latency between an FD becoming ready, and its associated callback being called," whereas VST3's per-FD registration is JUCE's preferred integration. This latency is an acknowledged regret of the plugin loop model.
- **GPU / Direct2D rendering.** JUCE 8 introduced the `Direct2D` rendering backend on Windows (`D2DRenderContext`, `juce_Direct2DHwndContext_windows.cpp`) alongside legacy GDI — the largest recent change touching the windowing/presentation seam. See the [JUCE 8 announcement][juce8-blog].
- **No Wayland backend** is the longest-standing open windowing gap. Native Wayland support has been requested for years on the JUCE forum ([JUCE forum: Wayland support][juce-wayland-forum]) and is visible in open issues such as [#549 "DemoRunner not showing on debian buster (wayland)"][juce-issue-549] (opened 2019, still open) and more recent Wayland-only regressions like [#1481 (un-editable labels in CalloutBox on Wayland)][juce-issue-1481]; JUCE 8 still ships X11-only and runs under Wayland via XWayland. This is the single biggest "known regret" of the Linux windowing layer.
- **X11 IME and INCR gaps** ([§3](#_3-input), [§8](#_8-clipboard-dnd)) are documented in-source as deliberate omissions ("a pain in the \*ss") rather than bugs — cheap lessons that a from-scratch Linux backend should not repeat.

---

## Strengths

- **One small virtual interface, total control.** `ComponentPeer` is ~50 methods; each backend is hand-written against the native API, so JUCE carries no GTK/Qt runtime dependency — ideal for plugins loaded into arbitrary hosts.
- **First-class plugin-in-host loop model.** The dual standalone/guest loop, FD-registration with VST3 hosts, and `setCustomPlatformScaleFactor` make JUCE unusually good at _not_ owning the loop — a rare and well-executed design point.
- **Decoupled frame pacing.** Per-screen `CVDisplayLink` (mac) and a dedicated `WaitForVBlank` thread (Windows) give smooth, host-independent redraw — important when the host's pump is unpredictable.
- **Mature IME on the platforms that matter for desktop.** Full `NSTextInputClient` (mac) and IMM32 (Windows) composition support.
- **Clean native escape hatches** for the cases the abstraction can't cover.

## Weaknesses

- **No Wayland backend.** Linux is X11-only; everything Wayland (fractional scale, per-surface scale, modern clipboard, idle-inhibit, layer-shell) is unavailable, and Wayland users run through XWayland.
- **Weak X11 backend overall.** No IME (`XLookupString` only, no `XIM`/`xkbcommon` state machine), no `INCR` clipboard (≈1 MB cap), integer-only DPI (even shelling out to `dconf`), timer-based "vblank."
- **Windows uses legacy IMM32, not TSF.** Misses some modern text-services features.
- **Modal-loop friction in plugins.** The Win32 `WM_ENTERSIZEMOVE` nested loop and JUCE's own modal loops block the host pump; plugins must avoid them.
- **`getNativeHandle` is type-erased `void*`** — no `raw-window-handle`-style typed handle; callers must know the platform.

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                             | Trade-off                                                                                        |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| One `ComponentPeer` virtual interface, hand-written native backends        | No external GUI-toolkit dependency; works inside any plugin host                      | Every platform feature must be re-implemented by hand; backends drift in completeness (X11 lags) |
| Hybrid loop ownership (own it standalone, cede it to the host as a plugin) | Plugins cannot own the host's message pump                                            | Two code paths; host-loop latency (VST2 `effEditIdle`); modal loops disabled in plugins          |
| Logical-pixel `Component` space, physical-pixel peers                      | Resolution-independent app code                                                       | Per-platform scale conversion; X11 integer-only scaling can't express fractional DPI             |
| X11-only on Linux (no Wayland)                                             | X11 is universal via XWayland; Wayland's per-compositor variance is costly to support | No fractional scale, modern clipboard, IME, or SSD negotiation on Wayland                        |
| Dedicated vblank thread / `CVDisplayLink` for frame pacing                 | Smooth redraw independent of an unpredictable host pump                               | Extra thread (Windows at `Priority::highest`); Linux degrades to a refresh-rate timer            |
| Legacy IMM32 on Windows, `NSTextInputClient` on mac, nothing on X11        | IMM32/Cocoa cover the common desktop IME need with least code                         | No TSF features; CJK input simply does not work on Linux/X11                                     |
| `getNativeHandle()` returns `void*`                                        | Universal, dependency-free escape hatch                                               | Untyped; callers must cast and know the platform                                                 |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **plugin-in-host loop model** — separating "own the loop" from "ride the host's readiness notifications," and exposing FD registration to the host (the `LinuxEventLoopInternal` pattern). Any framework that must embed in foreign processes should copy this.
- **Frame pacing decoupled from the message loop** via a display-link/vblank source feeding a coalesced repaint — robust against hosts you can't pace.
- **`setCustomPlatformScaleFactor`**: letting an embedder override the OS scale is a pragmatic answer to host/plugin DPI mismatch.
- The honest **`OptionalBorderSize`** acknowledgement that frame geometry is unknown for a transient after creation.

**Avoid:**

- **Shipping no Wayland backend in 2025.** A new Linux backend should target Wayland-first (with `xdg-shell`, `wp-fractional-scale-v1`, `wp-viewporter`, `zwp_text_input_v3`) and treat X11 as the legacy path — the inverse of JUCE's current stance.
- **Skipping IME and `INCR`** because they are tedious. JUCE's own comments ("a pain in the \*ss") mark exactly the corners a real backend cannot cut.
- **Integer-only DPI** and **scraping `dconf`** for scale — use the compositor's fractional-scale protocol instead.
- **Type-erased `void*` native handles** — prefer a typed, `raw-window-handle`-style accessor.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Is a native Wayland backend on JUCE's roadmap?** Not in the `8.0.13` tree. The answer would surface in the [JUCE forum Wayland thread][juce-wayland-forum] and the [JUCE GitHub issues][juce-issues].
- **Exact redraw-coalescing policy under a stalled host pump** (e.g. during a Win32 modal resize). The `VBlankThread`/`performAnyPendingRepaintsNow` interaction is visible in [`juce_VBlank_windows.cpp`][win-vblank] and the `HWNDComponentPeer` paint path, but the precise drop/merge behaviour for missed frames would need a runtime trace.
- **Whether the Direct2D backend uses a DXGI _waitable_ swapchain** for present pacing. The setup is in `juce_Direct2DHwndContext_windows.cpp` (not fully read here); that file is where flip-model/`SetMaximumFrameLatency` details would live.
- **macOS `getPlatformScaleFactor()` returning 1.0** — confirmed JUCE defers backing-scale to AppKit, but the exact point where physical-pixel sizes are chosen for the Metal layer is spread across the layer-delegate path in [`juce_NSViewComponentPeer_mac.mm`][mac-peer] and `juce_CGMetalLayerRenderer_mac.h`.

---

## Sources

- [juce-framework/JUCE] @ [`3ba67d4`][commit] — source for all quoted file paths (JUCE `8.0.13`)
- [`juce_ComponentPeer.h`][peer-h] — the portable windowing interface, `StyleFlags`, `VBlankListener`, `ScaleFactorListener`
- [`juce_NSViewComponentPeer_mac.mm`][mac-peer] — macOS/AppKit backend (`NSWindow`, `NSTextInputClient`, scroll momentum)
- [`juce_Windowing_windows.cpp`][win-peer] — Win32 backend (`CreateWindowEx`, IMM32 IME, `WM_DPICHANGED`, Direct2D)
- [`juce_XWindowSystem_linux.cpp`][x11-create] — X11 backend (`XCreateWindow`, `XLookupString`, selections, `_NET_WM_MOVERESIZE`)
- [`juce_Messaging_linux.cpp`][linux-msg] — Linux `poll` loop and the VST2/VST3 host-loop integration comment
- [`juce_MessageManager_mac.mm`][mac-mm] / [`juce_MessageQueue_mac.h`][mac-queue] — macOS `CFRunLoop` integration
- [`juce_VBlank_windows.cpp`][win-vblank] / [`juce_PerScreenDisplayLinks_mac.h`][mac-vblank] — frame-pacing sources
- [JUCE 8 announcement][juce8-blog] — Direct2D rendering and other 8.0 changes
- [JUCE forum: Wayland support][juce-wayland-forum] and issues [#549][juce-issue-549] / [#1481][juce-issue-1481] — the standing Linux/Wayland gap
- Shared vocabulary: [concepts]. Sibling surveys: [UI layout][ui-layout], [async-io event loops][async-io]

<!-- References -->

[commit]: https://github.com/juce-framework/JUCE/commit/3ba67d4585e9d1fbcdb26a877c7978608b1f802e
[juce-framework/JUCE]: https://github.com/juce-framework/JUCE
[juce-docs]: https://docs.juce.com/master/index.html
[juce-tutorials]: https://juce.com/learn/tutorials/
[AGPLv3]: https://spdx.org/licenses/AGPL-3.0-only.html
[juce-licence]: https://juce.com/legal/juce-8-licence/
[juce8-blog]: https://juce.com/blog/juce-8-feature-overview-direct2d-rendering-on-windows/
[juce-wayland-forum]: https://forum.juce.com/t/wayland-support/12591
[juce-issue-549]: https://github.com/juce-framework/JUCE/issues/549
[juce-issue-1481]: https://github.com/juce-framework/JUCE/issues/1481
[juce-issues]: https://github.com/juce-framework/JUCE/issues
[peer-h]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/windows/juce_ComponentPeer.h
[mac-peer]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_NSViewComponentPeer_mac.mm
[mac-peer-create]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_NSViewComponentPeer_mac.mm#L184
[mac-stylemask]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_NSViewComponentPeer_mac.mm#L1460
[mac-ime]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_NSViewComponentPeer_mac.mm#L2396
[mac-wheel]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_NSViewComponentPeer_mac.mm#L794
[win-peer]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp
[win-create]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L2222
[win-regclass]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L2121
[win-layered]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L2446
[win-sizemove]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L3899
[win-dpi]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L349
[win-dpichanging]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L3398
[win-key]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L3935
[win-ime]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L4207
[win-wheel]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L2748
[win-d2d]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L5013
[win-clip]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L5683
[win-drop]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_windows.cpp#L1888
[win-vblank]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_VBlank_windows.cpp
[win-msg]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_events/native/juce_Messaging_windows.cpp
[linux-peer]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_linux.cpp
[linux-native-handle]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_linux.cpp#L95
[linux-vblank]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_linux.cpp#L635
[linux-cursor]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_linux.cpp#L831
[linux-msg]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_events/native/juce_Messaging_linux.cpp
[x11-create]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp#L1528
[x11-key]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp#L3440
[x11-clip]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp#L1366
[x11-scale]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp#L1145
[x11-resize]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_XWindowSystem_linux.cpp#L1807
[mac-mm]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_events/native/juce_MessageManager_mac.mm#L323
[mac-queue]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_events/native/juce_MessageQueue_mac.h
[mac-vblank]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_PerScreenDisplayLinks_mac.h
[mac-clip]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_Windowing_mac.mm#L65
[mm-h]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_events/messages/juce_MessageManager.h
[multitouch]: https://github.com/juce-framework/JUCE/blob/3ba67d4585e9d1fbcdb26a877c7978608b1f802e/modules/juce_gui_basics/native/juce_MultiTouchMapper.h
[csd-vs-ssd]: ./concepts.md#csd-vs-ssd
[scancode-keysym-virtualkey]: ./concepts.md#scancode-keysym-virtualkey
[logical-vs-physical-coords]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pre-edit-composition]: ./concepts.md#pre-edit-composition
[override-redirect-vs-xdg-popup-grab]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal-resize-loop]: ./concepts.md#win32-modal-resize-loop
[raw-vs-accelerated-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer-no-window]: ./concepts.md#no-buffer-no-window
[frame-callback-vsync]: ./concepts.md#frame-callback-vsync
[readiness-vs-completion-windowing]: ./concepts.md#readiness-vs-completion-windowing
[client-vs-server-decoration]: ./concepts.md#client-vs-server-decoration
[concepts]: ./concepts.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
