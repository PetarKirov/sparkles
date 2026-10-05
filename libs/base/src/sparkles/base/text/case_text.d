/** Allocating UTF-8 casing conveniences over the owned Unicode algorithms.
 * Unicode operations use the root locale and reject malformed UTF-8 before
 * returning any text or comparison result. ASCII helpers operate on code units
 * and preserve all bytes outside the ASCII alphabet, including malformed UTF-8.
 */
module sparkles.base.text.case_text;

import sparkles.base.text.casing : caseTransform, UnicodeCaseMode,
    UnicodeCasingScratch, unicodeSimpleFold;
import sparkles.base.text.transform : UnicodeTransformUnit,
    UnicodeTransformWorkspace, UnicodeTransformEpoch, decodeTransformText;
import sparkles.base.text.unicode_algorithm : UnicodeResult, UnicodeStatus,
    UnicodeSourceSpan, UnicodeBoundary;
import sparkles.base.text.boundaries : WordBoundaryWorkspace;
import sparkles.base.text.utf : UtfMode, UtfStatus, UtfResult, UtfToken,
    decodeToken, encodeScalar, scalarUnits, addUtfCount;

/// Failure details are owned values; no partial output or borrowed input escapes.
class UnicodeCaseTextException : Exception
{
    /// UTF failure, including its original byte offset and reason.
    immutable UtfResult utfResult;
    /// Algorithm failure; `utfResult.status == ok` distinguishes this variant.
    immutable UnicodeResult unicodeResult;

    this(UtfResult result) @safe pure nothrow
    {
        super("Malformed UTF-8 in Unicode casing or comparison");
        utfResult = result;
        unicodeResult = UnicodeResult.init;
    }

    this(UnicodeResult result) @safe pure nothrow
    {
        super("Owned Unicode casing failed");
        unicodeResult = result;
        utfResult = UtfResult.init;
    }
}

/// Full root lowercase, including expansions and contextual final sigma.
string unicodeLower(scope const(char)[] source) @safe pure
    => transformText(source, UnicodeCaseMode.lower);
/// Full root uppercase, including multi-scalar expansions.
string unicodeUpper(scope const(char)[] source) @safe pure
    => transformText(source, UnicodeCaseMode.upper);
/// Full root titlecase, segmented by owned Unicode word boundaries.
string unicodeTitle(scope const(char)[] source) @safe pure
    => transformText(source, UnicodeCaseMode.title);
/// Full default (non-Turkic) case folding; not normalization.
string unicodeFold(scope const(char)[] source) @safe pure
    => transformText(source, UnicodeCaseMode.fullFold);

/** Lexicographic comparison of simple-folded Unicode scalars, returning -1, 0,
 * or 1. Unlike full folding, this preserves one scalar per input scalar:
 * `ß` and `ss` are unequal. Both complete inputs are strictly validated even
 * when their first scalars already differ. No allocation occurs on success.
 */
int unicodeCaselessCompare(scope const(char)[] left, scope const(char)[] right)
    @safe pure
{
    size_t l, r;
    int comparison;
    while (l < left.length || r < right.length)
    {
        const hasLeft = l < left.length;
        const hasRight = r < right.length;
        dchar av, bv;
        if (hasLeft)
        {
            const a = decodeToken(left[l .. $], UtfMode.strict, true, l);
            if (a.result.status != UtfStatus.ok)
                throw new UnicodeCaseTextException(a.result);
            if (!comparison) av = unicodeSimpleFold(a.token.scalar);
            l = a.token.end;
        }
        if (hasRight)
        {
            const b = decodeToken(right[r .. $], UtfMode.strict, true, r);
            if (b.result.status != UtfStatus.ok)
                throw new UnicodeCaseTextException(b.result);
            if (!comparison) bv = unicodeSimpleFold(b.token.scalar);
            r = b.token.end;
        }
        if (!comparison)
        {
            if (!hasLeft || !hasRight) comparison = hasLeft ? 1 : -1;
            else if (av != bv) comparison = av < bv ? -1 : 1;
        }
    }
    return comparison;
}

/// ASCII-only lowercase for command grammar, extensions and byte identifiers.
string asciiLower(scope const(char)[] source) @safe pure nothrow
{
    import std.ascii : toLower;
    auto result = new char[source.length];
    foreach (i; 0 .. source.length) result[i] = toLower(source[i]);
    // The fresh allocation has no other surviving mutable alias.
    return (() @trusted pure nothrow => cast(string) result)();
}

/// ASCII-only uppercase; non-ASCII bytes are preserved without decoding.
string asciiUpper(scope const(char)[] source) @safe pure nothrow
{
    import std.ascii : toUpper;
    auto result = new char[source.length];
    foreach (i; 0 .. source.length) result[i] = toUpper(source[i]);
    return (() @trusted pure nothrow => cast(string) result)();
}

/** Lexicographic ASCII-caseless byte comparison, returning -1, 0, or 1.
 * Non-ASCII bytes are compared unchanged; arbitrary byte strings are accepted.
 */
int asciiCaselessCompare(scope const(char)[] left, scope const(char)[] right)
    @safe pure nothrow @nogc
{
    import std.ascii : toLower;
    const common = left.length < right.length ? left.length : right.length;
    foreach (i; 0 .. common)
    {
        const a = cast(ubyte) toLower(left[i]);
        const b = cast(ubyte) toLower(right[i]);
        if (a != b) return a < b ? -1 : 1;
    }
    return left.length < right.length ? -1 : left.length > right.length ? 1 : 0;
}

@("text.caseText.asciiCaselessByteOrdering")
@safe pure nothrow @nogc
unittest
{
    assert(asciiCaselessCompare("ClAuDe", "claude") == 0);
    assert(asciiCaselessCompare("a", "AB") < 0);
    assert(asciiCaselessCompare("AB", "a") > 0);
    assert(asciiCaselessCompare("A\xFF", "a\xFF") == 0);
    assert(asciiCaselessCompare("\xFF", "\x80") > 0);
    assert(asciiCaselessCompare("İ", "i") != 0);
}

private size_t validateText(scope const(char)[] source) @safe pure
{
    size_t offset, count;
    while (offset < source.length)
    {
        const decoded = decodeToken(source[offset .. $], UtfMode.strict, true, offset);
        if (decoded.result.status != UtfStatus.ok)
            throw new UnicodeCaseTextException(decoded.result);
        offset = decoded.token.end;
        ++count;
    }
    return count;
}

private string transformText(scope const(char)[] source, UnicodeCaseMode mode)
    @safe pure
{
    const n = validateText(source);
    if (!n) return "";
    if (n == size_t.max)
        throw new UnicodeCaseTextException(UnicodeResult(status: UnicodeStatus.overflow));
    auto input = UnicodeTransformWorkspace(units: new UnicodeTransformUnit[n],
        spans: new UnicodeSourceSpan[n], epoch: new UnicodeTransformEpoch[1]);
    auto result = decodeTransformText(source, UtfMode.strict, input);
    if (!result.succeeded()) throw new UnicodeCaseTextException(result);
    auto scratch = UnicodeCasingScratch(contexts: new ubyte[n],
        boundaryMap: new size_t[n + 1]);
    if (mode == UnicodeCaseMode.title)
    {
        scratch.tokens = new UtfToken[n];
        scratch.words = new UnicodeBoundary[n + 1];
        scratch.wordWorkspace = new WordBoundaryWorkspace[n];
    }
    // Root mappings never delete input. Each decoded unit has exactly one
    // source span; expansions share that span rather than duplicating it.
    auto output = UnicodeTransformWorkspace(spans: new UnicodeSourceSpan[n],
        epoch: new UnicodeTransformEpoch[1]);
    result = caseTransform(input.output(), output, mode, scratch);
    if (result.status != UnicodeStatus.outputFull)
        throw new UnicodeCaseTextException(result);
    output.units = new UnicodeTransformUnit[result.required];
    result = caseTransform(input.output(), output, mode, scratch);
    if (!result.succeeded()) throw new UnicodeCaseTextException(result);
    const view = output.output();
    size_t bytes;
    foreach (unit; view.units)
        if (!addUtfCount(bytes, scalarUnits!char(unit.value)))
            throw new UnicodeCaseTextException(UnicodeResult(status: UnicodeStatus.overflow));
    auto text = new char[bytes];
    size_t offset;
    foreach (unit; view.units)
    {
        const encoded = encodeScalar(unit.value, text[offset .. $]);
        if (encoded.status != UtfStatus.ok)
            throw new UnicodeCaseTextException(encoded);
        offset += encoded.written;
    }
    return (() @trusted pure nothrow => cast(string) text)();
}

@("text.caseText.expansionContextAndTitle")
@safe pure
unittest
{
    assert(unicodeUpper("Straße ﬃ") == "STRASSE FFI");
    assert(unicodeLower("İ ΟΣ ΟΣΑ") == "i\u0307 ος οσα");
    assert(unicodeTitle("ßETA hELLO wORLD") == "Sseta Hello World");
    assert(unicodeFold("Straße ﬃ ς") == "strasse ffi σ");
    assert(unicodeLower("") == "");
}

@("text.caseText.strictMalformedAndComparison")
@safe pure
unittest
{
    assert(unicodeCaselessCompare("Σς", "σσ") == 0);
    assert(unicodeCaselessCompare("Straße", "STRASSE") != 0);
    assert(unicodeCaselessCompare("a", "AB") < 0);
    assert(unicodeCaselessCompare("B", "a") > 0);
    foreach (mode; [UnicodeCaseMode.lower, UnicodeCaseMode.upper,
        UnicodeCaseMode.title, UnicodeCaseMode.fullFold])
    {
        bool failed;
        try transformText("a\xFF", mode);
        catch (UnicodeCaseTextException e)
        {
            failed = true;
            assert(e.utfResult.status == UtfStatus.invalid && e.utfResult.offset == 1);
        }
        assert(failed);
    }
    foreach (right; [false, true])
    {
        bool failed;
        try unicodeCaselessCompare(right ? "a" : "z\xFF", right ? "z\xFF" : "a");
        catch (UnicodeCaseTextException e)
        {
            failed = true;
            assert(e.utfResult.offset == 1);
        }
        assert(failed);
    }
}

@("text.caseText.asciiPreservesBytes")
@safe pure nothrow
unittest
{
    assert(asciiLower("AbC İ\xFF") == "abc İ\xFF");
    assert(asciiUpper("aBc ß\xFF") == "ABC ß\xFF");
}
