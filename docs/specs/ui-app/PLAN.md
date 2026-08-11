# `sparkles:ui-app` — delivery plan

_Audience: contributors. Execution-only — deliverables, dependencies, acceptance
gates. For the requirement tree and the rationale read the
[spec](./index.md); IDs (`APP1`…`TST4`) refer to the
[feature requirements](./feature-requirements.md)._

The host cannot be built first. Three of its requirements depend on capabilities the
supporting libraries do not have yet — a buffer that can hold reference-bearing
elements, an input vocabulary that can express a held key, and a display list that
does not allocate. Phase 0 supplies those; phases 1–3 build on them.

## Phase overview

| #      | Deliverable                                                                                | Depends on | Status                                               |
| ------ | ------------------------------------------------------------------------------------------ | ---------- | ---------------------------------------------------- |
| **P0** | Foundations: `SmallBuffer` for reference-bearing elements, `sparkles:input` growth, `NFR2` | —          | shipped                                              |
| **P1** | `libs/ui-app`: backend selection, the CLI, the host contract, the recording target         | P0         | shipped (P1.1–P1.6; `TST3` still open — see its row) |
| **P2** | `apps/terminal` and `apps/hue` fully migrated onto the host                                | P1         | shipped (P2.A as `TVW1`–`TVW7`; P2.B1–B5)            |
| **P3** | `apps/diagram` — a new dual-backend application that proves the abstraction                | P2         | open                                                 |

Each phase must be green before the next starts, and every commit inside a phase
must build, test and lint on its own.

## Raising test coverage is an objective, not a side effect

Three application modules are excluded from their unittest builds because they link
a window or hold `main`: `apps/hue/src/gui.d` (2536 lines), `apps/hue/src/app.d`
(934) and `apps/terminal/src/app.d` (1340) — **4810 lines** invisible to both the
test suite and any coverage measurement. Almost none of it is untestable in
principle: folding input, routing a pointer, composing chrome, encoding a keystroke
and deciding whether to draw are all pure or nearly pure.

Each phase therefore carries a coverage deliverable, and they compound:

| Phase | What becomes testable                                                                                                                           |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| P0    | The per-frame input fold leaves `apps/hue` and becomes a library with a suite; a coverage baseline exists at all                                |
| P1    | Backend selection is a pure function over an injected policy (`BKD2`); the recording target makes any `present`/`handle` pair testable (`TST1`) |
| P2    | Both applications' loops run under the recording target; decision logic leaves the excluded modules and the excluded line count falls (`TST4`)  |
| P3    | A new application is written against the recording target from its first commit; its excluded surface is `main` and nothing else                |

## Phase 0 — foundations {#phase-0}

Three library changes in existing packages, plus the coverage baseline. No new
package.

### P0.1 — coverage baseline

Nothing in the repository measures coverage today. `apps/ci` gains a `--coverage`
mode: per sub-package `unittest-cov` runs into a scratch directory, the `.lst`
trailers parsed into a covered/total summary sorted worst-first. It is **measured,
not gated** — no threshold blocks a build. Record the baseline, including the
excluded-module line counts that coverage cannot see, in
[open issues](./open-issues.md#uiapp-o4).

D's `-cov` counts template instantiations per instantiation and emits `.lst` files
for imported modules; the percentage is a trend indicator, which is precisely why it
does not gate.

### P0.2 — `SmallBuffer` for reference-bearing elements

`sparkles:base`'s `SmallBuffer` cannot safely hold an element type containing
references, for two independent reasons: its inline slots are `void`-initialized,
and its heap block comes from `Mallocator` and so is **not scanned by the GC** — a
buffer that outgrows its inline storage can have the memory its elements point at
collected. This is why the toolkit's recording canvas uses a GC array and says so.

The change, gated on `hasIndirections!T` so pointer-free instantiations are
byte-identical:

- inline slots default-initialize instead of `= void`;
- the heap block is registered as a GC root at every inline→heap promotion and at
  every copy-on-write clone, and unregistered before every release — including the
  unique→shared promotion, where the block transfers without reallocating and must
  **not** be registered twice.

The struct's methods are `pure nothrow @nogc`, and the GC root calls are `nothrow
@nogc` but not `pure`; they need a pure-cast wrapper of the kind druntime's
`pureMalloc` uses, with the justification recorded at the call site — registering a
root has no observable effect on the pure computation.

Residual limit to document rather than fix: a buffer living inside **another**
malloc'd block still has unscanned inline slots. Stack instances and instances
embedded in GC memory are covered by the conservative scan.

Acceptance: elements holding freshly allocated references survive a forced
collection after the buffer has grown past its inline capacity; a pointer-free
instantiation's size and append path are unchanged.

### P0.3 — `sparkles:input` growth

Two additions, both traced in the [input spec](../ui/input.md):

1. **Key levels.** A key event gains an action (press / repeat / release), the
   layout-independent unshifted code point, and the text that keystroke produced;
   modifiers gain the platform "super" modifier. Fields are **appended**, so every
   existing construction and helper keeps compiling. Targets declare whether they can
   report a key release at all — a terminal cannot — so a held-key interaction asks
   the capability and offers another route instead of degrading silently
   ([`TGT5`](../ui/backends.md)).

   Carrying the produced text on the same event as the key is not a convenience: a
   terminal emulator's key encoder pairs them, and a detached text event cannot
   express that pairing.

2. **The per-frame fold.** `apps/hue`'s private frame-input fold — edges versus
   levels, wheel accumulation, gesture anchors — is a pure function of an event
   sequence with a real test suite, and nothing about it is hue-specific. It moves
   into `sparkles:input`, generalized to every pointer button, to modifier level, and
   to a held-key set populated only where the target can report releases. It stays
   **unit-agnostic**: positions pass through in whatever unit the producer emits, so
   a host polling in pixels is unaffected.

### P0.4 — `NFR2`: the allocation-free display list

P0.2 is what makes this legal. The widget arena and the display list both move onto
`SmallBuffer`, closing [`NFR2`](../ui/feature-requirements.md).

The hazard is lifetime, not allocation: a display list sliced out of a buffer is
**borrowed**, and the buffer must outlive every painter that walks it. Every
existing consumer needs an audit for a slice that currently outlives its producer
only because the GC kept it alive.

## Phase 1 — the host package {#phase-1}

### P1.0 — prove version propagation first

`run` is a template, so a version identifier gating one of its arms is resolved
during the **consumer's** compilation (`APP5`). The design assumed dub propagates a
dependency's version identifiers to its dependents.

**Done — it holds.** A two-package spike confirms that a dependency's
configuration `versions` reach the dependent's compilation, and that a
version-gated template arm resolves the way the selected `subConfiguration` says.
The package-split fallback is not needed; `APP3`'s three configurations stand.
Recorded in [UIAPP-O2](./open-issues.md#uiapp-o2), with two details the manifests
depend on: the **first** configuration is what a consumer gets when it declares
none, so ordering is load-bearing, and the propagation applies to non-templates
too.

### P1.1–P1.5 — the package

| Step | Deliverable                                                                                              | Requirements                 |
| ---- | -------------------------------------------------------------------------------------------------------- | ---------------------------- |
| P1.1 | Package scaffold, three configurations, root manifest entry, `AGENTS.md` rows, this spec tree            | `APP1`–`APP4`                |
| P1.2 | Backend selection over an injected policy, with the full decision matrix as pure tests                   | `BKD1`–`BKD5`                |
| P1.3 | The window/font CLI vocabulary — one declaration, one set of defaults                                    | `CLI1`–`CLI3`                |
| P1.4 | The host contract **and** the recording target, together — the recorder is how the contract is specified | `HST1`–`HST9`, `TST1`–`TST3` |
| P1.5 | The two live arms: terminal loop (`version (Posix)`), then GPU loop and the setup helpers                | `APP4`, `CLI4`–`CLI6`        |

Acceptance: all three configurations build; the contract tests run with no window
and no tty; a scripted session produces the same operations through the recorder and
through the live terminal arm.

**Status: P1.1–P1.5 shipped.** All three configurations build on ldc2 and dmd, the
contract tests run headlessly, and both live arms now run on `event-horizon` rings
(with the blocking paths kept as explicit fallbacks). The remaining acceptance
clause — recorder ↔ live-terminal operation parity (`TST3`) — is still open; the
PTY harness for it comes with the `apps/terminal` migration, which already needs
one for the behavior gate.

### P1.6 — the component entry point (`runApp`)

**Done.** One call above `run`: an application is a value with `view`/`handle`
(`isAppFor`), and `runApp` owns theme resolution, layout, the display-list build
and a themed page fill — with `probedPolicy` as the single environment read and
`runAppRecorded` as the headless twin (`HST10`–`HST12`). This is the entry point
every app migrates onto in phase 2; the direct `run` level remains for the loop
shapes `runApp` does not cover.

## Phase 2 — migrate the applications {#phase-2}

Both applications migrate fully — CLI, backend decision and event loop. Terminal
goes first: it is the harder case and the one with a measurable gate, so a defect in
the contract surfaces before hue's GUI module is touched.

### Excluded-surface targets (`TST4`)

| Module                    | At exclusion count | Now (2026-08-09) | Target | What leaves                                                                              |
| ------------------------- | ------------------ | ---------------- | ------ | ---------------------------------------------------------------------------------------- |
| `apps/hue/src/gui.d`      | 2536               | 3162             | ≤ 1200 | frame assembly, chrome composition, hit routing, pointer-shape composition, wheel policy |
| `apps/hue/src/app.d`      | 934                | 1325             | ≤ 500  | backend policy assembly, CLI→request mapping, document/sink selection                    |
| `apps/terminal/src/app.d` | 1340               | 114              | ≤ 700  | **met** by the `terminal-view` extraction — the shell is CLI parse → `runApp`            |

A target that cannot be met is a finding to record, not a number to move. Note the
hue numbers moved **up** while the extraction work waited — the GUI module kept
absorbing features (diff view, markdown preview polish, hover popups) — which is
the strongest argument for P2.B1 landing before any more feature work touches it.

### P2.A — `apps/terminal`

**Shipped**, as the `terminal-view` extraction: the core is a new
**`libs/terminal-view`** library embeddable as a `runApp` component — the full
design, the paint-hook host extension, and the gate numbers live in
[terminal-view.md](./terminal-view.md) (`TVW1`–`TVW7`, all full;
`apps/terminal` is a 114-line shell). The remaining loop work is the ring
step that spec reserved: **`TVW8`** (pty reads and the reap park on
`event-horizon`, behind the `HST15` errands), planned there. The historical
steps below are kept for the record.

Hard requirements were: **identical behavior** and **no measured performance
regression** — both held (`TVW6`'s gate row).

| Step  | Deliverable                                                                                                   |
| ----- | ------------------------------------------------------------------------------------------------------------- |
| P2.A1 | Adopt the shared CLI and setup helpers; loop untouched                                                        |
| P2.A2 | Capture the encoder's output bytes for a scripted key/mouse sequence **on the current code**, as the oracle   |
| P2.A3 | Extract the dirty/redraw, selection, hover and font-resize decisions into tested modules — no behavior change |
| P2.A4 | Rewrite the key/mouse encoder against `sparkles:input`, against the byte oracle                               |
| P2.A5 | Move the loop onto the host with `skipFrame`; loop tests under the recording target; run the gate             |

The encoder is the sharp edge. It needs physical key identity, press/repeat/release,
the "super" modifier, an unshifted code point and the produced text — which is
exactly what P0.3 adds, and where "identical behavior" is most at risk. The byte
oracle is the only mechanical proof available, which is why it is captured before
anything moves.

The gate is the existing render-CPU benchmark, run on `main` and on the migrated
build on the same host: the idle scenario must stay at its near-zero baseline (this
is what `HST6` protects), and the render and churn scenarios must be within
run-to-run noise. Both numbers go in the commit message. If the gate fails, the fix
belongs in the host contract, not in a private path for one application.

### P2.B — `apps/hue`

| Step  | Deliverable                                                                                             |
| ----- | ------------------------------------------------------------------------------------------------------- |
| P2.B0 | The `HST15`/`HST16` host extensions, proven by `TVW8` before hue consumes them                          |
| P2.B1 | Extract the GUI module's frame, chrome and routing decisions into tested modules — no behavior change   |
| P2.B2 | Adopt the shared CLI; delete hue's private backend enum and picker                                      |
| P2.B3 | Move window/font opening onto the setup helpers, with the capture hooks passed in                       |
| P2.B4 | Move the GUI loop onto the host — input, then paint, then chrome, as separate commits                   |
| P2.B5 | Move the TUI loop onto the host; assert both hosts produce the same operations for one scripted session |

**Status (2026-08-10): P2.B1 shipped** across #285/#286 and this branch —
the state vocabulary (`gui_state.d`, 11 suites), the debounce settle, the
goto-line parse, the selection-drag lifecycle, the search-jump wrap, and the
line-input typing rules are all tested decisions; `gui.d` keeps routing and
frame assembly (3181 → 3013 lines). **P2.B2 shipped too** (same day): the
sink decision through the host picker (hue’s Backend/pickBackend/env
displayAvailable deleted; the socket-level probe replaces the env sniff),
and the CLI onto `mixin GuiCliFields` with the shared defaults — the
UIAPP-O1 user-visible shift (14→18 pt, catppuccin-mocha→tokyo-night,
Maple-first cascade, +--font-dir/+--font-codepoint-map) plus the Android
prepend’s deletion. En route: the mixin’s `--no-gui` was a silent no-op
(declaration order vs the parser’s negation resolution) — fixed with a
regression test.

**Status (2026-08-11): P2.B3 shipped, P2.B4 in progress.** P2.B3 landed in
two halves — the capture hooks off the environment and onto `GuiRequest`
(`CLI6`), then window and fonts through `openGuiSession`, which is also what
put the `HST14` font errand within reach.

P2.B4 is being cut as seams before it is cut as a component, four slices so
far: `runGui`’s 39 parameters became a `GuiArgs` value, its loop-carried
state became a `GuiRunState` value, the paint half became
`paintWindowFrame`, and the view half became `stepFrame`. The third slice is
the load-bearing one — hoisting the paint half out of the loop made the
compiler enumerate every value it had been closing over (22 of them), and
that list is now `FrameGeom`: the exact interface between the frame’s two
halves, derived rather than guessed. It is also the split the component
needs, since `FrameGeom` is per-frame (what `view` computes for `paint`,
`HST13`) and everything still captured is run-scoped (the component’s
fields). The frame loop is now pace → `stepFrame` → `paintWindowFrame` →
present, which is `gui_loop.d`’s `oneFrame` with hue’s names on it. Nothing
in either half’s body changed; `dub test :hue` stays at 194.

**P2.B4 then shipped.** `runGui` stops owning a loop: `handle` collects the
drain, `present` is the view half, `draw` is the paint half inside the arm’s
bracket. hue’s `Sched`, its `pumpUntilFrame` (40 lines of `Sched.tick`
embedding hatch), the `targetFps: 0` handshake, its `openGuiSession` call and
its own `RaylibEvents` are all deleted — every one of them exists in
`gui_loop.d`, once, for every application, and hue is why they were written
there.

Three host contracts had to land first, and each is a finding rather than a
workaround: `HST18` (hue hit-tests in **pixels**), `HST17` (a live modifier
level, because a stationary drag gets no event when Shift moves) and `HST19`
(hue lays out before its first frame, against a window that does not exist
until the arm opens it). `GuiArgs` also lost six fields to one `GuiOptions`,
which is how `--font-dir` and `--font-codepoint-map` reach the request at
all — unpacking them by hand had been dropping both.

Two things the desktop compiler could not have told us. The Android arm
crosses the same view/paint seam (the touch action bar builds a tree in one
half and paints it in the other; the back button broke the frame loop), and
`APP3`’s “an Android build must not link a terminal” turned out to be
load-bearing: with the loop now the host’s, ui-app’s `full` configuration
pulled the terminal arm into `run`’s `final switch` for the cross build,
where it took LDC down with a locationless ICE. Android moves to `gui`.

The oracle for all of it was hue’s own golden capture. `DBG1` makes it
reproducible, so `origin/main` and the branch must produce byte-identical
PNGs; five scenarios (twoslash overlay, markdown preview, syntax view) do,
across every slice. One caveat worth writing down: `xvfb-run -a` sometimes
lands on the workstation’s real display, where ambient keystrokes reach the
window and act as commands — a `t` toggles the copy format, an arrow cycles
the theme. Pin the display number.

**P2.B5 then shipped too.** `WorkspaceTui` is a component and both private
loop arms are gone — `runWorkspaceAsync` (230 lines) and
`runWorkspaceBlocking` were `runTui`'s two arms with hue's names on them, so
the `EventChannel`, the `withDeadline` take, the signalfd and the arm
selection all went with them. The oracle watchers and the git-status driver
park through `HST15`; the wait deadline is `HST16`; `dirty` inverted into
`skipFrame`; and the out-of-band drains became errands rather than sequences
hue spelled itself (`takeClipboard` returns the text, `takeCursorShape` a
`PointerShape`), which is the layer the old code was missing rather than a
redirection.

Two things worth carrying forward. **The contract landed before the arms
were deleted**, because unlike `P2.B4` this milestone had no oracle at all —
`HUE_TWOSLASH_TUI_CAPTURE` renders through `twoslash_tui.d`, which never
constructs a `WorkspaceTui` — so `view`/`handle`/`paint` went in while both
arms still ran, and four scripted `runAppRecorded` sessions passed against
the code the arms were running before anything was removed. And
`currentScheduler` was **not** right on the first try: it returned `Sched*`,
which made every consumer dereference a pointer and so needed `@trusted` per
call site. Returning `ref Sched`, with `onScheduler` carrying the
nullability as the question it always was, removed the last `@trusted` from
`workspace.d` — the daemon closures capture `ref` locals (2.111) instead of
`(() @trusted => &this)()` pointers.

Next: `TST3`, which `P2.B5` sharpened rather than closed — see its row in the
[feature requirements](./feature-requirements.md).

P2.B1 comes first among the hue steps deliberately: the GUI module has no tests
today, so the migration's first commit is the one that gives it some.

What each step means against the code as it stands (2026-08-09):

- **P2.B0 — the contract extensions the loops need.** Two findings force them.
  hue's TUI arm computes a **per-iteration** wait deadline (the lantern
  panel's remainder, the oracle tick where a poll survives) that
  `RunConfig.idleTimeoutMs` — fixed at startup — cannot express: that is
  `HST16` (`wakeIn`). And hue's background fibers (the oracle-readiness
  watchers, the spawned git refresh) plus `terminal-view`'s pty pump all need
  to park on the loop's scope and wake it: that is `HST15`
  (`spawnDaemon`/`wake`). Land them recorder-first, then the async arms
  (the GPU arm needs a scope around its ticker loop), and let `TVW8` prove
  them on the measurable app before hue's migration leans on them.
- **P2.B1 — make `gui.d` testable before moving it.** The module is 3162
  lines and grew ~600 since the exclusion count. Its state is already
  struct-shaped (`Regime`, `SelectionDrag`, `Panes`, `InputState`,
  `CopyModes`, `Flashes`, `HoverPopup`, `ResizeDebounce`, `Mode`) — the
  extraction moves those with their transition logic into tested sibling
  modules, leaving `gui.d` the frame assembly. No behavior change; the
  golden-frame screenshots are the oracle that nothing drifted.
- **P2.B2 — one backend picker.** `app.d`'s `displayAvailable`/`Backend`/
  `pickBackend` are line-for-line ancestors of `sparkles.ui_app.backend`
  (`BKD` preserves the rules verbatim, including "explicit `--gui` wins");
  the CLI re-declares `GuiCliFields`. Both collapse onto the library
  (structural copy into `GuiOptions`, the ui-gallery `main` is the
  pattern). One wrinkle stays hue's: the `html`/`ansi` sinks are static
  and the host returns `notInteractive` for them ([UIAPP-O3]), so hue's
  `main` keeps that dispatch and calls `runApp` only for `gui`/`tui`.
- **P2.B3 — the capture hooks stop being environment reads.** `gui.d` reads
  `HUE_GUI_SCREENSHOT`/`_FRAME`/`_FONTSIZE`/`_TOP`/`_FLASH`/`_HOVER` inline;
  `CLI6` requires deterministic capture to be **caller-supplied** on the
  request. The env reads move to hue's `main`, the hooks ride `GuiRequest`,
  and the screenshot harness keeps working through both.
- **P2.B4 — the GUI loop.** `runGui` (34 parameters today) becomes a
  component: `view` from the frame body, `handle` from the input fold,
  hand-minted `RaylibCanvas` chrome into the `HST13` draw phase. hue's
  private `Sched`/`pumpUntilFrame`/`targetFps: 0` plumbing is deleted —
  `gui_loop.d`'s ticker arm already is that code. The dub flip is one line
  (`subConfiguration "sparkles:ui-app" "tui"` → `"full"`). Input, paint,
  chrome as separate commits; screenshots and the resize-debounce benchmark
  green after each.
- **P2.B5 — the TUI loop, and the parity test.** `WorkspaceTui` already has
  component shape (`paint(grid)` → the draw phase against `grid()`/
  `canvas()`; `handle(Event)` exists). What the host absorbs:
  `runWorkspaceAsync`'s scope/pumps/take-with-deadline skeleton (it **is**
  `runTui`'s async arm), the oracle watchers and git-refresh fiber onto
  `HST15`, `waitDeadline` onto `HST16`, the out-of-band drains
  (`takeClipboard` → `clipboard`, cursor shape → `pointerShape`) onto the
  existing errands. The repaint `dirty` flag inverts into `skipFrame`
  (`HST9`: default repaints, idle passes decline). This step closes `TST3`:
  one scripted session driven through `runAppRecorded` and through the live
  terminal arm under a pty harness must produce the same operation stream.

  **Sub-slices, in dependency order** (surveyed 2026-08-11, against
  `workspace.d`'s 1686 lines and both of its private arms):
  1. **`currentScheduler`** — shipped. hue's TUI arm has three background
     fibers (two oracle-readiness watchers and the git-status refresh) and
     they need a `ref Sched` for `waitReadable`/`capture`, which
     `spawnDaemon(void delegate())` cannot hand them. Without this the
     migration cannot start; with it, each daemon asks at the top.
  2. **The oracle first, as `P2.B4` did.** The workspace TUI has no headless
     frame capture — `HUE_TWOSLASH_TUI_CAPTURE` renders through
     `twoslash_tui.d`, a different path that never constructs a
     `WorkspaceTui`. So there is nothing to A/B a restructure against, and
     the first commit has to make one: a scripted `runAppRecorded` session
     over the component, asserted on the operation stream. The
     chicken-and-egg (the recorder needs the component; the component wants
     the recorder) resolves by adding `view`/`handle`/`paint` as member
     templates **while both private arms keep running**, so the oracle exists
     before anything is deleted.
  3. **The component contract.** `WidgetTree view(H)(ref H h)` is the loop's
     top half — the polls, the git snapshot, `arrange` on a size change, the
     `HST16` deadline (`waitDeadline` verbatim), the out-of-band drains, and
     `skipFrame` where `dirty` is false. It returns an empty tree: hue paints
     its own cells. `paint(H)` is `paint(h.grid)`. `handle(H)` wraps the
     existing `handle(Event)`, turning its `false` into `h.quit()`. One piece
     of state has no equivalent yet — the loop distinguishes "an event
     arrived" from "the deadline expired" (`onWaitExpired`), which becomes a
     flag `handle` sets and `view` clears.
  4. **The arms are deleted.** `runWorkspaceAsync` (230 lines) and
     `runWorkspaceBlocking` are `runTui`'s two arms with hue's names on them;
     the daemons move to `h.spawnDaemon`, the channel wake to `h.wake`, the
     `EventChannel`/`withDeadline`/`SIGWINCH` skeleton disappears entirely.
  5. **The out-of-band drains become errands.** Not a rename:
     `PreviewTui.takeClipboard` returns an OSC 52 sequence it base64-encoded
     itself, so `h.clipboard(text)` requires keeping the raw text instead —
     with `tui.d`'s existing encoding tests moved onto the host's. Same for
     the cursor shape and `pointerShape`. Behaviour-preserving, but it is a
     change to what hue emits, not a redirection of it.

Preserve explicitly: the golden-frame screenshot harness and its deterministic
font-size override; the resize debounce and its benchmark; and the container wiring
the two hosts already share.

[UIAPP-O3]: ./open-issues.md#uiapp-o3

## Phase 3 — `apps/diagram` {#phase-3}

A draw.io-style board — infinite canvas, camera pan, wheel zoom, minimap, create /
select / group / label, orthogonal connectors, context menu — built on the host with
**zero** backend imports (`APP2`). It exists to stress the abstraction with an
application neither existing app resembles. The full requirement tree and its
delivery plan live in [docs/specs/diagram](../diagram/index.md).

Two commit series: the MVP board (scaffold, camera, world, input, render, minimap),
then menus, groups, labels, connectors and fit-all.

Constraints that shape it, each a consequence of a checked property of the stack:

- The canvas line primitive is an **underline attribute** on the terminal target, so
  connectors are drawn with box-drawing glyphs on both axes. Those route through the
  GPU backend's procedural box drawing, so their arms connect across cells on both
  targets — a line primitive would not.
- Held-key bindings are unavailable where a target cannot report key releases, so
  panning is middle-drag, a modifier-drag and the keyboard on both targets.
- Geometry types are union-backed vectors, so named-field reads are unavailable at
  compile time; camera tests are runtime tests.

The backend-isolation check stays a **manual grep**, deliberately not automated.

## Verification

| Phase | Command                                                                                      |
| ----- | -------------------------------------------------------------------------------------------- |
| P0    | `dub test :base :input :ui`; `dub run :ci -- --coverage` (baseline, then delta)              |
| P1    | `dub test :ui-app`; `dub build :ui-app -c tui -c gui -c full`                                |
| P2    | `dub test :terminal :hue`; the benchmark gate; the screenshot capture; `nix build .#hue-apk` |
| P3    | `dub test :diagram`; both configurations built and run; the manual isolation grep            |

Every phase additionally runs `nix run .#ci -- --test --fail-fast`.
