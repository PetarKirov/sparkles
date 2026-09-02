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

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.unique : makeUnique, Unique;
import sparkles.input : EndOfInput, Event, isEndOfInput, KeyAction, KeyEvent,
    match, Point, PointerAction, PointerEvent, WheelEvent;
import sparkles.ui.components.lantern_view : BoxLayout, LabelArena, LanternStyle,
    Placement, viewLantern;
import sparkles.ui.display_list : buildDisplayListInto;
import sparkles.ui.geometry : Constraints, Size;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui.layout : Frame, layout;
import sparkles.ui.state : CaptureState;
import sparkles.ui.widget : Builder, WidgetTree;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.run_app : AppTheme;

import camera : Camera;
import grid_file : saveGridConfigFile;
import keymap : Binding, bindingsAt, DiagramContext;
import settings_pane : PaneGeometry, paneGeometryFor, PaneOutcome, SettingsPane;
import systems.input : InputView, surfaceCell, systemInput;
import systems.render : FrameOps, systemRender;
import world : World;

/// How many rows the key guide may list at once (`LTN`). The board's whole
/// table is smaller than this, so the panel never scrolls today.
enum size_t guideRowCap = 64;

/**
The passkey that makes $(LREF DiagramApp.create) the only constructor.

`private` to this module, so no other module can name it — and therefore none
can reach the constructor that takes one. The constructor itself cannot be
`private`: $(REF makeUnique, sparkles,base,unique) builds the value in its own
module, where a private constructor is not visible.
*/
private struct AppKey {}

/**
The application component: state → frames, events → state.

$(B Heap-only, by construction.) A `DiagramApp` is ~3 MiB — the reused op
buffer (`RND1`) and the world's dense entity arrays (`WLD4`) — while a
non-main thread's stack is 512 KiB on macOS. A by-value instance is therefore
not a size problem to keep an eye on, it is a crash: the unittest runner runs
tests on `std.parallelism` workers, and a factory returning one by value took
down the whole binary with `SIGBUS` and no output.

So `this()` is disabled, the real constructor takes a key only this module can
name, and $(LREF create) hands back a
$(REF Unique, sparkles,base,unique) over the malloc heap — which is also
move-only, so nobody copies those 3 MiB either.
*/
struct DiagramApp
{
    // The board is heap-only too (`World` is ~442 KiB of dense columns), so
    // the app owns a handle rather than the value. `world` borrows it, which
    // is why every use site — and every system taking `ref World` — reads
    // exactly as it did when this was a field.
    private Unique!World _world;
    /// The board and every piece of interaction (`WLD4`).
    ref World world() @safe pure nothrow @nogc return => _world.get();
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
    /// The key guide's label storage, reused across frames (`LTN`).
    LabelArena guideLabels;
    /**
    The modal settings pane (`SET1`).

    GC state — a property tree, its rows and its edit history — so it lives
    here rather than in the `@nogc` $(MREF world) (`DIA5`). The world keeps
    only `settingsOpen`, which is the flag the keymap and the systems read.
    */
    SettingsPane settingsPane;
    /**
    Where `s` writes (`SET5`), set by `main`: `--config-file`'s path, or the
    platform config dir. Empty means the pane has nowhere to save and says so
    instead of guessing a location.
    */
    string settingsPath;

    /// No stack instances: see the type's note. `create` is the way in.
    @disable this();

    /// The real constructor — unreachable without an $(LREF AppKey).
    this(AppKey, in AppTheme th) @safe pure nothrow @nogc
    {
        theme = th;
        _world = World.create();
    }

    /**
    The only way to build one: a sole-ownership handle to a heap-allocated
    board, off the collected heap (`makeUnique`'s allocator is `Mallocator`)
    and rooted for the references it holds.
    */
    static Unique!DiagramApp create(in AppTheme th = AppTheme.init)
        @safe nothrow
        => makeUnique!DiagramApp(AppKey.init, th);

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

        // The pane is modal (`SET2`), so it receives the event instead of the
        // board. This is the ONE `if` the design allows: it decides who is
        // listening, never what a key means — that stays the keymap's
        // `settings` scope, which is terminal and hides the board's rows.
        if (world.settingsOpen)
        {
            routeToPane(h.size, view, e);
            return;
        }

        if (systemInput(world, camera, capture, e, view))
            h.quit();
    }

    /// Feeds one event to the open pane, in the pane's own coordinates.
    private void routeToPane(in Size viewport, in InputView view, in Event e)
        @safe
    {
        const g = paneGeometryFor(viewport);
        settingsPane.ensure(world.settings, g);
        auto self = (() @trusted => &this)();
        e.match!(
            (in KeyEvent k) {
                // A release is not pane business, and a terminal cannot send
                // one anyway — the same rule the board's `onKey` follows.
                if (k.action == KeyAction.release)
                    return;
                self.applyOutcome(
                    self.settingsPane.handleKey(self.world.settings, k));
            },
            (in PointerEvent p) {
                const cell = surfaceCell(p.pos, view);
                if (!g.contains(cell))
                {
                    // A click outside a modal surface closes it, which is what
                    // every other overlay on this board does.
                    if (p.action == PointerAction.press)
                    {
                        self.settingsPane.close(self.world.settings);
                        self.world.settingsOpen = false;
                    }
                    return;
                }
                PointerEvent local = p;
                local.pos = Point(cell.x - g.x, cell.y - g.y);
                self.applyOutcome(self.settingsPane.handleOverlay(
                    self.world.settings, Event(local)));
            },
            (in WheelEvent wv) {
                self.applyOutcome(self.settingsPane.handleOverlay(
                    self.world.settings, Event(wv)));
            },
            (e2) {},
        );
    }

    /// Performs what the pane asked for and could not do itself (`SET5`).
    private void applyOutcome(PaneOutcome outcome) @safe
    {
        final switch (outcome)
        {
            case PaneOutcome.consumed:
                return;
            case PaneOutcome.closed:
                world.settingsOpen = false;
                return;
            case PaneOutcome.saveRequested:
                settingsPane.status = saveSettings();
                return;
        }
    }

    /**
    Writes the grid half through the schema `--config-file` reads (`SET5`), and
    answers with the footer line — a reason on failure, never an exception: the
    board is fine either way, and a stack trace would be the wrong report.
    */
    private string saveSettings() @safe
    {
        if (settingsPath.length == 0)
            return "nowhere to save — start with --config-file PATH";
        string err;
        return saveGridConfigFile(settingsPath, world.settings.grid, err)
            ? "saved to " ~ settingsPath : err;
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
        paintGuide(h.size);
        paintSettings(h.size);
        // One call on every host: `paint` is `auto ref`, so a recorder field
        // binds by reference and a live by-value handle binds by value.
        .paint(h.canvas, frameOps[]);
    }

    /**
    Appends the key guide's panel to the frame, along the bottom edge (`LTN5`).

    The panel is a widget tree — $(REF viewLantern, sparkles,ui,components,lantern_view)
    builds it from the same $(REF bindingsAt, keymap) the resolver reads, so
    what it advertises cannot disagree with what a key does. Nothing here
    measures a label or divides a width.

    $(B The one place the board leaves its op-buffer discipline.) `Builder`
    and `layout` allocate, so this costs a GC frame — but only on the frames
    the panel actually shows, and never in $(REF systemRender, systems,render),
    which stays `@nogc` (`DIA5`).
    */
    private void paintGuide(in Size viewport) @safe
    {
        if (!world.lantern.shown)
            return;

        SharedBuffer!(Binding, guideRowCap) listed;
        bindingsAt(listed, DiagramContext(isEditing: world.isEditing,
            settingsOpen: world.settingsOpen), world.lantern.pending[]);
        if (listed.length == 0)
            return;

        Builder b;
        BoxLayout box;
        const root = viewLantern(b, guideLabels, listed[],
            world.lantern.pending.length, viewport.width, box,
            Placement.classic, LanternStyle.init, 0, world.lantern.scroll);
        auto tree = b.finish(root);
        auto frames = layout(tree, Constraints(maxW: viewport.width));

        // The panel builds at the origin; the frame wants it on the bottom
        // edge, so the appended ops — and only those — shift down together.
        const dy = viewport.height - frames[tree.root].rect.height;
        const start = frameOps.length;
        buildDisplayListInto(tree, frames, theme.palette, theme.pageFg,
            theme.pageBg, frameOps);
        if (dy <= 0)
            return;
        foreach (ref op; frameOps.ops[start .. $])
            op.translate(0, dy);
    }

    /**
    Appends the settings pane to the frame, centred (`SET1`, `SET8`).

    Same shape as $(LREF paintGuide) and for the same reason: a widget tree
    built at the origin, laid out, flattened onto the board's own op buffer
    (`RND1`), then shifted as a block. Painting it here rather than in
    $(REF systemRender, systems,render) is what keeps that function `@nogc`
    (`DIA5`) — this costs a GC frame only while the pane is up.
    */
    private void paintSettings(in Size viewport) @safe
    {
        if (!world.settingsOpen)
            return;

        const g = paneGeometryFor(viewport);
        settingsPane.ensure(world.settings, g);
        auto tree = settingsPane.buildView();
        auto frames = layout(tree, Constraints(maxW: g.cols));
        const start = frameOps.length;
        buildDisplayListInto(tree, frames, theme.palette, theme.pageFg,
            theme.pageBg, frameOps);
        if (g.x == 0 && g.y == 0)
            return;
        foreach (ref op; frameOps.ops[start .. $])
            op.translate(g.x, g.y);
    }
}

// ---------------------------------------------------------------------------
// Scripted-session tests (`TST1`): no window, no tty. Fine-grained tool /
// capture / render behaviour is pure under `systems.*`; these assert the
// component wires the host through.
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.input : charEvent, keyEvent, Key, Mods, PointerButton;
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

    private Unique!DiagramApp themedApp() @safe
    {
        auto th = appThemeOf(GuiOptions.init);
        // Ensure a non-empty palette even if the options resolve to a
        // syntax-only theme — the render path names slots.
        if (!th.palette.bg[Slot.surface].isSet)
            th.palette = defaultTwoslashPalette(ColorScheme.dark);
        return DiagramApp.create(th);
    }
}

@("diagram.app.quitsOnQ")
@safe
unittest
{
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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

    auto app2Owner = themedApp();
    ref DiagramApp app2() => app2Owner.get();
    auto rec2 = runAppRecorded(app2, RunConfig.init, [
        charEvent('+'),
        charEvent('+'),
        charEvent('0'),
        charEvent('q'),
    ]);
    assert(rec2.quitRequested);
    assert(app2.camera.zoom == 0 && app2.camera.scalePercent == 100);
}

@("diagram.app.theGuidePaintsWhatTheTableSays")
@safe
unittest
{
    // `?` reveals the guide (`LTN`), and what it paints comes from the same
    // table the resolver reads — so a key that works is a key that is listed.
    // The panel's rows sit along the bottom edge, below the board's ops.
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
    auto rec = runAppRecorded(app, RunConfig.init, [charEvent('?')]);

    assert(rec.frames.length == 2);
    assert(app.world.lantern.shown, "the reveal row opened the panel");

    // What the panel paints is what the resolver would answer: the rows come
    // from `bindingsAt` over the same table, so this asserts the tie rather
    // than a hardcoded label. The board's set is taller than the panel's
    // window, so only the first rows are guaranteed painted.
    SharedBuffer!(Binding, guideRowCap) listed;
    bindingsAt(listed, DiagramContext.init);
    assert(listed.length > 0);
    const firstDesc = listed[0].desc;

    // The panel's ops ride the board's own buffer (`RND1`), appended after
    // the frame the render system built.
    bool painted;
    int panelTop = int.max;
    foreach (ref op; app.frameOps[])
    {
        if (op.kind != OpKind.textRun || op.text != firstDesc)
            continue;
        painted = true;
        if (op.rect.y < panelTop)
            panelTop = op.rect.y;
    }
    assert(painted, "the panel lists what the table resolves");
    assert(panelTop > 1, "…and it hugs the bottom edge, not the toolbar");

    // A label edit hides the board's scope, so `?` never reaches the guide:
    // it is text, and it lands in the label (`IXN5`).
    auto typingOwner = themedApp();
    ref DiagramApp typing() => typingOwner.get();
    const e = typing.world.spawn(Rect(2, 2, 6, 3));
    typing.world.beginEdit(e);
    cast(void) runAppRecorded(typing, RunConfig.init, [charEvent('?')]);
    assert(!typing.world.lantern.shown);
    assert(typing.world.editText == "?", "the guide's key typed into the label");
}

@("diagram.app.scriptedSessionMenuGroupLabelConnect")
@safe
unittest
{
    // Series 2 sweep: create two boxes, group via menu, label one, connect.
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
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
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
    const e = app.world.spawn(Rect(2, 2, 6, 3));
    app.world.setLabel(e, "Box");
    auto rec = runAppRecorded(app, RunConfig.init, []);
    assert(app.frameOps.length > 0, "paint rebuilt the op buffer");

    // Slots live on the op buffer (`RND5`); the canvas recorder drops them
    // (it only keeps kind/rect/visual). Assert slots on frameOps, geometry
    // on both.
    bool frameBody, canvasBody, frameLabel;
    foreach (ref op; app.frameOps[])
    {
        if (op.kind == OpKind.fillRect && op.slot == Slot.surface
            && op.rect.width >= 6)
            frameBody = true;
        if (op.kind == OpKind.textRun && op.text == "Box" && op.slot == Slot.code)
            frameLabel = true;
    }
    foreach (ref op; rec.canvas.ops)
        if (op.kind == OpKind.fillRect && op.rect.width >= 6
            && op.rect.height >= 3)
            canvasBody = true;
    assert(frameBody, "frameOps holds the entity body with Slot.surface");
    assert(frameLabel, "frameOps holds the entity label textRun");
    assert(canvasBody, "canvas received the entity body");
}

@("diagram.app.theSettingsPaneOpensEditsTheLiveBoardAndCloses")
@safe
unittest
{
    // The whole `SET` round trip through the real host loop: `,` opens the
    // pane, its keys reach it instead of the board, an edit lands in the
    // running world, and Esc gives the keyboard back.
    import sparkles.ui.components.grid_backdrop : MarkKind;

    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();

    const beforeOrigin = app.camera.origin;
    auto rec = runAppRecorded(app, RunConfig.init, [
        charEvent(','),
        // `d` and `q` are board keys — pan right and quit. Inside the pane
        // they are unbound, and a modal surface spends them (`SET2`).
        charEvent('d'),
        charEvent('q'),
    ]);
    assert(!rec.quitRequested, "`q` did not reach the board");
    assert(app.world.settingsOpen);
    assert(app.camera.origin == beforeOrigin, "`d` did not pan the board");

    // `3` is the dot-paper fixture; it must change the board the render
    // system reads, not a copy (`SET3`).
    cast(void) runAppRecorded(app, RunConfig.init, [charEvent('3')]);
    assert(app.world.gridConfig.minorStyle.markKind == MarkKind.dots);

    cast(void) runAppRecorded(app, RunConfig.init, [keyEvent(Key.escape)]);
    assert(!app.world.settingsOpen, "Esc closed the pane…");

    // …and the board has its keys back: the same `q` now quits.
    auto after = runAppRecorded(app, RunConfig.init, [charEvent('q')]);
    assert(after.quitRequested);
}

@("diagram.app.theSettingsPanePaintsOverTheBoard")
@safe
unittest
{
    // `SET8`: the pane rides the board's own op buffer (`RND1`), appended
    // after the frame the `@nogc` render system built — so z-order is append
    // order and `systemRender` never learned about widgets.
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();

    auto plain = runAppRecorded(app, RunConfig.init, []);
    const boardOps = app.frameOps.length;
    assert(plain.frames.length == 1);

    cast(void) runAppRecorded(app, RunConfig.init, [charEvent(',')]);
    assert(app.world.settingsOpen);
    assert(app.frameOps.length > boardOps, "the pane added ops");

    // The panel's own surface is somewhere inside the viewport, below the
    // toolbar — a modal centred on the screen, not chrome pinned to an edge.
    const g = paneGeometryFor(RecordingHost.init.size);
    bool framed;
    foreach (ref op; app.frameOps[])
        if (op.kind == OpKind.fillRect && op.slot == Slot.surface
            && op.rect.x >= g.x && op.rect.y >= g.y
            && op.rect.width >= g.cols - 4)
            framed = true;
    assert(framed, "the pane's framed surface is on the frame, and centred");
}

@("diagram.app.savingWithoutAPathSaysSoInsteadOfGuessing")
@safe
unittest
{
    // `SET5`: `main` supplies the path. With none, the pane must report that
    // rather than write somewhere the reader did not ask for.
    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
    assert(app.settingsPath.length == 0);

    cast(void) runAppRecorded(app, RunConfig.init, [charEvent(','), charEvent('s')]);
    assert(app.settingsPane.status.length > 0);
    assert(app.world.settingsOpen, "a failed save does not close the pane");
}

@("diagram.app.savingWritesTheSchemaTheConfigFileReads")
@system
unittest
{
    import std.file : exists, rmdirRecurse, tempDir;
    import std.path : buildPath;
    import grid_file : loadGridConfigFile;
    import sparkles.ui.components.grid_backdrop : GridConfig, MarkKind;
    import sparkles.ui.style : Palette;

    const dir = buildPath(tempDir, "diagram-app-save-test");
    scope (exit) if (exists(dir)) rmdirRecurse(dir);

    auto appOwner = themedApp();
    ref DiagramApp app() => appOwner.get();
    app.settingsPath = buildPath(dir, "grid.json");

    // Open, pick the dot-paper fixture, save.
    cast(void) runAppRecorded(app, RunConfig.init, [
        charEvent(','), charEvent('3'), charEvent('s'),
    ]);
    assert(exists(app.settingsPath), app.settingsPane.status);

    // What came out is what `--config-file` puts back in (`GRD8`/`SET5`).
    GridConfig loaded;
    Palette pal;
    string err;
    assert(loadGridConfigFile(app.settingsPath, loaded, pal, err), err);
    assert(loaded.minorStyle.markKind == MarkKind.dots);
    assert(loaded == app.world.gridConfig);
}
