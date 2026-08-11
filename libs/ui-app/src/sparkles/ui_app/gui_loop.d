/**
The GPU arm of the host (`APP4`, `HST6`, `HST9`).

The mirror of the terminal arm, and different from it in exactly one way that
matters: a window $(B has) a frame clock, so this paces rather than blocks. The
application is asked to present every frame and decides whether anything
changed.

$(B Declining a frame skips the buffer swap, not just the drawing.) That is the
whole point of `HST6`: a terminal emulator with nothing to redraw polls input,
paces to its frame rate and leaves the last frame on screen — swapping an
identically-redrawn buffer would cost the same as drawing it. Beginning and
ending a frame unconditionally would erase the property.

$(B Where a ring is available, event-horizon owns the cadence) (its SPEC
§15.3, the GUI shape): raylib's own pacing is disabled and the loop runs
in the root fiber over a `Ticker` — absolute frame deadlines, missed
frames skipped — parking in the $(B ring) between frames, where any
subprocess, watch, and timer fibers the application spawns run. Raylib is
thereby demoted to render + window + input sampling. Where loop creation
fails, raylib keeps its own pacing — the explicit fallback arm, selected
once and reported on `GuiHost.asyncLoop`.
*/
module sparkles.ui_app.gui_loop;

version (UiAppGui):

import sparkles.base.term_control : PointerShape;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input : Event, InputCapabilities, Mods, mousePointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_setup : GuiRequest, GuiSession, openGuiSession;
import sparkles.ui_app.host : FrameOps, HostState, isHost, noDraw, noSetup,
    PointerUnit, RunConfig, withRealSize;
import sparkles.ui_raylib.raylib_canvas : RaylibCanvas;
import sparkles.ui_raylib.events : RaylibEvents;
import sparkles.ui_raylib.window : Window;

/// The host an application sees in a window.
struct GuiHost
{
    mixin HostState;

    private GuiSession* session;
    private SmallBuffer!(char, 4096) drawScratch;

    /// `true` when the event-horizon arm paces (raylib never sleeps);
    /// `false` on the raylib-paced fallback (no ring available).
    bool asyncLoop;

    private void delegate(void delegate()) _spawnDaemon;

    /**
    Park a background fiber on the loop's own scope (`HST15`): between
    frames the thread parks in the ring, which is where the daemon runs.
    Returns `false` on the raylib-paced fallback (no ring): the component
    keeps its polled path.
    */
    bool spawnDaemon(void delegate() fiberBody) @system
    {
        if (_spawnDaemon is null)
            return false;
        _spawnDaemon(fiberBody);
        return true;
    }

    /// `HST15`: on a paced arm the next frame is already coming, so a wake
    /// asks for nothing — it exists so a component wakes its host without
    /// branching on the target.
    void wake() @safe pure nothrow @nogc {}

    /// The surface, in cells — pixels divided by the loaded cell metrics, so an
    /// application reasons in the same unit on both targets.
    Size size() const @system
        => Size(session.window.width / session.cellW,
                session.window.height / session.cellH);

    /// A window is a mouse target on the desktop and a touch target on a phone;
    /// the difference is not observable until a contact arrives, so the loop
    /// declares it rather than guessing.
    InputCapabilities capabilities;

    /// ditto
    Backend backend() const @safe pure nothrow @nogc => Backend.gui;

    /// Seconds the last frame took — the clock every animation reads.
    float frameSeconds() const @system => session.window.frameSeconds;

    /// The font pixel size, and the errand changing it (`HST14`): reloads the
    /// face set and re-measures the cell metrics, so `size` changes on its
    /// next read. Call from `handle` — it runs outside the frame bracket,
    /// where the reload's texture upload is safe.
    int fontSizePx() const @system => session.fontSizePx;
    /// ditto
    void fontSize(int px) @system => session.setFontSize(px);

    void pointerShape(PointerShape s) @system => session.window.pointerShape(s);

    void clipboard(scope const(char)[] text) @system
    {
        import std.string : toStringz;

        session.window.clipboard(text.toStringz);
    }

    void title(scope const(char)[] t) @system
    {
        import std.string : toStringz;

        session.window.title(t.toStringz);
    }

    /// A window has no out-of-band channel: the terminal's escape sequences
    /// address a terminal. Accepted and dropped so an application does not have
    /// to branch on the target for something the other one needs.
    void writeOutOfBand(scope const(char)[]) @safe pure nothrow @nogc {}

    bool fullscreenSupported() const @system => session.window.fullscreenSupported;
    /// ditto
    void toggleFullscreen() @system => session.window.toggleFullscreen();

    /// The canvas, for an application with a renderer of its own (`HST3`) —
    /// `apps/terminal` paints a VT screen cell by cell and would not survive
    /// being routed through a display list.
    RaylibCanvas canvas() @system
        => RaylibCanvas(&session.fonts, &drawScratch, session.cellW, session.cellH);

    /**
    The window, the `HST3` companion to $(LREF canvas).

    A renderer of its own needs more than a canvas: the pixel size (cells are
    a truncating division of it, so an application positioning chrome to the
    pixel cannot recover it), the scissor, the clear colour, the screenshot.
    Each is a $(B window) operation rather than a drawing one, and inventing a
    host errand per call would only rename them.

    $(B Not the frame bracket.) `beginFrame`/`endFrame` belong to the arm —
    calling them from `present` or the draw phase nests a bracket inside the
    one already open, and `HST6`'s declined frame stops meaning anything.
    */
    ref Window window() @system => session.window;
}

static assert(isHost!GuiHost);

/**
Runs `present`/`handle` in a window until the application quits or the platform
closes it.

`draw` is the post-display-list phase (`HST13`): called $(B inside) the frame
bracket, after the host's operations painted — the only place a canvas call is
valid, which is why an application with a renderer of its own cannot paint from
`present`. A skipped frame skips it with the rest of the bracket.

Returns `false` when the window opened but no font resolved — the caller reports
which family it asked for, since a window painting without a font is a blank one.
*/
bool runGui(alias present, alias handle, alias draw = noDraw,
    alias setup = noSetup)(in RunConfig cfg, in GuiRequest req)
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.interp.immediate : paint;

    GuiSession session;
    if (!openGuiSession(req, session))
        return false;

    GuiHost host;
    host.session = &session;
    host.capabilities = mousePointer;
    // The terminal-grade keyboard, where the application asked for it: the
    // capability declaration IS the switch — RaylibEvents reads it back.
    host.capabilities.keyRelease = cfg.keyRelease;

    // `HST19`: the window exists and the font has settled on a cell size, so
    // an application that lays out before its first frame can now do it.
    setup(host);

    RaylibEvents events;
    events.capabilities = host.capabilities;

    // One frame: sample input, present, swap unless declined (`HST6`).
    void oneFrame()
    {
        // Gesture thresholds are PHYSICAL, so they track the cell size — a
        // pinch or a font-size change moves it, and the recogniser's own
        // defaults (12 px slop, a 16 px row) describe no font we ship. Set
        // per frame, before the drain, because the drain is what advances the
        // recogniser. This is the host's job by construction: `cfg` is public
        // so the side that knows the rendered cell size sets it.
        const slop = session.cellH / 2.0f;
        events.gestures.cfg.slopPx = slop > 8 ? slop : 8;
        events.gestures.cfg.cellH = session.cellH;

        // Input first: the frame an application presents should reflect what
        // just happened, not what happened before it. `HST18`: a 1×1 cell is
        // how "positions in pixels" is spelled — the synthesizer's divisor,
        // set to the identity.
        const unit = cfg.pointerUnit == PointerUnit.pixels
            ? 1 : session.cellW;
        const unitH = cfg.pointerUnit == PointerUnit.pixels
            ? 1 : session.cellH;
        events.poll((Event e) { handle(host, withRealSize(e, host.size)); },
            unit, unitH);
        // `HST17`: the live level, not the last event's — read after the
        // drain, so a frame sees the modifiers it was actually held under.
        host.noteModifiers(events.modifiers);

        if (host.quitRequested)
            return;

        host.beginFrameState();
        present(host);

        // `HST6`: no swap, no clear — the last frame stays up. The window
        // system still gets its input pump (endFrame does it implicitly on
        // the drawing path).
        if (host.frameSkipped)
        {
            session.window.pumpEvents();
            return;
        }

        session.window.beginFrame();
        session.window.resetClip();
        session.window.clear(RgbColor(0, 0, 0));
        auto canvas = host.canvas;
        paint(canvas, host.ops()[]);
        draw(host); // `HST13`: the application's own renderer, inside the bracket
        session.window.endFrame();
    }

    // The event-horizon arm (its SPEC §15.3, the GUI shape): the Ticker owns
    // the cadence; between frames the thread parks in the ring, where the
    // application's async fibers run. UI-sized fiber stacks — frames run
    // arbitrary paint code, and FrameOps-sized stack temporaries appear in
    // debug builds.
    import sparkles.event_horizon.sched : Sched, SchedOptions;

    SchedOptions schedOpts;
    schedOpts.stackSize = 1024 * 1024;
    schedOpts.maxFibers = 64;

    Sched sched;
    if (!Sched.create(sched, schedOpts).hasError)
    {
        scope (exit) sched.destroy();
        host.asyncLoop = true;
        session.window.targetFps(0); // the frame clock owns the cadence

        import core.time : usecs;

        import sparkles.event_horizon.errors : IoError;
        import sparkles.event_horizon.io : Ticker;
        import sparkles.event_horizon.scope_ : withScope;

        const fps = cfg.targetFps > 0 ? cfg.targetFps : 60;
        sched.run(() {
            // The scope is what lets the application park daemons on this
            // loop (`HST15`); its exit reaps them — parked operations
            // cancelled in-ring — before the window closes.
            cast(void) withScope!((ref sc) {
                // `sc` is a `ref` parameter — closures capture the slot,
                // never the referent, so its address goes through a local.
                auto scP = (() @trusted => &sc)();
                host._spawnDaemon = (void delegate() b) { scP.spawnDaemon(b); };
                scope (exit) host._spawnDaemon = null;

                auto ticker = Ticker.start(sched, (1_000_000 / fps).usecs);
                while (!session.window.shouldClose && !host.quitRequested)
                {
                    // Park in the ring until the frame is due: async work
                    // runs here, costing no frames and dropping no input
                    // (HST9).
                    cast(void) ticker.tick(sched);
                    oneFrame();
                }
            }, IoError)(sched);
        });
        return true;
    }

    // The raylib-paced fallback arm: endFrame sleeps to targetFps.
    while (!session.window.shouldClose && !host.quitRequested)
        oneFrame();
    return true;
}

// A template arm is analysed only where it is instantiated, and this package
// has no application — so without this the whole GPU loop could be broken and
// `dub test :ui-app` would still pass.
@("ui_app.gui_loop.instantiates")
@system
unittest
{
    static assert(__traits(compiles, {
        RunConfig cfg;
        GuiRequest req;
        runGui!((ref GuiHost h) { h.ops() ~= DrawOp.init; },
                (ref GuiHost h, in Event e) { h.quit(); })(cfg, req);
    }), "the GPU arm must compile against the host contract");

    static assert(__traits(compiles, (ref GuiHost h) {
        h.pointerShape(PointerShape.grab);
        h.clipboard("copied");
        h.title("a title");
        h.writeOutOfBand("ignored here");
        h.toggleFullscreen();
        h.fontSize(h.fontSizePx + 2);
        auto c = h.canvas;
        cast(void) h.window.width; // the `HST3` window handle
        Mods m = h.modifiers;
    }));

    // The optional `HST15` errands are present on this host, and refused
    // (false) outside a live async arm — the raylib-paced-fallback answer.
    import sparkles.ui_app.host : canSpawnDaemon, canWake;

    static assert(canSpawnDaemon!GuiHost && canWake!GuiHost);
    GuiHost bare;
    assert(!bare.spawnDaemon(delegate void() {}),
        "no ring paces a bare host — the component keeps its polled path");
    bare.wake(); // free on a paced arm
}
