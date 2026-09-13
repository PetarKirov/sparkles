/**
What a target's input actually offers (`INP14`, `TGT5`, `IXB10`).

$(LREF InteractionTier) answers "how live is this target?" and is a $(B ladder)
— `<=` is the whole test. This module answers a different question that the
ladder cannot express: $(B which pointer affordances exist at all.)

The two are orthogonal, and touch is the proof. A touchscreen serves tier 1
(press, drag, wheel) and tier 2 (sub-cell positions, continuous time) while
lacking $(B hover) — which sits at tier 0, the rung every target is assumed to
serve. Inserting touch into the ladder would make `<=` wrong in both
directions at once, so hover, pointer precision and pointer count are declared
here as independent axes instead.

The payoff is that a component stops $(I assuming) a mouse. Given
`hover: false` it offers a non-hover route — a scrollbar renders permanently
expanded rather than easing open on a hover that never honestly occurs, an
overlay picks tap-to-reveal — instead of animating against a stale last-touch
position, which is what the hosts did before this existed.
*/
module sparkles.input.capability;

import sparkles.input.tier : InteractionTier;

@safe pure nothrow @nogc:

/**
A target's declared input affordances.

The defaults describe a $(B mouse): the historical assumption, so a producer
that has not thought about this yet keeps today's behavior rather than
silently claiming a capability it lacks in the other direction.

Declare with one of the profiles below where one fits — $(LREF mousePointer),
$(LREF touchPointer), $(LREF cellPointer), $(LREF staticPointer) — so the
vocabulary stays small and two targets that mean the same thing say it the
same way.
*/
struct InputCapabilities
{
    /**
    The pointer can rest on a target without pressing.

    `false` on touch, and it is the one that changes component behavior most:
    everything hover-driven needs a second route, because on a touchscreen the
    "pointer position" between taps is simply the last place a finger left.
    */
    bool hover = true;

    /// Positions are finer than one cell (a pixel backend). Cell-quantized
    /// targets say `false`, so a component can decline sub-cell work rather
    /// than compute a precision the target will round away.
    bool precisePointer = true;

    /// Simultaneous contacts the target can report. `1` is a mouse; a
    /// touchscreen reports its digitizer's limit. Anything above `1` is what
    /// makes a pinch expressible at all.
    ubyte maxPointers = 1;

    /// The highest $(LREF InteractionTier) this target serves.
    InteractionTier tier = InteractionTier.interactive;

    /**
    The target reports key $(B releases), not only presses (`INP16`).

    A terminal cannot: its input is a byte stream of what was typed, with no
    key-up to decode. So a held-key interaction — "pan while space is down" —
    works on a window and silently does nothing in a terminal unless the
    consumer asks this first and offers another route.

    $(B Defaults to `false`), unlike the other axes, which default to a mouse.
    A release is not a refinement of a press but an $(I extra) event, and a
    consumer that switches on the key alone would read one as a second press.
    Undeclared therefore means "presses only", which is what every producer
    reported before this existed; a producer opts in by declaring it and
    synthesizing them.
    */
    bool keyRelease = false;

    /**
    A gesture recognizer is $(B wired) on this target (`TRG2`).

    Not implied by the tier, and not by `maxPointers` either: the recognizer
    that turns contacts into a long-press or a pinch exists in one backend, and
    a target with a touchscreen but no recognizer reports contacts nobody
    interprets. A consumer choosing what to substitute for an unavailable
    trigger cannot resolve the long-press rule without knowing.

    $(B Defaults to `false`), for `keyRelease`'s reason: an undeclared target
    is one nobody has wired, and a consumer that assumed otherwise would offer
    an affordance that never fires.
    */
    bool gestures = false;

    /**
    Bare-motion reporting is on — the target sends pointer moves with no button
    held (`TRG11`).

    $(B Defaults to `false`.) A terminal only sends motion under DEC 1003, which
    a host opts into; without it there is no motion stream at all, so
    hover-intent machinery — a corridor, a direction latch, a warm-up keyed to
    the pointer resting — has nothing to run on. The distinction that matters is
    that such machinery must then be $(B absent), not degraded: a component that
    computes intent from events it never receives simply never opens.
    */
    bool motion = false;

    // The module-level block above does not reach inside an aggregate.
@safe pure nothrow @nogc:

    /// `true` iff this target serves `t` — the ladder's `<=` test, kept here
    /// so a caller asks the capability set rather than reaching past it.
    bool serves(InteractionTier t) const => t <= tier;

    /// `true` iff more than one contact can be reported (pinch, two-finger
    /// pan). Named because `maxPointers > 1` at a call site reads as a
    /// magic-number comparison.
    bool multiPointer() const => maxPointers > 1;
}

/// A mouse: hover, sub-cell positions, one contact. The default.
enum InputCapabilities mousePointer = InputCapabilities.init;

/**
A touchscreen: no hover, precise, multi-contact, and tier 2 because a gesture
is resolved from sub-cell positions over time.

`maxPointers = 10` is the digitizer limit rather than what any gesture uses —
the recognizer cares about 1 and 2 — but declaring the device's real limit
keeps this a $(I fact about the target) rather than a restatement of current
consumer needs.
*/
enum InputCapabilities touchPointer = InputCapabilities(
    hover: false, precisePointer: true, maxPointers: 10,
    tier: InteractionTier.precise);

/// A terminal mouse: hover and press/drag arrive over SGR-1006, but positions
/// are whole cells, so `precisePointer` is `false`.
enum InputCapabilities cellPointer = InputCapabilities(
    hover: true, precisePointer: false, maxPointers: 1,
    tier: InteractionTier.interactive);

/// Static output (the pure-CSS HTML target): `:hover` works, nothing live
/// does — tier 0, and no pointer stream at all.
enum InputCapabilities staticPointer = InputCapabilities(
    hover: true, precisePointer: false, maxPointers: 1,
    tier: InteractionTier.passive);

@("input.capability.axesAreOrthogonalToTheTier")
@safe pure nothrow @nogc
unittest
{
    // The reason this module exists: touch outranks a terminal on the ladder
    // while lacking a capability the terminal has. Neither `<=` direction
    // captures that, which is why hover is not a rung.
    assert(touchPointer.tier > cellPointer.tier);
    assert(!touchPointer.hover && cellPointer.hover);

    // The ladder still works for what it is for.
    assert(touchPointer.serves(InteractionTier.interactive));
    assert(touchPointer.serves(InteractionTier.precise));
    assert(!staticPointer.serves(InteractionTier.interactive));
    assert(staticPointer.serves(InteractionTier.passive));

    // Multi-contact is exactly what makes pinch expressible.
    assert(touchPointer.multiPointer);
    assert(!mousePointer.multiPointer);
    assert(!cellPointer.multiPointer);

    // The default is the historical assumption, so an undeclared producer
    // behaves as it did rather than claiming less than it offers.
    assert(mousePointer == InputCapabilities.init);
    assert(mousePointer.hover && mousePointer.precisePointer);

    // Key releases are the one axis that defaults to absent: they are an extra
    // event, not a refinement of an existing one, so claiming them by default
    // would change what every existing consumer sees.
    assert(!mousePointer.keyRelease);
    assert(!cellPointer.keyRelease, "a terminal has no key-up to decode");
    assert(!touchPointer.keyRelease && !staticPointer.keyRelease);

    // A window target opts in by declaring it.
    enum windowWithReleases = InputCapabilities(keyRelease: true);
    assert(windowWithReleases.keyRelease);
}

@("input.capability.additiveAxesDefaultOff")
@safe pure nothrow @nogc unittest
{
    // `gestures` and `motion` join `keyRelease` in defaulting to `false`, and
    // for the same reason: each names an EXTRA event stream rather than a
    // refinement of one that already arrives. A consumer that assumed a
    // default of `true` would offer an affordance the target never fires, and
    // the failure is silent — nothing happens, and nothing says why.
    const undeclared = InputCapabilities.init;
    assert(!undeclared.keyRelease && !undeclared.gestures && !undeclared.motion);

    // They are independent of the tier and of each other: a touchscreen with a
    // digitizer but no recognizer reports contacts nobody interprets.
    auto touch = InputCapabilities(hover: false, maxPointers: 10);
    assert(!touch.gestures, "contacts are not gestures");
    touch.gestures = true;
    assert(touch.gestures && !touch.motion);
}
