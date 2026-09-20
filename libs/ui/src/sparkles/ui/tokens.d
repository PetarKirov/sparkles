/**
The design-system token vocabulary — the $(B draft) the
[design-system spec](../../../../../docs/specs/design-system/SPEC.md) traces
to: token tiers and paths (`TOK1`/`TOK2`), the interaction-state dimension
(`TOK4`/`TOK5`), the per-component slot check (`TOK6`), the target capability
declaration and its documented profiles
([`CAP1`/`CAP5`/`CAP9`](../../../../../docs/specs/design-system/capabilities.md)),
and the border projection onto a cell target
([`GLY2`](../../../../../docs/specs/design-system/glyphs.md)).

Nothing here is wired into $(REF Slot, sparkles,ui,style) resolution or the
backends yet — that is the plan's M1/M2. What this module fixes now is the
$(I vocabulary): the names, the precedence and the projection tables, each with
the test that makes its row of the spec falsifiable.
*/
module sparkles.ui.tokens;

import std.traits : EnumMembers;

import sparkles.base.term_color : ColorDepth;
import sparkles.input.capability : InputCapabilities;
import sparkles.input.tier : InteractionTier;
import sparkles.ui.style : BorderStyle, BoxBorder, Slot;

// ── tiers and paths (TOK1, TOK2) ────────────────────────────────────────────

/// Which layer of the token graph a token sits on (`TOK1`).
enum TokenTier : ubyte
{
    primitive, /// a raw value with no role: `indigo.500`
    semantic,  /// a role: `text.primary`, `status.error`
    component, /// a part of one component: `scrollbar.thumb`, `diff.added`
}

/**
The dotted path of a slot (`TOK2`) — the one spelling from which the CSS
custom-property name and the DTCG group path are both derived.

Paths group the shipped slots into the spec's vocabulary: the semantic groups
(`text`, `status`, `surface`, `border`, `link`, `selection`, `shadow`) and the
component namespaces (`chrome`, `gutter`, `scrollbar`, `completion`, `input`,
`twoslash`, `diff`, `coverage` — the last three being the application domains
`TOK10` keeps in the closed enum).
*/
string tokenPath(Slot s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case Slot.inherit:         return "inherit";
        case Slot.code:            return "text.code";
        case Slot.docs:            return "text.docs";
        case Slot.muted:           return "text.muted";
        case Slot.error:           return "status.error";
        case Slot.warn:            return "status.warning";
        case Slot.info:            return "status.info";
        case Slot.surface:         return "surface.overlay";
        case Slot.border:          return "border.default";
        case Slot.shadow:          return "shadow.overlay";
        case Slot.hoverUnderline:  return "link.underline";
        case Slot.selection:       return "selection.bg";

        case Slot.chrome:          return "chrome.band";
        case Slot.chromeAccent:    return "chrome.accent";
        case Slot.chromeFocused:   return "chrome.focused";
        case Slot.gutter:          return "gutter.fg";
        case Slot.gutterBand:      return "gutter.band";
        case Slot.track:           return "scrollbar.track";
        case Slot.thumb:           return "scrollbar.thumb";
        case Slot.matched:         return "completion.matched";
        case Slot.unmatched:       return "completion.unmatched";
        case Slot.caret:           return "input.caret";

        case Slot.annotate:        return "twoslash.annotate";
        case Slot.highlight:       return "twoslash.highlight";
        case Slot.highlightBorder: return "twoslash.highlight.border";
        case Slot.chip:            return "twoslash.chip";

        case Slot.diffAdded:       return "diff.added";
        case Slot.diffRemoved:     return "diff.removed";
        case Slot.diffEmphAdded:   return "diff.emph.added";
        case Slot.diffEmphRemoved: return "diff.emph.removed";
        case Slot.diffHunk:        return "diff.hunk";
        case Slot.diffFill:        return "diff.fill";

        case Slot.covCovered:      return "coverage.covered";
        case Slot.covUncovered:    return "coverage.uncovered";
        case Slot.covPartial:      return "coverage.partial";
    }
}

/// The groups whose slots are semantic roles; every other group is a
/// component namespace (`TOK1`). `inherit` is the one single-segment path.
private immutable string[] semanticGroups =
    ["inherit", "text", "status", "surface", "border", "link", "selection", "shadow"];

/// The tier a slot's path places it on (`TOK1`).
TokenTier tierOf(Slot s) @safe pure nothrow @nogc
{
    const head = firstSegment(tokenPath(s));
    foreach (g; semanticGroups)
        if (g == head)
            return TokenTier.semantic;
    return TokenTier.component;
}

private const(char)[] firstSegment(return scope const(char)[] path) @safe pure nothrow @nogc
{
    foreach (i, c; path)
        if (c == '.')
            return path[0 .. i];
    return path;
}

/**
`TOK2`'s path grammar: one or more segments joined by `.`, each `[a-z0-9]+`,
the first beginning with a letter (`indigo.500` is a primitive; `500` alone is
not a token). Checked over every slot by the test below, so a misspelled path
is a test failure rather than a stylesheet with a stray property.
*/
bool isValidTokenPath(scope const(char)[] path) @safe pure nothrow @nogc
{
    if (path.length == 0 || !(path[0] >= 'a' && path[0] <= 'z'))
        return false;
    bool segmentStart = true;
    foreach (c; path)
    {
        if (c == '.')
        {
            if (segmentStart)
                return false; // empty segment
            segmentStart = true;
            continue;
        }
        const lower = c >= 'a' && c <= 'z';
        const digit = c >= '0' && c <= '9';
        if (!(lower || digit))
            return false;
        segmentStart = false;
    }
    return !segmentStart; // no trailing '.'
}

// ── interaction states (TOK4, TOK5) ─────────────────────────────────────────

/**
The second axis of slot resolution (`TOK4`). Declaration order $(B is) the
precedence (`TOK5`): when several states are active, the override of the
highest one that has an override wins. `rest` is the absence of every other
state, never a bit of its own.
*/
enum InteractionState : ubyte
{
    rest,     /// nothing else applies — the value a theme always sets
    hover,    /// the pointer rests on it
    focused,  /// it owns keyboard focus
    selected, /// it is part of the selection
    pressed,  /// the pointer/key is down on it
    disabled, /// it cannot be interacted with
}

/// The name a state contributes to a CSS custom property (`WEB1`).
string stateName(InteractionState s) @safe pure nothrow @nogc
{
    final switch (s)
    {
        case InteractionState.rest:     return "rest";
        case InteractionState.hover:    return "hover";
        case InteractionState.focused:  return "focused";
        case InteractionState.selected: return "selected";
        case InteractionState.pressed:  return "pressed";
        case InteractionState.disabled: return "disabled";
    }
}

/// The set of currently active states — a bitset over every state but
/// `rest`, which is the empty set.
struct StateSet
{
    private ubyte bits;

@safe pure nothrow @nogc:

    /// Builds a set from the listed states; `rest` contributes nothing.
    static StateSet of(scope const InteractionState[] states...)
    {
        StateSet r;
        foreach (s; states)
            r = r.with_(s);
        return r;
    }

    private static ubyte bit(InteractionState s)
        => s == InteractionState.rest ? 0 : cast(ubyte)(1u << (s - 1));

    bool empty() const => bits == 0;

    bool has(InteractionState s) const
        => s == InteractionState.rest ? empty : (bits & bit(s)) != 0;

    StateSet with_(InteractionState s) const => StateSet(cast(ubyte)(bits | bit(s)));

    StateSet without(InteractionState s) const => StateSet(cast(ubyte)(bits & ~bit(s)));

    /**
    The state whose override wins (`TOK5`): the highest-precedence active
    state — or `rest` for the empty set. A resolver that consults overrides
    walks from `highest` downward and stops at the first override set, so a
    theme that sets none yields exactly `rest` (`TOK4`).
    */
    InteractionState highest() const
    {
        static foreach_reverse (s; EnumMembers!InteractionState)
            if (has(s))
                return s;
        return InteractionState.rest;
    }
}

// ── CSS custom-property names (TOK2, WEB1) ──────────────────────────────────

/**
Writes `--spk-<path with '.' → '-'>[-<state>]` (`WEB1`) into `w`. The GC-free
form the stylesheet emitter uses; $(LREF cssName) is the convenience wrapper.
*/
void writeCssName(W)(ref W w, Slot slot, InteractionState state = InteractionState.rest)
{
    import std.range.primitives : put;

    put(w, "--spk-");
    foreach (c; tokenPath(slot))
        put(w, c == '.' ? '-' : c);
    if (state != InteractionState.rest)
    {
        put(w, '-');
        put(w, stateName(state));
    }
}

/// ditto — allocating.
string cssName(Slot slot, InteractionState state = InteractionState.rest) @safe pure
{
    import std.array : appender;

    auto w = appender!string;
    writeCssName(w, slot, state);
    return w[];
}

// ── component slot declarations (TOK6) ──────────────────────────────────────

/**
`true` iff every op in `ops` references a slot in `allowed` (`TOK6`). `ops` is
any input range whose elements expose `.slot` — a display list's op range — so
a component test reads `assert(slotsWithin(list.ops, Component.slots))`.
*/
bool slotsWithin(R)(R ops, scope const(Slot)[] allowed)
{
    foreach (ref op; ops)
    {
        bool found;
        foreach (s; allowed)
            if (s == op.slot)
            {
                found = true;
                break;
            }
        if (!found)
            return false;
    }
    return true;
}

// ── target capabilities (CAP1, CAP2, CAP5, CAP9) ────────────────────────────

/// How fine the block-element tier a target's font covers (`CAP2` `blocks`).
enum BlockTier : ubyte
{
    none,     /// no block elements
    half,     /// `▀▄█` and the eighth-blocks `▏…▉` / `▁…▇`
    quadrant, /// the 2×2 quadrants (U+2596–U+259F)
    sextant,  /// the 2×3 sextants (Symbols for Legacy Computing)
    octant,   /// the 2×4 octants (Unicode 16)
}

/// Which inline-image protocol the target accepts (`CAP2` `images`).
enum ImageProtocol : ubyte
{
    none,
    sixel,  /// DEC sixel
    iterm2, /// OSC 1337
    kitty,  /// the kitty graphics protocol
}

/**
What one target can render and receive (`CAP1`): one field per row of the
capability table, every default the conservative answer. Subsumes the input
axes (`input`) so a backend declares one value.

The documented profiles are $(LREF capabilitiesOf); a backend's real
declaration is derived from its own probing (`CAP3`), never from a profile.
*/
struct TargetCapabilities
{
    /// The existing input axes (`IXB10`). `InputCapabilities`' own defaults
    /// describe a mouse; here they are overridden to the conservative answer
    /// so a default-constructed declaration claims nothing (`CAP1`).
    InputCapabilities input = InputCapabilities(
        hover: false, precisePointer: false, maxPointers: 0,
        tier: InteractionTier.passive);

    ColorDepth colorDepth;     /// `none` … `trueColor`
    bool unicode;              /// non-ASCII glyphs at all
    BlockTier blocks;          /// block-element coverage
    bool braille;              /// U+2800 as a 2×4 grid
    bool nerdFont;             /// Nerd Font PUA glyphs (configured, not queried — `GLY4`)

    bool hyperlinks;           /// OSC 8
    bool clipboard;            /// OSC 52 write
    bool notifications;        /// OSC 99 / 9 / 777
    bool pointerShape;         /// OSC 22
    bool textSizing;           /// OSC 66
    ImageProtocol images;      /// inline images
    bool syncOutput;           /// mode 2026
    bool mouse;                /// SGR 1006
    bool hoverMotion;          /// mode 1003
    bool pixelMouse;           /// mode 1016
    bool focusEvents;          /// mode 1004
    bool bracketedPaste;       /// mode 2004
    bool colorSchemeNotify;    /// mode 2031 / OSC 11
    bool progress;             /// OSC 9;4
    bool extendedUnderline;    /// SGR 4:3 + 58
    bool cellPixelSize;        /// CSI 16 t
    bool graphemeClusters;     /// mode 2027

    bool subCellScroll;        /// scroll offsets finer than a cell (GUI/Web)
    bool proportionalText;     /// a proportional face for `FontRole.docs` (GUI/Web)
    bool radius;               /// corner radius honoured, not projected
    bool shadow;               /// drop shadow honoured
    bool alpha;                /// translucent fills honoured

    bool reducedMotion;        /// the user prefers no animation (`ACC5`)
}

/// The three documented profiles (`CAP5`) — test and style-guide presets,
/// not detection results.
enum Profile : ubyte
{
    baseline, /// a pipe, `TERM=dumb`, a serial console
    enhanced, /// any xterm-compatible emulator of the last decade
    full,     /// kitty / Ghostty / WezTerm / foot with a Nerd Font
}

/// The flag set a profile names.
TargetCapabilities capabilitiesOf(Profile p) @safe pure nothrow @nogc
{
    final switch (p)
    {
        case Profile.baseline:
            return TargetCapabilities.init;
        case Profile.enhanced:
            return TargetCapabilities(
                input: InputCapabilities(precisePointer: false),
                colorDepth: ColorDepth.ansi256,
                unicode: true,
                blocks: BlockTier.half,
                hyperlinks: true,
                mouse: true,
                focusEvents: true,
                bracketedPaste: true,
            );
        case Profile.full:
            return TargetCapabilities(
                input: InputCapabilities(precisePointer: false, keyRelease: true),
                colorDepth: ColorDepth.trueColor,
                unicode: true,
                blocks: BlockTier.octant,
                braille: true,
                nerdFont: true,
                hyperlinks: true,
                clipboard: true,
                notifications: true,
                pointerShape: true,
                textSizing: true,
                images: ImageProtocol.kitty,
                syncOutput: true,
                mouse: true,
                hoverMotion: true,
                pixelMouse: true,
                focusEvents: true,
                bracketedPaste: true,
                colorSchemeNotify: true,
                progress: true,
                extendedUnderline: true,
                cellPixelSize: true,
                graphemeClusters: true,
            );
    }
}

/**
`true` iff `a` claims nothing `b` does not (`CAP9`): every `bool` implies,
every ordered enum is `<=`, and an image protocol is a subset only of itself
or of `none`. `reducedMotion` is a preference, not a capability, and is
ignored.
*/
bool subsetOf(in TargetCapabilities a, in TargetCapabilities b) @safe pure nothrow @nogc
{
    static bool widens(T)(T x, T y)
    {
        static if (is(immutable T == immutable bool))
            return !x || y;
        else static if (is(immutable T == immutable ImageProtocol))
            return x == ImageProtocol.none || x == y;
        else static if (is(immutable T == immutable InputCapabilities))
            return widens(x.hover, y.hover) && widens(x.precisePointer, y.precisePointer)
                && x.maxPointers <= y.maxPointers && x.tier <= y.tier
                && widens(x.keyRelease, y.keyRelease);
        else
            return x <= y;
    }

    static foreach (i, _; TargetCapabilities.tupleof)
        static if (__traits(identifier, TargetCapabilities.tupleof[i]) != "reducedMotion")
            if (!widens(a.tupleof[i], b.tupleof[i]))
                return false;
    return true;
}

// ── border projection (GLY2) ────────────────────────────────────────────────

/// The box-drawing charset a cell target strokes a border with.
enum BoxCharset : ubyte
{
    none,        /// no edge
    ascii,       /// `+-|`
    light,       /// `┌─┐│└┘`
    rounded,     /// `╭─╮│╰╯`
    heavy,       /// `┏━┓┃┗┛`
    dashedLight, /// `┌┄┐┆└┘`
    dashedHeavy, /// `┏┅┓┇┗┛`
}

/// What $(LREF projectBorder) decided, and whether it lost something the
/// theme asked for (`CAP6`: a substitution is published, never silent).
struct BorderProjection
{
    BoxCharset charset;
    bool lossy; /// the request could not be honoured exactly on this target
}

/**
Projects a px-typed border onto a cell target (`GLY2`): width `0` → none;
below `unicode` → ASCII; `dotted`/`dashed` → the dashed variants; width `≥ 2`
→ heavy; radius `> 0` → rounded — which exists only for the light set, so
heavy-and-rounded degrades to heavy-square and says so.
*/
BorderProjection projectBorder(in BoxBorder border, int radius, in TargetCapabilities caps)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : max;

    const width = max(border.width.top, border.width.right, border.width.bottom,
        border.width.left);
    if (width <= 0 || border.style == BorderStyle.none)
        return BorderProjection(BoxCharset.none, false);
    if (!caps.unicode)
        return BorderProjection(BoxCharset.ascii, true);

    const heavy = width >= 2;
    const dashed = border.style == BorderStyle.dashed || border.style == BorderStyle.dotted;
    if (dashed)
        return BorderProjection(heavy ? BoxCharset.dashedHeavy : BoxCharset.dashedLight,
                                radius > 0);
    if (heavy)
        return BorderProjection(BoxCharset.heavy, radius > 0);
    return BorderProjection(radius > 0 ? BoxCharset.rounded : BoxCharset.light, false);
}

// ── tests ───────────────────────────────────────────────────────────────────

@("ui.tokens.tokenPath.grammarAndUniqueness")
@safe pure nothrow @nogc
unittest
{
    // TOK2: every slot has a well-formed path, and no two share one.
    static foreach (a; EnumMembers!Slot)
    {
        assert(isValidTokenPath(tokenPath(a)), tokenPath(a));
        static foreach (b; EnumMembers!Slot)
            static if (a != b)
                assert(tokenPath(a) != tokenPath(b), tokenPath(a));
    }
    assert(!isValidTokenPath(""));
    assert(!isValidTokenPath("Text.primary"));
    assert(!isValidTokenPath("text..primary"));
    assert(!isValidTokenPath("text.primary."));
    assert(!isValidTokenPath("500"));
    assert(!isValidTokenPath("text-primary"));
    assert(isValidTokenPath("indigo.500"));
    assert(isValidTokenPath("text.1st"));
}

@("ui.tokens.tierOf.groups")
@safe pure nothrow @nogc
unittest
{
    assert(tierOf(Slot.muted) == TokenTier.semantic);
    assert(tierOf(Slot.error) == TokenTier.semantic);
    assert(tierOf(Slot.inherit) == TokenTier.semantic);
    assert(tierOf(Slot.thumb) == TokenTier.component);
    assert(tierOf(Slot.diffAdded) == TokenTier.component);
    assert(tierOf(Slot.chip) == TokenTier.component);
}

@("ui.tokens.cssName.derivedFromPath")
@safe pure
unittest
{
    assert(cssName(Slot.muted) == "--spk-text-muted");
    assert(cssName(Slot.highlightBorder) == "--spk-twoslash-highlight-border");
    assert(cssName(Slot.thumb, InteractionState.hover) == "--spk-scrollbar-thumb-hover");
    assert(cssName(Slot.thumb, InteractionState.rest) == cssName(Slot.thumb));
}

@("ui.tokens.writeCssName.nogc")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkWriter;

    checkWriter!((ref w) => writeCssName(w, Slot.chromeAccent, InteractionState.disabled))
        ("--spk-chrome-accent-disabled");
}

@("ui.tokens.StateSet.precedence")
@safe pure nothrow @nogc
unittest
{
    // TOK4: the empty set is `rest`.
    StateSet none;
    assert(none.empty);
    assert(none.has(InteractionState.rest));
    assert(none.highest == InteractionState.rest);

    // TOK5: disabled > pressed > selected > focused > hover.
    const hf = StateSet.of(InteractionState.hover, InteractionState.focused);
    assert(hf.highest == InteractionState.focused);
    assert(!hf.has(InteractionState.rest));
    assert(hf.with_(InteractionState.disabled).highest == InteractionState.disabled);
    assert(hf.with_(InteractionState.pressed).without(InteractionState.pressed) == hf);
    assert(StateSet.of(InteractionState.selected, InteractionState.hover).highest
        == InteractionState.selected);
    // `rest` never contributes a bit.
    assert(StateSet.of(InteractionState.rest).empty);
}

@("ui.tokens.slotsWithin.checksEveryOp")
@safe pure nothrow @nogc
unittest
{
    static struct Op { Slot slot; }
    static immutable Op[3] ops = [Op(Slot.thumb), Op(Slot.track), Op(Slot.inherit)];
    static immutable Slot[3] declared = [Slot.thumb, Slot.track, Slot.inherit];
    static immutable Slot[2] narrower = [Slot.thumb, Slot.track];
    assert(slotsWithin(ops[], declared[]));
    assert(!slotsWithin(ops[], narrower[]));
    assert(slotsWithin(ops[0 .. 0], narrower[]));
}

@("ui.tokens.profiles.monotone")
@safe pure nothrow @nogc
unittest
{
    // CAP9: baseline ⊆ enhanced ⊆ full, and the relation is not trivially true.
    const b = capabilitiesOf(Profile.baseline);
    const e = capabilitiesOf(Profile.enhanced);
    const f = capabilitiesOf(Profile.full);
    assert(subsetOf(b, e));
    assert(subsetOf(e, f));
    assert(subsetOf(b, f));
    assert(!subsetOf(f, e));
    assert(!subsetOf(e, b));
    // CAP8: baseline is what a pipe gets — nothing on.
    assert(b.colorDepth == ColorDepth.none && !b.unicode && !b.mouse
        && b.input.tier == InteractionTier.passive);
    // A default-constructed declaration is the conservative one (CAP1).
    assert(subsetOf(TargetCapabilities.init, b));
}

@("ui.tokens.subsetOf.imagesAreNotOrdered")
@safe pure nothrow @nogc
unittest
{
    TargetCapabilities a, b;
    a.images = ImageProtocol.sixel;
    b.images = ImageProtocol.kitty;
    assert(!subsetOf(a, b)); // sixel is not "less than" kitty
    b.images = ImageProtocol.sixel;
    assert(subsetOf(a, b));
    a.images = ImageProtocol.none;
    b.images = ImageProtocol.iterm2;
    assert(subsetOf(a, b));
}

@("ui.tokens.projectBorder.table")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.geometry : Insets;

    TargetCapabilities cell;
    cell.unicode = true;
    TargetCapabilities dumb; // unicode = false

    static BoxBorder box(int w, BorderStyle s) @safe pure nothrow @nogc
    {
        BoxBorder b;
        b.width = Insets(w, w, w, w);
        b.style = s;
        return b;
    }

    // GLY2, row by row.
    assert(projectBorder(box(0, BorderStyle.solid), 0, cell) == BorderProjection(BoxCharset.none, false));
    assert(projectBorder(box(1, BorderStyle.none), 4, cell) == BorderProjection(BoxCharset.none, false));
    assert(projectBorder(box(1, BorderStyle.solid), 0, cell) == BorderProjection(BoxCharset.light, false));
    assert(projectBorder(box(1, BorderStyle.solid), 4, cell) == BorderProjection(BoxCharset.rounded, false));
    assert(projectBorder(box(2, BorderStyle.solid), 0, cell) == BorderProjection(BoxCharset.heavy, false));
    // heavy has no rounded corners: degrade, and say so (CAP6).
    assert(projectBorder(box(3, BorderStyle.solid), 4, cell) == BorderProjection(BoxCharset.heavy, true));
    assert(projectBorder(box(1, BorderStyle.dashed), 0, cell) == BorderProjection(BoxCharset.dashedLight, false));
    assert(projectBorder(box(1, BorderStyle.dotted), 0, cell) == BorderProjection(BoxCharset.dashedLight, false));
    assert(projectBorder(box(2, BorderStyle.dashed), 0, cell) == BorderProjection(BoxCharset.dashedHeavy, false));
    // below unicode everything is ASCII, and that is a loss.
    assert(projectBorder(box(1, BorderStyle.solid), 4, dumb) == BorderProjection(BoxCharset.ascii, true));
    // a one-sided border still counts by its widest side.
    BoxBorder oneSide;
    oneSide.width = Insets(0, 0, 0, 3);
    oneSide.style = BorderStyle.solid;
    assert(projectBorder(oneSide, 0, cell).charset == BoxCharset.heavy);
}
