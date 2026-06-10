# Smithay Client Toolkit + libdecor (Rust + C)

A pair of **Wayland-only** building blocks: [`smithay-client-toolkit`][sctk-repo] (SCTK) wraps the raw `wayland-client` protocol bindings into handler-trait abstractions for `xdg-shell` windows, seats, outputs and SHM buffers; [`libdecor`][libdecor-archive] is the de-facto C library that draws [client-side decorations][csd] (titlebar, borders, shadows) when the compositor refuses to draw [server-side][csd] ones. Neither is a cross-platform windowing framework — together they are the canonical reference for how a Wayland client handles the windowing layer.

| Field                  | Value                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit studied | SCTK `0.20.0` @ [`70a21c0`][sctk-repo]; libdecor `0.2.2` @ [`59c498a`][libdecor-archive]                                        |
| Language               | Rust (edition 2021) for SCTK; C (C99) for libdecor                                                                              |
| License                | MIT (both)                                                                                                                      |
| Repository             | [Smithay/client-toolkit][sctk-repo] / [libdecor/libdecor][libdecor-archive] (gitlab.freedesktop)                                |
| Documentation          | [SCTK docs.rs][sctk-docs] / libdecor headers ([`libdecor.h`][libdecor-h])                                                       |
| Category               | Wayland client toolkit + CSD helper (not a windowing framework)                                                                 |
| Platforms covered      | **Wayland only** — no X11, no Win32, no AppKit, no Android/iOS                                                                  |
| Loop ownership         | **Caller-owned, poll/fd-based.** SCTK plugs into [`calloop`][calloop]; libdecor exposes a raw `fd`.                             |
| Repo paths (platform)  | SCTK `src/shell/xdg/`, `src/seat/`, `src/compositor.rs`, `src/output.rs`; libdecor `src/libdecor.c`, `src/plugins/{cairo,gtk}/` |

> [!IMPORTANT]
> This deep-dive is the catalog's authority for **dimension 4 (Wayland specifics)**.
> Because the subject is Wayland-only, the Win32, AppKit, X11 and per-monitor-DPI-on-Windows
> dimensions **do not apply**; each is marked accordingly and the absence explained rather
> than skipped. For the cross-platform abstractions that have to unify all of this, see the
> framework deep-dives in this tree (e.g. winit, GLFW, SDL).

---

## Overview

### What it solves

A Wayland client is not handed a "window". It binds globals over a Unix-domain socket, creates a `wl_surface`, gives that surface a **role** (here `xdg_toplevel` via `xdg_surface`), attaches a buffer, and commits — and only then does anything appear. There is no window manager drawing a titlebar, no synchronous "create window" call, and (on many compositors) no server-side decorations at all. SCTK's own README states the gap plainly:

> The crate is structured around handlers that are implemented by the application's
> state and `delegate` macros that route Wayland events to those handlers.
> — SCTK is the toolkit that "[handles] the interaction with the shell (`xdg_shell` ...) and the drawing of decorations" ([`README.md`][sctk-readme])

SCTK supplies: `XdgShell::create_window` (the toplevel lifecycle), `SeatState`/`KeyboardData`/`PointerData` (input with [xkbcommon][xkbcommon] keymap handling and **client-side key repeat**), `CompositorState`/`SurfaceData` (surface + scale tracking), `OutputState` (monitor enumeration), `Shm`/`SlotPool` (software buffers), and data-device + primary-selection (clipboard/DnD). It does **not** own an event loop — it integrates with [`calloop`][calloop] via [`calloop-wayland-source`][calloop-wl-source].

libdecor solves the orthogonal problem: when the compositor will not draw [server-side decorations][csd] (GNOME/Mutter notably offers no `zxdg_decoration_manager_v1`), _someone_ must draw a titlebar, resize borders, and shadows, and translate clicks on them into `xdg_toplevel` move/resize requests. libdecor is that someone, packaged so every GTK-less client (SDL, GLFW, winit, Firefox) need not reinvent it. Its README:

> libdecor is a library that can help Wayland clients draw window decorations for
> them. It aims to provide multiple backends that implements the decoration drawing.
> — [`README.md`][libdecor-archive]

### Design philosophy

- **Handlers + delegation, not inheritance (SCTK).** The application defines one state struct and implements `WindowHandler`, `KeyboardHandler`, `PointerHandler`, `CompositorHandler`, `OutputHandler`, … . The `delegate_*` macros (now unified into `delegate_dispatch2!`, see [`CHANGELOG.md`][sctk-changelog]) wire `wayland-client`'s `Dispatch` trait to those handlers. SCTK never spawns a thread or hides the socket.
- **The toolkit is a thin, honest mirror of the protocol.** `WindowConfigure` is a near-1:1 translation of the `xdg_toplevel.configure` event; `request_decoration_mode` is a thin wrapper over `zxdg_toplevel_decoration_v1.set_mode`. SCTK does not pretend the protocol's double-buffered, configure-ack handshake is a synchronous setter.
- **libdecor is a dynamically-loaded plugin host.** The core (`libdecor.c`) is decoration-agnostic; the actual drawing lives in `dlopen`-ed plugins (`cairo`, `gtk`) chosen at runtime by per-desktop priority. This lets a GNOME desktop get a native-looking GTK titlebar without the core linking GTK.
- **libdecor spun out of GTK's CSD code.** It exists because GTK's client-side decorations (introduced ~2014) were the reference implementation everyone copied badly; libdecor extracted a reusable, compositor-portable version. See [History](#10-history-redesigns-known-regrets).

---

## How it works

### SCTK: the window object and the configure handshake

`XdgShell::bind` binds `xdg_wm_base` (up to v6) and, _if present_, `zxdg_decoration_manager_v1` ([`src/shell/xdg/mod.rs`][sctk-xdg-mod]). `XdgShell::create_window` builds the role objects inside an `Arc::new_cyclic` so the `WindowData`'s `Weak` is valid before any event can fire, freezing the event queue to avoid the race:

```rust
// src/shell/xdg/mod.rs — XdgShell::create_window (abridged)
let freeze = qh.freeze();                       // pause event dispatch during construction
let inner = Arc::new_cyclic(|weak| {
    let xdg_surface = self.xdg_wm_base.get_xdg_surface(surface.wl_surface(), qh, WindowData(weak.clone()));
    let xdg_surface = XdgShellSurface { surface, xdg_surface };
    let xdg_toplevel = xdg_surface.xdg_surface().get_toplevel(qh, WindowData(weak.clone()));
    // Create zxdg_toplevel_decoration_v1 only if the manager exists and the app wants SSD:
    let toplevel_decoration = decoration_manager.and_then(|mgr| match decorations {
        WindowDecorations::ClientOnly | WindowDecorations::None => None,
        _ => { /* mgr.get_toplevel_decoration(...); maybe set_mode(...) */ Some(/*…*/) }
    });
    WindowInner { xdg_surface, xdg_toplevel, toplevel_decoration, pending_configure: Mutex::new(/*…*/) }
});
drop(freeze);
Window(inner)
```

The window is **unmapped** at this point — exactly the [no-buffer-no-window][no-buffer-no-window] rule. The compositor replies with `xdg_toplevel.configure` then `xdg_surface.configure`; SCTK accumulates the toplevel half into `pending_configure`, then on the `xdg_surface.configure` it **acks the serial and fires the handler** ([`src/shell/xdg/window/inner.rs`][sctk-window-inner]):

```rust
// src/shell/xdg/window/inner.rs — Dispatch2<xdg_surface::XdgSurface> for WindowData
xdg_surface::Event::Configure { serial } => {
    xdg_surface.ack_configure(serial);                                  // protocol requirement
    let configure = { window.0.pending_configure.lock().unwrap().clone() };
    WindowHandler::configure(data, conn, qh, &window, configure, serial); // app draws first frame here
}
```

The application draws its first buffer _inside_ `configure` — the canonical Wayland startup dance.

### libdecor: the context, the frame, and the fd

libdecor's public surface is `libdecor_new(display, iface)` → `libdecor_decorate(context, wl_surface, frame_iface, user_data)` → a `libdecor_frame`. The app responds to `configure`/`close`/`commit`/`dismiss_popup`/`bounds` callbacks in `libdecor_frame_interface` ([`libdecor.h`][libdecor-h]):

```c
// src/libdecor.h — the per-frame callback interface (abridged)
struct libdecor_frame_interface {
    void (* configure)(struct libdecor_frame *frame,
                       struct libdecor_configuration *configuration, void *user_data);
    void (* close)(struct libdecor_frame *frame, void *user_data);
    void (* commit)(struct libdecor_frame *frame, void *user_data);
    void (* dismiss_popup)(struct libdecor_frame *frame, const char *seat_name, void *user_data);
    void (* bounds)(struct libdecor_frame *frame, int width, int height, void *user_data);
    /* reserved0 .. reserved8 */
};
```

libdecor wholly owns the `xdg_surface`/`xdg_toplevel` (`init_shell_surface` in [`libdecor.c`][libdecor-c] calls `xdg_wm_base_get_xdg_surface` / `xdg_surface_get_toplevel`), so the client gives libdecor a bare `wl_surface` and gets the role back via `libdecor_frame_get_xdg_toplevel`. The decoration plugin runs its own internal Wayland event handling, so libdecor exposes its readiness as an fd:

```c
// src/libdecor.h — integrate libdecor with the application's poll loop
int  libdecor_get_fd(struct libdecor *context);          // poll this fd
int  libdecor_dispatch(struct libdecor *context, int timeout); // then dispatch
```

Both delegate to the active plugin (`plugin->priv->iface->get_fd` / `dispatch`, [`libdecor.c`][libdecor-c]), which in turn drives `wl_display`.

---

## 1. Window creation & lifecycle

**Platform call (Wayland only).** A toplevel is `wl_compositor.create_surface` → `xdg_wm_base.get_xdg_surface` → `xdg_surface.get_toplevel`. SCTK wraps this as `XdgShell::create_window` returning a `Window` (an `Arc<WindowInner>`); libdecor wraps it as `libdecor_decorate` returning a `libdecor_frame`. There is no other platform — see the scope note above.

**Window-attributes model.** SCTK's `Window` exposes `set_title`, `set_app_id`, `set_parent`, `set_min_size`/`set_max_size`, `set_maximized`/`unset_maximized`, `set_minimized`, `set_fullscreen(Option<&wl_output>)`/`unset_fullscreen`, and `request_decoration_mode` ([`src/shell/xdg/window/mod.rs`][sctk-window-mod]). Note what is **structurally absent**, because Wayland deliberately omits it:

| Attribute       | SCTK status                     | Why                                                                                                |
| --------------- | ------------------------------- | -------------------------------------------------------------------------------------------------- |
| Position (x, y) | **Unsupported**                 | A core Wayland design choice — clients cannot place toplevels; only the compositor positions them. |
| Always-on-top   | **Unsupported**                 | No core/`xdg-shell` request; needs `wlr-layer-shell` (a different role) or compositor policy.      |
| Transparency    | Implicit                        | Alpha is per-pixel in the buffer; no window flag.                                                  |
| Title / app-id  | `set_title` / `set_app_id`      | `app_id` is the only stable window identity Wayland exposes.                                       |
| Min/max size    | `set_min_size` / `set_max_size` | Double-buffered hints; compositor may ignore.                                                      |
| Fullscreen      | `set_fullscreen(output)`        | Per-output; compositor confirms via `WindowState::FULLSCREEN`.                                     |
| Decorations     | `WindowDecorations` enum        | `ServerDefault` / `RequestServer` / `RequestClient` / `ClientOnly` / `None`.                       |

> [!NOTE]
> Toplevel **size and state are not set by the client** — they are _negotiated_. The client
> may _request_ (`set_maximized`), but the truth arrives in `WindowConfigure.state`
> (`WindowState` flags: `MAXIMIZED`, `FULLSCREEN`, `RESIZING`, `ACTIVATED`, `TILED_*`,
> `SUSPENDED`). The client must redraw to whatever size the configure suggests
> ([`src/shell/xdg/window/inner.rs`][sctk-window-inner], the `xdg_toplevel::Event::Configure` arm).

**Initial-frame handling.** [No buffer ⇒ no window][no-buffer-no-window]: SCTK's own example comments "We don't draw immediately, the configure will notify us when to first draw" ([`examples/simple_window.rs`][sctk-simple]); the first commit-with-buffer happens inside `WindowHandler::configure`. This is the opposite of X11/Win32, where `XMapWindow`/`CreateWindowEx` map immediately.

**Surface/handle exposure for GPU/software rendering.** Crucially, **SCTK does not implement [`raw-window-handle`][rwh] itself.** The `wgpu` example constructs the handle by hand from the connection backend pointer and the surface object id ([`examples/wgpu.rs`][sctk-wgpu]):

```rust
// examples/wgpu.rs — building a raw-window-handle manually (SCTK gives you the pointers, not the trait)
let raw_display_handle = RawDisplayHandle::Wayland(WaylandDisplayHandle::new(
    NonNull::new(conn.backend().display_ptr() as *mut _).unwrap()));
let raw_window_handle = RawWindowHandle::Wayland(WaylandWindowHandle::new(
    NonNull::new(window.wl_surface().id().as_ptr() as *mut _).unwrap()));
```

This is a deliberate non-feature: SCTK exposes `wl_surface()` and the `Connection` and lets the caller bridge to GPU APIs. (libdecor likewise hands back the `wl_surface`/`xdg_surface` and stays out of rendering.)

**Destruction-ordering hazards.** Wayland requires protocol objects be destroyed children-first. SCTK encodes this in `Drop for WindowInner` ([`src/shell/xdg/window/inner.rs`][sctk-window-inner]):

```rust
// src/shell/xdg/window/inner.rs — Drop order is load-bearing
impl Drop for WindowInner {
    fn drop(&mut self) {
        // XDG decoration says we must destroy the decoration object before the toplevel
        if let Some(d) = self.toplevel_decoration.as_ref() { d.destroy(); }
        // XDG Shell protocol dictates we must destroy the role object before the xdg surface.
        self.xdg_toplevel.destroy();
        // XdgShellSurface's own Drop destroys xdg_surface before wl_surface
    }
}
```

Getting this order wrong is a compositor-side protocol error that kills the connection — a real Wayland landmine that the `Arc`/`Drop` chaining hides.

## 2. Event loop

**Who owns the loop: the caller does.** SCTK is loop-agnostic but ships first-class integration with **[`calloop`][calloop]** (the Smithay project's epoll-based event-loop crate) through **[`calloop-wayland-source`][calloop-wl-source]**. The pattern, from [`examples/simple_window.rs`][sctk-simple]:

```rust
// examples/simple_window.rs — caller owns calloop; the Wayland fd is just one source
let mut event_loop: EventLoop<SimpleWindow> = EventLoop::try_new().unwrap();
WaylandSource::new(conn.clone(), event_queue).insert(event_loop.handle()).unwrap();
loop {
    event_loop.dispatch(Duration::from_millis(16), &mut simple_window).unwrap();
    if simple_window.exit { break; }
}
```

`WaylandSource` registers the Wayland display fd into calloop and, on readiness, reads + dispatches the queue, invoking SCTK handlers. This is the [readiness model applied to windowing][readiness-vs-completion]: poll the socket fd, then dispatch. Because the loop is the caller's, **timers, other fds, and async-runtime integration are calloop's job** (calloop supports `Timer`, generic fd sources, and channel sources for cross-thread user events). For how this overlaps async I/O, see [the async-io survey][async-io].

> [!NOTE]
> The `calloop` feature is _default_ but not mandatory: SCTK can be driven by any loop
> that pumps `wayland-client`'s `EventQueue` (`blocking_dispatch` / `flush`). Without
> `calloop`, **client-side key repeat is disabled** (the repeat timer needs a `LoopHandle`,
> see [Input](#3-input)).

**libdecor's loop integration is the C analogue:** `libdecor_get_fd` + `libdecor_dispatch(timeout)` — the app `poll()`s the fd and calls dispatch, identical in spirit to `wl_display_get_fd`/`wl_display_dispatch`.

**Native loop integration (NSRunLoop / Win32 pump): N/A.** There is no `CFRunLoop`, no Win32 message pump, no [modal resize/move loop][win32-modal-resize] — those are platform concepts absent on Wayland. Resize on Wayland is interactive but cooperative: a click on the CSD border calls `xdg_toplevel.resize(seat, serial, edges)` (SCTK `Window::resize`, [`src/shell/xdg/window/mod.rs`][sctk-window-mod]) and the compositor streams `configure` events; the client never enters a blocking modal loop.

**Frame pacing & vsync.** The vsync source is the Wayland **[frame callback][frame-callback-vsync]**: request `wl_surface.frame` before committing, draw only when `CompositorHandler::frame` fires ([`src/compositor.rs`][sctk-compositor], `FrameCallbackData`). SCTK documents the coalescing intent: "Frame callbacks are used to avoid updating surfaces that are not currently visible" ([`src/compositor.rs`][sctk-compositor]). For richer pacing, SCTK also wraps `wp_presentation` (`PresentationTimeHandler::presented`, [`src/presentation_time.rs`][sctk-presentation]) which delivers actual on-screen timestamps. There is no `CVDisplayLink`, no DXGI waitable swapchain — those are other platforms.

## 3. Input

SCTK owns the [xkbcommon][xkbcommon] state machine. `KeyboardData` holds `xkb::Context`, `xkb::State`, and `xkb::compose::State`, each behind a `Mutex` because "libxkbcommon has no internal synchronization" ([`src/seat/keyboard/mod.rs`][sctk-keyboard]).

**Scancode vs keysym.** SCTK delivers both. A `KeyEvent` carries `raw_code: u32` (the raw evdev code), `keysym: Keysym`, and `utf8: Option<String>` ([`src/seat/keyboard/mod.rs`][sctk-keyboard]). The protocol's "+8" keycode offset is applied before every xkb call — see [scancode/keysym/virtual-key][scancode-keysym-vk]:

```rust
// src/seat/keyboard/mod.rs — wl_keyboard::Event::Key handling
let keycode = KeyCode::new(key + 8);                 // wl_keyboard uses evdev codes; xkb wants +8
let keysym  = guard.key_get_one_sym(keycode);
let utf8 = if state == KeyState::Pressed { /* feed compose, else key_get_utf8 */ } else { None };
```

**Layout handling.** The compositor sends the keymap as an fd; SCTK `mmap`s it and builds `xkb::Keymap::new_from_fd` (the `wl_keyboard::Event::Keymap` arm). Modifiers come from `wl_keyboard.modifiers` and are reduced into a `Modifiers` struct via `mod_name_is_active(MOD_NAME_CTRL, STATE_MODS_EFFECTIVE)` etc.

**Key repeat — the client must do it.** Wayland does _not_ repeat keys; the compositor only sends the repeat _parameters_ (`RepeatInfo { rate, delay }`). SCTK implements repeat with a **calloop timer** ([`src/seat/keyboard/repeat.rs`][sctk-repeat] + the `Pressed` arm of [`src/seat/keyboard/mod.rs`][sctk-keyboard]):

```rust
// src/seat/keyboard/mod.rs — on press, if the key repeats, arm a calloop Timer
let gap = Duration::from_micros(1_000_000 / rate.get() as u64);
let timer = Timer::from_duration(Duration::from_millis(delay as u64));
loop_handle.insert_source(timer, move |_, _, state| {
    // re-deliver via callback; first fire uses `delay`, subsequent use `gap`
    callback(state, &kbd, key.key.clone());
    TimeoutAction::ToDuration(gap)               // reschedule at the repeat rate
});
```

Repeat only arms if `keymap.key_repeats(keycode)` is true, and is cancelled on key release or focus `Leave`. This is the textbook example of "Wayland makes the client do it", and it is why repeat needs `calloop`.

**Dead keys / compose.** SCTK initialises an `xkb::compose::Table` from the locale (`init_compose`, [`src/seat/keyboard/mod.rs`][sctk-keyboard]) and feeds each keysym through `compose.feed(keysym)`; only on `Status::Composed` does it emit the composed `utf8`, supporting é-style dead-key sequences.

**IME / text input — a notable gap.** This is [pre-edit / composition handling][pre-edit]. SCTK is asymmetric here:

- It implements the **IME side** — `zwp_input_method_v2` (`InputMethod`, `set_preedit_string`, `commit_string`, `delete_surrounding_text`; [`src/seat/input_method.rs`][sctk-input-method]) and the experimental `xx-input-method-v2` ([`src/seat/input_method_v3.rs`][sctk-input-method-v3]) — i.e. for _writing an input method_.
- It does **not** ship a client-side `zwp_text_input_v3` _consumer_ handler (a `TextInputHandler` for ordinary apps that want pre-edit/candidate handling). The only `text_input::zv3` import is for the `ContentHint`/`ContentPurpose`/`ChangeCause` enums reused by the input-method code. So a normal SCTK app receives key events but has **no built-in pre-edit or candidate-window plumbing** — that is left to the app or a higher framework (winit layers its own). The CHANGELOG marks input-method support as recently added and "partial" ([`CHANGELOG.md`][sctk-changelog]: "Add partial support for `zwp-input-method-v2`").

No TSF/IMM32/`NSTextInputClient`/XIM — those are other platforms.

**Pointer.** `PointerData` produces `PointerEvent`s with a `PointerEventKind` covering `Enter`/`Leave`/`Motion`/`Press`/`Release`/`Axis` ([`src/seat/pointer/mod.rs`][sctk-pointer]). Motion is **absolute** (surface-local `f64` coordinates); **relative/raw motion** is a separate global, `zwp_relative_pointer_v1` (`RelativePointerHandler::relative_pointer_motion`, [`src/seat/relative_pointer.rs`][sctk-relative]) — see [accelerated vs raw pointer][raw-vs-accel].

**High-resolution scroll.** `AxisScroll` carries `absolute: f64`, legacy `discrete: i32`, and the high-res `value120: i32` from `wl_pointer.axis_value120` (v8); SCTK merges per-axis events across a `wl_pointer.frame` boundary so a single frame can express diagonal scroll ([`src/seat/pointer/mod.rs`][sctk-pointer], the `Frame` arm and `AxisScroll::merge`). This is the Wayland counterpart to Win32 `WM_MOUSEWHEEL` delta accumulation. SCTK added `wl_pointer` v8 and v9 in 0.20.0 ([`CHANGELOG.md`][sctk-changelog]).

**Capture / confinement / locking.** `PointerConstraintsState` wraps `zwp_pointer_constraints_v1` with `confine_pointer` and `lock_pointer` ([`src/seat/pointer_constraints.rs`][sctk-constraints]) — the Wayland equivalents of pointer grab/clip used by FPS-style apps.

**Cursor handling — both paths.** SCTK prefers the modern `wp_cursor_shape_v1` server-side cursor (`CursorShapeManager`, mapping `CursorIcon` → `Shape`, [`src/seat/pointer/cursor_shape.rs`][sctk-cursor-shape]) and falls back to a **client-rendered** themed cursor via `ThemedPointer::set_cursor`/`set_cursor_legacy` (loads a cursor theme into an SHM buffer and `wl_pointer.set_cursor`, [`src/seat/pointer/mod.rs`][sctk-pointer]) when `cursor_shape` is unavailable.

**Touch & gestures.** `TouchHandler` exposes `down`/`up`/`motion`/`shape`/`orientation`/`cancel` ([`src/seat/touch.rs`][sctk-touch]). Gesture protocols (`zwp_pointer_gestures_v1`) are not wrapped by SCTK.

## 4. Wayland specifics

This is the dimension SCTK + libdecor exist for. See [client vs server decoration][csd].

**Decoration negotiation — SCTK's three-way choice.** SCTK binds `zxdg_decoration_manager_v1` (v1 only) when present. The `WindowDecorations` enum maps to `set_mode`:

```rust
// src/shell/xdg/window/mod.rs — DecorationMode mapping (request_decoration_mode)
Some(DecorationMode::Client) => toplevel_decoration.set_mode(Mode::ClientSide),
Some(DecorationMode::Server) => toplevel_decoration.set_mode(Mode::ServerSide),
None                         => toplevel_decoration.unset_mode(),
```

The compositor replies via `zxdg_toplevel_decoration_v1.configure`, decoded into `WindowConfigure.decoration_mode` ([`src/shell/xdg/window/inner.rs`][sctk-window-inner]). SCTK's docs are blunt about the fallback: `decoration_mode` "will always be `DecorationMode::Client` if server side decorations are not enabled or supported" ([`src/shell/xdg/window/mod.rs`][sctk-window-mod]).

**Does SCTK draw its own CSD? Yes — a _fallback_ frame, not libdecor.** SCTK ships `FallbackFrame` ([`src/shell/xdg/fallback_frame.rs`][sctk-fallback]), a minimal titlebar+border drawn into SHM (via `tiny-skia`/raqote-style raster), implementing the `DecorationsFrame` trait from `wayland-csd-frame`. It maps clicks to `FrameAction::{Move, Close, Minimize, Maximize, UnMaximize, Resize(edge), ShowMenu}` ([`src/shell/xdg/fallback_frame.rs`][sctk-fallback]). It is intentionally spartan (three buttons, no theming) — for a _native-looking_ titlebar, applications reach for **libdecor** instead. So the catalog's CSD landscape is: compositor SSD → SCTK `FallbackFrame` (ugly but dependency-free) → libdecor (native, plugin-drawn).

**libdecor's SSD↔CSD decision.** libdecor binds `zxdg_decoration_manager_v1` if available and, per frame, requests SSD; the compositor's `zxdg_toplevel_decoration_v1.configure` sets `frame_priv->decoration_mode` ([`libdecor.c`][libdecor-c], `toplevel_decoration_configure`). If the mode comes back `SERVER_SIDE`, libdecor draws nothing; if `CLIENT_SIDE` (or no manager exists), the plugin draws. libdecor is candid that the toggle is best-effort:

> enable/disable decorations that are managed by the compositor. Note that, as of
> xdg_decoration v1, this is just a hint and there is no reliable way of disabling all
> decorations. In practice this should work but per spec this is not guaranteed.
> — [`libdecor.c`][libdecor-c], `libdecor_frame_set_visibility`

**libdecor's plugin model.** The core is decoration-agnostic. At `libdecor_new`, `init_plugins` scans `LIBDECOR_PLUGIN_DIR` (colon-separated), `dlopen`s each `.so`, reads its `libdecor_plugin_description`, computes a per-desktop priority, and keeps the highest-priority loadable plugin; on total failure it falls back to a no-op plugin ([`libdecor.c`][libdecor-c]):

```c
// src/libdecor.c — libdecor_new tail: choose a plugin or fall back to no decorations
if (init_plugins(context) != 0) {
    fprintf(stderr, "No plugins found, falling back on no decorations\n");
    context->plugin = libdecor_fallback_plugin_new(context);
}
```

Priority is `{ desktop, int }` matched against `XDG_CURRENT_DESKTOP` ([`libdecor-plugin.h`][libdecor-plugin-h], `calculate_priority` in [`libdecor.c`][libdecor-c]). The two shipped plugins:

| Plugin  | Priority (default desktop)        | Backend                 | File                                                   |
| ------- | --------------------------------- | ----------------------- | ------------------------------------------------------ |
| `gtk`   | `LIBDECOR_PLUGIN_PRIORITY_HIGH`   | GTK3 (native theming)   | [`src/plugins/gtk/libdecor-gtk.c`][libdecor-gtk]       |
| `cairo` | `LIBDECOR_PLUGIN_PRIORITY_MEDIUM` | Cairo + Pango (generic) | [`src/plugins/cairo/libdecor-cairo.c`][libdecor-cairo] |

So **GTK wins when installed** (giving Adwaita-style titlebars on GNOME), else Cairo draws a generic frame; the cairo plugin even borrows weston's shadow blur (`render_shadow`, [`libdecor-cairo-blur.c`][libdecor-blur]). A `check_symbol_conflicts` guard refuses to load a plugin whose symbols (`png_free`, `gdk_get_use_xshm`, …) clash with the host process ([`libdecor.c`][libdecor-c], gtk plugin's `conflicting_symbols`) — a hard-won workaround for clients that already link GTK/libpng.

**Protocol coverage.** SCTK is broad. Beyond core + `xdg-shell`, it wraps (grep of `src/`): `xdg-activation-v1` (`ActivationState`, [`src/activation.rs`][sctk-activation]), `xdg-decoration`, `wp-presentation-time`, `wp-cursor-shape-v1`, `wp-pointer-constraints`, `wp-relative-pointer`, `wp-primary-selection`, `wp-linux-dmabuf`, `wlr-layer-shell` ([`src/shell/wlr_layer/`][sctk-layer]), `ext-session-lock-v1`, `ext-foreign-toplevel-list-v1`, `zxdg-output-v1`, plus `text-input`/`input-method`.

> [!WARNING]
> **SCTK has no `fractional-scale-v1` or `viewporter` support.** A repo-wide grep for
> `fractional` returns nothing. SCTK tracks only **integer** scale (see
> [DPI & scaling](#5-dpi-scaling)); fractional scaling is left to frameworks built on top.
> SCTK also has no `idle-inhibit`. Its scope is the integer-scale, core-plus-xdg surface area.

**Compositor-specific workarounds.** SCTK carries weston-specific touch hacks: it works around "touch up events delivered too late with certain Weston versions" ([`CHANGELOG.md`][sctk-changelog]) and notes "Weston doesn't always send a frame even after the last touch point was released" linking [weston#44][weston-44] ([`src/seat/touch.rs`][sctk-touch]). libdecor's GNOME accommodation is structural: the GTK plugin exists _because_ Mutter ships no `xdg-decoration` SSD, so libdecor must draw a GTK-native titlebar there.

## 5. DPI & scaling

The [scale-factor][scale-factor] model is **integer-only** in SCTK, and the API native unit is the surface's buffer scale. See [logical vs physical coordinates][logical-vs-physical].

**Where the scale comes from.** Two paths in `SurfaceData` ([`src/compositor.rs`][sctk-compositor]):

- **v6 surfaces:** `wl_surface.preferred_buffer_scale` delivers an integer factor directly; SCTK stores it and fires `CompositorHandler::scale_factor_changed` only on change.
- **Pre-v6:** SCTK derives the factor from the _outputs the surface overlaps_, taking the **maximum** `OutputInfo.scale_factor` across them (`dispatch_surface_state_updates` reduces with `acc.0.max(props.0)`, [`src/compositor.rs`][sctk-compositor]), and installs a scale-watcher so a later output-scale change re-fires the handler.

**The "created at wrong scale then rescaled" problem.** A pre-v6 surface has no scale until it `enter`s an output, so SCTK seeds `SurfaceData::new(_, scale_factor: 1, _)` and corrects it via `scale_factor_changed` once outputs are known — exactly the rescale-after-creation hazard the concepts page describes.

**Not applicable here:** per-monitor DPI on Windows (v1/v2 awareness, the `WM_DPICHANGED` dance) and macOS backing scale are other platforms. **Fractional scaling is absent in SCTK** (no `fractional-scale-v1`; see the warning above) — a client that wants 1.5× must either round to integer scale or implement `fractional-scale-v1` + `viewporter` itself. Mixed-DPI multi-monitor: a surface spanning two outputs takes the _max_ scale (over-rendering on the lower-DPI monitor), and migration between monitors re-fires `scale_factor_changed`.

## 6. Multi-window & popups

**Popups.** SCTK's `Popup` wraps `xdg_popup` with an `XdgPositioner` ([`src/shell/xdg/popup.rs`][sctk-popup]). Popups are positioned relative to a parent `xdg_surface` via the positioner's anchor/gravity/constraint rules — there is no absolute placement. This is the [xdg_popup grab vs X11 override-redirect][override-redirect-popup] distinction: a Wayland menu is an `xdg_popup` with an explicit `grab(seat, serial)`, dismissed by the compositor on click-outside, _not_ an [override-redirect][override-redirect-popup] window the client positions and stacks itself.

**Popup grab in libdecor.** Because libdecor owns the titlebar, it also owns the window-menu popup; it forwards grab/ungrab via `libdecor_frame_popup_grab(frame, seat_name)` / `libdecor_frame_popup_ungrab` and asks the app to dismiss its own popups through the `dismiss_popup(frame, seat_name, ...)` callback ([`libdecor.h`][libdecor-h]) — the seat-name plumbing exists precisely because grabs are per-seat.

**Modal dialogs / parent-child.** `Window::set_parent(Option<&Window>)` establishes the toplevel parent relationship (`xdg_toplevel.set_parent`, [`src/shell/xdg/window/mod.rs`][sctk-window-mod]); libdecor mirrors it with `libdecor_frame_set_parent`. There is no Wayland "modal" flag — modality is a compositor convention layered on the parent link. **Window groups / explicit stacking are not exposed** (Wayland gives clients no control over stacking order, by design). Tooltips are typically `xdg_popup`s without a grab.

## 7. Threading

**Wayland imposes no main-thread rule** — unlike macOS AppKit, there is no thread that must own the UI. The constraints are SCTK's own:

- **`wayland-client` event dispatch is single-threaded per `EventQueue`.** SCTK handlers run on whatever thread calls `event_loop.dispatch` / `EventQueue::dispatch`. The toolkit does not move events between threads.
- **`Send`/`Sync` are required on user data**, e.g. `create_surface_with_data<D, U> where U: Send + Sync + 'static` ([`src/compositor.rs`][sctk-compositor]), because proxy object-data may be touched from the backend. Internally SCTK guards shared state with `Mutex` (the xkb state, `pending_configure`, `SurfaceDataInner`).
- **Rendering can happen off the event thread** — the buffer is just SHM/dmabuf memory; nothing stops a render thread from filling a buffer and another thread from committing, as long as Wayland calls are serialized. SCTK does not prescribe this.

So the model is "one event-dispatch thread by construction, rendering wherever you like" — driven by the readiness loop, not by any platform main-thread requirement. The contrast with AppKit (main-thread-only) and Win32 (the message pump's thread owns the window) is a _platform_ difference, not an SCTK choice.

## 8. Clipboard & DnD

SCTK wraps the Wayland **selection** model via `wl_data_device_manager` ([`src/data_device_manager/`][sctk-data-device]).

- **Copy/paste:** `create_copy_paste_source(mime_types)` builds a `CopyPasteSource` advertising MIME types; the receiver reads through a pipe (`read_pipe.rs`/`write_pipe.rs`). MIME negotiation is explicit — the source offers strings, the destination picks one and `receive`s an fd. This is the Wayland selection model: the data flows through a pipe fd on demand, the toolkit-level equivalent of X11 selections **without** the [INCR protocol][x11-selections] (Wayland uses a pipe, so no chunked-transfer property dance).
- **Drag-and-drop:** `create_drag_and_drop_source(mime_types, dnd_actions)` plus `DataDeviceHandler` callbacks for enter/leave/motion/drop. The data-device code carries several "`XXX` Drop done here to prevent Mutex deadlocks" notes ([`src/data_device_manager/data_device.rs`][sctk-data-device-rs]) — a sign the selection state machine is fiddly.
- **Primary selection:** a separate `wp_primary_selection` wrapper ([`src/primary_selection/`][sctk-primary]) for middle-click paste.

**Not applicable:** Win32 delayed rendering and X11 INCR are other platforms; the Wayland pipe-fd model sidesteps both (data is rendered lazily when the consumer opens the pipe, which is delayed-rendering in spirit but mechanically different).

## 9. Escape hatches

SCTK is _itself_ mostly escape hatch — it is a thin layer, so reaching the native objects is trivial and expected:

- **Raw protocol objects:** every wrapper exposes its proxy — `Window::xdg_toplevel()`, `XdgSurface::xdg_surface()`, `WaylandSurface::wl_surface()`, `XdgShell::xdg_wm_base()`. You can call any `wayland-client` request directly.
- **The connection backend:** `conn.backend().display_ptr()` and `surface.id().as_ptr()` give the raw C pointers needed to build a [`raw-window-handle`][rwh] for `wgpu`/`vulkan` ([`examples/wgpu.rs`][sctk-wgpu]) — required _because_ SCTK does not implement the trait.
- **Bring-your-own dispatch:** the `Dispatch2`/`delegate_dispatch2!` machinery ([`src/dispatch2.rs`][sctk-dispatch2]) lets an app handle protocols SCTK doesn't wrap (e.g. `fractional-scale-v1`) on its own state, alongside SCTK's handlers.

For libdecor: `libdecor_frame_get_xdg_surface` / `libdecor_frame_get_xdg_toplevel` ([`libdecor.h`][libdecor-h]) hand the raw role objects back so the app can set its own toplevel properties libdecor doesn't wrap. The leak this reveals: SCTK's abstraction is _deliberately_ incomplete (no fractional scale, no text-input consumer), so the escape hatches are not failure modes but the intended extension mechanism.

## 10. History, redesigns & known regrets

**libdecor's origin: the GTK CSD story.** [Client-side decorations][csd] became unavoidable when GNOME/Mutter decided to draw none server-side (~GTK 3.10, 2013–2014), forcing every GTK app to draw its own titlebar. Non-GTK clients (SDL, GLFW, Firefox, games) then each badly reimplemented that titlebar. libdecor was created (Jonas Ådahl / Christian Rauch, copyrights 2017–2019 in [`libdecor.c`][libdecor-c]) to extract a _reusable, compositor-portable_ CSD library so the GTK-blessed look could be shared — hence the GTK plugin being the high-priority backend. The `xdg-decoration` protocol was the standardisation attempt to let the _compositor_ draw decorations again ([xdg-decoration-unstable-v1][xdg-decoration-proto]); libdecor's `set_visibility` comment links the very protocols MR that debated whether SSD could be reliably forced ([wayland-protocols!17][wp-mr-17]).

**The unresolved tension (the genuine regret).** `xdg-decoration` v1 made SSD a _hint_, not a guarantee — libdecor's source admits "there is no reliable way of disabling all decorations" ([`libdecor.c`][libdecor-c]). So on GNOME, every non-GTK client _must_ carry libdecor (or draw its own frame); there is no way to demand SSD. This split — KDE/wlroots offer SSD, GNOME never does — is the central, still-open Wayland decoration regret, and the reason both SCTK's `FallbackFrame` and libdecor exist at all.

**SCTK redesigns across `wayland-rs` versions.** SCTK was rewritten around the modern `wayland-rs` 0.30+ object model: the handler-trait + `Dispatch` architecture replaced the older callback style. The `0.20.0` cycle and the `Unreleased` section show the churn is ongoing ([`CHANGELOG.md`][sctk-changelog]):

- _Unreleased:_ "All `delegate_*!` macros except `delegate_registry!` replaced with single `delegate_dispatch2!` in preparation for future wayland-rs release" and "`*DataExt` traits removed" — a breaking simplification of the dispatch model.
- _0.20.0 (2025-07-29):_ added `wl_keyboard` v10, `wl_pointer` v8/v9, `wp_cursor_shape_manager_v1` v2, `wp_presentation`, `ext-foreign-toplevel-list-v1`, partial `zwp-input-method-v2`; **"Fix keyboard sending press events when repeat is disabled"** — a real bug in the client-side-repeat logic described in [Input](#3-input).
- _0.19.x:_ `SessionLock` required an explicit `unlock` call "to avoid accidental unlock", and a crash fix "when compositor sends event to dead `wl_output`" — both compositor-robustness lessons.

The recurring theme: each `wayland-rs` major version forces an SCTK redesign, and each compositor's quirks (Weston touch timing, dead outputs) land as targeted workarounds rather than abstractions.

---

## Strengths

- **Honest, thin protocol mirror.** SCTK does not lie about Wayland's negotiated, double-buffered nature; the configure/ack handshake is visible, so apps that need it can get it exactly right.
- **Loop-agnostic with first-class calloop.** Plugs into any readiness loop; doesn't fight the host application's architecture.
- **Correct, hard-won Wayland details for free:** destruction ordering, the +8 keycode offset, client-side key repeat, scale-watcher rescaling, per-frame axis merging, cursor-shape-with-fallback.
- **libdecor's plugin model** cleanly separates "draw a native titlebar" from the core, so a GTK-themed frame is available without the core linking GTK, and clients that already link GTK are protected by symbol-conflict checks.
- **Broad protocol coverage** (activation, layer-shell, session-lock, foreign-toplevel, presentation-time, dmabuf, constraints).
- **Everything is an escape hatch** — raw proxies and `Dispatch2` make unwrapped protocols easy to add.

## Weaknesses

- **Wayland only.** No portability; a cross-platform app needs a framework on top.
- **No `fractional-scale-v1` / `viewporter` / `idle-inhibit`** in SCTK — fractional DPI is the app's problem.
- **No client-side `text_input_v3` consumer** — ordinary apps get key events but no built-in pre-edit/candidate IME plumbing; input-method support is "partial".
- **`FallbackFrame` is intentionally ugly** (three buttons, no theming); native-looking CSD means pulling in libdecor (and transitively GTK/Cairo/Pango).
- **The SSD-vs-CSD split is unsolved upstream** — GNOME never offers SSD, so libdecor is effectively mandatory there, and `set_mode(SERVER_SIDE)` is only a hint.
- **Frequent breaking changes** as `wayland-rs` evolves (the `delegate_dispatch2!` churn, `*DataExt` removal).

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                         | Trade-off                                                                                  |
| ----------------------------------------------------------- | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Handler traits + `delegate_dispatch2!`, no inheritance      | Maps cleanly onto `wayland-client`'s `Dispatch`; one app state struct, no vtables | Verbose boilerplate; macro churn breaks downstreams each `wayland-rs` major                |
| Caller owns the loop; integrate via `calloop`               | Composes with any host architecture; doesn't hide the socket fd                   | Client-side key repeat (and convenience) only work with the `calloop` feature              |
| Expose the configure/ack handshake verbatim                 | Lets apps get Wayland's negotiated sizing/state exactly right                     | Steeper learning curve than a synchronous `resize()` setter                                |
| Integer scale only; no fractional-scale support             | Keeps SCTK small and covers the common case                                       | Fractional-DPI displays render at the rounded integer scale unless the app adds it itself  |
| Ship a minimal `FallbackFrame`, punt native CSD to libdecor | Dependency-free decorations for apps that don't care about looks                  | Native titlebars require libdecor → GTK/Cairo/Pango dependency chain                       |
| libdecor: `dlopen` plugins chosen by per-desktop priority   | GTK-native look on GNOME without the core linking GTK; generic Cairo elsewhere    | Runtime plugin resolution; symbol-conflict guards needed; an extra `.so` dependency        |
| libdecor owns the `xdg_surface`/`xdg_toplevel`              | Decorations and content stay in sync (geometry, move/resize) without app glue     | App must obtain the role objects via getters; libdecor and SCTK can't both wrap one window |
| Don't implement `raw-window-handle`; expose raw pointers    | Avoids a dependency and a versioning treadmill                                    | Every GPU integration hand-builds the handle from `display_ptr()`/`surface.id()`           |

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **client-side key-repeat timer** pattern ([`repeat.rs`][sctk-repeat]) — it is the correct, compositor-faithful way to do repeat, and every Wayland backend needs it.
- **Destruction-ordering encoded in `Drop`** ([`window/inner.rs`][sctk-window-inner]) — make the type system enforce children-first teardown.
- **Per-frame axis merging + scale-watcher rescaling** — both are subtle correctness wins that are easy to get wrong by hand.
- libdecor's **priority-based `dlopen` plugin model with symbol-conflict guards** — a clean recipe for pluggable, host-safe native theming.

**Avoid:**

- Shipping _only_ integer scale — a modern framework must do `fractional-scale-v1` + `viewporter` from day one.
- Leaving the **text-input consumer** unimplemented — IME is table-stakes; don't make every app reinvent pre-edit handling.
- Treating SSD as reliable — design for "SSD is a hint" and always have a CSD path (this is the lesson GNOME forced on the whole ecosystem).

## Open questions I could not resolve (with where the answer likely lives)

- **Exactly which compositors will be left undecorated** when both `xdg-decoration` is absent _and_ libdecor finds no plugin (the fallback no-op plugin path). Likely answered by `libdecor-fallback.c` behaviour and per-compositor testing; see [`src/libdecor-fallback.c`][libdecor-c] and downstream bug trackers.
- **Whether SCTK plans a first-class `fractional-scale-v1` wrapper** or considers it permanently out of scope. Likely in the [SCTK issue tracker][sctk-issues] / wayland-rs roadmap.
- **The precise GNOME-vs-cairo plugin behaviour** when GTK is present but `XDG_CURRENT_DESKTOP` is non-GNOME — `calculate_priority` matches on desktop strings, but both shipped plugins use a `NULL` (default) desktop entry, so resolution is by static HIGH/MEDIUM priority; whether downstream packagers ship desktop-specific overrides is unclear from the source alone.

## Sources

- [Smithay/client-toolkit][sctk-repo] — SCTK source (all quoted SCTK paths, pinned at `70a21c0`)
- [SCTK docs.rs][sctk-docs] — API reference
- [SCTK `CHANGELOG.md`][sctk-changelog] — redesign history, version-gating, bug fixes
- [libdecor][libdecor-archive] (gitlab.freedesktop.org) — libdecor source `0.2.2` @ `59c498a`
- [`libdecor.h`][libdecor-h] / [`libdecor.c`][libdecor-c] / [`libdecor-plugin.h`][libdecor-plugin-h] — the C API, plugin loader, decoration negotiation
- [xdg-decoration-unstable-v1][xdg-decoration-proto] / [text-input-unstable-v3][text-input-proto] / [cursor-shape-v1][cursor-shape-proto] / [fractional-scale-v1][fractional-scale-proto] — protocol specs (wayland.app)
- [wayland-protocols!17][wp-mr-17] — the SSD-vs-CSD protocol debate libdecor links
- [weston#44][weston-44] — the touch-frame bug SCTK works around
- [`calloop`][calloop] / [`calloop-wayland-source`][calloop-wl-source] / [`wayland-rs`][wayland-rs] — the loop and binding crates SCTK builds on
- Sibling docs: [concepts][concepts], [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[sctk-repo]: https://github.com/Smithay/client-toolkit
[sctk-docs]: https://docs.rs/smithay-client-toolkit/latest/smithay_client_toolkit/
[sctk-readme]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/README.md
[sctk-changelog]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/CHANGELOG.md
[sctk-xdg-mod]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/xdg/mod.rs
[sctk-window-mod]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/xdg/window/mod.rs
[sctk-window-inner]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/xdg/window/inner.rs
[sctk-compositor]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/compositor.rs
[sctk-keyboard]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/keyboard/mod.rs
[sctk-repeat]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/keyboard/repeat.rs
[sctk-pointer]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/pointer/mod.rs
[sctk-cursor-shape]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/pointer/cursor_shape.rs
[sctk-relative]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/relative_pointer.rs
[sctk-constraints]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/pointer_constraints.rs
[sctk-touch]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/touch.rs
[sctk-input-method]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/input_method.rs
[sctk-input-method-v3]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/seat/input_method_v3.rs
[sctk-output]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/output.rs
[sctk-fallback]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/xdg/fallback_frame.rs
[sctk-popup]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/xdg/popup.rs
[sctk-activation]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/activation.rs
[sctk-presentation]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/presentation_time.rs
[sctk-layer]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/shell/wlr_layer/mod.rs
[sctk-data-device]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/data_device_manager/mod.rs
[sctk-data-device-rs]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/data_device_manager/data_device.rs
[sctk-primary]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/primary_selection/mod.rs
[sctk-dispatch2]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/src/dispatch2.rs
[sctk-simple]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/examples/simple_window.rs
[sctk-wgpu]: https://github.com/Smithay/client-toolkit/blob/70a21c022d20671f390ea1030256b7301dca5329/examples/wgpu.rs
[sctk-issues]: https://github.com/Smithay/client-toolkit/issues
[libdecor-archive]: https://gitlab.freedesktop.org/libdecor/libdecor
[libdecor-h]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/libdecor.h
[libdecor-c]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/libdecor.c
[libdecor-plugin-h]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/libdecor-plugin.h
[libdecor-gtk]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/plugins/gtk/libdecor-gtk.c
[libdecor-cairo]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/plugins/cairo/libdecor-cairo.c
[libdecor-blur]: https://gitlab.freedesktop.org/libdecor/libdecor/-/blob/master/src/plugins/common/libdecor-cairo-blur.c
[calloop]: https://github.com/Smithay/calloop
[calloop-wl-source]: https://github.com/Smithay/calloop-wayland-source
[wayland-rs]: https://github.com/Smithay/wayland-rs
[xkbcommon]: https://xkbcommon.org/
[rwh]: https://docs.rs/raw-window-handle/latest/raw_window_handle/
[xdg-decoration-proto]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[text-input-proto]: https://wayland.app/protocols/text-input-unstable-v3
[cursor-shape-proto]: https://wayland.app/protocols/cursor-shape-v1
[fractional-scale-proto]: https://wayland.app/protocols/fractional-scale-v1
[wp-mr-17]: https://gitlab.freedesktop.org/wayland/wayland-protocols/-/merge_requests/17
[weston-44]: https://web.archive.org/web/20240208180924/https://gitlab.freedesktop.org/wayland/weston/-/issues/44
[csd]: ./concepts.md#client-vs-server-decoration
[scancode-keysym-vk]: ./concepts.md#scancode-keysym-virtualkey
[logical-vs-physical]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pre-edit]: ./concepts.md#pre-edit-composition
[override-redirect-popup]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[win32-modal-resize]: ./concepts.md#win32-modal-resize-loop
[raw-vs-accel]: ./concepts.md#raw-vs-accelerated-pointer
[no-buffer-no-window]: ./concepts.md#no-buffer-no-window
[frame-callback-vsync]: ./concepts.md#frame-callback-vsync
[readiness-vs-completion]: ./concepts.md#readiness-vs-completion-windowing
[x11-selections]: ./concepts.md#client-vs-server-decoration
[concepts]: ./concepts.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
