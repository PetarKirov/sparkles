/// The touch layout, recorded (`FXU11`–`FXU13`).
module touch_layout_test;

import std.algorithm.searching : canFind, countUntil;
import std.array : split;
import std.conv : text;
import std.string : indexOf;

import sparkles.build_primitives.fileset.emit : NixGlobs;
import sparkles.input : Event, Key, keyEvent, PointerAction, PointerButton, PointerEvent, Point;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import evaluate : Root;
import explorer : ExplorerApp, Focus;
import render : renderFrame;

private enum literal = "src/app.d = module app;\nsrc/lib.d = module lib;\nsrc/lib_test.d = test\n"
    ~ "docs/guide.md = # Guide\nREADME.md = hello\ndub.sdl = name \"x\"\n";

private ExplorerApp* make(string query)
{
    auto app = new ExplorerApp(Root(literal: literal, name: "t"), query);
    app.layout = ExplorerApp.Layout.touch;
    return app;
}

private string[] frameOf(ref ExplorerApp app, Size size) => renderFrame(app, "", size).split('\n');

// Where `label` first shows on the frame, in cells.
private Point find(ref ExplorerApp app, string label, Size size)
{
    import std.utf : count;

    foreach (y, line; frameOf(app, size))
    {
        const at = line.indexOf(label);
        if (at >= 0)
            return Point(cast(int) line[0 .. at].count, cast(int) y);
    }
    assert(false, label ~ " is not on the frame:\n" ~ renderFrame(app, "", size));
}

private void tap(ref ExplorerApp app, Point at, Size size)
{
    runAppRecorded(app, RunConfig.init, [Event(PointerEvent(PointerAction.press, PointerButton.left, at)),
        Event(PointerEvent(PointerAction.release, PointerButton.left, at))],
        (ref RecordingHost h) @safe { h.size = size; });
}

private enum tablet = Size(140, 40);

/// FXU11: no borders, no key hints, rows a touch target apart, and the
/// operator chips insert at the caret.
@("fileset_explorer.FXU11.touchFrame")
@system unittest
{
    auto app = make("src/*.d");
    const lines = frameOf(*app, tablet);
    const frame = renderFrame(*app, "", tablet);
    assert(!frame.canFind("╭") && !frame.canFind("Tab tree") && !frame.canFind("F1 help"), frame);
    assert(frame.canFind("Fileset explorer") && frame.canFind("Clear"), frame);
    size_t app_, lib;
    foreach (i, line; lines)
    {
        if (line.canFind(" app.d"))
            app_ = i;
        if (line.canFind(" lib.d"))
            lib = i;
    }
    assert(lib - app_ == app.rowCells && app.rowCells >= 2, text(app_, " ", lib, " ", app.rowCells));

    // `|` inserts ` | ` at the caret, at the query's end.
    auto chipAt = find(*app, "|", tablet);
    foreach (y, line; lines)
        if (line.canFind("Clear"))
            chipAt = Point(cast(int) line.indexOf("|"), cast(int) y);
    tap(*app, chipAt, tablet);
    assert(app.query.text == "src/*.d | ", app.query.text);
    assert(app.focus == Focus.query);
}

/// FXU12: side by side on a tablet, stacked on a narrow screen.
@("fileset_explorer.FXU12.tabletAndPhone")
@system unittest
{
    auto wide = make("**");
    const segments = find(*wide, "Stats", tablet), members = find(*wide, "Members", tablet);
    assert(segments.y == members.y && segments.x > members.x, text(segments, " ", members));

    auto narrow = make("**");
    const phone = Size(60, 60);
    const below = find(*narrow, "Stats", phone), tree = find(*narrow, "Members", phone);
    assert(below.y > tree.y + 4, text(below, " ", tree));
}

/// FXU13: a tap opens or closes a directory; collapse and expand all; the
/// ids; Nix's glob mode; Back leaves the help before quitting.
@("fileset_explorer.FXU13.touchInThePanes")
@system unittest
{
    auto app = make("**");
    const before = app.tv.rows.length;
    tap(*app, find(*app, " src", tablet), tablet);
    assert(app.tv.rows.length == before - 3, text(app.tv.rows.length, " of ", before));
    tap(*app, find(*app, " src", tablet), tablet);
    assert(app.tv.rows.length == before);

    tap(*app, find(*app, "Collapse all", tablet), tablet);
    assert(app.tv.rows.length < before);
    tap(*app, find(*app, "Expand all", tablet), tablet);
    assert(app.tv.rows.length == before);

    app.idsRequested = false;
    // Ids are computed live for a small fileset; the chip asks for them anyway.
    if (renderFrame(*app, "", tablet).canFind("Compute ids"))
    {
        tap(*app, find(*app, "Compute ids", tablet), tablet);
        assert(app.idsRequested);
    }

    tap(*app, find(*app, "Export", tablet), tablet);
    assert(app.exportShown);
    tap(*app, find(*app, "expand", tablet), tablet);
    assert(app.nixGlobs == NixGlobs.expand, text(find(*app, "expand", tablet), "\n", renderFrame(*app, "", tablet)));

    // Back: the help first, whatever has focus, and then the explorer.
    auto rec = runAppRecorded(*app, RunConfig.init, [keyEvent(Key.f1), keyEvent(Key.back)],
        (ref RecordingHost h) @safe { h.size = tablet; });
    assert(!app.helpShown && !rec.quitRequested, "Back left the help, and only that");
}
