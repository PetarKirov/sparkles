/** Syntax presentation composed with shared editor decorations and source identity. */
module sparkles.source_view.editor;

import sparkles.ui.components.editor : editorLineSpans, EditorViewOptions;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : TextSpan;
import sparkles.base.term_color : RgbColor;
import sparkles.syntax.color : toRgb;
import sparkles.syntax.event : StyledSpan;
import sparkles.syntax.theme : ResolvedTheme;
import sparkles.source_view.code : specStyle;

/// Resolve only the requested byte window of sorted syntax runs, using logarithmic lookup.
TextSpan[] syntaxWindow(string source, scope const(StyledSpan)[] runs, size_t start, size_t end,
    in ResolvedTheme theme, RgbColor pageFg) @safe
{
    TextSpan[] result;
    if (start > end || end > source.length) return result;
    size_t low, high = runs.length;
    while (low < high)
    {
        const middle = low + (high - low) / 2;
        if (runs[middle].end <= start) low = middle + 1;
        else high = middle;
    }
    foreach (run; runs[low .. $])
    {
        if (run.start >= end) break;
        const from = run.start < start ? start : run.start;
        const to = run.end > end ? end : run.end;
        if (from >= to) continue;
        const style = theme[run.label];
        result ~= TextSpan(source[from .. to], Slot.code, specStyle(style),
            fg: toRgb(style.fg, pageFg), hasFg: true,
            bg: toRgb(style.bg, RgbColor.init), hasBg: style.bg.isSet,
            srcStart: from, srcEnd: to);
    }
    return result;
}

/// Windowing keeps global source identity while clipping syntax at viewport edges.
@("source_view.editor.syntaxWindowClipsGlobalOffsets")
@safe unittest
{
    import sparkles.syntax.event : LabelId;
    StyledSpan[3] runs = [StyledSpan(0, 3), StyledSpan(3, 7), StyledSpan(7, 9)];
    const spans = syntaxWindow("int value", runs[], 2, 8, ResolvedTheme.init, RgbColor(1, 2, 3));
    assert(spans.length == 3);
    assert(spans[0].text == "t" && spans[0].srcStart == 2 && spans[0].srcEnd == 3);
    assert(spans[1].text == " val" && spans[1].srcStart == 3 && spans[1].srcEnd == 7);
    assert(spans[2].text == "u" && spans[2].srcStart == 7 && spans[2].srcEnd == 8);
}

/// Overlay source-addressed syntax on one editor line, preserving synthetic preedit/carets.
TextSpan[] highlightedEditorLine(in EditorState state, size_t line,
    scope const(TextSpan)[] syntax, EditorViewOptions options = EditorViewOptions.init) @safe
{
    auto decorated = editorLineSpans(state, line, options);
    TextSpan[] result;
    size_t tokenIndex;
    foreach (ref editor; decorated)
    {
        if (editor.srcStart == size_t.max || editor.srcEnd - editor.srcStart != editor.text.length)
        {
            result ~= editor;
            continue;
        }
        size_t at = editor.srcStart;
        while (at < editor.srcEnd)
        {
            size_t stop = editor.srcEnd;
            size_t found = size_t.max;
            while (tokenIndex < syntax.length
                && (syntax[tokenIndex].srcStart == size_t.max || syntax[tokenIndex].srcEnd <= at))
                ++tokenIndex;
            if (tokenIndex < syntax.length)
            {
                ref const token = syntax[tokenIndex];
                if (token.srcStart > at)
                {
                    if (token.srcStart < stop) stop = token.srcStart;
                }
                else
                {
                    found = tokenIndex;
                    if (token.srcEnd < stop) stop = token.srcEnd;
                }
            }
            TextSpan span;
            span.text = editor.text[at - editor.srcStart .. stop - editor.srcStart];
            span.slot = editor.slot;
            span.textStyle = editor.textStyle;
            span.paintBackground = editor.paintBackground;
            span.srcStart = at;
            span.srcEnd = stop;
            if (found != size_t.max)
            {
                ref const token = syntax[found];
                span.fg = token.fg;
                span.hasFg = token.hasFg;
                span.textStyle.bold |= token.textStyle.bold;
                span.textStyle.italic |= token.textStyle.italic;
                span.textStyle.strikethrough |= token.textStyle.strikethrough;
                if (span.slot == options.textSlot)
                {
                    span.slot = token.slot;
                    span.bg = token.bg;
                    span.hasBg = token.hasBg;
                }
            }
            result ~= span;
            at = stop;
        }
    }
    return result;
}

/// A selected keyword retains syntax ink while selection/caret remain editor decorations.
@("source_view.editor.syntaxSurvivesSelection")
@safe unittest
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.components.editor : EditorViewOptions;
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    import sparkles.ui.style : Slot;
    import sparkles.ui.widget : TextSpan;
    auto state = EditorState.create("int value");
    state.selection = SelectionSet.single(EditRange(1, 3));
    const ink = RgbColor(210, 90, 60);
    TextSpan[2] syntax = [TextSpan("int", Slot.code, fg: ink, hasFg: true, srcStart: 0, srcEnd: 3),
        TextSpan(" value", Slot.code, srcStart: 3, srcEnd: 9)];
    const spans = highlightedEditorLine(state, 0, syntax[], EditorViewOptions.init);
    string selected, original;
    bool caret;
    foreach (span; spans)
    {
        if (span.slot == Slot.selection)
        {
            selected ~= span.text;
            assert(span.fg == ink && span.hasFg && span.paintBackground);
            assert(span.srcStart == 1 && span.srcEnd == 3);
        }
        if (span.slot == Slot.caret) caret = true;
        if (span.srcStart != size_t.max) original ~= span.text;
    }
    assert(selected == "nt" && original == "int value" && caret);
}

/// Composing text stays synthetic; syntax applies only to surviving source bytes.
@("source_view.editor.preeditKeepsItsOwnIdentity")
@safe unittest
{
    import sparkles.input.events : CompositionEvent;
    import sparkles.ui.editor.field : EditorField;
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    import sparkles.base.term_color : RgbColor;
    auto field = EditorField.make("abc");
    field.state.selection = SelectionSet.single(EditRange(1, 2));
    field.compose(CompositionEvent.init, "日本");
    TextSpan[1] syntax = [TextSpan("abc", Slot.code, fg: RgbColor(200, 80, 40),
        hasFg: true, srcStart: 0, srcEnd: 3)];
    const spans = highlightedEditorLine(field.state, 0, syntax[]);
    string source, preedit;
    foreach (span; spans)
    {
        if (span.srcStart != size_t.max) source ~= span.text;
        else if (span.slot != Slot.caret)
        {
            preedit ~= span.text;
            assert(!span.hasFg);
        }
    }
    assert(source == "ac" && preedit == "日本");
}

/// Dense single-line syntax intersects every token with one selection without losing offsets.
@("source_view.editor.denseLineTokenIntersections")
@safe unittest
{
    import sparkles.ui.editor.selection : EditRange, SelectionSet;
    enum count = 16_384;
    auto bytes = new char[count];
    bytes[] = 'x';
    auto state = EditorState.create(bytes);
    state.selection = SelectionSet.single(EditRange(0, count));
    auto syntax = new TextSpan[count];
    foreach (i; 0 .. count)
        syntax[i] = TextSpan("x", Slot.code, srcStart: i, srcEnd: i + 1);
    const spans = highlightedEditorLine(state, 0, syntax);
    assert(spans.length == count + 1);
    foreach (i; 0 .. count)
        assert(spans[i].slot == Slot.selection && spans[i].srcStart == i && spans[i].srcEnd == i + 1);
    assert(spans[count].slot == Slot.caret);
}
