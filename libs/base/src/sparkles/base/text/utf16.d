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
import sparkles.base.text.utf : encodeUtf8;
import sparkles.base.text.utf8 : utf8SequenceLength;

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
        const len = source[si] < 0x80 ? 1 : utf8SequenceLength(source, si);
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
        dchar scalar = source[si++];
        if (scalar >= 0xD800 && scalar <= 0xDBFF)
        {
            const low = source[si++];
            scalar = cast(dchar)(0x1_0000
                + ((scalar - 0xD800) << 10) + (low - 0xDC00));
        }
        char[4] encoded;
        const len = encodeUtf8(scalar, encoded);
        foreach (i; 0 .. len)
            destination[di++] = encoded[i];
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
    while (i < source.length)
    {
        const lead = source[i];
        if (lead == 0 && rejectNul)
            return utfErr!size_t(UtfConversionError(
                UtfConversionErrorCode.embeddedNul, i, 0));

        size_t len = 1;
        if (lead >= 0x80)
        {
            len = utf8SequenceLength(source, i);
            if (len == 0)
                return utfErr!size_t(UtfConversionError(
                    UtfConversionErrorCode.invalidUtf8, i, 0));
        }
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
    while (i < source.length)
    {
        const unit = source[i];
        if (unit == 0 && rejectNul)
            return utfErr!size_t(UtfConversionError(
                UtfConversionErrorCode.embeddedNul, i, 0));

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

        bytes += unit < 0x80 ? 1 : unit < 0x800 ? 2 : 3;
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
