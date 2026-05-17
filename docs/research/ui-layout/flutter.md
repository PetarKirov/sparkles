# Flutter (Dart)

Google's portable UI toolkit, built around a one-pass constraint-propagation layout
protocol summarised by the slogan _"Constraints go down. Sizes go up. Parent sets
position."_ A retained-mode widget tree compiles into an underlying render-object tree
that performs all layout in a single recursive walk.

| Field            | Value                                                                                 |
| ---------------- | ------------------------------------------------------------------------------------- |
| Language         | Dart                                                                                  |
| License          | BSD-3-Clause                                                                          |
| Repository       | <https://github.com/flutter/flutter>                                                  |
| Documentation    | <https://docs.flutter.dev>                                                            |
| Version snapshot | Flutter docs reflect 3.41.5 as of May 2026; 3.44 targeted the May 2026 release window |
| First Release    | Sky / Flutter announced 2015; 1.0 in December 2018                                    |
| Renderer         | Impeller (default since 3.10 / 2023); Skia legacy path                                |
| Used By          | Google Pay, BMW iX app, Alibaba Xianyu, eBay Motors, Toyota IVI                       |

---

## Overview

### What It Is

Flutter is Google's cross-platform UI framework. It targets iOS, Android, web, Windows,
macOS, Linux, and embedded devices from a single Dart codebase, rendering every pixel
itself rather than wrapping native platform widgets. The layout system at the heart of
Flutter is the focus of this document: a strict, deterministic, single-pass constraint
protocol that decides where every widget sits and how big it is.

### What It Solves

Cross-platform UI frameworks historically had to choose between two unsatisfying
options: wrap native widgets (and inherit their idiosyncrasies and platform drift), or
draw everything custom and pay the cost of reinventing layout, accessibility,
theming, and input. Flutter chose the second path and committed fully -- the framework
ships with its own widget set, its own text shaping, its own scrolling physics, and its
own layout algorithm.

For layout specifically, Flutter solves a problem that web CSS, Auto Layout, and
WPF/XAML all struggle with: making the layout algorithm _predictable_ and _bounded_ in
time. CSS reflow is famously hard to reason about; Auto Layout solves a constraint
system that can be slow or ambiguous; WPF performs two full passes. Flutter pins down
exactly one rule: each render object is visited once, given constraints from its
parent, returns a size, and the parent positions it. Everything else falls out of that.

### Design Philosophy

Flutter's layout philosophy can be expressed in three principles.

1. **Single-pass layout.** A render object is laid out exactly once per frame. There is
   no measure-then-arrange, no constraint solver, no reflow. The render tree is walked
   top-down with constraints; sizes propagate back up; parents position children.

2. **Constraints are passed by value.** A `BoxConstraints` value -- four doubles, plus
   helpers -- is passed from parent to child. The child cannot ask its parent any
   questions, cannot peek at siblings, and cannot know its own position. It just
   receives constraints and returns a size that satisfies them.

3. **Composition over inheritance.** Layout behaviour is _composed_ from small,
   single-purpose widgets. `Padding` adds padding. `Center` centres. `SizedBox`
   imposes a tight size. `Expanded` claims remaining flex space. A complex layout is a
   tree of these primitives, not a single configurable container with many flags.

### History

- **2015 -- Sky.** Announced at the Dart Developer Summit as "Sky", an experiment in
  running Dart UI at 120 Hz. The render-object layout protocol existed from the
  earliest prototypes.
- **2017 -- Flutter alpha.** Rebranded as Flutter; iOS/Android targets; `Material`
  and `Cupertino` widget catalogues appeared.
- **December 2018 -- Flutter 1.0.** First stable release.
- **2021-2022 -- 2.0 / 3.0.** Stable web; stable macOS and Linux desktop.
- **2023 -- Impeller default on iOS.** New renderer precompiles shaders to eliminate
  jank, replacing the Skia backend.
- **2024-2025 -- 3.16-3.27.** Impeller default on Android; finer-grained slivers.

Production users include Google Pay, the BMW iX companion app, Alibaba's Xianyu
marketplace, eBay Motors, and Toyota's IVI cockpit system.

### Comparison to TUI Frameworks

For terminal-UI comparators see [Ratatui](../tui-libraries/ratatui.md) and
[Ink](../tui-libraries/ink.md). Ratatui uses an immediate-mode constraint solver
(Cassowary via the `kasuari` crate) where the application explicitly splits a
rectangle into sub-rectangles each frame; Ink uses Flexbox via Yoga. Flutter's
constraint protocol is closer in spirit to Ratatui's "give me a rect" model than to
Ink's CSS-style cascade -- but Flutter goes further by formalising the contract
between every parent and every child as a typed value object.

---

## Layout Model

### The Core Rule

The Flutter layout system is summarised on a single page of the official docs by
three sentences:

> **Constraints go down. Sizes go up. Parent sets position.**

Each phrase corresponds to a step of the layout algorithm.

1. **Constraints go down.** A parent calls `child.layout(constraints,
parentUsesSize: bool)`. The `constraints` argument is a `BoxConstraints` -- four
   doubles, `minWidth`/`maxWidth`/`minHeight`/`maxHeight`. The child cannot peek at its
   parent, siblings, or position. All it gets is the constraint envelope.

2. **Sizes go up.** Inside `performLayout()`, the child first lays out its own children
   (passing them whatever constraints it sees fit) and then sets `this.size` to a
   `Size` value. The size _must_ satisfy the constraints passed in. If the child sets
   a size outside the constraint envelope, Flutter throws in debug mode.

3. **Parent sets position.** After all children return their sizes, the parent walks
   them and assigns `child.parentData.offset` to position each one. Children never know
   where they are; only the parent knows.

This three-step protocol is _the entire layout algorithm_. Every Row, Column, Stack,
Padding, Container, custom widget -- everything -- is implemented in terms of this
contract.

### BoxConstraints

```dart
class BoxConstraints {
  const BoxConstraints({
    this.minWidth = 0.0,
    this.maxWidth = double.infinity,
    this.minHeight = 0.0,
    this.maxHeight = double.infinity,
  });

  // A constraint is "tight" if min == max on the relevant axis.
  bool get hasTightWidth  => minWidth  >= maxWidth;
  bool get hasTightHeight => minHeight >= maxHeight;
  bool get isTight        => hasTightWidth && hasTightHeight;

  // A constraint is "bounded" if max is finite.
  bool get hasBoundedWidth  => maxWidth  < double.infinity;
  bool get hasBoundedHeight => maxHeight < double.infinity;

  // Helper constructors.
  BoxConstraints.tight(Size size);
  BoxConstraints.loose(Size size);
  BoxConstraints.expand({double? width, double? height});
  BoxConstraints.tightFor({double? width, double? height});
  BoxConstraints.tightForFinite({double width = ..., double height = ...});
}
```

The terminology matters. A widget receiving _tight_ constraints has its size fixed by
the parent (`min == max`). A widget receiving _loose_ constraints has `min == 0` and
some finite `max`. A widget receiving _unbounded_ constraints has `max == infinity` --
this is what scrollables pass down on their scroll axis.

Most layout bugs in Flutter applications come from confusing these three categories.
"Why doesn't my `Container(width: 100)` show as 100 pixels?" -- because the parent
imposed _tight_ constraints, and the child's `width` request is just a hint.

### The RenderBox.layout Method

Underneath the widget tree is a parallel _render tree_ of `RenderObject` instances.
Box-protocol render objects extend `RenderBox`. The layout entry point is non-virtual:

```dart
// In RenderObject (simplified):
void layout(Constraints constraints, {bool parentUsesSize = false}) {
  // 1. Short-circuit if nothing changed and parent doesn't need our size.
  if (!_needsLayout &&
      constraints == _constraints &&
      !parentUsesSize) {
    return;
  }
  _constraints = constraints;
  // 2. Delegate to subclass-specific layout.
  performLayout();
  _needsLayout = false;
}
```

Subclasses override `performLayout()`:

```dart
class RenderPadding extends RenderShiftedBox {
  @override
  void performLayout() {
    final BoxConstraints constraints = this.constraints;
    if (child == null) {
      size = constraints.constrain(Size(
        _resolvedPadding!.horizontal,
        _resolvedPadding!.vertical,
      ));
      return;
    }
    final BoxConstraints innerConstraints =
        constraints.deflate(_resolvedPadding!);
    child!.layout(innerConstraints, parentUsesSize: true);
    final BoxParentData childParentData = child!.parentData! as BoxParentData;
    childParentData.offset = Offset(
      _resolvedPadding!.left,
      _resolvedPadding!.top,
    );
    size = constraints.constrain(Size(
      _resolvedPadding!.horizontal + child!.size.width,
      _resolvedPadding!.vertical   + child!.size.height,
    ));
  }
}
```

Three things to notice:

1. `constraints.deflate(padding)` shrinks the constraints by the padding before passing
   them down. The child sees a smaller envelope, not the same envelope plus a flag.
2. `parentUsesSize: true` tells the layout system that this parent looks at the
   child's size after the call. Flutter uses this flag for relayout-boundary
   optimisations: if a child's size doesn't affect its parent, a relayout can stop at
   the child.
3. `size = constraints.constrain(...)` clamps the computed size back into the
   parent's envelope. This is how Flutter guarantees every render object returns a
   size that satisfies its constraints, even if the math says otherwise.

### Relayout Boundaries

A subtle but important optimisation: Flutter does not always walk the full tree on
every layout pass. A `RenderObject` is a _relayout boundary_ if its size is fully
determined by its constraints (i.e., the parent passed `parentUsesSize: false` _or_
the constraints are tight). Inside a relayout boundary, marking a descendant dirty
does not propagate the dirty flag up past the boundary -- the next layout pass starts
at the boundary, not the root.

This is what makes Flutter's "rebuild the whole UI on every frame" performance model
work. The vast majority of the tree is sitting inside a relayout boundary that does
not need to be revisited.

### Intrinsics

The constraint protocol has one major weakness: a child cannot ask its parent
questions like "how wide will you let me be?" before deciding its own size. To support
widgets that genuinely need this information -- e.g., a `Table` that wants its columns
all to be the same width, or an `IntrinsicHeight` row where every child must match the
tallest -- Flutter offers _intrinsic dimensions_.

```dart
abstract class RenderBox extends RenderObject {
  double getMinIntrinsicWidth(double height);
  double getMaxIntrinsicWidth(double height);
  double getMinIntrinsicHeight(double width);
  double getMaxIntrinsicHeight(double width);
}
```

These methods ask: "If you had unlimited height, what is the smallest width you could
reasonably take?" (and three variants thereof). They are computed _separately from
layout_ and are conceptually free to recurse through the whole subtree.

That recursion is exactly the problem. Computing `IntrinsicHeight` of a `Row` with N
children traverses each child's subtree to ask for its intrinsic height. If one of
those children is itself an `IntrinsicHeight` wrapping another `Row`, the cost
explodes to O(N^2) or worse. The Flutter docs explicitly warn:

> Intrinsic operations are relatively expensive, because they require performing
> layout in a special mode... Avoid using them in performance-critical code.

In practice, `IntrinsicWidth`/`IntrinsicHeight` are useful for forms and small
toolbars where you genuinely need every child to match. They are catastrophic inside
`ListView` or `Column`s with hundreds of children.

### Tight vs Loose vs Unbounded: The Three Worlds

A widget's behaviour depends fundamentally on which category of constraints it
receives:

| Category      | Definition                             | Typical Parent                                                                                                        | Child Behaviour                            |
| ------------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------ |
| **Tight**     | `min == max` on both axes              | screen, `SizedBox`, `Expanded`                                                                                        | Size is dictated; `width:` is ignored      |
| **Loose**     | `min == 0`, `max` finite               | `Center`, `Align`, `Padding`                                                                                          | Free within envelope; child decides        |
| **Unbounded** | `max == infinity` on at least one axis | `ListView`, `SingleChildScrollView`, `Column` (cross-axis is fine; main axis can be unbounded if parent is unbounded) | Child must be intrinsic-sized or it errors |

The 28 worked examples in Flutter's `understandingconstraints` doc all turn on which
category the constraint falls into. Two especially load-bearing examples:

- **Example 2**: `Container(width: 100, height: 100, color: red)` as the root of a
  page. The screen passes _tight_ constraints (= screen size). The Container's `width`
  and `height` arguments are hints to be satisfied _if possible_, but tight constraints
  override them. Result: the red box fills the screen.
- **Example 14**: `UnconstrainedBox(child: Container(width: double.infinity))`. The
  UnconstrainedBox unties the parent's constraints (passes unbounded), and the
  Container then tries to be infinity wide -- which throws in debug mode.

### Multi-Child Layout: Flex

`Row` and `Column` extend `Flex`. The layout algorithm in `RenderFlex.performLayout`
runs in two passes over its children:

```
Pass 1: Lay out all *non-flex* children with the cross-axis constraint and an
        unbounded main axis. Sum their main-axis sizes.

Pass 2: Compute remaining main-axis space (= maxMainAxisExtent - sum from Pass 1).
        Distribute remaining space across *flex* children proportional to their flex
        factors. Lay out each flex child with TIGHT main-axis constraints equal to its
        allocation (or LOOSE if it's a Flexible with fit: FlexFit.loose).

Pass 3: Position all children along the main axis according to MainAxisAlignment.
        Set this.size based on MainAxisSize.
```

Key participants:

- **`Expanded(child: ...)`** = `Flexible(fit: FlexFit.tight, ...)`. Forces the child
  to fill its allocation.
- **`Flexible(child: ...)`** = `Flexible(fit: FlexFit.loose, ...)`. Lets the child be
  smaller than its allocation if it wants.
- **`MainAxisAlignment`**: `start`, `end`, `center`, `spaceBetween`, `spaceAround`,
  `spaceEvenly`. Controls how leftover space (after laying out non-flex children) is
  distributed.
- **`CrossAxisAlignment`**: `start`, `end`, `center`, `stretch`, `baseline`.
- **`MainAxisSize`**: `max` (Flex fills available main-axis space) or `min` (Flex is
  only as large as its children).

The most common Flex error -- "RenderFlex overflowed by N pixels" -- happens when
non-flex children sum to more main-axis space than the Flex received. The standard
fix is to wrap one of them in `Expanded`/`Flexible`, or to wrap text children in
`Expanded(child: Text(...))` so they receive a bounded width and can wrap.

---

## Widget Catalogue (Layout)

### Single-Child Layout Primitives

| Widget                 | What It Does                                                       |
| ---------------------- | ------------------------------------------------------------------ |
| `Container`            | Composite: padding + border + decoration + alignment + transform.  |
| `Padding`              | Wraps child with `EdgeInsets`. Shrinks constraints by padding.     |
| `Center`               | Aligns child to centre. Passes loose constraints down.             |
| `Align`                | Centre with arbitrary `Alignment(x, y)`. Loose constraints.        |
| `SizedBox`             | Imposes a tight size (or one dimension tight, other pass-through). |
| `ConstrainedBox`       | Combines parent's constraints with additional ones (intersection). |
| `LimitedBox`           | Only applies its `maxWidth/maxHeight` when parent is unbounded.    |
| `FractionallySizedBox` | Sizes child as fraction of parent (`widthFactor`, `heightFactor`). |
| `AspectRatio`          | Sizes child to a given aspect ratio.                               |
| `Transform`            | Applies matrix transform; does not affect layout.                  |
| `FittedBox`            | Scales child to fit (`BoxFit.contain` / `cover` / etc.).           |
| `OverflowBox`          | Allows child to exceed parent's bounds without warning.            |
| `IntrinsicWidth`       | Forces child to its `getMaxIntrinsicWidth`. Expensive.             |
| `IntrinsicHeight`      | Forces child to its `getMaxIntrinsicHeight`. Expensive.            |

### Multi-Child Layout Primitives

| Widget                   | What It Does                                                         |
| ------------------------ | -------------------------------------------------------------------- |
| `Row`                    | Flex with horizontal main axis.                                      |
| `Column`                 | Flex with vertical main axis.                                        |
| `Flex`                   | Configurable-axis row/column (rarely used directly).                 |
| `Stack`                  | Z-stacked children; positioning via `Positioned`.                    |
| `Wrap`                   | Like a `Row` that wraps to a new line/column when full.              |
| `Table`                  | Grid with column/row sizing (`FixedColumnWidth`, `FlexColumnWidth`). |
| `CustomMultiChildLayout` | Caller-controlled layout via a `MultiChildLayoutDelegate`.           |
| `IndexedStack`           | Stack that shows one child at a time (others still laid out).        |

### Flex Modifiers

| Widget     | What It Does                                                        |
| ---------- | ------------------------------------------------------------------- |
| `Expanded` | Mandates a flex factor with `FlexFit.tight` (must fill allocation). |
| `Flexible` | Mandates a flex factor with `FlexFit.loose` (may be smaller).       |
| `Spacer`   | `Expanded` with no child; just claims space.                        |

### Slivers (Scroll-Aware Layout)

For scrollable layouts, the box protocol is replaced by the _sliver protocol_, which
uses a richer constraint type (`SliverConstraints`) that includes scroll offset and
viewport size. Slivers are the building blocks of `CustomScrollView`.

```dart
CustomScrollView(
  slivers: [
    SliverAppBar(
      pinned: true,
      expandedHeight: 200,
      flexibleSpace: FlexibleSpaceBar(title: Text('Title')),
    ),
    SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) => ListTile(title: Text('Item $i')),
        childCount: 1000,
      ),
    ),
    SliverGrid(
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
      ),
      delegate: SliverChildBuilderDelegate(
        (context, i) => Card(child: Text('Tile $i')),
        childCount: 60,
      ),
    ),
    SliverToBoxAdapter(child: Container(height: 100, color: Colors.amber)),
  ],
)
```

Slivers are critical because they enable lazy materialisation: only the slivers (and
the children within them) that intersect the viewport are laid out and painted. A
1,000,000-item `SliverList` is feasible because off-screen items never run through
the layout pipeline.

Common slivers: `SliverList`, `SliverGrid`, `SliverFixedExtentList`, `SliverAppBar`,
`SliverPersistentHeader`, `SliverToBoxAdapter`, `SliverFillRemaining`,
`SliverMainAxisGroup`, `SliverCrossAxisGroup`, `SliverPadding`.

### Per-Element Properties

Unlike WPF, Flutter does not attach per-element layout properties via attached
properties. Instead, each modifier is its own widget that wraps the child:

```dart
// WPF style (attached):  Grid.Row="1" Grid.Column="2" Margin="5"
// Flutter style (wrap):
Padding(
  padding: EdgeInsets.all(5),
  child: GridItem(row: 1, column: 2, child: ...),
)
```

The Flutter approach forces every layout decoration to be an explicit, visible widget
in the tree. The cost is verbosity; the benefit is no hidden state and a tree that
exactly mirrors the rendered output.

---

## Code Examples

### Example 1: Dashboard With Flex

A two-column dashboard built from `Row`, `Column`, `Expanded`, and `Padding`. This is
the bread-and-butter Flutter layout.

```dart
import 'package:flutter/material.dart';

class Dashboard extends StatelessWidget {
  const Dashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header card -- fixed height, full width.
          SizedBox(
            height: 80,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.dashboard, size: 32),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Text('Welcome back',
                              style: TextStyle(fontSize: 18)),
                          Text('Pipeline status: green',
                              style: TextStyle(color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Body -- two columns sharing remaining vertical space.
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 1,
                  child: Card(
                    child: ListView(
                      padding: const EdgeInsets.all(8),
                      children: const [
                        ListTile(title: Text('Overview')),
                        ListTile(title: Text('Builds')),
                        ListTile(title: Text('Logs')),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  flex: 3,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text('System Overview',
                              style: TextStyle(
                                fontSize: 20, fontWeight: FontWeight.bold)),
                          SizedBox(height: 16),
                          Text('CPU: 23%   MEM: 4.2 GB   Disk: 87%'),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

What this example demonstrates:

- The header is a `SizedBox(height: 80, ...)`: a tight vertical constraint, but
  horizontal stretches because the parent `Column` has `crossAxisAlignment: stretch`.
- `Expanded(flex: 1)` and `Expanded(flex: 3)` divide the body row 1:3 -- the sidebar
  takes a quarter, the main pane takes three quarters.
- The body `Row` is wrapped in an `Expanded` so it consumes all remaining vertical
  space inside the outer `Column`.
- `SizedBox(width: 16)` and `SizedBox(height: 16)` serve as gutters -- a more
  type-safe alternative to margin.

### Example 2: A Custom RenderBox

When you need a layout that no built-in widget expresses, you drop down to the
render-object protocol directly. Here is a single-child widget that lays its child
out with the parent's constraints but vertically centres it inside a fixed-height
band, ignoring the child's height. (This is what `Center` plus `SizedBox(height: H)`
does, but written as a single render object.)

```dart
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class BandedCenter extends SingleChildRenderObjectWidget {
  const BandedCenter({super.key, required this.bandHeight, super.child});

  final double bandHeight;

  @override
  RenderBandedCenter createRenderObject(BuildContext context) =>
      RenderBandedCenter(bandHeight: bandHeight);

  @override
  void updateRenderObject(BuildContext context, RenderBandedCenter renderObject) {
    renderObject.bandHeight = bandHeight;
  }
}

class RenderBandedCenter extends RenderShiftedBox {
  RenderBandedCenter({double bandHeight = 0, RenderBox? child})
      : _bandHeight = bandHeight,
        super(child);

  double _bandHeight;
  double get bandHeight => _bandHeight;
  set bandHeight(double value) {
    if (_bandHeight == value) return;
    _bandHeight = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    // 1. Lay out the child with loose constraints, height capped at bandHeight.
    final BoxConstraints childConstraints = BoxConstraints(
      minWidth: constraints.minWidth,
      maxWidth: constraints.maxWidth,
      minHeight: 0,
      maxHeight: bandHeight,
    );
    if (child != null) {
      child!.layout(childConstraints, parentUsesSize: true);
      // 2. Position the child centred vertically within our band.
      final BoxParentData parentData = child!.parentData! as BoxParentData;
      parentData.offset = Offset(
        0,
        (bandHeight - child!.size.height) / 2,
      );
    }
    // 3. Our own size: full width from constraints, bandHeight tall.
    size = constraints.constrain(Size(constraints.maxWidth, bandHeight));
  }

  @override
  double computeMinIntrinsicHeight(double width) => bandHeight;

  @override
  double computeMaxIntrinsicHeight(double width) => bandHeight;
}
```

Three things stand out:

1. The implementation lives entirely in `performLayout()`. There is no measure pass,
   no second arrange step. The render object does everything in one call.
2. Constraints flow down (`child.layout(childConstraints)`); the child's size flows
   back up (`child!.size.height`); the parent (us) sets the child's position
   (`parentData.offset = ...`); we then set our own size.
3. We override `computeMin/MaxIntrinsicHeight` so that widgets that ask "how tall do
   you want to be?" (e.g., an enclosing `IntrinsicHeight`) get a sensible answer
   without needing to lay us out.

### Example 3: Slivers for Lazy Scrolling

A long news feed with a collapsible header and a grid section, lazily materialised:

```dart
import 'package:flutter/material.dart';

class NewsFeedScreen extends StatelessWidget {
  const NewsFeedScreen({super.key, required this.articles});

  final List<Article> articles;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          // Collapsible header that shrinks as you scroll.
          SliverAppBar(
            pinned: true,
            expandedHeight: 200,
            flexibleSpace: FlexibleSpaceBar(
              title: const Text('News'),
              background: Image.network(
                'https://example.com/banner.jpg',
                fit: BoxFit.cover,
              ),
            ),
          ),
          // A trending grid: lazily materialised tiles.
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.5,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) => _TrendingCard(article: articles[i]),
                childCount: 6,
              ),
            ),
          ),
          // The main feed: lazily materialised list rows.
          SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) {
                final article = articles[i + 6];
                return _FeedRow(article: article);
              },
              childCount: articles.length - 6,
            ),
          ),
        ],
      ),
    );
  }
}

class _TrendingCard extends StatelessWidget {
  const _TrendingCard({required this.article});
  final Article article;
  @override
  Widget build(BuildContext context) =>
      Card(child: Center(child: Text(article.title)));
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.article});
  final Article article;
  @override
  Widget build(BuildContext context) =>
      ListTile(title: Text(article.title), subtitle: Text(article.summary));
}

class Article {
  Article(this.title, this.summary);
  final String title;
  final String summary;
}
```

Slivers solve a problem the box protocol cannot: composing multiple lazily-laid-out
scrollable regions inside a single scrollable. The header, the grid, and the list all
share one scroll position, but each one materialises its own children on demand. The
sliver protocol does this by passing a `SliverConstraints` -- containing scroll offset,
remaining viewport extent, axis direction, and cache extent -- to each sliver in
turn, and each sliver reports back a `SliverGeometry` describing how much main-axis
extent it consumed and how it interacts with the viewport.

### Example 4: Reading and Reacting to Constraints

The `LayoutBuilder` widget surfaces the constraints from the layout pass into the
build pass, so you can branch your widget tree based on available space:

```dart
import 'package:flutter/material.dart';

class ResponsiveLayout extends StatelessWidget {
  const ResponsiveLayout({super.key});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 600) return const _PhoneLayout();
        if (constraints.maxWidth < 1000) return const _TabletLayout();
        return const _DesktopLayout();
      },
    );
  }
}
```

`LayoutBuilder` is the principled escape hatch from "I want to know how much space
I have before deciding what to build". The cost is that the widget's build runs inside
the layout pass, so it cannot return a widget that depends on its own size (the
algorithm would not terminate).

---

## Common Gotchas

### Unbounded Constraints in the Scroll Axis

The most-cited Flutter error is `Vertical viewport was given unbounded height.` It
happens when a scrollable (`ListView`, `SingleChildScrollView`) tries to lay out a
descendant that needs a finite main-axis constraint -- typically an `Expanded`:

```dart
SingleChildScrollView(
  child: Column(children: [
    Expanded(child: SomeWidget()),  // Expanded needs a finite parent main-axis.
  ]),
)  // ERROR.
```

Fix: provide a finite height via `SizedBox`/`ConstrainedBox`, or replace `Expanded`
with `Flexible` (loose fit).

### Row/Column Overflow

`A RenderFlex overflowed by 42 pixels on the right.` -- a `Row` got non-flex children
summing to more main-axis space than it received. Fix: wrap one child in `Expanded`,
or wrap text children in `Expanded(child: Text(...))` so they get a finite `maxWidth`
and wrap.

### Container's `width` Is a Hint

A `Container(width: 100)` inside a `Row` does not produce a 100-pixel box. Loose
parent constraints mean `width` is just a hint, and an undecorated `Container` sizes
to fit its child. Fix: use `SizedBox(width: 100, child: Container(...))` -- `SizedBox`
imposes a tight constraint that overrides the loose parent constraints.

### Intrinsic Dimensions Are O(N^2)

`IntrinsicHeight` inside a `Row` walks every descendant's intrinsic-height
implementation, which itself may recurse. A frequent source of frame-time
regressions. Prefer explicit `SizedBox` heights, or use intrinsics only at the top
of a small subtree.

### LayoutBuilder Causes Rebuilds

`LayoutBuilder` reruns its builder whenever constraints change. Putting it high in a
tree means every resize causes a full subtree rebuild. Keep it low.

---

## Rendering: A Brief Note on Impeller

Flutter's renderer is largely orthogonal to its layout system, but worth a paragraph
for completeness. Until 2023, Flutter rendered via _Skia_ -- the same 2D library that
powers Chrome. Skia compiled shaders lazily at runtime, which produced visible jank
on first display ("shader compilation jank"). Impeller replaces Skia with a renderer
designed around precompiled shaders, Metal/Vulkan/OpenGL backends, and a more
predictable performance profile. As of Flutter 3.27, Impeller is default on iOS,
Android, and is stabilising on macOS.

This matters for layout only insofar as Impeller does not change the layout protocol
-- the `RenderObject` tree's `performLayout` calls are unchanged. The change is purely
in the paint phase that consumes the laid-out tree.

---

## Strengths

- **Predictable single-pass layout.** Every widget is visited exactly once per frame
  during layout. The algorithm's time complexity is straightforward O(N) in the
  number of render objects (with the caveat that `IntrinsicWidth`/`Height` introduce
  extra passes). This is dramatically simpler than the two-pass WPF model or the
  iterative constraint solving of CSS reflow.
- **The constraint protocol is clean.** Once "constraints down, sizes up, parent
  positions" clicks, every layout widget makes sense. There is no special "panel
  protocol" vs "control protocol" -- everything is a `RenderBox` (or `RenderSliver`)
  and obeys the same rules.
- **Relayout boundaries make rebuilds cheap.** A tight-constrained subtree is a
  relayout boundary; marking a deep descendant dirty does not bubble up. Combined
  with `const` widgets and the element-reconciliation system, this is what makes
  60 Hz UIs feasible from a "rebuild the world" programming model.
- **Composable primitives.** `Padding`, `Center`, `SizedBox`, `Expanded`, and a
  handful of others compose to express any conceivable layout. The widget tree
  reflects the rendered output exactly -- no hidden state, no implicit defaults.
- **Slivers unlock scrollable composition.** The sliver protocol is one of the most
  underappreciated parts of Flutter -- it lets you build a screen with a collapsible
  header, a grid, a list, a footer, and an infinite-scroll section all sharing one
  scroll position, all lazily materialised.
- **Excellent debug tooling.** `flutter inspector` shows the live widget tree;
  `debugDumpRenderTree()` prints the render objects and their sizes; `debugPaintSizeEnabled`
  overlays bounding boxes. Layout errors come with a "stack trace" of widgets that
  contributed to the failed constraint.
- **Cross-platform consistency.** The same layout code runs identically on iOS,
  Android, web, Windows, macOS, Linux, and embedded. No platform-specific layout
  quirks.

---

## Weaknesses

- **Intrinsic dimensions are a performance landmine.** Using `IntrinsicHeight` or
  `IntrinsicWidth` -- often the most "obvious" way to express "make these the same
  size" -- can silently turn O(N) layout into O(N^2). The documentation warns about
  it, but the API surface does not.
- **Unbounded-constraint errors are confusing.** "Vertical viewport was given
  unbounded height" is not a useful error for someone who hasn't internalised the
  constraint categories. The mental model has a steep onboarding cost.
- **No attached properties means more nesting.** Where WPF expresses a button's
  margin and grid position with five attributes on one element, Flutter wraps the
  button in `Padding`, then `Align`, then `Expanded` -- three additional tree levels.
  The tree is faithful but verbose.
- **No declarative layout language.** Unlike XAML, Flutter has no markup; you compose
  widgets in Dart. This is great for refactoring and bad for designers who want a
  visual designer that round-trips with code.
- **Container's hint behaviour confuses newcomers.** `Container(width: 100)` does not
  always produce a 100-pixel box; whether it does depends on the parent's constraint
  category. The `SizedBox` idiom solves this but is one of the first things experts
  internalise that beginners do not.
- **Layout cannot consult the platform.** A Flutter widget cannot ask the host
  platform's text-rendering library "how wide is this string in 12pt Verdana?" --
  Flutter draws its own text, so this works inside Flutter but cannot be deferred to
  platform metrics. (This is also a strength: cross-platform consistency.)
- **Heavyweight runtime.** Flutter's layout system is part of a 5+ MB framework with
  its own renderer, text shaper, and accessibility tree. For UIs that could be a few
  hundred lines of HTML, Flutter is overkill.

---

## Lessons for D / Sparkles

The Flutter constraint protocol translates _remarkably_ well to terminal UIs. Three
specific patterns are worth highlighting.

### Constraints-Down-Sizes-Up Maps Directly to Terminal Tables

A terminal table or panel layout is exactly the problem the box protocol solves:
"given this rectangular envelope, how big does each child want to be, and where do I
position them?" A D port of the box protocol could look like:

```d
struct BoxConstraints {
    ushort minWidth, maxWidth;
    ushort minHeight, maxHeight;

    bool isTight() const => minWidth == maxWidth && minHeight == maxHeight;
    bool isBoundedWidth() const => maxWidth < ushort.max;

    Size constrain(Size unconstrained) const {
        return Size(
            clamp(unconstrained.width, minWidth, maxWidth),
            clamp(unconstrained.height, minHeight, maxHeight),
        );
    }
}

// Single-pass layout via duck-typed renderObject:
enum isRenderBox(T) = is(typeof((T t, BoxConstraints c, ref Buffer buf) {
    auto size = t.layout(c);
    t.paint(buf, Position(0, 0));
}));
```

Because terminals have a single, fixed cell size and small dimensions, the constraint
arithmetic is simpler than Flutter's (`ushort` instead of `double`; no sub-pixel
rounding; no relayout boundaries because the whole screen is small enough to relayout
in a single millisecond).

### Static Layouts Become CTFE-Friendly

Flutter performs all layout at runtime because constraints depend on the window size.
For terminal UIs where the table column widths are known at compile time, D's CTFE
can run the entire constraint protocol _at compile time_ -- the box widget's
`performLayout()` is a pure function from constraints to size, which means a
sufficiently-pure tree can fold to a constant.

```d
enum tableLayout = box(
    direction: Direction.row,
    children: [
        box(width: 20),     // sidebar
        box(flexGrow: 1),   // main content
    ],
).layout(BoxConstraints.tight(Size(80, 24)));
// tableLayout is now a compile-time-known array of positioned rects.
```

### Strict Constraint Categories Catch Bugs at Compile Time

Flutter discovers unbounded-constraint errors at runtime. In D, the constraint
category (`tight`, `loose`, `unbounded`) could be a compile-time type parameter, with
template constraints rejecting widgets that need a bounded envelope from an unbounded
parent:

```d
enum ConstraintKind { tight, loose, unbounded }

void layoutFlex(ConstraintKind kind)(Flex flex, BoxConstraints!kind c)
if (kind != ConstraintKind.unbounded)  // Flex cannot accept unbounded main axis.
{
    // ...
}
```

Strict static dispatch like this turns the most painful Flutter runtime error into
a compile-time error.

### Render Objects as Output-Range Consumers

Flutter's `paint(canvas, offset)` maps cleanly onto Sparkles' output-range pattern. A
`RenderBox`-style widget for a terminal can be a pure `@nogc @safe` struct -- the
constraint protocol uses only 4-tuple value types and 2-tuple positions, so no heap
allocations are needed.

---

## References

- **Layout Constraints (the foundational article):**
  <https://docs.flutter.dev/ui/layout/constraints>
- **Layout Cheat Sheet:** <https://docs.flutter.dev/ui/layout>
- **Slivers:**
  - Concept: <https://docs.flutter.dev/ui/layout/scrolling/slivers>
  - `CustomScrollView`: <https://api.flutter.dev/flutter/widgets/CustomScrollView-class.html>
- **API Reference:**
  - `Widget`: <https://api.flutter.dev/flutter/widgets/Widget-class.html>
  - `StatelessWidget`: <https://api.flutter.dev/flutter/widgets/StatelessWidget-class.html>
  - `StatefulWidget`: <https://api.flutter.dev/flutter/widgets/StatefulWidget-class.html>
  - `BoxConstraints`: <https://api.flutter.dev/flutter/rendering/BoxConstraints-class.html>
  - `RenderBox`: <https://api.flutter.dev/flutter/rendering/RenderBox-class.html>
  - `RenderObject`: <https://api.flutter.dev/flutter/rendering/RenderObject-class.html>
  - `Row` / `Column` / `Flex`: <https://api.flutter.dev/flutter/widgets/Flex-class.html>
  - `Expanded` / `Flexible`: <https://api.flutter.dev/flutter/widgets/Expanded-class.html>
  - `Stack` / `Positioned`: <https://api.flutter.dev/flutter/widgets/Stack-class.html>
  - `LayoutBuilder`: <https://api.flutter.dev/flutter/widgets/LayoutBuilder-class.html>
  - `CustomMultiChildLayout`: <https://api.flutter.dev/flutter/widgets/CustomMultiChildLayout-class.html>
- **Rendering pipeline:**
  - Impeller architecture: <https://docs.flutter.dev/perf/impeller>
- **Talks and articles:**
  - Adam Barth, "How Flutter renders widgets" (Google I/O 2019):
    <https://www.youtube.com/watch?v=996ZgFRENMs>
  - "Inside Flutter":
    <https://docs.flutter.dev/resources/inside-flutter>
- **Cross-reference:**
  - Ratatui (Rust TUI, immediate-mode constraint solver):
    [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)
  - Ink (JS TUI, retained-mode Flexbox via Yoga):
    [../tui-libraries/ink.md](../tui-libraries/ink.md)
