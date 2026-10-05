/++
Owned, bounded UTF token decoding, scalar encoding, and incremental conversion.
UTF-8 bytes, UTF-16 code units and UTF-32 values are never auto-decoded ranges.
Whole transactional conversions and their named encoding-pair seams live in utf16.
+/
module sparkles.base.text.utf;

/// Malformed-input handling. Opaque tokens are supported only for UTF-8 input.
enum UtfMode : ubyte { strict, replacement, opaque }
enum UtfEncoding : ubyte { utf8, utf16, utf32 }
enum UtfStatus : ubyte
{
    ok, end, needInput, outputFull, invalid, overflow, overlap,
    invalidOptions, invalidState,
}
enum UtfReason : ubyte
{
    none, invalidLead, invalidContinuation, truncated, unpairedSurrogate,
    invalidScalar, opaqueNotEncodable,
}
enum UtfTokenKind : ubyte { scalar, replacement, opaqueByte }

/// Owned value and source-unit span; opaque byte values are never scalar values.
struct UtfToken
{
    UtfTokenKind kind;
    dchar scalar;
    ubyte byteValue;
    size_t start;
    size_t end;
}

/// Counts refer to this call; offset identifies the blocking source token.
struct UtfResult
{
    UtfStatus status;
    size_t consumed;
    size_t written;
    size_t offset;
    size_t required;
    UtfEncoding encoding;
    UtfReason reason;
}
struct UtfDecodeResult
{
    UtfResult result;
    UtfToken token;
}

template isUtfUnit(T)
{
    enum isUtfUnit = is(T == char) || is(T == wchar) || is(T == dchar);
}
template utfEncoding(T) if (isUtfUnit!T)
{
    static if (is(T == char)) enum utfEncoding = UtfEncoding.utf8;
    else static if (is(T == wchar)) enum utfEncoding = UtfEncoding.utf16;
    else enum utfEncoding = UtfEncoding.utf32;
}

bool isUnicodeScalar(dchar value) @safe pure nothrow @nogc
{
    return value <= 0x10FFFF && (value < 0xD800 || value > 0xDFFF);
}

/// Checked count addition leaves the accumulator unchanged on overflow.
bool addUtfCount(ref size_t count, size_t amount) @safe pure nothrow @nogc
{
    if (amount > size_t.max - count)
        return false;
    count += amount;
    return true;
}

private bool validMode(S)(UtfMode mode)
{
    return mode == UtfMode.strict || mode == UtfMode.replacement
        || (is(S == char) && mode == UtfMode.opaque);
}

/// Decode exactly one token. An incomplete non-final suffix remains unconsumed.
UtfDecodeResult decodeToken(S)(scope const(S)[] source,
    UtfMode mode = UtfMode.strict, bool isFinal = true, size_t offset = 0)
    if (isUtfUnit!S)
{
    UtfDecodeResult decoded;
    decoded.result.encoding = utfEncoding!S;
    decoded.result.offset = offset;
    if (!validMode!S(mode))
    {
        decoded.result.status = UtfStatus.invalidOptions;
        return decoded;
    }
    if (!source.length)
    {
        decoded.result.status = isFinal ? UtfStatus.end : UtfStatus.needInput;
        return decoded;
    }
    size_t count = 1;
    dchar scalar;
    UtfReason reason;
    bool incomplete;
    static if (is(S == char))
    {
        const first = cast(ubyte) source[0];
        if (first < 0x80)
            scalar = first;
        else
        {
            size_t length;
            ubyte lower = 0x80, upper = 0xBF;
            if (first >= 0xC2 && first <= 0xDF)
            {
                length = 2;
                scalar = first & 0x1F;
            }
            else if (first >= 0xE0 && first <= 0xEF)
            {
                length = 3;
                scalar = first & 0x0F;
                if (first == 0xE0) lower = 0xA0;
                if (first == 0xED) upper = 0x9F;
            }
            else if (first >= 0xF0 && first <= 0xF4)
            {
                length = 4;
                scalar = first & 0x07;
                if (first == 0xF0) lower = 0x90;
                if (first == 0xF4) upper = 0x8F;
            }
            else
                reason = UtfReason.invalidLead;
            if (length)
            {
                while (count < length)
                {
                    if (count == source.length)
                    {
                        incomplete = true;
                        reason = UtfReason.truncated;
                        break;
                    }
                    const next = cast(ubyte) source[count];
                    if (next < lower || next > upper)
                    {
                        reason = UtfReason.invalidContinuation;
                        break;
                    }
                    scalar = cast(dchar)((scalar << 6) | (next & 0x3F));
                    ++count;
                    lower = 0x80;
                    upper = 0xBF;
                }
            }
        }
    }
    else static if (is(S == wchar))
    {
        scalar = source[0];
        if (scalar >= 0xD800 && scalar <= 0xDBFF)
        {
            if (source.length == 1)
            {
                incomplete = true;
                reason = UtfReason.truncated;
            }
            else if (source[1] < 0xDC00 || source[1] > 0xDFFF)
                reason = UtfReason.unpairedSurrogate;
            else
            {
                scalar = cast(dchar)(0x10000 + ((scalar - 0xD800) << 10)
                    + (source[1] - 0xDC00));
                count = 2;
            }
        }
        else if (scalar >= 0xDC00 && scalar <= 0xDFFF)
            reason = UtfReason.unpairedSurrogate;
    }
    else
    {
        scalar = source[0];
        if (!isUnicodeScalar(scalar))
            reason = UtfReason.invalidScalar;
    }
    if (incomplete && !isFinal)
    {
        decoded.result.status = UtfStatus.needInput;
        return decoded;
    }
    if (reason != UtfReason.none)
    {
        if (mode == UtfMode.strict)
        {
            decoded.result.status = UtfStatus.invalid;
            decoded.result.reason = reason;
            return decoded;
        }
        if (mode == UtfMode.opaque)
        {
            count = 1;
            decoded.token.kind = UtfTokenKind.opaqueByte;
            decoded.token.byteValue = cast(ubyte) source[0];
            scalar = 0;
        }
        else
        {
            decoded.token.kind = UtfTokenKind.replacement;
            scalar = 0xFFFD;
        }
    }
    if (count > size_t.max - offset)
    {
        decoded.result.status = UtfStatus.overflow;
        return decoded;
    }
    decoded.token.scalar = scalar;
    decoded.token.start = offset;
    decoded.token.end = offset + count;
    decoded.result.status = UtfStatus.ok;
    decoded.result.consumed = count;
    return decoded;
}

/// Encode a scalar atomically. Replacement mode replaces non-scalars explicitly.
UtfResult encodeScalar(D)(dchar scalar, scope D[] destination,
    UtfMode mode = UtfMode.strict) if (isUtfUnit!D)
{
    UtfResult result;
    result.encoding = utfEncoding!D;
    if (mode != UtfMode.strict && mode != UtfMode.replacement)
    {
        result.status = UtfStatus.invalidOptions;
        return result;
    }
    if (!isUnicodeScalar(scalar))
    {
        if (mode == UtfMode.strict)
        {
            result.status = UtfStatus.invalid;
            result.reason = UtfReason.invalidScalar;
            return result;
        }
        scalar = 0xFFFD;
    }
    result.required = scalarUnits!D(scalar);
    if (destination.length < result.required)
    {
        result.status = UtfStatus.outputFull;
        return result;
    }
    static if (is(D == char))
    {
        if (result.required == 1)
            destination[0] = cast(char) scalar;
        else
        {
            if (result.required == 2)
                destination[0] = cast(char)(0xC0 | (scalar >> 6));
            else if (result.required == 3)
                destination[0] = cast(char)(0xE0 | (scalar >> 12));
            else
                destination[0] = cast(char)(0xF0 | (scalar >> 18));
            foreach (i; 1 .. result.required)
                destination[i] = cast(char)(0x80
                    | ((scalar >> (6 * (result.required - i - 1))) & 0x3F));
        }
    }
    else static if (is(D == wchar))
    {
        if (result.required == 1)
            destination[0] = cast(wchar) scalar;
        else
        {
            const value = scalar - 0x10000;
            destination[0] = cast(wchar)(0xD800 | (value >> 10));
            destination[1] = cast(wchar)(0xDC00 | (value & 0x3FF));
        }
    }
    else
        destination[0] = scalar;
    result.written = result.required;
    result.status = UtfStatus.ok;
    return result;
}

size_t scalarUnits(D)(dchar scalar) if (isUtfUnit!D)
{
    static if (is(D == char))
        return scalar < 0x80 ? 1 : scalar < 0x800 ? 2 : scalar < 0x10000 ? 3 : 4;
    else static if (is(D == wchar))
        return scalar < 0x10000 ? 1 : 2;
    else
        return 1;
}

/// Scalar encoding rejects opaque tokens, even when the destination is UTF-8.
UtfResult encodeToken(D)(UtfToken token, scope D[] destination)
    if (isUtfUnit!D)
{
    if (token.kind == UtfTokenKind.opaqueByte)
        return UtfResult(UtfStatus.invalid, 0, 0, token.start, 0,
            utfEncoding!D, UtfReason.opaqueNotEncodable);
    auto result = encodeScalar(token.scalar, destination);
    result.offset = token.start;
    return result;
}

/// Explicit byte reconstruction, distinct from Unicode encoding.
UtfResult reconstructToken(UtfToken token, scope char[] destination)
    @safe pure nothrow @nogc
{
    if (token.kind != UtfTokenKind.opaqueByte)
        return encodeToken(token, destination);
    UtfResult result = UtfResult(UtfStatus.outputFull, 0, 0, token.start, 1);
    if (destination.length)
    {
        destination[0] = cast(char) token.byteValue;
        result.status = UtfStatus.ok;
        result.written = 1;
    }
    return result;
}

/// Byte-address overlap check includes cross-element slices, without end overflow.
bool utfStorageOverlaps(S, D)(scope const(S)[] source, scope D[] destination)
{
    if (!source.length || !destination.length)
        return false;
    if (__ctfe)
    {
        // CTFE cannot cast pointers to integers; comparison remains element-based.
        static if (is(S == D))
        {
            foreach (ref const value; source)
                if (&value == destination.ptr) return true;
            foreach (ref target; destination)
                if (&target == source.ptr) return true;
        }
        return false;
    }
    return (() @trusted {
        const a = cast(size_t) source.ptr;
        const b = cast(size_t) destination.ptr;
        // Valid D slices have representable storage extents. Subtract addresses
        // instead of forming a possibly overflowing one-past address.
        if (a <= b)
            return (b - a) / S.sizeof < source.length;
        return (a - b) / D.sizeof < destination.length;
    })();
}

/** Borrow one object's exact storage for alias preflight without copying it.
The `return ref` lifetime follows the caller's object; pointer slicing is confined
to the trusted operation that constructs the one-element view.
*/
package(sparkles) T[] utfObjectStorage(T)(scope return ref T value)
    => (() @trusted { return (&value)[0 .. 1]; })();

/// Stateless decoding into caller token storage.
UtfResult decodePrefix(S)(scope const(S)[] source, scope UtfToken[] destination,
    UtfMode mode = UtfMode.strict, bool isFinal = true) if (isUtfUnit!S)
{
    return prefixImpl(source, destination, mode, isFinal);
}

/// Stateless conversion; only complete output tokens commit.
UtfResult convertPrefix(S, D)(scope const(S)[] source, scope D[] destination,
    UtfMode mode = UtfMode.strict, bool isFinal = true)
    if (isUtfUnit!S && isUtfUnit!D)
{
    return prefixImpl(source, destination, mode, isFinal);
}

private UtfResult prefixImpl(S, D)(scope const(S)[] source, scope D[] destination,
    UtfMode mode, bool isFinal)
{
    UtfResult result;
    result.encoding = utfEncoding!S;
    if (!validMode!S(mode))
    {
        result.status = UtfStatus.invalidOptions;
        return result;
    }
    if (utfStorageOverlaps(source, destination))
    {
        result.status = UtfStatus.overlap;
        return result;
    }
    while (true)
    {
        const decoded = decodeToken(source[result.consumed .. $], mode, isFinal,
            result.consumed);
        result.status = decoded.result.status;
        result.offset = decoded.result.offset;
        result.reason = decoded.result.reason;
        if (result.status != UtfStatus.ok)
            return result;
        const emitted = emitDecoded(decoded.token, destination[result.written .. $]);
        result.status = emitted.status;
        result.required = emitted.required;
        result.reason = emitted.reason;
        if (emitted.status != UtfStatus.ok)
            return result;
        result.consumed += decoded.result.consumed;
        result.written += emitted.written;
        result.required = 0;
    }
}

private UtfResult emitDecoded(D)(UtfToken token, scope D[] destination)
{
    static if (is(D == UtfToken))
    {
        if (!destination.length)
            return UtfResult(UtfStatus.outputFull, 0, 0, token.start, 1);
        destination[0] = token;
        return UtfResult(UtfStatus.ok, 0, 1, token.start, 1);
    }
    else
        return encodeToken(token, destination);
}

enum UtfStreamPhase : ubyte { active, finalized, failed }

/// Caller-owned state; only an incomplete encoding suffix is retained.
struct UtfStream(S) if (isUtfUnit!S)
{
    private S[is(S == char) ? 3 : is(S == wchar) ? 1 : 0] carry_;
    private size_t carryLength_;
    private size_t offset_;
    private UtfMode mode_;
    private UtfStreamPhase phase_;
    private bool pendingFinal_;
    private UtfResult failure_;

    void reset(UtfMode mode = UtfMode.strict) @safe pure nothrow @nogc
    {
        this = typeof(this).init;
        mode_ = mode;
    }
    const(S)[] carry() scope return const @safe pure nothrow @nogc
        => carry_[0 .. carryLength_];
    size_t offset() const @safe pure nothrow @nogc { return offset_; }
    UtfMode mode() const @safe pure nothrow @nogc { return mode_; }
    UtfStreamPhase phase() const @safe pure nothrow @nogc { return phase_; }
    bool pendingFinal() const @safe pure nothrow @nogc { return pendingFinal_; }
    UtfResult failure() const @safe pure nothrow @nogc { return failure_; }
}

UtfResult decodeStream(S)(ref UtfStream!S state, scope const(S)[] source,
    scope UtfToken[] destination, bool isFinal = false) if (isUtfUnit!S)
{
    return streamImpl(state, source, destination, isFinal);
}
UtfResult convertStream(S, D)(ref UtfStream!S state, scope const(S)[] source,
    scope D[] destination, bool isFinal = false) if (isUtfUnit!S && isUtfUnit!D)
{
    return streamImpl(state, source, destination, isFinal);
}

/// Commit at most one decoded token, without looking ahead to a later defect.
/// A final token returns ok; a subsequent final empty feed seals the stream.
UtfResult decodeStreamToken(S)(ref UtfStream!S state, scope const(S)[] source,
    ref UtfToken destination, bool isFinal = false) if (isUtfUnit!S)
{
    auto output = (() @trusted { return (&destination)[0 .. 1]; })();
    return streamImpl!(S, UtfToken, true)(state, source, output, isFinal);
}

private UtfResult streamImpl(S, D, bool oneToken = false)(ref UtfStream!S state,
    scope const(S)[] source, scope D[] destination, bool isFinal)
{
    UtfResult result;
    result.encoding = utfEncoding!S;
    result.offset = state.offset_ - state.carryLength_;
    if (state.phase_ != UtfStreamPhase.active || (state.pendingFinal_ && !isFinal))
    {
        result.status = UtfStatus.invalidState;
        return result;
    }
    if (!validMode!S(state.mode_))
    {
        result.status = UtfStatus.invalidOptions;
        return result;
    }
    if (utfStorageOverlaps(source, destination))
    {
        result.status = UtfStatus.overlap;
        return result;
    }
    // Empty non-final feeds do not change even an active retained suffix.
    if (!source.length && !isFinal)
    {
        result.status = UtfStatus.needInput;
        return result;
    }
    if (isFinal) state.pendingFinal_ = true;
    while (true)
    {
        const origin = state.offset_ - state.carryLength_;
        const remaining = source[result.consumed .. $];
        S[is(S == char) ? 4 : is(S == wchar) ? 2 : 1] joined;
        const(S)[] input = remaining;
        size_t joinedLength;
        if (state.carryLength_)
        {
            joined[0 .. state.carryLength_] = state.carry_[0 .. state.carryLength_];
            joinedLength = state.carryLength_;
            const take = remaining.length < joined.length - joinedLength
                ? remaining.length : joined.length - joinedLength;
            joined[joinedLength .. joinedLength + take] = remaining[0 .. take];
            joinedLength += take;
            input = joined[0 .. joinedLength];
        }
        const decoded = decodeToken(input, state.mode_, isFinal, origin);
        result.status = decoded.result.status;
        result.offset = origin;
        result.reason = decoded.result.reason;
        result.required = 0;
        if (result.status == UtfStatus.needInput)
        {
            const take = input.length - state.carryLength_;
            if (take > size_t.max - state.offset_)
                result.status = UtfStatus.overflow;
            else
            {
                // Every incomplete UTF suffix fits the statically bounded carry.
                state.carry_[0 .. input.length] = input[];
                state.carryLength_ = input.length;
                state.offset_ += take;
                result.consumed += take;
                return result;
            }
        }
        if (result.status == UtfStatus.end)
        {
            state.phase_ = UtfStreamPhase.finalized;
            return result;
        }
        if (result.status == UtfStatus.invalid || result.status == UtfStatus.overflow)
        {
            state.phase_ = UtfStreamPhase.failed;
            state.failure_ = result;
            return result;
        }
        const count = decoded.result.consumed;
        // Replacement/opaque may consume only a prefix of a retained suffix.
        const fromCarry = count < state.carryLength_ ? count : state.carryLength_;
        const fresh = count - fromCarry;
        if (fresh > size_t.max - state.offset_)
        {
            result.status = UtfStatus.overflow;
            state.phase_ = UtfStreamPhase.failed;
            state.failure_ = result;
            return result;
        }
        const emitted = emitDecoded(decoded.token, destination[result.written .. $]);
        result.status = emitted.status;
        result.required = emitted.required;
        result.reason = emitted.reason;
        if (result.status != UtfStatus.ok)
        {
            if (result.status == UtfStatus.invalid)
            {
                state.phase_ = UtfStreamPhase.failed;
                state.failure_ = result;
            }
            return result;
        }
        result.consumed += fresh;
        result.written += emitted.written;
        state.offset_ += fresh;
        const kept = state.carryLength_ - fromCarry;
        foreach (i; 0 .. kept)
            state.carry_[i] = state.carry_[i + fromCarry];
        state.carryLength_ = kept;
        static if (oneToken)
        {
            result.status = UtfStatus.ok;
            result.required = 0;
            return result;
        }
    }
}

@("text.utf.scalarPublishedVectors")
@safe pure nothrow @nogc unittest
{
    static immutable dchar[] scalars = [0, 0x7F, 0x80, 0x7FF, 0x800,
        0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF];
    static immutable string[] bytes = ["\0", "\x7F", "\xC2\x80", "\xDF\xBF",
        "\xE0\xA0\x80", "\xED\x9F\xBF", "\xEE\x80\x80", "\xEF\xBF\xBF",
        "\xF0\x90\x80\x80", "\xF4\x8F\xBF\xBF"];
    foreach (i, scalar; scalars)
    {
        char[5] output = '!';
        foreach (capacity; 0 .. bytes[i].length)
        {
            const result = encodeScalar(scalar, output[0 .. capacity]);
            assert(result.status == UtfStatus.outputFull && result.required == bytes[i].length);
            assert(output[] == "!!!!!");
        }
        const result = encodeScalar(scalar, output[]);
        assert(result.status == UtfStatus.ok && output[0 .. result.written] == bytes[i]);
        assert(output[result.written] == '!');
        const decoded = decodeToken(bytes[i]);
        assert(decoded.result.status == UtfStatus.ok && decoded.token.scalar == scalar);
    }
    foreach (scalar; [cast(dchar) 0xD800, cast(dchar) 0xDFFF, cast(dchar) 0x110000])
    {
        char[4] output = '!';
        const result = encodeScalar(scalar, output[0 .. 0]);
        assert(result.status == UtfStatus.invalid && result.reason == UtfReason.invalidScalar);
        assert(output[] == "!!!!");
        assert(encodeScalar(scalar, output[], UtfMode.replacement).written == 3);
        assert(output[0 .. 3] == "\xEF\xBF\xBD");
    }
    wchar[3] wide = 0xA5A5;
    assert(encodeScalar(cast(dchar) 0x10FFFF, wide[]).written == 2);
    assert(wide[0] == 0xDBFF && wide[1] == 0xDFFF && wide[2] == 0xA5A5);
    assert(decodeToken(wide[0 .. 2]).token.scalar == 0x10FFFF);
    dchar[2] values = 0xA5A5;
    assert(encodeScalar(cast(dchar) 0xFFFF, values[]).written == 1);
    assert(values[0] == 0xFFFF && values[1] == 0xA5A5);
    assert(decodeToken(values[0 .. 1]).token.scalar == 0xFFFF);
}

@("text.utf.maximalSubpartsAndOpaqueSpans")
@safe pure nothrow @nogc unittest
{
    static immutable string[] inputs = ["\xE1\x80A", "\xF0\x90\x80",
        "\xED\xA0\x80", "\xF0\x90A\x80", "\xC2\xC2\xA2"];
    static immutable size_t[][] ends = [[2,3], [3], [1,2,3], [2,3,4], [1,3]];
    static immutable dchar[][] values = [[0xFFFD,'A'], [0xFFFD],
        [0xFFFD,0xFFFD,0xFFFD], [0xFFFD,'A',0xFFFD], [0xFFFD,0xA2]];
    foreach (i, input; inputs)
    {
        UtfToken[4] tokens;
        auto result = decodePrefix(input, tokens[], UtfMode.replacement);
        assert(result.status == UtfStatus.end && result.written == ends[i].length);
        size_t start;
        foreach (j; 0 .. result.written)
        {
            assert(tokens[j].start == start && tokens[j].end == ends[i][j]);
            assert(tokens[j].scalar == values[i][j]);
            start = ends[i][j];
        }
        result = decodePrefix(input, tokens[], UtfMode.opaque);
        assert(result.status == UtfStatus.end);
        char[5] reconstructed = '!';
        size_t written;
        foreach (j; 0 .. result.written)
        {
            const encoded = reconstructToken(tokens[j], reconstructed[written .. $]);
            assert(encoded.status == UtfStatus.ok);
            written += encoded.written;
            if (tokens[j].kind == UtfTokenKind.opaqueByte)
            {
                wchar[2] sentinel = 0xA5A5;
                const rejected = encodeToken(tokens[j], sentinel[0 .. 0]);
                assert(rejected.status == UtfStatus.invalid
                    && rejected.reason == UtfReason.opaqueNotEncodable);
                assert(sentinel[0] == 0xA5A5 && sentinel[1] == 0xA5A5);
            }
        }
        assert(reconstructed[0 .. written] == input);
    }
}

@("text.utf.prefixDefectBeforeCapacity")
@safe pure nothrow @nogc unittest
{
    wchar[2] output = 0xA5A5;
    auto result = convertPrefix("A\xF0\x90", output[], UtfMode.strict, false);
    assert(result.status == UtfStatus.needInput && result.consumed == 1 && result.written == 1);
    assert(output[0] == 'A' && output[1] == 0xA5A5);
    result = convertPrefix("\xF0\x90", output[0 .. 0], UtfMode.strict, false);
    assert(result.status == UtfStatus.needInput && result.consumed == 0);
    result = convertPrefix("\xC0", output[0 .. 0]);
    assert(result.status == UtfStatus.invalid && result.offset == 0);
    result = convertPrefix("\xE0\x80", output[0 .. 0], UtfMode.strict, false);
    assert(result.status == UtfStatus.invalid);
    result = convertPrefix("\xF0\x90", output[0 .. 0], UtfMode.strict, true);
    assert(result.status == UtfStatus.invalid && result.reason == UtfReason.truncated);
    result = convertPrefix("\xF0\x90", output[], UtfMode.replacement, true);
    assert(result.status == UtfStatus.end && result.consumed == 2 && output[0] == 0xFFFD);
}

@("text.utf.streamCarryBackpressureAndFinalIntent")
@safe pure nothrow @nogc unittest
{
    UtfStream!char state;
    wchar[3] output = 0xA5A5;
    auto result = convertStream(state, "A\xF0", output[]);
    assert(result.status == UtfStatus.needInput && result.consumed == 2 && result.written == 1);
    assert(state.carry == "\xF0" && state.offset == 2 && output[0] == 'A');
    result = convertStream(state, "\x90\x80", output[]);
    assert(result.status == UtfStatus.needInput && result.consumed == 2 && result.written == 0);
    assert(state.carry == "\xF0\x90\x80" && state.offset == 4);
    result = convertStream(state, "", output[]);
    assert(result.status == UtfStatus.needInput && state.offset == 4 && state.carry.length == 3);
    output[] = 0xA5A5;
    result = convertStream(state, "\x80B", output[0 .. 1], true);
    assert(result.status == UtfStatus.outputFull && result.consumed == 0 && result.written == 0);
    assert(result.offset == 1 && result.required == 2 && state.carry.length == 3);
    assert(output[0] == 0xA5A5 && state.pendingFinal);
    result = convertStream(state, "", output[], false);
    assert(result.status == UtfStatus.invalidState && state.carry.length == 3);
    result = convertStream(state, "\x80B", output[0 .. 2], true);
    assert(result.status == UtfStatus.outputFull && result.consumed == 1 && result.written == 2);
    assert(output[0] == 0xD800 && output[1] == 0xDC00 && state.carry.length == 0);
    result = convertStream(state, "B", output[2 .. 3], true);
    assert(result.status == UtfStatus.end && result.consumed == 1 && output[2] == 'B');
    result = convertStream(state, "", output[]);
    assert(result.status == UtfStatus.invalidState && state.phase == UtfStreamPhase.finalized);
    state.reset();
    assert(state.offset == 0 && state.carry.length == 0 && !state.pendingFinal);
    result = convertStream(state, "\xE1\x80", output[]);
    assert(result.status == UtfStatus.needInput && result.consumed == 2);
    result = convertStream(state, "", output[], true);
    assert(result.status == UtfStatus.invalid && result.offset == 0 && state.carry.length == 2);
    assert(state.failure.reason == UtfReason.truncated && state.phase == UtfStreamPhase.failed);
    assert(convertStream(state, "", output[]).status == UtfStatus.invalidState);
    state.reset(UtfMode.replacement);
    assert(convertStream(state, "\xE1\x80", output[]).status == UtfStatus.needInput);
    result = convertStream(state, "A", output[], true);
    assert(result.status == UtfStatus.end && result.consumed == 1 && result.written == 2);
    assert(output[0] == 0xFFFD && output[1] == 'A');
}

@("text.utf.streamEveryScalarSplit")
@safe pure nothrow @nogc unittest
{
    static immutable string[] input = ["\xC2\x80", "\xE0\xA0\x80", "\xF0\x90\x80\x80"];
    static immutable dchar[] expected = [0x80, 0x800, 0x10000];
    foreach (i, bytes; input)
        foreach (partition; 0 .. (1 << (bytes.length - 1)))
        {
            UtfStream!char state;
            dchar[1] output = 0xA5A5;
            size_t start;
            foreach (end; 1 .. bytes.length + 1)
                if (end == bytes.length || (partition & (1 << (end - 1))))
                {
                    const result = convertStream(state, bytes[start .. end], output[], end == bytes.length);
                    assert(result.consumed == end - start);
                    if (end == bytes.length)
                        assert(result.status == UtfStatus.end && result.written == 1 && output[0] == expected[i]);
                    else
                        assert(result.status == UtfStatus.needInput && result.written == 0 && output[0] == 0xA5A5);
                    start = end;
                }
        }
    UtfStream!wchar wide;
    immutable wchar[2] pair = [0xD800, 0xDC00];
    char[4] bytes = '!';
    auto result = convertStream(wide, pair[0 .. 1], bytes[]);
    assert(result.status == UtfStatus.needInput && result.consumed == 1 && wide.carry.length == 1);
    result = convertStream(wide, pair[1 .. 2], bytes[0 .. 3], true);
    assert(result.status == UtfStatus.outputFull && result.consumed == 0 && bytes[] == "!!!!");
    result = convertStream(wide, pair[1 .. 2], bytes[], true);
    assert(result.status == UtfStatus.end && result.consumed == 1 && bytes[] == "\xF0\x90\x80\x80");
}

@("text.utf.checkedCountsAndStreamOverflow")
@safe pure nothrow @nogc unittest
{
    size_t count = size_t.max - 1;
    assert(addUtfCount(count, 1) && count == size_t.max);
    assert(!addUtfCount(count, 1) && count == size_t.max);
    UtfStream!char state;
    state.offset_ = size_t.max;
    wchar[1] output = 0xA5A5;
    const result = convertStream(state, "A", output[], true);
    assert(result.status == UtfStatus.overflow && result.consumed == 0 && result.written == 0);
    assert(output[0] == 0xA5A5 && state.phase == UtfStreamPhase.failed);
}

@("text.utf.maximalSubpartLeadWindows")
@safe pure nothrow @nogc unittest
{
    // Unicode Table 3-7 expressed as prefix windows, independently of decoder
    // control flow. A prefix ending at the second byte consumes both units;
    // excluded second bytes leave a one-byte maximal subpart.
    static immutable ubyte[5][] windows = [
        [0xC2,0xDF,0x80,0xBF,2], [0xE0,0xE0,0xA0,0xBF,3],
        [0xE1,0xEC,0x80,0xBF,3], [0xED,0xED,0x80,0x9F,3],
        [0xEE,0xEF,0x80,0xBF,3], [0xF0,0xF0,0x90,0xBF,4],
        [0xF1,0xF3,0x80,0xBF,4], [0xF4,0xF4,0x80,0x8F,4],
    ];
    foreach (first; 0 .. 256)
    {
        char[1] input = [cast(char) first];
        bool potential;
        foreach (window; windows)
            potential |= first >= window[0] && first <= window[1];
        const decoded = decodeToken(input[], UtfMode.replacement);
        assert(decoded.result.status == UtfStatus.ok && decoded.result.consumed == 1);
        assert(decoded.token.scalar == (first < 0x80 ? first : 0xFFFD));
        const prefix = decodeToken(input[], UtfMode.strict, false);
        assert(prefix.result.status == (first < 0x80 ? UtfStatus.ok
            : potential ? UtfStatus.needInput : UtfStatus.invalid));
    }
    foreach (first; 0 .. 256)
        foreach (second; 0 .. 256)
        {
            char[2] input = [cast(char) first, cast(char) second];
            bool allowed;
            size_t length;
            foreach (window; windows)
                if (first >= window[0] && first <= window[1])
                {
                    allowed = second >= window[2] && second <= window[3];
                    length = window[4];
                }
            const decoded = decodeToken(input[], UtfMode.replacement);
            const expected = first < 0x80 ? 1 : allowed ? 2 : 1;
            assert(decoded.result.status == UtfStatus.ok && decoded.result.consumed == expected);
            assert(decoded.token.start == 0 && decoded.token.end == expected);
            if (first >= 0x80)
                assert(decoded.token.kind == (allowed && length == 2
                    ? UtfTokenKind.scalar : UtfTokenKind.replacement));
            const prefix = decodeToken(input[], UtfMode.strict, false);
            const status = first < 0x80 || (allowed && length == 2)
                ? UtfStatus.ok : allowed ? UtfStatus.needInput : UtfStatus.invalid;
            assert(prefix.result.status == status);
        }
}

@("text.utf.streamMalformedCarrySplits")
@safe pure nothrow @nogc unittest
{
    // Every partition of the worked malformed traces must retain source spans,
    // including a maximal subpart whose final continuation arrives next call.
    static immutable string[] inputs = ["\xE1\x80A", "\xF0\x90\x80",
        "\xED\xA0\x80", "\xF0\x90A\x80", "\xC2\xC2\xA2"];
    static immutable size_t[][] ends = [[2,3], [3], [1,2,3], [2,3,4], [1,3]];
    static immutable dchar[][] values = [[0xFFFD,'A'], [0xFFFD],
        [0xFFFD,0xFFFD,0xFFFD], [0xFFFD,'A',0xFFFD], [0xFFFD,0xA2]];
    foreach (i, input; inputs)
        foreach (partition; 0 .. (1 << (input.length - 1)))
        {
            UtfStream!char state;
            state.reset(UtfMode.replacement);
            UtfToken[4] output;
            size_t start, written;
            foreach (end; 1 .. input.length + 1)
                if (end == input.length || (partition & (1 << (end - 1))))
                {
                    const result = decodeStream(state, input[start .. end],
                        output[written .. $], end == input.length);
                    assert(result.consumed == end - start);
                    assert(result.status == (end == input.length ? UtfStatus.end : UtfStatus.needInput));
                    written += result.written;
                    start = end;
                }
            assert(written == ends[i].length && state.carry.length == 0);
            start = 0;
            foreach (j; 0 .. written)
            {
                assert(output[j].start == start && output[j].end == ends[i][j]);
                assert(output[j].scalar == values[i][j]);
                start = ends[i][j];
            }
        }
    // Opaque decoding may need to drain individual bytes already in carry.
    UtfStream!char state;
    state.reset(UtfMode.opaque);
    UtfToken[3] output;
    assert(decodeStream(state, "\xF0\x90", output[]).consumed == 2);
    auto result = decodeStream(state, "A", output[0 .. 1], true);
    assert(result.status == UtfStatus.outputFull && result.consumed == 0 && result.written == 1);
    assert(output[0].kind == UtfTokenKind.opaqueByte && output[0].byteValue == 0xF0);
    assert(state.carry == "\x90" && result.offset == 1);
    result = decodeStream(state, "A", output[1 .. 3], true);
    assert(result.status == UtfStatus.end && result.consumed == 1 && result.written == 2);
    assert(output[1].byteValue == 0x90 && output[1].start == 1 && output[2].scalar == 'A');
}

import sparkles.test_runner.attributes : ctfe;

@("text.utf.ctfeTokenCarryAndCapacity")
@ctfe @safe pure nothrow @nogc unittest
{
    UtfStream!char state;
    wchar[3] wide = 0xA5A5;
    auto result = convertStream(state, "\xF0\x90", wide[]);
    assert(result.status == UtfStatus.needInput && state.carry == "\xF0\x90");
    result = convertStream(state, "\x80\x80", wide[0 .. 1], true);
    assert(result.status == UtfStatus.outputFull && result.consumed == 0 && wide[0] == 0xA5A5);
    result = convertStream(state, "\x80\x80", wide[], true);
    assert(result.status == UtfStatus.end && result.written == 2);
    assert(wide[0] == 0xD800 && wide[1] == 0xDC00 && wide[2] == 0xA5A5);
    const decoded = decodeToken("\xED\xA0\x80", UtfMode.replacement);
    assert(decoded.token.scalar == 0xFFFD && decoded.token.end == 1);
}

@("text.utf.streamTokenStopsBeforeLaterDefect")
@safe pure nothrow @nogc unittest
{
    UtfStream!char state;
    UtfToken token;
    auto result = decodeStreamToken(state, "A\xC0", token, true);
    assert(result.status == UtfStatus.ok && result.consumed == 1 && result.written == 1);
    assert(token.scalar == 'A' && token.start == 0 && token.end == 1);
    assert(state.phase == UtfStreamPhase.active && state.pendingFinal);
    const previous = token;
    result = decodeStreamToken(state, "\xC0", token, true);
    assert(result.status == UtfStatus.invalid && result.offset == 1 && result.consumed == 0);
    assert(token == previous && state.phase == UtfStreamPhase.failed);
    state.reset();
    result = decodeStreamToken(state, "A", token, true);
    assert(result.status == UtfStatus.ok && state.phase == UtfStreamPhase.active);
    result = decodeStreamToken(state, "", token, true);
    assert(result.status == UtfStatus.end && state.phase == UtfStreamPhase.finalized);
}
