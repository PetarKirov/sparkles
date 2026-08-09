#!/usr/bin/env dub
/+ dub.sdl:
    name "platform_ui_color_scheme_probe"
    targetPath "build"
    platforms "posix"
    dependency "sparkles:base" path="../../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Asking the *terminal* what color scheme it is using.
 *
 * A terminal application has no window-system connection and no desktop
 * session to consult — the only peer that knows what the text will look like is
 * the emulator on the other end of the pty. Two escape sequences ask it, and
 * this program runs both against whatever terminal it is launched in:
 *
 *   1. **`CSI ? 996 n`** — the DEC mode 2031 status query. The terminal replies
 *      `CSI ? 997 ; 1 n` for dark or `CSI ? 997 ; 2 n` for light. This is a
 *      *semantic* answer: the terminal has already decided, usually by following
 *      the OS, and no luminance guessing is involved.
 *   2. **`OSC 11 ; ? ST`** — the background-color query, answered as
 *      `OSC 11 ; rgb:RRRR/GGGG/BBBB ST` with 16-bit-per-channel values. The
 *      caller must classify it itself, which is where the threshold disagreement
 *      that [../../color-derivation/index.md](../../color-derivation/index.md)
 *      measures comes from.
 *
 * It also demonstrates the two hazards the deep-dive documents: the query
 * **must** be timed out (a terminal that does not implement a sequence simply
 * says nothing, and a blocking read hangs forever), and under `tmux` the
 * sequence needs DCS passthrough or it is swallowed.
 *
 * Companion to docs/research/platform-ui-guidelines/terminal/index.md
 *   § "DEC mode 2031" and § "Hazards".
 *
 * Run with: dub run --single color-scheme-probe.d
 *
 * Portability: POSIX only (termios raw mode). When stdin/stdout is not a tty —
 * which is how CI runs it — it prints a `SKIP:` line and exits 0. A terminal
 * that answers neither query is reported as such, not as a failure.
 */
module platform_ui_color_scheme_probe;

import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.termios : ECHO, ICANON, ISIG, TCSAFLUSH, TCSANOW,
    tcgetattr, tcsetattr, termios, VMIN, VTIME;
import core.sys.posix.unistd : read, STDIN_FILENO, STDOUT_FILENO, write;

import std.process : environment;
import std.stdio : writefln, writeln;

import sparkles.base.term_caps : isTerminal, StdStream;

/// How long to wait for a reply before concluding the terminal does not
/// implement the sequence. The deep-dive's recommendation is 100–200 ms: long
/// enough for an ssh round trip, short enough that a non-implementing terminal
/// does not visibly stall startup.
enum replyTimeoutMs = 200;

/// Raw-mode guard: a terminal reply arrives on stdin as ordinary input, so
/// canonical mode (which waits for a newline) and echo (which would paint the
/// reply into the user's scrollback) both have to go.
struct RawMode
{
    private termios original;
    private bool active;

    static RawMode enter() @trusted nothrow @nogc
    {
        RawMode m;
        if (tcgetattr(STDIN_FILENO, &m.original) != 0)
            return m;

        termios raw = m.original;
        raw.c_lflag &= ~(ICANON | ECHO);
        raw.c_cc[VMIN] = 0;
        raw.c_cc[VTIME] = 0;
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0)
            m.active = true;
        return m;
    }

    ~this() @trusted nothrow @nogc
    {
        if (active)
            tcsetattr(STDIN_FILENO, TCSANOW, &original);
    }
}

void emit(scope const(char)[] bytes) @trusted nothrow @nogc
{
    write(STDOUT_FILENO, bytes.ptr, bytes.length);
}

/// Read whatever arrives within `replyTimeoutMs` of *the last* byte seen, so a
/// reply split across packets is still collected whole. Returns the bytes read.
char[] drain(return scope char[] buf) @trusted nothrow @nogc
{
    size_t n;
    while (n < buf.length)
    {
        pollfd pfd;
        pfd.fd = STDIN_FILENO;
        pfd.events = POLLIN;
        // First byte gets the full budget; subsequent bytes a short one, since
        // the reply is already in flight.
        if (poll(&pfd, 1, n == 0 ? replyTimeoutMs : 20) <= 0)
            break;
        const got = read(STDIN_FILENO, buf.ptr + n, buf.length - n);
        if (got <= 0)
            break;
        n += got;
    }
    return buf[0 .. n];
}

/// `tmux` does not forward an unknown query to the outer terminal and does not
/// answer it either, so a bare probe times out. Wrapping it in DCS passthrough
/// (`ESC P tmux; <escaped> ESC \`, with every ESC doubled) hands it through.
/// See the deep-dive § "Hazards — multiplexers".
string wrapForMultiplexer(string seq) @safe
{
    if (environment.get("TMUX") is null)
        return seq;

    string escaped;
    foreach (ch; seq)
        escaped ~= ch == '\x1b' ? "\x1b\x1b" : [ch];
    return "\x1bPtmux;" ~ escaped ~ "\x1b\\";
}

/// Render a byte string with escapes visible, so the report is copy-pasteable.
string visible(scope const(char)[] s) @safe
{
    import std.format : format;

    string out_;
    foreach (ch; s)
    {
        if (ch == '\x1b') out_ ~= "ESC";
        else if (ch == '\a') out_ ~= "BEL";
        else if (ch < 0x20) out_ ~= format!"\\x%02x"(ch);
        else out_ ~= ch;
    }
    return out_;
}

/// Parse `CSI ? 997 ; Ps n`. Returns 1 (dark), 2 (light), or 0 (no answer).
int parseColorScheme(scope const(char)[] reply) @safe
{
    import std.algorithm : canFind;

    if (reply.canFind("997;1"))
        return 1;
    if (reply.canFind("997;2"))
        return 2;
    return 0;
}

/// Parse `OSC 11 ; rgb:RRRR/GGGG/BBBB ST` into 8-bit channels. The channels are
/// 16-bit *hex of variable width* in practice — xterm emits four digits, some
/// terminals two — so each component is scaled by its own digit count rather
/// than assumed to be `/0xffff`.
bool parseOsc11(scope const(char)[] reply, out ubyte r, out ubyte g, out ubyte b) @safe
{
    import std.algorithm : findSplit, startsWith;
    import std.conv : to;

    auto split = reply.findSplit("rgb:");
    if (!split)
        return false;

    auto rest = split[2];
    ubyte[3] chans;
    size_t ci;
    size_t i;
    while (ci < 3 && i <= rest.length)
    {
        size_t start = i;
        while (i < rest.length && isHexDigit(rest[i]))
            i++;
        if (i == start)
            return false;
        const digits = rest[start .. i];
        const value = digits.to!uint(16);
        // Scale from `digits.length` nibbles down to 8 bits.
        const max = (1u << (4 * digits.length)) - 1;
        chans[ci++] = cast(ubyte) ((value * 255 + max / 2) / max);
        if (ci < 3)
        {
            if (i >= rest.length || rest[i] != '/')
                return false;
            i++;
        }
    }
    if (ci != 3)
        return false;
    r = chans[0]; g = chans[1]; b = chans[2];
    return true;
}

bool isHexDigit(char c) @safe pure nothrow @nogc
    => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

void main() @safe
{
    // Both directions must be a terminal: the query goes out on stdout and the
    // reply comes back on stdin. Under CI either one is a pipe.
    if (!isTerminal(StdStream.stdout) || !isTerminal(StdStream.stdin))
    {
        writeln("SKIP: stdin/stdout is not a terminal — nothing to query.");
        return;
    }

    writefln!"TERM=%s  TERM_PROGRAM=%s  TMUX=%s"(
        environment.get("TERM", "(unset)"),
        environment.get("TERM_PROGRAM", "(unset)"),
        environment.get("TMUX") is null ? "no" : "yes (using DCS passthrough)");
    writefln!"COLORFGBG=%s"(environment.get("COLORFGBG", "(unset)"));
    writeln();

    char[256] buf;

    {
        auto raw = RawMode.enter();

        // --- 1. DEC mode 2031 status query -------------------------------
        const dsr = wrapForMultiplexer("\x1b[?996n");
        emit(dsr);
        auto reply = drain(buf[]);
        writefln!"query  CSI ? 996 n   -> %s"(
            reply.length ? visible(reply) : "(no reply within " ~ "200ms)");

        const scheme = parseColorScheme(reply);
        writefln!"       color scheme  -> %s"(
            scheme == 1 ? "dark" : scheme == 2 ? "light" : "unknown (mode 2031 unsupported)");
        writeln();

        // --- 2. OSC 11 background color ----------------------------------
        const osc = wrapForMultiplexer("\x1b]11;?\x1b\\");
        emit(osc);
        reply = drain(buf[]);
        writefln!"query  OSC 11 ; ? ST -> %s"(
            reply.length ? visible(reply) : "(no reply within 200ms)");

        ubyte r, g, b;
        if (parseOsc11(reply, r, g, b))
        {
            import std.format : format;

            const hex = format!"#%02X%02X%02X"(r, g, b);
            // The same Rec. 601 threshold `sparkles.ui.style.schemeForBackground`
            // uses today, reproduced here so the two answers can be compared.
            const luma = (r * 299 + g * 587 + b * 114) / 1000;
            writefln!"       background   -> %s (Rec.601 luma %d ⇒ %s)"(
                hex, luma, luma < 110 ? "dark" : "light");

            if (scheme != 0)
            {
                const inferred = luma < 110 ? 1 : 2;
                writefln!"       agreement    -> %s"(
                    inferred == scheme
                        ? "mode 2031 and the luminance guess agree"
                        : "DISAGREE — trust mode 2031, it is the terminal's own answer");
            }
        }
        else
            writeln("       background   -> unavailable (OSC 11 unsupported or blocked)");
    }

    writeln();
    writeln("Enabling unsolicited notifications (CSI ? 2031 h) makes the terminal");
    writeln("send CSI ? 997 n whenever the scheme changes, so a long-running TUI");
    writeln("never has to poll. Remember CSI ? 2031 l on exit.");
}
