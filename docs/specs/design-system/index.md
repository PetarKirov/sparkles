# Sparkles design system — Overview

_**Status:** proposed (Stage 0 in progress) · **Date:** 2026-09-21 · **Scope:**
two deliverables that share one vocabulary — the **framework** by which any
`sparkles:ui` application expresses a design system as data, and **Sparkles**,
the one concrete design system the repository's own applications and
documentation sites follow._

## Why

A "theme" means four unrelated things in this repository today, and none of
them is a design system:

| Where                                                       | What it holds                                                                                                           | What it cannot say                                                          |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| [`sparkles.ui.theme.Theme`](../ui/theme.md)                 | 36 editor color schemes (syntax rules) with a chrome palette **derived** from `defaultFg`/`defaultBg`                   | what a _hovered_ or _disabled_ thing looks like — the slot set has no state |
| `sparkles.ui.style.Slot` / `Palette`                        | ~36 slots, half of them one feature's (twoslash chips, diff rows, coverage), metrics named after popups, mixed px/cells | which slots a component is allowed to use                                   |
| `sparkles.ui.theme.GlyphSet`                                | one `bool unicode`                                                                                                      | heavy vs light borders, status marks, sub-cell rules, icons                 |
| `docs/.vitepress/theme/custom.css` + `sparkles.docs.assets` | a hand-authored indigo/cyan site look; five callout colors as hex literals                                              | anything the terminal or the window could reuse                             |

The toolkit renders one widget tree to a cell grid, a GPU window and static
HTML ([`TGT`](../ui/backends.md)); that parity is worthless if the _design
language_ is authored four times. This tree makes the design language one
value with a defined projection onto each target's capabilities.

## Two products, one vocabulary

| Product           | What it is                                                                                                                                                                                                           | Owner                                                                                                |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **the framework** | the token model (tiers, interaction states, units), the capability model, the glyph and typography projections, the keyboard vocabulary, the CSS custom-property declaration and the theme file format — all as data | `sparkles:ui` (types, resolution), `sparkles:tui`/`base` (capability probing), `sparkles:docs` (CSS) |
| **Sparkles**      | one concrete set of values for every token the framework declares: the brand. The default theme of `ui-gallery`, the docs sites and, later, `hue`                                                                    | [`sparkles-theme.md`](./sparkles-theme.md)                                                           |

A `hue` user switching to `catppuccin-mocha` at runtime is exercising the
framework; the docs site is exercising Sparkles. The 36 borrowed schemes remain
valid themes — they simply fill fewer tokens explicitly and inherit the rest
through the framework's fallback rules ([`TOK4`](./SPEC.md#interaction-states),
[`ACC2`](./SPEC.md#accessibility)).

## Owning library per obligation

An effort spanning packages must name one owner per contract. Consumers link
here; they do not restate normative text.

| Obligation                                                         | Owner                                                                                                    | Page                                          |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- | --------------------------------------------- |
| Token tiers, paths, interaction states, units, component slot sets | `sparkles:ui` (`tokens.d`, `style.d`)                                                                    | [`SPEC.md`](./SPEC.md) `TOK`                  |
| Contrast floors, conformance labelling, never-color-alone          | `sparkles:ui` + the theme author                                                                         | [`SPEC.md`](./SPEC.md) `ACC`                  |
| Theme file format (DTCG), load/save                                | `sparkles:ui` types, `sparkles:wired` I/O                                                                | [`SPEC.md`](./SPEC.md) `FMT`                  |
| Capability flags, profiles, per-target application                 | `sparkles:ui`                                                                                            | [`capabilities.md`](./capabilities.md)        |
| Detecting each terminal capability                                 | `sparkles:base` (env), `sparkles:tui` (query)                                                            | [`capabilities.md`](./capabilities.md) `CAP3` |
| Glyph tiers, border projection, sub-cell drawing, status marks     | `sparkles:ui` (`GlyphSet`), `sparkles:ui-tui`                                                            | [`glyphs.md`](./glyphs.md)                    |
| Nerd Font pin, icon table, bundled faces                           | `nix/packages/fonts.nix`, [`FNT`](../hue/gui.md)                                                         | [`glyphs.md`](./glyphs.md) `GLY4`             |
| Text sizing (OSC 66) and its fallback                              | [text-sizing proposal](../../research/tui-libraries/text-sizing/sparkles-proposal.md) — **not accepted** | [`glyphs.md`](./glyphs.md) `GLY5`             |
| Default binding vocabulary                                         | `sparkles:ui` (`keymap.d` overlay)                                                                       | [`keyboard.md`](./keyboard.md)                |
| CSS custom properties, VitePress mapping, generated stylesheet     | `sparkles:docs`                                                                                          | [`web.md`](./web.md)                          |
| The Sparkles values                                                | this tree                                                                                                | [`sparkles-theme.md`](./sparkles-theme.md)    |
| Canonical component renderings (the Storybook role)                | `apps/ui-gallery`                                                                                        | [`testing.md`](./testing.md) `O1`             |
| The public style guide (wireframes + fences)                       | `docs/design-system/` on the site                                                                        | [`PLAN.md` M3](./PLAN.md)                     |

## Target sequencing

Every target is in scope; only the order is fixed, and the order is by
constraint severity:

1. **TUI first.** The cell grid is the harshest target — integer units, no
   sub-cell geometry without block elements, a capability set that must be
   _probed_. A design language that survives it survives the others.
2. **Responsive Web second.** Best-established design-system practice; the
   docs sites are a first consumer; CSS custom properties are the framework's
   most direct externalization.
3. **GUI third.** The middle ground: cells scaled to pixels, so radius,
   shadow, smooth scrolling and proportional text become real.
4. **Mobile last.** Partly covered by the responsive web target; `hue` on
   Android is not a current focus.

## Relationship to existing specs

| Spec                                                                                                                     | Relationship                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`THM`](../ui/theme.md)                                                                                                  | this tree **realises** `THM2` (widened vocabulary), `THM6` (one value), `THM8` (capability gating) and `THM9` (file-loadable); `THM` keeps its IDs |
| [`TGT5`](../ui/backends.md)                                                                                              | the "chrome half" of declared capabilities is [`CAP1`](./capabilities.md)                                                                          |
| [`WGT`](../ui/widgets.md)                                                                                                | every catalogued widget declares its slot set ([`TOK6`](./SPEC.md#component-slot-declarations))                                                    |
| [`KEY`/`LTN`](../ui/keymap.md)                                                                                           | the vocabulary in [`keyboard.md`](./keyboard.md) is one overlay table per `KEY12`, not new machinery                                               |
| [`UGL`](../ui-gallery/index.md)                                                                                          | `ui-gallery` becomes the reference implementation whose `--render` output is the style guide ([`O1`](./testing.md))                                |
| [`GAL`](../hue/gallery.md), [`sparkles:docs`](../docs/index.md)                                                          | the generated stylesheet consumes the CSS declaration in [`web.md`](./web.md)                                                                      |
| [platform-ui-guidelines proposal](../../research/platform-ui-guidelines/sparkles-proposal.md)                            | OS-following (`sparkles:appearance`) is **deferred**; its palette derivation is adopted as the contrast oracle's tone model                        |
| [tui-libraries](../../research/tui-libraries/index.md), [text-sizing](../../research/tui-libraries/text-sizing/index.md) | the surveyed prior art; nothing here restates it                                                                                                   |

## Pages

| Page                                      | Owns                                                                                                                        |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| [Specification](./SPEC.md)                | the framework contract: tokens (`TOK`), accessibility (`ACC`), the theme file format (`FMT`)                                |
| [Capabilities](./capabilities.md)         | per-feature capability flags, the documented profiles, detection ownership and published degradation (`CAP`)                |
| [Glyphs & typography](./glyphs.md)        | glyph tiers, border projection, sub-cell drawing, status marks, the Nerd Font baseline, text sizing, grapheme width (`GLY`) |
| [Keyboard vocabulary](./keyboard.md)      | the minimal default bindings every Sparkles application shares (`KBD`)                                                      |
| [Web](./web.md)                           | the CSS custom-property declaration, the generated stylesheet, the VitePress mapping, responsive breakpoints (`WEB`)        |
| [The Sparkles theme](./sparkles-theme.md) | constraints on, and the delivery of, the concrete brand values (`SPK`)                                                      |
| [Testing](./testing.md)                   | oracles and the evidence ledger                                                                                             |
| [Delivery plan](./PLAN.md)                | milestones, gates, exclusions                                                                                               |
| [Decisions](./decisions.md)               | the recorded choices and open questions                                                                                     |

**Status legend** (requirement rows): `not started` · `partial` · `full` ·
`proposed` (contract drafted, no acceptance yet). Evidence uses `unverified` /
`partial` / `verified` per [the spec guideline](../../guidelines/spec-docs.md).
