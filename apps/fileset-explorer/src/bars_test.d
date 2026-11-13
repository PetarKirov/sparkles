/// The scrollbars and the pointer over the editor, recorded (`FXU14`, `FXU15`).
module bars_test;

import std.array : split;
import std.conv : text;
import std.string : indexOf;

import sparkles.base.term_control : PointerShape;
import sparkles.input : Event, PointerAction, PointerButton, PointerEvent, Point;
import sparkles.ui.geometry : Size;
import sparkles.ui.widget : WidgetKind;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import sparkles.fileset_tools.evaluate : Root;
import explorer : ExplorerApp;
import render : renderFrame;

private enum screen = Size(100, 24);

private ExplorerApp* longTree()
{
    import std.format : format;

    string literal;
    foreach (i; 0 .. 300)
        literal ~= format("f%02d.txt = x\n", i);
    return new ExplorerApp(Root(literal: literal, name: "t"), "**");
}

private auto run(ref ExplorerApp app, Event[] script)
    => runAppRecorded(app, RunConfig.init, script, (ref RecordingHost h) @safe { h.size = screen; });

private Event at(PointerAction action, Point p, PointerButton button = PointerButton.none)
    => Event(PointerEvent(action, button, p));

/// FXU14: a long tree draws a bar sized to it, and dragging its thumb to the
/// bottom scrolls the tree to its end.
@("fileset_explorer.FXU14.treeBar")
@system unittest
{
    auto app = longTree();
    RecordingHost h;
    h.size = screen;
    const t = app.view(h);
    bool found;
    foreach (ref n; t.nodes)
        if (n.kind == WidgetKind.scrollbar && n.hitId == ExplorerApp.barHitBase + ExplorerApp.Bar.tree)
        {
            found = true;
            assert(n.barContent == app.tv.rows.length && n.barViewport == app.tv.bodyRows,
                text(n.barContent, "/", n.barViewport, " for ", app.tv.rows.length, "/", app.tv.bodyRows));
        }
    assert(found, "the tree draws its bar");

    run(*app, null);
    const r = app.barRect(ExplorerApp.Bar.tree);
    assert(r.height == app.tv.bodyRows && r.width == 1, text(r));
    run(*app, [at(PointerAction.press, Point(r.x, r.y), PointerButton.left),
        at(PointerAction.drag, Point(r.x, r.y + r.height + 3), PointerButton.left),
        at(PointerAction.release, Point(r.x, r.y + r.height + 3), PointerButton.left)]);
    assert(app.tv.top == app.tv.rows.length - app.tv.bodyRows,
        text(app.tv.top, " of ", app.tv.rows.length - app.tv.bodyRows));
    assert(app.tv.sel == 0, "the bar leaves the cursor where it was");
}

/// FXU15: the I-beam over the query, a hand over a tab, the default over the
/// tree; a click on the query puts the caret under it.
@("fileset_explorer.FXU15.pointerOverTheEditor")
@system unittest
{
    auto app = longTree();
    run(*app, null);
    const q = app.queryArea;
    assert(q.height > 0, "the query's lines are drawn");
    Point help;
    foreach (y, line; renderFrame(*app, "", screen).split('\n'))
        if (line.indexOf("Help") >= 0 && help == Point.init)
        {
            import std.utf : count;

            help = Point(cast(int) line[0 .. line.indexOf("Help")].count, cast(int) y);
        }
    const r = app.barRect(ExplorerApp.Bar.tree);
    auto rec = run(*app, [at(PointerAction.move, Point(q.x + 3, q.y)), at(PointerAction.move, help),
        at(PointerAction.move, Point(r.x - 5, r.y + 2))]);
    assert(rec.shapes == [PointerShape.text, PointerShape.pointer, PointerShape.default_], text(rec.shapes));

    // The fifth column: past the two-cell prompt, before the third character.
    run(*app, [at(PointerAction.press, Point(q.x + 4, q.y), PointerButton.left),
        at(PointerAction.release, Point(q.x + 4, q.y), PointerButton.left)]);
    assert(app.query.state.selection.primary.head == 2, text(app.query.state.selection.primary.head));
}
