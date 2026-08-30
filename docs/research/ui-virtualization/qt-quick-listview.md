# Qt Quick — `ListView.reuseItems` (C++ / QML)

Delegate recycling added to a view that had virtualized instantiation for a
decade without it — and shipped **off by default**, with a documented warning
that reusing items changes what a delegate is allowed to remember.

|                         |                                                                        |
| ----------------------- | ---------------------------------------------------------------------- |
| **Language**            | C++ / QML                                                              |
| **License**             | LGPL-3.0 / GPL-2.0 / commercial                                        |
| **Repository**          | [qt/qtdeclarative][qtd] (pinned at [`ffc46f2`][qtd-pin])               |
| **Documentation**       | [Qt Quick `ListView`][qt-docs]                                         |
| **Category**            | Retained, GPU (scene graph)                                            |
| **Rendering model**     | Retained item tree → scene graph; delegate instances per visible index |
| **Virtualization unit** | Model row ↔ delegate instance                                          |
| **`reuseItems` since**  | Qt 5.15                                                                |

See also [Qt Quick's scene graph](../ui-backend-seam/qt-quick-scenegraph.md) and
[Qt layouts](../ui-layout/qt-layouts.md).

## Overview

### What it solves

`ListView` has always instantiated delegates only for visible rows (plus a
configurable `cacheBuffer`). What it did _not_ do until Qt 5.15 was reuse those
instances: a row scrolling out was destroyed and a row scrolling in was
constructed from the delegate `Component`. For a delegate of any complexity —
QML object creation, binding evaluation, scene-graph node creation — that is the
dominant scroll cost.

> Since 5.15, ListView can be configured to recycle items instead of instantiating
> from the \l delegate whenever new rows are flicked into view. This approach improves
> performance, depending on the complexity of the delegate.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-doc]

### Design philosophy

Qt exposes the pool as an explicit, observable lifecycle rather than hiding it.
A delegate can _see_ that it is being pooled and reused, and is expected to
participate:

> When an item is flicked out, it moves to the \e{reuse pool}, which is an
> internal cache of unused items. When this happens, the \l ListView::pooled
> signal is emitted to inform the item about it. Likewise, when the item is
> moved back from the pool, the \l ListView::reused signal is emitted.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-doc]

## How it works

Model-derived properties are refreshed automatically; everything else is not:

> Any item properties that come from the model are updated when the
> item is reused. This includes \c index and \c row, but also
> any model roles.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-doc]

The corresponding obligation is stated as a `\note`:

> Avoid storing any state inside a delegate. If you do, reset it manually on
> receiving the \l ListView::reused signal.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-doc]

and two further hazards follow from an item outliving the row it displayed:

> If an item has timers or animations, consider pausing them on receiving
> the \l ListView::pooled signal. That way you avoid using the CPU resources
> for items that are not visible. Likewise, if an item has resources that
> cannot be reused, they could be freed up.

> While an item is in the pool, it might still be alive and respond
> to connected signals and bindings.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-doc]

That last sentence is the sharp edge: a pooled item is _not_ inert. It is a live
QML object with live bindings that happens not to be visible, so an
inattentive delegate keeps doing work — and can react to signals — on behalf of
a row that scrolled away.

The property itself is deliberately conservative:

> This property enables you to reuse items that are instantiated
> from the \l delegate. If set to \c false, any currently
> pooled items are destroyed.
>
> This property is \c false by default.
>
> — [`src/quick/items/qquicklistview.cpp`][qt-reuse-prop]

The stated reason for the default is backwards compatibility — which is itself
the finding: turning recycling on is a **semantic** change to delegates, not
merely a faster path, so it could not be enabled for existing code.

## Analysis

### 1. What the window bounds

Delegate instantiation, layout, scene-graph nodes, and data access through
`QAbstractItemModel::data(index, role)` — a full
[model protocol](./concepts.md#model-protocol). `cacheBuffer` extends the window
past the viewport in pixels, the same idea as Flutter's
[`cacheExtent`](./flutter-slivers.md).

### 2. How the range is computed

`QQuickItemView` maintains the visible-item list with measured sizes and walks
outward from the current position; `ListView` supports variable-height delegates
natively, so there is no division.

### 3. What survives between frames

Delegate instances (in the reuse pool), the visible-item list with geometry, and
the model. Maximally retained, like [GTK 4](./gtk4-list-factories.md).

### 4. How the extent is known

Estimated from average delegate size for unvisited regions, exact once visited —
`ListView` has long carried the caveat that its `contentHeight` is an estimate
for models it has not fully traversed.

### 5. What breaks

Everything the documentation warns about, and in this order in practice:

1. **Delegate-local state** survives into the next row (checkbox states, edit
   buffers, expanded flags).
2. **Animations and timers** keep running in the pool.
3. **Signal handlers fire on pooled items**, so an item can act on an event for a
   row it no longer represents.
4. Anything holding a reference to a delegate by identity — an overlay anchored
   to "that row's item" — now points at a different row.

## Strengths

- The lifecycle is explicit and observable (`pooled` / `reused`), so a delegate
  can be written correctly rather than defensively.
- Model roles are re-bound automatically, which covers the common case with no
  delegate code at all.
- Off by default, so the semantic change is opt-in per view.

## Weaknesses

- Correctness burden moved onto every delegate author.
- A pooled item is live, which is surprising and is the source of the subtlest
  bugs.
- The win is "depending on the complexity of the delegate" — for a trivial
  delegate, recycling can be neutral or negative.

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                                | Trade-off                                                      |
| ---------------------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------- |
| Add recycling as an opt-in property            | It changes delegate semantics; existing code cannot be silently migrated | Most applications never turn it on and never get the win       |
| Emit `pooled` / `reused` signals               | Delegates can reset state and pause work deliberately                    | Requires every non-trivial delegate to handle two more signals |
| Refresh model-derived properties automatically | The common case needs no delegate changes                                | Blurs the line: some properties update, others silently do not |
| Keep pooled items alive with live bindings     | Reuse must be cheap; tearing down bindings would defeat it               | Invisible items can still consume CPU and react to signals     |

## Sources

- [`src/quick/items/qquicklistview.cpp`, "Reusing items"][qt-reuse-doc]
- [`src/quick/items/qquicklistview.cpp`, `ListView::reuseItems`][qt-reuse-prop]
- [Qt Quick `ListView` QML type reference][qt-docs]

<!-- References -->

[qtd]: https://github.com/qt/qtdeclarative
[qtd-pin]: https://github.com/qt/qtdeclarative/tree/ffc46f28ab21b6666dbea46c81cf2726ce682419
[qt-reuse-doc]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquicklistview.cpp#L2305
[qt-reuse-prop]: https://github.com/qt/qtdeclarative/blob/ffc46f28ab21b6666dbea46c81cf2726ce682419/src/quick/items/qquicklistview.cpp#L2593
[qt-docs]: https://doc.qt.io/qt-6/qml-qtquick-listview.html
