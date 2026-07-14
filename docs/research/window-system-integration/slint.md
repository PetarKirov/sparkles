# Slint (Rust)

A declarative, reactive GUI toolkit that defines its own `Platform`/`WindowAdapter` backend abstraction in the core crate, then ships several implementations of it — a [winit]-based desktop/web/mobile backend, a bare [`linuxkms`][linuxkms-dir] backend that drives DRM/KMS with no compositor, a Qt backend, and an Android backend. The windowing layer is therefore _two_ abstractions stacked: Slint's own `WindowAdapter` over winit's `Window`/`ApplicationHandler`, or over raw [DRM]/[libinput].

| Field                  | Value                                                                                                                                                                      |
| ---------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit studied | `1.17.0` dev, commit [`24318cebc2`][commit] (2026-06-06)                                                                                                                   |
| Language               | Rust (edition 2024; `rust-version = "1.92"`)                                                                                                                               |
| License                | GPL-3.0-only OR LicenseRef-Slint-Royalty-free-2.0 OR LicenseRef-Slint-Software-3.0 (tri-license)                                                                           |
| Repository             | [slint-ui/slint]                                                                                                                                                           |
| Documentation          | [slint.dev docs][slint-docs] / [`Platform` API docs][platform-docs]                                                                                                        |
| Category               | Reactive UI toolkit on a pluggable backend abstraction                                                                                                                     |
| Platforms covered      | Wayland, X11, Win32, macOS/AppKit, Android, iOS, Web (wasm), bare-metal Linux KMS, `no_std`                                                                                |
| Loop ownership         | Hybrid: callback-driven via winit's `ApplicationHandler` (desktop), or a hand-rolled [calloop] loop (KMS)                                                                  |
| Repo paths (platform)  | [`internal/core/platform.rs`][platform-rs], [`internal/core/window.rs`][window-rs], [`internal/backends/winit/`][winit-dir], [`internal/backends/linuxkms/`][linuxkms-dir] |

---

## Overview

### What it solves

Slint separates the _scene graph and reactive engine_ (the `i-slint-core` crate) from the _windowing and rendering_ concern, which is delegated to an interchangeable backend. The seam is the `Platform` trait, documented in [`internal/core/platform.rs`][platform-rs] as:

> This trait defines the interface between Slint and platform APIs typically provided by operating and windowing systems.

A `Platform` produces `WindowAdapter`s and (optionally) spins an event loop:

```rust
// internal/core/platform.rs
pub trait Platform {
    /// Instantiate a window for a component.
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, PlatformError>;

    /// Spins an event loop and renders the visible windows.
    fn run_event_loop(&self) -> Result<(), PlatformError> {
        Err(PlatformError::NoEventLoopProvider)
    }
    // ... process_events, new_event_loop_proxy, duration_since_start, clipboard, ...
}
```

This is the same kind of capability-trait/default-method design Sparkles encodes via [Design by Introspection][dbi] — the core never names a concrete OS; it asks the backend. The key structural twist for this survey is that the **flagship winit backend is itself an adapter over another full windowing abstraction** (winit), whereas the `linuxkms` backend implements the same `WindowAdapter` trait directly on top of [DRM]/[libinput] with no display server at all.

### Design philosophy

- **Reactive core, replaceable shell.** The core owns properties, layout (see the companion [ui-layout survey][ui-layout]), animations, and a software renderer; everything OS-touching is behind `Platform`/`WindowAdapter`. A backend can be as thin as the `linuxkms` one or as thick as the winit one.
- **Logical coordinates are the API native unit.** Every `WindowEvent` position is documented "in logical window coordinates" ([`platform.rs`][platform-rs]); the backend converts physical winit pixels to logical using the [scale factor][scale-factor] before dispatch.
- **The core drives time, the backend drives the loop.** `update_timers_and_animations()` and `duration_until_next_timer_update()` live in core; each backend's loop calls them once per iteration and uses the returned timeout to size its sleep. This keeps animation/timer semantics identical across backends.
- **`#![no_std]`-capable.** `Platform` has a `duration_since_start` hook precisely so the toolkit can run on bare metal with a custom backend, with `std` gated behind a feature.
- **Don't reinvent winit.** Rather than write per-OS windowing code, Slint reuses [winit] (and [glutin]/[softbuffer]/[Skia]) and layers its reactive needs on top — at the cost of an extra abstraction layer and being bound by winit's model and bugs (see [§10](#10-history-redesigns-known-regrets)).

---

## How it works

### The two-trait core abstraction

The contract is split across [`internal/core/window.rs`][window-rs]:

- `WindowAdapter` — the public, user-implementable trait: `window()`, `set_visible()`, `position()`/`set_position()`, `set_size()`/`size()`, `request_redraw()`, `renderer()`, `update_window_properties()`, and the `raw-window-handle` getters.
- `WindowAdapterInternal` (`#[doc(hidden)]`) — the private extension: `set_mouse_cursor()`, `input_method_request()`, `create_child_window_adapter()`, `supports_native_menu_bar()`, `safe_area_inset()`, etc.

A backend never sees Slint's items; it pushes input in (`Window::try_dispatch_event(WindowEvent)`) and pulls properties out (`update_window_properties(WindowProperties)`). The `WindowEvent` enum ([`platform.rs`][platform-rs]) is the entire input/lifecycle vocabulary: `PointerPressed/Released/Moved/Scrolled/Exited`, `KeyPressed/KeyPressRepeated/KeyReleased`, `ScaleFactorChanged`, `Resized`, `CloseRequested`, `WindowActiveChanged`.

### The winit backend: an `ApplicationHandler`

The desktop backend ([`internal/backends/winit/`][winit-dir]) implements winit `0.30.2`'s `ApplicationHandler<SlintEvent>` trait on an `EventLoopState` struct ([`event_loop.rs`][event-loop-rs]). winit owns the loop and calls back into Slint:

```rust
// internal/backends/winit/event_loop.rs
impl winit::application::ApplicationHandler<SlintEvent> for EventLoopState {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) { /* create_inactive_windows */ }
    fn window_event(&mut self, event_loop, window_id, event: WindowEvent) { /* translate + dispatch */ }
    fn user_event(&mut self, event_loop, event: SlintEvent) { /* UserEvent / Exit / AccessKit / Muda */ }
    fn new_events(&mut self, event_loop, cause) { event_loop.set_control_flow(ControlFlow::Wait); update_timers_and_animations(); }
    fn about_to_wait(&mut self, event_loop) { /* coalesce, request redraws, size the next sleep */ }
}
```

Each Slint `WinitWindowAdapter` is registered in a `SharedBackendData` keyed by `winit::window::WindowId`, so `window_event` routes to the right adapter via `window_by_id` ([`lib.rs`][winit-lib-rs] `SharedBackendData`).

### The window adapter holds "window or attributes"

The single cleverest data structure in the winit backend is `WinitWindowOrNone` ([`winitwindowadapter.rs`][winit-window-rs]): a window adapter exists _before_ a winit `Window` does, so it stores either the live window or the pending `WindowAttributes`:

```rust
// internal/backends/winit/winitwindowadapter.rs
enum WinitWindowOrNone {
    HasWindow { window: Arc<winit::window::Window>, frame_throttle: Box<dyn FrameThrottle>, /* accesskit, muda, ... */ },
    None(RefCell<WindowAttributes>),
}
```

Every setter (`set_title`, `set_decorations`, `set_fullscreen`, `set_min_inner_size`, …) is implemented twice — once forwarding to the live `Window`, once mutating the buffered `WindowAttributes` — so property changes made before the window is mapped are replayed at creation in `ensure_window()`. This is how Slint copes with winit `0.30`'s rule that windows may only be created from inside `resumed()`/an active event loop. See [§2](#2-event-loop) and [§7](#7-threading).

### The linuxkms backend: a hand-rolled calloop loop

The bare-metal backend ([`calloop_backend.rs`][calloop-rs]) implements `Platform` directly and owns its own loop built on [calloop] `0.14`, multiplexing libinput, a user-event channel, and DRM page-flip events. There is exactly one fullscreen window (`FullscreenWindowAdapter`); there is no compositor, no decorations, no multi-window. Its `run_event_loop` is the explicit, readable counterpart to winit's callback model (quoted in full in [§2](#2-event-loop)).

---

## 1. Window creation & lifecycle

**Per-platform create call.** Slint never calls `CreateWindowEx`/`XCreateWindow`/`-[NSWindow init]`/`wl_compositor` itself in the winit backend — it builds a `winit::window::WindowAttributes` and hands it to `renderer.resume(active_event_loop, window_attributes)`, which calls winit's `ActiveEventLoop::create_window` (wrapped so the renderer can attach its GL/Vulkan/software surface). The exact native call is whatever winit does per platform. In the `linuxkms` backend there is no window object at all: `FullscreenWindowAdapter::new` opens a DRM device (via [libseat] or a raw `open`) and takes over a CRTC.

**The deferral model.** `WinitWindowAdapter::new` registers the adapter as an _inactive_ window and stores `WinitWindowOrNone::None(attributes)`. The real winit window is materialized lazily in `ensure_window()` ([`winitwindowadapter.rs`][winit-window-rs]), driven from `resumed()`/`about_to_wait()`:

```rust
// internal/backends/winit/winitwindowadapter.rs  (ensure_window, abridged)
// Never show the window right away, as we
//  a) need to compute the correct size based on the scale factor before it's shown ...
//  b) need to create the accesskit adapter before it's shown ...
let show_after_creation = std::mem::replace(&mut window_attributes.visible, false);
let winit_window = self.renderer.resume(active_event_loop, window_attributes)?;
let scale_factor = overriding_scale_factor.unwrap_or_else(|| winit_window.scale_factor() as f32);
self.window().try_dispatch_event(WindowEvent::ScaleFactorChanged { scale_factor })?;
```

So Slint learns the [scale factor][scale-factor] _before_ the window is visible, sizes it, then shows it — its answer to the [created-at-wrong-scale][logical-vs-physical-coords] problem.

**Window-attributes model.** Mapped onto winit `WindowAttributes` in `update_window_properties` and the `WinitWindowOrNone` setters: title, inner size (logical), min/max size, decorations (`no_frame`), transparency (`with_transparent(true)` is the default — see the base `window_attributes()`), always-on-top (`WindowLevel::AlwaysOnTop`), fullscreen, maximized, resizable, window icon. Silently unsupported per platform:

> [!WARNING]
> `set_minimized` on a not-yet-created window is a no-op with the comment `/* TODO: winit is missing attributes.minimized */`. Minimizing is only honored on an already-mapped window. Several attributes (transparency, always-on-top, decorations toggling) are honored or ignored entirely at winit's discretion per compositor/WM.

**Initial-frame handling.** This is platform-shaped by winit. On Wayland the [no-buffer-no-window][no-buffer-no-window] rule means creating a window implies showing it; Slint explicitly notes this in `suspend()`:

> Note: Don't register the window in inactive_windows for re-creation later, as creating the window on wayland implies making it visible. Unfortunately, winit won't allow creating a window on wayland that's not visible.

Consequently, hiding a window on Wayland _destroys_ it (`suspend()` drops the `Arc<Window>` and reverts to `WinitWindowOrNone::None`), gated on detecting `RawWindowHandle::Wayland` (`set_visibility`, `winitwindowadapter.rs`). On X11/Win32 hiding is a real `set_visible(false)`.

**Surface/handle exposure.** Via [raw-window-handle] `0.6` (`rwh_06` winit feature). `WindowAdapter::window_handle_06`/`display_handle_06` and the internal `*_rc` variants return the `Arc<winit::window::Window>` (which implements `HasWindowHandle`/`HasDisplayHandle`). This is what the Skia/femtovg/wgpu renderers consume to create their surfaces, and what an app uses as the [escape hatch][escape] (see [§9](#9-escape-hatches)).

**Destruction-ordering hazard.** `suspend()` uses `Arc::into_inner(last_window_rc)` and only proceeds if it is the _sole_ owner; otherwise it logs:

> Slint winit backend: request to hide window failed because references to the window still exist. This could be an application issue, make sure that there are no slint::WindowHandle instances left

i.e. leaking a `raw-window-handle` `Arc` past hide leaves the window alive.

---

## 2. Event loop

**Who owns the loop — hybrid, by backend.**

- **winit backend (callback-driven, loop owned by winit).** winit runs the native pump (`NSApplication`/`CFRunLoop` on macOS, the Win32 message loop, Wayland fd dispatch via [calloop] _inside winit_, X11 connection polling) and calls back into Slint's `ApplicationHandler`. Slint cannot block; it must return from each callback.
- **linuxkms backend (poll-based, loop owned by Slint).** Slint owns an explicit `while !quit { ... }` loop over `calloop::EventLoop::dispatch`.

**The winit redesign history matters.** winit `0.30` (adopted in Slint `1.7.0`, 2024-07-18) replaced the old closure-based `EventLoop::run(move |event, _| …)` with the `ApplicationHandler` trait — this is the structure quoted in [How it works](#the-winit-backend-an-applicationhandler). Slint had to track it. Because winit forbids creating more than one `EventLoop` per process and `run` historically consumed it, Slint uses `run_app_on_demand` and **stashes the loop for reuse**:

```rust
// internal/backends/winit/event_loop.rs  (EventLoopState::run, non-wasm/non-iOS)
use winit::platform::run_on_demand::EventLoopExtRunOnDemand as _;
winit_loop.run_app_on_demand(&mut self)
    .map_err(|e| format!("Error running winit event loop: {e}"))?;
// Keep the EventLoop instance alive and re-use it in future invocations of run_event_loop().
// Winit does not support creating multiple instances of the event loop.
self.shared_backend_data.not_running_event_loop.replace(Some(winit_loop));
```

This is what lets `slint::run_event_loop()` be called more than once. There is also a non-blocking `process_events(timeout)` path (`Platform::process_events`) built on winit's `pump_app_events`, for embedding Slint in a host loop.

**Timers/wakeups & next-sleep sizing.** In `about_to_wait`, after coalescing, Slint asks core for the next deadline and sets winit's control flow accordingly:

```rust
// internal/backends/winit/event_loop.rs  (about_to_wait, abridged)
if event_loop.control_flow() == ControlFlow::Wait
    && let Some(next_timer) = corelib::platform::duration_until_next_timer_update()
{
    event_loop.set_control_flow(ControlFlow::wait_duration(next_timer));
}
```

**User-event injection from other threads.** `Platform::new_event_loop_proxy` returns a `Proxy` wrapping winit's thread-safe `EventLoopProxy<SlintEvent>`. `invoke_from_event_loop(Box<dyn FnOnce + Send>)` sends `CustomEvent::UserEvent`; `quit_event_loop` sends `CustomEvent::Exit(generation)`. The _generation_ counter (an `AtomicUsize` bumped per `run_event_loop`) guards against a stale quit from a previous loop run terminating a fresh one. A deliberate re-entrancy note explains why user events flip winit into `Poll`:

> To prevent re-entrancy issues that might happen by getting the application event processed on top of the current stack, set winit in Poll mode so that events are queued and process on top of a clean stack during a requested animation frame a few moments later.

**Frame pacing & vsync.** A per-window `FrameThrottle` ([`frame_throttle.rs`][throttle-rs]) chooses the [vsync][frame-callback-vsync] source per platform:

| Platform              | `FrameThrottle` impl         | vsync source                                                       |
| --------------------- | ---------------------------- | ------------------------------------------------------------------ |
| Wayland               | `WinitBasedFrameThrottle`    | winit `request_redraw` → Wayland `wl_surface` frame callbacks      |
| macOS / iOS           | `CADisplayLinkFrameThrottle` | `CADisplayLink` on the main `NSRunLoop` (`NSRunLoopCommonModes`)   |
| X11 / Windows / other | `TimerBasedFrameThrottle`    | a Slint `Timer` ticking at the monitor's `refresh_rate_millihertz` |

The Apple path is notable — it calls `adapter.draw()` _directly_ from the `CADisplayLink` tick, because "during modal tracking loops (e.g. context menus) winit's event loop is blocked and would never process `RedrawRequested`" ([`apple_display_link.rs`][apple-link-rs]). This is Slint's workaround for the [Win32-style modal loop][win32-modal-resize-loop] equivalent on macOS.

**Redraw coalescing.** `request_redraw()` is idempotent (`if !self.pending_redraw.replace(true)`), and high-frequency `CursorMoved` events are bunched into a single `pending_mouse_move` flushed when any other event arrives — added to fix performance issues (`#9038`, `#10912`).

**The linuxkms loop, verbatim:**

```rust
// internal/backends/linuxkms/calloop_backend.rs  (run_event_loop, core loop)
while !quit_loop.load(std::sync::atomic::Ordering::Acquire) {
    i_slint_core::platform::update_timers_and_animations();
    // Only after updating the animation tick, invoke callbacks from invoke_from_event_loop() ...
    for callback in callbacks_to_invoke_per_iteration.take().into_iter() { callback(); }
    if let Some(adapter) = self.window.borrow().as_ref() {
        adapter.clone().render_if_needed(mouse_position_property.as_ref())?;
    };
    let next_timeout = i_slint_core::platform::duration_until_next_timer_update();
    event_loop.dispatch(next_timeout, &mut loop_data).map_err(|e| format!("Error dispatch events: {e}"))?;
}
```

DRM presentation waits on a page-flip event: `DrmOutput::present` issues `page_flip(..., PageFlipFlags::EVENT, ...)` and `wait_for_page_flip` blocks on `drm_device.receive_events()` for a `drm::control::Event::PageFlip` ([`drmoutput.rs`][drmoutput-rs]) — a [completion-style][readiness-vs-completion] vsync rather than a readiness fd. This overlaps the event-loop concerns surveyed in [async-io][async-io].

---

## 3. Input

**Key model — text-first, not scancode.** Slint's `WindowEvent::KeyPressed { text: SharedString }` carries the produced _text_, not a [scancode/keysym/virtual-key][scancode-keysym-virtualkey]. The winit backend translates `winit::keyboard::Key` (a keysym-level logical key) to a `SharedString`: `Key::Character(str)` becomes the text directly; named keys (Enter, Tab, arrows, F-keys, modifiers) map to private-use Unicode code points via the shared `for_each_keys!` macro table ([`event_loop.rs`][event-loop-rs] `to_slint_key`). Modifiers are not delivered as separate flags on the event; the core derives modifier state from the key text stream.

**Layout & the xkb state machine — who owns it.** On the winit path winit (and thus the OS / its own xkbcommon usage) owns layout. On the `linuxkms` path Slint owns xkbcommon directly ([`calloop_backend/input.rs`][kms-input-rs]):

```rust
// internal/backends/linuxkms/calloop_backend/input.rs  (Keyboard event)
let key_code = xkb::Keycode::new(key_event.key() + 8);   // evdev -> xkb keycode offset
// keystate created lazily from default RMLVO:
let xkb_context = xkb::Context::new(xkb::CONTEXT_NO_FLAGS);
let keymap = xkb::Keymap::new_from_names(&xkb_context, "", "", "", "", None, 0)
    .expect("Error compiling keymap");
xkb::State::new(&keymap)
```

> [!WARNING]
> The KMS backend compiles the keymap from **empty RMLVO names** — i.e. the libxkbcommon compile-time default layout (typically `us`), _not_ the user's configured console/X layout. There is no XKB-config or per-seat layout discovery on the bare KMS path. The `+8` is the standard evdev→XKB keycode offset.

**Key repeat.** On the winit path, repeat is the platform's: a repeated press arrives as a normal `KeyboardInput` and Slint maps it to `KeyPressRepeated` only where the core decides. On Wayland, where the protocol mandates the _client_ synthesize repeat from `wl_keyboard.repeat_info`, winit does that synthesis; Slint inherits it. The KMS backend does **not** synthesize key repeat at all (libinput delivers discrete press/release; there is no repeat timer in `input.rs`), which is a gap relative to the winit path.

**Dead keys / compose & IME / text input.** Handled entirely through winit's `WindowEvent::Ime`. Slint maps it to two [pre-edit/composition][pre-edit-composition] event types:

```rust
// internal/backends/winit/event_loop.rs
WindowEvent::Ime(Ime::Preedit(string, sel)) => /* KeyEventType::UpdateComposition { preedit_text, preedit_selection } */
WindowEvent::Ime(Ime::Commit(string))       => /* KeyEventType::CommitComposition { text } */
```

Composition is therefore cleanly separated from key events: `KeyPressed`/`KeyReleased` vs `UpdateComposition`/`CommitComposition` (`KeyEventType`, [`input.rs`][core-input-rs]). The reverse direction — telling the IME where to draw the candidate window — goes through `WindowAdapterInternal::input_method_request`, which calls winit's `set_ime_allowed`, `set_ime_purpose` (Password vs Normal), and **`set_ime_cursor_area`** for [candidate-window positioning][pre-edit-composition] ([`winitwindowadapter.rs`][winit-window-rs]). The concrete protocol underneath is winit's: [`zwp_text_input_v3`][text-input-v3] on Wayland, [TSF/IMM32] on Windows, [`NSTextInputClient`][ns-text-input] on macOS, XIM on X11. Slint never touches these directly.

> [!NOTE]
> On Windows there is an extra `key_without_modifiers()` dance (`KeyEventExtModifierSupplement`) to disambiguate `Ctrl+Alt` from AltGr — see the comment citing [winit `#2945`][winit-2945]. Synthetic key events sent on focus-gain are filtered to modifiers only.

**Pointer.** Absolute by default (`PointerMoved { position }`); the KMS backend produces both relative (`PointerEvent::Motion`, integrated and clamped to the screen) and absolute (`MotionAbsolute`, transformed by screen size). High-resolution scroll: `MouseScrollDelta::LineDelta` is multiplied by `60.` to get logical pixels; `PixelDelta` is converted via the scale factor ([`event_loop.rs`][event-loop-rs] `MouseWheel`). macOS trackpad **`PinchGesture`/`RotationGesture`** are forwarded (with a comment that winit's pinch carries no position, so the last cursor position is used). There is no relative/raw pointer mode, pointer capture, confinement, or pointer-lock surfaced through the Slint API.

**Touch & gestures.** `WindowEvent::Touch` → `process_touch_input(finger_id, position, phase)`. winit's `u64` touch id is narrowed to `i32` on all platforms except iOS, where a `TouchFingerIdAllocator` maps the `UITouch` pointer address to a small id ([`event_loop.rs`][event-loop-rs]).

**Cursor handling.** Client-side: `set_mouse_cursor` maps Slint's `MouseCursor` enum to winit `CursorIcon` and calls `set_cursor` / `set_cursor_visible` — winit then uses the platform's named cursors (on Wayland, `cursor_shape_v1` where available). No custom image cursor API is exposed via the adapter.

---

## 4. Wayland specifics

> [!IMPORTANT]
> All Wayland behavior on the desktop backend is winit's; Slint does not speak Wayland protocols directly. The relevant decisions are (a) which winit features Slint enables and (b) the small set of Wayland-specific workarounds Slint adds around winit.

**Decorations — own-drawn CSD.** Slint enables winit's [`wayland-csd-adwaita`][csd-adwaita] feature ([`Cargo.toml`][winit-cargo]), so under a compositor with no server-side decorations winit draws Adwaita-style [client-side decorations][csd-vs-ssd] itself (via `sctk-adwaita` + `tiny-skia`), rather than using [libdecor]. Where the compositor offers `xdg-decoration` server-side, winit uses that. Slint additionally implements **its own resize-border hit-testing** for borderless/CSD windows in [`drag_resize_window.rs`][drag-resize-rs] (`handle_cursor_move_for_resize` + `drag_resize_window`), used for Slint's `resize-border-width` property when the window is undecorated.

**Protocol coverage beyond core + xdg-shell.** Inherited from winit `0.30`: `xdg-shell`, `xdg-decoration`, `fractional-scale-v1` + `viewporter` (fractional scaling), `cursor-shape-v1`, `text-input-v3`, plus winit's own bits. Slint adds, _outside_ winit, an [XDG Desktop Portal] watcher ([`xdg_desktop_settings.rs`][xdg-rs]) over zbus/D-Bus that reads `org.freedesktop.appearance color-scheme` and `accent-color` and `org.gnome.desktop.interface cursor-blink*`, pushing dark/light theme and accent color (and cursor blink interval) into the `SlintContext` and onto every mapped window. This is how CSDs and the theme stay in sync with the desktop.

> [!NOTE]
> No [`layer-shell`][layer-shell], [`xdg-activation`][xdg-activation], or [`idle-inhibit`][idle-inhibit] support — Slint targets ordinary application toplevels via winit, not panels/overlays.

**Compositor-specific workarounds.** The `xdg_app_id` is pushed via winit's `WindowAttributesExtWayland::with_name` so compositors group/identify the app ([`ensure_window`][winit-window-rs]). Under **WSL** Slint forces the X11 winit backend because "Under WSL, the compositor sometimes crashes ... when running under WSL, try to connect to X11 instead" ([`lib.rs`][winit-lib-rs], detecting `/run/WSL` or the binfmt WSLInterop file). The Windows-only "occluded on zero size" and the X11 cached-`inner_size` workarounds are also present.

---

## 5. DPI & scaling

**Model — logical is the API native unit; physical is winit's.** Slint stores window size as `PhysicalSize` (`size: Cell<PhysicalSize>`) but every event Slint dispatches is logical: `resize_event` converts `physical_size.to_logical(scale_factor)` before `WindowEvent::Resized`, and pointer positions are `to_logical(scale_factor)` ([`winitwindowadapter.rs`][winit-window-rs], [`event_loop.rs`][event-loop-rs]). The [scale factor][scale-factor] flows in as `WindowEvent::ScaleFactorChanged`.

**When the app learns the scale.** At window creation, _before_ the window is shown: `ensure_window` dispatches `ScaleFactorChanged` immediately after `renderer.resume` (quoted in [§1](#1-window-creation-lifecycle)). The `platform.rs` doc on `ScaleFactorChanged` mandates this:

> Platform implementations should dispatch this event also right after the initial window creation, to set the initial scale factor the windowing system provided for the window.

This dodges the [created-at-wrong-scale-then-rescaled][logical-vs-physical-coords] problem for the common case; later changes (monitor migration, settings change) arrive as further `ScaleFactorChanged` events from winit's `WindowEvent::ScaleFactorChanged`, which Slint forwards verbatim (unless `SLINT_SCALE_FACTOR` overrides it).

**Per-platform.** All inherited from winit `0.30`: per-monitor-v2 DPI awareness on Windows (the `WM_DPICHANGED` dance is winit's), `fractional-scale-v1` on Wayland, backing-scale on macOS. Slint's only DPI-specific code is (a) the `SLINT_SCALE_FACTOR` env override, which when set _suppresses_ winit's `ScaleFactorChanged` and applies the factor to attribute sizes (`apply_scale_factor_to_logical_sizes_in_attributes`), and (b) sizing min/max constraints as physical when the window exists but logical when it doesn't, "so that we can apply the real window scale factor later when it's known."

**Mixed-DPI multi-monitor.** Window migration between monitors fires winit `ScaleFactorChanged`, forwarded as above; there is a `// TODO: send a resize event or try to keep the logical size the same.` admitting the resize coupling is incomplete. On the KMS backend scaling is whatever the renderer reports for the single output; there is no multi-monitor.

---

## 6. Multi-window & popups

**Multi-window.** Fully supported on the winit backend: `SharedBackendData.active_windows` is a `HashMap<WindowId, Weak<WinitWindowAdapter>>`, and `create_window_adapter` can be called repeatedly. The KMS backend is **single-window only** (one `FullscreenWindowAdapter`); the Qt and Android backends have their own constraints.

**Popups — embedded, not native (winit backend).** The core models a popup as either a top-level OS window or an embedded child ([`window.rs`][window-rs]):

```rust
// internal/core/window.rs
pub enum PopupWindowLocation {
    /// The popup is rendered in its own top-level window that is know to the windowing system.
    TopLevel(Rc<dyn WindowAdapter>),
    /// The popup is rendered as an embedded child window at the given position.
    ChildWindow(LogicalPoint),
}
```

The choice hinges on `WindowAdapterInternal::create_child_window_adapter`, which **defaults to `None`** — and the winit `WinitWindowAdapter` does not override it. So on the winit backend, tooltips/menus/`PopupWindow`s are drawn _inside_ the parent surface ([`ChildWindow`]), not as separate [`xdg_popup`][override-redirect-vs-xdg-popup-grab] surfaces. The code comment in `activation_changed` confirms: "We don't render popups as separate windows yet, so treat focus to be the same as being active."

**Native menus where the platform has them.** When the `muda` feature is on, the winit backend overrides `supports_native_menu_bar()`/`setup_menubar`/`show_native_popup_menu` to use [muda] for native macOS/Windows menu bars and context menus. The Qt backend renders native `PopupWindow`s. Modal dialogs (`Dialog`) are layout/focus constructs in core, not OS-modal windows, on the winit path. Parent/child stacking uses `WindowLevel::AlwaysOnTop` for always-on-top; there is no general window-group API.

---

## 7. Threading

**Window/loop creation thread.** On Linux and Windows, Slint relaxes winit's usual main-thread rule by calling `EventLoopBuilderExt*::with_any_thread(true)` for Wayland, X11, and Windows ([`lib.rs`][winit-lib-rs] `SharedBackendData::new`):

```rust
// internal/backends/winit/lib.rs  (SharedBackendData::new, abridged)
#[cfg(feature = "wayland")] { use winit::platform::wayland::EventLoopBuilderExtWayland; builder.with_any_thread(true); }
#[cfg(feature = "x11")]     { use winit::platform::x11::EventLoopBuilderExtX11;     builder.with_any_thread(true); }
// windows:
use winit::platform::windows::EventLoopBuilderExtWindows; builder.with_any_thread(true);
```

**macOS is the hard constraint.** There is no `with_any_thread` for macOS — AppKit requires the event loop and all UI on the main thread, the usual culprit. The `CADisplayLink` throttle asserts it: `MainThreadMarker::new().expect("frame throttle must be created on main thread")`. So the portable contract is: **create windows and run the loop on the same thread you started on; on macOS that must be the main thread.**

**Which thread receives events.** Always the loop thread — winit's `ApplicationHandler` callbacks all run there, and the KMS loop dispatches on its own thread. Cross-thread work re-enters via `invoke_from_event_loop` (winit `EventLoopProxy`, which is `Send + Sync`), processed back on the loop thread.

**Rendering off the event thread.** Not supported through the public model — `draw()`/`render()` run on the loop thread (and on Apple, also from the `CADisplayLink` tick on the main run loop). The core's reactive state (`Rc`/`RefCell`, not `Arc`/`Mutex`) is single-threaded by construction.

---

## 8. Clipboard & DnD

**Clipboard.** Implemented via the [copypasta] crate ([`clipboard.rs`][clipboard-rs]). Slint exposes two clipboards matching the [X11 selection model][x11-selections] — `DefaultClipboard` (the Ctrl+C/Ctrl+V clipboard; X11 _secondary_) and `SelectionClipboard` (copy-on-select; X11 _primary_) — defined in `platform.rs`:

```rust
// internal/backends/winit/clipboard.rs  (Wayland branch)
#[cfg(feature = "wayland")]
if let RawDisplayHandle::Wayland(wayland) = _display_handle.as_raw() {
    let clipboard = unsafe { copypasta::wayland_clipboard::create_clipboards_from_external(wayland.display.as_ptr()) };
    return (Box::new(clipboard.1), Box::new(clipboard.0));
};
```

The Wayland clipboard is created from the raw `wl_display` ([Wayland data-device selection model][wl-data-device]); X11 uses `X11ClipboardContext<Primary>`/`<Clipboard>`; macOS/Windows use copypasta's default. iOS exposes only a single general pasteboard (selection clipboard is a no-op). The KMS backend has only an _internal_ in-process clipboard (two `RefCell<Option<String>>`), since there is no display server.

> [!NOTE]
> Only **plain text** clipboard is supported through the Slint API (`set_clipboard_text`/`clipboard_text`). There is no MIME/format negotiation, no rich-content or image clipboard, and **no drag-and-drop** at the windowing layer in either backend studied. Win32 delayed rendering and X11 `INCR` are copypasta's concern, not exposed.

---

## 9. Escape hatches

Slint is unusually generous here, because its backend is itself winit:

- **The whole `winit::window::Window`.** The `WinitWindowAccessor` trait ([`lib.rs`][winit-lib-rs]) gives `has_winit_window()`, `with_winit_window(|w| …)`, and `on_winit_window_event(filter)` — apps can call any winit API directly. Slint even `pub use winit;` so versions match.
- **`CustomApplicationHandler`.** A trait mirroring winit's `ApplicationHandler` whose methods run _before_ Slint's, returning `EventResult::PreventDefault` to suppress Slint's handling ([`lib.rs`][winit-lib-rs]). This is a raw-event passthrough / message-pump hook.
- **`with_window_attributes_hook`.** A closure on `BackendBuilder` to mutate `WindowAttributes` before each window is created (the docs example uses `with_content_protected(true)`).
- **`with_event_loop_builder`.** Supply a custom winit `EventLoopBuilder<SlintEvent>`.
- **`raw-window-handle` 0.6** getters on every `WindowAdapter` (see [§1](#1-window-creation-lifecycle)).
- **KMS-specific:** `with_libinput_event_hook` and `SLINT_KMS_ROTATION`.

That the abstraction exposes the entire underlying `Window` and an `ApplicationHandler` clone is itself a finding: the `WindowAdapter` surface is known to be insufficient for advanced windowing, so Slint punts to winit rather than growing the trait.

---

## 10. History, redesigns & known regrets

- **Software-renderer + `Platform` API for bare metal — `1.0.0` (2023-04-03).** The `platform` module and `WindowAdapter` trait shipped with 1.0, designed so Slint can run on `no_std`/MCUs with a custom backend ("Added the `platform` module providing API to use slint on bare metal with a software renderer").
- **`WindowAdapter` de-genericized — `1.1.0` (2023-06-26).** "Experimental: the `slint::platform::WindowAdapter` no longer takes a template parameter and has a different constructor signature" — the early generic design was walked back to a plain `dyn WindowAdapter`.
- **Why winit _plus_ an abstraction.** [inference] The pre-1.0 backends were named `backend-gl-*`; the "backend-gl-\*" Rust crate features were renamed as the renderer/backend split solidified. Keeping Slint's _own_ trait above winit lets the Qt, Android, KMS, and `no_std` software backends coexist with the winit one behind one interface — winit alone could not serve the compositor-less and Qt cases.
- **The bare `linuxkms` backend — `1.2.0` (2023-09-04).** "Added support for a new experimental backend that renders fullscreen on Linux using KMS (`backend-linuxkms`)." It later grew rotation (`1.3.0`), `noseat` mode, software rendering, absolute-motion pointer events, frame throttling, libinput event hooks, and WGPU rendering (`1.16.0`, 2026-04-16). It exists for kiosk/embedded targets with no compositor — the antithesis of the winit path.
- **winit `0.30` / `ApplicationHandler` migration — `1.7.0` (2024-07-18).** "Winit backend: upgraded to winit 0.30, accesskit 0.16, glutin." This is the redesign that forced the `ApplicationHandler` + `run_app_on_demand` structure and the `WinitWindowOrNone` lazy-creation dance.
- **Keep-the-loop-running regret — issue [#1499]** ("_Keep the eventloop running when windows are closed_"), resolved by [PR #4315]. The original "quit on last window closed" behavior is now `#[deprecated]` in `platform.rs` ("`i-slint-core` takes care of closing behavior ... This is being phased out, see #1499"), with `event_loop_generation` added to disambiguate stale quits.
- **winit is now the default everywhere — `1.16.0` (2026-04-16).** "The winit backend is now the default on all platforms. (Qt is no longer the default on Linux)" — a strategic bet on winit over the Qt backend.
- **Long-standing winit bugs Slint works around in-tree:** `#2334` (no window-state event for fullscreen/maximize — Slint synthesizes one), `#4371` (macOS focus event), `#2945` (Windows AltGr), `#2990` (non-resizable windows keep a maximize button), `#3280` (Ubuntu 20.04 raising on `set_window_level`), `#8795`/`#8793` (graphics resource/menubar translucency).

---

## Strengths

- **Clean, replaceable backend seam.** One `Platform`/`WindowAdapter` trait serves winit desktop/mobile/web, bare KMS, Qt, and `no_std` software rendering — a genuinely portable contract.
- **Logical-coordinate discipline.** Every event is logical; scale is learned before first paint, sidestepping the most common DPI bug.
- **Generous escape hatches.** Full `winit::window::Window` access, a `CustomApplicationHandler` passthrough, attribute hooks, and `raw-window-handle` — apps are rarely boxed in.
- **Per-platform vsync done right.** `CADisplayLink` on Apple (even during modal loops), Wayland frame callbacks, monitor-rate timer elsewhere; DRM page-flip on KMS.
- **A real compositor-less path.** The `linuxkms` backend is a self-contained DRM/libinput/xkbcommon stack for kiosks and embedded.
- **Reuses the ecosystem.** winit/glutin/softbuffer/Skia carry the per-OS windowing burden; Slint tracks their fixes for free.

## Weaknesses

- **Double abstraction = double the leaks.** Bound by winit's model and bugs; the long workaround list in [§10](#10-history-redesigns-known-regrets) is the tax. The `WindowAdapter` trait is admittedly insufficient (popups embedded, escape hatches everywhere).
- **Popups are not real OS surfaces (winit backend).** No `xdg_popup` grab semantics, no override-redirect — tooltips/menus render inside the parent, with focus conflated with activation.
- **Text-only clipboard, no DnD.** No MIME negotiation, images, or drag-and-drop at the windowing layer.
- **KMS input gaps.** Default-only xkb keymap (ignores configured layout), no key-repeat synthesis, single fullscreen window.
- **Thin pointer model.** No raw/relative pointer mode, capture, confinement, or pointer-lock through the Slint API.
- **macOS main-thread rigidity.** Unavoidable, but the `CADisplayLink`-drives-`draw()` workaround shows how brittle the modal-loop interaction is.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                   |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Own `Platform`/`WindowAdapter` trait above winit                  | One contract spanning winit, Qt, Android, KMS, and `no_std` software backends             | Two stacked abstractions; the upper one leaks (popups, handle access) into winit below      |
| Logical coordinates as the API native unit                        | Identical event semantics across backends; DPI-correct by default                         | Backend must convert every coordinate; physical size cached separately to fight X11 jitter  |
| Lazy `WinitWindowOrNone` (window-or-attributes)                   | winit `0.30` only creates windows inside an active loop; learn scale before first paint   | Every window setter is written twice; replay logic and edge cases (Wayland hide-destroys)   |
| Delegate the loop to winit (`run_app_on_demand`), own it for KMS  | Reuse native pumps (`CFRunLoop`/Win32/Wayland fd); own loop only where there is no server | Slint can't block in callbacks; must stash the single winit loop for reuse; generation hack |
| Text-first key events; xkb owned by winit (desktop) / Slint (KMS) | Simple cross-backend key vocabulary; bare-metal needs its own keymap                      | KMS uses the default layout only and synthesizes no repeat                                  |
| Per-platform `FrameThrottle` (CADisplayLink/Wayland/timer)        | Correct vsync source per OS; redraw during macOS modal loops                              | Three code paths; timer path on X11/Windows is approximate                                  |
| Popups rendered embedded, native menus only via `muda`/Qt         | Simpler; avoids `xdg_popup`/grab complexity in the winit backend                          | No true menu grab semantics; focus == activation; per-monitor popup placement limited       |
| Expose the whole `winit::window::Window` as an escape hatch       | Apps reach any native feature the trait omits                                             | Couples apps to a non-semver-stable winit version; admits the abstraction is incomplete     |

---

## Verdict: what a new framework should steal / avoid

**Steal:**

- The **`Platform` + `WindowAdapter` capability-trait split** with rich default methods — it is the cleanest way seen in this survey to let one reactive core target a compositor (winit), a bare display (KMS), a foreign toolkit (Qt), and bare metal (`no_std`) behind one interface. It mirrors Sparkles' own [Design by Introspection][dbi] ethos.
- **Learn the scale factor before first paint** and make logical coordinates the API unit — the dispatch-`ScaleFactorChanged`-on-creation rule is a concrete, copyable cure for the created-at-wrong-scale bug.
- **A per-platform `FrameThrottle` abstraction** that picks `CADisplayLink`/frame-callback/timer/page-flip — and the lesson that on macOS you must drive paint from the display link to survive modal tracking loops.
- **First-class escape hatches** (`with_winit_window`, `CustomApplicationHandler`, attribute hooks) so the abstraction's gaps are not dead ends.

**Avoid:**

- **Conflating popups with in-window children** if you need real menu/tooltip grab semantics — design `xdg_popup`/override-redirect popups in from the start, not as a later `create_child_window_adapter` override.
- **Shipping a bare backend with the default-only xkb keymap and no key repeat** — if you do compositor-less input, read the seat's configured layout and synthesize repeat.
- **Letting the upper abstraction lag the lower one's redesigns** — the winit `0.30` `ApplicationHandler` migration shows the cost of being a second layer; budget for tracking the layer you sit on.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Does winit `0.30` use [libdecor] at all, or always `sctk-adwaita`?** Slint only sets `wayland-csd-adwaita`; the actual libdecor-vs-own-drawn decision is winit's. Answer lives in winit's `src/platform_impl/linux/wayland/` and its `Cargo.toml` feature graph.
- **Exact set of Wayland protocols winit `0.30.2` binds** (e.g. whether `xdg-activation`/`single-pixel-buffer` are negotiated). Lives in winit `0.30`'s Wayland backend and its `wayland-protocols` dependency, not in the Slint tree.
- **Whether the KMS backend ever supports multi-output / per-screen scale.** The code has `// This could be per-screen, once we support multiple outputs` ([`calloop_backend.rs`][calloop-rs]); status would be in [slint-ui/slint] issues tagged `linuxkms`.
- **DnD roadmap.** No drag-and-drop anywhere in core/backends studied; whether it is planned belongs in the Slint issue tracker / roadmap.

---

## Sources

- [slint-ui/slint] — repository (all quoted file paths at commit [`24318cebc2`][commit])
- [`internal/core/platform.rs`][platform-rs] — the `Platform` trait, `WindowEvent`, `EventLoopProxy`, timer hooks
- [`internal/core/window.rs`][window-rs] — `WindowAdapter`/`WindowAdapterInternal`, `WindowProperties`, `PopupWindowLocation`, `InputMethodRequest`
- [`internal/backends/winit/event_loop.rs`][event-loop-rs] — the `ApplicationHandler` impl, input translation, IME, `run_app_on_demand`
- [`internal/backends/winit/winitwindowadapter.rs`][winit-window-rs] — `WinitWindowOrNone`, `ensure_window`, scale handling, raw-window-handle, IME request
- [`internal/backends/winit/lib.rs`][winit-lib-rs] — `Backend`/`SharedBackendData`, `Platform` impl, clipboard, `WinitWindowAccessor`, `CustomApplicationHandler`, `with_any_thread`
- [`internal/backends/winit/frame_throttle.rs`][throttle-rs] / [`apple_display_link.rs`][apple-link-rs] — vsync sources
- [`internal/backends/winit/clipboard.rs`][clipboard-rs] / [`xdg_desktop_settings.rs`][xdg-rs] / [`drag_resize_window.rs`][drag-resize-rs] — clipboard, portal theme watcher, CSD resize
- [`internal/backends/linuxkms/calloop_backend.rs`][calloop-rs] / [`calloop_backend/input.rs`][kms-input-rs] / [`drmoutput.rs`][drmoutput-rs] — bare DRM/libinput/xkbcommon backend
- [CHANGELOG.md][changelog] — version timeline; issues [#1499] and [PR #4315]
- Concepts cross-references: [./concepts.md](./concepts.md); sibling surveys [ui-layout][ui-layout] and [async-io][async-io]

<!-- References -->

[slint-ui/slint]: https://github.com/slint-ui/slint
[commit]: https://github.com/slint-ui/slint/commit/24318cebc2b3feed4f7187e237915f52715ce285
[slint-docs]: https://slint.dev/docs
[platform-docs]: https://docs.rs/i-slint-core/latest/i_slint_core/platform/trait.Platform.html
[changelog]: https://github.com/slint-ui/slint/blob/fca8dcbacf79ce75c6e353fdfff58849f3566c89/CHANGELOG.md
[#1499]: https://github.com/slint-ui/slint/issues/1499
[PR #4315]: https://github.com/slint-ui/slint/pull/4315
[winit-2945]: https://github.com/rust-windowing/winit/issues/2945
[platform-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/platform.rs
[window-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/window.rs
[core-input-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/core/input.rs
[event-loop-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/event_loop.rs
[winit-window-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/winitwindowadapter.rs
[winit-lib-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/lib.rs
[throttle-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/frame_throttle.rs
[apple-link-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/frame_throttle/apple_display_link.rs
[clipboard-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/clipboard.rs
[xdg-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/xdg_desktop_settings.rs
[drag-resize-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/drag_resize_window.rs
[winit-cargo]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit/Cargo.toml
[calloop-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/linuxkms/calloop_backend.rs
[kms-input-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/linuxkms/calloop_backend/input.rs
[drmoutput-rs]: https://github.com/slint-ui/slint/blob/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/linuxkms/drmoutput.rs
[winit-dir]: https://github.com/slint-ui/slint/tree/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/winit
[linuxkms-dir]: https://github.com/slint-ui/slint/tree/24318cebc2b3feed4f7187e237915f52715ce285/internal/backends/linuxkms
[winit]: https://github.com/rust-windowing/winit
[glutin]: https://github.com/rust-windowing/glutin
[softbuffer]: https://github.com/rust-windowing/softbuffer
[Skia]: https://skia.org/
[calloop]: https://github.com/Smithay/calloop
[copypasta]: https://github.com/alacritty/copypasta
[muda]: https://github.com/tauri-apps/muda
[raw-window-handle]: https://github.com/rust-windowing/raw-window-handle
[DRM]: https://www.kernel.org/doc/html/latest/gpu/drm-kms.html
[libinput]: https://wayland.freedesktop.org/libinput/doc/latest/
[libseat]: https://git.sr.ht/~kennylevinsen/seatd
[libdecor]: https://gitlab.freedesktop.org/libdecor/libdecor
[XDG Desktop Portal]: https://flatpak.github.io/xdg-desktop-portal/docs/
[csd-adwaita]: https://docs.rs/winit/0.30.2/winit/index.html
[layer-shell]: https://wayland.app/protocols/wlr-layer-shell-unstable-v1
[xdg-activation]: https://wayland.app/protocols/xdg-activation-v1
[idle-inhibit]: https://wayland.app/protocols/idle-inhibit-unstable-v1
[text-input-v3]: https://wayland.app/protocols/text-input-unstable-v3
[wl-data-device]: https://wayland.app/protocols/wayland#wl_data_device
[TSF/IMM32]: https://web.archive.org/web/20221114201716/https://learn.microsoft.com/en-us/windows/win32/tsf/text-services-framework
[ns-text-input]: https://web.archive.org/web/20260115025403/https://developer.apple.com/documentation/appkit/nstextinputclient
[x11-selections]: https://tronche.com/gui/x/icccm/sec-2.html
[dbi]: ../../guidelines/design-by-introspection-00-intro.md
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
[escape]: #9-escape-hatches
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
[readiness-vs-completion]: ./concepts.md#readiness-vs-completion-windowing
[client-vs-server-decoration]: ./concepts.md#client-vs-server-decoration
