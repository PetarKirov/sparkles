# GLFW (C)

A small, single-purpose C library for creating an OpenGL/OpenGL ES/Vulkan window with input on the desktop — the deliberately minimal baseline for "what windowing integration cannot be omitted", offering a poll-driven event model (`glfwPollEvents`/`glfwWaitEvents`) over a thin per-platform function-pointer vtable.

| Field                | Value                                                                                            |
| -------------------- | ------------------------------------------------------------------------------------------------ |
| Version / commit     | GLFW 3.5.0 (development), commit [`b00e6a8`][glfw-commit] (studied June 8, 2026)                 |
| Language             | C99 (macOS support partly Objective-C)                                                           |
| License              | zlib/libpng ([`LICENSE.md`][glfw-license])                                                       |
| Repository           | [glfw/glfw]                                                                                      |
| Documentation        | [GLFW docs][glfw-docs] / [Intro guide][glfw-intro] / [Window guide][glfw-window-guide]           |
| Category             | Minimal windowing library (OpenGL/Vulkan window + input + monitor)                               |
| Platforms covered    | Win32, Cocoa (AppKit), Wayland, X11, plus a headless Null platform; no Android/iOS               |
| Loop ownership       | **Application-owned, poll-based** — the app calls `glfwPollEvents` each frame; GLFW owns no loop |
| Repo paths (Win32)   | [`src/win32_window.c`][src-win32], [`src/win32_init.c`][src-win32-init]                          |
| Repo paths (Cocoa)   | [`src/cocoa_window.m`][src-cocoa], [`src/cocoa_init.m`][src-cocoa-init]                          |
| Repo paths (Wayland) | [`src/wl_window.c`][src-wl], [`src/wl_init.c`][src-wl-init]                                      |
| Repo paths (X11)     | [`src/x11_window.c`][src-x11], [`src/x11_init.c`][src-x11-init]                                  |
| Repo paths (core)    | [`src/internal.h`][src-internal], [`src/window.c`][src-window], [`src/platform.c`][src-platform] |

---

## Overview

### What it solves

GLFW gives a portable C API for the handful of things a graphics application cannot do itself: open an OS window with a rendering surface, learn the size and DPI of that surface, and read keyboard/mouse/gamepad input — and nothing else. The README states the scope verbatim:

> GLFW is an Open Source, multi-platform library for OpenGL, OpenGL ES and Vulkan application development. It provides a simple, platform-independent API for creating windows, contexts and surfaces, reading input, handling events, etc.
>
> — [`README.md`][glfw-readme]

It is the spiritual baseline of the comparative study: where heavier toolkits (Qt, GTK, AppKit) bundle widgets, layout, and theming, GLFW deliberately stops at the window edge. There is no widget layer (see the companion [ui-layout catalog][ui-layout] for that axis), no software-rendering surface of its own, no menu API. The application owns its render loop and its main function; GLFW is a set of leaf functions it calls.

### Design philosophy

- **Minimal, irreducible surface area.** GLFW exposes one window type (`GLFWwindow`), four event-loop functions, and a flat C API. It is closer to a syscall shim than a framework. This makes it the cleanest specimen for "what is the floor of windowing integration".
- **Application owns the loop.** GLFW never spins its own thread or run loop. The app calls `glfwPollEvents` (non-blocking drain) or `glfwWaitEvents` (block until something happens) — see [Event loop](#2-event-loop). This is the [callback-vs-poll][loop] decision made firmly in favour of poll.
- **Thin per-platform vtable.** All platform divergence is funnelled through one struct of function pointers, `_GLFWplatform` in [`src/internal.h`][src-internal-platform]; the public API in [`src/window.c`][src-window] is a stateless forwarder. A backend is "implement these ~70 functions".
- **Runtime platform selection.** Since 3.4 a single binary can contain both Wayland and X11 backends and choose at `glfwInit` time ([`src/platform.c`][src-platform], `_glfwSelectPlatform`), defaulting to Wayland when `$WAYLAND_DISPLAY` is set, else X11.
- **Deliberate omissions are documented, not hidden.** No IME pre-edit, no menus, no software framebuffer — each is a recorded decision with a tracking issue (see [History & regrets](#10-history-redesigns--known-regrets)).

---

## How it works

### The platform vtable

The whole abstraction is one struct of function pointers, filled in by whichever backend `glfwInit` selects. The public entry points do nothing but forward through it:

```c
// src/internal.h — _GLFWplatform (abridged): the entire backend contract
struct _GLFWplatform
{
    int platformID;
    GLFWbool (*init)(void);
    void     (*terminate)(void);
    // ... input, monitor ...
    GLFWbool (*createWindow)(_GLFWwindow*,const _GLFWwndconfig*,const _GLFWctxconfig*,const _GLFWfbconfig*);
    void     (*destroyWindow)(_GLFWwindow*);
    // ... ~40 window ops ...
    void     (*pollEvents)(void);
    void     (*waitEvents)(void);
    void     (*waitEventsTimeout)(double);
    void     (*postEmptyEvent)(void);
};
```

`glfwPollEvents` is the canonical example of the forwarder pattern ([`src/window.c`][src-window-poll]):

```c
// src/window.c
GLFWAPI void glfwPollEvents(void)
{
    _GLFW_REQUIRE_INIT();
    _glfw.platform.pollEvents();
}
```

Each backend assigns its functions into a `_GLFWplatform` literal at connect time — e.g. `_glfwConnectCocoa` in [`src/cocoa_init.m`][src-cocoa-init] sets `.pollEvents = _glfwPollEventsCocoa`, and so on. There is no inheritance, no objects: just one populated struct per process.

### Window creation flow

`glfwCreateWindow` ([`src/window.c`][src-window-create]) is platform-agnostic: it snapshots the current window hints into `_GLFWwndconfig`/`_GLFWctxconfig`/`_GLFWfbconfig`, `calloc`s a `_GLFWwindow`, links it into a global intrusive list (`_glfw.windowListHead`), then calls `_glfw.platform.createWindow`. The backend is responsible for the native window and the GL/Vulkan surface. If it fails, GLFW calls `glfwDestroyWindow` to unwind.

> [!NOTE]
> GLFW has no concept of a "running" application object. The lifecycle is: `glfwInit` -> create windows -> loop calling `glfwPollEvents` + `glfwSwapBuffers` -> `glfwDestroyWindow` -> `glfwTerminate`. Everything between init and terminate is the application's responsibility.

---

## 1. Window creation & lifecycle

**Per-platform native calls** (all wrapped by the `createWindow` vtable slot):

| Platform | Native call (symbol)                                                        | File                                     |
| -------- | --------------------------------------------------------------------------- | ---------------------------------------- |
| X11      | `XCreateWindow` (in `createNativeWindow`)                                   | [`src/x11_window.c`][src-x11-create]     |
| Win32    | `CreateWindowExW` (in `createNativeWindow`)                                 | [`src/win32_window.c`][src-win32-create] |
| Cocoa    | `[GLFWWindow alloc]` / `NSWindow` (in `createNativeWindow`)                 | [`src/cocoa_window.m`][src-cocoa-create] |
| Wayland  | `wl_compositor_create_surface` + `xdg_surface`/`xdg_toplevel` (or libdecor) | [`src/wl_window.c`][src-wl-create]       |

**Attribute model.** The cross-platform hints set on `_GLFWwndconfig` are: `width`/`height`, `xpos`/`ypos` (or `GLFW_ANY_POSITION`), `title`, `resizable`, `decorated`, `floating` (always-on-top), `maximized`, `visible`, `focused`, `focusOnShow`, `autoIconify`, `mousePassthrough`, `transparent` (framebuffer alpha), and `scaleFramebuffer`. Defaults are set in `glfwDefaultWindowHints` ([`src/window.c`][src-window-create]).

**Silently unsupported per platform** — an absent feature is a finding:

- **Wayland cannot set or query absolute window position.** There is no protocol for a client to place its own toplevel; `glfwSetWindowPos`/`glfwGetWindowPos` are no-ops/errors on Wayland. X11/Win32/Cocoa honour `xpos`/`ypos`.
- **`floating` (always-on-top)** is honoured via `_NET_WM_STATE_ABOVE` on X11 and `NSWindow` level on Cocoa, but on Wayland there is no protocol to request it (it would need `wlr-layer-shell`, which GLFW does not bind — see [Wayland specifics](#4-wayland-specifics)).
- **`requestWindowAttention`** maps to `_NET_WM_STATE_DEMANDS_ATTENTION` (X11), `[NSApp requestUserAttention:]` (Cocoa), `FlashWindowEx` (Win32), and `xdg_activation_v1` (Wayland) — but only when the compositor advertises the protocol.

**Initial-frame handling** differs sharply, the canonical [no-buffer-no-window][no-buffer] split:

- **X11 / Win32 / Cocoa** map the window immediately; the WM shows it (subject to `visible`).
- **Wayland** must not create the `xdg_toplevel` until the window is actually meant to be shown, and even then nothing appears until a buffer is committed. GLFW defers shell-object creation: in `_glfwCreateWindowWayland` ([`src/wl_window.c`][src-wl-create]) the `xdg_surface`/`xdg_toplevel` are created only `if (window->monitor || wndconfig->visible)`. The surface is committed and a round-trip is performed so the compositor can send the first `configure` before GLFW attaches a buffer:

```c
// src/wl_window.c — createXdgShellObjects (tail): commit, then wait for configure
updateXdgSizeLimits(window);
wl_surface_commit(window->wl.surface);
wl_display_roundtrip(_glfw.wl.display);
```

**Surface/handle exposure for rendering.** GLFW does not have a `raw-window-handle`-style abstract handle. Instead each backend exposes a typed native accessor behind `GLFW_EXPOSE_NATIVE_*` (see [Escape hatches](#9-escape-hatches)): `glfwGetX11Window`, `glfwGetWaylandWindow`/`glfwGetWaylandDisplay`, `glfwGetWin32Window`, `glfwGetCocoaWindow`. For GPU work, `glfwCreateWindowSurface` produces a `VkSurfaceKHR` via the `createWindowSurface` vtable slot. GLFW has no software-framebuffer presentation path of its own — it assumes you bring OpenGL or Vulkan.

**Destruction-ordering hazards.** `glfwTerminate` destroys all remaining windows; the docs warn that contexts and windows must be destroyed on the main thread, and that the context must not be current on another thread at destruction. On Wayland, `destroyShellObjects` ([`src/wl_window.c`][src-wl-destroy]) unrefs the libdecor frame / xdg objects in a fixed order (decoration -> toplevel -> surface) to avoid protocol errors.

---

## 2. Event loop

**Who owns the loop: the application.** GLFW is the textbook [poll model][loop]. There are exactly two blocking disciplines, both driven by the app:

- `glfwPollEvents` — drain all pending events and return immediately (for a continuously-redrawing game loop).
- `glfwWaitEvents` / `glfwWaitEventsTimeout` — block until at least one event arrives (for an editor-style app that redraws only on input).

`glfwPostEmptyEvent` wakes a thread blocked in `glfwWaitEvents` from another thread — the one piece of cross-thread loop integration GLFW offers.

> [!IMPORTANT]
> GLFW never runs its own event thread or installs a run loop. This is the defining minimalist choice: the application's `while (!glfwWindowShouldClose(w)) { render(); glfwSwapBuffers(w); glfwPollEvents(); }` _is_ the event loop. There is no callback-driven "GLFW takes over `main`" mode.

**How each native loop is integrated:**

- **Win32** ([`src/win32_window.c`][src-win32-poll]) — `_glfwPollEventsWin32` is a standard `PeekMessageW(..., PM_REMOVE)` drain with `TranslateMessage`/`DispatchMessageW`; `_glfwWaitEventsWin32` calls `WaitMessage`; the timeout variant uses `MsgWaitForMultipleObjects(..., QS_ALLINPUT)`. `glfwPostEmptyEvent` posts `WM_NULL` to a hidden helper window.
- **Cocoa** ([`src/cocoa_window.m`][src-cocoa-poll]) — drains `[NSApp nextEventMatchingMask:NSEventMaskAny untilDate:... dequeue:YES]` and re-sends each via `[NSApp sendEvent:]`. It does **not** call `[NSApp run]`; GLFW drives `NSRunLoop` manually so the app keeps control. `glfwPostEmptyEvent` injects an `NSEventTypeApplicationDefined` event.
- **Wayland** ([`src/wl_window.c`][src-wl-poll]) — `handleEvents` multiplexes several fds with `poll(2)` (via `_glfwPollPOSIX`): the Wayland display fd, the key-repeat `timerfd`, the cursor-animation `timerfd`, and the libdecor fd. It uses the prepare-read/read-events protocol (`wl_display_prepare_read` -> `poll` -> `wl_display_read_events` -> `wl_display_dispatch_pending`) so it can block on multiple fds safely.
- **X11** ([`src/x11_window.c`][src-x11-poll]) — `_glfwPollEventsX11` drains `XPending`/`XNextEvent`; `waitForAnyEvent` does a `poll(2)` over the X connection fd, an empty-event pipe, and (on Linux) the joystick inotify fd.

**User-event injection / external fds.** The Wayland and X11 backends already multiplex extra fds in their `poll` set, but GLFW exposes **no public API to add your own fd** to the wait set — the only cross-thread wakeup is `glfwPostEmptyEvent`. Applications that need to integrate an async runtime must either poll on their own timer or run GLFW's wait in a dedicated thread.

The empty-event mechanism on X11 is a self-pipe — a clean, citable pattern:

```c
// src/x11_window.c — writeEmptyEvent: wake a blocked glfwWaitEvents from any thread
static void writeEmptyEvent(void)
{
    for (;;)
    {
        const char byte = 0;
        const ssize_t result = write(_glfw.x11.emptyEventPipe[1], &byte, 1);
        if (result == 1 || (result == -1 && errno != EINTR))
            break;
    }
}
```

**Frame pacing & vsync.** GLFW does **not** use `CVDisplayLink`/`CADisplayLink`, DXGI waitable swapchains, or X11 Present for pacing (verified: no such symbols exist in `src/`). Vsync is delegated to the rendering API's swap interval (`glfwSwapInterval` -> `eglSwapInterval`/`glXSwapIntervalEXT`/`wglSwapIntervalEXT`/NSGL). The one exception is Wayland, where a buffer swap on a hidden/occluded surface would otherwise block forever: GLFW gates the EGL swap on a `wl_surface_frame` callback ([frame-callback vsync][frame-cb]) in `_glfwWaitForEGLFrameWayland` ([`src/wl_window.c`][src-wl-frame]):

```c
// src/wl_window.c — _glfwWaitForEGLFrameWayland (tail): arm a frame callback per swap
window->wl.egl.callback = wl_surface_frame(window->wl.egl.wrapper);
wl_callback_add_listener(window->wl.egl.callback, &frameCallbackListener, window);
// If the window is hidden when the wait is over then don't swap
return window->wl.visible;
```

> [!WARNING]
> **The Win32 and Cocoa modal move/resize loops block GLFW.** When the user grabs a window edge, the OS runs its own modal loop and GLFW's `glfwPollEvents` does not return until the drag ends. The docs acknowledge this is not a bug:
>
> > Window moving and resizing (by the user) will block the main thread on some platforms. This is not a bug. Set a [refresh callback] if you want to keep the window contents updated during a move or size operation.
> >
> > — [`docs/CONTRIBUTING.md`][glfw-contributing]
>
> GLFW's mitigation is the window-refresh callback (`WM_PAINT` / `drawRect` reentry); there is no `SetTimer`-driven continuous-redraw hack inside the [Win32 modal resize loop][win32-modal].

---

## 3. Input

**Key model: physical [scancode + key token][scancode], text reported separately.** GLFW splits _key_ events (a physical key changed state) from _character_ events (text was produced), and documents that they do not map 1:1:

> Keys and characters do not map 1:1. A single key press may produce several characters, and a single character may require several keys to produce.
>
> — [`docs/input.md`][glfw-input]

The key callback delivers `(key, scancode, action, mods)`: `key` is a layout-independent token (US-layout positional, e.g. `GLFW_KEY_A`), `scancode` is the raw platform scancode, and the character callback (`_glfwInputChar`, [`src/input.c`][src-input-char]) delivers Unicode codepoints. The core key bookkeeping in `_glfwInputKey` ([`src/input.c`][src-input-key]) synthesizes `GLFW_REPEAT` (when a press arrives for an already-pressed key) and implements sticky-keys.

**Layout / xkb ownership.** On Wayland the **client owns the xkb state machine**: the compositor sends a keymap fd, GLFW compiles it with `xkb_keymap_new_from_string` and tracks modifiers with `xkb_state` ([`src/wl_init.c`][src-wl-init] loads the `libxkbcommon` symbols dynamically). On X11 the X server owns the keyboard state; GLFW uses Xkb/`XkbGetState` plus `Xutf8LookupString` for text.

**Key repeat — Wayland makes the client do it.** The Wayland protocol delivers only press/release plus a `repeat_info` (rate, delay); the client must synthesize repeats. GLFW arms a `timerfd` on press and reads accumulated expirations in the event loop. On press in `keyboardHandleKey` ([`src/wl_window.c`][src-wl-keyrepeat]):

```c
// src/wl_window.c — keyboardHandleKey (press branch): arm the key-repeat timerfd
if (xkb_keymap_key_repeats(_glfw.wl.xkb.keymap, keycode) &&
    _glfw.wl.keyRepeatRate > 0)
{
    _glfw.wl.keyRepeatScancode = scancode;
    if (_glfw.wl.keyRepeatRate > 1)
        timer.it_interval.tv_nsec = 1000000000 / _glfw.wl.keyRepeatRate;
    else
        timer.it_interval.tv_sec = 1;
    timer.it_value.tv_sec = _glfw.wl.keyRepeatDelay / 1000;
    timer.it_value.tv_nsec = (_glfw.wl.keyRepeatDelay % 1000) * 1000000;
    timerfd_settime(_glfw.wl.keyRepeatTimerfd, 0, &timer, NULL);
}
```

The event loop then reads the timerfd and replays the key+text once per expiration (`handleEvents`, the `KEYREPEAT_FD` branch in [`src/wl_window.c`][src-wl-poll]). Win32/Cocoa/X11 get repeat from the OS.

**Dead keys / compose.** Wayland feeds keysyms through `xkb_compose` (`composeSymbol` in [`src/wl_window.c`][src-wl-compose]); X11 gets composed text from `Xutf8LookupString`; Cocoa and Win32 get composed text from the OS via `insertText`/`WM_CHAR`.

> [!WARNING]
> **GLFW has no IME / pre-edit (composition) support on any backend.** There is no [pre-edit / composition][preedit] string delivered to the application, no candidate-window positioning API, and none of `zwp_text_input_v3`, Windows TSF/IMM32 pre-edit hooks, or X11 over-the-spot XIM are wired up. What each backend _does_ provide is only **committed** text:
>
> - **macOS** implements `NSTextInputClient` (`GLFWContentView` in [`src/cocoa_window.m`][src-cocoa-textinput]) but **discards the marked (pre-edit) text** in `setMarkedText:` and returns a zero-size rect at the view origin from `firstRectForCharacterRange:`, so the IME candidate window is mispositioned; only the final `insertText:` string reaches the app.
> - **X11** creates its input context with `XIMPreeditNothing | XIMStatusNothing` ([`src/x11_window.c`][src-x11-xim], `_glfwCreateInputContextX11`) — i.e. it explicitly asks for _no_ client-side pre-edit; text arrives only via `Xutf8LookupString`.
> - **Win32** receives `WM_CHAR`/`WM_UNICHAR` (so committed IME text flows) but never associates an IMM32/TSF context for pre-edit.
> - **Wayland** binds no text-input protocol at all.
>
> This is the multi-year gap tracked since issue [#41 "IME input"][glfw-issue-ime] (open since 2013), with the large unmerged [PR #2130 "Add IME support for each platform"][glfw-pr-ime] still pending. See [History & regrets](#10-history-redesigns--known-regrets).

**Pointer.** Absolute motion is the default (`_glfwInputCursorPos`). For [relative/raw motion][rawptr] GLFW has a "disabled cursor" mode (`GLFW_CURSOR_DISABLED`) that hides and recenters the cursor and reports virtual unbounded deltas, plus an optional `GLFW_RAW_MOUSE_MOTION` (`setRawMouseMotion`/`rawMouseMotionSupported` vtable slots). Raw motion uses `WM_INPUT`/`RegisterRawInputDevices` on Win32 ([`src/win32_window.c`][src-win32-rawinput]), `zwp_relative_pointer_v1` + `zwp_locked_pointer_v1` on Wayland ([`src/wl_window.c`][src-wl-relptr]), and XInput2 raw events on X11.

**High-resolution scroll.** Win32 accumulates `WM_MOUSEWHEEL` deltas divided by `WHEEL_DELTA` ([`src/win32_window.c`][src-win32-scroll]). Wayland prefers the high-resolution `axis_value120` event (`pointerHandleAxisValue120` in the `wl_pointer` listener, [`src/wl_window.c`][src-wl-axis]) falling back to the coarse `axis` event. macOS scales precise scrolling deltas by 0.1 in `scrollWheel:` ([`src/cocoa_window.m`][src-cocoa-scroll]); GLFW does **not** expose macOS momentum phases — only the summed delta.

**Cursor handling.** GLFW renders its own cursors from `GLFWimage` and uses the platform's standard-cursor set (`createStandardCursor`). On Wayland it draws cursors client-side via `libwayland-cursor` (`setCursorImage` in [`src/wl_window.c`][src-wl-cursor]) and animates them with a `timerfd`; it does **not** use the newer `wp_cursor_shape_v1` protocol (requested in issue [#2679][glfw-issue-cursorshape]).

**Touch & gestures.** GLFW has **no touch or gesture API** — no touch events, no pinch/rotate. This is an explicit scope cut; touchscreens are seen only as emulated pointer input where the OS provides it.

---

## 4. Wayland specifics

GLFW's Wayland backend (added in 3.2, matured through 3.3/3.4) binds a curated set of protocols in `registryHandleGlobal` ([`src/wl_init.c`][src-wl-registry]); the XML is vendored under [`deps/wayland/`][glfw-deps-wl].

| Protocol                             | Bound? | Use in GLFW                                                                   |
| ------------------------------------ | ------ | ----------------------------------------------------------------------------- |
| `wl_compositor` / `wl_subcompositor` | yes    | surfaces; subsurfaces for fallback decoration edges                           |
| `xdg_wm_base` / `xdg-shell`          | yes    | toplevel windows                                                              |
| `xdg-decoration-unstable-v1`         | yes    | [server-side decorations][csd-server]                                         |
| `viewporter`                         | yes    | fractional-scale destination sizing; fallback-decoration edges                |
| `fractional-scale-v1`                | yes    | per-surface fractional scale (see [DPI](#5-dpi--scaling))                     |
| `xdg-activation-v1`                  | yes    | `glfwRequestWindowAttention` / focus stealing                                 |
| `idle-inhibit-unstable-v1`           | yes    | `GLFW_FLOATING`-style idle inhibition for fullscreen                          |
| `relative-pointer-unstable-v1`       | yes    | raw mouse motion                                                              |
| `pointer-constraints-unstable-v1`    | yes    | cursor lock/confine                                                           |
| `wl_data_device_manager`             | yes    | clipboard + DnD                                                               |
| `wp_cursor_shape_v1`                 | **no** | cursors are drawn client-side instead (issue [#2679][glfw-issue-cursorshape]) |
| `zwp_text_input_v3`                  | **no** | no IME (see [Input](#3-input))                                                |
| `wlr-layer-shell`                    | **no** | no always-on-top / panel surfaces                                             |
| `xdg-output`                         | **no** | monitor geometry comes from `wl_output`                                       |

**Decorations: libdecor with own-drawn CSD fallback.** GLFW's [client-vs-server decoration][csd-server] strategy is three-tier, decided in `createShellObjects` ([`src/wl_window.c`][src-wl-shell]):

1. **libdecor** if available — `createShellObjects` prefers it whenever `_glfw.wl.libdecor.context` exists (libdecor is dlopened at runtime so it is an optional dependency).
2. else **server-side via `xdg-decoration`** — if the compositor advertises `zxdg_decoration_manager_v1`, GLFW requests `ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE`.
3. else **GLFW's own minimal client-side decorations** — flat grey subsurface edges drawn by `createFallbackDecorations` ([`src/wl_window.c`][src-wl-fallback-deco]): a 1x1 SHM buffer stretched via viewporter into a title-bar and border edges (`GLFW_CAPTION_HEIGHT`/`GLFW_BORDER_SIZE`). These are intentionally crude — no buttons, no theming.

If the compositor sends `unset` on a `xdg-decoration` it requested SSD for, GLFW falls back to drawing its own (the `xdgDecorationListener` callback at [`src/wl_window.c`][src-wl-decolistener]).

**Protocol-absence handling** is per-feature graceful degradation: viewporter missing -> no fallback decorations; fractional-scale missing -> integer buffer scale from `wl_output` enter events; activation missing -> attention request is a no-op. The compositor-name workarounds visible elsewhere are minimal here; GLFW's posture is "use the standard protocol or do without".

> [!NOTE]
> The Wayland backend's maturity lagged X11 for years; "the Wayland support is incomplete" was a standing caveat through 3.2/3.3 (issue [#1639 "Proper window decorations via libdecor"][glfw-issue-libdecor]). libdecor integration only landed in 3.4 via [PR #2285][glfw-pr-libdecor].

---

## 5. DPI & scaling

**The model: GLFW reports both a window size (logical-ish) and a framebuffer size (pixels), plus a content scale.** GLFW does not pick a single [logical-vs-physical][logical] unit globally; instead it exposes three quantities:

- `glfwGetWindowSize` — the window size in the platform's "screen coordinates".
- `glfwGetFramebufferSize` — the size in pixels (what you pass to `glViewport`).
- `glfwGetWindowContentScale` — the ratio between them (the [scale factor][scale]).

A `GLFW_SCALE_FRAMEBUFFER` hint (default on) controls whether the framebuffer is scaled up on HiDPI displays.

**Per platform:**

- **Win32** — process DPI awareness is set at init to the best available tier ([`src/win32_init.c`][src-win32-dpi]): `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` on Windows 10 1703+, else `PROCESS_PER_MONITOR_DPI_AWARE`, else `SetProcessDPIAware`. Per-monitor rescaling is handled in [`WM_DPICHANGED`][win32-dpichanged] ([`src/win32_window.c`][src-win32-dpichanged]), which both repositions the window to the OS-suggested rect and fires `_glfwInputWindowContentScale`. New-window non-client scaling uses `EnableNonClientDpiScaling`.
- **Wayland** — fractional scale comes from `wp_fractional_scale_v1`; `fractionalScaleHandlePreferredScale` ([`src/wl_window.c`][src-wl-fracscale]) receives a 120-based numerator and reports `numerator / 120.f` as the content scale, then resizes the framebuffer and uses `viewporter` to set the destination size. Without the protocol, GLFW uses the integer `wl_output` buffer scale gathered from surface-enter events (`surfaceHandleEnter`, [`src/wl_window.c`][src-wl-surfenter]).
- **macOS** — `backingScaleFactor` (1x or 2x) drives `convertRectToBacking:` to compute the pixel framebuffer ([`src/cocoa_window.m`][src-cocoa-backing]); the layer's `contentsScale` is set to match. macOS scale is effectively integer.
- **X11** — there is no per-window DPI event; GLFW derives a single system content scale from `Xft.dpi` (`getSystemContentScale` in [`src/x11_init.c`][src-x11-dpi]):

```c
// src/x11_init.c — getSystemContentScale: derive scale from Xft.dpi, like Qt/GTK
// NOTE: Basing the scale on Xft.dpi where available should provide the most
//       consistent user experience (matches Qt, Gtk, etc), although not
//       always the most accurate one
```

**The created-at-wrong-scale problem.** On Wayland the surface starts at scale 1 and only learns its real scale after the first `configure`/`preferred_scale`; GLFW handles this by deferring the buffer and re-querying scale after the round-trip in window creation. On Win32, `WM_DPICHANGED` migration between mixed-DPI monitors is honoured by accepting the suggested rect. Mixed-DPI multi-monitor on X11 is the weak spot — a single global `Xft.dpi` means a window dragged to a differently-scaled monitor does not re-scale.

---

## 6. Multi-window & popups

GLFW supports multiple top-level windows (the intrusive `windowListHead` list), but **has no popup, menu, tooltip, or modal-dialog API**. There is no `xdg_popup`, no `override-redirect` helper, no window-group/parent-child stacking primitive in the public API. Every `GLFWwindow` is an independent top-level.

This is a deliberate scope cut: menus and tooltips belong to a widget toolkit (out of scope here; see [ui-layout][ui-layout]). The consequence is that an application needing a context menu on Wayland — where a menu must be an `xdg_popup` with a [grab][overrideredirect] to dismiss-on-click-outside — cannot build one through GLFW; it must either drop to the native handle (see [Escape hatches](#9-escape-hatches)) or render the menu inside its own window. Window "modality" likewise is the app's problem; GLFW provides only `glfwFocusWindow` and input focus reporting.

> [!NOTE]
> The Wayland fallback **decoration** edges _are_ built from subsurfaces (`wl_subcompositor`), but those are internal to a single window's frame, not a popup mechanism exposed to applications.

---

## 7. Threading

**Windows must be created — and events processed — on the main thread.** This is GLFW's hardest constraint, forced by AppKit. The docs state it plainly:

> Initialization, termination, event processing and the creation and destruction of windows, cursors and OpenGL and OpenGL ES contexts are all restricted to the main thread due to limitations of one or several platforms.
>
> Because event processing must be performed on the main thread, all callbacks except for the error callback will only be called on that thread.
>
> — [`docs/intro.md`][glfw-intro-thread]

So: **the event thread is the main thread, and it is the only thread that may touch windows.** All input/window callbacks fire there, synchronously, inside `glfwPollEvents`/`glfwWaitEvents`.

**What may happen off the main thread:** OpenGL rendering — `glfwMakeContextCurrent`, `glfwSwapBuffers`, `glfwSwapInterval` may be called from any thread (a context is made current per-thread), so a render thread is allowed as long as the _windowing_ calls stay on main. The error query, the user pointer, the close flag, the raw timer, and `glfwPostEmptyEvent` are also documented as thread-callable.

**Why the model:** macOS `NSApplication`/`NSWindow` event handling must run on the main thread, and GLFW will not paper over it with a hidden dispatch hop. `_glfwInitCocoa` ([`src/cocoa_init.m`][src-cocoa-init]) sets up `NSApplication`, an app delegate, and a key-up event monitor on the calling (main) thread, and even detaches a do-nothing thread to put Cocoa into multithreaded mode.

---

## 8. Clipboard & DnD

**Clipboard** is text-only: `glfwSetClipboardString` / `glfwGetClipboardString` (the `setClipboardString`/`getClipboardString` vtable slots). No arbitrary MIME formats, no images.

- **X11** implements the full ICCCM selection dance, including [INCR][overrideredirect] for large transfers. `getSelectionString` ([`src/x11_window.c`][src-x11-selection]) converts the `CLIPBOARD` selection, advertising `UTF8_STRING`/`TARGETS` and reassembling chunked `INCR` properties in a loop. As the owner it answers `SelectionRequest` events in `handleSelectionRequest`.
- **Wayland** uses the `wl_data_device` selection model: it sets a `wl_data_source` offering `text/plain;charset=utf-8`, and reads an offered selection by `wl_data_offer_receive` into a pipe (`readDataOfferAsString` in [`src/wl_window.c`][src-wl-dataoffer]).
- **Win32** uses the standard clipboard (`OpenClipboard`/`SetClipboardData` with `CF_UNICODETEXT`) — immediate rendering, not delayed.
- **Cocoa** uses `NSPasteboard`.

**Drag-and-drop is receive-only and files-only.** GLFW exposes a path-drop callback (`glfwSetDropCallback` -> `_glfwInputDrop`); there is no drag-_source_ API and no non-file payloads. Win32 uses `WM_DROPFILES`/`DragQueryFileW` ([`src/win32_window.c`][src-win32-drop]); Cocoa reads `NSURL` file URLs in `performDragOperation:` ([`src/cocoa_window.m`][src-cocoa-drop]); Wayland reads a drag offer's `text/uri-list`; X11 implements the XDND receiver protocol.

---

## 9. Escape hatches

GLFW's leak-points are deliberate and typed. Including the right `GLFW_EXPOSE_NATIVE_*` macro before `<GLFW/glfw3native.h>` unlocks per-backend accessors that hand back the real OS objects:

| Accessor                                                         | Returns                       | File                                     |
| ---------------------------------------------------------------- | ----------------------------- | ---------------------------------------- |
| `glfwGetX11Display` / `glfwGetX11Window`                         | `Display*` / `Window`         | [`src/x11_window.c`][src-x11-native]     |
| `glfwGetWaylandDisplay` / `glfwGetWaylandWindow`                 | `wl_display*` / `wl_surface*` | [`src/wl_window.c`][src-wl-native]       |
| `glfwGetWin32Window`                                             | `HWND`                        | [`src/win32_window.c`][src-win32-native] |
| `glfwGetCocoaWindow`                                             | `id` (`NSWindow*`)            | [`src/cocoa_window.m`][src-cocoa-native] |
| `glfwGetGLXContext` / `glfwGetWGLContext` / `glfwGetNSGLContext` | native GL context             | [`src/glx_context.c`][src-glx], etc.     |

These are how applications recover what GLFW omits: build an `xdg_popup` menu from the raw `wl_surface`, install a Win32 subclass `WNDPROC`, or hand the `HWND`/`NSWindow` to a different graphics API. There is **no message-pump hook or raw-event passthrough** callback — you cannot intercept GLFW's `windowProc`/`sendEvent:` from the public API; you must reach for the native handle and subclass it yourself.

> [!NOTE]
> The breadth of these accessors (one per windowing system _and_ one per GL context type) is itself the signal of where the abstraction is known to leak: popups, system tray, custom message handling, and non-GLFW rendering APIs all require dropping to native.

---

## 10. History, redesigns & known regrets

GLFW's history is mostly _addition_ on a stable core; the windowing-layer redesigns and regrets cluster around Wayland and input:

- **Runtime platform selection (3.4, 2024).** Earlier GLFW chose its backend at compile time; 3.4 made a single binary able to hold Wayland+X11 and select at `glfwInit` (`_glfwSelectPlatform`, [`src/platform.c`][src-platform]). This was a structural refactor that produced the `_GLFWplatform` vtable as it stands today.
- **Per-monitor content scale (3.3, 2019).** `glfwGetWindowContentScale` + the content-scale callback were added to give applications HiDPI information without guessing from monitor DPI — the model now described in [DPI](#5-dpi--scaling).
- **Wayland decorations via libdecor (3.4).** For years Wayland windows had only GLFW's crude own-drawn fallback decorations; proper decorations were tracked in issue [#1639][glfw-issue-libdecor] and finally delivered by runtime-loaded libdecor in [PR #2285][glfw-pr-libdecor].
- **The long no-IME gap (open since 2013).** The single most-requested missing windowing feature. Tracking issue [#41 "IME input"][glfw-issue-ime] has been open for over a decade; later issues ([#1825][glfw-issue-1825]) and the large [PR #2130][glfw-pr-ime] ("Add IME support for each platform") remain unmerged. The maintainers' caution is that a cross-platform pre-edit API that is correct on TSF, IMM32, XIM, `zwp_text_input_v3`, and `NSTextInputClient` simultaneously is genuinely hard — so GLFW ships only committed-text input rather than a half-working pre-edit. This is the clearest illustration of GLFW's "omit rather than half-implement" stance.
- **Standing caveats.** No touch/gesture API; no `wp_cursor_shape_v1` ([#2679][glfw-issue-cursorshape]); no Wayland window positioning (protocol limitation); modal move/resize blocks the loop ([`docs/CONTRIBUTING.md`][glfw-contributing]); vsync glitches on some drivers (e.g. [#2049][glfw-issue-vsync]).

---

## Strengths

- **Irreducible, legible surface area.** The entire backend contract is one `_GLFWplatform` struct; a reader can hold the whole abstraction in their head. The cleanest reference for "the floor of windowing integration".
- **Application owns the loop.** No inversion of control, no hidden thread — trivial to embed in any game loop or to drive at a custom cadence.
- **Honest omissions.** Unsupported features error or no-op explicitly and carry tracking issues, rather than silently misbehaving.
- **Strong native escape hatches.** Typed accessors for every windowing system and GL context type mean the abstraction can always be bypassed.
- **Mature, portable core** across Win32/Cocoa/Wayland/X11 with graceful Wayland protocol degradation and runtime platform selection.

## Weaknesses

- **No IME / pre-edit on any backend** — the decade-old gap ([#41][glfw-issue-ime]); committed text only, candidate windows mispositioned on macOS.
- **No popups, menus, tooltips, modal dialogs, or window groups** — anything beyond a bare top-level requires native handles.
- **No touch or gesture input**, no scroll momentum phases, no `wp_cursor_shape_v1`.
- **Modal move/resize blocks the loop** on Win32/Cocoa; redraw only via the refresh callback.
- **No public API to add external fds** to the wait set; the only cross-thread loop primitive is `glfwPostEmptyEvent`.
- **Mixed-DPI multi-monitor on X11 is weak** — a single global `Xft.dpi` scale.
- **Main-thread-only** windowing forced by AppKit; rendering can move threads but events cannot.

## Key design decisions and trade-offs

| Decision                                                                              | Rationale                                                                                              | Trade-off                                                                                         |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------- |
| Application-owned poll loop (`glfwPollEvents`/`glfwWaitEvents`), no GLFW-owned thread | Trivial embedding; full control of cadence; matches game-loop mental model                             | Modal OS resize/move loops block the app; no place to integrate external async fds                |
| One function-pointer vtable (`_GLFWplatform`) per backend                             | Minimal, legible abstraction; a backend is a checklist                                                 | No room for backend-specific features without growing the vtable; capabilities are all-or-nothing |
| Omit IME pre-edit rather than half-implement it                                       | A correct cross-platform pre-edit API (TSF/IMM32/XIM/`text_input_v3`/`NSTextInputClient`) is very hard | Decade-long missing feature; CJK apps must drop to native                                         |
| No popup/menu/widget layer                                                            | Stays a windowing library, not a toolkit                                                               | Context menus/tooltips need native handles or in-window rendering                                 |
| Vsync via GL/EGL swap interval, no `CVDisplayLink`/waitable swapchain                 | One mechanism, fewer moving parts                                                                      | No frame-pacing telemetry; Wayland needs a special frame-callback gate to avoid blocking          |
| Typed `GLFW_EXPOSE_NATIVE_*` accessors instead of an opaque raw handle                | Explicit, compile-time-gated escape per platform                                                       | No message-pump hook; apps must subclass the native window themselves                             |
| Wayland decorations: libdecor -> SSD -> own-drawn fallback                            | Best-available decoration without a hard libdecor dependency                                           | Fallback decorations are crude (no buttons/theming); behaviour varies by compositor               |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- **The poll loop as the default contract.** `glfwPollEvents`/`glfwWaitEvents`/`glfwPostEmptyEvent` is the smallest honest event-loop API; a new framework should offer this even if it _also_ offers a callback-driven mode.
- **The single-vtable backend boundary.** `_GLFWplatform` is an exemplary "porting checklist" — every backend is the same ~70 functions, and the public API is a pure forwarder.
- **The X11 self-pipe / Wayland `timerfd` multiplexing.** Clean, copyable patterns for cross-thread wakeup and client-side key repeat.
- **Typed native escape hatches with compile-time gating.**

**Avoid / improve on:**

- **Add an external-fd integration point.** The lack of a "wait on these extra fds too" API is the main thing blocking async-runtime integration (cf. [async-io readiness model][async-io]).
- **Don't ship a windowing layer with no IME.** A modern toolkit must deliver pre-edit + candidate positioning; budget for it from day one rather than deferring a decade.
- **Provide at least a popup/grab primitive** so menus and tooltips don't force a native-handle escape.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact ordering guarantees of resize vs. content-scale vs. framebuffer-size callbacks across backends** during a monitor migration. Likely answerable by tracing `_glfwInputWindowContentScale`/`_glfwInputFramebufferSize` call sites in each `*_window.c` and the `tests/events.c` harness output.
- **Whether libdecor's own event fd can starve the Wayland key-repeat timerfd** under load (both are in the same `poll` set in `handleEvents`). Likely needs runtime instrumentation, not source reading.
- **The precise reason `dequeue:NO` hangs `_glfwWaitEventsCocoa`** — the code comment ([`src/cocoa_window.m`][src-cocoa-poll]) admits it is "not at all clear". Likely an AppKit run-loop-mode interaction documented (if anywhere) in Apple's `NSApplication`/run-loop notes.

---

## Sources

- [glfw/glfw] — main repository; all quoted file paths are pinned to commit [`b00e6a8`][glfw-commit].
- [`src/internal.h`][src-internal] — the `_GLFWplatform` vtable and `_GLFWwindow` struct.
- [`src/window.c`][src-window] / [`src/input.c`][src-input-key] / [`src/platform.c`][src-platform] — platform-agnostic core and runtime platform selection.
- Backend sources: [`src/win32_window.c`][src-win32], [`src/cocoa_window.m`][src-cocoa], [`src/wl_window.c`][src-wl], [`src/x11_window.c`][src-x11] (+ their `*_init.c`).
- [`docs/intro.md`][glfw-intro-thread] — thread-safety contract; [`docs/input.md`][glfw-input] — key/character model; [`docs/CONTRIBUTING.md`][glfw-contributing] — modal-resize caveat.
- Issues / PRs: IME [#41][glfw-issue-ime] / [#1825][glfw-issue-1825] / [PR #2130][glfw-pr-ime]; libdecor [#1639][glfw-issue-libdecor] / [PR #2285][glfw-pr-libdecor]; cursor-shape [#2679][glfw-issue-cursorshape]; vsync [#2049][glfw-issue-vsync].
- Protocols: [xdg-shell][proto-xdg-shell], [xdg-decoration][proto-xdg-deco], [fractional-scale-v1][proto-fracscale], [text-input-v3][proto-textinput], [cursor-shape-v1][proto-cursorshape]; [libdecor][libdecor]; [EWMH/wm-spec][ewmh].
- Platform APIs: [`WM_DPICHANGED`][win32-dpichanged], [`WM_MOUSEWHEEL`][win32-wheel], [`GetDpiForWindow`][win32-getdpi], [`PeekMessageW`][win32-peek]; [`NSTextInputClient`][apple-textinput], [`nextEventMatchingMask`][apple-nextevent], [`backingScaleFactor`][apple-backing].
- Sibling docs: [concepts][concepts], [ui-layout][ui-layout], [async-io readiness model][async-io].

<!-- References -->

[glfw/glfw]: https://github.com/glfw/glfw
[glfw-commit]: https://github.com/glfw/glfw/tree/b00e6a8a88ad1b60c0a045e696301deb92c9a13e
[glfw-license]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/LICENSE.md
[glfw-readme]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/README.md
[glfw-docs]: https://www.glfw.org/docs/latest/
[glfw-intro]: https://www.glfw.org/docs/latest/intro_guide.html
[glfw-window-guide]: https://www.glfw.org/docs/latest/window_guide.html
[glfw-news]: https://www.glfw.org/docs/latest/news.html
[glfw-input]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/docs/input.md
[glfw-intro-thread]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/docs/intro.md
[glfw-contributing]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/docs/CONTRIBUTING.md
[glfw-deps-wl]: https://github.com/glfw/glfw/tree/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/deps/wayland
[src-internal]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/internal.h
[src-internal-platform]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/internal.h#L683
[src-window]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/window.c
[src-window-create]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/window.c#L180
[src-window-poll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/window.c#L1166
[src-platform]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/platform.c
[src-input-key]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/input.c#L272
[src-input-char]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/input.c#L309
[src-win32]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c
[src-win32-init]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_init.c
[src-win32-create]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L1272
[src-win32-poll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L2089
[src-win32-dpi]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_init.c#L657
[src-win32-dpichanged]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L1197
[src-win32-scroll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L975
[src-win32-rawinput]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L897
[src-win32-drop]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L1230
[src-win32-native]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/win32_window.c#L2565
[src-cocoa]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m
[src-cocoa-init]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_init.m
[src-cocoa-create]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L775
[src-cocoa-poll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L1517
[src-cocoa-textinput]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L671
[src-cocoa-scroll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L602
[src-cocoa-backing]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L508
[src-cocoa-drop]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L624
[src-cocoa-native]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/cocoa_window.m#L2028
[src-wl]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c
[src-wl-init]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_init.c
[src-wl-create]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L2372
[src-wl-destroy]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1159
[src-wl-poll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1368
[src-wl-frame]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L2331
[src-wl-keyrepeat]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1943
[src-wl-compose]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1330
[src-wl-registry]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_init.c#L106
[src-wl-shell]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1148
[src-wl-fallback-deco]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L237
[src-wl-decolistener]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L439
[src-wl-fracscale]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L700
[src-wl-surfenter]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L586
[src-wl-relptr]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L3158
[src-wl-axis]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1782
[src-wl-cursor]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1239
[src-wl-dataoffer]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L1469
[src-wl-native]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/wl_window.c#L3577
[src-x11]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c
[src-x11-init]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_init.c
[src-x11-create]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c#L566
[src-x11-poll]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c#L2808
[src-x11-xim]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c#L1926
[src-x11-dpi]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_init.c#L993
[src-x11-selection]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c#L943
[src-x11-native]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/x11_window.c#L3316
[src-glx]: https://github.com/glfw/glfw/blob/b00e6a8a88ad1b60c0a045e696301deb92c9a13e/src/glx_context.c#L669
[glfw-issue-ime]: https://github.com/glfw/glfw/issues/41
[glfw-issue-1825]: https://github.com/glfw/glfw/issues/1825
[glfw-pr-ime]: https://github.com/glfw/glfw/pull/2130
[glfw-issue-libdecor]: https://github.com/glfw/glfw/issues/1639
[glfw-pr-libdecor]: https://github.com/glfw/glfw/pull/2285
[glfw-issue-cursorshape]: https://github.com/glfw/glfw/issues/2679
[glfw-issue-vsync]: https://github.com/glfw/glfw/issues/2049
[proto-xdg-shell]: https://wayland.app/protocols/xdg-shell
[proto-xdg-deco]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[proto-fracscale]: https://wayland.app/protocols/fractional-scale-v1
[proto-textinput]: https://wayland.app/protocols/text-input-unstable-v3
[proto-cursorshape]: https://wayland.app/protocols/cursor-shape-v1
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor
[ewmh]: https://specifications.freedesktop.org/wm-spec/latest/
[win32-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[win32-wheel]: https://learn.microsoft.com/en-us/windows/win32/inputdev/wm-mousewheel
[win32-getdpi]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdpiforwindow
[win32-peek]: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-peekmessagew
[apple-textinput]: https://developer.apple.com/documentation/appkit/nstextinputclient
[apple-nextevent]: https://developer.apple.com/documentation/appkit/nsapplication/nextevent(matching:until:inmode:dequeue:)
[apple-backing]: https://developer.apple.com/documentation/appkit/nswindow/backingscalefactor
[loop]: ./concepts.md#readiness-vs-completion-windowing
[csd-server]: ./concepts.md#client-vs-server-decoration
[scancode]: ./concepts.md#scancode-keysym-virtualkey
[logical]: ./concepts.md#logical-vs-physical-coords
[scale]: ./concepts.md#scale-factor
[preedit]: ./concepts.md#pre-edit-composition
[overrideredirect]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal]: ./concepts.md#win32-modal-resize-loop
[rawptr]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer]: ./concepts.md#no-buffer-no-window
[frame-cb]: ./concepts.md#frame-callback-vsync
[concepts]: ./concepts.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
[refresh callback]: https://www.glfw.org/docs/latest/window_guide.html#window_refresh
