# Avalonia (C# / .NET)

A cross-platform, GPU-accelerated .NET UI framework that owns its windowing layer end-to-end — every backend (Win32, X11, macOS/AppKit, Android, iOS, Browser) is a thin platform shim behind a single managed `IWindowImpl`/`ITopLevelImpl` abstraction, with all pixels drawn by Skia rather than native controls.

| Field                  | Value                                                                                                                                                                                                                 |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit studied | `12.1.999` dev branch, commit [`aee3f68`][commit] (2026-06-06)                                                                                                                                                        |
| Language               | C# (`LangVersion 14.0`, .NET); macOS shim in Objective-C++ (`.mm`)                                                                                                                                                    |
| License                | MIT                                                                                                                                                                                                                   |
| Repository             | [AvaloniaUI/Avalonia][repo]                                                                                                                                                                                           |
| Documentation          | [docs.avaloniaui.net][docs] / [api-docs.avaloniaui.net][apidocs]                                                                                                                                                      |
| Category               | From-scratch .NET UI framework (Skia-rendered, own windowing layer)                                                                                                                                                   |
| Platforms covered      | Win32, X11 (incl. XWayland), macOS/AppKit, Android, iOS, Browser (WASM); **no native Wayland** ([#1243][wayland-issue])                                                                                               |
| Loop ownership         | Hybrid: a WPF-style managed `Dispatcher` drives a per-platform native loop (`GetMessage`, `NSApp run`/`CFRunLoop`, `epoll` over the X11 fd)                                                                           |
| Native coord unit      | Logical (DIPs); platform shims convert to/from physical pixels at the boundary                                                                                                                                        |
| Repo paths (platform)  | `src/Avalonia.Controls/Platform/` (interfaces), `src/Windows/Avalonia.Win32/`, `src/Avalonia.X11/`, `src/Avalonia.Native/` + `native/Avalonia.Native/src/OSX/` (Obj-C++ shim), `src/Avalonia.FreeDesktop/` (DBus/IME) |

---

## Overview

### What it solves

Avalonia is a single-codebase desktop-and-mobile UI framework for .NET. Unlike a binding over native controls (think `Gtk#`, WinForms, or MAUI's handler model), Avalonia renders **everything itself** with [Skia], and treats the OS window merely as a surface + an input/event source. Its windowing layer is therefore deliberately minimal: each platform implements a small set of interfaces — `IWindowingPlatform`, `IWindowImpl`, `IPopupImpl`, `ITopLevelImpl` — and the rest of the framework (layout, controls, composition renderer) is platform-agnostic. The companion [ui-layout survey][ui-layout] covers the layout half; this doc is strictly about the windowing/event-loop/input layer.

The abstraction's intended shape is captured in the doc comment on `ITopLevelImpl.Surfaces`, which spells out the contract every backend must satisfy to be renderable:

> It should be enough to expose a native window handle via IPlatformHandle and add support for framebuffer (even if it's emulated one) via IFramebufferPlatformSurface. If you have some rendering platform that's tied to your particular windowing platform, just expose some toolkit-specific object (e. g. Func&lt;Gdk.Drawable&gt; in case of GTK#+Cairo)
>
> — [`src/Avalonia.Controls/Platform/ITopLevelImpl.cs`][toplevel-impl]

### Design philosophy

- **Own the window, draw the pixels.** A backend supplies an OS window handle and a list of `IPlatformRenderSurface`s (framebuffer, GLX/EGL, Metal, Vulkan, DXGI); the Skia-backed compositor does the rest. Native widgets are never used, so the windowing layer never has to wrap a native control hierarchy.
- **A single managed loop model across all OSes.** Rather than expose each platform's loop directly, Avalonia funnels everything through a WPF-derived `Dispatcher` with `DispatcherPriority` ordering. Each platform implements only a tiny `IDispatcherImpl` that knows how to _signal_, _time_, and (optionally) _run_ the native loop. This was a deliberate 2023 rewrite — see [§10](#10-history-redesigns-known-regrets).
- **Interop via MicroCom, not P/Invoke soup.** The macOS backend is a C++/Obj-C++ library (`libAvaloniaNative`) reached through a generated COM-style ABI (`avn.idl` + the MicroCom source generator), so the managed/native boundary is a set of vtable interfaces rather than thousands of marshalled function pointers.
- **`[Unstable]`/`[PrivateApi]` platform interfaces.** `IWindowImpl` and friends are annotated `[Unstable]`; from Avalonia 11 onward direct access to `window.PlatformImpl`/`IWindowingPlatform` was removed from the public surface. The windowing layer is explicitly an implementation detail.

---

## How it works

### The core abstractions

| Concept              | Type / item                                                                | Role                                                                            |
| -------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Window factory       | `IWindowingPlatform` (`CreateWindow`, `CreateTrayIcon`, …)                 | Per-platform factory registered in `AvaloniaLocator`.                           |
| Top-level surface    | `ITopLevelImpl`                                                            | Common base of window + popup: surfaces, input/paint/resize callbacks, scaling. |
| Window               | `IWindowImpl : IWindowBaseImpl`                                            | Adds title, state, decorations, move/resize-drag, min/max constraints.          |
| Popup                | `IPopupImpl`                                                               | Menus/tooltips/flyouts; positioned by `IPopupPositioner`.                       |
| Managed loop         | `Avalonia.Threading.Dispatcher`                                            | WPF-style priority queue; owns frames, timers, the sync-context.                |
| Loop driver (per OS) | `IDispatcherImpl` / `IControlledDispatcherImpl`                            | Tiny shim: `Signal()`, `UpdateTimer()`, `RunLoop()`, `Now`.                     |
| Render pacing        | `IRenderTimer` (`CVDisplayLink`, `SleepLoopRenderTimer`, DComp/DXGI)       | Drives the composition render loop off the UI thread.                           |
| Native handle        | `IPlatformHandle` (e.g. `"HWND"`, `"XID"`, `IMacOSTopLevelPlatformHandle`) | Escape hatch to the raw OS handle.                                              |

### The loop: a managed `Dispatcher` over a native pump

The heart of the design is that the **managed `Dispatcher` does not own a loop of its own** — it delegates to a per-platform `IControlledDispatcherImpl.RunLoop`. `Dispatcher.MainLoop` simply pushes a `DispatcherFrame`, and the frame's `Run` calls into the platform impl:

```cs
// src/Avalonia.Base/Threading/Dispatcher.MainLoop.cs
public void MainLoop(CancellationToken cancellationToken)
{
    if (_controlledImpl == null)
        throw new PlatformNotSupportedException();
    var frame = new DispatcherFrame();
    cancellationToken.Register(() => frame.Continue = false);
    PushFrame(frame);
}
```

The split is captured by three interfaces in [`src/Avalonia.Base/Threading/IDispatcherImpl.cs`][dispatcher-impl]: `IDispatcherImpl` (every backend — `Signal`, `Timer`, `Now`, `UpdateTimer`), `IDispatcherImplWithPendingInput` (can it tell whether OS input is queued?), and `IControlledDispatcherImpl` (it owns a runnable native loop). The `Dispatcher` schedules work in WPF-style priority bands defined in `DispatcherPriority.cs`: jobs above `Input` run _before_ the OS processes pending input; `Input`-priority jobs run after; `Background`/`ContextIdle` run only when the queue is otherwise empty. This is why the dispatcher needs `HasPendingInput` — it must interleave its own queue with native input correctly.

> [!NOTE]
> Loop ownership differs per platform but the _managed_ contract is identical everywhere. Win32 and X11 run their own `while` loop; macOS hands control to `[NSApp run]`; the same `Dispatcher` sits on top of all three. See [readiness-vs-completion-windowing][concept-readiness] for how this readiness-style fd/message pumping contrasts with completion models.

---

## 1. Window creation & lifecycle

Every backend implements `IWindowingPlatform.CreateWindow()` returning an `IWindowImpl`. The attribute model is the big `IWindowImpl` interface ([`IWindowImpl.cs`][window-impl]): `SetTitle`, `WindowState`, `SetWindowDecorations`, `Resize`, `Move`, `SetMinMaxSize`, `BeginMoveDrag`/`BeginResizeDrag`, `SetExtendClientAreaToDecorationsHint`, `ShowTaskbarIcon`, `CanResize`/`SetCanMinimize`/`SetCanMaximize`.

**Win32** — `WindowImpl.CreateWindow()` registers a unique window class per window (`$"Avalonia-{Guid}"`) with `CS_OWNDC | CS_HREDRAW | CS_VREDRAW`, then `CreateWindowEx`:

```cs
// src/Windows/Avalonia.Win32/WindowImpl.cs  (CreateWindowOverride)
return CreateWindowEx(
    UseRedirectionBitmap ? 0 : (int)WindowStyles.WS_EX_NOREDIRECTIONBITMAP,
    atom, null,
    (int)WindowStyles.WS_OVERLAPPEDWINDOW | (int)WindowStyles.WS_CLIPCHILDREN,
    CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
    IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
```

The `WS_EX_NOREDIRECTIONBITMAP` style is chosen when transparency/composition is wanted (it removes the DWM redirection bitmap so a swap-chain can be composited). Immediately after creation Win32 calls `RegisterTouchWindow` and queries per-monitor DPI via `GetDpiForMonitor`. Handle is exposed as `"HWND"`.

**X11** — `X11Window` calls `XCreateWindow` against the root window with an explicit `XSetWindowAttributes` (colormap chosen from a GLX/EGL or transparent visual). It optionally creates a _separate child render window_ (`_renderHandle`) because "OpenGL seems to do weird things to its current window which breaks resize sometimes" ([`X11Window.cs:126`][x11window]). It then `XSetWMProtocols(WM_DELETE_WINDOW)` and sets `_NET_WM_WINDOW_TYPE`. Handle is `new PlatformHandle(_handle, "XID")`. Note X11 maps the window immediately (decorations come from the WM), unlike Wayland's [no-buffer-no-window][concept-nbnw] rule — which Avalonia never has to handle, having no Wayland backend.

**macOS** — `AvnWindow` (an `NSWindow` subclass) is created in the Obj-C++ shim:

```objc
// native/Avalonia.Native/src/OSX/AvnWindow.mm
self = [super initWithContentRect:contentRect styleMask: styleMask
                          backing:NSBackingStoreBuffered defer:false];
[self setReleasedWhenClosed:false];
[self setOpaque:NO];
```

The `defer:false` is deliberate (an explicit `contentRect` avoids a documented AppKit resize bug). `setOpaque:NO` keeps every window transparency-capable. The native `NSWindow`/`NSView` are reachable through `IMacOSTopLevelPlatformHandle` (`NSView`, `NSWindow`, plus retained variants).

**Attribute support gaps:** `IWindowImpl.WindowStateGetterIsUsable` exists precisely because some WMs cannot report state reliably — when false, `Window` tracks state only via the setter + `WindowStateChanged` callback. `AllowedWindowActions`/`PlatformAllowedWindowActions` let a backend advertise that, e.g., a tiling WM forbids maximize. Many decoration knobs are advisory: `IsClientAreaExtendedToDecorations` and `NeedsManagedDecorations` report whether the platform could honour client-side decoration extension.

**Destruction ordering:** Win32 defers cleanup — `AfterCloseCleanup` is `Post`ed to the dispatcher rather than run inline in `WM_CLOSE`, and the window class is `UnregisterClass`'d only after the HWND is gone. `Closing` returns a `bool` to veto destruction.

---

## 2. Event loop

Ownership is **hybrid** and per-platform; the managed `Dispatcher` is constant.

**Win32** — `Win32DispatcherImpl` is an `IControlledDispatcherImpl`. Its `RunLoop` is the classic message pump, and `Signal()` posts a private message so dispatcher work jumps the input queue:

```cs
// src/Windows/Avalonia.Win32/Win32DispatcherImpl.cs
public void RunLoop(CancellationToken cancellationToken)
{
    var result = 0;
    while (!cancellationToken.IsCancellationRequested
           && (result = GetMessage(out var msg, IntPtr.Zero, 0, 0)) > 0)
    {
        TranslateMessage(ref msg);
        DispatchMessage(ref msg);
    }
    // ...
}

public void Signal() =>
    // Messages from PostMessage are always processed before any user input
    PostMessage(_messageWindow, (int)WindowsMessage.WM_DISPATCH_WORK_ITEM,
        new IntPtr(SignalW), new IntPtr(SignalL));
```

`HasPendingInput` uses `MsgWaitForMultipleObjectsEx(..., QS_INPUT | QS_EVENT | QS_POSTMESSAGE, MWMO_INPUTAVAILABLE)` rather than `GetQueueStatus`, because (per the verbatim in-source comment) `GetQueueStatus` "only counts 'new' input … This results in very hard to find bugs." Timers use `SetTimer`/`KillTimer` with a dedicated `TIMERID_DISPATCHER`. The [Win32 modal resize/move loop][concept-modal] is handled by tagging the resize reason between `WM_ENTERSIZEMOVE` and `WM_EXITSIZEMOVE` (`_resizeReason = WindowResizeReason.User`) so resizes during the modal loop are attributed correctly.

**X11** — `X11PlatformThreading` (also `IControlledDispatcherImpl`) multiplexes the X11 connection fd with a self-pipe under `epoll`. In the constructor it `epoll_ctl(EPOLL_CTL_ADD)`s both `_x11Events.Fd` (tagged `EventCodes.X11`) and the read end of a `pipe2(O_NONBLOCK)` (`EventCodes.Signal`). `RunLoop` flushes Xlib, then blocks in `epoll_wait` with a timeout derived from the next dispatcher timer:

```cs
// src/Avalonia.X11/Dispatching/X11PlatformThreading.cs  (RunLoop, abridged)
_x11Events.Flush();
if (!_x11Events.IsPending)
{
    var timeout = _nextTimer == null ? (int)-1 : Math.Max(1, _nextTimer.Value - now);
    epoll_wait(_epoll, &ev, 1, (int)Math.Min(int.MaxValue, timeout));
    // Drain the signaled pipe
    int buf = 0;
    while (read(_sigread, &buf, new IntPtr(4)).ToInt64() > 0) { }
}
CheckSignaled();
_x11Events.DispatchX11Events(cancellationToken);
```

`Signal()` writes one byte into the pipe (`Wakeup`) so a blocked `epoll_wait` returns. Cross-thread `Dispatcher.Post` from another thread therefore wakes the X11 loop via the pipe. An optional **GLib** dispatcher (`UseGLibMainLoop`, see [`GLibDispatcherImpl.cs`][glib-dispatcher]) lets Avalonia cohabit a thread with another GLib/GTK toolkit — added in [#17281][glib-pr].

**macOS** — control is given to AppKit. `PlatformThreadingInterface::RunLoop` either starts the app (`[NSApp run]`) or, when already running (nested frames), pumps events manually with `nextEventMatchingMask`:

```objc
// native/Avalonia.Native/src/OSX/platformthreading.mm  (RunLoop)
if(![NSApp isRunning]) { can->IsApp = true; [NSApp run]; return; }
else {
    while(!can->Cancelled) { @autoreleasepool {
        NSEvent* ev = [NSApp nextEventMatchingMask:NSEventMaskAny
                       untilDate:[NSDate dateWithTimeIntervalSinceNow:1]
                       inMode:NSDefaultRunLoopMode dequeue:true];
        if(ev != NULL) [NSApp sendEvent:ev];
    }}
}
```

Dispatcher signalling on macOS goes through `dispatch_async(dispatch_get_main_queue(), …)` + `CFRunLoopWakeUp`, and a `CFRunLoopObserver` on `kCFRunLoopBeforeWaiting` drains signalled work and fires `ReadyForBackgroundProcessing` — i.e. background work is run right before the `CFRunLoop` would sleep. Timers are a single repeating `CFRunLoopTimer` whose fire date is reset via `CFRunLoopTimerSetNextFireDate` (set to a "distant future" 50-year interval when idle, exactly as Apple's docs recommend).

**Frame pacing / vsync.** Rendering runs on a separate render loop driven by an `IRenderTimer`. macOS uses a real `CVDisplayLink` (`PlatformRenderTimer.mm`: `CVDisplayLinkCreateWithActiveCGDisplays` + `CVDisplayLinkSetOutputCallback`). X11 has **no vsync source** — it falls back to a fixed-rate clock: `options.ShouldRenderOnUIThread ? new UiThreadRenderTimer(60) : new SleepLoopRenderTimer(60)` ([`X11Platform.cs:77`][x11platform]). Win32 uses DXGI/DirectComposition where available (`DxgiConnection`, `DirectCompositionConnection`).

> [!WARNING]
> The X11 60 Hz `SleepLoopRenderTimer` is a sleep-based timer, **not** a true vsync ([frame-callback-vsync][concept-vsync] / X11 `Present`). On high-refresh or fractional-refresh displays this can produce tearing/judder that a Wayland frame-callback or `CVDisplayLink` backend avoids.

---

## 3. Input

**Keyboard model.** Avalonia separates a [scancode/keysym/virtual-key][concept-keys] triple into a layout-independent `PhysicalKey` (scancode → physical position) and a layout-dependent `Key`. Crucially, on X11 it does **not** use `xkbcommon`; it ships its own hard-coded scancode→`PhysicalKey` table in `X11KeyTransform.cs` (ordered to match Chromium's `dom_code_data.inc`) and uses raw Xlib `XLookupString` for the text/keysym, with `XkbSetDetectableAutoRepeat` to suppress synthetic release events:

```cs
// src/Avalonia.X11/X11Globals.cs
if (_x11.HasXkb)
{
    nint supportsDetectable = 0;
    XkbSetDetectableAutoRepeat(_x11.Display, true, supportsDetectable);
}
```

> [!NOTE]
> Because X11 (the server) owns key-repeat, Avalonia's X11 backend does **not** synthesize repeats client-side. A native Wayland backend would have to — Wayland delegates repeat to the client (rate/delay come from `wl_keyboard.repeat_info`). This is one of the items the Wayland WIP ([#1243][wayland-issue]) must implement that X11 gets for free.

Win32 maps `WM_KEYDOWN`/`WM_SYSKEYDOWN` to virtual keys; macOS maps via `KeyTransform.mm`.

**IME / text input.** Each platform uses the native protocol, and key events are kept separate from composition:

- **Win32 uses legacy IMM32, not TSF.** `Imm32InputMethod.Current` handles `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION`/`WM_IME_ENDCOMPOSITION`; while composing, `WM_CHAR` is swallowed (`if (Imm32InputMethod.Current.IsComposing) …`). `WM_INPUTLANGCHANGE` re-syncs the layout via `UpdateInputMethod(GetKeyboardLayout(0))`. (No Text Services Framework integration exists — a known limitation.)
- **macOS implements `NSTextInputClient`** on `AvnView`: `setMarkedText:selectedRange:replacementRange:`, `insertText:replacementRange:`, `unmarkText`, `firstRectForCharacterRange:` (candidate-window positioning), routed through `[self inputContext] handleEvent:`.
- **X11 picks an IME at startup**: it prefers a DBus IME (IBus/Fcitx5) detected from `AVALONIA_IM_MODULE`/`GTK_IM_MODULE`/`QT_IM_MODULE`/`XMODIFIERS` in `X11DBusImeHelper.DetectInputMethod`, falling back to **XIM** (`XCreateIC` with `XIMPreeditPosition | XIMStatusNothing`, see `X11Window.Ime.cs`/`X11Window.Xim.cs`). [pre-edit/composition][concept-preedit] is buffered in an `_imeQueue` so key events and committed text don't race.

**Pointer.** `RawPointerEventArgs` carry position, modifiers, and pointer type (mouse/pen/touch). High-resolution / [accelerated pointer][concept-pointer] data:

- Win32 mouse wheel divides the raw delta by `WHEEL_DELTA` (120): `new Vector(0, (ToInt32(wParam) >> 16) / wheelDelta)` for `WM_MOUSEWHEEL`. When `IsMouseInPointerEnabled`, it instead handles the `WM_POINTER*` family (`WM_POINTERWHEEL`, `WM_POINTERUPDATE`, …) for unified pen/touch/mouse with sub-pixel data.
- Win32 has full **touch** (`WM_TOUCH` + `RegisterTouchWindow`) and the newer `WM_POINTER` stack.
- macOS pointer/scroll comes through `NSEvent` (momentum phases available via AppKit).

**Cursor.** Each backend implements `ICursorFactory`/`ICursorImpl` (`X11CursorFactory`, Win32 `CursorFactory`, native `Cursor.cs`). X11 uses client-side cursor themes; there is no `cursor_shape_v1` because there is no Wayland backend.

---

## 4. Wayland specifics

> [!IMPORTANT]
> **Avalonia has no native Wayland backend.** On Linux it is X11-only; under a Wayland session it runs via **XWayland**. There is no `wl_surface`, `xdg_toplevel`, `xdg-decoration`, `libdecor`, `fractional-scale-v1`, `viewporter`, `xdg-activation`, or `layer-shell` code in the tree — `find src -iname "*wayland*"` returns nothing under the platform backends. (`Avalonia.X11/NativeDialogs/Gtk.cs` and an unrelated `IPortalParentLease.cs` are the only string matches.)

Native Wayland is tracked by **[issue #1243 "Our own backend for Wayland"][wayland-issue]**, opened 2017-10-22 by maintainer `kekekeks` and (at this checkout) still attached to milestone 12.1. The issue states the motivation for _not_ going through GTK/GDK:

> There are way too many limitations and tradeoffs that GTK/GDK have to support both of them, while not allowing us to do things that we want to do.
>
> — [#1243][wayland-issue]

The blocking concerns it enumerates are exactly the windowing-layer hard parts: system dialogs (would need GTK or out-of-process portals with modality), IME (currently GTK-coupled), and **client-side decorations** required by some Wayland shells (X11 lets the WM draw them). A WIP backend PR ([#8352][wayland-pr]) exists alongside the org's `NWayland` .NET bindings, and the wiki page ["Wayland limitations that we aren't ready for"][wayland-wiki] catalogs the gaps (e.g. absolute positioning, no global coordinates). For now, any reader comparing Avalonia against a Wayland-native toolkit should treat its Linux story as "X11 + XWayland", with all the [CSD-vs-SSD][concept-csd] decisions still living in the WM.

---

## 5. DPI & scaling

The native unit is **logical (DIPs)**; `ITopLevelImpl` exposes `RenderScaling` (for the render surface) and `DesktopScaling` (for positioning), and raises `ScalingChanged`. See [logical-vs-physical-coords][concept-coords] and [scale-factor][concept-scale].

**Win32** sets process DPI awareness up front, preferring per-monitor v2:

```cs
// src/Windows/Avalonia.Win32/Win32Platform.cs  (DPI awareness selection)
if (SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) ||
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE))
    // ...
```

Per-monitor changes are handled in the [`WM_DPICHANGED`][concept-scale] message: it reads the new DPI from `wParam >> 16`, updates `_scaling`, fires `ScalingChanged`, and **repositions the window to the suggested rect** passed in `lParam` (`SetWindowPos` with the DPI-change resize reason) — the standard `WM_DPICHANGED` "use the OS-suggested rectangle" dance. Initial DPI is read at creation via `GetDpiForMonitor(MDT_EFFECTIVE_DPI)`.

**macOS** uses AppKit backing scale (`NSWindow`/`NSScreen.backingScaleFactor`), surfaced as `RenderScaling`.

**X11 has no first-class scale protocol**, so it _guesses_ via a pluggable `IScalingProvider` ([`X11Screens.Scaling.cs`][x11scaling]). Resolution order: `AVALONIA_GLOBAL_SCALE_FACTOR` / `AVALONIA_SCREEN_SCALE_FACTORS` (then the `QT_*` equivalents) → physical-DPI auto-guess (`PhysicalDpiScalingProvider`, snapping to "sane" densities 1/1.25/1.5/1.75/2) → otherwise the `Xft.dpi` X resource (`XrdbScalingProvider`, `factor = parsed / 96`). A `PostMultiplyScalingProvider` applies a global multiplier on top.

> [!WARNING]
> Because X11 scaling is heuristic and read from `Xft.dpi`/env vars, **mixed-DPI multi-monitor on X11 is approximate**: dragging a window between monitors of different scale relies on per-screen `GetScaling(screen, index)` and a re-scale, not a true protocol event. This is a recurring user complaint (e.g. blurry HiDPI under Ubuntu, [discussion #13450][hidpi-discussion]). macOS and Win32 v2 get crisp per-monitor scaling; X11 is best-effort.

---

## 6. Multi-window & popups

**Popups** (menus, tooltips, flyouts, combo dropdowns) are `IPopupImpl`. Their placement is computed by Avalonia itself via `IPopupPositioner`. On X11 and macOS popups are created as **borderless top-levels positioned by `ManagedPopupPositioner`** ([`ManagedPopupPositioner.cs`][popup-positioner]) — Avalonia does the flip/slide/constrain math against the screen rect, rather than handing it to the compositor:

- **X11:** popups are `override_redirect` windows ([override-redirect][concept-override]). `X11Window`'s constructor sets `attr.override_redirect = 1` whenever `_popup || overrideRedirect`, bypassing the WM entirely, and wires a `ManagedPopupPositioner`. There is no `xdg_popup` grab semantics because there is no Wayland — Avalonia approximates pointer-grab dismissal itself.
- **macOS:** `PopupImpl` creates a window with `NSWindowStyleMaskBorderless`.
- **Win32:** `PopupImpl` (a `WindowImpl` subclass) uses a popup window style.

**Modal dialogs:** `IWindowImpl.SetEnabled(false)` disables a parent while a modal child is open, and `GotInputWhenDisabled` fires when the disabled parent is clicked (so the modal child can be re-activated/flashed). `SetParent` establishes the owner relationship for stacking. Z-order across windows is queryable via `IWindowingPlatform.GetWindowsZOrder`.

> [!NOTE]
> Because popups are managed-positioned `override_redirect`/borderless windows, the [override-redirect vs xdg_popup grab][concept-override] distinction is moot for Avalonia today: it never gets compositor-enforced popup grabs and instead emulates dismissal. A future Wayland backend would have to adopt real `xdg_popup` grab semantics — exactly the kind of behaviour `ManagedPopupPositioner` cannot express.

---

## 7. Threading

Windows must be created and driven on the **UI (dispatcher) thread**; events are delivered on that same thread. `Dispatcher.VerifyAccess()` / `CheckAccess()` enforce this:

```cs
// src/Avalonia.Base/Threading/Dispatcher.cs
public bool CheckAccess() => Thread.CurrentThread == _thread;
public void VerifyAccess() { if (!CheckAccess()) /* throws */ }
```

The hard constraint is **macOS**: AppKit requires all UI on the main thread, so the entire Avalonia UI thread _is_ the macOS main thread. `PlatformThreadingInterface::GetCurrentThreadIsLoopThread` is literally `[NSThread isMainThread]`, and `LoopCancellation::Cancel` bounces to the main queue (`dispatch_async(dispatch_get_main_queue(), …)`) if called off-thread before `[NSApp stop:]`. Win32 and X11 are more relaxed (any thread can be the loop thread) but conventionally use the startup thread.

**Off-thread rendering:** yes — the Skia compositor runs its render passes on a **separate render thread**, paced by the `IRenderTimer` (`ThreadProxyRenderTimer` marshals the tick). The UI thread builds the scene graph; the render thread rasterizes. As of Avalonia 12 the dispatcher supports **multiple dispatchers, one per thread**, so non-UI threads can have their own loops; `Dispatcher.UIThread` remains the canonical app loop.

---

## 8. Clipboard & DnD

Clipboard is an `IClipboard` feature obtained via `TryGetFeature` on the top-level; data is exchanged through `IAsyncDataTransfer` with MIME-like format negotiation.

- **Win32** wraps OLE: `ClipboardImpl.SetDataAsync` builds a `Win32Com.IDataObject` (via the MicroCom wrapper) and hands it to `OleSetClipboard`; reads create a MicroCom proxy over the returned `IDataObject`. DnD uses the OLE drag source/drop target (`OleDragSource`, `OleDropTarget`, `DragSource.cs`). Delayed rendering is expressible through the OLE `IDataObject` model (formats materialized on demand).
- **X11** implements the full selection protocol in `Clipboard/X11Clipboard.cs` + `ClipboardReadSession.cs`, including **INCR** chunked transfer for large payloads: it both _advertises_ INCR (`XChangeProperty(..., _x11.Atoms.INCR, ...)`) when sending and _consumes_ it (`if (res.ActualTypeAtom == _x11.Atoms.INCR)`) when receiving. `PRIMARY` and `CLIPBOARD` selections are handled.
- **macOS** uses `NSPasteboard` via `clipboard.mm` + the managed `ClipboardImpl.cs`/`ClipboardDataTransfer*`.

---

## 9. Escape hatches

The abstraction is admittedly leaky at the edges, so Avalonia exposes deliberate hatches:

- **Native handle.** `TopLevel.TryGetPlatformHandle()` returns `IPlatformHandle` whose `HandleDescriptor` is `"HWND"` / `"XID"` / etc.; on macOS, `IMacOSTopLevelPlatformHandle` exposes `NSView`/`NSWindow` (and retained variants).
- **Win32 WndProc hook.** `IWin32OptionsTopLevelImpl.WndProcHookCallback` lets an app intercept _every_ window message before Avalonia handles it:

  ```cs
  // src/Windows/Avalonia.Win32/WindowImpl.cs  (WndProcMessageHandler)
  if (WndProcHookCallback is { } callback)
      ret = callback(hWnd, msg, wParam, lParam, ref handled);
  if (handled) return ret;
  return WndProc(hWnd, msg, wParam, lParam);
  ```

- **Native control host.** `INativeControlHostImpl` (`Win32NativeControlHost`, `X11NativeControlHost`, native `NativeControlHostImpl.cs`) embeds a foreign native control inside an Avalonia window — the inverse hatch.
- **Feature provider.** `ITopLevelImpl : IOptionalFeatureProvider` means a backend can expose arbitrary capabilities (`IStorageProvider`, `IInsetsManager`, `IClipboard`, `IScreenImpl`) by type, queried with `TryGetFeature<T>()`. This is how platform-specific surface area is added without widening the core interface.

The fact that `WndProcHookCallback`, INCR, and `IMacOSTopLevelPlatformHandle` all exist tells you precisely where the abstraction is known to leak: raw Win32 messages, X11 selection edge cases, and AppKit-specific window/view access.

---

## 10. History, redesigns & known regrets

- **The big dispatcher rewrite (2023).** Originally each platform implemented a chunkier `IPlatformThreadingInterface` (still present as the `LegacyDispatcherImpl` shim in [`IDispatcherImpl.cs`][dispatcher-impl]). PR [#10691 "Implemented dispatcher that works like WPF one"][dispatcher-pr] (tracked by [#10520][dispatcher-issue]) ported WPF's `Dispatcher` priority model and reduced the per-platform surface to the tiny `IDispatcherImpl`/`IControlledDispatcherImpl`. This is why backends now only implement `Signal`/`Timer`/`RunLoop`. A follow-up [#17281][glib-pr] added the GLib-based dispatcher so Avalonia can share a thread with GTK.
- **Platform-interface lockdown (Avalonia 11+).** `IWindowImpl`, `window.PlatformImpl`, and `IWindowingPlatform` were removed from the public API (now `[Unstable]`/`[PrivateApi]`); apps must go through `TryGetPlatformHandle`/features. Listed in the [breaking-changes wiki][breaking-changes] and [Avalonia 12 breaking changes][avalonia12-breaking]. The regret being addressed: too many apps had hard-coded against unstable internals.
- **macOS via a C++ shim, not pure P/Invoke.** AppKit is reached through `libAvaloniaNative` (Obj-C++) over a MicroCom ABI generated from [`avn.idl`][avn-idl]. The trade-off is a build dependency on Xcode/clang and an extra interop layer, chosen because driving Obj-C runtime + `NSApplication` purely from managed P/Invoke proved fragile. Multiple dispatcher `Signaler`/`ObserverHolder` gymnastics in `platformthreading.mm` (re-creating a `CFRunLoopObserver` when already inside a callback) are scar tissue from nested-loop reentrancy bugs.
- **No Wayland, since 2017.** [#1243][wayland-issue] has been open the entire modern history of the project; the multi-year delay is itself the lesson — a from-scratch toolkit that punts on Wayland inherits XWayland's limits (no fractional scale protocol, approximate HiDPI, no `xdg_popup` grabs). A [three-year sponsorship][sponsorship] was announced to fund the roadmap that includes it.
- **X11 render pacing.** The fixed 60 Hz `SleepLoopRenderTimer` has no vsync; on Wayland/HiDPI/high-refresh setups this is a recurring visual-quality complaint that a native backend would fix.

---

## Strengths

- **One windowing abstraction, six backends.** `IWindowImpl`/`ITopLevelImpl` is small, consistent, and feature-probed (`IOptionalFeatureProvider`), so most of the framework never touches platform code.
- **WPF-grade dispatcher.** Priority-ordered work that correctly interleaves with native input on every OS, with cross-thread `Post`, frames, and a `SynchronizationContext` — a genuinely portable loop model.
- **Clean managed/native boundary on macOS.** MicroCom gives a typed vtable ABI instead of brittle marshalled callbacks.
- **Real native input fidelity.** Per-platform IME (IMM32/XIM/IBus/Fcitx/`NSTextInputClient`), touch + `WM_POINTER`, INCR clipboard, OLE DnD — not lowest-common-denominator.
- **Skia-everywhere rendering** decouples the windowing layer from native widget toolkits entirely.

## Weaknesses

- **No native Wayland** (X11/XWayland only) — the single biggest gap versus modern Linux toolkits ([#1243][wayland-issue]).
- **X11 DPI is heuristic** (`Xft.dpi`/env-var guessing), so mixed-DPI multi-monitor is approximate and HiDPI can be blurry ([#13450][hidpi-discussion]).
- **X11 has no vsync** (60 Hz sleep timer) — tearing/judder on high-refresh displays.
- **Win32 uses legacy IMM32, not TSF** — weaker advanced-IME and accessibility integration than a TSF client.
- **Managed-runtime input latency surface.** Every native event crosses the managed boundary and is subject to GC; a long Gen2 pause can stall the UI loop. (Mitigated by off-thread rendering and the dispatcher's priority bands, but inherent to a managed UI thread.) [inference]
- **Popups are emulated** (`override_redirect`/borderless + `ManagedPopupPositioner`) rather than compositor-grabbed, so dismissal/stacking edge cases are Avalonia's problem.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                            | Trade-off                                                                                       |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- |
| Own the window, render everything with Skia                         | Pixel-identical UI on all platforms; no native-widget wrapping                       | Must reimplement IME, DnD, a11y, decorations per platform; no native control look-and-feel      |
| WPF-style managed `Dispatcher` over a tiny per-platform loop shim   | One portable loop/priority model; backends implement only `Signal`/`Timer`/`RunLoop` | Managed thread on the hot input path; GC can perturb latency; nested-loop reentrancy is subtle  |
| macOS through an Obj-C++ shim over a MicroCom ABI                   | Robustly drives `NSApplication`/AppKit; typed vtable boundary                        | Xcode/clang build dependency; extra interop layer to maintain                                   |
| X11-only on Linux (XWayland for Wayland sessions)                   | Ship Linux support without GTK's constraints; X11 is mature and WM-decorated         | No fractional scale, approximate HiDPI, no vsync, no `xdg_popup` grabs; Wayland open since 2017 |
| Popups as managed-positioned borderless/`override_redirect` windows | Uniform popup placement across X11/macOS/Win32 without compositor support            | No compositor-enforced grab; dismissal/stacking emulated; won't map cleanly onto `xdg_popup`    |
| Heuristic X11 scaling (`Xft.dpi`/env vars, snapped densities)       | No X11 scale protocol exists; gives _some_ HiDPI on most setups                      | Wrong/blurry on mixed-DPI; needs env-var overrides for correctness                              |
| `[Unstable]`/`[PrivateApi]` platform interfaces (11+)               | Free the team to refactor backends; push apps onto stable handles/features           | Apps lose direct low-level access; must use escape hatches (`WndProcHookCallback`, handles)     |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **two-layer loop split** — a portable priority `Dispatcher` whose backends implement only `Signal`/`UpdateTimer`/`RunLoop`/`HasPendingInput`. It is the cleanest way seen here to get WPF-grade scheduling on top of `GetMessage`, `CFRunLoop`, and `epoll` alike without per-platform queue logic.
- **`IOptionalFeatureProvider` capability probing** (`TryGetFeature<T>()`) instead of an ever-widening window interface — the right way to handle platform-specific surface area.
- **A typed COM-style ABI (MicroCom) for the native boundary** when a native shim is unavoidable (macOS) — far more maintainable than hand-rolled P/Invoke marshalling.
- The honest **escape-hatch set** (`WndProcHookCallback`, native handles, native control host) that documents exactly where the abstraction leaks.

**Avoid / improve:**

- **Don't punt on Wayland.** Avalonia's 8-year delay shows how a from-scratch toolkit that defers Wayland inherits XWayland's ceiling (no fractional scale, no frame-callback vsync, no `xdg_popup` grabs). Design the popup/positioning and decoration model for `xdg_popup`/CSD from day one — `ManagedPopupPositioner` is a dead end against Wayland.
- **Don't ship a sleep-based render timer.** Wire vsync (`Present`, frame callbacks, `CVDisplayLink`, DXGI waitable swapchains) per platform from the start.
- **Prefer TSF over IMM32 on Windows** if advanced IME/a11y matter.
- **Make scaling protocol-driven, not heuristic.** Heuristic `Xft.dpi` scaling is a perennial bug source.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact GC-pause vs input-latency behaviour.** Whether server-GC or background-GC pauses measurably stall the dispatcher loop is not documented in-tree; the answer lives in profiling `Dispatcher.MainLoop` under load and in any perf issues on the tracker. (Marked [inference] above.)
- **Win32 high-resolution-scroll accumulation.** Avalonia divides wheel deltas by `WHEEL_DELTA` per message but I did not find sub-120 delta accumulation across messages for precision touchpads in `WindowImpl.AppWndProc.cs` — likely handled (or not) in `RawMouseWheelEventArgs` consumers in `src/Avalonia.Base/Input/`.
- **Wayland WIP fidelity.** How far PR [#8352][wayland-pr] gets on `xdg-decoration`/`libdecor`/fractional-scale is out of this checkout's tree; the answer is in that PR and the `NWayland` repo.
- **Android/iOS windowing depth.** Covered only by name here; the implementations live in `src/Android/` and `src/iOS/` and warrant their own pass.

---

## Sources

- [AvaloniaUI/Avalonia][repo] — main repository (all quoted file paths, commit [`aee3f68`][commit])
- [`src/Avalonia.Controls/Platform/ITopLevelImpl.cs`][toplevel-impl], [`IWindowImpl.cs`][window-impl] — windowing interfaces
- [`src/Avalonia.Base/Threading/IDispatcherImpl.cs`][dispatcher-impl], [`Dispatcher.MainLoop.cs`][dispatcher-mainloop] — managed loop model
- [`src/Windows/Avalonia.Win32/Win32DispatcherImpl.cs`][win32-dispatcher], [`WindowImpl.cs`][win32-window], [`WindowImpl.AppWndProc.cs`][win32-appwndproc] — Win32 backend
- [`src/Avalonia.X11/Dispatching/X11PlatformThreading.cs`][x11-threading], [`X11Window.cs`][x11window], [`Screens/X11Screens.Scaling.cs`][x11scaling] — X11 backend
- [`native/Avalonia.Native/src/OSX/platformthreading.mm`][osx-threading], [`AvnWindow.mm`][osx-window], [`PlatformRenderTimer.mm`][osx-rendertimer] — macOS Obj-C++ shim
- Issues/PRs: Wayland [#1243][wayland-issue] / [#8352][wayland-pr] / [wiki][wayland-wiki]; dispatcher rewrite [#10520][dispatcher-issue] / [#10691][dispatcher-pr]; GLib loop [#17281][glib-pr]; sponsorship [#19108][sponsorship]; HiDPI [#13450][hidpi-discussion]
- [Threading model docs][threading-docs], [Avalonia 12 breaking changes][avalonia12-breaking], [Breaking Changes wiki][breaking-changes]
- Sibling docs: [concepts][concepts], [ui-layout survey][ui-layout], [async-io survey][async-io]

<!-- References -->

[repo]: https://github.com/AvaloniaUI/Avalonia
[commit]: https://github.com/AvaloniaUI/Avalonia/commit/aee3f68551b0ac4417e32996a6627f34462edbc3
[docs]: https://docs.avaloniaui.net/
[apidocs]: https://api-docs.avaloniaui.net/
[Skia]: https://skia.org/
[toplevel-impl]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/Platform/ITopLevelImpl.cs
[window-impl]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/Platform/IWindowImpl.cs
[dispatcher-impl]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Threading/IDispatcherImpl.cs
[dispatcher-mainloop]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Base/Threading/Dispatcher.MainLoop.cs
[win32-dispatcher]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Windows/Avalonia.Win32/Win32DispatcherImpl.cs
[win32-window]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Windows/Avalonia.Win32/WindowImpl.cs
[win32-appwndproc]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Windows/Avalonia.Win32/WindowImpl.AppWndProc.cs
[x11platform]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.X11/X11Platform.cs
[x11-threading]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.X11/Dispatching/X11PlatformThreading.cs
[x11window]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.X11/X11Window.cs
[x11scaling]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.X11/Screens/X11Screens.Scaling.cs
[glib-dispatcher]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.X11/Dispatching/GLibDispatcherImpl.cs
[osx-threading]: https://github.com/AvaloniaUI/Avalonia/blob/master/native/Avalonia.Native/src/OSX/platformthreading.mm
[osx-window]: https://github.com/AvaloniaUI/Avalonia/blob/master/native/Avalonia.Native/src/OSX/AvnWindow.mm
[osx-rendertimer]: https://github.com/AvaloniaUI/Avalonia/blob/master/native/Avalonia.Native/src/OSX/PlatformRenderTimer.mm
[avn-idl]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Native/avn.idl
[popup-positioner]: https://github.com/AvaloniaUI/Avalonia/blob/master/src/Avalonia.Controls/Primitives/PopupPositioning/ManagedPopupPositioner.cs
[wayland-issue]: https://github.com/AvaloniaUI/Avalonia/issues/1243
[wayland-pr]: https://github.com/AvaloniaUI/Avalonia/pull/8352
[wayland-wiki]: https://github.com/AvaloniaUI/Avalonia/wiki/Wayland-limitations-that-we-aren't-ready-for
[dispatcher-issue]: https://github.com/AvaloniaUI/Avalonia/issues/10520
[dispatcher-pr]: https://github.com/AvaloniaUI/Avalonia/pull/10691
[glib-pr]: https://github.com/AvaloniaUI/Avalonia/pull/17281
[sponsorship]: https://github.com/AvaloniaUI/Avalonia/discussions/19108
[hidpi-discussion]: https://github.com/AvaloniaUI/Avalonia/discussions/13450
[threading-docs]: https://docs.avaloniaui.net/docs/app-development/threading
[avalonia12-breaking]: https://docs.avaloniaui.net/docs/avalonia12-breaking-changes
[breaking-changes]: https://github.com/AvaloniaUI/Avalonia/wiki/Breaking-Changes
[concepts]: ./concepts.md
[concept-readiness]: ./concepts.md#readiness-vs-completion-windowing
[concept-keys]: ./concepts.md#scancode-keysym-virtualkey
[concept-coords]: ./concepts.md#logical-vs-physical-coords
[concept-scale]: ./concepts.md#scale-factor
[concept-preedit]: ./concepts.md#pre-edit-composition
[concept-override]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[concept-modal]: ./concepts.md#win32-modal-resize-loop
[concept-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[concept-nbnw]: ./concepts.md#no-buffer-no-window
[concept-vsync]: ./concepts.md#frame-callback-vsync
[concept-csd]: ./concepts.md#client-vs-server-decoration
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
