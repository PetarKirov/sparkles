/**
The command buffer: a frame's $(REF DrawOp, sparkles,ui,canvas) stream $(I plus)
the storage those operations point into.

An operation is 64 bytes because its two bulky parts — the text of a run, the
chrome of a decorated box — live somewhere else. This is that somewhere, paired
with the operations so the two cannot be separated by accident:

$(B An operation is valid while the buffer that built it is alive and unreset.)

That is the ownership policy [`UI-O4`](../../../../docs/specs/ui/open-issues.md#ui-o4)
asks for, and stating it as a type is the point. A retained consumer keeps the
$(I buffer), not a slice of one; a frame loop calls $(LREF CmdBufferT.reset)
and reuses both halves, allocating nothing in the steady state.

$(B Two arenas, one emitter.) The buffer is generic over
$(REF isArena, sparkles,ui,arena), so the same emitting code serves both paths:

$(UL
    $(LI $(LREF CmdBuffer) — `FrameArena`-backed. `@nogc`, reset per frame.)
    $(LI $(LREF GcCmdBuffer) — collector-backed. Its operations outlive it, so
    $(REF buildDisplayList, sparkles,ui,display_list) can keep handing back a
    plain `DrawOp[]` that needs no lifetime rule at all.)
)
*/
module sparkles.ui.cmd_buffer;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : RgbColor;

import sparkles.ui.arena : FrameArena, GcArena, isArena;
import sparkles.ui.canvas : boxChromeOf, DrawOp, FillRect, Glyph, inkOf, Line,
    LineStyle, PopClip, PushClip, Rule, RuleEdge, Scrollbar, TextRun;
import sparkles.ui.geometry : cellsOf, Point, Rect, Size;
import sparkles.ui.style : Slot, Visual;

/// Operations held inline before the buffer reaches for the heap. A frame
/// typically emits thousands, so this is a warm-start size, not a ceiling —
/// keeping it small is what lets a buffer sit inside another value without
/// the stack cost that a 4096-operation inline array used to impose.
enum size_t defaultInlineOps = 64;

/**
A frame's operations and their storage.

Move-only: the operations alias this buffer's arena, so a copy would hand out a
second set of live pointers into one set of bytes — the same reason
$(REF FrameArena, sparkles,ui,arena) is move-only.
*/
struct CmdBufferT(Arena, size_t inlineOps = defaultInlineOps)
if (isArena!Arena)
{
    private
    {
        SmallBuffer!(DrawOp, inlineOps) _ops;
        Arena _arena;
    }

    @disable this(ref const CmdBufferT);

    /// The operations emitted so far, in order.
    DrawOp[] ops() return scope @safe pure nothrow @nogc => _ops[];

    /// ditto
    const(DrawOp)[] ops() const return scope @safe pure nothrow @nogc => _ops[];

    /// ditto — `buf[]`, so a buffer reads like the `SmallBuffer` it replaced
    /// at the call sites that only want the operations.
    DrawOp[] opSlice() return scope @safe pure nothrow @nogc => _ops[];

    /// ditto
    const(DrawOp)[] opSlice() const return scope @safe pure nothrow @nogc
        => _ops[];

    /// How many operations the frame has emitted.
    size_t length() const @safe pure nothrow @nogc => _ops.length;

    /// Drops every operation and every byte they pointed at, keeping the
    /// capacity both halves have already paid for.
    void reset()
    {
        _ops.length = 0;
        _arena.reset();
    }

    /**
    Appends an operation built elsewhere.

    The escape hatch for an operation whose payload needs no interning — one
    over `string` text, or a clip. An operation that points at anything
    shorter-lived than this buffer must be built by the methods below instead.
    */
    // By value, not `in`: `-preview=in` would make the parameter `scope`,
    // and storing a scope operation in the buffer is precisely what this
    // does. The lifetime it must respect is the arena's, which the operation
    // points at — not this parameter's.
    void put(DrawOp op)
    {
        _ops ~= op;
    }

    /// ditto
    void opOpAssign(string op : "~")(DrawOp value)
    {
        put(value);
    }

    // ── the primitives ───────────────────────────────────────────────────

    /**
    A fill, with `visual`'s box chrome kept in the arena — and only when there
    is any, which is the point: a plain background fill spends no arena at all.
    */
    void fillRect(in Rect rect, Slot slot = Slot.inherit,
        in Visual visual = Visual.init)
    {
        const chrome = boxChromeOf(visual);
        _ops ~= DrawOp(FillRect(
            rect: rect,
            chrome: chrome.any ? _arena.store(chrome) : null,
            fg: visual.fg, fgAlpha: visual.fgAlpha,
            bg: visual.bg, bgAlpha: visual.bgAlpha, hasBg: visual.hasBg,
            slot: slot,
        ));
    }

    /**
    A text run whose bytes are copied into the arena.

    The copy is what makes a `scope` source safe — a status line formatted into
    a stack buffer, a temporary formatter — and it has no length cap, so a
    paragraph is one operation rather than a truncated one.

    `rect.width` should be the display-cell advance (use
    $(REF cellsOf, sparkles,ui,geometry) or grapheme `visibleWidth`).
    */
    void textRun(in Rect rect, scope const(char)[] text,
        Slot slot = Slot.inherit, in Visual visual = Visual.init)
    {
        _ops ~= DrawOp(TextRun(
            rect: rect,
            text: _arena.intern(text),
            ink: inkOf(visual),
            slot: slot,
        ));
    }

    /// ditto — the canvas-shaped spelling, measuring its own advance.
    void textRun(in Point at, scope const(char)[] text,
        in Visual visual = Visual.init)
    {
        textRun(Rect(at.x, at.y, cast(int) cellsOf(text), 1), text,
            Slot.inherit, visual);
    }

    /// ditto
    void glyph(in Point at, dchar g, Slot slot = Slot.inherit,
        in Visual visual = Visual.init)
    {
        _ops ~= DrawOp(Glyph(at: at, glyph: g, ink: inkOf(visual), slot: slot));
    }

    /// ditto
    void line(in Point from, in Point to, LineStyle style = LineStyle.solid,
        Slot slot = Slot.inherit, in Visual visual = Visual.init)
    {
        _ops ~= DrawOp(Line(from: from, to: to, ink: inkOf(visual),
            style: style, slot: slot));
    }

    /// ditto
    void rule(in Rect rect, RuleEdge edge, Slot slot = Slot.inherit,
        in Visual visual = Visual.init)
    {
        _ops ~= DrawOp(Rule(rect: rect, ink: inkOf(visual), edge: edge,
            slot: slot));
    }

    /// ditto — extents in content units, so a backend resolves the thumb at
    /// its own resolution (`STM2`).
    void scrollbar(in Rect rect, RuleEdge edge, int content, int viewport,
        int offset, Slot slot = Slot.inherit, in Visual thumb = Visual.init,
        RgbColor trackColor = RgbColor.init, bool trackLit = false,
        ubyte expandPercent = 0, dchar trackGlyph = '│',
        dchar thumbGlyph = '█', ubyte trackAlpha = 0xFF)
    {
        _ops ~= DrawOp(Scrollbar(
            rect: rect, content: content, viewport: viewport, offset: offset,
            fg: thumb.fg, fgAlpha: thumb.fgAlpha,
            trackColor: trackColor, trackAlpha: trackAlpha, trackLit: trackLit,
            expandPercent: expandPercent, edge: edge, slot: slot,
            trackGlyph: trackGlyph, thumbGlyph: thumbGlyph,
        ));
    }

    /// ditto
    void pushClip(in Rect rect)
    {
        _ops ~= DrawOp(PushClip(rect));
    }

    /// ditto
    void popClip()
    {
        _ops ~= DrawOp(PopClip());
    }

    /// The cell extent of `text` — the `isCanvas` primitive, so a buffer can
    /// stand in for a canvas that records.
    Size measure(scope const(char)[] text) const @safe pure nothrow @nogc
        => Size(cast(int) cellsOf(text), 1);
}

/// The frame loop's buffer: malloc-backed, `@nogc`, reset every frame.
alias CmdBuffer = CmdBufferT!(FrameArena!());

/// The convenience buffer: its operations outlive it, because the collector
/// owns what they point at.
alias GcCmdBuffer = CmdBufferT!GcArena;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("ui.cmd_buffer.internsWhatTheCallerWillNotKeep")
@safe pure nothrow @nogc
unittest
{
    // The failure this removes: an operation borrowing a caller's buffer and
    // being painted after it died. The copy happens before the source can go.
    CmdBuffer buf;
    {
        char[32] scratch = "sel 3  z120%                    ";
        buf.textRun(Rect(0, 0, 12, 1), scratch[0 .. 12]);
        scratch[] = '?';
    }
    assert(buf.length == 1);
    assert(buf.ops[0].text == "sel 3  z120%");
}

@("ui.cmd_buffer.aLongRunIsOneOperation")
@safe pure nothrow @nogc
unittest
{
    // The 512-byte inline payload truncated here, on a byte boundary.
    CmdBuffer buf;
    char[1500] para = 'p';
    buf.textRun(Rect(0, 0, 1500, 1), para[]);
    assert(buf.ops[0].text.length == 1500);
}

@("ui.cmd_buffer.chromeCostsOnlyDecoratedBoxes")
@safe pure nothrow @nogc
unittest
{
    import sparkles.ui.geometry : Insets;
    import sparkles.ui.style : BorderStyle, BoxBorder;

    CmdBuffer buf;
    Visual plain;
    plain.hasBg = true;
    plain.bg = RgbColor(10, 20, 30);
    buf.fillRect(Rect(0, 0, 4, 2), Slot.surface, plain);

    Visual boxed = plain;
    boxed.border = BoxBorder(width: Insets.all(1), style: BorderStyle.solid,
        color: RgbColor(1, 2, 3));
    buf.fillRect(Rect(0, 0, 4, 2), Slot.surface, boxed);

    // The common fill carries no chrome at all; the decorated one keeps its
    // border, and reading it back through `visual` is lossless.
    assert(buf.ops[0].visual.bg == RgbColor(10, 20, 30));
    assert(!buf.ops[0].visual.border.any, "a plain fill spends no arena");
    assert(buf.ops[1].visual.border.any);
    assert(buf.ops[1].visual.border.color == RgbColor(1, 2, 3));
}

@("ui.cmd_buffer.resetKeepsCapacityAndForgetsBytes")
@safe pure nothrow @nogc
unittest
{
    CmdBuffer buf;
    foreach (i; 0 .. 200)
        buf.textRun(Rect(0, i, 5, 1), "row!");
    assert(buf.length == 200);

    buf.reset();
    assert(buf.length == 0);
    // The steady-state frame: refilling allocates nothing, and the text is
    // the new frame's, not the old one's.
    foreach (i; 0 .. 200)
        buf.textRun(Rect(0, i, 5, 1), "next");
    assert(buf.ops[0].text == "next");
}

@("ui.cmd_buffer.textStaysValidAsTheFrameGrows")
@safe pure nothrow @nogc
unittest
{
    // Both halves grow during a frame — the operation array reallocates and
    // the arena adds chunks. Neither may disturb what an earlier operation
    // points at.
    CmdBuffer buf;
    buf.textRun(Rect(0, 0, 5, 1), "first");
    foreach (i; 0 .. 2000)
        buf.textRun(Rect(0, i, 20, 1), "0123456789012345678");
    assert(buf.ops[0].text == "first");
    assert(buf.ops[$ - 1].text == "0123456789012345678");
}

@("ui.cmd_buffer.gcBufferOperationsOutliveIt")
@safe
unittest
{
    // What lets `buildDisplayList` keep returning a plain `DrawOp[]`.
    DrawOp[] kept;
    {
        GcCmdBuffer buf;
        char[8] scratch = "wobbly!!";
        buf.textRun(Rect(0, 0, 8, 1), scratch[]);
        kept = buf.ops.dup;
    }
    assert(kept[0].text == "wobbly!!");
}
