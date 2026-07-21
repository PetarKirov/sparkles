/**
 * Greedy, ANSI- and Unicode-aware text wrapping.
 *
 * `writeWrappedText` wraps UTF-8 text to a column width measured in terminal
 * cells (via `sparkles.base.text.grapheme`), so CJK, combining marks, emoji and
 * flags are sized correctly and a wide glyph never straddles the wrap column. It
 * breaks at a pragmatic subset of UAX #14 opportunities -- spaces, ZWSP, between
 * CJK ideographs, after a soft hyphen -- never at NBSP / word-joiner, and honours
 * mandatory breaks (newline, line/paragraph separator). Active SGR style and OSC
 * 8 hyperlinks are suspended before each wrap newline and re-emitted on the
 * continuation line, so styling never bleeds onto a border and links survive a
 * split.
 *
 * `writeWrappedText(ref Writer, text, opts)` is the primitive (writer-first, void,
 * attributes inferred); `wrapText` is a GC convenience returning a `string`.
 */
module sparkles.base.text.wrap;

import std.range.primitives : ElementType, isInputRange, put;
import std.traits : isSomeChar;
import std.uni : unicode;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.ansi : OscLinkState, SgrState, writeSgrReset;
import sparkles.base.text.grapheme : byGraphemeCluster, ClusterMeasure;

/// How runs of whitespace are treated.
enum WhitespaceMode
{
    preserve, /// Emit whitespace verbatim (default).
    collapse, /// Fold each run to a single space; trim per-line leading/trailing.
}

/// How much active terminal state is re-emitted across a wrap newline.
enum StyleContinuity
{
    none,       /// Copy escapes through; do not suspend/resume at breaks.
    sgrReset,   /// Reset SGR at line end and re-emit it on the next line.
    sgrAndLink, /// Also close and re-open the active OSC 8 hyperlink (default).
}

/// How a tab advances the column.
enum TabPolicy
{
    passThrough, /// Emit '\t'; advance to the next tab stop.
    expand,      /// Emit spaces up to the next tab stop.
}

/// Options for `writeWrappedText` / `wrapText`.
struct WrapOptions
{
    size_t width = 0;                 /// Wrap width in cells; 0 = no wrapping.
    const(char)[] indent = null;      /// Indent on continuation lines.
    const(char)[] firstIndent = null; /// Indent on the first line.
    WhitespaceMode whitespace = WhitespaceMode.preserve;
    bool breakLongWords = true;       /// Hard-break a word wider than the line.
    StyleContinuity continuity = StyleContinuity.sgrAndLink;
    TabPolicy tabs = TabPolicy.passThrough;
    bool emitSoftHyphenGlyph = true;  /// Show '-' at a realized soft-hyphen break.
    size_t tabSize = 8;
    const(char)[] newline = "\n";
}

/// Break classes for the reduced UAX #14 classifier.
private enum BreakClass
{
    other,       /// Ordinary character.
    space,       /// Space or tab (breakable whitespace).
    zwsp,        /// Zero-width space (breakable, no glyph).
    mandatory,   /// Forces a line break (newline, Zl, Zp, ...).
    glue,        /// Must not break (NBSP, word joiner, ...).
    softHyphen,  /// Break opportunity that shows a hyphen when used.
    ideographic, /// CJK ideograph (break allowed on both sides).
}

private BreakClass classOf(dchar cp) @safe pure nothrow @nogc
{
    switch (cp)
    {
    case '\n': case '\r': case '\v': case '\f':
    case '\u0085': case '\u2028': case '\u2029': // NEL, line sep, paragraph sep
        return BreakClass.mandatory;
    case ' ': case '\t':
        return BreakClass.space;
    case '\u200B': // zero-width space
        return BreakClass.zwsp;
    case '\u00A0': case '\u202F': case '\u2060': case '\uFEFF': // NBSP, NNBSP, WJ, ZWNBSP
        return BreakClass.glue;
    case '\u00AD': // soft hyphen
        return BreakClass.softHyphen;
    default:
        return isIdeographic(cp) ? BreakClass.ideographic : BreakClass.other;
    }
}

/// Membership in `std.uni`'s Ideographic property (read via a `@trusted` wrapper
/// around the immutable global set).
private bool isIdeographic(dchar cp) @trusted pure nothrow @nogc
{
    static immutable ideographic = unicode.Ideographic;
    return ideographic[cp];
}

/// Snapshot of the active terminal state, used to re-emit across a wrap newline.
private struct StyleSnapshot
{
    SgrState sgr;
    OscLinkState link;
}

/// Greedy-wrap `text` to `opt.width` cells, writing into output range `w`.
///
/// Writer-first, `void`; attributes infer (do not force `@safe` on the template).
/// `text` is range-polymorphic (selected with `static if`): a `string`/`char[]`, a
/// range of `const(char)[]` chunks, or a range of `char`/`dchar`. A non-contiguous
/// range is gathered into a `SmallBuffer` first (so the engine still sees one
/// contiguous buffer); the chunks are treated as a single logical text (include any
/// `'\n'` separators yourself). The contiguous engine is `writeWrappedImpl`.
void writeWrappedText(Writer, Text)(ref Writer w, Text text, in WrapOptions opt = WrapOptions.init)
{
    static if (is(Text : const(char)[]))
        writeWrappedImpl(w, text, opt);
    else static if (isInputRange!Text && is(ElementType!Text : const(char)[]))
    {
        SmallBuffer!(char, 256) buf;
        foreach (chunk; text)
            buf.put(chunk);
        writeWrappedImpl(w, buf[], opt);
    }
    else static if (isInputRange!Text && isSomeChar!(ElementType!Text))
    {
        import std.utf : encode;

        SmallBuffer!(char, 256) buf;
        foreach (c; text)
        {
            static if (is(typeof(c) : char))
                buf.put(c);
            else
            {
                char[4] enc;
                buf.put(enc[0 .. encode(enc, c)]);
            }
        }
        writeWrappedImpl(w, buf[], opt);
    }
    else
        static assert(false,
            "writeWrappedText: text must be a string, a range of strings, or a range of chars");
}

/// The contiguous greedy-wrap engine; see `writeWrappedText` for the public,
/// range-polymorphic entry point.
private void writeWrappedImpl(Writer)(ref Writer w, in char[] text, in WrapOptions opt)
{
    if (opt.width == 0)
    {
        put(w, text);
        return;
    }

    const size_t width = opt.width;
    const size_t indentW = columnWidth(opt.indent, opt.tabSize);

    // Active style up to the scan point, and a snapshot at the start of the
    // pending word (what a continuation line restores when breaking before it).
    StyleSnapshot live;
    StyleSnapshot atWordStart;

    size_t col = columnWidth(opt.firstIndent, opt.tabSize);
    bool lineHasContent = false;
    put(w, opt.firstIndent);

    // Pending word and the gap (whitespace) before it, as offsets into `text`.
    size_t wordStart, wordEnd, wordW;
    bool haveWord;
    size_t gapStart, gapEnd, gapW;
    bool haveGap;
    bool softHyphenPending; // a soft-hyphen break sits before the pending word

    size_t off = 0;

    void emitBreak(StyleSnapshot snap)
    {
        if (opt.continuity != StyleContinuity.none)
        {
            if (opt.continuity == StyleContinuity.sgrAndLink)
                snap.link.writeClose(w);
            if (snap.sgr.active)
                writeSgrReset(w);
        }
        put(w, opt.newline);
        put(w, opt.indent);
        col = indentW;
        lineHasContent = false;
        if (opt.continuity != StyleContinuity.none)
        {
            snap.sgr.emit(w);
            if (opt.continuity == StyleContinuity.sgrAndLink)
                snap.link.reopen(w);
        }
    }

    // Emit a word slice, hard-breaking inside it (cluster by cluster) when it
    // cannot fit and `breakLongWords` is set. `start` is the style at its first byte.
    void placeWord(scope const(char)[] word, size_t wW, StyleSnapshot start)
    {
        const size_t avail = width > col ? width - col : 0;
        if (!opt.breakLongWords || wW <= avail)
        {
            put(w, word);
            col += wW;
            if (wW)
                lineHasContent = true;
            return;
        }
        StyleSnapshot s = start;
        foreach (cc; word.byGraphemeCluster)
        {
            if (cc.isEscape)
            {
                put(w, cc.slice);
                s.sgr.apply(cc.slice);
                s.link.apply(cc.slice);
                continue;
            }
            if (lineHasContent && col + cc.width > width)
                emitBreak(s);
            put(w, cc.slice);
            col += cc.width;
            if (cc.width)
                lineHasContent = true;
        }
    }

    void flushWord()
    {
        if (!haveWord)
            return;
        const word = text[wordStart .. wordEnd];
        const gap = haveGap ? text[gapStart .. gapEnd] : null;

        const bool emitGap = opt.whitespace == WhitespaceMode.preserve
            ? (gap.length != 0)
            : (lineHasContent && gap.length != 0);
        const size_t effGapW = emitGap ? gapW : 0;

        if (lineHasContent && col + effGapW + wordW > width)
        {
            // Break before the word; a preserved trailing gap stays on this line.
            if (opt.whitespace == WhitespaceMode.preserve && gap.length)
            {
                put(w, gap);
                col += gapW;
            }
            if (softHyphenPending && opt.emitSoftHyphenGlyph)
                put(w, "-");
            emitBreak(atWordStart);
            placeWord(word, wordW, atWordStart);
        }
        else
        {
            if (emitGap)
            {
                put(w, gap);
                col += effGapW;
            }
            placeWord(word, wordW, atWordStart);
        }

        haveWord = false;
        wordW = 0;
        haveGap = false;
        gapW = 0;
        softHyphenPending = false;
    }

    void startWord(size_t start)
    {
        if (!haveWord)
        {
            atWordStart = live;
            haveWord = true;
            wordStart = start;
            wordW = 0;
        }
        wordEnd = off;
    }

    foreach (c; text.byGraphemeCluster)
    {
        const size_t start = off;
        off += c.slice.length;

        if (c.isEscape)
        {
            startWord(start);   // escapes attach to the (next) word, zero width
            live.sgr.apply(c.slice);
            live.link.apply(c.slice);
            continue;
        }

        final switch (classOf(c.first))
        {
        case BreakClass.mandatory:
            flushWord();
            emitBreak(live);
            haveGap = false;
            gapW = 0;
            break;

        case BreakClass.space:
            flushWord();
            if (!haveGap)
            {
                haveGap = true;
                gapStart = start;
                gapW = 0;
            }
            gapEnd = off;
            gapW += c.slice.length == 1 && c.slice[0] == '\t'
                ? opt.tabSize - (col + gapW) % opt.tabSize
                : c.width;
            break;

        case BreakClass.zwsp:
            flushWord(); // break opportunity, no visible gap
            break;

        case BreakClass.softHyphen:
            flushWord();
            softHyphenPending = true;
            break;

        case BreakClass.glue:
        case BreakClass.other:
            startWord(start);
            wordW += c.width;
            break;

        case BreakClass.ideographic:
            flushWord();          // break allowed before the ideograph
            startWord(start);
            wordW = c.width;
            flushWord();          // and after it
            break;
        }
    }
    flushWord();
    if (opt.whitespace == WhitespaceMode.preserve && haveGap)
        put(w, text[gapStart .. gapEnd]);
}

/// Column width of `s` counting tabs to the next `tabSize` stop.
private size_t columnWidth(in char[] s, size_t tabSize) @safe pure nothrow @nogc
{
    size_t col = 0;
    foreach (cl; s.byGraphemeCluster)
    {
        if (!cl.isEscape && cl.slice.length == 1 && cl.slice[0] == '\t')
            col += tabSize - col % tabSize;
        else
            col += cl.width;
    }
    return col;
}

/// GC convenience: wrap `text` and return the result as a `string`.
string wrapText(in char[] text, in WrapOptions opt = WrapOptions.init) @safe
{
    import std.array : appender;

    auto a = appender!string;
    writeWrappedText(a, text, opt);
    return a[];
}

/// A lazy, `@nogc` forward range over the wrapped lines of some text. `front` is the
/// current wrapped line as `const(char)[]`; joining the lines with `"\n"` reproduces
/// `wrapText`, so callers can peek the first line (and whether any further lines
/// follow) without materialising a `string[]`. Construct it with $(LREF byWrappedLine).
///
/// The wrapped output is built once (via `writeWrappedText`) into an owned
/// copy-on-write `SmallBuffer`, so saving/copying the range shares that buffer.
/// `front` is **borrowed** — a slice into that buffer, valid only while this range
/// (or a copy sharing its buffer) is alive; to keep a line past then, `.idup` it
/// (the `File.byLine` contract). Line boundaries are walked lazily.
struct WrappedLines(size_t bufferSize = 256)
{
    private SmallBuffer!(char, bufferSize) _buf;
    private size_t _total, _start, _end;

    // Set the cursor on the first line after `_buf` has been filled.
    private void initCursor()
    {
        _total = _buf.length;
        _start = _total == 0 ? _total + 1 : 0; // empty input -> empty range
        if (_start <= _total)
            scanEnd();
    }

    // Extend `_end` to the next '\n' (the only line separator the engine emits) or
    // the buffer end.
    private void scanEnd()
    {
        const v = (cast(const) _buf)[];
        _end = _start;
        while (_end < _total && v[_end] != '\n')
            ++_end;
    }

    /// Range primitives (forward range).
    bool empty() const => _start > _total;

    /// ditto
    const(char)[] front() const
    in (!empty)
        => (cast(const) _buf)[][_start .. _end];

    /// ditto
    void popFront()
    in (!empty)
    {
        if (_end >= _total) // last line ran to the buffer end
            _start = _total + 1; // mark empty
        else
        {
            _start = _end + 1; // skip the '\n'
            if (_start >= _total) // a trailing '\n' adds no extra empty line
                _start = _total + 1;
            else
                scanEnd();
        }
    }

    /// ditto
    typeof(this) save() => this;
}

/// Build a $(LREF WrappedLines): the wrapped lines of `text` as a lazy `@nogc`
/// forward range of `const(char)[]`.
///
/// `text` is range-polymorphic via `writeWrappedText` — a `string`/`char[]`, a range
/// of `const(char)[]` chunks, or a range of `char`/`dchar` (chunks are one logical
/// text; include any `'\n'` separators yourself).
WrappedLines!bufferSize byWrappedLine(size_t bufferSize = 256, Text)(
    Text text, in WrapOptions opt = WrapOptions.init)
{
    WrappedLines!bufferSize r;
    writeWrappedText(r._buf, text, opt);
    r.initCursor();
    return r;
}

/// A lazy, `@nogc` forward range over the wrapped *chunks* of some text — the
/// cell-granular sibling of $(LREF WrappedLines). Each `front` is either exactly
/// `"\n"` (a line break) or a run of text known to fit the current line;
/// concatenating every chunk reproduces `wrapText`. The compile-time `lineBuffered`
/// flag picks the granularity:
///
/// $(LIST
///   * `true` — a chunk is a whole wrapped line, interleaved with `"\n"` chunks
///     (coarse; one chunk per row, like walking $(LREF WrappedLines)).
///   * `false` — a chunk is a sub-line run: any leading escapes and space(s) then a
///     run of visible non-space clusters, ending right before the next space or
///     newline (fine; a word / break-segment at a time, for cell-granular streaming).
/// )
///
/// A grapheme cluster or escape sequence is never split across chunks, and a chunk
/// that carries escapes always carries at least one visible cell — so no chunk is
/// escape-only and per-chunk pacing stays even.
///
/// Like $(LREF WrappedLines) the output is built once (via `writeWrappedText`) into
/// an owned copy-on-write `SmallBuffer`, so saving/copying the range shares that
/// buffer. `front` is **borrowed** — a slice into the buffer, valid only while this
/// range (or a copy) is alive; `.idup` it to keep a chunk past then (the
/// `File.byLine` contract). Construct it with $(LREF byWrappedChunk).
struct WrappedChunks(bool lineBuffered = true, size_t bufferSize = 256)
{
    import sparkles.base.text.grapheme : byGraphemeCluster;

    private SmallBuffer!(char, bufferSize) _buf;
    private size_t _total, _start, _end;

    // Set the cursor on the first chunk after `_buf` has been filled.
    private void initCursor()
    {
        _total = _buf.length;
        _start = _total == 0 ? _total + 1 : 0; // empty input -> empty range
        if (_start <= _total)
            scanEnd();
    }

    // Compute `_end`: one past the end of the chunk that starts at `_start`. Chunks
    // tile the buffer contiguously (newlines included), so `popFront` just hops to
    // `_end` — unlike `WrappedLines`, which skips the separating '\n'.
    private void scanEnd()
    {
        const v = (cast(const) _buf)[];

        // A newline is always its own chunk.
        if (v[_start] == '\n')
        {
            _end = _start + 1;
            return;
        }

        static if (lineBuffered)
        {
            // Run up to (not including) the next '\n'.
            _end = _start;
            while (_end < _total && v[_end] != '\n')
                ++_end;
        }
        else
        {
            // Leading escapes + space(s), then visible non-space clusters, ending
            // right before the next space/newline. Escapes never end a chunk (they
            // ride into the adjacent visible chunk); a bare space run before a '\n'
            // folds into that '\n' chunk so we never emit a space/escape-only chunk.
            bool sawVisible = false;
            size_t off = _start;
            foreach (c; v[_start .. _total].byGraphemeCluster)
            {
                if (!c.isEscape && c.slice.length == 1 && c.slice[0] == '\n')
                    break; // newline starts the next chunk
                if (c.isEscape)
                {
                    off += c.slice.length; // escapes ride along
                    continue;
                }
                if (c.slice.length == 1 && c.slice[0] == ' ')
                {
                    if (sawVisible)
                        break; // a space after content leads the next chunk
                    off += c.slice.length; // leading space accumulates
                    continue;
                }
                sawVisible = true;
                off += c.slice.length;
            }
            if (!sawVisible && off < _total && v[off] == '\n')
                off += 1; // fold a leading space/escape run into the following '\n'
            _end = off;
        }
    }

    /// Range primitives (forward range).
    bool empty() const => _start > _total;

    /// ditto
    const(char)[] front() const
    in (!empty)
        => (cast(const) _buf)[][_start .. _end];

    /// ditto
    void popFront()
    in (!empty)
    {
        if (_end >= _total) // consumed to the buffer end
            _start = _total + 1; // mark empty
        else
        {
            _start = _end; // chunks are contiguous; the next begins where this ended
            scanEnd();
        }
    }

    /// ditto
    typeof(this) save() => this;
}

/// Build a $(LREF WrappedChunks): the wrapped chunks of `text` as a lazy `@nogc`
/// forward range of `const(char)[]`.
///
/// `text` is range-polymorphic via `writeWrappedText` — a `string`/`char[]`, a range
/// of `const(char)[]` chunks, or a range of `char`/`dchar` (chunks are one logical
/// text; include any `'\n'` separators yourself). `lineBuffered` selects whole-line
/// vs sub-line granularity (see $(LREF WrappedChunks)).
WrappedChunks!(lineBuffered, bufferSize) byWrappedChunk(
    bool lineBuffered = true, size_t bufferSize = 256, Text)(
    Text text, in WrapOptions opt = WrapOptions.init)
{
    WrappedChunks!(lineBuffered, bufferSize) r;
    writeWrappedText(r._buf, text, opt);
    r.initCursor();
    return r;
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

@("wrap.basic.collapseAndPreserve")
@safe unittest
{
    assert(wrapText("the quick brown fox",
        WrapOptions(width: 9, whitespace: WhitespaceMode.collapse)) == "the quick\nbrown fox");
    // Preserve keeps the trailing space of the broken line.
    assert(wrapText("a b c", WrapOptions(width: 3)) == "a b \nc");
}

@("wrap.basic.exactFitAndEmpty")
@safe unittest
{
    assert(wrapText("ab cd", WrapOptions(width: 5)) == "ab cd"); // exactly 5 cells, no break
    assert(wrapText("", WrapOptions(width: 5)) == "");
    assert(wrapText("   ", WrapOptions(width: 5)) == "   ");      // whitespace-only preserved
    assert(wrapText("a b c d", WrapOptions(width: 0)) == "a b c d"); // width 0 = passthrough
}

@("wrap.indent.firstAndContinuation")
@safe unittest
{
    assert(wrapText("aa bb cc",
        WrapOptions(width: 5, indent: "  ", whitespace: WhitespaceMode.collapse)) == "aa bb\n  cc");
    assert(wrapText("aa bb",
        WrapOptions(width: 6, firstIndent: ">>", whitespace: WhitespaceMode.collapse)) == ">>aa\nbb");
}

@("wrap.breakClasses.nbspZwspSoftHyphen")
@safe unittest
{
    // NBSP glues the word together; the whole thing wraps as a unit.
    assert(wrapText("a\u00A0b c", WrapOptions(width: 3, whitespace: WhitespaceMode.collapse)) == "a\u00A0b\nc");
    // ZWSP is an invisible break opportunity.
    assert(wrapText("ab\u200Bcd", WrapOptions(width: 3, whitespace: WhitespaceMode.collapse)) == "ab\ncd");
    // Soft hyphen shows a '-' only when the break is realized.
    assert(wrapText("ab\u00ADcd", WrapOptions(width: 3, whitespace: WhitespaceMode.collapse)) == "ab-\ncd");
    assert(wrapText("ab\u00ADc", WrapOptions(width: 4, whitespace: WhitespaceMode.collapse)) == "abc");
}

@("wrap.cjk.breaksBetweenIdeographs")
@safe unittest
{
    assert(wrapText("世界世", WrapOptions(width: 4)) == "世界\n世");
}

@("wrap.wide.neverStraddles")
@safe unittest
{
    // Fullwidth letters are width 2 but not ideographic -> one long word that
    // hard-breaks; a 2-cell glyph never straddles a width-3 column.
    assert(wrapText("ＡＢＣ", WrapOptions(width: 3)) == "Ａ\nＢ\nＣ");
}

@("wrap.longWord.hardBreakAndOverflow")
@safe unittest
{
    assert(wrapText("abcdefg", WrapOptions(width: 3)) == "abc\ndef\ng");
    assert(wrapText("abcdefg", WrapOptions(width: 3, breakLongWords: false)) == "abcdefg");
    // A combining mark stays with its base across a hard break.
    assert(wrapText("aA\u0301bc", WrapOptions(width: 2)) == "aA\u0301\nbc");
}

@("wrap.tab.advancesToStop")
@safe unittest
{
    assert(wrapText("a\tb", WrapOptions(width: 20)) == "a\tb"); // fits; passthrough
}

@("wrap.style.sgrReEmittedAcrossBreak")
@safe unittest
{
    // Red "foo bar" wrapped at 3: each line reset at the end and re-colored at
    // the start, so color never bleeds onto the next line / a border.
    assert(wrapText("\x1b[31mfoo bar\x1b[0m",
        WrapOptions(width: 3, continuity: StyleContinuity.sgrReset, whitespace: WhitespaceMode.collapse))
        == "\x1b[31mfoo\x1b[0m\n\x1b[31mbar\x1b[0m");
}

@("wrap.style.oscLinkReopenedAcrossBreak")
@safe unittest
{
    // OSC 8 link split across a wrap: closed at line end, re-opened next line.
    assert(wrapText("\x1b]8;;http://x\x07ab cd\x1b]8;;\x07",
        WrapOptions(width: 2, continuity: StyleContinuity.sgrAndLink, whitespace: WhitespaceMode.collapse))
        == "\x1b]8;;http://x\x07ab\x1b]8;;\x07\n\x1b]8;;http://x\x07cd\x1b]8;;\x07");
}

@("wrap.writer.isNogc")
@safe pure nothrow @nogc unittest
{
    import sparkles.base.smallbuffer : checkWriter;

    checkWriter!((ref b) => writeWrappedText(b, "the quick brown",
        WrapOptions(width: 9, whitespace: WhitespaceMode.collapse)))("the quick\nbrown");
}

@("wrap.byWrappedLine.matchesWrapText")
@safe unittest
{
    import std.algorithm.comparison : equal;
    import std.string : lineSplitter;

    // The lazy line range yields exactly the lines `wrapText` produces, for plain,
    // long-word-hard-break, CJK, and styled inputs.
    static foreach (pair; [
        ["the quick brown fox", "9"],
        ["abcdefg", "3"],
        ["世界世", "4"],
    ])
    {{
        const opt = WrapOptions(width: pair[1] == "9" ? 9 : pair[1] == "4" ? 4 : 3,
            whitespace: WhitespaceMode.collapse);
        assert(pair[0].byWrappedLine(opt).equal(pair[0].wrapText(opt).lineSplitter));
    }}

    // Styled input: each line is reset/re-colored exactly as `wrapText` does.
    const styled = "\x1b[31mfoo bar\x1b[0m";
    const sopt = WrapOptions(width: 3, continuity: StyleContinuity.sgrReset,
        whitespace: WhitespaceMode.collapse);
    assert(styled.byWrappedLine(sopt).equal(styled.wrapText(sopt).lineSplitter));
}

@("wrap.byWrappedLine.isNogc")
@safe pure nothrow @nogc unittest
{
    // Walking the lazy range allocates nothing on the GC: the wrapped output lives
    // in the range's own (CoW, malloc-backed) buffer and `front` borrows from it.
    auto r = "the quick brown".byWrappedLine(
        WrapOptions(width: 9, whitespace: WhitespaceMode.collapse));
    assert(r.front == "the quick");
    r.popFront;
    assert(r.front == "brown");
    r.popFront;
    assert(r.empty);
}

@("wrap.byWrappedLine.peekFirstLine")
@safe unittest
{
    // The box's title rule: buffer the first line, then decide "did it wrap?" by
    // whether any further line follows — without materialising a string[].
    auto fits = "short".byWrappedLine(WrapOptions(width: 20));
    assert(fits.front == "short");
    fits.popFront;
    assert(fits.empty);            // one line -> title fits, no wrap

    auto wraps = "alpha beta gamma".byWrappedLine(
        WrapOptions(width: 7, whitespace: WhitespaceMode.collapse));
    assert(wraps.front == "alpha");
    wraps.popFront;
    assert(!wraps.empty);          // further lines -> title wrapped
}

@("wrap.byWrappedLine.rangeInputs")
@safe unittest
{
    import std.algorithm.comparison : equal;

    const opt = WrapOptions(width: 9, whitespace: WhitespaceMode.collapse);
    // `front` is borrowed (a slice into the range's own buffer), so retain it with
    // `.idup` before the range dies — like `File.byLine`.
    string[] want;
    foreach (l; "the quick brown".byWrappedLine(opt))
        want ~= l.idup; // ["the quick", "brown"]

    // A range of const(char)[] chunks gathered into one logical text.
    const(char)[][] chunks = ["the qu", "ick br", "own"];
    assert(chunks.byWrappedLine(opt).equal(want));

    // A lazy range of char.
    import std.utf : byChar;
    assert("the quick brown".byChar.byWrappedLine(opt).equal(want));
}

// Concatenate every chunk of a `WrappedChunks` into one string (test helper).
version (unittest) private string joinChunks(R)(R r)
{
    string s;
    foreach (c; r)
        s ~= c;
    return s;
}

@("wrap.byWrappedChunk.concatMatchesWrapText")
@safe unittest
{
    // The sub-line chunks concatenate back to exactly what `wrapText` produces — for
    // plain, long-word-hard-break, CJK, and styled inputs (newlines included as their
    // own chunks).
    static foreach (pair; [["the quick brown fox", "9"], ["abcdefg", "3"], ["世界世", "4"]])
    {{
        const opt = WrapOptions(width: pair[1] == "9" ? 9 : pair[1] == "4" ? 4 : 3,
            whitespace: WhitespaceMode.collapse);
        assert(pair[0].byWrappedChunk!false(opt).joinChunks == pair[0].wrapText(opt));
    }}

    const styled = "\x1b[31mfoo bar\x1b[0m";
    const sopt = WrapOptions(width: 3, continuity: StyleContinuity.sgrReset,
        whitespace: WhitespaceMode.collapse);
    assert(styled.byWrappedChunk!false(sopt).joinChunks == styled.wrapText(sopt));
}

@("wrap.byWrappedChunk.noEscapeOnlyChunk")
@safe unittest
{
    import sparkles.base.text.grapheme : visibleWidth;

    // Every chunk is either exactly "\n" or carries at least one visible cell — a
    // chunk is never escape-only, so the colors ride along with their text.
    const styled = "\x1b[31mfoo bar baz\x1b[0m";
    const opt = WrapOptions(width: 3, continuity: StyleContinuity.sgrReset,
        whitespace: WhitespaceMode.collapse);
    foreach (c; styled.byWrappedChunk!false(opt))
        assert(c == "\n" || c.visibleWidth >= 1);
}

@("wrap.byWrappedChunk.lineBufferedMatchesLines")
@safe unittest
{
    import std.algorithm.comparison : equal;

    // With `lineBuffered`, dropping the "\n" chunks yields exactly `byWrappedLine`.
    const opt = WrapOptions(width: 9, whitespace: WhitespaceMode.collapse);
    string[] lines;
    foreach (c; "the quick brown fox".byWrappedChunk!true(opt))
        if (c != "\n")
            lines ~= c.idup;
    assert("the quick brown fox".byWrappedLine(opt).equal(lines));
}

@("wrap.byWrappedChunk.isNogc")
@safe pure nothrow @nogc unittest
{
    // Walking the lazy chunk range allocates nothing on the GC, like byWrappedLine.
    auto r = "ab cd".byWrappedChunk!false(
        WrapOptions(width: 5, whitespace: WhitespaceMode.collapse));
    assert(r.front == "ab");
    r.popFront;
    assert(r.front == " cd");
    r.popFront;
    assert(r.empty);
}
