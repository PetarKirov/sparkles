# Deriving a palette from the appearance triple

Every platform in this survey hands an application some subset of the same three
scalars — a **color scheme**, an **accent color**, a **contrast level** — and,
with the sole exceptions of [KDE](../kde.md) and [Android](../android.md), none
of them hands over a palette. Turning three scalars into a whole design language
is the application's job. This page is how.

**Last reviewed:** August 9, 2026

|                  |                                                                  |
| ---------------- | ---------------------------------------------------------------- |
| Input            | `(ColorScheme, RgbColor accent, ContrastLevel)`                  |
| Output           | a [`sparkles.ui.theme.Theme`](../../../specs/ui/theme.md)        |
| Machinery        | CIE `L*` tone · WCAG contrast ratio · hue-preserving tone shifts |
| Acceptance test  | body text ≥ 4.5:1, chrome accent ≥ 3:1, in every combination     |
| Runnable example | [`examples/derive-palette.d`](./examples/derive-palette.d)       |

---

## Why not just pick two palettes

The obvious implementation — ship a light theme and a dark theme, switch on the
scheme bit — is what `sparkles:ui` effectively does today via
[`defaultTwoslashPalette(ColorScheme)`](../../../specs/ui/theme.md). It handles
exactly one of the three inputs. It cannot express an accent (there is nowhere to
put it), and it cannot express a contrast level (there is no third theme, and
authoring a fourth and a sixth by hand does not scale).

Deriving costs a page of arithmetic and handles all three, plus every future
combination, plus the case [KDE](../kde.md) presents where the platform supplies
real colors that must be honoured rather than approximated.

## The tone axis

Work in **tone**: CIE `L*`, 0 (black) to 100 (white), the third dimension of
Material's [HCT](../concepts.md#tone-and-the-tonal-palette). `L*` is
perceptually uniform, so equal tone steps look like equal lightness steps, which
is what makes a _fixed tone difference_ a usable design primitive.

Concretely (from the example, which computes rather than tabulates these):

```[Output]
tone   grey      luminance
   0   #000000   0.0000
  10   #1B1B1B   0.0110
  20   #303030   0.0296
  40   #5E5E5E   0.1119
  50   #777777   0.1845
  60   #919191   0.2831
  80   #C6C6C6   0.5647
  90   #E2E2E2   0.7605
 100   #FFFFFF   1.0000
```

Note how non-linear this is against luminance: tone 50 — the perceptual midpoint —
sits at 18% luminance, not 50%. Any derivation that reasons about "50% grey" in
luminance or in raw sRGB channels will place its mid-tones far too light.

## The tone-delta rule

[Material's documentation][hct] states the rule the whole tonal-palette approach
rests on:

> a difference of 40 in HCT tone guarantees a contrast ratio >= 3.0, and a
> difference of 50 guarantees a contrast ratio >= 4.5

That is a strong claim — it converts an accessibility check into arithmetic. The
example sweeps the entire tone axis at each delta and reports the worst case
rather than repeating the claim:

```[Output]
ΔT 40: worst 3.152:1 (tone 60→100) vs claimed ≥ 3.0:1  holds
ΔT 50: worst 4.478:1 (tone 50→100) vs claimed ≥ 4.5:1  MISSES by 0.022

smallest ΔT that clears 3.0:1 at every tone: 38.50
smallest ΔT that clears 4.5:1 at every tone: 50.25
```

**ΔT 40 holds. ΔT 50 does not — it misses 4.5:1 by 0.022 at the top of the
axis.** The shortfall is ~0.5%, so the rule remains an excellent design
heuristic; it is not, however, the guarantee the wording claims. The true
threshold under WCAG 2.x relative luminance is ΔT 50.25, and the worst case is
always at the light end (`tone 50 → 100`), where the luminance curve is
steepest relative to tone.

The practical rule this yields, and the one the derivation follows:

> Use tone deltas to _place_ colors. Use the contrast ratio to _accept_ them.

A palette that must certify WCAG AA checks the ratio; a palette that merely wants
to look right can trust the delta. The example does both — it places by delta and
then asserts the ratio, so a future change to the placement that breaks
accessibility fails the build rather than the review.

## Deriving the Sparkles palette

### The input type

```d
struct SystemAppearance
{
    ColorScheme   scheme;
    RgbColor      accent;
    ContrastLevel contrast;   // standard | medium | high
}
```

`ContrastLevel` has three steps rather than a boolean because
[Android 14](../android.md#contrast) and [Apple](../ios.md) have three and the
desktops have two; widening at the abstraction and collapsing at each backend
loses nothing, while the reverse loses the middle step permanently.

### Placement

| Role                   | Light scheme      | Dark scheme       | Rationale                                                                                                                                                                 |
| ---------------------- | ----------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| page background        | tone 98           | tone 12           | not pure white/black — pure extremes are fatiguing and leave no room to place `surface`                                                                                   |
| body text              | bg − ΔT           | bg + ΔT           | ΔT = 50 / 60 / 75 by contrast level                                                                                                                                       |
| `surface` (popups)     | bg − 4            | bg **+ 6**        | in dark schemes a raised surface must be _lighter_; shadows do not read — the [elevation](../concepts.md#elevation) rule [iOS](../ios.md) encodes as `userInterfaceLevel` |
| `chromeAccent` (text)  | accent at tone 40 | accent at tone 80 | accent-as-text must clear 3:1 against the page                                                                                                                            |
| `chromeFocused` (fill) | accent at tone 90 | accent at tone 30 | accent-as-fill sits _near_ the page so text on it stays legible                                                                                                           |
| `selection`            | accent at tone 85 | accent at tone 35 | a tint under text, so closer to the page than the fill                                                                                                                    |

The `chromeAccent`/`chromeFocused` split is the same distinction libadwaita draws
with `adw_accent_color_to_rgba()` versus
`adw_accent_color_to_standalone_rgba()` ([libadwaita](../libadwaita.md)): the
same hue cannot be both a fill and text on the page. Treating the accent as one
color gets one of the two wrong.

### Moving a color to a tone

A full HCT round trip solves for chroma at the target tone through CAM16. The
example uses a cheaper approximation — scale the channels **in linear light**, so
the ratios between them (and therefore the hue) survive, then clamp:

```d
const k = luminanceFromTone(targetTone) / luminance(c);
// each channel: linearize → × k → clamp → re-encode
```

This is accurate enough for chrome and is `@safe pure nothrow @nogc`-shaped with
no tables. It loses chroma at extreme tones, where the clamp bites, and a future
implementation that needs saturated accents at tone 90 will want the real solve.
Recorded as a known limitation rather than discovered later.

### The result

Running the derivation on the accent GNOME actually reported on the authoring
machine (`#3584E4`):

```[Output]
OS accent: #3584E4 (GNOME 'blue')

light / standard  fg #727272  bg #F9F9F9  accent #245FA6
                 text/bg    4.57:1   accent/bg  6.11:1

light / high      fg #373737  bg #F9F9F9  accent #245FA6
                 text/bg   11.31:1   accent/bg  6.11:1

dark  / standard  fg #969696  bg #1F1F1F  accent #54C7FF
                 text/bg    5.57:1   accent/bg  8.63:1

dark  / high      fg #DADADA  bg #1F1F1F  accent #54C7FF
                 text/bg   11.79:1   accent/bg  8.63:1
```

Every combination clears WCAG AA for body text and AA-large for the accent, and
the example asserts exactly that — so the property is enforced by CI rather than
by inspection.

> [!NOTE]
> The derived body text at standard contrast (4.57:1) is deliberately close to
> the 4.5 floor. That is what "standard" means: a comfortable reading contrast,
> not a maximal one. The `high` rows show the range the contrast preference buys.

## Scheme inference vs. the OS answer

Sparkles today infers the scheme from a background color, in
`sparkles.ui.style.schemeForBackground`, using Rec. 601 luma with a threshold of 110. [Windows'](../windows.md) documented method uses a _third_ formula,
`(5G + 2R + B) > 8 × 128`. How much do they actually disagree?

```[Output]
color     Rec601   tone    schemeForBackground   tone < 50
#686868      104    44.0   dark                  dark  grey
#6D6D6D      109    46.0   dark                  dark  grey
#6F6F6F      111    46.8   light                 dark  <-- disagree  grey
#727272      114    48.0   light                 dark  <-- disagree  grey
#747474      116    48.8   light                 dark  <-- disagree  grey

#008000       75    46.2   dark                  dark  saturated green
#1E1E2E       31    12.0   dark                  dark  catppuccin-mocha base
#282C34       43    17.9   dark                  dark  one-dark base
#002B36       31    15.5   dark                  dark  solarized-dark base
#FDF6E3      245    97.0   light                 light  solarized-light base
```

The disagreement is confined to a ~3-tone band of mid greys (`tone 46.8–48.8`),
and **every real theme background in the table agrees**. That is the honest
conclusion, and it points somewhere more useful than "fix the threshold":

> The existing heuristic is fine. The problem with inference is not that it
> classifies badly — it is that a _fixed theme_ has a fixed background, so
> inference can only ever report what the theme already decided. It can never
> report what the **user** wants.

Which is the entire argument for this research tree: the fix is not a better
threshold, it is asking the platform.

## Where the derivation must not reach

A derivation that retints everything produces a coherent but wrong result. Two
categories must survive it untouched:

1. **Semantic status colors.** `error`, `warn`, `info`, `diffAdded`,
   `diffRemoved` mean something. An error that follows a green desktop accent
   stops being an error. [Apple's HIG](../ios.md#what-the-guidelines-require)
   states the rule directly: preserve meaning across appearances.
2. **The syntax channel.** A user who chose `catppuccin-mocha` chose those
   keyword colors. Following the system accent into
   [syntax rules](../../../specs/ui/theme.md) would overwrite an explicit
   aesthetic choice with an implicit one.

What _should_ follow is chrome: page fore/background, panel surfaces, gutters,
scrollbars, the focused-pane band, the selection tint, the caret. That division —
**chrome follows the system, content follows the theme** — is the policy the
[comparison](../comparison.md#what-follows-the-system-and-what-must-not) states
and the [proposal](../sparkles-proposal.md) implements.

## Sources

- [Material Design 3 — how the color system works][hct] — HCT, tonal palettes, the tone-delta rule quoted above
- [AOSP — Dynamic color][aosp] — the tonal-palette recipes and 13 tone indices
- [WCAG 2.2 — contrast minimum][wcag] and [relative luminance][relum]
- [Support Dark and Light themes in Win32 apps][mslearn] — the `(5G+2R+B)` brightness formula
- `libs/ui/src/sparkles/ui/style.d` — `schemeForBackground`, the Rec. 601 baseline compared above
- All measurements on this page are produced by [`examples/derive-palette.d`](./examples/derive-palette.d), which CI compiles and runs

<!-- References -->

[aosp]: https://source.android.com/docs/core/display/dynamic-color
[hct]: https://m3.material.io/styles/color/system/how-the-system-works
[mslearn]: https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-windows-themes
[relum]: https://www.w3.org/WAI/GL/wiki/Relative_luminance
[wcag]: https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
