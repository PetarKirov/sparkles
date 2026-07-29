# `sparkles:ui` theme — Feature Requirements (`THM`)

_**Status:** planned · **Date:** 2026-07-29 · **Scope:** the unified,
runtime-swappable design language — syntax highlighting rules, semantic widget
slots, glyph sets and chrome metrics in one value, gated by terminal
capabilities._

## Design & rationale

A "theme" today means three unrelated things in this repository: an ordered list
of dotted selectors mapping syntax labels to text styles; a semantic
`Slot → Visual` palette with scalar chrome metrics; and a terminal `Theme`
carrying 16-color roles, box-drawing charsets and status glyphs. They share no
vocabulary, they are configured separately, and two different enums are even
named `BorderStyle` with different meanings.

That split is wrong for the goal: **an application should express its whole
design language as one value the user can swap at runtime.** Whether a code
keyword is mauve, whether a popup border is rounded or square, and whether a
table uses heavy or light box-drawing are all the same kind of decision.

The unification is cheap because the syntax rules' value type is already a
`base` text-style type — the merged theme needs no syntax types at all, so
placing it in `sparkles:ui` does not drag a highlighting engine into the
toolkit. It goes the other way: `sparkles:syntax` consumes the theme.

### Channels

| Channel     | Content                                                                                                                  | Replaces                           |
| ----------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------- |
| **syntax**  | ordered rules mapping dotted label selectors to text styles; resolved once against a label vocabulary into an O(1) table | `sparkles.syntax.theme`            |
| **slots**   | semantic role → resolved appearance (fg/bg with alpha, attributes, border, shadow, font role/scale)                      | `sparkles.ui.style.Palette`        |
| **glyphs**  | box-drawing charsets and border presets, table glyphs, status marks, tree guides, meter and spinner frames               | `core_cli.ui.theme` + table glyphs |
| **metrics** | scalar chrome — corner radius, paddings, gaps, border widths, shadow offsets, font scales, arrow size                    | `Palette`'s scalar fields          |

## Requirements

| ID   | Requirement                                                                                                                                                                                                                                                          | Status      | Traces to                                    |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------- |
| THM1 | A widget must reference a **semantic slot**, never a concrete color; resolution to concrete appearance happens during display-list construction, so the tree stays presentation-free.                                                                                | full        | `style.d` `Slot`; `display_list.d`           |
| THM2 | The slot vocabulary must cover **general design-system roles** — surfaces, borders, text emphasis levels, semantic status (error/warn/info/success), interactive accents, selection, focus, muted/disabled — not only the roles one consumer happened to need first. | partial     | `style.d` `Slot`                             |
| THM3 | Slot resolution must yield a **`Visual`** carrying foreground, background, alpha, text attributes, border, radius, shadow, font role and font scale, so every backend reads one resolved value.                                                                      | full        | `style.d` `Visual`, `resolveVisual`          |
| THM4 | Chrome **metrics** must live in the theme, not be hardcoded in views, so a theme can restyle spacing and border weight without code changes.                                                                                                                         | full        | `style.d` `Palette` scalar fields            |
| THM5 | Where the theme is mirrored by a stylesheet, the D values and the CSS must be asserted **in lockstep by tests**, so drift is a build failure rather than a visual regression.                                                                                        | full        | twoslash `paletteLockstep`/`metricsLockstep` |
| THM6 | A **single `Theme` value** must carry all four channels — syntax rules, slots, glyphs and metrics — so an application expresses its design language once.                                                                                                            | not started | proposed `sparkles.ui.theme`                 |
| THM7 | Themes must be **swappable at runtime**: re-resolving a theme must rebuild every derived table and repaint, with no restart and no stale cached color anywhere.                                                                                                      | partial     | proposed `Theme.resolve`                     |
| THM8 | Glyph selection must be **capability-gated** — a terminal reporting no Unicode support gets the ASCII charset, and color output is gated on the detected color tier — from the capability snapshot, not from per-call flags threaded by hand.                        | not started | `base.term_caps.TermCaps`                    |
| THM9 | The theme must be **plain data**, loadable from a file (and serializable back) without code changes, so users can ship their own. Parsing formats are out of scope here; the requirement is that the value contains no code.                                         | researched  | proposed theme file format                   |

> [!NOTE]
> `THM2` is the one substantive widening. The shipped slot set was designed for a
> single overlay feature and has no interaction-state axis and no general
> accent/selection/focus roles. A design language for a whole application needs
> them, and the widget catalog in [widgets.md](./widgets.md) cannot be expressed
> without them.

## Milestones

| Milestone | Scope                                                             | Status      | Requirements |
| --------- | ----------------------------------------------------------------- | ----------- | ------------ |
| H0        | Slot vocabulary widened to general design-system roles            | not started | `THM2`       |
| H1        | Single `Theme` value with all four channels; syntax rules move in | not started | `THM6`       |
| H2        | Capability gating of glyphs and color tier                        | not started | `THM8`       |
| H3        | Runtime swap across every backend, with derived tables rebuilt    | not started | `THM7`       |
| H4        | File-loadable themes                                              | not started | `THM9`       |

## Module coverage

| Source file                              | Requirements   |
| ---------------------------------------- | -------------- |
| `libs/ui/src/sparkles/ui/style.d`        | `THM1`–`THM5`  |
| `libs/ui/src/sparkles/ui/theme.d`        | `THM6`–`THM9`  |
| `libs/ui/src/sparkles/ui/display_list.d` | `THM1`, `THM3` |

## Relationship to existing specs

| Piece                              | Role in theming                                                 |
| ---------------------------------- | --------------------------------------------------------------- |
| `sparkles:syntax` label vocabulary | the selector space the syntax channel resolves against          |
| `sparkles.base.term_style`         | the underlying text-style and color value types                 |
| `sparkles.base.term_caps`          | the capability snapshot gating glyphs and color tier (`THM8`)   |
| [widgets.md](./widgets.md) `WGT`   | the consumers of slots; `THM2`'s widened vocabulary serves them |
| [backends.md](./backends.md) `TGT` | per-target degradation of chrome the theme requests             |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Backends](./backends.md)
