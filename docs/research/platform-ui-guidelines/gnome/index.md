# GNOME (GTK 4 / libadwaita / XDG portal)

The desktop that turned appearance preferences into a **cross-desktop wire
protocol** rather than a toolkit API — and therefore the one that decides what a
non-GTK application can read on Linux.

|                     |                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------- |
| Preference surface  | color scheme · accent color · contrast · reduced motion · document/monospace fonts |
| Canonical API       | `org.freedesktop.portal.Settings` (D-Bus), namespace `org.freedesktop.appearance`  |
| Toolkit API         | `AdwStyleManager` (libadwaita), `GtkSettings` (GTK)                                |
| Change notification | **push** — `SettingChanged(namespace, key, value)` D-Bus signal                    |
| Palette derivation  | none exposed; libadwaita ships a hand-authored named palette per accent            |
| Reachable w/o GTK   | **yes** — the portal is the point; no toolkit link required                        |
| Runnable example    | [`examples/portal-appearance.d`](./examples/portal-appearance.d)                   |

## Overview

### What it solves

GNOME's appearance settings live in GSettings (`org.gnome.desktop.interface`),
which is a GNOME-specific store behind a GNOME-specific library. That is fine for
GNOME applications and useless for everybody else — a Flatpak-sandboxed app cannot
reach the host's dconf at all, and a non-GLib application should not have to link
GIO to learn whether the user likes dark mode.

The answer was to publish the preferences over D-Bus through
[xdg-desktop-portal][portal], in a **vendor-neutral namespace** that other
desktops implement too. `org.freedesktop.appearance` is the result, and it is the
reason [KDE](../kde.md), Sway/wlroots setups and GNOME can all be asked the same
question by the same code.

### Design philosophy

The portal interface documents `ReadAll`, the deprecated `Read`, and `ReadOne`,
which "was added in version 2". The deprecation note is the interesting part:
`Read` has "a known issue: the value returns wrapped in two variant layers
instead of one" — an ABI mistake preserved for compatibility with a fixed method
beside it. New code uses `ReadOne`.

The `org.freedesktop.appearance` keys, with the domains the spec assigns:

| Key              | Type    | Values                                            |
| ---------------- | ------- | ------------------------------------------------- |
| `color-scheme`   | `u`     | 0 no preference · 1 prefer dark · 2 prefer light  |
| `accent-color`   | `(ddd)` | RGB in `[0,1]` sRGB; **out-of-range means unset** |
| `contrast`       | `u`     | 0 normal · 1 higher contrast                      |
| `reduced-motion` | `u`     | 0 no preference · 1 reduced motion                |

`accent-color` arrived in xdg-desktop-portal 1.17.1; `contrast` and
`reduced-motion` followed. Unknown values are to be treated as `0`.

## How it works

### The portal route

One D-Bus method call, no session-specific knowledge:

```bash
gdbus call --session \
  --dest org.freedesktop.portal.Desktop \
  --object-path /org/freedesktop/portal/desktop \
  --method org.freedesktop.portal.Settings.ReadOne \
  org.freedesktop.appearance color-scheme
```

On the GNOME 4x session this survey was written against, that and its siblings
answer:

```[Output]
desktop: XDG_CURRENT_DESKTOP=GNOME   (querying via gdbus)
portal Settings interface version: 2

org.freedesktop.appearance:
  color-scheme   1  (prefer-dark)
  accent-color   #3584E4  (0.2078, 0.5176, 0.8941)  = AdwAccentColor 'blue'
  contrast       0  (normal)
  reduced-motion NOT IMPLEMENTED by this backend (portal.Error.NotFound)

=> theme to use: the app's dark theme
```

That capture is the real output of
[`examples/portal-appearance.d`](./examples/portal-appearance.d) on the authoring
machine, and it demonstrates both of this page's findings at once — see
[Coverage is per-backend](#coverage-is-per-backend) and
[The accent is quantized](#the-accent-is-quantized).

### The GSettings route

Underneath, GNOME's own keys are:

| GSettings key                                    | Portal key       |
| ------------------------------------------------ | ---------------- |
| `org.gnome.desktop.interface color-scheme`       | `color-scheme`   |
| `org.gnome.desktop.interface accent-color`       | `accent-color`   |
| `org.gnome.desktop.a11y.interface high-contrast` | `contrast`       |
| `org.gnome.desktop.interface enable-animations`  | `reduced-motion` |

`xdg-desktop-portal-gnome`'s `src/settings.c` reads exactly these and republishes
them, guarding each with `g_settings_schema_has_key` so an older schema degrades
to absence rather than crashing. An application **should not** use this route:
it fails under sandboxing, it hard-codes GNOME, and it duplicates the portal's
normalization.

### Change notification

`SettingChanged(namespace, key, value)` is emitted on the portal object. Captured
live on the authoring machine while toggling `enable-animations`:

```
/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged
  ('org.gnome.desktop.interface', 'enable-animations', <false>)
/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged
  ('org.gnome.desktop.interface', 'enable-animations', <false>)
/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged
  ('org.gnome.desktop.interface', 'enable-animations', <true>)
/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged
  ('org.gnome.desktop.interface', 'enable-animations', <true>)
```

Two observations, both load-bearing:

1. **The signal fired twice per change.** The session had both
   `org.freedesktop.impl.portal.desktop.gnome` and
   `org.freedesktop.impl.portal.desktop.gtk` registered, and the change
   propagated through both. A consumer that repaints on every signal repaints
   twice; a consumer that _rebuilds a theme_ on every signal does that work
   twice. Compare against the held value first.
2. **The namespace was the GNOME one, not `org.freedesktop.appearance`.** The
   portal forwards vendor namespaces verbatim in addition to the neutral one. A
   client filtering strictly on `org.freedesktop.appearance` will see the neutral
   signal, but it must not assume every signal it receives is in that namespace.

### Coverage is per-backend

`reduced-motion` is documented in the current portal spec and implemented in
`xdg-desktop-portal-gnome`'s `main` branch — and the deployed backend on the
authoring machine answered `org.freedesktop.portal.Error.NotFound` for it while
answering the other three. The spec version reported was `2`.

The lesson generalizes past this one key: **the interface version does not tell
you which keys exist.** Version 2 is a statement about `ReadOne` existing, not
about namespace coverage. Each key has to be probed, and `NotFound` has to be a
first-class outcome distinct from "the value is 0" — the difference between "the
user has no preference" and "this desktop cannot tell me".

Across backends the asymmetry is concrete: GNOME's implements all four keys in
`main`; [KDE's](../kde.md) implements `color-scheme`, `accent-color` and
`reduced-motion` but **not** `contrast`.

### The accent is quantized

`accent-color`'s type is an arbitrary sRGB triple, which suggests a color picker
behind it. On GNOME there is not one. `xdg-desktop-portal-gnome` reads the
`accent-color` GSettings **enum**, maps it onto libadwaita's `AdwAccentColor`, and
converts that to RGB at the boundary:

```c
switch (g_settings_get_enum (bundle->settings, "accent-color"))
  {
  case G_DESKTOP_ACCENT_COLOR_BLUE:
    color = ADW_ACCENT_COLOR_BLUE;
    break;
  …
  }
adw_accent_color_to_rgba (color, &color_rgba);
return g_variant_new ("(ddd)", color_rgba.red, color_rgba.green, color_rgba.blue);
```

So the value is always one of nine hexes. The live read above returned
`(0.20784313976764679, 0.51764708757400513, 0.89411765336990356)`, which is
exactly `#3584E4` — libadwaita's `blue`. The example asserts that correspondence
at runtime by matching against the nine known values, so the finding stays true or
the example stops saying it.

The consequence for a consumer is a real design choice, taken up in
[comparison](../comparison.md#dimension-2--accent-raw-or-quantized): accept an
arbitrary hue and _compute_ a palette, or recognize the nine and ship
hand-tuned palettes. GNOME does the latter; [libadwaita](../libadwaita.md) even
re-quantizes an arbitrary incoming triple back to the enum with
`adw_accent_color_nearest_from_rgba`.

## What the guidelines require

The [libadwaita](../libadwaita.md) design guidance, which is GNOME's de-facto HIG
for colors, asks applications to consume **named style classes and CSS variables**
rather than literals, and states that accent support needs no application changes
in the common case: "Accent colors are supported automatically, and in most cases
apps don't need any changes to make use of them. However, apps are still free to
set their own accent color, and CSS always takes priority over the system
accent."

That last clause is the policy statement worth carrying into a design: the
system accent is a **default, not an override**. An application that has a
deliberate reason to own a color keeps owning it.

## Reachability from a non-GTK application

This is GNOME's strongest dimension and the reason the portal exists. A D program
needs:

- a **D-Bus client** — one method call and one signal subscription;
- **no GTK, no GLib, no GSettings schema, no dconf**;
- no display-server connection, so it works over ssh and inside a container with
  the bus socket bind-mounted.

Sparkles has no D-Bus binding today. The example sidesteps that by invoking
`gdbus`/`busctl` and parsing their output, which is honest for a demonstration and
wrong for a library: it costs a process spawn per read and cannot subscribe to the
signal at all. See the
[proposal](../sparkles-proposal.md#milestone-p2--the-linux-backend) for how that
gap is scoped.

## Traps

| Trap                                                                                  | Consequence                                                   |
| ------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| Treating `color-scheme: 0` as light                                                   | a dark-by-default app flips light on a default desktop        |
| Assuming interface version 2 implies all four keys                                    | `NotFound` crashes or is mis-read as `0`                      |
| Repainting on every `SettingChanged`                                                  | duplicate work; observed 2× per change with two backends live |
| Filtering signals only on the neutral namespace and assuming that is all that arrives | vendor-namespace signals surprise the handler                 |
| Using `Read` rather than `ReadOne`                                                    | double-wrapped variant; deprecated                            |
| Reading GSettings directly                                                            | breaks under Flatpak; hard-codes GNOME                        |
| Believing `accent-color`'s type                                                       | a recipe built for arbitrary hues, exercised with nine        |

## Strengths

- The **only** appearance API in this survey designed to be consumed from outside
  its own toolkit, and the only one that is genuinely cross-vendor.
- Push notification with a stable, introspectable signal.
- Sandbox-transparent by construction.
- Values are already normalized (an enum, not a theme name to string-match).

## Weaknesses

- Coverage is a per-backend lottery with no capability query; probing is the only
  way to know.
- Duplicate signal delivery when several impl backends are registered.
- No palette: an app gets a bit and a hue and must build everything else.
- `contrast` is a boolean, so it cannot express Android's or Apple's middle step.
- Requires a D-Bus client, which is a real dependency for a small application.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                      | Trade-off                                                                      |
| ------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Publish over D-Bus, not a library API       | works for any language, any toolkit, inside a sandbox          | every consumer needs a D-Bus client; a process spawn is the cheap wrong answer |
| Vendor-neutral namespace beside vendor ones | one code path serves GNOME, KDE and wlroots desktops           | neutral coverage is the intersection of what backends bother to implement      |
| Three-valued `color-scheme`                 | preserves "no preference" so an app's own default survives     | consumers habitually collapse it to two and break the default                  |
| Accent as an sRGB triple                    | forward-compatible with a future free color picker             | GNOME quantizes to nine, so the type over-promises and consumers over-engineer |
| Deprecate `Read`, add `ReadOne`             | fixes the double-variant bug without breaking existing callers | two methods for one job; the wrong one is the more obvious name                |
| `contrast` as a boolean                     | matches GNOME's own single high-contrast switch                | cannot represent a middle step, so cross-platform code needs a wider type      |

## Sources

- [`org.freedesktop.portal.Settings` interface documentation][portal]
- `xdg-desktop-portal-gnome` `src/settings.c` ([`main`][xdpg-settings]) — the GSettings ↔ portal mapping and the `AdwAccentColor` conversion
- [libadwaita 1.6 release notes][adw16] — `AdwStyleManager` accent properties, and the "CSS always takes priority" policy
- [xdg-desktop-portal 1.17.1 release announcement][xdp1171] — `accent-color` introduction
- Live captures on GNOME (`XDG_CURRENT_DESKTOP=GNOME`, portal Settings v2), August 2026 — reproduced by [`examples/portal-appearance.d`](./examples/portal-appearance.d)

<!-- References -->

[adw16]: https://blogs.gnome.org/alicem/2024/09/13/libadwaita-1-6/
[portal]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html
[xdp1171]: https://www.phoronix.com/news/XDG-Desktop-Portal-1.17.1
[xdpg-settings]: https://gitlab.gnome.org/GNOME/xdg-desktop-portal-gnome/-/blob/main/src/settings.c
