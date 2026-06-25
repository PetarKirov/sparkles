# Platform Windowing API Research — Parallel Demo Program Plan (v2)

## Mission

Build a matrix of small, focused demo programs that exercise the windowing/input APIs of
**Wayland, X11, Win32, and macOS (AppKit)** directly — no frameworks, no abstraction layers — to
empirically map where the platforms diverge. The output is (a) working reference code per
platform per feature, (b) measured/observed behavior recorded in a shared findings matrix, and
(c) a final synthesis that pairs with the framework source-code study already landed at
`docs/research/window-system-integration/` (the per-library deep-dives plus `comparison.md`,
`recommendations.md`, and `platform-gotchas.md`) to drive the design of our windowing layer.

Everything lands in **this repository**, inside the existing OS-API research sub-tree at
`docs/research/window-system-integration/os-apis/`. That sub-tree already contains a survey
(`index.md`), a cross-platform `summary.md`, and per-platform survey directories
(`wayland/`, `x11/`, `win32/`, `appkit/`, `uikit/`, `android/`), each with a minimal
`example/` dub package that opens (or bootstraps) a window by calling the OS API directly.
This plan extends that sub-tree; it does not create a new repo.

> [!NOTE]
> `uikit/` and `android/` are **out of scope** for this demo matrix — the surveys exist, but
> mobile is outside CI scope and the feature set below is desktop-windowing-shaped. The matrix
> covers the four desktop platforms.

**Language & binding policy:** all demos are **D programs**, binding the OS the same way the
existing `os-apis/<platform>/example/` packages do:

| Platform     | Mechanism                                                                                      | Precedent                          |
| ------------ | ---------------------------------------------------------------------------------------------- | ---------------------------------- |
| Wayland, X11 | **ImportC** — a `c.c` shim `#include`s the real system header; `libs` uses the pkg-config name | `wayland/example/`, `x11/example/` |
| Win32        | druntime's built-in **`core.sys.windows`** (zero third-party)                                  | `win32/example/`                   |
| macOS        | **`extern(Objective-C)`** + `@selector` via the `objective-d` package                          | `appkit/example/`                  |

No helper libraries except: `libwayland-client`, `wayland-protocols`, `xkbcommon`,
`libxcb`/`Xlib`, and platform SDKs. The point is to touch the raw API. (The existing X11
example uses Xlib; stay with Xlib unless a feature genuinely needs xcb — if so, that choice is
itself a finding to document.)

## Layout (inside `docs/research/window-system-integration/os-apis/`)

```
os-apis/
  index.md                      # existing umbrella — extended with links to the matrix
  summary.md                    # existing cross-platform synthesis — updated in Phase 3
  features/                     # the feature specs below, one file per feature
    f01-first-pixel.md ... f17-threading.md
  feature-matrix.md             # the per-platform × per-feature grid (template below)
  manual-run-queue.md           # aggregated Tier C checklist (see below)
  divergence-map.md             # Phase 3 synthesis docs
  event-sequences.md
  design-constraints.md
  <platform>/                   # wayland/ x11/ win32/ appkit/
    index.md                    # existing survey — do not break its links
    example/                    # existing minimal program — DO NOT MODIFY (survey prose cites it)
    examples/
      scaffold/                 # Phase 1 output: full scaffold (window + buffer + frame loop)
      f01-first-pixel/ ... f17-threading/   # one dub package per demo, copied from scaffold/
    f01-first-pixel.md ... f17-threading.md # per-feature findings docs, next to index.md
```

Each demo is a **single small dub package** (≤ ~500 LOC target, `app.d` + `c.c` shim +
`dub.sdl`, mirroring the `example/` packages) that exercises exactly one feature cluster on top
of its platform scaffold. Scaffold code is **copied, not shared** as a library — duplication is
fine; isolation and readability win. The same goes for the `instrument.d` logging helper: each
demo carries its own copy.

## Conventions (binding)

All prose artifacts (specs, findings, matrix, synthesis) are research docs and must follow
[`docs/guidelines/research-docs.md`](docs/guidelines/research-docs.md) — reference-style links
under `<!-- References -->`, every identifier backticked, every term linked to its definition,
`**Last reviewed:**` dates on umbrella/synthesis docs, GitHub alerts for caveats, and primary
sources cited. The findings docs are sub-deep-dives of the graduated platform subjects, exactly
like `async-io/io-uring/{features,timeline}.md`.

- **VitePress:** register `features/`, the findings docs, the matrix, and the synthesis docs in
  the `os-apis` sidebar group in `docs/.vitepress/config.mts` (grouped: Features, then per
  platform, then Synthesis). Links to non-page artifacts (demo `.d`/`.c` files, `dub.sdl`,
  trace logs) need `ignoreDeadLinks` patterns (the `/\.d$/` rule is the model).
  `npm run docs:build` **must be green** before every commit.
- **Commits:** conventional commits, scope `research` (e.g.
  `docs(research): add os-apis wayland f02 resize demo + findings`). One commit per demo
  (code + findings + matrix cell together); preparation commits (nix shell, CI, `.gitignore`,
  sidebar) go first. Commit as you go; only pushing needs explicit sign-off.
- **Hooks:** `SKIP=lychee,verify-md-examples git commit …` is acceptable for large drops;
  re-check tables after prettier runs.
- **Nix footgun:** `git add` every new file **before** any `nix develop`/flake build — the
  flake cannot see untracked files.

## Verification tiers (agents must label every result)

- **Tier A — built and run by agent/CI.** Wayland demos run under
  `weston --backend=headless` (and `WAYLAND_DEBUG=1` captures the protocol trace — quote it in
  the findings). X11 demos run under `xvfb-run` (+ `xtrace` for protocol capture when useful).
  Win32 demos that need no interaction (create/paint/auto-close) run on the `windows-latest`
  CI runner — the existing `win32-example` job in `.github/workflows/ci.yml` is the model —
  and, once Phase 0 proves the pipeline, locally under **Wine** from a cross-compile (see
  [Local test environments](#local-test-environments-agent-driven); label such findings
  `A[wine]`). macOS demos are built **and run** by the agent over SSH on `mac-bsn` (same
  section). Behavioral findings from headless/Wine runs are valid for protocol/API behavior,
  NOT for visual/interactive behavior.
- **Tier B — compiled for target, not run.** The fallback when Wine or the Mac is
  unavailable: Win32 and macOS demos must at minimum produce a target object in the dev shell
  (`ldc2 -mtriple=x86_64-windows-msvc -c` / `ldc2 -mtriple=arm64-apple-macos -c`), the same
  compile-for-target bar the existing surveys use for iOS/Win32.
- **Tier C — requires manual run.** Every demo prints its findings checklist to stdout and
  writes the instrumentation log; agents add an entry to `manual-run-queue.md` per Tier-C demo
  listing the exact steps and expected observations for Petar to execute on real Windows/macOS
  machines and real compositors (mutter, kwin, sway). **Never report Tier B/C behavior as
  observed fact — mark it `[expected, unverified]` in the matrix and findings.**

## Local test environments (agent-driven)

### macOS — `mac-bsn` over SSH

`mac-bsn` is an `aarch64-darwin` machine with Nix and Xcode installed, reachable via
`ssh mac-bsn`. The repo lives at `~/code/repos/mine/sparkles`. Working rules:

- **Check for existing git worktrees first** (`git worktree list`) — earlier sessions may have
  left some; reuse a worktree for this branch rather than re-pointing a checkout that may be
  in use for something else.
- **Verify the checkout is at the right commit** before building anything: `git fetch`, then
  check out / fast-forward the research branch in the chosen worktree.
- The D toolchain is **not on `PATH`** — prefix every build/run command with `nix develop -c`
  from the repo root (e.g. `nix develop -c ldc2 …`).
- Known footgun: **`dub` fork-ENOMEMs on this machine** — drive `ldc2` directly instead of
  `dub build`/`dub run`.
- What an SSH session can verify: building, launching, and the demo's own instrumentation
  log. Whether an `NSWindow` actually appears (and anything needing focus, real input, or
  monitor topology) depends on the logged-in GUI session — Phase 0 establishes what works by
  re-running the existing `appkit/example`; whatever remains unobservable stays Tier C.

### Win32 — cross-compile + Wine

Try a fully local, agent-driven Win32 loop on Linux:

- **Compile:** `ldc2 -mtriple=x86_64-windows-msvc` in the dev shell.
- **Link:** `lld-link` against nixpkgs **`windows.sdk`**
  (`pkgs/os-specific/windows/msvcSdk/` — the MSVC CRT + Windows SDK headers/libs, splatted by
  `xwin`, the engine behind `cargo-xwin`).
- **Run:** under Wine (headless-friendly via a virtual desktop, e.g.
  `wine explorer /desktop=ci,1280x720 demo.exe`).

Phase 0 prototypes this against the existing `win32/example/` and records the exact working
commands; if it works, wire it into the dev shell and treat non-interactive Wine runs as Tier
A with the `A[wine]` label.

> [!WARNING]
> **Wine is not Windows.** It is an independent reimplementation of `user32`/DWM behavior, and
> this research is precisely about behavioral quirks. Every Wine-observed finding carries the
> `[wine]` label, and any surprising or load-bearing behavior must be re-confirmed on
> `windows-latest` CI or the real Windows box (manual queue) before the synthesis treats it as
> fact.

## Instrumentation (uniform across all demos)

Every demo logs to stderr in this exact format so traces are diffable across platforms:

```
<monotonic_us> <DEMO> <EVENT_KIND> key=value key=value...
```

Mandatory events: `init_start`, `window_created`, `first_configure` (or equivalent),
`first_pixel_presented`, `resize size=WxH scale=S`, `key code=.. sym=.. text=..`,
`pointer ...`, `scale_changed`, `close_requested`, `frame_callback t=..`. Demo F01 establishes
the format in `instrument.d`; all others copy it.

Additionally every demo records: **concept count** (number of distinct platform
objects/handles touched before first pixel) and **LOC** — these go in the matrix header row.

Findings docs must **quote the proving log lines verbatim** in fenced blocks. Full traces are
committed next to the demo as `trace.log` only when short (≲200 lines); otherwise trim to the
relevant excerpt.

---

## Phase 0 — Orchestrator setup (you, before fan-out)

1. Create the layout above (`features/`, `examples/` dirs, `feature-matrix.md` from the
   template at the bottom, `manual-run-queue.md` stub). `git add` everything immediately.
2. Write the feature specs (section below) into `features/f01-…md … f17-…md`, register the new
   docs in the VitePress sidebar, extend `ignoreDeadLinks`, and verify `npm run docs:build`.
3. Extend the Linux dev shell (`nix/shells/default.nix`) with `weston`, `wayland-protocols`,
   `libxkbcommon` (+ xcb libs only if a demo ends up needing them) — gated with
   `lib.optionals pkgs.stdenv.isLinux`, like the existing X11/Wayland deps.
4. Extend `os-apis/.gitignore` for the new packages (`*/examples/*/build/`,
   `*/examples/*/.dub/`, `*/examples/*/*.o`).
5. Extend `.github/workflows/ci.yml`: the Linux step builds/runs every
   `os-apis/*/examples/*` package (X11 under `xvfb-run`, Wayland under
   `weston --backend=headless`); the `win32-example` job loops over the Win32 demos. Keep the
   existing discipline: a demo that lacks a host capability prints `SKIP:` and exits 0 —
   never a red CI from a missing capability.
6. Verify the shell can run `weston --backend=headless` and `xvfb-run`, and that both
   compile-for-target triples produce objects. Fix the flake until true.
7. Prototype the **Win32 cross + Wine** pipeline against the existing `win32/example/`
   (`ldc2 -mtriple=x86_64-windows-msvc` → `lld-link` vs `windows.sdk` → Wine, per
   [Local test environments](#local-test-environments-agent-driven)). If it works, add the
   pieces (`windows.sdk`, `wine`) to the Linux dev shell and record the exact commands in the
   Win32 scaffold notes; if not, document why and fall back to `windows-latest`-only Tier A.
8. Verify **`mac-bsn`**: SSH reachable, worktree picked/created on the right commit,
   `nix develop -c ldc2 --version` works, and whether re-running the existing
   `appkit/example` shows a window from the SSH session. The outcome decides whether macOS
   run-findings are Tier A or Tier C.
9. Commit all of this as the preparation commits.

## Phase 1 — Scaffolds (4 parallel agents, one per platform)

The existing `example/` packages are the starting point — each already proves the binding
mechanism and the irreducible bootstrap. Scaffold agents **copy** them into
`<platform>/examples/scaffold/` and grow them to full scaffold acceptance; the `example/`
packages stay untouched (the survey prose cites them as the minimal program).

| Agent          | Task                                                                                                                                                                                                                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **W0**         | Wayland scaffold: registry, `xdg_wm_base`, toplevel, `wl_shm` double buffer, configure/ack/commit loop, frame-callback redraw, clean teardown. (The existing example stops at the `wl_registry` bootstrap — most of this is new.) Run under headless weston with `WAYLAND_DEBUG=1`; quote the trace. |
| **X0**         | X11 scaffold (Xlib, like the existing example): window, `WM_PROTOCOLS`/`WM_DELETE_WINDOW`, MIT-SHM image presentation, event loop on the connection fd (`ConnectionNumber`).                                                                                                                         |
| **N0** (win32) | Win32 scaffold: `RegisterClassEx`, `CreateWindowEx`, message pump, DIB section + `BitBlt` on `WM_PAINT`, auto-close path for CI. Tier A on `windows-latest` plus the local Wine pipeline from Phase 0 (label `A[wine]`); manual-queue entry for the interactive rest.                                |
| **M0**         | macOS scaffold: `NSApplication` with explicit activation policy, `NSWindow`, custom `NSView` drawing a CPU buffer via `CGContext`, run loop. Build **and run on `mac-bsn` over SSH** (`nix develop -c ldc2`, not `dub`); whatever the SSH session cannot observe goes to the manual queue.           |

Scaffold acceptance: window opens, shows a gradient, resizes without artifacts (Wayland:
correct ack-configure ordering), closes cleanly. Each scaffold agent also writes
`<platform>/scaffold.md` (house style) answering: concepts-to-pixel count, LOC, what surprised
you — and how the full scaffold differs from the survey's minimal `example/`.

**Gate:** Phase 2 agents copy their platform scaffold. Do not start Phase 2 for a platform
until its scaffold is merged.

## Phase 2 — Feature demos (fan out: one agent per platform × feature cluster)

Feature clusters and their specs. Each agent gets ONE row on ONE platform. 17 features × 4
platforms = 68 cells, but several cells are N/A (marked) → ~58 demo tasks. Batch agents by
platform if budget requires; priority order is the listed order (F01–F08 are the
discriminating core; F09–F17 are second wave).

| ID      | Feature                            | Spec essentials (full text in `features/`)                                                                                                                                                                                                                                                                                                                                                                       | Platform notes / N-A                                                          |
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

1. Copy `<platform>/examples/scaffold/` into `<platform>/examples/fXX-<slug>/`; do not modify
   the scaffold directory or the survey's `example/`. `git add` new files immediately.
2. Read `features/fXX-<slug>.md` — implement everything in it; if something is impossible on
   your platform, that's a finding, not a skip: document the closest achievable behavior and why.
3. Build in the Nix shell. Tier A platforms: run it, capture the instrumentation log and
   protocol trace; quote the proving lines in the findings doc. Win32 agents use the Wine
   pipeline, macOS agents the `mac-bsn` SSH loop (see
   [Local test environments](#local-test-environments-agent-driven)), labeling findings
   `A[wine]` / `A[ssh]` accordingly.
4. Write `<platform>/fXX-<slug>.md` in research-doc house style: what the spec asked / what the
   platform actually does / event sequences observed / surprises / `[expected, unverified]`
   items / open questions. Cross-link the demo source and the relevant section of the
   platform's survey `index.md`.
5. Fill your row-cell in `feature-matrix.md` (one-line summary + link). Register the findings
   doc in the VitePress sidebar; `npm run docs:build` must be green. One commit per demo:
   `docs(research): add os-apis <platform> fXX <slug> demo + findings`.
6. **Cite primary docs** for every non-obvious API behavior claim (Microsoft Learn, AppKit
   docs, wayland-protocols XML, Xorg specs) as reference-style links in the findings doc.

## Phase 3 — Synthesis (1 agent, after F01–F08 land; update after second wave)

Read all findings + traces and produce (each with a `**Last reviewed:**` line, registered in
the sidebar):

- `os-apis/divergence-map.md` — for each feature: where the four platforms agree, where they
  fork, and what abstraction each fork forces (e.g. "resize must be modeled as negotiation,
  not notification, because Wayland").
- `os-apis/event-sequences.md` — side-by-side ordered event sequences per lifecycle transition
  per platform (from F02/F08/F14 logs).
- `os-apis/design-constraints.md` — the hard constraints a new framework cannot abstract away
  (threading from F17, modal loop from F03, CSD from F13, client-side repeat from F06,
  ack-configure from F02), each with the evidence link.
- Cross-reference against the framework deep-dives one directory up
  (`../winit.md`, `../sdl3.md`, …, `../comparison.md`, `../platform-gotchas.md`) — where our
  empirical findings confirm or contradict how the frameworks behave, say so explicitly.
- Update `os-apis/summary.md` and `os-apis/index.md` to link the matrix and synthesis docs
  (refresh their `**Last reviewed:**` dates).

## Manual-run queue (compiled for Petar)

Orchestrator maintains `os-apis/manual-run-queue.md`: a single ordered checklist aggregating
every Tier C item — grouped by machine (Windows box, Mac, GNOME session, KDE session, sway
session) so each environment is visited once. Each entry: demo path, build command (on the
Mac: `nix develop -c ldc2`, not `dub`), steps, expected observation, where to paste results.
Wine-verified Win32 items that need real-Windows confirmation are queued here too, flagged
`[wine]` so they can be batch-confirmed on the Windows box.

---

## `feature-matrix.md` template

```markdown
# Platform × Feature Findings Matrix

Legend: A=agent-verified (A[wine]=under Wine, A[ssh]=on mac-bsn over SSH),
B=compiled-only, C=manual pending/done, — =N/A

| Feature                           | Wayland | X11 | Win32 | macOS |
| --------------------------------- | ------- | --- | ----- | ----- |
| Scaffold: concepts-to-pixel / LOC |         |     |       |       |
| F01 first pixel                   |         |     |       |       |
| F02 resize                        |         |     |       |       |
| ... (all 17 rows)                 |
```

Each cell: `[tier] one-line finding → <platform>/fXX-<slug>.md` (reference-style links; add a
`**Last reviewed:**` line at the top).

## Quality bar

A demo fails review if: it links a convenience library beyond the allowed list; it handles
only the happy path the spec called out as divergent (e.g. F08 without the fractional-scale
path on Wayland); its findings restate documentation instead of observed logs; a Tier B/C
expectation is written as fact; its findings doc breaks the research-doc house style (dead
links, unbackticked identifiers, missing citations); or `npm run docs:build` is red. The
traces are the ground truth — when a finding is interesting, the log line proving it must be
quoted in the findings doc.
