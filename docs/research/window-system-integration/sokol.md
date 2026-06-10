# sokol_app.h (C, single-header)

A single-header, callback-driven "application wrapper" that opens **exactly one** window plus a 3D-API swapchain and pumps a unified event stream — a deliberately minimal windowing shim whose stance is "one window, one GL/Metal/D3D11/WebGPU/Vulkan context, one frame callback, and nothing you didn't ask for."

| Field             | Value                                                                                                   |
| ----------------- | ------------------------------------------------------------------------------------------------------- |
| Version / commit  | [`0eab0e9`][commit] (`floooh/sokol`, studied June 8, 2026)                                              |
| Language          | C99 (compiled as Objective-C on Apple platforms); C++ wrapper overloads provided                        |
| License           | zlib/libpng ([`LICENSE`][license])                                                                      |
| Repository        | [floooh/sokol][repo]                                                                                    |
| Documentation     | In-header doc comment (top of [`sokol_app.h`][app-h]); [sokol-samples][samples]                         |
| Category          | Single-header app/windowing shim (window + 3D context + input + entry point)                            |
| Platforms covered | Win32, macOS/AppKit, Linux/**X11 only**, iOS/UIKit, Android, Emscripten/HTML5                           |
| Loop ownership    | **Library-owned** (`sokol_app.h` hijacks `main`/`WinMain`; runs the loop and calls back into user code) |
| Repo paths        | One mega-header; per-platform code in `#if defined(_SAPP_MACOS/_WIN32/_LINUX/_APPLE/...)` blocks        |

---

## Overview

### What it solves

`sokol_app.h` is the "application-wrapper" member of Andre Weissflog's [sokol][repo] header collection. Its self-description in the [`FEATURE OVERVIEW`][app-h] block is the cleanest statement of scope:

> ```c
> // sokol_app.h, FEATURE OVERVIEW
> sokol_app.h provides a minimalistic cross-platform API which
> implements the 'application-wrapper' parts of a 3D application:
>
> - a common application entry function
> - creates a window and 3D-API context/device with a swapchain
>   surface, depth-stencil-buffer surface and optionally MSAA surface
> - makes the rendered frame visible
> - provides keyboard-, mouse- and low-level touch-events
> - platforms: MacOS, iOS, HTML5, Win32, Linux/RaspberryPi, Android
> - 3D-APIs: Metal, D3D11, GL4.1, GL4.3, GLES3, WebGL2, WebGPU, NOAPI
> ```

It is the windowing/entry-point counterpart to [`sokol_gfx.h`][gfx-h] (the rendering API): `sokol_app.h` owns the window, the event loop, the input plumbing, and the swapchain surfaces; `sokol_gfx.h` consumes those surfaces. The boundary between them is deliberately thin — `sapp_get_environment()` and `sapp_get_swapchain()` hand the GPU device/swapchain pointers across, and the (separate) `sokol_glue.h` adapts `sapp_swapchain` into `sg_swapchain`.

This deep-dive concerns only the windowing layer (window lifecycle, loop, input, presentation surfaces); the rendering API and shader/resource model are out of scope. For the layout side of GUI work see the [ui-layout catalog][ui-layout]; where the loop overlaps with async I/O see the [async-io catalog][async-io].

### Design philosophy

- **One window, one global state object.** The entire backend hangs off a single file-scope instance — `static _sapp_t _sapp;` ([`sokol_app.h`][app-h], the `_sapp_t` definition). There is no window handle parameter on any API call; `sapp_width()`, `sapp_dpi_scale()`, `sapp_set_window_title()` all implicitly act on _the_ window. Multi-window is not a missing feature so much as an architectural axiom.
- **Library owns the loop; the app is a set of callbacks.** The user writes `sokol_main()` returning an `sapp_desc` with `init_cb` / `frame_cb` / `event_cb` / `cleanup_cb`; `sokol_app.h` provides the platform's real entry point and drives those callbacks. This is the inverse of a [readiness/poll windowing model][readiness] where the app owns the loop and asks the library for events.
- **Opinionated, fixed event set.** Events are a closed `sapp_event_type` enum (~24 values) packed into one fat `sapp_event` struct. There is no generic "native event" passthrough on desktop — if an event type isn't in the enum, the app cannot see it.
- **Deliberately omits the hard, high-maintenance features.** Multi-window, server-side text input / IME, and Wayland are all absent _by design_, documented as `TODO`/`???` in the feature matrix (see [§10][s10]). The cost model is explicit: keep the header small and the per-platform surface area maintainable by one person.
- **Borrow from [GLFW][glfw].** The header states outright: "Portions of the Windows and Linux GL initialization, event-, icon- etc... code have been taken from GLFW", and the `sapp_keycode` values "are identical with GLFW." Many platform quirks are inherited GLFW workarounds, cited inline.

---

## How it works

### The `sapp_desc` contract and the callback model

The whole API surface starts from one struct returned by `sokol_main()`:

```c
// sokol_app.h — sapp_desc (abridged), returned from user's sokol_main()
typedef struct sapp_desc {
    void (*init_cb)(void);                  // after window + 3D context + swapchain exist
    void (*frame_cb)(void);                 // per-frame; "usually called 60 times per second"
    void (*cleanup_cb)(void);               // once before quitting
    void (*event_cb)(const sapp_event*);    // input + state-change events
    // ... _userdata_cb variants carrying a void* ...
    int width; int height;                  // *preferred* size; actual may differ
    int sample_count; int swap_interval;
    bool high_dpi; bool fullscreen; bool alpha;
    const char* window_title;
    bool enable_clipboard; int clipboard_size;
    bool enable_dragndrop; int max_dropped_files; /* ... */
    sapp_icon_desc icon;
    // backend-specific nested structs:
    sapp_gl_desc gl; sapp_win32_desc win32; sapp_html5_desc html5; sapp_ios_desc ios;
} sapp_desc;
```

The header is explicit that `sokol_main()` runs "very early, usually at the start of the platform's entry function" and that the callbacks may run on a different thread:

> All provided function callbacks will be called from the same thread, but this may be different from the thread where `sokol_main()` was called.

Because the standard callbacks carry no user pointer, the docs note bluntly that "any data that needs to be preserved between callbacks must live in global variables" — or you use the `_userdata_cb` variants plus `sapp_userdata()`.

### Entry-point hijacking and `sapp_run()`

By default `sokol_app.h` defines `main()` (or `WinMain`) itself. Each backend's `int main(...)` calls `sokol_main()` to obtain the desc, then enters the platform run function — e.g. `_sapp_linux_run`, `_sapp_win32_run`, `_sapp_macos_run`. Defining `SOKOL_NO_ENTRY` suppresses this; the app then writes its own `main()` and calls `sapp_run(&desc)`. The header warns that `sapp_run()`'s return semantics differ per platform (returns on Win32/Linux; "never returns" on macOS via `[NSApp run]`; "returns immediately while the frame callback keeps being called" on Emscripten), so "there shouldn't be any code _after_ `sapp_run()`."

### The unified `sapp_event`

Every event — input or state change — arrives as one fat struct, with comments documenting which fields are valid for which type:

```c
// sokol_app.h — sapp_event (abridged)
typedef struct sapp_event {
    uint64_t frame_count;
    sapp_event_type type;               // always valid
    sapp_keycode key_code;              // KEY_UP/DOWN only — a *virtual* keycode
    uint32_t char_code;                 // CHAR only — a UTF-32 code point
    bool key_repeat;
    uint32_t modifiers;                 // SAPP_MODIFIER_{SHIFT,CTRL,ALT,SUPER,LMB,RMB,MMB}
    sapp_mousebutton mouse_button;
    float mouse_x, mouse_y;             // framebuffer pixels; "always valid except during mouse lock"
    float mouse_dx, mouse_dy;           // relative movement since last frame
    float scroll_x, scroll_y;
    int num_touches; sapp_touchpoint touches[SAPP_MAX_TOUCHPOINTS];
    int window_width, window_height;            // logical-ish window size
    int framebuffer_width, framebuffer_height;  // = window_* * dpi_scale
} sapp_event;
```

Note the dual coordinate fields: a `window_*` pair and a `framebuffer_*` pair whose ratio is `dpi_scale` (see [§5][s5]).

### The presentation surfaces

`sokol_app.h` creates the swapchain and exposes it through two value structs introduced in the Dec-2025 API reshuffle: `sapp_get_environment()` returns an `sapp_environment` (the device/queue/instance objects) and `sapp_get_swapchain()` returns an `sapp_swapchain` (per-frame render/resolve/depth views, sizes, formats, and an `invalid` flag). The frame callback is meant to call `sapp_get_swapchain()` once per frame because the views "may change from one frame to the next."

---

## 1. Window creation & lifecycle

**Per-platform creation calls (the wrapped abstraction is one global window):**

| Platform    | Creation primitive                                                                                   | Where                                           |
| ----------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| macOS       | `[[_sapp_macos_window alloc] initWithContentRect:styleMask:backing:NSBackingStoreBuffered defer:NO]` | `_sapp_macos_run` / window setup                |
| Win32       | `CreateWindowExW(...)` inside `_sapp_win32_create_window` (guarded by `win32.in_create_window`)      | `_sapp_win32_run` → `_sapp_win32_create_window` |
| Linux (X11) | `XCreateWindow` in `_sapp_x11_create_window`, then `_sapp_x11_show_window`                           | `_sapp_linux_run`                               |
| iOS         | `UIWindow` + `CAMetalLayer`/`CADisplayLink` (UIScene lifecycle since the 23-Feb-2026 rewrite)        | `_sapp_ios_run`                                 |
| Android     | `ANativeWindow` driven by the `ANativeActivity` callbacks                                            | `_sapp_android_*`                               |
| HTML5       | a WebGL/WebGPU `<canvas>` looked up by CSS selector (default `#canvas`)                              | `_sapp_emsc_run`                                |

**Window-attributes model and what is silently unsupported.** The model is the flat `sapp_desc`: `width`/`height` (a _preferred_ size — the header stresses the actual size may differ), `window_title`, `fullscreen`, `high_dpi`, `alpha`, `sample_count`, `swap_interval`, and `icon`. Conspicuously absent: window **position** (no API to set or query it), **decorations toggle** (the macOS window is hard-coded `Titled | Closable | Miniaturizable | Resizable`; X11 uses default WM decorations), **always-on-top**, and explicit **transparency** control beyond the `alpha` framebuffer flag. `sapp_set_window_title()` is "only on desktop platforms" and `sapp_set_icon()` "only on Windows and Linux" — on macOS the icon changes the dock tile, not a title-bar icon (per the [`WINDOW ICON SUPPORT`][app-h] doc).

**Fullscreen** is a "soft approach": the header says sokol uses "a borderless fullscreen window instead of a 'real' fullscreen mode." X11 does it via `_NET_WM_STATE_FULLSCREEN` client messages (`_sapp_x11_set_fullscreen`); the requested width/height are ignored for the initial fullscreen size.

**Initial-frame handling.** X11 and Win32 map the window immediately and the loop renders unconditionally each turn. There is no [no-buffer-no-window][no-buffer] dance because Wayland is not supported (see [§4][s4]); X11/Win32 give immediate mapping.

**Surface/handle exposure.** Instead of a [raw-window-handle][concepts]-style trait, `sokol_app.h` exposes a long list of type-erased getters returning `const void*`: `sapp_macos_get_window()` (an `NSWindow*` bridged through C), `sapp_win32_get_hwnd()` (`HWND`), `sapp_x11_get_window()` / `sapp_x11_get_display()` (X11 `Window`/`Display`), `sapp_ios_get_window()`, `sapp_android_get_native_activity()` / `_native_window()`, plus the GPU-object getters (`sapp_metal_get_device()`, `sapp_d3d11_get_device()`, `sapp_wgpu_get_device()`, `sapp_gl_get_framebuffer()`, `sapp_egl_get_display()`). See [§9][s9].

**Destruction ordering.** On X11, `_sapp_linux_run` tears down in strict reverse: cleanup callback → GL/EGL/WGPU/VK context discard → `_sapp_x11_destroy_window` → cursors → `XCloseDisplay` → `_sapp_discard_state`. On macOS the window sets `releasedWhenClosed = NO` so cleanup can run from `applicationWillTerminate` rather than during `[NSApp run]` (which never returns).

---

## 2. Event loop

**Who owns the loop, and why.** The library owns it; the app is callbacks. The motivation is the entry-point problem stated in the [`SOKOL_NO_ENTRY`][app-h] doc: "different platforms have different entry point conventions which are not compatible with C's `main()` (for instance `WinMain` on Windows has completely different arguments)." Owning `main` lets one `sapp_desc` work everywhere. Each backend integrates the native loop differently:

**macOS — `[NSApp run]` (callback, never returns).** `_sapp_macos_run` builds an `NSApplication`, installs an app delegate, then calls `[NSApp run]`. The comment is explicit:

```objc
// sokol_app.h — _sapp_macos_run
[NSApp run];
// NOTE: [NSApp run] never returns, instead cleanup code
// must be put into applicationWillTerminate
```

Frames are driven by a display-link added to the run loop, not a manual loop (see frame pacing below).

**Win32 — a `PeekMessage` pump that also renders every turn.** `_sapp_win32_run` runs:

```c
// sokol_app.h — _sapp_win32_run (loop body, abridged)
while (!(done || _sapp.quit_ordered)) {
    _sapp_timing_update(&_sapp.timing, 0.0);
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        if (WM_QUIT == msg.message) { done = true; continue; }
        TranslateMessage(&msg); DispatchMessageW(&msg);
    }
    _sapp_win32_frame(false);             // render once per loop turn
    if (_sapp_win32_update_dimensions()) { /* recreate RT, fire RESIZED */ }
    if (_sapp.quit_requested) PostMessage(_sapp.win32.hwnd, WM_CLOSE, 0, 0);
    _sapp_win32_update_mouse_lock();
}
```

The [Win32 modal resize/move loop][win32-modal] is handled the classic way: `WM_ENTERSIZEMOVE` arms a `SetTimer(hwnd, 1, USER_TIMER_MINIMUM, NULL)`, `WM_TIMER` then calls `_sapp_timing_update` + `_sapp_win32_frame(true)` so the app keeps rendering while the user drags the frame; `WM_EXITSIZEMOVE` does `KillTimer`. A separate `WM_NCLBUTTONDOWN` workaround re-posts a `WM_MOUSEMOVE` to dodge the "half-second pause when starting to move window."

**Linux/X11 — a non-blocking busy poll.** `_sapp_linux_run` does **not** block on the X11 fd. It drains pending events with `XPending`/`XNextEvent`, then renders unconditionally, then `XFlush`:

```c
// sokol_app.h — _sapp_linux_run (loop body, abridged)
while (!_sapp.quit_ordered) {
    _sapp_timing_update(&_sapp.timing, 0.0);
    int count = XPending(_sapp.x11.display);
    while (count--) {
        XEvent event;
        XNextEvent(_sapp.x11.display, &event);   // does not block (count>0)
        _sapp_x11_process_event(&event);
    }
    _sapp_linux_frame();                          // render every turn
    XFlush(_sapp.x11.display);
    if (_sapp.quit_requested && !_sapp.quit_ordered) { /* QUIT_REQUESTED */ }
}
```

Frame pacing on X11 therefore relies on the GL **swap-interval** (`_sapp_glx_swapinterval` / `eglSwapBuffers`) to block in the swap — there is no separate timer or vsync source, and the loop is effectively render-bound. This is a [readiness-style][readiness] connection-poll rather than a blocking dispatch.

**Timers / wakeups / user-event injection.** There is essentially **none** in the cross-thread sense. There is no API to post a custom event from another thread into the loop, no external-fd integration, and no `select`/`epoll` multiplexing of the windowing fd with app fds. The only wakeups are the platform-native ones (the Win32 size-move `WM_TIMER`, the macOS display link). A long-running app that needs to integrate other fds must do so off-thread and mutate globals.

**Frame pacing & vsync sources.**

- **macOS:** a `CADisplayLink` created via `NSView`'s `displayLinkWithTarget:selector:` (macOS 14+) added to `[NSRunLoop currentRunLoop]` with a `preferredFrameRateRange` (`_sapp_macos_mtl_start_display_link`). The frame duration is taken directly from `CADisplayLink.timestamp` (no jitter filtering) — see [§10][s10]. When the window is minified/obscured the display link stops, so a 60 Hz fallback `NSTimer` (`fallbackTimerFired:`) takes over.
- **Win32 / Linux:** swap-interval driven (DXGI present / `wglSwapBuffers` / `glXSwapBuffers` / `eglSwapBuffers`); the loop renders every turn and the swap blocks for vsync.
- **iOS / Android:** `CADisplayLink` and the Android `Choreographer` respectively (the latter added for "much less jitter," per the CHANGELOG).

**Redraw coalescing.** There is no "redraw region" or damage model — sokol redraws the whole frame every turn (it is a 3D-app wrapper, not a retained-mode widget toolkit). There is no `request_redraw()`; the app cannot ask to skip frames except by doing less work in `frame_cb`.

---

## 3. Input

### Keyboard: virtual keycodes, no scancodes

`sapp_event.key_code` is a [virtual keycode][scancode], not a scancode — and the enum is **GLFW's** ("Note that the keycode values are identical with GLFW"), e.g. `SAPP_KEYCODE_A = 65`, `SAPP_KEYCODE_ESCAPE = 256`. Translation is per-platform:

- **X11:** `_sapp_x11_translate_key(keycode)` maps the hardware keycode through a keytable; text comes separately from `XLookupString` → `_sapp_x11_keysym_to_unicode`. Note: this uses core-X11 `XLookupString`, **not** `xkbcommon` — there is no client-side xkb state machine; X11 owns layout interpretation. Modifiers are emulated because "X11 doesn't set modifier bit on key down."
- **Win32:** `WM_KEYDOWN`/`WM_SYSKEYDOWN` extract the scancode via `(HIWORD(lParam) & 0x1FF)` and translate; text comes from `WM_CHAR`.
- **macOS:** `keyDown:` reads `event.keyCode` → `_sapp_translate_key`; text comes from `event.characters` (see IME below).

**Key repeat.** Each backend exposes `sapp_event.key_repeat`. On X11 sokol forces detectable auto-repeat (`XkbSetDetectableAutoRepeat(display, true, NULL)`) and tracks a per-keycode `key_repeat[]` table so the second-and-later KEY_DOWN for a held key is flagged as a repeat (`_sapp_x11_keypress_repeat`). Win32 reads the `lParam & 0x40000000` previous-state bit; macOS uses `event.isARepeat`. (Unlike Wayland — which makes the client own repeat timing entirely — none of sokol's supported backends require client-driven repeat.)

**Dead keys / compose.** Handled only insofar as the OS layout delivers composed characters through the text path (`XLookupString` / `WM_CHAR` / `NSEvent.characters`). There is no explicit compose-sequence handling in sokol.

### IME / text input — essentially absent

This is the clearest "deliberate omission." The feature matrix lists IME as `TODO`/`???` on **every** platform:

```text
// sokol_app.h — FEATURE/PLATFORM MATRIX
                    | Windows | macOS | Linux |  iOS  | Android |  HTML5
IME                 | TODO    | TODO? | TODO  | ???   | TODO    |  ???
```

There is no [pre-edit / composition][preedit] handling, no candidate-window positioning, and none of the platform IME protocols are wired up:

- **macOS does not implement `NSTextInputClient`.** The view's `keyDown:` reads `event.characters` directly and emits `SAPP_EVENTTYPE_CHAR` per UTF-16 unit (skipping the `0xF7xx` private-use function-key range). With no `setMarkedText:`/`insertText:` path, marked-text composition (the basis of CJK input on macOS) never reaches the app.
- **Win32** uses legacy `WM_CHAR`, not [TSF][tsf] or `IMM32` composition messages.
- **X11** uses `XLookupString`, not `XIM`/`XIC` (no `XFilterEvent` on the keypress path).

iOS gets an on-screen keyboard via a hidden `UITextField` (`_sapp_ios_show_keyboard` → `becomeFirstResponder`) driven by `sapp_show_keyboard(bool)` — but that is mobile soft-keyboard text entry, not desktop IME composition. Key events are cleanly separated from text: KEY_DOWN/UP carry `key_code`; CHAR carries `char_code` (UTF-32). They are simply not joined to a composition state machine.

### Pointer

- **Absolute vs relative/raw.** Normal mode reports absolute `mouse_x/y` in framebuffer pixels plus per-frame `mouse_dx/dy`. [Mouse lock][rawptr] (`sapp_lock_mouse(true)`) switches to raw relative input: on Win32 via `RegisterRawInputDevices` + `WM_INPUT` (with an absolute-vs-delta branch and a documented Remote-Desktop caveat citing [issue #806][i806]); `mouse_x/y` freeze and `mouse_dx/dy` become "raw mouse input" (platform-defined). The header notes the lock state may toggle "a few frames later" and on the web only inside short-lived input handlers (HTML5 Pointer Lock API restrictions).
- **High-resolution scroll.** Win32 `WM_MOUSEWHEEL` divides `GET_WHEEL_DELTA_WPARAM` by `WHEEL_DELTA`; there is no sub-line `WM_MOUSEWHEEL` accumulation. A Feb-2026 change "harmonized mouse wheel scaling with GLFW" (it had been 4x too fast on Windows/Emscripten — [PR #1442][pr1442]). There is no Wayland `axis_v120` path (no Wayland), and no macOS momentum-phase exposure — scroll deltas arrive as `scroll_x/scroll_y` floats.
- **Capture/confinement.** Win32 captures the mouse with button-press refcounting (`_sapp_win32_capture_mouse`/`_release_mouse`) and tracks enter/leave via `TrackMouseEvent` (`TME_LEAVE`). Confinement-to-window beyond mouse-lock is not exposed.

### Touch & gestures

Low-level multitouch only: `SAPP_EVENTTYPE_TOUCHES_{BEGAN,MOVED,ENDED,CANCELLED}` with a `touches[SAPP_MAX_TOUCHPOINTS]` array (id, pos, `changed`, and an Android `tooltype`). There is **no gesture recognition** (pinch/rotate/swipe) — the app composes gestures itself. Touch is iOS/Android/HTML5 only.

### Cursor

`sapp_set_mouse_cursor()` selects from a fixed `sapp_mouse_cursor` enum (arrow, ibeam, crosshair, pointing-hand, four resize cursors, resize-all, not-allowed) plus 16 custom slots bindable via `sapp_bind_mouse_cursor_image()`. X11 uses `Xcursor` (`XcursorLibraryLoadImage` by theme name, falling back per cursor). Win32 uses `LoadCursor`. There is no Wayland `cursor_shape_v1` path; on X11 cursors are client/theme-loaded.

---

## 4. Wayland specifics

> [!IMPORTANT]
> **`sokol_app.h` has no Wayland backend at all.** On Linux it is **X11-only**. A full-text search of the studied commit finds **zero** occurrences of `wayland`, `wl_display`, `wl_surface`, `xdg_toplevel`, or `libdecor` in `sokol_app.h`. The `_SAPP_LINUX` block opens an X11 `Display` (`XOpenDisplay(NULL)`) and links `X11, Xi, Xcursor` (per the header's link instructions). Under a Wayland session, an app built on sokol runs through **XWayland**.

Consequently every Wayland-specific dimension is **N/A here**:

- **Decorations:** no [CSD/SSD][csd] question arises — there is no `xdg-decoration`, no `libdecor`, no own-drawn client-side decorations. On X11, decorations come from the X window manager.
- **Protocol coverage:** none of `fractional-scale-v1`, `viewporter`, `xdg-activation`, `idle-inhibit`, or `layer-shell` are used (no Wayland client).
- **Compositor workarounds:** the only Wayland-adjacent grep hit in the tree is a Chromium HiDPI workaround in the GLX path (`// HACK: This is a (hopefully temporary) workaround for Chromium`), not a compositor quirk.

The maintainer-tracked feature request is [issue #245 "Wayland support"][i245] (open since Jan 2020). Adding a Wayland backend would mean confronting exactly the CSD/`libdecor`, fractional-scaling, and client-side-key-repeat work that the X11-only design currently sidesteps. [inference] The single-window, render-every-frame busy-loop model would also need an `wl_display` fd-dispatch rewrite, since Wayland has no equivalent of the X11 "just poll the connection" pattern.

---

## 5. DPI & scaling

**The model: logical window units, physical framebuffer pixels, ratio = `dpi_scale`.** The [`HIGH-DPI RENDERING`][app-h] doc gives the canonical Retina example: requesting a 640×480 window with `high_dpi = true` yields `sapp_width()`/`sapp_height()` of 1280×960 and `sapp_dpi_scale()` of 2.0. The [logical-vs-physical][logical] split is visible in `sapp_event` as the `window_*` (logical-ish) vs `framebuffer_*` (physical) pairs, with `framebuffer = window * dpi_scale`. The API-native unit for **rendering** is physical framebuffer pixels (`sapp_width/height`); mouse coordinates are reported in framebuffer pixels too.

**When the app learns the scale, and rescaling.** The header documents dynamic scale changes: "on some platforms the DPI scaling factor may change at any time (for instance when a window is moved from a high-dpi display to a low-dpi display)," and there is "no event associated with a DPI change, but an `SAPP_EVENTTYPE_RESIZED` will be sent as a side effect of the framebuffer size changing." So apps must re-read `sapp_dpi_scale()` on RESIZED.

**Per platform:**

- **macOS:** backing scale from `[[window screen] backingScaleFactor]` (`_sapp_macos_update_dimensions`); per-monitor DPI supported.
- **Windows:** the most elaborate. `_sapp_win32_init_dpi` dynamically loads `user32`/`shcore` and prefers `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` (the `(DPI_AWARENESS_CONTEXT_T)-4` value), falling back to `SetProcessDpiAwareness(PROCESS_SYSTEM_DPI_AWARE)`, then Win7's `SetProcessDPIAware()`. The header comment narrates the whole "different attempts to get DPI handling on Windows right." The [`WM_DPICHANGED`][wmdpi] handler (`_sapp_win32_dpi_changed`) fires "only if `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2` is used" and resizes the window when it migrates to a different-DPI monitor. A subtlety: for the **GL/Vulkan** backends, if `high_dpi` is _not_ requested sokol deliberately sets the process **DPI-unaware** so Windows does the upscaling.
- **Linux/X11:** **high-DPI is `TODO`** (feature matrix). `_sapp_linux_run` computes `dpi_scale = x11.dpi / 96.0f` from the X resource DB, but the comment is decisive — "on Linux system-window-size to frame-buffer-size mapping is always 1:1" — and `_sapp_x11_update_dimensions_from_window_size` feeds raw `XGetWindowAttributes` width/height straight through with no scaling. So per-monitor and fractional scaling on Linux are unsupported.

**Mixed-DPI multi-monitor & migration.** Supported on macOS and Windows (the `WM_DPICHANGED` path is exactly window-migration handling). The header states plainly: "Per-monitor DPI is currently supported on macOS and Windows" — i.e. **not** Linux.

---

## 6. Multi-window & popups

> [!WARNING]
> **There is no multi-window support, and it is not on the roadmap as a near-term feature.** The architecture forecloses it: all state lives in one `static _sapp_t _sapp;`, every API call implicitly targets that single window, and the public API has no window-handle type. There is no API for modal dialogs, tooltips, menus, popups, parent/child stacking, or window groups.

Because there is no second surface, the entire popup/grab problem space — [X11 `override-redirect` vs Wayland `xdg_popup` grab semantics][overrideredirect] — simply does not arise inside sokol. An app needing a menu or modal must either draw it _inside_ its single GL/Metal canvas (the Dear ImGui route the samples take) or reach for the native handle (see [§9][s9]) and open a real OS dialog itself. The header's only "dialog" facility is the web-platform `sapp_html5_ask_leave_site()` (the browser's hardwired "Leave Site?" box) and the documented pattern of building a "Really Quit?" dialog _with ImGui_ inside the canvas.

---

## 7. Threading

**The constraints are stated up front.** The header's threading contract is two sentences:

> All provided function callbacks will be called from the same thread, but this may be different from the thread where `sokol_main()` was called.

So: **callbacks all run on one thread** (init/frame/event/cleanup are mutually consistent), but that thread is **not guaranteed** to be the thread `sokol_main()` ran on. The header also warns: "DO NOT call any sokol-app function from inside `sokol_main()`, since sokol-app will not be initialized at this point."

**Window-creation thread.** Window and context creation happen inside the platform run function on whatever thread becomes the app/UI thread. On macOS/iOS this is the main thread (the usual AppKit/UIKit constraint — `[NSApp run]` and `CADisplayLink` are main-thread bound), which is precisely why the callback thread can differ from `sokol_main()`'s thread on some platforms.

**Rendering off the event thread.** Not supported by the model — `frame_cb` is where you render, and it runs on the callback thread. The header explicitly forbids rendering in the event callback ("Do _not_ call any 3D API rendering functions in the event callback function, since the 3D API context may not be active"). There is no provided mechanism to render from a separate thread; an app can spin its own threads but must marshal results back into `frame_cb` via globals. X11 init calls `XInitThreads()` so the X connection is at least thread-safe, but sokol itself drives X only from the loop thread.

---

## 8. Clipboard & DnD

**Clipboard — UTF-8 text only, opt-in, fixed buffer.** Disabled by default; enabled via `sapp_desc.enable_clipboard` + `clipboard_size` (default 8 KB). The header is candid that oversized strings "will be silently clipped." Only **UTF-8 text** is supported — no image or arbitrary-MIME formats. The paste event `SAPP_EVENTTYPE_CLIPBOARD_PASTED` is generated on Cmd+V (macOS), the browser `paste` event (HTML5), or Ctrl+V (everywhere else) — i.e. sokol manufactures the paste event from a keystroke rather than from a real OS clipboard-change notification on desktop.

Platform mechanics:

- **Win32:** `OpenClipboard`/`EmptyClipboard`/`SetClipboardData(CF_UNICODETEXT, ...)` with UTF-8↔wide conversion; `SetClipboardData` "takes ownership of memory object." This is **immediate-render**, not Win32 delayed rendering.
- **X11:** owns the `CLIPBOARD` selection; `_sapp_x11_get_clipboard_string` does `XConvertSelection` for `UTF8_STRING`, waits up to 0.1 s for `SelectionNotify`, and reads the property. It responds to `SelectionRequest` for `UTF8_STRING` and `TARGETS` (`_sapp_x11_on_selectionrequest`).

  > [!NOTE]
  > **X11 INCR transfers are detected but not implemented.** The getter checks `if ((actualType == incremental) || (itemCount >= buf_size))` and, in that case, logs `CLIPBOARD_STRING_TOO_BIG` and returns `NULL` rather than performing the incremental [INCR][incr] read loop. Large pastes from another app simply fail.

**Drag and drop — file paths, opt-in.** Enabled via `sapp_desc.enable_dragndrop`; on a drop the app gets `SAPP_EVENTTYPE_FILES_DROPPED` and queries `sapp_get_num_dropped_files()` / `sapp_get_dropped_file_path(i)` (UTF-8 paths). Tunables: `max_dropped_files` (default 1) and `max_dropped_file_path_length` (default 2048; if any path is longer "the entire drop operation will be silently ignored"). No MIME negotiation — files only.

- **Win32:** `WM_DROPFILES` → `_sapp_win32_files_dropped` (`DragQueryFileW`).
- **X11:** full XDND client-message protocol — `XdndAware` property set on the window, `XdndDrop`/`XdndSelection` handling, requesting `text/uri-list` and parsing URIs.
- **HTML5/WASM:** different by necessity — the browser gives "black-box file objects," so sokol adds `sapp_html5_get_dropped_file_size()` and the async `sapp_html5_fetch_dropped_file()` to read content into an app buffer.

The header notes a current gap: "no mouse positions are reported while the drag is in process."

---

## 9. Escape hatches

When the (intentionally narrow) abstraction is not enough, sokol's escape hatch is **type-erased native-handle getters** rather than a structured raw-handle trait. Each returns a `const void*` that the caller casts back:

| Need                  | Getter(s)                                                                                                                                                                                           |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native window/display | `sapp_macos_get_window` (`NSWindow*`), `sapp_win32_get_hwnd` (`HWND`), `sapp_x11_get_window` + `sapp_x11_get_display`, `sapp_ios_get_window`, `sapp_android_get_native_activity` / `_native_window` |
| GPU device/context    | `sapp_metal_get_device`, `sapp_d3d11_get_device` / `_get_device_context`, `sapp_wgpu_get_device`, `sapp_egl_get_display` / `_get_context`                                                           |
| GPU swapchain views   | `sapp_get_swapchain()` (struct), `sapp_d3d11_get_swap_chain`, `sapp_metal_get_current_drawable`                                                                                                     |
| GL specifics          | `sapp_gl_get_framebuffer`, `sapp_gl_get_major_version` / `_minor_version`, `sapp_gl_is_gles`                                                                                                        |

The header is careful about the Objective-C bridging: these void pointers "are actually Objective-C ids converted with a (ARC) `__bridge` cast so that the ids can be tunneled through C code," and must be `__bridge`-cast back. **What leaks most:** the absence of a generic native-event passthrough on desktop. `sapp_consume_event()` exists to stop an event being forwarded to the OS — but the header admits "this behaviour is currently only implemented for some HTML5 events." So an app cannot, on Win32/macOS/X11, intercept native messages the enum doesn't model; the only recourse is the native window handle plus its own subclass/hook.

---

## 10. History, redesigns & known regrets

The richest sources are the [`CHANGELOG.md`][changelog] and the in-header `FEATURE/PLATFORM MATRIX` (which encodes the known gaps as `TODO`/`???`). Major windowing-layer events:

- **2025-12-02 — swapchain/window decoupling from sokol-gfx ([PR notes][changelog]).** A breaking API reshuffle: backend-specific `sapp_desc` fields moved into nested structs; new `sapp_get_environment()` → `sapp_environment` and `sapp_get_swapchain()` → `sapp_swapchain` value structs replaced "a ton of platform/backend specific functions ... which returned type-erased pointers to various 3D backend objects." This cleanly separated "what surfaces exist this frame" from the rendering API.
- **2026-02-20 — macOS: `MTKView` removed, `CAMetalLayer` + `CADisplayLink` adopted ([PR #1444][pr1444]).** The maintainer's own retrospective is the clearest "regret" in the tree:

  > Dropping `MTKView` was planned for a long time because of its 'brittleness': updating macOS versions would sometimes come with surprising swapchain behaviour changes...

  The upside: `CADisplayLink` gives "the most stable presentation timestamp I've seen anywhere yet" — frame duration straight from the timestamp, "without _any_ timing jitter." The downside, openly flagged as possibly premature: "the min-spec for sokol_app.h had to be bumped to macOS 14 (Sonoma)... This might be a bit too soon." It also introduced the minified/obscured-window problem (display link stops) and the 60 Hz fallback `NSTimer`, with a planning ticket ([issue #1446][i1446]) left open for a proper fix.

- **2026-02-23 — iOS: `MTKView` removed, UIScene lifecycle + `CADisplayLink` ([PR #1447][pr1447]).** Bumped min iOS to 15; only tested in the simulator ("I currently don't own any recent physical iOS devices").
- **Earlier — Android `Choreographer` and a "complete rewrite of the frame timing code"** (jitter-filtered `sapp_frame_duration()` plus unfiltered variant), both in the CHANGELOG.
- **2026-02-12 — mouse-wheel scaling fix ([PR #1442][pr1442]):** Windows/Emscripten wheel deltas had been 4x too fast for years.

**Long-standing open gaps (each a deliberate non-goal, not a bug):**

- **Wayland — [issue #245][i245], open since 2020.** No backend; X11/XWayland only (see [§4][s4]).
- **Multi-window — architecturally precluded** by the single global `_sapp` (see [§6][s6]).
- **IME — `TODO` on every platform** in the feature matrix (see [§3][s3]); no `NSTextInputClient`/`TSF`/`XIM`.
- **High-DPI on Linux — `TODO`** (see [§5][s5]).

The throughline: sokol*app.h's "regrets" are mostly about \_depending on platform middleware* (`MTKView`) that shifted under it, and its omissions are an explicit maintainability budget — fewer platforms/features one author can keep working over a decade.

---

## Strengths

- **Trivial integration.** Drop in one header, write `sokol_main()`, get a window + GPU context + input on six platforms. No build-system surgery.
- **Uniform, tiny API.** One `sapp_desc`, one `sapp_event`, ~50 functions. The mental model is small enough to hold entirely in your head.
- **Clean GPU-surface handoff.** `sapp_get_environment()`/`sapp_get_swapchain()` make the windowing↔rendering boundary explicit and backend-agnostic (GL/Metal/D3D11/WebGPU/Vulkan).
- **Honest documentation.** The header's feature matrix tells you exactly what is `TODO`/unsupported per platform — rare candor.
- **Excellent frame pacing where it counts.** The macOS `CADisplayLink` timestamp path yields jitter-free frame durations; Android uses `Choreographer`.
- **Pragmatic native escape hatches.** Every native window/device handle is reachable for the cases sokol doesn't cover.

## Weaknesses

- **Single window, full stop.** No second window, no real popups/menus/modal dialogs — you draw them inside your canvas or go native.
- **No IME / desktop text composition.** A non-starter for CJK text-entry apps; `NSTextInputClient`/TSF/XIM are all unimplemented.
- **X11-only on Linux.** Native Wayland (fractional scaling, CSD, modern protocols) is absent; you run under XWayland.
- **High-DPI broken on Linux** (1:1 mapping; `dpi_scale` plumbed but not applied to the framebuffer).
- **Busy-loop on Win32/Linux.** Render-every-turn with no blocking dispatch; no external-fd/timer/user-event integration for app-driven idling.
- **Closed event set, no native passthrough on desktop.** `sapp_consume_event()` works only for some HTML5 events; unmodeled native events are invisible.
- **Incomplete X11 clipboard.** INCR transfers fail; UTF-8 text only; fixed-size buffer silently truncates.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                           | Trade-off                                                                         |
| ------------------------------------------------------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Single global window (`static _sapp_t _sapp;`)          | Smallest possible API; no handle plumbing; one author can maintain it               | Multi-window, popups, and real modal dialogs are impossible without native escape |
| Library owns the loop; app is callbacks                 | One `sapp_desc` works across six wildly different entry-point conventions           | App can't own its loop; no external-fd/async-runtime integration; idling is hard  |
| Closed `sapp_event` enum, no desktop native passthrough | Tiny, portable event surface; identical semantics everywhere                        | Anything not in the enum is unreachable except via the native handle              |
| X11-only on Linux (no Wayland)                          | Avoids the CSD/`libdecor`/fractional-scale/client-key-repeat maintenance burden     | No native Wayland; XWayland only; high-DPI on Linux left `TODO` (issue #245 open) |
| No IME / `NSTextInputClient`/TSF/XIM                    | Composition is huge per-platform work for a 3D-app wrapper                          | CJK and complex text input don't work; `keyDown:` reads `characters` directly     |
| Virtual keycodes = GLFW's, text via OS layout path      | Reuse GLFW's battle-tested keytables and keycode constants                          | Inherits GLFW quirks; no `xkbcommon` state machine on X11                         |
| Render every loop turn; vsync via swap-interval         | Dead-simple pacing for a render-bound 3D app                                        | Wasteful for idle/event-driven UIs; Win32 needs a size-move `WM_TIMER` hack       |
| Type-erased `const void*` native getters                | Tunnel `HWND`/`NSWindow`/`Display` through plain C without platform headers leaking | No structured raw-handle contract; caller must know the cast and lifetime rules   |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **explicit windowing↔rendering surface boundary** (`sapp_get_swapchain()` as a per-frame value struct with an `invalid` flag) — it cleanly decouples "what surfaces exist now" from the GPU API, and the `invalid` flag is a tidy way to handle minimized/zero-sized swapchains.
- The **honest feature/platform matrix** in the docs — encoding `TODO`/unsupported per platform per feature is a discipline every windowing library should copy.
- The **`CADisplayLink` timestamp-as-frame-duration** insight for jitter-free pacing on Apple platforms.
- The **opt-in, budgeted clipboard/DnD** (fixed buffer, declared limits) as a model for "good enough, predictable" when full fidelity isn't the goal.

**Avoid (for a general-purpose toolkit):**

- The **single global window** — fine for a game/demo, fatal for anything needing menus, tooltips, dialogs, or multiple top-levels. Make windows first-class handles from day one.
- **Render-every-turn busy loops** — a modern library should block on a unified fd/dispatch and support `request_redraw()`, user-event injection, and external-fd integration ([readiness vs completion][readiness] both want this).
- **Skipping IME** — acceptable for a 3D-app shim, unacceptable for a text-capable toolkit; design the [pre-edit/composition][preedit] path in early because retrofitting `NSTextInputClient`/TSF/`zwp_text_input_v3` is painful.
- **X11-only on Linux in 2026** — a new library should target Wayland natively (and thus confront [CSD/SSD][csd] and fractional scaling) rather than leaning on XWayland.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exactly which thread runs the callbacks on Android/Emscripten?** The header says "same thread, may differ from `sokol_main()`'s thread" but not which. Likely answer: the `_SAPP_ANDROID` block (the `ANativeActivity` callback thread setup) and `_sapp_emsc_run` (the browser main thread / `emscripten_request_animation_frame_loop`).
- **Does the Vulkan backend's render-during-resize differ from GL/D3D11 on Win32?** The CHANGELOG mentions Win32+Vulkan resize stutter "waiting for vsync"; the precise loop interaction is in the `_SAPP_WIN32` Vulkan swapchain path and [PR #1430][pr1430].
- **Will the macOS minified/obscured "fallback timer" be replaced by a proper workload-reduction signal?** Tracked in the open planning ticket [issue #1446][i1446].
- **Is there any path to native Wayland without rewriting the loop model?** The render-every-turn X11 poll has no `wl_display` analogue; the design discussion would land on [issue #245][i245] if/when it's revisited. [inference]

---

## Sources

- [floooh/sokol][repo] — repository (all quoted paths at commit [`0eab0e9`][commit])
- [`sokol_app.h`][app-h] — the single mega-header: doc comment, `sapp_desc`/`sapp_event`, and the per-platform `_sapp_*_run` / `WndProc` / event code quoted throughout
- [`CHANGELOG.md`][changelog] — windowing-layer redesign history (MTKView removal, swapchain decoupling, timing rewrite, wheel-scale fix)
- [`LICENSE`][license] — zlib/libpng license
- [`sokol_gfx.h`][gfx-h] — the rendering API the windowing layer hands surfaces to (boundary context)
- [Issue #245 — Wayland support][i245]; [Issue #1446 — minified/obscured frame handling][i1446]; [Issue #806 — raw-input absolute-position caveat][i806]
- [PR #1444][pr1444] / [PR #1447][pr1447] — macOS/iOS `CAMetalLayer` + `CADisplayLink` migration; [PR #1442][pr1442] — wheel scaling; [PR #1430][pr1430] — Win32 Vulkan frame sync
- [GLFW][glfw] — upstream of sokol's keycode table and many platform workarounds
- Concepts: [windowing concepts][concepts]; sibling catalogs: [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[repo]: https://github.com/floooh/sokol
[commit]: https://github.com/floooh/sokol/tree/0eab0e92731f997312b139292b327b34e1c9e5a9
[app-h]: https://github.com/floooh/sokol/blob/0eab0e92731f997312b139292b327b34e1c9e5a9/sokol_app.h
[gfx-h]: https://github.com/floooh/sokol/blob/0eab0e92731f997312b139292b327b34e1c9e5a9/sokol_gfx.h
[changelog]: https://github.com/floooh/sokol/blob/0eab0e92731f997312b139292b327b34e1c9e5a9/CHANGELOG.md
[license]: https://github.com/floooh/sokol/blob/0eab0e92731f997312b139292b327b34e1c9e5a9/LICENSE
[samples]: https://github.com/floooh/sokol-samples
[i245]: https://github.com/floooh/sokol/issues/245
[i1446]: https://github.com/floooh/sokol/issues/1446
[i806]: https://github.com/floooh/sokol/issues/806
[pr1444]: https://github.com/floooh/sokol/pull/1444
[pr1447]: https://github.com/floooh/sokol/pull/1447
[pr1442]: https://github.com/floooh/sokol/pull/1442
[pr1430]: https://github.com/floooh/sokol/pull/1430
[glfw]: https://www.glfw.org/
[wmdpi]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[tsf]: https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[concepts]: ./concepts.md
[csd]: ./concepts.md#csd-vs-ssd
[scancode]: ./concepts.md#scancode-keysym-virtualkey
[logical]: ./concepts.md#logical-vs-physical-coords
[preedit]: ./concepts.md#pre-edit-composition
[overrideredirect]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal]: ./concepts.md#win32-modal-resize-loop
[rawptr]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer]: ./concepts.md#no-buffer-no-window
[readiness]: ./concepts.md#readiness-vs-completion-windowing
[csd-server]: ./concepts.md#client-vs-server-decoration
[incr]: https://www.x.org/releases/X11R7.7/doc/xorg-docs/icccm/icccm.html
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
[s4]: #4-wayland-specifics
[s5]: #5-dpi-scaling
[s6]: #6-multi-window-popups
[s9]: #9-escape-hatches
[s10]: #10-history-redesigns-known-regrets
[s3]: #3-input
