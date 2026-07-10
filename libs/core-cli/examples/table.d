#!/usr/bin/env dub
/+ dub.sdl:
    name "table"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// A gallery of every `drawTable` feature: spans, sparse placement, per-column
// horizontal & vertical alignment, glyph presets & custom glyphs, separator
// toggles, width caps & wrapping, and the `validateTable` error posture.
//
// Every section deliberately mixes ANSI-styled text (`styledText`), wide/CJK
// glyphs, and emoji + combining marks, so each feature simultaneously proves it
// measures content in *terminal cells* (via `sparkles.base.text`) rather than
// bytes — a misaligned column would be immediately visible.

import sparkles.core_cli.ui.demo : Section, runDemo;
import sparkles.core_cli.ui.table :
    drawTable, Cell, Placement, TableProps, TableGlyphs, VAlign, stylePresets,
    validateTable, TableError;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.width : Align;

void main()
{
    // Shared samples reused across the preset and toggle galleries.
    string[][] sample = [
        [styledText(i"{bold Node}"), styledText(i"{bold 地域}"), styledText(i"{bold Status}")],
        ["api", "日本 🇯🇵", styledText(i"{green ✅ up}")],
        ["web", "eu-west", styledText(i"{yellow ⚠ warn}")],
    ];
    string[][] toggleSample = [
        ["a", "日本"],
        ["b", "🚀"],
        ["c", "café"],
    ];

    // Preset helper: render `sample` under a named glyph set from `stylePresets`.
    Section preset(string name) => Section(
        header: `Preset: "` ~ name ~ `"`,
        content: drawTable(sample, TableProps(glyphs: stylePresets[name])),
    );

    // A deliberately malformed layout for the validation section: cell B lands on
    // a slot already covered by A's colspan.
    Placement[] overlapping = [
        Placement(0, 0, styledText(i"{bold A}"), colSpan: 2),
        Placement(0, 1, styledText(i"{red B}")), // overlaps A's second slot
    ];
    auto validation = validateTable(overlapping);
    const validationNote = validation.hasError
        ? "⚠ validateTable: " ~ validation.error.message
        : "✓ validateTable: no model errors";

    runDemo(
        header: "drawTable Demo — Every Feature",
        content: [
            //
            // 1. Basics — backward-compatible string[][]
            //
            Section(
                header: "Basic table (plain string[][], byte-identical baseline)",
                content: [
                    ["Service", "Region", "Status"],
                    ["api", "us-east", "up"],
                    ["web", "eu-west", "up"],
                    ["db", "ap-south", "down"],
                ].drawTable,
            ),
            Section(
                header: "Styled + i18n content (ANSI SGR, CJK, emoji, flags)",
                content: [
                    [styledText(i"{bold Service}"), styledText(i"{bold 地域}"), styledText(i"{bold Status}")],
                    ["api 🚀", "us-east", styledText(i"{green ✅ up}")],
                    ["web", "日本 🇯🇵", styledText(i"{yellow ⚠ warn}")],
                    ["db", "eu-west", styledText(i"{red ✗ down}")],
                ].drawTable,
            ),
            //
            // 2. Column spans
            //
            Section(
                header: "Column span (colSpan banner; right-aligned numeric columns)",
                content: drawTable([
                    [Cell(styledText(i"{bold.underline 四半期売上 (Quarterly Sales)}"), colSpan: 3)],
                    [Cell("Region"), Cell("Q1"), Cell("Q2")],
                    [Cell("North 🌎"), Cell("1200"), Cell("1350")],
                    [Cell("日本"), Cell("980"), Cell("1100")],
                ], TableProps(columnAligns: [Align.left, Align.right, Align.right])),
            ),
            //
            // 3. Row spans (with row separators)
            //
            Section(
                header: "Row span (rowSpan label + rowSeparators → rule breaks, ┌┐└┘ corners)",
                content: drawTable([
                    [Cell("地域\nAsia", rowSpan: 2), Cell("Tokyo"), Cell(styledText(i"{green ✅ up}"))],
                    [Cell("Osaka"), Cell(styledText(i"{yellow ⚠ warn}"))],
                ], TableProps(rowSeparators: true)),
            ),
            //
            // 4. Row × column block span
            //
            Section(
                header: "Block span (colSpan: 2, rowSpan: 2)",
                content: drawTable([
                    [Cell(styledText(i"{bold.inverse CORE}"), colSpan: 2, rowSpan: 2), Cell("edge-1")],
                    [Cell("edge-2")],
                    [Cell("a"), Cell("b"), Cell("c 🚀")],
                ]),
            ),
            //
            // 5. Sparse Placement[] (order-independent)
            //
            Section(
                header: "Sparse Placement[] (out-of-order; uncovered slots blank)",
                content: drawTable([
                    Placement(2, 2, styledText(i"{cyan cells}")),
                    Placement(0, 0, "diagonal 🚀"),
                    Placement(1, 1, "日本語"),
                ]),
            ),
            //
            // 6. Horizontal alignment
            //
            Section(
                header: "Per-column horizontal alignment (left / center / right)",
                content: drawTable([
                    ["left", "center", "right"],
                    ["a", styledText(i"{green ✅}"), "1"],
                    ["日本語", "mid", "4200"],
                ], TableProps(columnAligns: [Align.left, Align.center, Align.right])),
            ),
            Section(
                header: "defaultAlign: right, with a single Align.left override on col 0",
                content: drawTable([
                    ["metric", "v1", "v2"],
                    ["cpu", "45", "80"],
                    ["mem 💾", "1200", "980"],
                ], TableProps(defaultAlign: Align.right, columnAligns: [Align.left])),
            ),
            //
            // 7. Vertical alignment
            //
            Section(
                header: "Per-column vertical alignment (top / middle / bottom in a tall row)",
                content: drawTable([
                    [
                        Cell("line 1\nline 2\nline 3\nline 4"),
                        Cell(styledText(i"{green ▲ top}")),
                        Cell(styledText(i"{yellow ● middle}")),
                        Cell(styledText(i"{red ▼ bottom}")),
                    ],
                ], TableProps(columnVAligns: [VAlign.top, VAlign.top, VAlign.middle, VAlign.bottom])),
            ),
            //
            // 8. Glyph presets (all five)
            //
            preset("rounded"),
            preset("square"),
            preset("ascii"),
            preset("double"),
            preset("heavy"),
            //
            // 9. Custom glyphs
            //
            Section(
                header: "Custom TableGlyphs (dotted rules — fields are individually overridable)",
                content: drawTable([
                    [styledText(i"{bold x}"), styledText(i"{bold y}")],
                    ["1", "日本"],
                    ["2", "🚀"],
                ], TableProps(glyphs: TableGlyphs(
                    topLeft: '·', topRight: '·', bottomLeft: '·', bottomRight: '·',
                    horizontalLine: '┈', verticalLine: '┊',
                    teeDown: '·', teeUp: '·', teeRight: '·', teeLeft: '·', cross: '·',
                    cornerTL: '·', cornerTR: '·', cornerBL: '·', cornerBR: '·'))),
            ),
            //
            // 10. Separator toggles
            //
            Section(
                header: "Toggle: border off",
                content: drawTable(toggleSample, TableProps(border: false)),
            ),
            Section(
                header: "Toggle: column separators off",
                content: drawTable(toggleSample, TableProps(columnSeparators: false)),
            ),
            Section(
                header: "Toggle: row separators on",
                content: drawTable(toggleSample, TableProps(rowSeparators: true)),
            ),
            //
            // 10b. Header row & stub column separators (distinct emphasis rules)
            //
            Section(
                header: "Header row separator (headerRows: 1 — distinct heavy rule under the header)",
                content: drawTable(sample, TableProps(headerRows: 1)),
            ),
            Section(
                header: "Stub column separator (headerCols: 1, columnSeparators off — heavy ┃ after the stub)",
                content: drawTable(sample, TableProps(headerCols: 1, columnSeparators: false)),
            ),
            Section(
                header: "Header row + stub column (headerRows: 1, headerCols: 1 — ╋ where the rules cross)",
                content: drawTable(sample, TableProps(headerRows: 1, headerCols: 1)),
            ),
            //
            // 11. Width caps & wrapping — sparkles.base.text robustness
            //
            Section(
                header: "Wrap (a): total maxWidth: 40 — shrink largest-first to fit",
                content: drawTable([
                    ["id", "description"],
                    ["1", "A fairly long description that will not fit a narrow terminal and must wrap"],
                ], TableProps(maxWidth: 40)),
            ),
            Section(
                header: "Wrap (b): per-column columnMaxWidths: [0, 20] — cap one column",
                content: drawTable([
                    ["id", "note"],
                    ["1", "wrap this column at twenty cells while the id column stays untouched"],
                ], TableProps(columnMaxWidths: [0, 20])),
            ),
            Section(
                header: "Width floor: columnMinWidths: [12, 0] — stable geometry for live re-renders",
                content: drawTable([
                    ["name", "value"],
                    ["cpu", "45%"],
                ], TableProps(columnMinWidths: [12, 0])),
            ),
            Section(
                header: "Wrap (c): explicit \\n in content — hard break",
                content: drawTable([
                    ["key", "value"],
                    ["PATH", "/usr/local/bin\n/opt/app/bin\n/home/user/bin"],
                ]),
            ),
            Section(
                header: "Wrap (d): Unicode width — full-width CJK (2 cells each) + emoji graphemes",
                content: drawTable([
                    ["lang", "sample"],
                    ["ja", "日本語のテキストは全角文字で構成されています"],
                    ["mix", "🚀 ✅ 🎉 🇯🇵 café résumé"],
                ], TableProps(columnMaxWidths: [0, 14])),
            ),
            Section(
                header: "Wrap (e): ANSI-safe wrapping — SGR style re-opened on each line",
                content: drawTable([
                    ["level", "message"],
                    [
                        styledText(i"{red ERR}"),
                        styledText(i"{bold.green A long styled message whose bold-green SGR style must be re-emitted on every wrapped continuation line, never split mid-escape}"),
                    ],
                ], TableProps(columnMaxWidths: [0, 26])),
            ),
            //
            // 12. validateTable — detect + render anyway
            //
            Section(
                header: "validateTable (overlap): reports the error AND still renders deterministically",
                content: validationNote ~ "\n\n" ~ drawTable(overlapping),
            ),
            //
            // 13. Title & footer — spliced into the frame like drawBox's
            //
            Section(
                header: "Title/footer: spliced into the borders (truncated with … when narrow)",
                content: drawTable([
                    ["item", "qty"],
                    ["nuts", "12"],
                    ["bolts", "7"],
                ], TableProps(title: styledText(i"{bold Inventory}"),
                    footer: "2 kinds", headerRows: 1,
                    columnAligns: [Align.left, Align.right])),
            ),
            //
            // 14. Align.decimal — a column of numbers sharing a dot position
            //
            Section(
                header: "Align.decimal: values align on the last '.' (dotless sit left of it)",
                content: drawTable([
                    ["benchmark", "median/iter"],
                    ["parse", "1.25µs"],
                    ["render", "23.5µs"],
                    ["noop", "980ns"],
                ], TableProps(headerRows: 1,
                    columnAligns: [Align.left, Align.decimal])),
            ),
            //
            // 15. Per-cell halign/valign — overrides beat the column default
            //
            Section(
                header: "Per-cell align: a centered colspan banner over left/right columns",
                content: drawTable([
                    [Cell("Quarterly totals", colSpan: 2, halign: Align.center)],
                    [Cell("north"), Cell("1200", halign: Align.right)],
                    [Cell("south"), Cell("98", halign: Align.right)],
                ]),
            ),
            //
            // 16. Streaming views — lazy line/chunk emission (eager layout)
            //
            Section(
                header: "drawTableLines: a forward range of lines (LiveRegion-ready), byte-identical joined",
                content: streamingNote,
            ),
        ],
    );
}

/// Demonstrates the streaming views: `drawTableLines` yields the same bytes as
/// `drawTable` line by line (no trailing newlines — ready for a `LiveRegion`
/// frame), and `drawTableChunks!false` reveals the table cell by cell.
private string streamingNote()
{
    import std.algorithm.iteration : joiner, map;
    import std.conv : text, to;
    import std.range : enumerate;
    import sparkles.core_cli.ui.table : drawTableChunks, drawTableLines;

    auto cells = [["a", "b"], ["1", "2"]];
    string out_;
    foreach (i, line; drawTableLines(cells).enumerate)
        out_ ~= text("line ", i, ": ", line, "\n");

    const chunks = drawTableChunks!false(cells).map!(to!string).joiner(" ⏵ ").to!string;
    out_ ~= "\ncell chunks: " ~ chunks;
    return out_;
}
