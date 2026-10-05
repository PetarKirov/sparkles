---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Sparkles design system — Overview

## Abstract

The Sparkles design system has two deliverables that share one vocabulary. The
framework lets any `sparkles:ui` application express a design system as data:
named tokens for colors, lengths, glyphs and font roles, resolved the same way
for a terminal, a GPU window and a web page, with a published substitution
wherever a target cannot draw a request. Sparkles is the one concrete design
system, the brand that the repository's own applications and documentation
sites follow.

## Introduction

A design system replaces four separate mechanisms that each carry part of a
visual language. A [slot](../../glossary.md#slot) is the named role a widget
paints with instead of a color; the chrome palette is the set of colors for the
toolkit's own frames, bars and borders, as opposed to syntax colors. None of the
four is a design system on its own:

| Where                                                       | What it holds                                                                                           | What it cannot say                                          |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| [`sparkles.ui.theme.Theme`](../ui/theme.md)                 | 36 editor color schemes (syntax rules) with a chrome palette **derived** from `defaultFg`/`defaultBg`   | what a _hovered_ or _disabled_ thing looks like             |
| `sparkles.ui.style.Slot` / `Palette`                        | the slots and metrics widgets name, several of them one feature's (twoslash chips, diff rows, coverage) | which slots a component is allowed to use                   |
| `sparkles.ui.theme.GlyphSet`                                | whether non-ASCII glyphs may be drawn                                                                   | heavy vs light borders, status marks, sub-cell rules, icons |
| `docs/.vitepress/theme/custom.css` + `sparkles.docs.assets` | a hand-authored indigo/cyan site look; callout colors as hex literals                                   | anything the terminal or the window could reuse             |

The toolkit renders one widget tree to a character grid, a GPU window and
static HTML ([`TGT`](../ui/backends.md)); that parity is worth little if the
design language is authored four times. This tree makes the design language one
value with a defined projection onto each target's capabilities.

The framework is the token model ([design-token](../../glossary.md#design-token)
tiers, interaction states, [cell](../../glossary.md#cell) units), the
capability model with its [capability profiles](../../glossary.md#capability-profile), the glyph and typography projections, the keyboard
vocabulary, the CSS custom-property declaration and the theme file format, all
as data. Sparkles is one set of values for every token the framework declares,
specified as the default theme of `ui-gallery`, the docs sites and `hue`
([`SPK3`](./sparkles-theme.md)). A `hue`
user switching to `catppuccin-mocha` at runtime exercises the framework; the
docs site exercises Sparkles. The borrowed schemes remain valid themes: they
fill fewer tokens explicitly and inherit the rest through the framework's
fallback rules ([`TOK4`](./SPEC.md#interaction-states),
[`ACC2`](./SPEC.md#accessibility-acc)).

The design system does not own text measurement or fonts. Grid widths, width
profiles, cell wrapping and scaled cell footprints belong to `sparkles:base`
([base/text](../base/text/SPEC.md)); font matching and fallback to
[`sparkles:font`](../font/SPEC.md); proportional paragraph layout to
[`sparkles:text-layout`](../text-layout/SPEC.md). Following the operating
system's appearance is deferred to `sparkles:appearance`.

The sections below name the owner of every obligation, fix the target order,
relate this tree to the existing specifications, and list the pages.
[SPEC.md](./SPEC.md) holds the core contract; [PLAN.md](./PLAN.md) the delivery
order; [decisions.md](./decisions.md) the choices; [testing.md](./testing.md)
the oracles and evidence.

## Two products, one vocabulary

| Product           | What it is                                                                                                                                                                                                                                                                                | Owner                                                                                                |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| **the framework** | the token model (tiers, interaction states, units), the capability model with its [capability profiles](../../glossary.md#capability-profile), the glyph and typography projections, the keyboard vocabulary, the CSS custom-property declaration and the theme file format — all as data | `sparkles:ui` (types, resolution), `sparkles:tui`/`base` (capability probing), `sparkles:docs` (CSS) |
| **Sparkles**      | one concrete set of values for every token the framework declares: the brand                                                                                                                                                                                                              | [`sparkles-theme.md`](./sparkles-theme.md)                                                           |

## Owning library per obligation

An effort spanning packages names one owner per contract. Consumers link here;
they do not restate normative text.

| Obligation                                                              | Owner                                                                                                                                                      | Page                                               |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| Token tiers, paths, interaction states, units, component slot sets      | `sparkles:ui` (`tokens.d`, `style.d`)                                                                                                                      | [`SPEC.md`](./SPEC.md) `TOK`                       |
| Contrast floors, conformance labelling, never-color-alone               | `sparkles:ui` + the theme author                                                                                                                           | [`SPEC.md`](./SPEC.md) `ACC`                       |
| Theme file format (DTCG), load/save                                     | `sparkles:ui` types, `sparkles:wired` I/O                                                                                                                  | [`SPEC.md`](./SPEC.md) `FMT`                       |
| Capability flags, capability profiles, per-target application           | `sparkles:base` (`OutputCapabilities`, `TermCaps`), `sparkles:input` (`InputCapabilities`, `fromTerminal`), `sparkles:ui` (`TargetCapabilities`, profiles) | [`capabilities.md`](./capabilities.md)             |
| Detecting each terminal capability                                      | `sparkles:base` (env), `sparkles:tui` (query)                                                                                                              | [`capabilities.md`](./capabilities.md) `CAP3`      |
| Glyph tiers, border projection, sub-cell drawing, status marks          | `sparkles:ui` (`GlyphSet`), `sparkles:ui-tui`                                                                                                              | [`glyphs.md`](./glyphs.md)                         |
| Width profiles, grid widths, the glyph-channel exemption, long clusters | `sparkles:base` ([base/text](../base/text/SPEC.md#_6-cell-text-and-coordinates))                                                                           | [`glyphs.md`](./glyphs.md) `GLY3`, `GLY6`, `GLY12` |
| Cell wrapping and the pure line-breaking solvers                        | `sparkles:base` ([wrapping](../base/text/wrapping.md)); `sparkles:ui` keeps the policy                                                                     | [layout](../ui/layout.md) `LAY10`, `LAY14`         |
| Font roles and their values                                             | `sparkles:ui` (roles), the theme (values)                                                                                                                  | [`glyphs.md`](./glyphs.md) `GLY11`                 |
| Font matching, fallback chains, code-point routes                       | [`sparkles:font`](../font/SPEC.md#_13-discovery-matching-and-fallback)                                                                                     | [`glyphs.md`](./glyphs.md) `GLY11`                 |
| Proportional paragraphs inside cell rects                               | [`sparkles:text-layout`](../text-layout/SPEC.md)                                                                                                           | [`glyphs.md`](./glyphs.md) `GLY7`                  |
| Nerd Font pin, icon table, bundled faces                                | `nix/packages/fonts.nix`, [`FNT`](../hue/gui.md)                                                                                                           | [`glyphs.md`](./glyphs.md) `GLY4`                  |
| Scaled cell footprints for text sizing (OSC 66)                         | `sparkles:base` ([base/text](../base/text/SPEC.md)); whether a terminal honours it is the design system's (OQ5)                                            | [`glyphs.md`](./glyphs.md) `GLY5`                  |
| Default binding vocabulary                                              | `sparkles:ui` (`keymap.d` overlay)                                                                                                                         | [`keyboard.md`](./keyboard.md)                     |
| CSS custom properties, VitePress mapping, generated stylesheet          | `sparkles:docs`                                                                                                                                            | [`web.md`](./web.md)                               |
| The Sparkles values                                                     | this tree                                                                                                                                                  | [`sparkles-theme.md`](./sparkles-theme.md)         |
| Canonical component renderings (the Storybook role)                     | `apps/ui-gallery`                                                                                                                                          | [`testing.md`](./testing.md) `O1`                  |
| The public style guide (wireframes + fences)                            | `docs/design-system/` on the site                                                                                                                          | [`PLAN.md` M3](./PLAN.md)                          |

## Target sequencing

Every target is in scope; only the order is fixed, and the order is by
constraint severity:

1. **TUI first.** The character grid is the harshest target: integer units, no
   sub-cell geometry without block elements, and a capability set that must be
   _probed_. A design language that survives it survives the others.
2. **Responsive Web second.** It has the best-established design-system
   practice, the docs sites are a first consumer, and CSS custom properties are
   the framework's most direct externalization.
3. **GUI third.** The middle ground: cells scaled to pixels, so radius, shadow,
   smooth scrolling and proportional text become real.
4. **Mobile last.** The responsive web target covers part of it; `hue` on
   Android is outside the sequence's focus.

## Relationship to existing specs

| Spec                                                                                                                     | Relationship                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`THM`](../ui/theme.md)                                                                                                  | this tree **realises** `THM2` (widened vocabulary), `THM6` (one value), `THM8` (capability gating) and `THM9` (file-loadable); `THM` keeps its IDs |
| [`TGT5`](../ui/backends.md)                                                                                              | the "chrome half" of declared capabilities is [`CAP1`](./capabilities.md)                                                                          |
| [`WGT`](../ui/widgets.md)                                                                                                | every catalogued widget declares its slot set ([`TOK6`](./SPEC.md#interaction-states))                                                             |
| [`KEY`/`LTN`](../ui/keymap.md)                                                                                           | the vocabulary in [`keyboard.md`](./keyboard.md) is one overlay table per `KEY12`, not new machinery                                               |
| [`UGL`](../ui-gallery/index.md)                                                                                          | `ui-gallery` is the reference implementation whose `--render` output is the style guide ([`O1`](./testing.md))                                     |
| [`GAL`](../hue/gallery.md), [`sparkles:docs`](../docs/index.md)                                                          | the generated stylesheet consumes the CSS declaration in [`web.md`](./web.md)                                                                      |
| [base/text](../base/text/SPEC.md)                                                                                        | width profiles, cell wrapping, scaled footprints and the glyph-channel exemption, consumed by `GLY3`, `GLY5`, `GLY6` and `GLY12`                   |
| [font](../font/SPEC.md), [text layout](../text-layout/SPEC.md)                                                           | font roles resolve to font requests, chains and routes (`GLY11`); proportional docs text is a text-layout paragraph (`GLY7`)                       |
| [platform-ui-guidelines proposal](../../research/platform-ui-guidelines/sparkles-proposal.md)                            | OS-following (`sparkles:appearance`) is **deferred**; its palette derivation is adopted as the contrast oracle's tone model                        |
| [tui-libraries](../../research/tui-libraries/index.md), [text-sizing](../../research/tui-libraries/text-sizing/index.md) | the surveyed prior art; nothing here restates it                                                                                                   |

## Pages

| Page                                      | Owns                                                                                                                                    |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| [Specification](./SPEC.md)                | the framework contract: tokens (`TOK`), accessibility (`ACC`), the theme file format (`FMT`)                                            |
| [Capabilities](./capabilities.md)         | per-feature capability flags, the capability profiles, detection ownership and published degradation (`CAP`)                            |
| [Glyphs & typography](./glyphs.md)        | glyph tiers, border projection, sub-cell drawing, status marks, the Nerd Font baseline, font roles, text sizing, grapheme width (`GLY`) |
| [Keyboard vocabulary](./keyboard.md)      | the minimal default bindings every Sparkles application shares (`KBD`)                                                                  |
| [Web](./web.md)                           | the CSS custom-property declaration, the generated stylesheet, the VitePress mapping, responsive breakpoints (`WEB`)                    |
| [The Sparkles theme](./sparkles-theme.md) | constraints on, and the delivery of, the concrete brand values (`SPK`)                                                                  |
| [Testing](./testing.md)                   | oracles and the evidence ledger                                                                                                         |
| [Delivery plan](./PLAN.md)                | milestones, gates, exclusions                                                                                                           |
| [Decisions](./decisions.md)               | the recorded choices and open questions                                                                                                 |

**Status legend** (requirement rows): `not started` · `partial` · `full` ·
`proposed` (contract drafted, no acceptance). Evidence uses `unverified` /
`partial` / `verified` per [the spec guideline](../../guidelines/spec-docs.md).
