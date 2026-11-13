/**
What a step reads besides the state (`EDT2`, `EDT7`): the time, the
viewport height, and the visual-line structure of the laid-out text.

A context is any type with the members `isEditContext` names, so a view can
answer from its own layout and a test from plain logical lines. Every query
is a pure function of the text it is given.

A layout context may additionally offer
`horizontalCaret(text, range, direction, extend) -> CaretTarget`. It selects
the next visual caret, including a nonempty selection's visual collapse edge.
The step retains the returned affinity and keeps the logical anchor when
extending. Without this primitive, grapheme motion retains logical order.
`lineBoundaryCaret(text, position, affinity, boundary) -> CaretTarget` may
likewise supply the visual left/right edge of the wrapped row for Home/End.
For vertical motion, `caretColumn(text, line, CaretTarget) -> size_t` measures
a caret's goal column with its affinity, and `caretAt(text, line, column) ->
CaretTarget` returns the nearest caret together with the side of a soft wrap
or bidi boundary that draws it there. Vertical motion always resolves the
head's row with its affinity. `LayoutContext` (`sparkles.ui.editor.layout`)
answers all of these from one cell-grid layout.
The context must answer for the supplied revision, never from stale geometry.

Specification: `docs/specs/ui/editor.md` §2.
*/
module sparkles.ui.editor.context;

import core.time : MonoTime;

import sparkles.base.text.seek : nextGraphemeBoundary;
import sparkles.base.text.grapheme : printableAsciiPrefix;
import sparkles.base.text.utf : UtfMode, decodeToken;
import sparkles.base.text.width : ClusterWidthState;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;
import sparkles.ui.geometry : Rect;
import std.algorithm.comparison : min;

/// One line of the laid-out text: `[start, end)`, `end` before any line break.
struct VisualLine
{
    size_t start;
    size_t end;
}

/// A source byte position and the side of an ambiguous visual boundary it belongs to.
struct CaretTarget
{
    size_t position;
    Affinity affinity;
}

/**
Whether `C` answers a step's questions:

$(UL
    $(LI `now`: the current time, for coalescing (`EDT6`);)
    $(LI `viewportLines`: the viewport's height in visual lines (`movePage`);)
    $(LI `lineAt(text, position, affinity)`: the visual line holding a
        position; at a wrap point `affinity` picks the line before or after;)
    $(LI `lineAbove(text, line, out above)` and `lineBelow`: the adjacent
        visual line, `false` at the first or last;)
    $(LI `columnOf(text, line, position)`: a position's column on its line,
        in the layout's unit;)
    $(LI `positionAt(text, line, column)`: the grapheme boundary on `line`
        nearest `column`.))
*/
enum bool isEditContext(C) = is(typeof((ref C c, in Text t) {
    MonoTime now = c.now;
    size_t page = c.viewportLines;
    VisualLine line = c.lineAt(t, size_t(0), Affinity.before);
    bool up = c.lineAbove(t, line, line);
    bool down = c.lineBelow(t, line, line);
    size_t column = c.columnOf(t, line, size_t(0));
    size_t position = c.positionAt(t, line, column);
}));

/**
A context without layout (`EDT7`): visual lines are logical lines, ending
before LF or the CR of CR LF, and columns are terminal cells. This is
exactly how an editor behaves in a terminal without soft wrapping.
*/
struct LogicalContext
{
    MonoTime now;
    size_t viewportLines = 24;
    /// The host answers clipboard reads (`INP25`); absent, paste is a
    /// `noop(capabilityAbsent)` the field reports (`EDI5`).
    bool clipboardRead;
    /// The host writes the clipboard; absent, copy and cut are a
    /// `noop(capabilityAbsent)` and cut deletes nothing (`EDI5`).
    bool clipboardWrite;

@safe pure nothrow @nogc:

    VisualLine lineAt(in Text text, size_t position, Affinity affinity) const scope
    {
        const line = text.lineOf(position);
        return VisualLine(text.lineStart(line), text.lineEnd(line));
    }

    bool lineAbove(in Text text, VisualLine line, out VisualLine above) const scope
    {
        const index = text.lineOf(line.start);
        if (index == 0)
            return false;
        above = VisualLine(text.lineStart(index - 1), text.lineEnd(index - 1));
        return true;
    }

    bool lineBelow(in Text text, VisualLine line, out VisualLine below) const scope
    {
        const index = text.lineOf(line.start);
        if (index + 1 >= text.lineCount)
            return false;
        below = VisualLine(text.lineStart(index + 1), text.lineEnd(index + 1));
        return true;
    }

    size_t columnOf(in Text text, VisualLine line, size_t position) const scope
    {
        size_t column;
        size_t at = line.start;
        foreach (chunk; text.chunks(line.start))
        {
            if (at >= position || at >= line.end) break;
            if (at >= chunk.start + chunk.bytes.length) continue;
            const stop = min(position, line.end, chunk.start + chunk.bytes.length);
            while (at < stop)
            {
                const plain = printableAsciiPrefix(chunk.bytes[at - chunk.start .. stop - chunk.start]);
                if (plain > 1)
                {
                    // Leave the final starter for grapheme/presentation rules,
                    // including selectors or combining marks in the next chunk.
                    at += plain - 1;
                    column += plain - 1;
                    continue;
                }
                const next = nextGraphemeBoundary(text, at);
                column += clusterCells(text, at, next);
                at = next;
            }
        }
        return column;
    }

    size_t positionAt(in Text text, VisualLine line, size_t column) const scope
    {
        size_t at = line.start;
        size_t reached;
        foreach (chunk; text.chunks(line.start))
        {
            if (at >= line.end) break;
            if (at >= chunk.start + chunk.bytes.length) continue;
            const stop = min(line.end, chunk.start + chunk.bytes.length);
            while (at < stop)
            {
                const plain = printableAsciiPrefix(chunk.bytes[at - chunk.start .. stop - chunk.start]);
                if (plain > 1)
                {
                    const count = plain - 1;
                    if (column - reached < count) return at + column - reached;
                    at += count;
                    reached += count;
                    continue;
                }
                const next = nextGraphemeBoundary(text, at);
                const cells = clusterCells(text, at, next);
                // Nearest boundary: past the cluster's middle counts as after it.
                if (reached + cells > column)
                    return 2 * (column - reached) >= cells && cells ? next : at;
                reached += cells;
                at = next;
            }
        }
        return line.end;
    }

    /**
    The caret at `position`, `extra` cells further right (a preedit's cursor),
    as a one-cell rectangle in lines and columns from the text's start: what
    `imeArea` reports (`EDI6`). The view offsets it by its own origin.
    */
    Rect caretArea(in Text text, size_t position, size_t extra) const scope
    {
        const line = lineAt(text, position, Affinity.before);
        const column = columnOf(text, line, position) + extra;
        return Rect(cast(int) column, cast(int) text.lineOf(position), 1, 1);
    }
}

static assert(isEditContext!LogicalContext);

/// A late selector in a long cluster still controls its width and nearest caret boundary.
@("editor.context.longClusterPresentation")
@safe pure nothrow @nogc unittest
{
    import std.array : replicate;
    enum prefix = "x".replicate(4096);
    enum cluster = "\u2764" ~ "\u0301".replicate(40) ~ "\uFE0F";
    const text = Text(prefix ~ cluster ~ "z");
    const line = VisualLine(0, text.length);
    LogicalContext context;
    assert(clusterCells(text, prefix.length, prefix.length + cluster.length) == 2);
    assert(context.columnOf(text, line, text.length) == 4099);
    assert(context.positionAt(text, line, 4096) == prefix.length);
    assert(context.positionAt(text, line, 4097) == prefix.length + cluster.length);
    assert(context.positionAt(text, line, 4098) == prefix.length + cluster.length);
}

/// Literal escape bytes are editor text rather than a request to strip ANSI formatting.
@("editor.context.literalControls")
@safe pure nothrow @nogc unittest
{
    const text = Text("hello\x1B[31mX");
    LogicalContext context;
    const line = VisualLine(0, text.length);
    assert(context.columnOf(text, line, text.length) == 10);
    assert(context.positionAt(text, line, 5) == 6);
}

/// An ASCII keycap starter is finalized only after its presentation continuation.
@("editor.context.asciiStarterPresentation")
@safe pure nothrow @nogc unittest
{
    import std.array : replicate;
    enum prefix = "x".replicate(4095);
    const text = Text(prefix ~ "1\uFE0F\u20E3z");
    const line = VisualLine(0, text.length);
    LogicalContext context;
    assert(context.columnOf(text, line, text.length) == 4098);
    assert(context.positionAt(text, line, 4095) == 4095);
    assert(context.positionAt(text, line, 4096) == 4102);
    assert(context.positionAt(text, line, 4097) == 4102);
}

/// Terminal cells of the grapheme `[from, to)`, under the default width profile.
size_t clusterCells(in Text text, size_t from, size_t to) @safe pure nothrow @nogc
{
    // Presentation selectors can follow arbitrarily many extending scalars.
    // Borrow whole text chunks instead of imposing a copied-prefix limit.
    ClusterWidthState state;
    foreach (chunk; text.chunks(from))
    {
        if (chunk.start >= to) break;
        const first = from > chunk.start ? from - chunk.start : 0;
        const last = to - chunk.start < chunk.bytes.length ? to - chunk.start : chunk.bytes.length;
        for (size_t i = first; i < last;)
        {
            const decoded = decodeToken(chunk.bytes[i .. last], UtfMode.replacement);
            if (decoded.result.consumed == 0) break;
            state.push(decoded.token.scalar, false);
            i += decoded.result.consumed;
        }
    }
    return state.width < 0 ? 0 : state.width;
}

///
@("editor.context.logicalLines")
@safe pure nothrow @nogc
unittest
{
    const text = Text("ab世c\r\nxyz");
    LogicalContext c;
    const first = c.lineAt(text, 1, Affinity.before);
    assert(first == VisualLine(0, 6));
    assert(c.columnOf(text, first, 5) == 4, "the CJK cluster is two cells");
    assert(c.positionAt(text, first, 3) == 5, "column 3 is the CJK cluster's middle: after it");
    assert(c.positionAt(text, first, 2) == 2);
    VisualLine second;
    assert(c.lineBelow(text, first, second) && second == VisualLine(8, 11));
    VisualLine third;
    assert(!c.lineBelow(text, second, third));
    assert(c.positionAt(text, second, 9) == 11);
}
