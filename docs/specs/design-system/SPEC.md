---
status: accepted
owner: sparkles:ui
reviewed: 2026-09-21
---

# Sparkles design system — Specification (`TOK` / `ACC` / `FMT`)

## Abstract

`sparkles:ui` expresses a design system as data: one value that names every
visual decision an application makes, from colors and lengths to glyph
choices and font roles, and projects it onto a terminal, a GPU window and a
web page by one rule set. This specification defines the core of that
framework. Widgets name slots, the roles they play, rather than colors. A
slot's appearance may vary with interaction states such as hover or disabled.
A slot a theme leaves unset falls back to a documented default, and a state it
leaves unset to the slot's resting appearance. Layout
lengths are whole character cells, while finer metrics carry a declared
fallback for targets that cannot draw them. Every theme is measured against
contrast floors and stored in the Design Tokens Community Group format.

## Introduction

The `sparkles:ui` toolkit renders one widget tree to a terminal's character
grid, to a GPU window and to static HTML, as the [backends
specification](../ui/backends.md) describes. The applications built on it
and the project's documentation sites should share one visual language,
while a user of an application such as `hue` still switches at runtime among
dozens of editor color schemes borrowed from upstream. A design system, in
the sense of web practice, is what makes both possible: a vocabulary of named
decisions, such as "primary text", "focus ring" or "overlay padding", whose
values a theme supplies.

A palette of named colors is not yet a design system. It cannot say what a
hovered or disabled control looks like without a separate color per state.
It does not say which roles a component may use, so restyling one component
can silently restyle another. It sets no floor on legibility and has no file
format that a user or a web tool can edit. The three targets compound each
gap: a corner radius or a hairline border exists in a window and in CSS but
has no direct form on a character grid. Parity between targets is worth
little if the design language must be authored separately for each.

The framework makes the design language one value. A widget names a
[slot](../../glossary.md#slot), the role it plays, instead of a color. Each
slot is a [design token](../../glossary.md#design-token) on one of three
tiers: raw values, semantic roles, and parts of a single component, each
tier aliasing the one below. A semantic role a theme leaves unset falls back
to a documented default. Resolving a slot also takes the active
[interaction states](../../glossary.md#interaction-state), and a state the
theme does not override leaves the resting appearance unchanged, so every
theme resolves every slot in every state. Layout lengths are whole
[cells](../../glossary.md#cell). A metric finer than a cell, such as a corner
radius, is given in device pixels together with a defined
[projection](../../glossary.md#projection) onto a target that cannot draw it,
so no metric is silently dropped.

Each component declares the slots it uses, and a test holds it to that set.
Every theme is measured against
[WCAG](https://www.w3.org/TR/WCAG22/#contrast-minimum) contrast floors. A
failure is a test failure for the Sparkles theme and for any theme that
declares it must conform. A borrowed scheme that fails is labelled rather
than rejected, so it keeps its upstream colors. Themes are stored as
[Design Tokens Community Group](https://www.designtokens.org/) (DTCG)
documents, which `sparkles:wired` reads and writes.

This page specifies the tokens, the accessibility floors and the theme file
format: the contract every theme fills. It assigns no token values; the
concrete Sparkles theme, the brand the repository's own applications and
documentation follow, has [its own page](./sparkles-theme.md). Which
features each target supports and how a terminal is probed for them, glyph and
typography projection, the shared keyboard bindings, and the CSS mapping for
the web are specified by sibling pages of this tree. Syntax highlighting
stays outside the token model: `sparkles:syntax` resolves its rules, and the
tokens treat them as opaque. Text measurement and fonts are consumed, not
owned: grid widths, width profiles, cell wrapping and scaled cell footprints
belong to [base/text](../base/text/SPEC.md), font matching and fallback to the
[font specification](../font/SPEC.md), and proportional paragraphs to
[text layout](../text-layout/SPEC.md); the design system owns the font roles
that name them. Following the operating system's light or dark
preference is out of scope and deferred, as the
[overview](./index.md#relationship-to-existing-specs) records.

[Vocabulary](#vocabulary) defines the terms the requirements use.
[Tokens](#tokens-tok) specifies tiers and paths, interaction states, and
units and metrics; [Accessibility](#accessibility-acc) the contrast floors
and the rule that color never carries meaning alone; and [Theme file
format](#theme-file-format-fmt) the DTCG mapping. [Relationship to
`THM`](#relationship-to-thm) lists which rows of the toolkit's [theme
specification](../ui/theme.md) these requirements realise. Where a
requirement table's "Traces to" column marks a symbol _proposed_, that
symbol does not exist yet. The [overview](./index.md) names the owning
package of every obligation in this tree, and its sibling pages cover
[capabilities](./capabilities.md), [glyphs and typography](./glyphs.md), the
[keyboard vocabulary](./keyboard.md) and the [web](./web.md).
[testing.md](./testing.md) holds the oracles and evidence,
[PLAN.md](./PLAN.md) the delivery order, and [decisions.md](./decisions.md)
the choices behind each requirement.

## Vocabulary

| Term                  | Meaning                                                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| **token**             | one named design decision with a value: a color, a length, a glyph choice, a font role. Named by a dotted **path** (`text.primary`, `border.weight`) |
| **tier**              | `primitive` (a raw value: `indigo.500`), `semantic` (a role: `text.primary`), `component` (a part of one component: `scrollbar.thumb`, `diff.added`) |
| **slot**              | a semantic or component token a widget references instead of a color — the existing `Slot` enum ([`THM1`](../ui/theme.md))                           |
| **interaction state** | `rest`, `hover`, `focused`, `selected`, `pressed`, `disabled` — a second axis on slot resolution                                                     |
| **visual**            | the resolved appearance a backend paints (`sparkles.ui.style.Visual`)                                                                                |
| **target**            | one rendering backend instance with a declared capability set ([`capabilities.md`](./capabilities.md))                                               |
| **projection**        | the rule by which a target that cannot honour a token renders it anyway (a px radius becomes rounded box-drawing)                                    |
| **theme**             | one complete assignment of values to tokens: `sparkles.ui.theme.Theme`                                                                               |

## Tokens (`TOK`)

### Tiers and paths

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           | Status  | Traces to                                                                                                                                                                   |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TOK1` | Every token belongs to exactly one **tier**. A component token must resolve to a semantic token or a primitive; a semantic token to a primitive or a literal; the alias graph must be acyclic and every alias must resolve. Violation: a theme whose alias graph has a cycle or a dangling reference is rejected at load with the offending path named, never resolved to a default.                                                                                                                                                                  | partial | `tokens.d` `TokenTier`, `tierOf`; state aliases read their target's rest only, so they cannot chain (D46); rejecting a cyclic or dangling theme file at load is `FMT2` (M5) |
| `TOK2` | Every slot has exactly one **path**: segments of `[a-z0-9]+` joined by `.`, the first starting with a letter (so `indigo.500` is a valid primitive), unique across the slot enum. The path is **declared once, as `@WireName` data on the `Slot` member**, and resolved by `sparkles:wired` (`wireNames`) — the same table the JSON writer and the DTCG theme file use; the CSS custom-property name is derived from that table, never spelled separately. Violation: two slots with the same path, or a path failing the grammar, is a test failure. | full    | `style.d` `Slot` (`@WireName`), `tokens.d` `slotPaths`, `cssName`; [`WEB1`](./web.md)                                                                                       |
| `TOK3` | The **semantic vocabulary** must contain at least the roles below. A theme may leave a role unset; resolution then follows the documented fallback (the last column), so every role is total for every theme.                                                                                                                                                                                                                                                                                                                                         | full    | `style.d` `Slot` (the roles), `defaultTwoslashPalette` (scheme defaults), `theme.d` `effectivePalette` (derived from the page colors + the accent probe)                    |

The minimum semantic set (`TOK3`):

| Group       | Roles                                                     | Fallback when unset                                                    |
| ----------- | --------------------------------------------------------- | ---------------------------------------------------------------------- |
| `text`      | `primary`, `secondary`, `muted`, `disabled`, `inverse`    | `primary` = page fg; the rest are alpha mixes of it toward the page bg |
| `surface`   | `base`, `raised`, `overlay`, `sunken`                     | `base` = page bg; the rest are tone steps per the derivation rule      |
| `border`    | `default`, `strong`, `focus`                              | `default` = `text.muted`; `focus` = `accent.primary`                   |
| `accent`    | `primary`, `secondary`                                    | probed from the syntax rules (`function` / `markup.link`) as today     |
| `status`    | `error`, `warning`, `info`, `success` (each fg + bg tint) | the existing `error`/`warn`/`info` slots; `success` = diff-added hue   |
| `selection` | `bg`                                                      | existing `selection`                                                   |
| `link`      | `fg`, `underline`                                         | `accent.primary`; `hoverUnderline`                                     |
| `focus`     | `ring`                                                    | `border.focus`                                                         |

### Interaction states

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Status  | Traces to                                                                                                                                                                                                                                                                                                                                                                            |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `TOK4` | Slot resolution takes an **interaction state set** as a second argument: `resolve(theme, slot, states) → Visual`. It is total: for any slot and any state set, a theme that sets no override for that state yields exactly the `rest` visual. Violation: a resolved visual that differs from `rest` when the theme declares no override for any active state.                                                                                                                                                                                                                                                             | full    | `style.d` `InteractionState`, `StateSet`, `Palette.states`/`overlay`, `resolveSlot`/`resolveVisual` (`states` parameter), `Widget.states`, `display_list.d`; colours, per-channel slot aliases and attributes (D46: `stateAlias`, `addComponentStates`, test `resolveSlot.stateAliasesAndAttributes`); the components report states (`chrome.d`, `tree_widget.d`, `property_view.d`) |
| `TOK5` | When several states are active, the override of the **highest-precedence** state that has one wins; precedence, low to high, is `hover < focused < selected < pressed < disabled`. A theme override for a state is sparse: it may set only the fields it changes — colors, attributes **and metrics** (a pressed button may inset by a cell; a hovered thumb may widen) — and unset fields fall through to `rest`. A metric override changes layout, so it participates in the frame's relayout like any other model change, never as a paint-time adjustment. Violation: a `disabled` widget that also reads as hovered. | partial | `style.d` `StateSet.highest`; `resolveSlot` walks the states highest-first per channel (test `resolveSlot.statesFallThroughToRest`), aliases and attributes included (D46). Metric overrides admitted (D22), not built: no consumer yet                                                                                                                                              |
| `TOK6` | Every component declares the **slots it uses** as compile-time data (a `slots` member), and a test asserts that the display list it builds references no slot outside that set. The component's documentation page lists the slots from the declaration, not from prose. Violation: an op in the component's display list whose `slot` is not in its declared set.                                                                                                                                                                                                                                                        | partial | `tokens.d` `firstUndeclaredSlot`/`slotsWithin`; `chromeSlots`, `gutterSlots`, `inspectorSlots`, `treeWidgetSlots`, `lanternSlots`, `propertyViewSlots`, `treeViewSlots`, `gridBackdropSlots` (over each preset's ops), `tableWidgetSlots` with their tests. Pending: the twoslash/source-view/hue views; the docs-page listing (M3)                                                  |

### Units and metrics

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | Status  | Traces to                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------- |
| `TOK7`  | The **cell** is the universal layout unit: paddings, gaps, widths and heights are integer cells on every target ([`LAY`](../ui/layout.md) integer-unit rule). A metric whose meaning is sub-cell — corner radius, border weight, shadow offset/blur, font scale, a type step (`GLY10`) — is typed in **CSS px**, which are density-independent: a pixel target multiplies them by its density, so a 16 px radius is as round on a 440 dpi phone as on a desktop. Each carries a defined **projection** onto a cell target ([`GLY2`](./glyphs.md)). A target declares per px-typed metric whether it _honours_ or _projects_ it; a metric is never silently dropped. | partial | `style.d` `Palette` (mixed units, no declaration); `RaylibCanvas.densityScaled` |
| `TOK8`  | Metrics are named by **role**, not by the feature that first needed them, and each carries a role-first token path, matching the slots: `overlay.radius`, `overlay.pad.inline`/`.block`, `overlay.gap`, `overlay.width.max`/`.min`, `border.width`, `border.accent.width`, `docs.width.max`, `signature.indent`, `shadow.offset.x`/`.y`, `shadow.blur`, `code.font.scale`, `docs.font.scale`, `tag.font.scale`, `arrow.size` — replacing `popupRadius`, `borderWidth`, `accentBorder`, `popupPadX`/`Y`, `popupMaxWidth`/`MinWidth`, `sigIndent`. Renames are one-shot with the `Palette` migration; no alias period.                                                | full    | `style.d` `Palette` scalar fields (`@WireName` paths)                           |
| `TOK9`  | The **syntax channel stays opaque** to the token model: syntax rules are `(selector, TextStyle)` data resolved by `sparkles:syntax`, exactly as [`THM`](../ui/theme.md) states. The token model may _reference_ a syntax rule's foreground (the accent probe) but never resolves selectors.                                                                                                                                                                                                                                                                                                                                                                         | full    | `theme.d` `ruleFgFor`                                                           |
| `TOK10` | Application-domain component tokens (`diff.*`, `coverage.*`, `twoslash.*`) live in `sparkles:ui`'s component tier under a **domain namespace**, because the slot index must stay a closed enum for the display list. Their _values_ belong to the theme; their _existence_ is the toolkit's. Revisit if a third application domain appears ([`decisions.md` D16](./decisions.md)).                                                                                                                                                                                                                                                                                  | full    | `style.d` `Slot` (diff/cov groups)                                              |

## Accessibility (`ACC`)

Floors are the [color-derivation](../../research/platform-ui-guidelines/color-derivation/index.md)
values: WCAG 2.x contrast ratio, computed from sRGB relative luminance.

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                          | Status      | Traces to                                                                                                                                                                                                                                                    |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `ACC1` | For every theme, a test computes **conformance**: `text.primary` on `surface.base` ≥ 4.5:1 and every chrome/accent foreground on its band ≥ 3:1, in the theme's own scheme. The result is data (`ThemeConformance`) rendered in `ui-gallery`'s theme page and the docs, and exposed to a theme picker.                                                                                               | not started | [`testing.md` O2](./testing.md)                                                                                                                                                                                                                              |
| `ACC2` | A built-in theme that **fails** the floors is **labelled**, not rejected: the 36 borrowed schemes keep upstream fidelity. Only [Sparkles](./sparkles-theme.md) and any theme that _declares_ `conformance: required` must pass, and for those a failure is a test failure. Violation: a required theme shipping below floor; or a failing theme rendered without its label where labels are shown.   | not started | `SPK2`                                                                                                                                                                                                                                                       |
| `ACC3` | **Never color alone.** Every `status.*` token has a paired **status mark** in the glyph channel with an ASCII fallback ([`GLY3`](./glyphs.md)); a component that shows status must emit the mark whenever the target's color depth is `none` or `ansi16`, and may omit it above that only if the theme says so. Violation: a monochrome render of a status row indistinguishable from a neutral row. | full        | `glyphs.d` `Mark` (pairwise distinct per charset, test `ui.glyphs.marks.*`); `tasklist.d` always emits the mark                                                                                                                                              |
| `ACC4` | **Focus is visible in monochrome.** Under a target with no color, the focused element must differ from its unfocused rendering by attribute (reverse, underline or bold) or glyph, never only by a color token. Checked by the `baseline` profile render of every `ui-gallery` page with focus placed on each focusable ([`O1`](./testing.md)).                                                      | full        | `ui-gallery` tests `ui_gallery.render.focusIsVisibleInMonochrome` (page list ⇄ page on every page) and `ui_gallery.render.focusMovesVisiblyInsideEveryPage` (each page's `focusKey` walk: an attribute or a symbol glyph, not a word, changes at every step) |
| `ACC5` | **Reduced motion** is a capability input (`TargetCapabilities.reducedMotion`): when set, spinners render their static frame, eased scrolling jumps, and toasts appear without transition. The source is the host (OS preference later via `sparkles:appearance`; a `--reduced-motion` flag and env now).                                                                                             | not started | [`capabilities.md`](./capabilities.md)                                                                                                                                                                                                                       |

## Theme file format (`FMT`)

The file format is the Design Tokens Community Group's
[Design Tokens Format Module 2025.10](https://www.designtokens.org/tr/2025.10/format/)
(DTCG; D12), used both to author user themes and to interchange with web
tooling. It realises [`THM9`](../ui/theme.md). The generic format, parsed,
resolved and written canonically, is `sparkles.ui.dtcg`; the mapping onto a
theme is `sparkles.ui.theme_file`. The project's own data lives under the
`$extensions` key `dev.petar-kirov.sparkles` (D56).

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Status  | Traces to                                                                                                                                                                                                         |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FMT1` | A theme file is a DTCG document. A slot is a **group at its token path** (`TOK2`) whose `fg` and `bg` leaves are `color` tokens; an interaction state is a group inside the slot (`scrollbar.thumb.hover.bg`); `page.fg`/`page.bg` are the page colors; px metrics are `dimension` tokens and cell metrics and font scales `number` tokens, each at its role-first path (D55). Fonts are `font.family.<face>` `fontFamily` stacks and `font.<role>` aliases of a face (D63); the box chrome maps onto `border`/`shadow` tokens once `Theme` carries it. | partial | `theme_file` `exportTheme`, `loadTheme`; tests `theme_file.palette.slotsStatesAndMetricsRoundTrip`, `theme_file.fonts.facesAndRolesRoundTrip`. Pending: box chrome                                                |
| `FMT2` | Aliases resolve in both 2025.10 forms, `{a.b}` and the `$ref` JSON Pointer, with `$type` inherited and group `$extends` applied. A file may name a **base**, a built-in theme or another file; the base's tokens come first and the file's after them, the later winning per token, the DTCG resolver rule. A file with no base stands alone, its unset slots derived from its page colors (D57). A state channel that aliases another slot's same channel is a `D46` alias. Unresolvable aliases and cycles reject the file (`TOK1`).                  | full    | `dtcg` `collectTokens`, `DtcgTokens.resolved`; `theme_file` `loadTheme`; tests `theme_file.load.overlaysABase`, `dtcg.collectTokens.rejectsCyclesAndDanglingAliases`                                              |
| `FMT3` | Loading **must** fail closed on malformed input: invalid JSON, a wrong `$type` on a token the theme maps, a dangling or cyclic alias, or an out-of-range value yields a `DtcgError` naming the JSON path. Unknown `$extensions` and tokens the theme does not map are kept for the round trip; the latter are reported as warnings. Malformed input **must never** become an assertion.                                                                                                                                                                 | full    | `dtcg` `DtcgError`; `ThemeFile.warnings`; test `theme_file.load.malformedCorpusFailsWithAPath` (`O4`)                                                                                                             |
| `FMT4` | Loading keeps the file's own document, so `save(load(file))` writes the file's primitives, aliases, descriptions and unknown extensions back, in canonical form: keys sorted, two-space indentation (D58). Colors and dimensions written by the toolkit use the 2025.10 object forms; a draft `#rrggbb` or `4px` value the file wrote is kept as written.                                                                                                                                                                                               | full    | `dtcg` `writeDtcg`; `theme_file` `saveTheme`; tests `theme_file.builtins.roundTrip`, `theme_file.load.unknownExtensionsSurviveASave`                                                                              |
| `FMT5` | Every built-in theme is **exported** to DTCG and the exports are checked in as goldens, so the format is exercised by real documents and a change to any built-in is visible in review as a token diff. An export writes only what a theme sets, so a theme with a derived palette exports without one and loads back to the same palette.                                                                                                                                                                                                              | full    | `theme_file` `exportTheme`; the 36 exports in `libs/ui/test/data/themes/` and test `theme_file.builtins.exportsMatchTheCheckedInGoldens` (`SPARKLES_UPDATE_GOLDENS=1` rewrites them); `hue theme <name> --export` |
| `FMT6` | Syntax rules are groups at `syntax.<selector>` with the slots' `fg`/`bg` leaves and their attributes and underline in the group's extension, so a rule that sets only attributes is a group with no color token (D14).                                                                                                                                                                                                                                                                                                                                  | full    | `theme_file` `exportTheme`, `loadTheme`; test `theme_file.load.attrsOnlyRulesAndDraftHex`                                                                                                                         |

## Relationship to `THM`

| `THM` row | Realised by                                                                |
| --------- | -------------------------------------------------------------------------- |
| `THM2`    | `TOK3` (the minimum semantic set) and `TOK4`/`TOK5` (the state axis)       |
| `THM6`    | `TOK7`–`TOK10` (metrics and domain tokens in the one value)                |
| `THM8`    | [`CAP4`](./capabilities.md) (per-target application, never a tty snapshot) |
| `THM9`    | `FMT1`–`FMT6`                                                              |

→ [Overview](./index.md) · [Capabilities](./capabilities.md) · [Glyphs](./glyphs.md) · [Testing](./testing.md)
