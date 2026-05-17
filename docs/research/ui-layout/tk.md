# Tk Geometry Managers (pack / grid / place)

The trio of geometry managers — `pack`, `grid`, and `place` — that ship with
the Tk widget toolkit (the X11 / Windows / macOS GUI toolkit created by John
Ousterhout in 1990 alongside Tcl). `pack` was the original; it predates CSS
Flexbox by nineteen years and is the conceptual ancestor of nearly every
"box-with-direction-and-fill" layout system that followed. `grid` arrived in
1996 and pioneered the row/column/sticky model that re-emerged in CSS Grid
two decades later. `place` covers the absolute-positioning escape hatch.
Together they form a coherent, three-tier approach to GUI layout that is
unusually concise — `pack {.toolbar} -side top -fill x` is a complete
"sticky horizontal toolbar" in one line.

| Field            | Value                                                                                                                                                                                                                  |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language         | Tcl (with first-class bindings for Python (`tkinter`), Perl (`Tk` / `Tkx`), Ruby (`ruby-tk`), Common Lisp (`Lisp-Tk`), Haskell, more)                                                                                  |
| License          | Tcl/Tk License (BSD-style, permissive)                                                                                                                                                                                 |
| Repository       | <https://core.tcl-lang.org/tk/timeline> (Fossil); GitHub mirror <https://github.com/tcltk/tk>                                                                                                                          |
| Documentation    | <https://www.tcl-lang.org/man/> (man pages), <https://tkdocs.com/> (tutorial)                                                                                                                                          |
| Version snapshot | Tk 9.0.2 (July 2025); long-lived 8.6 series still common                                                                                                                                                               |
| Notable adoption | Python's standard-library `tkinter`; IDLE (Python's reference IDE); `pgAdmin` (PostgreSQL admin); historically the AOLserver admin UI; Moneydance, Eagle Mode, many engineering and scientific GUIs across Linux / BSD |

---

## Overview

### What It Solves

Tk's geometry managers solve the fundamental GUI layout problem: given a
container (in Tk terminology, a _master_ or, since Tk 8.5, a _parent_) and a
set of child widgets (_slaves_ / _children_) with intrinsic "natural" sizes,
position and size each child within the container so that:

- The container's size accommodates its contents (or imposes a fixed size).
- Resizing the container redistributes available space sensibly.
- The layout adjusts when children appear, disappear, or change size.

The Tk approach is to _separate widget creation from widget placement_.
Creating a button does not display it; it only allocates the widget object.
Display happens only when one of the three geometry managers takes ownership
of the widget and assigns it space in a parent. This separation is enforced
by the API: `Button .ok` creates the button, `pack .ok` places it.

Three managers cover three distinct mental models:

- **`pack`** — sequential placement. "Cram this widget onto the top edge of
  whatever space is left." The model is _cavity_-based: each placement
  subtracts a strip from the remaining cavity.

- **`grid`** — row/column placement. "Put this widget in cell (row 2,
  column 3). When the window grows, give the extra space to columns with
  weight." The conceptual ancestor of CSS Grid.

- **`place`** — absolute placement. "Put this widget at (x, y), or at
  (relx, rely) as a fraction of the parent." Used rarely, for special cases.

### Design Philosophy

The geometry managers embody several decisions that have aged well:

- **Each child is managed by exactly one geometry manager at a time, in one
  parent at a time.** Switching managers (calling `grid .x` after `pack .x`)
  transfers ownership. The constraint is enforced per-parent: a single
  parent should be managed entirely by one of `pack`, `grid`, or `place`.
  Folklore says "never mix `pack` and `grid` in the same container" — see the
  [Mixing Managers](#mixing-managers-the-pack-vs-grid-folklore) section
  below.

- **Layout is _relational_, not absolute.** `pack` expresses "put this above
  that" and "this fills the remaining horizontal space." `grid` expresses
  "this is in column 1 and stretches with `-sticky we`." Neither requires
  the author to compute pixel coordinates. (`place` is the explicit exception
  for the rare case where pixel coordinates are wanted.)

- **Natural size first, fitting second.** Each widget reports a _requested_
  size (its natural size, computed from its content and configuration). The
  geometry manager respects that as the floor, then applies fill / expand /
  sticky rules to decide whether to stretch beyond it. A `Label "Quit"`
  remains a small button-sized box unless explicitly asked to grow.

- **Container shrinks to fit children, by default.** A frame with no explicit
  size adopts the bounding box of its packed/gridded contents. This is the
  inverse of CSS, where most blocks default to filling their containing
  block's width.

- **Geometry options are _configuration_, not code.** All options
  (`-side`, `-fill`, `-sticky`, `-padx`, `-weight`) are passed as
  `-name value` pairs to the manager command. There is no separate
  "layout DSL" — the same Tcl command syntax that creates widgets configures
  their layout.

### History

- **1988–1990: Tcl is born.** John Ousterhout, then at UC Berkeley, creates
  Tcl as an embeddable command language for the design-automation tools his
  group is building.

- **1990: Tk emerges.** Ousterhout begins work on Tk as a Tcl extension for
  building GUIs on the X Window System. The original geometry manager,
  `placer` (the ancestor of `place`), is joined by `packer` (the ancestor of
  `pack`). The `pack` model — "shove this widget toward the top/bottom/left/
  right edge of the remaining space" — proves vastly more usable than
  pixel-coordinate placement.

- **1991: First public Tk release.** Tk 1.0 ships, packaged with Tcl. The
  combination becomes wildly popular as a rapid-prototyping toolkit on Unix,
  partly because it was substantially easier than Motif / Athena Widgets /
  Xaw.

- **1994: Python's Tkinter.** Steen Lumholt and Guido van Rossum bind Tk into
  Python's standard library as `Tkinter` (later `tkinter`). To this day, Tk
  is the GUI toolkit Python ships with by default. Perl/Tk (Nick Ing-Simmons)
  follows soon after.

- **1996: `grid` is introduced.** Tk 4.1 adds the `grid` geometry manager,
  designed for the alignment-based form layouts (aligned labels, aligned
  entries, stretchy cells) that `pack` could only express awkwardly. `grid`
  introduces the _sticky_ model (`n s e w` and combinations), _row/column
  configure_ for weights, and _spanning_.

- **1997: ACM Software System Award.** Ousterhout receives the ACM Software
  System Award for "creating a simple mechanism for creating graphical user
  interfaces."

- **1997: Tk 8.0.** Native look-and-feel arrives on Windows and Macintosh.
  Tk transitions from a Unix-only toolkit to a true cross-platform one.

- **2007: Tk 8.5.** A major revival: themed widgets (`ttk`), the new
  geometry-aware `panedwindow`, and improvements to font and Unicode handling.

- **2013: Tk 8.6.** PNG support, angled-text, and other modernizations.

- **2024–2025: Tk 9.0.** UTF-32 internals (full Unicode 15 support), 64-bit
  size limits, and modernization of the C API. Tk's design — including the
  geometry managers — is preserved essentially intact across the entire
  three-decade history.

The influence of `pack` and `grid` is hard to overstate. AWT's `BorderLayout`
and `FlowLayout`, Java Swing's `BoxLayout` and `GridBagLayout`, GTK's
`GtkBox` and `GtkGrid`, Qt's `QHBoxLayout` / `QVBoxLayout` / `QGridLayout`,
WPF's `StackPanel` and `Grid` — every one of these owes a direct conceptual
debt to Tk's geometry managers. CSS Flexbox arrived in 2012 with semantics
that, on inspection, look like `pack` with prettier names (`flex-direction:
row` ↔ `pack ... -side left`, `align-self` ↔ `-anchor`, `flex-grow` ↔
`-expand`).

---

## Layout Model

Tk has three geometry managers, summarized:

| Manager | Mental model                           | Best for                                                      | Year added         |
| ------- | -------------------------------------- | ------------------------------------------------------------- | ------------------ |
| `pack`  | Pack widgets into a cavity             | Toolbars, status bars, simple side-by-side / stacked layouts. | 1990               |
| `grid`  | Row / column table                     | Form layouts, aligned grids, two-dimensional UIs.             | 1996               |
| `place` | Absolute or relative pixel coordinates | Splash screens, draggable overlays, edge-anchored widgets.    | 1990 (as `placer`) |

### `pack`: The Cavity Algorithm

The conceptual model: the parent has a rectangular _cavity_. Each call to
`pack` claims a strip from one edge of the cavity (the side specified by
`-side`), reducing the cavity for subsequent packs. The widget receives a
_parcel_ — the strip it just claimed — and its placement within that parcel
depends on `-fill` (whether to expand into the parcel) and `-anchor` (where
to sit within an unfilled parcel).

**Command syntax.**

```tcl
pack widget ?widget ...? ?options?
pack configure widget ?widget ...? ?options?
pack forget widget ?widget ...?
pack info widget
pack propagate parent ?boolean?
pack slaves parent
```

`pack widget` is shorthand for `pack configure widget`. All forms accept the
following per-widget options:

| Option              | Default  | Meaning                                                                                         |
| ------------------- | -------- | ----------------------------------------------------------------------------------------------- |
| `-side`             | `top`    | Which edge of the _remaining cavity_ to attach the widget to: `top`, `bottom`, `left`, `right`. |
| `-fill`             | `none`   | Stretch the widget within its parcel: `none`, `x`, `y`, `both`.                                 |
| `-expand`           | `0`      | Whether the _parcel itself_ grows to claim unused cavity space. Boolean.                        |
| `-anchor`           | `center` | Position the widget within its parcel: `n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`, `center`.    |
| `-padx`, `-pady`    | `0`      | External padding (outside the widget, inside the parcel).                                       |
| `-ipadx`, `-ipady`  | `0`      | Internal padding (added to the widget's natural size before placement).                         |
| `-before`, `-after` | --       | Insert this widget in the packing order before / after another packed widget.                   |
| `-in`               | parent   | Pack this widget into a different parent than its logical parent.                               |

**The algorithm.** Given a parent with cavity `C` (initially the parent's
content area) and a list of packed children in order:

1. Take the next child `w`.
2. Allocate a _parcel_ from the cavity along the side specified by `w`'s
   `-side`:
   - For `-side top` or `-side bottom`: the parcel spans the full _width_ of
     the cavity. Its _height_ is `w`'s natural height (plus padding), or
     more if `-expand 1`.
   - For `-side left` or `-side right`: the parcel spans the full _height_
     of the cavity. Its _width_ is `w`'s natural width (plus padding), or
     more if `-expand 1`.
3. Subtract the parcel from the cavity.
4. Place `w` inside its parcel according to `-fill` and `-anchor`.
5. Repeat for the next child.

Crucially, `-side top` claims a parcel spanning the _current_ cavity's full
width — not the parent's full width. If you `pack .a -side left` first, then
`pack .b -side top`, `.b`'s parcel is only as wide as the cavity _minus_ the
strip `.a` took on the left.

This is what gives `pack` its characteristic conciseness for "edge plus
center" layouts but also its surprises: the order of `pack` calls matters,
and inserting a new packed widget in the middle of a layout can reshape
everything that follows.

**A canonical example: a window with a toolbar, status bar, and main area.**

```tcl
# Frames for the regions
frame .toolbar -bg lightgray -height 30
frame .status  -bg gray80    -height 20
frame .main    -bg white

# Pack the toolbar at the top, full width
pack .toolbar -side top -fill x

# Pack the status bar at the bottom, full width
pack .status  -side bottom -fill x

# Pack the main area to fill all remaining space
pack .main    -side top -fill both -expand 1
```

The cavity walk:

1. `.toolbar`: claims a 30-px strip across the top. Cavity is now
   "everything except the top 30 px".
2. `.status`: claims a 20-px strip across the bottom of the _remaining
   cavity_ (i.e. across the full width again). Cavity is now "middle
   region between toolbar and status bar".
3. `.main`: with `-fill both -expand 1`, it fills the entire remaining
   cavity and the parcel grows on resize.

This is a complete, idiomatic Tk toolbar-and-status-bar layout in three
lines. The CSS-Flexbox equivalent — `display: flex; flex-direction: column`
with the body as `flex: 1` — takes more markup and CSS but expresses the
same idea.

**A side-by-side example: a tree view next to a detail pane.**

```tcl
frame .left  -width 200
frame .right

pack .left  -side left  -fill y
pack .right -side left  -fill both -expand 1
```

Both children pack to the left, claiming vertical strips. The first claims a
200-px-wide strip from the cavity's left edge; the second claims the entire
remaining cavity because of `-expand 1`.

**`-fill` versus `-expand`** is a frequent source of confusion. The parcel
is what `pack` _gave_ the widget; `-expand 1` lets the parcel grow to claim
unused cavity space, while `-fill` controls how the widget fills its parcel:

```tcl
# A button centered in a stretchy parcel
pack .button -side top -expand 1
# (parcel is large; button sits in the middle of it, unstretched)

# A button stretching across a stretchy parcel
pack .button -side top -expand 1 -fill x
# (parcel is large; button stretches horizontally to fill it)

# A button against the top edge, parcel only as tall as the button
pack .button -side top
# (parcel = natural size; widget = natural size)
```

**`-anchor`** positions the widget within its parcel when neither `-fill`
(in the relevant direction) nor `-expand` is enough to fill it. Compass-point
values: `n`, `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`, `center`. The default is
`center`.

**`-padx`, `-pady`** add external padding _outside_ the widget but _inside_
the parcel; `-ipadx`, `-ipady` add internal padding to the widget's natural
size. Either single integers or two-element lists (`{left right}` or
`{top bottom}`):

```tcl
pack .ok     -side right -padx 8 -pady 8
pack .cancel -side right -padx {0 8} -pady 8
```

**Re-ordering with `-before` / `-after`.**

```tcl
pack .new_button -before .ok
```

inserts `.new_button` into the packing order before `.ok`, then re-runs the
cavity algorithm.

**`-in`** allows packing a widget into a non-default parent — useful for
re-parenting in special cases. Most code does not need this.

**`pack propagate`** controls whether a parent shrinks/grows to fit its
packed contents. Default is `true` — a frame with packed children adopts
their bounding-box size. `pack propagate .myframe false` keeps the frame at
its configured `-width`/`-height` regardless of its contents.

### `grid`: Row / Column / Sticky

Added in Tk 4.1 (1996), `grid` is a flat row-and-column model. Each managed
widget is assigned to a cell (or a rectangular block of cells via `-rowspan`
and `-columnspan`). Rows and columns are sized to fit their largest cell's
natural size by default; configurable per-row and per-column weights
distribute extra space when the container is larger than the natural size.

**Command syntax.**

```tcl
grid widget ?widget ...? ?options?
grid configure widget ?widget ...? ?options?
grid forget widget ?widget ...?
grid info widget
grid slaves parent ?-row r? ?-column c?
grid size parent
grid bbox parent ?column row? ?column2 row2?
grid rowconfigure    parent index ?-option value ...?
grid columnconfigure parent index ?-option value ...?
grid propagate parent ?boolean?
grid anchor parent ?anchor?
grid remove widget ?widget ...?
```

**Per-widget options.**

| Option                    | Default | Meaning                                                                                                                |
| ------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------- |
| `-row`, `-column`         | --      | Cell coordinates. Non-negative integers, need not be contiguous.                                                       |
| `-rowspan`, `-columnspan` | `1`     | Number of cells (rows or columns) the widget occupies.                                                                 |
| `-sticky`                 | `""`    | Compass-direction string controlling how the widget sticks to the edges of its cell. Any subset of `n`, `s`, `e`, `w`. |
| `-padx`, `-pady`          | `0`     | External padding around the cell.                                                                                      |
| `-ipadx`, `-ipady`        | `0`     | Internal padding added to the widget's natural size.                                                                   |
| `-in`                     | parent  | Grid this widget into a non-default parent.                                                                            |

**`-sticky` semantics.** The most distinctive feature of `grid`. The value
is a string composed of zero or more of the letters `n`, `s`, `e`, `w`,
indicating which edges of the cell the widget should stick to:

- `""` _(default)_ — the widget is placed at its natural size, centered in
  the cell. Extra space is around it.
- `"n"` — the widget is at its natural size, jammed against the top edge.
- `"nw"` — the widget is at its natural size, in the top-left corner.
- `"we"` (or `"ew"`) — the widget _stretches_ horizontally to fill the cell;
  vertical placement is centered.
- `"ns"` — the widget _stretches_ vertically; horizontal placement is
  centered.
- `"nsew"` (or any equivalent permutation) — the widget fills the cell in
  both directions.

The rule: when opposite directions both appear in `-sticky`, the widget
stretches along that axis; otherwise the widget keeps its natural size and is
positioned according to the present directions.

**`grid rowconfigure` and `grid columnconfigure`.** Per-row and per-column
configuration:

| Option     | Default | Meaning                                                                                    |
| ---------- | ------- | ------------------------------------------------------------------------------------------ |
| `-weight`  | `0`     | Share of extra space when the parent grows. Weight `0` means the row/column does not grow. |
| `-minsize` | `0`     | Minimum row/column size in pixels.                                                         |
| `-pad`     | `0`     | Extra padding added to the row/column.                                                     |
| `-uniform` | --      | A group name. Rows or columns in the same uniform group are forced to be the same size.    |

`-uniform` is particularly useful for equally-sized columns regardless of
content:

```tcl
grid columnconfigure . 0 -weight 1 -uniform col
grid columnconfigure . 1 -weight 1 -uniform col
grid columnconfigure . 2 -weight 1 -uniform col
```

makes columns 0, 1, 2 always the same width, even if column 1 contains
wider content than column 0.

**A canonical example: a labelled form.**

```tcl
ttk::label .lblName    -text "Name:"
ttk::entry .entName    -textvariable name
ttk::label .lblEmail   -text "Email:"
ttk::entry .entEmail   -textvariable email
ttk::label .lblNotes   -text "Notes:"
ttk::text  .txtNotes   -height 4
ttk::button .btnOK     -text "OK"     -command submit
ttk::button .btnCancel -text "Cancel" -command cancel

# Labels on the left, entry fields on the right
grid .lblName    -row 0 -column 0 -sticky e  -padx 8 -pady 4
grid .entName    -row 0 -column 1 -sticky we -padx 8 -pady 4

grid .lblEmail   -row 1 -column 0 -sticky e  -padx 8 -pady 4
grid .entEmail   -row 1 -column 1 -sticky we -padx 8 -pady 4

grid .lblNotes   -row 2 -column 0 -sticky ne -padx 8 -pady 4
grid .txtNotes   -row 2 -column 1 -sticky nsew -padx 8 -pady 4

# Buttons spanning both columns, right-aligned
grid .btnCancel  -row 3 -column 0 -sticky e -padx 8 -pady 8
grid .btnOK      -row 3 -column 1 -sticky w -padx 8 -pady 8

# Column 1 (entries) takes all extra horizontal space; row 2 (notes) all extra vertical
grid columnconfigure . 1 -weight 1
grid rowconfigure    . 2 -weight 1
```

Three things to notice:

- Labels use `-sticky e` so they right-align next to their entry fields,
  producing a clean colon-aligned column.
- The notes label uses `-sticky ne` (top-right) because the multi-line text
  area is taller; aligning the label to the top keeps it visually paired
  with the entry's first line.
- `columnconfigure 1 -weight 1` + `rowconfigure 2 -weight 1` means: when the
  window grows, the entry column and the notes row absorb all the new space;
  the label column and the button row stay at their natural sizes.

**Introspection.**

- `grid info .entName` returns the current grid configuration of `.entName`.
- `grid slaves .` (without args) returns all gridded children of `.`,
  optionally filtered by row or column.
- `grid size .` returns `{columns rows}`, the dimensions of the grid.
- `grid bbox . col row` returns the pixel bounding box `{x y w h}` of the
  cell, or `{x1 y1 x2 y2 w h}` for a range.

**`grid remove` vs `grid forget`.** `forget` strips the widget of its grid
options. `remove` hides it but preserves the options, so a subsequent plain
`grid .widget` re-displays it in its original cell. Useful for show/hide
toggles.

**`grid anchor`** controls where the grid as a whole is placed inside the
parent when the grid is smaller than the parent. Default `nw` (top-left).
`center` centers the grid; `e` right-aligns it; etc.

### `place`: Absolute and Relative Placement

The escape hatch. `place` lets the programmer specify pixel coordinates
(`-x`, `-y`) or _relative_ coordinates as a fraction of the parent's size
(`-relx`, `-rely`), as well as absolute or relative sizes (`-width`,
`-height`, `-relwidth`, `-relheight`). It is the only geometry manager that
permits overlapping siblings and the only one with a notion of "fraction of
parent."

**Command syntax.**

```tcl
place widget ?options?
place configure widget ?options?
place forget widget
place info widget
place slaves parent
```

**Options.**

| Option                    | Default  | Meaning                                                                                          |
| ------------------------- | -------- | ------------------------------------------------------------------------------------------------ |
| `-x`, `-y`                | `0`      | Absolute pixel position of the widget's anchor point within the parent.                          |
| `-relx`, `-rely`          | `0.0`    | Relative position as a fraction of the parent's width / height.                                  |
| `-width`, `-height`       | --       | Absolute pixel size, overriding the widget's natural size.                                       |
| `-relwidth`, `-relheight` | --       | Size as a fraction of the parent's size. Use `1.0` to make the widget fill the parent.           |
| `-anchor`                 | `nw`     | Which point of the widget the `-x`/`-y`/`-relx`/`-rely` coordinates refer to.                    |
| `-bordermode`             | `inside` | Whether the parent's border is included in the coordinate system: `inside`, `outside`, `ignore`. |
| `-in`                     | parent   | Place into a different parent.                                                                   |

The `-x`/`-relx` (and `-y`/`-rely`) values _add together_ to give the final
position. This is genuinely useful: "centered, but offset 10 pixels right"
is `-relx 0.5 -x 10 -anchor center`.

**A centered, fixed-size dialog inside its parent.**

```tcl
place .dialog -relx 0.5 -rely 0.5 -anchor center -width 320 -height 200
```

**An overlay covering 80% of the parent.**

```tcl
place .overlay -relx 0.1 -rely 0.1 -relwidth 0.8 -relheight 0.8
```

**A widget anchored to the parent's bottom-right corner with 10-px padding.**

```tcl
place .corner -relx 1.0 -rely 1.0 -x -10 -y -10 -anchor se
```

`place` is rarely used for _primary_ layout — its outputs do not adapt
well to fonts, content changes, or DPI scaling. It excels for:

- Overlay widgets (loading spinners over a main content area).
- Edge-anchored controls (a small status indicator pinned to a corner).
- Drag-to-reposition UI elements (a `bind <B1-Motion>` handler updates
  `-x`/`-y`).
- Layered effects (a banner over a background image).

### Mixing Managers: The `pack`-vs-`grid` Folklore

A long-running piece of Tk folklore says **"never mix `pack` and `grid` in
the same parent."** The technical reason is that each geometry manager
_reads_ its children's requested sizes and _writes_ their actual positions
and sizes; when two managers manage children of the same parent, they fight
over the parent's size and may loop indefinitely (each manager re-reads
sizes that the other just wrote).

The constraint is per-parent, not global. The same window may use `pack`
for the outer layout (toolbar / main / status) and `grid` _inside_ the main
frame (for a form). This is the recommended idiom:

```tcl
# Outer layout uses pack
frame .toolbar
frame .main
frame .status
pack .toolbar -side top    -fill x
pack .status  -side bottom -fill x
pack .main    -side top    -fill both -expand 1

# The .main frame, internally, uses grid
ttk::label  .main.lblName -text "Name:"
ttk::entry  .main.entName
grid .main.lblName -row 0 -column 0 -sticky e
grid .main.entName -row 0 -column 1 -sticky we
grid columnconfigure .main 1 -weight 1
```

The two managers do not interfere because they manage different _parents_.
`place` does not have this issue (it does not require fitting the parent),
so a `place`d overlay can coexist with packed or gridded siblings — it is
often used precisely for floating overlays atop a packed primary layout.

### Two Computation Phases

Conceptually, each geometry manager runs in two phases:

1. **Up phase.** Recursively ask each child its requested size. Compose them
   to compute the parent's natural size.
2. **Down phase.** Given the parent's actual (resized) size, distribute it
   to children according to the manager's rules (cavity for `pack`,
   row/column weights for `grid`, relative fractions for `place`).

The result is a single coherent layout pass. There is no constraint solver,
no iterative settling — the entire layout is computed in two tree walks.
This is one reason Tk has historically been so responsive: layouts that
would require hundreds of milliseconds of solver time in modern web stacks
complete in microseconds in Tk.

`grid` and `pack` honor a parent's `propagate` setting: by default, the
parent's requested size grows or shrinks to match its packed/gridded
contents, but `pack propagate $f 0` (or `grid propagate $f 0`) decouples the
two so the parent retains an explicit `-width`/`-height`.

---

## Strengths and Weaknesses

### For GUI Application Layout (target domain)

**Strengths.**

- **Conciseness.** Three lines for a "toolbar / main / status" layout that
  takes 8 – 15 lines in CSS / Flexbox markup. The Tk maxim "type less than
  you would in a config file" is unusually true for layout code.
- **Direct expression.** The manager command names describe what they do:
  `pack -side top -fill x` reads as "pack to the top, filling x." Authors
  rarely need to translate intent into a layout DSL.
- **Predictable resize behavior.** `-expand` (for `pack`) and `-weight`
  (for `grid` rows / columns) give explicit control over which children
  absorb extra space. The behavior is deterministic; there are no surprises
  from min-content / max-content fluctuations as in some CSS contexts.
- **Decoupled creation and placement.** Widgets can be created (and have
  their content set, event bindings attached, etc.) before any decision
  about layout is made. This is good for code organization: a "create
  widgets" function is independent of a "lay out widgets" function.
- **`-sticky` is uniquely expressive.** A single short string controls four
  axes of alignment and stretching, in a way that compares favorably to the
  combination of `align-self`, `justify-self`, and `width: 100%` it takes
  to express the equivalent in CSS Grid.

**Weaknesses.**

- **The cavity model has nonlocal effects.** Inserting a new packed widget
  changes the cavity for all subsequent widgets. Refactoring a `pack` layout
  is often nonlocal — moving widget A may shift widget B's parcel.
- **No content-based row heights with mixed cell types.** `grid` rows size
  to the tallest cell content, but there is no way to say "row 2 is tall
  enough for a 4-line text widget" without setting `-height` on the text
  widget itself.
- **No equivalent of `flex-wrap`.** A `pack` row that exceeds the parent's
  width does not wrap to the next line; it simply overflows or clips. Wrap-
  to-next-line behavior must be coded manually (e.g. with a `text` widget
  embedding child widgets, or with `grid` and explicit row management).
- **No baseline alignment.** Items align by their bounding boxes, not by
  their text baselines. A button next to an entry next to a label do not
  share a baseline unless their box heights happen to match.
- **`place` is the only option for "absolute coordinates"** — and it does
  not interact well with content-sized siblings. A `place`d widget shares
  its parent's content area with `pack`'ed or `grid`'ed siblings, but the
  cavity / cell computation ignores the placed widget's space.
- **No animation primitives.** Layout transitions on container resize are
  instantaneous; smooth animation must be implemented manually.

### For Static One-Shot Rendering

Tk is fundamentally a _live_, _retained-mode_, _interactive_ toolkit. Its
geometry managers were designed for live windows that respond to user
resize, font change, and theme switches. "Render once and exit" is not a
target use case for Tk.

Nevertheless, the _layout vocabulary_ Tk pioneered is highly relevant to
static rendering, including terminal output:

- The `pack` _cavity_ model maps cleanly to "claim a strip from the
  remaining vertical space" — exactly what a terminal-cell renderer does
  when writing a report's header, footer, and body.
- The `grid` _row/column/sticky_ model is the most concise way to describe
  aligned tabular output, including bordered tables.
- The `place` _relative-coordinate_ model is the only one where a static
  renderer needs _no_ knowledge of children's natural sizes — the position
  is given directly. Useful when you know "this widget covers the bottom
  20% of the screen."

For Sparkles, the directly applicable lesson is that `pack`'s API is _short_
in a way modern layout APIs are not. A two-line "header on top, body fills
rest" specification:

```tcl
pack .header -side top -fill x
pack .body   -side top -fill both -expand 1
```

is the conceptual shape of a CLI-rendering layout function that takes
positional arguments rather than a builder pattern with many `.setX().setY()`
calls. The D translation would look something like:

```d
auto report = Layout()
    .pack(header, side: Side.top, fill: Fill.x)
    .pack(body,   side: Side.top, fill: Fill.both, expand: 1);
```

— and CTFE could specialize the result for a known output width.

### Compared to Alternatives

| Aspect                   | Tk `pack`                       | Tk `grid`                       | CSS Flexbox                            | CSS Grid                                     | Ratatui constraints             |
| ------------------------ | ------------------------------- | ------------------------------- | -------------------------------------- | -------------------------------------------- | ------------------------------- |
| Primary axis             | One (cavity-claimed)            | Two (rows × columns)            | One                                    | Two                                          | One (Horizontal / Vertical)     |
| Year introduced          | 1990                            | 1996                            | 2012 (CR)                              | 2017 (Rec)                                   | 2018 (tui-rs) / 2023 (ratatui)  |
| API verbosity            | Very low (1 – 4 options/widget) | Low (5 – 8 options/widget)      | Medium (CSS verbose)                   | High (CSS verbose)                           | Medium (Rust verbose)           |
| Ordering matters?        | Yes (cavity is order-dependent) | No (cells are coordinate-keyed) | Source order (with `order` opt-out)    | No (placement is coordinate-keyed)           | Yes (list order = layout order) |
| Sticky / fill alignment  | `-anchor`, `-fill`              | `-sticky NSEW`                  | `align-self`, `justify-self`           | `align-self`, `justify-self`                 | `Constraint::Length` / `Fill`   |
| Spans                    | Not supported                   | `-rowspan`, `-columnspan`       | Not native (use `flex-basis`)          | `grid-row: span n`                           | Not native                      |
| Wrapping                 | Not supported                   | Not supported                   | `flex-wrap: wrap`                      | `grid-template-rows: repeat(auto-fill, ...)` | Not native                      |
| "Fill remaining space"   | `-expand 1`                     | `rowconfigure -weight 1`        | `flex: 1`                              | `1fr`                                        | `Constraint::Fill(n)`           |
| Constraint-solver based? | No (cavity walk + two-pass)     | No (two-pass)                   | No (algorithmic, single-pass-per-axis) | No (algorithmic)                             | Yes (Cassowary via `kasuari`)   |

The most important observation: **Tk's geometry managers shipped the core
ideas that modern layout systems still use.** `flex-direction: row` is
`-side left`. `align-self: stretch` is `-sticky we`. `flex-grow: 1` is
`-expand 1`. `grid-template-columns: 1fr 2fr` is `grid columnconfigure 0
-weight 1; grid columnconfigure 1 -weight 2`. The CSS specifications use
different vocabulary and add expressive features (named grid areas, line
naming, item ordering) — but the conceptual debt to `pack` and `grid` is
unmistakable.

### When Tk Geometry Managers Win

- **Quick prototypes.** A scientist who needs a parameter-sweep GUI in 30
  lines of Python uses `tkinter.pack` and is done.
- **Cross-platform GUIs without web tech.** Tk runs natively on Linux,
  macOS, and Windows without a browser. The geometry managers are part of
  why Tk apps start in milliseconds where Electron apps take seconds.
- **Resizable forms with weight-driven elasticity.** `grid columnconfigure`
  with `-weight` and `-uniform` matches the typical "this column grows, this
  one stays fixed" UI very directly.
- **Embedded Tcl in instrument and design-automation tools.** Tk's original
  domain. Reliability and minimal dependencies matter more than visual
  polish.

### When Tk Geometry Managers Lose

- **Modern web-style responsive design** with wrapping flex rows, media-
  query-driven re-layout, and animation. Use Flexbox / Grid.
- **Pixel-perfect graphic-design layouts.** Use a canvas / drawing API or a
  layout system built for graphic design.
- **Layouts with many constraints that interact** (e.g. an IDE's split
  panes with min sizes and proportional resizing). A constraint solver
  (Cassowary, kasuari) handles these more gracefully than `pack` /`grid`.
- **High-frequency layout changes** where each change should animate
  smoothly. Tk's geometry managers re-layout instantaneously; smooth
  animation must be hand-rolled.

---

## References

### Primary Documentation

- **Tk `pack` manual.** <https://www.tcl-lang.org/man/tcl9.0/TkCmd/pack.htm>
- **Tk `grid` manual.** <https://www.tcl-lang.org/man/tcl9.0/TkCmd/grid.htm>
- **Tk `place` manual.** <https://www.tcl-lang.org/man/tcl9.0/TkCmd/place.htm>
- **TkDocs Tutorial — Concepts (geometry managers overview).** <https://tkdocs.com/tutorial/concepts.html>
- **TkDocs Tutorial — Grid.** <https://tkdocs.com/tutorial/grid.html>
- **Python `tkinter` documentation.** <https://docs.python.org/3/library/tkinter.html>

### Historical and Background

- **John Ousterhout, "Tcl and the Tk Toolkit"** (Addison-Wesley, 1994). The
  original book describing Tk's design philosophy, including the geometry
  managers. ISBN 0-201-63337-X.
- **Wikipedia — Tk (software).** <https://en.wikipedia.org/wiki/Tk_(software)>
- **ACM Software System Award 1997 citation.**
  <https://awards.acm.org/award_winners/ousterhout_2009295>
- **Tcler's Wiki — pack.** <https://wiki.tcl-lang.org/page/pack>
- **Tcler's Wiki — grid.** <https://wiki.tcl-lang.org/page/grid>
- **Tcler's Wiki — place.** <https://wiki.tcl-lang.org/page/place>

### Source

- **Tk source code (Fossil repository).** <https://core.tcl-lang.org/tk/timeline>
- **Tk source code (GitHub mirror).** <https://github.com/tcltk/tk>
- **The geometry manager implementations live in `generic/tkPack.c`,
  `generic/tkGrid.c`, and `generic/tkPlace.c`.**

### Adjacent Sparkles Research

- **CSS normal flow (the "blocks stack, inlines flow" model that predates
  every CSS layout module):** [css-normal-flow.md](./css-normal-flow.md)
- **CSS Flexbox (Tk `pack`'s direct descendant in spirit, 19 years later):**
  [css-flexbox.md](./css-flexbox.md)
- **CSS Grid (Tk `grid`'s direct descendant in spirit, 21 years later):**
  [css-grid.md](./css-grid.md)
- **Constraint-based TUI layout (a different, solver-driven approach
  contemporaneous with Ratatui):** [../tui-libraries/ratatui.md](../tui-libraries/ratatui.md)
- **Yoga / Flexbox-driven TUI (the closest TUI analogue of Tk's `pack`
  layered with Flex semantics):** [../tui-libraries/ink.md](../tui-libraries/ink.md)
