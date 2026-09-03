/** Canonical semantic emission for SDL scalar values. */
module sparkles.wired.sdl.writer;

import core.time : Duration;
import std.datetime.date : Date;
import std.range.primitives : put;

import sparkles.base.buffer : SharedBuffer, checkWriter;
import sparkles.wired.json.writer : writeJsonDouble, writeJsonLong;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.error;

version (unittest)
{
    private import sparkles.wired.sdl.config : sdlDubRecipe, sdlFull;
    private import sparkles.wired.sdl.reader : parseSdlDocument;
}

/// Owning text returned by SDL convenience APIs.
alias SdlString = SharedBuffer!(char, 256);

/** Canonical document-writer options (SPEC §9/§11).

`indent` may be any non-empty string; the canonical default is four ASCII
spaces. `newlineForEmptyDocument` controls whether a document with no
top-level tags emits a single LF or nothing at all.
*/
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
    failure.reason ~= reason;
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
    SharedBuffer!(char, 40) token;
    writeJsonDouble(token, value);
    writeFixedDecimal(writer, token[]);
    put(writer, 'D');
    return sdlOk();
}

/** Writes the shortest decimal that reads back as `value` through the SDL
adapter, in SDL's exponent-free notation, then `suffix`.

`shortestDigits` proves its spelling against the value's rounding interval
rather than asking a reader, so there is no search over precisions, no
Phobos formatting, and nothing left to fail past the non-finite check —
which is what makes this `nothrow` and `@nogc` whenever the writer is. The
digits come out in scientific notation and `writeFixedDecimal` expands
them, the same path the `double` kind takes.
*/
private SdlExpected!void writeShortestGeneric(T, Writer)(T value,
    ref Writer writer, string suffix)
if (is(T == float) || is(T == real))
{
    import std.math : isFinite;
    import sparkles.base.text.float_conv : writeShortest;

    if (!isFinite(value))
        return sdlErr!void(encodeError(SdlErrorCode.valueOutOfRange,
            T.stringof, "NaN and infinity are not representable in SDL"));

    SharedBuffer!(char, 64) scientific;
    writeShortest(scientific, value);
    writeFixedDecimal(writer, scientific[]);
    put(writer, suffix);
    return sdlOk();
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

// ── Canonical document emission (SPEC §9) ────────────────────────────────────

/** Writes one parsed document in canonical SDL form.

The output is UTF-8 without BOM, LF newlines, one declaration per logical
line, exactly one final LF for a non-empty document, positional values then
attributes then children in stored order with single-space separators, and
four-space indentation by default (any non-empty `options.indent`). A
child-bearing tag writes `" {"` and LF, and its closing `}` sits on its own
indented line; empty child blocks still open and close on their own lines.
Anonymous tags emit their bare values with no name. Comments and source
trivia are never reproduced; spans and the source name are ignored. An empty
document emits nothing, plus exactly one LF when `newlineForEmptyDocument`
is set.

Every failure returns a structured encode-stage error whose role path names
the offending member, e.g. `$.child[2]@attr` or `$<value[0]>` (SPEC §7).

Emission is incremental, so only the failures detected before any byte is
written — an empty `indent`, an invalid document — leave the writer untouched.
A scalar this canonical form cannot spell is found mid-document, and the tags
before it have already been emitted. Such a scalar is not exotic: a raw
`` `…` `` string may legally carry a control byte, and a `string` field may
hold U+2028, neither of which has a canonical spelling. A caller that needs
all-or-nothing writes into a staging buffer and copies on success — which is
what $(LREF sparkles.wired.sdl.codec.toSDL) and
$(LREF sparkles.wired.sdl.files.writeSDLFile) already do, so both are atomic.
Individual scalars are atomic in either case: each validates before emitting.

`Document` is any SdlDocument-like arena exposing `valid()` and `root()`.
Attributes infer from `Writer`; over $(LREF SharedBuffer) the structural path
performs no GC allocation (the floating-point kernels may format through
Phobos).
*/
SdlExpected!void writeSdlDocument(Document, Writer)(
    return scope const ref Document document,
    ref Writer writer,
    SdlWriteOptions options = SdlWriteOptions.init)
{
    if (!document.valid || document.root.childCount == 0)
    {
        if (options.newlineForEmptyDocument)
            put(writer, '\n');
        return sdlOk();
    }
    if (options.indent.length == 0)
        return sdlErr!void(encodeError(SdlErrorCode.checkFailed, "indent",
            "indent must be a non-empty string"));

    SharedBuffer!(char, 96) rolePath;

    /// Stamps the role path composed during the unwind onto the failure.
    SdlExpected!void attach(SdlError error)
    {
        error.rolePath ~= rolePath[];
        return sdlErr!void(error);
    }

    void putIndent(ref Writer sink, size_t depth)
    {
        foreach (_; 0 .. depth)
            put(sink, options.indent);
    }

    void putName(W)(ref W sink, SdlQualifiedName name)
    {
        if (name.namespace_.length)
        {
            put(sink, name.namespace_);
            put(sink, ':');
        }
        put(sink, name.localName);
    }

    SdlExpected!void writeScalar(ref Writer sink, SdlScalar scalar)
    {
        auto result = writeSdlScalar(scalar, sink);
        if (result.hasError)
            return sdlErr!void(result.error);
        return sdlOk();
    }

    SdlQualifiedName childNameAt(SdlNode node, size_t position)
    {
        auto walker = node.byChild;
        foreach (_; 0 .. position)
            walker.popFront();
        return walker.front.qualifiedName;
    }

    /// Occurrence index of `position` among same-qualified-name siblings.
    ///
    /// Children repeat freely, so the path segment counts equal qualified
    /// names before `position`; two bounded walks keep this allocation-free.
    size_t occurrenceOf(SdlNode node, size_t position)
    {
        const target = childNameAt(node, position);

        auto prior = node.byChild;
        size_t occurrence;
        foreach (_; 0 .. position)
        {
            if (prior.front.qualifiedName == target)
                occurrence++;
            prior.popFront();
        }
        return occurrence;
    }

    /** Puts this level's segment in front of the path built so far.

    The path is composed while a failure unwinds, never while writing
    succeeds. Both walks above are O(position), so paying for them per child
    on the way *down* makes emitting a tag quadratic in its sibling count —
    for output nothing reads unless something goes wrong.
    */
    void prependChildSegment(SdlNode node, size_t position)
    {
        import sparkles.base.text.writers : writeInteger;

        SharedBuffer!(char, 96) composed;
        composed ~= ".";
        putName(composed, childNameAt(node, position));
        composed ~= "[";
        writeInteger(composed, occurrenceOf(node, position));
        composed ~= "]";
        composed ~= rolePath[];
        rolePath.length = 0;
        rolePath ~= composed[];
    }

    SdlExpected!void writeNode(ref Writer sink, SdlNode node,
        size_t depth, bool named)
    {
        putIndent(sink, depth);
        size_t seen;
        if (named)
        {
            putName(sink, node.qualifiedName);
            seen = 1;
        }
        auto valueRange = node.byValue;
        for (size_t index = 0; !valueRange.empty; valueRange.popFront(), index++)
        {
            const value = valueRange.front;
            if (seen++ != 0)
                put(sink, ' ');
            const written = writeScalar(sink, value);
            if (written.hasError)
            {
                import sparkles.base.text.writers : writeInteger;

                rolePath ~= "<value[";
                writeInteger(rolePath, index);
                rolePath ~= "]>";
                return written;
            }
        }
        foreach (attribute; node.byAttribute)
        {
            if (seen++ != 0)
                put(sink, ' ');
            putName(sink, attribute.qualifiedName);
            put(sink, '=');
            const written = writeScalar(sink, attribute.value);
            if (written.hasError)
            {
                rolePath ~= "@";
                putName(rolePath, attribute.qualifiedName);
                return written;
            }
        }
        if (!node.hasBlock)
        {
            put(sink, '\n');
            return sdlOk();
        }
        put(sink, " {\n");
        auto childRange = node.byChild;
        for (size_t position = 0; !childRange.empty;
            childRange.popFront(), position++)
        {
            const child = childRange.front;
            const written = writeNode(sink, child, depth + 1,
                child.qualifiedName.localName.length != 0
                    || child.qualifiedName.namespace_.length != 0);
            if (written.hasError)
            {
                prependChildSegment(node, position);
                return written;
            }
        }
        putIndent(sink, depth);
        put(sink, "}\n");
        return sdlOk();
    }

    const root = document.root;
    auto topLevel = root.byChild;
    for (size_t position = 0; !topLevel.empty;
        topLevel.popFront(), position++)
    {
        const child = topLevel.front;
        const written = writeNode(writer, child, 0,
            child.qualifiedName.localName.length != 0
                || child.qualifiedName.namespace_.length != 0);
        if (written.hasError)
        {
            prependChildSegment(root, position);
            return attach(written.error);
        }
    }
    return sdlOk();
}

/** Package seam: semantic document equality for the SPEC §10 law tests.

Two documents are semantically equal when their canonical serializations are
byte-identical — which by construction ignores source spans and source names
while preserving every ordered channel, scalar kind, and payload byte.
*/
package bool sdlDocumentsSemanticallyEqual(A, B)(
    return scope const ref A left, return scope const ref B right)
{
    import sparkles.base.buffer : SharedBuffer, checkWriter;

    static bool canonical(D)(scope const ref D document,
        ref SharedBuffer!(char, 512) bytes)
    {
        return !writeSdlDocument(document, bytes).hasError;
    }

    SharedBuffer!(char, 512) leftBytes;
    SharedBuffer!(char, 512) rightBytes;
    if (!canonical(left, leftBytes) || !canonical(right, rightBytes))
        return false;
    return leftBytes[] == rightBytes[];
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

                SharedBuffer!(ubyte, 64) decoded;
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
        import sparkles.base.buffer : SharedBuffer, checkWriter;

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
    SharedBuffer!(ubyte, 8) decoded;
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
    // The width-sensitive corners, at whatever width this host's `real` has:
    // on binary128 these are ~4 900-character `BD` tokens.
    checkFloatingRoundTrip(-real.max);
    checkFloatingRoundTrip(real.epsilon);
    checkFloatingRoundTrip(1.0L + real.epsilon);
    checkFloatingRoundTrip(real.min_normal * real.epsilon);
    checkFloatingRoundTrip(real.min_normal * (1 - real.epsilon));
    checkFloatingRoundTrip(float.min_normal * float.epsilon);
    checkFloatingRoundTrip(1.00000011920928955078125f);

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
// The writer proves its spelling against the rounding interval and consults
// no reader; the law is that the reader's own adapter, `parseDecimalReal`,
// maps it back — which is what this test reads through.
@("sdl.writer.decimalRoundTripProperty")
@system unittest
{
    import sparkles.wired.sdl.decimal : parseDecimalReal;

    static immutable real[] corners = [
        0.0L, -0.0L, 1.0L, -1.0L, 0.1L, real.min_normal, real.max, -real.max,
        real.epsilon, 1.0L + real.epsilon, 9.999999999999999L,
        real.min_normal * real.epsilon, real.min_normal * (1 - real.epsilon),
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

    // `1 + real.epsilon` is the value Phobos' `%g` could not render on x87 —
    // "1" at every precision — which the old precision search surfaced as an
    // encode error. The interval method has no such gap: at every width the
    // value encodes, and reads back.
    {
        const edge = SdlScalar.decimal(1.0L + real.epsilon);
        SdlString sink;
        const written = writeSdlScalar(edge, sink);
        assert(!written.hasError, written.error.toString);
        assert(sink.length > 2 && sink[][$ - 2 .. $] == "BD");
        assert(parseDecimalReal(sink[][0 .. $ - 2]) is edge.decimalValue);
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

version (unittest)
{
    private string renderDocument(A)(scope const ref A document)
    {
        SharedBuffer!(char, 1024) bytes;
        auto written = writeSdlDocument(document, bytes);
        assert(!written.hasError, written.error.toString);
        return bytes[].idup;
    }

    private struct LawRandom
    {
        uint state;
        uint next() @safe pure nothrow @nogc
        {
            state = state * 1_664_525 + 1_013_904_223;
            return state;
        }
    }

    private string pick(ref LawRandom rng, scope immutable(string)[] items)
    {
        return items[rng.next() % items.length];
    }

    private string pickValue(ref LawRandom rng, bool recipeOnly)
    {
        static immutable string[] full = [
            "null", "true", "false", "on", "off", "'x'",
            `"str\"q"`, `"multi\nline"`, "`raw`", "-42", "42L",
            "0.5F", "-0.0D", "0.125BD", "[TQ==]",
        ];
        static immutable string[] recipe = [`"a"`, `"b\nc"`, "true", "false"];
        return recipeOnly ? recipe[rng.next() % recipe.length]
            : full[rng.next() % full.length];
    }

    private void generateTag(ref LawRandom rng, ref string out_,
        size_t depth, bool recipeOnly)
    {
        if (!recipeOnly && rng.next() % 7 == 0)
            out_ ~= "# note\n";
        if (rng.next() % 11 == 0)
            out_ ~= "\n";
        foreach (_; 0 .. depth)
            out_ ~= "    ";

        const anonymous = !recipeOnly && depth < 2 && rng.next() % 5 == 0;
        if (!anonymous)
            out_ ~= pick(rng, recipeOnly
                ? ["alpha", "beta"] : ["alpha", "beta", "x:gamma", "dup"]);

        const valueCount = anonymous ? 1 + rng.next() % 3 : rng.next() % 4;
        foreach (index; 0 .. valueCount)
        {
            out_ ~= index == 0 && !anonymous ? " " : "";
            if (index != 0 || anonymous)
                out_ ~= " ";
            out_ ~= pickValue(rng, recipeOnly);
        }
        foreach (_; 0 .. 1 + rng.next() % 2)
        {
            out_ ~= anonymous && valueCount == 0 ? "" : " ";
            out_ ~= pick(rng, recipeOnly
                ? ["opt", "x:plat"] : ["opt", "ver", "x:plat"]);
            out_ ~= "=";
            out_ ~= pickValue(rng, recipeOnly);
        }

        if (depth < 3 && rng.next() % 3 != 0)
        {
            out_ ~= " {\n";
            foreach (_; 0 .. 1 + rng.next() % 3)
                generateTag(rng, out_, depth + 1, recipeOnly);
            foreach (_; 0 .. depth)
                out_ ~= "    ";
            out_ ~= "}";
            out_ ~= rng.next() % 4 == 0 ? ";" : "\n";
        }
        else
            out_ ~= rng.next() % 4 == 0 ? ";\n" : "\n";
    }

    /// Space-bearing temporal literals are emitted as their own standalone
    /// tags: the scanner legitimately fuses a leading date/clock with a
    /// following digit-and-colon token, so adjacency would change meaning.
    /// Scalars whose spelling may fuse with an adjacent digit-led token
    /// (dates absorb a following clock; clocks/durations absorb dates) are
    /// emitted as their own single-value tags.
    private string pickTemporal(ref LawRandom rng)
    {
        static immutable string[] temporal = [
            "2024/2/29",
            "01:02:03.0000001",
            "2d:00:00:00",
            "-0:00:00.5",
            "2024/2/29 01:02:03.05",
            "2024/2/29 01:02:03-Europe/X",
            "2024/2/29 01:02:03-GMT+02:00",
        ];
        return temporal[rng.next() % temporal.length];
    }

    private string generateDocument(ref LawRandom rng, bool recipeOnly)
    {
        string source;
        foreach (_; 0 .. 1 + rng.next() % 3)
        {
            if (!recipeOnly && rng.next() % 5 == 0)
                source ~= pick(rng, ["alpha", "beta", "dup"])
                    ~ " " ~ pickTemporal(rng) ~ "\n";
            generateTag(rng, source, 0, recipeOnly);
        }
        return source;
    }
}

@("sdl.writer.canonicalGolden")
@system unittest
{
    enum source =
        "# line comment\n"
        ~ "/* block */\n"
        ~ `ns:tag on off x:v=` ~ "`raw`" ~ ` y="re\ng"` ~ "\n"
        ~ `"a" 42L` ~ "\n"
        ~ "empty {\n}\n"
        ~ "deep {\n"
        ~ "    inner -0D .5F .25D .1BD [AAEC/v8=] null 'x'\n"
        ~ "}\n"
        ~ "dt 2024/2/29 01:02:03.5-GMT+02:00\n"
        ~ "dur 2d:03:04:05.0000007\n"
        ~ "neg -0:00:00.5\n";
    auto parsed = parseSdlDocument!sdlFull(source, "golden.sdl");
    assert(parsed.hasValue, parsed.error.toString);

    enum expected =
        `ns:tag true false x:v="raw" y="re\ng"` ~ "\n"
        ~ "\"a\" 42L\n"
        ~ "empty {\n}\n"
        ~ "deep {\n"
        ~ "    inner -0.0D 0.5F 0.25D 0.1BD [AAEC/v8=] null 'x'\n"
        ~ "}\n"
        ~ "dt 2024/2/29 01:02:03.5-GMT+02:00\n"
        ~ "dur 2d:03:04:05.0000007\n"
        ~ "neg -00:00:00.5\n";

    const rendered = renderDocument(parsed.document);
    assert(rendered == expected, rendered);

    // LAW 2 spot check on the golden: double canonicalization is identity.
    const reparsed = parseSdlDocument!sdlFull(rendered, "golden2.sdl");
    assert(reparsed.hasValue, reparsed.error.toString);
    assert(renderDocument(reparsed.document) == rendered);
}

@("sdl.writer.canonicalOptions")
@system unittest
{
    auto nested = parseSdlDocument!sdlFull("a {\nb\n}\n");
    assert(nested.hasValue);
    SharedBuffer!(char, 64) tabbed;
    assert(!writeSdlDocument(nested.document, tabbed,
        SdlWriteOptions(indent: "\t")).hasError);
    assert(tabbed[] == "a {\n\tb\n}\n");

    SharedBuffer!(char, 8) emptyDefault;
    auto blank = parseSdlDocument!sdlFull("");
    assert(blank.hasValue);
    assert(!writeSdlDocument(blank.document, emptyDefault).hasError);
    assert(emptyDefault.length == 0);

    SharedBuffer!(char, 8) blankNewline;
    assert(!writeSdlDocument(blank.document, blankNewline,
        SdlWriteOptions(newlineForEmptyDocument: true)).hasError);
    assert(blankNewline[] == "\n");

    SharedBuffer!(char, 8) untouched;
    auto rejected = writeSdlDocument(nested.document, untouched,
        SdlWriteOptions(indent: ""));
    assert(rejected.hasError && rejected.error.code == SdlErrorCode.checkFailed);
    assert(untouched.length == 0);
}

@("sdl.writer.pathedFailures")
@system unittest
{
    import core.exception : AssertError;

    static void checkPath(string source, size_t valueIndex, size_t attributeIndex,
        SdlScalar replacement, SdlErrorCode code, string path)
    {
        auto parsed = parseSdlDocument!sdlFull(source, "bad.sdl");
        if (!parsed.hasValue)
            throw new AssertError(parsed.error.toString);
        if (valueIndex != size_t.max)
            parsed.document.values[valueIndex].value = replacement;
        else
            parsed.document.attributes[attributeIndex].value = replacement;

        SharedBuffer!(char, 128) sink;
        const failure = writeSdlDocument(parsed.document, sink);
        assert(failure.hasError);
        assert(failure.error.code == code);
        assert(failure.error.rolePath[] == path, failure.error.toString);
    }

    checkPath("t {\nc \"v\" x=1\n}\n", 0, size_t.max,
        SdlScalar.invalidScalar, SdlErrorCode.unexpectedKind,
        ".t[0].c[0]<value[0]>");
    checkPath("t {\nc \"v\" x=1\n}\nw \"s\"\n", 1, size_t.max,
        SdlScalar.invalidScalar, SdlErrorCode.unexpectedKind,
        ".w[0]<value[0]>");
    checkPath("t {\nc \"v\" x=1\n}\nw \"s\"\n", size_t.max, 0,
        SdlScalar(double.nan), SdlErrorCode.valueOutOfRange,
        ".t[0].c[0]@x");

    // Non-finite positional value keeps its value-segment path.
    checkPath("root -42L\n", 0, size_t.max,
        SdlScalar(double.infinity), SdlErrorCode.valueOutOfRange,
        ".root[0]<value[0]>");
}

// Parsing and canonical emission must stay linear in sibling count. Both
// were quadratic: `finalizeChildren` found each node's parent by scanning
// backwards, and the writer composed every child's role path — two O(position)
// range walks — on the success path, for output no reader ever sees unless
// something fails.
//
// The bound is wall clock, which is normally a poor test oracle; it works
// here because the gap is not marginal. At this size the linear
// implementation takes tens of milliseconds and the quadratic one takes
// tens of seconds, so any machine that runs the suite at all separates them
// by two orders of magnitude.
@("sdl.writer.flatDocumentScalesLinearly")
@system unittest
{
    import std.array : appender;
    import std.datetime.stopwatch : AutoStart, StopWatch;

    enum tags = 200_000;
    auto source = appender!string;
    source.reserve(tags * 12);
    foreach (_; 0 .. tags)
        source ~= "tag \"v\"\n";

    auto clock = StopWatch(AutoStart.yes);
    auto parsed = parseSdlDocument!sdlFull(source[], "scale.sdl");
    const parseMs = clock.peek.total!"msecs";
    assert(parsed.hasValue, parsed.error.toString);
    assert(parsed.document.root.childCount == tags);

    clock.reset();
    SharedBuffer!(char, 1024) rendered;
    const written = writeSdlDocument(parsed.document, rendered);
    const writeMs = clock.peek.total!"msecs";
    assert(!written.hasError, written.error.toString);
    assert(rendered.length == source[].length);

    import std.conv : to;

    assert(parseMs < 5_000, "parse went quadratic: " ~ parseMs.to!string ~ "ms");
    assert(writeMs < 5_000, "write went quadratic: " ~ writeMs.to!string ~ "ms");
}

// The writer emits as it goes, so a mid-document failure has already written
// the tags before it. `sdl.writer.pathedFailures` builds this exact shape but
// only inspects the error, which is how the contract and the code drifted
// apart. Reachable without hand-editing an arena: a raw string may legally
// carry a control byte that canonical output cannot spell.
@("sdl.writer.partialOutputOnMidDocumentFailure")
@system unittest
{
    enum source = "first \"ok\"\nsecond \x60p\x01q\x60\nthird \"never\"\n";
    auto parsed = parseSdlDocument!sdlFull(source, "partial.sdl");
    assert(parsed.hasValue, parsed.error.toString);

    SharedBuffer!(char, 128) sink;
    sink ~= "PRE|";
    const written = writeSdlDocument(parsed.document, sink);
    assert(written.hasError);
    assert(written.error.code == SdlErrorCode.valueOutOfRange);
    assert(written.error.rolePath[] == ".second[0]<value[0]>",
        written.error.rolePath[].idup);

    // Everything up to the offending scalar is already in the writer.
    assert(sink[] == "PRE|first \"ok\"\nsecond ", sink[].idup);

    // The failures caught before emission starts still leave it untouched.
    SharedBuffer!(char, 64) untouched;
    untouched ~= "PRE|";
    assert(writeSdlDocument(parsed.document, untouched,
        SdlWriteOptions(indent: "")).hasError);
    assert(untouched[] == "PRE|");
}

@("sdl.writer.laws.generatedDocuments")
@system unittest
{
    uint lawCase;
    void runLaws(bool recipeOnly)(uint seedValue, size_t cases)
    {
        LawRandom rng;
        foreach (_; 0 .. cases)
        {
            rng.state = seedValue += 0x9E37_79B9;
            const source = generateDocument(rng, recipeOnly);
            auto first = parseSdlDocument!(recipeOnly
                ? sdlDubRecipe : sdlFull)(source, "law.sdl");
            if (!first.hasValue)
                throw new Exception(first.error.toString ~ "\n---\n" ~ source);

            SharedBuffer!(char, 512) once;
            auto written = writeSdlDocument(first.document, once);
            if (written.hasError)
                throw new Exception(written.error.toString ~ "\n---\n" ~ source);

            auto second = parseSdlDocument!(recipeOnly
                ? sdlDubRecipe : sdlFull)(once[], "law2.sdl");
            if (!second.hasValue)
                throw new Exception(second.error.toString ~ "\n---\n"
                    ~ once[].idup);

            // LAW 1: parse(write(parse(s))) == parse(s), spans excluded.
            assert(sdlDocumentsSemanticallyEqual(first.document,
                second.document));

            SharedBuffer!(char, 512) twice;
            auto rewritten = writeSdlDocument(second.document, twice);
            assert(!rewritten.hasError);
            // LAW 2: canonicalization is byte-idempotent.
            assert(twice[] == once[]);
            lawCase++;
        }
    }

    runLaws!false(0x1D0C_5EED, 400);
    runLaws!true(0xB0B5_CAFE, 200);
    assert(lawCase == 600);
}

@("sdl.writer.laws.dubCorpusRoundTrip")
@system unittest
{
    import core.exception : AssertError;
    import std.file : SpanMode, dirEntries, isSymlink, readText;
    import std.path : baseName;

    static void roundTrip(string path)
    {
        const source = readText(path);
        auto first = parseSdlDocument!sdlDubRecipe(source, path);
        if (!first.hasValue)
            throw new AssertError(path ~ ": " ~ first.error.toString);

        SharedBuffer!(char, 512) once;
        auto written = writeSdlDocument(first.document, once);
        if (written.hasError)
            throw new AssertError(path ~ ": " ~ written.error.toString);

        auto second = parseSdlDocument!sdlDubRecipe(once[], path);
        if (!second.hasValue)
            throw new AssertError(path ~ ": " ~ second.error.toString);

        SharedBuffer!(char, 512) twice;
        auto rewritten = writeSdlDocument(second.document, twice);
        assert(!rewritten.hasError);
        assert(twice[] == once[]);
        assert(sdlDocumentsSemanticallyEqual(first.document, second.document));
    }

    static void visit(string directory, ref size_t count)
    {
        foreach (entry; dirEntries(directory, SpanMode.shallow))
        {
            if (entry.isDir)
            {
                const name = entry.name.baseName;
                if (name == ".git" || name == ".direnv" || name == ".dub"
                    || name == "build" || name == "node_modules"
                    || isSymlink(entry.name))
                    continue;
                visit(entry.name, count);
            }
            else if (entry.isFile && entry.name.baseName == "dub.sdl")
            {
                roundTrip(entry.name);
                count++;
            }
        }
    }

    size_t count;
    visit(".", count);
    assert(count > 100);

    // Direct compatibility fixture: dlang/dub dub.sdl at
    // 5efed360e1c9342453bc5dd19339c75981526d83 (MIT; fixture README/notices).
    roundTrip("libs/wired/src/sparkles/wired/sdl/fixtures/"
        ~ "dub-5efed360-recipe.snapshot.sdl");
}
