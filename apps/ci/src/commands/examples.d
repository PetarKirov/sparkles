/++
`ci examples`: runnable markdown examples and standalone `.d` files.

It finds the code blocks of markdown files that are dub single-file
programs, runs them, and reports or verifies their output. It also
smoke-tests tracked standalone example files such as `libs/base/examples/*.d`
and `libs/core-cli/examples/*.d`.

Standalone example files can declare that they should be compiled but not
executed by placing a header comment after the `dub.sdl` block:
---d
// ci: build-only
---

It looks for D code blocks starting with:
---
#!/usr/bin/env dub
/+ dub.sdl:
    name "example-name"
+/
---

When an `ansi`-labelled fenced block immediately follows a runnable code
block, it is treated as the expected output for that example:
---
```ansi
expected output here
```
---

An `ansi` block stores the output verbatim, escape sequences included, so a
colored example keeps its color. `[Output]` (and the alias `[Output:ansi]`)
are also recognised; `[Output]` is the legacy spelling and stores
ANSI-stripped text. New blocks — including those `ci examples update` inserts — use
`ansi`.

For examples with dynamic output (timestamps, file locations, etc.), place a
`<!-- md-example-expected -->` HTML comment directive between the code block
and the output block. The directive contains a wildcard pattern used for
`ci examples verify` instead of the literal output block. Use `{{_}}` as a wildcard
that matches any non-empty text:

---html
<!-- md-example-expected
[ {{_}} | info ]: Listening on port 8080
-->
```ansi
[ 14:32:01 | info ]: Listening on port 8080
```
---

The literal output block is kept for display in rendered markdown, while the
wildcard pattern handles verification against the actual (dynamic) output.
The pattern is matched against the ANSI-stripped output, so write it in plain
text even next to an `ansi` block.

To park a runnable example whose dependency does not exist yet (for example, a
spec written before its implementation lands), place a `<!-- md-example-skip -->`
HTML comment directly before its code block. A skipped example is neither built
nor verified; removing the directive makes the example required again:

---
<!-- md-example-skip: sparkles:wired not implemented until M4 -->
```d
#!/usr/bin/env dub
...
```
---
+/

module commands.examples;

import cli : ExampleAction, FileSelection;
import commands.files : InputFiles, collectInputFiles, detectRepoRoot;
import commands.maintenance : seedDubHome;
import commands.output :
    FailureReplay, displayFailureReplay, displayResultBox, displaySummary, executeComparisonCommand,
    executeLogged, flushStdout, formatOutputLines, resultBox, uiWidth;
import core.time : Duration, msecs, seconds;
import example_manifest : exampleRunsOnHost;
import fence_audit : wrapperFenceEnd;
import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.expected : andThen;
import sparkles.base.hw_caps : hwMemoryBytes, hwOnlineCpuCount, hwParallelism;
import sparkles.base.logger : error, info, trace, warning;
import sparkles.base.styled_template : styledText;
import sparkles.base.text.case_text : asciiLower;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import sparkles.core_cli.process_utils : ResourceUsage;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.ui.components.box : BoxProps, drawBox;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import std.algorithm : canFind, countUntil, joiner, map, sort, startsWith;
import std.array : array, join, split;
import std.conv : text, to;
import std.file : exists, mkdirRecurse, readText, tempDir, write;
import std.path : baseName, buildPath;
import std.process : environment;
import std.range.primitives : put;
import std.stdio : writeln;
import std.string : endsWith, indexOf, lineSplitter, strip, stripRight;

struct Example
{
    string sourcePath; /// Complete imported source; keeps dependency resolution at its origin.
    string name;
    string code;
    string expectedOutput;
    string verifyPattern; /// Wildcard pattern from `<!-- md-example-expected -->` directive
    string outputFenceType; /// "ansi", "[Output:ansi]", legacy "[Output]", or null if no output block
    size_t codeBlockStart;
    size_t codeBlockEnd;
    size_t outputBlockStart;
    size_t outputBlockEnd;
}

struct ExecutionResult
{
    bool success;
    string programOutput; // ANSI-stripped
    string rawOutput;     // with ANSI codes for display
    ResourceUsage usage;
}

enum StandaloneExampleMode
{
    run,
    buildOnly,
}

/// What a `// ci:` directive asked for: how to execute the example, and — for
/// `run` — the arguments to hand the program.
struct StandaloneExampleSpec
{
    StandaloneExampleMode mode;
    string[] runArgs;
}

/// `ci examples run|verify|update`.
RunExpected!void runMarkdownExamplesCommand(ExampleAction action, in FileSelection files,
    bool failFast)
{
    const command = text("ci examples ", action);
    return collectInputFiles(files, InputFiles.markdownExamples, command)
        .andThen!(mdFiles => runExamplesForFiles(mdFiles, action, failFast));
}

/// `ci examples standalone`.
RunExpected!void runStandaloneExamplesCommand(in FileSelection files, bool failFast)
{
    seedDubHome();
    return collectInputFiles(files, InputFiles.standalone, "ci examples standalone")
        .andThen!(exampleFiles => runExampleFilesMode(exampleFiles, failFast));
}

private RunExpected!void runExamplesForFiles(string[] mdFiles, ExampleAction action, bool failFast)
{
    static struct FileExamples
    {
        string mdFile;
        Example[] examples;
    }

    FileExamples[] gathered;
    Example[] contractExamples;
    int totalFailures = 0;

    foreach (mdFile; mdFiles)
    {
        if (!mdFile.exists)
        {
            error(i"File not found: $(mdFile)");
            totalFailures++;
            continue;
        }

        Example[] examples;
        try
        {
            const content = mdFile.readText;
            examples = extractExamples(content);
            import comparison_examples : extractComparisons, validateMigrationComparisons,
                migrationContractSources;
            const comparisons = extractComparisons(content, buildPath(detectRepoRoot(), "docs"));
            if (mdFile.canFind("event-horizon/tutorial/coming-from-"))
            {
                validateMigrationComparisons(mdFile, comparisons);
                foreach (source; migrationContractSources(mdFile, comparisons,
                    buildPath(detectRepoRoot(), "docs")))
                    contractExamples ~= Example(sourcePath: source, name: "contract " ~ source.baseName);
            }
            foreach (item; comparisons)
                examples ~= Example(sourcePath: item.sourcePath,
                    name: item.sourcePath.baseName[0 .. $ - (item.sourcePath.endsWith(".mjs") ? 4 : 2)], expectedOutput: item.expectedOutput,
                    outputFenceType: item.outputFenceType,
                    codeBlockStart: item.codeStart, codeBlockEnd: item.codeStart,
                    outputBlockStart: item.outputStart, outputBlockEnd: item.outputEnd);
            examples.sort!((a, b) => a.codeBlockStart < b.codeBlockStart);
        }
        catch (Exception e)
        {
            error(i"Invalid comparisons in $(mdFile): $(e.msg)");
            totalFailures++;
            continue;
        }

        if (examples.length == 0)
        {
            trace(i"No runnable examples found in $(mdFile).");
            continue;
        }

        gathered ~= FileExamples(mdFile, examples);
    }

    if (gathered.length == 0)
        return totalFailures > 0 ? failRun(text(totalFailures, " markdown file(s) failed")) : ranOk();

    const repoRoot = detectRepoRoot();

    // Building (and running) examples is the expensive, parallelizable work; the
    // per-file presentation below is cheap and order-sensitive. So execute every
    // example across all files up front, concurrently, then replay the results
    // through the existing serial display/diff/rewrite loops unchanged. The
    // build graph runs them (M9): each a single-file package against the
    // store's variants, the capacity from `exampleJobCount`, bounding memory.
    auto allExamples = gathered.map!(g => g.examples).joiner.array;
    // Shared full-file programs execute once per invocation. Each occurrence
    // still has its own expected output and Markdown positions below.
    Example[] uniqueExamples;
    size_t[] executionIndices;
    size_t[string] importedIndices;
    foreach (example; allExamples)
    {
        auto existing = example.sourcePath.length ? example.sourcePath in importedIndices : null;
        if (existing !is null) executionIndices ~= *existing;
        else
        {
            executionIndices ~= uniqueExamples.length;
            if (example.sourcePath.length) importedIndices[example.sourcePath] = uniqueExamples.length;
            uniqueExamples ~= example;
        }
    }
    // Contract counterparts are executed independently, never deduplicated by
    // basename with tutorial sources and never used as Markdown update targets.
    size_t[] contractIndices;
    foreach (example; contractExamples)
    {
        if (example.sourcePath in importedIndices) continue;
        importedIndices[example.sourcePath] = uniqueExamples.length;
        contractIndices ~= uniqueExamples.length;
        uniqueExamples ~= example;
    }
    auto uniqueResults = executeExamplesOnGraph(uniqueExamples, repoRoot);
    foreach (index; contractIndices)
    {
        if (!uniqueResults[index].success)
        {
            error(i"Contract example failed: $(uniqueExamples[index].sourcePath)");
            error(i"$(uniqueResults[index].rawOutput)");
            ++totalFailures;
        }
    }
    if (contractIndices.length)
        info(i"Executed $(contractIndices.length) independent contract examples.");
    auto allResults = executionIndices.map!(i => uniqueResults[i]).array;

    size_t offset = 0;
    foreach (g; gathered)
    {
        auto results = allResults[offset .. offset + g.examples.length];
        offset += g.examples.length;

        RunExpected!void rc;
        final switch (action)
        {
            case ExampleAction.run:
                rc = runDefaultMode(g.examples, results, g.mdFile, failFast);
                break;
            case ExampleAction.verify:
                rc = runVerifyMode(g.examples, results, g.mdFile, failFast);
                break;
            case ExampleAction.update:
                rc = runUpdateMode(g.examples, results, g.mdFile, failFast);
                break;
        }

        if (rc.hasError)
        {
            totalFailures++;
            if (failFast)
                return failRun(text(totalFailures, " markdown file(s) failed"));
        }
    }

    return totalFailures > 0 ? failRun(text(totalFailures, " markdown file(s) failed")) : ranOk();
}

/**
Builds and runs `examples` on the build graph (M9, CIC8): each a single-file
package, an inline one extracted to its content-addressed path, built against
the store's variants and run in the worktree. The results are in `examples`'
order; an inline example's output is ANSI-stripped and right-trimmed by line,
as the pre-commit hooks leave the Markdown.
*/
private ExecutionResult[] executeExamplesOnGraph(Example[] examples, string repoRoot)
{
    import example_graph : ExampleJob, extractedExamplePath, runExamplesOnGraph;
    import std.path : absolutePath;

    ExampleJob[] jobs;
    foreach (ref e; examples)
        jobs ~= ExampleJob(e.sourcePath.length ? absolutePath(e.sourcePath)
            : extractedExamplePath(repoRoot, e.name, e.code), e.name);
    string why;
    // Weighted units (CIC1): a compile claims two.
    const outcomes = runExamplesOnGraph(repoRoot, graphStore(), jobs, 2 * exampleJobCount(), exampleTimeout(),
        false, why);
    auto results = new ExecutionResult[examples.length];
    foreach (i, ref e; examples)
    {
        const raw = why.length ? why : outcomes[i].output;
        const cleaned = e.sourcePath.length ? raw.unstyle
            : raw.unstyle.lineSplitter.map!(l => l.stripRight).join("\n");
        results[i] = ExecutionResult(success: !why.length && outcomes[i].success, programOutput: cleaned,
            rawOutput: raw);
    }
    return results;
}

/// The directory holding the build graph's store: `$XDG_CACHE_HOME/sparkles`.
private string graphStore()
{
    const xdg = environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache"));
    return buildPath(xdg, "sparkles");
}

/// Number of example builds to run concurrently. Honors `SPARKLES_CI_JOBS`,
/// otherwise bounds parallelism by both CPU count and available memory — ldc
/// builds are memory-hungry and this work is historically OOM-prone, so we
/// deliberately do not fan out to every core.
private uint exampleJobCount()
{
    if (auto raw = environment.get("SPARKLES_CI_JOBS"))
    {
        try
        {
            const n = raw.to!uint;
            if (n >= 1)
                return n;
        }
        catch (Exception) { /* fall through to the computed default */ }
    }

    // What this host will actually let us run in parallel: a CI container's
    // CPU quota, a ballooned VM's available RAM, and a high load average are
    // all invisible to `totalCPUs`. `hwParallelism` folds those in.
    uint jobs = hwParallelism();

    // Compiler jobs are hungrier than a generic worker: budget ~2 GiB of
    // *total* RAM per concurrent build. Available-RAM clamps already applied
    // above; this one catches a 7 GiB GitHub-hosted macOS VM that still
    // reports 3–4 CPUs.
    if (const mem = hwMemoryBytes())
    {
        const byMem = cast(uint)(mem / (2UL << 30));
        if (byMem >= 1 && byMem < jobs)
            jobs = byMem;
    }

    enum uint hardCap = 12;
    return jobs > hardCap ? hardCap : jobs;
}

/**
Wall-clock budget for a single example.

An example that wedges must fail naming itself rather than consuming the whole
CI step. One stuck example (`valgrind-attribution.d`, on a CircleCI runner)
burned a 20-minute job and the log named nothing at all — the last line was the
*previous* example's success.

Deliberately generous: examples normally take a couple of seconds, so this only
ever fires on a genuine wedge. Override with `SPARKLES_CI_EXAMPLE_TIMEOUT`
(seconds; `0` disables the cap).
*/
package Duration exampleTimeout()
{
    if (auto raw = environment.get("SPARKLES_CI_EXAMPLE_TIMEOUT"))
    {
        try
        {
            const n = raw.to!long;
            return n <= 0 ? Duration.zero : n.seconds;
        }
        catch (Exception) { /* fall through to the default */ }
    }
    return 300.seconds;
}


private bool isAnsiFence(string fenceType)
{
    return fenceType == "ansi" || fenceType.startsWith("ansi [") || fenceType == "[Output:ansi]";
}

/// Extracts dub single-file examples from markdown content,
/// including any adjacent expected-output blocks.
@safe pure
Example[] extractExamples(string content)
{
    // Expected output uses the ```ansi fence (ANSI escapes preserved, rendered
    // as real color by the site). ```[Output] is the legacy spelling and stores
    // ANSI-stripped text; it is still recognised so old blocks keep verifying
    // instead of silently degrading to "no expected output". Bare ``` and all
    // other labelled fences (```d [D], ```rust [Rust], etc.) are code blocks,
    // not output.
    string getOutputFenceType(string s)
    {
        auto stripped = s.strip;
        if (stripped == "```ansi") return "ansi";
        if (stripped == "```[Output:ansi]") return "[Output:ansi]";
        if (stripped == "```[Output]") return "[Output]";
        return null;
    }

    Example[] examples;
    auto lines = content.lineSplitter.array;

    size_t outerFenceEnd = 0; // tracks end of outer (non-D) fenced blocks

    for (size_t idx = 0; idx < lines.length; idx++)
    {
        auto stripped = lines[idx].strip;

        // Skip wrapper blocks (````markdown, etc.) wholesale: the fences inside
        // them are quoted content, not code blocks of this document. The
        // scanning rule is shared with the fence audit — see
        // `fence_audit.wrapperFenceEnd`.
        if (idx >= outerFenceEnd)
        {
            const wrapperEnd = wrapperFenceEnd(lines, idx);
            if (wrapperEnd > 0)
            {
                outerFenceEnd = wrapperEnd;
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

        // An example explicitly marked <!-- md-example-skip --> is neither built
        // nor verified. Advance past it; any adjacent output block is ignored as
        // a non-`d` fence on the next iterations.
        if (precededBySkipDirective(lines, codeStart))
        {
            idx = codeEnd;
            continue;
        }

        if (!isDubSingleFileBlock(codeLines))
        {
            idx = codeEnd;
            continue;
        }

        auto name = extractExampleName(codeLines);

        // Look for adjacent output block (a ```[Output] or ```ansi fence),
        // optionally preceded by a <!-- md-example-expected ... --> directive.
        string expectedOutput = null;
        string verifyPattern = null;
        string outputFenceType = null;
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

        if (searchStart < lines.length)
        {
            outputFenceType = getOutputFenceType(lines[searchStart]);
        }

        if (outputFenceType !is null)
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
            outputFenceType: outputFenceType,
            codeBlockStart: codeStart,
            codeBlockEnd: codeEnd,
            outputBlockStart: outputStart,
            outputBlockEnd: outputEnd,
        );

        idx = (outputEnd != size_t.max) ? outputEnd : codeEnd;
    }

    return examples;
}


private RunExpected!void runExampleFilesMode(string[] allExampleFiles, bool failFast)
{
    // Honor each example's dub `platforms` declaration: skip (don't build) the
    // ones this host can't satisfy — e.g. the Linux-only `io_uring` examples on
    // a macOS runner. dub's `platforms` is advisory and won't stop the build, so
    // the runner enforces it.
    string[] exampleFiles;
    string[] skippedFiles;
    foreach (exampleFile; allExampleFiles)
    {
        if (exampleFile.exists && !exampleRunsOnHost(exampleFile.readText))
            skippedFiles ~= exampleFile;
        else
            exampleFiles ~= exampleFile;
    }

    foreach (skippedFile; skippedFiles)
        info(i"{yellow ⊘} {cyan $(skippedFile.baseName)} — skipped (unsupported on this platform)");

    i"Checking $(exampleFiles.length) standalone example file(s)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");
    flushStdout();

    const repoRoot = detectRepoRoot();

    // M9: every example file on the build graph at once; the results are
    // presented below in input order.
    import example_graph : ExampleJob, runExamplesOnGraph;
    import std.path : absolutePath;

    ExampleJob[] jobs;
    size_t[] jobOf = new size_t[exampleFiles.length];
    foreach (i, exampleFile; exampleFiles)
    {
        jobOf[i] = size_t.max;
        if (!exampleFile.exists)
            continue;
        const spec = detectStandaloneExampleSpec(exampleFile);
        jobOf[i] = jobs.length;
        jobs ~= ExampleJob(absolutePath(exampleFile), exampleFile.baseName,
            spec.mode == StandaloneExampleMode.run ? spec.runArgs.dup : null,
            spec.mode == StandaloneExampleMode.buildOnly);
    }
    string why;
    const outcomes = jobs.length ? runExamplesOnGraph(repoRoot, graphStore(), jobs, 2 * exampleJobCount(),
        exampleTimeout(), failFast, why) : null;
    if (why.length)
        return failRun(why);

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;

    foreach (i, exampleFile; exampleFiles)
    {
        if (!exampleFile.exists)
        {
            error(i"File not found: $(exampleFile)");
            failures++;
            processed = i + 1;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: formatExampleFileHeader(exampleFile, i"[$(i + 1)/$(exampleFiles.length)]".text, "run"),
                    outputLines: [styledText(i"{red File not found:} $(exampleFile)")],
                    footer: styledText(i"{red ✗ missing file}"),
                );
                stoppedEarly = true;
                break;
            }
            continue;
        }

        auto spec = detectStandaloneExampleSpec(exampleFile);
        const action = standaloneExampleAction(spec.mode);
        const verb = standaloneExampleVerb(spec.mode);
        const progress = i"[$(i + 1)/$(exampleFiles.length)]".text;
        const header = formatExampleFileHeader(exampleFile, progress, action, spec.runArgs);
        const outcome = outcomes[jobOf[i]];
        const result = ExecutionResult(success: outcome.success, rawOutput: outcome.output);

        if (result.success)
        {
            info(i"{green ✓} {cyan $(exampleFile.baseName)} — $(verb)");
        }
        else
        {
            failures++;
            auto failureLines = result.rawOutput.lineSplitter
                .map!(l => l.to!string)
                .array
                .formatOutputLines(24)
                .array;
            failureLines
                .drawBox(header, BoxProps(footer: styledText(i"{red ✗ $(action) failed}")))
                .writeln;

            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: failureLines,
                    footer: styledText(i"{red ✗ $(action) failed}"),
                );
                stoppedEarly = true;
                processed = i + 1;
                writeln();
                break;
            }
        }

        processed = i + 1;
    }

    displaySummary(stoppedEarly ? processed : exampleFiles.length, failures);
    if (stoppedEarly)
        displayFailureReplay(failureReplay);
    return failures > 0 ? failRun(text(failures, " example file(s) failed")) : ranOk();
}


/// Default mode: run examples and display output in boxes.
/// `results` holds the pre-computed execution result for each example.
RunExpected!void runDefaultMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
{
    i"Running $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");
    flushStdout();

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;
    foreach (i, example; examples)
    {
        auto progress = i"[$(i + 1)/$(examples.length)]".text;
        auto result = results[i];
        auto header = formatExampleHeader(example, progress);
        auto outputLines = result.rawOutput.lineSplitter
            .map!(l => l.to!string)
            .array;

        displayResultBox(outputLines, header, result.success, result.usage);

        if (!result.success)
        {
            failures++;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: outputLines.formatOutputLines(8, keepTail: true).array,
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
    return failures > 0 ? failRun(text(failures, " example(s) failed")) : ranOk();
}

/// Verify mode: run examples, display output, and compare against expected output blocks.
/// `results` holds the pre-computed execution result for each example.
@("ci.importedOutputsAreMandatoryAndLiteral") unittest
{
    Example example = Example(sourcePath: "/docs/fixture.mjs", name: "fixture",
        outputFenceType: "ansi [fixture output]");
    ExecutionResult result = ExecutionResult(success: true, programOutput: "unexpected", rawOutput: "unexpected");
    assert(runVerifyMode([example], [result], "fixture.md", false).hasError,
        "an empty imported output must not mean skip verification");
    example.expectedOutput = "...";
    assert(runVerifyMode([example], [result], "fixture.md", false).hasError,
        "imported outputs are literal, not wildcard patterns");
    example.expectedOutput = null;
    result.programOutput = result.rawOutput = null;
    assert(!runVerifyMode([example], [result], "fixture.md", false).hasError);
}

RunExpected!void runVerifyMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
{
    i"Verifying $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");
    flushStdout();

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;
    foreach (i, example; examples)
    {
        auto progress = i"[$(i + 1)/$(examples.length)]".text;
        auto header = formatExampleHeader(example, progress);
        auto result = results[i];
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
                .drawBox(header, resultBox(styledText(i"{red ✗ build failed}")))
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

        if (verifyAgainst is null && example.sourcePath.length == 0)
        {
            outputLines
                .formatOutputLines
                .drawBox(header, resultBox(styledText(i"{green ✓ ran} {dim │} {yellow ⚠ no expected output}")))
                .writeln;
            writeln();
            processed = i + 1;
            continue;
        }

        string actual;
        if (example.verifyPattern is null && isAnsiFence(example.outputFenceType))
        {
            actual = result.rawOutput
                .lineSplitter
                .map!(l => l.stripRight)
                .join("\n")
                .strip;
        }
        else
        {
            actual = result.programOutput.strip;
        }
        auto expected = verifyAgainst.strip;

        if (example.sourcePath.length ? actual == expected : matchesWithWildcards(actual, expected))
        {
            outputLines
                .formatOutputLines
                .drawBox(header, resultBox(styledText(i"{green ✓ ran} {dim │} {green ✓ output matches}")))
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
                .drawBox(header, resultBox(styledText(i"{green ✓ ran} {dim │} {red ✗ output mismatch}")))
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
    return failures > 0 ? failRun(text(failures, " example(s) did not match their output")) : ranOk();
}

/// Update mode: rewrite the markdown file with actual output.
/// Processes examples in reverse order so line indices remain valid.
/// `results` holds the pre-computed execution result for each example.
RunExpected!void runUpdateMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
{
    i"Updating $(examples.length) example(s) in $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    auto lines = mdFile.readText.lineSplitter.array;
    int failures = 0;
    int updated = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;

    foreach_reverse (i, example; examples)
    {
        auto result = results[i];

        if (!result.success)
        {
            failures++;
            error(i"  {red ✗} {cyan $(example.name)} — build failed, skipping");
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

        string actualOutput;
        // Newly inserted output blocks default to ```ansi so colors survive.
        // An existing block keeps its own fence type (including the legacy
        // ```[Output], which stores ANSI-stripped text).
        string fenceType = "ansi";

        if (example.outputFenceType !is null)
        {
            fenceType = example.outputFenceType;
        }

        if (isAnsiFence(fenceType))
        {
            actualOutput = result.rawOutput
                .lineSplitter
                .map!(l => l.stripRight)
                .join("\n")
                .strip;
        }
        else
        {
            actualOutput = result.programOutput.strip;
        }

        if (example.expectedOutput !is null && actualOutput == example.expectedOutput.strip)
        {
            info(i"  {green ✓} {cyan $(example.name)} — output unchanged");
            processed = examples.length - i;
            continue;
        }

        auto newOutputLines = ["```" ~ fenceType]
            ~ actualOutput.lineSplitter.map!(l => l.idup).array
            ~ ["```"];

        if (example.outputBlockStart != size_t.max)
        {
            // Replace existing output block
            lines = lines[0 .. example.outputBlockStart]
                ~ newOutputLines.map!(l => l.idup).array
                ~ lines[example.outputBlockEnd + 1 .. $];
            updated++;
            info(i"  {yellow ↻} {cyan $(example.name)} — output block updated");
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
            info(i"  {yellow +} {cyan $(example.name)} — output block inserted");
        }
        processed = examples.length - i;
    }

    if (updated > 0 && !stoppedEarly)
        mdFile.write(lines.join("\n") ~ "\n");

    writeln();
    if (updated > 0 && !stoppedEarly)
        info(i"{green ✓} Updated $(updated) output block(s) in $(mdFile)");
    else if (updated > 0)
        warning(i"{yellow ⚠} Stopped before writing $(updated) pending output block update(s) in $(mdFile)");
    else
        info(i"{green ✓} All output blocks already up to date");

    if (failures > 0)
    {
        error(i"{red ✗} $(failures) example(s) failed to build");
        displaySummary(stoppedEarly ? processed : examples.length, failures);
        if (stoppedEarly)
            displayFailureReplay(failureReplay);
        return failRun(text(failures, " example(s) failed to build"));
    }

    displaySummary(examples.length, 0);
    return ranOk();
}

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

/// True when the code fence beginning at `codeStart` is immediately preceded
/// (ignoring blank lines) by a `<!-- md-example-skip ... -->` directive.
///
/// A skipped example is neither built nor verified — used to park a runnable
/// example whose dependency does not exist yet (e.g. a spec written before its
/// implementation lands). Remove the directive to make the example required.
@safe pure
private bool precededBySkipDirective(const(char[])[] lines, size_t codeStart)
{
    enum openTag = "<!-- md-example-skip";
    enum closeTag = "-->";

    if (codeStart == 0)
        return false;

    ptrdiff_t i = cast(ptrdiff_t) codeStart - 1;
    while (i >= 0 && lines[i].strip.length == 0)
        i--;
    if (i < 0)
        return false;

    auto s = lines[i].strip;
    return s.startsWith(openTag) && s.endsWith(closeTag);
}

/// Checks if code lines represent a dub single-file program: a `dub`
/// shebang, an embedded SDL recipe (the shared locator), and a `main`.
@safe pure
private bool isDubSingleFileBlock(const(char[])[] codeLines)
{
    import std.array : join;
    import sparkles.wired.sdl : locateEmbeddedRecipe;

    if (codeLines.length < 2 || !codeLines[0].strip.startsWith("#!/usr/bin/env dub"))
        return false;
    const recipe = locateEmbeddedRecipe(codeLines.join('\n'));
    if (!recipe.found || recipe.isJson)
        return false;

    bool hasMain = false;
    foreach (line; codeLines)
    {
        if (line.canFind("main"))
        {
            hasMain = true;
            break;
        }
    }
    return hasMain;
}

/// The example's name: its embedded recipe's `name`, or `unnamed`.
@safe pure
private string extractExampleName(const(char[])[] codeLines)
{
    import std.array : join;
    import sparkles.build_primitives.dub_manifest : parseEmbeddedDubManifest;

    const manifest = parseEmbeddedDubManifest(codeLines.join('\n'));
    return manifest.hasValue && manifest.value.name.length ? manifest.value.name : "unnamed";
}


private StandaloneExampleSpec detectStandaloneExampleSpec(string filePath)
{
    return parseStandaloneExampleSpec(filePath.readText.lineSplitter.array);
}

@safe pure
private StandaloneExampleSpec parseStandaloneExampleSpec(const(char[])[] lines)
{
    import std.array : join;
    import sparkles.wired.sdl : locateEmbeddedRecipe;

    enum metadataPrefixes = ["// ci:", "// run_md_examples:"];

    // The directives follow the embedded recipe, which the shared locator
    // finds and ends at its first `+/`, as DUB does.
    const text = lines.join('\n');
    const recipe = locateEmbeddedRecipe(text);
    const rest = recipe.found ? text[recipe.close.endOffset .. $] : text;

    foreach (line; rest.lineSplitter)
    {
        const stripped = line.strip;

        if (stripped.length == 0)
            continue;

        if (stripped.startsWith("#!"))
            continue;

        // A `module …;` declaration may sit between the recipe and the
        // directive. It is not a comment, so without this the scan would stop
        // at it (see the loop tail) and the directive below would be ignored —
        // the example would silently run when it asked to be built only.
        if (stripped.startsWith("module ") && stripped.endsWith(";"))
            continue;

        foreach (metadataPrefix; metadataPrefixes)
        {
            if (!stripped.startsWith(metadataPrefix))
                continue;

            // `<mode>` or `<mode> <args…>` — the first word selects the mode,
            // the rest are the program's arguments. Only the mode word is
            // lowercased; arguments are the author's, case included.
            const value = stripped[metadataPrefix.length .. $].strip;
            const spaceIdx = value.indexOf(' ');
            const modeWord = (spaceIdx < 0 ? value : value[0 .. spaceIdx]).asciiLower;
            const argsPart = spaceIdx < 0 ? "" : value[spaceIdx + 1 .. $].strip;

            if (modeWord == "build-only")
                return StandaloneExampleSpec(StandaloneExampleMode.buildOnly, null);

            string[] runArgs;
            if (argsPart.length > 0)
                runArgs = argsPart.split.map!(a => a.idup).array;
            return StandaloneExampleSpec(StandaloneExampleMode.run, runArgs);
        }

        if (!stripped.startsWith("//"))
            break;
    }

    return StandaloneExampleSpec(StandaloneExampleMode.run, null);
}

@("ci.parseStandaloneExampleSpec.directives")
@safe pure unittest
{
    static StandaloneExampleSpec parse(string directive)
    {
        return parseStandaloneExampleSpec([
            "#!/usr/bin/env dub",
            "/+ dub.sdl:",
            `    name "demo"`,
            "+/",
            directive,
        ]);
    }

    // No arguments: the mode word alone.
    assert(parse("// ci: run") == StandaloneExampleSpec(StandaloneExampleMode.run, null));
    assert(parse("// ci: build-only")
        == StandaloneExampleSpec(StandaloneExampleMode.buildOnly, null));

    // Arguments after the mode word are the program's.
    assert(parse("// ci: run --help")
        == StandaloneExampleSpec(StandaloneExampleMode.run, ["--help"]));
    assert(parse("// ci: run --colour never --width 80")
        == StandaloneExampleSpec(StandaloneExampleMode.run, ["--colour", "never", "--width", "80"]));

    // The mode word is matched case-insensitively; arguments are not touched.
    assert(parse("// ci: RUN --Tag Value")
        == StandaloneExampleSpec(StandaloneExampleMode.run, ["--Tag", "Value"]));

    // `build-only` never runs, so it carries no arguments even if given some.
    assert(parse("// ci: build-only --help")
        == StandaloneExampleSpec(StandaloneExampleMode.buildOnly, null));

    // The legacy prefix still works.
    assert(parse("// run_md_examples: run --help")
        == StandaloneExampleSpec(StandaloneExampleMode.run, ["--help"]));
}

@("ci.parseStandaloneExampleSpec.defaultsToRun")
@safe pure unittest
{
    // No directive at all.
    assert(parseStandaloneExampleSpec(["module demo;", "import std.stdio;"])
        == StandaloneExampleSpec(StandaloneExampleMode.run, null));

    // The scan stops at the first line that is neither a comment nor part of
    // the header, so a `// ci:` below the code is not a directive.
    assert(parseStandaloneExampleSpec(["import std.stdio;", "// ci: build-only"])
        == StandaloneExampleSpec(StandaloneExampleMode.run, null));
}

// A `module …;` declaration is not a comment, so it would end the header scan
// and take any directive below it with it — the example would run when it
// asked to be built only.
@("ci.parseStandaloneExampleSpec.moduleDeclarationDoesNotEndTheHeader")
@safe pure unittest
{
    assert(parseStandaloneExampleSpec([
        "#!/usr/bin/env dub",
        "/+ dub.sdl:",
        `    name "demo"`,
        "+/",
        "module demo;",
        "// ci: build-only",
    ]) == StandaloneExampleSpec(StandaloneExampleMode.buildOnly, null));

    assert(parseStandaloneExampleSpec(["module demo;", "// ci: run --help"])
        == StandaloneExampleSpec(StandaloneExampleMode.run, ["--help"]));
}


private string standaloneExampleAction(StandaloneExampleMode mode)
{
    return mode == StandaloneExampleMode.buildOnly ? "build" : "run";
}

private string standaloneExampleVerb(StandaloneExampleMode mode)
{
    return mode == StandaloneExampleMode.buildOnly ? "built" : "ran";
}

/// Formats the header line for an example run.
private string formatExampleHeader(in Example example, string progress)
{
    if (example.sourcePath.endsWith(".mjs"))
        return styledText(i"{dim $(progress)} {cyan $(example.name)} {dim › node $(example.sourcePath.baseName)}");
    return styledText(i"{dim $(progress)} {cyan $(example.name)} {dim › build and run $(example.name).d}");
}

private string formatExampleFileHeader(
    string exampleFile,
    string progress,
    string action,
    string[] runArgs = null,
)
{
    const argsSuffix = runArgs.length > 0 ? " -- " ~ runArgs.join(" ") : "";
    return styledText(i"{dim $(progress)} {cyan $(exampleFile.baseName)} {dim › dub $(action) --single $(exampleFile)$(argsSuffix)}");
}
