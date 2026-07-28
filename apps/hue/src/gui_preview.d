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
import sparkles.core_cli.ui.table : MappedTable, TableGridMap, drawTableMapped;
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
A width-independent, theme-resolved layout item. $(LREF wrapPreview) turns each
into one or more $(LREF PreviewLine)s at a given width. A flat tagged POD (not a
`SumType`): only the fields named for `kind` carry meaning. Everything expensive
and width-independent — inline flattening, prose tokenization into `words`, code
highlighting, table-grid flattening — is precomputed here so a resize replays
only the wrap.
*/
struct PreviewItem
{
    ItemKind kind;
    int indentCols;
    ubyte qdepth;
    size_t srcLine;
    bool number;      /// the item's first emitted line carries the gutter number
    RgbColor barFg;   /// callout accent bar (any kind, inside a callout body)
    bool hasBarFg;

    // flow
    Word[] words;     /// pre-tokenized, width-independent
    string leader;
    RgbColor leaderFg;
    bool hasLeaderFg;
    BandKind band;
    RgbColor bandBg;

    // code
    string codeLabel;         /// devicon + language + info label for the header
    PreviewRun[][] codeLines; /// per body line, unwrapped highlighted runs
    size_t[] codeSrcLines;    /// parallel to codeLines: each body line's source line
    int copyFence = -1;

    // table
    string[][] grid;
    const(ColAlign)[] aligns;
    size_t blockStart, blockEnd; /// the table's source byte span (text-regime cross, TBL4)

    // html
    PreviewRun[] preRuns;     /// one prebuilt line's runs (emitted unwrapped)
}

/**
A flattened preview document: the width-independent $(LREF PreviewItem) stream
plus the wrap-time palette colors (resolved once at flatten). Built by
$(LREF flattenPreview) and consumed by $(LREF wrapPreview); the GUI caches one of
these per theme and re-wraps it on every resize.
*/
struct PreviewDoc
{
    PreviewItem[] items;
    const(char)[] source; /// retained so callers can map selections back to file bytes
    // Palette colors the wrap pass needs (frame borders, code panel, table text).
    RgbColor ruleFg, codePanelBg, codeFg, codeLineNoFg, pageFg;
}

/// A rendered table's on-screen placement + selection map (`TBL3`). `firstLine`
/// is the index into `WrappedPreview.lines` where the table's lines begin; a
/// `PreviewLine.tableIndex` points into `WrappedPreview.tables`. The `map` hit-
/// tests screen `(outLine = plineIndex - firstLine, x)` and reads cell text.
struct TableView
{
    int firstLine;
    int lineCount;
    TableGridMap map;
}

/// The result of $(LREF wrapPreview): the painted lines plus the per-table maps
/// the GUI needs for 2D table selection. (`layoutPreview` returns just `.lines`.)
struct WrappedPreview
{
    PreviewLine[] lines;
    TableView[] tables;
}

/**
Flatten `m` into painted lines for `theme`, resolving colors against
`pageFg`/`pageBg` and soft-wrapping to `widthCols`. Kept as the composition of
$(LREF flattenPreview) and $(LREF wrapPreview) — the previous one-shot signature,
for callers (and tests) that don't cache. Pure.
*/
PreviewLine[] layoutPreview(PreviewModel m, ResolvedTheme theme,
    RgbColor pageFg, RgbColor pageBg, int widthCols, bool codeLineNumbers = true) @safe
    => wrapPreview(flattenPreview(m, theme, pageFg, pageBg), widthCols, codeLineNumbers).lines;

/**
Stage 2a — the width-INDEPENDENT flatten. Runs the block recursion, resolving
theme colors and precomputing every width-independent input to the wrap (prose
tokenized into `words`, code highlighted, tables flattened). Rerun only when the
theme or the document changes — never on resize. Pure.
*/
PreviewDoc flattenPreview(PreviewModel m, ResolvedTheme theme,
    RgbColor pageFg, RgbColor pageBg) @safe
{
    auto fl = Flattener(source: m.doc.source, theme: theme, pageFg: pageFg,
        pageBg: pageBg, fences: m.fences);
    fl.resolvePalette();
    fl.buildLineStarts();
    foreach (ref b; m.doc.root.children)
        fl.block(b, 0, 0);
    return PreviewDoc(items: fl.items, source: m.doc.source,
        ruleFg: fl.ruleFg, codePanelBg: fl.codePanelBg, codeFg: fl.codeFg,
        codeLineNoFg: fl.codeLineNoFg, pageFg: fl.pageFg);
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

private struct Flattener
{
    const(char)[] source;
    ResolvedTheme theme;
    RgbColor pageFg, pageBg;
    const(CodeFence)[] fences;

    PreviewItem[] items;
    size_t fenceIdx;
    int listDepth; // current list nesting (1-based inside list(); 0 outside)

    // Source-line numbering: `curSrcLine`/`pendingNumber` are set by `beginLine`
    // right before a logical line's content; `emit` stamps every item with
    // `curSrcLine` and gives the first item after `beginLine` the number.
    size_t[] lineStarts;
    size_t curSrcLine;
    bool pendingNumber;

    // Resolved role colors (from the theme's markup.* labels, page-fallback).
    RgbColor headingFg, codeFg, linkFg, quoteFg;
    RgbColor codePanelBg, codeHeaderBg, ruleFg, inlineCodeBg, codeLineNoFg;
    // Accent hues borrowed from syntax roles (theme-derived, page-fallback), used
    // for heading levels, checkbox green, and callout accents.
    RgbColor accentBlue, accentGreen, accentRed, accentYellow, accentPurple;
    RgbColor[6] headingAccents; /// per heading level (index = level-1)

    void resolvePalette() @safe
    {
        RgbColor role(string name, RgbColor fallback)
        {
            const spec = theme[theme.labels.resolve(name)];
            return toRgb(spec.fg, fallback);
        }
        headingFg = role("markup.heading", pageFg);
        codeFg = role("markup.raw", pageFg);
        linkFg = role("markup.link", pageFg);
        quoteFg = role("markup.quote", mix(pageFg, pageBg, 0.35));
        codePanelBg = mix(pageBg, pageFg, 0.08);
        codeHeaderBg = mix(pageBg, pageFg, 0.16);
        inlineCodeBg = mix(pageBg, pageFg, 0.12);
        ruleFg = mix(pageBg, pageFg, 0.4);
        codeLineNoFg = mix(codePanelBg, codeFg, 0.45); // dim in-panel code numbers

        // Syntax roles carry a stable-ish hue across themes: functions blue,
        // strings green, numbers red/orange, types yellow, keywords purple.
        accentBlue = role("function", linkFg);
        accentGreen = role("string", RgbColor(0x40, 0xc0, 0x60));
        accentRed = role("number", RgbColor(0xe0, 0x60, 0x50));
        accentYellow = role("type", RgbColor(0xd8, 0xb0, 0x40));
        accentPurple = role("keyword", RgbColor(0xb0, 0x70, 0xd0));
        headingAccents = [
            headingFg, accentBlue, accentPurple, accentGreen, accentYellow, accentRed,
        ];
    }

    const(char)[] slice(size_t a, size_t b) @safe
        => a <= b && b <= source.length ? source[a .. b] : "";

    // Byte offset of each source line's start (for byte → line-number lookup).
    void buildLineStarts() @safe
    {
        lineStarts = [0];
        foreach (i, c; source)
            if (c == '\n')
                lineStarts ~= i + 1;
    }

    // The 0-based source line containing byte `off`.
    size_t srcLineOf(size_t off) @safe
    {
        size_t lo, hi = lineStarts.length;
        while (lo < hi)
        {
            const mid = (lo + hi) / 2;
            if (lineStarts[mid] <= off)
                lo = mid + 1;
            else
                hi = mid;
        }
        return lo == 0 ? 0 : lo - 1;
    }

    // Mark the source line for the next logical line's content; its first pushed
    // visual row carries the gutter number, wrapped continuations do not.
    void beginLine(size_t off) @safe
    {
        curSrcLine = srcLineOf(off);
        pendingNumber = true;
    }

    // Stamp `it` with the current source line + gutter-number flag and append it.
    void emit(PreviewItem it) @safe
    {
        it.srcLine = curSrcLine;
        if (pendingNumber)
        {
            it.number = true;
            pendingNumber = false;
        }
        items ~= it;
    }

    void blank() @safe { items ~= PreviewItem(kind: ItemKind.blank); } // spacer

    void block(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        // Number this block by its source line; multi-line blocks (list, code)
        // re-mark per sub-line below.
        beginLine(b.span.start);
        final switch (b.kind) with (MdBlockKind)
        {
        case document:
            foreach (ref c; b.children)
                block(c, indent, qdepth);
            break;
        case heading:
            this.heading(b, indent, qdepth);
            break;
        case paragraph:
            flow(inlineRuns(b.inlines, pageFg, 0), indent, qdepth, "");
            blank();
            break;
        case codeFence:
            this.codeFence(indent, qdepth);
            break;
        case blockQuote:
            this.blockQuote(b, indent, qdepth);
            break;
        case list:
            this.list(b, indent, qdepth);
            break;
        case thematicBreak:
            this.rule(indent, qdepth);
            break;
        case table:
            this.table(b, indent, qdepth);
            break;
        case htmlBlock:
            this.htmlBlock(b, indent, qdepth);
            break;
        // These never appear at block level (only inside a list/table).
        case listItem:
        case tableRow:
        case tableCell:
            break;
        }
    }

    void heading(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        // Per-level MDI section glyphs (nf-md-format-header-1..6), each painted in
        // that level's accent; the heading text takes the same accent (bold) and a
        // subtle full-width band tints the line by level.
        static immutable string[6] icons = [
            "\U000F0CA1", "\U000F0CA3", "\U000F0CA5",
            "\U000F0CA7", "\U000F0CA9", "\U000F0CAB",
        ];
        const lvl = b.level < 1 ? 1 : (b.level > 6 ? 6 : b.level);
        const accent = headingAccents[lvl - 1];
        const band = mix(pageBg, accent, 0.12);
        flow(inlineRuns(b.inlines, accent, Attr.bold), indent, qdepth,
            icons[lvl - 1] ~ " ", leaderFg: accent, hasLeaderFg: true,
            band: BandKind.heading, bandBg: band);
        blank();
    }

    // A block quote, or — when its first line is a GitHub `[!TYPE]` marker — a
    // callout/admonition: a titled, iconed block with an accent gutter bar.
    void blockQuote(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        Callout co;
        if (detectCallout(b, co))
        {
            renderCallout(b, co, indent, qdepth);
            return;
        }
        foreach (ref c; b.children)
            block(c, indent, cast(ubyte)(qdepth + 1));
    }

    // Recognize `> [!NOTE]` (and TIP/IMPORTANT/WARNING/CAUTION) on the quote's
    // first paragraph. Detection reads the paragraph's raw source (not the parsed
    // inlines: `[!NOTE]` parses as a *shortcut link*, not text). `markerLen` is
    // the byte length of `[!TYPE]` (incl. any leading space) to strip from the
    // rendered body.
    bool detectCallout(in MdBlock b, out Callout co) @safe
    {
        const(MdBlock)* p;
        foreach (ref c; b.children)
            if (c.kind == MdBlockKind.paragraph)
            {
                p = &c;
                break;
            }
        if (p is null)
            return false;

        const txt = slice(p.span.start, p.span.end);
        size_t i;
        while (i < txt.length && (txt[i] == ' ' || txt[i] == '\t'))
            ++i;
        if (i + 2 >= txt.length || txt[i] != '[' || txt[i + 1] != '!')
            return false;
        const s = i + 2;
        size_t e = s;
        while (e < txt.length && txt[e] != ']')
            ++e;
        if (e >= txt.length || !matchCalloutType(txt[s .. e], co))
            return false;
        co.markerLen = e + 1; // through the closing `]` (incl. leading ws)
        return true;
    }

    bool matchCalloutType(const(char)[] type, out Callout co) @safe
    {
        switch (upperAscii(type))
        {
        case "NOTE": co = Callout("\U000F02FD", accentBlue, "Note"); return true;      // 󰋽
        case "TIP": co = Callout("\U000F0336", accentGreen, "Tip"); return true;       // 󰌶
        case "IMPORTANT": co = Callout("\U000F017E", accentPurple, "Important"); return true; // 󰅾
        case "WARNING": co = Callout("\U000F002A", accentYellow, "Warning"); return true;     // 󰀪
        case "CAUTION": co = Callout("\U000F0CE6", accentRed, "Caution"); return true;        // 󰳦
        default: return false;
        }
    }

    void renderCallout(in MdBlock b, Callout co, int indent, ubyte qdepth) @safe
    {
        const bodyDepth = cast(ubyte)(qdepth + 1);
        // Title line: icon + Title-case type, in the accent (bold). The accent bar
        // is applied to the title + every body item below.
        const start = items.length;
        flow([PreviewRun(co.title, co.accent, RgbColor.init, false, Attr.bold)],
            indent, bodyDepth, co.icon ~ " ", leaderFg: co.accent, hasLeaderFg: true);

        // Body: the quoted blocks, with the `[!TYPE]` marker dropped from the
        // first paragraph (it parses as a leading link/text inline).
        bool firstPara = true;
        foreach (ref c; b.children)
        {
            if (c.kind == MdBlockKind.paragraph && firstPara)
            {
                firstPara = false;
                const cutoff = c.span.start + co.markerLen;
                auto trimmed = trimLeadingBytes(c.inlines, cutoff);
                // Number the body by where its text actually starts (the line
                // after the `[!TYPE]` marker), not the marker's line.
                beginLine(trimmed.length ? trimmed[0].span.start : cutoff);
                flow(inlineRuns(trimmed, pageFg, 0), indent, bodyDepth, "");
                blank();
            }
            else
                block(c, indent, bodyDepth);
        }
        foreach (ref it; items[start .. $])
        {
            it.hasBarFg = true;
            it.barFg = co.accent;
        }
        blank();
    }

    void codeFence(int indent, ubyte qdepth) @safe
    {
        if (fenceIdx >= fences.length)
            return;
        const f = fences[fenceIdx++];
        const baseLine = srcLineOf(f.bodyStart);

        // The devicon + language label for the header (width-independent). The box
        // framing (`╭─ … ╮`, `│ … │`, `╰──╯`), gutter, and wrapping are the wrap
        // pass's job; here we just resolve the per-body-line highlighted runs.
        const icon = langIcon(f.lang);
        string lbl = (icon.length ? icon ~ " " : "") ~ (f.lang.length ? f.lang.idup : "code");
        if (f.label.length)
            lbl ~= " " ~ f.label.idup;

        PreviewRun[][] codeLines;
        size_t[] srcLines;
        void addLine(size_t bodyRow, PreviewRun[] row)
        {
            codeLines ~= row;
            srcLines ~= baseLine + bodyRow;
        }

        const decoded = f.isAnsi && f.ansi.length;
        if (decoded)
        {
            // Cell-granular ANSI selection (SEL6): the off-screen VT is 1:1 with
            // source lines, and each decoded span's text is the contiguous source
            // between two escapes, so map each span back to its source bytes via
            // `ansiColToSrc` over the raw source line. Selectable like code — the
            // `│`/gutter/padding runs (no srcStart) stay excluded.
            size_t lineStart; // byte offset of the current source line in f.body
            foreach (i, ref al; f.ansi)
            {
                size_t lineEnd = lineStart;
                while (lineEnd < f.body.length && f.body[lineEnd] != '\n')
                    ++lineEnd;
                auto colSrc = ansiColToSrc(f.body[lineStart .. lineEnd]);

                PreviewRun[] runs;
                size_t col;
                foreach (ref sp; al.spans)
                {
                    const off = col < colSrc.length ? colSrc[col] : (lineEnd - lineStart);
                    runs ~= PreviewRun(sp.text, sp.fgDefault ? pageFg : sp.fg,
                        sp.bg, !sp.bgDefault, sp.attrs, f.bodyStart + lineStart + off);
                    col += columnWidth(sp.text);
                }
                addLine(i, runs);
                lineStart = lineEnd < f.body.length ? lineEnd + 1 : lineEnd;
            }
        }
        else if (f.isAnsi)
        {
            // No off-screen VT decoder (terminal / HTML paths, `no-gui` build):
            // strip the SGR escapes and render the fence as plain code lines.
            const plainTxt = stripSgr(f.body);
            size_t bodyRow, lineStart;
            foreach (i, char c; plainTxt)
                if (c == '\n')
                {
                    addLine(bodyRow++, [PreviewRun(plainTxt[lineStart .. i], codeFg,
                        RgbColor.init, false, 0)]);
                    lineStart = i + 1;
                }
            if (lineStart < plainTxt.length)
                addLine(bodyRow, [PreviewRun(plainTxt[lineStart .. $], codeFg,
                    RgbColor.init, false, 0)]);
        }
        else
        {
            const n = lineCount(f.body);
            auto byLine = new PreviewRun[][](n);
            foreach (ls; byStyledLine(f.body, f.events))
            {
                if (ls.line >= n)
                    continue;
                const spec = theme[ls.span.label];
                // Only paint a per-token background when the theme gives this
                // token a background distinct from the page default — an
                // unlabeled run resolves to `defaults`, whose bg IS the page bg,
                // and drawing that over the (lighter) code panel bleeds dark
                // boxes. The panel band already provides the backdrop.
                const bg = toRgb(spec.bg, pageBg);
                const hasBg = spec.bg.isSet && bg != pageBg;
                byLine[ls.line] ~= PreviewRun(f.body[ls.span.start .. ls.span.end],
                    toRgb(spec.fg, codeFg), bg, hasBg, mapAttrs(spec), f.bodyStart + ls.span.start);
            }
            foreach (i, row; byLine)
                addLine(i, row);
        }

        pendingNumber = false; // the header carries no line number
        emit(PreviewItem(kind: ItemKind.code, indentCols: indent, qdepth: qdepth,
            codeLabel: lbl, codeLines: codeLines, codeSrcLines: srcLines,
            copyFence: cast(int)(fenceIdx - 1)));
        blank();
    }

    void list(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        static immutable string[4] bullets = ["●", "○", "◆", "◇"];
        ++listDepth;
        scope (exit) --listDepth;
        int ord = 1;
        foreach (ref item; b.children)
        {
            if (item.kind != MdBlockKind.listItem)
                continue;
            beginLine(item.span.start); // number each item by its source line

            // Leader: a Nerd checkbox (green when checked), an ordinal, or a
            // depth-cycled bullet.
            string leader;
            RgbColor leaderFg;
            bool hasLeaderFg;
            if (item.checkbox == 1)
            {
                leader = "\U000F0C52 "; // 󰱒 checked
                leaderFg = accentGreen;
                hasLeaderFg = true;
            }
            else if (item.checkbox == 0)
                leader = "\U000F0131 "; // 󰄱 unchecked
            else if (b.ordered)
            {
                import std.conv : text;
                leader = text(ord, ". ");
            }
            else
                leader = bullets[(listDepth - 1) % bullets.length] ~ " ";
            ++ord;

            // The item's first paragraph carries the leader; nested blocks indent.
            bool first = true;
            foreach (ref c; item.children)
            {
                if (c.kind == MdBlockKind.paragraph && first)
                {
                    flow(inlineRuns(c.inlines, pageFg, 0), indent, qdepth, leader,
                        leaderFg: leaderFg, hasLeaderFg: hasLeaderFg);
                    first = false;
                }
                else
                    block(c, indent + cast(int) columnWidth(leader), qdepth);
            }
            if (first) // an empty item still gets its marker (a leader-only line)
                flow([], indent, qdepth, leader,
                    leaderFg: leaderFg, hasLeaderFg: hasLeaderFg);
        }
        blank();
    }

    // Drop any inline fully within `[0, cutoff)` (an absolute byte offset) and
    // clip a straddling leading text inline — used to remove a callout's
    // `[!TYPE]` marker (which parses as a leading link/text inline) from the body.
    const(MdInline)[] trimLeadingBytes(in MdInline[] inlines, size_t cutoff) @safe
    {
        const(MdInline)[] kept;
        foreach (ref inl; inlines)
        {
            if (inl.span.end <= cutoff)
                continue;
            if (inl.span.start < cutoff && inl.kind == MdInlineKind.text)
            {
                kept ~= MdInline(kind: MdInlineKind.text,
                    span: Span(cutoff, inl.span.end));
            }
            else
                kept ~= inl;
        }
        return kept;
    }

    void table(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        // Flatten to a plain-text grid (cells are already flattened today, so no
        // inline styling is lost); the wrap pass hands it to core-cli's table
        // renderer for box-drawing borders + per-column alignment at the width.
        size_t cols;
        foreach (ref row; b.children)
            if (row.children.length > cols)
                cols = row.children.length;
        if (cols == 0)
            return;

        import std.string : strip;
        string[][] grid;
        foreach (ref row; b.children)
        {
            string[] cells;
            foreach (ref cell; row.children)
                cells ~= plain(cell.inlines).strip.idup;
            while (cells.length < cols) // pad ragged rows
                cells ~= "";
            grid ~= cells;
        }

        emit(PreviewItem(kind: ItemKind.table, indentCols: indent, qdepth: qdepth,
            grid: grid, aligns: b.aligns.dup, // dup: b is `scope`, item outlives it
            blockStart: b.span.start, blockEnd: b.span.end));
        blank();
    }

    void rule(int indent, ubyte qdepth) @safe
    {
        emit(PreviewItem(kind: ItemKind.rule, indentCols: indent, qdepth: qdepth));
        blank();
    }

    void htmlBlock(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        import std.string : splitLines;
        foreach (ln; slice(b.span.start, b.span.end).splitLines)
            emit(PreviewItem(kind: ItemKind.html, indentCols: indent, qdepth: qdepth,
                preRuns: [PreviewRun(ln.idup, mix(pageFg, pageBg, 0.35),
                    RgbColor.init, false, Attr.italic)]));
        blank();
    }

    // Flatten an inline tree into styled runs (unwrapped, in order).
    PreviewRun[] inlineRuns(in MdInline[] inlines, RgbColor fg, ubyte attrs) @safe
    {
        PreviewRun[] runs;
        foreach (ref inl; inlines)
        {
            final switch (inl.kind) with (MdInlineKind)
            {
            case text:
                runs ~= PreviewRun(slice(inl.span.start, inl.span.end), fg,
                    RgbColor.init, false, attrs, inl.span.start);
                break;
            case emphasis:
                runs ~= inlineRuns(inl.children, fg, cast(ubyte)(attrs | Attr.italic));
                break;
            case strong:
                runs ~= inlineRuns(inl.children, fg, cast(ubyte)(attrs | Attr.bold));
                break;
            case strikethrough:
                runs ~= inlineRuns(inl.children, fg, cast(ubyte)(attrs | Attr.strikethrough));
                break;
            case codeSpan:
                runs ~= PreviewRun(slice(inl.span.start, inl.span.end), codeFg,
                    inlineCodeBg, true, attrs, inl.span.start);
                break;
            case link:
                // A per-destination icon (github / web / mail / file), then the
                // underlined label.
                runs ~= PreviewRun(linkIcon(inl.linkDest) ~ " ", linkFg,
                    RgbColor.init, false, attrs);
                auto label = inl.children.length
                    ? inlineRuns(inl.children, linkFg, cast(ubyte)(attrs | Attr.underline))
                    : [PreviewRun(slice(inl.span.start, inl.span.end), linkFg,
                        RgbColor.init, false, cast(ubyte)(attrs | Attr.underline),
                        inl.span.start)];
                runs ~= label;
                break;
            case image:
                // 󰥶 image glyph (a Nerd Font monochrome icon — the previous 🖼
                // color emoji rasterizes as tofu under raylib/stb_truetype).
                const(char)[] alt = plain(inl.children);
                runs ~= PreviewRun("\U000F0976 " ~ alt ~ " → " ~ inl.linkDest,
                    linkFg, RgbColor.init, false, attrs);
                break;
            case lineBreak:
                runs ~= PreviewRun(" ", fg, RgbColor.init, false, attrs);
                break;
            }
        }
        return runs;
    }

    // Plain concatenated text of an inline subtree (for table cells / alt text).
    const(char)[] plain(in MdInline[] inlines) @safe
    {
        const(char)[] s;
        foreach (ref inl; inlines)
            s = inl.children.length ? s ~ plain(inl.children)
                : s ~ slice(inl.span.start, inl.span.end);
        return s;
    }

    ubyte mapAttrs(in StyleSpec spec) @safe => mapSpecAttrs(spec);

    // Tokenize `runs` into words and emit a width-independent `flow` item; the
    // wrap pass places the line breaks. A "word" is a maximal whitespace-free unit
    // that may span several runs (so a styled span touching punctuation —
    // `**bold**,` — stays one word with no stray space); breaks happen only where
    // the source had whitespace.
    void flow(PreviewRun[] runs, int indent, ubyte qdepth, string leader,
        RgbColor leaderFg = RgbColor.init, bool hasLeaderFg = false,
        BandKind band = BandKind.none, RgbColor bandBg = RgbColor.init) @safe
    {
        Word[] words;
        bool spacePending, open;
        foreach (r; runs)
        {
            size_t i;
            while (i < r.text.length)
            {
                if (isSpace(r.text[i]))
                {
                    spacePending = true;
                    open = false;
                    ++i;
                    continue;
                }
                const s = i;
                while (i < r.text.length && !isSpace(r.text[i]))
                    ++i;
                const frag = r.text[s .. i];
                if (!open)
                {
                    words ~= Word(spaceBefore: spacePending);
                    open = true;
                    spacePending = false;
                }
                // Carry the fragment's byte offset into the run so selection maps
                // back to the right file bytes.
                const fragSrc = r.srcStart == size_t.max ? size_t.max : r.srcStart + s;
                words[$ - 1].parts ~= PreviewRun(frag, r.fg, r.bg, r.hasBg, r.attrs, fragSrc);
                words[$ - 1].width += cast(int) columnWidth(frag);
            }
            // `open`/`spacePending` carry across the run boundary: a word joins
            // fragments from adjacent runs unless whitespace fell between them.
        }

        emit(PreviewItem(kind: ItemKind.flow, indentCols: indent, qdepth: qdepth,
            words: words, leader: leader, leaderFg: leaderFg, hasLeaderFg: hasLeaderFg,
            band: band, bandBg: bandBg));
    }
}

// ── Stage 2b: wrap (width-dependent — the resize hot path) ────────────────────

/**
Wrap the cached width-independent $(LREF PreviewDoc) to `widthCols` columns —
framing code blocks and tables, placing prose line breaks, drawing rules. This is
the only stage a resize / font-size change / gutter toggle re-runs.
`codeLineNumbers` toggles the in-panel code-number gutter. Pure.

A single `SmallBuffer!(PreviewRun)` scratch is reused across every emitted line
(cleared, refilled, then `.dup`'d once into `PreviewLine.runs`), so a relayout
allocates roughly one right-sized array per emitted line instead of a
`~=`-growth chain — the bulk of the old per-frame allocation churn.
*/
WrappedPreview wrapPreview(PreviewDoc doc, int widthCols, bool codeLineNumbers = true) @safe
{
    const width = widthCols < 8 ? 8 : widthCols;
    WrappedPreview wp;
    // Most items emit one line; flow/code emit a few. Reserve generously to dodge
    // growth reallocs without over-allocating.
    wp.lines.reserve(doc.items.length + doc.items.length / 2 + 8);
    PreviewRun[] scratch; // reused per emitted line (see takeRuns)
    foreach (ref it; doc.items)
    {
        final switch (it.kind) with (ItemKind)
        {
        case flow:  wrapFlow(it, width, scratch, wp.lines); break;
        case code:  wrapCode(it, width, codeLineNumbers, doc, scratch, wp.lines); break;
        case table: wrapTable(it, width, doc, wp); break;
        case rule:  wrapRule(it, width, doc, wp.lines); break;
        case html:  wp.lines ~= wrapHtmlLine(it); break;
        case blank: wp.lines ~= PreviewLine.init; break;
        }
    }
    return wp;
}

// Take the scratch buffer's contents as a freshly-owned run array and reset it
// for reuse. `assumeSafeAppend` lets the next line refill the same buffer in
// place, so a relayout allocates one right-sized array per emitted line instead
// of a `~=`-growth chain per line.
private PreviewRun[] takeRuns(ref PreviewRun[] scratch) @trusted
{
    auto r = scratch.dup;
    scratch.length = 0;
    scratch.assumeSafeAppend();
    return r;
}

// Wrap a prose/heading/list-item/callout item: place words into lines at the
// available width. The leader rides the first line; continuations hang-indent;
// the band spans every wrapped line; only the first line shows the gutter number.
private void wrapFlow(ref PreviewItem it, int width,
    ref PreviewRun[] scratch, ref PreviewLine[] lines) @safe
{
    const lead = cast(int) columnWidth(it.leader);
    const avail = width - it.indentCols - it.qdepth * 2 - lead;
    const a = avail < 4 ? 4 : avail;

    int col;
    bool firstLine = true;
    void flush()
    {
        lines ~= PreviewLine(indentCols: firstLine ? it.indentCols : it.indentCols + lead,
            quoteDepth: it.qdepth, band: it.band, bandBg: it.bandBg,
            leader: firstLine ? it.leader : "",
            leaderFg: it.leaderFg, hasLeaderFg: firstLine && it.hasLeaderFg,
            barFg: it.barFg, hasBarFg: it.hasBarFg,
            srcLine: it.srcLine, showNumber: firstLine && it.number,
            runs: takeRuns(scratch));
        col = 0;
        firstLine = false;
    }
    foreach (w; it.words)
    {
        if (col > 0 && col + (w.spaceBefore ? 1 : 0) + w.width > a)
            flush();
        if (col > 0 && w.spaceBefore)
        {
            scratch ~= PreviewRun(" ", w.parts[0].fg, RgbColor.init, false, 0);
            ++col;
        }
        foreach (p; w.parts)
        {
            scratch ~= p;
            col += cast(int) columnWidth(p.text);
        }
    }
    if (scratch.length || firstLine)
        flush();
}

// Frame a code block: a rounded box (`╭─ label ╮` header with a copy-button
// cutout, `│ … │` body rows with an optional in-panel number gutter, `╰──╯`
// footer). Body lines hard-wrap to the inner width; each is numbered by its
// document line (first wrapped row only).
private void wrapCode(ref PreviewItem it, int width, bool codeLineNumbers,
    ref PreviewDoc pal, ref PreviewRun[] scratch, ref PreviewLine[] lines) @safe
{
    const avail = width - it.indentCols - it.qdepth * 2;
    const boxW = avail < 4 ? 4 : avail; // total box width in columns
    const inner = boxW - 2;             // columns between the two `│`
    const nLines = it.codeLines.length;
    const gw = codeLineNumbers ? numDigits(nLines) + 1 : 0; // in-panel number + sep
    const codeW = inner - gw < 1 ? 1 : inner - gw;

    // "╭─ " + label + " " + fill + "   ╮" — the trailing three spaces are a cutout
    // for the copy button (a space on each side of it, drawn by gui.d).
    const usedTop = 8 + cast(int) columnWidth(it.codeLabel);
    const fillTop = boxW - usedTop < 0 ? 0 : boxW - usedTop;
    lines ~= PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
        band: BandKind.codeHeader, bandBg: pal.codePanelBg,
        barFg: it.barFg, hasBarFg: it.hasBarFg, srcLine: it.srcLine,
        copyFence: it.copyFence, runs: [
            PreviewRun("╭─ ", pal.ruleFg, pal.codePanelBg, true, 0),
            PreviewRun(it.codeLabel, pal.codeFg, pal.codePanelBg, true, 0),
            PreviewRun(" " ~ repeat("─", fillTop) ~ "   ╮", pal.ruleFg, pal.codePanelBg, true, 0),
        ]);

    foreach (bi, row; it.codeLines)
    {
        const srcLine = it.codeSrcLines[bi];
        bool firstWrap = true;
        foreach (wl; hardWrapRuns(row, codeW))
        {
            scratch ~= PreviewRun("│", pal.ruleFg, pal.codePanelBg, true, 0);
            int used;
            if (gw > 0)
            {
                scratch ~= PreviewRun(codeGutterStr(bi + 1, firstWrap, gw),
                    pal.codeLineNoFg, pal.codePanelBg, true, 0);
                used += gw;
            }
            foreach (r; wl)
            {
                scratch ~= r;
                used += cast(int) columnWidth(r.text);
            }
            if (inner - used > 0) // pad to the right border
                scratch ~= PreviewRun(repeat(" ", inner - used), pal.codeFg, pal.codePanelBg, true, 0);
            scratch ~= PreviewRun("│", pal.ruleFg, pal.codePanelBg, true, 0);
            lines ~= PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
                band: BandKind.codePanel, bandBg: pal.codePanelBg,
                barFg: it.barFg, hasBarFg: it.hasBarFg,
                srcLine: srcLine, showNumber: firstWrap,
                runs: takeRuns(scratch));
            firstWrap = false;
        }
    }

    // Rounded bottom border (numbered like the last body line, as before).
    lines ~= PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
        band: BandKind.codePanel, bandBg: pal.codePanelBg,
        barFg: it.barFg, hasBarFg: it.hasBarFg,
        srcLine: nLines ? it.codeSrcLines[nLines - 1] : it.srcLine,
        runs: [PreviewRun("╰" ~ repeat("─", inner) ~ "╯", pal.ruleFg, pal.codePanelBg, true, 0)]);
}

// Render a table: hand the flattened grid to core-cli's mapped renderer at the
// width, colorize each rendered line (box-drawing muted, content page-fg, header
// row bold), tag the lines with the table index, and record the `TableView` (the
// screen↔cell map) for the GUI's 2D selection (`TBL3`).
private void wrapTable(ref PreviewItem it, int width, ref PreviewDoc pal,
    ref WrappedPreview wp) @safe
{
    const cols = it.grid.length ? it.grid[0].length : 0;
    if (cols == 0)
        return;
    const avail = width - it.indentCols - it.qdepth * 2;
    auto mt = renderTableMapped(it.grid, it.aligns, cols, avail < 8 ? 8 : avail);

    const tableIndex = cast(int) wp.tables.length;
    const firstLine = cast(int) wp.lines.length;
    bool headerDone, firstLn = true;
    foreach (ln; mt.lines)
    {
        const content = lineHasContent(ln);
        const bold = content && !headerDone;
        if (content)
            headerDone = true;
        wp.lines ~= PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
            barFg: it.barFg, hasBarFg: it.hasBarFg,
            srcLine: it.srcLine, showNumber: firstLn && it.number,
            tableIndex: tableIndex,
            // A text-regime drag crossing the table selects its whole markdown
            // source span (a drag starting inside uses the 2D grid regime, TBL4).
            selSrcStart: it.blockStart, selSrcEnd: it.blockEnd,
            runs: colorizeTableLine(ln, bold, pal.ruleFg, pal.pageFg));
        firstLn = false;
    }
    wp.tables ~= TableView(firstLine, cast(int) mt.lines.length, mt.map);
}

private void wrapRule(ref PreviewItem it, int width, ref PreviewDoc pal,
    ref PreviewLine[] lines) @safe
{
    const n = width - it.indentCols - it.qdepth * 2;
    lines ~= PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
        band: BandKind.rule, barFg: it.barFg, hasBarFg: it.hasBarFg,
        srcLine: it.srcLine, showNumber: it.number,
        runs: [PreviewRun(repeat("─", n < 1 ? 1 : n), pal.ruleFg, RgbColor.init, false, 0)]);
}

private PreviewLine wrapHtmlLine(ref PreviewItem it) @safe
    => PreviewLine(indentCols: it.indentCols, quoteDepth: it.qdepth,
        barFg: it.barFg, hasBarFg: it.hasBarFg, srcLine: it.srcLine,
        showNumber: it.number, runs: it.preRuns);

// Split a rendered table line into box-drawing runs (ruleFg) and content runs
// (pageFg, optionally bold for the header row).
private PreviewRun[] colorizeTableLine(const(char)[] ln, bool bold,
    RgbColor ruleFg, RgbColor pageFg) @safe
{
    import std.utf : decode;
    PreviewRun[] runs;
    size_t i;
    while (i < ln.length)
    {
        const start = i;
        size_t probe = i;
        const firstBox = isBoxDrawing(decode(ln, probe));
        i = probe;
        while (i < ln.length)
        {
            size_t k = i;
            if (isBoxDrawing(decode(ln, k)) != firstBox)
                break;
            i = k;
        }
        runs ~= PreviewRun(ln[start .. i], firstBox ? ruleFg : pageFg,
            RgbColor.init, false, firstBox ? 0 : (bold ? cast(ubyte) Attr.bold : 0));
    }
    return runs;
}

// A rendered table line carries real cell text (not just borders / padding).
private bool lineHasContent(const(char)[] ln) @safe
{
    import std.utf : decode;
    size_t i;
    while (i < ln.length)
    {
        const cp = decode(ln, i);
        if (cp != ' ' && !isBoxDrawing(cp))
            return true;
    }
    return false;
}

// A recognized GitHub callout/admonition: its icon, accent, Title-case name, and
// the byte length of the `[!TYPE]` marker to strip from the rendered body.
private struct Callout
{
    string icon;
    RgbColor accent;
    string title;
    size_t markerLen;
}

// A wrap unit: whitespace-free, possibly spanning several styled fragments.
private struct Word
{
    PreviewRun[] parts;
    int width;
    bool spaceBefore;
}

// ── small pure helpers ───────────────────────────────────────────────────────

private bool isSpace(char c) @safe pure nothrow @nogc
    => c == ' ' || c == '\t' || c == '\n' || c == '\r';

private int numDigits(size_t n) @safe pure nothrow @nogc
{
    int d = 1;
    while (n >= 10) { n /= 10; ++d; }
    return d;
}

// An in-panel code-line-number gutter cell: `num` right-aligned in `gw-1` columns
// plus a trailing separator space, or all spaces on a wrapped continuation row.
private string codeGutterStr(size_t num, bool first, int gw) @safe pure nothrow
{
    if (gw <= 0)
        return "";
    if (!first)
    {
        auto s = new char[](gw);
        s[] = ' ';
        return (() @trusted => cast(string) s)();
    }
    import std.conv : text;
    string ns = text(num);
    string s;
    foreach (_; 0 .. (gw - 1) - cast(int) ns.length)
        s ~= ' ';
    return s ~ ns ~ " ";
}

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

/**
Lay a plain-text grid out with box-drawing borders and per-column alignment via
`core-cli`'s table renderer, returning the newline-free lines.

`@trusted`: the renderer takes plain `string`s and returns plain box-drawing
`string` lines — string-in / string-out, no unsafe operations — but it is not
attributed `@safe` (it GC-allocates during layout). Wrapping the one call keeps
`table()` / `layoutPreview` `@safe`. It runs in the layout stage (per theme /
width change), never per frame.
*/
private auto tableProps(scope const(ColAlign)[] aligns, size_t cols, int maxWidth) @trusted
{
    import sparkles.core_cli.ui.table : TableProps;
    import sparkles.base.text.width : Align;

    auto cAligns = new Align[](cols);
    foreach (i; 0 .. cols)
    {
        const a = i < aligns.length ? aligns[i] : ColAlign.none;
        final switch (a) with (ColAlign)
        {
        case center: cAligns[i] = Align.center; break;
        case right: cAligns[i] = Align.right; break;
        case none:
        case left: cAligns[i] = Align.left; break; // `none` renders left by convention
        }
    }
    return TableProps(headerRows: 1, columnAligns: cAligns,
        maxWidth: maxWidth > 0 ? cast(size_t) maxWidth : 0);
}

private string[] renderTableLines(string[][] grid, scope const(ColAlign)[] aligns,
    size_t cols, int maxWidth) @trusted
{
    import sparkles.core_cli.ui.table : drawTableLines;

    string[] rows;
    foreach (ln; drawTableLines(grid, tableProps(aligns, cols, maxWidth)))
        rows ~= ln;
    return rows;
}

/// Render the table AND its screen↔cell map (for GUI 2D selection, `TBL3`).
/// `@trusted`: `drawTableMapped` GC-allocates but is otherwise pure data-in /
/// data-out (`renderTableLines` covers the same for the non-GUI path).
private MappedTable renderTableMapped(string[][] grid, scope const(ColAlign)[] aligns,
    size_t cols, int maxWidth) @trusted
    => drawTableMapped(grid, tableProps(aligns, cols, maxWidth));

// ASCII-uppercase a string (for case-insensitive callout-type matching).
private string upperAscii(const(char)[] s) @safe pure
{
    auto r = new char[s.length];
    foreach (i, c; s)
        r[i] = (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
    return (() @trusted => cast(string) r)();
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

// Map each visible display column of an ANSI source line to the byte offset (in
// `s`) of the character that occupies it — skipping SGR/other escapes. Lets a
// decoded span be mapped back to its source bytes for cell-granular selection
// (SEL6): the span's text is the contiguous source between two escapes, so its
// source offset is `map[<span start column>]`.
private size_t[] ansiColToSrc(scope const(char)[] s) @safe
{
    import std.utf : decode;
    import std.typecons : Yes;

    size_t[] map;
    size_t i;
    while (i < s.length)
    {
        if (s[i] == '\x1b')
        {
            i = skipAnsiEscape(s, i);
            continue;
        }
        const start = i;
        decode!(Yes.useReplacementDchar)(s, i);
        const w = cast(int) columnWidth(s[start .. i]);
        foreach (_; 0 .. (w < 1 ? 1 : w))
            map ~= start;
    }
    return map;
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

/// A Nerd-Font glyph for a link destination (by host / scheme), else a file icon.
private string linkIcon(const(char)[] dest) @safe pure nothrow
{
    if (dest.containsText("github.com")) return "\U0000F09B";  //  github
    if (dest.containsText("gitlab")) return "\U0000F296";       //  gitlab
    if (dest.startsWithText("mailto:")) return "\U000F01EE";    // 󰇮 email
    if (dest.startsWithText("http://") || dest.startsWithText("https://"))
        return "\U000F059F";                                   // 󰖟 web
    return "\U0000F15C";                                       //  file / local
}

/// A devicon glyph for a fenced-code language (canonicalized), else a generic
/// code glyph; empty when the fence has no language.
private string langIcon(const(char)[] lang) @safe pure nothrow
{
    switch (lang)
    {
    case "python": return "\U0000E606"; //
    case "rust": return "\U0000E7A8"; //
    case "javascript", "typescript", "jsx", "tsx": return "\U0000E781"; //
    case "bash", "shell", "sh", "zsh", "fish": return "\U0000E795"; //
    case "nix": return "\U000F1105"; // 󱄅
    case "json": return "\U0000E60B"; //
    case "markdown", "md": return "\U0000E609"; //
    case "c", "cpp", "c++": return "\U0000E61E"; //
    case "html": return "\U0000E736"; //
    case "css": return "\U0000E749"; //
    case "go": return "\U0000E627"; //
    case "": return "";
    default: return "\U0000F121"; //  generic code
    }
}

private RgbColor mix(RgbColor a, RgbColor b, double t) @safe pure nothrow @nogc
{
    ubyte ch(ubyte x, ubyte y) => cast(ubyte)(x + (y - x) * t);
    return RgbColor(ch(a.r, b.r), ch(a.g, b.g), ch(a.b, b.b));
}

// Shared, CTFE-built fillers of the only two units `repeat` is ever called with
// (─ and space). Slicing these makes box borders / rules / code padding
// allocation-free on the wrap (resize) hot path; the old char-by-char `~=`
// reallocated ~log2(n) times, hundreds of times per relayout.
private enum size_t fillerCap = 1024;
private static immutable string dashFiller =
    () { string s; foreach (_; 0 .. fillerCap) s ~= "─"; return s; }();
private static immutable string spaceFiller =
    () { string s; foreach (_; 0 .. fillerCap) s ~= " "; return s; }();

// `n` copies of `unit`. For the fixed units above it returns a slice of the
// shared filler (zero allocation); anything else — or a width past the cap (a
// very wide window) — falls back to a single materializing allocation.
private const(char)[] repeat(string unit, int n) @safe pure nothrow
{
    if (n <= 0 || unit.length == 0)
        return "";
    const total = n * unit.length;
    if (unit == "─" && total <= dashFiller.length)
        return dashFiller[0 .. total];
    if (unit == " " && total <= spaceFiller.length)
        return spaceFiller[0 .. total];
    auto s = new char[total];
    foreach (k; 0 .. n)
        s[k * unit.length .. (k + 1) * unit.length] = unit[];
    return (() @trusted => cast(string) s)();
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
    // Times `wrapPreview` over an already-flattened doc — the actual resize hot
    // path (the GUI caches the flatten and only re-wraps on resize).
    private static struct WrapState
    {
        PreviewDoc doc;
        int w;
        size_t run()
        {
            import sparkles.test_runner.bench : blackBox;
            return blackBox(wrapPreview(doc, w).lines.length);
        }
    }

    // Times `flattenPreview` — the one-time-per-theme cost a resize no longer pays.
    private static struct FlattenState
    {
        PreviewModel model;
        ResolvedTheme theme;
        size_t run()
        {
            import sparkles.test_runner.bench : blackBox;
            return blackBox(flattenPreview(model, theme, tPageFg, tPageBg).items.length);
        }
    }

    private void registerWrapCase(PreviewDoc doc, int w)
    {
        import sparkles.test_runner.bench : benchCase;
        import std.conv : text;
        auto st = new WrapState(doc, w);
        benchCase(name: text("w=", st.w), labels: ["op": "wrap"],
            timed: &st.run, after: (ref size_t _) {});
    }

    private void registerFlattenCase(PreviewModel model, ResolvedTheme theme)
    {
        import sparkles.test_runner.bench : benchCase;
        auto st = new FlattenState(model, theme);
        benchCase(name: "flatten", labels: ["op": "flatten"],
            timed: &st.run, after: (ref size_t _) {});
    }
}

// The window-resize hot path. `gui.d` caches the width-independent flatten and
// re-runs only `wrapPreview` every frame the column count changes (continuously
// during a resize drag). Benchmark that wrap across a width sweep on a real
// document (`HUE_BENCH_FILE`, else the committed `docs/specs/base/text/index.md`),
// plus one `flatten` case for the one-time per-theme cost a resize no longer
// pays. The tree-sitter model build and the flatten are setup (not measured on
// the `wrap` cases).
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
    auto doc = flattenPreview(model, theme, tPageFg, tPageBg); // cached once, as the GUI does

    // A resize drag walks the column count; each stop re-wraps the cached doc.
    foreach (w; [40, 60, 80, 100, 120, 160])
        registerWrapCase(doc, w);
    registerFlattenCase(model, theme);
}

@("gui_preview.layout.wrapsProse")
@safe
unittest
{
    // A 24-word paragraph must wrap to several lines at width 20.
    string src;
    foreach (i; 0 .. 24)
        src ~= "word ";
    auto para = MdBlock(kind: MdBlockKind.paragraph,
        inlines: [MdInline(kind: MdInlineKind.text, span: Span(0, src.length))]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [para]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 20);
    import std.algorithm.iteration : filter;
    import std.range : walkLength;
    const nonblank = lines.filter!(l => l.runs.length).walkLength;
    assert(nonblank >= 3);
    // every wrapped line fits the width
    foreach (l; lines)
    {
        int col;
        foreach (r; l.runs)
            col += cast(int) columnWidth(r.text);
        assert(col <= 20);
    }
}

@("gui_preview.layout.headingDecoration")
@safe
unittest
{
    // A level-2 heading gets an accent-colored icon leader (not a `#` hash) and a
    // subtle heading band — no grammar needed, the model is built directly.
    string src = "Title";
    auto h = MdBlock(kind: MdBlockKind.heading, level: 2,
        inlines: [MdInline(kind: MdInlineKind.text, span: Span(0, src.length))]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [h]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    import std.algorithm.searching : any;
    assert(lines.any!(l => l.band == BandKind.heading && l.hasLeaderFg
        && l.leader.length && l.leader[0] != '#'));
}

@("gui_preview.layout.checkboxes")
@safe
unittest
{
    // Checked item → colored (green) icon leader; unchecked → muted icon leader;
    // neither uses the old ASCII `[ ]` marker.
    string src = "done todo";
    MdBlock item(byte state, size_t a, size_t b)
        => MdBlock(kind: MdBlockKind.listItem, checkbox: state,
            children: [MdBlock(kind: MdBlockKind.paragraph,
                inlines: [MdInline(kind: MdInlineKind.text, span: Span(a, b))])]);
    auto lst = MdBlock(kind: MdBlockKind.list,
        children: [item(1, 0, 4), item(0, 5, 9)]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [lst]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    import std.algorithm.searching : any;
    assert(lines.any!(l => l.hasLeaderFg && l.leader.length && l.leader[0] != '['));
    assert(lines.any!(l => !l.hasLeaderFg && l.leader.length && l.leader[0] != '['));
}

@("gui_preview.layout.linkIcon")
@safe
unittest
{
    // A link prepends a per-destination Nerd-Font icon (a multibyte run) before
    // its underlined label.
    string src = "gh";
    auto link = MdInline(kind: MdInlineKind.link, span: Span(0, 2),
        linkDest: "https://github.com/x",
        children: [MdInline(kind: MdInlineKind.text, span: Span(0, 2))]);
    auto para = MdBlock(kind: MdBlockKind.paragraph, inlines: [link]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [para]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    bool hasIcon;
    foreach (l; lines)
        foreach (r; l.runs)
            if (r.text.length && cast(ubyte) r.text[0] >= 0x80)
                hasIcon = true;
    assert(hasIcon);
}

@("gui_preview.layout.callout")
@safe
unittest
{
    // `> [!NOTE] …` renders a titled callout: an accent bar + icon-leader title
    // line, with the `[!NOTE]` marker stripped from the body.
    string src = "[!NOTE] pay attention";
    auto para = MdBlock(kind: MdBlockKind.paragraph, span: Span(0, src.length),
        inlines: [MdInline(kind: MdInlineKind.text, span: Span(0, src.length))]);
    auto quote = MdBlock(kind: MdBlockKind.blockQuote, children: [para]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [quote]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    import std.algorithm.searching : any, canFind;
    assert(lines.any!(l => l.hasBarFg && l.hasLeaderFg)); // title line
    assert(lines.any!(l => l.runs.canFind!(r => r.text == "Note")));
    foreach (l; lines) // marker stripped everywhere
        foreach (r; l.runs)
            assert(!r.text.canFind("[!NOTE]"));
}

@("gui_preview.layout.tableBorders")
@safe
unittest
{
    // A 2-column table renders box-drawing borders; a right-aligned column pads
    // its short cell on the left. Model built directly (no grammar).
    string src = "h1 h2 x 9";
    MdBlock cell(size_t a, size_t b)
        => MdBlock(kind: MdBlockKind.tableCell,
            inlines: [MdInline(kind: MdInlineKind.text, span: Span(a, b))]);
    auto header = MdBlock(kind: MdBlockKind.tableRow, children: [cell(0, 2), cell(3, 5)]);
    auto row = MdBlock(kind: MdBlockKind.tableRow, children: [cell(6, 7), cell(8, 9)]);
    auto tbl = MdBlock(kind: MdBlockKind.table,
        aligns: [ColAlign.left, ColAlign.right], children: [header, row]);
    auto m = PreviewModel(present: true,
        doc: MdDoc(MdBlock(kind: MdBlockKind.document, children: [tbl]), src));

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    import std.algorithm.searching : any, canFind;
    // vertical + horizontal box-drawing runs present
    assert(lines.any!(l => l.runs.canFind!(r => r.text.canFind("│"))));
    assert(lines.any!(l => l.runs.canFind!(r => r.text.canFind("─"))));
    // the right-aligned "9" sits flush right — a space precedes it in its cell
    assert(lines.any!(l => l.runs.canFind!(r => r.text.canFind(" 9"))));
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
    auto m = buildPreviewModel(reg, cache, src, &decodeAnsi);
    assert(m.present);
    assert(m.fences.length == 2);
    assert(!m.fences[0].isAnsi && m.fences[0].lang == "d");
    assert(m.fences[0].events.length > 0);
    assert(m.fences[1].isAnsi && m.fences[1].ansi.length == 1);

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    assert(lines.length > 0);
    assert(lines.any!(l => l.band == BandKind.codeHeader));
    assert(lines.any!(l => l.band == BandKind.codePanel));
    assert(lines.any!(l => l.band == BandKind.rule));
    // the table renders with box-drawing borders (a `│` vertical rule)
    assert(lines.any!(l => l.runs.canFind!(r => r.text.canFind("│"))));

    // the ` ```ansi ` block produced a non-default-colored "red" run
    bool redRun;
    foreach (l; lines)
        if (l.band == BandKind.codePanel)
            foreach (r; l.runs)
                if (r.text.canFind("red") && r.fg != tPageFg)
                    redRun = true;
    assert(redRun);

    // the heading renders as an accent-colored icon-leader band (not a `#` hash)
    assert(lines.any!(l => l.band == BandKind.heading && l.hasLeaderFg
        && l.leader.length && l.leader[0] != '#'));
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

    // No decoder passed (the terminal / HTML paths and the `no-gui` build): the
    // ansi fence keeps its raw body and layout strips the SGR to plain text.
    auto m = buildPreviewModel(reg, cache, src);
    assert(m.fences.length == 1);
    assert(m.fences[0].isAnsi && m.fences[0].ansi.length == 0);

    auto lines = layoutPreview(m, darkTheme, tPageFg, tPageBg, 80);
    // "red text" survives inside the code panel, with the SGR escapes gone.
    bool sawStripped;
    foreach (l; lines)
        if (l.band == BandKind.codePanel)
            foreach (r; l.runs)
            {
                assert(!r.text.canFind('\x1b'), "SGR escape leaked into a stripped run");
                if (r.text.canFind("red") && r.text.canFind("text"))
                    sawStripped = true;
            }
    assert(sawStripped, "the stripped ansi fence text is missing");
}

@("gui_preview.layout.wrapCacheStable")
@system
unittest
{
    // The GUI caches one flattened `PreviewDoc` per theme and re-wraps it on every
    // resize. Guard the two properties that makes safe: re-wrapping the same doc
    // must be idempotent (wrapPreview must not mutate it), and a cached re-wrap
    // must equal a fresh one-shot `layoutPreview` at each width. Uses a rich source
    // so every item kind is exercised (flow / heading / list / callout / table /
    // rule / code).
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax : GrammarRegistry, TsConfigCache, LabelSet;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    const src = "# Title\n\nSome **bold** prose with a [link](x.md) that wraps.\n\n"
        ~ "- first\n- second\n\n> [!NOTE] heed this\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n"
        ~ "---\n\n```d\nvoid main() {}\n```\n";
    auto m = buildPreviewModel(reg, cache, src);
    auto doc = flattenPreview(m, darkTheme, tPageFg, tPageBg);

    foreach (w; [24, 40, 80])
    {
        auto a = wrapPreview(doc, w).lines;   // re-wrap the SAME cached doc…
        auto b = wrapPreview(doc, w).lines;   // …twice: must be byte-identical
        auto oneShot = layoutPreview(m, darkTheme, tPageFg, tPageBg, w);
        assert(a == b, "wrapPreview mutated the cached doc");
        assert(a == oneShot, "cached wrap differs from a one-shot layout");
    }
}

@("gui_preview.wrap.ansiAndTableSelection")
@system
unittest
{
    import std.process : environment;
    import std.algorithm.searching : any, canFind;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.syntax : GrammarRegistry, TsConfigCache, LabelSet;
    import gui_ansi : decodeAnsi;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    const src = "| a | b |\n|---|---|\n| 1 | 2 |\n\n```ansi\n\x1b[31mred\x1b[0m\n```\n";
    auto m = buildPreviewModel(reg, cache, src, &decodeAnsi);
    auto wp = wrapPreview(flattenPreview(m, darkTheme, tPageFg, tPageBg), 80);

    // The table produced a TableView + tagged lines + a readable map, and each
    // table line carries the table's block source span for text-regime crossing
    // (`TBL4`) — the span covers the raw markdown table.
    assert(wp.tables.length == 1);
    assert(wp.lines.any!(l => l.tableIndex == 0));
    assert(wp.tables[0].map.numRows >= 2 && wp.tables[0].map.numCols == 2);
    foreach (l; wp.lines)
        if (l.tableIndex == 0)
        {
            assert(l.selSrcStart != size_t.max && l.selSrcEnd > l.selSrcStart);
            assert(src[l.selSrcStart .. l.selSrcEnd].canFind("| a | b |"));
        }

    // ANSI body cells are char-level source-backed (`SEL6`): a content run maps
    // to the raw source "red" and carries no block `selSrcStart`.
    bool ansiCell;
    foreach (l; wp.lines)
        if (l.band == BandKind.codePanel)
        {
            assert(l.selSrcStart == size_t.max); // no longer block-granular
            foreach (r; l.runs)
                if (r.srcStart != size_t.max && src[r.srcStart .. r.srcStart + r.text.length] == "red")
                    ansiCell = true;
        }
    assert(ansiCell, "ANSI content run not mapped char-level to source");
}

@("gui_preview.ansiColToSrc.skipsEscapes")
@safe
unittest
{
    // Each visible column maps to the source byte of its char, skipping the SGR
    // escapes: "red" at bytes 5-7 (after ESC[31m), " x" at 12-13 (after ESC[0m).
    assert(ansiColToSrc("\x1b[31mred\x1b[0m x") == [5, 6, 7, 12, 13]);
    assert(ansiColToSrc("ab") == [0, 1]); // no escapes → identity
}
