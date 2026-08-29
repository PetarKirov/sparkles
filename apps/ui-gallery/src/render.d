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

import std.array : appender;
import std.conv : to;

import sparkles.base.term_color : Color;
import sparkles.input : charEvent, Event;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.tui.render : paintFull;
import sparkles.ui.geometry : Size;
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
    paintFull(buf, grid);
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

/// The painted grid — the step both forms share, and the one that must be the
/// terminal's own painter rather than a lookalike.
Grid renderGrid(in RenderRequest req)
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
    Grid grid;
    grid.resize(cast(ushort) req.width, cast(ushort) req.height);
    grid.clearTo(CellStyle(fg: Color.fromRgb(th.pageFg),
        bg: Color.fromRgb(th.pageBg)));
    paintGrid(grid, th.pageBg, rec.lastOps);
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
