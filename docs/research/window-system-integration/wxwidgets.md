# wxWidgets (C++)

A mature C++ framework that implements its windowing layer by **wrapping the platform's native toolkit** — Win32 directly on Windows, AppKit/Cocoa on macOS, and (the decisive twist) **GTK on Linux** rather than talking to X11 or Wayland itself, so wxWidgets is never a direct Wayland client.

| Field             | Value                                                                                                       |
| ----------------- | ----------------------------------------------------------------------------------------------------------- |
| Version / commit  | `3.3.3` (development), commit [`f12b247d`][commit] (studied June 2026)                                      |
| Language          | C++ (C++11 baseline; some C in vendored libs)                                                               |
| License           | [wxWindows Library Licence v3.1][license] (LGPL-with-exception)                                             |
| Repository        | [wxWidgets/wxWidgets]                                                                                       |
| Documentation     | [wxWidgets manual][wx-manual] (`wxTopLevelWindow`, `wxEvtLoopBase`, `wxApp`)                                |
| Category          | Native-widget-wrapping framework                                                                            |
| Platforms covered | Win32 (`src/msw/`), macOS/AppKit (`src/osx/cocoa/`), Linux/GTK (`src/gtk/`) → X11 **and** Wayland _via GTK_ |
| Loop ownership    | **Callback-driven, delegated to the native loop** (`gtk_main`, the Win32 message pump, `[NSApp run]`)       |
| Repo paths        | `src/gtk/{toplevel,window,evtloop,app}.cpp`, `src/msw/{toplevel,window,evtloop}.cpp`, `src/osx/cocoa/*.mm`  |

---

## Overview

### What it solves

wxWidgets gives a single C++ API (`wxFrame`, `wxDialog`, `wxWindow`, `wxApp`) that produces a **genuinely native** application on each platform — native menus, native file dialogs, native controls — by mapping its classes onto the platform's own toolkit. Its stated identity, from the project README:

> wxWidgets is a free and open source cross-platform C++ framework for writing advanced GUI applications using native controls.

— [`README.md`][readme] (wxWidgets/wxWidgets)

The windowing layer is the load-bearing part of "native controls": every `wxTopLevelWindow` is backed by a real `HWND`, `NSWindow`, or `GtkWindow`, and every event ultimately originates in that platform's event queue. wxWidgets does **not** own an event loop, a compositor connection, or an input stack of its own — it adapts each platform's. This is the opposite stance to toolkits that draw everything themselves and own the [client-vs-server-decoration][csd-vs-ssd] decision directly (Avalonia, Flutter, [`winit`][winit]-based apps); wxWidgets inherits whatever the native toolkit chose. The layout side of the framework (sizers) is surveyed separately in [ui-layout][ui-layout]; this document stays on windowing.

### Design philosophy

- **Wrap, don't reimplement.** Each port (`src/msw/`, `src/osx/cocoa/`, `src/gtk/`) is a thin adapter over the native toolkit. The class `wxTopLevelWindowMSW` calls `CreateWindowEx`; `wxNonOwnedWindowCocoaImpl` allocates an `NSWindow`; `wxTopLevelWindowGTK` calls `gtk_window_new`. The shared `wxTopLevelWindowBase` / `wxWindowBase` define the portable contract.
- **GTK as the Linux abstraction layer.** On Linux wxWidgets targets **GTK**, not X11 or Wayland. This is the framework's most consequential windowing decision: it gets Wayland support "for free" (whatever GTK supports) but is **two abstraction layers away from the display server** and can only reach Wayland or X11 primitives through GTK's GDK, or — very recently — by opening its own `wl_display` alongside GTK's for the few protocols GDK does not expose (see [§4](#_4-wayland-specifics)).
- **A deep single-rooted class hierarchy.** Every visible object descends from `wxWindow` → `wxWindowBase` → `wxEvtHandler` → `wxObject`; top-level windows add `wxTopLevelWindowBase` and `wxNonOwnedWindow`. The depth is the price of sharing behaviour across three radically different native toolkits.
- **Native event loop, wx event _system_.** wxWidgets pumps the platform loop and translates each native message into a `wxEvent` dispatched through its own `wxEvtHandler` chain. The loop is borrowed; the dispatch is wx's.

> [!NOTE]
> wxWidgets also ships ports for Qt, DirectFB, X11 (`wxUniversal`), iOS and Android, but the three mainstream desktop ports — MSW, OSX/Cocoa, GTK — carry the windowing weight and are the focus here. The X11 (`src/x11/`) port is the `wxUniversal` "draw-our-own-widgets" backend and is effectively legacy.

---

## How it works

The windowing core is three layers deep:

1. **Portable base** — `wxWindowBase` (`include/wx/window.h`), `wxTopLevelWindowBase` (`include/wx/toplevel.h`), `wxEvtLoopBase` (`include/wx/evtloop.h`), `wxAppBase`. These define the API and the event model.
2. **Per-platform window class** — `wxWindowMSW` / `wxWindowGTK` / `wxWindowMac`, and the top-level `wxTopLevelWindowMSW` / `wxTopLevelWindowGTK` / `wxNonOwnedWindowImpl`. Each holds the native handle (`m_hWnd`, `m_widget`, `m_macWindow`).
3. **Per-platform event loop** — `wxGUIEventLoop`, one implementation per `src/<platform>/evtloop`, each delegating to the native loop.

The native handle is exposed uniformly through `GetHandle()`:

```cpp
// include/wx/msw/window.h
virtual WXWidget GetHandle() const override { return GetHWND(); }
// include/wx/gtk/window.h
virtual WXWidget GetHandle() const override { return m_widget; }
```

The loop is **never wx's own**. On GTK, `wxGUIEventLoop::DoRun` is a thin wrapper around `gtk_main`:

```cpp
// src/gtk/evtloop.cpp  (wxGUIEventLoop::DoRun)
while ( !m_shouldExit )
{
    gtk_main();
}
```

On Windows it is the classic Win32 `GetMessage`/`TranslateMessage`/`DispatchMessage` pump (`src/msw/evtloop.cpp`, `wxGUIEventLoop::ProcessMessage`); on macOS it is `[NSApp run]` (`src/osx/cocoa/evtloop.mm`, `wxGUIEventLoop::OSXDoRun`). Each native message is fed back into wx via `wxEvtHandler::ProcessEvent`. This delegation is the single most important fact about wxWidgets' windowing model: see [readiness-vs-completion-windowing][readiness-vs-completion-windowing] for how a borrowed loop constrains everything downstream.

---

## 1. Window creation & lifecycle

Each port maps the portable `Create(parent, id, title, pos, size, style, name)` onto one native call.

**Win32.** `wxTopLevelWindowMSW::CreateFrame` builds a window class name and calls `MSWCreate`, which bottoms out in `CreateWindowEx`. The wx `style` flags are translated to Win32 `WS_*` / `WS_EX_*` styles in `MSWGetStyle` (`src/msw/toplevel.cpp`):

```cpp
// src/msw/toplevel.cpp  (wxTopLevelWindowMSW::MSWGetStyle)
// note that if we don't set WS_POPUP, Windows assumes WS_OVERLAPPED and
// creates a window with both caption and border, hence we need to use
// WS_POPUP in a few cases just to avoid having caption/border ...
if ( ( style & wxRESIZE_BORDER ) && !IsAlwaysMaximized())
    msflags |= WS_THICKFRAME;
...
if ( style & (wxCAPTION | wxMINIMIZE_BOX | wxMAXIMIZE_BOX | wxCLOSE_BOX) )
    msflags |= WS_CAPTION;
```

X11/Win32-style **immediate mapping** applies: the `HWND` exists the moment `CreateWindowEx` returns.

**macOS/Cocoa.** `wxNonOwnedWindowCocoaImpl::Create` (`src/osx/cocoa/nonownedwnd.mm`) allocates `wxNSWindow` (or `wxNSPanel` for tool/popup/dialog), translates wx styles to an `NSWindowStyleMask`, and calls `initWithContentRect:styleMask:backing:defer:`:

```objc
// src/osx/cocoa/nonownedwnd.mm  (wxNonOwnedWindowCocoaImpl::Create)
[m_macWindow initWithContentRect:contentRect
    styleMask:windowstyle
    backing:NSBackingStoreBuffered
    defer:NO
    ];
```

`wxSTAY_ON_TOP` becomes `NSModalPanelWindowLevel`, `wxPOPUP_WINDOW` becomes `NSPopUpMenuWindowLevel`, transparency via `setAlphaValue:`.

**Linux/GTK.** `wxTopLevelWindowGTK::Create` (`src/gtk/toplevel.cpp`) calls `gtk_window_new(GTK_WINDOW_TOPLEVEL)`, then sets a `GdkWindowTypeHint`, transient parent, and skip-taskbar/keep-above hints. Decorations are translated to **WM hints** (`GdkWMDecoration`/`GdkWMFunction`):

```cpp
// src/gtk/toplevel.cpp  (wxTopLevelWindowGTK::Create)
if ( (style & wxSIMPLE_BORDER) || (style & wxNO_BORDER) )
{
    m_gdkDecor = 0;
    gtk_window_set_decorated(GTK_WINDOW(m_widget), false);
}
else // have border
{
    m_gdkDecor = GDK_DECOR_BORDER;
    if ( style & wxCAPTION )   m_gdkDecor |= GDK_DECOR_TITLE;
    if ( style & wxSYSTEM_MENU ) m_gdkDecor |= GDK_DECOR_MENU;
    ...
}
```

**Attributes that silently degrade.** `gdk_window_set_decorations`/`gdk_window_set_functions` are X11-WM hints that Wayland compositors mostly ignore; the WM-functions hints (minimize/maximize/resize enable) are advisory even on X11. Transparency on GTK depends on a compositing manager (`wxBG_STYLE_TRANSPARENT` checks `IsTransparentBackgroundSupported`, `src/gtk/window.cpp`); `wxSTAY_ON_TOP` is `gtk_window_set_keep_above`, honoured on X11 but compositor-dependent on Wayland.

**Initial-frame handling.** On X11, GTK realizes and maps immediately, but wxGTK adds a wrinkle: to get correct frame extents it **defers `gtk_widget_show()`** until the WM answers a `_NET_REQUEST_FRAME_EXTENTS` round-trip (with a 1-second timeout fallback):

```cpp
// src/gtk/toplevel.cpp  (wxTopLevelWindowGTK::Show)
// Initial show. If WM supports _NET_REQUEST_FRAME_EXTENTS, defer
// calling gtk_widget_show() until _NET_FRAME_EXTENTS property
// notification is received, so correct frame extents are known.
```

On Wayland the [no-buffer-no-window][no-buffer-no-window] rule is GTK's concern, not wxWidgets': wx never attaches a `wl_buffer` itself; GDK does so when the GTK widget is drawn.

**Surface/handle exposure for GPU/software rendering.** wx exposes the native handle via `GetHandle()` (an `HWND`, `NSWindow`/`NSView`, or `GtkWidget*`). For OpenGL, `wxGLCanvas` (`src/gtk/glcanvas.cpp`) branches on `wxGTKImpl::IsWayland`/`IsX11` to fetch the right native surface. There is **no** `raw-window-handle`-style portable struct; consumers must `#ifdef` per platform.

**Destruction-ordering hazards.** wxGTK's destructor explicitly defends against dangling timer callbacks and lingering grabs:

```cpp
// src/gtk/toplevel.cpp  (wxTopLevelWindowGTK::~wxTopLevelWindowGTK)
if ( m_netFrameExtentsTimerId )
    g_source_remove(m_netFrameExtentsTimerId);
if (m_grabbedEventLoop)
{
    wxFAIL_MSG(wxT("Window still grabbed"));
    RemoveGrab();
}
```

On Win32, `WM_CLOSE` is deliberately swallowed so `DefWindowProc` cannot destroy the `HWND` out from under the C++ object — wx destroys it itself in `~wxWindow` (`src/msw/window.cpp`, `case WM_CLOSE`).

---

## 2. Event loop

**Who owns the loop: the native toolkit does; wxWidgets delegates.** wxWidgets defines a portable `wxEventLoopBase` ([`wxEvtLoopBase`][wx-evtloop]) whose `DoRun`/`Dispatch`/`WakeUp` each port implements against the platform loop. This is callback-driven — the app calls `wxApp::OnRun` → `loop->Run()`, and from then on control lives inside the native pump, surfacing only through wx event handlers. [inference] The rationale is structural: to host native controls you must run their loop, because controls expect their toolkit's dispatch (menu tracking, IME windows, modal sheets) to be live.

**GTK.** `wxGUIEventLoop::Dispatch` calls `gtk_main_iteration`; `DoRun` loops on `gtk_main` (quoted above). External fds are integrated through GLib's `GIOChannel` in `wxGUIEventLoopSourcesManager` (`src/gtk/evtloop.cpp`, `wx_on_channel_event`), so wx event-loop sources ride GLib's `GMainContext` poll. `YieldFor` temporarily swaps GDK's event handler (`gdk_event_handler_set(wxgtk_main_do_event, ...)`) to filter which events are dispatched during a yield.

**Win32.** `src/msw/evtloop.cpp` runs the textbook message pump:

```cpp
// src/msw/evtloop.cpp  (wxGUIEventLoop::ProcessMessage)
if ( !PreProcessMessage(msg) )
{
    ::TranslateMessage(msg);
    ::DispatchMessage(msg);
}
```

The infamous [Win32 modal resize/move loop][win32-modal-resize-loop] is handled, not avoided: wx hooks `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` (`src/msw/window.cpp`, `HandleEnterSizeMove`/`HandleExitSizeMove`) so it can keep idle processing alive while `DefWindowProc` runs its own internal `GetMessage` loop during a drag-resize. A `gs_modalEntryWindowCount` counter (`src/msw/window.cpp`) tracks nested modal loops so keyboard interception behaves.

**macOS.** `src/osx/cocoa/evtloop.mm` chooses between `[NSApp run]` for the outermost loop and a manual `nextEventMatchingMask:` pump for nested loops — and the comment explaining why is one of the clearest statements of the cost of borrowing AppKit's loop:

> In order to properly nest GUI event loops in Cocoa, it is important to have `[NSApp run]` only as the main/outermost event loop. There are many problems if `[NSApp run]` is used as an inner event loop. The main issue is that a call to `[NSApp stop]` is needed to exit an `[NSApp run]` event loop. But the `[NSApp stop]` has some side effects that we do not want — such as if there was a modal dialog box with a modal event loop running, that event loop would also get exited, and the dialog would be closed.

— `src/osx/cocoa/evtloop.mm` (`wxGUIEventLoop::OSXDoRun`)

Underneath, the Core Foundation layer (`src/osx/core/evtloop_cf.cpp`) installs `CFRunLoopObserver`s on `kCFRunLoopBeforeTimers`/`kCFRunLoopBeforeWaiting` to drive wx idle/pending-event processing, and `WakeUp` calls `CFRunLoopWakeUp`.

**Timers, wakeups, cross-thread user events.** `WakeUp` is per-platform: GTK posts a low-priority idle source (`g_idle_add_full`, `src/gtk/app.cpp`, `wxApp::WakeUpIdle`); CF calls `CFRunLoopWakeUp`; Win32 posts a null message. Cross-thread event injection uses `wxEvtHandler::QueueEvent`/`CallAfter`, which appends to a thread-safe pending-event queue and wakes the loop — the portable substitute for `winit`'s `EventLoopProxy`.

**Frame pacing & vsync.** wxWidgets has **no portable frame-callback or vsync abstraction**. Redraws are coalesced by the native toolkit's invalidation (`WM_PAINT` accumulation, GTK's `GdkFrameClock`). wxGTK connects to the `GdkFrameClock` `"layout"` signal (`src/gtk/window.cpp`, `frame_clock_layout`) only to integrate its sizer layout into GTK's frame cycle, not to expose [frame-callback vsync][frame-callback-vsync] to the app. There is no `CVDisplayLink`, no DXGI waitable-swapchain, no Wayland `wl_surface.frame` plumbing at the wx level; animation-timing apps must drop to the native handle.

> [!IMPORTANT]
> Because the loop is borrowed, wxWidgets has no way to offer the modern "the compositor tells you when to draw" pacing model. Frame timing is whatever the wrapped toolkit does, and the app cannot opt into compositor frame callbacks without reaching past wx to GDK.

---

## 3. Input

**Keyboard model.** wxWidgets normalizes to a portable `wxKeyEvent` carrying both a `wxKeyCode` ("virtual" key) and (where available) a raw scancode/keysym via `GetRawKeyCode`/`GetRawKeyFlags`. The mapping between [scancode, keysym, and virtual-key][scancode-keysym-virtualkey] is done per platform:

- **Win32** translates `WM_KEYDOWN`/`WM_CHAR` (`src/msw/window.cpp`), keeping the VK code and the translated character separate — `WM_KEYDOWN` produces the key event, `WM_CHAR` the text.
- **GTK** lets GTK/GDK own the keymap and xkbcommon state machine. wxGTK uses `libxkbcommon` only for _raw keycode translation_, and even then with a **hardcoded "us" layout**:

```cpp
// src/gtk/window.cpp  (XkbData::GetState)
m_ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
xkb_rule_names names{};
names.layout = "us";
m_keymap = xkb_keymap_new_from_names(m_ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
m_state = xkb_state_new(m_keymap);
```

The real layout-aware translation is GTK's; this xkb state exists only to fill in `GetRawKeyCode`. **Key repeat** is therefore GTK's responsibility on Wayland (Wayland makes the client synthesize repeats; GTK does it, wx inherits it) — wxWidgets never sees the `wl_keyboard` repeat-info.

**IME / text input.** This is where the wrap-native model shows both its strength (it works, because the native toolkit does it) and a notable wxGTK limitation:

- **GTK.** Input is funnelled through a `GtkIMContext` (`gtk_im_multicontext_new`), and committed text arrives via the `"commit"` signal. But wxGTK **disables on-the-spot pre-edit rendering**:

```cpp
// src/gtk/window.cpp  (creating the IM context)
m_imContext = gtk_im_multicontext_new();
// Cannot handle drawing preedited text yet
gtk_im_context_set_use_preedit(m_imContext, false);
```

So [pre-edit/composition][pre-edit-composition] text is shown in the IME's own over-the-spot window rather than inline; wx generic controls do not render the composition string themselves. Candidate-window positioning is GTK's.

- **Win32** forwards the full legacy IMM32 message set — `WM_IME_STARTCOMPOSITION`, `WM_IME_COMPOSITION`, `WM_IME_ENDCOMPOSITION`, `WM_IME_CHAR`, etc. — through `PreProcessMessage` (`src/msw/evtloop.cpp`) to `DefWindowProc` / the native EDIT control, which renders composition. wxWidgets uses **IMM32 via the native control**, not TSF directly.
- **macOS** relies on the `NSTextView`/[`NSTextInputClient`][nstextinputclient] machinery of the wrapped Cocoa control.

Key/text separation is therefore inherited from each toolkit: the native control distinguishes composition from committed text; wx surfaces the result as `wxEVT_CHAR`.

**Pointer.** `wxMouseEvent` is **absolute** (client/screen coordinates); there is no portable relative/raw-motion API. High-resolution scroll is partial:

```cpp
// src/msw/window.cpp  (wxWindowMSW::HandleMouseWheel)
event.m_wheelRotation = (short)HIWORD(wParam);
event.m_wheelDelta = WHEEL_DELTA;
event.m_wheelAxis = axis;
```

On Win32 wx passes the raw `WM_MOUSEWHEEL`/`WM_MOUSEHWHEEL` delta and `WHEEL_DELTA` granule to the app, leaving [delta accumulation][raw-vs-accelerated-pointer] to the handler. macOS momentum-scroll phases and Wayland `wl_pointer` `axis_v120` high-resolution steps are not surfaced as distinct wx concepts — they arrive flattened through the native control. Pointer capture is `CaptureMouse`/`ReleaseMouse`; there is no portable pointer-confinement or pointer-lock API (a recent addition, `src/gtk/wayland.cpp`, adds direct Wayland pointer _warping_ — see [§4](#_4-wayland-specifics)).

**Touch & gestures.** wxWidgets has a portable gesture-event family (`wxGestureEvent`, `wxPanGestureEvent`, `wxZoomGestureEvent`) wired to native recognizers, but coverage is uneven and Wayland touch is whatever GTK delivers.

**Cursor.** Cursors are native (`gdk_cursor_new_from_name`/`gdk_cursor_new_for_display` on GTK, `src/gtk/cursor.cpp`); wxGTK does not talk [`cursor_shape_v1`][cursor-shape-v1] itself — GDK does the cursor-shape negotiation under Wayland.

---

## 4. Wayland specifics

> [!WARNING]
> wxWidgets is **not a Wayland client**. On Linux it is a GTK application, and GTK (GDK) is the Wayland client. Every Wayland behaviour — surfaces, `xdg_toplevel`, decorations, fractional scale, popups — is implemented by GDK, two layers below wx. wxWidgets sees only GTK widgets and GDK windows.

**Decorations.** wxWidgets does not choose [client- vs server-side decorations][client-vs-server-decoration]; GTK does (GTK uses its own CSD client-side decorations / header bars). The one place wxGTK touches it is to give borderless-on-Wayland windows a header bar so they remain movable:

```cpp
// src/gtk/toplevel.cpp  (wxTopLevelWindowGTK::Create)
if ((m_gdkDecor & GDK_DECOR_TITLE) == 0 &&
    wxGTKImpl::IsWayland(display) &&
    wx_is_at_least_gtk3(10))
{
    gtk_window_set_titlebar(GTK_WINDOW(m_widget), gtk_header_bar_new());
}
```

It uses neither `libdecor` nor `xdg-decoration` directly — that is entirely GTK's affair.

**Backend detection.** wxGTK distinguishes Wayland from X11 by querying GDK's display type, cached in a static:

```cpp
// src/gtk/window.cpp  (wxGTKImpl::IsWayland)
bool wxGTKImpl::IsWayland(void* instance)
{
    static wxByte is = 2;
    if (is > 1)
        is = IsBackend(instance, "GdkWayland");
    return bool(is);
}
```

This `IsWayland`/`IsX11` pair (declared in `include/wx/gtk/private/backend.h`) is sprinkled across the GTK port (clipboard, glcanvas, cursor, mini-frame) to branch on per-backend quirks.

**Direct Wayland protocol use (the escape from GDK).** As of mid-2025 wxGTK began opening its **own** `wl_display`/`wl_registry` alongside GTK's to use protocols GDK does not expose. The first is [`pointer-warp-v1`][pointer-warp] — because Wayland forbids arbitrary pointer warping and GTK offers no API for it, wxGTK binds the staging protocol itself:

```cpp
// src/gtk/wayland.cpp
#include "wx/protocols/pointer-warp-v1-client-protocol.c"
...
if ( strcmp(interface, wp_pointer_warp_v1_interface.name) == 0 )
{
    WLGlobals.pointer_warp.reset(static_cast<wp_pointer_warp_v1*>(
        wl_registry_bind(registry, name, &wp_pointer_warp_v1_interface, 1)
    ));
}
```

The file header notes "We currently only use Wayland API for pointer warping" — a precise measure of how little of the Wayland surface area wxWidgets reaches around GTK for.

**Protocol coverage beyond core + xdg-shell** (`fractional-scale-v1`, `viewporter`, `xdg-activation`, `idle-inhibit`, `layer-shell`) is **whatever the linked GTK provides**; wxWidgets exposes none of them as a portable concept. Compositor-specific workarounds in wx comments target X11 WM quirks (Ubuntu's WM, KDE/Gnome taskbar differences in `MSWGetStyle`-adjacent comments) rather than Wayland compositors, because the Wayland quirks are absorbed by GTK.

---

## 5. DPI & scaling

wxWidgets' native coordinate unit is **logical pixels (DIPs)** in 3.x, with `FromDIP`/`ToDIP` and `wxWindow::GetContentScaleFactor`/`GetDPIScaleFactor` mediating the [logical-vs-physical][logical-vs-physical-coords] split. Per [`scale factor`][scale-factor]:

**Win32 — per-monitor v2.** wxMSW supports [Per-Monitor-DPI-Aware v2][wm-dpichanged] when the application manifest declares it. The window detects its awareness context (`src/msw/nonownedwnd.cpp`, comparing against `WXDPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`) and handles the [`WM_DPICHANGED`][wm-dpichanged] dance, propagating to all children:

```cpp
// src/msw/nonownedwnd.cpp
case WM_DPICHANGED:
    ...
    const bool processed = MSWUpdateOnDPIChange(m_activeDPI, newDPI);
```

`MSWUpdateOnDPIChange` (`src/msw/window.cpp`) walks children recursively and fires `wxDPIChangedEvent`. Per-window DPI is read with `GetDpiForWindow` (loaded dynamically for older Windows).

**The created-at-wrong-scale problem.** wxGTK acknowledges it explicitly: at create time the widget is not realized, so it guesses the primary monitor's scale and corrects later:

```cpp
// src/gtk/toplevel.cpp  (wxTopLevelWindowGTK::Create)
// This value may be incorrect as here it's just set to the scale factor of
// the primary monitor because the widget is not realized yet ...
// And if this isn't the case, we will set it to
// the correct value when we get "configure-event" from GTK later.
m_scaleFactor = GetContentScaleFactor();
```

**Wayland fractional scaling** is GTK's job; before GTK 4's fractional-scale support, GTK reported integer scales and wxGTK saw only `gdk_window_get_scale_factor` (`src/gtk/toplevel.cpp`). **macOS** uses `backingScaleFactor`, observed via the `NSWindowDidChangeBackingProperties` notification (`src/osx/cocoa/nonownedwnd.mm`, `newBackingScaleFactor`). Mixed-DPI multi-monitor migration is handled by the native toolkit; wx reacts to the resulting events. See the high-DPI overview in the [wxWidgets manual][wx-highdpi].

---

## 6. Multi-window & popups

- **Modal dialogs.** `wxDialog::ShowModal` spins a nested `wxGUIEventLoop`. On GTK the dialog grabs input (`m_grabbedEventLoop`, guarded in the destructor above); on macOS it runs a modal session via `runModalSession:` (`src/osx/cocoa/evtloop.mm`); on Win32 it disables the parent and runs a nested pump (the `gs_modalEntryWindowCount`-tracked loop).
- **Tooltips / menus / popups.** `wxPopupWindow` on GTK is a `GTK_WINDOW_POPUP` with a manual grab so a click outside dismisses it:

```cpp
// src/gtk/popupwin.cpp
m_widget = gtk_window_new( GTK_WINDOW_POPUP );
...
gtk_window_set_type_hint( GTK_WINDOW(m_widget), GDK_WINDOW_TYPE_HINT_COMBO );
```

On X11 a `GTK_WINDOW_POPUP` maps to an [override-redirect][override-redirect-vs-xdg-popup-grab] window; on Wayland GTK must instead realize it as an `xdg_popup` with proper grab semantics — again, GTK's translation, not wx's. wxWidgets cannot position popups with Wayland's parent-relative `xdg_positioner` semantics directly; it asks GTK to place a top-level-ish popup and GTK maps that onto Wayland's stricter model, which is a known source of popup-placement quirks under Wayland.

- **Parent/child stacking & groups.** `gtk_window_set_transient_for` (GTK), `WS_EX_TOPMOST`/owned-window relationships and a hidden parent window for taskbar control (`wxTLWHiddenParentModule`, `src/msw/toplevel.cpp`), and `NSWindow` levels (Cocoa).

---

## 7. Threading

The rule is the strictest common denominator of the three toolkits: **GUI objects must be created and touched on the main thread, and events are delivered on the main thread.** This is forced by AppKit (Cocoa is main-thread-only) and matched everywhere for portability.

- **Window creation & events: main thread only.** All native loops dispatch on the thread that called `Run()`.
- **Cross-thread communication.** Worker threads must not call wx GUI methods directly; they use `wxEvtHandler::QueueEvent` / `wxThreadEvent` / `CallAfter`, which marshal back to the main thread via the wake-up mechanism in [§2](#_2-event-loop).
- **The legacy GTK GUI mutex.** Historically wxGTK allowed `wxMutexGuiEnter`/`wxMutexGuiLeave` around `gdk_threads_enter`/`gdk_threads_leave` (`include/wx/gtk/private/threads.h`, `wxGDKThreadsLock`); these wrap GDK functions that GTK itself has deprecated, and the recommended path is now message-passing, not the GUI lock.
- **Rendering off the event thread** is not supported portably; drawing happens in paint handlers on the main thread.

> [!NOTE]
> macOS/AppKit's main-thread requirement is the historical reason every cross-platform toolkit, wxWidgets included, settles on "create windows and pump events on the main thread."

---

## 8. Clipboard & DnD

wxWidgets models data as `wxDataObject`s carrying `wxDataFormat`s (MIME-like atoms), negotiated against the native clipboard/DnD machinery.

- **Win32** uses **OLE** (`OleSetClipboard`, `src/msw/clipbrd.cpp`) for both clipboard and DnD, which gives delayed rendering for free (the source supplies data on demand via the `IDataObject` interface). wx flushes with `OleFlushClipboard`/`OleSetClipboard(nullptr)` on exit so data survives the app.
- **GTK / X11+Wayland** uses GTK's `GtkClipboard` over X11 selections (`GDK_SELECTION_CLIPBOARD`, `GDK_SELECTION_PRIMARY`) with the standard targets/INCR protocol handled by GDK (`src/gtk/clipbrd.cpp`, `GTKOnTargetReceived`, the timestamp-atom dance). Under Wayland the selection model differs, so wxGTK keeps an **alternative-format table** mapping X11 atoms to Wayland-friendly MIME types:

```cpp
// src/gtk/clipbrd.cpp
// Returns alternative format used under Wayland for the given format or 0.
extern GdkAtom wxGTKGetAltWaylandFormat(GdkAtom atom);
```

This is a concrete instance of the wrap-native model leaking: wx must special-case Wayland clipboard MIME conventions because GTK's older selection API does not paper over them completely.

- **macOS** uses `NSPasteboard`/`NSDragging` via the Cocoa controls.

INCR (large X11 selections) and delayed Win32 rendering are thus handled by the underlying toolkit (GDK / OLE), not reimplemented by wx.

---

## 9. Escape hatches

When the abstraction is insufficient, wxWidgets exposes the native layer:

- **Native handle.** `GetHandle()` returns the `HWND` / `NSWindow` (or `NSView`) / `GtkWidget*`; helper getters like `GetHWND()`, `GTKGetDrawingWindow()` (`GdkWindow*`), and `MacGetTopLevelWindowRef` give finer access. This is the primary leak point — any windowing capability wx does not model is reachable here, at the cost of `#ifdef`-per-platform code.
- **Embedding native windows.** `wxNativeWindow` (`src/gtk/nativewin.cpp`, [`wxNativeWindow`][wx-nativewindow]) wraps an existing native control as a wx window, and `wxNativeContainerWindow` lets a wx app live inside a foreign top-level (it even installs a GDK event filter, `wxNativeContainerWindowFilter`, to learn when the foreign window is destroyed).
- **Message-pump hooks.** `MSWWindowProc` is virtual — subclasses override it to intercept raw Win32 messages before wx; `MSWTranslateMessage` and `wxGUIEventLoop::PreProcessMessage` are override points. On GTK, apps can `g_signal_connect` directly to the `GtkWidget` from `GetHandle()`.
- **Direct backend protocols.** The newest hatch is wxGTK itself reaching past GDK to raw Wayland (`src/gtk/wayland.cpp`) for pointer warping — the framework using its own escape hatch internally.

The breadth of these hatches is itself the finding: the wrap-native model means the abstraction is _known_ to leak (frame pacing, raw pointer, pre-edit, Wayland popups), and wx provides the native handle precisely so apps can route around it.

---

## 10. History, redesigns & known regrets

- **The GTK1 → GTK2 → GTK3 migration.** `src/gtk/` carries the scars of three GTK generations. `#ifdef __WXGTK3__` and `#ifndef __WXGTK4__` guards are everywhere (toplevel.cpp, window.cpp), and `gtk_widget_set_uposition` (GTK2) vs `gtk_window_move` (GTK3) branches survive in `Create`. GTK 3 became the default; GTK 2 is still selectable. The cost of supporting multiple GTK majors in one codebase is the dominant complexity in the Linux port.
- **GTK4 is still not a shipping target.** Despite a `__WXGTK4__` build macro existing, `configure` in 3.3.x offers only GTK 3 (default), GTK 2, and obsolete GTK 1.2 — **there is no `--with-gtk=4`**:

```text
# docs/gtk/install.md
 * `--with-gtk=3`   Use GTK 3. Default.
 * `--with-gtk=2`   Use GTK 2.
 * `--with-gtk=1`   Use GTK 1.2. Obsolete.
```

GTK4 removed `GdkWindow` and the X11 escape hatches wxGTK relies on (it forces CSD, drops `gdk_window_*` decoration hints, restructures the event model), so the port is a long, unfinished effort — a concrete example of how the wrap-native model leaves wxWidgets exposed to its dependency's redesigns. Tracking: [wxWidgets GitHub issues for GTK4][gtk4-issue].

- **Wayland support is recent and incremental.** Wayland came "for free" via GTK but the gaps (pointer warping, clipboard MIME, popup placement) are still being filled — the `src/gtk/wayland.cpp` direct-protocol code is dated **2025-08-22**, two decades into the project's life. Long-standing Wayland tickets cover DPI/fractional-scale and pointer behaviour; see e.g. [issue #22082][wx-issue-22082] and [issue #23598][wx-issue-23598].
- **The deep `wxWindow` hierarchy** is a recurring maintenance theme: every behaviour shared across MSW/Cocoa/GTK must thread through `wxWindowBase`, and platform-specific exceptions accumulate as `MSW*`/`GTK*`/`OSX*` virtual overrides. It is the structural price of "one API, three native toolkits."
- **The Python binding shift.** The wxPython binding was rewritten as [Phoenix][phoenix] (auto-generated from the C++ headers via sip) to escape the unmaintainable hand-written SWIG bindings — a downstream regret about how the large surface area was exposed.

---

## Strengths

- **Genuinely native look, feel, and behaviour** on each platform, because it is the platform's own toolkit — including native IME, menus, dialogs, and accessibility "for free."
- **One C++ API across Win32, Cocoa, and GTK** (plus Qt/X11/mobile ports), with a mature, stable, decades-proven surface.
- **Robust escape hatches** (`GetHandle`, virtual `MSWWindowProc`, `wxNativeWindow`) so apps are never fully boxed in by the abstraction.
- **Native event integration done carefully** — the nested-loop, modal, and resize-loop edge cases are handled with hard-won per-platform code.
- **Sensible DPI story on Windows** (per-monitor v2, `WM_DPICHANGED` propagation, `FromDIP`/`ToDIP`).

## Weaknesses

- **Two layers from the display server on Linux.** Targeting GTK means wxWidgets is never a direct Wayland/X11 client; modern Wayland features arrive only as fast as GTK exposes them, and wx must occasionally reach around GTK to raw protocols.
- **No portable frame-pacing/vsync model** — animation-timing apps cannot opt into compositor frame callbacks, `CVDisplayLink`, or waitable swapchains through wx.
- **Limited modern input surfacing** — no portable raw/relative pointer, high-resolution scroll flattened, GTK pre-edit composition not rendered inline (`gtk_im_context_set_use_preedit(..., false)`).
- **Hostage to dependency redesigns** — the unfinished GTK4 port is the clearest case; GTK4's removal of `GdkWindow`/decoration hints breaks core assumptions.
- **Deep class hierarchy and large per-platform `#ifdef` surface** make the windowing code dense and the abstraction's leaks numerous and documented.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                   | Trade-off                                                                                               |
| --------------------------------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| Wrap the native toolkit per platform                            | Truly native controls, IME, dialogs, accessibility with little wx code      | The windowing abstraction leaks; capabilities limited to what the native toolkit exposes                |
| Use **GTK** as the Linux backend (not X11/Wayland directly)     | One Linux port covers both X11 and Wayland; reuse GTK's compositor handling | Two layers from the display server; modern Wayland features gated on GTK; occasional raw-protocol hacks |
| Delegate the event loop to the native pump                      | Native controls require their toolkit's dispatch (menus, IME, modal sheets) | No control over frame pacing/vsync; nested-loop and modal edge cases must be hand-handled per platform  |
| Logical-pixel (DIP) API with `FromDIP`/`ToDIP`                  | Portable coordinate model across mixed-DPI monitors                         | Created-at-wrong-scale window must be re-corrected after realization (GTK guesses, fixes on configure)  |
| Expose native handle + virtual `MSWWindowProc`/`wxNativeWindow` | Apps can always reach the platform when wx falls short                      | Escape-hatch use is `#ifdef`-per-platform and concedes the abstraction is incomplete                    |
| Single deep `wxWindow` → `wxEvtHandler` → `wxObject` hierarchy  | Shared behaviour across three native toolkits in one API                    | Dense, override-heavy code; platform exceptions accumulate; hard to evolve                              |

---

## Verdict: what a new framework should steal / avoid

**Steal:** the disciplined treatment of native-loop nesting (the Cocoa `[NSApp run]`-vs-`nextEventMatchingMask:` split and the Win32 `WM_ENTERSIZEMOVE` idle-keepalive are textbook), the always-available native-handle escape hatch with structured embedding (`wxNativeWindow`/`wxNativeContainerWindow`), the explicit per-backend detection (`IsWayland`/`IsX11`) so quirks are branched not papered over, and the honest `FromDIP`/`ToDIP` logical-coordinate model with a documented "fix scale on configure" reconciliation.

**Avoid:** building your Linux windowing on a higher-level toolkit (GTK) if you need direct control of the display server — wxWidgets' two-layer indirection means it is perpetually a step behind on Wayland and must hack around its own dependency (`src/gtk/wayland.cpp`). A framework that wants modern frame pacing, raw pointer, inline pre-edit, and Wayland popup positioning should own the [client-vs-server-decoration][csd-vs-ssd] layer itself (the Avalonia/`winit` stance) rather than inherit it. And weigh the deep single-rooted hierarchy: it shares code but ossifies the design.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact GTK4 port status and blocking issues.** The build offers no `--with-gtk=4`; the live state lives in the GTK4-labelled issues and the `__WXGTK4__` guards across `src/gtk/`. Answer: [wxWidgets GitHub issues][gtk4-issue] + a full (non-shallow) clone's commit history of `src/gtk/`.
- **Whether direct Wayland protocol use will expand beyond pointer-warp.** `src/gtk/wayland.cpp` says "currently only ... pointer warping"; the trajectory lives in recent PRs touching `include/wx/protocols/` and `src/gtk/wayland.cpp`.
- **High-resolution / momentum scroll fidelity on macOS and Wayland.** The flattening happens inside the native controls; confirming exactly what wx drops needs reading `src/osx/cocoa/window.mm` scroll handling and GTK `wl_pointer` axis handling under a profiler.
- **TSF (vs IMM32) on Windows.** wxMSW forwards IMM32 messages; whether any control path uses TSF would need a grep of the full tree's rich-text/`wxTextCtrl` MSW backend, not present in the windowing files.

---

## Sources

- [wxWidgets/wxWidgets] — main repository; all quoted paths are at commit [`f12b247d`][commit]
- `src/gtk/toplevel.cpp`, `src/gtk/window.cpp`, `src/gtk/evtloop.cpp`, `src/gtk/app.cpp` — GTK port window creation, input, loop
- `src/gtk/wayland.cpp`, `include/wx/gtk/private/{wayland,backend,threads}.h` — direct Wayland protocol use, backend detection
- `src/msw/toplevel.cpp`, `src/msw/window.cpp`, `src/msw/evtloop.cpp`, `src/msw/nonownedwnd.cpp` — Win32 port, DPI, IME, modal loop
- `src/osx/cocoa/{nonownedwnd,evtloop}.mm`, `src/osx/core/evtloop_cf.cpp` — Cocoa window creation and CFRunLoop integration
- `src/gtk/clipbrd.cpp`, `src/msw/clipbrd.cpp`, `src/gtk/nativewin.cpp` — clipboard/DnD and native embedding
- `docs/gtk/install.md` — GTK version build options (no GTK4)
- [wxWidgets manual][wx-manual]: [`wxTopLevelWindow`][wx-toplevel], [`wxEvtLoopBase`][wx-evtloop], [high-DPI overview][wx-highdpi], [`wxNativeWindow`][wx-nativewindow]
- Microsoft: [About Messages and Message Queues][win32-msgloop], [`WM_DPICHANGED`][wm-dpichanged], [Clipboard Operations][win32-clipboard]
- Apple: [`NSTextInputClient`][nstextinputclient]
- Wayland protocols: [`cursor-shape-v1`][cursor-shape-v1], [`text-input-unstable-v3`][text-input-v3], [`xdg-decoration-unstable-v1`][xdg-decoration], [`pointer-warp-v1`][pointer-warp]
- Sibling docs: [concepts][concepts], [ui-layout (GTK/Qt layout)][ui-layout], [async-io (event-loop overlap)][async-io]

<!-- References -->

[wxWidgets/wxWidgets]: https://github.com/wxWidgets/wxWidgets
[commit]: https://github.com/wxWidgets/wxWidgets/commit/f12b247d26b6a1f2d48e88f2892c51988acbb578
[readme]: https://github.com/wxWidgets/wxWidgets/blob/52eee93edb66f59d0516a09a5f5e3335262356a8/README.md
[license]: https://github.com/wxWidgets/wxWidgets/blob/52eee93edb66f59d0516a09a5f5e3335262356a8/docs/licence.txt
[wx-manual]: https://web.archive.org/web/20250514161534/https://docs.wxwidgets.org/3.2/
[wx-toplevel]: https://web.archive.org/web/20250323112235/https://docs.wxwidgets.org/3.2/classwx_top_level_window.html
[wx-evtloop]: https://web.archive.org/web/20250208031531/https://docs.wxwidgets.org/3.2/classwx_event_loop_base.html
[wx-highdpi]: https://web.archive.org/web/20250428195429/https://docs.wxwidgets.org/3.2/overview_high_dpi.html
[wx-nativewindow]: https://web.archive.org/web/20250428094713/https://docs.wxwidgets.org/3.2/classwx_native_window.html
[win32-msgloop]: https://learn.microsoft.com/en-us/windows/win32/winmsg/about-messages-and-message-queues
[wm-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[win32-clipboard]: https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-operations
[nstextinputclient]: https://developer.apple.com/documentation/appkit/nstextinputclient
[cursor-shape-v1]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/cursor-shape/cursor-shape-v1.xml
[text-input-v3]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/unstable/text-input/text-input-unstable-v3.xml
[xdg-decoration]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/xdg-decoration/xdg-decoration-unstable-v1.xml
[pointer-warp]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/blob/main/staging/pointer-warp/pointer-warp-v1.xml
[gtk4-issue]: https://github.com/wxWidgets/wxWidgets/issues?q=is%3Aissue+GTK4
[wx-issue-22082]: https://github.com/wxWidgets/wxWidgets/issues/22082
[wx-issue-23598]: https://github.com/wxWidgets/wxWidgets/issues/23598
[phoenix]: https://github.com/wxWidgets/Phoenix
[winit]: https://github.com/rust-windowing/winit
[concepts]: ./concepts.md
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
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
