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

import sparkles.base.term_caps : BlockTier, ImageProtocol, OutputCapabilities;
import sparkles.base.term_color : ColorDepth;
import sparkles.input.capability : cellPointer, InputCapabilities, staticPointer;
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

/// The box-drawing charset a cell target strokes a border with.
enum BoxCharset : ubyte
{
    none,        /// no edge
    ascii,       /// `+-|`
    light,       /// `┌─┐│└┘`
    rounded,     /// `╭─╮│╰╯`
    heavy,       /// `┏━┓┃┗┛`
    double_,     /// `╔═╗║╚╝`
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
below `unicode` → ASCII; `double_` → the double set (weight and radius are
meaningless there, so a radius is reported lost); `dotted`/`dashed` → the
dashed variants; width `≥ 2` → heavy; radius `> 0` → rounded — which exists
only for the light set, so heavy-and-rounded degrades to heavy-square and says
so.
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

    if (border.style == BorderStyle.double_)
        return BorderProjection(BoxCharset.double_, radius > 0);
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
    assert(projectBorder(box(1, BorderStyle.double_), 0, cell) == BorderProjection(BoxCharset.double_, false));
    assert(projectBorder(box(3, BorderStyle.double_), 2, cell) == BorderProjection(BoxCharset.double_, true));
    // below unicode everything is ASCII, and that is a loss.
    assert(projectBorder(box(1, BorderStyle.solid), 4, dumb) == BorderProjection(BoxCharset.ascii, true));
    // a one-sided border still counts by its widest side.
    BoxBorder oneSide;
    oneSide.width = Insets(0, 0, 0, 3);
    oneSide.style = BorderStyle.solid;
    assert(projectBorder(oneSide, 0, cell).charset == BoxCharset.heavy);
}
