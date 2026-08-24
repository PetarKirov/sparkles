/** Canonical semantic emission for SDL scalar values. */
module sparkles.wired.sdl.writer;

import core.time : Duration;
import std.datetime.date : Date;
import std.range.primitives : put;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.wired.json.writer : writeJsonDouble, writeJsonLong;
import sparkles.wired.sdl.decimal : sdlDecimalSignificantDigits;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.error;

/// Owning text returned by SDL convenience APIs.
alias SdlString = SmallBuffer!(char, 256);

/// Canonical document-writer options, used by the later document milestone.
struct SdlWriteOptions
{
    string indent = "    ";
    bool newlineForEmptyDocument;
}

private SdlError encodeError(SdlErrorCode code, string type, string reason)
    @safe pure nothrow @nogc
{
    SdlError failure;
    failure.stage = SdlErrorStage.encode;
    failure.code = code;
    failure.sourceType = type;
    failure.reason = reason;
    return failure;
}

private string scalarType(SdlScalarKind kind) @safe pure nothrow @nogc
{
    final switch (kind) with (SdlScalarKind)
    {
    case none:
        return "invalid SDL scalar";
    case null_:
        return "null";
    case boolean:
        return "bool";
    case string_:
        return "string";
    case character:
        return "dchar";
    case integer:
        return "int";
    case longInteger:
        return "long";
    case float_:
        return "float";
    case double_:
        return "double";
    case decimal:
        return "real";
    case binary:
        return "ubyte[]";
    case date:
        return "Date";
    case dateTime:
        return "SdlDateTime";
    case zonedDateTime:
        return "SdlZonedDateTime";
    case duration:
        return "Duration";
    }
}

private bool containsUnquotedLineSeparator(scope const(char)[] value)
    @safe pure nothrow @nogc
{
    foreach (i; 0 .. value.length)
        if (i + 2 < value.length && cast(ubyte) value[i] == 0xE2
            && cast(ubyte) value[i + 1] == 0x80
            && (cast(ubyte) value[i + 2] == 0xA8
                || cast(ubyte) value[i + 2] == 0xA9))
            return true;
    return false;
}

private SdlExpected!void validateString(scope const(char)[] value)
    @safe pure nothrow @nogc
{
    import sparkles.base.text.utf8 : indexOfInvalidUtf8;

    if (indexOfInvalidUtf8(value) != value.length)
        return sdlErr!void(encodeError(SdlErrorCode.invalidUtf8, "string",
            "string is not well-formed UTF-8"));
    if (containsUnquotedLineSeparator(value))
        return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange, "string",
            "U+2028 and U+2029 are not representable in canonical SDL strings"));
    foreach (c; value)
        if (c < 0x20 && c != '\n' && c != '\r' && c != '\t')
            return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange,
                "string", "control character has no canonical SDL escape"));
    return sdlOk();
}

private void writeSdlString(Writer)(ref Writer writer, scope const(char)[] value)
{
    put(writer, '"');
    size_t runStart;
    foreach (i, c; value)
    {
        if (c != '"' && c != '\\' && c != '\n' && c != '\r' && c != '\t')
            continue;
        if (i > runStart)
            put(writer, value[runStart .. i]);
        runStart = i + 1;
        final switch (c)
        {
        case '"':
            put(writer, `\"`);
            break;
        case '\\':
            put(writer, `\\`);
            break;
        case '\n':
            put(writer, `\n`);
            break;
        case '\r':
            put(writer, `\r`);
            break;
        case '\t':
            put(writer, `\t`);
            break;
        }
    }
    if (runStart < value.length)
        put(writer, value[runStart .. $]);
    put(writer, '"');
}

private SdlExpected!void writeSdlCharacter(Writer)(dchar value,
    ref Writer writer)
{
    import sparkles.base.text.utf : encodeUtf8;
    import std.utf : isValidDchar;

    if (!isValidDchar(value) || value == 0x2028 || value == 0x2029)
        return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange, "dchar",
            "character is not representable in a canonical SDL literal"));

    put(writer, '\'');
    switch (value)
    {
    case '\n':
        put(writer, `\n`);
        break;
    case '\r':
        put(writer, `\r`);
        break;
    case '\t':
        put(writer, `\t`);
        break;
    case '\'':
        put(writer, `\'`);
        break;
    case '\\':
        put(writer, `\\`);
        break;
    default:
        char[4] encoded = void;
        const length = encodeUtf8(value, encoded);
        put(writer, encoded[0 .. length]);
        break;
    }
    put(writer, '\'');
    return sdlOk();
}

private int parseExponent(scope const(char)[] value) @safe pure nothrow @nogc
{
    bool negative;
    size_t i;
    if (value.length && (value[0] == '+' || value[0] == '-'))
    {
        negative = value[0] == '-';
        i++;
    }
    int result;
    foreach (c; value[i .. $])
        result = result * 10 + c - '0';
    return negative ? -result : result;
}

/** Writes a finite `%g`/JSON decimal without exponent notation.

SDL deliberately has no exponent grammar. The source text is already a
shortest round-tripping decimal; moving its point and adding zeroes preserves
that significand exactly.
*/
private void writeFixedDecimal(Writer)(ref Writer writer,
    scope const(char)[] value)
{
    size_t expAt = value.length;
    foreach (i, c; value)
        if (c == 'e' || c == 'E')
        {
            expAt = i;
            break;
        }
    if (expAt == value.length)
    {
        put(writer, value);
        return;
    }

    const negative = value[0] == '-';
    const start = negative ? 1 : 0;
    size_t dotAt = expAt;
    foreach (i; start .. expAt)
        if (value[i] == '.')
        {
            dotAt = i;
            break;
        }

    char[64] digits = void;
    size_t digitCount;
    foreach (i; start .. expAt)
        if (value[i] != '.')
            digits[digitCount++] = value[i];
    const digitsBeforeDot = cast(int)(dotAt == expAt
        ? digitCount : dotAt - start);
    const decimalPos = digitsBeforeDot + parseExponent(value[expAt + 1 .. $]);

    if (negative)
        put(writer, '-');
    if (decimalPos <= 0)
    {
        put(writer, "0.");
        foreach (_; 0 .. -decimalPos)
            put(writer, '0');
        put(writer, digits[0 .. digitCount]);
    }
    else if (decimalPos >= digitCount)
    {
        put(writer, digits[0 .. digitCount]);
        foreach (_; digitCount .. decimalPos)
            put(writer, '0');
    }
    else
    {
        put(writer, digits[0 .. decimalPos]);
        put(writer, '.');
        put(writer, digits[decimalPos .. digitCount]);
    }
}

private SdlExpected!void writeDouble(Writer)(double value, ref Writer writer)
{
    import std.math : isFinite;

    if (!isFinite(value))
        return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange, "double",
            "NaN and infinity are not representable in SDL"));

    // Reuse wired.json's measured shortest-binary64 emitter, then adapt its
    // notation only when JSON chose an exponent SDL cannot spell.
    SmallBuffer!(char, 40) token;
    writeJsonDouble(token, value);
    writeFixedDecimal(writer, token[]);
    put(writer, 'D');
    return sdlOk();
}

/** Whether the canonical text `emitted` decodes back to `value` through the
kernel the SDL reader actually uses.

This is the round-trip predicate behind SPEC §10 LAW 3 for `float` and
`real`: `readDecimalFloat` is the lexer's binary64 path (`float` narrows from
it), and `parseDecimalReal` is its `decimal` path.
*/
private bool roundTripsAsWritten(T)(scope const(char)[] emitted, T value)
    @safe pure nothrow @nogc
if (is(T == float) || is(T == real))
{
    static if (is(T == float))
    {
        import sparkles.base.text.float_conv : readDecimalFloat;

        scope const(char)[] input = emitted;
        auto parsed = readDecimalFloat(input);
        if (parsed.hasError || input.length)
            return false;
        return cast(float) parsed.value is value;
    }
    else
    {
        import sparkles.wired.sdl.decimal : parseDecimalReal;

        return parseDecimalReal(emitted) is value;
    }
}

private SdlExpected!void writeShortestGeneric(T, Writer)(T value,
    ref Writer writer, string suffix)
if (is(T == float) || is(T == real))
{
    import std.format : formattedWrite;
    import std.math : isFinite;

    if (!isFinite(value))
        return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange,
            T.stringof, "NaN and infinity are not representable in SDL"));

    // The search must be able to reach a spelling the *reader's* kernel maps
    // back onto `value`. For `real` that is the kernel's own resolution:
    // `parseDecimalReal` is within an ulp rather than correctly rounded, so
    // the shortest spelling is occasionally a few digits longer than
    // max_digits10, and past its capture width no spelling can differ.
    // `float` decodes through the correctly rounded `readDecimalFloat`, where
    // max_digits10 plus a guard digit for Phobos' `%g` boundary behaviour
    // near min_normal is enough.
    static if (is(T == real))
        enum maxDigits = sdlDecimalSignificantDigits;
    else
        enum maxDigits = (T.mant_dig * 30_103 + 99_999) / 100_000 + 2;
    try
    {
        foreach (precision; 1 .. maxDigits + 1)
        {
            SmallBuffer!(char, 128) candidate;
            formattedWrite(candidate, "%.*g", precision, value);

            // Test the bytes that will actually be emitted, decoded by the
            // very routine the lexer uses. Asking a third algorithm
            // (`std.conv.to!real`, which is not correctly rounded for x87
            // 80-bit) whether a spelling round-trips both rejects reals that
            // are perfectly representable and lets through spellings this
            // backend would decode differently.
            SmallBuffer!(char, 160) emitted;
            writeFixedDecimal(emitted, candidate[]);
            if (roundTripsAsWritten!T(emitted[], value))
            {
                put(writer, emitted[]);
                put(writer, suffix);
                return sdlOk();
            }
        }
    }
    catch (Exception)
        return sdlErr!void(encodeError(SdlErrorCode.allocationFailed,
            T.stringof, "could not format the floating-point value"));

    return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange,
        T.stringof, "could not find a round-tripping decimal representation"));
}

private void writeDate(Writer)(ref Writer writer, Date value)
{
    writeJsonLong(writer, value.year);
    put(writer, '/');
    writeJsonLong(writer, cast(int) value.month);
    put(writer, '/');
    writeJsonLong(writer, value.day);
}

private void writePadded2(Writer)(ref Writer writer, uint value)
{
    put(writer, cast(char)('0' + value / 10));
    put(writer, cast(char)('0' + value % 10));
}

private SdlExpected!void validateDateTime(in SdlDateTime value)
    @safe pure nothrow @nogc
{
    if (value.hour >= 24 || value.minute >= 60 || value.second >= 60)
        return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
            "SdlDateTime", "clock fields are outside their civil ranges"));
    if (value.fractionHnsecs >= 10_000_000
        || value.fractionHnsecs % 10_000 != 0)
        return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
            "SdlDateTime", "date-time fraction must contain 1-3 decimal digits"));
    return sdlOk();
}

private void writeFraction(Writer)(ref Writer writer, uint fractionHnsecs)
{
    if (fractionHnsecs == 0)
        return;
    char[7] digits = void;
    auto value = fractionHnsecs;
    foreach_reverse (i; 0 .. digits.length)
    {
        digits[i] = cast(char)('0' + value % 10);
        value /= 10;
    }
    size_t length = digits.length;
    while (length > 0 && digits[length - 1] == '0')
        length--;
    put(writer, '.');
    put(writer, digits[0 .. length]);
}

private void writeDateTime(Writer)(ref Writer writer, in SdlDateTime value)
{
    writeDate(writer, value.date);
    put(writer, ' ');
    writePadded2(writer, value.hour);
    put(writer, ':');
    writePadded2(writer, value.minute);
    put(writer, ':');
    writePadded2(writer, value.second);
    writeFraction(writer, value.fractionHnsecs);
}

private SdlExpected!void writeZone(Writer)(in SdlZonedDateTime value,
    ref Writer writer)
{
    if (value.zone.length)
    {
        auto valid = validateString(value.zone);
        if (valid.hasError)
            return valid;
        foreach (c; value.zone)
            if (c <= ' ' || c == ';' || c == '{' || c == '}')
                return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
                    "SdlZonedDateTime", "zone spelling is not an SDL zone token"));
        put(writer, value.zone);
        return sdlOk();
    }
    if (!value.hasUtcOffset)
        return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
            "SdlZonedDateTime", "zoned date-time has neither a zone nor an offset"));

    const raw = value.utcOffset.total!"hnsecs";
    if (raw % 600_000_000 != 0)
        return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
            "SdlZonedDateTime", "UTC offset must be an exact number of minutes"));
    const negative = raw < 0;
    const magnitude = negative ? 0UL - cast(ulong) raw : cast(ulong) raw;
    const minutes = magnitude / 600_000_000;
    if (minutes > 23 * 60 + 59)
        return sdlErr!void(encodeError(SdlErrorCode.invalidDateTime,
            "SdlZonedDateTime", "UTC offset exceeds SDL's GMT range"));
    put(writer, negative ? "GMT-" : "GMT+");
    writePadded2(writer, cast(uint)(minutes / 60));
    put(writer, ':');
    writePadded2(writer, cast(uint)(minutes % 60));
    return sdlOk();
}

private void writeDuration(Writer)(Duration duration, ref Writer writer)
{
    const raw = duration.total!"hnsecs";
    const negative = raw < 0;
    ulong remaining = negative ? 0UL - cast(ulong) raw : cast(ulong) raw;
    enum ulong perSecond = 10_000_000;
    enum ulong perMinute = 60 * perSecond;
    enum ulong perHour = 60 * perMinute;
    enum ulong perDay = 24 * perHour;

    if (negative)
        put(writer, '-');
    const days = remaining / perDay;
    remaining %= perDay;
    if (days)
    {
        writeJsonLong(writer, cast(long) days);
        put(writer, "d:");
    }
    writePadded2(writer, cast(uint)(remaining / perHour));
    remaining %= perHour;
    put(writer, ':');
    writePadded2(writer, cast(uint)(remaining / perMinute));
    remaining %= perMinute;
    put(writer, ':');
    writePadded2(writer, cast(uint)(remaining / perSecond));
    writeFraction(writer, cast(uint)(remaining % perSecond));
}

/// Writes one scalar in canonical SDL syntax.
SdlExpected!void writeSdlScalar(Writer)(scope const ref SdlScalar scalar,
    ref Writer writer)
{
    final switch (scalar.kind) with (SdlScalarKind)
    {
    case none:
        return sdlErr!void(encodeError(SdlErrorCode.unexpectedKind,
            scalarType(scalar.kind), "cannot write an invalid scalar"));
    case null_:
        put(writer, "null");
        break;
    case boolean:
        put(writer, scalar.boolean ? "true" : "false");
        break;
    case string_:
        {
            auto valid = validateString(scalar.stringValue);
            if (valid.hasError)
                return valid;
            writeSdlString(writer, scalar.stringValue);
            break;
        }
    case character:
        return writeSdlCharacter(scalar.character, writer);
    case integer:
        writeJsonLong(writer, scalar.integer);
        break;
    case longInteger:
        writeJsonLong(writer, scalar.longInteger);
        put(writer, 'L');
        break;
    case float_:
        return writeShortestGeneric(scalar.floatValue, writer, "F");
    case double_:
        return writeDouble(scalar.doubleValue, writer);
    case decimal:
        return writeShortestGeneric(scalar.decimalValue, writer, "BD");
    case binary:
        {
            import sparkles.base.text.base_codecs : encodeBase64;

            put(writer, '[');
            encodeBase64(writer, scalar.binary);
            put(writer, ']');
            break;
        }
    case date:
        writeDate(writer, scalar.date);
        break;
    case dateTime:
        {
            const value = scalar.dateTime;
            auto valid = validateDateTime(value);
            if (valid.hasError)
                return valid;
            writeDateTime(writer, value);
            break;
        }
    case zonedDateTime:
        {
            const value = scalar.zonedDateTime;
            auto valid = validateDateTime(value.local);
            if (valid.hasError)
                return valid;
            // Validate both parts before writing to avoid a partial scalar on
            // the SDL-specific semantic error paths.
            SdlString zone;
            auto zoneResult = writeZone(value, zone);
            if (zoneResult.hasError)
                return zoneResult;
            writeDateTime(writer, value.local);
            put(writer, '-');
            put(writer, zone[]);
            break;
        }
    case duration:
        writeDuration(scalar.duration, writer);
        break;
    }
    return sdlOk();
}

version (unittest)
{
    private long parseSignedHarness(scope const(char)[] token)
    {
        import std.conv : to;

        return token.to!long;
    }

    private uint parsePartHarness(scope const(char)[] token, ref size_t at,
        char delimiter)
    {
        uint value;
        while (at < token.length && token[at] != delimiter)
        {
            assert('0' <= token[at] && token[at] <= '9');
            value = value * 10 + token[at++] - '0';
        }
        assert(at < token.length && token[at] == delimiter);
        at++;
        return value;
    }

    private SdlDateTime parseDateTimeHarness(scope const(char)[] token,
        ref size_t at)
    {
        const year = cast(int) parsePartHarness(token, at, '/');
        const month = parsePartHarness(token, at, '/');
        const day = parsePartHarness(token, at, ' ');
        const hour = parsePartHarness(token, at, ':');
        const minute = parsePartHarness(token, at, ':');
        uint second;
        while (at < token.length && '0' <= token[at] && token[at] <= '9')
            second = second * 10 + token[at++] - '0';

        uint fraction;
        uint digits;
        if (at < token.length && token[at] == '.')
        {
            at++;
            while (at < token.length && '0' <= token[at] && token[at] <= '9')
            {
                fraction = fraction * 10 + token[at++] - '0';
                digits++;
            }
            foreach (_; digits .. 7)
                fraction *= 10;
        }
        return SdlDateTime(Date(year, cast(int) month, cast(int) day), cast(ubyte) hour,
            cast(ubyte) minute, cast(ubyte) second, fraction);
    }

    private Duration parseDurationHarness(scope const(char)[] token)
    {
        import core.time : hnsecs;

        size_t at;
        const negative = token[0] == '-';
        at += negative;
        ulong first;
        while (token[at] != ':' && token[at] != 'd')
            first = first * 10 + token[at++] - '0';
        ulong days;
        ulong hours = first;
        if (token[at] == 'd')
        {
            days = first;
            at += 2;
            hours = parsePartHarness(token, at, ':');
        }
        else
            at++;
        const minutes = parsePartHarness(token, at, ':');
        ulong seconds;
        while (at < token.length && token[at] != '.')
            seconds = seconds * 10 + token[at++] - '0';
        ulong fraction;
        size_t digits;
        if (at < token.length)
        {
            at++;
            while (at < token.length)
            {
                fraction = fraction * 10 + token[at++] - '0';
                digits++;
            }
            foreach (_; digits .. 7)
                fraction *= 10;
        }
        ulong raw = (((days * 24 + hours) * 60 + minutes) * 60 + seconds)
            * 10_000_000 + fraction;
        const signed = negative ? -cast(long) raw : cast(long) raw;
        return signed.hnsecs;
    }

    private SdlString unescapeHarness(scope const(char)[] token)
    {
        SdlString result;
        size_t i = 1;
        while (i < token.length - 1)
        {
            if (token[i] != '\\')
            {
                put(result, token[i++]);
                continue;
            }
            i++;
            final switch (token[i])
            {
            case 'n': put(result, '\n'); break;
            case 'r': put(result, '\r'); break;
            case 't': put(result, '\t'); break;
            case '\\': put(result, '\\'); break;
            case '"': put(result, '"'); break;
            case '\'': put(result, '\''); break;
            }
            i++;
        }
        return result;
    }

    private SdlString renderScalar(SdlScalar scalar)
    {
        SdlString result;
        auto written = writeSdlScalar(scalar, result);
        assert(!written.hasError);
        return result;
    }

    private T parseFixedHarness(T)(scope const(char)[] token)
    if (is(T == float) || is(T == real))
    {
        import std.conv : to;

        const start = token.length && token[0] == '-' ? 1 : 0;
        size_t dotAt = token.length;
        size_t first = token.length;
        size_t last = start;
        size_t leadingZeros;
        foreach (i; start .. token.length)
        {
            if (token[i] == '.')
            {
                dotAt = i;
                continue;
            }
            if (first == token.length)
            {
                if (token[i] == '0')
                    leadingZeros++;
                else
                    first = i;
            }
            if (token[i] != '0')
                last = i;
        }
        if (first == token.length)
            return token.to!T;

        const digitsBeforeDot = dotAt == token.length
            ? token.length - start : dotAt - start;
        SdlString scientific;
        if (start)
            put(scientific, '-');
        put(scientific, token[first]);
        bool wroteDot;
        foreach (i; first + 1 .. last + 1)
        {
            if (token[i] == '.')
                continue;
            if (!wroteDot)
            {
                put(scientific, '.');
                wroteDot = true;
            }
            put(scientific, token[i]);
        }
        put(scientific, 'e');
        writeJsonLong(scientific,
            cast(long) digitsBeforeDot - cast(long) leadingZeros - 1);
        return scientific[].to!T;
    }

    private void checkScalarHarness(scope const ref SdlScalar original,
        scope const(char)[] token)
    {
        import core.time : minutes;

        final switch (original.kind) with (SdlScalarKind)
        {
        case none:
            assert(false, "the writer must reject the sentinel kind");
        case null_:
            assert(token == "null");
            break;
        case boolean:
            assert((token == "true") == original.boolean);
            break;
        case string_:
            assert(unescapeHarness(token)[] == original.stringValue);
            break;
        case character:
            {
                import std.utf : decode;

                auto decoded = unescapeHarness(token);
                size_t at;
                const value = decode(decoded[], at);
                assert(value == original.character && at == decoded.length);
                break;
            }
        case integer:
            assert(parseSignedHarness(token) == original.integer);
            break;
        case longInteger:
            assert(parseSignedHarness(token[0 .. $ - 1]) == original.longInteger);
            break;
        case float_:
            assert(parseFixedHarness!float(token[0 .. $ - 1])
                is original.floatValue);
            break;
        case double_:
            {
                import sparkles.base.text.float_conv : readDecimalFloat;

                scope const(char)[] input = token[0 .. $ - 1];
                auto parsed = readDecimalFloat(input);
                assert(parsed.hasValue && input.length == 0);
                assert(parsed.value is original.doubleValue);
                break;
            }
        case decimal:
            {
                import sparkles.wired.sdl.decimal : parseDecimalReal;

                assert(parseDecimalReal(token[0 .. $ - 2])
                    is original.decimalValue);
                break;
            }
        case binary:
            {
                import sparkles.base.text.base_codecs : decodeBase64;

                SmallBuffer!(ubyte, 64) decoded;
                auto parsed = decodeBase64(decoded, token[1 .. $ - 1]);
                assert(parsed.hasValue && decoded[] == original.binary);
                break;
            }
        case date:
            {
                size_t at;
                const year = cast(int) parsePartHarness(token, at, '/');
                const month = parsePartHarness(token, at, '/');
                const day = parseSignedHarness(token[at .. $]);
                assert(Date(year, cast(int) month, cast(int) day) == original.date);
                break;
            }
        case dateTime:
            {
                size_t at;
                assert(parseDateTimeHarness(token, at) == original.dateTime);
                assert(at == token.length);
                break;
            }
        case zonedDateTime:
            {
                size_t at;
                const local = parseDateTimeHarness(token, at);
                assert(local == original.zonedDateTime.local);
                assert(at < token.length && token[at++] == '-');
                const zone = token[at .. $];
                if (original.zonedDateTime.zone.length)
                    assert(zone == original.zonedDateTime.zone);
                else
                {
                    assert(zone[0 .. 3] == "GMT");
                    const negative = zone[3] == '-';
                    at = 4;
                    const hours = parsePartHarness(zone, at, ':');
                    const minuteCount = parseSignedHarness(zone[at .. $]);
                    auto offset = (hours * 60 + minuteCount).minutes;
                    if (negative)
                        offset = -offset;
                    assert(original.zonedDateTime.hasUtcOffset
                        && offset == original.zonedDateTime.utcOffset);
                }
                break;
            }
        case duration:
            assert(parseDurationHarness(token) == original.duration);
            break;
        }
    }

    private void checkScalar(SdlScalar scalar, string expected)
    {
        import sparkles.base.smallbuffer : checkWriter;

        checkWriter!((ref writer) {
            auto result = writeSdlScalar(scalar, writer);
            assert(!result.hasError);
        })(expected);
        checkScalarHarness(scalar, expected);
    }

    private void checkFloatingRoundTrip(T)(T value)
    if (is(T == float) || is(T == double) || is(T == real))
    {
        static if (is(T == float))
        {
            auto rendered = renderScalar(SdlScalar(value));
            enum suffixLength = 1;
        }
        else static if (is(T == double))
        {
            auto rendered = renderScalar(SdlScalar(value));
            enum suffixLength = 1;
        }
        else
        {
            auto rendered = renderScalar(SdlScalar.decimal(value));
            enum suffixLength = 2;
        }
        const token = rendered[][0 .. $ - suffixLength];

        // Each kind is checked against the kernel the SDL *reader* uses, not
        // against `std.conv`: `to!real` is not correctly rounded for x87
        // 80-bit, so validating `real` through it asserts a round trip this
        // backend never performs (and rejects spellings that do round-trip).
        static if (is(T == double))
        {
            import sparkles.base.text.float_conv : readDecimalFloat;

            scope const(char)[] input = token;
            auto parsed = readDecimalFloat(input);
            assert(parsed.hasValue && input.length == 0);
            assert(parsed.value is value);
        }
        else static if (is(T == real))
        {
            import sparkles.wired.sdl.decimal : parseDecimalReal;

            assert(parseDecimalReal(token) is value);
        }
        else
        {
            assert(parseFixedHarness!T(token) is value);
        }
    }
}

@("sdl.writer.scalarPrimitives")
@system unittest
{
    checkScalar(SdlScalar(null), "null");
    checkScalar(SdlScalar(true), "true");
    checkScalar(SdlScalar(false), "false");
    checkScalar(SdlScalar(int.min), "-2147483648");
    checkScalar(SdlScalar(int.max), "2147483647");
    checkScalar(SdlScalar(long.min), "-9223372036854775808L");
    checkScalar(SdlScalar(long.max), "9223372036854775807L");
    checkScalar(SdlScalar("a\nb\t\"c\"\\d"), `"a\nb\t\"c\"\\d"`);
    checkScalar(SdlScalar(cast(dchar) '€'), `'€'`);
    checkScalar(SdlScalar(cast(dchar) '\''), `'\''`);

    static immutable ubyte[5] bytes = [0, 1, 2, 0xFE, 0xFF];
    checkScalar(SdlScalar(bytes[]), "[AAEC/v8=]");
    static immutable ubyte[0] empty;
    static immutable ubyte[1] one = ['f'];
    static immutable ubyte[2] two = ['f', 'o'];
    static immutable ubyte[3] three = ['f', 'o', 'o'];
    checkScalar(SdlScalar(empty[]), "[]");
    checkScalar(SdlScalar(one[]), "[Zg==]");
    checkScalar(SdlScalar(two[]), "[Zm8=]");
    checkScalar(SdlScalar(three[]), "[Zm9v]");

    import sparkles.base.text.base_codecs : decodeBase64;

    auto rendered = renderScalar(SdlScalar(bytes[]));
    SmallBuffer!(ubyte, 8) decoded;
    auto decodedResult = decodeBase64(decoded, rendered[][1 .. $ - 1]);
    assert(decodedResult.hasValue && decoded[] == bytes[]);
}

@("sdl.writer.floatingKinds")
@system unittest
{
    import std.array : replicate;
    import std.algorithm.searching : canFind;

    checkScalar(SdlScalar(0.1f), "0.1F");
    checkScalar(SdlScalar(-0.0f), "-0F");
    checkScalar(SdlScalar(0.1), "0.1D");
    checkScalar(SdlScalar(double.min_normal / (1UL << 52)),
        "0." ~ "0".replicate(323) ~ "5D");
    checkScalar(SdlScalar.decimal(0.1L), "0.1BD");

    checkFloatingRoundTrip(0.0f);
    checkFloatingRoundTrip(-0.0f);
    checkFloatingRoundTrip(float.min_normal);
    checkFloatingRoundTrip(float.max);
    checkFloatingRoundTrip(0x1p-149f);
    checkFloatingRoundTrip(0.0);
    checkFloatingRoundTrip(-0.0);
    checkFloatingRoundTrip(double.min_normal);
    checkFloatingRoundTrip(double.max);
    checkFloatingRoundTrip(double.min_normal / (1UL << 52));
    checkFloatingRoundTrip(0.0L);
    checkFloatingRoundTrip(-0.0L);
    checkFloatingRoundTrip(real.min_normal);
    checkFloatingRoundTrip(real.max);

    auto largeValue = SdlScalar(1e30);
    auto large = renderScalar(largeValue);
    assert(large[].canFind('e') == false && large[].canFind('E') == false);
    checkScalarHarness(largeValue, large[]);

    SdlString writer;
    auto infinity = SdlScalar(double.infinity);
    auto invalid = writeSdlScalar(infinity, writer);
    assert(invalid.hasError);
    assert(invalid.error.code == SdlErrorCode.valueOutOfRange);
    assert(writer.length == 0);

    auto floatInfinity = SdlScalar(float.infinity);
    assert(writeSdlScalar(floatInfinity, writer).hasError && writer.length == 0);
    auto decimalInfinity = SdlScalar.decimal(real.infinity);
    assert(writeSdlScalar(decimalInfinity, writer).hasError && writer.length == 0);
}

// SPEC §9/§10 for the `decimal` family: every finite `real` has a canonical
// spelling, and that spelling decodes back to it through the reader's kernel.
// Both directions go through `parseDecimalReal` on purpose — a writer whose
// round-trip oracle is a *different* algorithm from the reader's (Phobos'
// `to!real` was) rejects representable values and lets through spellings the
// reader decodes to something else.
@("sdl.writer.decimalRoundTripProperty")
@system unittest
{
    import sparkles.wired.sdl.decimal : parseDecimalReal;

    static immutable real[] corners = [
        0.0L, -0.0L, 1.0L, -1.0L, 0.1L, real.min_normal, real.max,
        real.epsilon, 9.999999999999999L,
    ];

    static void check(real value)
    {
        SdlString rendered;
        const scalar = SdlScalar.decimal(value);
        const written = writeSdlScalar(scalar, rendered);
        assert(!written.hasError, written.error.toString);
        assert(rendered.length > 2 && rendered[][$ - 2 .. $] == "BD");
        const decoded = parseDecimalReal(rendered[][0 .. $ - 2]);
        assert(decoded is value, rendered[].idup);
    }

    foreach (value; corners)
        check(value);

    // Phobos cannot render every 80-bit `real`: `%.38g` of `1 + real.epsilon`
    // is "1" at every precision, so no candidate distinguishes it from 1.0.
    // The contract that matters is that this surfaces as a structured encode
    // error rather than silently emitting a spelling for a different value.
    {
        const unrenderable = SdlScalar.decimal(1.0L + real.epsilon);
        SdlString sink;
        const written = writeSdlScalar(unrenderable, sink);
        assert(written.hasError);
        assert(written.error.code == SdlErrorCode.valueOutOfRange);
        assert(sink.length == 0);
    }

    // A spread of non-dyadic values: the generated law test elsewhere feeds
    // only n/32.0L, which every accumulate-based kernel happens to survive.
    ulong state = 0x2545_F491_4F6C_DD1DUL;
    foreach (_; 0 .. 4000)
    {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const numerator = cast(long)(state % 1_000_000_000);
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        check(cast(real) numerator / cast(real)(1 + state % 1_000_000_007));
    }
}

@("sdl.writer.temporalKinds")
@system unittest
{
    import core.time : hnsecs, hours, msecs, seconds;
    import std.datetime.date : Date;

    const date = Date(2026, 8, 24);
    checkScalar(SdlScalar(date), "2026/8/24");

    const local = SdlDateTime(date, 7, 5, 9, 120_000);
    checkScalar(SdlScalar(local), "2026/8/24 07:05:09.012");
    checkScalar(SdlScalar(SdlDateTime(date, 7, 5, 9, 1_000_000)),
        "2026/8/24 07:05:09.1");
    checkScalar(SdlScalar(SdlDateTime(date, 7, 5, 9, 100_000)),
        "2026/8/24 07:05:09.01");
    checkScalar(SdlScalar(SdlDateTime(date, 7, 5, 9, 10_000)),
        "2026/8/24 07:05:09.001");
    checkScalar(SdlScalar(SdlZonedDateTime(local, "Europe/Sofia")),
        "2026/8/24 07:05:09.012-Europe/Sofia");
    checkScalar(SdlScalar(SdlZonedDateTime(local, null, 2.hours, true)),
        "2026/8/24 07:05:09.012-GMT+02:00");
    SdlString invalidWriter;
    auto offsetValue = SdlScalar(SdlZonedDateTime(local, null,
        2.hours + 30.msecs, true));
    auto badOffset = writeSdlScalar(offsetValue, invalidWriter);
    assert(badOffset.hasError && invalidWriter.length == 0);

    checkScalar(SdlScalar(Duration.zero), "00:00:00");
    checkScalar(SdlScalar(3.hours + 4.seconds + 5.msecs), "03:00:04.005");
    checkScalar(SdlScalar(-(25.hours + 1.hnsecs)), "-1d:01:00:00.0000001");
    auto minimumValue = SdlScalar(Duration.min);
    auto minimum = renderScalar(minimumValue);
    assert(minimum.length > 0 && minimum[][0] == '-');
    checkScalarHarness(minimumValue, minimum[]);
}

@("sdl.writer.semanticRejections")
@system unittest
{
    SdlString writer;
    auto fraction = SdlScalar(SdlDateTime(Date(2026, 8, 24), 1, 2, 3, 1));
    auto invalid = writeSdlScalar(fraction, writer);
    assert(invalid.hasError && invalid.error.code == SdlErrorCode.invalidDateTime);
    assert(writer.length == 0);

    auto separatorValue = SdlScalar("a\u2028b");
    auto separator = writeSdlScalar(separatorValue, writer);
    assert(separator.hasError && writer.length == 0);

    auto badCharacter = SdlScalar(cast(dchar) 0x11_0000);
    auto character = writeSdlScalar(badCharacter, writer);
    assert(character.hasError && writer.length == 0);
}
