# Taffy (Rust)

A high-performance, cross-platform UI layout library written in Rust that implements three CSS layout algorithms (Flexbox, Grid, and Block) as a renderer-agnostic engine. Taffy is used as a shared layout dependency by Servo, Bevy, Zed/GPUI, Slint, Floem, Blitz, and other Rust UI frameworks.

| Field            | Value                                                         |
| ---------------- | ------------------------------------------------------------- |
| Language         | Rust                                                          |
| License          | MIT                                                           |
| Repository       | <https://github.com/DioxusLabs/taffy>                         |
| Documentation    | <https://docs.rs/taffy/>                                      |
| Version snapshot | 0.10.1 (2026 release line)                                    |
| Notable adoption | Servo, Bevy, Zed (GPUI), Slint, Floem, Blitz, iocraft, Takumi |

---

## Overview

### What It Solves

Most UI toolkits eventually need to answer the same question: given a tree of nodes and a
set of style properties on each one, where does every node end up, and how big is it? In
the web platform this question is answered by the browser's layout engines (block, inline,
flex, grid). Outside the browser, the same question is answered repeatedly --- and
inconsistently --- by every native UI framework, game engine, and embedded UI runtime.

Taffy is an attempt to factor that work out of any particular framework. It provides a
**pure layout engine**: you describe a tree of nodes with CSS-like styles, you call
`compute_layout`, and it returns the absolute position and size of every node. It does not
draw anything, does not handle input, does not own a window, does not assume a particular
unit. The "pixel" is just a `f32`, which means the same engine works equally well for
desktop GUIs, terminal cell grids, game-engine HUDs, and PDF or SVG generation.

The library implements three CSS algorithms faithfully enough that you can copy a CSS
property from MDN and reasonably expect it to behave the same way in Taffy: **Flexbox**
(`display: flex`), **CSS Grid** (`display: grid`), and **Block** (`display: block`). Each
is gated behind a Cargo feature flag, so consumers who only need one algorithm pay only for
that algorithm's compiled code.

### Design Philosophy

Taffy's design rests on a small number of deliberate choices.

**Pure layout, nothing else.** The engine never reads from a font file, never opens a
window, never asks for a system clock. The only "world" it sees is the style tree and a
caller-supplied `available_space`. Anything that requires measuring real content (the
width of a piece of text, the natural dimensions of an image) is delegated back to the
caller via a _measure function_. This keeps the engine deterministic, testable in
isolation, and trivially embeddable.

**Web-spec fidelity over invention.** Taffy chooses to implement existing CSS algorithms
rather than design new ones. The vocabulary (`Length`, `Percent`, `Auto`, `Fr`, `Min`,
`Max`, `MinMax`, `flex-grow`, `align-self`, `grid-template-rows`, ...) is the vocabulary of
the W3C specs. The benefit is enormous: every front-end developer already understands the
mental model, every MDN reference page is also a reference page for Taffy, and the
correctness of the implementation can be validated against Chromium and Firefox by running
the same test fixtures.

**Slotmap-backed storage with stable IDs.** Nodes live in a slotmap inside a
`TaffyTree<Context>`. The caller holds `NodeId` handles, not pointers, which means there
is no borrow-checker friction when storing IDs in user-side structures, and nodes can be
freely added and removed without invalidating other IDs. This pattern is shared with most
slot-arena Rust UI engines (Bevy's `Entity`, GPUI's element keys, slotmap-backed ECS in
general).

**Cached, incremental computation.** Each node owns a `Cache` that memoises the result of
layout requests keyed on the available space and the kind of measurement requested
(content-size vs. final layout). Re-layout of a single subtree only invalidates entries
whose inputs actually changed, which is what makes Taffy fast enough for retained UI at 60
or 120 Hz.

**Renderer-agnostic by deliberate omission.** Taffy never tells you what a cell or pixel
looks like. It hands back floating-point rectangles and lets the caller decide whether to
draw them, snap them to a character grid, emit them as SVG, or pipe them into a GPU
command buffer. The same engine is used by Zed (GPU desktop UI), by Bevy (game UI), by
iocraft (terminal UI), and by Blitz (HTML rendering).

### History

Taffy's history is a chain of forks, each driven by the previous project losing its
maintainer.

- **2018 -- Stretch.** Visly Inc. released [Stretch][stretch-repo], a Rust Flexbox engine
  intended as a Yoga-alternative for cross-platform UI. It powered the Visly design tool
  and ran via FFI bindings on iOS, Android, and the web.

- **2021 -- Stretch archived.** Visly stopped maintaining Stretch. A community fork
  appeared as `stretch2` to keep the engine alive, but it too went stale within a year.

- **2022 -- Taffy 0.1.** The DioxusLabs maintainers renamed `stretch2 0.4.3` to `taffy`,
  cleaned up its dependency tree, and committed to long-term maintenance. The initial
  scope was Stretch's: Flexbox only.

- **0.3 (2023) -- CSS Grid.** The first major algorithm addition. Taffy gained a complete
  implementation of CSS Grid, including auto-placement, named lines, and `minmax(...)`
  track sizing.

- **0.4 (2023) -- Block layout and overflow.** Added `display: block`, so Taffy could now
  serve as a layout backend for HTML rendering (Servo, Blitz). Introduced the `overflow`
  property and overflow-aware scrollbar sizing.

- **0.6 (2024) -- Traitified style.** The `Style` struct became generic over a trait, so
  consumers could plug in their own style storage (useful for ECS integration in Bevy).
  `box-sizing` and computed margin output landed in this release.

- **0.9 (2024-2025) -- Named grid lines and grid template areas.** Generic string support
  for named lines, matching the CSS Grid spec.

- **0.10 (2026) -- RTL direction, floats, and CSS string parsing.** The `direction`
  property (LTR/RTL) became supported. Floats landed behind a feature flag. Style values
  gained `from_str` parsers, so callers can hand-write CSS strings.

The lineage is visible in the API: `Stretch -> Node -> Style` became
`TaffyTree -> NodeId -> Style`, with the same general shape but a more idiomatic Rust
slotmap and a much wider style vocabulary.

---

## Layout Model

Taffy is organised around four pieces: a **tree** that owns nodes, a **style** that
describes each node, an **algorithm** selected by `display`, and a **measure function**
that callers supply for leaves whose intrinsic size depends on real content.

### The TaffyTree

The top-level type is `TaffyTree<Context>`:

```rust
pub struct TaffyTree<Context = ()> { /* slotmap of nodes, caches, ... */ }
```

The optional `Context` type parameter lets callers attach arbitrary user data to each
leaf node (typically a reference into their own text or asset cache). The headline methods
are:

| Method                                         | Purpose                                                          |
| ---------------------------------------------- | ---------------------------------------------------------------- |
| `new()`                                        | Construct a tree with default capacity (16 nodes).               |
| `new_leaf(style)`                              | Create an unattached leaf node with the given style.             |
| `new_leaf_with_context(style, ctx)`            | Same, but attach a `Context` value used by the measure function. |
| `new_with_children(style, &[NodeId])`          | Create a parent node with an initial set of children.            |
| `set_style(node, style)`                       | Replace a node's style; invalidates caches.                      |
| `add_child(parent, child) / remove_child(...)` | Mutate the tree shape.                                           |
| `set_children(parent, &[NodeId])`              | Replace the entire child list of a node.                         |
| `compute_layout(root, available_space)`        | Run layout when no leaves need measuring.                        |
| `compute_layout_with_measure(root, space, fn)` | Run layout, calling `fn` to size leaves.                         |
| `layout(node) -> Result<&Layout>`              | Read the computed layout for a node relative to its parent.      |

Note the asymmetry: layout is _written_ during `compute_layout` and _read_ via `layout`.
The `Layout` type is a small POD:

```rust
pub struct Layout {
    pub order: u32,
    pub location: Point<f32>,
    pub size: Size<f32>,
    pub content_size: Size<f32>,
    pub scrollbar_size: Size<f32>,
    pub border: Rect<f32>,
    pub padding: Rect<f32>,
    pub margin: Rect<f32>,
}
```

`location` is offset from the parent's content box, so converting to absolute coordinates
is a simple cumulative sum during a render pass.

### Sizing Primitives

Taffy's most-reused vocabulary lives in `taffy::style::Dimension` and its siblings. These
are the small types every style field is built from:

```rust
pub enum Dimension {
    Length(f32),       // px-equivalent absolute length
    Percent(f32),      // 0.0..=1.0 of parent's relevant axis
    Auto,              // CSS auto
}

pub enum LengthPercentage {
    Length(f32),
    Percent(f32),
}

pub enum LengthPercentageAuto {
    Length(f32),
    Percent(f32),
    Auto,
}
```

Different style fields use different variants depending on what CSS allows:

| Property     | Type                         | Why                           |
| ------------ | ---------------------------- | ----------------------------- |
| `size`       | `Size<Dimension>`            | `width: auto` is meaningful.  |
| `min_size`   | `Size<Dimension>`            | Same.                         |
| `max_size`   | `Size<Dimension>`            | Same.                         |
| `padding`    | `Rect<LengthPercentage>`     | `padding: auto` is not valid. |
| `border`     | `Rect<LengthPercentage>`     | Same.                         |
| `margin`     | `Rect<LengthPercentageAuto>` | `margin: auto` _is_ valid.    |
| `inset`      | `Rect<LengthPercentageAuto>` | Same.                         |
| `gap`        | `Size<LengthPercentage>`     | No auto-gap.                  |
| `flex_basis` | `Dimension`                  | `flex-basis: auto` is valid.  |

For CSS Grid, two additional types appear:

```rust
pub enum MinTrackSizingFunction {
    Fixed(LengthPercentage),
    MinContent, MaxContent, Auto,
}

pub enum MaxTrackSizingFunction {
    Fixed(LengthPercentage),
    MinContent, MaxContent, Auto,
    FitContent(LengthPercentage),
    Fraction(f32),    // the `1fr`, `2fr`, ... unit
}
```

`Fraction` (the `fr` unit) is the one piece of vocabulary that has no analogue in
Flexbox: it expresses "share of the remaining track space after fixed and content tracks
are resolved". This is the same algorithm that makes CSS Grid feel so natural for
spreadsheet-shaped layouts.

`AvailableSpace` is the input handed into `compute_layout`:

```rust
pub enum AvailableSpace {
    Definite(f32),     // I have exactly this many units to fill.
    MinContent,        // Give me the smallest size that fits.
    MaxContent,        // Give me the size where nothing wraps.
}
```

Callers pass `Size<AvailableSpace>` so the two axes can be specified independently. A
desktop window typically passes `Definite(width)` and `Definite(height)`. A
narrow-content-measurement pass (e.g., for shrink-to-fit) passes `MinContent` /
`MaxContent` on the relevant axis.

### The Style Struct

`Style` is the single source of truth for everything Taffy needs to know about a node.
Selected fields, grouped:

```rust
pub struct Style {
    // ----- algorithm selection -----
    pub display: Display,                       // Block | Flex | Grid | None
    pub item_is_table: bool,
    pub item_is_replaced: bool,
    pub box_sizing: BoxSizing,
    pub direction: Direction,                   // LTR | RTL (>=0.10)

    // ----- overflow / scroll -----
    pub overflow: Point<Overflow>,              // (x, y) Overflow variant
    pub scrollbar_width: f32,

    // ----- positioning -----
    pub position: Position,                     // Relative | Absolute
    pub inset: Rect<LengthPercentageAuto>,

    // ----- box model -----
    pub size: Size<Dimension>,
    pub min_size: Size<Dimension>,
    pub max_size: Size<Dimension>,
    pub aspect_ratio: Option<f32>,
    pub margin: Rect<LengthPercentageAuto>,
    pub padding: Rect<LengthPercentage>,
    pub border: Rect<LengthPercentage>,

    // ----- gap -----
    pub gap: Size<LengthPercentage>,

    // ----- alignment (flex & grid) -----
    pub align_items: Option<AlignItems>,
    pub align_self: Option<AlignSelf>,
    pub align_content: Option<AlignContent>,
    pub justify_items: Option<AlignItems>,
    pub justify_self: Option<AlignSelf>,
    pub justify_content: Option<JustifyContent>,
    pub text_align: TextAlign,

    // ----- flex -----
    pub flex_direction: FlexDirection,          // Row | RowReverse | Column | ColumnReverse
    pub flex_wrap: FlexWrap,                    // NoWrap | Wrap | WrapReverse
    pub flex_basis: Dimension,
    pub flex_grow: f32,                         // default 0.0
    pub flex_shrink: f32,                       // default 1.0

    // ----- grid -----
    pub grid_template_rows: Vec<GridTemplateComponent<S>>,
    pub grid_template_columns: Vec<GridTemplateComponent<S>>,
    pub grid_auto_rows: Vec<TrackSizingFunction>,
    pub grid_auto_columns: Vec<TrackSizingFunction>,
    pub grid_auto_flow: GridAutoFlow,
    pub grid_template_areas: Vec<GridTemplateArea<S>>,
    pub grid_template_row_names: Vec<Vec<S>>,
    pub grid_template_column_names: Vec<Vec<S>>,
    pub grid_row: Line<GridPlacement<S>>,
    pub grid_column: Line<GridPlacement<S>>,

    // ----- floats (>=0.10, feature = "float_layout") -----
    pub float: Float,
    pub clear: Clear,
}
```

Most consumers never touch most of these fields. The idiomatic constructor is
`Style { ..Default::default() }`, in which everything is set to the CSS default. The
defaults are chosen so that an unstyled tree behaves the same as an unstyled CSS document
under the chosen `Display`.

### Display Modes

`Display` selects which algorithm runs on a node's children:

```rust
pub enum Display {
    Block,   // CSS block formatting context
    Flex,    // CSS Flexbox
    Grid,    // CSS Grid
    None,    // node and descendants are skipped
}
```

The default is `Flex` (assuming the `flexbox` feature is enabled), which matches the
preference of most Taffy-consuming UI frameworks. Switching modes is per-node: a flex
container can contain a grid container, which can contain a block container, exactly as in
HTML.

### Padding, Margin, Border, Gap

Taffy uses the CSS box model verbatim. Every node has, from outside in:

1. **Margin** -- space _outside_ the border; collapses in block flow, never in flex/grid.
2. **Border** -- visible (or not) edge; Taffy reserves the space, but does not paint it.
3. **Padding** -- space _inside_ the border, before content.
4. **Content** -- the area children flow into.

`box_sizing` toggles between `ContentBox` (the size set on `size` is the content box) and
`BorderBox` (the size includes border + padding).

`gap` controls space between flex items in a line, between flex lines when wrapping, and
between grid tracks. It is `Size<LengthPercentage>`, allowing different row-gap and
column-gap values.

### Alignment

The alignment vocabulary is the union of Flexbox's and Grid's:

```rust
pub enum AlignItems {
    Start, End, FlexStart, FlexEnd,
    Center, Baseline, Stretch,
}
pub type AlignSelf = AlignItems;

pub enum AlignContent {
    Start, End, FlexStart, FlexEnd,
    Center, Stretch, SpaceBetween, SpaceEvenly, SpaceAround,
}
pub type JustifyContent = AlignContent;
```

For Flexbox: `justify_content` controls main-axis alignment, `align_items`/`align_self`
control cross-axis alignment of single items, `align_content` controls the cross-axis
alignment of _lines_ when wrapping. For Grid: `justify_*` runs on the inline axis,
`align_*` on the block axis, and the same vocabulary is reused.

### Measure-Arrange Protocol

Taffy implements a two-phase **measure / arrange** protocol, although it does not expose
the phases separately. From the caller's perspective, a single call to `compute_layout`
runs both. Internally, layout proceeds as follows:

1. **Style cascade is skipped.** Taffy does not implement CSS inheritance; every node's
   style is independent. Callers do their own inheritance up-front.

2. **Measure pass.** For each leaf, Taffy asks "how big are you?" If a measure function
   was supplied, it is called with the known dimensions, available space, node ID, optional
   context, and the node's `Style`. If no measure function is supplied (or this node is
   not a leaf), the node's intrinsic size is `Size::ZERO`.

3. **Layout pass.** For each container, Taffy runs the algorithm selected by `display`:
   block, flex, or grid. Each algorithm distributes the available space among children
   according to the appropriate spec.

4. **Cache writeback.** Each node's `Layout` is written into a slotmap-backed cache,
   keyed on the `(NodeId, AvailableSpace, MeasureMode)` triple. Subsequent
   `compute_layout` calls with the same inputs are O(1).

The measure-function signature reads:

```rust
FnMut(
    known_dimensions: Size<Option<f32>>,
    available_space:  Size<AvailableSpace>,
    node_id:          NodeId,
    node_context:     Option<&mut Context>,
    style:            &Style,
) -> Size<f32>
```

This shape is the single seam between Taffy and the rest of the world. For text, the
measure function calls into a text-shaping library (cosmic-text, parley, swash, ...). For
images, it returns the intrinsic image size. For terminal cells, it returns
`Size { width: cells_wide as f32, height: lines_tall as f32 }`.

### Code Example: Flexbox Column

```rust
use taffy::prelude::*;

let mut tree: TaffyTree<()> = TaffyTree::new();

let header = tree.new_leaf(Style {
    size: Size { width: length(800.0), height: length(100.0) },
    ..Default::default()
}).unwrap();

let body = tree.new_leaf(Style {
    size: Size { width: length(800.0), height: auto() },
    flex_grow: 1.0,
    ..Default::default()
}).unwrap();

let footer = tree.new_leaf(Style {
    size: Size { width: length(800.0), height: length(40.0) },
    ..Default::default()
}).unwrap();

let root = tree.new_with_children(Style {
    flex_direction: FlexDirection::Column,
    size: Size { width: length(800.0), height: length(600.0) },
    gap: Size { width: length(0.0), height: length(8.0) },
    ..Default::default()
}, &[header, body, footer]).unwrap();

tree.compute_layout(root, Size::MAX_CONTENT).unwrap();

let body_layout = tree.layout(body).unwrap();
println!("body @ {:?} size {:?}", body_layout.location, body_layout.size);
```

The `prelude` re-exports the helper functions `length(x)`, `percent(x)`, `auto()`, and
`fr(x)`, which produce the right enum variant for whichever style field they are passed
into.

### Code Example: CSS Grid

```rust
use taffy::prelude::*;

let mut tree: TaffyTree<()> = TaffyTree::new();

let cell = |t: &mut TaffyTree<()>| t.new_leaf(Style::default()).unwrap();

let a = cell(&mut tree);
let b = cell(&mut tree);
let c = cell(&mut tree);
let d = cell(&mut tree);

let root = tree.new_with_children(Style {
    display: Display::Grid,
    size: Size { width: length(600.0), height: length(400.0) },
    grid_template_columns: vec![
        TrackSizingFunction::from_length(120.0),  // sidebar
        TrackSizingFunction::fr(1.0),             // main, takes leftover
        TrackSizingFunction::fr(1.0),             // detail, equal share
    ],
    grid_template_rows: vec![
        TrackSizingFunction::from_length(40.0),   // header
        TrackSizingFunction::fr(1.0),             // body
    ],
    gap: Size { width: length(8.0), height: length(8.0) },
    ..Default::default()
}, &[a, b, c, d]).unwrap();

tree.compute_layout(root, Size::MAX_CONTENT).unwrap();
```

Without `grid_row` / `grid_column` placement, items auto-flow into the grid in
declaration order according to `grid_auto_flow` (defaults to `Row`).

### Code Example: Custom Measure Function

```rust
use taffy::prelude::*;

#[derive(Clone, Copy)]
enum LeafKind { Text(&'static str), Image(f32, f32) }

let mut tree: TaffyTree<LeafKind> = TaffyTree::new();

let title = tree.new_leaf_with_context(
    Style::default(),
    LeafKind::Text("Hello, world"),
).unwrap();

let avatar = tree.new_leaf_with_context(
    Style::default(),
    LeafKind::Image(64.0, 64.0),
).unwrap();

let root = tree.new_with_children(Style {
    flex_direction: FlexDirection::Row,
    gap: Size { width: length(12.0), height: length(0.0) },
    ..Default::default()
}, &[avatar, title]).unwrap();

tree.compute_layout_with_measure(
    root,
    Size { width: AvailableSpace::Definite(400.0), height: AvailableSpace::MaxContent },
    |known, avail, _id, ctx, _style| {
        match ctx.copied() {
            Some(LeafKind::Image(w, h)) => Size { width: w, height: h },
            Some(LeafKind::Text(s)) => {
                let max_w = match avail.width {
                    AvailableSpace::Definite(w) => w,
                    _ => f32::INFINITY,
                };
                // Pretend we shaped text and got these dimensions back.
                let natural = s.chars().count() as f32 * 7.0;
                let width = known.width.unwrap_or(natural.min(max_w));
                let lines = ((natural / width).ceil()).max(1.0);
                Size { width, height: lines * 16.0 }
            }
            None => Size::ZERO,
        }
    },
).unwrap();
```

This is the canonical shape of integrating Taffy with a text shaper: the measure function
closes over the application's font and asset caches, and decides per-leaf how to compute
intrinsic dimensions.

### Code Example: Block + Flex Composition

```rust
use taffy::prelude::*;

let mut tree: TaffyTree<()> = TaffyTree::new();

let para_a = tree.new_leaf(Style::default()).unwrap();
let para_b = tree.new_leaf(Style::default()).unwrap();

let article = tree.new_with_children(Style {
    display: Display::Block,
    padding: Rect::length(16.0),
    ..Default::default()
}, &[para_a, para_b]).unwrap();

let sidebar = tree.new_leaf(Style {
    size: Size { width: length(220.0), height: auto() },
    ..Default::default()
}).unwrap();

let page = tree.new_with_children(Style {
    display: Display::Flex,
    flex_direction: FlexDirection::Row,
    size: Size { width: length(960.0), height: auto() },
    gap: Size { width: length(24.0), height: length(0.0) },
    ..Default::default()
}, &[sidebar, article]).unwrap();

tree.compute_layout(page, Size::MAX_CONTENT).unwrap();
```

The outer container uses Flex to lay out sidebar + article side by side; the inner
`article` switches to `Block` so its paragraph children stack vertically with margin
collapsing, exactly like HTML.

---

## Bindings / Language Support

Taffy itself is a Rust crate. Unlike Stretch, which shipped first-class FFI bindings,
Taffy leaves binding generation to downstream consumers. In practice:

- **C FFI** is provided by community crates such as `taffy_ffi`. Because the API is small
  (mostly `compute_layout`, `set_style`, `add_child`), wrapping it by hand is also a
  reasonable approach.
- **WebAssembly.** Taffy compiles cleanly to `wasm32-unknown-unknown` and is used inside
  WASM browsers (Servo's WASM build, Blitz). Downstream wrappers expose it to JavaScript
  via `wasm-bindgen`.
- **Bevy** vendors Taffy as an internal dependency for its UI plugin; Bevy users never
  call Taffy directly.
- **Slint** uses Taffy via a private interface for items that opt into CSS-like layout.
- **GPUI / Zed** uses Taffy for its element layout, with GPUI-specific element traits as
  the public API.

The pattern is consistent: Taffy is treated as a _library that frameworks use_, not as a
library that applications use. The vocabulary of `Style` and `Dimension` shows up in
those frameworks, sometimes 1-to-1 (Floem), sometimes wrapped in framework-specific
helpers (Bevy's `Node`, GPUI's `Style`).

---

## Strengths and Weaknesses

### For the UI-Layout Catalog Domain

**Strengths.**

- **Three algorithms in one engine.** Most layout libraries (Yoga, Stretch, classic
  Cassowary solvers) implement only one model. Taffy is the only widely-used Rust engine
  that ships Flexbox, Grid, _and_ Block under a single API. For a sparkles-style catalog
  this matters because the choice between algorithms is per-page: a CLI dashboard's outer
  shell might be a 3-row Grid, an inner toolbar a Flex row, and a help section a Block of
  paragraphs.
- **Spec fidelity.** Taffy is tested against the WPT (Web Platform Tests) suite where
  applicable, and against fixtures generated by headless Chrome for the rest. The
  practical consequence: if a layout works in a browser, it almost certainly works in
  Taffy, and if it does not, that is a bug Taffy is interested in fixing.
- **Renderer-agnostic.** Nothing about Taffy assumes pixels; the `f32` "unit" is whatever
  the caller decides it is. For a terminal layout it can be character cells, and the
  Cassowary-like distribution behaviour falls out naturally.
- **Active maintenance.** DioxusLabs has shipped Taffy releases continuously since 2022,
  with a steady cadence of bugfixes and feature additions. It is the de-facto choice for
  any Rust UI framework that does not want to write its own layout engine.

**Weaknesses.**

- **Heavyweight vocabulary.** The `Style` struct has thirty-plus fields, including
  fifteen that are only meaningful for CSS Grid. For a simple Flexbox-only consumer this
  is a lot of irrelevant surface area. Feature flags reduce _compiled_ code, but not the
  size of the public API.
- **No styling, no events, no rendering.** Taffy is pure layout. Consumers must supply
  their own text shaper, their own color and font model, their own input system. For a
  catalog comparing against, e.g., [Ratatui](../tui-libraries/ratatui.md) (which bundles
  layout + widgets + buffering) or [Textual](../tui-libraries/textual.md) (full TUI
  framework), Taffy is at a much lower abstraction level.
- **`f32` units are awkward for terminals.** Terminals are integer grids. Mixing `f32`
  layout with character cells means rounding policy becomes a real concern: do you floor,
  ceil, round-to-nearest? Taffy lets the caller decide, but that decision is non-trivial
  and easy to get wrong (off-by-one cells on resize is a common Taffy-in-terminal bug).
- **No incremental tree diffing.** The cache invalidates on `set_style`, but there is no
  "this subtree did not change, skip it" hook beyond cache hits. Frameworks like GPUI add
  their own layer on top.

### For Static One-Shot Rendering

Sparkles' main near-term consumer is the `drawTable` helper, which renders a single
non-interactive table once and exits. For that use case, Taffy is overkill in some ways
and underwhelming in others.

- **Overkill.** A table draw needs roughly two things: figure out per-column widths from
  content, then stamp the cells. Taffy can do that --- it amounts to a one-row Flex
  container with shrink-to-fit columns, or equivalently a one-row Grid with
  `auto`-sized columns. But pulling in a 30k-LOC layout engine to compute four column
  widths is the kind of dependency cost that is hard to justify.
- **Underwhelming.** Conversely, Taffy does not solve the _actual_ hard parts of static
  rendering: ANSI escape generation, Unicode width tables, grapheme-cluster handling,
  styled-text composition. All of these are _upstream_ of measurement (the measure
  function needs to know the width of a piece of text) and _downstream_ of layout (the
  arranged rects need to be rendered with ANSI escapes). A consumer would still need to
  write or import all of that.
- **What is genuinely useful.** The _vocabulary_ of `Length`, `Percent`, `Auto`, `Fr`,
  `Min`/`Max`/`MinMax` is excellent. It cleanly expresses the column-sizing problem ("two
  fixed columns, one auto, one taking the rest") that every drawTable consumer eventually
  hits. Even without using Taffy itself, copying this vocabulary into a sparkles-internal
  layout API would be a substantial usability win over ad-hoc `int width / int weight`
  pairs.

### Compared to Alternatives

| Compared with                                 | Where Taffy wins                                                | Where Taffy loses                                                                      |
| --------------------------------------------- | --------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| [Stretch](stretch.md)                         | Maintained; adds Grid, Block, RTL, named lines, floats.         | Larger API surface; loses Stretch's official FFI bindings.                             |
| Yoga (Facebook, used by Ink/Reaqct Native)    | Pure Rust; Grid + Block in addition to Flex; no C++ dependency. | Yoga has a larger ecosystem in mobile UI and is the runtime behind React Native + Ink. |
| [Ratatui](../tui-libraries/ratatui.md) layout | Generic algorithms (Flex, Grid, Block) not just kasuari-driven. | Ratatui's `Constraint` is purpose-built for terminals and integrates with widgets.     |
| [Ink](../tui-libraries/ink.md) / Yoga in JS   | Native Rust; embeds in any framework.                           | Ink offers a full retained-mode CLI framework; Taffy is layout-only.                   |
| Kasuari / Cassowary constraint solvers        | Algorithmic familiarity (CSS); incremental cache.               | Cassowary expresses arbitrary linear constraints; Taffy is limited to CSS algorithms.  |
| Manual `int x, y, w, h` arithmetic            | Handles wrapping, alignment, grid, baseline, ...                | Pulls in a ~30k-LOC dependency for cases where two `min`/`max`/`sum` calls suffice.    |

The honest summary: **Taffy is the right answer when "this looks like CSS layout" is
true** --- multi-pane dashboards, resizable splits, intrinsic-content sizing across many
elements, grid-shaped UIs. For one-shot terminal output of a known shape (a single table,
a single tree, a single status line), the dependency cost is hard to justify, but the
_vocabulary_ (`Length`/`Percent`/`Auto`/`Fr`) is worth borrowing wholesale.

---

## References

- **Repository:** <https://github.com/DioxusLabs/taffy>
- **Crate:** <https://crates.io/crates/taffy>
- **API docs (current):** <https://docs.rs/taffy/>
  - `TaffyTree`: <https://docs.rs/taffy/latest/taffy/tree/struct.TaffyTree.html>
  - `Style`: <https://docs.rs/taffy/latest/taffy/style/struct.Style.html>
  - `Display`: <https://docs.rs/taffy/latest/taffy/style/enum.Display.html>
  - `Dimension`, `LengthPercentage`, `LengthPercentageAuto`: see `taffy::style`
- **Release notes / changelog:** <https://github.com/DioxusLabs/taffy/blob/c4c7d09fe4ca2bd5109e976ed31a3d4e763b979d/CHANGELOG.md>
- **Notable adopters:**
  - Bevy UI: <https://github.com/bevyengine/bevy>
  - Zed editor (via GPUI): <https://github.com/zed-industries/zed>
  - Servo browser engine: <https://github.com/servo/servo>
  - Blitz: <https://github.com/DioxusLabs/blitz>
  - Slint: <https://github.com/slint-ui/slint>
  - Floem (Lapce editor): <https://github.com/lapce/floem>
- **Predecessor:** [Stretch](stretch.md) (this catalog)
- **Related TUI libraries:**
  - [Ratatui](../tui-libraries/ratatui.md) --- its `Constraint` enum is a single-axis
    cousin of Taffy's track-sizing vocabulary.
  - [Ink](../tui-libraries/ink.md) --- the JS-side equivalent of Taffy-embedded-in-a-framework.
  - [Textual](../tui-libraries/textual.md) --- ships its own CSS-driven layout, conceptually similar.
  - [Bubble Tea](../tui-libraries/bubbletea.md) --- contrasts with Taffy: no layout engine, all layout is by hand.

[stretch-repo]: https://github.com/vislyhq/stretch
