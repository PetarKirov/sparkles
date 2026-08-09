# Concepts & Vocabulary

The shared vocabulary the rest of this tree uses. Every platform surveyed here
solves the same problem with different words; this page fixes one set of words so
the [master catalog](./index.md#master-catalog) and
[comparison](./comparison.md) can be read as a single table rather than six
glossaries.

**Last reviewed:** August 9, 2026

---

## The appearance triple

Strip the vendor branding from [iOS][ios], [Android][android], [GNOME][gnome],
[KDE][kde], [Windows][windows], [macOS][macos], the [web][web] and even the
[terminal][terminal], and every one of them exposes some subset of the same three
scalars:

| Scalar             | What it is                                                        | Domain in the wild                                       |
| ------------------ | ----------------------------------------------------------------- | -------------------------------------------------------- |
| **Color scheme**   | whether the user wants light or dark surfaces                     | 3 values (light / dark / **no preference**) — see below  |
| **Accent color**   | one hue the user picked to tint interactive and selected elements | an sRGB triple, or a **quantized enum** of named colors  |
| **Contrast level** | how far apart foreground and background should be pushed          | boolean on most platforms; 3 steps on Android 14 and iOS |

Two more preferences travel with them often enough to matter, because they are
carried by the same APIs and delivered by the same change notification:
**reduced motion** (suppress animation) and **reduced transparency** (suppress
translucency and blur). This tree treats them as part of the appearance surface
even though neither is a color.

> [!IMPORTANT]
> **Color scheme has three values, not two.** Every modern API — the portal's
> `color-scheme`, `UITraitCollection.userInterfaceStyle`, `NSAppearance`,
> `AdwSystemColorScheme` — distinguishes _prefer-light_, _prefer-dark_ and
> _no preference_. `0`/`unspecified` means **the application's own default
> wins**, not "light". Collapsing three into two is the most common defect in
> preference consumers, and it is why an app with a dark house style
> incorrectly turns light on a freshly installed desktop.

---

## Semantic color vs literal color

A **literal color** is a hex value in the source: `#1E1E2E`. A **semantic color**
is a name for a _role_ — "the default text color", "the selected-row tint",
"the error foreground" — that resolves to a different literal in each appearance.

Every vendor's guidance reduces to the same instruction: name the role, resolve
late. [Apple][macos] ships the roles as objects
(`UIColor.label`, `NSColor.controlAccentColor`) that _are_ the resolution.
[Android][android] ships them as theme attributes (`colorPrimary`,
`colorOnPrimary`). The [web][web] ships them as custom properties plus
[`light-dark()`][lightdark]. `sparkles:ui` already ships them as
[`Slot`](../../specs/ui/theme.md) — the toolkit's existing
[`THM1`](../../specs/ui/theme.md) requirement ("a widget must reference a
semantic slot, never a concrete color") is precisely this concept, arrived at
independently.

The distinction is what makes following the system _possible_. An app whose
widgets name roles has one place to re-resolve when the preference changes; an app
whose widgets name hexes has to be rewritten.

## Tone, and the tonal palette

**Tone** is lightness on a perceptually uniform axis: CIE `L*`, 0 (black) to 100
(white). It is the third dimension of [Material's HCT][hct] color space (hue,
chroma, tone), which pairs CAM16 hue and chroma with `L*` lightness.

Tone matters because a fixed tone _difference_ buys a roughly predictable
contrast ratio at any hue, which turns palette construction into arithmetic. A
**tonal palette** is one hue sampled at a fixed ladder of tones — Android's is
13 stops (`0, 10, 50, 100, 200, …, 900, 1000`), and a whole
[Material You](./android.md) scheme is five such palettes.

How far the tone-delta rule actually holds is measured, not assumed, in
[color-derivation](./color-derivation/index.md#the-tone-delta-rule) — the
`derive-palette.d` example sweeps the axis and finds it a good heuristic that
misses its own stated guarantee at one end.

## Contrast ratio

The [WCAG 2.x][wcag] ratio between two colors, `(L1 + 0.05) / (L2 + 0.05)` over
relative luminance, in `[1, 21]`. The thresholds this tree cites: **4.5:1** for
body text (AA), **3:1** for large text and non-text UI (AA-large). It is the
acceptance criterion a derived palette has to clear — and, as
[color-derivation](./color-derivation/index.md) shows, the thing to check
directly rather than infer from a tone delta.

## Quantized accent

Some platforms report the accent as an arbitrary sRGB triple; some restrict the
user to a fixed set and report a member of it. GNOME does the latter and then
_converts to a triple at the API boundary_, so the type promises variety the
system never delivers — a fact the
[`portal-appearance.d`](./gnome/examples/portal-appearance.d) example detects at
runtime by matching the answer against libadwaita's nine hexes.

This matters when deriving: a palette recipe tuned for nine known hues can be
authored by hand, while one that must accept any hue has to compute (and then has
to worry about a user picking a hue that cannot clear contrast at the tone the
design wants).

## Push vs poll

**Push** — the platform tells the app: a D-Bus `SettingChanged` signal, a WinRT
`ColorValuesChanged` event, `registerForTraitChanges`, KVO on
`effectiveAppearance`, a terminal's unsolicited `CSI ? 997 n`.

**Poll** — the app asks, repeatedly, because there is nothing to subscribe to.

Every desktop and mobile platform in this survey offers push. The interesting
cases are the ones where push exists but is _lossy_: signals that fire more than
once per change (observed on GNOME, see [gnome](./gnome/index.md#change-notification)),
signals that fire for an unrelated key, and — on
[Android's NativeActivity](./android.md#the-nativeactivity-reality) — a
configuration-change callback that tells you _something_ changed and leaves you to
diff.

The practical consequence is the same everywhere and worth stating once: **treat
a notification as "re-read", never as "the value is now X", and compare against
the value you hold before repainting.**

## Elevation

A surface drawn _above_ another needs to be distinguishable from it. In light
schemes a shadow suffices; in dark schemes shadows are nearly invisible, so
platforms lighten the raised surface instead. Apple exposes this as
[`UITraitCollection.userInterfaceLevel`][traits] (`base` / `elevated`); Material
expresses it as surface tones. A dark theme that draws popups in the same color as
the page, relying on a shadow, loses its popup boundaries — which is why the
derivation in [color-derivation](./color-derivation/index.md) offsets the
`surface` slot from the page background in the dark direction only.

## Forced colors

A mode in which the _system_ overrides the app's palette entirely with a small
user-chosen set — Windows High Contrast, mapped to the web's
[`forced-colors`][forcedcolors] media query. It is categorically different from
"high contrast": high contrast asks the app to push its own colors further apart,
while forced colors asks the app to **stop specifying colors**. No platform in
this survey lets an app opt out, and the correct response is to drop decorative
color and let the system's substitution through.

## Capability, not assumption

Whether a given preference is _readable at all_ varies by platform, by desktop,
by version, and — on Linux — by which portal backend happens to be installed. The
survey found the same key present on one desktop and answering
`org.freedesktop.portal.Error.NotFound` on another
([gnome](./gnome/index.md#coverage-is-per-backend)).

The design pattern the field converged on is therefore a **capability flag per
preference**, not a single "does the OS support appearance" bit.
[libadwaita][adw] is the clearest instance: five features, each with its own
`has_*` predicate, filled in by a cascade of backends until something claims it.
This is the same shape as Sparkles'
[Design-by-Introspection](../../guidelines/design-by-introspection-01-guidelines.md)
capability-by-presence protocol, and the
[proposal](./sparkles-proposal.md) adopts it directly.

---

## Sources

- [XDG Desktop Portal — `org.freedesktop.portal.Settings`][portal]
- [Material Design 3 — how the color system works][hct]
- [WCAG 2.2 — contrast minimum][wcag]
- [MDN — `prefers-color-scheme`][web-mdn], [`forced-colors`][forcedcolors], [`light-dark()`][lightdark]
- [UIKit — `UITraitCollection`][traits]
- libadwaita `src/adw-settings-impl-private.h` at [`01d51e39`][adw]

<!-- References -->

[adw]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-private.h
[android]: ./android.md
[forcedcolors]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/forced-colors
[gnome]: ./gnome/index.md
[hct]: https://m3.material.io/styles/color/system/how-the-system-works
[ios]: ./ios.md
[kde]: ./kde.md
[lightdark]: https://developer.mozilla.org/en-US/docs/Web/CSS/color_value/light-dark
[macos]: ./macos.md
[portal]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html
[terminal]: ./terminal/index.md
[traits]: https://developer.apple.com/documentation/uikit/uitraitcollection
[wcag]: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
[web]: ./web.md
[web-mdn]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-color-scheme
[windows]: ./windows.md
