# Chromium Ozone (C++)

Chromium's in-tree platform-abstraction layer for low-level graphics and input on Linux: a runtime-pluggable factory (`OzonePlatform`) that decouples the platform-neutral Aura/Views/Viz upper layers from `wayland`, `x11`, `drm/gbm`, `headless`, and embedded backends behind a single set of C++ interfaces (`PlatformWindow`, `SurfaceFactoryOzone`, `PlatformScreen`).

| Field             | Value                                                                                                                                                                        |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Version/commit    | `main` branch as of June 8, 2026 (web-only study via [GitHub][chromium] + [source.chromium.org][srcchromium])                                                                |
| Language          | C++ (C++20, Chromium style)                                                                                                                                                  |
| License           | BSD-3-Clause                                                                                                                                                                 |
| Repository        | [chromium/chromium][chromium]                                                                                                                                                |
| Documentation     | [Ozone Overview][ozone-overview] design doc                                                                                                                                  |
| Category          | Browser platform-abstraction layer (window-system integration)                                                                                                               |
| Platforms covered | Wayland, X11 (Ozone/X11), DRM/GBM, Headless, Cast, Fuchsia/Flatland; this doc focuses on Wayland + X11                                                                       |
| Loop ownership    | Hybrid — Ozone plugs each backend's display fd into Chromium's own `base::MessagePump` (callback-driven dispatch); Wayland additionally runs a **dedicated fd-watch thread** |
| Repo paths        | `ui/ozone/public/` (interfaces), `ui/ozone/platform/{wayland,x11}/` (backends), `ui/platform_window/` (cross-platform window contract), `ui/events/` (input)                 |

---

## Overview

### What it solves

Ozone is the seam that lets one Chromium binary target wildly different graphics/input stacks — from a GPU-less embedded SoC to a desktop Wayland compositor — without `#ifdef`-ing the rendering and UI code. The design doc states its purpose plainly:

> Ozone is a platform abstraction layer beneath the Aura window system that is used for low level input and graphics.

— [`docs/ozone_overview.md`][ozone-overview]

The architectural commitment is **"Interfaces, not ifdefs"** — platform variation is a virtual-method call into a platform-supplied object, never a conditional compile:

> Differences between platforms are handled by calling a platform-supplied object through an interface instead of using conditional compilation. Platform internals remain encapsulated, and the public interface acts as a firewall between the platform-neutral upper layers (aura, blink, content, etc) and the platform-specific lower layers. The platform layer is relatively centralized to minimize the number of places ports need to add code.

— [`docs/ozone_overview.md`][ozone-overview]

That firewall is what every other subject in this survey has to build from scratch: a winit, GLFW, or SDL exposes _one_ window API and switches backend internally; Ozone is the same idea pushed to browser scale, where the consumer (Aura/Views) is itself an enormous codebase that must never see a `wl_surface` or an `xcb_window_t`. See [csd-vs-ssd][concepts-csd] and the broader [layout corpus][ui-layout] for how the upper layers consume this seam.

> [!NOTE]
> This is **source-code-level** research into the windowing layer (`ui/ozone`, `ui/platform_window`, `ui/events`). Aura, Views, Blink, and the Viz compositor are out of scope except where they constrain windowing. Ozone's GPU/Viz buffer-allocation half (`SurfaceFactoryOzone`, `NativePixmap`, overlays) is touched only where it dictates window/thread structure.

### Design philosophy

- **Runtime-bound, multi-platform binary.** Multiple backends compile into one executable and are chosen by a flag, not a build:

  > Avoiding conditional compilation in the upper layers allows us to build multiple platforms into one binary and bind them at runtime. We allow this and provide a command-line flag to select a platform (`--ozone-platform`) if multiple are enabled. — [`docs/ozone_overview.md`][ozone-overview]

- **A factory-of-factories.** `OzonePlatform` is an abstract base whose subclasses (`OzonePlatformWayland`, `OzonePlatformX11`, …) vend the per-capability factories. The class comment: _"Base class for Ozone platform implementations. Ozone platforms must override this class and implement the virtual `GetFooFactoryOzone()` methods…"_ ([`ui/ozone/public/ozone_platform.h`][ozone-platform-h]).
- **Two processes, one abstraction.** The same `OzonePlatform` is initialized in two modes: `InitializeUI()` (browser/UI process — windowing + input) and `InitializeGPU()` (GPU process — buffer allocation), both pure-virtual ([`ozone_platform.h`][ozone-platform-h]). Windowing lives entirely in the UI process; the GPU process only allocates surfaces. This split shapes the [threading model](#7-threading).
- **Minimal, porting-friendly contracts.** _"The platform interfaces should encapsulate just what chrome needs from the platform, with minimal constraints on the platform's implementation"_ ([`ozone_overview.md`][ozone-overview]) — `PlatformWindow` is deliberately small (~30 pure-virtual methods) so a new port is tractable.

---

## How it works

### The factory abstraction

The whole subsystem hangs off three interfaces:

```cpp
// ui/ozone/public/ozone_platform.h — the factory base (abridged)
class COMPONENT_EXPORT(OZONE) OzonePlatform {
 public:
  // Per-capability factories (called by the platform-neutral layers):
  virtual SurfaceFactoryOzone* GetSurfaceFactoryOzone() = 0;  // GPU surfaces
  virtual OverlayManagerOzone* GetOverlayManager() = 0;
  virtual CursorFactory* GetCursorFactory() = 0;
  virtual InputController* GetInputController() = 0;
  virtual std::unique_ptr<PlatformWindow> CreatePlatformWindow(
      PlatformWindowDelegate* delegate,
      PlatformWindowInitProperties properties) = 0;
  virtual std::unique_ptr<PlatformScreen> CreateScreen() = 0;
  virtual PlatformClipboard* GetPlatformClipboard();
  // Two-phase, two-process init:
  virtual void InitializeUI(const InitParams& args) = 0;
  virtual void InitializeGPU(const InitParams& args) = 0;
};
```

`OzonePlatformWayland::CreatePlatformWindow` simply forwards to the backend's own factory:

```cpp
// ui/ozone/platform/wayland/ozone_platform_wayland.cc (~line 286)
std::unique_ptr<PlatformWindow> CreatePlatformWindow(
    PlatformWindowDelegate* delegate,
    PlatformWindowInitProperties properties) override {
  return WaylandWindow::Create(delegate, connection_.get(),
                               std::move(properties));
}
```

`WaylandWindow::Create` switches on `properties.type` to instantiate a `WaylandToplevelWindow`, `WaylandPopup`, or `WaylandBubble` ([`wayland_window.h`][wayland-window-h], `static Create()` ~line 118).

### The window contract and its delegate

`PlatformWindow` ([`ui/platform_window/platform_window.h`][platform-window-h], class comment: _"Generic PlatformWindow interface."_) is the cross-platform window. Every operation a window needs is a pure-virtual: `Show(bool inactive)`, `Hide`, `Close`, `SetBoundsInPixels`/`SetBoundsInDIP`, `SetTitle`, `Maximize`/`Minimize`/`Restore`, `SetFullscreen(bool, int64_t target_display_id)`, `Activate`/`Deactivate`, `SetCapture`/`ReleaseCapture`, `SetUseNativeFrame`/`ShouldUseNativeFrame`, `SetCursor`, `ConfineCursorToBounds`, `GetWidget`.

Events flow the other way through `PlatformWindowDelegate` ([`platform_window_delegate.h`][platform-window-delegate-h]). The backend calls into the delegate; Aura's `DesktopWindowTreeHostPlatform` implements it. Key callbacks:

```cpp
// ui/platform_window/platform_window_delegate.h (abridged)
virtual void OnBoundsChanged(const BoundsChange& change) = 0;          // line 167
virtual void OnDamageRect(const gfx::Rect& damaged_region) = 0;        // line 170
virtual void DispatchEvent(Event* event) = 0;                         // line 171 — input
virtual void OnCloseRequest() = 0;                                    // line 172
virtual void OnWindowStateChanged(PlatformWindowState old_state,
                                  PlatformWindowState new_state) = 0;  // line 174
virtual void OnAcceleratedWidgetAvailable(gfx::AcceleratedWidget) = 0;// line 189 — GPU handle
virtual void OnActivationChanged(bool active) = 0;                    // line 197
```

The `OnAcceleratedWidgetAvailable(gfx::AcceleratedWidget)` callback is the [escape-hatch](#9-escape-hatches) handoff: the backend tells the upper layer "here is the opaque native handle the GPU process can render into."

### The loop integration

Ozone does **not** own a loop. It plugs each backend's fd into Chromium's own `base::MessagePump`. On X11 the `x11::Connection` fd is registered with the UI message pump via `WatchFileDescriptor`; on Wayland the display fd is watched on a dedicated thread that posts dispatch back to the UI thread. Both ultimately drive the backend's event-source object, which translates native events into `ui::Event` and hands them to `PlatformWindowDelegate::DispatchEvent`. Details in [§2](#2-event-loop).

---

## 1. Window creation & lifecycle

**The wrapping abstraction.** Creation is uniform: `OzonePlatform::CreatePlatformWindow(delegate, PlatformWindowInitProperties)`. `PlatformWindowInitProperties` ([`platform_window_init_properties.h`][platform-window-init-h]) is the attribute bag, with `type` (`PlatformWindowType`: `kWindow`, `kPopup`, `kMenu`, `kTooltip`, `kDrag`, `kBubble`), `bounds`, `parent_widget`, `opacity` (`kOpaque`/`kTranslucent`), and flags `activatable`, `keep_on_top`, `visible_on_all_workspaces`, `remove_standard_frame`, plus Linux-WM fields `wm_role_name`/`wm_class_name`/`wm_class_class` (the comment: _"Controls window grouping and desktop file matching in Linux window managers"_) and `wayland_app_id`.

**Per-platform native calls.**

- **Wayland.** `WaylandToplevelWindow` creates a `wl_surface` (`root_surface_`, z-order `INT32_MIN`, an opaque background) and an `xdg_surface`/`xdg_toplevel` via `CreateXdgToplevel()` ([`wayland_toplevel_window.h`][wayland-toplevel-h] ~line 251). A toplevel is configured asynchronously: the compositor sends `xdg_toplevel.configure` → `HandleToplevelConfigure()`, the client acks, then attaches a buffer.
- **X11.** `X11Window::CreateXWindow()` issues the create request through `x11::Connection` (xcb wire protocol, not legacy Xlib), `AddWindow` to the `X11WindowManager`, selects an event mask (`ButtonPress | KeyPress | StructureNotify | PropertyChange | PointerMotion | …`), and registers the `WM_PROTOCOLS` atoms `WM_DELETE_WINDOW`, `_NET_WM_PING`, `_NET_WM_SYNC_REQUEST` ([`x11_window.cc`][x11-window-cc] ~lines 565–631).

**Initial-frame handling — the [no-buffer-no-window][concepts-nbnw] rule.** On Wayland a `wl_surface` is not on screen until a buffer is committed; certain state is silently dropped if committed without a buffer. `WaylandSurface` documents this:

> Some states do not take effect if the surface commit has no buffer. E.g. `xdg_surface.set_window_geometry`

— [`ui/ozone/platform/wayland/host/wayland_surface.h`][wayland-surface-h] (~line 223)

So a Wayland window goes create-surface → configure → ack → attach-buffer → commit before it is mapped. X11 maps immediately on `MapWindow` regardless of paint — the classic readiness-vs-deferred divergence.

**Attributes silently unsupported per platform.** `SetBoundsInPixels` for absolute window _position_ is meaningful on X11 but a no-op on Wayland (clients cannot position their own toplevels — there is no global coordinate space). `always-on-top`/`keep_on_top`, taskbar visibility, and explicit workspace placement are honored on X11 via EWMH hints (`_NET_WM_STATE_ABOVE`, etc.) but are compositor-discretionary or unavailable on core Wayland (handled, when present, through the aura-shell/`zaura_shell` extension on ChromeOS exo compositors). `SetWindowIcons` maps to X11 `_NET_WM_ICON` but on Wayland needs the separate `toplevel_icon_manager` (xdg-toplevel-icon).

**Surface/handle exposure for rendering.** The opaque `gfx::AcceleratedWidget` delivered via `OnAcceleratedWidgetAvailable` is the rendering handle. On X11 it is the X window id; on Wayland the GPU process is handed enough to create its own `wl_surface`/EGL window (the windowing happens host-side, buffers are produced GPU-side and shipped via `WaylandBufferManager`). `SurfaceFactoryOzone` (_"The Ozone interface supports two drawing modes: 1) accelerated drawing using GL and 2) software drawing through Skia."_ — [`surface_factory_ozone.h`][surface-factory-h]) turns that handle into a GL surface or Skia canvas.

**Destruction-ordering hazards.** `OnWillDestroyAcceleratedWidget` / `OnAcceleratedWidgetDestroyed` bracket teardown so the GPU side stops rendering into a handle before it is freed; `PrepareForShutdown()` exists on `PlatformWindow` for the same reason. The deadlock that motivated the dedicated Wayland fd-watch thread (see [§7](#7-threading)) is fundamentally a destruction-ordering hazard between UI-thread `prepare_read` and GPU-thread EGL teardown.

---

## 2. Event loop

**Who owns the loop: Chromium, not Ozone (hybrid, callback-driven).** Chromium has its own cross-platform message loop, `base::MessagePump`. Ozone's job is to feed each backend's display fd into that pump and translate native events into `ui::Event`. So dispatch is callback-driven (the pump calls the backend when the fd is readable), but the _readiness_ source is the OS poll inside the pump — a hybrid of Chromium's loop and the platform's fd. This mirrors the [readiness-vs-completion][concepts-readiness] split studied in [async-io][async-io].

**X11 — fd watched directly on the UI pump.** `X11EventSource` ([`ui/events/platform/x11/x11_event_source.h`][x11-event-source-h]) is the X implementation of `PlatformEventSource`. It registers the X connection fd (`ConnectionNumber(...)`) with the UI message pump through a watcher; there are two watcher implementations selected at build/run time — `X11EventWatcherGlib` ([`x11_event_watcher_glib.cc`][x11-watcher-glib]) for the default glib-backed `MessagePumpGlib`, and `X11EventWatcherFdwatch` for the libevent pump. When the fd is readable the watcher pulls XCB events and `X11EventSource` walks its `XEventDispatcher` list, dispatching each to the matching `X11Window`, which forwards to `PlatformWindowDelegate::DispatchEvent`. (Igalia's write-up of this flow: [Event management in X11 Chromium][igalia-x11-events].)

**Wayland — a dedicated fd-watch thread.** `WaylandEventSource` ([`wayland_event_source.h`][wayland-event-source-h]) is the Wayland `PlatformEventSource`; its class comment:

> Wayland implementation of `ui::PlatformEventSource`. It polls for events through `WaylandEventWatcher` and centralizes the input and focus handling logic…

— [`ui/ozone/platform/wayland/host/wayland_event_source.h`][wayland-event-source-h]

The actual fd polling is delegated to `WaylandEventWatcher` (with glib and fdwatch subclasses), which performs the libwayland `wl_display_prepare_read` / `wl_display_read_events` / `wl_display_dispatch_pending` / `wl_display_flush` dance. Critically, Chromium moved this off the UI thread onto a dedicated thread to avoid a `prepare_read` deadlock — see [§7](#7-threading). User-event injection and timers come for free from `base::MessagePump` (`PostTask`, `base::OneShotTimer`), so cross-thread wakeups use Chromium's task system rather than a self-pipe.

**Frame pacing & vsync.** Wayland frame pacing is driven by `wl_surface.frame` callbacks managed in `WaylandFrameManager`/`WaylandFrame` ([`wayland_frame_manager.h`][wayland-frame-h]): a frame holds a `wl::Object<wl_callback> wl_frame_callback` (~line 145) and the manager only submits the next frame after the previous callback is ack'ed — the comment _"Previous frame's `wl_frame_callback` must be ack'ed"_ (~line 216). Presentation timing uses `wp_presentation_feedback` (`OnPresented`/`OnDiscarded`, ~lines 276–291), feeding `gfx::PresentationFeedback`. This is the [frame-callback vsync][concepts-frame-callback] model. On X11 vsync/present is sourced differently (the Present extension / GPU swap), outside the windowing layer. Redraw coalescing is handled by `OnDamageRect` accumulation in the delegate plus the one-frame-in-flight throttle.

---

## 3. Input

**Keyboard model — DOM codes + xkbcommon.** Chromium normalizes physical keys to W3C `ui::DomCode` (a USB-HID-derived [scancode][concepts-scancode]) and logical keys to `ui::DomKey`, decoupled from any platform keysym. The layout state machine is xkbcommon, owned by `XkbKeyboardLayoutEngine`. `WaylandKeyboard` ([`wayland_keyboard.h`][wayland-keyboard-h]) selects it at compile time: when `USE_XKBCOMMON` is set, `LayoutEngine` aliases `XkbKeyboardLayoutEngine`, else a stub. The keymap arrives via the `wl_keyboard.keymap` event (`OnKeymap()`, ~lines 92–96), an fd to an `xkb_keymap` string that is fed to xkbcommon. X11 likewise routes through the same xkb layout engine.

**Key repeat — client-side on Wayland.** Wayland delivers key _state_ only; repeat is the client's responsibility. Chromium implements it with `EventAutoRepeatHandler` ([`event_auto_repeat_handler.h`][auto-repeat-h]). `WaylandKeyboard` owns an `auto_repeat_handler_` and implements `EventAutoRepeatHandler::Delegate`, synthesizing repeated `ui::KeyEvent`s on a timer using the rate/delay from `wl_keyboard.repeat_info` ([`wayland_keyboard.h`][wayland-keyboard-h] ~line 120). This is the textbook "Wayland makes the client do repeat" case. X11 gets auto-repeat from the server, so it does not use this handler.

**IME / text input — the most platform-divergent area.** Chromium implements the cross-platform `ui::LinuxInputMethodContext` for Wayland in `WaylandInputMethodContext` ([`wayland_input_method_context.h`][wayland-ime-h]), which holds **two** wrappers and picks one per compositor support:

```cpp
// ui/ozone/platform/wayland/host/wayland_input_method_context.h (abridged)
std::unique_ptr<ZwpTextInputV1Client> text_input_v1_client_;   // line 168
std::unique_ptr<ZwpTextInputV3Client> text_input_v3_client_;   // line 169
raw_ptr<ZwpTextInputV1> text_input_v1_;                        // line 171
raw_ptr<ZwpTextInputV3> text_input_v3_;                        // line 172
```

`zwp_text_input_v1` is preferred where available (it carries richer pre-edit styling); `zwp_text_input_v3` is the standardized fallback. [Pre-edit/composition][concepts-preedit] flows through `OnPreeditString(text, spans, preedit_cursor)` (~line 109) and commits via `OnCommitString(text)` (~line 113); the candidate-window position is set with `SetCursorLocation(rect)` (~line 72), and surrounding-text context via `SetSurroundingText` (~line 74) / `OnDeleteSurroundingText` (~line 119). v3 support was added under a flag and tracked in [crbug 40113488][crbug-text-input-v3]. Key events and text-input events are separate channels: `wl_keyboard` key events are dispatched as `ui::KeyEvent`, while the text-input protocol delivers composition/commit independently, so the IME can swallow keys without them double-firing.

**Pointer.** `WaylandPointer` ([`wayland_pointer.h`][wayland-pointer-h]) wraps `wl_pointer`; its `Delegate` exposes `OnPointerFocusChanged` (enter/leave), `OnPointerMotionEvent`, `OnPointerButtonEvent`, `OnPointerAxisEvent`, `OnPointerAxisSourceEvent`, `OnPointerFrameEvent`. [High-resolution scroll][concepts-raw-pointer] is handled by `OnPointerAxisEvent(..., bool is_high_resolution)` consuming `wl_pointer.axis_value120` (the 120-per-detent convention shared with Windows `WM_MOUSEWHEEL`). Absolute vs relative motion: ordinary motion is absolute surface-local; raw/relative motion uses `zwp_relative_pointer_v1` and confinement/locking uses `zwp_pointer_constraints_v1` (`ConfineCursorToBounds` on `PlatformWindow`). Touch is `WaylandTouch` (delegate methods `OnTouchPressEvent`/`OnTouchReleaseEvent`, tracked in a `touch_points_` flat_map), and pointer-gesture pinch via `WaylandZwpPointerGestures`. Fling velocity is computed client-side (`ComputeFlingVelocity`, `ProcessPointerScrollData` in `WaylandEventSource`).

**Cursor.** Chromium prefers server-side cursors via `wp_cursor_shape_v1` when available: `WaylandCursorShape` ([`wayland_cursor_shape.h`][wayland-cursor-shape-h]) maps `ui::mojom::CursorType` to a `wp_cursor_shape_device_v1` shape (`ShapeFromType`, _"…or nullopt if the type isn't supported by Wayland's cursor shape API."_), falling back to client-rendered cursor surfaces (`WaylandCursor` + `WaylandCursorFactory`) when the protocol is absent.

---

## 4. Wayland specifics

**Decorations — prefers server-side, falls back to client-drawn, does NOT use libdecor.** `WaylandToplevelWindow` keys decoration mode on `use_native_frame_`, documented inline:

> When `use_native_frame` is false, client-side decoration is set. When `use_native_frame` is true, server-side decoration is set.

— [`wayland_toplevel_window.h`][wayland-toplevel-h] (~lines 267–268)

Server-side decoration is negotiated via `zxdg_toplevel_decoration_v1` (`xdg-decoration-unstable-v1`) — `OnDecorationModeChanged()` reacts to the compositor's enforced mode (~line 247). Where the compositor declines server-side decorations (e.g. GNOME/mutter, which does not implement `xdg-decoration` SSD), Chromium draws its **own** [CSD][concepts-csd] frame from Views — it does **not** link libdecor. This own-CSD path is the source of recurring fit-and-finish bugs ([crbug 40785698, "Issues with client-side decorations"][crbug-csd]).

**Protocol coverage beyond core + xdg-shell.** Studied in the host tree: `fractional_scale_manager` (`wp_fractional_scale_v1`), `wp_viewport` (viewporter, in `WaylandSurface::set_viewport_destination`), `zwp_text_input_v1`/`v3`, `zwp_relative_pointer_v1`, `zwp_pointer_constraints_v1`, `zwp_pointer_gestures_v1`, `wp_cursor_shape_v1`, `wp_presentation`, `zxdg_decoration_v1`, `org_kde_kwin_server_decoration`, `xdg-activation` (focus/raise), plus the ChromeOS-only `zaura_shell` extension. Layer-shell (`zwlr_layer_shell`) is **not** used — Chromium is an app, not a panel.

**Protocol absence handled per compositor.** Each global is bound only if advertised in `wl_registry`; absence flips the corresponding feature off (cursor-shape → client cursors; fractional-scale → integer `wl_surface.set_buffer_scale`; SSD → own CSD). Compositor-specific workarounds appear throughout the issue tracker (mutter SSD refusal, KWin/Sway tiled-edge decoration fixes — e.g. [ozone-reviews: "fix frame decoration when in tiled/ssd mode"][ozone-tiled-fix]).

> [!NOTE]
> Chromium binds aura-shell only against ChromeOS's exo compositor; on a generic Linux Wayland desktop those extensions are absent, so ChromeOS-only window features (workspaces/desks, some window states) degrade to compositor defaults.

---

## 5. DPI & scaling

**Native unit is logical (DIP), pixels at the boundary.** `PlatformWindow` exposes both `SetBoundsInDIP`/`GetBoundsInDIP` and `SetBoundsInPixels`/`GetBoundsInPixels` ([`platform_window.h`][platform-window-h]) — the upper layers work in [logical device-independent pixels][concepts-logical] and convert at the seam. `WaylandSurface` carries the buffer scale: `set_surface_buffer_scale()` (~lines 149–155), where _"buffers operate in pixels while the compositor interprets them in device-independent pixels."_

**Integer scale (legacy) vs fractional scale.** Without `wp_fractional_scale_v1`, Chromium uses integer `wl_surface.set_buffer_scale` from `wl_output.scale`. With it, `fractional_scale_manager` ([`fractional_scale_manager.h`][fractional-scale-h]) receives a float [scale factor][concepts-scale] via `OnPreferredScale()` and Chromium renders to a fractional scale by submitting an oversized buffer and shrinking it with `wp_viewport` (the standard fractional-scale recipe; landed in [Phoronix coverage][phoronix-fractional], background in Igalia's [HiDPI support in Chromium for Wayland][igalia-hidpi]). The advantage over `set_buffer_scale` is that the float scale is sent only when it changes (on display migration/settings change), not per frame.

**The created-at-wrong-scale-then-rescaled problem.** On Wayland a surface does not know its scale until the compositor sends `preferred_scale`/`wl_surface.enter` _after_ first commit, so the first frame can be produced at the wrong scale and re-rendered — `WaylandWindow` recomputes on-screen bounds when `preferred_scale` arrives. X11 learns DPI up front from RandR/Xft, avoiding the round-trip but lacking true per-monitor fractional scale.

**Multi-monitor / window migration.** On Wayland, dragging a window across outputs of different scales triggers a fresh `preferred_scale`, re-rendering at the new factor. There is **no** Windows `WM_DPICHANGED` analogue and no macOS `backingScaleFactor` — scale is purely compositor-driven. A long-standing fractional-scale blurriness bug for floating windows is tracked at [crbug 40934705][crbug-fractional-blurry].

---

## 6. Multi-window & popups

**Popups are `xdg_popup` with grab semantics.** `WaylandPopup` ([`wayland_popup.h`][wayland-popup-h]) wraps an `XdgPopup` created with a parent `WaylandWindow*` and an `xdg_positioner`. Menus/tooltips request an explicit grab (`xdg_popup.grab(seat, serial)`), which gives the [xdg_popup grab][concepts-popup-grab] semantics: the compositor dismisses the whole popup chain on click-outside via `xdg_popup.popup_done` → `OnCloseRequest()` (~line 38). This contrasts sharply with X11, where menus/tooltips are [override-redirect][concepts-popup-grab] windows the client positions absolutely and grabs the pointer itself. `PlatformWindowInitProperties::type` carries `kMenu`/`kTooltip`/`kPopup`/`kBubble` so the backend picks the right native mechanism.

**Modal dialogs, parent/child stacking, groups.** `set_parent_for_non_top_level_windows = true` in `OzonePlatformWayland::GetPlatformProperties` makes Ozone reparent non-toplevels. Toplevel parent/child is `xdg_toplevel.set_parent`; modality and stacking above the parent are then compositor-enforced on Wayland (no client z-control), versus X11's explicit `WM_TRANSIENT_FOR` + `_NET_WM_STATE_MODAL` + restacking. Window groups/workspaces use `wm_class` on X11 and the `WorkspaceExtension` (`GetWorkspace`/`SetVisibleOnAllWorkspaces`, ChromeOS aura-shell) on Wayland.

---

## 7. Threading

**Windows are created and events received on the UI thread.** The `OzonePlatform` UI half (`InitializeUI`) and all `PlatformWindow`/`PlatformWindowDelegate` traffic live on the browser's UI thread, which runs a `base::MessagePumpType::UI` pump. Rendering happens **off** the event thread: the GPU process (`InitializeGPU`) owns buffer allocation and Viz compositing, communicating with the host via Mojo IPC and `WaylandBufferManager`. `PlatformProperties` even lets a backend pick the GPU/viz thread pump type:

```cpp
// ui/ozone/public/ozone_platform.h (PlatformProperties, ~lines 147–156)
// Determines the type of message pump that should be used for GPU main thread.
base::MessagePumpType message_pump_type_for_gpu = base::MessagePumpType::DEFAULT;
// Determines the type of message pump that should be used for viz compositor thread.
base::MessagePumpType message_pump_type_for_viz_compositor =
    base::MessagePumpType::DEFAULT;
```

**The constraint that forced a dedicated Wayland thread.** The interesting per-platform forcing function here is not macOS main-thread AppKit (Ozone is Linux-only) but a libwayland `prepare_read` deadlock between the UI thread and the GPU thread's EGL. Maksim Sisov's CL _"ozone/wayland: watch fd on a dedicated thread"_ ([ozone-reviews][ozone-dedicated-thread], Apr 2021) describes it: when a menu closes, the UI thread calls `wl_display_prepare_read()`, while the GPU thread's vendor EGL driver _also_ calls `wl_display_prepare_read()` during surface teardown; the read-counter cannot drain because the UI thread prepared-but-didn't-read while blocked on IPC waiting for the GPU thread. The fix: a dedicated non-blocking thread always watches the Wayland fd and dispatches back to the UI thread, plus non-default `wl_event_queue`s so toolkit/EGL default-queue reads don't interfere. This is a windowing-layer landmine worth stealing the lesson from.

> [!WARNING]
> **Wayland fd ownership is subtle.** Naively watching the Wayland display fd directly on the UI thread (as X11 does) deadlocks Chromium because in-process GPU + vendor EGL also reads that fd. The dedicated-thread design is a direct consequence of libwayland's single-reader `prepare_read` contract.

---

## 8. Clipboard & DnD

**Cross-platform seam.** `OzonePlatform::GetPlatformClipboard()` returns a `PlatformClipboard`; the Wayland implementation is `WaylandClipboard`.

**Wayland selection model.** `WaylandDataDevice` ([`wayland_data_device.h`][wayland-data-device-h]) wraps `wl_data_device`/`wl_data_offer`/`wl_data_source` and keeps selection and DnD as independent concurrent sessions:

> There are two separate data offers at a time, the drag offer and the selection offer, each with independent lifetimes.

— [`ui/ozone/platform/wayland/host/wayland_data_device.h`][wayland-data-device-h] (~lines 117–119)

Selection set via `SetSelectionSource()`; DnD started via `StartDrag()` (with a `DragDelegate` for `OnDragEnter/Motion/Leave/Drop` and `DrawIcon`). MIME negotiation is the Wayland `wl_data_offer.offer`/`receive` exchange; actual bytes are read over a pipe fd the compositor hands back (implementation in the `.cc`). Drag controller logic is in `wayland_data_drag_controller`.

**X11 selections + INCR.** The X11 path uses the classic ICCCM selection model (`XConvertSelection`/`SelectionNotify`) with the INCR protocol for large transfers, in `ui/base/x` selection code — a fundamentally different, polling-style handshake versus Wayland's fd-passing. (Win32 delayed-rendering and the rest of the cross-platform clipboard live above Ozone in `ui/base/clipboard`.)

---

## 9. Escape hatches

Ozone is a firewall by design, so escape hatches are deliberate and narrow:

- **Native handle access.** `gfx::AcceleratedWidget` (delivered via `OnAcceleratedWidgetAvailable`, retrievable via `PlatformWindow::GetWidget`) is the opaque native handle (X window id; Wayland surface handle to the GPU side) — the [raw-window-handle][concepts-csd] equivalent. The X11 backend additionally exposes `X11Extension`/`WorkspaceExtension` interfaces (`AsWaylandToplevelWindow()` / extension casts) for X-specific behavior the generic contract omits.
- **Per-backend extension interfaces.** `WaylandExtension`, `WorkspaceExtension`, `X11Extension`, `WmMoveResizeHandler`, `WmDragHandler` are mix-in interfaces a `PlatformWindow` subclass implements; callers downcast through accessor methods to reach platform-specific operations (move-loops, workspace pinning) the neutral interface intentionally lacks. The very existence of `X11Extension`/`WorkspaceExtension` documents where the abstraction is known to leak.
- **Raw event passthrough.** Because the backend ultimately calls `PlatformWindowDelegate::DispatchEvent(ui::Event*)`, anything not modeled as a `ui::Event` (some compositor-specific protocol events) has no passthrough — it is handled inside the backend or dropped. There is no public hook to inject into the native message pump from outside Ozone; the pump is Chromium's `base::MessagePump`, extended only via `base::CurrentThread` task posting.

---

## 10. History, redesigns & known regrets

- **Origins (2013–2016): "Interfaces, not ifdefs."** Ozone began as the abstraction to bring Aura to embedded/non-X11 targets; the [design doc][ozone-overview] dates the principle. Early external Wayland work (intel/ozone-wayland) predated the in-tree port.
- **Wayland upstreaming (2016–2020).** Igalia drove the in-tree `ui/ozone/platform/wayland` backend ("Waylandifying Chromium"); the [Igalia blog corpus][igalia-hidpi] tracks HiDPI, IME, and DnD milestones.
- **Ozone/X11 becomes the default and legacy X11 is deleted (2021).** The biggest redesign was migrating X11 itself _onto_ Ozone. Ozone/X11 reached 100% on stable/beta in August 2021, after which the legacy non-Ozone X11 path was deprecated and removed, letting low-level X code move into `ui/ozone/platform/x11`. Coverage: [Phoronix, "Ozone X11 Code Now Fully Enabled, Old Legacy X11 Code To Be Removed"][phoronix-x11], and Maksim Sisov's retrospective [_"Where is Ozone now?"_][igalia-where-ozone] (Dec 2021): _"Recently, the old path has been deprecated and removed,"_ with Wayland then classified as **beta** ("most features implemented") and shipping in automotive/appliance products.
- **The dedicated-thread fd-watch fix (2021).** The [`prepare_read` deadlock CL][ozone-dedicated-thread] is the clearest documented windowing-layer regret/landmine — a non-obvious consequence of libwayland's single-reader contract under in-process GPU.
- **Ongoing rough edges.** Client-side decorations on non-SSD compositors ([crbug 40785698][crbug-csd]); fractional-scale blurriness for floating windows ([crbug 40934705][crbug-fractional-blurry]); text-input-v3 maturation ([crbug 40113488][crbug-text-input-v3]). Wayland remained behind X11 in polish for years, which is itself the headline lesson: a clean abstraction does not make the newest backend mature — protocol gaps (decorations, positioning, scaling) leak through no matter how good the firewall.

---

## Strengths

- **A genuine firewall.** "Interfaces, not ifdefs" keeps a multi-million-line UI codebase ignorant of `wl_surface` vs `xcb_window_t`; new ports touch one centralized layer.
- **Runtime-pluggable, one binary.** `--ozone-platform` selects Wayland/X11/headless at launch; invaluable for testing and distro packaging.
- **Two-process model baked in.** The UI/GPU `InitializeUI`/`InitializeGPU` split cleanly separates windowing from buffer allocation, enabling the sandboxed GPU process.
- **Battle-tested input normalization.** DOM-code/DOM-key + xkbcommon + client-side repeat + dual text-input wrappers is one of the most complete Linux input stacks in any application.
- **Honest about leaks.** Per-backend extension interfaces (`X11Extension`, `WorkspaceExtension`) name exactly where the abstraction is insufficient instead of hiding it.

## Weaknesses

- **Heavyweight.** Ozone only makes sense inside Chromium's `base`/`mojo`/Viz infrastructure; it is not a standalone windowing library you could vendor.
- **Wayland decorations are own-drawn, not libdecor.** Reimplementing CSD in Views causes persistent fit-and-finish bugs on compositors that refuse SSD.
- **No native message-pump escape hatch.** Embedders cannot inject into the loop; everything must become a `ui::Event` or be handled inside the backend.
- **Fractional scaling is fiddly.** The oversized-buffer + viewport recipe and the create-at-wrong-scale round-trip produce blur regressions.
- **Wayland fd handling is a known footgun.** The dedicated-thread deadlock fix shows how unforgiving libwayland's single-reader contract is under in-process GPU.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                              | Trade-off                                                                                        |
| -------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| "Interfaces, not ifdefs" factory (`OzonePlatform`)       | Keep platform-neutral upper layers free of conditional compilation; centralize porting | Indirection cost; the firewall hides capabilities, forcing per-backend extension interfaces      |
| Runtime backend selection (`--ozone-platform`)           | One binary covers Wayland/X11/headless; eases testing & packaging                      | All backends compiled in; larger binary; abstraction must be the LCD of every platform           |
| UI/GPU two-process init (`InitializeUI`/`InitializeGPU`) | Sandboxed GPU; windowing on UI thread, allocation on GPU process                       | Cross-process buffer/handle handoff (`WaylandBufferManager`, Mojo); destruction-ordering hazards |
| Dedicated Wayland fd-watch thread                        | Avoid `prepare_read` deadlock between UI thread and in-process GPU EGL                 | Extra thread + cross-thread dispatch latency; complexity vs X11's direct-on-pump fd watch        |
| Logical (DIP) native unit, pixels at the seam            | Upper layers stay resolution-independent; matches multi-DPI reality                    | Constant DIP↔pixel conversion; first-frame-at-wrong-scale round-trip on Wayland                  |
| Own-drawn Wayland CSD (no libdecor)                      | Consistent Chrome look; full control of titlebar; no extra dependency                  | Reimplements decoration logic; breaks on compositors that enforce SSD; recurring polish bugs     |
| Dual `zwp_text_input_v1`/`v3` wrappers                   | v1 has richer pre-edit styling; v3 is the portable standard                            | Two code paths to maintain; behavior differs per compositor's advertised protocol                |

---

## Verdict: what a new framework should steal / avoid

**Steal.** The factory firewall (`OzonePlatform` + small `PlatformWindow` contract + delegate-callback event direction) is the gold standard for decoupling a large consumer from multiple window systems — far cleaner than `#ifdef` soup. Steal the explicit DIP-vs-pixel boundary on the window contract; the DOM-code + xkbcommon + client-side-repeat input normalization; the dual text-input wrappers; and especially the hard-won lesson that the **Wayland display fd needs a dedicated reader thread** when a GPU/EGL also reads it. Steal naming your leaks (`X11Extension`) instead of pretending the abstraction is complete.

**Avoid.** Don't reimplement CSD by hand if you can integrate libdecor — Chromium's own-drawn path is a maintenance tax. Don't assume a single message loop can host the Wayland fd directly. Don't expect a clean abstraction to make the youngest backend mature: Wayland protocol gaps (positioning, decorations, scaling) leaked through Ozone for years regardless.

---

## Open questions I could not resolve (with where the answer likely lives)

- **Exact current event-watcher class hierarchy.** The `WaylandEventWatcher`/`WaylandEventWatcherFdwatch`/`WaylandEventWatcherGlib`/`WaylandEventWatcherThread` split is referenced by `wayland_event_source.h` and the unittest, but the header path drifted; the authoritative source is [`ui/ozone/platform/wayland/host/wayland_event_watcher*`][srcchromium-watcher] on `source.chromium.org`.
- **Precise fractional-scale buffer-sizing math and rounding.** The viewport-shrink recipe is in `WaylandSurface`/`WaylandWindow` scale handling and [crbug 40934705][crbug-fractional-blurry]; the rounding policy that causes blur is best read from those `.cc` files.
- **Whether any backend exposes a true native-pump escape hatch.** I found none; confirmation would come from the full `OzonePlatform` surface in [`ui/ozone/public/ozone_platform.h`][ozone-platform-h] and the `*Extension` interfaces.
- **X11 INCR selection details.** Stated from ICCCM knowledge; the implementation lives in `ui/base/x` selection code (not fetched here).

---

## Sources

- [chromium/chromium][chromium] — source tree for all quoted file paths (`main`, June 8, 2026)
- [Ozone Overview design doc][ozone-overview] — the "Interfaces, not ifdefs" rationale and `--ozone-platform`
- [`ui/ozone/public/ozone_platform.h`][ozone-platform-h], [`surface_factory_ozone.h`][surface-factory-h] — factory interfaces
- [`ui/platform_window/platform_window.h`][platform-window-h], [`platform_window_delegate.h`][platform-window-delegate-h], [`platform_window_init_properties.h`][platform-window-init-h] — the window contract
- Wayland backend: [`wayland_window.h`][wayland-window-h], [`wayland_toplevel_window.h`][wayland-toplevel-h], [`wayland_popup.h`][wayland-popup-h], [`wayland_surface.h`][wayland-surface-h], [`wayland_event_source.h`][wayland-event-source-h], [`wayland_keyboard.h`][wayland-keyboard-h], [`wayland_pointer.h`][wayland-pointer-h], [`wayland_input_method_context.h`][wayland-ime-h], [`wayland_cursor_shape.h`][wayland-cursor-shape-h], [`wayland_data_device.h`][wayland-data-device-h], [`wayland_frame_manager.h`][wayland-frame-h], [`fractional_scale_manager.h`][fractional-scale-h], [`ozone_platform_wayland.cc`][ozone-platform-wayland-cc]
- X11 backend: [`x11_window.cc`][x11-window-cc], [`x11_event_source.h`][x11-event-source-h], [`x11_event_watcher_glib.cc`][x11-watcher-glib]
- Input infra: [`event_auto_repeat_handler.h`][auto-repeat-h], [`keyboard_layout_engine.h`][keyboard-layout-engine-h]
- Design discussions/CLs: [ozone-reviews: dedicated fd-watch thread][ozone-dedicated-thread], [ozone-reviews: tiled/SSD frame fix][ozone-tiled-fix]
- Issues: [crbug 40785698 (CSD)][crbug-csd], [crbug 40934705 (fractional blur)][crbug-fractional-blurry], [crbug 40113488 (text-input-v3)][crbug-text-input-v3]
- Background: Igalia [_HiDPI support in Chromium for Wayland_][igalia-hidpi], [_Where is Ozone now?_][igalia-where-ozone], [_Event management in X11 Chromium_][igalia-x11-events]; Phoronix [Ozone/X11 default][phoronix-x11], [fractional scaling][phoronix-fractional]
- Protocols: [`wp_fractional_scale_v1`][proto-fractional], [`xdg-decoration-unstable-v1`][proto-xdg-decoration], [`wp_cursor_shape_v1`][proto-cursor-shape]
- Concepts & sibling trees: [concepts][concepts-csd], [ui-layout][ui-layout], [async-io][async-io]

<!-- References -->

[chromium]: https://github.com/chromium/chromium
[srcchromium]: https://source.chromium.org/chromium/chromium/src/+/main:ui/ozone/
[srcchromium-watcher]: https://source.chromium.org/chromium/chromium/src/+/main:ui/ozone/platform/wayland/host/wayland_event_watcher.cc
[ozone-overview]: https://github.com/chromium/chromium/blob/main/docs/ozone_overview.md
[ozone-platform-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/public/ozone_platform.h
[surface-factory-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/public/surface_factory_ozone.h
[platform-window-h]: https://github.com/chromium/chromium/blob/main/ui/platform_window/platform_window.h
[platform-window-delegate-h]: https://github.com/chromium/chromium/blob/main/ui/platform_window/platform_window_delegate.h
[platform-window-init-h]: https://github.com/chromium/chromium/blob/main/ui/platform_window/platform_window_init_properties.h
[wayland-window-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_window.h
[wayland-toplevel-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_toplevel_window.h
[wayland-popup-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_popup.h
[wayland-surface-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_surface.h
[wayland-event-source-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_event_source.h
[wayland-keyboard-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_keyboard.h
[wayland-pointer-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_pointer.h
[wayland-ime-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_input_method_context.h
[wayland-cursor-shape-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_cursor_shape.h
[wayland-data-device-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_data_device.h
[wayland-frame-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/wayland_frame_manager.h
[fractional-scale-h]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/host/fractional_scale_manager.h
[ozone-platform-wayland-cc]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/wayland/ozone_platform_wayland.cc
[x11-window-cc]: https://github.com/chromium/chromium/blob/main/ui/ozone/platform/x11/x11_window.cc
[x11-event-source-h]: https://github.com/chromium/chromium/blob/main/ui/events/platform/x11/x11_event_source.h
[x11-watcher-glib]: https://github.com/chromium/chromium/blob/main/ui/events/platform/x11/x11_event_watcher_glib.cc
[auto-repeat-h]: https://github.com/chromium/chromium/blob/main/ui/events/ozone/keyboard/event_auto_repeat_handler.h
[keyboard-layout-engine-h]: https://github.com/chromium/chromium/blob/main/ui/events/ozone/layout/keyboard_layout_engine.h
[ozone-dedicated-thread]: https://groups.google.com/a/chromium.org/g/ozone-reviews/c/RvBChIZWhDs
[ozone-tiled-fix]: https://groups.google.com/a/chromium.org/g/ozone-reviews/c/GeM7ZzpKYc4
[crbug-csd]: https://issues.chromium.org/issues/40785698
[crbug-fractional-blurry]: https://issues.chromium.org/issues/40934705
[crbug-text-input-v3]: https://issues.chromium.org/issues/40113488
[igalia-hidpi]: https://blogs.igalia.com/adunaev/2020/11/13/hidpi-support-in-chromium-for-wayland/
[igalia-where-ozone]: https://blogs.igalia.com/msisov/where-is-ozone-now/
[igalia-x11-events]: https://blogs.igalia.com/jaragunde/2020/10/event-management-in-x11-chromium/
[phoronix-x11]: https://www.phoronix.com/news/Chrome-Ozone-X11-Future
[phoronix-fractional]: https://www.phoronix.com/news/Chrome-fractional-scale-v1
[proto-fractional]: https://wayland.app/protocols/fractional-scale-v1
[proto-xdg-decoration]: https://wayland.app/protocols/xdg-decoration-unstable-v1
[proto-cursor-shape]: https://wayland.app/protocols/cursor-shape-v1
[concepts-csd]: ./concepts.md#csd-vs-ssd
[concepts-scancode]: ./concepts.md#scancode-keysym-virtualkey
[concepts-logical]: ./concepts.md#logical-vs-physical-coords
[concepts-scale]: ./concepts.md#scale-factor
[concepts-preedit]: ./concepts.md#pre-edit-composition
[concepts-popup-grab]: ./concepts.md#override-redirect-vs-xdg-popup-grab
[concepts-raw-pointer]: ./concepts.md#raw-vs-accelerated-pointer
[concepts-nbnw]: ./concepts.md#no-buffer-no-window
[concepts-frame-callback]: ./concepts.md#frame-callback-vsync
[concepts-readiness]: ./concepts.md#readiness-vs-completion-windowing
[ui-layout]: ../ui-layout/index.md
[async-io]: ../async-io/index.md
