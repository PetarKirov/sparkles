#!/usr/bin/env dub
/+ dub.sdl:
    name "run_md_examples"
    dependency "sparkles:core-cli" version="*"
+/

/++
Extracts and runs dub single-file examples from markdown files.

This script parses markdown files to find code blocks that represent
dub single-file programs, executes them, and reports results.

Usage:
---
./run_md_examples.d [--verify|--update] <markdown-file>
---

Modes:

$(LIST
    $(ITEM Default — run examples and display results in boxes)
    $(ITEM `--verify` — compare output against expected output blocks, report mismatches)
    $(ITEM `--update` — rewrite the markdown file with actual output (golden snapshot update))
)

The script looks for D code blocks starting with:
---
#!/usr/bin/env dub
/+ dub.sdl:
    name "example-name"
+/
---

When an output block (a bare fenced code block with no language tag) immediately
follows a runnable code block, it is treated as the expected output for that example.
+/

// std.* modules
import std.algorithm : countUntil, filter, map, startsWith;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.path : baseName, buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, lineSplitter, strip, stripRight;

// sparkles packages
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;
import sparkles.core_cli.styled_template : styledText, styledWriteln, styledWritelnErr;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.core_cli.ui.box : BoxProps, drawBox;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

// === Types ===

struct CliParams
{
    @CliOption(`V|verify`, "Compare example output against expected output blocks in the markdown.")
    bool verify;

    @CliOption(`u|update`, "Rewrite the markdown file with actual example output.")
    bool update;
}

struct Example
{
    string name;
    string code;
    string expectedOutput;
    size_t codeBlockStart;
    size_t codeBlockEnd;
    size_t outputBlockStart;
    size_t outputBlockEnd;
}

struct ExampleResult
{
    bool success;
    string programOutput; // ANSI-stripped
    string rawOutput;     // with ANSI codes for display
}

// === Main Entry Point ===

/// `dub` has several verbosity flags that affect its diagnostic output
/// (progress messages like "Building...", "Linking...", "Up-to-date...", etc.):
///
///   (default)   — prints all progress messages to stderr
///   --quiet     — suppresses progress, still shows warnings and errors
///   --vquiet    — suppresses everything including warnings (errors still shown)
///
/// Using `dub run --quiet --single <file>` eliminates the need for a heuristic
/// noise filter: on success, only the program's stdout appears in the combined
/// output; on failure, compiler errors are still reported.

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "run_md_examples",
            "Extract and run dub single-file examples from markdown files",
        ),
    );

    if (cli.verify && cli.update)
    {
        styledWritelnErr(i"{red Error:} --verify and --update are mutually exclusive");
        return 1;
    }

    if (args.length < 2)
    {
        styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--verify|--update] <markdown-file>");
        return 1;
    }

    const mdFile = args[1];
    if (!mdFile.exists)
    {
        styledWritelnErr(i"{red Error:} File not found: $(mdFile)");
        return 1;
    }

    auto content = mdFile.readText;
    auto examples = extractExamples(content);

    if (examples.length == 0)
    {
        styledWriteln(i"{yellow No runnable examples found.}");
        return 0;
    }

    if (cli.verify)
        return runVerifyMode(examples, mdFile);
    else if (cli.update)
        return runUpdateMode(examples, mdFile);
    else
        return runDefaultMode(examples, mdFile);
}

// === Core Functions ===

/// Extracts dub single-file examples from markdown content,
/// including any adjacent expected-output blocks.
@safe pure
Example[] extractExamples(string content)
{
    Example[] examples;
    auto lines = content.lineSplitter.array;

    for (size_t idx = 0; idx < lines.length; idx++)
    {
        // Look for ```d code fence
        if (!lines[idx].strip.startsWith("```d"))
            continue;

        auto codeStart = idx;

        // Find end of code block
        auto endIdx = lines[idx + 1 .. $].countUntil!(l => l.strip.startsWith("```"));
        if (endIdx < 0)
            continue;

        auto codeLines = lines[idx + 1 .. idx + 1 + endIdx];
        auto codeEnd = idx + 1 + endIdx;

        if (!isDubSingleFileBlock(codeLines))
        {
            idx = codeEnd;
            continue;
        }

        auto name = extractExampleName(codeLines);

        // Look for adjacent output block (bare ``` fence, no language tag)
        string expectedOutput = null;
        size_t outputStart = size_t.max;
        size_t outputEnd = size_t.max;

        auto searchStart = codeEnd + 1;
        // Skip blank lines
        while (searchStart < lines.length && lines[searchStart].strip.length == 0)
            searchStart++;

        if (searchStart < lines.length && lines[searchStart].strip == "```")
        {
            outputStart = searchStart;
            auto outEndIdx = lines[searchStart + 1 .. $]
                .countUntil!(l => l.strip.startsWith("```"));
            if (outEndIdx >= 0)
            {
                outputEnd = searchStart + 1 + outEndIdx;
                expectedOutput = lines[searchStart + 1 .. searchStart + 1 + outEndIdx]
                    .join("\n");
            }
        }

        examples ~= Example(
            name: name,
            code: codeLines.join("\n"),
            expectedOutput: expectedOutput,
            codeBlockStart: codeStart,
            codeBlockEnd: codeEnd,
            outputBlockStart: outputStart,
            outputBlockEnd: outputEnd,
        );

        idx = (outputEnd != size_t.max) ? outputEnd : codeEnd;
    }

    return examples;
}

/// Runs a single example and returns its result.
ExampleResult executeExample(in Example example)
{
    auto tmpDir = buildPath(tempDir, "md-examples");
    mkdirRecurse(tmpDir);
    auto tmpFile = buildPath(tmpDir, example.name ~ ".d");

    tmpFile.write(example.code);
    scope(exit) if (tmpFile.exists) tmpFile.remove();

    auto result = execute(["dub", "run", "--quiet", "--single", tmpFile]);

    // Strip ANSI codes, then trim trailing whitespace from each line
    // so output matches what pre-commit hooks produce in markdown files.
    auto cleaned = result.output.unstyle
        .lineSplitter
        .map!(l => l.stripRight)
        .join("\n");

    return ExampleResult(
        success: result.status == 0,
        programOutput: cleaned,
        rawOutput: result.output,
    );
}

// === Modes ===

/// Default mode: run examples and display output in boxes.
int runDefaultMode(Example[] examples, string mdFile)
{
    i"Running $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    int failures = 0;
    foreach (i, example; examples)
    {
        auto progress = i"[$(i + 1)/$(examples.length)]".text;
        auto result = executeExample(example);
        auto header = formatExampleHeader(example, progress);
        auto outputLines = result.rawOutput.lineSplitter
            .map!(l => l.to!string)
            .array;

        displayResultBox(outputLines, header, result.success);

        if (!result.success)
            failures++;
        writeln();
    }

    displaySummary(examples.length, failures);
    return failures > 0 ? 1 : 0;
}

/// Verify mode: run examples, display output, and compare against expected output blocks.
int runVerifyMode(Example[] examples, string mdFile)
{
    i"Verifying $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    int failures = 0;
    foreach (i, example; examples)
    {
        auto progress = i"[$(i + 1)/$(examples.length)]".text;
        auto header = formatExampleHeader(example, progress);
        auto result = executeExample(example);
        auto outputLines = result.rawOutput.lineSplitter
            .map!(l => l.to!string)
            .array;

        if (!result.success)
        {
            failures++;
            outputLines
                .formatOutputLines(12)
                .drawBox(header, BoxProps(footer: styledText(i"{red ✗ build failed}")))
                .writeln;
            writeln();
            continue;
        }

        if (example.expectedOutput is null)
        {
            outputLines
                .formatOutputLines
                .drawBox(header, BoxProps(footer: styledText(i"{green ✓ ran} {dim │} {yellow ⚠ no expected output}")))
                .writeln;
            writeln();
            continue;
        }

        auto actual = result.programOutput.strip;
        auto expected = example.expectedOutput.strip;

        if (actual == expected)
        {
            outputLines
                .formatOutputLines
                .drawBox(header, BoxProps(footer: styledText(i"{green ✓ ran} {dim │} {green ✓ output matches}")))
                .writeln;
        }
        else
        {
            failures++;
            outputLines ~= "";
            outputLines ~= styledText(i"{dim ─── expected ───}");
            outputLines ~= expected.lineSplitter.map!(l => l.to!string).array;
            outputLines
                .formatOutputLines(24)
                .drawBox(header, BoxProps(footer: styledText(i"{green ✓ ran} {dim │} {red ✗ output mismatch}")))
                .writeln;
        }
        writeln();
    }

    displaySummary(examples.length, failures);
    return failures > 0 ? 1 : 0;
}

/// Update mode: rewrite the markdown file with actual output.
/// Processes examples in reverse order so line indices remain valid.
int runUpdateMode(Example[] examples, string mdFile)
{
    i"Updating $(examples.length) example(s) in $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    auto lines = mdFile.readText.lineSplitter.array;
    int failures = 0;
    int updated = 0;

    foreach_reverse (i, example; examples)
    {
        auto result = executeExample(example);

        if (!result.success)
        {
            failures++;
            styledWriteln(i"  {red ✗} {cyan $(example.name)} — build failed, skipping");
            continue;
        }

        auto actualOutput = result.programOutput.strip;

        if (example.expectedOutput !is null && actualOutput == example.expectedOutput.strip)
        {
            styledWriteln(i"  {green ✓} {cyan $(example.name)} — output unchanged");
            continue;
        }

        auto newOutputLines = ["```"]
            ~ actualOutput.lineSplitter.map!(l => l.idup).array
            ~ ["```"];

        if (example.outputBlockStart != size_t.max)
        {
            // Replace existing output block
            lines = lines[0 .. example.outputBlockStart]
                ~ newOutputLines.map!(l => l.idup).array
                ~ lines[example.outputBlockEnd + 1 .. $];
            updated++;
            styledWriteln(i"  {yellow ↻} {cyan $(example.name)} — output block updated");
        }
        else
        {
            // Insert new output block after code block
            auto insertPos = example.codeBlockEnd + 1;
            auto insertLines = [""] ~ newOutputLines;
            lines = lines[0 .. insertPos]
                ~ insertLines.map!(l => l.idup).array
                ~ lines[insertPos .. $];
            updated++;
            styledWriteln(i"  {yellow +} {cyan $(example.name)} — output block inserted");
        }
    }

    if (updated > 0)
        mdFile.write(lines.join("\n") ~ "\n");

    writeln();
    if (updated > 0)
        styledWriteln(i"{green ✓} Updated $(updated) output block(s) in $(mdFile)");
    else
        styledWriteln(i"{green ✓} All output blocks already up to date");

    if (failures > 0)
    {
        styledWriteln(i"{red ✗} $(failures) example(s) failed to build");
        return 1;
    }

    return 0;
}

// === Private Helpers ===

/// Checks if code lines represent a dub single-file program.
@safe pure nothrow @nogc
private bool isDubSingleFileBlock(const(char[])[] codeLines)
{
    if (codeLines.length < 4)
        return false;
    if (!codeLines[0].strip.startsWith("#!/usr/bin/env dub"))
        return false;
    if (!codeLines[1].strip.startsWith("/+ dub.sdl:"))
        return false;
    return true;
}

/// Extracts the example name from dub.sdl header lines.
@safe pure
private string extractExampleName(const(char[])[] codeLines)
{
    foreach (line; codeLines[2 .. $])
    {
        auto stripped = line.strip;
        if (stripped.startsWith("name "))
            return parseQuotedName(stripped);
        if (stripped.startsWith("+/"))
            break;
    }
    return "unnamed";
}

/// Parses a name from a line like: name "example-name"
@safe pure
private string parseQuotedName(const(char)[] line)
in (line.length > 0, "Line cannot be empty")
{
    auto start = line.indexOf('"');
    if (start < 0)
        return "unnamed";

    auto rest = line[start + 1 .. $];
    auto end = rest.indexOf('"');
    if (end < 0)
        return "unnamed";

    return rest[0 .. end].idup;
}

/// Formats the header line for an example run.
private string formatExampleHeader(in Example example, string progress)
{
    return styledText(i"{dim $(progress)} {cyan $(example.name)} {dim › dub run --single $(example.name).d}");
}

/// Formats output lines for display, truncating if necessary.
private string[] formatOutputLines(string[] lines, size_t maxLines = 8)
in (maxLines > 1, "maxLines must be at least 2 for truncation indicator")
{
    if (lines.length == 0)
        return [styledText(i"{dim (no output)}")];

    if (lines.length > maxLines)
        return lines[0 .. maxLines - 1] ~ [styledText(i"{dim ...}")];

    return lines;
}

/// Displays the result box for an example run.
private void displayResultBox(string[] outputLines, string header, bool success)
{
    auto footer = success
        ? styledText(i"{green ✓ passed}")
        : styledText(i"{red ✗ FAILED}");

    outputLines
        .formatOutputLines
        .drawBox(header, BoxProps(footer: footer))
        .writeln;
}

/// Displays the results summary.
private void displaySummary(size_t total, size_t failures)
{
    writeln();
    auto passed = total - failures;

    if (failures == 0)
    {
        writeln([
            styledText(i"{green ✓} All examples passed!"),
            styledText(i"{dim $(passed)/$(total) passed}"),
        ].drawBox(styledText(i"{green Results}")));
    }
    else
    {
        writeln([
            styledText(i"{red ✗} $(failures) example(s) failed"),
            styledText(i"{dim $(passed)/$(total) passed}"),
        ].drawBox(styledText(i"{red Results}")));
    }
}
