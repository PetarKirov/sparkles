#!/usr/bin/env dub
/+ dub.sdl:
    name "tui_query_probe"
    dependency "sparkles:base" path="../../../.."
    dependency "sparkles:core-cli" path="../../../.."
    platforms "posix"
    targetPath "build"
+/
/**
 * Empirical terminal-capability probe: asks the attached terminal what it can
 * do instead of guessing from the environment.
 *
 * Sends one batched write of capability queries — XTVERSION, the kitty
 * keyboard query, `DECRQM` for DEC private modes 2004/2026/2027/2031/2048,
 * `XTGETTCAP` for `RGB`/`Tc`/`Su`, OSC 10/11 fg/bg color, the kitty graphics
 * query, and secondary DA — fenced by a trailing primary DA (`CSI c`), which
 * every VT100 descendant answers. Because terminals answer queries in order,
 * the DA1 reply proves every earlier query has either answered or never will;
 * a wall-clock deadline (default 1000 ms, `--timeout`) covers terminals that
 * answer nothing at all.
 *
 * Alongside the query results it prints the environment layer (`TERM`,
 * `COLORTERM`, `TERM_PROGRAM`, `NO_COLOR`, multiplexer variables, locale) and
 * the env-derived `detectTermCaps()` snapshot, so the "guess" and the
 * "answer" can be compared side by side.
 *
 * Companion to `docs/research/tui-libraries/capability-detection-case-study.md`
 * §"Appendix: empirical response matrix" — `--markdown` emits one matrix row
 * ready to paste there. Run it inside each terminal of interest:
 *
 *     dub run --single query-probe.d -- --markdown
 *
 * Flags: `--markdown` (matrix row), `--name NAME` (row label), `--timeout MS`
 * (deadline, default 1000), `--no-graphics` (skip the kitty graphics APC
 * query — a handful of legacy parsers print APC payloads instead of consuming
 * them), `--raw` (append the raw response buffer, escapes visualized), and
 * `--out FILE` (write the report to a file; queries still go through the
 * terminal, which lets a headless harness collect rows via xvfb-run).
 *
 * Known limitations, deliberate for a probe: responses from inside tmux/GNU
 * screen/zellij describe the *multiplexer*, not the outer terminal (flagged in
 * the output; passthrough is out of scope); keys pressed during the ~1 s
 * window are consumed and ignored (an arrow key shows up as one unrecognized
 * escape); raw mode clears `ISIG`, so Ctrl+C cannot interrupt the probe window
 * and cannot leave the terminal in raw mode — every read is deadline-bounded.
 */
module tui_query_probe;

version (Posix)  { }
else
{
    void main()
    {
        import std.stdio : writeln;
        writeln("SKIP: tui_query_probe sends POSIX termios queries; Windows is out of scope.");
    }
}

version (Posix):

import std.algorithm.comparison : min;
import std.algorithm.searching : canFind, endsWith, startsWith;
import std.conv : to;
import std.format : format;
import std.process : environment;
import std.stdio : File, stdout, writeln;
import std.string : indexOf;

import core.stdc.errno : EINTR, errno;
import core.sys.posix.poll : poll, pollfd, POLLIN;
import core.sys.posix.termios : ECHO, ICANON, ISIG, tcgetattr, TCSAFLUSH,
    TCSANOW, tcsetattr, termios, VMIN, VTIME;
import core.sys.posix.unistd : posixRead = read, posixWrite = write,
    STDIN_FILENO, STDOUT_FILENO;
import core.time : Duration, MonoTime, msecs;

import sparkles.base.term_control : DecMode;
import sparkles.base.text.ansi : byAnsiToken;
import sparkles.base.text.readers : hexNibble, isHexDigit;
import sparkles.core_cli.term_caps : detectTermCaps, isTerminal, StdStream;

struct Options
{
    bool markdown;
    string name;
    int timeoutMs = 1000;
    bool noGraphics;
    bool raw;
    string outPath;
}

/// The DEC private modes the probe interrogates, in query order.
immutable DecMode[] probedModes = [
    DecMode.bracketedPaste, // 2004
    DecMode.syncOutput,     // 2026
    DecMode.unicodeCore,    // 2027
    DecMode.colorScheme,    // 2031
    DecMode.inBandResize,   // 2048
];

/// The XTGETTCAP capability names the probe requests, in query order.
immutable string[] probedTcaps = ["RGB", "Tc", "Su"];

int main(string[] args)
{
    import std.getopt : defaultGetoptPrinter, getopt;

    Options opts;
    auto helpInfo = getopt(args,
        "markdown", "Emit a markdown matrix row (for the case-study appendix).", &opts.markdown,
        "name", "Terminal name for the matrix row label.", &opts.name,
        "timeout", "Overall response deadline in ms (default 1000).", &opts.timeoutMs,
        "no-graphics", "Skip the kitty graphics APC query.", &opts.noGraphics,
        "raw", "Dump the raw response buffer (escapes visualized).", &opts.raw,
        "out", "Write the report to a file instead of stdout (queries still go "
            ~ "through the terminal — useful under headless capture).", &opts.outPath);
    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Terminal capability query probe.", helpInfo.options);
        return 0;
    }

    auto sink = opts.outPath.length ? File(opts.outPath, "w") : stdout;

    if (!isTerminal(StdStream.stdin) || !isTerminal(StdStream.stdout))
    {
        sink.writeln("SKIP: stdin/stdout is not a terminal — no queries sent.");
        return 0;
    }

    if (!opts.markdown)
        printEnvironmentReport(sink);

    if (environment.get("TERM", "") == "dumb")
    {
        sink.writeln("SKIP: TERM=dumb — not sending queries.");
        return 0;
    }

    const batch = buildQueryBatch(!opts.noGraphics);
    stdout.flush();

    auto raw = RawMode.enter();
    if (!raw.active)
    {
        sink.writeln("SKIP: could not enter raw terminal mode.");
        return 0;
    }
    char[] buf;
    Duration fenceElapsed;
    bool fenced;
    {
        scope (exit) raw.restore();
        buf = collectResponses(batch, opts.timeoutMs, fenced, fenceElapsed);
    }

    auto results = classify(buf, opts.noGraphics);

    if (opts.markdown)
        printMarkdownRow(sink, opts, results);
    else
        printHumanReport(sink, opts, results, fenced, fenceElapsed);

    if (opts.raw)
    {
        sink.writeln("\n== Raw response buffer ==");
        sink.writeln(buf.length ? visualizeEscapes(buf) : "(empty)");
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Query batch
// ---------------------------------------------------------------------------

/// All queries in one string, written in a single flush. Terminals process
/// input in order, so the trailing primary DA acts as a fence: its reply
/// proves every earlier query has answered or never will.
string buildQueryBatch(bool graphics)
{
    string b;
    b ~= "\x1b[>0q";                       // XTVERSION: terminal name/version
    b ~= "\x1b[?u";                        // kitty keyboard: current flags
    foreach (m; probedModes)
        b ~= format("\x1b[?%d$p", cast(int) m); // DECRQM: mode recognized/set?
    foreach (cap; probedTcaps)
        b ~= "\x1bP+q" ~ hexEncode(cap) ~ "\x1b\\"; // XTGETTCAP, one cap per DCS
    b ~= "\x1b]10;?\x07";                  // OSC 10: foreground color
    b ~= "\x1b]11;?\x07";                  // OSC 11: background color
    if (graphics)                          // kitty graphics: 1×1 RGB query action
        b ~= "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
    b ~= "\x1b[>c";                        // secondary DA: terminal identity
    b ~= "\x1b[c";                         // primary DA: the fence
    return b;
}

// ---------------------------------------------------------------------------
// Raw mode + response collection
// ---------------------------------------------------------------------------

/// Raw-mode session modeled on `sparkles.core_cli.key_input` (whose helpers
/// are private and decode a closed key vocabulary). `ISIG` is cleared on
/// purpose: reads are deadline-bounded so Ctrl+C is never needed to escape a
/// hang, and keeping it would let Ctrl+C kill the process before the restore.
struct RawMode
{
    private termios original;
    bool active;

    static RawMode enter() @trusted
    {
        RawMode r;
        if (tcgetattr(STDIN_FILENO, &r.original) != 0)
            return r;
        auto raw = r.original;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;
        // TCSAFLUSH also discards pending unread input (stale keystrokes).
        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0)
            r.active = true;
        return r;
    }

    void restore() @trusted
    {
        if (!active)
            return;
        active = false;
        tcsetattr(STDIN_FILENO, TCSANOW, &original);
    }
}

/// Writes the batch, then accumulates response bytes until the DA1 fence
/// reply is complete or the deadline expires; drains stragglers briefly so
/// nothing leaks into the shell prompt after exit.
char[] collectResponses(in char[] batch, int timeoutMs,
    out bool fenced, out Duration fenceElapsed) @trusted
{
    const started = MonoTime.currTime;
    writeAll(batch);

    char[] buf;
    const deadline = started + timeoutMs.msecs;
    for (;;)
    {
        const remaining = deadline - MonoTime.currTime;
        if (remaining <= Duration.zero)
            break;
        const slice = min(50, remaining.total!"msecs" + 1);
        if (!readChunk(buf, cast(int) slice))
            continue;
        if (hasCompleteDa1Reply(buf))
        {
            fenced = true;
            fenceElapsed = MonoTime.currTime - started;
            break;
        }
    }

    // Quiet drain: swallow anything still in flight (≤ 25 ms of silence).
    while (readChunk(buf, 25)) { }
    return buf;
}

/// One EINTR-safe full write of `s` to stdout.
private void writeAll(in char[] s) @trusted
{
    size_t off = 0;
    while (off < s.length)
    {
        const n = posixWrite(STDOUT_FILENO, s.ptr + off, s.length - off);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            break;
        }
        off += n;
    }
}

/// Polls stdin for up to `waitMs` and appends whatever is readable to `buf`.
/// Returns true if any bytes arrived.
private bool readChunk(ref char[] buf, int waitMs) @trusted
{
    pollfd pfd;
    pfd.fd = STDIN_FILENO;
    pfd.events = POLLIN;
    const pr = poll(&pfd, 1, waitMs);
    if (pr <= 0)
        return false; // timeout, or EINTR/error: caller re-checks the deadline
    char[256] chunk = void;
    const n = posixRead(STDIN_FILENO, chunk.ptr, chunk.length);
    if (n <= 0)
        return false;
    buf ~= chunk[0 .. n];
    return true;
}

/// True once `buf` holds a complete primary-DA reply (`CSI ? … c`). The
/// final byte is the completeness proof: `escapeLength` gives an unterminated
/// trailing CSI everything to end-of-input, so its token can't end in `c`.
bool hasCompleteDa1Reply(in char[] buf)
{
    foreach (tok; buf.byAnsiToken)
        if (tok.isEscape && isDa1(tok.slice))
            return true;
    return false;
}

private bool isDa1(in char[] s)
    => s.length >= 4 && s.startsWith("\x1b[?") && s[$ - 1] == 'c';

// ---------------------------------------------------------------------------
// Classification
// ---------------------------------------------------------------------------

/// One slot per query; `null` means "no reply" (rendered as —).
struct ProbeResults
{
    string xtversion;
    string kittyKbd;
    string[int] decrpm;       // mode number → raw DECRPM value (0–4) as text
    string[string] tcap;      // cap name → decoded value, "ok", or "invalid"
    string osc10, osc11;
    string kittyGfx;          // "OK", raw payload, or "skipped"
    string da1, da2;
    int unrecognized;
}

/// Pure dispatch over the accumulated bytes: every reply shape in the battery
/// is distinguishable by (introducer, prefix, final byte), so no bookkeeping
/// beyond a FIFO for XTGETTCAP failure replies that omit the capability name.
ProbeResults classify(in char[] buf, bool graphicsSkipped)
{
    ProbeResults r;
    if (graphicsSkipped)
        r.kittyGfx = "skipped";
    const(string)[] pendingTcaps = probedTcaps;

    foreach (tok; buf.byAnsiToken)
    {
        if (!tok.isEscape)
            continue; // stray keystrokes during the probe window
        const s = tok.slice;

        if (s.startsWith("\x1bP>|"))                       // XTVERSION reply
            r.xtversion = stripStringTerminator(s[4 .. $]).idup;
        else if (s.startsWith("\x1bP1+r") || s.startsWith("\x1bP0+r")) // XTGETTCAP
            classifyTcapReply(r, pendingTcaps, s[2] == '1',
                stripStringTerminator(s[5 .. $]));
        else if (s.startsWith("\x1b]10;"))                 // OSC 10 fg color
            r.osc10 = stripStringTerminator(s[5 .. $]).idup;
        else if (s.startsWith("\x1b]11;"))                 // OSC 11 bg color
            r.osc11 = stripStringTerminator(s[5 .. $]).idup;
        else if (s.startsWith("\x1b_G"))                   // kitty graphics reply
        {
            const payload = stripStringTerminator(s[3 .. $]);
            r.kittyGfx = payload.canFind(";OK") ? "OK" : payload.idup;
        }
        else if (s.startsWith("\x1b[?") && s.endsWith("$y")) // DECRPM
            classifyDecrpmReply(r, s[3 .. $ - 2]);
        else if (s.startsWith("\x1b[?") && s[$ - 1] == 'u')  // kitty keyboard flags
            r.kittyKbd = s[3 .. $ - 1].idup;
        else if (s.startsWith("\x1b[>") && s[$ - 1] == 'c')  // secondary DA
            r.da2 = s[3 .. $ - 1].idup;
        else if (isDa1(s))                                   // primary DA (fence)
            r.da1 = s[3 .. $ - 1].idup;
        else
            r.unrecognized++;
    }
    return r;
}

/// `CSI ? mode ; value $ y` payload (already stripped to `mode;value`).
private void classifyDecrpmReply(ref ProbeResults r, in char[] payload)
{
    const sep = payload.indexOf(';');
    if (sep <= 0)
        return;
    import std.conv : ConvException;
    try
    {
        const mode = payload[0 .. sep].to!int;
        r.decrpm[mode] = payload[sep + 1 .. $].idup;
    }
    catch (ConvException)
    {
    }
}

/// XTGETTCAP reply payload: `key=value` (both hex) on success, and usually
/// bare on failure. Replies arrive in query order, so a keyless failure is
/// attributed to the oldest still-pending capability.
private void classifyTcapReply(ref ProbeResults r,
    ref const(string)[] pending, bool ok, in char[] payload)
{
    import std.algorithm.searching : countUntil;

    string cap, value;
    const sep = payload.indexOf('=');
    const keyHex = sep >= 0 ? payload[0 .. sep] : payload;
    if (keyHex.length)
        cap = hexDecode(keyHex);
    if (sep >= 0)
        value = hexDecode(payload[sep + 1 .. $]);

    if (cap.length == 0 && pending.length)
        cap = pending[0]; // keyless failure reply: attribute in query order
    const idx = pending.countUntil(cap);
    if (idx >= 0)
        pending = pending[0 .. idx] ~ pending[idx + 1 .. $];

    if (cap.length == 0)
        return;
    r.tcap[cap] = !ok ? "invalid" : (value.length ? value : "ok");
}

/// Strips the BEL or `ESC \` string terminator, if present.
private const(char)[] stripStringTerminator(return scope const(char)[] s)
{
    if (s.endsWith("\x1b\\"))
        return s[0 .. $ - 2];
    if (s.endsWith("\x07"))
        return s[0 .. $ - 1];
    return s;
}

private string hexEncode(in char[] s)
{
    string r;
    foreach (c; s)
        r ~= format("%02X", c);
    return r;
}

private string hexDecode(in char[] s)
{
    string r;
    for (size_t i = 0; i + 1 < s.length; i += 2)
    {
        if (!isHexDigit(s[i]) || !isHexDigit(s[i + 1]))
            return null;
        r ~= cast(char)(hexNibble(s[i]) * 16 + hexNibble(s[i + 1]));
    }
    return r;
}

// ---------------------------------------------------------------------------
// Reports
// ---------------------------------------------------------------------------

immutable string[] reportedEnvVars = [
    "TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "NO_COLOR",
    "CLICOLOR", "CLICOLOR_FORCE", "FORCE_COLOR", "TMUX", "STY", "ZELLIJ",
    "SSH_TTY", "LC_ALL", "LC_CTYPE", "LANG",
];

void printEnvironmentReport(File sink)
{
    sink.writeln("== Environment ==");
    foreach (name; reportedEnvVars)
    {
        const v = environment.get(name, null);
        sink.writefln("%-21s = %s", name, v is null ? "(unset)" : v);
    }

    const caps = detectTermCaps();
    sink.writeln("\n== detectTermCaps() — the env-derived guess ==");
    sink.writefln("tty=%s colors=%s colorDepth=%s unicode=%s size=%sx%s",
        caps.tty, caps.colors, caps.colorDepth, caps.unicode,
        caps.size.width, caps.size.height);

    if (environment.get("TMUX", "").length || environment.get("STY", "").length
        || environment.get("ZELLIJ", "").length)
        sink.writeln("\nNOTE: running inside tmux/screen/zellij — query responses below\n"
            ~ "describe the multiplexer, not the outer terminal.");
    sink.writeln();
}

private string orDash(string v) => v is null ? "—" : (v.length ? v : "(empty)");

private string describeDecrpm(string v)
{
    if (v is null)
        return "—";
    switch (v)
    {
        case "0": return "0 (not recognized)";
        case "1": return "1 (set)";
        case "2": return "2 (recognized, reset)";
        case "3": return "3 (permanently set)";
        case "4": return "4 (permanently reset)";
        default:  return v;
    }
}

void printHumanReport(File sink, in Options opts, ProbeResults r,
    bool fenced, Duration fenceElapsed)
{
    sink.writefln("== Queries (%s) ==", fenced
        ? format("fence arrived after %s ms", fenceElapsed.total!"msecs")
        : format("timed out after %s ms — terminal never answered primary DA", opts.timeoutMs));
    sink.writefln("%-16s %-20s %s", "query", "sent", "reply");

    void row(string name, string sent, string reply)
    {
        sink.writefln("%-16s %-20s %s", name, sent, reply);
    }

    row("XTVERSION", "ESC[>0q", orDash(r.xtversion));
    row("kitty-kbd", "ESC[?u", r.kittyKbd is null ? "—" : "flags=" ~ r.kittyKbd);
    foreach (m; probedModes)
        row(format("mode %d", cast(int) m), format("ESC[?%d$p", cast(int) m),
            describeDecrpm(r.decrpm.get(cast(int) m, null)));
    foreach (cap; probedTcaps)
        row("XTGETTCAP " ~ cap, "ESC P+q" ~ hexEncode(cap), orDash(r.tcap.get(cap, null)));
    row("OSC 10 fg", "ESC]10;?BEL", orDash(r.osc10));
    row("OSC 11 bg", "ESC]11;?BEL", orDash(r.osc11));
    row("kitty-gfx", opts.noGraphics ? "(not sent)" : "ESC_G…a=q…", orDash(r.kittyGfx));
    row("DA2", "ESC[>c", orDash(r.da2));
    row("DA1 (fence)", "ESC[c", orDash(r.da1));

    if (r.unrecognized)
        sink.writefln("\n%d unrecognized escape token(s) — rerun with --raw to inspect.",
            r.unrecognized);
}

void printMarkdownRow(File sink, in Options opts, ProbeResults r)
{
    string name = opts.name;
    if (name is null)
    {
        const prog = environment.get("TERM_PROGRAM", "");
        const ver = environment.get("TERM_PROGRAM_VERSION", "");
        if (prog.length)
            name = ver.length ? prog ~ " " ~ ver : prog;
        else if (r.xtversion !is null)
            name = r.xtversion;
        else
            name = environment.get("TERM", "(unknown)");
    }

    string[] cells = [
        name,
        orDash(environment.get("TERM", null)),
        orDash(environment.get("COLORTERM", null)),
        orDash(r.da1),
        orDash(r.da2),
        orDash(r.xtversion),
        orDash(r.kittyKbd),
    ];
    foreach (m; probedModes)
        cells ~= orDash(r.decrpm.get(cast(int) m, null));
    foreach (cap; probedTcaps)
        cells ~= orDash(r.tcap.get(cap, null));
    cells ~= [orDash(r.osc10), orDash(r.osc11), orDash(r.kittyGfx)];

    sink.writeln("| Terminal | TERM | COLORTERM | DA1 | DA2 | XTVERSION | kitty-kbd "
        ~ "| 2004 | 2026 | 2027 | 2031 | 2048 | RGB | Tc | Su | OSC 10 | OSC 11 | kitty-gfx |");
    sink.write("|");
    foreach (c; cells)
        sink.write(" ", c.length ? c : "—", " |");
    sink.writeln();
}

/// Makes a response buffer printable: ESC → `ESC`, BEL → `BEL`, other C0 → `^X`.
string visualizeEscapes(in char[] s)
{
    string r;
    foreach (c; s)
    {
        if (c == '\x1b')
            r ~= "ESC";
        else if (c == '\x07')
            r ~= "BEL";
        else if (c < 0x20)
            r ~= format("^%c", cast(char)(c + '@'));
        else
            r ~= c;
    }
    return r;
}
