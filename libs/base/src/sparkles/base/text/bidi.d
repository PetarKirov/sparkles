/**
 * Owned Unicode 18 UAX #9 revision 52 paragraph resolution and L1/L2 maps.
 *
 * `resolveBidiParagraph` accepts exactly one paragraph (a B separator may occur
 * only at its end). All original tokens, controls and source spans remain borrowed
 * unchanged. X9 entries have `bidiRemovedLevel` and `bidiNoPosition`, never a
 * fabricated glyph position. Other zero-width controls still participate in maps;
 * these maps describe scalar ordering, not glyphs, mirroring or visual carets.
 *
 * Each workspace slice needs one element per input token; the fixed 127-entry
 * directional stack and 63-entry BD16 bracket stack are owned by the workspace.
 * No allocation or paragraph maximum is imposed. Work is linear (with the fixed
 * normative depth/bracket bounds). A call invalidates earlier views into its
 * workspace. Failure returns an empty view; scratch may change, input may not.
 * All input, scratch and output storage must be disjoint. Line maps use absolute
 * paragraph logical indices, and line-relative visual positions. Paragraph maps
 * apply L1/L2 with the whole paragraph selected as one line; `cells[].level`
 * retains the pre-L1 paragraph level for subsequent selected-line resolution.
 *
 * Authority: https://www.unicode.org/reports/tr9/tr9-52.html
 */
module sparkles.base.text.bidi;

import sparkles.base.text.utf : UtfToken, UtfTokenKind, utfStorageOverlaps;
import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus,
    UnicodeSourceSpan, validUnicodeToken;
import sparkles.base.text.unicode_tables : BidiClass, bidiClass, bidiBracket, bidiBracketType;

/// P2/P3 automatic direction defaults to LTR in the absence of a strong scalar.
enum BidiDirection : ubyte { ltr, rtl, automatic }
enum ubyte bidiRemovedLevel = ubyte.max;
enum size_t bidiNoPosition = size_t.max;

/// Per-original-token resolution and source-independent internal metadata.
struct BidiCell
{
    BidiClass original;
    BidiClass resolved;
    ubyte level;
    ubyte lineLevel;
    size_t logicalToVisual = bidiNoPosition;
    private ubyte explicitLevel;
    private size_t matching = bidiNoPosition;
    private size_t previous = bidiNoPosition;
    private size_t next = bidiNoPosition;
    private size_t run = bidiNoPosition;
    private size_t runEnd = bidiNoPosition;
    private size_t runNext = bidiNoPosition;
    private bool continuation;
    private BidiClass firstStrong = BidiClass.ON;
    private size_t bracketEnd = bidiNoPosition;
    private size_t leftCount;
    private size_t rightCount;
}
struct BidiDirectionalStatus
{
    ubyte level;
    BidiClass overrideType = BidiClass.ON;
    bool isolate;
}
struct BidiBracketStatus
{
    dchar mate;
    size_t position;
}
/// All variable-length slices require input.length elements, even for X9 controls.
struct BidiWorkspace
{
    BidiCell[] cells;
    size_t[] sequence;
    size_t[] visualToLogical;
    BidiDirectionalStatus[127] directionalStack;
    BidiBracketStatus[63] bracketStack;
}
struct BidiParagraph
{
    const(UtfToken)[] source;
    const(BidiCell)[] cells;
    const(size_t)[] visualToLogical;
    ubyte baseLevel;
}
struct BidiParagraphResult
{
    UnicodeResult outcome;
    BidiParagraph paragraph;
}
/// Line scratch uses one element per selected original logical token.
struct BidiLineWorkspace
{
    ubyte[] levels;
    size_t[] logicalToVisual;
    size_t[] visualToLogical;
}
struct BidiLine
{
    size_t start;
    size_t end;
    const(ubyte)[] levels;
    const(size_t)[] logicalToVisual;
    const(size_t)[] visualToLogical;
}
struct BidiLineResult
{
    UnicodeResult outcome;
    BidiLine line;
}

private bool removed(BidiClass t) @safe pure nothrow @nogc
{
    return t == BidiClass.BN || t == BidiClass.LRE || t == BidiClass.RLE ||
        t == BidiClass.LRO || t == BidiClass.RLO || t == BidiClass.PDF;
}
private bool initiator(BidiClass t) @safe pure nothrow @nogc
{
    return t == BidiClass.LRI || t == BidiClass.RLI || t == BidiClass.FSI;
}
private bool whitespace(BidiClass t) @safe pure nothrow @nogc
{
    return t == BidiClass.WS || initiator(t) || t == BidiClass.PDI;
}
private BidiClass direction(uint level) @safe pure nothrow @nogc
{
    return level & 1 ? BidiClass.R : BidiClass.L;
}
private BidiClass strong(BidiClass t) @safe pure nothrow @nogc
{
    return t == BidiClass.EN || t == BidiClass.AN ? BidiClass.R : t;
}
private bool neutral(BidiClass t) @safe pure nothrow @nogc
{
    return whitespace(t) || t == BidiClass.ON || t == BidiClass.B || t == BidiClass.S;
}
private dchar canonicalBracket(dchar cp) @safe pure nothrow @nogc
{
    return cp == 0x232A ? cast(dchar) 0x3009 : cp;
}
private UnicodeResult failure(UnicodeStatus status, size_t required = 0,
    UnicodeSourceSpan blocking = UnicodeSourceSpan.init) @safe pure nothrow @nogc
{
    return UnicodeResult(status: status, required: required, blocking: blocking);
}

BidiParagraphResult resolveBidiParagraph(return scope const(UtfToken)[] input,
    BidiDirection requested, return scope ref BidiWorkspace workspace) @safe pure nothrow @nogc
{
    BidiParagraphResult result;
    const n = input.length;
    if (requested != BidiDirection.ltr && requested != BidiDirection.rtl &&
        requested != BidiDirection.automatic)
    {
        result.outcome = failure(UnicodeStatus.invalidOptions);
        return result;
    }
    if (utfStorageOverlaps(input, workspace.cells) ||
        utfStorageOverlaps(input, workspace.sequence) ||
        utfStorageOverlaps(input, workspace.visualToLogical) ||
        utfStorageOverlaps(input, workspace.directionalStack[]) ||
        utfStorageOverlaps(input, workspace.bracketStack[]) ||
        utfStorageOverlaps(workspace.cells, workspace.directionalStack[]) ||
        utfStorageOverlaps(workspace.cells, workspace.bracketStack[]) ||
        utfStorageOverlaps(workspace.sequence, workspace.directionalStack[]) ||
        utfStorageOverlaps(workspace.sequence, workspace.bracketStack[]) ||
        utfStorageOverlaps(workspace.visualToLogical, workspace.directionalStack[]) ||
        utfStorageOverlaps(workspace.visualToLogical, workspace.bracketStack[]) ||
        utfStorageOverlaps(workspace.cells, workspace.sequence) ||
        utfStorageOverlaps(workspace.cells, workspace.visualToLogical) ||
        utfStorageOverlaps(workspace.sequence, workspace.visualToLogical))
    {
        result.outcome = failure(UnicodeStatus.overlap);
        return result;
    }
    foreach (i, ref const token; input)
    {
        if ((token.kind != UtfTokenKind.scalar && token.kind != UtfTokenKind.replacement) ||
            !validUnicodeToken(token) ||
            (bidiClass(token.scalar) == BidiClass.B && i + 1 != n))
        {
            result.outcome = failure(UnicodeStatus.invalidInput, 0,
                UnicodeSourceSpan(token.start, token.end));
            return result;
        }
    }
    const capacity = minSize(workspace.cells.length,
        minSize(workspace.sequence.length, workspace.visualToLogical.length));
    if (capacity < n)
    {
        result.outcome = failure(UnicodeStatus.workspaceFull, n,
            UnicodeSourceSpan(input[capacity].start, input[capacity].end));
        return result;
    }
    auto cells = workspace.cells[0 .. n];
    foreach (i, ref const token; input)
    {
        cells[i] = BidiCell.init;
        cells[i].original = cells[i].resolved = bidiClass(token.scalar);
    }
    // BD9 matching is independent of explicit-depth overflow. The predecessor
    // field temporarily holds the unbounded isolate stack, in caller storage.
    size_t top = bidiNoPosition;
    foreach (i; 0 .. n)
    {
        if (initiator(cells[i].original))
        {
            cells[i].previous = top;
            top = i;
        }
        else if (cells[i].original == BidiClass.PDI && top != bidiNoPosition)
        {
            cells[top].matching = i;
            cells[i].matching = top;
            top = cells[top].previous;
        }
    }
    // Reverse dynamic scan answers P2 for each FSI without rescanning nested text.
    BidiClass first = BidiClass.ON;
    for (size_t i = n; i; )
    {
        --i;
        auto t = cells[i].original;
        if (t == BidiClass.PDI && cells[i].matching != bidiNoPosition)
        {
            cells[i].firstStrong = first;
            first = BidiClass.ON;
        }
        else if (initiator(t))
        {
            cells[i].firstStrong = first;
            first = cells[i].matching == bidiNoPosition ? BidiClass.ON :
                cells[cells[i].matching].firstStrong;
        }
        else if (t == BidiClass.L || t == BidiClass.R || t == BidiClass.AL)
            first = t;
    }
    const ubyte base = requested == BidiDirection.rtl ? 1 :
        requested == BidiDirection.ltr ? 0 :
        cast(ubyte) (first == BidiClass.R || first == BidiClass.AL);
    auto stack = workspace.directionalStack[];
    size_t depth = 1, overflowIsolate = 0, overflowEmbedding = 0, validIsolate = 0;
    stack[0] = BidiDirectionalStatus(base, BidiClass.ON, false);
    foreach (i; 0 .. n)
    {
        auto t = cells[i].original;
        auto current = stack[depth - 1];
        cells[i].explicitLevel = current.level;
        if (t == BidiClass.RLE || t == BidiClass.LRE ||
            t == BidiClass.RLO || t == BidiClass.LRO || initiator(t))
        {
            bool isolate = initiator(t);
            bool right = t == BidiClass.RLE || t == BidiClass.RLO || t == BidiClass.RLI ||
                (t == BidiClass.FSI && (cells[i].firstStrong == BidiClass.R ||
                    cells[i].firstStrong == BidiClass.AL));
            const nextLevel = right ? (current.level + 1) | 1 : (current.level + 2) & ~1;
            if (isolate && current.overrideType != BidiClass.ON)
                cells[i].resolved = current.overrideType;
            if (nextLevel <= 125 && !overflowIsolate && !overflowEmbedding)
            {
                const overrideType = t == BidiClass.LRO ? BidiClass.L :
                    t == BidiClass.RLO ? BidiClass.R : BidiClass.ON;
                stack[depth++] = BidiDirectionalStatus(cast(ubyte) nextLevel, overrideType, isolate);
                if (isolate) ++validIsolate;
            }
            else if (isolate) ++overflowIsolate;
            else if (!overflowIsolate) ++overflowEmbedding;
        }
        else if (t == BidiClass.PDI)
        {
            if (overflowIsolate) --overflowIsolate;
            else if (validIsolate)
            {
                overflowEmbedding = 0;
                while (!stack[depth - 1].isolate) --depth;
                --depth;
                --validIsolate;
            }
            current = stack[depth - 1];
            cells[i].explicitLevel = current.level;
            if (current.overrideType != BidiClass.ON) cells[i].resolved = current.overrideType;
        }
        else if (t == BidiClass.PDF)
        {
            if (!overflowIsolate)
            {
                if (overflowEmbedding) --overflowEmbedding;
                else if (depth > 1 && !current.isolate) --depth;
            }
        }
        else if (t == BidiClass.B) cells[i].explicitLevel = base;
        else if (t != BidiClass.BN && current.overrideType != BidiClass.ON)
            cells[i].resolved = current.overrideType;
        cells[i].level = removed(t) ? bidiRemovedLevel : cells[i].explicitLevel;
    }
    // Build X9-filtered logical links and maximal level runs.
    size_t previous = bidiNoPosition, run = bidiNoPosition;
    foreach (i; 0 .. n)
    {
        cells[i].previous = bidiNoPosition;
        if (removed(cells[i].original)) continue;
        cells[i].previous = previous;
        if (previous != bidiNoPosition) cells[previous].next = i;
        if (previous == bidiNoPosition || cells[previous].explicitLevel != cells[i].explicitLevel)
            run = i;
        cells[i].run = run;
        cells[run].runEnd = i;
        previous = i;
    }
    foreach (i; 0 .. n)
    {
        if (cells[i].run != i) continue;
        const last = cells[i].runEnd;
        const match = cells[last].matching;
        if (initiator(cells[last].original) && match != bidiNoPosition &&
            cells[match].run != i && cells[match].explicitLevel == cells[last].explicitLevel)
        {
            cells[i].runNext = cells[match].run;
            cells[cells[match].run].continuation = true;
        }
    }
    foreach (i; 0 .. n)
    {
        if (cells[i].run != i || cells[i].continuation) continue;
        size_t count = 0, currentRun = i;
        while (currentRun != bidiNoPosition)
        {
            size_t index = currentRun;
            while (true)
            {
                workspace.sequence[count++] = index;
                if (index == cells[currentRun].runEnd) break;
                index = cells[index].next;
            }
            currentRun = cells[currentRun].runNext;
        }
        const last = workspace.sequence[count - 1];
        const before = cells[i].previous;
        const after = cells[last].next;
        const sos = direction(maxLevel(cells[i].explicitLevel,
            before == bidiNoPosition ? base : cells[before].explicitLevel));
        const eos = direction(maxLevel(cells[last].explicitLevel,
            after == bidiNoPosition || initiator(cells[last].original) ? base : cells[after].explicitLevel));
        resolveSequence(input, cells, workspace.sequence[0 .. count], sos, eos,
            workspace.bracketStack[]);
    }
    // L1/L2 default whole-paragraph maps, without losing pre-line levels.
    foreach (ref cell; cells) cell.lineLevel = cell.level;
    resetParagraphLine(cells, base);
    size_t visible = 0;
    foreach (i; 0 .. n)
        if (cells[i].level != bidiRemovedLevel) workspace.visualToLogical[visible++] = i;
    reorderParagraph(cells, workspace.visualToLogical[0 .. visible]);
    foreach (position, logical; workspace.visualToLogical[0 .. visible])
        cells[logical].logicalToVisual = position;
    result.outcome = UnicodeResult(status: UnicodeStatus.ok, written: n, required: n);
    result.paragraph = BidiParagraph(input, workspace.cells[0 .. n],
        workspace.visualToLogical[0 .. visible], base);
    return result;
}

private size_t minSize(size_t a, size_t b) @safe pure nothrow @nogc => a < b ? a : b;
private uint maxLevel(uint a, uint b) @safe pure nothrow @nogc => a > b ? a : b;

private void resolveSequence(scope const(UtfToken)[] input, BidiCell[] cells,
    scope const(size_t)[] sequence, BidiClass sos, BidiClass eos,
    BidiBracketStatus[] brackets) @safe pure nothrow @nogc
{
    auto previous = sos;
    foreach (index; sequence) // W1
    {
        if (cells[index].resolved == BidiClass.NSM)
            cells[index].resolved = initiator(previous) || previous == BidiClass.PDI ? BidiClass.ON : previous;
        previous = cells[index].resolved;
    }
    auto context = sos;
    foreach (index; sequence) // W2
    {
        auto t = cells[index].resolved;
        if (t == BidiClass.EN && context == BidiClass.AL) cells[index].resolved = BidiClass.AN;
        else if (t == BidiClass.L || t == BidiClass.R || t == BidiClass.AL) context = t;
    }
    foreach (index; sequence) // W3
        if (cells[index].resolved == BidiClass.AL) cells[index].resolved = BidiClass.R;
    foreach (position, index; sequence) // W4
    {
        auto t = cells[index].resolved;
        if (!position || position + 1 == sequence.length) continue;
        const a = cells[sequence[position - 1]].resolved;
        const b = cells[sequence[position + 1]].resolved;
        if (a == b && ((t == BidiClass.ES && a == BidiClass.EN) ||
            (t == BidiClass.CS && (a == BidiClass.EN || a == BidiClass.AN))))
            cells[index].resolved = a;
    }
    for (size_t p = 0; p < sequence.length; ) // W5
    {
        if (cells[sequence[p]].resolved != BidiClass.ET) { ++p; continue; }
        const start = p;
        while (p < sequence.length && cells[sequence[p]].resolved == BidiClass.ET) ++p;
        if ((start && cells[sequence[start - 1]].resolved == BidiClass.EN) ||
            (p < sequence.length && cells[sequence[p]].resolved == BidiClass.EN))
            foreach (q; start .. p) cells[sequence[q]].resolved = BidiClass.EN;
    }
    foreach (index; sequence) // W6
    {
        auto t = cells[index].resolved;
        if (t == BidiClass.ET || t == BidiClass.ES || t == BidiClass.CS)
            cells[index].resolved = BidiClass.ON;
    }
    context = sos;
    foreach (index; sequence) // W7
    {
        auto t = cells[index].resolved;
        if (t == BidiClass.EN && context == BidiClass.L) cells[index].resolved = BidiClass.L;
        else if (t == BidiClass.L || t == BidiClass.R) context = t;
    }
    // BD16. Store pairs at opening positions, already sorted without a sort.
    size_t depth = 0;
    bool bracketOverflow = false;
    foreach (p, index; sequence)
    {
        if (cells[index].resolved != BidiClass.ON) continue;
        const kind = bidiBracketType(input[index].scalar);
        if (kind == 1)
        {
            if (depth == 63) { bracketOverflow = true; break; }
            brackets[depth++] = BidiBracketStatus(canonicalBracket(bidiBracket(input[index].scalar)), p);
        }
        else if (kind == 2)
        {
            auto cp = canonicalBracket(input[index].scalar);
            for (size_t q = depth; q; )
            {
                --q;
                if (brackets[q].mate == cp)
                {
                    cells[sequence[brackets[q].position]].bracketEnd = p;
                    depth = q;
                    break;
                }
            }
        }
    }
    if (bracketOverflow)
        foreach (index; sequence) cells[index].bracketEnd = bidiNoPosition;
    // Prefix counts make enclosure searches constant-time even for long spans.
    size_t left = 0, right = 0;
    foreach (index; sequence)
    {
        const t = strong(cells[index].resolved);
        if (t == BidiClass.L) ++left;
        if (t == BidiClass.R) ++right;
        cells[index].leftCount = left;
        cells[index].rightCount = right;
    }
    const embedding = direction(cells[sequence[0]].explicitLevel);
    context = sos;
    foreach (p, index; sequence) // N0, ascending opening positions
    {
        const close = cells[index].bracketEnd;
        if (close != bidiNoPosition)
        {
            const closeIndex = sequence[close];
            const hasLeft = cells[closeIndex].leftCount > cells[index].leftCount;
            const hasRight = cells[closeIndex].rightCount > cells[index].rightCount;
            BidiClass selected = BidiClass.ON;
            if (embedding == BidiClass.L ? hasLeft : hasRight) selected = embedding;
            else if (hasLeft || hasRight) selected = context;
            if (selected != BidiClass.ON)
            {
                cells[index].resolved = cells[closeIndex].resolved = selected;
                const size_t[2] endpoints = [p, close];
                foreach (position; endpoints)
                {
                    size_t q = position + 1;
                    while (q < sequence.length && cells[sequence[q]].original == BidiClass.NSM)
                        cells[sequence[q++]].resolved = selected;
                }
            }
        }
        const t = strong(cells[index].resolved);
        if (t == BidiClass.L || t == BidiClass.R) context = t;
    }
    previous = sos;
    for (size_t p = 0; p < sequence.length; ) // N1/N2
    {
        if (!neutral(cells[sequence[p]].resolved))
        { previous = strong(cells[sequence[p++]].resolved); continue; }
        const start = p;
        while (p < sequence.length && neutral(cells[sequence[p]].resolved)) ++p;
        const following = p == sequence.length ? eos : strong(cells[sequence[p]].resolved);
        const selected = previous == following ? previous : embedding;
        foreach (q; start .. p) cells[sequence[q]].resolved = selected;
        previous = selected;
    }
    foreach (index; sequence) // I1/I2
    {
        const t = cells[index].resolved;
        if (cells[index].level & 1)
        {
            if (t == BidiClass.L || t == BidiClass.EN || t == BidiClass.AN) ++cells[index].level;
        }
        else if (t == BidiClass.R) ++cells[index].level;
        else if (t == BidiClass.EN || t == BidiClass.AN) cells[index].level += 2;
    }
}

private void resetParagraphLine(BidiCell[] cells, ubyte base) @safe pure nothrow @nogc
{
    size_t start = 0;
    foreach (i, ref cell; cells)
    {
        if (removed(cell.original)) continue;
        if (whitespace(cell.original)) continue;
        if (cell.original == BidiClass.B || cell.original == BidiClass.S)
        {
            foreach (j; start .. i + 1)
                if (!removed(cells[j].original)) cells[j].lineLevel = base;
        }
        start = i + 1;
    }
    foreach (j; start .. cells.length)
        if (!removed(cells[j].original)) cells[j].lineLevel = base;
}
private void reorderParagraph(scope const(BidiCell)[] cells, size_t[] map) @safe pure nothrow @nogc
{
    uint highest = 0, lowestOdd = 127;
    foreach (index; map)
    {
        const level = cells[index].lineLevel;
        highest = maxLevel(highest, level);
        if ((level & 1) && level < lowestOdd) lowestOdd = level;
    }
    for (uint level = highest; level >= lowestOdd; --level)
    {
        for (size_t p = 0; p < map.length; )
        {
            if (cells[map[p]].lineLevel < level) { ++p; continue; }
            const start = p;
            while (p < map.length && cells[map[p]].lineLevel >= level) ++p;
            reverseMap(map[start .. p]);
        }
    }
}
private void reverseMap(size_t[] map) @safe pure nothrow @nogc
{
    for (size_t a = 0, b = map.length; a < b; ++a)
    {
        --b;
        if (a >= b) break;
        const temporary = map[a]; map[a] = map[b]; map[b] = temporary;
    }
}

BidiLineResult resolveBidiLine(scope const BidiParagraph paragraph, size_t start,
    size_t end, return scope ref BidiLineWorkspace workspace) @safe pure nothrow @nogc
{
    BidiLineResult result;
    if (start > end || end > paragraph.cells.length ||
        paragraph.source.length != paragraph.cells.length || paragraph.baseLevel > 1)
    { result.outcome = failure(UnicodeStatus.invalidOptions); return result; }
    if (utfStorageOverlaps(paragraph.source, workspace.levels) ||
        utfStorageOverlaps(paragraph.source, workspace.logicalToVisual) ||
        utfStorageOverlaps(paragraph.source, workspace.visualToLogical) ||
        utfStorageOverlaps(paragraph.cells, workspace.levels) ||
        utfStorageOverlaps(paragraph.cells, workspace.logicalToVisual) ||
        utfStorageOverlaps(paragraph.cells, workspace.visualToLogical) ||
        utfStorageOverlaps(paragraph.visualToLogical, workspace.levels) ||
        utfStorageOverlaps(paragraph.visualToLogical, workspace.logicalToVisual) ||
        utfStorageOverlaps(paragraph.visualToLogical, workspace.visualToLogical) ||
        utfStorageOverlaps(workspace.levels, workspace.logicalToVisual) ||
        utfStorageOverlaps(workspace.levels, workspace.visualToLogical) ||
        utfStorageOverlaps(workspace.logicalToVisual, workspace.visualToLogical))
    { result.outcome = failure(UnicodeStatus.overlap); return result; }
    const n = end - start;
    const capacity = minSize(workspace.levels.length,
        minSize(workspace.logicalToVisual.length, workspace.visualToLogical.length));
    if (capacity < n)
    {
        const token = paragraph.source[start + capacity];
        result.outcome = failure(UnicodeStatus.workspaceFull, n, UnicodeSourceSpan(token.start, token.end));
        return result;
    }
    auto levels = workspace.levels[0 .. n];
    auto inverse = workspace.logicalToVisual[0 .. n];
    size_t resetStart = 0, visible = 0;
    foreach (i, ref const cell; paragraph.cells[start .. end])
    {
        levels[i] = cell.level;
        inverse[i] = bidiNoPosition;
        if (removed(cell.original)) continue;
        workspace.visualToLogical[visible++] = start + i;
        if (whitespace(cell.original)) continue;
        if (cell.original == BidiClass.S || cell.original == BidiClass.B)
            foreach (j; resetStart .. i + 1)
                if (levels[j] != bidiRemovedLevel) levels[j] = paragraph.baseLevel;
        resetStart = i + 1;
    }
    foreach (j; resetStart .. n)
        if (levels[j] != bidiRemovedLevel) levels[j] = paragraph.baseLevel;
    auto map = workspace.visualToLogical[0 .. visible];
    uint highest = 0, lowestOdd = 127;
    foreach (index; map)
    {
        const level = levels[index - start];
        highest = maxLevel(highest, level);
        if ((level & 1) && level < lowestOdd) lowestOdd = level;
    }
    for (uint level = highest; level >= lowestOdd; --level)
    {
        for (size_t p = 0; p < map.length; )
        {
            if (levels[map[p] - start] < level) { ++p; continue; }
            const first = p;
            while (p < map.length && levels[map[p] - start] >= level) ++p;
            reverseMap(map[first .. p]);
        }
    }
    foreach (position, logical; map) inverse[logical - start] = position;
    result.outcome = UnicodeResult(status: UnicodeStatus.ok, written: n, required: n);
    result.line = BidiLine(start, end, workspace.levels[0 .. n],
        workspace.logicalToVisual[0 .. n], workspace.visualToLogical[0 .. map.length]);
    return result;
}

@("text.bidi.isolatesControlsAndSelectedLines")
@safe pure nothrow @nogc unittest
{
    UtfToken[7] input;
    const dchar[7] scalars = ['a', 0x2067, 0x05D0, 0x2069, 0x202B, ' ', 'b'];
    foreach (i, cp; scalars) input[i] = UtfToken(scalar: cp, start: 10 + i, end: 11 + i);
    const original = input;
    BidiCell[7] cells;
    size_t[7] sequence, visual;
    BidiWorkspace workspace = BidiWorkspace(cells[], sequence[], visual[]);
    auto paragraph = resolveBidiParagraph(input[], BidiDirection.automatic, workspace);
    assert(paragraph.outcome.status == UnicodeStatus.ok);
    assert(paragraph.paragraph.baseLevel == 0);
    assert(input == original);
    assert(cells[2].level == 1 && cells[6].level == 2);
    assert(cells[4].level == bidiRemovedLevel);
    assert(cells[4].logicalToVisual == bidiNoPosition);
    assert(paragraph.paragraph.visualToLogical == [0, 1, 2, 3, 6, 5]);
    ubyte[3] levels;
    size_t[3] inverse, lineVisual;
    BidiLineWorkspace lineWorkspace = BidiLineWorkspace(levels[], inverse[], lineVisual[]);
    auto line = resolveBidiLine(paragraph.paragraph, 3, 6, lineWorkspace);
    assert(line.outcome.status == UnicodeStatus.ok);
    assert(line.line.levels == [0, bidiRemovedLevel, 0]);
    assert(line.line.visualToLogical == [3, 5]);
    assert(line.line.logicalToVisual == [0, bidiNoPosition, 1]);
    assert(cells[5].level == 1); // A selected-line L1 reset is not paragraph mutation.
}

@("text.bidi.bracketsCanonicalEquivalenceAndMarks")
@safe pure nothrow @nogc unittest
{
    UtfToken[5] input;
    const dchar[5] scalars = [0x05D0, 0x2329, 0x05D1, 0x3009, 0x0300];
    foreach (i, cp; scalars) input[i] = UtfToken(scalar: cp, start: i, end: i + 1);
    BidiCell[5] cells;
    size_t[5] sequence, visual;
    BidiWorkspace workspace = BidiWorkspace(cells[], sequence[], visual[]);
    auto result = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(result.outcome.status == UnicodeStatus.ok);
    foreach (cell; result.paragraph.cells) assert(cell.level == 1);
    assert(result.paragraph.visualToLogical == [4, 3, 2, 1, 0]);
}

@("text.bidi.errorsCapacitiesAndEmpty")
@safe pure nothrow @nogc unittest
{
    UtfToken[2] input = [UtfToken(scalar: 'a', start: 4, end: 5),
        UtfToken(kind: UtfTokenKind.opaqueByte, byteValue: 0xFF, start: 5, end: 6)];
    BidiCell[2] cells;
    size_t[2] sequence, visual;
    BidiWorkspace workspace = BidiWorkspace(cells[], sequence[], visual[]);
    auto bad = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(bad.outcome.status == UnicodeStatus.invalidInput);
    assert(bad.outcome.blocking == UnicodeSourceSpan(5, 6));
    assert(bad.outcome.written == 0 && bad.paragraph.source.length == 0);
    input[1] = UtfToken(scalar: 0x05D0, start: 5, end: 6);
    workspace.sequence = sequence[0 .. 1];
    auto full = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(full.outcome.status == UnicodeStatus.workspaceFull);
    assert(full.outcome.required == 2 && full.outcome.blocking == UnicodeSourceSpan(5, 6));
    assert(full.paragraph.source.length == 0);
    workspace.sequence = sequence[];
    auto paragraph = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    BidiLineWorkspace lineWorkspace;
    auto lineFull = resolveBidiLine(paragraph.paragraph, 0, 2, lineWorkspace);
    assert(lineFull.outcome.status == UnicodeStatus.workspaceFull && lineFull.outcome.required == 2);
    assert(lineFull.line.levels.length == 0);
    auto invalidRange = resolveBidiLine(paragraph.paragraph, 2, 1, lineWorkspace);
    assert(invalidRange.outcome.status == UnicodeStatus.invalidOptions);
    auto badDirection = resolveBidiParagraph(input[], cast(BidiDirection) 99, workspace);
    assert(badDirection.outcome.status == UnicodeStatus.invalidOptions);
    BidiWorkspace emptyWorkspace;
    auto empty = resolveBidiParagraph(null, BidiDirection.rtl, emptyWorkspace);
    assert(empty.outcome.status == UnicodeStatus.ok && empty.paragraph.baseLevel == 1);
    auto emptyLine = resolveBidiLine(empty.paragraph, 0, 0, lineWorkspace);
    assert(emptyLine.outcome.status == UnicodeStatus.ok && emptyLine.line.visualToLogical.length == 0);
    workspace.visualToLogical = sequence[];
    auto overlap = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(overlap.outcome.status == UnicodeStatus.overlap && overlap.outcome.written == 0);
}

@("text.bidi.normativeOverflowCounters")
@safe pure nothrow @nogc unittest
{
    UtfToken[263] input;
    foreach (i; 0 .. 130) input[i] = UtfToken(scalar: 0x2067, start: i, end: i + 1);
    input[130] = UtfToken(scalar: 'a', start: 130, end: 131);
    foreach (i; 131 .. 261) input[i] = UtfToken(scalar: 0x2069, start: i, end: i + 1);
    input[261] = UtfToken(scalar: 0x202C, start: 261, end: 262);
    input[262] = UtfToken(scalar: 'b', start: 262, end: 263);
    BidiCell[263] cells;
    size_t[263] sequence, visual;
    BidiWorkspace workspace = BidiWorkspace(cells[], sequence[], visual[]);
    auto result = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(result.outcome.status == UnicodeStatus.ok);
    assert(cells[130].level == 126); // max_depth 125 plus I2, not storage failure.
    assert(cells[262].level == 0); // Overflow isolates and valid isolates all unwind.
    assert(cells[261].level == bidiRemovedLevel && cells[261].logicalToVisual == bidiNoPosition);
    foreach (cell; cells) assert(cell.level == bidiRemovedLevel || cell.level <= 126);
}

@("text.bidi.bd16OverflowDiscardsAllPairs")
@safe pure nothrow @nogc unittest
{
    // First pair would resolve to R by N0; the later 64 nested openings require
    // BD16 to discard that earlier pair as well, leaving N1/N2 to resolve it.
    UtfToken[135] input;
    const dchar[7] prefix = [0x05D0, '(', 0x05D1, ')', 'a', ' ', 'a'];
    foreach (i, cp; prefix) input[i] = UtfToken(scalar: cp, start: i, end: i + 1);
    foreach (i; 7 .. 71) input[i] = UtfToken(scalar: '(', start: i, end: i + 1);
    foreach (i; 71 .. 135) input[i] = UtfToken(scalar: ')', start: i, end: i + 1);
    BidiCell[135] cells;
    size_t[135] sequence, visual;
    BidiWorkspace workspace = BidiWorkspace(cells[], sequence[], visual[]);
    auto result = resolveBidiParagraph(input[], BidiDirection.ltr, workspace);
    assert(result.outcome.status == UnicodeStatus.ok);
    assert(cells[1].level == 1); // R ON R: N1.
    assert(cells[3].level == 0); // R ON L: N2, not paired with the opener.
}
