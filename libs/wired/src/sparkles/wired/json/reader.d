/**
The strict RFC 8259 arena reader (SPEC §11.3).

`parseJsonDocument` turns JSON text into a $(LREF JsonDocument) in one
pass: the input is copied into the document's string pool with four
bytes of zero padding (so every scan is termination-safe and strings
unescape in place), and values append to the cell arena with the
threaded-parent scheme — an open container's payload temporarily stores
its parent's cell $(I index), so there is neither host recursion nor a
separate stack, and a growing arena needs no pointer fixups.

Defaults are strict RFC 8259: invalid UTF-8, trailing commas, comments,
`inf`/`nan` literals, leading zeros, bare `.5`/`1.` numbers, and
trailing content are all rejected with a precise `ParseError`.
*/
module sparkles.wired.json.reader;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

import sparkles.base.text.errors : ParseError, ParseErrorCode;
import sparkles.base.text.float_conv : bitsToDouble, doubleToBits, readDigits,
    slowDouble, tryFastDouble;
import sparkles.base.text.utf8 : indexOfInvalidUtf8;
import sparkles.wired.json.document : JsonCell, JsonDocument, JsonKind;
import sparkles.wired.json.scan : allDigits8, eightDigits, loadWord,
    scanStringBody, skipWs, StringScan;

/// Compile-time reader configuration (SPEC §11.3). Each combination
/// specializes the reader; dead option branches vanish.
struct JsonReadOptions
{
    bool rawNumbers = false; /// keep numbers as verbatim token text
    bool validateUtf8 = true; /// strict RFC 8259: reject ill-formed UTF-8
    uint maxDepth = 1024; /// nesting limit (`depthExceeded` beyond)

    // Declared, not yet implemented (SPEC §11.3):
    bool allowTrailingCommas = false; /// ditto
    bool allowComments = false; /// ditto
    bool allowInfNan = false; /// ditto
    bool insitu = false; /// ditto
    bool stopWhenDone = false; /// ditto
}

/// The outcome of a parse: the document, or a `ParseError` (byte offset
/// into the original input). Expected-shaped; the non-copyable document
/// forbids the `Expected` type itself.
struct JsonParseResult(Allocator = Mallocator)
{
    JsonDocument!Allocator document; /// valid iff `hasValue`
    ParseError error; /// meaningful iff `hasError`

    bool hasValue() const @safe pure nothrow @nogc => document.valid;
    /// ditto
    bool hasError() const @safe pure nothrow @nogc => !document.valid;
}

/**
Parses `text` into an arena document (SPEC §11.3). The input needs no
padding or NUL termination and is never modified. Attributes infer from
the allocator — over the `Mallocator` default the whole parse path is
`@safe pure nothrow @nogc`.
*/
JsonParseResult!Allocator parseJsonDocument(
    JsonReadOptions opts = JsonReadOptions.init, Allocator = Mallocator)(
    scope const(char)[] text)
if (stateSize!Allocator == 0)
{
    JsonParseResult!Allocator result;
    parseInto!opts(result, text);
    return result;
}

/// ditto — stateful allocators pass an instance (the store-the-allocator
/// rule: the document keeps it for its whole lifetime).
JsonParseResult!Allocator parseJsonDocument(
    JsonReadOptions opts = JsonReadOptions.init, Allocator)(
    scope const(char)[] text, Allocator alloc)
if (stateSize!Allocator != 0)
{
    import core.lifetime : move;

    JsonParseResult!Allocator result;
    result.document.alloc = move(alloc);
    parseInto!opts(result, text);
    return result;
}

private enum ulong maxCellSize = (1UL << 56) - 1;

/// Branch-expectation hint (folds away when the backend lacks it).
private pragma(inline, true) bool unlikely()(bool cond)
{
    import core.builtins : expect;

    return expect(cond, false);
}

private void parseInto(JsonReadOptions opts, Allocator)(
    ref JsonParseResult!Allocator result, scope const(char)[] text)
{
    static assert(!opts.allowTrailingCommas && !opts.allowComments
            && !opts.allowInfNan && !opts.insitu && !opts.stopWhenDone,
        "JsonReadOptions flag declared but not implemented yet (SPEC §11.3)");

    void fail(ParseErrorCode code, size_t offset, string context = null)
    {
        result.error = ParseError(code, offset, context);
        result.document.cellCount = 0;
    }

    if (text.length == 0)
    {
        fail(ParseErrorCode.emptyInput, 0);
        return;
    }

    // Cell estimate: ~1 cell / 6 bytes minified, ~1 / 16 pretty
    // (whitespace-heavy). Underestimates grow ×1.5.
    const looksPretty = text.length >= 2 && (text[0] == '{' || text[0] == '[')
        && (text[1] == '\n' || text[1] == ' ' || text[1] == '\r' || text[1] == '\t');
    const cellEstimate = text.length / (looksPretty ? 16 : 6) + 4;

    if (!result.document.acquire(cellEstimate, text.length + 8))
    {
        fail(ParseErrorCode.outOfMemory, 0);
        return;
    }

    auto doc = () @trusted { return &result.document; }();
    auto pool = doc.pool;
    pool[0 .. text.length] = text[];
    pool[text.length .. text.length + 8] = '\0';

    const n = text.length; // content length; padding beyond
    size_t i = 0;

    // ── cell append / container machinery (threaded parent) ─────────────
    // Hot state lives in locals — stores through `pool` would otherwise
    // force conservative reloads of every document field on each append;
    // the document is synced at growth and on completion.
    auto cells = doc.cells;
    size_t cellCount = 0;

    enum size_t noParent = size_t.max;
    size_t parent = noParent;
    bool parentIsObject = false; // cells[parent].kind cached (hot loop)
    uint depth = 0;

    // Returns the new cell's index, or size_t.max on allocation failure.
    size_t appendCell(JsonKind kind, ulong size = 0)
    {
        if (unlikely(cellCount == cells.length))
        {
            doc.cellCount = cellCount;
            if (!doc.growCells())
                return size_t.max;
            cells = doc.cells;
        }
        const idx = cellCount++;
        cells[idx] = JsonCell(kind, size);
        return idx;
    }

    // Appends a scalar cell with a u64/i64/f64 payload; false on OOM.
    bool appendScalar(JsonKind kind, ulong payload)
    {
        const idx = appendCell(kind);
        if (idx == size_t.max)
        {
            fail(ParseErrorCode.outOfMemory, i);
            return false;
        }
        cells[idx].bits = payload;
        return true;
    }

    bool appendStringCell(size_t start, size_t len,
        JsonKind kind = JsonKind.string_)
    {
        const idx = appendCell(kind, len);
        if (idx == size_t.max)
        {
            fail(ParseErrorCode.outOfMemory, i);
            return false;
        }
        () @trusted {
            cells[idx].bits = cast(ulong)(pool.ptr + start);
        }();
        return true;
    }


    // Validates the UTF-8 of pool[from .. to] (a string's decoded bytes).
    bool validateSpan(size_t from, size_t to)
    {
        const bad = indexOfInvalidUtf8(pool[from .. to]);
        if (bad == to - from)
            return true;
        fail(ParseErrorCode.invalidUtf8, from + bad);
        return false;
    }

    // ── string scanning (shared by keys and values) ──────────────────────
    // Parses the string whose opening quote sits at `i` and appends its
    // cell; on success `i` is past the closing quote. On failure fail()
    // has run and false returns.
    bool parseString(JsonKind kind = JsonKind.string_)()
    {
        const openQuote = i;
        i++; // past '"'
        const start = i;
        const scan = scanStringBody(pool, i);
        size_t j = scan.stop;
        if (unlikely(j >= n))
        {
            fail(ParseErrorCode.unexpectedEnd, openQuote);
            return false;
        }
        if (pool[j] == '"') // fast lane: no escapes
        {
            static if (opts.validateUtf8)
            {
                if (scan.sawHigh && !validateSpan(start, j))
                    return false;
            }
            pool[j] = '\0';
            i = j + 1;
            return appendStringCell(start, j - start, kind);
        }
        if (pool[j] != '\\')
        {
            fail(ParseErrorCode.unexpectedCharacter, j,
                "control character inside string");
            return false;
        }

        // Escape lane: unescape in place (dst ≤ src always); clean
        // segments between escapes move as one bulk copy over the same
        // SWAR scan as the fast lane.
        size_t dst = j;
        size_t src = j;
        while (true)
        {
            if (src >= n)
            {
                fail(ParseErrorCode.unexpectedEnd, openQuote);
                return false;
            }
            const c = pool[src];
            if (c == '"')
                break;
            if (c < 0x20)
            {
                fail(ParseErrorCode.unexpectedCharacter, src,
                    "control character inside string");
                return false;
            }
            if (c != '\\')
            {
                // Bulk-move the clean run up to the next stop byte.
                // dst ≤ src and copying forward word-by-word is overlap-
                // safe for a leftward move; ≥8 padding bytes keep the
                // word loads in bounds. Escape-dense strings have tiny
                // segments — avoid the memmove call for them.
                const seg = scanStringBody(pool, src).stop - src;
                () @trusted {
                    auto d = pool.ptr + dst;
                    auto q = pool.ptr + src;
                    if (src - dst >= 8)
                    {
                        // Word copies rounded up to 8: the ≤7-byte
                        // overshoot lands in the dead zone between the
                        // shrunken destination and the unconsumed source
                        // (gap ≥ 8 guarantees it), and pool padding keeps
                        // the loads in bounds.
                        size_t k = 0;
                        do
                        {
                            memcpyWord(d + k, q + k);
                            k += 8;
                        }
                        while (k < seg);
                    }
                    else
                        foreach (k; 0 .. seg)
                            d[k] = q[k];
                }();
                dst += seg;
                src += seg;
                continue;
            }

            const escAt = src;
            src++;
            if (src >= n)
            {
                fail(ParseErrorCode.unexpectedEnd, escAt);
                return false;
            }
            const e = pool[src];
            src++;
            switch (e)
            {
            case '"', '\\', '/':
                pool[dst++] = e;
                break;
            case 'b':
                pool[dst++] = '\b';
                break;
            case 'f':
                pool[dst++] = '\f';
                break;
            case 'n':
                pool[dst++] = '\n';
                break;
            case 'r':
                pool[dst++] = '\r';
                break;
            case 't':
                pool[dst++] = '\t';
                break;
            case 'u':
                uint cp;
                if (!readHex4(pool, n, src, cp))
                {
                    fail(ParseErrorCode.invalidEscape, escAt);
                    return false;
                }
                if (cp >= 0xD800 && cp <= 0xDBFF) // high surrogate
                {
                    if (src + 1 < n && pool[src] == '\\' && pool[src + 1] == 'u')
                    {
                        src += 2;
                        uint low;
                        if (!readHex4(pool, n, src, low))
                        {
                            fail(ParseErrorCode.invalidEscape, escAt);
                            return false;
                        }
                        if (low < 0xDC00 || low > 0xDFFF)
                        {
                            fail(ParseErrorCode.invalidSurrogate, escAt);
                            return false;
                        }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                    }
                    else
                    {
                        fail(ParseErrorCode.invalidSurrogate, escAt);
                        return false;
                    }
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF) // lone low surrogate
                {
                    fail(ParseErrorCode.invalidSurrogate, escAt);
                    return false;
                }
                dst += encodeUtf8(pool, dst, cp);
                break;
            default:
                fail(ParseErrorCode.invalidEscape, escAt);
                return false;
            }
        }
        static if (opts.validateUtf8)
        {
            if (!validateSpan(start, dst))
                return false;
        }
        pool[dst] = '\0';
        i = src + 1; // past closing quote
        return appendStringCell(start, dst - start, kind);
    }


    // ── number scanning (fused grammar + accumulation) ───────────────────
    // Pointer-based kernel: the ≥8-byte zero padding terminates every
    // digit run, so the hot loops carry no bounds checks. @trusted with
    // the same invariant as the scan seams.
    bool parseNumber() @trusted
    {
        auto p = pool.ptr;
        const tokenStart = i;
        size_t k = i;
        bool negative = false;
        if (p[k] == '-')
        {
            negative = true;
            k++;
        }

        // Integer part (strict: no leading zeros, at least one digit).
        const intStart = k;
        ulong sig = 0;
        size_t taken = 0;
        if (p[k] == '0')
        {
            k++;
            taken = 1;
            if (unlikely(p[k] >= '0' && p[k] <= '9'))
            {
                fail(ParseErrorCode.leadingZero, tokenStart);
                return false;
            }
        }
        else
        {
            // Accumulate up to 19 digits: eight per SWAR gulp while the
            // budget allows (long ids; the pool padding keeps the loads
            // in bounds), then unrolled two at a time.
            while (taken + 8 <= 18)
            {
                const w = loadWord(p + k);
                if (!allDigits8(w))
                    break;
                sig = sig * 100_000_000 + eightDigits(w);
                taken += 8;
                k += 8;
            }
            while (taken < 18)
            {
                const uint d0 = cast(uint)(p[k] - '0');
                if (d0 > 9)
                    break;
                const uint d1 = cast(uint)(p[k + 1] - '0');
                if (d1 > 9)
                {
                    sig = sig * 10 + d0;
                    taken++;
                    k++;
                    break;
                }
                sig = sig * 100 + d0 * 10 + d1;
                taken += 2;
                k += 2;
            }
            if (taken == 18)
            {
                const uint d = cast(uint)(p[k] - '0');
                if (d <= 9)
                {
                    sig = sig * 10 + d;
                    taken++;
                    k++;
                }
            }
            if (taken == 0)
            {
                fail(ParseErrorCode.unexpectedCharacter, k);
                return false;
            }
        }
        // Integer digits beyond the 19-digit accumulator (cold).
        size_t intExtra = 0;
        while (unlikely(p[k] >= '0' && p[k] <= '9'))
        {
            intExtra++;
            k++;
        }
        const intEnd = k;

        // Fraction.
        size_t fracStart = 0, fracEnd = 0, fracTaken = 0;
        bool fracExtraNonzero = false;
        if (p[k] == '.')
        {
            k++;
            fracStart = k;
            if (intExtra == 0)
            {
                // Two digits per iteration, mirroring the integer loop;
                // the budget bound is hoisted so the loop carries a
                // single moving index.
                const fs = k;
                const budgetEnd = k + (19 - taken);
                // Eight fraction digits per SWAR gulp first — the
                // dominant shape in geo data (canada: 2-3 integer digits
                // then 15-17 fraction digits).
                while (k + 8 <= budgetEnd)
                {
                    const w = loadWord(p + k);
                    if (!allDigits8(w))
                        break;
                    sig = sig * 100_000_000 + eightDigits(w);
                    k += 8;
                }
                while (k + 2 <= budgetEnd)
                {
                    const uint d0 = cast(uint)(p[k] - '0');
                    if (d0 > 9)
                        break;
                    const uint d1 = cast(uint)(p[k + 1] - '0');
                    if (d1 > 9)
                    {
                        sig = sig * 10 + d0;
                        k++;
                        break;
                    }
                    sig = sig * 100 + d0 * 10 + d1;
                    k += 2;
                }
                if (k < budgetEnd)
                {
                    const uint d = cast(uint)(p[k] - '0');
                    if (d <= 9)
                    {
                        sig = sig * 10 + d;
                        k++;
                    }
                }
                fracTaken = k - fs;
                taken += fracTaken;
            }
            while (p[k] >= '0' && p[k] <= '9')
            {
                fracExtraNonzero |= p[k] != '0';
                k++;
            }
            fracEnd = k;
            if (fracEnd == fracStart)
            {
                fail(ParseErrorCode.unexpectedCharacter, k,
                    "digit required after decimal point");
                return false;
            }
        }

        // Exponent.
        int explicitExp = 0;
        bool hasExp = false;
        if ((p[k] | 0x20) == 'e')
        {
            hasExp = true;
            k++;
            bool expNeg = false;
            if (p[k] == '+' || p[k] == '-')
            {
                expNeg = p[k] == '-';
                k++;
            }
            ulong e = 0;
            size_t eDigits = 0;
            while (eDigits < 10)
            {
                const uint d = cast(uint)(p[k] - '0');
                if (d > 9)
                    break;
                e = e * 10 + d;
                eDigits++;
                k++;
            }
            if (eDigits == 0)
            {
                fail(ParseErrorCode.unexpectedCharacter, k,
                    "digit required in exponent");
                return false;
            }
            while (p[k] >= '0' && p[k] <= '9') // absurd exponents saturate
                k++;
            if (e > 400)
                e = 400;
            explicitExp = expNeg ? -cast(int) e : cast(int) e;
        }
        i = k;

        static if (opts.rawNumbers)
        {
            return appendStringCell(tokenStart, i - tokenStart, JsonKind.rawNumber);
        }
        else
        {
            const isInt = fracStart == 0 && !hasExp;
            if (isInt && intExtra == 0) // ≤19 digits: exact
            {
                if (!negative)
                {
                    const kind = sig <= long.max
                        ? JsonKind.integer : JsonKind.uinteger;
                    return appendScalar(kind, sig);
                }
                if (sig == 0) // "-0": preserve the sign (yyjson behavior)
                    return appendScalar(JsonKind.floating, doubleToBits(-0.0));
                if (sig <= 1UL << 63) // down to long.min
                    return appendScalar(JsonKind.integer, 0 - sig);
                // Below long.min: floating (≤19-digit ulong → double is
                // a single correct rounding).
                return appendScalar(JsonKind.floating,
                    doubleToBits(-cast(double) sig));
            }
            if (isInt && intExtra == 1)
            {
                // The 20-digit u64 tail: one extra digit may still fit.
                const d = cast(uint)(p[intEnd - 1] - '0');
                if (sig < ulong.max / 10
                    || (sig == ulong.max / 10 && d <= ulong.max % 10))
                {
                    const wide = sig * 10 + d;
                    if (negative)
                        return appendScalar(JsonKind.floating,
                            doubleToBits(-cast(double) wide));
                    const kind = wide <= long.max
                        ? JsonKind.integer : JsonKind.uinteger;
                    return appendScalar(kind, wide);
                }
            }

            // Floating path (fraction / exponent / oversized integer).
            // Conservative truncation: extra integer digits might be all
            // zeros (still exact), but claiming truncation just routes
            // through bracketing or slowDouble — exact either way.
            const truncated = intExtra != 0 || fracExtraNonzero;
            const exp10 = explicitExp + cast(int) intExtra - cast(int) fracTaken;

            double value;
            bool decided;
            if (!truncated)
                decided = tryFastDouble(sig, exp10, value);
            else
            {
                // Bracket: if sig and sig+1 round identically, the true
                // in-between value must round there too.
                double lowV, highV;
                decided = tryFastDouble(sig, exp10, lowV)
                    && tryFastDouble(sig + 1, exp10, highV)
                    && doubleToBits(lowV) == doubleToBits(highV);
                value = lowV;
            }
            if (!decided)
                value = slowDouble(pool[intStart .. intEnd],
                    fracStart == 0 ? null : pool[fracStart .. fracEnd],
                    explicitExp);

            return appendScalar(JsonKind.floating,
                doubleToBits(negative ? -value : value));
        }
    }

    // ── literals ─────────────────────────────────────────────────────────
    bool parseLiteral(string lit)(JsonKind kind, ulong payload)
    {
        // One unaligned 32-bit compare ("true"/"null"/"alse" after 'f');
        // the zero padding makes the loads safe near the end.
        enum tail = lit.length == 5 ? lit[1 .. 5] : lit;
        enum uint word = tail[0] | tail[1] << 8 | tail[2] << 16
            | cast(uint) tail[3] << 24;
        const at = i + (lit.length == 5 ? 1 : 0);
        const got = (() @trusted {
            import core.stdc.string : memcpy;

            uint w;
            memcpy(&w, pool.ptr + at, 4);
            return w;
        })();
        if (got != word)
        {
            fail(ParseErrorCode.unexpectedCharacter, i);
            return false;
        }
        i += lit.length;
        return appendScalar(kind, payload);
    }

    // ── the grammar loop ─────────────────────────────────────────────────
    skipWs(pool, i);

value: // parse one value at pool[i]
    if (i >= n)
    {
        fail(ParseErrorCode.unexpectedEnd, i);
        return;
    }
    {
        const c0 = pool[i];
        if (c0 == '"') // most frequent first (string-heavy JSON)
        {
            if (!parseString!()())
                return;
            goto afterValue;
        }
        if (c0 != '{' && c0 != '[')
        {
            if (c0 == 't')
            {
                if (!parseLiteral!"true"(JsonKind.bool_, 1))
                    return;
                goto afterValue;
            }
            if (c0 == 'f')
            {
                if (!parseLiteral!"false"(JsonKind.bool_, 0))
                    return;
                goto afterValue;
            }
            if (c0 == 'n')
            {
                if (!parseLiteral!"null"(JsonKind.null_, 0))
                    return;
                goto afterValue;
            }
            if (!parseNumber())
                return;
            goto afterValue;
        }
        {
            const isObject = c0 == '{';
            if (depth >= opts.maxDepth)
            {
                fail(ParseErrorCode.depthExceeded, i);
                return;
            }
            depth++;
            const idx = appendCell(isObject ? JsonKind.object : JsonKind.array);
            if (idx == size_t.max)
            {
                fail(ParseErrorCode.outOfMemory, i);
                return;
            }
            cells[idx].bits = parent; // threaded parent
            parent = idx;
            parentIsObject = isObject;
            i++;
            skipWs(pool, i);
            if (i < n && pool[i] == (isObject ? '}' : ']'))
            {
                i++;
                goto closeContainer;
            }
            if (isObject)
                goto objectKey;
            goto value;
        }
    }

objectKey: // parse `"key" :` then its value
    if (i >= n || pool[i] != '"')
    {
        fail(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter,
            i, "object key must be a string");
        return;
    }
    {
        // Short-key fast path: keys are overwhelmingly ≤15 bytes of
        // escape-free ASCII — find the quote in two word loads and skip
        // the general machinery (which remains the fallback).
        const quick = (() @trusted {
            enum ulong ones = 0x0101_0101_0101_0101;
            enum ulong highs = 0x8080_8080_8080_8080;
            auto p = pool.ptr + i + 1;
            static ulong stopsOf(ulong x)
            {
                const q = x ^ 0x2222_2222_2222_2222; // '"'
                const b = x ^ 0x5C5C_5C5C_5C5C_5C5C; // '\\'
                return ((q - ones) & ~q & highs)
                    | ((b - ones) & ~b & highs)
                    | ((x - 0x2020_2020_2020_2020) & ~x & highs)
                    | (x & highs);
            }

            import core.bitop : bsf;

            const x0 = loadWord(p);
            const s0 = stopsOf(x0);
            if (s0 != 0)
            {
                const at = bsf(s0) / 8;
                return p[at] == '"' ? at : size_t.max;
            }
            const x1 = loadWord(p + 8);
            const s1 = stopsOf(x1);
            if (s1 != 0)
            {
                const at = 8 + bsf(s1) / 8;
                return p[at] == '"' ? at : size_t.max;
            }
            return size_t.max; // long/escaped/non-ASCII key: general path
        })();
        if (quick != size_t.max)
        {
            const start = i + 1;
            pool[start + quick] = '\0';
            i = start + quick + 1;
            if (!appendStringCell(start, quick))
                return;
        }
        else if (!parseString!()())
            return;
    }
    skipWs(pool, i);
    if (i >= n || pool[i] != ':')
    {
        fail(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter,
            i, "':' expected after object key");
        return;
    }
    i++;
    skipWs(pool, i);
    goto value;

afterValue: // a value completed; count it, then continue its container
    if (parent == noParent)
        goto endCheck;
    cells[parent].tag += 1UL << 8; // one more member
    skipWs(pool, i);
    if (unlikely(i >= n))
    {
        fail(ParseErrorCode.unexpectedEnd, i);
        return;
    }
    {
        const isObject = parentIsObject;
        const c = pool[i];
        if (c == ',')
        {
            // Minified object hot path: `,"` starts the next key.
            if (isObject && pool[i + 1] == '"')
            {
                i++;
                goto objectKey;
            }
            i++;
            skipWs(pool, i);
            if (isObject)
                goto objectKey;
            goto value;
        }
        if (c == (isObject ? '}' : ']'))
        {
            i++;
            goto closeContainer;
        }
        fail(ParseErrorCode.unexpectedCharacter, i,
            "',' or container close expected");
        return;
    }

closeContainer: // finalize cells[parent], pop the threaded parent
    {
        const idx = parent;
        parent = cast(size_t) cells[idx].bits;
        parentIsObject = parent != noParent
            && cells[parent].kind == JsonKind.object;
        cells[idx].bits = cellCount - idx;
        depth--;
        goto afterValue;
    }

endCheck:
    skipWs(pool, i);
    if (i != n)
    {
        fail(ParseErrorCode.trailingContent, i);
        return;
    }
    doc.cellCount = cellCount; // success: nonzero ⇒ hasValue
}

/// Copies one 8-byte word (used by the escape lane's segment moves;
/// callers guarantee in-bounds via the pool padding).
private void memcpyWord(char* d, const(char)* q) @system pure nothrow @nogc
{
    pragma(inline, true);
    import core.stdc.string : memcpy;

    ulong x;
    memcpy(&x, q, 8);
    memcpy(d, &x, 8);
}

/**
Validates that `text` is a single well-formed RFC 8259 JSON document —
the same strict grammar as $(LREF parseJsonDocument), materializing
nothing: no input copy, no arena, no unescaping (SPEC §11.5). Roughly
the parse loop minus every store, over the original (unpadded) input.
*/
ParseError validateJson(scope const(char)[] text) @safe pure nothrow @nogc
{
    // Non-failure sentinel: code emptyInput + offset max (never produced
    // for real errors, which use offset < length or == length).
    enum size_t none = size_t.max;

    const n = text.length;
    if (n == 0)
        return ParseError(ParseErrorCode.emptyInput, 0);

    size_t i = 0;
    uint depth = 0;
    // Container kinds as a bit stack: 1 = object, 0 = array (bounded
    // only by input size — one ulong word per 64 levels).
    ulong[16] kindStack; // 1024 levels — matches the reader's default cap
    bool parentIsObject = false;

    void skipWsG() @safe pure nothrow @nogc
    {
        while (i < n && (text[i] == ' ' || text[i] == '\t'
                || text[i] == '\n' || text[i] == '\r'))
            i++;
    }

    // Validates the string whose opening quote sits at `i`; advances past
    // the closing quote. Returns the error offset or `none`.
    size_t checkString() @safe pure nothrow @nogc
    {
        const openQuote = i;
        i++;
        while (true)
        {
            if (i >= n)
                return openQuote; // unterminated
            const c = text[i];
            if (c == '"')
            {
                i++;
                return none;
            }
            if (c < 0x20)
                return i;
            if (c >= 0x80)
            {
                import sparkles.base.text.utf8 : utf8SequenceLength;

                const len = utf8SequenceLength(text, i);
                if (len == 0)
                    return i;
                i += len;
                continue;
            }
            if (c != '\\')
            {
                i++;
                continue;
            }
            // Escape.
            i++;
            if (i >= n)
                return openQuote;
            const e = text[i];
            i++;
            switch (e)
            {
            case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
                break;
            case 'u':
                uint cp;
                if (!readHex4(text, n, i, cp))
                    return i - 2;
                if (cp >= 0xD800 && cp <= 0xDBFF)
                {
                    if (i + 1 < n && text[i] == '\\' && text[i + 1] == 'u')
                    {
                        i += 2;
                        uint low;
                        if (!readHex4(text, n, i, low))
                            return i - 2;
                        if (low < 0xDC00 || low > 0xDFFF)
                            return i - 6;
                    }
                    else
                        return i - 6;
                }
                else if (cp >= 0xDC00 && cp <= 0xDFFF)
                    return i - 6;
                break;
            default:
                return i - 2;
            }
        }
    }

    // Validates the number starting at `i` (guarded — no padding here).
    size_t checkNumber() @safe pure nothrow @nogc
    {
        const tokenStart = i;
        if (text[i] == '-')
            i++;
        if (i >= n)
            return tokenStart;
        if (text[i] == '0')
        {
            i++;
            if (i < n && text[i] >= '0' && text[i] <= '9')
                return tokenStart; // leading zero
        }
        else
        {
            if (text[i] < '1' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        if (i < n && text[i] == '.')
        {
            i++;
            if (i >= n || text[i] < '0' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        if (i < n && (text[i] == 'e' || text[i] == 'E'))
        {
            i++;
            if (i < n && (text[i] == '+' || text[i] == '-'))
                i++;
            if (i >= n || text[i] < '0' || text[i] > '9')
                return i;
            while (i < n && text[i] >= '0' && text[i] <= '9')
                i++;
        }
        return none;
    }

    size_t checkLiteral(string lit)() @safe pure nothrow @nogc
    {
        if (n - i < lit.length || text[i .. i + lit.length] != lit)
            return i;
        i += lit.length;
        return none;
    }

    skipWsG();

value:
    if (i >= n)
        return ParseError(ParseErrorCode.unexpectedEnd, i);
    {
        const c0 = text[i];
        if (c0 == '"')
        {
            const bad = checkString();
            if (bad != none)
                return ParseError(ParseErrorCode.unexpectedCharacter, bad,
                    "invalid string");
            goto afterValue;
        }
        if (c0 == '{' || c0 == '[')
        {
            if (depth >= 1024)
                return ParseError(ParseErrorCode.depthExceeded, i);
            const bit = 1UL << (depth & 63);
            if (c0 == '{')
                kindStack[depth >> 6] |= bit;
            else
                kindStack[depth >> 6] &= ~bit;
            parentIsObject = c0 == '{';
            depth++;
            i++;
            skipWsG();
            if (i < n && text[i] == (parentIsObject ? '}' : ']'))
            {
                i++;
                goto closeContainer;
            }
            if (parentIsObject)
                goto objectKey;
            goto value;
        }
        size_t bad;
        if (c0 == 't')
            bad = checkLiteral!"true"();
        else if (c0 == 'f')
            bad = checkLiteral!"false"();
        else if (c0 == 'n')
            bad = checkLiteral!"null"();
        else
            bad = checkNumber();
        if (bad != none)
            return ParseError(ParseErrorCode.unexpectedCharacter, bad);
        goto afterValue;
    }

objectKey:
    if (i >= n || text[i] != '"')
        return ParseError(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter, i,
            "object key must be a string");
    {
        const bad = checkString();
        if (bad != none)
            return ParseError(ParseErrorCode.unexpectedCharacter, bad,
                "invalid string");
    }
    skipWsG();
    if (i >= n || text[i] != ':')
        return ParseError(i >= n ? ParseErrorCode.unexpectedEnd
                : ParseErrorCode.unexpectedCharacter, i,
            "':' expected after object key");
    i++;
    skipWsG();
    goto value;

afterValue:
    if (depth == 0)
        goto endCheck;
    skipWsG();
    if (i >= n)
        return ParseError(ParseErrorCode.unexpectedEnd, i);
    {
        const c = text[i];
        if (c == ',')
        {
            i++;
            skipWsG();
            if (parentIsObject)
                goto objectKey;
            goto value;
        }
        if (c == (parentIsObject ? '}' : ']'))
        {
            i++;
            goto closeContainer;
        }
        return ParseError(ParseErrorCode.unexpectedCharacter, i,
            "',' or container close expected");
    }

closeContainer:
    depth--;
    parentIsObject = depth > 0
        && (kindStack[(depth - 1) >> 6] & (1UL << ((depth - 1) & 63))) != 0;
    goto afterValue;

endCheck:
    skipWsG();
    if (i != n)
        return ParseError(ParseErrorCode.trailingContent, i);
    return ParseError(ParseErrorCode.emptyInput, none); // the ok sentinel
}

/// Whether a $(LREF validateJson) result means "well-formed".
bool isValidJson(const ParseError e) @safe pure nothrow @nogc
    => e.code == ParseErrorCode.emptyInput && e.offset == size_t.max;

/// Convenience: one-call well-formedness check.
bool isValidJson(scope const(char)[] text) @safe pure nothrow @nogc
    => isValidJson(validateJson(text));

/// Reads exactly 4 hex digits at `src`, advancing it.
private bool readHex4(scope const(char)[] pool, size_t n, ref size_t src,
    out uint value) @safe pure nothrow @nogc
{
    if (n - src < 4)
        return false;
    uint v = 0;
    foreach (k; 0 .. 4)
    {
        const c = pool[src + k];
        uint d;
        if (c >= '0' && c <= '9')
            d = c - '0';
        else if (c >= 'a' && c <= 'f')
            d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F')
            d = c - 'A' + 10;
        else
            return false;
        v = (v << 4) | d;
    }
    src += 4;
    value = v;
    return true;
}

/// Encodes `cp` (a valid scalar value) as UTF-8 at `pool[dst]`; returns
/// the byte count.
private size_t encodeUtf8(scope char[] pool, size_t dst, uint cp)
    @safe pure nothrow @nogc
{
    if (cp < 0x80)
    {
        pool[dst] = cast(char) cp;
        return 1;
    }
    if (cp < 0x800)
    {
        pool[dst] = cast(char)(0xC0 | (cp >> 6));
        pool[dst + 1] = cast(char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000)
    {
        pool[dst] = cast(char)(0xE0 | (cp >> 12));
        pool[dst + 1] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
        pool[dst + 2] = cast(char)(0x80 | (cp & 0x3F));
        return 3;
    }
    pool[dst] = cast(char)(0xF0 | (cp >> 18));
    pool[dst + 1] = cast(char)(0x80 | ((cp >> 12) & 0x3F));
    pool[dst + 2] = cast(char)(0x80 | ((cp >> 6) & 0x3F));
    pool[dst + 3] = cast(char)(0x80 | (cp & 0x3F));
    return 4;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

version (unittest)
{
    private JsonParseResult!Mallocator parse(scope const(char)[] text)
        @safe pure nothrow @nogc
        => parseJsonDocument(text);
}

@("reader.scalars.roots")
@safe pure nothrow @nogc
unittest
{
    {
        auto r = parse(`true`);
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.bool_);
        assert(r.document.root.boolean == true);
    }
    {
        auto r = parse(`false`);
        assert(r.hasValue && r.document.root.boolean == false);
    }
    {
        auto r = parse(`null`);
        assert(r.hasValue && r.document.root.kind == JsonKind.null_);
    }
    {
        auto r = parse(`"hello"`);
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.string_);
        assert(r.document.root.str == "hello");
    }
    {
        auto r = parse(` 42 `);
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.integer);
        assert(r.document.root.integer == 42);
    }
}

@("reader.numbers.pins")
@safe pure nothrow @nogc
unittest
{
    static void checkInt(string text, long expected)
    {
        auto r = parse(text);
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.integer);
        assert(r.document.root.integer == expected);
    }

    static void checkF(string text, double expected)
    {
        auto r = parse(text);
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.floating);
        assert(doubleToBits(r.document.root.floating) == doubleToBits(expected));
    }

    checkInt("0", 0);
    checkInt("-1", -1);
    checkInt("9223372036854775807", long.max);
    checkInt("-9223372036854775808", long.min);

    {
        auto r = parse("18446744073709551615"); // ulong.max (20 digits)
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.uinteger);
        assert(r.document.root.uinteger == ulong.max);
    }
    {
        auto r = parse("9223372036854775808"); // long.max + 1
        assert(r.hasValue);
        assert(r.document.root.kind == JsonKind.uinteger);
        assert(r.document.root.uinteger == 9_223_372_036_854_775_808UL);
    }

    checkF("-0", -0.0); // sign preserved (yyjson behavior)
    checkF("1.5", 1.5);
    checkF("-3.14159", -3.14159);
    checkF("1e10", 1e10);
    checkF("2.5e-3", 2.5e-3);
    checkF("1e999", double.infinity); // saturation
    checkF("-1e999", -double.infinity);
    checkF("1e-999", 0.0);
    checkF("18446744073709551616", 18_446_744_073_709_551_616.0); // ulong.max+1
    checkF("-9223372036854775809", -9_223_372_036_854_775_809.0);
    checkF("1e23", bitsToDouble(0x44B5_2D02_C7E1_4AF6)); // exact-tier tie
    checkF("5e-324", bitsToDouble(1)); // smallest subnormal

    // Long-digit torture: 301 integer digits (1 then 300 zeros) exercise
    // the oversized-integer path; the value is exactly 1e300.
    {
        char[301] longInt = '0';
        longInt[0] = '1';
        auto r = parse(longInt[]);
        assert(r.hasValue);
        assert(doubleToBits(r.document.root.floating) == doubleToBits(1e300));
    }
    // 100 fraction threes round to the double nearest 1/3.
    {
        char[102] third = '3';
        third[0] = '0';
        third[1] = '.';
        auto r = parse(third[]);
        assert(r.hasValue);
        assert(doubleToBits(r.document.root.floating)
            == doubleToBits(1.0 / 3.0));
    }
}

@("reader.strings.escapes")
@safe pure nothrow @nogc
unittest
{
    {
        auto r = parse(`"a\nb\t\"c\"A\\"`);
        assert(r.hasValue);
        assert(r.document.root.str == "a\nb\t\"c\"A\\");
    }
    {
        auto r = parse(`"😀"`); // surrogate pair → 😀
        assert(r.hasValue);
        assert(r.document.root.str == "\U0001F600");
    }
    {
        auto r = parse("\"\\u0000embedded\""); // embedded NUL is legal JSON
        assert(r.hasValue);
        assert(r.document.root.str.length == 9);
        assert(r.document.root.str[0] == '\0');
    }
    {
        auto r = parse(`"préservé — ユニコード 🌍"`); // raw UTF-8 passthrough
        assert(r.hasValue);
        assert(r.document.root.str == "préservé — ユニコード 🌍");
    }
    {
        auto r = parse(`"é中�"`); // 2- and 3-byte escapes
        assert(r.hasValue);
        assert(r.document.root.str == "é中�");
    }
}

@("reader.containers.nestedWalk")
@safe pure nothrow @nogc
unittest
{
    auto r = parse(`{"a": 1, "b": [true, null, 2.5], "c": {"d": "x"}}`);
    assert(r.hasValue);
    auto root = r.document.root;
    assert(root.kind == JsonKind.object);
    assert(root.length == 3);

    assert(root.objectGet("a").integer == 1);

    auto b = root.objectGet("b");
    assert(b.kind == JsonKind.array && b.length == 3);
    size_t idx;
    foreach (v; b.byElement)
    {
        final switch (idx)
        {
        case 0:
            assert(v.boolean == true);
            break;
        case 1:
            assert(v.kind == JsonKind.null_);
            break;
        case 2:
            assert(v.floating == 2.5);
            break;
        }
        idx++;
    }
    assert(idx == 3);

    auto c = root.objectGet("c");
    assert(c.kind == JsonKind.object && c.length == 1);
    assert(c.objectGet("d").str == "x");

    assert(parse(`[]`).document.root.length == 0);
    assert(parse(`{}`).document.root.length == 0);
    assert(parse(`[[[[[]]]]]`).hasValue);
    assert(parse(`[{"k":[{"deep":[1,2,[3]]}]}]`).hasValue);
}

@("reader.rejections.strictRfc8259")
@safe pure nothrow @nogc
unittest
{
    static void reject(string text)
    {
        auto r = parse(text);
        assert(r.hasError, text);
    }

    static void rejectAs(string text, ParseErrorCode code)
    {
        auto r = parse(text);
        assert(r.hasError, text);
        assert(r.error.code == code, text);
    }

    reject("");
    reject("  ");
    reject("tru");
    reject("truE");
    reject("nul");
    rejectAs("01", ParseErrorCode.leadingZero);
    rejectAs("-01", ParseErrorCode.leadingZero);
    rejectAs("1.", ParseErrorCode.unexpectedCharacter);
    reject(".5");
    reject("1e");
    reject("1e+");
    reject("+1");
    reject("- 1");
    reject("0x10");
    rejectAs("1 2", ParseErrorCode.trailingContent);
    reject("[1,]");
    reject("[1 2]");
    reject("[1,,2]");
    reject(`{"a":}`);
    reject(`{"a" 1}`);
    reject("{a:1}");
    reject(`{"a":1,}`);
    reject("[");
    reject("{");
    reject("]");
    reject("[}");
    reject(`"unterminated`);
    rejectAs("\"tab\tinside\"", ParseErrorCode.unexpectedCharacter);
    rejectAs(`"\x41"`, ParseErrorCode.invalidEscape);
    rejectAs(`"\uD800"`, ParseErrorCode.invalidSurrogate); // lone high
    rejectAs(`"\uDC00"`, ParseErrorCode.invalidSurrogate); // lone low
    rejectAs(`"\uD800A"`, ParseErrorCode.invalidSurrogate);
    rejectAs(`"\u12"`, ParseErrorCode.invalidEscape);
    rejectAs("\"\xFF\xFE\"", ParseErrorCode.invalidUtf8);
    rejectAs("\"\xED\xA0\x80\"", ParseErrorCode.invalidUtf8); // raw surrogate
    reject("\xEF\xBB\xBF{}"); // BOM is not whitespace
    reject("// comment\n1");
    reject("nan");
    reject("Infinity");
}

@("reader.depth.limitEnforced")
@safe pure nothrow @nogc
unittest
{
    enum opts = JsonReadOptions(maxDepth: 8);
    auto ok = parseJsonDocument!opts(`[[[[[[[[1]]]]]]]]`); // exactly 8
    assert(ok.hasValue);
    auto deep = parseJsonDocument!opts(`[[[[[[[[[1]]]]]]]]]`); // 9
    assert(deep.hasError);
    assert(deep.error.code == ParseErrorCode.depthExceeded);
}

@("reader.rawNumbers.tokenPreserved")
@safe pure nothrow @nogc
unittest
{
    enum opts = JsonReadOptions(rawNumbers: true);
    auto r = parseJsonDocument!opts(`[0.30000000000000004, 1e999, -0]`);
    assert(r.hasValue);
    size_t idx;
    static immutable string[3] expected =
        ["0.30000000000000004", "1e999", "-0"];
    foreach (v; r.document.root.byElement)
    {
        assert(v.kind == JsonKind.rawNumber);
        assert(v.raw == expected[idx]);
        idx++;
    }
    assert(idx == 3);
}

@("reader.arena.growthAcrossEstimate")
@safe pure nothrow @nogc
unittest
{
    // A dense array of tiny values defeats the 1-cell-per-6-bytes
    // estimate, forcing at least one growCells round-trip.
    enum count = 512;
    char[2 + 2 * count] text = void;
    text[0] = '[';
    size_t w = 1;
    foreach (k; 0 .. count)
    {
        text[w++] = '1';
        text[w++] = ',';
    }
    text[w - 1] = ']';
    auto r = parse(text[0 .. w]);
    assert(r.hasValue);
    assert(r.document.root.kind == JsonKind.array);
    assert(r.document.root.length == count);
    foreach (v; r.document.root.byElement)
        assert(v.integer == 1);
}

@("reader.utf8Validation.optOut")
@safe pure nothrow @nogc
unittest
{
    // With validateUtf8 disabled, raw bytes pass through unvalidated
    // (the caller owns the consequences — SPEC §11.3).
    enum opts = JsonReadOptions(validateUtf8: false);
    auto r = parseJsonDocument!opts("\"\xFF\"");
    assert(r.hasValue);
    assert(r.document.root.str.length == 1);
}

@("reader.statefulAllocator.instancePassed")
@system unittest
{
    import std.experimental.allocator.building_blocks.region : Region;

    static struct RegionRef
    {
        Region!Mallocator* impl;
        enum uint alignment = Region!Mallocator.alignment;
        void[] allocate(size_t s) => impl.allocate(s);
        bool deallocate(void[] b) => impl.deallocate(b);
        bool expand(ref void[] b, size_t delta) => impl.expand(b, delta);
    }

    auto region = Region!Mallocator(1024 * 1024);
    auto r = parseJsonDocument(`{"region": [1, 2, 3]}`, RegionRef(&region));
    assert(r.hasValue);
    assert(r.document.root.objectGet("region").length == 3);
}

@("reader.validateJson.grammar")
@safe pure nothrow @nogc
unittest
{
    assert(isValidJson(`{"a": [1, true, "x\n", 2.5e-3, null], "b": {}}`));
    assert(isValidJson(` 42 `));
    assert(isValidJson(`"😀 ユニコード"`));
    assert(isValidJson(`[[[[[]]]]]`));

    assert(!isValidJson(``));
    assert(!isValidJson(`{`));
    assert(!isValidJson(`[1,]`));
    assert(!isValidJson(`{"a":}`));
    assert(!isValidJson(`01`));
    assert(!isValidJson(`1.`));
    assert(!isValidJson(`"\uD800"`));
    assert(!isValidJson("\"\xFF\"")); // ill-formed UTF-8
    assert(!isValidJson(`1 2`));
    assert(!isValidJson(`tru`));

    // Error positions surface like the parser's.
    const e = validateJson(`{"a": 01}`);
    assert(!isValidJson(e));
    assert(e.offset == 6);
}

@("reader.validateJson.agreesWithParser")
@safe pure nothrow @nogc
unittest
{
    static immutable string[] cases = [
        `{"k": [1, "two", 3.0, true, null]}`, `[]`, `{}`, `"s"`, `0`,
        `-0.5e10`, `[{"a":{"b":[[]]}}]`, `{`, `}`, `[1 2]`, `nul`,
        `"unterminated`, `1e`, `--1`, `[,]`, `18446744073709551615`,
    ];
    foreach (c; cases)
        assert(isValidJson(c) == parseJsonDocument(c).hasValue);
}
