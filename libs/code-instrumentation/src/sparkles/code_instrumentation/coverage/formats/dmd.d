/**
Parser for DMD / LDC `-cov` listing (`.lst`) coverage files.

`dmd -cov` and `dub test -b unittest-cov` write one line per source line,
`<count>|<source>`, where the counter column is blank for a line that emitted
no code and `0000000` for one that emitted code but never ran. A trailer names
the source the listing describes:

    libs/x/src/math.d is 50% covered
    libs/x/src/empty.d has no code
*/
module sparkles.code_instrumentation.coverage.formats.dmd;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

import sparkles.code_instrumentation.coverage.model :
    FileCoverage, LineCoverage, LineState;
import sparkles.code_instrumentation.coverage.record :
    RecordScanner, splitOnce, trimmed, wholeNumber;

/**
Parses a DMD `.lst` listing.

Params:
    contents = the whole listing
    overridePath = source path to record; when empty the trailer's is used.
        A caller that knows the source independently passes it, but the
        trailer wins over nothing — the listing names the file it describes,
        and the artifact's own path does not.

Returns: the `FileCoverage`, or a `ParseError` with a byte offset into
    `contents`.
*/
ParseExpected!FileCoverage parseDmdCoverage(const(char)[] contents,
    string overridePath = null) @safe
{
    FileCoverage file;
    file.sourcePath = overridePath;

    size_t lineNumber = 1;
    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const record = scanner.line;
        const split = splitOnce(record, '|');
        if (!split.found)
        {
            // The only uncounted line that carries information is the trailer.
            if (auto trailer = parseTrailer(record))
                if (file.sourcePath is null)
                    file.sourcePath = trailer;
            continue;
        }

        const countField = split.before.trimmed;
        LineCoverage line;
        line.lineNumber = lineNumber++;

        if (countField.length == 0)
        {
            line.state = LineState.nonCode;     // no code emitted for this line
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
The source text a listing recorded, one line per counted record.

A `.lst` is the only artifact in this library that carries the code it counted:
every record is `<count>|<source line>`. That makes it the one format whose
records can be re-anchored onto an edited file, because the text is the evidence
for which line each counter belongs to. Without it "line 42" is a number that
means whatever line 42 happens to be now.

Params:
    contents = the whole listing

Returns: the recorded source, newline-joined, with no trailing newline; empty
    when the listing has no counted records.
*/
string dmdListingText(const(char)[] contents) @safe
{
    import std.array : appender;

    auto text = appender!string;
    bool first = true;
    auto scanner = RecordScanner(contents);
    while (scanner.next)
    {
        const split = splitOnce(scanner.line, '|');
        if (!split.found)
            continue;                       // the trailer, or a stray line
        if (!first)
            text ~= '\n';
        first = false;
        // `trimmed` would eat significant leading indentation, so only the
        // CR of a CRLF listing comes off.
        const(char)[] line = split.after;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        text ~= line;
    }
    return text[];
}

@("coverage.formats.dmd.dmdListingText")
@safe
unittest
{
    enum listing = "      5|int add(int a, int b)\n"
        ~ "       |{\n"
        ~ "      5|    return a + b;\n"
        ~ "       |}\n"
        ~ "src/math.d is 100% covered\n";

    // Indentation is part of the evidence — a line diff over de-indented text
    // matches lines that are not the same line.
    assert(dmdListingText(listing)
        == "int add(int a, int b)\n{\n    return a + b;\n}");

    assert(dmdListingText("") == "");
    assert(dmdListingText("src/m.d has no code\n") == "");
    assert(dmdListingText("      1|x();\r\nsrc/a.d is 100% covered\r\n") == "x();");
}

/**
The source path a listing's trailer names, read from the end of `contents`
without parsing the counter columns.

For indexing a directory of listings: a `.lst`'s *name* is the source path with
`/` replaced by `-`, which cannot be inverted (a package directory may itself
contain a `-`), and it encodes the path as the compiler saw it — relative to
wherever the build ran. The trailer is the only place the path survives intact,
so mapping artifacts back to sources means reading it. Parsing each whole file
to recover one line is the thing this avoids.

Params:
    contents = the listing, or enough of its tail to hold the trailer

Returns: the path, or `null` when the text does not end in a trailer — which is
    what a truncated listing, or a file that is not a `.lst` at all, looks like.
*/
string dmdListingSource(const(char)[] contents) @safe
{
    import std.string : lineSplitter;

    // The trailer is the last non-empty line; a listing may end with a newline
    // and CRLF input leaves a stray `\r` that `trimmed` takes off.
    string found;
    foreach (line; contents.lineSplitter)
    {
        const stripped = line.trimmed;
        if (stripped.length == 0)
            continue;
        found = parseTrailer(stripped);
    }
    return found;
}

@("coverage.formats.dmd.dmdListingSource")
@safe
unittest
{
    enum listing = "      5|    return a + b;\n"
        ~ "libs/x/src/math.d is 50% covered\n";
    assert(dmdListingSource(listing) == "libs/x/src/math.d");
    assert(dmdListingSource("       |module m;\nsrc/m.d has no code\n") == "src/m.d");

    // Only the trailer answers: a counted line is not a path, and a listing
    // cut off before its trailer names nothing rather than guessing.
    assert(dmdListingSource("      5|    return a + b;\n") is null);
    assert(dmdListingSource("") is null);
    assert(dmdListingSource("just some prose\n") is null);

    // CRLF, and a trailing blank line after the trailer.
    assert(dmdListingSource("      5|x();\r\nsrc/a.d is 100% covered\r\n\r\n")
        == "src/a.d");
}

/// The source path named by a listing's trailer, or `null` for any other
/// line. Handles both spellings `-cov` emits.
private string parseTrailer(const(char)[] line) @safe
{
    import std.algorithm.searching : endsWith, findSplit;

    if (line.endsWith("% covered"))
    {
        if (auto split = line.findSplit(" is "))
            return split[0].idup;
    }
    else if (line.endsWith(" has no code"))
        return line[0 .. $ - " has no code".length].idup;
    return null;
}

@("coverage.formats.dmd.basic")
@safe
unittest
{
    enum listing = "      5|    auto x = f();\n"
        ~ "      1|    if (x)\n"
        ~ "0000000|        neverRun();\n"
        ~ "       |}\n"
        ~ "libs/input/src/sparkles/input/tier.d is 66% covered\n";

    const cov = parseDmdCoverage(listing);
    assert(cov, "parse failed");
    const f = cov.value;
    assert(f.sourcePath == "libs/input/src/sparkles/input/tier.d");
    assert(f.totalLines == 4);
    assert(f.coverableLines == 3);
    assert(f.coveredLines == 2);
    assert(f.lines[0].state == LineState.covered);
    assert(f.lines[0].executionCount == 5);
    assert(f.lines[1].state == LineState.covered);
    assert(f.lines[1].executionCount == 1);
    assert(f.lines[2].state == LineState.uncovered);
    assert(f.lines[2].executionCount == 0);
    assert(f.lines[3].state == LineState.nonCode);
}

@("coverage.formats.dmd.noCode")
@safe
unittest
{
    const cov = parseDmdCoverage("       |module m;\nlibs/x/src/m.d has no code\n");
    assert(cov, "parse failed");
    assert(cov.value.sourcePath == "libs/x/src/m.d");
    assert(cov.value.coverableLines == 0);
    assert(cov.value.linePercent == 100.0);
}

@("coverage.formats.dmd.crlfAndMissingFinalNewline")
@safe
unittest
{
    const cov = parseDmdCoverage("      5|    x();\r\n       |}\r\nsrc/a.d is 100% covered");
    assert(cov, "parse failed");
    assert(cov.value.sourcePath == "src/a.d");
    assert(cov.value.lines.length == 2);
    assert(cov.value.coveredLines == 1);
}

@("coverage.formats.dmd.malformedCounterIsRejected")
@safe
unittest
{
    // Previously a non-numeric counter parsed as 0 and the line was recorded
    // as *covered* with zero executions — a contradiction the report carried
    // silently.
    const junk = parseDmdCoverage("   abc|    x();\n");
    assert(junk.hasError);
    assert(junk.error.code == ParseErrorCode.unexpectedCharacter);

    // 21 digits overflows `ulong`; it used to wrap to 200376420520689663.
    const huge = parseDmdCoverage("99999999999999999999999|    x();\n");
    assert(huge.hasError);
    assert(huge.error.code == ParseErrorCode.numericOverflow);
}
