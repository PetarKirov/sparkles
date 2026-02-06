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
./run_md_examples.d <markdown-file>
---

The script looks for D code blocks starting with:
---
#!/usr/bin/env dub
/+ dub.sdl:
    name "example-name"
+/
---
+/

// std.* modules
import std.algorithm : canFind, countUntil, filter, map, startsWith;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.path : baseName, buildPath;
import std.process : execute;
import std.stdio : writeln;
import std.string : indexOf, lineSplitter, strip;

// sparkles packages
import sparkles.core_cli.styled_template : styledText, styledWriteln, styledWritelnErr;
import sparkles.core_cli.ui.box : BoxProps, drawBox;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

// === Types ===

struct Example
{
    string name;
    string code;
}

// === Main Entry Point ===

int main(string[] args)
{
    auto mdFile = parseArgs(args);
    if (mdFile is null)
        return 1;

    auto examples = extractExamples(mdFile.readText);

    if (examples.length == 0)
    {
        styledWriteln(i"{yellow No runnable examples found.}");
        return 0;
    }

    i"Running $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    int failures = 0;
    foreach (i, example; examples)
    {
        auto progress = i"[$(i + 1)/$(examples.length)]".text;
        if (!runExample(example, progress))
            failures++;
        writeln();
    }

    displaySummary(examples.length, failures);

    return failures > 0 ? 1 : 0;
}

// === Core Functions ===

/// Extracts dub single-file examples from markdown content.
@safe pure
Example[] extractExamples(string content)
{
    Example[] examples;
    auto lines = content.lineSplitter.array;

    for (size_t i = 0; i < lines.length; i++)
    {
        // Look for ```d code fence
        if (!lines[i].strip.startsWith("```d"))
            continue;

        // Find end of code block
        auto endIdx = lines[i + 1 .. $].countUntil!(l => l.strip.startsWith("```"));
        if (endIdx < 0)
            continue;

        auto codeLines = lines[i + 1 .. i + 1 + endIdx];

        if (!isDubSingleFileBlock(codeLines))
            continue;

        auto name = extractExampleName(codeLines);
        examples ~= Example(name, codeLines.join("\n"));
        i += endIdx;
    }

    return examples;
}

/// Runs a single example and displays results.
bool runExample(in Example example, string progress)
{
    // Write to temp file
    auto tmpDir = buildPath(tempDir, "md-examples");
    mkdirRecurse(tmpDir);
    auto tmpFile = buildPath(tmpDir, example.name ~ ".d");

    tmpFile.write(example.code);
    scope(exit) if (tmpFile.exists) tmpFile.remove();

    // Run with dub
    auto result = execute(["dub", "run", "--single", tmpFile]);

    // Format and display
    auto header = formatExampleHeader(example, progress);
    auto outputLines = result.output.lineSplitter
        .filter!(l => !isDubNoise(l))
        .map!(l => l.to!string)
        .array;

    displayResultBox(outputLines, header, result.status == 0);

    return result.status == 0;
}

/// Checks if a line is dub build noise that should be filtered.
@safe pure nothrow @nogc
bool isDubNoise(const(char)[] line)
{
    auto stripped = line.strip;
    if (stripped.length == 0)
        return false; // Keep empty lines

    // Simple patterns
    if (line.canFind("Up-to-date") || line.canFind("up to date"))
        return true;
    if (line.canFind("Starting Performing"))
        return true;
    if (line.canFind("Linking "))
        return true;
    if (line.canFind("Finished "))
        return true;
    if (line.canFind("--force"))
        return true;

    // Context-dependent patterns
    if (line.canFind("Building ") && line.canFind("configuration"))
        return true;
    if (line.canFind("Running ") && line.canFind("md-examples"))
        return true;

    return false;
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

/// Validates command-line arguments.
/// Returns the markdown file path or null on error.
private string parseArgs(string[] args)
{
    if (args.length < 2)
    {
        styledWritelnErr(i"{bold Usage:} $(args[0].baseName) <markdown-file>");
        return null;
    }

    const mdFile = args[1];
    if (!mdFile.exists)
    {
        styledWritelnErr(i"{red Error:} File not found: $(mdFile)");
        return null;
    }

    return mdFile;
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
