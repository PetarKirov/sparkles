/**
Parser for `llvm-cov export` JSON.

The payload's per-file `segments` array is the interesting part. A segment is

    [line, column, count, hasCount, isRegionEntry, isGapRegion]

and only some of them state an execution count. A segment with `hasCount`
false marks a region *ending* — its count field is meaningless — and a gap
region covers text (a brace on its own line, say) that carries no independent
count. Reading those two as real counts is how region boundaries came to be
rendered as missed lines.

Several segments can also share a line; the line ran if any of them ran, so
they aggregate by maximum rather than first-wins.
*/
module sparkles.code_instrumentation.coverage.formats.llvm;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.wired.json.document : JsonKind, JsonValue;
import sparkles.wired.json.reader : parseJsonDocument;

import sparkles.code_instrumentation.coverage.model :
    CoverageReport, FileCoverage, LineCoverage, LineState;

/// A JSON number as `ulong`, whichever integral kind it decoded as.
private bool asNumber(in JsonValue v, out ulong result) @safe
{
    if (v.kind == JsonKind.integer)
    {
        if (v.integer < 0)
            return false;
        result = cast(ulong) v.integer;
        return true;
    }
    if (v.kind == JsonKind.uinteger)
    {
        result = v.uinteger;
        return true;
    }
    return false;
}

/// A JSON boolean, defaulting to `fallback` when the field is absent or not a
/// boolean — older exporters omit the flags entirely.
private bool asBool(in JsonValue v, bool fallback) @safe
    => v.kind == JsonKind.bool_ ? v.boolean : fallback;

/**
Parses an `llvm-cov export` JSON payload.

Params:
    jsonText = the whole document

Returns: a `CoverageReport`, or a `ParseError` when the document does not
    parse or is not shaped like an llvm-cov export.
*/
ParseExpected!CoverageReport parseLlvmExportJson(const(char)[] jsonText) @safe
{
    CoverageReport report;

    auto parsed = parseJsonDocument(jsonText);
    if (!parsed.hasValue)
        return parseErr!CoverageReport(ParseErrorCode.unexpectedCharacter, 0,
            "not well-formed JSON");

    const root = parsed.document.root;
    if (root.kind != JsonKind.object)
        return parseErr!CoverageReport(ParseErrorCode.unexpectedCharacter, 0,
            "llvm-cov export must be a JSON object");

    const dataArr = root.objectGet("data");
    if (dataArr.kind != JsonKind.array)
        return parseErr!CoverageReport(ParseErrorCode.unexpectedEnd, 0,
            "missing 'data' array");

    foreach (d; dataArr.byElement)
    {
        if (d.kind != JsonKind.object)
            continue;
        const filesArr = d.objectGet("files");
        if (filesArr.kind != JsonKind.array)
            continue;

        foreach (fe; filesArr.byElement)
        {
            if (fe.kind != JsonKind.object)
                continue;

            FileCoverage file;
            const fnVal = fe.objectGet("filename");
            if (fnVal.kind == JsonKind.string_)
                file.sourcePath = fnVal.str.idup;

            readSegments(fe.objectGet("segments"), file);
            readSummary(fe.objectGet("summary"), file);

            report.files ~= file;
        }
    }

    return parseOk(report);
}

/// Builds `file.lines` from the `segments` array, honouring the flags.
private void readSegments(in JsonValue segsArr, ref FileCoverage file) @safe
{
    if (segsArr.kind != JsonKind.array)
        return;

    // Line number → index into `file.lines`, so repeated segments on one line
    // aggregate instead of the first one winning.
    size_t[size_t] indexOfLine;

    foreach (seg; segsArr.byElement)
    {
        if (seg.kind != JsonKind.array || seg.length < 3)
            continue;

        ulong line, count;
        bool hasCount = true, isGap;
        size_t idx;
        foreach (elem; seg.byElement)
        {
            switch (idx)
            {
                case 0: if (!asNumber(elem, line)) return; break;
                case 2: cast(void) asNumber(elem, count); break;
                case 3: hasCount = asBool(elem, true); break;
                case 5: isGap = asBool(elem, false); break;
                default: break;
            }
            idx++;
        }

        // A region *exit* carries no count of its own, and a gap region is
        // text between regions rather than code with its own counter.
        if (!hasCount || isGap || line == 0)
            continue;

        // Plain `size_t`, not `const`: on a 64-bit target `size_t` is
        // `ulong`, so a `const` cast here is a no-op whose result DMD
        // deprecates using as an associative-array lvalue.
        size_t key = cast(size_t) line;
        if (auto at = key in indexOfLine)
        {
            if (file.lines[*at].executionCount < count)
                file.lines[*at].executionCount = count;
        }
        else
        {
            indexOfLine[key] = file.lines.length;
            file.lines ~= LineCoverage(lineNumber: key, executionCount: count);
        }
    }

    foreach (ref line; file.lines)
        line.state = line.executionCount > 0 ? LineState.covered : LineState.uncovered;
}

/// Applies the file's `summary` object. llvm-cov computes these over regions
/// rather than the segment list, so they are authoritative where present; the
/// segment-derived counts stand in when they are not.
private void readSummary(in JsonValue summaryObj, ref FileCoverage file) @safe
{
    size_t derivedCoverable, derivedCovered;
    foreach (ref line; file.lines)
    {
        derivedCoverable++;
        if (line.state == LineState.covered)
            derivedCovered++;
    }
    file.coverableLines = derivedCoverable;
    file.coveredLines = derivedCovered;

    // `totalLines` means physical lines, which the payload never states; the
    // highest line carrying a segment is the closest honest answer.
    size_t highest;
    foreach (ref line; file.lines)
        if (line.lineNumber > highest)
            highest = line.lineNumber;
    file.totalLines = highest;

    if (summaryObj.kind != JsonKind.object)
        return;

    const linesObj = summaryObj.objectGet("lines");
    if (linesObj.kind == JsonKind.object)
    {
        ulong n;
        if (asNumber(linesObj.objectGet("count"), n))
            file.coverableLines = cast(size_t) n;
        if (asNumber(linesObj.objectGet("covered"), n))
            file.coveredLines = cast(size_t) n;
    }

    const branchesObj = summaryObj.objectGet("branches");
    if (branchesObj.kind == JsonKind.object)
    {
        ulong n;
        if (asNumber(branchesObj.objectGet("count"), n))
            file.totalBranches = cast(size_t) n;
        if (asNumber(branchesObj.objectGet("covered"), n))
            file.coveredBranches = cast(size_t) n;
    }
}

@("coverage.formats.llvm.basic")
@safe
unittest
{
    enum llvmJson = `{
        "version": "2.0.1",
        "type": "llvm.coverage.json.export",
        "data": [
            {
                "files": [
                    {
                        "filename": "/src/core.cpp",
                        "segments": [
                            [1, 1, 5, true, true, false],
                            [3, 1, 0, true, true, false]
                        ],
                        "summary": {
                            "lines": { "count": 10, "covered": 8, "percent": 80.0 },
                            "branches": { "count": 2, "covered": 1, "percent": 50.0 }
                        }
                    }
                ]
            }
        ]
    }`;

    const report = parseLlvmExportJson(llvmJson);
    assert(report, "parse failed");
    const f = report.value.files[0];
    assert(f.sourcePath == "/src/core.cpp");
    assert(f.coverableLines == 10);
    assert(f.coveredLines == 8);
    assert(f.linePercent == 80.0);
    assert(f.totalBranches == 2);
    assert(f.coveredBranches == 1);
    assert(f.lines.length == 2);
    assert(f.lines[0].executionCount == 5);
    assert(f.lines[1].executionCount == 0);
}

@("coverage.formats.llvm.regionExitsAreNotMissedLines")
@safe
unittest
{
    // Segment 2 is a region *exit* (hasCount false) and segment 3 a gap
    // region. Neither states a count, but both used to be recorded as lines
    // that ran zero times — closing braces rendered red.
    enum json = `{"data":[{"files":[{"filename":"a.c","segments":[
        [2,1,7,true,true,false],
        [4,2,0,false,false,false],
        [5,1,0,true,false,true]
    ]}]}]}`;

    const report = parseLlvmExportJson(json);
    assert(report, "parse failed");
    const f = report.value.files[0];
    assert(f.lines.length == 1, "only the counted segment is a line");
    assert(f.lines[0].lineNumber == 2);
    assert(f.lines[0].executionCount == 7);
}

@("coverage.formats.llvm.segmentsOnOneLineAggregate")
@safe
unittest
{
    // A line with several regions ran if any of them ran. First-wins reported
    // the line uncovered whenever its first region happened to be the cold one.
    enum json = `{"data":[{"files":[{"filename":"a.c","segments":[
        [7,1,0,true,true,false],
        [7,20,4,true,true,false]
    ]}]}]}`;

    const report = parseLlvmExportJson(json);
    assert(report, "parse failed");
    const f = report.value.files[0];
    assert(f.lines.length == 1);
    assert(f.lines[0].executionCount == 4);
    assert(f.lines[0].state == LineState.covered);
}

@("coverage.formats.llvm.malformedDocumentsAreReported")
@safe
unittest
{
    assert(parseLlvmExportJson(`{"data":`).hasError);
    assert(parseLlvmExportJson(`[]`).hasError);

    const noData = parseLlvmExportJson(`{"type":"llvm.coverage.json.export"}`);
    assert(noData.hasError);
    assert(noData.error.code == ParseErrorCode.unexpectedEnd);
}
