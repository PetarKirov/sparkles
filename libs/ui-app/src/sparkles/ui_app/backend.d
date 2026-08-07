/**
Which backend an application opens, and why (`BKD`).

Three inputs decide it — what the user asked for, what was compiled in, and what
the environment offers — and until now every application read all three itself.
`apps/hue` had the only complete answer, including the Android rule, as a
private function nobody else could call.

$(B The decision is pure and the probes are not.) `pickBackend` reads a
$(LREF BackendPolicy) and nothing else: no environment, no tty, no window. That
is what makes the whole matrix — flags × tty × display × compiled-in — a table
of unit tests rather than something only observable by running an application on
a machine configured just so. $(LREF displayAvailable) does the impure half, and
a caller composes them.
*/
module sparkles.ui_app.backend;

@safe:

/**
The sink an application renders into — one vocabulary, four members.

`html` and `ansi` are here because they are choices a user makes with the same
flags, not because this package drives them: `sparkles:ui` already has an HTML
target (`TGT4`) and a non-interactive ANSI sink, and an application that had to
keep its own enum for those would be back to two vocabularies that disagree.
$(LREF isInteractive) is the line between what a host loop can open and what it
must hand back.
*/
enum Backend : ubyte
{
    gui,  /// a window
    tui,  /// the interactive terminal (alternate screen)
    html, /// static HTML
    ansi, /// static ANSI on a stream
}

/// Whether `b` is a live target a frame loop can drive, rather than a static
/// sink the application renders once and writes out.
bool isInteractive(Backend b) pure nothrow @nogc
    => b == Backend.gui || b == Backend.tui;

/**
Everything the decision reads, gathered by the caller.

Injected rather than probed so `pickBackend` stays pure. The defaults describe
the least capable environment — no flags, nothing compiled in, no tty, no
display — so a policy built field by field cannot accidentally claim a
capability it did not check.
*/
struct BackendPolicy
{
    // What the user asked for.
    bool forceGui;   /// `--gui`
    bool forceNoGui; /// `--no-gui`
    bool forceTui;   /// `--tui` (an alias for `--no-gui`)
    bool forceHtml;  /// `--html`

    /// Whether this build has the GPU backend at all (`version (UiAppGui)`).
    bool guiCompiledIn;

    bool stdinTty;  /// stdin is a terminal
    bool stdoutTty; /// stdout is a terminal

    /// A graphical display appears to exist — see $(LREF displayAvailable).
    bool displayPresent;
}

/**
Picks the sink.

Explicit flags win, then autodetection. The rules are `apps/hue`'s, preserved:

$(LIST
    * `--gui` wins $(B even without GPU support). The sink reports that problem
        itself, with the name of the thing that is missing; a picker that
        quietly chose something else would answer a question the user did not
        ask.
    * `--html` selects `html`; `--no-gui`/`--tui` force the terminal.
    * Otherwise: the GUI when it is compiled in $(I and) stdout is a tty
        $(I and) a display exists; else the interactive terminal when stdin and
        stdout are both ttys; else `ansi`.
)

The stdout-tty condition on the GUI is not obvious and is deliberate: a piped
run is asking for output on that pipe, so opening a window would strand it.
*/
Backend pickBackend(in BackendPolicy p) pure nothrow @nogc
{
    if (p.forceGui)
        return Backend.gui;
    if (p.forceHtml)
        return Backend.html;
    if (!p.forceNoGui && !p.forceTui
        && p.guiCompiledIn && p.stdoutTty && p.displayPresent)
        return Backend.gui;
    if (p.stdinTty && p.stdoutTty)
        return Backend.tui;
    return Backend.ansi;
}

/**
Whether a graphical display appears to exist.

The impure half, and the reason it is a separate function: `pickBackend` above
stays a pure table, and this is where the environment — and its lies — are
dealt with. See $(MREF sparkles,ui_app,display) for what each platform actually
asks, and $(REF probeDisplay, sparkles,ui_app,display) when the answer to
$(I which) display system matters.

A false negative costs only a fallback to the terminal, and `--gui` overrides
the question entirely, so this is allowed to be a heuristic.
*/
public import sparkles.ui_app.display : displayAvailable;

/**
The platform's own answer, where it has one.

$(B Android is not a display question.) There the surface $(I is) the
application: no tty, no argv, no `$DISPLAY`. The heuristic above cannot stand in
for that — `stdinTty`, `stdoutTty` and `displayPresent` are all false on a
`NativeActivity`, so the general rules would answer `ansi`, which is meaningless
when nothing can read a stream. This states the process model instead, and it is
the reason the fact belongs to the host rather than to one application's private
picker.

Returns: the forced backend, or `Backend.init` alongside `false` when this
    platform leaves the choice to $(LREF pickBackend).
*/
bool platformForcedBackend(out Backend forced) pure nothrow @nogc
{
    version (Android)
    {
        forced = Backend.gui;
        return true;
    }
    else
        return false;
}

// ---------------------------------------------------------------------------
// Tests — the whole matrix, with no tty, no display and no window in sight.
// ---------------------------------------------------------------------------

@("ui_app.backend.explicitFlagsWin")
@safe pure nothrow @nogc
unittest
{
    // `--gui` is honoured even where the backend was never compiled in. The
    // sink then reports what is missing, by name; silently opening a terminal
    // would answer a question the user did not ask.
    assert(pickBackend(BackendPolicy(forceGui: true)) == Backend.gui);
    assert(pickBackend(BackendPolicy(forceGui: true, guiCompiledIn: false))
        == Backend.gui);

    assert(pickBackend(BackendPolicy(forceHtml: true)) == Backend.html);

    // Forcing the terminal beats every autodetection input.
    enum rich = BackendPolicy(guiCompiledIn: true, stdinTty: true,
        stdoutTty: true, displayPresent: true);
    auto noGui = rich;
    noGui.forceNoGui = true;
    assert(pickBackend(noGui) == Backend.tui);

    auto tui = rich;
    tui.forceTui = true;
    assert(pickBackend(tui) == Backend.tui);

    // `--gui` outranks `--no-gui`: the affirmative flag is the more specific
    // request, and hue resolved the conflict this way.
    auto both = rich;
    both.forceGui = true;
    both.forceNoGui = true;
    assert(pickBackend(both) == Backend.gui);
}

@("ui_app.backend.autodetection")
@safe pure nothrow @nogc
unittest
{
    // Everything present: the window.
    assert(pickBackend(BackendPolicy(guiCompiledIn: true, stdinTty: true,
        stdoutTty: true, displayPresent: true)) == Backend.gui);

    // Each of the three GUI conditions is load-bearing on its own.
    assert(pickBackend(BackendPolicy(guiCompiledIn: false, stdinTty: true,
        stdoutTty: true, displayPresent: true)) == Backend.tui);
    assert(pickBackend(BackendPolicy(guiCompiledIn: true, stdinTty: true,
        stdoutTty: true, displayPresent: false)) == Backend.tui);

    // A piped stdout with a display present still does NOT open a window: the
    // run is asking for output on that pipe, and a window would strand it.
    assert(pickBackend(BackendPolicy(guiCompiledIn: true, stdinTty: true,
        stdoutTty: false, displayPresent: true)) == Backend.ansi);

    // The interactive terminal needs BOTH ends to be a tty — a piped stdin is
    // a script driving the tool, not a person.
    assert(pickBackend(BackendPolicy(stdinTty: false, stdoutTty: true))
        == Backend.ansi);
    assert(pickBackend(BackendPolicy(stdinTty: true, stdoutTty: true))
        == Backend.tui);

    // Nothing at all: a stream.
    assert(pickBackend(BackendPolicy.init) == Backend.ansi);
}

@("ui_app.backend.interactiveSplit")
@safe pure nothrow @nogc
unittest
{
    // The line a host loop cares about: two of these it can open and drive,
    // two it must hand back for the application to render once.
    assert(Backend.gui.isInteractive && Backend.tui.isInteractive);
    assert(!Backend.html.isInteractive && !Backend.ansi.isInteractive);
}

@("ui_app.backend.platformForcedBackend")
@safe pure nothrow @nogc
unittest
{
    Backend forced;
    const isForced = platformForcedBackend(forced);

    version (Android)
    {
        // The surface IS the application: no tty, no argv, no display, and
        // the general rules would answer `ansi` — a stream nothing can read.
        assert(isForced && forced == Backend.gui);
    }
    else
    {
        // Everywhere else the choice is `pickBackend`'s.
        assert(!isForced);

        // And on those platforms an Android-shaped policy — nothing detected —
        // is exactly the case that would answer `ansi`, which is why the rule
        // above cannot be expressed as a heuristic.
        assert(pickBackend(BackendPolicy(guiCompiledIn: true)) == Backend.ansi);
    }
}
