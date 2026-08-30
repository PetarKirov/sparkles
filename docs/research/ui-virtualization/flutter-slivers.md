# Flutter — slivers and builder delegates (Dart)

Virtualization as a **layout protocol**: a viewport hands each child a scroll
window, and the child returns how much of itself that window covers. Lists are
just the sliver that happens to build its children lazily.

|                         |                                                                                          |
| ----------------------- | ---------------------------------------------------------------------------------------- |
| **Language**            | Dart                                                                                     |
| **License**             | BSD-3-Clause                                                                             |
| **Repository**          | [flutter/flutter][flutter] (pinned at [`feab40b`][flutter-pin])                          |
| **Documentation**       | [Slivers overview][flutter-docs]                                                         |
| **Category**            | Retained, GPU                                                                            |
| **Rendering model**     | Widget tree → element tree → render tree; slivers laid out against a `SliverConstraints` |
| **Virtualization unit** | Child index, via a `SliverChildDelegate`                                                 |

See also the [UI Layout deep-dive on Flutter](../ui-layout/flutter.md) and
[the Flutter engine's backend seam](../ui-backend-seam/flutter-engine.md).

## Overview

### What it solves

Flutter's ordinary layout is "constraints down, sizes up" over a box protocol,
which cannot express "you are 40 000 logical pixels tall but only 800 of you are
visible, starting at offset 12 400". Slivers are a second layout protocol for
exactly that: `SliverConstraints` carries `scrollOffset`, `remainingPaintExtent`
and `cacheExtent`, and `SliverGeometry` answers with `scrollExtent`,
`paintExtent` and `layoutExtent`.

The consequence is that virtualization is not a list feature — it is available to
any sliver, which is why app bars that shrink on scroll, sticky headers and
lazily-built grids are all the same mechanism.

### Design philosophy

The lazy-building half is factored into a delegate, so _which_ children exist and
_how they are laid out_ stay orthogonal. `SliverChildBuilderDelegate` is the lazy
one; `SliverChildListDelegate` is the eager one; a `SliverList` or `SliverGrid`
takes either.

## How it works

The delegate is a builder from index to widget, with a child count:

```dart
SliverGrid(
  gridDelegate: _gridDelegate,
  delegate: SliverChildBuilderDelegate(
    (BuildContext context, int index) {
       if (index.isEven) {
         return const Text('...');
       }
       return const Spacer();
     },
     semanticIndexCallback: (Widget widget, int localIndex) {
       if (localIndex.isEven) {
         return localIndex ~/ 2;
       }
       return null;
     },
     childCount: 10,
   ),
 ),
```

— [`packages/flutter/lib/src/widgets/scroll_delegate.dart`][flutter-delegate]

`ListView.builder` and `GridView.builder` are thin wrappers that construct this
delegate for you; `ListView(children: [...])` constructs the eager
`SliverChildListDelegate` and is `O(N)`, which is the single most common Flutter
performance mistake.

### The cache extent

The viewport lays out beyond what it paints:

```dart
/// The default value for the cache extent of the viewport.
///
/// This default assumes [CacheExtentStyle.pixel].
static const double defaultCacheExtent = 250.0;
```

— [`packages/flutter/lib/src/rendering/viewport.dart`][flutter-cache]

with a unit selector so the band can be expressed proportionally instead:

```dart
/// The unit of measurement for a [Viewport.cacheExtent].
enum CacheExtentStyle {
  /// Treat the [Viewport.cacheExtent] as logical pixels.
  pixel,
  /// Treat the [Viewport.cacheExtent] as a multiplier of the main axis extent.
  viewport,
}
```

— [`packages/flutter/lib/src/rendering/viewport.dart`][flutter-cache-style]

250 logical pixels of pre-built content is the difference between a scroll that
reveals content and one that reveals blanks, and it is the same knob as WPF's
`CacheLength` and Qt Quick's `cacheBuffer`.

### The semantic index

`semanticIndexCallback` in the snippet above exists because accessibility needs
to say "item 7 of 200" for a child whose position in the _built_ subset is
meaningless. `semanticIndexOffset` composes multiple delegates in one scroll
view. This is the accessibility corner of the
[identity problem](./concepts.md#5-what-breaks): the framework cannot infer an
item's logical index from a realized window, so the delegate carries it
explicitly.

The delegate also owns three cross-cutting policies as flags —
`addAutomaticKeepAlives` (let a child veto being destroyed when it scrolls out),
`addRepaintBoundaries`, and `addSemanticIndexes` — each of which is a decision
about what survives virtualization.

## Analysis

### 1. What the window bounds

Widget building, element inflation, layout, paint, and data access through the
builder. `addAutomaticKeepAlives` deliberately punches a hole in this for
children that must persist (a playing video, an in-progress form).

### 2. How the range is computed

`RenderSliverList` walks: it lays out children outward from the ones it already
has, using `SliverConstraints.scrollOffset` and the geometry each child reports.
Variable heights are native. Because the walk needs an existing child to start
from, a large programmatic jump requires either an anchor or
`SliverFixedExtentList` — the uniform-extent variant, which _can_ divide and is
substantially faster for that reason.

### 3. What survives between frames

The element tree for realized children, kept-alive children outside the window,
and cached geometry. The widget objects themselves are cheap immutable
configurations, so Flutter recycles _elements_, not widgets — the analogue of a
GTK pool one level up.

### 4. How the extent is known

Progressive: `SliverGeometry.scrollExtent` is exact for what has been laid out
and estimated beyond it, which is why a `ListView.builder` with a null
`childCount` has a scrollbar that never quite settles.
`SliverFixedExtentList` and `prototypeItem` exist to make it exact.

### 5. What breaks

- **`ListView(children:)` vs `ListView.builder`** — the eager delegate silently
  defeats the whole mechanism, and the code looks nearly identical.
- **State in scrolled-out children** is destroyed unless `AutomaticKeepAlive`
  opts in, which is a per-child memory cost.
- **Semantic index** must be supplied when the realized subset is not the
  logical list.
- **`shrinkWrap: true`** disables the laziness entirely by forcing the sliver to
  measure all children — a documented but frequently-hit trap.

## Strengths

- Virtualization is a layout protocol, so it composes: headers, grids, and
  bespoke slivers all get it.
- The cache extent is a first-class, unit-selectable knob.
- The eager/lazy choice is a visible type (`SliverChildListDelegate` vs
  `SliverChildBuilderDelegate`), not a hidden heuristic.
- Fixed-extent variants let an application buy exactness back when it can.

## Weaknesses

- Two layout protocols to understand, and their interaction (`shrinkWrap`,
  nested scroll views) is the hardest part of Flutter layout.
- Estimated extents by default.
- Keeping a child alive across scroll is opt-in per child rather than a property
  of the data.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                              | Trade-off                                                             |
| --------------------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------- |
| A separate sliver layout protocol             | Expresses partial visibility of an item larger than the viewport       | A second protocol to learn; box↔sliver boundaries are subtle          |
| Delegate carries the child count and builder  | Eager and lazy are the same shape, chosen by type                      | The eager form is the more obvious spelling and is the common mistake |
| `cacheExtent` in pixels or viewport multiples | One knob covers both fixed and proportional pre-building               | Costs building work the user may never see                            |
| `semanticIndexCallback` on the delegate       | Accessibility indices cannot be derived from a realized window         | Extra API surface most apps never touch                               |
| Recycle elements, not widgets                 | Widgets are cheap immutable configs; elements hold the expensive state | Element lifecycle (`didUpdateWidget`, keys) becomes the mental model  |

## Sources

- [`packages/flutter/lib/src/widgets/scroll_delegate.dart`, `SliverChildBuilderDelegate`][flutter-delegate]
- [`packages/flutter/lib/src/rendering/viewport.dart`, `defaultCacheExtent`][flutter-cache]
- [`packages/flutter/lib/src/rendering/viewport.dart`, `CacheExtentStyle`][flutter-cache-style]
- [Flutter slivers documentation][flutter-docs]

<!-- References -->

[flutter]: https://github.com/flutter/flutter
[flutter-pin]: https://github.com/flutter/flutter/tree/feab40b83b8d1954106e83bb1d7b52265a41cb45
[flutter-delegate]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/widgets/scroll_delegate.dart#L352
[flutter-cache]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/rendering/viewport.dart#L289
[flutter-cache-style]: https://github.com/flutter/flutter/blob/feab40b83b8d1954106e83bb1d7b52265a41cb45/packages/flutter/lib/src/rendering/viewport.dart#L136
[flutter-docs]: https://docs.flutter.dev/ui/layout/scrolling/slivers
