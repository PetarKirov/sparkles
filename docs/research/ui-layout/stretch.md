# Stretch (Rust)

A Rust implementation of CSS Flexbox built by Visly Inc. as a cross-platform, FFI-friendly
alternative to Facebook's Yoga. Stretch was the first widely-used Rust Flexbox engine
and is the direct ancestor of [Taffy](taffy.md); the repository has been archived since
roughly 2021, but its design --- a tree-owning `Stretch` driver, `Node` handles, and a
CSS-aligned `Style` struct --- continues to shape every Rust layout engine that came
after it.

| Field            | Value                                                                                               |
| ---------------- | --------------------------------------------------------------------------------------------------- |
| Language         | Rust                                                                                                |
| License          | MIT                                                                                                 |
| Repository       | <https://github.com/vislyhq/stretch> (archived)                                                     |
| Documentation    | <https://vislyhq.github.io/stretch/> (historical)                                                   |
| Version snapshot | 0.3.2 (last release ~2020; unmaintained since 2021)                                                 |
| Notable adoption | Visly design tool; early Servo experiments; embedded UI prototypes; React Native-style mobile demos |

---

## Overview

### What It Solves

In 2018, the only mature, embeddable Flexbox engine in widespread use was Facebook's
**Yoga** --- a C++ port of the parts of the WebKit layout engine relevant to React
Native. Yoga was (and remains) excellent, but it carried a C++ codebase, a hand-rolled
build system, manual memory management across an FFI boundary, and a slightly idiosyncratic
take on the CSS spec.

Stretch's pitch was: take the same idea --- "Flexbox without a browser" --- and reimplement
it in modern, safe Rust. The library was intended to be:

- **Embeddable.** A single layout engine that powers iOS, Android, web, desktop, and
  server-side rendering, with thin FFI shims on each platform.
- **Cross-platform.** No assumptions about the surrounding runtime; works equally well in
  a mobile app, a WASM bundle, or a server.
- **Mobile-first in performance budget.** Small binary size, low allocation pressure,
  optional multithreaded layout.
- **Spec-aligned.** Validated against Chrome's layout via headless tests, so behaviour
  matches what web developers expect.

Stretch was the layout backbone of **Visly**, the design platform from Visly Inc. (now
defunct). Visly used Stretch to power a "what you see is what you get" UI editor whose
outputs ran identically on iOS, Android, and the web.

### Design Philosophy

Stretch's design rested on a few core decisions, most of which Taffy inherited.

**A driver-owned tree.** The library's main type is `stretch::node::Stretch`, an arena-like
container that owns all `Node`s. Nodes are referenced by stable handles, not by pointers
or `Box`es. This avoided lifetime headaches across FFI: a node's identity is a small
integer that can live in a Swift `struct` or a Java `long` without borrow-checker drama.

**Style is a plain data struct.** Every CSS-like property is a field on `Style`. No
inheritance, no cascade, no selectors --- those are problems for whoever builds _on top_ of
Stretch. The library's job is purely to convert a tree of styles into a tree of
rectangles.

**Measure functions as escape hatch.** Anything Stretch cannot compute on its own (most
notably "how wide is this text in this font?") is delegated to a caller-supplied measure
function, called for leaf nodes whose intrinsic size matters. This is the same pattern
Yoga uses and Taffy inherited.

**Spec-aligned, browser-validated.** Tests were generated from HTML fixtures rendered in
headless Chrome, with the expected layout extracted from `getBoundingClientRect()`. If
Stretch disagreed with Chrome, Stretch was wrong by definition. This kept the library
honest and is the same testing strategy Taffy uses today.

**Small, focused API.** The full public surface area fit in three modules:
`stretch::node`, `stretch::style`, `stretch::geometry`. Adding a node, setting children,
setting a style, computing layout --- there were no other operations.

### History

- **2018 --- Initial release.** Eli Pesso and the Visly team published Stretch as
  open-source, alongside the Visly design tool. Initial scope was Flexbox only.

- **2019 --- FFI bindings.** Native bindings shipped for Android (Kotlin, via JNI), iOS
  (Swift, via CocoaPods), and JavaScript/TypeScript (via WebAssembly). This made Stretch
  one of the first Rust libraries with first-class consumption from mobile platforms.

- **2020 --- 0.3.x maintenance releases.** The final 0.3.2 release added bugfixes and
  small API polish. The project's stated roadmap mentioned CSS Grid and multithreaded
  layout, but neither shipped.

- **2021 --- Archived.** Visly Inc. ceased operations, and active maintenance of Stretch
  stopped. The repository was archived on GitHub. A community fork named `stretch2`
  attempted to keep the code alive but did not gain momentum.

- **2022 --- Renamed to Taffy.** DioxusLabs picked up `stretch2 0.4.3`, renamed it to
  `taffy`, cleaned up its dependencies, and committed to long-term maintenance. Taffy
  later added CSS Grid (0.3), Block (0.4), traitified Style (0.6), and named grid lines
  (0.9). See [Taffy](taffy.md) for the continuation of this lineage.

Stretch remains historically important even though it is no longer the right tool to
pick today: it established the shape of the API that every Rust layout engine since
2018 has converged on.

---

## Layout Model

Stretch is **Flexbox-only**. There is no Grid, no Block formatting context, no absolute
positioning beyond CSS-style `position: absolute`. Everything is a flex item or a flex
container, exactly as in CSS Flexbox Level 1.

### The Stretch Driver

The top-level type is `stretch::node::Stretch`:

```rust
pub struct Stretch { /* internal node storage */ }

impl Stretch {
    pub fn new() -> Stretch;
    pub fn new_node(&mut self, style: Style, children: Vec<Node>) -> Result<Node, Error>;
    pub fn new_leaf(&mut self, style: Style, measure: MeasureFunc) -> Result<Node, Error>;
    pub fn set_style(&mut self, node: Node, style: Style) -> Result<(), Error>;
    pub fn set_children(&mut self, parent: Node, children: Vec<Node>) -> Result<(), Error>;
    pub fn add_child(&mut self, parent: Node, child: Node) -> Result<(), Error>;
    pub fn remove_child(&mut self, parent: Node, child: Node) -> Result<Node, Error>;
    pub fn compute_layout(&mut self, node: Node, size: Size<Number>) -> Result<(), Error>;
    pub fn layout(&self, node: Node) -> Result<&Layout, Error>;
}
```

The `Node` handle is a small opaque value (an internal arena index), `Copy`, and safe to
store in user-side structures.

Layout is a two-step dance:

1. Build the tree by calling `new_node` (containers) and `new_leaf` (terminals).
2. Call `compute_layout(root, size)` with the available space, then read back per-node
   `Layout` values.

The `Layout` returned is a simple POD:

```rust
pub struct Layout {
    pub order: u32,
    pub size: Size<f32>,
    pub location: Point<f32>,
}
```

`location` is relative to the node's parent; the caller cumulates parent offsets when
rendering.

### Sizing Primitives

Stretch's sizing vocabulary is the direct ancestor of Taffy's `Dimension`. It lives in
`stretch::style`:

```rust
pub enum Dimension {
    Undefined,         // explicitly "not set"
    Auto,              // CSS auto
    Points(f32),       // absolute length (px-like)
    Percent(f32),      // 0.0..=1.0 of parent's relevant axis
}

pub enum Number {
    Defined(f32),
    Undefined,
}
```

`Number` is the inputs-with-unknowns type: callers pass
`Size<Number> { width: Defined(800.0), height: Undefined }` to `compute_layout` when
exactly one axis is known. Taffy later replaced `Number` with the more spec-aligned
`AvailableSpace` enum (which distinguishes "definite", "min-content", and "max-content"),
but Stretch's three-way split (`Undefined`, `Auto`, `Defined`) captures the same essential
information.

### The Style Struct

`Style` is the single source of truth for every layout property. The full field list is
modest, matching Flexbox Level 1:

```rust
pub struct Style {
    pub display: Display,                       // Flex | None
    pub position_type: PositionType,            // Relative | Absolute
    pub direction: Direction,                   // Inherit | LTR | RTL
    pub flex_direction: FlexDirection,          // Row | RowReverse | Column | ColumnReverse
    pub flex_wrap: FlexWrap,                    // NoWrap | Wrap | WrapReverse
    pub overflow: Overflow,                     // Visible | Hidden | Scroll

    pub align_items: AlignItems,                // FlexStart | FlexEnd | Center | Baseline | Stretch
    pub align_self: AlignSelf,                  // Auto | + AlignItems variants
    pub align_content: AlignContent,            // FlexStart | FlexEnd | Center | Stretch | SpaceBetween | SpaceAround
    pub justify_content: JustifyContent,        // FlexStart | FlexEnd | Center | SpaceBetween | SpaceAround | SpaceEvenly

    pub position: Rect<Dimension>,              // top/right/bottom/left when position_type == Absolute
    pub margin:   Rect<Dimension>,
    pub padding:  Rect<Dimension>,
    pub border:   Rect<Dimension>,

    pub flex_grow:   f32,                       // default 0.0
    pub flex_shrink: f32,                       // default 1.0
    pub flex_basis:  Dimension,                 // default Auto

    pub size:     Size<Dimension>,
    pub min_size: Size<Dimension>,
    pub max_size: Size<Dimension>,
    pub aspect_ratio: Number,
}
```

A blank `Style::default()` is a CSS-default Flex item: `flex-grow: 0`, `flex-shrink: 1`,
`flex-basis: auto`, `align-items: stretch`, `justify-content: flex-start`. This makes it
straightforward to construct a style by setting only the properties that differ from the
default:

```rust
Style {
    flex_direction: FlexDirection::Column,
    size: Size { width: Dimension::Percent(1.0), height: Dimension::Auto },
    ..Default::default()
}
```

### Display Modes

`Display` had only two variants in Stretch:

```rust
pub enum Display {
    Flex,   // default: children laid out via Flexbox
    None,   // node and descendants are skipped
}
```

There is no `Block` or `Grid` --- Stretch never shipped them. The Visly team mentioned
Grid as a roadmap item, but it landed only in the Taffy fork (0.3, 2023).

### Position: Relative vs Absolute

```rust
pub enum PositionType {
    Relative,   // participates in flex layout (default)
    Absolute,   // positioned by `position` rect, removed from flex flow
}
```

Combined with the `position: Rect<Dimension>` field, Stretch supports CSS absolute
positioning: an absolute child is removed from its parent's flex flow and positioned by
its `top`/`right`/`bottom`/`left` offsets relative to the parent's padding edge. This was
the standard way to build overlays and modals in Stretch-based UIs.

### Padding, Margin, Border

Stretch uses the CSS box model, though with a slightly less complete vocabulary than
Taffy. Each of margin / padding / border is a `Rect<Dimension>`:

```rust
pub struct Rect<T> {
    pub start: T,    // left in LTR
    pub end:   T,    // right in LTR
    pub top:   T,
    pub bottom: T,
}
```

The `start` / `end` naming (instead of `left` / `right`) makes RTL trivial: the same style
declaration produces a mirrored layout when `direction: RTL` is set on the parent. This is
the same convention CSS uses with `margin-inline-start` etc.

### Alignment

The alignment vocabulary is Flexbox Level 1, no more, no less:

```rust
pub enum AlignItems    { FlexStart, FlexEnd, Center, Baseline, Stretch }
pub enum AlignSelf     { Auto, FlexStart, FlexEnd, Center, Baseline, Stretch }
pub enum AlignContent  { FlexStart, FlexEnd, Center, Stretch, SpaceBetween, SpaceAround }
pub enum JustifyContent {
    FlexStart, FlexEnd, Center, SpaceBetween, SpaceAround, SpaceEvenly,
}
```

`justify_content` controls the **main axis** (the axis flex items flow along, determined
by `flex_direction`). `align_items` / `align_self` control the **cross axis** (the
perpendicular axis). `align_content` controls cross-axis distribution of multiple flex
_lines_ when `flex_wrap` is enabled. Anyone who has written CSS Flexbox will recognise
all of this verbatim.

### Measure-Arrange Protocol

Like Taffy and Yoga, Stretch separates **measure** (intrinsic content sizing of leaves)
from **arrange** (distribution of available space among children). The split is invisible
to callers --- a single `compute_layout` call runs both --- but it determines how custom
text and image content fit in.

The measure-function signature reads:

```rust
pub type MeasureFunc = Box<dyn Fn(Size<Number>) -> Size<f32>>;
```

The argument is the _constraints_ the algorithm wants the leaf to honour:
`Number::Defined(w)` means "fit within this width", `Number::Undefined` means "your
choice". The return value is the natural size the leaf chose. Callers typically close
over a font + text cache, an image, or a child UI that paints itself.

### Layout Algorithm

`compute_layout` walks the tree twice per pass:

1. **Measure descent.** Visit each node; if it is a leaf with a `MeasureFunc`, invoke
   the function with whatever constraints are known. Cache the result.
2. **Layout descent.** Run the Flexbox layout algorithm on each flex container,
   distributing space according to `flex-grow`, `flex-shrink`, `flex-basis`,
   `justify-content`, and the rest. Children's `Layout` values are written into the
   driver's internal storage.

Once `compute_layout` returns, the caller iterates the tree and reads `stretch.layout(node)`
for each node to get its final size and parent-relative position.

Caching is per-node: each node remembers the input constraints and the computed layout.
Repeated `compute_layout` calls with the same inputs hit the cache. Mutating a style or
the child list invalidates the affected subtree.

### Code Example: Basic Flex Row

```rust
use stretch::geometry::Size;
use stretch::node::Stretch;
use stretch::style::{Dimension, FlexDirection, JustifyContent, Style};

let mut stretch = Stretch::new();

let item_a = stretch.new_node(
    Style {
        size: Size { width: Dimension::Points(120.0), height: Dimension::Points(40.0) },
        ..Default::default()
    },
    vec![],
)?;

let item_b = stretch.new_node(
    Style {
        size: Size { width: Dimension::Points(120.0), height: Dimension::Points(40.0) },
        ..Default::default()
    },
    vec![],
)?;

let item_c = stretch.new_node(
    Style {
        flex_grow: 1.0,
        ..Default::default()
    },
    vec![],
)?;

let row = stretch.new_node(
    Style {
        flex_direction: FlexDirection::Row,
        justify_content: JustifyContent::FlexStart,
        size: Size { width: Dimension::Points(800.0), height: Dimension::Points(40.0) },
        ..Default::default()
    },
    vec![item_a, item_b, item_c],
)?;

stretch.compute_layout(row, Size::undefined())?;

let c = stretch.layout(item_c)?;
println!("item_c expands to width {}", c.size.width);
```

The third item has `flex_grow: 1.0` while the others have the default `flex_grow: 0.0`,
so it absorbs the remaining 560 units of width.

### Code Example: Column with Text Leaf

```rust
use stretch::geometry::{Number, Size};
use stretch::node::{MeasureFunc, Stretch};
use stretch::style::{AlignItems, Dimension, FlexDirection, Style};

let mut stretch = Stretch::new();

let title_measure: MeasureFunc = Box::new(|constraint: Size<Number>| {
    // Pretend we shaped "Hello, world" in a 14pt font and got these metrics.
    let width = match constraint.width {
        Number::Defined(w) => w.min(120.0),
        Number::Undefined => 120.0,
    };
    Size { width, height: 18.0 }
});

let title = stretch.new_leaf(Style::default(), title_measure)?;

let body = stretch.new_node(
    Style {
        flex_grow: 1.0,
        ..Default::default()
    },
    vec![],
)?;

let footer = stretch.new_node(
    Style {
        size: Size { width: Dimension::Auto, height: Dimension::Points(20.0) },
        ..Default::default()
    },
    vec![],
)?;

let card = stretch.new_node(
    Style {
        flex_direction: FlexDirection::Column,
        align_items: AlignItems::Stretch,
        size: Size { width: Dimension::Points(300.0), height: Dimension::Points(200.0) },
        padding: stretch::geometry::Rect {
            start: Dimension::Points(8.0),
            end: Dimension::Points(8.0),
            top: Dimension::Points(8.0),
            bottom: Dimension::Points(8.0),
        },
        ..Default::default()
    },
    vec![title, body, footer],
)?;

stretch.compute_layout(card, Size::undefined())?;
```

The measure function closes over whatever font / text-shaping state the application owns;
Stretch never sees fonts directly.

### Code Example: Absolute Overlay

```rust
use stretch::geometry::{Rect, Size};
use stretch::node::Stretch;
use stretch::style::{Dimension, PositionType, Style};

let mut stretch = Stretch::new();

let overlay = stretch.new_node(
    Style {
        position_type: PositionType::Absolute,
        position: Rect {
            start: Dimension::Points(20.0),
            end:   Dimension::Auto,
            top:   Dimension::Points(20.0),
            bottom: Dimension::Auto,
        },
        size: Size {
            width:  Dimension::Points(200.0),
            height: Dimension::Points(100.0),
        },
        ..Default::default()
    },
    vec![],
)?;

let underlay = stretch.new_node(
    Style {
        flex_grow: 1.0,
        ..Default::default()
    },
    vec![],
)?;

let scene = stretch.new_node(
    Style {
        size: Size {
            width:  Dimension::Points(800.0),
            height: Dimension::Points(600.0),
        },
        ..Default::default()
    },
    vec![underlay, overlay],
)?;

stretch.compute_layout(scene, Size::undefined())?;
```

`overlay` is removed from the flex flow of `scene` and pinned to `(20, 20)` with its own
size. `underlay` fills the full scene independently. This is the standard pattern for
toasts, modals, and pop-ups in CSS.

---

## Bindings / Language Support

Unlike its successor Taffy, Stretch shipped first-class bindings to several non-Rust
languages out of the box. This was a deliberate choice: Visly was a cross-platform product
shipping native iOS, Android, and web apps from a shared layout core.

| Platform              | Binding                         | Distribution |
| --------------------- | ------------------------------- | ------------ |
| Rust                  | Native crate                    | crates.io    |
| Android (Kotlin/Java) | JNI bindings to compiled `.so`  | Maven        |
| iOS (Swift)           | Swift wrapper over a static lib | CocoaPods    |
| Web (JS/TS)           | WebAssembly + a thin JS shim    | npm          |

Each binding presented the same conceptual API --- create a `Stretch` driver, add nodes,
set styles, compute layout --- adapted to the host language's idioms. A Stretch tree
declared in Kotlin would produce identical layout results to the same tree declared in
Swift or in raw Rust, because all four paths called the same compiled-Rust core.

The bindings have not been maintained since 2021. The Maven artifacts, CocoaPods, and
npm package are all frozen at the last release.

For an analogous capability today, the closest equivalents are:

- **Yoga**, which has had supported bindings to virtually every language for years.
- **[Taffy](taffy.md)**, which leaves binding generation to consumers --- there is no
  official Swift or Kotlin distribution, though community FFI wrappers exist.

---

## Strengths and Weaknesses

### For the UI-Layout Catalog Domain

**Strengths.**

- **Historically significant.** Stretch was the first Rust Flexbox engine, the first
  Rust UI-adjacent library with serious mobile bindings, and the direct ancestor of
  Taffy. Understanding Stretch is genuinely useful for understanding the design of
  every modern Rust layout engine.
- **Small, focused API.** The full public surface fits on one page. There is one driver,
  one style struct, one algorithm. For learning Flexbox in Rust, Stretch's code is far
  more readable than the larger and more general Taffy or Yoga codebases.
- **Spec-aligned via headless-Chrome fixtures.** The testing strategy --- diff against a
  real browser --- is exactly right for a layout engine, and was directly inherited by
  Taffy.
- **CSS-aligned vocabulary.** Like Taffy, the `Dimension` / `Points` / `Percent` /
  `Auto` / `Undefined` quartet maps cleanly to CSS, so developers can transfer mental
  models from web layout.

**Weaknesses.**

- **Archived and unmaintained.** No bug fixes since 2020-2021. No support for newer Rust
  editions or recent dependencies. Any production use today is taking on a maintenance
  cost.
- **Flexbox only.** No CSS Grid, no block formatting context, no inline flow, no
  baseline alignment beyond `align-items: baseline`. For real-world UI, this often is not
  enough; pure-Flex grids of inputs and cards work, but anything that wants two-axis
  control (rows + columns specified together) requires manual nesting.
- **`Box<dyn Fn>` measure functions.** Each measure function allocates and dyn-dispatches.
  Taffy later moved to a generic measure-function shape, removing both costs.
- **No build for modern Rust workflows.** No `wasm-bindgen` or `tracing` integration,
  no `no_std` story, no recent `serde` derives. The library predates these conventions.
- **Roadmap items never shipped.** CSS Grid, multithreaded layout, and incremental
  re-layout were all listed as future work, none of which Visly ever delivered. Each
  of these landed in Taffy.

### For Static One-Shot Rendering

For sparkles' static-table use case, Stretch's analysis tracks Taffy's closely, with two
additional considerations:

- **Smaller, more readable.** A reader curious about "what does Flexbox actually look
  like, in code?" gets more from reading Stretch's source than Taffy's. Stretch is ~5k
  LOC of focused algorithm; Taffy is ~30k LOC spanning three algorithms.
- **But: not a real option.** No serious project should depend on Stretch in 2026.
  It is on no maintenance schedule, has known bugs that will not be fixed, and its
  release artifacts have not been updated in five years.

For a working sparkles consumer the practical answer is: **read Stretch to understand
the shape**, then use Taffy if a real layout engine is needed, or hand-roll a small
column-sizer if it isn't. The vocabulary worth borrowing --- `Length`, `Percent`,
`Auto`, `Min`, `Max` --- is identical in both libraries.

### Compared to Alternatives

| Compared with                               | Where Stretch wins                                   | Where Stretch loses                                                                               |
| ------------------------------------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [Taffy](taffy.md)                           | Smaller; first-class FFI bindings; easier to read.   | Loses on everything that matters: maintenance, Grid, Block, RTL polish, named lines, modern Rust. |
| Yoga (C++, by Facebook)                     | Safer (Rust memory model); cleaner build.            | Yoga is maintained, has more language bindings, more battle-tested in mobile.                     |
| [Ratatui](../tui-libraries/ratatui.md)      | True Flexbox, including baseline alignment and wrap. | Ratatui is terminal-native and shipped; Stretch's `f32`s require rounding policy decisions.       |
| [Ink](../tui-libraries/ink.md) (Yoga in JS) | Pure Rust; no Node.js dependency.                    | Ink is a full retained-mode TUI framework; Stretch is layout-only and outdated.                   |
| Manual `int x, y, w, h` arithmetic          | Real Flexbox semantics for free.                     | A heavyweight, unmaintained dep when a couple of `std::cmp::max` calls would do.                  |

The practical summary: **Stretch is primarily historical** --- valuable to study, important
to Rust layout-engine lineage, but not the right answer for production decisions today.
Where you would have reached for Stretch in 2020, reach for [Taffy](taffy.md) in 2026.

---

## References

- **Repository:** <https://github.com/vislyhq/stretch> (archived)
- **API docs (historical):** <https://vislyhq.github.io/stretch/>
- **Crate:** <https://crates.io/crates/stretch>
- **stretch2 community fork:** <https://github.com/vislyhq/stretch/network/members>
- **Successor:** [Taffy](taffy.md) (this catalog)
- **Conceptual ancestors / siblings:**
  - Facebook Yoga: <https://github.com/facebook/yoga>
  - W3C Flexbox spec: <https://www.w3.org/TR/css-flexbox-1/>
- **Related TUI libraries:**
  - [Ratatui](../tui-libraries/ratatui.md) --- terminal layout via Cassowary-style
    constraints; complementary vocabulary.
  - [Ink](../tui-libraries/ink.md) --- the JavaScript/Yoga analogue of "Flexbox layout
    powering a non-browser UI framework".
  - [Textual](../tui-libraries/textual.md) --- Python TUI framework whose CSS layer
    reaches for similar concepts.
  - [Bubble Tea](../tui-libraries/bubbletea.md) --- contrasts with Stretch's tree
    approach: no shared layout engine, all layout by hand in `View`.
- **Visly Inc.:** The company that funded Stretch's development; ceased operations
  ~2021.
