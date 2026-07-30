/**
Line breaking for $(MREF sparkles,ui) — the `LAY10` strategy seam. A text run
opts into wrapping with $(LREF TextWrap); the engine invokes $(LREF wrapLines)
from the cross-axis measure with the width the node was $(I actually allocated).

Two strategies, one contract:

$(LIST
    * $(B greedy) — first-fit, break as late as possible. The natural default on
        a monospace grid (there is no stretchable glue to justify with).
    * $(B balanced) — minimum-raggedness dynamic programming (the rigid-glue
        Knuth–Plass variant): minimizes the sum of squared trailing slack over
        all lines but the last. A quality upgrade for full-width prose; it
        degenerates to greedy at narrow widths.
)

Lines are $(B slices of the input) — no copying, no allocation beyond the line
list. Breaks happen at spaces (which the break consumes); a `'\n'` forces a
break; a word wider than the limit overflows its own line rather than being
split mid-word. Width is measured through a caller-supplied function, so the
breaker is as grapheme-correct as its measurer (`LAY5`).
*/
module sparkles.ui.wrap;

import sparkles.base.term_color : RgbColor;
import sparkles.ui.style : Slot, TextStyle;

@safe:

/// One styled span of a rich text run (`WGT6`): a slice of text with its own
/// semantic slot and text chrome, so syntax-highlighted or inline-styled
/// content is one node — not a backend overpainting the toolkit's output to
/// re-colour it, and not a row of per-token widgets fighting the line breaker.
struct TextSpan
{
    const(char)[] text;      /// borrowed — must outlive the tree
    Slot slot = Slot.inherit;
    TextStyle textStyle;     /// per-span bold/italic/underline etc.
    /// Fill the span's slot background (an inline-`code` pill).
    bool paintBackground;
    /// Never break inside this span — it wraps as one token (a pill's name
    /// stays whole; hugging punctuation in a neighbouring span still joins it).
    bool noBreak;
    /// A $(B resolved) foreground override, gated by `hasFg` — the theme's
    /// syntax channel: highlight rules resolve outside the slot vocabulary
    /// (`THM1`), so a syntax-colored token carries its color directly.
    RgbColor fg;
    /// ditto
    bool hasFg;
    /// A resolved background override, gated by `hasBg` — pre-styled content
    /// (a decoded ANSI fence) carries its own cell background the same way.
    RgbColor bg;
    /// ditto
    bool hasBg;
    /// The source byte range this span's text came from (`size_t.max` start =
    /// synthetic — an icon, bullet, or gutter). The $(B identity channel):
    /// selection, search jumps and copy map screen content back to the source
    /// through it, the same discipline as the old model's per-run `srcStart`.
    /// Normalized prose keeps its original span, so offsets are span-granular
    /// there and byte-exact for source-sliced content (code).
    size_t srcStart = size_t.max;
    /// ditto
    size_t srcEnd;
}

/// How a text widget breaks into lines (the `LAY10` strategy seam). `none`
/// (the default) keeps the run a single line regardless of allocated width.
enum TextWrap : ubyte
{
    none,     /// a single line (the default)
    greedy,   /// first-fit: break as late as possible (ragged right)
    balanced, /// minimum squared-slack over all lines but the last
}

/**
Breaks `text` into lines no wider than `width` columns, measuring through
`measure` (any callable `const(char)[] → int`). `firstLineWidth` expresses hang
indent as a first-line width delta: when non-negative, the first line of each
paragraph wraps to it instead of `width`.

Returns the lines as slices of `text`. Inter-word spacing inside a line is
preserved verbatim; the spaces $(I at) a break are consumed. An empty paragraph
(text between two `'\n'`) is one empty line, so blank lines survive.
*/
const(char)[][] wrapLines(F)(
    const(char)[] text, int width, scope F measure,
    TextWrap algo = TextWrap.greedy, int firstLineWidth = -1)
if (is(typeof(measure(text)) : int))
{
    const(char)[][] lines;

    size_t paraStart = 0;
    foreach (i, char c; text)
        if (c == '\n')
        {
            wrapParagraph(text[paraStart .. i], width, measure, algo,
                firstLineWidth, lines);
            paraStart = i + 1;
        }
    wrapParagraph(text[paraStart .. $], width, measure, algo,
        firstLineWidth, lines);

    return lines;
}

// A word's byte span within its paragraph.
private struct Span
{
    size_t start, end;
}

private void wrapParagraph(F)(
    const(char)[] para, int width, scope F measure, TextWrap algo,
    int firstLineWidth, ref const(char)[][] lines)
{
    // Tokenize into space-separated words (any other byte is word content).
    Span[] words;
    size_t i = 0;
    while (i < para.length)
    {
        while (i < para.length && para[i] == ' ')
            i++;
        const start = i;
        while (i < para.length && para[i] != ' ')
            i++;
        if (i > start)
            words ~= Span(start, i);
    }

    if (words.length == 0)
    {
        lines ~= para[0 .. 0]; // a blank line survives
        return;
    }

    const firstW = firstLineWidth >= 0 ? firstLineWidth : width;

    if (algo == TextWrap.balanced)
        wrapBalanced(para, words, width, firstW, measure, lines);
    else
        wrapGreedy(para, words, width, firstW, measure, lines);
}

private void wrapGreedy(F)(
    const(char)[] para, in Span[] words, int width, int firstW,
    scope F measure, ref const(char)[][] lines)
{
    size_t lineStart = words[0].start;
    size_t lineEnd = words[0].end;
    int lineW = measure(para[lineStart .. lineEnd]);
    int limit = firstW;

    foreach (word; words[1 .. $])
    {
        // The candidate joint: the inter-word gap plus the word itself.
        const jointW = measure(para[lineEnd .. word.end]);
        if (lineW + jointW <= limit)
        {
            lineW += jointW;
            lineEnd = word.end;
        }
        else
        {
            lines ~= para[lineStart .. lineEnd];
            lineStart = word.start;
            lineEnd = word.end;
            lineW = measure(para[lineStart .. lineEnd]);
            limit = width;
        }
    }
    lines ~= para[lineStart .. lineEnd];
}

private void wrapBalanced(F)(
    const(char)[] para, in Span[] words, int width, int firstW,
    scope F measure, ref const(char)[][] lines)
{
    const n = words.length;

    // acc[j] = width of words[0..j] joined with their source gaps, so
    // lineWidth(i..j) = acc[j] - acc[i] + wordW(i).
    auto wordW = new int[](n);
    auto acc = new int[](n);
    foreach (k, word; words)
    {
        wordW[k] = measure(para[word.start .. word.end]);
        acc[k] = k == 0 ? wordW[0]
            : acc[k - 1] + measure(para[words[k - 1].end .. word.end]);
    }
    int lineWidth(size_t i, size_t j) => acc[j] - acc[i] + wordW[i];

    // cost[j] = minimal penalty for words[0..j+1]; the last line is free.
    enum long infinity = long.max / 2;
    // An overflowing single word costs a large *finite* constant (plus its
    // overflow), so it never displaces a feasible break — but a text full of
    // overwide words still sums nowhere near `infinity` (a fractional-infinity
    // penalty saturates after a few and collapses the DP to one line).
    enum long overwidePenalty = 1L << 40;
    auto cost = new long[](n);
    auto breakBefore = new size_t[](n); // the line holding j starts at this word
    foreach (j; 0 .. n)
    {
        cost[j] = infinity;
        // Try every line start i for the line ending at j.
        foreach_reverse (i; 0 .. j + 1)
        {
            const limit = i == 0 ? firstW : width;
            const lw = lineWidth(i, j);
            // An overwide line is admissible only as a single overflowing word.
            if (lw > limit && i != j)
                break; // widening the line further only overflows more
            const prev = i == 0 ? 0 : cost[i - 1];
            if (prev >= infinity)
                continue;
            const slack = limit - lw;
            // The last line's raggedness is free; an overflowing word is
            // heavily penalized so it never displaces a feasible break.
            const long penalty = slack < 0 ? overwidePenalty + cast(long)(-slack)
                : j == n - 1 ? 0
                : cast(long) slack * slack;
            if (prev + penalty < cost[j])
            {
                cost[j] = prev + penalty;
                breakBefore[j] = i;
            }
        }
    }

    // Reconstruct the line starts back-to-front, then emit in order.
    auto starts = new size_t[](0);
    size_t j = n - 1;
    while (true)
    {
        starts ~= breakBefore[j];
        if (breakBefore[j] == 0)
            break;
        j = breakBefore[j] - 1;
    }
    foreach_reverse (k, start; starts)
    {
        const end = k == 0 ? n - 1 : starts[k - 1] - 1;
        lines ~= para[words[start].start .. words[end].end];
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest)
{
    import sparkles.ui.geometry : cellsOf;

    private int cols(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) cellsOf(s);
}

@("ui.wrap.greedy.basics")
@safe pure nothrow unittest
{
    // First-fit at width 10: break as late as possible.
    assert(wrapLines("the quick brown fox", 10, &cols)
        == ["the quick", "brown fox"]);
    // Everything fits: one line, spacing preserved verbatim.
    assert(wrapLines("a  b", 10, &cols) == ["a  b"]);
    // Empty text is one empty line.
    assert(wrapLines("", 10, &cols) == [""]);
}

@("ui.wrap.newlineForcesBreak")
@safe pure nothrow unittest
{
    assert(wrapLines("one\ntwo", 80, &cols) == ["one", "two"]);
    // A blank line survives as an empty line.
    assert(wrapLines("one\n\ntwo", 80, &cols) == ["one", "", "two"]);
}

@("ui.wrap.overwideWordOverflowsItsOwnLine")
@safe pure nothrow unittest
{
    foreach (algo; [TextWrap.greedy, TextWrap.balanced])
    {
        const lines = wrapLines("a incomprehensibility z", 8, &cols, algo);
        assert(lines == ["a", "incomprehensibility", "z"]);
    }
}

@("ui.wrap.linesAreSlicesOfTheInput")
@safe pure nothrow unittest
{
    const text = "alpha beta gamma";
    const lines = wrapLines(text, 10, &cols);
    foreach (ln; lines)
    {
        // No copying: every line points into the original buffer.
        assert(() @trusted {
            return ln.ptr >= text.ptr && ln.ptr + ln.length <= text.ptr + text.length;
        }());
    }
}

@("ui.wrap.balanced.minimizesRaggedness")
@safe pure nothrow unittest
{
    // The classic case: greedy leaves a lone word on the last line; balanced
    // moves a word down for even lines. Both respect the width.
    const text = "aaa bb cc ddddd";
    assert(wrapLines(text, 6, &cols, TextWrap.greedy)
        == ["aaa bb", "cc", "ddddd"]);
    assert(wrapLines(text, 6, &cols, TextWrap.balanced)
        == ["aaa", "bb cc", "ddddd"]);
    // Every balanced line still fits.
    foreach (ln; wrapLines(text, 6, &cols, TextWrap.balanced))
        assert(cols(ln) <= 6);
}

@("ui.wrap.propertyEveryLineFitsAndEveryWordSurvives")
@safe pure nothrow unittest
{
    // Property: at any width, both strategies emit lines within the limit
    // (an overwide line must be a single unbreakable word) and no word is
    // ever dropped or duplicated.
    static bool hasSpace(scope const(char)[] s) @safe pure nothrow @nogc
    {
        foreach (char c; s)
            if (c == ' ')
                return true;
        return false;
    }

    const text = "the quick brown fox jumps over the lazy dog";
    foreach (w; 3 .. 20)
        foreach (algo; [TextWrap.greedy, TextWrap.balanced])
        {
            size_t wordBytes;
            foreach (ln; wrapLines(text, w, &cols, algo))
            {
                assert(cols(ln) <= w || !hasSpace(ln));
                foreach (char c; ln)
                    wordBytes += c != ' ';
            }
            size_t expected;
            foreach (char c; text)
                expected += c != ' ';
            assert(wordBytes == expected);
        }
}

@("ui.wrap.hangIndentViaFirstLineWidth")
@safe pure nothrow unittest
{
    // A 4-column-narrower first line models a hang indent.
    const lines = wrapLines("one two three four five", 12, &cols,
        TextWrap.greedy, 8);
    assert(lines == ["one two", "three four", "five"]);
}

// ── Styled-run breaking ─────────────────────────────────────────────────────

/**
Breaks a rich run — a sequence of styled $(LREF TextSpan)s — into lines no
wider than `width`, measuring through `measure`. The other half of `WGT6`:
prose with inline pills and styled words wraps as $(B text), not as a row of
word widgets fighting the box layout.

Break opportunities are the spaces inside breakable spans (a break consumes
them); a `noBreak` span wraps as one token, and adjacent non-space content in
neighbouring spans $(B joins) its token — so a pill followed by `", and"`
carries its comma to the next line with it. A `'\n'` anywhere forces a break.
Lines are lists of span $(I slices) — no text is copied.

Greedy only (the balanced strategy applies to plain runs; styled prose is
ragged-right by design).
*/
TextSpan[][] wrapSpans(F)(
    const(TextSpan)[] spans, int width, scope F measure, int hangIndent = 0)
if (is(typeof(measure("")) : int))
{
    // A hang indent narrows every line after the first (the painter offsets
    // them right by the same amount — a leader's continuation alignment).
    const contWidth = hangIndent < width ? width - hangIndent : 1;
    // A fragment is a maximal unbreakable piece of one span: either a word
    // fragment / whole noBreak span (glue = false), a run of spaces
    // (glue = true), or a forced break (newline = true).
    static struct Fragment
    {
        size_t span;
        const(char)[] text;
        bool glue;
        bool newline;
    }

    Fragment[] frags;
    foreach (si, ref span; spans)
    {
        const t = span.text;
        if (span.noBreak)
        {
            if (t.length)
                frags ~= Fragment(si, t);
            continue;
        }
        size_t i = 0;
        while (i < t.length)
        {
            if (t[i] == '\n')
            {
                frags ~= Fragment(si, t[i .. i + 1], glue: false, newline: true);
                ++i;
                continue;
            }
            const start = i;
            const isGlue = t[i] == ' ';
            while (i < t.length && (t[i] == ' ') == isGlue && t[i] != '\n')
                ++i;
            frags ~= Fragment(si, t[start .. i], glue: isGlue);
        }
    }

    TextSpan[][] lines;
    TextSpan[] cur;
    int curW;
    size_t pendingGlue = size_t.max; // index into frags of glue awaiting content

    void append(size_t fi)
    {
        const f = frags[fi];
        const w = measure(f.text);
        // Merge into the previous slice when it continues the same span.
        if (cur.length && cur[$ - 1].text.length
            && &spans[f.span].text[0] <= &f.text[0]
            && cur[$ - 1].slot == spans[f.span].slot
            && isContiguous(cur[$ - 1].text, f.text))
        {
            cur[$ - 1].text = joinSlices(cur[$ - 1].text, f.text);
            // The joined slice covers more source: extend the identity too
            // (contiguous slices ⇒ end = start + length).
            if (cur[$ - 1].srcStart != size_t.max)
                cur[$ - 1].srcEnd = cur[$ - 1].srcStart
                    + cur[$ - 1].text.length;
        }
        else
        {
            auto s = cast() spans[f.span];
            // A sliced fragment keeps its source identity: shift srcStart by
            // the fragment's offset within the span (approximate for
            // normalized prose, exact for source-sliced code).
            if (s.srcStart != size_t.max)
            {
                const off = sliceOffset(spans[f.span].text, f.text);
                s.srcStart += off;
                if (s.srcEnd > s.srcStart + f.text.length)
                    s.srcEnd = s.srcStart + f.text.length;
            }
            s.text = f.text;
            cur ~= s;
        }
        curW += w;
    }

    void flush()
    {
        lines ~= cur;
        cur = null;
        curW = 0;
        pendingGlue = size_t.max;
    }

    size_t i = 0;
    while (i < frags.length)
    {
        const f = frags[i];
        if (f.newline)
        {
            flush();
            ++i;
            continue;
        }
        if (f.glue)
        {
            pendingGlue = cur.length ? i : size_t.max; // leading glue drops
            ++i;
            continue;
        }
        // A token: this fragment plus every directly-adjacent non-glue
        // fragment (spanning pills and hugging punctuation).
        int tokenW = 0;
        size_t j = i;
        while (j < frags.length && !frags[j].glue && !frags[j].newline)
        {
            tokenW += measure(frags[j].text);
            ++j;
        }
        const glueW = pendingGlue != size_t.max
            ? measure(frags[pendingGlue].text) : 0;
        const limit = lines.length == 0 ? width : contWidth;
        if (cur.length && curW + glueW + tokenW > limit)
            flush(); // the pending glue is consumed by the break
        else if (pendingGlue != size_t.max && cur.length)
            append(pendingGlue);
        foreach (k; i .. j)
            append(k);
        pendingGlue = size_t.max;
        i = j;
    }
    flush();
    return lines;
}

// Byte offset of slice `b` within its parent slice `a` (same buffer).
private size_t sliceOffset(scope const(char)[] a, scope const(char)[] b)
    @trusted pure nothrow @nogc
    => b.ptr >= a.ptr ? cast(size_t)(b.ptr - a.ptr) : 0;

// `b` starts exactly where `a` ends (slices of one buffer).
private bool isContiguous(scope const(char)[] a, scope const(char)[] b)
    @trusted pure nothrow @nogc
    => a.length && b.length && a.ptr + a.length is b.ptr;

// The single slice covering contiguous `a` then `b`.
private const(char)[] joinSlices(return scope const(char)[] a,
    scope const(char)[] b) @trusted pure nothrow @nogc
    => a.ptr[0 .. a.length + b.length];

@("ui.wrap.spans.greedyAcrossStyles")
@safe pure nothrow unittest
{
    import sparkles.ui.geometry : cellsOf;

    static int cols2(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) cellsOf(s);

    // "use the |run| helper today" with |run| a pill, width 14:
    const spans = [
        TextSpan("use the "),
        TextSpan("run", Slot.chip, TextStyle.init, paintBackground: true, noBreak: true),
        TextSpan(" helper today"),
    ];
    const lines = wrapSpans(spans, 14, &cols2);
    assert(lines.length == 2);
    // "use the " + pill(3) = 11 fits; " helper" would make 18 > 14 → wraps.
    // The inter-word gap before the pill is preserved (painters draw it).
    assert(lines[0].length == 2);
    assert(lines[0][0].text == "use the " && lines[0][1].text == "run");
    assert(lines[0][1].paintBackground);          // the pill's style survives
    assert(lines[1][0].text == "helper today");   // merged back into one slice
}

@("ui.wrap.spans.punctuationHugsThePill")
@safe pure nothrow unittest
{
    import sparkles.ui.geometry : cellsOf;

    static int cols2(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) cellsOf(s);

    // A pill followed by ", x" in the next span: the comma joins the pill's
    // token, so a break never strands it at a line start.
    const spans = [
        TextSpan("aaaa bbbb "),
        TextSpan("pill", Slot.chip, TextStyle.init, true, true),
        TextSpan(", x"),
    ];
    const lines = wrapSpans(spans, 9, &cols2);
    // "aaaa bbbb" fills line 1; "pill," + " x" go to line 2 together.
    assert(lines.length == 2);
    assert(lines[0].length == 1 && lines[0][0].text == "aaaa bbbb");
    assert(lines[1][0].text == "pill" && lines[1][1].text == ", x");
}

@("ui.wrap.spans.forcedBreakAndWhitespaceCollapse")
@safe pure nothrow unittest
{
    import sparkles.ui.geometry : cellsOf;

    static int cols2(scope const(char)[] s) @safe pure nothrow @nogc
        => cast(int) cellsOf(s);

    const spans = [TextSpan("one\ntwo three")];
    const lines = wrapSpans(spans, 80, &cols2);
    assert(lines.length == 2);
    assert(lines[0][0].text == "one" && lines[1][0].text == "two three");
}
