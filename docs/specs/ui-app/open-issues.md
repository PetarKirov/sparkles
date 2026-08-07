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

## UIAPP-O2 — Version propagation is proven {#uiapp-o2}

**Status:** closed — the spike ran and the assumption holds. **Requirements:**
`APP4`, `APP5`.

The host's backend arms are conditionally compiled behind a version identifier that a
dub **configuration** sets. Its public entry point is a template, so those arms are
resolved during the _consumer's_ compilation, and the design assumes dub propagates a
dependency's version identifiers to its dependents.

A two-package spike settles it. The library declares two configurations, one of
which sets a version identifier; the consumer selects between them with
`subConfiguration` and calls both a **template** with a version-gated arm (its
body analysed at the instantiation, in the consumer's compilation) and a
non-template (resolved in the library's own):

| Consumer's `subConfiguration` | Template arm | Non-template arm |
| ----------------------------- | ------------ | ---------------- |
| the version-setting one       | gated arm    | gated arm        |
| the plain one                 | plain arm    | plain arm        |
| none declared                 | plain arm    | plain arm        |

So a dependency's configuration `versions` **do** reach the dependent's
compilation, and a version-gated template arm resolves the way the selected
configuration says. `APP3`'s three configurations are viable as specified; the
package-split fallback is not needed.

Two things the spike also pins down, both worth knowing before the manifests are
written: a consumer that declares no `subConfiguration` gets the library's
**first** configuration, so the order of the blocks is load-bearing — the default
must be listed first; and the propagation is not special to templates, which
means a non-template helper behind the same gate behaves consistently rather than
silently taking the other arm.

Closed by the [P1.0](./PLAN.md#phase-1) spike.

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

**Status:** open by design — the embedding mechanism is now decided.
**Requirements:** `HST3`, `HST10`.

`apps/terminal` migrates onto the host but keeps its own renderer, reached through
the host's direct-canvas level. Its paint loop walks a terminal screen cell by cell
and is benchmarked; expressing it as a display list would mean rebuilding a hot path
whose performance is a hard acceptance gate.

That is a legitimate use of the third render level rather than a shortcoming — but it
does mean one of the host's three consumers exercises the widget and display-list
levels only for its chrome. Revisit if the display list ever becomes cheap enough
that the distinction stops mattering; the measurement, not the aesthetics, decides.

**How the two levels compose** (decided with `HST10`, built with
`libs/terminal-view`): the terminal core becomes a component whose `view` emits a
_keyed_ widget for its pane — `Widget.key` plus
`keyedRects(tree, frames)` already report a keyed node's laid-out rect, so
layout sizes and positions the pane like any other widget while the per-cell
renderer paints _into_ that rect through the backend canvas, clipped. No new
widget kind is needed and the closed sum ([`PRN12`](../ui/principles.md)) stands.
The missing piece is **when** that paint runs: on the GPU arm, canvas calls are
only valid inside the frame bracket (`beginFrame`/`endFrame`), which the loop
owns — so the arms need a post-layout paint hook in their draw phase. That hook
is deliberately designed in the `libs/terminal-view` PR, against the real
consumer, under the no-regression gate — not speculated here. Until it lands,
`runApp` (`HST10`) is widget-level only.
