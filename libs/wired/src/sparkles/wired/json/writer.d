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

When `w` is a $(LREF JsonSink) (and `opts.pretty` is off), a
specialized walk takes over: one capacity check covers each token, the
bytes after it are raw stores, and separators use the trailing-comma
discipline instead of per-token `put` calls.
*/
ref Writer writeJson(JsonWriteOptions opts = JsonWriteOptions.init, Writer)(
    JsonValue root, return ref Writer w)
{
    static if (is(Writer == JsonSink) && !opts.pretty)
    {
        sinkValue(root, w);
        w.unput(); // the walk's trailing comma
    }
    else
        writeJsonValue!opts(root, w, 0);
    return w;
}

// ─────────────────────────────────────────────────────────────────────────────
// JsonSink — the buffered serialization sink
// ─────────────────────────────────────────────────────────────────────────────

/**
A contiguous, grow-doubling text buffer for serialization. It is a
plain output range (`put`), so it works with every generic writer
utility — but $(LREF writeJson) recognizes the type and switches to a
reserve-then-raw-store walk that is several times faster than emitting
through per-token `put` calls.

The buffer is GC-allocated and reusable: `clear()` resets the length
and keeps the capacity, so a steady-state serialize loop allocates
nothing.
*/
struct JsonSink
{
    private char[] buf;
    private size_t len;

    /// The rendered text (valid until the next mutating call).
    const(char)[] opSlice() const @safe pure nothrow @nogc return scope
        => buf[0 .. len];

    /// Number of bytes written so far.
    size_t length() const @safe pure nothrow @nogc => len;

    /// Resets to empty, keeping the capacity.
    void clear() @safe pure nothrow @nogc
    {
        len = 0;
    }

    /// Output-range interface (the generic-writer path).
    void put(char c) @safe pure nothrow
    {
        ensure(1);
        () @trusted { buf.ptr[len] = c; }();
        len++;
    }

    /// ditto
    void put(scope const(char)[] s) @safe pure nothrow
    {
        ensure(s.length);
        () @trusted { buf.ptr[len .. len + s.length] = s[]; }();
        len += s.length;
    }

    // ── the reserve/raw-store emitters of the specialized walk ──────────

    /// Removes the last byte (the walk's trailing comma).
    private void unput() @safe pure nothrow @nogc
    in (len > 0)
    {
        len--;
    }

    /// Overwrites the last byte (container closers replace the last
    /// child's trailing comma).
    private void replaceLast(char c) @safe pure nothrow @nogc
    in (len > 0)
    {
        buf[len - 1] = c;
    }

    /// Appends a compile-time literal as one fixed-size store.
    private void putLit(string lit)()
    {
        ensure(lit.length);
        () @trusted { buf.ptr[len .. len + lit.length] = lit[]; }();
        len += lit.length;
    }

    /// Appends an integer plus a trailing separator in one reservation.
    private void putIntTail(char tail, T)(const T v)
    {
        import sparkles.base.text.writers : writeInteger;

        ensure(22); // sign + 20 digits + tail
        () @trusted {
            auto pw = PtrWriter(buf.ptr + len);
            writeInteger(pw, v);
            *pw.p = tail;
            len = pw.p + 1 - buf.ptr;
        }();
    }

    /// Appends a double (shortest round-trip; saturated ±infinity as
    /// `±1e999`) plus a trailing separator in one reservation.
    private void putDoubleTail(char tail)(double v)
    in (v == v, "NaN is not representable in JSON")
    {
        import sparkles.base.text.float_conv : formatShortestDouble;

        if (v == double.infinity)
            return putLit!("1e999" ~ tail);
        if (v == -double.infinity)
            return putLit!("-1e999" ~ tail);
        ensure(41); // formatShortestDouble max + tail
        () @trusted {
            const n = formatShortestDouble(buf.ptr[len .. len + 40], v);
            buf.ptr[len + n] = tail;
            len += n + 1;
        }();
    }

    /// Appends a JSON string token (same escape policy as
    /// $(LREF writeJsonString)) plus a trailing separator, under a
    /// single worst-case reservation.
    private void putStringTail(char tail)(scope const(char)[] s)
    {
        ensure(6 * s.length + 3); // every byte \u00XX + quotes + tail
        () @trusted {
            auto p = buf.ptr + len;
            *p++ = '"';
            size_t runStart = 0;
            foreach (i, c; s)
            {
                if (c != '"' && c != '\\' && c >= 0x20)
                    continue;
                p[0 .. i - runStart] = s[runStart .. i];
                p += i - runStart;
                runStart = i + 1;
                switch (c)
                {
                case '"':
                    p[0 .. 2] = `\"`;
                    p += 2;
                    break;
                case '\\':
                    p[0 .. 2] = `\\`;
                    p += 2;
                    break;
                case '\b':
                    p[0 .. 2] = `\b`;
                    p += 2;
                    break;
                case '\f':
                    p[0 .. 2] = `\f`;
                    p += 2;
                    break;
                case '\n':
                    p[0 .. 2] = `\n`;
                    p += 2;
                    break;
                case '\r':
                    p[0 .. 2] = `\r`;
                    p += 2;
                    break;
                case '\t':
                    p[0 .. 2] = `\t`;
                    p += 2;
                    break;
                default: // other control characters
                    p[0 .. 4] = `\u00`;
                    p[4] = "0123456789abcdef"[c >> 4];
                    p[5] = "0123456789abcdef"[c & 0xF];
                    p += 6;
                    break;
                }
            }
            p[0 .. s.length - runStart] = s[runStart .. $];
            p += s.length - runStart;
            *p++ = '"';
            *p++ = tail;
            len = p - buf.ptr;
        }();
    }

    private void ensure(size_t n) @safe pure nothrow
    {
        if (len + n > buf.length)
            grow(len + n);
    }

    private void grow(size_t need) @safe pure nothrow
    {
        size_t cap = buf.length ? buf.length * 2 : 1024;
        while (cap < need)
            cap *= 2;
        auto nb = new char[](cap);
        nb[0 .. len] = buf[0 .. len];
        buf = nb;
    }
}

/// Raw-pointer output range for one pre-reserved region (the integer
/// emitter's adapter — writeInteger's puts become plain stores).
private struct PtrWriter
{
    char* p;

    void put(char c) @system pure nothrow @nogc
    {
        *p++ = c;
    }

    void put(scope const(char)[] s) @system pure nothrow @nogc
    {
        p[0 .. s.length] = s[];
        p += s.length;
    }
}

// The JsonSink minify walk: every value appends itself plus a trailing
// comma under one reservation; containers overwrite their last child's
// comma with the closer. writeJson strips the root's trailing comma.
// Explicitly `@safe` (all unsafe stores live in the emitters' `@trusted`
// blocks) — a plain recursive function does not infer through its own
// self-call the way the generic template walk does.
private void sinkValue(scope JsonValue v, ref JsonSink w) @safe
{
    final switch (v.kind) with (JsonKind)
    {
    case null_:
        w.putLit!"null,";
        break;
    case bool_:
        if (v.boolean)
            w.putLit!"true,";
        else
            w.putLit!"false,";
        break;
    case integer:
        w.putIntTail!','(v.integer);
        break;
    case uinteger:
        w.putIntTail!','(v.uinteger);
        break;
    case floating:
        w.putDoubleTail!','(v.floating);
        break;
    case string_:
        w.putStringTail!','(v.str);
        break;
    case rawNumber:
        w.put(v.raw); // verbatim token: already valid JSON
        w.putLit!",";
        break;
    case array:
        if (v.length == 0)
        {
            w.putLit!"[],";
            break;
        }
        w.putLit!"[";
        foreach (e; v.byElement)
            sinkValue(e, w);
        w.replaceLast(']');
        w.putLit!",";
        break;
    case object:
        if (v.length == 0)
        {
            w.putLit!"{},";
            break;
        }
        w.putLit!"{";
        foreach (m; v.byKeyValue)
        {
            w.putStringTail!':'(m.key);
            sinkValue(m.value, w);
        }
        w.replaceLast('}');
        w.putLit!",";
        break;
    case none:
        assert(false, "cannot serialize an invalid view");
    }
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

package void newlineIndent(Writer)(ref Writer w, uint depth)
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

@("writer.sink.matchesGenericPath")
@system unittest
{
    import std.array : appender;
    import sparkles.wired.json.reader : parseJsonDocument;

    // The specialized JsonSink walk must produce byte-identical output
    // to the generic output-range walk, whatever the document shape.
    static immutable string[] docs = [
        `{"a":1,"b":[true,null],"c":{"d":"x"},"e":[],"f":{}}`,
        `[-1,18446744073709551615,0.1,2.5e300,"esc\n\t\"\\",""]`,
        `"lone string"`, `42`, `null`, `[[[[1]]]]`,
        "\"controls \\u0001\\u001f and unicode € \U0001F30D\"",
    ];
    foreach (doc; docs)
    {
        auto r = parseJsonDocument(doc);
        assert(r.hasValue);
        auto generic = appender!string;
        writeJson(r.document.root, generic);
        JsonSink sink;
        writeJson(r.document.root, sink);
        assert(sink[] == generic[], doc);
    }
}

@("writer.sink.growthAndReuse")
@safe unittest
{
    import sparkles.wired.json.reader : parseJsonDocument;

    // Force several grow() rounds past the initial capacity, then
    // check clear() reuses the buffer without disturbing content.
    JsonSink sink;
    char[] text;
    text ~= '[';
    foreach (k; 0 .. 800)
        text ~= `"the quick brown fox jumps over the lazy dog",`;
    text ~= `"tail"]`;
    auto r = parseJsonDocument(text);
    assert(r.hasValue);
    writeJson(r.document.root, sink);
    assert(sink.length == text.length);
    assert(sink[] == text);

    const capBefore = sink[].length;
    sink.clear();
    assert(sink.length == 0);
    writeJson(r.document.root, sink);
    assert(sink[] == text);
    assert(sink[].length == capBefore);
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
