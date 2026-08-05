/**
Multi-annotation layout for the below-line blocks of a single source line — the
compiler-diagnostic art that keeps several annotations on one line legible.

When two `^?` queries (or a query and an error, or a query and a completion
list) attach to the $(B same) source line, stacking them in node order loses the
association: the second block's caret sits rows away from the code it points at,
and the first block's payload runs underneath it. Rust, Elm, and modern
GCC/Clang all solve this the same way — one shared marker row under the code,
then the labels peeled off $(B right to left), with vertical connectors running
down to whatever has not been said yet:

---
w = spread(lo, hi);
┬   ┬─────
│   ╰─ double sample.spread(double lo, double hi)
╰─ (thread local global) double sample.w
---

$(LREF layoutBelowLine) computes that shape as pure data — marker runs, row
assignment, and the guide columns each row must draw — so the ANSI renderer and
the $(MREF sparkles,ui) widget view grow identical chrome from one model. It
decides $(I where), never $(I how): glyphs come from $(LREF ConnectorGlyphs) and
painting stays with the backend.

The layout engages only when a line carries $(B two or more distinct anchor
columns). One annotation — or several sharing a column, where there is nothing
to disambiguate — keeps the plain stacked shape (`connected == false`), so the
overwhelmingly common case renders exactly as it always has.
*/
module sparkles.twoslash.below_layout;

import sparkles.ui.geometry : cellsOf;

import sparkles.twoslash.overlay : BelowBlock;
import sparkles.twoslash.protocol : Node, NodeType, TwoslashReturn;

@safe:

/// Cells an elbow occupies before its payload (`╰─ ` / `+- `).
enum int elbowCells = 3;

/// Blank cells kept between two payloads that share an annotation row.
enum int shareGutter = 2;

/**
The connector charset. `unicode` is the default; `ascii` is the degraded set for
a terminal that cannot render box drawing (the target's capability decides,
not the theme's preference — see $(REF GlyphSet, sparkles,ui,theme)).

`fill` mirrors GCC's `~~~~^~~` underline and `anchor` marks the span's first
cell, so the ASCII set reads as the diagnostic art it degrades from.
*/
struct ConnectorGlyphs
{
    string anchor = "┬"; /// the span's first cell on the marker row
    string fill = "─";   /// the rest of the span on the marker row
    string guide = "│";  /// a vertical connector passing through a row
    string elbow = "╰─ "; /// turns a guide into its payload ($(LREF elbowCells) wide)

    /// The ASCII degradation.
    static ConnectorGlyphs ascii() @safe pure nothrow @nogc
        => ConnectorGlyphs(anchor: "^", fill: "~", guide: "|", elbow: "+- ");
}

/// One span's run on the shared marker row. Runs never overlap: a run is
/// clipped at the next anchor column, so adjacent spans stay distinguishable.
struct AnchorMarker
{
    int col;       /// 0-based cell column of the span start
    int width;     /// cells on the marker row (at least 1)
    NodeType kind; /// colors the run (error/warn vs. caret)
    size_t node;   /// index into `TwoslashReturn.nodes` — the run's owner
}

/// One annotation row under the marker row.
struct AnnotationRow
{
    /// Columns drawing a vertical connector $(I through) this row — the anchors
    /// of every block still to come. Ascending, deduplicated, and always left of
    /// every payload on the row (placement runs right to left), so a connector
    /// can never cross text.
    int[] guides;

    /// Node indices whose payload $(I starts) on this row, left to right. More
    /// than one only when their payloads provably do not overlap.
    size_t[] blocks;
}

/// The plan for one source line's below-blocks.
struct BelowLineLayout
{
    AnchorMarker[] markers;  /// left to right; one per distinct anchor column
    AnnotationRow[] rows;    /// top to bottom; `rows[0]` sits under the marker row
    size_t[] unanchored;     /// line-level blocks (`tag`), in node order
    bool connected;          /// `false` ⇒ render the plain stacked shape
}

/**
`true` iff `kind` is anchored to a span on its line, and so takes part in the
connected layout.

A `tag` is a $(I line) annotation — the notation carries no column and the node
reports `character == 0` with zero length — so it has nothing to point at and
stays a plain stacked row.
*/
bool isAnchored(NodeType kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case NodeType.error:
        case NodeType.query:
        case NodeType.completion:
            return true;
        case NodeType.tag:
        case NodeType.hover:
        case NodeType.highlight:
            return false;
    }
}

/**
Lays out `blocks` — the below-blocks of one source line, in plan order — over
`availWidth` cells (0 = unbounded).

Placement runs $(B right to left): the rightmost anchor's payload takes the
first row, the leftmost takes the last, so a connector only ever runs downward
past anchors whose labels have not been drawn yet. Two payloads share a row when
the left one provably ends $(LREF shareGutter) cells before the right one's
anchor and neither wraps; otherwise each takes its own row.

Returns a layout with `connected == false` when the line has fewer than two
distinct anchor columns — there is nothing to disambiguate, and the caller
should keep its existing stacked rendering.
*/
BelowLineLayout layoutBelowLine(in TwoslashReturn tw,
    scope const(BelowBlock)[] blocks, int availWidth) @safe
{
    import std.algorithm.iteration : filter, map, uniq;
    import std.algorithm.sorting : sort;
    import std.array : array;

    BelowLineLayout layout;
    foreach (ref const b; blocks)
        if (!isAnchored(b.kind))
            layout.unanchored ~= b.node;

    auto anchored = blocks
        .filter!(b => isAnchored(b.kind))
        .map!(b => b.node)
        .array;

    const columns = anchored.map!(n => anchorCol(tw.nodes[n])).array.sort.uniq.array;
    if (columns.length < 2)
        return layout;
    layout.connected = true;

    // One marker per distinct column, clipped at its right neighbour so two
    // adjacent spans never merge into one run.
    foreach (i, col; columns)
    {
        const owner = anchored.filter!(n => anchorCol(tw.nodes[n]) == col).front;
        const limit = i + 1 < columns.length ? columns[i + 1] - col : int.max;
        layout.markers ~= AnchorMarker(col: col, kind: tw.nodes[owner].type,
            node: owner, width: clampWidth(spanCells(tw, tw.nodes[owner]), limit));
    }

    // Right to left, opening a new row whenever the next payload would collide
    // with what is already on the current one.
    auto order = anchored.dup;
    order.sort!((a, b) => anchorCol(tw.nodes[a]) != anchorCol(tw.nodes[b])
        ? anchorCol(tw.nodes[a]) > anchorCol(tw.nodes[b]) : a < b);

    auto rowOf = new int[](order.length);
    int row;
    int leftmost = int.max; // leftmost cell claimed on the current row
    bool rowWraps;          // a wrapping payload owns its row outright
    foreach (i, n; order)
    {
        const col = anchorCol(tw.nodes[n]);
        const cells = elbowCells + payloadCells(tw.nodes[n]);
        const flat = fitsFlat(tw.nodes[n], col, cells, availWidth);
        if (i && (rowWraps || !flat || col + cells + shareGutter > leftmost))
        {
            ++row;
            leftmost = int.max;
            rowWraps = false;
        }
        rowOf[i] = row;
        rowWraps |= !flat;
        leftmost = col;
    }

    layout.rows = new AnnotationRow[](row + 1);
    foreach (i, n; order)
        layout.rows[rowOf[i]].blocks ~= n;
    foreach (ref r; layout.rows)
        r.blocks.sort!((a, b) => anchorCol(tw.nodes[a]) < anchorCol(tw.nodes[b]));

    // A row's guides are the anchors of every block on a *later* row — all of
    // them to its left, since placement ran right to left.
    foreach (r, ref rowSpec; layout.rows)
        rowSpec.guides = order
            .filter!(n => rowOf[indexIn(order, n)] > r)
            .map!(n => anchorCol(tw.nodes[n]))
            .array
            .sort
            .uniq
            .array;

    return layout;
}

/// The anchor column of `node`, as a signed cell column.
int anchorCol(in Node node) @safe pure nothrow @nogc => cast(int) node.character;

/// Cells `node`'s span covers in `tw.code` (at least 1 — a zero-length
/// completion anchor still needs a cell to point with).
private int spanCells(in TwoslashReturn tw, in Node node) @safe pure nothrow @nogc
{
    const end = node.start + node.length;
    if (!node.length || end > tw.code.length)
        return 1;
    const cells = cast(int) cellsOf(tw.code[node.start .. end]);
    return cells > 0 ? cells : 1;
}

/// A marker run is at least one cell and never reaches the next anchor.
private int clampWidth(int width, int limit) @safe pure nothrow @nogc
    => width > limit ? (limit > 1 ? limit : 1) : width;

/// The cells `node`'s payload occupies on its widest row, ignoring the elbow.
/// A completion list is measured by its longest candidate; it never shares a
/// row (see $(LREF fitsFlat)), so the figure only bounds the row.
private int payloadCells(in Node node) @safe
{
    final switch (node.type)
    {
        case NodeType.error:
            // The message sits in a panel with one cell of padding a side.
            return cast(int) cellsOf(node.text) + 2;
        case NodeType.query:
            return cast(int) cellsOf(node.text);
        case NodeType.completion:
            int widest;
            foreach (ref const c; node.completions)
            {
                const cells = cast(int) cellsOf(c.name) + 2; // "- " bullet
                if (cells > widest)
                    widest = cells;
            }
            return widest;
        case NodeType.tag:
        case NodeType.hover:
        case NodeType.highlight:
            return 0;
    }
}

/// `true` iff `node`'s payload occupies exactly one row at `col` — the
/// precondition for sharing a row with a neighbour. A completion list is many
/// rows by construction; anything that would wrap within `availWidth` is not
/// flat.
private bool fitsFlat(in Node node, int col, int cells, int availWidth) @safe pure nothrow @nogc
    => node.type != NodeType.completion
        && (availWidth <= 0 || col + cells <= availWidth);

/// The position of `n` in `order` (small arrays; a linear scan is the cheapest
/// thing that stays `@safe pure`).
private size_t indexIn(scope const(size_t)[] order, size_t n) @safe pure nothrow @nogc
{
    foreach (i, v; order)
        if (v == n)
            return i;
    return order.length;
}

version (unittest)
{
    import sparkles.twoslash.overlay : planTwoslash;
    import sparkles.twoslash.protocol : Completion;

    /// The below-blocks of `line`, in plan order.
    private BelowBlock[] blocksOn(in TwoslashReturn tw, size_t line) @safe
    {
        import std.algorithm.iteration : filter;
        import std.array : array;

        return planTwoslash(tw).belowBlocks.filter!(b => b.line == line).array;
    }

    /// Two `^?` queries on one line, at columns 5 and 13 (the shape of
    /// `08-cut-variants`).
    private TwoslashReturn twoQueries() @safe pure nothrow
        => TwoslashReturn(
            code: "auto width = spread(lo, hi);\n",
            nodes: [
                Node(type: NodeType.query, start: 5, length: 5, line: 0, character: 5,
                    text: "(thread local global) double sample.width"),
                Node(type: NodeType.query, start: 13, length: 6, line: 0, character: 13,
                    text: "double sample.spread(double lo, double hi)"),
            ]);
}

@("below_layout.isAnchored")
@safe pure nothrow @nogc
unittest
{
    assert(isAnchored(NodeType.error));
    assert(isAnchored(NodeType.query));
    assert(isAnchored(NodeType.completion));
    // A `// @tag` has no span to point at.
    assert(!isAnchored(NodeType.tag));
    assert(!isAnchored(NodeType.hover));
    assert(!isAnchored(NodeType.highlight));
}

@("below_layout.singleAnchorStaysStacked")
@safe unittest
{
    // One query: nothing to disambiguate, so the caller keeps its plain shape.
    const tw = TwoslashReturn(code: "auto x = f();\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 1, line: 0, character: 5, text: "int x")]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 0);
    assert(!layout.connected);
    assert(layout.rows.length == 0);
}

@("below_layout.sameColumnStaysStacked")
@safe unittest
{
    // A query and an error on the *same* token (the `24-deprecated` /
    // `25-dip1000-scope` shape) share one anchor — a connector would point both
    // labels at the same cell and say nothing.
    const tw = TwoslashReturn(code: "    render();\n", nodes: [
        Node(type: NodeType.query, start: 4, length: 6, line: 0, character: 4,
            text: "void sample.render()"),
        Node(type: NodeType.error, start: 4, length: 6, line: 0, character: 4,
            text: "deprecated", level: "error"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 0);
    assert(!layout.connected);
}

@("below_layout.tagIsLineLevel")
@safe unittest
{
    // A `// @tag` plus one query is still a single anchor: the tag is not one.
    const tw = TwoslashReturn(code: "enum budgetMs = 750;\n", nodes: [
        Node(type: NodeType.tag, start: 0, length: 0, line: 0, character: 0,
            name: "retry", text: "budget = 750 ms"),
        Node(type: NodeType.query, start: 5, length: 8, line: 0, character: 5,
            text: "(constant) int sample.budgetMs = 750"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 0);
    assert(!layout.connected);
    assert(layout.unanchored == [0UL]);
}

@("below_layout.rightToLeftRows")
@safe unittest
{
    const tw = twoQueries();
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 100);
    assert(layout.connected);

    // Two markers, clipped so neither reaches the other's anchor.
    assert(layout.markers.length == 2);
    assert(layout.markers[0].col == 5 && layout.markers[0].width == 5);
    assert(layout.markers[1].col == 13 && layout.markers[1].width == 6);

    // The rightmost label lands first; the leftmost last.
    assert(layout.rows.length == 2);
    assert(layout.rows[0].blocks == [1UL]);
    assert(layout.rows[1].blocks == [0UL]);

    // Row 0 runs a connector down past the anchor it has not labelled yet;
    // by row 1 there is nothing left to carry.
    assert(layout.rows[0].guides == [5]);
    assert(layout.rows[1].guides.length == 0);
}

@("below_layout.markerRunsAreClippedAtTheNextAnchor")
@safe unittest
{
    // The first span is 9 cells wide but the next anchor is 4 cells away, so
    // its run stops short instead of swallowing the neighbour's marker.
    const tw = TwoslashReturn(code: "auto value = compute(x);\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 9, line: 0, character: 5, text: "A"),
        Node(type: NodeType.query, start: 9, length: 5, line: 0, character: 9, text: "B"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 0);
    assert(layout.markers[0].width == 4, "clipped at the next anchor");
    assert(layout.markers[1].width == 5, "the last run is unclipped");
}

@("below_layout.shortPayloadsShareARow")
@safe unittest
{
    // Two short labels that provably do not overlap stay on one row.
    const tw = TwoslashReturn(code: "auto p = q + r;\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 1, line: 0, character: 5, text: "int"),
        Node(type: NodeType.query, start: 30, length: 1, line: 0, character: 30, text: "int"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 100);
    assert(layout.rows.length == 1);
    assert(layout.rows[0].blocks == [0UL, 1UL], "left to right within the row");
    assert(layout.rows[0].guides.length == 0);
}

@("below_layout.wrappingPayloadOwnsItsRow")
@safe unittest
{
    // The right-hand label is short, but the left one wraps at this width, so
    // it cannot join the row above it.
    const tw = TwoslashReturn(code: "auto p = q + r;\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 1, line: 0, character: 5,
            text: "a signature far too long to sit beside anything"),
        Node(type: NodeType.query, start: 30, length: 1, line: 0, character: 30, text: "int"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 40);
    assert(layout.rows.length == 2);
    assert(layout.rows[0].blocks == [1UL]);
    assert(layout.rows[1].blocks == [0UL]);
}

@("below_layout.completionNeverSharesARow")
@safe unittest
{
    // A completion list is many rows by construction (the `05-completions`
    // shape: a query at column 5 and a candidate list at column 20).
    const tw = TwoslashReturn(code: "auto o = t.op;\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 1, line: 0, character: 5, text: "T"),
        Node(type: NodeType.completion, start: 20, length: 0, line: 0, character: 20,
            completions: [Completion(name: "map"), Completion(name: "filter")]),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 100);
    assert(layout.rows.length == 2);
    assert(layout.rows[0].blocks == [1UL], "the completion list takes the first row");
    assert(layout.rows[1].blocks == [0UL]);
    assert(layout.rows[0].guides == [5]);
}

@("below_layout.threeAnchorsPeelRightToLeft")
@safe unittest
{
    const tw = TwoslashReturn(code: "auto a = f(g(h));\n", nodes: [
        Node(type: NodeType.query, start: 5, length: 1, line: 0, character: 5,
            text: "a fairly long resolved type"),
        Node(type: NodeType.query, start: 9, length: 1, line: 0, character: 9,
            text: "a fairly long resolved type"),
        Node(type: NodeType.query, start: 11, length: 1, line: 0, character: 11,
            text: "a fairly long resolved type"),
    ]);
    const layout = layoutBelowLine(tw, blocksOn(tw, 0), 60);
    assert(layout.rows.length == 3);
    assert(layout.rows[0].blocks == [2UL]);
    assert(layout.rows[1].blocks == [1UL]);
    assert(layout.rows[2].blocks == [0UL]);
    // Each row carries exactly the anchors still owed a label.
    assert(layout.rows[0].guides == [5, 9]);
    assert(layout.rows[1].guides == [5]);
    assert(layout.rows[2].guides.length == 0);
}

@("below_layout.asciiGlyphsDegradeToDiagnosticArt")
@safe pure nothrow @nogc
unittest
{
    const g = ConnectorGlyphs.ascii;
    assert(g.anchor == "^" && g.fill == "~" && g.guide == "|");
    assert(g.elbow.length == elbowCells, "the elbow must keep its cell budget");
    assert(ConnectorGlyphs.init.guide == "│");
}
