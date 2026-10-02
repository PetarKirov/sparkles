# Design: the mockup register

_**Status:** open — no mockup chosen yet · **Date:** 2026-10-02 · **Owner:**
the repository owner chooses; `apps/terminal` implements · **Scope:** how each
surface of the terminal's own UI will look and be laid out, and the rules
every candidate must meet._

Every surface's **layout** stays open until one of its mockups is chosen
([D10](./decisions.md)): 2–3 HTML variants each, made in Claude Design for
rapid iteration, at three sizes — phone portrait, phone landscape, desktop.
Behaviour is already agreed in the requirement pages; a mockup decides
arrangement, density, affordance shape and motion. A row whose status is
`open` changes to `not started` with a link to the chosen variant.

## Rules every variant must meet

From the [design system](../design-system/index.md) and the
[theme](../ui/theme.md) — not restated, only applied:

- **Slots, not colours** ([`THM1`](../ui/theme.md)); each implemented
  component declares its slot set with a test ([`TOK6`](../design-system/SPEC.md)).
- **The chrome's colours derive from the terminal's** ([D17](./decisions.md)):
  every variant is shown over a dark and a light terminal scheme, and over one
  saturated Termux scheme, to prove it tracks.
- **Interaction states** ([`TOK4`/`TOK5`](../design-system/SPEC.md)): rest,
  hover (desktop), focused, selected, pressed, disabled are drawn for every
  control.
- **Focus visible in monochrome** ([`ACC4`](../design-system/SPEC.md)), and
  **never colour alone** for status ([`ACC3`](../design-system/SPEC.md)).
- **Cells are the unit** ([`TOK7`](../design-system/SPEC.md)); touch targets
  are at least 48 dp; radius and shadow are px metrics with a cell projection.
- **Reduced motion** ([`ACC5`](../design-system/SPEC.md)) has a defined
  rendering for every animation.
- **The keyboard is the program's** ([`TKM2`](./keymap.md)): no surface may
  assume a key the pane would lose.

## Surfaces

| Surface                                  | Rows it decides                    | Variants | Chosen |
| ---------------------------------------- | ---------------------------------- | -------- | ------ |
| Workspace: tab strip, splits, headers    | `TSS11`, `TSS12`, `TSS13`          | —        | —      |
| Extra-keys row (and its show/hide)       | `TCF7`, `TKM7`                     | —        | —      |
| Selection handles and the selection menu | `TSE3`, `TSE5`                     | —        | —      |
| Link confirm bar                         | [`TPR5`](./protocols.md)           | —        | —      |
| Paste and OSC 52 read confirmations      | [`TPR19`, `TPR21`](./protocols.md) | —        | —      |
| Exit prompt                              | `TSS2`                             | —        | —      |
| Autofill chip                            | `TSE10`                            | —        | —      |
| Settings page                            | `TSP5`, `TSP6`                     | —        | —      |
| About page                               | [`TPG1`–`TPG3`](./pages.md)        | —        | —      |
| Log page                                 | `TPG8`                             | —        | —      |
| Notification log, unseen marks, toasts   | `TPG9`–`TPG11`                     | —        | —      |
| Touch lantern guide                      | `TKM6`                             | —        | —      |

→ [Overview](./index.md) · [Decisions](./decisions.md)
