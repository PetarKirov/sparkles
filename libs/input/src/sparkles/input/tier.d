/**
The capability ladder of `sparkles:input` (`INP5`–`INP6`). The three render
targets are not equally capable, and the binding constraint is pure-CSS HTML:
static output expresses hover, focus and toggling with no script, but cannot
express a drag. Rather than degrade silently, every interaction is classified
into a $(LREF InteractionTier); a widget declares the highest tier it needs and
a target declares the highest tier it serves, so emitting a widget beyond the
target's capability is a $(B reportable) degradation, never a silent drop.
*/
module sparkles.input.tier;

import sparkles.input.events;

@safe:

/**
The interaction capability ladder:

| Tier | Interactions | Served by |
|------|--------------|-----------|
| `passive` | hover, focus, toggle/checked, disclosure | every target, including pure-CSS HTML |
| `interactive` | key events, text input, pointer press/release/drag, wheel | GUI + TUI |
| `precise` | sub-cell pointer precision, continuous drag, time-based effects | pixel targets only |
*/
enum InteractionTier : ubyte
{
    passive,     /// tier 0 — expressible in static output (`:hover`, `:checked`, `<details>`)
    interactive, /// tier 1 — needs a live event loop
    precise,     /// tier 2 — needs sub-cell positions / continuous time
}

/// The tier an event belongs to: key/pointer/wheel traffic is `interactive`;
/// focus, resize and the sentinels ride along on any target (`passive`).
/// (`precise` is a property of a $(I capability) — sub-cell coordinates,
/// timers — not of the event vocabulary itself.)
InteractionTier tierOf(in Event e) pure nothrow @nogc
    => e.match!(
        (in KeyEvent _) => InteractionTier.interactive,
        (in PointerEvent _) => InteractionTier.interactive,
        (in WheelEvent _) => InteractionTier.interactive,
        // The first case that makes `precise` reachable from `tierOf`: a
        // gesture is resolved from sub-cell positions over time, which is the
        // ladder's own definition of tier 2 (`GST5`).
        (in GestureEvent _) => InteractionTier.precise,
        _ => InteractionTier.passive,
    );

@("input.tier.classification")
@safe pure nothrow @nogc unittest
{
    assert(tierOf(keyEvent(Key.enter)) == InteractionTier.interactive);
    assert(tierOf(Event(WheelEvent(dy: 1))) == InteractionTier.interactive);
    assert(tierOf(Event(GestureEvent(Gesture.longPress))) == InteractionTier.precise);
    assert(tierOf(Event(FocusEvent(focused: true))) == InteractionTier.passive);
    assert(tierOf(Event(ResizeEvent())) == InteractionTier.passive);
    // The ladder is ordered, so "does the target serve this?" is `<=`.
    assert(InteractionTier.passive < InteractionTier.interactive);
    assert(InteractionTier.interactive < InteractionTier.precise);
}
