/**
The DQL path grammar (SPEC §2.1) as a reader and a writer of steps.

A path is `Segment ( "." Segment | "[" Digits "]" | "[" String "]" )*`, where
a segment is an identifier or a quoted `["…"]` name in JSON string escaping.
An identifier segment is a run of the bytes the DQL lexer keeps inside one
identifier, excluding `.`, `[` and `]`, so every path the parser hands a
resolver reads back step by step. `validateDqlPath` reports the first fault
at its byte offset; `dqlPathSteps` walks a valid path without allocating; a
step's `nameEquals` and `writeName` see its decoded name. `writeDqlSegment`
writes a name back, quoted when it is not an identifier, so a printed path
parses to the same steps. Hosts that address their own data by DQL paths —
the SDL selector in `sparkles:wired` — read paths here rather than
re-implement the grammar.
*/
module sparkles.dql.path;

import std.range.primitives : put;

import sparkles.base.expected : Expected, err, ok;
import sparkles.dql.engine : DqlParseError;

/// What one step of a path addresses.
enum DqlPathStepKind : ubyte
{
    member, /// A named segment, an identifier or quoted.
    index,  /// A `[Digits]` positional index.
}

/// One step of a path: a segment's name, or an index.
struct DqlPathStep
{
    DqlPathStepKind kind; /// Which of the two the step is.
    /// A `member` step's name as written: an identifier, or the escaped
    /// text between a quoted segment's quotes (see `quoted`).
    const(char)[] name;
    bool quoted;          /// The name is a JSON string body still escaped.
    size_t index;         /// The number, for an `index` step.
    size_t offset;        /// Byte offset of the step's first byte in the path.

    /// Whether the decoded name is `text`.
    bool nameEquals(scope const(char)[] text) const scope @safe pure nothrow @nogc
        => nameEquals(text, null, null);

    /// Whether the decoded name is `a ~ b ~ c` — a qualified name's
    /// `namespace`, `:` and local name, say — without building it.
    bool nameEquals(scope const(char)[] a, scope const(char)[] b, scope const(char)[] c)
        const scope @safe pure nothrow @nogc
    {
        auto bytes = DqlNameBytes(name, quoted);
        bool consume(scope const(char)[] part)
        {
            foreach (ch; part)
            {
                if (bytes.empty || bytes.front != ch)
                    return false;
                bytes.popFront();
            }
            return true;
        }
        return consume(a) && consume(b) && consume(c) && bytes.empty;
    }

    /// Writes the decoded name to `writer`.
    void writeName(Writer)(ref Writer writer) const scope
    {
        for (auto bytes = DqlNameBytes(name, quoted); !bytes.empty; bytes.popFront())
        {
            const char[1] c = bytes.front;
            put(writer, c[]);
        }
    }
}

/// Whether `c` may appear in an identifier segment: the DQL lexer keeps it
/// inside an identifier, and it is not `.`, `[` or `]`.
bool isDqlSegmentByte(char c) @safe pure nothrow @nogc
{
    switch (c)
    {
        case ' ', '\t', '\r', '\n', '(', ')', ',', '=', '!', '<', '>', '&', '|',
            '"', '\'', '`', '.', '[', ']':
            return false;
        default:
            return true;
    }
}

private uint hexValue(char c) @safe pure nothrow @nogc
{
    if (c >= '0' && c <= '9')
        return c - '0';
    if (c >= 'a' && c <= 'f')
        return c - 'a' + 10;
    if (c >= 'A' && c <= 'F')
        return c - 'A' + 10;
    return uint.max;
}

// The four hex digits at `text[at .. at + 4]`, or uint.max.
private uint hex4(scope const(char)[] text, size_t at) @safe pure nothrow @nogc
{
    if (at + 4 > text.length)
        return uint.max;
    uint value;
    foreach (c; text[at .. at + 4])
    {
        const digit = hexValue(c);
        if (digit == uint.max)
            return uint.max;
        value = value << 4 | digit;
    }
    return value;
}

/** Scans the JSON string whose opening quote is `path[at]`; returns the
offset of its closing quote, or leaves the fault in `fault`. Escapes are
JSON's; a `\u` high surrogate must be followed by a `\u` low one. */
private size_t scanString(scope const(char)[] path, size_t at, out DqlParseError fault)
    @safe pure nothrow @nogc
{
    size_t i = at + 1;
    while (i < path.length)
    {
        const c = path[i];
        if (c == '"')
            return i;
        if (cast(ubyte) c < 0x20)
        {
            fault = DqlParseError("control character in a quoted segment", i, 1);
            return 0;
        }
        if (c != '\\')
        {
            i++;
            continue;
        }
        if (i + 1 >= path.length)
            break;
        switch (path[i + 1])
        {
            case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
                i += 2;
                continue;
            case 'u':
                const unit = hex4(path, i + 2);
                if (unit == uint.max || (unit >= 0xDC00 && unit <= 0xDFFF))
                {
                    fault = DqlParseError("bad \\u escape in a quoted segment", i, 2);
                    return 0;
                }
                if (unit >= 0xD800 && unit <= 0xDBFF)
                {
                    const low = i + 7 < path.length && path[i + 6] == '\\'
                        && path[i + 7] == 'u' ? hex4(path, i + 8) : uint.max;
                    if (low < 0xDC00 || low > 0xDFFF)
                    {
                        fault = DqlParseError("unpaired surrogate in a quoted segment", i, 6);
                        return 0;
                    }
                    i += 12;
                    continue;
                }
                i += 6;
                continue;
            default:
                fault = DqlParseError("bad escape in a quoted segment", i, 2);
                return 0;
        }
    }
    fault = DqlParseError("unterminated quoted segment", at, path.length - at);
    return 0;
}

/** Reads the step at `at`, advancing it; `first` selects the leading
segment, which has no `.` before it. A fault is left in `fault`. */
package(sparkles.dql) DqlPathStep readStep(return scope const(char)[] path, ref size_t at,
    bool first, out DqlParseError fault) @safe pure nothrow @nogc
{
    const start = at;
    if (path[at] == '[')
    {
        at++;
        if (at < path.length && path[at] == '"')
        {
            const close = scanString(path, at, fault);
            if (fault.message !is null)
                return DqlPathStep.init;
            if (close + 1 >= path.length || path[close + 1] != ']')
            {
                fault = DqlParseError("expected ']' after a quoted segment", close + 1, 1);
                return DqlPathStep.init;
            }
            const body_ = path[at + 1 .. close];
            at = close + 2;
            return DqlPathStep(DqlPathStepKind.member, body_, true, 0, start);
        }
        if (first)
        {
            fault = DqlParseError("an index must follow a segment", start, 1);
            return DqlPathStep.init;
        }
        const digits = at;
        size_t value;
        while (at < path.length && path[at] >= '0' && path[at] <= '9')
        {
            const digit = path[at] - '0';
            if (value > (size_t.max - digit) / 10)
            {
                fault = DqlParseError("index overflows", digits, at - digits + 1);
                return DqlPathStep.init;
            }
            value = value * 10 + digit;
            at++;
        }
        if (at == digits)
            fault = DqlParseError("expected digits or a quoted name in brackets", at, 1);
        else if (at >= path.length || path[at] != ']')
            fault = DqlParseError("unclosed index", start, at - start);
        if (fault.message !is null)
            return DqlPathStep.init;
        at++;
        return DqlPathStep(DqlPathStepKind.index, null, false, value, start);
    }
    if (!first)
    {
        if (path[at] != '.')
        {
            fault = DqlParseError("expected '.' or '[' between path steps", at, 1);
            return DqlPathStep.init;
        }
        at++;
        if (at < path.length && path[at] == '[')
        {
            // `."…"` is the grammar's `"." Segment` with a quoted segment.
            if (at + 1 < path.length && path[at + 1] == '"')
                return readStep(path, at, true, fault);
            fault = DqlParseError("expected a segment after '.'", at, 1);
            return DqlPathStep.init;
        }
    }
    const nameStart = at;
    while (at < path.length && isDqlSegmentByte(path[at]))
        at++;
    if (at == nameStart)
    {
        fault = DqlParseError("empty path segment", nameStart, 1);
        return DqlPathStep.init;
    }
    return DqlPathStep(DqlPathStepKind.member, path[nameStart .. at], false, 0, nameStart);
}

/** The number of steps in `path`, or the first fault in it at its byte
offset. An empty path is a fault. */
Expected!(size_t, DqlParseError) validateDqlPath(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    if (path.length == 0)
        return err!size_t(DqlParseError("empty path", 0, 0));
    size_t at, steps;
    while (at < path.length)
    {
        DqlParseError fault;
        readStep(path, at, steps == 0, fault);
        if (fault.message !is null)
            return err!size_t(fault);
        steps++;
    }
    return ok!DqlParseError(steps);
}

/// Forward range over the steps of a path $(LREF validateDqlPath) accepted.
struct DqlPathSteps
{
    private const(char)[] _path;
    private size_t _next;
    private DqlPathStep _front;
    private bool _empty;
    private bool _first = true;

    /// Positions the range on the first step of `path`.
    this(return scope const(char)[] path) @safe pure nothrow @nogc
    {
        _path = path;
        popFront();
    }

    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _empty;
    /// ditto
    DqlPathStep front() const return scope @safe pure nothrow @nogc
    in (!empty) => _front;
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    {
        if (_next >= _path.length)
        {
            _empty = true;
            return;
        }
        DqlParseError fault;
        _front = readStep(_path, _next, _first, fault);
        assert(fault.message is null, "dqlPathSteps: the path was not validated");
        _first = false;
    }
    /// ditto
    DqlPathSteps save() const return scope @safe pure nothrow @nogc => this;
}

/// The steps of `path`, which $(LREF validateDqlPath) has accepted.
DqlPathSteps dqlPathSteps(return scope const(char)[] path) @safe pure nothrow @nogc
    => DqlPathSteps(path);

/** Whether `a` and `b` are the same path step by step: the same kinds and
indexes, and names that decode alike, so `["x"].y` is `x.y`. Malformed
paths compare by their text. */
bool sameDqlPath(scope const(char)[] a, scope const(char)[] b) @safe pure nothrow @nogc
{
    if (a == b)
        return true;
    if (validateDqlPath(a).hasError || validateDqlPath(b).hasError)
        return false;
    auto left = dqlPathSteps(a), right = dqlPathSteps(b);
    for (; !left.empty && !right.empty; left.popFront(), right.popFront())
    {
        const l = left.front, r = right.front;
        if (l.kind != r.kind)
            return false;
        if (l.kind == DqlPathStepKind.index ? l.index != r.index : !sameName(l, r))
            return false;
    }
    return left.empty && right.empty;
}

private bool sameName(in DqlPathStep a, in DqlPathStep b) @safe pure nothrow @nogc
{
    auto left = DqlNameBytes(a.name, a.quoted), right = DqlNameBytes(b.name, b.quoted);
    for (; !left.empty && !right.empty; left.popFront(), right.popFront())
        if (left.front != right.front)
            return false;
    return left.empty && right.empty;
}

/** Input range over a name's decoded UTF-8 bytes: the identifier itself,
or a quoted segment's JSON string body with its escapes applied. */
struct DqlNameBytes
{
    private const(char)[] _text;
    private bool _quoted;
    private size_t _at;
    private char[4] _pending;
    private ubyte _pendingAt, _pendingLength;

    /// Positions the range on the first byte of `text`.
    this(return scope const(char)[] text, bool quoted) @safe pure nothrow @nogc
    {
        _text = text;
        _quoted = quoted;
        fill();
    }

    /// Input-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _pendingAt >= _pendingLength;
    /// ditto
    char front() const scope @safe pure nothrow @nogc
    in (!empty) => _pending[_pendingAt];
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    in (!empty)
    {
        if (++_pendingAt >= _pendingLength)
            fill();
    }

    // Decodes the next source unit into `_pending`.
    private void fill() scope @safe pure nothrow @nogc
    {
        _pendingAt = _pendingLength = 0;
        if (_at >= _text.length)
            return;
        const c = _text[_at];
        if (!_quoted || c != '\\')
        {
            _pending[0] = c;
            _pendingLength = 1;
            _at++;
            return;
        }
        const escape = _text[_at + 1];
        _at += 2;
        dchar code;
        switch (escape)
        {
            case 'b': code = '\b'; break;
            case 'f': code = '\f'; break;
            case 'n': code = '\n'; break;
            case 'r': code = '\r'; break;
            case 't': code = '\t'; break;
            case 'u':
                code = hex4(_text, _at);
                _at += 4;
                if (code >= 0xD800 && code <= 0xDBFF)
                {
                    const low = hex4(_text, _at + 2);
                    code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                    _at += 6;
                }
                break;
            default: code = escape; break; // `"`, `\`, `/`
        }
        encode(code);
    }

    private void encode(dchar code) scope @safe pure nothrow @nogc
    {
        if (code < 0x80)
        {
            _pending[0] = cast(char) code;
            _pendingLength = 1;
        }
        else if (code < 0x800)
        {
            _pending[0] = cast(char)(0xC0 | code >> 6);
            _pending[1] = cast(char)(0x80 | (code & 0x3F));
            _pendingLength = 2;
        }
        else if (code < 0x10000)
        {
            _pending[0] = cast(char)(0xE0 | code >> 12);
            _pending[1] = cast(char)(0x80 | (code >> 6 & 0x3F));
            _pending[2] = cast(char)(0x80 | (code & 0x3F));
            _pendingLength = 3;
        }
        else
        {
            _pending[0] = cast(char)(0xF0 | code >> 18);
            _pending[1] = cast(char)(0x80 | (code >> 12 & 0x3F));
            _pending[2] = cast(char)(0x80 | (code >> 6 & 0x3F));
            _pending[3] = cast(char)(0x80 | (code & 0x3F));
            _pendingLength = 4;
        }
    }
}

/** Whether `name` can be written as an identifier segment: not empty, every
byte a segment byte, and — `first` being the segment that opens a path —
neither a lexer keyword nor starting with a digit or `-`, which the lexer
would read as a number. */
bool isDqlIdentifierSegment(scope const(char)[] name, bool first) @safe pure nothrow @nogc
{
    if (name.length == 0)
        return false;
    foreach (c; name)
        if (!isDqlSegmentByte(c))
            return false;
    if (!first)
        return true;
    if ((name[0] >= '0' && name[0] <= '9') || name[0] == '-')
        return false;
    switch (name)
    {
        case "true", "false", "null", "regexMatch", "globMatch", "fuzzyMatch":
            return false;
        default:
            return true;
    }
}

/** Writes `name` as the next segment of a path: `.name` (or `name` when it
is `first`) for an identifier, `["…"]` with JSON escapes otherwise, so the
printed path parses back to the same steps. */
void writeDqlSegment(Writer)(ref Writer writer, scope const(char)[] name, bool first)
{
    if (isDqlIdentifierSegment(name, first))
    {
        if (!first)
            put(writer, ".");
        put(writer, name);
        return;
    }
    put(writer, `["`);
    foreach (c; name)
    {
        switch (c)
        {
            case '"': put(writer, `\"`); break;
            case '\\': put(writer, `\\`); break;
            case '\b': put(writer, `\b`); break;
            case '\f': put(writer, `\f`); break;
            case '\n': put(writer, `\n`); break;
            case '\r': put(writer, `\r`); break;
            case '\t': put(writer, `\t`); break;
            default:
                if (cast(ubyte) c < 0x20)
                {
                    static immutable digits = "0123456789abcdef";
                    const char[6] escape = ['\\', 'u', '0', '0', digits[c >> 4], digits[c & 0xF]];
                    put(writer, escape[]);
                }
                else
                {
                    const char[1] one = c;
                    put(writer, one[]);
                }
        }
    }
    put(writer, `"]`);
}

///
@("dql.path.validateDqlPath.grammar")
@safe pure nothrow @nogc
unittest
{
    static struct Case { string path; size_t steps; size_t faultAt = size_t.max; }
    static immutable Case[] cases = [
        Case("a", 1),
        Case("pointer.phase", 2),
        Case("stops[0]", 2),
        Case("a[12].b-c:d[3]", 4),
        Case("a[0][1]", 3),
        Case(`build["my.tool"].dependency`, 3),
        Case(`["a"]`, 1),
        Case(`["a"]["b"][0].c`, 4),
        Case(`a["q\"\\\/\b\f\n\r\t\u00e9\ud83d\ude00"]`, 2),
        Case(`a[""]`, 2),
        Case("", 0, 0),
        Case(".a", 0, 0),
        Case("a.", 0, 2),
        Case("a..b", 0, 2),
        Case("[0]", 0, 0),
        Case("a[]", 0, 2),
        Case("a[x]", 0, 2),
        Case("a[1", 0, 1),
        Case("a]", 0, 1),
        Case("a b", 0, 1),
        Case("a[99999999999999999999]", 0, 2),
        Case(`a["open`, 0, 2),
        Case(`a["open"`, 0, 8),
        Case(`a["bad\q"]`, 0, 6),
        Case(`a["\u12"]`, 0, 3),
        Case(`a["\udc00"]`, 0, 3),
        Case(`a["\ud83d"]`, 0, 3),
        Case(`a.["b"]`, 2),
        Case("a.[0]", 0, 2),
        Case("a[\"\x01\"]", 0, 3),
    ];
    foreach (c; cases)
    {
        const result = validateDqlPath(c.path);
        if (c.faultAt == size_t.max)
            assert(result.hasValue && result.value == c.steps, c.path);
        else
            assert(result.hasError && result.error.offset == c.faultAt, c.path);
    }
}

///
@("dql.path.dqlPathSteps.walk")
@safe pure nothrow @nogc
unittest
{
    const path = `configuration[1].dependency["my.tool"]`;
    assert(validateDqlPath(path).hasValue);
    auto steps = dqlPathSteps(path);
    assert(steps.front.kind == DqlPathStepKind.member && steps.front.name == "configuration");
    steps.popFront();
    assert(steps.front.kind == DqlPathStepKind.index && steps.front.index == 1);
    assert(steps.front.offset == 13);
    steps.popFront();
    assert(steps.front.name == "dependency" && steps.front.offset == 17);
    steps.popFront();
    assert(steps.front.quoted && steps.front.nameEquals("my", ".", "tool"));
    assert(!steps.front.nameEquals("my.too") && !steps.front.nameEquals("my.tool!"));
    steps.popFront();
    assert(steps.empty);
}

///
@("dql.path.DqlPathStep.decodedNames")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkWriter;

    const path = `["q\"\\\/\b\u00e9\ud83d\ude00"]`;
    assert(validateDqlPath(path).hasValue);
    const step = dqlPathSteps(path).front;
    assert(step.nameEquals("q\"\\/\bé😀"));
    checkWriter!((ref w) => step.writeName(w))("q\"\\/\bé😀");
    assert(sameDqlPath(`["a"].b[0]`, "a.b[0]"));
    assert(sameDqlPath(`a["b"]`, "a.b"));
    assert(!sameDqlPath("a.b", "a.c") && !sameDqlPath("a[0]", "a.b"));
}

///
@("dql.path.writeDqlSegment.roundTrip")
@safe pure nothrow
unittest
{
    import sparkles.base.buffer : UniqueBuffer;

    static immutable string[][] paths = [
        ["pointer", "phase"],
        ["build", "my.tool", "dependency"],
        ["3d", "x"],
        ["null"],
        ["-x", "-y"],
        ["q\"uote", "back\\slash", "tab\tand\nline", "\x01", "é😀", ""],
        ["ns:my.tool", "a[0]", "b c"],
    ];
    foreach (names; paths)
    {
        UniqueBuffer!char text;
        foreach (i, name; names)
            writeDqlSegment(text, name, i == 0);
        assert(validateDqlPath(text[]).hasValue, text[]);
        auto steps = dqlPathSteps(text[]);
        foreach (name; names)
        {
            assert(!steps.empty && steps.front.kind == DqlPathStepKind.member);
            assert(steps.front.nameEquals(name), text[]);
            steps.popFront();
        }
        assert(steps.empty);
    }
}
