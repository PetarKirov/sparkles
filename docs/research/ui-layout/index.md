# UI Layout Catalog

A breadth-first survey of UI layout libraries and the layout subsystems embedded in major UI/TUI/GUI frameworks. This catalog complements the [TUI Libraries Catalog](../tui-libraries/index.md) by zooming in on the **layout** dimension specifically: how widgets get sizes and positions, what primitives are exposed to the developer, and what algorithm runs underneath.

The scope is deliberately broad. We cover renderer-agnostic layout libraries (Clay, Yoga, Taffy), web platform layout specifications (CSS Flexbox, CSS Grid, Normal Flow), modern declarative GUI frameworks (SwiftUI, Jetpack Compose, Flutter), traditional desktop GUI layouts (WPF/XAML, Qt, GTK), JVM and Apple stacks (Swing/MiG, Auto Layout), Android (ConstraintLayout), classical Tk geometry managers, immediate-mode UI layout (Dear ImGui, egui), tiling window managers (i3/sway, xmonad), and the foundational typesetting algorithm of Knuth-Plass. Each entry has its own detailed write-up.

## Renderer-agnostic layout libraries

| Library                   | Language | Layout Model                   | Sizing Vocabulary                               | Status   | Links                                                                          |
| ------------------------- | -------- | ------------------------------ | ----------------------------------------------- | -------- | ------------------------------------------------------------------------------ |
| **[Clay](clay.md)**       | C        | Box-flow (row/column)          | `FIT` / `GROW` / `FIXED` / `PERCENT` + min/max  | Active   | [repo](https://github.com/nicbarker/clay)                                      |
| **[Yoga](yoga.md)**       | C++      | Flexbox (CSS subset)           | `flex-grow` / `flex-shrink` / `flex-basis`      | Active   | [repo](https://github.com/facebook/yoga) / [docs](https://www.yogalayout.dev/) |
| **[Taffy](taffy.md)**     | Rust     | Flexbox + CSS Grid + CSS Block | CSS `Length` / `Percent` / `Auto` / `Fr` / etc. | Active   | [repo](https://github.com/DioxusLabs/taffy)                                    |
| **[Stretch](stretch.md)** | Rust     | Flexbox (CSS subset)           | `flex-grow` / `flex-shrink` / `flex-basis`      | Archived | [repo](https://github.com/vislyhq/stretch)                                     |
| **[Kiwi](kiwi.md)**       | C++ / Py | Linear constraint solver       | `Variable` + `Constraint` + `Strength`          | Active   | [repo](https://github.com/nucleic/kiwi)                                        |

## Foundational algorithms

| Algorithm                             | Domain             | Year | Reference Implementations                                         | Links                                                                      |
| ------------------------------------- | ------------------ | ---- | ----------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **[Cassowary](cassowary.md)**         | Linear constraints | 1997 | Apple Auto Layout, GTK 4, kiwisolver, Cassowary.js, Cassowary.py  | [paper](https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf) |
| **[Knuth-Plass](tex-knuth-plass.md)** | Line breaking      | 1981 | TeX, LuaTeX, SILE, knuth-plass.js, several CSS engine experiments | [paper](https://www.eprg.org/G53DOC/pdfs/knuth-plass-breaking.pdf)         |

## Web platform layout specs

| Specification                             | Level / Year               | Browsers Interop | Non-browser Implementations                                                                                                       |
| ----------------------------------------- | -------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------------------------------- |
| **[CSS Normal Flow](css-normal-flow.md)** | CSS 2.1 (2011) / Display 3 | Universal        | Foundational; every other CSS layout mode is a deviation from it                                                                  |
| **[CSS Flexbox](css-flexbox.md)**         | Level 1 (2017) / Level 2   | Universal        | [Yoga](yoga.md), [Taffy](taffy.md), [Stretch](stretch.md), [Ink](../tui-libraries/ink.md), [Textual](../tui-libraries/textual.md) |
| **[CSS Grid](css-grid.md)**               | Level 1 (2017) / Level 2   | Universal        | [Taffy](taffy.md); rare in TUI libraries                                                                                          |

## Modern declarative GUI framework layouts

| Framework                                 | Language | Layout Protocol            | Sizing Vocabulary                      | Cross-link                                                          |
| ----------------------------------------- | -------- | -------------------------- | -------------------------------------- | ------------------------------------------------------------------- |
| **[SwiftUI](swiftui.md)**                 | Swift    | Propose-and-respond        | min / ideal / max preferred sizes      | Apple-only                                                          |
| **[Jetpack Compose](jetpack-compose.md)** | Kotlin   | Measure / place            | `Constraints(minWidth, maxWidth, ...)` | [Mosaic](../tui-libraries/mosaic.md) ports the runtime to terminals |
| **[Flutter](flutter.md)**                 | Dart     | Constraints down, sizes up | `BoxConstraints` (tight / loose)       | -                                                                   |

## Traditional desktop GUI layouts

| Framework                              | Language          | Layout Model                 | Sizing Vocabulary                                     | Notable lineage                                                                  |
| -------------------------------------- | ----------------- | ---------------------------- | ----------------------------------------------------- | -------------------------------------------------------------------------------- |
| **[WPF / XAML](wpf-xaml.md)**          | .NET (XAML+C#)    | Two-pass Measure / Arrange   | `Auto` / `Star (*)` / pixel + alignment               | Inherited by Silverlight, UWP, .NET MAUI, Avalonia, Uno                          |
| **[Qt Layouts](qt-layouts.md)**        | C++ / QML         | Box / Grid / Form / Stacked  | `QSizePolicy` + stretch factor                        | QHBoxLayout / QVBoxLayout / QGridLayout / QFormLayout                            |
| **[GTK 4](gtk.md)**                    | C (with bindings) | Pluggable `GtkLayoutManager` | halign / valign + hexpand / vexpand                   | GtkBoxLayout, GtkGridLayout, GtkConstraintLayout (Cassowary)                     |
| **[Swing / MiG Layout](swing-mig.md)** | Java              | `LayoutManager` interface    | preferred / min / max + per-manager constraints       | FlowLayout, BorderLayout, GridLayout, BoxLayout, GridBagLayout, GroupLayout, MiG |
| **[Tk geometry managers](tk.md)**      | Tcl/Tk            | `pack` / `grid` / `place`    | -side, -fill, -expand (pack); -sticky, -weight (grid) | Originated 1990; predates most modern layout APIs                                |

## Apple / Android constraint-based

| System                                                      | Platform       | Solver               | Adoption                                                      |
| ----------------------------------------------------------- | -------------- | -------------------- | ------------------------------------------------------------- |
| **[Auto Layout](auto-layout.md)**                           | UIKit / AppKit | Cassowary            | macOS 10.7 (2011), iOS 6 (2012), still the substrate of UIKit |
| **[Android ConstraintLayout](android-constraintlayout.md)** | Android Views  | Cassowary-derivative | Android Studio default for new layouts since 2017             |

## Immediate-mode layout

| Library                         | Language | Layout Style                      | Companion TUI Port                 |
| ------------------------------- | -------- | --------------------------------- | ---------------------------------- |
| **[Dear ImGui](dear-imgui.md)** | C++      | Cursor-based + Tables API         | [ImTui](../tui-libraries/imtui.md) |
| **[egui](egui.md)**             | Rust     | Cursor-based with retained sizing | -                                  |

## Tiling and structural layout

| System                      | Algorithm                                 | Configuration           |
| --------------------------- | ----------------------------------------- | ----------------------- |
| **[i3 / sway](i3-sway.md)** | Binary split-container tree               | Plain text config + IPC |
| **[xmonad](xmonad.md)**     | Functional layout combinators (typeclass) | Haskell                 |

## TUI layout models (cross-references)

These libraries are documented in the [TUI Libraries Catalog](../tui-libraries/index.md); this section pulls out their **layout subsystem** for direct comparison with the dedicated layout libraries above.

| Library                                                  | Layout Approach                                    | Sizing Vocabulary                                                               |
| -------------------------------------------------------- | -------------------------------------------------- | ------------------------------------------------------------------------------- |
| **[Ratatui](../tui-libraries/ratatui.md)** (Rust)        | Constraint solver on Rects                         | `Length(n)` / `Percentage(p)` / `Ratio(a, b)` / `Min(n)` / `Max(n)` / `Fill(n)` |
| **[Textual](../tui-libraries/textual.md)** (Python)      | CSS subset (Flexbox-like + Grid)                   | CSS keywords (`auto`, `1fr`, `100%`, fixed) plus dock                           |
| **[Ink](../tui-libraries/ink.md)** (JavaScript)          | Yoga (Flexbox)                                     | Yoga `flex-grow` / `flex-basis` etc. - see [Yoga](yoga.md)                      |
| **[FTXUI](../tui-libraries/ftxui.md)** (C++)             | Functional combinators (`hbox`, `vbox`, `gridbox`) | `size(WIDTH, EQUAL, n)` decorators                                              |
| **[Brick](../tui-libraries/brick.md)** (Haskell)         | Pure-functional combinators                        | `padLeftRight`, `hLimit`, `vLimit`, `padded`, `border`                          |
| **[tview](../tui-libraries/tview.md)** (Go)              | Flex with proportions                              | Fixed size + proportional weight                                                |
| **[Cursive](../tui-libraries/cursive.md)** (Rust)        | LinearLayout / nested views                        | Min size with caller-controlled bounds                                          |
| **[Notcurses](../tui-libraries/notcurses.md)** (C)       | Planes (absolute positioning) + helpers            | Manual rectangle math                                                           |
| **[Mosaic](../tui-libraries/mosaic.md)** (Kotlin)        | Jetpack Compose runtime on terminal                | See [Jetpack Compose](jetpack-compose.md)                                       |
| **[Nottui](../tui-libraries/nottui.md)** (OCaml)         | Functional reactive layout                         | Box combinators with stretch                                                    |
| **[libvaxis](../tui-libraries/libvaxis.md)** (Zig)       | Imperative                                         | Manual                                                                          |
| **[ImTui](../tui-libraries/imtui.md)** (C++)             | Dear ImGui on terminal                             | See [Dear ImGui](dear-imgui.md)                                                 |
| **[snacks.nvim](../tui-libraries/snacks-nvim.md)** (Lua) | Floating windows on Neovim's window/buffer model   | Window-row/col grid + size hints                                                |
| **[broot](../tui-libraries/broot.md)** (Rust)            | Custom (built on Ratatui)                          | -                                                                               |

---

## Architectural Taxonomy

### By Sizing Vocabulary

| Vocabulary                         | Description                                                                         | Libraries                                                                                                                                                  |
| ---------------------------------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Fit / Grow / Fixed / Percent**   | Small primitives with optional min/max clamps; siblings with `GROW` share equally   | [Clay](clay.md)                                                                                                                                            |
| **Flex-grow / shrink / basis**     | CSS Flexbox sibling weighting along main axis                                       | [Yoga](yoga.md), [CSS Flexbox](css-flexbox.md), [Taffy](taffy.md), [Stretch](stretch.md), [Ink](../tui-libraries/ink.md)                                   |
| **Linear constraints (Cassowary)** | Variables linked by `=`, `<=`, `>=` with strength priorities                        | [Cassowary](cassowary.md), [Kiwi](kiwi.md), [Auto Layout](auto-layout.md), [Android ConstraintLayout](android-constraintlayout.md), GTK 4 ConstraintLayout |
| **Grid template (`fr`, minmax)**   | Track-based two-axis grid with named lines / areas                                  | [CSS Grid](css-grid.md), [Taffy](taffy.md), WPF `Grid` (`*` star sizing close cousin)                                                                      |
| **Star sizing**                    | Proportional sibling weights (`*`, `2*`)                                            | [WPF / XAML](wpf-xaml.md), [Qt](qt-layouts.md) (stretch factor)                                                                                            |
| **Per-side stickiness / fill**     | Anchor to one or more edges of a cell                                               | [Tk](tk.md) (`grid -sticky nsew`), GridBagLayout (`anchor` / `fill`)                                                                                       |
| **Tight / loose constraints**      | Constraints flow down, sizes flow up; each box answers a `(minW, maxW, minH, maxH)` | [Flutter](flutter.md), Compose                                                                                                                             |
| **Propose-and-respond**            | Parent proposes an optional `(width?, height?)`; child returns a CGSize             | [SwiftUI](swiftui.md)                                                                                                                                      |
| **Cursor + auto-advance**          | Layout cursor moves after each widget; explicit `SameLine` for horizontal flow      | [Dear ImGui](dear-imgui.md), [egui](egui.md), [ImTui](../tui-libraries/imtui.md)                                                                           |
| **Tiling tree**                    | Binary split tree; new windows insert as siblings; resize via proportions           | [i3 / sway](i3-sway.md), [xmonad](xmonad.md)                                                                                                               |
| **Optimal line breaking**          | Dynamic programming over breakpoints with glue / penalty model                      | [Knuth-Plass](tex-knuth-plass.md)                                                                                                                          |

### By Measure / Arrange Protocol

| Protocol                       | Description                                                                  | Libraries                                                                                                                          |
| ------------------------------ | ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **Single-pass top-down**       | Parent passes constraints; child reports size; no second pass                | [Flutter](flutter.md), [Compose](jetpack-compose.md)                                                                               |
| **Two-pass Measure / Arrange** | Phase 1 collects desired sizes bottom-up; phase 2 distributes space top-down | [WPF / XAML](wpf-xaml.md), [GTK 4](gtk.md), [Qt](qt-layouts.md), [Swing](swing-mig.md), [SwiftUI](swiftui.md) (effectively)        |
| **Iterative solver**           | Constraint solver runs to a stable solution                                  | [Cassowary](cassowary.md), [Kiwi](kiwi.md), [Auto Layout](auto-layout.md), [Android ConstraintLayout](android-constraintlayout.md) |
| **Immediate / cursor-based**   | No measure pass; widgets are placed in order they are issued                 | [Dear ImGui](dear-imgui.md), [egui](egui.md)                                                                                       |
| **Combinator algebra**         | Layout is a pure function from `Rectangle` to placements                     | [xmonad](xmonad.md), [Brick](../tui-libraries/brick.md), [Nottui](../tui-libraries/nottui.md), [FTXUI](../tui-libraries/ftxui.md)  |
| **Render-command emission**    | Layout pass produces a list of draw commands; renderer agnostic              | [Clay](clay.md)                                                                                                                    |

### By Embedding

| Embedding                                      | Definition                                                                | Examples                                                                                                                                                                                    |
| ---------------------------------------------- | ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Standalone layout library**                  | Just sizing and positioning; renderer is the application's responsibility | [Clay](clay.md), [Yoga](yoga.md), [Taffy](taffy.md), [Stretch](stretch.md), [Kiwi](kiwi.md)                                                                                                 |
| **Spec without bundled implementation**        | Definition of behavior; many engines implement it                         | [CSS Flexbox](css-flexbox.md), [CSS Grid](css-grid.md), [CSS Normal Flow](css-normal-flow.md), [Cassowary](cassowary.md), [Knuth-Plass](tex-knuth-plass.md)                                 |
| **Baked into a GUI framework**                 | Layout types are part of a larger widget system                           | [SwiftUI](swiftui.md), [Compose](jetpack-compose.md), [Flutter](flutter.md), [WPF](wpf-xaml.md), [Qt](qt-layouts.md), [GTK 4](gtk.md), [Swing](swing-mig.md), [Auto Layout](auto-layout.md) |
| **Baked into a window manager / WM-like tool** | Layout is the product; UI affordances are minimal                         | [i3 / sway](i3-sway.md), [xmonad](xmonad.md)                                                                                                                                                |
| **Embedded as a TUI sublayer**                 | The layout primitives are wired through a terminal renderer               | All [TUI libraries](../tui-libraries/index.md)                                                                                                                                              |

---

## Detailed Studies

The following entries are analysed in depth.

### Pure layout libraries

- **[Clay][clay]** - single-header C library; sizing primitives `FIT` / `GROW` / `FIXED` / `PERCENT`; render-command emission
- **[Yoga][yoga]** - Meta's cross-platform Flexbox; the engine behind [Ink](../tui-libraries/ink.md) and React Native
- **[Taffy][taffy]** - Rust; supports CSS Flexbox + Grid + Block; used by Dioxus, Bevy, Zed
- **[Stretch][stretch]** - Taffy's archived Flexbox-only predecessor
- **[Kiwi][kiwi]** - C++ Cassowary implementation; the engine in `kiwisolver`, Matplotlib's `constrained_layout`, enaml

### Foundational algorithms

- **[Cassowary][cassowary]** - linear arithmetic constraint solver (Badros & Borning, 1997); the substrate of iOS Auto Layout
- **[Knuth-Plass][knuth-plass]** - optimal line breaking via dynamic programming (1981); the algorithm in TeX, SILE, and (selectively) modern browsers

### Web platform layout specs

- **[CSS Normal Flow][normal-flow]** - block / inline formatting contexts, the box model, margin collapsing, floats, position
- **[CSS Flexbox][flexbox]** - one-axis flex container; main / cross axes; the spec that birthed Yoga
- **[CSS Grid][grid]** - two-axis grid with tracks, lines, areas, subgrid, `fr` unit, `minmax`, `auto-fill` / `auto-fit`

### Modern declarative GUI framework layouts

- **[SwiftUI][swiftui]** - HStack / VStack / ZStack / Grid; propose-and-respond protocol; `Layout` protocol for custom layouts (iOS 16+)
- **[Jetpack Compose][compose]** - Row / Column / Box / ConstraintLayout; measure-and-place protocol; `Modifier.layout`; intrinsic measurements
- **[Flutter][flutter]** - Row / Column / Stack / Wrap / Flex; constraints-down-sizes-up; `RenderBox` protocol

### Traditional desktop GUI layouts

- **[WPF / XAML][wpf]** - Grid (with `*` star sizing) / StackPanel / DockPanel / WrapPanel / Canvas; Measure / Arrange protocol; inherited by Avalonia, UWP, MAUI
- **[Qt Layouts][qt]** - QHBoxLayout / QVBoxLayout / QGridLayout / QFormLayout / QStackedLayout; QSizePolicy + stretch factor; QML alternatives
- **[GTK 4][gtk]** - pluggable `GtkLayoutManager`; GtkBoxLayout, GtkGridLayout, GtkConstraintLayout (Cassowary), GtkOverlayLayout
- **[Swing / MiG Layout][swing-mig]** - AWT `LayoutManager` family; the GridBagLayout case study; GroupLayout; MiG's declarative constraint strings
- **[Tk geometry managers][tk]** - `pack` (1990), `grid` (1996), `place`; the classical layout API that influenced AWT and many others

### Apple / Android constraint-based

- **[Auto Layout][auto-layout]** - Cassowary in production; NSLayoutConstraint, anchors, intrinsic content size, content hugging / compression resistance
- **[Android ConstraintLayout][acl]** - flat hierarchy with anchored constraints, guidelines, barriers, chains; the modern Android default

### Immediate-mode layout

- **[Dear ImGui][imgui]** - cursor-based layout; Columns (legacy) and Tables API (since 1.80)
- **[egui][egui]** - Rust immediate mode with retained sizing memory; horizontal / vertical / columns

### Tiling and structural layout

- **[i3 / sway][i3-sway]** - binary split-container tree; configurable in plain text; the canonical modern tiling WM
- **[xmonad][xmonad]** - layouts as typeclass values composed with `|||`; pure-Haskell window arrangement

### Comparative

A focused cross-library comparison is in [the TUI Libraries Comparison](../tui-libraries/comparison.md). A follow-up `comparison.md` for layout libraries specifically may be added here as the catalog matures.

---

## References

[clay]: clay.md
[yoga]: yoga.md
[taffy]: taffy.md
[stretch]: stretch.md
[kiwi]: kiwi.md
[cassowary]: cassowary.md
[knuth-plass]: tex-knuth-plass.md
[normal-flow]: css-normal-flow.md
[flexbox]: css-flexbox.md
[grid]: css-grid.md
[swiftui]: swiftui.md
[compose]: jetpack-compose.md
[flutter]: flutter.md
[wpf]: wpf-xaml.md
[qt]: qt-layouts.md
[gtk]: gtk.md
[swing-mig]: swing-mig.md
[tk]: tk.md
[auto-layout]: auto-layout.md
[acl]: android-constraintlayout.md
[imgui]: dear-imgui.md
[egui]: egui.md
[i3-sway]: i3-sway.md
[xmonad]: xmonad.md
