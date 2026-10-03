/**
Bounded, allocation-free UTF-8/UTF-16 conversion for native platform APIs.

The ordinary functions preserve embedded NUL code points. The `z` variants
produce a trailing NUL and reject an embedded one, which makes the result safe
to pass to Win32 and other APIs that take a NUL-terminated UTF-16 string.

Every conversion validates and sizes the complete source before touching the
destination. On failure the destination is unchanged. A successful length
excludes the optional terminator.
*/
module sparkles.base.text.utf16;

import expected : Expected, err, ok;

import sparkles.base.text.errors : NoGcHook;
import sparkles.base.text.utf8 : utf8SequenceLength;

version (LDC)
    version (X86_64)
        version = textSimdX86;

version (textSimdX86)
{
    import sparkles.base.text.utf16_simd : asciiUtf8Prefix, asciiUtf16Prefix,
        widenAsciiUtf8, narrowAsciiUtf16, countUtf8Units, measureUtf16Prefix;
    import sparkles.base.text.utf16_emit : emitUtf8, emitUtf16, hasCompaction;
    import sparkles.base.text.utf8_simd : validatedUtf8Prefix;
}

@safe pure nothrow @nogc:

/// Machine-readable failure from a UTF conversion.
enum UtfConversionErrorCode
{
    invalidUtf8,       /// malformed UTF-8; `offset` is a byte offset
    invalidUtf16,      /// lone or mispaired surrogate; `offset` is a code-unit offset
    embeddedNul,       /// a `z` conversion found an embedded U+0000
    insufficientSpace,/// destination needs `required` code units/bytes
}

/// Structured UTF conversion failure.
struct UtfConversionError
{
    UtfConversionErrorCode code;
    size_t offset;
    /// Required destination capacity, including the terminator for `z` conversions.
    size_t required;
}

/// `Expected` result used by the bounded conversion functions.
alias UtfConversionResult(T) = Expected!(T, UtfConversionError, NoGcHook);

/**
Converts well-formed UTF-8 into UTF-16. Embedded NUL is preserved.

The returned count is the number of UTF-16 code units written.
*/
UtfConversionResult!size_t utf8ToUtf16(scope const(char)[] source,
    return scope wchar[] destination)
{
    return utf8ToUtf16Impl(source, destination, false);
}

/**
Converts UTF-8 into a NUL-terminated UTF-16 string.

Embedded NUL is rejected and the returned count excludes the terminator.
*/
UtfConversionResult!size_t utf8ToUtf16z(scope const(char)[] source,
    return scope wchar[] destination)
{
    return utf8ToUtf16Impl(source, destination, true);
}

/**
Converts well-formed UTF-16 into UTF-8. Embedded NUL is preserved.

The returned count is the number of UTF-8 bytes written.
*/
UtfConversionResult!size_t utf16ToUtf8(scope const(wchar)[] source,
    return scope char[] destination)
{
    return utf16ToUtf8Impl(source, destination, false);
}

/**
Converts UTF-16 into a NUL-terminated UTF-8 string.

Embedded NUL is rejected and the returned count excludes the terminator.
*/
UtfConversionResult!size_t utf16ToUtf8z(scope const(wchar)[] source,
    return scope char[] destination)
{
    return utf16ToUtf8Impl(source, destination, true);
}

private UtfConversionResult!size_t utf8ToUtf16Impl(
    scope const(char)[] source, return scope wchar[] destination, bool terminate)
{
    auto measured = measureUtf8(source, terminate);
    if (measured.hasError)
        return utfErr!size_t(measured.error);

    const payloadUnits = measured.value;
    const required = payloadUnits + cast(size_t) terminate;
    if (destination.length < required)
        return utfErr!size_t(UtfConversionError(
            UtfConversionErrorCode.insufficientSpace, source.length, required));

    size_t si;
    size_t di;
    while (si < source.length)
    {
        if (source[si] < 0x80)
        {
            version (textSimdX86)
            {
                if (!__ctfe && source.length - si >= 16)
                {
                    const count = widenAsciiUtf8(source[si .. $],
                        destination[di .. payloadUnits]);
                    si += count;
                    di += count;
                    continue;
                }
            }
            destination[di++] = cast(wchar) source[si++];
            continue;
        }
        version (textSimdX86)
        {
            if (!__ctfe && source.length - si >= 33 && hasCompaction())
            {
                const emitted = emitUtf8(source[si .. $], destination[di .. payloadUnits]);
                si += emitted.consumed;
                di += emitted.written;
                continue;
            }
        }
        // The preflight already validated every sequence.
        const len = source[si] < 0xE0 ? 2 : source[si] < 0xF0 ? 3 : 4;
        const scalar = decodeScalar(source, si, len);
        if (scalar < 0x1_0000)
        {
            destination[di++] = cast(wchar) scalar;
        }
        else
        {
            const supplementary = scalar - 0x1_0000;
            destination[di++] = cast(wchar)(0xD800 + (supplementary >> 10));
            destination[di++] = cast(wchar)(0xDC00 + (supplementary & 0x3FF));
        }
        si += len;
    }
    if (terminate)
        destination[di] = 0;
    return utfOk(di);
}

private UtfConversionResult!size_t utf16ToUtf8Impl(
    scope const(wchar)[] source, return scope char[] destination, bool terminate)
{
    auto measured = measureUtf16(source, terminate);
    if (measured.hasError)
        return utfErr!size_t(measured.error);

    const payloadBytes = measured.value;
    const required = payloadBytes + cast(size_t) terminate;
    if (destination.length < required)
        return utfErr!size_t(UtfConversionError(
            UtfConversionErrorCode.insufficientSpace, source.length, required));

    size_t si;
    size_t di;
    while (si < source.length)
    {
        dchar scalar = source[si];
        if (scalar < 0x80)
        {
            version (textSimdX86)
            {
                if (!__ctfe && source.length - si >= 16)
                {
                    const count = narrowAsciiUtf16(source[si .. $],
                        destination[di .. payloadBytes]);
                    si += count;
                    di += count;
                    continue;
                }
            }
            destination[di++] = cast(char) scalar;
            ++si;
            continue;
        }
        version (textSimdX86)
        {
            if (!__ctfe && source.length - si >= 17 && hasCompaction())
            {
                const emitted = emitUtf16(source[si .. $], destination[di .. payloadBytes]);
                si += emitted.consumed;
                di += emitted.written;
                continue;
            }
        }
        ++si;
        if (scalar >= 0xD800 && scalar <= 0xDBFF)
        {
            const low = source[si++];
            scalar = cast(dchar)(0x1_0000
                + ((scalar - 0xD800) << 10) + (low - 0xDC00));
        }
        if (scalar < 0x800)
        {
            destination[di++] = cast(char)(0xC0 | (scalar >> 6));
            destination[di++] = cast(char)(0x80 | (scalar & 0x3F));
        }
        else if (scalar < 0x1_0000)
        {
            destination[di++] = cast(char)(0xE0 | (scalar >> 12));
            destination[di++] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
            destination[di++] = cast(char)(0x80 | (scalar & 0x3F));
        }
        else
        {
            destination[di++] = cast(char)(0xF0 | (scalar >> 18));
            destination[di++] = cast(char)(0x80 | ((scalar >> 12) & 0x3F));
            destination[di++] = cast(char)(0x80 | ((scalar >> 6) & 0x3F));
            destination[di++] = cast(char)(0x80 | (scalar & 0x3F));
        }
    }
    if (terminate)
        destination[di] = 0;
    return utfOk(di);
}

private UtfConversionResult!size_t measureUtf8(
    scope const(char)[] source, bool rejectNul)
{
    size_t units;
    size_t i;
    version (textSimdX86)
    {
        if (!__ctfe && source.length >= 64)
        {
            if (source[0] < 0x80)
                i = units = asciiUtf8Prefix(source, rejectNul);
            if (source.length - i >= 64)
            {
                const valid = validatedUtf8Prefix(source[i .. $]);
                const counted = countUtf8Units(source[i .. i + valid], rejectNul);
                i += counted.consumed;
                units += counted.required;
            }
        }
    }
    while (i < source.length)
    {
        const lead = source[i];
        if (lead < 0x80)
        {
            if (lead == 0 && rejectNul)
                return utfErr!size_t(UtfConversionError(
                    UtfConversionErrorCode.embeddedNul, i, 0));
            ++i;
            ++units;
            continue;
        }
        const len = utf8SequenceLength(source, i);
        if (len == 0)
            return utfErr!size_t(UtfConversionError(
                UtfConversionErrorCode.invalidUtf8, i, 0));
        units += len == 4 ? 2 : 1;
        i += len;
    }
    return utfOk(units);
}

private UtfConversionResult!size_t measureUtf16(
    scope const(wchar)[] source, bool rejectNul)
{
    size_t bytes;
    size_t i;
    version (textSimdX86)
    {
        if (!__ctfe && source.length >= 16)
        {
            if (source[0] < 0x80)
                i = bytes = asciiUtf16Prefix(source, rejectNul);
            const measured = measureUtf16Prefix(source[i .. $], rejectNul);
            i += measured.consumed;
            bytes += measured.required;
        }
    }
    while (i < source.length)
    {
        const unit = source[i];
        if (unit < 0x80)
        {
            if (unit == 0 && rejectNul)
                return utfErr!size_t(UtfConversionError(
                    UtfConversionErrorCode.embeddedNul, i, 0));
            ++i;
            ++bytes;
            continue;
        }

        if (unit >= 0xD800 && unit <= 0xDBFF)
        {
            if (i + 1 == source.length
                || source[i + 1] < 0xDC00 || source[i + 1] > 0xDFFF)
                return utfErr!size_t(UtfConversionError(
                    UtfConversionErrorCode.invalidUtf16, i, 0));
            bytes += 4;
            i += 2;
            continue;
        }
        if (unit >= 0xDC00 && unit <= 0xDFFF)
            return utfErr!size_t(UtfConversionError(
                UtfConversionErrorCode.invalidUtf16, i, 0));

        bytes += unit < 0x800 ? 2 : 3;
        ++i;
    }
    return utfOk(bytes);
}

private dchar decodeScalar(scope const(char)[] source, size_t at, size_t len)
in (len >= 1 && len <= 4)
{
    const b0 = cast(ubyte) source[at];
    final switch (len)
    {
        case 1:
            return b0;
        case 2:
            return cast(dchar)(((b0 & 0x1F) << 6)
                | (cast(ubyte) source[at + 1] & 0x3F));
        case 3:
            return cast(dchar)(((b0 & 0x0F) << 12)
                | ((cast(ubyte) source[at + 1] & 0x3F) << 6)
                | (cast(ubyte) source[at + 2] & 0x3F));
        case 4:
            return cast(dchar)(((b0 & 0x07) << 18)
                | ((cast(ubyte) source[at + 1] & 0x3F) << 12)
                | ((cast(ubyte) source[at + 2] & 0x3F) << 6)
                | (cast(ubyte) source[at + 3] & 0x3F));
    }
}

private UtfConversionResult!T utfOk(T)(T value)
    => ok!(UtfConversionError, NoGcHook)(value);

private UtfConversionResult!T utfErr(T)(UtfConversionError error)
    => err!(T, NoGcHook)(error);

@("text.utf16.roundTripAllUtf8Widths")
unittest
{
    immutable source = "Aé€😀";
    wchar[5] wide;
    auto encoded = utf8ToUtf16(source, wide[]);
    assert(encoded.hasValue && encoded.value == 5);
    assert(wide == [cast(wchar) 0x41, cast(wchar) 0xE9,
        cast(wchar) 0x20AC, cast(wchar) 0xD83D, cast(wchar) 0xDE00]);

    char[source.length] bytes;
    auto decoded = utf16ToUtf8(wide[], bytes[]);
    assert(decoded.hasValue && decoded.value == source.length);
    assert(bytes[] == source);
}

@("text.utf16.zTerminatesAndRejectsEmbeddedNul")
unittest
{
    wchar[4] wide = 0xA5A5;
    auto encoded = utf8ToUtf16z("hi", wide[]);
    assert(encoded.hasValue && encoded.value == 2);
    assert(wide[0 .. 3] == [cast(wchar) 'h', cast(wchar) 'i', cast(wchar) 0]);

    const before = wide;
    auto embedded8 = utf8ToUtf16z("a\0b", wide[]);
    assert(embedded8.hasError);
    assert(embedded8.error.code == UtfConversionErrorCode.embeddedNul);
    assert(embedded8.error.offset == 1 && wide == before);

    char[4] bytes = cast(char) 0x5A;
    const wchar[3] source = ['a', 0, 'b'];
    auto embedded16 = utf16ToUtf8z(source[], bytes[]);
    assert(embedded16.hasError);
    assert(embedded16.error.code == UtfConversionErrorCode.embeddedNul);
    assert(embedded16.error.offset == 1);
}

@("text.utf16.ordinaryConversionPreservesNul")
unittest
{
    wchar[3] wide;
    assert(utf8ToUtf16("a\0b", wide[]).value == 3);
    assert(wide == [cast(wchar) 'a', cast(wchar) 0, cast(wchar) 'b']);

    char[3] bytes;
    assert(utf16ToUtf8(wide[], bytes[]).value == 3);
    assert(bytes[] == "a\0b");
}

@("text.utf16.errorsDoNotModifyDestination")
unittest
{
    wchar[4] wide = 0xA5A5;
    const wideBefore = wide;
    auto malformed8 = utf8ToUtf16("ok\xF0\x80", wide[]);
    assert(malformed8.hasError);
    assert(malformed8.error.code == UtfConversionErrorCode.invalidUtf8);
    assert(malformed8.error.offset == 2 && wide == wideBefore);

    char[8] bytes = cast(char) 0x5A;
    const bytesBefore = bytes;
    const wchar[2] malformed16 = [cast(wchar) 0xD800, cast(wchar) 'x'];
    auto decoded = utf16ToUtf8(malformed16[], bytes[]);
    assert(decoded.hasError);
    assert(decoded.error.code == UtfConversionErrorCode.invalidUtf16);
    assert(decoded.error.offset == 0 && bytes == bytesBefore);

    const wchar[1] loneLow = [cast(wchar) 0xDC00];
    assert(utf16ToUtf8(loneLow[], bytes[]).error.offset == 0);
}

@("text.utf16.capacityIncludesOptionalTerminator")
unittest
{
    wchar[2] tooShort;
    auto wide = utf8ToUtf16z("hi", tooShort[]);
    assert(wide.hasError);
    assert(wide.error.code == UtfConversionErrorCode.insufficientSpace);
    assert(wide.error.required == 3);

    const wchar[2] source = [cast(wchar) 0xD83D, cast(wchar) 0xDE00];
    char[4] exact;
    assert(utf16ToUtf8(source[], exact[]).value == 4);
    auto terminated = utf16ToUtf8z(source[], exact[]);
    assert(terminated.hasError && terminated.error.required == 5);
}

@("text.utf16.mixedAsciiBlocksRespectExactSlices")
unittest
{
    enum source = "0123456789abcdefé€😀abcdefghijklmnop\0qrstuvwxyz012345";
    enum expected = "0123456789abcdefé€😀abcdefghijklmnop\0qrstuvwxyz012345"w;
    // Independently aligned inputs/outputs, non-ASCII transitions and a NUL
    // exercise bounded stores across baseline/feature-targeted call sites.
    foreach (sourceAlignment; 0 .. 16)
    foreach (destinationAlignment; 0 .. 16)
    {
        char[128] input;
        input[sourceAlignment .. sourceAlignment + source.length] = source[];
        wchar[128] wide = 0xA5A5;
        const encoded = utf8ToUtf16(input[sourceAlignment .. sourceAlignment + source.length],
            wide[destinationAlignment .. destinationAlignment + expected.length]);
        assert(encoded.hasValue && encoded.value == expected.length);
        assert(wide[destinationAlignment .. destinationAlignment + expected.length] == expected);
        foreach (unit; wide[0 .. destinationAlignment])
            assert(unit == 0xA5A5);
        foreach (unit; wide[destinationAlignment + expected.length .. $])
            assert(unit == 0xA5A5);

        char[128] bytes = cast(char) 0x5A;
        const decoded = utf16ToUtf8(wide[destinationAlignment .. destinationAlignment + expected.length],
            bytes[sourceAlignment .. sourceAlignment + source.length]);
        assert(decoded.hasValue && decoded.value == source.length);
        assert(bytes[sourceAlignment .. sourceAlignment + source.length] == source);
        foreach (unit; bytes[0 .. sourceAlignment])
            assert(unit == 0x5A);
        foreach (unit; bytes[sourceAlignment + source.length .. $])
            assert(unit == 0x5A);
    }

    wchar[128] wide = 0xA5A5;
    const wideBefore = wide;
    foreach (capacity; 0 .. expected.length)
    {
        const result = utf8ToUtf16(source, wide[3 .. 3 + capacity]);
        assert(result.hasError
            && result.error.code == UtfConversionErrorCode.insufficientSpace);
        assert(result.error.offset == source.length
            && result.error.required == expected.length);
        assert(wide == wideBefore);
    }
    char[128] bytes = cast(char) 0x5A;
    const bytesBefore = bytes;
    foreach (capacity; 0 .. source.length)
    {
        const result = utf16ToUtf8(expected, bytes[3 .. 3 + capacity]);
        assert(result.hasError
            && result.error.code == UtfConversionErrorCode.insufficientSpace);
        assert(result.error.offset == expected.length
            && result.error.required == source.length);
        assert(bytes == bytesBefore);
    }
}

@("text.utf16.vectorBoundaryFailuresRemainTransactional")
unittest
{
    foreach (position; [0, 7, 8, 15, 16, 17, 31, 32, 33, 47, 63])
    {
        char[80] source8 = 'a';
        wchar[80] source16 = 'a';
        source8[position] = 0;
        source16[position] = 0;

        wchar[81] wide = 0xA5A5;
        const wideBefore = wide;
        char[81] bytes = cast(char) 0x5A;
        const bytesBefore = bytes;
        // Embedded NUL wins over insufficient space even after ASCII blocks.
        const rejected8 = utf8ToUtf16z(source8[], wide[0 .. 1]);
        assert(rejected8.hasError
            && rejected8.error.code == UtfConversionErrorCode.embeddedNul);
        assert(rejected8.error.offset == position
            && rejected8.error.required == 0 && wide == wideBefore);
        const rejected16 = utf16ToUtf8z(source16[], bytes[0 .. 1]);
        assert(rejected16.hasError
            && rejected16.error.code == UtfConversionErrorCode.embeddedNul);
        assert(rejected16.error.offset == position
            && rejected16.error.required == 0 && bytes == bytesBefore);

        assert(utf8ToUtf16(source8[], wide[0 .. 80]).value == 80);
        assert(wide[0 .. 80] == source16[] && wide[80] == 0xA5A5);
        assert(utf16ToUtf8(source16[], bytes[0 .. 80]).value == 80);
        assert(bytes[0 .. 80] == source8[] && bytes[80] == 0x5A);

        wide[] = wideBefore[];
        bytes[] = bytesBefore[];
        source8[position] = '\xE2';
        source8[position + 1] = '(';
        source16[position] = cast(wchar) 0xD800;
        const malformed8 = utf8ToUtf16(source8[], wide[]);
        assert(malformed8.hasError
            && malformed8.error.code == UtfConversionErrorCode.invalidUtf8);
        assert(malformed8.error.offset == position
            && malformed8.error.required == 0 && wide == wideBefore);
        const malformed16 = utf16ToUtf8(source16[], bytes[]);
        assert(malformed16.hasError
            && malformed16.error.code == UtfConversionErrorCode.invalidUtf16);
        assert(malformed16.error.offset == position
            && malformed16.error.required == 0 && bytes == bytesBefore);

        source8[position] = 'a';
        source8[position + 1] = 'a';
        source16[position] = 'a';
        const terminated8 = utf8ToUtf16z(source8[], wide[]);
        assert(terminated8.hasValue && terminated8.value == 80);
        assert(wide[0 .. 80] == source16[] && wide[80] == 0);
        const terminated16 = utf16ToUtf8z(source16[], bytes[]);
        assert(terminated16.hasValue && terminated16.value == 80);
        assert(bytes[0 .. 80] == source8[] && bytes[80] == 0);
    }
}

@("text.utf16.nonAsciiSizingAndSurrogateBoundaries")
unittest
{
    enum part8 = "\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFF😀\0";
    enum part16 = "\u007F\u0080\u07FF\u0800\uD7FF\uE000\uFFFF😀\0"w;
    enum source8 = part8 ~ part8 ~ part8 ~ part8 ~ part8 ~ part8 ~ part8 ~ part8;
    enum source16 = part16 ~ part16 ~ part16 ~ part16 ~ part16 ~ part16 ~ part16 ~ part16;
    foreach (alignment; 0 .. 32)
    {
        char[256] input;
        input[alignment .. alignment + source8.length] = source8[];
        wchar[160] wide = 0xA5A5;
        const encoded = utf8ToUtf16(input[alignment .. alignment + source8.length],
            wide[alignment .. alignment + source16.length]);
        assert(encoded.hasValue && encoded.value == source16.length);
        assert(wide[alignment .. alignment + source16.length] == source16);
        assert(wide[alignment + source16.length] == 0xA5A5);
        char[256] bytes = cast(char) 0x5A;
        const decoded = utf16ToUtf8(wide[alignment .. alignment + source16.length],
            bytes[alignment .. alignment + source8.length]);
        assert(decoded.hasValue && decoded.value == source8.length);
        assert(bytes[alignment .. alignment + source8.length] == source8);
        assert(bytes[alignment + source8.length] == 0x5A);
    }
    foreach (position; 0 .. 64)
    {
        wchar[80] source = '\u4E16';
        source[position] = 0xD83D;
        source[position + 1] = 0xDE00;
        char[241] bytes = cast(char) 0x5A;
        const valid = utf16ToUtf8(source[], bytes[0 .. 238]);
        assert(valid.hasValue && valid.value == 238);
        assert(bytes[position * 3 .. position * 3 + 4] == "😀");
        assert(bytes[238] == 0x5A);

        bytes[] = cast(char) 0x5A;
        const before = bytes;
        source[position + 1] = '\u4E16';
        const badHead = utf16ToUtf8(source[], bytes[]);
        assert(badHead.hasError && badHead.error.code == UtfConversionErrorCode.invalidUtf16);
        assert(badHead.error.offset == position && bytes == before);
        source[position] = 0xDC00;
        const badTail = utf16ToUtf8(source[], bytes[]);
        assert(badTail.hasError && badTail.error.code == UtfConversionErrorCode.invalidUtf16);
        assert(badTail.error.offset == position && bytes == before);
    }
}

@("text.utf16.compactedEmissionMatchesIndependentScalarReference")
unittest
{
    import std.utf : codeLength, toUTF8, toUTF16;

    enum scalars = (() {
        dchar[128] result;
        immutable dchar[12] edges = [cast(dchar) 0, 0x7F, 0x80, 0x7FF, 0x800, 0xD7FF,
            0xE000, 0xFFFF, 0x10000, 0x103FF, 0x10400, 0x10FFFF];
        uint state = 0x31415926;
        foreach (i; 0 .. result.length)
        {
            state = state * 1664525 + 1013904223;
            auto scalar = state % 0x110000;
            if (scalar >= 0xD800 && scalar <= 0xDFFF)
                scalar = 0xE000;
            result[i] = i % 3 == 0 ? cast(dchar) scalar : edges[(state >> 16) % edges.length];
        }
        return result;
    })();
    static immutable reference8 = toUTF8(scalars[]);
    static immutable reference16 = toUTF16(scalars[]);
    size_t length8, length16;
    foreach (scalar; scalars)
    {
        length8 += codeLength!char(scalar);
        length16 += codeLength!wchar(scalar);
        // Every scalar prefix gives exact capacities on both sides, including
        // all final block lengths and surrogate-pair boundary positions.
        foreach (alignment; 0 .. 8)
        {
            char[528] input8;
            wchar[272] input16;
            input8[alignment .. alignment + length8] = reference8[0 .. length8];
            input16[alignment .. alignment + length16] = reference16[0 .. length16];
            wchar[272] wide = 0xA5A5;
            char[528] bytes = cast(char) 0x5A;
            const encoded = utf8ToUtf16(input8[alignment .. alignment + length8],
                wide[alignment .. alignment + length16]);
            const decoded = utf16ToUtf8(input16[alignment .. alignment + length16],
                bytes[alignment .. alignment + length8]);
            assert(encoded.hasValue && encoded.value == length16);
            assert(decoded.hasValue && decoded.value == length8);
            assert(wide[alignment .. alignment + length16] == reference16[0 .. length16]);
            assert(bytes[alignment .. alignment + length8] == reference8[0 .. length8]);
            foreach (unit; wide[0 .. alignment])
                assert(unit == 0xA5A5);
            foreach (unit; wide[alignment + length16 .. $])
                assert(unit == 0xA5A5);
            foreach (unit; bytes[0 .. alignment])
                assert(unit == 0x5A);
            foreach (unit; bytes[alignment + length8 .. $])
                assert(unit == 0x5A);
        }
    }
}

@("text.utf16.uniformWidthEdgesAndExactCapacity")
@safe pure nothrow @nogc
unittest
{
    import std.utf : toUTF8, toUTF16;

    static foreach (edges; [[cast(dchar) 0x80, 0x7FF],
        [cast(dchar) 0x800, 0xD7FF], [cast(dchar) 0xE000, 0xFFFF]])
    {{
        enum scalars = (() {
            immutable dchar[2] pair = edges;
            dchar[96] result;
            foreach (i, ref scalar; result)
                scalar = pair[i & 1];
            return result;
        })();
        static immutable reference8 = toUTF8(scalars[]);
        static immutable reference16 = toUTF16(scalars[]);
        enum bytesPerScalar = edges[0] < 0x800 ? 2 : 3;
        foreach (count; 1 .. scalars.length + 1)
            foreach (alignment; 0 .. 8)
            {
                const byteCount = count * bytesPerScalar;
                char[304] source8 = void;
                wchar[112] source16 = void;
                source8[alignment .. alignment + byteCount] = reference8[0 .. byteCount];
                source16[alignment .. alignment + count] = reference16[0 .. count];
                wchar[112] wide = 0xA5A5;
                char[304] bytes = cast(char) 0x5A;
                const encoded = utf8ToUtf16(source8[alignment .. alignment + byteCount],
                    wide[alignment .. alignment + count]);
                const decoded = utf16ToUtf8(source16[alignment .. alignment + count],
                    bytes[alignment .. alignment + byteCount]);
                assert(encoded.hasValue && encoded.value == count);
                assert(decoded.hasValue && decoded.value == byteCount);
                assert(wide[alignment .. alignment + count] == reference16[0 .. count]);
                assert(bytes[alignment .. alignment + byteCount] == reference8[0 .. byteCount]);
                foreach (unit; wide[0 .. alignment])
                    assert(unit == 0xA5A5);
                foreach (unit; wide[alignment + count .. $])
                    assert(unit == 0xA5A5);
                foreach (unit; bytes[0 .. alignment])
                    assert(unit == 0x5A);
                foreach (unit; bytes[alignment + byteCount .. $])
                    assert(unit == 0x5A);
            }
    }}
}

@("text.utf16.nonAsciiPreflightPreservesFailurePrecedence")
unittest
{
    enum prefix8 = "é世😀é世😀é世😀é世😀é世😀é世😀é世😀é世😀";
    enum prefix16 = "é世😀é世😀é世😀é世😀é世😀é世😀é世😀é世😀"w;
    wchar[128] wide = 0xA5A5;
    char[256] bytes = cast(char) 0x5A;
    const beforeWide = wide;
    const beforeBytes = bytes;
    foreach (extra; ["\xF4\x90\x80\x80", "\xED\xA0\x80", "\xF0\x90\x80", "\x80"])
    {
        char[128] input;
        input[0 .. prefix8.length] = prefix8[];
        input[prefix8.length .. prefix8.length + extra.length] = extra[];
        const invalid = utf8ToUtf16(input[0 .. prefix8.length + extra.length], wide[0 .. 1]);
        assert(invalid.hasError && invalid.error.code == UtfConversionErrorCode.invalidUtf8);
        assert(invalid.error.offset == prefix8.length && invalid.error.required == 0);
        assert(wide == beforeWide);
    }
    wchar[128] input16;
    input16[0 .. prefix16.length] = prefix16[];
    input16[prefix16.length] = 0xD800;
    const invalid16 = utf16ToUtf8(input16[0 .. prefix16.length + 1], bytes[0 .. 1]);
    assert(invalid16.hasError && invalid16.error.code == UtfConversionErrorCode.invalidUtf16);
    assert(invalid16.error.offset == prefix16.length && invalid16.error.required == 0);
    assert(bytes == beforeBytes);
    const capacity8 = utf8ToUtf16(prefix8, wide[0 .. prefix16.length - 1]);
    const capacity16 = utf16ToUtf8(prefix16, bytes[0 .. prefix8.length - 1]);
    assert(capacity8.hasError && capacity8.error.code == UtfConversionErrorCode.insufficientSpace);
    assert(capacity16.hasError && capacity16.error.code == UtfConversionErrorCode.insufficientSpace);
    assert(capacity8.error.required == prefix16.length && wide == beforeWide);
    assert(capacity16.error.required == prefix8.length && bytes == beforeBytes);
    const nul8 = utf8ToUtf16z(prefix8 ~ "\0\x80", wide[0 .. 1]);
    input16[prefix16.length] = 0;
    input16[prefix16.length + 1] = 0xDC00;
    const nul16 = utf16ToUtf8z(input16[0 .. prefix16.length + 2], bytes[0 .. 1]);
    assert(nul8.hasError && nul8.error.code == UtfConversionErrorCode.embeddedNul);
    assert(nul16.hasError && nul16.error.code == UtfConversionErrorCode.embeddedNul);
    assert(nul8.error.offset == prefix8.length && wide == beforeWide);
    assert(nul16.error.offset == prefix16.length && bytes == beforeBytes);
}
