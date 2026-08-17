/**
Parser for GCC / GDC `gcov` (`.gcov`) coverage listings.

A `.gcov` file is `<count>:<line>:<source>`, where the counter is `-` for a
line that emitted no code, `#####` (or `=====` for an unconditional block) for
one that never ran, and a decimal count otherwise. Line 0 carries the
`Source:`/`Graph:`/`Data:` preamble.

With `-b`, branch and function annotations are interleaved as their own
unprefixed lines. The branch form has two spellings, and reading only one of
them is how an untaken branch came to be scored as covered:

    branch  0 taken 50%      # gcov -b
    branch  0 taken 0        # gcov -b -c   (counts, not percentages)
    branch  1 never executed
*/
module sparkles.code_instrumentation.coverage.formats.gcov;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.code_instrumentation.coverage.model :
    FileCoverage, LineCoverage, LineState;
import sparkles.code_instrumentation.coverage.record :
    RecordScanner, splitOnce, trimmed, wholeNumber;

/**
Parses a `.gcov` listing.

Params:
    contents = the whole listing
    overridePath = source path to record; when empty the `Source:` preamble's
        is used.

Returns: the `FileCoverage`, or a `ParseError` with a byte offset into
    `contents`.
*/
ParseExpected!FileCoverage parseGcovCoverage(const(char)[] contents,
    string overridePath = null) @safe
{
    import std.algorithm.searching : startsWith;

    FileCoverage file;
    file.sourcePath = overridePath;

    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const record = scanner.line;
        const stripped = record.trimmed;
        if (stripped.length == 0)
            continue;

        // Branch and function annotations carry no `<count>:<line>:` prefix.
        if (stripped.startsWith("branch "))
        {
            applyBranch(stripped, file);
            continue;
        }
        if (stripped.startsWith("function ") || stripped.startsWith("call ")
            || stripped.startsWith("unconditional "))
            continue;

        const first = splitOnce(record, ':');
        if (!first.found)
            continue;   // `-a` block separators (`------`) and the like
        const second = splitOnce(first.after, ':');
        if (!second.found)
            continue;

        const lineAt = scanner.offset + first.afterIndex;
        auto lineNumber = wholeNumber(second.before, lineAt);
        if (!lineNumber)
            return parseErr!FileCoverage(lineNumber.error);

        if (lineNumber.value == 0)
        {
            // `-: 0:Source:src/math.c` and friends.
            const meta = second.after.trimmed;
            if (meta.startsWith("Source:") && file.sourcePath is null)
                file.sourcePath = meta["Source:".length .. $].trimmed.idup;
            continue;
        }

        const countField = first.before.trimmed;
        LineCoverage line;
        line.lineNumber = cast(size_t) lineNumber.value;

        if (countField == "-")
        {
            line.state = LineState.nonCode;
        }
        else if (countField.startsWith("#####") || countField.startsWith("====="))
        {
            line.state = LineState.uncovered;
            file.coverableLines++;
        }
        else
        {
            auto count = wholeNumber(countField, scanner.offset);
            if (!count)
                return parseErr!FileCoverage(count.error);
            line.executionCount = count.value;
            line.state = count.value > 0 ? LineState.covered : LineState.uncovered;
            file.coverableLines++;
            if (count.value > 0)
                file.coveredLines++;
        }

        file.lines ~= line;
    }

    file.totalLines = file.lines.length;
    return parseOk(file);
}

/**
Applies a `branch N ...` annotation to the most recently read line.

gcov attaches a branch to the line above it, so unlike LCOV there is no line
number to join on — position *is* the association here.
*/
private void applyBranch(const(char)[] annotation, ref FileCoverage file) @safe
{
    file.totalBranches++;
    const taken = branchWasTaken(annotation);
    if (taken)
        file.coveredBranches++;

    if (file.lines.length == 0)
        return;
    auto last = &file.lines[$ - 1];
    last.branchesTotal++;
    if (taken)
        last.branchesTaken++;
    // A line that ran but did not take every branch out of it is partial.
    if (last.state == LineState.covered && last.branchesTaken < last.branchesTotal)
        last.state = LineState.partial;
    else if (last.state == LineState.partial && last.branchesTaken == last.branchesTotal)
        last.state = LineState.covered;
}

/**
Whether a `branch N ...` annotation says the branch was ever taken.

Reads the token after `taken` and tests it numerically, so both spellings work:
`taken 50%` and `taken 0` mean what they say. The previous test —
`!line.canFind("taken 0%")` — matched only the percentage form, so every
untaken branch in a `gcov -b -c` listing counted as covered.
*/
private bool branchWasTaken(const(char)[] annotation) @safe
{
    import std.algorithm.searching : canFind, find;

    if (annotation.canFind("never executed"))
        return false;

    auto after = annotation.find("taken ");
    if (after.length == 0)
        return false;                 // no verdict expressed; do not claim one
    after = after["taken ".length .. $];

    // Strip a trailing '%' and anything after the number ("(fallthrough)").
    size_t end;
    while (end < after.length && after[end] >= '0' && after[end] <= '9')
        end++;
    if (end == 0)
        return false;
    return after[0 .. end] != "0" && !allZeros(after[0 .. end]);
}

/// Whether every character is `0` — `taken 000` is still untaken.
private bool allZeros(const(char)[] digits) @safe pure nothrow @nogc
{
    foreach (c; digits)
        if (c != '0')
            return false;
    return digits.length > 0;
}

@("coverage.formats.gcov.basic")
@safe
unittest
{
    enum gcovText =
        "        -:    0:Source:src/math.c\n" ~
        "        -:    0:Graph:math.gcno\n" ~
        "        -:    0:Data:math.gcda\n" ~
        "        -:    0:Runs:1\n" ~
        "        -:    1:#include <stdio.h>\n" ~
        "        1:    2:int add(int a, int b) {\n" ~
        "        1:    3:    return a + b;\n" ~
        "        -:    4:}\n" ~
        "    #####:    5:void unused() {\n" ~
        "    #####:    6:    printf(\"never\");\n" ~
        "        -:    7:}\n";

    const cov = parseGcovCoverage(gcovText);
    assert(cov, "parse failed");
    const f = cov.value;
    assert(f.sourcePath == "src/math.c");
    assert(f.totalLines == 7);
    assert(f.coverableLines == 4);
    assert(f.coveredLines == 2);
    assert(f.lines[0].state == LineState.nonCode);
    assert(f.lines[1].state == LineState.covered);
    assert(f.lines[1].executionCount == 1);
    assert(f.lines[4].state == LineState.uncovered);
    assert(f.lines[4].executionCount == 0);
}

@("coverage.formats.gcov.branchCountAndPercentSpellings")
@safe
unittest
{
    // `gcov -b -c` reports counts, `gcov -b` reports percentages. Both must
    // score branch 1 as untaken; only the percentage form used to.
    enum counts =
        "        -:    0:Source:a.c\n" ~
        "        1:    1:if (x) {\n" ~
        "branch  0 taken 1\n" ~
        "branch  1 taken 0\n";
    enum percents =
        "        -:    0:Source:a.c\n" ~
        "        1:    1:if (x) {\n" ~
        "branch  0 taken 100%\n" ~
        "branch  1 taken 0%\n";
    enum never =
        "        -:    0:Source:a.c\n" ~
        "        1:    1:if (x) {\n" ~
        "branch  0 taken 1 (fallthrough)\n" ~
        "branch  1 never executed\n";

    foreach (doc; [counts, percents, never])
    {
        const cov = parseGcovCoverage(doc);
        assert(cov, "parse failed");
        const f = cov.value;
        assert(f.totalBranches == 2, "both branches counted");
        assert(f.coveredBranches == 1, "exactly one branch taken");
        // The line ran, but not every way out of it.
        assert(f.lines[0].state == LineState.partial);
        assert(f.lines[0].branchesTaken == 1);
        assert(f.lines[0].branchesTotal == 2);
    }
}

@("coverage.formats.gcov.malformedCounterIsRejected")
@safe
unittest
{
    const junk = parseGcovCoverage("      12x:    1:x();\n");
    assert(junk.hasError);
    assert(junk.error.code == ParseErrorCode.unexpectedCharacter);
}
