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

import std.range.primitives : put;
import std.uni : unicode;

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
/// Writer-first, `void`; attributes infer (do not force `@safe` on the template).
void writeWrappedText(Writer)(ref Writer w, in char[] text, in WrapOptions opt = WrapOptions.init)
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
    // Red "foo bar" wrapped at 3: each line reset at the end and re-coloured at
    // the start, so colour never bleeds onto the next line / a border.
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
