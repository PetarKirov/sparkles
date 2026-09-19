/**
Rendering one frame with no terminal session and no window (`--render`).

The catalog is a visual artifact, and the slowest way to look at one is to open
it. This drives the $(B same) `view` the real loop calls — through the recording
host, so nothing is special-cased — paints the resulting display list, and hands
back either ANSI or bare glyphs.

$(B It paints through the terminal's own canvas.) An earlier version used
$(REF CellGrid, sparkles,ui,interp,cells), which is a second cell canvas with
its own copy of the glyph decisions — and the two disagreed. `--render` showed
dashed borders and accent bars that the live `--tui` did not, so a render that
was supposed to make a defect visible was hiding one instead. A headless render
of a different painter than the one that runs is worse than no render at all.

So this module, alone in the application, names a canvas. `gallery.d` — the
component, the thing that actually runs — still names none; this is a
development tool and a golden-snapshot source, and it is only useful if it is
byte-for-byte the terminal.
*/
module render;

import std.array : appender, join;
import std.conv : to;

import sparkles.base.term_color : Color;
import sparkles.input : charEvent, Event, Key, keyEvent;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.cell : writeStyle;
import sparkles.tui.render : paintFull, serializeRow;
import sparkles.ui.degradation : DegradationReport, degradationsOf;
import sparkles.ui.geometry : Size;
import sparkles.ui.tokens : Profile, TargetCapabilities;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui.geometry : Rect;
import sparkles.ui_tui.grid_canvas : EffectContext, paintGrid;

import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import gallery : Gallery;
import state : EmulatorChoice, GalleryState, narrowingOf;

@safe:

/// One `--keys` character as the event a terminal would deliver: the control
/// characters a script can spell — tab, return, escape — are those keys, not
/// typed text, so a render can reach a state that takes `Tab` to get to.
Event keyOf(dchar c)
{
    switch (c)
    {
        case '\t': return keyEvent(Key.tab);
        case '\r', '\n': return keyEvent(Key.enter);
        case '\x1b': return keyEvent(Key.escape);
        default: return charEvent(c);
    }
}

/// What to render, and how big.
struct RenderRequest
{
    size_t page;         /// index into the catalog
    string keys;         /// keystrokes delivered before the frame is taken
    int width = 96;      /// surface width in cells
    int height = 32;     /// surface height in cells
    /// The documented capability profile to paint for (`CAP5`). `full` paints
    /// exactly what the grid holds, so a render that names no profile is the
    /// one it always was.
    Profile profile = Profile.full;
    /// The measured emulator to preview (`CAP10`), met with the profile.
    EmulatorChoice emulator;

    /// What the frame is painted for: the profile, inside the preset.
    TargetCapabilities capabilities() const scope @safe pure nothrow @nogc
        => narrowingOf(profile, emulator);
}

/// The frame `req` describes, as ANSI — the same bytes the terminal backend
/// would emit for a full repaint.
string renderAnsi(in RenderRequest req)
{
    // A `SharedBuffer!char`, not an `appender!string`: the terminal writers put
    // `const(char)[]` control sequences, which an immutable-element appender
    // refuses. This is the buffer the real render loop uses too.
    import sparkles.base.buffer : SharedBuffer;

    auto grid = renderGrid(req);
    SharedBuffer!(char, 1 << 16) buf;
    // The profile's color tier is the one the bytes are folded to: at
    // `baseline` no color sequence is emitted at all (`CAP8`).
    paintFull(buf, grid, req.capabilities.colorDepth);
    return buf[].idup;
}

/**
The frame `req` describes as the body of an `ansi` fence: each row's cells
styled at the profile's color depth, no cursor addressing, a reset and a
newline after every row — the form a Markdown renderer can color, and the
style guide's fences are made of.
*/
string renderFence(in RenderRequest req)
{
    import sparkles.base.buffer : SharedBuffer;

    auto grid = renderGrid(req);
    const depth = req.capabilities.colorDepth;
    SharedBuffer!(char, 1 << 16) buf;
    foreach (ushort y; 0 .. grid.rows)
    {
        serializeRow(buf, grid.row(y), depth);
        writeStyle(buf, CellStyle.init, depth);
        buf ~= '\n';
    }
    return buf[].idup;
}

/**
The frame `req` describes as bare glyphs, one line per row, trailing blanks
trimmed.

The form a golden compares against: a layout regression is visible in it
directly, whereas a diff over SGR runs mostly reports colour changes nobody
asked about.
*/
string renderPlain(in RenderRequest req)
    => gridText(renderGrid(req));

/// A painted grid as bare glyphs. Separate from $(LREF renderPlain) so the
/// wide-glyph rule below can be checked against a grid built by hand, rather
/// than only wherever a page happens to put one.
string gridText(in Grid grid)
{
    auto out_ = appender!string;

    foreach (ushort y; 0 .. grid.rows)
    {
        char[] line;
        foreach (ushort x; 0 .. grid.cols)
        {
            const c = grid[x, y];
            // A wide glyph's continuation cell carries no bytes of its own;
            // emitting its empty grapheme would silently narrow the row and
            // make every column after it disagree with the terminal.
            if (c.width == 0)
                continue;
            line ~= c.grapheme.length ? c.grapheme : " ";
        }
        // Trailing blanks carry no information and make a golden sensitive to
        // the surface width in a way the content is not.
        size_t end = line.length;
        while (end > 0 && line[end - 1] == ' ')
            --end;
        out_ ~= line[0 .. end];
        out_ ~= '\n';
    }
    return out_[];
}

/**
What the frame `req` describes gave up to its profile (`CAP6`): one line per
substitution taken, empty when the frame rendered exactly as authored.
*/
string renderDegradations(in RenderRequest req)
{
    DegradationReport report;
    cast(void) paintFrame(req, report);
    auto out_ = appender!string;
    report.toString(out_);
    return out_[];
}

/// The painted grid — the step both forms share, and the one that must be the
/// terminal's own painter rather than a lookalike.
Grid renderGrid(in RenderRequest req)
{
    DegradationReport ignored;
    return paintFrame(req, ignored);
}

// The frame, painted for `req.profile`, and the report of the same operations
// against the same declaration — one recording, so the two cannot describe
// different frames.
private Grid paintFrame(in RenderRequest req, out DegradationReport report)
{
    auto app = Gallery(GalleryState(page: req.page));

    Event[] script;
    foreach (dchar c; req.keys)
        script ~= keyOf(c);

    const size = Size(req.width, req.height);
    auto rec = runAppRecorded(app, RunConfig.init, script,
        (ref RecordingHost h) {
            h.size = size;
            // No frame clock: a render is one frame, and a timed notice would
            // otherwise animate away between the keystroke and the snapshot.
            h.frameSeconds = 0;
        });

    const th = app.theme;
    const caps = req.capabilities;
    Grid grid;
    grid.resize(cast(ushort) req.width, cast(ushort) req.height);
    grid.clearTo(CellStyle(fg: Color.fromRgb(th.pageFg),
        bg: Color.fromRgb(th.pageBg)));
    // The effect context, so a tier-0 bracket is actually honoured here
    // (`EFX9`) — a `--render` that dropped effects would be showing something
    // the terminal does not.
    auto fxP = (() @trusted => &app.fx)();
    paintGrid(grid, th.pageBg, rec.lastOps, caps: caps,
        effects: EffectContext(fxP, th.pageFg));
    report = degradationsOf(rec.lastOps, caps);
    return grid;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui_gallery.render.everyPageRendersSomething")
@safe unittest
{
    import std.algorithm : canFind;
    import registry : pages;

    // A page that lays out but paints nothing would pass the catalog sweep and
    // still be blank on screen. This is the assertion that notices.
    foreach (i, ref p; pages)
    {
        const text = renderPlain(RenderRequest(page: i, width: 90, height: 28));
        assert(text.canFind(p.title), p.title ~ " is not on its own page");
        assert(text.canFind("sparkles:ui"), "the header band is missing");
    }
}

@("ui_gallery.render.aRenderIsDeterministic")
@safe unittest
{
    // Goldens depend on it, and so does anyone diffing two runs. Nothing in the
    // frame path may read a clock or a random source.
    const req = RenderRequest(page: 0, width: 80, height: 24);
    assert(renderPlain(req) == renderPlain(req));
}

@("ui_gallery.render.keystrokesReachTheFrame")
@safe unittest
{
    import std.algorithm : canFind;

    // `--keys` is how a screenshot reaches a state that takes input to get to.
    const plain = RenderRequest(page: 0, width: 80, height: 24);
    const themed = RenderRequest(page: 0, keys: "]", width: 80, height: 24);
    assert(renderPlain(plain).canFind("tokyo-night"));
    assert(renderPlain(themed).canFind("solarized-dark"));
}

@("ui_gallery.render.paintsThroughTheTerminalsOwnCanvas")
@safe unittest
{
    import std.algorithm : canFind;
    import registry : pageIndexOf;

    // The reason this module names a canvas at all. `--render` used a second
    // cell canvas whose border glyphs had drifted from the terminal's, so it
    // showed dashed borders and an accent bar the live `--tui` did not — the
    // render agreeing with itself while disagreeing with the program.
    //
    // These glyphs come from the Decoration page's specimens. If `--render`
    // ever goes back to a lookalike canvas that renders them differently, this
    // fails rather than quietly making the goldens fiction.
    const text = renderPlain(RenderRequest(page: pageIndexOf("decoration"),
        width: 76, height: 44));

    assert(text.canFind('┈'), "a dotted border draws quadruple dashes");
    assert(text.canFind('╌'), "a dashed border draws double dashes");
    assert(text.canFind('┃'), "a wide left accent draws the heavy quote bar");
    assert(text.canFind('╭'), "a rounded border keeps its corners");
}

@("ui_gallery.render.wideGlyphsSurviveTheRoundTrip")
@safe unittest
{
    // A wide glyph occupies two cells and the second carries no bytes. Emitting
    // that empty continuation would shorten the row, so every column after it
    // would disagree with the terminal — which is the whole property this file
    // exists to preserve. Checked on a grid built here rather than wherever a
    // page happens to put one, which is also below the fold on its own page.
    Grid g;
    g.resize(10, 1);
    g.putText(0, 0, "日本語ab", CellStyle.init);

    const text = gridText(g);
    assert(text == "日本語ab\n", "the row is neither padded nor truncated");
}

// The directory a page's profile goldens live in, beside this package's other
// test data — found from this file rather than the working directory, which
// is wherever `dub test` was run from.
private string goldenDir(string title)
{
    import std.array : replace;
    import std.path : buildNormalizedPath, dirName;
    import std.uni : toLower;

    return buildNormalizedPath(__FILE_FULL_PATH__.dirName, "..", "test", "data",
        "profiles", title.toLower.replace(" ", "-"));
}

/**
Every file of one page's style-guide entry (`O1`): for each profile its
`ansi` fence and its degradation report, plus the `baseline` frame as plain
glyphs — the one a reviewer reads a layout diff in. The docs pages under
`docs/design-system/catalog/` import these files, so what CI checks here is
what the style guide shows.
*/
private string[2][] goldenFiles(size_t page)
{
    import std.conv : to;
    import std.traits : EnumMembers;

    string[2][] files;
    files ~= ["baseline.txt", renderPlain(RenderRequest(page: page, profile: Profile.baseline))];
    static foreach (p; EnumMembers!Profile)
    {
        files ~= [p.to!string ~ ".ansi", renderFence(RenderRequest(page: page, profile: p))];
        files ~= [p.to!string ~ ".report", renderDegradations(RenderRequest(page: page, profile: p))];
    }
    return files;
}

@("ui_gallery.render.profileGoldens")
@system unittest
{
    import std.file : exists, mkdirRecurse, readText, write;
    import std.path : buildPath;
    import std.process : environment;
    import registry : pages;

    // `O1`/`CAP5`: every page, every profile, is a reviewed file, and drift
    // from it fails here. Bless a deliberate change with
    // `SPARKLES_UPDATE_GOLDENS=1 dub test :ui-gallery`, then read the diff —
    // `baseline.txt` first: that review is the oracle's independence.
    const bless = environment.get("SPARKLES_UPDATE_GOLDENS", "") == "1";
    string[] drifted;
    foreach (i, ref p; pages)
    {
        const dir = goldenDir(p.title);
        if (bless)
            mkdirRecurse(dir);
        foreach (f; goldenFiles(i))
        {
            const path = buildPath(dir, f[0]);
            if (bless)
                write(path, f[1]);
            else if (!path.exists || readText(path) != f[1])
                drifted ~= p.title ~ "/" ~ f[0];
        }
    }
    assert(drifted.length == 0, "the profile renders drifted from their goldens: "
        ~ drifted.join(", ") ~ " (bless with SPARKLES_UPDATE_GOLDENS=1)");
}

@("ui_gallery.render.baselineEmitsNoColor")
@safe unittest
{
    import std.algorithm : canFind, splitter;
    import std.conv : to;
    import registry : pages;

    // `CAP8`: a pipe gets no color sequence the profile forbids — no
    // parameter of any SGR sequence may select a color, at any depth: not
    // 24-bit, not 256, and not the classic 16 either (which this test once
    // let through, and the writer once emitted).
    static bool selectsColor(uint p)
        => p == 38 || p == 48 || p == 58 || (p >= 30 && p <= 37)
            || (p >= 40 && p <= 47) || (p >= 90 && p <= 97) || (p >= 100 && p <= 107);

    foreach (i, ref pg; pages)
    {
        const ansi = renderAnsi(RenderRequest(page: i, profile: Profile.baseline))
            ~ renderFence(RenderRequest(page: i, profile: Profile.baseline));
        for (size_t at = 0; at + 1 < ansi.length; ++at)
        {
            if (ansi[at] != '\x1b' || ansi[at + 1] != '[')
                continue;
            size_t end = at + 2;
            while (end < ansi.length && ansi[end] >= 0x20 && ansi[end] < 0x40)
                ++end;
            if (end < ansi.length && ansi[end] == 'm')
                foreach (param; ansi[at + 2 .. end].splitter(';'))
                {
                    // `4:3` is an underline shape (a sub-parameter), not a color.
                    if (param.length == 0 || param.canFind(':'))
                        continue;
                    assert(!selectsColor(param.to!uint),
                        pg.title ~ " emits color at baseline: " ~ ansi[at .. end + 1]);
                }
            at = end;
        }
    }
}

@("ui_gallery.render.profilesOnlyEverLoseThings")
@safe unittest
{
    import registry : pages;
    import sparkles.ui.degradation : Substitution, substitutionCapabilities;

    // `CAP9` as the gallery sees it: moving up the ladder never costs a
    // capability more. Counted per capability, not per substitution — the
    // same box is `radius-dropped` at baseline and `radius-as-glyph` above
    // it, which is one loss getting smaller, not a new one appearing.
    static uint[string] byCapability(in DegradationReport r)
    {
        uint[string] m;
        foreach (s, c; r.counts)
            m[substitutionCapabilities[s]] += c;
        return m;
    }

    foreach (i, ref p; pages)
    {
        DegradationReport b, e, f;
        cast(void) paintFrame(RenderRequest(page: i, profile: Profile.baseline), b);
        cast(void) paintFrame(RenderRequest(page: i, profile: Profile.enhanced), e);
        cast(void) paintFrame(RenderRequest(page: i, profile: Profile.full), f);
        auto cb = byCapability(b), ce = byCapability(e), cf = byCapability(f);
        foreach (cap, n; cf)
            assert(n <= ce.get(cap, 0), p.title ~ ": full costs more " ~ cap);
        foreach (cap, n; ce)
            assert(n <= cb.get(cap, 0), p.title ~ ": enhanced costs more " ~ cap);
        assert(f[Substitution.asciiBorder] == 0 && f[Substitution.colorDropped] == 0);
        assert(renderPlain(RenderRequest(page: i))
            == renderPlain(RenderRequest(page: i, profile: Profile.full)),
            "an unprofiled render is the full one");
    }
}

@("ui_gallery.render.focusIsVisibleInMonochrome")
@safe unittest
{
    import registry : pages;

    // `ACC4`: with no color at all, moving the keyboard between the page list
    // and the page must change something a monochrome terminal shows — a
    // glyph, or an attribute (reverse, bold, underline) — on every page.
    // Colors are left out of the comparison on purpose: they are exactly
    // what `baseline` cannot show.
    // The page list only — the element that gains and loses focus. The whole
    // frame would pass on the status bar's own "pages"/"page" label, which
    // says where focus is without showing it on the focused thing.
    static string mono(in Grid g)
    {
        import std.conv : to;

        string r;
        foreach (ushort y; 1 .. cast(ushort)(g.rows - 1))
            foreach (ushort x; 0 .. 20)
            {
                const c = g[x, y];
                r ~= c.grapheme;
                r ~= (cast(uint) c.style.attrs.bits).to!string;
                r ~= (cast(uint) c.style.underline).to!string;
            }
        return r;
    }

    foreach (i, ref p; pages)
    {
        const nav = mono(renderGrid(RenderRequest(page: i, profile: Profile.baseline)));
        const content = mono(renderGrid(RenderRequest(page: i, keys: "\t",
            profile: Profile.baseline)));
        assert(nav != content, p.title ~ ": focus moved and nothing visible changed");
    }
}
