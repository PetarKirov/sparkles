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
./run_md_examples.d [--verify|--update] [--fail-fast] [--glob=PATTERN] <markdown-file...>
./run_md_examples.d [--dedup-reference-links|--fix-reference-links] [--glob=PATTERN] [markdown-file...]
---

Modes:

$(LIST
    $(ITEM Default — run examples and display results in boxes)
    $(ITEM `--verify` — compare output against expected output blocks, report mismatches)
    $(ITEM `--update` — rewrite the markdown file with actual example output (golden snapshot update))
    $(ITEM `--fail-fast` — stop on the first failing example and replay its output at the end)
    $(ITEM `--dedup-reference-links` — report duplicate markdown reference definitions by URL)
    $(ITEM `--fix-reference-links` — rewrite duplicates to a canonical label)
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

For examples with dynamic output (timestamps, file locations, etc.), place a
`<!-- md-example-expected -->` HTML comment directive between the code block
and the output block. The directive contains a wildcard pattern used for
`--verify` instead of the literal output block. Use `{{_}}` as a wildcard
that matches any non-empty text:

---html
<!-- md-example-expected
[ {{_}} | info ]: Listening on port 8080
-->
```
[ 14:32:01 | info ]: Listening on port 8080
```
---

The literal output block is kept for display in rendered markdown, while the
wildcard pattern handles verification against the actual (dynamic) output.
+/

// std.* modules
import std.algorithm : any, canFind, countUntil, filter, map, sort, startsWith;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.path : baseName, buildPath;
import std.process : execute;
import std.regex : ctRegex, matchFirst;
import std.stdio : writeln;
import std.string : endsWith, indexOf, lineSplitter, replace, strip, stripRight, toLower;

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

    @CliOption(`F|fail-fast`, "Stop on the first failing example and replay its output at the end.")
    bool failFast;

    @CliOption(`g|glob`, "Glob pattern to find markdown files (e.g. '*.md' or '**/*.md').")
    string glob;

    @CliOption(`d|dedup-reference-links`, "Report duplicate markdown reference definitions that point to the same URL.")
    bool dedupReferenceLinks;

    @CliOption(`f|fix-reference-links`, "Rewrite duplicate markdown references to one canonical label per URL.")
    bool fixReferenceLinks;
}

enum ProgramMode
{
    runExamples,
    verifyExamples,
    updateExamples,
    checkReferenceLinks,
    fixReferenceLinks,
}

struct Example
{
    string name;
    string code;
    string expectedOutput;
    string verifyPattern; /// Wildcard pattern from `<!-- md-example-expected -->` directive
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

struct FailureReplay
{
    string header;
    string[] outputLines;
    string footer;
}

struct ReferenceDef
{
    size_t lineIndex;
    string label;
    string url;
}

struct DuplicateGroup
{
    string filePath;
    string canonicalLabel;
    string url;
    ReferenceDef[] defs;
}

private __gshared immutable refDefRegex = ctRegex!(r"^\[([^\]]+)\]:\s+(https?://\S+)");

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

    const modeError = validateCliMode(cli);
    if (modeError !is null)
    {
        styledWritelnErr(i"{red Error:} $(modeError)");
        return 1;
    }

    const mode = resolveProgramMode(cli);
    auto mdFiles = collectMarkdownFiles(cli, args[1 .. $], mode);

    if (mdFiles.length == 0)
    {
        if (isReferenceMode(mode))
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--dedup-reference-links|--fix-reference-links] [--glob=PATTERN] [markdown-file...]");
        else
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--verify|--update] [--fail-fast] [--glob=PATTERN] [markdown-file...]");
        return 1;
    }

    if (mode == ProgramMode.checkReferenceLinks)
        return runReferenceLinkMode(mdFiles, false);

    if (mode == ProgramMode.fixReferenceLinks)
        return runReferenceLinkMode(mdFiles, true);

    return runExamplesForFiles(mdFiles, mode, cli.failFast);
}

private string validateCliMode(in CliParams cli)
{
    if (cli.verify && cli.update)
        return "--verify and --update are mutually exclusive";

    if ((cli.verify || cli.update)
        && (cli.dedupReferenceLinks || cli.fixReferenceLinks))
    {
        return "example modes (--verify/--update) cannot be combined with reference deduplication modes (--dedup-reference-links/--fix-reference-links)";
    }

    return null;
}

private ProgramMode resolveProgramMode(in CliParams cli)
{
    if (cli.fixReferenceLinks)
        return ProgramMode.fixReferenceLinks;

    if (cli.dedupReferenceLinks)
        return ProgramMode.checkReferenceLinks;

    if (cli.update)
        return ProgramMode.updateExamples;

    if (cli.verify)
        return ProgramMode.verifyExamples;

    return ProgramMode.runExamples;
}

private bool isReferenceMode(in ProgramMode mode)
{
    return mode == ProgramMode.checkReferenceLinks
        || mode == ProgramMode.fixReferenceLinks;
}

private string[] trackedMarkdownFiles()
{
    const result = execute(["git", "ls-files", "--", "*.md"]);
    if (result.status != 0)
    {
        styledWritelnErr(i"{red Error:} Failed to enumerate markdown files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

private string[] collectMarkdownFiles(
    in CliParams cli,
    string[] positionalArgs,
    in ProgramMode mode,
)
{
    const hasExplicitSelection = cli.glob.length > 0 || positionalArgs.length > 0;

    string[] mdFiles;

    if (cli.glob.length > 0)
    {
        auto result = execute(["git", "ls-files", "--", cli.glob]);
        if (result.status == 0)
        {
            mdFiles ~= result.output.lineSplitter
                .filter!(line => line.length > 0)
                .map!(line => line.idup)
                .array;
        }
    }

    if (positionalArgs.length > 0)
        mdFiles ~= positionalArgs;

    if (mdFiles.length == 0 && isReferenceMode(mode) && !hasExplicitSelection)
        mdFiles = trackedMarkdownFiles();

    return mdFiles
        .filter!(path => path.length > 0)
        .filter!(path => path.endsWith(".md"))
        .map!(path => path.idup)
        .array;
}

private int runExamplesForFiles(string[] mdFiles, in ProgramMode mode, bool failFast)
{
    int totalFailures = 0;

    foreach (mdFile; mdFiles)
    {
        if (!mdFile.exists)
        {
            styledWritelnErr(i"{red Error:} File not found: $(mdFile)");
            totalFailures++;
            continue;
        }

        auto content = mdFile.readText;
        auto examples = extractExamples(content);

        if (examples.length == 0)
        {
            styledWriteln(i"{yellow No runnable examples found in $(mdFile).}");
            continue;
        }

        int rc;
        final switch (mode)
        {
            case ProgramMode.runExamples:
                rc = runDefaultMode(examples, mdFile, failFast);
                break;
            case ProgramMode.verifyExamples:
                rc = runVerifyMode(examples, mdFile, failFast);
                break;
            case ProgramMode.updateExamples:
                rc = runUpdateMode(examples, mdFile, failFast);
                break;
            case ProgramMode.checkReferenceLinks:
            case ProgramMode.fixReferenceLinks:
                rc = 1;
                break;
        }

        if (rc != 0)
        {
            totalFailures++;
            if (failFast)
                return 1;
        }
    }

    return totalFailures > 0 ? 1 : 0;
}

private int runReferenceLinkMode(string[] mdFiles, bool fix)
{
    const title = fix
        ? "Rewriting duplicate markdown reference links"
        : "Checking duplicate markdown reference links";
    title
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    string[] existingFiles;
    int missingFiles = 0;
    foreach (filePath; mdFiles)
    {
        if (!filePath.exists)
        {
            styledWritelnErr(i"{red Error:} File not found: $(filePath)");
            missingFiles++;
            continue;
        }
        existingFiles ~= filePath;
    }

    auto duplicateGroups = collectDuplicateGroups(existingFiles);
    if (duplicateGroups.length == 0)
    {
        styledWriteln(i"{green ✓} No duplicate markdown reference URLs found.");
        return missingFiles > 0 ? 1 : 0;
    }

    printDuplicateGroups(duplicateGroups);

    if (!fix)
        return 1;

    auto changedFiles = fixDuplicateGroups(existingFiles, duplicateGroups);

    writeln();
    styledWriteln(i"{green ✓} Updated $(changedFiles.length) file(s).");
    foreach (filePath; changedFiles)
        writeln("  ", filePath);

    return missingFiles > 0 ? 1 : 0;
}

// === Core Functions ===

/// Extracts dub single-file examples from markdown content,
/// including any adjacent expected-output blocks.
@safe pure
Example[] extractExamples(string content)
{
    Example[] examples;
    auto lines = content.lineSplitter.array;

    size_t outerFenceEnd = 0; // tracks end of outer (non-D) fenced blocks

    for (size_t idx = 0; idx < lines.length; idx++)
    {
        auto stripped = lines[idx].strip;

        // Track outer fenced blocks (````markdown, etc.) to skip nested code blocks.
        // An outer fence uses ≥4 backticks or is a non-D triple-backtick block.
        if (idx >= outerFenceEnd && stripped.length >= 4
            && stripped[0 .. 4] == "````")
        {
            auto fenceLen = stripped.countUntil!(c => c != '`');
            if (fenceLen < 0) fenceLen = stripped.length;
            auto closeFence = stripped[0 .. fenceLen];
            // Find matching closing fence
            auto closeIdx = lines[idx + 1 .. $]
                .countUntil!(l => l.strip.length >= fenceLen
                    && l.strip[0 .. fenceLen] == closeFence);
            if (closeIdx >= 0)
            {
                outerFenceEnd = idx + 1 + closeIdx + 1;
                idx = outerFenceEnd - 1;
                continue;
            }
        }

        // Look for ```d code fence
        if (!stripped.startsWith("```d"))
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

        // Look for adjacent output block (bare ``` fence, no language tag),
        // optionally preceded by a <!-- md-example-expected ... --> directive.
        string expectedOutput = null;
        string verifyPattern = null;
        size_t outputStart = size_t.max;
        size_t outputEnd = size_t.max;

        auto searchStart = codeEnd + 1;
        // Skip blank lines
        while (searchStart < lines.length && lines[searchStart].strip.length == 0)
            searchStart++;

        // Check for <!-- md-example-expected ... --> comment directive
        if (searchStart < lines.length)
            verifyPattern = parseExpectedDirective(lines, searchStart);

        // If we found a directive, skip past it (and any trailing blanks)
        if (verifyPattern !is null)
        {
            while (searchStart < lines.length
                && !lines[searchStart].strip.startsWith("```"))
                searchStart++;
        }

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
            verifyPattern: verifyPattern,
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
int runDefaultMode(Example[] examples, string mdFile, bool failFast)
{
    i"Running $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;
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
        {
            failures++;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: outputLines.formatOutputLines.array,
                    footer: styledText(i"{red ✗ FAILED}"),
                );
                processed = i + 1;
                stoppedEarly = true;
                writeln();
                break;
            }
        }
        processed = i + 1;
        writeln();
    }

    displaySummary(stoppedEarly ? processed : examples.length, failures);
    if (stoppedEarly)
        displayFailureReplay(failureReplay);
    return failures > 0 ? 1 : 0;
}

/// Verify mode: run examples, display output, and compare against expected output blocks.
int runVerifyMode(Example[] examples, string mdFile, bool failFast)
{
    i"Verifying $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;
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
            auto failureLines = outputLines
                .formatOutputLines(12)
                .array;
            failureLines
                .drawBox(header, BoxProps(footer: styledText(i"{red ✗ build failed}")))
                .writeln;
            writeln();
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: failureLines,
                    footer: styledText(i"{red ✗ build failed}"),
                );
                processed = i + 1;
                stoppedEarly = true;
                break;
            }
            processed = i + 1;
            continue;
        }

        // Use verifyPattern (from <!-- md-example-expected --> directive)
        // if present, otherwise fall back to the literal output block.
        auto verifyAgainst = example.verifyPattern !is null
            ? example.verifyPattern
            : example.expectedOutput;

        if (verifyAgainst is null)
        {
            outputLines
                .formatOutputLines
                .drawBox(header, BoxProps(footer: styledText(i"{green ✓ ran} {dim │} {yellow ⚠ no expected output}")))
                .writeln;
            writeln();
            processed = i + 1;
            continue;
        }

        auto actual = result.programOutput.strip;
        auto expected = verifyAgainst.strip;

        if (matchesWithWildcards(actual, expected))
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
            auto failureLines = outputLines
                .formatOutputLines(24)
                .array;
            failureLines
                .drawBox(header, BoxProps(footer: styledText(i"{green ✓ ran} {dim │} {red ✗ output mismatch}")))
                .writeln;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: failureLines,
                    footer: styledText(i"{green ✓ ran} {dim │} {red ✗ output mismatch}"),
                );
                processed = i + 1;
                stoppedEarly = true;
                writeln();
                break;
            }
        }
        processed = i + 1;
        writeln();
    }

    displaySummary(stoppedEarly ? processed : examples.length, failures);
    if (stoppedEarly)
        displayFailureReplay(failureReplay);
    return failures > 0 ? 1 : 0;
}

/// Update mode: rewrite the markdown file with actual output.
/// Processes examples in reverse order so line indices remain valid.
int runUpdateMode(Example[] examples, string mdFile, bool failFast)
{
    i"Updating $(examples.length) example(s) in $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: 60))
        .writeln("\n");

    auto lines = mdFile.readText.lineSplitter.array;
    int failures = 0;
    int updated = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;

    foreach_reverse (i, example; examples)
    {
        auto result = executeExample(example);

        if (!result.success)
        {
            failures++;
            styledWriteln(i"  {red ✗} {cyan $(example.name)} — build failed, skipping");
            if (failFast)
            {
                const progress = i"[$(examples.length - i)/$(examples.length)]".text;
                failureReplay = FailureReplay(
                    header: formatExampleHeader(example, progress),
                    outputLines: result.rawOutput
                        .lineSplitter
                        .map!(l => l.to!string)
                        .array
                        .formatOutputLines(12)
                        .array,
                    footer: styledText(i"{red ✗ build failed}"),
                );
                processed = examples.length - i;
                stoppedEarly = true;
                break;
            }
            processed = examples.length - i;
            continue;
        }

        auto actualOutput = result.programOutput.strip;

        if (example.expectedOutput !is null && actualOutput == example.expectedOutput.strip)
        {
            styledWriteln(i"  {green ✓} {cyan $(example.name)} — output unchanged");
            processed = examples.length - i;
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
        processed = examples.length - i;
    }

    if (updated > 0 && !stoppedEarly)
        mdFile.write(lines.join("\n") ~ "\n");

    writeln();
    if (updated > 0 && !stoppedEarly)
        styledWriteln(i"{green ✓} Updated $(updated) output block(s) in $(mdFile)");
    else if (updated > 0)
        styledWriteln(i"{yellow ⚠} Stopped before writing $(updated) pending output block update(s) in $(mdFile)");
    else
        styledWriteln(i"{green ✓} All output blocks already up to date");

    if (failures > 0)
    {
        styledWriteln(i"{red ✗} $(failures) example(s) failed to build");
        displaySummary(stoppedEarly ? processed : examples.length, failures);
        if (stoppedEarly)
            displayFailureReplay(failureReplay);
        return 1;
    }

    displaySummary(examples.length, 0);
    return 0;
}

// === Reference Link Deduplication ===

private DuplicateGroup[] collectDuplicateGroups(string[] mdFiles)
{
    DuplicateGroup[] groups;

    foreach (filePath; mdFiles)
    {
        auto refsByUrl = parseReferenceDefs(filePath);

        foreach (url, defs; refsByUrl)
        {
            if (defs.length < 2)
                continue;

            const canonicalLabel = chooseCanonicalLabel(defs);

            groups ~= DuplicateGroup(
                filePath: filePath,
                canonicalLabel: canonicalLabel,
                url: url,
                defs: defs.sort!((a, b) => a.lineIndex < b.lineIndex).array,
            );
        }
    }

    groups.sort!((a, b)
        => a.filePath < b.filePath
        || (a.filePath == b.filePath && a.url < b.url)
    );

    return groups;
}

private ReferenceDef[][string] parseReferenceDefs(string filePath)
{
    ReferenceDef[][string] refsByUrl;
    const lines = filePath.readText.lineSplitter.array;

    foreach (lineIndex, line; lines)
    {
        auto match = matchFirst(line, refDefRegex);
        if (match.empty)
            continue;

        refsByUrl[match.captures[2]] ~= ReferenceDef(
            lineIndex: lineIndex,
            label: match.captures[1].idup,
            url: match.captures[2].idup,
        );
    }

    return refsByUrl;
}

private string chooseCanonicalLabel(ReferenceDef[] defs)
{
    auto best = defs[0].label;
    auto bestScore = labelScore(best);

    foreach (def; defs[1 .. $])
    {
        const score = labelScore(def.label);
        if (score > bestScore)
        {
            best = def.label;
            bestScore = score;
        }
    }

    return best;
}

private int labelScore(string label)
{
    int score = 0;

    if (label.canFind(" "))
        score += 40;

    if (label.any!(c => c >= 'A' && c <= 'Z'))
        score += 10;

    if (containsKeyword(label))
        score += 15;

    if (isUrlishLabel(label))
        score -= 60;

    if (label.canFind("-hackage") || label.canFind("-website") || label.canFind("-docs"))
        score -= 10;

    return score;
}

private bool containsKeyword(string label)
{
    static immutable keywords = [
        "repository",
        "documentation",
        "announcement",
        "website",
        "release",
        "hackage",
        "book",
        "api",
        "guide",
        "proposal",
    ];

    const lower = label.toLower;
    return keywords.any!(kw => lower.canFind(kw));
}

private bool isUrlishLabel(string label)
{
    if (label.canFind("/") || label.canFind("://"))
        return true;

    if (!label.canFind(" ") && label.canFind("."))
        return true;

    return false;
}

private void printDuplicateGroups(DuplicateGroup[] groups)
{
    styledWriteln(i"{yellow Duplicate markdown reference URLs found:}");

    foreach (group; groups)
    {
        writeln();
        styledWriteln(i"{cyan $(group.filePath)}:");
        writeln("  canonical: [", group.canonicalLabel, "]");
        writeln("  url: ", group.url);

        foreach (def; group.defs)
            writeln("    - [", def.label, "] @ line ", def.lineIndex + 1);
    }
}

private string[] fixDuplicateGroups(string[] mdFiles, DuplicateGroup[] groups)
{
    DuplicateGroup[][string] groupsByFile;
    foreach (group; groups)
        groupsByFile[group.filePath] ~= group;

    string[] changedFiles;

    foreach (filePath; mdFiles)
    {
        if (filePath !in groupsByFile)
            continue;

        const originalText = filePath.readText;
        auto lines = originalText.lineSplitter.array;
        const hadTrailingNewline = originalText.length > 0 && originalText[$ - 1] == '\n';

        bool[] removeLine = new bool[](lines.length);
        string[string] replacementByLabel;

        foreach (group; groupsByFile[filePath])
        {
            size_t keepLine = size_t.max;
            foreach (def; group.defs)
            {
                if (def.label == group.canonicalLabel)
                {
                    keepLine = def.lineIndex;
                    break;
                }
            }

            if (keepLine == size_t.max)
                keepLine = group.defs[0].lineIndex;

            foreach (def; group.defs)
            {
                if (def.lineIndex == keepLine)
                    continue;

                removeLine[def.lineIndex] = true;
                if (def.label != group.canonicalLabel)
                    replacementByLabel[def.label] = group.canonicalLabel;
            }
        }

        auto oldLabels = replacementByLabel.keys.array;
        oldLabels.sort!((a, b) => a.length > b.length);

        string[] outputLines;
        foreach (lineIndex, originalLine; lines)
        {
            if (removeLine[lineIndex])
                continue;

            auto line = originalLine.idup;
            foreach (oldLabel; oldLabels)
                line = line.replace("[" ~ oldLabel ~ "]", "[" ~ replacementByLabel[oldLabel] ~ "]");

            // Avoid introducing repeated bullets after relabeling:
            //   - [A]
            //   - [B]
            // can become a duplicate pair when B rewrites to A.
            if (line.length >= 4 && line[0 .. 4] == "- ["
                && outputLines.length > 0
                && outputLines[$ - 1] == line)
            {
                continue;
            }

            outputLines ~= line;
        }

        auto rewritten = outputLines.join("\n");
        if (hadTrailingNewline)
            rewritten ~= "\n";

        if (rewritten != originalText)
        {
            filePath.write(rewritten);
            changedFiles ~= filePath;
        }
    }

    return changedFiles;
}

// === Wildcard Matching ===

/// Checks if `actual` matches `expected`, treating `{{_}}` in `expected` as
/// a wildcard that matches any non-empty sequence of non-newline characters.
///
/// Both strings are compared line-by-line after stripping trailing whitespace.
/// Returns `true` when every line matches (wildcards expand greedily within
/// the line).
@safe pure
bool matchesWithWildcards(string actual, string expected)
{
    auto actLines = actual.lineSplitter.map!(l => l.stripRight).array;
    auto expLines = expected.lineSplitter.map!(l => l.stripRight).array;

    if (actLines.length != expLines.length)
        return false;

    foreach (i; 0 .. actLines.length)
    {
        if (!lineMatchesPattern(actLines[i], expLines[i]))
            return false;
    }
    return true;
}

/// Matches a single actual line against a pattern line containing `{{_}}` wildcards.
@safe pure
private bool lineMatchesPattern(const(char)[] actual, const(char)[] pattern)
{
    // Fast path: no wildcards
    if (pattern.indexOf("{{_}}") < 0)
        return actual == pattern;

    // Split pattern on {{_}} and verify actual contains the literal segments in order.
    size_t apos = 0;
    auto rest = pattern;

    while (rest.length > 0)
    {
        auto wcIdx = rest.indexOf("{{_}}");
        if (wcIdx < 0)
        {
            // Remaining pattern is a literal suffix
            if (actual.length < apos + rest.length)
                return false;
            return actual[apos .. $].length >= rest.length
                && actual[$ - rest.length .. $] == rest;
        }

        auto literal = rest[0 .. wcIdx];
        rest = rest[wcIdx + 5 .. $]; // skip "{{_}}"

        // Literal segment must appear at current position
        if (actual.length < apos + literal.length)
            return false;
        if (actual[apos .. apos + literal.length] != literal)
            return false;
        apos += literal.length;

        if (rest.length == 0)
        {
            // Trailing wildcard — matches rest of line (must be non-empty)
            return apos < actual.length;
        }

        // Find next literal segment to know where wildcard ends
        auto nextWc = rest.indexOf("{{_}}");
        auto nextLiteral = (nextWc < 0) ? rest : rest[0 .. nextWc];

        if (nextLiteral.length == 0)
            continue; // consecutive wildcards — skip

        // Search for nextLiteral in actual starting from apos
        auto searchArea = actual[apos .. $];
        auto found = searchArea.indexOf(nextLiteral);
        if (found < 0)
            return false;
        if (found == 0)
            return false; // wildcard must match at least 1 char

        apos += found;
    }

    return apos == actual.length;
}

// === Private Helpers ===

/// Parses a `<!-- md-example-expected ... -->` HTML comment directive starting
/// at `startIdx`. The directive may span multiple lines:
///
/// ---html
/// <!-- md-example-expected
/// [ {{_}} | info ]: message
/// [ {{_}} | warn ]: other
/// -->
/// ---
///
/// Returns the content between the opening tag and `-->`, or `null` if no
/// directive is found at `startIdx`.
@safe pure
private string parseExpectedDirective(const(char[])[] lines, size_t startIdx)
{
    enum openTag = "<!-- md-example-expected";
    enum closeTag = "-->";

    auto firstLine = lines[startIdx].strip;
    if (!firstLine.startsWith(openTag))
        return null;

    // Single-line form: <!-- md-example-expected ... -->
    if (firstLine.length >= closeTag.length
        && firstLine[$ - closeTag.length .. $] == closeTag
        && firstLine.length > openTag.length + closeTag.length)
    {
        auto inner = firstLine[openTag.length .. $ - closeTag.length].strip;
        return inner.length > 0 ? inner.idup : null;
    }

    // Multi-line form: collect lines until -->
    string[] contentLines;
    foreach (line; lines[startIdx + 1 .. $])
    {
        auto stripped = line.strip;
        if (stripped.length >= closeTag.length
            && stripped[$ - closeTag.length .. $] == closeTag)
        {
            // If there's content before --> on the closing line, include it
            if (stripped.length > closeTag.length)
                contentLines ~= stripped[0 .. $ - closeTag.length].stripRight.idup;
            break;
        }
        contentLines ~= line.idup;
    }

    return contentLines.length > 0 ? contentLines.join("\n") : null;
}

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

private void displayFailureReplay(FailureReplay replay)
{
    writeln();
    styledWriteln(i"{red Fail-fast:} replaying first failing case");
    replay.outputLines
        .drawBox(replay.header, BoxProps(footer: replay.footer))
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
