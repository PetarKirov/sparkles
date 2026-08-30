# GTK 4 — `GListModel` + `GtkListItemFactory` (C)

The clearest statement in the catalog of the **setup / bind** split: a small pool
of widgets is created once, and scrolling re-_binds_ those widgets to different
model items. This is precisely the "build the table once, then only change the
cell contents" intuition, made into an API.

|                         |                                                                                    |
| ----------------------- | ---------------------------------------------------------------------------------- |
| **Language**            | C (with bindings)                                                                  |
| **License**             | LGPL-2.1-or-later                                                                  |
| **Repository**          | [GNOME/gtk][gtk] (pinned at [`817caae`][gtk-pin])                                  |
| **Documentation**       | [GtkListItemFactory][gtk-docs-factory] · [List widget overview][gtk-docs-overview] |
| **Category**            | Retained, GPU                                                                      |
| **Rendering model**     | Retained widget tree; render nodes (GSK) rebuilt from dirty regions                |
| **Virtualization unit** | Model item ↔ `GtkListItem` widget                                                  |

See also the [UI Layout deep-dive on GTK 4](../ui-layout/gtk.md) and
[GTK 4 / GSK in the backend-seam catalog](../ui-backend-seam/gtk4-gsk.md).

## Overview

### What it solves

GTK 4 replaced `GtkTreeView`/`GtkListStore` with a model-view stack —
`GtkListView`, `GtkGridView`, `GtkColumnView` over a `GListModel` — whose entire
reason for existing is that the view holds only as many widgets as it shows. The
factory's own documentation states the mechanism in one paragraph:

> Because views do not display the whole list at once but only a few
> items, they only need to maintain a few widgets at a time. They will
> instruct the `GtkListItemFactory` to create these widgets and bind them
> to the items that are currently displayed.
>
> As the list model changes or the user scrolls to the list, the items will
> change and the view will instruct the factory to bind the widgets to those
> new items.
>
> — [`gtk/gtklistitemfactory.c`][gtk-factory]

### Design philosophy

Two objects, two responsibilities: a `GListModel` is a pure, lazily-indexable
data source (`get_n_items`, `get_item(i)`); a `GtkListItemFactory` turns an item
into a widget. The view owns neither. That is a
[model protocol](./concepts.md#model-protocol) in the strict sense — the view
never sees the data, only asks the model for the indices it needs.

## How it works

The factory hands the application a `GtkListItem` — a container object, not the
widget itself — and the application fills it in:

> When the factory needs widgets created, it will create a `GtkListItem`
> and hand it to your code to set up a widget for. This list item will provide
> various properties with information about what item to display and provide
> you with some opportunities to configure its behavior.
>
> — [`gtk/gtklistitemfactory.c`][gtk-factory]

`GtkSignalListItemFactory`, the common implementation, splits that into four
signals, of which two matter here:

| Signal     | Runs                                                   | Does                                               |
| ---------- | ------------------------------------------------------ | -------------------------------------------------- |
| `setup`    | once per pooled widget                                 | build the widget structure (labels, boxes, images) |
| `bind`     | on every scroll that changes which item a widget shows | write item `i`'s values into that structure        |
| `unbind`   | when the widget stops showing an item                  | drop references, cancel per-item work              |
| `teardown` | when the pooled widget is discarded                    | free the structure                                 |

The cost model follows directly: `setup` runs `O(viewport)` times **for the
lifetime of the view**, `bind` runs `O(viewport)` times **per scroll step**, and
neither is a function of `N`. `GtkBuilderListItemFactory` compiles the `setup`
half from a UI file, so the structure is built from a template and only the
bindings are re-evaluated.

A view is inert until both halves are present, which the documentation flags as
the common first mistake:

> A view is usually only able to display anything after both a factory
> and a model have been set on the view. So it is important that you do
> not skip this step when setting up your first view.
>
> — [`gtk/gtklistitemfactory.c`][gtk-factory]

### The column case

`GtkColumnView` layers columns over the same machinery: each `GtkColumnViewColumn`
carries its **own** factory, so a row is not one widget but one cell widget per
column, each independently set up and bound. Column virtualization (not
instantiating cells for horizontally scrolled-out columns) is a separate axis
GTK handles by the same pooling.

## Analysis

### 1. What the window bounds

Widget construction, layout, paint, **and data access** — `GListModel::get_item`
is only called for the items the view intends to bind. A model backed by a
database or a file can implement `get_item` lazily and the view is none the
wiser.

### 2. How the range is computed

The list-base machinery keeps a per-item size cache and an anchor item, walking
outward from the anchor and extrapolating unmeasured items from the average
measured height. Random access by scroll fraction is therefore approximate until
the region has been visited.

### 3. What survives between frames

The widget pool (post-`setup`, pre-`bind` structures), the measured size cache,
and the whole model. This is the maximally-retained end of the catalog.

### 4. How the extent is known

**Estimated then refined** — same family as [Gio](./gio-list.md), but the
estimate improves permanently because measured sizes are cached rather than
recomputed.

### 5. What breaks

- **State in the widget.** A pooled widget that keeps per-item state (an
  expanded flag, a scroll position inside a cell) shows the previous item's
  state after a `bind` unless `unbind` clears it. This is the recycling tax,
  identical in shape to [Qt Quick's](./qt-quick-listview.md) warning.
- **Per-item asynchronous work** (thumbnail loads, network fetches) must be
  cancelled on `unbind` or a fast scroll queues work for items long gone.
- **Bindings, not assignments.** `GtkBuilderListItemFactory` templates express
  `bind` as property bindings, so a value that is not expressible as a binding
  forces the signal factory.

## Strengths

- The setup/bind split names the two costs separately, so an application can see
  which one it is paying.
- A real model protocol: the data layer is virtualized, not just the widgets.
- Declarative `setup` via UI templates keeps the per-scroll work to bindings.

## Weaknesses

- Considerably more machinery than an index range: four signals, a list-item
  wrapper object, and a model interface to implement.
- Size estimation means scrollbar geometry is approximate for unvisited regions.
- The `unbind` discipline is easy to get wrong and the symptom (stale content
  after a fast scroll) appears only under load.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                                   | Trade-off                                                           |
| --------------------------------------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Separate `GListModel` from the view     | The data can be lazy, sorted, filtered and shared without the view knowing  | An interface to implement before anything renders                   |
| Split `setup` from `bind`               | Structure is built `O(viewport)` times ever; only values change per scroll  | Widgets outlive items, so per-item state must be explicitly cleared |
| Pool widgets rather than destroy them   | GTK widget construction is genuinely expensive (CSS, accessibility, layout) | The pool is state, and stale state is the characteristic bug        |
| Per-column factories in `GtkColumnView` | Columns virtualize independently of rows                                    | A row is `n` widgets, multiplying bind cost by column count         |

## Sources

- [`gtk/gtklistitemfactory.c`, `GtkListItemFactory` documentation][gtk-factory]
- [GTK 4 `GtkListItemFactory` API reference][gtk-docs-factory]
- [GTK 4 list widget overview][gtk-docs-overview]

<!-- References -->

[gtk]: https://github.com/GNOME/gtk
[gtk-pin]: https://github.com/GNOME/gtk/tree/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671
[gtk-factory]: https://github.com/GNOME/gtk/blob/817caae3dd5bc8ff6f4a96d5bef0aa0dc0bec671/gtk/gtklistitemfactory.c#L26
[gtk-docs-factory]: https://docs.gtk.org/gtk4/class.ListItemFactory.html
[gtk-docs-overview]: https://docs.gtk.org/gtk4/section-list-widget.html
