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
nix run .#ci -- [--verify|--update] [--fail-fast] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]
nix run .#ci -- --example-files [--fail-fast] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]
nix run .#ci -- --test [--fail-fast]
nix run .#ci -- --test-extracted [--fail-fast]
nix run .#ci -- [--dedup-reference-links|--fix-reference-links] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]
nix run .#ci -- --check-vcs-urls [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]
nix run .#ci -- --check-docs-sidebar
nix run .#ci -- --check-blob-paths [--clone-root DIR] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]
nix run .#ci -- [--log-level trace|info|warning|error]
---

Modes:

$(LIST
    $(ITEM Default — run examples and display results in boxes)
    $(ITEM `--verify` — compare output against expected output blocks, report mismatches)
    $(ITEM `--update` — rewrite the markdown file with actual example output (golden snapshot update))
    $(ITEM `--example-files` — build/run standalone example `.d` files, defaulting to `libs/base/examples/*.d`, `libs/build-primitives/examples/*.d`, `libs/core-cli/examples/*.d`, `docs/research/async-io/io-uring/examples/*.d`, `docs/research/async-io/gcd/examples/*.d`, `docs/research/units-of-measure/examples/*.d`, `docs/research/cpu-pmu/examples/*.d`, `docs/research/sanitizers/examples/*.d`, `docs/research/manim/examples/*.d`, `docs/research/anchored-overlays/examples/*.d`, `docs/research/property-tree/examples/*.d`, and the per-subject `examples/` directories under `docs/research/platform-ui-guidelines/`)
    $(ITEM `--test` — run `dub test` for each sub-package defined in the root `dub.sdl`)
    $(ITEM `--test-extracted` — run the test runner's `--better-c` and `--wasm` modes for each sub-package whose sources use the matching marker attribute, failing (rather than skipping) when a mode's toolchain is missing)
    $(ITEM `--include-files` (alias `--files`) — select explicit files or git-style globs; when omitted, each mode uses its tracked defaults)
    $(ITEM `--exclude-files` — drop matching files from the include set (or from the mode's defaults); same path/glob selectors as `--include-files`)
    $(ITEM `--fail-fast` — stop on the first failing example and replay its output at the end)
    $(ITEM `--dedup-reference-links` — report duplicate markdown reference definitions by URL)
    $(ITEM `--fix-reference-links` — rewrite duplicates to a canonical label)
    $(ITEM `--check-vcs-urls` — check tracked markdown files for github.com/raw.githubusercontent.com URLs, ensuring they reference a specific commit SHA)
    $(ITEM `--check-docs-sidebar` — verify the VitePress sidebar in `docs/.vitepress/sidebar.json` is consistent with published `docs/**/*.md` pages: every page is linked, and every sidebar link resolves to a page (respects `srcExclude`; home page is implicit))
    $(ITEM `--check-blob-paths` — verify every SHA-pinned GitHub blob citation names a path that exists at that commit, using local clones under `--clone-root` (default `$REPOS`). Complements `--check-vcs-urls`, which only checks the ref; a wrong path is a 404 no ref check can see. $(B Local only) — a citation whose repository is not cloned is reported as unchecked, never failed, so this is not wired into CI or a pre-commit hook)
)

The script looks for D code blocks starting with:
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
ANSI-stripped text. New blocks — including those `--update` inserts — use
`ansi`.

For examples with dynamic output (timestamps, file locations, etc.), place a
`<!-- md-example-expected -->` HTML comment directive between the code block
and the output block. The directive contains a wildcard pattern used for
`--verify` instead of the literal output block. Use `{{_}}` as a wildcard
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

module app;

// std.* modules
import std.algorithm : any, canFind, countUntil, filter, joiner, map, min, sort, startsWith;
import std.array : array, join, split;
import std.conv : text, to;
import core.time : Duration, msecs, seconds;
import std.file : exists, mkdirRecurse, readText, remove, tempDir, write;
import std.parallelism : TaskPool, totalCPUs;
import sparkles.base.hw_caps : hwParallelism;
import std.path : baseName, buildPath, globMatch;
import std.process : environment, execute;
import std.range : iota;
import std.regex : ctRegex, matchFirst;
import std.stdio : stderr, stdout, writeln;
import std.string : endsWith, indexOf, lineSplitter, replace, strip, stripRight, toLower;

// sparkles packages
import sparkles.core_cli.args : Argument, HelpInfo, Option, parseCli, reportCliError;
import sparkles.base.logger : error, info, initLogger, LogLevel, trace, warning;
import sparkles.core_cli.process_utils :
    ChildStdin, executeMonitored, MonitoredResult, ResourceUsage, selfRssBytes,
    timedOutStatus;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.styled_template : styledText, styledWritelnErr;
import sparkles.base.text.writers : writeDuration;
import sparkles.core_cli.term_unstyle : unstyle;
import sparkles.ui.components.box : BoxProps, drawBox, TitleOverflow;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;

// in-app modules
import blob_paths :
    BlobPathReport, BlobRef, BlobResult, BlobStatus,
    parseBlobRefs, resolveClone;
import docs_config : loadDocsConfig, loadSidebar, sidebarDataPath;
import docs_sidebar : checkDocsSidebar;
import dub_deps : parseSubPackages, rewriteInTreeDeps;
import coverage : collectCoverage, PackageCoverage;
import example_manifest : exampleRunsOnHost;
import fence_audit : AuditScope, FenceAuditOptions, runFenceAudit, wrapperFenceEnd;

// === UI sizing ===

/// Shared visible-column width for all UI chrome: `drawHeader` banners and the
/// `drawBox` `minWidth`/`maxWidth`. Keeping these in lockstep makes headers and
/// the boxes beneath them line up at a single, predictable width — capped at the
/// terminal so chrome never overflows a window narrower than 120 columns, and
/// defaulting to 120 when stdout is not a tty (piped output, CI).
private size_t uiWidth()
{
    import sparkles.base.term_caps : terminalSize;

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
    @(Option(`V|verify`, description: "Compare example output against expected output blocks in the markdown."))
    bool verify;

    @(Option(`u|update`, description: "Rewrite the markdown file with actual example output."))
    bool update;

    @(Option(`audit-fences`, description: "Classify every fenced code block in docs/ and README.md against the tree-sitter grammar bundle, and inventory the VitePress code-block features a highlighter swap must preserve."))
    bool auditFences;

    @(Option(`json`, description: "With --audit-fences: write the machine-readable report to this file."))
    string json;

    @(Option(`root`, description: "With --audit-fences: audit this worktree instead of the current one."))
    string root;

    @(Option(`audit-scope`, description: "With --audit-fences: which side of the config srcExclude split to census - site (default), all, or excluded."))
    string auditScope = "site";

    @(Option(`x|example-files`, description: "Run standalone example .d files instead of markdown examples. With no files, defaults to libs/base/examples/*.d, libs/build-primitives/examples/*.d, libs/core-cli/examples/*.d, docs/research/async-io/io-uring/examples/*.d, docs/research/async-io/gcd/examples/*.d, docs/research/units-of-measure/examples/*.d, docs/research/cpu-pmu/examples/*.d, docs/research/sanitizers/examples/*.d, docs/research/manim/examples/*.d, docs/research/anchored-overlays/examples/*.d, docs/research/property-tree/examples/*.d, and the per-subject examples directories under docs/research/platform-ui-guidelines/."))
    bool exampleFiles;

    @(Option(`t|test`, description: "Run dub test for each sub-package defined in the root dub.sdl."))
    bool test;

    @(Option(`test-extracted`, description: "Run the test runner's --better-c and --wasm modes for each sub-package that uses the matching marker attribute. Fails if a mode's toolchain is missing rather than skipping."))
    bool testExtracted;

    @(Option(`F|fail-fast`, description: "Stop on the first failing example and replay its output at the end."))
    bool failFast;

    // Canonical name last (same convention as short|long): `--files` is the
    // alias, `--include-files` is the primary name shown in synopsis/errors.
    @(Option(`files|include-files`,
        description: "File paths or git-style globs to include. Pass one or more "
            ~ "selectors immediately after the flag. Alias: --files. When omitted, "
            ~ "each mode uses its tracked defaults."))
    string[] files;

    @(Option(`exclude-files`,
        description: "File paths or git-style globs to exclude from the include set "
            ~ "(or from the mode's tracked defaults). Pass one or more selectors "
            ~ "immediately after the flag. May be repeated."))
    string[] exclude;

    /// The one mode that takes a positional: `--check-commit-scope <path>`.
    /// Everything else selects its inputs with `--include-files` / `--exclude-files`.
    @(Argument("arg", optional: true))
    string[] positionals;

    @(Option(`d|dedup-reference-links`, description: "Report duplicate markdown reference definitions that point to the same URL."))
    bool dedupReferenceLinks;

    @(Option(`f|fix-reference-links`, description: "Rewrite duplicate markdown references to one canonical label per URL."))
    bool fixReferenceLinks;

    @(Option(`L|log-level`, description: "Set the log level (trace, info, warning, error). Default: info."))
    LogLevel logLevel = LogLevel.info;

    @(Option(`check-commit-scope`, description: "Check a commit message for a detailed scope (used by pre-commit commit-msg hook). If no file is given or the argument is '-', reads the message from stdin instead of a file."))
    bool checkCommitScope;

    @(Option(`check-vcs-urls`, description: "Check tracked markdown files (or specified files) for github.com and raw.githubusercontent.com URLs, ensuring they reference a specific git commit."))
    bool checkVcsUrls;

    @(Option(`check-docs-sidebar`,
        description: "Verify the VitePress sidebar (docs/.vitepress/config.mts) is consistent "
        ~ "with published docs/**/*.md pages: every page is linked, and every "
        ~ "sidebar link resolves to a page. Respects srcExclude; the home page "
        ~ "(docs/index.md) is always considered linked."))
    bool checkDocsSidebar;

    @(Option(`check-blob-paths`,
        description: "Verify that every SHA-pinned GitHub blob citation names a path that "
        ~ "exists at that commit, using local clones under --clone-root. "
        ~ "Complements --check-vcs-urls, which only checks the ref. Local only: "
        ~ "a citation whose repository is not cloned is reported as unchecked, "
        ~ "never as a failure."))
    bool checkBlobPaths;

    @(Option(`clone-root`,
        description: "Root directory holding the upstream clones --check-blob-paths reads. "
        ~ "Defaults to the REPOS environment variable."))
    string cloneRoot;

    @(Option(`coverage`,
        description: "With --test, build each sub-package's tests under -cov and merge their "
        ~ "listings into build/coverage, then report covered/coverable lines per package, "
        ~ "worst first. On by default; pass --no-coverage for a plain test run. Reports "
        ~ "only; nothing fails on a low number."))
    bool coverage = true;

    @(Option(`C|ci-stats`,
        description: "Compute GitHub Actions CI job timing statistics and runner-type aggregates. "
        ~ "See docs/specs/ci/stats/ for the full specification."))
    bool ciStats;

    @(Option(`g|github-token`,
        description: "GitHub token for API access (Bearer auth). Falls back to $GITHUB_TOKEN."))
    string githubToken;

    @(Option(`r|repo`,
        description: "Target repository as owner/repo (e.g. PetarKirov/sparkles)."))
    string repo;

    @(Option(`l|limit`,
        description: "Maximum number of recent workflow runs to analyze (default 100)."))
    int limit = 100;

    @(Option(`S|since`,
        description: "Only include runs created on/after this date (YYYY-MM-DD or ISO)."))
    string since;

    @(Option(`w|workflow`,
        description: "Filter to runs/jobs matching this workflow name or path substring."))
    string workflow;

    @(Option(`c|conclusion`,
        description: "Only jobs with this conclusion (e.g. success, failure)."))
    string conclusion;

    @(Option(`b|branch`,
        description: "Only runs on this branch (head_branch, exact match)."))
    string branch;

    @(Option(`B|baseline`,
        description: "Compare --branch against this branch per job name, showing the median delta. "
        ~ "Both refs are taken from the same run window."))
    string baseline;

    @(Option(`s|split`,
        description: "Split the fetched jobs at this instant (YYYY-MM-DD or ISO-8601) and compare "
        ~ "the halves per job name. The axis to use when a workflow only triggers on "
        ~ "pull_request and so never runs on the default branch."))
    string split;

    @(Option(`steps`,
        description: "Break the slowest job names down by step, so a regression is attributed "
        ~ "to the step that owns it rather than to the job total."))
    bool steps;

    @(Option(`step-jobs`,
        description: "How many job names --steps expands (default 3)."))
    int stepJobs = 3;
}

enum ProgramMode
{
    runExamples,
    verifyExamples,
    updateExamples,
    runExampleFiles,
    runDubTests,
    runExtractedTests,
    checkReferenceLinks,
    fixReferenceLinks,
    checkCommitScope,
    checkVcsUrls,
    checkDocsSidebar,
    checkBlobPaths,
    ciStats,
    auditFences,
}

struct Example
{
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

int ciMain(string[] args)
{
    auto parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "ci",
            "Run repository CI helpers for markdown examples, standalone example files, and markdown reference maintenance",
        ),
    );
    if (!parsed)
        return reportCliError(parsed.error);
    auto cli = parsed.value;
    initLogger(cli.logLevel);

    const positionalArgs = cli.positionals.idup;
    const modeError = validateCliMode(cli, positionalArgs);
    if (modeError !is null)
    {
        error(i"$(modeError)");
        return 1;
    }

    const mode = resolveProgramMode(cli);

    if (mode == ProgramMode.checkCommitScope)
    {
        string source = (positionalArgs.length > 0) ? positionalArgs[0] : "-";
        return runCheckCommitScope(source);
    }

    if (mode == ProgramMode.checkDocsSidebar)
        return runCheckDocsSidebar();

    // The audit resolves its own corpus (docs/**/*.md + README.md, or --files),
    // so it must not fall through to the shared "no input files" usage error.
    if (mode == ProgramMode.auditFences)
        return runAuditFencesMode(cli);

    if (mode == ProgramMode.runDubTests)
        return runDubTestsMode(cli.failFast, cli.coverage);

    if (mode == ProgramMode.runExtractedTests)
        return runExtractedTestsMode(cli.failFast);

    if (mode == ProgramMode.ciStats)
        return runCiStatsMode(cli);


    auto inputFiles = collectInputFiles(cli, mode);

    if (inputFiles.length == 0)
    {
        if (cli.files.length > 0 || cli.exclude.length > 0)
        {
            error(i"--include-files / --exclude-files selection matched no supported input files for this mode");
            return 1;
        }

        if (isReferenceMode(mode))
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--dedup-reference-links|--fix-reference-links] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]");
        else if (mode == ProgramMode.runExampleFiles)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --example-files [--fail-fast] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]");
        else if (mode == ProgramMode.checkCommitScope)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --check-commit-scope [<commit-msg-file> | -]");
        else if (mode == ProgramMode.checkVcsUrls)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --check-vcs-urls [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]");
        else if (mode == ProgramMode.checkDocsSidebar)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --check-docs-sidebar");
        else if (mode == ProgramMode.checkBlobPaths)
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) --check-blob-paths [--clone-root DIR] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]");
        else
            styledWritelnErr(i"{bold Usage:} $(args[0].baseName) [--verify|--update] [--fail-fast] [--include-files GLOB|FILE...] [--exclude-files GLOB|FILE...]");
        return 1;
    }

    if (mode == ProgramMode.runExampleFiles)
        return runExampleFilesMode(inputFiles, cli.failFast);

    if (mode == ProgramMode.checkReferenceLinks)
        return runReferenceLinkMode(inputFiles, false);

    if (mode == ProgramMode.fixReferenceLinks)
        return runReferenceLinkMode(inputFiles, true);

    if (mode == ProgramMode.checkVcsUrls)
        return runCheckVcsUrls(inputFiles);

    if (mode == ProgramMode.checkBlobPaths)
        return runCheckBlobPaths(inputFiles, cli.cloneRoot);

    return runExamplesForFiles(inputFiles, mode, cli.failFast);
}

private string validateCliMode(
    in CliParams cli,
    in string[] positionalArgs,
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

    if (cli.testExtracted && (cli.verify || cli.update || cli.exampleFiles || cli.test
            || cli.dedupReferenceLinks || cli.fixReferenceLinks))
        return "--test-extracted cannot be combined with other modes";

    if (cli.checkCommitScope && (cli.verify || cli.update || cli.exampleFiles || cli.test || cli.dedupReferenceLinks || cli.fixReferenceLinks || cli.checkVcsUrls || cli.checkDocsSidebar || cli.checkBlobPaths || cli.ciStats))
        return "--check-commit-scope cannot be combined with other modes";

    if (cli.checkVcsUrls && (cli.verify || cli.update || cli.exampleFiles || cli.test || cli.dedupReferenceLinks || cli.fixReferenceLinks || cli.checkCommitScope || cli.checkDocsSidebar || cli.checkBlobPaths || cli.ciStats))
        return "--check-vcs-urls cannot be combined with other modes";

    if (cli.checkBlobPaths && (cli.verify || cli.update || cli.exampleFiles || cli.test || cli.dedupReferenceLinks || cli.fixReferenceLinks || cli.checkCommitScope || cli.checkVcsUrls || cli.checkDocsSidebar || cli.ciStats))
        return "--check-blob-paths cannot be combined with other modes";

    if (cli.checkDocsSidebar && (cli.verify || cli.update || cli.exampleFiles || cli.test || cli.dedupReferenceLinks || cli.fixReferenceLinks || cli.checkCommitScope || cli.checkVcsUrls || cli.checkBlobPaths || cli.ciStats))
        return "--check-docs-sidebar cannot be combined with other modes";

    if (cli.ciStats && (cli.verify || cli.update || cli.exampleFiles || cli.test
            || cli.dedupReferenceLinks || cli.fixReferenceLinks || cli.checkCommitScope || cli.checkVcsUrls || cli.checkDocsSidebar || cli.checkBlobPaths))
        return "--ci-stats cannot be combined with other modes";

    if (cli.ciStats && cli.limit <= 0)
        return "--limit must be a positive integer";

    // A baseline is one side of a two-population comparison; without
    // `--branch` there is nothing to compare it against.
    if (cli.ciStats && cli.baseline.length && cli.branch.length == 0)
        return "--baseline requires --branch (the candidate side of the comparison)";

    if (cli.ciStats && cli.stepJobs <= 0)
        return "--step-jobs must be a positive integer";

    // Reject a malformed pivot here rather than after a few hundred API calls.
    if (cli.ciStats && cli.split.length)
    {
        import ci_stats : parseSplitInstant;

        try
            cast(void) parseSplitInstant(cli.split);
        catch (Exception e)
            return "--split: " ~ e.msg;
    }

    if (cli.checkCommitScope && positionalArgs.length > 1)
        return "--check-commit-scope accepts at most one argument (a path or '-' for stdin)";

    if (positionalArgs.length > 0 && !cli.checkCommitScope)
        return "Positional file arguments are no longer supported; use --include-files (alias --files)";

    return null;
}

private ProgramMode resolveProgramMode(in CliParams cli)
{

    if (cli.auditFences)
        return ProgramMode.auditFences;

    if (cli.ciStats)
        return ProgramMode.ciStats;

    if (cli.exampleFiles)
        return ProgramMode.runExampleFiles;

    if (cli.testExtracted)
        return ProgramMode.runExtractedTests;

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

    if (cli.checkCommitScope)
        return ProgramMode.checkCommitScope;

    if (cli.checkVcsUrls)
        return ProgramMode.checkVcsUrls;

    if (cli.checkDocsSidebar)
        return ProgramMode.checkDocsSidebar;

    if (cli.checkBlobPaths)
        return ProgramMode.checkBlobPaths;

    return ProgramMode.runExamples;
}

private bool isReferenceMode(in ProgramMode mode)
{
    return mode == ProgramMode.checkReferenceLinks
        || mode == ProgramMode.fixReferenceLinks;
}

/// Runs the detailed commit scope check for a commit message file.
/// This is invoked by the pre-commit commit-msg hook.
/// Returns 0 on success (allow commit), 1 on failure (block).
/// Check the given commit message (file path or "-" / empty for stdin) for
/// detailed scope compliance. Returns 0 on success (allow), 1 on violation (block).
private int runCheckCommitScope(string msgSource)
{
    import std.file : readText;
    import std.process : execute;
    import std.regex : ctRegex, matchFirst;
    import std.stdio : stderr;
    import std.string : lineSplitter, strip, toLower;

    static immutable badScopes = [
        "wip", "todo", "tmp", "temp", "misc", "various", "update", "updates",
        "changes", "general", "stuff", "fixme", "foo", "bar", "baz", "xxx",
        "test", "tests",
    ];

    static immutable largeBareScopes = [
        "base", "core-cli", "core_cli", "versions", "build-primitives",
        "test-runner", "test-utils", "wired",
    ];

    string content;
    if (msgSource == "-" || msgSource.length == 0)
    {
        // Read from stdin (supports piping the commit message)
        import std.stdio : stdin;
        ubyte[] buf;
        foreach (chunk; stdin.byChunk(4096))
            buf ~= chunk;
        content = cast(string) buf;
    }
    else
    {
        try
        {
            content = readText(msgSource);
        }
        catch (Exception e)
        {
            stderr.writeln("✗ Failed to read commit message file: ", msgSource);
            return 1;
        }
    }

    string subject;
    foreach (rawLine; content.lineSplitter)
    {
        auto line = rawLine.strip;
        if (line.length == 0 || line.startsWith("#"))
            continue;
        subject = line;
        break;
    }

    if (subject.length == 0)
        return 0; // nothing to check

    // Match conventional type(scope)?: or type:
    static subjectRe = ctRegex!(`^([a-zA-Z0-9_-]+)(?:\(([^)]*)\))?:\s*`);
    auto m = subject.matchFirst(subjectRe);
    if (m.empty)
        return 0; // not a conventional subject we care about

    string scopeText = m.captures.length > 2 ? m.captures[2].strip : "";
    if (scopeText.length == 0)
        return 0; // no scope present — allowed

    // Check useless scopes
    auto lowered = scopeText.toLower;
    if (badScopes.canFind(lowered))
    {
        stderr.writeln("✗ Useless commit scope detected.\n");
        stderr.writeln("  Subject: ", subject);
        stderr.writeln;
        stderr.writeln("Use a descriptive scope that helps `git log` readers locate the change.\n");
        stderr.writeln("Preferred patterns (examples):");
        stderr.writeln("  docs(research/window-system-integration)");
        stderr.writeln("  fix(base.smallbuffer)");
        stderr.writeln("  feat(core-cli.ui.table)");
        stderr.writeln("  feat(core-cli/examples)");
        stderr.writeln("  feat(terminal)            # short is ok for small/cohesive packages");
        stderr.writeln("  config(lychee)");
        stderr.writeln;
        stderr.writeln("See docs/guidelines/AGENTS.md § \"Commit messages\".\n");
        stderr.writeln("Bypass (use sparingly): SKIP=detailed-scope git commit ...");
        stderr.writeln("or:                    git commit --no-verify");
        return 1;
    }

    // Heuristic for large bare package scopes
    if (largeBareScopes.canFind(scopeText))
    {
        auto diffRes = execute(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]);
        if (diffRes.status != 0)
            return 0; // can't compute suggestion, allow

        auto changed = diffRes.output
            .lineSplitter
            .filter!(l => l.length > 0)
            .array;

        string suggestion = computeDetailedScopeSuggestion(changed);
        if (suggestion.length > 0 && suggestion != scopeText)
        {
            stderr.writeln("✗ Scope could be more specific.\n");
            stderr.writeln("  You wrote: ", subject);
            stderr.writeln("  Staged changes suggest: ", suggestion);
            stderr.writeln;
            stderr.writeln("When a change is localized (one module, one research topic, one subdirectory),");
            stderr.writeln("prefer the detailed form. Bare package scopes are still acceptable for broad");
            stderr.writeln("or cross-cutting commits.\n");
            stderr.writeln("See docs/guidelines/AGENTS.md.\n");
            stderr.writeln("Bypass: SKIP=detailed-scope git commit ...   or   git commit --no-verify");
            return 1;
        }
    }

    return 0;
}

/// Given a list of staged paths (from git diff --cached --name-only), returns
/// a suggested more-detailed scope string (e.g. "base.smallbuffer" or
/// "docs(research/foo)") or empty if no good suggestion.
private string computeDetailedScopeSuggestion(string[] changed)
{
    import std.regex : ctRegex, matchFirst;
    import std.string : replace;

    static reResearch   = ctRegex!(`^docs/research/([^/]+)`);
    static reGuidelines = ctRegex!(`^docs/guidelines/([^/]+)`);
    static rePkgDeep    = ctRegex!(`^(libs|apps)/([^/]+)/.*/([^/.]+)\.(d|md)$`);
    static rePkgSrc     = ctRegex!(`^(libs|apps)/([^/]+)/src/.*/([^/.]+)\.d$`);
    static rePkgRoot    = ctRegex!(`^(libs|apps)/([^/]+)/([^/.]+)\.(d|md)$`);

    foreach (path; changed)
    {
        auto m = path.matchFirst(reResearch);
        if (!m.empty)
            return "docs(research/" ~ m.captures[1] ~ ")";

        m = path.matchFirst(reGuidelines);
        if (!m.empty)
            return "docs(guidelines/" ~ m.captures[1] ~ ")";

        m = path.matchFirst(rePkgDeep);
        if (!m.empty)
        {
            string pkg = m.captures[2].replace("-", "_");
            string child = m.captures[3];
            return pkg ~ "." ~ child;
        }

        m = path.matchFirst(rePkgSrc);
        if (!m.empty)
        {
            string pkg = m.captures[2].replace("-", "_");
            string child = m.captures[3];
            return pkg ~ "." ~ child;
        }

        m = path.matchFirst(rePkgRoot);
        if (!m.empty)
        {
            string pkg = m.captures[2].replace("-", "_");
            string child = m.captures[3];
            return pkg ~ "." ~ child;
        }
    }

    return "";
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
/// defaults `--example-files` uses when no `--include-files` selection is
/// given: the `base`, `build-primitives`, and `core-cli` library demos plus the
/// worked examples that accompany the research docs
/// (`docs/research/async-io/io-uring/`, `docs/research/async-io/gcd/`,
/// `docs/research/units-of-measure/`,
/// `docs/research/cpu-pmu/`, `docs/research/sanitizers/`, `docs/research/manim/`,
/// `docs/research/anchored-overlays/`, `docs/research/property-tree/`, and the four
/// per-subject `examples/`
/// directories under `docs/research/platform-ui-guidelines/`).
@safe pure nothrow
private string[] standaloneExampleGlobs()
{
    return [
        "libs/base/examples/*.d",
        "libs/build-primitives/examples/*.d",
        "libs/core-cli/examples/*.d",
        "libs/event-horizon/examples/*.d",
        "libs/http/examples/*.d",
        "docs/research/async-io/io-uring/examples/*.d",
        "docs/research/async-io/gcd/examples/*.d",
        "docs/research/units-of-measure/examples/*.d",
        "docs/research/cpu-pmu/examples/*.d",
        "docs/research/sanitizers/examples/*.d",
        "docs/research/manim/examples/*.d",
        "docs/research/anchored-overlays/examples/*.d",
        "docs/research/property-tree/examples/*.d",
        "docs/research/platform-ui-guidelines/color-derivation/examples/*.d",
        "docs/research/platform-ui-guidelines/gnome/examples/*.d",
        "docs/research/platform-ui-guidelines/kde/examples/*.d",
        "docs/research/platform-ui-guidelines/terminal/examples/*.d",
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

@safe pure nothrow @nogc
private bool isGlobSelector(string selector)
{
    return selector.canFind("*")
        || selector.canFind("?")
        || selector.canFind("[");
}

/// True when `path` should be dropped by a single `--exclude-files` selector.
///
/// Glob selectors use $(REF globMatch, std,path) (supports `**`). Non-glob
/// selectors match the path exactly, or any path under that directory
/// (`libs/foo` excludes `libs/foo` and `libs/foo/bar.md`).
@safe pure
private bool pathMatchesExclude(string path, string selector)
{
    if (path.length == 0 || selector.length == 0)
        return false;

    if (isGlobSelector(selector))
        return globMatch(path, selector);

    if (path == selector)
        return true;

    // Directory / prefix form: `libs/syntax/test/data` excludes the tree.
    const prefix = selector.endsWith("/") ? selector : selector ~ "/";
    return path.startsWith(prefix);
}

/// True when `path` matches any selector in `excludeSelectors`.
@safe pure
private bool isExcludedBy(string path, const(string)[] excludeSelectors)
{
    foreach (selector; excludeSelectors)
        if (pathMatchesExclude(path, selector))
            return true;
    return false;
}

@("ci.pathMatchesExclude.globAndPrefix")
@safe pure
unittest
{
    enum golden = "libs/syntax/test/data/md/goldens/code-tall.md";

    assert(pathMatchesExclude(golden, "libs/syntax/test/data/**"));
    assert(pathMatchesExclude(golden, "**/goldens/**"));
    assert(pathMatchesExclude(golden, "libs/syntax/test/data"));
    assert(pathMatchesExclude(golden, "libs/syntax/test/data/"));
    assert(pathMatchesExclude(golden, golden));
    assert(!pathMatchesExclude(golden, "libs/syntax/test/other/**"));
    assert(!pathMatchesExclude(golden, "libs/syntax/test/dat")); // not a path prefix
    assert(!pathMatchesExclude("README.md", "libs/syntax/test/data/**"));
    assert(!pathMatchesExclude("", "**"));
    assert(!pathMatchesExclude(golden, ""));
}

@("ci.isExcludedBy.anySelector")
@safe pure
unittest
{
    enum golden = "libs/syntax/test/data/md/goldens/code-tall.md";
    assert(isExcludedBy(golden, ["docs/**", "libs/syntax/test/data/**"]));
    assert(!isExcludedBy(golden, ["docs/**", "apps/**"]));
    assert(!isExcludedBy(golden, cast(string[])[]));
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

/// Runs the fence audit (`--audit-fences`). `--files` selectors override the
/// default `docs/**/*.md` + `README.md` set; globs resolve through
/// `git ls-files` in the current directory, so combine them with `--root` only
/// when the two agree.
private int runAuditFencesMode(in CliParams cli)
{
    string[] selected;
    foreach (selector; cli.files)
    {
        if (selector.length == 0)
            continue;

        if (isGlobSelector(selector))
            selected ~= trackedFilesMatching(selector);
        else
            selected ~= selector.idup;
    }

    // An unknown scope is a typo, not a reason to silently census the default
    // set and report numbers the caller did not ask for.
    AuditScope scope_;
    switch (cli.auditScope)
    {
        case "site":     scope_ = AuditScope.site;     break;
        case "all":      scope_ = AuditScope.all;      break;
        case "excluded": scope_ = AuditScope.excluded; break;
        default:
            error(i"unknown --audit-scope `$(cli.auditScope)`; expected site, all or excluded");
            return 1;
    }

    return runFenceAudit(FenceAuditOptions(
        root: cli.root,
        files: selected.filter!(path => path.endsWith(".md")).array,
        jsonPath: cli.json,
        auditScope: scope_,
    ));
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
        else if (mode == ProgramMode.checkVcsUrls)
            inputFiles = trackedMarkdownFiles();
        else if (mode == ProgramMode.checkBlobPaths)
            inputFiles = trackedMarkdownFiles();
    }

    const requiredSuffix = mode == ProgramMode.runExampleFiles ? ".d" : ".md";

    return inputFiles
        .filter!(path => path.length > 0)
        .filter!(path => path.endsWith(requiredSuffix))
        .filter!(path => !isExcludedBy(path, cli.exclude))
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
            case ProgramMode.runExtractedTests:
                rc = 1;
                break;
            case ProgramMode.checkReferenceLinks:
            case ProgramMode.fixReferenceLinks:
            case ProgramMode.checkCommitScope:
            case ProgramMode.checkVcsUrls:
            case ProgramMode.checkDocsSidebar:
            case ProgramMode.checkBlobPaths:
                rc = 1;
                break;
            case ProgramMode.ciStats:
            case ProgramMode.auditFences:
                rc = 1;   // handled earlier in main(); should never reach here
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

    // What this host will actually let us run in parallel: a CI container's
    // CPU quota is invisible to `totalCPUs`, and over-subscribing it just
    // adds context switches to an already build-bound job.
    uint jobs = hwParallelism();

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
private Duration exampleTimeout()
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
///
/// While the pool works, the main thread polls per-example status slots and
/// repaints a live progress frame (built N/M + the currently-building examples)
/// — the workers never touch the terminal, so the single-threaded `LiveRegion`
/// is safe by construction. On a non-tty the frame is skipped entirely and the
/// output is unchanged (the serial replay below remains the only output).
private ExecutionResult[] executeExamplesParallel(Example[] examples, string repoRoot)
{
    import core.atomic : atomicLoad, atomicStore;
    import core.thread : Thread;
    import std.parallelism : task;
    import std.range : take;
    import sparkles.base.term_caps : detectTermCaps;
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.meter : ProgressBar;
    import sparkles.ui.components.progress : spinnerFrame;
    import sparkles.ui.components.theme : makeTheme, Semantic;

    auto results = new ExecutionResult[](examples.length);

    if (examples.length <= 1)
    {
        if (examples.length == 1)
            results[0] = executeExample(examples[0], repoRoot, 0);
        return results;
    }

    const jobs = exampleJobCount();

    // Log the fan-out, because it is the single biggest lever on this mode's
    // runtime and was previously invisible. It also exposes a host whose
    // reported core count is not what the job may actually use: a CI runner
    // that applies a cgroup CPU limit still reports the *host's* cores here,
    // so the pool silently oversubscribes. `SPARKLES_CI_JOBS` is the override.
    info(i"{dim Examples:} $(examples.length){dim , parallel jobs:} $(jobs){dim , totalCPUs:} $(totalCPUs)");

    // The calling thread no longer participates in the work (it polls), so the
    // pool holds all `jobs` workers.
    auto pool = new TaskPool(jobs < 1 ? 1 : jobs);
    scope(exit) pool.finish(true);

    enum : size_t { statePending = 0, stateBuilding = 1, stateDone = 2 }
    auto states = new shared(size_t)[](examples.length);

    void runOne(size_t idx)
    {
        atomicStore(states[idx], stateBuilding);
        results[idx] = executeExample(examples[idx], repoRoot, idx);
        atomicStore(states[idx], stateDone);
    }

    foreach (i; 0 .. examples.length)
        pool.put(task(&runOne, i));

    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish(keepFrame: false); // the serial replay is the real output
    const theme = makeTheme(detectTermCaps());

    size_t spin;
    for (;;)
    {
        size_t completed;
        string[] buildingNames;
        foreach (i; 0 .. examples.length)
        {
            const s = atomicLoad(states[i]);
            if (s == stateDone)
                completed++;
            else if (s == stateBuilding)
                buildingNames ~= examples[i].name;
        }

        if (region.interactive)
        {
            SmallBuffer!(char, 128) bar;
            ProgressBar(done: completed, total: examples.length).toString(bar);
            string[] frame = ["building examples " ~ bar[].idup];
            enum size_t maxShown = 4;
            foreach (name; buildingNames.take(maxShown))
                frame ~= "  " ~ theme.paint(Semantic.accent, spinnerFrame(spin))
                    ~ " " ~ name;
            if (buildingNames.length > maxShown)
                frame ~= i"  … and $(buildingNames.length - maxShown) more".text;
            region.update(frame);
        }

        if (completed == examples.length)
            break;
        spin++;
        Thread.sleep(100.msecs);
    }

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

private int runCheckVcsUrls(string[] files)
{
    import std.file : readText;
    import std.regex : ctRegex, matchAll, matchFirst;
    import std.string : lineSplitter;
    import std.algorithm : canFind;

    // The github blob/tree path is optional: a directory link like
    // `github.com/o/r/tree/main` (a moving branch ref, no trailing file path)
    // must still be caught, so the ref group stands alone and `(?:/…)?` wraps
    // the path. Capture indices are unchanged (the wrapper is non-capturing).
    static urlRe = ctRegex!(`https?://(?:raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/([^#\s"'()\]]*)|(?:www\.)?github\.com/([^/]+)/([^/]+)/(blob|tree)/([^/#\s"'()\]]+)(?:/([^#\s"'()\]]*))?)`);
    static shaRe = ctRegex!(`^[0-9a-fA-F]{40}$`);

    int totalErrors = 0;

    foreach (filePath; files)
    {
        string content;
        try
        {
            content = readText(filePath);
        }
        catch (Exception e)
        {
            // A file we cannot read (e.g. invalid UTF-8) cannot be scanned for
            // unpinned URLs. Surface it and fail rather than silently passing —
            // a silent skip would defeat the guarantee this check exists for.
            stderr.writefln("✗ %s: could not read file to check URLs (%s)", filePath, e.msg);
            totalErrors++;
            continue;
        }

        size_t lineNum = 1;
        foreach (line; content.lineSplitter)
        {
            foreach (m; line.matchAll(urlRe))
            {
                string rText;
                if (m.captures[3].length > 0)
                    rText = m.captures[3].idup;
                else if (m.captures[8].length > 0)
                    rText = m.captures[8].idup;
                else
                    continue;

                // Allow placeholders or variables
                if (rText.canFind('$') || rText.canFind('%'))
                    continue;

                if (matchFirst(rText, shaRe).empty)
                {
                    stderr.writefln("✗ %s:%d: URL refers to branch/tag '%s' instead of a specific commit SHA:",
                        filePath, lineNum, rText);
                    stderr.writefln("  %s", m.hit);
                    stderr.writeln;
                    totalErrors++;
                }
            }
            lineNum++;
        }
    }

    if (totalErrors > 0)
    {
        stderr.writefln("Found %d non-conforming GitHub URL(s).", totalErrors);
        stderr.writeln("Please pin all code/file reference URLs to a specific 40-character commit SHA.");
        return 1;
    }

    info(i"{green ✓} All checked GitHub URLs refer to specific commit SHAs.");
    return 0;
}

/++
Index the clones under `root`: every directory containing a `.git` becomes a
lookup entry, keyed both by its own name and by `<parent>/<name>`.

Two keys because the `$REPOS` convention buckets by language or organisation
rather than by owner — `typescript/floating-ui` holds `floating-ui/floating-ui`,
while `typescript/radix-ui/primitives` holds `radix-ui/primitives`. The bare
name resolves the first shape and the qualified one disambiguates the second,
which is exactly the precedence `resolveClone` applies.

The walk stops at `maxDepth` and does not descend into a repository, so a
vendored submodule cannot shadow its parent.
+/
private string[string] indexClones(string root, int maxDepth = 3)
{
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : baseName, buildPath, dirName;

    string[string] index;

    void walk(string dir, int depth)
    {
        if (depth > maxDepth)
            return;
        foreach (entry; dirEntries(dir, SpanMode.shallow))
        {
            if (!entry.isDir)
                continue;
            if (buildPath(entry.name, ".git").exists)
            {
                const name = entry.name.baseName;
                const parent = entry.name.dirName.baseName;
                index[name] = entry.name;
                index[parent ~ "/" ~ name] = entry.name;
                continue; // a clone's contents are not more clones
            }
            walk(entry.name, depth + 1);
        }
    }

    try
        walk(root, 0);
    catch (Exception e)
        warning(i"Could not fully scan clone root $(root): $(e.msg)");

    return index;
}

/++
Ask one clone about many objects in a single `git` invocation.

`git cat-file --batch-check` reads revspecs on stdin and writes one line per
input, in order: `<oid> <type> <size>` when the object resolves, `<spec> missing`
when it does not. One spawn therefore answers a whole document's worth of
citations — the difference between a check that runs in seconds and one that
takes half an hour, since a per-citation `git` costs ~200 ms and a real docs
tree carries thousands.

Input is chunked because both pipes are drained sequentially: writing every
revspec before reading any output would deadlock once the replies outgrow the
pipe buffer. `chunk` keeps a batch's output far below it.

Returns one `bool` per input spec, in order.
+/
private bool[] batchObjectsExist(string cloneDir, in string[] specs, size_t chunk = 256)
{
    import std.algorithm : endsWith;
    import std.process : pipeProcess, Redirect, wait;
    import std.string : lineSplitter, strip;

    bool[] found;
    found.reserve(specs.length);

    for (size_t start = 0; start < specs.length; start += chunk)
    {
        const end = start + chunk < specs.length ? start + chunk : specs.length;
        auto slice = specs[start .. end];

        auto pipes = pipeProcess(
            ["git", "-C", cloneDir, "cat-file", "--batch-check"],
            Redirect.stdin | Redirect.stdout | Redirect.stderrToStdout);

        foreach (spec; slice)
            pipes.stdin.writeln(spec);
        pipes.stdin.flush();
        pipes.stdin.close();

        size_t seen;
        foreach (line; pipes.stdout.byLine)
        {
            // "<oid> <type> <size>" resolved; "<spec> missing" (or
            // "... ambiguous") did not.
            const text = line.idup.strip;
            if (text.length == 0)
                continue;
            found ~= !(text.endsWith(" missing") || text.endsWith(" ambiguous"));
            seen++;
        }
        wait(pipes.pid);

        // A short reply would silently shift every later verdict onto the wrong
        // citation, so pad rather than misattribute.
        while (seen++ < slice.length)
            found ~= false;
    }
    return found;
}

/++
Check that every SHA-pinned blob citation names a path present at that commit.

Complements `--check-vcs-urls`, which proves only that a citation carries a
commit SHA rather than a moving ref. See `blob_paths` for why this is a local
check and why an unclonable repository is reported rather than failed.
+/
private int runCheckBlobPaths(string[] files, string cloneRoot)
{
    import std.array : array;
    import std.algorithm : map, sort, uniq;
    import std.file : exists, isDir, readText;
    import std.process : environment;
    import std.stdio : stderr;

    const root = cloneRoot.length ? cloneRoot : environment.get("REPOS", "");
    if (root.length == 0)
    {
        stderr.writeln("✗ No clone root: pass --clone-root DIR or set REPOS.");
        stderr.writeln("  This check reads the upstream clones the citations were written from;");
        stderr.writeln("  without them there is nothing to verify against.");
        return 1;
    }
    if (!root.exists || !root.isDir)
    {
        stderr.writefln("✗ Clone root is not a directory: %s", root);
        return 1;
    }

    "Checking pinned blob citations"
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    const index = indexClones(root);
    info(i"Indexed $(index.length / 2) clone(s) under $(root)");

    BlobRef[] refs;
    foreach (filePath; files)
    {
        try
            refs ~= parseBlobRefs(filePath.readText, filePath);
        catch (Exception e)
        {
            // Unreadable input is a failure, not a skip: staying silent here
            // would report a clean run over a file nobody looked at.
            stderr.writefln("✗ %s: could not read file (%s)", filePath, e.msg);
            return 1;
        }
    }

    // Deduplicate to distinct (clone, sha, path) work, then group by
    // (clone, sha) so one `git` invocation answers a whole group.
    BlobPathReport report;
    BlobRef[][string] byClone; // clone dir -> its citations, deduplicated
    bool[string] seen;
    foreach (r; refs)
    {
        const dir = resolveClone(index, r);
        const key = (dir is null ? r.slug : dir) ~ "\0" ~ r.revSpec;
        if (key in seen)
            continue;
        seen[key] = true;

        if (dir is null)
            report.unchecked ~= BlobResult(r, BlobStatus.noClone);
        else
            byClone[dir] ~= r;
    }
    report.uniqueCount = seen.length;

    foreach (dir, group; byClone)
    {
        // Ask about each distinct commit alongside the paths, so a shallow or
        // stale clone is reported as unchecked rather than accused of carrying
        // a broken citation.
        bool[string] commitKnown;
        string[] commitSpecs;
        foreach (r; group)
            if (r.sha !in commitKnown)
            {
                commitKnown[r.sha] = false;
                commitSpecs ~= r.sha ~ "^{commit}";
            }
        auto commitFound = batchObjectsExist(dir, commitSpecs);
        foreach (i, spec; commitSpecs)
            commitKnown[spec[0 .. 40]] = i < commitFound.length && commitFound[i];

        auto resolvable = group.filter!(r => commitKnown[r.sha]).array;
        foreach (r; group)
            if (!commitKnown[r.sha])
                report.unchecked ~= BlobResult(r, BlobStatus.noRevision, dir);

        auto pathFound = batchObjectsExist(dir, resolvable.map!(r => r.revSpec).array);
        foreach (i, r; resolvable)
        {
            if (i < pathFound.length && pathFound[i])
                report.okCount++;
            else
                report.failures ~= BlobResult(r, BlobStatus.missingPath, dir);
        }
    }

    info(i"$(refs.length) citation(s), $(report.uniqueCount) distinct (repo, sha, path) triple(s)");

    if (report.unchecked.length != 0)
    {
        auto missingRepos = report.unchecked
            .map!(u => u.status == BlobStatus.noRevision
                ? u.ref_.slug ~ " (revision not in clone)"
                : u.ref_.slug)
            .array
            .sort
            .uniq
            .array;
        // Header and list share one stream: `warning` goes to stderr, so a
        // stdout list would detach from its heading whenever the two are
        // redirected separately.
        warning(i"$(report.unchecked.length) citation(s) unverified — no local clone at that revision:");
        foreach (name; missingRepos)
            stderr.writefln("  %s", name);
        stderr.writeln;
    }

    if (!report.ok)
    {
        stderr.writefln("✗ %d citation(s) name a path that does not exist at the pinned commit:",
            report.failures.length);
        stderr.writeln;
        foreach (f; report.failures)
        {
            stderr.writefln("  %s:%d", f.ref_.file, f.ref_.line);
            stderr.writefln("    %s", f.ref_.url);
            stderr.writefln("    %s is not at %s in %s",
                f.ref_.path, f.ref_.sha[0 .. 12], f.cloneDir);
            stderr.writeln;
        }
        stderr.writeln("These 404 upstream. --check-vcs-urls cannot catch them: it "
            ~ "verifies the ref, not the path.");
        return 1;
    }

    info(i"{green ✓} All $(report.okCount) verifiable blob citation(s) resolve at their pinned commit.");
    return 0;
}

/// Verify the VitePress sidebar is consistent with published docs pages
/// (pages → sidebar and sidebar → pages). Invoked by the pre-commit
/// `check-docs-sidebar` hook. Returns 0 when both directions are clean, 1
/// when pages are missing from the sidebar or sidebar links are dangling.
private int runCheckDocsSidebar()
{
    import std.stdio : stderr;

    const repoRoot = detectRepoRoot();

    // The sidebar tree and srcExclude list are data files `config.mts` imports;
    // see docs_config. A malformed or missing file is a hard error — never an
    // empty link set that would flag every page as unlinked.
    auto sidebar = loadSidebar(repoRoot);
    if (sidebar.hasError)
    {
        error(i"Could not read the docs sidebar: $(sidebar.error)");
        return 1;
    }

    auto docsConfig = loadDocsConfig(repoRoot);
    if (docsConfig.hasError)
    {
        error(i"Could not read the docs config: $(docsConfig.error)");
        return 1;
    }

    // Tracked docs markdown only (excludes untracked WIP and docs/public assets).
    const result = execute(["git", "-C", repoRoot, "ls-files", "--", "docs"]);
    if (result.status != 0)
    {
        error(i"Failed to enumerate docs files with git ls-files");
        return 1;
    }

    auto mdFiles = result.output
        .lineSplitter
        .filter!(line => line.length != 0)
        .filter!(line => line.endsWith(".md"))
        .map!(line => line.idup)
        .array;

    const report = checkDocsSidebar(sidebar.value, docsConfig.value.srcExclude, mdFiles);
    if (report.ok)
    {
        info(i"{green ✓} Docs sidebar is consistent: every published page is linked, and every sidebar link resolves ($(mdFiles.length) markdown files checked).");
        return 0;
    }

    if (report.unlinkedPages.length != 0)
    {
        stderr.writefln(
            "✗ %d docs page(s) are not linked from the VitePress sidebar in %s:",
            report.unlinkedPages.length,
            sidebarDataPath,
        );
        stderr.writeln;
        foreach (path; report.unlinkedPages)
            stderr.writefln("  %s", path);
        stderr.writeln;
        stderr.writeln(
            "Add each page to the sidebar tree (or exclude it via srcExclude in "
            ~ "docs/.vitepress/docs-config.json if it must not be published). The "
            ~ "home page docs/index.md is always considered linked.",
        );
        if (report.danglingLinks.length != 0)
            stderr.writeln;
    }

    if (report.danglingLinks.length != 0)
    {
        stderr.writefln(
            "✗ %d sidebar link(s) in %s do not resolve to a published docs page:",
            report.danglingLinks.length,
            sidebarDataPath,
        );
        stderr.writeln;
        foreach (link; report.danglingLinks)
            stderr.writefln("  %s", link);
        stderr.writeln;
        stderr.writeln(
            "Point each link at an existing docs/**/*.md page (or remove the "
            ~ "entry). Links that only match an srcExclude-d path are treated "
            ~ "as dangling.",
        );
    }

    return 1;
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
    auto result = executeLogged(cmd, "run " ~ example.name, exampleTimeout());

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
instrumentation for troubleshooting OOM during a build. At coarser levels it
samples on a lazy interval instead, which costs a `tryWait` poll and nothing
else.

Children always get `ChildStdin.empty`. Examples are batch work and must never
go interactive, but several probe `isatty(0)` to decide — and runners disagree
about it: a CircleCI `run` step allocates a TTY where a GitHub Actions step
does not. `README.md`'s `readme_prompts` example is the live case; inheriting a
terminal made it render a select prompt and then fail on the EOF that followed.
An empty stdin makes the answer `false` everywhere, including on a developer's
terminal.
*/
/// Fold the timeout into the captured output, so the reason travels with the
/// result to every renderer. A wedged child produces no output at all, so
/// without this its failure box is simply empty.
private MonitoredResult noteIfTimedOut(MonitoredResult result, Duration timeout)
{
    if (!result.timedOut)
        return result;

    SmallBuffer!(char, 32) budget;
    writeDuration(budget, timeout);
    result.output ~= i"\n[ci] no output — killed after $(budget[]) (timeout)\n".text;
    return result;
}

private MonitoredResult executeLogged(
    const(string)[] args, string label, Duration timeout = Duration.zero,
    const string[string] env = null)
{
    import std.array : join;
    import std.logger : globalLogLevel;
    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.base.text.writers : writeBytes, writeDuration;

    if (globalLogLevel > LogLevel.trace)
        return noteIfTimedOut(
            executeMonitored(args, 5.seconds, null, ChildStdin.empty, timeout, env),
            timeout);

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
    }, ChildStdin.empty, timeout, env);

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

    return noteIfTimedOut(res, timeout);
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

        auto spec = detectStandaloneExampleSpec(exampleFile);
        const action = standaloneExampleAction(spec.mode);
        const verb = standaloneExampleVerb(spec.mode);
        const progress = i"[$(i + 1)/$(exampleFiles.length)]".text;
        const header = formatExampleFileHeader(exampleFile, progress, action, spec.runArgs);
        auto result = executeStandaloneExampleFile(exampleFile, repoRoot, spec);

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
    StandaloneExampleSpec spec,
)
{
    const action = standaloneExampleAction(spec.mode);
    // A `build-only` example is never executed, so its directive's arguments —
    // if it somehow carries any — have nowhere to go.
    auto runArgs = spec.mode == StandaloneExampleMode.run ? spec.runArgs : null;
    auto result = executeLogged(
        dubSingleFileCommand(action, exampleFile, repoRoot, runArgs),
        action ~ " " ~ exampleFile.baseName,
        exampleTimeout());
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

/// One package's test outcome, and whether coverage came with it.
private struct PackageRun
{
    int status;
    string output;
    bool coverageCollected;
}

/**
Runs one package's tests, retrying without coverage if that is what broke.

`-cov` changes how a package links, and some cannot take it: under DMD the
`sparkles:dmd-lsp` family fails to resolve `dmd.backend.*` in a coverage build
while linking and passing perfectly without one. That is a build incompatibility,
not a failing test, and `--test`'s job is to report whether the tests pass — so a
package that only fails *with* coverage is run again without it and reported on
its own merits, with its absence from the table noted rather than hidden.

Params:
    baseCmd = the `dub test` invocation, without coverage arguments
    cov = the run's coverage settings
    exec = runs a command with an environment and reports status plus output

Returns: the outcome, with `coverageCollected` false when the fallback was used.
*/
private PackageRun runPackageTests(const(string)[] baseCmd, in CoverageRun cov,
    scope PackageRun delegate(const(string)[] cmd, const string[string] env) exec)
{
    if (!cov.enabled)
        return exec(baseCmd, null);

    auto result = exec(baseCmd ~ cov.dubArgs ~ cov.runtimeArgs, cov.env);
    if (result.status == 0)
    {
        result.coverageCollected = true;
        return result;
    }

    auto plain = exec(baseCmd, null);
    plain.coverageCollected = false;
    // Only the coverage build was at fault if the plain one passes; otherwise
    // report the original failure, which is the one the reader needs to see.
    return plain.status == 0 ? plain : result;
}

/**
How a test run collects coverage, or that it does not.

`-cov` is not free — every counted line becomes an atomic increment — so this
is one value threaded through both test paths rather than a flag each of them
re-interprets.

The listings all land in **one** directory and are merged (`merge:1`), which is
what makes them usable afterwards. A run scoped to a single package also emits
listings for every module it compiled, and those read `0% covered` because that
package's tests never exercised them; merging every package's run into one set
replaces those zeroes with the coverage some other package's tests did provide.
`hue --cov` then has a single directory holding one truthful answer per file.
*/
private struct CoverageRun
{
    bool enabled;
    string dir;       /// merged destination, `build/coverage`
    string dflags;    /// extra `$DFLAGS` for the child, empty when none apply

    /// The `dub test` arguments that turn coverage on.
    string[] dubArgs() const @safe pure nothrow
        => enabled ? ["-b", "unittest-cov"] : null;

    /// The runtime arguments, after `--`.
    string[] runtimeArgs() const @safe pure nothrow
        => enabled ? ["--", "--DRT-covopt=merge:1 dstpath:" ~ dir] : null;

    /// The environment additions for the child.
    const(string[string]) env() const @safe pure nothrow
        => enabled && dflags.length ? ["DFLAGS": dflags] : null;
}

/**
Prepares `build/coverage` for a run, clearing whatever a previous one left.

Clearing is not optional: `merge:1` accumulates, so a second `ci --test` over a
stale directory would report hit counts summed across both runs. Percentages
would survive that, but the per-line counts a viewer shows would not.

Params:
    repoRoot = the repository root
    wanted = whether the caller asked for coverage at all
    subPackages = used only to pick a package to resolve the compiler against

Returns: the descriptor; `enabled` is false when `wanted` is false.
*/
private CoverageRun prepareCoverage(string repoRoot, bool wanted, in string[] subPackages)
{
    import std.file : rmdirRecurse;

    if (!wanted)
        return CoverageRun.init;

    CoverageRun run = {enabled: true, dir: buildPath(repoRoot, "build", "coverage")};
    if (run.dir.exists)
        run.dir.rmdirRecurse;
    run.dir.mkdirRecurse;   // `dstpath` must exist; druntime will not create it

    // LDC's `--cov-increment` picks how a counter is bumped, and `boolean`
    // stores a 1 instead of counting — so every covered line reports `1` and a
    // viewer's hit-count badge becomes noise. `atomic` is already LDC's
    // default; passing it pins the contract against an inherited `$DFLAGS` or
    // a future default, and it is the mode whose counts are true under the
    // parallel test runner. DMD has no equivalent switch and rejects this one,
    // hence the compiler check.
    if (resolvedCompiler(repoRoot, subPackages) == "ldc")
        run.dflags = "--cov-increment=atomic";
    return run;
}

/**
The compiler dub will actually use, as dub itself reports it (`"ldc"`, `"dmd"`,
`"gdc"`), or empty when that cannot be determined.

Asked rather than guessed. `$DC` decides it when set, but otherwise the choice
falls out of `$PATH` order — the dev shell resolves to `ldc2` while the Nix-built
`ci` closure resolves to `dmd` — so neither the environment nor a hardcoded
default answers this. `dub describe` reports the resolved compiler and honours
the same `--compiler=` this run passes, which makes it the one source that
cannot disagree with the build.
*/
private string resolvedCompiler(string repoRoot, in string[] subPackages)
{
    import std.json : JSONException, parseJSON;
    import sparkles.core_cli.process_utils : runCaptured;

    if (subPackages.length == 0)
        return null;

    auto cmd = ["dub", "describe", "--root", repoRoot, ":" ~ subPackages[0].baseName];
    const dc = environment.get("DC", "");
    if (dc.length)
        cmd ~= "--compiler=" ~ dc;

    const result = runCaptured(cmd);
    if (!result.succeeded)
        return null;
    try
    {
        auto doc = parseJSON(result.stdout);
        if (const c = "compiler" in doc.object)
            return c.str;
    }
    catch (JSONException)
    {
        // A describe that does not parse is not worth failing a test run over;
        // the flag it would have decided is a no-op on LDC's default anyway.
    }
    return null;
}

private int runDubTestsMode(bool failFast, bool coverage)
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

    const cov = prepareCoverage(repoRoot, coverage, subPackages);

    i"Testing $(subPackages.length) sub-package(s)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    // On a tty a live checklist (with the running package's dub output in a
    // bounded tail pane) replaces the per-package result boxes; piped output
    // keeps today's box-per-package log byte-stable for CI.
    {
        import sparkles.base.term_caps : isTerminal;

        if (isTerminal())
            return runDubTestsChecklist(repoRoot, subPackages, failFast, cov);
    }

    int failures = 0;
    size_t processed = 0;
    string[] failedPackages, uncovered;
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
        auto result = runPackageTests(testCmd, cov,
            (const(string)[] cmd, const string[string] env)
            {
                auto r = executeLogged(cmd, "test " ~ pkgName, Duration.zero, env);
                return PackageRun(r.status, r.output);
            });
        if (cov.enabled && !result.coverageCollected && result.status == 0)
            uncovered ~= pkgName;

        auto outputLines = result.output.lineSplitter
            .map!(l => l.to!string)
            .array;

        displayResultBox(outputLines, header, result.status == 0);

        if (result.status != 0)
        {
            failures++;
            failedPackages ~= pkgName;
            if (failFast)
            {
                failureReplay = FailureReplay(
                    header: header,
                    outputLines: outputLines.formatOutputLines(24, keepTail: true).array,
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
    reportCoverage(subPackages, cov, failedPackages, uncovered);
    if (stoppedEarly)
        displayFailureReplay(failureReplay);
    return failures > 0 ? 1 : 0;
}

/**
Reports line coverage from the listings a `--test` run merged into `cov.dir`.

Reports only. There is no threshold and nothing fails on a low number: D's
`-cov` counts template instantiations per instantiation and emits listings for
imported modules too, so the figure is a trend indicator rather than a contract.
Gating on it would buy noise.

A package's row counts only files beneath its own directory
($(REF ownedBy, coverage)), because the merged set describes the whole
repository — every module any package compiled. What merging changes is the
*number*: a file now carries the coverage every package's tests gave it, not
just its own package's, which is both the more useful figure and the one a
viewer shows.

Params:
    subPackages = repository-relative sub-package directories
    cov = the run that produced the listings
    failedPackages = packages whose tests did not pass, whose rows cannot be read
        as coverage
*/
private void reportCoverage(in string[] subPackages, in CoverageRun cov,
    in string[] failedPackages, in string[] uncovered)
{
    import std.algorithm : sort;
    import std.format : format;
    import sparkles.ui.components.table : drawTable, TableProps;

    if (!cov.enabled || !cov.dir.exists)
        return;

    PackageCoverage[] results;
    foreach (pkg; subPackages)
        results ~= collectCoverage(cov.dir, pkg.baseName, pkg);
    results.sort!((a, b) => a.percent < b.percent);

    string[][] rows = [["package", "files", "covered", "coverable", "%"]];
    size_t totalCovered, totalCoverable;
    foreach (r; results)
    {
        totalCovered += r.covered;
        totalCoverable += r.coverable;
        rows ~= [
            r.name,
            r.files.length.to!string,
            r.covered.to!string,
            r.coverable.to!string,
            r.coverable == 0 ? "—" : format("%.1f", r.percent),
        ];
    }
    const total = totalCoverable == 0 ? 100.0 : (100.0 * totalCovered) / totalCoverable;
    rows ~= [
        "TOTAL", "", totalCovered.to!string, totalCoverable.to!string, format("%.1f", total),
    ];

    writeln();
    drawTable(rows, TableProps(headerRows: 1)).writeln;
    styledText(i"{dim listings in} $(cov.dir) {dim — open one with} hue --cov").writeln;

    // The notes below go to stderr, which is unbuffered; without this the
    // first one lands in the middle of the table stdout has not flushed yet.
    stdout.flush();

    // A package whose tests did not run has no coverage to report, and a zero
    // that means "did not build" must not read as a zero that means "untested".
    if (failedPackages.length)
        warning(i"{yellow tests failed} for $(failedPackages.length) package(s): $(failedPackages.join(", ")) — their rows are not meaningful");

    // A package that only builds without `-cov` is tested but unmeasured, and
    // a row of zeroes would read as untested rather than as unmeasured.
    if (uncovered.length)
        warning(i"{yellow no coverage} for $(uncovered.length) package(s): $(uncovered.join(", ")) — they do not link under -cov, and were tested without it");
}

/// Which of the test runner's extracted-test modes a sub-package opts into.
struct ExtractedModes
{
    bool betterC; /// has at least one `@betterC` test
    bool wasm;    /// has at least one `@wasm` test

    bool any() const @safe pure nothrow @nogc => betterC || wasm;
}

/// The extracted-test modes a D source file opts into.
///
/// A deliberately shallow text scan, not a parse: the marker attributes are
/// written literally at their use sites, so this has no false negatives —
/// which is the direction that matters, since a missed module means a mode
/// silently goes unexercised. False positives (the attribute named in a doc
/// comment, as the runner's own modules do) merely run a mode that then
/// reports "no tests found" and exits 0, so they cost a little time and
/// nothing else.
ExtractedModes extractedModesInSource(scope const(char)[] source) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    return ExtractedModes(
        betterC: source.canFind("@betterC"),
        wasm: source.canFind("@wasm"),
    );
}

@("ci.extractedModesInSource")
@safe pure nothrow
unittest
{
    assert(extractedModesInSource("@betterC @safe unittest {}") == ExtractedModes(betterC: true));
    assert(extractedModesInSource("@wasm @safe unittest {}") == ExtractedModes(wasm: true));
    // The value form of the attribute is found the same way.
    assert(extractedModesInSource("@betterC(selfContained: true)")
        == ExtractedModes(betterC: true));
    assert(extractedModesInSource("@wasm(selfContained: true) @betterC")
        == ExtractedModes(betterC: true, wasm: true));

    auto none = extractedModesInSource("@safe @nogc unittest {}");
    assert(!none.any);
    assert(!extractedModesInSource("").any);
}

/// Whether a sub-package's `dub.sdl` wires in `sparkles:test-runner`, by
/// either recipe: a `dependency "sparkles:test-runner"` (the common path) or
/// the cycle-safe `sourcePaths "../test-runner/src" …` source-include used by
/// `base`, `core-cli`, and `test-utils`.
///
/// This gate is what keeps `--test-extracted` honest. Without the runner,
/// `dub test :pkg -- --better-c` reaches druntime's default tester, which
/// ignores the flag, runs the ordinary unittests and exits 0 — a green that
/// means nothing. Better to leave such a package out than to report success
/// for a mode that never ran.
bool integratesTestRunner(scope const(char)[] dubConfig) @safe pure nothrow
{
    import std.algorithm.searching : canFind;

    return dubConfig.canFind("test-runner");
}

@("ci.integratesTestRunner")
@safe pure nothrow
unittest
{
    assert(integratesTestRunner(`    dependency "sparkles:test-runner" path="../.."`));
    assert(integratesTestRunner(`    sourcePaths "../test-runner/src" "../test-runner-impl/src"`));
    assert(!integratesTestRunner(`dependency "sparkles:base" path="../.."`));
    assert(!integratesTestRunner(""));
}

/// The modes any `.d` file under `packagePath` opts into — empty for a
/// package that does not integrate the runner (see $(LREF integratesTestRunner)).
private ExtractedModes extractedModesOf(string repoRoot, string packagePath)
{
    import std.file : dirEntries, readText, SpanMode;
    import std.path : buildPath, extension;

    const root = buildPath(repoRoot, packagePath);
    ExtractedModes modes;
    if (!root.exists)
        return modes;

    const dubConfig = buildPath(root, "dub.sdl");
    if (!dubConfig.exists || !integratesTestRunner(dubConfig.readText))
        return modes;
    foreach (entry; dirEntries(root, SpanMode.depth))
    {
        if (!entry.isFile || entry.name.extension != ".d")
            continue;
        const found = extractedModesInSource(entry.name.readText);
        modes.betterC |= found.betterC;
        modes.wasm |= found.wasm;
        if (modes.betterC && modes.wasm)
            break; // nothing left to learn
    }
    return modes;
}

/// `--test-extracted`: run the test runner's `--better-c` and `--wasm` modes
/// for every sub-package whose sources use the matching marker attribute.
///
/// These modes are not covered by `--test`: a `@betterC` test runs as an
/// ordinary unittest there, and only `--better-c` additionally extracts it,
/// compiles it without druntime, and runs the result — so a break in the
/// extraction, the `-betterC` codegen, or the wasm cross-compile is invisible
/// to `dub test`.
///
/// `--require-toolchain` is what makes this job meaningful: both modes
/// normally $(I skip) when their toolchain is missing (no D compiler, no
/// wasm-ld, no wasm runtime), which is right for a contributor's machine and
/// exactly wrong here — without it a missing linker would leave this reporting
/// success having run nothing.
private int runExtractedTestsMode(bool failFast)
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

    struct Job
    {
        string packagePath; /// repo-relative, e.g. `libs/base`
        string packageName;
        string flag; /// `--better-c` or `--wasm`
    }

    Job[] jobs;
    foreach (pkg; subPackages)
    {
        const modes = extractedModesOf(repoRoot, pkg);
        if (modes.betterC)
            jobs ~= Job(pkg, pkg.baseName, "--better-c");
        if (modes.wasm)
            jobs ~= Job(pkg, pkg.baseName, "--wasm");
    }

    if (jobs.length == 0)
    {
        // Not a pass: the repo is supposed to have such tests, so an empty
        // sweep means the scan (or the attributes) regressed.
        error(i"No sub-package uses @betterC or @wasm — nothing to run");
        return 1;
    }

    i"Running $(jobs.length) extracted-test mode(s)".text
        .drawHeader(HeaderProps(style: HeaderStyle.banner, width: uiWidth()))
        .writeln("\n");

    int failures = 0;
    size_t processed = 0;
    foreach (i, job; jobs)
    {
        const progress = i"[$(i + 1)/$(jobs.length)]".text;
        const header = styledText(
            i"{dim $(progress)} {cyan $(job.packageName)} {dim › dub test :$(job.packageName) -- $(job.flag)}");

        mkdirRecurse(buildPath(repoRoot, job.packagePath, "build"));
        auto cmd = ["dub", "--root", repoRoot, "test", ":" ~ job.packageName];
        const dc = environment.get("DC", "");
        if (dc.length)
            cmd ~= "--compiler=" ~ dc;
        // `--self-test` also covers the runner's own extracted tests, which are
        // the ones exercising the `selfContained` opt-out.
        cmd ~= ["--", job.flag, "--self-test", "--require-toolchain"];

        auto result = executeLogged(cmd, job.flag ~ " " ~ job.packageName);
        auto outputLines = result.output.lineSplitter.map!(l => l.to!string).array;
        displayResultBox(outputLines, header, result.status == 0);

        processed = i + 1;
        if (result.status != 0)
        {
            failures++;
            if (failFast)
            {
                writeln();
                break;
            }
        }
        writeln();
    }

    // After a fail-fast break the untried jobs never ran, so report what was
    // actually attempted rather than the full list.
    displaySummary(processed, failures);
    return failures > 0 ? 1 : 0;
}

/// The tty variant of `--test`: one checklist row per sub-package, the running
/// package's dub output streaming through the bounded tail pane, failures
/// graduating with their output tail, and fail-fast marking the rest skipped.
private int runDubTestsChecklist(string repoRoot, string[] subPackages, bool failFast,
    in CoverageRun cov)
{
    import sparkles.core_cli.process_utils : runStreaming;
    import sparkles.base.term_caps : detectTermCaps;
    import sparkles.ui.components.live : stdoutLiveRegion;
    import sparkles.ui.components.tasklist : TaskReporter;
    import sparkles.ui.components.theme : makeTheme;

    static string lastLines(string s, size_t n)
    {
        auto lines = s.lineSplitter.map!(l => l.to!string).array;
        return (lines.length <= n ? lines : lines[$ - n .. $]).join("\n");
    }

    const theme = makeTheme(detectTermCaps());
    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish();
    auto tasks = TaskReporter(&region, theme);

    size_t[] ids;
    foreach (pkg; subPackages)
        ids ~= tasks.add("dub test :" ~ pkg.baseName);

    int failures = 0;
    size_t processed = 0;
    string[] failed, uncovered;
    foreach (i, pkg; subPackages)
    {
        const pkgName = pkg.baseName;
        mkdirRecurse(buildPath(repoRoot, pkg, "build"));
        auto testCmd = ["dub", "--root", repoRoot, "test", ":" ~ pkgName];
        const dc = environment.get("DC", "");
        if (dc.length)
            testCmd ~= "--compiler=" ~ dc;
        tasks.start(ids[i]);
        auto result = runPackageTests(testCmd, cov,
            (const(string)[] cmd, const string[string] env)
            {
                auto r = runStreaming(cmd,
                    (scope const(char)[] line) { tasks.output(ids[i], line); },
                    null, env);
                return PackageRun(r.status, r.stdout);
            });
        if (cov.enabled && !result.coverageCollected && result.status == 0)
            uncovered ~= pkgName;
        processed = i + 1;

        if (result.status == 0)
        {
            tasks.succeed(ids[i]);
            continue;
        }
        failures++;
        failed ~= pkgName;
        tasks.fail(ids[i], lastLines(result.output, 12));
        if (failFast)
        {
            foreach (j; i + 1 .. subPackages.length)
                tasks.skip(ids[j], "fail-fast");
            break;
        }
    }

    region.finish();
    displaySummary(processed, failures);
    reportCoverage(subPackages, cov, failed, uncovered);
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

@safe pure
private string[] dubSingleFileCommand(
    string action,
    string filePath,
    string repoRoot,
    string[] runArgs = null,
)
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

    // Everything after `--` is the program's, not dub's.
    if (runArgs.length > 0)
        command ~= ["--"] ~ runArgs;

    return command;
}

private StandaloneExampleSpec detectStandaloneExampleSpec(string filePath)
{
    return parseStandaloneExampleSpec(filePath.readText.lineSplitter.array);
}

@safe pure
private StandaloneExampleSpec parseStandaloneExampleSpec(const(char[])[] lines)
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
            const modeWord = (spaceIdx < 0 ? value : value[0 .. spaceIdx]).toLower;
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

@("ci.dubSingleFileCommand.runArgsAfterDoubleDash")
@safe unittest
{
    // No arguments: the command ends at the file, with no stray `--`.
    assert(dubSingleFileCommand("run", "e.d", null)[$ - 2 .. $] == ["--single", "e.d"]);

    // With arguments, `--` separates them — everything after it is the
    // program's, not dub's.
    assert(dubSingleFileCommand("run", "e.d", null, ["--help"])[$ - 4 .. $]
        == ["--single", "e.d", "--", "--help"]);
    assert(dubSingleFileCommand("run", "e.d", null, ["--width", "80"])[$ - 4 .. $]
        == ["e.d", "--", "--width", "80"]);
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

/**
Formats output lines for display, truncating if necessary.

`keepTail` decides *which* end survives, and it matters: a compiler or test
runner puts the diagnosis at the **end** of its output, so truncating a failure
to its first lines shows a header and a few passing cases while discarding the
error — the failure is reported without ever naming its cause. Failing boxes
therefore keep the tail; passing ones keep the head, where a build's summary
lives.
*/
private string[] formatOutputLines(string[] lines, size_t maxLines = 8,
    bool keepTail = false) @safe
in (maxLines > 1, "maxLines must be at least 2 for truncation indicator")
{
    if (lines.length == 0)
        return [styledText(i"{dim (no output)}")];

    if (lines.length > maxLines)
        return keepTail
            ? [styledText(i"{dim ...}")] ~ lines[$ - (maxLines - 1) .. $]
            : lines[0 .. maxLines - 1] ~ [styledText(i"{dim ...}")];

    return lines;
}

@("ci.formatOutputLines.failureKeepsTheTail")
@safe
unittest
{
    auto lines = ["a", "b", "c", "d", "e"];
    // Passing: the head (a build summary) survives.
    const head = formatOutputLines(lines, 3);
    assert(head[0] == "a" && head[1] == "b", "head-truncation keeps the first lines");
    // Failing: the tail (the error) survives — the whole point.
    const tail = formatOutputLines(lines, 3, keepTail: true);
    assert(tail[$ - 1] == "e" && tail[$ - 2] == "d", "tail-truncation keeps the last lines");
    // Short output is untouched either way.
    assert(formatOutputLines(lines, 99) == lines);
    assert(formatOutputLines(lines, 99, keepTail: true) == lines);
}

/// Displays the result box for an example run.
private void displayResultBox(string[] outputLines, string header, bool success)
{
    auto footer = success
        ? styledText(i"{green ✓ passed}")
        : styledText(i"{red ✗ FAILED}");

    outputLines
        // A failing box keeps the TAIL: a compiler/test-runner puts its
        // diagnosis last, so head-truncation reports the failure while hiding
        // its cause (this box once showed a header and four passing tests for
        // a failure whose error was three lines further down).
        .formatOutputLines(8, keepTail: !success)
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

// ---------------------------------------------------------------------------
// ci-stats (GitHub Actions usage) — M1 skeleton; real implementation in M2+
// (see docs/specs/ci/stats/)
// ---------------------------------------------------------------------------

private int runCiStatsMode(in CliParams cli)
{
    import std.process : environment;
    import std.stdio : writeln;

    import ci_stats : CiStatsOptions, fetchAndDeserializeJson, runCiStats;

    string token = cli.githubToken;
    if (token.length == 0)
        token = environment.get("GITHUB_TOKEN", "");

    auto opts = CiStatsOptions(
        repo: cli.repo,
        token: token,
        limit: cli.limit,
        since: cli.since,
        workflowFilter: cli.workflow,
        conclusionFilter: cli.conclusion,
        branchFilter: cli.branch,
        baselineBranch: cli.baseline,
        splitAt: cli.split,
        showSteps: cli.steps,
        stepJobs: cli.stepJobs,
    );

    auto res = runCiStats!fetchAndDeserializeJson(opts);
    if (res.hasError)
    {
        import sparkles.base.logger : error;
        string errMsg = res.error;
        error(i"ci-stats failed: $(errMsg)");
        return 1;
    }

    return 0;
}
