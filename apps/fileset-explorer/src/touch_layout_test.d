/// The touch layout, recorded (`FXU11`–`FXU13`, `FXU17`–`FXU20`, `FXU22`).
module touch_layout_test;

import std.algorithm.searching : canFind, countUntil;
import std.array : split;
import std.conv : text;
import std.string : indexOf;

import sparkles.build_primitives.fileset.emit : NixGlobs, Target;
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
    assert(lib - app_ == app.treeRowCells && app.rowCells >= 2, text(app_, " ", lib, " ", app.treeRowCells));
    // The tree is a dense list: 32 dp to a row, where a chip takes 48.
    assert(ExplorerApp.cellsFor(32, 16) == 2 && ExplorerApp.cellsFor(48, 16) == 3);
    assert(ExplorerApp.cellsFor(32, 20) == 2 && ExplorerApp.cellsFor(48, 20) == 3);
    assert(ExplorerApp.cellsFor(32, 33) == 1);

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

    // A phone's width crowds the chips, the prompt and the app bar, and
    // squeezes none of them away.
    const slim = Size(50, 40);
    const frame = renderFrame(*narrow, "", slim);
    foreach (line; frame.split('\n'))
        if (line.canFind("Clear"))
            foreach (label; ["|", "&", "−", "( )", "**", "\" \"", "#", "⌫"])
                assert(line.canFind(label), label ~ " is missing:\n" ~ line);
    assert(frame.canFind("❯ **"), frame);
    assert(frame.canFind("  2110 members") || frame.canFind("  6 members"), frame);
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

/// FXU17: a pill's box is its whole touch target, so the 32 dp it is drawn
/// at has room around its label.
@("fileset_explorer.FXU17.pillsFillTheirTargets")
@system unittest
{
    import sparkles.ui.widget : WidgetKind;

    auto app = make("**");
    RecordingHost h;
    h.size = tablet;
    const t = app.view(h);
    size_t pills;
    foreach (ref n; t.nodes)
        if (n.kind == WidgetKind.panel && n.hitId >= ExplorerApp.actionBase
            && n.hitId <= ExplorerApp.actionBase + ExplorerApp.Action.insert + 8)
        {
            assert(n.height.value == app.rowCells, text(n.hitId, ": ", n.height));
            assert(n.decoration.drawHeight == 32);
            ++pills;
        }
    assert(pills >= 10, text(pills, " pills"));
}

/// FXU18: each tap goes to the pane under it, whichever pane was tapped first.
@("fileset_explorer.FXU18.tapsFindTheirPane")
@system unittest
{
    auto app = make("**");
    const before = app.tv.rows.length;
    // The Stats pane first: it used to keep every later tap.
    const stats = find(*app, "symlinks", tablet);
    tap(*app, stats, tablet);
    assert(app.focus == Focus.side);
    tap(*app, find(*app, " src", tablet), tablet);
    assert(app.focus == Focus.tree);
    assert(app.tv.rows.length == before - 3, "the tap closed src");
    // And back: the tree first, then Stats.
    tap(*app, stats, tablet);
    assert(app.focus == Focus.side, "the tree kept the tap");
    assert(app.tv.rows.length == before - 3);
}

/// FXU19: a cheat sheet snippet's ▶ tries it against the directory.
@("fileset_explorer.FXU19.cheatSheetTries")
@system unittest
{
    auto app = make("**");
    if (app.helpDoc.root.children.length == 0)
        return; // no markdown grammar: no table to find
    runAppRecorded(*app, RunConfig.init, [keyEvent(Key.f1)], (ref RecordingHost h) @safe { h.size = tablet; });
    const at = find(*app, "src/*.d ▶", tablet);
    tap(*app, Point(at.x + 8, at.y), tablet);
    assert(app.query.text == "src/*.d", app.query.text);
    assert(app.helpShown, "the help stays");
    assert(app.shown.found.members.length == 3, text(app.shown.found.members.length));
}

/// FXU20: the Export tab builds the lines that show, not every line.
@("fileset_explorer.FXU20.exportBuildsWhatShows")
@system unittest
{
    import std.array : appender;

    import sparkles.ui.widget : WidgetKind;

    // A hundred and fifty literal paths: the gitignore has two lines for each.
    auto files = appender!string, query = appender!string;
    foreach (i; 0 .. 150)
    {
        files ~= text("f", i, ".d = x\n");
        query ~= text(i ? " | " : "", "/f", i, ".d");
    }
    auto app = new ExplorerApp(Root(literal: files[], name: "t"), query[]);
    app.layout = ExplorerApp.Layout.touch;
    app.exportTarget = Target.gitignore;
    tap(*app, find(*app, "Export", tablet), tablet);
    assert(app.exportShown && app.exportLines.length >= 150, text(app.exportLines.length, "\n",
        app.exported.code, app.exported.reason));

    // The rows the frame built for the export's lines: those that show.
    bool[string] lines;
    foreach (l; app.exportLines)
    {
        string s;
        foreach (sp; l)
            s ~= sp.text;
        lines[s] = true;
    }
    RecordingHost h;
    h.size = tablet;
    const t = app.view(h);
    size_t built;
    foreach (ref n; t.nodes)
        if (n.kind == WidgetKind.rich)
        {
            string s;
            foreach (sp; n.spans)
                s ~= sp.text;
            built += (s in lines) !is null;
        }
    assert(built > 10 && built <= tablet.height, text(built, " of ", app.exportLines.length, " lines built"));
    assert(app.exportScroll.content >= 150, "the scroll still spans every line");
}

/// FXU22: a line wider than the Export tab scrolls across, under a header
/// that stays.
@("fileset_explorer.FXU22.exportScrollsAcross")
@system unittest
{
    import std.array : replicate;

    import sparkles.input : WheelEvent;

    const name = "a".replicate(200) ~ ".d";
    auto app = new ExplorerApp(Root(literal: name ~ " = x\n", name: "t"), "/" ~ name);
    app.layout = ExplorerApp.Layout.touch;
    app.exportTarget = Target.gitignore;
    tap(*app, find(*app, "Export", tablet), tablet);
    assert(app.exportShown && app.exportWidth > 200, text(app.exportWidth));

    // A finger moving across, over the export's lines.
    const copy = find(*app, "Copy", tablet);
    WheelEvent across;
    across.pos = Point(copy.x - 10, copy.y + 4);
    across.precise = true;
    across.fdx = 30;
    across.fdy = 2;
    runAppRecorded(*app, RunConfig.init, [Event(across)], (ref RecordingHost h) @safe { h.size = tablet; });
    assert(app.exportScrollX.motion.whole == 30, text(app.exportScrollX.motion.whole));
    assert(app.exportScroll.motion.whole == 0, "more across than down: across only");
    const frame = renderFrame(*app, "", tablet);
    assert(frame.canFind("Copy") && frame.canFind("gitignore"), "the header stays:\n" ~ frame);
    assert(!frame.canFind("# Generated") && frame.canFind("r from: /aaaa"), "the lines start 30 columns in:\n" ~ frame);
}
