# iOS / iPadOS (UIKit & SwiftUI)

The platform that made appearance a **property of the view hierarchy** rather
than of the process — and the only one in this survey with no user-settable
accent color at all.

|                     |                                                                                                                                |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Preference surface  | user interface style · accessibility contrast · legibility weight (bold text) · interface level · reduce motion / transparency |
| Canonical API       | `UITraitCollection` (UIKit) · `@Environment(\.colorScheme)` (SwiftUI)                                                          |
| Change notification | **push** — `registerForTraitChanges(_:target:action:)` (iOS 17+), KVO-free and type-safe                                       |
| Palette derivation  | **the system ships the palette** — dynamic `UIColor`s resolve per trait collection                                             |
| User accent color   | **none** — iOS has no system accent setting                                                                                    |
| Reachable w/o UIKit | no; the traits are a UIKit concept and a non-UIKit renderer must be handed them                                                |

## Overview

### What it solves

Dark Mode on iOS is not a global flag an app reads once. It is one axis of a
**trait collection**, the same mechanism that carries size classes, display scale
and dynamic type — and trait collections are _inherited down the view hierarchy
and overridable at any node_. That design decision is the platform's defining
one: it makes "this one panel is always dark" expressible without the panel
knowing anything special, and it makes a screenshot-rendering path that needs the
opposite appearance a local override rather than a global mutation.

### Design philosophy

Apple's instruction to developers is to stop naming colors. The system ships
**semantic colors** whose whole purpose is to resolve differently per trait
collection — `UIColor.label`, `.secondaryLabel`, `.tertiaryLabel`,
`.quaternaryLabel` for text; `.systemBackground`,
`.secondarySystemBackground`, `.tertiarySystemBackground` for surfaces, with
`…GroupedBackground` variants for table-style screens; `.separator` and
`.opaqueSeparator`; `.link`; the `.systemFill` family for control fills.

An app built on those adapts to dark mode, to increased contrast, and to
elevation, without a line of conditional code — because each of those inputs is
a trait, and the color object is a function of the trait collection.

## How it works

### The appearance traits

| Trait                   | Values                                 | Meaning                                      |
| ----------------------- | -------------------------------------- | -------------------------------------------- |
| `userInterfaceStyle`    | `.light` · `.dark` · `.unspecified`    | the color scheme                             |
| `accessibilityContrast` | `.normal` · `.high` · `.unspecified`   | Settings → Accessibility → Increase Contrast |
| `legibilityWeight`      | `.regular` · `.bold` · `.unspecified`  | Bold Text                                    |
| `userInterfaceLevel`    | `.base` · `.elevated` · `.unspecified` | whether this surface sits above another      |
| `displayScale`          | 1× / 2× / 3×                           | rendering scale                              |

`userInterfaceLevel` is the one with no counterpart on any other platform in this
survey. In dark mode a shadow cannot separate a raised surface from the page, so
the system instead resolves `.systemBackground` _lighter_ when the level is
`.elevated`. Elevation is thereby a colour input rather than a shadow — the
concept [concepts.md](./concepts.md#elevation) names, and the reason the
[Sparkles derivation](./color-derivation/index.md) offsets its `surface` slot
away from the page in the dark direction only.

### Custom dynamic colors

An app that must own a color still names a role, by supplying a resolver:

```swift
let brand = UIColor { traits in
    switch traits.userInterfaceStyle {
    case .dark:  return UIColor(red: 0.33, green: 0.78, blue: 1.0, alpha: 1)
    default:     return UIColor(red: 0.14, green: 0.37, blue: 0.65, alpha: 1)
    }
}
```

The closure is invoked _at resolution time_, per trait collection, so the same
object is correct in a light view and a dark one simultaneously. This is exactly
the shape [`sparkles:ui`](../../specs/ui/theme.md)'s `Slot` → `Visual`
resolution already has: a widget names the role, the palette resolves it, and
the resolution is a function of the current appearance rather than a stored value.

### Change notification

iOS 17 replaced the override-a-method pattern with a registration API:

```swift
registerForTraitChanges([UITraitUserInterfaceStyle.self],
                        target: self, action: #selector(appearanceChanged))
```

`traitCollectionDidChange(_:)` is **deprecated** as of iOS 17. The new API is
type-safe (you name the trait types you care about), avoids waking every view for
every trait, and manages observer lifetime — which is a direct response to the
old pattern's defect, where every view controller in the app ran a diff on every
trait change including ones it had no interest in.

The notification is genuinely push and genuinely prompt: the system re-resolves
dynamic colors and re-renders as part of the same transaction, so an app using
semantic colors changes appearance with no code running at all.

## What the guidelines require

Apple's Human Interface Guidance on Dark Mode is unusually prescriptive, and the
three rules that survive translation to a non-Apple toolkit are:

1. **Use semantic colors; do not hard-code.** A literal that looked right in
   light mode is a bug in dark mode and an accessibility failure under increased
   contrast.
2. **Test both appearances, and test increased contrast separately.** Increased
   contrast is not "darker dark"; it changes the separator and fill colors more
   than the backgrounds.
3. **Preserve meaning across appearances.** A color that carries semantics —
   destructive red, a status indicator — keeps its meaning in both, which
   constrains how far a derivation may move it. This is the rule behind the
   [comparison](./comparison.md#what-follows-the-system-and-what-must-not)'s
   distinction between chrome that should follow the system and semantics that
   must not.

## The missing accent

iOS has **no user-facing accent color setting**. macOS does
([`NSColor.controlAccentColor`](./macos.md)), Windows does, GNOME and KDE do,
Android does via wallpaper extraction — iOS does not. `UIView.tintColor` exists,
but it is the _app's_ choice propagated down the hierarchy, not the user's.

This is a genuine finding rather than an omission in the research: a
cross-platform appearance abstraction must model accent as **optional**, and the
`has_accent_colors`-style capability flag that [libadwaita](./libadwaita.md)
uses is exactly the mechanism. An abstraction that assumes an accent always
exists has to invent one on iOS, and inventing one means picking a brand color —
which is the app's decision, made in the wrong layer.

## Reachability from a non-UIKit application

Poor, and unavoidably so. Trait collections are UIKit objects; there is no
`defaults`-style file to read and no daemon to query. A renderer that draws its
own pixels — which is what [`hue`](../../specs/hue/index.md) does on every
platform — must be **handed** the appearance by whatever thin UIKit shim owns the
`CAMetalLayer`/`UIView`, at launch and again on every trait change.

For Sparkles, whose iOS target is planned rather than shipped, that shapes the
port: the appearance seam has to be an input the host pushes in, not something the
core pulls. The [proposal](./sparkles-proposal.md) makes that the default shape
for every backend precisely so the iOS case is not special.

## Traps

| Trap                                                 | Consequence                                                      |
| ---------------------------------------------------- | ---------------------------------------------------------------- |
| Reading `userInterfaceStyle` once at launch          | correct until the user changes it, or auto dark kicks in at dusk |
| Treating `.unspecified` as `.light`                  | inherits nothing; ignores the app's own default                  |
| Overriding `traitCollectionDidChange` on iOS 17+     | deprecated; misses the type-safe path and wakes every view       |
| Hard-coding a "dark" palette and switching wholesale | ignores `accessibilityContrast` and `userInterfaceLevel`         |
| Assuming an accent color exists                      | there is none on iOS; an abstraction must make it optional       |
| Resolving a dynamic color and caching the result     | the cached value is stale in the other appearance                |

## Strengths

- Appearance is hierarchical and overridable, which makes per-view exceptions and
  off-screen rendering in the _other_ appearance trivial.
- The system ships a complete semantic palette, so a conforming app needs no
  color code at all.
- Contrast, bold text and elevation ride the same mechanism as light/dark, so
  supporting one supports all.
- Change delivery is type-safe and scoped since iOS 17.

## Weaknesses

- Entirely UIKit-internal: unreachable from a self-rendering or cross-platform
  core without a shim.
- No accent color, unlike every other GUI platform surveyed.
- The semantic palette is Apple's; an app with its own visual identity gets less
  from it than a stock-controls app does.
- `traitCollectionDidChange` deprecation means two code paths for a while.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                        | Trade-off                                                            |
| ---------------------------------------------------- | ---------------------------------------------------------------- | -------------------------------------------------------------------- |
| Appearance as an inherited view trait                | per-subtree overrides; off-screen rendering in either appearance | unreachable outside the view hierarchy; no process-level query       |
| Colors as resolver objects, not values               | one object is correct in every appearance simultaneously         | a resolved value must never be cached, which is easy to get wrong    |
| Ship a complete semantic palette                     | conforming apps need zero color code                             | apps with their own identity still author everything themselves      |
| Elevation as a colour input (`userInterfaceLevel`)   | shadows do not read on dark surfaces                             | one more axis to honour; no equivalent on other platforms to port to |
| No user accent color                                 | keeps app identity under the developer's control                 | cross-platform abstractions must model accent as optional            |
| Replace `traitCollectionDidChange` with registration | avoids waking every view for every trait                         | deprecation churn; two paths until the floor moves to iOS 17         |

## Sources

- [`UITraitCollection` — UIKit reference][traits]
- [Human Interface Guidelines — Dark Mode][hig]
- [`UIColor` — UI element colors][uicolor]
- [Adopting Live Text and trait changes — `registerForTraitChanges`][regtraits]

<!-- References -->

[hig]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[regtraits]: https://developer.apple.com/documentation/uikit/uitraitchangeobservable/registerfortraitchanges(_:target:action:)
[traits]: https://developer.apple.com/documentation/uikit/uitraitcollection
[uicolor]: https://developer.apple.com/documentation/uikit/uicolor
