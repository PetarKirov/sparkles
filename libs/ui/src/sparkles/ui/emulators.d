/**
Emulator presets (design-system [`CAP10`](../../../../../docs/specs/design-system/capabilities.md)):
a declaration per terminal emulator whose answers were $(I measured), for
previewing and testing what an application looks like there.

A preset is two things, kept apart so each can be checked on its own:

$(LIST
    * the emulator's $(B recorded replies) — a row of the empirical response
        matrix (the capability-detection case study's §16, collected with its
        `query-probe.d`; research branch `research/term-capabilities` at
        `9ee7df44`), transcribed verbatim onto the member as a $(LREF replies)
        UDA;
    * $(LREF fromReplies), which reads answers, never a name, through the one
        mapping a live probe feeds too
        ($(REF applyReplies, sparkles,base,term_replies); `CAP3`: capabilities
        come from answers, not identity).
)

Only what the battery asks is claimed from it: color depth, synchronized
output (2026), grapheme clustering (2027), color-scheme reports (2031),
bracketed paste (2004), the kitty keyboard and graphics protocols and the DA1
sixel attribute. The facts no query reaches — links, clipboard,
notifications, styled underlines, and every font fact past the half blocks —
are left off (D32): a preset may show less than its emulator can, never more.

Presets are a partial order, not a ladder: kitty and Ghostty are each missing
something the other has. `CAP9`'s monotone chain is the three profiles';
narrowing a host to a preset is `meet`, which needs no order.
*/
module sparkles.ui.emulators;

import std.traits : EnumMembers, getUDAs;

import sparkles.base.term_caps : BlockTier, ImageProtocol, TermCaps;
import sparkles.base.term_color : classifyColorDepth, ColorDepth;
import sparkles.base.term_replies : applyReplies, available, ModeReply, TcapReply,
    TerminalReplies;
import sparkles.ui.tokens : meet, TargetCapabilities, terminalCapabilities;
import sparkles.wired.policy : AnyFormat, CaseStyle, resolveCaseStyle, WireCase,
    wireNames;

/**
What one emulator answered the query battery with: a row's label, and the
answers themselves in the vocabulary a live probe records them in
($(REF TerminalReplies, sparkles,base,term_replies)).
*/
struct replies
{
    string measured;         /// the row's label: emulator, version and platform
    TerminalReplies answers; /// the replies, and the environment they came with
}

/**
The measured emulators. Each member carries every row recorded for it — a
multiplexer one per host it was attached to, since what it answers can
follow the host — and its declaration is $(LREF capabilitiesOf). Rows the
matrix holds but no preset takes: the bare pty (no emulator at all —
`baseline`) and GNU screen 4.00.03, a 2006 build below every glyph
assumption the presets share.

Rows not in the case study's matrix were collected with its probe
(`query-probe.d --raw`) and are checked in whole under
`libs/ui/test/data/emulators/`.
*/
@WireCase(CaseStyle.kebabCase)
enum Emulator : ubyte
{
    @replies("XTerm 403 (Linux)", TerminalReplies(term: "xterm", da1: "64;1;2;6;9;15;16;17;18;21;22;28;29",
        paste: ModeReply.reset, sync: ModeReply.notRecognized,
        graphemes: ModeReply.notRecognized, scheme: ModeReply.notRecognized,
        rgb: TcapReply.valid, tc: TcapReply.invalid))
    xterm,

    @replies("Apple Terminal (macOS 26.3)", TerminalReplies(term: "xterm-256color", colorterm: "truecolor",
        da1: "1;2"))
    appleTerminal,

    @replies("iTerm2 3.6.10 (macOS)", TerminalReplies(term: "xterm-256color", colorterm: "truecolor",
        da1: "64;1;2;4;6;17;18;21;22;52", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.permanentlyReset, scheme: ModeReply.reset,
        rgb: TcapReply.valid, tc: TcapReply.invalid, kittyGraphics: true))
    iterm2,

    @replies("Alacritty 0.16.1 (Linux)", TerminalReplies(term: "alacritty", colorterm: "truecolor",
        da1: "6", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.notRecognized, scheme: ModeReply.notRecognized))
    alacritty,

    // foot.txt
    @replies("foot 1.25.0 (Linux, headless cage)", TerminalReplies(term: "foot", colorterm: "truecolor",
        da1: "62;4;22;28;52", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.set, scheme: ModeReply.reset,
        rgb: TcapReply.valid, tc: TcapReply.valid))
    foot,

    @replies("WezTerm 2025-10-14 (Linux)", TerminalReplies(term: "xterm-256color", colorterm: "truecolor",
        da1: "65;4;6;18;22;52",
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.permanentlySet, scheme: ModeReply.notRecognized,
        rgb: TcapReply.valid, tc: TcapReply.valid, kittyGraphics: true))
    wezterm,

    @replies("kitty 0.44.0 (Linux)", TerminalReplies(term: "xterm-kitty", colorterm: "truecolor",
        da1: "62;52;", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.notRecognized, scheme: ModeReply.reset,
        rgb: TcapReply.invalid, tc: TcapReply.valid, kittyGraphics: true))
    kitty,

    @replies("Ghostty 1.3.1 (Linux, macOS 26.3)", TerminalReplies(term: "xterm-ghostty",
        colorterm: "truecolor", da1: "62;22;52", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.set, scheme: ModeReply.reset,
        rgb: TcapReply.valid, tc: TcapReply.valid, kittyGraphics: true))
    ghostty,

    // The matrix row, then tmux-foot.txt and tmux-ghostty.txt: tmux answers
    // alike under every host, sixel attribute included — even in Ghostty,
    // which draws no sixel.
    @replies("tmux 3.6a (detached, or on a bare pty)", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4",
        paste: ModeReply.reset, scheme: ModeReply.reset, multiplexer: true))
    @replies("tmux 3.6a in foot 1.25.0", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4",
        paste: ModeReply.reset, scheme: ModeReply.reset, multiplexer: true))
    @replies("tmux 3.6a in Ghostty 1.3.1", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4",
        paste: ModeReply.reset, scheme: ModeReply.reset, multiplexer: true))
    tmux,

    // zellij-bare.txt, zellij-foot.txt, zellij-ghostty.txt: zellij's image
    // answers follow its host — kitty graphics in Ghostty, refused in foot,
    // and both protocols claimed with no host at all.
    @replies("zellij 0.45.1 on a bare pty", TerminalReplies(term: "xterm-256color", colorterm: "truecolor",
        da1: "62;4;52", kittyKeyboard: true,
        paste: ModeReply.none, sync: ModeReply.reset,
        graphemes: ModeReply.none, scheme: ModeReply.reset,
        rgb: TcapReply.invalid, tc: TcapReply.invalid, kittyGraphics: true,
        multiplexer: true))
    @replies("zellij 0.45.1 in foot 1.25.0", TerminalReplies(term: "foot", colorterm: "truecolor",
        da1: "62;4;52", kittyKeyboard: true,
        paste: ModeReply.none, sync: ModeReply.reset,
        graphemes: ModeReply.none, scheme: ModeReply.reset,
        rgb: TcapReply.invalid, tc: TcapReply.invalid, multiplexer: true))
    @replies("zellij 0.45.1 in Ghostty 1.3.1", TerminalReplies(term: "xterm-ghostty", colorterm: "truecolor",
        da1: "62;52", kittyKeyboard: true,
        paste: ModeReply.none, sync: ModeReply.reset,
        graphemes: ModeReply.none, scheme: ModeReply.reset,
        rgb: TcapReply.invalid, tc: TcapReply.invalid, kittyGraphics: true,
        multiplexer: true))
    zellij,
}

/// The kebab-case names a command line spells presets with.
alias emulatorNames = wireNames!(AnyFormat, Emulator,
    resolveCaseStyle!(AnyFormat, Emulator));

/// Each preset's recorded rows, by ordinal — read from the members' UDAs,
/// so the table is spelled once, on the enum.
static immutable replies[][] emulatorReplies = () {
    replies[][] t;
    static foreach (e; EnumMembers!Emulator)
    {{
        replies[] rows;
        static foreach (r; getUDAs!(e, replies))
            rows ~= r;
        t ~= rows;
    }}
    return t;
}();

/**
What a set of replies declares: the environment they came with, as
`detectTermCaps` classifies it, with the answers applied by
$(REF applyReplies, sparkles,base,term_replies) — the same mapping a live
probe feeds, so a preset is what the probe would declare in that emulator —
plus the input modes a previewed application would negotiate where the
emulator answered for them: bracketed paste, focus reports, and the kitty
keyboard (key releases).

Everything else stays off; $(LREF capabilitiesOf) adds the shared floor.
*/
TargetCapabilities fromReplies(in TerminalReplies r) @safe pure nothrow @nogc
{
    TermCaps t;
    t.tty = true;
    t.colorDepth = classifyColorDepth(r.colorterm, r.term);
    applyReplies(t, r);
    t.bracketedPaste = r.paste.available;
    t.focusReporting = r.focus.available;
    t.kittyKeyboard = r.kittyKeyboard;
    return terminalCapabilities(t);
}

/// ditto — a recorded row.
TargetCapabilities fromReplies(in replies r) @safe pure nothrow @nogc
    => fromReplies(r.answers);

/**
An emulator's declaration: what every row recorded for it declares
($(LREF fromReplies), met across the rows — a multiplexer is credited only
with what it answered under every host) over the floor
every preset shares — Unicode, the half blocks, and an SGR cell mouse with
hover. The floor is what the `enhanced` profile already assumes of an
emulator of the last decade; `enhanced`'s protocol claims (links, focus and
paste events) are not in it, because those the replies answer or they stay
unknown (D32).
*/
TargetCapabilities capabilitiesOf(Emulator e) @safe pure nothrow @nogc
{
    const rows = emulatorReplies[e];
    auto c = fromReplies(rows[0]);
    foreach (r; rows[1 .. $])
        c = meet(c, fromReplies(r));
    c.unicode = true;
    c.blocks = BlockTier.half;
    c.input.hover = true;
    c.input.maxPointers = 1;
    return c;
}

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.ui.tokens : Profile, subsetOf;
    static import sparkles.ui.tokens;

    private TargetCapabilities profile(Profile p) @safe pure nothrow @nogc
        => sparkles.ui.tokens.capabilitiesOf(p);
}

@("ui.emulators.table")
@safe pure nothrow @nogc
unittest
{
    // The whole mapping, one row per preset (`O7`): what each emulator's
    // recorded replies declare.
    static struct Row
    {
        Emulator e;
        ColorDepth depth;
        bool sync, graphemes, scheme;
        ImageProtocol images;
        bool paste, keyRelease;
    }
    alias C = ColorDepth;
    alias I = ImageProtocol;
    static immutable Row[] rows = [
        Row(Emulator.xterm,         C.trueColor, false, false, false, I.none,  true,  false),
        Row(Emulator.appleTerminal, C.trueColor, false, false, false, I.none,  false, false),
        Row(Emulator.iterm2,        C.trueColor, true,  false, true,  I.kitty, true,  true),
        Row(Emulator.alacritty,     C.trueColor, true,  false, false, I.none,  true,  true),
        Row(Emulator.foot,          C.trueColor, true,  true,  true,  I.sixel, true,  true),
        Row(Emulator.wezterm,       C.trueColor, true,  true,  false, I.kitty, true,  false),
        Row(Emulator.kitty,         C.trueColor, true,  false, true,  I.kitty, true,  true),
        Row(Emulator.ghostty,       C.trueColor, true,  true,  true,  I.kitty, true,  true),
        Row(Emulator.tmux,          C.trueColor, false, false, true,  I.none,  true,  false),
        Row(Emulator.zellij,        C.trueColor, true,  false, true,  I.none,  false, true),
    ];
    assert(rows.length == emulatorReplies.length, "a row per preset");
    foreach (i, row; rows)
    {
        assert(row.e == i, "rows in declaration order");
        const c = capabilitiesOf(row.e);
        assert(c.colorDepth == row.depth);
        assert(c.syncOutput == row.sync);
        assert(c.graphemeClusters == row.graphemes);
        assert(c.colorSchemeNotify == row.scheme);
        assert(c.images == row.images);
        assert(c.input.pasteEvents == row.paste);
        assert(c.input.keyRelease == row.keyRelease);
    }
}

@("ui.emulators.neverClaimTheUnmeasured")
@safe pure nothrow @nogc
unittest
{
    // D32: no preset claims a fact the battery does not ask, and every one
    // sits inside `full` but for the image protocol, which is not ordered —
    // tmux's sixel is no less than `full`'s kitty, and no more.
    const full = profile(Profile.full);
    static foreach (e; EnumMembers!Emulator)
    {{
        const c = capabilitiesOf(e);
        TargetCapabilities sansImages = c;
        sansImages.images = ImageProtocol.none;
        assert(subsetOf(sansImages, full));
        assert(!c.hyperlinks && !c.clipboard && !c.notifications && !c.pointerShape
            && !c.textSizing && !c.progress && !c.extendedUnderline && !c.cellPixelSize);
        assert(!c.braille && !c.nerdFont && c.blocks == BlockTier.half && c.unicode);
        assert(!c.input.focusEvents && !c.input.precisePointer);
        assert(!c.subCellScroll && !c.radius && !c.shadow && !c.alpha);
    }}
}

@("ui.emulators.presetsAreAPartialOrder")
@safe pure nothrow @nogc
unittest
{
    // kitty has the scheme reports Ghostty has too, but WezTerm's graphemes
    // are not kitty's and kitty's key releases are not WezTerm's: neither
    // contains the other, so no ladder places them.
    const kitty = capabilitiesOf(Emulator.kitty);
    const wezterm = capabilitiesOf(Emulator.wezterm);
    const ghostty = capabilitiesOf(Emulator.ghostty);
    assert(!subsetOf(kitty, wezterm) && !subsetOf(wezterm, kitty));
    assert(subsetOf(kitty, ghostty), "Ghostty answers everything kitty does");
    // A preset narrowed by a profile is still below both — `meet` is how the
    // live switch composes them.
    const e = profile(Profile.enhanced);
    const m = meet(kitty, e);
    assert(subsetOf(m, kitty) && subsetOf(m, e));
    assert(m.colorDepth == ColorDepth.ansi256 && m.images == ImageProtocol.none);
}

@("ui.emulators.fromReplies.readsAnswersNotNames")
@safe pure nothrow @nogc
unittest
{
    // No reply at all is the bare pty: a tier of color from the environment
    // and nothing else — the mapping has no name to lean on.
    TerminalReplies bare = {term: "xterm-256color"};
    const c = fromReplies(bare);
    assert(c.colorDepth == ColorDepth.ansi256);
    assert(!c.syncOutput && !c.graphemeClusters && !c.colorSchemeNotify);
    assert(c.images == ImageProtocol.none && !c.input.pasteEvents);

    // The permanent answers: 3 is on, 4 is off for good.
    TerminalReplies r = bare;
    r.graphemes = ModeReply.permanentlySet;
    assert(fromReplies(r).graphemeClusters);
    r.graphemes = ModeReply.permanentlyReset;
    assert(!fromReplies(r).graphemeClusters);
    // DA1's first parameter is the class, not an attribute: `4;…` is VT132
    // hardware, not sixel.
    r.da1 = "4;6";
    assert(fromReplies(r).images == ImageProtocol.none);
    r.da1 = "65;4";
    assert(fromReplies(r).images == ImageProtocol.sixel);
    // An `XTGETTCAP` answer outranks a 16-color `$TERM` (XTerm's own row).
    r.term = "xterm";
    r.tc = TcapReply.valid;
    assert(fromReplies(r).colorDepth == ColorDepth.trueColor);
}

@("ui.emulators.names")
@safe pure nothrow @nogc
unittest
{
    assert(emulatorNames[Emulator.appleTerminal] == "apple-terminal");
    assert(emulatorNames[Emulator.iterm2] == "iterm2");
    assert(emulatorReplies[Emulator.kitty][0].measured == "kitty 0.44.0 (Linux)");
}

@("ui.emulators.multiplexerImagesNeedAConfirmedRoundTrip")
@safe pure nothrow @nogc
unittest
{
    // CAP7: tmux lists sixel in DA1 under every host, Ghostty included,
    // which draws none — a static advertisement is not a passthrough.
    foreach (r; emulatorReplies[Emulator.tmux])
        assert(fromReplies(r).images == ImageProtocol.none);
    // The same attribute from a terminal is its own: foot draws sixel.
    assert(capabilitiesOf(Emulator.foot).images == ImageProtocol.sixel);
    // The kitty graphics query is a round trip, and zellij's answer follows
    // its host: `OK` in Ghostty, refused in foot. The preset is what holds
    // under every host it was measured in, so it claims no images at all.
    const z = emulatorReplies[Emulator.zellij];
    assert(z.length == 3);
    assert(fromReplies(z[2]).images == ImageProtocol.kitty);
    assert(fromReplies(z[1]).images == ImageProtocol.none);
    assert(capabilitiesOf(Emulator.zellij).images == ImageProtocol.none);
}

@("ui.emulators.aPresetIsTheMeetOfItsRows")
@safe pure nothrow @nogc
unittest
{
    // Every row's declaration contains the preset's, for every preset: a
    // second recorded host can only take a claim away.
    static foreach (e; EnumMembers!Emulator)
        foreach (r; emulatorReplies[e])
        {
            TargetCapabilities row = fromReplies(r);
            row.unicode = true;
            row.blocks = BlockTier.half;
            row.input.hover = true;
            row.input.maxPointers = 1;
            assert(subsetOf(capabilitiesOf(e), row));
        }
}

@("ui.emulators.rowsAreTheirTranscripts")
@system unittest
{
    import std.algorithm.searching : findSplit, startsWith;
    import std.array : replace;
    import std.string : lineSplitter, strip;
    import sparkles.base.term_replies : parseReplies;
    import sparkles.ui.test_utils : readFromTestDir;

    // `O5`: the rows collected for this module are the probe reports checked
    // in beside it — and each report's raw reply bytes are fed here through
    // the parser a live probe uses, so a row can drift neither from its
    // evidence nor from what the probe would make of the same bytes.
    static TerminalReplies parse(string report)
    {
        TerminalReplies r;
        bool raw;
        foreach (line; report.lineSplitter)
        {
            if (raw)
            {
                // The report spells the control bytes out.
                const bytes = line.replace("ESC", "\x1b").replace("BEL", "\x07");
                ubyte[] rest;
                parseReplies(cast(const(ubyte)[]) bytes, r, rest);
                break;
            }
            if (line.startsWith("== Raw response buffer =="))
            {
                raw = true;
                continue;
            }
            const env = line.findSplit(" = ");
            if (env[1].length && !line.startsWith(" "))
            {
                const key = env[0].strip, value = env[2].strip;
                const set = value != "(unset)";
                if (key == "TERM") r.term = value;
                if (key == "COLORTERM" && set) r.colorterm = value;
                if ((key == "TMUX" || key == "STY" || key == "ZELLIJ") && set)
                    r.multiplexer = true;
            }
        }
        return r;
    }

    static struct Evidence { Emulator e; size_t row; string file; }
    static immutable Evidence[] evidence = [
        Evidence(Emulator.foot, 0, "foot.txt"),
        Evidence(Emulator.tmux, 1, "tmux-foot.txt"),
        Evidence(Emulator.tmux, 2, "tmux-ghostty.txt"),
        Evidence(Emulator.zellij, 0, "zellij-bare.txt"),
        Evidence(Emulator.zellij, 1, "zellij-foot.txt"),
        Evidence(Emulator.zellij, 2, "zellij-ghostty.txt"),
    ];
    foreach (ev; evidence)
    {
        auto parsed = parse(readFromTestDir(ev.file));
        const row = emulatorReplies[ev.e][ev.row].answers;
        assert(parsed.fenced, ev.file ~ ": the DA1 fence is in the bytes");
        parsed.fenced = row.fenced; // a transcribed row does not record the fence
        assert(parsed == row, ev.file);
    }
}
