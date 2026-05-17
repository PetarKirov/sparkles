# SwiftUI (Swift)

Apple's declarative UI framework for all Apple platforms. SwiftUI introduces a
**propose-and-respond** layout protocol where every parent proposes a size to each child
and the child responds with the size it actually wants -- giving authors per-axis,
per-subview negotiation that is more flexible than the tight/loose `BoxConstraints`
model used by Flutter or the single-pass `Constraints` model used by Jetpack Compose.
Since iOS 16, the same `Layout` protocol that powers built-in stacks is public, so
applications can write their own containers (flow, radial, equal-width grids) without
falling back to `GeometryReader` hacks.

| Field            | Value                                                                                                              |
| ---------------- | ------------------------------------------------------------------------------------------------------------------ |
| Language         | Swift                                                                                                              |
| License          | Proprietary (Apple SDK)                                                                                            |
| Repository       | Closed source; ships with Xcode                                                                                    |
| Documentation    | <https://developer.apple.com/documentation/swiftui>                                                                |
| Version snapshot | Layout protocol focus: iOS 16+ / macOS 13+; SwiftUI releases are tied to Apple platform SDKs                       |
| Notable adoption | Apple's own apps (Settings, Weather, Notes, Stocks, App Store, Wallet); third-party: Things 3, Linear macOS, Ivory |

---

## Overview

### What It Solves

Prior to SwiftUI (announced WWDC 2019, iOS 13), Apple-platform UI was written with
**UIKit** (iOS/tvOS) or **AppKit** (macOS) -- imperative, retained-mode toolkits with
manual frame computation, Auto Layout constraint solvers, or hand-tuned
`layoutSubviews()` overrides. Auto Layout in particular was powerful but notoriously
verbose: every relationship between two views became an `NSLayoutConstraint` object, and
"intrinsic content size" hooks plus content-hugging and compression-resistance
priorities had to be tuned per view to make the Cassowary solver produce the desired
result. Layout bugs typically appeared as ambiguous-constraint console spam rather than
visibly broken UI, making them hard to diagnose.

SwiftUI replaces this with three coordinated ideas:

1. **A declarative DSL** -- views are immutable value types described by a
   `@ViewBuilder` result-builder closure. Re-rendering is the framework's job.
2. **A propose-and-respond layout protocol** -- the parent passes a
   [`ProposedViewSize`][apple-proposedviewsize] (each axis optional) to each child; the
   child returns a `CGSize` it would like to occupy. There is no separate "intrinsic
   content size" API: every view answers the same question with the same protocol.
3. **A public `Layout` protocol (iOS 16)** -- the very same machinery that backs
   `HStack`, `VStack`, `Grid`, and `ZStack` is available to user code, so custom
   containers compose naturally with built-ins, share their alignment-guide machinery,
   and benefit from the framework's layout caching.

### Design Philosophy

SwiftUI's layout system rests on a small number of orthogonal axioms:

- **A view is a function of state.** The same `body` re-evaluated on the same state
  produces the same view tree. The framework reconciles successive trees and re-runs
  layout only where state changed.
- **Sizing is negotiated, not dictated.** A parent never forces a child to a specific
  size unless it explicitly wraps the child in a `.frame(...)`. The proposal mechanism
  expresses "I have this much room available; please tell me what you want." The child
  may return a smaller or larger size, and the parent then decides how to place it
  (centred, padded, clipped, etc.).
- **Composition over configuration.** Where UIKit offered `setNeedsLayout`,
  `intrinsicContentSize`, content-hugging priorities, and `translatesAutoresizingMaskIntoConstraints`,
  SwiftUI offers a single protocol with two methods. Behaviour that UIKit modelled with
  flags becomes a separate view modifier or layout container.
- **Result builders for shape.** The `@ViewBuilder`, `@SceneBuilder`, and (from iOS 16)
  `@LayoutValueKey` machinery lets containers consume their children as a
  result-builder block while still seeing them as a typed sequence at runtime.
- **Per-platform but not per-toolkit.** The same SwiftUI source compiles for iOS,
  iPadOS, macOS, tvOS, watchOS, and visionOS. Differences are usually limited to
  available modifiers (e.g., `.menuBarExtraStyle` only on macOS) rather than to entirely
  different layout primitives.

### History

| Year | Release              | Layout-relevant additions                                                                                                           |
| ---- | -------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 2019 | SwiftUI 1.0 / iOS 13 | `HStack`, `VStack`, `ZStack`, `Spacer`, `Divider`, `ScrollView`, `Group`, `GeometryReader`, `.frame`, `.padding`, alignment guides. |
| 2020 | SwiftUI 2.0 / iOS 14 | `LazyVStack`, `LazyHStack`, `LazyVGrid`, `LazyHGrid`, `GridItem`, `ScrollViewReader`, `Section` pinning.                            |
| 2021 | SwiftUI 3.0 / iOS 15 | `.safeAreaInset`, `materialBackground`, refined `List` performance, `AsyncImage`.                                                   |
| 2022 | SwiftUI 4.0 / iOS 16 | **`Layout` protocol becomes public**; `Grid` / `GridRow`; `AnyLayout`; `ViewThatFits`; `gridCellColumns`, `gridColumnAlignment`.    |
| 2023 | SwiftUI 5.0 / iOS 17 | `ScrollView` content margins, `.scrollTargetBehavior`, `Inspector`, `ContentUnavailableView`.                                       |
| 2024 | SwiftUI 6.0 / iOS 18 | `@Entry` macro for environment values, `MeshGradient`, refined `Grid` interaction with animations, custom container values.         |

The 2022 release was the most significant for layout: applications previously had to
choose between Apple's bundled stacks and grids or drop down to `GeometryReader` with
manual offset math. The `Layout` protocol closed that gap.

---

## Architecture / Layout Model

### The Propose-and-Respond Protocol

Every layout pass walks the view tree twice, conceptually:

1. **Sizing.** The root view is given an unconstrained or window-sized proposal. It
   forwards a (possibly transformed) proposal to each child via the same protocol. Each
   child returns its actual size as a `CGSize`. The parent then computes its own size
   from those responses.
2. **Placement.** The parent receives a concrete bounds rectangle and decides where each
   child goes, calling `place(at:anchor:proposal:)` on each subview.

The proposal carries optional axes:

```swift
@frozen public struct ProposedViewSize {
    public var width: CGFloat?
    public var height: CGFloat?

    public static let zero: ProposedViewSize          // (0, 0)
    public static let infinity: ProposedViewSize      // (∞, ∞)
    public static let unspecified: ProposedViewSize   // (nil, nil)

    public init(_ size: CGSize)
    public init(width: CGFloat?, height: CGFloat?)
    public func replacingUnspecifiedDimensions(by size: CGSize = CGSize(width: 10, height: 10)) -> CGSize
}
```

The three sentinel values correspond to three layout queries a parent may want to ask:

- **`.zero`** -- "What is your minimum size?" A child returns the smallest size it can
  draw at; used by `fixedSize()` and by stacks resolving `minWidth`.
- **`.infinity`** -- "What is your maximum useful size?" A child returns the largest
  size it would still benefit from; used to compute `idealWidth` / `idealHeight`.
- **`.unspecified`** -- "What is your ideal (preferred) size?" A child returns its
  natural intrinsic size; this is the proposal a top-level container starts with.

A parent typically asks all three. Stacks, for instance, query `.zero` and
`.infinity` to discover each child's flexibility, then distribute available space
proportionally to the children with the largest `max - min` range.

A view responds to a proposal by returning a `CGSize`. There is no contract that the
returned size be _less than or equal to_ the proposal -- a child may legitimately demand
more space than was offered. The parent then decides whether to clip, scroll, or accept
the overflow. (`Text`, for example, will lay out wider than its proposal if `lineLimit`
is `1` and `truncationMode` is `.none`.)

### Built-In Containers

| Container      | Direction  | Behaviour                                                                                                        | Min iOS |
| -------------- | ---------- | ---------------------------------------------------------------------------------------------------------------- | ------- |
| `HStack`       | horizontal | Lays children left-to-right, asks each its ideal width, distributes leftover space to flexible children.         | 13      |
| `VStack`       | vertical   | Top-to-bottom version of `HStack`.                                                                               | 13      |
| `ZStack`       | depth      | Overlays children in the parent's bounds, aligned via `Alignment`.                                               | 13      |
| `LazyHStack`   | horizontal | Same API as `HStack` but only materialises children that intersect the visible viewport (inside a `ScrollView`). | 14      |
| `LazyVStack`   | vertical   | Same as `LazyHStack`, vertical.                                                                                  | 14      |
| `Grid`         | 2-D        | Two-dimensional layout with aligned columns and rows; rows declared via `GridRow`.                               | 16      |
| `LazyVGrid`    | vertical   | Vertical-scrolling grid where columns are described by `[GridItem]`.                                             | 14      |
| `LazyHGrid`    | horizontal | Horizontal-scrolling counterpart.                                                                                | 14      |
| `ScrollView`   | n/a        | Container that proposes its own size on the scroll axis as unbounded.                                            | 13      |
| `ViewThatFits` | n/a        | Picks the first child whose ideal size fits the proposal.                                                        | 16      |

#### HStack / VStack / ZStack

```swift
public struct HStack<Content: View>: View {
    public init(
        alignment: VerticalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    )
}

public struct VStack<Content: View>: View {
    public init(
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    )
}

public struct ZStack<Content: View>: View {
    public init(
        alignment: Alignment = .center,
        @ViewBuilder content: () -> Content
    )
}
```

A passed-in `spacing: nil` is **not** zero -- it means "use the system default", which
varies by platform and by which two views are adjacent. SwiftUI's `ViewSpacing` machinery
tracks per-edge spacing preferences for each view (text baselines, list rows, etc.) and
the stack queries that to compute the gap.

The simplest layout example:

```swift
HStack(alignment: .firstTextBaseline, spacing: 8) {
    Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.yellow)
    VStack(alignment: .leading, spacing: 2) {
        Text("Disk almost full")
            .font(.headline)
        Text("12.4 GB free of 256 GB")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
    Spacer()
    Button("Manage…") { /* … */ }
}
```

Here the `HStack` proposes its full width to its three children. The image returns
its intrinsic size; the inner `VStack` returns the natural size of its two `Text`
labels; the `Spacer` returns `Length(min, max)` with `max = .infinity`. The stack
then assigns the leftover horizontal space to the spacer.

#### Grid (iOS 16+)

```swift
public struct Grid<Content: View>: View {
    public init(
        alignment: Alignment = .center,
        horizontalSpacing: CGFloat? = nil,
        verticalSpacing: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    )
}

public struct GridRow<Content: View>: View {
    public init(
        alignment: VerticalAlignment? = nil,
        @ViewBuilder content: () -> Content
    )
}
```

`Grid` is a real, eager 2-D layout (unlike `LazyVGrid`/`LazyHGrid`): the column
widths are determined by the widest cell in each column, the row heights by the
tallest cell in each row, and cells align across both axes. Cells may span multiple
columns via `.gridCellColumns(_:)`, anchor differently via `.gridCellAnchor(_:)`, or
override their column alignment with `.gridColumnAlignment(_:)`.

```swift
Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
    GridRow {
        Text("Name").bold()
        Text("Petar Kirov")
    }
    GridRow {
        Text("Email").bold()
        Text("petar@blocksense.network")
    }
    GridRow {
        Text("Notes").bold()
        Text("Long multi-line note that should wrap and influence column 2 only.")
            .gridCellColumns(1)
    }
}
```

#### LazyVGrid / LazyHGrid

```swift
public struct LazyVGrid<Content: View>: View {
    public init(
        columns: [GridItem],
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        pinnedViews: PinnedScrollableViews = .init(),
        @ViewBuilder content: () -> Content
    )
}

public struct GridItem {
    public enum Size {
        case fixed(CGFloat)
        case flexible(minimum: CGFloat = 10, maximum: CGFloat = .infinity)
        case adaptive(minimum: CGFloat, maximum: CGFloat = .infinity)
    }
    public var size: Size
    public var spacing: CGFloat?
    public var alignment: Alignment?
}
```

`GridItem` sizing modes:

- **`.fixed(w)`** -- exactly `w` points wide; takes no extra.
- **`.flexible(min, max)`** -- between `min` and `max`; the number of columns is fixed
  by the array length.
- **`.adaptive(min, max)`** -- as many columns of this width as fit in the available
  axis; this is how SwiftUI builds responsive grids without a media query.

```swift
let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

ScrollView {
    LazyVGrid(columns: columns, spacing: 12) {
        ForEach(photos) { photo in
            AsyncImage(url: photo.thumbnail)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    .padding()
}
```

#### ScrollView

```swift
public struct ScrollView<Content: View>: View {
    public init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    )
}
```

A `ScrollView` proposes `nil` (unspecified) on its scroll axis to its child, meaning
"you can grow as tall (or as wide) as you want". This is how `LazyVStack`s in a
`ScrollView` get an unlimited vertical proposal even when their parent window is fixed.

### Sizing Modifiers

```swift
extension View {
    public func frame(
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View

    public func frame(
        minWidth: CGFloat? = nil,
        idealWidth: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        minHeight: CGFloat? = nil,
        idealHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil,
        alignment: Alignment = .center
    ) -> some View

    public func fixedSize() -> some View
    public func fixedSize(horizontal: Bool, vertical: Bool) -> some View
    public func padding(_ edges: Edge.Set = .all, _ length: CGFloat? = nil) -> some View
    public func layoutPriority(_ value: Double) -> some View
}
```

The `min/ideal/max` variant is the canonical way to make a view _flexible_ -- e.g.,
`.frame(minWidth: 100, maxWidth: .infinity)` says "I want at least 100 points but I
will gladly consume any extra width". `fixedSize()` is the opposite: it tells the
parent "use my ideal size; do not propose a smaller one".

`layoutPriority` modifies how a parent stack distributes _leftover_ space when two
flexible children compete. Higher-priority children are sized first.

### Safe Area Insets

```swift
extension View {
    public func safeAreaInset<V: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: () -> V
    ) -> some View

    public func safeAreaPadding(_ insets: EdgeInsets) -> some View
}
```

Adding a `.safeAreaInset(edge: .bottom) { Toolbar() }` extends the safe area: scroll
content underneath stays scrollable but the toolbar is anchored at the visual bottom
above the home-indicator inset. This is roughly Compose's `Scaffold` slot pattern
delivered as a view modifier instead of a top-level container.

### Alignment Guides

Each axis has a typed alignment enum:

```swift
public struct HorizontalAlignment {
    public static let leading: HorizontalAlignment
    public static let center: HorizontalAlignment
    public static let trailing: HorizontalAlignment
}

public struct VerticalAlignment {
    public static let top: VerticalAlignment
    public static let center: VerticalAlignment
    public static let bottom: VerticalAlignment
    public static let firstTextBaseline: VerticalAlignment
    public static let lastTextBaseline: VerticalAlignment
}

public struct Alignment {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment
    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment)
    public static let center: Alignment
    // … leading, trailing, top, bottom, topLeading, bottomTrailing, …
}
```

Custom alignment guides extend the system. The `AlignmentID` protocol takes the
default offset from the view's natural alignment and adjusts it per view:

```swift
extension HorizontalAlignment {
    private enum FormFieldLabelAlignment: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[.leading]
        }
    }
    static let formFieldLabel = HorizontalAlignment(FormFieldLabelAlignment.self)
}

VStack(alignment: .formFieldLabel) {
    HStack {
        Text("Name:")
            .alignmentGuide(.formFieldLabel) { d in d[.trailing] }
        TextField("", text: $name)
    }
    HStack {
        Text("Email:")
            .alignmentGuide(.formFieldLabel) { d in d[.trailing] }
        TextField("", text: $email)
    }
}
```

The above aligns the trailing edges of the labels into a single vertical column, even
though the labels have different widths -- something that would require an explicit
table layout in most other frameworks.

---

## Custom Layouts -- the `Layout` Protocol (iOS 16+)

Before iOS 16, building a custom container meant building a `GeometryReader` plus
manual `.offset(...)` modifiers and pre-computed sizes, with no integration into the
framework's alignment-guide or animation machinery. iOS 16's [`Layout`][apple-layout]
protocol gave third-party code the same hooks built-in stacks use.

### Protocol Definition

```swift
public protocol Layout: Animatable {
    associatedtype Cache = Void

    static var layoutProperties: LayoutProperties { get }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    )

    func spacing(subviews: Subviews, cache: inout Cache) -> ViewSpacing

    func explicitAlignment(
        of guide: HorizontalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGFloat?

    func explicitAlignment(
        of guide: VerticalAlignment,
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGFloat?

    func makeCache(subviews: Subviews) -> Cache
    func updateCache(_ cache: inout Cache, subviews: Subviews)
}
```

Only `sizeThatFits` and `placeSubviews` are required (everything else has a default).
`Subviews` is a typed `RandomAccessCollection` of [`LayoutSubview`][apple-layoutsubview]:

```swift
public struct LayoutSubview {
    public func sizeThatFits(_ proposal: ProposedViewSize) -> CGSize
    public func dimensions(in proposal: ProposedViewSize) -> ViewDimensions
    public func place(at position: CGPoint, anchor: UnitPoint = .topLeading, proposal: ProposedViewSize)
    public var spacing: ViewSpacing { get }
    public var priority: Double { get }
    public subscript<K: LayoutValueKey>(key: K.Type) -> K.Value { get }
}
```

The `cache` parameter is a per-layout-instance scratch space. SwiftUI calls
`makeCache(subviews:)` once, then `sizeThatFits` and `placeSubviews` zero or more
times, then `updateCache(_:subviews:)` if the children change. Heavy work (e.g.,
measuring all children for an equal-width grid) goes into the cache so the place
phase is O(n).

### Example: A Flow Layout

A wrap-to-next-line layout, like CSS's `flex-wrap: wrap`:

```swift
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    struct Cache {
        var sizes: [CGSize] = []
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes.removeAll(keepingCapacity: true)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for size in cache.sizes {
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x)
        }

        return CGSize(width: min(widest, maxWidth), height: y + rowHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for (subview, size) in zip(subviews, cache.sizes) {
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// Usage:
FlowLayout(spacing: 6) {
    ForEach(tags, id: \.self) { tag in
        Text(tag)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(.gray.opacity(0.15)))
    }
}
```

### Example: A Radial Layout

A layout that arranges children evenly around the bounds' centre at a constant radius:

```swift
struct RadialLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 300, height: 300))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let radius = min(bounds.size.width, bounds.size.height) / 3
        let angleStep = .pi * 2 / Double(subviews.count)
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)

        for (i, subview) in subviews.enumerated() {
            let angle = angleStep * Double(i) - .pi / 2
            let pt = CGPoint(
                x: centre.x + cos(angle) * radius,
                y: centre.y + sin(angle) * radius
            )
            subview.place(at: pt, anchor: .center, proposal: .unspecified)
        }
    }
}
```

### Example: An Equal-Width Column Layout

Useful for keyboards or toolbars where every cell should be exactly the widest cell's
width:

```swift
struct EqualWidthHStack: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let unitSizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let cellWidth = unitSizes.map(\.width).max() ?? 0
        let cellHeight = unitSizes.map(\.height).max() ?? 0
        let totalWidth = cellWidth * CGFloat(subviews.count)
            + spacing * CGFloat(subviews.count - 1)
        return CGSize(width: totalWidth, height: cellHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let cellWidth = (bounds.width - spacing * CGFloat(subviews.count - 1))
            / CGFloat(subviews.count)
        let cellProposal = ProposedViewSize(width: cellWidth, height: bounds.height)
        var x = bounds.minX
        for subview in subviews {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: cellProposal
            )
            x += cellWidth + spacing
        }
    }
}
```

### `AnyLayout` and Layout Switching

`AnyLayout` is a type-erased `Layout` wrapper that allows the layout type itself to be
animated. This is how SwiftUI achieves the "view morphs from HStack to VStack on
orientation change" demo:

```swift
struct AdaptiveStack<Content: View>: View {
    @Environment(\.horizontalSizeClass) var sizeClass
    @ViewBuilder var content: () -> Content

    var body: some View {
        let layout: AnyLayout = sizeClass == .compact
            ? AnyLayout(VStackLayout())
            : AnyLayout(HStackLayout())

        layout {
            content()
        }
    }
}
```

`VStackLayout` and `HStackLayout` are the `Layout`-conforming structs behind the
built-in `VStack` / `HStack` containers; they were exposed in iOS 16 to make the
`AnyLayout` story tractable.

### `LayoutValueKey` -- Passing Data from Subview to Layout

Custom layouts often need per-child metadata (e.g., a span count for a grid, a
priority weight). The `LayoutValueKey` protocol works like `EnvironmentKey` but flows
upward:

```swift
private struct Weight: LayoutValueKey {
    static let defaultValue: Double = 1
}

extension View {
    func weight(_ value: Double) -> some View {
        self.layoutValue(key: Weight.self, value: value)
    }
}

// Inside FlowLayout (or similar):
let w = subview[Weight.self]
```

This lets users write `Text("Hello").weight(2)` and have the parent layout read `2`
from the subview proxy.

---

## Strengths and Weaknesses

### For App UIs

**Strengths.**

- **Sizing protocol is per-axis optional.** Unlike Flutter's `BoxConstraints`, where
  every constraint is a fixed `[min, max]` pair, SwiftUI's `nil` width/height means
  "unconstrained" without committing to `0…∞`. This makes it trivial to express "I
  have unlimited horizontal space but my height is fixed" -- common for scroll-view
  content.
- **Result-builder DSL.** `@ViewBuilder` produces a strongly typed tuple of views at
  compile time. There is no virtual DOM diffing; the framework knows the tree shape
  statically and can skip large unchanged subtrees with `Equatable` or `@State` hash
  comparisons.
- **Built-in animations.** Layout changes (e.g., a stack shrinking when a row is
  deleted) animate by default; custom layouts get this for free if they conform to
  `Animatable`.
- **Alignment guides are first-class.** Built-in cross-stack alignment (the
  `firstTextBaseline` of a label aligning with the centre of a button) requires no
  manual offset math.
- **Live previews.** Xcode's preview canvas renders Swift code with hot-reload, scoped
  by `#Preview` macros. Iterating on layout is much faster than running a simulator
  build.

**Weaknesses.**

- **Tooling is opaque when it goes wrong.** When a child returns a size larger than
  the proposal, the parent silently clips or overflows; the canonical "view too large"
  diagnostic just prints a warning. Debug-mode tools like `Self._printChanges()` help
  but are private API.
- **Slow incremental compilation.** Heavily nested view bodies hit Swift's type
  inferencer hard. Real-world apps often split complex bodies into small `@ViewBuilder`
  helpers solely to keep the compiler responsive.
- **Per-platform quirks accumulate.** A modifier that exists on iOS may be a no-op on
  watchOS, or behave subtly differently on macOS. Cross-platform code accumulates
  `#if os(...)` blocks.

### For Static One-Shot Rendering

SwiftUI **can** render off-screen via [`ImageRenderer`][apple-image-renderer] (iOS 16+),
which composites a SwiftUI view tree into a `CGImage`, `NSImage`/`UIImage`, or PDF
context. This is the natural fit if you want SwiftUI's layout engine to produce a
poster, an Open Graph image, or a print-quality PDF.

For terminal-style one-shot rendering, SwiftUI is overkill: the framework spins up a
fully retained renderer with hit-testing, accessibility, and animations even if you
only want a single static frame. The Sparkles use case (a CLI emitting a styled report
once and exiting) maps poorly onto SwiftUI's runtime; the _protocol_ (propose-and-
respond), however, is exactly what one would want.

### Compared to Alternatives

- **vs. UIKit / AppKit.** SwiftUI replaces an imperative, retained-mode toolkit with a
  declarative, value-typed one. Auto Layout's constraint-solver complexity is gone; the
  cost is less direct control over sub-pixel positioning and a harder-to-debug
  rendering pipeline.
- **vs. Jetpack Compose** (see [`jetpack-compose.md`](./jetpack-compose.md)). Compose's
  `Constraints` is a four-field `(minWidth, maxWidth, minHeight, maxHeight)` tuple per
  axis -- closer to CSS Flexbox or Auto Layout than to SwiftUI's optional proposal.
  Compose enforces single-pass measurement (each child measured once); SwiftUI permits
  multiple `sizeThatFits` calls per layout pass, which is why stacks can ask `.zero` /
  `.infinity` / `.unspecified` to discover flexibility. Compose's separation of
  `Layout` and `SubcomposeLayout` mirrors SwiftUI's distinction between regular views
  and `ViewThatFits`, but Compose surfaces it as two different APIs while SwiftUI
  unifies them.
- **vs. Flutter.** Flutter's `BoxConstraints` is closer to Compose than to SwiftUI:
  every axis is `[min, max]`, with no notion of "unspecified". Flutter's render-tree
  layout is also single-pass with intrinsic-size fallbacks; performance is excellent
  but expressing "as much as the parent gives me but no more" requires explicit
  `LayoutBuilder` usage.
- **vs. CSS Flexbox / Grid (Ink, see [`../tui-libraries/ink.md`](../tui-libraries/ink.md)).**
  Flexbox solves a similar problem -- distribute available main-axis space among items
  -- but operates as a constraint solver (via Yoga, in Ink's case) rather than a
  recursive propose/respond walk. SwiftUI's per-axis `nil` is closer to Flexbox's
  `auto` than to Compose/Flutter's `[min, max]`.
- **vs. Ratatui** (see [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)).
  Ratatui uses a Cassowary-style constraint solver to subdivide a `Rect`. There is no
  notion of "intrinsic content size" because terminal widgets do not have one --
  every widget is told its area. SwiftUI's protocol is a strict superset: a Ratatui-
  like fixed-area subdivision corresponds to "the parent ignores the child's response
  and forces a frame via `.frame(...)`".

### Lessons for Sparkles

The relevant takeaways for a D-based pretty-printer / CLI layout engine:

1. **Make every axis of a proposal individually optional** rather than `[min, max]`.
   Terminal output frequently knows its main-axis width (the terminal column count) but
   has no cross-axis upper bound (you can always print more lines). The SwiftUI model
   maps onto this cleanly.
2. **Expose a `Layout`-like protocol** with separate _size_ and _place_ phases. The
   place phase can write into a target buffer (Sparkles' `SmallBuffer!(Cell, N)`),
   while the size phase produces a cached layout description usable for tests and for
   `--width=auto` flow.
3. **Treat alignment guides as a separate dimension.** When mixing labels, prefixes,
   and badges in a CLI report, aligning columns by a custom guide (the colon in
   `key: value`) is exactly the SwiftUI pattern.
4. **Layout caching keyed on inputs.** SwiftUI's `Cache` type avoids redundant work in
   `placeSubviews`. The same pattern, with D's CTFE, can pre-bake layouts whose inputs
   are known at compile time.

---

## References

- **Apple Developer Documentation -- Layout fundamentals:**
  <https://developer.apple.com/documentation/swiftui/layout-fundamentals>
- **Apple Developer Documentation -- `Layout` protocol:**
  <https://developer.apple.com/documentation/swiftui/layout>
- **Apple Developer Documentation -- `ProposedViewSize`:**
  <https://developer.apple.com/documentation/swiftui/proposedviewsize>
- **Apple Developer Documentation -- `LayoutSubview`:**
  <https://developer.apple.com/documentation/swiftui/layoutsubview>
- **Apple Developer Documentation -- `AnyLayout`:**
  <https://developer.apple.com/documentation/swiftui/anylayout>
- **Apple Developer Documentation -- `AlignmentID`:**
  <https://developer.apple.com/documentation/swiftui/alignmentid>
- **Apple Developer Documentation -- `LayoutValueKey`:**
  <https://developer.apple.com/documentation/swiftui/layoutvaluekey>
- **Apple Developer Documentation -- `Grid`:**
  <https://developer.apple.com/documentation/swiftui/grid>
- **Apple Developer Documentation -- `LazyVGrid`:**
  <https://developer.apple.com/documentation/swiftui/lazyvgrid>
- **Apple Developer Documentation -- `ScrollView`:**
  <https://developer.apple.com/documentation/swiftui/scrollview>
- **Apple Developer Documentation -- `ImageRenderer`:**
  <https://developer.apple.com/documentation/swiftui/imagerenderer>
- **WWDC 2022 session 10056, "Compose custom layouts with SwiftUI":**
  <https://developer.apple.com/videos/play/wwdc2022/10056/>
- **WWDC 2019 session 237, "Building Custom Views with SwiftUI":**
  <https://developer.apple.com/videos/play/wwdc2019/237/>
- **Cross-references inside this catalog:**
  - [Jetpack Compose](./jetpack-compose.md) -- the closest peer framework.
  - [Ratatui](../tui-libraries/ratatui.md) -- constraint-solver style fixed-area subdivision.
  - [Ink](../tui-libraries/ink.md) -- Flexbox-via-Yoga in the terminal.

---

## Markdown References

[apple-layout]: https://developer.apple.com/documentation/swiftui/layout
[apple-proposedviewsize]: https://developer.apple.com/documentation/swiftui/proposedviewsize
[apple-layoutsubview]: https://developer.apple.com/documentation/swiftui/layoutsubview
[apple-image-renderer]: https://developer.apple.com/documentation/swiftui/imagerenderer
