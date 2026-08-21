/**
hue's HTML sink, part one — the **content fragment** for one document
([`HTM4`](../../../../../docs/specs/hue/feature-requirements.md)): a `<style>`
block plus one `<pre class="syn-root"><code>`, and the physical-line gutter
(`GAL4`) that can be baked into it when there is no page shell to add one.

Structure: $(B pure string builders). $(LREF plainFragment) /
$(LREF twoslashFragment) render one document (also the single-file `--html`
path); $(LREF relayoutGutter) and $(LREF withLineNumbers) rework a fragment's
line structure. The page around a fragment lives in
[`page_shell`](./page_shell.d).
*/
module sparkles.docs.fragment;

import std.array : appender, Appender;
import std.conv : text;
import std.string : indexOf, lastIndexOf;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax;
import sparkles.twoslash;

// ── one document → a content fragment ──────────────────────────────────────

/**
How a content fragment is built.

The defaults are the self-contained single-file `--html` document: a `<style>`
block carrying the whole theme, and no gutter (the page shell adds one). A
$(I set) of pages — hundreds of pre-rendered listings — turns both off: the
rules move to one shared stylesheet ([`assets`](./assets.d)) and the
gutter is baked into the fragment because there is no shell to add it.
*/
struct FragmentOptions
{
    /// embed the theme stylesheet in a `<style>` block
    bool embedStyles = true;

    /// number the physical lines in place (the `<span class="ln">` gutter),
    /// recording the gutter width on the `<pre>` as `--hue-gutter`
    bool gutter;
}

/// The custom property a gutter-carrying fragment records its width in, so the
/// shared stylesheet can lay the numbers out without a per-page `<style>`.
enum gutterProperty = "--hue-gutter:";

/**
The plain-highlight fragment: (optionally) a `<style>` block plus
`<pre class="syn-root">` with CSS-class highlighting (`HTM1`). Shared by the
single-file `--html` path and the gallery, so both emit byte-identical content.
*/
string plainFragment(scope const(char)[] source, scope const(HighlightEvent)[] events,
    in ResolvedTheme theme, in FragmentOptions opt = FragmentOptions.init) @system
{
    SmallBuffer!char styles;
    if (opt.embedStyles)
    {
        styles ~= "pre { padding: 1em; }\n";
        writeThemeStylesheet(theme, styles);
    }
    SmallBuffer!char code;
    renderHtml(source, events, theme, code, HtmlOptions(mode: HtmlMode.cssClasses));
    return assembleFragment(styles[], "syn-root", code[], opt);
}

/**
The twoslash-overlay fragment: the theme stylesheet plus the `.twoslash-*` overlay
stylesheet, then `<pre class="syn-root twoslash">` with the decorated code
(`TWM2`).
*/
string twoslashFragment(in TwoslashReturn tw, scope const(HighlightEvent)[] events,
    in ResolvedTheme theme, ref TsConfigCache cache,
    in FragmentOptions opt = FragmentOptions.init) @system
{
    SmallBuffer!char styles;
    if (opt.embedStyles)
    {
        writeThemeStylesheet(theme, styles);
        writeTwoslashStyles(styles);
    }
    SmallBuffer!char code;
    renderTwoslashHtml(tw, events, theme, cache, code);
    return assembleFragment(styles[], "syn-root twoslash", code[], opt);
}

/// Wraps rendered `code` in the fragment's `<style>` + `<pre class="…"><code>`
/// shell. With `opt.gutter` the lines are numbered here and the width is
/// recorded inline, since a fragment used outside $(LREF pageShell) has no
/// stylesheet of its own to put it in.
private string assembleFragment(scope const(char)[] styles, string preClass,
    scope const(char)[] code, in FragmentOptions opt) @safe pure
{
    auto w = appender!string;
    if (styles.length)
    {
        w ~= "<style>\n";
        w ~= styles;
        w ~= "</style>\n";
    }
    w ~= "<pre class=\"";
    w ~= preClass;
    w ~= "\"";
    if (!opt.gutter)
    {
        w ~= "><code>";
        w ~= code;
    }
    else
    {
        size_t lines;
        const inner = relayoutGutter(code, lines);
        w ~= text(" style=\"", gutterProperty, gutterWidth(lines), "ch\"><code>");
        w ~= inner;
    }
    w ~= "</code></pre>\n";
    return w[];
}

// ── the physical-line gutter (GAL4) ────────────────────────────────────────

/// HTML elements that never nest, so they must not change the tag depth.
private immutable string[] voidElements = [
    "br", "hr", "img", "input", "wbr", "col", "area", "base", "link", "meta",
    "source", "track",
];

/// The below-line overlay blocks: emitted verbatim, unnumbered, and they must not
/// advance the line counter (`GAL4`).
private immutable string[] annotationClasses = [
    "twoslash-meta-line", "twoslash-completion-list", "twoslash-tag-line",
];

/**
Splits the inner `<code>` HTML into $(B physical lines) and below-line annotations:
each physical line's content is wrapped in an inline `<span class="ln">` (which
carries the CSS line counter) and annotations pass through untouched (no number).

Physical-line boundaries are the `'\n'`s at $(B tag depth 0) — hue balances every
tag at each line seam, and popup markup (with its own newlines) stays nested at
depth > 0, so those newlines never split a line. The `'\n'` is $(B kept) (a literal
text node after the span), so `white-space: pre` draws the breaks and a copied
selection preserves every line — including blank ones, which would vanish if each
line were a self-collapsing block.

`lines` receives the physical line count (the gutter width comes from it).
*/
string relayoutGutter(scope const(char)[] code, out size_t lines) @safe pure
{
    auto outp = appender!string;
    // Plain strings (not appenders): each holds at most one line / one annotation,
    // and both are reset repeatedly — which `Appender!string` cannot do.
    string line;
    string anno;
    int depth;
    bool inAnno;

    // `nl` appends the physical newline after the line span (omitted only for a
    // final line the source did not newline-terminate, or a defensive mid-line flush).
    void emitLine(bool nl)
    {
        outp ~= "<span class=\"ln\">";
        outp ~= line;
        outp ~= "</span>";
        if (nl)
            outp ~= "\n";
        line = null;
        ++lines;
    }

    size_t i;
    while (i < code.length)
    {
        const ch = code[i];
        if (ch == '<')
        {
            const gt = code[i .. $].indexOf('>');
            if (gt < 0)
            {
                // Unterminated tag — treat the remainder as text rather than looping.
                if (inAnno) anno ~= code[i .. $]; else line ~= code[i .. $];
                break;
            }
            const raw = code[i .. i + cast(size_t) gt + 1];
            const closing = raw.length > 1 && raw[1] == '/';
            const isVoid = isVoidTag(raw);

            // A below-line block opens at depth 0 (the query/error/tag `<div>` or
            // the completion `<ul>`). Everything until it balances back to depth 0
            // is one annotation, emitted verbatim with no line number.
            if (!inAnno && depth == 0 && !closing && isAnnotationTag(raw))
            {
                if (line.length)
                    emitLine(false); // defensive; a '\n' already flushed it
                inAnno = true;
                anno = null;
            }

            if (inAnno) anno ~= raw; else line ~= raw;
            if (!isVoid)
                depth += closing ? -1 : 1;
            if (inAnno && depth == 0)
            {
                outp ~= anno;
                anno = null;
                inAnno = false;
            }
            i += cast(size_t) gt + 1;
        }
        else if (ch == '\n')
        {
            if (inAnno)
                anno ~= "\n";
            else if (depth == 0)
                emitLine(true); // a physical line boundary — keep the newline
            else
                line ~= "\n"; // a newline nested in popup markup — keep verbatim
            ++i;
        }
        else
        {
            size_t j = i;
            while (j < code.length && code[j] != '<' && code[j] != '\n')
                ++j;
            if (inAnno) anno ~= code[i .. j]; else line ~= code[i .. j];
            i = j;
        }
    }
    if (line.length)
        emitLine(false);
    return outp[];
}

/// `true` iff `raw` is a void element or a self-closing tag (neither nests).
private bool isVoidTag(scope const(char)[] raw) @safe pure nothrow
{
    import std.algorithm.searching : canFind, endsWith;
    import std.ascii : isAlphaNum, toLower;

    if (raw.endsWith("/>"))
        return true;
    size_t s = 1;
    if (s < raw.length && raw[s] == '/')
        ++s;
    size_t e = s;
    while (e < raw.length && raw[e].isAlphaNum)
        ++e;
    char[16] buf;
    if (e - s == 0 || e - s > buf.length)
        return false;
    foreach (k, char c; raw[s .. e])
        buf[k] = c.toLower;
    return voidElements.canFind(buf[0 .. e - s]);
}

/// `true` iff `raw` opens one of the below-line annotation blocks.
private bool isAnnotationTag(scope const(char)[] raw) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    if (!raw.canFind("class=\""))
        return false;
    foreach (c; annotationClasses)
        if (raw.canFind(c))
            return true;
    return false;
}

/**
Rewrites `fragment` (a whole hue `--html` document: `<style>` + `<pre
class="syn-root…"><code>…</code></pre>`) so its code is line-numbered, returning
the gutter width in `ch` via `gutterCols`. A fragment whose `<pre><code>` cannot be
located is returned unchanged (with a default gutter), so a shape change degrades
rather than corrupts.
*/
string withLineNumbers(string fragment, out int gutterCols) @safe pure
{
    gutterCols = 3;
    // Already numbered by `FragmentOptions.gutter`: re-wrapping would nest the
    // `.ln` spans and count every line twice. Take the width it recorded.
    const rec = fragment.indexOf(gutterProperty);
    if (rec >= 0)
    {
        int n;
        foreach (char c; fragment[cast(size_t) rec + gutterProperty.length .. $])
        {
            if (c < '0' || c > '9')
                break;
            n = n * 10 + (c - '0');
        }
        if (n > 0)
            gutterCols = n;
        return fragment;
    }

    const preAt = fragment.indexOf("<pre class=\"syn-root");
    if (preAt < 0)
        return fragment;
    const openAt = fragment[cast(size_t) preAt .. $].indexOf("><code>");
    if (openAt < 0)
        return fragment;
    const innerStart = cast(size_t) preAt + cast(size_t) openAt + "><code>".length;
    const closeAt = fragment.lastIndexOf("</code></pre>");
    if (closeAt < 0 || cast(size_t) closeAt < innerStart)
        return fragment;

    size_t lines;
    const inner = relayoutGutter(fragment[innerStart .. cast(size_t) closeAt], lines);
    gutterCols = gutterWidth(lines);
    return fragment[0 .. innerStart] ~ inner ~ fragment[cast(size_t) closeAt .. $];
}

/// The gutter width in `ch` for a `lines`-line document: the widest number
/// plus a 1ch number-gap and a 1ch pad.
private int gutterWidth(size_t lines) @safe pure nothrow @nogc
    => cast(int)(digits(lines) + 2);

/// Decimal digit count of `n` (`0` has one digit).
private size_t digits(size_t n) @safe pure nothrow @nogc
{
    size_t d = 1;
    while (n >= 10)
    {
        n /= 10;
        ++d;
    }
    return d;
}

// ---------------------------------------------------------------------------

@("gallery.plainFragment.embedStylesAndGutter")
@system
unittest
{
    import std.algorithm.searching : canFind, startsWith;

    const theme = resolveTheme(Theme(name: "t",
        defaultBg: Color.fromRgb(0x1e, 0x1e, 0x2e),
        rules: [ThemeRule("keyword", StyleSpec(fg: Color.fromRgb(0xcb, 0xa6, 0xf7)))]),
        LabelSet.standard());
    const events = [HighlightEvent.sourceSpan(0, 4)];

    // The default is the self-contained document, unchanged.
    const embedded = plainFragment("a\nb\n", events, theme);
    assert(embedded.startsWith("<style>\npre { padding: 1em; }\n"), embedded);
    assert(embedded.canFind("<pre class=\"syn-root\"><code>a\nb\n</code></pre>\n"), embedded);
    assert(!embedded.canFind("class=\"ln\""), embedded);

    // A shared stylesheet carries the rules: no `<style>` block survives.
    const bare = plainFragment("a\nb\n", events, theme, FragmentOptions(embedStyles: false));
    assert(!bare.canFind("<style"), bare);
    assert(bare == "<pre class=\"syn-root\"><code>a\nb\n</code></pre>\n", bare);

    // With no page shell to add one, the gutter is baked in and its width
    // recorded inline — 2 lines ⇒ 1 digit + 2.
    const numbered = plainFragment("a\nb\n", events, theme,
        FragmentOptions(embedStyles: false, gutter: true));
    assert(numbered == "<pre class=\"syn-root\" style=\"--hue-gutter:3ch\"><code>"
        ~ "<span class=\"ln\">a</span>\n<span class=\"ln\">b</span>\n"
        ~ "</code></pre>\n", numbered);
}

@("gallery.relayoutGutter.physicalLinesAndBlanks")
@safe pure
unittest
{
    size_t lines;
    // Three physical lines, the middle one blank: each is wrapped, the newlines
    // are kept, and the blank line still counts (it must keep its height).
    const outp = relayoutGutter("<span>a</span>\n\n<span>b</span>\n", lines);
    assert(lines == 3, outp);
    assert(outp == "<span class=\"ln\"><span>a</span></span>\n"
        ~ "<span class=\"ln\"></span>\n"
        ~ "<span class=\"ln\"><span>b</span></span>\n", outp);
}

@("gallery.relayoutGutter.nestedNewlinesDoNotSplit")
@safe pure
unittest
{
    size_t lines;
    // A newline INSIDE nested markup (a hover popup) is at depth > 0, so it must
    // not end the physical line: one line out, with the newline kept verbatim.
    const outp = relayoutGutter("<span class=\"twoslash-hover\">x\ny</span>\n", lines);
    assert(lines == 1, outp);
    assert(outp == "<span class=\"ln\"><span class=\"twoslash-hover\">x\ny</span></span>\n", outp);
}

@("gallery.relayoutGutter.annotationsAreUnnumbered")
@safe pure
unittest
{
    // hue flushes a below-line block immediately after the newline that ends the
    // line it annotates, and adds no newline of its own — so the next `'\n'`
    // belongs to the NEXT source line. The block must pass through verbatim and
    // must not consume a line number: `b` below is still line 2.
    size_t lines;
    const outp = relayoutGutter(
        "<span>a</span>\n<div class=\"twoslash-meta-line twoslash-error-line\">boom</div>"
        ~ "<span>b</span>\n", lines);
    assert(lines == 2, outp);
    assert(outp == "<span class=\"ln\"><span>a</span></span>\n"
        ~ "<div class=\"twoslash-meta-line twoslash-error-line\">boom</div>"
        ~ "<span class=\"ln\"><span>b</span></span>\n", outp);

    // When the annotated line is followed by a BLANK source line, that blank line's
    // own newline follows the block — and is numbered, as any blank line is.
    size_t l2;
    const blank = relayoutGutter(
        "<span>a</span>\n<div class=\"twoslash-meta-line\">boom</div>\n<span>c</span>\n", l2);
    assert(l2 == 3, blank); // a, the blank line, c
    assert(blank == "<span class=\"ln\"><span>a</span></span>\n"
        ~ "<div class=\"twoslash-meta-line\">boom</div>"
        ~ "<span class=\"ln\"></span>\n"
        ~ "<span class=\"ln\"><span>c</span></span>\n", blank);
}

@("gallery.relayoutGutter.voidTagsKeepDepth")
@safe pure
unittest
{
    size_t lines;
    // A void element must not open a level (or the rest of the file would be
    // swallowed as one line).
    const outp = relayoutGutter("a<br>b\nc\n", lines);
    assert(lines == 2, outp);
    // An unterminated tag degrades to text instead of hanging.
    size_t l2;
    const bad = relayoutGutter("a<span", l2);
    assert(l2 == 1 && bad == "<span class=\"ln\">a<span</span>", bad);
}

@("gallery.withLineNumbers.wrapsOnlyTheCode")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    int gutter;
    const frag = "<style>\n.syn-root { background-color: #1e1e2e; }\n</style>\n"
        ~ "<pre class=\"syn-root\"><code>a\nb\n</code></pre>\n";
    const outp = withLineNumbers(frag, gutter);
    assert(gutter == 3, outp);                       // 1 digit + 2
    assert(outp.canFind("<style>"), outp);            // the stylesheet is untouched
    assert(outp.canFind("<span class=\"ln\">a</span>\n"), outp);
    assert(outp.canFind("</code></pre>"), outp);

    // A fragment of an unexpected shape is returned unchanged, not corrupted.
    int g2;
    assert(withLineNumbers("<p>nope</p>", g2) == "<p>nope</p>");
}

/// A fragment that already carries the gutter is left alone — nesting `.ln`
/// spans would number every line twice — and its recorded width is reused.
@("gallery.withLineNumbers.idempotentOverAGutterFragment")
@safe pure
unittest
{
    const frag = "<pre class=\"syn-root\" style=\"--hue-gutter:4ch\"><code>"
        ~ "<span class=\"ln\">a</span>\n</code></pre>\n";
    int gutter;
    assert(withLineNumbers(frag, gutter) is frag);
    assert(gutter == 4);
}
