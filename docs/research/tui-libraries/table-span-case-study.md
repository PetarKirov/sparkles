# Table Row/Column-Span Case Study

A comparative analysis of how libraries represent **tables with cell spanning** —
`colspan`/`rowspan`, merged cells, spanning blocks — across terminal table renderers,
TUI frameworks, document/markup systems, and GUI grid layouts. The lens is the same as
the [Tree-View Case Study][tree-view-case-study]: [Sean Parent's principles][sean-parent-index]
(value semantics, avoiding incidental data structures, separating algorithms from data)
and the project's D guidelines ([Design by Introspection][dbi-guidelines],
[functional/declarative style][functional-guidelines]). The motivating gap is that
Sparkles' current [`drawTable`][table-src] takes a flat rectangular `string[][]` and has
**no span model at all** — this survey maps the design space a span-capable successor must
choose from.

**Last reviewed:** June 26, 2026

## 1. Introduction

A table without spans is trivial: a rectangular `Cell[rows][cols]`, one content string per
position, one column width per column. Sparkles' [`drawTable`][table-src] is exactly this —
it asserts [`hasRectangularShape`][table-src], computes one width per column via
[`columnWidths`][table-src], and draws every interior junction (`┬`/`┴`) unconditionally.

A span breaks every one of those assumptions. Once a cell can occupy a `w×h` rectangle of
grid positions, a span-capable design must answer **four distinct sub-problems**, and the
libraries surveyed here differ primarily in _which_ sub-problems they solve and _how_:

- **Representation** — how a span is _encoded_ in the data model: an attribute on the
  anchor cell, a separate descriptor list, a continuation sentinel, or implicit from content.
- **Occlusion** — which grid positions a span _covers_, and how those covered positions are
  represented (omitted from the row, held as `null`, marked by a sentinel) so they are not
  rendered twice.
- **Resolution** — once cells overlap a shared grid, how **column widths / row heights** are
  distributed across a spanning cell, and how the **interior border glyphs** (junctions
  `┼ ┬ ┴ ├ ┤`, separators) are suppressed or redrawn to make the merge read as one cell.
- **Validation** — what happens when spans **overlap**, exceed the grid, or leave holes.

The single most important finding of this survey: **true cell spanning is rare in TUI
libraries and ubiquitous in document/markup and GUI-layout systems.** The richest, most
fully-specified models therefore come from _outside_ the terminal world — the HTML table
model, GNU `tbl`, LaTeX, CSS Grid — and a Sparkles design should borrow its data model from
those references rather than from any single terminal library, none of which solves all four
sub-problems.

---

## 2. The five representation strategies

Every system surveyed encodes spans in one of five ways (or supports no spanning at all). This
taxonomy is the spine of the rest of the document.

| #      | Strategy                                     | How a span is encoded                                                                                      | How covered cells are represented                                             | Exemplars                                                                                                                                                                         |
| ------ | -------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **S1** | **Dense row-stream + per-anchor attributes** | `colspan`/`rowspan` on the anchor cell; row order is implicit                                              | Covered cells **omitted** from the row stream; later rows supply fewer cells  | [HTML][html-tables], [cli-table3][cli-table3], LaTeX `\multicolumn`, [AsciiDoc][asciidoc-span], [Ratatui][ratatui] (colspan only)                                                 |
| **S2** | **Descriptor overlay on a full grid**        | A separate `spanningCells: [{row, col, rowSpan, colSpan}]` list layered over a complete rectangular `data` | Covered cells **kept** in `data` but their content is discarded               | [npm `table`][npm-table]                                                                                                                                                          |
| **S3** | **Continuation sentinels in a full grid**    | A reserved token at each covered position pointing left/up to the anchor                                   | Covered cells are **explicit sentinels** (`s`, `^`, empty `&`, drawn borders) | [`tbl`][tbl] (`s`/`^`), LaTeX `\multirow` (empty rows), [reStructuredText grid tables][rst-tables]                                                                                |
| **S4** | **Content-equality auto-merge**              | No coordinates at all; adjacent cells with **identical content** merge                                     | Data stays dense; merge is inferred at render time                            | [olekukonko/tablewriter][tablewriter]                                                                                                                                             |
| **S5** | **Sparse absolute placement**                | Each cell declares `(row, col, rowSpan, colSpan)`; the container is a sparse grid                          | Covered / never-addressed positions simply **hold no cell**                   | [CSS Grid][css-grid], Qt `setSpan`, [GtkGrid][gtk-grid], Swing `GridBagLayout`, Android `GridLayout`, Tk `grid`                                                                   |
| **—**  | **No span (rectangular `string[][]`)**       | n/a — strictly one content per `(row, col)`                                                                | n/a                                                                           | [lipgloss/table][lipgloss], Rich `Table`, [Textual][textual] `DataTable`, ink-table, [Brick][brick] `Table`, [tview][tview] `Table`, [FTXUI][ftxui] `Table`, Sparkles `drawTable` |

Two cross-cutting observations frame the strategies:

- **Dense-stream (S1/S2/S3) vs. sparse-placement (S5).** The document/markup world is
  _dense_: a row is an ordered stream and a span causes following positions to be _omitted_
  (S1) or marked (S3). The GUI world is _sparse_: every cell names its own `(row, col)`
  coordinates and the grid is a scatter of anchors (S5). CSS Grid is the one system that
  spans the divide — explicitly-placed items are sparse-absolute, while auto-placed items are
  packed into a dense stream, with a `dense`/`sparse` policy knob ([§8](#8-gui-grid-layouts--the-sparse-absolute-placement-model)).
- **Overlap is the universally under-specified corner.** Only HTML defines overlap as a
  named error with deterministic behaviour; CSS Grid, GTK, and Android explicitly _permit_
  overlap and define paint order or call it "undefined"; Qt, Swing, Tk, and every terminal
  library leave it silent. A clean Sparkles model should make overlap a _defined_ outcome
  (error or last-writer-wins) rather than inherit the ambiguity ([§11](#11-design-principles-for-a-sparkles-span-capable-table)).

---

## 3. Reference model — the HTML slot grid

Source: [WHATWG HTML Standard, §"Forming a table"][html-tables] (the most fully-specified
span model in existence, and the one most directly imitable for a terminal table).

### Slots, cells, and coverage

HTML separates two concepts that a naïve `string[][]` conflates: the **slot** (a coordinate
on the grid) and the **cell** (a content object that _covers_ a rectangle of slots).

> "A table consists of cells aligned on a two-dimensional grid of slots with coordinates
> (x, y). The grid is finite, and is either empty or has one or more slots." — [HTML §tables][html-tables]

> "A cell is a set of slots anchored at a slot (cellx, celly), and with a particular width
> and height such that the cell covers all the slots with coordinates (x, y) where
> cellx ≤ x < cellx+width and celly ≤ y < celly+height." — [HTML §tables][html-tables]

This is the **anchor + extent** model: a cell is `(cellx, celly, width, height)`, and the set
of covered slots is _derived_, never stored. `colspan`/`rowspan` are the public spelling of
`width`/`height`:

```html
<td colspan="2" rowspan="3">anchor</td>
```

The attribute value limits are part of the spec, which a robust model should mirror:

> "The td and th elements may have a colspan content attribute specified, whose value must
> be a valid non-negative integer greater than zero and less than or equal to 1000." — [HTML §tables][html-tables]

`rowspan` is capped at 65534, and `rowspan="0"` is special — it means "grow downward to the
end of the row group" (a _downward-growing_ cell), the only deferred/unbounded extent in any
system surveyed.

### The placement cursor skips covered slots

The processing model walks cells in document order, advancing a cursor and **skipping any
slot already covered** by a previously-anchored cell:

> "While xcurrent is less than xwidth and the slot with coordinate (xcurrent, ycurrent)
> already has a cell assigned to it, increase xcurrent by 1." — [HTML §tables, processing model][html-tables]

This is the algorithmic heart of strategy **S1**: covered cells are _omitted_ from the row
stream, and the renderer recovers their positions by advancing past occupied slots. Depth
(here, column position) is _derived from the cursor_, not stored on the cell — directly
analogous to how [ratatui-tree-widget's `flatten()` derives depth from path length][tree-view-case-study].

### Overlap is a defined error

HTML is the only surveyed system that gives overlap a name and a defined behaviour:

> "If any of the slots involved already had a cell covering them, then this is a table model
> error. Those slots now have two cells overlapping." — [HTML §tables][html-tables]

> "A table model error is an error with the data represented by table elements and their
> descendants. Documents must not have table model errors." — [HTML §tables][html-tables]

The model is conformant-or-not, but the algorithm still terminates deterministically (the slot
ends up covered by two cells). This is the right posture for Sparkles: **detect overlap, but
define what rendering does anyway.**

---

## 4. Reference model — `tbl` key-letter sentinels

Source: [groff `tbl(1)` man page][tbl] (the classic Unix table preprocessor; the canonical
strategy **S3**).

`tbl`'s format section assigns one **key letter** to every grid position — a classifier, not
content. Real entries use `L`/`R`/`C`/`N`; spans use two dedicated _continuation_ letters that
act as sentinels pointing at the anchor:

> **S, s** — "Span previous entry on the left into this column." — [groff `tbl(1)`][tbl]

> **^** — "Span entry in the same column from the previous row into this row." — [groff `tbl(1)`][tbl]

A `2×2` block anchored top-left is expressed by surrounding the anchor with `s` (to its right)
and `^` (below it):

```
.TS
box tab(:);
Lz S
^  ^ .
anchor:
:
.TE
```

The elegance of S3 is that **the grid stays rectangular** — every position has exactly one
classifier — so there is never an "uneven row length" to reconcile and never a slot-collision
question: `s` always means "left", `^` always means "up", and the fixed column count makes
spans unambiguous _by construction_. The cost is verbosity (every covered position must be
spelled out) and that the anchor must be reconstructed by scanning left/up from each sentinel.

reStructuredText [grid tables][rst-tables] are S3 in visual form: the span "token" is the
_absence_ of an interior `|` or `-` border, and the merged cell is the maximal rectangle in the
box-drawing art. Notably, reST's _simple_ tables support column spans but **not** row spans —
the same asymmetry that recurs across terminal libraries:

> "Grid tables allow arbitrary cell contents (body elements), and both row and column spans."
> … "Simple tables allow multi-line rows (in all but the first column) and column spans, but
> not row spans." — [docutils reST spec][rst-tables]

---

## 5. Terminal table renderers — deep dives

Among libraries that actually render boxes to a terminal, only a handful support spans, and
each picks a _different_ one of the five strategies — making this the most instructive cluster.

### cli-table3 (JavaScript) — S1, omit covered cells

Source: [cli-table3 repository][cli-table3]. The reference terminal implementation of full
two-axis spanning.

> "Ability to make cells span columns and/or rows." — [cli-table3 README][cli-table3]

A cell is either a bare string or an options object carrying `colSpan`/`rowSpan` alongside
`content`, `hAlign`, `vAlign`:

```javascript
table.push(
  [
    { content: 'hello', colSpan: 2 },
    { rowSpan: 3, content: 'hi' },
  ],
  [{ content: 'howdy', colSpan: 2 }],
  ['o', 'k', ''],
);
```

Covered cells are **omitted entirely** from the row arrays (not `null`, not `""`) — exactly the
HTML S1 model. A `rowSpan` therefore makes the _following_ rows supply one fewer cell, so the
arrays are deliberately ragged; "the layout manager automatically [creates] empty cells to fill
in the table." Column widths auto-fit content unless pinned via `colWidths`, and the layout
manager redraws interior borders to fit the spanned region. cli-table3 is the closest existing
analogue to what Sparkles needs.

### npm `table` (JavaScript) — S2, descriptor overlay

Source: [`table` repository (Gajus Kohelet)][npm-table]. The reference for strategy **S2**.

Here `data` must stay a **complete rectangular grid**, and spans are declared in a _separate_
`spanningCells` array layered on top:

```js
spanningCells: [
  { col: 0, row: 0, colSpan: 6 },
  { col: 0, row: 2, rowSpan: 2, verticalAlignment: 'middle' },
  { col: 0, row: 4, colSpan: 2, alignment: 'right' },
];
```

The covered cells still occupy slots in `data`; their content is thrown away at render time:

> "just specify an array of minimal cell configurations including the position of top-left
> cell and the number of columns and/or rows will be expanded from it. The content of overlap
> cells will be ignored to make the `data` shape be consistent." — [`table` README][npm-table]

The trade-off vs. cli-table3 is **shape stability for redundancy**: `data` stays a clean
rectangle (easy to build programmatically, easy to validate), at the cost of carrying dead
content for every covered slot. The spanning cell inherits its column's width/padding/wrap and
adds `alignment`/`verticalAlignment`.

### olekukonko/tablewriter (Go) — S4, content-equality auto-merge

Source: [tablewriter][tablewriter]. The reference for strategy **S4** — the only "implicit
span" model, where the author never writes span coordinates at all.

> "Set Auto Merge Cells. This would enable / disable the merge of cells with identical
> values." — [`SetAutoMergeCells` godoc][tablewriter-godoc]

The data stays a dense `[][]string`; the renderer merges _adjacent cells holding identical
strings_ — vertically (a repeated column value across consecutive rows becomes a visual
rowspan) and/or horizontally. The v1 API generalizes this to merge modes
(`MergeHorizontal`, `MergeHierarchical`, `MergeBoth`) and per-column targeting
(`SetAutoMergeCellsByColumnIndex`). S4 is wonderful for _reports_ (collapsing a repeated
category column) and useless for _layout_ (you cannot merge two cells that happen to share a
value but should stay separate, nor merge two cells with different content). It solves
representation and occlusion implicitly but offers no control over either.

### Ratatui (Rust) — S1, colspan only

Source: [ratatui `Cell`][ratatui-cell-src]. A retained-mode TUI widget that recently grew
_column_ spanning — correcting the older catalog claim that Ratatui has no span at all.

```rust
pub struct Cell<'a> {
    content: Text<'a>,
    style: Style,
    pub(crate) column_span: u16,
}
// builder:
pub const fn column_span(mut self, column_span: u16) -> Self
```

A `Row` is still a stream of `Cell`s sized by the table's `widths: [Constraint]`, and a cell's
`column_span` makes it consume multiple columns (S1) — but there is **no `row_span`**. This
mirrors the recurring asymmetry (colspan is cheap, rowspan is hard) seen in reST simple tables
and Dear ImGui. The feature landed from issue [#1568][ratatui-1568]; rowspan remains open.

### FTXUI (C++) — no span, decorate-a-rectangle

Source: [`ftxui/dom/table.hpp`][ftxui-table-src]. Worth a close look because it shows the
_shape_ of the "fake it" escape hatch that every no-span library falls back to.

FTXUI's `Table` is built from a 2-D `std::vector<std::vector<Element>>` and exposes only
_selection + decoration_, never merging:

```cpp
TableSelection SelectCell(int column, int row);
TableSelection SelectRectangle(int column_min, int column_max,
                               int row_min, int row_max);
// TableSelection: Decorate, DecorateCells, DecorateBorder*, DecorateSeparator* — no Merge/Span
```

To "merge" cells you put content in one cell, leave the neighbours empty, `SelectRectangle`
the block, and decorate its border — or you abandon `Table` entirely and compose with
`hbox`/`vbox`/`gridbox`/`flexbox` + the `flex` decorator. There is no API to suppress an
_individual_ interior junction for a spanned cell, so true merges are not cleanly achievable.
This is the universal no-span fallback: **spanning becomes a manual border-suppression +
nesting exercise**, which is exactly the burden a real span model removes.

---

## 6. TUI frameworks — span as a non-feature

Across retained- and immediate-mode TUI frameworks, native cell spanning is the exception, not
the rule. The recurring architectural reason: a **row-of-cells** or **immediate-mode column
cursor** model has no persistent 2-D cell object to merge — only a retained
**grid-of-coordinates** (or a separate grid-layout primitive) can express a span.

### Dear ImGui / ImTui (C++) — horizontal _background_ spanning only

Source: [`imgui_tables.cpp`][imgui-tables-src]. ImGui's Tables API is an immediate-mode column
cursor (`BeginTable` → `TableNextColumn()`); there is no retained cell to merge. The codebase is
explicit that even the _background_ can only span horizontally:

> "TablePushBackgroundChannel() is only used for horizontal spanning. If we allowed vertical
> spanning we'd need one background draw channel per merge group (1-4)." — [`imgui_tables.cpp`][imgui-tables-src]

The documented workarounds (issue [#3565][imgui-3565]) — first column with `NoClipX`,
zero-width columns, ending/restarting the table — are content tricks, not a cell model. ImTui,
being "99.9% based on … Dear ImGui," inherits the identical limitation.

### Brick (Haskell) — rectangle enforced at runtime

Source: [`Brick.Widgets.Table`][brick-table-docs]. Brick's `Table` _refuses_ non-rectangular
input, foreclosing S1-style ragged rows:

> "All rows MUST have the same number of cells. If not, this function will raise a
> `TableException`." — [`Brick.Widgets.Table`][brick-table-docs]

Spanning must be composed manually from `hBox`/`vBox`/`padLeft` outside the table — the FTXUI
fallback again.

### tview (Go) — `Table` has no span; `Grid` does

Source: [tview `Table`][tview-table-src]. `TableCell` has no `colSpan`/`rowSpan`. Note the
tempting-but-unrelated `SetExpansion`:

> "SetExpansion sets the value by which the column of this cell expands if the available width
> for the table is more than the table width…" — [tview godoc][tview-godoc]

That is _width redistribution_, not merging. Real spanning in tview exists only in the separate
`Grid` _layout_ primitive, whose `AddItem(p, row, column, rowSpan, colSpan, …)` is a textbook
**S5** sparse-placement signature — but `Grid` lays out arbitrary primitives, it is not the
cell-grid `Table`. The split is itself a finding: tview keeps the _data table_ dense and
span-free, and pushes spanning into a _layout_ container.

### The no-span baseline

[Rich][textual] `Table`, [Textual][textual] `DataTable`, [lipgloss/table][lipgloss],
`ink-table`, [Notcurses][notcurses] (no table widget — absolutely-positioned planes), and
`prompt_toolkit` / Urwid (split containers, no cell grid) all share the rectangular
`string[][]`-equivalent model with **no span and no merge**. Their only escape hatch is nesting
a sub-renderable inside one cell — composition, not spanning. Textual is a partial exception at
the layout level: its CSS exposes `column-span` / `row-span` on grid children
([§8](#8-gui-grid-layouts--the-sparse-absolute-placement-model)), but its `DataTable` widget
does not.

---

## 7. Document & markup span syntaxes

Beyond HTML ([§3](#3-reference-model--the-html-slot-grid)) and `tbl`/reST
([§4](#4-reference-model--tbl-key-letter-sentinels)), the markup world supplies two more
data points on the S1/S3 axis.

### LaTeX — `\multicolumn` (S1) + `\multirow` (S3)

LaTeX splits the two axes across two mechanisms with _opposite_ representations:

- `\multicolumn{n}{align}{text}` **replaces** _n_ column entries with one — covered columns are
  _omitted_ from the row (fewer `&`). This is S1.
- `\multirow{n}{width}{text}` (from the `multirow` package) typesets only the anchor; the
  spanned rows below must contain **empty cells**. This is S3 with emptiness as the sentinel:

> "The main thing to note when using `\multirow` is that a blank entry must be inserted for
> each appropriate cell in each subsequent row to be spanned." — [Wikibooks, LaTeX/Tables][latex-tables]

Overlap is entirely the author's responsibility — `\multirow` silently _overwrites_ whatever is
in the rows it spans if they are not blanked. A 2-D block is `\multicolumn` and `\multirow`
combined.

### AsciiDoc — span vs. duplicate operators

Source: [Asciidoctor span-cells docs][asciidoc-span]. AsciiDoc prefixes the cell delimiter `|`
with a _cell specifier_, distinguishing **span** (`+`) from **duplicate** (`*`):

- `2+|` — colspan 2; `.2+|` — rowspan 2; `2.2+|` — a 2×2 block (column factor before the dot,
  row factor after).
- `3*|` — _duplicate_ into 3 independent cells (not a span).

> "The span operator tells the converter to interpret the span factor as part of a span instead
> of a duplication." — [Asciidoctor docs][asciidoc-span]

This explicit _span-vs-duplicate_ distinction is a useful API nuance: "repeat this value across
N columns" (duplicate) and "let this value occupy N columns" (span) are genuinely different
intents, and most terminal libraries conflate or omit both.

[GitHub-Flavored Markdown / CommonMark][gfm-tables] sit at the bottom of the expressiveness
ladder: no spanning at all, cell counts simply normalized to the header row ("If there are a
number of cells fewer than … the header row, empty cells are inserted. If there are greater,
the excess is ignored"). Org-mode similarly offers only `/`-row _column groups_ (vertical
rules), never merged cells.

---

## 8. GUI grid layouts — the sparse absolute-placement model

Source cluster: [CSS Grid][css-grid] / the project's [ui-layout CSS-Grid study][ui-css-grid],
Qt, [GTK][gtk-grid], Swing, Android, Tk. This cluster is unanimous on strategy **S5** and
supplies the cleanest separation of placement from packing.

The universal idiom is **anchor + extent extending down/right, default extent 1**:

| System                | Span API                                                    | Anchor                         | Default                              | Overlap (documented?)    |
| --------------------- | ----------------------------------------------------------- | ------------------------------ | ------------------------------------ | ------------------------ |
| Qt `QTableView`       | `setSpan(row, column, rowSpanCount, columnSpanCount)`       | `(row, column)`                | 1                                    | unspecified              |
| Qt `QGridLayout`      | `addWidget(w, fromRow, fromColumn, rowSpan, columnSpan)`    | `(fromRow, fromColumn)`        | 1 (`-1` = to edge)                   | unspecified              |
| GTK4 `GtkGrid`        | `gtk_grid_attach(grid, child, column, row, width, height)`  | `(column, row)`                | 1                                    | **"undefined"**          |
| Swing `GridBagLayout` | `GridBagConstraints.gridwidth` / `gridheight`               | `gridx` / `gridy`              | 1 (`REMAINDER`/`RELATIVE` sentinels) | silent                   |
| Android `GridLayout`  | `spec(start, size)`, `layout_rowSpan` / `layout_columnSpan` | `layout_row` / `layout_column` | 1                                    | **permitted, undefined** |
| Tk / Tkinter          | `grid(row, column, rowspan, columnspan)`                    | `row` / `column`               | 1                                    | silent                   |

The consistency is striking — every framework converged on the same `(row, col, rowSpan,
colSpan)` shape with default 1. Representative signatures:

> "Sets the span of the table element at (row, column) to the number of rows and columns
> specified by (rowSpanCount, columnSpanCount)." — [Qt `QTableView::setSpan`][qt-tableview]

> "width — The number of columns that `child` will span. height — The number of rows that
> `child` will span." — [GTK4 `Grid.attach`][gtk-grid]

The container is **sparse**: covered and never-addressed cells hold no widget, and grid
dimensions are _inferred_ from the maximum coordinate used. Overlap is where these systems
diverge — GTK4 and Android explicitly permit-but-undefine it:

> "The behaviour of `GtkGrid` when several children occupy the same grid cell is undefined."
> — [GTK4 `Grid`][gtk-grid-class]

> "there is no guarantee that children will not themselves overlap after the layout operation
> completes." — [Android `GridLayout`][android-gridlayout]

### CSS Grid — the one hybrid

[CSS Grid][css-grid] is the richest reference because it cleanly separates the _two axes_ a
terminal table must decide: **placement** (sparse-absolute via explicit lines / `grid-area`,
or auto) and **packing policy** (sparse vs. dense auto-flow).

> "Contributes a grid span to the grid item's placement such that the corresponding edge of
> the grid item's grid area is n lines from the opposite edge." (`span N`) — [MDN `grid-column`][css-grid]

> "a 'sparse' algorithm is used, where the placement algorithm only ever moves 'forward' …
> never backtracking to fill holes." vs. "a 'dense' packing algorithm, which attempts to fill
> in holes earlier in the grid." — [CSS Grid §grid-auto-flow][css-grid-spec]

Auto-placement _never creates_ overlap (each step "increment[s] the column position … until
this item's grid area does not overlap any occupied grid cells"), but _explicit_ placement may,
with paint order resolved by `z-index`/`order`. [Textual's][textual] `column-span` / `row-span`
CSS properties are the terminal-world adoption of exactly this model — applied to _widgets in a
grid container_, not to table cells.

---

## 9. Comparative analysis

| Library / system                                                  | Strategy | Col-span           | Row-span              | Covered cells                   | Overlap rule                     | Width/height resolution       |
| ----------------------------------------------------------------- | -------- | ------------------ | --------------------- | ------------------------------- | -------------------------------- | ----------------------------- |
| **HTML table**                                                    | S1       | ✓                  | ✓ (+`rowspan=0` grow) | omitted; cursor skips occupied  | defined **error**, deterministic | spec leaves to CSS            |
| **`tbl`**                                                         | S3       | ✓ (`s`)            | ✓ (`^`)               | explicit sentinels              | unambiguous by fixed grid        | preprocessor computes         |
| **LaTeX**                                                         | S1 + S3  | ✓ (`\multicolumn`) | ✓ (`\multirow`)       | omitted (cols) / empty (rows)   | author-managed; overwrites       | typesetter                    |
| **AsciiDoc**                                                      | S1       | ✓ (`2+`)           | ✓ (`.2+`)             | not authored                    | implied by factor                | converter                     |
| **reST grid**                                                     | S3       | ✓                  | ✓                     | drawn borders                   | non-rectangular → parse error    | from art                      |
| **cli-table3**                                                    | S1       | ✓                  | ✓                     | **omitted** from row arrays     | silent                           | auto-fit + `colWidths`        |
| **npm `table`**                                                   | S2       | ✓                  | ✓                     | kept in `data`, content ignored | silent                           | inherits anchor column        |
| **tablewriter**                                                   | S4       | ✓ (equal)          | ✓ (equal)             | dense; inferred                 | n/a (content-driven)             | per-column, no redistribution |
| **Ratatui**                                                       | S1       | ✓                  | ✗                     | omitted                         | silent                           | `Constraint` widths           |
| **FTXUI**                                                         | none     | ✗                  | ✗                     | n/a (decorate rectangle)        | n/a                              | per cell                      |
| **Dear ImGui**                                                    | none     | bg only            | ✗                     | n/a                             | n/a                              | per column                    |
| **Brick / tview `Table` / Rich / lipgloss / Textual `DataTable`** | none     | ✗                  | ✗                     | n/a (rectangular)               | n/a                              | per column                    |
| **CSS Grid**                                                      | S5       | ✓                  | ✓                     | sparse (no item)                | **defined**: allowed + `z-index` | track sizing                  |
| **Qt / GTK / Swing / Android / Tk**                               | S5       | ✓                  | ✓                     | sparse (no widget)              | unspecified / "undefined"        | layout pass                   |

### Key observations

**Representation is independent of the four sub-problems it must serve.** The two-axis
terminal renderers cli-table3 (S1) and npm `table` (S2) reach the same expressive power via
opposite encodings — ragged-omit vs. dense-overlay. The choice is purely ergonomic: S1 is
hand-friendly (you only write what you see) but yields ragged arrays that are awkward to build
and validate programmatically; S2 keeps a clean rectangle (trivial to construct, index, and
diff) at the cost of redundant covered content. For a _library_ API consumed by other code, S2's
shape-stability is the stronger default; for a _human-authored_ table, S1 reads better.

**Colspan is cheap; rowspan is hard.** Ratatui (colspan only), Dear ImGui (horizontal
background only), and reST simple tables (column spans, not row spans) independently stop at the
column axis. The reason is rendering, not representation: a colspan only suppresses _vertical_
interior separators within one row band, while a rowspan forces row-height coupling across
multiple row bands and per-merge-group vertical draw state (ImGui names this explicitly). A
Sparkles design that wants rowspan must budget for the harder border/height-coupling problem up
front.

**The sparse model (S5) decouples placement from row order; the dense model (S1) binds them.**
S5's `(row, col, rowSpan, colSpan)` is order-independent and naturally a _value_ (a flat array
of placements) — which is why it dominates GUI toolkits and why CSS Grid can offer a
sparse-vs-dense _policy_. S1's "omit covered cells, recover by cursor" is more compact for dense
tables but conflates representation with traversal order, exactly the coupling
[Sean Parent warns against][sean-parent-ds].

**Only HTML and CSS Grid define overlap.** Every other system is silent or calls it
"undefined." A terminal table aimed at correctness should pick HTML's posture: detect the
collision, report it, and still render deterministically.

**Content-equality merge (S4) is a different feature, not a weaker span.** tablewriter's
auto-merge serves _report compression_ (collapse a repeated category), not _layout_. It should
be offered, if at all, as a separate rendering option over a span-free grid — not as the span
model itself.

---

## 10. Analysis through Sean Parent's principles

### Avoiding incidental data structures

> "An incidental data structure is a data structure where there is no object representing the
> structure as a whole." — [Data Structures][sean-parent-ds]

The **S1 ragged-omit** model (cli-table3, HTML's in-memory `<tr>` streams) is mildly incidental:
the "covered" relationship between an anchor and the slots it occupies exists only as a
_consequence_ of the placement cursor's walk — there is no object that _is_ the covered region.
You cannot ask a covered slot "who covers me?" without re-running the placement algorithm. The
**S5 sparse-placement** model is cleaner: a `Span { row, col, rowSpan, colSpan }` is a first-class
value, and a grid is a flat `Span[]` — a single whole object you can copy, diff, and validate.
The **HTML slot grid** is the ideal: it makes both the _slot grid_ and the _cell_ explicit
objects, deriving coverage from `anchor + extent` rather than storing it incidentally.

### Value semantics

> "Value semantics are the cleanest way to implement Whole-Part relationships." — [Value Semantics][sean-parent-vs]

A span model built as a flat array of placements (S5) or a flat slot grid (HTML) is a regular,
copyable value — duplicating it is one array copy, enabling snapshot testing and undo/redo, just
as the [tree-view study][tree-view-case-study] recommends flat `Node[]` storage. cli-table3's
ragged `Cell[][]` is also copyable but its raggedness makes structural comparison awkward. npm
`table`'s "dense `data` + separate `spanningCells`" is two values that must stay consistent — a
weaker invariant than a single grid where coverage is derived.

### Separate algorithms from data

> "Algorithms are more fundamental than the data structures on which they operate." — [Generic Programming][sean-parent-gp]

The HTML processing model is the exemplar: **"forming a table"** is a free algorithm over slot +
cell data, separable from rendering. A Sparkles design should likewise express _resolve coverage_
(anchor + extent → covered slots, with overlap detection) and _resolve junctions_ (which interior
glyphs to suppress) as free functions over the grid — testable in isolation, exactly as
ratatui-tree-widget's [`flatten()` is a pure free function][tree-view-case-study]. Border-junction
resolution in particular is a pure function `(grid, position) → glyph` that the no-span libraries
never need but a span model cannot avoid.

### Regular types & DbI

The GUI cluster's universal `(row, col, rowSpan, colSpan)` with default 1 is a small regular
value. Per the project's [Design by Introspection guidelines][dbi-guidelines], optional
per-cell capabilities (alignment, vertical-alignment, style) should be _optional primitives_
detected on the cell type — a `string` cell, a styled-IES cell, and a nested-renderable cell can
share one rendering path that adapts via `static if`/traits rather than a type hierarchy.

---

## 11. Design principles for a Sparkles span-capable table

Synthesizing the survey for a span-capable successor to [`drawTable`][table-src]:

### 1. Adopt the HTML slot-grid model as the data model

Represent a table as an explicit grid of **slots** plus **cells**, where a cell is
`anchor (row, col) + extent (rowSpan, colSpan)` and coverage is _derived_, never stored
([§3](#3-reference-model--the-html-slot-grid)). This is the only surveyed model that solves all
four sub-problems coherently and the one most TUI libraries lack.

### 2. Prefer the sparse-placement (S5) value, dense as a convenience

Make the canonical model a flat, copyable `Cell[]` of `(row, col, rowSpan, colSpan, content)`
placements (strategy **S5**) — order-independent, regular, and trivially value-semantic
([§10](#10-analysis-through-sean-parents-principles)). Offer the dense `string[][]` form (today's
`drawTable` input) as sugar that lowers to placements with all extents 1 — preserving backward
compatibility with the existing API and tests.

### 3. Default extent 1; validate overlap as a defined error

Follow the GUI cluster's universal `rowSpan = colSpan = 1` default ([§8](#8-gui-grid-layouts--the-sparse-absolute-placement-model)),
and follow **HTML's posture on overlap** ([§3](#3-reference-model--the-html-slot-grid)): a
`resolveCoverage` pass detects collisions and out-of-bounds spans and returns an
[`Expected`][functional-guidelines]-style error, but rendering of a malformed grid is still
deterministic (e.g. last-writer-wins). Do **not** inherit the "undefined" overlap of GTK/Android.

### 4. Coverage resolution as a free function

Express `(cells) → SlotGrid` (anchor + extent → covered slots, with overlap detection) as a pure
free function over the grid, mirroring HTML's "forming a table" algorithm and the
[tree-view study's][tree-view-case-study] `flatten()` — testable without any rendering.

### 5. Junction resolution as a pure `(grid, position) → glyph` function

The hard, span-specific rendering problem is **interior border glyphs**: today `drawTable` emits
`┬`/`┴` unconditionally. With spans, each junction must be computed from whether its four
incident edges are real grid lines or suppressed-because-covered — a pure function over the
resolved slot grid. Budget for the full junction set (`┼ ┬ ┴ ├ ┤ ─ │` and the rounded variants
already in `BoxProps`). This is where colspan-only libraries stop ([§9](#9-comparative-analysis)).

### 6. Distribute spanning width across columns + separators

A colspan-`n` cell's content occupies its `n` column widths **plus** the `n-1` interior
separators it absorbs. Column-width computation ([`columnWidths`][table-src]) must therefore
flow a spanning cell's min-width as a _constraint across its columns_ (as cli-table3 and CSS
track-sizing do), not assign it to a single column — otherwise a wide spanning header silently
overflows.

### 7. Distinguish span from duplicate

Adopt AsciiDoc's explicit distinction ([§7](#7-document--markup-span-syntaxes)): "let this value
occupy N columns" (span) and "repeat this value across N columns" (duplicate) are different
intents. Span is the core feature; content-equality auto-merge (tablewriter's **S4**) is a
separate, optional _rendering_ pass over a span-free grid, not the span model.

### 8. Rowspan is a deliberate, costed feature

Several mature libraries ship colspan and stop ([§9](#9-comparative-analysis)). Treat rowspan as
a distinct milestone: it forces row-height coupling across row bands and per-merge-group vertical
border state. Ship colspan first if needed, but design the data model (anchor + 2-D extent) to
admit rowspan from day one so it is not a breaking change later.

### 9. `@nogc` / output-range rendering

Per the project [functional/declarative guidelines][functional-guidelines], the renderer writes
to any output range (`SmallBuffer`, `appender`, a terminal buffer) and the flat `Cell[]` /
slot-grid storage stays `@nogc`-friendly — no recursive allocation, matching the
[tree-view study's][tree-view-case-study] flat-storage recommendation.

### 10. DbI for cell content

Let the cell content type vary (plain `string`, styled IES, nested renderable) and adapt the
render path via traits rather than a hierarchy, consistent with the existing styled-content
handling in [`drawTable`][table-src] (which already unstyles for width via `visibleWidth`).

---

## References

[tui-index]: index.md
[comparison]: comparison.md
[tree-view-case-study]: tree-view-case-study.md
[ftxui]: ftxui.md
[ratatui]: ratatui.md
[textual]: textual.md
[brick]: brick.md
[tview]: tview.md
[notcurses]: notcurses.md
[imtui]: imtui.md
[lipgloss]: bubbletea.md
[ui-css-grid]: ../ui-layout/css-grid.md
[sean-parent-index]: ../sean-parent/index.md
[sean-parent-ds]: ../sean-parent/data-structures.md
[sean-parent-vs]: ../sean-parent/value-semantics.md
[sean-parent-gp]: ../sean-parent/generic-programming.md
[dbi-guidelines]: ../../guidelines/design-by-introspection-01-guidelines.md
[functional-guidelines]: ../../guidelines/functional-declarative-programming-guidelines.md
[table-src]: ../../../libs/core-cli/src/sparkles/core_cli/ui/table.d

## External Sources

[html-tables]: https://html.spec.whatwg.org/multipage/tables.html
[tbl]: https://man7.org/linux/man-pages/man1/tbl.1.html
[rst-tables]: https://docutils.sourceforge.io/docs/ref/rst/restructuredtext.html
[latex-tables]: https://en.wikibooks.org/wiki/LaTeX/Tables
[asciidoc-span]: https://docs.asciidoctor.org/asciidoc/latest/tables/span-cells/
[gfm-tables]: https://github.github.com/gfm/
[cli-table3]: https://github.com/cli-table/cli-table3
[npm-table]: https://github.com/gajus/table
[tablewriter]: https://github.com/olekukonko/tablewriter
[tablewriter-godoc]: https://pkg.go.dev/github.com/olekukonko/tablewriter@v0.0.5
[ratatui-cell-src]: https://github.com/ratatui/ratatui/blob/main/ratatui-widgets/src/table/cell.rs
[ratatui-1568]: https://github.com/ratatui/ratatui/issues/1568
[ftxui-table-src]: https://github.com/ArthurSonzogni/FTXUI/blob/main/include/ftxui/dom/table.hpp
[imgui-tables-src]: https://github.com/ocornut/imgui/blob/master/imgui_tables.cpp
[imgui-3565]: https://github.com/ocornut/imgui/issues/3565
[brick-table-docs]: https://hackage.haskell.org/package/brick/docs/Brick-Widgets-Table.html
[tview-table-src]: https://github.com/rivo/tview/blob/master/table.go
[tview-godoc]: https://pkg.go.dev/github.com/rivo/tview
[css-grid]: https://developer.mozilla.org/en-US/docs/Web/CSS/grid-column
[css-grid-spec]: https://www.w3.org/TR/css-grid-1/#grid-auto-flow-property
[qt-tableview]: https://doc.qt.io/qt-6/qtableview.html
[gtk-grid]: https://docs.gtk.org/gtk4/method.Grid.attach.html
[gtk-grid-class]: https://docs.gtk.org/gtk4/class.Grid.html
[android-gridlayout]: https://developer.android.com/reference/android/widget/GridLayout
