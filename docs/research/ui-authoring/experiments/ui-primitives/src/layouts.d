/**
Custom layouts, by mechanism:

- (a) **layout protocol**: `ClockLayout`, `TimelineLayout`, `CalendarLayout`
    — POD structs with `static arrange` (and `measure`), given to
    `box(custom: ui.layout(L(…)))`; their children are ordinary nodes.
- (c) **paint-only**: `ClockFace` (hands and rim behind the (a) clock's
    labels), `CalendarGrid`, and `ClockPainted` (the whole clock painted, no
    nodes for the labels).
- (b) **build-time placement**: `clockBuilt` (`layoutBuilder`: built during
    layout, once the size is known) and `clockLagged` (last frame's size from
    the element store, Clay-style), both floating their labels.
- (d) **anchored placement** (a built-in `Dir.anchor`): `clockAnchored`.
*/
module layouts;

import uicore;
import widgets_common : column, row;

/// A child the layout stretches over its whole content box (a paint layer).
enum LayoutData fill = LayoutData(int.min);

private bool isFill(in Child c) @safe pure nothrow @nogc => c.data.a == int.min;

/// sin and cos of k·30°, ×10 000 (exact integers: no `std.math` rounding).
private static immutable int[12] sin30 = [0, 5000, 8660, 10_000, 8660, 5000, 0, -5000, -8660, -10_000, -8660, -5000];
/// ditto
private static immutable int[12] cos30 = [10_000, 8660, 5000, 0, -5000, -8660, -10_000, -8660, -5000, 0, 5000, 8660];

/// The 12 hour labels, 12 first.
static immutable string[12] hourLabels = ["12", "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"];
/// ditto, as indices (for views that need `k`).
static immutable int[12] hourIndex = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];

/// Where hour `k`'s label centre goes in a `w`×`h` box: radius
/// `min(w, h) / 2 - inset`, clockwise from the top.
int[2] hourPoint(int k, int w, int h, int inset) @safe pure nothrow @nogc
{
    const r = (w < h ? w : h) / 2 - inset;
    return [w / 2 + divRound(r * sin30[k], 10_000), h / 2 - divRound(r * cos30[k], 10_000)];
}

// ── (a) the clock face ─────────────────────────────────────────────────────

/// Mechanism (a): every non-`fill` child, in order, centred on hour `k`.
struct ClockLayout
{
    int inset = 1;

    static void arrange(in ClockLayout p, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)
        @safe pure nothrow @nogc
    {
        int k;
        foreach (ref c; kids)
        {
            if (c.isFill)
            {
                c.x = 0;
                c.y = 0;
                c.w = inner.w;
                c.h = inner.h;
                continue;
            }
            const pt = hourPoint(k++ % 12, inner.w, inner.h, p.inset);
            c.x = pt[0] - c.w / 2;
            c.y = pt[1] - c.h / 2;
        }
    }
}

/// Mechanism (c) behind (a): the rim and the hands, painted.
struct ClockFace
{
    int hour, minute; // the hands; minute to 5-minute resolution
    int inset = 1;

    static void paint(in ClockFace p, Rect r, ref DrawList list) @safe pure nothrow @nogc
    {
        list.frame(r, Slot.border);
        const cx = r.x + r.w / 2, cy = r.y + r.h / 2;
        const rad = (r.w < r.h ? r.w : r.h) / 2 - p.inset;
        const hk = p.hour % 12, mk = (p.minute / 5) % 12;
        list.line(cx, cy, cx + divRound(rad / 2 * sin30[hk], 10_000), cy - divRound(rad / 2 * cos30[hk], 10_000), Slot.accent);
        list.line(cx, cy, cx + divRound((rad - 1) * sin30[mk], 10_000), cy - divRound((rad - 1) * cos30[mk], 10_000), Slot.body);
    }
}

/// The clock in mechanism (a) + (c): a painted face, 12 real text labels.
Node clockFace(ref Ui ui, NamedOnly _ = NamedOnly.init, int hour = 0, int minute = 0,
    Sizing w = Sizing.fixed(21), Sizing h = Sizing.fixed(21)) @safe pure nothrow @nogc
    => ui.box(layout: Lay(w: w, h: h), custom: ui.layout(ClockLayout(inset: 1)),
        sem: Sem(role: Role.clock), label: "clock", children:
        ui.custom(paint: ui.painter(ClockFace(hour, minute)), data: fill),
        hourLabels[].toUi(ui).mapByIndex!(l => ui.text(text: l)));

// ── (c) alone: the whole clock painted ─────────────────────────────────────

/// Mechanism (c) only: labels are draw commands, not nodes — no
/// semantics, no hit target per label, measured by the painter itself.
struct ClockPainted
{
    int inset = 1;

    static void paint(in ClockPainted p, Rect r, ref DrawList list) @safe pure nothrow @nogc
    {
        foreach (k; 0 .. 12)
        {
            const pt = hourPoint(k, r.w, r.h, p.inset);
            const w = cast(int) cells(hourLabels[k]);
            list.ops ~= DrawOp(OpKind.text, Slot.body, r.x + pt[0] - w / 2, r.y + pt[1], w, 1, lit: hourLabels[k]);
        }
    }
}

/// ditto
Node clockPainted(ref Ui ui) @safe pure nothrow @nogc
    => ui.custom(paint: ui.painter(ClockPainted(1)), w: Sizing.fixed(21), h: Sizing.fixed(21),
        sem: Sem(role: Role.clock), label: "clock");

// ── (b) build-time placement ───────────────────────────────────────────────

struct ClockParams
{
    int inset = 1;
}

/// The labels as floating text at positions computed in the view from
/// `avail` — the view must measure each label itself (`cells`).
private Node clockLabels(ref Ui ui, int w, int h, int inset) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.stack, w: Sizing.grow, h: Sizing.grow), children:
        hourIndex[].toUi(ui).mapByIndex!(k => ui.text(text: hourLabels[k],
            floating: Floating(active: true,
                x: cast(short) (hourPoint(k, w, h, inset)[0] - cast(int) cells(hourLabels[k]) / 2),
                y: cast(short) hourPoint(k, w, h, inset)[1]))));

private Node clockBuild(ref Ui ui, in ClockParams p, Size avail) @safe pure nothrow @nogc
    => clockLabels(ui, avail.w, avail.h, p.inset);

/// (b'): `layoutBuilder` — the labels are built during layout.
Node clockBuilt(ref Ui ui) @safe pure nothrow @nogc
    => ui.layoutBuilder!clockBuild(params: ClockParams(1),
        layout: Lay(w: Sizing.fixed(21), h: Sizing.fixed(21)), sem: Sem(role: Role.clock));

/// (b): last frame's size, from the element store (wrong on frame one).
Node clockLagged(ref Ui ui, NamedOnly _ = NamedOnly.init, Sizing w = Sizing.fixed(21),
    Sizing h = Sizing.fixed(21)) @safe pure nothrow @nogc
    => clockLaggedAt(ui, ui.peekState, w, h);

private Node clockLaggedAt(ref Ui ui, in ElemState s, Sizing w, Sizing h) @safe pure nothrow @nogc
    => ui.box(layout: Lay(w: w, h: h), sem: Sem(role: Role.clock), label: "clock", children:
        clockLabels(ui, s.lastW, s.lastH, 1));

// ── (d) anchored placement ─────────────────────────────────────────────────

/// Radius as a fraction of the box: 9/21 ≈ 0.4286.
private enum anchorRadius = 4286;

/// Mechanism (d): each label's centre at a fraction of the box; the core
/// does the arithmetic, the view only data → fractions.
Node clockAnchored(ref Ui ui) @safe pure nothrow @nogc
    => ui.box(layout: Lay(dir: Dir.anchor, w: Sizing.fixed(21), h: Sizing.fixed(21)),
        sem: Sem(role: Role.clock), label: "clock", children:
        hourIndex[].toUi(ui).mapByIndex!(k => ui.text(text: hourLabels[k],
            data: anchorAt(5000 + divRound(sin30[k] * anchorRadius, 10_000),
                5000 - divRound(cos30[k] * anchorRadius, 10_000)))));

// ── (a) a timeline with lane stacking ──────────────────────────────────────

/// Mechanism (a): child `i` (data `a` = start, `b` = end, sorted by start)
/// at x = f(start); it occupies max(its time span, its measured width) and
/// goes into the first lane free there — so a long label never overlaps the
/// next event, which a data-only lane assignment cannot know.
struct TimelineLayout
{
    long t0, t1;
    int laneHeight = 1, laneGap = 0;

    enum maxLanes = 64;

    private static int xOf(in TimelineLayout p, long t, int w) @safe pure nothrow @nogc
        => cast(int) ((t - p.t0) * w / (p.t1 - p.t0));

    /// Lanes at width `w`; places the children too when `kids` is mutable.
    private static int stack(K)(in TimelineLayout p, int w, K kids) @safe pure nothrow @nogc
    {
        int[maxLanes] laneEnd;
        int lanes;
        foreach (ref c; kids)
        {
            const x = xOf(p, c.data.a, w);
            const span = xOf(p, c.data.b, w) - x;
            const cw = span > c.fitW ? span : c.fitW;
            int l;
            while (l < lanes && laneEnd[l] > x)
                l++;
            assert(l < maxLanes, "the timeline has more lanes than it can stack");
            if (l == lanes)
                lanes++;
            laneEnd[l] = x + cw;
            static if (is(K == Child[]))
            {
                c.x = x;
                c.y = l * (p.laneHeight + p.laneGap);
                c.w = cw;
                c.h = p.laneHeight;
            }
        }
        return lanes;
    }

    static Size measure(in TimelineLayout p, Constraints c, scope const(Child)[] kids) @safe pure nothrow @nogc
    {
        const w = c.boundedW ? c.maxW : cast(int) (p.t1 - p.t0);
        const lanes = stack(p, w, kids);
        return Size(w, lanes ? lanes * p.laneHeight + (lanes - 1) * p.laneGap : 0);
    }

    static void arrange(in TimelineLayout p, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)
        @safe pure nothrow @nogc
    {
        cast(void) stack(p, inner.w, kids);
    }
}

struct Event
{
    long start, end;
    string label;
}

/// One event as a node: hit-testable, with semantics and a message.
Node eventBox(ref Ui ui, in Event e, MsgRef onPress) @safe pure nothrow @nogc
    => ui.box(bg: Slot.event, data: LayoutData(cast(int) e.start, cast(int) e.end),
        sem: Sem(role: Role.event, merge: true), onPress: onPress, children:
        ui.text(text: e.label, wrap: Wrap.none));

// ── (a) a calendar schedule with overlap columns ───────────────────────────

/**
Mechanism (a): children carry `a` = day, `b` = start, `c` = end (minutes
from midnight), sorted by (day, start); a `fill` child spans the content.
Each day's events split into clusters of transitively overlapping ones; a
cluster's events take the first free column, and share the day's width
evenly between the cluster's columns.
*/
struct CalendarLayout
{
    int days = 7, dayStart = 8 * 60, dayEnd = 20 * 60, rowsPerHour = 2;

    enum maxColumns = 32;

    static Size measure(in CalendarLayout p, Constraints c, scope const(Child)[] kids) @safe pure nothrow @nogc
        => Size(c.boundedW ? c.maxW : p.days * 10, (p.dayEnd - p.dayStart) * p.rowsPerHour / 60);

    static void arrange(in CalendarLayout p, Size inner, scope Child[] kids, scope ref LayoutCtx ctx)
        @safe pure nothrow @nogc
    {
        auto col = ctx.ints(kids.length);
        int[maxColumns] colEnd;
        int cols, clusterEnd = int.min, day = -1;
        size_t clusterStart;

        void finish(size_t upTo)
        {
            foreach (j; clusterStart .. upTo)
            {
                ref c = kids[j];
                if (c.isFill)
                    continue;
                const d = c.data.a;
                const x0 = d * inner.w / p.days, x1 = (d + 1) * inner.w / p.days;
                c.x = x0 + col[j] * (x1 - x0) / cols;
                c.w = x0 + (col[j] + 1) * (x1 - x0) / cols - c.x;
            }
        }

        foreach (i, ref c; kids)
        {
            if (c.isFill)
            {
                c.x = 0;
                c.y = 0;
                c.w = inner.w;
                c.h = inner.h;
                continue;
            }
            if (c.data.a != day || c.data.b >= clusterEnd)
            {
                finish(i);
                clusterStart = i;
                cols = 0;
                clusterEnd = int.min;
                day = c.data.a;
            }
            int k;
            while (k < cols && colEnd[k] > c.data.b)
                k++;
            assert(k < maxColumns, "too many overlapping events");
            if (k == cols)
                cols++;
            colEnd[k] = c.data.c;
            col[i] = k;
            if (c.data.c > clusterEnd)
                clusterEnd = c.data.c;
            c.y = (c.data.b - p.dayStart) * p.rowsPerHour / 60;
            const h = (c.data.c - c.data.b) * p.rowsPerHour / 60;
            c.h = h > 0 ? h : 1;
        }
        finish(kids.length);
    }
}

/// The hour lines behind the events (c).
struct CalendarGrid
{
    int hours, rowsPerHour;

    static void paint(in CalendarGrid p, Rect r, ref DrawList list) @safe pure nothrow @nogc
    {
        foreach (h; 0 .. p.hours + 1)
            list.line(r.x, r.y + h * p.rowsPerHour, r.x + r.w, r.y + h * p.rowsPerHour, Slot.grid);
    }
}

struct CalEvent
{
    int day, start, end;
    string title;
}

/// One calendar event: its title wraps in its column.
Node calEventBox(ref Ui ui, in CalEvent e, MsgRef onPress) @safe pure nothrow @nogc
    => ui.box(bg: Slot.event, data: LayoutData(e.day, e.start, e.end),
        sem: Sem(role: Role.event, merge: true), onPress: onPress, children:
        ui.text(text: e.title));

// ── the views ──────────────────────────────────────────────────────────────

struct OpenEvent { long start; }
alias CustomMsg = imported!"std.sumtype".SumType!(OpenEvent);

/// A timeline over `[t0, t1)`, `width` cells wide; its height is measured.
Node timelineView(ref Ui ui, in Event[] events, long t0, long t1, int width) @safe pure nothrow @nogc
    => ui.box(layout: Lay(w: Sizing.fixed(width)), custom: ui.layout(TimelineLayout(t0, t1)),
        sem: Sem(role: Role.timeline), label: "timeline", children:
        events.toUi(ui).mapKeyed!(e => e.start, e => ui.eventBox(e, ui.on(CustomMsg(OpenEvent(e.start))))));

/// A week: day headers in a row, then the schedule (grid painted, events laid out).
Node calendarView(ref Ui ui, in CalEvent[] events, int width, int rowsPerHour) @safe pure nothrow @nogc
    => ui.column(w: Sizing.fixed(width), children:
        ui.row(w: Sizing.grow, children:
            weekDays[].toUi(ui).mapByIndex!(d => ui.text(text: d, w: Sizing.grow))),
        ui.box(layout: Lay(w: Sizing.grow), custom: ui.layout(CalendarLayout(rowsPerHour: rowsPerHour)),
            sem: Sem(role: Role.calendar), label: "week", children:
            ui.custom(paint: ui.painter(CalendarGrid(12, rowsPerHour)), data: fill),
            events.toUi(ui).mapKeyed!(e => e.day * 10_000 + e.start,
                e => ui.calEventBox(e, ui.on(CustomMsg(OpenEvent(e.start)))))));

static immutable string[7] weekDays = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// The comparison tree: the same events as a plain column of rows.
Node eventColumn(ref Ui ui, in Event[] events, int width) @safe pure nothrow @nogc
    => ui.column(w: Sizing.fixed(width), children:
        events.toUi(ui).mapKeyed!(e => e.start, e => ui.eventBox(e, ui.on(CustomMsg(OpenEvent(e.start))))));
