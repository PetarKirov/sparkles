/**
Keyboard focus and routing values (`FOC`) — the pieces of the input-routing
chain that applications kept hand-rolling as booleans and statement order.

The routing doctrine, extending `DCK13` from pointers to keys: a key is
offered to, in order,

$(OL
    $(LI an active $(B grab) ($(LREF KeyGrab)) — an exclusive consumer such
    as an embedded terminal, with declared release chords and a pass-through
    allowlist;)
    $(LI the $(B modal / focused scopes), which are not a separate mechanism
    at all — a modal surface is a context in which the app's `reachable`
    hook answers `false` for everything below it, and the focused scope is
    a $(LREF ScopeFocus) value that same hook reads;)
    $(LI the $(B keymap) ($(MREF sparkles,ui,keymap), stepped through
    $(MREF sparkles,ui,lantern) when prefixes exist);)
    $(LI the application's $(B fallback) — whatever an `unbound` key means
    to the pane that owns it (typing into a prompt, forwarding to an
    embedded view).)
)

Everything here is a Regular value, `@safe pure nothrow @nogc`, testable
without a backend — the `STM` discipline.

$(B Edge-aware element traversal) (`MDL5`): `FocusState.next`/`previous`
always wrap, and cannot express "the edge was reached, leave this order" —
which nested focus orders (an overlay spliced into its trigger's order, a
pane handing focus back to its container) need. $(LREF move) is the additive
answer: the same traversal, reporting the crossing instead of performing it.
*/
module sparkles.ui.focus;

import sparkles.input.events : Key, KeyEvent;

import sparkles.ui.keymap : Chord, matches;
import sparkles.ui.state : FocusState;

// ---------------------------------------------------------------------------
// Edge-aware traversal over an element order (MDL5).
// ---------------------------------------------------------------------------

/// The result of an edge-aware traversal: the state to adopt when the move
/// stays inside the order, and whether it tried to cross the edge instead.
struct FocusMove
{
    FocusState state;
    /// The move ran off the order's edge. `state` is unchanged from the
    /// input — the caller decides what lies beyond (a parent order, a wrap,
    /// nothing).
    bool leftEdge;
}

/**
Moves focus through `order` $(B without wrapping) — the edge is reported, not
jumped. With nothing focused (or the focused id absent from `order`), a
forward move enters at the first element and a backward move at the last,
exactly as the wrapping traversal does.
*/
FocusMove move(in FocusState f, scope const size_t[] order, int step)
    @safe pure nothrow @nogc
{
    if (order.length == 0)
        return FocusMove(FocusState(0), leftEdge: true);
    ptrdiff_t at = -1;
    foreach (i, id; order)
        if (id == f.focused)
        {
            at = i;
            break;
        }
    const n = cast(ptrdiff_t) order.length;
    if (at < 0)
        return FocusMove(FocusState(order[step > 0 ? 0 : n - 1]));
    const to = at + step;
    if (to < 0 || to >= n)
        return FocusMove(FocusState(f.focused), leftEdge: true);
    return FocusMove(FocusState(order[to]));
}

// ---------------------------------------------------------------------------
// Scope-level keyboard focus.
// ---------------------------------------------------------------------------

/**
Which of an application's keymap scopes owns the keyboard — the value the
context's `reachable` hook reads, replacing the per-app booleans
(`treeFocused`, a picker's pane enum, a gallery's `Region`) that all encode
the same idea.

The scope enum is the app's own ($(MREF sparkles,ui,keymap)'s `Binding`
parameter), so "focus selects the keymap" needs no translation layer: the
focused scope is reachable, its siblings are not, and the table does the
rest.
*/
struct ScopeFocus(Scope)
if (is(Scope == enum))
{
    Scope focused;

@safe pure nothrow @nogc:

    /// `true` iff `s` holds focus.
    bool isFocused(Scope s) const => s == focused;

    /**
    Focus cycled through `order` — the app's reachable panes, in the order a
    cycle key should visit them (wrapping; an absent current scope enters at
    the first/last element; an empty order leaves focus where it is).
    */
    ScopeFocus cycled(scope const Scope[] order, int step = 1) const
    {
        if (order.length == 0)
            return this;
        ptrdiff_t at = -1;
        foreach (i, s; order)
            if (s == focused)
            {
                at = i;
                break;
            }
        const n = cast(ptrdiff_t) order.length;
        if (at < 0)
            return ScopeFocus(order[step > 0 ? 0 : n - 1]);
        return ScopeFocus(order[((at + step) % n + n) % n]);
    }
}

// ---------------------------------------------------------------------------
// Exclusive keyboard capture.
// ---------------------------------------------------------------------------

/**
What an active grab's policy declares: how to get out, and what passes
through. Chords rather than raw comparisons, so the four terminal spellings
of one release chord are four table entries, not a hand-written predicate.
*/
struct GrabPolicy
{
    /// Chords that end the grab (the key is consumed by the release).
    const(Chord)[] release;
    /// Chords the grab lets through to the rest of the chain (scrollback
    /// paging while a terminal owns the keyboard).
    const(Chord)[] passthrough;
}

/// What $(LREF checkGrab) decided about one key.
enum GrabVerdict : ubyte
{
    none,        /// no grab is active — route normally
    forward,     /// the grab owns this key — deliver it to the owner
    released,    /// a release chord ended the grab; the key is spent
    passthrough, /// the grab is active but lets this key through the chain
}

/**
Exclusive keyboard capture as a value — the first rung of the routing chain.

`owner` is a caller-chosen non-zero id (the same convention as `hitId`), so a
host can tell $(I which) surface holds the grab and can drive focus-in/out
edges (an embedded terminal's DECSET 1004 reporting) off `active`
transitions.
*/
struct KeyGrab
{
    size_t owner;

@safe pure nothrow @nogc:

    /// Whether any surface holds the grab.
    bool active() const => owner != 0;

    /// Takes the grab for `id` (non-zero).
    void take(size_t id)
    in (id != 0, "a grab owner must be addressable")
    {
        owner = id;
    }

    /// Releases it.
    void release()
    {
        owner = 0;
    }
}

/**
Routes one key against the grab: release chords end it, pass-through chords
skip it, anything else is the owner's. A caller switches on the verdict
before consulting anything else — which is the whole routing rule the
statement order used to carry.
*/
GrabVerdict checkGrab(ref KeyGrab g, in KeyEvent k, in GrabPolicy p)
    @safe pure nothrow @nogc
{
    if (!g.active)
        return GrabVerdict.none;
    foreach (ref c; p.release)
        if (matches(c, k))
        {
            g.release();
            return GrabVerdict.released;
        }
    foreach (ref c; p.passthrough)
        if (matches(c, k))
            return GrabVerdict.passthrough;
    return GrabVerdict.forward;
}

// ---------------------------------------------------------------------------
// Tests.
// ---------------------------------------------------------------------------

@("ui.focus.moveReportsTheEdgeInsteadOfWrapping")
@safe pure nothrow @nogc
unittest
{
    static immutable size_t[] order = [7, 3, 9];

    // Entry mirrors the wrapping traversal: first forward, last backward.
    auto m = move(FocusState.cleared, order, 1);
    assert(m.state.isFocused(7) && !m.leftEdge);
    m = move(FocusState.cleared, order, -1);
    assert(m.state.isFocused(9) && !m.leftEdge);

    // Inside the order it moves; at the edge it reports and stays.
    m = move(FocusState(7), order, 1);
    assert(m.state.isFocused(3));
    m = move(FocusState(9), order, 1);
    assert(m.leftEdge && m.state.isFocused(9), "the edge is not a wrap");
    m = move(FocusState(7), order, -1);
    assert(m.leftEdge && m.state.isFocused(7));

    // An empty order has only edges.
    assert(move(FocusState(7), null, 1).leftEdge);
}

@("ui.focus.scopeFocusCyclesTheSuppliedOrder")
@safe pure nothrow @nogc
unittest
{
    enum P : ubyte
    {
        input,
        list,
        preview,
    }

    static immutable P[] order = [P.input, P.list, P.preview];
    auto f = ScopeFocus!P(P.input);
    assert(f.isFocused(P.input));
    f = f.cycled(order);
    assert(f.isFocused(P.list));
    f = f.cycled(order);
    f = f.cycled(order);
    assert(f.isFocused(P.input), "the cycle wraps");
    f = f.cycled(order, -1);
    assert(f.isFocused(P.preview), "…in both directions");
    assert(f.cycled(null).isFocused(P.preview), "an empty order is inert");
}

@("ui.focus.grabRoutesReleaseAndPassthroughByChord")
@safe pure nothrow @nogc
unittest
{
    import sparkles.input.events : Mods;
    import sparkles.ui.keymap : chord, ShiftReq;

    // The embedded-terminal shape: several spellings of one release chord,
    // and shifted paging passing through to the host.
    static immutable Chord[] release = [
        Chord(key: Key.char_, ch: ']', ctrl: true),
        Chord(key: Key.char_, ch: '`', ctrl: true),
    ];
    static immutable Chord[] pass = [
        chord(Key.pageUp, ShiftReq.yes),
        chord(Key.pageDown, ShiftReq.yes),
    ];
    const policy = GrabPolicy(release, pass);

    KeyGrab g;
    assert(checkGrab(g, KeyEvent(Key.char_, 'x'), policy) == GrabVerdict.none,
        "no grab, no routing");

    g.take(42);
    assert(g.active && g.owner == 42);
    assert(checkGrab(g, KeyEvent(Key.char_, 'x'), policy)
        == GrabVerdict.forward, "the grab owns ordinary keys");
    assert(checkGrab(g, KeyEvent(Key.pageUp, 0, Mods(shift: true)), policy)
        == GrabVerdict.passthrough, "…except the declared allowlist");
    assert(g.active, "a pass-through does not end the grab");
    assert(checkGrab(g, KeyEvent(Key.char_, ']', Mods(ctrl: true)), policy)
        == GrabVerdict.released);
    assert(!g.active, "a release chord ends it, consuming the key");
}
