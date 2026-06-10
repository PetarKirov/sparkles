# Uno Platform (C# / .NET)

A re-implementation of the WinUI 3 / Windows App SDK API surface over [Skia][skia], with a family of native "Skia desktop" hosts — genuine, hand-written [X11], Linux DRM/framebuffer, [Win32], and [AppKit][appkit] backends — that each own window creation, the event loop, and input, then hand pixels to a shared Skia compositor.

| Field                  | Value                                                                                                                                                  |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Version/commit studied | `df5d18a850248cb8c2ccb34032b4ebeb54dc8283` (`6.7-dev`, June 2026)                                                                                      |
| Language               | C# (.NET 8/9); macOS host has an Objective-C companion library (`UnoNativeMac`)                                                                        |
| License                | Apache-2.0                                                                                                                                             |
| Repository             | [unoplatform/uno]                                                                                                                                      |
| Documentation          | [Using the Skia Desktop][uno-skia-desktop]                                                                                                             |
| Category               | WinUI-over-Skia framework (cross-platform application framework, not a thin windowing library)                                                         |
| Platforms covered      | X11 (Linux), Linux framebuffer/DRM, Win32 (Windows), macOS/AppKit; Android & iOS via separate Skia heads; Wayland only via XWayland (no native client) |
| Loop ownership         | **Hybrid, per-platform**: X11 & Win32 — Uno owns the loop; macOS — AppKit (`NSApplicationMain`) owns it                                                |
| Repo paths (platform)  | `src/Uno.UI.Runtime.Skia.X11/`, `src/Uno.UI.Runtime.Skia.Linux.FrameBuffer/`, `src/Uno.UI.Runtime.Skia.Win32/`, `src/Uno.UI.Runtime.Skia.MacOS/`       |

---

## Overview

### What it solves

Uno Platform lets a single C#/XAML codebase that targets Microsoft's WinUI API run on Linux, Windows, macOS, the browser (WebAssembly), Android, and iOS. For the desktop, the interesting artifact is the **Skia desktop host family** introduced in Uno 5.2 (April–May 2024), which replaced the old GTK+3-based Linux/macOS heads with backends that talk to each platform's window system directly. The official docs state the scope plainly:

> The currently supported targets and platforms are: Linux X11, Linux Framebuffer, Windows (Using Win32 shell), macOS (Using an AppKit shell).
>
> — [Using the Skia Desktop][uno-skia-desktop]

What makes Uno unusual in this survey is that the **X11 host is a from-scratch X11 client written entirely in managed C#** — `XOpenDisplay`, `XCreateWindow`, XI2, XRandR, ICCCM/EWMH, XDND, and even an IBus/Fcitx [IME][pre-edit-composition] client are all P/Invoked from `Uno.UI.Runtime.Skia.X11`. The Win32 host is likewise a managed Win32 client (via [CsWin32]-generated P/Invoke), and the macOS host is a thin Objective-C library (`UnoNativeMac`) driven by managed callbacks. There is no SDL, GLFW, or GTK underneath the desktop hosts.

> [!NOTE]
> This survey is **scoped to the windowing layer** (window lifecycle, event loop, input, presentation hand-off). Uno's WinUI control library, XAML layout, and the Skia render pipeline are out of scope except where they constrain windowing. For layout see the companion [ui-layout catalog][ui-layout]; for event-loop/async-runtime overlap see [async-io][async-io].

### Design philosophy

- **One WinUI API, many heads.** Each host implements the same internal contracts — `IXamlRootHost`, `INativeWindowWrapper` (`NativeWindowWrapperBase`), `INativeOverlappedPresenter`, `IUnoKeyboardInputSource`, `IUnoCorePointerInputSource`, `IDisplayInformationExtension`, `IClipboardExtension`, `IDragDropExtension` — and registers them through `ApiExtensibility.Register` in the host's static constructor (e.g. `X11ApplicationHost`'s `static` ctor, `src/Uno.UI.Runtime.Skia.X11/Hosting/X11ApplicationHost.cs:44`). The WinUI-facing code is platform-agnostic; the host supplies the window-system glue.
- **Managed where possible, native where required.** X11 and Win32 are reachable purely through P/Invoke, so those hosts are pure C#. AppKit's object model (`NSWindow` subclassing, `NSTextInputClient`, `sendEvent:` overrides) cannot be expressed from managed code, so macOS ships a small Objective-C shim and calls into it.
- **Skia is the single rasterizer; the host only owns the surface.** Every host creates a window, picks a rendering surface (Vulkan → OpenGL/GLX/EGL → software, or Metal on macOS), and lets the shared `Uno.UI.Runtime.Skia` compositor draw into it. The host's job is window + loop + input, not drawing.
- **Degrade, don't crash.** The X11 host's renderer selection tries Vulkan, then GLX, then EGL/GLES, then software, catching exceptions at each step (`X11XamlRootHost.Initialize`, `src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.cs:383-460`); macOS falls back from Metal to software.

---

## How it works

Each `Window` maps to one host object that implements `IXamlRootHost`. The lifecycle differs sharply by platform because **loop ownership differs**.

### The three loop-ownership models

`SkiaHost` (shared base) exposes two overridable hooks, `Initialize()` and `RunLoop()`. Each host fills them differently:

- **X11** spins up a managed `EventLoop` thread (the WinUI dispatcher thread), plus a dedicated X11-event thread per window, plus a render thread; the "main" thread is just a keep-alive sleeper. `X11ApplicationHost.RunLoop` (`src/Uno.UI.Runtime.Skia.X11/Hosting/X11ApplicationHost.cs:210`):

```cs
// src/Uno.UI.Runtime.Skia.X11/Hosting/X11ApplicationHost.cs
protected override Task RunLoop()
{
    Thread.CurrentThread.Name = "Main Thread (keep-alive)";
    _eventLoop.Schedule(StartApp);

    while (!ShouldExit())
    {
        Thread.Sleep(100);
    }
    return Task.CompletedTask;
}
```

- **Win32** runs a classic message pump on the calling thread, draining the queue with `GetMessage`/`PeekMessage` until all windows close (`Win32Host.RunLoop`, `src/Uno.UI.Runtime.Skia.Win32/Hosting/Win32Host.cs:150`).
- **macOS** hands the loop to AppKit and never returns until quit (`MacSkiaHost.RunLoop`, `src/Uno.UI.Runtime.Skia.MacOS/Hosting/MacSkiaHost.cs:74`):

```cs
// src/Uno.UI.Runtime.Skia.MacOS/Hosting/MacSkiaHost.cs
protected override unsafe Task RunLoop()
{
    NativeUno.uno_set_application_start_callback(&StartApp);
    // `argc` and `argv` parameters are ignored by macOS
    _ = NativeMac.NSApplicationMain(argc: 0, argv: nint.Zero);
    return Task.CompletedTask;
}
```

### The dispatcher bridge

WinUI's `CoreDispatcher` is redirected per host so `RunAsync`/`Dispatch` lands on the right thread:

- X11: `CoreDispatcher.DispatchOverride = (a, p) => _eventLoop.Schedule(a)` — a managed work queue on the "Uno Event Loop" thread.
- Win32: `CoreDispatcher.DispatchOverride = Win32EventLoop.Schedule` — `PostMessage` to a hidden `HWND_MESSAGE` window.
- macOS: `CoreDispatcher.DispatchOverride = MacOSDispatcher.DispatchNativeSingle` — `dispatch_async_f` onto the GCD main queue.

Input arrives on the host's native event thread, but is **marshalled to the dispatcher thread before touching the visual tree**. On X11 every handler does `X11XamlRootHost.QueueAction(this, …)`, which is `host.RootElement?.Dispatcher.RunAsync(CoreDispatcherPriority.High, …)` (`src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.x11events.cs:315`).

---

## 1. Window creation & lifecycle

| Platform    | Create call                                                                 | Wrapper / host                            |
| ----------- | --------------------------------------------------------------------------- | ----------------------------------------- |
| X11         | `XOpenDisplay` + two `XCreateWindow` (root anchor + top render window)      | `X11WindowWrapper` / `X11XamlRootHost`    |
| Win32       | `CreateWindowEx(WS_OVERLAPPEDWINDOW)`                                       | `Win32WindowWrapper` (is itself the host) |
| macOS       | `[[UNOWindow alloc] initWithContentRect:styleMask:…]` (`NSWindow` subclass) | `MacOSWindowHost` + native `UNOWindow`    |
| Framebuffer | DRM/KMS or `/dev/fb0` — no window manager at all                            | `FramebufferHost`                         |

**X11's two-window design is the most distinctive.** `X11XamlRootHost.Initialize` creates a software-only _root_ window that "does nothing but act as an anchor for children" plus a _top_ window (on a second `XOpenDisplay` connection) that owns the GL/Vulkan context and receives input (`src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.cs:378-460`). `CreateGLXWindow` matches a 32-bit `XVisualInfo`, creates a GLX context, and calls `XCreateWindow` with a `CWColormap` to dodge a GLX error on some drivers ([issue #21285][uno-21285], cited inline at `:534`). The window is mapped only on `ShowCore` via `XMapWindow` on both windows.

**Window-attributes model.** The cross-platform surface is WinUI's `OverlappedPresenter` / `FullScreenPresenter`, mapped to native hints per host:

| Attribute               | X11                                               | Win32                                  | macOS                                       |
| ----------------------- | ------------------------------------------------- | -------------------------------------- | ------------------------------------------- |
| Title                   | `XStoreName`/`XFetchName`                         | `SetWindowText`/`GetWindowText`        | `NSWindow.title`                            |
| Size / position         | `XResizeWindow` / `XMoveWindow`                   | `SetWindowPos`                         | `setFrame:` / `setFrameOrigin:`             |
| Min/max size            | `XSetWMNormalHints` (`PMinSize`/`PMaxSize`)       | `WM_GETMINMAXINFO` (`ptMinTrackSize`)  | `window.minSize` / `window.maxSize`         |
| Decorations / titlebar  | Motif `_MOTIF_WM_HINTS` (`SetMotifWMDecorations`) | `WM_NCCALCSIZE` strips non-client area | toggle `NSWindowStyleMaskTitled`            |
| Resizable / min / max   | Motif `_MOTIF_WM_FUNCTIONS`                       | grey-out via `WM_GETMINMAXINFO`        | toggle style-mask bits                      |
| Always-on-top           | `_NET_WM_STATE_ABOVE` (EWMH)                      | (`SetWindowPos` HWND_TOPMOST path)     | `NSWindow.level = NSStatusWindowLevel`      |
| Fullscreen              | `_NET_WM_STATE_FULLSCREEN`                        | `SW_MAXIMIZE` + strip `WS_DLGFRAME`    | `toggleFullScreen:`                         |
| Transparency / backdrop | (limited)                                         | DWM dark-mode attr                     | `NSVisualEffectView` (Mica/Acrylic mapping) |

The X11 overlapped presenter is candid that decoration control is non-standard:

> What works is using the Motif WM hints, which aren't standardized or documented anywhere
>
> — `src/Uno.UI.Runtime.Skia.X11/UI/Windowing/X11NativeOverlappedPresenter.cs:17`

It also notes that `SetIsResizable` "doesn't prevent resizing using xlib calls (e.g. `XResizeWindow`)" (`:20`), and that `SetIsModal` is a stub `// TODO: modal windows` (`:23-26`).

**Initial-frame handling** is the [no-buffer-no-window][no-buffer-no-window] story inverted: X11 and Win32 map immediately and the renderer fills the first frame (Win32 forces a synchronous render in `WM_ERASEBKGND` to avoid a white flash, `Win32WindowWrapper.cs:306-323`). macOS creates the window hidden (`makeKeyWindow` then `orderOut:`) and shows it on activate (`UNOWindow.m:320-324`). There is **no native Wayland client**, so the Wayland-specific deferred-first-buffer dance never appears.

**Surface/handle exposure.** `NativeWindow` returns a platform handle wrapper: `X11NativeWindow(window)`, `Win32NativeWindow(hwnd)`, or the `NSWindow*`. macOS additionally exposes Metal handles for Skia via `uno_window_get_metal_handles(window, &device, &queue)` (`UNOWindow.m:986`).

**Destruction ordering** is treated as a hazard. X11 stops the render thread _before_ destroying the window — "otherwise we might end up in a situation where the render thread is trying to render on a destroyed window" (`X11XamlRootHost.cs:334-339`) — and `SynchronizedShutDown` flushes both X connections ten times and waits via `SpinWait` before `XDestroyWindow`, commented "This is extremely extremely delicate" (`:640-675`).

---

## 2. Event loop

Loop ownership is the spine of the design and is **deliberately different per platform** because the native constraints differ.

**X11 — Uno owns it, with a thread per window connection.** Each window starts two background threads (`Run(RootX11Window)` and `Run(TopX11Window)`, `X11XamlRootHost.x11events.cs:36-48`). Each multiplexes its X connection fd with `poll(2)` on a 1-second timeout, then drains events under an `XLock`:

```cs
// src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.x11events.cs
fds[0].fd = XLib.XConnectionNumber(x11Window.Display);
fds[0].events = X11Helper.POLLIN;
while (true)
{
    var ret = X11Helper.poll(fds, 1, 1000); // timeout every second to see if the window is closed
    if (Closed.IsCompleted) { SynchronizedShutDown(x11Window); return; }
    if (ret == 0) continue;          // timeout: re-check closed flag
    // ... XPending / XNextEvent loop, then QueueAction(...) to the dispatcher
}
```

This is a [readiness-style][readiness-vs-completion-windowing] fd poll, not a completion model. User-event injection from other threads is the `EventLoop.Schedule` queue (dispatcher thread); cross-thread wakeups to the X thread are unnecessary because that thread polls on a timeout.

**Win32 — the standard message pump, plus a hidden dispatcher window.** `Win32EventLoop.RunOnce` prioritizes input messages, then blocks on `GetMessage` (`src/Uno.UI.Runtime.Skia.Win32/Native/Win32EventLoop.cs:110`):

```cs
// src/Uno.UI.Runtime.Skia.Win32/Native/Win32EventLoop.cs
if (PInvoke.PeekMessage(out var msg, HWND.Null, 0, 0, PM_REMOVE | PM_QS_INPUT)
    || PInvoke.GetMessage(out msg, HWND.Null, 0, 0).Value != -1)
{
    PInvoke.TranslateMessage(msg);
    PInvoke.DispatchMessage(msg);
}
```

Cross-thread dispatch posts a privately `RegisterWindowMessage`-d message (`UnoWin32DispatcherMsg`) to a hidden `HWND_MESSAGE` window whose `WndProc` dequeues and invokes the action (`:71-101`). The standard Win32 caveat applies: a [modal resize/move loop][win32-modal-resize-loop] (`DefWindowProc`'s internal loop for `WM_SYSCOMMAND`/`SC_SIZE`) blocks Uno's own pump; Uno mitigates the resulting blank frames by rendering synchronously on `WM_MOVE`/`WM_SIZE` (`Win32WindowWrapper.cs:275-291`).

**macOS — AppKit owns it.** `NSApplicationMain` runs the `CFRunLoop`; Uno only supplies callbacks. Window/screen/input notifications come through AppKit delegate methods on `UNOWindow`/`UNOApplicationDelegate`, then call managed function pointers (`uno_set_window_events_callbacks`, `UNOWindow.m:895`).

**Frame pacing & vsync.** Uno uses a shared, **self-correcting software pacer** rather than a hard vsync lock. `FramePacer` (`src/Uno.UI.Runtime.Skia/Hosting/FramePacer.cs`) tracks absolute target timestamps so "overshoot from one frame is absorbed by shortening the next wait." On X11 the render thread waits on an `AutoResetEvent` that the pacer sets; the _target FPS is updated to the monitor's actual refresh rate_ read from XRandR (`mode_refresh` in `X11DisplayInformationExtension.cs:458-500`, fed to `UpdateRenderTimerFps`). On macOS the `MTKView` with `enableSetNeedsDisplay = YES` lets MetalKit drive `drawInMTKView:` (`UNOMetalViewDelegate.m:36`), so AppKit/Core Animation does the pacing. Redraw coalescing is via `IXamlRootHost.InvalidateRender()` → `_framePacer.RequestFrame()` (X11) / `view.needsDisplay = true` (macOS).

---

## 3. Input

### Keyboard

All hosts converge on WinUI's `VirtualKey` + a separate text/character channel — i.e. a [scancode → virtual-key][scancode-keysym-virtualkey] split.

- **X11** uses core-protocol `KeyPress`/`KeyRelease` (XI2 is used _only_ for pointer events; see the `EventsHandledByXI2Mask` comment, `X11XamlRootHost.cs:47`). `ProcessKeyboardEvent` calls `XLookupString` to get both a keysym and the UTF-8 text, maps the keysym to a `VirtualKey` via `X11KeyTransform.VirtualKeyFromKeySym`, and carries the X11 keycode as the scancode (`src/Uno.UI.Runtime.Skia.X11/Devices/Input/X11KeyboardInputSource.cs:107-200`). Layout/keysym translation is owned by Xlib (`XLookupString` honours the server's layout); Uno does not embed [xkbcommon][xkbcommon].
- **Win32** reads the `VirtualKey` straight from `wParam` and _peeks the queue for a following `WM_CHAR`_ to separate the character from the key, deliberately documenting the implementation-detail reliance (`Win32WindowWrapper.Keyboard.cs:21-49`). Scancode is `(lParam >> 16) & 0xFF`.
- **macOS** maps the AppKit `keyCode` (a positional scancode) through a big hand-written `get_virtual_key` switch and obtains the character via `CGEventKeyboardGetUnicodeString` (`UNOWindow.m:703-872`). Modifier keys are synthesized from `NSEventTypeFlagsChanged` deltas (`processModifiers:`, `:1393`).

**Key repeat** is server/OS-driven on all three (X server autorepeat, Win32 repeat in `lParam`, AppKit repeat) — none of these is the Wayland model where the client must run its own repeat timer, because **Uno has no Wayland client**.

### IME / text input (studied closely)

This is where the hosts diverge most, and each picks the platform-idiomatic protocol:

- **X11 → D-Bus IBus/Fcitx, not XIM.** `X11InputMethodDetector.DetectAsync` probes `UNO_IM_MODULE`/`GTK_IM_MODULE`/`QT_IM_MODULE`/`XMODIFIERS`, then checks the session bus for `org.freedesktop.portal.IBus` / `org.freedesktop.portal.Fcitx` / `org.fcitx.Fcitx` owners and builds a D-Bus IME client (`src/Uno.UI.Runtime.Skia.X11/IME/X11InputMethodDetector.cs`). Key events are forwarded to the IME via `HandleKeyEventAsync` (with a 100 ms timeout so a slow daemon can't stall input), and if the IME consumes the key Uno does **not** dispatch `KeyDown`/`KeyUp` (`X11KeyboardInputSource.cs:113-156`). Pre-edit text flows back through `OnDBusImePreeditChanged` → `OnPreeditChanged`. Using the modern D-Bus IME portals instead of legacy XIM is a notable, deliberate choice for a new X11 client.
- **Win32 → IMM32 (legacy), not TSF.** `Win32ImeTextBoxExtension` is documented as "Win32 **IMM32-based**" and handles `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION`/`WM_IME_ENDCOMPOSITION` (`src/Uno.UI.Runtime.Skia.Win32/UI/Xaml/Controls/TextBox/Win32ImeTextBoxExtension.cs:13-17`). The committed string is read with `GCS_RESULTSTR`; candidate-window positioning uses `ImmSetCompositionWindow` + `ImmSetCandidateWindow` (`Win32ImeCaretManager.cs:96-109`).
- **macOS → `NSTextInputClient`.** The rendering view (`UNOMetalFlippedView`) implements the protocol — `setMarkedText:`/`insertText:`/`unmarkText`/`markedRange`. Crucially it overrides `inputContext` because "`MTKView` (a rendering view) may not provide one by default, which would cause `interpretKeyEvents:` to bypass the input method entirely" (`UNOWindow.m:120-131`). Candidate-window positioning is `firstRectForCharacterRange:actualRange:`, which queries the managed caret rect and converts it to screen coordinates (`:244-256`). Key events are routed through `NSTextInputContext handleEvent:` while IME is active; if the IME doesn't consume the key, processing falls through to normal key handling (`UNOWindow.m:1230-1264`).

### Pointer

- **X11** uses XI2 (≥ 2.2) for all pointer/touch/scroll and core protocol for the rest. [High-resolution scroll][raw-vs-accelerated-pointer] is handled by reading `XIScrollClassInfo` valuators, diffing the absolute scroll "position" against the previous value (touchpads report position, not delta), and dividing by the scroll `Increment` (`X11PointerInputSource.XInput.cs:221-253`). Emulated core button-4/5/6/7 scroll events are ignored via the `XIPointerEmulated` flag (`:557-565`). Touchpad-vs-mouse is detected by probing libinput/synaptics device properties (`IsTouchpad`, `:630-728`). Cursor is set with `XCreateFontCursor` from the X cursor font/theme (`X11PointerInputSource.cs:56-61`) — no `cursor-shape-v1` because there's no Wayland.
- **Win32** opts into the unified pointer stack: `RegisterTouchWindow` + `EnableMouseInPointer(true)` (`Win32WindowWrapper.cs:207-210`), then handles `WM_POINTERDOWN/UP/WHEEL/HWHEEL/ENTER/LEAVE/UPDATE` and `WM_POINTERCAPTURECHANGED` (`:360-367`). This gives mouse, pen, and touch through one `WM_POINTER*` path.
- **macOS** routes everything through `UNOWindow.sendEvent:`, classifying `NSEventType*` into a `MouseEvents` enum (`UNOWindow.m:1174-1391`). Momentum/precise scrolling uses `event.hasPreciseScrollingDeltas` to scale: "trackpad / magic mouse sends about 10x more events than a normal (PC) mouse … line scroll versus a pixel scroll" — so non-precise deltas are multiplied by 10 (`:1362-1373`). Pen pressure/tilt come from `NSEvent.tilt`/`.pressure`.

Touch: X11 via XI2 `XI_TouchBegin/Update/End`; Win32 via `WM_POINTER*`; macOS via `NSEventTypeDirectTouch`. High-level gestures are synthesized by Uno's cross-platform gesture recognizer, not the window system.

---

## 4. Wayland specifics

> [!IMPORTANT]
> **Uno has no native Wayland client.** A full-tree search of the `Uno.UI.Runtime.Skia.*` hosts at this commit finds exactly one mention of "Wayland", and it is in the _framebuffer_ host detecting that a display server holds the DRM master:
>
> > The Linux framebuffer host detected a DRM device, but another process (most likely a running X11 or **Wayland** display server) currently holds the DRM master.
> >
> > — `src/Uno.UI.Runtime.Skia.Linux.FrameBuffer/Builder/FramebufferHostBuilder.cs:81`

There are zero references to `wl_surface`, `wl_display`, `xdg_toplevel`, `xdg_shell`, `zwp_text_input_v3`, `xdg-decoration`, `fractional-scale-v1`, `viewporter`, `libdecor`, or `layer-shell` anywhere in the desktop hosts. On Wayland systems Uno runs its **X11 host under XWayland**, which the maintainers acknowledge in docs and discussions:

- The official docs warn that "When running using X11 Wayland compatibility (e.g. recent Ubuntu releases), DPI scaling cannot be determined in a reliable way" ([Using the Skia Desktop][uno-skia-desktop]).
- A long-running discussion catalogs OpenGL/rendering crashes specifically under Wayland, with the X11/XWayland route as the workaround ([discussion #13641][uno-13641]).

So every Wayland dimension this survey asks about — server-side vs client-side [decorations][client-vs-server-decoration], `libdecor`, protocol coverage, [frame-callback vsync][frame-callback-vsync], compositor-specific workarounds — is **not applicable**: those concerns are delegated to the XWayland server, which presents a legacy X11 surface to Uno. This is the sharpest contrast in this catalog with toolkits like [GTK][gtk-wayland] or `winit` that ship a real Wayland client. (Recording an absent feature is itself a finding: a managed-code, from-scratch Wayland client would be a genuinely novel piece of work, and Uno has not built one.)

---

## 5. DPI & scaling

Uno's coordinate model is WinUI's: layout is in **logical (view) pixels**, and each host computes a `RasterizationScale` (= `RawPixelsPerViewPixel`) that the compositor multiplies into physical pixels. So the API-native unit is [logical][logical-vs-physical-coords] / [scale-factor][scale-factor]-based, with physical pixels at the surface boundary.

- **X11** computes scale from XRandR 1.3+ when available, otherwise falls back to an `xdpyinfo`-style DPI estimate, and always lets `Xft.dpi` (read fresh from the X resource database) or the `UNO_DISPLAY_SCALE_OVERRIDE` env var win (`X11DisplayInformationExtension.cs:212-249`, `:454`). It picks the CRTC that overlaps the window the most for multi-monitor correctness, and reads the refresh rate from the CRTC mode. When X resources change at runtime it reacts to a `PropertyNotify` on `RESOURCE_MANAGER` and re-publishes DPI (`X11XamlRootHost.x11events.cs:157-169`). The created-at-wrong-scale problem is handled by re-querying on these events; the Wayland-via-X11 DPI caveat above is the known weak spot.
- **Win32** is **per-monitor-v2 aware**: the wrapper calls `SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` before `CreateWindowEx` (`Win32WindowWrapper.cs:91`) and performs the [`WM_DPICHANGED`][wm-dpichanged] dance — on the message it updates display info, then `SetWindowPos` to the suggested `RECT` the OS provides (`OnWmDpiChanged`, `:440-449`). The constructor even resizes the window after creation if `RasterizationScale != 1` to compensate for a startup sizing bug ([#20021][uno-20021], cited at `:124-128`).
- **macOS** uses `NSScreen.backingScaleFactor`. The native side fires `windowDidChangeScreenNotification:` and `applicationDidChangeScreenParametersNotification:` (`UNOWindow.m:55-77`), reporting raw-pixel screen size and backing scale to managed code; `windowWillStartLiveResize:`/`windowDidEndLiveResize:` keep `layer.contentsScale` in sync so dragging a window between a Retina and non-Retina display rescales correctly (`:1422-1444`).

Mixed-DPI multi-monitor migration is therefore handled natively on Win32 (`WM_DPICHANGED`) and macOS (`windowDidChangeScreen`), and on X11 by re-evaluating the best-overlap CRTC.

---

## 6. Multi-window & popups

`SupportsMultipleWindows => true` on every desktop host's `INativeWindowFactoryExtension` (e.g. `X11NativeWindowFactoryExtension.cs:16`), and each new WinUI `Window` builds a fresh native window (and, on X11, a fresh root+top pair on new connections). Uno 5.2's release notes list multi-window as a headline feature.

**Popups, menus, and tooltips are _not_ native top-level windows.** Uno renders flyouts, `ComboBox` drop-downs, tooltips, and `ContextMenu` in an in-canvas light-dismiss popup layer inside the same window's visual tree — the cross-platform WinUI behaviour — rather than as [`xdg_popup` grabs or X11 override-redirect][override-redirect-vs-xdg-popup-grab] windows. The only place the X11 host touches override-redirect is `AttachSubWindow`, which reparents an _embedded native child_ (e.g. a hosted GTK WebView or media surface) and sets `CWOverrideRedirect` so the WM doesn't detach it (`X11XamlRootHost.cs:622-638`). Modal dialogs are likewise drawn in-tree; the native modal hooks are stubs (`X11NativeOverlappedPresenter.SetIsModal` is a TODO; macOS `uno_window_set_modal` "is a read-only property so we simply log if we can't change it", `UNOWindow.m:654-658`).

Parent/child stacking and window groups are thus mostly delegated to WinUI semantics plus per-platform always-on-top/level hints, not to a windowing-system grab model.

---

## 7. Threading

The thread model is forced by the platforms and differs per host:

- **macOS — main-thread AppKit, as always.** All `NSWindow` work happens on the AppKit main thread; `MacSkiaHost` sets `_isDispatcherThread = true` on the thread that calls `NSApplicationMain`, and cross-thread work is `dispatch_async_f` to the GCD main queue (`MacOSDispatcher.cs:34-42`). The classic "AppKit is main-thread-only" constraint is the reason the macOS dispatcher is GCD-based.
- **X11 — a dedicated managed UI thread, _not_ the X-event thread.** The "Uno Event Loop" thread is the dispatcher/UI thread; X events arrive on separate per-window threads and are `QueueAction`-ed onto it; rendering happens on yet another thread ("X11RenderThread", `AboveNormal` priority). So rendering _does_ happen off the event thread, guarded by `XLock` and the render-thread-stop-before-destroy ordering. `XInitThreads` is called once at startup, "necessary to run on WSL" (`X11ApplicationHost.cs:46-48`).
- **Win32 — single-threaded pump + a render timer.** The window must be created and pumped on the dispatcher thread; the `FramePacer` timer triggers rendering. `OleInitialize` is called on both the static ctor thread and the dispatcher thread for OLE/clipboard/drag-drop (`Win32Host.cs:49`, `:123`).

A recurring rule: **windows are created on, and events delivered to, the dispatcher thread; only rendering may run elsewhere (X11) or is driven by the platform (macOS).**

---

## 8. Clipboard & DnD

- **X11** implements the ICCCM selection model by hand in `X11ClipboardExtension` (1077 lines). It takes `CLIPBOARD` ownership via `XSetSelectionOwner`, answers `SelectionRequest` for `TARGETS` and `MULTIPLE` ("To be ICCCM-compliant, we need to support TARGETS and MULTIPLE at the very least", `:559`), tracks an ownership timestamp to reject stale requests, and reads via `XConvertSelection` + `SelectionNotify`. **INCR** (chunked large transfers) is implemented on the _read_ side — it watches for the `INCR` atom and accumulates chunks (`:829-890`, with a note crediting xsel/xclip and observing "Avalonia doesn't implement it") — but the _write_ side carries an explicit `// TODO: implement INCR` (`:506`). DnD is a hand-written XDND drop handler (`X11DragDropExtension`, deriving from edrosten's `x_clipboard` sample), wired through `ClientMessage` events for `XdndEnter`/`XdndPosition`/`XdndLeave`/`XdndDrop` (`X11XamlRootHost.x11events.cs:190-197`).
- **Win32** uses OLE: `OleInitialize` at startup, a `Win32ClipboardExtension`, and a `Win32DragDropExtension` over `IDropTarget`. (Win32 delayed-rendering / `WM_RENDERFORMAT` is the platform's mechanism; Uno's clipboard goes through the OLE data-object path.)
- **macOS** uses `NSPasteboard generalPasteboard` for text/HTML/RTF/URL/file-URL/image MIME types (`UNOClipboard.m:11-67`) and AppKit drag-and-drop.

MIME negotiation is therefore native to each platform's idiom: X11 atoms + `TARGETS`, Win32 clipboard formats via OLE, macOS UTI pasteboard types.

---

## 9. Escape hatches

When the WinUI abstraction is insufficient, Uno exposes the native handle:

- `INativeWindowWrapper.NativeWindow` returns `X11NativeWindow` (the `Window` XID), `Win32NativeWindow` (the `HWND`), or the `NSWindow*` — so apps can P/Invoke directly against the real window.
- macOS exposes the Metal `device`/`queue` via `uno_window_get_metal_handles` for custom GPU work, and `INativeOpenGLWrapper` (`X11NativeOpenGLWrapper`, `Win32NativeOpenGLWrapper`, `MacOSNativeOpenGLWrapper`) for native GL interop.
- **Native element hosting** is the deepest hatch: `INativeElementHostingExtension` reparents a real native child into the Uno window. On X11 this is `AttachSubWindow` (override-redirect reparent + XI2 input registration via `RegisterInputFromNativeSubwindow`, `X11XamlRootHost.x11events.cs:347-367`); on Win32/macOS the equivalent embeds an `HWND` / `NSView`. This is how WebView2/WKWebView and the VLC media surface are embedded.
- Win32 routes raw messages through a single `WndProc` per window (`Win32WindowWrapper.WndProcInner`); a `DwmDefWindowProc` pre-pass and `WM_NCHITTEST` handling expose custom-titlebar control. There is no public per-message hook, but the handle is reachable so an app can subclass.

These hatches reveal the known leaks: decoration control (Motif hints on X11), modal windows (stubbed everywhere), and Wayland (no native client at all).

---

## 10. History, redesigns & known regrets

- **2024 (Uno 5.2): the from-scratch Skia desktop hosts.** The headline windowing-layer redesign replaced the GTK+3-based Skia.GTK head with native X11, Linux-framebuffer, Win32, and macOS/AppKit hosts, selectable at runtime via `UnoPlatformHostBuilder` (`.UseX11().UseLinuxFrameBuffer().UseMacOS().UseWin32()`). The stated motivation was startup speed and footprint: removing GTK+3 "removes about 200MB of binaries from Gtk+3 on Windows or macOS" ([Uno 5.2 announcement][uno-52-blog], [InfoQ coverage][infoq-52], April–May 2024). This is what makes Uno a _managed_ X11/Win32 client today.
- **GTK head deprecated.** The older `Uno.UI.Runtime.Skia.Gtk` / `XamlHost.Skia.Wpf` heads still exist (`src/Uno.UI.Runtime.Skia.Wpf`, `Uno.UI.XamlHost.Skia.Wpf`) for migration, but the Skia desktop hosts are the recommended path; a [migration guide][uno-migrate] exists.
- **Wayland is the standing gap.** Native Wayland support remains unimplemented; users run under XWayland and hit the DPI-detection caveat and OpenGL/rendering issues ([#13641][uno-13641]). This is the clearest "known regret"-shaped item: a managed Wayland client is the obvious missing head.
- **Decoration handling is explicitly non-standard.** The code itself documents that resize/min/max control relies on undocumented Motif WM hints (`X11NativeOverlappedPresenter.cs:17`) and that several presenter operations are best-effort "hints" each WM interprets differently (`:28-31`).
- **Delicate X11 shutdown.** The two-connection design forces the "extremely extremely delicate" synchronized-shutdown dance (`X11XamlRootHost.cs:640`), and key-input handling needed `XSetLocaleModifiers`/`setlocale` workarounds ("keyboard input fails without this, not sure why this works but Avalonia and xev make similar calls", `X11ApplicationHost.cs:50`) and a top-window event-mask fix ([#19310][uno-19310], cited at `X11XamlRootHost.cs:29`).
- **GLX colormap and DPI bugs.** Concrete fixes cited in-source: the GLX colormap workaround ([#21285][uno-21285]) and the Win32 startup-scale resize ([#20021][uno-20021]).

---

## Strengths

- **A real, auditable managed X11/Win32 client.** No SDL/GLFW/GTK dependency on those platforms; the entire window-system integration is readable C# you can step through.
- **Platform-idiomatic input/IME per host.** D-Bus IBus/Fcitx on X11, IMM32 on Win32, `NSTextInputClient` on macOS — each picks the right protocol rather than a lowest-common-denominator shim.
- **Correct modern DPI on Win32 and macOS.** Per-monitor-v2 awareness with the `WM_DPICHANGED` dance; `backingScaleFactor` with live-resize rescaling.
- **Graceful renderer fallback.** Vulkan → GLX → EGL/GLES → software on X11; Metal → software on macOS, all exception-guarded.
- **Clean separation of concerns.** `IXamlRootHost` + the extension registry let one WinUI implementation serve very different windowing backends.
- **Self-correcting frame pacing** that tracks the monitor refresh rate from XRandR.

## Weaknesses

- **No native Wayland client.** Runs via XWayland with a documented DPI-detection caveat and rendering issues; this is the biggest gap versus `winit`/GTK/Qt.
- **Decoration control is undocumented/fragile** (Motif hints) and **modal windows are stubbed** on every host.
- **Clipboard INCR write-side is unimplemented** (large X11 clipboard writes can fail).
- **Heavyweight per-window threading on X11** (two X connections + multiple threads per window) makes the shutdown path "extremely delicate."
- **Popups are in-canvas, not native**, so they can't escape the window bounds the way `xdg_popup`/override-redirect menus can — a constraint inherited from the WinUI model.
- **macOS requires a native Objective-C shim**, so that host is not pure managed code.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                      | Trade-off                                                                                        |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| From-scratch managed X11/Win32 clients (drop GTK+3)             | ~200 MB smaller, faster start, fewer native deps, full control                 | Must re-implement ICCCM/EWMH/XI2/XRandR/XDND by hand; Wayland left unbuilt                       |
| Per-platform loop ownership (Uno on X11/Win32, AppKit on macOS) | Honour each platform's natural model (`NSApplicationMain` is mandatory)        | Three different threading/dispatch implementations to maintain                                   |
| Two X11 windows (root anchor + top render) on two connections   | Isolate GL context & input from the anchor; embed native children cleanly      | "Extremely delicate" synchronized shutdown; double the X resources/threads                       |
| D-Bus IBus/Fcitx IME on X11 instead of XIM                      | Modern, async, matches GTK/Qt env-var conventions                              | Depends on a running D-Bus IME daemon; 100 ms key-forward timeout band-aid                       |
| IMM32 (not TSF) for Win32 IME                                   | Simpler, sufficient for `TextBox` composition + candidate window               | Misses TSF features (rich text services, some advanced IMEs)                                     |
| Software self-correcting `FramePacer` (refresh-rate-tracked)    | Portable across X11/Win32; absorbs timer jitter; no per-backend vsync plumbing | Not a true vsync lock; relies on accurate refresh-rate detection (unreliable under XWayland/VMs) |
| In-canvas popups/flyouts instead of native sub-windows          | Identical WinUI behaviour on every platform                                    | Popups can't extend beyond the window; no compositor grab semantics                              |
| Skia as the sole rasterizer; host only owns the surface         | One render pipeline; hosts stay small                                          | Host can't expose platform-native drawing without an escape hatch                                |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **`IXamlRootHost` + extension-registry** seam — one app/UI layer, swappable windowing backends registered in a host's static ctor — is a clean way to support many window systems without `#if` soup.
- **Per-platform IME via the platform-idiomatic protocol** (D-Bus IBus/Fcitx, `NSTextInputClient`, IMM/TSF) rather than a shared shim; the `inputContext` override for a non-text rendering view (`MTKView`) is a reusable macOS lesson.
- **Renderer fallback chains** with exception guards, and a **refresh-rate-tracking software frame pacer** for portability.
- **Native-element hosting via override-redirect reparenting** (X11) as a concrete embedding recipe.

**Avoid / be wary of:**

- **Skipping Wayland.** Running everything through XWayland is a legitimate bootstrap, but it leaks (DPI, GL crashes); a serious Linux story needs a native Wayland client eventually.
- **Two windows on two X connections** unless you truly need the isolation — it multiplies thread count and makes shutdown perilous.
- **Undocumented Motif hints** for decoration control and **stubbed modal windows** — plan these in from the start.
- **In-canvas-only popups** if your app needs menus/tooltips that escape the window.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Will a native Wayland (managed) client land, and with what decoration strategy (libdecor vs own CSD)?** Likely in future `src/Uno.UI.Runtime.Skia.Wayland/` plus the discussion/issue tracker ([#13641][uno-13641]).
- **Exact frame-pacing behaviour under a compositor with adaptive sync / under XWayland**, where refresh-rate detection is "nondeterministic" (`X11DisplayInformationExtension.cs:456`). Answer would come from runtime tracing on real hardware.
- **Whether clipboard INCR write-side will be implemented** (currently `// TODO`, `X11ClipboardExtension.cs:506`) — watch that file / the issue tracker.
- **Win32 modal resize/move-loop blank-frame behaviour** beyond the `WM_MOVE`/`WM_SIZE` synchronous-render mitigation — likely needs a `WM_ENTERSIZEMOVE`/timer experiment.

---

## Sources

- [unoplatform/uno] — main repository; all quoted file paths are at commit `df5d18a`.
- X11 host: [`X11XamlRootHost.cs`][src-x11-host], [`X11XamlRootHost.x11events.cs`][src-x11-events], [`X11ApplicationHost.cs`][src-x11-apphost], [`X11NativeOverlappedPresenter.cs`][src-x11-presenter], [`X11DisplayInformationExtension.cs`][src-x11-display], [`X11KeyboardInputSource.cs`][src-x11-kbd], [`X11PointerInputSource.XInput.cs`][src-x11-ptr], [`X11InputMethodDetector.cs`][src-x11-ime], [`X11ClipboardExtension.cs`][src-x11-clip].
- Win32 host: [`Win32Host.cs`][src-win32-host], [`Win32EventLoop.cs`][src-win32-loop], [`Win32WindowWrapper.cs`][src-win32-wrapper], [`Win32WindowWrapper.Keyboard.cs`][src-win32-kbd], [`Win32ImeTextBoxExtension.cs`][src-win32-ime].
- macOS host: [`MacSkiaHost.cs`][src-mac-host], [`MacOSDispatcher.cs`][src-mac-dispatcher], native [`UNOApplication.m`][src-mac-app], [`UNOWindow.m`][src-mac-window], [`UNOMetalViewDelegate.m`][src-mac-metal].
- Shared: [`FramePacer.cs`][src-framepacer]; framebuffer [`FramebufferHostBuilder.cs`][src-fb-builder].
- Official docs & releases: [Using the Skia Desktop][uno-skia-desktop], [Uno 5.2 announcement][uno-52-blog], [InfoQ on Uno 5.2][infoq-52], [migration guide][uno-migrate].
- Issues/discussions: [#13641 (OpenGL/Wayland)][uno-13641], [#19310][uno-19310], [#20021][uno-20021], [#21285][uno-21285].
- Cross-references: shared vocabulary in [concepts][concepts]; layout in [ui-layout][ui-layout]; event-loop/async overlap in [async-io][async-io].

<!-- References -->

[unoplatform/uno]: https://github.com/unoplatform/uno
[skia]: https://skia.org/
[X11]: https://www.x.org/wiki/
[Win32]: https://learn.microsoft.com/en-us/windows/win32/
[appkit]: https://developer.apple.com/documentation/appkit
[CsWin32]: https://github.com/microsoft/CsWin32
[xkbcommon]: https://xkbcommon.org/
[uno-skia-desktop]: https://platform.uno/docs/articles/features/using-skia-desktop.html
[uno-52-blog]: https://platform.uno/blog/the-first-and-only-true-single-project-for-mobile-web-desktop-and-embedded-in-net/
[infoq-52]: https://www.infoq.com/news/2024/05/uno-platform-5-2-release/
[uno-migrate]: https://platform.uno/blog/migrating-uno-platform-applications-from-native-to-skia/
[uno-13641]: https://github.com/unoplatform/uno/discussions/13641
[uno-19310]: https://github.com/unoplatform/uno/issues/19310
[uno-20021]: https://github.com/unoplatform/uno/issues/20021
[uno-21285]: https://github.com/unoplatform/uno/issues/21285
[gtk-wayland]: https://docs.gtk.org/gtk4/wayland.html
[wm-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[src-x11-host]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.cs
[src-x11-events]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Hosting/X11XamlRootHost.x11events.cs
[src-x11-apphost]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Hosting/X11ApplicationHost.cs
[src-x11-presenter]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/UI/Windowing/X11NativeOverlappedPresenter.cs
[src-x11-display]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Graphics/Display/X11DisplayInformationExtension.cs
[src-x11-kbd]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Devices/Input/X11KeyboardInputSource.cs
[src-x11-ptr]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/Devices/Input/X11PointerInputSource.XInput.cs
[src-x11-ime]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/IME/X11InputMethodDetector.cs
[src-x11-clip]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.X11/ApplicationModel/DataTransfer/X11ClipboardExtension.cs
[src-win32-host]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Win32/Hosting/Win32Host.cs
[src-win32-loop]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Win32/Native/Win32EventLoop.cs
[src-win32-wrapper]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Win32/UI/Xaml/Window/Win32WindowWrapper.cs
[src-win32-kbd]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Win32/Devices/Input/Win32WindowWrapper.Keyboard.cs
[src-win32-ime]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Win32/UI/Xaml/Controls/TextBox/Win32ImeTextBoxExtension.cs
[src-mac-host]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.MacOS/Hosting/MacSkiaHost.cs
[src-mac-dispatcher]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.MacOS/Hosting/MacOSDispatcher.cs
[src-mac-app]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.MacOS/UnoNativeMac/UnoNativeMac/UNOApplication.m
[src-mac-window]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.MacOS/UnoNativeMac/UnoNativeMac/UNOWindow.m
[src-mac-metal]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.MacOS/UnoNativeMac/UnoNativeMac/UNOMetalViewDelegate.m
[src-framepacer]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia/Hosting/FramePacer.cs
[src-fb-builder]: https://github.com/unoplatform/uno/blob/df5d18a850248cb8c2ccb34032b4ebeb54dc8283/src/Uno.UI.Runtime.Skia.Linux.FrameBuffer/Builder/FramebufferHostBuilder.cs
[concepts]: ./concepts.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
[override-redirect-vs-xdg-popup-grab]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal-resize-loop]: ./concepts.md#win32-modal-resize-loop
[raw-vs-accelerated-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer-no-window]: ./concepts.md#no-buffer-no-window
[frame-callback-vsync]: ./concepts.md#frame-callback-vsync
[readiness-vs-completion-windowing]: ./concepts.md#readiness-vs-completion-windowing
[client-vs-server-decoration]: ./concepts.md#client-vs-server-decoration
[scancode-keysym-virtualkey]: ./concepts.md#scancode-keysym-virtualkey
[logical-vs-physical-coords]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pre-edit-composition]: ./concepts.md#pre-edit-composition
