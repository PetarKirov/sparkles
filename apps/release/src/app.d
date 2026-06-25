/++
`release` — automate the middle of the sparkles release process.

Scans git tags (as SemVer), summarizes the commits since the latest one, suggests
a SemVer bump from the conventional commits, gathers the release notes (your
`$EDITOR` or a CLI LLM agent), and then carries the release as far as `--stage`
allows: a local annotated tag (default), a pushed tag, a draft GitHub release, or
a published one.

See `docs/guidelines/release.md` for the policy this encodes.

Usage:
    release [--stage=create-tag|push-tag|create-gh-release-draft|publish-gh-release]
            [--auto] [--agent=<key>] [--bump=major|minor|patch]
            [--notes=manual|agent] [--no-verify] [--log-level=<level>]
+/
module sparkles.release.app;

import std.stdio : writeln, write, stdout;
import std.typecons : Nullable;

import sparkles.base.logger : initLogger, LogLevel, info, warning, error;
import sparkles.base.term_style : Style, stylize;
import sparkles.core_cli.args : parseCliArgs, CliOption, HelpInfo;
import sparkles.core_cli.process_utils : isInPath, runCaptured;
import sparkles.core_cli.ui.box : drawBox, BoxProps;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.agents : AgentSpec, availableAgents, buildAgentPrompt, findAgent, runAgent;
import sparkles.release.bump : applyBump, BumpKind, parseBumpKind, suggestBump;
import sparkles.release.conventional : CommitType;
import sparkles.release.git : authorCounts, createAnnotatedTag, currentBranch, diffStat, latestTag, listTags, logRange, logStatRange, numstat, pushTag, repoRoot;
import sparkles.release.notes : openInEditor, seedEditorBuffer, seedReviewBuffer, stripComments;
import sparkles.release.preflight : runPreflight, PreflightResult;
import sparkles.release.result : Result;
import sparkles.release.stages : Stage, parseStage, stageAtLeast, stageToken;
import sparkles.release.stats : tallyCommits, typeCounts, ReleaseStats, Commit, AuthorCount, FileStat, AreaStat, areaBreakdown;

/// CLI options (validated string fields for the hyphenated/closed vocabularies;
/// only `--log-level` is a real enum, which getopt binds directly).
struct CliParams
{
    @CliOption(`s|stage`,
        "Cumulative stage: create-tag (default), push-tag, "
        ~ "create-gh-release-draft, publish-gh-release. Each implies the earlier ones.")
    string stage = "create-tag";

    @CliOption(`a|auto`,
        "Non-interactive: take the suggested bump and run the agent for notes "
        ~ "without opening $EDITOR.")
    bool auto_;

    @CliOption(`g|agent`,
        "CLI LLM agent key for agent notes (claude-code, codex, gemini, ...). "
        ~ "Only agents found on PATH are offered.")
    string agent;

    @CliOption(`b|bump`, "Override the suggested bump: major, minor, or patch.")
    string bump;

    @CliOption(`n|notes`,
        "Release-notes mode: manual (open $EDITOR) or agent (LLM summary).")
    string notes;

    @CliOption(`N|no-verify`, "Skip the pre-flight checks (clean tree, on main, ci tests).")
    bool noVerify;

    @CliOption(`L|log-level`, "trace, info, warning, error (default info).")
    LogLevel logLevel = LogLevel.info;
}

int main(string[] args)
{
    auto parseArgs = args.dup;
    auto cli = parseArgs.parseCliArgs!CliParams(HelpInfo(
        "release",
        "Scan tags, summarize commits, suggest a bump, write notes, tag and publish.",
    ));
    initLogger(cli.logLevel);

    try
        return run(cli);
    catch (Exception e)
    {
        error(i"$(e.msg)");
        return 1;
    }
}

private int run(CliParams cli)
{
    // ----- validate the closed-vocabulary options up front -----
    auto stage = parseStage(cli.stage);
    if (stage.isNull)
        return fail("unknown --stage `" ~ cli.stage
            ~ "` (create-tag, push-tag, create-gh-release-draft, publish-gh-release)");

    Nullable!BumpKind bumpOverride;
    if (cli.bump.length)
    {
        bumpOverride = parseBumpKind(cli.bump);
        if (bumpOverride.isNull)
            return fail("unknown --bump `" ~ cli.bump ~ "` (major, minor, patch)");
    }

    auto notesMode = resolveNotesMode(cli);
    if (notesMode.isNull)
        return fail("--notes=manual is incompatible with --auto (manual needs $EDITOR)");

    // ----- locate the latest tag and the commit range -----
    auto tagsR = listTags();
    if (tagsR.hasError)
        return fail(tagsR.error);
    const latest = latestTag(tagsR.value);
    const firstRelease = latest.isNull;
    const fromRef = firstRelease ? "" : latest.get.tag;
    const rangeLabel = firstRelease ? "(initial release)" : latest.get.tag ~ "..HEAD";

    auto commitsR = logRange(fromRef, "HEAD");
    if (commitsR.hasError)
        return fail(commitsR.error);
    auto commits = commitsR.value;
    if (commits.length == 0)
    {
        const since = firstRelease ? "the initial commit" : latest.get.tag;
        info(i"No commits since $(since); nothing to release.");
        return 0;
    }

    // ----- gather and render stats -----
    auto rs = buildStats(commits, fromRef);
    if (rs.hasError)
        return fail(rs.error);
    renderStats(rs.value, rangeLabel);

    // ----- decide the next version -----
    const current = firstRelease ? SemVer(major: 0, minor: 0, patch: 0)
        : latest.get.version_;
    auto kind = firstRelease ? BumpKind.minor : suggestBump(rs.value.tally, current);
    if (!bumpOverride.isNull)
        kind = bumpOverride.get;
    else if (!cli.auto_)
        kind = promptBump(kind);
    const next = applyBump(current, kind);
    const tag = "v" ~ verStr(next);
    const suggestedSubject = tag ~ " — ";

    writeln();
    writeln("Next version: " ~ stylize(tag, Style.green));
    stdout.flush();

    // ----- fail fast if a GitHub stage is requested but unusable -----
    if (auto e = checkGhReady(stage.get))
        return fail(e);

    // ----- pre-flight (before any tag is created) -----
    if (!cli.noVerify)
    {
        info(i"Running pre-flight checks (clean tree, on main, ci --test, ci --verify)…");
        const root = repoRoot();
        auto result = runPreflight(root.hasValue ? root.value : ".");
        if (!result.ok)
        {
            writeln(drawBox(result.failures, "Pre-flight failed"));
            return fail("pre-flight checks failed; fix them or pass --no-verify");
        }
        info(i"Pre-flight checks passed.");
    }
    else
        warning(i"Skipping pre-flight checks (--no-verify).");

    // ----- acquire the release notes (the annotated-tag body) -----
    auto notesR = acquireNotes(cli, notesMode.get, suggestedSubject, fromRef);
    if (notesR.hasError)
        return fail(notesR.error);
    const notesBody = notesR.value;
    if (notesBody.length == 0)
    {
        info(i"Empty release notes; aborting (no tag created).");
        return 0;
    }

    // ----- execute the chosen stages -----
    return executeStages(stage.get, tag, notesBody);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

private Result!ReleaseStats buildStats(Commit[] commits, string fromRef) @safe
{
    import sparkles.release.result : success, failure;

    const tally = tallyCommits(commits);
    const tc = typeCounts(commits);

    size_t filesChanged = 0;
    size_t insertions = 0;
    size_t deletions = 0;
    auto ds = diffStat(fromRef, "HEAD");
    if (ds.hasValue)
    {
        filesChanged = ds.value.filesChanged;
        insertions = ds.value.insertions;
        deletions = ds.value.deletions;
    }

    AuthorCount[] authors;
    auto authorsR = authorCounts(fromRef, "HEAD");
    if (authorsR.hasValue)
        authors = authorsR.value;

    AreaStat[] areas;
    auto files = numstat(fromRef, "HEAD");
    if (files.hasValue)
        areas = areaBreakdown(files.value, expandableAreas);

    return success(ReleaseStats(
        commitCount: commits.length,
        filesChanged: filesChanged,
        insertions: insertions,
        deletions: deletions,
        authors: authors,
        typeCounts: tc,
        breakingCount: tally.breaking,
        tally: tally,
        areas: areas,
    ));
}

/// Top-level directories whose change breakdown is shown one level deeper.
private enum string[] expandableAreas = ["apps", "libs", "docs"];

private void renderStats(in ReleaseStats rs, string rangeLabel)
{
    import std.conv : text;

    writeln();
    writeln(drawHeader("Release range: " ~ rangeLabel,
        HeaderProps(style: HeaderStyle.banner)));

    string[][] overview = [
        ["Commits", rs.commitCount.text],
        ["Files changed", rs.filesChanged.text],
        ["Insertions", "+" ~ rs.insertions.text],
        ["Deletions", "-" ~ rs.deletions.text],
        ["Authors", rs.authors.length.text],
        ["Breaking changes", rs.breakingCount.text],
    ];
    writeln(drawTable(overview));

    // Conventional-commit type breakdown (only non-zero rows).
    string[][] types = [["Type", "Count"]];
    static foreach (t; __traits(allMembers, CommitType))
        if (rs.typeCounts[__traits(getMember, CommitType, t)] > 0)
            types ~= [t, rs.typeCounts[__traits(getMember, CommitType, t)].text];
    if (types.length > 1)
    {
        writeln();
        writeln(drawTable(types));
    }

    if (rs.areas.length)
    {
        string[][] areaRows = [["Area", "Changed"]];
        foreach (a; rs.areas)
        {
            const indent = a.depth ? "  " : "";
            areaRows ~= [
                indent ~ a.label,
                "+" ~ a.insertions.text ~ " / -" ~ a.deletions.text,
            ];
        }
        writeln();
        writeln(drawTable(areaRows));
    }

    if (rs.authors.length)
    {
        string[] lines;
        foreach (a; rs.authors)
            lines ~= a.name ~ " (" ~ a.commits.text ~ ")";
        writeln();
        writeln(drawBox(lines, "Authors"));
    }
    stdout.flush();
}

// ---------------------------------------------------------------------------
// Notes acquisition
// ---------------------------------------------------------------------------

private enum NotesMode { manual, agent }

private Nullable!NotesMode resolveNotesMode(in CliParams cli) @safe pure nothrow @nogc
{
    Nullable!NotesMode m;
    if (cli.notes == "manual")
    {
        if (cli.auto_)
            return m;                        // null ⇒ conflict
        m = NotesMode.manual;
    }
    else if (cli.notes == "agent")
        m = NotesMode.agent;
    else
        m = cli.auto_ ? NotesMode.agent : NotesMode.manual;
    return m;
}

private Result!string acquireNotes(
    in CliParams cli, NotesMode mode, string suggestedSubject, string fromRef)
{
    import sparkles.release.result : success, failure;

    auto logStatR = logStatRange(fromRef, "HEAD");
    const logStat = logStatR.hasValue ? logStatR.value : "";

    if (mode == NotesMode.manual)
    {
        auto edited = openInEditor(seedEditorBuffer(suggestedSubject, logStat));
        if (edited.hasError)
            return edited;
        return success(stripComments(edited.value));
    }

    // Agent mode.
    auto specR = pickAgent(cli);
    if (specR.hasError)
        return failure!string(specR.error);
    const spec = specR.value;
    info(i"Summarizing $(spec.key) → release notes…");

    auto generated = runAgent(spec, buildAgentPrompt(suggestedSubject, fromRef ~ "..HEAD", logStat));
    if (generated.hasError)
        return generated;

    if (cli.auto_)
        return success(generated.value);     // verbatim; non-empty checked by runAgent

    // Interactive: let the user review/edit the agent output.
    auto edited = openInEditor(seedReviewBuffer(generated.value));
    if (edited.hasError)
        return edited;
    return success(stripComments(edited.value));
}

private Result!(AgentSpec) pickAgent(in CliParams cli)
{
    import sparkles.release.result : success, failure;

    auto avail = availableAgents();

    if (cli.agent.length)
    {
        auto spec = findAgent(cli.agent);
        if (spec is null)
            return failure!AgentSpec("unknown agent `" ~ cli.agent ~ "`");
        if (!isInPath(spec.binary))
            return failure!AgentSpec(
                "agent `" ~ cli.agent ~ "` (" ~ spec.binary ~ ") is not on PATH");
        return success(cast(AgentSpec) *spec);
    }

    if (avail.length == 0)
        return failure!AgentSpec("no CLI LLM agents found on PATH");

    if (cli.auto_)
    {
        if (avail.length == 1)
            return success(cast(AgentSpec) avail[0]);
        return failure!AgentSpec(
            "--auto needs --agent; available: " ~ agentKeys(avail));
    }

    return success(cast(AgentSpec) promptAgent(avail));
}

// ---------------------------------------------------------------------------
// Stage execution
// ---------------------------------------------------------------------------

private int executeStages(Stage chosen, string tag, string notesBody)
{
    import std.conv : text;
    import std.file : tempDir, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    // The annotated-tag body lives in a temp file passed to `git tag -F`.
    const notesPath = buildPath(tempDir, "sparkles-release-notes-" ~ thisProcessID.text ~ ".txt");
    write(notesPath, notesBody);
    scope (exit)
        removeQuietly(notesPath);

    auto tagR = createAnnotatedTag(tag, notesPath);
    if (tagR.hasError)
        return fail(tagR.error);
    info(i"Created annotated tag $(tag).");

    if (stageAtLeast(chosen, Stage.pushTag))
    {
        auto pushR = pushTag(tag);
        if (pushR.hasError)
            return fail("tag created locally but push failed: " ~ pushR.error
                ~ "\nRetry with: git push origin " ~ tag);
        info(i"Pushed $(tag) to origin.");
    }

    if (stageAtLeast(chosen, Stage.createGhReleaseDraft))
    {
        auto r = runCaptured(["gh", "release", "create", tag, "--draft", "--notes-from-tag"]);
        if (r.status != 0)
            return fail("gh release draft failed: " ~ r.stderr);
        info(i"Created draft GitHub release for $(tag).");
    }

    if (stageAtLeast(chosen, Stage.publishGhRelease))
    {
        auto r = runCaptured(["gh", "release", "edit", tag, "--draft=false"]);
        if (r.status != 0)
            return fail("gh release publish failed: " ~ r.stderr);
        info(i"Published GitHub release for $(tag) (notify-dub-registry will fire).");
    }

    return 0;
}

/// Returns an error string if `stage` needs `gh` but it is missing or unauthenticated.
private string checkGhReady(Stage stage)
{
    if (!stageAtLeast(stage, Stage.createGhReleaseDraft))
        return null;
    if (!isInPath("gh"))
        return "stage `" ~ stageToken(stage) ~ "` needs the `gh` CLI, which is not on PATH";
    auto auth = runCaptured(["gh", "auth", "status"]);
    if (auth.status != 0)
        return "`gh` is not authenticated (run `gh auth login`)";
    return null;
}

// ---------------------------------------------------------------------------
// Interactive prompts
// ---------------------------------------------------------------------------

private BumpKind promptBump(BumpKind suggested)
{
    import std.string : strip, toLower;

    const def = bumpName(suggested);
    auto answer = ask("Version bump [" ~ def ~ "] (major/minor/patch): ").strip.toLower;
    if (answer.length == 0)
        return suggested;
    auto parsed = parseBumpKind(answer);
    return parsed.isNull ? suggested : parsed.get;
}

private AgentSpec promptAgent(const(AgentSpec)[] avail)
{
    import std.conv : text, to;
    import std.string : strip;

    writeln("Available agents:");
    foreach (i, a; avail)
        writeln("  " ~ (i + 1).text ~ ") " ~ a.key ~ " (" ~ a.binary ~ ")");

    while (true)
    {
        auto answer = ask("Choose an agent [1]: ").strip;
        if (answer.length == 0)
            return cast(AgentSpec) avail[0];
        try
        {
            const n = answer.to!size_t;
            if (n >= 1 && n <= avail.length)
                return cast(AgentSpec) avail[n - 1];
        }
        catch (Exception)
        {
        }
        writeln("Please enter a number between 1 and " ~ avail.length.text ~ ".");
    }
}

private string ask(string prompt)
{
    import std.stdio : readln;
    import std.string : strip;

        write(prompt);
        stdout.flush();
    auto line = readln();
    return line is null ? "" : line.strip.idup;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

private int fail(string message) @safe
{
    error(i"$(message)");
    return 1;
}

private void removeQuietly(string path) @safe nothrow
{
    import std.file : remove;

    try
        remove(path);
    catch (Exception)
    {
    }
}

private string verStr(in SemVer v) @safe
{
    import std.array : appender;

    auto w = appender!string;
    v.toString(w);
    return w[];
}

private string bumpName(BumpKind k) @safe pure nothrow @nogc
{
    final switch (k)
    {
        case BumpKind.major: return "major";
        case BumpKind.minor: return "minor";
        case BumpKind.patch: return "patch";
    }
}

private string agentKeys(const(AgentSpec)[] specs) @safe
{
    import std.algorithm.iteration : map;
    import std.array : join;

    return specs.map!(a => a.key).join(", ");
}
