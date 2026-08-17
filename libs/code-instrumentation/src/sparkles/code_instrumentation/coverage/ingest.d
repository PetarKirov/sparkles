/**
Format detection and universal coverage report ingestion.

Detection is deliberately conservative. The heuristics here used to match a
bare substring anywhere in the file — `"ranges"` meant V8, `"segments"` meant
llvm-cov, `#####:` meant gcov — so an ordinary D source that mentioned
"ranges" in a comment, or a markdown page documenting gcov, classified as a
coverage report. Every marker is now anchored to the position the format
actually puts it in, and the JSON forms must additionally carry the right root
shape.
*/
module sparkles.code_instrumentation.coverage.ingest;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.code_instrumentation.coverage.formats.dmd : parseDmdCoverage;
import sparkles.code_instrumentation.coverage.formats.gcov : parseGcovCoverage;
import sparkles.code_instrumentation.coverage.formats.lcov : parseLcovCoverage;
import sparkles.code_instrumentation.coverage.formats.llvm : parseLlvmExportJson;
import sparkles.code_instrumentation.coverage.formats.v8 : parseV8Coverage;
import sparkles.code_instrumentation.coverage.model : CoverageReport, FileCoverage;
import sparkles.code_instrumentation.coverage.record : RecordScanner, splitOnce, trimmed;

/// The recognized code coverage format kinds.
enum CoverageFormat : ubyte
{
    unknown,
    dmdLst,   /// DMD / LDC `-cov` (.lst)
    gcov,     /// GCC / GDC gcov (.gcov)
    lcov,     /// Standard LCOV (.info)
    v8Json,   /// Vitest / Node.js V8 coverage JSON
    llvmJson, /// llvm-cov export JSON
}

/// Case-insensitive extension test — `.LST` is the same artifact as `.lst`.
private bool hasExtension(const(char)[] path, string extension) @safe pure nothrow @nogc
{
    import std.ascii : toLower;

    if (path.length < extension.length)
        return false;
    const tail = path[$ - extension.length .. $];
    foreach (i, c; tail)
        if (toLower(c) != extension[i])
            return false;
    return true;
}

/**
The format `path` names by extension alone, ignoring its contents.

This is the trustworthy half of detection: an extension is a statement by
whoever produced the file, where a content match is a guess about a file
someone asked to view. A caller deciding whether to *act* on a file — rather
than parsing one it was explicitly handed — should use this.

Returns: the format, or `unknown` when the extension says nothing.
*/
CoverageFormat formatFromExtension(const(char)[] path) @safe pure nothrow @nogc
{
    if (path.hasExtension(".lst"))
        return CoverageFormat.dmdLst;
    if (path.hasExtension(".gcov"))
        return CoverageFormat.gcov;
    if (path.hasExtension(".info") || path.hasExtension(".lcov"))
        return CoverageFormat.lcov;
    return CoverageFormat.unknown;
}

/**
Detects the coverage format of a file from its path extension, then its
contents.

Params:
    path = the artifact's path, consulted first
    contents = the artifact's text

Returns: the detected format, or `unknown`.
*/
CoverageFormat detectFormat(const(char)[] path, const(char)[] contents) @safe
{
    const byExtension = formatFromExtension(path);
    if (byExtension != CoverageFormat.unknown)
        return byExtension;

    if (looksLikeLcov(contents))
        return CoverageFormat.lcov;
    if (looksLikeGcov(contents))
        return CoverageFormat.gcov;
    if (looksLikeDmdLst(contents))
        return CoverageFormat.dmdLst;

    const json = detectJsonFormat(contents);
    if (json != CoverageFormat.unknown)
        return json;

    return CoverageFormat.unknown;
}

/// An LCOV block: an `SF:` record at the start of a line, and the
/// `end_of_record` that closes it. Requiring both keeps prose that merely
/// quotes an `SF:` line from qualifying.
private bool looksLikeLcov(const(char)[] contents) @safe
{
    bool sawSourceFile, sawEndOfRecord;
    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const record = scanner.line.trimmed;
        if (record.length > 3 && record[0 .. 3] == "SF:")
            sawSourceFile = true;
        else if (record == "end_of_record")
            sawEndOfRecord = true;
        if (sawSourceFile && sawEndOfRecord)
            return true;
    }
    return false;
}

/// A gcov listing: a `<count>:<line>:` prefix on its own lines, including the
/// line-0 preamble gcov always writes.
private bool looksLikeGcov(const(char)[] contents) @safe
{
    import sparkles.code_instrumentation.coverage.record : wholeNumber;

    auto scanner = RecordScanner(contents);
    size_t prefixed;
    while (scanner.next)
    {
        const first = splitOnce(scanner.line, ':');
        if (!first.found)
            continue;
        const second = splitOnce(first.after, ':');
        if (!second.found)
            continue;
        // The line-number column must be a number, and the counter column
        // must be one of gcov's four spellings.
        if (!wholeNumber(second.before, 0))
            continue;
        const count = first.before.trimmed;
        if (count == "-" || count == "#####" || count == "=====" || wholeNumber(count, 0))
            prefixed++;
        if (prefixed >= 2)
            return true;
    }
    return false;
}

/// A DMD listing: `<counter>|` prefixes plus the trailer `-cov` always emits.
private bool looksLikeDmdLst(const(char)[] contents) @safe
{
    import std.algorithm.searching : endsWith;

    bool sawCounted, sawTrailer;
    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const record = scanner.line;
        const split = splitOnce(record, '|');
        if (split.found)
            sawCounted = true;
        else if (record.endsWith("% covered") || record.endsWith(" has no code"))
            sawTrailer = true;
    }
    return sawCounted && sawTrailer;
}

/// The JSON coverage forms, distinguished by root shape rather than by any
/// key name appearing somewhere in the text.
private CoverageFormat detectJsonFormat(const(char)[] contents) @safe
{
    import sparkles.wired.json.document : JsonKind;
    import sparkles.wired.json.reader : parseJsonDocument;

    auto parsed = parseJsonDocument(contents);
    if (!parsed.hasValue)
        return CoverageFormat.unknown;
    const root = parsed.document.root;
    if (root.kind != JsonKind.object)
        return CoverageFormat.unknown;

    if (root.objectGet("data").kind == JsonKind.array)
        return CoverageFormat.llvmJson;
    if (root.objectGet("result").kind == JsonKind.array)
        return CoverageFormat.v8Json;
    return CoverageFormat.unknown;
}

/**
Loads a `CoverageReport` from an artifact, dispatching on its detected format.

Params:
    path = the artifact's path, used for detection and as a fallback source
        path for the single-file formats
    contents = the artifact's text
    sourceText = the covered source, needed only by the V8 format to resolve
        byte offsets to lines

Returns: the report, or a `ParseError`. An unrecognized format is
    `unknownValue` rather than an empty report — "I could not read this" and
    "this describes nothing" are different answers, and the caller needs to
    tell them apart to honour the overlay degradation contract.
*/
ParseExpected!CoverageReport loadCoverage(const(char)[] path, const(char)[] contents,
    const(char)[] sourceText = null) @safe
{
    final switch (detectFormat(path, contents))
    {
        case CoverageFormat.dmdLst:
            // No override: the listing's trailer names the source it
            // describes, and the artifact's own path does not. Passing the
            // `.lst` path here made every lookup by source path miss.
            return parseDmdCoverage(contents).andThenReport;

        case CoverageFormat.gcov:
            return parseGcovCoverage(contents).andThenReport;

        case CoverageFormat.lcov:
            return parseLcovCoverage(contents);

        case CoverageFormat.v8Json:
            return parseV8Coverage(contents, sourceText);

        case CoverageFormat.llvmJson:
            return parseLlvmExportJson(contents);

        case CoverageFormat.unknown:
            return parseErr!CoverageReport(ParseErrorCode.unknownValue, 0,
                "not a recognized coverage format");
    }
}

/// Lifts a single-file parse into a one-file report, preserving any error.
private ParseExpected!CoverageReport andThenReport(ParseExpected!FileCoverage file) @safe
{
    if (!file)
        return parseErr!CoverageReport(file.error);
    CoverageReport report;
    report.files ~= file.value;
    return parseOk(report);
}

@("coverage.ingest.detectByExtension")
@safe
unittest
{
    assert(detectFormat("math.lst", "") == CoverageFormat.dmdLst);
    assert(detectFormat("math.gcov", "") == CoverageFormat.gcov);
    assert(detectFormat("lcov.info", "") == CoverageFormat.lcov);
    assert(detectFormat("coverage.lcov", "") == CoverageFormat.lcov);
    // An extension is a statement about the file, whatever its case.
    assert(detectFormat("MATH.LST", "") == CoverageFormat.dmdLst);
}

@("coverage.ingest.detectByContent")
@safe
unittest
{
    assert(detectFormat("cov.json", `{"type":"llvm.coverage.json.export","data":[]}`)
        == CoverageFormat.llvmJson);
    assert(detectFormat("cov.json", `{"result":[{"scriptId":"1"}]}`)
        == CoverageFormat.v8Json);
    assert(detectFormat("x", "SF:a.c\nDA:1,1\nend_of_record\n") == CoverageFormat.lcov);
    assert(detectFormat("x", "        -:    0:Source:a.c\n        1:    1:x();\n")
        == CoverageFormat.gcov);
    assert(detectFormat("x", "      5|  x();\nsrc/a.d is 100% covered\n")
        == CoverageFormat.dmdLst);
}

@("coverage.ingest.ordinaryFilesAreNotCoverageReports")
@safe
unittest
{
    // Each of these matched before, on a bare substring search.
    assert(detectFormat("app.d",
        "module app;\n/// Returns the \"ranges\" of the parse.\nvoid main() {}\n")
        == CoverageFormat.unknown);
    assert(detectFormat("notes.md",
        "# gcov notes\n\nUncovered lines print as `#####:` in the listing.\n")
        == CoverageFormat.unknown);
    assert(detectFormat("conf.json", `{ "compilerOptions": {}, "segments": [] }`)
        == CoverageFormat.unknown);
    // Prose quoting an LCOV record, without a record block to close it.
    assert(detectFormat("notes.md", "A block starts with\nSF:/some/path\n")
        == CoverageFormat.unknown);

    assert(detectFormat("x", "") == CoverageFormat.unknown);
    assert(detectFormat("x.bin", "\0\0\0\0") == CoverageFormat.unknown);
}

@("coverage.ingest.dmdListingKeepsItsTrailerPath")
@safe
unittest
{
    // The trailer names the source; the artifact path names the artifact.
    // Overriding with the latter made `findFile` miss every lookup, so hue
    // only ever attached coverage through a fallback that ignored paths.
    enum lst = "      5|    return a + b;\n"
        ~ "0000000|    return a - b;\n"
        ~ "libs/x/src/math.d is 50% covered\n";

    const report = loadCoverage("build/cov/math.lst", lst);
    assert(report, "parse failed");
    assert(report.value.files[0].sourcePath == "libs/x/src/math.d");
    assert(report.value.findFile("libs/x/src/math.d") !is null);
}

@("coverage.ingest.unknownFormatIsAnError")
@safe
unittest
{
    // Distinguishable from a valid report that happens to describe nothing.
    const unknown = loadCoverage("notes.md", "just some prose\n");
    assert(unknown.hasError);
    assert(unknown.error.code == ParseErrorCode.unknownValue);

    const empty = loadCoverage("empty.info", "");
    assert(empty, "a valid, empty LCOV report is not an error");
    assert(empty.value.files.length == 0);
}
