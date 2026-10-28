/**
What a step reads besides the state (`EDT2`, `EDT7`): the time, the
viewport height, and the visual-line structure of the laid-out text.

A context is any type with the members `isEditContext` names, so a view can
answer from its own layout and a test from plain logical lines. Every query
is a pure function of the text it is given.

Specification: `docs/specs/ui/editor.md` §2.
*/
module sparkles.ui.editor.context;

import core.time : MonoTime;

import sparkles.base.text.seek : nextGraphemeBoundary;
import sparkles.base.text.utf : UtfMode, decodeToken;
import sparkles.base.text.width : ClusterWidthState;
import sparkles.text_buffer.summary : Affinity;
import sparkles.text_buffer.text : Text;

/// One line of the laid-out text: `[start, end)`, `end` before any line break.
struct VisualLine
{
    size_t start;
    size_t end;
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
        for (size_t at = line.start; at < position && at < line.end;)
        {
            const next = nextGraphemeBoundary(text, at);
            column += clusterCells(text, at, next);
            at = next;
        }
        return column;
    }

    size_t positionAt(in Text text, VisualLine line, size_t column) const scope
    {
        size_t at = line.start;
        size_t reached;
        while (at < line.end)
        {
            const next = nextGraphemeBoundary(text, at);
            const cells = clusterCells(text, at, next);
            // Nearest boundary: past the cluster's middle counts as after it.
            if (reached + cells > column)
                return 2 * (column - reached) >= cells && cells ? next : at;
            reached += cells;
            at = next;
        }
        return line.end;
    }
}

static assert(isEditContext!LogicalContext);

/// Terminal cells of the grapheme `[from, to)`, under the default width profile.
size_t clusterCells(in Text text, size_t from, size_t to) @safe pure nothrow @nogc
{
    // A cluster's width is its leading scalar's, adjusted by a following
    // variation selector, so its first bytes decide it.
    char[32] bytes;
    const n = to - from < bytes.length ? to - from : bytes.length;
    text.copyTo(from, from + n, bytes[0 .. n]);
    ClusterWidthState state;
    for (size_t i; i < n;)
    {
        const decoded = decodeToken(bytes[i .. n], UtfMode.replacement);
        if (decoded.result.consumed == 0)
            break;
        state.push(decoded.token.scalar, false);
        i += decoded.result.consumed;
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
