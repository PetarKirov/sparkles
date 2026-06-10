# SDL3 (C)

Simple DirectMedia Layer 3: a cross-platform C library that abstracts windowing, input, audio, and GPU presentation behind one portable API, taking the stance that an app should "simply [create] a window and [listen] for events" while the library hides every per-platform windowing protocol underneath.

| Field             | Value                                                                                                 |
| ----------------- | ----------------------------------------------------------------------------------------------------- |
| Version/commit    | SDL `3.5.0` dev tree, commit [`b53f1b06`][commit] (2026-06-07)                                        |
| Language          | C (C99/C11), with `.m` Objective-C for Cocoa/UIKit and `.cpp` for GameInput                           |
| License           | [Zlib][license]                                                                                       |
| Repository        | [libsdl-org/SDL][repo]                                                                                |
| Documentation     | [SDL3 wiki][wiki] / [`README-migration.md`][migration] / [`README-highdpi.md`][highdpi]               |
| Category          | Windowing + media library (windowing, input, audio, GPU/render)                                       |
| Platforms covered | Wayland, X11, Win32, Cocoa (macOS), UIKit (iOS), Android, plus KMSDRM, Emscripten, Haiku, consoles    |
| Loop ownership    | **Hybrid** — app owns the loop by default (`SDL_PollEvent`); `SDL_MAIN_USE_CALLBACKS` inverts control |
| Repo paths        | `src/video/{wayland,x11,windows,cocoa}/`, `src/video/SDL_video.c`, `src/events/`, `src/main/`         |

---

## Overview

### What it solves

SDL is the lingua franca of cross-platform game and media development: it gives a single C entry point to window creation, the OS event stream, keyboard/mouse/pen/touch/gamepad input, the clipboard, and GPU/software presentation, so an application never touches `wl_surface`, `XCreateWindow`, `CreateWindowEx`, or `NSWindow` directly. The header for the video subsystem states the design goal plainly:

> Of course, it can simply get out of your way and give you the window handles you need to use Vulkan, Direct3D, Metal, or whatever else you like directly, too.
>
> The video subsystem covers a lot of functionality, out of necessity, so it is worth perusing the list of functions just to see what's available, but most apps can get by with simply creating a window and listening for events, so start with `SDL_CreateWindow()` and `SDL_PollEvent()`.
>
> — [`include/SDL3/SDL_video.h`][sdl-video-h] (header doc comment)

The windowing layer is one piece of a larger media library, but it carries the same contract everywhere: a unified `SDL_Event` union, a `SDL_Window` opaque handle, and a [properties][props-h] bag for the rare native-handle escape. Layout and widget toolkits are explicitly **not** SDL's job — it is the substrate that toolkits like Dear ImGui, [Clay][clay], or Nuklear render on top of (see [ui-layout][ui-layout] for that layer).

### Design philosophy

- **One portable API, per-platform backends behind a vtable.** Every backend implements the `SDL_VideoDevice` function-pointer table in [`src/video/SDL_sysvideo.h`][sysvideo-h]; `SDL_CreateWindow` in [`SDL_video.c`][video-c] dispatches `_this->CreateWindow(...)` to `Wayland_CreateWindow` / `X11_CreateWindow` / `WIN_CreateWindow` / `Cocoa_CreateWindow`.
- **The app owns its loop — unless the platform refuses.** The default model is a synchronous `SDL_PollEvent` pump the app drives. SDL3 adds an _optional_ inverted **main-callbacks** model (`SDL_AppInit`/`SDL_AppIterate`/`SDL_AppEvent`/`SDL_AppQuit`) for platforms that "would rather be in charge of that `while` loop" (iOS, Emscripten, Wayland frame-driven animation).
- **Properties replace typed getters.** SDL3 deleted `SDL_GetWindowWMInfo` and the typed `SDL_GetWindowData`; native handles now live in a string-keyed `SDL_PropertiesID` bag (`SDL_GetWindowProperties`), a deliberate extensibility move so adding `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER` never breaks ABI.
- **Native units, not a synthetic coordinate space.** SDL3 reversed SDL2's behavior: "Interfaces provided by SDL [use] the platform's native coordinates unless otherwise specified" ([`README-highdpi.md`][highdpi]). The library exposes the scale rather than hiding it.
- **Escape hatches are first-class.** `SDL_SetWindowsMessageHook`, `SDL_SetX11EventHook`, and the native-handle properties are documented API, not back doors — SDL assumes its abstraction will leak and gives you the raw layer when it does.

---

## How it works

### Core types and the dispatch table

The central objects are `SDL_Window` (opaque, defined in [`SDL_sysvideo.h`][sysvideo-h]), `SDL_VideoDevice` (the per-backend vtable), and the `SDL_Event` tagged union ([`SDL_events.h`][events-h]). One `SDL_VideoDevice` is selected at init (`SDL_VideoInit`) from a static list of backend bootstraps; on Linux SDL probes Wayland first, then X11. Window operations are virtual calls:

```c
// src/video/SDL_sysvideo.h — the per-backend window vtable (excerpt)
struct SDL_VideoDevice
{
    bool (*CreateWindow)(SDL_VideoDevice *_this, SDL_Window *window, SDL_PropertiesID create_props);
    void (*ShowWindow)(SDL_VideoDevice *_this, SDL_Window *window);
    void (*SetWindowSize)(SDL_VideoDevice *_this, SDL_Window *window);
    void (*PumpEvents)(SDL_VideoDevice *_this);
    int  (*WaitEventTimeout)(SDL_VideoDevice *_this, Sint64 timeoutNS);
    void (*DestroyWindow)(SDL_VideoDevice *_this, SDL_Window *window);
    // ...dozens more...
};
```

### The default loop: `SDL_PollEvent` → `SDL_PumpEvents` → backend

In the classic model the app drives the loop. `SDL_PollEvent` calls `SDL_PumpEvents`, which calls the backend's `PumpEvents` to drain the native queue and translate native events into `SDL_Event`s pushed onto SDL's internal queue, then dequeues one. Each backend's `PumpEvents` is the integration seam with the native loop (see [Event loop](#2-event-loop)).

### The optional inverted loop: main callbacks

`SDL_MAIN_USE_CALLBACKS` flips ownership: the app provides four functions and SDL owns `main`. The generic implementation in [`src/main/generic/SDL_sysmain_callbacks.c`][gen-callbacks] runs the loop itself:

```c
// src/main/generic/SDL_sysmain_callbacks.c — the faked loop on platforms that don't need real callbacks
while ((rc = GenericIterateMainCallbacks()) == SDL_APP_CONTINUE) {
    // ...rate-limit to SDL_HINT_MAIN_CALLBACK_RATE, else run at the pace the video subsystem allows...
}
```

The shared core ([`src/main/SDL_main_callbacks.c`][callbacks-c]) installs an event watcher and dispatches events to `SDL_AppEvent` before each `SDL_AppIterate`; `SDL_IterateMainCallbacks` pumps, dispatches, then calls the iterate callback. The whole result is an atomic `SDL_AppResult` so a quit can land from any thread:

```c
// src/main/SDL_main_callbacks.c
SDL_AppResult SDL_IterateMainCallbacks(bool pump_events)
{
    if (pump_events) {
        SDL_PumpEvents();
    }
    SDL_DispatchMainCallbackEvents();
    SDL_AppResult rc = (SDL_AppResult)SDL_GetAtomicInt(&apprc);
    if (rc == SDL_APP_CONTINUE) {
        rc = SDL_main_iteration_callback(SDL_main_appstate);
        // CAS so a quit set by another thread isn't clobbered...
    }
    return rc;
}
```

> [!NOTE]
> This is the headline windowing-layer change from SDL2. On iOS the loop is driven by a `CADisplayLink`, on Emscripten by `emscripten_set_main_loop`; the same four callbacks work unchanged everywhere because non-callback platforms "fake them with a simple loop in an internal implementation of the usual `SDL_main`" ([`README-main-functions.md`][mainfns]).

---

## 1. Window creation & lifecycle

`SDL_CreateWindow(title, w, h, flags)` and `SDL_CreateWindowWithProperties(props)` both funnel into `SDL_CreateWindow` in [`SDL_video.c`][video-c], which allocates the `SDL_Window`, then calls the backend `CreateWindow`. The native call per platform:

| Platform | Function                                                        | Native call                                                                                                           |
| -------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Win32    | `WIN_CreateWindow` ([`SDL_windowswindow.c:692`][win-create])    | `CreateWindowEx(styleEx, SDL_Appname, ...)`                                                                           |
| X11      | `X11_CreateWindow` ([`SDL_x11window.c:556`][x11-create])        | `X11_XCreateWindow(display, RootWindow(...), ...)` then `XMapWindow` on show                                          |
| Cocoa    | `Cocoa_CreateWindow` ([`SDL_cocoawindow.m:2421`][cocoa-create]) | `[[SDL3Window alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO screen:screen]` |
| Wayland  | `Wayland_CreateWindow` ([`SDL_waylandwindow.c`][wl-window])     | `wl_compositor_create_surface`; the `xdg_surface`/`xdg_toplevel` role is assigned later in `Wayland_ShowWindow`       |

**Attribute model.** Window flags are a 64-bit bitfield in [`SDL_video.h:197`][win-flags]: `SDL_WINDOW_FULLSCREEN`, `SDL_WINDOW_BORDERLESS`, `SDL_WINDOW_RESIZABLE`, `SDL_WINDOW_ALWAYS_ON_TOP`, `SDL_WINDOW_TRANSPARENT`, `SDL_WINDOW_HIGH_PIXEL_DENSITY`, `SDL_WINDOW_UTILITY`, `SDL_WINDOW_TOOLTIP`, `SDL_WINDOW_POPUP_MENU`, `SDL_WINDOW_NOT_FOCUSABLE`, and more. Per-platform silent gaps are real:

- **Always-on-top** maps to `xdg`/libdecor on Wayland only weakly; Wayland deliberately offers no protocol to position a toplevel, so `SDL_SetWindowPosition` on a Wayland toplevel is silently a no-op (the compositor owns placement).
- **Transparency** requires `SDL_WINDOW_TRANSPARENT` plus an alpha-capable buffer; on Wayland SDL drops the opaque region (`SetSurfaceOpaqueRegion`, [`SDL_waylandwindow.c:294`][wl-opaque]) so the compositor blends, while on X11 it depends on a compositing WM being present.
- **Fullscreen** is real fullscreen on all four; Wayland uses `xdg_toplevel_set_fullscreen`, X11 sets `_NET_WM_STATE_FULLSCREEN`, Win32 manipulates style + `SetWindowPos`, Cocoa toggles native fullscreen spaces.

**Initial-frame handling diverges sharply.** Win32 and X11 map immediately (`CreateWindowEx` + `ShowWindow`; `XMapWindow`). Wayland enforces the [no-buffer-no-window][concepts-nbnw] rule: a surface is invisible until a buffer is committed, and the role can only be used after the compositor's `configure`. `Wayland_ShowWindow` round-trips and blocks for the configure before the surface is usable:

```c
// src/video/wayland/SDL_waylandwindow.c (Wayland_ShowWindow) — must wait for the compositor's configure
/* We have to wait until the surface gets a "configure" event, or use of
 * this surface will fail. This is a new rule for xdg_shell.
 */
while (data->shell_surface_status == WAYLAND_SHELL_SURFACE_STATUS_WAITING_FOR_CONFIGURE) {
    if (libdecor_dispatch(c->shell.libdecor, -1) < 0) { /* ...handle disconnect... */ }
    if (WAYLAND_wl_display_dispatch_pending(c->display) < 0) { /* ... */ }
}
```

**Surface/handle exposure for rendering.** Native handles are exposed through the [properties][props-h] system (`SDL_GetWindowProperties`): `SDL_PROP_WINDOW_WIN32_HWND_POINTER`, `SDL_PROP_WINDOW_COCOA_WINDOW_POINTER`, `SDL_PROP_WINDOW_X11_DISPLAY_POINTER` + `SDL_PROP_WINDOW_X11_WINDOW_NUMBER`, `SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER` + `SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER` (all listed in [`SDL_video.h`][win-flags]). This is SDL3's [`SDL_GetWindowProperties`][props-h] equivalent of Qt's QPA native interface or Rust's `raw-window-handle`.

**Destruction ordering.** `SDL_DestroyWindow` tears down children first; on Wayland the shell-surface objects (`xdg_popup`, `xdg_toplevel`, `xdg_surface`, then `wl_surface`) must be destroyed in protocol order, and a parent toplevel may not be destroyed while a popup grab is live without a protocol error — child windows are shown only after the parent reaches `WAYLAND_SHELL_SURFACE_STATUS_SHOWN` (the `surface_frame_done` callback walks `first_child` to release pending children, [`SDL_waylandwindow.c:840`][wl-framedone]).

---

## 2. Event loop

**Who owns the loop.** By default the **app** owns it (`SDL_PollEvent`/`SDL_WaitEvent` pump). The `SDL_MAIN_USE_CALLBACKS` model hands ownership to **SDL**, which on real callback platforms hands it to the OS. The motivation is explicitly platform-driven:

> There are platforms that would rather be in charge of that `while` loop: iOS would rather you return from `main()` immediately and then it will let you know that it's time to update and draw the next frame of video. Emscripten (programs that run on a web page) absolutely requires this to function at all. Video targets like Wayland can notify the app when to draw a new frame, to save battery life and cooperate with the compositor more closely.
>
> — [`docs/README-main-functions.md`][mainfns]

This is the central redesign relative to SDL2, which only ever offered the synchronous pump (the `SDL_iPhoneSetAnimationCallback` hack on iOS aside). See [readiness-vs-completion-windowing][concepts-rvc] for how this "who calls whom" question generalizes.

**Native loop integration, per backend:**

- **Win32** — `WIN_PumpEvents` ([`SDL_windowsevents.c:2590`][win-pump]) drains the thread message queue with `PeekMessage(..., PM_REMOVE)` + `TranslateMessage` + `DispatchMessage`, capping at ~1 ms of work so it can't busy-loop forever. The **[modal resize/move loop][concepts-win32modal]** is handled specially: `WM_ENTERSIZEMOVE` installs a timer keyed on the callback function pointer, and `WM_TIMER` runs a live-resize iteration so rendering continues while the user drags the frame:

  ```c
  // src/video/windows/SDL_windowsevents.c — keep iterating during the Win32 modal resize loop
  case WM_ENTERSIZEMOVE:
  case WM_ENTERMENULOOP:
      ++data->in_modal_loop;
      if (data->in_modal_loop == 1) {
          SetTimer(hwnd, (UINT_PTR)SDL_IterateMainCallbacks, USER_TIMER_MINIMUM, NULL);
      }
      break;
  case WM_TIMER:
      if (wParam == (UINT_PTR)SDL_IterateMainCallbacks) {
          SDL_OnWindowLiveResizeUpdate(data->window);   // app keeps drawing while DefWindowProc blocks
          return 0;
      }
      break;
  ```

- **Cocoa** — `Cocoa_PumpEvents` ([`SDL_cocoaevents.m:633`][cocoa-pump]) wraps `nextEventMatchingMask:untilDate:inMode:dequeue:` in `NSDefaultRunLoopMode`, forwarding each `NSEvent` to `[NSApp sendEvent:]`. `Cocoa_WaitEventTimeout` blocks on `[NSDate distantFuture]`; user wakeups are injected with a synthetic `NSEventTypeApplicationDefined` event posted via `[NSApp postEvent:atStart:YES]` (`Cocoa_SendWakeupEvent`).

- **Wayland** — `Wayland_PumpEvents` ([`SDL_waylandevents.c:598`][wl-pump]) drives the fd-dispatch dance by hand: `wl_display_prepare_read` / `wl_display_flush` / `SDL_IOReady(display_fd, ...)` / `wl_display_read_events` / `wl_display_dispatch_pending`, plus `libdecor_dispatch`. It is the readiness-on-an-fd model. **Frame pacing** uses [frame callbacks][concepts-framevsync]: `surface_frame_done` ([`SDL_waylandwindow.c:810`][wl-framedone]) re-arms `wl_surface_frame` every frame, damages the surface, and advances the show-state machine — vsync comes from the compositor telling you when to draw, not from a clock.

- **X11** — `X11_PumpEvents` ([`SDL_x11events.c:2322`][x11-pump]) loops `X11_PollEvent` → `X11_DispatchEvent` over the connection, and also services bookkeeping: fullscreen-mode-switch deadlines, screensaver tickle every 30 s, window-flash timers, and XInput2 hierarchy changes.

**Timers/wakeups & external fds.** `SDL_WaitEventTimeout` blocks with a timeout; cross-thread wakeups are `SDL_SendWakeupEvent` (Cocoa synthetic event, Wayland a pipe write, X11 a dummy client message). There is no built-in way to add an arbitrary external fd to the wait set portably — apps that need that drop to the native handle or run their own thread. **Frame pacing sources** by platform: Wayland frame callbacks; macOS the run loop / Metal `CAMetalLayer` present; Win32 DWM/DXGI present timing; X11 the redraw cadence of the app. The main-callback rate is tunable via `SDL_HINT_MAIN_CALLBACK_RATE` (`"waitevent"` to iterate only after an event).

---

## 3. Input

**Scancode vs keycode model.** SDL separates **physical** keys from **virtual** keys: `SDL_Scancode` is a layout-independent physical position (USB HID-derived), `SDL_Keycode` is the layout-dependent symbol ([`SDL_keycode.h`][keycode-h]). This is the [scancode/keysym/virtual-key][concepts-scancode] split made explicit in the API — `WASD` movement keys by scancode, text shortcuts by keycode. Backends translate native codes through static tables in [`src/events/SDL_scancode_tables_c.h`][scancode-tables] (`scancodes_linux.h`, `scancodes_windows.h`, `scancodes_darwin.h`, `scancodes_xfree86.h`).

**Layout / xkbcommon ownership.** On X11, SDL owns the xkb state: `X11_XkbGetMap(... XkbUseCoreKbd)` and `X11_XkbSetDetectableAutoRepeat(display, True, ...)` ([`SDL_x11keyboard.c:140`][x11-kbd]). On Wayland the compositor sends a keymap fd that SDL feeds to `xkbcommon` to build the state machine per seat.

**Key repeat — the client must synthesize it on Wayland.** Wayland sends only physical press/release plus a repeat rate/delay; the client generates the repeats. SDL does this in the pump loop after dispatching, checking each seat's repeat state and emitting synthetic key + text events:

```c
// src/video/wayland/SDL_waylandevents.c (keyboard_repeat_handle) — client-side key repeat
while (elapsed >= repeat_info->next_repeat_ns) {
    if (repeat_info->scancode != SDL_SCANCODE_UNKNOWN) {
        SDL_SendKeyboardKeyIgnoreModifiers(/*ts*/, repeat_info->keyboard_id, repeat_info->key, repeat_info->scancode, true);
    }
    if (repeat_info->text[0] && !(SDL_GetModState() & (SDL_KMOD_CTRL | SDL_KMOD_ALT))) {
        SDL_SendKeyboardText(repeat_info->text);
    }
    repeat_info->next_repeat_ns += SDL_NS_PER_SECOND / (Uint64)repeat_info->repeat_rate;
}
```

X11 takes the opposite route, asking the server for detectable autorepeat so it does **not** have to synthesize it.

**IME / text input.** SDL separates key events from text via `SDL_StartTextInput`/`SDL_EVENT_TEXT_INPUT` (committed) and `SDL_EVENT_TEXT_EDITING` (pre-edit/[composition][concepts-preedit]). Protocol per platform:

- **Wayland** uses `zwp_text_input_v3` ([`text-input-unstable-v3.xml`][wl-textinput-xml]). The pre-edit handler converts the compositor's byte cursor offsets into UTF-8 and emits an editing event; the commit handler emits final text:

  ```c
  // src/video/wayland/SDL_waylandevents.c — zwp_text_input_v3 pre-edit vs commit
  static void text_input_preedit_string(void *data, struct zwp_text_input_v3 *ti,
                                        const char *text, int32_t cursor_begin, int32_t cursor_end)
  {
      seat->text_input.has_preedit = true;
      SDL_SendEditingText(text, cursor_begin_utf8, cursor_size_utf8);   // EVENT_TEXT_EDITING
  }
  static void text_input_commit_string(void *data, struct zwp_text_input_v3 *ti, const char *text)
  {
      SDL_SendKeyboardText(text);   // EVENT_TEXT_INPUT
  }
  ```

  Candidate-window positioning is fed by `SDL_SetTextInputArea` → `zwp_text_input_v3_set_cursor_rectangle`.

- **Windows** uses **legacy IMM32**, not TSF: `ImmGetContext`, `ImmSetCompositionWindow`, and the `WM_IME_STARTCOMPOSITION`/`WM_IME_COMPOSITION` (`GCS_COMPSTR` for pre-edit, `GCS_RESULTSTR` for the committed string) messages ([`SDL_windowskeyboard.c`][win-kbd]). Candidate positioning is `ImmSetCompositionWindow(himc, &cof)`.

- **macOS** implements `NSTextInputClient` on an internal `SDL3TranslatorResponder` view ([`SDL_cocoakeyboard.m:39`][cocoa-kbd]): `setMarkedText:` produces pre-edit, `insertText:` the committed text, `firstRectForCharacterRange:` positions the candidate window.

- **X11** uses XIM (legacy), or routes through the `text` package's `SDL_IME_*` when `SDL_USE_IME`/IBus is built in.

**Pointer.** Mouse coordinates are floating-point for sub-pixel motion (an SDL2→SDL3 change, [`README-migration.md:377`][migration]). Relative/raw motion is `SDL_WINDOW_MOUSE_RELATIVE_MODE`, on Wayland via `zwp_relative_pointer_v1` + `zwp_locked_pointer_v1` ([raw-vs-accelerated pointer][concepts-rawptr]). [High-resolution scroll][concepts-rawptr]: Wayland accumulates `wl_pointer` `axis_value120` per frame (`pointer_handle_axis_common`, [`SDL_waylandevents.c:1132`][wl-axis]), preferring v120 > discrete > continuous within a frame; Win32 accumulates `WM_MOUSEWHEEL` `WHEEL_DELTA`; macOS tracks momentum phases. Capture is `SDL_CaptureMouse`; confinement/locking via `SDL_WINDOW_MOUSE_GRABBED` + the Wayland pointer-constraints protocol.

**Touch, gestures, pen.** `SDL_EVENT_FINGER_DOWN/UP/MOTION` for touch; SDL3 added a first-class pen API ([`src/events/SDL_pen.c`][pen-c], `SDL_EVENT_PEN_*`). Gesture recognition was **removed** in SDL3 (the SDL2 `SDL_GESTURE` events are gone) — apps are expected to recognize gestures from raw touch.

**Cursor.** Wayland prefers the `cursor-shape-v1` protocol (`wp_cursor_shape_device_v1_set_shape`, [`SDL_waylandmouse.c:1135`][wl-cursor]) and falls back to a client-rendered `wl_surface` cursor when the compositor lacks it; `wl_pointer_set_cursor(NULL)` hides it.

---

## 4. Wayland specifics

**Decorations: SSD-preferred, libdecor or own-surface CSD fallback.** SDL prefers [server-side decorations][concepts-csd] when `zxdg_decoration_manager_v1` is advertised; it binds it at registry time ([`SDL_waylandvideo.c:1389`][wl-video]) and on a plain `xdg_toplevel` requests the mode directly:

```c
// src/video/wayland/SDL_waylandwindow.c — ask the compositor for server-side decorations when possible
if (c->decoration_manager) {
    data->server_decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(c->decoration_manager, ...);
    const enum zxdg_toplevel_decoration_v1_mode mode =
        !(window->flags & SDL_WINDOW_BORDERLESS) ? ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE
                                                  : ZXDG_TOPLEVEL_DECORATION_V1_MODE_CLIENT_SIDE;
    zxdg_toplevel_decoration_v1_set_mode(data->server_decoration, mode);
}
```

When the compositor offers no `xdg-decoration` (notably GNOME/Mutter, which has refused SSD), SDL routes the toplevel through **libdecor** (`#include <libdecor.h>`, `libdecor_decorate` + `libdecor_frame_map`, `WAYLAND_SHELL_SURFACE_TYPE_LIBDECOR`) so a CSD frame is drawn for it. SDL does **not** hand-draw its own titlebar — it punts to libdecor. (See the in-code KDE bug reference around [`SDL_waylandwindow.c:2125`][wl-show] for the kind of compositor-specific workaround that litters this file.)

**Protocol coverage.** The bundled protocol set in [`wayland-protocols/`][wl-protocols] and its usage covers far more than core + `xdg-shell`: `fractional-scale-v1`, `viewporter`, `xdg-activation-v1` (focus stealing), `idle-inhibit-unstable-v1`, `cursor-shape-v1`, `relative-pointer`/`pointer-constraints`/`pointer-gestures`, `tablet-v2`, `primary-selection`, `text-input-unstable-v3`, `xdg-foreign-v2` (window export), `xdg-toplevel-icon-v1`, `xdg-dialog-v1` (modal hint), `single-pixel-buffer-v1`, `alpha-modifier-v1`, and `color-management-v1`. There is **no layer-shell** support — SDL is a client-app toolkit, not a desktop-shell toolkit.

> [!NOTE]
> Protocol absence is handled by feature-test: SDL binds each global only if the compositor advertises it (`wl_registry` listener in `SDL_waylandvideo.c`) and degrades — e.g. no `fractional-scale-v1` means integer `wl_surface_set_buffer_scale`; no `cursor-shape-v1` means a client-rendered cursor surface; no `xdg-decoration` means libdecor.

---

## 5. DPI & scaling

SDL3's scale model is documented in full in [`README-highdpi.md`][highdpi]. The native unit is the **platform's** unit — SDL does not impose one logical space:

> SDL 3.0 has new support for high DPI displays. Interfaces provided by SDL [use] the platform's native coordinates unless otherwise specified.
>
> — [`docs/README-highdpi.md`][highdpi]

Three distinct quantities: **display content scale** (`SDL_GetDisplayContentScale`, the "draw things bigger" hint), **window pixel density** (`SDL_GetWindowPixelDensity`, the size-vs-pixels ratio), and **window display scale** (`SDL_GetWindowDisplayScale`, their product). Crucially the model differs by platform, and SDL exposes rather than hides it ([logical vs physical coords][concepts-coords], [scale factor][concepts-scale]):

> The Windows and Android coordinate system always deals in physical device pixels... The macOS and iOS coordinate system always deals in window coordinates... On Linux, X11 uses a similar approach to Windows and Wayland uses a similar approach to macOS.

So on a 3840×2160 / 200% monitor a default window reports `SDL_GetWindowSize` = 1920×1080 on macOS but 3840×2160 on Windows. The "created-at-wrong-scale-then-rescaled" problem is handled with events: you are **guaranteed** a `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` on creation and on every resize, and `SDL_EVENT_WINDOW_DISPLAY_SCALE_CHANGED` when the scale changes — the app sizes its graphics context off those events rather than off the create-time numbers.

- **Windows per-monitor DPI.** SDL loads `SetProcessDpiAwarenessContext` and prefers `DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2`, falling back to the v1 `SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE)` on older Windows ([`SDL_windowsvideo.c:263`][win-video]). The [`WM_DPICHANGED`][concepts-coords] handler ([`SDL_windowsevents.c:2423`][win-dpi]) resizes via the OS-suggested rect, while ignoring the change when SDL itself triggered the move (`data->expected_resize`).
- **Wayland fractional scaling** is `fractional-scale-v1` + `viewporter`: SDL renders at a buffer scale and uses `wp_viewport` to map to the fractional logical size.
- **macOS backing scale** comes from the `NSScreen` `backingScaleFactor`; `SDL_WINDOW_HIGH_PIXEL_DENSITY` requests the 2× backing store.

Mixed-DPI multi-monitor migration fires the scale-changed events as the window crosses monitors; on Win32 that is the `WM_DPICHANGED` dance above.

---

## 6. Multi-window & popups

SDL3 has a real parent/child window model: `SDL_CreatePopupWindow(parent, x, y, w, h, flags)` plus the `SDL_WINDOW_TOOLTIP`, `SDL_WINDOW_POPUP_MENU`, `SDL_WINDOW_UTILITY`, and `SDL_WINDOW_MODAL` flags.

- **Wayland** maps popups to `xdg_popup` with an `xdg_positioner` ([`SDL_waylandwindow.c:2189`][wl-popup]): anchor rect, gravity, and constraint-adjustment (slide) are set, and tooltips get an empty input region so they cannot be interacted with. Popup-menu windows take keyboard focus; this is the [xdg_popup grab][concepts-popupgrab] discipline (a popup is parented to its toplevel and the compositor manages the grab/dismiss).
- **X11** uses [override-redirect][concepts-popupgrab] for tooltips and popup menus: `xattr.override_redirect = (TOOLTIP || POPUP_MENU || force) ? True : False` ([`SDL_x11window.c:653`][x11-create]), bypassing the WM for placement.
- **Win32** creates utility windows with a hidden owner window and uses owner/parent `HWND` relationships ([`SDL_windowswindow.c:709`][win-create]).
- **Modal dialogs** use `SDL_SetWindowModal`; on Cocoa it runs an `NSModalSession` inside the pump loop ([`SDL_cocoaevents.m:591`][cocoa-pump]), on Wayland the `xdg-dialog-v1` modal hint.

Stacking and groups follow the parent chain; a child is shown only after its parent is fully shown (Wayland's `SHOW_PENDING` state, [`SDL_waylandwindow.c:2102`][wl-show]).

---

## 7. Threading

The hard constraint is that **video init and window/event calls must happen on the main thread**. `SDL_INIT_VIDEO` is documented "should be initialized on the main thread" ([`SDL_init.h:81`][init-h]), and the per-platform reason is AppKit/UIKit: on Apple platforms the main thread is the thread that runs `main()`, and `NSApplication`/`NSWindow` are main-thread-only. SDL exposes `SDL_IsMainThread` and, for off-thread work that must touch the UI, a marshaling primitive:

```c
// include/SDL3/SDL_init.h — marshal a callback onto the main thread during event processing
typedef void (SDLCALL *SDL_MainThreadCallback)(void *userdata);
extern SDL_DECLSPEC bool SDLCALL SDL_RunOnMainThread(SDL_MainThreadCallback callback, void *userdata, bool wait_complete);
```

Events are delivered on the thread that pumps (normally main). Rendering: the SDL 2D renderer and `SDL_GPU` are likewise expected to be used from the thread that created the window on most backends; the constraint is strictest on macOS where AppKit forbids off-main UI mutation. `SDL_PushEvent`/`SDL_SetAtomicInt` make the event queue and the main-callbacks quit-result thread-safe, but window mutation off-main is unsupported.

> [!WARNING]
> The macOS main-thread requirement is the usual culprit shaping the whole model: because `NSApp` must run on thread 0, SDL routes its loop and all window calls there, and offers `SDL_RunOnMainThread` rather than locking, so cross-platform code that creates windows from a worker thread will work on Win32/X11 but break on Cocoa.

---

## 8. Clipboard & DnD

SDL3 unified the clipboard around **MIME types and a lazy provider callback** ([`SDL_clipboard.h`][clipboard-h]): `SDL_SetClipboardData(callback, cleanup, userdata, mime_types, n)` registers the offered MIME types but defers the bytes until a consumer asks, and `SDL_GetClipboardData(mime_type, &size)` retrieves them. Primary selection (`SDL_SetPrimarySelectionText`) is exposed separately.

- **Wayland** maps directly: `wl_data_device`/`wl_data_source`/`wl_data_offer` for the regular selection and `zwp_primary_selection_v1` for primary ([`SDL_waylanddatamanager.c`][wl-data]). The lazy callback matches Wayland's "source sends bytes on demand over a pipe" model perfectly.
- **X11** implements the selection protocol with **[INCR][x11-incr]** (incremental transfer) for large data — the getter loops, deleting the property between chunks until the transfer completes ([`SDL_x11clipboard.c:215`][x11-clip]).
- **Win32** investigated delayed rendering and chose **eager** materialization, with a candid comment:

  > I investigated delayed clipboard rendering, and at least with text and image formats you have to use an output window, not `SDL_HelperWindow`, and the system requests them being rendered immediately, so there isn't any benefit.
  >
  > — [`src/video/windows/SDL_windowsclipboard.c`][win-clip] (`WIN_SetClipboardData`)

**Drag-and-drop** is delivery-only as files/text: `SDL_EVENT_DROP_BEGIN`, `SDL_EVENT_DROP_FILE`, `SDL_EVENT_DROP_TEXT`, `SDL_EVENT_DROP_POSITION`, `SDL_EVENT_DROP_COMPLETE` ([`src/events/SDL_dropevents.c`][drop-c]). SDL is a drop **target**; initiating a drag from an SDL window is not part of the portable API.

---

## 9. Escape hatches

SDL treats the leaky abstraction as inevitable and ships documented hatches:

- **Native handles** via `SDL_GetWindowProperties` (the `HWND`, `NSWindow`, `Display`+`Window`, `wl_display`+`wl_surface` pointers listed in [§1](#1-window-creation--lifecycle)). This is the primary hatch for integrating Vulkan/Direct3D/Metal directly or embedding into another toolkit.
- **Message-pump hooks.** `SDL_SetWindowsMessageHook(callback, userdata)` ([`SDL_system.h:96`][system-h]) hands every Win32 `MSG` to the app before SDL dispatches it (returning `false` swallows it); `SDL_SetX11EventHook` does the same for raw `XEvent`s. These replace SDL2's `SDL_GetWindowWMInfo`:

  > The Windows and X11 events are now available via callbacks which you can set with `SDL_SetWindowsMessageHook()` and `SDL_SetX11EventHook()`.
  >
  > — [`docs/README-migration.md`][migration]

- **External windows.** `SDL_CreateWindowWithProperties` accepts `SDL_PROP_WINDOW_CREATE_WIN32_HWND_POINTER` / `..._WAYLAND_WL_SURFACE_POINTER` / `..._X11_WINDOW_NUMBER` / `..._COCOA_WINDOW_POINTER` to wrap an already-created native window (`SDL_WINDOW_EXTERNAL`), the replacement for SDL2's removed `SDL_CreateWindowFrom`.

That this many hatches exist, and that the Win32/X11 hooks are first-class API, is itself the signal of where the abstraction is known to leak: raw message handling and native-handle interop.

---

## 10. History, redesigns & known regrets

The richest source is [`docs/README-migration.md`][migration], a long catalog of every SDL2→SDL3 break. The windowing-layer changes worth noting:

- **Main-callbacks model (new in SDL3).** `SDL_AppInit`/`SDL_AppIterate`/`SDL_AppEvent`/`SDL_AppQuit` under `SDL_MAIN_USE_CALLBACKS` ([`SDL_main.h`][main-h], used since SDL 3.2.0). It exists because iOS/Emscripten/Wayland want to drive the frame loop; the FIXME in the generic loop ([`SDL_sysmain_callbacks.c`][gen-callbacks]) records the still-unfinished ambition to "hand off callback responsibility to the video subsystem... if Wayland has a protocol to drive an animation loop."

- **Properties replace typed getters (new in SDL3).** `SDL_GetWindowWMInfo` and `SDL_SysWMinfo` were deleted; `SDL_GetWindowProperties` + `SDL_GetWindowData`/`SDL_SetWindowData` removed in favor of `SDL_GetPointerProperty` on the window's property bag ([`README-migration.md:2224`][migration]). `SDL_CreateWindowFrom` was replaced by `SDL_CreateWindowWithProperties` ([line 2226][migration]).

- **High-DPI overhaul (new in SDL3).** Native coordinates by default; the distinct pixel-size / display-scale / pixel-density model; `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED`; mouse coordinates became floating-point. SDL2's renderer auto-scaling of mouse coordinates was removed (`SDL_HINT_MOUSE_RELATIVE_SCALING`, [line 834][migration]); apps now call `SDL_ConvertEventToRenderCoordinates` explicitly ([line 1392][migration]).

- **Unified flags & 64-bit window flags.** Window flags grew to 64 bits to fit `SDL_WINDOW_NOT_FOCUSABLE`, `SDL_WINDOW_TRANSPARENT`, `SDL_WINDOW_HIGH_PIXEL_DENSITY`, etc.

- **Gesture recognition removed.** The SDL2 multi-gesture/dollar-gesture API is gone with no replacement; apps recognize gestures from raw `SDL_EVENT_FINGER_*` themselves.

- **Wayland's no-buffer-no-window has been a long tail of bugs.** The `Wayland_ShowWindow` code carries explicit references to upstream compositor bugs (the [KDE bug 448856][kde-bug] comment around [`SDL_waylandwindow.c:2125`][wl-show]) and a confession that the same buffer-detach call had to be duplicated in both Hide and Show paths to satisfy Unreal Engine's popups — a candid maintainer note that the Wayland lifecycle is fiddly.

> [!NOTE]
> SDL3.0 (`3.2.0`) was the first stable SDL3, released January 2025; this study is against the `3.5.0` development tree at [`b53f1b06`][commit]. The migration document and the issue tracker ([libsdl-org/SDL/issues][issues]) are the primary record of why each windowing change was made.

---

## Strengths

- **True cross-platform parity** for the windowing core: one API spans Wayland, X11, Win32, Cocoa, UIKit, Android, KMSDRM, and Emscripten, with backends selected at runtime.
- **The hybrid loop model is pragmatic.** Apps keep a simple `SDL_PollEvent` loop, but the main-callbacks option means the _same_ code runs on iOS and the web where the OS must own the loop.
- **Honest about coordinates.** Exposing pixel density / content scale / display scale separately, with guaranteed events, lets apps render crisply on mixed-DPI setups without guesswork.
- **Modern Wayland citizen.** Fractional scale, cursor-shape, text-input v3, pointer-constraints, xdg-activation, and libdecor fallback are all present; protocol absence degrades gracefully.
- **Documented escape hatches** (properties, message-pump hooks, external windows) make SDL embeddable and extensible without forking.
- **Live-resize keeps drawing** on Win32 via the `WM_TIMER` trick inside the modal loop — a notoriously hard case handled.

## Weaknesses

- **Win32 IME is legacy IMM32, not TSF**, so it lags modern Windows text-input features and per-input-method behavior.
- **No layer-shell, no drag source.** SDL can't be a desktop-shell component on Wayland, and can't _initiate_ drag-and-drop portably.
- **Gesture API removed with no replacement** — a regression for touch apps that relied on SDL2.
- **Main-thread bound.** Window/event calls must be on the main thread (AppKit), so worker-thread window creation that works on Win32/X11 silently breaks on macOS.
- **No portable external-fd integration** into the wait set; async-runtime cohabitation needs the native handle or a side thread (cf. [async-io][async-io]).
- **Wayland lifecycle is fragile** — the no-buffer-no-window/configure round-trip and popup ordering have produced a long bug tail visible in the source comments.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                          | Trade-off                                                                           |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Hybrid loop: app-owned `SDL_PollEvent` + optional main-callbacks | Simple by default; lets the OS own the loop on iOS/Emscripten/Wayland without `#ifdef`s in the app | Two code paths to learn; callbacks dispatch events via an event-watcher indirection |
| Per-backend vtable behind one C API                              | Add/replace a platform by filling a function table; runtime backend selection                      | Lowest-common-denominator API; per-platform features hide behind hints/properties   |
| Native coordinates, expose the scale                             | Matches each OS's real model; no lossy synthetic logical space                                     | App must handle three scale quantities and react to size-changed events itself      |
| Properties bag for native handles                                | ABI-stable extensibility; one mechanism for `HWND`/`NSWindow`/`wl_surface`/…                       | Stringly-typed, runtime-checked access instead of typed getters                     |
| SSD-first, libdecor CSD fallback                                 | Respect compositor decoration preference; still work on GNOME (no `xdg-decoration`)                | Depends on an external libdecor; SDL draws no titlebar of its own                   |
| Client-side Wayland key repeat, server-side X11 autorepeat       | Each follows its platform's protocol contract                                                      | Wayland repeat logic lives in SDL's pump and must track per-seat timing             |
| Win32 IMM32 over TSF                                             | Simpler, ubiquitous, fewer COM dependencies                                                        | Misses modern TSF capabilities and richer composition control                       |
| Main-thread-only windowing                                       | AppKit/UIKit mandate it; uniform rule across platforms                                             | `SDL_RunOnMainThread` marshaling needed; no off-thread window creation              |

## Verdict: what a new framework should steal / avoid

**Steal:** the hybrid loop — a dead-simple default pump _plus_ an opt-in inverted callback model so the same app runs where the OS owns the loop; the honest DPI model (separate pixel-density / content-scale / display-scale with guaranteed change events); the properties-bag escape hatch for native handles (ABI-stable, uniform); SSD-first-with-libdecor-fallback on Wayland; and first-class message-pump hooks so the abstraction can be bypassed without forking. **Avoid:** legacy IMM32 instead of TSF on Windows; dropping a whole capability (gestures) with no replacement; and a Wayland show-path that blocks on a synchronous round-trip for `configure` — model the no-buffer-no-window lifecycle as explicit state from the start rather than a blocking wait retrofitted with compositor-bug workarounds.

## Open questions I could not resolve (with where the answer likely lives)

- **Will the main-callback loop ever be handed to the Wayland frame-callback driver?** The FIXME in [`SDL_sysmain_callbacks.c`][gen-callbacks] flags this as intended-but-undone; the answer will appear in the [issue tracker][issues] / future commits to `src/main/`.
- **What exactly is the threading contract for `SDL_GPU` vs the 2D renderer off the event thread?** Documented thread-safety annotations are per-function in the headers; the authoritative answer is in `include/SDL3/SDL_gpu.h` and `src/render/`, not the video subsystem studied here. Marked [inference] that it follows the main-thread window rule.
- **Does SDL ever use TSF on Windows?** Only IMM32 paths were found in [`SDL_windowskeyboard.c`][win-kbd]; whether a TSF backend is planned would be in the [issue tracker][issues].

---

## Sources

- [libsdl-org/SDL][repo] — repository (all quoted file paths), at commit [`b53f1b06`][commit]
- [`include/SDL3/SDL_video.h`][sdl-video-h] — video subsystem API and header positioning quote
- [`include/SDL3/SDL_main.h`][main-h] — main-callbacks macro and entry points
- [`docs/README-main-functions.md`][mainfns] — rationale for the callback loop
- [`docs/README-migration.md`][migration] — SDL2→SDL3 windowing-layer changes
- [`docs/README-highdpi.md`][highdpi] — the high-DPI coordinate model
- [`src/main/SDL_main_callbacks.c`][callbacks-c] / [`src/main/generic/SDL_sysmain_callbacks.c`][gen-callbacks] — callback loop implementation
- [`src/video/SDL_sysvideo.h`][sysvideo-h] / [`SDL_video.c`][video-c] — the backend vtable and dispatch
- Backends: [`SDL_waylandwindow.c`][wl-window], [`SDL_waylandevents.c`][wl-pump], [`SDL_x11window.c`][x11-create], [`SDL_x11events.c`][x11-pump], [`SDL_windowswindow.c`][win-create], [`SDL_windowsevents.c`][win-pump], [`SDL_cocoawindow.m`][cocoa-create], [`SDL_cocoaevents.m`][cocoa-pump]
- Wayland protocols: [`wayland-protocols/`][wl-protocols], [`text-input-unstable-v3.xml`][wl-textinput-xml]
- [libsdl-org/SDL issues][issues] — design rationale and regressions
- Sibling docs: [concepts][concepts], [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[repo]: https://github.com/libsdl-org/SDL
[commit]: https://github.com/libsdl-org/SDL/commit/b53f1b06447cfe699e2649afc52a1a54e5f19f71
[license]: https://github.com/libsdl-org/SDL/blob/main/LICENSE.txt
[wiki]: https://wiki.libsdl.org/SDL3/
[issues]: https://github.com/libsdl-org/SDL/issues
[kde-bug]: https://bugs.kde.org/show_bug.cgi?id=448856
[sdl-video-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_video.h
[win-flags]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_video.h#L197
[main-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_main.h
[keycode-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_keycode.h
[events-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_events.h
[props-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_properties.h
[clipboard-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_clipboard.h
[init-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_init.h#L81
[system-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/include/SDL3/SDL_system.h#L96
[migration]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/docs/README-migration.md
[mainfns]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/docs/README-main-functions.md
[highdpi]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/docs/README-highdpi.md
[callbacks-c]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/main/SDL_main_callbacks.c
[gen-callbacks]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/main/generic/SDL_sysmain_callbacks.c
[sysvideo-h]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/SDL_sysvideo.h
[video-c]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/SDL_video.c
[wl-window]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandwindow.c
[wl-opaque]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandwindow.c#L294
[wl-show]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandwindow.c#L2125
[wl-framedone]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandwindow.c#L810
[wl-popup]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandwindow.c#L2189
[wl-pump]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandevents.c#L598
[wl-axis]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandevents.c#L1132
[wl-cursor]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandmouse.c#L1135
[wl-video]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylandvideo.c#L1389
[wl-data]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/wayland/SDL_waylanddatamanager.c
[wl-protocols]: https://github.com/libsdl-org/SDL/tree/b53f1b06447cfe699e2649afc52a1a54e5f19f71/wayland-protocols
[wl-textinput-xml]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/wayland-protocols/text-input-unstable-v3.xml
[x11-create]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/x11/SDL_x11window.c#L556
[x11-pump]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/x11/SDL_x11events.c#L2322
[x11-kbd]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/x11/SDL_x11keyboard.c#L140
[x11-clip]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/x11/SDL_x11clipboard.c#L215
[x11-incr]: https://tronche.com/gui/x/icccm/sec-2.html
[win-create]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowswindow.c#L692
[win-pump]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowsevents.c#L2590
[win-dpi]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowsevents.c#L2423
[win-video]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowsvideo.c#L263
[win-kbd]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowskeyboard.c
[win-clip]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/windows/SDL_windowsclipboard.c#L266
[cocoa-create]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/cocoa/SDL_cocoawindow.m#L2421
[cocoa-pump]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/cocoa/SDL_cocoaevents.m#L633
[cocoa-kbd]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/video/cocoa/SDL_cocoakeyboard.m#L39
[scancode-tables]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/events/SDL_scancode_tables_c.h
[pen-c]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/events/SDL_pen.c
[drop-c]: https://github.com/libsdl-org/SDL/blob/b53f1b06447cfe699e2649afc52a1a54e5f19f71/src/events/SDL_dropevents.c
[clay]: https://github.com/nicbarker/clay
[concepts]: ./concepts.md
[concepts-nbnw]: ./concepts.md#no-buffer-no-window
[concepts-rvc]: ./concepts.md#readiness-vs-completion-windowing
[concepts-win32modal]: ./concepts.md#win32-modal-resize-loop
[concepts-framevsync]: ./concepts.md#frame-callback-vsync
[concepts-scancode]: ./concepts.md#scancode-keysym-virtualkey
[concepts-preedit]: ./concepts.md#pre-edit-composition
[concepts-rawptr]: ./concepts.md#raw-vs-accelerated-pointer
[concepts-csd]: ./concepts.md#client-vs-server-decoration
[concepts-coords]: ./concepts.md#logical-vs-physical-coords
[concepts-scale]: ./concepts.md#scale-factor
[concepts-popupgrab]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
