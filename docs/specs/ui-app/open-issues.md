# `sparkles:ui-app` — Open issues

_Companion to the [feature requirements](./feature-requirements.md) and the
[delivery plan](./PLAN.md). The normative decisions stay in those pages; this one
records deferred decisions, the constraints behind them, and the measurements the
plan is calibrated against. Close an entry only after the change lands, the affected
requirement statuses are reconciled, and the closing commit is recorded._

## UIAPP-O1 — One point size for every application {#uiapp-o1}

**Status:** open (decision taken, consequence outstanding). **Requirements:** `CLI3`.

The two applications ship different default point sizes today — 13 in
`apps/terminal`, 14 in `apps/hue` — and the shared vocabulary (`CLI1`) can only have
one. The decision is **14 everywhere**; terminal's default changes.

The reason no per-application override is offered is a property of the argument
parser, not a preference: the parsing entry point **default-constructs the parameter
struct internally**, so an application cannot seed a field before parsing and then
have the parse leave it alone. The alternatives were to parameterize the mixin
template for the benefit of one application, or to accept the unified default. The
latter was taken.

Close this entry when both applications ship the unified default and the change is
noted in their release notes — a default point size is user-visible.

Two related user-visible consequences of `CLI1`, tracked here because they land with
the same change: hue gains `--font-dir` and `--font-codepoint-map` (today internal to
its Android path), and both applications' `--help` flag ordering changes.

## UIAPP-O2 — Version propagation is assumed, not proven {#uiapp-o2}

**Status:** open. **Requirements:** `APP4`, `APP5`.

The host's backend arms are conditionally compiled behind a version identifier that a
dub **configuration** sets. Its public entry point is a template, so those arms are
resolved during the _consumer's_ compilation, and the design assumes dub propagates a
dependency's version identifiers to its dependents.

If that assumption is wrong, the fallback is to split the backend arms into their own
packages — a consumer then depends on exactly the arms it wants, with no
configuration, no version identifier and no propagation question. The requirement
tree is unaffected either way; only the manifests change.

Close this entry when the spike in [P1.0](./PLAN.md#phase-1) has run and the outcome
is recorded here.

## UIAPP-O3 — Non-interactive backends have no runtime shape yet {#uiapp-o3}

**Status:** open. **Requirements:** `BKD1`, `BKD5`.

`Backend` names four members, but the host only _drives_ two. The HTML and ANSI
members exist so that one vocabulary describes every sink an application can choose
(`BKD1`), and the loop is specified to report them as non-interactive rather than
attempt to open them.

What is not settled is whether the host should eventually own those sinks too — the
toolkit already has an HTML interpreter, and a non-interactive ANSI render is a
legitimate third target. Until an application asks for it, reporting is enough.

Close this entry when either the host grows the two sinks or the requirement is
narrowed to two members with the static sinks documented as application-owned.

## UIAPP-O4 — Coverage baseline and the excluded surface {#uiapp-o4}

**Status:** open. **Requirements:** `TST4`.

Nothing in the repository measures coverage today, and the three largest interactive
modules are invisible to any measurement that might exist, because they are excluded
from their unittest builds:

| Module                    | Lines | Why excluded                        |
| ------------------------- | ----- | ----------------------------------- |
| `apps/hue/src/gui.d`      | 2536  | links the GPU backend               |
| `apps/hue/src/app.d`      | 934   | holds `main`                        |
| `apps/terminal/src/app.d` | 1340  | holds `main`, links the GPU backend |
| **Total**                 | 4810  |                                     |

_Counted 2026-08-06, before any migration work._

[P0.1](./PLAN.md#phase-0) adds the measurement; [phase 2](./PLAN.md#phase-2) sets the
per-module targets. This entry holds the numbers so the delta is auditable rather
than remembered, and records the per-package coverage baseline once it is first
measured.

Close this entry when the phase-2 targets are met or the shortfall is explained here.

## UIAPP-O5 — Terminal-emulator rendering stays outside the display list {#uiapp-o5}

**Status:** open by design. **Requirements:** `HST3`.

`apps/terminal` migrates onto the host but keeps its own renderer, reached through
the host's direct-canvas level. Its paint loop walks a terminal screen cell by cell
and is benchmarked; expressing it as a display list would mean rebuilding a hot path
whose performance is a hard acceptance gate.

That is a legitimate use of the third render level rather than a shortcoming — but it
does mean one of the host's three consumers exercises the widget and display-list
levels only for its chrome. Revisit if the display list ever becomes cheap enough
that the distinction stops mattering; the measurement, not the aesthetics, decides.
