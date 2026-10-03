---
status: draft
owner: apps/font-explorer
reviewed:
---

# `font-explorer` — Delivery plan

_Delivery order for [`SPEC.md`](./SPEC.md). The font library's milestones are
in [`../font/PLAN.md`](../font/PLAN.md); each app milestone names the library
milestones it waits for._

| Milestone                                                 | Waits for (library)   | State       |
| --------------------------------------------------------- | --------------------- | ----------- |
| [Stage 0](#stage-0)                                       | —                     | in progress |
| [A1 `inspect` subcommand](#a1-inspect)                    | M1, M2                | not started |
| [A2 Explorer shell](#a2-explorer-shell)                   | M4, M5, layout chosen | not started |
| [A3 Specimens and inspector](#a3-specimens-and-inspector) | M3–M6                 | not started |
| [A4 Programming-font checks](#a4-programming-font-checks) | M4, M5                | not started |
| [A5 Library pane](#a5-library-pane)                       | M7                    | not started |
| [A6 Live terminal](#a6-live-terminal)                     | M8                    | not started |

## Stage 0

This specification accepted; mockups for every surface in
[`design.md`](./design.md) produced and one variant chosen per surface. Layout
work does not start before the choice; non-visual work may.

## A1 `inspect`

**Obligations.** `FXP7`–`FXP9`, `FXP4` for the command-line path.

**Deliverable.** `apps/font-explorer` with the `inspect` subcommand only; no
window code.

**Acceptance.** Report, JSON and CSS goldens over the bundled fonts; exit codes
for a non-font, a truncated font and a usage error; the JSON round-trips through
`sparkles:wired`.

## A2 Explorer shell

**Obligations.** `FXP1`–`FXP3`, `FXP5`, `FXP6`, `FXP14`, `FXP25` (info view).

**Deliverable.** The chosen layout on both arms with a preview specimen and the
info view; the image-op path end to end.

**Acceptance.** Recording-host op-stream goldens; a kitty byte-stream golden for
the terminal arm; `FXP1`'s grep check; the `FXP3` frame-with-no-change check.

## A3 Specimens and inspector

**Obligations.** `FXP15`–`FXP19`, `FXP25`, `FXP26`, `FXP27`.

## A4 Programming-font checks

**Obligations.** `FXP17` (code), `FXP20`–`FXP23`.

## A5 Library pane

**Obligations.** `FXP10`–`FXP13`, `FXP12`'s facets.

## A6 Live terminal

**Obligations.** `FXP24`.
