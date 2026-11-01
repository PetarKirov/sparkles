/++
CI-provider log conventions
([task-DAG SPEC TDO6, TDO7](../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
detection of the CI service a tool runs under, and its syntax for
collapsible groups, source annotations, secret masks, and step summaries.

Reporters never test environment variables themselves: they detect once
($(LREF detectCiProvider), through an environment seam so tests are
hermetic) and write through a $(LREF CiLog). Every operation is a
writer-based template that writes whole lines and stays `@nogc` where the
writer is; a provider without an operation degrades to plain output and
never emits another provider's syntax.

$(TABLE
    $(TR $(TH provider) $(TH group) $(TH annotate) $(TH mask) $(TH summary))
    $(TR $(TD GitHub Actions) $(TD `::group::`/`::endgroup::`) $(TD `::error file=…,line=…::`)
        $(TD `::add-mask::`) $(TD append to `$GITHUB_STEP_SUMMARY`))
    $(TR $(TD GitLab CI) $(TD `section_start`/`section_end`) $(TD plain) $(TD none) $(TD none))
    $(TR $(TD Buildkite) $(TD `--- <title>`) $(TD plain) $(TD none) $(TD `buildkite-agent annotate`, as data))
    $(TR $(TD Azure Pipelines) $(TD `##[group]`/`##[endgroup]`) $(TD `##vso[task.logissue …]`)
        $(TD `##vso[task.setvariable …;isSecret=true]`) $(TD none))
    $(TR $(TD CircleCI, none) $(TD a heading line) $(TD plain) $(TD none) $(TD none))
)

The syntax follows each provider's published reference:

$(LIST
    * GitHub Actions: https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands,
        with data and property escaping as `@actions/core` implements it
        (`escapeData`/`escapeProperty` in
        https://github.com/actions/toolkit/blob/main/packages/core/src/command.ts);
        `GITHUB_ACTIONS`: https://docs.github.com/en/actions/reference/workflows-and-actions/variables
    * GitLab CI: https://docs.gitlab.com/ci/jobs/job_logs/ ("Custom collapsible
        sections"); `GITLAB_CI`: https://docs.gitlab.com/ci/variables/predefined_variables/
    * Buildkite: https://buildkite.com/docs/pipelines/configure/managing-log-output,
        https://buildkite.com/docs/agent/v3/cli-annotate; `BUILDKITE`:
        https://buildkite.com/docs/pipelines/environment-variables
    * Azure Pipelines: https://learn.microsoft.com/en-us/azure/devops/pipelines/scripts/logging-commands;
        `TF_BUILD`: https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables
    * CircleCI: `CIRCLECI=true`, https://circleci.com/docs/reference/variables/
)

A leaf package: it depends on nothing, so any tool — the task DAG's
reporters, the test runner — can report to a CI service through it. The
environment and file parts are compiled only where they exist: not under
`-betterC`, and the step-summary file append not on WASI.
+/
module sparkles.ci_provider;

import std.range.primitives : put;

// The test-runner markers are UDAs only, imported unconditionally as the
// runner requires; the shim is on this package's import path, never linked.
import sparkles.test_runner.attributes : betterC, wasm;

/// The CI service a process runs under.
enum CiProvider
{
    none,           /// not under CI, or an unrecognized service
    githubActions,  /// `GITHUB_ACTIONS=true`
    gitlabCi,       /// `GITLAB_CI=true`
    buildkite,      /// `BUILDKITE=true`
    azurePipelines, /// `TF_BUILD=True`
    circleCi,       /// `CIRCLECI=true`: recognized, but has no log commands
}

/// An annotation's severity.
enum Severity
{
    error,   ///
    warning, ///
    notice,  /// GitHub's `notice`; Azure has none, and writes a `warning`
}

/**
The provider named by an environment. `lookup(name)` returns a variable's
value, or null when it is unset — $(LREF systemEnvironment) for the real
process, a table in tests. The first match wins, in the order GitHub
Actions, GitLab CI, Buildkite, Azure Pipelines, CircleCI.
*/
CiProvider detectCiProvider(Lookup)(Lookup lookup)
{
    if (lookup("GITHUB_ACTIONS") == "true")
        return CiProvider.githubActions;
    if (lookup("GITLAB_CI") == "true")
        return CiProvider.gitlabCi;
    if (lookup("BUILDKITE") == "true")
        return CiProvider.buildkite;
    if (equalsIgnoringCase(lookup("TF_BUILD"), "true"))
        return CiProvider.azurePipelines;
    if (lookup("CIRCLECI") == "true")
        return CiProvider.circleCi;
    return CiProvider.none;
}

/**
The process environment, as $(LREF detectCiProvider)'s lookup: a borrowed
view of `getenv`'s value, valid until the environment changes. A name of
256 bytes or more reads as unset.
*/
const(char)[] systemEnvironment(scope const(char)[] name) @trusted nothrow @nogc
{
    import core.stdc.stdlib : getenv;
    import core.stdc.string : strlen;

    char[256] z = void;
    if (name.length >= z.length)
        return null;
    z[0 .. name.length] = name[];
    z[name.length] = '\0';
    // `@trusted`: `z` is terminated above; `getenv` returns null or a
    // terminated string it owns.
    const value = getenv(z.ptr);
    return value is null ? null : value[0 .. strlen(value)];
}

/// Whether `provider` collapses output into groups (a heading line is not a
/// group).
bool supportsGroups(CiProvider provider) @safe pure nothrow @nogc
    => provider == CiProvider.githubActions || provider == CiProvider.gitlabCi
        || provider == CiProvider.buildkite || provider == CiProvider.azurePipelines;

/**
A provider's log conventions, ready to write. Copyable; GitLab section ids
come from a counter, so give each output stream one `CiLog`.
*/
struct CiLog
{
    CiProvider provider; ///
    /// GitHub's `$GITHUB_STEP_SUMMARY` file, when set: borrowed from the
    /// lookup that detected it.
    const(char)[] stepSummaryPath;
    /// Unix time in seconds for GitLab section markers; the default reads
    /// the system clock, and tests pin it.
    long function() @safe nothrow @nogc unixTime = &systemUnixTime;

    private uint sections;
    private uint openSection;

    /// The log conventions for the environment `lookup` describes.
    static CiLog detect(Lookup)(Lookup lookup)
    {
        CiLog log;
        log.provider = detectCiProvider(lookup);
        if (log.provider == CiProvider.githubActions)
            log.stepSummaryPath = lookup("GITHUB_STEP_SUMMARY");
        return log;
    }

    /// Whether $(LREF openGroup) collapses (see $(LREF supportsGroups)).
    bool groups() const @safe pure nothrow @nogc => supportsGroups(provider);

    /**
    Opens a group titled `title` — one line. Groups do not nest: open the
    next only after $(LREF closeGroup). `collapsed` applies where the
    provider lets the log choose (GitLab, Buildkite).
    */
    void openGroup(Writer)(ref Writer w, scope const(char)[] title, bool collapsed = true)
    {
        final switch (provider)
        {
            case CiProvider.githubActions:
                put(w, "::group::");
                writeGithubData(w, title);
                break;
            case CiProvider.gitlabCi:
                openSection = ++sections;
                put(w, "\x1b[0Ksection_start:");
                writeDecimal(w, unixTime());
                put(w, ":task_");
                writeDecimal(w, openSection);
                if (collapsed)
                    put(w, "[collapsed=true]");
                put(w, "\r\x1b[0K");
                writeSingleLine(w, title);
                break;
            case CiProvider.buildkite:
                put(w, collapsed ? "--- " : "+++ ");
                writeSingleLine(w, title);
                break;
            case CiProvider.azurePipelines:
                put(w, "##[group]");
                writeSingleLine(w, title);
                break;
            case CiProvider.circleCi:
            case CiProvider.none:
                put(w, "== ");
                writeSingleLine(w, title);
                break;
        }
        put(w, '\n');
    }

    /// Closes the open group; writes nothing where groups have no end.
    void closeGroup(Writer)(ref Writer w)
    {
        final switch (provider)
        {
            case CiProvider.githubActions:
                put(w, "::endgroup::\n");
                break;
            case CiProvider.gitlabCi:
                put(w, "\x1b[0Ksection_end:");
                writeDecimal(w, unixTime());
                put(w, ":task_");
                writeDecimal(w, openSection);
                put(w, "\r\x1b[0K\n");
                break;
            case CiProvider.azurePipelines:
                put(w, "##[endgroup]\n");
                break;
            case CiProvider.buildkite:
            case CiProvider.circleCi:
            case CiProvider.none:
                break;
        }
    }

    /**
    Annotates `file`:`line` with `message`. Where the provider has no
    annotations it writes the plain `file:line: severity: message` line.
    */
    void annotate(Writer)(ref Writer w, Severity severity, scope const(char)[] file, uint line,
        scope const(char)[] message)
    {
        switch (provider)
        {
            case CiProvider.githubActions:
                put(w, "::");
                put(w, severityName(severity));
                put(w, " file=");
                writeGithubProperty(w, file);
                put(w, ",line=");
                writeDecimal(w, line);
                put(w, "::");
                writeGithubData(w, message);
                break;
            case CiProvider.azurePipelines:
                put(w, "##vso[task.logissue type=");
                put(w, severity == Severity.error ? "error" : "warning");
                put(w, ";sourcepath=");
                writeAzureProperty(w, file);
                put(w, ";linenumber=");
                writeDecimal(w, line);
                put(w, "]");
                writeAzureData(w, message);
                break;
            default:
                writeSingleLine(w, file);
                put(w, ':');
                writeDecimal(w, line);
                put(w, ": ");
                put(w, severityName(severity));
                put(w, ": ");
                writeSingleLine(w, message);
                break;
        }
        put(w, '\n');
    }

    /**
    Asks the provider to mask `value` in every later log line; `name` is the
    variable it came from (Azure registers the mask as a secret variable).
    Writes nothing — never the value — where the provider has no masks.
    */
    void mask(Writer)(ref Writer w, scope const(char)[] name, scope const(char)[] value)
    {
        if (value.length == 0)
            return;
        switch (provider)
        {
            case CiProvider.githubActions:
                put(w, "::add-mask::");
                writeGithubData(w, value);
                put(w, '\n');
                break;
            case CiProvider.azurePipelines:
                put(w, "##vso[task.setvariable variable=");
                writeAzureProperty(w, name);
                put(w, ";isSecret=true]");
                writeAzureData(w, value);
                put(w, '\n');
                break;
            default:
                break;
        }
    }

    /// Where a step summary goes.
    StepSummary stepSummary() const @safe pure nothrow @nogc
    {
        if (provider == CiProvider.githubActions && stepSummaryPath.length)
            return StepSummary(StepSummaryKind.file, stepSummaryPath);
        if (provider == CiProvider.buildkite)
            return StepSummary(StepSummaryKind.buildkiteAnnotate);
        return StepSummary(StepSummaryKind.none);
    }

    version (D_BetterC) {} else version (WASI) {} else
    {
        /**
        Appends `markdown` to GitHub's step-summary file. `false` when the
        provider keeps no summary file (see $(LREF stepSummary)) or the append
        failed. Buildkite's summary is a process the caller runs:
        $(LREF buildkiteAnnotateArgv).
        */
        bool appendStepSummary(scope const(char)[] markdown) const @safe
        {
            const target = stepSummary();
            if (target.kind != StepSummaryKind.file)
                return false;
            try
            {
                import std.file : append;

                append(target.path, markdown);
                if (markdown.length && markdown[$ - 1] != '\n')
                    append(target.path, "\n");
                return true;
            }
            catch (Exception)
                return false;
        }
    }
}

/// How a provider takes a step summary.
enum StepSummaryKind
{
    none,              /// the provider has none
    file,              /// append Markdown to `path`
    buildkiteAnnotate, /// run $(LREF buildkiteAnnotateArgv)
}

/// A step-summary target.
struct StepSummary
{
    StepSummaryKind kind; ///
    const(char)[] path;   /// for `StepSummaryKind.file`
}

version (D_BetterC) {} else
{
    /**
    The argv that appends `markdown` to a Buildkite annotation under
    `context`: `buildkite-agent annotate --append --style <style> --context
    <context> <markdown>`. Data only — this package spawns nothing; the caller
    runs it through its own process path (a task-DAG process action).
    */
    string[] buildkiteAnnotateArgv(string markdown, string context, string style = "info") @safe pure nothrow
        => ["buildkite-agent", "annotate", "--append", "--style", style, "--context", context, markdown];
}

// ── writing ─────────────────────────────────────────────────────────────────

private string severityName(Severity severity) @safe pure nothrow @nogc
    => severity == Severity.error ? "error" : severity == Severity.warning ? "warning" : "notice";

// A non-negative-or-negative integer in decimal.
private void writeDecimal(Writer)(ref Writer w, long value)
{
    char[20] digits = void;
    size_t at = digits.length;
    ulong magnitude = value < 0 ? -cast(ulong) value : value;
    do
    {
        digits[--at] = cast(char)('0' + magnitude % 10);
        magnitude /= 10;
    }
    while (magnitude);
    if (value < 0)
        put(w, '-');
    put(w, digits[at .. $]);
}

// A text with any line break folded to a space: a title or plain field must
// stay one line.
private void writeSingleLine(Writer)(ref Writer w, scope const(char)[] text)
{
    foreach (c; text)
    {
        char[1] one = c == '\n' || c == '\r' ? ' ' : c;
        put(w, one[]);
    }
}

// GitHub workflow-command data: `%`, CR, LF escaped.
private void writeGithubData(Writer)(ref Writer w, scope const(char)[] text)
{
    foreach (c; text)
        switch (c)
        {
            case '%': put(w, "%25"); break;
            case '\r': put(w, "%0D"); break;
            case '\n': put(w, "%0A"); break;
            default:
                char[1] one = c;
                put(w, one[]);
        }
}

// GitHub workflow-command property values: data escapes plus `:` and `,`.
private void writeGithubProperty(Writer)(ref Writer w, scope const(char)[] text)
{
    foreach (c; text)
        switch (c)
        {
            case '%': put(w, "%25"); break;
            case '\r': put(w, "%0D"); break;
            case '\n': put(w, "%0A"); break;
            case ':': put(w, "%3A"); break;
            case ',': put(w, "%2C"); break;
            default:
                char[1] one = c;
                put(w, one[]);
        }
}

// Azure logging-command data: `%`, CR, LF escaped (`%AZP25`, `%0D`, `%0A`).
private void writeAzureData(Writer)(ref Writer w, scope const(char)[] text)
{
    foreach (c; text)
        switch (c)
        {
            case '%': put(w, "%AZP25"); break;
            case '\r': put(w, "%0D"); break;
            case '\n': put(w, "%0A"); break;
            default:
                char[1] one = c;
                put(w, one[]);
        }
}

// Azure logging-command property values: data escapes plus `;` and `]`.
private void writeAzureProperty(Writer)(ref Writer w, scope const(char)[] text)
{
    foreach (c; text)
        switch (c)
        {
            case '%': put(w, "%AZP25"); break;
            case '\r': put(w, "%0D"); break;
            case '\n': put(w, "%0A"); break;
            case ';': put(w, "%3B"); break;
            case ']': put(w, "%5D"); break;
            default:
                char[1] one = c;
                put(w, one[]);
        }
}

private long systemUnixTime() @trusted nothrow @nogc
{
    import core.stdc.time : time;

    return cast(long) time(null);
}

private bool equalsIgnoringCase(scope const(char)[] a, scope const(char)[] b) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, c; a)
    {
        const lc = c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c;
        const lb = b[i] >= 'A' && b[i] <= 'Z' ? cast(char)(b[i] + 32) : b[i];
        if (lc != lb)
            return false;
    }
    return true;
}

// ── tests ───────────────────────────────────────────────────────────────────
//
// The fixtures live inside the tests: the runner's extracted `@betterC` and
// `@wasm` builds see a test body and this module's public API, nothing else.

///
@("ci_provider.detectCiProvider.byEnvironment") @betterC @wasm
@safe pure nothrow @nogc
unittest
{
    // An environment of `name=value` pairs.
    static struct Env
    {
        const(string[2])[] vars;

        const(char)[] opCall(scope const(char)[] name) const @safe pure nothrow @nogc
        {
            foreach (ref v; vars)
                if (v[0] == name)
                    return v[1];
            return null;
        }
    }

    static immutable string[2][1] github = [["GITHUB_ACTIONS", "true"]];
    static immutable string[2][1] gitlab = [["GITLAB_CI", "true"]];
    static immutable string[2][1] buildkite = [["BUILDKITE", "true"]];
    static immutable string[2][1] azure = [["TF_BUILD", "True"]];
    static immutable string[2][1] circle = [["CIRCLECI", "true"]];
    static immutable string[2][1] wrongValue = [["GITHUB_ACTIONS", "1"]];
    static immutable string[2][2] summary = [["GITHUB_ACTIONS", "true"], ["GITHUB_STEP_SUMMARY", "/tmp/s.md"]];

    assert(detectCiProvider(Env()) == CiProvider.none);
    assert(detectCiProvider(Env(github[])) == CiProvider.githubActions);
    assert(detectCiProvider(Env(gitlab[])) == CiProvider.gitlabCi);
    assert(detectCiProvider(Env(buildkite[])) == CiProvider.buildkite);
    assert(detectCiProvider(Env(azure[])) == CiProvider.azurePipelines);
    assert(detectCiProvider(Env(circle[])) == CiProvider.circleCi);
    // Only the documented values count.
    assert(detectCiProvider(Env(wrongValue[])) == CiProvider.none);
    assert(!supportsGroups(CiProvider.circleCi) && supportsGroups(CiProvider.buildkite));

    // The step-summary target follows the provider.
    assert(CiLog.detect(Env(summary[])).stepSummary == StepSummary(StepSummaryKind.file, "/tmp/s.md"));
    assert(CiLog.detect(Env(github[])).stepSummary.kind == StepSummaryKind.none, "no file named");
    assert(CiLog.detect(Env(buildkite[])).stepSummary.kind == StepSummaryKind.buildkiteAnnotate);
    assert(CiLog.detect(Env(gitlab[])).stepSummary.kind == StepSummaryKind.none);
    assert(CiLog.detect(Env(azure[])).stepSummary.kind == StepSummaryKind.none);
    assert(CiLog.detect(Env()).stepSummary.kind == StepSummaryKind.none);
}

/// Every provider's groups, annotation (with its escaping), and mask, and
/// that no provider's output contains another's syntax.
@("ci_provider.golden.everyProvider") @betterC @wasm
@safe nothrow @nogc
unittest
{
    // A bounded writer with no runtime behind it.
    static struct Writer
    {
        char[1024] buf;
        size_t length;

        // Byte by byte: a slice copy needs a druntime helper `-betterC` lacks.
        void put(scope const(char)[] s) @safe pure nothrow @nogc
        {
            foreach (c; s)
                buf[length++] = c;
        }

        void put(char c) @safe pure nothrow @nogc { buf[length++] = c; }
    }

    static long pinned() @safe nothrow @nogc => 1_700_000_000;

    static bool contains(scope const(char)[] haystack, scope const(char)[] needle) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. haystack.length + 1)
            if (i + needle.length <= haystack.length && haystack[i .. i + needle.length] == needle)
                return true;
        return false;
    }

    // One of everything, as `provider` writes it.
    static Writer w;
    const(char)[] sample(CiProvider provider) @safe nothrow @nogc
    {
        CiLog log;
        log.provider = provider;
        log.unixTime = &pinned;
        w.length = 0;
        log.openGroup(w, "test:a: failed: exit-status 1");
        w.put("[test:a stdout] boom\n");
        log.closeGroup(w);
        log.annotate(w, Severity.error, "libs/a,b:c.d", 12, "50% done\nsecond line");
        log.mask(w, "GH_TOKEN", "hunter2");
        return w.buf[0 .. w.length];
    }

    assert(sample(CiProvider.githubActions) ==
        "::group::test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "::endgroup::\n"
        ~ "::error file=libs/a%2Cb%3Ac.d,line=12::50%25 done%0Asecond line\n"
        ~ "::add-mask::hunter2\n");

    assert(sample(CiProvider.gitlabCi) ==
        "\x1b[0Ksection_start:1700000000:task_1[collapsed=true]\r\x1b[0Ktest:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "\x1b[0Ksection_end:1700000000:task_1\r\x1b[0K\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n");

    assert(sample(CiProvider.buildkite) ==
        "--- test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n");

    assert(sample(CiProvider.azurePipelines) ==
        "##[group]test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "##[endgroup]\n"
        ~ "##vso[task.logissue type=error;sourcepath=libs/a,b:c.d;linenumber=12]50%AZP25 done%0Asecond line\n"
        ~ "##vso[task.setvariable variable=GH_TOKEN;isSecret=true]hunter2\n");

    enum plain =
        "== test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n";
    assert(sample(CiProvider.none) == plain);
    assert(sample(CiProvider.circleCi) == plain);

    // Each provider's markers; a provider's output may contain only its own.
    static immutable string[4] githubMarkers = ["::group::", "::endgroup::", "::error", "::add-mask::"];
    static immutable string[2] gitlabMarkers = ["section_start:", "section_end:"];
    static immutable string[2] buildkiteMarkers = ["--- ", "+++ "];
    static immutable string[3] azureMarkers = ["##[group]", "##[endgroup]", "##vso["];
    static immutable CiProvider[6] all = [CiProvider.none, CiProvider.githubActions, CiProvider.gitlabCi,
        CiProvider.buildkite, CiProvider.azurePipelines, CiProvider.circleCi];
    foreach (provider; all)
    {
        const text = sample(provider);
        if (provider != CiProvider.githubActions)
            foreach (m; githubMarkers)
                assert(!contains(text, m));
        if (provider != CiProvider.gitlabCi)
            foreach (m; gitlabMarkers)
                assert(!contains(text, m));
        if (provider != CiProvider.buildkite)
            foreach (m; buildkiteMarkers)
                assert(!contains(text, m));
        if (provider != CiProvider.azurePipelines)
            foreach (m; azureMarkers)
                assert(!contains(text, m));
        if (provider != CiProvider.githubActions && provider != CiProvider.azurePipelines)
            assert(!contains(text, "hunter2"), "no mask command, so the value is never written");
    }
}

@("ci_provider.systemEnvironment.readsTheProcess")
@system
unittest
{
    import core.sys.posix.stdlib : setenv, unsetenv;

    assert(setenv("SPARKLES_CI_PROVIDER_PROBE", "on", 1) == 0);
    scope (exit)
        unsetenv("SPARKLES_CI_PROVIDER_PROBE");
    assert(systemEnvironment("SPARKLES_CI_PROVIDER_PROBE") == "on");
    assert(systemEnvironment("SPARKLES_CI_PROVIDER_UNSET_PROBE") is null);
}

@("ci_provider.buildkiteAnnotateArgv.isData")
@safe pure nothrow
unittest
{
    assert(buildkiteAnnotateArgv("**ok**", "ci") == ["buildkite-agent", "annotate", "--append",
        "--style", "info", "--context", "ci", "**ok**"]);
}

@("ci_provider.CiLog.appendStepSummary.appendsLines")
@system
unittest
{
    import std.conv : to;
    import std.file : exists, readText, remove, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    const path = tempDir.buildPath("sparkles-ci-provider-" ~ thisProcessID.to!string ~ ".md");
    scope (exit)
        if (path.exists)
            remove(path);
    CiLog log;
    log.provider = CiProvider.githubActions;
    log.stepSummaryPath = path;
    assert(log.appendStepSummary("# ci"));
    assert(log.appendStepSummary("- a: failed\n"));
    assert(readText(path) == "# ci\n- a: failed\n");

    CiLog none;
    assert(!none.appendStepSummary("x"), "no summary file without a provider that keeps one");
}
