/**
The entry point: pick a backend, open it, run the loop (`HST1`, `BKD5`).

An application calls $(LREF run) and never names a canvas, a window, a terminal
or an event source. Which arm it lands on is the `BKD` decision; whether that arm
exists in this build is a configuration question, and the two are resolved
together here.

$(B The fallback goes both ways.) A build without the GPU arm falls to the
terminal, and a platform without the terminal arm — Windows, Android — falls to
the GPU. Only when neither exists does this report a failure, and it says which
sink it wanted rather than opening nothing.
*/
module sparkles.ui_app.run;

import sparkles.ui_app.backend : Backend, BackendPolicy, isInteractive,
    pickBackend, platformForcedBackend;
import sparkles.ui_app.host : RunConfig;

/// Why a run did not happen. `ok` is the only value that means a loop ran.
enum RunOutcome : ubyte
{
    ok,             /// the loop ran and returned
    notInteractive, /// the chosen sink is static — the application renders it
    noBackend,      /// neither arm is available in this build on this platform
    openFailed,     /// the arm was there but would not open
}

/// The backends this build actually carries — what `BKD5` falls back across.
struct AvailableArms
{
    bool gui; ///
    bool tui; ///

    /// Whether anything interactive can be opened at all.
    bool any() const @safe pure nothrow @nogc => gui || tui;
}

/// The arms compiled into this build, on this platform.
AvailableArms compiledArms() @safe pure nothrow @nogc
{
    AvailableArms a;
    version (UiAppGui)
        a.gui = true;
    // Both gates, matching `tui_loop`: the configuration must have brought
    // `sparkles:ui-tui`, AND the platform must have a terminal session.
    version (UiAppTui)
    {
        version (Posix)
        {
            version (Android) {}
            else
                a.tui = true;
        }
    }
    return a;
}

/**
Resolves which backend to actually open.

Separated from $(LREF run) and pure, so the fallback — the part with the
interesting edge cases — is a table of unit tests rather than something only
observable by building three configurations on three platforms.

Params:
    wanted = what the decision (`pickBackend`) chose
    arms = what this build carries
*/
Backend resolveArm(Backend wanted, in AvailableArms arms, out RunOutcome outcome)
    @safe pure nothrow @nogc
{
    outcome = RunOutcome.ok;

    if (!wanted.isInteractive)
    {
        // `html`/`ansi` are the application's to render; a loop has nothing to
        // drive. Reported rather than silently substituted, because a run that
        // asked for HTML and got a window would be surprising in both places.
        outcome = RunOutcome.notInteractive;
        return wanted;
    }

    if (wanted == Backend.gui && arms.gui)
        return Backend.gui;
    if (wanted == Backend.tui && arms.tui)
        return Backend.tui;

    // The other arm, if there is one — a GUI-less build falls to the terminal,
    // and a terminal-less platform falls to the window.
    if (arms.gui)
        return Backend.gui;
    if (arms.tui)
        return Backend.tui;

    outcome = RunOutcome.noBackend;
    return wanted;
}

/**
Opens a backend and runs the frame loop.

`present` builds each frame and `handle` receives each event; both take
`ref Host`, whose concrete type differs per arm and satisfies
$(REF isHost, sparkles,ui_app,host).

$(B The callbacks are `alias` parameters, not values,) because the two arms hand
back $(I different host types) and one application writes its loop once. An
untyped lambda passed by value has no type to deduce — `run(cfg, policy, (ref h)
{ … })` cannot compile — while the same lambda passed by alias is instantiated
against whichever host the chosen arm provides. It reads like any other D
predicate: `run!(present, handle)(cfg, policy)`.

Params:
    present = called to build a frame, as `(ref host)`
    handle = called per event, as `(ref host, in Event)`
    cfg = the run configuration, including the window/font request
    policy = the backend decision's inputs. Its `guiCompiledIn` is overwritten
        with the truth, so a caller cannot accidentally claim an arm this build
        does not carry.
*/
RunOutcome run(alias present, alias handle)(in RunConfig cfg, BackendPolicy policy)
{
    const arms = compiledArms();
    policy.guiCompiledIn = arms.gui;

    Backend wanted;
    if (!platformForcedBackend(wanted))
        wanted = pickBackend(policy);

    RunOutcome outcome;
    const arm = resolveArm(wanted, arms, outcome);
    if (outcome != RunOutcome.ok)
        return outcome;

    final switch (arm)
    {
        case Backend.gui:
            version (UiAppGui)
            {
                import sparkles.ui_app.gui_loop : runGui;
                import sparkles.ui_app.gui_setup : GuiRequest;
                import sparkles.ui_app.gui_options : fontRequestOf, windowCellsOf;

                GuiRequest req;
                req.title = cfg.title;
                req.font = fontRequestOf(cfg.gui);
                req.cells = windowCellsOf(cfg.gui);
                req.fontSizePoints = cfg.gui.fontSize;
                req.targetFps = cfg.targetFps;

                return runGui!(present, handle)(cfg, req)
                    ? RunOutcome.ok : RunOutcome.openFailed;
            }
            else
                return RunOutcome.noBackend;

        case Backend.tui:
            static if (__traits(compiles, { import sparkles.ui_app.tui_loop; }))
            {
                version (UiAppTui)
                {
                    version (Posix)
                    {
                        version (Android)
                            return RunOutcome.noBackend;
                        else
                        {
                            import sparkles.ui_app.tui_loop : runTui;

                            return runTui!(present, handle)(cfg)
                                ? RunOutcome.ok : RunOutcome.openFailed;
                        }
                    }
                    else
                        return RunOutcome.noBackend;
                }
                else
                    return RunOutcome.noBackend;
            }
            else
                return RunOutcome.noBackend;

        case Backend.html:
        case Backend.ansi:
            return RunOutcome.notInteractive;
    }
}

// ---------------------------------------------------------------------------
// Tests — the fallback matrix, with no arm actually opened.
// ---------------------------------------------------------------------------

@("ui_app.run.resolveArmPrefersWhatWasChosen")
@safe pure nothrow @nogc
unittest
{
    enum both = AvailableArms(gui: true, tui: true);
    RunOutcome o;

    assert(resolveArm(Backend.gui, both, o) == Backend.gui && o == RunOutcome.ok);
    assert(resolveArm(Backend.tui, both, o) == Backend.tui && o == RunOutcome.ok);
}

@("ui_app.run.resolveArmFallsBackBothWays")
@safe pure nothrow @nogc
unittest
{
    RunOutcome o;

    // A build without the GPU arm runs the terminal — the `-c tui` case, and
    // what a headless install gets.
    enum tuiOnly = AvailableArms(gui: false, tui: true);
    assert(resolveArm(Backend.gui, tuiOnly, o) == Backend.tui && o == RunOutcome.ok);

    // A platform without the terminal arm runs the window. This is the
    // direction the plan originally missed: Android and Windows have no
    // `TerminalSession` at all, so "fall back to the terminal" is not a
    // universal answer.
    enum guiOnly = AvailableArms(gui: true, tui: false);
    assert(resolveArm(Backend.tui, guiOnly, o) == Backend.gui && o == RunOutcome.ok);

    // Neither: reported, not papered over.
    enum none = AvailableArms.init;
    assert(!none.any);
    resolveArm(Backend.gui, none, o);
    assert(o == RunOutcome.noBackend);
}

@("ui_app.run.staticSinksAreHandedBack")
@safe pure nothrow @nogc
unittest
{
    // `html`/`ansi` are the application's to render. A loop cannot drive them,
    // and substituting a window for a requested HTML render would surprise in
    // both directions — so the outcome says so and the backend is unchanged.
    enum both = AvailableArms(gui: true, tui: true);
    RunOutcome o;

    assert(resolveArm(Backend.html, both, o) == Backend.html);
    assert(o == RunOutcome.notInteractive);

    assert(resolveArm(Backend.ansi, both, o) == Backend.ansi);
    assert(o == RunOutcome.notInteractive);
}

@("ui_app.run.compiledArmsMatchesThisBuild")
@safe pure nothrow @nogc
unittest
{
    const a = compiledArms();

    // The unittest configuration takes the widest closure, so both arms are
    // here — which is what lets the recording target be checked against them.
    version (UiAppGui)
        assert(a.gui);
    else
        assert(!a.gui);

    version (UiAppTui)
    {
        version (Android)
            assert(!a.tui, "the surface IS the application; there is no terminal");
        else version (Posix)
            assert(a.tui);
        else
            assert(!a.tui, "the terminal session type is Posix-only");
    }
    else
        assert(!a.tui, "this configuration did not bring sparkles:ui-tui");
}

@("ui_app.run.instantiates")
@system
unittest
{
    import sparkles.input : Event;

    // `run` dispatches to arms that are themselves templates, so nothing here
    // is analysed until it is instantiated. Both host types are reachable from
    // one call site only through the version-gated branches, which is exactly
    // what this checks.
    // One loop, both arms. The `final switch` in `run` compiles every branch,
    // so this instantiates the callbacks against BOTH host types — which is
    // the property that makes "an application never names a canvas" true
    // rather than aspirational.
    static assert(__traits(compiles, {
        RunConfig cfg;
        BackendPolicy policy;
        run!(
            (ref h) { h.requestFrame(); },
            (ref h, in Event e) { h.quit(); },
        )(cfg, policy);
    }), "run must compile against both arms");
}
