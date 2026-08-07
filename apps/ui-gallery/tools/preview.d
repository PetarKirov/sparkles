#!/usr/bin/env dub
/+ dub.sdl:
    name "ui_gallery_preview"
    dependency "sparkles:ui" path="../../.."
    dependency "sparkles:ui-app" path="../../.."
    dependency "sparkles:input" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    subConfiguration "sparkles:ui-app" "tui"
    sourcePaths "../src"
    importPaths "../src"
    excludedSourceFiles "../src/app.d"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
Renders one gallery frame to ANSI on stdout, with no terminal session.

The point is a $(B look) at a page without opening the app: the same
`present` the real loop calls, driven through the recording host, painted into a
cell grid and written out. Used while developing a page, and to produce the
screenshots the docs carry.

---
dub run --single tools/preview.d -- --page themes --keys "]]]" --width 100
---
*/
module ui_gallery_preview;

import std.conv : to;
import std.stdio : write, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;
import sparkles.input : charEvent, Event;
import sparkles.ui.geometry : Size;
import sparkles.ui.interp.cells : CellGrid;
import sparkles.ui.interp.immediate : paint;
import sparkles.ui_app.host : RunConfig;

import compat : RecordingHost, runAppRecorded;
import gallery : Gallery;
import registry : pageIndexOf, pages;
import state : GalleryState;

struct Params
{
    @CliOption("page|p", "The page to render, by name prefix or number.")
    string page;

    @CliOption("keys|k", "Keystrokes to deliver before rendering, e.g. \"]]j\".")
    string keys;

    @CliOption("width|w", "Surface width in cells.")
    int width = 96;

    @CliOption("height|h", "Surface height in cells.")
    int height = 32;

    @CliOption("plain", "Write the glyphs only, with no colour — for diffing.")
    bool plain;
}

int main(string[] args)
{
    const cli = args.parseCliArgs!Params(HelpInfo("ui-gallery-preview",
        "Render one gallery frame to ANSI, with no terminal session.", null));

    auto app = Gallery(GalleryState(page: pageIndexOf(cli.page)));

    Event[] script;
    foreach (dchar c; cli.keys)
        script ~= charEvent(c);

    auto rec = runAppRecorded(app, RunConfig.init, script,
        (ref RecordingHost h) { h.size = Size(cli.width, cli.height); });

    const ops = rec.lastOps;
    const th = app.theme;
    auto grid = CellGrid(cli.width, cli.height, th.pageFg, th.pageBg);
    paint(grid, ops);

    if (cli.plain)
    {
        // Glyphs only. A layout regression shows up here without a diff tool
        // having to reason about SGR runs.
        foreach (y; 0 .. cli.height)
        {
            char[] line;
            foreach (x; 0 .. cli.width)
            {
                const g = grid[x, y].glyph;
                line ~= g == dchar.init || g == '\0' ? ' ' : g.to!string;
            }
            writeln(line);
        }
        return 0;
    }

    SmallBuffer!(char, 1 << 16) buf;
    grid.writeAnsi(buf);
    write(buf[]);
    writeln();
    return 0;
}
