#!/usr/bin/env dub
/+ dub.sdl:
    name "anchored_overlays_dismissal_policy"
    targetPath "build"
    dependency "sparkles:ui" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Dismissal as **one value**: a flags word ANDed with a router-offered cause.
 *
 * The survey found dismissal decomposed into three separable things that most
 * implementations tangle — a POLICY (which causes may close this surface), a
 * CAUSE detector (how each cause is recognised), and a CASCADE (how far down a
 * nested stack one close propagates). Only Qt Quick Controls has all three as
 * data: `QQuickPopup::ClosePolicy` is a flags enum and `tryClose(pos, phase)`
 * is one boolean expression, `closePolicy & (phase & outsideFlags)`. Uno/WinUI
 * reached the same shape independently and it rotted into dead code for want of
 * a default. This program is that value form, written the way
 * [8-dismissal](../index.md) and the [proposal](../proposal.md) § 3.6
 * (`DismissPolicy` / `DismissReason`, item `P4`) recommend it for sparkles:
 *
 *   1. **The router names the cause in the policy's own vocabulary** and the
 *      surface answers `dismisses(policy, event, hit)`. Nobody else decides.
 *   2. **A separate class of MANDATORY causes bypasses the word entirely** —
 *      anchor removed, unplaceable, parent closing. An orphan cannot survive.
 *   3. **The two hard parts are pairing and cascade**, and both are shown here
 *      failing as well as working: § 4 pairs press with release (Qt's
 *      `outsidePressed` latch, HTML's two-phase light dismiss), § 5 exempts the
 *      frame an overlay opened on (Slint's `had_popup_on_press`, Turbo Vision's
 *      `firstEvent`), and § 6 truncates a nested chain to an endpoint index
 *      (Blink's `HideAllPopoversUntil`).
 *
 * Companion to docs/research/anchored-overlays/index.md § "Dismissal" and to
 * proposal.md § 3.6.
 *
 * Run with: dub run --single dismissal-policy.d
 *
 * Portability: pure computation over integer cells — no OS, no clock, no
 * display, no input device. Every decision here is assertable on the recording
 * canvas, which is the point of making dismissal a value.
 */
module anchored_overlays_dismissal_policy;

import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.input.events : Key, KeyAction, KeyEvent, isDismiss;
import sparkles.ui.geometry : cellsOf, Point, Rect;

// ---------------------------------------------------------------------------
// The policy value
// ---------------------------------------------------------------------------

/**
Every cause a surface can be closed by, one bit each — the shape of
`QQuickPopup::ClosePolicyFlag` and of Uno's `DismissalTriggerFlags`. The router
offers a cause in exactly this vocabulary, so the evaluation is an AND.

`anchorClipped` is deliberately present and deliberately never dismisses here:
CSS anchor positioning HIDES a box whose anchor scrolled out of view rather than
closing it (`position-visibility: anchor-visible` is the initial value), and the
proposal keeps that distinction.
*/
enum DismissOn : ushort
{
    nothing = 0,
    closeRequest = 1 << 0, /// `isDismiss` — Escape and the Android back key (INP13)
    pressOutside = 1 << 1,
    releaseOutside = 1 << 2,
    outsideAnchor = 1 << 3, /// the anchor's own cells count as OUTSIDE, not inside
    triggerReactivate = 1 << 4,
    focusOutside = 1 << 5,
    surfaceBlur = 1 << 6, /// window/app deactivation — not detectable on the TUI
    anchorGone = 1 << 7, /// mandatory: bypasses the policy word
    anchorClipped = 1 << 8, /// HIDES, does not close
    unplaceable = 1 << 9, /// mandatory: the placement solver returned nothing
    resize = 1 << 10,
    scroll = 1 << 11,
    siblingOpened = 1 << 12,
    cascade = 1 << 13, /// mandatory: an ancestor is closing
    timeout = 1 << 14, /// the notify band's clock
}

/// Why a surface closed. `xdg-shell`'s argument-less `popup_done` is the named
/// anti-pattern: a client that cannot tell Escape from a click outside cannot
/// implement "restore focus only when dismissed by keyboard".
enum DismissReason : ubyte
{
    none,
    programmatic,
    closeRequest,
    pressOutside,
    releaseOutside,
    outsideAnchor,
    triggerReactivate,
    focusOutside,
    surfaceBlur,
    anchorGone,
    unplaceable,
    resize,
    scroll,
    siblingOpened,
    parentClosed,
    timeout,
}

/// The whole dimension, per surface. `group` is Flutter's `groupId`: a menu
/// chain is ONE dismiss target, so "inside" is group membership rather than
/// geometric descent of a widget tree.
struct DismissPolicy
{
    DismissOn on;
    size_t group; /// 0 is the bare page — never a surface's own group
    bool passThrough; /// does the dismissing press also reach what it hit?
}

/// What the router says happened, in the policy's vocabulary. Exactly one cause
/// bit per call — the router owns "what happened", the surface owns "do I care".
struct DismissEvent
{
    DismissOn cause;
    uint frame; /// the frame this event is being routed on
    bool openGuard = true; /// honour the one-frame open exemption (§ 5)
}

/// What the router resolved about this event with respect to THIS surface. All
/// of it comes from the last painted frame's hit list; none of it needs a grab,
/// a capture, a scrim or a platform popup.
struct OverlayHit
{
    size_t group; /// group the CURRENT pointer phase resolved to (0 = bare page)
    size_t pressGroup; /// group the PRESS phase resolved to — Qt's latch, Blink's `t0`
    bool insideAnchor; /// the point lies in this surface's anchor cells
    uint openedFrame; /// the frame this surface opened on
}

/// The causes the policy word does not get a vote on. An orphaned surface, a
/// surface whose anchor is gone, and a surface the solver cannot place are all
/// unreachable by any dismissal path — ImGui's sticky-orphan bug is what
/// happens when they are not mandatory.
enum mandatoryCauses = combine(DismissOn.anchorGone, DismissOn.unplaceable, DismissOn.cascade);

/// The causes that must be tested against the hit list before they count.
enum outsideCauses = combine(DismissOn.pressOutside, DismissOn.releaseOutside, DismissOn.outsideAnchor);

/// The causes a surface opened this very frame is exempt from.
enum guardedCauses = combine(outsideCauses, DismissOn.triggerReactivate);

/**
The whole decision, as one expression per clause.

This is `tryClose` with the phase latch and the open guard folded in — the two
narrowings the survey forced on the naive "AND the flags" form (`D8.C1`).
*/
DismissReason dismissedBy(in DismissPolicy policy, in DismissEvent event, in OverlayHit hit) @safe pure nothrow @nogc
in (isSingleCause(event.cause), "the router offers exactly one cause per call")
{
    // 1. Mandatory causes bypass the word.
    if (has(mandatoryCauses, event.cause))
        return reasonOf(event.cause);

    // 2. Qt's `tryClose`: the policy word ANDed with the offered cause.
    if (!has(policy.on, event.cause))
        return DismissReason.none;

    // 3. A surface opened by the very press being routed is exempt from it
    //    (Slint's `had_popup_on_press`, Turbo Vision's `firstEvent` guard).
    if (event.openGuard && has(guardedCauses, event.cause) && hit.openedFrame == event.frame)
        return DismissReason.none;

    // 4. "Outside" is group membership. The anchor's cells are inside the group
    //    unless the surface opted into the wider scope (the inverse spelling of
    //    Qt's `CloseOnPressOutsideParent`) — which is why pressing an open
    //    popover's own trigger is `triggerReactivate` and never `pressOutside`.
    if (has(outsideCauses, event.cause))
    {
        if (hit.group == policy.group)
            return DismissReason.none;
        if (hit.insideAnchor && !has(policy.on, DismissOn.outsideAnchor))
            return DismissReason.none;

        // 5. The pairing: a release only dismisses if the press was outside too
        //    (Blink's `t0 == t1`, Qt's `!contains(pressPoint)`).
        if (event.cause == DismissOn.releaseOutside && hit.pressGroup == policy.group)
            return DismissReason.none;
    }

    return reasonOf(event.cause);
}

/// The boolean face of $(LREF dismissedBy) — the predicate the router calls when
/// it only needs to know whether to plan a close.
bool dismisses(in DismissPolicy policy, in DismissEvent event, in OverlayHit hit) @safe pure nothrow @nogc
    => dismissedBy(policy, event, hit) != DismissReason.none;

// ---------------------------------------------------------------------------
// Flag plumbing (an enum's `|` promotes to `int`, so combining needs a helper)
// ---------------------------------------------------------------------------

DismissOn combine(scope const DismissOn[] flags...) @safe pure nothrow @nogc
{
    ushort acc;
    foreach (f; flags)
        acc |= cast(ushort) f;
    return cast(DismissOn) acc;
}

bool has(in DismissOn set, in DismissOn bit) @safe pure nothrow @nogc
    => (cast(ushort) set & cast(ushort) bit) != 0;

bool isSingleCause(in DismissOn c) @safe pure nothrow @nogc
{
    const v = cast(ushort) c;
    return v != 0 && (v & (v - 1)) == 0;
}

DismissReason reasonOf(in DismissOn cause) @safe pure nothrow @nogc
{
    switch (cause)
    {
    case DismissOn.closeRequest:
        return DismissReason.closeRequest;
    case DismissOn.pressOutside:
        return DismissReason.pressOutside;
    case DismissOn.releaseOutside:
        return DismissReason.releaseOutside;
    case DismissOn.outsideAnchor:
        return DismissReason.outsideAnchor;
    case DismissOn.triggerReactivate:
        return DismissReason.triggerReactivate;
    case DismissOn.focusOutside:
        return DismissReason.focusOutside;
    case DismissOn.surfaceBlur:
        return DismissReason.surfaceBlur;
    case DismissOn.anchorGone:
        return DismissReason.anchorGone;
    case DismissOn.unplaceable:
        return DismissReason.unplaceable;
    case DismissOn.resize:
        return DismissReason.resize;
    case DismissOn.scroll:
        return DismissReason.scroll;
    case DismissOn.siblingOpened:
        return DismissReason.siblingOpened;
    case DismissOn.cascade:
        return DismissReason.parentClosed;
    case DismissOn.timeout:
        return DismissReason.timeout;
        // `anchorClipped` hides the surface; it never closes it.
    default:
        return DismissReason.none;
    }
}

/// The short label a matrix cell prints for a reason.
string shortName(in DismissReason r) @safe pure nothrow @nogc
{
    final switch (r)
    {
    case DismissReason.none:
        return "·";
    case DismissReason.programmatic:
        return "prog";
    case DismissReason.closeRequest:
        return "esc";
    case DismissReason.pressOutside:
        return "press";
    case DismissReason.releaseOutside:
        return "rel";
    case DismissReason.outsideAnchor:
        return "outanc";
    case DismissReason.triggerReactivate:
        return "trig";
    case DismissReason.focusOutside:
        return "focus";
    case DismissReason.surfaceBlur:
        return "blur";
    case DismissReason.anchorGone:
        return "GONE";
    case DismissReason.unplaceable:
        return "NOFIT";
    case DismissReason.resize:
        return "resize";
    case DismissReason.scroll:
        return "scroll";
    case DismissReason.siblingOpened:
        return "sib";
    case DismissReason.parentClosed:
        return "PARENT";
    case DismissReason.timeout:
        return "time";
    }
}

private struct FlagName
{
    DismissOn bit;
    string name;
}

private immutable FlagName[] flagNames = [
    FlagName(DismissOn.closeRequest, "closeRequest"),
    FlagName(DismissOn.pressOutside, "pressOutside"),
    FlagName(DismissOn.releaseOutside, "releaseOutside"),
    FlagName(DismissOn.outsideAnchor, "outsideAnchor"),
    FlagName(DismissOn.triggerReactivate, "triggerReactivate"),
    FlagName(DismissOn.focusOutside, "focusOutside"),
    FlagName(DismissOn.surfaceBlur, "surfaceBlur"),
    FlagName(DismissOn.anchorGone, "anchorGone"),
    FlagName(DismissOn.anchorClipped, "anchorClipped"),
    FlagName(DismissOn.unplaceable, "unplaceable"),
    FlagName(DismissOn.resize, "resize"),
    FlagName(DismissOn.scroll, "scroll"),
    FlagName(DismissOn.siblingOpened, "siblingOpened"),
    FlagName(DismissOn.cascade, "cascade"),
    FlagName(DismissOn.timeout, "timeout"),
];

/// Render a flags word as `a|b|c`. A template, so the writer's attributes infer.
void writeFlags(Writer)(in DismissOn on, ref Writer w)
{
    bool first = true;
    foreach (fn; flagNames)
        if (has(on, fn.bit))
        {
            if (!first)
                w ~= '|';
            w ~= fn.name;
            first = false;
        }
    if (first)
        w ~= "nothing";
}

// ---------------------------------------------------------------------------
// The presets — five roles, one type
// ---------------------------------------------------------------------------

/// The band a surface lives in. Only `popup` participates in the dismissal
/// stack: `hint` is HTML's separate hint list (tooltips, never a dismissal
/// parent) and `notify` is out of the stack entirely.
enum OverlayBand : ubyte
{
    hint,
    popup,
    notify,
}

immutable DismissPolicy tooltipDismiss = DismissPolicy(
    on: combine(DismissOn.closeRequest, DismissOn.pressOutside, DismissOn.focusOutside,
        DismissOn.siblingOpened, DismissOn.scroll, DismissOn.resize),
    group: 1,
);

immutable DismissPolicy popoverDismiss = DismissPolicy(
    on: combine(DismissOn.closeRequest, DismissOn.pressOutside, DismissOn.releaseOutside,
        DismissOn.triggerReactivate, DismissOn.focusOutside, DismissOn.resize),
    group: 2,
);

immutable DismissPolicy menuDismiss = DismissPolicy(
    on: combine(DismissOn.closeRequest, DismissOn.pressOutside, DismissOn.releaseOutside,
        DismissOn.triggerReactivate, DismissOn.focusOutside, DismissOn.siblingOpened,
        DismissOn.resize),
    group: 7,
);

/// Qt's modal dialog: `CloseOnEscape` and nothing else — light dismiss off.
immutable DismissPolicy modalDismiss = DismissPolicy(
    on: DismissOn.closeRequest,
    group: 4,
);

/// A notification toast is not in the dismissal stack and does not answer to the
/// pointer; it answers to its own clock.
immutable DismissPolicy notifierDismiss = DismissPolicy(
    on: DismissOn.timeout,
    group: 9,
);

/// The touch / WCAG-pointer-cancellation resolution of the same policy: act on
/// the release, never on the press (base-ui's per-pointer-type mode).
immutable DismissPolicy touchPopoverDismiss = DismissPolicy(
    on: combine(DismissOn.closeRequest, DismissOn.releaseOutside),
    group: 2,
);

// ---------------------------------------------------------------------------
// A nested chain, for the cascade
// ---------------------------------------------------------------------------

enum noParent = size_t.max;

struct OverlayRecord
{
    string name;
    OverlayBand band;
    size_t parent = noParent; /// index into the open array
    Rect surface;
    DismissPolicy policy;
    uint openedFrame;
}

/// Strict ancestry over the open array — Avalonia's `IsChildOrThis` climb, on a
/// flat arena instead of a visual tree.
bool isDescendant(scope const OverlayRecord[] open, size_t candidate, size_t ancestor) @safe pure nothrow @nogc
{
    if (candidate == ancestor || ancestor == noParent)
        return false;
    for (size_t i = open[candidate].parent; i != noParent; i = open[i].parent)
        if (i == ancestor)
            return true;
    return false;
}

/// Reverse paint order is reverse hit order: the last-opened surface wins a cell
/// it shares with anything beneath it (HoverState's "later target wins" rule,
/// which is also what keeps an overlay and its anchor from both answering true).
size_t hitIndex(scope const OverlayRecord[] open, in Point p) @safe pure nothrow @nogc
{
    foreach_reverse (i, const r; open)
        if (r.surface.contains(p))
            return i;
    return noParent;
}

/// The result of one truncation: what closes, in leaf-to-root order, and why.
struct CloseList
{
    size_t[8] index;
    DismissReason[8] reason;
    size_t length;

    void add(size_t i, DismissReason r) @safe pure nothrow @nogc
    in (length < index.length, "the demo chain never exceeds 8 open surfaces")
    {
        index[length] = i;
        reason[length] = r;
        ++length;
    }
}

/**
Blink's `HideAllPopoversUntil`, in a flat arena: compute an ENDPOINT and close
everything above it, leaf to root. The endpoint itself stays open; `noParent`
means "the bare page", which closes the whole group.

The shallowest surface closed is the one the cause actually named; everything
above it closes because its parent did — which is the `parentClosed` reason,
mandatory and unvetoable.
*/
CloseList truncateTo(scope const OverlayRecord[] open, size_t endpoint, size_t group,
    DismissReason cause) @safe pure nothrow @nogc
{
    CloseList closing;
    size_t shallowest = noParent;
    foreach_reverse (i, const r; open)
    {
        const closes = endpoint == noParent
            ? r.policy.group == group : isDescendant(open, i, endpoint);
        if (!closes)
            continue;
        closing.add(i, DismissReason.parentClosed);
        shallowest = i;
    }
    foreach (k; 0 .. closing.length)
        if (closing.index[k] == shallowest)
            closing.reason[k] = cause;
    return closing;
}

// ---------------------------------------------------------------------------

/// The hit facts for a single-surface overlay, resolved from the last frame.
OverlayHit hitFor(in Rect surface, in Rect anchor, in DismissPolicy p, in Point now,
    in Point pressed, uint openedFrame) @safe pure nothrow @nogc
    => OverlayHit(
        group: surface.contains(now) ? p.group : 0,
        pressGroup: surface.contains(pressed) || anchor.contains(pressed) ? p.group : 0,
        insideAnchor: anchor.contains(now),
        openedFrame: openedFrame,
    );

string pt(in Point p) @safe
{
    import std.format : format;

    return format!"(%d,%d)"(p.x, p.y);
}

/// Pad a table cell to `width` display columns. `cellsOf` is the toolkit's one
/// width authority — `%-7s` would pad by BYTES and skew every column holding a
/// multi-byte `·`.
void writeCell(Writer)(ref Writer w, scope const(char)[] s, size_t width, bool leftAlign = false)
{
    const used = cellsOf(s);
    const pad = width > used ? width - used : 0;
    if (leftAlign)
        w ~= s;
    foreach (_; 0 .. pad)
        w ~= ' ';
    if (!leftAlign)
        w ~= s;
}

void main() @safe
{
    // -----------------------------------------------------------------------
    writeln("=== 1. Five roles, one type ===");
    writeln("Dismissal is not five behaviours; it is one evaluator and five values.");
    writeln();

    static struct Preset
    {
        string name;
        DismissPolicy policy;
    }

    const presets = [
        Preset("tooltip", tooltipDismiss),
        Preset("popover", popoverDismiss),
        Preset("menu", menuDismiss),
        Preset("modal", modalDismiss),
        Preset("notifier", notifierDismiss),
    ];

    foreach (p; presets)
    {
        SmallBuffer!(char, 256) buf;
        writeFlags(p.policy.on, buf);
        writefln!"  %-9s group %d  on = %s"(p.name, p.policy.group, buf[]);
    }

    // -----------------------------------------------------------------------
    writeln("\n=== 2. The decision matrix: policy word AND router-offered cause ===");
    writeln("Cell = the DismissReason the surface returns. `·` = the cause was offered");
    writeln("and declined. UPPERCASE = a MANDATORY cause that bypassed the policy word.");
    writeln();

    static struct Cause
    {
        string label;
        DismissOn bit;
    }

    const causes = [
        Cause("esc", DismissOn.closeRequest),
        Cause("press", DismissOn.pressOutside),
        Cause("rel", DismissOn.releaseOutside),
        Cause("trig", DismissOn.triggerReactivate),
        Cause("focus", DismissOn.focusOutside),
        Cause("gone", DismissOn.anchorGone),
        Cause("sib", DismissOn.siblingOpened),
        Cause("parent", DismissOn.cascade),
        Cause("time", DismissOn.timeout),
        Cause("resize", DismissOn.resize),
    ];

    // The canonical matrix hit: the bare page, pressed and released there, with
    // the surface long since opened — so nothing but the policy word decides.
    const outsideHit = OverlayHit(group: 0, pressGroup: 0, insideAnchor: false, openedFrame: 0);
    const frame = DismissEvent(cause: DismissOn.nothing, frame: 42);

    {
        SmallBuffer!(char, 256) head;
        head ~= "  ";
        head.writeCell("policy", 9, true);
        foreach (c; causes)
            head.writeCell(c.label, 7);
        writeln(head[]);
    }

    foreach (p; presets)
    {
        SmallBuffer!(char, 256) row;
        row ~= "  ";
        row.writeCell(p.name, 9, true);
        foreach (c; causes)
        {
            const e = DismissEvent(cause: c.bit, frame: frame.frame);
            row.writeCell(shortName(dismissedBy(p.policy, e, outsideHit)), 7);
        }
        writeln(row[]);
    }

    writeln();
    writeln("  A modal dialog declines every light-dismiss cause and still closes on");
    writeln("  GONE/PARENT; a notifier declines the pointer entirely and answers only");
    writeln("  its clock. No branch anywhere selected that — the value did.");

    // -----------------------------------------------------------------------
    writeln("\n=== 3. The close request is one input, and it is a key DOWN ===");
    writeln("`isDismiss` (INP13) already unifies Escape and the Android back key, and");
    writeln("already excludes releases — the HTML spec makes down-only normative.");
    writeln();

    KeyEvent escUp = KeyEvent(Key.escape);
    escUp.action = KeyAction.release;
    const strokes = [KeyEvent(Key.escape), escUp, KeyEvent(Key.back), KeyEvent(Key.char_, 'q')];
    const strokeNames = ["Escape down", "Escape up", "Back down", "'q' down"];

    foreach (i, k; strokes)
    {
        const cause = isDismiss(k) ? DismissOn.closeRequest : DismissOn.nothing;
        if (cause == DismissOn.nothing)
        {
            writefln!"  %-12s -> no cause offered            popover: ·"(strokeNames[i]);
            continue;
        }
        const e = DismissEvent(cause: cause, frame: 42);
        writefln!"  %-12s -> DismissOn.closeRequest      popover: %s"(
            strokeNames[i], shortName(dismissedBy(popoverDismiss, e, outsideHit)));
    }
    writeln("  (An Escape release must not dismiss a second time — an app that closed a");
    writeln("   popup on the press would otherwise close the popup AND quit per stroke.)");

    // -----------------------------------------------------------------------
    writeln("\n=== 4. The press/release pairing ===");
    // A popover on a trigger, both rectangles in abstract cells. Coordinates may
    // legitimately be negative: content scrolled left of the viewport still
    // hit-tests, and the pairing must survive it.
    const surface = Rect(20, 6, 24, 5);
    const anchor = Rect(18, 4, 6, 1);
    const inside = Point(30, 8);
    const outside = Point(4, 12);
    const outside2 = Point(7, 13);
    const scrolledOff = Point(-3, 2); // left of the viewport origin — not clamped

    writefln!"  surface %s..%s   anchor %s..%s"(
        pt(surface.origin), pt(Point(surface.right, surface.bottom)),
        pt(anchor.origin), pt(Point(anchor.right, anchor.bottom)));
    writeln();
    writeln("  press at   release at    press phase   release phase   release-only policy");

    static struct Pairing
    {
        Point press, release;
    }

    const pairings = [
        Pairing(outside, outside2),
        Pairing(outside, inside),
        Pairing(inside, outside),
        Pairing(inside, inside),
        Pairing(scrolledOff, scrolledOff),
    ];

    foreach (pr; pairings)
    {
        const pressHit = hitFor(surface, anchor, popoverDismiss, pr.press, pr.press, 0);
        const relHit = hitFor(surface, anchor, popoverDismiss, pr.release, pr.press, 0);
        const pressEv = DismissEvent(cause: DismissOn.pressOutside, frame: 42);
        const relEv = DismissEvent(cause: DismissOn.releaseOutside, frame: 42);

        const touchHit = hitFor(surface, anchor, touchPopoverDismiss, pr.release, pr.press, 0);

        SmallBuffer!(char, 128) row;
        row ~= "  ";
        row.writeCell(pt(pr.press), 11, true);
        row.writeCell(pt(pr.release), 14, true);
        row.writeCell(shortName(dismissedBy(popoverDismiss, pressEv, pressHit)), 14, true);
        row.writeCell(shortName(dismissedBy(popoverDismiss, relEv, relHit)), 16, true);
        row.writeCell(shortName(dismissedBy(touchPopoverDismiss, relEv, touchHit)), 1, true);
        writeln(row[]);
    }

    writeln();
    writeln("  Row 2: pressed outside, released INSIDE — the release declines (a drag");
    writeln("         that ends on the surface is not a dismissal).");
    writeln("  Row 3: pressed INSIDE, released outside — the release declines too, on");
    writeln("         the latched press group. This is the drag-to-select-text case the");
    writeln("         WCAG pointer-cancellation comment in Blink exists for.");
    writeln("  Row 5: negative cell coordinates hit-test like any other — the point is");
    writeln("         outside the surface, not clamped onto its edge.");

    // The two behaviours, pinned. `checked` keeps assertions live.
    {
        const relEv = DismissEvent(cause: DismissOn.releaseOutside, frame: 42);
        assert(!dismisses(popoverDismiss, relEv,
                hitFor(surface, anchor, popoverDismiss, outside, inside, 0)),
            "press inside / release outside must not dismiss");
        assert(!dismisses(popoverDismiss, relEv,
                hitFor(surface, anchor, popoverDismiss, inside, outside, 0)),
            "press outside / release inside must not dismiss");
        assert(dismisses(popoverDismiss, relEv,
                hitFor(surface, anchor, popoverDismiss, outside, outside2, 0)),
            "outside press paired with an outside release must dismiss");
    }

    // -----------------------------------------------------------------------
    writeln("\n=== 5. The one-frame open guard ===");
    writeln("A surface opened by the very press being routed must not be dismissed by");
    writeln("that same press. Two shapes of the bug, with the guard on and off:");
    writeln();
    {
        SmallBuffer!(char, 128) head;
        head ~= "  ";
        head.writeCell("case", 50, true);
        head.writeCell("guard on", 11, true);
        head.writeCell("guard off", 1, true);
        writeln(head[]);
    }

    void guardRow(string label, in DismissPolicy p, in DismissEvent e, in OverlayHit h) @safe
    {
        DismissEvent off = e;
        off.openGuard = false;
        SmallBuffer!(char, 128) row;
        row ~= "  ";
        row.writeCell(label, 50, true);
        row.writeCell(shortName(dismissedBy(p, e, h)), 11, true);
        row.writeCell(shortName(dismissedBy(p, off, h)), 1, true);
        writeln(row[]);
    }

    // (a) a context menu opened at frame 100 by a press on the bare document —
    //     there is no registered trigger widget, so the opening press resolves
    //     outside the new surface's group.
    const openedNow = OverlayHit(group: 0, pressGroup: 0, insideAnchor: false, openedFrame: 100);
    guardRow("context menu, the press that opened it (f100)", menuDismiss,
        DismissEvent(cause: DismissOn.pressOutside, frame: 100), openedNow);
    guardRow("...the next outside press (f101)", menuDismiss,
        DismissEvent(cause: DismissOn.pressOutside, frame: 101), openedNow);

    // (b) the toggle: the press on a popover's own trigger both opens it and is
    //     a `triggerReactivate` for it.
    const openedByTrigger = OverlayHit(group: 0, pressGroup: 0, insideAnchor: true, openedFrame: 200);
    guardRow("popover, the trigger press that opened it (f200)", popoverDismiss,
        DismissEvent(cause: DismissOn.triggerReactivate, frame: 200), openedByTrigger);
    guardRow("...pressing that trigger again later (f260)", popoverDismiss,
        DismissEvent(cause: DismissOn.triggerReactivate, frame: 260), openedByTrigger);

    writeln();
    writeln("  Without the guard the surface closes on the frame it opened — visibly");
    writeln("  never opening at all. GTK gave up and disabled release-based autohide");
    writeln("  outright over this; Slint, Turbo Vision, WPF, tippy and Qt each carry a");
    writeln("  bespoke latch. One integer field on the record replaces all of them.");

    // -----------------------------------------------------------------------
    writeln("\n=== 6. The cascade ===");
    writeln("Dismissal never closes \"this one\": it computes an ENDPOINT index and closes");
    writeln("everything ABOVE it, leaf to root. Ancestors survive; so does anything that");
    writeln("is not a descendant — the toast below is open the whole time and never");
    writeln("closes, because truncation is by ancestry, not by stack position.");
    writeln();

    const chain = [
        OverlayRecord("File", OverlayBand.popup, noParent, Rect(2, 3, 14, 6), menuDismiss, 10),
        OverlayRecord("Recent", OverlayBand.popup, 0, Rect(16, 5, 16, 5), menuDismiss, 12),
        OverlayRecord("Projects", OverlayBand.popup, 1, Rect(32, 7, 18, 4), menuDismiss, 14),
        OverlayRecord("toast", OverlayBand.notify, noParent, Rect(50, 1, 20, 3), notifierDismiss, 9),
    ];

    writeln("  idx  name       band    rect                 parent  group");
    foreach (i, const r; chain)
        writefln!"  [%d]  %-10s %-7s %-20s %-7s %d"(i, r.name, r.band,
            pt(r.surface.origin) ~ ".." ~ pt(Point(r.surface.right, r.surface.bottom)),
            r.parent == noParent ? "-" : chain[r.parent].name, r.policy.group);

    writeln();
    writeln("  cause                                     endpoint   closes (leaf -> root)");

    void cascadeRow(string label, size_t endpoint, DismissReason cause) @safe
    {
        const closing = truncateTo(chain, endpoint, menuDismiss.group, cause);
        SmallBuffer!(char, 256) buf;
        foreach (k; 0 .. closing.length)
        {
            if (k)
                buf ~= ' ';
            buf ~= chain[closing.index[k]].name;
            buf ~= '[';
            buf ~= shortName(closing.reason[k]);
            buf ~= ']';
        }
        if (closing.length == 0)
            buf ~= "(nothing)";
        writefln!"  %-41s %-10s %s"(label,
            endpoint == noParent ? "-" : chain[endpoint].name, buf[]);
    }

    // (1) A close request goes to the topmost open surface in the popup band —
    //     so the endpoint is that surface's parent.
    cascadeRow("close request (topmost popup only)", chain[2].parent, DismissReason.closeRequest);
    // (2) Press on the bare page: nothing in the group survives.
    cascadeRow("press outside every surface (60,20)", hitIndex(chain, Point(60, 20)),
        DismissReason.pressOutside);
    // (3) Press inside the root menu: it becomes the endpoint and stays open.
    cascadeRow("press inside File (6,5)", hitIndex(chain, Point(6, 5)), DismissReason.parentClosed);
    // (4) Press mid-chain.
    cascadeRow("press inside Recent (20,7)", hitIndex(chain, Point(20, 7)), DismissReason.parentClosed);
    // (5) A mandatory cause, applied to a surface in the middle of the chain.
    cascadeRow("anchor of Recent removed", chain[1].parent, DismissReason.anchorGone);
    // (6) A sibling submenu opens at depth 1.
    cascadeRow("sibling submenu opened at depth 1", chain[1].parent, DismissReason.siblingOpened);

    writeln();
    writeln("  Every row is the same truncation with a different endpoint and a different");
    writeln("  named reason; only the shallowest closed surface carries the cause, the");
    writeln("  rest carry PARENT. Nothing above an endpoint survives and nothing below it");
    writeln("  is touched — which is exactly `HideAllPopoversUntil(endpoint)`.");

    // Pinned: a mid-chain close takes its descendants and leaves its ancestors.
    {
        const closing = truncateTo(chain, chain[1].parent, menuDismiss.group, DismissReason.anchorGone);
        assert(closing.length == 2, "closing Recent must take exactly Recent and Projects");
        assert(closing.index[0] == 2 && closing.index[1] == 1, "leaf-to-root order");
        assert(closing.reason[0] == DismissReason.parentClosed);
        assert(closing.reason[1] == DismissReason.anchorGone);

        const all = truncateTo(chain, noParent, menuDismiss.group, DismissReason.pressOutside);
        assert(all.length == 3, "the toast is not in the menu's dismiss group");
    }
}
