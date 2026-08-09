# Proposal — OS-derived themes for `sparkles:ui` and `hue`

What this survey concludes Sparkles should build, and in what order. This is a
research-tree proposal, not a normative spec: when it is accepted, its
requirements land in [`docs/specs/ui/theme.md`](../../specs/ui/theme.md) as
`THM10`+ and in [`docs/specs/hue/config.md`](../../specs/hue/config.md) as a new
`appearance.follow` setting, and this page becomes the rationale they cite.

**Last reviewed:** August 9, 2026

---

## The problem, restated precisely

`hue` bases every color on a
[`sparkles.ui.theme.Theme`](../../specs/ui/theme.md), selected by name from
`builtinThemes` via `--theme` or a config key. Two consequences:

1. **The user's desktop preference is invisible.** A user in dark mode who has
   not configured `hue` gets whatever `builtinThemes`' default is. On
   [Android](../../specs/hue/android.md), where
   [there is no command line](../../specs/hue/config.md), it is unreachable
   entirely.
2. **A running instance never changes.** Every platform in this survey can
   _tell_ an application the appearance changed
   ([comparison](./comparison.md#dimension-5--change-delivery)); `hue` has
   nowhere to receive that.

And the current light/dark decision is circular: `schemeForBackground` infers the
scheme from `Theme.defaultBg` — the theme's own background. As
[color-derivation](./color-derivation/index.md#scheme-inference-vs-the-os-answer)
measures, that inference is accurate; it is just answering the wrong question. It
reports what the theme decided, never what the user wants.

## The shape

A new leaf library, `sparkles:appearance`, sitting beside `sparkles:base` with no
UI dependency, plus one new channel into `Theme`.

```
sparkles:appearance  ──┐
   (OS preferences)    ├──►  deriveTheme()  ──►  sparkles.ui.theme.Theme
sparkles:ui (Slot/Palette)                             │
                                                       ▼
                                    hue / ui-gallery / any runApp application
```

Why a separate library rather than a module in `sparkles:ui`:

- It is an **environment query**, not a presentation concern — the same argument
  [`sparkles.base.term_caps`](../../guidelines/AGENTS.md) already makes for
  living in `base` ("a logger, a CLI tool and a full-screen UI all need it, and
  none of them should pull in a UI stack to ask").
- Its dependencies are platform-shaped (a D-Bus client on Linux, WinRT on
  Windows) and must not become dependencies of the toolkit.
- It is independently useful: a CLI tool that only wants "is this terminal dark"
  should not link a widget toolkit.

`base` is the wrong home for the same reason — a D-Bus client does not belong in
the allocation-conscious foundation library.

### The core types

```d
/// Three-valued, per the consensus in comparison.md § Dimension 1.
enum SchemePreference : ubyte { noPreference, light, dark }

/// Three steps, because Android 14 and Apple have three (Dimension 3).
enum ContrastLevel : ubyte { standard, medium, high }

/// What one backend could actually answer. Absence is first-class:
/// `hasAccent == false` on iOS and in every terminal.
struct SystemAppearance
{
    SchemePreference scheme;
    RgbColor         accent;
    ContrastLevel    contrast;
    bool             forcedColors;   // Windows High Contrast; web forced-colors
    bool             reducedMotion;

    // Capability flags — libadwaita's five `has_*` predicates, in D.
    bool hasScheme, hasAccent, hasContrast, hasForcedColors, hasReducedMotion;
}
```

The capability flags are the survey's single most load-bearing import. They come
straight from [libadwaita](./libadwaita.md)'s
`adw_settings_impl_get_has_*` family, and they are what lets one type describe a
GNOME session that answers three of four keys, an Android build whose contrast is
behind JNI, and a terminal that has no accent at all — all without lying.

### The backend seam

A [Design-by-Introspection](../../guidelines/design-by-introspection-01-guidelines.md)
hook, not a class hierarchy — matching how
[`isCanvas!T`](../../specs/ui/backends.md) already works in the toolkit:

```d
enum isAppearanceSource(T) = is(typeof((T t) {
    SystemAppearance a = t.read();          // required
}));

// Optional primitives, detected by presence:
//   t.subscribe(void delegate(SystemAppearance) nothrow) → push notification
//   t.paletteOverride()                                  → KDE's real colors
```

`subscribe` being **optional** is deliberate: a one-shot ANSI render never needs
it, and a backend that cannot provide it (a macOS tool with no run loop) declares
that by not having the method rather than by returning an error.

### Composition: the cascade

[libadwaita's cascade](./libadwaita.md#design-philosophy) transfers directly, and
D expresses it better than C does — sources compose at compile time and one
binary can carry several, which the `#if`-based original cannot. That matters
here because a single Sparkles process can render to a
[terminal and a GPU window in the same run](../../specs/ui/backends.md).

Order, highest priority first:

1. **Explicit configuration** — `--theme`, `appearance.theme`. Always wins.
   libadwaita's rule: "apps are still free to set their own accent color… CSS
   always takes priority over the system accent".
2. **Environment override** — `SPARKLES_APPEARANCE=dark|light|...`, mirroring
   `ADW_DEBUG_COLOR_SCHEME`. Needed so
   [golden captures](../../specs/hue/gui.md) stay deterministic, exactly as
   `HUE_GUI_*` already does for [`CFG2`](../../specs/hue/config.md).
3. **Platform source** — portal / registry / `NSAppearance` / `AConfiguration`.
4. **Terminal source** — mode 2031, then OSC 11.
5. **Compiled default** — the current behaviour, unchanged.

Each level fills only the features the levels above left unclaimed, per feature —
not per level.

---

## Milestones

### Milestone P0 — the vocabulary and the derivation

The whole of [color-derivation](./color-derivation/index.md), promoted from an
example into the library, with no OS integration at all.

- `SystemAppearance`, `SchemePreference`, `ContrastLevel` as above.
- `deriveTheme(SystemAppearance, in Theme seed) → Theme` — tone-based placement
  of the chrome slots, leaving the syntax channel and semantic slots untouched
  ([the policy](./comparison.md#what-follows-the-system-and-what-must-not)).
- Contrast **verified**, not assumed: unit tests asserting ≥ 4.5:1 body text and
  ≥ 3:1 chrome accent across `{light, dark} × {standard, medium, high}`, which is
  what [`derive-palette.d`](./color-derivation/examples/derive-palette.d)
  already does.
- Widen `Slot` for the accent-derived roles if
  [`THM2`](../../specs/ui/theme.md) has not already landed.

Shippable and testable with zero platform code, and it makes
[`THM7`](../../specs/ui/theme.md) (runtime theme swap) exercisable — a derived
theme is a second theme to swap to.

### Milestone P1 — the terminal source

The [terminal](./terminal/index.md) backend, because it is the cheapest, covers
the sink `hue` uses most, and exercises every part of the abstraction.

- `CSI ? 996 n` query with a 200 ms budget; `CSI ? 2031 h` subscription;
  OSC 11 fallback; `COLORFGBG` last.
- `tmux` DCS passthrough when `$TMUX` is set.
- The `CSI ? 997` reply must be decoded by
  [`sparkles:input`](../../specs/ui/input.md), not read from stdin behind the
  event loop's back — see
  [the hazard](./terminal/index.md#the-reply-is-input).
- `CSI ? 2031 l` on teardown, alongside the existing alt-screen/mouse unwind in
  `sparkles:tui`.

Deliverable: `hue --tui` and the ANSI sink follow the terminal's scheme, and
re-theme live when the user switches their terminal.

### Milestone P2 — the Linux backend

The [portal](./gnome/index.md), serving GNOME, KDE and anything else with a
backend.

- A minimal D-Bus client — `ReadOne` plus a `SettingChanged` subscription. This
  is the one genuinely new dependency in the plan; Sparkles has no D-Bus binding,
  and [`portal-appearance.d`](./gnome/examples/portal-appearance.d) sidesteps it
  by spawning `gdbus`, which is fine for a demonstration and unacceptable in a
  library (a process spawn per read, and no way to subscribe at all).
- **Probe per key.** `NotFound` is a distinct outcome from `0`
  ([the finding](./gnome/index.md#coverage-is-per-backend)).
- **Debounce.** The signal was observed firing twice per change; compare before
  rebuilding a theme.
- Optional `paletteOverride()` reading `kdeglobals` on Plasma, mapping
  `Colors:View` → page, `Colors:Window` → `chrome`, `Colors:Selection` →
  `selection` ([the mapping](./kde.md#eight-color-sets-not-one)).

> [!NOTE]
> The D-Bus client is the largest single unknown in this plan. If it proves
> heavier than expected, P2 can ship read-only over a one-shot connection and
> defer the subscription — losing live updates on Linux while keeping them in the
> terminal, which is where `hue` users mostly are.

### Milestone P3 — macOS and Android

The two platforms `hue` already ships on.

- **macOS:** `CFPreferencesCopyAppValue("AppleInterfaceStyle")` and
  `AppleAccentColor`; no AppKit link. Change delivery deferred — the only
  non-AppKit mechanism is
  [racy and undocumented](./macos.md#change-notification), and reading at startup
  is already the whole improvement for a CLI-launched viewer.
- **Android:** `AConfiguration_getUiModeNight` on the existing
  `android_native_app_glue` config, re-read on `APP_CMD_CONFIG_CHANGED`. No JNI,
  so no accent and no contrast — declared via the capability flags rather than
  faked. This is the point of the flags: the Android backend simply reports
  `hasAccent == false`, exactly as
  [GTK's own Android backend](./android.md#the-nativeactivity-reality) reports
  `has_high_contrast = FALSE`.

Deferred by design: one JNI call for `android.R.color.system_accent1_500`, which
would light up accent derivation on Android using the P0 machinery unchanged.

### Milestone P4 — the HTML sink

[`DEF5`](../../specs/hue/feature-requirements.md), which this survey supplies the
mechanism for: emit **one** document carrying both palettes via
[`light-dark()`](./web.md#light-dark) and `color-scheme: light dark`, switched by
`prefers-color-scheme` or `:root[data-theme]`.

The generator already exists —
`sparkles.ui.style.writeTwoslashVars` emits the `--twoslash-*` custom-property
block and a test keeps it in lockstep with the stylesheet
([`THM5`](../../specs/ui/theme.md)). Emitting a `light-dark()` pair per variable
instead of one value is a change to that function, not a new subsystem.

The accent must be **baked in at generation time**: the web
[deliberately does not expose it](./web.md#design-philosophy), so a page cannot
re-derive what the native app followed.

### Milestone P5 — Windows and iOS

Both currently planned-but-unspecified for `hue`.

- **Windows:** the cheap path first — `RegGetValueW(AppsUseLightTheme)` and
  `SystemParametersInfo(SPI_GETHIGHCONTRAST)`, no COM
  ([the split](./windows.md#reachability-from-a-non-winrt-application)). WinRT
  accent behind a capability flag afterwards, loaded dynamically the way
  libadwaita does. Plus `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`
  on the GPU window, trying attribute 20 then 19.
- **iOS:** the host shim pushes traits in; the core pulls nothing
  ([why](./ios.md#reachability-from-a-non-uikit-application)). The seam already
  supports this — a "backend" that is just a setter satisfies
  `isAppearanceSource`.

---

## Requirements this would add

Proposed for [`docs/specs/ui/theme.md`](../../specs/ui/theme.md):

| ID      | Requirement                                                                                                                                                      |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `THM10` | A `Theme` must be **derivable** from an OS appearance triple, not only authored; the derivation covers the chrome slots and leaves the syntax channel untouched. |
| `THM11` | The color scheme must be **three-valued**; `noPreference` selects the application's own default rather than light.                                               |
| `THM12` | Every appearance input must carry a **capability flag**; an unavailable preference is declared absent, never defaulted silently.                                 |
| `THM13` | Derived palettes must **verify** contrast (≥ 4.5:1 body, ≥ 3:1 chrome accent) in tests, rather than inferring it from a tone delta.                              |
| `THM14` | An appearance change must re-derive and repaint without restart, satisfying [`THM7`](../../specs/ui/theme.md)'s byte-identity criterion.                         |
| `THM15` | Explicit configuration outranks the system: `--theme` and `appearance.theme` always win.                                                                         |

And for [`docs/specs/hue/config.md`](../../specs/hue/config.md): an
`appearance.follow` key (`system` | `never`, default `system`), which is also the
only route to the preference on [Android](../../specs/hue/android.md).

## Risks

| Risk                                                 | Mitigation                                                                        |
| ---------------------------------------------------- | --------------------------------------------------------------------------------- |
| The D-Bus client is larger than budgeted             | P2 ships read-only first; the terminal source (P1) already covers most `hue` use  |
| A derived theme looks worse than a hand-authored one | derivation applies to **chrome only**; `catppuccin-mocha`'s syntax colors survive |
| Live re-theming exposes latent state in the backends | it is [`THM7`](../../specs/ui/theme.md), already specified and already partial    |
| Golden captures become environment-dependent         | `SPARKLES_APPEARANCE` override pre-empts every source, as `ADW_DEBUG_*` does      |
| Users dislike the app changing under them            | `appearance.follow=never`; explicit `--theme` always wins                         |
| The accent lands on an illegible tone for some hue   | assertions in P0 fail the build; the clamp limitation is documented in advance    |

## Sequencing note

P0 and P1 together deliver the visible win — `hue` in a terminal follows the
terminal, live — with no new dependency and no platform code. Everything after is
additive and independently shippable, which is the right shape for a change that
touches a type every color in the application flows through.

→ [Comparison & synthesis](./comparison.md) · [Overview](./index.md)
