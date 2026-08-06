/**
The drawing seam for $(MREF sparkles,ui): the primitive vocabulary every backend
implements, expressed as a $(B Design-by-Introspection capability concept)
($(LREF isCanvas)) rather than an interface — so the interpreter's `@safe`/`@nogc`
attributes are $(I inferred) from the concrete canvas ($(LREF RecordingCanvas) is
`@safe @nogc`; a raylib canvas is `@system`), and no vtable/GC indirection sits in
the paint hot path.

A canvas draws four primitives — $(LREF DrawOp) is their reified, backend-neutral
form, the boundary between the pure model (`buildDisplayList`) and the impure
painter (`interp/immediate.paint`). Input is $(B not) defined here: the state
machines in $(MREF sparkles,ui,state) consume the shared `sparkles:input`
vocabulary, which backends produce.
*/
module sparkles.ui.canvas;

import sparkles.ui.geometry : Point, Rect, Size, cellsOf;
import sparkles.ui.style : Slot, Visual;

/// How a $(LREF DrawOp)'s `line` is stroked.
enum LineStyle : ubyte
{
    solid, /// a straight rule (connectors, borders)
    wavy,  /// a wavy underline (the twoslash error squiggle)
}

/// The drawing primitives, reified so the pure model can hand a painter a
/// flat `DrawOp[]` with no backend in sight.
/**
Where a hairline sits within a cell band (`UIA2`).

The toolkit's geometry is whole cells, but real chrome is thinner than a
cell: a 1 px pane divider, the hairline under a header, a separator above
a toolbar. Naming the $(B edge) instead of a pixel count keeps that
expressible without giving the toolkit device units — the backend decides
what "a hairline along this edge" is in its own terms, which is the same
bargain `LineStyle` already makes.
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

enum OpKind : ubyte
{
    fillRect, /// fill `rect` with `visual.bg`
    textRun,  /// draw `text` at `rect.origin` (`rect.width` = advance in cells)
    glyph,    /// draw a single `glyph` at `rect.origin`
    line,     /// stroke `rect.origin` → `to` in `lineStyle`
    rule,     /// a hairline along `ruleEdge` of `rect`, in `visual.fg`
    pushClip, /// clip subsequent ops to `rect` (nested clips intersect)
    popClip,  /// undo the matching `pushClip`
}

/**
A single reified drawing command in abstract cell space. `buildDisplayList`
($(MREF sparkles,ui,display_list)) emits a `DrawOp[]`; a painter walks it once.
Carries both the semantic `slot` (for backends that re-resolve, e.g. HTML class
names) and the already-resolved `visual` (for pixel backends).
*/
struct DrawOp
{
    OpKind kind;
    Rect rect;          /// fill area; text/glyph anchor (`rect.width` = cell advance)
    Point to;           /// `line` end point (`rect.origin` is the start)
    const(char)[] text; /// `textRun` payload (borrowed; must outlive the op)
    dchar glyph;        /// `glyph` payload
    LineStyle lineStyle;
    RuleEdge ruleEdge;  /// `rule` placement
    Slot slot;          /// the semantic role this op was resolved from
    Visual visual;      /// resolved appearance
}

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
them from the concrete type, so a `@system` GPU canvas and a `@safe @nogc`
recorder both satisfy the same concept.

A canvas $(B may) additionally implement the optional clipping pair
`void pushClip(Rect)` / `void popClip()` (nested clips intersect). The painter
forwards the display list's scissor ops to it by introspection; a canvas
without the pair paints unclipped, relying on the display list's subtree
culling for fully-hidden content.
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
drawing — the test seam and the reference `isCanvas` implementation. `@safe`, so
instantiating the interpreter against it proves the pure model path stays
GL-free. (It uses a GC array rather than a `SmallBuffer`, since a `DrawOp` holds
a slice and `SmallBuffer`'s `void`-initialized inline storage is unsafe for
pointer-bearing elements — the same reason `gui_preview.d` keeps a GC
`PreviewLine[]`.)
*/
struct RecordingCanvas
{
    /// The captured op stream.
    DrawOp[] ops;

@safe nothrow:

    void fillRect(in Rect r, in Visual v)
    {
        ops ~= DrawOp(kind: OpKind.fillRect, rect: r, visual: v);
    }

    void textRun(in Point at, const(char)[] text, in Visual v)
    {
        ops ~= DrawOp(
            kind: OpKind.textRun,
            rect: Rect(at.x, at.y, cast(int) cellsOf(text), 1),
            text: text,
            visual: v,
        );
    }

    void glyph(in Point at, dchar g, in Visual v)
    {
        ops ~= DrawOp(
            kind: OpKind.glyph,
            rect: Rect(at.x, at.y, 1, 1),
            glyph: g,
            visual: v,
        );
    }

    void line(in Point from, in Point to, in Visual v, LineStyle style)
    {
        ops ~= DrawOp(
            kind: OpKind.line,
            rect: Rect(from.x, from.y, 0, 0),
            to: to,
            lineStyle: style,
            visual: v,
        );
    }

    // The optional clipping pair — recorded so tests can assert scissor
    // bracketing without a real backend.
    void pushClip(in Rect r)
    {
        ops ~= DrawOp(kind: OpKind.pushClip, rect: r);
    }

    /// ditto
    void popClip()
    {
        ops ~= DrawOp(kind: OpKind.popClip);
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
    import sparkles.ui.style : Visual;
    import sparkles.base.term_color : RgbColor;

    RecordingCanvas c;
    const v = Visual(fg: RgbColor(1, 2, 3));
    c.fillRect(Rect(0, 0, 4, 2), v);
    c.textRun(Point(1, 1), "hi", v);
    c.glyph(Point(3, 3), '^', v);
    c.line(Point(0, 5), Point(4, 5), v, LineStyle.wavy);

    assert(c.ops.length == 4);
    assert(c.ops[0].kind == OpKind.fillRect && c.ops[0].rect == Rect(0, 0, 4, 2));
    assert(c.ops[1].kind == OpKind.textRun && c.ops[1].rect == Rect(1, 1, 2, 1));
    assert(c.ops[2].kind == OpKind.glyph && c.ops[2].glyph == '^');
    assert(c.ops[3].kind == OpKind.line
        && c.ops[3].to == Point(4, 5) && c.ops[3].lineStyle == LineStyle.wavy);
    assert(c.measure("hello") == Size(5, 1));
}
