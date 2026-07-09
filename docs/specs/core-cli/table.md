# Spec: span-capable `drawTable` overhaul

**Status:** accepted · **Date:** 2026-07-08 · **Scope:** `sparkles:core-cli`
(`libs/core-cli/src/sparkles/core_cli/ui/table.d`) + a small `sparkles:base` addition.

Successor design for `drawTable`, driven by the survey in
[`docs/research/tui-libraries/table-span-case-study.md`](../../research/tui-libraries/table-span-case-study.md)
(§11 design principles) and the project guidelines
([functional/declarative](../../guidelines/functional-declarative-programming-guidelines.md),
[design-by-introspection](../../guidelines/design-by-introspection-01-guidelines.md)).

## Decision ledger

| Area              | Decision                                                                                                                                                                      |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authoring API     | Dense `Cell[][]` + `string[][]` sugar **and** sparse `Placement[]`; both lower to one HTML slot grid + shared renderer                                                        |
| Config type       | New `TableProps` (replaces the `BoxProps` param — no caller passes it today)                                                                                                  |
| Glyphs            | A `TableGlyphs` struct embedded in `TableProps`, plus a mutable `TableGlyphs[string] stylePresets` registry (rounded/square/ascii/double/heavy, caller-extensible)            |
| Horizontal align  | Per-column (`TableProps.columnAligns`), `Align{inherit,left,center,right}`                                                                                                    |
| Vertical align    | Per-column (`TableProps.columnVAligns`), `VAlign{inherit,top,middle,bottom}`, built now                                                                                       |
| Separators        | Independent toggles: `border`, `columnSeparators`, `rowSeparators`; plus `headerRows` / `headerCols` counts for a distinct rule after the header rows / stub columns          |
| Wrapping / fit    | Per-column max content width **+** total-table `maxWidth` (separators & borders included); cells wrap on `\n` and width via `sparkles.base.text.wrap`; rows become multi-line |
| Default rendering | Byte-identical to the pre-overhaul output (`maxWidth == 0` ⇒ expand to fit)                                                                                                   |
| Overlap / OOB     | Detected as a "table model error"; render is always deterministic; `validateTable` surfaces errors as `Expected`                                                              |
| Shared helper     | `alignField` + `Align` added to `sparkles.base.text.width`                                                                                                                    |
| Consumers         | Bench tables (`test-runner-impl/reporting.d`) right-align numeric columns                                                                                                     |

## 1. Motivation

The current `drawTable(string[][], BoxProps)` renders a flat, rectangular grid: one width
per column, every cell left-aligned, `│` column separators, hardcoded `┬`/`┴` junctions, no
interior row rules, and no way to wrap or fit content to a width. It has **no span model**.
This spec defines a successor that adds column/row spans, per-column horizontal & vertical
alignment, fully configurable glyphs with named presets, independent border/column/row
separator toggles, and content wrapping with per-column and total-width caps — while keeping
the default output byte-identical (it is locked by golden unittests, the README/overview/
spec `[Output]` blocks, and the test-runner bench-table snapshots).

## 2. Data model & configuration

Dense authoring uses `Cell[][]` with covered slots **omitted** from the row (cli-table3 /
HTML "forming a table" model); sparse authoring uses an order-independent `Placement[]`.
Both lower to the same internal **slot grid**, where coverage is derived from `anchor +
extent`, never stored.

```d
enum Align  { inherit, left, center, right }   // horizontal, per-column
enum VAlign { inherit, top, middle, bottom }   // vertical, per-column

struct Cell {                 // dense: Cell[][], covered slots omitted
    string content;
    size_t colSpan = 1;
    size_t rowSpan = 1;
}

struct Placement {            // sparse: Placement[], order-independent
    size_t row, col;
    string content;
    size_t colSpan = 1;
    size_t rowSpan = 1;
}

// All glyphs grouped; defaults are the "rounded" set (== today's output).
struct TableGlyphs {
    dchar topLeft = '╭', topRight = '╮', bottomLeft = '╰', bottomRight = '╯';
    dchar horizontalLine = '─', verticalLine = '│';
    dchar teeDown = '┬', teeUp = '┴', teeRight = '├', teeLeft = '┤', cross = '┼';
    dchar cornerTL = '┌', cornerTR = '┐', cornerBL = '└', cornerBR = '┘'; // interior square corners (spans)
}

// Mutable, string-keyed registry; populated in `shared static this()` and open for
// callers to register their own styles.
TableGlyphs[string] stylePresets;   // "rounded" (== TableGlyphs.init) | "square" | "ascii" | "double" | "heavy"

struct TableProps {
    TableGlyphs glyphs;            // default = rounded
    // separator toggles
    bool border           = true; // outer frame
    bool columnSeparators = true; // interior │
    bool rowSeparators    = false;// interior ─ rules
    // header/stub emphasis: a distinct rule (glyphs.headerRow / headerCol, heavy by
    // default) after N leading header rows / stub columns. 0 ⇒ none. Independent of
    // row/columnSeparators; the stub rule is width-budgeted even with columns off.
    size_t headerRows = 0;
    size_t headerCols = 0;
    // width caps + wrapping (0 / empty ⇒ unbounded, expand to fit; today's behaviour)
    size_t   maxWidth        = 0;    // total table width incl. separators & borders
    size_t[] columnMaxWidths = null; // per-column max CONTENT width (excludes separators)
    // per-column alignment (array entry inherit or out-of-range ⇒ the default)
    Align    defaultAlign   = Align.left;
    Align[]  columnAligns   = null;
    VAlign   defaultVAlign  = VAlign.top;
    VAlign[] columnVAligns  = null;
}
```

Built-in glyph sets: `square` = `┌┐└┘┬┴├┤┼─│`, `double` = `╔╗╚╝╦╩╠╣╬═║`,
`heavy` = `┏┓┗┛┳┻┣┫╋━┃`, `ascii` = `+ - |` for every corner/junction/line, `rounded` =
`TableGlyphs.init`. Usage:
`drawTable(cells, TableProps(glyphs: stylePresets["ascii"], rowSeparators: true))`.

`Align`/`VAlign` are resolved per column: `columnAligns[col]` if in range and ≠ `inherit`,
else `defaultAlign` (same for vertical). `Cell`/`Placement` carry no alignment fields.

Internal structures:

```d
struct Anchor { size_t row, col, rowSpan, colSpan; string content; bool implicit; }
struct SlotGrid { size_t numRows, numCols; Anchor[] anchors; size_t[] slotOwner; }
// owner(r,c) == anchors[slotOwner[r*numCols + c]]
```

## 3. Rendering pipeline (free functions)

Each pass is a free function, unit-testable in isolation (the case study's "separate
algorithms from data" principle).

| Pass                     | Signature                                                                              | Role                                                                                                       |
| ------------------------ | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| sugar lift               | `Cell[][] toCells(string[][])`                                                         | string → extent-1 `Cell`                                                                                   |
| grid resolution (dense)  | `GridResolution resolveGrid(Cell[][])`                                                 | HTML placement cursor → anchors + `slotOwner`; detect overlap/OOB/ragged; clamp spans; sparse-fill empties |
| grid resolution (sparse) | `GridResolution resolveGrid(Placement[])`                                              | direct placement at each stated `(row,col)`; same detection, sparse-fill, and `SlotGrid` output            |
| validation               | `Expected!(SlotGrid, TableError) validateTable(...)`                                   | idiomatic error path over the same resolution                                                              |
| width resolution         | `size_t[] resolveColumnWidths(in SlotGrid, in TableProps)`                             | natural widths + colspan distribution, then per-column caps, then shrink to total `maxWidth`               |
| cell wrapping            | `string[][] wrapCells(in SlotGrid, in size_t[], in TableProps)`                        | wrap each anchor on `\n` and to its field width via `sparkles.base.text.wrap`                              |
| row heights              | `size_t[] resolveRowHeights(in SlotGrid, in string[][])`                               | per grid row = max wrapped-line count among its cells                                                      |
| geometry                 | `vSeg`, `hSeg`, `junctionGlyph`, `contentField`, `padTop` — `@safe pure nothrow @nogc` | segment presence, junction glyph, span field width, vertical offset                                        |
| horizontal align         | `alignField(content, F, Align)` — **from `sparkles.base.text.width`**                  | pad content in field per column align                                                                      |
| line builders            | `bodyBand(...)`, `separatorLine(...)`                                                  | one text line each                                                                                         |
| top-level                | `string drawTable(string[][] / Cell[][] / Placement[], TableProps = init)`             | interleave borders/bands/rules into a GC string (`Appender!string`, mirroring `drawBox`)                   |

### 3.1 Grid resolution — HTML "forming a table"

Dense: walk cells row-major; a cursor advances past already-occupied slots; each anchor
claims its `rowSpan×colSpan` rectangle (**first-writer-wins**; a collision is recorded as a
`TableError`); `numCols = max(cursor + colSpan)`; rowspans past the last row are clamped
(recorded); every unclaimed slot becomes an `implicit` empty extent-1 anchor. Sparse: the
same, but each `Placement` is positioned at its explicit `(row, col)` with no cursor. The
grid is **always fully populated and renderable**, even on model errors (HTML's "table model
error" posture: detect, but define what rendering does — deterministically).

### 3.2 Column widths, caps & wrapping

A cell renders `<field>` (1-space gutters). A colspan-`n` anchor absorbs the `n−1`
interior verticals: `contentField(A) = Σ colWidth[span] + 3*(n−1)`.

1. **Natural widths** — seed `w[c]` with the per-column max of extent-1 cells (this equals
   today's `columnWidths`), then walk colspan≥2 anchors ascending by `colSpan` then
   `(row,col)`; for each, `required = max(0, visibleWidth(content) − 3*(n−1))`; if it exceeds
   the current member-column sum, distribute the deficit evenly (remainder to leftmost).
   Columns only grow, so one ascending pass satisfies all constraints without overflow.
2. **Per-column caps** — `w[c] = min(w[c], columnMaxWidths[c])` where set; over-wide content
   wraps rather than overflowing.
3. **Total `maxWidth`** — content budget = `maxWidth − frame`, where
   `frame = (border?2:0) + Σ_{j=1..numCols−1} sepWidth(j) + 2*numCols` gutters
   (`sepWidth(j) = 1` iff `columnSeparators` or `j` is the stub rule `headerCols`). If
   `Σ w[c]` exceeds the budget, shrink columns largest-first (trim the widest by 1, floor 1)
   until they fit — the standard terminal fit-to-width policy. `maxWidth == 0` skips steps
   2–3 and the table expands to fit exactly as today.
4. **Wrap** — `wrapCells` wraps every anchor on `\n` and to `contentField(A)` via
   `wrapText`/`byWrappedLine` (`WhitespaceMode.preserve`, style/CJK-safe — the `box.d`
   primitive), yielding the per-anchor line lists that feed row heights and bands.

### 3.3 Multi-line bands, rowspan & vertical alignment

Grid row `r` has height `H[r] ≥ 1` and renders as `H[r]` text lines. An anchor spanning rows
`[row, row+k)` has total height `HH = Σ H[row..row+k)` plus the `k−1` interior rules it
absorbs (when `rowSeparators`); its `L` wrapped content lines are placed within `HH` by the
column's `VAlign`:

```
padTop(HH, L, va): top -> 0;  middle -> (HH-L)/2;  bottom -> HH-L   // clamp ≥ 0
```

For each text line of a row, an anchor emits its wrapped line
`alignField(line, contentField(A), effectiveAlign(A.col))` when the index falls within its
content block, else `spaces(F)` (padding lines and covered rowspan rows). The `│` between
an anchor and its right neighbour is a normal inter-anchor boundary (`vSeg` sees two owners)
→ drawn on every text line, no special case. Horizontal rules sit only at grid-**row**
boundaries; multi-line height adds identical body lines _within_ a band and never moves a
rule.

### 3.4 Junction glyph resolution

Model the table as a lattice of vertical boundaries `j ∈ 0..numCols` and horizontal
boundaries `i ∈ 0..numRows`. Two predicates carry the toggles and detect spans:

```
vSeg(r,j): j∈{0,numCols} ? border : (!columnSeparators && !isHeaderCol(j)) ? false : owner(r,j-1)!=owner(r,j)  // false ⇒ colspan crosses
hSeg(i,c): i∈{0,numRows} ? border : (!rowSeparators    && !isHeaderRow(i)) ? false : owner(i-1,c)!=owner(i,c)    // false ⇒ rowspan crosses
```

(`isHeaderRow(i) = headerRows>0 && i==headerRows && i<numRows`, and `isHeaderCol`
symmetrically — the emphasized rules draw even when their bool toggle is off.)

The 4-arm mask at `(i,j)` is `up=vSeg(i-1,j)`, `down=vSeg(i,j)`, `left=hSeg(i,j-1)`,
`right=hSeg(i,j)` (bounds-guarded). The four extreme table corners use the rounded frame
glyphs; every other intersection maps purely from the mask (square interior corners),
selecting the glyph from one of four sets by whether the junction sits on a header row,
a stub column, both, or neither — the emphasized sets (`glyphs.headerRow` / `headerCol`
/ `headerBoth`) default to heavy glyphs so the rule stands out:

| U D L R        | glyph              | U D L R      | glyph        |
| -------------- | ------------------ | ------------ | ------------ |
| 0000           | space              | 0101 (D+R)   | `cornerTL ┌` |
| 0001/0010/0011 | `horizontalLine ─` | 0110 (D+L)   | `cornerTR ┐` |
| 0100/1000/1100 | `verticalLine │`   | 1001 (U+R)   | `cornerBL └` |
| 0111 (D+L+R)   | `teeDown ┬`        | 1010 (U+L)   | `cornerBR ┘` |
| 1011 (U+L+R)   | `teeUp ┴`          | 1101 (U+D+R) | `teeRight ├` |
| 1110 (U+D+L)   | `teeLeft ┤`        | 1111         | `cross ┼`    |

A colspan kills `down` on the top border ⇒ `┬→─` (and `up` on the bottom ⇒ `┴→─`); a rowspan
kills a horizontal arm on an interior rule ⇒ the rule breaks around the block, its interior
corners becoming `┌┐└┘`. **Bands and rules share the same `vSeg`/`hSeg`/`contentField`
helpers**, so their widths and junctions can never desync.

### 3.5 Per-`Align` horizontal formula

`F = contentField`, `W = visibleWidth(content)`, `P = F − W ≥ 0` (guaranteed by width
resolution). Gutters are always emitted:

- left → `content spaces(P)`
- right → `spaces(P) content`
- center → `spaces(P/2) content spaces(P−P/2)` (floor left, remainder right)

Padding is always computed on `visibleWidth`, so ANSI/CJK/grapheme content aligns correctly.

## 4. Backward compatibility (hard requirement)

Default `TableProps` (rounded glyphs, `columnSeparators` on, `rowSeparators` off,
`headerRows`/`headerCols` = 0, `border`
on, left-align, `maxWidth == 0`, no spans) must reproduce the pre-overhaul bytes exactly:
the `<content><pad>` cell format, `┬`/`┴` top/bottom junctions, no interior rules, and a
trailing newline on every line. Guaranteed by: (1) the natural-width step being literally
today's `columnWidths` (retained as the base case); (2) bands and rules deriving from one set
of geometry helpers; (3) locking the existing golden unittests + the `drawTable.styledContent`
golden as byte-identical regression tests. External `[Output]` blocks that reproduce
`drawTable` verbatim (`README.md`, `docs/overview.md`, `docs/specs/base/text/index.md`, and
the test-runner bench tables) must stay put — verified with `nix run .#ci -- --verify`. The
bench-table snapshots change intentionally when numeric columns are right-aligned and are
regenerated in that same change.

## 5. `@nogc` posture

Mirror `drawBox`: the primary API returns a GC `string` built via `Appender!string`. The
pure geometry helpers (`vSeg`, `hSeg`, `junctionGlyph`, `contentField`, `padTop`) stay
`@safe pure nothrow @nogc`; `resolveGrid`/`resolveColumnWidths`/`wrapCells`/
`resolveRowHeights` allocate GC arrays and stay `@safe`. The extracted `alignField` in
`width.d` keeps an output-range core so `base` retains its `@nogc` guarantees. The path stays
`@system` only because styled/`visibleWidth` tests are (as today). A future lazy
`drawTableLines` range is a trivial seam (yield `bodyBand`/`separatorLine`).

## 6. Reused primitives

- `visibleWidth` (`sparkles.base.text.grapheme`, `@safe pure nothrow @nogc`) — width/padding
  math; ANSI=0, CJK=2, grapheme-correct. The new `alignField` (in `sparkles.base.text.width`)
  wraps it.
- `columnWidths` / `hasRectangularShape` (existing in `table.d`) — width base case / shape
  guard.
- `wrapText` / `byWrappedLine` / `WrapOptions` / `WhitespaceMode` (`sparkles.base.text.wrap`)
  — the cell-wrapping engine (same one `box.d`/`header.d` use).
- `expected` (`Expected`/`ok`/`err`) — `validateTable`'s error return.
- `sparkles.core_cli.term_size` — apps derive `maxWidth` from the terminal.

## 7. Test coverage

1. Golden byte-identical — the current tables + styled table (regression lock).
2. Single cell / row / column; empty-string cells; zero-width column.
3. colSpan=2 header wider than its columns → columns widen, no overflow, `┬→─`, interior `│`
   suppressed in that band.
4. colSpan across all columns (full-width banner row).
5. rowSpan=2 → covered band blank, right-edge `│` in both bands; with rowsep the rule breaks.
6. rowSpan×colSpan block → interior square corners `┌┐└┘` where edges meet rules.
7. Nested/adjacent colspans → deterministic, non-overflowing widths.
8. colSpan narrower than its columns → no widening.
9. Model errors: overlap (Expected error + first-writer-wins render); rowSpan past last row
   (clamp + error); colSpan past row width (grid grows + sparse fill).
10. Ragged rows → trailing implicit empty cells.
11. Per-column horizontal align L/C/R (+ `inherit`→default, short/empty arrays), even/odd
    center split, on ANSI-styled and CJK content.
12. Vertical align top/middle/bottom on rowSpan≥2 and on short cells in taller wrapped rows.
13. Toggle matrix: all combinations of `border`/`columnSeparators`/`rowSeparators`
    (× `headerRows`/`headerCols` ∈ {0,1}); band↔rule width parity in each.
14. Glyph presets: each `stylePresets[...]` renders a golden; `stylePresets["rounded"] ==
TableGlyphs.init`; a custom registered `TableGlyphs` and per-field overrides take effect.
15. Sparse `Placement[]` renders identically to the equivalent dense `Cell[][]`;
    out-of-order placements resolve the same.
16. `sparkles.base.text.width.alignField` own tests (L/C/R, `inherit`, ANSI/CJK, zero pad,
    output-range vs string forms agree).
17. Wrapping: content over `columnMaxWidths[c]` wraps to N lines → row height grows, each
    wrapped line padded to the field, band↔rule parity holds; `\n` wraps like a soft wrap.
18. Total `maxWidth`: table shrunk to a narrow width (largest-first); rendered width ≤
    `maxWidth` incl. separators/borders; floor-1 columns don't underflow; `maxWidth == 0`
    expands to fit.
19. Bench-table right-align regen: numeric columns right-aligned, snapshots updated & stable.
20. Trailing newline in every mode; empty input (0 rows / 0 cols) defined.

## 8. Implementation phases

Each phase is an atomic, independently green commit.

1. `feat(base): add styled-width-aware alignField + Align to sparkles.base.text.width`.
2. `build(dub): add expected as a direct dep of core-cli` (+ `dub.selections.json`,
   `nix/dub-lock.json`).
3. `refactor(core-cli): introduce slot-grid model + pass pipeline behind unchanged drawTable`
   (data model, dense `resolveGrid`, `resolveColumnWidths`, geometry helpers; default output
   byte-identical; adopt shared `alignField`).
4. `feat(core-cli): configurable glyphs, presets & optional separators in drawTable`
   (`TableProps`, `TableGlyphs`, `stylePresets` registry, junction resolver, toggle + preset
   tests).
5. `feat(core-cli): content wrapping & width caps in drawTable` (`maxWidth`/
   `columnMaxWidths`, `wrapCells`, `resolveRowHeights`, multi-line bands).
6. `feat(core-cli): column/row spans in drawTable` (`Cell`, cursor, span width/bands).
7. `feat(core-cli): sparse Placement[] table input` (`Placement`, sparse `resolveGrid`,
   parity tests).
8. `feat(core-cli): per-column horizontal & vertical content alignment` (`VAlign`, `padTop`,
   wire `alignField`).
9. `feat(core-cli): overlap/OOB detection via validateTable` (Expected error path).
10. `feat(test-runner): right-align numeric bench columns via TableProps` (+ regenerate
    `docs/libs/test-runner/**` `[Output]` snapshots).
11. `docs(core-cli): README example + example demo for table spans/alignment/glyphs/wrap`.

Documentation lands as a runnable `[Output]`-verified README example plus thorough DDoc on
the new types; a full `docs/libs/core-cli/` Diátaxis tree is deferred to a follow-up.
