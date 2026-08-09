# Platform UI Guidelines

A breadth-first survey of how eight platforms let an application **follow the
user's OS-level appearance preferences** — not merely light and dark, but the
accent color, the contrast level, forced colors and reduced motion — and of what
an application must do with those preferences once it has them.

The motivating problem is concrete. [`hue`](../../specs/hue/index.md) bases every
color it draws on a single [`sparkles.ui.theme.Theme`](../../specs/ui/theme.md)
value, chosen by name and then fixed for the life of the process. A user in dark
mode gets whatever the default theme is; a user who switches to light mode at
dawn gets no change at all until they restart. The survey asks what the platforms
offer, what the field's consensus is, and what it would take to **derive** that
`Theme` from the OS instead of authoring it.

This survey answers seven questions:

1. **What is the shared vocabulary** — the appearance triple, semantic vs literal
   color, tone, quantized accents, forced colors, push vs poll, and why
   capability flags beat a support bit? See [concepts][concepts].
2. **What each platform exposes, and how** — the preference surface, the query
   API, the change-notification mechanism, and whether a palette comes with it.
   See the [master catalog](#master-catalog).
3. **What a self-rendering application can actually reach** — with no native
   toolkit linked, which is the position `sparkles:ui` is in on every target. See
   [comparison § Dimension 6][cmp-reach].
4. **How to turn three scalars into a palette** — tone placement, the tone-delta
   rule (measured, not assumed), and per-role accent resolution. See
   [color-derivation][derive].
5. **How somebody already solved this** — libadwaita follows the native
   appearance on six platforms behind one interface. See [libadwaita][adw].
6. **Where the field agrees and where it genuinely forks**, and where Sparkles
   stands against it today. See [comparison][cmp] and its
   [delta table][cmp-delta].
7. **What Sparkles should build** — a milestoned plan for `sparkles:appearance`
   and the `Theme` derivation. See [the proposal][proposal].

> [!NOTE]
> **Scope.** This tree is about _following OS preferences_, not about window-system
> integration generally — for decorations, scaling, input translation and the
> event loop, see [window-system-integration](../window-system-integration/index.md),
> whose [os-apis](../window-system-integration/os-apis/index.md) subtree covers the
> same platforms from the windowing side. Where this survey needs a platform's
> windowing behaviour it links there rather than restating it.

**Last reviewed:** August 9, 2026

---

## Master Catalog

One row per surveyed subject; **the name links to its deep-dive**. "Ships a
palette" means the platform hands the application resolved colors rather than
preferences it must derive from. "Reachable" is the survey's key column for
Sparkles: whether a self-rendering application can read the preference **without
linking the platform's UI toolkit**.

| Subject                             | Category            | Scheme                | Accent            | Contrast      |  Push  | Ships a palette      | Reachable without the toolkit  |
| ----------------------------------- | ------------------- | --------------------- | ----------------- | ------------- | :----: | -------------------- | ------------------------------ |
| **[iOS / iPadOS][ios]**             | mobile OS           | 3-valued              | **none**          | 2-valued      |   ✓    | ✓ semantic           | **no** — UIKit traits only     |
| **[Android][android]**              | mobile OS           | 3-valued              | wallpaper-seeded  | **3-valued**  |   ✓    | ✓ generated (5 × 13) | scheme only; rest needs JNI    |
| **[GNOME][gnome]**                  | Linux desktop       | 3-valued              | 9 named           | 2-valued      |   ✓    | —                    | **yes** — D-Bus portal         |
| **[KDE Plasma][kde]**               | Linux desktop       | 3-valued              | free RGB          | native only   |   ✓    | ✓ 8 role sets        | **yes** — INI + portal         |
| **[Windows][windows]**              | desktop OS          | 2-valued              | free RGB + ladder | forced colors |   ✓    | —                    | partly — accent needs WinRT    |
| **[macOS][macos]**                  | desktop OS          | 2-valued              | 8 indexed         | 2-valued      | ✓ racy | ✓ semantic           | **yes** — global defaults      |
| **[Terminal emulators][terminal]**  | pty protocol        | 2-valued              | **none**          | **none**      |   ✓    | the 16-color palette | **yes** — two escape sequences |
| **[The web][web]**                  | sandboxed runtime   | 2-valued              | **none**          | **4-valued**  |   ✓    | —                    | n/a — it _is_ the sandbox      |
| **[libadwaita `AdwSettings`][adw]** | prior art (toolkit) | abstracts 6 platforms | quantized to 9    | boolean       |   ✓    | —                    | (the reference implementation) |

Two facts frame the whole survey and are visible in the table. **Light/dark is
universal and solved; nothing else is** — accent is missing on three platforms,
contrast on two, and no two platforms agree on what "contrast" means. And
**push notification is universal**, including over a pty — which makes
re-theming at runtime, not reading at startup, the real requirement.

## Library & platform deep-dives

Every deep-dive applies the same seven-dimension spine — preference surface,
reading it, change notification, what the platform derives for you, what the
vendor's guidelines require, reachability from a non-native application, and
traps — so the pages can be read against each other. Where a dimension does not
apply, the _absence_ is recorded as a finding (the terminal has no accent; iOS has
no accent; KDE exposes no contrast neutrally).

| Category             | Subjects                                                                       |
| -------------------- | ------------------------------------------------------------------------------ |
| **Mobile**           | [iOS / iPadOS][ios] · [Android (Material You)][android]                        |
| **Linux desktop**    | [GNOME (portal)][gnome] · [KDE Plasma][kde]                                    |
| **Desktop OS**       | [Windows][windows] · [macOS][macos]                                            |
| **Non-GUI surfaces** | [Terminal emulators][terminal] · [The web][web]                                |
| **Prior art**        | [libadwaita `AdwSettings`][adw]                                                |
| **Applying it**      | [Color derivation][derive] · [Comparison][cmp] · [Sparkles proposal][proposal] |

## Taxonomy

### By what the platform hands you

| The platform gives you      | Subjects                                                             | The application must…                                  |
| --------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------ |
| A complete semantic palette | [iOS][ios], [macOS][macos]                                           | name roles; write no color code                        |
| A generated tonal palette   | [Android][android]                                                   | name tokens; the wallpaper drives the rest             |
| A full role-scoped palette  | [KDE][kde]                                                           | map its roles onto its own                             |
| Scalars only                | [GNOME][gnome], [Windows][windows], [terminal][terminal], [web][web] | **derive everything** — see [color-derivation][derive] |

### By how the scheme is answered

| Mechanism                 | Subjects                                                                                                                 |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| A semantic value          | [iOS][ios], [Android][android], [GNOME][gnome], [KDE][kde], [macOS][macos], [terminal][terminal] (mode 2031), [web][web] |
| **Inferred from a color** | [Windows][windows] (documented!), [terminal][terminal] (OSC 11 fallback)                                                 |

### By accent model

| Model                    | Subjects                                                      |
| ------------------------ | ------------------------------------------------------------- |
| Free RGB                 | [KDE][kde], [Windows][windows], [Android][android]            |
| Quantized to a named set | [GNOME][gnome] (9), [macOS][macos] (8), [libadwaita][adw] (9) |
| Not exposed              | [iOS][ios], [terminal][terminal], [web][web]                  |

## Milestones

When each capability became available to applications.

| Year      | Milestone                                                                                                  |
| --------- | ---------------------------------------------------------------------------------------------------------- |
| 2018      | macOS Mojave ships Dark Mode; `NSAppearance` gains `darkAqua`                                              |
| 2019      | iOS 13 adds `UITraitCollection.userInterfaceStyle`; Android 10 adds system-wide dark theme                 |
| 2019      | `prefers-color-scheme` reaches all major browsers (widely available Jan 2020)                              |
| 2019      | Windows 10 exposes dark mode to Win32 via `UISettings`; `DWMWA_USE_IMMERSIVE_DARK_MODE` 19→20              |
| 2021      | Android 12 ships Material You — wallpaper-seeded tonal palettes as `android.R.color.system_*`              |
| 2021      | `org.freedesktop.appearance` `color-scheme` lands in xdg-desktop-portal                                    |
| 2023      | xdg-desktop-portal 1.17.1 adds `accent-color`                                                              |
| 2023      | Android 14 adds a three-step contrast level (`UiModeManager.getContrast()`)                                |
| 2023      | iOS 17 replaces `traitCollectionDidChange` with `registerForTraitChanges`                                  |
| 2024      | libadwaita 1.6 adds accent colors, with native macOS and Windows backends                                  |
| 2024      | `light-dark()` reaches baseline availability in CSS                                                        |
| 2024–2025 | **DEC mode 2031** spreads across terminals — Contour, Ghostty 1.0, foot 1.23, kitty, iTerm2, VTE, tmux 3.6 |

The bottom row is the newest and, for `hue`, the most consequential: terminal
applications only recently gained the semantic answer plus change notification
that GUI applications have had since 2018.

## Runnable examples

Four programs the [`ci` helper](../../guidelines/AGENTS.md#run-the-full-ci-check-locally)
compiles and runs on every pass, so the behaviour these pages describe cannot
rot silently. Each prints `SKIP:` and exits 0 where the host lacks the capability.

| Example                                                   | Backs                      | What it proves                                                                                      |
| --------------------------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------------- |
| [`color-derivation/examples/derive-palette.d`][ex-derive] | [color-derivation][derive] | the tone-delta rule **misses** its claimed 4.5:1 by 0.022; derived palettes clear WCAG AA           |
| [`gnome/examples/portal-appearance.d`][ex-portal]         | [GNOME][gnome]             | GNOME's accent is one of libadwaita's nine; `reduced-motion` answers `NotFound` on a live v2 portal |
| [`kde/examples/kdeglobals-appearance.d`][ex-kde]          | [KDE][kde]                 | `Colors:View` and `Colors:Window` genuinely differ (`#141618` vs `#202326` in Breeze Dark)          |
| [`terminal/examples/color-scheme-probe.d`][ex-term]       | [terminal][terminal]       | mode 2031 and OSC 11 round-trip, and a silent terminal is handled by timeout, not a hang            |

## Suggested reading paths

**"I want the conclusions."**
[comparison][cmp] → its [delta table][cmp-delta] → [the proposal][proposal].

**"I'm implementing the Sparkles feature this informs."**
[concepts][concepts] → [libadwaita][adw] (the abstraction to copy) →
[color-derivation][derive] (the math) → [terminal][terminal] (the first backend) →
[the proposal][proposal].

**"I'm porting `hue` to a specific platform."**
[concepts][concepts] → that platform's deep-dive →
[comparison § what follows the system][cmp-policy] → the relevant
[proposal milestone][proposal].

**"I only care about the terminal."**
[terminal][terminal] → [`color-scheme-probe.d`][ex-term] →
[proposal § P1][proposal].

**"I want to understand the color math."**
[concepts § tone][concepts-tone] → [color-derivation][derive] →
[`derive-palette.d`][ex-derive].

## Sources

Primary sources are cited per deep-dive; each page's `Sources` section is its
provenance. The recurring ones:

- [XDG Desktop Portal — `org.freedesktop.portal.Settings`][portal]
- libadwaita `src/adw-settings*.c`, pinned at [`01d51e39`][adwtree]
- [Material Design 3][m3] and [AOSP dynamic color][aosp]
- [Apple HIG — Dark Mode][hig] and [`UITraitCollection`][traits]
- [Support Dark and Light themes in Win32 apps][mslearn]
- [Color scheme reporting — DEC mode 2031][vtdn]
- [MDN — CSS user-preference media features][mdn]

Live captures on a GNOME session with portal Settings v2, and pty-harness
captures of a mode-2031 terminal, were taken in August 2026 and are reproduced by
the examples above.

<!-- References -->

[adw]: ./libadwaita.md
[adwtree]: https://gitlab.gnome.org/GNOME/libadwaita/-/tree/01d51e393fa613d5c1fd520fbcde79d68db21877/src
[android]: ./android.md
[aosp]: https://source.android.com/docs/core/display/dynamic-color
[cmp]: ./comparison.md
[cmp-delta]: ./comparison.md#delta-table--where-sparkles-stands-today
[cmp-policy]: ./comparison.md#what-follows-the-system-and-what-must-not
[cmp-reach]: ./comparison.md#dimension-6--reachability-from-a-self-rendering-application
[concepts]: ./concepts.md
[concepts-tone]: ./concepts.md#tone-and-the-tonal-palette
[derive]: ./color-derivation/index.md
[ex-derive]: ./color-derivation/examples/derive-palette.d
[ex-kde]: ./kde/examples/kdeglobals-appearance.d
[ex-portal]: ./gnome/examples/portal-appearance.d
[ex-term]: ./terminal/examples/color-scheme-probe.d
[gnome]: ./gnome/index.md
[hig]: https://developer.apple.com/design/human-interface-guidelines/dark-mode
[ios]: ./ios.md
[kde]: ./kde.md
[m3]: https://m3.material.io/styles/color/system/how-the-system-works
[macos]: ./macos.md
[mdn]: https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-color-scheme
[mslearn]: https://learn.microsoft.com/en-us/windows/apps/desktop/modernize/ui/apply-windows-themes
[portal]: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Settings.html
[proposal]: ./sparkles-proposal.md
[terminal]: ./terminal/index.md
[traits]: https://developer.apple.com/documentation/uikit/uitraitcollection
[vtdn]: https://vtdn.dev/docs/decset/mode2031-color-scheme/
[web]: ./web.md
[windows]: ./windows.md
