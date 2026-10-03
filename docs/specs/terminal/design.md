---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Design: the mockup register

## Introduction

The terminal draws its own interface on every platform: the tab tree, pane
headers, menus, confirmations and pages. Requirements fix what each
[surface](../../glossary.md#surface) does, but not how it is arranged, and an
arrangement that reads well on a desktop can fail on a phone held upright or
in landscape. Choosing a layout from prose alone tends to settle on the first
idea written down.

Each surface's layout is therefore chosen by the repository owner from two or
three HTML mockups, drawn at three sizes (phone portrait, phone landscape and
desktop) and shown over dark, light and saturated terminal schemes
([D10](./decisions.md)). A mockup decides arrangement, density, the shape of
an affordance and motion; behaviour stays with the requirement pages, and
`apps/terminal` implements the chosen variant.

This page registers every surface, its variants and the choice, and states the
rules any variant must meet. A requirement whose layout waits on a choice has
the status `open`, meaning undecided; once its mockup is chosen it becomes
`not started`, meaning decided but not built, with a link to the chosen
variant. Behaviour, and the design system's own tokens and rules, are out of
scope here: the requirement pages and the
[design system](../design-system/index.md) own them.

## Rules every variant must meet

From the [design system](../design-system/index.md) and the
[theme](../ui/theme.md), applied rather than restated:

- **[Slots](../../glossary.md#slot), not colours** ([`THM1`](../ui/theme.md));
  each implemented component declares its slot set with a test
  ([`TOK6`](../design-system/SPEC.md)).
- **The chrome's colours derive from the terminal's**
  ([D17](./decisions.md)): every variant is shown over a dark and a light
  terminal scheme, and over one saturated Termux scheme, to prove it tracks.
- **[Interaction states](../../glossary.md#interaction-state)**
  ([`TOK4`/`TOK5`](../design-system/SPEC.md)): rest, hover (desktop), focused,
  selected, pressed and disabled are drawn for every control.
- **Focus visible in monochrome** ([`ACC4`](../design-system/SPEC.md)), and
  **never colour alone** for status ([`ACC3`](../design-system/SPEC.md)).
- **[Cells](../../glossary.md#cell) are the unit**
  ([`TOK7`](../design-system/SPEC.md)); touch targets are at least 48 dp;
  radius and shadow are pixel metrics with a cell projection.
- **Reduced motion** ([`ACC5`](../design-system/SPEC.md)) has a defined
  rendering for every animation.
- **The keyboard is the program's** ([`TKM2`](./keymap.md)): no surface may
  assume a key the pane would lose.
- **Large screens take the desktop's arrangement** ([D47](./decisions.md)):
  on a screen at least 600 dp across, the rail stays in portrait, the
  selection menu is the anchored card ([`TCF14`](./config.md)), and pages and
  sheets are at most 100 columns wide ([`TPG19`](./pages.md)).

## Surfaces

Three canvases hold the variants:
[workspace](https://claude.ai/artifact/PiwEvu54XJK3mkSZFWh7QB),
[overlays](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq) and
[pages](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX). Each artboard has
a dark and light switch, and some are interactive. A chosen variant is
recorded here and in [decisions](./decisions.md). Once a surface is decided,
the variants it rejected are removed from the canvas; the register keeps
their names (S1, S3, E2, G1, G2, C2, LG2, N1, K1, K2).

| Surface                                  | Rows it decides                                    | Variants                                                                     | Chosen                                                                                                               |
| ---------------------------------------- | -------------------------------------------------- | ---------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| Workspace: tab strip, splits, headers    | `TSS11`, `TSS12`, `TSS13`                          | [E](https://claude.ai/artifact/PiwEvu54XJK3mkSZFWh7QB)                       | **E**, opener by `ui.tabsOpener`, chrome by `ui.paneChrome` ([`TCF12`, `TCF13`](./config.md), [D42](./decisions.md)) |
| Extra-keys row (and its show/hide)       | `TCF7`, `TKM7`                                     | [E](https://claude.ai/artifact/PiwEvu54XJK3mkSZFWh7QB)                       | **E**: the row under the terminal, above the keyboard                                                                |
| Selection handles and the selection menu | [`TSE3`, `TSE5`](./selection.md)                   | [S2, B1–B4, X1–X3](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)        | **all**, chosen by `ui.selectionMenu` ([`TCF11`](./config.md)); X1 on the desktop ([D41](./decisions.md))            |
| Button labels                            | [`TCF9`](./config.md)                              | [S2, E1, L3, D1 (Tweaks)](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq) | a setting ([D35](./decisions.md))                                                                                    |
| Confirmations: anchored card or sheet    | [`TCF10`](./config.md)                             | [CA1–CA4, CS1–CS4](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)        | **both**, chosen by `ui.overlayStyle` ([D41](./decisions.md))                                                        |
| Link confirm                             | [`TPR5`](./protocols.md)                           | [L1, L2](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                  | **both presentations** ([D41](./decisions.md))                                                                       |
| File link                                | [`TDV12`](./viewer.md)                             | [L3](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                      | **both presentations** ([D41](./decisions.md))                                                                       |
| Paste guard                              | [`TPR19`](./protocols.md)                          | [P1](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                      | **both presentations** ([D41](./decisions.md))                                                                       |
| OSC 52 read confirmation                 | [`TPR21`](./protocols.md)                          | [P2](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                      | **P2** ([D40](./decisions.md))                                                                                       |
| Exit prompt                              | [`TSS2`](./sessions.md)                            | [E1, E2](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                  | **E1**, expanding status line ([D39](./decisions.md))                                                                |
| Autofill chip                            | [`TSE10`](./selection.md)                          | [A1](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                      | **A1** ([D40](./decisions.md))                                                                                       |
| Desktop context menu and link bar        | [`TSE7`](./selection.md), [`TPR7`](./protocols.md) | [D1](https://claude.ai/artifact/RacV5BXgLBvk198GrcLUyq)                      | **D1** ([D40](./decisions.md))                                                                                       |
| Settings page                            | [`TSP5`–`TSP8`](./config.md)                       | [G1, G2, G3, G4](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)          | **G3**, with the G4 capture editor ([D36](./decisions.md), [D37](./decisions.md))                                    |
| About and credits pages                  | [`TPG1`–`TPG3`, `TPG15`](./pages.md)               | [C1, C2](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)                  | **C1** ([D40](./decisions.md))                                                                                       |
| Log page                                 | [`TPG8`](./pages.md)                               | [LG1, LG2](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)                | **LG1** ([D40](./decisions.md))                                                                                      |
| Notification log, unseen marks           | [`TPG9`–`TPG11`, `TPG18`](./pages.md)              | [N1, N2](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)                  | **N2**, with a grouping control ([D38](./decisions.md))                                                              |
| Touch key guide                          | [`TKM6`](./keymap.md)                              | [K1, K2, K3](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)              | **K3**, search at the bottom ([D40](./decisions.md))                                                                 |
| Viewer pane                              | [`TDV5`, `TDV6`](./viewer.md)                      | [V1, V2](https://claude.ai/artifact/LS6JhR9X6iPq7Ysv8UFUXX)                  | **both**: tab and split ([D40](./decisions.md))                                                                      |

→ [Overview](./index.md) · [Decisions](./decisions.md)
