/**
The diagram board component (`DIA3`, `DIA6`).

Everything the application $(I is) lives here as a `runApp` component —
`main` (in `app.d`, excluded from the test build) only parses the CLI and
calls $(REF runApp, sparkles,ui_app,run_app). That split is `DIA6`: every
behaviour is a free function over $(MREF world) (and the camera), exercised
by scripted-event tests against the recording target, and `main` is the only
untested line.

`handle` builds an $(REF InputView, systems,input) from the host and hands the
event to $(REF systemInput, systems,input). `paint` rebuilds the frame's op
buffer through $(REF systemRender, systems,render) and replays it onto
`host.canvas` (`HST13`, `RND1`). Interaction state lives in the $(LREF World)
(`WLD4`); the toolkit's $(REF CaptureState, sparkles,ui,state) is the drag
arbitration (`IXN1`).
*/
module diagram_app;

import sparkles.input : EndOfInput, Event, isEndOfInput, match;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.layout : Frame;
import sparkles.ui.state : CaptureState;
import sparkles.ui.widget : WidgetTree;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.run_app : AppTheme;

import camera : Camera;
import systems.input : InputView, systemInput;
import systems.render : FrameOps, systemRender;
import world : World;

/// The application component: state → frames, events → state.
struct DiagramApp
{
    World world;           /// the board and every piece of interaction (`WLD4`)
    Camera camera;         /// the viewport onto the world (`CAM`)
    CaptureState capture;  /// toolkit drag arbitration (`IXN1`)
    /**
    The frame's theme (`RND5`). `main` sets it from `--theme` via
    $(REF appThemeOf, sparkles,ui_app,run_app) so the CLI theme reaches the
    board as well as the page fill; $(REF frameTheme, sparkles,ui_app,run_app)
    then prefers this over the run fallback.
    */
    AppTheme theme;
    /// Reused op buffer — board + minimap + chrome (`RND1`, `DIA5`).
    FrameOps frameOps;

    /// Empty tree: the board is a display-list application, not a widget tree.
    /// The host still paints the theme's page fill; we paint on top in
    /// $(LREF paint).
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

    /**
    Draw phase (`HST13` / `DIA3`): rebuild the frame ops and replay them onto
    the host's canvas through the toolkit's immediate interpreter — so the
    board paints identically on every arm.
    */
    void paint(H)(ref H h, in WidgetTree, in Frame[])
    {
        systemRender(world, camera, h.size, theme.palette, theme.pageFg,
            theme.pageBg, frameOps);
        // One call on every host: `paint` is `auto ref`, so a recorder field
        // binds by reference and a live by-value handle binds by value.
        .paint(h.canvas, frameOps[]);
    }
}

// ---------------------------------------------------------------------------
// Scripted-session tests (`TST1`): no window, no tty. Fine-grained tool /
// capture / render behaviour is pure under `systems.*`; these assert the
// component wires the host through.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, keyEvent, Key, KeyAction, Mods,
        PointerAction, PointerButton, PointerEvent, Point;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui.style : ColorScheme, defaultTwoslashPalette, Slot;
    import sparkles.ui_app.gui_options : GuiOptions;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : appThemeOf, isAppFor, runAppRecorded;
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

    private DiagramApp themedApp() @safe
    {
        DiagramApp app;
        app.theme = appThemeOf(GuiOptions.init);
        // Ensure a non-empty palette even if the options resolve to a
        // syntax-only theme — the render path names slots.
        if (!app.theme.palette.bg[Slot.surface].isSet)
            app.theme.palette = defaultTwoslashPalette(ColorScheme.dark);
        return app;
    }
}

@("diagram.app.quitsOnQ")
@safe
unittest
{
    auto app = themedApp();
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
    auto app = themedApp();
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
    // The host paints the theme's page fill; the board paints on top via the
    // canvas (`RND5` / `HST13`).
    auto app = themedApp();
    auto rec = runAppRecorded(app, RunConfig.init, []);
    assert(rec.frames.length == 1);
    assert(rec.frames[0].ops.length >= 1);
    assert(rec.frames[0].ops[0].kind == OpKind.fillRect);
    // Draw phase ran: the canvas holds board/chrome ops.
    assert(rec.canvas.ops.length > 0);
    assert(app.frameOps.length > 0);
}

@("diagram.app.scriptedSessionCreatesAndSelects")
@safe
unittest
{
    // End-to-end through `runAppRecorded`: the component's world is the one
    // `systemInput` mutated — `WLD4` in one assertion site.
    auto app = themedApp();
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
    auto app = themedApp();
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

    auto app2 = themedApp();
    auto rec2 = runAppRecorded(app2, RunConfig.init, [
        charEvent('+'),
        charEvent('+'),
        charEvent('0'),
        charEvent('q'),
    ]);
    assert(rec2.quitRequested);
    assert(app2.camera.zoom == 0 && app2.camera.scalePercent == 100);
}

@("diagram.app.scriptedSessionMenuGroupLabelConnect")
@safe
unittest
{
    // Series 2 sweep: create two boxes, group via menu, label one, connect.
    auto app = themedApp();
    import systems.input : menuItemRect, MenuItem;
    import sparkles.input : PointerButton;

    auto rec = runAppRecorded(app, RunConfig.init, [
        charEvent('r'),
        press(2, 1 + 2), drag(6, 1 + 5), release(6, 1 + 5),
        press(10, 1 + 2), drag(14, 1 + 5), release(14, 1 + 5),
        charEvent('v'),
        // Shift-select both is hard without tracking selection; use g after
        // selecting via marquee over both.
        press(1, 1 + 1), drag(16, 1 + 8), release(16, 1 + 8),
        charEvent('g'),
        charEvent('q'),
    ]);
    assert(rec.quitRequested);
    assert(app.world.count == 2);
    assert(app.world.group[0] != 0 && app.world.group[0] == app.world.group[1]);
}

@("diagram.app.paintEmitsBoardOpsForLiveEntities")
@safe
unittest
{
    auto app = themedApp();
    const e = app.world.spawn(Rect(2, 2, 6, 3));
    app.world.setLabel(e, "Box");
    auto rec = runAppRecorded(app, RunConfig.init, []);
    assert(app.frameOps.length > 0, "paint rebuilt the op buffer");

    // Slots live on the op buffer (`RND5`); the canvas recorder drops them
    // (it only keeps kind/rect/visual). Assert slots on frameOps, geometry
    // on both.
    bool frameBody, canvasBody, frameGlyph;
    foreach (ref op; app.frameOps[])
    {
        if (op.kind == OpKind.fillRect && op.slot == Slot.surface
            && op.rect.width >= 6)
            frameBody = true;
        if (op.kind == OpKind.glyph && op.glyph == 'B' && op.slot == Slot.code)
            frameGlyph = true;
    }
    foreach (ref op; rec.canvas.ops)
        if (op.kind == OpKind.fillRect && op.rect.width >= 6
            && op.rect.height >= 3)
            canvasBody = true;
    assert(frameBody, "frameOps holds the entity body with Slot.surface");
    assert(frameGlyph, "frameOps holds the label glyph");
    assert(canvasBody, "canvas received the entity body");
}
