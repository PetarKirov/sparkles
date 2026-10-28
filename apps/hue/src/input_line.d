/**
The document viewer's line-input bar — the `/` search, the `:` goto and the
DSV filter prompt.

Backend-neutral by construction: a mode and one editor field that both hosts
drive with the same key events, so the terminal and the window reach the
matcher with the same query (`UIA13`). The field is the toolkit's editor
(`EDU4`): it edits by grapheme cluster and word, kills and yanks, undoes,
and takes pastes whole, where the bar it replaced appended printable ASCII
one byte at a time.
*/
module input_line;

import sparkles.input.events : KeyEvent;
import sparkles.input.frame : InputFrame;
import sparkles.ui.editor.field : EditorField, FieldResult, FieldSetup, serveClipboard;
import sparkles.ui.state : CaptureState;

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
enum Mode
{
    normal,
    search,
    gotoLine,
    dsvFilter, // the DSV grid's filter bar (`DSF1`)
}

/// What one input did to the bar.
enum LineStep : ubyte
{
    /// Not the bar's: the key falls through.
    none,
    /// Consumed; the query did not change.
    handled,
    /// The query changed (the search mode's cue to re-run it).
    edited,
    /// Enter.
    submitted,
    /// Escape with nothing left to collapse.
    cancelled,
}

/// The input-routing state (M15 GROUP-I of the GuiState hoist): which
/// line-input surface owns the keyboard ('/' search, ':' goto) and its
/// query, pointer-capture ownership (STM11), and the per-frame
/// `FrameInput` fold carry (IXB7 — the button level lives across frames).
struct InputState
{
    Mode mode = Mode.normal;
    /// The bar's editor; `query` is its text.
    EditorField field;
    /// The bar's key table and clipboard, applied each time it opens.
    FieldSetup setup;
    CaptureState capture;
    InputFrame fin;
    private string text_;

    /// The query, as of the last edit.
    const(char)[] query() const return @safe pure nothrow @nogc => text_;

    /// The query as the bar shows it: the caret glyph where the editor has
    /// its caret, and nothing else marked (`EDR1`).
    string shown(bool caret = true) const @safe pure nothrow
    {
        import sparkles.ui.components.editor : EditorViewOptions, editorLineSpans;

        EditorViewOptions options;
        options.caretVisible = caret;
        string result;
        foreach (span; editorLineSpans(field.state, 0, options))
            result ~= span.text;
        return result;
    }

    /// Opens the bar in `mode` with an empty query. Goto-line takes digits.
    void open(Mode mode) @safe pure nothrow
    {
        this.mode = mode;
        field = setup.singleLine();
        if (mode == Mode.gotoLine)
            field.state.options.accepts = (dchar c) => c >= '0' && c <= '9';
        text_ = null;
    }

    /// Closes the bar and clears the query.
    void close() @safe pure nothrow
    {
        mode = Mode.normal;
        field = setup.singleLine();
        text_ = null;
    }

    /// One key for the bar's editor.
    LineStep key(in KeyEvent e) @safe pure nothrow => outcome(field.key(e));

    /// Text pasted into the bar (`EDI4`).
    LineStep paste(scope const(char)[] text) @safe pure nothrow
        => outcome(field.insert(text, true));

    /// Text typed into the bar at once (a debug seed, a test).
    LineStep type(scope const(char)[] text) @safe pure nothrow
        => outcome(field.insert(text));

    /// Do the clipboard work the bar asked for (`EDY5`): a copy, and a
    /// paste answered with `clipboard`'s text.
    LineStep serve(Clipboard)(in Clipboard clipboard)
        => outcome(serveClipboard(field, clipboard));

    private LineStep outcome(in FieldResult r) @safe pure nothrow
    {
        if (!r.handled)
            return LineStep.none;
        if (r.cancelled)
            return LineStep.cancelled;
        if (r.submitted)
            return LineStep.submitted;
        if (!r.changed)
            return LineStep.handled;
        text_ = field.text;
        return LineStep.edited;
    }
}

@("input_line.InputState.editsLikeAnEditor")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key, Mods;

    InputState inp;
    inp.open(Mode.search);
    assert(inp.type("foo bar") == LineStep.edited);
    assert(inp.key(KeyEvent(Key.char_, 'w', Mods(ctrl: true))) == LineStep.edited);
    assert(inp.query == "foo ", "Ctrl-W kills back to the blank");
    assert(inp.type("é") == LineStep.edited && inp.query == "foo é", "the query is Unicode");
    assert(inp.key(KeyEvent(Key.enter)) == LineStep.submitted);
    assert(inp.key(KeyEvent(Key.escape)) == LineStep.cancelled);
    assert(inp.key(KeyEvent(Key.f5)) == LineStep.none, "keys the editor declines fall through");
}

@("input_line.InputState.gotoLineTakesDigits")
@safe pure nothrow
unittest
{
    InputState inp;
    inp.open(Mode.gotoLine);
    inp.type("12");
    assert(inp.type("x") == LineStep.handled, "a letter is refused, not inserted");
    inp.type("3");
    assert(inp.query == "123");
    inp.close();
    assert(inp.mode == Mode.normal && inp.query.length == 0);
}

@("input_line.InputState.pastesAreOneLine")
@safe pure nothrow
unittest
{
    InputState inp;
    inp.open(Mode.dsvFilter);
    assert(inp.paste("a > 1\n") == LineStep.edited);
    assert(inp.query == "a > 1 ", "a pasted line break becomes a space");
}

@("input_line.InputState.shownPlacesTheCaret")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key;

    InputState inp;
    inp.open(Mode.search);
    inp.type("abc");
    inp.key(KeyEvent(Key.left));
    assert(inp.shown == "ab▏c");
    assert(inp.shown(false) == "abc");
}

@("input_line.InputState.servesItsClipboard")
@safe pure nothrow
unittest
{
    import sparkles.input.events : Key, Mods;
    import sparkles.ui.editor.field : fieldClipboard, FieldSetup;
    import sparkles.ui.editor.keys : EditorTarget;

    string board = "needle";
    auto clipboard = fieldClipboard((scope const(char)[] t) { board = t.idup; }, () => board);
    InputState inp;
    inp.setup = FieldSetup.of(EditorTarget.window, clipboard);
    inp.open(Mode.search);
    assert(inp.key(KeyEvent(Key.char_, 'v', Mods(ctrl: true))) == LineStep.handled);
    assert(inp.serve(clipboard) == LineStep.edited && inp.query == "needle");
    inp.key(KeyEvent(Key.char_, 'a', Mods(ctrl: true)));
    inp.key(KeyEvent(Key.char_, 'x', Mods(ctrl: true)));
    assert(inp.serve(clipboard) == LineStep.none, "a copy changes nothing here");
    assert(board == "needle" && inp.field.empty);
}
