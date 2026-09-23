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
import sparkles.input : charEvent, Event;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.render : paintFull;
import sparkles.ui.degradation : DegradationReport, degradationsOf;
import sparkles.ui.geometry : Size;
import sparkles.ui.tokens : capabilitiesOf, Profile;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_tui.grid_canvas : paintGrid;

import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import gallery : Gallery;
import state : GalleryState;

@safe:

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
    paintFull(buf, grid, capabilitiesOf(req.profile).colorDepth);
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
        script ~= charEvent(c);

    const size = Size(req.width, req.height);
    auto rec = runAppRecorded(app, RunConfig.init, script,
        (ref RecordingHost h) {
            h.size = size;
            // No frame clock: a render is one frame, and a timed notice would
            // otherwise animate away between the keystroke and the snapshot.
            h.frameSeconds = 0;
        });

    const th = app.theme;
    const caps = capabilitiesOf(req.profile);
    Grid grid;
    grid.resize(cast(ushort) req.width, cast(ushort) req.height);
    grid.clearTo(CellStyle(fg: Color.fromRgb(th.pageFg),
        bg: Color.fromRgb(th.pageBg)));
    paintGrid(grid, th.pageBg, rec.lastOps, caps: caps);
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

// The directory the `baseline` goldens live in, beside this package's other
// test data — found from this file rather than the working directory, which
// is wherever `dub test` was run from.
private string baselineGoldenDir()
{
    import std.path : buildNormalizedPath, dirName;

    return buildNormalizedPath(__FILE_FULL_PATH__.dirName, "..", "test", "data",
        "profiles", "baseline");
}

// A page's golden file name: its title, lower-case, spaces to dashes.
private string goldenName(string title)
{
    import std.array : replace;
    import std.uni : toLower;

    return title.toLower.replace(" ", "-") ~ ".txt";
}

@("ui_gallery.render.baselineGoldens")
@system unittest
{
    import std.file : exists, mkdirRecurse, readText, write;
    import std.path : buildPath;
    import std.process : environment;
    import registry : pages;

    // `O1`/`CAP5`: every page's `baseline` render — ASCII chrome, no color —
    // is a reviewed file, and drift from it fails here. Bless a deliberate
    // change with `SPARKLES_UPDATE_GOLDENS=1 dub test :ui-gallery`, then read
    // the diff: that review is the oracle's independence.
    const bless = environment.get("SPARKLES_UPDATE_GOLDENS", "") == "1";
    const dir = baselineGoldenDir();
    if (bless)
        mkdirRecurse(dir);

    string[] drifted;
    foreach (i, ref p; pages)
    {
        const text = renderPlain(RenderRequest(page: i, profile: Profile.baseline));
        const path = buildPath(dir, goldenName(p.title));
        if (bless)
            write(path, text);
        else if (!path.exists || readText(path) != text)
            drifted ~= p.title;
    }
    assert(drifted.length == 0, "baseline render drifted from its golden for: "
        ~ drifted.join(", ") ~ " (bless with SPARKLES_UPDATE_GOLDENS=1)");
}

@("ui_gallery.render.baselineEmitsNoColor")
@safe unittest
{
    import std.algorithm : canFind;
    import registry : pages;

    // `CAP8`: a pipe gets no color sequence the profile forbids — not a
    // foreground, not a background, on any page.
    foreach (i, ref p; pages)
    {
        const ansi = renderAnsi(RenderRequest(page: i, profile: Profile.baseline));
        assert(!ansi.canFind("[38;") && !ansi.canFind(";38;")
            && !ansi.canFind("[48;") && !ansi.canFind(";48;"),
            p.title ~ " emits color at baseline");
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
