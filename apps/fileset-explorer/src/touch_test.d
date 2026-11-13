/// Tapping and scrolling the explorer, as a finger does it (`FXU10`).
module touch_test;

import std.algorithm.searching : canFind, countUntil;
import std.array : split;
import std.conv : text;
import std.string : indexOf;
import std.math : isClose;

import sparkles.input : Event, match, PointerAction, PointerButton, PointerEvent, Point, WheelEvent;
import sparkles.input.gesture : GestureRecognizer, PointF;
import sparkles.input.events : isNoEvent;
import sparkles.build_primitives.fileset.emit : Target;
import sparkles.ui.geometry : Size;
import sparkles.ui_app.host : RunConfig;
import sparkles.ui_app.record : RecordingHost;
import sparkles.ui_app.run_app : runAppRecorded;

import sparkles.fileset_tools.evaluate : Root;
import explorer : ExplorerApp, Focus;
import render : renderFrame;

private enum screen = Size(100, 24);

// Three hundred files: far more than the tree's pane shows, and than a fling
// coasts through.
private ExplorerApp* longTree()
{
    import std.format : format;

    string literal;
    foreach (i; 0 .. 300)
        literal ~= format("f%02d.txt = x\n", i);
    return new ExplorerApp(Root(literal: literal, name: "t"), "**");
}

// Where `label` first shows on the frame of `app`, in cells.
private Point find(ref ExplorerApp app, string label)
{
    import std.utf : count;

    foreach (y, line; renderFrame(app, "", screen).split('\n'))
    {
        const at = line.indexOf(label);
        if (at >= 0)
            return Point(cast(int) line[0 .. at].count, cast(int) y);
    }
    assert(false, label ~ " is not on the frame");
}

private Event[] tap(Point at)
    => [Event(PointerEvent(PointerAction.press, PointerButton.left, at)),
        Event(PointerEvent(PointerAction.release, PointerButton.left, at))];

private auto run(ref ExplorerApp app, Event[] script)
{
    app.smoothScroll = true;
    return runAppRecorded(app, RunConfig.init, script, (ref RecordingHost h) @safe {
        h.size = screen;
        h.frameSeconds = 1.0f / 60;
    });
}

/// A tap on a tab shows its pane; a tap on the Export tab's ▶ steps the target.
@("fileset_explorer.FXU10.tapsSwitchTabs")
@system unittest
{
    auto app = longTree();
    run(*app, tap(find(*app, "Help")));
    assert(app.helpShown && app.focus == Focus.side);

    run(*app, tap(find(*app, "Export")));
    assert(app.exportShown && app.exportTarget == Target.nix);
    run(*app, tap(find(*app, " ▶")));
    assert(app.exportTarget != Target.nix, "▶ is the next target");

    run(*app, tap(find(*app, "Stats")));
    assert(!app.helpShown && !app.exportShown);

    // Above the dock is the query.
    run(*app, tap(Point(5, 2)));
    assert(app.focus == Focus.query);
}

/// A finger's drag moves the tree by exactly its distance, fraction and
/// all, and leaves the cursor where it was.
@("fileset_explorer.FXU10.dragFollowsTheFinger")
@system unittest
{
    auto app = longTree();
    const inTree = find(*app, "f00.txt");
    run(*app, [Event(WheelEvent(dy: 2, fdy: 2.5f, pos: inTree, precise: true))]);
    assert(isClose(app.treeScroll.motion.pos, 2.5), text(app.treeScroll.motion.pos));
    assert(app.tv.top == 2 && app.tv.sel == 0, text(app.tv.top, " ", app.tv.sel));
}

/// A wheel notch eases three rows on over a few frames rather than jumping.
@("fileset_explorer.FXU10.notchEases")
@system unittest
{
    auto app = longTree();
    const inTree = find(*app, "f00.txt");
    Event[] script = [Event(WheelEvent(dy: 1, pos: inTree))];
    foreach (_; 0 .. 40)
        script ~= Event.init;
    auto rec = run(*app, script);
    assert(rec.frames.length > 3);
    assert(isClose(app.treeScroll.motion.pos, 3), text(app.treeScroll.motion.pos));
}

/// A lifted finger flings: the recogniser's coasting tail carries the tree
/// past where the finger let go, and then it stops.
@("fileset_explorer.FXU10.flingCoasts")
@system unittest
{
    auto app = longTree();
    const inTree = find(*app, "f00.txt");

    // A finger drags up 9 rows of 10 px and lets go at speed.
    GestureRecognizer g;
    g.cfg.cellH = 10;
    g.cfg.fractional = true;
    Event[] dragged, coasted;
    void drain(ref Event[] into)
    {
        for (auto e = g.next(); !isNoEvent(e); e = g.next())
        {
            e.match!((ref WheelEvent w) { w.pos = inTree; }, (ref _) {});
            into ~= e;
        }
    }
    g.pointer(0, true, PointF(100, 400));
    g.tick(16);
    foreach (i; 0 .. 3)
    {
        g.pointer(0, true, PointF(100, 400 - 30 * (i + 1)));
        g.tick(16);
        drain(dragged);
    }
    g.pointer(0, false, PointF(100, 310));
    g.tick(16);
    drain(dragged);
    foreach (_; 0 .. 400)
    {
        g.tick(16);
        drain(coasted);
    }
    assert(!g.active, "the fling stopped");

    // The tree moves exactly as far as the recogniser said, both while the
    // finger was down and while it coasts after.
    double rows(in Event[] es)
    {
        double sum = 0;
        foreach (e; es)
            e.match!((in WheelEvent w) { sum += w.exactY; }, (in _) {});
        return sum;
    }
    assert(rows(dragged) >= 9, text(rows(dragged)));
    assert(rows(coasted) > 1, text("a fling coasts: ", rows(coasted)));
    run(*app, dragged);
    const released = app.treeScroll.motion.pos;
    assert(isClose(released, rows(dragged), 1e-3), text(released, " ", rows(dragged)));
    run(*app, coasted);
    assert(isClose(app.treeScroll.motion.pos, released + rows(coasted), 1e-3),
        text(app.treeScroll.motion.pos, " ", released + rows(coasted)));
    assert(app.tv.sel == 0, "scrolling never moves the cursor");
}

/// A key that moves the cursor out of view still brings the view to it.
@("fileset_explorer.FXU10.cursorKeepsTheView")
@system unittest
{
    import sparkles.input : Key, keyEvent;

    auto app = longTree();
    Event[] script = [keyEvent(Key.tab)];
    foreach (_; 0 .. 30)
        script ~= keyEvent(Key.down);
    foreach (_; 0 .. 40)
        script ~= Event.init;
    run(*app, script);
    assert(app.tv.sel == 30);
    assert(app.tv.top <= 30 && 30 < app.tv.top + app.tv.bodyRows, text(app.tv.top, " ", app.tv.bodyRows));
    assert(app.treeScroll.motion.frac == 0, "settled on a whole row");
}
