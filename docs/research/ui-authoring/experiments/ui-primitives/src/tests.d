/// Tests: pure vs hybrid (same app, same answers) and the custom layouts'
/// exact coordinates.
module tests;

import std.sumtype : match;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.writers : writeText;

import uicore;
import model;
import layouts;
static import views_pure, views_hybrid;

private immutable MemberRow[] rows1000 = () {
    MemberRow[] rs;
    foreach (i; 0 .. 1000)
    {
        char[6] d;
        foreach (j; 0 .. 6)
            d[5 - j] = cast(char) ('0' + (i / 10 ^^ j) % 10);
        rs ~= MemberRow("row" ~ d.idup, "value-" ~ d.idup);
    }
    return rs;
}();

package Settings settings() @safe pure nothrow
{
    Settings s;
    s.flags = [true, false, true, false, true, false, false, true];
    s.numbers = [4, 13, 120, 300, 1000, 80, 30, 8];
    s.name = "sparkles";
    return s;
}

/// Builds and lays out the settings page on library `lib` (80×40).
private Ui* settingsFrame(string lib)(Ui* ui)
{
    ui.reset();
    ui.expectMsg!SettingsMsg;
    const ids = IdsView(false, "", rows1000);
    const s = settings();
    static if (lib == "pure")
        cast(void) ui.frame(Env(), views_pure.settingsPage(*ui, s, ids));
    else
        cast(void) ui.frame(Env(), views_hybrid.settingsPage(*ui, s, ids));
    ui.layOut(80, 40);
    return ui;
}

private string semanticsText(ref const Ui ui) @safe
{
    string s;
    ui.semantics((uint depth, scope const(char)[] line) {
        foreach (_; 0 .. depth)
            s ~= "  ";
        s ~= line;
        s ~= "\n";
    });
    return s;
}

private void assertRect(ref const Ui ui, Node n, int x, int y, int w, int h, string what) @safe
{
    import std.format : format;
    const r = ui.rectOf(n);
    assert(r == Rect(x, y, w, h), format("%s: got %s, expected %s", what, r, Rect(x, y, w, h)));
}

@("primitives.settings.sameSemantics") @safe
unittest
{
    auto p = settingsFrame!"pure"(new Ui);
    auto h = settingsFrame!"hybrid"(new Ui);
    // Same app source, same semantics tree — roles, labels, states, rects.
    assert(semanticsText(*p) == semanticsText(*h), semanticsText(*p) ~ "\n----\n" ~ semanticsText(*h));
    // 8 toggles × 3, text input 1, scroll view 2 (content column, thumb), virtual list 2 spacers.
    assert(p.nodeCount - h.nodeCount == 29);
}

@("primitives.settings.findToggleAndPress") @safe
unittest
{
    static foreach (lib; ["pure", "hybrid"])
    {{
        ref ui = *settingsFrame!lib(new Ui);
        const t = ui.find(Role.switch_, "Word wrap");
        assert(t.isSet, lib);
        assert(ui.checkedOf(t) == Checked.on);
        const r = ui.rectOf(t);
        // A press on the knob (pure: the knob box, hybrid: the leaf) routes
        // to the toggle's message.
        const target = ui.pressTarget(r.x + 3, r.y);
        assert(target == t, lib);
        int got = -1;
        ui.dispatch!SettingsMsg(target, (SettingsMsg m) { m.match!((ToggleFlag f) { got = f.index; }, (_) {}); });
        assert(got == 2, lib);
    }}
}

@("primitives.settings.numberFieldPayload") @safe
unittest
{
    static foreach (lib; ["pure", "hybrid"])
    {{
        ref ui = *settingsFrame!lib(new Ui);
        const f = ui.find(Role.spinButton, "Font size");
        assert(f.isSet && ui[f].hasValue && ui[f].value == 13, lib);
        SetNumber got;
        ui.dispatch!SettingsMsg(f, (SettingsMsg m) { m.match!((SetNumber s) { got = s; }, (_) {}); }, 14);
        assert(got == SetNumber(1, 14), lib);
    }}
}

@("primitives.settings.focusOrder") @safe
unittest
{
    string[] order(Ui* ui)
    {
        string[] r;
        ui.focusOrder((Node n) { r ~= (ui.roleOf(n) == Role.textField ? "<field>" : ui.labelOf(n).idup); });
        return r;
    }
    auto p = order(settingsFrame!"pure"(new Ui));
    auto h = order(settingsFrame!"hybrid"(new Ui));
    assert(p == h);
    assert(p.length == 8 + 8 + 1 + 3);
    assert(p[0] == "Autosave" && p[8] == "Tab width" && p[16] == "<field>" && p[19] == "Cancel");
}

@("primitives.settings.virtualListScrolls") @safe
unittest
{
    static foreach (lib; ["pure", "hybrid"])
    {{
        auto up = new Ui;
        ref ui = *up;
        settingsFrame!lib(up);
        ui.commitStore();
        const list = ui.find(Role.list, null);
        assert(list.isSet, lib);
        const listRect = ui.rectOf(list);
        ui.store.put(ui[list].id).scrollY = 100;
        settingsFrame!lib(up);
        const first = ui.find(Role.button, "row000100");
        assert(first.isSet, lib);
        assertRect(ui, first, listRect.x, listRect.y, ui.rectOf(first).w, 1, lib ~ " first visible row");
        assert(!ui.find(Role.button, "row000099").isSet && !ui.find(Role.button, "row000112").isSet, lib);
        assert(ui.find(Role.button, "row000111").isSet, lib);
    }}
}

// ── custom layouts: the clock in every mechanism ──────────────────────────

/// Hour label k's expected top-left in a 21×21 clock (centre 10,10, radius
/// 9, label centred: x − width/2, y − 0): worked by hand in README.md.
private immutable int[2][12] clockExpected = [
    [9, 1], [15, 2], [18, 5], [19, 10], [18, 15], [15, 18],
    [10, 19], [5, 18], [2, 15], [1, 10], [1, 5], [4, 2],
];

private void assertClockLabels(ref const Ui ui, string what) @safe
{
    import std.format : format;
    foreach (k, l; hourLabels)
    {
        // the k-th text node with this label
        Node n;
        foreach (i; 0 .. cast(uint) ui.nodeCount)
            if (ui[Node(i)].kind == Kind.text && ui.textOf(Node(i)) == l)
                n = Node(i);
        assert(n.isSet, what ~ ": no label " ~ l);
        const r = ui.rectOf(n);
        assert([r.x, r.y] == clockExpected[k], format("%s: %s at %s,%s, expected %s", what, l, r.x, r.y, clockExpected[k]));
    }
}

@("layouts.clock.protocol") @safe
unittest
{
    ref ui = *new Ui;
    cast(void) ui.frame(Env(), ui.clockFace(hour: 3, minute: 0));
    ui.layOut(80, 40);
    assertClockLabels(ui, "(a)");
    // the paint layer (c) fills the face; its hands are draw commands
    DrawList dl;
    ui.paint(dl);
    const ops = dl.ops[];
    assert(ops[0].kind == OpKind.frame && [ops[0].x, ops[0].y, ops[0].w, ops[0].h] == [0, 0, 21, 21]);
    assert(ops[1].kind == OpKind.line && [ops[1].x, ops[1].y, ops[1].w, ops[1].h] == [10, 10, 14, 10]); // hour hand → 3
    assert(ops[2].kind == OpKind.line && [ops[2].x, ops[2].y, ops[2].w, ops[2].h] == [10, 10, 10, 2]);  // minute hand → 12
    // each label is a node: semantics, hit testing
    assert(ui.hitTest(19, 10) != Node(0) && ui.textOf(ui.hitTest(19, 10)) == "3");
}

@("layouts.clock.paintOnly") @safe
unittest
{
    ref ui = *new Ui;
    cast(void) ui.frame(Env(), ui.clockPainted());
    ui.layOut(80, 40);
    assert(ui.nodeCount == 1);
    DrawList dl;
    ui.paint(dl);
    assert(dl.length == 12);
    foreach (k, op; dl.ops[])
        assert(op.lit == hourLabels[k] && [op.x, op.y] == clockExpected[k]);
    // one hit target for the whole face
    assert(ui.hitTest(19, 10) == Node(0));
}

@("layouts.clock.layoutBuilder") @safe
unittest
{
    ref ui = *new Ui;
    cast(void) ui.frame(Env(), ui.clockBuilt());
    assert(ui.nodeCount == 1); // the labels do not exist until layout
    ui.layOut(80, 40);
    assert(ui.nodeCount == 1 + 1 + 12);
    assertClockLabels(ui, "(b')");
}

@("layouts.clock.lastFrameBounds") @safe
unittest
{
    ref ui = *new Ui;
    cast(void) ui.frame(Env(), ui.clockLagged());
    ui.layOut(80, 40);
    // frame one: the store has no size yet, every label lands near 0,0
    assert(ui.rectOf(Node(3)).x != clockExpected[1][0]);
    ui.commitStore();
    ui.reset();
    cast(void) ui.frame(Env(), ui.clockLagged());
    ui.layOut(80, 40);
    assertClockLabels(ui, "(b) frame two");
}

@("layouts.clock.anchored") @safe
unittest
{
    ref ui = *new Ui;
    cast(void) ui.frame(Env(), ui.clockAnchored());
    ui.layOut(80, 40);
    // fractions of the box, rounded: not the (a) clock's min(w, h)/2 − 1 radius
    assertRect(ui, Node(1), 10, 0, 2, 1, "12");
    assertRect(ui, Node(4), 19, 10, 1, 1, "3");
    assertRect(ui, Node(7), 10, 19, 1, 1, "6");
    assertRect(ui, Node(10), 0, 10, 1, 1, "9");
}

// ── the timeline and the calendar, end to end ─────────────────────────────

private immutable Event[] smallTimeline = [
    Event(0, 10, "a"), Event(5, 20, "b"), Event(12, 15, "long label"),
    Event(16, 18, "d"), Event(21, 30, "c"),
];

@("layouts.timeline.lanes") @safe
unittest
{
    ref ui = *new Ui;
    ui.expectMsg!CustomMsg;
    cast(void) ui.frame(Env(), timelineView(ui, smallTimeline, 0, 100, 100));
    ui.layOut(200, 50);
    assertRect(ui, Node(0), 0, 0, 100, 3, "timeline (3 lanes, measured)");
    // events are nodes 1, 3, 5, 7, 9 (each a box with its text)
    assertRect(ui, Node(1), 0, 0, 10, 1, "a");
    assertRect(ui, Node(3), 5, 1, 15, 1, "b");
    assertRect(ui, Node(5), 12, 0, 10, 1, "long label: its width, not its span");
    assertRect(ui, Node(7), 16, 2, 2, 1, "d: lane 2, past the label");
    assertRect(ui, Node(9), 21, 1, 9, 1, "c");
    assertRect(ui, Node(6), 12, 0, 10, 1, "long label's text");
    // a click on the label's tail reaches that event's message
    const t = ui.pressTarget(20, 0);
    assert(t == Node(5));
    long got = -1;
    ui.dispatch!CustomMsg(t, (CustomMsg m) { m.match!((OpenEvent e) { got = e.start; }); });
    assert(got == 12);
    assert(ui.find(Role.event, "long label") == Node(5));
}

private immutable CalEvent[] smallWeek = [
    CalEvent(0, 9 * 60, 10 * 60, "Standup"),
    CalEvent(0, 9 * 60 + 30, 11 * 60, "Review"),
    CalEvent(0, 10 * 60 + 30, 11 * 60 + 30, "Pairing"),
    CalEvent(0, 12 * 60, 13 * 60, "Lunch"),
    CalEvent(1, 9 * 60, 10 * 60, "Planning"),
];

@("layouts.calendar.overlapColumns") @safe
unittest
{
    ref ui = *new Ui;
    ui.expectMsg!CustomMsg;
    cast(void) ui.frame(Env(), calendarView(ui, smallWeek, 70, 2));
    ui.layOut(80, 40);
    const sched = ui.find(Role.calendar, "week");
    assertRect(ui, sched, 0, 1, 70, 24, "schedule (12 h × 2 rows, measured)");
    assertRect(ui, ui.find(Role.event, "Standup"), 0, 3, 5, 2, "Standup: column 0 of 2");
    assertRect(ui, ui.find(Role.event, "Review"), 5, 4, 5, 3, "Review: column 1 of 2");
    assertRect(ui, ui.find(Role.event, "Pairing"), 0, 6, 5, 2, "Pairing: column 0 again");
    assertRect(ui, ui.find(Role.event, "Lunch"), 0, 9, 10, 2, "Lunch: its own cluster");
    assertRect(ui, ui.find(Role.event, "Planning"), 10, 3, 10, 2, "Planning: Tuesday");
    // the title wraps in its column: "Standup" (7) in 5 cells → 2 rows
    const standup = ui.find(Role.event, "Standup");
    assertRect(ui, Node(ui.kidsOf(standup)[0]), 0, 3, 5, 2, "Standup's text, wrapped");
    // day headers share the width
    assertRect(ui, Node(ui.kidsOf(Node(1))[1]), 10, 0, 10, 1, "Tue");
}

@("layouts.calendar.keyedIdentity") @safe
unittest
{
    ref ui = *new Ui;
    ui.expectMsg!CustomMsg;
    cast(void) ui.frame(Env(), calendarView(ui, smallWeek, 70, 2));
    const lunch = ui[ui.find(Role.event, "Lunch")].id;
    ui.reset();
    cast(void) ui.frame(Env(), calendarView(ui, smallWeek[1 .. $], 70, 2));
    ui.layOut(80, 40);
    assert(ui[ui.find(Role.event, "Lunch")].id == lunch);
}

@("primitives.settings.scrollViewScrollsAndClips") @safe
unittest
{
    static foreach (lib; ["pure", "hybrid"])
    {{
        auto up = new Ui;
        ref ui = *up;
        settingsFrame!lib(up);
        // "History" (y 13) lies below the 12-row viewport (y 1–12): a press
        // there reaches the text field drawn at y 13, not the clipped row.
        assert(ui.rectOf(ui.find(Role.spinButton, "History")).y == 13, lib);
        assert(ui.pressTarget(18, 13) == ui.find(Role.textField, null), lib);
        ui.commitStore();
        const area = ui.find(Role.scrollArea, null);
        assert(ui.store.get(ui[area].id).contentH == 16, lib);
        ui.store.put(ui[area].id).scrollY = 5;
        settingsFrame!lib(up);
        assert(ui.rectOf(ui.find(Role.switch_, "Telemetry")).y == 1, lib);
        assert(ui.rectOf(ui.find(Role.spinButton, "History")).y == 8, lib);
        assert(ui.pressTarget(18, 8) == ui.find(Role.spinButton, "History"), lib);
        // the thumb: 12 × 12 / 16 = 9 rows, at 5 × 12 / 16 = 3 below the top
        DrawList dl;
        ui.paint(dl);
        bool thumb;
        foreach (op; dl.ops[])
            if (op.slot == Slot.thumb && op.x == 79)
                thumb = thumb || [op.y, op.h] == [1 + 3, 9];
        assert(thumb, lib);
    }}
}
