#!/usr/bin/env dub
/+ dub.sdl:
    name "anchored_overlays_tooltip_timing"
    targetPath "build"
    dependency "sparkles:base" path="../../../.."
    dependency "sparkles:ui" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The tooltip warm-up / cool-down machine, **composed from `Timeline` (`STM6`)**
 * and stepped over a scripted event list.
 *
 * Nine subjects in the survey implement the behaviour the field converged on —
 * the *first* tooltip in a group pays a warm-up delay, a *subsequent* one appears
 * instantly while the group is still warm, and the group goes cold again after a
 * cool-down (WPF's `BetweenShowDelay`, React Aria's `globalWarmedUp` +
 * `TOOLTIP_COOLDOWN`, Radix's `skipDelayDuration`, Ariakit's `skipTimeout`,
 * Base UI's `FloatingDelayGroup`, Qt, GTK, WinUI, Avalonia). They also converged
 * on its *shape*: **one shared arbiter holding two integers, with no per-widget
 * timer state.** This program is that machine, built the way `PRN8` demands —
 * the clock is the toolkit's existing $(REF Timeline, sparkles,ui,state), not a
 * second hand-rolled timer:
 *
 *   * `Timeline.Phase.fadeIn` **is** `warming` (the arm-to-deadline interval),
 *   * `Timeline.Phase.hold` **is** `shown`, pinned `holdUntilDismissed`,
 *   * the only genuinely new state is `DwellGroup` — `openId` plus one integer.
 *
 * Section 2 shows the three seams where `STM6`'s own semantics do *not* line up
 * with a warm-up, each demonstrated by running it: `visible()` is already true
 * in `fadeIn`, `dismissed()` from `fadeIn` plays a full-opacity fade-out, and a
 * backend with no frame clock never advances `stepped` at all. Composing
 * `Timeline` therefore means using it as the **counter**, and deriving
 * visibility from `phase == hold` rather than from `visible()`.
 *
 * The trace tables are the demonstration. The same scripted event list is run
 * through three targets, so the collapses are visible as *divergence in one
 * column* rather than as prose:
 *
 *   1. a pointer target (the full machine),
 *   2. a touch target — `caps.hover == false`, where the hover trigger is
 *      substituted rather than degraded,
 *   3. tier-0 static HTML — no script, **no timers at all**, where the warm-up
 *      survives as `transition-delay` and the group behaviour is honestly absent.
 *
 * Companion to [../proposal.md](../proposal.md) § 4.1 "Tooltip" and § 4.5
 * "The one genuinely new machine, and its `PRN8` justification"; the field
 * evidence it implements is in [../comparison.md](../comparison.md), dimension 6.
 *
 * Run with: dub run --single tooltip-timing.d
 *
 * Portability: pure computation over an injected `dtMs` — no clock, no display,
 * no terminal. Deterministic everywhere.
 */
module anchored_overlays_tooltip_timing;

import std.range.primitives : put;
import std.stdio : writefln, writeln;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.writers : writeValue;
import sparkles.input : InputCapabilities;
import sparkles.ui.state : Timeline;

// ---------------------------------------------------------------------------
// Configuration — the numbers live beside the other popup metrics, never inline
// ---------------------------------------------------------------------------

/**
The two durations the whole dimension reduces to. Both belong in `Palette`
beside `popupPadX`, exactly as WinUI puts them in the OS and Qt in `QStyle`;
they are parameters here so the trace can name them.

`skipMs == 0` must **statically disable** warmth rather than arm a zero-length
timer — Radix shipped that bug (`#3873`: a zero-length timer left every tooltip
instant forever) and fixed it with early returns in both provider callbacks.
$(LREF DwellConfig.warmthEnabled) is that early return, expressed as a value.
*/
struct DwellConfig
{
    int warmUpMs = 500; /// the first tooltip in a cold group waits this long
    int skipMs = 300;   /// the group stays warm this long after one closes

    /// Warmth is a *feature*, switched on by a positive skip window.
    bool warmthEnabled() const @safe pure nothrow @nogc => skipMs > 0;
}

// ---------------------------------------------------------------------------
// The machine: Timeline (STM6) as the clock + a two-integer group arbiter
// ---------------------------------------------------------------------------

/// The `Timeline` config a dwell arms with. `fadeInMs` is the *resolved* delay
/// (0 when the group was warm), and `holdUntilDismissed` is pinned so a
/// hover-triggered surface can never self-close — the WCAG 1.4.13 defaults trap
/// that `Timeline.Config.holdMs = 1200` sets for an unwary caller.
Timeline.Config lifeCfg(int resolvedDelayMs) @safe pure nothrow @nogc
    => Timeline.Config(fadeInMs: resolvedDelayMs, holdUntilDismissed: true);

/// One tooltip's timing state: a composed `Timeline` plus the anchor it belongs
/// to. `armedDelayMs` is stored because the deadline must be **absolute** —
/// measured from the arm instant, never recomputed as `now + delay` — which
/// `Timeline.stepped` gives for free as long as the config does not change
/// under it.
struct TooltipDwell
{
    Timeline life;      /// `fadeIn` == warming, `hold` == shown
    size_t anchorId;    /// 0 == no anchor
    int armedDelayMs;   /// the delay resolved at arm time

@safe pure nothrow @nogc:

    Timeline.Config cfg() const => lifeCfg(armedDelayMs);

    /// Counting down to the deadline, and **not** in the display or hit list.
    bool warming() const => life.phase == Timeline.Phase.fadeIn;

    /// Painted. Note this is `phase == hold`, *not* `life.visible()` — see § 2.
    bool shown() const => life.phase == Timeline.Phase.hold;
}

/// The whole cross-instance protocol: which anchor owns the open surface, and
/// how much warmth is left once it closes. Nine independent lineages converged
/// on exactly this much state. With an injected wall clock the second field is
/// the absolute `warmUntilMs` the proposal specifies; this driver supplies
/// `dtMs` (the shape `Timeline.stepped` already consumes), so it counts down.
/// One integer either way.
struct DwellGroup
{
    size_t openId;   /// the anchor currently showing, 0 == none
    int warmMsLeft;  /// > 0 ⇒ the next tooltip in the group opens instantly
}

/// A group and its at-most-one live tooltip. One record suffices because
/// opening closes every peer (React Aria's `closeOthers`), so a registry of
/// per-instance timers — which is not expressible in `@safe pure` value code
/// anyway — has nothing left to hold.
struct Dwell
{
    TooltipDwell active;
    DwellGroup group;

@safe pure nothrow @nogc:

    bool visible() const => active.shown;
    size_t visibleId() const => active.shown ? active.anchorId : 0;

    /// `true` while a *subsequent* tooltip would open with no delay.
    bool warm() const => group.openId != 0 || group.warmMsLeft > 0;
}

/// Post-transition invariant: a shown tooltip **is** the group's open surface,
/// and an open surface makes the countdown redundant (React Aria clears the
/// pending cool-down on show).
Dwell settled(in Dwell s) @safe pure nothrow @nogc
{
    Dwell n = s;
    if (n.active.shown)
    {
        n.group.openId = n.active.anchorId;
        n.group.warmMsLeft = 0;
    }
    return n;
}

/// Whatever was live yields the group.
///
/// The cool-down is armed **only if something was actually shown** — abandoning
/// a hover mid-warm-up leaves the group cold and the next hover pays full price
/// (React Aria arms its cool-down inside `if (globalWarmedUp)`). And a cancelled
/// warm-up resets to `Timeline.init`, never through `Timeline.dismissed` — § 2.b.
Dwell closedActive(in Dwell s, in DwellConfig c) @safe pure nothrow @nogc
{
    Dwell n = s;
    const wasShown = s.active.shown;
    n.active = TooltipDwell.init;
    n.group.openId = 0;
    if (wasShown && c.warmthEnabled)
        n.group.warmMsLeft = c.skipMs;
    return n;
}

/// The pointer came to rest on an anchor.
Dwell entered(in Dwell s, size_t id, in DwellConfig c) @safe pure nothrow @nogc
in (id != 0, "anchor id 0 means 'no anchor'")
{
    // Re-entry on the live anchor is a no-op, not a restart: a `retarget`, never
    // a close+open, or the surface flashes.
    if (s.active.anchorId == id && s.active.life.phase != Timeline.Phase.idle)
        return s;

    // Read the group *before* the outgoing surface yields — the swap is instant
    // because a peer is open, which is the same warmth the cool-down preserves.
    const instant = c.warmthEnabled && s.warm;
    auto n = closedActive(s, c);
    const delay = instant ? 0 : c.warmUpMs;
    n.active = TooltipDwell(Timeline.triggered(lifeCfg(delay)), id, delay);
    return settled(n);
}

/// The pointer left the anchor (and the group's region).
Dwell left(in Dwell s, in DwellConfig c) @safe pure nothrow @nogc
    => closedActive(s, c);

/// A press, a key, or a scroll: closes the surface **and clears warmth**.
///
/// Nothing in React Aria or Radix clears warmth except its own cool-down, so a
/// click or a scroll leaves the next tooltip in instant mode; Ariakit patched
/// exactly this symptom on `onBlur`. Warmth is a property of an uninterrupted
/// hover context, so the interruption ends it.
Dwell interrupted(in Dwell s, in DwellConfig c) @safe pure nothrow @nogc
{
    auto n = closedActive(s, c);
    n.group.warmMsLeft = 0;
    return n;
}

/// Advance by `dtMs`. The warm-up elapses inside `Timeline`; the cool-down is
/// the one subtraction this machine adds.
Dwell stepped(in Dwell s, int dtMs, in DwellConfig c) @safe pure nothrow @nogc
{
    Dwell n = s;
    n.active.life = s.active.life.stepped(dtMs, s.active.cfg);
    if (!n.active.shown && n.group.openId == 0)
        n.group.warmMsLeft = n.group.warmMsLeft > dtMs ? n.group.warmMsLeft - dtMs : 0;
    return settled(n);
}

// ---------------------------------------------------------------------------
// The scripted event list
// ---------------------------------------------------------------------------

/// What a target can deliver. `enter`/`leave` exist only where `caps.hover`.
enum Ev : ubyte
{
    tick,   /// time passes, nothing happens
    enter,  /// the pointer rests on an anchor
    leave,  /// the pointer leaves the group
    tap,    /// press+release on an anchor (or on 0 == outside)
    press,  /// a press elsewhere; also stands in for key/scroll
}

/// One driver step: advance the clock by `dtMs`, then deliver `ev`.
struct Step
{
    int dtMs;
    Ev ev;
    size_t anchor;
    string why; /// what the step is meant to prove
}

string evName(Ev e) @safe pure nothrow @nogc
{
    final switch (e) with (Ev)
    {
        case tick: return "tick";
        case enter: return "enter";
        case leave: return "leave";
        case tap: return "tap";
        case press: return "press";
    }
}

string anchorLabel(size_t id) @safe pure nothrow @nogc
    => id == 0 ? "-" : id == 1 ? "A" : id == 2 ? "B" : "C";

/// `enter A`, `tick`, `tap outside` … — built through an output range, so the
/// label costs no allocation even though `main` only prints it.
void writeEvent(Writer)(ref Writer w, in Step s)
{
    put(w, evName(s.ev));
    if (s.anchor != 0)
    {
        put(w, " ");
        put(w, anchorLabel(s.anchor));
    }
    else if (s.ev == Ev.tap)
        put(w, " outside");
}

/// `cold` / `warm 180`.
void writeGroup(Writer)(ref Writer w, in DwellGroup g)
{
    if (g.openId != 0)
        put(w, "open");
    else if (g.warmMsLeft > 0)
    {
        put(w, "warm ");
        writeValue(w, g.warmMsLeft);
    }
    else
        put(w, "cold");
}

string dwellPhase(in TooltipDwell d) @safe pure nothrow @nogc
    => d.warming ? "warming" : d.shown ? "shown" : "idle";

/// The hover script: A warms up and shows, B rides the warm group instantly,
/// the cool-down expires before C, a press clears warmth, and an abandoned
/// warm-up leaves the group cold.
immutable Step[] hoverScript = [
    Step(0, Ev.enter, 1, "cold group: A pays the full warm-up"),
    Step(250, Ev.tick, 0, "mid warm-up: armed, not painted"),
    Step(250, Ev.tick, 0, "deadline reached: A is shown"),
    Step(700, Ev.tick, 0, "holdUntilDismissed: no 1.2 s self-close"),
    Step(0, Ev.leave, 0, "A closes and arms the cool-down"),
    Step(120, Ev.enter, 2, "group still warm: B is INSTANT"),
    Step(300, Ev.tick, 0, "B holds"),
    Step(0, Ev.leave, 0, "B closes, cool-down re-armed"),
    Step(400, Ev.tick, 0, "cool-down expires: the group is cold"),
    Step(0, Ev.enter, 3, "C pays the full warm-up again"),
    Step(500, Ev.tick, 0, "C is shown"),
    Step(0, Ev.press, 3, "press closes AND clears warmth"),
    Step(50, Ev.enter, 1, "warmth was cleared: A warms up again"),
    Step(200, Ev.leave, 0, "abandoned mid-warm-up: no cool-down armed"),
    Step(0, Ev.enter, 2, "so B pays full price, not the skip window"),
];

/// The touch script: the substituted trigger, on the same three anchors.
immutable Step[] tapScript = [
    Step(0, Ev.tap, 1, "tap pins A instantly (openMs is statically 0)"),
    Step(900, Ev.tick, 0, "pinned: no max-duration, no self-close"),
    Step(0, Ev.tap, 2, "tap B swaps the pinned surface"),
    Step(0, Ev.tap, 2, "tap the same anchor: triggerReactivate dismisses"),
    Step(0, Ev.tap, 3, "tap C pins C"),
    Step(0, Ev.tap, 0, "tap outside dismisses"),
];

// ---------------------------------------------------------------------------
// Trigger resolution (the sketch from proposal.md § 3.5, reduced to what a
// tooltip needs)
// ---------------------------------------------------------------------------

/// A declaration, not a behaviour: which triggers the component *wants*.
struct TriggerPolicy
{
    bool hover, activate, longPress;
}

/// What the target can actually serve, and what it put in hover's place.
struct TriggerPlan
{
    TriggerPolicy served, dropped, substituted;
}

/// `caps.hover == false` moves `hover` to `substituted` and lets `activate`
/// (tap-to-pin) carry it — the only substitution expressible on all three live
/// targets. Long press is **not** the default substitute: it exceeds the cell
/// pointer's tier, and on Android it collides with text selection.
TriggerPlan resolveTriggers(in TriggerPolicy want, in InputCapabilities caps)
    @safe pure nothrow @nogc
{
    TriggerPlan p;
    p.served.activate = want.activate;
    if (want.hover && caps.hover)
        p.served.hover = true;
    else if (want.hover && want.activate)
        p.substituted.hover = true;
    else if (want.hover)
        p.dropped.hover = true;
    if (want.longPress && caps.hover)
        p.dropped.longPress = true; // deliberate: never the default substitute
    else
        p.served.longPress = want.longPress;
    return p;
}

// ---------------------------------------------------------------------------
// The tier-0 model: what `:hover` + `transition-delay` can and cannot express
// ---------------------------------------------------------------------------

/// Static HTML has no cross-element state, so *this is the entire machine*: how
/// long one element has matched `:hover`. There is no group, no arbiter, and
/// nothing to interrupt.
struct CssHover
{
    size_t hoveredId;
    int hoveredMs;
}

CssHover cssEntered(size_t id) @safe pure nothrow @nogc => CssHover(id, 0);
CssHover cssLeft() @safe pure nothrow @nogc => CssHover(0, 0);

/// Leaving reverts the property, so mid-delay cancellation is free — the one
/// piece of the machine tier-0 gets right for nothing.
CssHover cssStepped(in CssHover s, int dtMs) @safe pure nothrow @nogc
    => CssHover(s.hoveredId, s.hoveredId == 0 ? 0 : s.hoveredMs + dtMs);

bool cssVisible(in CssHover s, in DwellConfig c) @safe pure nothrow @nogc
    => s.hoveredId != 0 && s.hoveredMs >= c.warmUpMs;

/// The rule pair a `DwellConfig` compiles to. It needs one change to
/// `interp/html_semantic.d:57-58`: `display` is not transitionable, so the
/// tier-0 reveal must switch to `visibility`/`opacity`.
void writeTier0Css(Writer)(ref Writer w, in DwellConfig c)
{
    put(w, ".spk-reveal{position:absolute;z-index:1;visibility:hidden;opacity:0;"
        ~ "transition:visibility 0s,opacity 0s;transition-delay:0ms}\n");
    put(w, ".spk-hit:hover>.spk-reveal,.spk-hit:focus-visible>.spk-reveal{"
        ~ "visibility:visible;opacity:1;transition-delay:");
    writeValue(w, c.warmUpMs);
    put(w, "ms}\n");
}

// ---------------------------------------------------------------------------

void main() @safe
{
    const cfg = DwellConfig();

    writeln("=== The tooltip timing machine, composed from Timeline (STM6) ===");
    writefln!"warm-up %d ms   cool-down (skip window) %d ms   warmth enabled: %s"(
        cfg.warmUpMs, cfg.skipMs, cfg.warmthEnabled);
    writeln("composition: Timeline.Config(fadeInMs: <resolved delay>, "
        ~ "holdUntilDismissed: true)");
    writeln("             fadeIn == warming (not painted)   hold == shown");
    writeln("new state:   DwellGroup { openId, warmMsLeft } — two integers, "
        ~ "no per-widget timer");

    // -- 1. the pointer trace ------------------------------------------------
    writeln("\n=== 1. The hover script on a pointer target ===");
    writeln("    t  event      dwell     group      shown  why");

    Dwell s;
    int t;
    size_t instantOpens, delayedOpens;
    foreach (st; hoverScript)
    {
        t += st.dtMs;
        s = s.stepped(st.dtMs, cfg);
        const before = s;
        final switch (st.ev) with (Ev)
        {
            case tick: break;
            case enter: s = s.entered(st.anchor, cfg); break;
            case leave: s = s.left(cfg); break;
            case tap: s = s.entered(st.anchor, cfg); break;
            case press: s = s.interrupted(cfg); break;
        }
        if (st.ev == Ev.enter)
        {
            if (s.active.armedDelayMs == 0)
                ++instantOpens;
            else
                ++delayedOpens;
        }
        // The fade-out phase is unreachable here: fadeOutMs is 0 by
        // construction, so `shown` and `warming` partition every live state.
        assert(s.active.life.phase != Timeline.Phase.fadeOut);
        assert(before.group.warmMsLeft >= 0);

        SmallBuffer!(char, 32) ev, grp;
        writeEvent(ev, st);
        writeGroup(grp, s.group);
        writefln!"%5d  %-9s  %-8s  %-9s  %-5s  %s"(
            t, ev[], dwellPhase(s.active), grp[],
            s.visible ? anchorLabel(s.visibleId) : "-", st.why);
    }
    writefln!("\nopens: %d paid the warm-up, %d opened instantly "
        ~ "(one arbiter, zero per-widget timers)")(delayedOpens, instantOpens);
    assert(instantOpens == 1 && delayedOpens == 4);

    // -- 2. the three STM6 seams --------------------------------------------
    writeln("\n=== 2. Three Timeline seams the composition must not step on ===");
    {
        // (a) visible() is already true while warming.
        const warmingCfg = lifeCfg(cfg.warmUpMs);
        auto w = Timeline.triggered(warmingCfg).stepped(250, warmingCfg);
        writefln!("a) warming at 250/%d ms: life.visible()=%s  alpha=%d%%  "
            ~ "=> paint on `phase == hold`, never on visible()")(
            cfg.warmUpMs, w.visible, w.alphaPercent(warmingCfg));
        assert(w.visible && w.phase == Timeline.Phase.fadeIn);
        assert(!TooltipDwell(w, 1, cfg.warmUpMs).shown);

        // (b) dismissed() from fadeIn plays a full-opacity fade-out.
        const fading = Timeline.Config(fadeInMs: 500, fadeOutMs: 150,
            holdUntilDismissed: true);
        const cancelled = Timeline.triggered(fading).stepped(250, fading)
            .dismissed(fading);
        writefln!("b) dismissed() mid-warm-up: phase=%s alpha=%d%% — a cancelled "
            ~ "warm-up must reset to idle, not dismiss")(
            cancelled.phase, cancelled.alphaPercent(fading));
        assert(cancelled.phase == Timeline.Phase.fadeOut
            && cancelled.alphaPercent(fading) == 100);

        // (c) a backend with no frame clock never advances `stepped`.
        auto frozen = Dwell().entered(1, cfg);
        foreach (_; 0 .. 100)
            frozen = frozen.stepped(0, cfg); // TuiHost.frameSeconds() => 0
        writefln!("c) 100 frames at dt=0 (the TUI's frameSeconds): dwell=%s, "
            ~ "shown=%s — a warm-up needs an injected clock")(
            dwellPhase(frozen.active), frozen.visible);
        assert(frozen.active.warming && !frozen.visible);
    }

    // -- 3. zero disables the feature, structurally --------------------------
    writeln("\n=== 3. skipMs == 0 disables warmth; it never arms a 0 ms timer ===");
    {
        const zero = DwellConfig(warmUpMs: 500, skipMs: 0);
        auto z = Dwell().entered(1, zero).stepped(500, zero); // A shown
        assert(z.visible);
        z = z.left(zero);
        writefln!"after closing A with skipMs=0: group=%s, warmMsLeft=%d"(
            z.warm ? "warm" : "cold", z.group.warmMsLeft);
        z = z.entered(2, zero);
        writefln!("entering B: armed delay %d ms (not 0) — the WPF "
            ~ "BetweenShowDelay==0 rule, and the fix for Radix #3873")(
            z.active.armedDelayMs);
        assert(!z.warm && z.active.armedDelayMs == zero.warmUpMs);
    }

    // -- 4. the touch collapse ----------------------------------------------
    writeln("\n=== 4. The touch collapse (caps.hover == false) ===");
    const touch = InputCapabilities(hover: false, precisePointer: false,
        maxPointers: 5);
    const want = TriggerPolicy(hover: true, activate: true, longPress: false);
    const plan = resolveTriggers(want, touch);
    writefln!"want: hover+activate   caps.hover=%s"(touch.hover);
    writefln!"  served:      hover=%s activate=%s"(plan.served.hover,
        plan.served.activate);
    writefln!"  substituted: hover=%s  -> tap-to-pin over PressState"(
        plan.substituted.hover);
    writefln!"  dropped:     hover=%s"(plan.dropped.hover);
    assert(!plan.served.hover && plan.substituted.hover && !plan.dropped.hover);

    // The same hover script, on a target that emits no hover events at all.
    {
        Dwell h;
        int delivered, shownSteps;
        foreach (st; hoverScript)
        {
            h = h.stepped(st.dtMs, cfg);
            if (st.ev == Ev.enter || st.ev == Ev.leave)
                continue; // the target produces neither
            ++delivered;
            if (st.ev == Ev.press)
                h = h.interrupted(cfg);
            if (h.visible)
                ++shownSteps;
        }
        writefln!("\nreplaying the hover script here: %d of %d steps deliver an "
            ~ "event, tooltip shown on %d — hover is unreachable, not slow")(
            delivered, hoverScript.length, shownSteps);
        assert(shownSteps == 0);
    }

    // The substituted trigger, driven by the same machine with openMs == 0.
    // `warming` and the cool-down are unreachable *by configuration*, not by a
    // runtime branch — a zero warm-up means `Timeline.triggered` lands in `hold`.
    const touchCfg = DwellConfig(warmUpMs: 0, skipMs: 0);
    writeln("\ntap-to-pin, warm-up statically 0, holdUntilDismissed pinned:");
    writeln("    t  event        dwell     group      shown  why");
    {
        Dwell p;
        int tt;
        foreach (st; tapScript)
        {
            tt += st.dtMs;
            p = p.stepped(st.dtMs, touchCfg);
            if (st.ev == Ev.tap)
                p = st.anchor == 0 || p.group.openId == st.anchor
                    ? p.interrupted(touchCfg)          // outside / reactivate
                    : p.entered(st.anchor, touchCfg);  // pin
            assert(!p.active.warming, "warming is unreachable on touch");
            assert(p.group.warmMsLeft == 0, "the cool-down is unreachable too");

            SmallBuffer!(char, 32) ev, grp;
            writeEvent(ev, st);
            writeGroup(grp, p.group);
            writefln!"%5d  %-11s  %-8s  %-9s  %-5s  %s"(
                tt, ev[], dwellPhase(p.active), grp[],
                p.visible ? anchorLabel(p.visibleId) : "-", st.why);
        }
        assert(!p.visible);
    }
    writeln("unavailable rather than degraded: dwell intent (there is no rest "
        ~ "without hover),");
    writeln("the warm group, the cool-down. The substitution must be PUBLISHED "
        ~ "— as a readable");
    writeln("resolution value and an accessible description — or it is a silent "
        ~ "product hole.");

    // -- 5. the tier-0 collapse ---------------------------------------------
    writeln("\n=== 5. The tier-0 collapse (static HTML: no script, no timers) ===");
    {
        SmallBuffer!(char, 512) css;
        writeTier0Css(css, cfg);
        writeln(css[]);
    }
    writeln("The same hover script, evaluated by those two rules alone:");
    writeln("    t  event      machine    tier-0   divergence");

    {
        Dwell m;
        CssHover h;
        int ct, diverged;
        foreach (st; hoverScript)
        {
            ct += st.dtMs;
            m = m.stepped(st.dtMs, cfg);
            h = h.cssStepped(st.dtMs);
            final switch (st.ev) with (Ev)
            {
                case tick: break;
                case enter:
                    m = m.entered(st.anchor, cfg);
                    h = cssEntered(st.anchor);
                    break;
                case leave:
                    m = m.left(cfg);
                    h = cssLeft();
                    break;
                case tap:
                    m = m.entered(st.anchor, cfg);
                    break;
                case press:
                    m = m.interrupted(cfg);
                    break; // no press channel at tier 0
            }
            const mv = m.visible ? anchorLabel(m.visibleId) : "-";
            const hv = cssVisible(h, cfg) ? anchorLabel(h.hoveredId) : "-";
            if (mv != hv)
                ++diverged;

            SmallBuffer!(char, 32) ev;
            writeEvent(ev, st);
            writefln!"%5d  %-9s  %-9s  %s"(ct, ev[], mv,
                mv == hv ? hv : hv ~ "        <-- differs");
        }
        writefln!"\n%d of %d steps differ."(diverged, hoverScript.length);
        assert(diverged > 0);
    }

    writeln("\nWhat tier 0 keeps, and what is simply not there:");
    writeln("  warm-up delay          -> transition-delay on the :hover rule");
    writeln("  mid-delay cancellation -> free; the property reverts on unhover");
    writeln("  hold until dismissed   -> :hover holds as long as the pointer "
        ~ "stays");
    writeln("  keyboard trigger       -> the :focus-visible half of the same "
        ~ "rule");
    writeln("  ABSENT: warm group / instant swap (no cross-element state)");
    writeln("  ABSENT: cool-down, and the whole arbiter with it");
    writeln("  ABSENT: rest (the id-stability gate needs a machine)");
    writeln("  ABSENT: press / key / scroll clearing warmth (no channel)");
    writeln("  ABSENT: the singleton — two nested .spk-hit elements both match "
        ~ ":hover");
    writeln("These are honestly absent, not approximated, and are reported "
        ~ "under TGT5.");
}
