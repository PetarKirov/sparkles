/**
Build and layout cost: pure vs hybrid on the Stats pane and the settings
page; the (a) timeline and calendar next to a plain column of the same events.
*/
module bench;

import std.format : format;
import std.algorithm : sort;

import sparkles.test_runner.attributes : benchmark;
import sparkles.test_runner.bench : benchCase, blackBox, Metric, Unit;

import uicore;
import model;
import layouts;
static import views_pure, views_hybrid;

/// Roots for the cases' closures: the runner keeps registered cases where
/// the GC does not scan them (see the lazy demo's README).
private __gshared const(void)*[] keepAlive;

private MemberRow[] makeRows(size_t n)
{
    auto rs = new MemberRow[n];
    foreach (i, ref r; rs)
        r = MemberRow(format("row%06d", i), format("value-%06d", i));
    return rs;
}

private Event[] makeTimeline(size_t n)
{
    auto es = new Event[n];
    foreach (i, ref e; es)
        e = Event(i * 7, i * 7 + 5 + (i * 37) % 40, format("ev%05d", i));
    return es;
}

private CalEvent[] makeWeek(size_t n)
{
    auto es = new CalEvent[n];
    foreach (i, ref e; es)
    {
        const start = 8 * 60 + cast(int) ((i * 53) % 660) / 15 * 15;
        e = CalEvent(cast(int) (i % 7), start, start + 30 + cast(int) ((i * 17) % 4) * 30, format("meeting %s", i));
    }
    es.sort!((a, b) => a.day != b.day ? a.day < b.day : a.start < b.start);
    return es;
}

/// One case's state, on the heap.
private struct Case
{
    Ui ui;
    void delegate(ref Ui) build;
    int w, h;
    ulong hash;
    size_t nodes;
}

private void register(string name, string view, string[string] labels, Case* c)
{
    // the reference: one build + layout, untimed
    c.build(c.ui);
    c.ui.layOut(c.w, c.h);
    c.hash = c.ui.layoutHash;
    c.nodes = c.ui.nodeCount;

    auto build = () {
        c.ui.reset();
        c.build(c.ui);
        return blackBox(c.ui.nodeCount);
    };
    auto layout = () {
        c.ui.layOut(c.w, c.h);
        return blackBox(c.ui.nodeCount);
    };
    auto both = () {
        c.ui.reset();
        c.build(c.ui);
        c.ui.layOut(c.w, c.h);
        return blackBox(c.ui.nodeCount);
    };
    auto checkBuilt = (ref size_t n) {
        if (n != c.nodes)
            throw new Exception(format("%s/%s: %s nodes, expected %s", name, view, n, c.nodes));
    };
    auto checkLaid = (ref size_t n) {
        checkBuilt(n);
        if (c.ui.layoutHash != c.hash)
            throw new Exception(format("%s/%s: layout differs", name, view));
    };
    keepAlive ~= [cast(const(void)*) c, build.ptr, layout.ptr, both.ptr, checkBuilt.ptr, checkLaid.ptr];
    foreach (pass, timed; ["build": build, "layout": layout, "build+layout": both])
    {
        auto l = labels.dup;
        l["view"] = view;
        l["pass"] = pass;
        l["nodes"] = format("%s", c.nodes);
        benchCase(name: name, labels: l, timed: timed, after: pass == "build" ? checkBuilt : checkLaid,
            metrics: [Metric(Unit("node"), c.nodes, Metric.Mode.rate)]);
    }
}

@("ui.primitives") @benchmark @system
unittest
{
    const rows = makeRows(1000);
    auto stats = IdsView(true, "ab", rows);
    Settings s;
    s.flags = [true, false, true, false, true, false, false, true];
    s.numbers = [4, 13, 120, 300, 1000, 80, 30, 8];
    s.name = "sparkles";

    foreach (lib; ["pure", "hybrid"])
    {
        auto c = new Case;
        c.w = 120;
        c.h = 4000;
        c.build = lib == "pure"
            ? (ref Ui ui) { ui.expectMsg!StatsMsg; cast(void) ui.frame(Env(), views_pure.statsPane(ui, Stats(true, 300), stats)); }
            : (ref Ui ui) { ui.expectMsg!StatsMsg; cast(void) ui.frame(Env(), views_hybrid.statsPane(ui, Stats(true, 300), stats)); };
        register(lib, "stats-1000", ["group": "primitives"], c);

        auto d = new Case;
        d.w = 80;
        d.h = 40;
        d.build = lib == "pure"
            ? (ref Ui ui) { ui.expectMsg!SettingsMsg; cast(void) ui.frame(Env(), views_pure.settingsPage(ui, s, stats)); }
            : (ref Ui ui) { ui.expectMsg!SettingsMsg; cast(void) ui.frame(Env(), views_hybrid.settingsPage(ui, s, stats)); };
        register(lib, "settings", ["group": "primitives"], d);
    }
}

@("ui.customLayout") @benchmark @system
unittest
{
    const timeline = makeTimeline(10_000);
    const week = makeWeek(200);
    auto weekAsEvents = new Event[week.length];
    foreach (i, e; week)
        weekAsEvents[i] = Event(e.day * 10_000 + e.start, e.day * 10_000 + e.end, e.title);
    const t1 = timeline[$ - 1].end + 1;

    auto a = new Case;
    a.w = 4000;
    a.h = 100;
    a.build = (ref Ui ui) { ui.expectMsg!CustomMsg; cast(void) ui.frame(Env(), timelineView(ui, timeline, 0, t1, 4000)); };
    register("custom (a)", "timeline-10000", ["group": "custom"], a);

    auto b = new Case;
    b.w = 4000;
    b.h = 100;
    b.build = (ref Ui ui) { ui.expectMsg!CustomMsg; cast(void) ui.frame(Env(), eventColumn(ui, timeline, 4000)); };
    register("column", "timeline-10000", ["group": "custom"], b);

    auto c = new Case;
    c.w = 140;
    c.h = 60;
    c.build = (ref Ui ui) { ui.expectMsg!CustomMsg; cast(void) ui.frame(Env(), calendarView(ui, week, 140, 4)); };
    register("custom (a)", "calendar-200", ["group": "custom"], c);

    auto d = new Case;
    d.w = 140;
    d.h = 60;
    d.build = (ref Ui ui) { ui.expectMsg!CustomMsg; cast(void) ui.frame(Env(), eventColumn(ui, weekAsEvents, 140)); };
    register("column", "calendar-200", ["group": "custom"], d);
}
