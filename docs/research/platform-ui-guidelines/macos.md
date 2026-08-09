# macOS (AppKit / `NSAppearance`)

`hue`'s second shipping desktop target, and the platform whose appearance model
is [iOS's](./ios.md) with an accent color bolted on and a much easier escape
hatch for non-native code.

|                      |                                                                                                                |
| -------------------- | -------------------------------------------------------------------------------------------------------------- |
| Preference surface   | appearance (Aqua / Dark Aqua, ± high contrast) · accent color · highlight color · reduce motion / transparency |
| Canonical API        | `NSApplication.effectiveAppearance` · `NSAppearance` · `NSColor` semantic colors                               |
| Change notification  | **push** — KVO on `effectiveAppearance`; `NSDistributedNotificationCenter` for the raw defaults                |
| Palette derivation   | **the system ships the palette** — `NSColor` dynamic colors resolve per appearance                             |
| Reachable w/o AppKit | **yes, partly** — `AppleInterfaceStyle` in the global domain is readable by anything                           |

## Overview

### What it solves

macOS Mojave introduced Dark Mode to a desktop with a much smaller compatibility
tail than [Windows](./windows.md) and a much stricter framework than
[Linux](./gnome/index.md). The result sits between them: appearance is a
first-class object (`NSAppearance`), it is inherited down the view hierarchy the
way [iOS traits](./ios.md) are, and an app that uses `NSColor`'s semantic colors
gets dark mode for free.

### Design philosophy

The same "name the role, resolve late" rule as iOS, with the same payoff.
`NSColor.labelColor`, `.textBackgroundColor`, `.controlAccentColor`,
`.selectedContentBackgroundColor` and friends are not values but resolvers;
`NSColor.controlAccentColor` in particular tracks the user's accent setting
directly, which is the piece iOS lacks entirely.

`effectiveAppearance` is the resolved answer for a given object — it "takes into
account the inheritance hierarchy and returns a suitable appearance in the likely
event that no explicit value has been set on the object". Its name is one of the
more common bug sources on the platform: `NSApp.appearance` is what the app
_requested_ (usually `nil`) and `effectiveAppearance` is what it _gets_.

## How it works

### Reading it

```swift
let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
```

`bestMatch(from:)` rather than a name comparison, because the appearance may be
one of the **high-contrast** variants — `NSAppearanceNameAccessibilityHighContrastAqua`
and `…HighContrastDarkAqua`. Comparing `name == .darkAqua` reports "light" for a
user in high-contrast dark, which is both wrong and the exact opposite of what
they need.

### The raw preference

Outside AppKit, the global-domain user default is readable directly:

```bash
defaults read -g AppleInterfaceStyle    # prints "Dark", or errors when light
```

The **absence** of the key means light — an unusual encoding that makes "not
set" and "light" indistinguishable, so the three-valued
[no-preference](./concepts.md#the-appearance-triple) state the other platforms
carry does not exist here. `AppleAccentColor` (an integer index, `-1` for
graphite/multicolour) and `AppleHighlightColor` live in the same domain.

This is why macOS scores better than iOS on reachability: a non-AppKit process —
a CLI tool, a self-rendering renderer, a build script — can read the appearance
with `CFPreferencesCopyAppValue` or by shelling out, no framework link and no
run loop required.

### Change notification

Three levels, in decreasing fidelity:

1. **KVO on `effectiveAppearance`** — the supported route inside AppKit. Fires
   for every cause, including a per-window override.
2. **`NSDistributedNotificationCenter`, `AppleInterfaceThemeChangedNotification`** —
   process-wide, works without a view hierarchy, but is undocumented and famously
   racy: the notification can arrive _before_ the default is updated, so a
   handler that immediately re-reads sometimes gets the old value. The
   established workaround is to re-read on the next run-loop turn.
3. **Polling the default** — what a tool with no run loop is left with.

libadwaita's macOS backend takes route 1 and, notably, is the reason libadwaita
can claim "accent colors are also supported when running on Windows and macOS":
one abstraction, native backends, as described in [libadwaita](./libadwaita.md).

### Automatic graphite

An `NSColor` semantic color resolves correctly under
`NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast` and
`…ShouldReduceTransparency` without app involvement. An app painting its own
pixels has to consult those two properties itself; they are on `NSWorkspace`,
not on the appearance, which is easy to miss when porting from the trait-based
iOS model where contrast rides the same object as the scheme.

## Reachability from a non-AppKit application

Good for the scheme, adequate for the accent, poor for change delivery:

| Preference    | Without AppKit                                                                   |
| ------------- | -------------------------------------------------------------------------------- |
| Light/dark    | `CFPreferencesCopyAppValue("AppleInterfaceStyle", kCFPreferencesAnyApplication)` |
| Accent        | `AppleAccentColor` integer index → a fixed table of eight                        |
| Highlight     | `AppleHighlightColor` string, `"r g b name"`                                     |
| High contrast | `com.apple.universalaccess increaseContrast`                                     |
| Change signal | distributed notification (needs a run loop) or polling                           |

The accent index maps to a fixed palette (graphite, red, orange, yellow, green,
blue, purple, pink) — so macOS, like [GNOME](./gnome/index.md#the-accent-is-quantized),
is effectively a **quantized accent** platform even though the resolved
`NSColor` is a concrete value.

## Traps

| Trap                                                          | Consequence                                                                         |
| ------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| Reading `NSApp.appearance` instead of `effectiveAppearance`   | usually `nil`; the app never sees the system setting                                |
| `name == .darkAqua` instead of `bestMatch(from:)`             | high-contrast dark misreported as light                                             |
| Trusting `AppleInterfaceThemeChangedNotification` immediately | reads the stale value; re-read on the next run-loop turn                            |
| Treating a missing `AppleInterfaceStyle` as "no preference"   | on macOS, absent genuinely means light                                              |
| Looking for contrast on the appearance                        | it is on `NSWorkspace`, not `NSAppearance`                                          |
| Building against an old SDK                                   | `effectiveAppearance` reports light unless `NSRequiresAquaSystemAppearance` is `NO` |
| Caching a resolved `NSColor`                                  | stale in the other appearance, exactly as on iOS                                    |

## Strengths

- The raw preference is readable by any process, with no framework link — the
  best non-native reachability of any GUI platform here.
- A complete semantic palette plus a real user accent, unlike iOS.
- Appearance inheritance and per-window override, as on iOS.
- High-contrast variants are modelled as appearances, so `bestMatch` handles them.

## Weaknesses

- No three-valued scheme: absent means light, so "no preference" is unexpressible.
- Contrast and transparency live on a different object from the appearance.
- The only push mechanism reachable outside AppKit is undocumented and racy.
- The accent is an index into a fixed table, so it is quantized in practice.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                | Trade-off                                                                   |
| --------------------------------------------- | -------------------------------------------------------- | --------------------------------------------------------------------------- |
| Appearance as an inherited object             | per-window and per-view overrides, as on iOS             | `appearance` vs `effectiveAppearance` is a persistent bug source            |
| High contrast as separate appearance _names_  | one `bestMatch` call handles it                          | name equality — the obvious code — is wrong                                 |
| Store the raw preference in the global domain | readable by any process, scriptable, no framework needed | absence means light, so three-valued state is lost                          |
| Accent as an index into a fixed table         | a small, designed, guaranteed-legible set                | users cannot pick a free color; apps cannot derive from an arbitrary hue    |
| Contrast/transparency on `NSWorkspace`        | they are workspace-wide, not per-view                    | splits the appearance surface across two objects; easy to miss when porting |
| No documented non-AppKit change notification  | AppKit is the supported app model                        | tools and self-rendering apps are left with a racy or polling path          |

## Sources

- [`NSAppearance`][nsappearance] and [`effectiveAppearance`][effapp] — AppKit reference
- [`NSColor` UI element colors][nscolor] — the semantic palette and `controlAccentColor`
- [Human Interface Guidelines — Dark Mode][hig]
- [Mozilla bug 1593390][moz] — "Use `NSApplication::effectiveAppearance` and/or `NSRequiresAquaSystemAppearance` to detect dark mode instead of `standardUserDefaults`", a well-documented account of the failure modes above
- libadwaita `src/adw-settings-impl-macos.c` at [`01d51e39`][adwmac]

<!-- References -->

[adwmac]: https://gitlab.gnome.org/GNOME/libadwaita/-/blob/01d51e393fa613d5c1fd520fbcde79d68db21877/src/adw-settings-impl-macos.c
[effapp]: https://developer.apple.com/documentation/appkit/nsapplication/effectiveappearance
[hig]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[moz]: https://bugzilla.mozilla.org/show_bug.cgi?id=1593390
[nsappearance]: https://developer.apple.com/documentation/appkit/nsappearance
[nscolor]: https://developer.apple.com/documentation/appkit/nscolor
