/**
Presentation hold for DEC private mode 2026, driven by libghostty-vt's render
hold callback (`GHOSTTY_TERMINAL_OPT_RENDER_HOLD`).

The callback fires inside `ghostty_terminal_vt_write` at the byte that begins
a hold, before any text following it in the same write, so the snapshot taken
there is exactly the last finished frame. It fires again when the hold ends:
the program resets the mode, a full reset (RIS), or a resize. The terminal
keeps consuming input and answering queries during the hold. It has no clock,
so the hold's deadline lives here.
*/
module sparkles.terminal_view.synchronized_output;

import core.time : Duration, MonoTime, seconds;

import sparkles.ghostty.c : GhosttyTerminal, GhosttyRenderState,
    ghostty_render_state_update, GHOSTTY_MODE_SYNCHRONIZED_OUTPUT;
import sparkles.ghostty.helpers : terminalModeSet;

/// The hold and its presentation deadline, one per terminal.
struct SynchronizedOutput
{
    private bool active;
    private MonoTime deadline;

    /// A forgotten reset must not freeze the screen indefinitely.
    enum timeout = 1.seconds;

    bool held() const @safe pure nothrow @nogc => active;

    /**
    A hold begins (the render hold callback with `held` true): freeze
    `snapshot` at the terminal's current, complete frame. The library pairs
    each begin with an end, so a begin while held cannot happen; it is
    ignored rather than extending the deadline.
    */
    bool begin(GhosttyTerminal terminal, GhosttyRenderState snapshot,
        MonoTime now = MonoTime.init) @system nothrow @nogc
    {
        if (active)
            return false;
        ghostty_render_state_update(snapshot, terminal);
        active = true;
        // Ordinary mode traffic must not pay for a clock read.
        deadline = (now == MonoTime.init ? MonoTime.currTime : now) + timeout;
        return true;
    }

    /// The hold ends (the render hold callback with `held` false).
    void end() @safe pure nothrow @nogc
    {
        active = false;
    }

    /// Time until a held frame is forced out; an idle terminal needs no wake.
    Duration remaining(MonoTime now = MonoTime.currTime) const @safe nothrow @nogc
    {
        if (!active)
            return Duration.max;
        return now < deadline ? deadline - now : Duration.zero;
    }

    /**
    EOF and timeout clear both our gate and the reported terminal mode.
    Setting the mode through the API never invokes the render hold callback,
    so the gate is cleared here.
    */
    bool release(GhosttyTerminal terminal) @system nothrow @nogc
    {
        if (!active)
            return false;
        terminalModeSet(terminal, GHOSTTY_MODE_SYNCHRONIZED_OUTPUT, false);
        active = false;
        return true;
    }

    bool releaseExpired(GhosttyTerminal terminal,
        MonoTime now = MonoTime.currTime) @system nothrow @nogc
    {
        return active && now >= deadline && release(terminal);
    }
}

@("terminal_view.synchronized_output.timeoutClearsTheReportedMode")
@system unittest
{
    import core.time : msecs;
    import sparkles.ghostty.c : GhosttyTerminalOption, ghostty_terminal_free,
        ghostty_terminal_set, ghostty_terminal_vt_write, ghostty_render_state_new,
        ghostty_render_state_free, GHOSTTY_TERMINAL_OPT_USERDATA,
        GHOSTTY_TERMINAL_OPT_RENDER_HOLD;
    import sparkles.ghostty.helpers : newTerminal, setEffect, terminalModeGet;

    static struct Fixture
    {
        SynchronizedOutput output;
        GhosttyRenderState snapshot;
        MonoTime now;
    }
    static extern (C) void onHold(GhosttyTerminal t, void* userdata, bool held) nothrow @nogc
    {
        auto f = cast(Fixture*) userdata;
        if (held)
            f.output.begin(t, f.snapshot, f.now);
        else
            f.output.end();
    }

    GhosttyTerminal terminal;
    newTerminal(&terminal, 8, 2);
    scope (exit) ghostty_terminal_free(terminal);
    Fixture f;
    ghostty_render_state_new(null, &f.snapshot);
    scope (exit) ghostty_render_state_free(f.snapshot);
    ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, &f);
    terminal.setEffect!GHOSTTY_TERMINAL_OPT_RENDER_HOLD(&onHold);
    void feed(string bytes)
        => ghostty_terminal_vt_write(terminal, cast(const(ubyte)*) bytes.ptr, bytes.length);

    f.now = MonoTime.currTime;
    const now = f.now;
    assert(f.output.remaining(now) == Duration.max);
    feed("\x1b[?2026h");
    assert(f.output.held);
    assert(!f.output.releaseExpired(terminal, now + 999.msecs));
    assert(f.output.remaining(now + 999.msecs) == 1.msecs);
    // Another begin must not indefinitely extend a broken frame.
    f.now = now + 999.msecs;
    feed("\x1b[?2026h");
    assert(f.output.releaseExpired(terminal, now + 1.seconds));
    bool enabled = true;
    terminalModeGet(terminal, GHOSTTY_MODE_SYNCHRONIZED_OUTPUT, &enabled);
    assert(!enabled && !f.output.held);
    assert(f.output.remaining(now + 1.seconds) == Duration.max);
    f.now = now + 2.seconds;
    feed("\x1b[?2026h");
    assert(f.output.held, "timeout does not disable later synchronized frames");
    feed("\x1b[?2026l");
    assert(!f.output.held, "the program's reset ends the hold");
}
