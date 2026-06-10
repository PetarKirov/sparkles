# Platform Windowing API Research — Parallel Demo Program Plan

## Mission

Build a matrix of small, focused demo programs that exercise the windowing/input APIs of **Wayland, X11, Win32, and macOS (AppKit)** directly — no frameworks, no abstraction layers — to empirically map where the platforms diverge. The output is (a) working reference code per platform per feature, (b) measured/observed behavior recorded in a shared findings matrix, and (c) a final synthesis that pairs with the framework source-code study (`windowing-research-prompt.md`) to drive the design of our windowing layer.

**Language policy:** C for Wayland/X11/Win32 demos, Objective-C (or C calling Objective-C runtime) for macOS. No helper libraries except: `libwayland-client`, `wayland-protocols`, `xkbcommon`, `libxcb`/`Xlib`, and platform SDKs. The point is to touch the raw API.

## Repository layout

All work happens in one repo (create it if absent): `$REPOS/schelling-point/windowing-demos`

```
windowing-demos/
  common/                  # shared spec, logging helpers (header-only, per-platform impls)
    spec/                  # the feature specs below, one file per feature (F01..F17)
    instrument.h           # timestamped event logging in a COMMON FORMAT (see Instrumentation)
  wayland/
    scaffold/              # W0 output: connect, registry, xdg-shell window, shm buffer, frame loop
    f01-first-pixel/ ... f17-threading/
  x11/      (same structure)
  win32/    (same structure)
  macos/    (same structure)
  findings/
    matrix.md              # the per-platform × per-feature grid (template below)
    <platform>/<feature>.md
  flake.nix                # dev shells: linux (wayland+x11+xkbcommon+weston+xvfb), win32 cross (mingw64), macos stub
  ci/                      # build-all scripts per platform
```

Each demo is a **single small program** (≤ ~500 LOC target) that exercises exactly one feature cluster on top of its platform scaffold. Scaffold code is copied, not shared as a library — duplication is fine; isolation and readability win.

## Verification tiers (agents must label every result)

- **Tier A — built and run by agent.** Wayland demos run under `weston --backend=headless` (and `WAYLAND_DEBUG=1` captures the protocol trace — attach it to findings). X11 demos run under `Xvfb` (+ `xtrace` for protocol capture). Behavioral findings from headless runs are valid for protocol behavior, NOT for visual/interactive behavior.
- **Tier B — cross-compiled, not run.** Win32 demos must compile with `x86_64-w64-mingw32-gcc` from the Nix shell. macOS demos must at minimum pass `clang -fsyntax-only` against bundled SDK headers if no macOS builder is available.
- **Tier C — requires manual run.** Every demo prints its findings checklist to stdout and writes the instrumentation log; agents produce a `MANUAL-RUN.md` per Tier-C demo listing the exact steps and expected observations for Petar to execute on real Windows/macOS machines and real compositors (mutter, kwin, sway). **Never report Tier B/C behavior as observed fact — mark it `[expected, unverified]` in the matrix.**

## Instrumentation (uniform across all demos)

Every demo logs to stderr in this exact format so traces are diffable across platforms:

```
<monotonic_us> <DEMO> <EVENT_KIND> key=value key=value...
```

Mandatory events: `init_start`, `window_created`, `first_configure` (or equivalent), `first_pixel_presented`, `resize size=WxH scale=S`, `key code=.. sym=.. text=..`, `pointer ...`, `scale_changed`, `close_requested`, `frame_callback t=..`. Demo F01 establishes the format; all others reuse `common/instrument.h`.

Additionally every demo records: **concept count** (number of distinct platform objects/handles touched before first pixel) and **LOC** — these go in the matrix header row.

---

## Phase 0 — Orchestrator setup (you, before fan-out)

1. Create the repo skeleton above, write `flake.nix` with the three dev shells, commit.
2. Copy the feature specs (section below) into `common/spec/F01..F17.md` verbatim.
3. Create `findings/matrix.md` from the template at the bottom.
4. Verify the Linux shell can run `weston --backend=headless` and `Xvfb`, and that `x86_64-w64-mingw32-gcc` links a trivial `WinMain`. Fix the flake until true.

## Phase 1 — Scaffolds (4 parallel agents, one per platform)

| Agent          | Task                                                                                                                                                                                                               |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **W0**         | Wayland scaffold: registry, `xdg_wm_base`, toplevel, `wl_shm` double buffer, configure/ack/commit loop, frame-callback redraw, clean teardown. Run under headless weston with `WAYLAND_DEBUG=1`; commit the trace. |
| **X0**         | X11 scaffold via **xcb**: connection, window, `WM_PROTOCOLS`/`WM_DELETE_WINDOW`, MIT-SHM image presentation, event loop on the connection fd.                                                                      |
| **N0** (win32) | Win32 scaffold: `RegisterClassEx`, `CreateWindowEx`, message pump, DIB section + `BitBlt` on `WM_PAINT`. Tier B compile; write MANUAL-RUN.md.                                                                      |
| **M0**         | macOS scaffold: `NSApplication` with explicit activation policy, `NSWindow`, custom `NSView` drawing a CPU buffer via `CGContext`, run loop. Tier B/C.                                                             |

Scaffold acceptance: window opens, shows a gradient, resizes without artifacts (Wayland: correct ack-configure ordering), closes cleanly. Each scaffold agent also writes `findings/<platform>/scaffold.md` answering: concepts-to-pixel count, LOC, what surprised you.

**Gate:** Phase 2 agents copy their platform scaffold. Do not start Phase 2 for a platform until its scaffold is merged.

## Phase 2 — Feature demos (fan out: one agent per platform × feature cluster)

Feature clusters and their specs. Each agent gets ONE row on ONE platform. 17 features × 4 platforms = 68 cells, but several cells are N/A (marked) → ~58 demo tasks. Batch agents by platform if budget requires; priority order is the listed order (F01–F08 are the discriminating core; F09–F17 are second wave).

| ID      | Feature                            | Spec essentials (full text in `common/spec/`)                                                                                                                                                                                                                                                                                                                                                                    | Platform notes / N-A                                                          |
| ------- | ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| **F01** | First pixel & init cost            | Software-drawn frame; log every step from `init_start` to `first_pixel_presented`; count concepts.                                                                                                                                                                                                                                                                                                               | All. Mostly done by scaffold — this agent formalizes measurement.             |
| **F02** | Resize correctness                 | Continuous gradient redraw during resize; no stretching/tearing/protocol errors. Wayland: prove correct configure-serial ack + matching buffer size; log every configure.                                                                                                                                                                                                                                        | All                                                                           |
| **F03** | Modal-loop survival                | Animate (color cycle) and prove animation continues during interactive resize AND title-bar drag. Win32: defeat the `WM_ENTERSIZEMOVE` modal loop (document the technique chosen and alternatives). macOS: live-resize path.                                                                                                                                                                                     | All; the Win32 cell is the headline. Tier C verification.                     |
| **F04** | Vsync / frame pacing               | Drive redraw from the platform's frame clock; log inter-frame deltas for 600 frames; report jitter histogram. Wayland `frame` callbacks; X11 Present ext; Win32 DXGI waitable swapchain or DWM `DwmFlush`; macOS `CADisplayLink` (or `CVDisplayLink` + note deprecation).                                                                                                                                        | All                                                                           |
| **F05** | Loop wakeup & external fds         | Second thread injects an event 10×/s; main loop logs wakeup latency. Also: add an arbitrary fd (a timerfd/pipe) into the native loop where possible; document where it is NOT possible.                                                                                                                                                                                                                          | All                                                                           |
| **F06** | Keyboard & keymap                  | xkbcommon state machine on Wayland/X11 (consume keymap fd on Wayland); log scancode, keysym, UTF-8 for every press under at least 2 layouts (us, bg or de); dead-key compose test. **Wayland: implement client-side key repeat from `repeat_info`** with correct cancel-on-release/focus-loss. Win32: `WM_KEYDOWN`+`WM_CHAR` interplay; macOS: `keyDown:` + `interpretKeyEvents:`.                               | All                                                                           |
| **F07** | IME / text input                   | Pre-edit string rendered inline with underline, caret-anchored candidate window positioning (set the cursor rectangle), commit handling. Wayland `zwp_text_input_v3`; Win32 **TSF** (fall back to IMM32 only if TSF proves impractical — document why); macOS `NSTextInputClient`; X11 XIM (document its pathologies first-hand). Tier C: needs a real CJK IME; write a precise manual test script.              | All. Highest difficulty; assign strongest budget.                             |
| **F08** | DPI / runtime rescale              | Window reports logical+physical size and scale; survives monitor-to-monitor drag with different scales. Win32: PMv2 manifest + `WM_DPICHANGED` honoring suggested rect. Wayland: `wp_fractional_scale_v1`+`viewporter` path AND integer `buffer_scale` fallback. macOS: `backingScaleFactor` observation. X11: document that there is no runtime mechanism (Xft.dpi snapshot) — that finding IS the deliverable. | All                                                                           |
| **F09** | Output enumeration & hotplug       | List outputs (geometry/scale/refresh); log enter/leave (Wayland) or equivalent; handle hotplug events at runtime.                                                                                                                                                                                                                                                                                                | All; hotplug Tier C on win/mac.                                               |
| **F10** | Pointer: relative + lock + confine | Mouselook demo: raw deltas while cursor locked; toggle lock; confine-to-region variant.                                                                                                                                                                                                                                                                                                                          | All. Tier C interactive.                                                      |
| **F11** | Scroll fidelity                    | Log raw scroll data from notched wheel vs trackpad: Wayland `axis_v120` + axis_source, Win32 delta accumulation incl. <120 deltas, macOS phases+momentum, X11 buttons 4/5 vs XI2 smooth scrolling.                                                                                                                                                                                                               | All. Tier C for trackpad.                                                     |
| **F12** | Cursors                            | Set system-themed cursors (resize edges, hand, text); one custom pixmap cursor. Wayland: `cursor-shape-v1` when offered, else cursor-theme surface rendering — implement both.                                                                                                                                                                                                                                   | All                                                                           |
| **F13** | CSD & decoration modes             | Wayland only: `xdg-decoration` negotiation; when SSD denied, draw minimal CSD (title bar drag region via `xdg_toplevel.move`, resize edges via `.resize`) AND a libdecor variant for comparison. Run findings under mutter, kwin, sway (Tier C beyond headless).                                                                                                                                                 | Wayland only; others record "N/A — SSD" with one line on customization hooks. |
| **F14** | Window state & vetoable close      | Min/max/fullscreen toggles, focus events, close request with confirm-on-dirty. Log the exact event sequences for each transition per platform (these sequences are the deliverable).                                                                                                                                                                                                                             | All                                                                           |
| **F15** | Popup with grab                    | Right-click → popup menu, dismiss on outside click, correct placement near screen edge. Wayland `xdg_popup`+positioner (anchor/gravity/constraint_adjustment); X11 override-redirect + pointer grab; Win32 `WS_POPUP`+capture; macOS borderless window or `NSMenu` (do the borderless-window variant; note NSMenu as the escape hatch).                                                                          | All                                                                           |
| **F16** | Clipboard + file DnD               | Copy/paste UTF-8 both directions with another app; accept a file drop, log MIME/format negotiation sequence. X11: implement INCR receive. Win32: delayed rendering.                                                                                                                                                                                                                                              | All. Tier C for cross-app verification.                                       |
| **F17** | Threading probes                   | Deliberately violate threading rules: create window off main thread, pump events on another thread, render from a second thread while events flow. Record exactly what breaks, how it manifests (error? silent corruption? exception?).                                                                                                                                                                          | All. macOS findings are the anchor.                                           |

### Per-agent contract (every Phase 2 agent)

1. Copy your platform scaffold into `<platform>/fXX-<name>/`; do not modify the scaffold directory.
2. Read `common/spec/FXX.md` — implement everything in it; if something is impossible on your platform, that's a finding, not a skip: document the closest achievable behavior and why.
3. Build in the Nix shell. Tier A platforms: run it, capture the instrumentation log and protocol trace into `findings/<platform>/fXX-trace.log`.
4. Write `findings/<platform>/fXX.md`: what the spec asked / what the platform actually does / event sequences observed / surprises / `[expected, unverified]` items / open questions.
5. Fill your row-cell in `findings/matrix.md` (one-line summary + link). Use exactly one commit per demo, message `fXX(<platform>): <summary>`.
6. **Cite primary docs** for every non-obvious API behavior claim (MSDN, AppKit docs, wayland-protocols XML, Xorg specs) with links in the findings file.

## Phase 3 — Synthesis (1 agent, after F01–F08 land; update after second wave)

Read all findings + traces and produce:

- `findings/synthesis/divergence-map.md` — for each feature: where the four platforms agree, where they fork, and what abstraction each fork forces (e.g. "resize must be modeled as negotiation, not notification, because Wayland").
- `findings/synthesis/event-sequences.md` — side-by-side ordered event sequences per lifecycle transition per platform (from F02/F08/F14 logs).
- `findings/synthesis/design-constraints.md` — the hard constraints a new framework cannot abstract away (threading from F17, modal loop from F03, CSD from F13, client-side repeat from F06, ack-configure from F02), each with the evidence link.
- Cross-reference against the framework study reports (`research/reports/*.md` from the companion project) — where our empirical findings confirm or contradict how the frameworks behave, say so explicitly.

## Manual-run queue (compiled for Petar)

Orchestrator maintains `findings/MANUAL-RUN-QUEUE.md`: a single ordered checklist aggregating every Tier C item — grouped by machine (Windows box, Mac, GNOME session, KDE session, sway session) so each environment is visited once. Each entry: demo path, build command, steps, expected observation, where to paste results.

---

## `findings/matrix.md` template

```markdown
# Platform × Feature Findings Matrix

Legend: A=agent-verified, B=compiled-only, C=manual pending/done, — =N/A

| Feature                           | Wayland | X11 | Win32 | macOS |
| --------------------------------- | ------- | --- | ----- | ----- |
| Scaffold: concepts-to-pixel / LOC |         |     |       |       |
| F01 first pixel                   |         |     |       |       |
| F02 resize                        |         |     |       |       |
| ... (all 17 rows)                 |
```

Each cell: `[tier] one-line finding → findings/<platform>/fXX.md`

## Quality bar

A demo fails review if: it links a convenience library beyond the allowed list; it handles only the happy path the spec called out as divergent (e.g. F08 without the fractional-scale path on Wayland); its findings restate documentation instead of observed logs; or a Tier B/C expectation is written as fact. The traces are the ground truth — when a finding is interesting, the log line proving it must be linked.
