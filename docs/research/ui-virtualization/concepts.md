# Virtualization Concepts

The shared vocabulary the deep-dives in this catalog use. Terms differ wildly
between ecosystems — Flutter says _sliver_, GTK says _factory_, WPF says
_container recycling_, Dear ImGui says _clipper_ — so this page fixes one set of
names and one set of questions, and every subject page answers the same five.

---

## The problem

A scrollable view shows `V` items out of `N`, where `N` may be orders of
magnitude larger. A naive implementation does `O(N)` work per frame and its cost
grows with the data. **Virtualization** is any technique that makes the per-frame
cost `O(V)` instead — plus, ideally, `O(1)` amortized bookkeeping for the `N - V`
items that are not on screen.

The subtlety is that "the work" is not one thing. A scrolling view does at least
four kinds of work per item, and a framework can bound any subset of them:

| Layer      | Work per item                                      | Bounded by                                      |
| ---------- | -------------------------------------------------- | ----------------------------------------------- |
| **Data**   | fetch, decode, sort, filter the underlying record  | a [model protocol](#model-protocol)             |
| **Build**  | construct the widget / element / node for the item | a [builder](#builder) or [factory](#factory)    |
| **Layout** | measure and position it                            | the [realized window](#realized-window)         |
| **Paint**  | emit its draw commands                             | [clipping](#clipping) — every toolkit does this |

> [!IMPORTANT]
> **Clipping is not virtualization.** Every toolkit discards draw commands
> outside the viewport; that bounds only the last row of the table. A view can
> clip perfectly and still be `O(N)` because it built, laid out and — worst of
> all — _re-derived from raw data_ every item in order to discover which ones to
> clip. This distinction is the whole subject: see
> [Dear ImGui](./dear-imgui-clipper.md), whose documentation states it outright.

---

## Core terms

### Viewport

The rectangle the user actually sees. Its size in items (`V`) is the target
per-frame cost.

### Virtual extent

The size the content _would_ have if it were all materialized — what the
scrollbar's thumb is proportioned against and what a drag maps into. Since the
point of virtualization is to never measure `N` items, the extent must be
obtained without measuring:

- **Declared** — the app states it (uniform row height × `N`). Exact.
  [egui](./egui-show-rows.md), [Slint](./slint-repeater.md).
- **Estimated** — extrapolated from the measured visible items.
  [Gio](./gio-list.md), [Avalonia](./avalonia-wpf-virtualizing-panels.md).
- **Progressive** — refined as more items are visited; the scrollbar grows
  under the user. [Textual](./textual-line-api.md)-style incremental indexing.

### Realized window

The contiguous index range `[first, last)` the view has actually materialized.
Everything outside it exists only as data (or not even that).

### Overscan / cache extent

Extra items realized just outside the viewport so a scroll of one step does not
expose an unbuilt gap. Named `cacheExtent` in
[Flutter](./flutter-slivers.md) (250 logical pixels by default),
`CacheLength` + `CacheLengthUnit` in
[WPF](./avalonia-wpf-virtualizing-panels.md), and an unnamed `+1` row in
[egui](./egui-show-rows.md).

### Model protocol

An interface that exposes the data as `count` + `item(i)` so the view can read
_only_ the indices it needs. `QAbstractItemModel` (Qt), `GListModel`
([GTK](./gtk4-list-factories.md)), `Model` ([Slint](./slint-repeater.md)),
`IListVirtualDelegate` ([VS Code](./vscode-listview.md)). The presence or absence
of this layer is the single sharpest divide in the catalog.

### Builder

A callback `(index) -> view` invoked for visible indices only. The
immediate-mode form of a model protocol:
`ListElement func(gtx, index) Dimensions` in [Gio](./gio-list.md),
`SliverChildBuilderDelegate` in [Flutter](./flutter-slivers.md).

### Factory

A builder split into two phases — **setup** (create an empty view) and **bind**
(fill it with item `i`'s data) — so the setup half can be skipped when a view is
reused. `GtkListItemFactory` ([GTK 4](./gtk4-list-factories.md)) is the clearest
statement of this split.

### Recycling

Retaining scrolled-out views in a pool and re-binding them to newly visible
indices rather than destroying and recreating. `VirtualizationMode.Recycling`
([WPF](./avalonia-wpf-virtualizing-panels.md)), `ListView.reuseItems`
([Qt Quick](./qt-quick-listview.md)), `RowCache`
([VS Code](./vscode-listview.md)).

### Clipping

Discarding paint work outside the viewport. Universal, and the baseline every
framework already had before it virtualized anything.

---

## The analysis spine

Every deep-dive in this catalog answers these five questions in this order.

### 1. What does the window bound?

Paint only, build too, or the data access itself? A framework that bounds
building but still requires a fully materialized item array (as
[Ratatui](./ratatui-offsets.md) does) has solved a different problem from one
whose model is queried per index.

### 2. How is the visible range computed?

- **Division** — uniform item size, `first = floor(scroll / size)`. Exact,
  `O(1)`, and wrong the moment items differ.
- **Walk** — accumulate sizes from a known anchor until the viewport is full.
  `O(V)`, tolerates variable sizes, but only supports relative movement cheaply.
- **Prefix sums / interval tree** — `O(log N)` random access into variable
  sizes, at the cost of maintaining the index.

### 3. What survives between frames?

Nothing (pure immediate mode), the measured geometry, the built views (a
recycling pool), or the whole model. This is the axis on which
"immediate" and "retained" actually differ — not whether the tree is rebuilt,
but what is _cached_ across rebuilds.

### 4. How is the scroll extent known?

Declared, estimated or progressive — see [virtual extent](#virtual-extent). A
framework that gets this wrong has a thumb that jitters or a drag that overshoots
even when the rows themselves are perfect.

### 5. What breaks?

The recurring hazards, in the order they bite:

- **Identity.** A view's state (focus, selection, an open editor, an in-progress
  drag) is keyed by _something_. If that key is derived from position in the
  build order, virtualization silently shifts it. egui advances its auto-ID
  counter by the number of skipped rows for exactly this reason
  ([`skip_ahead_auto_ids`](./egui-show-rows.md)); Avalonia keeps the focused and
  scroll-target elements _outside_ the realized window
  ([`_focusedElement`](./avalonia-wpf-virtualizing-panels.md)); Qt Quick warns
  against storing any state in a delegate at all
  ([`reuseItems`](./qt-quick-listview.md)).
- **Variable sizes.** Division stops working; the extent stops being knowable
  without measuring.
- **Jump-to-index.** Cheap under division, expensive under a walk.
- **Hit testing and coordinates.** A pointer position must map back to a data
  index, which the window offsets.
- **Search and accessibility.** Both traditionally want the whole list to exist.
  Flutter carries `semanticIndexCallback` through its builder delegate precisely
  because the semantic index cannot be inferred from the realized subset.

---

## Sources

Each term's authority is the deep-dive it links to; those pages carry the
primary-source citations.

<!-- References -->
