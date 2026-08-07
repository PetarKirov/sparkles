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
import sparkles.input : Event, InputCapabilities, mousePointer;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.gui_setup : GuiRequest, GuiSession, openGuiSession;
import sparkles.ui_app.host : FrameOps, HostState, isHost, noDraw, RunConfig,
    withRealSize;
import sparkles.ui_raylib.raylib_canvas : RaylibCanvas;
import sparkles.ui_raylib.events : RaylibEvents;

/// The host an application sees in a window.
struct GuiHost
{
    mixin HostState;

    private GuiSession* session;
    private SmallBuffer!(char, 4096) drawScratch;

    /// `true` when the event-horizon arm paces (raylib never sleeps);
    /// `false` on the raylib-paced fallback (no ring available).
    bool asyncLoop;

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
bool runGui(alias present, alias handle, alias draw = noDraw)(
    in RunConfig cfg, in GuiRequest req)
{
    import sparkles.base.term_color : RgbColor;
    import sparkles.ui.interp.immediate : paint;

    GuiSession session;
    if (!openGuiSession(req, session))
        return false;

    GuiHost host;
    host.session = &session;
    host.capabilities = mousePointer;

    RaylibEvents events;
    events.capabilities = host.capabilities;

    // One frame: sample input, present, swap unless declined (`HST6`).
    void oneFrame()
    {
        // Input first: the frame an application presents should reflect what
        // just happened, not what happened before it.
        events.poll((Event e) { handle(host, withRealSize(e, host.size)); },
            session.cellW, session.cellH);

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

        import sparkles.event_horizon.io : Ticker;

        const fps = cfg.targetFps > 0 ? cfg.targetFps : 60;
        sched.run(() {
            auto ticker = Ticker.start(sched, (1_000_000 / fps).usecs);
            while (!session.window.shouldClose && !host.quitRequested)
            {
                // Park in the ring until the frame is due: async work runs
                // here, costing no frames and dropping no input (HST9).
                cast(void) ticker.tick(sched);
                oneFrame();
            }
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
        auto c = h.canvas;
    }));
}
