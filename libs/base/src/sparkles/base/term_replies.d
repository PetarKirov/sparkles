/++
What a terminal answered, and what the answers mean (design-system `CAP3`):
the query-derived half of $(REF TermCaps, sparkles,base,term_caps).

$(LREF TerminalReplies) is the vocabulary of one query battery's answers —
recorded by `sparkles:tui`'s probe from a live terminal, or transcribed from a
measured one (the design system's emulator presets). $(LREF applyReplies) is
the $(B one) mapping from those answers onto a `TermCaps`, so a preset and a
live probe of the same terminal cannot disagree: a preset $(I is) what the
probe would declare.

The mapping sets what may be $(B emitted) — colour depth, synchronized output,
grapheme clustering, scheme reports, images, the cell's pixel size. The input
modes the battery also asks about (bracketed paste, focus, the kitty keyboard)
are recorded but not applied: `TermCaps`' mode fields say what was
$(I negotiated), and only whoever enables a mode can say that.
+/
module sparkles.base.term_replies;

import sparkles.base.term_caps : ImageProtocol, TermCaps;
import sparkles.base.term_color : ColorDepth;

/// One `DECRPM` reply to a `DECRQM` mode query, or its absence — the
/// default, as a record that does not name a mode got no reply for it.
enum ModeReply : ubyte
{
    none,             /// no reply before the DA1 fence
    notRecognized,    /// `0`
    set,              /// `1`
    reset,            /// `2` — recognized, and the application may set it
    permanentlySet,   /// `3`
    permanentlyReset, /// `4`
}

/// `true` iff the mode is on or can be turned on.
bool available(ModeReply m) @safe pure nothrow @nogc
    => m == ModeReply.set || m == ModeReply.reset
    || m == ModeReply.permanentlySet;

/// One `XTGETTCAP` reply.
enum TcapReply : ubyte
{
    none,    /// no reply before the fence
    valid,   /// the capability was answered
    invalid, /// the terminal answered that it has no such capability
}

/**
One query battery's answers, and the environment they came with. The strings
are the replies' own bytes.
*/
struct TerminalReplies
{
    string term;           /// `$TERM`
    string colorterm;      /// `$COLORTERM`, empty when unset
    string da1;            /// primary DA's parameters, empty when unanswered
    bool kittyKeyboard;    /// the kitty keyboard query (`CSI ? u`) was answered
    ModeReply paste;       /// mode 2004
    ModeReply sync;        /// mode 2026
    ModeReply graphemes;   /// mode 2027
    ModeReply scheme;      /// mode 2031
    ModeReply focus;       /// mode 1004
    TcapReply rgb;         /// `XTGETTCAP RGB`
    TcapReply tc;          /// `XTGETTCAP Tc`
    bool kittyGraphics;    /// the kitty graphics query was answered `OK`
    /// `$TMUX`, `$STY` or `$ZELLIJ` was set: the replies are a multiplexer's,
    /// and describe the host terminal only where it relays them (`CAP7`).
    bool multiplexer;
    ushort cellWidth, cellHeight; /// `CSI 16 t`'s answer, `0` when unanswered
    bool fenced;           /// DA1 arrived: every earlier reply is in
}

/// Whether DA1's parameters list `attribute` after the class — the first
/// parameter is the device class, never an attribute.
bool listsAttribute(in char[] da1, in char[] attribute) @safe pure nothrow @nogc
{
    size_t start, field;
    foreach (i; 0 .. da1.length + 1)
        if (i == da1.length || da1[i] == ';')
        {
            if (field++ > 0 && da1[start .. i] == attribute)
                return true;
            start = i + 1;
        }
    return false;
}

/**
Applies `r` to `t`, a snapshot the environment already filled:

$(LIST
    * colour depth is raised to 24-bit when `XTGETTCAP` answers `RGB` or `Tc`
        — never where the environment turned colour off;
    * `syncOutput`, `graphemeClusters` and `colorSchemeNotify` are what their
        mode answers (on, or can be set);
    * `images` is kitty when the graphics query answers, else sixel when DA1
        lists attribute `4` — but not under a multiplexer (`CAP7`), where the
        attribute is a static advertisement, not a confirmed passthrough;
    * `cellPixelSize` is whether `CSI 16 t` was answered.
)
*/
void applyReplies(ref TermCaps t, in TerminalReplies r) @safe pure nothrow @nogc
{
    if (t.colorDepth != ColorDepth.none && (r.rgb == TcapReply.valid || r.tc == TcapReply.valid))
        t.colorDepth = ColorDepth.trueColor;
    t.syncOutput = r.sync.available;
    t.graphemeClusters = r.graphemes.available;
    t.colorSchemeNotify = r.scheme.available;
    t.images = r.kittyGraphics ? ImageProtocol.kitty
        : !r.multiplexer && listsAttribute(r.da1, "4") ? ImageProtocol.sixel
        : ImageProtocol.none;
    t.cellPixelSize = r.cellWidth != 0 && r.cellHeight != 0;
}

/**
The battery (`CAP3`), in one write: the kitty graphics query (a 1×1 image,
id 31, queried and never stored), the kitty keyboard flags, `DECRQM` for
modes 2004, 2026, 2027, 2031 and 1004, `XTGETTCAP` for `RGB` and `Tc`, the
cell's pixel size (`CSI 16 t`) — then primary DA, the fence. Terminals answer
in order, so DA1's reply proves every earlier one is in or never coming.
*/
enum string queryBattery = "\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\"
    ~ "\x1b[?u"
    ~ "\x1b[?2004$p\x1b[?2026$p\x1b[?2027$p\x1b[?2031$p\x1b[?1004$p"
    ~ "\x1bP+q524742\x1b\\\x1bP+q5463\x1b\\"
    ~ "\x1b[16t"
    ~ "\x1b[c";

/**
Takes the battery's replies out of what arrived on the input stream, into
`r`, and appends every other byte — a key typed meanwhile, a reply to
something else — to `rest`, in order, for the input decoder.

Call it on everything read so far: a reply cut off at the end is left in
`rest` and `r.fenced` stays false until a longer read completes it.
*/
void parseReplies(in ubyte[] bytes, ref TerminalReplies r, ref ubyte[] rest)
    @safe pure nothrow
{
    size_t i;
    while (i < bytes.length)
    {
        const at = bytes[i .. $];
        // APC: the kitty graphics reply.
        if (startsWith(at, "\x1b_G"))
        {
            const end = find(at, "\x1b\\");
            if (end == size_t.max)
                break;
            const body_ = at[3 .. end];
            if (find(body_, "i=31") != size_t.max && find(body_, ";OK") != size_t.max)
                r.kittyGraphics = true;
            i += end + 2;
            continue;
        }
        // DCS: an `XTGETTCAP` reply, `1+r` answered or `0+r` refused.
        if (at.length >= 5 && at[0] == 0x1b && at[1] == 'P'
            && (at[2] == '0' || at[2] == '1') && at[3] == '+' && at[4] == 'r')
        {
            const end = find(at, "\x1b\\");
            if (end == size_t.max)
                break;
            auto name = at[5 .. end];
            const eq = find(name, "=");
            if (eq != size_t.max)
                name = name[0 .. eq];
            const reply = at[2] == '1' ? TcapReply.valid : TcapReply.invalid;
            if (name == cast(const(ubyte)[]) "524742")
                r.rgb = reply;
            else if (name == cast(const(ubyte)[]) "5463")
                r.tc = reply;
            else if (name.length == 0)
            {
                // A refusal need not echo the name (zellij's does not):
                // replies come in order, so it answers the first capability
                // the battery asked that is still unanswered — `RGB`, `Tc`.
                if (r.rgb == TcapReply.none)
                    r.rgb = reply;
                else if (r.tc == TcapReply.none)
                    r.tc = reply;
            }
            i += end + 2;
            continue;
        }
        // CSI: DA1, `DECRPM`, the kitty keyboard flags, the cell size.
        if (startsWith(at, "\x1b["))
        {
            size_t j = 2;
            const priv = j < at.length && at[j] == '?';
            if (priv)
                ++j;
            const p0 = j;
            while (j < at.length && ((at[j] >= '0' && at[j] <= '9') || at[j] == ';'))
                ++j;
            const params = at[p0 .. j];
            const dollar = j < at.length && at[j] == '$';
            if (dollar)
                ++j;
            if (j >= at.length)
                break; // cut off
            const fin = at[j];
            if (priv && !dollar && fin == 'c')
            {
                r.da1 = (cast(const(char)[]) params).idup;
                r.fenced = true;
                i += j + 1;
                continue;
            }
            if (priv && !dollar && fin == 'u')
            {
                r.kittyKeyboard = true;
                i += j + 1;
                continue;
            }
            if (priv && dollar && fin == 'y')
            {
                uint mode, value;
                const semi = find(params, ";");
                if (semi != size_t.max)
                {
                    mode = number(params[0 .. semi]);
                    value = number(params[semi + 1 .. $]);
                    const m = value <= 4 ? cast(ModeReply)(value + 1) : ModeReply.none;
                    switch (mode)
                    {
                        case 2004: r.paste = m; break;
                        case 2026: r.sync = m; break;
                        case 2027: r.graphemes = m; break;
                        case 2031: r.scheme = m; break;
                        case 1004: r.focus = m; break;
                        default: break;
                    }
                }
                i += j + 1;
                continue;
            }
            if (!priv && !dollar && fin == 't' && startsWith(params, "6;"))
            {
                const rest_ = params[2 .. $];
                const semi = find(rest_, ";");
                if (semi != size_t.max)
                {
                    r.cellHeight = cast(ushort) number(rest_[0 .. semi]);
                    r.cellWidth = cast(ushort) number(rest_[semi + 1 .. $]);
                    i += j + 1;
                    continue;
                }
            }
        }
        rest ~= bytes[i];
        ++i;
    }
    rest ~= bytes[i .. $];
}

private bool startsWith(in ubyte[] s, string prefix) @safe pure nothrow @nogc
    => s.length >= prefix.length && s[0 .. prefix.length] == cast(const(ubyte)[]) prefix;

private size_t find(in ubyte[] s, string needle) @safe pure nothrow @nogc
{
    if (s.length < needle.length)
        return size_t.max;
    foreach (k; 0 .. s.length - needle.length + 1)
        if (s[k .. k + needle.length] == cast(const(ubyte)[]) needle)
            return k;
    return size_t.max;
}

private uint number(in ubyte[] digits) @safe pure nothrow @nogc
{
    uint v;
    foreach (c; digits)
        if (c >= '0' && c <= '9')
            v = v * 10 + (c - '0');
    return v;
}

@("term_replies.applyReplies.outputRows")
@safe pure nothrow @nogc
unittest
{
    // Ghostty's measured answers, over a truecolor environment.
    TermCaps t;
    t.colorDepth = ColorDepth.ansi256;
    TerminalReplies r = {term: "xterm-ghostty", colorterm: "truecolor", da1: "62;22;52",
        kittyKeyboard: true, paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.set, scheme: ModeReply.reset,
        rgb: TcapReply.valid, tc: TcapReply.valid, kittyGraphics: true, fenced: true};
    applyReplies(t, r);
    assert(t.colorDepth == ColorDepth.trueColor);
    assert(t.syncOutput && t.graphemeClusters && t.colorSchemeNotify);
    assert(t.images == ImageProtocol.kitty && !t.cellPixelSize);
    // The input modes are recorded, not applied: nothing negotiated them.
    assert(!t.bracketedPaste && !t.kittyKeyboard && !t.focusReporting);
}

@("term_replies.applyReplies.colourOffStaysOff")
@safe pure nothrow @nogc
unittest
{
    // `NO_COLOR` or a pipe turned colour off; an answer does not turn it on.
    TermCaps t;
    TerminalReplies r = {rgb: TcapReply.valid};
    applyReplies(t, r);
    assert(t.colorDepth == ColorDepth.none);
}

@("term_replies.applyReplies.sixelIsTheTerminalsOwnOnly")
@safe pure nothrow @nogc
unittest
{
    TermCaps t;
    TerminalReplies foot = {da1: "62;4;22;28;52"};
    applyReplies(t, foot);
    assert(t.images == ImageProtocol.sixel);
    TerminalReplies tmux = {da1: "1;2;4", multiplexer: true};
    applyReplies(t, tmux);
    assert(t.images == ImageProtocol.none);
    // The class is not an attribute: VT132's `4;…` is no sixel.
    TerminalReplies vt132 = {da1: "4;6"};
    applyReplies(t, vt132);
    assert(t.images == ImageProtocol.none);
}

@("term_replies.available")
@safe pure nothrow @nogc
unittest
{
    assert(ModeReply.set.available && ModeReply.reset.available
        && ModeReply.permanentlySet.available);
    assert(!ModeReply.none.available && !ModeReply.notRecognized.available
        && !ModeReply.permanentlyReset.available);
}

@("term_replies.parseReplies.theWholeBattery")
@safe pure nothrow
unittest
{
    // foot's answers to the battery (its measured replies, plus `CSI 16 t`),
    // with a key typed in the middle and a reply to something else.
    const bytes = cast(const(ubyte)[]) ("\x1b[?0u"
        ~ "\x1b[?2004;2$y\x1b[?2026;2$yj\x1b[?2027;1$y\x1b[?2031;2$y\x1b[?1004;2$y"
        ~ "\x1bP1+r524742=38\x1b\\\x1bP1+r5463\x1b\\"
        ~ "\x1b]11;rgb:2424/2424/2424\x07"
        ~ "\x1b[6;13;6t\x1b[?62;4;22;28;52c");
    TerminalReplies r;
    ubyte[] rest;
    parseReplies(bytes, r, rest);
    assert(r.kittyKeyboard && !r.kittyGraphics && r.fenced);
    assert(r.paste == ModeReply.reset && r.sync == ModeReply.reset);
    assert(r.graphemes == ModeReply.set && r.scheme == ModeReply.reset);
    assert(r.focus == ModeReply.reset);
    assert(r.rgb == TcapReply.valid && r.tc == TcapReply.valid);
    assert(r.cellWidth == 6 && r.cellHeight == 13);
    assert(r.da1 == "62;4;22;28;52");
    assert(rest == cast(const(ubyte)[]) "j\x1b]11;rgb:2424/2424/2424\x07");
}

@("term_replies.parseReplies.namelessRefusalsGoInOrder")
@safe pure nothrow
unittest
{
    // zellij 0.45.1's measured replies: three refusals, none naming what it
    // refuses. They answer the battery in order.
    TerminalReplies r;
    ubyte[] rest;
    parseReplies(cast(const(ubyte)[]) "\x1bP0+r\x1b\\\x1bP0+r\x1b\\\x1bP0+r\x1b\\", r, rest);
    assert(r.rgb == TcapReply.invalid && r.tc == TcapReply.invalid && rest.length == 0);
}

@("term_replies.parseReplies.refusalsAndACutOff")
@safe pure nothrow
unittest
{
    // A refused capability, a refused graphics query, and the fence not yet
    // in: the partial DA1 waits in `rest` for a longer read.
    TerminalReplies r;
    ubyte[] rest;
    parseReplies(cast(const(ubyte)[]) ("\x1bP0+r524742\x1b\\"
        ~ "\x1b_Gi=31;ENOTSUPPORTED:no\x1b\\\x1b[?62;2"), r, rest);
    assert(r.rgb == TcapReply.invalid && !r.kittyGraphics && !r.fenced);
    assert(rest == cast(const(ubyte)[]) "\x1b[?62;2");
}

@("term_replies.transcripts.corpus")
@system unittest
{
    import std.array : replace;
    import std.conv : to;
    import std.file : readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : lineSplitter, startsWith;
    import sparkles.base.term_color : classifyColorDepth;

    // `O5`: the battery's replies as real terminals sent them — captured
    // with `queryBattery` itself, headless (kitty, Ghostty, XTerm and
    // Alacritty under xvfb; foot under `cage`; tmux and zellij under each of
    // foot, Ghostty and a bare pty), checked in under
    // `libs/base/test/data/term_replies/` — through the parser a live probe
    // uses, row by row, then through the mapping.
    static struct Transcript { TerminalReplies replies; string terminal; }
    static Transcript load(string file)
    {
        const path = __FILE_FULL_PATH__.dirName
            .buildNormalizedPath("../../../test/data/term_replies", file);
        Transcript t;
        foreach (line; readText(path).lineSplitter)
        {
            if (line.startsWith("terminal: "))
                t.terminal = line["terminal: ".length .. $];
            else if (line.startsWith("TERM: "))
                t.replies.term = line["TERM: ".length .. $];
            else if (line.startsWith("COLORTERM: "))
                t.replies.colorterm = line["COLORTERM: ".length .. $];
            else if (line.startsWith("TMUX: set") || line.startsWith("ZELLIJ: set"))
                t.replies.multiplexer = true;
            else if (line.startsWith("replies: "))
            {
                // The capture spells control bytes out.
                string bytes = line["replies: ".length .. $].replace("ESC", "\x1b").replace("BEL", "\x07");
                ubyte[] rest;
                parseReplies(cast(const(ubyte)[]) bytes, t.replies, rest);
                assert(rest.length == 0, file ~ ": every byte is a reply");
            }
        }
        return t;
    }

    alias M = ModeReply;
    alias X = TcapReply;
    alias P = ImageProtocol;
    static struct Row
    {
        string file;
        bool graphics, keyboard;
        M paste, sync, graphemes, scheme, focus;
        X rgb, tc;
        ushort cellWidth, cellHeight;
        P images;
    }
    static immutable Row[] rows = [
        Row("kitty.txt",     true,  true,  M.reset, M.reset, M.notRecognized, M.reset, M.reset,
            X.invalid, X.valid, 9, 18, P.kitty),
        Row("ghostty.txt",   true,  true,  M.reset, M.reset, M.set, M.reset, M.reset,
            X.valid, X.valid, 10, 21, P.kitty),
        Row("foot.txt",      false, true,  M.reset, M.reset, M.set, M.reset, M.reset,
            X.valid, X.valid, 6, 13, P.sixel),
        Row("xterm.txt",     false, false, M.reset, M.notRecognized, M.notRecognized,
            M.notRecognized, M.reset, X.valid, X.invalid, 6, 13, P.none),
        Row("alacritty.txt", false, true,  M.reset, M.reset, M.notRecognized, M.notRecognized,
            M.reset, X.none, X.none, 0, 0, P.none),
        // tmux answers for itself, under any host: no graphics or keyboard
        // reply relayed, DA1's sixel not believed under a multiplexer
        // (`CAP7`), and a cell size of its own on a bare pty.
        Row("tmux-foot.txt", false, false, M.reset, M.none, M.none, M.reset, M.reset,
            X.none, X.none, 6, 13, P.none),
        Row("tmux-ghostty.txt", false, false, M.reset, M.none, M.none, M.reset, M.reset,
            X.none, X.none, 10, 21, P.none),
        Row("tmux-bare.txt", false, false, M.reset, M.none, M.none, M.reset, M.reset,
            X.none, X.none, 16, 32, P.none),
        // zellij's graphics answer follows its host; it answers neither
        // paste nor focus, and refuses `XTGETTCAP` without naming what.
        Row("zellij-bare.txt", true, true, M.none, M.reset, M.none, M.reset, M.none,
            X.invalid, X.invalid, 0, 0, P.kitty),
        Row("zellij-foot.txt", false, true, M.none, M.reset, M.none, M.reset, M.none,
            X.invalid, X.invalid, 6, 13, P.none),
        Row("zellij-ghostty.txt", true, true, M.none, M.reset, M.none, M.reset, M.none,
            X.invalid, X.invalid, 10, 21, P.kitty),
    ];
    foreach (row; rows)
    {
        const t = load(row.file);
        const r = t.replies;
        assert(r.fenced, row.file);
        assert(r.kittyGraphics == row.graphics && r.kittyKeyboard == row.keyboard, row.file);
        assert(r.paste == row.paste && r.sync == row.sync && r.graphemes == row.graphemes
            && r.scheme == row.scheme && r.focus == row.focus, row.file);
        assert(r.rgb == row.rgb && r.tc == row.tc, row.file);
        assert(r.cellWidth == row.cellWidth && r.cellHeight == row.cellHeight, row.file);

        // And what the answers declare, over the environment's snapshot.
        TermCaps caps;
        caps.colorDepth = classifyColorDepth(r.colorterm, r.term);
        applyReplies(caps, r);
        assert(caps.images == row.images, row.file);
        assert(caps.syncOutput == row.sync.available, row.file);
        assert(caps.cellPixelSize == (row.cellWidth != 0), row.file);
        // Every one of these can show 24-bit colour: from `$COLORTERM`, or —
        // XTerm, whose `$TERM` says 16 — from its `RGB` answer.
        assert(caps.colorDepth == ColorDepth.trueColor, row.file);
    }
    // And the corpus is exactly these rows.
    {
        import std.algorithm.iteration : filter;
        import std.algorithm.searching : count;
        import std.file : dirEntries, SpanMode;

        const dir = __FILE_FULL_PATH__.dirName
            .buildNormalizedPath("../../../test/data/term_replies");
        assert(dirEntries(dir, "*.txt", SpanMode.shallow).count == rows.length);
    }
}
