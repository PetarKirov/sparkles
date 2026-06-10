# Winit (Rust)

The Rust ecosystem's dominant pure windowing abstraction: a thin, opinionated layer that owns the platform event loop, hands you a trait-based [`ApplicationHandler`][app-handler] callback surface, and exposes the raw native handle through [`raw-window-handle`][rwh] so a GPU/software renderer (`wgpu`, `glutin`, `softbuffer`) can take over presentation. Winit draws nothing itself.

| Field                 | Value                                                                                                                                                                                              |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit        | `0.31.0-beta.2`, commit [`81b27297`][commit] (June 5, 2026)                                                                                                                                        |
| Language              | Rust (edition 2024; MSRV `1.85`)                                                                                                                                                                   |
| License               | Apache-2.0                                                                                                                                                                                         |
| Repository            | [rust-windowing/winit][repo]                                                                                                                                                                       |
| Documentation         | [docs.rs/winit][docsrs] / [`FEATURES.md`][features]                                                                                                                                                |
| Category              | Windowing library (window lifecycle + event loop + input; no rendering, no widgets)                                                                                                                |
| Platforms covered     | Wayland, X11, Win32, macOS/AppKit, iOS/UIKit, Android, Web (wasm), Orbital (Redox)                                                                                                                 |
| Loop ownership        | **Callback-driven** — winit owns the native loop and calls into your `ApplicationHandler`                                                                                                          |
| Repo paths (platform) | `winit-wayland/`, `winit-x11/`, `winit-win32/`, `winit-appkit/`, `winit-uikit/`, `winit-android/`, `winit-web/`, `winit-orbital/`; shared core in `winit-core/`, shared OS glue in `winit-common/` |

> [!NOTE]
> **The studied tree is mid-refactor.** As of `0.31.0-beta.2` winit is no longer a single crate with a `src/platform_impl/{linux,windows,macos}/` subtree (the layout described in pre-0.30 docs). Each backend is now its own crate (`winit-wayland`, `winit-x11`, `winit-win32`, `winit-appkit`, …), the cross-platform contract lives in `winit-core`, and the façade crate `winit` re-exports one backend per `cfg` via [`winit/src/platform_impl/mod.rs`][platform-impl] (`#[cfg(windows_platform)] pub(crate) use winit_win32 as platform;`). All file paths below are at the pinned commit.

---

## Overview

### What it solves

A native renderer (Vulkan, Metal, OpenGL, software) needs three things from the OS that have nothing to do with drawing: a **window/surface** to draw into, a **stream of input/lifecycle events**, and a **handle** the graphics API can bind to. Each OS supplies these through a different, deeply opinionated API — Wayland's asynchronous protocol over a socket, X11's request/reply connection, the Win32 message pump, AppKit's `NSApplication`/`CFRunLoop`, UIKit, the Android `NativeActivity` lifecycle, and the browser's animation-frame loop. Winit papers over all of them behind one trait and one event enum, and then gets out of the way.

The crate's own top-level doc states the boundary plainly:

> Winit is a cross-platform window creation and event loop management library.

— [`winit/src/lib.rs`][lib-rs] (module doc, line 1)

And [`FEATURES.md`][features] draws the rendering line explicitly:

> Winit **_does not_** directly expose functionality for drawing inside windows or creating native menus, but **_does_** commit to providing APIs that higher-level crates can use to implement that functionality.

This makes winit the windowing-and-input substrate underneath most of the Rust GUI/graphics stack (`wgpu` examples, `egui`'s `eframe`, `iced`, `bevy`, `glutin`). It occupies the niche [SDL] and [GLFW] hold in C — but unlike those, it is callback-first and integrates raw-window-handle as a first-class concept rather than exposing platform handle getters ad hoc.

### Design philosophy

- **Callback-driven, not poll-driven.** Winit deliberately abandoned the `for event in event_loop.poll_events()` iterator model because it cannot be implemented correctly where the OS owns the loop (Web's animation-frame callback, iOS's `UIApplicationMain`, AppKit's `CFRunLoop`). See [the loop-ownership rationale](#2-event-loop) and the verbatim quote there.
- **Abstract the intersection, expose the rest through extension traits.** [`FEATURES.md`][features] formalizes a tiering: _Core_ features are cross-platform and maintained by the core team; _Platform_ features live behind `*ExtWindows`/`*ExtWayland`/`*ExtMacOS` traits and are owned by whoever contributed them. The common API is the intersection of what every platform can do; everything else leaks through a named escape hatch (see [§9](#9-escape-hatches)).
- **Physical coordinates are the native unit.** The API speaks `PhysicalSize`/`PhysicalPosition` (device pixels) by default and exposes a [`scale_factor`][scale-factor] so the app converts to/from logical units itself — the opposite of AppKit/GTK, which default to logical points. See [§5](#5-dpi--scaling).
- **Presentation is someone else's job.** Winit gives you a [`RawWindowHandle`][rwh] and a `RawDisplayHandle`; it never creates a swapchain, GL context, or software buffer. The only presentation-adjacent API is [`pre_present_notify`][lib-rs] (a Wayland frame-callback hook). See [§1](#1-window-creation--lifecycle).
- **One window crate per platform.** The 0.31 split means a downstream crate can depend on, say, `winit-wayland` directly, and platform maintainers own their crate's release cadence. See the [scope note](#winit-rust) above and [§10](#10-history-redesigns--known-regrets).

---

## How it works

### Core abstractions

| Concept                   | Type / item                                                               | Role                                                                                         |
| ------------------------- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Application contract      | `ApplicationHandler` ([`winit-core/src/application/mod.rs`][app-handler]) | The callback trait you implement; winit calls its methods.                                   |
| Loop entry point          | `EventLoop` ([`winit/src/event_loop.rs`][el-rs])                          | Owns the native loop; `run_app(app)` consumes it and drives `ApplicationHandler`.            |
| Loop handle (in-callback) | `dyn ActiveEventLoop` ([`winit-core/src/event_loop/mod.rs`][el-core])     | Passed to every callback; creates windows, sets `ControlFlow`, exits.                        |
| Cross-thread waker        | `EventLoopProxy` + `EventLoopProxyProvider`                               | `wake_up()` from any thread → coalesced `proxy_wake_up()` callback.                          |
| Loop scheduling mode      | `ControlFlow::{Poll, Wait, WaitUntil(Instant)}`                           | Tells winit whether to spin, block, or block-with-deadline after each iteration.             |
| Window object             | `dyn Window` ([`winit-core/src/window.rs`][window-core])                  | Trait; each backend has a concrete impl (`winit_win32::Window`, …). Boxed behind `dyn`.      |
| Event payloads            | `WindowEvent`, `DeviceEvent`, `StartCause`                                | The data each callback receives.                                                             |
| GPU/SW handoff            | `rwh_06::HasWindowHandle` / `HasDisplayHandle`                            | `Window::rwh_06_window_handle()` returns the native handle for `wgpu`/`glutin`/`softbuffer`. |

### The callback model

`run_app` takes ownership of the loop and the app, then repeatedly calls the trait methods. The two required methods are `can_create_surfaces` (the "you may now make a render surface" lifecycle hook) and `window_event`; everything else has a default no-op body ([`winit-core/src/application/mod.rs`][app-handler], lines 10–103):

```rust
// winit-core/src/application/mod.rs
pub trait ApplicationHandler {
    fn new_events(&mut self, event_loop: &dyn ActiveEventLoop, cause: StartCause) { /* default */ }
    fn resumed(&mut self, event_loop: &dyn ActiveEventLoop) { /* default */ }
    fn can_create_surfaces(&mut self, event_loop: &dyn ActiveEventLoop);          // required
    fn proxy_wake_up(&mut self, event_loop: &dyn ActiveEventLoop) { /* default */ }
    fn window_event(&mut self, event_loop: &dyn ActiveEventLoop,
                    window_id: WindowId, event: WindowEvent);                     // required
    fn device_event(&mut self, /* … */) { /* default */ }
    fn about_to_wait(&mut self, event_loop: &dyn ActiveEventLoop) { /* default */ }
    fn suspended(&mut self, event_loop: &dyn ActiveEventLoop) { /* default */ }
    // destroy_surfaces, memory_warning, macos_handler …
}
```

A loop iteration on every backend follows the same fixed order, visible in the Wayland `single_iteration` ([`winit-wayland/src/event_loop/mod.rs`][wl-el], lines 314–486): `new_events(cause)` → (on `StartCause::Init`) `can_create_surfaces` → `proxy_wake_up` (if a wake was requested) → drain `WindowEvent`s → drain `DeviceEvent`s → emit `RedrawRequested` per window → `about_to_wait`. The macOS backend produces the _same_ sequence not by hand-rolling a loop but by hanging `CFRunLoop` observers off the native run loop (see [§2](#2-event-loop)).

### `ControlFlow`: who decides when to block

After `about_to_wait`, winit consults the `ControlFlow` the app set on the `ActiveEventLoop` ([`winit-core/src/event_loop/mod.rs`][el-core], lines 219–254):

```rust
// winit-core/src/event_loop/mod.rs
pub enum ControlFlow {
    Poll,                  // immediately begin a new iteration
    #[default] Wait,       // sleep until an event arrives
    WaitUntil(Instant),    // sleep until an event or this deadline
}
```

Each backend translates this into the native blocking primitive's timeout argument — `calloop`'s `dispatch(timeout)` on Wayland/X11, `MsgWaitForMultipleObjectsEx` on Win32, a `CFRunLoop` run-mode timeout on macOS.

---

## 1. Window creation & lifecycle

Windows are created **through the event loop**, not free-standing: `ActiveEventLoop::create_window(WindowAttributes) -> Result<Box<dyn Window>, RequestError>` ([`winit-core/src/event_loop/mod.rs`][el-core], line 33). The returned `Box<dyn Window>` dispatches to the per-platform concrete type.

**Per-platform native call:**

| Platform | Native creation call                                                      | File                                                     |
| -------- | ------------------------------------------------------------------------- | -------------------------------------------------------- |
| Win32    | `CreateWindowExW(...)` inside `unsafe fn init`                            | [`winit-win32/src/window.rs`][win-window] line 1417      |
| macOS    | `NSWindow` with a computed `NSWindowStyleMask`                            | [`winit-appkit/src/window_delegate.rs`][mac-wd] line 585 |
| Wayland  | `xdg_shell.create_window(surface, decorations, qh)` (SCTK `xdg_toplevel`) | [`winit-wayland/src/window/mod.rs`][wl-window] line 107  |
| X11      | `xcb` `create_window` + `_NET_WM_*` hints                                 | `winit-x11/src/window.rs`                                |

**Attributes model.** `WindowAttributes` ([`winit-core/src/window.rs`][window-core]) carries `surface_size`/`min`/`max`, `position`, `title`, `decorations: bool`, `transparent: bool`, `blur`, `window_level: WindowLevel` (Normal / AlwaysOnBottom / AlwaysOnTop), `fullscreen: Option<Fullscreen>`, `resizable`, `maximized`, `window_icon`, `parent_window`. Many are silently unsupported per platform — winit's convention is a `warn!` log, not an error. The sharpest example is Wayland fullscreen ([`winit-wayland/src/window/mod.rs`][wl-window] line 156):

```rust
// winit-wayland/src/window/mod.rs
Some(Fullscreen::Exclusive(..)) => {
    warn!("`Fullscreen::Exclusive` is ignored on Wayland");
},
```

— Wayland has no exclusive (mode-changing) fullscreen, only borderless; the request is dropped with a warning rather than refused.

**Initial-frame handling — the [no-buffer-no-window][nbnw] problem.** On X11/Win32 a window maps immediately. On Wayland a surface is invisible until it has both committed a buffer _and_ received the compositor's initial `configure`. Winit's window constructor blocks on exactly that handshake before returning ([`winit-wayland/src/window/mod.rs`][wl-window] lines 186–213):

```rust
// winit-wayland/src/window/mod.rs
// XXX Do initial commit.
window.commit();
// …
// Do a roundtrip.
event_queue.roundtrip(&mut state)?;
// XXX Wait for the initial configure to arrive.
while !window_state.lock().unwrap().is_configured() {
    event_queue.blocking_dispatch(&mut state)?;
}
```

So `create_window` does not return on Wayland until the first `xdg_surface.configure` round-trips — the app never observes the unconfigured intermediate state.

**Surface/handle exposure.** The `Window` trait exposes `rwh_06_window_handle() -> &dyn HasWindowHandle` and `rwh_06_display_handle()` ([`winit-core/src/window.rs`][window-core] lines 1434–1437), and `dyn Window` itself implements `rwh_06::HasWindowHandle`/`HasDisplayHandle` (lines 1456–1462). That handle is what `wgpu::Surface`, `glutin`, and `softbuffer` consume. This is the [raw-window-handle](#9-escape-hatches) contract, covered in [§9](#9-escape-hatches).

**Destruction ordering.** Dropping the `Box<dyn Window>` tears down the native window; the backend then emits a synthetic `WindowEvent::Destroyed`. On Wayland the destroy is folded into the loop iteration: a closed window is removed from `state.windows` and a `Destroyed` event synthesized while draining requests ([`winit-wayland/src/event_loop/mod.rs`][wl-el] lines 448–455). The hazard winit guards against on Win32 is `WM_NCDESTROY` arriving after the userdata pointer is freed — it zeroes `GWL_USERDATA` and sets a `userdata_removed` flag ([`winit-win32/src/event_loop.rs`][win-el] lines 1174–1178).

---

## 2. Event loop

**Who owns the loop: winit does, and it calls you back.** This is the central design decision, and the doc comment in [`winit/src/lib.rs`][lib-rs] states the _why_ verbatim:

> Winit no longer uses a `EventLoop::poll_events() -> impl Iterator<Event>`-based event loop model, since that can't be implemented properly on some platforms (e.g Web, iOS) and works poorly on most other platforms. However, this model can be re-implemented to an extent with `EventLoopExtPumpEvents::pump_app_events()`.

So the abstraction is **callback** by necessity (the OS owns the loop on Web/iOS/macOS), with a **`pump_app_events`** escape hatch ([`winit-core/src/event_loop/pump_events.rs`][pump]) and a **`run_app_on_demand`** ([`run_on_demand.rs`][rod]) for embedders who must own their own loop — but the docs actively discourage both.

**Native loop integration, per backend:**

- **Wayland — `calloop` fd multiplexing.** The Wayland `EventLoop` wraps a `calloop::EventLoop<WinitState>` ([`winit-wayland/src/event_loop/mod.rs`][wl-el] line 76). The Wayland display socket is inserted as a `WaylandSource`, and additional `calloop` sources multiplex alongside it: a `ping` for window-request wake-ups, a `ping` for the `EventLoopProxy` user-event waker, and per-key **`Timer`** sources for key repeat (see [§3](#3-input)). The blocking call is `self.event_loop.dispatch(timeout, state)` ([`loop_dispatch`][wl-el], line 533) — one `poll(2)` over _all_ registered fds. This is the windowing analogue of the [readiness-driven][rvc] reactors surveyed in [async-io][async-io].

  ```rust
  // winit-wayland/src/event_loop/mod.rs
  let wayland_source = WaylandSource::new(connection.clone(), event_queue);
  let wayland_dispatcher =
      calloop::Dispatcher::new(wayland_source, |_, queue, winit_state: &mut WinitState| {
          let result = queue.dispatch_pending(winit_state);
          // …
          winit_state.dispatched_events = true;
          result
      });
  ```

- **X11 — `calloop` over the XCB fd.** The X connection fd is wrapped in a `calloop::generic::Generic` source with `Interest::READ` and `Mode::Level` ([`winit-x11/src/event_loop.rs`][x11-el] lines 297–308); on readiness the callback stashes the readiness flag and the loop drains queued events with `poll_one_event`/`process_event` ([`drain_events`][x11-el] lines 621–628). Two additional `ping` sources serve as the generic waker and the user-event waker.

- **Win32 — the message pump.** `wait_for_messages` blocks in `MsgWaitForMultipleObjectsEx` ([`winit-win32/src/event_loop.rs`][win-el] line 685), then `dispatch_peeked_messages` drains everything with `PeekMessageW(PM_REMOVE)` + `TranslateMessage` + `DispatchMessageW` ([`win-el`][win-el] lines 338–384). The comment explains the design is shaped to mirror macOS: treat `MsgWaitForMultipleObjectsEx` as the wait/wake boundary so `about_to_wait`/`new_events` line up across backends (lines 318–336).
  - **The [Win32 modal resize/move loop][modal].** When the user grabs the title bar or a resize edge, Windows enters its _own_ nested modal loop and stops returning to winit's pump, freezing redraws. Winit tracks this with a `WindowFlags::MARKER_IN_SIZE_MOVE` flag set on `WM_ENTERSIZEMOVE` and cleared on `WM_EXITSIZEMOVE` ([`win-el`][win-el] lines 1111–1127), and works around the ~500 ms title-bar-click pause by posting a dummy `WM_MOUSEMOVE` on `WM_NCLBUTTONDOWN` to cancel the modal loop early — with a remarkable block comment documenting the empirically-discovered `lparam = 0` trick (lines 1129–1158).

- **macOS — `CFRunLoop` observers.** Winit does _not_ run its own loop on macOS; it calls `NSApplication::run()` and hangs observers off the main `CFRunLoop` ([`winit-appkit/src/event_loop.rs`][mac-el] lines 228–259). An `AfterWaiting` observer calls `app_state.wakeup()` (≈ `new_events`) and a `BeforeWaiting` observer calls `app_state.cleared()` (≈ `about_to_wait`):

  ```rust
  // winit-appkit/src/event_loop.rs
  let _after_waiting_observer = MainRunLoopObserver::new(
      mtm, CFRunLoopActivity::AfterWaiting, true, CFIndex::MIN + 1,
      move |_| app_state_clone.wakeup(),
  );
  ```

  `sendEvent:` on `NSApplication` is also overridden (`override_send_event`, line 198) so window/device events route through winit's state.

**Timers / wakeups.** `ControlFlow::WaitUntil` becomes the dispatch timeout. Cross-thread wakeups go through `EventLoopProxy::wake_up()` ([`winit-core/src/event_loop/mod.rs`][el-core] line 151), which is `Send + Sync` and coalesces: multiple `wake_up()`s collapse into a single `proxy_wake_up` callback. The backend wiring differs — a `calloop` `ping` on Linux, `PostMessageW(USER_EVENT_MSG_ID)` on Win32 ([`win-el`][win-el] line 761).

> [!WARNING]
> The `EventLoopProxy::wake_up` doc records a real defect: _"On Windows, the wake-up may be ignored under high contention, see [#3687]."_ ([`el-core`][el-core] lines 146–150).

**External fd / async-runtime integration.** On Linux this is first-class: because the loop _is_ a `calloop::EventLoop`, an embedder can insert their own fd sources, and `EventLoop` implements `AsFd`/`AsRawFd` ([`winit-wayland/src/event_loop/mod.rs`][wl-el] lines 567–578) so the whole winit loop can itself be polled inside a larger reactor. On Win32/macOS the only portable integration point is `pump_app_events`.

**Frame pacing & vsync.** Winit does not own a swapchain, so vsync comes from the renderer — _except_ on Wayland, where presentation throttling is protocol-level via [frame callbacks][fcv]. `Window::pre_present_notify()` exists solely to schedule a `wl_surface.frame` callback so winit can throttle `RedrawRequested` ([`winit-core/src/window.rs`][window-core] lines 574–606): _"Wayland: Schedules a frame callback to throttle `WindowEvent::RedrawRequested`. … Android / iOS / X11 / Web / Windows / macOS / Orbital: Unsupported."_ The Wayland loop only re-emits `RedrawRequested` once the previous frame callback has fired ([`winit-wayland/src/event_loop/mod.rs`][wl-el] lines 460–472, gated on `FrameCallbackState::Requested`). Apps are told to drive rendering from `RedrawRequested`, never from `about_to_wait` ([`app-handler`][app-handler] lines 214–227).

---

## 3. Input

### Keyboard

Winit's key model is a deliberate three-part split (see [scancode / keysym / virtual-key][skv]): every `KeyEvent` carries a `physical_key: PhysicalKey` (layout-independent location, a `KeyCode` like `KeyA`), a `logical_key: Key` (layout-dependent, e.g. `Character("ä")`), and a `text: Option<SmolStr>`. Unmappable keys fall back to `NativeKeyCode` variants — `Android(u32)`, `MacOS(u16)`, `Windows(u16)`, `Xkb(u32)` ([`winit-core/src/keyboard.rs`][kb-core] lines 22–35). The macOS doc comment is candid that the platform gives nothing better:

> A macOS "scancode". There does not appear to be any direct analogue to either keysyms or "virtual-key" codes in macOS, so we report the scancode instead.

— [`winit-core/src/keyboard.rs`][kb-core] lines 85–86

**Layout handling — xkbcommon, owned by winit.** On Linux/BSD the xkb state machine lives in `winit-common` (`winit-common/src/xkb/{keymap,state,compose}.rs`), shared by both the Wayland and X11 backends. X11 also keeps a legacy `xmodmap` fallback. Windows uses `keyboard_layout.rs`; macOS uses AppKit's interpretation.

**Key repeat — Wayland makes the client do it.** The Wayland protocol delivers a single press plus a `RepeatInfo { rate, delay }` and expects the _client_ to synthesize repeats. Winit implements this with a `calloop` `Timer`: on key-down it arms a `Timer::from_duration(delay)`, and the timer callback re-injects a synthetic pressed event and re-arms itself to the repeat `gap` ([`winit-wayland/src/seat/keyboard/mod.rs`][wl-kb] lines 145–205):

```rust
// winit-wayland/src/seat/keyboard/mod.rs
let timer = Timer::from_duration(delay);
keyboard_state.repeat_token = keyboard_state.loop_handle
    .insert_source(timer, move |_, _, state| {
        // … re-inject the held key …
        key_input(keyboard_state, &mut state.events_sink, data,
                  repeat_keycode, ElementState::Pressed, true);
        match keyboard_state.repeat_info {
            RepeatInfo::Repeat { gap, .. } => TimeoutAction::ToDuration(gap),
            RepeatInfo::Disable => TimeoutAction::Drop,
        }
    }).ok();
```

The code even notes that if the compositor opts to handle repeat itself, winit disables its own timer to avoid double repeats (lines 147–149). **Dead keys / compose** are handled through xkb's compose state in `winit-common/src/xkb/compose.rs`, and `Window::reset_dead_keys()` ([`window-core`][window-core] line 620) lets an app clear a pending dead-key sequence.

### IME / text input

IME is a first-class, separately-modelled event stream ([pre-edit / composition][pec]). Key events and composition are kept distinct: a `WindowEvent::Ime(Ime::{Enabled, Preedit, Commit, Disabled})` enum carries composition state, while `KeyEvent`s carry physical keys. An app opts in with `Window::set_ime_allowed(true)` and positions the candidate window with `Window::set_ime_cursor_area(position, size)` ([`window-core`][window-core] lines 1104, 1135).

Per-platform protocol:

| Platform | Protocol                                                   | File                                                |
| -------- | ---------------------------------------------------------- | --------------------------------------------------- |
| Wayland  | `zwp_text_input_v3`                                        | [`winit-wayland/src/seat/text_input/mod.rs`][wl-ti] |
| X11      | XIM (`XOpenIM`/`XCreateIC`, on-the-spot preedit callbacks) | [`winit-x11/src/ime/input_method.rs`][x11-ime]      |
| Win32    | legacy IMM32 (`ime.rs`) with a `minimal_ime.rs` fallback   | [`winit-win32/src/ime.rs`][win-ime]                 |
| macOS    | `NSTextInputClient` on the content view                    | `winit-appkit/src/view.rs`                          |

The Wayland path shows the protocol's commit-batched model directly: `PreeditString`, `CommitString`, and `DeleteSurroundingText` events accumulate into pending fields and are applied on the protocol's `done` event ([`winit-wayland/src/seat/text_input/mod.rs`][wl-ti] lines 106–149). The X11 path queries the XIM server's supported styles and prefers `XIMPreeditCallbacks | XIMStatusNothing` (on-the-spot) ([`winit-x11/src/ime/input_method.rs`][x11-ime] lines 64–90), falling back to root-window or none styles.

> [!NOTE]
> Winit's IME support is comparatively recent and uneven: TSF (the modern Windows text framework) is _not_ used — Win32 uses legacy IMM32. The X11 backend still carries explicit workarounds for GNOME and uim ([`v0.30.md`][changelog-30] entries "On X11, add a workaround for disabling IME on GNOME", "On X11, fix crash with uim").

### Pointer

`WindowEvent::PointerMoved`/`PointerButton` carry absolute, window-relative positions; **raw/relative** motion is a separate `DeviceEvent::MouseMotion` ([raw vs accelerated pointer][rap]) sourced on Wayland from the `relative_pointer` protocol ([`winit-wayland/src/seat/pointer/relative_pointer.rs`]) and on Win32 from `WM_INPUT`/`raw_input.rs`.

**High-resolution scroll.** `MouseScrollDelta` distinguishes `LineDelta` from `PixelDelta`. Win32 divides the wheel delta by `WHEEL_DELTA` and multiplies by the system lines-per-notch setting ([`winit-win32/src/event_loop.rs`][win-el] lines 1630–1658; the horizontal axis is inverted on purpose with a citation to [PR #2105]). Wayland reads `wl_pointer` axis events into `LineDelta`/`PixelDelta` ([`winit-wayland/src/seat/pointer/mod.rs`] lines 223–235); macOS surfaces momentum-phase scrolling.

**Capture / confinement / locking.** `Window::set_cursor_grab(CursorGrabMode::{None, Confined, Locked})`. On Wayland these map to the `pointer-constraints` protocol's confine/lock requests ([`winit-wayland/src/window/state.rs`][wl-wstate] lines 909–927); `pointer_constraints` and `relative_pointer` are bound optionally and degrade to errors if the compositor lacks them.

**Touch & gestures.** `WindowEvent::PointerMoved`/`Touch` plus pinch/rotate/pan gesture events; Wayland binds the `pointer-gestures` protocol (`winit-wayland/src/seat/pointer/pointer_gesture.rs`) and tablet input v2 (`wp_tablet_input_v2.rs`).

**Cursor handling.** Wayland prefers the server-side [`cursor_shape_v1`][cursor-shape] protocol (`WpCursorShapeManagerV1`/`WpCursorShapeDeviceV1`, [`winit-wayland/src/seat/pointer/mod.rs`] lines 16–17), falling back to a client-rendered themed pointer when the compositor lacks it. Custom cursors are supported via `ActiveEventLoop::create_custom_cursor` (unsupported on iOS/Android/Orbital, [`el-core`][el-core] line 43).

---

## 4. Wayland specifics

**Decorations — own-drawn CSD, _not_ libdecor.** Winit uses [`smithay-client-toolkit`][sctk] (SCTK) `0.20` and, for [client-side decorations][cvs], the `sctk-adwaita` crate which draws an Adwaita-style title bar/frame itself ([`winit-wayland/Cargo.toml`][wl-cargo] lines 14–16, 40). It does **not** link libdecor. The preference order is server-side first, client-side as fallback ([`winit-wayland/src/window/mod.rs`][wl-window] lines 98–104):

```rust
// winit-wayland/src/window/mod.rs
// We prefer server side decorations, however to not have decorations we ask for client
// side decorations instead.
let default_decorations = if attributes.decorations {
    WindowDecorations::RequestServer
} else {
    WindowDecorations::RequestClient
};
```

So on a compositor that supports `xdg-decoration` SSD (KWin, recent Mutter for some apps), the title bar is the compositor's; on one that doesn't (historically GNOME/Mutter, which forces CSD), SCTK + `sctk-adwaita` draws it. The `csd-adwaita*` cargo features select the font backend (`ab_glyph` vs `crossfont`) or a no-titlebar variant.

**Protocol coverage beyond core + `xdg-shell`** (all bound optionally and `None`-checked, from [`winit-wayland/src/state.rs`][wl-state]):

| Protocol                     | Field / type                  | Use                                                    |
| ---------------------------- | ----------------------------- | ------------------------------------------------------ |
| `wp_fractional_scale_v1`     | `FractionalScalingManager`    | Fractional DPI (see [§5](#5-dpi--scaling))             |
| `wp_viewporter`              | `ViewporterState`             | Surface scaling/cropping, paired with fractional scale |
| `xdg_activation_v1`          | `XdgActivationState`          | Focus-stealing-correct activation / startup tokens     |
| `wp_cursor_shape_v1`         | (seat)                        | Server-side cursors                                    |
| `zwp_pointer_constraints_v1` | `PointerConstraintsState`     | Lock/confine pointer                                   |
| `zwp_relative_pointer_v1`    | `RelativePointerState`        | Raw motion                                             |
| `zwp_pointer_gestures_v1`    | `PointerGesturesState`        | Pinch/swipe                                            |
| `zwp_tablet_v2`              | `TabletManager`               | Stylus                                                 |
| `zwp_text_input_v3`          | `TextInputState`              | IME                                                    |
| `xdg_toplevel_icon_v1`       | `XdgToplevelIconManagerState` | Per-window taskbar icon                                |
| KDE blur (plasma)            | `kwin_blur`                   | Background blur (`types/kwin_blur.rs`)                 |

**How protocol absence is handled.** Each global is bound with a fallible `bind`/`new` returning `Option`; e.g. `xdg_activation: XdgActivationState::bind(globals, qh).ok()` ([`winit-wayland/src/state.rs`][wl-state] line 183). A missing protocol means the corresponding feature silently no-ops. Fractional scaling is only enabled if _both_ `wp_fractional_scale` and `wp_viewporter` are present (lines 164–170).

**Compositor-specific workarounds.** The changelog and `types/` modules carry KWin/Plasma-specific code (`kwin_blur.rs`, `ext_background_effect.rs`, `bgr_effects.rs`) and the X11 backend has GNOME IME workarounds; Wayland legacy-output handling special-cases compositors that send integer scale alongside fractional ([`wl-state`][wl-state] line 228, `is_legacy && fractional_scaling_manager.is_some()`).

---

## 5. DPI & scaling

**Physical is the API-native unit.** Sizes are `PhysicalSize<u32>` (device pixels) and the app multiplies/divides by `Window::scale_factor() -> f64` to reach [logical coordinates][lpc]. The [`dpi`][dpi-crate] crate (a separate workspace member, re-exported as `winit::dpi`) provides `LogicalSize`/`PhysicalSize` conversions. This is the inverse of GTK/AppKit, which default to logical.

**When the app learns the scale ([created-at-wrong-scale][scale-factor]).** Scale arrives as a `WindowEvent::ScaleFactorChanged { scale_factor, surface_size_writer }`. The `surface_size_writer` is the resolution to the rescale problem: winit hands the app a writable handle so the callback can _adjust_ the resulting physical size, and winit then resizes the surface to match ([`winit-wayland/src/event_loop/mod.rs`][wl-el] lines 343–379).

**Per-monitor DPI on Windows (v1 vs v2).** Winit opts the process into Per-Monitor-V2 awareness at loop creation, falling back to V1 then system-DPI on older OSes ([`winit-win32/src/dpi.rs`][win-dpi] `become_dpi_aware`, lines 20–35):

```rust
// winit-win32/src/dpi.rs
if let Some(SetProcessDpiAwarenessContext) = *SET_PROCESS_DPI_AWARENESS_CONTEXT {
    if SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == false.into() {
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE);
    }
} else if let Some(SetProcessDpiAwareness) = *SET_PROCESS_DPI_AWARENESS {
    SetProcessDpiAwareness(PROCESS_PER_MONITOR_DPI_AWARE);
}
```

The [`WM_DPICHANGED`][wm-dpichanged] handler ([`winit-win32/src/event_loop.rs`][win-el] lines 2176–2240) reads the new DPI from `wparam`, computes a new physical surface size (preferring its own calculation over Windows' suggested rect to preserve logical size), and emits `ScaleFactorChanged`. Non-client (title-bar) scaling is enabled per-window with `EnableNonClientDpiScaling` on `WM_NCCREATE` ([`win-dpi`][win-dpi] line 44). It is _DPI-aware by default_ — `PlatformSpecificEventLoopAttributes::dpi_aware` defaults to `true` ([`win-el`][win-el] line 178).

**Fractional scaling on Wayland.** Via `wp_fractional_scale_v1` + `wp_viewporter` (above); when present, winit gets a fractional scale (e.g. 1.5) instead of the integer `wl_surface` scale. **Backing scale on macOS** comes from `NSWindow.backingScaleFactor`. **Mixed-DPI multi-monitor**: window migration between monitors triggers `ScaleFactorChanged` on every backend.

---

## 6. Multi-window & popups

Winit supports an arbitrary number of top-level windows from one event loop, each with its own `WindowId`. Child/parent relationships are expressed via `WindowAttributes::parent_window(RawWindowHandle)` ([`window-core`][window-core] lines 72–79, 367), used for embedding and modal parenting; the `child_window.rs` example demonstrates it.

> [!IMPORTANT]
> **Winit has no first-class popup/menu/tooltip abstraction.** This is a notable gap — there is no `xdg_popup`-with-grab API ([override-redirect vs xdg_popup grab][orx]) exposed cross-platform. On X11, winit can set `_NET_WM_WINDOW_TYPE` hints (`_NET_WM_WINDOW_TYPE_POPUP_MENU`, `_DROPDOWN_MENU`, `_TOOLTIP`, `_DIALOG`, via `WindowType`, [`winit-x11/src/util/hint.rs`][x11-hint] lines 24–32) but does not create true override-redirect grab windows. On Wayland there is no `xdg_popup` grab path. Applications that need real menus (e.g. `egui`, `iced`) build them as ordinary child windows or draw them inside the parent surface. Native menus are explicitly out of scope per [`FEATURES.md`][features].

Modal dialogs are likewise not a core concept; window stacking is controlled coarsely via `WindowLevel::{AlwaysOnBottom, Normal, AlwaysOnTop}` ([`window-core`][window-core] line 1585).

---

## 7. Threading

**Window/loop creation is main-thread by default; events arrive on that same thread.** The hard constraint is macOS: AppKit requires `NSApplication` and `NSWindow` on the main thread, and winit enforces it at runtime with `MainThreadMarker` ([`winit-appkit/src/event_loop.rs`][mac-el] lines 176–177):

```rust
// winit-appkit/src/event_loop.rs
let mtm = MainThreadMarker::new()
    .expect("on macOS, `EventLoop` must be created on the main thread!");
```

The `Window` and `ActiveEventLoop` types are deliberately `!Send`/`!Sync` so they cannot escape the loop thread; the _only_ sanctioned cross-thread channel is `EventLoopProxy` (`Send + Sync`, [§2](#2-event-loop)). On Linux and Windows the main-thread requirement is relaxable: each backend exposes `EventLoopBuilderExt*::with_any_thread(true)` ([`winit-win32/src/lib.rs`][win-lib] line 179, [`winit-x11/src/lib.rs`][x11-lib] line 135, [`winit-wayland/src/lib.rs`][wl-lib] line 75) — but macOS and iOS have no such method.

**Rendering off the event thread.** Winit doesn't own rendering, so an app _can_ render on another thread — but it needs the window handle there. Win32 exposes `WindowExtWindows::window_handle_any_thread()` (an `unsafe` getter) precisely because Win32 ties some window ops to the creating thread ([`winit-win32/src/lib.rs`][win-lib] lines 343–450). On macOS the handle is main-thread-bound; cross-thread rendering must hand the `raw-window-handle` (which is `Send` via `SendSyncRawWindowHandle`, [`window-core`][window-core] lines 449–452) to the render thread before the loop starts.

---

## 8. Clipboard & DnD

> [!NOTE]
> **Winit deliberately does not implement clipboard.** There is no `Clipboard` type in `winit-core`. Apps use a sibling crate ([`arboard`], [`smithay-clipboard`], or `wl-clipboard`) built on the same `raw-window-handle`/display connection. This keeps winit's surface small and side-steps the very different selection models (X11 PRIMARY/CLIPBOARD selections with [INCR][incr] chunking, Wayland's `wl_data_device` seat-scoped selections, Win32 delayed-rendering clipboard formats).

**Drag-and-drop is implemented** (file drops), per platform:

- **X11** — full XDND protocol: `XdndEnter`/`XdndPosition`/`XdndDrop` handlers, with the actual data fetched via `convert_selection` and a `SelectionNotify` round-trip ([`winit-x11/src/dnd.rs`][x11-dnd] lines 47–56, 141–145), surfaced as `WindowEvent::HoveredFile`/`DroppedFile`.
- **Win32** — a COM `IDropTarget` (`FileDropHandler` implementing the `IDropTarget` vtable, [`winit-win32/src/drop_handler.rs`][win-drop] lines 32–47) registered with `RegisterDragDrop`, pulling `CF_HDROP` file lists.
- **macOS** — `NSDraggingDestination` on the content view.
- **Wayland** — `wl_data_device` drag-and-drop offers.

The `dnd.rs` example exercises this. MIME/format negotiation is mostly limited to file lists (`text/uri-list`); rich-content DnD is not abstracted cross-platform.

---

## 9. Escape hatches

Winit's leak strategy is explicit and layered:

1. **`raw-window-handle` for the renderer.** The primary, sanctioned escape: `Window::rwh_06_window_handle()` / `rwh_06_display_handle()` return `&dyn HasWindowHandle`/`HasDisplayHandle` ([`window-core`][window-core] lines 1434–1462), and `winit` re-exports the crate as `winit::raw_window_handle` ([`lib-rs`][lib-rs] line 290). This is how `wgpu`, `glutin`, and `softbuffer` bind a swapchain/context/buffer. The [`raw-window-handle`][rwh] split into its own crate is what lets the GPU and windowing ecosystems version independently (see [§10](#10-history-redesigns--known-regrets)).

2. **Per-platform native getters.** Each backend's `Window` exposes raw handles: Wayland `WindowExtWayland::xdg_toplevel()` returns the `xdg_toplevel` pointer ([`winit-wayland/src/window/mod.rs`][wl-window] lines 235–237); Win32 `WindowExtWindows` exposes the `HWND` (incl. the `_any_thread` variant); macOS exposes the `NSWindow`/`NSView`.

3. **Message-pump hook (Win32).** `PlatformSpecificEventLoopAttributes` carries an optional `msg_hook` callback invoked on every peeked `MSG` _before_ `TranslateMessage`/`DispatchMessageW` ([`winit-win32/src/event_loop.rs`][win-el] lines 360–368), letting an app intercept raw Windows messages (e.g. accelerator tables, custom WM\_ messages).

4. **macOS handler extension.** `ApplicationHandler::macos_handler()` returns an optional `&mut dyn ApplicationHandlerExtMacOS` ([`app-handler`][app-handler] lines 339–345) for things like `standard_key_binding` (NSResponder action routing) that have no cross-platform analogue.

5. **Owning the loop.** `pump_app_events` / `run_app_on_demand` hand control back to an embedder's loop (with the caveats in [§2](#2-event-loop)).

That so many escape hatches exist — and the `*Ext*` trait proliferation — is itself the map of where winit's abstraction is known to leak: decorations, menus, clipboard, IME edge cases, and thread affinity.

---

## 10. History, redesigns & known regrets

The per-version changelogs live _in the source tree_ (`winit/src/changelog/v0.*.md`), which makes the redesign history unusually citable.

- **Event Loop 2.0 (issue [#459]).** The long-running redesign that replaced the old `poll_events()` iterator with a callback model, motivated by the impossibility of an iterator loop on Web/iOS/macOS (the rationale quoted in [§2](#2-event-loop)). This reshaped the entire API surface across many releases.

- **The 0.30 `ApplicationHandler` redesign.** [`v0.30.md`][changelog-30] (lines 191–395): `0.30.0` _"Add `ApplicationHandler<T>` trait which mimics `Event<T>`"_, and deprecated the closure-based `EventLoop::run` in favor of `EventLoop::run_app` (lines 250–251). The migration guide in the changelog shows the move from a `match event { … }` closure to a trait `impl`. The motivation was partly iOS/macOS: a trait with per-event methods maps cleanly onto `CFRunLoop` observers and the UIKit/AppKit delegate callbacks, where a single closure capturing all state re-entrantly was awkward.

- **The 0.31 lifecycle split.** [`v0.31.md`][changelog-31]: `ApplicationHandler::can_create_surfaces()/destroy_surfaces()` were _split off_ from `resumed()/suspended()` (lines 86–92) because conflating "app resumed" with "you may now make a surface" was wrong on Android (where the surface can be destroyed/recreated independently of resume) — `resumed/suspended` are now _only_ emitted on iOS/Web/Android. `user_event` was renamed to `user_wake_up`/`proxy_wake_up` (line 77). The big rename `inner_size → surface_size` (lines 111–124) reflects that what winit measures is the _render surface_, not a Win32-style "client area". MSRV jumped `1.70 → 1.85` (line 76).

- **The `raw-window-handle` split & version churn.** `0.31` removed the `rwh_04`/`rwh_05` cargo features, standardizing on `rwh_06` ([`v0.31.md`][changelog-31] line 211). The repeated rwh major-version migrations (0.4 → 0.5 → 0.6) are a recurring cost: every bump forces the entire `winit`/`wgpu`/`glutin` stack to upgrade in lockstep — a known ecosystem pain point that the crate split partly addresses.

- **The crate split itself (the studied tree).** Pulling each backend into its own crate (`winit-wayland`, `winit-win32`, …) under `winit-core` is the most recent structural redesign, letting platform maintainers own their crate and letting downstreams depend on a single backend. It is also why pre-0.30 path references (`src/platform_impl/linux/wayland/…`) no longer resolve.

- **Standing pain points / regrets visible in the tree:** no cross-platform popup/menu grab ([§6](#6-multi-window--popups)); Win32 IME stuck on legacy IMM32 rather than TSF ([§3](#3-input)); the `EventLoopProxy` wake-up that can be dropped under contention on Windows ([#3687], [§2](#2-event-loop)); and the X11 backend's accumulating compositor-specific workarounds (GNOME/uim IME, WM hittest quirks, [`v0.30.md`][changelog-30]).

---

## Strengths

- **Genuinely cross-platform from one API**, including the awkward cases (Web, iOS, Android) that callback ownership exists to support.
- **Clean GPU handoff** via first-class `raw-window-handle`; the reason the entire Rust graphics stack standardizes on it.
- **Honest about the abstraction boundary** — `FEATURES.md`'s Core/Platform/Usability tiering and the `*Ext*` traits make leaks explicit instead of pretending they don't exist.
- **Excellent Linux event-loop story:** building on `calloop` means the whole loop is an fd multiplexer an embedder can extend and even poll from a larger reactor.
- **Source-tree changelogs and dense doc comments** make design rationale and per-platform caveats unusually traceable.
- **Modular crate split** lets platform experts own their backend and downstreams trim dependencies.

## Weaknesses

- **No clipboard, no menus, no popups/tooltips with grab** — large, commonly-needed pieces punted to sibling crates or the app.
- **Win32 IME uses legacy IMM32, not TSF**; IME support generally lags and carries per-WM workarounds.
- **Callback model is more boilerplate** than a simple loop for trivial apps, and the lifecycle (`resumed` vs `can_create_surfaces`) is subtle and has been re-cut twice.
- **Physical-coordinate default** surprises developers coming from logical-unit toolkits and pushes scale-conversion onto every app.
- **API instability:** still pre-1.0, with breaking renames (`inner_size → surface_size`), trait reshuffles, and rwh version churn every few releases.
- **Frame pacing is only real on Wayland;** elsewhere winit relies entirely on the renderer for vsync.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                                             | Trade-off                                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Callback `ApplicationHandler`, not a poll iterator | Only model that works where the OS owns the loop (Web/iOS/macOS)                      | More boilerplate; re-entrancy and lifecycle subtleties; `pump_events` is a discouraged stopgap |
| `calloop` for the Linux loop                       | fd multiplexing for free; embedders can add sources and poll the loop                 | Linux-only abstraction; Win32/macOS get bespoke integration instead                            |
| `raw-window-handle` for presentation               | Decouples windowing from the GPU stack; one handle every renderer consumes            | rwh major bumps force the whole ecosystem to upgrade in lockstep                               |
| Physical coordinates as native unit                | No precision loss; explicit about device pixels                                       | Every app must convert; differs from AppKit/GTK conventions                                    |
| Own-drawn CSD via `sctk-adwaita` (no libdecor)     | No C dependency; pure-Rust frame; predictable look                                    | Adwaita frame on non-GNOME compositors; extra maintenance vs delegating to libdecor            |
| No clipboard / menus / popups in core              | Keeps the abstraction to the platform intersection; avoids selection-model divergence | Common needs pushed to `arboard`/`smithay-clipboard` and per-app menu hacks                    |
| Per-platform crate split (0.31)                    | Platform-expert ownership; downstream dep trimming; independent cadence               | More crates to coordinate; churn; old path references break                                    |
| `EventLoopProxy` as the only cross-thread channel  | Enforces `!Send` window types → matches macOS main-thread reality                     | Cross-thread work must marshal through one coalesced wake-up; Windows can drop it under load   |

---

## Verdict: what a new framework should steal / avoid

**Steal:** the callback-first loop model (it is the only one that survives contact with Web/iOS/macOS); `raw-window-handle`-style decoupling of windowing from rendering; the explicit Core/Platform/Usability tiering with named extension traits so leaks are _documented_, not hidden; and the `calloop` approach of making the Linux loop a first-class fd multiplexer that embedders can extend. The `surface_size_writer` pattern for resolving the [created-at-wrong-scale][scale-factor] problem (let the app rewrite the post-rescale physical size in-callback) is elegant.

**Avoid / improve on:** leaving clipboard, menus, and especially **popup/tooltip grab semantics** entirely out of scope pushes real complexity onto every consumer — a windowing layer that owns the loop is the right place to own `xdg_popup`/override-redirect grabs. The legacy-IMM32 (not TSF) Win32 IME and the uneven IME story generally are worth surpassing. And the recurring breaking renames argue for nailing the coordinate-unit and lifecycle vocabulary _before_ a 1.0, not re-cutting it across point releases.

For where the rendering/layout layers that sit _on top_ of a windowing substrate are surveyed, see the [ui-layout catalog][ui-layout]; for the event-loop/reactor concepts winit's Linux backend shares with async runtimes, see [async-io][async-io].

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exactly which Mutter/GNOME versions now grant `xdg-decoration` SSD to winit** (vs forcing the `sctk-adwaita` CSD path). Likely in the Mutter `xdg-decoration` implementation history and winit issues tagged `wayland` + `decorations`; the SCTK `xdg/window` decoration negotiation code is the proximate source.
- **Whether the 0.31 crate split is final or whether `winit-core` will itself be published independently for non-winit consumers.** Likely answered in the `0.31`/`1.0` milestone discussion on [rust-windowing/winit][repo] and [`FEATURES.md`][features]'s 1.0 section.
- **The precise frame-pacing semantics on macOS** — winit says `pre_present_notify` is unsupported there, so whether `CVDisplayLink`/`CADisplayLink` integration is planned. Likely in macOS-tagged issues and `winit-appkit` redraw code.
- **Whether the Windows `EventLoopProxy` wake-up drop ([#3687]) was ever fully fixed** or is still a live "may be ignored under high contention" caveat. The PR thread and current `winit-win32` proxy code hold the answer.

---

## Sources

- [rust-windowing/winit][repo] — main repository (all quoted file paths, at commit [`81b27297`][commit])
- [`winit/src/lib.rs`][lib-rs] — top-level module doc; the loop-ownership rationale
- [`winit-core/src/application/mod.rs`][app-handler] — the `ApplicationHandler` trait
- [`winit-core/src/event_loop/mod.rs`][el-core] — `ActiveEventLoop`, `ControlFlow`, `EventLoopProxy`
- [`winit-core/src/window.rs`][window-core] — `Window` trait, `WindowAttributes`, rwh handles, `pre_present_notify`
- [`winit-core/src/keyboard.rs`][kb-core] — keyboard model (`PhysicalKey`/`Key`/`NativeKeyCode`)
- [`winit-wayland/src/event_loop/mod.rs`][wl-el] — calloop multiplexing, frame-callback throttling
- [`winit-wayland/src/window/mod.rs`][wl-window] — no-buffer-no-window handshake, decoration preference
- [`winit-wayland/src/seat/keyboard/mod.rs`][wl-kb] — client-side key-repeat timer
- [`winit-wayland/src/state.rs`][wl-state] — optional Wayland protocol binding
- [`winit-x11/src/event_loop.rs`][x11-el] — calloop over the XCB fd
- [`winit-win32/src/event_loop.rs`][win-el] — message pump, modal resize loop, `WM_DPICHANGED`
- [`winit-win32/src/dpi.rs`][win-dpi] — Per-Monitor-V2 awareness
- [`winit-appkit/src/event_loop.rs`][mac-el] — CFRunLoop observers, MainThreadMarker
- [`FEATURES.md`][features] — scope, tiering, the "does not draw" boundary
- Changelogs [`v0.30.md`][changelog-30], [`v0.31.md`][changelog-31]; Event Loop 2.0 [#459]; wake-up bug [#3687]; scroll-inversion [PR #2105]
- Sibling concepts: [concepts.md][concepts]; cross-tree [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[repo]: https://github.com/rust-windowing/winit
[commit]: https://github.com/rust-windowing/winit/tree/81b272976588c767954df51b26999723fdb7cab4
[docsrs]: https://docs.rs/winit/latest/winit/
[features]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/FEATURES.md
[lib-rs]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit/src/lib.rs
[platform-impl]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit/src/platform_impl/mod.rs
[el-rs]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit/src/event_loop.rs
[app-handler]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/application/mod.rs
[el-core]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/event_loop/mod.rs
[window-core]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/window.rs
[kb-core]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/keyboard.rs
[pump]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/event_loop/pump_events.rs
[rod]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-core/src/event_loop/run_on_demand.rs
[wl-el]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/event_loop/mod.rs
[wl-window]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/window/mod.rs
[wl-kb]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/seat/keyboard/mod.rs
[wl-ti]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/seat/text_input/mod.rs
[wl-state]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/state.rs
[wl-wstate]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/window/state.rs
[wl-cargo]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/Cargo.toml
[wl-lib]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-wayland/src/lib.rs
[x11-el]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-x11/src/event_loop.rs
[x11-ime]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-x11/src/ime/input_method.rs
[x11-hint]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-x11/src/util/hint.rs
[x11-dnd]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-x11/src/dnd.rs
[x11-lib]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-x11/src/lib.rs
[win-el]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/event_loop.rs
[win-window]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/window.rs
[win-dpi]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/dpi.rs
[win-ime]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/ime.rs
[win-drop]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/drop_handler.rs
[win-lib]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-win32/src/lib.rs
[mac-el]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-appkit/src/event_loop.rs
[mac-wd]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit-appkit/src/window_delegate.rs
[changelog-30]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit/src/changelog/v0.30.md
[changelog-31]: https://github.com/rust-windowing/winit/blob/81b272976588c767954df51b26999723fdb7cab4/winit/src/changelog/v0.31.md
[#459]: https://github.com/rust-windowing/winit/issues/459
[#3687]: https://github.com/rust-windowing/winit/pull/3687
[PR #2105]: https://github.com/rust-windowing/winit/pull/2105
[rwh]: https://github.com/rust-windowing/raw-window-handle
[sctk]: https://github.com/Smithay/client-toolkit
[dpi-crate]: https://docs.rs/dpi/latest/dpi/
[arboard]: https://github.com/1Password/arboard
[smithay-clipboard]: https://github.com/Smithay/smithay-clipboard
[SDL]: https://www.libsdl.org/
[GLFW]: https://www.glfw.org/
[wm-dpichanged]: https://learn.microsoft.com/en-us/windows/win32/hidpi/wm-dpichanged
[concepts]: ./concepts.md
[csd-vs-ssd]: ./concepts.md#client-vs-server-decoration
[cvs]: ./concepts.md#client-vs-server-decoration
[skv]: ./concepts.md#scancode-keysym-virtualkey
[lpc]: ./concepts.md#logical-vs-physical-coords
[scale-factor]: ./concepts.md#scale-factor
[pec]: ./concepts.md#pre-edit-composition
[orx]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[modal]: ./concepts.md#win32-modal-resize-loop
[rap]: ./concepts.md#raw-vs-accelerated-pointer
[nbnw]: ./concepts.md#no-buffer-no-window
[fcv]: ./concepts.md#frame-callback-vsync
[rvc]: ./concepts.md#readiness-vs-completion-windowing
[cursor-shape]: ./concepts.md#raw-vs-accelerated-pointer
[incr]: https://tronche.com/gui/x/icccm/sec-2.html#s-2.7.2
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
