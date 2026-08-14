# Anchored overlays

An **anchored overlay** is any surface whose position is derived from something else on
screen: a tooltip beside a button, a menu under a menubar item, a submenu beside its parent
row, a completion list next to a caret, a hover card beside a link, a teaching tip beside a
feature. Thirty-eight systems were read at pinned revisions to answer one question — **how
much of that problem is surface-independent?** — because `sparkles:ui` must solve it once, in
integer cells, for a GPU window, a terminal cell grid, a script-free HTML page and an Android
`NativeActivity`, none of which agree on whether hover exists, whether a key release arrives,
whether there is a frame clock, or whether there is an OS window at all.

The corpus was chosen to make the surface question falsifiable rather than assumed. It spans
a wire protocol whose placement runs in another process ([`xdg_positioner`][xdg]), a browser
engine ([Blink][blink]), ten desktop toolkits, three mobile stacks, ten headless web
libraries, and ten terminal systems that have no compositor, no hover and no timers — plus
the one historical subject ([Turbo Vision][turbo-vision]) that already built the whole
vocabulary inside a character grid in the early 1990s. Where the field's answers diverge, the
divergence is reported as a fork rather than resolved by preference; where a first-pass claim
did not survive verification, the narrower wording is what appears in the tree.

## This survey answers ten questions

1. **[What is the minimal surface-independent core?][q1]** — six values and pure functions
   over them, with a short, explicit list of what is irreducibly surface-specific.
   Vocabulary in [`concepts.md`][concepts].
2. **[Can placement be a pure function of Regular values?][q2]** — yes, with two amendments
   the verification pass forced; demonstrated by [`place-reference.d`](./examples/place-reference.d).
3. **[What does the cell grid actually cost?][q3]** — which behaviours degrade gracefully,
   which degrade badly, and which are simply unrepresentable in whole cells.
   Per-target constraints in [`sparkles-baseline.md`][baseline].
4. **[What replaces hover?][q4]** — on targets with no pointer, and on targets where hover
   exists but [warm-up][concepts] has no clock. Timing behaviours catalogued in
   [`features-people-forget.md`][forget]; the machine is [`tooltip-timing.d`](./examples/tooltip-timing.d).
5. **[What does a script-free HTML target get?][q5]** — what survives when the only runtime
   is the cascade, read against [CSS anchor positioning][css-anchor] and the
   [Popover API][popover-api].
6. **[How much of Floating UI will the browser absorb?][q6]** — which of the
   [middleware set][floating-ui] the platform has already taken, and which parts it
   structurally cannot.
7. **[Overlay tree, or overlay list?][q7]** — why the tree must be a _query_ over a flat
   ordered list, not a structure. Layering vocabulary in [`concepts.md`][concepts-layering].
8. **[Where does adaptive presentation belong?][q8]** — popover-versus-sheet-versus-dialog
   as a host decision above the primitive, on [Apple's][apple] and [WinUI's][winui] evidence.
9. **[What must the API not foreclose?][q9]** — the decisions that are cheap now and
   unaffordable later, which is what [`proposal.md`][proposal] is built around.
10. **[What should Sparkles build?][q10]** — the final synthesis, taken up as a milestoned
    plan in [`proposal.md`][proposal] against the delta table in
    [`sparkles-baseline.md`][baseline].

**Last reviewed:** August 14, 2026

> [!IMPORTANT]
> Every claim in this tree is tied to a primary source at a **pinned revision**, recorded in
> the [revision ledger](#revision-ledger) below. A citation is the upstream URL at that SHA —
> so any statement here can be re-checked against exactly the code that produced it, years
> from now. Load-bearing statements in [`comparison.md`][comparison] additionally passed a
> two-lens adversarial verification pass; statements that are analysis rather than
> observation are marked **INFERENCE** there.

---

## Master catalog

Thirty-eight subjects. **Surface model** is the single most consequential column for this
toolkit: `OS popup` means the overlay is a separate window the compositor or window manager
owns; `in-canvas` means it is painted into the same surface as everything else — the
constraint `sparkles:ui` works under; `both` means one declaration resolves to either at
runtime, which is the interesting case, because it proves the two share a core.

| Subject                                      | Category                          | Where the behaviour lives                                                                                                 | Surface model                                                                                               | Deep-dive                                        |
| -------------------------------------------- | --------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| [Floating UI][floating-ui]                   | Web / headless positioning        | A ~100-line kernel folding an ordered `middleware` array over one tuple, behind a three-method `Platform`                 | in-canvas (coordinates only; the top layer is detected, never entered)                                      | [`floating-ui.md`](./floating-ui.md)             |
| [Radix Primitives][radix]                    | Web / headless behaviour          | Four separately-consumable mechanisms: `Popper`, `DismissableLayer`, `FocusScope`, `Portal`                               | in-canvas (React portal into `document.body`; no top layer)                                                 | [`radix.md`](./radix.md)                         |
| [Base UI][base-ui]                           | Web / headless behaviour          | One ~800-line positioning hook plus one reason-tagged popup store shared by ten components                                | in-canvas (DOM only; no `showPopover`, no `dialog`)                                                         | [`base-ui.md`](./base-ui.md)                     |
| [Ariakit][ariakit]                           | Web / headless behaviour          | A single-inheritance chain of stores and prop-transformer hooks; a 96-line polygon test in-house                          | in-canvas (React portal into `document.body`)                                                               | [`ariakit.md`](./ariakit.md)                     |
| [Zag.js][zag]                                | Web / state machines              | A statechart as inert data plus one single-purpose package per concern (`popper`, `dismissable`)                          | in-canvas (content portalled to `document.body`)                                                            | [`zag.md`](./zag.md)                             |
| [Headless UI][headlessui]                    | Web / headless behaviour          | A pure-reducer `Machine` plus a forty-line stack machine; no positioner and no arrow, deliberately                        | in-canvas (one userland portal root, an explicitly non-native "top layer")                                  | [`headlessui.md`](./headlessui.md)               |
| [Floating Vue][floating-vue]                 | Web / framework binding           | One 1187-line `Popper.ts`; tooltip, dropdown and menu are nine-line files differing by a theme string                     | in-canvas (one container, one flat `z-index: 10000`)                                                        | [`floating-vue.md`](./floating-vue.md)           |
| [Tippy.js][tippy]                            | Web / imperative controller       | 1145 lines of _when_ — timing, intent and lifecycle — configuring Popper 2 for the _where_                                | in-canvas (a `div` in the same document; `z-index: 9999`)                                                   | [`tippy.md`](./tippy.md)                         |
| [Angular CDK Overlay][angular-cdk]           | Web / enterprise manager          | `OverlayRef` + `FlexibleConnectedPositionStrategy` + a scroll strategy + one document-level key/pointer stack             | both — legacy `.cdk-overlay-container` div; since v22 the browser top layer by feature test                 | [`angular-cdk.md`](./angular-cdk.md)             |
| [React Aria][react-aria]                     | Web / headless behaviour          | A hand-written ~850-line `calculatePosition` plus a document-global tooltip warm-up machine                               | in-canvas (DOM portal into `document.body`)                                                                 | [`react-aria.md`](./react-aria.md)               |
| [HTML Popover API][popover-api]              | Web platform                      | Spec algorithms for stacking, cascade dismissal, focus scope and re-entrancy — and no geometry at all                     | both — the top layer is an in-document ordered set; the one OS surface is `select`'s native picker          | [`popover-api.md`](./popover-api.md)             |
| [CSS Anchor Positioning][css-anchor]         | Web platform                      | The cascade: `anchor()`, `anchor-name`, `position-try-fallbacks`, and an incumbent-skip hysteresis rule                   | in-canvas (the UA top layer is a paint-order set, not an OS popup)                                          | [`css-anchor.md`](./css-anchor.md)               |
| [Chromium / Blink][blink]                    | Web platform (impl)               | Two systems sharing one pointer: `popover` owns lifecycle, anchor positioning owns geometry                               | in-canvas (`Document::top_layer_elements_`, a per-document vector)                                          | [`blink.md`](./blink.md)                         |
| [WAI-ARIA APG][aria-apg]                     | Web platform / a11y               | Patterns and six reference implementations: roles, focus ownership, dismissal, modality — no placement                    | in-canvas (`position: absolute` inside the trigger's containing block)                                      | [`aria-apg.md`](./aria-apg.md)                   |
| [Qt Quick Controls][qt-quick]                | Native desktop (Qt)               | One `QQuickPopup` base class: a declaration plus a **permission set** (`ClosePolicy`, six placement booleans)             | both                                                                                                        | [`qt-quick-controls.md`](./qt-quick-controls.md) |
| [Qt Widgets][qt-widgets]                     | Native desktop (Qt)               | One window flag (`Qt::Popup`) buying the stack, the grab, event re-routing and modality exemption                         | OS popup                                                                                                    | [`qt-widgets.md`](./qt-widgets.md)               |
| [GTK4][gtk4]                                 | Native desktop (GTK)              | `GdkPopupLayout` — a ten-scalar value — plus a swappable solver (compositor, GDK arithmetic, or Android)                  | both — a compositor surface everywhere except the Android backend, which clips to the parent                | [`gtk4.md`](./gtk4.md)                           |
| [WPF][wpf]                                   | Native desktop (Windows)          | Candidate **generation plus scoring** in `PlacementMode`/`CustomPopupPlacement`, one `HwndSource` per popup               | OS popup (`WS_POPUP` + `WS_EX_TOPMOST` + `WS_EX_NOACTIVATE`)                                                | [`wpf.md`](./wpf.md)                             |
| [WinUI][winui]                               | Native desktop (Windows)          | Two stacks sharing a portal and a dismissal layer: `CPopup`/`FlyoutBase`, plus `TeachingTip`'s forked 14-candidate solver | both                                                                                                        | [`winui.md`](./winui.md)                         |
| [Uno Platform][uno]                          | Native desktop/web (.NET)         | Every open popup is a full-window `Panel` under one in-app `PopupRoot`; placement is managed `Rect` arithmetic            | in-canvas (plus one Android full-screen native window contributing no placement)                            | [`uno.md`](./uno.md)                             |
| [Avalonia][avalonia]                         | Native desktop (.NET)             | `ManagedPopupPositioner` — a ~130-line solver modelled on `xdg_positioner` — behind two adapters                          | both — the same solver serves a `PopupRoot` window and an in-window `OverlayPopupHost`                      | [`avalonia.md`](./avalonia.md)                   |
| [Slint][slint]                               | Native desktop (Rust)             | One point anchor, one clamp-and-shrink pass, a flat stack of extra item trees; policy pushed into `.slint`                | both — an in-window `ChildWindow`, a real OS child window, or a native OS menu                              | [`slint.md`](./slint.md)                         |
| [Zed / GPUI][gpui]                           | Native desktop (Rust GPU)         | A flat per-frame vector of deferred paint records; `anchored()` elements; no top layer, no grab                           | in-canvas (one OS window, one GPU surface)                                                                  | [`gpui.md`](./gpui.md)                           |
| [Dear ImGui][imgui]                          | Immediate-mode GUI                | Two flat POD arrays, one ~70-line integer placement function, one draw-layer bit                                          | in-canvas (every popup is an ordinary `ImGuiWindow` in the same `ImDrawData`)                               | [`imgui.md`](./imgui.md)                         |
| [Jetpack Compose][compose]                   | Mobile / adaptive (Android)       | `PopupPositionProvider.calculatePosition(anchorBounds, windowSize, layoutDirection, contentSize)` → `IntOffset`           | OS popup (a real `WindowManager` child window per popup)                                                    | [`compose.md`](./compose.md)                     |
| [Flutter][flutter]                           | Mobile / adaptive                 | `OverlayPortal` / `RawMenuAnchor` / `PopupRoute` in one render tree; `positionDependentBox` for tooltips                  | in-canvas (one render tree, one surface; `SystemContextMenu` on iOS is the one escape hatch)                | [`flutter.md`](./flutter.md)                     |
| [Apple (UIKit/AppKit/SwiftUI/TipKit)][apple] | Mobile & desktop                  | Nine overlapping primitives across four frameworks, sharing a content model but never an anchor or a policy               | both — `NSPopover`/`NSMenu` are OS surfaces; `UIPopoverPresentationController` is an in-window presentation | [`apple.md`](./apple.md)                         |
| [Wayland `xdg_positioner`][xdg]              | Protocol-level algebra            | A ~40-byte POD of plain `int`s solved **out of process** by the compositor                                                | OS popup (a compositor-managed `wl_surface` with the `xdg_popup` role)                                      | [`xdg-positioner.md`](./xdg-positioner.md)       |
| [Helix][helix]                               | Terminal / cell grid              | One ~60-line integer-cell function re-run from scratch every frame; a flat `Vec` of self-clipping painters                | in-canvas                                                                                                   | [`helix.md`](./helix.md)                         |
| [Neovim floats][neovim]                      | Terminal / cell grid              | `nvim_open_win`: an anchor descriptor resolved to one cell, clamped; `ui_compositor` merges by `zindex`                   | both — a float is an in-canvas cell rectangle, but opaque to the plugin that opened it                      | [`neovim-floats.md`](./neovim-floats.md)         |
| [Notcurses][notcurses]                       | Terminal / cell grid              | The `ncplane` — an independently owned cell buffer in a totally ordered `ncpile`                                          | in-canvas (one framebuffer; the terminal is the only surface)                                               | [`notcurses.md`](./notcurses.md)                 |
| [nui.nvim][nui]                              | Terminal / cell grid              | A declarative geometry vocabulary — `{relative, position, size, anchor, border}` — normalised by one function             | in-canvas (Neovim floats; no collision engine at all)                                                       | [`nui.md`](./nui.md)                             |
| [nvim-cmp / blink.cmp][nvim-completion]      | Terminal / cell grid              | Menu-beside-a-text-range, then docs-beside-the-menu, on a pure integer grid with no pointer                               | both — floats are in-canvas cells, but opaque rect+`zindex` handles to the plugin                           | [`nvim-completion.md`](./nvim-completion.md)     |
| [Ratatui][ratatui]                           | Terminal / cell grid              | No overlay primitive: a ten-line `Clear` widget, a `Rect` with `clamp`/`intersection`, and later-call-wins                | in-canvas                                                                                                   | [`ratatui.md`](./ratatui.md)                     |
| [Textual][textual]                           | Terminal / cell grid              | Three CSS rules taught to the ordinary layout engine — `layers`/`layer`, `overlay`, `constrain`                           | in-canvas                                                                                                   | [`textual.md`](./textual.md)                     |
| [tmux][tmux]                                 | Terminal / cell grid              | `display-popup` / `display-menu` painted into the grid tmux already owns; three generations side by side                  | in-canvas                                                                                                   | [`tmux-popup.md`](./tmux-popup.md)               |
| [Turbo Vision][turbo-vision]                 | Terminal / cell grid (historical) | A complete windowing system in `TScreenCell`s: `TView`/`TGroup`, menus, submenus, modals, drop shadows                    | in-canvas (the console is the only surface)                                                                 | [`turbo-vision.md`](./turbo-vision.md)           |
| [Emacs posframe + company][emacs-posframe]   | Terminal / GUI hybrid             | A _poshandler_: a named pure function of a flat measured record; plus a second, surface-free cell renderer                | both — a child frame in GUI Emacs, an overlay-based pseudo-tooltip in a terminal                            | [`emacs-posframe.md`](./emacs-posframe.md)       |

Beyond the deep-dives, five synthesis documents:

| Document                              | What it is                                                                                                                                                                                                                               |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`concepts.md`][concepts]             | The shared vocabulary — anchor, placement, constraint adjustment, boundary, top layer, warm-up, safe polygon, grab, modality, geometry metadata — each defined once, with canonical spellings and an index of which subject exercises it |
| [`comparison.md`][comparison]         | The capstone: twelve capabilities × thirty-eight subjects, sixteen dimensions with a best-in-class per dimension, the consensus, the genuine forks, and the ten questions                                                                |
| [`features-people-forget.md`][forget] | The behaviours nobody remembers until they ship — anchoring, collision, timing, pointer intent, dismissal, focus, layering, accessibility, animation, degradation                                                                        |
| [`sparkles-baseline.md`][baseline]    | What `sparkles:ui` can express today: `WidgetKind.popup`, the `Palette` popup metrics, `clampOrigin`, `HoverPopup`, `DCK5`, the open defects, the per-target constraint list, and the delta table                                        |
| [`proposal.md`][proposal]             | The milestoned plan: the primitive architecture, the bands-versus-precedence resolution, an API straw man, the state machines, the geometry pipeline, the adapter surface, and the open questions                                        |

And three runnable examples that CI compiles and runs, so the conclusions cannot rot:

| Example                                               | The claim it pins                                                                                                   |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| [`place-reference.d`](./examples/place-reference.d)   | `place()` as a `@safe pure nothrow @nogc` function over Regular values returning a **decision record**, not a point |
| [`tooltip-timing.d`](./examples/tooltip-timing.d)     | The warm-up / cool-down machine as one shared arbiter holding two integers, composed from the existing `Timeline`   |
| [`dismissal-policy.d`](./examples/dismissal-policy.d) | Dismissal as one value: a policy flags word ANDed with a router-offered cause                                       |

---

## Revision ledger

Every subject, the upstream repository, and the exact revision it was read at. This is what
makes the tree re-verifiable: a claim on any page can be checked against precisely this code.
SHAs are given in full and are never abbreviated.

| Subject                                      | Repository                                                                  | Revision read                                                                                                                                                                                               | Date read  |
| -------------------------------------------- | --------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- |
| [Dear ImGui][imgui]                          | [`ocornut/imgui`][r-imgui]                                                  | `46d39d56febc2a00bdd2270dc88c8a13f2a0441a`                                                                                                                                                                  | 2026-08-11 |
| [Apple (UIKit/AppKit/SwiftUI/TipKit)][apple] | [`developer.apple.com`][r-apple]                                            | _docs-only — no public source_ (reference pages as published August 2026)                                                                                                                                   | 2026-08-11 |
| [Jetpack Compose][compose]                   | [`androidx/androidx`][r-compose]                                            | `268d841a45644cadf438fc335c793869728449ec`                                                                                                                                                                  | 2026-08-11 |
| [Flutter][flutter]                           | [`flutter/flutter`][r-flutter]                                              | `feab40b83b8d1954106e83bb1d7b52265a41cb45`                                                                                                                                                                  | 2026-08-11 |
| [Avalonia][avalonia]                         | [`AvaloniaUI/Avalonia`][r-avalonia]                                         | `aee3f68551b0ac4417e32996a6627f34462edbc3`                                                                                                                                                                  | 2026-08-11 |
| [GTK4][gtk4]                                 | [`GNOME/gtk`][r-gtk4]                                                       | `817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671` (GTK 4.23.1)                                                                                                                                                     | 2026-08-11 |
| [Qt Quick Controls][qt-quick]                | [`qt/qtdeclarative`][r-qtdeclarative]                                       | `ffc46f28ab21b6666dbea46c81cf2726ce682419`                                                                                                                                                                  | 2026-08-11 |
| [Qt Widgets][qt-widgets]                     | [`qt/qtbase`][r-qtbase]                                                     | `d0787745aa43e5baf49de876f917946df6aceca5`                                                                                                                                                                  | 2026-08-11 |
| [Zed / GPUI][gpui]                           | [`zed-industries/zed`][r-zed]                                               | `d71f1461045c098dc6ca6b1b5adcf1b8949722e8`                                                                                                                                                                  | 2026-08-11 |
| [Slint][slint]                               | [`slint-ui/slint`][r-slint]                                                 | `24318cebc2b3feed4f7187e237915f52715ce285`                                                                                                                                                                  | 2026-08-11 |
| [WPF][wpf]                                   | [`dotnet/wpf`][r-wpf]                                                       | `99caccf23145777f910711b51961885bec783213`                                                                                                                                                                  | 2026-08-11 |
| [WinUI][winui]                               | [`microsoft/microsoft-ui-xaml`][r-winui]                                    | `29ebf098f70df518b57b754130bc94004be8c6bc` (`winui3/main`)                                                                                                                                                  | 2026-08-11 |
| [Uno Platform][uno]                          | [`unoplatform/uno`][r-uno]                                                  | `df5d18a850248cb8c2ccb34032b4ebeb54dc8283`                                                                                                                                                                  | 2026-08-11 |
| [Wayland `xdg_positioner`][xdg]              | [`wayland/wayland-protocols`][r-wayland]                                    | `afb614d5fcbd02d261a6ae91920aa91cf3915a8a` (wayland-protocols 1.49)                                                                                                                                         | 2026-08-11 |
| [Emacs posframe + company][emacs-posframe]   | [`tumashu/posframe`][r-posframe] + [`company-mode/company-mode`][r-company] | posframe `74c8c56131ed866db47ae4191364b72dd4852456` (v1.5.2, 2026-05-27); company-mode `1cc907ac9e46ae4209eb5a341131787e0c678406` (1.1.0, 2026-07-21)                                                       | 2026-08-11 |
| [Helix][helix]                               | [`helix-editor/helix`][r-helix]                                             | `14d6bc0febed9c692048271a8ae2362ac969c6e0`                                                                                                                                                                  | 2026-08-11 |
| [Neovim floats][neovim]                      | [`neovim/neovim`][r-neovim]                                                 | `2757f6eef92a99812d5ad12408d03592bd54f10c`                                                                                                                                                                  | 2026-08-11 |
| [Notcurses][notcurses]                       | [`dankamongmen/notcurses`][r-notcurses]                                     | `b26048eebc74d5d254717d3332fa484718f9efe6`                                                                                                                                                                  | 2026-08-11 |
| [Ratatui][ratatui]                           | [`ratatui/ratatui`][r-ratatui]                                              | `a2ca2df5688772baffb743b494761f4ec82b3174`                                                                                                                                                                  | 2026-08-11 |
| [Textual][textual]                           | [`Textualize/textual`][r-textual]                                           | `06dbeef4bb70fb718236aa418ed658ef4667a126`                                                                                                                                                                  | 2026-08-11 |
| [nui.nvim][nui]                              | [`MunifTanjim/nui.nvim`][r-nui]                                             | `de740991c12411b663994b2860f1a4fd0937c130`                                                                                                                                                                  | 2026-08-11 |
| [nvim-cmp / blink.cmp][nvim-completion]      | [`Saghen/blink.cmp`][r-blinkcmp] + [`hrsh7th/nvim-cmp`][r-nvimcmp]          | blink.cmp `8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526` (2026-08-08); nvim-cmp `2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3` (2026-07-10); corroborated against neovim `2757f6eef92a99812d5ad12408d03592bd54f10c` | 2026-08-11 |
| [tmux][tmux]                                 | [`tmux/tmux`][r-tmux]                                                       | `851c5a933d4838c32ad06c248b2ba975d106149c` (`next-3.8`)                                                                                                                                                     | 2026-08-11 |
| [Turbo Vision][turbo-vision]                 | [`magiblot/tvision`][r-tvision]                                             | `57b6f56b38e0ee75240a80a10ee0e11470c24693`                                                                                                                                                                  | 2026-08-11 |
| [Angular CDK Overlay][angular-cdk]           | [`angular/components`][r-angular]                                           | `f3e6276c969f33e527b616ef8bf7b0404685721d`                                                                                                                                                                  | 2026-08-11 |
| [Floating Vue][floating-vue]                 | [`Akryum/floating-vue`][r-floatingvue]                                      | `19857764c4f73dea7ed44a7d970adb968ee7ad90`                                                                                                                                                                  | 2026-08-11 |
| [Ariakit][ariakit]                           | [`ariakit/ariakit`][r-ariakit]                                              | `a0426ed547d95b84c9d53033053e51baeaca4aaa`                                                                                                                                                                  | 2026-08-11 |
| [Base UI][base-ui]                           | [`mui/base-ui`][r-baseui]                                                   | `adbd590484b26c1e68049348c57c70998ad667a7`                                                                                                                                                                  | 2026-08-11 |
| [Headless UI][headlessui]                    | [`tailwindlabs/headlessui`][r-headlessui]                                   | `eea57cf46fd6767ed1059012f7073b88eb159fba` (`@headlessui/react` 2.2.10)                                                                                                                                     | 2026-08-11 |
| [Radix Primitives][radix]                    | [`radix-ui/primitives`][r-radix]                                            | `f7ecd5ab16f5e1e820eb5786a1419a98a2d594ae`                                                                                                                                                                  | 2026-08-11 |
| [React Aria][react-aria]                     | [`adobe/react-spectrum`][r-reactspectrum]                                   | `7c0765468a1d161ab9ac88ca9f1b54d3603a275c`                                                                                                                                                                  | 2026-08-11 |
| [Floating UI][floating-ui]                   | [`floating-ui/floating-ui`][r-floatingui]                                   | `0eb8c985a6d7aadc3fbe621acfc3d7f1cdd6fdf1` (`@floating-ui/dom` 1.8.0)                                                                                                                                       | 2026-08-11 |
| [Tippy.js][tippy]                            | [`atomiks/tippyjs`][r-tippy]                                                | `ad85f6feb79cf6c5853c43bf1b2a50c4fa98e7a1` (v6.3.7)                                                                                                                                                         | 2026-08-11 |
| [Zag.js][zag]                                | [`chakra-ui/zag`][r-zag]                                                    | `eabc04440baa219723bc5d9a51d4e95c1deaf024`                                                                                                                                                                  | 2026-08-11 |
| [CSS Anchor Positioning][css-anchor]         | [`w3c/csswg-drafts`][r-csswg]                                               | `6dc15cc9cb15043840eacf081e89f5a666fa7889`                                                                                                                                                                  | 2026-08-11 |
| [HTML Popover API][popover-api]              | [`whatwg/html`][r-whatwg]                                                   | `ac0389a3aca0331055bf4bf23f509c2913e3f795`                                                                                                                                                                  | 2026-08-11 |
| [Chromium / Blink][blink]                    | [`chromium/src`][r-chromium]                                                | `b0e30a9973232cee28901ea5d6cd4de6ea9428aa`                                                                                                                                                                  | 2026-08-11 |
| [WAI-ARIA APG][aria-apg]                     | [`w3c/aria-practices`][r-apg]                                               | `7e4034b262bc0d25332e330d8a582aaf34113829`                                                                                                                                                                  | 2026-08-11 |

> [!NOTE]
> Two subjects are **specification** readings rather than implementation readings
> ([`xdg_positioner`][xdg] and [CSS Anchor Positioning][css-anchor]), and one
> ([Apple][apple]) is documentation-only because no source is published. Each page says so in
> its own header and marks every claim accordingly. [Blink][blink] was read through a sparse
> checkout, so its legacy `select` popup-menu path is outside the reading.

---

## Taxonomy

The same thirty-eight subjects, re-cut one axis at a time.

### By surface model

The axis that decides how much of the field transfers to a single-surface toolkit. The
`both` row is the load-bearing one: eleven subjects run the _same_ placement code on an OS
surface and on an in-window one, which is the strongest available evidence that placement is
surface-independent.

| Surface model                                         | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Count |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **OS popup** — a compositor/WM-owned surface          | [Compose][compose], [Qt Widgets][qt-widgets], [WPF][wpf], [`xdg_positioner`][xdg]                                                                                                                                                                                                                                                                                                                                                                                                     | 4     |
| **Both** — one declaration, either surface at runtime | [Angular CDK][angular-cdk], [Apple][apple], [Avalonia][avalonia], [GTK4][gtk4], [Neovim][neovim], [nvim-cmp / blink.cmp][nvim-completion], [posframe + company][emacs-posframe], [Popover API][popover-api], [Qt Quick Controls][qt-quick], [Slint][slint], [WinUI][winui]                                                                                                                                                                                                            | 11    |
| **In-canvas** — painted into the surface it shares    | [Ariakit][ariakit], [Base UI][base-ui], [Blink][blink], [CSS anchor][css-anchor], [Dear ImGui][imgui], [Floating UI][floating-ui], [Floating Vue][floating-vue], [Flutter][flutter], [GPUI][gpui], [Headless UI][headlessui], [Helix][helix], [Notcurses][notcurses], [nui.nvim][nui], [Radix][radix], [Ratatui][ratatui], [React Aria][react-aria], [Textual][textual], [Tippy][tippy], [tmux][tmux], [Turbo Vision][turbo-vision], [Uno][uno], [WAI-ARIA APG][aria-apg], [Zag][zag] | 23    |

### By placement algorithm family

Six families of candidate generation. Per [`comparison.md` § 2][c-placement], every one of
them is integer arithmetic over four rects and a small policy value — the families differ on
how candidates are _produced_, not on what they compute.

| Family                                                                            | Subjects                                                                                                                                                                                                                                                                                           | Count |
| --------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **Per-axis adjustment bits** — a flags mask; no candidate combinatorics           | [`xdg_positioner`][xdg], [GTK4][gtk4], [Avalonia][avalonia], [Qt Quick Controls][qt-quick], [Slint][slint], [Textual][textual]                                                                                                                                                                     | 6     |
| **Ordered candidate list** — a fallback array, first fit wins                     | [Floating UI][floating-ui], [Radix][radix], [Base UI][base-ui], [Ariakit][ariakit], [Zag][zag], [Floating Vue][floating-vue], [Tippy][tippy], [Headless UI][headlessui] (delegated), [CSS anchor][css-anchor], [Blink][blink], [WinUI][winui], [Uno][uno], [Compose][compose], [Dear ImGui][imgui] | 14    |
| **Scored candidates** — a real objective (visible area), with a total order       | [Angular CDK][angular-cdk], [WPF][wpf]                                                                                                                                                                                                                                                             | 2     |
| **Single-candidate flip-then-clamp** — exactly one alternative, then clamp        | [Qt Widgets][qt-widgets], [React Aria][react-aria]                                                                                                                                                                                                                                                 | 2     |
| **Free-space budget** — pick a side by room, hand that room to layout as a budget | [Helix][helix], [Neovim][neovim], [nvim-cmp / blink.cmp][nvim-completion], [GPUI][gpui], [Flutter][flutter], [tmux][tmux]                                                                                                                                                                          | 6     |
| **No solver** — clamp-only, caller-supplied, or deliberately out of scope         | [Apple][apple] (unpublished/system-owned), [posframe + company][emacs-posframe] (a caller-selected pure poshandler), [Notcurses][notcurses], [Ratatui][ratatui], [nui.nvim][nui], [Turbo Vision][turbo-vision], [WAI-ARIA APG][aria-apg], [Popover API][popover-api]                               | 8     |

### By dismissal model

Who decides that a press landed "outside", and who owns the cause vocabulary. Values follow
the [`comparison.md` at-a-glance matrix][c-glance]; the mechanics are in
[`comparison.md` § 8][c-dismissal] and [`concepts.md` § 8][concepts-dismissal].

| Dismissal model                                                      | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Count |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **Substrate-delivered** — the grab, the compositor or the UA decides | [GTK4][gtk4], [Popover API][popover-api], [Blink][blink], [Apple][apple], [`xdg_positioner`][xdg]                                                                                                                                                                                                                                                                                                                                                                                 | 5     |
| **Library-owned and on by default**                                  | [Radix][radix], [Base UI][base-ui], [Ariakit][ariakit], [Headless UI][headlessui], [Floating Vue][floating-vue], [Tippy][tippy], [React Aria][react-aria], [Qt Quick Controls][qt-quick], [Qt Widgets][qt-widgets], [WPF][wpf], [WinUI][winui], [Uno][uno], [Avalonia][avalonia], [Slint][slint], [GPUI][gpui], [Dear ImGui][imgui], [Compose][compose], [Flutter][flutter], [Textual][textual], [tmux][tmux], [Turbo Vision][turbo-vision], [posframe + company][emacs-posframe] | 22    |
| **Opt-in package**                                                   | [Floating UI][floating-ui] (`@floating-ui/react`'s `useDismiss`)                                                                                                                                                                                                                                                                                                                                                                                                                  | 1     |
| **Partial** — present but restricted or divergent between paths      | [Zag][zag], [WAI-ARIA APG][aria-apg], [Helix][helix], [Notcurses][notcurses]                                                                                                                                                                                                                                                                                                                                                                                                      | 4     |
| **Caller's problem** — the seam is exposed and nothing is decided    | [Angular CDK][angular-cdk], [Neovim][neovim], [nui.nvim][nui], [Ratatui][ratatui]                                                                                                                                                                                                                                                                                                                                                                                                 | 4     |
| **Absent**                                                           | [CSS anchor][css-anchor] (out of scope by design), [nvim-cmp / blink.cmp][nvim-completion]                                                                                                                                                                                                                                                                                                                                                                                        | 2     |

> [!NOTE]
> The single best-shaped answer in the corpus is [Qt Quick Controls'][qt-quick] `ClosePolicy`
> plus `tryClose(pos, phase)` — a flags word ANDed with a cause the _router_ supplies in the
> same vocabulary the policy is written in. [Uno][uno] and [WinUI][winui] reached the same
> shape independently and it rotted into verified dead code for want of a caller.
> [`dismissal-policy.d`](./examples/dismissal-policy.d) is that design in D.

### By state architecture

Per [`comparison.md` § 15][c-state], only four of thirty-eight model the open/close lifecycle
as an explicit machine. Rows 3 and 4 are _techniques_ and can co-occur with rows 1–2; row 5
is the residual.

| State architecture                                                                    | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Count |
| ------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| **Explicit lifecycle machine**                                                        | [Zag][zag] (declarative statechart), [Headless UI][headlessui] (pure reducer, total dispatch), [GPUI][gpui] (tooltip enum), [Compose][compose] (sealed context-menu status)                                                                                                                                                                                                                                                                                                                                                                                    | 4     |
| **Mount / transition lifecycle only**                                                 | [Radix][radix] (three-state presence), [Qt Quick Controls][qt-quick] (transition state), [Base UI][base-ui] (transition status)                                                                                                                                                                                                                                                                                                                                                                                                                                | 3     |
| **Openness as membership in one ordered array** — no per-overlay boolean              | [Dear ImGui][imgui] (compare two stack lengths), [Popover API][popover-api] + [Blink][blink] (the popover stack), [Slint][slint] (monotonically-keyed vector), [Headless UI][headlessui] (forty-line stack machine)                                                                                                                                                                                                                                                                                                                                            | 5     |
| **Transactional value update** — copy, modify, replace; restore on validation failure | [Neovim][neovim] (key-presence-guarded partial config patches), [`xdg_positioner`][xdg] (normatively pinned copy-on-use), [tmux][tmux] (preferred beside current geometry)                                                                                                                                                                                                                                                                                                                                                                                     | 3     |
| **Loose booleans over an imperative controller** — the rest of the catalog            | [Angular CDK][angular-cdk], [Apple][apple], [Ariakit][ariakit], [WAI-ARIA APG][aria-apg], [Avalonia][avalonia], [CSS anchor][css-anchor], [Floating UI][floating-ui], [Floating Vue][floating-vue], [Flutter][flutter], [GTK4][gtk4], [Helix][helix], [Notcurses][notcurses], [nui.nvim][nui], [nvim-cmp / blink.cmp][nvim-completion], [posframe + company][emacs-posframe], [Qt Widgets][qt-widgets], [Ratatui][ratatui], [React Aria][react-aria], [Textual][textual], [Tippy][tippy], [Turbo Vision][turbo-vision], [Uno][uno], [WinUI][winui], [WPF][wpf] | 24    |

### By whether the overlay can escape its parent's bounds

The unclippability question. It is what OS popups are bought for — and the third row is the
proof that a survey of "how do I escape a clip" is not the same survey as "where does the box
go", because three subjects place overlays perfectly well while never escaping anything.

| Escape                                                                           | Subjects                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Count |
| -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| **Escapes the application window** — onto the desktop, past every app-owned edge | [Apple][apple], [Avalonia][avalonia] (in its `PopupRoot` configuration), [Compose][compose], [GTK4][gtk4] (every backend but Android), [posframe + company][emacs-posframe] (GUI child frames), [Qt Quick Controls][qt-quick], [Qt Widgets][qt-widgets], [Slint][slint] (its `TopLevel` and native-menu paths), [WinUI][winui], [WPF][wpf], [`xdg_positioner`][xdg]                                                                                                                                                            | 11    |
| **Escapes every in-app clip, bounded by the app/terminal surface**               | [Angular CDK][angular-cdk], [Ariakit][ariakit], [Base UI][base-ui], [Blink][blink], [CSS anchor][css-anchor], [Dear ImGui][imgui], [Floating Vue][floating-vue], [Flutter][flutter], [GPUI][gpui], [Headless UI][headlessui], [Helix][helix], [Neovim][neovim], [Notcurses][notcurses], [nui.nvim][nui], [nvim-cmp / blink.cmp][nvim-completion], [Popover API][popover-api], [Radix][radix], [React Aria][react-aria], [Textual][textual], [Tippy][tippy], [tmux][tmux], [Turbo Vision][turbo-vision], [Uno][uno], [Zag][zag] | 24    |
| **Clipped by an ancestor, or the subject does not answer**                       | [WAI-ARIA APG][aria-apg] (`position: absolute` inside the trigger's containing block — no portal anywhere in the corpus), [Floating UI][floating-ui] (emits coordinates; escaping is the caller's job), [Ratatui][ratatui] (a widget can only write inside its own `Rect`)                                                                                                                                                                                                                                                     | 3     |

> [!NOTE]
> [Textual][textual] is the one subject that implements a genuine first-class top layer **in
> integer cells with no OS window and no z coordinate**, and it decomposes into exactly three
> resets: an order reset, a clip reset, and an _extent_ reset that keeps a wide overlay from
> growing its host's scrollable size. The third appears in no other subject.

---

## Milestones

When the capabilities the field now takes for granted actually landed. The **Verified**
column is strict: ✓ means the fact and its date were read at the pinned revision recorded in
the [ledger](#revision-ledger); ⚠ means the _fact_ is grounded but the calendar date comes
from ecosystem knowledge outside the reading, and should be treated as approximate.

| When                                                    | Milestone                                                                                                                                                                                                                                    | Subject                                    | Verified                                                                                                                                                                                    |
| ------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ≈1990                                                   | The whole overlay vocabulary — dropdown menus, cascading submenus, context menus, modal dialogs, a combobox surface, drop shadows — already exists inside a character cell grid, with no compositor, no hover, no key releases and no timers | [Turbo Vision][turbo-vision]               | ⚠ era attribution; the tree read is `magiblot/tvision`, a modern port, and carries no such date                                                                                             |
| 2006 (WPF 3.0)                                          | `BetweenShowDelay` — the cool-down / skip-delay as one duration plus one flag, defaulting to 100 ms                                                                                                                                          | [WPF][wpf]                                 | ⚠ "shipping since WPF 3.0" is read at the pinned revision; the calendar year is not                                                                                                         |
| ≈2016 (xdg-shell stable)                                | `set_constraint_adjustment` makes flip/slide/resize a wire-level bitfield the client cannot compute, solved out of process                                                                                                                   | [`xdg_positioner`][xdg]                    | ⚠ date not established at the pinned revision; what _is_ pinned is that the last functional change was interface version 3, and the interface stands at version 7 in wayland-protocols 1.49 |
| ≈2020 (GTK 4.0)                                         | `GtkPopover` becomes a `GtkNative` with its own `GdkSurface`, and `GdkPopupLayout` becomes the ten-scalar value a compositor _or_ GDK's own integer solver executes                                                                          | [GTK4][gtk4]                               | ⚠ the 4.0 attribution was not read at the pinned revision (4.23.1)                                                                                                                          |
| ≈2020 (Popper 2 → Floating UI)                          | Placement becomes an ordered **middleware** fold over one mutable `(x, y, placement, rects, middlewareData)` tuple, with every environment contact behind a three-method `Platform`                                                          | [Floating UI][floating-ui]                 | ⚠ dates; the packages read are `@floating-ui/dom` 1.8.0 / `@floating-ui/react` 0.27.20                                                                                                      |
| ≈2023–2024                                              | The **HTML Popover API** and the top layer specify stacking, cascade dismissal, focus scope and re-entrancy in painstaking detail — and specify placement, timing, hover and semantics not at all                                            | [Popover API][popover-api], [Blink][blink] | ⚠ shipping dates were not read; the algorithms were                                                                                                                                         |
| ≈2024                                                   | **CSS anchor positioning** puts placement into the cascade — `anchor()`, `position-try-fallbacks`, and an incumbent-skip rule that trades optimality for stability                                                                           | [CSS anchor][css-anchor]                   | ⚠ ship date; at the pinned revision Level 1 is a Working Draft with Work Status "refining"                                                                                                  |
| March 2020 → January 2026                               | Ratatui's `Clear` — the one widget whose purpose is popups — panics when its rect crosses the right or bottom edge, for six years                                                                                                            | [Ratatui][ratatui]                         | ✓                                                                                                                                                                                           |
| April 2025                                              | Ratatui absorbs the `centered_rect` helper out of an example and into `Rect`, five years after it appeared                                                                                                                                   | [Ratatui][ratatui]                         | ✓                                                                                                                                                                                           |
| August 2025                                             | Ariakit patches `tabindex` across three separate open paths in one commit (`ccfa79e8`) — the cost of an overlay family with no single open funnel                                                                                            | [Ariakit][ariakit]                         | ✓                                                                                                                                                                                           |
| December 2025                                           | CSS `anchor-name` lookup is re-specified to match timeline-name lookup (nearest ancestor first, else _last_ match in tree order)                                                                                                             | [CSS anchor][css-anchor]                   | ✓                                                                                                                                                                                           |
| 2026-04-28                                              | The `::tether` pseudo-element — the arrow primitive — is reverted back out of the anchor-positioning drafts (`31491a8b4`), leaving Level 1 with no arrow concept at all                                                                      | [CSS anchor][css-anchor]                   | ✓                                                                                                                                                                                           |
| GTK 4.22                                                | `GtkPopoverBin` lands as the dedicated context-menu container                                                                                                                                                                                | [GTK4][gtk4]                               | ✓ version; ⚠ calendar date                                                                                                                                                                  |
| Angular CDK v22                                         | The overlay's **default** layering becomes the browser top layer (`popover="manual"` + `showPopover()`), chosen once at creation by a feature test                                                                                           | [Angular CDK][angular-cdk]                 | ✓                                                                                                                                                                                           |
| notcurses 3.0.9                                         | The `ncplane_move_family_*` reconciliation stops looping forever — evidence that reconciling an ownership tree with a z-order is genuinely hard                                                                                              | [Notcurses][notcurses]                     | ✓ version; ⚠ calendar date                                                                                                                                                                  |
| tmux `next-3.8`                                         | Three successive generations of the popup idea sit in the tree at once, with the maintainer's written verdict on the oldest                                                                                                                  | [tmux][tmux]                               | ✓                                                                                                                                                                                           |
| posframe 1.5.2 (2026-05-27), company 1.1.0 (2026-07-21) | The _poshandler_ — placement as a named pure function of a flat measured record — paired with a second, surface-free renderer for the terminal                                                                                               | [posframe + company][emacs-posframe]       | ✓                                                                                                                                                                                           |

> [!WARNING]
> Entries marked ⚠ are **not** re-verifiable from this tree. They are included because a
> timeline with only the dates that happened to be committed to source comments would
> misrepresent the field's shape — but any of them should be re-checked before being quoted
> as fact.

---

## Quick navigation

### Reading paths

**"I have twenty minutes."** [`concepts.md`][concepts] for the vocabulary →
[`comparison.md` at a glance][c-glance] for the twelve-capability matrix →
[the ten questions][q-all].

**"I am designing the Sparkles primitive this informs."** The intended path, in order:

1. [`sparkles-baseline.md`][baseline] — what `sparkles:ui` can express **today**:
   `WidgetKind.popup` as a look with no behaviour, the unfinished `Palette` popup metrics,
   `clampOrigin`/`effectivePopupWidth` as the entire current placement engine, the GUI-only
   `HoverPopup`, `DCK5`'s finished overlay view with nowhere to live, the open defects, and
   the [per-target constraint list][baseline-targets].
2. [`comparison.md` § the ten questions][q-all] — especially
   [Q1 (the minimal core)][q1], [Q2 (placement as a pure function)][q2],
   [Q3 (what the cell grid costs)][q3] and [Q9 (what not to foreclose)][q9].
3. [`comparison.md` § the genuine forks][c-forks] — the decisions the field does _not_ agree
   on, which are therefore decisions rather than defaults.
4. [`features-people-forget.md`][forget] — read before freezing any signature; it is the
   list of behaviours that are cheap to design in and expensive to retrofit.
5. [`proposal.md`][proposal] — the milestoned plan, then its
   [open questions][proposal-open].
6. The three examples: [`place-reference.d`](./examples/place-reference.d),
   [`tooltip-timing.d`](./examples/tooltip-timing.d),
   [`dismissal-policy.d`](./examples/dismissal-policy.d) — the conclusions as code CI runs.

**"I am writing the placement solver."** [GTK4][gtk4] (best in class: complete, pure integer,
per-axis, value-shaped) → [`xdg_positioner`][xdg] (the same algebra proven across a process
boundary) → [Angular CDK][angular-cdk] (runner-up: a total order over candidates) →
[`comparison.md` § 2][c-placement] and [§ 3][c-collision] → [`place-reference.d`](./examples/place-reference.d).

**"I am writing tooltip timing."** [WPF][wpf] (`BetweenShowDelay`, the original formulation) →
[React Aria][react-aria] (the document-global warm-up machine) →
[`concepts.md` § warm-up / cool-down][concepts-timing] →
[`features-people-forget.md` § Timing][forget-timing] → [`tooltip-timing.d`](./examples/tooltip-timing.d).

**"I am writing dismissal, focus and modality."** [Qt Quick Controls][qt-quick] (policy as
data) → [Popover API][popover-api] + [Blink][blink] (the cause set and the cascade) →
[Flutter][flutter] (the hit-group test with no grab) → [`comparison.md` § 8][c-dismissal] →
[`dismissal-policy.d`](./examples/dismissal-policy.d).

**"I am on a cell grid and want to know what survives."** [Textual][textual] (a real top
layer in integer cells) → [Turbo Vision][turbo-vision] (the whole vocabulary, thirty-five
years early, and the substitute-don't-omit rule) → [Helix][helix] and [tmux][tmux] →
[`comparison.md` Q3][q3].

**"I care about accessibility and the a11y tree."** [WAI-ARIA APG][aria-apg] (roles, focus
ownership, dismissal, modality) → [Apple][apple] → [`features-people-forget.md` §
Accessibility][forget-a11y] → [`comparison.md` § 13][c-a11y].

### Neighbouring trees

| Tree                                    | What it carries that this one does not                                                                        |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| [Window system integration][wsi]        | The compositor grab, the X11 override-redirect alternative, and the in-canvas fork as a windowing decision    |
| [Platform UI guidelines][pug]           | The platform conventions an overlay's _chrome_ must respect — appearance, contrast, accent, motion            |
| [UI layout][ui-layout]                  | The box-flow model an overlay's _content_ is laid out by                                                      |
| [Sean Parent: Better Code][sean-parent] | The value-semantics vocabulary the recommendations lean on — Regular types, local reasoning, narrow contracts |
| [TUI libraries][tui-libraries]          | The cell-grid rendering substrate the terminal subjects sit on                                                |

### Specs this survey is tested against

[UI principles][spec-prn] (`PRN1`–`PRN12`) · [state machines][spec-stm] (`STM1`–`STM13`) ·
[the input model][spec-input] (the tier ladder, the hit-testing model) ·
[container routing precedence][spec-dck] (`DCK13`'s empty top-layers rung, and `DCK5`) ·
[backend degradation][spec-tgt] (`TGT5`) · [the widget catalog][spec-wgt] (`WGT7`'s popup,
`WGT16`'s toast) · [the theme][spec-theme].

---

## Sources

- The thirty-eight per-subject deep-dives listed in the [master catalog](#master-catalog),
  each carrying its own `Sources` section of primary-source file paths and official-doc URLs
  at the revision recorded in the [ledger](#revision-ledger).
- [`concepts.md`][concepts] — the shared vocabulary, with an index of which subject exercises
  each term.
- [`comparison.md`][comparison] — the cross-subject synthesis, including
  [how this survey was verified][c-verified] (the counts and the failure taxonomy of the
  adversarial pass).
- [`features-people-forget.md`][forget], [`sparkles-baseline.md`][baseline] and
  [`proposal.md`][proposal] — the behaviour inventory, the current state of `sparkles:ui`,
  and the plan.
- The three CI-compiled examples under [`examples/`](./examples/place-reference.d).
- [Writing Research Docs][research-docs] — the conventions this tree follows.

<!-- References -->

[comparison]: ./comparison.md
[concepts]: ./concepts.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[floating-ui]: ./floating-ui.md
[react-aria]: ./react-aria.md
[radix]: ./radix.md
[base-ui]: ./base-ui.md
[zag]: ./zag.md
[tippy]: ./tippy.md
[floating-vue]: ./floating-vue.md
[angular-cdk]: ./angular-cdk.md
[ariakit]: ./ariakit.md
[headlessui]: ./headlessui.md
[popover-api]: ./popover-api.md
[css-anchor]: ./css-anchor.md
[aria-apg]: ./aria-apg.md
[qt-quick]: ./qt-quick-controls.md
[qt-widgets]: ./qt-widgets.md
[gtk4]: ./gtk4.md
[avalonia]: ./avalonia.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[slint]: ./slint.md
[uno]: ./uno.md
[gpui]: ./gpui.md
[imgui]: ./imgui.md
[compose]: ./compose.md
[flutter]: ./flutter.md
[apple]: ./apple.md
[xdg]: ./xdg-positioner.md
[blink]: ./blink.md
[neovim]: ./neovim-floats.md
[nvim-completion]: ./nvim-completion.md
[nui]: ./nui.md
[textual]: ./textual.md
[ratatui]: ./ratatui.md
[helix]: ./helix.md
[turbo-vision]: ./turbo-vision.md
[notcurses]: ./notcurses.md
[tmux]: ./tmux-popup.md
[emacs-posframe]: ./emacs-posframe.md
[concepts-layering]: ./concepts.md#layering-group
[concepts-timing]: ./concepts.md#timing-group
[concepts-dismissal]: ./concepts.md#dismissal-group
[c-glance]: ./comparison.md#at-a-glance
[c-placement]: ./comparison.md#_2-placement-model
[c-collision]: ./comparison.md#_3-collision-and-geometry-engine
[c-dismissal]: ./comparison.md#_8-dismissal
[c-a11y]: ./comparison.md#_13-accessibility
[c-state]: ./comparison.md#_15-state-architecture
[c-forks]: ./comparison.md#the-genuine-forks
[c-verified]: ./comparison.md#how-this-survey-was-verified
[q-all]: ./comparison.md#the-ten-questions
[q1]: ./comparison.md#_1-what-is-the-minimal-surface-independent-core
[q2]: ./comparison.md#_2-can-placement-be-a-pure-function-of-regular-values
[q3]: ./comparison.md#_3-what-does-the-cell-grid-actually-cost
[q4]: ./comparison.md#_4-what-replaces-hover
[q5]: ./comparison.md#_5-what-does-a-script-free-html-target-get
[q6]: ./comparison.md#_6-how-much-of-floating-ui-will-the-browser-absorb
[q7]: ./comparison.md#_7-overlay-tree-or-overlay-list
[q8]: ./comparison.md#_8-where-does-adaptive-presentation-belong
[q9]: ./comparison.md#_9-what-must-the-api-not-foreclose
[q10]: ./comparison.md#_10-final-synthesis
[forget-timing]: ./features-people-forget.md#timing-warm-up-cool-down-and-the-shape-of-a-delay
[forget-a11y]: ./features-people-forget.md#accessibility
[baseline-targets]: ./sparkles-baseline.md#_8-the-per-target-constraint-list
[proposal-open]: ./proposal.md#_8-open-questions
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[tui-libraries]: ../tui-libraries/index.md
[spec-prn]: ../../specs/ui/principles.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-input]: ../../specs/ui/input.md
[spec-dck]: ../../specs/ui/containers.md
[spec-tgt]: ../../specs/ui/backends.md
[spec-wgt]: ../../specs/ui/widgets.md
[spec-theme]: ../../specs/ui/theme.md
[research-docs]: ../../guidelines/research-docs.md
[r-imgui]: https://github.com/ocornut/imgui
[r-apple]: https://developer.apple.com/documentation/
[r-compose]: https://github.com/androidx/androidx
[r-flutter]: https://github.com/flutter/flutter
[r-avalonia]: https://github.com/AvaloniaUI/Avalonia
[r-gtk4]: https://github.com/GNOME/gtk
[r-qtdeclarative]: https://github.com/qt/qtdeclarative
[r-qtbase]: https://github.com/qt/qtbase
[r-zed]: https://github.com/zed-industries/zed
[r-slint]: https://github.com/slint-ui/slint
[r-wpf]: https://github.com/dotnet/wpf
[r-winui]: https://github.com/microsoft/microsoft-ui-xaml
[r-uno]: https://github.com/unoplatform/uno
[r-wayland]: https://gitlab.freedesktop.org/wayland/wayland-protocols
[r-posframe]: https://github.com/tumashu/posframe
[r-company]: https://github.com/company-mode/company-mode
[r-helix]: https://github.com/helix-editor/helix
[r-neovim]: https://github.com/neovim/neovim
[r-notcurses]: https://github.com/dankamongmen/notcurses
[r-ratatui]: https://github.com/ratatui/ratatui
[r-textual]: https://github.com/Textualize/textual
[r-nui]: https://github.com/MunifTanjim/nui.nvim
[r-blinkcmp]: https://github.com/Saghen/blink.cmp
[r-nvimcmp]: https://github.com/hrsh7th/nvim-cmp
[r-tmux]: https://github.com/tmux/tmux
[r-tvision]: https://github.com/magiblot/tvision
[r-angular]: https://github.com/angular/components
[r-floatingvue]: https://github.com/Akryum/floating-vue
[r-ariakit]: https://github.com/ariakit/ariakit
[r-baseui]: https://github.com/mui/base-ui
[r-headlessui]: https://github.com/tailwindlabs/headlessui
[r-radix]: https://github.com/radix-ui/primitives
[r-reactspectrum]: https://github.com/adobe/react-spectrum
[r-floatingui]: https://github.com/floating-ui/floating-ui
[r-tippy]: https://github.com/atomiks/tippyjs
[r-zag]: https://github.com/chakra-ui/zag
[r-csswg]: https://github.com/w3c/csswg-drafts
[r-whatwg]: https://github.com/whatwg/html
[r-chromium]: https://chromium.googlesource.com/chromium/src
[r-apg]: https://github.com/w3c/aria-practices
