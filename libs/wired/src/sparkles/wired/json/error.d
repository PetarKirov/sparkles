/**
The structured error type of the native JSON codec (SPEC §9, §11.6).

`JsonError` replaces `Exception` as the error payload of every wired
result: a plain value type carrying the failing stage, the value path,
the target type, and the reason — built only on the error path, with no
GC allocation (`SmallBuffer` storage). `toString(Writer)` renders the
SPEC §9 message contract; the message text is derived, the struct is the
contract.

Path syntax (SPEC §9): `$` for the root, `[0]` for array elements,
`.name` for identifier-safe object keys, `["key"]` (JSON-escaped) for
all other keys. The decode/encode walks build the path while unwinding —
each frame $(I prepends) its segment, so only failing branches pay.
*/
module sparkles.wired.json.error;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.errors : ParseError, ParseErrorCode;
import sparkles.wired.json.document : JsonKind;

/// Which processing stage failed (SPEC §11.6).
enum JsonStage : ubyte
{
    parse, /// text → document (`ParseErrorCode` detail + input position)
    decode, /// document → D value
    encode, /// D value → text
    fileRead, /// `readJSONFile` I/O
    fileWrite, /// `writeJSONFile` I/O
}

/**
A wired JSON failure. Copyable value type; construction never allocates
from the GC (path/summary/file storage is `SmallBuffer`-backed, filled
only on the error path).
*/
struct JsonError
{
    /// The failing stage; selects the `toString` rendering.
    JsonStage stage;

    /// Parse-stage detail (reused base vocabulary; `init` otherwise).
    ParseErrorCode code;

    /// Parse stage: byte offset, 1-based line, and 1-based column of the
    /// failure in the original input (line/column are derived eagerly at
    /// the boundary — the error must not borrow the input).
    size_t offset;
    /// ditto
    uint line, column;

    /// The value path from the root to the failing location (`$…`,
    /// SPEC §9). Empty means the root itself.
    SmallBuffer!(char, 48) path;

    /// The D type being decoded into / encoded from (a compile-time
    /// literal from the walk).
    string targetType;

    /// Why it failed (compile-time literal or static string).
    string reason;

    /// Decode stage: the JSON kind actually found (`none` when not
    /// applicable).
    JsonKind actualKind = JsonKind.none;

    /// Decode stage: compact summary of the offending value (token text
    /// or string prefix), when cheaply available.
    SmallBuffer!(char, 32) valueSummary;

    /// File stages: the path of the file involved.
    SmallBuffer!(char, 40) filePath;

    /// File stages: errno-style cause (0 = none).
    int cause;

    // ── path building (called by the walks while unwinding) ──────────────

    /// Prepends an array-index segment: `[7]`.
    void prependIndex(size_t index) @safe pure nothrow @nogc
    {
        char[24] seg = void;
        size_t n = seg.length;
        seg[--n] = ']';
        if (index == 0)
            seg[--n] = '0';
        else
            for (auto v = index; v != 0; v /= 10)
                seg[--n] = cast(char)('0' + v % 10);
        seg[--n] = '[';
        prependRaw(seg[n .. $]);
    }

    /// Prepends an object-key segment: `.name` when identifier-safe,
    /// `["key"]` (JSON-escaped) otherwise (SPEC §9).
    void prependKey(scope const(char)[] key) @safe pure nothrow @nogc
    {
        if (isIdentifierSafe(key))
        {
            SmallBuffer!(char, 48) seg;
            seg ~= '.';
            seg ~= key;
            prependRaw(seg[]);
            return;
        }
        SmallBuffer!(char, 48) seg;
        seg ~= `["`;
        foreach (c; key)
        {
            switch (c)
            {
            case '"':
                seg ~= `\"`;
                break;
            case '\\':
                seg ~= `\\`;
                break;
            default:
                if (c < 0x20)
                {
                    seg ~= `\u00`;
                    seg ~= "0123456789abcdef"[c >> 4];
                    seg ~= "0123456789abcdef"[c & 0xF];
                }
                else
                    seg ~= c;
            }
        }
        seg ~= `"]`;
        prependRaw(seg[]);
    }

    private void prependRaw(scope const(char)[] segment) @safe pure nothrow @nogc
    {
        // Error path only: rebuild rather than shift in place.
        SmallBuffer!(char, 48) next;
        next ~= segment;
        next ~= path[];
        path = next;
    }

    // ── rendering (SPEC §9 / §11.6) ───────────────────────────────────────

    /// Renders the human-readable message; the fragments (path syntax,
    /// target type, kind, reason) are the contract, exact wording is not.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;
        import sparkles.base.text.writers : writeInteger;

        final switch (stage)
        {
        case JsonStage.parse:
            put(w, "Cannot parse JSON at line ");
            writeInteger(w, line);
            put(w, " column ");
            writeInteger(w, column);
            put(w, " (byte ");
            writeInteger(w, offset);
            put(w, "): ");
            put(w, reason.length ? reason : parseCodeText(code));
            break;

        case JsonStage.decode:
            put(w, "Cannot decode ");
            put(w, targetType);
            put(w, " at $");
            put(w, path[]);
            if (actualKind != JsonKind.none)
            {
                put(w, " from JSON ");
                put(w, kindText(actualKind));
                if (valueSummary.length)
                {
                    put(w, ' ');
                    put(w, valueSummary[]);
                }
            }
            put(w, ": ");
            put(w, reason);
            break;

        case JsonStage.encode:
            put(w, "Cannot encode ");
            put(w, targetType);
            put(w, " at $");
            put(w, path[]);
            put(w, ": ");
            put(w, reason);
            break;

        case JsonStage.fileRead:
        case JsonStage.fileWrite:
            put(w, stage == JsonStage.fileRead
                    ? "Cannot read JSON file '" : "Cannot write JSON file '");
            put(w, filePath[]);
            put(w, "': ");
            put(w, reason);
            break;
        }
    }
}

/// Builds a parse-stage `JsonError` from the reader's `ParseError`,
/// deriving line/column from the original input (1-based; columns count
/// bytes — good enough for editors and the contract).
JsonError parseStageError(const ParseError e, scope const(char)[] text)
    @safe pure nothrow @nogc
{
    JsonError err;
    err.stage = JsonStage.parse;
    err.code = e.code;
    err.offset = e.offset;
    err.reason = e.context;
    err.line = 1;
    err.column = 1;
    const upTo = e.offset < text.length ? e.offset : text.length;
    foreach (c; text[0 .. upTo])
    {
        if (c == '\n')
        {
            err.line++;
            err.column = 1;
        }
        else
            err.column++;
    }
    return err;
}

/// Whether `key` may be rendered as a `.name` path segment
/// (`[A-Za-z_][A-Za-z0-9_]*`, SPEC §9).
private bool isIdentifierSafe(scope const(char)[] key) @safe pure nothrow @nogc
{
    if (key.length == 0)
        return false;
    foreach (i, c; key)
    {
        const alpha = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_';
        if (!alpha && (i == 0 || c < '0' || c > '9'))
            return false;
    }
    return true;
}

/// Human name of a JSON kind for messages.
package string kindText(JsonKind kind) @safe pure nothrow @nogc
{
    final switch (kind) with (JsonKind)
    {
    case none:
        return "nothing";
    case null_:
        return "null";
    case bool_:
        return "boolean";
    case integer, uinteger, floating, rawNumber:
        return "number";
    case string_:
        return "string";
    case array:
        return "array";
    case object:
        return "object";
    }
}

/// Fallback reason text for parse-stage codes without explicit context.
private string parseCodeText(ParseErrorCode code) @safe pure nothrow @nogc
{
    final switch (code) with (ParseErrorCode)
    {
    case emptyInput:
        return "empty input";
    case unexpectedCharacter:
        return "unexpected character";
    case unexpectedEnd:
        return "unexpected end of input";
    case leadingZero:
        return "numbers may not have leading zeros";
    case numericOverflow:
        return "number out of range";
    case invalidIdentifier:
        return "invalid identifier";
    case unknownValue:
        return "unknown value";
    case widthMismatch:
        return "width mismatch";
    case invalidEscape:
        return "invalid string escape";
    case invalidSurrogate:
        return "lone or mispaired UTF-16 surrogate escape";
    case invalidUtf8:
        return "ill-formed UTF-8";
    case depthExceeded:
        return "nesting too deep";
    case trailingContent:
        return "content after the top-level value";
    case outOfMemory:
        return "allocator failure";
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("error.path.segments")
@safe pure nothrow @nogc
unittest
{
    JsonError e;
    e.prependKey("port");
    e.prependKey("server");
    assert(e.path[] == ".server.port");

    JsonError f;
    f.prependIndex(0);
    f.prependKey("items");
    assert(f.path[] == ".items[0]");

    JsonError g;
    g.prependKey("server.port"); // resolved dotted key → bracket form
    assert(g.path[] == `["server.port"]`);

    JsonError h;
    h.prependKey(`quote"key`);
    assert(h.path[] == `["quote\"key"]`);

    JsonError i;
    i.prependIndex(42);
    i.prependIndex(7);
    assert(i.path[] == "[7][42]");

    JsonError j;
    j.prependKey("_ok2");
    assert(j.path[] == "._ok2");

    JsonError k;
    k.prependKey("2start"); // leading digit is not identifier-safe
    assert(k.path[] == `["2start"]`);
}

@("error.render.decodeContract")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    JsonError e;
    e.stage = JsonStage.decode;
    e.targetType = "ushort";
    e.actualKind = JsonKind.null_;
    e.reason = "null is not allowed for non-nullable fields";
    e.prependKey("port");
    e.prependKey("server");

    checkWriter!((ref b) => e.toString(b))(
        "Cannot decode ushort at $.server.port from JSON null: "
        ~ "null is not allowed for non-nullable fields");
}

@("error.render.decodeWithSummary")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    JsonError e;
    e.stage = JsonStage.decode;
    e.targetType = "Mode";
    e.actualKind = JsonKind.string_;
    e.valueSummary ~= `"sideways"`;
    e.reason = "expected one of: off, on, automatic";

    checkWriter!((ref b) => e.toString(b))(
        `Cannot decode Mode at $ from JSON string "sideways": `
        ~ "expected one of: off, on, automatic");
}

@("error.render.parseStage")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;
    import sparkles.base.text.errors : ParseError;

    const text = "{\n  \"a\": 01\n}";
    const pe = ParseError(ParseErrorCode.leadingZero, 9);
    auto e = parseStageError(pe, text);
    assert(e.line == 2 && e.column == 8);

    checkWriter!((ref b) => e.toString(b))(
        "Cannot parse JSON at line 2 column 8 (byte 9): "
        ~ "numbers may not have leading zeros");
}

@("error.render.encodeAndFileStages")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    JsonError e;
    e.stage = JsonStage.encode;
    e.targetType = "double";
    e.reason = "NaN is not representable in JSON";
    e.prependKey("ratio");
    checkWriter!((ref b) => e.toString(b))(
        "Cannot encode double at $.ratio: NaN is not representable in JSON");

    JsonError f;
    f.stage = JsonStage.fileRead;
    f.filePath ~= "/etc/app/config.json";
    f.reason = "No such file or directory";
    f.cause = 2;
    checkWriter!((ref b) => f.toString(b))(
        "Cannot read JSON file '/etc/app/config.json': No such file or directory");
}

@("error.value.copyable")
@safe pure nothrow @nogc
unittest
{
    // JsonError travels by value through Expected — copies must be
    // independent.
    JsonError a;
    a.stage = JsonStage.decode;
    a.prependKey("x");
    auto b = a;
    b.prependKey("y");
    assert(a.path[] == ".x");
    assert(b.path[] == ".y.x");
}
