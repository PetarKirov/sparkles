# GTK 4 Layout Managers

A widget-tree toolkit that, since GTK 4, cleanly separates _what a widget
contains_ from _how a widget arranges its children_: every `GtkWidget`
delegates layout to a swappable `GtkLayoutManager` subclass, including the
familiar box and grid arrangements as well as a Cassowary-based constraint
solver.

| Field          | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| Language       | C (with first-class bindings: Rust, Python, JavaScript, Vala, C++) |
| License        | LGPLv2.1+                                                          |
| Vendor         | The GNOME Project                                                  |
| Documentation  | <https://docs.gtk.org/gtk4/>                                       |
| First Released | GTK+ 1.0 (1998); GTK 4.0 in 2020                                   |
| Layout API     | <https://docs.gtk.org/gtk4/class.LayoutManager.html>               |
| Predecessor    | GTK 3 (2011), where each container widget hardcoded its own layout |

---

## Overview

GTK has been the canonical widget toolkit on Linux desktops for more than two
decades. Originally written as the toolkit for the GIMP (hence "GIMP
ToolKit"), it has gone through four major versions, with each one
reorganizing how widgets compose. The layout story in GTK 4 (released in
December 2020) is one of the biggest API redesigns in the toolkit's history:
_layout policy is no longer an attribute of the widget_, but a separately
attached `GtkLayoutManager` object.

**What GTK 4 layouts solve.** Most desktop UIs need a small set of layout
primitives: linear stacks, grids, centered content, overlays, and the
occasional pixel-precise positioning. GTK 4 ships exactly that as a set of
focused `GtkLayoutManager` classes, each implementing the same `measure()` and
`allocate()` virtual methods. This means that any widget can swap its layout
algorithm without changing its widget-tree structure — the children stay the
same, only the policy changes.

**Why the redesign mattered.** Before GTK 4, every container widget owned its
own layout. `GtkBox` had its own packing code; `GtkGrid` had its own row/column
solver; `GtkFixed` had its own absolute-positioning logic. Layout-related
properties (homogeneous, spacing, packing) were duplicated across many widget
classes. Worse, you could not _change_ a widget's layout policy without
replacing the widget — and replacing a widget meant migrating all its
children, signal connections, accessibility metadata, and CSS state.

GTK 4 fixes this by separating concerns: a widget owns its children
(`gtk_widget_set_parent`) and is responsible for size negotiation
(`gtk_widget_measure`, `gtk_widget_size_allocate`), but it delegates the
algorithm to a `GtkLayoutManager` object set via
`gtk_widget_set_layout_manager`. The result is a much smaller, more focused
widget API and a layout subsystem that is fully extensible (you can write
your own `GtkLayoutManager`).

**Design philosophy.** GTK 4 layout managers are deliberately small and
single-purpose. There are no megaclasses with dozens of toggles; instead,
each manager does one thing well and you compose them by nesting widgets. The
toolkit ships eight concrete `GtkLayoutManager` subclasses, which together
cover the vast majority of GUI compositions. Custom managers are encouraged
for niche needs.

**Lineage and influences.** The split between widget and layout manager
mirrors Qt's long-standing `QLayout`/`QWidget` distinction (see
[`qt-layouts.md`](./qt-layouts.md)), with one key difference: in Qt the
layout is _contained by_ the widget, while in GTK the layout is _attached as
a strategy_ via a property setter. GTK 4 also introduced `GtkConstraintLayout`,
a port of the Cassowary linear-arithmetic constraint solver that Apple's
AutoLayout (iOS/macOS) popularized in 2011 — bringing GTK closer to platform
parity for declarative constraint-based UI.

---

## Layout Model

### The `GtkLayoutManager` protocol

Every layout manager implements four virtual methods (and a couple of
lifecycle hooks):

```c
struct _GtkLayoutManagerClass {
    GObjectClass parent_class;

    GtkSizeRequestMode (* get_request_mode)  (GtkLayoutManager *manager,
                                              GtkWidget        *widget);

    void               (* measure)           (GtkLayoutManager *manager,
                                              GtkWidget        *widget,
                                              GtkOrientation    orientation,
                                              int               for_size,
                                              int              *minimum,
                                              int              *natural,
                                              int              *minimum_baseline,
                                              int              *natural_baseline);

    void               (* allocate)          (GtkLayoutManager *manager,
                                              GtkWidget        *widget,
                                              int               width,
                                              int               height,
                                              int               baseline);

    GtkLayoutChild *   (* create_layout_child)(GtkLayoutManager *manager,
                                               GtkWidget        *widget,
                                               GtkWidget        *for_child);

    void               (* root)              (GtkLayoutManager *manager);
    void               (* unroot)            (GtkLayoutManager *manager);
};
```

The two essential methods are `measure()` and `allocate()`. `measure()`
returns four numbers — minimum, natural, minimum*baseline, natural_baseline —
for a given orientation and a constraint along the \_other* orientation
(`for_size`). `allocate()` is called once the parent has decided on a final
width/height; the manager walks its children and calls
`gtk_widget_size_allocate` on each.

The optional `create_layout_child()` returns a `GtkLayoutChild` object that
stores per-child layout properties — for example, a `GtkGridLayoutChild`
holds `row`, `column`, `row-span`, `column-span` for one child of a
`GtkGridLayout`. These objects are cached by the framework and looked up via
`gtk_layout_manager_get_layout_child(manager, child)`.

### Size request modes

The `GtkSizeRequestMode` enum tells GTK how a widget's sizing depends on its
orthogonal axis:

| Value              | Meaning                                                                     |
| ------------------ | --------------------------------------------------------------------------- |
| `CONSTANT_SIZE`    | Width is independent of height, and vice versa. Most widgets.               |
| `HEIGHT_FOR_WIDTH` | The widget needs to know its width before it can compute its height.        |
| `WIDTH_FOR_HEIGHT` | The widget needs to know its height before it can compute its width (rare). |

Height-for-width is GTK's standout feature for text-heavy UIs. A wrapped label
in `HEIGHT_FOR_WIDTH` mode: GTK first measures it horizontally (asking for
minimum and natural widths); then, after allocating a width, GTK calls
`measure(VERTICAL, for_size=allocated_width)` to ask how tall the label
needs to be. The label's `measure()` implementation runs Pango's line breaker
at the allocated width and returns the resulting height.

The orientation-aware measure protocol is rare among widget toolkits.
Qt approximates it via `QSizePolicy::hasHeightForWidth()`, which adds a
second pass after the initial measure; GTK bakes it directly into the
measure protocol, so any widget can participate without extra ceremony.

### Per-widget layout properties

Every widget — _regardless of which `GtkLayoutManager` its parent uses_ —
exposes a small set of layout properties read by the manager:

- **`halign`, `valign`** — alignment within the widget's allocation. Values
  from `GtkAlign`: `FILL`, `START`, `END`, `CENTER`, `BASELINE_FILL`,
  `BASELINE_CENTER`. `FILL` is the default; the others let a widget refuse
  to consume its full allocation and instead anchor to one edge.
- **`margin-start`, `margin-end`, `margin-top`, `margin-bottom`** — outer
  margins in pixels. Always part of the widget's measurement, so a margin
  on a child propagates correctly into the parent's `sizeHint`.
- **`hexpand`, `vexpand`** — request extra space from the parent if the
  parent has any to give. The corresponding `hexpand-set`/`vexpand-set`
  flags distinguish between "explicitly false" and "default false (inferred
  from children)".
- **`width-request`, `height-request`** — minimum size requests, equivalent
  to a per-axis floor.

These properties live on `GtkWidget` itself (not on the layout manager), so
they are _universally available_ and behave the same across all layouts.
This is a major usability win compared to GTK 3, where many of these
properties were duplicated on each container.

### Built-in layout managers

GTK 4 ships eight concrete `GtkLayoutManager` subclasses:

| Class                 | Purpose                                                                         | Common widgets                                   |
| --------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------ |
| `GtkBoxLayout`        | Linear horizontal or vertical packing with spacing and homogeneous mode.        | `GtkBox`, `GtkActionBar`                         |
| `GtkGridLayout`       | 2D grid with per-cell row/column placement and spans.                           | `GtkGrid`                                        |
| `GtkCenterLayout`     | Three slots: start, center, end. Holds three children at most.                  | `GtkCenterBox`, `GtkHeaderBar`                   |
| `GtkBinLayout`        | Single child, sized to the parent. Trivial pass-through.                        | `GtkFrame`, `GtkWindowHandle`, many leaf widgets |
| `GtkOverlayLayout`    | One main child + N overlay children. Overlays float over the main child.        | `GtkOverlay`                                     |
| `GtkFixedLayout`      | Explicit `GskTransform` per child. Pixel-precise positioning.                   | `GtkFixed`                                       |
| `GtkConstraintLayout` | Cassowary-based linear constraint solver. AutoLayout-style.                     | (user-installed; no dedicated widget)            |
| `GtkCustomLayout`     | Trampolines into user-supplied measure/allocate callbacks. No `GtkLayoutChild`. | (anonymous, application-specific)                |

### `GtkBoxLayout`

Arranges children linearly along an orientation (`GTK_ORIENTATION_HORIZONTAL`
or `GTK_ORIENTATION_VERTICAL`). Spacing between children is a constant
pixel value; the `homogeneous` flag forces all children to the same size.

```c
GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, /*spacing=*/6);
gtk_widget_set_margin_start(box, 8);
gtk_widget_set_margin_end(box, 8);

GtkWidget *search = gtk_search_entry_new();
gtk_widget_set_hexpand(search, TRUE);     // absorb leftover width

GtkWidget *go     = gtk_button_new_with_label("Go");
GtkWidget *cancel = gtk_button_new_with_label("Cancel");

gtk_box_append(GTK_BOX(box), search);     // hexpand=TRUE -> grows
gtk_box_append(GTK_BOX(box), go);         // hexpand=FALSE -> at natural size
gtk_box_append(GTK_BOX(box), cancel);
```

Equivalent in PyGObject:

```python
box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6,
              margin_start=8, margin_end=8)
search = Gtk.SearchEntry(hexpand=True)
box.append(search)
box.append(Gtk.Button(label="Go"))
box.append(Gtk.Button(label="Cancel"))
```

Notable properties on `GtkBoxLayout` (which `GtkBox` exposes through its own
properties):

- `orientation` (from `GtkOrientable`).
- `spacing` (px between children).
- `homogeneous` (force equal sizes).
- `baseline-position` (where to place the baseline within the extra space
  along the orthogonal axis).
- `baseline-child` (added in 4.12: nominate one child as the baseline source
  in a vertical box).

Unlike GTK 3, there is **no `pack_start` vs. `pack_end`** distinction; you
simply append children in the order you want, and use `halign`/`hexpand` on
each child to control placement and growth. This is a deliberate
simplification: the old "fill" / "expand" / "padding" per-child arguments
were merged into the universal widget properties.

### `GtkGridLayout` and `GtkGridLayoutChild`

A two-dimensional grid. Children are positioned by setting properties on
the per-child `GtkGridLayoutChild` object:

```c
GtkWidget *grid_widget = gtk_grid_new();
GtkGrid   *grid        = GTK_GRID(grid_widget);

gtk_grid_set_row_spacing(grid, 4);
gtk_grid_set_column_spacing(grid, 8);
gtk_grid_set_row_homogeneous(grid, FALSE);
gtk_grid_set_column_homogeneous(grid, FALSE);

// gtk_grid_attach(grid, child, column, row, width, height)
gtk_grid_attach(grid, gtk_label_new("Name:"),    0, 0, 1, 1);
gtk_grid_attach(grid, name_entry,                1, 0, 1, 1);
gtk_grid_attach(grid, gtk_label_new("Email:"),   0, 1, 1, 1);
gtk_grid_attach(grid, email_entry,               1, 1, 1, 1);
gtk_grid_attach(grid, gtk_label_new("Comment:"), 0, 2, 1, 1);
gtk_grid_attach(grid, comment_view,              1, 2, 1, 1);

// Make the field column absorb extra horizontal space.
gtk_widget_set_hexpand(name_entry, TRUE);
gtk_widget_set_hexpand(email_entry, TRUE);
gtk_widget_set_hexpand(comment_view, TRUE);
gtk_widget_set_vexpand(comment_view, TRUE);
```

`GtkGridLayoutChild` properties (set via `g_object_set` or via
`gtk_grid_attach`):

- `column`, `row` — the top-left cell occupied by the child.
- `column-span`, `row-span` — how many cells the child spans.

`GtkGridLayout` itself exposes:

- `row-spacing`, `column-spacing` — pixel gap between cells.
- `row-homogeneous`, `column-homogeneous` — force equal sizes.
- `baseline-row` — which row aligns to the parent's baseline.

Unlike `QGridLayout`, GTK does not have per-row or per-column stretch
factors. Instead, distribution of extra space comes from the children's
`hexpand`/`vexpand` flags: a column where at least one child has
`hexpand=TRUE` is an "expanding" column, and all expanding columns share
extra horizontal space evenly.

### `GtkCenterLayout` and `GtkCenterBox`

Holds exactly three children — start, center, end — with the start child at
the leading edge, the end child at the trailing edge, and the center child
centered in the leftover space. This is what `GtkHeaderBar` uses.

```c
GtkWidget *center = gtk_center_box_new();
gtk_center_box_set_start_widget (GTK_CENTER_BOX(center), back_button);
gtk_center_box_set_center_widget(GTK_CENTER_BOX(center), title_label);
gtk_center_box_set_end_widget   (GTK_CENTER_BOX(center), menu_button);
```

The center child is _truly centered relative to the parent_, not relative
to the space between the start and end children — meaning that if the
start child is wider than the end child, the center child is still placed
at the geometric center of the parent (clipping if needed). The
`shrink-center-last` property lets the center child yield space to the
start/end children when it would otherwise overlap.

### `GtkBinLayout`

The trivial case: one child, allocated the full parent size minus margins.
Used by leaf widgets like `GtkFrame`, `GtkWindowHandle`, `GtkRevealer`, and
many others. Most application developers never touch `GtkBinLayout`
directly; it is the default layout manager for any widget that doesn't
declare another.

### `GtkOverlayLayout` and `GtkOverlay`

A main child plus zero or more overlay children floating on top. Overlays
are positioned via their own `halign`/`valign` and can be measured
independently of the main child.

```c
GtkWidget *overlay = gtk_overlay_new();
gtk_overlay_set_child(GTK_OVERLAY(overlay), document_view);

GtkWidget *toast = gtk_label_new("Saved!");
gtk_widget_set_halign(toast, GTK_ALIGN_END);
gtk_widget_set_valign(toast, GTK_ALIGN_END);
gtk_widget_set_margin_end(toast, 16);
gtk_widget_set_margin_bottom(toast, 16);
gtk_overlay_add_overlay(GTK_OVERLAY(overlay), toast);
```

Overlays are GTK's answer to floating notifications, scroll indicators,
loading spinners on top of content, and similar transient UI.

### `GtkFixedLayout` and `GtkFixed`

Pixel-precise placement via per-child `GskTransform` matrices. Unlike older
GTK 3 `GtkFixed`, which was simple `(x, y)` placement, the GTK 4 version
takes a 2D transform — you can rotate, scale, or skew children.

```c
GtkWidget *fixed = gtk_fixed_new();
GskTransform *t = gsk_transform_translate(NULL,
                      &GRAPHENE_POINT_INIT(40, 80));
gtk_fixed_put(GTK_FIXED(fixed), my_label, 40, 80);
gtk_fixed_set_child_transform(GTK_FIXED(fixed), my_label, t);
gsk_transform_unref(t);
```

`GtkFixedLayout` is _the_ escape hatch when none of the other layouts fit
(typically: custom canvases, game-style UI, complex diagram editors). It
does not participate in dynamic resizing; the application is responsible
for repositioning children when the parent changes size.

### `GtkConstraintLayout`

GTK 4 ships a port of the **Cassowary linear-arithmetic constraint solver**
as `GtkConstraintLayout`. Each constraint is a relation
`target.attr (=|≥|≤) multiplier * source.attr + constant` at a given
_strength_. The solver finds an assignment of all widget edges that
satisfies the strongest possible set of constraints.

```c
GtkLayoutManager *clay = gtk_constraint_layout_new();
gtk_widget_set_layout_manager(parent, clay);

GtkConstraintLayout *cl = GTK_CONSTRAINT_LAYOUT(clay);

// Pin button.left to parent.left + 8.
gtk_constraint_layout_add_constraint(cl,
    gtk_constraint_new(button, GTK_CONSTRAINT_ATTRIBUTE_LEFT,
                       GTK_CONSTRAINT_RELATION_EQ,
                       parent, GTK_CONSTRAINT_ATTRIBUTE_LEFT,
                       /*multiplier=*/1.0, /*constant=*/8.0,
                       GTK_CONSTRAINT_STRENGTH_REQUIRED));

// button.width >= 80.
gtk_constraint_layout_add_constraint(cl,
    gtk_constraint_new_constant(button, GTK_CONSTRAINT_ATTRIBUTE_WIDTH,
                                GTK_CONSTRAINT_RELATION_GE, 80.0,
                                GTK_CONSTRAINT_STRENGTH_REQUIRED));
```

Constraints can also be expressed in **Visual Format Language** (VFL),
borrowed from Cocoa AutoLayout:

```c
const char *vfl[] = {
    "H:|-[button(>=80)]-[entry]-|",   // left margin, button>=80, gap, entry, right margin
    "V:|-[button]-|",
    "V:|-[entry(==button)]-|",
};
gtk_constraint_layout_add_constraints_from_description(
    cl, vfl, G_N_ELEMENTS(vfl), /*hspacing=*/8, /*vspacing=*/8,
    /*error=*/NULL);
```

`GtkConstraintGuide` objects act as named invisible rectangles that
constraints can reference — useful for shared edges, alignment guides, or
content area markers without adding actual widgets.

The Cassowary algorithm is incremental: adding or removing a constraint
re-solves only the affected portion of the system. This makes constraint
layouts cost-effective for moderately complex compositions (tens to
hundreds of constraints) but does add a real cost for very large hierarchies
relative to the simpler box/grid managers.

For deeper background on the Cassowary algorithm, see the planned
`./cassowary.md` companion doc in this catalog, which covers the underlying
linear-arithmetic simplex solver shared between AutoLayout, kiwi.js,
Ratatui's `kasuari`, and GTK's `GtkConstraintLayout`.

### Widgets that use these managers

GTK 4 widgets pair a `GtkLayoutManager` with a thin wrapper that exposes
ergonomic API:

| Widget                                 | Layout manager                              | Purpose                                                    |
| -------------------------------------- | ------------------------------------------- | ---------------------------------------------------------- |
| `GtkBox`                               | `GtkBoxLayout`                              | Horizontal/vertical container.                             |
| `GtkGrid`                              | `GtkGridLayout`                             | Row/column container.                                      |
| `GtkCenterBox`, `GtkHeaderBar`         | `GtkCenterLayout`                           | Three-slot bar.                                            |
| `GtkOverlay`                           | `GtkOverlayLayout`                          | Main child + floating overlays.                            |
| `GtkFixed`                             | `GtkFixedLayout`                            | Pixel-precise placement.                                   |
| `GtkFrame`, `GtkRevealer`, `GtkButton` | `GtkBinLayout`                              | Single-child decorators.                                   |
| `GtkScrolledWindow`                    | Custom (`GtkScrolledWindow` private layout) | Adds scrollbars, handles overshoot.                        |
| `GtkPaned`                             | Custom                                      | Two children with a draggable separator.                   |
| `GtkStack`                             | Custom                                      | Show one of N children with optional cross-fade animation. |
| `GtkNotebook`                          | Custom                                      | Tabbed pages.                                              |
| `GtkExpander`                          | `GtkBinLayout`                              | Collapsible single-child container.                        |

A separate family of widgets implements **list-style scrollable views**
with their own internal layouts:

- **`GtkListBox`** — vertical list of rows. Children must be `GtkListBoxRow`
  widgets. Selection, filtering, and sorting are handled by the list.
- **`GtkFlowBox`** — children flow horizontally and wrap to multiple lines.
  Selectable like `GtkListBox` but in 2D.
- **`GtkListView`** — list view backed by a `GListModel`. Replaces the older
  `GtkTreeView` for modern scrolling lists; uses an internal recycling
  layout that does not allocate widgets for off-screen rows.
- **`GtkColumnView`** — multi-column variant of `GtkListView` with sortable
  columns. The closest thing to a traditional spreadsheet/grid view.
- **`GtkGridView`** — 2D grid view backed by a `GListModel`, with
  customizable cell size.

These widget-internal layouts are not pluggable `GtkLayoutManager`s — they
are tightly coupled to the widget that hosts them. But conceptually they
behave like specialized layouts. For comparable patterns in TUI land, see
the [`../tui-libraries/textual.md`](../tui-libraries/textual.md) doc on
Textual's `ListView` / `OptionList` widgets.

### A complete example: form with constraint-based alignment

```c
GtkWidget *win = gtk_window_new();
gtk_window_set_default_size(GTK_WINDOW(win), 480, 320);

GtkWidget *area = gtk_widget_new(GTK_TYPE_WIDGET, NULL);
gtk_window_set_child(GTK_WINDOW(win), area);

GtkLayoutManager *clay = gtk_constraint_layout_new();
gtk_widget_set_layout_manager(area, clay);
GtkConstraintLayout *cl = GTK_CONSTRAINT_LAYOUT(clay);

GtkWidget *name_label = gtk_label_new("Name:");
GtkWidget *name_entry = gtk_entry_new();
GtkWidget *mail_label = gtk_label_new("Email:");
GtkWidget *mail_entry = gtk_entry_new();
GtkWidget *ok_button  = gtk_button_new_with_label("Save");

gtk_widget_set_parent(name_label, area);
gtk_widget_set_parent(name_entry, area);
gtk_widget_set_parent(mail_label, area);
gtk_widget_set_parent(mail_entry, area);
gtk_widget_set_parent(ok_button,  area);

const char *vfl[] = {
    "H:|-12-[name_label]-8-[name_entry]-12-|",
    "H:|-12-[mail_label]-8-[mail_entry]-12-|",
    "H:[ok_button(>=80)]-12-|",
    "V:|-12-[name_label]-8-[mail_label]-(>=16)-[ok_button]-12-|",
    "V:[name_entry(==name_label)]",
    "V:[mail_entry(==mail_label)]",
};

GHashTable *views = g_hash_table_new(g_str_hash, g_str_equal);
g_hash_table_insert(views, (gpointer)"name_label", name_label);
g_hash_table_insert(views, (gpointer)"name_entry", name_entry);
g_hash_table_insert(views, (gpointer)"mail_label", mail_label);
g_hash_table_insert(views, (gpointer)"mail_entry", mail_entry);
g_hash_table_insert(views, (gpointer)"ok_button",  ok_button);

GError *err = NULL;
gtk_constraint_layout_add_constraints_from_descriptionv(
    cl, vfl, G_N_ELEMENTS(vfl), 8, 8, views, &err);

gtk_window_present(GTK_WINDOW(win));
```

In about 30 lines, this composes a two-field form with consistent baseline
alignment between labels and entries, a save button anchored to the bottom
right, and a flexible vertical gap that absorbs window resize. The same
layout in `GtkBox`/`GtkGrid` would need explicit nesting and several
expansion flags; in `GtkConstraintLayout` it reads almost like the visual
description.

### Comparing GTK 4 to GTK 3

The key shift from GTK 3 to GTK 4 in the layout space:

| Concept                   | GTK 3                                                                      | GTK 4                                                                 |
| ------------------------- | -------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Layout algorithm location | Each container subclasses `GtkContainer` and implements its own algorithm. | Separate `GtkLayoutManager` object attached via `set_layout_manager`. |
| Pack semantics            | `gtk_box_pack_start`/`pack_end` with `expand`/`fill`/`padding` per child.  | `gtk_box_append`/`prepend` + widget's universal `hexpand`/`halign`.   |
| Margins                   | `margin-left`/`margin-right` (LTR-specific).                               | `margin-start`/`margin-end` (logical, RTL-aware).                     |
| Custom layouts            | Subclass `GtkContainer` (large, complex base class).                       | Subclass `GtkLayoutManager` (small, focused base class).              |
| Constraint solving        | Not built in.                                                              | `GtkConstraintLayout` ships with the toolkit.                         |
| `GtkAlignment` widget     | Used to wrap a child for alignment.                                        | Removed — use universal `halign`/`valign` properties.                 |
| `GtkVBox`, `GtkHBox`      | Distinct widget classes.                                                   | Removed — use `GtkBox` with `orientation` property.                   |

Migration is mostly mechanical: the new APIs are smaller and more orthogonal
than the old ones. The biggest gain is composability — once you understand
`GtkLayoutManager`, you can mix and match layouts in ways that GTK 3
required widget surgery to achieve.

---

## Strengths and Weaknesses

### Strengths

- **Clean separation of widget and layout.** In GTK 4 the algorithm is a
  swappable strategy object. Changing a `GtkBox` from horizontal to vertical,
  or replacing its `GtkBoxLayout` with a `GtkConstraintLayout`, does not
  require touching the children. This is a strictly better architecture than
  GTK 3's per-container hardcoded layouts.
- **Height-for-width is first-class.** GTK is rare among toolkits in
  modeling orientation-dependent measurement as part of the base widget
  protocol. Text-heavy and resizable UIs work without per-widget hacks.
- **Universal per-widget layout properties.** `halign`, `valign`, `margin-*`,
  `hexpand`, `vexpand` live on every `GtkWidget` and behave identically
  regardless of the parent's layout manager. No equivalent of Qt's "this
  property only matters in `QHBoxLayout`" surprises.
- **Constraint solver in the box.** `GtkConstraintLayout` brings Cassowary
  to the toolkit. For complex compositions that would require deeply nested
  box/grid trees, constraints provide a flatter, more readable description.
- **Logical RTL by default.** `margin-start`/`margin-end` and
  `Layout.alignment` semantics flip automatically for right-to-left
  locales. No conditional code is needed for Arabic/Hebrew layouts.
- **Small, focused layout classes.** Each `GtkLayoutManager` does one thing.
  This is easier to learn than a single sprawling layout class with two
  dozen toggles.
- **Custom layout managers are first-class.** Subclassing `GtkLayoutManager`
  is far simpler than subclassing GTK 3's `GtkContainer`. Hobbyist projects
  routinely ship their own layouts now (e.g. masonry, force-directed,
  hexagon grids).
- **GtkBuilder XML.** Layouts can be expressed declaratively in XML and
  loaded at runtime. The Glade-style designer (now Cambalache) generates
  these files directly.
- **List-view performance.** `GtkListView`/`GtkColumnView`/`GtkGridView`
  recycle row widgets and only instantiate enough widgets to fill the
  viewport, scaling cleanly to millions of items.

### Weaknesses

- **Smaller built-in library than Qt.** Qt ships five core layouts plus
  several specialized variants. GTK 4 has seven layouts in total, several
  of which are very narrow in purpose (`GtkBinLayout`, `GtkCenterLayout`).
  You frequently end up nesting boxes when a single richer layout would do.
- **No per-row/column stretch factors on `GtkGridLayout`.** Distribution of
  extra space comes from `hexpand`/`vexpand` flags on children, which is
  less direct than Qt's `setColumnStretch(col, n)`. Achieving "this column
  is twice as wide as that column" requires either explicit width requests
  or constraint expressions.
- **Per-child layout properties are opaque.** Setting grid placement
  requires going through `GtkGridLayoutChild` or the wrapper API
  (`gtk_grid_attach`), which is fine in C but feels indirect in language
  bindings — Python, JavaScript, and Vala all have to surface a child
  property mechanism.
- **`GtkConstraintLayout` performance.** Cassowary scales well for moderate
  systems but is measurably slower than `GtkBoxLayout` for the simple cases.
  Most app developers default to nested boxes/grids and use constraints
  only for the parts that really need them.
- **Custom layouts must implement measure precisely.** Bugs in `measure()`
  or `allocate()` cause subtle clipping, jitter, and crash-on-resize
  problems. GTK 4 is stricter than GTK 3 about this contract.
- **Migration cost from GTK 3 is significant.** Apps with extensive layout
  code have to relearn the model. There are no automatic translation tools
  for `pack_start`/`pack_end` semantics.
- **Limited declarative syntax.** Unlike Qt Quick's QML, GTK has no
  reactive/declarative layout language. GtkBuilder XML describes a static
  tree, not a function of state. Some projects use Blueprint
  (<https://gnome.pages.gitlab.gnome.org/blueprint-compiler/>) to get a
  more readable surface, but it still produces a static description.
- **Mixing of measure-time and CSS styling.** GTK 4 uses CSS for visual
  styling (colors, fonts, borders) and ignores most layout properties from
  CSS. Newcomers from the web frequently expect `display: flex` to work.

### Comparison to other systems

- **Qt.** See [`./qt-layouts.md`](./qt-layouts.md). Qt's `QLayout`
  hierarchy is conceptually similar but predates GTK 4 by 15 years. Qt
  ships a richer built-in layout library; GTK 4 ships a more orthogonal one
  and adds the Cassowary solver.
- **Cocoa AutoLayout.** GTK's `GtkConstraintLayout` is directly inspired by
  AutoLayout and uses the same VFL syntax (`H:|-[button]-|`, etc.). The
  underlying solver is the same Cassowary algorithm.
- **CSS Flexbox / Grid.** GTK's `GtkBoxLayout` is similar in spirit to
  flexbox single-axis behavior; `GtkGridLayout` is similar to CSS Grid but
  without subgrid or named lines. Both Qt Quick layouts and GTK are less
  expressive than CSS Grid for complex 2D arrangements.
- **Ratatui constraints.** Ratatui (see
  [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)) uses the
  same Cassowary solver via the `kasuari` crate, but applies it to 1D
  splits of rectangles rather than full 2D constraint systems.
- **Ink / Yoga.** See [`../tui-libraries/ink.md`](../tui-libraries/ink.md).
  Yoga implements CSS flexbox over terminal-cell coordinates; the
  layout-manager-as-strategy concept is broadly similar to GTK's, though
  Yoga is a single layout algorithm rather than a family.
- **Textual.** Textual's CSS-like layout syntax (see
  [`../tui-libraries/textual.md`](../tui-libraries/textual.md)) is closer
  to CSS than to GTK, but both share the idea that layout is a separate
  concern from widget identity.

---

## References

- **GTK 4 documentation root.** <https://docs.gtk.org/gtk4/>
- **`GtkLayoutManager` class reference.**
  <https://docs.gtk.org/gtk4/class.LayoutManager.html>
- **Built-in layout managers.**
  - `GtkBoxLayout`: <https://docs.gtk.org/gtk4/class.BoxLayout.html>
  - `GtkGridLayout`: <https://docs.gtk.org/gtk4/class.GridLayout.html>
  - `GtkGridLayoutChild`: <https://docs.gtk.org/gtk4/class.GridLayoutChild.html>
  - `GtkCenterLayout`: <https://docs.gtk.org/gtk4/class.CenterLayout.html>
  - `GtkBinLayout`: <https://docs.gtk.org/gtk4/class.BinLayout.html>
  - `GtkOverlayLayout`: <https://docs.gtk.org/gtk4/class.OverlayLayout.html>
  - `GtkFixedLayout`: <https://docs.gtk.org/gtk4/class.FixedLayout.html>
  - `GtkCustomLayout`: <https://docs.gtk.org/gtk4/class.CustomLayout.html>
  - `GtkConstraintLayout`: <https://docs.gtk.org/gtk4/class.ConstraintLayout.html>
- **Constraint primitives.**
  - `GtkConstraint`: <https://docs.gtk.org/gtk4/class.Constraint.html>
  - `GtkConstraintGuide`: <https://docs.gtk.org/gtk4/class.ConstraintGuide.html>
- **Widget protocol.**
  - `GtkWidget` (measure, allocate, alignment, margins):
    <https://docs.gtk.org/gtk4/class.Widget.html>
  - `GtkSizeRequestMode`:
    <https://docs.gtk.org/gtk4/enum.SizeRequestMode.html>
  - `GtkAlign`: <https://docs.gtk.org/gtk4/enum.Align.html>
- **Container widgets.**
  - `GtkBox`: <https://docs.gtk.org/gtk4/class.Box.html>
  - `GtkGrid`: <https://docs.gtk.org/gtk4/class.Grid.html>
  - `GtkCenterBox`: <https://docs.gtk.org/gtk4/class.CenterBox.html>
  - `GtkOverlay`: <https://docs.gtk.org/gtk4/class.Overlay.html>
  - `GtkFixed`: <https://docs.gtk.org/gtk4/class.Fixed.html>
  - `GtkPaned`: <https://docs.gtk.org/gtk4/class.Paned.html>
  - `GtkStack`: <https://docs.gtk.org/gtk4/class.Stack.html>
  - `GtkRevealer`: <https://docs.gtk.org/gtk4/class.Revealer.html>
  - `GtkScrolledWindow`: <https://docs.gtk.org/gtk4/class.ScrolledWindow.html>
- **List/grid views.**
  - `GtkListBox`: <https://docs.gtk.org/gtk4/class.ListBox.html>
  - `GtkFlowBox`: <https://docs.gtk.org/gtk4/class.FlowBox.html>
  - `GtkListView`: <https://docs.gtk.org/gtk4/class.ListView.html>
  - `GtkColumnView`: <https://docs.gtk.org/gtk4/class.ColumnView.html>
  - `GtkGridView`: <https://docs.gtk.org/gtk4/class.GridView.html>
- **GTK 4 migration and history.**
  - Migration guide (GTK 3 to 4):
    <https://docs.gtk.org/gtk4/migrating-3to4.html>
  - GTK 4.0 release announcement (2020):
    <https://blog.gtk.org/2020/12/16/gtk-4-0/>
  - Visual index / widget gallery:
    <https://docs.gtk.org/gtk4/visual_index.html>
- **Constraint solver background.**
  - Cassowary algorithm paper, Badros & Borning (1998):
    <https://constraints.cs.washington.edu/solvers/cassowary-tochi.pdf>
  - Cocoa AutoLayout (the original VFL):
    <https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/>
- **Cross-references in this catalog.**
  - Qt layouts: [`./qt-layouts.md`](./qt-layouts.md)
  - Ratatui constraint layout:
    [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)
  - Ink / Yoga / Flexbox:
    [`../tui-libraries/ink.md`](../tui-libraries/ink.md)
  - Textual CSS-like layout:
    [`../tui-libraries/textual.md`](../tui-libraries/textual.md)
