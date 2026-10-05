/**
Unicode 18 default line opportunities (UAX #14 revision 57).

The implementation follows https://www.unicode.org/reports/tr14/tr14-57.html
in normative rule order, without language tailoring, width selection, shaping,
or hyphen insertion. LB9's ignored characters are represented by caller-owned
links, so arbitrarily long combining, space, numeric, and RI contexts take
linear work rather than repeated backwards scans. Opaque bytes are hard barriers.
*/
module sparkles.base.text.line_break;

import sparkles.base.text.utf : UtfToken, UtfTokenKind, utfStorageOverlaps;
import sparkles.base.text.unicode_algorithm : UnicodeStatus, UnicodeResult,
    UnicodeSourceSpan, UnicodeBoundary, UnicodeBoundaryKind, validUnicodeToken;
import sparkles.base.text.unicode_tables : LineBreakClass, lineBreakClass,
    GeneralCategory, generalCategory, EastAsianWidthClass, eastAsianWidthClass,
    UnicodeProperty, unicodeProperty;

@safe pure nothrow @nogc:

/** Caller scratch, one entry per input token. Contents are unspecified after a call. */
struct LineBreakWorkspaceEntry
{
    private size_t base;
    private size_t previous;
    private size_t next;
    private size_t nonSpace;
    private LineBreakClass raw;
    private LineBreakClass resolved;
    private GeneralCategory category;
    private bool eastAsian;
    private bool potentialEmoji;
    private bool dotted;
    private bool opaque;
    private bool numeric;
    private bool regionalOdd;
}

/**
Publish all `input.length + 1` logical positions, including prohibited ones.

`workspace` needs exactly `input.length` entries; `output` needs exactly
`input.length + 1` entries. `required` counts entries in the exhausted storage
(`workspaceFull` or `outputFull`), or output entries on success. Failure always
has `written == 0` and leaves output untouched. Scratch may be overwritten.
All three supplied storage slices must be disjoint, including unused capacity.
Input spans must be individually valid and ordered without overlap. Offsets are
`input[0].start` at the start and the preceding token's `end` thereafter; empty
input has the sole mandatory end position at offset zero. Interior positions
adjoining opaque bytes are mandatory and reset all Unicode context.
*/
UnicodeResult lineOpportunities(scope const(UtfToken)[] input,
    scope UnicodeBoundary[] output, scope LineBreakWorkspaceEntry[] workspace)
{
    if (input.length == size_t.max)
        return UnicodeResult(UnicodeStatus.overflow);
    const required = input.length + 1;
    if (utfStorageOverlaps(input, output) || utfStorageOverlaps(input, workspace)
        || utfStorageOverlaps(workspace, output))
        return UnicodeResult(UnicodeStatus.overlap);
    foreach (i, ref const token; input)
    {
        if ((token.kind != UtfTokenKind.scalar && token.kind != UtfTokenKind.replacement
                && token.kind != UtfTokenKind.opaqueByte)
            || !validUnicodeToken(token) || (i && token.start < input[i - 1].end))
            return UnicodeResult(UnicodeStatus.invalidInput, 0, 0,
                UnicodeSourceSpan(token.start, token.end));
    }
    if (workspace.length < input.length)
        return UnicodeResult(UnicodeStatus.workspaceFull, 0, input.length,
            UnicodeSourceSpan(input[workspace.length].start, input[workspace.length].end));
    if (output.length < required)
    {
        const index = output.length;
        const offset = index == 0 ? (input.length ? input[0].start : 0)
            : input[index - 1].end;
        return UnicodeResult(UnicodeStatus.outputFull, 0, required,
            UnicodeSourceSpan(offset, offset));
    }

    auto entries = workspace[0 .. input.length];
    precompute(input, entries);
    foreach (i; 0 .. required)
    {
        const offset = i == 0 ? (input.length ? input[0].start : 0) : input[i - 1].end;
        const kind = i == input.length ? UnicodeBoundaryKind.mandatory
            : i == 0 ? UnicodeBoundaryKind.prohibited : opportunity(entries, i);
        output[i] = UnicodeBoundary(i, offset, kind);
    }
    return UnicodeResult(UnicodeStatus.ok, required, required);
}

private alias L = LineBreakClass;
private alias K = UnicodeBoundaryKind;
private enum absent = size_t.max;

private bool hard(L value)
{
    return value == L.BK || value == L.CR || value == L.LF || value == L.NL;
}

private bool alphabetic(L value) { return value == L.AL || value == L.HL; }
private bool affix(L value) { return value == L.PR || value == L.PO; }
private bool ideographic(L value) { return value == L.ID || value == L.EB || value == L.EM; }
private bool hangul(L value)
{
    return value == L.JL || value == L.JV || value == L.JT || value == L.H2 || value == L.H3;
}
private bool aksara(scope const(LineBreakWorkspaceEntry)* entry)
{
    return entry.resolved == L.AK || entry.resolved == L.AS || entry.dotted;
}
private bool hyphen(L value) { return value == L.HY || value == L.HH; }
private bool initialContext(L value)
{
    return hard(value) || value == L.OP || value == L.QU || value == L.GL
        || value == L.SP || value == L.ZW;
}
private bool finalContext(L value)
{
    return hard(value) || value == L.SP || value == L.GL || value == L.WJ
        || value == L.CL || value == L.QU || value == L.CP || value == L.EX
        || value == L.IS || value == L.SY || value == L.ZW;
}
private bool wordInitialContext(L value)
{
    return hard(value) || value == L.SP || value == L.ZW || value == L.CB || value == L.GL;
}

private void precompute(scope const(UtfToken)[] input, scope LineBreakWorkspaceEntry[] entries)
{
    size_t previous = absent;
    foreach (i, ref entry; entries)
    {
        entry = LineBreakWorkspaceEntry.init;
        entry.base = i;
        entry.previous = previous;
        entry.next = absent;
        entry.nonSpace = i;
        entry.opaque = input[i].kind == UtfTokenKind.opaqueByte;
        if (entry.opaque)
        {
            entry.raw = entry.resolved = L.BK;
            previous = i;
            continue;
        }
        const cp = input[i].scalar;
        entry.raw = lineBreakClass(cp);
        entry.resolved = entry.raw;
        entry.category = generalCategory(cp);
        const width = eastAsianWidthClass(cp);
        entry.eastAsian = width == EastAsianWidthClass.F || width == EastAsianWidthClass.W
            || width == EastAsianWidthClass.H;
        entry.potentialEmoji = entry.category == GeneralCategory.Cn
            && unicodeProperty(cp, UnicodeProperty.ExtPict);
        entry.dotted = cp == 0x25CC;
        // LB1 default resolution. CB remains unresolved until LB20.
        if (entry.raw == L.AI || entry.raw == L.SG || entry.raw == L.XX)
            entry.resolved = L.AL;
        else if (entry.raw == L.CJ)
            entry.resolved = L.NS;
        else if (entry.raw == L.SA)
            entry.resolved = entry.category == GeneralCategory.Mn || entry.category == GeneralCategory.Mc
                ? L.CM : L.AL;
        if (entry.resolved == L.CM || entry.resolved == L.ZWJ)
        {
            if (previous != absent && !entries[previous].opaque
                && !hard(entries[previous].resolved) && entries[previous].resolved != L.SP
                && entries[previous].resolved != L.ZW)
            {
                // LB9: only raw class and base link are used on ignored entries.
                entry.base = previous;
                continue;
            }
            // LB10 changes *all* properties to those of LATIN CAPITAL LETTER A.
            entry.resolved = L.AL;
            entry.category = GeneralCategory.Lu;
            entry.eastAsian = entry.potentialEmoji = entry.dotted = false;
        }
        if (previous != absent)
            entries[previous].next = i;
        if (entry.resolved == L.SP)
            entry.nonSpace = previous == absent ? absent : entries[previous].nonSpace;
        entry.numeric = entry.resolved == L.NU || (previous != absent
            && (entry.resolved == L.SY || entry.resolved == L.IS) && entries[previous].numeric);
        entry.regionalOdd = entry.resolved == L.RI
            && (previous == absent || entries[previous].resolved != L.RI || !entries[previous].regionalOdd);
        previous = i;
    }
}

private K opportunity(scope const(LineBreakWorkspaceEntry)[] entries, size_t index)
{
    const immediateLeft = &entries[index - 1];
    const immediateRight = &entries[index];
    // Lossless malformed units are outside the Unicode algorithm.
    if (immediateLeft.opaque || immediateRight.opaque) return K.mandatory;
    const leftIndex = immediateLeft.base;
    const left = &entries[leftIndex];
    const right = immediateRight;
    const a = left.resolved;
    const b = right.resolved;
    // LB4–LB7 precede combining inheritance.
    if (a == L.BK) return K.mandatory;
    if (a == L.CR && right.raw == L.LF) return K.prohibited;
    if (a == L.CR || a == L.LF || a == L.NL) return K.mandatory;
    if (hard(right.raw)) return K.prohibited;
    if (right.raw == L.SP || right.raw == L.ZW) return K.prohibited;
    const nonSpace = left.nonSpace;
    if (nonSpace != absent && entries[nonSpace].resolved == L.ZW) return K.allowed; // LB8
    if (immediateLeft.raw == L.ZWJ) return K.prohibited; // LB8a
    if (right.base != index) return K.prohibited; // LB9
    if (a == L.WJ || b == L.WJ) return K.prohibited; // LB11
    if (a == L.GL) return K.prohibited; // LB12
    if (b == L.GL && a != L.SP && !hyphen(a)) return K.prohibited; // LB12a
    if (b == L.CL || b == L.CP || b == L.EX || b == L.SY) return K.prohibited; // LB13
    if (nonSpace != absent && entries[nonSpace].resolved == L.OP) return K.prohibited; // LB14
    if (nonSpace != absent)
    {
        const beforeSpaces = &entries[nonSpace];
        if (beforeSpaces.resolved == L.QU && beforeSpaces.category == GeneralCategory.Pi
            && (beforeSpaces.previous == absent || entries[beforeSpaces.previous].opaque
                || initialContext(entries[beforeSpaces.previous].resolved)))
            return K.prohibited; // LB15a
    }
    const next = right.next;
    if (b == L.QU && right.category == GeneralCategory.Pf
        && (next == absent || entries[next].opaque || finalContext(entries[next].resolved)))
        return K.prohibited; // LB15b
    if (a == L.SP && b == L.IS && next != absent && entries[next].resolved == L.NU)
        return K.allowed; // LB15c
    if (b == L.IS) return K.prohibited; // LB15d
    if (b == L.NS && nonSpace != absent
        && (entries[nonSpace].resolved == L.CL || entries[nonSpace].resolved == L.CP))
        return K.prohibited; // LB16
    if (b == L.B2 && nonSpace != absent && entries[nonSpace].resolved == L.B2)
        return K.prohibited; // LB17
    if (a == L.SP) return K.allowed; // LB18
    if ((b == L.QU && right.category != GeneralCategory.Pi)
        || (a == L.QU && left.category != GeneralCategory.Pf)) return K.prohibited; // LB19
    if ((b == L.QU && (!left.eastAsian || next == absent || !entries[next].eastAsian))
        || (a == L.QU && (!right.eastAsian || left.previous == absent
            || !entries[left.previous].eastAsian))) return K.prohibited; // LB19a
    if (a == L.CB || b == L.CB) return K.allowed; // LB20
    const previous = left.previous;
    if (hyphen(a) && alphabetic(b)
        && (previous == absent || entries[previous].opaque
            || wordInitialContext(entries[previous].resolved))) return K.prohibited; // LB20a
    if (b == L.BA || hyphen(b) || b == L.NS || a == L.BB) return K.prohibited; // LB21
    if (hyphen(a) && b != L.HL && previous != absent && entries[previous].resolved == L.HL)
        return K.prohibited; // LB21a
    if (a == L.SY && b == L.HL) return K.prohibited; // LB21b
    if (b == L.IN) return K.prohibited; // LB22
    if ((alphabetic(a) && b == L.NU) || (a == L.NU && alphabetic(b))) return K.prohibited; // LB23
    if ((a == L.PR && ideographic(b)) || (ideographic(a) && b == L.PO)) return K.prohibited; // LB23a
    if ((affix(a) && alphabetic(b)) || (alphabetic(a) && affix(b))) return K.prohibited; // LB24
    // LB25: linear precomputed suffix state and at most two significant lookaheads.
    if (affix(b) && (left.numeric || ((a == L.CL || a == L.CP)
        && previous != absent && entries[previous].numeric))) return K.prohibited;
    if (affix(a) && b == L.OP && next != absent)
    {
        const after = entries[next].next;
        if (entries[next].resolved == L.NU || (entries[next].resolved == L.IS
            && after != absent && entries[after].resolved == L.NU)) return K.prohibited;
    }
    if (b == L.NU && (affix(a) || a == L.HY || a == L.IS || left.numeric)) return K.prohibited;
    if ((a == L.JL && (b == L.JL || b == L.JV || b == L.H2 || b == L.H3))
        || ((a == L.JV || a == L.H2) && (b == L.JV || b == L.JT))
        || ((a == L.JT || a == L.H3) && b == L.JT)) return K.prohibited; // LB26
    if ((hangul(a) && b == L.PO) || (a == L.PR && hangul(b))) return K.prohibited; // LB27
    if (alphabetic(a) && alphabetic(b)) return K.prohibited; // LB28
    if ((a == L.AP && aksara(right)) || (aksara(left) && (b == L.VF || b == L.VI))
        || (a == L.VI && previous != absent && aksara(&entries[previous])
            && (b == L.AK || right.dotted))
        || (aksara(left) && aksara(right) && next != absent && entries[next].resolved == L.VF))
        return K.prohibited; // LB28a
    if (a == L.IS && alphabetic(b)) return K.prohibited; // LB29
    if (((alphabetic(a) || a == L.NU) && b == L.OP && !right.eastAsian)
        || (a == L.CP && !left.eastAsian && (alphabetic(b) || b == L.NU)))
        return K.prohibited; // LB30
    if (a == L.RI && b == L.RI && left.regionalOdd) return K.prohibited; // LB30a
    if ((a == L.EB || left.potentialEmoji) && b == L.EM) return K.prohibited; // LB30b
    return K.allowed; // LB31
}

version (unittest)
{
    private void checkLine(in dchar[] scalars, in K[] expected)
    {
        enum capacity = 16;
        assert(scalars.length <= capacity && expected.length == scalars.length + 1);
        const N = scalars.length;
        UtfToken[capacity] input;
        LineBreakWorkspaceEntry[capacity] workspace;
        UnicodeBoundary[capacity + 1] output;
        foreach (i, cp; scalars)
            input[i] = UtfToken(scalar: cp, start: 7 + i * 2, end: 9 + i * 2);
        const result = lineOpportunities(input[0 .. N], output[0 .. N + 1], workspace[0 .. N]);
        assert(result.succeeded() && result.written == N + 1);
        foreach (i, boundary; output[0 .. N + 1])
        {
            assert(boundary.kind == expected[i]);
            assert(boundary.index == i && boundary.offset == 7 + i * 2);
        }
    }
}

@("text.lineBreak.hardAndCombiningPrecedence")
unittest
{
    checkLine([cast(dchar)'a', '\r', '\n', 0x0308, 'b'],
        [K.prohibited, K.prohibited, K.prohibited, K.mandatory, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)0x200B, ' ', 0x2060, 'a'],
        [K.prohibited, K.prohibited, K.allowed, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)'(', 0x0308, ' ', 'a'],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.mandatory]);
}

@("text.lineBreak.numericAndHebrewContext")
unittest
{
    checkLine([cast(dchar)'$', '(', '.', 0x0308, '5', ')', '%'],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.prohibited,
            K.prohibited, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)'a', ' ', '.', '5'],
        [K.prohibited, K.prohibited, K.allowed, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)0x05D0, '-', 'a', ' ', '-', 'b'],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.allowed, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)0x05D0, '-', 0x05D1],
        [K.prohibited, K.prohibited, K.allowed, K.mandatory]);
}

@("text.lineBreak.eastAsianQuotesAndOrthographicSyllables")
unittest
{
    checkLine([cast(dchar)0x4E00, 0x201C, 0x4E01, 0x201D, 0x4E02],
        [K.prohibited, K.allowed, K.prohibited, K.prohibited, K.allowed, K.mandatory]);
    checkLine([cast(dchar)0x1B05, 0x1B44, 0x0308, 0x1B05],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)0x1F1E6, 0x0308, 0x1F1E7, 0x1F1E8, 0x1F1E9],
        [K.prohibited, K.prohibited, K.prohibited, K.allowed, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)0x1F466, 0x0308, 0x1F3FB],
        [K.prohibited, K.prohibited, K.prohibited, K.mandatory]);
}

@("text.lineBreak.capacityAndOpaqueBarriers")
unittest
{
    UtfToken[3] input = [UtfToken(scalar: 'a', start: 10, end: 11),
        UtfToken(kind: UtfTokenKind.opaqueByte, byteValue: 0xFF, start: 11, end: 12),
        UtfToken(scalar: 0x0308, start: 12, end: 13)];
    LineBreakWorkspaceEntry[3] workspace;
    UnicodeBoundary[4] output;
    output[] = UnicodeBoundary(99, 99, K.allowed);
    auto result = lineOpportunities(input[], output[], workspace[0 .. 2]);
    assert(result.status == UnicodeStatus.workspaceFull && result.required == 3 && result.written == 0);
    assert(output[0].index == 99 && output[3].index == 99);
    result = lineOpportunities(input[], output[0 .. 3], workspace[]);
    assert(result.status == UnicodeStatus.outputFull && result.required == 4 && result.written == 0);
    assert(output[0].index == 99 && output[3].index == 99);
    result = lineOpportunities(input[], output[], workspace[]);
    assert(result.succeeded());
    assert(output[0].kind == K.prohibited && output[1].kind == K.mandatory
        && output[2].kind == K.mandatory && output[3].kind == K.mandatory);
    input[2].scalar = cast(dchar)0xD800;
    output[] = UnicodeBoundary(99, 99, K.allowed);
    result = lineOpportunities(input[], output[], workspace[]);
    assert(result.status == UnicodeStatus.invalidInput && result.blocking.start == 12 && result.written == 0);
    assert(output[0].index == 99 && output[3].index == 99);
    result = lineOpportunities(null, output[0 .. 1], null);
    assert(result.succeeded() && output[0] == UnicodeBoundary(0, 0, K.mandatory));
}

@("text.lineBreak.defaultResolutionAndUnicode18Hyphens")
unittest
{
    checkLine([cast(dchar)0x4E00, 0x0E31, 0x4E01],
        [K.prohibited, K.prohibited, K.allowed, K.mandatory]);
    checkLine([cast(dchar)0x11003, 0x25CC, 0x1B05, 0x1BF2],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)'a', 0x2013, 0x00A0, 'b'],
        [K.prohibited, K.prohibited, K.prohibited, K.prohibited, K.mandatory]);
    checkLine([cast(dchar)'a', 0x00AD, 0x00A0, 'b'],
        [K.prohibited, K.prohibited, K.allowed, K.prohibited, K.mandatory]);
}

@("text.lineBreak.storageOverlap")
@system
unittest
{
    union AliasedStorage
    {
        UtfToken[2] input;
        UnicodeBoundary[3] output;
        LineBreakWorkspaceEntry[2] workspace;
    }
    AliasedStorage storage;
    LineBreakWorkspaceEntry[2] scratch;
    UnicodeBoundary[3] output;
    storage.input[0] = UtfToken(scalar: 'a', start: 0, end: 1);
    storage.input[1] = UtfToken(scalar: 'b', start: 1, end: 2);
    assert(lineOpportunities(storage.input[], storage.output[], scratch[]).status == UnicodeStatus.overlap);
    assert(lineOpportunities(storage.input[], output[], storage.workspace[]).status == UnicodeStatus.overlap);
    UtfToken[2] input = storage.input;
    assert(lineOpportunities(input[], storage.output[], storage.workspace[]).status == UnicodeStatus.overlap);
}
