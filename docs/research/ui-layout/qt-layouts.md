# Qt Layouts (Qt Widgets and Qt Quick)

A mature, explicit, widget-oriented layout system built around a hierarchy of
`QLayout` managers, a two-axis `QSizePolicy` per widget, and per-item stretch
factors. Qt Quick (QML) adds a complementary declarative model with attached
properties, item positioners, and anchor-based positioning.

| Field            | Value                                                               |
| ---------------- | ------------------------------------------------------------------- |
| Language         | C++ (Qt Widgets), QML (Qt Quick)                                    |
| License          | LGPLv3 / GPL / Commercial                                           |
| Vendor           | The Qt Company / Qt Project                                         |
| Documentation    | <https://doc.qt.io/qt-6/layout.html>                                |
| First Released   | Qt 1.0 (1995); modern `QLayout` hierarchy stabilized in Qt 4 (2005) |
| Version snapshot | Qt 6 Widgets API; Qt 6.0 shipped in 2020                            |
| Sub-API          | `QtWidgets`, `QtQuick.Layouts`, `QtQuick` positioners, QML anchors  |

---

## Overview

Qt is one of the longest-lived cross-platform UI toolkits in production. Its
layout system predates CSS Flexbox by more than a decade and has evolved
through five major versions while retaining a remarkably stable conceptual
core. Most desktop and embedded Qt applications still rely on the original
`QHBoxLayout` / `QVBoxLayout` / `QGridLayout` triad introduced in early Qt and
modernized in Qt 4.

**What Qt's layout system solves.** Native desktop UIs need to deal with
several thorny problems at once: localized text of varying length, fonts and
DPI that differ between platforms, user-driven window resizing, accessibility
constraints, and (more recently) high-DPI displays and dark/light theme
switching. Qt's response is a _measure-then-arrange_ protocol where every
widget reports a `sizeHint()` (preferred), `minimumSizeHint()` (smallest
sensible), and a `QSizePolicy` (how the widget reacts to extra or insufficient
space along each axis). Layout managers aggregate those signals from their
children and produce a geometry assignment.

**Two flavors of layout.** Qt Widgets (`QWidget`-based, C++) and Qt Quick
(`QtQuick`-based, QML + JavaScript) present the same conceptual model with
different surfaces. In Qt Widgets, layouts are first-class C++ objects
(`QLayout` subclasses) installed on a `QWidget` container. In Qt Quick, layout
managers are QML types (`RowLayout`, `ColumnLayout`, `GridLayout`) that
participate alongside two older positioning systems: declarative _anchors_
(`anchors.left: parent.left`) and _item positioners_ (`Row`, `Column`, `Grid`,
`Flow`) that arrange children without sizing them.

**Design philosophy.** Qt layouts are _explicit_ rather than _implicit_:
nothing is laid out by default. A bare `QWidget` containing children with no
`QLayout` attached will leave those children at `(0, 0)`. This was a deliberate
choice — Qt does not impose a layout model the way HTML does block flow — but
it means every widget that participates in resizing must opt in through a
layout. Once installed, a layout _owns_ the geometry of its children: trying
to set `widget->setGeometry(...)` on a child managed by a layout will simply
be overwritten on the next resize event.

**Lineage and influence.** Qt's two-pass model (compute hints, then assign
geometry) closely resembles WPF's measure/arrange pass and predates it by
roughly a decade. Unlike WPF, however, Qt has no star-sizing (`*` and `Auto`
in grid columns); instead it uses integer **stretch factors** per item or per
row/column, plus the `QSizePolicy` enum on each widget. Qt Quick layouts
introduced attached properties (`Layout.fillWidth`, `Layout.preferredWidth`,
etc.) that closely echo the WPF / XAML attached-property pattern, and the
constraint-based `GtkConstraintLayout` in GTK 4 was directly inspired by Qt's
long-standing flirtation with constraint solvers (the Qt Quick declarative
binding system has Cassowary-like dataflow semantics).

---

## Layout Model

### The two-pass protocol

Every Qt layout pass works in two phases, propagated up and down the widget
tree:

1. **Measurement.** Each widget reports three numbers per axis: minimum size,
   maximum size, and `sizeHint()`. A composite layout (e.g. `QHBoxLayout`)
   aggregates those values from its children by walking the list of items,
   applying spacing and contents margins, and producing its own minimum,
   maximum, and `sizeHint()`. If a child widget overrides `heightForWidth()`
   (used by word-wrapped labels, for example), the layout participates in a
   secondary height-for-width measurement.

2. **Allocation.** Once the parent decides on a final geometry, the layout's
   `setGeometry(QRect)` method is called. The layout walks its items again,
   assigning each one a rectangle inside the available area. Allocation
   respects (in order): minimum sizes, then `QSizePolicy::Fixed` items, then
   stretch factors, then the `QSizePolicy::Expanding` policy, then any leftover
   space distributed back to non-expanding items.

This protocol mirrors the WPF measure/arrange pass closely. Where WPF uses
`Auto`, `Pixel`, and `*` (star) for grid sizing, Qt uses a combination of a
`QSizePolicy` enum on each child widget and an _integer stretch factor_ (per
child within a box layout, or per row/column within a grid).

### The `QLayout` hierarchy

All Qt Widgets layouts inherit from `QLayout`, which itself inherits from
`QLayoutItem`. A layout is therefore a layout item — that is what makes
nesting possible.

```
QLayoutItem (abstract)
   |
   +-- QWidgetItem      (wraps a single QWidget)
   +-- QSpacerItem      (blank space, fixed or expanding)
   +-- QLayout (abstract)
        |
        +-- QBoxLayout
        |     +-- QHBoxLayout
        |     +-- QVBoxLayout
        +-- QGridLayout
        +-- QFormLayout
        +-- QStackedLayout
```

The five concrete layout classes cover the vast majority of widget UIs. There
are also third-party flow layouts and grid-bag layouts in the Qt examples,
but the built-in five are conceptually complete.

### `QHBoxLayout` and `QVBoxLayout`

These are the workhorses: arrange children in a single row (horizontal) or
column (vertical). Each child has an optional **stretch factor** (an integer,
default 0) and an optional **alignment**.

```cpp
#include <QHBoxLayout>
#include <QPushButton>
#include <QLineEdit>

QWidget* makeToolbar()
{
    auto* container = new QWidget;
    auto* row = new QHBoxLayout(container);
    row->setContentsMargins(8, 4, 8, 4);
    row->setSpacing(6);

    auto* search = new QLineEdit;
    auto* go     = new QPushButton(QObject::tr("Go"));
    auto* cancel = new QPushButton(QObject::tr("Cancel"));

    // search expands to fill leftover space (stretch=1);
    // the two buttons stay at their sizeHint.
    row->addWidget(search, /*stretch=*/1);
    row->addWidget(go);
    row->addWidget(cancel);

    return container;
}
```

Several conventions are worth noting:

- The `QHBoxLayout(container)` constructor automatically installs the layout
  on the container widget. There is no separate `setLayout()` call.
- `addWidget(widget, stretch, alignment)` accepts an optional integer stretch
  factor and an optional `Qt::Alignment` flag. The signature is overloaded.
- Inserting `row->addStretch(1)` adds a _spacer_ with `Expanding` policy and
  the given stretch factor — a common idiom for pushing widgets to one end.
- Margins are set via `setContentsMargins(left, top, right, bottom)` (with a
  no-argument convenience getter) and inter-item spacing via `setSpacing`.

### `QGridLayout`

The most flexible 2D layout: place widgets in row/column cells with optional
spans. Stretch factors are set per row and per column.

```cpp
auto* grid = new QGridLayout(container);
grid->setContentsMargins(10, 10, 10, 10);
grid->setHorizontalSpacing(8);
grid->setVerticalSpacing(4);

// Place title spanning columns 0..2 on row 0.
grid->addWidget(title, /*row=*/0, /*col=*/0, /*rowspan=*/1, /*colspan=*/3);

// Two-column form on rows 1..3.
grid->addWidget(new QLabel("Name:"),    1, 0);
grid->addWidget(nameEdit,               1, 1);
grid->addWidget(new QLabel("Email:"),   2, 0);
grid->addWidget(emailEdit,              2, 1);
grid->addWidget(new QLabel("Comment:"), 3, 0, Qt::AlignTop);
grid->addWidget(commentEdit,            3, 1);

// Buttons on the right at row 4.
auto* buttons = new QHBoxLayout;
buttons->addStretch(1);
buttons->addWidget(okButton);
buttons->addWidget(cancelButton);
grid->addLayout(buttons, 4, 0, 1, 2);

// Column 1 (the field column) absorbs extra horizontal space.
grid->setColumnStretch(0, 0);
grid->setColumnStretch(1, 1);

// The comment row absorbs extra vertical space.
grid->setRowStretch(3, 1);
```

Key API:

- `addWidget(widget, fromRow, fromCol, rowSpan, colSpan, alignment)` — the
  6-argument overload provides span support. A `rowSpan` or `colSpan` of `-1`
  extends to the bottom/right edge of the grid.
- `addLayout(...)` nests a sub-layout into a cell.
- `setColumnStretch(col, stretch)` / `setRowStretch(row, stretch)` are how
  rows/columns absorb leftover space.
- `setColumnMinimumWidth(col, px)` / `setRowMinimumHeight(row, px)` force a
  floor.
- `setHorizontalSpacing()` / `setVerticalSpacing()` can be different (unlike
  box layouts which have one `spacing`).

The combination _one expanding column + a final row of stretchy spacer +
column-stretch on the field column_ handles the layout of about 95% of form
dialogs.

### `QFormLayout`

A specialization for two-column "label : field" forms. It tracks alignment
conventions per platform (right-aligned labels on macOS, left-aligned on most
Linux desktops) and exposes two policies that govern resize behavior.

```cpp
auto* form = new QFormLayout;
form->setFieldGrowthPolicy(QFormLayout::AllNonFixedFieldsGrow);
form->setRowWrapPolicy(QFormLayout::WrapLongRows);
form->setLabelAlignment(Qt::AlignRight);

// Each addRow auto-creates a QLabel and sets it as buddy of the field.
form->addRow(tr("&Name:"),    nameEdit);
form->addRow(tr("&Email:"),   emailEdit);
form->addRow(tr("&Comment:"), commentEdit);

// Spanning row (single widget, no label).
form->addRow(disclaimerLabel);
```

The `FieldGrowthPolicy` enum:

| Value                   | Behavior                                                                   |
| ----------------------- | -------------------------------------------------------------------------- |
| `FieldsStayAtSizeHint`  | Fields never exceed their `sizeHint()`. macOS default.                     |
| `ExpandingFieldsGrow`   | Only fields whose `sizePolicy()` is `Expanding` grow. Older Linux default. |
| `AllNonFixedFieldsGrow` | Any field that can grow does. The de-facto default for new code.           |

The `RowWrapPolicy` enum:

| Value          | Behavior                                                          |
| -------------- | ----------------------------------------------------------------- |
| `DontWrapRows` | Labels and fields always share a row.                             |
| `WrapLongRows` | A field wraps below its label when the label runs out of room.    |
| `WrapAllRows`  | Fields are always placed below their labels (mobile-style forms). |

`setRowVisible(int, bool)` (added in Qt 6.4) hides a row without deleting it
— useful for conditional form sections.

### `QStackedLayout`

Holds N children but shows only one at a time. The companion widget
`QStackedWidget` wraps a `QStackedLayout`. Switching the current index emits
`currentChanged(int)`. The `StackingMode` enum supports `StackOne` (default,
hide all but current) and `StackAll` (keep all visible, raise current),
useful for overlay effects.

```cpp
auto* stack = new QStackedLayout(container);
stack->addWidget(welcomePage);   // index 0
stack->addWidget(editorPage);    // index 1
stack->addWidget(settingsPage);  // index 2
stack->setCurrentIndex(1);

QObject::connect(modeCombo, &QComboBox::activated,
                 stack, &QStackedLayout::setCurrentIndex);
```

### `QSplitter` (a layout-shaped widget)

Strictly speaking `QSplitter` is _not_ a `QLayout` — it is a `QWidget` that
contains other widgets directly. But it is the canonical way to do
_interactively resizable_ splits and so is almost always discussed alongside
the layout classes.

```cpp
auto* split = new QSplitter(Qt::Horizontal);
split->addWidget(fileTree);
split->addWidget(editor);
split->addWidget(inspector);

split->setStretchFactor(0, 0);   // file tree: keep its width
split->setStretchFactor(1, 1);   // editor: absorb growth
split->setStretchFactor(2, 0);   // inspector: keep its width

split->setHandleWidth(6);
split->setChildrenCollapsible(true);   // user can drag a pane to width 0

// Persist split positions across sessions.
QSettings settings;
settings.setValue("mainSplit", split->saveState());
// later: split->restoreState(settings.value("mainSplit").toByteArray());
```

Important constraint: `QSplitter` does _not_ accept a `QLayout` as a child.
You add widgets via `addWidget()`, and inside each pane you nest your own
container widget with its own layout.

### `QSizePolicy`: how children react to space

`QSizePolicy` is the per-widget signal that lets the layout manager know how
the widget wants to behave. It has two axes (horizontal, vertical), each set
to a value from the `Policy` enum, plus optional stretch factors.

| `QSizePolicy::Policy` | Bit flags              | Behavior                                                         |
| --------------------- | ---------------------- | ---------------------------------------------------------------- |
| `Fixed`               | (none)                 | Always `sizeHint()`. Cannot grow, cannot shrink.                 |
| `Minimum`             | `GrowFlag`             | `sizeHint()` is minimum, can grow but unwilling.                 |
| `Maximum`             | `ShrinkFlag`           | `sizeHint()` is maximum, can shrink.                             |
| `Preferred`           | `GrowFlag\|ShrinkFlag` | Default. Can grow or shrink around `sizeHint()`.                 |
| `Expanding`           | `Grow\|Shrink\|Expand` | Actively wants extra space. Used by text widgets, lists, etc.    |
| `MinimumExpanding`    | `Grow\|Expand`         | `sizeHint()` is minimum; eager to grow but never shrinks.        |
| `Ignored`             | `Grow\|Shrink\|Ignore` | Disregards `sizeHint()` entirely; takes whatever space is given. |

The flags above (`GrowFlag`, `ShrinkFlag`, `ExpandFlag`, `IgnoreFlag`) compose
each policy. The layout reads them when distributing space: `Expand` widgets
get extra space _before_ `Grow`-only widgets do, and `Ignore` widgets are
always asked last.

`QSizePolicy` also carries per-axis stretch factors (`horizontalStretch`,
`verticalStretch`) and an `hasHeightForWidth` flag for word-wrap-like
widgets. The `ControlType` field is a style hint that lets Qt's per-style
spacing calculator pick the right inter-widget gap for, say, a `PushButton`
next to a `ComboBox`.

### `QSpacerItem`

A blank rectangle with its own size policy. Used to push widgets apart inside
a layout. Two convenience methods on `QBoxLayout` create them inline:

- `addStretch(int factor = 0)` — adds an `Expanding` spacer with the given
  stretch factor.
- `addSpacing(int pixels)` — adds a `Fixed` spacer of the given size.

```cpp
auto* row = new QHBoxLayout;
row->addWidget(prevButton);
row->addStretch(1);                  // pushes the next group to the right
row->addWidget(pageLabel);
row->addSpacing(20);                 // fixed 20px gap
row->addWidget(nextButton);
```

### Alignment

Per-item alignment is set either at the call site
(`layout->addWidget(w, stretch, Qt::AlignRight)`) or after the fact
(`layout->setAlignment(w, Qt::AlignRight | Qt::AlignTop)`). Alignment flags
are bitwise OR-combined `Qt::Alignment` values:

- Horizontal: `Qt::AlignLeft`, `Qt::AlignRight`, `Qt::AlignHCenter`,
  `Qt::AlignJustify`.
- Vertical: `Qt::AlignTop`, `Qt::AlignBottom`, `Qt::AlignVCenter`,
  `Qt::AlignBaseline`.
- Compound: `Qt::AlignCenter` (== `AlignHCenter | AlignVCenter`).

When alignment is set, the widget is placed at its `sizeHint()` rather than
filling the cell — alignment and "fill the cell" are mutually exclusive in
Qt's model. This is one of the surprising-for-beginners behaviors: aligning
a button to `AlignLeft` makes it stop growing horizontally.

### Margins and spacing

Two distinct concepts:

- **Contents margins** — the padding _between the layout and the surrounding
  widget_. Set via `setContentsMargins(left, top, right, bottom)`.
- **Spacing** — the gap _between adjacent items inside the layout_. Set via
  `setSpacing(int)` on box layouts, or `setHorizontalSpacing/setVerticalSpacing`
  on grid/form layouts.

Both default to style-dependent values pulled from `QStyle::PM_LayoutLeftMargin`
and friends, so a Qt app on Windows, macOS, and KDE looks "native" without
the developer hardcoding pixel values.

### `SizeConstraint`

A `QLayout` can constrain its _parent widget's_ size based on the children:

| `QLayout::SizeConstraint` | Effect                                                      |
| ------------------------- | ----------------------------------------------------------- |
| `SetDefaultConstraint`    | Sets the parent's minimum to `minimumSize()`.               |
| `SetFixedSize`            | Locks the parent to `sizeHint()`. Window cannot be resized. |
| `SetMinimumSize`          | Floor on the parent.                                        |
| `SetMaximumSize`          | Ceiling on the parent.                                      |
| `SetMinAndMaxSize`        | Both floor and ceiling.                                     |
| `SetNoConstraint`         | Layout does not constrain the parent.                       |

(Qt 6.10 split this into separate horizontal/vertical constraints, accessible
via `setSizeConstraints(horizontal, vertical)`.)

This is how `QDialog::adjustSize()` makes a dialog snap to its content size,
and how `setFixedSize()` is implemented when applied to a parent that holds a
layout.

### Qt Quick layouts (QML)

Qt Quick has _three_ coexisting positioning systems:

1. **Anchors** — declarative attachment of one edge of an item to another:

   ```qml
   Rectangle {
       anchors.left: parent.left
       anchors.right: parent.right
       anchors.top: header.bottom
       anchors.margins: 8
   }
   ```

   Anchors are computed in a single pass and do not resolve cycles. They are
   fast and idiomatic for relatively simple compositions.

2. **Item positioners** (`Row`, `Column`, `Grid`, `Flow`) — arrange children
   _without resizing_ them. The positioner sets only `x` and `y` on each
   child; the children keep their own intrinsic width/height.

   ```qml
   Row {
       spacing: 6
       Image { source: "icon.png" }
       Text  { text: "Hello" }
   }
   ```

3. **Layouts** (`RowLayout`, `ColumnLayout`, `GridLayout` from
   `QtQuick.Layouts`) — resize children based on attached properties.
   Functionally similar to Qt Widgets layouts, but expressed declaratively
   in QML:

```qml
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls

ApplicationWindow {
    width: 640; height: 400
    visible: true
    title: qsTr("Layout demo")

    RowLayout {
        anchors.fill: parent
        anchors.margins: 8
        spacing: 6

        // Sidebar: fixed-ish width, full height.
        Rectangle {
            Layout.preferredWidth: 180
            Layout.fillHeight: true
            color: "#222"
        }

        // Main content: absorbs all leftover width and height.
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 4

            Label {
                text: qsTr("Title")
                Layout.alignment: Qt.AlignHCenter
            }

            TextArea {
                Layout.fillWidth: true
                Layout.fillHeight: true
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                Button { text: qsTr("OK") }
                Button { text: qsTr("Cancel") }
            }
        }
    }
}
```

The `Layout.*` attached properties echo the Qt Widgets API: `fillWidth`,
`fillHeight`, `preferredWidth/Height`, `minimumWidth/Height`,
`maximumWidth/Height`, `alignment`, `row`, `column`, `rowSpan`, `columnSpan`,
`horizontalStretchFactor`, `verticalStretchFactor`. The `uniformCellSizes`
property on `GridLayout` (Qt 6.6+) forces all rows/columns to the same size.

The takeaway: Qt Quick deliberately keeps positioners and layouts separate.
Positioners are cheap and predictable; layouts are flexible but cost more
per resize. Anchors interoperate with both, but you cannot anchor a child
_and_ place it in a layout simultaneously — the layout takes ownership of
geometry, just like in the Widgets world.

---

## Strengths and Weaknesses

### Strengths

- **Explicit and predictable.** Every widget participates in layout only
  when explicitly opted in. Layout boundaries are visible in code.
- **Mature.** Three decades of polish: rotation handles in `QGraphicsLayout`,
  RTL support baked into `QHBoxLayout`, per-style spacing via `QStyle::layoutSpacing`,
  high-DPI scaling at the layout-engine level.
- **The `QGridLayout` + stretch-factor + spacer combo handles 95% of forms.**
  Once mastered, the same pattern composes for dialogs, document windows,
  tool palettes, and side panels.
- **`QSizePolicy` is verbose but explicit.** Unlike CSS flexbox where space
  distribution depends on the interaction of `flex-grow`, `flex-shrink`,
  `flex-basis`, intrinsic content sizes, and minimum size constraints, Qt
  separates "policy" (what kind of widget is this?) from "stretch" (how
  greedy is it?). Once you internalize the seven `Policy` values, behavior
  is deterministic.
- **Two-axis policy.** Each widget can have completely different behavior
  horizontally vs. vertically. A multi-line text editor is `Expanding`
  vertically but `Preferred` horizontally; a button is `Preferred` both
  ways; a slider is `Expanding` along its axis and `Fixed` across it. There
  is no single-axis "flex" abstraction to fight.
- **Layouts are nestable and replaceable.** Swapping a `QHBoxLayout` for a
  `QVBoxLayout` is a single-line change. The widget tree itself is
  unaffected.
- **Three coexisting models in Qt Quick.** Anchors, positioners, and layouts
  let the developer pick the cheapest tool for each job. A static toolbar
  uses anchors; a list of equal-sized icons uses `Row`; a resizable
  document area uses `ColumnLayout`.
- **Excellent visual designers.** Qt Designer (Widgets) and Qt Design Studio
  (Quick) both have first-class WYSIWYG support, generating clean code that
  mirrors what a developer would write by hand.
- **Save/restore for `QSplitter` and dock layouts.** `saveState()` / `restoreState()`
  serialize user-adjusted geometry to a `QByteArray` for trivial persistence
  across sessions.
- **Localizable.** `QLayout` measures children in logical pixels and respects
  per-platform spacing; localized strings of different lengths re-layout
  automatically without app code.

### Weaknesses

- **Implicit cell sizing is awkward.** Qt has no equivalent of WPF's star
  sizing (`*`, `2*`, `Auto`). Stretch factors approximate `*` weights but
  require setting `setColumnStretch` separately from cell placement, and
  there is no direct "shrink to content" mode at the column level — instead
  you set `QSizePolicy::Fixed` on the child widgets.
- **No constraint solver in Qt Widgets.** Unlike `GtkConstraintLayout` (Cassowary)
  or AutoLayout (iOS/macOS), Qt Widgets has no "this edge equals that edge
  plus 8 pixels" model. You either nest box/grid layouts to approximate the
  effect, or drop down to `QGraphicsLayout` (more flexible but heavier).
- **`QSplitter` is not a layout.** Resizable splits require switching to a
  widget-as-container model; you cannot nest a `QLayout` _inside_ a splitter
  pane (you must wrap the layout in a `QWidget` first).
- **`heightForWidth()` is subtle and rarely correct.** Word-wrapped labels
  and text editors need `hasHeightForWidth()` set on their `QSizePolicy`,
  plus the containing layout must support it, plus the parent widget must
  participate. Many third-party widgets break in subtle ways when given a
  width-constrained vertical layout.
- **Stretch factor semantics differ from CSS.** Where flex's `flex-grow: 1`
  shares leftover space evenly, Qt's stretch factor is proportional but
  _bounded by `QSizePolicy`_. A widget with `Fixed` policy and stretch=1
  will not grow at all. Newcomers from web backgrounds find this
  counterintuitive.
- **Three positioning systems in Qt Quick is two too many.** Anchors,
  positioners, and layouts have overlapping but non-identical semantics.
  Mixing them in one parent (e.g., anchoring an item inside a `ColumnLayout`)
  is a runtime error.
- **No declarative layout in Qt Widgets.** Layouts are imperatively
  constructed in C++. Qt Designer generates `.ui` files which are XML, but
  the runtime API is still imperative `addWidget(...)` calls.
- **High-DPI quirks.** Qt 5.6+ does most of the right thing for high-DPI,
  but pixel-perfect alignment of layouts mixed with manually-drawn content
  (`QPainter`) still requires care. Some apps still ship `Qt::HighDpiScaleFactorRoundingPolicy`
  configuration to paper over rounding.
- **Designer-generated code is verbose.** A simple form dialog produces
  hundreds of lines of `setupUi()` boilerplate, much of it `setObjectName()`
  calls and translation infrastructure.

### Comparison to other systems

- **WPF.** Both use a measure/arrange pass. WPF has star sizing (`*`, `Auto`);
  Qt has stretch factors + size policy. WPF has `Grid.Row`, `Grid.Column`
  attached properties; Qt has them too in QML (`Layout.row`, `Layout.column`)
  but uses positional arguments in C++. WPF's `Canvas` and `StackPanel` map
  closely to Qt's `QGraphicsScene` and `QBoxLayout`.
- **CSS Flexbox.** Conceptually similar (main axis, cross axis, stretch),
  but Qt's policy/stretch decomposition is more explicit. Flexbox's
  `flex-basis` has no clean Qt analogue. See also Ink's Yoga-based model in
  [`../tui-libraries/ink.md`](../tui-libraries/ink.md).
- **GTK 4.** GTK 4's `GtkLayoutManager` (see [`gtk.md`](gtk.md)) is closer
  in spirit to Qt's `QLayout` — a swappable algorithm attached to a widget —
  but ships with fewer built-in layouts and adds a Cassowary-based
  constraint layout that Qt does not include.
- **Ratatui constraints.** Ratatui's `Length`/`Fill`/`Min`/`Max`/`Percentage`
  (see [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)) covers
  similar ground to Qt's stretch factors + size policy, but is constraint-
  solver-based (Cassowary via the `kasuari` crate) and is purely 1D per call.
- **Textual (Python).** Textual's CSS-like layout system (see
  [`../tui-libraries/textual.md`](../tui-libraries/textual.md)) borrows
  flexbox grammar; closer to Qt Quick `Layout.*` attached properties than to
  Qt Widgets' imperative API.

---

## References

- **Qt Widgets Layout Management.**
  <https://doc.qt.io/qt-6/layout.html>
- **`QLayout` class reference.**
  <https://doc.qt.io/qt-6/qlayout.html>
- **Per-layout references.**
  - `QHBoxLayout`: <https://doc.qt.io/qt-6/qhboxlayout.html>
  - `QVBoxLayout`: <https://doc.qt.io/qt-6/qvboxlayout.html>
  - `QBoxLayout`: <https://doc.qt.io/qt-6/qboxlayout.html>
  - `QGridLayout`: <https://doc.qt.io/qt-6/qgridlayout.html>
  - `QFormLayout`: <https://doc.qt.io/qt-6/qformlayout.html>
  - `QStackedLayout`: <https://doc.qt.io/qt-6/qstackedlayout.html>
- **Size policies and layout items.**
  - `QSizePolicy`: <https://doc.qt.io/qt-6/qsizepolicy.html>
  - `QLayoutItem`: <https://doc.qt.io/qt-6/qlayoutitem.html>
  - `QSpacerItem`: <https://doc.qt.io/qt-6/qspaceritem.html>
- **`QSplitter` (interactive split widget).**
  <https://doc.qt.io/qt-6/qsplitter.html>
- **Qt Quick Layouts.**
  - `RowLayout`: <https://doc.qt.io/qt-6/qml-qtquick-layouts-rowlayout.html>
  - `ColumnLayout`: <https://doc.qt.io/qt-6/qml-qtquick-layouts-columnlayout.html>
  - `GridLayout`: <https://doc.qt.io/qt-6/qml-qtquick-layouts-gridlayout.html>
  - `Layout` attached properties:
    <https://doc.qt.io/qt-6/qml-qtquick-layouts-layout.html>
  - Overview: <https://doc.qt.io/qt-6/qtquicklayouts-overview.html>
- **Qt Quick positioners and anchors.**
  - Item positioners (`Row`, `Column`, `Grid`, `Flow`):
    <https://doc.qt.io/qt-6/qtquick-positioning-layouts.html>
  - Anchor-based layout:
    <https://doc.qt.io/qt-6/qtquick-positioning-anchors.html>
- **History.**
  - Qt 1.0 release (1995):
    <https://en.wikipedia.org/wiki/Qt_(software)#Release_history>
  - Qt 4 "Layout management" redesign:
    <https://doc.qt.io/archives/qt-4.8/layout.html>
- **Cross-references in this catalog.**
  - Ratatui constraint layouts:
    [`../tui-libraries/ratatui.md`](../tui-libraries/ratatui.md)
  - Ink / Flexbox via Yoga:
    [`../tui-libraries/ink.md`](../tui-libraries/ink.md)
  - Textual's CSS-like layout:
    [`../tui-libraries/textual.md`](../tui-libraries/textual.md)
  - GTK 4 layout managers:
    [`./gtk.md`](./gtk.md)
