/**
The document viewer's line-input bar — the `/` search, the `:` goto and the
DSV filter prompt.

Backend-neutral by construction: a mode, a bounded query buffer, and the two
acceptance rules that decide what a keystroke does to it. It lives in its own
module rather than in `gui_state` because the terminal drives the same bar,
and it reached the same feature by hand — a raw `char[256]` written with
`cast(char) e.ch`, which truncates any non-ASCII code point into a stray byte
and leaves the query invalid UTF-8. Two hosts feeding one matcher different
queries is the `UIA13` defect the search unification exists to end; sharing
the matcher is necessary and not sufficient, so the INPUT is shared too.
*/
module input_line;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.frame : InputFrame;
import sparkles.ui.state : CaptureState;

/// The interactive input mode (M4): normal keys, or typing a search / goto line.
enum Mode
{
    normal,
    search,
    gotoLine,
    dsvFilter, // the DSV grid's filter bar (`DSF1`)
}


/// The input-routing state (M15 GROUP-I of the GuiState hoist): which
/// line-input surface owns the keyboard ('/' search, ':' goto) and its
/// typed query, pointer-capture ownership (STM11), and the per-frame
/// `FrameInput` fold carry (IXB7 — the button level lives across frames).
struct InputState
{
    Mode mode = Mode.normal;
    SmallBuffer!(char, 256) query;
    CaptureState capture;
    InputFrame fin;

    /**
    Feeds one typed code point into the query under the mode's acceptance
    rules — printable ASCII only, goto-line takes digits only, and the query
    caps at 255. Returns `true` when the character was $(B accepted) (the
    search mode's cue to re-run the query) — deliberately not "appended":
    at the cap an accepted character still re-runs the search with the
    unchanged query, exactly as the inline version did.
    */
    bool typeChar(dchar c) @safe pure nothrow
    {
        if (c < 32 || c >= 127)
            return false;
        if (mode == Mode.gotoLine && (c < '0' || c > '9'))
            return false;
        if (query.length < 255)
            query ~= cast(char) c;
        return true;
    }

    /// Deletes the last typed character: `true` when something was deleted —
    /// the same re-search cue.
    bool backspace() @safe pure nothrow @nogc
    {
        if (query.length == 0)
            return false;
        query.popBack();
        return true;
    }
}

@("input_line.InputState.typeCharAcceptanceRules")
@safe pure nothrow
unittest
{
    InputState inp;
    inp.mode = Mode.search;
    assert(inp.typeChar('a'));
    assert(inp.typeChar('3'));
    assert(!inp.typeChar('\x1b'), "control characters never type");
    assert(!inp.typeChar('é'), "the query is ASCII");
    assert(inp.query[] == "a3");

    inp.mode = Mode.gotoLine;
    assert(!inp.typeChar('a'), "goto-line takes digits only");
    assert(inp.typeChar('7'));
    InputState flt;
    flt.mode = Mode.dsvFilter;
    assert(flt.typeChar('q'), "the filter bar takes printable ASCII");
    assert(flt.typeChar('>'), "operators type through");
    assert(!flt.typeChar('\x1b'), "control characters still never type");
    assert(flt.query[] == "q>");
    assert(inp.query[] == "a37");
}

@("input_line.InputState.typeCharCapStillReSearches")
@safe pure nothrow
unittest
{
    // At the cap the character is accepted (the caller re-searches) but not
    // appended — the inline behavior, preserved on purpose.
    InputState inp;
    inp.mode = Mode.search;
    foreach (i; 0 .. 255)
        cast(void) inp.typeChar('x');
    assert(inp.query.length == 255);
    assert(inp.typeChar('y'), "accepted at the cap");
    assert(inp.query.length == 255, "but not appended");
}


@("input_line.InputState.backspaceDeletesOrDeclines")
@safe pure nothrow
unittest
{
    InputState inp;
    assert(!inp.backspace(), "nothing to delete");
    cast(void) inp.typeChar('q');
    assert(inp.backspace());
    assert(inp.query.length == 0);
}
