/**
Parser for standard LCOV (`.info`) coverage reports.

LCOV is the interchange format every other tool can emit — Vitest, Istanbul,
GCC, Clang/LLVM and `lcov` itself — which also means it is the format with the
most variation in the wild. Records are grouped into per-file blocks between
`SF:` and `end_of_record`, but the order of the `DA` / `BRDA` / `FN` groups
inside a block is not fixed: `geninfo` writes branches before lines, Istanbul
writes them after. So this parser buffers a block's records and joins them by
line number at `end_of_record`, rather than assuming any adjacency.

See `man geninfo` for the record vocabulary.
*/
module sparkles.code_instrumentation.coverage.formats.lcov;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.code_instrumentation.coverage.model :
    CoverageReport, FileCoverage, FunctionCoverage, LineCoverage, LineState;
import sparkles.code_instrumentation.coverage.record :
    RecordScanner, Halves, splitFields, splitOnce, trimmed, wholeNumber;

/// A `DA:` record, before the block is assembled.
private struct LineRecord
{
    size_t lineNumber;
    ulong executionCount;
}

/// A `BRDA:` record, before the block is assembled.
private struct BranchRecord
{
    size_t lineNumber;
    bool taken;
}

/**
Parses an LCOV `.info` document.

Params:
    contents = the whole `.info` text

Returns: a `CoverageReport`, or the first malformed record's
    `ParseError` with a byte offset into `contents`.
*/
ParseExpected!CoverageReport parseLcovCoverage(const(char)[] contents) @safe
{
    CoverageReport report;

    FileCoverage current;
    LineRecord[] lineRecords;
    BranchRecord[] branchRecords;
    bool inRecord;

    /// Assembles the buffered records into `current` and appends it.
    void flush() @safe
    {
        // Join by line number rather than adjacency: `lines` is built from the
        // `DA` records, then the `BRDA` records are attributed to them. This is
        // what makes the parser independent of the producer's record order.
        size_t[size_t] indexOfLine;
        foreach (rec; lineRecords)
        {
            if (auto existing = rec.lineNumber in indexOfLine)
            {
                // A merged tracefile can carry the same line twice; `lcov -a`
                // adds the counts, and counting the line as coverable twice
                // would inflate the denominator.
                current.lines[*existing].executionCount += rec.executionCount;
                continue;
            }
            indexOfLine[rec.lineNumber] = current.lines.length;
            current.lines ~= LineCoverage(
                lineNumber: rec.lineNumber,
                executionCount: rec.executionCount,
            );
        }

        foreach (rec; branchRecords)
        {
            current.totalBranches++;
            if (rec.taken)
                current.coveredBranches++;
            if (auto at = rec.lineNumber in indexOfLine)
            {
                current.lines[*at].branchesTotal++;
                if (rec.taken)
                    current.lines[*at].branchesTaken++;
            }
        }

        foreach (ref line; current.lines)
        {
            if (line.executionCount == 0)
                line.state = LineState.uncovered;
            else if (line.branchesTotal > 0 && line.branchesTaken < line.branchesTotal)
                line.state = LineState.partial;   // ran, but not every way through
            else
                line.state = LineState.covered;

            current.coverableLines++;
            if (line.state != LineState.uncovered)
                current.coveredLines++;
        }

        // The highest line described, not the record count: a tracefile
        // records a subset, so `lines.length` says nothing about the file.
        foreach (ref line; current.lines)
            if (line.lineNumber > current.totalLines)
                current.totalLines = line.lineNumber;
        report.files ~= current;

        current = FileCoverage.init;
        lineRecords = null;
        branchRecords = null;
        inRecord = false;
    }

    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const record = scanner.line.trimmed;
        if (record.length == 0)
            continue;

        const split = splitOnce(record, ':');
        if (!split.found)
        {
            if (record == "end_of_record" && inRecord)
                flush();
            continue;   // `TN:`-less preambles and unknown lines are not errors
        }

        const tag = split.before;
        const data = split.after;
        const dataAt = scanner.offset + split.afterIndex;

        switch (tag)
        {
            case "SF":
                if (inRecord)
                    flush();    // a block that never closed still describes a file
                current.sourcePath = data.trimmed.idup;
                inRecord = true;
                break;

            case "DA":
            {
                // `DA:<line>,<count>[,<checksum>]`. The checksum is ignored,
                // but the count is read as a whole field — folding the
                // checksum's digits into it is the bug this format is most
                // prone to.
                const(char)[][3] fields;
                size_t[3] at;
                const n = splitFields(data, ',', fields[], at[]);
                if (n < 2)
                    return parseErr!CoverageReport(
                        ParseErrorCode.unexpectedEnd, dataAt, "DA needs <line>,<count>");
                auto line = wholeNumber(fields[0], dataAt + at[0]);
                if (!line)
                    return parseErr!CoverageReport(line.error);
                auto count = wholeNumber(fields[1], dataAt + at[1]);
                if (!count)
                    return parseErr!CoverageReport(count.error);
                lineRecords ~= LineRecord(cast(size_t) line.value, count.value);
                break;
            }

            case "BRDA":
            {
                // `BRDA:<line>,<block>,<branch>,<taken>`, where `taken` is `-`
                // when the branch was never reached at all.
                const(char)[][4] fields;
                size_t[4] at;
                const n = splitFields(data, ',', fields[], at[]);
                if (n < 4)
                    return parseErr!CoverageReport(
                        ParseErrorCode.unexpectedEnd, dataAt,
                        "BRDA needs <line>,<block>,<branch>,<taken>");
                auto line = wholeNumber(fields[0], dataAt + at[0]);
                if (!line)
                    return parseErr!CoverageReport(line.error);

                bool taken;
                const takenField = fields[3].trimmed;
                if (takenField != "-")
                {
                    auto count = wholeNumber(takenField, dataAt + at[3]);
                    if (!count)
                        return parseErr!CoverageReport(count.error);
                    taken = count.value > 0;
                }
                branchRecords ~= BranchRecord(cast(size_t) line.value, taken);
                break;
            }

            case "FN":
            {
                // Two shapes in the wild: `FN:<line>,<name>` (LCOV 1.x) and
                // `FN:<start>,<end>,<name>` (LCOV 2.x). Telling them apart by
                // whether the second field is numeric keeps a name that begins
                // with a digit from being mistaken for an end line.
                const(char)[][3] fields;
                size_t[3] at;
                const n = splitFields(data, ',', fields[], at[]);
                if (n < 2)
                    return parseErr!CoverageReport(
                        ParseErrorCode.unexpectedEnd, dataAt, "FN needs <line>,<name>");
                auto start = wholeNumber(fields[0], dataAt + at[0]);
                if (!start)
                    return parseErr!CoverageReport(start.error);

                const(char)[] name = fields[1];
                if (n == 3)
                    name = wholeNumber(fields[1], dataAt + at[1]) ? fields[2] : fields[1];
                current.functions ~= FunctionCoverage(
                    functionName: name.idup,
                    startLine: cast(size_t) start.value,
                );
                break;
            }

            case "FNDA":
            {
                const(char)[][2] fields;
                size_t[2] at;
                const n = splitFields(data, ',', fields[], at[]);
                if (n < 2)
                    break;      // a name-less FNDA is noise, not a parse failure
                auto count = wholeNumber(fields[0], dataAt + at[0]);
                if (!count)
                    return parseErr!CoverageReport(count.error);
                foreach (ref fn; current.functions)
                    if (fn.functionName == fields[1])
                    {
                        fn.executionCount = count.value;
                        break;
                    }
                break;
            }

            default:
                break;  // TN, LF, LH, BRF, BRH, FNF, FNH — derived, so recomputed
        }
    }

    // A report that ends mid-block still describes a file. Dropping it was
    // silent data loss for anything streamed or truncated.
    if (inRecord)
        flush();

    return parseOk(report);
}

@("coverage.formats.lcov.basic")
@safe
unittest
{
    enum lcov =
        "TN:TestRun\n" ~
        "SF:src/utils.ts\n" ~
        "FN:1,helper\n" ~
        "FNDA:3,helper\n" ~
        "DA:1,3\n" ~
        "DA:2,3\n" ~
        "DA:3,0\n" ~
        "BRDA:2,0,0,3\n" ~
        "BRDA:2,0,1,0\n" ~
        "end_of_record\n";

    const report = parseLcovCoverage(lcov);
    assert(report, "parse failed");
    assert(report.value.files.length == 1);
    const f = report.value.files[0];
    assert(f.sourcePath == "src/utils.ts");
    assert(f.coverableLines == 3);
    assert(f.coveredLines == 2);
    assert(f.totalBranches == 2);
    assert(f.coveredBranches == 1);
    assert(f.functions.length == 1);
    assert(f.functions[0].functionName == "helper");
    assert(f.functions[0].executionCount == 3);
}

@("coverage.formats.lcov.checksumIsNotPartOfTheCount")
@safe
unittest
{
    // `geninfo --checksum` appends an MD5 to each DA record. The digits in it
    // used to be folded into the execution count: 3 read as 31290.
    const report = parseLcovCoverage(
        "SF:src/a.c\nDA:1,3,f1ab29d0\nend_of_record\n");
    assert(report, "parse failed");
    assert(report.value.files[0].lines[0].executionCount == 3);
}

@("coverage.formats.lcov.branchesJoinRegardlessOfRecordOrder")
@safe
unittest
{
    // geninfo writes BRDA before DA; Istanbul writes it after. Both must
    // attribute the branches to line 2 — matching on adjacency found neither.
    enum before = "SF:a.c\nBRDA:2,0,0,3\nBRDA:2,0,1,0\nDA:1,1\nDA:2,1\nend_of_record\n";
    enum after = "SF:a.c\nDA:1,1\nDA:2,1\nBRDA:2,0,0,3\nBRDA:2,0,1,0\nend_of_record\n";

    foreach (doc; [before, after])
    {
        const report = parseLcovCoverage(doc);
        assert(report, "parse failed");
        const f = report.value.files[0];
        assert(f.totalBranches == 2 && f.coveredBranches == 1);

        const line2 = f.lineAt(2);
        assert(line2 !is null);
        assert(line2.branchesTotal == 2, "branches must reach the line record");
        assert(line2.branchesTaken == 1);
        // Executed, but not every way through it.
        assert(line2.state == LineState.partial);
    }
}

@("coverage.formats.lcov.functionRecordShapes")
@safe
unittest
{
    // LCOV 2.x adds an end line: `FN:<start>,<end>,<name>`. Reading it as the
    // 1.x shape produced the name "20,doWork", so FNDA never matched.
    const two = parseLcovCoverage("SF:a.c\nFN:10,doWork\nFNDA:7,doWork\nend_of_record\n");
    assert(two, "parse failed");
    assert(two.value.files[0].functions[0].functionName == "doWork");
    assert(two.value.files[0].functions[0].executionCount == 7);

    const three = parseLcovCoverage("SF:a.c\nFN:10,20,doWork\nFNDA:7,doWork\nend_of_record\n");
    assert(three, "parse failed");
    assert(three.value.files[0].functions[0].functionName == "doWork");
    assert(three.value.files[0].functions[0].startLine == 10);
    assert(three.value.files[0].functions[0].executionCount == 7);

    // A name containing a comma survives: the last field takes the remainder.
    const templated = parseLcovCoverage(
        "SF:a.c\nFN:1,2,pair<int,long>\nend_of_record\n");
    assert(templated, "parse failed");
    assert(templated.value.files[0].functions[0].functionName == "pair<int,long>");
}

@("coverage.formats.lcov.truncatedReportKeepsItsFile")
@safe
unittest
{
    // No `end_of_record`: the file used to be discarded along with every
    // record already read.
    const report = parseLcovCoverage("SF:src/a.c\nDA:1,5\nDA:2,0\n");
    assert(report, "parse failed");
    assert(report.value.files.length == 1);
    assert(report.value.files[0].coverableLines == 2);
    assert(report.value.files[0].coveredLines == 1);
}

@("coverage.formats.lcov.duplicateLinesMerge")
@safe
unittest
{
    // A merged tracefile repeats a line; `lcov -a` sums the counts. Appending
    // it twice inflated the coverable-line denominator.
    const report = parseLcovCoverage("SF:a.c\nDA:1,2\nDA:1,3\nend_of_record\n");
    assert(report, "parse failed");
    const f = report.value.files[0];
    assert(f.lines.length == 1);
    assert(f.lines[0].executionCount == 5);
    assert(f.coverableLines == 1);
}

@("coverage.formats.lcov.malformedRecordsAreReported")
@safe
unittest
{
    // Silence was the old failure mode: a bad record produced an empty or
    // wrong report with nothing to say about it.
    const short_ = parseLcovCoverage("SF:a.c\nDA:1\nend_of_record\n");
    assert(short_.hasError);
    assert(short_.error.code == ParseErrorCode.unexpectedEnd);

    const junk = parseLcovCoverage("SF:a.c\nDA:1,abc\nend_of_record\n");
    assert(junk.hasError);
    assert(junk.error.code == ParseErrorCode.unexpectedCharacter);

    // The offset points at the offending character: `abc` begins two bytes
    // into `DA:`'s data, which itself begins at byte 10.
    assert(junk.error.offset == "SF:a.c\nDA:1,".length);
}
