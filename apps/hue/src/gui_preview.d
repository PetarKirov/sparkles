// Markdown-preview model + layout for `hue --gui`.
//
// Three stages, all raylib-free (gui.d does the painting):
//
//   buildPreviewModel  (@system, once at file load) — parse the markdown
//       structure (sparkles.syntax.md.model), and for each fenced code block
//       either syntax-highlight its body with the fence language (reusing the
//       highlightInjected pipeline) or, for a ` ```ansi ` fence, decode it with
//       the off-screen VT (gui_ansi.decodeAnsi). Theme-independent.
//
//   flattenPreview     (pure, rerun on theme / file change) — resolve the model
//       into a width-INDEPENDENT PreviewItem[] with live-theme colors: heading
//       markers, code panels + language labels, list bullets + checkboxes, quote
//       gutters, callouts, tables. Prose is tokenized into words but not yet
//       broken; code is highlighted but not yet framed. This is the expensive
//       part, so the GUI caches its PreviewDoc.
//
//   wrapPreview        (pure, rerun on resize / font-size / gutter change) — wrap
//       the cached PreviewDoc to the window width into a flat PreviewLine[]:
//       place prose line breaks, frame code boxes, render table borders. The only
//       stage a resize re-runs (`layoutPreview` composes the two for non-cached
//       callers — the terminal ANSI + interactive-viewer paths).
//
// gui.d paints PreviewLine[] index-culled to the viewport, mapping the neutral
// RgbColor + Attr bits onto raylib-text's TextStyle + raylib Color.
module gui_preview;

import ansi_model : AnsiLine, AnsiSpan, Attr;
import gui_text : columnWidth, lineCount;

import sparkles.syntax : MdDoc, MdBlock, MdBlockKind, MdInline, MdInlineKind, ColAlign, Span,
    HighlightEvent, byStyledLine, ResolvedTheme, StyleSpec, TextAttr, UnderlineStyle,
    LabelId, toRgb, RgbColor, GrammarRegistry, TsConfigCache, canonicalLanguage,
    extractMarkdown, highlightInjected;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;
import sparkles.test_runner.attributes : benchmark;

// ── Presentation model ───────────────────────────────────────────────────────

/// A styled text fragment on a preview line. `hasBg` gates `bg` (most runs have
/// no explicit background — the line's `band` provides one). `attrs` uses the
/// `gui_ansi.Attr` bits.
struct PreviewRun
{
    const(char)[] text;
    RgbColor fg;
    RgbColor bg;
    bool hasBg;
    ubyte attrs;
    /// Byte offset into the source file of this run's first char, or `size_t.max`
    /// for synthetic runs (icons, bullets, gutters, box-drawing) — used to map a
    /// mouse selection back to file offsets, and to exclude decorations from it.
    size_t srcStart = size_t.max;
}

/// A full-width background band drawn behind a line (before its runs).
enum BandKind : ubyte
{
    none,       /// no band (plain prose)
    codePanel,  /// fenced-code body
    codeHeader, /// fenced-code language-label bar
    tableRow,   /// a table row
    rule,       /// a thematic break (a horizontal line)
    heading,    /// a heading line (subtle per-level accent band)
}

/// One laid-out visual line. `leader` (bullet / number / checkbox / heading
/// marker) is drawn at `indentCols` — muted by default, or in `leaderFg` when
/// `hasLeaderFg` (a colored heading icon / checked box / callout icon).
/// `quoteDepth` draws that many `│` gutter bars (per-depth colored, or all in
/// `barFg` when `hasBarFg` — a callout accent). Blank `runs` with a non-`none`
/// `band` still paint the band (e.g. a blank code-panel line).
struct PreviewLine
{
    int indentCols;
    ubyte quoteDepth;
    BandKind band;
    RgbColor bandBg;  /// full-width band color (when band != none)
    string leader;
    RgbColor leaderFg; /// colored-leader tint (when hasLeaderFg)
    bool hasLeaderFg;  /// paint the leader in leaderFg instead of muted gutterFg
    RgbColor barFg;    /// quote-bar override color (when hasBarFg)
    bool hasBarFg;     /// paint all this line's quote bars in barFg (callout accent)
    /// 0-based source (physical) line this visual line came from.
    size_t srcLine;
    /// Gutter shows `srcLine+1` — true only on the first visual row of a wrapped
    /// physical line (continuations are blank).
    bool showNumber;
    /// Source column this visual row starts at (raw view; for remapping search
    /// matches onto wrapped lines).
    int wrapColOffset;
    /// Index into the model's `fences` when this is a code-header line — the code
    /// block whose body the header's copy button copies; -1 otherwise.
    int copyFence = -1;
    /// Block-granular selection span: the source byte range a **text-regime** drag
    /// crossing this whole line selects. Set on table lines (`TBL4`) so a drag that
    /// starts outside a table still covers its markdown source; `size_t.max` ⇒ use
    /// the per-run `srcStart` (char-level — prose, code, and ANSI cells).
    size_t selSrcStart = size_t.max;
    size_t selSrcEnd;
    /// Index of the table this line belongs to (into `WrappedPreview.tables`), or
    /// -1. A drag starting on a table line uses the 2D grid regime (`TBL`).
    int tableIndex = -1;
    /// Index of the table whose whole-table **copy button** sits in this line's
    /// top-border cutout (into `WrappedPreview.tables`), or -1. Mirrors `copyFence`.
    int copyTable = -1;
    PreviewRun[] runs;
}

/// Per-fence highlight data, resolved once (theme-independent).
struct CodeFence
{
    const(char)[] lang;      /// canonicalized language ("" if none)
    const(char)[] label;     /// info-string remainder (e.g. "[file.d]")
    bool isAnsi;             /// a ` ```ansi ` fence → decoded, not highlighted
    const(char)[] body;      /// the code_fence_content bytes
    size_t bodyStart;        /// source byte offset of `body` (for line numbering)
    HighlightEvent[] events; /// highlight events over `body` (when !isAnsi)
    AnsiLine[] ansi;         /// decoded styled lines (when isAnsi)
}

/// The built preview model. `present` is false for a non-markdown file (the
/// caller keeps the raw view).
struct PreviewModel
{
    bool present;
    MdDoc doc;
    CodeFence[] fences; /// in document order, parallel to the codeFence blocks
}

// ── Stage 1: build (@system, once) ───────────────────────────────────────────

/**
Parse `source` as markdown and resolve every fenced code block's contents.
Grammars come from `registry`; per-fence highlighting reuses `cache` (the same
`TsConfigCache` the whole-file path uses). `@system`, GC-allocating — call once
at file load.

`decodeAnsiFn`, when passed, decodes a ` ```ansi ` fence into styled
`AnsiLine[]` (the GUI supplies `gui_ansi.decodeAnsi`, an off-screen libghostty-vt
bridge). When omitted (the terminal / HTML paths and the ghostty-free `no-gui`
build), an ansi fence keeps its raw body and `layoutPreview` strips the SGR to
plain text — so this module never depends on `sparkles:ghostty`. The parameter is
a `static if`-guarded template argument, so the no-decoder instantiation compiles
without any reference to a decoder.
*/
PreviewModel buildPreviewModel(Decode = typeof(null))(ref GrammarRegistry registry,
    ref TsConfigCache cache, scope const(char)[] source, Decode decodeAnsiFn = null) @system
{
    PreviewModel m;
    m.doc = extractMarkdown(registry, source);
    m.present = true;
    collectFences(m.doc.root, source, cache, m.fences, decodeAnsiFn);
    return m;
}

private void collectFences(Decode)(in MdBlock b, scope const(char)[] source,
    ref TsConfigCache cache, ref CodeFence[] fences, Decode decodeAnsiFn) @system
{
    if (b.kind == MdBlockKind.codeFence)
    {
        CodeFence f;
        f.lang = canonicalLanguage(b.infoLang);
        f.label = b.label;
        f.body = source[b.codeBody.start .. b.codeBody.end];
        f.bodyStart = b.codeBody.start;
        if (f.lang == "ansi")
        {
            f.isAnsi = true;
            static if (!is(Decode == typeof(null)))
                f.ansi = decodeAnsiFn(f.body); // GUI: off-screen VT decode
            // else: no decoder — layoutPreview strips the SGR to plain text.
        }
        else
        {
            SmallBuffer!HighlightEvent ev;
            auto r = highlightInjected(cache, f.lang, f.body, ev);
            f.events = r.hasError
                ? [HighlightEvent.sourceSpan(0, f.body.length)] : ev[].dup;
        }
        fences ~= f;
    }
    foreach (ref c; b.children)
        collectFences(c, source, cache, fences, decodeAnsiFn);
}

// ── Stage 2: layout ──────────────────────────────────────────────────────────
//
// Split into a width-INDEPENDENT flatten (`flattenPreview`) and a width-DEPENDENT
// wrap (`wrapPreview`). The GUI caches the flattened `PreviewDoc` per theme and
// re-wraps it on resize / font-size / gutter toggles, so a resize no longer
// re-does inline flattening, prose tokenization, or code highlighting — the
// dominant per-frame cost — and pays only the wrap.

/// The kind of a $(LREF PreviewItem); selects which of its fields are meaningful.
enum ItemKind : ubyte
{
    flow,  /// prose / heading / list-item / callout line: width-independent `words`
    code,  /// a fenced code block: pre-highlighted, unwrapped `codeLines`
    table, /// a table: the flattened `grid` + `aligns`
    rule,  /// a thematic break
    html,  /// a raw HTML line (one prebuilt, non-wrapping line)
    blank, /// a spacer
}

/**
Build the raw highlighted-source view as wrapped $(LREF PreviewLine)s: each source
line's styled runs (from `events`) are hard-wrapped to `widthCols`, tagged with the
source line number (`showNumber` on the first wrapped row only, so a wrapped
physical line is numbered once) and the source column each visual row starts at
(`wrapColOffset`, for remapping search matches). Reuses the preview's draw path.
*/
PreviewLine[] buildRawPlines(const(char)[] source, const(HighlightEvent)[] events,
    ResolvedTheme theme, RgbColor pageFg, RgbColor pageBg, int widthCols) @safe
{
    const w = widthCols < 1 ? 1 : widthCols;
    const n = lineCount(source);
    auto byLine = new PreviewRun[][](n);
    foreach (ls; byStyledLine(source, events))
    {
        if (ls.line >= n)
            continue;
        const spec = theme[ls.span.label];
        byLine[ls.line] ~= PreviewRun(source[ls.span.start .. ls.span.end],
            toRgb(spec.fg, pageFg), toRgb(spec.bg, pageBg), spec.bg.isSet,
            mapSpecAttrs(spec), ls.span.start);
    }

    PreviewLine[] out_;
    foreach (li, row; byLine)
    {
        int colOff;
        bool first = true;
        foreach (wl; hardWrapRuns(row, w))
        {
            out_ ~= PreviewLine(srcLine: li, showNumber: first, wrapColOffset: colOff, runs: wl);
            foreach (r; wl)
                colOff += cast(int) columnWidth(r.text);
            first = false;
        }
    }
    return out_;
}

/// The number of distinct nested-quote gutter-bar colors before the cycle repeats.
enum quoteBarCycle = 4;

/**
Theme-derived colors for nested block-quote gutter bars, indexed by depth (mod
$(LREF quoteBarCycle)). Exposed for the painter (`gui.d`), which draws the bars
but has no access to the layouter's resolved palette. Pure — recomputed per theme.
*/
RgbColor[quoteBarCycle] quoteBarColors(ResolvedTheme theme, RgbColor pageFg, RgbColor pageBg) @safe
{
    RgbColor role(string name, RgbColor fallback)
    {
        const spec = theme[theme.labels.resolve(name)];
        return toRgb(spec.fg, fallback);
    }
    const quoteFg = role("markup.quote", mix(pageFg, pageBg, 0.35));
    return [
        quoteFg,
        role("function", quoteFg),
        role("string", quoteFg),
        role("keyword", quoteFg),
    ];
}

// ── Stage 2b: wrap (width-dependent — the resize hot path) ────────────────────

// ── small pure helpers ───────────────────────────────────────────────────────

// An in-panel code-line-number gutter cell: `num` right-aligned in `gw-1` columns
// plus a trailing separator space, or all spaces on a wrapped continuation row.
// Map a syntax `StyleSpec`'s attributes onto the `gui_ansi.Attr` bits the preview
// runs use. Shared by the Flattener and the raw-view builder.
private ubyte mapSpecAttrs(in StyleSpec spec) @safe
{
    ubyte a;
    if (spec.attrs.has(TextAttr.bold)) a |= Attr.bold;
    if (spec.attrs.has(TextAttr.italic)) a |= Attr.italic;
    if (spec.attrs.has(TextAttr.strikethrough)) a |= Attr.strikethrough;
    if (spec.underline != UnderlineStyle.none) a |= Attr.underline;
    return a;
}

// Hard-wrap a code/ANSI line's styled runs to `width` display columns, splitting
// runs at the column boundary (code has long unbreakable tokens, so break on any
// codepoint rather than word boundaries). Returns one run list per wrapped line;
// an empty input yields a single empty line (a blank code row).
private PreviewRun[][] hardWrapRuns(const(PreviewRun)[] runs, int width) @safe
{
    import std.utf : decode;
    if (width < 1)
        width = 1;
    PreviewRun[][] lines;
    PreviewRun[] cur;
    int col;
    foreach (r; runs)
    {
        size_t segStart, i;
        // The split piece keeps its byte offset into the original run (added to the
        // run's srcStart) so selection still maps to the right file bytes.
        size_t pieceSrc(size_t off) => r.srcStart == size_t.max ? size_t.max : r.srcStart + off;
        while (i < r.text.length)
        {
            const cpStart = i;
            decode(r.text, i); // advance one codepoint
            const cw = cast(int) columnWidth(r.text[cpStart .. i]);
            if (col + cw > width && col > 0)
            {
                if (cpStart > segStart)
                    cur ~= PreviewRun(r.text[segStart .. cpStart], r.fg, r.bg, r.hasBg,
                        r.attrs, pieceSrc(segStart));
                lines ~= cur;
                cur = null;
                col = 0;
                segStart = cpStart;
            }
            col += cw;
        }
        if (r.text.length > segStart)
            cur ~= PreviewRun(r.text[segStart .. $], r.fg, r.bg, r.hasBg, r.attrs,
                pieceSrc(segStart));
    }
    if (cur.length || lines.length == 0)
        lines ~= cur;
    return lines;
}

private bool startsWithText(const(char)[] s, const(char)[] prefix) @safe pure nothrow @nogc
    => s.length >= prefix.length && s[0 .. prefix.length] == prefix;

private bool isBoxDrawing(dchar cp) @safe pure nothrow @nogc
    => cp >= 0x2500 && cp <= 0x257F;

// Strip ANSI escape sequences (CSI `ESC[…<final>`, OSC `ESC]…(BEL|ST)`, and other
// two-byte `ESC<x>`) from `s`, keeping printable text and newlines. Used to
// degrade a ` ```ansi ` fence to plain text when no off-screen VT is available to
// decode it (terminal / HTML paths, `no-gui` build).
string stripSgr(scope const(char)[] s) @safe pure nothrow
{
    auto r = new char[s.length];
    size_t n, i;
    while (i < s.length)
    {
        if (s[i] == '\x1b' && i + 1 < s.length)
        {
            i = skipAnsiEscape(s, i);
            continue;
        }
        r[n++] = s[i++];
    }
    return (() @trusted => cast(string) r[0 .. n])();
}

// Advance past the ANSI escape starting at `s[i] == ESC`, returning the index
// just after it: CSI (`ESC[…<final @-~>`), OSC (`ESC]…<BEL|ST>`), or a two-byte
// `ESC<x>`. On a lone trailing ESC returns `i + 1`.
private size_t skipAnsiEscape(scope const(char)[] s, size_t i) @safe pure nothrow @nogc
{
    if (i + 1 >= s.length)
        return i + 1;
    const c = s[i + 1];
    if (c == '[') // CSI: params until a final byte in @…~
    {
        i += 2;
        while (i < s.length && !(s[i] >= '@' && s[i] <= '~'))
            ++i;
        return i < s.length ? i + 1 : i;
    }
    if (c == ']') // OSC: until BEL or ST (ESC \)
    {
        i += 2;
        while (i < s.length && s[i] != '\x07' && s[i] != '\x1b')
            ++i;
        if (i < s.length && s[i] == '\x07')
            return i + 1;
        if (i + 1 < s.length && s[i] == '\x1b')
            return i + 2;
        return i;
    }
    return i + 2; // other two-byte escape
}

private bool containsText(const(char)[] hay, const(char)[] needle) @safe pure nothrow @nogc
{
    if (needle.length == 0 || needle.length > hay.length)
        return needle.length == 0;
    foreach (i; 0 .. hay.length - needle.length + 1)
        if (hay[i .. i + needle.length] == needle)
            return true;
    return false;
}


// ── tests ────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.syntax : Span, resolveTheme, LabelSet, builtinDark;

    private ResolvedTheme darkTheme() @safe
        => resolveTheme(builtinDark, LabelSet.standard());

    private enum RgbColor tPageFg = RgbColor(0xcd, 0xd6, 0xf4);
    private enum RgbColor tPageBg = RgbColor(0x1e, 0x1e, 0x2e);

    // Register one relayout case. The state lives in a heap struct captured by
    // pointer, so the deferred `benchCase` closure shares stable storage (a
    // body-local / `foreach` variable is one shared slot under deferred
    // execution; capturing the large model/theme aggregates by value segfaults).
    // Heap state whose measured `run` is bound as a method delegate — its context
    // pointer IS the GC-owned `St`, so (unlike a stack-captured closure literal,
    // which `benchCase`'s deferred execution turns into a dangling stack read) it
    // stays valid until the case is measured.
    // Times the widget-path resize rebuild — view → layout → display list at
    // one width, exactly what the interactive backends re-run per settled
    // resize (`rebuildMd`).
    private static struct RebuildState
    {
        import sparkles.syntax.md.model : MdDoc;
        import sparkles.syntax.md.render_widgets : MdViewOptions;

        MdDoc doc;
        MdViewOptions opt;
        int w;
        size_t run()
        {
            import sparkles.syntax.md.render_widgets : viewMarkdown;
            import sparkles.test_runner.bench : blackBox;
            import sparkles.ui.display_list : buildDisplayList;
            import sparkles.ui.geometry : Constraints;
            import sparkles.ui.layout : layout;
            import sparkles.ui.style : defaultTwoslashPalette;

            auto tree = viewMarkdown(doc, opt);
            auto frames = layout(tree, Constraints(maxW: w));
            return blackBox(buildDisplayList(tree, frames,
                defaultTwoslashPalette(), tPageFg, tPageBg).length);
        }
    }

    private void registerRebuildCase(PreviewModel m, ResolvedTheme theme, int w)
    {
        import sparkles.syntax.md.render_widgets : MdViewOptions, MdViewTheme;
        import sparkles.test_runner.bench : benchCase;
        import std.conv : text;

        MdViewOptions opt = {theme: MdViewTheme.derive(theme, tPageFg, tPageBg)};
        auto st = new RebuildState(m.doc, opt, w);
        benchCase(name: text("w=", st.w), labels: ["op": "rebuild"],
            timed: &st.run, after: (ref size_t _) {});
    }
}

// The window-resize hot path: the interactive backends rebuild the markdown
// widget pipeline (view → layout → display list) once per settled width.
// Benchmark that rebuild across a width sweep on a real document
// (`HUE_BENCH_FILE`, else the committed `docs/specs/base/text/index.md`). The
// tree-sitter model build is setup (not measured).
@("gui_preview.layout.resizeSweep")
@benchmark
@system
unittest
{
    import std.process : environment;
    import std.file : exists, readText;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax : GrammarRegistry, TsConfigCache, LabelSet;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    const path = environment.get("HUE_BENCH_FILE", "../../docs/specs/base/text/index.md");
    if (!path.exists)
        skipTest("bench doc not found: " ~ path ~ " (set HUE_BENCH_FILE)");
    const source = readText(path);

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    auto model = buildPreviewModel(reg, cache, source); // one-time (no ansi decoder)
    const theme = darkTheme();

    // A resize drag walks the column count; each settled stop rebuilds the
    // widget pipeline at the new width.
    foreach (w; [40, 60, 80, 100, 120, 160])
        registerRebuildCase(model, theme, w);
}

@("gui_preview.build.fencesAndBands")
@system
unittest
{
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax : GrammarRegistry, TsConfigCache, LabelSet;
    import std.algorithm.searching : any, canFind;

    import gui_ansi : decodeAnsi;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    const src = "# Title\n\nPara **bold** and `code`.\n\n- a\n- b\n\n> quote\n\n"
        ~ "| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n"
        ~ "```d\nvoid main() {}\n```\n\n```ansi\n\x1b[31mred\x1b[0m\n```\n";

    // The GUI supplies the off-screen-VT decoder for ` ```ansi ` fences.
    // (The rendering itself is the markdown widget view's responsibility —
    // covered by sparkles.syntax.md.render_widgets' tests.)
    auto m = buildPreviewModel(reg, cache, src, &decodeAnsi);
    assert(m.present);
    assert(m.fences.length == 2);
    assert(!m.fences[0].isAnsi && m.fences[0].lang == "d");
    assert(m.fences[0].events.length > 0);
    assert(m.fences[1].isAnsi && m.fences[1].ansi.length == 1);
    assert(m.doc.root.children.length >= 6); // heading/para/list/quote/table/…
}

@("gui_preview.build.ansiFenceStrippedWithoutDecoder")
@system
unittest
{
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax : GrammarRegistry, TsConfigCache, LabelSet;
    import std.algorithm.searching : any, canFind;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    const src = "```ansi\n\x1b[31mred\x1b[0m text\n```\n";

    // No decoder passed (the terminal / HTML paths and the `no-gui` build):
    // the ansi fence keeps its raw body — the fence renderers strip its SGR
    // at view time (hueFenceRenderer).
    auto m = buildPreviewModel(reg, cache, src);
    assert(m.fences.length == 1);
    assert(m.fences[0].isAnsi && m.fences[0].ansi.length == 0);
    assert(stripSgr(m.fences[0].body).canFind("red text"));
}
