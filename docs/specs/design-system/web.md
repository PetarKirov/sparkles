---
status: draft
owner: sparkles:docs
reviewed: 2026-10-05
---

# Web (`WEB`)

## Abstract

The `sparkles:ui` design system reaches web pages as CSS custom properties.
This page specifies how the framework names a property for each token,
how `sparkles:docs` emits a stylesheet of values from a theme, how the
documentation sites consume that stylesheet without authoring colors of their
own, and how responsive breakpoints are expressed in character columns so a
layout behaves the same on the web as in a terminal of that width.

## Introduction

The web has the most established design-system practice: tokens become CSS
custom properties, components read them, and a theme is a stylesheet of values.
The repository's two documentation sites — the project site, built with
VitePress, and the pages `sparkles:docs` generates, such as `hue gallery`'s —
are the first consumers of
[Sparkles](./sparkles-theme.md), which is why the web is sequenced second, after
the terminal ([overview](./index.md#target-sequencing)).

The gap is drift. A hand-authored site stylesheet invents its own names and
hex values, and nothing ties it to the theme a terminal application renders.
The approach is that the framework owns the property names, derived from the
token paths, and the theme owns the values. The sites map their own variables
from the generated properties and never author a color, and a test diffs the
committed stylesheet against a fresh emission. Responsive breakpoints are
measured in character columns (CSS `ch` units of the mono face), so a page
collapses at the widths where a terminal layout does.

Interactive web output beyond static CSS, and following the operating system's
appearance, are out of scope. Delivery order lives in [PLAN.md](./PLAN.md)
(M6), and the open choice between suffixed properties and pseudo-class rules is
[OQ4](./decisions.md#open-questions).

## Contract at a glance

1. Every custom-property name is produced from the token path by one function.
2. One stylesheet is emitted from a theme and imported by both sites.
3. VitePress consumes the generated properties and authors none.
4. Breakpoints are in columns, not device pixels.

## Requirements

| ID     | Requirement                                                                                                                                                                                                                      | Status   | Traces to                                                      |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | -------------------------------------------------------------- |
| `WEB1` | The framework **must** declare the CSS custom properties: one `--spk-<path>` per token ([`TOK2`](./SPEC.md)) and one `--spk-<path>-<state>` per state override a theme sets ([`TOK4`](./SPEC.md)), named by `cssName`.           | proposed | `tokens.d` `cssName`; `sparkles.docs.assets`                   |
| `WEB2` | The **theme defines the values**: `sparkles.docs.assets` **must** emit one stylesheet from a `Theme`, light values unscoped and dark values under `html.dark` and `@media (prefers-color-scheme: dark)`.                         | partial  | `assets.d` `themeStylesheet` (syntax only; callouts hardcoded) |
| `WEB3` | **VitePress consumes, never authors.** `custom.css` **must** map its own variables _from_ `--spk-*` in one mapping block, and a test **must** diff the committed stylesheet against a fresh emission. Responsive breakpoints are |

measured in character columns (CSS `ch` units of the mono face), so a page
collapses at the widths where a terminal layout does. | not started | `docs/.vitepress/theme/custom.css` (hand-authored) |
| `WEB4` | The **`html_semantic` interpreter** ([`TGT4`](../ui/backends.md)) **must** emit class names derived from slot paths (`.spk-text-primary`) and use the same emitted stylesheet. | partial | `interp/html_semantic.d` (own class scheme) |
| `WEB5` | Responsive breakpoints **must** be **in columns**: 80, 120 and 160, mapped to px through the mono face's `1ch`, as container queries over `ch` units, not device px. | not started | |
| `WEB6` | Each [font role](../../glossary.md#font-role) ([`GLY11`](./glyphs.md)) **must** be a token the site reads (`font.sans`, `font.mono`), emitted from the role's font request and fallback chain. | not started | `custom.css` `--vp-font-family-*` |

**WEB1 notes.** For example, `text.primary` becomes `--spk-text-primary`.
Components' CSS reads `var(--spk-x-hover, var(--spk-x))`, so an unset state
falls through exactly as `TOK4` requires. A name is never typed in a stylesheet
by hand.

**WEB2 notes.** The stylesheet includes the syntax channel (`.syn-*`) and the
callout colors, which become `status.*` tokens instead of hex literals.

**WEB3 notes.** The mapped variables are `--vp-c-brand-*`, `--vp-c-bg*`,
`--vp-c-text-*` and their relatives. The generated stylesheet is imported from a
build artifact (`ci --emit-css` or a `sparkles:docs` step). The diff is the
`THM5` lockstep pattern, generalised, so the site cannot drift from the theme.

**WEB4 notes.** A `ui-gallery` page rendered to HTML and a docs page then share
one design language byte for byte.

**WEB5 notes.** The same layout rules the TUI applies at those widths hold on
the web: `UGL15`'s 60-column sidebar collapse and `UGL5`'s sizes.

**WEB6 notes.** A role's value is a font request, a fallback chain and
code-point routes ([font `FTD4`–`FTD6`](../font/SPEC.md#_13-discovery-matching-and-fallback));
CSS expresses the request and the chain as a `font-family` stack. The mono stack
lists the bundled Nerd Font families first, as `custom.css` does, which carries
the Private Use Area route on the web. The Sparkles theme fixes the values
([`SPK4`](./sparkles-theme.md)).

→ [Overview](./index.md) · [Specification](./SPEC.md) · [Sparkles theme](./sparkles-theme.md)
