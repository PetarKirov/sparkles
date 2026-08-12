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

_Re-counted 2026-08-09: `gui.d` 3162, hue `app.d` 1325, terminal `app.d`
**114** (the `terminal-view` extraction landed its target); total 4601. The
hue modules grew while they waited — the audit trail the
[P2.B targets](./PLAN.md#excluded-surface-targets-tst4) now carry._

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

## UIAPP-O6 — Host `canvas` is not always an lvalue {#uiapp-o6}

**Status:** open (workaround shipped). **Requirements:** `HST3`, `HST13`.

Both live hosts expose the third render level as a **factory method** that
returns a by-value handle each call:

```d
// GuiHost
RaylibCanvas canvas() => RaylibCanvas(&session.fonts, &drawScratch, cellW, cellH);

// TuiHost
auto canvas() => GridCanvas(&session.grid, pageBg);
```

That is convenient for the arms: the canvas is a cheap view over session state
(fonts / grid / current cell metrics), so reconstructing it picks up a
`fontSize` change, starts with an empty clip stack, and needs no long-lived
object on the host. The recorder, by contrast, keeps `RecordingCanvas` as a
**field** — it owns the captured ops, so mutations must hit that field.

The asymmetry is load-bearing at the call site. The immediate interpreter's
`paint` used to take plain `ref Canvas`; a live temporary could not bind, and
`auto c = h.canvas; paint(c, ops)` discarded the recorder's capture. The
shipped workaround is `auto ref` on `paint` (`libs/ui/interp/immediate.d`), so
`.paint(h.canvas, ops)` is correct on every host: lvalue by reference, rvalue
by value. That is an interpreter patch for a host-contract gap, not a claim
that by-value is a canvas property.

The right shape is still undecided:

1. **Stable lvalue on every host** — a field (or `ref` return) refreshed at the
   start of the frame bracket, so `paint` can go back to plain `ref` and every
   consumer writes `.paint(h.canvas, ops)` without thinking about binding.
2. **Leave the factory methods** and keep `auto ref` as the permanent answer —
   document that live canvases are ephemeral handles and that the recorder is
   the one host whose canvas is owned state.

(1) tightens the host concept; (2) accepts the split. Either way the application
must not branch on canvas type (diagram briefly did; that path is gone).

Close this entry when the host contract states one rule for `canvas` (lvalue
everywhere, or "handle by value, recorder is the exception") and the live arms,
the recorder, and `paint`'s parameter match that rule with no `auto ref` needed
only as a compatibility shim — or when (2) is chosen and the DDoc on `paint` /
`HST3` records the exception as intentional.
