# `sparkles:wsi` — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone ends green, records evidence in
[comparison.md](./comparison.md), and leaves the repository buildable. Feature IDs refer
to [feature-requirements.md](./feature-requirements.md)._

**Last reviewed:** September 5, 2026

## Rules of execution

1. Land small capability slices, not one platform-sized dump. A feature-bearing commit
   updates the comparison matrix in that same commit.
2. Preserve the SDL triangle until the native Wayland path is measured and green; then
   retain SDL as the explicit compatibility backend.
3. Renderer work must not fossilize an incomplete WSI seam. Graphite work that does not
   touch the seam (the Nix Skia build, `extern(C++)` bindings, offscreen render/readback
   goldens, the `sparkles:ui` canvas adapter) may proceed in parallel at any time; the
   presentation host may begin once the renderer-facing subset — `INT1`/`INT2` handles
   and Vulkan bridge, `F01` first frame, `F02` resize, `F04` frame pacing, `F08`
   scale — is verified on the platform in question, which it now is on all four at the
   partial level the evidence log records. MG's full acceptance gate (goldens,
   interactive resize, DPI, device loss) is unchanged. M7 brings the `INT5` adapter and
   one native configuration, `gui-vulkan`, forward for the terminal; M8 completes the
   configuration set and the migration.
4. Platform code may reuse OS client libraries but never a cross-platform WSI library.
5. Prefer pure model/translation tests, then automated native harnesses, then the named
   HITL pass. Record which kind proved each claim.
6. Behavior assertions are written once, in `sparkles.wsi.conformance`, against the
   value-level contract, and every implementation — the four native backends and the
   recording fake — runs the same suite. A platform smoke is a thin driver supplying
   only what that platform alone can (its wait step, out-of-band triggers, key
   injection); platform-only channels (IMM32) are explicit addenda, and a backend that
   cannot trigger a behavior skips that property rather than weakening it.

## Milestone overview

| Milestone | Deliverable                                            | Requirements                               | Status      |
| --------- | ------------------------------------------------------ | ------------------------------------------ | ----------- |
| M0        | normative docs, prior-art matrix, cross-spec ownership | `WSI1`–`WSI8`, `INT6`                      | complete    |
| M1        | shared geometry/input/text primitives                  | `WSI8`, `F06`, `F07`, `F11`, `F12`, `INT5` | in progress |
| M2        | Event Horizon/native-loop spikes on all four backends  | `WSI3`, `WSI4`, `F03`–`F05`, `F17`         | in progress |
| M3        | package core and lifecycle (`F01`–`F05`, `F17`)        | `WSI1`–`WSI6`, `F01`–`F05`, `F17`, `INT1`  | in progress |
| M4        | input, DPI, outputs, capture and cursors               | `F06`–`F12`                                | in progress |
| M5        | decorations, state, popup, clipboard and DnD           | `F13`–`F16`                                | in progress |
| M6        | SDL compatibility and Vulkan bridge                    | `WSI7`, `INT2`                             | in progress |
| M7        | native Vulkan canvas and the terminal on it            | `INT5`, `INT4` (`gui-vulkan`)              | in progress |
| MG        | Skia Graphite native and SDL hosts                     | `INT3`                                     | planned     |
| M8        | `ui-app` configurations and migration                  | `INT4`                                     | planned     |
| M9        | Win32 TSF                                              | `POST1`                                    | deferred    |
| MA        | Android backend                                        | `POST2`, `F16`                             | in progress |

## Milestone M0 — specification and evidence baseline

Deliver:

- this normative tree (`SPEC`, plan, requirements, comparison, open issues);
- cross-links from Event Horizon, UI input/backends, UI App, the SDL resize handoff,
  and the research synthesis/recommendations;
- pinned source revisions for GLFW, raylib, SDL3, SFML, Qt QPA, Gio, winit,
  raw-window-handle and OpenTK 5;
- explicit ownership/reuse findings for existing `sparkles:*` packages.

Gate: docs sidebar/link/build checks pass. No implementation cell says `partial` or
`verified` merely because a dependency or research example already implements it.

## Milestone M1 — shared foundations

Make the common types genuinely common before WSI copies them:

1. alias `sparkles.input.events.PointF` to `ScreenPosition!float` and prove source and
   ABI expectations in tests;
2. expose canonical `PointerShape` through `sparkles:input` while retaining its
   leaf definition in `sparkles:base` (moving the definition upward would create
   the forbidden base↔input dependency cycle);
3. move `CellMetrics` and pixel-to-cell conversion from the SDL/raylib producers into
   one pure input helper;
4. add allocation-conscious UTF-8/UTF-16 conversion to `sparkles:base`, with malformed
   sequence, embedded-NUL, surrogate and bounded-buffer tests (**complete**);
5. add lossless physical/logical key, composition, scroll source/unit/phase, and target
   capability values without breaking the existing simplified toolkit events.

Gate: `dub test :base`, `:input`, `:ui-raylib`, and `:ui-sdl3` pass in their supported
configurations; no downstream package owns a duplicate of the moved primitive.

## Milestone M2 — native-loop spikes

Prove the only uncertain integration seam before building full backends. Each spike
opens a minimal native window, queues a native event, runs a concurrent Event Horizon
timer and wake, and shuts down without a second blocking loop.

| Spike   | Required proof                                                                             |
| ------- | ------------------------------------------------------------------------------------------ |
| Wayland | prepare-read/flush/read/dispatch over `OpPollAdd`; cancellation repairs prepare-read state |
| X11     | non-blocking XCB drain over the connection fd; XIM bridge does not introduce its own wait  |
| Win32   | `PeekMessage` drain progresses beside IOCP; move/size modal loop still wakes and queues    |
| AppKit  | `CFRunLoopSource`/observer plus kqueue waker coexist on the main thread                    |

The OS-owned-loop half of M2 is delivered on both platforms: Win32 combines User32
with an IOCP completion-mirror event; AppKit wraps Event Horizon's native kqueue
descriptor in a `CFFileDescriptor` source in the main CFRunLoop. Their platform
smokes each run a real window lifecycle, timer, and foreign-thread waker without a
polling timeout or second scheduler. Both Linux foreign-fd lifecycles are delivered:
X11 drains one XCB connection around `OpPollAdd`; Wayland asynchronously discovers
globals, pairs every successful `prepare_read` with `read_events` or `cancel_read`,
handles flush backpressure, and acks configure inside the listener. Their Xvfb and
headless-Weston smokes run resize/configure beside the same timer and waker. XIM still
has to prove that it preserves X11's single connection/event queue.

If an Event Horizon generic native-host primitive is missing, add the smallest
backend-neutral operation there and update its spec. Do not put a second IOCP, kqueue,
timer wheel, channel, or worker scheduler in WSI.

Gate: each spike has a deterministic core test and a platform-labelled executable
result. Any unresolved integration issue moves to [open-issues.md](./open-issues.md)
before M3.

## Milestone M3 — package core and window lifecycle

Add `libs/wsi` to the monorepo with `types`, `events`, `handles`, `loop`, a fake/recording
backend for tests, and the four platform modules. Implement in vertical feature slices:

1. `F17` ownership, generation ids, command queue, non-reentrant drain and shutdown;
2. `F01` create/ready/first metrics/native handle/first frame;
3. `F02` continuous resize and zero-size suspension;
4. `F03` modal-loop survival;
5. `F04` native frame opportunity plus `Ticker` fallback;
6. `F05` readiness, wake and external Event Horizon work.

The native Wayland surface probe is delivered as M3's first renderer consumer. It
exposed and fixed the shared-display rule: Mesa Vulkan WSI calls run while the backend's
prepared read is synchronously cancelled, then Event Horizon is re-armed. The full
triangle stays gated on immediate configure acknowledgement and a live-resize trace
matching the measured target in the
[SDL handoff](../ui-sdl3/native-wayland-resize-handoff.md).

Gate: all four platform columns for `F01`–`F05` and `F17` are verified; typed handles
are exercised by a minimal native surface probe; resize and wake traces contain no
unbounded native wait.

## Milestone M4 — input, scale and outputs

Implement `F06`–`F12` one cross-platform semantic at a time. Windows IME is IMM32 in
this milestone. The common event contract must be rich enough for TSF later without a
breaking change.

The first Win32 input slice is delivered: scan-code/VK key transitions, UTF-16
`WM_CHAR` commits, and allocation-bounded IMM32 pre-edit attributes/cursor/result
translation. Wine/Xvfb exercises a real `SCS_SETSTR` → `GCS_COMPSTR` →
`CPS_COMPLETE`/`GCS_RESULTSTR` round trip. The matching X11 slice queues
evdev-keycode identity, left/right/numpad location, core-state-mask modifiers and
press/repeat/release, with XKB detectable auto-repeat requested so a held key
repeats without synthesized releases; an XTEST-injected shift-chorded key runs
through the real server under Xvfb. The Wayland slice binds `wl_seat`, tracks
capability arrival and departure, consumes the keymap fd, derives keyboard
focus from enter/leave, and queues press/release with the same shared
evdev-location and xkb-real-modifier policy; its evidence lane chords through
Xvfb → Weston's X11 backend → `wl_keyboard`, with the smoke mapping a real shm
buffer under the native-I/O borrow because compositors only focus mapped
surfaces. The AppKit slice completes the four-platform physical-keyboard
contract: the content view accepts first-responder status, `keyDown`/`keyUp`
carry Carbon virtual keycodes with repeat identity, and modifier keys arrive
through `flagsChanged` with press/release derived from the event's own flag
state; a synthetic shift-chorded key posted through the real responder chain
verifies it on macOS. Logical keys are delivered on all four backends at the
layout's unshifted base level, matching `sparkles:input`'s `unshifted`
convention: xkbcommon compiles the Wayland keymap fd (previously just closed)
and the X11 core device's map, Win32 asks the layout via `MAPVK_VK_TO_CHAR`,
and AppKit reads `charactersIgnoringModifiers` with function keys kept as
named private-range scalars; the conformance chord now asserts the
layout-derived spelling on every platform. The pointer slice delivers
button/motion/enter/leave and scroll on all four backends under one sign
convention (positive scrolls down/right): Wayland accumulates axis events
per frame with `axis_source`/`axis_discrete` and acquires/releases the seat
pointer with the keyboard; X11 translates core buttons with the legacy
wheel mapping; Win32 pairs `WM_MOUSEMOVE` entry with `TrackMouseEvent`
leave and flips wheel deltas; AppKit hit-tests through the real responder
path (with `acceptsFirstMouse` so an inactive window's activating click is
still delivered) and reports precise deltas with the natural-direction
flag. The conformance click and scroll properties inject through XTEST,
`SendMessageW`, posted `NSEvent`s, and the external Weston lane — which
moved to the kiosk shell, because this Weston's desktop-shell
click-to-activate binding crashes on a null pointer focus in the headless
environment. The key-repeat slice closes Wayland's repeat gap: repeats never
travel on the wire, so the backend synthesizes `KeyAction.repeat` from the
compositor's `repeat_info` schedule with a single Event Horizon timer op in
flight (retarget and teardown reap it deterministically), and a shared
hold-a-repeating-key conformance property verifies the platform repeat
channel on X11 (detectable auto-repeat under Xvfb) and the synthesized one
through the kiosk-Weston lane, where Weston filters the X server's own
repeat so every observed repeat is the client's. The Wayland text-input
slice starts F07's third column: `zwp_text_input_manager_v3` binds whenever
the compositor offers it (the manager and the seat arrive in either
registry order), the per-seat text input auto-enables on the compositor's
enter — the always-on role IMM32 already plays — and the double-buffered
protocol state is applied as one pure batch on `done`: commit string before
the new pre-edit, byte-offset cursor/selection mapped to the shared
composition vocabulary with the conventional underline segment, and an
active composition ended by exactly one empty event. The batch and mapping
semantics are model-tested; live compositor IME evidence is owed to a
text-input-v3 compositor, because this Weston implements only text-input-v1
and never advertises the v3 manager. The XIM slice closes M2's last open
integration question the right way round: XIM is an Xlib API, but
xcb-imdkit's client speaks the XIM wire protocol over the backend's one XCB
connection — `xcb_xim_filter_event` consumes its ClientMessages inside the
ordinary pump, so the hosted single wait stays the only wait. With a live
per-window input context every key forwards to the input method first and
either commits (queued as `TextCommittedEvent`, UTF-8 negotiated and
validated) or bounces back through the unchanged delivery path; without a
server on `$XMODIFIERS` nothing changes. The evidence is end-to-end: the
lane runs an in-tree test XIM server (xcb-imdkit's server API) that commits
for one keycode and bounces everything else, so the chord, hold, and
repeat properties incidentally prove the bounce path while the new IME
property proves the commit path. The NSTextInputClient slice completes the
F07 column set: the content view adopts the protocol (registered through
the Objective-C runtime, since `extern (Objective-C)` has no adoption
syntax and NSView's input context is nil without conformance), keyDown
routes every event through the input context after the physical key, and
text arrives only as protocol calls — `insertText` commits validated
UTF-8 and ends marked text, `setMarkedText` maps AppKit's UTF-16-unit
selection to byte offsets with underline and selected segments. The shared
IME-commit property runs on AppKit (a posted key comes back as committed
text through the real input context) and an addendum drives the
marked-text contract exactly as the input context does. Keymap-change
events, callback-style XIM pre-edit, candidate-window placement, and raw
input remain. The modal-loop slice makes F03 real on the two platforms
whose native loops steal the thread: Win32 arms a USER timer on entering
move/size and menu loops, and its `WM_TIMER` handler — which those loops
do dispatch — drives one non-blocking Event Horizon drain, while AppKit's
kqueue source already lives in the common run-loop modes and now drives
the drain itself whenever it fires outside this host's own wait (live
resize, menu tracking, modal sessions), re-arming its one-shot callback.
Both learn which loop drives them by presence (`noteHostLoop` in
`runHostedOnce`). The conformance property is built not to pass vacuously:
a timer armed before the phase must fire during it, its completion is the
only thing that ends the phase, and `enterModalPhase` blocks for the
phase's whole duration — which is how the property caught Wine's `SC_MOVE`
never entering a loop (the driver runs `TrackPopupMenu`'s real menu loop
instead), caught the wiring hole where a backend whose properties were
all satisfied synchronously had never run its hosted wait, and caught that
kqueue hands armed ops to the kernel only at the next wait — so the
property steps once between arming and the phase, the shape a real app
has, and AppKit's `stopModal` needs a posted wake event when called from
a source callout. Interactive move/size traces and dialog loops
(`WM_ENTERIDLE`) remain. Two UAT-driven additions follow: `wsi-input-echo`
(`libs/wsi/examples/`) opens one window on the platform's native backend
and prints every queued event - the standing interactive acceptance
program, and the vehicle for the owed live-IME runtime evidence on a
text-input-v3 compositor - and F13's first sliver,
`startInteractiveMove`/`startInteractiveResize` over `xdg_toplevel`'s
move/resize with the shared `ResizeEdge`/`resizeEdgeAt` affordance,
because GNOME draws no server decorations and a bare toplevel is
otherwise unmovable and unresizable there; the native triangle and the
echo both grow border-drag resize and alt-drag move on it. The scale slice makes
`SurfaceMetrics` real on Wayland: outputs are bound with their scales, each
window's scale is the maximum of its entered outputs, a change requests the
matching buffer scale and reports one atomic metrics transition — verified at
scale 2 through the kiosk-Weston lane, where the chord, click, and scroll
properties also still pass. Win32's existing `GetDpiForWindow` path keeps its
Wine caveat: a per-monitor-V2-aware window under Wine always sees a 96-DPI
monitor whatever `LogPixels` says, so that column's scale evidence is owed to
native Windows CI. The cursor slice puts the shared `PointerShape` vocabulary — CSS names, so
Wayland's `cursor-shape-v1` maps one-to-one — behind `setCursor` and
`setCursorVisible` on all four backends, with a conformance property that
requires a standard shape to apply or fail with typed `unsupported`, plus
platform-observable confirmation where one exists (`GetCursor` after
`WM_SETCURSOR` under Wine, `NSCursor.currentCursor` on macOS). The
cursor-shape protocol is vendored beside xdg-shell with its single unused
tablet request stubbed rather than pulling in the tablet-v2 tables. The drag slice
delivers F10's release-preservation half: Win32 gains implicit capture —
User32 stops delivering client messages at the border without it — spanning
the first press to the last release and unwound on `WM_CAPTURECHANGED`, while
X11's automatic core grab and AppKit's window drag routing are verified
rather than assumed; the conformance drag property requires the release to
arrive with outside coordinates. The explicit-capture slice completes F10's
vocabulary: `setPointerCapture` takes a `PointerCaptureMode` (`capture`,
`confine`) and `setRelativePointer` switches a separate delta stream, each
backend answering typed `unsupported` where the platform has no such thing
rather than pretending — X11 grabs (with `confine_to`) and XInput 2
`RawMotion`, Wayland `pointer-constraints-v1` confinement and
`relative-pointer-v1` deltas with capture refused (the compositor owns
grabs), Win32 `SetCapture` held past the buttons, `ClipCursor` re-clipped on
move/size and lifted on focus loss, and Raw Input `WM_INPUT` deltas, AppKit
the event deltas with both capture modes refused. Three conformance
properties drive real pointer motion (a warp or an injected move, never a
posted message) and time out rather than pass vacuously when nothing is
routed. X11 scale detection, custom cursor images, full output
enumeration/hotplug, and native-Windows evidence beyond the hosted runner
remain.

Required platform paths:

- Wayland: xkbcommon, text-input-v3, fractional-scale/viewporter, seat capability
  changes, relative-pointer and pointer-constraints;
- X11: xkbcommon-x11, XIM, RandR, grabs/XI2 raw motion where available;
- Win32: scan code/VK separation, `WM_CHAR`/`WM_UNICHAR`, IMM32 composition,
  Per-Monitor-V2, raw input and capture;
- AppKit: key codes plus `NSTextInputClient`, backing conversion, display changes,
  tracking/raw delta behavior.

Gate: recorded cross-backend event fixtures agree on the common semantics while
retaining platform-specific codes; native layout/IME/mixed-DPI/capture/cursor passes are
recorded in the matrix.

## Milestone M5 — shell integration

Implement `F13`–`F16` in four vertical slices: decorations, state/close, grabbed popup,
then clipboard/DnD. Large transfer paths must stream through Event Horizon rather than
blocking the UI thread.

Wayland CSD is renderer-owned and protocol-driven: WSI supplies frame regions/actions,
never a libdecor dependency. X11 selection tests include `INCR`; Win32 OLE runs on the
STA UI thread; AppKit pasteboard promises do not call application code re-entrantly.

Gate: the full `F01`–`F17` matrix is verified across four native backends. This is the
entry condition for renderer integration.

Delivered slice: the clipboard (`DT1`–`DT5`) on all four backends, each lane
round-tripping 32 MiB through the platform and reading another writer's text.
Drag-and-drop, decorations, window state and the grabbed popup remain.

## Milestone M6 — compatibility and Vulkan

1. Factor a small host concept from WSI without weakening native semantics.
2. Implement it in `sparkles:wsi-sdl3`; unsupported SDL public semantics remain
   explicitly degraded.
3. Add `sparkles:vulkan-wsi`: reuse `sparkles:vulkan` commands/types and extract
   `FrameSync`, `Swapchain`, context selection, tracing, and resource retirement from
   `sparkles:ui-sdl3`.
4. Drive the same Vulkan triangle on native WSI and SDL compatibility, with backend
   selection explicit at build/configuration time.

Gate: Vulkan validation clean on Wayland, X11, Win32/Wine and native Windows CI; native
macOS uses the handle probe here but Metal in MG.

Delivered slices: target-native surface ABI/dispatch in `sparkles:vulkan`, typed
handle-pair validation, instance/surface/device ownership in `sparkles:vulkan-wsi`, and
a headless-Weston Wayland-to-present-device smoke; then the proven `CommandPool`,
`FrameSync`, `Swapchain`, resize decisions, and deferred-retirement policy were moved
from SDL into that bridge. The SDL module names are compatibility re-exports and its
existing triangle builds unchanged against the shared implementation. The renderer
half of that triangle is promoted to `sparkles.vulkan_wsi.triangle`, and the native
Wayland triangle drives it through `sparkles:wsi` and Event Horizon alone — no SDL
or libdecor in the process — presenting under sync validation with compositor
resize, with the native-I/O borrow widened to cover acquire and present. The X11
and Win32 runtime surface probes drive the live ICD through the same typed
handles: XCB under Xvfb and winevulkan under Wine both create a real surface,
select a present-capable device (falling through to lavapipe where hardware
ICDs cannot present), and prove the integrated wait still dispatches after the
driver ran. The Wayland presentation gate is scripted: Weston's X11 backend
inside Xvfb with the client pinned to lavapipe presents the full stress run
under sync validation without a live desktop session (headless Weston loses
the surface, and a hardware ICD's dmabufs crash a software Weston — the
windowed backend avoids both), and the triangle now reports the SDL handoff's
comparison counters (`framesOver50ms`/`framesOver100ms`, `reaps`,
`maxDispatchMs`) so the HITL run can be read against the measured target in
one glance. The HITL live-resize trace itself remains; native Windows CI landed
as the `windows-latest` leg of the test matrix, which runs `dub test :wsi` and
the Win32 conformance driver on a real User32/IOCP — a 96-DPI, IME-less runner,
so per-monitor scale and IME automation still wait for a host that has them.

## Milestone M7 — the native Vulkan canvas

The toolkit and the terminal draw with Vulkan on `sparkles:wsi`, through
`sparkles:ui-vulkan` and a native `sparkles:ui-app` arm: the Linux desktop
first, the phone terminal of MA slice 4 last. Its specification, slices and
gates are owned by [`sparkles:ui-vulkan`](../ui-vulkan/PLAN.md); this plan does
not repeat them. Skia Graphite follows as milestone MG, a second canvas behind
the same seam ([UVX1](../ui-vulkan/decisions.md#uvx1-a-native-vulkan-renderer-before-skia-graphite)).

## Milestone MG — Skia Graphite

Add `sparkles:ui-skia` over the existing Nix Skia build:

- Graphite Vulkan on Linux and Windows;
- Graphite Metal on macOS;
- shared canvas/text/resource policy independent of the WSI implementation;
- SDL host only in a separate compatibility configuration.

Gate: render/readback goldens plus interactive resize, DPI and device-loss/recreation
passes. No Graphite type crosses into `sparkles:wsi`.

## Milestone M8 — application host

Replace `ui-app`'s generic `gui` configuration with the explicit set:

| Configuration  | Backend closure                                             |
| -------------- | ----------------------------------------------------------- |
| `tui`          | `ui-tui` only                                               |
| `gui-vulkan`   | native WSI + `sparkles:ui-vulkan`; default GUI              |
| `gui-skia`     | native WSI + Graphite                                       |
| `gui-skia-sdl` | SDL compatibility WSI + Graphite                            |
| `gui-raylib`   | existing raylib host                                        |
| `full`         | TUI plus all GUI choices used by development/gallery builds |

The application continues to call one `runApp`; backend selection stays in the host.
The GPU arm uses Event Horizon readiness/frame opportunities rather than a private poll
or sleep loop.

Gate: UI Gallery and representative hue/terminal flows run through recording, TUI,
native Vulkan, native Graphite, SDL Graphite, and raylib as applicable; application modules do not
import WSI, SDL, Vulkan, Metal, or Skia.

## Milestone MA — Android backend

Android joins as a fifth native backend because a phone terminal is one of the
library's main consumers (`POST2`). It is developed alongside the desktop
milestones rather than after them. The backend owns the native activity
without raylib's glue: the activity's callbacks run on the Java main thread and
hand values to the WSI thread, which runs Event Horizon. JNI goes through
`sparkles:android`'s worker thread.

1. **Clipboard and the skeleton.**
   - Clipboard API and its recording implementation, with the conformance
     properties for `DT1`–`DT5`.
   - `sparkles:android` takes the activity from its own `onCreate` entry,
     not from raylib.
   - The backend skeleton: entry point, one window over the activity's
     `ANativeWindow`, lifecycle and focus events, typed handles, `BackendKind`.
   - The Android clipboard over `ClipboardManager`.
   - Evidence: a test APK on the emulator runs the shared conformance suite and
     the clipboard round trip.
2. **Input.** Keys and text through `AInputQueue` and the IME bridge; touch as
   pointers with the `ED3` sample history.
3. **Scale and insets.** Density, content rect and window insets as surface
   metrics.
4. **Vulkan, then the terminal, on the backend.**
   - `VK_KHR_android_surface` in `sparkles:vulkan` and `sparkles:vulkan-wsi`,
     and a diagnostic test pattern presenting on the backend through a
     pre-rotated swapchain.
5. **Process-lifetime ownership and pacing** (§10.1).
   - One WSI owner thread per process; the window outlives activities, and an
     activity ending or a return is a surface lost or gained.
   - `MemoryPressureEvent` from the platform's low-memory call.
   - `VulkanDevice` (process) and `WindowSurface` (surface) in
     `sparkles:vulkan-wsi`, with a pipeline cache persisted to a path the
     application chooses.
   - Frame opportunities from `AChoreographer`, so a renderer draws once per
     display frame and nothing while it has no surface.
   - The test pattern shows it: device and pipelines kept across surfaces and
     activities, released on memory pressure, or optionally whenever the
     surface goes.

Gate for slice 1: the emulator lane (`libs/wsi/scripts/verify-android-emulator.sh`)
passes the shared conformance suite and the clipboard suite, and refuses a clip
past one Binder transaction with `capacity`; `comparison.md` records the run.

Gate for slice 2: the same lane injects keys as evdev events on the
emulator's keyboard and pointers through `input`, and the shared suite passes
its chord, held-key repeat, IME commit, click and scroll properties; a touch
drag arrives as one contact whose samples are all in the `ED3` history ring.

Gate for slice 3: the lane turns the display and changes its density; the
surface's metrics follow both in one event each, with the system bars' insets in
`safeInsets`. The soft keyboard's inset is read the same way but stays
unverified there: the hardware keyboard the lane injects through keeps Gboard
from showing one.

Gate for slice 4's Vulkan half: after the smoke, the lane runs
`libs/vulkan-wsi/scripts/verify-android-test-pattern.sh`, which presents the test
pattern through `VK_KHR_android_surface` with a pre-rotated swapchain and checks
a screen capture in portrait, turned to landscape and back: corners, safe-area
border, inset hatch, and an unstretched layout. The same script passes on a
phone without root. The terminal half is `sparkles:ui-vulkan`'s slice V7: the
terminal runs on the backend on a phone and on the emulator.

Gate for slice 5: the test pattern logs each launch's timing (instance, device,
pipelines, swapchain, first present); a relaunch in a running process and a
return from the background create neither a device nor a pipeline, and a launch
after the process was killed compiles no pipeline the cache holds. While the
window has no surface the app presents nothing, and while visible it presents
once per display frame. Measured on the emulator and a phone.

## Milestone M9 — TSF (deferred)

Implement TSF as the second Win32 text-service backend after the desktop/renderer/host
stack is stable. Preserve the M4 composition values and application contract; compare
IMM32 and TSF under native Windows automation. Keep IMM32 available as a compatibility
fallback only if evidence shows it is required.

## Platform verification recipes

### Windows locally

Use `nix develop .#win32` from `nix/shells/win32-cross.nix`, compile through
`win32-ldc2`, and use a fresh `WINEPREFIX` for each lane. Run direct `wine64` processes,
not Explorer virtual desktops:

- `winewayland` for the Wayland display path;
- Xvfb plus winex11 for the X11 display path.

Record Wine results as compatibility evidence, not proof of undocumented native
Windows behavior. The `windows-latest` test leg (`ci/test-windows.sh` plus the
driver step in `.github/workflows/ci.yml`, mirrored by CircleCI's
`test-windows`) runs the same `win32-hosted-smoke.d` recipe natively and is the
evidence of record for what User32 does; Wine keeps the IMM32 preedit phase, which
the hosted runner's IME-less layout never shows; the result-string commit is native
evidence.

### macOS remotely

Never modify `/Volumes/Dev/repos/mine/sparkles`. Inspect existing worktrees with:

```bash
ssh mac-bsn -- git -C /Volumes/Dev/repos/mine/sparkles worktree list
```

Create/use the dedicated `/Volumes/Dev/repos/mine/sparkles-ui-skia` worktree, sync a
commit or patch there, and run the platform tests through Nix because a bare `ldc2` is
not installed. Record the exact Darwin version and architecture with the evidence.
