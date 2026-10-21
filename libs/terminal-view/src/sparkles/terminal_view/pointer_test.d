/**
The terminal's mouse from events, through the recording host (plan slice V5
of `docs/specs/ui-vulkan`): a script of pointer and wheel events in pane
pixels, run by `runAppRecorded` against a `TerminalView` on a pty the test
holds. What a drag selects, what a double and a triple click select, where
a press on the overlay bar takes the scrollback, and what a program that
tracks the mouse is sent.

Cells are 10 × 20 pixels, so pixel `(x, y)` is cell `(x / 10, y / 20)`.
*/
module sparkles.terminal_view.pointer_test;

version (unittest):

import sparkles.input : Event, Mods, Point, PointerAction, PointerButton, PointerEvent,
    WheelEvent;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import sparkles.terminal_view.component : TerminalViewOptions;
import sparkles.terminal_view.protocol_oracle : RecordingPty;

private enum ushort cols = 30, rows = 6;

private RecordingPty* pane(scope const(char)[] output) @system
{
    TerminalViewOptions o;
    o.pollMouse = false; // the script is the mouse
    auto r = RecordingPty.open(o, cols, rows, 10, 20);
    r.program(output);
    return r;
}

// The pane as the application, without its `shutdown`: the run ends, the
// pane stays open for the assertions.
private struct Pane
{
    import sparkles.terminal_view.component : TerminalView;
    import sparkles.ui.widget : WidgetTree;

    TerminalView* tv;

    WidgetTree view(H)(ref H h) => tv.view(h);
    void handle(H)(ref H h, in Event e) { tv.handle(h, e); }
}

private void run(RecordingPty* r, Event[] script) @system
{
    auto app = Pane(r.tv);
    cast(void) runAppRecorded(app, RunConfig.init, script, (ref RecordingHost h) {
        h.size = Size(cols, rows);
    });
}

private Event press(int x, int y, Mods m = Mods.init)
    => Event(PointerEvent(action: PointerAction.press, button: PointerButton.left,
        pos: Point(x, y), mods: m));
private Event drag(int x, int y, Mods m = Mods.init)
    => Event(PointerEvent(action: PointerAction.drag, button: PointerButton.left,
        pos: Point(x, y), mods: m));
private Event release(int x, int y, Mods m = Mods.init)
    => Event(PointerEvent(action: PointerAction.release, button: PointerButton.left,
        pos: Point(x, y), mods: m));

@("terminal_view.pointer.aDragSelectsFromPressToRelease")
@system unittest
{
    auto r = pane("alpha beta gamma\r\nsecond line here\r\n");
    scope (exit) r.close();
    // (Not from cell (0, 0): a selection with both ends there reads as one
    // the program cleared away, `TSE4`.)
    run(r, [press(15, 5), drag(60, 25), drag(125, 25), release(125, 25)]);
    assert(r.tv.selectionText == "lpha beta gamma\nsecond line h", r.tv.selectionText);
    assert(!r.tv.s.selState.isSelecting, "the release ends the drag");
}

@("terminal_view.pointer.aDoubleClickSelectsAWordATripleTheLine")
@system unittest
{
    auto r = pane("alpha beta gamma\r\n");
    scope (exit) r.close();
    run(r, [press(75, 5), release(75, 5), press(75, 5), release(75, 5)]);
    assert(r.tv.selectionText == "beta", r.tv.selectionText);
    run(r, [press(75, 5), release(75, 5)]);
    assert(r.tv.selectionText == "alpha beta gamma", r.tv.selectionText);
}

@("terminal_view.pointer.altDragSelectsABlock")
@system unittest
{
    auto r = pane("abcdef\r\nghijkl\r\n");
    scope (exit) r.close();
    run(r, [press(15, 5, Mods(alt: true)), drag(35, 25, Mods(alt: true)),
        release(35, 25, Mods(alt: true))]);
    assert(r.tv.selectionText == "bcd\nhij", r.tv.selectionText);
}

@("terminal_view.pointer.theBarTakesThePressAndTheScrollback")
@system unittest
{
    import std.conv : text;

    // Forty full lines in a six-row pane: history to walk, the viewport at
    // the bottom, the bar over the text in the pane's rightmost 16 pixels.
    import std.string : leftJustify;

    char[] lines;
    foreach (i; 0 .. 40)
        lines ~= text("line ", i).leftJustify(cols, '.') ~ "\r\n";
    auto r = pane(lines);
    scope (exit) r.close();
    const bottom = r.tv.scrollback();
    assert(bottom.total > bottom.len && bottom.offset == bottom.total - bottom.len);

    // A press on the track above the thumb jumps there (`STM9`), and it is
    // the bar's: nothing is selected.
    run(r, [press(295, 2), release(295, 2)]);
    const jumped = r.tv.scrollback();
    assert(jumped.offset < bottom.offset, text(jumped.offset, " vs ", bottom.offset));
    assert(!r.tv.hasSelection, "the bar consumed the press");

    // The same press inside the text selects instead.
    run(r, [press(15, 5), release(15, 5)]);
    assert(r.tv.scrollback().offset == jumped.offset);
}

@("terminal_view.pointer.aTrackingProgramIsSentReportsNotASelection")
@system unittest
{
    import std.algorithm.searching : canFind;

    // SGR mouse reporting on: a press and release at cell (2, 2) are the
    // program's, one-based on the wire, and select nothing.
    auto r = pane("hello world\x1b[?1000h\x1b[?1006h");
    scope (exit) r.close();
    r.recorded = null;
    run(r, [press(25, 45), release(25, 45)]);
    r.program("");
    assert(r.recorded.canFind("\x1b[<0;3;3M") && r.recorded.canFind("\x1b[<0;3;3m"),
        r.recorded);
    assert(!r.tv.hasSelection);

    // Shift takes the mouse back for a selection.
    run(r, [press(15, 5, Mods(shift: true)), drag(45, 5, Mods(shift: true)),
        release(45, 5, Mods(shift: true))]);
    assert(r.tv.hasSelection);

    // The wheel becomes the scroll buttons, 64 and 65 in SGR.
    r.recorded = null;
    run(r, [Event(WheelEvent(dy: -3, pos: Point(25, 45))),
        Event(WheelEvent(dy: 3, pos: Point(25, 45)))]);
    r.program("");
    assert(r.recorded.canFind("\x1b[<64;3;3M") && r.recorded.canFind("\x1b[<65;3;3M"),
        r.recorded);
}

@("terminal_view.pointer.aWheelWalksTheScrollback")
@system unittest
{
    import std.conv : text;

    char[] lines;
    foreach (i; 0 .. 40)
        lines ~= text("line ", i, "\r\n");
    auto r = pane(lines);
    scope (exit) r.close();
    const before = r.tv.scrollPos;
    run(r, [Event(WheelEvent(dy: -3, pos: Point(50, 50)))]);
    assert(r.tv.scrollPos < before, text(r.tv.scrollPos, " vs ", before));
}
