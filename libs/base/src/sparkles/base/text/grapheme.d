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

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.ansi : escapeLength;
import sparkles.base.text.width : graphemeClusterWidth;

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
}

private struct ClusterScan
{
    size_t bytes;
    int width;
    dchar first;
}

/// Scan the first grapheme cluster of `run` (which begins at a cluster boundary
/// and contains no escape). Decodes code points into a `dchar` window until
/// `graphemeStride` reports a boundary, mapping back to a byte length.
private ClusterScan scanCluster(in char[] run) @safe pure nothrow @nogc
in (run.length > 0)
{
    SmallBuffer!(dchar, maxClusterCps) win;
    SmallBuffer!(size_t, maxClusterCps) ends; // ends[i] = byte offset just past cp i
    size_t pos = 0;
    while (pos < run.length && win.length < maxClusterCps)
    {
        size_t idx = pos;
        dchar cp = decode!(Yes.useReplacementDchar)(run, idx);
        win ~= cp;
        ends ~= idx;
        pos = idx;
        if (win.length >= 2)
        {
            const stride = graphemeStride(win[], 0);
            if (stride < win.length) // boundary found before the lookahead end
                return ClusterScan(ends[stride - 1],
                    graphemeClusterWidth(win[0 .. stride]), win[0]);
        }
    }
    // Reached the run end (or the cap): the window is a single cluster.
    const stride = graphemeStride(win[], 0);
    const k = stride < win.length ? stride : win.length;
    return ClusterScan(ends[k - 1], graphemeClusterWidth(win[0 .. k]), win[0]);
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
        _front = ClusterMeasure(_rest[0 .. scan.bytes], scan.width, false, scan.first);
        _rest = _rest[scan.bytes .. $];
        _runLen -= scan.bytes;
    }
}

/// Iterate `s` as escape sequences and grapheme clusters.
GraphemeClusterRange byGraphemeCluster(return scope const(char)[] s)
{
    return GraphemeClusterRange(s);
}

/// Visible width of UTF-8 text in terminal cells: ANSI escapes count 0, each
/// grapheme cluster counts its display width (wide CJK 2, combining 0, emoji /
/// flags one 2-cell cluster). The @nogc replacement for `unstyledLength`.
size_t visibleWidth(in char[] s)
{
    size_t total = 0;
    foreach (c; s.byGraphemeCluster)
        total += c.width;
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
    assert(r.front == ClusterMeasure("a", 1, false, 'a'));
    r.popFront;
    assert(r.front.isEscape && r.front.slice == "\x1b[31m" && r.front.width == 0);
    r.popFront;
    assert(!r.front.isEscape && r.front.width == 2 && r.front.first == '\u4E16');
    r.popFront;
    assert(r.empty);
}
