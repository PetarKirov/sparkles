# Windows (WinRT `UISettings` / DWM / High Contrast)

The platform with **no light/dark API at all** — dark mode is inferred from a
color — and the one that ships the survey's only true
[forced-colors](./concepts.md#forced-colors) mode.

|                     |                                                                                                    |
| ------------------- | -------------------------------------------------------------------------------------------------- |
| Preference surface  | apps/system color mode · accent color (and a tinted ladder) · High Contrast · transparency effects |
| Canonical API       | `Windows.UI.ViewManagement.UISettings` (WinRT), callable from Win32                                |
| Legacy API          | `HKCU\…\Themes\Personalize\AppsUseLightTheme` · `SystemParametersInfo(SPI_GETHIGHCONTRAST)`        |
| Change notification | **push** — `UISettings.ColorValuesChanged`; `WM_SETTINGCHANGE` / `WM_THEMECHANGED` for Win32       |
| Palette derivation  | none for app content; the accent comes with a light/dark ladder for chrome                         |
| Reachable w/o WinRT | partly — the registry value works, High Contrast works; the accent needs WinRT                     |
| Non-client area     | opt-in: `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`                                     |

## Overview

### What it solves

Windows added dark mode late, to an ecosystem of Win32 applications that would
break if the OS restyled them. The result is a design constrained entirely by
backwards compatibility: nothing changes for an app unless the app asks, and even
the window title bar stays light until it explicitly opts in. Microsoft states
the position plainly: "Windows doesn't know if an application can support Dark
mode, so it assumes that it can't for backwards compatibility reasons."

### Design philosophy

The most consequential design decision is that **there is no `IsDarkMode`
property**. Microsoft's own recommended detection is to read the _foreground
color_ and classify its brightness:

```cpp
inline bool IsColorLight(Windows::UI::Color& clr)
{
    return (((5 * clr.G) + (2 * clr.R) + clr.B) > (8 * 128));
}

auto settings = UISettings();
auto foreground = settings.GetColorValue(UIColorType::Foreground);
bool isDarkMode = static_cast<bool>(IsColorLight(foreground));
```

Read that twice: dark mode is `true` when the **foreground** is light. The
documentation explains the weighting as "a quick calculation of the _perceived
brightness_ of a color … using all-integer math for speed on typical CPUs", and
warns it "is not a model for real analysis of color brightness".

Two things follow. First, the platform is telling apps to do exactly the
luminance-guessing that [terminal apps](./terminal/index.md) are stuck with for
lack of anything better — except here it is the _documented_ API. Second, the
weighting `(5G + 2R + B) / 8` is a third distinct brightness formula alongside
Rec. 601 (which `sparkles.ui.style.schemeForBackground` uses today) and CIE `L*`
(which [color-derivation](./color-derivation/index.md) recommends); their
thresholds do not coincide, which is measured in that page.

## How it works

### Reading the mode

Two routes:

- **WinRT `UISettings`** — the documented one. `GetColorValue(UIColorType::Foreground)`
  plus `IsColorLight` as above. It also serves `UIColorType::Accent` and the
  ladder below.
- **The registry** — `HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`,
  `AppsUseLightTheme` (app content) and `SystemUsesLightTheme` (taskbar and
  system chrome), both `DWORD` `0` = dark, `1` = light. Undocumented as an API
  contract but universally used, and reachable from a plain Win32 process with no
  COM apartment, no WinRT, and no `combase` load.

For a self-rendering application the registry route is genuinely attractive: it
is a `RegGetValueW` call, it works in a console process, and it distinguishes app
content from system chrome — a distinction WinRT does not expose.

### The accent, and its ladder

`UIColorType` carries `Accent` plus `AccentDark1..3` and `AccentLight1..3` — the
system's own tinted ladder around the user's accent, so chrome that needs a
hover or pressed variant does not have to compute one. This is the only place in
the survey where a desktop platform ships accent _tones_ rather than a single
hue, and it is a small preview of what [Android](./android.md) does thoroughly.

The accent is a free color (a full picker, plus wallpaper-derived suggestions),
unlike [GNOME's nine](./gnome/index.md#the-accent-is-quantized).

### High Contrast is forced colors

`SystemParametersInfo(SPI_GETHIGHCONTRAST, …)` and the `HCF_HIGHCONTRASTON`
flag. This is not "increase contrast" in the [GNOME](./gnome/index.md) or
[Apple](./ios.md) sense — it is the system substituting a small user-chosen
palette for the app's colors, and it is what the web's
[`forced-colors`](./web.md) media query surfaces. libadwaita's Win32 backend maps
it straight onto its `high_contrast` feature:

```c
if (SystemParametersInfoA (SPI_GETHIGHCONTRAST, sizeof hc, &hc, 0)) {
  gboolean high_contrast = (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
  adw_settings_impl_set_high_contrast (ADW_SETTINGS_IMPL (self), high_contrast);
}
```

The correct application response is to **stop specifying decorative color**, not
to push its own colors apart. An app that "supports high contrast" by darkening
its own dark theme has misread the signal.

### The title bar is separate

Even with the content painted dark, the non-client area stays light until the app
asks:

```cpp
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif
BOOL value = TRUE;
::DwmSetWindowAttribute(hWnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &value, sizeof(value));
```

The `#ifndef` in Microsoft's own sample is the tell: the attribute number was
**19** before Windows 10 build 18985 and **20** after, and neither is in older
SDK headers. Code that must work on both tries 20, and on failure tries 19.

### Change notification

`UISettings.ColorValuesChanged` is the documented event, and Microsoft's sample
re-reads the foreground inside the handler rather than trusting the event
payload — the "notification means re-read" discipline
[concepts](./concepts.md#push-vs-poll) states generally.

A Win32 app without WinRT watches `WM_SETTINGCHANGE` with `lParam` pointing at
the string `"ImmersiveColorSet"`, and `WM_THEMECHANGED` (`0x031A`) — the latter
is what libadwaita's Win32 backend installs a message filter for. Both are
coarse: they say "something themed changed", so the handler re-reads.

## Reachability from a non-WinRT application

Mixed, and the split is worth planning around:

| Preference    | Plain Win32                                 | Needs WinRT |
| ------------- | ------------------------------------------- | ----------- |
| Light/dark    | `RegGetValueW(AppsUseLightTheme)`           | no          |
| High Contrast | `SystemParametersInfo(SPI_GETHIGHCONTRAST)` | no          |
| Accent color  | —                                           | **yes**     |
| Accent ladder | —                                           | **yes**     |
| Change signal | `WM_SETTINGCHANGE` / `WM_THEMECHANGED`      | no          |

libadwaita's backend takes the WinRT path but loads it dynamically — resolving
`RoInitialize`, `RoActivateInstance` and `WindowsCreateStringReference` out of
`combase.dll` at runtime and degrading when they are absent:

```c
if ((enable_color_scheme || enable_accent_colors) && FAILED (init_winrt_settings (self)))
  enable_color_scheme = enable_accent_colors = FALSE;
```

That is the pattern to copy: **the accent is optional, and its absence is
declared rather than faked.** For Sparkles, whose Windows support is planned, the
practical staging is registry-plus-`SPI` first (no COM, no dependency), WinRT
accent later behind a capability flag.

## Traps

| Trap                                                        | Consequence                                                   |
| ----------------------------------------------------------- | ------------------------------------------------------------- |
| Looking for an `IsDarkMode` API                             | there is none; the documented route infers from a color       |
| Confusing `AppsUseLightTheme` with `SystemUsesLightTheme`   | app content and system chrome follow different settings       |
| Hard-coding `DWMWA_USE_IMMERSIVE_DARK_MODE = 20`            | wrong on builds before 18985, where it is 19                  |
| Forgetting the title bar entirely                           | dark content in a light frame — the classic half-ported look  |
| Treating High Contrast as "more contrast"                   | it is forced colors; the app should stop specifying color     |
| Trusting `ColorValuesChanged` payload instead of re-reading | the event is a hint, not a value                              |
| Requiring WinRT for basic dark-mode support                 | drags COM into a console or minimal Win32 process for no gain |

## Strengths

- The accent ships with a light/dark ladder, so chrome states need no derivation.
- The legacy route (registry + `SPI`) is genuinely dependency-free and works in
  console processes.
- A real forced-colors mode with an unambiguous flag.
- App-content and system-chrome modes are separable, which no other platform offers.

## Weaknesses

- No first-class light/dark query; the documented method is a brightness heuristic.
- The accent is WinRT-only, so the cheap path is also the incomplete one.
- Nothing is applied automatically — even the title bar is opt-in per window.
- Change signals are coarse and undocumented in places (`"ImmersiveColorSet"`).
- The `19`/`20` attribute split is a version check baked into every app.

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                        | Trade-off                                                              |
| ------------------------------------------------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Nothing restyles unless the app opts in                | thirty years of Win32 apps keep working                          | a half-ported app looks broken; every surface is a separate opt-in     |
| Infer dark mode from the foreground color              | no new API surface; works with the existing color settings       | a heuristic with a documented caveat, in the role of an API            |
| Accent exposed with `AccentDark1..3`/`AccentLight1..3` | chrome states need no color math in the app                      | WinRT-only, so the ladder is unreachable on the cheap path             |
| High Contrast as forced colors, not increased contrast | guarantees a result for users who need it, regardless of the app | apps routinely misread it and "increase contrast" instead              |
| Split app-content and system-chrome modes              | lets a user keep a light taskbar with dark apps                  | two settings to read; apps read the wrong one                          |
| Title bar behind `DwmSetWindowAttribute`               | apps that cannot paint a dark frame keep a light one             | the constant changed value across builds and is absent from older SDKs |

## Sources

- [Support Dark and Light themes in Win32 apps][mslearn] — `IsColorLight`, `UISettings`, `ColorValuesChanged`, `DWMWA_USE_IMMERSIVE_DARK_MODE` (all code above quoted from it)
- [`UISettings`][uisettings] and [`UIColorType`][uicolortype] — WinRT reference
- [`DwmSetWindowAttribute`][dwmsetattr] / [`DWMWINDOWATTRIBUTE`][dwmattr]
- libadwaita `src/adw-settings-impl-win32.c` at [`01d51e39`][adwwin32] — dynamic `combase` loading, `SPI_GETHIGHCONTRAST`, `WM_THEMECHANGED`

<!-- References -->

[adwwin32]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-win32.c
[dwmattr]: https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwmwindowattribute
[dwmsetattr]: https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmsetwindowattribute
[mslearn]: https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-windows-themes
[uicolortype]: https://learn.microsoft.com/en-us/uwp/api/windows.ui.viewmanagement.uicolortype
[uisettings]: https://learn.microsoft.com/en-us/uwp/api/windows.ui.viewmanagement.uisettings
