# `sparkles:wsi` — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each milestone ends green, records evidence in
[comparison.md](./comparison.md), and leaves the repository buildable. Feature IDs refer
to [feature-requirements.md](./feature-requirements.md)._

**Last reviewed:** August 20, 2026

## Rules of execution

1. Land small capability slices, not one platform-sized dump. A feature-bearing commit
   updates the comparison matrix in that same commit.
2. Preserve the SDL triangle until the native Wayland path is measured and green; then
   retain SDL as the explicit compatibility backend.
3. Do not begin Graphite integration until every native backend has the full `F01`–`F17`
   contract. This prevents renderer work from fossilizing an incomplete WSI seam.
4. Platform code may reuse OS client libraries but never a cross-platform WSI library.
5. Prefer pure model/translation tests, then automated native harnesses, then the named
   HITL pass. Record which kind proved each claim.

## Milestone overview

| Milestone | Deliverable                                            | Requirements                               | Status      |
| --------- | ------------------------------------------------------ | ------------------------------------------ | ----------- |
| M0        | normative docs, prior-art matrix, cross-spec ownership | `WSI1`–`WSI8`, `INT6`                      | complete    |
| M1        | shared geometry/input/text primitives                  | `WSI8`, `F06`, `F07`, `F11`, `F12`, `INT5` | in progress |
| M2        | Event Horizon/native-loop spikes on all four backends  | `WSI3`, `WSI4`, `F03`–`F05`, `F17`         | in progress |
| M3        | package core and lifecycle (`F01`–`F05`, `F17`)        | `WSI1`–`WSI6`, `F01`–`F05`, `F17`, `INT1`  | in progress |
| M4        | input, DPI, outputs, capture and cursors               | `F06`–`F12`                                | in progress |
| M5        | decorations, state, popup, clipboard and DnD           | `F13`–`F16`                                | planned     |
| M6        | SDL compatibility and Vulkan bridge                    | `WSI7`, `INT2`                             | planned     |
| M7        | Skia Graphite native and SDL hosts                     | `INT3`                                     | planned     |
| M8        | `ui-app` configurations and migration                  | `INT4`, `INT5`                             | planned     |
| M9        | Win32 TSF                                              | `POST1`                                    | deferred    |

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

The native Wayland triangle is M3's first renderer consumer. Extract no public package
from the example until its immediate configure acknowledgement and live-resize trace
match the measured target in the
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
`CPS_COMPLETE`/`GCS_RESULTSTR` round trip. Logical key translation, candidate-window
placement, raw input, pointer/cursor/DPI/output work, the other three platform input
adapters, and native-Windows evidence remain.

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
macOS uses the handle probe here but Metal in M7.

## Milestone M7 — Skia Graphite

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
| `gui-skia`     | native WSI + Graphite; default GUI                          |
| `gui-skia-sdl` | SDL compatibility WSI + Graphite                            |
| `gui-raylib`   | existing raylib host                                        |
| `full`         | TUI plus all GUI choices used by development/gallery builds |

The application continues to call one `runApp`; backend selection stays in the host.
The GPU arm uses Event Horizon readiness/frame opportunities rather than a private poll
or sleep loop.

Gate: UI Gallery and representative hue/terminal flows run through recording, TUI,
native Graphite, SDL Graphite, and raylib as applicable; application modules do not
import WSI, SDL, Vulkan, Metal, or Skia.

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
Windows behavior. Native Windows CI closes those gaps.

### macOS remotely

Never modify `/Volumes/Dev/repos/mine/sparkles`. Inspect existing worktrees with:

```bash
ssh mac-bsn -- git -C /Volumes/Dev/repos/mine/sparkles worktree list
```

Create/use the dedicated `/Volumes/Dev/repos/mine/sparkles-ui-skia` worktree, sync a
commit or patch there, and run the platform tests through Nix because a bare `ldc2` is
not installed. Record the exact Darwin version and architecture with the evidence.
