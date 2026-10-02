/**
 * Grapheme-cluster iteration over ANSI-styled UTF-8 text, and the visible width
 * of such text.
 *
 * `byGraphemeCluster` walks a byte stream as alternating escape sequences and
 * UAX #29 grapheme clusters, reporting each cluster's byte slice and display
 * width. `visibleWidth` sums those widths -- the @nogc replacement for the old
 * regex-based `unstyledLength`, correct for CJK (wide), combining marks (zero),
 * emoji and flags (one 2-cell cluster).
 *
 * The @nogc linchpin: grapheme segmentation runs on a reusable decoded `dchar`
 * window via `std.uni.graphemeStride` (which infers `@nogc nothrow` for
 * `dchar[]`). Successive cluster scans reuse decoded code points rather than
 * rebuilding the window.
 * UTF-8 uses `Yes.useReplacementDchar`, preserving Phobos's malformed-byte
 * consumption and yielding U+FFFD instead of throwing.
 */
module sparkles.base.text.grapheme;

import std.typecons : Yes;
import std.uni : graphemeStride;
import std.utf : decode;

import sparkles.base.text.ansi : escapeLength;
import sparkles.base.text.width : codepointTraits, singletonBreak,
    graphemeClusterWidth, unclusteredWidth;
import sparkles.base.text.utf8 : decodeReplacement, decodeValidated;

version (LDC)
    version (X86_64)
        version = graphemeSimdX86;

version (graphemeSimdX86)
{
    import core.cpuid : avx2;
    import sparkles.base.text.utf8_simd : validatedUtf8Prefix;
    import ldc.attributes : target;
    import ldc.gccbuiltins_x86 : __builtin_ia32_pmovmskb128,
        __builtin_ia32_pmovmskb256;
    import ldc.simd : greaterMask, loadUnaligned;
}

@safe pure nothrow @nogc:

/// Largest grapheme cluster (in code points) the scanner will coalesce. Real
/// clusters are far shorter; the cap only bounds pathological combining/ZWJ runs.
private enum size_t maxClusterCps = 32;

/// One unit from `byGraphemeCluster`: a single escape sequence, or one grapheme
/// cluster of visible text.
struct ClusterMeasure
{
    const(char)[] slice; /// The unit's bytes (a slice of the input).
    int width;           /// Display columns (0 for escapes and zero-width clusters).
    bool isEscape;       /// True for an escape sequence, false for a text cluster.
    dchar first;         /// First code point of a text cluster (for break classing).
    /// The cells a terminal that does not cluster advances for it: `width`
    /// where it keeps its cell (see $(REF unclusteredWidth,
    /// sparkles,base,text,width)).
    int unclustered;
    /// Code points in the cluster (capped at the scanner's window).
    ubyte codepoints;
}

private struct ClusterScan
{
    size_t bytes;
    int width;
    dchar first;
    int unclustered;
    ubyte codepoints;
}

// A bounded decoded queue shared by successive clusters of one escape-free
// run. Keep two cap-sized windows so compaction happens at most once per
// window, not once per cluster. Offsets stay relative to the original run:
// consuming a cluster does not rewrite all the queued byte offsets.
private struct ClusterScanner
{
    dchar[maxClusterCps * 2] window = void;
    size_t[maxClusterCps * 2] ends = void;
    size_t begin;
    size_t end;
    size_t decodedBytes;
    size_t consumedBytes;
    bool aggregateSingletons = true;

    void reset() scope @safe pure nothrow @nogc
    {
        begin = end = decodedBytes = consumedBytes = 0;
        aggregateSingletons = true;
    }

    void skipBytes(size_t bytes) scope @safe pure nothrow @nogc
    {
        consumedBytes += bytes;
        while (begin < end && ends[begin] <= consumedBytes)
            ++begin;
        if (decodedBytes < consumedBytes)
            decodedBytes = consumedBytes;
    }

    ClusterScan scan(bool fullMetadata = true)(scope const(char)[] run) scope
    in (run.length > 0)
    {
        pragma(inline, true);
        // Plain ASCII boundaries need no segmentation, even when an earlier
        // Unicode cluster has already decoded this byte into the queue.
        if (run[0] >= 0x20 && run[0] <= 0x7E
            && (run.length == 1 || run[1] < 0x80))
        {
            if (begin == end)
                ++decodedBytes;
            else
                ++begin;
            ++consumedBytes;
            return ClusterScan(1, 1, run[0], 1, 1);
        }

        if (end - begin < maxClusterCps)
            refill(run);

        const available = end - begin;
        const count = available < maxClusterCps ? available : maxClusterCps;
        const first = window[begin];
        const traits = codepointTraits(first);
        if (count == 1 || singletonBreak(traits, codepointTraits(window[begin + 1]),
                window[begin + 1]))
        {
            const nextBytes = ends[begin++];
            const width = traits & 3;
            const unclustered = fullMetadata
                ? (first >= 0x1F1E6 && first <= 0x1F1FF ? 1 : width) : 0;
            const result = ClusterScan(nextBytes - consumedBytes, width,
                first, unclustered, 1);
            consumedBytes = nextBytes;
            return result;
        }
        return scanComplex!fullMetadata(count);
    }

    private void refill(scope const(char)[] run) scope @safe pure nothrow @nogc
    {
        if (begin != 0)
        {
            const remaining = end - begin;
            // The ranges may overlap: copy forwards, towards lower indices.
            foreach (i; 0 .. remaining)
            {
                window[i] = window[begin + i];
                ends[i] = ends[begin + i];
            }
            begin = 0;
            end = remaining;
        }
        const base = consumedBytes;
        size_t pos = decodedBytes - base;
        size_t filled = end;
        size_t validEnd = pos;
        version (graphemeSimdX86)
        {
            if (!__ctfe)
            {
                const bound = (window.length - filled) * 4;
                const bytes = run.length - pos < bound ? run.length - pos : bound;
                validEnd += validatedUtf8Prefix(run[pos .. pos + bytes]);
            }
        }
        while (pos < run.length && filled < window.length)
        {
            window[filled] = pos < validEnd
                ? decodeValidated(run, pos) : decodeReplacement(run, pos);
            ends[filled++] = base + pos;
        }
        end = filled;
        decodedBytes = base + pos;
        // Retry aggregation only when a refill discovers a promising head,
        // not after every cluster in a combining/ZWJ-heavy run.
        aggregateSingletons = end != 0 && (codepointTraits(window[0]) & 0xFC) == 64
            && (end == 1 || (codepointTraits(window[1]) & 0xFC) == 64);
    }

    private ClusterScan scanComplex(bool fullMetadata)(size_t count) scope
    {
        const cluster = window[begin .. begin + graphemeStride(window[begin .. begin + count], 0)];
        const nextBytes = ends[begin + cluster.length - 1];
        const result = ClusterScan(nextBytes - consumedBytes,
            graphemeClusterWidth(cluster), cluster[0],
            fullMetadata ? unclusteredWidth(cluster) : 0, cast(ubyte) cluster.length);
        begin += cluster.length;
        consumedBytes = nextBytes;
        return result;
    }
}

/// Lazy range over the escape sequences and grapheme clusters of `s`.
struct GraphemeClusterRange
{
    private const(char)[] _rest;
    private size_t _runLen; // bytes of the current escape-free text run remaining
    private ClusterMeasure _front;
    private bool _empty;
    private ClusterScanner _scanner;

    @safe pure nothrow @nogc:

    private this(return scope const(char)[] s)
    {
        _rest = s;
        popFront();
    }

    /// Range primitives.
    bool empty() const scope => _empty;

    /// ditto
    ClusterMeasure front() const return scope => _front;

    /// ditto
    void popFront() scope
    {
        if (_rest.length == 0)
        {
            _empty = true;
            _front = ClusterMeasure.init;
            return;
        }
        if (_runLen == 0)
        {
            if (_rest[0] == '\x1b')
            {
                const n = escapeLength(_rest);
                _front = ClusterMeasure(_rest[0 .. n], 0, true, '\x1b');
                _rest = _rest[n .. $];
                return;
            }
            // Start of a text run: measure it up to the next escape.
            _runLen = escapeFreePrefix(_rest);
            _scanner.reset();
        }
        const scan = _scanner.scan(_rest[0 .. _runLen]);
        _front = ClusterMeasure(_rest[0 .. scan.bytes], scan.width, false, scan.first,
            scan.unclustered, scan.codepoints);
        _rest = _rest[scan.bytes .. $];
        _runLen -= scan.bytes;
    }
}

private size_t escapeFreePrefix(scope const(char)[] s) @safe pure nothrow @nogc
{
    if (__ctfe)
    {
        foreach (i, c; s)
            if (c == '\x1b')
                return i;
        return s.length;
    }
    if (s.length == 0)
        return 0;
    import core.stdc.string : memchr;

    return (() @trusted {
        const found = cast(const(char)*) memchr(s.ptr, '\x1b', s.length);
        return found is null ? s.length : cast(size_t)(found - s.ptr);
    })();
}

/// Iterate `s` as escape sequences and grapheme clusters.
GraphemeClusterRange byGraphemeCluster(return scope const(char)[] s)
{
    return GraphemeClusterRange(s);
}

// Only byte classification is vectorized; segmentation stays with the public
// Phobos API and presentation with the existing width policy. AVX2 is selected
// only when CPU/OS support it; SSE2 is the x86-64 baseline.
version (graphemeSimdX86)
private size_t printableAsciiBlocks(size_t lanes)(scope const(char)[] s)
    @target(lanes == 32 ? "avx2" : "sse2") @safe pure nothrow @nogc
{
    alias V = __vector(ubyte[lanes]);
    alias S = __vector(byte[lanes]);
    size_t i;
    // Bias printable bytes into [-128,-34]. Everything else lies above -34,
    // including high bytes and controls: one signed comparison per vector.
    while (s.length - i >= lanes * 4)
    {
        S bad = 0;
        static foreach (block; 0 .. 4)
        {{
            const bytes = (() @trusted =>
                loadUnaligned!V(cast(const(ubyte)*) s.ptr + i + block * lanes))();
            bad |= greaterMask!S(cast(S) bytes + S(96), S(-34));
        }}
        static if (lanes == 32)
            const bits = __builtin_ia32_pmovmskb256(bad);
        else
            const bits = __builtin_ia32_pmovmskb128(bad);
        if (bits != 0)
            break;
        i += lanes * 4;
    }
    while (s.length - i >= lanes)
    {
        const bytes = (() @trusted => loadUnaligned!V(cast(const(ubyte)*) s.ptr + i))();
        const bad = greaterMask!S(cast(S) bytes + S(96), S(-34));
        static if (lanes == 32)
            const bits = __builtin_ia32_pmovmskb256(bad);
        else
            const bits = __builtin_ia32_pmovmskb128(bad);
        if (bits != 0)
            break;
        i += lanes;
    }
    return i;
}

private size_t printableAsciiPrefix(scope const(char)[] s)
{
    // Reject an exceptional head before paying for a vector call. CTFE and
    // non-LDC/non-x86 builds use the same bounded scalar classification.
    if (s.length == 0 || s[0] < 0x20 || s[0] > 0x7E)
        return 0;
    size_t i;
    version (graphemeSimdX86)
    {
        if (!__ctfe && s.length >= 16)
            i = s.length >= 64 && avx2()
                ? printableAsciiBlocks!32(s) : printableAsciiBlocks!16(s);
    }
    while (i < s.length && s[i] >= 0x20 && s[i] <= 0x7E)
        ++i;
    return i;
}

version (graphemeSimdX86)
private size_t singletonWidthPrefix(scope const(char)[] run, ref size_t total)
{
    // Only ordinary singleton traits participate. Retain the final starter
    // until its following scalar is known: Extend/VS/ZWJ can still attach.
    const bytes = run.length < 256 ? run.length : 256;
    const validEnd = validatedUtf8Prefix(run[0 .. bytes]);
    size_t pos, accepted, width, pendingEnd, pendingWidth;
    while (pos < validEnd)
    {
        const cp = decodeValidated(run, pos);
        const traits = codepointTraits(cp);
        if ((traits & 0xFC) != 64)
            break;
        width += pendingWidth;
        accepted = pendingEnd;
        pendingEnd = pos;
        pendingWidth = traits & 3;
    }
    if (pos == run.length && pendingEnd == pos)
    {
        width += pendingWidth;
        accepted = pendingEnd;
    }
    total += width;
    return accepted;
}

/// Visible width of UTF-8 text in terminal cells: ANSI escapes count 0, each
/// grapheme cluster counts its display width (wide CJK 2, combining 0, emoji /
/// flags one 2-cell cluster). The @nogc replacement for `unstyledLength`.
size_t visibleWidth(in char[] s)
{
    auto plain = printableAsciiPrefix(s);
    if (plain == s.length)
        return plain;
    return visibleWidthMixed(s, plain);
}

private size_t visibleWidthMixed(in char[] s, size_t plain)
{
    // Keep the ASCII-only call free of scanner initialization and its frame.
    if (plain != 0 && s[plain] >= 0x80)
        --plain;
    size_t total = plain;
    size_t pos = plain;
    size_t runEnd;
    ClusterScanner scanner;
    scanner.skipBytes(plain);
    while (pos < s.length)
    {
        plain = printableAsciiPrefix(s[pos .. $]);
        // The last ASCII starter can acquire combining marks or a presentation
        // selector, including keycaps. Leave it and its continuation together.
        if (plain != 0 && plain < s.length - pos && s[pos + plain] >= 0x80)
            --plain;
        if (plain != 0)
        {
            total += plain;
            pos += plain;
            scanner.skipBytes(plain);
            continue;
        }
        if (s[pos] == '\x1b')
        {
            pos += escapeLength(s[pos .. $]);
            runEnd = 0;
            scanner.reset();
            continue;
        }
        // Cache the escape-free run end, as the iterator does. Unicode clusters
        // never rescan the full remaining run: discovery is once per text run.
        if (pos >= runEnd)
        {
            runEnd = pos + escapeFreePrefix(s[pos .. $]);
        }
        version (graphemeSimdX86)
        {
            if (!__ctfe && scanner.aggregateSingletons)
            {
                const bytes = singletonWidthPrefix(s[pos .. runEnd], total);
                if (bytes != 0)
                {
                    pos += bytes;
                    scanner.skipBytes(bytes);
                    continue;
                }
                scanner.aggregateSingletons = false;
            }
        }
        const scan = scanner.scan!false(s[pos .. runEnd]);
        total += scan.width;
        pos += scan.bytes;
    }
    return total;
}

@("grapheme.visibleWidth.plainAndStyled")
unittest
{
    assert(visibleWidth("hello") == 5);
    assert(visibleWidth("") == 0);
    assert(visibleWidth("\x1b[1mhi\x1b[0m") == 2);          // SGR ignored
    assert(visibleWidth("\x1b]8;;http://x\x07Click\x1b]8;;\x07") == 5); // OSC 8
}

@("grapheme.visibleWidth.unicode")
unittest
{
    assert(visibleWidth("\u4E16\u754C") == 4);   // CJK 'shijie' = 2 wide cells x2
    assert(visibleWidth("A\u0301bc") == 3);          // combining acute is zero-width
    assert(visibleWidth("\U0001F1FA\U0001F1F8") == 2); // US flag: one 2-cell cluster
    assert(visibleWidth("\u0903") == 0);             // Devanagari spacing mark (Mc -> 0)
    assert(visibleWidth("\u0915\u093e") == 1);       // \u0915 + \u093e : base + Mc = one cell
}

@("grapheme.byGraphemeCluster.slicesAndKinds")
unittest
{
    auto r = "a\x1b[31m\u4E16".byGraphemeCluster;
    assert(r.front == ClusterMeasure("a", 1, false, 'a', 1, 1));
    r.popFront;
    assert(r.front.isEscape && r.front.slice == "\x1b[31m" && r.front.width == 0);
    r.popFront;
    assert(!r.front.isEscape && r.front.width == 2 && r.front.first == '\u4E16');
    r.popFront;
    assert(r.empty);
}

@("grapheme.byGraphemeCluster.unclustered")
unittest
{
    // A ZWJ family is one cluster of 2 cells, and 6 where the terminal lays
    // it out code point by code point; a combining mark changes neither.
    auto r = "\U0001F468\u200D\U0001F469\u200D\U0001F467e\u0301".byGraphemeCluster;
    assert(r.front.width == 2 && r.front.unclustered == 6 && r.front.codepoints == 5);
    r.popFront;
    assert(r.front.width == 1 && r.front.unclustered == 1 && r.front.codepoints == 2);
}

@("grapheme.asciiBoundary.presentationAndMetadata")
unittest
{
    enum suffixes = ["A\u0301", "A\uFE0F", "#\uFE0F\u20E3",
        "*\uFE0F\u20E3", "7\uFE0F\u20E3", "3\u20E3"];
    static immutable int[6] widths = [1, 1, 2, 2, 2, 1];
    static immutable int[6] counts = [2, 2, 3, 3, 3, 2];
    char[160] storage = void;
    // Both aligned and unaligned slices, every short tail, and starters on
    // either side of the sixteen-byte SIMD boundary.
    foreach (alignment; 0 .. 16)
    {
        foreach (prefix; 0 .. 65)
        {
            foreach (index, suffix; suffixes)
            {
                const end = alignment + prefix + suffix.length;
                storage[alignment .. alignment + prefix] = 'x';
                storage[alignment + prefix .. end] = suffix[];
                const text = storage[alignment .. end];
                assert(visibleWidth(text) == prefix + widths[index]);
                auto clusters = byGraphemeCluster(text);
                foreach (_; 0 .. prefix)
                {
                    assert(clusters.front == ClusterMeasure("x", 1, false, 'x', 1, 1));
                    clusters.popFront();
                }
                assert(clusters.front == ClusterMeasure(suffix, widths[index],
                    false, suffix[0], 1, cast(ubyte) counts[index]));
                clusters.popFront();
                assert(clusters.empty);
            }
        }
    }
    static assert(visibleWidth("xxxxxxxxxxxxxxxx#\uFE0F\u20E3") == 18);
    static assert(visibleWidth("xxxxxxxxxxxxxxxA\u0301") == 16);
}

@("grapheme.asciiBoundary.escapesAndControls")
unittest
{
    enum prefix = "xxxxxxxxxxxxxxxx";
    assert(visibleWidth(prefix ~ "\x1b[31mA\u0301\x1b[0m") == 17);
    assert(visibleWidth(prefix ~ "#\x1b[31m\uFE0F\u20E3") == 17);
    assert(visibleWidth(prefix ~ "\x1b]8;;https://x\x07hi\x1b]8;;\x07") == 18);
    assert(visibleWidth(prefix ~ "\x1b]unfinished") == 16);
    assert(visibleWidth(prefix ~ "\r\n\t\0\x7FY") == 17);

    auto clusters = (prefix ~ "\r\n\t\x1b[31mY").byGraphemeCluster;
    foreach (_; 0 .. prefix.length)
        clusters.popFront();
    assert(clusters.front == ClusterMeasure("\r\n", 0, false, '\r', 0, 2));
    clusters.popFront();
    assert(clusters.front == ClusterMeasure("\t", 0, false, '\t', 0, 1));
    clusters.popFront();
    assert(clusters.front.isEscape && clusters.front.slice == "\x1b[31m");
    clusters.popFront();
    assert(clusters.front == ClusterMeasure("Y", 1, false, 'Y', 1, 1));
    clusters.popFront();
    assert(clusters.empty);
}

@("grapheme.scanCluster.capBoundedWindow")
unittest
{
    char[67] text;
    text[0] = 'A';
    foreach (i; 0 .. 33)
        text[1 + i * 2 .. 3 + i * 2] = "\u0301";
    auto clusters = text[].byGraphemeCluster;
    assert(clusters.front == ClusterMeasure(text[0 .. 63], 1, false, 'A', 1, 32));
    clusters.popFront();
    assert(clusters.front == ClusterMeasure(text[63 .. $], 0, false, '\u0301', 0, 2));
    clusters.popFront();
    assert(clusters.empty);
    assert(visibleWidth(text[]) == 1);
}

@("grapheme.visibleWidth.exceptionalBytesAcrossBulkBlocks")
unittest
{
    foreach (position; [0, 15, 16, 31, 32, 63, 64, 95, 127, 128, 129, 191, 255])
    {
        char[256] text = 'x';
        foreach (value; 0 .. 256)
        {
            text[position] = cast(char) value;
            size_t expected;
            foreach (cluster; byGraphemeCluster(text[]))
                expected += cluster.width;
            assert(visibleWidth(text[]) == expected);
        }
    }
}

version (unittest)
private ClusterScan referenceScan(scope const(char)[] run)
{
    // The original growing-window algorithm is deliberately test-only. It
    // checks queue boundaries against Phobos independently of the new scanner.
    dchar[maxClusterCps] window = void;
    size_t[maxClusterCps] ends = void;
    size_t count;
    size_t pos;
    while (pos < run.length && count < maxClusterCps)
    {
        window[count] = decode!(Yes.useReplacementDchar)(run, pos);
        ends[count++] = pos;
        const stride = graphemeStride(window[0 .. count], 0);
        if (stride < count)
            return ClusterScan(ends[stride - 1],
                graphemeClusterWidth(window[0 .. stride]), window[0],
                unclusteredWidth(window[0 .. stride]), cast(ubyte) stride);
    }
    const stride = graphemeStride(window[0 .. count], 0);
    return ClusterScan(ends[stride - 1], graphemeClusterWidth(window[0 .. stride]),
        window[0], unclusteredWidth(window[0 .. stride]), cast(ubyte) stride);
}

version (unittest)
private void checkReference(scope const(char)[] text)
{
    const original = text;
    auto actual = byGraphemeCluster(text);
    size_t total;
    while (text.length != 0)
    {
        if (text[0] == '\x1b')
        {
            const bytes = escapeLength(text);
            assert(actual.front == ClusterMeasure(text[0 .. bytes], 0, true, '\x1b'));
            text = text[bytes .. $];
        }
        else
        {
            size_t runEnd;
            while (runEnd < text.length && text[runEnd] != '\x1b')
                ++runEnd;
            const expected = referenceScan(text[0 .. runEnd]);
            assert(actual.front == ClusterMeasure(text[0 .. expected.bytes], expected.width,
                false, expected.first, expected.unclustered, expected.codepoints));
            total += expected.width;
            text = text[expected.bytes .. $];
        }
        actual.popFront();
    }
    assert(actual.empty);
    // The width-only loop skips ASCII separately and must share the same
    // semantics even when a decoded window straddles that skip.
    assert(visibleWidth(original) == total);
}

@("grapheme.decodedQueue.phobosStateAndMetadata")
unittest
{
    import std.utf : encode;
    static immutable dchar[] representatives = [
        'A', '\0', '\r', '\n', '\t', '\x7F', '\u0085', '\u0301',
        '\u0903', '\u093E', '\u0600', '\u0D4E', '\u1100', '\u1161',
        '\u11A8', '\uAC00', '\uAC01', '\uA960', '\uD7B0', '\uD7CB',
        '\u200B', '\u200D', '\u2028', '\uFE0E', '\uFE0F', '\u20E3',
        '\u2701', '\u2764', '\u4E16', '\U00020000', '\U0001F1E6',
        '\U0001F1E7', '\U0001F1E8', '\U0001F469', '\U0001F467',
        '\U0001F3FE', '\U000110BD', '\U000E0020', '\U000E007F', '\uFFFD'
    ];
    char[2048] storage = void;
    uint seed = 0xCAFE0123;
    foreach (trial; 0 .. 64)
    {
        size_t bytes;
        foreach (i; 0 .. 192)
        {
            seed = seed * 1664525U + 1013904223U;
            const cp = representatives[(seed >> 16) % representatives.length];
            char[4] encoded = void;
            const n = encode!(Yes.useReplacementDchar)(encoded, cp);
            storage[bytes .. bytes + n] = encoded[0 .. n];
            bytes += n;
        }
        const text = storage[0 .. bytes];
        checkReference(text);
    }
    foreach (a; representatives)
        foreach (b; representatives)
            foreach (c; [cast(dchar) 'A', '\u0301', '\u200D', '\U0001F469'])
            {
                size_t bytes;
                foreach (cp; [a, b, c])
                {
                    char[4] encoded = void;
                    const n = encode!(Yes.useReplacementDchar)(encoded, cp);
                    storage[bytes .. bytes + n] = encoded[0 .. n];
                    bytes += n;
                }
                checkReference(storage[0 .. bytes]);
            }
}

@("grapheme.singletonRuns.deferTrailingAttachments")
@safe pure nothrow @nogc
unittest
{
    char[512] storage = void;
    foreach (starter; ["A", "\u00E9", "\u4E16", "\U0001F469"])
        foreach (count; 0 .. 97)
        {
            const prefixBytes = count * starter.length;
            foreach (i; 0 .. count)
                storage[i * starter.length .. (i + 1) * starter.length] = starter[];
            foreach (suffix; ["\u0301", "\uFE0F", "\uFE0E",
                "\u200D\U0001F469", "\u0600A", "\r\n",
                "\U0001F1E6\U0001F1E7", "\xFF\u0301"])
            {
                storage[prefixBytes .. prefixBytes + suffix.length] = suffix[];
                checkReference(storage[0 .. prefixBytes + suffix.length]);
            }
        }
}

@("grapheme.decodedQueue.capMalformedAndEscapeTransitions")
unittest
{
    enum malformed = ["\x80", "\xC0\xAF", "\xE2\x82", "\xED\xA0\x80",
        "\xF0\x80\x80\xAF", "\xF4\x90\x80\x80", "\xE2A\x80", "\xFF\xFF"];
    foreach (bad; malformed)
    {
        char[256] storage = void;
        size_t length;
        string[5] parts = ["\u0600A\u0301", bad, "\x1b[31m\u2764\uFE0F",
            bad, "\r\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\u0301"];
        foreach (part; parts)
        {
            storage[length .. length + part.length] = part[];
            length += part.length;
        }
        checkReference(storage[0 .. length]);
    }
    char[1024] text = void;
    size_t bytes;
    foreach (i; 0 .. 256)
    {
        text[bytes++] = 'A';
        foreach (_; 0 .. i % 40)
        {
            if (bytes + 2 > text.length)
                break;
            text[bytes .. bytes + 2] = "\u0301";
            bytes += 2;
        }
        if (bytes + 81 > text.length)
            break;
    }
    checkReference(text[0 .. bytes]);
    static assert(visibleWidth("\u0600\u2764\uFE0F\x1b[31mA\u0301\r\n") == 1);
}
