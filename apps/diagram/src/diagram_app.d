/**
The diagram board component (`DIA3`, `DIA6`).

Everything the application $(I is) lives here as a `runApp` component —
`main` (in `app.d`, excluded from the test build) only parses the CLI and
calls $(REF runApp, sparkles,ui_app,run_app). That split is `DIA6`: every
behaviour is a free function over $(MREF world) (and the camera), exercised
by scripted-event tests against the recording target, and `main` is the only
untested line.

`handle` builds an $(REF InputView, systems,input) from the host and hands the
event to $(REF systemInput, systems,input). Interaction state lives in the
$(LREF World) (`WLD4`); the toolkit's $(REF CaptureState, sparkles,ui,state)
is the drag arbitration (`IXN1`).
*/
module diagram_app;

import sparkles.input : EndOfInput, Event, isEndOfInput, match;
import sparkles.ui.state : CaptureState;
import sparkles.ui.widget : WidgetTree;
import sparkles.ui_app.backend : Backend;

import camera : Camera;
import systems.input : InputView, systemInput;
import world : World;

/// The application component: state → frames, events → state.
struct DiagramApp
{
    World world;           /// the board and every piece of interaction (`WLD4`)
    Camera camera;         /// the viewport onto the world (`CAM`)
    CaptureState capture;  /// toolkit drag arbitration (`IXN1`)

    /// The scaffold still presents the bare themed page; the board's op
    /// streams arrive with the render systems (`RND1`) and replay in the draw
    /// phase (`HST13`).
    WidgetTree view(H)(ref H h) => WidgetTree.init;

    /// Feeds one event to $(REF systemInput, systems,input). Quits when the
    /// system says so (`q`, the dismissal chain's tail, end-of-input).
    void handle(H)(ref H h, in Event e)
    {
        if (isEndOfInput(e) || e.match!((in EndOfInput _) => true, _ => false))
        {
            h.quit();
            return;
        }

        InputView view = {
            viewport: h.size,
            capabilities: h.capabilities,
            backend: h.backend,
        };
        // Pixel pointer path (`HST18`): a GUI host's canvas carries the
        // natural cell metrics. Named by introspection so this file never
        // imports a backend (`DIA1`/`DIA2`).
        static if (__traits(compiles, { int w = h.canvas.cellW; int hh = h.canvas.cellH; }))
        {
            if (h.backend == Backend.gui)
            {
                view.naturalCellW = h.canvas.cellW;
                view.naturalCellH = h.canvas.cellH;
            }
        }

        if (systemInput(world, camera, capture, e, view))
            h.quit();
    }
}

// ---------------------------------------------------------------------------
// Scripted-session tests (`TST1`): no window, no tty. Fine-grained tool /
// capture behaviour is pure under `systems.input`; these assert the component
// wires the host through and still quits cleanly.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, keyEvent, Key, KeyAction, Mods,
        PointerAction, PointerButton, PointerEvent, Point;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : isAppFor, runAppRecorded;
    import sparkles.ui_app.record : RecordingHost;
    import world : Tool;

    static assert(isAppFor!(DiagramApp, RecordingHost));

    private Event press(int x, int y, PointerButton b = PointerButton.left)
        @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.press, button: b,
            pos: Point(x, y)));
    private Event drag(int x, int y, PointerButton b = PointerButton.left)
        @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.drag, button: b,
            pos: Point(x, y)));
    private Event release(int x, int y, PointerButton b = PointerButton.left)
        @safe pure nothrow @nogc
        => Event(PointerEvent(action: PointerAction.release, button: b,
            pos: Point(x, y)));
}

@("diagram.app.quitsOnQ")
@safe
unittest
{
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig(title: "diagram"), [
        charEvent('x'),  // ignored
        charEvent('q'),  // quits
        charEvent('x'),  // never delivered
    ]);

    // First frame + one per delivered event; the run ends at quit.
    assert(rec.frames.length == 3);
}

@("diagram.app.dismissChainTailQuits")
@safe
unittest
{
    // With nothing open, Esc is the chain's tail: quit (IXN6). A release
    // must not quit a second time — or at all.
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig.init, [
        keyEvent(Key.escape, Mods(), KeyAction.release), // ignored
        keyEvent(Key.escape),
    ]);
    assert(rec.frames.length == 3);
}

@("diagram.app.presentsTheThemedPage")
@safe
unittest
{
    import sparkles.ui.canvas : OpKind;

    // The scaffold's whole frame is the theme's page fill (`RND5` starts
    // here: the default --theme reaches the board with no app code).
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig.init, []);
    assert(rec.frames.length == 1);
    assert(rec.frames[0].ops.length == 1);
    assert(rec.frames[0].ops[0].kind == OpKind.fillRect);
}

@("diagram.app.scriptedSessionCreatesAndSelects")
@safe
unittest
{
    // End-to-end through `runAppRecorded`: the component's world is the one
    // `systemInput` mutated — `WLD4` in one assertion site.
    DiagramApp app;
    auto rec = runAppRecorded(app, RunConfig(title: "diagram"), [
        charEvent('r'),
        press(4, 1 + 3),
        drag(12, 1 + 9),
        release(12, 1 + 9),
        charEvent('v'),
        charEvent('q'),
    ]);
    assert(rec.quitRequested);
    assert(app.world.count == 1);
    assert(app.world.tool == Tool.select);
    assert(app.world.selectionCount == 1);
    assert(app.capture.isFree);
}

@("diagram.app.scriptedSessionPansAndZooms")
@safe
unittest
{
    DiagramApp app;
    // Pan alone first — a subsequent zoom-at-pivot deliberately moves the
    // origin, so the pan's delta is asserted before that.
    auto rec = runAppRecorded(app, RunConfig.init, [
        press(30, 12, PointerButton.middle),
        drag(20, 12, PointerButton.middle),
        release(20, 12, PointerButton.middle),
        charEvent('q'),
    ]);
    assert(rec.quitRequested);
    assert(app.camera.origin.x == 10);

    DiagramApp app2;
    auto rec2 = runAppRecorded(app2, RunConfig.init, [
        charEvent('+'),
        charEvent('+'),
        charEvent('0'),
        charEvent('q'),
    ]);
    assert(rec2.quitRequested);
    assert(app2.camera.zoom == 0 && app2.camera.scalePercent == 100);
}
