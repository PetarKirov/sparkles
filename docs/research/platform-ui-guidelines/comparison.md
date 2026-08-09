# Comparison & synthesis

Where the field agrees, where it genuinely forks, and where Sparkles stands
today. Read the [deep-dives](./index.md#master-catalog) first if you want the
evidence; this page is the conclusions.

**Last reviewed:** August 9, 2026

---

## At a glance

| Platform                        |  Scheme  | Accent            | Contrast        | Reduced motion | Push notify |   Ships a palette    | Reachable without the native toolkit |
| ------------------------------- | :------: | ----------------- | --------------- | :------------: | :---------: | :------------------: | ------------------------------------ |
| [iOS / iPadOS](./ios.md)        | 3-valued | **none**          | 2-valued        |       ✓        |      ✓      |          ✓           | no — UIKit traits only               |
| [Android](./android.md)         | 3-valued | wallpaper-seeded  | **3-valued**    |       ✓        |      ✓      |       ✓ (5×13)       | scheme only; the rest needs JNI      |
| [GNOME](./gnome/index.md)       | 3-valued | 9 named           | 2-valued        |   ✓ (patchy)   |      ✓      |          —           | **yes** — D-Bus portal               |
| [KDE Plasma](./kde.md)          | 3-valued | free RGB          | — (native only) |       ✓        |      ✓      |   ✓ (8 role sets)    | **yes** — INI + portal               |
| [Windows](./windows.md)         | 2-valued | free RGB + ladder | forced colors   |       ✓        |      ✓      |          —           | partly — registry yes, accent no     |
| [macOS](./macos.md)             | 2-valued | 8 indexed         | 2-valued        |       ✓        |  ✓ (racy)   |          ✓           | **yes** — global-domain defaults     |
| [Terminal](./terminal/index.md) | 2-valued | **none**          | **none**        |       —        |      ✓      | the 16-color palette | **yes** — two escape sequences       |
| [Web](./web.md)                 | 2-valued | **none**          | **4-valued**    |       ✓        |      ✓      |          —           | n/a — it is the sandbox              |

Three structural facts fall straight out of this table.

**Nobody is missing the scheme, and almost everybody is missing something else.**
Light/dark is universal and solved. Accent is absent on iOS, the terminal and the
web; contrast is absent on the terminal and unreachable neutrally on KDE. A
consumer abstraction that models "appearance support" as one bit cannot describe
a single row here honestly.

**Push notification is universal.** Every platform, including the terminal over a
pty, can tell an application that the appearance changed. Polling is never
required and never correct. The corollary is that _the ability to re-theme at
runtime is the real requirement_ — reading the preference at startup is the easy
half.

**Reachability from outside the native toolkit is better than expected.** Four of
eight are fully reachable with no toolkit link at all, and the two hardest cases
are the two Apple mobile-style APIs. For a self-rendering application like
[`hue`](../../specs/hue/index.md), that is the difference between "we can do this"
and "we need a UIKit shim per platform".

---

## Dimension 1 — the color scheme

**Consensus.** Three values (light / dark / **no preference**), delivered by
push, re-read on notification. Every platform that got here later
([Windows](./windows.md), the [web](./web.md), the
[terminal](./terminal/index.md), [macOS](./macos.md)) shipped two values and
regretted it in a small way: the app's own default becomes unexpressible.

**The fork: semantic answer vs. inferred one.** [Windows](./windows.md) has no
`IsDarkMode`; the documented method infers it from a color's brightness. The
[terminal](./terminal/index.md) had the same shape until DEC mode 2031, and OSC
11 remains the fallback. Everyone else answers semantically.

The measured consequence is in
[color-derivation](./color-derivation/index.md#scheme-inference-vs-the-os-answer):
the three brightness formulas in play (Rec. 601, Windows' `(5G+2R+B)/8`, CIE
`L*`) disagree only in a narrow band of mid greys that no real theme uses. So
inference is not _inaccurate_ — it is **underdetermined**. A fixed theme has a
fixed background, so inferring from it reports what the theme decided, never what
the user wants. That is the whole case for asking the platform.

**Resolution for Sparkles.** Model three values. Prefer the semantic answer;
fall back to inference only where nothing else exists, and keep
`schemeForBackground` for that role rather than replacing it.

## Dimension 2 — accent: raw or quantized

A genuine three-way fork, with a clear line through it:

| Approach                     | Platforms                                       | Why                                             |
| ---------------------------- | ----------------------------------------------- | ----------------------------------------------- |
| **Free RGB**                 | KDE, Windows, Android (seed)                    | maximum user expression                         |
| **Quantized to a named set** | GNOME (9), macOS (8), libadwaita (9 internally) | lets a toolkit ship hand-tuned assets per color |
| **Not exposed**              | iOS, terminal, web                              | app identity (Apple) or fingerprinting (web)    |

[libadwaita](./libadwaita.md) does something revealing: it consumes free RGB on
Windows, macOS and Android and immediately **re-quantizes** it with
`adw_accent_color_nearest_from_rgba()`, discarding the user's actual choice —
because its widgets want to special-case nine colors. That is a defensible
trade for an asset-shipping toolkit and a bad one for a procedural renderer.

The second, subtler finding: libadwaita converts an accent to a colour **twice**,
via `adw_accent_color_to_rgba()` and `adw_accent_color_to_standalone_rgba()`.
A fill accent and a text accent are different colours for the same role, because
the hue that reads as a background fails contrast as text. **Any derivation that
treats the accent as one colour gets one of those two cases wrong** — which is
why the [derivation](./color-derivation/index.md#placement) places
`chromeAccent` and `chromeFocused` at different tones.

**Resolution for Sparkles.** Accept free RGB (the platforms that have a real
picker deserve it), derive per-role tones, and model the accent as **optional** —
because on three of eight platforms there is not one.

## Dimension 3 — contrast: boolean, tri-state, or forced

Three incompatible things share one word:

1. **Increase contrast** — push your own colors further apart. GNOME
   (`contrast: 0|1`), macOS, iOS (`accessibilityContrast`).
2. **A contrast _level_** — a magnitude, not a flag. [Android 14](./android.md)
   (Standard/Medium/High via `UiModeManager.getContrast()`); the
   [web](./web.md) additionally has `prefers-contrast: less`, which nothing else
   models.
3. **Forced colors** — stop specifying colors; the system substitutes them.
   [Windows High Contrast](./windows.md), surfaced on the web as
   [`forced-colors`](./web.md).

The third is categorically different and the most commonly misimplemented: an app
that "supports high contrast" on Windows by darkening its own dark theme has
misread the signal entirely.

**Resolution for Sparkles.** A three-step `ContrastLevel` (widening at the
abstraction loses nothing; narrowing loses the middle step permanently), plus a
separate **forced-colors** flag that suppresses decorative color rather than
scaling it.

## Dimension 4 — who builds the palette

| Platform ships              | Platforms                     | What the app must do                       |
| --------------------------- | ----------------------------- | ------------------------------------------ |
| A complete semantic palette | iOS, macOS                    | name roles; write no color code            |
| A generated tonal palette   | Android                       | name tokens; the wallpaper drives the rest |
| A full role-scoped palette  | KDE                           | map its roles onto yours                   |
| Nothing but scalars         | GNOME, Windows, web, terminal | **derive everything**                      |

This is the sharpest fork in the survey, and it decides the shape of a
cross-platform implementation. An app targeting only Apple platforms writes no
color code; an app targeting GNOME and the terminal writes all of it. An app
targeting **both** must have a derivation anyway — so the derivation is the
baseline, and platform-supplied palettes become an _optional refinement_ layered
on top, not an alternative architecture.

Practically: derive from the triple everywhere, and let [KDE](./kde.md) (the one
Linux desktop that publishes real colors) override individual slots when its
scheme is readable.

## Dimension 5 — change delivery

Universal push, but with three recurring defects that a consumer must assume:

- **Duplicate delivery.** Observed live on GNOME: `SettingChanged` fired **twice**
  per change with two portal backends registered
  ([gnome](./gnome/index.md#change-notification)).
- **Stale-at-notification.** macOS's distributed notification can arrive before
  the default is updated ([macos](./macos.md#change-notification)).
- **Valueless notification.** The [terminal](./terminal/index.md)'s
  `CSI ? 997 n` deliberately carries no value; Android's config change carries a
  whole `Configuration` you must diff.

Every one of these is neutralized by the same discipline, which the field has
independently converged on and which the [terminal spec authors wrote into the
protocol](./terminal/index.md#design-philosophy):

> **A notification means "re-read". It never means "the value is now X".**
> Compare against the value you hold, and repaint only on a real difference.

The [web](./web.md) is the sole exception — `matchMedia` change events carry a
boolean the UA already computed — and it is also the only platform where the app
need not participate at all.

## Dimension 6 — reachability from a self-rendering application

The dimension that matters most for Sparkles, since
[`sparkles:ui`](../../specs/ui/index.md) paints its own pixels on every target.

| Platform  | Cost of following the system                                            |
| --------- | ----------------------------------------------------------------------- |
| Terminal  | two `write(2)`s, a `poll(2)`, a parser — **no dependency**              |
| macOS     | one `CFPreferencesCopyAppValue`; change delivery needs a run loop       |
| GNOME/KDE | a D-Bus client (one call, one signal) — no toolkit, sandbox-transparent |
| KDE extra | plus an INI parse for the full palette                                  |
| Windows   | `RegGetValueW` + `SystemParametersInfo`; **accent needs WinRT**         |
| Android   | `AConfiguration_getUiModeNight` free; **accent and contrast need JNI**  |
| iOS       | nothing — the host shim must push the traits in                         |

The pattern: **the scheme is cheap everywhere; the accent is the expensive part
on three platforms and absent on three others.** That asymmetry argues strongly
for shipping scheme-following first and accent-following as a separate,
capability-gated increment — which is how the
[proposal](./sparkles-proposal.md) sequences the work.

## What follows the system, and what must not

The survey's clearest cross-platform policy, stated by Apple as "preserve
meaning across appearances" and implied by Material's token discipline:

| Follows the system                          | Does **not** follow                                       |
| ------------------------------------------- | --------------------------------------------------------- |
| page background / default foreground        | syntax-highlighting rules (the user chose that theme)     |
| panel and popup surfaces, borders, dividers | semantic status: `error`, `warn`, `info`                  |
| gutters, scrollbar track and thumb          | diff colors (`diffAdded` / `diffRemoved` mean add/remove) |
| focused-pane band, selection tint, caret    | anything the user configured explicitly                   |
| chrome accents and key hints                | brand colors an app deliberately owns                     |

libadwaita states the precedence rule for the last row exactly: "apps are still
free to set their own accent color, and CSS always takes priority over the system
accent". **The system supplies defaults, not overrides.** An explicit user or
app choice always wins.

---

## Delta table — where Sparkles stands today

Against the consensus, per capability. Sources: `libs/ui/src/sparkles/ui/theme.d`,
`libs/ui/src/sparkles/ui/style.d`, and the
[`sparkles:ui` theme spec](../../specs/ui/theme.md).

| Capability                              | Consensus                                               | Sparkles today                                                                                                                  |     Gap     |
| --------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- | :---------: |
| Widgets name semantic roles, not colors | universal                                               | **`Slot` + `Palette`** — [`THM1`](../../specs/ui/theme.md) already requires it                                                  |   ✓ none    |
| Theme is one runtime-swappable value    | required for change handling                            | **`Theme`** carries all four channels; [`THM7`](../../specs/ui/theme.md) is `partial`                                           |  ~ partial  |
| Light/dark from the OS                  | universal, push-delivered                               | **absent** — scheme is inferred from the theme's own background via `schemeForBackground`                                       |      ✗      |
| Three-valued scheme                     | 5 of 8 platforms                                        | **absent** — `ColorScheme` is a two-valued enum                                                                                 |      ✗      |
| Accent color                            | 5 of 8 platforms                                        | **absent** — no slot is accent-derived; `chromeAccent` is authored                                                              |      ✗      |
| Contrast level                          | 6 of 8 platforms; 3 steps on 2 of them                  | **absent**                                                                                                                      |      ✗      |
| Forced colors / high contrast           | Windows + web                                           | **absent**                                                                                                                      |      ✗      |
| Reduced motion                          | 6 of 8 platforms                                        | **absent**                                                                                                                      |      ✗      |
| Change notification → re-theme          | universal                                               | **absent** — no appearance source, so nothing to notify                                                                         |      ✗      |
| Per-feature capability flags            | [libadwaita](./libadwaita.md)'s five `has_*` predicates | **absent**, but the repo-wide [DbI protocol](../../guidelines/design-by-introspection-01-guidelines.md) is the same shape       |      ✗      |
| Capability-gated degradation per target | universal                                               | [`THM8`](../../specs/ui/theme.md) specifies it (`not started`); the warning about not gating on `isTerminal` is already correct | ~ specified |
| Tone-based derivation                   | Android; implied by Apple and Material                  | **absent** — palettes are authored as hexes                                                                                     |      ✗      |
| Contrast verified rather than assumed   | Material claims it structurally                         | **absent**                                                                                                                      |      ✗      |
| Multi-theme HTML output                 | web's `light-dark()` / `prefers-color-scheme`           | [`DEF5`](../../specs/hue/feature-requirements.md) — `researched/not-started`                                                    |      ✗      |

**The summary is unusually clean:** Sparkles' _architecture_ is already right —
semantic slots, one theme value, resolution at display-list construction, a
capability-gating requirement already written down. What is missing is entirely
the **input**: there is no source of OS preferences, so `Theme` is authored
rather than derived, and `ColorScheme` is inferred from the very theme it should
be selecting.

That is a good place to be. The gap is a new library and one new channel into an
existing type, not a refactor of the toolkit.

## What the proposal takes from each subject

| Subject                                         | Contribution to the design                                                     |
| ----------------------------------------------- | ------------------------------------------------------------------------------ |
| [libadwaita](./libadwaita.md)                   | per-feature capability flags; the backend cascade; declared degradation        |
| [GNOME](./gnome/index.md)                       | the portal as the one Linux route; probe per key; debounce duplicate signals   |
| [KDE](./kde.md)                                 | `Colors:View` ≠ `Colors:Window`; a platform palette can override derived slots |
| [Terminal](./terminal/index.md)                 | the first backend to build; timeout-as-capability-detection                    |
| [Android](./android.md)                         | tone-based derivation; the three-step contrast level                           |
| [iOS](./ios.md)                                 | accent must be optional; elevation is a colour input                           |
| [Windows](./windows.md)                         | forced colors ≠ high contrast; stage the cheap path before WinRT               |
| [macOS](./macos.md)                             | read the raw default without the framework; `bestMatch`, not name equality     |
| [Web](./web.md)                                 | `light-dark()` for the HTML sink; bake the accent in, it cannot be read back   |
| [color-derivation](./color-derivation/index.md) | place by tone, accept by ratio; chrome follows, content does not               |

→ [The Sparkles proposal](./sparkles-proposal.md)

## Sources

Each claim above is carried by the deep-dive it links to; those pages hold the
primary sources. The measurements are produced by the four runnable examples the
`ci` helper compiles and runs on every pass.
