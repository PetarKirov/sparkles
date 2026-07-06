/**
The streaming JSON writer (SPEC §11.4).

Three layers, no intermediate document on encode: token-emission
primitives over any output range (string escaping, shortest-round-trip
doubles, branchlut integers); $(LREF writeJson) — document/view →
text; and (next milestone) the codec's streaming encode from D values.

Escape policy: the two-character escapes plus `\u00XX` for other control
characters; `/` is never escaped. Pretty mode is 2-space indent, `": "`
separator, LF newlines. Doubles render shortest-round-trip; a document's
saturated `±infinity` (JSON cannot spell it) renders as `±1e999`, which
re-parses to the same value under any saturating RFC 8259 reader.
*/
module sparkles.wired.json.writer;

import std.range.primitives : put;

import sparkles.wired.json.document : JsonKind, JsonValue;

/// Compile-time writer configuration (SPEC §11.4).
struct JsonWriteOptions
{
    bool pretty = false; /// 2-space indent, `": "` separator, LF newlines
}

/**
Serializes one parsed value (usually a document root) to `w`.
The walk recurses per nesting level; documents produced by the reader
are depth-bounded by `JsonReadOptions.maxDepth`.
*/
ref Writer writeJson(JsonWriteOptions opts = JsonWriteOptions.init, Writer)(
    JsonValue root, return ref Writer w)
{
    writeJsonValue!opts(root, w, 0);
    return w;
}

private void writeJsonValue(JsonWriteOptions opts, Writer)(
    scope JsonValue v, ref Writer w, uint depth)
{
    final switch (v.kind) with (JsonKind)
    {
    case null_:
        put(w, "null");
        break;
    case bool_:
        put(w, v.boolean ? "true" : "false");
        break;
    case integer:
        writeJsonLong(w, v.integer);
        break;
    case uinteger:
        writeJsonUlong(w, v.uinteger);
        break;
    case floating:
        writeJsonDouble(w, v.floating);
        break;
    case string_:
        writeJsonString(w, v.str);
        break;
    case rawNumber:
        put(w, v.raw); // verbatim token: already valid JSON
        break;
    case array:
        {
            if (v.length == 0)
            {
                put(w, "[]");
                break;
            }
            put(w, '[');
            bool first = true;
            foreach (e; v.byElement)
            {
                if (!first)
                    put(w, ',');
                first = false;
                static if (opts.pretty)
                    newlineIndent(w, depth + 1);
                writeJsonValue!opts(e, w, depth + 1);
            }
            static if (opts.pretty)
                newlineIndent(w, depth);
            put(w, ']');
            break;
        }
    case object:
        {
            if (v.length == 0)
            {
                put(w, "{}");
                break;
            }
            put(w, '{');
            bool first = true;
            foreach (m; v.byKeyValue)
            {
                if (!first)
                    put(w, ',');
                first = false;
                static if (opts.pretty)
                    newlineIndent(w, depth + 1);
                writeJsonString(w, m.key);
                static if (opts.pretty)
                    put(w, ": ");
                else
                    put(w, ':');
                writeJsonValue!opts(m.value, w, depth + 1);
            }
            static if (opts.pretty)
                newlineIndent(w, depth);
            put(w, '}');
            break;
        }
    case none:
        assert(false, "cannot serialize an invalid view");
    }
}

private void newlineIndent(Writer)(ref Writer w, uint depth)
{
    put(w, '\n');
    foreach (_; 0 .. depth)
        put(w, "  ");
}

// ─────────────────────────────────────────────────────────────────────────────
// Token primitives
// ─────────────────────────────────────────────────────────────────────────────

/**
Writes `s` as a JSON string token: quoted, with `"` `\` and control
characters escaped (`\b \f \n \r \t`, `\u00XX` otherwise); `/` and all
valid UTF-8 pass through verbatim. Clean runs between escapes are
emitted as single slices.
*/
void writeJsonString(Writer)(ref Writer w, scope const(char)[] s)
{
    put(w, '"');
    size_t runStart = 0;
    foreach (i, c; s)
    {
        if (c != '"' && c != '\\' && c >= 0x20)
            continue;
        if (i > runStart)
            put(w, s[runStart .. i]);
        runStart = i + 1;
        switch (c)
        {
        case '"':
            put(w, `\"`);
            break;
        case '\\':
            put(w, `\\`);
            break;
        case '\b':
            put(w, `\b`);
            break;
        case '\f':
            put(w, `\f`);
            break;
        case '\n':
            put(w, `\n`);
            break;
        case '\r':
            put(w, `\r`);
            break;
        case '\t':
            put(w, `\t`);
            break;
        default: // other control characters
            {
                char[6] esc = ['\\', 'u', '0', '0', '?', '?'];
                esc[4] = "0123456789abcdef"[c >> 4];
                esc[5] = "0123456789abcdef"[c & 0xF];
                put(w, esc[]);
            }
            break;
        }
    }
    if (s.length > runStart)
        put(w, s[runStart .. $]);
    put(w, '"');
}

/// Writes a signed integer with the branchlut digit writer.
void writeJsonLong(Writer)(ref Writer w, long value)
{
    import sparkles.base.text.writers : writeInteger;

    writeInteger(w, value);
}

/// ditto, unsigned
void writeJsonUlong(Writer)(ref Writer w, ulong value)
{
    import sparkles.base.text.writers : writeInteger;

    writeInteger(w, value);
}

/**
Writes a finite double as its shortest round-trip representation;
`±infinity` (a saturated parse — JSON cannot spell it) as `±1e999`,
which re-parses to the identical saturated value. NaN cannot occur in a
parsed document and is rejected by contract.
*/
void writeJsonDouble(Writer)(ref Writer w, double value)
in (value == value, "NaN is not representable in JSON")
{
    import sparkles.base.text.float_conv : formatShortestDouble;

    if (value == double.infinity)
    {
        put(w, "1e999");
        return;
    }
    if (value == -double.infinity)
    {
        put(w, "-1e999");
        return;
    }
    char[40] buf = void;
    const len = formatShortestDouble(buf[], value);
    // formatShortestDouble keeps integral values unambiguously floating
    // with a ".0" tail — exactly what JSON round-tripping wants too.
    put(w, buf[0 .. len]);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.wired.json.reader : parseJsonDocument;

    /// parse → minify; asserts the parse succeeded.
    private void minifyInto(Buf)(scope const(char)[] text, ref Buf buf)
        @safe pure nothrow @nogc
    {
        auto r = parseJsonDocument(text);
        assert(r.hasValue);
        writeJson(r.document.root, buf);
    }
}

@("writer.minify.tokens")
@safe pure nothrow @nogc
unittest
{
    static void check(string text, string expected)
    {
        import sparkles.base.smallbuffer : checkWriter;

        checkWriter!((ref b) => minifyInto(text, b))(expected);
    }

    check(`  true `, "true");
    check(`false`, "false");
    check(`null`, "null");
    check(`42`, "42");
    check(`-7`, "-7");
    check(`18446744073709551615`, "18446744073709551615");
    check(`2.5`, "2.5");
    check(`-0`, "-0.0");
    check(`1e999`, "1e999"); // saturated ±inf round-trips as 1e999
    check(`-1e999`, "-1e999");
    check(`0.1`, "0.1");
    check(`"hello"`, `"hello"`);
    check(`"a\nb\t\"c\"\\d"`, `"a\nb\t\"c\"\\d"`);
    check(`"a\/b"`, `"a/b"`); // '/' never escaped
    check("\"\\u0001\"", "\"\\u0001\""); // control chars re-escape as \u00XX
    check(`"€ € ユニコード 🌍"`, `"€ € ユニコード 🌍"`);
    check(`[]`, "[]");
    check(`{}`, "{}");
    check(`[1, 2, 3]`, "[1,2,3]");
    check(`{"a": 1, "b": [true, null], "c": {"d": "x"}}`,
        `{"a":1,"b":[true,null],"c":{"d":"x"}}`);
}

@("writer.pretty.layout")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    static void checkPretty(string text, string expected)
    {
        checkWriter!((ref b) {
            auto r = parseJsonDocument(text);
            assert(r.hasValue);
            enum opts = JsonWriteOptions(pretty: true);
            writeJson!opts(r.document.root, b);
        })(expected);
    }

    checkPretty(`{"a":1,"b":[true,null]}`,
        "{\n  \"a\": 1,\n  \"b\": [\n    true,\n    null\n  ]\n}");
    checkPretty(`[]`, "[]");
    checkPretty(`{}`, "{}");
    checkPretty(`[1]`, "[\n  1\n]");
}

@("writer.rawNumbers.passThrough")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;
    import sparkles.wired.json.reader : JsonReadOptions;

    checkWriter!((ref b) {
        enum opts = JsonReadOptions(rawNumbers: true);
        auto r = parseJsonDocument!opts(`[0.30000000000000004, 1e999, -0]`);
        assert(r.hasValue);
        writeJson(r.document.root, b);
    })(`[0.30000000000000004,1e999,-0]`);
}

@("writer.roundTrip.fingerprintInvariant")
@system unittest
{
    import std.array : appender;
    import sparkles.wired.json.reader : parseJsonDocument;

    // parse → minify → parse and parse → pretty → parse must preserve
    // both validity and every value (numbers bit-exactly: floats render
    // shortest-round-trip).
    static immutable string[] docs = [
        `{"π": 3.141592653589793, "ids": [9223372036854775807, -1],
        "escaped": "line\nbreak \"quoted\" back\\slash",
        "unicode": "héllo — ユニコード 🌍",
        "nested": {"deep": [[1.5e-9, 2.5e300, 5e-324], {}]},
        "flags": [true, false, null]}`,
        `[0.1, 0.2, 0.30000000000000004]`,
        `{"empty": [], "eobj": {}}`,
    ];

    foreach (doc; docs)
    {
        auto first = parseJsonDocument(doc);
        assert(first.hasValue);

        auto minified = appender!string;
        writeJson(first.document.root, minified);
        auto second = parseJsonDocument(minified[]);
        assert(second.hasValue, minified[]);

        auto again = appender!string;
        writeJson(second.document.root, again);
        assert(minified[] == again[]); // minified form is a fixed point

        enum opts = JsonWriteOptions(pretty: true);
        auto pretty = appender!string;
        writeJson!opts(second.document.root, pretty);
        auto third = parseJsonDocument(pretty[]);
        assert(third.hasValue, pretty[]);

        auto fromPretty = appender!string;
        writeJson(third.document.root, fromPretty);
        assert(minified[] == fromPretty[]);
    }
}
