# Qt 6 (QPA) (C++)

The C++ GUI framework's window-system layer: **QPA** (Qt Platform Abstraction) — a runtime-loaded plugin per platform (`qxcb`, `qwayland`, `qwindows`, `qcocoa`, …) implementing a fixed set of abstract base classes ([`QPlatformIntegration`][qpi-h], [`QPlatformWindow`][qpw-h], [`QPlatformScreen`][qps-h]) and pushing every native event through one funnel, [`QWindowSystemInterface`][qwsi-h]. Unlike a pure windowing library, Qt 6 is a full framework — QPA is the bottom 5% that the widget/QML stack sits on, but it is self-contained enough to study in isolation.

| Field                 | Value                                                                                                                                                                                                       |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit        | Qt **6.8** LTS — `qtbase` [`d0787745`][qtbase-tree] (Apr 18, 2025), `qtwayland` [`e98390fe`][qtwl-tree] (Apr 17, 2025)                                                                                      |
| Language              | C++ (C++17/20; Objective-C++ for the Cocoa plugin)                                                                                                                                                          |
| License               | LGPL-3.0 / GPL-2.0 / GPL-3.0 / commercial (the Cocoa plugin also carries an Apple sample-code license)                                                                                                      |
| Repository            | [qt/qtbase][qtbase] (core + xcb/windows/cocoa plugins); [qt/qtwayland][qtwl] (Wayland is a separate module)                                                                                                 |
| Documentation         | [Qt Platform Abstraction][qpa-doc] / [High DPI][highdpi-doc] / [Wayland and Qt][wl-doc]                                                                                                                     |
| Category              | Full GUI framework; QPA = its platform-abstraction/windowing layer                                                                                                                                          |
| Platforms covered     | Wayland, X11 (xcb), Win32 (windows), macOS (cocoa), plus Android, iOS, QNX, INTEGRITY, WebAssembly, eglfs/linuxfb (offscreen/embedded) — this doc covers the four desktop backends                          |
| Loop ownership        | **Hybrid** — Qt owns `QEventLoop`/`QAbstractEventDispatcher`; the dispatcher wraps the native loop (`CFRunLoop`, the Win32 message pump) or a dedicated reader thread (`xcb`, Wayland) that funnels into it |
| Repo paths (platform) | `qtbase/src/gui/kernel/` (QPA contract); `qtbase/src/plugins/platforms/{xcb,windows,cocoa}/`; `qtwayland/src/client/` + `qtwayland/src/plugins/shellintegration/`                                           |

> [!NOTE]
> Qt's Wayland support lives in a **separate repository and module** (`qtwayland`), loaded as the `qwayland-*` platform plugin family. `qtbase` ships only the xcb, windows, and cocoa desktop plugins. All file paths below are at the two pinned commits above; `qtbase` paths are under `qtbase/`, Wayland paths under `qtwayland/`.

---

## Overview

### What it solves

A native renderer (Vulkan, Metal, OpenGL, software raster) and a widget/QML toolkit both need the same three things from the OS, none of which is drawing: a **window/surface**, a **stream of input and lifecycle events**, and a **handle** the graphics API can bind to. Each OS supplies these through a deeply different API — Wayland's asynchronous protocol over a socket, X11's request/reply connection, the Win32 message pump, AppKit's `NSApplication`/`CFRunLoop`. QPA is the seam: a runtime-selected plugin implements a fixed set of abstract base classes, and the whole of Qt GUI above the seam talks only to those classes, never to the OS directly.

The contract's own header states the boundary plainly. [`QPlatformIntegration`][qpi-cpp] is described as:

> QPlatformIntegration is the single entry point for windowsystem specific functionality when using the QPA platform. It has factory functions for creating platform specific pixmaps and windows. The class also controls the font subsystem.

And the per-window abstraction, [`QPlatformWindow`][qpw-cpp], draws the line between windowing and rendering:

> QPlatformWindow is used to signal to the windowing system, how Qt perceives its frame. However, it is not concerned with how Qt renders into the window it represents.

Above this seam sits the public `QWindow`/`QScreen`/`QGuiApplication` layer; above _that_, the [widget and QML layout systems][ui-layout] (out of scope here — QPA constrains them but does not implement them).

### Design philosophy

- **One plugin per platform, loaded at runtime.** QPA replaced Qt 4's per-platform `#ifdef`-laden native widget code (see [§10](#10-history-redesigns--known-regrets)). A plugin is a shared object exporting a `QPlatformIntegrationPlugin` factory, selected by `QT_QPA_PLATFORM` / `-platform`. The same Qt binary can drive X11, Wayland, or offscreen by swapping the plugin.
- **A single event funnel.** No matter the backend, every input/lifecycle event is converted into a Qt event by calling a `static` `QWindowSystemInterface::handle*` method ([`qwindowsysteminterface.h`][qwsi-h]). This is the choke point that makes high-DPI scaling, event compression, and synchronous-vs-asynchronous delivery uniform across all four backends.
- **Qt owns the loop; the backend feeds it.** Qt has its own `QEventLoop` and a pluggable `QAbstractEventDispatcher`. Each plugin supplies a dispatcher (`createEventDispatcher` is pure-virtual on the integration) that either wraps the native run loop or bridges a reader thread into Qt's loop. The application always calls `QGuiApplication::exec()`; control returns to user code via signals/slots and events, not a winit-style `ApplicationHandler` callback object.
- **Capability negotiation, not assumption.** A plugin advertises optional features through [`QPlatformIntegration::hasCapability`][qpi-h] (`ThreadedOpenGL`, `MultipleWindows`, `WindowActivation`, `RhiBasedRendering`, …); Qt GUI checks the capability before using the feature, so a minimal plugin (e.g. `offscreen`) degrades cleanly.
- **Native coordinates are physical; logical coordinates face the app.** The boundary functions in [`QHighDpiScaling`][qhdpi-cpp] convert between the OS "native pixels" and the app's "device independent pixels" at the QPA seam, so most of Qt GUI never sees a raw OS coordinate.

---

## How it works

### The core abstractions

| Concept             | Type (file)                                                     | Role                                                                                                      |
| ------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| Plugin entry point  | `QPlatformIntegration` ([`qplatformintegration.h`][qpi-h])      | Singleton built in the `QGuiApplication` ctor; factory for windows, backing stores, the event dispatcher. |
| Per-window backend  | `QPlatformWindow` ([`qplatformwindow.h`][qpw-h])                | Wraps the native window/surface; `setGeometry`, `setVisible`, `winId`, `requestUpdate`, …                 |
| Per-screen backend  | `QPlatformScreen` ([`qplatformscreen.h`][qps-h])                | Geometry, DPI (`logicalDpi`/`logicalBaseDpi`), refresh rate, color depth.                                 |
| The event funnel    | `QWindowSystemInterface` ([`qwindowsysteminterface.h`][qwsi-h]) | `static handle*` methods every backend pushes events into; queues + flushes them to Qt GUI.               |
| Loop integration    | `QAbstractEventDispatcher` (per-plugin subclass)                | Wraps the native loop / reader thread; created by `createEventDispatcher`.                                |
| Public window       | `QWindow` ([`qwindow.h`][qwindow-h])                            | App-facing handle; owns a `QPlatformWindow` created lazily via `create()`.                                |
| Scaling             | `QHighDpiScaling` ([`qhighdpiscaling_p.h`][qhdpi-h])            | Converts native ↔ device-independent coordinates at the seam.                                             |
| Native escape hatch | `QPlatformNativeInterface` + `QNativeInterface::*`              | Typed accessors for `Display*`, `wl_display*`, `HWND`, `NSWindow*`, …                                     |

`QPlatformIntegration` makes the create/accessor split explicit; the two methods Qt cannot run without are pure-virtual:

```cpp
// qtbase/src/gui/kernel/qplatformintegration.h
virtual QPlatformWindow *createPlatformWindow(QWindow *window) const = 0;
virtual QPlatformBackingStore *createPlatformBackingStore(QWindow *window) const = 0;
// ...
virtual QAbstractEventDispatcher *createEventDispatcher() const = 0;
```

### The event funnel

Every backend ultimately calls one of the dozens of `static` handlers on `QWindowSystemInterface`:

```cpp
// qtbase/src/gui/kernel/qwindowsysteminterface.h  (a representative slice)
static bool handleKeyEvent(QWindow *window, QEvent::Type t, int k, Qt::KeyboardModifiers mods, ...);
static bool handleMouseEvent(QWindow *window, const QPointF &local, const QPointF &global, ...);
static bool handleWheelEvent(QWindow *window, const QPointF &local, const QPointF &global, ...);
static void handleGeometryChange(QWindow *window, const QRect &newRect);
static bool handleExposeEvent(QWindow *window, const QRegion &region);
static bool handleCloseEvent(QWindow *window);
static void handleWindowStateChanged(QWindow *window, Qt::WindowStates newState, int oldState = -1);
```

The class doc names its job exactly:

> The QWindowSystemInterface provides an event queue for the QPA platform. The platform plugins call the various functions to notify about events. The events are queued until `sendWindowSystemEvents()` is called by the event dispatcher.

Delivery has two modes ([`qwindowsysteminterface.cpp`][qwsi-cpp]). In **asynchronous** mode the handler appends to a shared queue and wakes the GUI dispatcher; the GUI thread drains it later:

```cpp
// qtbase/src/gui/kernel/qwindowsysteminterface.cpp  (AsynchronousDelivery)
QWindowSystemInterfacePrivate::windowSystemEventQueue.append(new EventType(args...));
if (QAbstractEventDispatcher *dispatcher = QGuiApplicationPrivate::qt_qpa_core_dispatcher())
    dispatcher->wakeUp();
```

In **synchronous** mode (`setSynchronousWindowSystemEvents(true)`) the event is processed inline on the calling thread and the accepted state is returned immediately. The queue is what lets QPA **compress** events (e.g. coalesce resizes, merge mouse moves) and apply high-DPI conversion uniformly: notice that even `handleEnterEvent` runs its coordinates through `QHighDpi::fromNativeLocalPosition` before queueing.

### The four backends in one paragraph each

- **xcb (X11):** [`QXcbIntegration`][xcb-int] owns a `QXcbConnection`; a dedicated [`QXcbEventQueue`][xcb-eq] **thread** blocks in `xcb_wait_for_event` and hands events to the GUI thread over a lock-free linked list, waking the dispatcher.
- **windows (Win32):** [`QWindowsIntegration`][win-int] registers a window class with `qWindowsWndProc` and uses Qt's standard `QEventDispatcherWin32` message pump; messages are decoded in [`QWindowsContext::windowsProc`][win-ctx].
- **cocoa (macOS):** [`QCocoaIntegration`][cocoa-int] installs [`QCocoaEventDispatcher`][cocoa-disp] over the main `CFRunLoop`; windows are `QNSWindow`/`QNSView` ([`qcocoawindow.mm`][cocoa-win]).
- **wayland:** [`QWaylandIntegration`][wl-int] runs a dedicated `WaylandEventThread` that `poll()`s the display fd and signals the GUI thread to dispatch ([`qwaylanddisplay.cpp`][wl-disp]); shell roles (`xdg_toplevel`/`xdg_popup`) come from a second-level **shell-integration** plugin.

---

## 1. Window creation & lifecycle

A `QWindow` is a lightweight app-side object; the native window is created lazily when `QWindow::create()` (or first `show()`) calls `QPlatformIntegration::createPlatformWindow`. The class doc is explicit that a visible window always has a backend object but **not** necessarily a backing store (OpenGL/third-party-rendered windows have none):

> Visible QWindows will always have a QPlatformWindow. However, it is not necessary for all windows to have a QBackingStore.

The platform calls per backend:

| Step              | xcb                                                             | windows                                                                 | cocoa                                                                                             | wayland                                                                                        |
| ----------------- | --------------------------------------------------------------- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Create native obj | `xcb_create_window` ([`QXcbWindow::create`][xcb-win], line 347) | `CreateWindowEx` ([`WindowCreationData::create`][win-create], line 921) | `[[QNSView alloc] initWithCocoaWindow:]` + `QNSWindow` ([`qcocoawindow.mm`][cocoa-win], line 119) | `wl_compositor.create_surface` + shell role ([`QWaylandWindow::initWindow`][wl-win], line 101) |
| Set title         | `xcb_change_property` (`_NET_WM_NAME`)                          | passed to `CreateWindowEx`                                              | `NSWindow.title`                                                                                  | `xdg_toplevel.set_title`                                                                       |
| Map / show        | `xcb_map_window` (line 770)                                     | `ShowWindow`                                                            | `[NSWindow makeKeyAndOrderFront:]`                                                                | commit a buffer (see below)                                                                    |

**The window-attributes model** lives on `QWindow` (`Qt::WindowFlags`, `Qt::WindowStates`) and is pushed down through `QPlatformWindow` virtuals — `setGeometry`, `setWindowFlags`, `setWindowState`, `setWindowTitle`, `setOpacity`, `setMask`, `raise`/`lower`, `requestActivateWindow`. Each backend silently drops what it cannot express:

- **Position:** Wayland has **no global window position** — a client cannot place its toplevel. `QWaylandWindow` honors size but the compositor owns placement; `QPlatformWindow::setGeometry` position is largely advisory there. X11/Win32/macOS honor it.
- **Always-on-top:** `Qt::WindowStaysOnTopHint` maps to `_NET_WM_STATE_ABOVE` (xcb), `HWND_TOPMOST` (windows), `NSWindow.level` (cocoa); on Wayland it is **unsupported** by core protocol and ignored.
- **Activation:** gated behind the `WindowActivation` capability; `requestActivateWindow` is a no-op where unsupported.

**Initial-frame handling** is the sharpest cross-platform divergence ([no-buffer-no-window][nbnw]). X11 (`xcb_map_window`) and Win32 (`ShowWindow`) map an empty window immediately. Wayland refuses to show a surface until a buffer is attached and committed — Qt encodes this in [`QWaylandWindow::isExposed`][wl-win], which returns `false` until the shell surface is configured, and only then sends `handleExposeEvent`:

```cpp
// qtwayland/src/client/qwaylandwindow.cpp
bool QWaylandWindow::isExposed() const
{
    if (!window()->isVisible())
        return false;
    if (mFrameCallbackTimedOut)
        return false;
    if (mShellSurface)
        return mShellSurface->isExposed();   // true only after first xdg configure
    ...
}
```

**Surface/handle exposure for GPU/software rendering** goes through `QPlatformWindow::winId()` (returns the native `WId`) and the typed `QNativeInterface` accessors (see [§9](#9-escape-hatches)); for Vulkan/OpenGL Qt provides `QVulkanInstance`/`QOpenGLContext` that bind to the platform window. **Destruction ordering** is enforced bottom-up: the Wayland xdg-decoration must be destroyed before its `xdg_toplevel` (a protocol requirement Qt honors explicitly: _"The protocol spec requires that the decoration object is deleted before xdg_toplevel"_, [`qwaylandxdgshell.cpp`][wl-xdg]).

---

## 2. Event loop

**Who owns the loop: Qt does, but the native loop is wrapped.** This is the central QPA design choice and the reason it is a _hybrid_. `QGuiApplication::exec()` runs Qt's `QEventLoop`, which delegates blocking to a per-plugin `QAbstractEventDispatcher` (created by the pure-virtual `createEventDispatcher`). Each backend integrates the native source differently:

- **macOS — wrap `CFRunLoop`.** [`QCocoaEventDispatcher`][cocoa-disp] adds a `CFRunLoopSource` and a `CFRunLoopTimer` to the main run loop (`CFRunLoopGetMain()`), so Qt timers and AppKit events share one loop:

  ```cpp
  // qtbase/src/plugins/platforms/cocoa/qcocoaeventdispatcher.mm
  static inline CFRunLoopRef mainRunLoop() { return CFRunLoopGetMain(); }
  ...
  CFRunLoopAddTimer(mainRunLoop(), runLoopTimerRef, kCFRunLoopCommonModes);
  ```

- **Windows — the message pump + modal resize loop.** The plugin uses Qt's `QEventDispatcherWin32`, which runs `GetMessage`/`DispatchMessage`. The notorious problem is the [Win32 modal resize/move loop][win32-modal]: while the user drags the title bar, Windows runs its **own** internal `DefWindowProc` loop and `GetMessage` never returns, freezing Qt timers and repaints. Qt detects entry/exit via `WM_ENTERSIZEMOVE`/`WM_EXITSIZEMOVE` ([`QWindowsContext`][win-ctx], lines 1183-1194), flagging the window `ResizeMoveActive` so geometry handling adapts.

- **X11 — a reader thread.** [`QXcbEventQueue`][xcb-eq] is a `QThread` that blocks in `xcb_wait_for_event` and pushes onto a lock-free list, then `wakeUpDispatcher()`. Its own doc describes the lock-free hand-off:

  > The lock-free solution uses a singly-linked list to pass events from the reader thread to the main thread. An atomic operation is used to sync the tail node of the list between threads.

- **Wayland — `poll()` on a dedicated thread.** [`QWaylandDisplay`][wl-disp] runs a `WaylandEventThread` (a `QThread`) that `poll()`s the `wl_display` fd and a self-pipe (for clean shutdown), then signals the GUI thread to dispatch via a queued connection:

  ```cpp
  // qtwayland/src/client/qwaylanddisplay.cpp  (EventThread::run, abridged)
  pollfd fds[2] = { { m_fd, POLLIN, 0 }, { m_pipefd[0], POLLIN, 0 } };
  poll(fds, 2, -1);
  if (fds[1].revents & POLLIN) { wl_display_cancel_read(m_wldisplay); break; }
  if (fds[0].revents & POLLIN) wl_display_read_events(m_wldisplay);
  else                         wl_display_cancel_read(m_wldisplay);
  ```

  The connection to the GUI loop is a `Qt::QueuedConnection` so the actual dispatch happens on the main thread:

  ```cpp
  // qtwayland/src/client/qwaylanddisplay.cpp  (initEventThread)
  connect(m_eventThread.get(), &EventThread::needReadAndDispatch, this,
          &QWaylandDisplay::flushRequests, Qt::QueuedConnection);
  ```

**Timers / wakeups / user events.** Cross-thread event injection uses `dispatcher->wakeUp()` (the funnel does this) or `QCoreApplication::postEvent`, which is thread-safe and wakes the target thread's loop. Qt timers ride the dispatcher (`CFRunLoopTimer` on macOS, `SetTimer`/timed `GetMessage` on Win32, a timerfd-style wait elsewhere). External fd / async-runtime integration is via `QSocketNotifier` (the same primitive every Unix backend uses internally).

**Frame pacing & vsync** is per-backend ([frame-callback vsync][fcv]):

- **macOS** uses a per-screen `CVDisplayLink`; `QWindow::requestUpdate` ultimately reaches [`QCocoaScreen::requestUpdate`][cocoa-screen] which creates/starts the link (`CVDisplayLinkCreateWithCGDisplay`) and delivers update requests from its callback (line 262 ff).
- **Wayland** throttles to `wl_surface.frame` callbacks. Notably Qt runs a **second** event thread bound to a dedicated `wl_event_queue` purely for frame callbacks (`m_frameEventQueueThread`, [`initEventThread`][wl-disp]), in `SelfDispatch` mode, so frame events are not starved by the main queue. The callback marks the window ready and re-delivers the pending `requestUpdate` ([`QWaylandWindow::handleFrameCallback`][wl-win], line 812).
- **X11/Win32** rely on the redraw coalescing in `QWindow::requestUpdate` (a single pending flag) rather than a hardware vsync source by default.

---

## 3. Input

**Keyboard: keysym/virtual-key model with xkbcommon on Unix.** ([scancode/keysym/virtual-key][skv].) On X11 and Wayland Qt owns an **xkbcommon** state machine. The Wayland keyboard builds the keymap the compositor sends (`xkb_keymap_new_from_string`) and resolves each key with `xkb_state_key_get_one_sym` ([`qwaylandinputdevice.cpp`][wl-input], line 1305); the same `QXkbCommon` helper lives in `qtbase` for xcb ([`qxcbkeyboard.cpp`][xcb-kb], which can even synthesize an xkb keymap from core-X protocol when XKB is absent). On Windows, [`QWindowsKeyMapper`][win-kb] maps virtual-key codes; on macOS, key codes come through `QNSView`.

**Key repeat — the client does it on Wayland.** The `wl_keyboard.repeat_info` event gives a rate+delay; Wayland sends only press/release, never repeats, so Qt drives repeats itself with a `QTimer` ([`qwaylandinputdevice.cpp`][wl-input]):

```cpp
// qtwayland/src/client/qwaylandinputdevice.cpp  (Keyboard::keyboard_key)
if (state == WL_KEYBOARD_KEY_STATE_PRESSED && xkb_keymap_key_repeats(mXkbKeymap.get(), code) && mRepeatRate > 0) {
    mRepeatKey.key = qtkey; mRepeatKey.code = code; ...
    mRepeatTimer.setInterval(mRepeatDelay);
    mRepeatTimer.start();
}
// the timer's callback re-emits a KeyRelease+KeyPress pair at 1000/mRepeatRate ms
```

**Dead keys / compose** on X11/Wayland are handled by a dedicated platform-input-context plugin: `qtbase` ships `compose` (XCompose) and `ibus` plugins under [`src/plugins/platforminputcontexts/`][pic].

**IME / text input.** ([pre-edit / composition][pec].) The protocols differ per platform and Qt implements each natively:

- **Wayland:** all three text-input protocols — `zwp_text_input_v1`, `v2`, and `v3` ([`qwaylandtextinputv3.cpp`][wl-ti3] et al.). The v3 backend turns `preedit_string`/`commit_string`/`delete_surrounding_text` events into a `QInputMethodEvent`, and reports the candidate-window anchor with `set_cursor_rectangle`:
  ```cpp
  // qtwayland/src/client/qwaylandtextinputv3.cpp
  void QWaylandTextInputv3::zwp_text_input_v3_preedit_string(const QString &text, int32_t cursorBegin, int32_t cursorEnd);
  void QWaylandTextInputv3::zwp_text_input_v3_commit_string(const QString &text);
  // updateState():  set_cursor_rectangle(surfaceRect.x(), ..., surfaceRect.width(), surfaceRect.height());
  ```
- **Windows:** the legacy **IMM32** path ([`qwindowsinputcontext.cpp`][win-imc]) — it handles `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION`/`WM_IME_ENDCOMPOSITION` and explicitly notes that during composition **no key events are sent**: _"Windows sends WM_IME_STARTCOMPOSITION, WM_IME_COMPOSITION, WM_IME_ENDCOMPOSITION messages that trigger startComposition(), composition(), endComposition(), respectively. No key events are sent."_ Qt 6.8's `qtbase` Windows plugin uses IMM32, **not** the newer TSF.
- **macOS:** the `NSTextInputClient` protocol implemented on `QNSView` ([`qnsview_complextext.mm`][cocoa-text]) — `setMarkedText:` (pre-edit), `insertText:` (commit), `firstRectForCharacterRange:` (candidate positioning).

**Pointer.** Absolute motion is the default everywhere; relative/raw motion ([raw vs accelerated pointer][rap]) comes via `zwp_relative_pointer` + `zwp_pointer_constraints` on Wayland and raw input on Win32. High-resolution scroll is supported per platform: Wayland handles both `wl_pointer.axis_discrete` and the newer `wl_pointer.axis_value120` ([`qwaylandinputdevice.cpp`][wl-input], `pointer_axis_value120`, line 975); Win32 accumulates `WHEEL_DELTA` from `WM_MOUSEWHEEL` ([`qwindowspointerhandler.cpp`][win-ptr], `GET_WHEEL_DELTA_WPARAM`); macOS forwards momentum phases. Cursor handling on Wayland prefers the server-side `wp_cursor_shape_manager_v1` when present and falls back to a client-rendered cursor surface otherwise (both bound in [`qwaylanddisplay.cpp`][wl-disp]).

**Touch & gestures** funnel through `QWindowSystemInterface::handleTouchEvent`; Wayland adds `zwp_pointer_gestures` (bound as `QWaylandPointerGestures`).

---

## 4. Wayland specifics

**Decorations: Qt draws its own CSD, and prefers SSD when the compositor offers it** ([client vs server decoration][cvs]). Qt negotiates `zxdg_decoration_manager_v1`: when an `xdg_toplevel` is created it requests a server-side decoration object ([`qwaylandxdgshell.cpp`][wl-xdg], `createToplevelDecoration`), and `wantsDecorations()` returns `true` (meaning "Qt must draw them") **only** if the server chose client-side or hasn't configured:

```cpp
// qtwayland/src/plugins/shellintegration/xdg-shell/qwaylandxdgshell.cpp
bool QWaylandXdgSurface::Toplevel::wantsDecorations()
{
    if (m_decoration && (m_decoration->pending() == QWaylandXdgToplevelDecorationV1::mode_server_side
                         || !m_decoration->isConfigured()))
        return false;   // server-side: don't draw our own
    ...
}
```

When it must draw, Qt does **not** use `libdecor`; it loads a **decoration plugin** ([`QWaylandWindow::createDecoration`][wl-win], line 1037) — `adwaita`/`gnome` on GNOME desktops, else the built-in `bradient` plugin, overridable via `QT_WAYLAND_DECORATION`:

```cpp
// qtwayland/src/client/qwaylandwindow.cpp  (decoration selection)
if (desktopNames.contains("GNOME")) {
    if (decorations.contains("adwaita"_L1)) targetKey = "adwaita"_L1;
    else if (decorations.contains("gnome"_L1)) targetKey = "gnome"_L1;
} else {
    decorations.removeAll("adwaita"_L1); decorations.removeAll("gnome"_L1);
}
if (targetKey.isEmpty()) targetKey = decorations.first(); // first come, first served.
```

**Protocol coverage beyond core + `xdg-shell`** (all bound in [`QWaylandDisplay::registry_global`][wl-disp]): `wp_fractional_scale_manager_v1`, `wp_viewporter`, `wp_cursor_shape_manager_v1`, `xdg_activation_v1` (via the xdg-shell plugin), `zwp_text_input_v1/v2/v3`, `zwp_tablet_v2`, `zwp_pointer_gestures`, `zwp_primary_selection_v1`, `xdg_output`, `xdg_toplevel_drag_manager_v1`, plus Qt-private extensions (`qt_text_input_method_v1`, `qt_windowmanager`). **Protocol absence is handled by feature-gating** — each `else if` in the registry binds only what the compositor advertises, and `nullptr` checks at use sites print a warning and degrade (e.g. `createSubSurface` warns "not supported by the compositor" and returns `nullptr`).

> [!NOTE]
> **Compositor-specific workarounds appear in the source.** `QWaylandWindow::initWindow` notes a viewporter check is _"needed to work around Gnome < 36 where viewports don't work"_, and the popup-parent code warns about protocols where a non-grabbing popup parent is illegal — a `mutter`/`kwin`-driven divergence handled by reparenting popups to the topmost grabbing popup ([`qwaylandwindow.cpp`][wl-win], line 134).

> [!WARNING]
> `layer-shell` and `idle-inhibit` are **not** bound by the upstream Qt 6.8 Wayland plugin's registry handler. Apps needing `wlr-layer-shell` use third-party shell-integration plugins; this is a known gap relative to GTK/winit.

---

## 5. DPI & scaling

**The model: native (physical) pixels at the OS boundary, device-independent (logical) pixels for the app** ([logical vs physical coords][lpc], [scale factor][scale-factor]). [`QHighDpiScaling`][qhdpi-cpp] is the canonical authority and its header comment is the clearest statement in the tree:

> Seen from the outside there are only two coordinate systems: device independent pixels and device pixels. The devicePixelRatio seen by applications is the product of the Qt scale factor and the OS scale factor. ... Platforms that (may) have an OS scale factor include macOS, iOS, Wayland, and Web(Assembly).

The **per-screen Qt scale factor** is derived from the screen's logical DPI:

```text
factor = QPlatformScreen::logicalDpi() / QPlatformScreen::logicalBaseDpi()
```

so a backend reports DPI and Qt computes the factor (overridable via `QT_SCREEN_SCALE_FACTORS` / globally via `QT_SCALE_FACTOR`). **Qt 6 does not round scale factors by default** (Qt 5 rounded to the nearest integer) — the comment records this explicitly, and the policy is set with `QGuiApplication::setHighDpiScaleFactorRoundingPolicy()` / `QT_SCALE_FACTOR_ROUNDING_POLICY`. The "API native unit" the app sees is **logical**; the conversion helpers (`QHighDpi::fromNativeLocalPosition`, `toNativePixels`, …) are applied inside `QWindowSystemInterface` handlers and inside each plugin's `setGeometry`.

**Per-monitor DPI on Windows (v2)** — the WM_DPICHANGED dance is implemented in [`QWindowsWindow::handleDpiChanged`][win-create] (line 2036). Qt declares per-monitor-v2 awareness; when the user drags a window across a DPI boundary, Windows first sends `WM_GETDPISCALEDSIZE` (Qt sets the new size) then `WM_DPICHANGED` with a suggested rect, which Qt applies with `SetWindowPos` so the window tracks the cursor across the screen change. The code comments the two distinct cases (spontaneous drag vs `setGeometry`-induced) carefully to avoid double-scaling.

**Fractional scaling on Wayland** uses `wp_fractional_scale_v1` + `wp_viewporter`: when the rounding policy is `PassThrough`, `QWaylandWindow::initWindow` creates a `QWaylandFractionalScale` and a `QWaylandViewport`, rendering at the fractional buffer scale rather than integer `wl_surface.set_buffer_scale`. **macOS** exposes only integer backing scale (`backingScaleFactor`, 1× or 2×) as the OS scale factor.

**The created-at-wrong-scale-then-rescaled problem** is real on multi-monitor: a window created before its final screen is known may get the wrong factor and is rescaled on the subsequent `handleWindowScreenChanged` / `handleWindowDevicePixelRatioChanged`. Qt funnels both as dedicated events (`QWindowSystemInterface::handleWindowDevicePixelRatioChanged`).

---

## 6. Multi-window & popups

`QPlatformIntegration` advertises `MultipleWindows`, `NonFullScreenWindows`, and `WindowActivation` capabilities; Qt GUI checks them before relying on multi-window behavior. Modal dialogs are expressed as `Qt::WindowModality` and mapped down per-backend (e.g. Wayland uses `xdg_dialog_v1` `set_modal` when the `xdg-dialog` protocol is present — [`qwaylandxdgshell.cpp`][wl-xdg], line 40).

**Tooltips/menus diverge sharply** ([override-redirect vs xdg_popup grab][orx]):

- **X11:** popups, tooltips, and `BypassWindowManagerHint` windows are created **override-redirect** — the WM ignores them. [`QXcbWindow::create`][xcb-win] sets `XCB_CW_OVERRIDE_REDIRECT` for `Qt::Popup`/`Qt::ToolTip` (lines 331-341) and adds `X11BypassWindowManagerHint` to their flags.
- **Wayland:** a popup is an `xdg_popup` with a `xdg_positioner` and an explicit **grab** tied to an input serial. [`QWaylandXdgSurface::Popup::grab`][wl-xdg] calls `xdg_popup::grab(seat, serial)`; the compositor then dismisses the popup on outside click (`xdg_popup.popup_done`). Because the protocol forbids a popup whose parent isn't the topmost grabbing popup, Qt re-parents to `mTopPopup` and warns (see [§4](#4-wayland-specifics)).

Parent/child stacking uses `setParent`/`set_parent` (`xdg_toplevel.set_parent` on Wayland, transient-for on X11, `NSWindow` child ordering on macOS). There is no cross-platform "window group" beyond transient-parent chains.

---

## 7. Threading

**Windows must be created on, and events are received on, the GUI (main) thread.** `QGuiApplication` must run on the thread that entered `main()`; `QWindow::create()` and `requestUpdate()` assert it:

```cpp
// qtbase/src/gui/kernel/qwindow.cpp
void QWindow::requestUpdate()
{
    Q_ASSERT_X(QThread::isMainThread(),
        "QWindow", "Updates can only be scheduled from the GUI (main) thread");
    ...
}
```

The funnel's asynchronous mode exists precisely so backend **reader threads** (xcb `QXcbEventQueue`, the Wayland `WaylandEventThread`) can _produce_ events off-thread but have them _delivered_ on the GUI thread via `wakeUp()` + a queued connection. The Wayland decoration code asserts main-thread access explicitly (`"QWaylandWindow::createDecoration", "not called from main thread"`).

**The constraint's origin is macOS.** AppKit requires all UI calls on the main thread, and `CFRunLoopGetMain()` is the only run loop Qt can drive there — so QPA standardizes on "GUI = main thread" across all backends rather than special-casing macOS. **Rendering can happen off the event thread** where the backend allows it: the integration advertises `ThreadedOpenGL`/`ThreadedPixmaps`/`RhiBasedRendering` capabilities, and Qt Quick's render thread relies on them; the macOS window code has comments about producing frames off the main thread under the display-link path ([`qcocoawindow.mm`][cocoa-win], lines ~1297-1305).

---

## 8. Clipboard & DnD

`QPlatformIntegration::clipboard()` and `drag()` return per-backend objects; data is carried as `QMimeData` (MIME-typed), negotiated lazily.

- **X11 — selections + INCR.** [`QXcbClipboard`][xcb-clip] implements the ICCCM selection protocol with the `INCR` chunked-transfer mechanism for large data: when a payload exceeds `m_maxPropertyRequestDataBytes` it replies with an `INCR` atom and streams chunks (`handleSelectionRequest`, lines 444-462; the receive side checks the `INCR` type at line 715). It even notes Motif's lack of INCR support.
- **Windows — delayed rendering via OLE.** [`QWindowsClipboard`][win-clip] uses `OleSetClipboard` with an `IDataObject`, so formats are rendered on demand when a consumer requests them (the retrieval side is `QWindowsClipboardRetrievalMimeData`, _"managing delayed retrieval of clipboard data"_).
- **Wayland — the data-device model.** [`QWaylandClipboard`][wl-clip] wraps `wl_data_device`: the selection is a `QWaylandDataSource` advertising MIME types; the receiver gets a `wl_data_offer` and `receive()`s the chosen type over a pipe fd. Primary selection (`zwp_primary_selection_v1`) is supported when the compositor offers it.
- **macOS** uses `NSPasteboard` via `QMacPasteboard` ([`qmacclipboard.mm`][cocoa-clip]).

Drag-and-drop mirrors clipboard per backend (`QXcbDrag` / XDND, `QWindowsDrag` / OLE drag, `QWaylandDataDevice` DnD, `QCocoaDrag`).

---

## 9. Escape hatches

QPA leaks deliberately, through two mechanisms:

1. **Typed `QNativeInterface` accessors.** App code can reach the native connection without casting to private types. [`qguiapplication_platform.h`][gui-plat] declares, for example:
   ```cpp
   // qtbase/src/gui/kernel/qguiapplication_platform.h
   struct Q_GUI_EXPORT QX11Application {
       virtual Display *display() const = 0;
       virtual xcb_connection_t *connection() const = 0;
   };
   struct Q_GUI_EXPORT QWaylandApplication {
       virtual wl_display *display() const = 0;
       virtual wl_compositor *compositor() const = 0;
       virtual wl_seat *seat() const = 0;
       virtual uint lastInputSerial() const = 0;
       ...
   };
   ```
   Usage: `qApp->nativeInterface<QNativeInterface::QWaylandApplication>()->display()`. Per-window equivalents expose `HWND`, `NSWindow*`, the X11 window id, and the `wl_surface*`.
2. **`QPlatformNativeInterface` + `winId()`.** The older, string-keyed `nativeResourceForWindow("surface", window)` path and `QWindow::winId()` give the raw native handle for embedding or interop.
3. **Raw event passthrough.** `QWindowSystemInterface::handleNativeEvent` and the app-installable `QAbstractNativeEventFilter` let code intercept native messages (`MSG` on Win32, `xcb_generic_event_t` on X11) before Qt processes them — the message-pump hook.

These are exactly the points where the abstraction is known to leak: position on Wayland, `HWND` styling on Win32, `NSView` subclassing on macOS.

---

## 10. History, redesigns & known regrets

- **QPA replaced Qt 4's "QWS/native-widget" model in Qt 5.0 (2012).** Qt 4 had per-platform native code with `QWidget`-centric backends; Qt 5 introduced **QPA** (initially "Lighthouse") so that the entire windowing layer became a loadable plugin over `QWindow`, decoupled from `QWidget`. See the [Qt 5.0 wiki][qt5-wiki] and the [QPA overview][qpa-doc]. The classes are still marked `\since 4.8` / `\preliminary` `\internal` — QPA is an _internal_ API by policy, which is itself a maintainer stance: the seam is stable enough to build plugins against but Qt reserves the right to change it.
- **High-DPI evolution.** Opt-in `AA_EnableHighDpiScaling` in Qt 5.6 ([High DPI in Qt 5.6][highdpi56]); always-on in Qt 6 with **no default rounding** (the `QHighDpiScaling` comment records the Qt5→Qt6 rounding-policy change). The rounding-policy API ([QTBUG-53022 era][qtbug-dpi]) was added to tame fractional-scale ugliness.
- **Wayland matured late and unevenly.** The Wayland plugin shipped years after X11; window **positioning** remains impossible by protocol (a recurring complaint, e.g. [QTBUG-76902][qtbug-wl]), decorations were long a sore point (Qt draws its own rather than adopting `libdecor`), and `layer-shell`/`idle-inhibit` are still unbound upstream. The reconnect path (`mWaylandTryReconnect`) and the `_exit(-1)` on a broken connection ([`checkWaylandError`][wl-disp]) show how brittle compositor lifecycle handling has been.
- **The Win32 modal resize loop** remains a structural wart inherited from the OS; Qt mitigates but cannot eliminate the frozen-loop behavior during live resize.
- **IMM32 over TSF on Windows.** Qt's `qtbase` Windows input context is still IMM32-based in 6.8; modern Text Services Framework support has been a long-requested, slow-moving item.

---

## Strengths

- **One uniform event funnel** (`QWindowSystemInterface`) makes high-DPI conversion, event compression, and sync/async delivery consistent across four very different backends.
- **Runtime plugin selection** — the same binary runs X11, Wayland, or offscreen by swapping `QT_QPA_PLATFORM`; ideal for CI/headless.
- **Capability negotiation** lets minimal/embedded backends degrade cleanly instead of crashing on unsupported features.
- **Mature, complete desktop coverage** — full IME (three Wayland text-input versions, IMM32, `NSTextInputClient`), tablet, gestures, INCR/OLE/data-device clipboard, per-monitor-v2 DPI.
- **Typed native escape hatches** (`QNativeInterface`) give clean access to `wl_display`/`HWND`/`NSWindow` without private headers.

## Weaknesses

- **QPA is `\internal`/`\preliminary`** — no source/binary compatibility guarantee; out-of-tree plugins are explicitly discouraged ("not trivial to create or build a platform plugin outside of the Qt source tree").
- **Wayland gaps:** no `layer-shell`/`idle-inhibit` upstream, no toplevel positioning (protocol limit), own-drawn CSD instead of `libdecor`, compositor-specific popup workarounds.
- **Two reader threads + queued dispatch on Wayland** is more machinery (and more concurrency subtlety) than a single-threaded `calloop`-style loop; the `EventThread` carries a detailed concurrency comment for a reason.
- **Win32 IME is legacy IMM32**, not TSF.
- **Heavyweight:** QPA cannot be used standalone — it is the floor of a multi-megabyte framework, unlike a thin library (winit/GLFW/SDL).

## Key design decisions and trade-offs

| Decision                                              | Rationale                                                                          | Trade-off                                                                                          |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| Plugin per platform over abstract base classes (QPA)  | Decouple windowing from `QWidget`; swap backends at runtime; one binary, many OSes | A wide pure-virtual surface to implement; the API is kept `\internal`, deterring 3rd-party plugins |
| Single `QWindowSystemInterface` event funnel          | Uniform DPI scaling, compression, sync/async delivery in one place                 | Every event pays a queue hop + conversion; the funnel is a serialization point                     |
| Qt owns the loop; dispatcher wraps the native source  | Qt timers/signals/sockets interoperate with native events under one `exec()`       | Must fight native quirks (Win32 modal loop) and run reader threads (xcb/Wayland)                   |
| Reader thread + queued dispatch (xcb, Wayland)        | Never block the GUI thread on a socket; clean cross-thread wakeups                 | Lock-free/concurrency machinery; two threads on Wayland (main + frame queue)                       |
| Native = physical, app = logical, convert at the seam | App code is DPI-agnostic; backends speak the OS's native unit                      | A whole `QHighDpi::*` conversion vocabulary; created-at-wrong-scale rescale dance                  |
| Own-drawn CSD via decoration plugins on Wayland       | Works on any compositor; themable (adwaita) without `libdecor`                     | Diverges from desktop look; doesn't use the ecosystem-standard `libdecor`                          |
| GUI = main thread everywhere (driven by macOS AppKit) | One threading model across backends; matches AppKit's hard requirement             | No off-thread window creation; throughput-bound apps must push work to render/worker threads       |

## Verdict: what a new framework should steal / avoid

**Steal:** the **single typed event funnel** with built-in coordinate conversion and a sync/async toggle — it is the cleanest part of QPA and the reason high-DPI is uniform. **Steal** the **capability-negotiation** pattern (`hasCapability`) so backends degrade instead of asserting. **Steal** the **typed native-handle accessors** (`QNativeInterface`) over string-keyed `void*` lookups. **Avoid** keeping the platform contract perpetually `\internal`/`\preliminary` — it makes the most reusable layer un-reusable. **Avoid** own-drawing Wayland decorations when `libdecor` exists; QPA's plugin approach predates `libdecor` and now diverges from the desktop. **Reconsider** Wayland's two-event-thread design unless frame-callback starvation is a proven problem — winit's single `calloop` loop is simpler. See [winit][winit] for the thin-library counterpoint and [concepts][concepts] for the shared vocabulary.

## Open questions I could not resolve (with where the answer likely lives)

- **Exactly when the frame-queue thread is preferred over the main queue for a given surface.** The `SelfDispatch` vs `EmitToDispatch` split is in [`qwaylanddisplay.cpp`][wl-disp] (`initEventThread`), but the full rationale (which callbacks land on which queue) needs the `QWaylandWindow` frame-callback registration code (`qwaylandwindow.cpp`, `mFrameQueue`).
- **Whether Qt 6.x ever ships a TSF-based Windows input context.** `qtbase/src/plugins/platforms/windows/qwindowsinputcontext.cpp` is IMM32 in 6.8; a TSF variant, if any, would appear as a separate plugin or a `dev`-branch addition — check the Qt 6.9+ changelog and `bugreports.qt.io`.
- **The precise interaction of `WM_GETDPISCALEDSIZE` and Qt's logical geometry** during cross-monitor drag — the two-case comment in `handleDpiChanged` is the start, but the `WM_GETDPISCALEDSIZE` handler (`qwindowswindow.cpp`) holds the rest.

## Sources

- [qt/qtbase][qtbase] @ `d0787745` — QPA contract (`src/gui/kernel/`) and the xcb/windows/cocoa plugins
- [qt/qtwayland][qtwl] @ `e98390fe` — the Wayland client plugin (`src/client/`, `src/plugins/shellintegration/`)
- [`QPlatformIntegration`][qpi-cpp], [`QPlatformWindow`][qpw-cpp], [`QWindowSystemInterface`][qwsi-cpp], [`QHighDpiScaling`][qhdpi-cpp] — the in-source class docs quoted above
- [Qt Platform Abstraction][qpa-doc], [High DPI][highdpi-doc], [Wayland and Qt][wl-doc], [`QWindow`][qwindow-doc] — official docs
- Protocol references: [`xdg-shell`][p-xdgshell], [`xdg-decoration`][p-xdgdeco], [`fractional-scale-v1`][p-fracscale], [`text-input-v3`][p-ti3], [`wl_pointer.axis_value120`][p-v120]
- History: [Qt 5.0 wiki][qt5-wiki], [High DPI in Qt 5.6][highdpi56], [QTBUG-53022][qtbug-dpi], [QTBUG-76902][qtbug-wl], [WM_DPICHANGED][wm-dpichanged]
- Sibling docs: [concepts][concepts], [winit][winit], [SDL3][sdl3], [sokol][sokol], [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[qtbase]: https://github.com/qt/qtbase
[qtwl]: https://github.com/qt/qtwayland
[qtbase-tree]: https://github.com/qt/qtbase/tree/d0787745aa43e5baf49de876f917946df6aceca5
[qtwl-tree]: https://github.com/qt/qtwayland/tree/e98390fe0ec6ef8fca62645521aa30905b4ab75a
[qpi-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qplatformintegration.h
[qpi-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qplatformintegration.cpp
[qpw-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qplatformwindow.h
[qpw-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qplatformwindow.cpp
[qps-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qplatformscreen.h
[qwsi-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindowsysteminterface.h
[qwsi-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindowsysteminterface.cpp
[qwindow-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qwindow.h
[qhdpi-h]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qhighdpiscaling_p.h
[qhdpi-cpp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qhighdpiscaling.cpp
[gui-plat]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/gui/kernel/qguiapplication_platform.h
[xcb-int]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbintegration.cpp
[xcb-win]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbwindow.cpp
[xcb-eq]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbeventqueue.cpp
[xcb-kb]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbkeyboard.cpp
[xcb-clip]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/xcb/qxcbclipboard.cpp
[win-int]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowsintegration.cpp
[win-ctx]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowscontext.cpp
[win-create]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowswindow.cpp
[win-kb]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowskeymapper.cpp
[win-imc]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowsinputcontext.cpp
[win-ptr]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowspointerhandler.cpp
[win-clip]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/windows/qwindowsclipboard.cpp
[cocoa-int]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qcocoaintegration.mm
[cocoa-disp]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qcocoaeventdispatcher.mm
[cocoa-win]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qcocoawindow.mm
[cocoa-screen]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qcocoascreen.mm
[cocoa-text]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qnsview_complextext.mm
[cocoa-clip]: https://github.com/qt/qtbase/blob/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforms/cocoa/qmacclipboard.mm
[wl-int]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylandintegration.cpp
[wl-disp]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylanddisplay.cpp
[wl-win]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylandwindow.cpp
[wl-input]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylandinputdevice.cpp
[wl-clip]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylandclipboard.cpp
[wl-ti3]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/client/qwaylandtextinputv3.cpp
[wl-xdg]: https://github.com/qt/qtwayland/blob/e98390fe0ec6ef8fca62645521aa30905b4ab75a/src/plugins/shellintegration/xdg-shell/qwaylandxdgshell.cpp
[pic]: https://github.com/qt/qtbase/tree/d0787745aa43e5baf49de876f917946df6aceca5/src/plugins/platforminputcontexts
[qpa-doc]: https://doc.qt.io/qt-6/qpa.html
[highdpi-doc]: https://doc.qt.io/qt-6/highdpi.html
[wl-doc]: https://doc.qt.io/qt-6/wayland-and-qt.html
[qwindow-doc]: https://doc.qt.io/qt-6/qwindow.html
[qt5-wiki]: https://wiki.qt.io/Qt_5.0
[highdpi56]: https://www.qt.io/blog/2016/01/26/high-dpi-support-in-qt-5-6
[qtbug-dpi]: https://bugreports.qt.io/browse/QTBUG-53022
[qtbug-wl]: https://bugreports.qt.io/browse/QTBUG-76902
[wm-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[p-xdgshell]: https://wayland.app/protocols/xdg-shell
[p-xdgdeco]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[p-fracscale]: https://wayland.app/protocols/fractional-scale-v1
[p-ti3]: https://wayland.app/protocols/text-input-unstable-v3
[p-v120]: https://wayland.app/protocols/wayland#wl_pointer:event:axis_value120
[concepts]: ./concepts.md
[csd-vs-ssd]: ./concepts.md#client-vs-server-decoration
[cvs]: ./concepts.md#client-vs-server-decoration
[skv]: ./concepts.md#scancode-keysym-virtualkey
[lpc]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pec]: ./concepts.md#pre-edit-composition
[orx]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal]: ./concepts.md#win32-modal-resize-loop
[rap]: ./concepts.md#raw-vs-accelerated-pointer
[nbnw]: ./concepts.md#no-buffer-no-window
[fcv]: ./concepts.md#frame-callback-vsync
[winit]: ./winit.md
[sdl3]: ./sdl3.md
[sokol]: ./sokol.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
