/**
 * Result types shared by the layers, plus the summary table renderer.
 *
 * A layer reports `passed` plus the raw list of `Divergence`s it found. The
 * orchestrator then classifies each divergence against the allowlist into
 * "known" (reported, non-failing) and "new" (fails the run) — this split is
 * what makes the harness a ratchet against Unicode version drift.
 */
module sparkles.text_conformance.report;

import std.array : array;
import std.algorithm : any, map;
import std.conv : to;

import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.base.styled_template : styledText;

/// One observed disagreement between the library and an oracle.
struct Divergence
{
    int layer;        /// Originating layer (0–3).
    string key;       /// Normalized key for allowlist matching (stable, hashable).
    string observed;  /// What the library produced.
    string expected;  /// What the oracle expected.
    string note;      /// Human context (glyph, category, line number, …).
}

/// What a layer returns before allowlist classification.
struct LayerResult
{
    string name;
    bool skipped;
    string skipReason;
    size_t passed;
    Divergence[] divergences;
    string[] notes; /// Extra summary lines (e.g. category buckets).
}

/// A layer after allowlist classification — what the summary table renders.
struct LayerOutcome
{
    string name;
    bool skipped;
    string skipReason;
    size_t passed;
    size_t known;
    size_t newFail;
}

/// True if any layer has new (non-allowlisted) failures — drives the exit code.
bool anyNewFailures(in LayerOutcome[] outcomes)
    => outcomes.any!(o => o.newFail > 0);

/// Render the per-layer summary as a banner + table.
string renderSummary(in LayerOutcome[] outcomes)
{
    string[][] rows = [[
        styledText(i"{bold Layer}"),
        styledText(i"{bold Passed}"),
        styledText(i"{bold Known}"),
        styledText(i"{bold New}"),
        styledText(i"{bold Status}"),
    ]];

    foreach (o; outcomes)
    {
        string status;
        if (o.skipped)
            status = styledText(i"{yellow ⊘ skipped}");
        else if (o.newFail > 0)
            status = styledText(i"{red ✗ fail}");
        else if (o.known > 0)
            status = styledText(i"{green ✓ pass} {dim (known diffs)}");
        else
            status = styledText(i"{green ✓ pass}");

        rows ~= [
            o.name,
            o.skipped ? "—" : o.passed.to!string,
            o.skipped ? "—" : o.known.to!string,
            o.skipped ? "—" : o.newFail.to!string,
            status,
        ];
    }

    return "text-conformance"
        .drawHeader(HeaderProps(style: HeaderStyle.banner))
        ~ "\n\n" ~ drawTable(rows);
}
