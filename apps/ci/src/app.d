/++
Repository CI helper for runnable markdown examples, standalone `.d` files,
dub package tests, and markdown reference maintenance.

This script can parse markdown files to find code blocks that represent
dub single-file programs, execute them, and report results. It can also
smoke-test tracked standalone example files such as `libs/base/examples/*.d`
and `libs/core-cli/examples/*.d`, or run `dub test` for each sub-package
defined in the root `dub.sdl`.

Standalone example files can declare that they should be compiled but not
executed by placing a header comment after the `dub.sdl` block:
---d
// ci: build-only
---

Usage:
---
nix run .#ci -- [--verify|--update] [--fail-fast] [--files GLOB|FILE...]
nix run .#ci -- --example-files [--fail-fast] [--files GLOB|FILE...]
nix run .#ci -- --test [--fail-fast]
nix run .#ci -- [--dedup-reference-links|--fix-reference-links] [--files GLOB|FILE...]
nix run .#ci -- [--log-level trace|info|warning|error]
---

Modes:

$(LIST
    $(ITEM Default — run examples and display results in boxes)
    $(ITEM `--verify` — compare output against expected output blocks, report mismatches)
    $(ITEM `--update` — rewrite the markdown file with actual example output (golden snapshot update))
    $(ITEM `--example-files` — build/run standalone example `.d` files, defaulting to `libs/base/examples/*.d`, `libs/core-cli/examples/*.d`, and `docs/research/async-io/io-uring/examples/*.d`)
    $(ITEM `--test` — run `dub test` for each sub-package defined in the root `dub.sdl`)
    $(ITEM `--files` — select explicit files or git-style globs; when omitted, each mode uses its tracked defaults)
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

When a `[Output]`-labelled fenced block immediately follows a runnable code
block, it is treated as the expected output for that example:
---
```[Output]
expected output here
```
---

For examples with dynamic output (timestamps, file locations, etc.), place a
`<!-- md-example-expected -->` HTML comment directive between the code block
and the output block. The directive contains a wildcard pattern used for
`--verify` instead of the literal output block. Use `{{_}}` as a wildcard
that matches any non-empty text:

---html
<!-- md-example-expected
[ {{_}} | info ]: Listening on port 8080
-->
```[Output]
[ 14:32:01 | info ]: Listening on port 8080
```
---

The literal output block is kept for display in rendered markdown, while the
wildcard pattern handles verification against the actual (dynamic) output.

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

// std.* modules
import std.algorithm : any, canFind, countUntil, filter, joiner, map, min, sort, startsWith;
import std.array : array, join;
import std.conv : text, to;
import core.time : msecs;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.parallelism : TaskPool, totalCPUs;
import std.path : baseName, buildPath;
import std.process : environment, execute;
import std.range : iota;
import std.regex : ctRegex, matchFirst;
import std.stdio : writeln;
import std.string : endsWith, indexOf, lineSplitter, replace, strip, stripRight, toLower;

// sparkles packages
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;
import sparkles.base.logger : error, info, initLogger, LogLevel, trace, warning;
import sparkles.core_cli.process_utils :
    executeMonitored, MonitoredResult, ResourceUsage, selfRssBytes;
import sparkles.base.styled_template : styledText, styledWritelnErr;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.core_cli.ui.box : BoxProps, drawBox, TitleOverflow;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

// in-app modules
import dub_deps : parseSubPackages, rewriteInTreeDeps;
import example_manifest : exampleRunsOnHost;

// === UI sizing ===

/// Shared visible-column width for all UI chrome: `drawHeader` banners and the
/// `drawBox` `minWidth`/`maxWidth`. Keeping these in lockstep makes headers and
/// the boxes beneath them line up at a single, predictable width — capped at the
/// terminal so chrome never overflows a window narrower than 120 columns, and
/// defaulting to 120 when stdout is not a tty (piped output, CI).
private size_t uiWidth()
{
    import sparkles.core_cli.term_caps : terminalSize;

    const w = terminalSize().width;
    return w == 0 ? 120 : min(120, w);
}

/// `BoxProps` for an example result box: a fixed `uiWidth` frame (long output
/// wraps in, short output pads out) so every box lines up under its banner. A
/// long title wraps into a nested title box rather than overflowing the frame,
/// matching the banner header above it.
private BoxProps resultBox(string footer)
{
    const w = uiWidth();
    return BoxProps(footer: footer, minWidth: w, maxWidth: w, titleOverflow: TitleOverflow.wrap);
}

// === Types ===

struct CliParams
{
    @CliOption(`V|verify`, "Compare example output against expected output blocks in the markdown.")
    bool verify;

    @CliOption(`u|update`, "Rewrite the markdown file with actual example output.")
    bool update;

    @CliOption(`x|example-files`, "Run standalone example .d files instead of markdown examples. With no files, defaults to libs/base/examples/*.d, libs/core-cli/examples/*.d, docs/research/async-io/io-uring/examples/*.d, and docs/research/units-of-measure/examples/*.d.")
    bool exampleFiles;

    @CliOption(`t|test`, "Run dub test for each sub-package defined in the root dub.sdl.")
    bool test;

    @CliOption(`F|fail-fast`, "Stop on the first failing example and replay its output at the end.")
    bool failFast;

    @CliOption(`files`, "Explicit file paths or git-style globs to include. Pass one or more selectors immediately after --files.")
    string[] files;

    @CliOption(`d|dedup-reference-links`, "Report duplicate markdown reference definitions that point to the same URL.")
    bool dedupReferenceLinks;

    @CliOption(`f|fix-reference-links`, "Rewrite duplicate markdown references to one canonical label per URL.")
    bool fixReferenceLinks;

    @CliOption(`L|log-level`, "Set the log level (trace, info, warning, error). Default: info.")
    LogLevel logLevel = LogLevel.info;
}

enum ProgramMode
{
    runExamples,
    verifyExamples,
    updateExamples,
    runExampleFiles,
    runDubTests,
    checkReferenceLinks,
    fixReferenceLinks,
}

struct Example
{
    string name;
    string code;
    string expectedOutput;
    string verifyPattern; /// Wildcard pattern from `<!-- md-example-expected -->` directive
    string outputFenceType; /// "[Output]" or "ansi" or null if no output block
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
}

enum StandaloneExampleMode
{
    run,
    buildOnly,
}

struct FailureReplay
{
    string header;
    string[] outputLines;
    string footer;
}

struct FileSelection
{
    bool specified;
    string[] selectors;
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
    auto parseArgs = args.dup;
    const fileSelection = extractFilesOption(parseArgs);
    auto cli = parseArgs.parseCliArgs!CliParams(
        HelpInfo(
            "ci",
            "Run repository CI helpers for markdown examples, standalone example files, and markdown reference maintenance",
        ),
    );
    cli.files = fileSelection.selectors.dup;
    initLogger(cli.logLevel);

    const positionalArgs = parseArgs[1 .. $]
        .map!(arg => arg.idup)
        .array;
    const modeError = validateCliMode(cli, positionalArgs, fileSelection);
    if (modeError !is null)
    {
        error(i"$(modeError)");
        return 1;
    }

    const mode = resolveProgramMode(cli);

    if (mode == ProgramMode.runDubTests)
        return runDubTestsMode(cli.failFast);

    auto inputFiles = collectInputFiles(cli, mode);

    if (inputFiles.length == 0)
    {
        if (cli.files.length > 0)
        {
            error(i"--files did not match any supported input files for this mode");
            return 1;
        }

        if (isReferenceMode(mode))
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--dedup-reference-links|--fix-reference-links] [--files GLOB|FILE...]");
        else if (mode == ProgramMode.runExampleFiles)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --example-files [--fail-fast] [--files GLOB|FILE...]");
        else
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--verify|--update] [--fail-fast] [--files GLOB|FILE...]");
        return 1;
    }

    if (mode == ProgramMode.runExampleFiles)
        return runExampleFilesMode(inputFiles, cli.failFast);

    if (mode == ProgramMode.checkReferenceLinks)
        return runReferenceLinkMode(inputFiles, false);

    if (mode == ProgramMode.fixReferenceLinks)
        return runReferenceLinkMode(inputFiles, true);

    return runExamplesForFiles(inputFiles, mode, cli.failFast);
}

private string validateCliMode(
    in CliParams cli,
    in string[] positionalArgs,
    in FileSelection fileSelection,
)
{
    if (cli.verify && cli.update)
        return "--verify and --update are mutually exclusive";

    if (cli.exampleFiles && (cli.verify || cli.update))
        return "--example-files cannot be combined with --verify or --update";

    if (cli.test && (cli.verify || cli.update))
        return "--test cannot be combined with --verify or --update";

    if (cli.test && cli.exampleFiles)
        return "--test cannot be combined with --example-files";

    if ((cli.verify || cli.update)
        && (cli.dedupReferenceLinks || cli.fixReferenceLinks))
    {
        return "example modes (--verify/--update) cannot be combined with reference deduplication modes (--dedup-reference-links/--fix-reference-links)";
    }

    if (cli.exampleFiles && (cli.dedupReferenceLinks || cli.fixReferenceLinks))
        return "--example-files cannot be combined with reference deduplication modes (--dedup-reference-links/--fix-reference-links)";

    if (cli.test && (cli.dedupReferenceLinks || cli.fixReferenceLinks))
        return "--test cannot be combined with reference deduplication modes (--dedup-reference-links/--fix-reference-links)";

    if (positionalArgs.length > 0)
        return "Positional file arguments are no longer supported; use --files";

    if (fileSelection.specified && cli.files.length == 0)
        return "--files requires at least one file path or git-style glob";

    return null;
}

private ProgramMode resolveProgramMode(in CliParams cli)
{
    if (cli.exampleFiles)
        return ProgramMode.runExampleFiles;

    if (cli.test)
        return ProgramMode.runDubTests;

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
        error(i"Failed to enumerate markdown files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

/// Git pathspecs for the repository's standalone example `.d` files — the
/// defaults `--example-files` uses when no `--files` selection is given: the
/// `base` and `core-cli` library demos plus the worked examples that accompany
/// the research docs (`docs/research/async-io/io-uring/` and
/// `docs/research/units-of-measure/`).
@safe pure nothrow
private string[] standaloneExampleGlobs()
{
    return [
        "libs/base/examples/*.d",
        "libs/core-cli/examples/*.d",
        "docs/research/async-io/io-uring/examples/*.d",
        "docs/research/units-of-measure/examples/*.d",
    ];
}

private string[] trackedStandaloneExampleFiles()
{
    const result = execute(["git", "ls-files", "--"] ~ standaloneExampleGlobs());
    if (result.status != 0)
    {
        error(i"Failed to enumerate standalone example files with git ls-files");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

private FileSelection extractFilesOption(ref string[] argv)
{
    FileSelection selection;
    string[] filteredArgs;

    if (argv.length == 0)
        return selection;

    filteredArgs ~= argv[0];

    size_t idx = 1;
    while (idx < argv.length)
    {
        const arg = argv[idx];

        if (arg == "--files")
        {
            selection.specified = true;
            idx++;

            while (idx < argv.length && !argv[idx].startsWith("-"))
            {
                selection.selectors ~= argv[idx].idup;
                idx++;
            }

            continue;
        }

        if (arg.startsWith("--files="))
        {
            selection.specified = true;
            const selector = arg["--files=".length .. $].strip;
            if (selector.length > 0)
                selection.selectors ~= selector.idup;
            idx++;
            continue;
        }

        filteredArgs ~= arg;
        idx++;
    }

    argv = filteredArgs;
    return selection;
}

@safe pure nothrow @nogc
private bool isGlobSelector(string selector)
{
    return selector.canFind("*")
        || selector.canFind("?")
        || selector.canFind("[");
}

private string[] trackedFilesMatching(string pattern)
{
    const result = execute(["git", "ls-files", "--", pattern]);
    if (result.status != 0)
    {
        error(i"Failed to enumerate tracked files matching $(pattern)");
        return [];
    }

    return result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .map!(line => line.idup)
        .array;
}

private string[] collectInputFiles(
    in CliParams cli,
    in ProgramMode mode,
)
{
    const hasExplicitSelection = cli.files.length > 0;

    string[] inputFiles;

    foreach (selector; cli.files)
    {
        if (selector.length == 0)
            continue;

        if (isGlobSelector(selector))
            inputFiles ~= trackedFilesMatching(selector);
        else
            inputFiles ~= selector.idup;
    }

    if (inputFiles.length == 0 && !hasExplicitSelection)
    {
        if (isReferenceMode(mode))
            inputFiles = trackedMarkdownFiles();
        else if (mode == ProgramMode.runExampleFiles)
            inputFiles = trackedStandaloneExampleFiles();
    }

    const requiredSuffix = mode == ProgramMode.runExampleFiles ? ".d" : ".md";

    return inputFiles
        .filter!(path => path.length > 0)
        .filter!(path => path.endsWith(requiredSuffix))
        .map!(path => path.idup)
        .array;
}

private int runExamplesForFiles(string[] mdFiles, in ProgramMode mode, bool failFast)
{
    static struct FileExamples
    {
        string mdFile;
        Example[] examples;
    }

    FileExamples[] gathered;
    int totalFailures = 0;

    foreach (mdFile; mdFiles)
    {
        if (!mdFile.exists)
        {
            error(i"File not found: $(mdFile)");
            totalFailures++;
            continue;
        }

        auto examples = extractExamples(mdFile.readText);

        if (examples.length == 0)
        {
            trace(i"No runnable examples found in $(mdFile).");
            continue;
        }

        gathered ~= FileExamples(mdFile, examples);
    }

    if (gathered.length == 0)
        return totalFailures > 0 ? 1 : 0;

    const repoRoot = detectRepoRoot();

    // Building (and running) examples is the expensive, parallelizable work; the
    // per-file presentation below is cheap and order-sensitive. So execute every
    // example across all files up front, concurrently, then replay the results
    // through the existing serial display/diff/rewrite loops unchanged.
    // Concurrency is race-free thanks to `--temp-build` (see executeExample) and
    // bounded by `exampleJobCount` to keep peak memory in check.
    auto allExamples = gathered.map!(g => g.examples).joiner.array;
    auto allResults = executeExamplesParallel(allExamples, repoRoot);

    size_t offset = 0;
    foreach (g; gathered)
    {
        auto results = allResults[offset .. offset + g.examples.length];
        offset += g.examples.length;

        int rc;
        final switch (mode)
        {
            case ProgramMode.runExamples:
                rc = runDefaultMode(g.examples, results, g.mdFile, failFast);
                break;
            case ProgramMode.verifyExamples:
                rc = runVerifyMode(g.examples, results, g.mdFile, failFast);
                break;
            case ProgramMode.updateExamples:
                rc = runUpdateMode(g.examples, results, g.mdFile, failFast);
                break;
            case ProgramMode.runExampleFiles:
            case ProgramMode.runDubTests:
                rc = 1;
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

    uint jobs = totalCPUs < 1 ? 1 : cast(uint) totalCPUs;

    // Budget ~2 GiB of headroom per concurrent build.
    if (const memGiB = totalMemoryGiB())
    {
        const byMem = cast(uint)(memGiB / 2);
        if (byMem >= 1 && byMem < jobs)
            jobs = byMem;
    }

    enum uint hardCap = 12;
    return jobs > hardCap ? hardCap : jobs;
}

/// Total physical memory in GiB, or 0 when it cannot be determined (non-Linux,
/// or `/proc/meminfo` unavailable) — callers treat 0 as "no memory-based cap".
private size_t totalMemoryGiB()
{
    version (linux)
    {
        import std.ascii : isDigit;

        if (!"/proc/meminfo".exists)
            return 0;

        foreach (line; "/proc/meminfo".readText.lineSplitter)
        {
            if (!line.startsWith("MemTotal:"))
                continue;

            auto digits = line.filter!isDigit.to!string; // value is in kB
            return digits.length ? digits.to!size_t / (1024 * 1024) : 0;
        }
    }

    return 0;
}

/// Executes every example concurrently, returning results in input order.
/// Each build runs in its own `DUB_HOME` (see `executeExample`), so the parallel
/// `dub run`s never race on a shared dependency artifact.
private ExecutionResult[] executeExamplesParallel(Example[] examples, string repoRoot)
{
    auto results = new ExecutionResult[](examples.length);

    if (examples.length <= 1)
    {
        if (examples.length == 1)
            results[0] = executeExample(examples[0], repoRoot, 0);
        return results;
    }

    const jobs = exampleJobCount();

    // `parallel` also drives work on the calling thread, so a pool of N worker
    // threads yields N+1 concurrent builds — size it to honor `jobs` as the cap.
    auto pool = new TaskPool(jobs <= 1 ? 0 : jobs - 1);
    scope(exit) pool.finish(true);

    foreach (i; pool.parallel(iota(examples.length), 1))
        results[i] = executeExample(examples[i], repoRoot, i);

    return results;
}

private int runReferenceLinkMode(string[] mdFiles, bool fix)
{
    const title = fix
        ? "Rewriting duplicate markdown reference links"
        : "Checking duplicate markdown reference links";
    title
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    string[] existingFiles;
    int missingFiles = 0;
    foreach (filePath; mdFiles)
    {
        if (!filePath.exists)
        {
            error(i"File not found: $(filePath)");
            missingFiles++;
            continue;
        }
        existingFiles ~= filePath;
    }

    auto duplicateGroups = collectDuplicateGroups(existingFiles);
    if (duplicateGroups.length == 0)
    {
        info(i"{green ✓} No duplicate markdown reference URLs found.");
        return missingFiles > 0 ? 1 : 0;
    }

    printDuplicateGroups(duplicateGroups);

    if (!fix)
        return 1;

    auto changedFiles = fixDuplicateGroups(existingFiles, duplicateGroups);

    writeln();
    info(i"{green ✓} Updated $(changedFiles.length) file(s).");
    foreach (filePath; changedFiles)
        writeln("  ", filePath);

    return missingFiles > 0 ? 1 : 0;
}

// === Core Functions ===

private bool isAnsiFence(string fenceType)
{
    return fenceType == "ansi" || fenceType == "[Output:ansi]";
}

/// Extracts dub single-file examples from markdown content,
/// including any adjacent expected-output blocks.
@safe pure
Example[] extractExamples(string content)
{
    // Expected output uses the ```[Output] or ```ansi fence (a VitePress code-group
    // label). Bare ``` and all other labelled fences (```d [D], ```rust
    // [Rust], etc.) are code blocks, not output.
    string getOutputFenceType(string s)
    {
        auto stripped = s.strip;
        if (stripped == "```[Output]") return "[Output]";
        if (stripped == "```ansi") return "ansi";
        if (stripped == "```[Output:ansi]") return "[Output:ansi]";
        return null;
    }

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

/// Builds and runs a single example, returning its combined result.
///
/// Uses `dub run --quiet --temp-build`: `--quiet` keeps a successful run's
/// captured output to just the program's own stdout (no dub progress noise to
/// pollute the diff against the markdown's expected block), while `--temp-build`
/// isolates the build so concurrent example runs don't race on shared dependency
/// artifacts (see `dubSingleFileCommand`). `--temp-build` also places the binary
/// in a temp folder we don't track, so we let `dub run` execute it rather than
/// invoking it ourselves.
ExecutionResult executeExample(in Example example, string repoRoot, size_t uniqueId)
{
    // Give each example its own subdirectory: examples in different markdown
    // files can share a `name` (hence the same source filename), and these runs
    // happen concurrently. Keep the filename itself unchanged — ldc derives the
    // module name from it, which must stay a valid identifier.
    auto exampleDir = buildPath(tempDir, "md-examples", uniqueId.to!string);
    mkdirRecurse(exampleDir);
    auto tmpFile = buildPath(exampleDir, example.name ~ ".d");

    auto code = repoRoot.length
        ? rewriteInTreeDeps(example.code, repoRoot, exampleDir)
        : example.code;
    tmpFile.write(code);
    scope(exit)
    {
        import std.file : rmdirRecurse;
        if (exampleDir.exists) rmdirRecurse(exampleDir);
    }

    // Give each example its own `DUB_HOME` so concurrent builds don't race.
    // README examples depend on the in-repo `sparkles` package as `~master`,
    // which dub rebuilds *in place and unlocked* on every `dub run` (it's a
    // mutable branch version, never cached) — parallel builds then clobber the
    // shared `libsparkles_*.a`. `--temp-build` only isolates the leaf
    // single-file build, not this path dependency; a per-example home isolates
    // it. Registry deps still resolve normally (dub locks its own fetches).
    auto dubHome = buildPath(exampleDir, "dub-home");
    auto cmd = ["/usr/bin/env", "DUB_HOME=" ~ dubHome]
        ~ dubSingleFileCommand("run", tmpFile, repoRoot);
    auto result = executeLogged(cmd, "run " ~ example.name);

    // Strip ANSI codes, then trim trailing whitespace from each line
    // so output matches what pre-commit hooks produce in markdown files.
    auto cleaned = result.output.unstyle
        .lineSplitter
        .map!(l => l.stripRight)
        .join("\n");

    return ExecutionResult(
        success: result.status == 0,
        programOutput: cleaned,
        rawOutput: result.output,
    );
}

/**
Runs `args` like `std.process.execute`, returning a `MonitoredResult` (same
`status`/`output` fields the callers read). At `--log-level trace` it routes
through $(REF executeMonitored, sparkles,core_cli,process_utils), emitting the
process tree's resident-set size as it climbs plus a per-command summary — the
instrumentation for troubleshooting OOM during a build. At coarser levels it is
a plain `execute` with no sampling overhead.
*/
private MonitoredResult executeLogged(const(string)[] args, string label)
{
    import std.array : join;
    import std.logger : globalLogLevel;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeBytes, writeDuration;

    if (globalLogLevel > LogLevel.trace)
    {
        auto r = execute(args);
        return MonitoredResult(r.status, r.output);
    }

    const cmd = args.join(" ");
    trace(i"{dim ▸ $(label):} {dim $(cmd)}");

    // Log only when the peak climbs by a notable step, so a long compile does
    // not flood the trace with flat-line samples.
    enum size_t logStep = 256UL << 20;   // 256 MiB
    size_t lastLogged;
    auto res = executeMonitored(args, 500.msecs, (in ResourceUsage u) @safe {
        if (u.peakRssBytes >= lastLogged + logStep)
        {
            lastLogged = u.peakRssBytes;
            SmallBuffer!(char, 24) rss, cpu;
            writeBytes(rss, u.peakRssBytes);
            writeDuration(cpu, u.cpuTime);
            trace(i"{dim   $(label)} rss=$(rss[]) cpu=$(cpu[])");
        }
    });

    if (res.usage.sampled)
    {
        SmallBuffer!(char, 24) peak, cpu, ciRss;
        writeBytes(peak, res.usage.peakRssBytes);
        writeDuration(cpu, res.usage.cpuTime);
        writeBytes(ciRss, selfRssBytes());
        trace(i"{dim ◂ $(label):} peak_rss=$(peak[]) cpu=$(cpu[]) exit=$(res.status) (ci_rss=$(ciRss[]))");
    }
    else
        trace(i"{dim ◂ $(label):} exit=$(res.status) (resource sampling unavailable here)");

    return res;
}

private int runExampleFilesMode(string[] allExampleFiles, bool failFast)
{
    // Honor each example's dub `platforms` declaration: skip (don't build) the
    // ones this host can't satisfy — e.g. the Linux-only `io_uring` examples on
    // a macOS runner. dub's `platforms` is advisory and won't stop the build, so
    // the runner enforces it.
    string[] exampleFiles;
    string[] skippedFiles;
    foreach (exampleFile; allExampleFiles)
    {
        if (exampleFile.exists && !exampleRunsOnHost(exampleFile.readText.lineSplitter.array))
            skippedFiles ~= exampleFile;
        else
            exampleFiles ~= exampleFile;
    }

    foreach (skippedFile; skippedFiles)
        info(i"{yellow ⊘} {cyan $(skippedFile.baseName)} — skipped (unsupported on this platform)");

    i"Checking $(exampleFiles.length) standalone example file(s)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    const repoRoot = detectRepoRoot();

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

        const mode = detectStandaloneExampleMode(exampleFile);
        const action = standaloneExampleAction(mode);
        const verb = standaloneExampleVerb(mode);
        const progress = i"[$(i + 1)/$(exampleFiles.length)]".text;
        const header = formatExampleFileHeader(exampleFile, progress, action);
        auto result = executeStandaloneExampleFile(exampleFile, repoRoot, mode);

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
    return failures > 0 ? 1 : 0;
}

private ExecutionResult executeStandaloneExampleFile(
    string exampleFile,
    string repoRoot,
    StandaloneExampleMode mode,
)
{
    auto result = executeLogged(
        dubSingleFileCommand(standaloneExampleAction(mode), exampleFile, repoRoot),
        standaloneExampleAction(mode) ~ " " ~ exampleFile.baseName);
    auto cleaned = result.output.unstyle
        .lineSplitter
        .map!(l => l.stripRight)
        .join("\n");

    return ExecutionResult(
        success: result.status == 0,
        programOutput: cleaned,
        rawOutput: result.output,
    );
}

private int runDubTestsMode(bool failFast)
{
    const repoRoot = detectRepoRoot();
    if (repoRoot is null)
    {
        error(i"Could not detect repository root");
        return 1;
    }

    auto subPackages = parseSubPackages(repoRoot);
    if (subPackages.length == 0)
    {
        error(i"No sub-packages found in dub.sdl");
        return 1;
    }

    i"Testing $(subPackages.length) sub-package(s)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    int failures = 0;
    size_t processed = 0;
    FailureReplay failureReplay;
    bool stoppedEarly = false;

    foreach (i, pkg; subPackages)
    {
        const pkgName = pkg.baseName;
        const progress = i"[$(i + 1)/$(subPackages.length)]".text;
        const header = styledText(i"{dim $(progress)} {cyan $(pkgName)} {dim › dub test :$(pkgName)}");

        mkdirRecurse(buildPath(repoRoot, pkg, "build"));
        // Honour `$DC` so the sub-package tests use the CI matrix's compiler
        // (the dev shell provides both dmd and ldc). Example verification keeps
        // `ci`'s own embedded compiler; only the test suite is compiler-matrixed.
        auto testCmd = ["dub", "--root", repoRoot, "test", ":" ~ pkgName];
        const dc = environment.get("DC", "");
        if (dc.length)
            testCmd ~= "--compiler=" ~ dc;
        auto result = executeLogged(testCmd, "test " ~ pkgName);

        auto outputLines = result.output.lineSplitter
            .map!(l => l.to!string)
            .array;

        displayResultBox(outputLines, header, result.status == 0);

        if (result.status != 0)
        {
            failures++;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: outputLines.formatOutputLines(24).array,
                    footer: styledText(i"{red ✗ FAILED}"),
                );
                stoppedEarly = true;
                processed = i + 1;
                writeln();
                break;
            }
        }

        processed = i + 1;
        writeln();
    }

    displaySummary(stoppedEarly ? processed : subPackages.length, failures);
    if (stoppedEarly)
        displayFailureReplay(failureReplay);
    return failures > 0 ? 1 : 0;
}

// === Modes ===

/// Default mode: run examples and display output in boxes.
/// `results` holds the pre-computed execution result for each example.
int runDefaultMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
{
    i"Running $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

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
/// `results` holds the pre-computed execution result for each example.
int runVerifyMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
{
    i"Verifying $(examples.length) example(s) from $(mdFile)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

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

        if (verifyAgainst is null)
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

        if (matchesWithWildcards(actual, expected))
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
    return failures > 0 ? 1 : 0;
}

/// Update mode: rewrite the markdown file with actual output.
/// Processes examples in reverse order so line indices remain valid.
/// `results` holds the pre-computed execution result for each example.
int runUpdateMode(Example[] examples, ExecutionResult[] results, string mdFile, bool failFast)
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
        string fenceType = "[Output]";

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
    warning(i"{yellow Duplicate markdown reference URLs found:}");

    foreach (group; groups)
    {
        writeln();
        info(i"{cyan $(group.filePath)}:");
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

private string detectRepoRoot()
{
    const result = execute(["git", "rev-parse", "--show-toplevel"]);
    return result.status == 0
        ? result.output.strip
        : null;
}

private string[] dubSingleFileCommand(string action, string filePath, string repoRoot)
in (action == "run" || action == "build", "action must be dub run or dub build")
{
    // `--color=always` forces dub *and* the compiler to emit ANSI diagnostics
    // even though we run them as a captured subprocess (not a TTY). The colored
    // output flows through `rawOutput` into the failure boxes; `ci` itself
    // always renders styled output, so forcing color here keeps them in sync.
    // `--temp-build` is what makes concurrent example builds safe: it routes the
    // build through dub's lock-protected content-addressed cache
    // (`~/.dub/cache/<pkg>/<ver>/build/<hash>/`, guarded by `db.lock`) and emits
    // the final artifact into a per-invocation temp folder. Without it dub copies
    // each dependency's target into its package's *unlocked* in-place build dir
    // (`~/.dub/packages/expected/*/expected/libexpected.a`,
    // `libs/base/build/libsparkles_base.a`, …) on every build — so two builds
    // running at once race to remove/rewrite the same file ("No such file or
    // directory"). The cache reuses already-built deps, so this stays fast.
    auto command = ["dub", action, "--quiet", "--color=always", "--temp-build"];

    if (repoRoot !is null)
        command ~= ["--root", repoRoot];

    command ~= ["--single", filePath];
    return command;
}

private StandaloneExampleMode detectStandaloneExampleMode(string filePath)
{
    return parseStandaloneExampleMode(filePath.readText.lineSplitter.array);
}

@safe pure
private StandaloneExampleMode parseStandaloneExampleMode(const(char[])[] lines)
{
    enum metadataPrefixes = ["// ci:", "// run_md_examples:"];

    bool insideDubSdl = false;

    foreach (line; lines)
    {
        const stripped = line.strip;

        if (stripped.length == 0)
            continue;

        if (stripped.startsWith("#!"))
            continue;

        if (insideDubSdl)
        {
            if (stripped.startsWith("+/"))
                insideDubSdl = false;
            continue;
        }

        if (stripped.startsWith("/+ dub.sdl:"))
        {
            insideDubSdl = true;
            continue;
        }

        foreach (metadataPrefix; metadataPrefixes)
        {
            if (!stripped.startsWith(metadataPrefix))
                continue;

            const value = stripped[metadataPrefix.length .. $].strip.toLower;
            if (value == "build-only")
                return StandaloneExampleMode.buildOnly;
            if (value == "run")
                return StandaloneExampleMode.run;
            return StandaloneExampleMode.run;
        }

        if (!stripped.startsWith("//"))
            break;
    }

    return StandaloneExampleMode.run;
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
    return styledText(i"{dim $(progress)} {cyan $(example.name)} {dim › dub run --single $(example.name).d}");
}

private string formatExampleFileHeader(string exampleFile, string progress, string action)
{
    return styledText(i"{dim $(progress)} {cyan $(exampleFile.baseName)} {dim › dub $(action) --single $(exampleFile)}");
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
    warning(i"{red Fail-fast:} replaying first failing case");
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
