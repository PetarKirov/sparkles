/**
UTF-16 byte-order adapter: decodes UTF-16BE or UTF-16LE bytes to UTF-8.

The core codecs in `sparkles.base.text.utf16` take 16-bit code units, not bytes
with an implicit byte order (TXT-UTF18). This adapter reads the bytes in a
fixed stack chunk of code units and hands each chunk to those codecs, so
validation, replacement and error reasons are theirs. A chunk never ends on a
high surrogate while more input follows, so no surrogate pair is split.

Conversion validates and measures the whole source before writing; on
failure the destination is unchanged. Error offsets are byte offsets into
the source. A BOM is decoded as U+FEFF, never stripped.
*/
module sparkles.base.text.utf16_bytes;

import expected : err, ok;

import sparkles.base.text.errors : NoGcHook;
import sparkles.base.text.utf : addUtfCount, UtfMode, UtfReason, utfStorageOverlaps;
import sparkles.base.text.utf16 : measureConversion, utf16ToUtf8, UtfConversionError,
    UtfConversionErrorCode, UtfConversionMeasure, UtfConversionResult;

/// The serialization order of each 16-bit code unit.
enum ByteOrder : ubyte
{
    bigEndian,
    littleEndian,
}

private enum chunkUnits = 64;
private enum replacementUtf8 = "\xEF\xBF\xBD";

private UtfConversionResult!T success(T)(T value) => ok!(UtfConversionError, NoGcHook)(value);
private UtfConversionResult!T fail(T)(UtfConversionError error) => err!(T, NoGcHook)(error);

/// Reads up to `chunkUnits` code units starting at byte `from`; returns the count.
private size_t fillChunk(scope const(ubyte)[] bytes, size_t from, ByteOrder order,
    ref wchar[chunkUnits] units) @safe pure nothrow @nogc
{
    const available = (bytes.length - from) / 2;
    size_t count = available < chunkUnits ? available : chunkUnits;
    foreach (i; 0 .. count)
    {
        const at = from + 2 * i;
        units[i] = order == ByteOrder.bigEndian
            ? cast(wchar)((bytes[at] << 8) | bytes[at + 1])
            : cast(wchar)((bytes[at + 1] << 8) | bytes[at]);
    }
    // Keep a pair together: defer a trailing high surrogate to the next chunk.
    if (count == chunkUnits && count < available && (units[count - 1] & 0xFC00) == 0xD800)
        --count;
    return count;
}

/// A chunk-relative code-unit error, rebased to a byte offset in the whole source.
private UtfConversionError rebase(UtfConversionError error, size_t chunkStart)
    @safe pure nothrow @nogc
{
    if (error.code == UtfConversionErrorCode.invalidUtf16)
        error.offset = chunkStart + 2 * error.offset;
    return error;
}

/**
Measures the UTF-8 length of UTF-16 `bytes` in the given byte order.

`mode` is `strict` or `replacement`; `opaque` is `invalidOptions`. In strict
mode an odd trailing byte is `invalidUtf16` with reason `truncated` at its
offset, unless an earlier defect is found first; in replacement mode it
measures as U+FFFD.
*/
UtfConversionResult!UtfConversionMeasure measureUtf16BytesToUtf8(
    scope const(ubyte)[] bytes, ByteOrder order, UtfMode mode = UtfMode.strict)
    @safe pure nothrow @nogc
{
    if (mode != UtfMode.strict && mode != UtfMode.replacement)
        return fail!UtfConversionMeasure(UtfConversionError(UtfConversionErrorCode.invalidOptions));
    size_t payload;
    size_t from;
    wchar[chunkUnits] units;
    while (bytes.length - from >= 2)
    {
        const count = fillChunk(bytes, from, order, units);
        const measured = measureConversion!char(units[0 .. count], mode);
        if (measured.hasError)
            return fail!UtfConversionMeasure(rebase(measured.error, from));
        if (!addUtfCount(payload, measured.value.payload))
            return fail!UtfConversionMeasure(UtfConversionError(UtfConversionErrorCode.overflow));
        from += 2 * count;
    }
    if (bytes.length & 1)
    {
        if (mode == UtfMode.strict)
            return fail!UtfConversionMeasure(UtfConversionError(UtfConversionErrorCode.invalidUtf16,
                bytes.length - 1, 0, UtfReason.truncated));
        if (!addUtfCount(payload, replacementUtf8.length))
            return fail!UtfConversionMeasure(UtfConversionError(UtfConversionErrorCode.overflow));
    }
    return success(UtfConversionMeasure(payload, payload));
}

/**
Converts UTF-16 `bytes` in the given byte order into UTF-8 in `destination`.

The whole source is validated and measured first, under the rules of
`measureUtf16BytesToUtf8`; a too-short destination is `insufficientSpace`
with the required length, and storage shared between source and destination
is `overlap`. On any error the destination is unchanged. Returns the number
of bytes written.
*/
UtfConversionResult!size_t utf16BytesToUtf8(scope const(ubyte)[] bytes, ByteOrder order,
    scope char[] destination, UtfMode mode = UtfMode.strict) @safe pure nothrow @nogc
{
    if (mode != UtfMode.strict && mode != UtfMode.replacement)
        return fail!size_t(UtfConversionError(UtfConversionErrorCode.invalidOptions));
    if (utfStorageOverlaps(bytes, destination))
        return fail!size_t(UtfConversionError(UtfConversionErrorCode.overlap));
    const measured = measureUtf16BytesToUtf8(bytes, order, mode);
    if (measured.hasError)
        return fail!size_t(measured.error);
    const payload = measured.value.payload;
    if (destination.length < payload)
        return fail!size_t(UtfConversionError(UtfConversionErrorCode.insufficientSpace,
            bytes.length, payload));
    size_t written;
    size_t from;
    wchar[chunkUnits] units;
    while (bytes.length - from >= 2)
    {
        const count = fillChunk(bytes, from, order, units);
        const converted = utf16ToUtf8(units[0 .. count], destination[written .. payload], mode);
        // The source was fully validated and measured above.
        assert(converted.hasValue);
        written += converted.value;
        from += 2 * count;
    }
    if (bytes.length & 1)
    {
        destination[written .. written + replacementUtf8.length] = replacementUtf8;
        written += replacementUtf8.length;
    }
    assert(written == payload);
    return success(written);
}

///
@("text.utf16Bytes.bothByteOrders")
@safe pure nothrow @nogc
unittest
{
    // "A€😀": U+0041, U+20AC, U+1F600 (D83D DE00)
    static immutable ubyte[8] be = [0x00, 0x41, 0x20, 0xAC, 0xD8, 0x3D, 0xDE, 0x00];
    static immutable ubyte[8] le = [0x41, 0x00, 0xAC, 0x20, 0x3D, 0xD8, 0x00, 0xDE];
    char[16] out_;
    foreach (i, order; [ByteOrder.bigEndian, ByteOrder.littleEndian])
    {
        const source = i == 0 ? be[] : le[];
        const measured = measureUtf16BytesToUtf8(source, order);
        assert(measured.hasValue && measured.value.payload == 8);
        const written = utf16BytesToUtf8(source, order, out_[]);
        assert(written.hasValue && out_[0 .. written.value] == "A€😀");
    }
}

@("text.utf16Bytes.oddLengthIsTruncatedInStrictMode")
@safe pure nothrow @nogc
unittest
{
    static immutable ubyte[3] odd = [0x00, 0x41, 0x00];
    char[8] out_ = 'x';
    const strict = utf16BytesToUtf8(odd[], ByteOrder.bigEndian, out_[]);
    assert(strict.hasError);
    assert(strict.error.code == UtfConversionErrorCode.invalidUtf16);
    assert(strict.error.reason == UtfReason.truncated && strict.error.offset == 2);
    foreach (c; out_) assert(c == 'x');

    const replaced = utf16BytesToUtf8(odd[], ByteOrder.bigEndian, out_[], UtfMode.replacement);
    assert(replaced.hasValue && out_[0 .. replaced.value] == "A�");
}

@("text.utf16Bytes.earlierDefectWinsOverOddByte")
@safe pure nothrow @nogc
unittest
{
    // A lone low surrogate at byte 2, then a stray byte.
    static immutable ubyte[5] source = [0x00, 0x41, 0xDC, 0x00, 0x42];
    char[8] out_;
    const result = utf16BytesToUtf8(source[], ByteOrder.bigEndian, out_[]);
    assert(result.hasError && result.error.reason == UtfReason.unpairedSurrogate);
    assert(result.error.offset == 2);
}

@("text.utf16Bytes.pairAcrossChunkBoundary")
@safe pure nothrow @nogc
unittest
{
    // 63 'a' units, then a pair whose high surrogate would end the first chunk.
    ubyte[2 * 65] source;
    foreach (i; 0 .. 63)
        source[2 * i + 1] = 'a';
    static immutable ubyte[4] pair = [0xD8, 0x3D, 0xDE, 0x00];
    source[126 .. 130] = pair;
    char[67] out_;
    const written = utf16BytesToUtf8(source[], ByteOrder.bigEndian, out_[]);
    assert(written.hasValue && written.value == 67);
    assert(out_[63 .. 67] == "😀");

    // The same high surrogate followed by 'A' is unpaired, at byte 126.
    static immutable ubyte[2] letterA = [0x00, 0x41];
    source[128 .. 130] = letterA;
    const broken = utf16BytesToUtf8(source[], ByteOrder.bigEndian, out_[]);
    assert(broken.hasError && broken.error.reason == UtfReason.unpairedSurrogate);
    assert(broken.error.offset == 126);
}

@("text.utf16Bytes.capacityOptionsAndOverlap")
@safe pure nothrow @nogc
unittest
{
    static immutable ubyte[4] source = [0x00, 0x41, 0x00, 0x42];
    char[1] small = 'x';
    const tooSmall = utf16BytesToUtf8(source[], ByteOrder.bigEndian, small[]);
    assert(tooSmall.hasError && tooSmall.error.code == UtfConversionErrorCode.insufficientSpace);
    assert(tooSmall.error.required == 2 && small[0] == 'x');

    char[4] out_;
    const opaque = utf16BytesToUtf8(source[], ByteOrder.bigEndian, out_[], UtfMode.opaque);
    assert(opaque.hasError && opaque.error.code == UtfConversionErrorCode.invalidOptions);

    const empty = utf16BytesToUtf8(source[0 .. 0], ByteOrder.littleEndian, out_[]);
    assert(empty.hasValue && empty.value == 0);
}

@("text.utf16Bytes.overlapIsRejected")
@system pure nothrow @nogc
unittest
{
    ubyte[8] storage = [0x00, 0x41, 0x00, 0x42, 0, 0, 0, 0];
    auto destination = (() @trusted => cast(char[]) storage[2 .. 8])();
    const result = utf16BytesToUtf8(storage[0 .. 4], ByteOrder.bigEndian, destination);
    assert(result.hasError && result.error.code == UtfConversionErrorCode.overlap);
}
