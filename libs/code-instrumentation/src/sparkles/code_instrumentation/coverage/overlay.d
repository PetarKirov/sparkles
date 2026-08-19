/**
 * Overlay planner for code coverage visualization in `hue` (GUI, TUI, ANSI, HTML).
 */
module sparkles.code_instrumentation.coverage.overlay;

import sparkles.base.text.span : TextSpan;

import sparkles.code_instrumentation.coverage.model : FileCoverage, LineCoverage, LineState, SpanCoverage;

/// Gutter decoration element for a single source line.
struct CoverageGutterItem
{
    size_t lineNumber;       /// 1-based source line
    LineState state;         /// Covered / uncovered / partial / nonCode
    ulong executionCount;    /// Exact count
    string countText;        /// Compact formatted string (e.g. "5", "164k", "0", "")
    /// The line was re-anchored onto text it no longer holds; `countText` is
    /// empty and a renderer must not claim a state for it.
    bool stale;
}

/// An inline span highlight for sub-line execution or uncovering.
struct CoverageSpanItem
{
    TextSpan span;
    ulong executionCount;
    bool isBlockCoverage;
}

/// Complete planned coverage overlay ready for backend rendering.
struct CoveragePlan
{
    CoverageGutterItem[] gutterItems;
    CoverageSpanItem[] inlineSpans;
    string summaryBanner;
    double linePercent;
    double branchPercent;
    size_t coveredLines;
    size_t coverableLines;
    /// How many lines the report describes but can no longer speak for. Non-zero
    /// only after a consumer re-anchored the artifact onto an edited file.
    size_t staleLines;
}

/**
Plans the overlay decorations for one file's coverage.

Params:
    file = the parsed coverage for a single source file

Returns: the plan — one gutter item per recorded line (each carrying the line
    number it belongs to, since only a DMD `.lst` describes every line), the
    sub-line spans where the format provides them, and a summary banner.
*/
CoveragePlan planCoverage(in FileCoverage file) @safe pure
{
    import std.format : format;

    CoveragePlan plan;
    plan.linePercent = file.linePercent;
    plan.branchPercent = file.branchPercent;
    plan.coveredLines = file.coveredLines;
    plan.coverableLines = file.coverableLines;

    if (file.coverableLines > 0)
    {
        if (file.totalBranches > 0)
            plan.summaryBanner = format!"Coverage: %.1f%% (%s/%s lines, %s/%s branches)"(
                file.linePercent, file.coveredLines, file.coverableLines,
                file.coveredBranches, file.totalBranches);
        else
            plan.summaryBanner = format!"Coverage: %.1f%% (%s/%s lines covered)"(
                file.linePercent, file.coveredLines, file.coverableLines);
    }
    else
    {
        plan.summaryBanner = "Coverage: 100.0% (no executable code)";
    }

    foreach (ref const l; file.lines)
    {
        CoverageGutterItem item;
        item.lineNumber = l.lineNumber;
        item.state = l.state;
        item.executionCount = l.executionCount;
        item.stale = l.stale;
        // A stale line gets no count and no state to paint: whatever the
        // counter says, it is not about the text that is there now.
        item.countText = l.stale ? "" : formatCount(l.state, l.executionCount);
        if (l.stale)
            plan.staleLines++;
        plan.gutterItems ~= item;
    }

    foreach (ref const sp; file.spans)
    {
        plan.inlineSpans ~= CoverageSpanItem(
            span: sp.span,
            executionCount: sp.executionCount,
            isBlockCoverage: sp.isBlockCoverage
        );
    }

    if (plan.staleLines > 0)
        plan.summaryBanner ~= format!" — %s line(s) edited since the run"(
            plan.staleLines);

    return plan;
}

/// The widest string $(LREF formatCount) can return, in cells. A gutter sized
/// to the counts it actually holds never needs more than this.
enum size_t maxCountWidth = 4;

/**
Formats an execution count for the gutter, in at most
$(LREF maxCountWidth) cells.

The width bound is the point: the gutter is a fixed column beside the code,
and a count that overruns it either clips or pushes the source sideways. The
previous ladder had two ways to exceed four cells — `9999` rounded up to
`"10.0k"`, and anything past a billion rendered in full, so `ulong.max` came
out as the twelve-cell `"18446744073G"`. The `.1f` steps stop below the
rounding boundary, and everything past a trillion saturates to `">1T"`, which
is a claim about magnitude rather than a number nobody reads anyway.

Params:
    state = the line's coverage state
    count = its execution count

Returns: the formatted count; `""` for a non-code line and `"0"` for one that
    emitted code and never ran.
*/
string formatCount(LineState state, ulong count) @safe pure
{
    import std.format : format;

    if (state == LineState.nonCode)
        return "";
    if (state == LineState.uncovered || count == 0)
        return "0";

    // Each `.1f` step stops at 9_950 rather than 10_000: 9_999 / 1000 rounds
    // to 10.0, and `"10.0k"` is five cells.
    if (count < 1_000)
        return format!"%s"(count);
    if (count < 9_950)
        return format!"%.1fk"(count / 1_000.0);
    if (count < 1_000_000)
        return format!"%sk"(count / 1_000);
    if (count < 9_950_000)
        return format!"%.1fM"(count / 1_000_000.0);
    if (count < 1_000_000_000)
        return format!"%sM"(count / 1_000_000);
    if (count < 9_950_000_000)
        return format!"%.1fG"(count / 1_000_000_000.0);
    if (count < 1_000_000_000_000)
        return format!"%sG"(count / 1_000_000_000);
    return ">1T";
}

@("coverage.overlay.formatCount")
@safe pure
unittest
{
    assert(formatCount(LineState.nonCode, 0) == "");
    assert(formatCount(LineState.uncovered, 0) == "0");
    assert(formatCount(LineState.covered, 5) == "5");
    assert(formatCount(LineState.covered, 1200) == "1.2k");
    assert(formatCount(LineState.covered, 163840) == "163k");
    assert(formatCount(LineState.covered, 2500000) == "2.5M");
}

@("coverage.overlay.formatCount.neverExceedsTheColumn")
@safe pure
unittest
{
    // The bound the gutter is sized against. Both former overruns are here:
    // 9_999 used to round to "10.0k", and ulong.max to "18446744073G".
    static immutable ulong[] samples = [
        0, 1, 9, 10, 999, 1_000, 1_234, 9_949, 9_950, 9_999, 10_000,
        999_999, 1_000_000, 9_949_999, 9_950_000, 999_999_999,
        1_000_000_000, 9_949_999_999, 1_000_000_000_000, ulong.max,
    ];
    foreach (n; samples)
    {
        const text = formatCount(LineState.covered, n);
        assert(text.length <= maxCountWidth, text);
    }

    assert(formatCount(LineState.covered, 9_999) == "9k");
    assert(formatCount(LineState.covered, ulong.max) == ">1T");
    assert(formatCount(LineState.covered, 1_500_000_000) == "1.5G");
}

@("coverage.overlay.planCoverage")
@safe pure
unittest
{
    FileCoverage f;
    f.sourcePath = "src/app.d";
    f.totalLines = 3;
    f.coverableLines = 2;
    f.coveredLines = 1;
    f.lines = [
        LineCoverage(lineNumber: 1, executionCount: 10, state: LineState.covered),
        LineCoverage(lineNumber: 2, executionCount: 0, state: LineState.uncovered),
        LineCoverage(lineNumber: 3, executionCount: 0, state: LineState.nonCode),
    ];

    const plan = planCoverage(f);
    assert(plan.linePercent == 50.0);
    assert(plan.gutterItems.length == 3);
    assert(plan.gutterItems[0].countText == "10");
    assert(plan.gutterItems[1].countText == "0");
    assert(plan.gutterItems[2].countText == "");
    assert(plan.summaryBanner == "Coverage: 50.0% (1/2 lines covered)");
}
