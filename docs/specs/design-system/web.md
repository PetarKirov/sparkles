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
(M6), and the choice of suffixed properties over pseudo-class rules is
[D60](./decisions.md).

## Contract at a glance

1. Every custom-property name is produced from the token path by one function.
2. One stylesheet is emitted from a theme and imported by both sites.
3. VitePress consumes the generated properties and authors none.
4. A generated page's breakpoints are in columns, not device pixels.

## Requirements

| ID     | Requirement                                                                                                                                                                                                                                                                               | Status | Traces to                                                                                                                                                                                                                                    |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `WEB1` | The framework **must** declare the CSS custom properties: one `--spk-<path>` per token of a theme file, its path with `.` → `-`, so a state ([`TOK4`](./SPEC.md)) and a color channel sit in the name exactly as in the file (D60).                                                       | full   | `css.d` `writeThemeProperties`, `cssPropertyName`; `tokens.d` `cssName`; tests `ui.css.themeProperties.slotNamesAndAliases`, `ui.css.themeProperties.aFilesOwnTokensAndAliases`                                                              |
| `WEB2` | The **theme defines the values**: `sparkles.docs.assets` **must** emit one stylesheet from a theme pair, light values on `:root` and dark values under `html.dark`, and under `@media (prefers-color-scheme: dark)` for a page with no toggle.                                            | full   | `assets.d` `tokenStylesheet`, `calloutSlots`; tests `web_assets.tokenStylesheet.darkValuesAreScoped`, `web_assets.markdownPreviewCss.calloutsReadStatusTokens`                                                                               |
| `WEB3` | **VitePress consumes, never authors.** `custom.css` **must** map its own variables _from_ `--spk-*` in one mapping block, and a test **must** diff the committed stylesheet against a fresh emission.                                                                                     | full   | `custom.css` mapping block; `spk.css` from `sparkles-light.tokens` and `sparkles-dark.tokens` by `gen-site-css.d` (D61); test `web_assets.siteStylesheet.committedSheetIsCurrent`                                                            |
| `WEB4` | The **`html_semantic` interpreter** ([`TGT4`](../ui/backends.md)) **must** emit class names derived from slot paths (`.spk-text-primary`) and use the same emitted stylesheet.                                                                                                            | full   | `html_semantic.d` `writeSlotRules`, `writeSlotStylesheet`; tests `ui.interp.html_semantic.stylesheetCoversEverySlot`, `ui.interp.html_semantic.markupIsClassesNotColors`, `ui.interp.html_semantic.slotClassesNeverCollideWithKindClasses`   |
| `WEB5` | Responsive breakpoints on the generated pages **must** be **in columns**: 80, 120 and 160 columns of the mono face, as container queries over `ch` units, not device px (D62).                                                                                                            | full   | `breakpoints.d` `Columns`, `containerCss`; `sidebar.d` `sidebarCss`, `sidebarToggleHtml`; tests `docs.breakpoints.queriesAreInMonoColumns`, `sidebar.sidebarCss.drawerBelowEightyColumns`, `site_tree.directoryIndex.sidebarWrapsTheContent` |
| `WEB6` | Each [font role](../../glossary.md#font-role) ([`GLY11`](./glyphs.md)) **must** be a token the site reads (`font.body`, `font.code`, `font.heading`), naming a face (`font.family.sans`, `font.family.mono`, `font.family.display`) whose `fontFamily` value is its fallback chain (D63). | full   | `theme.d` `FontSet`; `theme_file.d` fonts; tests `theme_file.fonts.facesAndRolesRoundTrip`, `theme_file.fonts.aRoleMustNameAFace`, `ui.css.themeProperties.fontFacesAndRoles`                                                                |

**WEB1 notes.** For example, `text.primary.fg` becomes `--spk-text-primary-fg`
and `scrollbar.thumb.hover.bg` becomes `--spk-scrollbar-thumb-hover-bg`.
Components' CSS reads `var(--spk-x-hover-fg, var(--spk-x-fg))`, so an unset
state falls through exactly as `TOK4` requires. An alias in the file stays a
`var()` of its target, and a token the theme does not map, such as a site's
primitive, still gets its property. A name is never typed in a stylesheet by
hand.

**WEB2 notes.** The callouts' accents are `status.*` tokens instead of hex
literals; each falls back to the default palette's value, so a lone document
with no token sheet stays readable. The syntax channel (`.syn-*`) keeps its own
class rules ([`THM5`](./SPEC.md)).

**WEB3 notes.** The mapped variables are `--vp-c-brand-*`, `--vp-c-bg*`,
`--vp-c-text-*` and their relatives; a variable not mapped keeps VitePress's
default. The theme files are seeds holding the site's current values until the
Sparkles theme replaces them (D61). The diff is the `THM5` lockstep pattern,
generalised, so the site cannot drift from the theme.

**WEB4 notes.** The rules name no color: each slot's class reads its
properties, and a hit target's hover reads the `-hover-` property with the rest
value as its fallback. A `ui-gallery` page rendered to HTML and a docs page
then share one design language byte for byte, and a page that already carries
the properties links the rules alone.

**WEB5 notes.** The page's root element is the query container and is set in
the mono face, so a query's `ch` is one mono column; a registered `--spk-col`
carries that column to rules in other faces. Below 80 columns the sidebar
yields its width as the TUI's does (`UGL15`), as a drawer behind a checkbox
toggle, with no script; from 160 the content column widens to 100 columns. The
VitePress site keeps VitePress's own media queries (D62).

**WEB6 notes.** A role's value is a font request, a fallback chain and
code-point routes ([font `FTD4`–`FTD6`](../font/SPEC.md#_13-discovery-matching-and-fallback));
CSS expresses the request and the chain as a `font-family` stack. The mono stack
lists the bundled Nerd Font families first, as the site's theme files do,
which carries the Private Use Area route on the web. The Sparkles theme fixes the values
([`SPK4`](./sparkles-theme.md)).

→ [Overview](./index.md) · [Specification](./SPEC.md) · [Sparkles theme](./sparkles-theme.md)
