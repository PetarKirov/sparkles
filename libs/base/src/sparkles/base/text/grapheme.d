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
 * The @nogc linchpin: grapheme segmentation runs on a decoded `dchar` window via
 * `std.uni.graphemeStride` (which infers `@nogc nothrow` for `dchar[]`). We never
 * segment raw `char[]` -- `byGrapheme`/`decodeGrapheme` decode through a throwing,
 * non-@nogc path. UTF-8 is decoded with `Yes.useReplacementDchar` so malformed
 * input yields U+FFFD instead of throwing.
 */
module sparkles.base.text.grapheme;

import std.typecons : Yes;
import std.uni : graphemeStride;
import std.utf : decode;

import sparkles.base.text.ansi : escapeLength;
import sparkles.base.text.width : graphemeClusterWidth, unclusteredWidth;

version (LDC)
    version (X86_64)
        version = graphemeSimdX86;

version (graphemeSimdX86)
{
    import core.cpuid : avx2;
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

/// Scan the first grapheme cluster of `run` (which begins at a cluster boundary
/// and contains no escape). Decodes code points into a `dchar` window until
/// `graphemeStride` reports a boundary, mapping back to a byte length.
private ClusterScan scanCluster(bool fullMetadata = true)(in char[] run)
in (run.length > 0)
{
    // Printable ASCII has a boundary before any following ASCII byte. Keep an
    // ASCII starter before a high byte for the normal combining/VS/keycap path.
    if (run[0] >= 0x20 && run[0] <= 0x7E
        && (run.length == 1 || run[1] < 0x80))
        return ClusterScan(1, 1, run[0], 1, 1);

    dchar[maxClusterCps] win = void;
    size_t[maxClusterCps] ends = void; // byte offset just past each decoded cp
    size_t count;
    size_t pos = 0;
    while (pos < run.length && count < maxClusterCps)
    {
        size_t idx = pos;
        dchar cp = decode!(Yes.useReplacementDchar)(run, idx);
        win[count] = cp;
        ends[count] = idx;
        ++count;
        pos = idx;
        if (count >= 2)
        {
            const stride = graphemeStride(win[0 .. count], 0);
            if (stride < count) // boundary found before the lookahead end
                return ClusterScan(ends[stride - 1],
                    graphemeClusterWidth(win[0 .. stride]), win[0],
                    fullMetadata ? unclusteredWidth(win[0 .. stride]) : 0, cast(ubyte) stride);
        }
    }
    // Reached the run end (or the cap): the window is a single cluster.
    const stride = graphemeStride(win[0 .. count], 0);
    const k = stride < count ? stride : count;
    return ClusterScan(ends[k - 1], graphemeClusterWidth(win[0 .. k]), win[0],
        fullMetadata ? unclusteredWidth(win[0 .. k]) : 0, cast(ubyte) k);
}

/// Lazy range over the escape sequences and grapheme clusters of `s`.
struct GraphemeClusterRange
{
    private const(char)[] _rest;
    private size_t _runLen; // bytes of the current escape-free text run remaining
    private ClusterMeasure _front;
    private bool _empty;

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
            size_t j = 0;
            while (j < _rest.length && _rest[j] != '\x1b')
                j++;
            _runLen = j;
        }
        const scan = scanCluster(_rest[0 .. _runLen]);
        _front = ClusterMeasure(_rest[0 .. scan.bytes], scan.width, false, scan.first,
            scan.unclustered, scan.codepoints);
        _rest = _rest[scan.bytes .. $];
        _runLen -= scan.bytes;
    }
}

/// Iterate `s` as escape sequences and grapheme clusters.
GraphemeClusterRange byGraphemeCluster(return scope const(char)[] s)
{
    return GraphemeClusterRange(s);
}

// Only byte classification is vectorized; segmentation and presentation stay
// with Phobos and the existing width policy. AVX2 is selected only when the
// CPU and OS support it; SSE2 is the x86-64 baseline.
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

/// Visible width of UTF-8 text in terminal cells: ANSI escapes count 0, each
/// grapheme cluster counts its display width (wide CJK 2, combining 0, emoji /
/// flags one 2-cell cluster). The @nogc replacement for `unstyledLength`.
size_t visibleWidth(in char[] s)
{
    size_t total = 0;
    size_t pos;
    size_t runEnd;
    while (pos < s.length)
    {
        auto plain = printableAsciiPrefix(s[pos .. $]);
        // The last ASCII starter can acquire combining marks or a presentation
        // selector, including keycaps. Leave it and its continuation together.
        if (plain != 0 && plain < s.length - pos && s[pos + plain] >= 0x80)
            --plain;
        if (plain != 0)
        {
            total += plain;
            pos += plain;
            continue;
        }
        if (s[pos] == '\x1b')
        {
            pos += escapeLength(s[pos .. $]);
            runEnd = 0;
            continue;
        }
        // Cache the escape-free run end, as the iterator does. Unicode clusters
        // never rescan the full remaining run: discovery is once per text run.
        if (pos >= runEnd)
        {
            runEnd = pos;
            while (runEnd < s.length && s[runEnd] != '\x1b')
                ++runEnd;
        }
        const scan = scanCluster!false(s[pos .. runEnd]);
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
