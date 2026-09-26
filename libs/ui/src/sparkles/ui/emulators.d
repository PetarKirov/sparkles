/**
Emulator presets (design-system [`CAP10`](../../../../../docs/specs/design-system/capabilities.md)):
a declaration per terminal emulator whose answers were $(I measured), for
previewing and testing what an application looks like there.

A preset is two things, kept apart so each can be checked on its own:

$(LIST
    * the emulator's $(B recorded replies), onto the member as a
        $(LREF replies) UDA: the battery's own replies from the design
        system's `O5` corpus (`libs/base/test/data/term_replies/`), where it
        reaches, else a row of the capability-detection case study's
        empirical response matrix (§16, collected with its `query-probe.d`,
        an earlier battery; research branch `research/term-capabilities` at
        `9ee7df44`);
    * $(LREF fromReplies), which reads answers, never a name, through the one
        mapping a live probe feeds too
        ($(REF applyReplies, sparkles,base,term_replies); `CAP3`: capabilities
        come from answers, not identity).
)

Only what the battery asks is claimed from it: color depth, synchronized
output (2026), grapheme clustering (2027), color-scheme reports (2031),
bracketed paste (2004), focus reports (1004), the cell's pixel size
(`CSI 16 t`), the kitty keyboard and graphics protocols and the DA1 sixel
attribute — the last three only for rows recorded with them. The facts no
query reaches — links, clipboard, notifications, styled underlines, and
every font fact past the half blocks — are left off (D32): a preset may show
less than its emulator can, never more.

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
follow the host — and its declaration is $(LREF capabilitiesOf).

Where the design system's `O5` corpus reaches (kitty, Ghostty, foot, XTerm,
Alacritty, and tmux and zellij under a bare pty, foot and Ghostty), a row is
the battery's own replies as that terminal sent them, named by its file in
`libs/base/test/data/term_replies/` and re-read against it by test — so the
preset is what a live probe declares there, its focus, paste and cell-size
rows included. iTerm2, Apple Terminal and WezTerm keep their rows from the
capability case study's matrix (`query-probe.d`, an earlier battery), which
the corpus does not reach yet.
*/
@WireCase(CaseStyle.kebabCase)
enum Emulator : ubyte
{
    // xterm.txt
    @replies("XTerm 403 (Linux, xvfb)", TerminalReplies(term: "xterm",
        da1: "64;1;2;6;9;15;16;17;18;21;22;28;29", paste: ModeReply.reset,
        sync: ModeReply.notRecognized, graphemes: ModeReply.notRecognized,
        scheme: ModeReply.notRecognized, focus: ModeReply.reset, rgb: TcapReply.valid,
        tc: TcapReply.invalid, cellWidth: 6, cellHeight: 13))
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

    // alacritty.txt
    @replies("Alacritty 0.16.1 (Linux, xvfb, software GL)", TerminalReplies(
        term: "alacritty", colorterm: "truecolor", da1: "6", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset, graphemes: ModeReply.notRecognized,
        scheme: ModeReply.notRecognized, focus: ModeReply.reset))
    alacritty,

    // foot.txt
    @replies("foot 1.25.0 (Linux, headless cage)", TerminalReplies(term: "foot",
        colorterm: "truecolor", da1: "62;4;22;28;52", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset, graphemes: ModeReply.set,
        scheme: ModeReply.reset, focus: ModeReply.reset, rgb: TcapReply.valid,
        tc: TcapReply.valid, cellWidth: 6, cellHeight: 13))
    foot,

    @replies("WezTerm 2025-10-14 (Linux)", TerminalReplies(term: "xterm-256color", colorterm: "truecolor",
        da1: "65;4;6;18;22;52",
        paste: ModeReply.reset, sync: ModeReply.reset,
        graphemes: ModeReply.permanentlySet, scheme: ModeReply.notRecognized,
        rgb: TcapReply.valid, tc: TcapReply.valid, kittyGraphics: true))
    wezterm,

    // kitty.txt
    @replies("kitty 0.44.0 (Linux, xvfb)", TerminalReplies(term: "xterm-kitty",
        colorterm: "truecolor", da1: "62;52;", kittyKeyboard: true, paste: ModeReply.reset,
        sync: ModeReply.reset, graphemes: ModeReply.notRecognized, scheme: ModeReply.reset,
        focus: ModeReply.reset, rgb: TcapReply.invalid, tc: TcapReply.valid,
        kittyGraphics: true, cellWidth: 9, cellHeight: 18))
    kitty,

    // ghostty.txt
    @replies("Ghostty 1.3.1 (Linux, xvfb)", TerminalReplies(term: "xterm-ghostty",
        colorterm: "truecolor", da1: "62;22;52", kittyKeyboard: true,
        paste: ModeReply.reset, sync: ModeReply.reset, graphemes: ModeReply.set,
        scheme: ModeReply.reset, focus: ModeReply.reset, rgb: TcapReply.valid,
        tc: TcapReply.valid, kittyGraphics: true, cellWidth: 10, cellHeight: 21))
    ghostty,

    // tmux-bare.txt, tmux-foot.txt, tmux-ghostty.txt: tmux answers for
    // itself under every host, its DA1 sixel attribute included — even inside
    // Ghostty, which draws no sixel.
    @replies("tmux 3.6a on a bare pty", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4", paste: ModeReply.reset,
        scheme: ModeReply.reset, focus: ModeReply.reset, multiplexer: true,
        cellWidth: 16, cellHeight: 32))
    @replies("tmux 3.6a in foot 1.25.0", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4", paste: ModeReply.reset,
        scheme: ModeReply.reset, focus: ModeReply.reset, multiplexer: true,
        cellWidth: 6, cellHeight: 13))
    @replies("tmux 3.6a in Ghostty 1.3.1", TerminalReplies(term: "tmux-256color",
        colorterm: "truecolor", da1: "1;2;4", paste: ModeReply.reset,
        scheme: ModeReply.reset, focus: ModeReply.reset, multiplexer: true,
        cellWidth: 10, cellHeight: 21))
    tmux,

    // zellij-bare.txt, zellij-foot.txt, zellij-ghostty.txt: zellij's graphics
    // answer follows its host — `OK` in Ghostty and with no host at all,
    // refused in foot.
    @replies("zellij 0.45.1 on a bare pty", TerminalReplies(term: "xterm-256color",
        colorterm: "truecolor", da1: "62;4;52", kittyKeyboard: true, sync: ModeReply.reset,
        scheme: ModeReply.reset, rgb: TcapReply.invalid, tc: TcapReply.invalid,
        kittyGraphics: true, multiplexer: true))
    @replies("zellij 0.45.1 in foot 1.25.0", TerminalReplies(term: "foot",
        colorterm: "truecolor", da1: "62;4;52", kittyKeyboard: true, sync: ModeReply.reset,
        scheme: ModeReply.reset, rgb: TcapReply.invalid, tc: TcapReply.invalid,
        multiplexer: true, cellWidth: 6, cellHeight: 13))
    @replies("zellij 0.45.1 in Ghostty 1.3.1", TerminalReplies(term: "xterm-ghostty",
        colorterm: "truecolor", da1: "62;52", kittyKeyboard: true, sync: ModeReply.reset,
        scheme: ModeReply.reset, rgb: TcapReply.invalid, tc: TcapReply.invalid,
        kittyGraphics: true, multiplexer: true, cellWidth: 10, cellHeight: 21))
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
            && !c.textSizing && !c.progress && !c.extendedUnderline);
        assert(!c.braille && !c.nerdFont && c.blocks == BlockTier.half && c.unicode);
        assert(!c.input.precisePointer);
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
    assert(emulatorReplies[Emulator.kitty][0].measured == "kitty 0.44.0 (Linux, xvfb)");
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
    import std.array : replace;
    import std.file : readText;
    import std.path : buildNormalizedPath, dirName;
    import std.string : lineSplitter, startsWith;
    import sparkles.base.term_replies : parseReplies;

    // `O5`: a corpus-backed row is its recording — the battery's own replies
    // from that terminal, in `sparkles:base`'s capture corpus — fed through
    // the parser a live probe uses. A row can drift neither from its evidence
    // nor from what the probe would make of the same bytes.
    static TerminalReplies parse(string file)
    {
        const path = __FILE_FULL_PATH__.dirName
            .buildNormalizedPath("../../../../base/test/data/term_replies", file);
        TerminalReplies r;
        foreach (line; readText(path).lineSplitter)
        {
            if (line.startsWith("TERM: ")) r.term = line["TERM: ".length .. $];
            if (line.startsWith("COLORTERM: ")) r.colorterm = line["COLORTERM: ".length .. $];
            if (line.startsWith("TMUX: set") || line.startsWith("ZELLIJ: set"))
                r.multiplexer = true;
            if (line.startsWith("replies: "))
            {
                ubyte[] rest;
                parseReplies(cast(const(ubyte)[]) line["replies: ".length .. $]
                    .replace("ESC", "\x1b").replace("BEL", "\x07"), r, rest);
            }
        }
        return r;
    }

    static struct Evidence { Emulator e; size_t row; string file; }
    static immutable Evidence[] evidence = [
        Evidence(Emulator.xterm, 0, "xterm.txt"),
        Evidence(Emulator.alacritty, 0, "alacritty.txt"),
        Evidence(Emulator.foot, 0, "foot.txt"),
        Evidence(Emulator.kitty, 0, "kitty.txt"),
        Evidence(Emulator.ghostty, 0, "ghostty.txt"),
        Evidence(Emulator.tmux, 0, "tmux-bare.txt"),
        Evidence(Emulator.tmux, 1, "tmux-foot.txt"),
        Evidence(Emulator.tmux, 2, "tmux-ghostty.txt"),
        Evidence(Emulator.zellij, 0, "zellij-bare.txt"),
        Evidence(Emulator.zellij, 1, "zellij-foot.txt"),
        Evidence(Emulator.zellij, 2, "zellij-ghostty.txt"),
    ];
    foreach (ev; evidence)
    {
        auto parsed = parse(ev.file);
        const row = emulatorReplies[ev.e][ev.row].answers;
        assert(parsed.fenced, ev.file ~ ": the DA1 fence is in the bytes");
        parsed.fenced = row.fenced; // a row does not record the fence
        assert(parsed == row, ev.file);
    }
}

@("ui.emulators.cellSizeAndFocusWhereEveryRowAnswered")
@safe pure nothrow @nogc
unittest
{
    // The rows the `O5` corpus added: a preset claims the cell's pixel size
    // and focus events exactly where every row recorded for it answered —
    // `CSI 16 t`, and mode 1004 as available.
    static foreach (e; EnumMembers!Emulator)
    {{
        bool cell = true, focus = true;
        foreach (r; emulatorReplies[e])
        {
            cell &= r.answers.cellWidth != 0;
            focus &= r.answers.focus.available;
        }
        const c = capabilitiesOf(e);
        assert(c.cellPixelSize == cell);
        assert(c.input.focusEvents == focus);
    }}
    // Measured facts, spelled out: Alacritty answers focus but not its cell
    // size; zellij neither, and on a bare pty not even the size.
    assert(capabilitiesOf(Emulator.kitty).cellPixelSize
        && capabilitiesOf(Emulator.kitty).input.focusEvents);
    assert(!capabilitiesOf(Emulator.alacritty).cellPixelSize
        && capabilitiesOf(Emulator.alacritty).input.focusEvents);
    assert(!capabilitiesOf(Emulator.zellij).cellPixelSize
        && !capabilitiesOf(Emulator.zellij).input.focusEvents);
    // The case-study rows never asked: no claim.
    assert(!capabilitiesOf(Emulator.iterm2).cellPixelSize
        && !capabilitiesOf(Emulator.iterm2).input.focusEvents);
}
