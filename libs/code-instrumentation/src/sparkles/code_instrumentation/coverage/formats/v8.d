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

Offsets are treated as byte offsets into the source text supplied by the
caller. They are validated rather than trusted: a bundle rebuilt since the
report was written yields offsets past the end, and reading those used to
abort the whole render with an `AssertError`.
*/
module sparkles.code_instrumentation.coverage.formats.v8;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.lineindex : LineIndex;
import sparkles.base.text.span : TextSpan;
import sparkles.wired.json.codec : fromJSON;
import sparkles.wired.policy : WireName, WireOptional, WireSkip;

import sparkles.code_instrumentation.coverage.model :
    CoverageReport, FileCoverage, FunctionCoverage, LineCoverage, LineState, SpanCoverage;

/// One V8 coverage range with byte offsets and execution count.
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

/**
Parses a Vitest / V8 coverage JSON document.

Params:
    jsonText = the whole payload
    sourceText = the script's source, needed to map byte offsets to lines.
        Without it only `spans` and `functions` are produced — there is
        nothing to resolve a line number against.

Returns: a `CoverageReport`, or a `ParseError` when the payload does not
    decode.
*/
ParseExpected!CoverageReport parseV8Coverage(const(char)[] jsonText,
    const(char)[] sourceText = null) @safe
{
    CoverageReport report;

    auto doc = fromJSON!V8CoverageDocument(jsonText);
    if (!doc)
        return parseErr!CoverageReport(ParseErrorCode.unexpectedCharacter, 0,
            "not a well-formed V8 coverage payload");

    foreach (ref script; doc.value.result)
    {
        FileCoverage file;
        file.sourcePath = normalizeFileUrl(script.url);

        const haveSource = sourceText.length != 0;
        LineIndex lineIdx;
        if (haveSource)
        {
            lineIdx = LineIndex(sourceText);
            file.totalLines = lineIdx.lineCount;
            file.lines.length = lineIdx.lineCount;
            foreach (i, ref line; file.lines)
            {
                line.lineNumber = i + 1;
                line.state = LineState.nonCode;
            }
        }

        foreach (ref fn; script.functions)
        {
            if (fn.ranges.length == 0)
                continue;

            // Ranges arrive outermost-first in practice, but nothing in the
            // protocol says so, and applying them in the wrong order silently
            // inverts the verdict. Sort by width, widest first.
            auto ranges = fn.ranges.dup;
            sortWidestFirst(ranges);

            const fnRange = ranges[0];
            size_t fnStartLine = 1;
            if (haveSource && fnRange.startOffset <= sourceText.length)
                fnStartLine = lineIdx.lineColAt(fnRange.startOffset).line + 1;

            file.functions ~= FunctionCoverage(
                functionName: fn.functionName,
                startLine: fnStartLine,
                executionCount: fnRange.executionCount,
            );

            foreach (ref rng; ranges)
            {
                // Untrusted offsets: an out-of-range pair is skipped rather
                // than asserted on, and the span goes through the checked
                // factory so an inverted one cannot become a literal that
                // trips `TextSpan`'s invariant as an uncatchable `Error`
                // somewhere downstream.
                if (haveSource && rng.endOffset > sourceText.length)
                    continue;
                const span = TextSpan.of(rng.startOffset, rng.endOffset);
                if (!span.isValid)
                    continue;

                file.spans ~= SpanCoverage(
                    span: span,
                    executionCount: rng.executionCount,
                    isBlockCoverage: fn.isBlockCoverage,
                );

                if (haveSource)
                    applyRange(file, lineIdx, rng);
            }
        }

        tallyLines(file);
        report.files ~= file;
    }

    return parseOk(report);
}

/// Insertion sort by descending span width — a function has a handful of
/// ranges, and this keeps the parser allocation-light and stable.
private void sortWidestFirst(V8Range[] ranges) @safe pure nothrow @nogc
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
    in V8Range rng) @safe
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
    const report = parseV8Coverage(v8Json, src);
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

@("coverage.formats.v8.offsetsPastTheSourceAreSkipped")
@safe
unittest
{
    // A bundle rebuilt since the report was written. This used to escape as
    // an `AssertError` from `LineIndex`, which `catch (Exception)` cannot
    // contain, so hue died instead of degrading.
    enum src = "function f() {\n  hit();\n}\n";
    enum json = `{"result":[{"url":"f.js","functions":[{"functionName":"f",
        "isBlockCoverage":true,"ranges":[{"startOffset":0,"endOffset":9999,"count":1}]}]}]}`;

    const report = parseV8Coverage(json, src);
    assert(report, "an out-of-range offset degrades, it does not throw");
    assert(report.value.files[0].spans.length == 0);
}

@("coverage.formats.v8.invertedRangeIsSkipped")
@safe
unittest
{
    // `TextSpan`'s invariant rejects start > end, and it fires at whichever
    // member call happens to come first — far from the bad data.
    enum src = "a();b();\n";
    enum json = `{"result":[{"url":"f.js","functions":[{"functionName":"g",
        "isBlockCoverage":true,"ranges":[{"startOffset":7,"endOffset":2,"count":1}]}]}]}`;

    const report = parseV8Coverage(json, src);
    assert(report, "an inverted range degrades, it does not throw");
    assert(report.value.files[0].spans.length == 0);
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

    const report = parseV8Coverage(json, src);
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

    const a = parseV8Coverage(outerFirst, src);
    const b = parseV8Coverage(innerFirst, src);
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
    const truncated = parseV8Coverage(`{"result":[{"url":`, "x");
    assert(truncated.hasError);
}
