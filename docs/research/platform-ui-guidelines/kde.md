# KDE Plasma (KColorScheme / `kdeglobals`)

The desktop that hands an application a **whole palette** rather than a light/dark
bit — and the one whose portal coverage is narrower than its native surface.

|                     |                                                                                               |
| ------------------- | --------------------------------------------------------------------------------------------- |
| Preference surface  | full color scheme (8 role sets × ~10 roles) · accent color · scheme name                      |
| Canonical API       | `KColorScheme` / `KStatefulBrush` (KDE Frameworks), over `kdeglobals`                         |
| Neutral API         | `org.freedesktop.portal.Settings` — `color-scheme`, `accent-color`, `reduced-motion` **only** |
| Change notification | **push** — `KConfigWatcher` (`org.kde.kconfig.notify` D-Bus) or the portal signal             |
| Palette derivation  | **the palette _is_ the preference**; Plasma computes states, apps consume them                |
| Reachable w/o Qt    | yes — `kdeglobals` is plain INI; the portal covers the light/dark bit                         |
| Runnable example    | [`kde/examples/kdeglobals-appearance.d`](./kde/examples/kdeglobals-appearance.d)              |

## Overview

### What it solves

Where [GNOME](./gnome/index.md) exports a preference and expects the toolkit to
own the colors, Plasma exports **the colors**. A KDE color scheme is a document
listing concrete RGB values for every role in every context, and switching themes
means switching that document. `kdeglobals` is where the active one is
materialized: "when a color scheme is applied, its values are copied to
`~/.config/kdeglobals`".

The consequence for a follower is inverted relative to GNOME: on GNOME you
receive a bit and must derive a palette; on Plasma you receive a palette and must
decide how much of it to honour.

### Design philosophy

Roles are two-dimensional. One axis is the **set** — which kind of surface is
being painted — and the other is the **role** within that set. The eight sets
Breeze exports, verified against the upstream `BreezeDark.colors`:

```ini
[Colors:Window]           [Colors:View]        [Colors:Button]
[Colors:Selection]        [Colors:Tooltip]     [Colors:Complementary]
[Colors:Header]           [Colors:Header][Inactive]
```

Within each, `BackgroundNormal`, `ForegroundNormal`, `ForegroundActive`,
`ForegroundLink`, `ForegroundNegative`/`Neutral`/`Positive`, `DecorationFocus`,
`DecorationHover` and friends. `KStatefulBrush` then derives the disabled and
inactive variants from `[ColorEffects:Disabled]` and `[ColorEffects:Inactive]`
rather than storing them, so a scheme stays authorable by hand.

## How it works

### `kdeglobals` is the interface

```ini
[General]
ColorScheme=BreezeDark
AccentColor=61,174,233

[Colors:View]
BackgroundNormal=20,22,24
ForegroundNormal=252,252,252
```

Colors are decimal `r,g,b` (occasionally with a fourth alpha component).
`AccentColor` under `[General]` is the user's override; **absent means "inherit
the scheme's own"**, not "no accent" — the fallback is the scheme's
`DecorationFocus`.

### Eight color sets, not one

Running [`kdeglobals-appearance.d`](./kde/examples/kdeglobals-appearance.d)
against the upstream `BreezeDark.colors`:

```[Output]
[General] ColorScheme = BreezeDark
[General] AccentColor  = #3DAEE9 (61,174,233)

[Colors:*] sets present, with their normal fg/bg:
  Window             bg #202326   fg #FCFCFC
  View               bg #141618   fg #FCFCFC
  Button             bg #292C30   fg #FCFCFC
  Selection          bg #3DAEE9   fg #FCFCFC
  Tooltip            bg #292C30   fg #FCFCFC
  Complementary      bg #202326   fg #FCFCFC
  Header             bg #292C30   fg #FCFCFC
  Header (inactive)  bg #202326   fg #FCFCFC

=> document surface is Colors:View bg #141618 (Rec.601 luma 21 ⇒ dark)
```

`Window` is `#202326` and `View` is `#141618` — a genuine, visible difference.
**`View` is the document background**; `Window` is the chrome band around it. A
file viewer, an editor or a terminal paints on `View`. Picking `Window` because
it is the first section in the file produces a surface that is subtly wrong on
every Plasma scheme that distinguishes them, which is most of them.

For a viewer like [`hue`](../../specs/hue/index.md) the mapping is direct and
worth writing down:

| Plasma set              | `sparkles:ui` slot                       |
| ----------------------- | ---------------------------------------- |
| `Colors:View` bg/fg     | page background / default foreground     |
| `Colors:Window` bg/fg   | `chrome`                                 |
| `Colors:Selection` bg   | `selection`                              |
| `Colors:Header` bg      | `chrome` band, tab strip                 |
| `[General] AccentColor` | `chromeAccent`, `chromeFocused`, `caret` |
| `Colors:Tooltip` bg     | `surface` (popups)                       |

### The portal covers less than the desktop

Plasma ships `xdg-desktop-portal-kde`, so the [portal route](./gnome/index.md)
works here too. Its `src/settings.cpp` builds the `org.freedesktop.appearance`
map from exactly three keys:

```cpp
appearanceSettings.insert(colorScheme, readFdoColorScheme().variant());
appearanceSettings.insert(accentColor, readAccentColor().variant());
appearanceSettings.insert(reducedMotion, readReducedMotion().variant());
```

There is no `contrast`. That is the mirror image of the
[GNOME gap](./gnome/index.md#coverage-is-per-backend), where `reduced-motion` was
missing from the deployed backend and `contrast` was present — and together the
two make the general point: **the neutral namespace is a union on paper and an
intersection in practice.** Probe per key.

### Change notification

Two mechanisms, at different levels:

- **Native.** Plasma rewrites `kdeglobals` and `KConfigWatcher` picks the change
  up — a `KConfig`-level watch backed by `org.kde.kconfig.notify` D-Bus signals
  plus a file watch. The KDE-side design note is that the watching is centralized:
  rather than every consumer watching the file, "only the `KColorScheme` library
  does it".
- **Neutral.** The portal's `SettingChanged`, with the same caveats as on
  [GNOME](./gnome/index.md#change-notification).

A non-KDE application should subscribe to the portal signal for the _when_ and
re-read `kdeglobals` for the _what_ — the portal tells you something changed
promptly and correctly; the file has the detail the portal does not carry.

## What the guidelines require

KDE's Human Interface Guidelines ask applications to source colors from the
active scheme rather than hard-coding them, and Plasma's own components resolve
every color through `KColorScheme`. The accent-color work
([`D27263`][d27263]) made the accent loadable from `kdeglobals` rather than only
from a scheme file, so a user can keep a scheme and re-tint it — which means an
application must read **both** and let `AccentColor` win when present.

## Reachability from a non-Qt application

Better than it looks. `kdeglobals` is plain INI at a well-known XDG path, and the
values are already concrete RGB — no color-space work, no theme-name lookup, no
Qt. The example parses it in ~120 lines of D with no dependency beyond
`sparkles:base` for the color type.

Two rough edges a parser must handle:

- **`[Colors:Header][Inactive]`** is two bracket groups on one line. A naive INI
  reader that takes everything between the first `[` and the last `]` gets
  `Colors:Header][Inactive`, which happens to work as a key; one that stops at
  the first `]` silently merges the inactive header into the active one.
- **Section presence is meaningful.** An older or partial scheme omits sets, and
  the correct response is to fall back along a documented chain
  (`View` → `Window` → the portal's light/dark bit), not to substitute black.

## Traps

| Trap                                                        | Consequence                                                  |
| ----------------------------------------------------------- | ------------------------------------------------------------ |
| Using `Colors:Window` as the document background            | wrong surface on nearly every scheme; `View` is the document |
| Expecting `contrast` from the KDE portal                    | `NotFound`; Plasma exposes it nowhere neutral                |
| Treating absent `[General] AccentColor` as "no accent"      | drops the scheme's own accent instead of inheriting it       |
| Parsing `[Colors:Header][Inactive]` with a naive INI reader | inactive header silently overwrites the active one           |
| Watching only `kdeglobals` mtime                            | Plasma writes the file more than once per change; debounce   |
| Assuming the scheme name implies light/dark                 | user-installed schemes are named anything; read the colors   |

## Strengths

- The richest preference surface in the survey: an app that consumes it fully is
  genuinely indistinguishable from a native one.
- No derivation needed — no contrast math, no tone algebra, no accent recipe.
- Readable without linking anything, from any language.
- The accent is a free color, not a nine-value enum, so users get real choice.

## Weaknesses

- The neutral (portal) surface is narrower than GNOME's, missing `contrast`.
- The richness is only usable by an app whose slot vocabulary is close to
  Plasma's role vocabulary; anything else has to map, and the mapping is lossy.
- Two sources of truth (scheme file and `kdeglobals`) with an override rule that
  has to be known.
- No tonal structure: the scheme gives you the colors it gives you, and an app
  that needs an in-between tone must invent it.

## Key design decisions and trade-offs

| Decision                                           | Rationale                                            | Trade-off                                                                |
| -------------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| Export a full palette rather than a preference bit | apps match the desktop exactly, with no derivation   | apps whose roles differ from Plasma's must map, losing fidelity          |
| Materialize the active scheme into `kdeglobals`    | one well-known file; language- and toolkit-neutral   | a second source of truth beside the scheme file                          |
| Derive disabled/inactive via `[ColorEffects:*]`    | schemes stay hand-authorable; states stay consistent | consumers must implement the effects or lose state differentiation       |
| Accent as a free RGB in `[General]`                | real user choice, unlike GNOME's nine                | an app deriving from it cannot rely on a pre-tuned palette               |
| Centralize watching in `KColorScheme`              | one watcher, no thundering herd of file watches      | non-KDE consumers get no equivalent and must roll their own              |
| Ship only three keys through the portal            | the ones Plasma can answer honestly and cheaply      | `contrast` is unreachable neutrally, so cross-desktop code cannot use it |

## Sources

- [`BreezeDark.colors`][breeze] — the reference scheme; section list and values verified against it
- `xdg-desktop-portal-kde` [`src/settings.cpp`][xdpk-settings] — the three-key `org.freedesktop.appearance` map
- [KDE Phabricator `D27263`][d27263] — "RFC: Accent colour for KColorScheme"
- [KDE color-scheme desktop-integration notes][kdeint] — `kdeglobals` as the materialized active scheme
- [Plasma developer documentation][kdedev]

<!-- References -->

[breeze]: https://invent.kde.org/plasma/breeze/-/blob/master/colors/BreezeDark.colors
[d27263]: https://phabricator.kde.org/D27263
[kdedev]: https://develop.kde.org/docs/plasma/
[kdeint]: https://ethanc8.github.io/desktop-integration-x11-wayland/uncategorized/KDEColorScheme.html
[xdpk-settings]: https://invent.kde.org/plasma/xdg-desktop-portal-kde/-/blob/master/src/settings.cpp
