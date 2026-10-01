/**
Presentation hold for DEC private mode 2026 on the pinned libghostty-vt ABI.

The terminal keeps consuming input and answering queries during a hold. Its C
render snapshot API does not implement the hold itself, so the feed loop splits
at possible mode transitions and freezes the snapshot at the begin byte, before
any following text. Checking only after a pty read loses that distinction.
*/
module sparkles.terminal_view.synchronized_output;

import core.time : Duration, MonoTime, seconds;

import sparkles.ghostty.c : GhosttyTerminal, GhosttyRenderState,
    ghostty_terminal_mode_get, ghostty_terminal_mode_set,
    ghostty_render_state_update, GHOSTTY_MODE_SYNC_OUTPUT;

/// Internal stream scanner and presentation deadline, one per terminal.
struct SynchronizedOutput
{
    private enum ScanState : ubyte { ground, escape, csi, string_ }
    private ScanState state;
    private bool osc;
    private bool active;
    private MonoTime deadline;

    /// A forgotten reset must not freeze the screen indefinitely.
    enum timeout = 1.seconds;

    bool held() const @safe pure nothrow @nogc => active;

    /// Printable ASCII cannot change these scanner states.
    package bool skipsPrintable() const @safe pure nothrow @nogc
        => state == ScanState.ground || state == ScanState.string_;

    /**
    True when the current byte could change mode 2026. The caller first feeds
    through this byte, then calls `observe`, before feeding any following bytes.
    Ghostty alone interprets parameters, private/ANSI modes and saved modes.
    */
    bool scanByte(char b) @safe pure nothrow @nogc
    {
        if (b == '\x18' || b == '\x1a')
        {
            state = ScanState.ground;
            return false;
        }
        if (b == '\x1b')
        {
            // ESC terminates control strings too; the following byte starts
            // a new escape (including the usual ST backslash).
            state = ScanState.escape;
            return false;
        }
        // Ghostty decodes UTF-8 in ground and treats high OSC bytes as
        // payload, but recognizes C1 transitions in its other parser states.
        if (state != ScanState.ground && !(state == ScanState.string_ && osc)
            && b >= '\x80' && b <= '\x9f')
        {
            switch (b)
            {
                case '\x9b':
                    state = ScanState.csi;
                    break;
                case '\x90':
                case '\x98':
                case '\x9d':
                case '\x9e':
                case '\x9f':
                    state = ScanState.string_;
                    osc = b == '\x9d';
                    break;
                default:
                    state = ScanState.ground;
                    break;
            }
            return false;
        }
        final switch (state)
        {
            case ScanState.ground:
                return false;
            case ScanState.escape:
                if (b < ' ' || b == '\x7f')
                    return false;
                switch (b)
                {
                    case '[':
                        state = ScanState.csi;
                        return false;
                    case ']':
                    case 'P':
                    case 'X':
                    case '^':
                    case '_':
                        state = ScanState.string_;
                        osc = b == ']';
                        return false;
                    default:
                        if (b >= '0' && b <= '~')
                        {
                            state = ScanState.ground;
                            return b == 'c'; // RIS
                        }
                        return false;
                }
            case ScanState.csi:
                if (b >= '@' && b <= '~')
                {
                    state = ScanState.ground;
                    return b == 'h' || b == 'l' || b == 'r'
                        || b == 'p'; // set/reset/restore modes, DECSTR
                }
                return false;
            case ScanState.string_:
                if (osc && b == '\x07')
                    state = ScanState.ground;
                return false;
        }
    }

    /// Returns true only when a new hold captured a pre-update snapshot.
    bool observe(GhosttyTerminal terminal, GhosttyRenderState snapshot,
        MonoTime now = MonoTime.init) @system nothrow @nogc
    {
        bool enabled;
        ghostty_terminal_mode_get(terminal, GHOSTTY_MODE_SYNC_OUTPUT, &enabled);
        if (!enabled)
        {
            active = false;
            return false;
        }
        if (active)
            return false;
        ghostty_render_state_update(snapshot, terminal);
        active = true;
        // Ordinary mode traffic must not pay for a clock read.
        deadline = (now == MonoTime.init ? MonoTime.currTime : now) + timeout;
        return true;
    }

    /// Time until a held frame is forced out; an idle terminal needs no wake.
    Duration remaining(MonoTime now = MonoTime.currTime) const @safe nothrow @nogc
    {
        if (!active)
            return Duration.max;
        return now < deadline ? deadline - now : Duration.zero;
    }

    /// EOF and timeout clear both our gate and the reported terminal mode.
    bool release(GhosttyTerminal terminal) @system nothrow @nogc
    {
        if (!active)
            return false;
        ghostty_terminal_mode_set(terminal, GHOSTTY_MODE_SYNC_OUTPUT, false);
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
    import sparkles.ghostty.c : GhosttyTerminalOptions, ghostty_terminal_new,
        ghostty_terminal_free, ghostty_render_state_new, ghostty_render_state_free;

    GhosttyTerminal terminal;
    GhosttyTerminalOptions options = { cols: 8, rows: 2 };
    ghostty_terminal_new(null, &terminal, options);
    scope (exit) ghostty_terminal_free(terminal);
    GhosttyRenderState snapshot;
    ghostty_render_state_new(null, &snapshot);
    scope (exit) ghostty_render_state_free(snapshot);

    SynchronizedOutput output;
    const now = MonoTime.currTime;
    assert(output.remaining(now) == Duration.max);
    ghostty_terminal_mode_set(terminal, GHOSTTY_MODE_SYNC_OUTPUT, true);
    assert(output.observe(terminal, snapshot, now));
    assert(!output.releaseExpired(terminal, now + 999.msecs));
    assert(output.held && output.remaining(now + 999.msecs) == 1.msecs);
    // Another mode command must not indefinitely extend a broken frame.
    assert(!output.observe(terminal, snapshot, now + 999.msecs));
    assert(output.releaseExpired(terminal, now + 1.seconds));
    bool enabled = true;
    ghostty_terminal_mode_get(terminal, GHOSTTY_MODE_SYNC_OUTPUT, &enabled);
    assert(!enabled && !output.held);
    assert(output.remaining(now + 1.seconds) == Duration.max);
    ghostty_terminal_mode_set(terminal, GHOSTTY_MODE_SYNC_OUTPUT, true);
    assert(output.observe(terminal, snapshot, now + 2.seconds));
    assert(output.held, "timeout does not disable later synchronized frames");
}
