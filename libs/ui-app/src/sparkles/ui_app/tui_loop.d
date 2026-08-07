/**
The terminal arm of the host (`APP4`, `HST6`, `HST9`).

$(B Two gates, and both are load-bearing.) `UiAppTui` says the configuration
brought `sparkles:ui-tui` — the `gui` configuration deliberately does not, so
without it this module cannot even resolve its import there. `Posix` says the
platform has a terminal session at all: `sparkles.ui_tui.session` imports
`Terminal` and `PosixEvents`, which exist only under `version (Posix)`, so
without it the `tui` and `full` configurations fail to type-check on Windows and
Android — the platform hue's APK targets.

Neither implies the other. A `gui`-configured build on Linux has `Posix` and not
`UiAppTui`; a `full` build on Windows has `UiAppTui` and not `Posix`.

$(B The repaint policy is the interesting part.) A terminal has no frame clock,
so this blocks on input rather than spinning: it draws, then waits. Two things
wake it besides input — an application that asked for another frame
($(REF HostState.requestFrame, sparkles,ui_app,host), what an animation needs on
a target that would otherwise sleep), and `RunConfig.idleTimeoutMs`, which is
how background work gets a turn without dropping keystrokes.

$(B Where a ring is available, event-horizon owns the wait) (its SPEC §15.3,
the TUI shape): stdin and `SIGWINCH` become daemon fibers feeding one
channel through `sparkles.ui_app.event_source`, the loop above runs in the
root fiber, and the thread's single blocking point is the ring wait — the
same repaint policy, expressed as a deadline on the channel take, with any
background fibers the application spawns sharing the wait. Where loop
creation fails (a seccomp'd sandbox with no io_uring and no kqueue shim),
the plain blocking arm below is the explicit fallback, selected once and
reported on `TuiHost.asyncLoop` — honest degradation, never a silent fork.
*/
module sparkles.ui_app.tui_loop;

version (UiAppTui):
version (Posix):

import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, InputCapabilities, isEndOfInput;
import sparkles.ui.canvas : DrawOp;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.backend : Backend;
import sparkles.ui_app.host : FrameOps, HostState, isHost, noDraw, RunConfig,
    withRealSize;
import sparkles.ui_tui.session : TerminalRequest, TerminalSession;

/**
The host an application sees on a terminal.

Borrows the session rather than owning it: the session restores the terminal on
scope exit, and a host that could outlive it would be able to paint into a
terminal already handed back.
*/
struct TuiHost
{
    mixin HostState;

    private TerminalSession* session;
    private Size size_;

    /// `true` when the event-horizon arm is driving (one ring wait);
    /// `false` on the blocking fallback (no ring available).
    bool asyncLoop;

    /// The surface, in cells.
    Size size() const @safe pure nothrow @nogc => size_;

    /// A terminal serves hover and one whole-cell pointer, and cannot report a
    /// key release at all (`INP16`).
    static InputCapabilities capabilities() @safe pure nothrow @nogc
        => TerminalSession.capabilities;

    /// ditto
    Backend backend() const @safe pure nothrow @nogc => Backend.tui;

    /// A terminal has no frame clock; an application animating here drives
    /// itself with `requestFrame` and its own timing.
    float frameSeconds() const @safe pure nothrow @nogc => 0;

    /**
    The pointer shape, as OSC 22.

    Out-of-band, like everything below it: these address the terminal itself,
    not the cell surface, so the retained diff must never see them.

    A `final switch` over the enum rather than concatenation, so each sequence
    is a compile-time string and setting a shape allocates nothing — this is
    called once a frame by a host that composes shapes from hover state.
    */
    void pointerShape(PointerShape s) @system
    {
        final switch (s)
        {
            static foreach (m; __traits(allMembers, PointerShape))
            {
                case __traits(getMember, PointerShape, m):
                    session.writeOutOfBand("\x1b]22;"
                        ~ cast(string) __traits(getMember, PointerShape, m)
                        ~ "\x1b\\");
                    return;
            }
        }
    }

    /// The system clipboard, as OSC 52 — the only portable in-band route a
    /// terminal has. Base64 by the protocol, not by choice.
    void clipboard(scope const(char)[] text) @system
    {
        import std.base64 : Base64;
        import sparkles.base.smallbuffer : SmallBuffer;

        SmallBuffer!(char, 512) buf;
        buf ~= "\x1b]52;c;";
        Base64.encode(cast(const(ubyte)[]) text, buf);
        buf ~= "\x07";
        session.writeOutOfBand(buf[]);
    }

    /// The window title, as OSC 2. A terminal emulator shows it as the tab or
    /// window name; one that does not simply ignores the sequence.
    void title(scope const(char)[] t) @system
    {
        import sparkles.base.smallbuffer : SmallBuffer;

        SmallBuffer!(char, 256) buf;
        buf ~= "\x1b]2;";
        buf ~= t;
        buf ~= "\x07";
        session.writeOutOfBand(buf[]);
    }

    /// ditto
    void writeOutOfBand(scope const(char)[] seq) @system => session.writeOutOfBand(seq);

    /// A terminal has no fullscreen of its own — the emulator owns that.
    bool fullscreenSupported() const @safe pure nothrow @nogc => false;
    /// ditto
    void toggleFullscreen() @safe pure nothrow @nogc {}

    /// The cell grid, for an application still painting some chrome by hand.
    ref auto grid() @system => session.grid;

    /// The canvas over that grid (`HST3`) — the terminal counterpart of
    /// `GuiHost.canvas`, so a component that paints through `host.canvas` in
    /// its draw phase (`HST13`) instantiates on both arms instead of needing
    /// a per-target branch.
    auto canvas() @system
    {
        import sparkles.base.term_color : RgbColor;
        import sparkles.ui_tui.grid_canvas : GridCanvas;

        return GridCanvas(&session.grid, RgbColor(0, 0, 0));
    }
}

static assert(isHost!TuiHost);

/**
Runs `present`/`handle` on a terminal until the application quits or input ends.

`draw` is the post-display-list phase (`HST13`): called after the host's
operations painted into the grid and before the cell diff, so an application
painting cells of its own lands on top of the display list and still gets
diffed. A skipped frame skips it too.

Returns `false` when the terminal could not be put into raw mode, which is the
caller's cue to fall back rather than paint into nothing.
*/
bool runTui(alias present, alias handle, alias draw = noDraw)(in RunConfig cfg)
{
    import sparkles.ui.style : defaultTwoslashPalette;
    import sparkles.ui_tui.grid_canvas : paintGrid;
    import sparkles.base.term_color : RgbColor;

    auto session = TerminalSession.open(TerminalRequest(
        mouse: cfg.mouse, motion: cfg.motion));
    if (!session.active)
        return false;

    TuiHost host;
    host.session = &session;

    void frame()
    {
        const sz = session.resizeToTerminal();
        host.size_ = Size(sz.width, sz.height);
        host.beginFrameState();

        present(host);

        // `HST6`: a declined frame presents nothing and leaves the last one up.
        if (host.frameSkipped)
            return;

        paintGrid(session.grid, RgbColor(0, 0, 0), host.ops()[]);
        draw(host); // `HST13`: the application's own cells, before the diff
        session.present();
    }

    frame(); // an application draws before anything happens to it

    // The event-horizon arm (its SPEC §15.3): fibers need UI-sized stacks —
    // a frame runs arbitrary application paint code, and one FrameOps
    // operation can cost a quarter-megabyte stack temporary in a debug
    // build; the 64 KiB I/O-sized default blows instantly. Virtual memory
    // is lazily paged, so 1 MiB × few fibers costs what it touches.
    import sparkles.event_horizon.sched : Sched, SchedOptions;

    SchedOptions schedOpts;
    schedOpts.stackSize = 1024 * 1024;
    schedOpts.maxFibers = 64;

    Sched sched;
    if (!Sched.create(sched, schedOpts).hasError)
    {
        scope (exit) sched.destroy();
        host.asyncLoop = true;

        import core.time : msecs;

        import sparkles.event_horizon.errors : IoError;
        import sparkles.event_horizon.scope_ : withDeadline, withScope;
        import sparkles.ui_app.event_source : EventChannel, pumpTerminalInput;

        // Block SIGWINCH into a signalfd BEFORE any ring wait: resize must
        // be an event, never an EINTR side effect. Linux-only (signalfd);
        // the kqueue platforms apply a resize on the next event until their
        // EVFILT_SIGNAL lowering lands (event-horizon O26's sibling).
        version (linux)
        {
            import sparkles.event_horizon.signals : SignalFd;
            import sparkles.ui_app.event_source : pumpResizeSignals;

            enum int SIGWINCH = 28; // absent from druntime's posix.signal
            SignalFd winch;
            const winchOk = !SignalFd.create(winch, [SIGWINCH]).hasError;
        }

        EventChannel events;
        // `cfg` is a scope parameter — closures must not capture it (a
        // captured parameter slot, not the referent); everything the
        // fibers touch below is a plain local of this frame, which
        // provably outlives them (sched.run blocks here).
        const idleTimeoutMs = cfg.idleTimeoutMs;

        sched.run(() {
            cast(void) withScope!((ref sc) {
                sc.spawnDaemon(() { pumpTerminalInput(sched, events, 0); });
                version (linux)
                    if (winchOk)
                        sc.spawnDaemon(() { pumpResizeSignals(sched, events, winch); });

                while (!host.quitRequested)
                {
                    Event e;
                    bool haveEvent = true;
                    if (host.frameRequested)
                    {
                        // An animation frame: do not block; drain one event
                        // if one is already queued.
                        haveEvent = events.tryTake(e);
                    }
                    else if (idleTimeoutMs >= 0)
                    {
                        // Out-variable shape: the deadline body must not
                        // return an Expected (the scope would double-wrap).
                        Event taken;
                        bool gotOne;
                        auto o = withDeadline!((ref _) {
                            auto t = events.take(sched);
                            if (!t.hasError)
                            {
                                taken = t.value;
                                gotOne = true;
                            }
                        })(sched, idleTimeoutMs.msecs);
                        if (o.hasError)
                        {
                            if (!o.error.isTimeout)
                                return; // teardown
                            haveEvent = false; // idle turn: re-present only
                        }
                        else if (gotOne)
                            e = taken;
                        else
                            return; // channel closed: input ended
                    }
                    else
                    {
                        auto taken = events.take(sched);
                        if (taken.hasError)
                            return; // channel closed / teardown
                        e = taken.value;
                    }

                    if (haveEvent)
                    {
                        if (e.isEndOfInput)
                            return;
                        // `HST7`: the size the application reads is the
                        // one the host has.
                        handle(host, withRealSize(e, host.size));
                    }
                    frame();
                }
            }, IoError)(sched);
            // Scope exit reaps the daemon pumps: their parked reads are
            // cancelled in-ring before the session restores the terminal.
        });
        return true;
    }

    // The blocking fallback arm: same protocol over session reads.
    while (!host.quitRequested)
    {
        // Block unless the application asked for another frame, or the caller
        // wants a turn on an interval — a terminal has no clock of its own, so
        // "wait for something to happen" is the whole scheduling policy.
        const timeout = host.frameRequested ? 0 : cfg.idleTimeoutMs;
        auto e = session.next(timeout);

        if (e.isEndOfInput)
            break;

        // `HST7`: the size an application reads is the one the host has.
        handle(host, withRealSize(e, host.size));
        frame();
    }
    return true;
}

// A template arm is only analysed where it is instantiated, so a broken one
// costs nothing until an application tries to use it — and this package has no
// application. Instantiating it here, without running it, is what makes the
// terminal loop compile-checked by `dub test :ui-app` at all.
@("ui_app.tui_loop.instantiates")
@system
unittest
{
    static assert(__traits(compiles, {
        RunConfig cfg;
        runTui!((ref TuiHost h) { h.ops() ~= DrawOp.init; },
                (ref TuiHost h, in Event e) { h.quit(); })(cfg);
    }), "the terminal arm must compile against the host contract");

    // The errands, likewise: each is a separate template instantiation the
    // frame loop never reaches.
    static assert(__traits(compiles, (ref TuiHost h) {
        h.pointerShape(PointerShape.grab);
        h.clipboard("copied");
        h.title("a title");
        h.writeOutOfBand("\x1b[0m");
        h.toggleFullscreen();
    }));
}
