/**
The drawing seam for $(MREF sparkles,ui): the primitive vocabulary every backend
implements, expressed as a $(B Design-by-Introspection capability concept)
($(LREF isCanvas)) rather than an interface — so the interpreter's `@safe`/`@nogc`
attributes are $(I inferred) from the concrete canvas ($(LREF RecordingCanvas) is
`@safe`; a raylib canvas is `@system`), and no vtable/GC indirection sits in the
paint hot path.

A canvas draws a handful of primitives; $(LREF DrawOp) is their reified,
backend-neutral form — the boundary between the pure model
(`buildDisplayList`) and the impure painter (`interp/immediate.paint`). Input is
$(B not) defined here: the state machines in $(MREF sparkles,ui,state) consume
the shared `sparkles:input` vocabulary, which backends produce.

$(B An operation is a sum, not a record with unused fields.) It was the latter,
and the cost was structural: every operation carried a 512-byte inline text slot
and a whole $(REF Visual, sparkles,ui,style) — 656 bytes for a `popClip` that
needs neither — which made a 4096-operation frame buffer 2.6 MB, big enough to
overflow a thread stack and force two separate stack-growth fixes. It also
truncated a text run at 512 bytes, mid-UTF-8, silently. So each kind is now its
own payload carrying only what it uses, over `std.sumtype` — the same shape
$(REF Event, sparkles,input,events) uses for the same reason — and the bulky
parts live in a $(MREF sparkles,ui,arena):

$(UL
    $(LI $(LREF TextRun.text) is a slice interned in the arena: no cap, no
    truncation, 16 bytes on the operation.)
    $(LI $(LREF FillRect.chrome) is a pointer, non-null only for a box that
    actually has a border, shadow, radius or arrow — which most fills do not.)
)

The result is $(B 64 bytes) per operation, asserted below, and one lifetime
rule: an operation is valid while the buffer that built it is alive and unreset
($(MREF sparkles,ui,cmd_buffer)).

$(B Reading an operation.) Dispatch with `op.match!(…)`. The accessors
($(LREF kind), $(LREF rect), $(LREF text), …) are free functions, so `op.rect`
and `op.text` read as they always did; they exist for the call sites that ask
one question of an operation, while a painter — which asks every question —
matches.
*/
module sparkles.ui.canvas;

import std.sumtype : SumType;

/// Re-exported so consumers dispatch with `op.match!(…)` without importing
/// `std.sumtype` themselves.
public import std.sumtype : match;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.geometry : Point, Rect, Size, cellsOf;
import sparkles.ui.state : scrollbarThumb;
import sparkles.base.term_style : UnderlineStyle;
import sparkles.ui.style : BoxBorder, FontRole, Shadow, Slot, Visual;

/// How a $(LREF Line)'s stroke is drawn.
enum LineStyle : ubyte
{
    solid, /// a straight rule (connectors, borders)
    wavy,  /// a wavy underline (the twoslash error squiggle)
}

/**
Where a sub-cell band sits within a cell rect (`UIA2`).

The toolkit's geometry is whole cells, but real chrome is thinner than a
cell: a 1 px pane divider, the hairline under a header, a separator above
a toolbar, or a scrollbar rail expanding around a border. Naming the $(B edge)
instead of a pixel count keeps that expressible without giving the toolkit
device units — the same bargain `LineStyle` already makes.
*/
enum RuleEdge : ubyte
{
    top,      /// along the rect's top edge
    bottom,   /// along its bottom edge
    left,     /// along its left edge
    right,    /// along its right edge
    centerX,  /// vertically, down the rect's horizontal middle
    centerY,  /// horizontally, across its vertical middle
}

/**
Which primitive an operation is.

The sum type is the truth; this is the answer to "which arm is it" for a caller
that only wants to ask that (a test, a filter, a counter). $(LREF kind) derives
it, so the two cannot disagree.
*/
enum OpKind : ubyte
{
    fillRect,  /// fill `rect` with the payload's background
    textRun,   /// draw `text` at `rect.origin` (`rect.width` = advance in cells)
    glyph,     /// draw a single glyph at `rect.origin`
    line,      /// stroke `rect.origin` → `to`
    rule,      /// a hairline along `ruleEdge` of `rect`
    scrollbar, /// a semantic scrollbar band along `ruleEdge` of `rect`
    pushClip,  /// clip subsequent operations to `rect` (nested clips intersect)
    popClip,   /// undo the matching `pushClip`
}

/**
The resolved paint of an operation that draws content — everything a backend
reads to put colour on a cell, and nothing about boxes.

Split out of $(REF Visual, sparkles,ui,style) rather than referenced whole: a
`Visual` is ~72 bytes because it also carries border, shadow, radius and arrow,
which only a decorated fill uses. This is 16, and it is what a text run, a
glyph, a line and a rule share.
*/
struct Ink
{
    RgbColor fg;              /// foreground, already resolved against the page
    ubyte fgAlpha = 0xFF;     /// foreground opacity
    RgbColor bg;              /// background (valid only when `hasBg`)
    ubyte bgAlpha = 0xFF;     /// background opacity
    bool hasBg;               /// paint a background behind the content?
    UnderlineStyle underline; /// text-decoration underline
    ubyte underlineAlpha = 0xFF; /// underline opacity (hover-fade)
    FontRole fontRole;        /// which font family the run wants
    ushort styleBits;         /// packed `TextAttr` flags (bold/italic/…)
    ushort fontScale = 100;   /// font size as a percentage of 1em
}

/**
The bulky, rare half of a decorated box.

Border, shadow, radius and arrow are ~52 bytes that only a box with chrome
uses, and most fills are a flat rectangle of colour. Kept behind a pointer into
the frame arena, they cost a decorated fill one indirection and every other
operation nothing.
*/
struct BoxChrome
{
    BoxBorder border;   /// resolved box border
    int borderRadius;   /// corner radius in px (0 = square)
    Shadow shadow;      /// resolved drop shadow
    bool arrow;         /// draw a popup arrow/tail off the top edge?
    int arrowOffset;    /// arrow offset from the left, in cells

    /// Whether any of it would actually paint — the test the display list
    /// makes before spending an arena slot.
    bool any() const @safe pure nothrow @nogc
        => border.any || shadow.any || arrow || borderRadius > 0;
}

// ---------------------------------------------------------------------------
// The payloads.
// ---------------------------------------------------------------------------

/// Fill `rect`, and paint whatever chrome `chrome` describes.
struct FillRect
{
    Rect rect;
    const(BoxChrome)* chrome; /// null unless the box has border/shadow/radius/arrow
    RgbColor fg;              /// carried for backends that tint chrome from it
    ubyte fgAlpha = 0xFF;
    RgbColor bg;
    ubyte bgAlpha = 0xFF;
    bool hasBg;               /// a border-only box fills nothing
    Slot slot = Slot.inherit;
}

/**
Draw `text` at `rect.origin`, advancing `rect.width` cells.

`text` is $(B borrowed from the arena that interned it), not owned by the
operation — which is what took 512 bytes off every operation in the frame and
removed the cap that silently cut a long run mid-codepoint.
*/
struct TextRun
{
    Rect rect;
    const(char)[] text;
    Ink ink;
    Slot slot = Slot.inherit;
}

/// Draw one glyph at `at`.
struct Glyph
{
    Point at;
    dchar glyph;
    Ink ink;
    Slot slot = Slot.inherit;
}

/// Stroke `from` → `to`.
struct Line
{
    Point from;
    Point to;
    Ink ink;
    LineStyle style;
    Slot slot = Slot.inherit;
}

/// A hairline along `edge` of `rect` (`UIA2`).
struct Rule
{
    Rect rect;
    Ink ink;
    RuleEdge edge;
    Slot slot = Slot.inherit;
}

/// A semantic scrollbar band along `edge` of `rect` — extents in content
/// units, so a backend resolves the thumb at its own resolution (`STM2`).
struct Scrollbar
{
    Rect rect;
    int content;            /// content extent, in content units
    int viewport;           /// viewport extent, in content units
    int offset;             /// scroll offset, in content units
    RgbColor fg;            /// the thumb's colour
    ubyte fgAlpha = 0xFF;
    RgbColor trackColor;    /// the optional painted track behind the thumb
    ubyte trackAlpha = 0xFF; /// ...at this alpha (the palette dims the track)
    bool trackLit;          /// paint that track?
    ubyte expandPercent;    /// rail expansion: 0 idle, 100 expanded
    RuleEdge edge;
    Slot slot = Slot.inherit;
    dchar trackGlyph = '│'; /// the cell fallback's track glyph
    dchar thumbGlyph = '█'; /// the cell fallback's thumb glyph
}

/// Clip subsequent operations to `rect`; nested clips intersect.
struct PushClip
{
    Rect rect;
}

/// Undo the matching $(LREF PushClip).
struct PopClip
{
}

// A slice whose target outlives the aggregate it was reached through. Not a
// general-purpose escape: the one caller is `DrawOp.text`, whose comment
// carries the argument.
private const(char)[] launder(scope const(char)[] s) @trusted pure nothrow @nogc
{
    // Through an integer, because `dip1000` follows a pointer: the address is
    // the arena's, and the arena is not what `scope` here is about.
    const addr = cast(size_t) s.ptr;
    return (cast(const(char)*) addr)[0 .. s.length];
}

/// The sum itself: exactly one of the payloads above.
alias Payload = SumType!(FillRect, TextRun, Glyph, Line, Rule, Scrollbar,
    PushClip, PopClip);

/**
One reified drawing command in abstract cell space.

`buildDisplayList` ($(MREF sparkles,ui,display_list)) emits a `DrawOp[]`; a
painter walks it once. Dispatch with `op.match!(…)` — $(LREF Payload) is
`alias this`'d, so the sum type's whole API is this type's — and ask a single
question with the accessors below.

$(B Why a struct around the sum rather than the bare alias.) Two reasons, both
about the boundary being usable:

$(UL
    $(LI $(B The accessors are members.) As free functions they would need a
    UFCS name in scope, so every consumer's selective import would have to list
    every accessor it happens to use — a rename tax on ~17 modules for no
    benefit.)
    $(LI $(B Assignment.) `std.sumtype` marks `opAssign` `@system` whenever
    another alternative carries indirections, because overwriting a variant
    while a reference into it is outstanding reads the new bytes through the
    old type. Ours do (a slice, a pointer), so a plain `DrawOp[]` or
    `SmallBuffer!DrawOp` would be unusable from `@safe` code — including the
    display-list walk, which is `@safe pure nothrow @nogc` on purpose. The
    assignment below is the `@trusted` island that answers it, and the
    guarantee it rests on is stated there.)
)
*/
struct DrawOp
{
    /// The payload, and the sum type's API by `alias this`.
    Payload payload;
    alias payload this;

    /**
    Wraps one payload.

    `@trusted` for the same reason as $(LREF DrawOp.opAssign), minus the
    hazard: the operation being built is fresh, so there is no live reference
    into a previous variant to invalidate.
    */
    this(P)(P p) @trusted
    if (__traits(compiles, Payload(P.init)))
    {
        payload = P.init;  // a fresh, indirection-free variant to overwrite
        payload = p;
    }

    /**
    Replaces this operation.

    $(B The `@trusted` claim.) `std.sumtype`'s hazard is a reference into the
    old variant outliving the overwrite — `s.tryMatch!((ref int* p) { s = 123;
    return *p; })`. A `DrawOp` is written into a buffer and later read; nothing
    in the toolkit holds a `ref` to a payload across an assignment to the same
    operation, and the pointers a payload carries (interned text, box chrome)
    are owned by the arena, so overwriting one frees nothing and dangles
    nothing. What is left is a bit copy of plain data.
    */
    ref DrawOp opAssign(DrawOp rhs) @trusted pure nothrow @nogc return
    {
        payload = rhs.payload;
        return this;
    }

    /**
    Moves the operation by `(dx, dy)`.

    What a caller needs when it composes a subtree built at the origin into a
    larger frame — an overlay panel laid out on its own and then placed along
    an edge. It lives here because only the sum knows which of its arms carry
    geometry, and a caller reaching in to shift "the rect" would have to know
    too.
    */
    void translate(int dx, int dy) @safe pure nothrow @nogc scope
    {
        static Rect moved(in Rect r, int dx, int dy)
            => Rect(r.x + dx, r.y + dy, r.width, r.height);
        static Point movedPoint(in Point p, int dx, int dy)
            => Point(p.x + dx, p.y + dy);

        payload.match!(
            (ref FillRect f) { f.rect = moved(f.rect, dx, dy); },
            (ref TextRun t) { t.rect = moved(t.rect, dx, dy); },
            (ref Glyph g) { g.at = movedPoint(g.at, dx, dy); },
            (ref Line l)
            {
                l.from = movedPoint(l.from, dx, dy);
                l.to = movedPoint(l.to, dx, dy);
            },
            (ref Rule r) { r.rect = moved(r.rect, dx, dy); },
            (ref Scrollbar s) { s.rect = moved(s.rect, dx, dy); },
            (ref PushClip c) { c.rect = moved(c.rect, dx, dy); },
            (ref PopClip _) {},
        );
    }

@safe pure nothrow @nogc const scope:

    /// Which primitive this is.
    OpKind kind()
        => payload.match!(
            (in FillRect _) => OpKind.fillRect,
            (in TextRun _) => OpKind.textRun,
            (in Glyph _) => OpKind.glyph,
            (in Line _) => OpKind.line,
            (in Rule _) => OpKind.rule,
            (in Scrollbar _) => OpKind.scrollbar,
            (in PushClip _) => OpKind.pushClip,
            (in PopClip _) => OpKind.popClip,
        );

    /**
    Where the operation lands.

    A glyph and a line report the one-cell rect and the start point they anchor
    at, so a caller that only wants "where" need not know which arm it holds; a
    `popClip` has no geometry and reports `Rect.init`.
    */
    Rect rect()
        => payload.match!(
            (in FillRect f) => f.rect,
            (in TextRun t) => t.rect,
            (in Glyph g) => Rect(g.at.x, g.at.y, 1, 1),
            (in Line l) => Rect(l.from.x, l.from.y, 0, 0),
            (in Rule r) => r.rect,
            (in Scrollbar s) => s.rect,
            (in PushClip c) => c.rect,
            (in PopClip _) => Rect.init,
        );

    /**
    The run's bytes — a borrow from the arena that interned them, empty for
    every other kind.

    $(B The `@trusted` claim.) The compiler sees a slice reached through a
    `scope` operation and confines it to that operation's lifetime. That is the
    wrong lifetime: the bytes are the $(I arena's), and the buffer states how
    long they live. Laundering says so, and it is the only place the toolkit
    has to.
    */
    const(char)[] text() @trusted
        => payload.match!(
            (ref const TextRun t) => launder(t.text),
            _ => cast(const(char)[]) null);

    /// The glyph's code point, or `dchar.init`.
    dchar glyph()
        => payload.match!((in Glyph g) => g.glyph, _ => dchar.init);

    /// A line's end point, or `Point.init`.
    Point to()
        => payload.match!((in Line l) => l.to, _ => Point.init);

    /// A line's stroke style.
    LineStyle lineStyle()
        => payload.match!((in Line l) => l.style, _ => LineStyle.solid);

    /// Where a rule or scrollbar sits within its rect.
    RuleEdge ruleEdge()
        => payload.match!(
            (in Rule r) => r.edge,
            (in Scrollbar s) => s.edge,
            _ => RuleEdge.top,
        );

    /// The semantic role the operation was resolved from.
    Slot slot()
        => payload.match!(
            (in FillRect f) => f.slot,
            (in TextRun t) => t.slot,
            (in Glyph g) => g.slot,
            (in Line l) => l.slot,
            (in Rule r) => r.slot,
            (in Scrollbar s) => s.slot,
            _ => Slot.inherit,
        );

    /// The scrollbar's content-unit extents (`STM2`).
    int barContent() => payload.match!((in Scrollbar s) => s.content, _ => 0);
    /// ditto
    int barViewport() => payload.match!((in Scrollbar s) => s.viewport, _ => 0);
    /// ditto
    int barOffset() => payload.match!((in Scrollbar s) => s.offset, _ => 0);
    /// ditto
    ubyte expandPercent()
        => payload.match!((in Scrollbar s) => s.expandPercent, _ => ubyte(0));
    /// ditto
    bool barTrackLit()
        => payload.match!((in Scrollbar s) => s.trackLit, _ => false);
    /// ditto
    RgbColor barTrackColor()
        => payload.match!((in Scrollbar s) => s.trackColor, _ => RgbColor.init);
    /// ditto
    dchar barTrackGlyph()
        => payload.match!((in Scrollbar s) => s.trackGlyph, _ => '\u2502');
    /// ditto
    dchar barThumbGlyph()
        => payload.match!((in Scrollbar s) => s.thumbGlyph, _ => '\u2588');

    /**
    The operation's appearance as a whole `Visual`, for the canvas seam — which
    still speaks `Visual`, so no backend had to learn the payloads.

    $(B Lossy on purpose.) A payload keeps the fields its primitive is painted
    from, so this reports box chrome for a fill and text chrome for a run, and
    the defaults for the combinations no backend reads (a fill has no font; a
    text run has no shadow). Every canvas implementation was read against this
    before the fields were split.
    */
    Visual visual()
        => payload.match!(
            (in FillRect f) => visualOf(f),
            (in TextRun t) => visualOf(t.ink),
            (in Glyph g) => visualOf(g.ink),
            (in Line l) => visualOf(l.ink),
            (in Rule r) => visualOf(r.ink),
            (in Scrollbar s) => visualOf(s),
            _ => Visual.init,
        );
}

// The point of the sum: 656 bytes per operation became this. A frame buffer of
// 4096 operations is a quarter of a megabyte rather than 2.6 MB — which is the
// difference between fitting a thread stack and overflowing one. Guarded,
// because the regression is silent: a field added to the widest payload costs
// every operation in every frame.
static assert(DrawOp.sizeof <= 64,
    "DrawOp grew past its budget — check the widest payload");

// ---------------------------------------------------------------------------
// Visual ⇄ payload: the canvas seam still speaks `Visual`.
// ---------------------------------------------------------------------------

/// The content half of `v`.
Ink inkOf(in Visual v) @safe pure nothrow @nogc
    => Ink(fg: v.fg, fgAlpha: v.fgAlpha, bg: v.bg, bgAlpha: v.bgAlpha,
        hasBg: v.hasBg, underline: v.underline,
        underlineAlpha: v.underlineAlpha, fontRole: v.fontRole,
        styleBits: v.styleBits, fontScale: v.fontScale);

/// The box half of `v`.
BoxChrome boxChromeOf(in Visual v) @safe pure nothrow @nogc
    => BoxChrome(border: v.border, borderRadius: v.borderRadius,
        shadow: v.shadow, arrow: v.arrow, arrowOffset: v.arrowOffset);

/// `ink` back as a `Visual`, for the canvas primitives that take one.
Visual visualOf(in Ink ink) @safe pure nothrow @nogc
{
    Visual v;
    v.fg = ink.fg;
    v.fgAlpha = ink.fgAlpha;
    v.bg = ink.bg;
    v.bgAlpha = ink.bgAlpha;
    v.hasBg = ink.hasBg;
    v.underline = ink.underline;
    v.underlineAlpha = ink.underlineAlpha;
    v.fontRole = ink.fontRole;
    v.styleBits = ink.styleBits;
    v.fontScale = ink.fontScale;
    return v;
}

/// ditto
Visual visualOf(in FillRect f) @safe pure nothrow @nogc
{
    Visual v;
    v.fg = f.fg;
    v.fgAlpha = f.fgAlpha;
    v.bg = f.bg;
    v.bgAlpha = f.bgAlpha;
    v.hasBg = f.hasBg;
    if (f.chrome !is null)
    {
        v.border = f.chrome.border;
        v.borderRadius = f.chrome.borderRadius;
        v.shadow = f.chrome.shadow;
        v.arrow = f.chrome.arrow;
        v.arrowOffset = f.chrome.arrowOffset;
    }
    return v;
}

/// ditto
Visual visualOf(in Scrollbar s) @safe pure nothrow @nogc
{
    Visual v;
    v.fg = s.fg;
    v.fgAlpha = s.fgAlpha;
    return v;
}

/**
The operation's appearance as a whole `Visual`.

$(B Lossy on purpose.) A payload keeps the fields its primitive is painted
from, so this reports box chrome for a fill and text chrome for a run, and
`Visual.init`'s defaults for the combinations no backend reads (a fill has no
font; a text run has no shadow). Every canvas implementation was checked
against this before the fields were split.
*/
Visual visual(in DrawOp op) @safe pure nothrow @nogc
    => op.match!(
        (in FillRect f) => visualOf(f),
        (in TextRun t) => visualOf(t.ink),
        (in Glyph g) => visualOf(g.ink),
        (in Line l) => visualOf(l.ink),
        (in Rule r) => visualOf(r.ink),
        (in Scrollbar s) => visualOf(s),
        _ => Visual.init,
    );

// ---------------------------------------------------------------------------
// Factories for operations whose text needs no arena.
// ---------------------------------------------------------------------------

/// A fill, with `visual`'s box chrome dropped unless `chrome` is supplied by
/// a caller that has somewhere to keep it (a $(MREF sparkles,ui,cmd_buffer)).
DrawOp fillRectOp(in Rect rect, Slot slot = Slot.inherit,
    in Visual visual = Visual.init, const(BoxChrome)* chrome = null)
    @safe pure nothrow @nogc
    => DrawOp(FillRect(rect: rect, chrome: chrome, fg: visual.fg,
        fgAlpha: visual.fgAlpha, bg: visual.bg, bgAlpha: visual.bgAlpha,
        hasBg: visual.hasBg, slot: slot));

/**
A text run over storage the caller vouches for.

`string` — immutable, and in practice a literal or a collector-owned buffer —
is the one text an operation may point at without an arena to intern it into.
Anything shorter-lived goes through
$(REF CmdBuffer.textRun, sparkles,ui,cmd_buffer), which copies.

`rect.width` should be the display-cell advance (use
$(REF cellsOf, sparkles,ui,geometry) or grapheme `visibleWidth`).
*/
DrawOp textRunOp(in Rect rect, string text, Slot slot = Slot.inherit,
    in Visual visual = Visual.init) @safe pure nothrow @nogc
    => DrawOp(TextRun(rect: rect, text: text, ink: inkOf(visual), slot: slot));

/// ditto
DrawOp glyphOp(in Point at, dchar glyph, Slot slot = Slot.inherit,
    in Visual visual = Visual.init) @safe pure nothrow @nogc
    => DrawOp(Glyph(at: at, glyph: glyph, ink: inkOf(visual), slot: slot));

/// ditto
DrawOp lineOp(in Point from, in Point to, LineStyle style = LineStyle.solid,
    Slot slot = Slot.inherit, in Visual visual = Visual.init)
    @safe pure nothrow @nogc
    => DrawOp(Line(from: from, to: to, ink: inkOf(visual), style: style,
        slot: slot));

/// ditto
DrawOp ruleOp(in Rect rect, RuleEdge edge, Slot slot = Slot.inherit,
    in Visual visual = Visual.init) @safe pure nothrow @nogc
    => DrawOp(Rule(rect: rect, ink: inkOf(visual), edge: edge, slot: slot));

/// ditto
DrawOp pushClipOp(in Rect rect) @safe pure nothrow @nogc
    => DrawOp(PushClip(rect));

/// ditto
DrawOp popClipOp() @safe pure nothrow @nogc => DrawOp(PopClip());

/**
The endpoints of a $(LREF RuleEdge) within `rect`, in whole cells — the
fallback every canvas without a sub-cell `rule` primitive paints instead.
A hairline it cannot draw thinner becomes the cell-aligned line along the
same edge: visible in the same place, at the coarsest honest resolution.
*/
void ruleEndpoints(in Rect rect, RuleEdge edge, out Point from, out Point to)
    @safe pure nothrow @nogc
{
    const x1 = rect.x, y1 = rect.y;
    const x2 = rect.x + (rect.width > 0 ? rect.width - 1 : 0);
    const y2 = rect.y + (rect.height > 0 ? rect.height - 1 : 0);
    final switch (edge) with (RuleEdge)
    {
        case top:     from = Point(x1, y1); to = Point(x2, y1); break;
        case bottom:  from = Point(x1, y2); to = Point(x2, y2); break;
        case left:    from = Point(x1, y1); to = Point(x1, y2); break;
        case right:   from = Point(x2, y1); to = Point(x2, y2); break;
        case centerX:
            const cx = rect.x + rect.width / 2;
            from = Point(cx, y1); to = Point(cx, y2);
            break;
        case centerY:
            const cy = rect.y + rect.height / 2;
            from = Point(x1, cy); to = Point(x2, cy);
            break;
    }
}

/// Number of columns/rows a cell backend uses for a semantic scrollbar rail.
/// The continuous px animation degrades to the gallery's shipped threshold:
/// idle through 49% is one cell; 50% through fully expanded is two.
int scrollbarCellCount(ubyte expandPercent) @safe pure nothrow @nogc
    => expandPercent < 50 ? 1 : 2;

/**
Returns whether cell `at` along a `track` belongs to the thumb. This is the
semantic scrollbar's cell degradation over the one `STM2` formula — it does
not re-derive geometry and therefore retains the flush-at-both-ends property.
*/
bool scrollbarCell(int content, int viewport, int offset, int track, int at)
    @safe pure nothrow @nogc
{
    const thumb = scrollbarThumb(content, viewport, offset, track);
    return at >= thumb.start && at < thumb.start + thumb.extent;
}

/**
The canvas capability concept: `true` iff `T` supplies the four primitives plus
`measure`. A conforming canvas has, callable on a mutable instance:

$(LIST
    * `void fillRect(Rect, Visual)`
    * `void textRun(Point, const(char)[], Visual)`
    * `void glyph(Point, dchar, Visual)`
    * `void line(Point, Point, Visual, LineStyle)`
    * `Size measure(const(char)[])` — the run's cell extent
)

Attributes are deliberately $(I not) constrained here — the interpreter infers
them from the concrete type, so a `@system` GPU canvas and a `@safe` recorder
both satisfy the same concept.

A canvas $(B may) additionally implement the optional clipping pair
`void pushClip(Rect)` / `void popClip()` (nested clips intersect), a sub-cell
`rule`, and a semantic `scrollbar`. The painter forwards those by
introspection; a canvas without them gets the cell-aligned degradation.
*/
enum bool isCanvas(T) = __traits(compiles, (ref T c) {
    Rect r;
    Point p;
    Visual v;
    dchar g;
    c.fillRect(r, v);
    c.textRun(p, "x", v);
    c.glyph(p, g, v);
    c.line(p, p, v, LineStyle.solid);
    Size s = c.measure("x");
});

/**
A canvas that records every primitive into a growable `DrawOp[]` instead of
drawing — the test seam and the reference `isCanvas` implementation.

Text is $(B interned on the collected heap), not borrowed: a recorder outlives
the call that drew into it, and the caller's buffer may not. That is the same
guarantee the old owning `char[512]` gave, without the cap or the cost.
*/
struct RecordingCanvas
{
    import sparkles.ui.arena : GcArena;

    /// The captured op stream.
    DrawOp[] ops;

    private GcArena _arena;

@safe nothrow:

    void fillRect(in Rect r, in Visual v)
    {
        const chrome = boxChromeOf(v);
        ops ~= fillRectOp(r, Slot.inherit, v,
            chrome.any ? _arena.store(chrome) : null);
    }

    void textRun(in Point at, scope const(char)[] text, in Visual v)
    {
        ops ~= DrawOp(TextRun(
            rect: Rect(at.x, at.y, cast(int) cellsOf(text), 1),
            text: _arena.intern(text),
            ink: inkOf(v),
        ));
    }

    void glyph(in Point at, dchar g, in Visual v)
    {
        ops ~= glyphOp(at, g, Slot.inherit, v);
    }

    void line(in Point from, in Point to, in Visual v, LineStyle style)
    {
        ops ~= lineOp(from, to, style, Slot.inherit, v);
    }

    // The optional clipping pair — recorded so tests can assert scissor
    // bracketing without a real backend.
    void pushClip(in Rect r)
    {
        ops ~= pushClipOp(r);
    }

    /// ditto
    void popClip()
    {
        ops ~= popClipOp();
    }

    Size measure(scope const(char)[] text) const
        => Size(cast(int) cellsOf(text), 1);
}

// The recorder is the baseline conforming canvas — if this ever fails to
// compile, the concept and the reference implementation have diverged.
static assert(isCanvas!RecordingCanvas);

// A struct missing a primitive is NOT a canvas (guards against the concept
// silently degenerating to `true`).
private struct NotACanvas
{
    void fillRect(in Rect, in Visual) @safe {}
}

static assert(!isCanvas!NotACanvas);

@("ui.canvas.recording.capturesEachPrimitive")
@safe
unittest
{
    RecordingCanvas c;
    const v = Visual(fg: RgbColor(1, 2, 3));
    c.fillRect(Rect(0, 0, 4, 2), v);
    c.textRun(Point(1, 1), "hi", v);
    c.glyph(Point(3, 3), '^', v);
    c.line(Point(0, 5), Point(4, 5), v, LineStyle.wavy);

    assert(c.ops.length == 4);
    assert(c.ops[0].kind == OpKind.fillRect && c.ops[0].rect == Rect(0, 0, 4, 2));
    assert(c.ops[1].kind == OpKind.textRun && c.ops[1].rect == Rect(1, 1, 2, 1));
    assert(c.ops[1].text == "hi", "text is interned, not borrowed");
    assert(c.ops[2].kind == OpKind.glyph && c.ops[2].glyph == '^');
    assert(c.ops[3].kind == OpKind.line
        && c.ops[3].to == Point(4, 5) && c.ops[3].lineStyle == LineStyle.wavy);
    assert(c.ops[1].visual.fg == RgbColor(1, 2, 3), "the ink round-trips");
    assert(c.measure("hello") == Size(5, 1));
}

@("ui.canvas.scrollbarCell.degradesAtTheSharedThreshold")
@safe pure nothrow @nogc
unittest
{
    assert(scrollbarCellCount(0) == 1);
    assert(scrollbarCellCount(49) == 1);
    assert(scrollbarCellCount(50) == 2);
    assert(scrollbarCellCount(100) == 2);

    // 40 content units in a 10-unit viewport over ten cells resolves to a
    // two-cell thumb, flush at both ends through STM2's one formula.
    assert(scrollbarCell(40, 10, 0, 10, 0));
    assert(scrollbarCell(40, 10, 0, 10, 1));
    assert(!scrollbarCell(40, 10, 0, 10, 2));
    assert(scrollbarCell(40, 10, 30, 10, 8));
    assert(scrollbarCell(40, 10, 30, 10, 9));
}

@("ui.canvas.textRunOwnsUtf8")
@safe
unittest
{
    // Multi-byte UTF-8 must survive as a whole run, not as three "glyphs".
    RecordingCanvas c;
    c.textRun(Point(0, 0), "Label…", Visual.init);
    assert(c.ops.length == 1);
    assert(c.ops[0].text == "Label…");
    assert(c.ops[0].text.length == "Label…".length);
}

@("ui.canvas.textRunHasNoLengthCap")
@safe
unittest
{
    // The inline `char[512]` this replaced truncated here — on a byte
    // boundary, mid-codepoint, silently. A paragraph is one run now.
    RecordingCanvas c;
    char[2000] wide = 'w';
    c.textRun(Point(0, 0), wide[], Visual.init);
    assert(c.ops[0].text.length == 2000);
}

@("ui.canvas.recordedTextSurvivesItsSource")
@safe
unittest
{
    // The regression the owning payload was introduced for: a status line
    // formatted into a stack buffer, drawn, and gone before the frame paints.
    RecordingCanvas c;
    {
        char[16] scratch = "transient      ";
        c.textRun(Point(0, 0), scratch[0 .. 9], Visual.init);
        scratch[] = '?';
    }
    assert(c.ops[0].text == "transient");
}

@("ui.canvas.accessorsAgreeWithTheMatch")
@safe pure nothrow @nogc
unittest
{
    // The accessors exist so a call site can ask one question; they must not
    // become a second, drifting description of the sum.
    const DrawOp[7] ops = [
        fillRectOp(Rect(1, 2, 3, 4)),
        textRunOp(Rect(0, 0, 2, 1), "hi"),
        glyphOp(Point(5, 6), 'x'),
        lineOp(Point(0, 0), Point(9, 0), LineStyle.wavy),
        ruleOp(Rect(0, 0, 4, 1), RuleEdge.bottom),
        pushClipOp(Rect(2, 2, 2, 2)),
        popClipOp(),
    ];
    assert(ops[0].kind == OpKind.fillRect && ops[0].rect == Rect(1, 2, 3, 4));
    assert(ops[1].kind == OpKind.textRun && ops[1].text == "hi");
    assert(ops[2].kind == OpKind.glyph && ops[2].glyph == 'x');
    assert(ops[2].rect == Rect(5, 6, 1, 1), "a glyph reports where it lands");
    assert(ops[3].kind == OpKind.line && ops[3].to == Point(9, 0)
        && ops[3].lineStyle == LineStyle.wavy);
    assert(ops[4].kind == OpKind.rule && ops[4].ruleEdge == RuleEdge.bottom);
    assert(ops[5].kind == OpKind.pushClip && ops[5].rect == Rect(2, 2, 2, 2));
    assert(ops[6].kind == OpKind.popClip && ops[6].rect == Rect.init);

    // A question the arm cannot answer reports the neutral value rather than
    // reading another arm's bytes.
    assert(ops[0].text.length == 0 && ops[0].glyph == dchar.init);
}
