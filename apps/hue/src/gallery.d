/**
hue's **HTML sink**: the content fragment for one document, and the multi-document
**gallery** that wraps it ([`HTM4`](../../../docs/specs/hue/feature-requirements.md),
[`HTM6`–`HTM8`](../../../docs/specs/hue/feature-requirements.md),
[`gallery.md` `GAL2`–`GAL7`](../../../docs/specs/hue/gallery.md)).

hue emits a $(I content) fragment — a `<style>` block plus one
`<pre class="syn-root"><code>` — and everything needed to present it as a page
(a header with prev/next nav, a line-number gutter, a single scroll container,
selection domains) used to live in a node script that shelled out to hue once per
file. That page shell is hue's own output, so it lives here, in D, where it is
unit-testable.

Structure: $(B pure string builders + one I/O seam). $(LREF plainFragment) /
$(LREF twoslashFragment) render one document (also the single-file `--html` path);
$(LREF relayoutGutter), $(LREF pageShell) and $(LREF galleryIndex) build the page
text; only $(LREF writeGallery) touches disk.
*/
module gallery;

import std.array : appender, Appender;
import std.conv : text;
import std.string : indexOf, lastIndexOf;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.syntax;
import sparkles.twoslash;

import source_set : SourceEntry, SourceSet;

// ── one document → a content fragment ──────────────────────────────────────

/**
The plain-highlight fragment: a `<style>` block plus `<pre class="syn-root">` with
CSS-class highlighting (`HTM1`). Shared by the single-file `--html` path and the
gallery, so both emit byte-identical content.
*/
string plainFragment(scope const(char)[] source, scope const(HighlightEvent)[] events,
    in ResolvedTheme theme) @system
{
    SmallBuffer!char output;
    output ~= "<style>\npre { padding: 1em; }\n";
    writeThemeStylesheet(theme, output);
    output ~= "</style>\n<pre class=\"syn-root\"><code>";
    renderHtml(source, events, theme, output, HtmlOptions(mode: HtmlMode.cssClasses));
    output ~= "</code></pre>\n";
    return output[].idup;
}

/**
The twoslash-overlay fragment: the theme stylesheet plus the `.twoslash-*` overlay
stylesheet, then `<pre class="syn-root twoslash">` with the decorated code
(`TWM2`).
*/
string twoslashFragment(in TwoslashReturn tw, scope const(HighlightEvent)[] events,
    in ResolvedTheme theme, ref TsConfigCache cache) @system
{
    SmallBuffer!char output;
    output ~= "<style>\n";
    writeThemeStylesheet(theme, output);
    writeTwoslashStyles(output);
    output ~= "</style>\n<pre class=\"syn-root twoslash\"><code>";
    renderTwoslashHtml(tw, events, theme, cache, output);
    output ~= "</code></pre>\n";
    return output[].idup;
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
    gutterCols = cast(int)(digits(lines) + 2); // digits + 1ch number-gap + 1ch pad
    return fragment[0 .. innerStart] ~ inner ~ fragment[cast(size_t) closeAt .. $];
}

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

// ── the page shell (GAL3, GAL6, GAL7) ──────────────────────────────────────

/// Presentation knobs for a gallery — the page-title prefix and the index copy.
struct GalleryOptions
{
    string titlePrefix = "hue";                     /// `<title>` prefix per page
    string heading = "hue gallery";                 /// the index's `<h1>`
    string indexTitle;                              /// the index's `<title>` (default: `heading`)
    string blurb = "Rendered by <code>hue</code>."; /// the index's lead paragraph (raw HTML)
}

/**
Wraps a content `fragment` in the full preview shell (`GAL3`/`GAL6`): a header
(prev · name · summary · index · next), a full-height single scroll container, a
theme-matched background, the physical-line gutter (`GAL4`), and the selection
domains (`GAL7`). `prev`/`next` are page stems; an empty one renders its link
disabled (rather than omitted) so the header does not reflow between pages.
*/
string pageShell(scope const(char)[] name, scope const(char)[] summary, string fragment,
    scope const(char)[] prev, scope const(char)[] next,
    in GalleryOptions opt = GalleryOptions.init) @safe pure
{
    int gutter;
    const body_ = withLineNumbers(fragment, gutter);
    const bg = synRootBackground(fragment);

    auto w = appender!string;
    w ~= "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n";
    w ~= "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n";
    w ~= "<title>";
    escapeInto(w, opt.titlePrefix);
    w ~= " · ";
    escapeInto(w, name);
    w ~= "</title>\n<style>\n";
    w ~= "  html, body { height: 100%; }\n";
    w ~= text("  body { margin: 0; background: ", bg, "; color: #cdd6f4;\n");
    w ~= "         font: 14px/1.5 system-ui, sans-serif;\n";
    w ~= "         display: flex; flex-direction: column; }\n";
    w ~= "  header { flex: none; display: flex; gap: 0.9em; align-items: baseline;\n";
    w ~= "           flex-wrap: wrap; padding: 0.7em 1em;\n";
    w ~= "           background: #181825; border-bottom: 1px solid #313244; }\n";
    w ~= "  header b { font-size: 1.05em; } header .kinds { color: #a6adc8; }\n";
    w ~= "  header .spacer { flex: 1; } header a { color: #89b4fa; text-decoration: none; }\n";
    w ~= "  header a:hover { text-decoration: underline; }\n";
    w ~= "  header .disabled { color: #45475a; }\n";
    // The single scroll container: the code pane fills the remaining height, so
    // only ONE scrollbar ever appears (no nested body + pre scrollbars).
    w ~= text("  main { flex: 1; min-height: 0; overflow: auto; background: ", bg, "; }\n");
    w ~= "  main pre.syn-root { margin: 0; padding: 0.6em 1ch; min-height: 100%;\n";
    w ~= "                      box-sizing: border-box; }\n";
    // Line-number gutter: a left pad on <code> holds the numbers; each physical
    // line's number is generated content (never selected/copied). Below-line
    // annotations aren't `.ln`, so they carry no number and don't advance it.
    w ~= "  main pre.syn-root > code { display: block; counter-reset: lineno;\n";
    w ~= text("                             padding-left: ", gutter, "ch; }\n");
    // `.ln` is INLINE — the physical `\n` after each span (kept by relayoutGutter)
    // draws the line breaks under `white-space: pre` and gives blank lines their
    // height, and a copied selection keeps every line.
    w ~= "  .ln { position: relative; counter-increment: lineno; }\n";
    w ~= "  .ln::before { content: counter(lineno); position: absolute;\n";
    w ~= text("                left: -", gutter, "ch; width: ", gutter - 1, "ch; text-align: right;\n");
    w ~= "                color: #6c7086; -webkit-user-select: none; user-select: none; }\n";
    // Selection domains (VSCode-like). The shipped twoslash.css sets the below-line
    // annotations `user-select: none` (code copies cleanly for every consumer). The
    // gallery goes further: a drag is confined to whichever domain it STARTS in —
    // the code, or one annotation. Override the shipped `none` back to selectable
    // so a drag can begin inside an annotation…
    w ~= "  main .twoslash :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: text; user-select: text; }\n";
    // …started in code → annotations drop out of the selection;
    w ~= "  body.sel-code :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: none; user-select: none; }\n";
    // …started in an annotation → only that one stays selectable (contained).
    w ~= "  body.sel-anno main pre.syn-root > code { -webkit-user-select: none; user-select: none; }\n";
    w ~= "  body.sel-anno :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n";
    w ~= "    -webkit-user-select: none; user-select: none; }\n";
    w ~= "  body.sel-anno .sel-active, body.sel-anno .sel-active * {\n";
    w ~= "    -webkit-user-select: text; user-select: text; }\n";
    w ~= "</style></head><body>\n<header>";
    navLink(w, prev, "← prev", "prev");
    w ~= "<b>";
    escapeInto(w, name);
    w ~= "</b><span class=\"kinds\">";
    escapeInto(w, summary);
    w ~= "</span><span class=\"spacer\"></span><a href=\"index.html\">all</a>";
    navLink(w, next, "next →", "next");
    w ~= "</header>\n<main>";
    w ~= body_;
    w ~= "</main>\n";
    // Confine each drag to the domain it started in: mark the annotation the
    // mousedown landed in (if any) and flag the body so the CSS above restricts the
    // other domain. Runs before the drag extends, so the restriction applies to the
    // selection this mousedown begins.
    w ~= "<script>\n";
    w ~= "const A = '.twoslash-meta-line,.twoslash-completion-list,.twoslash-tag-line';\n";
    w ~= "addEventListener('mousedown', e => {\n";
    w ~= "  document.querySelectorAll('.sel-active').forEach(el => el.classList.remove('sel-active'));\n";
    w ~= "  const a = e.target.closest(A);\n";
    w ~= "  if (a) a.classList.add('sel-active');\n";
    w ~= "  document.body.classList.toggle('sel-anno', !!a);\n";
    w ~= "  document.body.classList.toggle('sel-code', !a);\n";
    w ~= "});\n";
    w ~= "</script>\n</body></html>\n";
    return w[];
}

/// A header nav link, or a disabled span when there is no such neighbour.
private void navLink(ref Appender!string w, scope const(char)[] target,
    string label, string cls) @safe pure
{
    if (target.length)
    {
        w ~= text("<a class=\"", cls, "\" href=\"");
        escapeInto(w, target);
        w ~= text(".html\">", label, "</a>");
    }
    else
        w ~= text("<span class=\"", cls, " disabled\">", label, "</span>");
}

/**
Builds the gallery `index.html` (`GAL2`): every entry as a link plus its summary.
An empty set renders an explicit "no documents" note rather than an empty list
(`GAL9`).
*/
string galleryIndex(scope const SourceEntry[] entries,
    in GalleryOptions opt = GalleryOptions.init) @safe pure
{
    auto w = appender!string;
    w ~= "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">\n";
    w ~= "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n";
    w ~= "<title>";
    escapeInto(w, opt.indexTitle.length ? opt.indexTitle : opt.heading);
    w ~= "</title>\n<style>\n";
    w ~= "  body { margin: 0 auto; max-width: 48em; padding: 2em 1.5em;\n";
    w ~= "         background: #11111b; color: #cdd6f4; font: 15px/1.6 system-ui, sans-serif; }\n";
    w ~= "  h1 { font-size: 1.4em; } p { color: #a6adc8; }\n";
    w ~= "  ul { list-style: none; padding: 0; }\n";
    w ~= "  li { padding: 0.5em 0; border-bottom: 1px solid #1e1e2e; }\n";
    w ~= "  a { color: #89b4fa; text-decoration: none; font-weight: 600; }\n";
    w ~= "  a:hover { text-decoration: underline; }\n";
    w ~= "  code { color: #a6adc8; font-size: 0.9em; margin-left: 0.6em; }\n";
    w ~= "</style></head><body>\n<h1>";
    escapeInto(w, opt.heading);
    w ~= "</h1>\n<p>";
    w ~= opt.blurb; // trusted, caller-supplied markup
    w ~= "</p>\n";

    if (entries.length == 0)
    {
        w ~= "<p><em>No documents to show.</em></p>\n</body></html>\n";
        return w[];
    }

    w ~= "<ul>\n";
    foreach (e; entries)
    {
        w ~= "  <li><a href=\"";
        escapeInto(w, e.name);
        w ~= ".html\">";
        escapeInto(w, e.name);
        w ~= "</a><code>";
        escapeInto(w, e.summary);
        w ~= "</code></li>\n";
    }
    w ~= "</ul>\n</body></html>\n";
    return w[];
}

/// The `.syn-root` background color declared in `fragment`'s theme stylesheet, so
/// the page surround matches the code pane (`GAL6`); falls back to the default
/// dark backdrop when the rule is absent.
private string synRootBackground(scope const(char)[] fragment) @safe pure
{
    enum fallback = "#1e1e2e";
    const at = fragment.indexOf(".syn-root");
    if (at < 0)
        return fallback;
    const open = fragment[cast(size_t) at .. $].indexOf('{');
    if (open < 0)
        return fallback;
    const blockStart = cast(size_t) at + cast(size_t) open;
    const close = fragment[blockStart .. $].indexOf('}');
    const block = close < 0 ? fragment[blockStart .. $]
        : fragment[blockStart .. blockStart + cast(size_t) close];
    const bg = block.indexOf("background-color:");
    if (bg < 0)
        return fallback;
    auto rest = block[cast(size_t) bg + "background-color:".length .. $];
    size_t s;
    while (s < rest.length && rest[s] == ' ')
        ++s;
    if (s >= rest.length || rest[s] != '#')
        return fallback;
    size_t e = s + 1;
    while (e < rest.length && isHexDigit(rest[e]))
        ++e;
    return rest[s .. e].idup;
}

private bool isHexDigit(char c) @safe pure nothrow @nogc
    => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

/// Escapes `&`, `<`, `>`, `"` into `w`.
private void escapeInto(ref Appender!string w, scope const(char)[] s) @safe pure
{
    foreach (char c; s)
        switch (c)
        {
            case '&': w ~= "&amp;"; break;
            case '<': w ~= "&lt;"; break;
            case '>': w ~= "&gt;"; break;
            case '"': w ~= "&quot;"; break;
            default: w ~= c; break;
        }
}

// ── the I/O seam ───────────────────────────────────────────────────────────

/**
Writes the gallery for `set` into `outDir` (`GAL2`): `<name>.html` per entry plus
`index.html`. `renderOne` produces one entry's content fragment; an entry it fails
on is reported and $(B skipped), leaving the rest of the gallery intact (`GAL9`).
Returns the number of pages written.
*/
size_t writeGallery(in SourceSet set, string outDir, in GalleryOptions opt,
    scope string delegate(in SourceEntry) renderOne) @system
{
    import std.file : mkdirRecurse, write;
    import std.path : buildPath;
    import std.stdio : stderr;

    mkdirRecurse(outDir);

    SourceEntry[] written;
    foreach (i, ref const e; set.entries)
    {
        string fragment;
        try
            fragment = renderOne(e);
        catch (Exception ex)
        {
            stderr.writeln("hue: skipping '", e.path, "': ", ex.msg);
            continue;
        }
        if (fragment.length == 0)
        {
            stderr.writeln("hue: skipping '", e.path, "': nothing rendered");
            continue;
        }
        const prev = i > 0 ? set.entries[i - 1].name : "";
        const next = i + 1 < set.entries.length ? set.entries[i + 1].name : "";
        write(buildPath(outDir, e.name ~ ".html"),
            pageShell(e.name, e.summary, fragment, prev, next, opt));
        written ~= e;
    }

    write(buildPath(outDir, "index.html"), galleryIndex(written, opt));
    return written.length;
}

// ---------------------------------------------------------------------------

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

@("gallery.pageShell.navSummaryAndTheme")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const frag = "<style>\n.syn-root { background-color: #123456; }\n</style>\n"
        ~ "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    const page = pageShell("02-query", "hover×2 query", frag, "01-hover", "03-completions",
        GalleryOptions(titlePrefix: "twoslash"));

    assert(page.canFind("<title>twoslash · 02-query</title>"), page);
    assert(page.canFind("<b>02-query</b>"), page);
    assert(page.canFind("hover×2 query"), page);
    // Both neighbours link; the index link is always present.
    assert(page.canFind("href=\"01-hover.html\""), page);
    assert(page.canFind("href=\"03-completions.html\""), page);
    assert(page.canFind("href=\"index.html\""), page);
    // The page background is taken from the theme's `.syn-root` rule.
    assert(page.canFind("background: #123456"), page);
    // Gutter + selection domains are wired.
    assert(page.canFind("counter-increment: lineno"), page);
    assert(page.canFind("sel-anno"), page);
}

@("gallery.pageShell.endsDisableRatherThanOmit")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const frag = "<pre class=\"syn-root\"><code>x\n</code></pre>\n";
    const first = pageShell("a", "", frag, "", "b");
    // No previous document ⇒ the link is disabled, not dropped (so the header
    // keeps its shape between pages).
    assert(first.canFind("<span class=\"prev disabled\">← prev</span>"), first);
    assert(first.canFind("href=\"b.html\""), first);

    const last = pageShell("b", "", frag, "a", "");
    assert(last.canFind("<span class=\"next disabled\">next →</span>"), last);
}

@("gallery.galleryIndex.linksEntriesAndHandlesEmpty")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const idx = galleryIndex([
        SourceEntry(path: "f/01-hover.twoslash.json", name: "01-hover", summary: "hover"),
        SourceEntry(path: "f/02-query.twoslash.json", name: "02-query", summary: "query×2"),
    ]);
    assert(idx.canFind("href=\"01-hover.html\">01-hover</a>"), idx);
    assert(idx.canFind("<code>query×2</code>"), idx);

    // An empty set says so rather than rendering an empty list.
    assert(galleryIndex([]).canFind("No documents to show"));
}

@("gallery.escaping.namesAndSummaries")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    // A name/summary carrying HTML metacharacters must not break the markup.
    const idx = galleryIndex([SourceEntry(name: "a<b>", summary: "x & \"y\"")]);
    assert(idx.canFind("a&lt;b&gt;"), idx);
    assert(idx.canFind("x &amp; &quot;y&quot;"), idx);
}
