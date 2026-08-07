/**
Rendering one frame with no terminal session and no window (`--render`).

The catalog is a visual artifact, and the slowest way to look at one is to open
it. This drives the $(B same) `view` the real loop calls — through the recording
host, so nothing is special-cased — paints the resulting display list into a
cell grid, and hands back either ANSI or bare glyphs.

Two consumers, and the second is why it lives in a module of its own rather than
inside `app.d`: a person developing a page (`--render --page themes --keys ']]'`)
and the golden snapshots the catalog sweep compares against, which need the
glyph form and must run under `dub test`.
*/
module render;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input : charEvent, Event;
import sparkles.ui.geometry : Size;
import sparkles.ui.interp.cells : CellGrid;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_app.host : RunConfig;

import compat : RecordingHost, runAppRecorded;
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

/// The frame `req` describes, as ANSI (colours and all).
string renderAnsi(in RenderRequest req)
{
    auto grid = renderGrid(req);
    SmallBuffer!(char, 1 << 16) buf;
    grid.writeAnsi(buf);
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
{
    import std.array : appender;
    import std.conv : to;

    auto grid = renderGrid(req);
    auto out_ = appender!string;
    foreach (y; 0 .. req.height)
    {
        char[] line;
        foreach (x; 0 .. req.width)
        {
            const g = grid.cells[y * req.width + x].glyph;
            line ~= g == dchar.init || g == '\0' ? " " : g.to!string;
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

/// The painted cell grid — the step both forms share.
CellGrid renderGrid(in RenderRequest req)
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
    auto grid = CellGrid(req.width, req.height, th.pageFg, th.pageBg);
    paint(grid, rec.lastOps);
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
