/** Borrowed, profile-specialized SDL lexer and deferred scalar decoders. */
module sparkles.wired.sdl.lexer;

import core.time : Duration, hnsecs, hours, minutes;
import std.datetime.date : Date;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.wired.sdl.config;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.error;

version (unittest) import core.exception : AssertError;

/// Stable token vocabulary shared by every SDL profile.
enum SdlTokenKind : ubyte
{
    eof,
    newline,
    semicolon,
    colon,
    equals,
    openBrace,
    closeBrace,
    identifier,
    null_,
    boolean,
    string_,
    character,
    integer,
    longInteger,
    float_,
    double_,
    decimal,
    binary,
    date,
    dateTime,
    zonedDateTime,
    duration,
}

/** One borrowed SDL token with an exact original-source slice.

Lexing establishes token shape and feature availability. Numeric ranges and
temporal semantics are deliberately deferred; callers must successfully run
$(LREF decodeSdlScalar) before using a scalar payload.
*/
struct SdlToken
{
    SdlTokenKind kind;
    const(char)[] raw;
    SdlSpan span;
}

/** Scratch ownership for deferred string and binary scalar decoding.

The returned `SdlScalar` borrows this storage until its next decode or
destruction. Scalar kinds without byte payloads do not use it.
*/
struct SdlScalarStorage
{
    SmallBuffer!(char, 256) text;
    SmallBuffer!(ubyte, 256) bytes;

    /// Discards the previous decoded payload while retaining capacity.
    void clear() @safe pure nothrow @nogc
    {
        text.clear();
        bytes.clear();
    }
}

private bool featureFor(SdlParserConfig config, SdlTokenKind kind)
    @safe pure nothrow @nogc
{
    final switch (kind) with (SdlTokenKind)
    {
    case null_: return config.scalars.nulls;
    case boolean: return config.scalars.booleans;
    case string_: return config.scalars.strings;
    case character: return config.scalars.characters;
    case integer: return config.scalars.integers;
    case longInteger: return config.scalars.longIntegers;
    case float_: return config.scalars.floats;
    case double_: return config.scalars.doubles;
    case decimal: return config.scalars.decimals;
    case binary: return config.scalars.binary;
    case date: return config.scalars.dates;
    case dateTime: return config.scalars.dateTimes;
    case zonedDateTime: return config.scalars.zonedDateTimes;
    case duration: return config.scalars.durations;
    case eof:
    case newline:
    case semicolon:
    case colon:
    case equals:
    case openBrace:
    case closeBrace:
    case identifier:
        return false;
    }
}

/// Whether specialization `config` contains the semantic kernel for `kind`.
enum bool sdlScalarKernelAvailable(SdlParserConfig config, SdlTokenKind kind) =
    featureFor(config, kind);

private SdlError lexicalError(SdlErrorCode code, SdlSpan span,
    scope const(char)[] sourceName, string reason) @safe pure nothrow @nogc
{
    SdlError result;
    result.stage = SdlErrorStage.lex;
    result.code = code;
    result.span = span;
    result.sourceName ~= sourceName;
    result.reason ~= reason;
    return result;
}

private size_t utf8Length(scope const(char)[] source, size_t at)
    @safe pure nothrow @nogc
{
    import sparkles.base.text.utf8 : utf8SequenceLength;

    if (at >= source.length)
        return 0;
    return cast(ubyte) source[at] < 0x80 ? 1 : utf8SequenceLength(source, at);
}

private dchar codePointAt(scope const(char)[] source, size_t at)
    @safe pure nothrow @nogc
{
    import sparkles.base.text.utf : decodeFirstUtf8;

    return decodeFirstUtf8(source[at .. $]);
}

private bool isAsciiSpace(char c) @safe pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\v' || c == '\f';

private bool isLogicalNewline(scope const(char)[] source, size_t at,
    out size_t width) @safe pure nothrow @nogc
{
    width = 0;
    if (at >= source.length)
        return false;
    if (source[at] == '\r')
    {
        width = at + 1 < source.length && source[at + 1] == '\n' ? 2 : 1;
        return true;
    }
    if (source[at] == '\n')
    {
        width = 1;
        return true;
    }
    if (at + 2 < source.length && cast(ubyte) source[at] == 0xE2
        && cast(ubyte) source[at + 1] == 0x80
        && (cast(ubyte) source[at + 2] == 0xA8
            || cast(ubyte) source[at + 2] == 0xA9))
    {
        width = 3;
        return true;
    }
    return false;
}

private bool isDelimiter(scope const(char)[] source, size_t at)
    @safe pure nothrow @nogc
{
    if (at >= source.length)
        return true;
    size_t width;
    if (isLogicalNewline(source, at, width) || isAsciiSpace(source[at]))
        return true;
    switch (source[at])
    {
    case ';': case '{': case '}': case '=': case ',': return true;
    default: return false;
    }
}

private ubyte base64Value(char c) @safe pure nothrow @nogc
{
    if (c >= 'A' && c <= 'Z') return cast(ubyte)(c - 'A');
    if (c >= 'a' && c <= 'z') return cast(ubyte)(c - 'a' + 26);
    if (c >= '0' && c <= '9') return cast(ubyte)(c - '0' + 52);
    return c == '+' ? 62 : 63;
}

private bool allDigits(scope const(char)[] value, size_t start, size_t end)
    @safe pure nothrow @nogc
{
    if (start == end)
        return false;
    foreach (c; value[start .. end])
        if (cast(uint)(c - '0') > 9)
            return false;
    return true;
}

private size_t indexOf(scope const(char)[] value, char needle, size_t start = 0)
    @safe pure nothrow @nogc
{
    foreach (i; start .. value.length)
        if (value[i] == needle)
            return i;
    return value.length;
}

private bool parseUnsigned(scope const(char)[] value, ref size_t at,
    out ulong result) @safe pure nothrow @nogc
{
    import sparkles.base.text.readers : readInteger;

    auto input = value[at .. $];
    const before = input.length;
    auto parsed = readInteger!ulong(input);
    if (parsed.hasError)
        return false;
    at += before - input.length;
    result = parsed.value;
    return true;
}

private SdlTokenKind classifyNumber(SdlParserConfig config)(scope const(char)[] raw)
    @safe pure nothrow @nogc
{
    size_t begin = raw.length && raw[0] == '-' ? 1 : 0;
    if (begin == raw.length)
        return SdlTokenKind.identifier;

    if (indexOf(raw, '/') < raw.length)
    {
        const firstSlash = indexOf(raw, '/');
        const secondSlash = indexOf(raw, '/', firstSlash + 1);
        size_t dayEnd = secondSlash + 1;
        while (dayEnd < raw.length && cast(uint)(raw[dayEnd] - '0') <= 9) dayEnd++;
        const clockAt = secondSlash < raw.length
            ? dateTimeClockAt!config(raw, dayEnd) : size_t.max;
        if (clockAt == size_t.max)
            return SdlTokenKind.date;
        const firstColon = indexOf(raw, ':', clockAt);
        const zoneDash = indexOf(raw, '-', firstColon + 1);
        return zoneDash < raw.length
            ? SdlTokenKind.zonedDateTime : SdlTokenKind.dateTime;
    }
    if (indexOf(raw, ':') < raw.length)
        return SdlTokenKind.duration;

    size_t suffix = raw.length;
    SdlTokenKind result;
    if (suffix >= 2 && (raw[suffix - 2] == 'B' || raw[suffix - 2] == 'b')
        && (raw[suffix - 1] == 'D' || raw[suffix - 1] == 'd'))
    {
        suffix -= 2;
        result = SdlTokenKind.decimal;
    }
    else if (raw[$ - 1] == 'L' || raw[$ - 1] == 'l')
    {
        suffix--;
        result = SdlTokenKind.longInteger;
    }
    else if (raw[$ - 1] == 'F' || raw[$ - 1] == 'f')
    {
        suffix--;
        result = SdlTokenKind.float_;
    }
    else if (raw[$ - 1] == 'D' || raw[$ - 1] == 'd')
    {
        suffix--;
        result = SdlTokenKind.double_;
    }
    else
        result = indexOf(raw, '.') < raw.length
            ? SdlTokenKind.double_ : SdlTokenKind.integer;

    const dot = indexOf(raw, '.', begin);
    if (result == SdlTokenKind.longInteger && dot < suffix)
        return SdlTokenKind.identifier;
    if (dot < suffix)
    {
        if ((!allDigits(raw, begin, dot) && dot != begin)
            || !allDigits(raw, dot + 1, suffix))
            return SdlTokenKind.identifier;
    }
    else if (!allDigits(raw, begin, suffix))
        return SdlTokenKind.identifier;
    return result;
}

private bool scalarCandidateStart(scope const(char)[] source, size_t at)
    @safe pure nothrow @nogc
{
    if (at >= source.length)
        return false;
    if (cast(uint)(source[at] - '0') <= 9)
        return true;
    return (source[at] == '-' || source[at] == '.')
        && at + 1 < source.length && cast(uint)(source[at + 1] - '0') <= 9;
}

private size_t dateTimeClockAt(SdlParserConfig config)(
    scope const(char)[] source, size_t at) @safe pure nothrow @nogc
{
    bool consumedTrivia;
    while (at < source.length)
    {
        if (isAsciiSpace(source[at]))
        {
            consumedTrivia = true;
            at++;
            continue;
        }
        if (config.syntax.blockComments && at + 1 < source.length
            && source[at .. at + 2] == "/*")
        {
            const closeStart = at;
            at += 2;
            while (at + 1 < source.length && source[at .. at + 2] != "*/") at++;
            if (at + 1 >= source.length) return closeStart;
            at += 2;
            consumedTrivia = true;
            continue;
        }
        if (config.syntax.continuations && source[at] == '\\')
        {
            size_t cursor = at + 1;
            while (cursor < source.length && isAsciiSpace(source[cursor])) cursor++;
            size_t width;
            if (cursor >= source.length || !isLogicalNewline(source, cursor, width))
                return at;
            at = cursor + width;
            consumedTrivia = true;
            static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
                while (at < source.length)
                {
                    if (isAsciiSpace(source[at])) at++;
                    else if (isLogicalNewline(source, at, width)) at += width;
                    else break;
                }
            continue;
        }
        break;
    }
    if (!consumedTrivia || at >= source.length)
        return size_t.max;
    size_t cursor = at + (source[at] == '-');
    const digits = cursor;
    while (cursor < source.length && cast(uint)(source[cursor] - '0') <= 9) cursor++;
    return cursor > digits && cursor < source.length && source[cursor] == ':'
        ? at : size_t.max;
}

/** A forward range over tokens borrowed from `source`.

`front` is an `Expected`: malformed input is yielded once as an error. After
that element is popped the range is empty. EOF is a regular final token.
*/
struct SdlLexer(SdlParserConfig config = sdlFull)
{
    private const(char)[] _source;
    private const(char)[] _sourceName;
    private size_t _at;
    private SdlPosition _position;
    private SdlToken _token;
    private SdlError _error;
    private bool _ready;
    private bool _failed;
    private bool _finished;

    /// Starts lexing borrowed UTF-8 source.
    this(return scope const(char)[] source,
        return scope const(char)[] sourceName = null)
    {
        _source = source;
        _sourceName = sourceName;
        _position = SdlPosition(0, 1, 1);
    }

    /// Whether EOF or a yielded error has been consumed.
    bool empty() scope
    {
        ensure();
        return _finished && !_ready;
    }

    /// Current token or structured lexical error.
    SdlExpected!SdlToken front() return scope
    {
        ensure();
        if (_failed)
            return sdlErr!SdlToken(errorCopy());
        return sdlOk(_token);
    }

    /// Advances to the next token.
    void popFront() scope
    {
        ensure();
        if (!_ready)
            return;
        _ready = false;
        if (_failed || _token.kind == SdlTokenKind.eof)
            _finished = true;
    }

    /// Independent cursor at the current token, satisfying forward-range save.
    SdlLexer save() return scope => this;

    private void advance(size_t count) scope
    {
        const end = _at + count;
        while (_at < end)
        {
            size_t newlineWidth;
            if (isLogicalNewline(_source, _at, newlineWidth)
                && _at + newlineWidth <= end)
            {
                _at += newlineWidth;
                _position.byteOffset = _at;
                _position.line++;
                _position.column = 1;
                continue;
            }
            const width = utf8Length(_source, _at);
            _at += width ? width : 1;
            _position.byteOffset = _at;
            _position.column++;
        }
    }

    private SdlSpan spanFrom(SdlPosition start) scope => SdlSpan(start, _position);

    private SdlError errorCopy() scope
    {
        SdlError result;
        result.stage = _error.stage;
        result.code = _error.code;
        result.sourceName ~= _error.sourceName[];
        result.span = _error.span;
        result.relatedSpan = _error.relatedSpan;
        result.hasRelatedSpan = _error.hasRelatedSpan;
        result.reason ~= _error.reason[];
        return result;
    }

    private void fail(SdlErrorCode code, SdlPosition start, string reason) scope
    {
        _error = lexicalError(code, spanFrom(start), _sourceName, reason);
        _failed = true;
        _ready = true;
    }

    private bool consumeUtf8(SdlPosition constructStart, string reason) scope
    {
        const width = utf8Length(_source, _at);
        if (width)
        {
            advance(width);
            return true;
        }
        const invalidStart = _position;
        advance(1);
        fail(SdlErrorCode.invalidUtf8, invalidStart, reason);
        return false;
    }

    private bool consumeUtf8Until(size_t end, SdlPosition constructStart,
        string reason) scope
    {
        while (_at < end)
            if (!consumeUtf8(constructStart, reason))
                return false;
        return true;
    }

    private void emit(SdlTokenKind kind, size_t startAt, SdlPosition start) scope
    {
        _token = SdlToken(kind, _source[startAt .. _at], spanFrom(start));
        _ready = true;
    }

    private bool skipComment() scope
    {
        const startAt = _at;
        const start = _position;
        bool line;
        bool enabled;
        if (_source[_at] == '#')
        {
            line = true;
            enabled = config.syntax.hashComments;
            advance(1);
        }
        else if (_at + 1 < _source.length && _source[_at .. _at + 2] == "//")
        {
            line = true;
            enabled = config.syntax.slashComments;
            advance(2);
        }
        else if (_at + 1 < _source.length && _source[_at .. _at + 2] == "--")
        {
            line = true;
            enabled = config.syntax.dashComments;
            advance(2);
        }
        else if (_at + 1 < _source.length && _source[_at .. _at + 2] == "/*")
        {
            enabled = config.syntax.blockComments;
            advance(2);
            while (_at + 1 < _source.length && _source[_at .. _at + 2] != "*/")
                if (!consumeUtf8(start, "invalid UTF-8 in block comment"))
                    return true;
            if (_at + 1 >= _source.length)
            {
                fail(SdlErrorCode.unterminatedComment, start,
                    "unterminated block comment");
                return true;
            }
            advance(2);
        }
        else
            return false;

        if (line)
        {
            size_t width;
            while (_at < _source.length && !isLogicalNewline(_source, _at, width))
                if (!consumeUtf8(start, "invalid UTF-8 in line comment"))
                    return true;
        }
        if (!enabled)
            fail(SdlErrorCode.unsupportedFeature, start,
                "comment syntax is disabled by this SDL profile");
        return true;
    }

    private bool skipContinuation() scope
    {
        if (_source[_at] != '\\')
            return false;
        const start = _position;
        advance(1);
        while (_at < _source.length)
        {
            if (isAsciiSpace(_source[_at]))
            {
                advance(1);
                continue;
            }
            if (_source[_at] == '#' || (_at + 1 < _source.length
                && (_source[_at .. _at + 2] == "//"
                    || _source[_at .. _at + 2] == "--"
                    || _source[_at .. _at + 2] == "/*")))
            {
                if (skipComment() && _ready)
                    return true;
                continue;
            }
            break;
        }
        size_t width;
        if (_at >= _source.length || !isLogicalNewline(_source, _at, width))
        {
            fail(_at >= _source.length ? SdlErrorCode.unexpectedEof
                    : SdlErrorCode.unexpectedCharacter,
                start,
                "line continuation requires a following newline");
            return true;
        }
        advance(width);
        if (!config.syntax.continuations)
            fail(SdlErrorCode.unsupportedFeature, start,
                "line continuations are disabled by this SDL profile");
        else if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
        {
            // Pinned DUB consumes all following trivia and blank physical
            // lines after one backslash, stopping at the next real token.
            while (_at < _source.length)
            {
                if (isAsciiSpace(_source[_at]))
                {
                    advance(1);
                    continue;
                }
                if (isLogicalNewline(_source, _at, width))
                {
                    advance(width);
                    continue;
                }
                if (_source[_at] == '#' || (_at + 1 < _source.length
                    && (_source[_at .. _at + 2] == "//"
                        || _source[_at .. _at + 2] == "--"
                        || _source[_at .. _at + 2] == "/*")))
                {
                    if (skipComment() && _ready)
                        return true;
                    continue;
                }
                break;
            }
        }
        return true;
    }

    private void scanQuoted(char quote, SdlTokenKind kind) scope
    {
        const startAt = _at;
        const start = _position;
        advance(1);
        size_t scalarCount;
        while (_at < _source.length)
        {
            size_t newlineWidth;
            if (isLogicalNewline(_source, _at, newlineWidth))
            {
                fail(SdlErrorCode.unterminatedString, start,
                    "newline before closing quote");
                return;
            }
            if (_source[_at] == quote)
            {
                advance(1);
                if (kind == SdlTokenKind.character && scalarCount != 1)
                {
                    fail(SdlErrorCode.invalidEscape, start,
                        "character literal must decode to one Unicode scalar");
                    return;
                }
                if (!featureFor(config, kind))
                    fail(SdlErrorCode.unsupportedFeature, start,
                        "scalar family is disabled by this SDL profile");
                else
                    emit(kind, startAt, start);
                return;
            }
            if (_source[_at] == '\\')
            {
                advance(1);
                if (_at >= _source.length)
                    break;
                if (_source[_at] == 'n' || _source[_at] == 'r'
                    || _source[_at] == 't' || _source[_at] == '\\'
                    || _source[_at] == quote)
                {
                    advance(1);
                    scalarCount++;
                    continue;
                }
                if (kind == SdlTokenKind.string_)
                {
                    while (_at < _source.length && isAsciiSpace(_source[_at]))
                        advance(1);
                    if (_at < _source.length
                        && isLogicalNewline(_source, _at, newlineWidth))
                    {
                        advance(newlineWidth);
                        static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
                        {
                            while (_at < _source.length)
                            {
                                if (isAsciiSpace(_source[_at])) advance(1);
                                else if (isLogicalNewline(_source, _at, newlineWidth))
                                    advance(newlineWidth);
                                else break;
                            }
                        }
                        continue;
                    }
                }
                fail(SdlErrorCode.invalidEscape, start, "invalid SDL escape");
                return;
            }
            const width = utf8Length(_source, _at);
            if (width == 0)
            {
                advance(1);
                fail(SdlErrorCode.invalidUtf8, start, "invalid UTF-8 in literal");
                return;
            }
            advance(width);
            scalarCount++;
        }
        fail(SdlErrorCode.unterminatedString, start, "unterminated quoted literal");
    }

    private void scanRawString() scope
    {
        const startAt = _at;
        const start = _position;
        advance(1);
        while (_at < _source.length && _source[_at] != '`')
        {
            const width = utf8Length(_source, _at);
            if (width == 0)
            {
                advance(1);
                fail(SdlErrorCode.invalidUtf8, start, "invalid UTF-8 in raw string");
                return;
            }
            advance(width);
        }
        if (_at == _source.length)
        {
            fail(SdlErrorCode.unterminatedString, start, "unterminated raw string");
            return;
        }
        advance(1);
        if (!config.syntax.rawStrings || !config.scalars.strings)
            fail(SdlErrorCode.unsupportedFeature, start,
                "raw strings are disabled by this SDL profile");
        else
            emit(SdlTokenKind.string_, startAt, start);
    }

    private void scanBinary() scope
    {
        const startAt = _at;
        const start = _position;
        advance(1);
        while (_at < _source.length && _source[_at] != ']')
        {
            const c = _source[_at];
            size_t width;
            if (isAsciiSpace(c) || isLogicalNewline(_source, _at, width))
                advance(width ? width : 1);
            else if (cast(ubyte) c >= 0x80)
            {
                import std.uni : isWhite;

                width = utf8Length(_source, _at);
                if (width && config.syntax.unicodeWhitespace
                    && isWhite(codePointAt(_source, _at)))
                    advance(width);
                else
                {
                    advance(width ? width : 1);
                    fail(width ? SdlErrorCode.invalidBase64 : SdlErrorCode.invalidUtf8,
                        start, "invalid character in Base64 payload");
                    return;
                }
            }
            else if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
                || (c >= '0' && c <= '9') || c == '+' || c == '/'
                || c == '=')
                advance(1);
            else
            {
                advance(1); // Non-ASCII was handled above; this is invalid ASCII.
                fail(SdlErrorCode.invalidBase64, start, "invalid Base64 character");
                return;
            }
        }
        if (_at == _source.length)
        {
            fail(SdlErrorCode.invalidBase64, start, "unterminated binary literal");
            return;
        }
        advance(1);
        size_t symbols;
        size_t padding;
        bool sawPadding;
        ubyte lastDataValue;
        size_t payloadAt = startAt + 1;
        while (payloadAt < _at - 1)
        {
            const c = _source[payloadAt];
            size_t width;
            if (isAsciiSpace(c) || isLogicalNewline(_source, payloadAt, width))
            {
                payloadAt += width ? width : 1;
                continue;
            }
            if (cast(ubyte) c >= 0x80)
            {
                import std.uni : isWhite;

                width = utf8Length(_source, payloadAt);
                if (width && isWhite(codePointAt(_source, payloadAt)))
                {
                    payloadAt += width;
                    continue;
                }
            }
            payloadAt++;
            symbols++;
            if (c == '=')
            {
                sawPadding = true;
                padding++;
            }
            else if (sawPadding)
            {
                fail(SdlErrorCode.invalidBase64, start,
                    "Base64 data follows padding");
                return;
            }
            else
                lastDataValue = base64Value(c);
        }
        if (symbols % 4 != 0 || padding > 2
            || padding == 2 && (lastDataValue & 0x0F) != 0
            || padding == 1 && (lastDataValue & 0x03) != 0)
        {
            fail(SdlErrorCode.invalidBase64, start,
                "Base64 payload has invalid padding or discarded bits");
            return;
        }
        if (!config.scalars.binary)
            fail(SdlErrorCode.unsupportedFeature, start,
                "binary scalars are disabled by this SDL profile");
        else
            emit(SdlTokenKind.binary, startAt, start);
    }

    private void scanNumber() scope
    {
        const startAt = _at;
        const start = _position;
        bool sawSlash;
        while (_at < _source.length)
        {
            size_t newlineWidth;
            if (isLogicalNewline(_source, _at, newlineWidth))
                break;
            if (_source[_at] == '#' || (_at + 1 < _source.length
                && (_source[_at .. _at + 2] == "//"
                    || _source[_at .. _at + 2] == "--"
                    || !sawSlash && _source[_at .. _at + 2] == "/*")))
                break;
            if (isAsciiSpace(_source[_at]))
            {
                if (!sawSlash)
                    break;
                const clockAt = dateTimeClockAt!config(_source, _at);
                if (clockAt == size_t.max)
                    break;
                if (!consumeUtf8Until(clockAt, start,
                    "invalid UTF-8 in date-time trivia"))
                    return;
                continue;
            }
            if (sawSlash && (_source[_at] == '\\' || (_at + 1 < _source.length
                && _source[_at .. _at + 2] == "/*")))
            {
                const clockAt = dateTimeClockAt!config(_source, _at);
                if (clockAt == size_t.max || clockAt == _at)
                    break;
                if (!consumeUtf8Until(clockAt, start,
                    "invalid UTF-8 in date-time trivia"))
                    return;
                continue;
            }
            if (_source[_at] == '/')
                sawSlash = true;
            if (_source[_at] == ';' || _source[_at] == '{' || _source[_at] == '}'
                || _source[_at] == '=' || _source[_at] == ',')
            {
                static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
                {
                    const current = _source[startAt .. _at];
                    if (!sawSlash
                        || classifyNumber!config(current) != SdlTokenKind.zonedDateTime)
                        break;
                }
                else
                    break;
            }
            if (!consumeUtf8(start, "invalid UTF-8 in scalar candidate"))
                return;
        }
        const raw = _source[startAt .. _at];
        const kind = classifyNumber!config(raw);
        if (kind == SdlTokenKind.identifier)
        {
            fail(SdlErrorCode.invalidNumber, start, "malformed SDL scalar candidate");
            return;
        }
        if (!featureFor(config, kind))
            fail(SdlErrorCode.unsupportedFeature, start,
                "scalar family is disabled by this SDL profile");
        else
            emit(kind, startAt, start);
    }

    private bool identifierStart(dchar cp) scope
    {
        import std.uni : isAlpha;

        return cp == '_' || cp < 0x80 && ((cp >= 'A' && cp <= 'Z')
            || (cp >= 'a' && cp <= 'z'))
            || config.syntax.unicodeIdentifiers && cp >= 0x80 && isAlpha(cp);
    }

    private bool identifierContinue(dchar cp) scope
    {
        import std.uni : isAlpha, isNumber;

        return identifierStart(cp) || (cp >= '0' && cp <= '9') || cp == '-'
            || cp == '.' || cp == '$'
            || config.syntax.unicodeIdentifiers && cp >= 0x80 && isNumber(cp);
    }

    private void scanIdentifier() scope
    {
        const startAt = _at;
        const start = _position;
        while (_at < _source.length)
        {
            const width = utf8Length(_source, _at);
            if (width == 0 || !identifierContinue(codePointAt(_source, _at)))
                break;
            advance(width);
        }
        const raw = _source[startAt .. _at];
        SdlTokenKind kind = SdlTokenKind.identifier;
        if (raw == "null") kind = SdlTokenKind.null_;
        else if (raw == "true" || raw == "false" || raw == "on" || raw == "off")
            kind = SdlTokenKind.boolean;
        if (kind != SdlTokenKind.identifier && !featureFor(config, kind))
            fail(SdlErrorCode.unsupportedFeature, start,
                "scalar family is disabled by this SDL profile");
        else
            emit(kind, startAt, start);
    }

    private void ensure() scope
    {
        if (_ready || _finished)
            return;
        if (_at == 0)
        {
            if (_source.length >= 3 && cast(ubyte) _source[0] == 0xEF
                && cast(ubyte) _source[1] == 0xBB && cast(ubyte) _source[2] == 0xBF)
            {
                _at = 3;
                _position.byteOffset = 3;
            }
            else if ((_source.length >= 2
                    && ((cast(ubyte) _source[0] == 0xFF && cast(ubyte) _source[1] == 0xFE)
                        || (cast(ubyte) _source[0] == 0xFE && cast(ubyte) _source[1] == 0xFF)))
                || (_source.length >= 4 && ((cast(ubyte) _source[0] == 0
                        && cast(ubyte) _source[1] == 0 && cast(ubyte) _source[2] == 0xFE
                        && cast(ubyte) _source[3] == 0xFF)
                    || (cast(ubyte) _source[0] == 0xFF && cast(ubyte) _source[1] == 0xFE
                        && cast(ubyte) _source[2] == 0 && cast(ubyte) _source[3] == 0))))
            {
                const start = _position;
                const isUtf32 = _source.length >= 4
                    && ((cast(ubyte) _source[0] == 0 && cast(ubyte) _source[1] == 0
                            && cast(ubyte) _source[2] == 0xFE
                            && cast(ubyte) _source[3] == 0xFF)
                        || (cast(ubyte) _source[0] == 0xFF
                            && cast(ubyte) _source[1] == 0xFE
                            && cast(ubyte) _source[2] == 0
                            && cast(ubyte) _source[3] == 0));
                advance(isUtf32 ? 4 : 2);
                fail(SdlErrorCode.unsupportedBom, start, "UTF-16/UTF-32 BOM is unsupported");
                return;
            }
            static if (config.validateUtf8)
            {
                import sparkles.base.text.utf8 : indexOfInvalidUtf8;

                const invalid = indexOfInvalidUtf8(_source[_at .. $]);
                if (invalid != _source.length - _at)
                {
                    advance(invalid + 1);
                    const end = _position;
                    SdlPosition start = end;
                    start.byteOffset--;
                    if (start.column > 1) start.column--;
                    fail(SdlErrorCode.invalidUtf8, start, "source is not well-formed UTF-8");
                    return;
                }
            }
        }

        while (_at < _source.length)
        {
            if (isAsciiSpace(_source[_at]))
            {
                advance(1);
                continue;
            }
            if (cast(ubyte) _source[_at] >= 0x80)
            {
                import std.uni : isWhite;

                const width = utf8Length(_source, _at);
                if (width == 0)
                {
                    const invalidStart = _position;
                    advance(1);
                    fail(SdlErrorCode.invalidUtf8, invalidStart,
                        "invalid UTF-8 in SDL source");
                    return;
                }
                const cp = codePointAt(_source, _at);
                size_t newlineWidth;
                if (isLogicalNewline(_source, _at, newlineWidth))
                {
                    if (!config.syntax.unicodeNewlines)
                    {
                        const start = _position;
                        advance(newlineWidth);
                        fail(SdlErrorCode.unsupportedFeature, start,
                            "Unicode newlines are disabled by this SDL profile");
                    }
                    else
                    {
                        const startAt = _at;
                        const start = _position;
                        advance(newlineWidth);
                        emit(SdlTokenKind.newline, startAt, start);
                    }
                    return;
                }
                if (isWhite(cp))
                {
                    const start = _position;
                    advance(width);
                    if (!config.syntax.unicodeWhitespace)
                    {
                        fail(SdlErrorCode.unsupportedFeature, start,
                            "Unicode whitespace is disabled by this SDL profile");
                        return;
                    }
                    continue;
                }
            }
            if (_source[_at] == '#' || (_at + 1 < _source.length
                && (_source[_at .. _at + 2] == "//"
                    || _source[_at .. _at + 2] == "--"
                    || _source[_at .. _at + 2] == "/*")))
            {
                if (skipComment() && _ready)
                    return;
                continue;
            }
            if (_source[_at] == '\\')
            {
                skipContinuation();
                if (_ready) return;
                continue;
            }
            break;
        }

        if (_at == _source.length)
        {
            _token = SdlToken(SdlTokenKind.eof, _source[_at .. _at],
                SdlSpan(_position, _position));
            _ready = true;
            return;
        }

        const startAt = _at;
        const start = _position;
        size_t newlineWidth;
        if (isLogicalNewline(_source, _at, newlineWidth))
        {
            advance(newlineWidth);
            emit(SdlTokenKind.newline, startAt, start);
            return;
        }
        switch (_source[_at])
        {
        case ';':
            advance(1);
            if (!config.syntax.semicolonTerminators)
                fail(SdlErrorCode.unsupportedFeature, start,
                    "semicolon terminators are disabled by this SDL profile");
            else emit(SdlTokenKind.semicolon, startAt, start);
            return;
        case ':': advance(1); emit(SdlTokenKind.colon, startAt, start); return;
        case '=': advance(1); emit(SdlTokenKind.equals, startAt, start); return;
        case '{': advance(1); emit(SdlTokenKind.openBrace, startAt, start); return;
        case '}': advance(1); emit(SdlTokenKind.closeBrace, startAt, start); return;
        case '"': scanQuoted('"', SdlTokenKind.string_); return;
        case '\'': scanQuoted('\'', SdlTokenKind.character); return;
        case '`': scanRawString(); return;
        case '[': scanBinary(); return;
        default: break;
        }
        if (scalarCandidateStart(_source, _at))
        {
            scanNumber();
            return;
        }
        const width = utf8Length(_source, _at);
        if (width && identifierStart(codePointAt(_source, _at)))
        {
            scanIdentifier();
            return;
        }
        advance(width ? width : 1);
        fail(width ? SdlErrorCode.unexpectedCharacter : SdlErrorCode.invalidUtf8,
            start, "unexpected character in SDL source");
    }
}

/// Constructs a borrowed lexer specialized for `config`.
SdlLexer!config lexSDL(SdlParserConfig config = sdlFull)(
    return scope const(char)[] source,
    return scope const(char)[] sourceName = null)
{
    return SdlLexer!config(source, sourceName);
}

private SdlError decodeError(SdlErrorCode code, in SdlToken token, string reason)
    @safe pure nothrow @nogc
{
    SdlError result;
    result.stage = SdlErrorStage.decode;
    result.code = code;
    result.span = token.span;
    result.reason ~= reason;
    return result;
}

private SdlExpected!long decodeInteger(SdlParserConfig config)(
    scope const(char)[] raw, bool longKind,
    in SdlToken token) @safe pure nothrow @nogc
{
    import sparkles.base.text.readers : readInteger;

    const negative = raw.length && raw[0] == '-';
    const suffix = longKind ? 1 : 0;
    auto digits = raw[negative .. raw.length - suffix];
    auto parsed = readInteger!ulong(digits);
    const limit = longKind ? (negative ? 0x8000_0000_0000_0000UL : long.max)
        : (negative ? 0x8000_0000UL : int.max);
    if (parsed.hasError || digits.length || parsed.value > limit)
        return sdlErr!long(decodeError(SdlErrorCode.numberOutOfRange, token,
            "integer is outside its SDL kind's range"));
    if (negative)
        return sdlOk(parsed.value == 0x8000_0000_0000_0000UL
            ? long.min : -cast(long) parsed.value);
    return sdlOk(cast(long) parsed.value);
}

private SdlExpected!double decodeFloating(SdlParserConfig config)(
    scope const(char)[] raw,
    size_t suffixLength, in SdlToken token) @safe pure nothrow @nogc
{
    import sparkles.base.text.float_conv : readDecimalFloat;
    import std.math : isFinite;

    SmallBuffer!(char, 64) normalized;
    auto body = raw[0 .. raw.length - suffixLength];
    if (body.length && body[0] == '.') normalized ~= '0';
    else if (body.length > 1 && body[0 .. 2] == "-.")
    {
        normalized ~= "-0";
        body = body[1 .. $];
    }
    normalized ~= body;
    scope const(char)[] input = normalized[];
    auto parsed = readDecimalFloat(input);
    if (parsed.hasError || input.length)
        return sdlErr!double(decodeError(SdlErrorCode.invalidNumber, token,
            "invalid floating-point scalar"));
    if (!isFinite(parsed.value))
        return sdlErr!double(decodeError(SdlErrorCode.numberOutOfRange, token,
            "floating-point scalar is not finite"));
    return sdlOk(parsed.value);
}

private SdlExpected!real decodeDecimal(SdlParserConfig config)(
    scope const(char)[] raw, in SdlToken token) @safe pure nothrow @nogc
{
    import std.math : isFinite;

    import sparkles.wired.sdl.decimal : parseDecimalReal;

    // The shared kernel, not a private accumulator: the canonical writer
    // picks its shortest spelling by asking this same routine what the text
    // decodes to, so SPEC §10 LAW 3 holds for `real` by construction.
    real value = parseDecimalReal(raw[0 .. raw.length - 2]);
    if (!isFinite(value))
        return sdlErr!real(decodeError(SdlErrorCode.numberOutOfRange, token,
            "decimal is outside real range"));
    return sdlOk(value);
}

private bool leapYear(SdlParserConfig config)(long year) @safe pure nothrow @nogc
    => year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);

private uint monthDays(SdlParserConfig config)(long year, ulong month)
    @safe pure nothrow @nogc
{
    static immutable ubyte[12] days = [31, 28, 31, 30, 31, 30,
        31, 31, 30, 31, 30, 31];
    return month == 2 && leapYear!config(year) ? 29 : days[month - 1];
}

private SdlExpected!Date decodeDatePart(SdlParserConfig config)(
    scope const(char)[] raw,
    in SdlToken token) @safe pure nothrow
{
    size_t at;
    ulong year, month, day;
    const negativeYear = raw.length && raw[0] == '-';
    at += negativeYear;
    if (!parseUnsigned(raw, at, year) || at >= raw.length || raw[at++] != '/'
        || !parseUnsigned(raw, at, month) || at >= raw.length || raw[at++] != '/'
        || !parseUnsigned(raw, at, day) || at != raw.length || year > int.max
        || month < 1 || month > 12 || day < 1
        || day > monthDays!config(
            negativeYear ? -cast(long) year : cast(long) year, month))
        return sdlErr!Date(decodeError(SdlErrorCode.invalidDate, token,
            "date fields are invalid"));
    try
        return sdlOk(Date(negativeYear ? -cast(int) year : cast(int) year,
            cast(int) month, cast(int) day));
    catch (Exception)
        return sdlErr!Date(decodeError(SdlErrorCode.invalidDate, token,
            "date is outside the representable Date range"));
}

private SdlExpected!SdlDateTime decodeDateTimePart(SdlParserConfig config)(
    scope const(char)[] raw, in SdlToken token) @safe pure nothrow
{
    SmallBuffer!(char, 128) normalized;
    const firstSlash = indexOf(raw, '/');
    if (firstSlash == raw.length)
        return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
            token, "date-time has no date separators"));
    const secondSlash = indexOf(raw, '/', firstSlash + 1);
    if (secondSlash == raw.length)
        return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
            token, "date-time has no day component"));
    size_t dayEnd = secondSlash + 1;
    while (dayEnd < raw.length && cast(uint)(raw[dayEnd] - '0') <= 9) dayEnd++;
    const normalizedClock = dateTimeClockAt!config(raw, dayEnd);
    if (normalizedClock != size_t.max)
    {
        normalized ~= raw[0 .. dayEnd];
        normalized ~= ' ';
        normalized ~= raw[normalizedClock .. $];
        raw = normalized[];
    }
    size_t space = indexOf(raw, ' ');
    const tab = indexOf(raw, '\t');
    if (tab < space) space = tab;
    if (space == raw.length)
        return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
            token, "date-time requires a clock"));
    auto date = decodeDatePart!config(raw[0 .. space], token);
    if (date.hasError) return sdlErr!SdlDateTime(date.error);
    size_t at = space;
    while (at < raw.length && isAsciiSpace(raw[at])) at++;
    bool negativeClock;
    static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
        if (at < raw.length && raw[at] == '-')
        {
            negativeClock = true;
            at++;
        }
    ulong hour, minute, second;
    if (!parseUnsigned(raw, at, hour) || at >= raw.length || raw[at++] != ':'
        || !parseUnsigned(raw, at, minute))
        return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
            token, "date-time clock is malformed"));
    ulong fraction;
    size_t fractionDigits;
    if (at < raw.length && raw[at] == ':')
    {
        at++;
        if (!parseUnsigned(raw, at, second))
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
                token, "date-time seconds are malformed"));
    }
    if (at < raw.length && raw[at] == '.')
    {
        const start = ++at;
        ulong parsedFraction;
        if (!parseUnsigned(raw, at, parsedFraction))
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
                token, "date-time fraction is malformed"));
        fractionDigits = at - start;
        static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
        {
            while (fractionDigits < 3) { parsedFraction *= 10; fractionDigits++; }
            if (parsedFraction > int.max)
                return sdlErr!SdlDateTime(decodeError(SdlErrorCode.numberOutOfRange,
                    token, "DUB millisecond field exceeds int range"));
            fraction = parsedFraction * 10_000;
        }
        else
        {
            if (fractionDigits > 3)
                return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
                    token, "date-time fraction has more than three digits"));
            while (fractionDigits < 7) { parsedFraction *= 10; fractionDigits++; }
            fraction = parsedFraction;
        }
    }
    if (at != raw.length)
        return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
            token, "date-time has trailing input"));
    static if (config.compatibility == SdlSyntaxCompatibility.sparkles)
    {
        if (hour >= 24 || minute >= 60 || second >= 60)
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.invalidDateTime,
                token, "date-time fields are outside civil ranges"));
        return sdlOk(SdlDateTime(date.value, cast(ubyte) hour, cast(ubyte) minute,
            cast(ubyte) second, cast(uint) fraction));
    }
    else
    {
        import core.time : days;

        if (hour > int.max || minute > int.max || second > int.max)
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.numberOutOfRange,
                token, "DUB clock component exceeds int range"));
        enum ulong perSecond = 10_000_000;
        enum ulong perDay = 86_400 * perSecond;
        if (hour > ulong.max / 3_600
            || hour * 3_600 + minute * 60 + second > long.max / perSecond
            || fraction > long.max - (hour * 3_600 + minute * 60 + second) * perSecond)
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.valueOutOfRange,
                token, "normalized DUB date-time overflows"));
        long clockTicks = cast(long)((hour * 3_600 + minute * 60 + second) * perSecond
            + fraction);
        if (negativeClock) clockTicks = -clockTicks;
        long dayShift = clockTicks / cast(long) perDay;
        long withinDay = clockTicks % cast(long) perDay;
        if (withinDay < 0)
        {
            dayShift--;
            withinDay += perDay;
        }
        Date normalizedDate;
        try normalizedDate = date.value + dayShift.days;
        catch (Exception)
            return sdlErr!SdlDateTime(decodeError(SdlErrorCode.valueOutOfRange,
                token, "normalized DUB date-time is outside Date range"));
        const wholeSeconds = withinDay / perSecond;
        return sdlOk(SdlDateTime(normalizedDate,
            cast(ubyte)(wholeSeconds / 3_600),
            cast(ubyte)(wholeSeconds / 60 % 60),
            cast(ubyte)(wholeSeconds % 60),
            cast(uint)(withinDay % perSecond)));
    }
}

private SdlExpected!Duration decodeDurationValue(SdlParserConfig config)(
    scope const(char)[] raw, in SdlToken token) @safe pure nothrow @nogc
{
    const negative = raw.length && raw[0] == '-';
    size_t at = negative;
    ulong first;
    if (!parseUnsigned(raw, at, first))
        return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration, token,
            "duration is malformed"));
    ulong days, hours = first, minute, second;
    if (at < raw.length && raw[at] == 'd')
    {
        days = first;
        at++;
        if (at >= raw.length || raw[at++] != ':' || !parseUnsigned(raw, at, hours))
            return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration,
                token, "duration day component is malformed"));
    }
    if (at >= raw.length || raw[at++] != ':' || !parseUnsigned(raw, at, minute)
        || at >= raw.length || raw[at++] != ':' || !parseUnsigned(raw, at, second))
        return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration, token,
            "duration clock is malformed"));
    ulong fraction;
    size_t digits;
    if (at < raw.length && raw[at] == '.')
    {
        const start = ++at;
        if (!parseUnsigned(raw, at, fraction))
            return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration,
                token, "duration fraction is malformed"));
        digits = at - start;
        static if (config.compatibility == SdlSyntaxCompatibility.dub5efed360)
        {
            while (digits < 3) { fraction *= 10; digits++; }
            if (fraction > long.max / 10_000)
                return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange,
                    token, "DUB millisecond field overflows Duration"));
            fraction *= 10_000;
        }
        else
        {
            if (digits > 7)
                return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration,
                    token, "duration fraction has more than seven digits"));
            while (digits < 7) { fraction *= 10; digits++; }
        }
    }
    if (at != raw.length)
        return sdlErr!Duration(decodeError(SdlErrorCode.invalidDuration, token,
            "duration has trailing input"));
    enum ulong perSecond = 10_000_000;
    if (days > ulong.max / 24)
        return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange, token,
            "duration overflows Duration"));
    ulong totalHours = days * 24;
    if (hours > ulong.max - totalHours || totalHours + hours > ulong.max / 60)
        return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange, token,
            "duration overflows Duration"));
    totalHours += hours;
    ulong totalMinutes = totalHours * 60;
    if (minute > ulong.max - totalMinutes
        || totalMinutes + minute > ulong.max / 60)
        return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange, token,
            "duration overflows Duration"));
    totalMinutes += minute;
    ulong totalSeconds = totalMinutes * 60;
    if (second > ulong.max - totalSeconds)
        return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange, token,
            "duration overflows Duration"));
    totalSeconds += second;
    const limit = negative ? 0x8000_0000_0000_0000UL : cast(ulong) long.max;
    if (totalSeconds > limit / perSecond
        || totalSeconds == limit / perSecond && fraction > limit % perSecond)
        return sdlErr!Duration(decodeError(SdlErrorCode.valueOutOfRange, token,
            "duration overflows Duration"));
    const magnitude = totalSeconds * perSecond + fraction;
    const signed = negative ? (magnitude == 0x8000_0000_0000_0000UL
        ? long.min : -cast(long) magnitude) : cast(long) magnitude;
    return sdlOk(signed.hnsecs);
}

/** Decodes one scalar token into the public borrowed scratch storage.

Unchanged external surface from S2: text and binary results borrow `storage`
until its next decode or destruction. Disabled families never instantiate
their conversion kernels.
*/
SdlExpected!SdlScalar decodeSdlScalar(SdlParserConfig config = sdlFull)(
    in SdlToken token, return ref SdlScalarStorage storage)
{
    return decodeSdlScalarInto!(config, SdlScalarStorage)(token, storage);
}

/** Package seam: decodes one scalar token into caller-provided exact storage.

The parser milestone uses this with fixed-target buffers so decoded string and
binary payloads are written directly into document-owned pool bytes without an
intermediate growable temporary. The `static if` branches are the binary-size
contract: disabled profile families do not reference, instantiate, or link
their semantic primitives. Malformed or out-of-range token spellings return a
structured error and never produce a usable `SdlScalar`.
*/
package SdlExpected!SdlScalar decodeSdlScalarInto(
    SdlParserConfig config = sdlFull, Storage)(
    in SdlToken token, return ref Storage storage)
{
    import sparkles.base.text.utf8 : indexOfInvalidUtf8;

    storage.clear();
    if (token.raw.length == 0 && token.kind != SdlTokenKind.eof)
        return sdlErr!SdlScalar(decodeError(SdlErrorCode.unexpectedToken, token,
            "scalar token has no source spelling"));
    if (indexOfInvalidUtf8(token.raw) != token.raw.length)
        return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidUtf8, token,
            "scalar token is not well-formed UTF-8"));
    final switch (token.kind) with (SdlTokenKind)
    {
    case null_:
        static if (config.scalars.nulls)
        {
            if (token.raw != "null")
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.unexpectedToken,
                    token, "invalid null spelling"));
            return sdlOk(SdlScalar(null));
        }
        else break;
    case boolean:
        static if (config.scalars.booleans)
        {
            if (token.raw != "true" && token.raw != "on"
                && token.raw != "false" && token.raw != "off")
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.unexpectedToken,
                    token, "invalid boolean spelling"));
            return sdlOk(SdlScalar(token.raw == "true" || token.raw == "on"));
        }
        else break;
    case string_:
        static if (config.scalars.strings)
        {
            if (token.raw.length < 2)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.unterminatedString,
                    token, "string token has no closing delimiter"));
            if (token.raw[0] == '`')
            {
                if (token.raw[$ - 1] != '`')
                    return sdlErr!SdlScalar(decodeError(
                        SdlErrorCode.unterminatedString, token,
                        "raw string token has no closing delimiter"));
                storage.text ~= token.raw[1 .. $ - 1];
            }
            else
            {
                if (token.raw[0] != '"' || token.raw[$ - 1] != '"')
                    return sdlErr!SdlScalar(decodeError(
                        SdlErrorCode.unterminatedString, token,
                        "string token has invalid delimiters"));
                size_t at = 1;
                while (at + 1 < token.raw.length)
                {
                    if (token.raw[at] != '\\')
                    {
                        size_t newlineWidth;
                        if (isLogicalNewline(token.raw, at, newlineWidth))
                            return sdlErr!SdlScalar(decodeError(
                                SdlErrorCode.unterminatedString, token,
                                "unescaped newline in string token"));
                        const width = utf8Length(token.raw, at);
                        storage.text ~= token.raw[at .. at + width];
                        at += width;
                        continue;
                    }
                    at++;
                    switch (token.raw[at])
                    {
                    case 'n': storage.text ~= '\n'; at++; break;
                    case 'r': storage.text ~= '\r'; at++; break;
                    case 't': storage.text ~= '\t'; at++; break;
                    case '\\': storage.text ~= '\\'; at++; break;
                    case '"': storage.text ~= '"'; at++; break;
                    default:
                        while (at < token.raw.length && isAsciiSpace(token.raw[at])) at++;
                        size_t width;
                        if (isLogicalNewline(token.raw, at, width)) at += width;
                        else
                            return sdlErr!SdlScalar(decodeError(
                                SdlErrorCode.invalidEscape, token,
                                "invalid string escape"));
                        break;
                    }
                }
            }
            return sdlOk(SdlScalar(storage.text[]));
        }
        else break;
    case character:
        static if (config.scalars.characters)
        {
            if (token.raw.length < 3)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.unterminatedString,
                    token, "character token has no payload"));
            if (token.raw[0] != '\'' || token.raw[$ - 1] != '\'')
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.unterminatedString,
                    token, "character token has invalid delimiters"));
            dchar value;
            if (token.raw[1] == '\\')
            {
                if (token.raw.length != 4)
                    return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidEscape,
                        token, "character escape has trailing input"));
                switch (token.raw[2])
                {
                case 'n': value = '\n'; break;
                case 'r': value = '\r'; break;
                case 't': value = '\t'; break;
                case '\\': value = '\\'; break;
                case '\'': value = '\''; break;
                default:
                    return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidEscape,
                        token, "invalid character escape"));
                }
            }
            else
            {
                const width = utf8Length(token.raw, 1);
                if (width == 0 || 1 + width != token.raw.length - 1)
                    return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidEscape,
                        token, "character literal must contain one Unicode scalar"));
                value = codePointAt(token.raw, 1);
            }
            return sdlOk(SdlScalar(value));
        }
        else break;
    case integer:
        static if (config.scalars.integers)
        {
            auto value = decodeInteger!config(token.raw, false, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(cast(int) value.value));
        }
        else break;
    case longInteger:
        static if (config.scalars.longIntegers)
        {
            auto value = decodeInteger!config(token.raw, true, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(value.value));
        }
        else break;
    case float_:
        static if (config.scalars.floats)
        {
            auto value = decodeFloating!config(token.raw, 1, token);
            if (value.hasError) return sdlErr!SdlScalar(value.error);
            const narrowed = cast(float) value.value;
            if (narrowed == float.infinity || narrowed == -float.infinity)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.numberOutOfRange,
                    token, "float is outside binary32 range"));
            return sdlOk(SdlScalar(narrowed));
        }
        else break;
    case double_:
        static if (config.scalars.doubles)
        {
            const suffix = token.raw[$ - 1] == 'D' || token.raw[$ - 1] == 'd' ? 1 : 0;
            auto value = decodeFloating!config(token.raw, suffix, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(value.value));
        }
        else break;
    case decimal:
        static if (config.scalars.decimals)
        {
            if (token.raw.length < 3)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidNumber,
                    token, "decimal token is missing its payload"));
            auto value = decodeDecimal!config(token.raw, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar.decimal(value.value));
        }
        else break;
    case binary:
        static if (config.scalars.binary)
        {
            if (token.raw.length < 2)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidBase64,
                    token, "binary token has no closing delimiter"));
            if (token.raw[0] != '[' || token.raw[$ - 1] != ']')
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidBase64,
                    token, "binary token has invalid delimiters"));
            size_t at = 1;
            char[4] quartet;
            size_t quartetLength;
            while (at + 1 < token.raw.length)
            {
                size_t width;
                if (isAsciiSpace(token.raw[at])
                    || isLogicalNewline(token.raw, at, width))
                {
                    at += width ? width : 1;
                    continue;
                }
                if (cast(ubyte) token.raw[at] >= 0x80)
                {
                    import std.uni : isWhite;

                    width = utf8Length(token.raw, at);
                    if (width && isWhite(codePointAt(token.raw, at)))
                    {
                        at += width;
                        continue;
                    }
                }
                quartet[quartetLength++] = token.raw[at++];
                if (quartetLength == 4)
                {
                    const a = base64Value(quartet[0]);
                    const b = base64Value(quartet[1]);
                    storage.bytes ~= cast(ubyte)((a << 2) | (b >> 4));
                    if (quartet[2] != '=')
                    {
                        const c = base64Value(quartet[2]);
                        storage.bytes ~= cast(ubyte)((b << 4) | (c >> 2));
                        if (quartet[3] != '=')
                            storage.bytes ~= cast(ubyte)((c << 6)
                                | base64Value(quartet[3]));
                    }
                    quartetLength = 0;
                }
            }
            if (quartetLength != 0)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidBase64,
                    token, "invalid Base64 payload"));
            return sdlOk(SdlScalar(storage.bytes[]));
        }
        else break;
    case date:
        static if (config.scalars.dates)
        {
            auto value = decodeDatePart!config(token.raw, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(value.value));
        }
        else break;
    case dateTime:
        static if (config.scalars.dateTimes)
        {
            auto value = decodeDateTimePart!config(token.raw, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(value.value));
        }
        else break;
    case zonedDateTime:
        static if (config.scalars.zonedDateTimes)
        {
            const firstColon = indexOf(token.raw, ':');
            if (firstColon == token.raw.length)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidDateTime,
                    token, "zoned date-time has no clock"));
            const zoneAt = indexOf(token.raw, '-', firstColon + 1);
            if (zoneAt == token.raw.length || zoneAt + 1 == token.raw.length)
                return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidDateTime,
                    token, "zoned date-time has no zone spelling"));
            auto local = decodeDateTimePart!config(token.raw[0 .. zoneAt], token);
            if (local.hasError) return sdlErr!SdlScalar(local.error);
            const zone = token.raw[zoneAt + 1 .. $];
            storage.text ~= zone;
            SdlZonedDateTime value = SdlZonedDateTime(local.value, storage.text[]);
            if (zone.length >= 4 && zone[0 .. 3] == "GMT"
                && (zone[3] == '+' || zone[3] == '-'))
            {
                ulong hour, minute;
                bool resolved;
                static if (config.compatibility == SdlSyntaxCompatibility.sparkles)
                {
                    const iso = zone[4 .. $];
                    if (!((iso.length == 2 && allDigits(iso, 0, 2))
                        || (iso.length == 5 && iso[2] == ':'
                            && allDigits(iso, 0, 2)
                            && allDigits(iso, 3, 5))))
                        return sdlErr!SdlScalar(decodeError(
                            SdlErrorCode.invalidDateTime, token,
                            "GMT offset must be HH or HH:MM with two-digit fields"));
                    size_t at = 4;
                    if (!parseUnsigned(zone, at, hour) || hour > 23)
                        return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidDateTime,
                            token, "GMT offset is malformed"));
                    if (at < zone.length && zone[at] == ':')
                    {
                        at++;
                        if (!parseUnsigned(zone, at, minute) || minute > 59)
                            return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidDateTime,
                                token, "GMT offset is malformed"));
                    }
                    if (at != zone.length)
                        return sdlErr!SdlScalar(decodeError(SdlErrorCode.invalidDateTime,
                            token, "GMT offset is malformed"));
                    resolved = true;
                }
                else
                {
                    const iso = zone[4 .. $];
                    const colon = indexOf(iso, ':');
                    size_t at;
                    if (iso.length >= 3 && iso[0] == ':' && iso.length == 3)
                    {
                        at = 1;
                        resolved = parseUnsigned(iso, at, minute) && at == iso.length;
                    }
                    else if (colon < iso.length)
                    {
                        at = 0;
                        resolved = (colon == 1 || colon == 2)
                            && parseUnsigned(iso[0 .. colon], at, hour)
                            && at == colon;
                        at = colon + 1;
                        resolved = resolved && iso.length - colon - 1 == 2
                            && parseUnsigned(iso, at, minute) && at == iso.length;
                    }
                    else if (iso.length == 1 || iso.length == 2)
                    {
                        at = 0;
                        resolved = parseUnsigned(iso, at, hour) && at == iso.length;
                    }
                    else if (iso.length > 2)
                    {
                        at = 1;
                        resolved = parseUnsigned(iso, at, minute) && at == iso.length;
                    }
                }
                if (resolved && hour <= long.max / 60
                    && minute <= cast(ulong) long.max - hour * 60)
                {
                    const totalMinutes = hour * 60 + minute;
                    if (totalMinutes > cast(ulong) long.max / 600_000_000)
                        return sdlErr!SdlScalar(decodeError(
                            SdlErrorCode.valueOutOfRange, token,
                            "GMT offset overflows Duration"));
                    value.utcOffset = (cast(long) totalMinutes).minutes;
                    if (zone[3] == '-') value.utcOffset = -value.utcOffset;
                    value.hasUtcOffset = true;
                }
            }
            return sdlOk(SdlScalar(value));
        }
        else break;
    case duration:
        static if (config.scalars.durations)
        {
            auto value = decodeDurationValue!config(token.raw, token);
            return value.hasError ? sdlErr!SdlScalar(value.error)
                : sdlOk(SdlScalar(value.value));
        }
        else break;
    case eof:
    case newline:
    case semicolon:
    case colon:
    case equals:
    case openBrace:
    case closeBrace:
    case identifier:
        return sdlErr!SdlScalar(decodeError(SdlErrorCode.unexpectedKind, token,
            "token is not an SDL scalar"));
    }
    return sdlErr!SdlScalar(decodeError(SdlErrorCode.unsupportedFeature, token,
        "scalar kernel is absent from this SDL profile"));
}

@("sdl.lexer.kernelAvailability")
@safe pure nothrow @nogc
unittest
{
    import std.range.primitives : isForwardRange;

    static assert(isForwardRange!(SdlLexer!sdlFull));
    static assert(sdlScalarKernelAvailable!(sdlFull, SdlTokenKind.binary));
    static assert(sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.string_));
    static assert(sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.boolean));
    static assert(!sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.integer));
    static assert(!sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.character));
    static assert(!sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.binary));
    static assert(!sdlScalarKernelAvailable!(sdlDubRecipe, SdlTokenKind.duration));
}

@("sdl.lexer.borrowedLifetimeContract")
@safe
unittest
{
    static assert(__traits(compiles, () @safe {
        char[4] source = "name";
        char[10] sourceName = "memory.sdl";
        auto direct = SdlLexer!sdlFull(source[], sourceName[]);
        auto factory = lexSDL!sdlFull(source[], sourceName[]);
    }));
    static assert(__traits(compiles, () @safe {
        SdlScalarStorage storage;
        auto token = SdlToken(SdlTokenKind.string_, `"value"`, SdlSpan.init);
        auto decoded = decodeSdlScalar!sdlFull(token, storage);
    }));
    static assert(!__traits(compiles, () @safe {
        char[4] source = "name";
        return lexSDL!sdlFull(source[]);
    }), "a lexer must not escape its stack-backed source");
    static assert(!__traits(compiles, () @safe {
        char[10] sourceName = "memory.sdl";
        return lexSDL!sdlFull("name", sourceName[]);
    }), "a lexer must not escape its stack-backed source name");
    static assert(!__traits(compiles, () @safe {
        char[4] source = "name";
        auto lexer = lexSDL!sdlFull(source[]);
        return lexer.front.value;
    }), "a token raw slice must not escape its lexer's source");
    static assert(!__traits(compiles, () @safe {
        SdlScalarStorage storage;
        auto token = SdlToken(SdlTokenKind.string_, `"value"`, SdlSpan.init);
        return decodeSdlScalar!sdlFull(token, storage);
    }), "a decoded Expected must not escape its payload storage");

    char[4] source = "name";
    char[10] sourceName = "memory.sdl";
    auto lexer = lexSDL!sdlFull(source[], sourceName[]);
    auto item = lexer.front;
    assert(item.hasValue && item.value.raw == "name");
    assert(item.value.raw.ptr == source.ptr);
}

version (unittest)
{
    private enum uncheckedFull = SdlParserConfig(
        scalars: sdlFull.scalars,
        syntax: sdlFull.syntax,
        validateUtf8: false,
        maxDepth: sdlFull.maxDepth,
    );

    private struct TokenCase
    {
        string source;
        SdlTokenKind kind;
    }

    private struct ErrorCase
    {
        string source;
        SdlErrorCode code;
    }

    private struct BomCase
    {
        string source;
        size_t width;
    }

    private SdlToken oneToken(SdlParserConfig config)(scope const(char)[] source)
    {
        auto lexer = lexSDL!config(source, "fixture.sdl");
        assert(!lexer.empty);
        auto item = lexer.front;
        if (item.hasError)
            throw new AssertError(item.error.toString);
        return item.value;
    }

    private SdlError oneError(SdlParserConfig config)(scope const(char)[] source)
    {
        auto lexer = lexSDL!config(source, "fixture.sdl");
        assert(!lexer.empty);
        auto item = lexer.front;
        assert(item.hasError);
        return item.error;
    }

    private void consumeArbitrary(SdlParserConfig config)(scope const(char)[] source)
    {
        auto lexer = lexSDL!config(source);
        size_t remaining = source.length * 2 + 8;
        while (!lexer.empty && remaining--)
        {
            auto item = lexer.front;
            lexer.popFront();
            if (item.hasError)
                break;
        }
        assert(remaining > 0);
        assert(lexer.empty);
    }
}

@("sdl.lexer.completeTokenVocabulary")
@system unittest
{
    static immutable TokenCase[] cases = [
        TokenCase(";", SdlTokenKind.semicolon),
        TokenCase(":", SdlTokenKind.colon),
        TokenCase("=", SdlTokenKind.equals),
        TokenCase("{", SdlTokenKind.openBrace),
        TokenCase("}", SdlTokenKind.closeBrace),
        TokenCase("name", SdlTokenKind.identifier),
        TokenCase("null", SdlTokenKind.null_),
        TokenCase("on", SdlTokenKind.boolean),
        TokenCase(`"text"`, SdlTokenKind.string_),
        TokenCase("`raw`", SdlTokenKind.string_),
        TokenCase("'x'", SdlTokenKind.character),
        TokenCase("-42", SdlTokenKind.integer),
        TokenCase("42L", SdlTokenKind.longInteger),
        TokenCase(".5F", SdlTokenKind.float_),
        TokenCase("0.5", SdlTokenKind.double_),
        TokenCase("0.5BD", SdlTokenKind.decimal),
        TokenCase("[Zm9v]", SdlTokenKind.binary),
        TokenCase("2026/8/25", SdlTokenKind.date),
        TokenCase("2026/8/25 01:02:03.004", SdlTokenKind.dateTime),
        TokenCase("2026/8/25 01:02:03-GMT+02:00", SdlTokenKind.zonedDateTime),
        TokenCase("-1d:01:02:03.0000001", SdlTokenKind.duration),
    ];
    foreach (test; cases)
    {
        const token = oneToken!sdlFull(test.source);
        assert(token.kind == test.kind);
        assert(token.raw == test.source);
        assert(token.span.start.byteOffset == 0 && token.span.end.byteOffset == test.source.length);
    }
}

@("sdl.lexer.triviaContinuationAndUnicodeNames")
@system unittest
{
    auto lexer = lexSDL!sdlFull(
        "\xEF\xBB\xBF# one\r\n/* two */ α:β \\\n// three\n= `value`;", "unicode.sdl");
    static immutable expected = [
        SdlTokenKind.newline,
        SdlTokenKind.identifier,
        SdlTokenKind.colon,
        SdlTokenKind.identifier,
        SdlTokenKind.newline,
        SdlTokenKind.equals,
        SdlTokenKind.string_,
        SdlTokenKind.semicolon,
        SdlTokenKind.eof,
    ];
    size_t index;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        if (item.hasError)
            throw new AssertError(item.error.toString);
        assert(index < expected.length);
        assert(item.value.kind == expected[index]);
        index++;
        if (item.value.kind == SdlTokenKind.identifier && item.value.raw == "α")
            assert(item.value.span.start.byteOffset == 20);
        lexer.popFront();
    }
    assert(index == expected.length);
}

@("sdl.lexer.logicalNewlinePositions")
@system unittest
{
    auto lexer = lexSDL!sdlFull("a\rb\nc\r\nd\u2028e\u2029f");
    uint expectedLine = 1;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        assert(item.hasValue);
        if (item.value.kind == SdlTokenKind.identifier)
        {
            assert(item.value.span.start.line == expectedLine++);
            assert(item.value.span.start.column == 1);
        }
        lexer.popFront();
    }
    assert(expectedLine == 7);

    const bomToken = oneToken!sdlDubCompat("\xEF\xBB\xBFname");
    assert(bomToken.span.start.byteOffset == 3);
    assert(bomToken.span.start.line == 1 && bomToken.span.start.column == 1);
}

@("sdl.lexer.exactPositionAndBomPins")
@system unittest
{
    static immutable size_t[] identifierOffsets = [0, 2, 4, 7, 11, 15];
    static immutable size_t[] newlineStarts = [1, 3, 5, 8, 12];
    static immutable size_t[] newlineEnds = [2, 4, 7, 11, 15];
    auto lexer = lexSDL!sdlFull("a\rb\nc\r\nd\u2028e\u2029f");
    size_t identifierIndex;
    size_t newlineIndex;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        assert(item.hasValue);
        const token = item.value;
        if (token.kind == SdlTokenKind.identifier)
        {
            assert(token.span.start.byteOffset == identifierOffsets[identifierIndex]);
            assert(token.span.start.line == identifierIndex + 1);
            assert(token.span.start.column == 1);
            identifierIndex++;
        }
        else if (token.kind == SdlTokenKind.newline)
        {
            assert(token.span.start.byteOffset == newlineStarts[newlineIndex]);
            assert(token.span.end.byteOffset == newlineEnds[newlineIndex]);
            assert(token.span.start.line == newlineIndex + 1);
            assert(token.span.start.column == 2);
            assert(token.span.end.line == newlineIndex + 2);
            assert(token.span.end.column == 1);
            newlineIndex++;
        }
        lexer.popFront();
    }
    assert(identifierIndex == identifierOffsets.length);
    assert(newlineIndex == newlineStarts.length);

    static immutable BomCase[] unsupported = [
        BomCase("\xFF\xFEa", 2),
        BomCase("\xFE\xFFa", 2),
        BomCase("\xFF\xFE\x00\x00a", 4),
        BomCase("\x00\x00\xFE\xFFa", 4),
    ];
    foreach (test; unsupported)
    {
        const failure = oneError!sdlFull(test.source);
        assert(failure.code == SdlErrorCode.unsupportedBom);
        assert(failure.span.start.byteOffset == 0);
        assert(failure.span.end.byteOffset == test.width);
    }
    const utf8 = oneToken!sdlFull("\xEF\xBB\xBFname");
    assert(utf8.raw == "name" && utf8.span.start.byteOffset == 3);
    assert(utf8.span.start.line == 1 && utf8.span.start.column == 1);

    const unicodeNumeric = oneToken!sdlFull("α١");
    assert(unicodeNumeric.kind == SdlTokenKind.identifier
        && unicodeNumeric.raw == "α١");
}

@("sdl.lexer.malformedInputMatrix")
@system unittest
{
    static immutable ErrorCase[] cases = [
        ErrorCase("\xFF\xFEa", SdlErrorCode.unsupportedBom),
        ErrorCase("\xC0", SdlErrorCode.invalidUtf8),
        ErrorCase(`"open`, SdlErrorCode.unterminatedString),
        ErrorCase(`"bad\q"`, SdlErrorCode.invalidEscape),
        ErrorCase("'ab'", SdlErrorCode.invalidEscape),
        ErrorCase("/* open", SdlErrorCode.unterminatedComment),
        ErrorCase("12wat", SdlErrorCode.invalidNumber),
        ErrorCase("[Zg=]", SdlErrorCode.invalidBase64),
        ErrorCase("[Z===]", SdlErrorCode.invalidBase64),
        ErrorCase("\\", SdlErrorCode.unexpectedEof),
    ];
    foreach (test; cases)
    {
        const failure = oneError!sdlFull(test.source);
        assert(failure.code == test.code);
        assert(failure.span.start.byteOffset <= failure.span.end.byteOffset);
        assert(failure.span.end.byteOffset <= test.source.length);
    }
}

@("sdl.lexer.base64CanonicalValidation")
@system unittest
{
    SdlScalarStorage storage;
    foreach (source; ["[]", "[TQ==]", "[TWE=]", "[TWFu]",
            "[ \t\n ]", "[TQ== \r\n]"])
    {
        auto token = oneToken!sdlFull(source);
        assert(token.kind == SdlTokenKind.binary && token.raw == source);
        auto decoded = decodeSdlScalar!sdlFull(token, storage);
        assert(decoded.hasValue);
    }
    foreach (source; ["[TR==]", "[TWF=]", "[T=Fu]", "[TQ=]",
            "[TQ]", "[====]"])
    {
        const failure = oneError!sdlFull(source);
        assert(failure.code == SdlErrorCode.invalidBase64);
        assert(failure.span.start.byteOffset == 0
            && failure.span.end.byteOffset == source.length);
    }
    assert(oneError!sdlDubRecipe("[TQ==]").code
        == SdlErrorCode.unsupportedFeature);
}

@("sdl.lexer.integerAndFloatingBoundaries")
@system unittest
{
    import std.array : replicate;

    SdlScalarStorage storage;
    foreach (source; ["-2147483648", "2147483647"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; ["-2147483649", "2147483648"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage)
            .error.code == SdlErrorCode.numberOutOfRange);
    foreach (source; ["-9223372036854775808L", "9223372036854775807L"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; ["-9223372036854775809L", "9223372036854775808L"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage)
            .error.code == SdlErrorCode.numberOutOfRange);

    foreach (source; ["1BD", "1Bd", "1bD", "1bd"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; ["1L", "1l", "1F", "1f", "1D", "1d"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; ["1B", "1BDF", "1.0L", "1.0B", "1e2"])
        assert(oneError!sdlFull(source).code == SdlErrorCode.invalidNumber);

    const huge = "9".replicate(400) ~ "D";
    auto overflow = decodeSdlScalar!sdlFull(oneToken!sdlFull(huge), storage);
    assert(overflow.hasError && overflow.error.code == SdlErrorCode.numberOutOfRange);
    const hugeFloat = "9".replicate(100) ~ "F";
    auto floatOverflow = decodeSdlScalar!sdlFull(oneToken!sdlFull(hugeFloat), storage);
    assert(floatOverflow.hasError
        && floatOverflow.error.code == SdlErrorCode.numberOutOfRange);
}

@("sdl.lexer.stringCharacterAndRawMatrices")
@system unittest
{
    SdlScalarStorage storage;
    foreach (source; [`"\n"`, `"\r"`, `"\t"`, `"\""`, `"\\"`,
            "\"a \\\nb\""])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; [`"\q"`, `"\'"`, `"unterminated`, "\"line\nfeed\""])
        assert(oneError!sdlFull(source).code == (source == `"unterminated`
            || source == "\"line\nfeed\"" ? SdlErrorCode.unterminatedString
                : SdlErrorCode.invalidEscape));

    foreach (source; [`'x'`, `'\n'`, `'\r'`, `'\t'`, `'\''`, `'\\'`, `'月'`])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; [`''`, `'xy'`, `'\q'`, "'\n'"])
    {
        const failure = oneError!sdlFull(source);
        assert(failure.code == SdlErrorCode.invalidEscape
            || failure.code == SdlErrorCode.unterminatedString);
    }

    auto raw = decodeSdlScalar!sdlFull(oneToken!sdlFull("`a\r\nb\u2028c`"), storage);
    assert(raw.hasValue && raw.value.stringValue == "a\r\nb\u2028c");
}

@("sdl.lexer.temporalSemanticPolicies")
@system unittest
{
    SdlScalarStorage storage;
    foreach (source; ["2024/2/29", "2000/2/29"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    foreach (source; ["2023/2/29", "2024/0/1", "2024/13/1",
            "2024/1/0", "2024/4/31"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage)
            .error.code == SdlErrorCode.invalidDate);

    auto minuteFraction = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("2024/1/2 03:04.5"), storage);
    assert(minuteFraction.hasValue && minuteFraction.value.dateTime.second == 0
        && minuteFraction.value.dateTime.fractionHnsecs == 5_000_000);
    foreach (source; ["2024/1/2 03:04.1", "2024/1/2 03:04.12",
            "2024/1/2 03:04.123"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    assert(decodeSdlScalar!sdlFull(
        oneToken!sdlFull("2024/1/2 03:04.1234"), storage)
        .error.code == SdlErrorCode.invalidDateTime);

    foreach (source; ["00:00:00.1", "00:00:00.12", "00:00:00.123",
            "00:00:00.1234", "00:00:00.12345", "00:00:00.123456",
            "00:00:00.1234567"])
        assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(source), storage).hasValue);
    assert(decodeSdlScalar!sdlFull(oneToken!sdlFull("00:00:00.12345678"), storage)
        .error.code == SdlErrorCode.invalidDuration);
    assert(decodeSdlScalar!sdlFull(oneToken!sdlFull(
        "18446744073709551615d:18446744073709551615:0:0"), storage)
        .error.code == SdlErrorCode.valueOutOfRange);
}

@("sdl.lexer.sparklesStrictGmtOffsets")
@system unittest
{
    SdlScalarStorage storage;
    foreach (source; ["GMT+00", "GMT-23", "GMT+00:00", "GMT-23:59"])
    {
        const scalar = "2024/1/2 03:04-" ~ source;
        auto decoded = decodeSdlScalar!sdlFull(oneToken!sdlFull(scalar), storage);
        assert(decoded.hasValue && decoded.value.zonedDateTime.hasUtcOffset);
    }
    foreach (source; ["GMT+0", "GMT+000", "GMT+0:00", "GMT+00:0",
            "GMT+24", "GMT-24:00", "GMT+23:60", "GMT+"])
    {
        const scalar = "2024/1/2 03:04-" ~ source;
        auto decoded = decodeSdlScalar!sdlFull(oneToken!sdlFull(scalar), storage);
        assert(decoded.hasError && decoded.error.code == SdlErrorCode.invalidDateTime);
    }

    auto dubShort = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("2024/1/2 03:04-GMT+2"), storage);
    assert(dubShort.hasValue && dubShort.value.zonedDateTime.utcOffset == 2.hours);
    auto dubMalformed = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("2024/1/2 03:04-GMT+"), storage);
    assert(dubMalformed.hasValue && !dubMalformed.value.zonedDateTime.hasUtcOffset);
}

@("sdl.lexer.commentAndContinuationFailures")
@system unittest
{
    auto lexer = lexSDL!sdlFull("# hash\n// slash\n-- dash\n/* block */name");
    size_t newlines;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        assert(item.hasValue);
        if (item.value.kind == SdlTokenKind.newline) newlines++;
        lexer.popFront();
    }
    assert(newlines == 3);

    assert(oneError!sdlFull("\\").code == SdlErrorCode.unexpectedEof);
    assert(oneError!sdlFull("\\ value\n").code
        == SdlErrorCode.unexpectedCharacter);
    assert(oneError!sdlFull("/* unterminated").code
        == SdlErrorCode.unterminatedComment);
}

@("sdl.lexer.scalarSemanticDecoding")
@system unittest
{
    SdlScalarStorage storage;

    auto nullValue = decodeSdlScalar!sdlFull(oneToken!sdlFull("null"), storage);
    assert(nullValue.hasValue && nullValue.value.kind == SdlScalarKind.null_);
    auto boolean = decodeSdlScalar!sdlFull(oneToken!sdlFull("off"), storage);
    assert(boolean.hasValue && !boolean.value.boolean);
    auto stringValue = decodeSdlScalar!sdlFull(oneToken!sdlFull(`"a\n\"b"`), storage);
    assert(stringValue.hasValue && stringValue.value.stringValue == "a\n\"b");
    auto rawString = decodeSdlScalar!sdlFull(oneToken!sdlFull("`a\\n`"), storage);
    assert(rawString.hasValue && rawString.value.stringValue == `a\n`);
    auto character = decodeSdlScalar!sdlFull(oneToken!sdlFull("'€'"), storage);
    assert(character.hasValue && character.value.character == '€');
    auto integer = decodeSdlScalar!sdlFull(oneToken!sdlFull("-2147483648"), storage);
    assert(integer.hasValue && integer.value.integer == int.min);
    auto longValue = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("9223372036854775807L"), storage);
    assert(longValue.hasValue && longValue.value.longInteger == long.max);
    auto floatValue = decodeSdlScalar!sdlFull(oneToken!sdlFull(".5F"), storage);
    assert(floatValue.hasValue && floatValue.value.floatValue == 0.5f);
    auto doubleValue = decodeSdlScalar!sdlFull(oneToken!sdlFull("0.25D"), storage);
    assert(doubleValue.hasValue && doubleValue.value.doubleValue == 0.25);
    auto decimal = decodeSdlScalar!sdlFull(oneToken!sdlFull("0.125BD"), storage);
    if (decimal.hasError)
        throw new AssertError(decimal.error.toString);
    assert(decimal.value.decimalValue == 0.125L);
    auto binary = decodeSdlScalar!sdlFull(oneToken!sdlFull("[AAEC/v8=]"), storage);
    assert(binary.hasValue && binary.value.binary == [0, 1, 2, 0xFE, 0xFF]);
    auto date = decodeSdlScalar!sdlFull(oneToken!sdlFull("2024/2/29"), storage);
    assert(date.hasValue && date.value.date == Date(2024, 2, 29));
    auto local = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("2026/8/25 01:02:03.004"), storage);
    assert(local.hasValue && local.value.dateTime.fractionHnsecs == 40_000);
    auto zoned = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("2026/8/25 01:02:03-GMT-02:30"), storage);
    assert(zoned.hasValue && zoned.value.zonedDateTime.hasUtcOffset);
    assert(zoned.value.zonedDateTime.utcOffset == -150.minutes);
    auto namedZone = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("2026/8/25 01:02:03-Europe/Sofia"), storage);
    assert(namedZone.hasValue && namedZone.value.zonedDateTime.zone == "Europe/Sofia");
    assert(!namedZone.value.zonedDateTime.hasUtcOffset);
    auto duration = decodeSdlScalar!sdlFull(
        oneToken!sdlFull("1d:01:02:03.0000001"), storage);
    assert(duration.hasValue
        && duration.value.duration.total!"hnsecs" == 901_230_000_001);

    assert(decodeSdlScalar!sdlFull(oneToken!sdlFull("2147483648"), storage)
        .error.code == SdlErrorCode.numberOutOfRange);
    assert(decodeSdlScalar!sdlFull(oneToken!sdlFull("2023/2/29"), storage)
        .error.code == SdlErrorCode.invalidDate);
    assert(decodeSdlScalar!sdlFull(oneToken!sdlFull("25:00:00"), storage)
        .hasValue); // Duration components normalize in the Sparkles profile.
}

@("sdl.lexer.deferredDecoderRejectsMalformedTokens")
@system unittest
{
    SdlScalarStorage storage;
    static immutable TokenCase[] malformed = [
        TokenCase("nil", SdlTokenKind.null_),
        TokenCase("yes", SdlTokenKind.boolean),
        TokenCase("plain", SdlTokenKind.string_),
        TokenCase("\"line\nfeed\"", SdlTokenKind.string_),
        TokenCase("'ab'", SdlTokenKind.character),
        TokenCase("1.0L", SdlTokenKind.longInteger),
        TokenCase("BD", SdlTokenKind.decimal),
        TokenCase("TQ==", SdlTokenKind.binary),
        TokenCase("2024/2/30", SdlTokenKind.date),
        TokenCase("2024/1/2", SdlTokenKind.dateTime),
        TokenCase("2024/1/2 03:04", SdlTokenKind.zonedDateTime),
        TokenCase("00:00", SdlTokenKind.duration),
    ];
    foreach (test; malformed)
    {
        auto decoded = decodeSdlScalar!sdlFull(
            SdlToken(test.kind, test.source, SdlSpan.init), storage);
        assert(decoded.hasError);
    }

    const invalidUtf8 = SdlToken(SdlTokenKind.string_, "\"\xFF\"", SdlSpan.init);
    assert(decodeSdlScalar!sdlFull(invalidUtf8, storage).error.code
        == SdlErrorCode.invalidUtf8);
}

@("sdl.lexer.recipeProfileDisabledFamilies")
@system unittest
{
    static immutable string[] disabled = [
        "null", "'x'", "1", "1L", "1F", "1.0", "1BD", "[Zg==]",
        "2026/8/25", "2026/8/25 01:02:03",
        "2026/8/25 01:02:03-GMT+02", "01:02:03",
    ];
    foreach (source; disabled)
    {
        const failure = oneError!sdlDubRecipe(source);
        assert(failure.code == SdlErrorCode.unsupportedFeature);
        assert(failure.span.start.byteOffset == 0);
        assert(failure.span.end.byteOffset == source.length);
    }
    assert(oneToken!sdlDubRecipe(`"value"`).kind == SdlTokenKind.string_);
    assert(oneToken!sdlDubRecipe("false").kind == SdlTokenKind.boolean);
}

@("sdl.lexer.namedProfileArbitraryByteSmoke")
@system unittest
{
    uint state = 0xC0FFEE42;
    char[96] bytes;
    foreach (_; 0 .. 512)
    {
        state = state * 1_664_525 + 1_013_904_223;
        const length = state % (bytes.length + 1);
        foreach (ref value; bytes[0 .. length])
        {
            state = state * 1_664_525 + 1_013_904_223;
            value = cast(char)(state >> 24);
        }
        consumeArbitrary!sdlFull(bytes[0 .. length]);
        consumeArbitrary!sdlDubCompat(bytes[0 .. length]);
        consumeArbitrary!sdlDubRecipe(bytes[0 .. length]);
        consumeArbitrary!uncheckedFull(bytes[0 .. length]);
    }

    foreach (source; ["#\xFF", "/*\xFF*/", "12\xFF", "`\xFF`", "[\xFF]"])
        assert(oneError!uncheckedFull(source).code == SdlErrorCode.invalidUtf8);
}

@("sdl.lexer.sparklesVsPinnedDubContinuation")
@system unittest
{
    // Adapted case selection: source/dub/internal/sdlang/lexer.d at
    // dlang/dub 5efed360e1c9342453bc5dd19339c75981526d83.
    auto sparkles = lexSDL!sdlFull("name \\\n\nvalue");
    assert(sparkles.front.value.kind == SdlTokenKind.identifier);
    sparkles.popFront();
    assert(sparkles.front.value.kind == SdlTokenKind.newline);

    auto dub = lexSDL!sdlDubCompat("name \\\n\nvalue");
    assert(dub.front.value.kind == SdlTokenKind.identifier);
    dub.popFront();
    assert(dub.front.value.kind == SdlTokenKind.identifier);
    assert(dub.front.value.raw == "value");
}

@("sdl.lexer.pinnedDubTemporalCompatibility")
@system unittest
{
    // Adapted fixture selection: source/dub/internal/sdlang/lexer.d at
    // dlang/dub 5efed360e1c9342453bc5dd19339c75981526d83.
    SdlScalarStorage storage;

    auto commented = oneToken!sdlDubCompat("2013/2/22/*foo*/07:53");
    assert(commented.kind == SdlTokenKind.dateTime);
    auto commentedValue = decodeSdlScalar!sdlDubCompat(commented, storage);
    assert(commentedValue.hasValue && commentedValue.value.dateTime.hour == 7);

    auto rollover = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("2013/2/22 34:65:77.1234"), storage);
    assert(rollover.hasValue);
    assert(rollover.value.dateTime.date == Date(2013, 2, 23));
    assert(rollover.value.dateTime.hour == 11);
    assert(rollover.value.dateTime.minute == 6);
    assert(rollover.value.dateTime.second == 18);
    assert(rollover.value.dateTime.fractionHnsecs == 2_340_000);

    auto negativeClock = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("2013/2/22 -07:53"), storage);
    assert(negativeClock.hasValue);
    assert(negativeClock.value.dateTime.date == Date(2013, 2, 21));
    assert(negativeClock.value.dateTime.hour == 16
        && negativeClock.value.dateTime.minute == 7);

    auto duration = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("00:00:01.1234"), storage);
    assert(duration.hasValue
        && duration.value.duration.total!"msecs" == 2_234);

    auto oddGmt = decodeSdlScalar!sdlDubCompat(
        oneToken!sdlDubCompat("2013/2/22 07:53-GMT+123"), storage);
    assert(oddGmt.hasValue && oddGmt.value.zonedDateTime.hasUtcOffset);
    assert(oddGmt.value.zonedDateTime.utcOffset == 23.minutes);

    auto dubBoundary = oneToken!sdlDubCompat(
        "2013/2/22 07:53-Europe/Sofia;");
    assert(dubBoundary.raw == "2013/2/22 07:53-Europe/Sofia;");
    auto sparklesBoundary = oneToken!sdlFull(
        "2013/2/22 07:53-Europe/Sofia;");
    assert(sparklesBoundary.raw == "2013/2/22 07:53-Europe/Sofia");
}

@("sdl.lexer.allInTreeDubRecipes")
@system unittest
{
    import std.file : SpanMode, dirEntries, isSymlink, readText;
    import std.path : baseName;

    static void check(string path)
    {
        const source = readText(path);
        auto lexer = lexSDL!sdlDubRecipe(source, path);
        while (!lexer.empty)
        {
            auto item = lexer.front;
            if (item.hasError)
                throw new AssertError(item.error.toString);
            lexer.popFront();
        }
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
                check(entry.name);
                count++;
            }
        }
    }

    size_t count;
    visit(".", count);
    assert(count > 100);
}

@("sdl.lexer.pinnedDubRecipeSnapshot")
@system unittest
{
    import std.file : readText;

    // Direct compatibility fixture: dlang/dub dub.sdl at
    // 5efed360e1c9342453bc5dd19339c75981526d83 (MIT; see the fixture README
    // and libs/wired/THIRD_PARTY_NOTICES.md).
    enum path = "libs/wired/src/sparkles/wired/sdl/fixtures/"
        ~ "dub-5efed360-recipe.snapshot.sdl";
    const source = readText(path);
    auto lexer = lexSDL!sdlDubRecipe(source, path);
    size_t count;
    while (!lexer.empty)
    {
        auto item = lexer.front;
        if (item.hasError)
            throw new AssertError(item.error.toString);
        count++;
        lexer.popFront();
    }
    assert(count > 50);
}
