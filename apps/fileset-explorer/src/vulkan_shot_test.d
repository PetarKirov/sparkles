/**
The touch layout through the Vulkan canvas on a real driver, as a tablet
draws it: a recorded frame of each screen painted offscreen, so its pixels
can be read back (`FXU17`, `FXU19`).

Opt-in (`SPARKLES_VULKAN_READBACK=1`): it needs lavapipe and the validation
layer. With `$FILESET_EXPLORER_SHOTS` naming a directory, each frame is also
written there as a PNG, for a reader to look at.
*/
module vulkan_shot_test;

version (unittest):

import std.file : read, write;
import std.path : buildPath;
import std.process : environment;

import sparkles.base.term_color : RgbColor;
import sparkles.font : Ppem;
import sparkles.image.png : encodePng;
import sparkles.input : Event, Key, keyEvent;
import sparkles.test_runner.skip : skipTest;
import sparkles.ui.geometry : Size;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;
import sparkles.ui_vulkan.painter : FrameMetrics, TextMetrics;
import sparkles.ui_vulkan.testing : Canvas, readbackEnabled, readbackSkipReason, Rig;

import sparkles.fileset_tools.evaluate : Root;
import explorer : ExplorerApp;

// A tablet's cell at 12 points: 26 × 44 pixels, 16 dp tall at 2.75 pixels a dp.
private enum cellW = 26, cellH = 44;
private enum float density = 2.75f;
private enum cols = 120, rows = 44;

/// The explorer's frame after `script`, painted and read back: RGBA bytes.
ubyte[] shoot(Rig* rig, ref ExplorerApp app, in Event[] script)
{
    auto rec = runAppRecorded(app, RunConfig.init, script, (ref RecordingHost h) {
        h.size = Size(cols, rows);
        h.frameSeconds = 0;
    });
    rig.canvas.images(rec.imageRegistry);
    return rig.draw((ref Canvas c) { paint(c, rec.lastOps); },
        FrameMetrics(cellW: cellW, cellH: cellH, density: density), RgbColor(0, 0, 0));
}

/// Opens a rig the size of the frame, its cell font DejaVu Sans Mono.
Rig* openRig(string name)
{
    const dir = environment.get("SPARKLES_FONTS_PATH");
    assert(dir !is null, "SPARKLES_FONTS_PATH is unset: run inside `nix develop`");
    auto rig = new Rig;
    rig.open(name, cols * cellW, rows * cellH);
    const(ubyte)[][4] faces;
    faces[0] = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono.ttf"));
    faces[1] = cast(const(ubyte)[]) read(dir.buildPath("DejaVuSansMono-Bold.ttf"));
    faces[2] = faces[0];
    faces[3] = faces[1];
    assert(rig.canvas.cellFont(faces, Ppem.fromInteger(36).value,
        TextMetrics(ascent: 33, underlineY: 37, underlineHeight: 2, strikeY: 22)));
    return rig;
}

/// Writes `rgba` as `name`.png under `$FILESET_EXPLORER_SHOTS`, when it is set.
void keep(in ubyte[] rgba, string name)
{
    const dir = environment.get("FILESET_EXPLORER_SHOTS");
    if (dir.length)
        write(dir.buildPath(name ~ ".png"), encodePng(rgba, cols * cellW, rows * cellH));
}

/// The touch layout's screens, painted: the tree beside the help, and beside
/// the Export tab.
@("fileset_explorer.vulkan.touchScreens")
@system unittest
{
    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = openRig("fileset-explorer-touch");
    scope (success)
        rig.close();

    auto app = new ExplorerApp(Root(dir: "."), "**/*.md | **/dub.sdl");
    app.layout = ExplorerApp.Layout.touch;
    app.cellDp = cellH / density;
    keep(shoot(rig, *app, null), "stats");
    keep(shoot(rig, *app, [keyEvent(Key.f1)]), "help");
}

/// FXU24: a code fence's frame on a pixel target is one ring, as wide on its
/// sides as on its top and bottom, its surface filling its rounded corners.
/// Its language and its ▶ are badges centred on the ring's top line, filled
/// with the page's colour; the ▶ is at the right, a button outlined in green.
@("fileset_explorer.vulkan.FXU24.fenceFrame")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.math : abs;

    import sparkles.ui.canvas : FillRect, match, TextRun;
    import sparkles.ui.geometry : Rect;
    import sparkles.ui.pixel_geometry : insideGlyphFrame;

    if (!readbackEnabled)
        return skipTest(readbackSkipReason);
    auto rig = openRig("fileset-explorer-fence");
    scope (success)
        rig.close();

    // The help, scrolled to its first try block.
    auto app = new ExplorerApp(Root(dir: "."), "**/*.md | **/dub.sdl");
    app.layout = ExplorerApp.Layout.touch;
    app.cellDp = cellH / density;
    shoot(rig, *app, [keyEvent(Key.f1)]);
    assert(app.tries.length);
    const row = app.tryRowOf(app.tries[0].at);
    assert(row >= 0);
    app.helpScroll.motion.scrollTo(row > 2 ? row - 2 : 0, app.helpScroll.limit);
    auto rec = runAppRecorded(*app, RunConfig.init, null, (ref RecordingHost h) {
        h.size = Size(cols, rows);
        h.frameSeconds = 0;
    });
    rig.canvas.images(rec.imageRegistry);
    const rgba = rig.draw((ref Canvas c) { paint(c, rec.lastOps); },
        FrameMetrics(cellW: cellW, cellH: cellH, density: density), RgbColor(0, 0, 0));
    keep(rgba, "fence");

    // The ops: the ▶'s run, the fence ringed around it, the badges on its row.
    static bool inside(in Rect a, in Rect b)
        => a.x >= b.x && a.y >= b.y && a.x + a.width <= b.x + b.width && a.y + a.height <= b.y + b.height;
    Rect play;
    bool found;
    foreach (ref op; rec.lastOps)
        op.payload.match!((in TextRun t) {
            if (!found && t.text.canFind("▶"))
            {
                play = t.rect;
                found = true;
            }
        }, (_) {});
    assert(found, "no ▶ on the frame");
    FillRect ring, button, label;
    foreach (ref op; rec.lastOps)
        op.payload.match!((in FillRect f) {
            if (f.chrome is null || !f.chrome.border.any)
                return;
            if (!f.chrome.pixelsOnly && f.rect.y == play.y && f.rect.x <= play.x
                && play.x < f.rect.x + f.rect.width)
                ring = f;
            else if (f.chrome.pixelsOnly && inside(play, f.rect))
                button = f;
            else if (f.chrome.pixelsOnly && f.rect.y == play.y && label.chrome is null)
                label = f;
        }, (_) {});
    assert(ring.chrome !is null && ring.chrome.insideGlyphFrame, "the fence draws no ring");
    assert(button.chrome !is null, "the ▶ is in no badge");
    assert(label.chrome !is null && label.rect.x < button.rect.x,
        "the language is in no badge, left of the ▶");
    foreach (badge; [label, button])
        assert(badge.rect.y == ring.rect.y && badge.rect.height == 1 && badge.hasBg,
            text("a badge is the top row's, centred on the ring's line, filled: ", badge.rect));
    assert(button.bg != ring.bg, "a badge is filled with the page's colour, not the fence's");
    assert(button.chrome.border.color != label.chrome.border.color, "the ▶ is outlined as a button");
    const ringRight = ring.rect.x + ring.rect.width;
    assert(button.rect.x > ring.rect.x + ring.rect.width / 2 && button.rect.x + button.rect.width >= ringRight - 6,
        text("the ▶ is at the right: ", button.rect, " in ", ring.rect));

    // The pixels: the ring is one width on all four sides.
    const box = insideGlyphFrame(Rect(ring.rect.x * cellW, ring.rect.y * cellH,
        ring.rect.width * cellW, ring.rect.height * cellH), cellW, cellH);
    const W = cols * cellW;
    RgbColor at(int x, int y)
    {
        const i = (cast(size_t) y * W + x) * 4;
        return RgbColor(rgba[i], rgba[i + 1], rgba[i + 2]);
    }
    static int dist(RgbColor a, RgbColor b)
        => abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b);
    // Pixels across the line at (x, y), stepping (dx, dy), unlike both the
    // colour outside it and the colour inside: the ring, translucent, blended.
    int width(int x, int y, int dx, int dy)
    {
        const outside = at(x - 10 * dx, y - 10 * dy), inner = at(x + 10 * dx, y + 10 * dy);
        int n;
        foreach (k; -8 .. 9)
        {
            const c = at(x + k * dx, y + k * dy);
            if (dist(c, outside) > 6 && dist(c, inner) > 6)
                ++n;
        }
        return n;
    }
    const midX = box.x + box.width / 2, midY = box.y + box.height / 2;
    const top = width(midX, box.y, 0, 1), bottom = width(midX, box.y + box.height, 0, -1);
    const left = width(box.x, midY, 1, 0), right = width(box.x + box.width, midY, -1, 0);
    assert(top > 0 && abs(top - left) <= 1 && abs(top - right) <= 1 && abs(top - bottom) <= 1,
        text("the ring's widths: top ", top, ", bottom ", bottom, ", left ", left, ", right ", right));

    // The surface fills the top corners up to the ring: a little inside the
    // corner's arc is the fence's colour, not the page's.
    const fill = at(box.x + box.width / 2, box.y + 12);
    foreach (x; [box.x + 9, box.x + box.width - 10])
        assert(dist(at(x, box.y + 9), fill) <= 6,
            text("a top corner shows the page at x ", x, ": ", at(x, box.y + 9), " vs ", fill));

    // Inside a badge, on the ring's line and below it, is the page's colour:
    // the ring stops at the badge's outline, and the fence's surface with it.
    const page = at(box.x - cellW / 2 - 4, box.y + cellH);
    const bx = button.rect.x * cellW + 8;
    foreach (y; [box.y, box.y + cellH / 4])
        assert(dist(at(bx, y), page) <= 6, text("inside the ▶'s badge at y ", y, ": ", at(bx, y), " vs ", page));
}
