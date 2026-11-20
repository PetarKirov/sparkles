/**
The `ci` command line (`apps/ci` SPEC §1.1): a core-cli command tree that
`runCli` dispatches.

Each command's options are its own fields, so an option means one thing on the
command that owns it, and the combinations the flat flags had to reject cannot
be written. Commands are verbs over subjects (CIC17): every pass/fail check is
a command of `ci check`, every check that rewrites a command of `ci fix`. Every
`run()` returns its outcome as a `RunExpected` (CIC16), which `runCli` turns
into the exit status and the diagnostic.

The commands hold options and dispatch; what they do lives in `app.d` and the
modules it calls.
*/
module cli;

import std.algorithm : canFind;
import std.array : join;

import sparkles.base.logger : initLogger, info, LogLevel;
import sparkles.core_cli.args;

import app : applyLogLevel, logHostResources;
import commands.check : runCheckAdHocSdl, runCheckBlobPathsCommand, runCheckCommitScope, runCheckCredits,
    runCheckDocsSidebar, runCheckGlossary, runCheckOpaqueRecipes, runCheckPinCache, runCheckSpecEvidence,
    runCheckVcsUrlsCommand, runReferenceLinksCommand;
import commands.docs : runAuditFencesCommand;
import commands.examples : runMarkdownExamplesCommand, runStandaloneExamplesCommand;
import commands.files : detectRepoRoot;
import commands.github : runMirrorChecksCommand, runReportLinkRotCommand;
import commands.maintenance : runBuildEachCommitMode, runGcR2Command, runSeedDubCache, runWritePinCosts,
    seedDubHome;
import commands.perf : runPerfAppendCommand, runPerfImportCommand, runPerfImportPrsCommand, runPerfPushCommand,
    runPerfSiteCommand, runRecordTask;
import commands.stats : runCiStatsCommand;
import commands.test_ : runListPlacements, runListSlowTestsMode, runTestCommand;
import one_node : runOneNode;
import sparkles.build_primitives.task.model : TaskKind;
import fence_audit : AuditScope;

// === Shared option groups ===

/// The program's options, accepted before or after any command.
struct GlobalOptions
{
    @(Option(`L|log-level`, description: "Set the log level (trace, info, warning, error). Default: info."))
    LogLevel logLevel = LogLevel.info;
}

/// Which files a command reads, besides its tracked defaults.
struct FileSelection
{
    @(Option(`include-files`,
        description: "File paths or git-style globs to include. Pass one or more selectors "
        ~ "immediately after the option. When omitted, the command uses its tracked defaults."))
    string[] include;

    @(Option(`exclude-files`,
        description: "File paths or git-style globs to leave out of the include set (or of the "
        ~ "command's tracked defaults). May be repeated."))
    string[] exclude;
}

/// Re-running a command inside a Linux VM from macOS (CIC3).
struct LinuxHostOptions
{
    @(Option(`host-system`,
        description: "Re-run this command on aarch64-linux or x86_64-linux from macOS, "
        ~ "via Apple container plus the matching packages.<system>.ci store path."))
    string hostSystem;

    @(Option(`host-ci-rev`,
        description: "With --host-system: the git revision to realize the Linux ci from "
        ~ "(default: HEAD, then the merge-base with origin/main, then origin/main)."))
    string hostCiRev;
}

/// Which repository's `refs/perf/data` to read or append to.
struct HistoryOptions
{
    @(Option(`history-remote`,
        description: "The repository whose refs/perf/data to read or append to (default: Sparkles' own)."))
    string historyRemote;
}

/// The GitHub API's credentials and repository.
struct GithubOptions
{
    @(Option(`g|github-token`, description: "GitHub token for API access (Bearer auth). Falls back to $GITHUB_TOKEN."))
    string token;

    @(Option(`r|repo`, description: "Target repository as owner/repo (e.g. PetarKirov/sparkles)."))
    string repo;
}

/// Who signs a commit of `refs/perf/data`.
struct SigningOptions
{
    @(Option(`signing-key`, description: "The SSH key that signs the history's commit."))
    string signingKey;
}

/// The program's command line as `ciMain` received it, for the Linux re-exec.
private string[] programArgs;

/**
`run()`, or, when `host` names another system, the same command line re-run
there (CIC3).
*/
private RunExpected!void onHost(alias run)(in LinuxHostOptions host)
{
    import linux_host : alreadyOnHostSystem, linuxHostSystems, runOnLinuxHost;

    if (host.hostCiRev.length && !host.hostSystem.length)
        return failRun("--host-ci-rev needs --host-system");
    if (!host.hostSystem.length)
        return run();
    if (!linuxHostSystems.canFind(host.hostSystem))
        return failRun("--host-system must be " ~ linuxHostSystems.join(" or "));
    if (alreadyOnHostSystem(host.hostSystem))
        return run();
    return runOnLinuxHost(host.hostSystem, programArgs, host.hostCiRev);
}

// === ci ===

@(Command("ci",
    shortDescription: "Repository CI helpers: tests, examples, checks, caches and run history",
))
struct Ci
{
    @(Flatten("Global options")) GlobalOptions global;

    mixin addSubCommand!TestCommand;
    mixin addSubCommand!PlacementsCommand;
    mixin addSubCommand!ExamplesCommand;
    mixin addSubCommand!CheckCommand;
    mixin addSubCommand!FixCommand;
    mixin addSubCommand!DocsCommand;
    mixin addSubCommand!GithubCommand;
    mixin addSubCommand!StatsCommand;
    mixin addSubCommand!CommitsCommand;
    mixin addSubCommand!CacheCommand;
    mixin addSubCommand!HostCommand;
    mixin addSubCommand!SlowTestsCommand;
    mixin addSubCommand!GcReportCommand;
    mixin addSubCommand!PerfCommand;
}

// === ci test ===

/// `ci test --special-modes`: the test runner's extracted modes.
enum SpecialModes
{
    off,     /// ordinary unittests
    betterc, /// the runner's `--better-c`
    wasm,    /// the runner's `--wasm`
    all,     /// both
}

/// `ci test --sanitize`.
enum Sanitizer
{
    off,     ///
    address, /// AddressSanitizer (LDC on Linux)
}

@(Command("test",
    shortDescription: "Build and test the repository's packages",
    description: "Runs dub test for each selected package (by default every one the root dub.sdl "
    ~ "declares), with coverage. --build-only builds instead, --special-modes runs the test "
    ~ "runner's extracted modes, --sanitize runs the tests under a sanitizer, and --slow runs "
    ~ "the @slow tests.",
))
struct TestCommand
{
    @(Option(`build-only`, description: "Run each package's dub build instead of its tests."))
    bool buildOnly;

    @(Option(`special-modes`,
        description: "Run the test runner's extracted modes, for each package that uses the "
        ~ "marker attribute: off (the default), betterc, wasm or all. Fails if a mode's "
        ~ "toolchain is missing."))
    SpecialModes specialModes;

    @(Option(`from`,
        description: "Test only these packages: each a short name, a qualified name, a path, or a "
        ~ "git-style glob over them (default: every one the root dub.sdl declares). With --slow: "
        ~ "the packages whose slow tests to run, by name."))
    string[] from;

    @(Option(`since`,
        description: "Also test the packages a change since REF reaches, judged by the files "
        ~ "their builds claim (default REF: the branch's upstream, else origin/main)."))
    string since;

    @(Option(`dependencies`, description: "Add the dependencies of the selected packages."))
    bool dependencies;

    @(Option(`dependents`, description: "Add the packages that depend on the selected ones."))
    bool dependents;

    @(Option(`coverage`,
        description: "Build each package's tests under -cov, merge the listings into "
        ~ "build/coverage and report covered lines per package, worst first. On by default; "
        ~ "--no-coverage turns it off. Reports only; nothing fails on a low number."))
    bool coverage = true;

    @(Option(`sanitize`,
        description: "Run each package's tests under a sanitizer: off (the default) or address "
        ~ "(LDC on Linux, DC=ldc2). Coverage is off under a sanitizer."))
    Sanitizer sanitize;

    @(Option(`slow`, description: "Run the @slow unittests instead of the ordinary ones, one dub test per package."))
    bool slow;

    @(Option(`tests`, description: "With --slow: the slow tests to run, by name (default: all of them)."))
    string[] tests;

    @(Option(`watch`,
        description: "Wait for a change to the packages' inputs, then test (with --build-only, "
        ~ "build) the packages it reaches, again after each change, until interrupted."))
    bool watch;

    @(Option(`placement`,
        description: "The placement of ci/placements.json this run belongs to: its legs and "
        ~ "coverage choose what runs, and its run record names it."))
    string placement;

    @(Option(`shard`, description: "With --placement: which of the placement's shards this run is, as K/N."))
    string shard;

    @(Option(`history-tip`,
        description: "With --shard: the refs/perf/data commit to pack from, as the planning job "
        ~ "read it. Default: the newest commit not later than HEAD's committer time."))
    string historyTip;

    @(Option(`F|fail-fast`, description: "Stop at the first failing package."))
    bool failFast;

    @(Option(`jobs`,
        description: "The weighted capacity running tasks may claim at once, not a count of threads "
        ~ "(a test leg claims its -t). Default: $SPARKLES_CI_JOBS, else the host's processors."))
    string jobs;

    @(Option(`interlaced`,
        description: "Stream each task's lines as they arrive, prefixed with the task, instead of "
        ~ "replaying whole task blocks in order."))
    bool interlaced;

    @(Option(`require-cached`,
        description: "Fail each build action of these kinds (compile, archive, link, generate) that "
        ~ "would execute instead of reusing a stored result, with why it missed. With --dry-run, "
        ~ "list the actions that would fail."))
    string[] requireCached;

    @(Option(`dry-run`,
        description: "Plan and print the graph: its tasks, claims and edges. Runs nothing and "
        ~ "writes nothing."))
    bool dryRun;

    @(Flatten) HistoryOptions history;
    @(Flatten) LinuxHostOptions host;

    RunExpected!void run()
    {
        if (const why = conflict())
            return failRun(why);
        return onHost!(() => runTestCommand(this))(host);
    }

    /// The combination of options this command cannot run, or `null`.
    string conflict() const @safe pure nothrow @nogc
    {
        const modes = buildOnly + (specialModes != SpecialModes.off) + slow;
        if (modes > 1)
            return "--build-only, --special-modes and --slow are mutually exclusive";
        if (sanitize != Sanitizer.off && modes)
            return "--sanitize runs the ordinary tests, not --build-only, --special-modes or --slow";
        if (tests.length && !slow)
            return "--tests needs --slow";
        if (watch && (specialModes != SpecialModes.off || slow || sanitize != Sanitizer.off))
            return "--watch runs the ordinary tests or --build-only";
        if (shard.length && !placement.length)
            return "--shard needs --placement";
        if (placement.length && (buildOnly || slow || watch))
            return "--placement does not combine with --build-only, --slow or --watch";
        if (historyTip.length && !shard.length)
            return "--history-tip needs --shard";
        // §4: focused selection is the graph's, not the slow or special modes'.
        if ((since.length || dependencies || dependents) && (slow || specialModes != SpecialModes.off
            || watch || placement.length))
            return "--since, --dependencies and --dependents select the ordinary or sanitized tests or "
                ~ "--build-only, without a placement";
        // CIC12: only the build graph's cacheable kinds.
        foreach (kind; requireCached)
            if (kind != "compile" && kind != "archive" && kind != "link" && kind != "generate")
                return "--require-cached takes compile, archive, link or generate";
        if (requireCached.length && (slow || specialModes != SpecialModes.off || watch))
            return "--require-cached applies to the build graph's runs: the ordinary or sanitized tests "
                ~ "or --build-only";
        // CIC1: the common execution options.
        if (jobs.length && !parseCapacity(jobs))
            return "--jobs takes a positive capacity";
        if (dryRun && interlaced)
            return "--dry-run has no task output to interlace";
        if ((dryRun || interlaced || jobs.length) && (slow || specialModes != SpecialModes.off || watch))
            return "--jobs, --interlaced and --dry-run run on the build graph: the ordinary or sanitized "
                ~ "tests or --build-only";
        return null;
    }
}

/**
A `--jobs` or `$SPARKLES_CI_JOBS` value as a weighted capacity (CIC1): a
positive decimal number, or zero when `text` is not one.
*/
uint parseCapacity(scope const(char)[] text) @safe pure nothrow @nogc
{
    if (!text.length || text.length > 6)
        return 0;
    uint n;
    foreach (c; text)
    {
        if (c < '0' || c > '9')
            return 0;
        n = n * 10 + (c - '0');
    }
    return n;
}

@("cli.parseCapacity")
@safe pure nothrow @nogc
unittest
{
    assert(parseCapacity("4") == 4 && parseCapacity("32") == 32);
    assert(parseCapacity("0") == 0 && parseCapacity("-1") == 0 && parseCapacity("") == 0);
    assert(parseCapacity("2x") == 0);
}

///
@("cli.TestCommand.conflict")
@safe pure nothrow
unittest
{
    assert(TestCommand().conflict is null);
    assert(TestCommand(buildOnly: true, slow: true).conflict
        == "--build-only, --special-modes and --slow are mutually exclusive");
    assert(TestCommand(sanitize: Sanitizer.address, specialModes: SpecialModes.all).conflict
        == "--sanitize runs the ordinary tests, not --build-only, --special-modes or --slow");
    assert(TestCommand(tests: ["x"]).conflict == "--tests needs --slow");
    assert(TestCommand(slow: true, tests: ["x"]).conflict is null);
    assert(TestCommand(shard: "1/2").conflict == "--shard needs --placement");
    assert(TestCommand(placement: "p", shard: "1/2", historyTip: "abc").conflict is null);
    assert(TestCommand(placement: "p", historyTip: "abc").conflict == "--history-tip needs --shard");
    assert(TestCommand(buildOnly: true, watch: true).conflict is null);
    assert(TestCommand(slow: true, watch: true).conflict == "--watch runs the ordinary tests or --build-only");
    // CIC1: the common execution options.
    assert(TestCommand(jobs: "0").conflict == "--jobs takes a positive capacity");
    assert(TestCommand(jobs: "-2").conflict == "--jobs takes a positive capacity");
    assert(TestCommand(jobs: "4").conflict is null);
    assert(TestCommand(dryRun: true, interlaced: true).conflict == "--dry-run has no task output to interlace");
    assert(TestCommand(dryRun: true, buildOnly: true).conflict is null);
    assert(TestCommand(slow: true, interlaced: true).conflict !is null);
    // §4: focused selection runs on the graph, without a placement.
    assert(TestCommand(since: "HEAD~1", dependents: true).conflict is null);
    assert(TestCommand(dependencies: true, slow: true).conflict !is null);
    assert(TestCommand(since: "main", placement: "p").conflict !is null);
    // CIC12.
    assert(TestCommand(requireCached: ["compile", "link"]).conflict is null);
    assert(TestCommand(requireCached: ["test"]).conflict == "--require-cached takes compile, archive, link or generate");
}

// === ci placements ===

@(Command("placements", shortDescription: "The placements of ci/placements.json (CIC14)"))
struct PlacementsCommand
{
    @(Command("list",
        shortDescription: "Print the placements' shards as a CI provider's matrix",
        description: "Prints ci/placements.json's shards as a CI provider's matrix, with the "
        ~ "refs/perf/data commit every shard reads. With --github-output, also sets them as the "
        ~ "step's outputs.",
    ))
    struct List
    {
        @(Option(`provider`, description: "The CI provider whose runners to list: github or circleci (default: github)."))
        string provider = "github";

        @(Option(`github-output`, description: "Append the matrix to this file, the step's $GITHUB_OUTPUT."))
        string githubOutput;

        @(Flatten) HistoryOptions history;

        RunExpected!void run() => runListPlacements(provider, githubOutput, history.historyRemote);
    }
}

// === ci examples ===

/// `ci examples run|verify|update`: what to do with a markdown example's output.
enum ExampleAction
{
    run,    /// run the examples
    verify, /// compare their output with the output blocks
    update, /// rewrite the output blocks
}

/// The options of the example commands.
struct ExampleOptions
{
    @(Option(`F|fail-fast`, description: "Stop on the first failing example and replay its output at the end."))
    bool failFast;

    @(Flatten) FileSelection files;
    @(Flatten) LinuxHostOptions host;
}

/// A markdown example command over `options`.
private RunExpected!void markdownExamples(ExampleAction action, in ExampleOptions options) =>
    onHost!(() => runMarkdownExamplesCommand(action, options.files, options.failFast))(options.host);

@(Command("examples", shortDescription: "Runnable examples in markdown and in example programs"))
struct ExamplesCommand
{
    @(Command("run", shortDescription: "Run the markdown files' examples"))
    struct Run
    {
        @(Flatten) ExampleOptions options;

        RunExpected!void run() => markdownExamples(ExampleAction.run, options);
    }

    @(Command("verify", shortDescription: "Compare the markdown examples' output with their output blocks"))
    struct Verify
    {
        @(Flatten) ExampleOptions options;

        RunExpected!void run() => markdownExamples(ExampleAction.verify, options);
    }

    @(Command("update", shortDescription: "Rewrite the markdown examples' output blocks with their actual output"))
    struct Update
    {
        @(Flatten) ExampleOptions options;

        RunExpected!void run() => markdownExamples(ExampleAction.update, options);
    }

    @(Command("standalone",
        shortDescription: "Run the standalone example programs",
        description: "Runs the .d example programs; with no files, the tracked example directories "
        ~ "(libs/*/examples and the research catalogs' examples).",
    ))
    struct Standalone
    {
        @(Flatten) ExampleOptions options;

        RunExpected!void run() =>
            onHost!(() => runStandaloneExamplesCommand(options.files, options.failFast))(options.host);
    }
}

// === ci check, ci fix ===

@(Command("check", shortDescription: "Pass/fail checks of the repository"))
struct CheckCommand
{
    @(Command("commit-scope",
        shortDescription: "Check a commit message for a detailed scope",
        description: "The pre-commit commit-msg hook. Reads the message from the file, or from "
        ~ "standard input when it is - or absent.",
    ))
    struct CommitScope
    {
        @(Argument("message-file", optional: true, description: "The commit message file, or - for standard input."))
        string messageFile = "-";

        RunExpected!void run() => runOneNode("check-commit-scope", TaskKind.scan, () => runCheckCommitScope(messageFile));
    }

    @(Command("reference-links",
        shortDescription: "Report duplicate markdown reference definitions that point to the same URL",
    ))
    struct ReferenceLinks
    {
        @(Flatten) FileSelection files;

        RunExpected!void run() => runOneNode("check-reference-links", TaskKind.scan, () => runReferenceLinksCommand(files, fix: false));
    }

    @(Command("vcs-urls",
        shortDescription: "Check that github.com and raw.githubusercontent.com URLs pin a commit",
    ))
    struct VcsUrls
    {
        @(Flatten) FileSelection files;

        RunExpected!void run() => runOneNode("check-vcs-urls", TaskKind.scan, () => runCheckVcsUrlsCommand(files));
    }

    @(Command("blob-paths",
        shortDescription: "Check that each SHA-pinned blob citation names a path that exists at that commit",
        description: "Reads the upstream clones under --clone-root. Complements `ci check "
        ~ "vcs-urls`, which only checks the ref. Local only: a citation whose repository is not "
        ~ "cloned is reported as unchecked, never as a failure.",
    ))
    struct BlobPaths
    {
        @(Option(`clone-root`, description: "Root directory holding the upstream clones. Defaults to $REPOS."))
        string cloneRoot;

        @(Flatten) FileSelection files;

        RunExpected!void run() => runOneNode("check-blob-paths", TaskKind.scan, () => runCheckBlobPathsCommand(files, cloneRoot));
    }

    @(Command("sidebar",
        shortDescription: "Check the docs sidebar against the published pages",
        description: "Every published docs/**/*.md page is linked, and every sidebar link "
        ~ "resolves to a page. Respects srcExclude; the home page is always linked.",
    ))
    struct Sidebar
    {
        RunExpected!void run() => runOneNode("check-sidebar", TaskKind.scan, () => runCheckDocsSidebar());
    }

    @(Command("glossary",
        shortDescription: "Check docs/.vitepress/glossary.json and the links into it",
        description: "Unique slug ids, known owners, plain-text summaries, portable links, "
        ~ "cross-references, and that every docs link into the glossary names an existing "
        ~ "entry. Unused entries are reported, not failed.",
    ))
    struct Glossary
    {
        RunExpected!void run() => runOneNode("check-glossary", TaskKind.scan, () => runCheckGlossary());
    }

    @(Command("credits",
        shortDescription: "Check docs/credits/ against the build inputs",
        description: "Every component an application links or ships has a part, every part "
        ~ "names something shipped, and each application page includes exactly its parts.",
    ))
    struct Credits
    {
        RunExpected!void run() => runOneNode("check-credits", TaskKind.scan, () => runCheckCredits());
    }

    @(Command("spec-evidence",
        shortDescription: "Check that every symbol a spec's evidence column cites resolves",
        description: "Citations listed in docs/specs/evidence-backlog.txt are reported, not "
        ~ "failed; a new unresolved citation fails, and so does a listed one that now resolves "
        ~ "(`ci fix spec-evidence-backlog` rewrites the list).",
    ))
    struct SpecEvidence
    {
        RunExpected!void run() => runOneNode("check-spec-evidence", TaskKind.scan, () => runCheckSpecEvidence(updateBacklog: false));
    }

    @(Command("adhoc-sdl",
        shortDescription: "Check that no D source matches SDL text by hand (SDE9)",
        description: "A canFind/indexOf/regex/… call whose arguments hold an SDL marker fails "
        ~ "unless apps/ci/sdl-audit-allowlist.txt lists it with a reason; so does a stale entry.",
    ))
    struct AdhocSdl
    {
        RunExpected!void run() => runOneNode("check-adhoc-sdl", TaskKind.scan, () => runCheckAdHocSdl());
    }

    @(Command("opaque-recipes",
        shortDescription: "Report every recipe entry no input set can hold",
        description: "Commands, flags carrying paths, and paths through variables or outside the "
        ~ "repository, with what to write instead. An entry apps/ci/opaque-recipe-allowlist.txt "
        ~ "does not list with a reason fails, and so does a stale one.",
    ))
    struct OpaqueRecipes
    {
        RunExpected!void run() => runOneNode("check-opaque-recipes", TaskKind.scan, () => runCheckOpaqueRecipes());
    }

    @(Command("pin-cache",
        shortDescription: "Check that the Cachix cache serves every pinned toolchain output (TC23)",
        description: "Evaluates the flake and builds nothing; needs no token. The cache is "
        ~ "$CACHIX_CACHE, or sparkles.",
    ))
    struct PinCache
    {
        RunExpected!void run() => runOneNode("check-pin-cache", TaskKind.scan, () => runCheckPinCache());
    }

    @(Command("wasm-modules",
        shortDescription: "Check the docs site's WebAssembly modules against the same D functions run natively",
        description: "Runs a fixed corpus through the modules under node and through the same D "
        ~ "functions natively, and fails on any difference (TCM9).",
    ))
    struct WasmModules
    {
        @(Option(`text-module`, description: "The text module (spk-text.wasm)."))
        string textModule;

        @(Option(`table-module`, description: "The table module (spk-table.wasm)."))
        string tableModule;

        @(Option(`wired-module`, description: "The wired module (spk-wired.wasm)."))
        string wiredModule;

        @(Option(`wasi-loader`, description: "The site's loader (docs/.vitepress/theme/wasi.ts)."))
        string wasiLoader;

        @(Option(`wasi-shim`, description: "The @bjorn3/browser_wasi_shim package directory."))
        string wasiShim;

        RunExpected!void run()
        {
            import wasm_modules_check : runCheckWasmModules;

            return runCheckWasmModules(textModule, tableModule, wiredModule, wasiLoader, wasiShim);
        }
    }

    @(Command("nix-wasm",
        shortDescription: "Check the dub recipe module for builtins.wasm against the native oracle (WW10)",
        description: "On an evaluator with builtins.wasm, checks the module against the native "
        ~ "oracle's answers and the regular-expression reader.",
    ))
    struct NixWasm
    {
        @(Option(`module`, description: "The module (spk-dub-manifest.wasm)."))
        string module_;

        @(Option(`answers`, description: "The oracle's answers (the dub-manifest-nix-answers package)."))
        string answers;

        @(Option(`evaluator`, description: "The evaluator to run (default: nix)."))
        string evaluator = "nix";

        RunExpected!void run()
        {
            import nix_wasm_check : runCheckNixWasm;

            return runCheckNixWasm(detectRepoRoot(), evaluator, module_, answers);
        }
    }
}

@(Command("fix", shortDescription: "Rewrite what a check reports"))
struct FixCommand
{
    @(Command("reference-links",
        shortDescription: "Rewrite duplicate markdown references to one canonical label per URL",
    ))
    struct ReferenceLinks
    {
        @(Flatten) FileSelection files;

        @(Option(`dry-run`, description: "Report what would change; write nothing."))
        bool dryRun;

        RunExpected!void run() => runOneNode("fix-reference-links", TaskKind.rewrite,
            () => runReferenceLinksCommand(files, fix: true, dryRun: dryRun));
    }

    @(Command("spec-evidence-backlog",
        shortDescription: "Rewrite docs/specs/evidence-backlog.txt to the citations that resolve nowhere now",
    ))
    struct SpecEvidenceBacklog
    {
        @(Option(`dry-run`, description: "Report what the backlog would hold; write nothing."))
        bool dryRun;

        RunExpected!void run() => runOneNode("fix-spec-evidence-backlog", TaskKind.rewrite,
            () => runCheckSpecEvidence(updateBacklog: true, dryRun: dryRun));
    }
}

// === ci docs ===

@(Command("docs", shortDescription: "The documentation site's reports and assets"))
struct DocsCommand
{
    @(Command("fences-audit",
        shortDescription: "Classify every fenced code block against the tree-sitter grammar bundle",
        description: "Classifies the fences of docs/ and README.md, and inventories the VitePress "
        ~ "code-block features a highlighter swap must preserve.",
    ))
    struct FencesAudit
    {
        @(Option(`json`, description: "Write the machine-readable report to this file."))
        string json;

        @(Option(`root`, description: "Audit this worktree instead of the current one."))
        string root;

        @(Option(`audit-scope`,
            description: "Which side of the config's srcExclude split to census: site (the default), all or excluded."))
        AuditScope auditScope;

        @(Flatten) FileSelection files;

        RunExpected!void run() => runAuditFencesCommand(files, json, root, auditScope);
    }

    @(Command("stage-wasm",
        shortDescription: "Build the site's WebAssembly modules (nix build .#docs-wasm) and copy them into docs/public/",
    ))
    struct StageWasm
    {
        RunExpected!void run()
        {
            import docs_wasm : stageDocsWasm;

            return stageDocsWasm(detectRepoRoot());
        }
    }
}

// === ci github, ci stats ===

@(Command("github", shortDescription: "Actions on GitHub: checks and issues"))
struct GithubCommand
{
    @(Command("mirror-checks",
        shortDescription: "Give a default-branch commit the checks its pull request earned",
        description: "When the landed tree is byte-identical to the tree the pull request built, "
        ~ "copies its checks onto the commit. Reports mirrored=false when the trees differ, so "
        ~ "the caller can run the real build instead.",
    ))
    struct MirrorChecks
    {
        @(Option(`sha`, description: "The commit to attach the mirrored checks to."))
        string sha;

        @(Option(`skip-check`,
            description: "A check-run name never to mirror, repeatable: for checks whose own "
            ~ "workflow also runs on this push, which would otherwise land twice."))
        string[] skipCheck;

        @(Option(`no-write`, description: "Report what would be mirrored without creating anything."))
        bool noWrite;

        @(Flatten) GithubOptions github;

        RunExpected!void run()
        {
            if (!sha.length)
                return failRun("ci github mirror-checks needs --sha");
            if (!github.repo.length)
                return failRun("ci github mirror-checks needs --repo owner/repo");
            return runMirrorChecksCommand(github, sha, skipCheck, dryRun: noWrite);
        }
    }

    @(Command("link-rot-issue",
        shortDescription: "Keep one standing issue in step with the link sweep",
        description: "A failing sweep opens or rewrites the issue, a passing one closes it.",
    ))
    struct LinkRotIssue
    {
        @(Option(`report`, description: "The sweep log to quote in the issue."))
        string report;

        @(Option(`rotten`,
            description: "The sweep found dead links. Without it the sweep is treated as clean "
            ~ "and the standing issue is closed."))
        bool rotten;

        @(Option(`run-url`, description: "URL of the run to link from the issue body."))
        string runUrl;

        @(Flatten) GithubOptions github;

        RunExpected!void run()
        {
            if (!github.repo.length)
                return failRun("ci github link-rot-issue needs --repo owner/repo");
            return runReportLinkRotCommand(github, report, rotten, runUrl);
        }
    }
}

@(Command("stats",
    shortDescription: "GitHub Actions job timing statistics and runner-type aggregates",
    description: "See docs/specs/ci/stats/ for the full specification. With --merges, audits what "
    ~ "merged pull requests landed on the default branch instead.",
))
struct StatsCommand
{
    @(Flatten) GithubOptions github;

    @(Option(`l|limit`, description: "Maximum number of recent workflow runs to analyze (default 100)."))
    int limit = 100;

    @(Option(`S|since`, description: "Only include runs created on/after this date (YYYY-MM-DD or ISO)."))
    string since;

    @(Option(`w|workflow`, description: "Filter to runs/jobs matching this workflow name or path substring."))
    string workflow;

    @(Option(`c|conclusion`, description: "Only jobs with this conclusion (e.g. success, failure)."))
    string conclusion;

    @(Option(`b|branch`, description: "Only runs on this branch (head_branch, exact match)."))
    string branch;

    @(Option(`B|baseline`,
        description: "Compare --branch against this branch per job name, showing the median delta. "
        ~ "Both refs are taken from the same run window."))
    string baseline;

    @(Option(`s|split`,
        description: "Split the fetched jobs at this instant (YYYY-MM-DD or ISO-8601) and compare "
        ~ "the halves per job name: the axis for a workflow that only triggers on pull_request."))
    string split;

    @(Option(`steps`,
        description: "Break the slowest job names down by step, so a regression is attributed to "
        ~ "the step that owns it rather than to the job total."))
    bool steps;

    @(Option(`step-jobs`, description: "How many job names --steps expands (default 3)."))
    int stepJobs = 3;

    @(Option(`merges`,
        description: "Audit what merged pull requests landed on the default branch: the commits "
        ~ "carried, whether the landed tree is the tree CI built, and the share green at the head."))
    bool merges;

    @(Option(`badge-dir`,
        description: "With --merges: also write the shields.io endpoint documents the README "
        ~ "badges read (merged-prs.json, merged-green.json) into this directory."))
    string badgeDir;

    RunExpected!void run()
    {
        import ci_stats : parseSplitInstant;

        if (limit <= 0)
            return failRun("--limit must be a positive integer");
        if (stepJobs <= 0)
            return failRun("--step-jobs must be a positive integer");
        // A baseline is one side of a two-population comparison.
        if (baseline.length && !branch.length)
            return failRun("--baseline requires --branch (the candidate side of the comparison)");
        if (badgeDir.length && !merges)
            return failRun("--badge-dir needs --merges");
        // Reject a malformed pivot here rather than after a few hundred API calls.
        if (split.length)
            try
                cast(void) parseSplitInstant(split);
            catch (Exception e)
                return failRun("--split: " ~ e.msg);
        return runCiStatsCommand(this);
    }
}

// === ci commits, ci cache, ci host, ci slow-tests, ci gc-report ===

@(Command("commits", shortDescription: "A range of commits"))
struct CommitsCommand
{
    @(Command("build-each",
        shortDescription: "Build sub-packages at every commit from --base to HEAD",
        description: "Builds every commit of the range in one scratch worktree, so each commit of "
        ~ "a stack is known to build: CI builds only a pull request's tip. Defaults to the apps "
        ~ "whose default configuration dub test never compiles (hue, ui-gallery, diagram).",
    ))
    struct BuildEach
    {
        @(Option(`base`,
            description: "The commit the range starts after. Default: the merge-base of HEAD and origin/main."))
        string base;

        @(Option(`packages`, description: "The sub-packages to build, by name."))
        string[] packages;

        @(Option(`F|fail-fast`, description: "Stop at the first commit that fails to build."))
        bool failFast;

        RunExpected!void run()
        {
            seedDubHome();
            return runBuildEachCommitMode(base, packages, failFast);
        }
    }
}

/// The directory holding the build graph's store: `$XDG_CACHE_HOME/sparkles`.
string storeDirectory() @safe
{
    import std.path : buildPath;
    import std.process : environment;

    return buildPath(environment.get("XDG_CACHE_HOME", buildPath(environment.get("HOME", "/"), ".cache")), "sparkles");
}

/// Standard output as a writer of the store's lines.
auto stdoutWriter() @trusted
{
    import std.stdio : stdout;

    return stdout.lockingTextWriter;
}

/// One of `storeOperation`'s operations on the store, as a command's outcome.
RunExpected!void storeCommand(string operation)
{
    import sparkles.build_graph.execute : storeOperation;

    auto writer = stdoutWriter();
    const status = storeOperation(storeDirectory(), operation, writer);
    return status == 0 ? ranOk() : failRun("ci cache: " ~ operation ~ " failed", status);
}

@(Command("cache", shortDescription: "Dependency, toolchain and binary caches"))
struct CacheCommand
{
    @(Command("seed-dub",
        shortDescription: "Copy the Nix-vendored dependency sources into DUB_HOME",
        description: "Copies the sources into DUB_HOME (default ~/.dub), preserving the versions already there.",
    ))
    struct SeedDub
    {
        RunExpected!void run() => runSeedDubCache();
    }

    // The build graph's store (build graph §6) beneath $XDG_CACHE_HOME/sparkles.

    @(Command("stats", shortDescription: "The build graph's store: its results and their bytes"))
    struct Stats
    {
        RunExpected!void run() => storeCommand("size");
    }

    @(Command("list", shortDescription: "Each stored result: key, bytes, recency and task"))
    struct List
    {
        RunExpected!void run() => storeCommand("list");
    }

    @(Command("gc",
        shortDescription: "Collect the store's abandoned staging, leases and older layouts, then evict",
        description: "Collects what crashed builders left (staging entries, dead leases) and the "
        ~ "directories of older store layouts, then evicts the least recently used results down "
        ~ "to --bound bytes (default 20 GiB) (BGS5, BGS10).",
    ))
    struct Gc
    {
        @(Option(`bound`, description: "Evict down to this many result bytes (default 20 GiB)."))
        string bound;

        RunExpected!void run()
        {
            auto collected = storeCommand("gc");
            if (collected.hasError)
                return collected;
            return storeCommand(bound.length ? "evict=" ~ bound : "evict");
        }
    }

    @(Command("verify",
        shortDescription: "Check stored results, or re-execute a sample of a run's (CIC13)",
        description: "Rehashes every stored result's outputs against its record, removing a corrupt "
        ~ "one (BGS6). With --rerun, re-executes a sample of the last `ci test` run's cacheable "
        ~ "actions with their lookups bypassed, into a private store, and fails naming each whose "
        ~ "outputs differ from its stored result, which it removes (BGS9, CIC13).",
    ))
    struct Verify
    {
        @(Option(`rerun`, description: "Re-execute a sample of the last run's actions and compare (BGS9)."))
        bool rerun;

        @(Option(`determinism-sample`,
            description: "With --rerun: how many compiles, and how many other actions, to check (default 4)."))
        string determinismSample;

        @(Option(`task`, description: "With --rerun: check these tasks instead of the sample."))
        string[] tasks;

        RunExpected!void run()
        {
            import graph_driver : rerunCheck;

            if (!rerun)
                return determinismSample.length || tasks.length
                    ? failRun("--determinism-sample and --task need --rerun", 2) : storeCommand("verify");
            const n = determinismSample.length ? parseCapacity(determinismSample) : 4;
            if (!n)
                return failRun("--determinism-sample takes a positive count", 2);
            auto writer = stdoutWriter();
            const status = rerunCheck(detectRepoRoot(), storeDirectory(), n, tasks, writer);
            return status == 0 ? ranOk() : failRun("ci cache verify --rerun found a difference", status);
        }
    }

    @(Command("remove",
        shortDescription: "Remove stored results by key, task, package or toolchain (BGS7)",
    ))
    struct Remove
    {
        @(Option(`key`, description: "Results with these result keys."))
        string[] keys;
        @(Option(`task`, description: "The results of these tasks."))
        string[] tasks;
        @(Option(`package`, description: "The results of these packages' actions."))
        string[] packages;
        @(Option(`toolchain`, description: "The results built by this toolchain identity."))
        string toolchain;

        RunExpected!void run()
        {
            string[] ops;
            foreach (k; keys)
                ops ~= "remove-key=" ~ k;
            foreach (t; tasks)
                ops ~= "remove-task=" ~ t;
            foreach (p; packages)
                ops ~= "remove-package=" ~ p;
            if (toolchain.length)
                ops ~= "remove-toolchain=" ~ toolchain;
            if (!ops.length)
                return failRun("ci cache remove needs --key, --task, --package or --toolchain", 2);
            foreach (op; ops)
            {
                auto removed = storeCommand(op);
                if (removed.hasError)
                    return removed;
            }
            return ranOk();
        }
    }

    @(Command("replace",
        shortDescription: "Execute tasks with their lookups bypassed, replacing their results (BGS7)",
    ))
    struct Replace
    {
        @(Argument("tasks", description: "Each task by id, or by a prefix only one id has."))
        string[] tasks;

        RunExpected!void run()
        {
            import graph_driver : replaceTask;

            if (!tasks.length)
                return failRun("ci cache replace needs a task", 2);
            auto writer = stdoutWriter();
            foreach (task; tasks)
            {
                const status = replaceTask(detectRepoRoot(), storeDirectory(), task, writer);
                if (status != 0)
                    return failRun("ci cache replace " ~ task ~ " failed", status);
            }
            return ranOk();
        }
    }

    @(Command("explain",
        shortDescription: "Whether a task and each action it needs would hit the store, and why not (BGS8)",
    ))
    struct Explain
    {
        @(Argument("task", description: "The task, by id or by a prefix only one id has."))
        string task;

        RunExpected!void run()
        {
            import graph_driver : explainTask;

            auto writer = stdoutWriter();
            const status = explainTask(detectRepoRoot(), storeDirectory(), task, writer);
            return status == 0 ? ranOk() : failRun("ci cache explain " ~ task ~ " failed", status);
        }
    }

    @(Command("pin-costs",
        shortDescription: "Write the toolchain build plan's cost file (TC23)",
        description: "Each pin's median recorded build time on refs/perf/data, and "
        ~ "ci/placements.json's budget.",
    ))
    struct PinCosts
    {
        @(Argument("file", description: "Where to write the cost file."))
        string file;

        @(Flatten) HistoryOptions history;

        RunExpected!void run() => runWritePinCosts(file, history.historyRemote);
    }

    @(Command("gc-r2",
        shortDescription: "Garbage-collect the R2 binary cache",
        description: "Keeps the gc-roots of the trees of HEAD's last --keep-commits first-parent "
        ~ "commits, everything younger than --grace-days, and their closures; deletes the rest. "
        ~ "Reads R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ACCOUNT_ID and R2_BUCKET.",
    ))
    struct GcR2
    {
        @(Option(`keep-commits`, description: "How many of HEAD's first-parent commits keep their roots (default 30)."))
        int keepCommits = 30;

        @(Option(`grace-days`, description: "Objects younger than this many days are kept, with their closures (default 14)."))
        int graceDays = 14;

        @(Option(`no-delete`, description: "Report what would be deleted without deleting it."))
        bool noDelete;

        RunExpected!void run()
        {
            if (keepCommits <= 0 || graceDays < 0)
                return failRun("--keep-commits must be positive and --grace-days not negative");
            return runGcR2Command(keepCommits, graceDays, dryRun: noDelete);
        }
    }
}

@(Command("host", shortDescription: "The Linux-on-macOS hosts --host-system uses"))
struct HostCommand
{
    @(Command("probe", shortDescription: "Report which Linux-on-macOS backends are available"))
    struct Probe
    {
        RunExpected!void run()
        {
            import linux_host : runLinuxHostProbe;

            return runLinuxHostProbe();
        }
    }
}

@(Command("slow-tests", shortDescription: "The @slow unittests"))
struct SlowTestsCommand
{
    @(Command("list",
        shortDescription: "Print the @slow unittests as the slow-tests job's JSON matrix",
        description: "Also appended to $GITHUB_OUTPUT as `matrix`.",
    ))
    struct List
    {
        RunExpected!void run() => runListSlowTestsMode();
    }
}

@(Command("gc-report",
    shortDescription: "Summarize a GC recording",
    description: "Summarizes a recording of sparkles.profiling.gc_sampler (a run with "
    ~ "SPARKLES_GC_SAMPLES=FILE and --DRT-gcopt=gc:sampler): the bytes allocated by site and "
    ~ "inclusively by function, the pauses, and what stayed live, scanned or not.",
))
struct GcReportCommand
{
    @(Argument("recording", description: "The recording to summarize."))
    string recording;

    @(Option(`baseline`,
        description: "A shorter recording of the same scenario to subtract, leaving the steady "
        ~ "cost (a 1200-frame drag minus a 200-frame one)."))
    string baseline;

    @(Option(`top`, description: "The rows each table shows (default 25)."))
    size_t top = 25;

    RunExpected!void run()
    {
        import gc_report : runGcReport;

        return runGcReport(recording, baseline, top);
    }
}

// === ci perf ===

@(Command("perf", shortDescription: "Run records and the refs/perf/data history"))
struct PerfCommand
{
    @(Command("record",
        shortDescription: "Run a command and record it as a task of a run record",
        description: "Runs the command after -- and records it as the task, with its wall time "
        ~ "and outcome (OD21): a step ci does not run itself, such as a toolchain pin build. "
        ~ "Exits with the command's status.",
    ))
    struct Record
    {
        @(Argument("task", description: "The task's id, such as pin-build:<pin>."))
        string task;

        @(Argument("command", optional: true, rest: true, description: "The command to run, after --."))
        string[] command;

        @(Option(`placement`, description: "The placement this run belongs to."))
        string placement;

        @(Option(`shard`, description: "With --placement: the shard, as K/N."))
        string shard;

        RunExpected!void run()
        {
            if (!command.length)
                return failRun("ci perf record needs a command after --", 2);
            return runRecordTask(task, command, placement, shard);
        }
    }

    @(Command("push",
        shortDescription: "Append this machine's run records to refs/perf/data (OBH6)",
        description: "Signed with --signing-key or git's user.signingkey. A record of a dirty "
        ~ "tree needs --allow-dirty.",
    ))
    struct Push
    {
        @(Option(`allow-dirty`, description: "Push records of a dirty tree too."))
        bool allowDirty;

        @(Flatten) SigningOptions signing;
        @(Flatten) HistoryOptions history;

        RunExpected!void run() => runPerfPushCommand(allowDirty, signing.signingKey, history.historyRemote);
    }

    @(Command("import",
        shortDescription: "Build run records from a GitHub Actions run's test job logs",
        description: "With gh, as origin `imported`, for `ci perf push` to publish: seeds the history.",
    ))
    struct Import
    {
        @(Argument("run", description: "The GitHub Actions run id."))
        string runId;

        @(Option(`r|repo`, description: "The repository as owner/repo."))
        string repo;

        RunExpected!void run()
        {
            if (!repo.length)
                return failRun("ci perf import needs --repo owner/repo", 2);
            return runPerfImportCommand(runId, repo);
        }
    }

    @(Command("append",
        shortDescription: "Append a CI run's downloaded records to refs/perf/data (OBH4)",
        description: "The identity and --run-date come from the provider's API, never from the records.",
    ))
    struct Append
    {
        @(Option(`records`, description: "The directory the records were downloaded to."))
        string records;

        @(Option(`run-id`, description: "The run whose records these are."))
        string runId;

        @(Option(`run-attempt`, description: "That run's latest attempt."))
        string runAttempt = "1";

        @(Option(`run-date`, description: "The run's start date, YYYY-MM-DD, in UTC."))
        string runDate;

        @(Option(`landed-commit`, description: "The commit of main the records describe."))
        string landedCommit;

        @(Flatten) SigningOptions signing;
        @(Flatten) HistoryOptions history;
        /// With `--repo`, the landing's pull request record is appended too (OBJ4).
        @(Flatten) GithubOptions github;

        RunExpected!void run()
        {
            if (!records.length || !runId.length || runDate.length != 10 || landedCommit.length < 12)
                return failRun("ci perf append needs --records, --run-id, --run-date YYYY-MM-DD "
                    ~ "and --landed-commit", 2);
            return runPerfAppendCommand(this);
        }
    }

    @(Command("import-prs",
        shortDescription: "Build the pull request records of merged pull requests (OBQ9)",
        description: "Writes them locally, for `ci perf push` to publish: seeds the history.",
    ))
    struct ImportPrs
    {
        @(Option(`since`, description: "The first merge date, YYYY-MM-DD, in UTC."))
        string since;

        @(Flatten) GithubOptions github;

        RunExpected!void run()
        {
            if (!github.repo.length || since.length != 10)
                return failRun("ci perf import-prs needs --repo owner/repo and --since YYYY-MM-DD", 2);
            return runPerfImportPrsCommand(github, since);
        }
    }

    @(Command("site",
        shortDescription: "Build the dashboard from refs/perf/data (§17)",
        description: "Static pages, built from the verified history only; two builds from one tip are "
        ~ "byte-identical.",
    ))
    struct Site
    {
        @(Option(`o|out`, description: "The directory to write the site to."))
        string out_;

        @(Option(`history-tip`, description: "The history commit to build from (default: the ref's tip)."))
        string historyTip;

        @(Option(`rates`, description: "The runner rates file (default: ci/runner-rates.json)."))
        string rates;

        @(Flatten) HistoryOptions history;

        RunExpected!void run()
        {
            if (!out_.length)
                return failRun("ci perf site needs --out DIR", 2);
            return runPerfSiteCommand(this);
        }
    }
}

// === Entry ===

/// `ci`'s `main`: parse the command line and run the command it names.
int ciMain(string[] args)
{
    // Installed before parsing, so a slow parse still has a timestamped
    // breadcrumb; `--log-level` applies once the options are in.
    initLogger(LogLevel.info);
    programArgs = args;
    return runCli!Ci(args, (ref parsed) {
        if (parsed.value.global.logLevel != LogLevel.info)
            applyLogLevel(parsed.value.global.logLevel);
        info(i"ci $(args.length > 1 ? args[1 .. $].join(" ") : "")");
        logHostResources();
        return 0;
    });
}

/// Every flag SPEC §2 removed is an unknown option (CIC4).
@("cli.removedFlags.unknown")
@system unittest
{
    static immutable removed = [
        "--test", "-t", "--build", "--test-extracted", "--test-sanitize", "--test-slow",
        "--packages", "--files", "--list-slow-tests", "--coverage", "--example-files", "-x",
        "--verify", "--update", "-u", "--dedup-reference-links", "-d", "--fix-reference-links",
        "-f", "--check-vcs-urls", "--check-docs-sidebar", "--check-glossary", "--check-credits",
        "--check-spec-evidence", "--update-spec-evidence-backlog", "--check-blob-paths",
        "--audit-fences", "--check-wasm-modules", "--stage-docs-wasm", "--build-each-commit",
        "--check-commit-scope", "--seed-dub-cache", "--check-pin-cache", "--linux-host-probe",
        "--mirror-checks", "--ci-stats", "-C", "--report-link-rot", "--watch",
        "--list-placements", "--check-adhoc-sdl", "--check-opaque-recipes", "--check-nix-wasm",
        "--gc-report", "--write-pin-costs", "--gc-r2", "--record-task", "--perf-push",
        "--perf-import-github-run", "--perf-append", "--perf-records", "--perf-run-id",
        "--skip-packages", "--dry-run",
    ];
    foreach (flag; removed)
    {
        const parsed = parseCli!Ci(["ci", flag]);
        assert(!parsed && parsed.error.message == "Unknown option " ~ flag, flag);
    }
    // `-V` was `--verify`; it is core-cli's `--version` now.
    assert(!parseCli!Ci(["ci", "-V"]) && parseCli!Ci(["ci", "-V"]).error.isVersion);
    // A command's own options keep their spelling.
    assert(parseCli!Ci(["ci", "test", "--no-coverage", "--from", "base"]));
    assert(parseCli!Ci(["ci", "commits", "build-each", "--packages", "hue"]));
    assert(parseCli!Ci(["ci", "perf", "record", "t", "--", "sh", "-c", "exit 0"]));
}
