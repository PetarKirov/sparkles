// Coverage that survives an edit.
//
// A `.lst` names lines by number, and a number means whatever line holds it
// now. Edit the file and every counter after the first insertion describes the
// wrong row — so the overlay used to refuse an artifact older than its source
// outright: warn, render plain, tell the reader to run the tests again.
//
// That is the right call at file granularity and the wrong granularity. An edit
// invalidates the lines it touched, not the file: three changed lines should not
// cost the ninety that still hold exactly the text the run measured. The
// research catalog puts it as a rule — staleness belongs *in the decoration
// type*, per datum, because a decoration that silently lies is worse than an
// absent one and a channel that goes dark on the first keystroke is worse than
// both.
//
// The evidence for doing better is already in the artifact. `dmd -cov` records
// each counted line's source text beside its counter, so the listing carries the
// code it measured. Diffing that against the file on disk (`sparkles:diff`'s
// Myers line diff — already a dependency, for the diff view) says exactly which
// lines survived and where they moved to. Survivors keep their counts at their
// new numbers; lines that were inserted or rewritten carry a record marked
// stale, which renders as nothing rather than as a number about text that is
// gone.
//
// This is the one format that can do it. Every other artifact this library
// ingests records numbers alone, and for those the old whole-file refusal is
// still the only honest answer.
module coverage_rebase;

import sparkles.code_instrumentation : FileCoverage, LineCoverage, LineState;
import sparkles.diff.myers : diffLines, LineSpans, splitDiffLines;

/// The Myers search cap, matching `DiffOptions.maxEditDistance`. Past it the
/// changed middle degrades to one remove+add block, which marks that whole
/// region stale — a safe degradation: it says less, never something wrong.
private enum uint maxEditDistance = 1024;

/**
`file`'s records re-anchored from `recorded` onto `current`.

Params:
    file = the parsed coverage, its line numbers indexing `recorded`
    recorded = the source text the artifact captured (`dmdListingText`)
    current = the file as it is on disk now

Returns: coverage indexed against `current` — one record per line of it. A line
    that survived the edit carries the counter it earned, at its new number; a
    line that was inserted or rewritten carries a `stale` record, which plans to
    no decoration at all. When `recorded` is empty (a format that carries no
    source text) `file` comes back untouched, since there is nothing to anchor
    against and guessing would be the lie this exists to avoid.
*/
FileCoverage rebasedCoverage(const FileCoverage file, const(char)[] recorded,
    const(char)[] current) @safe
{
    if (recorded.length == 0 || current.length == 0)
        return FileCoverage(sourcePath: file.sourcePath,
            lines: file.lines.dup, spans: file.spans.dup,
            functions: file.functions.dup, totalLines: file.totalLines,
            coveredLines: file.coveredLines, coverableLines: file.coverableLines,
            totalBranches: file.totalBranches,
            coveredBranches: file.coveredBranches);

    bool oldMissingNl, newMissingNl;
    const oldLines = splitDiffLines(recorded, oldMissingNl);
    const newLines = splitDiffLines(current, newMissingNl);
    const d = diffLines(recorded, oldLines, current, newLines, maxEditDistance);

    FileCoverage out_;
    out_.sourcePath = file.sourcePath;
    out_.functions = file.functions.dup;
    out_.totalLines = newLines.length;
    // Sub-line spans are dropped rather than carried across. They are byte
    // offsets into the text the run saw, and a line diff cannot move a byte
    // offset — re-emitting them would wash a range of whatever characters now
    // sit at those bytes, which is the confident lie this module exists to
    // avoid. (No format that carries spans also records its source, so today
    // this never fires; it is here so the day one does, it fails closed.)

    size_t i, j;                 // 0-based old / new line cursors
    const removed = d.oldRemoved[];
    const inserted = d.newInserted[];
    while (j < newLines.length)
    {
        while (i < removed.length && removed[i])
            ++i;                 // an old line that is simply gone
        if (j < inserted.length && inserted[j])
        {
            // New or rewritten text. It gets a record so the reader can tell
            // "the run has nothing to say about this line" from "this line has
            // no code", which a missing record cannot express.
            LineCoverage line;
            line.lineNumber = j + 1;
            line.state = LineState.nonCode;
            line.stale = true;
            out_.lines ~= line;
            ++j;
            continue;
        }
        if (i >= oldLines.length)
            break;

        // A survivor: the same text, wherever it now sits.
        auto line = file.lineAt(i + 1);
        if (line !is null)
        {
            LineCoverage moved = *line;
            moved.lineNumber = j + 1;
            out_.lines ~= moved;
            if (moved.state != LineState.nonCode)
            {
                out_.coverableLines++;
                if (moved.state == LineState.covered)
                    out_.coveredLines++;
            }
            out_.totalBranches += moved.branchesTotal;
            out_.coveredBranches += moved.branchesTaken;
        }
        ++i;
        ++j;
    }
    return out_;
}

@("coverage_rebase.survivorsKeepTheirCountsAtTheirNewNumbers")
@safe
unittest
{
    import sparkles.code_instrumentation : dmdListingText;
    import sparkles.code_instrumentation.coverage.formats.dmd : parseDmdCoverage;

    // Four counted lines; then two are inserted above the last one, which is
    // exactly the edit that used to cost the whole file its overlay.
    enum listing = "      5|int add(int a, int b)\n"
        ~ "       |{\n"
        ~ "      5|    return a + b;\n"
        ~ "       |}\n"
        ~ "src/math.d is 100% covered\n";

    const parsed = parseDmdCoverage(listing);
    assert(parsed, "parse failed");
    const recorded = dmdListingText(listing);

    const edited = "// a new comment\nint add(int a, int b)\n{\n"
        ~ "    log(a);\n    return a + b;\n}\n";
    const rebased = rebasedCoverage(parsed.value, recorded, edited);

    assert(rebased.lines.length == 6, "one record per line of the file now");

    // `int add(…)` moved from line 1 to line 2 and kept its five executions;
    // `return a + b;` moved from 3 to 5 and kept its own.
    assert(rebased.lines[1].lineNumber == 2);
    assert(rebased.lines[1].executionCount == 5 && !rebased.lines[1].stale);
    assert(rebased.lines[4].lineNumber == 5);
    assert(rebased.lines[4].executionCount == 5 && !rebased.lines[4].stale);

    // The two inserted lines are marked, not guessed at.
    assert(rebased.lines[0].stale && rebased.lines[0].lineNumber == 1);
    assert(rebased.lines[3].stale && rebased.lines[3].lineNumber == 4);

    // And the surviving counters still add up, so the summary is about what
    // the report can still speak for.
    assert(rebased.coverableLines == 2 && rebased.coveredLines == 2);
}

@("coverage_rebase.anUnchangedFileIsUnchanged")
@safe
unittest
{
    import sparkles.code_instrumentation : dmdListingText;
    import sparkles.code_instrumentation.coverage.formats.dmd : parseDmdCoverage;

    enum listing = "      5|a();\n0000000|b();\n       |c;\nsrc/x.d is 50% covered\n";
    const parsed = parseDmdCoverage(listing);
    assert(parsed, "parse failed");

    const same = dmdListingText(listing) ~ "\n";
    const rebased = rebasedCoverage(parsed.value, dmdListingText(listing), same);

    assert(rebased.lines.length == 3);
    foreach (i, ref const l; rebased.lines)
    {
        assert(!l.stale, "nothing moved, so nothing is stale");
        assert(l.lineNumber == i + 1);
    }
    assert(rebased.lines[0].state == LineState.covered);
    assert(rebased.lines[1].state == LineState.uncovered);
    assert(rebased.coverableLines == 2 && rebased.coveredLines == 1);
}

@("coverage_rebase.noRecordedTextMeansNoRebase")
@safe
unittest
{
    // The honest answer for a format that records numbers alone: hand the
    // report back untouched and let the caller's freshness check decide,
    // rather than anchoring against evidence that does not exist.
    FileCoverage f;
    f.lines = [LineCoverage(lineNumber: 1, executionCount: 3,
        state: LineState.covered)];
    f.coverableLines = 1;
    f.coveredLines = 1;

    const same = rebasedCoverage(f, "", "int x;\n");
    assert(same.lines.length == 1 && !same.lines[0].stale);
    assert(rebasedCoverage(f, "int x;\n", "").lines.length == 1);
}
