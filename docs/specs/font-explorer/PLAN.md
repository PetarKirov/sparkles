---
status: draft
owner: sparkles:font-explorer
reviewed:
---

# `font-explorer` — Delivery plan

_Delivery order for [`SPEC.md`](./SPEC.md). The font library's milestones
(`M`) are in [`../font/PLAN.md`](../font/PLAN.md) and text-layout's (`TL-M`) in
[`../text-layout/PLAN.md`](../text-layout/PLAN.md); each app milestone names
the library milestones it waits for._

| Milestone                                                 | Waits for (libraries) | State       |
| --------------------------------------------------------- | --------------------- | ----------- |
| [Stage 0](#stage-0)                                       | —                     | in progress |
| [A1 `inspect` subcommand](#a1-inspect)                    | M1, M2                | not started |
| [A2 Explorer shell](#a2-explorer-shell)                   | M3, M5                | not started |
| [A3 Specimens and inspector](#a3-specimens-and-inspector) | M3–M6, TL-M3          | not started |
| [A4 Programming-font checks](#a4-programming-font-checks) | M5, TL-M3             | not started |
| [A5 Library pane](#a5-library-pane)                       | M7, TL-M3             | not started |
| [A6 Live terminal](#a6-live-terminal)                     | M8                    | not started |

Every text specimen waits for TL-M3, text-layout's shaped flow, because
`FXP35` composes specimens there and nowhere else. TL-M3 itself waits for font
M2, M4 and M7. The glyph map draws glyphs by ID, so the shell proves the image
path with it before any text is composed.

## Stage 0

This specification accepted, and one mockup variant chosen per surface in
[`design.md`](./design.md).

**Progress.** Variants were chosen on 2026-10-03 and the chosen explorer was
redrawn at each width class. Acceptance of the specification is open.

## A1 `inspect`

**Obligations.** `FXP7`–`FXP9`, `FXP4` for the command-line path.

**Deliverable.** `apps/font-explorer` with the `inspect` subcommand only; no
window code.

**Acceptance.** Report, JSON and CSS goldens over the bundled fonts; exit codes
for a non-font, a truncated font and a usage error; the JSON round-trips through
`sparkles:wired`.

## A2 Explorer shell

**Obligations.** `FXP1`–`FXP3`, `FXP5`, `FXP6`, `FXP18`, `FXP25` (info view),
`FXP32`, `FXP33`.

**Deliverable.** The chosen layout on both arms with the glyph map and the
info view; the image-op path end to end.

**Acceptance.** Recording-host op-stream goldens; a kitty byte-stream golden for
the terminal arm; `FXP1`'s grep check; the `FXP3` frame-with-no-change check.

## A3 Specimens and inspector

**Obligations.** `FXP14`–`FXP17`, `FXP19`, `FXP25`–`FXP27`, `FXP30`, `FXP35`.

## A4 Programming-font checks

**Obligations.** `FXP17` (code), `FXP20`–`FXP23`, `FXP31`, `FXP34`.

## A5 Library pane

**Obligations.** `FXP10`–`FXP13`, `FXP28`, `FXP29`.

## A6 Live terminal

**Obligations.** `FXP24`.
