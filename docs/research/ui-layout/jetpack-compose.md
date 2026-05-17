# Jetpack Compose (Kotlin)

Google's declarative UI toolkit for Android, extended via Compose Multiplatform to
desktop, iOS, web, and -- through Jake Wharton's [Mosaic](../tui-libraries/mosaic.md)
project -- the terminal. Compose's layout model is built around a **single-pass
measurement protocol** in which every node receives `Constraints`
(`minWidth, maxWidth, minHeight, maxHeight`), calls `measure(constraints)` on each
child to obtain a `Placeable`, then chooses its own size and finally calls
`place(x, y)` on those placeables. The compiler plugin transforms `@Composable`
functions into incremental tree-building code, and the runtime observes snapshot
state to drive minimal recomposition.

| Field            | Value                                                                                                                                                        |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language         | Kotlin (Compose compiler plugin + runtime)                                                                                                                   |
| License          | Apache 2.0                                                                                                                                                   |
| Repository       | <https://android.googlesource.com/platform/frameworks/support/+/refs/heads/androidx-main/compose/>                                                           |
| GitHub mirror    | <https://github.com/androidx/androidx/tree/androidx-main/compose>                                                                                            |
| Documentation    | <https://developer.android.com/jetpack/compose> and <https://developer.android.com/develop/ui/compose>                                                       |
| Version snapshot | Compose UI 1.11.1 (AndroidX, May 2026); Compose Multiplatform releases independently through JetBrains                                                       |
| Notable adoption | Google Play Store, Twitter/X for Android, Lyft, Airbnb, Pinterest, Square Cash; Compose Multiplatform: JetBrains Toolbox, Toolbox apps; Mosaic for terminal. |

---

## Overview

### What It Solves

Pre-Compose Android UI was written in **XML layouts** combined with imperative `View`
hierarchies (`LinearLayout`, `RelativeLayout`, `ConstraintLayout`) inflated at runtime
into Java/Kotlin `View` objects. The model had well-known issues:

- **Two-language split.** Layout shape was in XML; behaviour was in Kotlin/Java. Type
  safety crossed the boundary via `findViewById` and view binding, both error-prone.
- **Quadratic measurement on nested layouts.** `LinearLayout` with `weight` measures
  every child twice; nested weighted layouts compound this multiplicatively. The
  practical rule was "don't nest weighted layouts" -- a footgun.
- **Property bag growth.** A `View` had hundreds of attributes shared by every
  subclass, only a few of which applied to any one widget. State management was
  imperative and stored on the views themselves.
- **Animation API mismatch.** `ValueAnimator`, `ObjectAnimator`, and
  `MotionLayout` all targeted the legacy view system; none composed cleanly with
  state-driven UI.

Compose replaces all of this with a single-language model (`@Composable` Kotlin
functions), a runtime that tracks state reactively, and a layout protocol explicitly
designed to keep measurement O(n) regardless of nesting depth.

### Design Philosophy

Compose's stated design principles, mirrored in its layout machinery:

1. **Composition over inheritance.** A composable is a function, not a class. Building
   a new container is writing a function that calls `Layout { … }` with a measure
   policy, not subclassing a `ViewGroup`.
2. **State is read where it is used.** Snapshot state (`mutableStateOf`,
   `mutableStateListOf`) automatically registers reads in the currently composing
   function; a state change invalidates only the composables that read it.
3. **Single-pass measurement is mandatory by default.** A composable may call
   `measure()` on each child **exactly once**. This rule eliminates the nested
   `LinearLayout` problem by construction. Multi-pass measurement is opt-in via
   `SubcomposeLayout`.
4. **Modifiers are the configuration channel.** Rather than dozens of constructor
   parameters, every composable accepts a `Modifier` chain. The chain is a left-to-
   right list of measure / draw / pointer-input nodes applied in order, with stable
   identity and predictable composition.
5. **The compiler plugin does the work.** A bespoke Kotlin compiler plugin (the
   "Compose compiler") rewrites every `@Composable` function call into bytecode that
   threads a `Composer` argument and emits `start/end` calls into a `SlotTable`. The
   runtime uses that slot table to memoise function calls and to skip composables
   whose inputs are unchanged.
6. **Multiplatform by construction.** The Compose runtime is platform-agnostic. The
   `Applier` interface lets non-Android targets (desktop, iOS, web, terminal) emit
   their own node types. Compose Multiplatform (JetBrains) and [Mosaic](../tui-libraries/mosaic.md)
   (Jake Wharton, terminal output) both build on this seam.

### History

| Year | Milestone                                                                                                            |
| ---- | -------------------------------------------------------------------------------------------------------------------- |
| 2019 | Compose announced at Google I/O. Source goes public in AOSP.                                                         |
| 2020 | Developer Preview / Alpha. `Layout {}` composable, `Modifier` chain, `mutableStateOf` are present.                   |
| 2021 | **Compose 1.0** ships (July). Production-ready for Android.                                                          |
| 2021 | JetBrains releases Compose Multiplatform (desktop) targeting JVM/Skiko.                                              |
| 2021 | Jake Wharton releases [Mosaic](../tui-libraries/mosaic.md) (June) -- Compose runtime on a custom terminal `Applier`. |
| 2022 | Compose for Wear OS 1.0. Compose Multiplatform for desktop 1.2.                                                      |
| 2023 | Compose Multiplatform iOS goes Alpha. Strong skipping mode (compose-compiler 1.5.4).                                 |
| 2024 | Compose Multiplatform iOS goes Stable. Compose UI 1.7 introduces Lazy*Item* APIs revisions, prefetch tuning.         |
| 2025 | Mosaic 0.17 ships custom terminal parser, Compose Multiplatform 1.7 expands web support.                             |

---

## Architecture / Layout Model

### Constraints: A Four-Field Box

Every measurement in Compose starts with a [`Constraints`][compose-constraints] value:

```kotlin
@Immutable
@kotlin.jvm.JvmInline
value class Constraints internal constructor(internal val value: Long) {
    val minWidth: Int
    val maxWidth: Int    // may be Constraints.Infinity
    val minHeight: Int
    val maxHeight: Int   // may be Constraints.Infinity

    val hasBoundedWidth: Boolean
    val hasBoundedHeight: Boolean
    val hasFixedWidth: Boolean    // minWidth == maxWidth
    val hasFixedHeight: Boolean

    fun copy(
        minWidth: Int = this.minWidth,
        maxWidth: Int = this.maxWidth,
        minHeight: Int = this.minHeight,
        maxHeight: Int = this.maxHeight,
    ): Constraints

    companion object {
        const val Infinity: Int = Int.MAX_VALUE
        fun fixed(width: Int, height: Int): Constraints
        fun fixedWidth(width: Int): Constraints
        fun fixedHeight(height: Int): Constraints
    }
}
```

Differences from SwiftUI's [`ProposedViewSize`](./swiftui.md):

- Each axis is a `[min, max]` pair instead of an optional. "Unbounded" is expressed by
  `maxWidth == Constraints.Infinity`, not by `nil`.
- The child may not pick a size outside its constraints (in the framework's contract).
  A child that needs more is expected to return its desired size as a `Placeable` and
  the parent decides whether to clip.
- The constraint type is a packed `Long` (`@JvmInline value class`). This avoids
  per-measure allocation: a constraint is one word.

### Measure / Place Phases

Compose's layout is two-step but **interleaved per node**:

```
parent.measure(constraints)
  ├─ inside measure block: each child.measure(childConstraints) -> Placeable
  ├─ call layout(width, height) { … }
  └─ inside layout block: each placeable.place(x, y)
```

The `MeasurePolicy` interface drives this:

```kotlin
@Stable
fun interface MeasurePolicy {
    fun MeasureScope.measure(
        measurables: List<Measurable>,
        constraints: Constraints,
    ): MeasureResult
}

interface MeasureResult {
    val width: Int
    val height: Int
    val alignmentLines: Map<AlignmentLine, Int>
    fun placeChildren()
}
```

The `MeasureScope.layout(width, height) { … }` builder constructs a `MeasureResult`;
the trailing lambda is the `Placeable.PlacementScope` and is where you call
`place(x, y)`.

### Built-In Containers

| Composable                  | Direction  | Behaviour                                                                                                                                      |
| --------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| `Column`                    | vertical   | Top-to-bottom; supports `verticalArrangement`, `horizontalAlignment`, and weighted children.                                                   |
| `Row`                       | horizontal | Left-to-right; supports `horizontalArrangement`, `verticalAlignment`, weighted children.                                                       |
| `Box`                       | depth      | Z-stacks children; `contentAlignment` aligns all children, `Modifier.align` overrides per child.                                               |
| `LazyColumn`                | vertical   | Recycler-backed scroll list. Only visible items composed.                                                                                      |
| `LazyRow`                   | horizontal | Horizontal recycler.                                                                                                                           |
| `LazyVerticalGrid`          | 2-D        | Vertical grid; columns described by `GridCells`.                                                                                               |
| `LazyHorizontalGrid`        | 2-D        | Horizontal counterpart.                                                                                                                        |
| `LazyVerticalStaggeredGrid` | 2-D        | Pinterest-style staggered grid.                                                                                                                |
| `FlowRow` / `FlowColumn`    | wrap       | Wrap to next line/column when out of room (Compose 1.4+).                                                                                      |
| `ConstraintLayout`          | rule-based | Port of Android's `ConstraintLayout`; see [`./android-constraintlayout.md`](./android-constraintlayout.md) for the legacy view-system version. |
| `Scaffold`                  | slots      | Material Design app shell with slots for `topBar`, `bottomBar`, `floatingActionButton`, etc.                                                   |

#### Column, Row, Box

```kotlin
@Composable
inline fun Column(
    modifier: Modifier = Modifier,
    verticalArrangement: Arrangement.Vertical = Arrangement.Top,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    content: @Composable ColumnScope.() -> Unit
)

@Composable
inline fun Row(
    modifier: Modifier = Modifier,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    verticalAlignment: Alignment.Vertical = Alignment.Top,
    content: @Composable RowScope.() -> Unit
)

@Composable
inline fun Box(
    modifier: Modifier = Modifier,
    contentAlignment: Alignment = Alignment.TopStart,
    propagateMinConstraints: Boolean = false,
    content: @Composable BoxScope.() -> Unit
)
```

The `ColumnScope` / `RowScope` / `BoxScope` receivers expose scope-only modifiers:

```kotlin
@LayoutScopeMarker
@Immutable
interface RowScope {
    @Stable fun Modifier.weight(weight: Float, fill: Boolean = true): Modifier
    @Stable fun Modifier.align(alignment: Alignment.Vertical): Modifier
    @Stable fun Modifier.alignBy(alignmentLine: HorizontalAlignmentLine): Modifier
    @Stable fun Modifier.alignByBaseline(): Modifier
}
```

A canonical example -- a contact row with avatar, name, badge, and a flexible spacer:

```kotlin
@Composable
fun ContactRow(contact: Contact) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Image(
            painter = rememberAsyncImagePainter(contact.avatarUrl),
            contentDescription = null,
            modifier = Modifier
                .size(40.dp)
                .clip(CircleShape),
        )
        Column(modifier = Modifier.weight(1f)) {
            Text(contact.name, style = MaterialTheme.typography.titleSmall)
            Text(
                contact.statusLine,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (contact.hasUnread) {
            Badge { Text(contact.unreadCount.toString()) }
        }
    }
}
```

#### Arrangement and Alignment

Arrangements describe **how leftover main-axis space is distributed**:

```kotlin
object Arrangement {
    val Start: Horizontal
    val End: Horizontal
    val Top: Vertical
    val Bottom: Vertical
    val Center: HorizontalOrVertical
    val SpaceBetween: HorizontalOrVertical
    val SpaceAround: HorizontalOrVertical
    val SpaceEvenly: HorizontalOrVertical
    fun spacedBy(space: Dp): HorizontalOrVertical
    fun spacedBy(space: Dp, alignment: Alignment.Horizontal): Horizontal
    val End: Horizontal
}
```

Alignments are the cross-axis story:

```kotlin
object Alignment {
    val TopStart: Alignment
    val TopCenter: Alignment
    val TopEnd: Alignment
    val CenterStart: Alignment
    val Center: Alignment
    val CenterEnd: Alignment
    val BottomStart: Alignment
    val BottomCenter: Alignment
    val BottomEnd: Alignment

    @Immutable interface Horizontal { fun align(size: Int, space: Int, layoutDirection: LayoutDirection): Int }
    @Immutable interface Vertical { fun align(size: Int, space: Int): Int }

    val Start: Horizontal
    val CenterHorizontally: Horizontal
    val End: Horizontal
    val Top: Vertical
    val CenterVertically: Vertical
    val Bottom: Vertical
}
```

#### Modifier Sizing API

The size-related modifiers in `androidx.compose.foundation.layout`:

```kotlin
fun Modifier.size(size: Dp): Modifier
fun Modifier.size(width: Dp, height: Dp): Modifier
fun Modifier.size(size: DpSize): Modifier
fun Modifier.width(width: Dp): Modifier
fun Modifier.height(height: Dp): Modifier
fun Modifier.requiredSize(size: Dp): Modifier          // ignores incoming constraints
fun Modifier.requiredWidth(width: Dp): Modifier
fun Modifier.fillMaxSize(fraction: Float = 1f): Modifier
fun Modifier.fillMaxWidth(fraction: Float = 1f): Modifier
fun Modifier.fillMaxHeight(fraction: Float = 1f): Modifier
fun Modifier.wrapContentSize(align: Alignment = Alignment.Center, unbounded: Boolean = false): Modifier
fun Modifier.wrapContentWidth(align: Alignment.Horizontal = Alignment.CenterHorizontally, unbounded: Boolean = false): Modifier
fun Modifier.padding(all: Dp): Modifier
fun Modifier.padding(horizontal: Dp = 0.dp, vertical: Dp = 0.dp): Modifier
fun Modifier.padding(start: Dp = 0.dp, top: Dp = 0.dp, end: Dp = 0.dp, bottom: Dp = 0.dp): Modifier
fun Modifier.padding(values: PaddingValues): Modifier
fun Modifier.offset(x: Dp = 0.dp, y: Dp = 0.dp): Modifier
fun Modifier.aspectRatio(ratio: Float, matchHeightConstraintsFirst: Boolean = false): Modifier

// In ColumnScope / RowScope:
fun Modifier.weight(weight: Float, fill: Boolean = true): Modifier
```

Note `size` versus `requiredSize`: `size` is a _preferred_ value, clamped to the parent's
`Constraints`. `requiredSize` overrides the parent's constraints (a child that is wider
than its parent's `maxWidth` can be drawn outside the parent's bounds).

#### LazyColumn, LazyRow, LazyVerticalGrid

```kotlin
@Composable
fun LazyColumn(
    modifier: Modifier = Modifier,
    state: LazyListState = rememberLazyListState(),
    contentPadding: PaddingValues = PaddingValues(0.dp),
    reverseLayout: Boolean = false,
    verticalArrangement: Arrangement.Vertical = if (!reverseLayout) Arrangement.Top else Arrangement.Bottom,
    horizontalAlignment: Alignment.Horizontal = Alignment.Start,
    flingBehavior: FlingBehavior = ScrollableDefaults.flingBehavior(),
    userScrollEnabled: Boolean = true,
    content: LazyListScope.() -> Unit,
)

@Composable
fun LazyVerticalGrid(
    columns: GridCells,
    modifier: Modifier = Modifier,
    state: LazyGridState = rememberLazyGridState(),
    contentPadding: PaddingValues = PaddingValues(0.dp),
    reverseLayout: Boolean = false,
    verticalArrangement: Arrangement.Vertical = if (!reverseLayout) Arrangement.Top else Arrangement.Bottom,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    flingBehavior: FlingBehavior = ScrollableDefaults.flingBehavior(),
    userScrollEnabled: Boolean = true,
    content: LazyGridScope.() -> Unit,
)

sealed class GridCells {
    class Fixed(val count: Int) : GridCells
    class Adaptive(val minSize: Dp) : GridCells
    class FixedSize(val size: Dp) : GridCells
}
```

The lazy variants build their item tree via the `LazyListScope` / `LazyGridScope`
receivers (`item { }`, `items(count) { i -> }`, `items(list) { item -> }`, plus
`stickyHeader { }`) rather than as a flat `@Composable` block. This is what allows
them to defer composition of off-screen rows.

#### ConstraintLayout

The Compose port of Android's view-system [`ConstraintLayout`](./android-constraintlayout.md):

```kotlin
@Composable
fun ConstraintLayout(
    modifier: Modifier = Modifier,
    optimizationLevel: Int = Optimizer.OPTIMIZATION_STANDARD,
    content: @Composable ConstraintLayoutScope.() -> Unit,
)
```

Each child gets a reference, and constraints are declared with the DSL:

```kotlin
ConstraintLayout(Modifier.fillMaxSize()) {
    val (title, subtitle, button) = createRefs()

    Text(
        "Hello",
        modifier = Modifier.constrainAs(title) {
            top.linkTo(parent.top, margin = 16.dp)
            start.linkTo(parent.start, margin = 16.dp)
        },
    )
    Text(
        "World",
        modifier = Modifier.constrainAs(subtitle) {
            top.linkTo(title.bottom, margin = 4.dp)
            start.linkTo(title.start)
        },
    )
    Button(
        onClick = { },
        modifier = Modifier.constrainAs(button) {
            bottom.linkTo(parent.bottom, margin = 16.dp)
            end.linkTo(parent.end, margin = 16.dp)
        },
    ) { Text("OK") }
}
```

`ConstraintLayout` runs a Cassowary-style solver and is the recommended container for
non-trivial 2-D arrangements where simple `Row` / `Column` nesting would obscure
intent.

### Intrinsic Measurements

Compose's single-pass rule forbids re-measuring a child to discover its preferred
size. Instead, every `Measurable` exposes four **intrinsic** queries that return what
the child would prefer **without performing a real measurement**:

```kotlin
interface IntrinsicMeasurable {
    val parentData: Any?
    fun minIntrinsicWidth(height: Int): Int
    fun maxIntrinsicWidth(height: Int): Int
    fun minIntrinsicHeight(width: Int): Int
    fun maxIntrinsicHeight(width: Int): Int
}
```

Semantics:

- `minIntrinsicWidth(height)` -- "If you had this height, what is the minimum width
  below which content would visibly truncate?" For text, this is the longest non-
  breakable word.
- `maxIntrinsicWidth(height)` -- "At this height, what width would let you draw all
  content on one line?"
- `minIntrinsicHeight(width)` -- "Given this width, what is the smallest height that
  still shows all content?"
- `maxIntrinsicHeight(width)` -- "What height do you want if width is this?"

A custom layout that needs `IntrinsicMeasurable` queries implements:

```kotlin
class TwoColumnMeasurePolicy : MeasurePolicy {
    override fun MeasureScope.measure(
        measurables: List<Measurable>,
        constraints: Constraints
    ): MeasureResult { /* … */ }

    override fun IntrinsicMeasureScope.minIntrinsicWidth(
        measurables: List<IntrinsicMeasurable>,
        height: Int
    ): Int = measurables.sumOf { it.minIntrinsicWidth(height) }

    override fun IntrinsicMeasureScope.maxIntrinsicHeight(
        measurables: List<IntrinsicMeasurable>,
        width: Int
    ): Int = measurables.maxOf { it.maxIntrinsicHeight(width / measurables.size) }

    // …minIntrinsicHeight, maxIntrinsicWidth analogously
}
```

The `Modifier.height(IntrinsicSize.Min)` and `Modifier.width(IntrinsicSize.Min/Max)`
modifiers let you force a parent to query intrinsics on its child instead of
performing a normal measure:

```kotlin
Row(modifier = Modifier.height(IntrinsicSize.Min)) {
    Text("Left", Modifier.weight(1f))
    Divider(modifier = Modifier.fillMaxHeight().width(1.dp))
    Text("Right side that may be taller", Modifier.weight(1f))
}
```

The divider here fills the height that the tallest of the two `Text`s would request,
without a separate measurement pass.

---

## Custom Layouts

### The `Layout` Composable

The fundamental building block is the [`Layout`][compose-layout-fn] composable:

```kotlin
@Composable inline fun Layout(
    content: @Composable @UiComposable () -> Unit,
    modifier: Modifier = Modifier,
    measurePolicy: MeasurePolicy,
)

@Composable inline fun Layout(
    contents: List<@Composable @UiComposable () -> Unit>,
    modifier: Modifier = Modifier,
    measurePolicy: MultiContentMeasurePolicy,
)
```

`MeasurePolicy` is a single-abstract-method interface so a trailing lambda works:

```kotlin
@Composable
fun MyColumn(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Layout(content = content, modifier = modifier) { measurables, constraints ->
        val placeables = measurables.map { it.measure(constraints) }

        val width = placeables.maxOf { it.width }
        val height = placeables.sumOf { it.height }

        layout(width, height) {
            var y = 0
            for (placeable in placeables) {
                placeable.placeRelative(x = 0, y = y)
                y += placeable.height
            }
        }
    }
}
```

`placeRelative` flips x for right-to-left layout direction; `place` is absolute.
`placeRelative` should be the default for application code; use `place` only when you
deliberately want LTR coordinates regardless of locale.

### A Custom Layout Modifier

Instead of writing a new container, you can write a layout-affecting modifier with
`Modifier.layout`:

```kotlin
fun Modifier.firstBaselineToTop(firstBaselineToTop: Dp) = this.layout { measurable, constraints ->
    val placeable = measurable.measure(constraints)
    check(placeable[FirstBaseline] != AlignmentLine.Unspecified)

    val firstBaseline = placeable[FirstBaseline]
    val placeableY = firstBaselineToTop.roundToPx() - firstBaseline
    val height = placeable.height + placeableY

    layout(placeable.width, height) {
        placeable.placeRelative(0, placeableY)
    }
}
```

This is precisely how Compose's `paddingFromBaseline` is implemented.

### Example: A Flow Layout

Wrap-to-next-line, like CSS `flex-wrap: wrap`:

```kotlin
@Composable
fun MyFlowRow(
    modifier: Modifier = Modifier,
    horizontalSpacing: Dp = 8.dp,
    verticalSpacing: Dp = 8.dp,
    content: @Composable () -> Unit,
) {
    Layout(modifier = modifier, content = content) { measurables, constraints ->
        val hSpacing = horizontalSpacing.roundToPx()
        val vSpacing = verticalSpacing.roundToPx()
        val maxWidth = constraints.maxWidth

        data class Row(val placeables: MutableList<Placeable>, var width: Int, var height: Int)
        val rows = mutableListOf<Row>()
        var current = Row(mutableListOf(), 0, 0)
        rows += current

        for (measurable in measurables) {
            val placeable = measurable.measure(constraints.copy(minWidth = 0))
            val needed = placeable.width + (if (current.placeables.isEmpty()) 0 else hSpacing)
            if (current.width + needed > maxWidth && current.placeables.isNotEmpty()) {
                current = Row(mutableListOf(), 0, 0)
                rows += current
            }
            current.placeables += placeable
            current.width += needed
            current.height = maxOf(current.height, placeable.height)
        }

        val totalWidth = rows.maxOf { it.width }.coerceAtMost(maxWidth)
        val totalHeight = rows.sumOf { it.height } + vSpacing * (rows.size - 1).coerceAtLeast(0)

        layout(totalWidth, totalHeight) {
            var y = 0
            for (row in rows) {
                var x = 0
                for (placeable in row.placeables) {
                    placeable.placeRelative(x, y)
                    x += placeable.width + hSpacing
                }
                y += row.height + vSpacing
            }
        }
    }
}
```

### Example: An Equal-Width Distribution

```kotlin
@Composable
fun EqualWidthRow(
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Layout(modifier = modifier, content = content) { measurables, constraints ->
        require(measurables.isNotEmpty())
        val cellWidth = constraints.maxWidth / measurables.size
        val cellConstraints = constraints.copy(
            minWidth = cellWidth,
            maxWidth = cellWidth,
        )
        val placeables = measurables.map { it.measure(cellConstraints) }
        val height = placeables.maxOf { it.height }

        layout(constraints.maxWidth, height) {
            var x = 0
            for (placeable in placeables) {
                placeable.placeRelative(x, 0)
                x += cellWidth
            }
        }
    }
}
```

This is the rough Compose equivalent of the `EqualWidthHStack` SwiftUI example in
[`swiftui.md`](./swiftui.md). Note the key difference: in SwiftUI we _query_ each
child for its natural width and then pick the maximum, because the protocol is
propose-and-respond. In Compose we _impose_ a fixed-width constraint on each child
and the child measures itself accordingly. The Compose model assumes the parent knows
what it wants up front; SwiftUI assumes the child does.

### SubcomposeLayout

`Layout` enforces "measure each child once". For genuinely two-pass layouts -- e.g.,
"size the navigation rail to match the tallest item, then re-lay-out the content
column to that height" -- Compose offers [`SubcomposeLayout`][compose-subcompose]:

```kotlin
@Composable
fun SubcomposeLayout(
    modifier: Modifier = Modifier,
    measurePolicy: SubcomposeMeasureScope.(Constraints) -> MeasureResult,
)

interface SubcomposeMeasureScope : MeasureScope {
    fun subcompose(slotId: Any?, content: @Composable () -> Unit): List<Measurable>
}
```

`subcompose(slotId)` lets you compose a subtree on demand, get back its `Measurable`s,
and measure them with constraints derived from earlier work in the same pass.
`BoxWithConstraints` is implemented on top of `SubcomposeLayout`; so is `Scaffold`
(which must size the body around the actual measured height of the top and bottom
bars).

A toy example -- a "tab strip that sizes its underline to the active tab's width":

```kotlin
@Composable
fun TabsWithUnderline(
    tabs: List<String>,
    selectedIndex: Int,
    onSelected: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    SubcomposeLayout(modifier) { constraints ->
        // First subcomposition: actual tabs
        val tabMeasurables = subcompose("tabs") {
            tabs.forEachIndexed { i, label ->
                Box(
                    Modifier
                        .padding(horizontal = 12.dp, vertical = 8.dp)
                        .clickable { onSelected(i) }
                ) { Text(label) }
            }
        }
        val tabPlaceables = tabMeasurables.map { it.measure(Constraints()) }
        val widths = tabPlaceables.map { it.width }
        val totalWidth = widths.sum()
        val rowHeight = tabPlaceables.maxOf { it.height }

        // Second subcomposition: underline sized to the selected tab
        val underline = subcompose("underline") {
            Box(
                Modifier
                    .height(2.dp)
                    .background(MaterialTheme.colorScheme.primary)
            )
        }.first().measure(
            Constraints.fixed(widths[selectedIndex], 2.dp.roundToPx())
        )

        val underlineX = widths.take(selectedIndex).sum()

        layout(totalWidth, rowHeight + underline.height) {
            var x = 0
            for (placeable in tabPlaceables) {
                placeable.placeRelative(x, 0)
                x += placeable.width
            }
            underline.placeRelative(underlineX, rowHeight)
        }
    }
}
```

Two-pass layouts are powerful but incur extra composition; the docs explicitly
recommend `Layout` whenever possible and `SubcomposeLayout` only when intrinsics or
constraints alone cannot express the relationship.

### Compose Multiplatform and Mosaic

The `Layout` composable, `Modifier`, `Constraints`, and `MeasurePolicy` are all
defined in `androidx.compose.ui` -- platform-agnostic packages that Compose
Multiplatform (JetBrains) reuses for desktop, iOS, and web targets without changes.
The Android-specific bits live in `androidx.compose.ui.platform.android`.

[Mosaic](../tui-libraries/mosaic.md) takes a different route: it does **not** reuse
`androidx.compose.ui` at all. Instead, Mosaic re-implements an `Applier` against its
own scene-graph of text-cell nodes, and supplies a minimal layout package (`Row`,
`Column`, `Box`, `Text`, `Static`) that produces terminal cells rather than pixels. The
Compose **runtime** (state, recomposition, slot table) is the same; the **layout
machinery** is bespoke. This is one of the cleanest demonstrations of the
runtime/UI separation in the Compose architecture: the same compiler plugin and
slot-table runtime can drive a recycler-view Android grid, a Skiko-on-Linux desktop
window, an iOS `UIView`, or an ANSI terminal cell buffer.

---

## Strengths and Weaknesses

### For App UIs

**Strengths.**

- **Single-pass measurement is enforced by construction.** Performance-pathological
  layouts that plagued `LinearLayout` weights are gone unless you opt into
  `SubcomposeLayout`. Compose's official guidance is that deep nesting is cheap.
- **Modifiers are a uniform extension point.** A custom property (e.g., a per-child
  bias for a `ConstraintLayout`, a sticky-header marker, a focus order) lives as a
  modifier rather than as a one-off constructor parameter.
- **Snapshot state recomposition.** A `mutableStateOf` write invalidates only the
  composables that read it. The compiler plugin also adds equality-based skipping,
  meaning unchanged subtrees are not recomposed even if their parent runs.
- **Excellent tooling.** Android Studio offers a Compose preview pane (with state
  hoist support and interactive mode), a layout inspector that maps to source
  positions, and a recomposition counter overlay.
- **Multiplatform.** The same Compose source runs on JVM, Android, iOS (Kotlin/Native),
  desktop (Skiko), web (Kotlin/Wasm), and terminal (Mosaic).

**Weaknesses.**

- **Verbose for trivial UIs.** Every container takes a `modifier`, every text needs
  a style; what is one HTML line is often four lines of Kotlin.
- **Recomposition cost is real.** Without `@Stable`/`@Immutable` annotations or
  `derivedStateOf` for expensive reads, badly written composables recompose far more
  than they need to. The Compose compiler 1.5.4 "strong skipping" mode mitigates this
  but does not eliminate it.
- **Compile times.** The Compose compiler plugin adds noticeable cost to incremental
  builds. Large Compose projects routinely report multi-minute clean builds.
- **`SubcomposeLayout` is a footgun.** Multi-pass layouts compose subtrees from
  scratch each measure call; using `SubcomposeLayout` where intrinsics would suffice
  can be an order of magnitude more expensive.

### For Static One-Shot Rendering

Compose's runtime model is **persistent**: a `Composer`, slot table, snapshot manager,
and recomposition scheduler are spun up for any composition, even one rendered exactly
once. For a single frame, this is overhead -- and for a CLI, it includes a thread
running the snapshot system whether you want it or not.

Mosaic ([`../tui-libraries/mosaic.md`](../tui-libraries/mosaic.md)) demonstrates that
the runtime _can_ produce one-shot output: its `renderMosaic` API composes a tree,
renders it to ANSI once, and exits. But the cost-versus-benefit is a real
consideration: bringing in the Compose compiler plugin, Kotlin runtime, and snapshot
machinery just to print a coloured table is heavy. Compose shines when the UI is
long-lived and state-driven; for batch-style "compose once, emit, exit" workloads, a
plain string builder or a smaller library is usually faster end-to-end.

### Compared to Alternatives

- **vs. SwiftUI** (see [`swiftui.md`](./swiftui.md)). Compose's `Constraints` is more
  imperative than SwiftUI's `ProposedViewSize`: the parent dictates a `[min, max]`
  range on each axis, and the child measures itself once and returns a `Placeable`.
  SwiftUI's child can ignore the proposal; Compose's child cannot legitimately violate
  its constraints. Compose is more flexible (you can constrain only one axis, pass
  through the other) but less expressive at the boundary (no built-in "unspecified" --
  you must use `Constraints.Infinity` and check `hasBoundedWidth`).
- **vs. Flutter.** Flutter's `BoxConstraints` and Compose's `Constraints` are nearly
  isomorphic: both are `(minWidth, maxWidth, minHeight, maxHeight)`. The difference
  is in scheduling -- Flutter's render tree is mutable and re-laid-out imperatively;
  Compose's tree is a function of state and re-laid-out reactively.
- **vs. Android view system.** The Compose `Layout` protocol replaces
  `View.onMeasure(int, int)` / `View.onLayout(boolean, int, int, int, int)` and the
  XML attribute soup. Migration is gradual via `AndroidView { … }` and `ComposeView`.
- **vs. CSS Flexbox (Ink, see [`../tui-libraries/ink.md`](../tui-libraries/ink.md)).**
  Ink uses Yoga, a C++ Flexbox engine. Yoga's measurement is one-pass; its API is
  similar in spirit to Compose's `Layout` (children measured then placed) but it
  exposes only Flexbox primitives. Compose generalises: `Row` and `Column` are
  ordinary `Layout` instances, not a special-cased Flexbox container.
- **vs. Ratatui** (see [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)).
  Ratatui's Cassowary-based area subdivision is closer to ConstraintLayout than to
  `Row`/`Column`. There is no "intrinsic size" concept for Ratatui widgets because
  the parent always assigns an area top-down. Compose's intrinsic-measurement protocol
  matters precisely because most UI elements (text, images) do have an inherent size.
- **vs. Mosaic** (see [`../tui-libraries/mosaic.md`](../tui-libraries/mosaic.md)).
  Mosaic _is_ Compose retargeted at the terminal. It reuses the runtime and compiler
  plugin and ships a small custom layout layer with `Row`, `Column`, `Box`, `Text`,
  and `Static`. The protocol is the same; only the unit is terminal cells instead of
  pixels.

### Lessons for Sparkles

For a D-based pretty-printer / CLI layout engine, the Compose model suggests:

1. **A `Constraints`-style packed integer.** A struct
   `struct Constraints { ushort minW, maxW, minH, maxH; }` fits in 64 bits and is
   passed by value -- no heap allocation in a `@nogc` layout pass.
2. **A `Placeable`-style intermediate.** Sparkles' equivalent would be a `Measured`
   struct with `(width, height)` plus a placement closure. Templates ensure each
   widget's `measure` is monomorphised at compile time.
3. **A `MeasurePolicy` analogue via template constraints.** D's design-by-introspection
   makes this natural:
   ```d
   enum hasMeasurePolicy(T) = is(typeof((T t, Measurable[] m, Constraints c) {
       MeasureResult r = t.measure(m, c);
   }));
   ```
4. **`SubcomposeLayout`-style two-pass on opt-in.** Sparkles can offer a single-pass
   `layout` for typical use and a multi-pass `relayout` for the few cases (e.g.,
   table alignment across columns) that require it.
5. **Modifier chains as compile-time builders.** D's UFCS chains
   (`text.bold.underline.padding(2)`) can statically thread through a left-to-right
   `Modifier` analogue, with the same identity-preserving semantics Compose's
   `Modifier` chain enforces at runtime.

---

## References

- **Compose Layout overview:**
  <https://developer.android.com/develop/ui/compose/layouts>
- **Basic layouts:**
  <https://developer.android.com/develop/ui/compose/layouts/basics>
- **Custom layouts:**
  <https://developer.android.com/develop/ui/compose/layouts/custom>
- **Material `Scaffold`:**
  <https://developer.android.com/develop/ui/compose/components/scaffold>
- **`ConstraintLayout` in Compose:**
  <https://developer.android.com/develop/ui/compose/layouts/constraintlayout>
- **Layout phases (measure / layout / draw):**
  <https://developer.android.com/develop/ui/compose/phases>
- **Compose Multiplatform (JetBrains):**
  <https://www.jetbrains.com/lp/compose-multiplatform/>
- **API reference (`androidx.compose.foundation.layout`):**
  <https://developer.android.com/reference/kotlin/androidx/compose/foundation/layout/package-summary>
- **API reference (`androidx.compose.ui.layout`):**
  <https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/package-summary>
- **Compose source (`Layout.kt`, `Constraints.kt`, `MeasurePolicy.kt`):**
  <https://cs.android.com/androidx/platform/frameworks/support/+/androidx-main:compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/layout/>
- **Google I/O 2021 "What's new in Compose":**
  <https://www.youtube.com/watch?v=PsnNUJUTn4M>
- **Jake Wharton -- "Bringing Compose to the Terminal" (Droidcon talk on Mosaic):**
  <https://github.com/JakeWharton/mosaic>
- **Cross-references inside this catalog:**
  - [SwiftUI](./swiftui.md) -- the closest peer framework; propose-and-respond.
  - [Mosaic](../tui-libraries/mosaic.md) -- Compose runtime retargeted at terminal cells.
  - [Ratatui](../tui-libraries/ratatui.md) -- constraint-solver area subdivision.
  - [Ink](../tui-libraries/ink.md) -- Flexbox-via-Yoga in JavaScript.

---

## Markdown References

[compose-constraints]: https://developer.android.com/reference/kotlin/androidx/compose/ui/unit/Constraints
[compose-layout-fn]: https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/package-summary#Layout(kotlin.Function0,androidx.compose.ui.Modifier,androidx.compose.ui.layout.MeasurePolicy)
[compose-subcompose]: https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/SubcomposeLayout
[compose-measurepolicy]: https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/MeasurePolicy
[compose-placeable]: https://developer.android.com/reference/kotlin/androidx/compose/ui/layout/Placeable
