# Yoga (C++)

Meta's portable, embeddable layout engine that implements a faithful subset
of the CSS Flexbox specification, exposes a consistent API across more than
half a dozen host languages, and powers layout in React Native, Litho,
ComponentKit, Ink, and a number of in-house Meta surfaces. Where Clay
optimises for raw speed and a tight C-macro DSL, Yoga optimises for
behavioural fidelity to CSS and cross-platform consistency.

| Field            | Value                                                                        |
| ---------------- | ---------------------------------------------------------------------------- |
| Language         | C++20 core, with bindings for Java, Kotlin, Obj-C, JS, C                     |
| License          | MIT                                                                          |
| Repository       | <https://github.com/facebook/yoga>                                           |
| Documentation    | <https://www.yogalayout.dev/>                                                |
| Version snapshot | 3.2.1 (December 13, 2024); 3.2.0 introduced `box-sizing`                     |
| Notable adoption | React Native, Litho, ComponentKit, [Ink](../tui-libraries/ink.md), Bloomberg |

---

## Overview

### What It Solves

Cross-platform UI frameworks face a recurring quandary: web developers
expect Flexbox; native platforms (iOS, Android, terminal, embedded) have
their own native layout engines (Auto Layout, ConstraintLayout, ad-hoc
column math). Implementing the same UI three times for three layout
engines, with three slightly-different bugs and three slightly-different
edge-case behaviours, is expensive and tedious. Yoga's pitch is: write
one Flexbox tree, get pixel-identical layout on every host where Yoga
runs.

Concretely, Yoga is an **embeddable layout system** -- you create a
tree of `YGNode`s, set Flexbox properties on each node, call
`YGNodeCalculateLayout(root, availableWidth, availableHeight,
ownerDirection)`, and Yoga annotates each node with its computed
`(left, top, width, height)`. The host then walks the tree and draws
the nodes using whatever rendering primitives it has -- pixels for
React Native and ComponentKit, virtual DOM operations for ReactDOM
ports, terminal cells for Ink. Yoga itself never draws anything.

### Design Philosophy

Yoga's design choices are all in service of CSS fidelity and portability:

- **CSS Flexbox is the source of truth.** Where the spec has a defined
  behaviour for a corner case, Yoga matches it -- including some
  intentionally inconsistent spec behaviours, on the grounds that
  divergence would surprise users more than the inconsistency.
- **One algorithm, many bindings.** The layout algorithm lives in C++
  in `yoga/`, and the bindings (Java, JavaScript, Obj-C, Kotlin) call
  into it through thin FFI layers. There is no per-binding fork of the
  layout logic, so behaviour is identical across hosts.
- **Conformance is verified, not asserted.** Yoga ships an extensive
  set of generated test fixtures that capture the layout that a real
  browser produces for a particular DOM tree, and the same fixtures run
  against Yoga to ensure it matches. New corner-case bugs are typically
  reproduced first as a browser fixture, then fixed in Yoga.
- **Embeddability is non-negotiable.** No global state, no thread
  affinity, no implicit allocation behind your back, no required event
  loop. You allocate a `YGNode`, set properties on it, drop it when
  you are done. The whole engine is a couple of dozen kilobytes of
  compiled code.
- **Custom measurement is a first-class extension point.** Leaves (text,
  images, native widgets) register a `YGMeasureFunc` that Yoga calls
  during layout to get the intrinsic size of the leaf at a given
  constraint. Everything else is delegated to a host-defined notion
  of "what does this node measure to?"

### History

Yoga's pedigree predates the Yoga name. The earliest ancestor was
`css-layout` (sometimes written `CSSLayout`), a small JavaScript
implementation of the Flexbox spec that Facebook open-sourced around
**2014-2015** to power layout in React Native. The JS implementation was
then ported to C for performance and the result was renamed **Yoga**
around **2017** -- by then it was already in use by React Native,
ComponentKit (Facebook's Obj-C UI framework for iOS), and Litho
(Facebook's Android UI framework on top of ComponentKit's ideas). The
key fact for terminal-CLI watchers is that the same C codebase is what
Ink compiles into WebAssembly and ships in `node_modules` to compute
Flexbox layout for terminal output.

Major milestones since:

- **Yoga 2.0.0 (June 30, 2023)** -- the first major release since 2018.
  Introduced full Flexbox `gap` support (`gap`, `rowGap`, `columnGap`),
  modernised the toolchain (CMake-based builds, C++20), and improved
  conformance against newer Flexbox spec revisions.
- **Yoga 2.0.1 (November 1, 2023)** -- maintenance.
- **Yoga 3.0.0 (March 14, 2024)** -- introduced `position: static` (CSS
  `position` value, distinct from default `relative`), added
  `align-content: space-evenly`, switched the JavaScript bindings to
  ES Modules, and shipped alongside React Native 0.74. Some legacy APIs
  were removed.
- **Yoga 3.0.3 / 3.0.4 (April 2024)** -- maintenance.
- **Yoga 3.1.0 (June 26, 2024)** -- additional CSS conformance fixes.
- **Yoga 3.2.0 (December 3, 2024)** -- introduced `box-sizing` (so
  `border-box` is finally supported, matching CSS), added `display:
contents`, used by React Native 0.77.
- **Yoga 3.2.1 (December 13, 2024)** -- maintenance.

The cadence has been steady but unflashy: incremental conformance
improvements driven by React Native's release train, with the
occasional new CSS property added when a major React Native version
needs it.

---

## Architecture / Layout Model

### The Flexbox Subset Yoga Implements

Yoga's documentation puts it plainly: Yoga "supports a familiar subset
of CSS, mostly focused on Flexbox." What is in:

- **Container axis & direction**: `flexDirection` (`row`, `row-reverse`,
  `column`, `column-reverse`), and the `direction` property for
  `ltr`/`rtl` writing direction.
- **Main-axis distribution**: `justifyContent` with all six values
  (`flex-start`, `center`, `flex-end`, `space-between`, `space-around`,
  `space-evenly`).
- **Cross-axis alignment of items**: `alignItems`, with values
  `flex-start`, `center`, `flex-end`, `stretch`, `baseline`.
- **Per-item cross-axis override**: `alignSelf`, same value set as
  `alignItems` plus `auto`.
- **Cross-axis line packing for wrapped containers**: `alignContent`,
  with values `flex-start`, `center`, `flex-end`, `stretch`,
  `space-between`, `space-around`, and (since 3.0) `space-evenly`.
- **Wrapping**: `flexWrap` (`nowrap`, `wrap`, `wrap-reverse`).
- **Flex item sizing**: `flex` (the CSS shorthand), `flexGrow`,
  `flexShrink`, `flexBasis`.
- **Gaps**: `gap`, `rowGap`, `columnGap` (since Yoga 2.0).
- **Spacing**: `padding` and `margin` on all four sides plus logical
  edges (`paddingStart`/`paddingEnd` for RTL).
- **Positioning**: `position: relative` (default), `absolute`, and
  (since 3.0) `static`.
- **Aspect ratio**: `aspectRatio`.
- **Dimensions**: `width`, `height`, `minWidth`, `minHeight`,
  `maxWidth`, `maxHeight`, all in points, percentages, or `auto`.
- **Display**: `display: flex` (default), `display: none`, and (since
  3.2) `display: contents`.
- **Box model**: `box-sizing: content-box` (default) or `border-box`
  (since 3.2.0).

What is **not** in (as of 3.2.1):

- **CSS Grid**. Yoga has no Grid implementation. If you need
  two-dimensional grid layout, you build it on top of nested Flexbox
  rows, or you use a different engine.
- **Floats** (`float: left`, `clear: both`). Pre-Flexbox layout
  primitives that Yoga has no use for.
- **Tables**. CSS table layout is a separate algorithm; Yoga does not
  implement it.
- **Multi-column layout** (`column-count`, `column-gap` in the
  multicol sense, not the Flexbox sense).
- **Text shaping or line-breaking**. Yoga measures text only through
  the host-provided `YGMeasureFunc` callback; it has no built-in
  understanding of text content.

For terminal CLI purposes the missing pieces are mostly irrelevant
(no one wants CSS floats in a CLI), but the absence of Grid is
significant: many CLI layouts -- a help table with fixed-width
columns, a dashboard with a fixed grid of cells -- read more
naturally as Grid than as Flexbox. Ink users routinely express
these as nested Flexbox containers, which works but feels indirect.

### Sizing Primitives

The three knobs you have for sizing on each axis are:

| Property                 | Type              | Meaning                                                   |
| ------------------------ | ----------------- | --------------------------------------------------------- |
| `width` / `height`       | points, %, `auto` | Preferred dimension. `auto` means "use intrinsic / flex". |
| `minWidth` / `minHeight` | points, %         | Minimum dimension; node will not shrink below this.       |
| `maxWidth` / `maxHeight` | points, %         | Maximum dimension; node will not grow past this.          |

For flex items there are three additional knobs:

| Property     | Type              | Default | Meaning                                                                                                                                                                            |
| ------------ | ----------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `flexGrow`   | number            | `0`     | If there is leftover space on the main axis after positioning all items, distribute it among grow-enabled items in proportion to their `flexGrow` value.                           |
| `flexShrink` | number            | `0`     | If items overflow the main axis, shrink shrink-enabled items in proportion to `flexShrink` \* `flexBasis`. With `UseWebDefaults`, Yoga switches this default to the CSS value `1`. |
| `flexBasis`  | points, %, `auto` | `auto`  | The starting size on the main axis before grow/shrink applies. `auto` means "use the item's `width`/`height` if set, otherwise content size".                                      |

The `flex` shorthand combines all three (`flex: 1` is roughly
`flexGrow: 1, flexShrink: 1, flexBasis: 0`). Yoga's JavaScript bindings expose
object-style setters; the C API exposes the three setters individually.

The default `flexShrink` value is one of Yoga's known divergences from
the CSS Flexbox spec: CSS specifies a default of `1` (items shrink to
fit), Yoga's C API defaults to `0` (items do not shrink), the JS
binding patches this back to `1` to match web expectations. This is the
single most-asked support question in Yoga's history.

### Padding, Margin, and Gap

`padding` and `margin` each have per-side setters:

```cpp
YGNodeStyleSetPadding(node, YGEdgeLeft,   8);
YGNodeStyleSetPadding(node, YGEdgeRight,  8);
YGNodeStyleSetPadding(node, YGEdgeTop,    4);
YGNodeStyleSetPadding(node, YGEdgeBottom, 4);
```

`YGEdge` values include `Left`, `Right`, `Top`, `Bottom`, `Start`,
`End`, `Horizontal` (sets left+right), `Vertical` (sets top+bottom),
and `All`. `Start`/`End` are the RTL-aware variants that flip with
`direction: rtl`.

`gap` (since Yoga 2.0) is a single setter for both row and column,
with `rowGap` and `columnGap` for asymmetric values:

```cpp
YGNodeStyleSetGap(node, YGGutterAll,    8);   // 8 on both axes
YGNodeStyleSetGap(node, YGGutterRow,    4);   // 4 between rows
YGNodeStyleSetGap(node, YGGutterColumn, 8);   // 8 between columns
```

This matches CSS Flexbox's `gap` / `row-gap` / `column-gap`. Before
Yoga 2.0 you had to fake gaps with margin, which is fiddly because
margins on the outermost children produce edge bleed.

### Alignment

Alignment in Yoga is honest CSS Flexbox alignment, not Clay's collapsed
single-value-per-axis model. The four properties are:

| Property         | Axis       | Notes                                                                  |
| ---------------- | ---------- | ---------------------------------------------------------------------- |
| `justifyContent` | Main axis  | Packs the items as a group along the main axis (or distributes them).  |
| `alignItems`     | Cross axis | Default cross-axis alignment for all children.                         |
| `alignSelf`      | Cross axis | Override for a specific child.                                         |
| `alignContent`   | Cross axis | When `flexWrap: wrap`, controls how multiple lines pack on cross axis. |

`alignContent` only matters when wrapping is enabled and there are
multiple lines of items. If wrapping is off (or there is only one
line), `alignContent` is ignored.

### Position

`position: relative` (default) makes the node participate in normal
Flexbox flow. `position: absolute` takes the node out of flow and
positions it relative to the _padding edge_ of the nearest ancestor
that has `position` set to anything other than `static` -- by default
that is the immediate parent. `position: static` (since Yoga 3.0)
matches CSS: the node participates in flow and ignores `top`/`left`/
etc. settings.

```cpp
YGNodeStyleSetPositionType(node, YGPositionTypeAbsolute);
YGNodeStyleSetPosition(node, YGEdgeTop,  8);
YGNodeStyleSetPosition(node, YGEdgeLeft, 8);
```

### Aspect Ratio

`aspectRatio` is `width / height`. When set, Yoga uses it to derive the
unknown dimension from the known one. This is the easiest way to keep
an image or video element from distorting under flex pressure.

### Measure-Arrange Protocol

Like Clay, Yoga delegates text measurement to a host callback:

```cpp
typedef YGSize (*YGMeasureFunc)(
    YGNodeRef node,
    float width,
    YGMeasureMode widthMode,
    float height,
    YGMeasureMode heightMode
);
```

The host registers a `YGMeasureFunc` on leaf nodes (typically text or
image nodes). During layout, Yoga calls it with the available width and
height plus a _measure mode_:

- `YGMeasureModeUndefined` -- "no constraint, return intrinsic size".
- `YGMeasureModeExactly` -- "you must be exactly this size".
- `YGMeasureModeAtMost` -- "you may be up to this size".

The callback returns a `YGSize { width, height }` that Yoga then uses
in the parent's flex calculations. This is the extension hook for
terminal-cell-width measurement, monospaced or otherwise, and it is
exactly what [../tui-libraries/ink.md](../tui-libraries/ink.md) uses
for its text-wrapping logic.

The arrangement pass is internal to Yoga. After
`YGNodeCalculateLayout(root, availableWidth, availableHeight,
ownerDirection)` returns, you read computed values off each node:

```cpp
float x = YGNodeLayoutGetLeft(child);
float y = YGNodeLayoutGetTop(child);
float w = YGNodeLayoutGetWidth(child);
float h = YGNodeLayoutGetHeight(child);
```

Unlike Clay, Yoga does _not_ emit a render-command stream. The host is
expected to walk the layout tree itself, reading the computed
properties and producing whatever rendering primitives are appropriate.
This is a meaningful architectural difference: Yoga is a "compute
layout, write back to tree" engine; Clay is a "compute layout, emit
flat commands" engine. Yoga's model is more flexible (you can attach
arbitrary state to each node and walk it any way you like), Clay's is
more decoupled (you can hand the command array to a renderer that has
never heard of Clay's tree types).

### Code Example 1: Native C API

```cpp
#include <yoga/Yoga.h>

int main(void) {
    // Root: 500x300, horizontal flex.
    YGNodeRef root = YGNodeNew();
    YGNodeStyleSetWidth(root, 500);
    YGNodeStyleSetHeight(root, 300);
    YGNodeStyleSetFlexDirection(root, YGFlexDirectionRow);
    YGNodeStyleSetPadding(root, YGEdgeAll, 16);
    YGNodeStyleSetGap(root, YGGutterAll, 16);

    // Sidebar: fixed width, full height.
    YGNodeRef sidebar = YGNodeNew();
    YGNodeStyleSetWidth(sidebar, 120);
    YGNodeStyleSetFlexGrow(sidebar, 0);
    YGNodeStyleSetFlexShrink(sidebar, 0);
    YGNodeInsertChild(root, sidebar, 0);

    // Content: grows to fill remaining width.
    YGNodeRef content = YGNodeNew();
    YGNodeStyleSetFlexGrow(content, 1);
    YGNodeInsertChild(root, content, 1);

    YGNodeCalculateLayout(root, YGUndefined, YGUndefined, YGDirectionLTR);

    // Read computed layout.
    printf("sidebar: x=%g y=%g w=%g h=%g\n",
        YGNodeLayoutGetLeft(sidebar),
        YGNodeLayoutGetTop(sidebar),
        YGNodeLayoutGetWidth(sidebar),
        YGNodeLayoutGetHeight(sidebar));
    printf("content: x=%g y=%g w=%g h=%g\n",
        YGNodeLayoutGetLeft(content),
        YGNodeLayoutGetTop(content),
        YGNodeLayoutGetWidth(content),
        YGNodeLayoutGetHeight(content));

    YGNodeFreeRecursive(root);
}
```

Things to notice:

- Every property is set through a `YGNodeStyleSet*` setter. The C API
  is verbose by design -- there is no fluent builder, no constructor
  taking a struct of properties. Every property is one function call.
- The root's `width` and `height` are set explicitly, but the call to
  `YGNodeCalculateLayout` passes `YGUndefined` for the available
  width/height. This is the contract: the values you pass to
  `YGNodeCalculateLayout` are _additional_ constraints from outside
  the tree; if you have already pinned the root with explicit
  dimensions, you do not need to re-supply them.
- Memory ownership is explicit. `YGNodeFreeRecursive` walks the tree
  freeing all descendants; if you have shared ownership of some node,
  use `YGNodeFree` and free children individually.

### Code Example 2: JavaScript Bindings (the Path Ink Uses)

The JS bindings wrap the C++ core through Emscripten-compiled WASM,
producing a `yoga-layout` npm package. The API maps the C functions
onto a Node-style object:

```js
import { Yoga, FlexDirection, Edge, Gutter } from 'yoga-layout';

const root = Yoga.Node.create();
root.setWidth(80);
root.setHeight(24);
root.setFlexDirection(FlexDirection.Column);
root.setPadding(Edge.All, 1);
root.setGap(Gutter.All, 1);

const header = Yoga.Node.create();
header.setHeight(3);
header.setFlexGrow(0);
header.setFlexShrink(0);
root.insertChild(header, 0);

const body = Yoga.Node.create();
body.setFlexGrow(1);
root.insertChild(body, 1);

const footer = Yoga.Node.create();
footer.setHeight(1);
footer.setFlexGrow(0);
root.insertChild(footer, 2);

root.calculateLayout(80, 24, /* direction */ 0);

console.log('header:', header.getComputedLayout());
console.log('body:', body.getComputedLayout());
console.log('footer:', footer.getComputedLayout());

root.freeRecursive();
```

`getComputedLayout()` returns `{ left, top, width, height }`. This is
the API surface Ink calls through after JSX is reconciled into a
node tree -- see [../tui-libraries/ink.md](../tui-libraries/ink.md) for
the full pipeline from `<Box>` to `Yoga.Node.create()` to ANSI string
output.

Critically, in the terminal-CLI use case, one Yoga "point" maps to
**one character cell**. Ink chooses this scaling: when Yoga reports
`width: 80`, that is 80 columns. The cell-scale assumption is what
makes Yoga's float-typed `setWidth`/`setHeight`/`flexGrow` API usable
for terminal output without further projection.

### Code Example 3: Measure Function for Text

```cpp
typedef struct {
    const char *text;
    int         fontHeight;  // cells, for terminal use
} TextLeaf;

YGSize MeasureText(
    YGNodeRef node,
    float width, YGMeasureMode widthMode,
    float height, YGMeasureMode heightMode
) {
    TextLeaf *leaf = (TextLeaf *) YGNodeGetContext(node);
    size_t len = strlen(leaf->text);

    YGSize result = { .width = (float) len, .height = (float) leaf->fontHeight };

    if (widthMode == YGMeasureModeExactly) {
        result.width = width;
    } else if (widthMode == YGMeasureModeAtMost && result.width > width) {
        // Naive word-wrap: split on the last space before `width`.
        size_t lines = (size_t) ceilf(result.width / width);
        result.width  = width;
        result.height = (float) (leaf->fontHeight * lines);
    }
    return result;
}

YGNodeRef text = YGNodeNew();
YGNodeSetContext(text, &myLeaf);
YGNodeSetMeasureFunc(text, MeasureText);
```

This is essentially what Ink's measure function does, but elaborated
with proper grapheme width handling for emoji, CJK double-width
characters, and ANSI escape sequences (which take terminal-cell width
0).

### Code Example 4: Composing a Centered Card

```cpp
// Root: column-direction, items centered on both axes.
YGNodeRef root = YGNodeNew();
YGNodeStyleSetFlexDirection(root, YGFlexDirectionColumn);
YGNodeStyleSetJustifyContent(root, YGJustifyCenter);
YGNodeStyleSetAlignItems(root, YGAlignCenter);
YGNodeStyleSetWidth(root, 80);
YGNodeStyleSetHeight(root, 24);

// Card: column-direction, fits content, with padding and a min width.
YGNodeRef card = YGNodeNew();
YGNodeStyleSetFlexDirection(card, YGFlexDirectionColumn);
YGNodeStyleSetMinWidth(card, 30);
YGNodeStyleSetMaxWidth(card, 60);
YGNodeStyleSetPadding(card, YGEdgeAll, 2);
YGNodeStyleSetGap(card, YGGutterAll, 1);
YGNodeStyleSetAlignItems(card, YGAlignCenter);
YGNodeInsertChild(root, card, 0);

// Two text children inside the card.
YGNodeRef title = YGNodeNew();
YGNodeSetContext(title, /* leaf with "Confirm" */ ...);
YGNodeSetMeasureFunc(title, MeasureText);
YGNodeInsertChild(card, title, 0);

YGNodeRef body = YGNodeNew();
YGNodeSetContext(body, /* leaf with "Are you sure?" */ ...);
YGNodeSetMeasureFunc(body, MeasureText);
YGNodeInsertChild(card, body, 1);

YGNodeCalculateLayout(root, YGUndefined, YGUndefined, YGDirectionLTR);
```

The card has `minWidth: 30` / `maxWidth: 60`, so it grows or shrinks
within that band as its text content varies. The combination
`justifyContent: center` + `alignItems: center` on the root produces
true center-of-screen placement on both axes.

---

## Bindings and Language Support

Yoga's value proposition is that the layout algorithm is identical
across hosts, so the binding catalog is the API:

| Language                | Binding                                   | Notes                                                                                           |
| ----------------------- | ----------------------------------------- | ----------------------------------------------------------------------------------------------- |
| C++                     | Core (in-tree)                            | The reference implementation. C++20.                                                            |
| C                       | `yoga/Yoga.h`                             | A thin C facade over the C++ core, used by all non-C++ bindings.                                |
| Java                    | `yoga/javatests`                          | Used by Litho (Facebook's Android UI framework). JNI to the C core.                             |
| Kotlin                  | (Android)                                 | Calls the Java bindings.                                                                        |
| Objective-C             | `YogaKit`                                 | Used by ComponentKit (Facebook's iOS UI framework). Categories on `UIView`.                     |
| Swift                   | via `YogaKit`                             | Mostly imports the Obj-C surface; Swift Package Manager support is available.                   |
| JavaScript / TypeScript | `yoga-layout` (npm)                       | Emscripten-compiled WASM. This is what [Ink](../tui-libraries/ink.md) uses for terminal layout. |
| .NET / C#               | Community ports                           | Several wrappers exist; no official Meta-maintained binding.                                    |
| Rust                    | `yoga` (crates.io), maintained externally | Wraps the C facade via `bindgen`.                                                               |

The dominant deployments:

- **React Native** uses Yoga to compute layout for native iOS and
  Android views. This is by far the biggest user, and it is why React
  Native's release cycle drives Yoga's release cycle (a new Yoga
  version typically ships in advance of a corresponding React Native
  release that needs the new properties).
- **Litho** (Facebook's Android UI) uses Yoga for declarative,
  Flexbox-driven view layout, mostly to avoid `View` allocation in
  list-heavy screens.
- **ComponentKit** (Facebook's iOS UI) uses Yoga via `YogaKit` for the
  same reason.
- **Ink** ([../tui-libraries/ink.md](../tui-libraries/ink.md)) uses
  `yoga-layout` (the WASM build) to compute Flexbox layout for
  terminal text output. Every `<Box>` in Ink is a `YGNode`; every
  `<Text>` is a leaf with a `YGMeasureFunc` that returns string width
  in cells.
- **Bloomberg** has been a long-running Yoga user for terminal UI,
  predating Ink.

### WASM Footprint

Because Ink ships Yoga's WASM build with every Ink CLI, the WASM
artifact size is worth noting. The current `yoga-layout` package
bundles a roughly 100-200 KB WASM binary (compressed) plus its JS
shim. Loading is asynchronous and adds a small fixed cost to every
Ink program's startup. This is one of the reasons Ink's startup time
is heavier than native CLI alternatives.

---

## Strengths and Weaknesses

### For Cross-Platform Component Layout (its target)

Yoga is the best-in-class choice for cross-platform Flexbox:

- **CSS-spec fidelity**. If you know what a browser would do, you know
  what Yoga will do (modulo a few documented divergences, mostly
  around `flexShrink` defaults). Web developers can sketch a UI in
  the browser and port it to React Native or Ink without surprises.
- **Identical behaviour across hosts**. A `<Box flexDirection="row">`
  in Ink lays out exactly like a `View` with the same style in React
  Native. This is the whole point of Yoga.
- **Mature and stable**. Ten years of production use at Meta, with
  ongoing investment driven by the React Native release train. Bugs
  are tracked via browser-fixture regression tests.
- **Good extensibility hook**. `YGMeasureFunc` is enough to integrate
  text shaping engines (HarfBuzz for native), terminal cell-width
  calculators (Ink's wide-character handling), or image natural
  sizes (React Native's `<Image>` measurement).
- **Predictable performance**. Yoga's layout pass is linear in node
  count for typical UIs. The hot path is well-optimised C++, with
  cached intrinsic measurements and a layout-dirty-flag system.

### For Static One-Shot Terminal Rendering

For a one-shot terminal renderer (a CLI table, a help screen, a log
line), Yoga is overkill in much the same way Clay is, but for slightly
different reasons:

- **The engine is sized for many frames per second of layout, not for
  one frame.** Allocating a tree of `YGNode`s for a one-shot render,
  setting properties one function call at a time, and then walking
  the tree to read computed values is a lot of ceremony for a static
  output. The amortised cost is fine for a long-running TUI; for a
  CLI tool that prints a table and exits, the layout-engine overhead
  is larger than the actual rendering work.
- **You are forced to think in Flexbox terms**. If your goal is "two
  columns, the left one fits its content, the right one fills the
  rest, with a one-cell gap," the Flexbox encoding is
  `flexDirection: row; gap: 1; left.flexShrink: 0;
right.flexGrow: 1`. That works, but for simple layouts a direct
  `(col1_width, col2_width = total - col1 - gap)` calculation is two
  lines of arithmetic. The conceptual overhead of "what does
  `flexShrink: 0` mean here?" is not zero, and a simpler library
  (Ratatui-style constraint splitting, or just D's
  `std.algorithm.sum` on column widths) is often clearer.
- **There is no built-in renderer.** Yoga gives you a tree of
  computed `(left, top, width, height)` values. You still have to
  walk the tree and emit cells. For a one-shot output, that walk is
  often as much code as a direct layout computation would have been.
- **The dependency is heavy.** For Ink, the Yoga WASM is justified by
  the cross-platform component model. For a small CLI, the same
  dependency is a hundred kilobytes of WASM plus a JS shim, all to
  align two columns.
- **Float coordinates have to be rounded.** Yoga's API is all `float`,
  so even when you are deliberately using one-point-equals-one-cell
  scaling, the values you read out can be `3.0000002` or `3.9999998`
  depending on the arithmetic. A terminal renderer has to round
  carefully (Ink uses `Math.round` on every dimension) to avoid
  off-by-one artefacts. Native point-based renderers do not have
  this problem because their hosts treat fractional points correctly;
  terminal renderers have to manage it.

The shape of the problem here is the same as the Clay critique: a
layout engine designed for a streaming UI imposes its mental model on
a static renderer, where a much smaller, less general primitive would
do. The Sparkles `core-cli` `prettyPrint` module solves a similar
problem with direct integer arithmetic over an output range, with no
intermediate tree and no allocation; that style of code is awkward to
reach for once Yoga is in the dependency graph.

### Compared to Alternatives

- **[Clay](./clay.md)**. Clay's pitch is "much faster, single-header,
  zero dependencies, simplified flex model." Yoga's counter-pitch is
  "faithful CSS, ten years of production hardening, identical across
  ten hosts." For a single-host project Clay's speed advantage is
  real but rarely matters in absolute terms; for a multi-host project
  Yoga's fidelity advantage is decisive. Clay produces a flat
  render-command array; Yoga annotates the input tree and the host
  walks it.
- **Ratatui's `Constraint` system** ([../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)).
  Not a comparable layout _engine_ -- Ratatui's constraint solver is
  a one-shot rectangle splitter, not a tree-aware Flexbox
  implementation. But for the terminal-rendering use case it is the
  honest comparison: Yoga gives you a Flexbox subset, Ratatui gives
  you `Length(n) | Fill(weight) | Percentage(p) | Min(n) | Max(n)`
  and resolves it in linear time without any tree-building.
- **`stretch` (Rust) / `taffy` (Rust)**. Two third-party Rust ports
  of the Yoga algorithm. `taffy` (the active fork of `stretch`) is
  the canonical Rust Flexbox engine and is used by Bevy's UI and
  Dioxus. API-wise it is very close to Yoga's C++ API, with Rust
  idioms.
- **Native toolkit engines (Auto Layout, ConstraintLayout)**.
  Platform-bound, much more powerful for arbitrary constraint
  problems (the Cassowary system underneath Auto Layout can express
  arbitrary linear inequalities), but not portable. Yoga's pitch is
  "a subset that is identical everywhere."

---

## References

### Primary

- **Repository**: <https://github.com/facebook/yoga>
- **Documentation site**: <https://www.yogalayout.dev/>
- **Interactive playground**: <https://www.yogalayout.dev/playground>
- **API docs (per binding)**: <https://www.yogalayout.dev/docs/about-yoga>
- **Release notes / changelog**: <https://github.com/facebook/yoga/releases>

### Spec / Algorithm

- **CSS Flexible Box Layout Module Level 1 (W3C)**: <https://www.w3.org/TR/css-flexbox-1/>
- **Yoga's documented Flexbox differences**: <https://github.com/facebook/yoga/blob/main/README.md>

### Bindings

- **Native C / C++** (in-tree): `yoga/Yoga.h`, `yoga/Yoga.cpp`
- **Java** (in-tree, for Litho/Android): `java/`
- **Kotlin** (Android): wraps the Java surface
- **`YogaKit`** (Obj-C, for ComponentKit/iOS): `YogaKit/`
- **`yoga-layout`** (npm, JS/TS, used by Ink): <https://www.npmjs.com/package/yoga-layout>
- **`taffy`** (Rust port, used by Bevy/Dioxus): <https://github.com/DioxusLabs/taffy>

### Notable Adopters

- **React Native**: <https://reactnative.dev/> -- Yoga's flagship use case.
- **Litho**: <https://fblitho.com/> -- Facebook's Android UI framework.
- **ComponentKit**: <https://componentkit.org/> -- Facebook's iOS UI framework.
- **Ink** ([../tui-libraries/ink.md](../tui-libraries/ink.md)) -- React for CLIs, with Yoga doing the terminal layout.

### History

- **Original `css-layout` repository (archived)**: predecessor JS implementation, ca. 2014-2015.
- **Yoga 2.0 announcement (June 2023)**: <https://github.com/facebook/yoga/releases/tag/v2.0.0>
- **Yoga 3.0 announcement (March 2024)**: <https://github.com/facebook/yoga/releases/tag/v3.0.0>
- **Yoga 3.2 announcement (December 2024)**: <https://github.com/facebook/yoga/releases/tag/v3.2.0>

### Cross-References

- [clay.md](./clay.md) -- the other Flexbox-style layout engine in this
  catalog, comparing favourably on raw speed and macro-DSL ergonomics
  but with a simplified flex model and a renderer-emit-commands
  philosophy where Yoga annotates an input tree.
- [../tui-libraries/ink.md](../tui-libraries/ink.md) -- the production
  case study for Yoga in a terminal-CLI context. Every `<Box>` is a
  `YGNode`; every `<Text>` is a Yoga leaf with a custom
  `YGMeasureFunc` for cell-aware widths.
- [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md) -- the
  natural contrast: a constraint-based one-shot box splitter rather
  than a tree-walking Flexbox engine. For static terminal output,
  Ratatui's model is much closer to the natural shape of the problem.
- [../tui-libraries/textual.md](../tui-libraries/textual.md) -- a
  Python TUI framework that builds its own CSS-subset layout engine
  rather than reusing Yoga; useful as a third design point.
- [../tui-libraries/ftxui.md](../tui-libraries/ftxui.md) -- C++ TUI
  with `hbox`/`vbox`/`flex` primitives that occupy a similar design
  space to Yoga's Flexbox subset but with a much smaller surface.
