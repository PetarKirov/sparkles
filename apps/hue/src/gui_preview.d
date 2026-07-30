// The markdown-preview model for hue: parse the document structure and
// resolve every fenced code block's contents once at file load
// (`buildPreviewModel`), plus the small theme-derived helpers the widget
// views and painters share (`quoteBarColors`, `stripSgr`). All raylib-free;
// rendering is the composable widget views' job (sparkles.syntax.md.render_widgets).
module gui_preview;

import ansi_model : AnsiLine;

import sparkles.syntax : MdDoc, MdBlock, MdBlockKind, HighlightEvent,
    ResolvedTheme, toRgb, RgbColor, GrammarRegistry, TsConfigCache,
    canonicalLanguage, extractMarkdown, highlightInjected;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.term_color : mix;
import sparkles.test_runner.attributes : benchmark;

// ── Presentation model ───────────────────────────────────────────────────────

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
