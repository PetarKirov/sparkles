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

| #      | Deliverable                                                                                | Depends on | Status |
| ------ | ------------------------------------------------------------------------------------------ | ---------- | ------ |
| **P0** | Foundations: `SmallBuffer` for reference-bearing elements, `sparkles:input` growth, `NFR2` | —          | open   |
| **P1** | `libs/ui-app`: backend selection, the CLI, the host contract, the recording target         | P0         | open   |
| **P2** | `apps/terminal` and `apps/hue` fully migrated onto the host                                | P1         | open   |
| **P3** | `apps/diagram` — a new dual-backend application that proves the abstraction                | P2         | open   |

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
the contract surfaces before hue's 2536-line GUI module is touched.

### Excluded-surface targets (`TST4`)

| Module                    | Now  | Target | What leaves                                                                              |
| ------------------------- | ---- | ------ | ---------------------------------------------------------------------------------------- |
| `apps/hue/src/gui.d`      | 2536 | ≤ 1200 | frame assembly, chrome composition, hit routing, pointer-shape composition, wheel policy |
| `apps/hue/src/app.d`      | 934  | ≤ 500  | backend policy assembly, CLI→request mapping, document/sink selection                    |
| `apps/terminal/src/app.d` | 1340 | ≤ 700  | the dirty/redraw decision, selection, URL hover, scrollbar state, font-resize policy     |

A target that cannot be met is a finding to record, not a number to move.

### P2.A — `apps/terminal`

Hard requirements: **identical behavior** and **no measured performance
regression**.

The migration's destination grew since these steps were written: the core is
extracted into a new **`libs/terminal-view`** library so it is embeddable as a
`runApp` component — the full design, the paint-hook host extension, and the
gates live in [terminal-view.md](./terminal-view.md) (`TVW`). `P2.A2` is done
(the `KeyStroke` byte oracle in `apps/terminal/src/input.d`); the steps below
execute inside that spec's order of work.

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
| P2.B1 | Extract the GUI module's frame, chrome and routing decisions into tested modules — no behavior change   |
| P2.B2 | Adopt the shared CLI; delete hue's private backend enum and picker                                      |
| P2.B3 | Move window/font opening onto the setup helpers, with the capture hooks passed in                       |
| P2.B4 | Move the GUI loop onto the host — input, then paint, then chrome, as separate commits                   |
| P2.B5 | Move the TUI loop onto the host; assert both hosts produce the same operations for one scripted session |

P2.B1 comes first deliberately: the GUI module has no tests today, so the migration's
first commit is the one that gives it some.

Preserve explicitly: the golden-frame screenshot harness and its deterministic
font-size override; the resize debounce and its benchmark; and the container wiring
the two hosts already share.

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
