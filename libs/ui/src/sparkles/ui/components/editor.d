/**
The editor's view (`EDR1`, `EDR2`, `EDR5`): an `EditorState` drawn through
the standard widget pipeline, alike on every backend.

Each logical line is one rich run. It is cut at every selection edge,
caret and read-only edge. Selected text paints on the `selection` slot,
read-only text on the read-only slot, and each caret is the `caret` slot's
`▏` where the primary range's head is, or every range's head with several.
Every span carries its source byte range, so the layout's hit test
(`sourceOffsetAt`) maps a pointer back to a text position, and the caret
is drawn where motion believes it is.

Specification: `docs/specs/ui/editor.md` §7.
*/
module sparkles.ui.components.editor;

import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.editor.state : EditorState, ReadOnlySpan;
import sparkles.ui.style : Slot;
import sparkles.ui.geometry : SizeSpec;
import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

/// How an editor is drawn.
struct EditorViewOptions
{
    /// Draw carets: the editor has focus and the blink (`STM6`) is on.
    bool caretVisible = true;
    /// Shown, muted, while the text is empty.
    string placeholder;
    /// The editable text's slot.
    Slot textSlot = Slot.inherit;
    /// Read-only spans' slot, distinct from editable text (`EDR5`).
    Slot readOnlySlot = Slot.muted;
    /// Lines to show from `firstLine` (multi-line); 0 shows all.
    size_t visibleLines;
    /// The first line shown.
    size_t firstLine;
}

/// The caret glyph.
enum string caretGlyph = "▏";

/**
The spans of logical line `line` of `state`. Text spans borrow nothing: they
hold copies, so the tree outlives the state.
*/
TextSpan[] editorLineSpans(in EditorState state, size_t line, in EditorViewOptions options)
    @safe pure nothrow
{
    const text = state.text;
    const start = text.lineStart(line);
    const end = text.lineEnd(line);
    const ranges = state.selection.ranges;
    const several = ranges.length > 1;

    // Every place the styling can change, sorted and unique.
    size_t[] cuts = [start, end];
    foreach (r; ranges)
        cuts ~= [r.start, r.end, r.head];
    foreach (span; state.readOnly[])
        cuts ~= [span.start, span.end];
    size_t[] inLine;
    foreach (c; cuts)
        if (c >= start && c <= end)
            inLine ~= c;
    sortUnique(inLine);

    TextSpan[] spans;
    foreach (i, at; inLine)
    {
        if (options.caretVisible)
            foreach (j, r; ranges)
                if (r.head == at && (several || j == state.selection.primaryIndex))
                {
                    spans ~= TextSpan(text: caretGlyph, slot: Slot.caret);
                    break;
                }
        if (i + 1 == inLine.length)
            break;
        const next = inLine[i + 1];
        if (next == at)
            continue;
        auto bytes = new char[next - at];
        text.copyTo(at, next, bytes);
        auto span = TextSpan(text: bytes, slot: options.textSlot, srcStart: at, srcEnd: next);
        foreach (ro; state.readOnly[])
            if (at >= ro.start && next <= ro.end)
                span.slot = options.readOnlySlot;
        foreach (r; ranges)
            if (!r.empty && at >= r.start && next <= r.end)
            {
                span.slot = Slot.selection;
                span.paintBackground = true;
            }
        spans ~= span;
    }
    return spans;
}

/// The editor as one node: a rich run for a single line, else a column of
/// them from `options.firstLine`.
uint editorView(ref Builder b, in EditorState state, EditorViewOptions options = EditorViewOptions.init)
    @safe
{
    if (state.text.length == 0 && options.placeholder.length)
    {
        TextSpan[] spans;
        if (options.caretVisible)
            spans ~= TextSpan(text: caretGlyph, slot: Slot.caret);
        spans ~= TextSpan(text: options.placeholder, slot: Slot.muted);
        return b.add(Widget(kind: WidgetKind.rich, spans: spans, width: SizeSpec.grow()));
    }
    const lines = state.text.lineCount;
    if (lines == 1)
        return b.add(Widget(kind: WidgetKind.rich, spans: editorLineSpans(state, 0, options),
            width: SizeSpec.grow()));
    const first = options.firstLine < lines ? options.firstLine : lines - 1;
    const last = options.visibleLines && first + options.visibleLines < lines
        ? first + options.visibleLines : lines;
    uint[] rows;
    foreach (line; first .. last)
        rows ~= b.add(Widget(kind: WidgetKind.rich, spans: editorLineSpans(state, line, options),
            width: SizeSpec.grow()));
    return b.add(Widget(kind: WidgetKind.column, children: rows, width: SizeSpec.grow()));
}

/**
The first line to show so the primary caret stays in view (`EDR2`, on
`scrollToPrimary`): unchanged while the caret's line is inside
`[firstLine, firstLine + visibleLines)`, else the nearest start that brings it in.
*/
size_t scrollToPrimary(in EditorState state, size_t firstLine, size_t visibleLines)
    @safe pure nothrow @nogc
{
    if (visibleLines == 0)
        return 0;
    const line = state.text.lineOf(state.selection.primary.head);
    if (line < firstLine)
        return line;
    if (line >= firstLine + visibleLines)
        return line + 1 - visibleLines;
    return firstLine;
}

private void sortUnique(ref size_t[] values) @safe pure nothrow
{
    foreach (i; 1 .. values.length)
    {
        const v = values[i];
        size_t j = i;
        while (j > 0 && values[j - 1] > v)
        {
            values[j] = values[j - 1];
            --j;
        }
        values[j] = v;
    }
    size_t n;
    foreach (i, v; values)
        if (i == 0 || v != values[n - 1])
            values[n++] = v;
    values = values[0 .. n];
}

version (unittest)
{
    import sparkles.ui.editor.testing : parse;

    /// The spans of `marked`'s first line, as `text/slot` pairs joined by `|`.
    string spansOf(string marked, EditorViewOptions options = EditorViewOptions.init)
        @safe pure nothrow
    {
        const state = parse(marked);
        string result;
        foreach (i, s; editorLineSpans(state, 0, options))
        {
            if (i)
                result ~= " ";
            result ~= s.text;
            if (s.slot == Slot.selection)
                result ~= "#sel";
            else if (s.slot == Slot.caret)
                result ~= "#caret";
            else if (s.slot == Slot.muted)
                result ~= "#ro";
        }
        return result;
    }
}

/// EDR1: text, selection and caret as spans; the caret at the range's head.
@("editor.view.spans")
@safe pure nothrow
unittest
{
    assert(spansOf("ab|cd") == "ab ▏#caret cd");
    assert(spansOf("a[bc]d") == "a bc#sel ▏#caret d");
    assert(spansOf("a]bc[d") == "a ▏#caret bc#sel d");
    EditorViewOptions blinkOff;
    blinkOff.caretVisible = false;
    assert(spansOf("ab|cd", blinkOff) == "ab cd");
}

/// EDR1: with several ranges every head shows a caret.
@("editor.view.everyCaret")
@safe pure nothrow
unittest
{
    assert(spansOf("a|b|c") == "a ▏#caret b ▏#caret c");
}

/// EDR5: read-only spans draw on their own slot.
@("editor.view.readOnlyDistinct")
@safe pure nothrow
unittest
{
    auto state = parse("ab|cdef");
    state.readOnly.put(ReadOnlySpan(4, 6));
    string shown;
    foreach (s; editorLineSpans(state, 0, EditorViewOptions.init))
        shown ~= s.text ~ (s.slot == Slot.muted ? "#ro " : " ");
    assert(shown == "ab ▏ cd ef#ro ");
}

/// Spans carry their source bytes, so a hit maps back to a text position.
@("editor.view.sourceRanges")
@safe pure nothrow
unittest
{
    const state = parse("a[bc]d");
    foreach (s; editorLineSpans(state, 0, EditorViewOptions.init))
        if (s.slot != Slot.caret)
        {
            char[8] bytes;
            state.text.copyTo(s.srcStart, s.srcEnd, bytes[0 .. s.srcEnd - s.srcStart]);
            assert(bytes[0 .. s.srcEnd - s.srcStart] == s.text);
        }
}

/// EDR2: the view scrolls just enough to keep the primary caret in view.
@("editor.view.scrollToPrimary")
@safe pure nothrow
unittest
{
    const state = parse("0\n1\n2\n3\n4|\n5");
    assert(scrollToPrimary(state, 0, 3) == 2);
    assert(scrollToPrimary(state, 2, 3) == 2);
    assert(scrollToPrimary(state, 5, 3) == 4);
}
