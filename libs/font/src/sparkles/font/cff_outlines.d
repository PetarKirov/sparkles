/**
`CFF` and `CFF2` outlines (`docs/specs/font/SPEC.md` § 10, FTO1–FTO4,
FTB3, FTB5): the INDEX, DICT, FDSelect and Private DICT structures a
charstring needs, and the Type 2 charstring interpreter behind
`sparkles.font.outlines`' `glyphOutline` and `drawGlyph`.

Charstrings run with subroutine depth 10 and at most 65,536 operations per
glyph (FTB3); a subroutine on the active call chain is a `cycle` (FTB5).
`CFF2` blends weigh their deltas by the `vstore` item variation store's
region scalars at the instance, and a `seac`-style `endchar` draws the
StandardEncoding base and accent glyphs. Nothing here allocates.
*/
module sparkles.font.cff_outlines;

import sparkles.font.bytes : be16, be32, bes16, bes32, fits;
import sparkles.font.errors : FontError, FontErrorKind, FontLimit, FontResult, fontErr, fontLimitValue, fontOk,
    limitError, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.glyph_names : cffGlyphOfSid;
import sparkles.font.instance : Instance;
import sparkles.font.outlines : GlyphOutline, OutlinePoint, OutlineSegment, SegmentKind, SegmentWriter, SinkWriter,
    writerPtr;
import sparkles.font.std_names : standardEncoding;
import sparkles.font.tables : locate;
import sparkles.font.variations : allZero, ItemVariationStore, NormalizedCoords;

import core.checkedint : adds, muls, negs, subs;

// ---------------------------------------------------------------------------
// Writer-generic templates, declared before the attribute label so their
// attributes infer from the writer: a sink may allocate, throw or be impure.
// ---------------------------------------------------------------------------

private struct CharState(W)
{
    W* writer;
    long x, y;
    long startX, startY;
    bool open;
    bool ended; // `endchar` ran: every caller returns
    bool hasSeac;
    Seac seac;
    size_t contours; // subpaths drawn
    size_t stems;
    ulong ops;
    // The operand stack, shared with every subroutine call (Type 2
    // subroutines consume and leave operands for their caller).
    size_t sp;
    long[cff2MaxStack] stack;
    // CFF2: the item variation data `blend` weighs, and its region scalars
    // at the instance, computed at the first `blend`.
    ushort vsIndex;
    bool seenVsIndex, scalarsReady;
    size_t scalarCount;
    int[cff2MaxStack - 1] scalars;
    // The active subroutine chain, `(global << 63) | biased index` per depth.
    ulong[cffMaxDepth + 1] calls;
    long[cffTransientCount] transientStore;
}

/**
Starts a subpath at `(nx, ny)`, closing the open one. The move is emitted
with the subpath's first line or curve, so a subpath that draws nothing
emits nothing, as `hb_font_draw_glyph` omits it.
*/
private void csMoveTo(W)(ref CharState!W s, long nx, long ny)
{
    csClose(s);
    s.x = s.startX = nx;
    s.y = s.startY = ny;
}

/// Emits the pending move before a subpath's first line or curve.
private void csDraw(W)(ref CharState!W s)
{
    if (!s.open)
    {
        s.writer.put(OutlineSegment(SegmentKind.moveTo, OutlinePoint(s.startX, s.startY)));
        s.open = true;
        ++s.contours;
    }
}

private void csLineTo(W)(ref CharState!W s, long nx, long ny)
{
    csDraw(s);
    s.writer.put(OutlineSegment(SegmentKind.lineTo, OutlinePoint(nx, ny)));
    s.x = nx;
    s.y = ny;
}

private void csCubicTo(W)(ref CharState!W s, long c1x, long c1y, long c2x, long c2y,
    long nx, long ny)
{
    csDraw(s);
    s.writer.put(OutlineSegment(SegmentKind.cubicTo, OutlinePoint(nx, ny),
        OutlinePoint(c1x, c1y), OutlinePoint(c2x, c2y)));
    s.x = nx;
    s.y = ny;
}

/**
Closes the open subpath with a line back to its start, then `close`. The
line is emitted even at zero length, so which segments appear never depends
on coordinates (FTO4). The current point stays where the subpath ended.
*/
private void csClose(W)(ref CharState!W s)
{
    if (s.open)
    {
        s.writer.put(OutlineSegment(SegmentKind.lineTo, OutlinePoint(s.startX, s.startY)));
        s.writer.put(OutlineSegment(SegmentKind.close));
        s.open = false;
    }
}

/// Computes the region scalars of item variation data `s.vsIndex` at the instance, once per glyph.
private FontResult!bool ensureScalars(W)(ref CharState!W s, scope ref CffContext ctx, size_t at)
{
    if (s.scalarsReady)
        return fontOk(true);
    if (!ctx.ivs.present)
        return fontErr!bool(tableError(FontErrorKind.badValue, ctx.tag, ctx.start, at));
    const k = ctx.ivs.regionIndexCount(s.vsIndex);
    if (k.hasError)
        return fontErr!bool(k.error);
    if (k.value > s.scalars.length) // its blend could not fit the stack
        return fontErr!bool(tableError(FontErrorKind.badValue, ctx.tag, ctx.start, at));
    if (allZero(ctx.coords))
        s.scalars[0 .. k.value] = 0;
    else
    {
        const written = ctx.ivs.dataScalars(s.vsIndex, ctx.coords, s.scalars[]);
        if (written.hasError)
            return fontErr!bool(written.error);
    }
    s.scalarCount = k.value;
    s.scalarsReady = true;
    return fontOk(true);
}

private FontResult!bool runCharstring(W)(scope const(ubyte)[] cs, ref CharState!W s,
    scope ref CffContext ctx, uint depth)
{
    ref long[cff2MaxStack] stack = s.stack;
    ref size_t sp = s.sp;
    const maxStack = ctx.is2 ? cff2MaxStack : cff1MaxStack;
    size_t i;
    FontResult!bool fail(FontErrorKind kind, size_t at)
        => fontErr!bool(tableError(kind, ctx.tag, ctx.start, at));

    while (i < cs.length)
    {
        if (++s.ops > fontLimitValue[FontLimit.cffOperations])
            return fontErr!bool(limitError(FontLimit.cffOperations, ctx.tag, ctx.start));
        const b = cs[i];
        if (b >= 32 || b == 28 || b == 255)
        {
            const decoded = decodeCharNumber(cs, i, ctx);
            if (decoded.hasError)
                return fontErr!bool(decoded.error);
            if (sp >= maxStack)
                return fail(FontErrorKind.badValue, i);
            stack[sp++] = decoded.value.value;
            i += decoded.value.consumed;
            continue;
        }
        const opAt = i++;
        switch (b)
        {
            case 1, 3, 18, 23: // hstem, vstem, hstemhm, vstemhm
                s.stems += sp / 2;
                sp = 0;
                break;
            case 19, 20: // hintmask, cntrmask: operands left are implicit vstems
                s.stems += sp / 2;
                sp = 0;
                i += (s.stems + 7) / 8;
                if (i > cs.length)
                    return fail(FontErrorKind.truncated, opAt);
                break;
            case 4: // vmoveto
                if (sp < 1)
                    return fail(FontErrorKind.badValue, opAt);
                csMoveTo(s, s.x, s.y + stack[sp - 1]);
                sp = 0;
                break;
            case 21: // rmoveto
                if (sp < 2)
                    return fail(FontErrorKind.badValue, opAt);
                csMoveTo(s, s.x + stack[sp - 2], s.y + stack[sp - 1]);
                sp = 0;
                break;
            case 22: // hmoveto
                if (sp < 1)
                    return fail(FontErrorKind.badValue, opAt);
                csMoveTo(s, s.x + stack[sp - 1], s.y);
                sp = 0;
                break;
            case 15: // vsindex (CFF2): pops the item variation data index
                if (!ctx.is2)
                    goto default;
                if (sp < 1 || s.seenVsIndex || s.scalarsReady)
                    return fail(FontErrorKind.badValue, opAt);
                {
                    const vs = stack[--sp] >> 16;
                    if (vs < 0 || vs > ushort.max)
                        return fail(FontErrorKind.badValue, opAt);
                    s.vsIndex = cast(ushort) vs;
                    s.seenVsIndex = true;
                }
                break;
            case 16: // blend (CFF2): n defaults, n·k deltas, n
            {
                if (!ctx.is2)
                    goto default;
                if (sp < 1)
                    return fail(FontErrorKind.badValue, opAt);
                const scalars = ensureScalars(s, ctx, opAt);
                if (scalars.hasError)
                    return scalars;
                const n = stack[--sp] >> 16;
                const k = s.scalarCount;
                if (n < 0 || n > sp || n * (k + 1) > sp)
                    return fail(FontErrorKind.badValue, opAt);
                const count = cast(size_t) n;
                const base = sp - count * (k + 1);
                foreach (v; 0 .. count)
                {
                    long sum;
                    bool overflow;
                    foreach (r; 0 .. k)
                        sum = adds(sum, muls(stack[base + count + v * k + r], long(s.scalars[r]), overflow),
                            overflow);
                    // F16.16 scalars: round the weighted sum back to counts.
                    const delta = sum >= 0 ? (sum + 32_768) >> 16 : -((-sum + 32_768) >> 16);
                    stack[base + v] = adds(stack[base + v], delta, overflow);
                    if (overflow)
                        return fail(FontErrorKind.badValue, opAt);
                }
                sp = base + count;
                break;
            }
            case 5: // rlineto
                if (sp % 2 || sp == 0)
                    return fail(FontErrorKind.badValue, opAt);
                for (size_t k = 0; k < sp; k += 2)
                    csLineTo(s, s.x + stack[k], s.y + stack[k + 1]);
                sp = 0;
                break;
            case 6, 7: // hlineto / vlineto
            {
                if (sp == 0)
                    return fail(FontErrorKind.badValue, opAt);
                bool horizontal = b == 6;
                foreach (k; 0 .. sp)
                {
                    if (horizontal)
                        csLineTo(s, s.x + stack[k], s.y);
                    else
                        csLineTo(s, s.x, s.y + stack[k]);
                    horizontal = !horizontal;
                }
                sp = 0;
                break;
            }
            case 8: // rrcurveto
                if (sp % 6 || sp == 0)
                    return fail(FontErrorKind.badValue, opAt);
                for (size_t k = 0; k < sp; k += 6)
                {
                    const c1x = s.x + stack[k], c1y = s.y + stack[k + 1];
                    const c2x = c1x + stack[k + 2], c2y = c1y + stack[k + 3];
                    csCubicTo(s, c1x, c1y, c2x, c2y, c2x + stack[k + 4], c2y + stack[k + 5]);
                }
                sp = 0;
                break;
            case 10, 29: // callsubr / callgsubr
            {
                const global = b == 29;
                if (sp < 1)
                    return fail(FontErrorKind.badValue, opAt);
                const index = stack[--sp] >> 16;
                if (!global && !ctx.hasLocalSubrs)
                    return fail(FontErrorKind.badValue, opAt);
                const subrs = global ? ctx.globalSubrs : ctx.localSubrs;
                const biased = index + subrBias(subrs.count);
                if (biased < 0)
                    return fail(FontErrorKind.badValue, opAt);
                const key = (ulong(global) << 63) | cast(ulong) biased;
                foreach (caller; s.calls[1 .. depth + 1])
                    if (caller == key)
                        return fail(FontErrorKind.cycle, opAt);
                if (depth + 1 > cffMaxDepth)
                    return fontErr!bool(limitError(FontLimit.cffSubroutineDepth, ctx.tag, ctx.start));
                const subr = subrs.object(cast(size_t) biased);
                if (subr.hasError)
                    return fontErr!bool(subr.error);
                s.calls[depth + 1] = key;
                const called = runCharstring(subr.value, s, ctx, depth + 1);
                if (called.hasError || s.ended)
                    return called;
                break;
            }
            case 11: // return
                return fontOk(true);
            case 14: // endchar; with four operands more, a seac
                if (!ctx.is2 && sp >= 4)
                {
                    s.hasSeac = true;
                    s.seac = Seac(stack[sp - 4], stack[sp - 3], stack[sp - 2] >> 16, stack[sp - 1] >> 16);
                }
                csClose(s);
                sp = 0;
                s.ended = true;
                return fontOk(true);
            case 24: // rcurveline
            {
                if (sp < 8 || (sp - 2) % 6)
                    return fail(FontErrorKind.badValue, opAt);
                size_t k;
                for (; k + 6 <= sp - 2; k += 6)
                {
                    const c1x = s.x + stack[k], c1y = s.y + stack[k + 1];
                    const c2x = c1x + stack[k + 2], c2y = c1y + stack[k + 3];
                    csCubicTo(s, c1x, c1y, c2x, c2y, c2x + stack[k + 4], c2y + stack[k + 5]);
                }
                csLineTo(s, s.x + stack[k], s.y + stack[k + 1]);
                sp = 0;
                break;
            }
            case 25: // rlinecurve
            {
                if (sp < 8 || (sp - 6) % 2)
                    return fail(FontErrorKind.badValue, opAt);
                size_t k;
                for (; k + 2 <= sp - 6; k += 2)
                    csLineTo(s, s.x + stack[k], s.y + stack[k + 1]);
                const c1x = s.x + stack[k], c1y = s.y + stack[k + 1];
                const c2x = c1x + stack[k + 2], c2y = c1y + stack[k + 3];
                csCubicTo(s, c1x, c1y, c2x, c2y, c2x + stack[k + 4], c2y + stack[k + 5]);
                sp = 0;
                break;
            }
            case 26: // vvcurveto
            {
                size_t k;
                long dx;
                if (sp % 4 == 1)
                {
                    dx = stack[0];
                    k = 1;
                }
                if (sp - k < 4 || (sp - k) % 4)
                    return fail(FontErrorKind.badValue, opAt);
                for (; k < sp; k += 4)
                {
                    const c1x = s.x + dx, c1y = s.y + stack[k];
                    const c2x = c1x + stack[k + 1], c2y = c1y + stack[k + 2];
                    csCubicTo(s, c1x, c1y, c2x, c2y, c2x, c2y + stack[k + 3]);
                    dx = 0;
                }
                sp = 0;
                break;
            }
            case 27: // hhcurveto
            {
                size_t k;
                long dy;
                if (sp % 4 == 1)
                {
                    dy = stack[0];
                    k = 1;
                }
                if (sp - k < 4 || (sp - k) % 4)
                    return fail(FontErrorKind.badValue, opAt);
                for (; k < sp; k += 4)
                {
                    const c1x = s.x + stack[k], c1y = s.y + dy;
                    const c2x = c1x + stack[k + 1], c2y = c1y + stack[k + 2];
                    csCubicTo(s, c1x, c1y, c2x, c2y, c2x + stack[k + 3], c2y);
                    dy = 0;
                }
                sp = 0;
                break;
            }
            case 30, 31: // vhcurveto / hvcurveto
            {
                // Alternating v- and h-curveto groups of four operands;
                // a single leftover operand is the last curve's final
                // delta on the axis its end moves along.
                bool vertical = b == 30;
                if (sp < 4 || sp % 4 > 1)
                    return fail(FontErrorKind.badValue, opAt);
                for (size_t k = 0; k + 4 <= sp; k += 4)
                {
                    const extra = sp - (k + 4) == 1 ? stack[sp - 1] : 0;
                    const a0 = stack[k], a1 = stack[k + 1], a2 = stack[k + 2], a3 = stack[k + 3];
                    if (vertical)
                        csCubicTo(s, s.x, s.y + a0, s.x + a1, s.y + a0 + a2,
                            s.x + a1 + a3, s.y + a0 + a2 + extra);
                    else
                        csCubicTo(s, s.x + a0, s.y, s.x + a0 + a1, s.y + a2,
                            s.x + a0 + a1 + extra, s.y + a2 + a3);
                    vertical = !vertical;
                }
                sp = 0;
                break;
            }
            case 12: // escaped operators
            {
                if (i >= cs.length)
                    return fail(FontErrorKind.truncated, opAt);
                const handled = runEscaped(s, cs[i++], ctx, opAt);
                if (handled.hasError)
                    return handled;
                break;
            }
            default:
                return fail(FontErrorKind.unsupportedVersion, opAt);
        }
    }
    return fontOk(true);
}

/// The flex family and the arithmetic, storage and conditional operators (escape `12 esc`).
private FontResult!bool runEscaped(W)(ref CharState!W s, ubyte esc, scope ref CffContext ctx, size_t at)
{
    ref long[cff2MaxStack] stack = s.stack;
    ref size_t sp = s.sp;
    FontResult!bool fail(FontErrorKind kind)
        => fontErr!bool(tableError(kind, ctx.tag, ctx.start, at));
    switch (esc)
    {
        case 0: // dotsection
            sp = 0;
            return fontOk(true);
        case 34: // hflex: dx1 dx2 dy2 dx3 dx4 dx5 dx6
        {
            if (sp != 7)
                return fail(FontErrorKind.badValue);
            const y = s.y;
            const c1x = s.x + stack[0];
            const c2x = c1x + stack[1], c2y = y + stack[2];
            const e1x = c2x + stack[3];
            csCubicTo(s, c1x, y, c2x, c2y, e1x, c2y);
            const c3x = e1x + stack[4];
            const c4x = c3x + stack[5];
            csCubicTo(s, c3x, c2y, c4x, y, c4x + stack[6], y);
            sp = 0;
            return fontOk(true);
        }
        case 35: // flex: six deltas per curve pair, then the flex depth
        {
            if (sp != 13)
                return fail(FontErrorKind.badValue);
            foreach (k; 0 .. 2)
            {
                const c1x = s.x + stack[k * 6], c1y = s.y + stack[k * 6 + 1];
                const c2x = c1x + stack[k * 6 + 2], c2y = c1y + stack[k * 6 + 3];
                csCubicTo(s, c1x, c1y, c2x, c2y, c2x + stack[k * 6 + 4], c2y + stack[k * 6 + 5]);
            }
            sp = 0;
            return fontOk(true);
        }
        case 36: // hflex1: dx1 dy1 dx2 dy2 dx3 dx4 dx5 dy5 dx6
        {
            if (sp != 9)
                return fail(FontErrorKind.badValue);
            const y0 = s.y;
            const c1x = s.x + stack[0], c1y = y0 + stack[1];
            const c2x = c1x + stack[2], c2y = c1y + stack[3];
            const e1x = c2x + stack[4];
            csCubicTo(s, c1x, c1y, c2x, c2y, e1x, c2y);
            const c3x = e1x + stack[5];
            const c4x = c3x + stack[6], c4y = c2y + stack[7];
            csCubicTo(s, c3x, c2y, c4x, c4y, c4x + stack[8], y0);
            sp = 0;
            return fontOk(true);
        }
        case 37: // flex1: five delta pairs, then d6 on the axis that moved most
        {
            if (sp != 11)
                return fail(FontErrorKind.badValue);
            const x0 = s.x, y0 = s.y;
            long dx, dy;
            foreach (k; 0 .. 5)
            {
                dx += stack[2 * k];
                dy += stack[2 * k + 1];
            }
            const c1x = x0 + stack[0], c1y = y0 + stack[1];
            const c2x = c1x + stack[2], c2y = c1y + stack[3];
            const e1x = c2x + stack[4], e1y = c2y + stack[5];
            csCubicTo(s, c1x, c1y, c2x, c2y, e1x, e1y);
            const c3x = e1x + stack[6], c3y = e1y + stack[7];
            const c4x = c3x + stack[8], c4y = c3y + stack[9];
            if ((dx < 0 ? -dx : dx) > (dy < 0 ? -dy : dy))
                csCubicTo(s, c3x, c3y, c4x, c4y, c4x + stack[10], y0);
            else
                csCubicTo(s, c3x, c3y, c4x, c4y, x0, c4y + stack[10]);
            sp = 0;
            return fontOk(true);
        }
        default:
            return runArithmetic(s, esc, ctx, at);
    }
}

/**
The Type 2 arithmetic, storage and conditional operators, on 1/65,536
counts. A missing operand, an overflow, a division by zero, a transient
index past 32 and `roll`/`index` past the stack are `badValue`; `random`,
which no deterministic decoder can honour, is `unsupportedCapability`.
*/
private FontResult!bool runArithmetic(W)(ref CharState!W s, ubyte esc, scope ref CffContext ctx,
    size_t at)
{
    ref long[cff2MaxStack] stack = s.stack;
    ref size_t sp = s.sp;
    FontResult!bool fail(FontErrorKind kind)
        => fontErr!bool(tableError(kind, ctx.tag, ctx.start, at));
    size_t need;
    switch (esc)
    {
        case 5, 9, 14, 18, 21, 26, 27, 29: need = 1; break; // not abs neg drop get sqrt dup index
        case 3, 4, 10, 11, 12, 15, 20, 24, 28, 30: need = 2; break; // and or add sub div eq put mul exch roll
        case 22: need = 4; break; // ifelse
        case 23: return fail(FontErrorKind.unsupportedCapability); // random
        default: return fail(FontErrorKind.unsupportedVersion);
    }
    if (sp < need)
        return fail(FontErrorKind.badValue);
    enum long one = 1 << 16;
    bool overflow;
    const top = stack[sp - 1];
    const second = need >= 2 ? stack[sp - 2] : 0;
    long result;
    switch (esc)
    {
        case 3: result = second && top ? one : 0; break;
        case 4: result = second || top ? one : 0; break;
        case 5: result = top ? 0 : one; break;
        case 9: result = top < 0 ? negs(top, overflow) : top; break;
        case 10: result = adds(second, top, overflow); break;
        case 11: result = subs(second, top, overflow); break;
        case 12:
            if (top == 0)
                return fail(FontErrorKind.badValue);
            result = muls(second, one, overflow) / top;
            break;
        case 14: result = negs(top, overflow); break;
        case 15: result = second == top ? one : 0; break;
        case 18: --sp; return fontOk(true);
        case 20: // put: value index
        {
            const index = top >> 16;
            if (index < 0 || index >= cffTransientCount)
                return fail(FontErrorKind.badValue);
            s.transientStore[cast(size_t) index] = second;
            sp -= 2;
            return fontOk(true);
        }
        case 21: // get: index
        {
            const index = top >> 16;
            if (index < 0 || index >= cffTransientCount)
                return fail(FontErrorKind.badValue);
            stack[sp - 1] = s.transientStore[cast(size_t) index];
            return fontOk(true);
        }
        case 22: // ifelse: s1 s2 v1 v2
            stack[sp - 4] = stack[sp - 2] <= stack[sp - 1] ? stack[sp - 4] : stack[sp - 3];
            sp -= 3;
            return fontOk(true);
        case 24: result = muls(second, top, overflow) >> 16; break;
        case 26:
        {
            import std.math : sqrt;

            if (top < 0)
                return fail(FontErrorKind.badValue);
            stack[sp - 1] = cast(long)(sqrt(top / 65_536.0) * 65_536.0);
            return fontOk(true);
        }
        case 27: // dup
            if (sp >= (ctx.is2 ? cff2MaxStack : cff1MaxStack))
                return fail(FontErrorKind.badValue);
            stack[sp++] = top;
            return fontOk(true);
        case 28: // exch
            stack[sp - 1] = second;
            stack[sp - 2] = top;
            return fontOk(true);
        case 29: // index: a negative index copies the top
        {
            const n = top >> 16 < 0 ? 0 : top >> 16;
            const below = sp - 1; // the elements under the index operand
            if (n >= cast(long) below)
                return fail(FontErrorKind.badValue);
            stack[sp - 1] = stack[below - 1 - cast(size_t) n];
            return fontOk(true);
        }
        case 30: // roll: N elements by J positions, toward the top when J > 0
        {
            const n = second >> 16, j = top >> 16;
            sp -= 2;
            if (n < 0 || n > cast(long) sp)
                return fail(FontErrorKind.badValue);
            if (n == 0)
                return fontOk(true);
            const count = cast(size_t) n;
            auto items = stack[sp - count .. sp];
            const shift = cast(size_t)(((j % n) + n) % n);
            foreach (_; 0 .. shift)
            {
                const last = items[$ - 1];
                foreach_reverse (k; 1 .. count)
                    items[k] = items[k - 1];
                items[0] = last;
            }
            return fontOk(true);
        }
        default:
            assert(0);
    }
    if (overflow)
        return fail(FontErrorKind.badValue);
    sp -= need;
    stack[sp++] = result;
    return fontOk(true);
}

/**
Sets up glyph `gid`'s charstring and runs it into `writer`, in one function
so every borrowed slice stays a local: the charstring, and the Private DICT
and local subroutines its font dict selects (FDSelect, for CID-keyed `CFF`
and for `CFF2`). A `seac`-style `endchar` then runs the base glyph and the
accent glyph, offset by `(adx, ady)`, under the same operation budget; a
`seac` inside either, or a code StandardEncoding and the charset cannot
resolve to a glyph, is `badValue`.
*/
private FontResult!GlyphOutline runCffGlyph(W)(in Instance inst, uint gid, ref W writer)
{
    alias R = GlyphOutline;
    auto setup = cffInfo(inst.face, inst.axisCount);
    if (setup.hasError)
        return fontErr!R(setup.error);
    const top = setup.value;
    const tag = top.tag, start = top.start;
    if (gid >= inst.face.numGlyphs)
        return fontErr!R(FontError(FontErrorKind.indexOutOfRange, tag, start));
    const strings = readIndex(top.table, top.charStringsAt, tag, start);
    if (strings.hasError)
        return fontErr!R(strings.error);

    CharState!W state;
    state.writer = writerPtr(writer);
    Seac seac;
    size_t contours;
    foreach (step; 0 .. 3)
    {
        uint glyph = gid;
        if (step > 0)
        {
            const code = step == 1 ? seac.base : seac.accent;
            const found = code < 0 || code > 255 ? fontOk(0u)
                : cffGlyphOfSid(inst.face, standardEncoding[cast(size_t) code]);
            if (found.hasError)
                return fontErr!R(found.error);
            if (found.value == 0)
                return fontErr!R(tableError(FontErrorKind.badValue, tag, start, top.charStringsAt));
            glyph = found.value;
            const ops = state.ops;
            state = CharState!W.init;
            state.writer = writerPtr(writer);
            state.ops = ops;
            if (step == 2)
            {
                state.x = state.startX = seac.adx;
                state.y = state.startY = seac.ady;
            }
        }
        if (glyph >= strings.value.count)
            return fontErr!R(FontError(FontErrorKind.indexOutOfRange, tag, start));
        const charstring = strings.value.object(glyph);
        if (charstring.hasError)
            return fontErr!R(charstring.error);

        CffInfo info = top;
        if (info.fdArrayAt != 0)
        {
            const fd = cffFontDict(info, glyph);
            if (fd.hasError)
                return fontErr!R(fd.error);
            const fdIndex = readIndex(info.table, info.fdArrayAt, tag, start);
            if (fdIndex.hasError)
                return fontErr!R(fdIndex.error);
            if (fd.value >= fdIndex.value.count)
                return fontErr!R(tableError(FontErrorKind.badValue, tag, start, info.fdSelectAt));
            const fdDict = fdIndex.value.object(fd.value);
            if (fdDict.hasError)
                return fontErr!R(fdDict.error);
            DictOps found;
            const parsed = parseDict(fdDict.value, tag, start, found);
            if (parsed.hasError)
                return fontErr!R(parsed.error);
            info.subrsAt = -1;
            info.vsIndex = 0;
            if (found.privateOffset > 0)
            {
                const read = readPrivate(info, cast(size_t)(found.privateOffset >> 16),
                    found.privateSize > 0 ? cast(size_t)(found.privateSize >> 16) : 0);
                if (read.hasError)
                    return fontErr!R(read.error);
            }
        }
        const local = info.subrsAt >= 0
            ? readIndex(info.table, cast(size_t) info.subrsAt, tag, start) : fontOk(CffIndex.init);
        if (local.hasError)
            return fontErr!R(local.error);
        scope CffContext ctx;
        ctx.coords = inst.coords;
        ctx.globalSubrs = top.globalSubrs;
        ctx.localSubrs = local.value;
        ctx.hasLocalSubrs = info.subrsAt >= 0;
        ctx.tag = tag;
        ctx.start = start;
        ctx.is2 = top.is2;
        ctx.ivs = top.ivs;
        state.vsIndex = info.vsIndex;

        const ran = runCharstring(charstring.value, state, ctx, 0);
        if (ran.hasError)
            return fontErr!R(ran.error);
        csClose(state); // CFF2 ends a glyph at its end, not with endchar
        contours += state.contours;
        if (step > 0 && state.hasSeac)
            return fontErr!R(tableError(FontErrorKind.badValue, tag, start, top.charStringsAt));
        if (step == 0 && !state.hasSeac)
            break;
        if (step == 0)
            seac = state.seac;
    }
    GlyphOutline result;
    result.segmentCount = writer.count;
    result.contourCount = contours;
    result.empty = writer.count == 0;
    return fontOk(result);
}

package FontResult!GlyphOutline cffOutlineSink(Sink)(in Instance inst, uint gid, ref Sink sink)
{
    SinkWriter!Sink writer;
    writer.sink = writerPtr(sink);
    return runCffGlyph(inst, gid, writer);
}

@safe pure nothrow @nogc:

private enum cffTag = Tag("CFF "), cff2Tag = Tag("CFF2");

private struct CffIndex
{
    size_t count;
    size_t data; // one byte before the first object (offsets are 1-based)
    size_t end;
    const(ubyte)[] bytes;
    ulong tableStart;
    Tag tag;
    size_t headerAt;

    FontResult!(const(ubyte)[]) object(size_t i) const return scope @safe pure nothrow @nogc
    {
        if (i >= count)
            return fontErr!(const(ubyte)[])(FontError(FontErrorKind.indexOutOfRange, tag,
                tableStart));
        const countSize = tag == cff2Tag ? 4 : 2;
        const offSize = bytes[headerAt + countSize];
        const offsetsAt = headerAt + countSize + 1;
        uint readOffset(size_t j) const
        {
            size_t v;
            foreach (k; 0 .. offSize)
                v = (v << 8) | bytes[offsetsAt + j * offSize + k];
            return cast(uint) v;
        }
        const from = readOffset(i), to = readOffset(i + 1);
        if (from < 1 || from > to || data + to > bytes.length)
            return fontErr!(const(ubyte)[])(FontError(FontErrorKind.badValue, tag, tableStart));
        return fontOk(bytes[data + from .. data + to]);
    }
}

private FontResult!CffIndex readIndex(return scope const(ubyte)[] d, size_t at, Tag tag,
    ulong start)
{
    const countSize = tag == cff2Tag ? 4 : 2;
    if (!fits(d.length, at, countSize))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, tag, start, at));
    const count = countSize == 4 ? be32(d, at) : be16(d, at);
    if (count == 0)
        return fontOk(CffIndex(0, at + countSize - 1, at + countSize, d, start, tag, at));
    if (!fits(d.length, at, countSize + 1))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, tag, start, at));
    const offSize = d[at + countSize];
    if (offSize < 1 || offSize > 4)
        return fontErr!CffIndex(tableError(FontErrorKind.badValue, tag, start, at + countSize));
    const offsetsAt = at + countSize + 1;
    const offsetBytes = offSize * (ulong(count) + 1);
    if (!fits(d.length, offsetsAt, offsetBytes))
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, tag, start, offsetsAt));
    uint last;
    foreach (k; 0 .. offSize)
        last = (last << 8) | d[offsetsAt + count * offSize + k];
    const data = offsetsAt + offsetBytes - 1;
    const end = data + last;
    if (end > d.length)
        return fontErr!CffIndex(tableError(FontErrorKind.truncated, tag, start, end));
    return fontOk(CffIndex(count, data, end, d, start, tag, at));
}

/// The DICT operators this library reads, with their last operands.
private struct DictOps
{
    @safe pure nothrow @nogc:

    long charStrings = -1;
    long privateSize = -1, privateOffset = -1;
    long fdArray = -1, fdSelect = -1, vstore = -1;
    long charStringType = 2 << 16;
    long subrs = -1;
    long vsIndex = 0;

    void record(int op, scope const(long)[] ops)
    {
        if (ops.length == 0)
            return;
        switch (op)
        {
            case 17: charStrings = ops[$ - 1]; break;
            case 18:
                if (ops.length >= 2)
                {
                    privateSize = ops[$ - 2];
                    privateOffset = ops[$ - 1];
                }
                break;
            case 1236: fdArray = ops[$ - 1]; break;
            case 1237: fdSelect = ops[$ - 1]; break;
            case 1206: charStringType = ops[$ - 1]; break;
            case 19: subrs = ops[$ - 1]; break;
            case 22: vsIndex = ops[$ - 1]; break;
            case 24: vstore = ops[$ - 1]; break;
            default: break;
        }
    }
}

/// The largest operand stacks of `CFF` and `CFF2` (DICTs and charstrings).
private enum cff1MaxStack = 48, cff2MaxStack = 513;

/**
Parses a DICT into `found`. A `CFF2` DICT may also hold `vsindex`, `blend`
and `vstore` (operators 22–24); a `blend` keeps its default operands, so the
DICT reads as at the default instance, and takes its region count from `ivs`
under the DICT's `vsindex`. Costs O(n) for `n` bytes.
*/
private FontResult!bool parseDict(scope const(ubyte)[] dict, Tag tag, ulong start,
    ref DictOps found, in ItemVariationStore ivs = ItemVariationStore.init)
{
    long[cff2MaxStack] stack;
    const maxStack = tag == cff2Tag ? cff2MaxStack : cff1MaxStack;
    size_t sp;
    size_t i;
    FontResult!bool fail(FontErrorKind kind, size_t at) => fontErr!bool(tableError(kind, tag, start, at));
    while (i < dict.length)
    {
        const b = dict[i];
        if (b <= 21 || (b <= 24 && tag == cff2Tag))
        {
            int op = b;
            const opAt = i++;
            if (b == 12)
            {
                if (i >= dict.length)
                    return fail(FontErrorKind.truncated, i);
                op = 1200 + dict[i++];
            }
            if (op == 23) // blend: keep the n defaults, drop their n·k deltas
            {
                if (sp < 1 || !ivs.present)
                    return fail(FontErrorKind.badValue, opAt);
                const n = stack[--sp] >> 16;
                const vs = found.vsIndex >> 16;
                if (vs < 0 || vs > ushort.max)
                    return fail(FontErrorKind.badValue, opAt);
                const k = ivs.regionIndexCount(cast(ushort) vs);
                if (k.hasError)
                    return fontErr!bool(k.error);
                if (n < 0 || n > sp || n * (k.value + 1L) > sp)
                    return fail(FontErrorKind.badValue, opAt);
                sp = sp - cast(size_t)(n * (k.value + 1L)) + cast(size_t) n;
                continue;
            }
            found.record(op, stack[0 .. sp]);
            sp = 0;
            continue;
        }
        long value;
        size_t consumed;
        if (b == 30)
        {
            const real_ = dictReal(dict, i, tag, start);
            if (real_.hasError)
                return fontErr!bool(real_.error);
            value = real_.value.value;
            consumed = real_.value.consumed;
        }
        else if (b == 28 || (b >= 32 && b <= 254))
        {
            CffContext numbers;
            numbers.tag = tag;
            numbers.start = start;
            const number = decodeCharNumber(dict, i, numbers);
            if (number.hasError)
                return fontErr!bool(number.error);
            value = number.value.value;
            consumed = number.value.consumed;
        }
        else if (b == 29)
        {
            if (!fits(dict.length, i, 5))
                return fail(FontErrorKind.truncated, i);
            value = long(bes32(dict, i + 1)) << 16;
            consumed = 5;
        }
        else
            return fail(FontErrorKind.badValue, i);
        if (sp >= maxStack)
            return fail(FontErrorKind.badValue, i);
        stack[sp++] = value;
        i += consumed;
    }
    return fontOk(true);
}

/**
The DICT real number (operator 30) at `at`, as counts of 1/65,536: BCD
nibbles of digits, `.` (0xA), `E` (0xB), `E-` (0xC) and a leading `-` (0xE),
ended by 0xF. Nibble 0xD, a repeated or misplaced point, exponent or minus,
a number or exponent without digits, and a magnitude of 2^31 units or more
are `badValue`; a number the DICT ends inside is `truncated`. Digits past
the 17th significant one only scale the value, and the exponent saturates,
so the cost is O(n) for `n` bytes.
*/
private FontResult!CharNumber dictReal(scope const(ubyte)[] dict, size_t at, Tag tag, ulong start)
{
    long mantissa;
    long scale; // the power of ten the mantissa's digits stand for
    long exponent;
    bool negative, seenDigit, seenPoint, inExponent, expNegative, expDigit, done;
    FontResult!CharNumber fail(FontErrorKind kind, size_t where)
        => fontErr!CharNumber(tableError(kind, tag, start, where));
    size_t i = at + 1;
    while (!done)
    {
        if (i >= dict.length)
            return fail(FontErrorKind.truncated, at);
        const pair = dict[i++];
        foreach (half; 0 .. 2)
        {
            const nibble = half == 0 ? pair >> 4 : pair & 0x0F;
            if (nibble <= 9)
            {
                if (inExponent)
                {
                    expDigit = true;
                    if (exponent < 100_000)
                        exponent = exponent * 10 + nibble;
                }
                else
                {
                    seenDigit = true;
                    if (mantissa < 10_000_000_000_000_000L)
                    {
                        mantissa = mantissa * 10 + nibble;
                        if (seenPoint)
                            --scale;
                    }
                    else if (!seenPoint)
                        ++scale;
                }
            }
            else if (nibble == 0x0A)
            {
                if (seenPoint || inExponent)
                    return fail(FontErrorKind.badValue, i - 1);
                seenPoint = true;
            }
            else if (nibble == 0x0B || nibble == 0x0C)
            {
                if (inExponent || !seenDigit)
                    return fail(FontErrorKind.badValue, i - 1);
                inExponent = true;
                expNegative = nibble == 0x0C;
            }
            else if (nibble == 0x0E)
            {
                if (negative || seenDigit || seenPoint || inExponent)
                    return fail(FontErrorKind.badValue, i - 1);
                negative = true;
            }
            else if (nibble == 0x0F)
            {
                done = true;
                break;
            }
            else
                return fail(FontErrorKind.badValue, i - 1);
        }
    }
    if (!seenDigit || (inExponent && !expDigit))
        return fail(FontErrorKind.badValue, at);
    const power = scale + (expNegative ? -exponent : exponent);
    double value = mantissa;
    if (mantissa != 0)
    {
        if (power > 30)
            return fail(FontErrorKind.badValue, at);
        double ten = 1;
        foreach (_; 0 .. power < -30 ? 31 : power < 0 ? -power : power)
            ten *= 10;
        value = power < 0 ? value / ten : value * ten;
    }
    value *= 65_536.0;
    if (value >= 140_737_488_355_328.0) // 2^31 units
        return fail(FontErrorKind.badValue, at);
    const counts = cast(long)(value + 0.5);
    return fontOk(CharNumber(negative ? -counts : counts, i - at));
}

private struct CffInfo
{
    bool is2;
    const(ubyte)[] table;
    ulong start;
    Tag tag;
    size_t charStringsAt;
    size_t fdArrayAt;
    size_t fdSelectAt;
    long subrsAt = -1; // absolute, -1 absent
    ushort vsIndex; // the Private DICT's: a CFF2 charstring's until its own vsindex
    CffIndex globalSubrs;
    ItemVariationStore ivs; // CFF2's vstore, absent otherwise
}

/// The `CFF` or `CFF2` table of `face`, its Top DICT and its Private DICT
/// read; `axisCount` is the instance's, for the `CFF2` variation store.
private FontResult!CffInfo cffInfo(return scope const Face face, ushort axisCount)
{
    // Prefer the table matching the outline format signature; a face is
    // OTTO (CFF) or TrueType. CFF2 faces carry the CFF2 tag.
    Tag tag = cffTag;
    if (face.has(cff2Tag) && !face.has(cffTag))
        tag = cff2Tag;
    else if (!face.has(cffTag))
        return fontErr!CffInfo(FontError(FontErrorKind.missingTable,
            face.has(cff2Tag) ? cff2Tag : cffTag));
    const is2 = tag == cff2Tag;
    auto at = locate(face, tag);
    if (at.hasError)
        return fontErr!CffInfo(at.error);
    const d = at.value.data;
    const start = at.value.start;
    if (d.length < 4)
        return fontErr!CffInfo(tableError(FontErrorKind.truncated, tag, start, d.length));
    const major = d[0];
    if (is2 ? major != 2 : major != 1)
        return fontErr!CffInfo(tableError(FontErrorKind.unsupportedVersion, tag, start, 0));
    const headerSize = d[2];
    DictOps found;
    size_t gsubrAt;
    if (is2)
    {
        // CFF2: the Top DICT follows the header directly; no Name or
        // String INDEX, and the Global Subr INDEX follows the Top DICT.
        if (d.length < 5)
            return fontErr!CffInfo(tableError(FontErrorKind.truncated, tag, start, d.length));
        const topLength = be16(d, 3);
        if (!fits(d.length, headerSize, topLength))
            return fontErr!CffInfo(tableError(FontErrorKind.truncated, tag, start, headerSize));
        const parsedTop = parseDict(d[headerSize .. headerSize + topLength], tag, start, found);
        if (parsedTop.hasError)
            return fontErr!CffInfo(parsedTop.error);
        gsubrAt = headerSize + topLength;
    }
    else
    {
        const nameIndex = readIndex(d, headerSize, tag, start);
        if (nameIndex.hasError)
            return fontErr!CffInfo(nameIndex.error);
        const topIndex = readIndex(d, nameIndex.value.end, tag, start);
        if (topIndex.hasError)
            return fontErr!CffInfo(topIndex.error);
        if (topIndex.value.count < 1)
            return fontErr!CffInfo(tableError(FontErrorKind.badValue, tag, start, headerSize));
        const top = topIndex.value.object(0);
        if (top.hasError)
            return fontErr!CffInfo(top.error);
        const parsedTop = parseDict(top.value, tag, start, found);
        if (parsedTop.hasError)
            return fontErr!CffInfo(parsedTop.error);
        const stringIndex = readIndex(d, topIndex.value.end, tag, start);
        if (stringIndex.hasError)
            return fontErr!CffInfo(stringIndex.error);
        gsubrAt = stringIndex.value.end;
    }
    const gsubr = readIndex(d, gsubrAt, tag, start);
    if (gsubr.hasError)
        return fontErr!CffInfo(gsubr.error);
    size_t offsetOf(long raw) => raw >= 0 ? cast(size_t)(raw >> 16) : 0;
    if (found.charStringType != 2 << 16)
        return fontErr!CffInfo(tableError(FontErrorKind.unsupportedVersion, tag, start, 0));
    CffInfo info;
    info.is2 = is2;
    info.table = d;
    info.start = start;
    info.tag = tag;
    info.charStringsAt = offsetOf(found.charStrings);
    info.fdArrayAt = offsetOf(found.fdArray);
    info.fdSelectAt = offsetOf(found.fdSelect);
    info.globalSubrs = gsubr.value;
    if (info.charStringsAt == 0 || info.charStringsAt >= d.length)
        return fontErr!CffInfo(tableError(FontErrorKind.badOffset, tag, start, 0));
    if (is2 && found.vstore >= 0)
        info.ivs = ItemVariationStore.read(d, tag, start, offsetOf(found.vstore) + 2UL, axisCount);
    if (!is2 && found.privateOffset > 0)
    {
        const read = readPrivate(info, offsetOf(found.privateOffset), offsetOf(found.privateSize));
        if (read.hasError)
            return fontErr!CffInfo(read.error);
    }
    return fontOk(info);
}

/// Reads the Private DICT of `size` bytes at `at`: its Subrs and `vsindex`.
private FontResult!bool readPrivate(ref CffInfo info, size_t at, size_t size)
{
    const d = info.table;
    if (!fits(d.length, at, size))
        return fontErr!bool(tableError(FontErrorKind.truncated, info.tag, info.start, at));
    DictOps found;
    const parsed = parseDict(d[at .. at + size], info.tag, info.start, found, info.ivs);
    if (parsed.hasError)
        return parsed;
    const vs = found.vsIndex >> 16;
    if (vs < 0 || vs > ushort.max)
        return fontErr!bool(tableError(FontErrorKind.badValue, info.tag, info.start, at));
    info.vsIndex = cast(ushort) vs;
    info.subrsAt = found.subrs >= 0 ? cast(long) at + (found.subrs >> 16) : -1; // relative to Private
    return fontOk(true);
}

/**
Selects the font dict for `gid` in a CID-keyed font or a `CFF2` font: 0
without an FDSelect. Formats 0, 3 and 4 (`CFF2`'s 32-bit ranges); a glyph
no range covers is `badValue`. Costs O(r) for `r` ranges.
*/
private FontResult!uint cffFontDict(scope const ref CffInfo info, uint gid)
{
    if (info.fdArrayAt == 0 || info.fdSelectAt == 0)
        return fontOk(0u);
    const d = info.table;
    const at = info.fdSelectAt;
    FontResult!uint fail(FontErrorKind kind, size_t where)
        => fontErr!uint(tableError(kind, info.tag, info.start, where));
    if (at >= d.length)
        return fail(FontErrorKind.badOffset, at);
    const format = d[at];
    if (format == 0)
    {
        if (!fits(d.length, at + 1, gid + 1UL))
            return fail(FontErrorKind.truncated, at);
        return fontOk!uint(d[at + 1 + gid]);
    }
    if (format != 3 && format != 4)
        return fail(FontErrorKind.unsupportedVersion, at);
    const wide = format == 4;
    const firstSize = wide ? 4 : 2;
    const rangeSize = firstSize + (wide ? 2 : 1);
    if (!fits(d.length, at + 1, firstSize))
        return fail(FontErrorKind.truncated, at);
    const ranges = wide ? be32(d, at + 1) : be16(d, at + 1);
    const rangesAt = at + 1 + firstSize;
    // The ranges, then a sentinel glyph id ending the last.
    if (!fits(d.length, rangesAt, ulong(rangeSize) * ranges + firstSize))
        return fail(FontErrorKind.truncated, rangesAt);
    ulong firstAt(size_t r)
    {
        const p = rangesAt + r * rangeSize;
        return wide ? be32(d, p) : be16(d, p);
    }
    foreach (r; 0 .. cast(size_t) ranges)
    {
        if (gid >= firstAt(r) && gid < firstAt(r + 1))
        {
            const p = rangesAt + r * rangeSize + firstSize;
            return fontOk!uint(wide ? be16(d, p) : d[p]);
        }
    }
    return fail(FontErrorKind.badValue, at);
}

// --- Charstring interpretation, over a segment writer ---

/// The Type 2 transient array's size, and the deepest subroutine nesting (FTB3).
private enum cffTransientCount = 32,
    cffMaxDepth = cast(size_t) fontLimitValue[FontLimit.cffSubroutineDepth];

/// A `seac`-style `endchar`: the accent's offset and the StandardEncoding codes of both glyphs.
private struct Seac
{
    long adx, ady;
    long base, accent;
}

private struct CffContext
{
    @safe pure nothrow @nogc:

    CffIndex globalSubrs;
    CffIndex localSubrs;
    bool hasLocalSubrs;
    Tag tag;
    ulong start;
    bool is2;
    ItemVariationStore ivs;
    NormalizedCoords coords;
}

private struct CharNumber
{
    long value;
    size_t consumed;
}

private FontResult!CharNumber decodeCharNumber(scope const(ubyte)[] cs, size_t i, in CffContext ctx)
{
    const b = cs[i];
    if (b == 28)
    {
        if (!fits(cs.length, i, 3))
            return fontErr!CharNumber(tableError(FontErrorKind.truncated, ctx.tag, ctx.start, i));
        return fontOk(CharNumber(cast(long) bes16(cs, i + 1) << 16, 3));
    }
    if (b == 255)
    {
        if (!fits(cs.length, i, 5))
            return fontErr!CharNumber(tableError(FontErrorKind.truncated, ctx.tag, ctx.start, i));
        return fontOk(CharNumber(bes32(cs, i + 1), 5));
    }
    if (b >= 32 && b <= 246)
        return fontOk(CharNumber(long(b - 139) << 16, 1));
    if (b >= 247 && b <= 250)
    {
        if (i + 1 >= cs.length)
            return fontErr!CharNumber(tableError(FontErrorKind.truncated, ctx.tag, ctx.start, i));
        return fontOk(CharNumber((long(b - 247) * 256 + cs[i + 1] + 108) << 16, 2));
    }
    if (b >= 251 && b <= 254)
    {
        if (i + 1 >= cs.length)
            return fontErr!CharNumber(tableError(FontErrorKind.truncated, ctx.tag, ctx.start, i));
        return fontOk(CharNumber((-long(b - 251) * 256 - cs[i + 1] - 108) << 16, 2));
    }
    return fontErr!CharNumber(tableError(FontErrorKind.badValue, ctx.tag, ctx.start, i));
}

private uint subrBias(size_t count) => count < 1_240 ? 107 : count < 33_900 ? 1_131 : 32_768;

package FontResult!GlyphOutline cffOutline(in Instance inst, uint gid, ref SegmentWriter writer)
    => runCffGlyph(inst, gid, writer);
