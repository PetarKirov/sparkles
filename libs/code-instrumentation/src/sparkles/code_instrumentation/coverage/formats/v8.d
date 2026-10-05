/**
Parser for JavaScript / TypeScript V8 coverage (Vitest, Node.js `node:inspector`).

V8 block coverage is *nested*, not flat. A function's first range spans the
whole function and carries its execution count; inner ranges carve out
sub-expressions that ran a different number of times, and a count of 0 means
the enclosing code ran but that piece did not.

Two consequences drive this parser:

$(UL
$(LI Ranges must be applied outermost-first, or the result depends on the
    order the producer happened to emit them — the same coverage could read
    as covered or uncovered.)
$(LI A zero-count range that only *partially* covers a line does not make the
    line unexecuted. `if (c) { miss(); }` runs every time its condition is
    evaluated; only the `{ miss(); }` block did not. That line is
    `LineState.partial`, and the byte-exact truth stays in `spans`.)
)

Offsets are JavaScript UTF-16 code units, not UTF-8 source bytes. Each script
requires its own original UTF-8 source snapshot. The owned source map converts
only exact scalar boundaries; stale/out-of-range offsets and surrogate interiors
are structured errors, never skipped or clamped.
*/
module sparkles.code_instrumentation.coverage.formats.v8;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.lineindex : LineIndex;
import sparkles.base.text.span : TextSpan;
import sparkles.base.text.source_map : SourceMapKey, SourceMapWorkspace,
    SourceMapBoundary, SourceMapEpoch, SourceByteOffset, Utf16Offset,
    MapStatus, buildSourceMap;
import sparkles.base.text.width : CellPolicy;
import sparkles.wired.json.codec : fromJSON;
import sparkles.wired.policy : WireName, WireOptional, WireSkip;

import sparkles.code_instrumentation.coverage.model :
    CoverageReport, FileCoverage, FunctionCoverage, LineCoverage, LineState, SpanCoverage;

/// One V8 coverage range with native UTF-16 code-unit offsets and execution count.
struct V8Range
{
    @WireName("startOffset") uint startOffset;
    @WireName("endOffset") uint endOffset;
    @WireName("count") ulong executionCount;
}

/// Function coverage in V8 payload.
struct V8Function
{
    @WireName("functionName") string functionName;
    @WireName("ranges") V8Range[] ranges;
    @WireOptional(WireSkip.whenDefault) @WireName("isBlockCoverage") bool isBlockCoverage;
}

/// Script / file coverage in V8 payload.
struct V8ScriptCoverage
{
    @WireOptional(WireSkip.whenDefault) @WireName("scriptId") string scriptId;
    @WireName("url") string url;
    @WireName("functions") V8Function[] functions;
}

/// Top-level V8 coverage container.
struct V8CoverageDocument
{
    @WireName("result") V8ScriptCoverage[] result;
}

/// Resolves a normalized script path to its borrowed original UTF-8 snapshot.
/// The snapshot must remain alive and unchanged through the entire parse.
/// A missing script is an error, distinct from a valid empty snapshot.
alias V8SourceResolver = ParseExpected!(const(char)[]) delegate(
    const(char)[] scriptPath) @safe;
/// Explicit report projection: false excludes a script before source resolution.
/// Null selects all scripts; selected reports contain only selected entries.
alias V8ScriptSelector = bool delegate(const(char)[] scriptPath) @safe;

/**
Parses a Vitest / V8 coverage JSON document.
The resolver is called once per selected script; ranges share its owned map.
Returns a report containing only original UTF-8 byte spans, or a structured
payload, source-resolution, malformed-source or invalid-producer-offset error.
*/
ParseExpected!CoverageReport parseV8Coverage(const(char)[] jsonText,
    scope V8SourceResolver resolveSource, scope V8ScriptSelector selectScript = null) @safe
{
    CoverageReport report;

    auto doc = fromJSON!V8CoverageDocument(jsonText);
    if (!doc)
        return parseErr!CoverageReport(ParseErrorCode.unexpectedCharacter, 0,
            "not a well-formed V8 coverage payload");

    foreach (scriptIndex, ref script; doc.value.result)
    {
        FileCoverage file;
        file.sourcePath = normalizeFileUrl(script.url);
        if (selectScript !is null && !selectScript(file.sourcePath))
            continue;

        if (resolveSource is null)
            return parseErr!CoverageReport(ParseErrorCode.unknownValue, 0,
                "V8 coverage requires original source snapshots");
        auto resolved = resolveSource(file.sourcePath);
        if (!resolved)
            return parseErr!CoverageReport(resolved.error);
        const sourceText = resolved.value;
        SourceMapKey key;
        // Identities are local to this parse and its distinct borrowed snapshots.
        key.sourceIdentity = scriptIndex + 1;
        key.sourceRevision = 1;
        key.cellPolicy = CellPolicy.none;
        key.cellPolicyRevision = 0;
        auto workspace = SourceMapWorkspace(epoch: new SourceMapEpoch[1]);
        auto mapped = buildSourceMap(sourceText, key, workspace);
        if (mapped.status == MapStatus.workspaceFull)
        {
            workspace.boundaries = new SourceMapBoundary[mapped.requiredBoundaries];
            mapped = buildSourceMap(sourceText, key, workspace);
        }
        if (!mapped.succeeded())
            return parseErr!CoverageReport(mapped.status == MapStatus.overflow
                ? ParseErrorCode.numericOverflow : ParseErrorCode.invalidUtf8,
                mapped.blocking.value, mapped.status == MapStatus.overflow
                    ? "V8 original source map overflows"
                    : "V8 original source is not valid UTF-8");
        const map = mapped.view;
        const lineIdx = LineIndex(sourceText);
        file.totalLines = lineIdx.lineCount;
        file.lines.length = lineIdx.lineCount;
        foreach (i, ref line; file.lines)
        {
            line.lineNumber = i + 1;
            line.state = LineState.nonCode;
        }

        foreach (ref fn; script.functions)
        {
            if (fn.ranges.length == 0)
                continue;

            // Ranges arrive outermost-first in practice, but nothing in the
            // protocol says so, and applying them in the wrong order silently
            // inverts the verdict. Sort by width, widest first.
            const ranges = fn.ranges;
            auto byteRanges = new ByteRange[ranges.length];
            foreach (i, range_; ranges)
            {
                if (range_.startOffset > range_.endOffset)
                    return producerOffsetError(ParseErrorCode.unexpectedCharacter,
                        range_.startOffset, "inverted UTF-16 range", file.sourcePath);
                const start = map.mapTo!SourceByteOffset(key, Utf16Offset(range_.startOffset));
                const end = map.mapTo!SourceByteOffset(key, Utf16Offset(range_.endOffset));
                if (!start.succeeded())
                    return producerOffsetError(start.status == MapStatus.notBoundary
                        ? ParseErrorCode.invalidSurrogate : ParseErrorCode.unexpectedEnd,
                        range_.startOffset, "invalid UTF-16 startOffset", file.sourcePath);
                if (!end.succeeded())
                    return producerOffsetError(end.status == MapStatus.notBoundary
                        ? ParseErrorCode.invalidSurrogate : ParseErrorCode.unexpectedEnd,
                        range_.endOffset, "invalid UTF-16 endOffset", file.sourcePath);
                if (start.value.value >= uint.max || end.value.value >= uint.max)
                    return producerOffsetError(ParseErrorCode.numericOverflow,
                        range_.endOffset, "UTF-8 byte span exceeds TextSpan capacity", file.sourcePath);
                byteRanges[i] = ByteRange(cast(uint) start.value.value,
                    cast(uint) end.value.value, range_.executionCount);
            }
            sortWidestFirst(byteRanges);

            const fnRange = byteRanges[0];
            const fnStartLine = lineIdx.lineColAt(fnRange.startOffset).line + 1;

            file.functions ~= FunctionCoverage(
                functionName: fn.functionName,
                startLine: fnStartLine,
                executionCount: fnRange.executionCount,
            );

            foreach (ref rng; byteRanges)
            {
                const span = TextSpan.of(rng.startOffset, rng.endOffset);

                file.spans ~= SpanCoverage(
                    span: span,
                    executionCount: rng.executionCount,
                    isBlockCoverage: fn.isBlockCoverage,
                );

                applyRange(file, lineIdx, rng);
            }
        }

        tallyLines(file);
        report.files ~= file;
    }

    return parseOk(report);
}
private struct ByteRange
{
    uint startOffset;
    uint endOffset;
    ulong executionCount;
}

private ParseExpected!CoverageReport producerOffsetError(ParseErrorCode code,
    size_t offset, string reason, string path) @safe
{
    import std.format : format;
    // ParseError.offset is a byte coordinate, not the producer's UTF-16 unit.
    // No JSON token position is retained by the codec; detail carries the unit.
    return parseErr!CoverageReport(code, 0,
        format("V8 %s %s at UTF-16 offset %s", path, reason, offset));
}


/// Insertion sort by descending span width — a function has a handful of
/// ranges, and this keeps the parser allocation-light and stable.
private void sortWidestFirst(ByteRange[] ranges) @safe pure nothrow @nogc
{
    foreach (i; 1 .. ranges.length)
    {
        const item = ranges[i];
        const width = item.endOffset - item.startOffset;
        size_t j = i;
        while (j > 0 && (ranges[j - 1].endOffset - ranges[j - 1].startOffset) < width)
        {
            ranges[j] = ranges[j - 1];
            j--;
        }
        ranges[j] = item;
    }
}

/**
Applies one range to the line records it touches.

A range fully containing a line sets that line's count outright. A range that
only overlaps part of a line — its first and last lines, typically — can raise
a count but never zero one: the rest of that line may still have run.
*/
// `ref const` rather than `in`: `in` implies `scope`, and `LineIndex`'s
// accessors are not scope members (AGENTS.md, dip1000 clash).
private void applyRange(ref FileCoverage file, ref const LineIndex lineIdx,
    in ByteRange rng) @safe
{
    const startLine = lineIdx.lineColAt(rng.startOffset).line;
    const endOffset = rng.endOffset > rng.startOffset ? rng.endOffset - 1 : rng.startOffset;
    const endLine = lineIdx.lineColAt(endOffset).line;

    foreach (l; startLine .. endLine + 1)
    {
        if (l >= file.lines.length)
            break;
        auto line = &file.lines[l];
        const whole = l != startLine && l != endLine;

        if (rng.executionCount == 0)
        {
            if (whole)
            {
                // Entirely inside the dead range: unambiguously not executed.
                line.state = LineState.uncovered;
                line.executionCount = 0;
            }
            else if (line.state == LineState.covered)
            {
                // Boundary line: part of it ran, part did not.
                line.state = LineState.partial;
            }
            else if (line.state == LineState.nonCode)
            {
                line.state = LineState.uncovered;
            }
            continue;
        }

        if (line.state == LineState.nonCode || line.executionCount < rng.executionCount)
        {
            line.executionCount = rng.executionCount;
            // A line already known partial stays partial: a later, wider
            // range does not un-carve the hole a nested one made.
            if (line.state != LineState.partial)
                line.state = LineState.covered;
        }
    }
}

/// Recomputes the file's line totals from its line records.
private void tallyLines(ref FileCoverage file) @safe pure nothrow @nogc
{
    file.coverableLines = 0;
    file.coveredLines = 0;
    foreach (ref l; file.lines)
    {
        if (l.state == LineState.nonCode)
            continue;
        file.coverableLines++;
        if (l.state == LineState.covered || l.state == LineState.partial)
            file.coveredLines++;
    }
}

private string normalizeFileUrl(const(char)[] url) @safe
{
    import std.algorithm.searching : startsWith;

    if (url.startsWith("file://"))
        return url["file://".length .. $].idup;
    return url.idup;
}

@("coverage.formats.v8.basic")
@safe
unittest
{
    enum v8Json = `{
        "result": [
            {
                "scriptId": "42",
                "url": "file:///app/src/index.ts",
                "functions": [
                    {
                        "functionName": "main",
                        "isBlockCoverage": true,
                        "ranges": [
                            { "startOffset": 0, "endOffset": 50, "count": 1 },
                            { "startOffset": 20, "endOffset": 35, "count": 0 }
                        ]
                    }
                ]
            }
        ]
    }`;

    enum src = "function main() {\n    if (false) {\n        never();\n    }\n}\n";
    const report = parseV8Coverage(v8Json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    assert(report, "parse failed");
    const f = report.value.files[0];
    assert(f.sourcePath == "/app/src/index.ts");
    assert(f.functions.length == 1);
    assert(f.functions[0].functionName == "main");
    assert(f.functions[0].executionCount == 1);
    assert(f.spans.length == 2);
    assert(f.spans[0].span == TextSpan(0, 50));
    assert(f.spans[0].executionCount == 1);
    assert(f.spans[1].span == TextSpan(20, 35));
    assert(f.spans[1].executionCount == 0);
}

@("coverage.formats.v8.offsetsPastTheSourceAreErrors")
@safe
unittest
{
    // A bundle rebuilt since the report was written. This used to escape as
    // an `AssertError` from `LineIndex`, which `catch (Exception)` cannot
    // contain, so hue died instead of degrading.
    enum src = "function f() {\n  hit();\n}\n";
    enum json = `{"result":[{"url":"f.js","functions":[{"functionName":"f",
        "isBlockCoverage":true,"ranges":[{"startOffset":0,"endOffset":9999,"count":1}]}]}]}`;

    const report = parseV8Coverage(json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    assert(report.hasError);
    assert(report.error.code == ParseErrorCode.unexpectedEnd);
}

@("coverage.formats.v8.invertedRangeIsAnError")
@safe
unittest
{
    // `TextSpan`'s invariant rejects start > end, and it fires at whichever
    // member call happens to come first — far from the bad data.
    enum src = "a();b();\n";
    enum json = `{"result":[{"url":"f.js","functions":[{"functionName":"g",
        "isBlockCoverage":true,"ranges":[{"startOffset":7,"endOffset":2,"count":1}]}]}]}`;

    const report = parseV8Coverage(json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    assert(report.hasError);
    assert(report.error.code == ParseErrorCode.unexpectedCharacter);
}

@("coverage.formats.v8.nestedZeroRangeMakesTheLinePartial")
@safe
unittest
{
    //          0         1         2         3         4
    //          0123456789012345678901234567890123456789012345
    enum src = "function f() {\n  if (c) { miss(); }\n  hit();\n}\n";
    // The whole function ran 9 times; the `{ miss(); }` block never did.
    enum json = `{"result":[{"url":"f.js","functions":[{"functionName":"f",
        "isBlockCoverage":true,"ranges":[
            {"startOffset":0,"endOffset":46,"count":9},
            {"startOffset":24,"endOffset":35,"count":0}]}]}]}`;

    const report = parseV8Coverage(json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    assert(report, "parse failed");
    const f = report.value.files[0];

    // Line 2 holds both the `if` (which ran) and the dead block. Marking the
    // whole line uncovered claimed the condition was never evaluated.
    const line2 = f.lineAt(2);
    assert(line2 !is null);
    assert(line2.state == LineState.partial);

    // Lines wholly inside the live range are plain covered.
    assert(f.lineAt(3).state == LineState.covered);
    assert(f.lineAt(3).executionCount == 9);
}

@("coverage.formats.v8.verdictDoesNotDependOnRangeOrder")
@safe
unittest
{
    // The same coverage, emitted in both orders. Applying ranges as they
    // arrive made the last one win, so these disagreed.
    enum src = "function f() {\n  if (c) { miss(); }\n  hit();\n}\n";
    enum outerFirst = `{"result":[{"url":"f.js","functions":[{"functionName":"f",
        "isBlockCoverage":true,"ranges":[
            {"startOffset":0,"endOffset":46,"count":9},
            {"startOffset":24,"endOffset":35,"count":0}]}]}]}`;
    enum innerFirst = `{"result":[{"url":"f.js","functions":[{"functionName":"f",
        "isBlockCoverage":true,"ranges":[
            {"startOffset":24,"endOffset":35,"count":0},
            {"startOffset":0,"endOffset":46,"count":9}]}]}]}`;

    const a = parseV8Coverage(outerFirst,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    const b = parseV8Coverage(innerFirst,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) src));
    assert(a && b, "parse failed");

    foreach (l; 1 .. 5)
    {
        const left = a.value.files[0].lineAt(l);
        const right = b.value.files[0].lineAt(l);
        assert((left is null) == (right is null));
        if (left !is null)
        {
            assert(left.state == right.state, "range order changed the verdict");
            assert(left.executionCount == right.executionCount);
        }
    }
}

@("coverage.formats.v8.malformedPayloadIsReported")
@safe
unittest
{
    const truncated = parseV8Coverage(`{"result":[{"url":`, null);
    assert(truncated.hasError);
}

@("coverage.formats.v8.utf16RangesUseOriginalUtf8Bytes")
@safe unittest
{
    // UTF-16 boundaries: 0,1,3,4,5,6,7. UTF-8 boundaries: 0,1,5,6,9,10,11.
    enum source = "A\U0001F600\n\u754CB\n";
    enum json = `{"result":[{"url":"unicode.js","functions":[{"functionName":"wide",
        "ranges":[{"startOffset":4,"endOffset":6,"count":3}]}]}]}`;
    const parsed = parseV8Coverage(json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) source));
    assert(parsed);
    const file = parsed.value.files[0];
    assert(file.spans[0].span == TextSpan(6, 10));
    assert(file.functions[0].startLine == 2);
    assert(file.lineAt(1).state == LineState.nonCode);
    assert(file.lineAt(2).state == LineState.covered);
    assert(file.lineAt(2).executionCount == 3);
    assert(file.lineAt(3).state == LineState.nonCode);
}

@("coverage.formats.v8.surrogateInteriorsAreErrors")
@safe unittest
{
    enum source = "A\U0001F600\u754C";
    enum badStart = `{"result":[{"url":"u.js","functions":[{"functionName":"f",
        "ranges":[{"startOffset":2,"endOffset":4,"count":1}]}]}]}`;
    enum badEnd = `{"result":[{"url":"u.js","functions":[{"functionName":"f",
        "ranges":[{"startOffset":1,"endOffset":2,"count":1}]}]}]}`;
    foreach (json; [badStart, badEnd])
    {
        const parsed = parseV8Coverage(json,
            (const(char)[] _) @safe => parseOk(cast(const(char)[]) source));
        assert(parsed.hasError);
        assert(parsed.error.code == ParseErrorCode.invalidSurrogate);
    }
}

@("coverage.formats.v8.scriptsResolveDistinctSnapshots")
@safe unittest
{
    enum json = `{"result":[
        {"url":"file:///a.js","functions":[{"functionName":"a",
            "ranges":[{"startOffset":0,"endOffset":2,"count":1}]}]},
        {"url":"b.js","functions":[{"functionName":"b",
            "ranges":[{"startOffset":0,"endOffset":2,"count":0}]}]}]}`;
    const parsed = parseV8Coverage(json, (const(char)[] path) @safe {
        return parseOk(cast(const(char)[]) (path == "/a.js"
            ? "\U0001F600" : "\u754Cx"));
    });
    assert(parsed);
    assert(parsed.value.files[0].spans[0].span == TextSpan(0, 4));
    assert(parsed.value.files[1].spans[0].span == TextSpan(0, 4));
    assert(parsed.value.files[0].lineAt(1).state == LineState.covered);
    assert(parsed.value.files[1].lineAt(1).state == LineState.uncovered);
}

@("coverage.formats.v8.malformedSuffixCannotBeBypassed")
@safe unittest
{
    enum json = `{"result":[{"url":"u.js","functions":[{"functionName":"f",
        "ranges":[{"startOffset":0,"endOffset":1,"count":1}]}]}]}`;
    const parsed = parseV8Coverage(json,
        (const(char)[] _) @safe => parseOk(cast(const(char)[]) "x\xFF"));
    assert(parsed.hasError && parsed.error.code == ParseErrorCode.invalidUtf8);
    assert(parsed.error.offset == 1);
}
