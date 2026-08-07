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
import sparkles.ui_app.host : FrameOps, HostState, isHost, RunConfig,
    withRealSize;
import sparkles.ui_raylib.raylib_canvas : RaylibCanvas;
import sparkles.ui_raylib.events : RaylibEvents;

/// The host an application sees in a window.
struct GuiHost
{
    mixin HostState;

    private GuiSession* session;
    private SmallBuffer!(char, 4096) drawScratch;

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

Returns `false` when the window opened but no font resolved — the caller reports
which family it asked for, since a window painting without a font is a blank one.
*/
bool runGui(alias present, alias handle)(in RunConfig cfg, in GuiRequest req)
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

    while (!session.window.shouldClose && !host.quitRequested)
    {
        // Input first: the frame an application presents should reflect what
        // just happened, not what happened before it.
        events.poll((Event e) { handle(host, withRealSize(e, host.size)); },
            session.cellW, session.cellH);

        if (host.quitRequested)
            break;

        host.beginFrameState();
        present(host);

        // `HST6`: no swap, no clear — the last frame stays up and the loop
        // costs a poll and a pace.
        if (host.frameSkipped)
            continue;

        session.window.beginFrame();
        session.window.resetClip();
        session.window.clear(RgbColor(0, 0, 0));
        auto canvas = host.canvas;
        paint(canvas, host.ops()[]);
        session.window.endFrame();
    }
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
