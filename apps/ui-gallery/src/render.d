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
import sparkles.input : charEvent, Event, match, PointerAction, PointerButton,
    PointerEvent;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.render : paintFull;
import sparkles.ui.degradation : DegradationReport, degradationsOf;
import sparkles.ui.geometry : Point, Size;
import sparkles.ui.tokens : capabilitiesOf, Profile;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_tui.grid_canvas : paintGrid;

import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import gallery : Gallery;
import state : GalleryState, Region;

@safe:

/// What to render, and how big.
struct RenderRequest
{
    size_t page;         /// index into the catalog
    string keys;         /// keystrokes delivered before the frame is taken
    /**
    A pointer script, in cells, delivered after `keys`.

    Space-separated words, each a verb and a `col,row`: `m12,4` move,
    `p12,4` press, `r12,4` release, `R20,12` right-press, `X20,12`
    right-release.

    `POP8` asks that every overlay behavior be assertable headlessly, and a
    key-only recorder cannot reach half of them: a context menu opens on a
    right-press and a hovercard on a click, so neither is expressible as a
    keystroke at all.
    */
    string pointer;
    int width = 96;      /// surface width in cells
    int height = 32;     /// surface height in cells
    /// The documented capability profile to paint for (`CAP5`). `full` paints
    /// exactly what the grid holds, so a render that names no profile is the
    /// one it always was.
    Profile profile = Profile.full;
}

/**
`script` as pointer events. A malformed word is skipped rather than fatal —
this is a debugging affordance, and a typo should cost the event it names, not
the frame.
*/
Event[] pointerScript(string script)
{
    import std.algorithm.iteration : splitter;
    import std.conv : to;
    import std.string : indexOf;

    Event[] out_;
    foreach (word; script.splitter(' '))
    {
        if (word.length < 4)
            continue;
        const verb = word[0];
        const rest = word[1 .. $];
        const comma = rest.indexOf(',');
        if (comma <= 0 || comma + 1 >= rest.length)
            continue;
        int x, y;
        try
        {
            x = rest[0 .. comma].to!int;
            y = rest[comma + 1 .. $].to!int;
        }
        catch (Exception)
            continue;

        PointerEvent p;
        p.pos = Point(x, y);
        switch (verb)
        {
            case 'm': p.action = PointerAction.move; break;
            case 'p':
                p.action = PointerAction.press;
                p.button = PointerButton.left;
                break;
            case 'r':
                p.action = PointerAction.release;
                p.button = PointerButton.left;
                break;
            case 'R':
                p.action = PointerAction.press;
                p.button = PointerButton.right;
                break;
            case 'X':
                p.action = PointerAction.release;
                p.button = PointerButton.right;
                break;
            default: continue;
        }
        out_ ~= Event(p);
    }
    return out_;
}

@("ui_gallery.render.pointerScriptDecodesEveryVerb")
@safe unittest
{
    const evs = pointerScript("m1,2 p3,4 r3,4 R10,20 X10,20");
    assert(evs.length == 5);

    PointerEvent[] ps;
    foreach (e; evs)
        e.match!((in PointerEvent p) { ps ~= p; }, (in _) {});
    assert(ps.length == 5);
    assert(ps[0].action == PointerAction.move && ps[0].pos == Point(1, 2));
    assert(ps[1].action == PointerAction.press
        && ps[1].button == PointerButton.left);
    assert(ps[3].button == PointerButton.right && ps[3].pos == Point(10, 20));

    // A typo costs its own event and nothing else.
    assert(pointerScript("m1,2 zzz p3,4").length == 2);
    assert(pointerScript("m1 mx,y m,4").length == 0);
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
    // `--render` names a page, so the keyboard starts IN it. A page's own
    // bindings are reachable only from the content region — that is the
    // "page gets first refusal" rule — so a render that stayed in the nav
    // list would silently drop every key `--keys` delivered, which is exactly
    // what it did: `--keys "o"` on the Overlays page did nothing at all.
    auto app = Gallery(GalleryState(page: req.page, region: Region.content));

    Event[] script;
    foreach (dchar c; req.keys)
        script ~= charEvent(c);
    // After the keys, so a script can open a page with a keystroke and then
    // point at what it opened.
    // `.idup` because `req` arrives `in` (scope const) and `splitter` does not
    // accept a scope range under dip1000 — the clash AGENTS.md records. One
    // copy of a CLI string, once per render.
    script ~= pointerScript(req.pointer.idup);

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

@("ui_gallery.render.anOpenOverlayReachesTheFrame")
@safe unittest
{
    // `POP8`: an anchored surface, asserted headlessly through the recorder
    // with no backend at all — which is the whole reason the arena is a value
    // the frame pass threads rather than something a backend owns.
    import sparkles.input : charEvent;
    import sparkles.ui.canvas : OpKind;
    import sparkles.ui.style : BoxSide;
    import sparkles.ui_app.host : RunConfig;
    import sparkles.ui_app.run_app : runAppRecorded;

    import gallery : Gallery;
    import registry : pageIndexOf;
    import state : Region;

    Gallery app;
    app.s.page = pageIndexOf("Overlays");
    app.s.region = Region.content;

    import sparkles.ui.geometry : Size;
    import sparkles.ui_app.record : RecordingHost;

    auto rec = runAppRecorded(app, RunConfig.init, [charEvent('o')],
        (ref RecordingHost h) { h.size = Size(110, 60); h.frameSeconds = 0; });

    assert(rec.frames.length >= 2, "one frame before the key, one after");
    const before = rec.frames[0].ops;
    const after = rec.frames[$ - 1].ops;

    static bool paints(in typeof(before) ops, string needle)
    {
        foreach (op; ops)
            if (op.kind == OpKind.textRun && op.text == needle)
                return true;
        return false;
    }

    // The host must be probing for exactly the signature the component
    // declares — a typo here is silent, because the introspection simply
    // finds nothing and the component renders with no overlays.
    import sparkles.ui.overlay.arena : OverlayArena;
    import sparkles.ui.widget : WidgetTree;
    static assert(__traits(compiles, {
        OverlayArena a = app.overlays(WidgetTree.init);
    }));
    static assert(__traits(compiles, app.overlaysSolved(OverlayArena.init)));
    assert(app.s.overlays.open, "the key opened the dropdown");
    assert(app.s.overlayGeometry.paintable,
        "and the solve placed it — a refused solve paints nothing");

    assert(!paints(before, "gruvbox"), "nothing is open before the key");
    assert(paints(after, "gruvbox"),
        "the dropdown's rows reach the frame once it opens");

    // `PLC10` end to end: the caret is on the edge the SOLVE resolved, not on
    // a hard-coded top. The view only declares that it wants one — where it
    // goes depends on where the overlay was actually placed, which is the
    // datum four backends used to guess at independently.
    const g = app.s.overlayGeometry;
    assert(g.arrowVisible, "the dropdown asked for a caret and got a cell");
    assert(g.arrowCell >= 1 && g.arrowCell <= g.rect.width - 2,
        "strictly inside the edge — never on a corner glyph");
    assert(g.side == BoxSide.bottom,
        "it hangs below its trigger, so its caret is on its own TOP edge");
}

@("ui_gallery.render.aContextMenuOpensWhereTheRightPressLanded")
@safe unittest
{
    // `POP8` again, for a surface no keystroke can reach — which is the whole
    // reason `--pointer` exists. And `ANC4`/`ANC5`: the anchor is the 1x1 cell
    // the press landed on, latched at PRESS because the terminal reports no
    // key release to latch at.
    import registry : pageIndexOf;
    import state : Region;

    Gallery app;
    app.s.page = pageIndexOf("Overlays");
    app.s.region = Region.content;

    auto script = pointerScript("R34,12");
    auto rec = runAppRecorded(app, RunConfig.init, script,
        (ref RecordingHost h) { h.size = Size(100, 40); h.frameSeconds = 0; });

    assert(app.s.overlays.open, "the right-press opened it");
    assert(app.s.overlays.at == Point(34, 12), "anchored where it landed");

    const g = app.s.overlayGeometry;
    assert(g.paintable);
    // One row below the anchor cell, not two: the extra row is the caret's
    // clearance, which is a placement INPUT (`PLC10`) folded in before the
    // constraint test — not a gap anybody typed.
    assert(g.rect.y == 14, "below the pressed cell, plus the caret's row");
    assert(g.arrowVisible, "and its caret points back at the press");

    import sparkles.ui.canvas : OpKind;
    bool sawItem;
    foreach (op; rec.frames[$ - 1].ops)
        if (op.kind == OpKind.textRun && op.text == "Rename")
            sawItem = true;
    assert(sawItem, "its rows reached the frame");
}

@("ui_gallery.render.anOverlayEscapesTheSectionThatOpenedIt")
@safe unittest
{
    // The V1 gate, as a painted frame: an overlay is not clipped by the box it
    // was opened from. On a single-surface backend that is not a z-index, it is
    // emission order — the arena is emitted after the root walk's clips close,
    // so the surface simply paints over whatever is under it (`LYR8`).
    import registry : pageIndexOf;
    import sparkles.ui.overlay.place : Fit;
    import state : Region;

    Gallery app;
    app.s.page = pageIndexOf("Overlays");
    app.s.region = Region.content;

    auto rec = runAppRecorded(app, RunConfig.init, pointerScript("R34,12"),
        (ref RecordingHost h) { h.size = Size(100, 40); h.frameSeconds = 0; });

    const g = app.s.overlayGeometry;
    assert(g.paintable);

    // The bordered section that opened it ends at row 15. A five-row menu
    // anchored inside it cannot fit, so if it is not clipped it must extend
    // past that edge — and it does, because it is not inside that box at all.
    assert(g.rect.bottom > 15,
        "the menu extends past the section that opened it");
    assert(g.fit != Fit.shrunk, "and it was not squeezed to fit inside one");

    import sparkles.ui.canvas : OpKind;
    size_t rows;
    foreach (op; rec.frames[$ - 1].ops)
        if (op.kind == OpKind.textRun
            && (op.text == "Open" || op.text == "Rename" || op.text == "Delete"))
            ++rows;
    assert(rows == 3, "and every row of it survived, unclipped");
}

@("ui_gallery.render.dismissalRunsThroughTheToolkitEvaluator")
@safe unittest
{
    // `DSM1`/`DSM2` with a real consumer: the page states a policy word, the
    // router offers a cause, and the toolkit answers with a reason the page
    // records. Nothing here paraphrases the requirement in an `if`.
    import registry : pageIndexOf;
    import state : CloseReason, Region;

    Gallery app;
    app.s.page = pageIndexOf("Overlays");
    app.s.region = Region.content;

    // `DSM9` first, because it is the one that bites: the press that OPENS a
    // menu is delivered against the frame before the menu existed, so an
    // evaluator without the one-frame exemption would close it on the same
    // press and the menu would never appear at all.
    auto opened = runAppRecorded(app, RunConfig.init, pointerScript("R34,12"),
        (ref RecordingHost h) { h.size = Size(100, 40); h.frameSeconds = 0; });
    assert(app.s.overlays.open, "opened, and not closed by its own press");
    assert(app.s.overlayGeometry.paintable);

    // A later press outside it closes it, and the reason travelled from the
    // toolkit rather than being invented at the call site.
    Gallery two;
    two.s.page = pageIndexOf("Overlays");
    two.s.region = Region.content;
    auto closed = runAppRecorded(two, RunConfig.init,
        pointerScript("R34,12 p70,30"),
        (ref RecordingHost h) { h.size = Size(100, 40); h.frameSeconds = 0; });
    assert(!two.s.overlays.open, "the outside press dismissed it");
    assert(two.s.overlays.lastReason == CloseReason.pressOutside,
        "and named why");

    import sparkles.ui.canvas : OpKind;
    static bool paints(in typeof(closed.frames[0].ops) ops, string needle)
    {
        foreach (op; ops)
            if (op.kind == OpKind.textRun && op.text == needle)
                return true;
        return false;
    }
    assert(paints(opened.frames[$ - 1].ops, "Rename"), "on screen while open");
    assert(!paints(closed.frames[$ - 1].ops, "Rename"), "and gone once closed");
}
