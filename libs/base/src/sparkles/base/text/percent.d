/**
RFC 3986 percent-encoding ("URL encoding") and its
`application/x-www-form-urlencoded` variant.

Percent-encoding is an $(I escape) encoding, not a bit-regrouping codec:
bytes that are safe in the target context pass through unchanged and every
other byte becomes `%XX`. Which bytes are safe is the only thing that
varies between contexts (path segment, query, form field, …), so it is the
one thing this module parameterizes — a $(LREF PercentSet) bound as a
template value parameter, exactly as
$(REF Alphabet, sparkles,base,text,base_codecs) is for the RFC 4648 family.

The hex digits themselves come from that family: encoding emits the
upper-case `base16` digits (RFC 3986 §2.1 recommends upper case) and
decoding accepts either case through `base16`'s case-insensitive reverse
table.

Input is bytes. To percent-encode text, encode the text as UTF-8 first —
which is what the `const(char)[]` overload does implicitly, since D strings
are already UTF-8.
*/
module sparkles.base.text.percent;

import sparkles.base.text.base_codecs : base16, makeDecodeTable;
import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

// Unconditional import (phobos-style, cf. std.internal.attributes): unittest
// UDAs are resolved even in builds where the unittest bodies are not compiled.
import sparkles.test_runner.attributes : benchmark, betterC;

/**
Which bytes survive percent-encoding unescaped.

ASCII letters and digits are always safe (every real-world encode set
keeps them); `extraUnreserved` names the additional punctuation the target
context allows. Every other byte — including all non-ASCII — is written as
`%XX`.
*/
struct PercentSet
{
    /// Punctuation left unescaped, beyond ASCII alphanumerics. Defaults to
    /// RFC 3986 §2.3's unreserved set.
    string extraUnreserved = "-._~";
    /// `application/x-www-form-urlencoded`: encode `' '` as `'+'`, and
    /// decode `'+'` back to `' '`. (A literal `'+'` must then be escaped,
    /// so it may not appear in `extraUnreserved`.)
    bool spaceAsPlus = false;

    /// `true` iff the set is self-consistent: a `spaceAsPlus` set must
    /// escape both `' '` and `'+'`, or `'+'` would be ambiguous on decode.
    /// Checked by a `static assert` where the set is bound as a template
    /// parameter, mirroring
    /// $(REF Alphabet.isConsistent, sparkles,base,text,base_codecs).
    bool isConsistent() const @safe pure nothrow @nogc
    {
        if (!spaceAsPlus)
            return true;
        foreach (char c; extraUnreserved)
            if (c == '+' || c == ' ')
                return false;
        return true;
    }
}

/// RFC 3986 §2.3 unreserved only — escapes every reserved character, so the
/// result is safe as a whole URI $(I component) (a path segment, one query
/// value, …). The conservative default.
enum PercentSet percentComponent = PercentSet();

/// A path segment: unreserved + sub-delims + `":"` `"@"` (RFC 3986 `pchar`).
/// `'/'` is escaped, so an encoded segment cannot introduce a new one.
enum PercentSet percentPathSegment = PercentSet(extraUnreserved: "-._~!$&'()*+,;=:@");

/// A query string: `pchar` plus `'/'` and `'?'` (RFC 3986 §3.4). Encodes a
/// whole query, so `'&'` and `'='` pass through — use $(LREF percentComponent)
/// for an individual key or value.
enum PercentSet percentQuery = PercentSet(extraUnreserved: "-._~!$&'()*+,;=:@/?");

/// `application/x-www-form-urlencoded` (WHATWG URL §5.2): only `*-._` and
/// alphanumerics survive, and space becomes `'+'`.
enum PercentSet percentFormUrlencoded = PercentSet(extraUnreserved: "*-._", spaceAsPlus: true);

/**
Builds the 256-entry "safe byte" table for `s`: `true` where the byte is
written literally, `false` where it becomes `%XX`. ASCII alphanumerics are
always safe; `s.extraUnreserved` adds to them. Evaluated at compile time by
the encoder.
*/
// NB: `const PercentSet` by value, not `in` — with `-preview=in` the by-ref
// passing of an enum struct argument segfaults the CTFE interpreter
// (LDC 1.41 / DMD 2.111 front end), as for `makeDecodeTable`.
bool[256] makeSafeTable(const PercentSet s) @safe pure nothrow @nogc
{
    bool[256] t = false;
    foreach (i; 0 .. 256)
    {
        immutable char c = cast(char) i;
        t[i] = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
            || (c >= '0' && c <= '9');
    }
    foreach (char c; s.extraUnreserved)
        t[cast(ubyte) c] = true;
    return t;
}

/// One CTFE safe-table per set, shared by every template that needs it —
/// instantiating `makeSafeTable` inside each would emit a separate 256-byte
/// copy per template per set.
private template safeTable(PercentSet s)
{
    static immutable bool[256] safeTable = makeSafeTable(s);
}

/// The hex reverse table is set-independent, so it lives here rather than
/// inside `decodePercent` (which would emit one copy per set).
private static immutable byte[256] hexTable = makeDecodeTable(base16);

/**
Percent-encodes bytes under the set `s`: safe bytes pass through, every
other byte becomes `%` and two upper-case hex digits (RFC 3986 §2.1).
Under a `spaceAsPlus` set, `' '` becomes `'+'` instead.

Use the named aliases ($(LREF encodePercentComponent),
$(LREF encodeFormUrlencoded), …) for the common contexts. The
eponymous-template shape is what lets a partial instantiation be aliased
while keeping the byte and text overloads in one overload set.
*/
template encodePercent(PercentSet s)
{
    static assert(s.isConsistent,
        "a spaceAsPlus PercentSet must not list ' ' or '+' as unreserved");

    private alias safe = safeTable!s;

    /// Encode `data` into the output range `w`.
    void encodePercent(Writer)(ref Writer w, scope const(ubyte)[] data)
    {
        import std.range.primitives : put;

        enum string hex = base16.digits; // upper-case, per RFC 3986 §2.1
        foreach (ubyte b; data)
        {
            if (safe[b])
                put(w, cast(char) b);
            else
            {
                static if (s.spaceAsPlus)
                    if (b == ' ')
                    {
                        put(w, '+');
                        continue;
                    }
                put(w, '%');
                put(w, hex[b >> 4]);
                put(w, hex[b & 0xF]);
            }
        }
    }

    /// ditto — text overload; D strings are already UTF-8, so this is the
    /// "encode the text as UTF-8, then percent-encode" path.
    void encodePercent(Writer)(ref Writer w, scope const(char)[] text)
    {
        encodePercent(w, cast(const(ubyte)[]) text);
    }
}

/// The exact number of characters $(LREF encodePercent) will write for
/// `data` — for pre-sizing an output buffer.
template percentEncodedLength(PercentSet s)
{
    private alias safe = safeTable!s;

    // Named separately: inside an eponymous template, a non-template member
    // cannot call its own overload set by name (the name resolves to the
    // enclosing template symbol).
    private size_t lengthOf(scope const(ubyte)[] data) @safe pure nothrow @nogc
    {
        size_t n = 0;
        foreach (ubyte b; data)
        {
            static if (s.spaceAsPlus)
                if (b == ' ')
                {
                    n++;
                    continue;
                }
            n += safe[b] ? 1 : 3;
        }
        return n;
    }

    /// ditto
    size_t percentEncodedLength(scope const(ubyte)[] data) @safe pure nothrow @nogc
        => lengthOf(data);

    /// ditto
    size_t percentEncodedLength(scope const(char)[] text) @safe pure nothrow @nogc
        => lengthOf(cast(const(ubyte)[]) text);
}

/**
Decodes percent-encoded text under the set `s`, writing bytes to the
`ubyte` output range `w` and returning the number written (never more than
`text.length`, so that is a safe output-buffer size).

Malformed escapes are rejected:

$(UL
    $(LI a `%` with fewer than two characters after it — `unexpectedEnd`,
        offset of the `%`;)
    $(LI a non-hex character in either position — `unexpectedCharacter`,
        offset of that character.)
)

Hex digits are accepted in either case (RFC 3986 §6.2.2.1).

Literal characters are $(I not) validated against `s` — a byte that should
have been escaped decodes as itself, which is what every interoperable
decoder does (and is why decoding is far less context-sensitive than
encoding). `s` therefore only affects `'+'`: under a `spaceAsPlus` set it
decodes to `' '`, otherwise it is literal.

As with the RFC 4648 decoders, the payload is taken by value rather than as
an advancing cursor, and on failure `w` may already hold a partial prefix.
*/
template decodePercent(PercentSet s = percentComponent)
{
    /// Decode `text` into the `ubyte` output range `w`.
    ParseExpected!size_t decodePercent(Writer)(ref Writer w, scope const(char)[] text)
    {
        import std.range.primitives : put;

        size_t written = 0;
        size_t i = 0;
        while (i < text.length)
        {
            immutable char c = text[i];
            if (c == '%')
            {
                if (i + 2 >= text.length)
                    return parseErr!size_t(ParseErrorCode.unexpectedEnd, i);
                immutable hi = hexTable[text[i + 1]];
                if (hi < 0)
                    return parseErr!size_t(ParseErrorCode.unexpectedCharacter, i + 1);
                immutable lo = hexTable[text[i + 2]];
                if (lo < 0)
                    return parseErr!size_t(ParseErrorCode.unexpectedCharacter, i + 2);
                put(w, cast(ubyte)((hi << 4) | lo));
                i += 3;
            }
            else
            {
                ubyte b = cast(ubyte) c;
                static if (s.spaceAsPlus)
                    if (c == '+')
                        b = ' ';
                put(w, b);
                i++;
            }
            written++;
        }
        return parseOk(written);
    }
}

/// RFC 3986 unreserved-only encoding — safe for any single URI component.
alias encodePercentComponent = encodePercent!percentComponent;
/// ditto
alias decodePercentComponent = decodePercent!percentComponent;
/// A URI path segment (`pchar`; `'/'` is escaped).
alias encodePercentPathSegment = encodePercent!percentPathSegment;
/// ditto
alias decodePercentPathSegment = decodePercent!percentPathSegment;
/// A whole query string (`'&'`, `'='`, `'/'`, `'?'` pass through).
alias encodePercentQuery = encodePercent!percentQuery;
/// ditto
alias decodePercentQuery = decodePercent!percentQuery;
/// `application/x-www-form-urlencoded` (space ⇄ `'+'`).
alias encodeFormUrlencoded = encodePercent!percentFormUrlencoded;
/// ditto
alias decodeFormUrlencoded = decodePercent!percentFormUrlencoded;

@("text.percent.makeSafeTable")
@betterC
unittest
{
    static immutable comp = makeSafeTable(percentComponent);
    assert(comp['A'] && comp['z'] && comp['0'] && comp['9']);
    assert(comp['-'] && comp['.'] && comp['_'] && comp['~']);
    assert(!comp[' '] && !comp['/'] && !comp['%'] && !comp['+'] && !comp[0xC3]);

    static immutable query = makeSafeTable(percentQuery);
    assert(query['/'] && query['?'] && query['&'] && query['=']);
    assert(!query[' '] && !query['%'] && !query['#']);

    static immutable seg = makeSafeTable(percentPathSegment);
    assert(seg[':'] && seg['@'] && seg['$']);
    assert(!seg['/'] && !seg['?']);

    // A form set escapes '+' (it is the space stand-in) but keeps '*'.
    static immutable form = makeSafeTable(percentFormUrlencoded);
    assert(form['*'] && form['-'] && form['.'] && form['_']);
    assert(!form['+'] && !form[' '] && !form['~']);

    static assert(percentComponent.isConsistent);
    static assert(percentPathSegment.isConsistent);
    static assert(percentQuery.isConsistent);
    static assert(percentFormUrlencoded.isConsistent);
    // A spaceAsPlus set that leaves '+' or ' ' unescaped would be ambiguous.
    static assert(!PercentSet(extraUnreserved: "+", spaceAsPlus: true).isConsistent);
    static assert(!PercentSet(extraUnreserved: " ", spaceAsPlus: true).isConsistent);
    // Without spaceAsPlus, a literal '+' is fine (percentQuery relies on it).
    static assert(PercentSet(extraUnreserved: "+").isConsistent);
}

@("text.percent.encode.rfc3986")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref b) => encodePercentComponent(b, ""))("");
    checkWriter!((ref b) => encodePercentComponent(b, "Man"))("Man");
    checkWriter!((ref b) => encodePercentComponent(b, "a-b_c.d~e"))("a-b_c.d~e");
    checkWriter!((ref b) => encodePercentComponent(b, "a b"))("a%20b");
    checkWriter!((ref b) => encodePercentComponent(b, "a+b"))("a%2Bb");
    checkWriter!((ref b) => encodePercentComponent(b, "100%"))("100%25");
    checkWriter!((ref b) => encodePercentComponent(b, "a/b?c&d=e"))("a%2Fb%3Fc%26d%3De");

    // Non-ASCII is encoded as its UTF-8 bytes, upper-case hex (§2.1).
    checkWriter!((ref b) => encodePercentComponent(b, "café"))("caf%C3%A9");
    checkWriter!((ref b) => encodePercentComponent(b, "√"))("%E2%88%9A");

    // Control bytes and DEL.
    checkWriter!((ref b) => encodePercentComponent(b, "a\nb\x7f"))("a%0Ab%7F");
}

@("text.percent.encode.contextSets")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    // The same input under four sets — the only thing that varies is which
    // bytes are safe.
    enum input = "a/b?c&d=e:f@g h+i*j";

    checkWriter!((ref b) => encodePercentComponent(b, input))(
        "a%2Fb%3Fc%26d%3De%3Af%40g%20h%2Bi%2Aj");
    checkWriter!((ref b) => encodePercentPathSegment(b, input))(
        "a%2Fb%3Fc&d=e:f@g%20h+i*j");
    checkWriter!((ref b) => encodePercentQuery(b, input))(
        "a/b?c&d=e:f@g%20h+i*j");
    checkWriter!((ref b) => encodeFormUrlencoded(b, input))(
        "a%2Fb%3Fc%26d%3De%3Af%40g+h%2Bi*j");
}

@("text.percent.encode.matchesBase16Oracle")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.base_codecs : encodeBase16;

    // An escaped byte is definitionally '%' followed by its base16 encoding —
    // anchor the escape path to the RFC 4648 kernel it shares hex digits with.
    static immutable safe = makeSafeTable(percentComponent);
    foreach (i; 0 .. 256)
    {
        const ubyte[1] src = [cast(ubyte) i];
        if (safe[i])
            continue;

        SmallBuffer!(char, 8) viaPercent;
        encodePercentComponent(viaPercent, src[]);

        SmallBuffer!(char, 8) expected;
        expected ~= '%';
        char[2] hex = void;
        encodeBase16(src, hex);
        expected ~= hex[];

        assert(viaPercent[] == expected[]);
    }
}

@("text.percent.decode.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    static void checkDecode(alias dec)(
        scope const(char)[] text, scope const(char)[] expected)
    {
        SmallBuffer!(ubyte, 64) buf;
        auto r = dec(buf, text);
        assert(r.hasValue);
        assert(r.value == expected.length);
        assert(buf[] == cast(const(ubyte)[]) expected);
    }

    checkDecode!decodePercentComponent("", "");
    checkDecode!decodePercentComponent("Man", "Man");
    checkDecode!decodePercentComponent("a%20b", "a b");
    checkDecode!decodePercentComponent("caf%C3%A9", "café");
    checkDecode!decodePercentComponent("100%25", "100%");

    // Hex digits decode case-insensitively (RFC 3986 §6.2.2.1).
    checkDecode!decodePercentComponent("%e2%88%9a", "√");
    checkDecode!decodePercentComponent("%E2%88%9A", "√");

    // '+' is literal outside a form set, a space inside one.
    checkDecode!decodePercentComponent("a+b", "a+b");
    checkDecode!decodeFormUrlencoded("a+b", "a b");
    checkDecode!decodeFormUrlencoded("a%2Bb", "a+b");

    // Literal characters that an encoder would have escaped still decode as
    // themselves — decoding is deliberately lenient about them.
    checkDecode!decodePercentComponent("a/b?c", "a/b?c");
}

@("text.percent.decode.rejectsTruncatedEscape")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 16) buf;
    auto r = decodePercentComponent(buf, "%");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedEnd);
    assert(r.error.offset == 0); // the '%' that starts the bad escape

    buf.clear();
    auto s = decodePercentComponent(buf, "ab%4");
    assert(!s.hasValue);
    assert(s.error.code == ParseErrorCode.unexpectedEnd);
    assert(s.error.offset == 2);
}

@("text.percent.decode.rejectsNonHexDigit")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(ubyte, 16) buf;
    auto r = decodePercentComponent(buf, "%ZZ");
    assert(!r.hasValue);
    assert(r.error.code == ParseErrorCode.unexpectedCharacter);
    assert(r.error.offset == 1);

    buf.clear();
    auto s = decodePercentComponent(buf, "%4Z");
    assert(!s.hasValue);
    assert(s.error.code == ParseErrorCode.unexpectedCharacter);
    assert(s.error.offset == 2);

    // A nested '%' is not a hex digit either.
    buf.clear();
    auto t = decodePercentComponent(buf, "%%20");
    assert(!t.hasValue);
    assert(t.error.code == ParseErrorCode.unexpectedCharacter);
    assert(t.error.offset == 1);
}

@("text.percent.roundTrip")
@safe pure nothrow @nogc
unittest
{
    import std.meta : AliasSeq;
    import sparkles.base.smallbuffer : SmallBuffer;

    static void roundTrip(PercentSet s)()
    {
        // Every byte value, in one payload and individually.
        ubyte[256] all = void;
        foreach (i, ref b; all)
            b = cast(ubyte) i;

        SmallBuffer!(char, 1024) enc;
        encodePercent!s(enc, all[]);
        assert(enc[].length == percentEncodedLength!s(all[]));

        SmallBuffer!(ubyte, 512) dec;
        auto r = decodePercent!s(dec, enc[]);
        assert(r.hasValue);
        assert(r.value == all.length);
        assert(dec[] == all[]);

        // Random lengths, deterministic inline LCG (std.random is not @nogc).
        uint x = 0x9E3779B9;
        ubyte[64] data = void;
        foreach (n; 0 .. data.length + 1)
        {
            foreach (j; 0 .. n)
            {
                x = x * 1664525 + 1013904223;
                data[j] = cast(ubyte)(x >> 24);
            }

            enc.clear();
            encodePercent!s(enc, data[0 .. n]);
            dec.clear();
            auto rr = decodePercent!s(dec, enc[]);
            assert(rr.hasValue);
            assert(rr.value == n);
            assert(dec[] == data[0 .. n]);
        }
    }

    static foreach (s; AliasSeq!(percentComponent, percentPathSegment,
            percentQuery, percentFormUrlencoded))
        roundTrip!s();
}

@("text.percent.encodedLength")
@safe pure nothrow @nogc
unittest
{
    assert(percentEncodedLength!percentComponent("") == 0);
    assert(percentEncodedLength!percentComponent("Man") == 3);
    assert(percentEncodedLength!percentComponent("a b") == 5);   // 1 + 3 + 1
    assert(percentEncodedLength!percentComponent("café") == 9);  // 3 + 3 + 3
    assert(percentEncodedLength!percentFormUrlencoded("a b") == 3); // space → '+'
}

@("text.percent.anonymousSet")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    // An anonymous PercentSet binds like a preset — nothing is hardcoded.
    enum PercentSet strict = PercentSet(extraUnreserved: "");
    checkWriter!((ref b) => encodePercent!strict(b, "a-b"))("a%2Db");
}

// ─────────────────────────────────────────────────────────────────────────────
// Benchmarks (`dub test :base -b bench -- --bench --group-by=set,op,data`)
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private struct PercentCharSink
    {
        char[] buf;
        size_t n;
        void put(char c) @safe { buf[n++] = c; }
    }

    private struct PercentByteSink
    {
        ubyte[] buf;
        size_t n;
        void put(ubyte b) @safe { buf[n++] = b; }
    }

    /// Per-cell bench state on the GC heap, with member-delegate callbacks —
    /// `base` source-includes the runner impl, so a frame closure passed to
    /// `benchCase` would be stack-allocated under this package's dip1000 and
    /// dangle by the time the deferred measurement runs.
    private final class PercentBenchCase(PercentSet s)
    {
        ubyte[] data;
        char[] encoded;
        ubyte[] decoded;

        this(size_t size, bool mostlySafe) @safe
        {
            data = new ubyte[](size);
            uint x = 0x9E3779B9 ^ cast(uint) size;
            foreach (ref b; data)
            {
                x = x * 1664525 + 1013904223;
                // "text" is mostly unreserved ASCII (a few escapes); "binary"
                // is uniform bytes, so ~3/4 of it escapes.
                b = mostlySafe
                    ? cast(ubyte)('a' + (x >> 24) % 30) : cast(ubyte)(x >> 24);
            }
            encoded = new char[](percentEncodedLength!s(data));
            decoded = new ubyte[](size);
            auto w = PercentCharSink(encoded);
            encodePercent!s(w, data); // seed `encoded` for the decode case
        }

        size_t timedEncode() @safe
        {
            auto w = PercentCharSink(encoded);
            encodePercent!s(w, data);
            return w.n;
        }

        void afterEncode(ref size_t n) @safe
        {
            if (n != encoded.length)
                throw new Exception("encoded length mismatch");
        }

        size_t timedDecode() @safe
        {
            auto w = PercentByteSink(decoded);
            auto r = decodePercent!s(w, encoded);
            return r.hasError ? size_t.max : r.value;
        }

        void afterDecode(ref size_t n) @safe
        {
            if (n != decoded.length)
                throw new Exception("decode mismatch");
        }
    }

    private void registerPercentBench(PercentSet s)(
        string setName, string dataName, bool mostlySafe, size_t size) @safe
    {
        import sparkles.test_runner.bench : benchCase, Metric, Unit;

        auto c = new PercentBenchCase!s(size, mostlySafe);
        benchCase(
            name: "scalar",
            labels: ["set": setName, "op": "encode", "data": dataName],
            timed: &c.timedEncode,
            after: &c.afterEncode,
            metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
        benchCase(
            name: "scalar",
            labels: ["set": setName, "op": "decode", "data": dataName],
            timed: &c.timedDecode,
            after: &c.afterDecode,
            metrics: [Metric(Unit("B"), size, Metric.Mode.rate)]);
    }
}

/// Percent-encoding throughput depends heavily on how much of the input
/// escapes, so the matrix varies the data profile as well as the set.
@("text.percent.bench")
@benchmark @safe
unittest
{
    enum size = 1 << 16;
    registerPercentBench!percentComponent("component", "text", true, size);
    registerPercentBench!percentComponent("component", "binary", false, size);
    registerPercentBench!percentQuery("query", "text", true, size);
    registerPercentBench!percentFormUrlencoded("form", "text", true, size);
}
