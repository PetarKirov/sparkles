---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# The Sparkles theme (`SPK`)

## Abstract

Sparkles is the concrete design system for the repository's own applications
and documentation sites: one complete set of values, in a light and a dark
scheme, for every token the `sparkles:ui` design-system framework declares.
This page fixes the constraints every value must meet — every role set
explicitly, the contrast floors passed — and how the theme is delivered: as the
default theme and as a theme file the loader is tested against. The values
themselves are an open question (OQ2).

## Introduction

The [framework](./SPEC.md) lets any theme restyle every application, and the 36
editor color schemes borrowed from upstream remain valid themes that fill fewer
tokens and fall back for the rest. The repository still needs one design
language of its own: the default look of `ui-gallery`, the documentation sites
and `hue`. That design language is Sparkles (D2).

Sparkles is held to a stricter standard than a borrowed scheme. It does not lean
on the framework's fallbacks, it passes the contrast floors that borrowed
schemes are merely labelled against, and it fixes the choices a borrowed scheme
leaves to defaults: its type stack and its glyph preferences per role.

The palette, type and glyph values come from a design exercise started from
scratch ([D3](./decisions.md)) and carried out against rendered components
(D23); [OQ2](./decisions.md#open-questions) tracks it. This page therefore fixes
constraints and delivery, not values. The documentation site's existing look is
not a seed (D23). Delivery order lives in
[PLAN.md](./PLAN.md) (M4–M6).

## Contract at a glance

1. Sparkles sets every semantic token and every state override explicitly, in
   both schemes.
2. Sparkles **must** pass the contrast floors; a regression is a test failure.
3. Sparkles is the default theme of the reference application and the docs.
4. Sparkles fixes its font roles and glyph preferences.
5. Sparkles ships as a DTCG theme file.

## Requirements

| ID     | Requirement                                                                                                                                                                                                                                     | Status      | Traces to                                |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------- |
| `SPK1` | Sparkles **must** set **every** semantic token of [`TOK3`](./SPEC.md) explicitly, in both a light and a dark scheme, and every state override the components read, so no fallback path is exercised.                                            | not started |                                          |
| `SPK2` | Sparkles **must** declare `conformance: required` and **pass** [`ACC1`](./SPEC.md) in both schemes; a regression is a test failure ([`ACC2`](./SPEC.md)).                                                                                       | not started | [`testing.md` O2](./testing.md)          |
| `SPK3` | Sparkles **must** be the **default theme** of `ui-gallery`, of the generated `hue gallery`/`sparkles:docs` output and of the VitePress site; `hue`'s own default follows once its settings migrate ([PLAN](./PLAN.md)).                         | not started | `ui-gallery` `themes_page`; `custom.css` |
| `SPK4` | Sparkles **must** fix the value of every [font role](../../glossary.md#font-role) ([`GLY11`](./glyphs.md)): a font request, a fallback chain and code-point routes ([font `FTD4`–`FTD6`](../font/SPEC.md#_13-discovery-matching-and-fallback)). | not started |                                          |
| `SPK5` | Sparkles **must** fix the **glyph preferences** per role (`GLY1`): frame, rule, tree-guide, thumb and mark charsets, and whether rules use sub-cell edges (`GLY2a`).                                                                            | not started |                                          |
| `SPK6` | Sparkles **must ship as a DTCG document** in the repository (`FMT5`) and be the first file the loader is tested against.                                                                                                                        | not started | [`FMT`](./SPEC.md)                       |

**SPK1 notes.** Sparkles is the one theme for which the framework's defaults
are never the answer.

**SPK4 notes.** The mono role requests the bundled Maple Mono NF CN, with the
FiraCode Nerd Font in its fallback chain ([`FNT`](../hue/gui.md)). Its
code-point routes are part of the value; the canonical route sends the Private
Use Area to a Nerd Font face (`GLY11`). The sans role's request is chosen with
the palette (OQ2). The roles reach the web as tokens ([`WEB6`](./web.md)) and the
theme file as DTCG font tokens ([`FMT1`](./SPEC.md#theme-file-format-fmt)). The
font library matches the request and builds the chain; it never sees the role
(D54).

**SPK5 notes.** The preferences are chosen on the TUI first, then checked
unchanged on GUI and Web.

**SPK6 notes.** The brand and the file format land together, so the first
document the loader reads is one the repository relies on.

## Not inherited from the docs site

The VitePress theme's "Midnight Aurora" look (indigo `#6366f1` / cyan
`#22d3ee`, Space Grotesk / Inter / JetBrains Mono) is **not** the seed
([D3](./decisions.md)). It is the site's appearance until `SPK3` is delivered,
and no token references it.

→ [Overview](./index.md) · [Specification](./SPEC.md) · [Delivery plan](./PLAN.md)
