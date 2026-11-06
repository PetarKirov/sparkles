/** Syntax presentation composed with shared editor decorations and source identity. */
module sparkles.source_view.editor;

import sparkles.ui.components.editor : editorLineSpans, EditorViewOptions;
import sparkles.ui.editor.state : EditorState;
import sparkles.ui.style : Slot;
import sparkles.ui.widget : TextSpan;

/// Overlay source-addressed syntax on one editor line, preserving synthetic preedit/carets.
TextSpan[] highlightedEditorLine(in EditorState state, size_t line,
    scope const(TextSpan)[] syntax, EditorViewOptions options = EditorViewOptions.init) @safe
{
    auto decorated = editorLineSpans(state, line, options);
    TextSpan[] result;
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
            foreach (i, ref token; syntax)
            {
                if (token.srcStart == size_t.max || token.srcEnd <= at) continue;
                if (token.srcStart > at)
                {
                    if (token.srcStart < stop) stop = token.srcStart;
                }
                else
                {
                    found = i;
                    if (token.srcEnd < stop) stop = token.srcEnd;
                    break;
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
