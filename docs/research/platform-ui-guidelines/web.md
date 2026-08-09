# The web (CSS user-preference media features)

The platform that turned every other platform's preferences into a
**declarative, sandboxed, vendor-neutral vocabulary** — and the one
[`hue`](../../specs/hue/index.md)'s HTML sink emits into.

|                     |                                                                                                                                               |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Preference surface  | `prefers-color-scheme` · `prefers-contrast` · `prefers-reduced-motion` · `prefers-reduced-transparency` · `forced-colors` · `inverted-colors` |
| Canonical API       | CSS media features; `window.matchMedia()` in script                                                                                           |
| Change notification | **push** — the media query re-evaluates and restyles with no script at all                                                                    |
| Palette derivation  | none; but `color-scheme` and `light-dark()` remove most of the need for it                                                                    |
| Accent color        | **not exposed** — deliberately, for fingerprinting reasons                                                                                    |
| Relevance to hue    | the `--html` sink and the planned [multi-theme output](../../specs/hue/feature-requirements.md) (`DEF5`)                                      |

## Overview

### What it solves

A web page is the most constrained consumer in this survey: it cannot read a
registry, call a D-Bus method, or link a toolkit. The platform's answer was to
expose preferences as **media features** — the same mechanism already used for
viewport width — so that adapting to dark mode requires no script, no
permission, and no API call, and so that the browser can re-evaluate and restyle
without the page participating.

### Design philosophy

Three properties of the design are worth naming, because they are the ones a
native toolkit can learn from:

1. **Preferences are queries, not values.** A page never reads "the user prefers
   dark"; it declares what to do _if_ they do. The absence of a getter is what
   makes the change path free — there is no cached value to invalidate.
2. **The set is deliberately incomplete.** There is no accent-color media
   feature, and the CSS Working Group has discussed and repeatedly declined
   exposing the system accent, because a free-form color read by any page is a
   high-entropy fingerprinting vector. Every native platform in this survey
   exposes the accent freely; the web is the one place where the privacy cost was
   priced in and the feature was cut. That asymmetry is worth remembering when
   [`hue --html`](../../specs/hue/index.md) emits a document: an accent the
   native app followed cannot be re-derived by the page, so it must be **baked
   into the emitted CSS**.
3. **Two-way negotiation via `color-scheme`.** The `color-scheme` property is not
   a query but a _declaration_: `:root { color-scheme: light dark; }` tells the
   browser the page handles both, which in turn makes the UA restyle form
   controls, scrollbars and the canvas background to match. A page that styles
   dark mode but omits `color-scheme` gets dark content with light scrollbars —
   the web's version of [Windows'](./windows.md) light title bar on a dark app.

## How it works

### The feature set

| Feature                        | Values                                       | Native counterpart                                          |
| ------------------------------ | -------------------------------------------- | ----------------------------------------------------------- |
| `prefers-color-scheme`         | `light` · `dark`                             | every platform's color scheme                               |
| `prefers-contrast`             | `no-preference` · `more` · `less` · `custom` | GNOME `contrast`, Apple `accessibilityContrast`, Android 14 |
| `prefers-reduced-motion`       | `no-preference` · `reduce`                   | portal `reduced-motion`, Apple reduce motion                |
| `prefers-reduced-transparency` | `no-preference` · `reduce`                   | Apple reduce transparency, Windows transparency effects     |
| `forced-colors`                | `none` · `active`                            | **Windows High Contrast** ([windows](./windows.md))         |
| `inverted-colors`              | `none` · `inverted`                          | platform color inversion                                    |

Note that `prefers-color-scheme` has **two** values, not three: the spec folds
"no preference" into `light`. This is the one place the web is _less_ expressive
than the native platforms, and it is a deliberate simplification — a page's
default styles serve the no-preference case, so the third value would have no
distinct behaviour to select.

`prefers-contrast: less` has no counterpart anywhere else in the survey.

### `light-dark()`

The modern form collapses the two-block pattern into one declaration:

```css
:root {
  color-scheme: light dark;
  --page-bg: light-dark(#fdf6e3, #1e1e2e);
  --page-fg: light-dark(#4c4f69, #cdd6f4);
}
```

`light-dark(a, b)` picks by the element's _used_ `color-scheme`, which means a
subtree that declares `color-scheme: dark` gets the dark value regardless of the
user preference — the same per-subtree override [iOS traits](./ios.md) and
[`NSAppearance`](./macos.md) provide, expressed in CSS.

For [`hue --html`](../../specs/hue/index.md) this is directly the mechanism
`DEF5` calls for: one document carrying both palettes, switched by
`:root[data-theme]` or `prefers-color-scheme`, rather than two emitted files.
Emitting `light-dark()` pairs into the existing `--twoslash-*` custom-property
block that
[`sparkles.ui.style.writeTwoslashVars`](../../specs/ui/theme.md) already
generates is a small change to a generator that exists.

### `forced-colors`

When active, the UA replaces the page's colors with the user's set. The rules the
page must follow are inverted from every other mode: **remove** color rather than
adapt it, keep `forced-color-adjust: auto` (the default) so the substitution
happens, and use the system color keywords (`Canvas`, `CanvasText`,
`LinkText`, `ButtonFace`, `Highlight`) for anything that must remain
distinguishable.

An HTML sink that hard-codes syntax-highlight colors — which is exactly what a
syntax highlighter does — will have them all substituted to `CanvasText` under
forced colors, collapsing the highlighting to plain text. That is the _correct_
outcome, and worth stating so it is not later filed as a bug.

### Change notification

The purest push in the survey: the media query re-evaluates and the page
restyles, with no script running. When script needs to know:

```js
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', e => {
  /* e.matches */
});
```

which is the only place in this survey where the notification **carries the
value** reliably, because the value is a boolean the UA already computed.

## Reachability

Total, and free. This is the one platform where following the system requires no
capability detection, no fallback chain and no timeout — the styles simply apply.
The cost is the ceiling: a page cannot learn the accent, cannot learn the exact
system colors outside forced-colors mode, and cannot distinguish "no preference"
from "light".

## Traps

| Trap                                                              | Consequence                                                     |
| ----------------------------------------------------------------- | --------------------------------------------------------------- |
| Styling dark mode without declaring `color-scheme`                | dark content with light scrollbars and form controls            |
| Expecting a third `no-preference` value                           | there is none; the default styles are the no-preference case    |
| Treating `forced-colors` as "high contrast"                       | the app should stop specifying color, not push it further apart |
| Overriding `forced-color-adjust` to keep brand colors             | defeats the accessibility mode users rely on                    |
| Assuming syntax highlighting survives forced colors               | it does not, correctly                                          |
| Looking for a system accent                                       | not exposed, deliberately — bake it in at generation time       |
| Toggling a `data-theme` attribute without updating `color-scheme` | UA-painted surfaces stay on the old scheme                      |

## Strengths

- Zero-cost change handling: no script, no listener, no invalidation.
- The broadest preference vocabulary in the survey, including `prefers-contrast: less`
  and `inverted-colors`, which no native platform here exposes.
- `light-dark()` plus `color-scheme` gives per-subtree override with one property.
- A real forced-colors contract with system color keywords to target.

## Weaknesses

- No accent color, by design.
- Two-valued color scheme, so "no preference" is unrepresentable.
- No way to read the platform's actual colors, so a page can match the _mode_ but
  never the _palette_ the way [KDE](./kde.md) consumers can.
- Forced colors silently destroys semantic color, including syntax highlighting.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                             | Trade-off                                                              |
| ------------------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------- |
| Expose preferences as media queries, not getters | restyling is automatic; no cached value to invalidate | script that genuinely needs the value takes a second, parallel path    |
| Do not expose the accent color                   | a free-form user color is a fingerprinting vector     | the web cannot match native chrome; generators must bake the accent in |
| Fold "no preference" into `light`                | the page's default styles already serve that case     | the three-valued native state cannot round-trip through a page         |
| `color-scheme` as a declaration, not a query     | lets the UA restyle its own painted surfaces to match | forgetting it produces the half-themed look, and nothing warns you     |
| `forced-colors` replaces rather than adjusts     | guarantees a usable result regardless of the page     | destroys legitimately semantic color, e.g. syntax highlighting         |

## Sources

- [MDN — `prefers-color-scheme`][mdn-pcs], [`prefers-contrast`][mdn-contrast], [`forced-colors`][mdn-fc], [`prefers-reduced-transparency`][mdn-prt]
- [MDN — `color-scheme`][mdn-cs] and [`light-dark()`][mdn-ld]
- [CSS WG discussion — exposing a native accent color as a system color keyword][csswg-accent]
- [`hue` feature requirements — `DEF5` multi-theme HTML](../../specs/hue/feature-requirements.md)

<!-- References -->

[csswg-accent]: https://lists.w3.org/Archives/Public/public-css-archive/2023Aug/0893.html
[mdn-contrast]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-contrast
[mdn-cs]: https://developer.mozilla.org/en-US/docs/Web/CSS/color-scheme
[mdn-fc]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/forced-colors
[mdn-ld]: https://developer.mozilla.org/en-US/docs/Web/CSS/color_value/light-dark
[mdn-pcs]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-color-scheme
[mdn-prt]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-transparency
