# Android (Material You / dynamic color)

The only platform in this survey that **generates a palette for you** — five
tonal palettes extracted from the user's wallpaper — and the one where a
self-rendering native application can reach the least of it.

|                     |                                                                                          |
| ------------------- | ---------------------------------------------------------------------------------------- |
| Preference surface  | night mode · dynamic color (wallpaper-seeded) · contrast (3 levels, API 34) · font scale |
| Canonical API       | `Configuration.uiMode` · `android.R.color.system_*` · `UiModeManager.getContrast()`      |
| Native (NDK) API    | `AConfiguration_getUiModeNight()` · `APP_CMD_CONFIG_CHANGED`                             |
| Change notification | **push** — configuration change (activity recreation or `onConfigurationChanged`)        |
| Palette derivation  | **the system does it** — 5 palettes × 13 tones, exposed as color resources               |
| Reachable from NDK  | night mode: yes · dynamic color: **only via JNI** · contrast: **only via JNI**           |

## Overview

### What it solves

Material You's premise is that the user picks a wallpaper, and the entire system —
and every consenting app — retints itself to match. That is a much stronger claim
than "follow dark mode", and it requires the platform to solve a problem no other
vendor solves in the OS: turning one arbitrary image into a coherent, accessible,
light-and-dark palette.

### Design philosophy

The pipeline, per the [AOSP dynamic-color documentation][aosp]:

1. **Seed.** A single source color is derived from the wallpaper via
   `com.android.systemui.monet.ColorScheme#getSeedColors`. When nothing suitable
   is found the fallback is the literal `0xFF1B6EF3`.
2. **Five palettes.** The seed becomes `accent1`, `accent2`, `accent3`,
   `neutral1`, `neutral2`, each a recipe over the seed in
   [HCT](./concepts.md#tone-and-the-tonal-palette): `accent1` at chroma 40/48
   holding the seed's tone, `accent2` at chroma 16, `accent3` at chroma 32 with
   hue rotated **+60°**, `neutral1` at chroma 4 and `neutral2` at chroma 8.
3. **Thirteen tones each.** Every palette is sampled at tones
   `0, 10, 50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 1000` — "a set of 13
   colors with defined various luminance values".
4. **Exposed as resources.** `android.R.color.system_accent1_10` and its 64
   siblings, readable by any app from API 31 (Android 12).

The design payoff is that **contrast is structural**. Because the ladder is in
perceptually uniform tone, a role pair like `primary`/`onPrimary` is defined as a
fixed tone distance and is therefore accessible by construction — the
[tone-delta rule](./color-derivation/index.md#the-tone-delta-rule) this tree
measures. Android 13 added variants (Neutral, Vibrant Tonal, Expressive) that
change the recipe's vibrancy and hue rotation while keeping the ladder.

## How it works

### Night mode

`Configuration.uiMode & UI_MODE_NIGHT_MASK` against `UI_MODE_NIGHT_YES` /
`UI_MODE_NIGHT_NO` / `UI_MODE_NIGHT_UNDEFINED` — three-valued, like every other
platform. Resource qualifiers (`values-night/`) let the framework switch whole
resource sets without app code.

### Contrast

Android 14 (API 34) added a **three-step** contrast slider (Standard / Medium /
High) under Accessibility → Color and motion, with
`UiModeManager.getContrast()` returning a float and
`addContrastChangeListener()` / `removeContrastChangeListener()` for changes.
Together with Apple, this is why the
[appearance triple](./concepts.md#the-appearance-triple) models contrast as more
than a boolean even though GNOME and Windows only report two states.

### Change notification

A configuration change is delivered by **recreating the activity** unless the app
declares `android:configChanges` and handles `onConfigurationChanged` itself.
That is a meaningfully different contract from every other platform here: the
default response to "the user switched to dark mode" is that your process's UI is
torn down and rebuilt. An app with expensive state — a parsed syntax tree, a GPU
atlas — wants the opt-out, and then owns the diffing.

### The NativeActivity reality

This is the dimension that matters for [`hue`](../../specs/hue/android.md), which
ships as a `NativeActivity` APK with no Java UI layer. From native code:

| Preference        | Reachable from the NDK?                                                                                           |
| ----------------- | ----------------------------------------------------------------------------------------------------------------- |
| Night mode        | **yes** — `AConfiguration_getUiModeNight(AConfiguration*)`, returning `ACONFIGURATION_UI_MODE_NIGHT_{NO,YES,ANY}` |
| Config changes    | **yes** — `APP_CMD_CONFIG_CHANGED` through `android_native_app_glue`                                              |
| Dynamic color     | **no** — `android.R.color.system_*` are _resources_; reaching them means JNI into `Resources.getColor`            |
| Contrast (API 34) | **no** — `UiModeManager` is a Java system service; JNI only                                                       |

So a NativeActivity gets the light/dark bit cheaply and everything else only by
crossing into the JVM. That is not a small caveat: on Android the _interesting_
preference is dynamic color, and it is precisely the one behind JNI.

GTK's Android backend confirms the shape from the other side — libadwaita's
`adw-settings-impl-android.c` declares its features as
`(color_scheme: TRUE, high_contrast: FALSE, accent_colors: TRUE, …)` and sources
both from `GdkAndroidDisplay`, which is the Java-aware layer:

```c
GdkAndroidDisplayNightMode night_mode =
  gdk_android_display_get_night_mode (GDK_ANDROID_DISPLAY (self->display));
…
const GdkRGBA *accent_color = gdk_android_display_get_accent_color (…);
```

Note what it does **not** claim: `high_contrast` is `FALSE` even on Android 14,
because the contrast API is not surfaced through GDK. Even a full toolkit stops
short of the whole surface.

### The pragmatic native recipe

For a NativeActivity that wants more than the bit, the options in increasing cost:

1. **Night mode only, no JNI.** `AConfiguration_getUiModeNight`, re-read on
   `APP_CMD_CONFIG_CHANGED`. Zero Java, works today, gets light/dark and nothing
   else.
2. **A tiny JNI call for the accent.** One `GetStaticIntField`-style lookup of
   `android.R.color.system_accent1_500` through `Resources.getColor`, cached and
   refreshed on config change. Yields a seed the app can run its own derivation
   from — which is the same code path the [Linux accent](./gnome/index.md) needs,
   so it is not new machinery.
3. **The whole ladder.** Read all 65 `system_*` resources and use Android's
   palette directly instead of deriving. Highest fidelity, most JNI, and it makes
   the Android look diverge from every other platform's.

Option 2 is the sweet spot for a cross-platform app: it reuses the accent-driven
derivation the other platforms already require, and adds one JNI call rather than
a second palette system.

## What the guidelines require

Material 3's guidance is to assign **design tokens**, not values —
`colorPrimary`, `colorOnPrimary`, `colorPrimaryContainer` — and let the theme
supply them, exactly the semantic-color rule Apple states differently. Opt-in for
views is `DynamicColors.applyToActivitiesIfAvailable(this)` or a theme parented on
`ThemeOverlay.Material3.DynamicColors.DayNight`.

The token discipline is what makes dynamic color possible at all: a palette that
changes with the wallpaper can only be substituted into an app that never named a
color.

## Traps

| Trap                                                        | Consequence                                                        |
| ----------------------------------------------------------- | ------------------------------------------------------------------ |
| Assuming `system_*` resources are reachable from the NDK    | they are resources; native code needs JNI                          |
| Not declaring `android:configChanges`                       | the activity is destroyed and recreated on every appearance change |
| Declaring it and then not handling `onConfigurationChanged` | the app keeps the old appearance silently                          |
| Treating `UI_MODE_NIGHT_UNDEFINED` as day                   | ignores the app's own default                                      |
| Assuming dynamic color exists                               | API 31+, and OEM builds may not ship it — check, don't assume      |
| Using Android's full tonal ladder on one platform only      | that platform's look diverges from the rest of the app             |
| Reading contrast without an API-34 guard                    | `NoSuchMethodError` on older devices                               |

## Strengths

- The only platform that derives a full, accessible palette for the app.
- Tone-based construction makes contrast a structural property, not a review step.
- Three-level contrast, matching Apple and exceeding the desktops.
- The resource-qualifier mechanism switches whole asset sets with no app code.

## Weaknesses

- The good part is behind JNI for native applications.
- Activity recreation as the default change contract is expensive for stateful apps.
- Dynamic color availability varies by API level and OEM.
- The palette is Android-shaped; adopting it wholesale makes a cross-platform app
  look inconsistent across its targets.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                 | Trade-off                                                                  |
| ---------------------------------------------- | --------------------------------------------------------- | -------------------------------------------------------------------------- |
| Derive the palette from the wallpaper          | personalization the user never has to configure           | the app cedes control of its identity; needs a token-only codebase         |
| Build on HCT tone rather than HSL lightness    | fixed tone deltas give predictable contrast at any hue    | requires a real color-appearance model, not a 20-line conversion           |
| Expose the ladder as framework color resources | any app, any language binding, no library needed          | resources are a Java-layer concept — invisible to the NDK                  |
| Recreate the activity on configuration change  | guarantees every resource is re-resolved correctly        | expensive for apps with costly state; opt-out shifts the burden to the app |
| Three-step contrast (API 34)                   | a boolean cannot express "somewhat higher"                | not surfaced natively or through GDK; effectively Java-only                |
| `accent3` at hue +60°                          | guarantees a usable tertiary that is not a near-duplicate | a fixed rotation is occasionally wrong for the seed's neighbourhood        |

## Sources

- [AOSP — Dynamic color][aosp] — seed extraction, the five palette recipes, the 13 tone indices, and the `0xFF1B6EF3` fallback
- [Android Developers — Dynamic color][devdc] — opt-in APIs, variants, the five key colors
- [`UiModeManager`][uimm] — `getContrast()`, contrast change listeners (API 34)
- [Material Design 3 — how the color system works][m3] — tokens and the tone/contrast relationship
- libadwaita `src/adw-settings-impl-android.c` at [`01d51e39`][adwandroid] — which features a toolkit actually claims on Android
- [`hue` Android spec](../../specs/hue/android.md) — the NativeActivity target this dimension is measured against

<!-- References -->

[adwandroid]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-android.c
[aosp]: https://source.android.com/docs/core/display/dynamic-color
[devdc]: https://developer.android.com/develop/ui/views/theming/dynamic-colors
[m3]: https://m3.material.io/styles/color/system/how-the-system-works
[uimm]: https://developer.android.com/reference/android/app/UiModeManager
