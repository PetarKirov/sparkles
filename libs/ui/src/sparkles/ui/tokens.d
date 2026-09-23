/**
The design-system token vocabulary — the $(B draft) the
[design-system spec](../../../../../docs/specs/design-system/SPEC.md) traces
to: token tiers and paths (`TOK1`/`TOK2`), the interaction-state dimension
(`TOK4`/`TOK5`), the per-component slot check (`TOK6`), the target capability
declaration and its documented profiles
([`CAP1`/`CAP5`/`CAP9`](../../../../../docs/specs/design-system/capabilities.md)),
and the border projection onto a cell target
([`GLY2`](../../../../../docs/specs/design-system/glyphs.md)).

This module is the $(I vocabulary): the names, the precedence and the
projection tables, each with the test that makes its row of the spec
falsifiable. Slot resolution consumes the paths and states
($(MREF sparkles,ui,style)); the backends declare the capabilities, and
$(MREF sparkles,ui,degradation) reports what a declaration cost a frame.
*/
module sparkles.ui.tokens;

import std.traits : EnumMembers;

import sparkles.base.term_caps : BlockTier, ImageProtocol, OutputCapabilities, TermCaps;
import sparkles.base.term_color : ColorDepth;
import sparkles.input.capability : cellPointer, fromTerminal, InputCapabilities,
    staticPointer;
import sparkles.input.tier : InteractionTier;
import sparkles.ui.style : BorderStyle, BoxBorder, InteractionState, Slot;
import sparkles.ui.widget : WidgetTree;
import sparkles.wired.policy : AnyFormat, CaseStyle, resolveCaseStyle, WireCase,
    wireNames;

// ── tiers and paths (TOK1, TOK2) ────────────────────────────────────────────

/// Which layer of the token graph a token sits on (`TOK1`).
enum TokenTier : ubyte
{
    primitive, /// a raw value with no role: `indigo.500`
    semantic,  /// a role: `text.primary`, `status.error`
    component, /// a part of one component: `scrollbar.thumb`, `diff.added`
}

/**
The resolved token paths of every slot, in declaration order (`TOK2`): the
`@WireName` each `Slot` member carries, resolved by wired — the same table
`toJSON`/`fromJSON` and the DTCG theme file use, so a path is spelled exactly
once, on the member. Wired also proves the names unique at compile time.
*/
alias slotPaths = wireNames!(AnyFormat, Slot, resolveCaseStyle!(AnyFormat, Slot));

// `slotPaths[s]` indexes by ordinal, which is only right while `Slot` is the
// contiguous `0 .. n` its `ubyte` base implies — checked, not assumed.
static foreach (i, m; EnumMembers!Slot)
    static assert(m == i, "Slot must stay a contiguous 0-based enum");

/// The dotted path of a slot (`TOK2`), from $(LREF slotPaths).
string tokenPath(Slot s) @safe pure nothrow @nogc => slotPaths[s];

/// The groups whose slots are semantic roles; every other group is a
/// component namespace (`TOK1`). `inherit` is the one single-segment path.
private immutable string[] semanticGroups = ["inherit", "text", "status",
    "surface", "border", "accent", "link", "selection", "focus", "shadow"];

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
// `InteractionState` and `StateSet` live beside `Slot` in `sparkles.ui.style`,
// where resolution consumes them; this module adds only their wire names.

/// The resolved wire names of the states (`WEB1`'s CSS suffixes), from the
/// enum's own `@WireCase` — declaration order, like $(LREF slotPaths).
alias stateNames = wireNames!(AnyFormat, InteractionState,
    resolveCaseStyle!(AnyFormat, InteractionState));

static foreach (i, m; EnumMembers!InteractionState)
    static assert(m == i, "InteractionState must stay a contiguous 0-based enum");

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
        put(w, stateNames[state]);
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

/**
The first slot `tree` references outside `allowed` (`TOK6`), or `Slot.inherit`
when every node, span and drawn border stays inside it — the tree-level form
of $(LREF slotsWithin), needing neither a layout nor a palette. `inherit` is
"no slot of its own" and never counts; a decoration's `borderSlot` counts only
when the decoration draws an edge, since every decoration carries the default.
*/
Slot firstUndeclaredSlot(in WidgetTree tree, scope const(Slot)[] allowed)
    @safe pure nothrow @nogc
{
    static bool declared(Slot s, scope const(Slot)[] allowed)
    {
        if (s == Slot.inherit)
            return true;
        foreach (a; allowed)
            if (a == s)
                return true;
        return false;
    }

    foreach (ref const n; tree.nodes)
    {
        if (!declared(n.slot, allowed))
            return n.slot;
        const bw = n.decoration.borderWidth;
        if ((bw.top > 0 || bw.right > 0 || bw.bottom > 0 || bw.left > 0)
            && !declared(n.decoration.borderSlot, allowed))
            return n.decoration.borderSlot;
        foreach (ref const sp; n.spans)
            if (!declared(sp.slot, allowed))
                return sp.slot;
    }
    return Slot.inherit;
}

@("ui.tokens.firstUndeclaredSlot.nodesSpansAndDrawnBorders")
@safe unittest
{
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : Decoration;
    import sparkles.ui.widget : Builder, TextSpan, Widget, WidgetKind;

    auto b = Builder();
    const t = b.add(Widget(kind: WidgetKind.text, text: "x", slot: Slot.muted));
    const r = b.add(Widget(kind: WidgetKind.rich,
        spans: [TextSpan("y", Slot.error)]));
    // A decoration with no drawn edge carries the default `borderSlot`, which
    // must not count; the same decoration with an edge does.
    const plain = b.add(Widget(kind: WidgetKind.box, decoration: Decoration()));
    const tree = b.finish(b.add(Widget(kind: WidgetKind.column,
        children: [t, r, plain])));
    static immutable Slot[2] ok = [Slot.muted, Slot.error];
    assert(firstUndeclaredSlot(tree, ok[]) == Slot.inherit);
    static immutable Slot[1] narrow = [Slot.muted];
    assert(firstUndeclaredSlot(tree, narrow[]) == Slot.error);

    auto b2 = Builder();
    const edged = b2.add(Widget(kind: WidgetKind.box,
        decoration: Decoration(borderWidth: Insets.all(1), borderSlot: Slot.borderStrong)));
    const tree2 = b2.finish(edged);
    assert(firstUndeclaredSlot(tree2, ok[]) == Slot.borderStrong);
}

// ── target capabilities (CAP1, CAP2, CAP5, CAP9) ────────────────────────────

/**
What one render target can render and receive (`CAP1`) — the composition of
the two layers below the toolkit plus the axes only a target has:

$(LIST
    * $(REF OutputCapabilities, sparkles,base,term_caps) — what may be emitted
        (color tier, glyph coverage, links, clipboard, images, …). A terminal's
        answers come from `TermCaps.output`; a window or HTML sink declares
        constants. Reachable directly (`caps.colorDepth`) via `alias this`.
    * $(REF InputCapabilities, sparkles,input,capability) — the input axes; a
        terminal's from `fromTerminal(termCaps)`, a window's from the presets.
    * the sub-cell chrome a target honours rather than projects (`TOK7`), and
        the user's motion preference (`ACC5`).
)

Every default is the conservative answer, so a default-constructed declaration
claims nothing (`CAP1`). The documented profiles are $(LREF capabilitiesOf); a
backend's real declaration is derived from its own probing (`CAP3`), never
from a profile.
*/
struct TargetCapabilities
{
    OutputCapabilities output; /// what may be emitted (`base`'s vocabulary)
    alias output this;

    /// The input axes (`IXB10`). `InputCapabilities`' own defaults describe a
    /// window; here they are overridden to the conservative answer.
    InputCapabilities input = InputCapabilities(
        hover: false, precisePointer: false, maxPointers: 0,
        tier: InteractionTier.passive, focusEvents: false, pasteEvents: false);

    bool subCellScroll;    /// scroll offsets finer than a cell (GUI/Web)
    bool proportionalText; /// a proportional face for `FontRole.docs` (GUI/Web)
    bool radius;           /// corner radius honoured, not projected
    bool shadow;           /// drop shadow honoured
    bool alpha;            /// translucent fills honoured

    bool reducedMotion;    /// the user prefers no animation (`ACC5`)
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
                output: OutputCapabilities(
                    colorDepth: ColorDepth.ansi256,
                    unicode: true,
                    blocks: BlockTier.half,
                    hyperlinks: true,
                ),
                input: cellPointer, // SGR mouse, focus and paste events
            );
        case Profile.full:
            return TargetCapabilities(
                output: OutputCapabilities(
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
                    progress: true,
                    extendedUnderline: true,
                    cellPixelSize: true,
                    graphemeClusters: true,
                    colorSchemeNotify: true,
                ),
                input: InputCapabilities(
                    hover: true, precisePointer: true, maxPointers: 1,
                    tier: InteractionTier.precise, keyRelease: true),
            );
    }
}

/**
The most `a` and `b` both claim (`CAP9`'s lattice meet): every `bool` both
must hold, every ordered enum or count the smaller, an image protocol only
when both name the same one, nested capability structs field by field.
`reducedMotion` is a preference, and either asking for it wins.

What a host paints for when it is narrowed to a profile: its own declaration
met with the profile's, so a window narrowed to `enhanced` loses what a
256-color terminal lacks without gaining the hyperlinks it never had.
*/
TargetCapabilities meet(in TargetCapabilities a, in TargetCapabilities b)
    @safe pure nothrow @nogc
{
    static T low(T)(in T x, in T y)
    {
        static if (is(immutable T == immutable bool))
            return x && y;
        else static if (is(immutable T == immutable ImageProtocol))
            return x == y ? x : ImageProtocol.none;
        else static if (is(T == struct))
        {
            T r;
            static foreach (i, _; T.tupleof)
                r.tupleof[i] = low(x.tupleof[i], y.tupleof[i]);
            return r;
        }
        else
            return x < y ? x : y;
    }

    auto r = low(a, b);
    r.reducedMotion = a.reducedMotion || b.reducedMotion;
    return r;
}

/**
A terminal's declaration from one snapshot (`CAP1`): its output half verbatim,
its input half through `fromTerminal`. The target-only axes stay off — a cell
grid scrolls by whole cells, draws one face, and projects radius, shadow and
alpha rather than honouring them.
*/
TargetCapabilities terminalCapabilities(in TermCaps t) @safe pure nothrow @nogc
    => TargetCapabilities(output: t.output, input: fromTerminal(t));

/**
What `target` declares (`CAP1`), by introspection: its `capabilities` member
when it has one of type $(LREF TargetCapabilities), else the conservative
`.init` — a target that has not thought about the question claims nothing.
*/
TargetCapabilities declaredCapabilities(T)(auto ref const T target)
{
    static if (is(typeof(target.capabilities) : const TargetCapabilities))
        return target.capabilities;
    else
        return TargetCapabilities.init;
}

/**
`true` iff `a` claims nothing `b` does not (`CAP9`): every `bool` implies,
every ordered enum or count is `<=`, an image protocol is a subset only of
itself or of `none`, and nested capability structs are compared field-wise.
`reducedMotion` is a preference, not a capability, and is ignored.
*/
bool subsetOf(in TargetCapabilities a, in TargetCapabilities b) @safe pure nothrow @nogc
{
    static bool widens(T)(in T x, in T y)
    {
        static if (is(immutable T == immutable bool))
            return !x || y;
        else static if (is(immutable T == immutable ImageProtocol))
            return x == ImageProtocol.none || x == y;
        else static if (is(T == struct))
        {
            static foreach (i, _; T.tupleof)
                if (!widens(x.tupleof[i], y.tupleof[i]))
                    return false;
            return true;
        }
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

/// The stroke family a cell target draws a border's edges with (`GLY2`).
enum BoxCharset : ubyte
{
    none,        /// no edge
    ascii,       /// `+-|`
    asciiDotted, /// `+.:` — a dotted border keeps its texture below `unicode`
    light,       /// `┌─┐│└┘` (`╭╮╰╯` when rounded)
    heavy,       /// `┏━┓┃┗┛`
    double_,     /// `╔═╗║╚╝`
    dashedLight, /// `┌╌┐╎└┘` (`╭╮╰╯` when rounded)
    dashedHeavy, /// `┏╍┓╏┗┛`
    dottedLight, /// `┌┈┐┊└┘` (`╭╮╰╯` when rounded)
    dottedHeavy, /// `┏┉┓┋┗┛`
}

/// What $(LREF projectBorder) decided, and whether it lost something the
/// theme asked for (`CAP6`: a substitution is published, never silent).
struct BorderProjection
{
    BoxCharset charset;
    bool rounded; /// corners drawn as arcs — only the light families have them
    bool lossy;   /// the request could not be honoured exactly on this target
}

/**
Projects a px-typed border onto a cell target (`GLY2`): width `0` → none;
below `unicode` → ASCII (dotted keeps `.`/`:`); `double_` → the double set
(weight and radius are meaningless there, so a radius is reported lost);
`dashed`/`dotted` → their own dash runs; width `≥ 2` → the heavy family;
radius `> 0` → arcs, which exist only for the light families. When a request
wants both — heavy and rounded — the radius wins: the shape is what a reader
recognises a panel by, so it draws light arcs and reports the weight lost
(design-system D31). `double_` has no arcs at all and reports the radius
lost.
*/
BorderProjection projectBorder(in BoxBorder border, int radius, in TargetCapabilities caps)
    @safe pure nothrow @nogc
{
    import std.algorithm.comparison : max;

    const width = max(border.width.top, border.width.right, border.width.bottom,
        border.width.left);
    if (width <= 0 || border.style == BorderStyle.none)
        return BorderProjection(BoxCharset.none);
    if (!caps.unicode)
        return BorderProjection(border.style == BorderStyle.dotted
            ? BoxCharset.asciiDotted : BoxCharset.ascii, lossy: true);

    // The radius wins over the weight (D31): arcs exist only in the light
    // families, and a rounded panel drawn square reads as a different thing.
    const heavy = width >= 2 && radius <= 0;
    BoxCharset c;
    final switch (border.style) with (BorderStyle)
    {
        case none: assert(0);
        case solid:   c = heavy ? BoxCharset.heavy : BoxCharset.light; break;
        case dashed:  c = heavy ? BoxCharset.dashedHeavy : BoxCharset.dashedLight; break;
        case dotted:  c = heavy ? BoxCharset.dottedHeavy : BoxCharset.dottedLight; break;
        case double_: c = BoxCharset.double_; break;
    }
    const arcs = c == BoxCharset.light || c == BoxCharset.dashedLight
        || c == BoxCharset.dottedLight;
    const weightLost = width >= 2 && !heavy && c != BoxCharset.double_;
    return BorderProjection(c, rounded: radius > 0 && arcs,
        lossy: (radius > 0 && !arcs) || weightLost);
}

/// The six glyphs a box in one family is stroked with.
struct BoxGlyphs
{
    dchar horizontal, vertical;
    dchar topLeft, topRight, bottomLeft, bottomRight;
}

/// The glyphs of a projection — the one table every cell painter strokes from
/// (`GLY2`). `none` is blanks; the ASCII families are ASCII.
BoxGlyphs boxGlyphs(in BorderProjection p) @safe pure nothrow @nogc
{
    static BoxGlyphs arcsOr(dchar h, dchar v, bool rounded)
        => rounded ? BoxGlyphs(h, v, '╭', '╮', '╰', '╯')
            : BoxGlyphs(h, v, '┌', '┐', '└', '┘');

    final switch (p.charset) with (BoxCharset)
    {
        case none:        return BoxGlyphs(' ', ' ', ' ', ' ', ' ', ' ');
        case ascii:       return BoxGlyphs('-', '|', '+', '+', '+', '+');
        case asciiDotted: return BoxGlyphs('.', ':', '+', '+', '+', '+');
        case light:       return arcsOr('─', '│', p.rounded);
        case dashedLight: return arcsOr('╌', '╎', p.rounded);
        case dottedLight: return arcsOr('┈', '┊', p.rounded);
        case heavy:       return BoxGlyphs('━', '┃', '┏', '┓', '┗', '┛');
        case dashedHeavy: return BoxGlyphs('╍', '╏', '┏', '┓', '┗', '┛');
        case dottedHeavy: return BoxGlyphs('┉', '┋', '┏', '┓', '┗', '┛');
        case double_:     return BoxGlyphs('═', '║', '╔', '╗', '╚', '╝');
    }
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
    assert(tierOf(Slot.accentPrimary) == TokenTier.semantic);
    assert(tierOf(Slot.focusRing) == TokenTier.semantic);
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
    assert(b.colorDepth == ColorDepth.none && !b.unicode && b.input.maxPointers == 0
        && b.input.tier == InteractionTier.passive);
    // The static HTML preset is a baseline target with hover: still ⊆ enhanced.
    TargetCapabilities html;
    html.input = staticPointer;
    assert(subsetOf(html, e) && !subsetOf(html, b));
    // A default-constructed declaration is the conservative one (CAP1).
    assert(subsetOf(TargetCapabilities.init, b));
}

@("ui.tokens.meet.isTheGreatestCommonLowerBound")
@safe pure nothrow @nogc
unittest
{
    const b = capabilitiesOf(Profile.baseline);
    const e = capabilitiesOf(Profile.enhanced);
    const f = capabilitiesOf(Profile.full);
    foreach (x; [b, e, f])
        foreach (y; [b, e, f])
        {
            const m = meet(x, y);
            assert(subsetOf(m, x) && subsetOf(m, y), "a lower bound");
            if (subsetOf(x, y))
                assert(meet(x, y) == x, "the greatest one");
        }
    // Unordered protocols meet at `none`; a preference is kept if either
    // side asks for it.
    TargetCapabilities k, s;
    k.images = ImageProtocol.kitty;
    s.images = ImageProtocol.sixel;
    s.reducedMotion = true;
    assert(meet(k, s).images == ImageProtocol.none && meet(k, s).reducedMotion);
    // A window narrowed to `enhanced` gains nothing it lacked.
    TargetCapabilities window = f;
    window.hyperlinks = false;
    window.radius = true;
    const narrowed = meet(window, e);
    assert(!narrowed.hyperlinks && !narrowed.radius && narrowed.unicode);
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

@("ui.tokens.terminalCapabilities.bothHalvesFromOneSnapshot")
@safe pure nothrow @nogc
unittest
{
    TermCaps t;
    t.colorDepth = ColorDepth.ansi256;
    t.unicode = true;
    t.hyperlinks = true;
    t.mouseSgr = true;
    t.anyMotion = true;
    t.bracketedPaste = true;
    const c = terminalCapabilities(t);
    assert(c.output == t.output);
    assert(c.input == fromTerminal(t));
    assert(c.input.hover && c.input.pasteEvents && !c.input.focusEvents);
    // The target-only axes are a window's, never a terminal's.
    assert(!c.subCellScroll && !c.proportionalText && !c.radius && !c.shadow && !c.alpha);
    // An unprobed snapshot declares the baseline exactly (`CAP8`).
    assert(terminalCapabilities(TermCaps.init) == capabilitiesOf(Profile.baseline));
}

@("ui.tokens.declaredCapabilities.byIntrospection")
@safe pure nothrow @nogc
unittest
{
    static struct Silent {}
    static struct Declares { TargetCapabilities capabilities; }

    Declares d;
    d.capabilities.unicode = true;
    assert(declaredCapabilities(Silent()) == TargetCapabilities.init);
    assert(declaredCapabilities(d).unicode);
}

@("ui.tokens.projectBorder.table")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.geometry : Insets;

    TargetCapabilities cell;
    cell.unicode = true;
    TargetCapabilities dumb; // unicode = false

    // `O7`, exhaustive: every (width, style, radius, unicode) the domain has,
    // against a hand-written row — charset, arcs, loss, and the glyphs drawn.
    static struct Row { int w; BorderStyle s; int r; bool uni; BoxCharset c; bool arcs;
        bool lossy; dstring glyphs; }
    alias S = BorderStyle;
    alias C = BoxCharset;
    static immutable Row[] rows = [
        // width 0 and style none draw nothing, whatever else is asked.
        Row(0, S.solid, 0, true, C.none, false, false, "      "),
        Row(0, S.solid, 4, false, C.none, false, false, "      "),
        Row(1, S.none, 4, true, C.none, false, false, "      "),
        Row(2, S.none, 0, false, C.none, false, false, "      "),
        // light families, square and arced
        Row(1, S.solid, 0, true, C.light, false, false, "─│┌┐└┘"),
        Row(1, S.solid, 4, true, C.light, true, false, "─│╭╮╰╯"),
        Row(1, S.dashed, 0, true, C.dashedLight, false, false, "╌╎┌┐└┘"),
        Row(1, S.dashed, 4, true, C.dashedLight, true, false, "╌╎╭╮╰╯"),
        Row(1, S.dotted, 0, true, C.dottedLight, false, false, "┈┊┌┐└┘"),
        Row(1, S.dotted, 4, true, C.dottedLight, true, false, "┈┊╭╮╰╯"),
        // heavy families; heavy and rounded at once keeps the arcs and
        // reports the weight lost (D31)
        Row(2, S.solid, 0, true, C.heavy, false, false, "━┃┏┓┗┛"),
        Row(3, S.solid, 4, true, C.light, true, true, "─│╭╮╰╯"),
        Row(2, S.dashed, 0, true, C.dashedHeavy, false, false, "╍╏┏┓┗┛"),
        Row(2, S.dashed, 4, true, C.dashedLight, true, true, "╌╎╭╮╰╯"),
        Row(2, S.dotted, 0, true, C.dottedHeavy, false, false, "┉┋┏┓┗┛"),
        Row(2, S.dotted, 4, true, C.dottedLight, true, true, "┈┊╭╮╰╯"),
        // double: one weight, no arcs
        Row(1, S.double_, 0, true, C.double_, false, false, "═║╔╗╚╝"),
        Row(3, S.double_, 0, true, C.double_, false, false, "═║╔╗╚╝"),
        Row(1, S.double_, 2, true, C.double_, false, true, "═║╔╗╚╝"),
        // below unicode: ASCII, always a loss; dotted keeps its texture
        Row(1, S.solid, 0, false, C.ascii, false, true, "-|++++"),
        Row(2, S.solid, 4, false, C.ascii, false, true, "-|++++"),
        Row(1, S.dashed, 0, false, C.ascii, false, true, "-|++++"),
        Row(1, S.double_, 0, false, C.ascii, false, true, "-|++++"),
        Row(1, S.dotted, 4, false, C.asciiDotted, false, true, ".:++++"),
    ];

    foreach (ref row; rows)
    {
        BoxBorder b;
        b.width = Insets(row.w, row.w, row.w, row.w);
        b.style = row.s;
        const p = projectBorder(b, row.r, row.uni ? cell : dumb);
        assert(p == BorderProjection(row.c, row.arcs, row.lossy));
        const g = boxGlyphs(p);
        assert([g.horizontal, g.vertical, g.topLeft, g.topRight, g.bottomLeft,
            g.bottomRight] == row.glyphs);
    }

    // Every style × every width 0..3 × radius {0, 4} × unicode is in the
    // domain above by construction; check the rows cover each style.
    static foreach (s; [S.none, S.solid, S.dashed, S.dotted, S.double_])
    {{
        bool seen;
        foreach (ref row; rows)
            seen |= row.s == s;
        assert(seen);
    }}

    // a one-sided border still counts by its widest side.
    BoxBorder oneSide;
    oneSide.width = Insets(0, 0, 0, 3);
    oneSide.style = BorderStyle.solid;
    assert(projectBorder(oneSide, 0, cell).charset == BoxCharset.heavy);
}
