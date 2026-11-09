/**
One frame of the explorer as text, with no terminal (`FXU8`): what
`--render-plain` prints, what CI's run checks, and what the tutorial's
expected results are compared with (`FXT5`).
*/
module render;

import sparkles.base.term_color : Color;
import sparkles.input : charEvent, Event, Key, keyEvent;
import sparkles.tui.cell : CellStyle, Grid;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.gui_options : GuiOptions;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : appThemeOf, runAppRecorded;
import sparkles.ui_tui.grid_canvas : paintGrid;

import explorer : ExplorerApp;

/// A `--keys` character as the event a terminal delivers: tab, newline and
/// escape are those keys, and `\x01` is F1; everything else is typed.
Event keyOf(dchar c) @safe
{
    switch (c)
    {
        case '\t': return keyEvent(Key.tab);
        case '\n': return keyEvent(Key.enter);
        case '\x1b': return keyEvent(Key.escape);
        case '\b': return keyEvent(Key.backspace);
        case '\x01': return keyEvent(Key.f1);
        default: return charEvent(c);
    }
}

/// The frame of `app` after `keys`, at `size`, as text: one line per row,
/// trailing blanks dropped.
string renderFrame(ref ExplorerApp app, string keys, Size size, GuiOptions gui = GuiOptions.init)
{
    Event[] script;
    foreach (dchar c; keys)
        script ~= keyOf(c);
    auto rec = runAppRecorded(app, RunConfig(gui: gui), script, (ref RecordingHost h) @safe {
        h.size = size;
        h.frameSeconds = 0;
    });
    const th = appThemeOf(gui);
    Grid grid;
    grid.resize(cast(ushort) size.width, cast(ushort) size.height);
    grid.clearTo(CellStyle(fg: Color.fromRgb(th.pageFg), bg: Color.fromRgb(th.pageBg)));
    paintGrid(grid, th.pageBg, rec.lastOps);
    return gridText(grid);
}

/// A painted grid as its glyphs.
string gridText(in Grid grid) @safe
{
    string result;
    foreach (ushort y; 0 .. grid.rows)
    {
        string line;
        foreach (ushort x; 0 .. grid.cols)
        {
            const c = grid[x, y];
            if (c.width == 0)
                continue; // a wide glyph's second cell
            line ~= c.grapheme.length ? c.grapheme : " ";
        }
        size_t end = line.length;
        while (end > 0 && line[end - 1] == ' ')
            --end;
        result ~= line[0 .. end] ~ "\n";
    }
    return result;
}
