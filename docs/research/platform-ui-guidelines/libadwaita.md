# libadwaita `AdwSettings` — the reference cross-platform abstraction

Not a platform: the **prior art**. libadwaita is a GNOME toolkit that nonetheless
follows the native appearance on six different systems, behind one interface —
which makes it the closest existing answer to the question this whole survey is
asked in service of.

|                     |                                                                              |
| ------------------- | ---------------------------------------------------------------------------- |
| What it is          | GTK 4's platform library; `AdwSettings` is its appearance abstraction        |
| Backends            | portal · gsettings · legacy (X11 `Xsettings`) · macOS · Win32 · Android      |
| Features abstracted | color scheme · high contrast · accent color · document font · monospace font |
| Composition         | a **cascade**: each backend claims the features it can serve                 |
| Overridability      | environment variables, then an explicit application override                 |
| Source              | `src/adw-settings*.c` at [`01d51e39`][adwtree]                               |

## Overview

### What it solves

libadwaita renders its own widgets. It does not use native controls on macOS or
Windows, so it gets none of the automatic adaptation an `NSColor` or a WinUI
control would give it — exactly the position
[`sparkles:ui`](../../specs/ui/index.md) is in. It nevertheless follows the
system light/dark setting and the system accent on every platform it runs on. The
mechanism it uses to do that is the thing worth studying.

### Design philosophy

Two decisions carry the design.

**Feature granularity, not platform granularity.** The abstraction is not "does
this platform support appearance" but five independent capabilities, each with
its own predicate:

```c
gboolean adw_settings_impl_get_has_color_scheme        (AdwSettingsImpl *self);
gboolean adw_settings_impl_get_has_high_contrast       (AdwSettingsImpl *self);
gboolean adw_settings_impl_get_has_accent_colors       (AdwSettingsImpl *self);
gboolean adw_settings_impl_get_has_document_font_name  (AdwSettingsImpl *self);
gboolean adw_settings_impl_get_has_monospace_font_name (AdwSettingsImpl *self);
void     adw_settings_impl_set_features                (AdwSettingsImpl *self,
                                                        gboolean         has_color_scheme,
                                                        gboolean         has_high_contrast,
                                                        gboolean         has_accent_colors,
                                                        gboolean         has_document_font_name,
                                                        gboolean         has_monospace_font_name);
```

This is exactly the shape the survey's findings demand. [Android](./android.md)
can serve the scheme and the accent but not contrast; [iOS](./ios.md) has no
accent at all; the [terminal](./terminal/index.md) has neither accent nor
contrast; a [GNOME portal](./gnome/index.md) answers three of four keys on one
machine and four on another. A single "supported" bit cannot express any of that;
five flags can.

It is also, recognizably, the
[capability-by-presence](../../guidelines/design-by-introspection-01-guidelines.md)
protocol Sparkles already uses throughout — arrived at independently, in C, by
people solving the same problem.

**Composition by cascade.** No backend has to be complete. `AdwSettings` holds
three implementations and asks each in turn for whatever is still unclaimed:

```c
self->platform_impl = adw_settings_impl_macos_new (!found_color_scheme,
                                                   !found_high_contrast,
                                                   !found_accent_colors,
                                                   !found_document_font_name,
                                                   !found_monospace_font_name);
```

Each `enable_*` argument is the negation of "somebody already provided this".
`register_impl` then wires up only what the implementation actually claimed:

```c
if (adw_settings_impl_get_has_color_scheme (impl)) {
  *found_color_scheme = TRUE;
  set_color_scheme (self, adw_settings_impl_get_color_scheme (impl));
  g_signal_connect_swapped (impl, "color-scheme-changed",
                            G_CALLBACK (set_color_scheme), self);
}
```

The order is **platform → gsettings → legacy**, so on a Linux desktop the portal
answers the scheme while GSettings still supplies the font names, and on a bare
X11 session the legacy `Xsettings` backend fills whatever is left. The result is
a per-feature best-available resolution rather than a per-platform one.

## How it works

### The backends, and what each claims

| Backend     | Source                          | Reads                                                               |
| ----------- | ------------------------------- | ------------------------------------------------------------------- |
| `portal`    | `adw-settings-impl-portal.c`    | `org.freedesktop.appearance` over D-Bus ([gnome](./gnome/index.md)) |
| `gsettings` | `adw-settings-impl-gsettings.c` | `org.gnome.desktop.interface` directly                              |
| `legacy`    | `adw-settings-impl-legacy.c`    | X11 `Xsettings` / `GtkSettings` — the pre-portal path               |
| `macos`     | `adw-settings-impl-macos.c`     | `NSAppearance`, `NSColor.controlAccentColor` ([macos](./macos.md))  |
| `win32`     | `adw-settings-impl-win32.c`     | WinRT `UISettings`, `SPI_GETHIGHCONTRAST` ([windows](./windows.md)) |
| `android`   | `adw-settings-impl-android.c`   | `GdkAndroidDisplay` night mode + accent ([android](./android.md))   |

The compile-time selection is a plain `#if` chain in
`adw-settings-impl-private.h` — `__APPLE__`, then `G_OS_WIN32`, then
`GDK_WINDOWING_ANDROID`, else portal — with `gsettings` and `legacy` always
compiled in as the tail of the cascade.

### Degradation is declared, not faked

The Win32 backend is the clearest instance. It loads WinRT dynamically and, when
that fails, **turns the features off** rather than inventing values:

```c
if ((enable_color_scheme || enable_accent_colors) && FAILED (init_winrt_settings (self)))
  enable_color_scheme = enable_accent_colors = FALSE;
```

High contrast survives, because `SystemParametersInfo` needs no WinRT. So on a
Windows build without `combase`, libadwaita reports "I can tell you about
contrast and nothing else" — and the cascade then gives the other two features to
a later backend or leaves them at the application's default.

The Android backend does the same thing for a different reason, declaring
`has_high_contrast = FALSE` outright even though
[Android 14 has a contrast API](./android.md#contrast) — because it is not
surfaced through GDK. A capability flag is about what _this build_ can actually
answer, not what the platform theoretically supports.

### Accent quantization

`AdwAccentColor` is a nine-value enum (blue, teal, green, yellow, orange, red,
pink, purple, slate). Every backend that reads a free-form platform accent —
Win32, macOS, Android — funnels it through
`adw_accent_color_nearest_from_rgba()`:

```c
adw_settings_impl_set_accent_color (ADW_SETTINGS_IMPL (self),
                                    adw_accent_color_nearest_from_rgba (&rgba));
```

So a Windows user's arbitrary accent becomes one of nine before any widget sees
it. The stated rationale is that a bounded set lets individual colors be
special-cased — "so that individual colors can be special cased (say, when using
bitmap assets)" — and the enum converts back to RGB on demand via
`adw_accent_color_to_rgba()` and `adw_accent_color_to_standalone_rgba()`.

The two-function split is itself a finding: a **background** accent and a
**standalone** (text-on-background) accent are different colors for the same
role, because the same hue that works as a fill fails contrast as text. Any
derivation that treats the accent as one color will get one of those two cases
wrong — which is why the
[Sparkles derivation](./color-derivation/index.md) places the accent at a
different tone for the `chromeAccent` (text) and `chromeFocused` (fill) slots.

### Overrides and debugging

`init_debug` reads `ADW_DEBUG_COLOR_SCHEME`, `ADW_DEBUG_HIGH_CONTRAST` and
`ADW_DEBUG_ACCENT_COLOR` _before_ any backend is constructed, and marks those
features as already found — so the environment override does not merely win, it
prevents the platform backend from ever claiming that feature. Above that sits an
application-level `override` used by the GTK inspector.

The three-layer precedence — **debug env → platform cascade → application
override** — is a good model, and directly comparable to
[`hue`'s configuration layering](../../specs/hue/config.md) (`CFG2`: defaults →
file → project → environment → CLI).

## What Sparkles should take, and what it should not

| Take                                                                        | Leave                                                                         |
| --------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Per-feature capability flags, not a per-platform bit                        | GObject signals and the `GType` machinery                                     |
| The cascade: each backend claims what it can, in priority order             | Compile-time `#if` backend selection — D can do better with traits            |
| Declared degradation (turn the feature off) over invented defaults          | Quantizing the accent to nine — Sparkles has no bitmap assets to special-case |
| Separate background-accent and standalone-accent resolution                 | The nine-color enum as a public type                                          |
| Environment overrides that pre-empt the platform, for reproducible captures | —                                                                             |

The quantization is the one deliberate divergence. libadwaita quantizes because a
bounded set lets it ship hand-tuned assets; Sparkles renders everything
procedurally and already has the
[tone machinery](./color-derivation/index.md) to place an arbitrary hue, so it
can accept the free accent that [KDE](./kde.md), [Windows](./windows.md) and
[Android](./android.md) actually provide.

## Strengths

- The only implementation in the survey that abstracts _six_ platforms behind one
  appearance interface, and it is small enough to read in an afternoon.
- Capability granularity matches the reality the rest of this survey documents.
- Degradation is explicit and testable rather than silent.
- Debug overrides make appearance-dependent rendering reproducible.

## Weaknesses

- The cascade order is hard-coded, so a user cannot prefer GSettings over the portal.
- Accent quantization loses information at the boundary, irreversibly.
- Backend selection is `#if`-based, so a single binary cannot carry two backends —
  fine for GTK, wrong for a Sparkles binary that may render to a
  [terminal and a GPU window in one process](../../specs/ui/backends.md).
- No contrast _level_, only a boolean, so Android's and Apple's middle step is lost.

## Key design decisions and trade-offs

| Decision                                          | Rationale                                                  | Trade-off                                                         |
| ------------------------------------------------- | ---------------------------------------------------------- | ----------------------------------------------------------------- |
| Five independent feature flags                    | platforms genuinely differ per feature, not per platform   | five predicates and five signals to wire, per backend             |
| Cascade platform → gsettings → legacy             | best-available per feature; partial backends are useful    | fixed order; no user control over the source                      |
| Quantize accents to nine named colors             | lets individual colors be special-cased with bitmap assets | irreversible loss of the user's actual choice                     |
| Split background vs standalone accent conversion  | the same hue cannot serve as both fill and text            | two functions callers must choose correctly between               |
| Declare features off when a dependency is missing | never invents a value; the cascade can fill in             | a feature can silently be unavailable with no user-visible reason |
| Compile-time backend selection                    | one platform per build; smallest binary                    | cannot serve two backends in one process                          |

## Sources

All at pinned commit [`01d51e39`][adwtree]:

- [`src/adw-settings-impl-private.h`][adwpriv] — the five-feature interface and the `#if` backend selection
- [`src/adw-settings.c`][adwsettings] — `register_impl`, the cascade, `init_debug`
- [`src/adw-settings-impl-win32.c`][adwwin32] — dynamic WinRT loading and declared degradation
- [`src/adw-settings-impl-android.c`][adwandroid] — `GdkAndroidDisplay` night mode and accent
- [`src/adw-settings-impl-macos.c`][adwmac]
- [libadwaita 1.6 release notes][adw16] — `accent-color`, `accent-color-rgb`, `system-supports-accent-colors`, and the macOS/Windows support statement

<!-- References -->

[adw16]: https://blogs.gnome.org/alicem/2024/09/13/libadwaita-1-6/
[adwandroid]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-android.c
[adwmac]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-macos.c
[adwpriv]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-private.h
[adwsettings]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings.c
[adwtree]: https://gitlab.gnome.org/GNOME/libadwaita/-/tree/01d51e393fa613d5c1fd520fbcde79d68db21877/src
[adwwin32]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-win32.c
