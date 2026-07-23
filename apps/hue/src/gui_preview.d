// Markdown-preview model + layout for `hue --gui`.
//
// Two stages, both raylib-free (gui.d does the painting):
//
//   buildPreviewModel  (@system, once at file load) — parse the markdown
//       structure (sparkles.syntax.md.model), and for each fenced code block
//       either syntax-highlight its body with the fence language (reusing the
//       highlightInjected pipeline) or, for a ` ```ansi ` fence, decode it with
//       the off-screen VT (gui_ansi.decodeAnsi). Theme-independent.
//
//   layoutPreview      (pure, rerun on theme / width / font change) — flatten the
//       structural model into a flat PreviewLine[] with colors resolved from the
//       live theme, prose soft-wrapped to the window width, and glow /
//       render-markdown-style decoration (heading markers, code panels + language
//       labels, list bullets + checkboxes, quote gutters, rules, tables).
//
// gui.d paints PreviewLine[] index-culled to the viewport, mapping the neutral
// RgbColor + Attr bits onto raylib-text's TextStyle + raylib Color.
module gui_preview;

import gui_ansi : AnsiLine, AnsiSpan, Attr, decodeAnsi;
import gui_text : columnWidth, lineCount;

import sparkles.syntax : MdDoc, MdBlock, MdBlockKind, MdInline, MdInlineKind, ColAlign, Span,
    HighlightEvent, byStyledLine, ResolvedTheme, StyleSpec, TextAttr, UnderlineStyle,
    LabelId, toRgb, RgbColor, GrammarRegistry, TsConfigCache, canonicalLanguage,
    extractMarkdown, highlightInjected;
import sparkles.base.smallbuffer : SmallBuffer;

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
*/
PreviewModel buildPreviewModel(ref GrammarRegistry registry, ref TsConfigCache cache,
    scope const(char)[] source) @system
{
    PreviewModel m;
    m.doc = extractMarkdown(registry, source);
    m.present = true;
    collectFences(m.doc.root, source, cache, m.fences);
    return m;
}

private void collectFences(in MdBlock b, scope const(char)[] source,
    ref TsConfigCache cache, ref CodeFence[] fences) @system
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
            f.ansi = decodeAnsi(f.body);
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
        collectFences(c, source, cache, fences);
}

// ── Stage 2: layout (pure) ───────────────────────────────────────────────────

/**
Flatten `m` into painted lines for `theme`, resolving default/ANSI colors against
`pageFg`/`pageBg` and soft-wrapping prose to `widthCols` columns. Pure — rerun
whenever the theme, window width, or font size changes.
*/
PreviewLine[] layoutPreview(PreviewModel m, ResolvedTheme theme,
    RgbColor pageFg, RgbColor pageBg, int widthCols) @safe
{
    auto lay = Layouter(source: m.doc.source, theme: theme, pageFg: pageFg,
        pageBg: pageBg, width: widthCols < 8 ? 8 : widthCols, fences: m.fences);
    lay.resolvePalette();
    lay.buildLineStarts();
    foreach (ref b; m.doc.root.children)
        lay.block(b, 0, 0);
    return lay.lines;
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
            toRgb(spec.fg, pageFg), toRgb(spec.bg, pageBg), spec.bg.isSet, mapSpecAttrs(spec));
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

private struct Layouter
{
    const(char)[] source;
    ResolvedTheme theme;
    RgbColor pageFg, pageBg;
    int width;
    const(CodeFence)[] fences;

    PreviewLine[] lines;
    size_t fenceIdx;
    int listDepth; // current list nesting (1-based inside list(); 0 outside)

    // Source-line numbering: `curSrcLine`/`pendingNumber` are set by `beginLine`
    // right before a logical line's content push; `push` stamps every line with
    // `curSrcLine` and gives the first push after `beginLine` the number.
    size_t[] lineStarts;
    size_t curSrcLine;
    bool pendingNumber;

    // Resolved role colors (from the theme's markup.* labels, page-fallback).
    RgbColor headingFg, codeFg, linkFg, quoteFg;
    RgbColor codePanelBg, codeHeaderBg, ruleFg, inlineCodeBg;
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

    void push(PreviewLine l) @safe
    {
        l.srcLine = curSrcLine;
        if (pendingNumber)
        {
            l.showNumber = true;
            pendingNumber = false;
        }
        lines ~= l;
    }

    void blank() @safe { lines ~= PreviewLine.init; } // spacer: never numbered

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
            emitFlow(inlineRuns(b.inlines, pageFg, 0), indent, qdepth, "");
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
        emitFlow(inlineRuns(b.inlines, accent, Attr.bold), indent, qdepth,
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
        // Title line: icon + Title-case type, in the accent (bold), with the bar.
        push(PreviewLine(indentCols: indent, quoteDepth: bodyDepth,
            leader: co.icon ~ " ", leaderFg: co.accent, hasLeaderFg: true,
            barFg: co.accent, hasBarFg: true,
            runs: [PreviewRun(co.title, co.accent, RgbColor.init, false, Attr.bold)]));

        // Body: the quoted blocks, with the `[!TYPE]` marker dropped from the
        // first paragraph (it parses as a leading link/text inline). Force the
        // accent bar on every line the body emits.
        const start = lines.length;
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
                emitFlow(inlineRuns(trimmed, pageFg, 0), indent, bodyDepth, "");
                blank();
            }
            else
                block(c, indent, bodyDepth);
        }
        foreach (ref l; lines[start .. $])
        {
            l.hasBarFg = true;
            l.barFg = co.accent;
        }
        blank();
    }

    void codeFence(int indent, ubyte qdepth) @safe
    {
        if (fenceIdx >= fences.length)
            return;
        const f = fences[fenceIdx++];

        // Language-label header bar, prefixed with a devicon for the fence
        // language.
        const icon = langIcon(f.lang);
        string lbl = (icon.length ? icon ~ " " : "") ~ (f.lang.length ? f.lang.idup : "code");
        if (f.label.length)
            lbl ~= " " ~ f.label.idup;
        pendingNumber = false; // the language-header bar carries no line number
        push(PreviewLine(indentCols: indent, quoteDepth: qdepth, band: BandKind.codeHeader,
            bandBg: codeHeaderBg, runs: [PreviewRun(lbl, codeFg, codeHeaderBg, true, 0)]));

        // Code/ANSI lines are hard-wrapped to the panel width (like prose) so long
        // lines reflow onto continuation rows instead of overflowing + clipping.
        // Each source code line is numbered by its document line (first wrapped
        // row only).
        const avail = width - indent - qdepth * 2;
        const aw = avail < 1 ? 1 : avail;
        const baseLine = srcLineOf(f.bodyStart);
        void pushCode(size_t bodyRow, PreviewRun[] row)
        {
            curSrcLine = baseLine + bodyRow;
            pendingNumber = true;
            foreach (wl; hardWrapRuns(row, aw))
                push(PreviewLine(indentCols: indent, quoteDepth: qdepth,
                    band: BandKind.codePanel, bandBg: codePanelBg, runs: wl));
        }

        if (f.isAnsi)
        {
            foreach (i, ref al; f.ansi)
            {
                PreviewRun[] runs;
                foreach (ref sp; al.spans)
                    runs ~= PreviewRun(sp.text, sp.fgDefault ? pageFg : sp.fg,
                        sp.bg, !sp.bgDefault, sp.attrs);
                pushCode(i, runs);
            }
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
                    toRgb(spec.fg, codeFg), bg, hasBg, mapAttrs(spec));
            }
            foreach (i, row; byLine)
                pushCode(i, row);
        }

        // Bottom border, so the panel reads as a framed block (the header bar is
        // the top edge).
        const bw = width - indent - qdepth * 2;
        pendingNumber = false; // the border carries no line number
        push(PreviewLine(indentCols: indent, quoteDepth: qdepth, band: BandKind.codePanel,
            bandBg: codePanelBg,
            runs: [PreviewRun(repeat("─", bw < 1 ? 1 : bw), ruleFg, codePanelBg, true, 0)]));
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
                    emitFlow(inlineRuns(c.inlines, pageFg, 0), indent, qdepth, leader,
                        leaderFg: leaderFg, hasLeaderFg: hasLeaderFg);
                    first = false;
                }
                else
                    block(c, indent + cast(int) columnWidth(leader), qdepth);
            }
            if (first) // an empty item still gets its marker
                push(PreviewLine(indentCols: indent, quoteDepth: qdepth, leader: leader,
                    leaderFg: leaderFg, hasLeaderFg: hasLeaderFg));
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
        // inline styling is lost) and hand it to core-cli's table renderer for
        // box-drawing borders + per-column alignment.
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

        const avail = width - indent - qdepth * 2;
        auto rows = renderTableLines(grid, b.aligns, cols, avail < 8 ? 8 : avail);

        // Colorize each rendered line: box-drawing muted (ruleFg), content pageFg,
        // the single header content row bold. No band — the borders frame it.
        bool headerDone;
        foreach (ln; rows)
        {
            const content = lineHasContent(ln);
            const bold = content && !headerDone;
            if (content)
                headerDone = true;
            push(PreviewLine(indentCols: indent, quoteDepth: qdepth,
                runs: colorizeTableLine(ln, bold)));
        }
        blank();
    }

    // Split a rendered table line into box-drawing runs (ruleFg) and content runs
    // (pageFg, optionally bold for the header row).
    PreviewRun[] colorizeTableLine(const(char)[] ln, bool bold) @safe
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
    bool lineHasContent(const(char)[] ln) @safe
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

    void rule(int indent, ubyte qdepth) @safe
    {
        const n = width - indent - qdepth * 2;
        push(PreviewLine(indentCols: indent, quoteDepth: qdepth, band: BandKind.rule,
            runs: [PreviewRun(repeat("─", n < 1 ? 1 : n), ruleFg, RgbColor.init, false, 0)]));
        blank();
    }

    void htmlBlock(in MdBlock b, int indent, ubyte qdepth) @safe
    {
        import std.string : splitLines;
        foreach (ln; slice(b.span.start, b.span.end).splitLines)
            push(PreviewLine(indentCols: indent, quoteDepth: qdepth,
                runs: [PreviewRun(ln.idup, mix(pageFg, pageBg, 0.35),
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
                    RgbColor.init, false, attrs);
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
                    inlineCodeBg, true, attrs);
                break;
            case link:
                // A per-destination icon (github / web / mail / file), then the
                // underlined label.
                runs ~= PreviewRun(linkIcon(inl.linkDest) ~ " ", linkFg,
                    RgbColor.init, false, attrs);
                auto label = inl.children.length
                    ? inlineRuns(inl.children, linkFg, cast(ubyte)(attrs | Attr.underline))
                    : [PreviewRun(slice(inl.span.start, inl.span.end), linkFg,
                        RgbColor.init, false, cast(ubyte)(attrs | Attr.underline))];
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

    // Word-wrap `runs` to the available width and push the resulting lines. A
    // "word" is a maximal whitespace-free unit that may span several runs (so a
    // styled span touching punctuation — `**bold**,` — stays one word with no
    // stray space); breaks happen only where the source had whitespace. The
    // first line shows `leader` at `indent`; continuation lines hang-indent.
    void emitFlow(PreviewRun[] runs, int indent, ubyte qdepth, string leader,
        RgbColor leaderFg = RgbColor.init, bool hasLeaderFg = false,
        BandKind band = BandKind.none, RgbColor bandBg = RgbColor.init) @safe
    {
        const lead = cast(int) columnWidth(leader);
        const avail = width - indent - qdepth * 2 - lead;
        const a = avail < 4 ? 4 : avail;

        // Tokenize into words carrying their styled fragments + preceding-space.
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
                words[$ - 1].parts ~= PreviewRun(frag, r.fg, r.bg, r.hasBg, r.attrs);
                words[$ - 1].width += cast(int) columnWidth(frag);
            }
            // `open`/`spacePending` carry across the run boundary: a word joins
            // fragments from adjacent runs unless whitespace fell between them.
        }

        PreviewRun[] line;
        int col;
        bool firstLine = true;
        void flush()
        {
            // The leader (and its accent) rides the first line only; the band
            // spans every wrapped line so a wrapped heading stays fully tinted.
            push(PreviewLine(indentCols: firstLine ? indent : indent + lead,
                quoteDepth: qdepth, band: band, bandBg: bandBg,
                leader: firstLine ? leader : "",
                leaderFg: leaderFg, hasLeaderFg: firstLine && hasLeaderFg,
                runs: line));
            line = null;
            col = 0;
            firstLine = false;
        }
        foreach (w; words)
        {
            if (col > 0 && col + (w.spaceBefore ? 1 : 0) + w.width > a)
                flush();
            if (col > 0 && w.spaceBefore)
            {
                line ~= PreviewRun(" ", w.parts[0].fg, RgbColor.init, false, 0);
                ++col;
            }
            foreach (p; w.parts)
            {
                line ~= p;
                col += cast(int) columnWidth(p.text);
            }
        }
        if (line.length || firstLine)
            flush();
    }
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

// Map a syntax `StyleSpec`'s attributes onto the `gui_ansi.Attr` bits the preview
// runs use. Shared by the Layouter and the raw-view builder.
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
        while (i < r.text.length)
        {
            const cpStart = i;
            decode(r.text, i); // advance one codepoint
            const cw = cast(int) columnWidth(r.text[cpStart .. i]);
            if (col + cw > width && col > 0)
            {
                if (cpStart > segStart)
                    cur ~= PreviewRun(r.text[segStart .. cpStart], r.fg, r.bg, r.hasBg, r.attrs);
                lines ~= cur;
                cur = null;
                col = 0;
                segStart = cpStart;
            }
            col += cw;
        }
        if (r.text.length > segStart)
            cur ~= PreviewRun(r.text[segStart .. $], r.fg, r.bg, r.hasBg, r.attrs);
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
private string[] renderTableLines(string[][] grid, scope const(ColAlign)[] aligns,
    size_t cols, int maxWidth) @trusted
{
    import sparkles.core_cli.ui.table : drawTableLines, TableProps;
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
    auto props = TableProps(headerRows: 1, columnAligns: cAligns,
        maxWidth: maxWidth > 0 ? cast(size_t) maxWidth : 0);
    string[] rows;
    foreach (ln; drawTableLines(grid, props))
        rows ~= ln;
    return rows;
}

// ASCII-uppercase a string (for case-insensitive callout-type matching).
private string upperAscii(const(char)[] s) @safe pure
{
    auto r = new char[s.length];
    foreach (i, c; s)
        r[i] = (c >= 'a' && c <= 'z') ? cast(char)(c - 32) : c;
    return (() @trusted => cast(string) r)();
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

private string repeat(string unit, int n) @safe pure nothrow
{
    string s;
    foreach (_; 0 .. n)
        s ~= unit;
    return s;
}

// ── tests ────────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.syntax : Span, resolveTheme, LabelSet, builtinDark;

    private ResolvedTheme darkTheme() @safe
        => resolveTheme(builtinDark, LabelSet.standard());

    private enum RgbColor tPageFg = RgbColor(0xcd, 0xd6, 0xf4);
    private enum RgbColor tPageBg = RgbColor(0x1e, 0x1e, 0x2e);
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

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());
    const src = "# Title\n\nPara **bold** and `code`.\n\n- a\n- b\n\n> quote\n\n"
        ~ "| a | b |\n|---|---|\n| 1 | 2 |\n\n---\n\n"
        ~ "```d\nvoid main() {}\n```\n\n```ansi\n\x1b[31mred\x1b[0m\n```\n";

    auto m = buildPreviewModel(reg, cache, src);
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
