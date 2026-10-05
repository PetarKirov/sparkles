/**
Owned Unicode 18 extended-grapheme scanning and terminal-cell measurement.

Segmentation retains finite UAX #29 state and at most one decoded lookahead;
clusters have no scalar-count limit and their text remains borrowed. Malformed
UTF-8 follows the explicit owned maximal-subpart replacement policy.
*/
module sparkles.base.text.grapheme;


import sparkles.base.text.ansi : escapeLength;
import sparkles.base.text.width : ClusterWidthState;
import sparkles.base.text.utf8 : decodeValidated;
import sparkles.base.text.utf : UtfMode, UtfStatus, UtfResult, UtfToken,
    UtfTokenKind, UtfStream, UtfStreamPhase, decodeToken, decodeStreamToken, utfStorageOverlaps;
import sparkles.base.text.unicode_tables : GraphemeBreakClass,
    IndicConjunctBreakClass, unicodeCoreProperties;

version (LDC)
    version (X86_64)
        version = graphemeSimdX86;

version (graphemeSimdX86)
{
    import core.cpuid : avx2;
    import sparkles.base.text.utf8_simd : validatedUtf8Prefix;
    import sparkles.base.text.simd_io : loadVector;
    import ldc.attributes : target;
    import ldc.gccbuiltins_x86 : __builtin_ia32_pmovmskb128,
        __builtin_ia32_pmovmskb256;
    import ldc.simd : greaterMask;
}

@safe pure nothrow @nogc:

/**
Finite-state Unicode 18 default extended-grapheme boundary detector.

`push` reports the boundary before its scalar, including the initial boundary.
The state never stores a cluster or imposes a limit on its length. Encoding
validation and source retention belong to the scanner feeding it.
*/
struct GraphemeBreakState
{
    private GraphemeBreakClass _previous;
    private bool _started;
    private bool _regionalOdd;
    private bool _pictographicExtend;
    private bool _pictographicZwj;
    private bool _linkerExtend;

    /// Discard all preceding context.
    void reset() scope @safe pure nothrow @nogc { this = GraphemeBreakState.init; }

    /** Exact bounded key for future break behavior under this Unicode manifest.
    Equal keys imply equal decisions for every identical following scalar stream.
    The key is below 8192; reset has key zero. It is not a cross-version encoding.
    */
    ulong identity() const @safe pure nothrow @nogc
        => cast(ulong) _previous | (cast(ulong) _started << 8)
            | (cast(ulong) _regionalOdd << 9)
            | (cast(ulong) _pictographicExtend << 10)
            | (cast(ulong) _pictographicZwj << 11)
            | (cast(ulong) _linkerExtend << 12);

    /** Restore an owned key without a state registry. Invalid keys do not mutate
    the receiver. Only internal consumers of the same manifest may restore keys.
    */
    package(sparkles) bool tryRestoreIdentity(ulong key) scope @safe pure nothrow @nogc
    {
        if (key >= 8192 || (key & 255) > cast(ulong) GraphemeBreakClass.max)
            return false;
        _previous = cast(GraphemeBreakClass)(key & 255);
        _started = (key & (1UL << 8)) != 0;
        _regionalOdd = (key & (1UL << 9)) != 0;
        _pictographicExtend = (key & (1UL << 10)) != 0;
        _pictographicZwj = (key & (1UL << 11)) != 0;
        _linkerExtend = (key & (1UL << 12)) != 0;
        return true;
    }

    /// Consume one Unicode scalar and report whether it starts a cluster.
    bool push(dchar scalar) scope @safe pure nothrow @nogc
    in (scalar <= 0x10FFFF && (scalar < 0xD800 || scalar > 0xDFFF),
        "Grapheme state requires a Unicode scalar")
    {
        alias G = GraphemeBreakClass;
        alias I = IndicConjunctBreakClass;
        const properties = unicodeCoreProperties(scalar);
        const current = properties.grapheme;
        const indic = properties.indic;
        const pictographic = properties.extendedPictographic;
        bool boundary = true;
        if (_started)
        {
            if (_previous == G.cr && current == G.lf)
                boundary = false; // GB3
            else if (_previous == G.control || _previous == G.cr || _previous == G.lf
                || current == G.control || current == G.cr || current == G.lf)
                boundary = true; // GB4–GB5
            else if (_previous == G.l && (current == G.l || current == G.v
                || current == G.lv || current == G.lvt))
                boundary = false; // GB6
            else if ((_previous == G.lv || _previous == G.v)
                && (current == G.v || current == G.t))
                boundary = false; // GB7
            else if ((_previous == G.lvt || _previous == G.t) && current == G.t)
                boundary = false; // GB8
            else if (current == G.extend || current == G.zwj
                || current == G.spacingMark || _previous == G.prepend)
                boundary = false; // GB9–GB9b
            else if (_linkerExtend && indic == I.consonant)
                boundary = false; // Unicode 18 GB9c
            else if (_pictographicZwj && pictographic)
                boundary = false; // GB11
            else if (_previous == G.regionalIndicator && current == G.regionalIndicator
                && _regionalOdd)
                boundary = false; // GB12–GB13
        }

        _regionalOdd = current == G.regionalIndicator && !_regionalOdd;
        _pictographicZwj = current == G.zwj && _pictographicExtend;
        _pictographicExtend = pictographic || (current == G.extend && _pictographicExtend);
        _linkerExtend = indic == I.linker || (indic == I.extend && _linkerExtend);
        _previous = current;
        _started = true;
        return boundary;
    }
}

/// Default boundaries include CRLF, Hangul, emoji, RI parity, and Unicode 18 GB9c.
@("grapheme.ownedState.defaultBoundaries")
@safe pure nothrow @nogc
unittest
{
    size_t clusters(scope const(dchar)[] scalars) @safe pure nothrow @nogc
    {
        GraphemeBreakState state;
        size_t count;
        foreach (scalar; scalars)
            count += state.push(scalar);
        return count;
    }
    assert(clusters("\r\n"d) == 1);
    assert(clusters("\r\u0301"d) == 2);
    assert(clusters("\u1100\u1161\u11A8"d) == 1);
    assert(clusters("\u0600A\u0301"d) == 1);
    assert(clusters("\u0915\u093E"d) == 1);
    assert(clusters("\u094D\u0301\u0915"d) == 1);
    assert(clusters("\u094D A\u0915"d) == 4);
    assert(clusters("\U0001F469\u0301\u200D\U0001F4BB"d) == 1);
    assert(clusters("\U0001F469\u200D\u0301\U0001F4BB"d) == 2);
    assert(clusters("\U0001F1FA\U0001F1F8\U0001F1E6"d) == 2);
    assert(clusters("\U0001F1FA\u0301\U0001F1F8"d) == 2);
}

/// Absolute UTF-8 source span of one completed cluster. Opaque byte units
/// are hard barriers, explicitly distinguished from Unicode scalar clusters.
struct GraphemeSpan
{
    size_t start;
    size_t end;
    size_t scalars;
    bool opaque;
}

/**
Caller-owned streaming grapheme state. Events borrow no bytes; callers retain
source storage if they need to recover text spanning several chunks. A chunk end
is not a boundary. Event backpressure never consumes the token proving a boundary
that cannot be delivered.
*/
struct GraphemeStream
{
    private UtfStream!char _decoder;
    private GraphemeBreakState _breaks;
    private GraphemeSpan _cluster;
    private bool _haveCluster;
    private bool _previousOpaque;
    private bool _sourceEnded;
    private bool _finalIntent;
    private UtfStreamPhase _phase;
    private UtfResult _failure;

    /// Discard carry, context, pending events and offsets, selecting the mode.
    void reset(UtfMode mode = UtfMode.strict) scope @safe pure nothrow @nogc
    {
        this = GraphemeStream.init;
        _decoder.reset(mode);
    }

    /// Stream lifecycle and global source offset.
    UtfStreamPhase phase() const scope @safe pure nothrow @nogc => _phase;
    /// ditto
    size_t offset() const scope @safe pure nothrow @nogc => _decoder.offset;
    /// Whether accepted final intent still awaits a completed stream.
    bool pendingFinal() const scope @safe pure nothrow @nogc => _finalIntent;
    /// Structured failure retained until reset.
    UtfResult failure() const scope @safe pure nothrow @nogc => _failure;
    /// The bounded incomplete encoding suffix; invalidated by the next feed.
    const(char)[] carry() scope return const @safe pure nothrow @nogc => _decoder.carry;

    private bool boundary(UtfToken token) scope @safe pure nothrow @nogc
    {
        if (token.kind == UtfTokenKind.opaqueByte)
        {
            _breaks.reset();
            _previousOpaque = true;
            return true;
        }
        if (_previousOpaque)
            _breaks.reset();
        _previousOpaque = false;
        return _breaks.push(token.scalar);
    }

    private void begin(UtfToken token) scope @safe pure nothrow @nogc
    {
        _cluster = GraphemeSpan(start: token.start, end: token.end,
            scalars: token.kind == UtfTokenKind.opaqueByte ? 0 : 1,
            opaque: token.kind == UtfTokenKind.opaqueByte);
        _haveCluster = true;
    }
}

/**
Feed a UTF-8 chunk and emit completed cluster spans into caller storage.

`consumed` counts bytes accepted from this call, including encoding carry.
`written` counts delivered events. Final intent must remain true on retries.
Opaque mode is an address-preserving extension, not scalar UAX #29 conformance.
*/
UtfResult scanGraphemeStream(ref GraphemeStream state, scope const(char)[] source,
    scope GraphemeSpan[] destination, bool isFinal = false) @safe pure nothrow @nogc
{
    if (state._phase != UtfStreamPhase.active || (state._finalIntent && !isFinal)
        || (state._sourceEnded && source.length != 0))
        return UtfResult(status: UtfStatus.invalidState, offset: state.offset);
    if (utfStorageOverlaps(source, destination))
        return UtfResult(status: UtfStatus.overlap, offset: state.offset);

    size_t consumed;
    size_t written;
    while (true)
    {
        if (state._sourceEnded)
        {
            if (state._haveCluster)
            {
                if (written == destination.length)
                    return UtfResult(status: UtfStatus.outputFull, consumed: consumed,
                        written: written, offset: state._cluster.end, required: 1);
                destination[written++] = state._cluster;
                state._haveCluster = false;
            }
            state._phase = UtfStreamPhase.finalized;
            state._finalIntent = false;
            return UtfResult(status: UtfStatus.end, consumed: consumed,
                written: written, offset: state.offset);
        }

        // Rollback is needed only with no event capacity. Normal scans neither
        // copy decoder state per scalar nor decode lookahead twice.
        const checkpoint = state._haveCluster && written == destination.length;
        UtfStream!char decoderBefore;
        GraphemeBreakState breaksBefore;
        bool opaqueBefore;
        if (checkpoint)
        {
            decoderBefore = state._decoder;
            breaksBefore = state._breaks;
            opaqueBefore = state._previousOpaque;
        }
        UtfToken token = void;
        const decoded = decodeStreamToken(state._decoder, source[consumed .. $],
            token, isFinal);
        if (decoded.status != UtfStatus.invalidOptions && decoded.status != UtfStatus.overlap
            && decoded.status != UtfStatus.invalidState)
            state._finalIntent |= isFinal;
        if (decoded.written != 0)
        {
            const boundary = state.boundary(token);
            if (boundary && state._haveCluster)
            {
                if (written == destination.length)
                {
                    state._decoder = decoderBefore;
                    state._breaks = breaksBefore;
                    state._previousOpaque = opaqueBefore;
                    return UtfResult(status: UtfStatus.outputFull, consumed: consumed,
                        written: written, offset: state._cluster.end, required: 1);
                }
                destination[written++] = state._cluster;
                state.begin(token);
            }
            else if (!state._haveCluster)
                state.begin(token);
            else
            {
                state._cluster.end = token.end;
                ++state._cluster.scalars;
            }
            consumed += decoded.consumed;
            continue;
        }

        consumed += decoded.consumed;
        if (decoded.status == UtfStatus.end)
        {
            state._sourceEnded = true;
            continue;
        }
        UtfResult result = decoded;
        result.consumed = consumed;
        result.written = written;
        if (decoded.status == UtfStatus.invalid || decoded.status == UtfStatus.overflow)
        {
            state._phase = UtfStreamPhase.failed;
            state._failure = result;
        }
        return result;
    }
}

/// Every byte partition produces the same absolute spans, including carry.
@("grapheme.stream.everyBytePartition")
@safe pure nothrow @nogc
unittest
{
    enum text = "\r\nA\u0301\U0001F1FA\U0001F1F8\u094D\u0915";
    static immutable GraphemeSpan[3] expected = [
        GraphemeSpan(start: 0, end: 2, scalars: 2),
        GraphemeSpan(start: 2, end: 5, scalars: 2),
        GraphemeSpan(start: 5, end: 19, scalars: 4),
    ];
    foreach (split; 0 .. text.length + 1)
    {
        GraphemeStream state;
        GraphemeSpan[expected.length] events;
        const first = scanGraphemeStream(state, text[0 .. split], events[]);
        assert(first.status == UtfStatus.needInput && first.consumed == split);
        const last = scanGraphemeStream(state, text[split .. $],
            events[first.written .. $], true);
        assert(last.status == UtfStatus.end && last.consumed == text.length - split);
        assert(first.written + last.written == expected.length);
        assert(events[] == expected[]);
    }
}

@("grapheme.stream.boundaryBackpressureAndFinalIntent")
@safe pure nothrow @nogc
unittest
{
    GraphemeStream state;
    GraphemeSpan[1] events = [GraphemeSpan(start: 99, end: 100, scalars: 1)];
    const sentinel = events[0];
    const blocked = scanGraphemeStream(state, "A\u0301B", events[0 .. 0], true);
    assert(blocked.status == UtfStatus.outputFull && blocked.consumed == 3
        && blocked.written == 0 && blocked.offset == 3 && blocked.required == 1);
    assert(state.offset == 3 && state.pendingFinal && events[0] == sentinel);
    const retracted = scanGraphemeStream(state, "B", events[], false);
    assert(retracted.status == UtfStatus.invalidState && retracted.consumed == 0);
    assert(state.offset == 3 && events[0] == sentinel);
    const resumed = scanGraphemeStream(state, "B", events[], true);
    assert(resumed.status == UtfStatus.outputFull && resumed.consumed == 1
        && resumed.written == 1 && resumed.offset == 4);
    assert(events[0] == GraphemeSpan(start: 0, end: 3, scalars: 2));
    const ended = scanGraphemeStream(state, "", events[], true);
    assert(ended.status == UtfStatus.end && ended.written == 1);
    assert(events[0] == GraphemeSpan(start: 3, end: 4, scalars: 1));
    assert(state.phase == UtfStreamPhase.finalized && !state.pendingFinal);
    assert(scanGraphemeStream(state, "", events[], true).status == UtfStatus.invalidState);
}

@("grapheme.stream.opaqueBarriersAndFailureReset")
@safe pure nothrow @nogc
unittest
{
    GraphemeStream state;
    GraphemeSpan[3] events;
    const failed = scanGraphemeStream(state, "\xC0\u0301A", events[], true);
    assert(failed.status == UtfStatus.invalid && failed.consumed == 0 && failed.written == 0);
    assert(state.phase == UtfStreamPhase.failed && state.failure.offset == 0);
    assert(scanGraphemeStream(state, "", events[], true).status == UtfStatus.invalidState);
    state.reset(UtfMode.opaque);
    const opaque = scanGraphemeStream(state, "\xC0\u0301A", events[], true);
    assert(opaque.status == UtfStatus.end && opaque.written == 3);
    assert(events[0] == GraphemeSpan(start: 0, end: 1, opaque: true));
    assert(events[1] == GraphemeSpan(start: 1, end: 3, scalars: 1));
    assert(events[2] == GraphemeSpan(start: 3, end: 4, scalars: 1));
    state.reset(UtfMode.replacement);
    const replacement = scanGraphemeStream(state, "\xC0\u0301A", events[], true);
    assert(replacement.status == UtfStatus.end && replacement.written == 2);
    assert(events[0] == GraphemeSpan(start: 0, end: 3, scalars: 2));
    assert(events[1] == GraphemeSpan(start: 3, end: 4, scalars: 1));
}

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
    size_t unclustered;
    /// Exact number of Unicode scalars; no decoded-window cap.
    size_t codepoints;
    /// Replacement decoding occurred; raw slice bytes are not valid rendered UTF-8.
    bool hasMalformed;
}

private struct ClusterScan
{
    size_t bytes;
    int width;
    dchar first;
    size_t unclustered;
    size_t codepoints;
    bool hasMalformed;
}

// One lookahead token avoids decoding each boundary scalar twice. The validated
// byte count is an acceleration cache only, never a segmentation window.
private struct ClusterScanner
{
    private GraphemeBreakState _state;
    private dchar _pending;
    private size_t _pendingBytes;
    private size_t _validatedRemaining;
    private bool _pendingMalformed;

    void reset() scope @safe pure nothrow @nogc { this = ClusterScanner.init; }

    ClusterScan scan(bool fullMetadata = true)(scope const(char)[] run) scope
    in (run.length > 0)
    {
        pragma(inline, true);
        if (run[0] >= 0x20 && run[0] <= 0x7E
            && (run.length == 1 || run[1] < 0x80))
        {
            reset();
            return ClusterScan(1, 1, run[0], fullMetadata ? 1 : 0, 1);
        }

        ClusterWidthState measure;
        size_t position;
        bool hasMalformed;
        if (_pendingBytes != 0)
        {
            measure.push(_pending, fullMetadata);
            position = _pendingBytes;
            hasMalformed = _pendingMalformed;
            _pendingBytes = 0;
        }
        while (position < run.length)
        {
            const start = position;
            bool malformed;
            const scalar = next(run, position, malformed);
            const boundary = _state.push(scalar);
            if (boundary && measure.codepoints != 0)
            {
                _pending = scalar;
                _pendingBytes = position - start;
                _pendingMalformed = malformed;
                position = start;
                break;
            }
            measure.push(scalar, fullMetadata);
            hasMalformed |= malformed;
        }
        return ClusterScan(position, measure.width, measure.first,
            measure.unclustered, measure.codepoints, hasMalformed);
    }

    private dchar next(scope const(char)[] run, ref size_t position, ref bool malformed) scope
        @safe pure nothrow @nogc
    in (position < run.length)
    {
        version (graphemeSimdX86)
        {
            if (!__ctfe && _validatedRemaining == 0 && run.length - position >= 16)
            {
                const count = run.length - position < 256 ? run.length - position : 256;
                _validatedRemaining = validatedUtf8Prefix(run[position .. position + count]);
            }
        }
        const start = position;
        if (_validatedRemaining != 0)
        {
            const scalar = decodeValidated(run, position);
            _validatedRemaining -= position - start;
            return scalar;
        }
        const decoded = decodeToken(run[position .. $], UtfMode.replacement);
        position += decoded.result.consumed;
        malformed = decoded.token.kind == UtfTokenKind.replacement;
        return decoded.token.scalar;
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
            scan.unclustered, scan.codepoints, scan.hasMalformed);
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
            const bytes = loadVector!V(s, i + block * lanes);
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
        const bytes = loadVector!V(s, i);
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
    auto plain = printableAsciiPrefix(s);
    if (plain == s.length)
        return plain;
    return fitCellsMixed(s, size_t.max, plain).cells;
}

/// A whole-cluster prefix; byte and cell counts have deliberately distinct names.
struct CellFitResult
{
    size_t bytes;
    size_t cells;
    bool complete;
}

/**
Fit the longest source prefix under the terminalKitty revision-1 cell budget.
Replacement decoding is explicit; ANSI formatting runs have zero advance and
do not reset Unicode break or presentation state. Zero-width clusters fit even
at a zero-cell budget. This is not a cursor-motion/VT-screen interpreter.
*/
CellFitResult fitCells(scope const(char)[] source, size_t maximum)
    @safe pure nothrow @nogc
{
    const plain = printableAsciiPrefix(source);
    if (plain == source.length)
    {
        const count = source.length < maximum ? source.length : maximum;
        return CellFitResult(bytes: count, cells: count, complete: count == source.length);
    }
    return fitCellsMixed(source, maximum, plain);
}

private CellFitResult fitCellsMixed(scope const(char)[] source, size_t maximum, size_t plain)
    @safe pure nothrow @nogc
{
    // Every initial ASCII cluster except the last is already final. Formatting
    // can precede that last starter's combining/presentation continuation.
    const committed = plain ? plain - 1 : 0;
    if (committed > maximum)
        return CellFitResult(bytes: maximum, cells: maximum);
    CellFitResult result = CellFitResult(bytes: committed, cells: committed);
    size_t position = committed;
    GraphemeBreakState breaks;
    ClusterWidthState width;
    bool pending;
    while (position < source.length)
    {
        if (source[position] == '\x1b')
        {
            position += escapeLength(source[position .. $]);
            if (!pending)
                result.bytes = position;
            continue;
        }
        const start = position;
        const decoded = decodeToken(source[position .. $], UtfMode.replacement);
        assert(decoded.result.status == UtfStatus.ok && decoded.result.consumed != 0);
        position += decoded.result.consumed;
        if (breaks.push(decoded.token.scalar) && pending)
        {
            if (cast(size_t) width.width > maximum - result.cells)
                return result;
            result.cells += width.width;
            result.bytes = start;
            width = ClusterWidthState.init;
        }
        width.push(decoded.token.scalar, false);
        pending = true;
    }
    if (pending)
    {
        if (cast(size_t) width.width > maximum - result.cells)
            return result;
        result.cells += width.width;
    }
    result.bytes = source.length;
    result.complete = true;
    return result;
}

/// Styled controls do not split a logical cluster or its cell presentation.
@("grapheme.fitCells.styledWholeClustersAndZeroBudget")
@safe pure nothrow @nogc
unittest
{
    const keycap = "#\x1b[31m\uFE0F\u20E3";
    assert(visibleWidth(keycap) == 2);
    assert(fitCells(keycap, 1).bytes == 0);
    const flag = "\U0001F1FA\x1b[31m\U0001F1F8";
    assert(visibleWidth(flag) == 2 && fitCells(flag, 2).complete);
    const zero = fitCells("\u0301\t界", 0);
    assert(zero.bytes == 3 && zero.cells == 0 && !zero.complete);
    const wide = fitCells("e\u0301界x", 2);
    assert(wide.bytes == 3 && wide.cells == 1 && !wide.complete);
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


/// A long cluster remains one borrowed span, including its exact scalar count.
@("grapheme.ownedScanner.unboundedCombiningSpan")
@safe pure nothrow @nogc
unittest
{
    char[4099] text = void;
    text[0] = 'A';
    foreach (i; 0 .. 2048)
        text[1 + i * 2 .. 3 + i * 2] = "\u0301";
    text[4097 .. $] = "BC";
    auto clusters = text[].byGraphemeCluster;
    assert(clusters.front == ClusterMeasure(text[0 .. 4097], 1, false, 'A', 1, 2049));
    clusters.popFront();
    assert(clusters.front == ClusterMeasure(text[4097 .. 4098], 1, false, 'B', 1, 1));
    clusters.popFront();
    assert(clusters.front == ClusterMeasure(text[4098 .. $], 1, false, 'C', 1, 1));
    clusters.popFront();
    assert(clusters.empty);
    assert(visibleWidth(text[]) == 3);
}

@("grapheme.ownedScanner.longEmojiContext")
@safe pure nothrow @nogc
unittest
{
    char[2060] text = void;
    text[0 .. 4] = "\U0001F469";
    foreach (i; 0 .. 1024)
        text[4 + i * 2 .. 6 + i * 2] = "\u0301";
    text[2052 .. $] = "\u200D\U0001F4BBx";
    auto clusters = text[].byGraphemeCluster;
    assert(clusters.front == ClusterMeasure(text[0 .. 2059], 2, false,
        '\U0001F469', 4, 1027));
    clusters.popFront();
    assert(clusters.front.slice == "x" && clusters.front.width == 1);
    clusters.popFront();
    assert(clusters.empty);
    assert(visibleWidth(text[]) == 3);
}

@("grapheme.ownedScanner.riParityAcrossClusters")
@safe pure nothrow @nogc
unittest
{
    char[516] text = void;
    foreach (i; 0 .. 129)
        text[i * 4 .. (i + 1) * 4] = "\U0001F1E6";
    auto clusters = text[].byGraphemeCluster;
    foreach (i; 0 .. 64)
    {
        assert(clusters.front.slice == text[i * 8 .. (i + 1) * 8]);
        assert(clusters.front.width == 2 && clusters.front.codepoints == 2);
        clusters.popFront();
    }
    assert(clusters.front.slice == text[512 .. $]);
    assert(clusters.front.width == 2 && clusters.front.codepoints == 1);
    clusters.popFront();
    assert(clusters.empty);
    assert(visibleWidth(text[]) == 130);
}
