/++
CI-provider log conventions
([SPEC §7.6](../../../../../docs/specs/build-primitives/task-dag/SPEC.md)):
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
    $(TR $(TD Buildkite) $(TD `--- <title>`) $(TD plain) $(TD none) $(TD `buildkite-agent annotate`))
    $(TR $(TD Azure Pipelines) $(TD `##[group]`/`##[endgroup]`) $(TD `##vso[task.logissue …]`)
        $(TD `##vso[task.setvariable …;issecret=true]`) $(TD none))
    $(TR $(TD CircleCI, none) $(TD a heading line) $(TD plain) $(TD none) $(TD none))
)

No dependency on the task DAG: any tool that reports to a CI service may
use it.
+/
module sparkles.build_primitives.ci_provider;

import std.range.primitives : put;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : WireCase;
import sparkles.base.text.writers : writeValue;

/// The CI service a process runs under.
@WireCase(CaseStyle.kebabCase)
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
@WireCase(CaseStyle.kebabCase)
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

/// The process environment, as $(LREF detectCiProvider)'s lookup: a
/// borrowed view of `getenv`'s value, valid until the environment changes.
const(char)[] systemEnvironment(scope const(char)[] name) @trusted nothrow @nogc
{
    import core.stdc.stdlib : getenv;
    import sparkles.base.text.cstring : CStr, toTempStringz;

    auto z = name.toTempStringz;
    // `@trusted`: `getenv` returns null or a terminated string it owns.
    return CStr.fromStringz(getenv(z.ptr))[];
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
    /// GitHub's `$GITHUB_STEP_SUMMARY` file, when set.
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
            log.stepSummaryPath = lookup("GITHUB_STEP_SUMMARY").idupOrNull;
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
                writeValue(w, unixTime());
                put(w, ":task_");
                writeValue(w, openSection);
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
                writeValue(w, unixTime());
                put(w, ":task_");
                writeValue(w, openSection);
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
                put(w, severity == Severity.error ? "error" : severity == Severity.warning ? "warning" : "notice");
                put(w, " file=");
                writeGithubProperty(w, file);
                put(w, ",line=");
                writeValue(w, line);
                put(w, "::");
                writeGithubData(w, message);
                break;
            case CiProvider.azurePipelines:
                put(w, "##vso[task.logissue type=");
                put(w, severity == Severity.error ? "error" : "warning");
                put(w, ";sourcepath=");
                writeAzureProperty(w, file);
                put(w, ";linenumber=");
                writeValue(w, line);
                put(w, ";]");
                writeAzureData(w, message);
                break;
            default:
                writeSingleLine(w, file);
                put(w, ':');
                writeValue(w, line);
                put(w, ": ");
                put(w, severity == Severity.error ? "error" : severity == Severity.warning ? "warning" : "notice");
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
                put(w, ";issecret=true]");
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

    /**
    Appends `markdown` to GitHub's step-summary file. `false` when the
    provider keeps no summary file (see $(LREF stepSummary)) or the append
    failed.
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

/// How a provider takes a step summary.
@WireCase(CaseStyle.kebabCase)
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

/**
The argv that appends `markdown` to a Buildkite annotation under `context`:
`buildkite-agent annotate --append --style <style> --context <context>
<markdown>`. The caller runs it, as it runs any subprocess.
*/
string[] buildkiteAnnotateArgv(string markdown, string context, string style = "info") @safe pure nothrow
    => ["buildkite-agent", "annotate", "--append", "--style", style, "--context", context, markdown];

// ── escaping ────────────────────────────────────────────────────────────────

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

private string idupOrNull(scope const(char)[] s) @safe pure nothrow => s.length ? s.idup : null;

// ── tests ───────────────────────────────────────────────────────────────────

version (unittest)
{
    import sparkles.base.buffer : checkWriter;

    // An environment of `name=value` pairs.
    private struct FakeEnv
    {
        string[2][] vars;

        const(char)[] opCall(scope const(char)[] name) const @safe pure nothrow @nogc
        {
            foreach (ref v; vars)
                if (v[0] == name)
                    return v[1];
            return null;
        }
    }

    private long fixedTime() @safe nothrow @nogc => 1_700_000_000;

    private CiLog logFor(CiProvider provider) @safe pure nothrow @nogc
    {
        CiLog log;
        log.provider = provider;
        log.unixTime = &fixedTime;
        return log;
    }

    // One of everything, as a provider writes it.
    private void writeSampler(Writer)(ref Writer w, CiProvider provider)
    {
        auto log = logFor(provider);
        log.openGroup(w, "test:a: failed: exit-status 1");
        put(w, "[test:a stdout] boom\n");
        log.closeGroup(w);
        log.annotate(w, Severity.error, "libs/a,b:c.d", 12, "50% done\nsecond line");
        log.mask(w, "GH_TOKEN", "hunter2");
    }
}

///
@("build_primitives.ci_provider.detectCiProvider.byEnvironment")
@safe pure nothrow
unittest
{
    assert(detectCiProvider(FakeEnv()) == CiProvider.none);
    assert(detectCiProvider(FakeEnv([["GITHUB_ACTIONS", "true"]])) == CiProvider.githubActions);
    assert(detectCiProvider(FakeEnv([["GITLAB_CI", "true"]])) == CiProvider.gitlabCi);
    assert(detectCiProvider(FakeEnv([["BUILDKITE", "true"]])) == CiProvider.buildkite);
    assert(detectCiProvider(FakeEnv([["TF_BUILD", "True"]])) == CiProvider.azurePipelines);
    assert(detectCiProvider(FakeEnv([["CIRCLECI", "true"]])) == CiProvider.circleCi);
    // Only the documented values count.
    assert(detectCiProvider(FakeEnv([["GITHUB_ACTIONS", "1"]])) == CiProvider.none);
    assert(!supportsGroups(CiProvider.circleCi) && supportsGroups(CiProvider.buildkite));
}

@("build_primitives.ci_provider.CiLog.detect.stepSummaryTargets")
@safe
unittest
{
    const github = CiLog.detect(FakeEnv([["GITHUB_ACTIONS", "true"], ["GITHUB_STEP_SUMMARY", "/tmp/s.md"]]));
    assert(github.stepSummary == StepSummary(StepSummaryKind.file, "/tmp/s.md"));
    const buildkite = CiLog.detect(FakeEnv([["BUILDKITE", "true"]]));
    assert(buildkite.stepSummary.kind == StepSummaryKind.buildkiteAnnotate);
    assert(buildkiteAnnotateArgv("**ok**", "ci") == ["buildkite-agent", "annotate", "--append",
        "--style", "info", "--context", "ci", "**ok**"]);
    foreach (provider; [CiProvider.gitlabCi, CiProvider.azurePipelines, CiProvider.circleCi, CiProvider.none])
        assert(logFor(provider).stepSummary.kind == StepSummaryKind.none);
    assert(!logFor(CiProvider.none).appendStepSummary("x"));
}

@("build_primitives.ci_provider.CiLog.appendStepSummary.appendsLines")
@safe
unittest
{
    import std.file : readText;
    import std.path : buildPath;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create();
    const path = tmp.dir.buildPath("summary.md");
    const log = CiLog.detect(FakeEnv([["GITHUB_ACTIONS", "true"], ["GITHUB_STEP_SUMMARY", path]]));
    assert(log.appendStepSummary("# ci"));
    assert(log.appendStepSummary("- a: failed\n"));
    assert(readText(path) == "# ci\n- a: failed\n");
}

@("build_primitives.ci_provider.golden.githubActions")
@safe nothrow @nogc
unittest
{
    checkWriter!((ref b) => writeSampler(b, CiProvider.githubActions))(
        "::group::test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "::endgroup::\n"
        ~ "::error file=libs/a%2Cb%3Ac.d,line=12::50%25 done%0Asecond line\n"
        ~ "::add-mask::hunter2\n");
}

@("build_primitives.ci_provider.golden.gitlabCi")
@safe nothrow @nogc
unittest
{
    checkWriter!((ref b) => writeSampler(b, CiProvider.gitlabCi))(
        "\x1b[0Ksection_start:1700000000:task_1[collapsed=true]\r\x1b[0Ktest:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "\x1b[0Ksection_end:1700000000:task_1\r\x1b[0K\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n");
}

@("build_primitives.ci_provider.golden.buildkite")
@safe nothrow @nogc
unittest
{
    checkWriter!((ref b) => writeSampler(b, CiProvider.buildkite))(
        "--- test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n");
}

@("build_primitives.ci_provider.golden.azurePipelines")
@safe nothrow @nogc
unittest
{
    checkWriter!((ref b) => writeSampler(b, CiProvider.azurePipelines))(
        "##[group]test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "##[endgroup]\n"
        ~ "##vso[task.logissue type=error;sourcepath=libs/a,b:c.d;linenumber=12;]50%AZP25 done%0Asecond line\n"
        ~ "##vso[task.setvariable variable=GH_TOKEN;issecret=true]hunter2\n");
}

@("build_primitives.ci_provider.golden.plainFallback")
@safe nothrow @nogc
unittest
{
    enum plain =
        "== test:a: failed: exit-status 1\n"
        ~ "[test:a stdout] boom\n"
        ~ "libs/a,b:c.d:12: error: 50% done second line\n";
    checkWriter!((ref b) => writeSampler(b, CiProvider.none))(plain);
    checkWriter!((ref b) => writeSampler(b, CiProvider.circleCi))(plain);
}

@("build_primitives.ci_provider.golden.noProviderEmitsAnothersSyntax")
@safe
unittest
{
    import std.algorithm.searching : canFind;
    import std.array : appender;

    // Each provider's own markers; a provider's output may contain only its own.
    static immutable string[][CiProvider.max + 1] markers = [
        CiProvider.none: [],
        CiProvider.githubActions: ["::group::", "::endgroup::", "::error", "::add-mask::"],
        CiProvider.gitlabCi: ["section_start:", "section_end:"],
        CiProvider.buildkite: ["--- ", "+++ "],
        CiProvider.azurePipelines: ["##[group]", "##[endgroup]", "##vso["],
        CiProvider.circleCi: [],
    ];
    foreach (provider; [CiProvider.none, CiProvider.githubActions, CiProvider.gitlabCi,
        CiProvider.buildkite, CiProvider.azurePipelines, CiProvider.circleCi])
    {
        auto w = appender!string;
        writeSampler(w, provider);
        foreach (other, ownMarkers; markers)
            if (other != provider)
                foreach (marker; ownMarkers)
                    assert(!w[].canFind(marker), "a provider wrote another's syntax");
        if (provider != CiProvider.githubActions && provider != CiProvider.azurePipelines)
            assert(!w[].canFind("hunter2"), "no mask command, so the value is never written");
    }
}
