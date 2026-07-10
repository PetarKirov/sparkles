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
import sparkles.core_cli.term_caps : detectTermCaps;
import sparkles.core_cli.ui.box : drawBox, BoxProps;
import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.core_cli.ui.live : LiveRegion, stdoutLiveRegion;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.ui.tasklist : TaskReporter;
import sparkles.core_cli.ui.theme : makeTheme, Theme;
import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.agents : AgentSpec, availableAgents, buildAgentPrompt, findAgent, runAgent;
import sparkles.release.bump : applyBump, BumpKind, parseBumpKind, suggestBump;
import sparkles.release.conventional : CommitType;
import sparkles.release.git : authorCounts, createAnnotatedTag, currentBranch, diffStat, latestTag, listTags, logRange, logStatRange, numstat, pushTag, repoRoot;
import sparkles.release.notes : openInEditor, seedEditorBuffer, seedReviewBuffer, stripComments;
import sparkles.release.preflight : runPreflight, PreflightProgress, PreflightResult;
import sparkles.release.result : Result;
import sparkles.release.stages : Stage, parseStage, stageAtLeast, stageToken;
import sparkles.release.stats : tallyCommits, typeCounts, ReleaseStats, Commit, CommitTally, AuthorCount, FileStat, AreaStat, areaBreakdown;

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
    const theme = makeTheme(detectTermCaps());

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
    else
        kind = promptBump(kind, current, rs.value.tally, cli.auto_, theme);
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
        writeln();
        writeln(drawHeader("Pre-flight"));
        stdout.flush();
        if (!runPreflightChecklist(theme))
            return fail("pre-flight checks failed; fix them or pass --no-verify");
    }
    else
        warning(i"Skipping pre-flight checks (--no-verify).");

    // ----- acquire the release notes (the annotated-tag body) -----
    auto notesR = acquireNotes(cli, notesMode.get, suggestedSubject, fromRef, theme);
    if (notesR.hasError)
        return fail(notesR.error);
    const notesBody = notesR.value;
    if (notesBody.length == 0)
    {
        info(i"Empty release notes; aborting (no tag created).");
        return 0;
    }

    // ----- confirm before anything outward-facing (push, GitHub release) -----
    if (stageAtLeast(stage.get, Stage.pushTag))
    {
        import sparkles.core_cli.prompts : confirm, PromptPolicy, stdioPromptIo;

        auto go = confirm(
            "About to " ~ describeOutwardStages(stage.get, tag) ~ ". Proceed?",
            defaultYes: true,
            policy: cli.auto_ ? PromptPolicy.takeDefault : PromptPolicy.interactive,
            io: stdioPromptIo(),
            theme: theme);
        if (go.hasError)
            return fail(go.error);
        if (!go.value)
        {
            info(i"Aborted before any outward stage; no tag was created.");
            return 0;
        }
    }

    // ----- execute the chosen stages -----
    const rc = executeStages(stage.get, tag, notesBody, theme);
    if (rc == 0)
        printReceipt(stage.get, tag, notesBody, theme);
    return rc;
}

/// The outward-facing part of the pipeline, for the confirm gate: what will
/// leave this machine if the user proceeds.
private string describeOutwardStages(Stage stage, string tag) @safe pure
{
    string s = "push " ~ tag ~ " to origin";
    if (stageAtLeast(stage, Stage.publishGhRelease))
        s ~= " and publish a GitHub release (notify-dub-registry fires)";
    else if (stageAtLeast(stage, Stage.createGhReleaseDraft))
        s ~= " and create a draft GitHub release";
    return s;
}

/// Runs the pre-flight checks as a live checklist: each check is a task row,
/// `ci` output lines pulse the spinner, and failures graduate with their
/// detail (e.g. the test output tail) as follow-up lines. Returns overall ok.
private bool runPreflightChecklist(in Theme theme)
{
    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish();
    auto tasks = TaskReporter(&region, theme);

    size_t[string] ids;
    auto progress = PreflightProgress(
        started: (string label) {
            const id = tasks.add(label);
            ids[label] = id;
            tasks.start(id);
        },
        finished: (string label, bool ok, string detail) {
            if (auto id = label in ids)
                ok ? tasks.succeed(*id) : tasks.fail(*id, detail);
        },
        output: (scope const(char)[]) { tasks.tick(); },
    );

    const root = repoRoot();
    return runPreflight(root.hasValue ? root.value : ".", progress).ok;
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
    import sparkles.base.text.width : Align;
    import sparkles.core_cli.term_caps : terminalSize;
    import sparkles.core_cli.ui.table : TableProps;

    // Numbers right-align; every table caps at the terminal width (0 = no cap
    // when piped); titles ride the frame instead of a separate banner line.
    const cap = terminalSize().width;
    const numeric = [Align.left, Align.right];

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
    writeln(drawTable(overview,
        TableProps(title: "Overview", columnAligns: numeric.dup, maxWidth: cap)));

    // Conventional-commit type breakdown (only non-zero rows).
    string[][] types = [["Type", "Count"]];
    static foreach (t; __traits(allMembers, CommitType))
        if (rs.typeCounts[__traits(getMember, CommitType, t)] > 0)
            types ~= [t, rs.typeCounts[__traits(getMember, CommitType, t)].text];
    if (types.length > 1)
    {
        writeln();
        writeln(drawTable(types, TableProps(title: "Commits by type",
            headerRows: 1, columnAligns: numeric.dup, maxWidth: cap)));
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
        writeln(drawTable(areaRows, TableProps(title: "Changed by area",
            headerRows: 1, columnAligns: numeric.dup, maxWidth: cap)));
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
    in CliParams cli, NotesMode mode, string suggestedSubject, string fromRef,
    in Theme theme)
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
    auto specR = pickAgent(cli, theme);
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

private Result!(AgentSpec) pickAgent(in CliParams cli, in Theme theme)
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

    return success(cast(AgentSpec) promptAgent(avail, theme));
}

// ---------------------------------------------------------------------------
// Stage execution
// ---------------------------------------------------------------------------

private int executeStages(Stage chosen, string tag, string notesBody, in Theme theme)
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

    writeln();
    writeln(drawHeader("Release " ~ tag ~ " · --stage=" ~ stageToken(chosen)));
    stdout.flush();

    auto region = stdoutLiveRegion();
    scope (exit)
        region.finish();
    auto tasks = TaskReporter(&region, theme);

    // The whole pipeline is registered up front so the pending rows show the
    // plan; stages beyond --stage are skipped in order as execution passes them.
    const tagId = tasks.add("create annotated tag " ~ tag);
    const pushId = tasks.add("push " ~ tag ~ " to origin");
    const draftId = tasks.add("create draft GitHub release");
    const publishId = tasks.add("publish GitHub release");

    int failStage(size_t id, string message)
    {
        tasks.fail(id, message);
        region.finish();
        return fail(message);
    }

    tasks.start(tagId);
    auto tagR = createAnnotatedTag(tag, notesPath);
    if (tagR.hasError)
        return failStage(tagId, tagR.error);
    tasks.succeed(tagId);

    if (stageAtLeast(chosen, Stage.pushTag))
    {
        tasks.start(pushId);
        auto pushR = pushTag(tag);
        if (pushR.hasError)
            return failStage(pushId, "tag created locally but push failed: " ~ pushR.error
                ~ "\nRetry with: git push origin " ~ tag);
        tasks.succeed(pushId);
    }
    else
        tasks.skip(pushId, "beyond --stage");

    if (stageAtLeast(chosen, Stage.createGhReleaseDraft))
    {
        tasks.start(draftId);
        auto r = runCaptured(["gh", "release", "create", tag, "--draft", "--notes-from-tag"]);
        if (r.status != 0)
            return failStage(draftId, "gh release draft failed: " ~ r.stderr);
        tasks.succeed(draftId);
    }
    else
        tasks.skip(draftId, "beyond --stage");

    if (stageAtLeast(chosen, Stage.publishGhRelease))
    {
        tasks.start(publishId);
        auto r = runCaptured(["gh", "release", "edit", tag, "--draft=false"]);
        if (r.status != 0)
            return failStage(publishId, "gh release publish failed: " ~ r.stderr);
        tasks.succeed(publishId, "notify-dub-registry will fire");
    }
    else
        tasks.skip(publishId, "beyond --stage");

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

/// The bump select: every candidate shows its concrete next version, and the
/// suggested one carries the tally that produced the policy suggestion. With
/// `--auto` the suggestion is taken silently; on EOF the suggestion stands.
private BumpKind promptBump(
    BumpKind suggested, in SemVer current, in CommitTally tally, bool auto_,
    in Theme theme)
{
    import std.conv : text;
    import sparkles.core_cli.prompts : PromptPolicy, select, SelectOption, stdioPromptIo;

    static immutable kinds = [BumpKind.patch, BumpKind.minor, BumpKind.major];

    SelectOption[] options;
    size_t defaultIndex = 0;
    foreach (i, k; kinds)
    {
        string description;
        if (k == suggested)
        {
            defaultIndex = i;
            description = text("suggested: ", tally.feat, " feat, ", tally.fix,
                " fix, ", tally.breaking, " breaking");
        }
        options ~= SelectOption(
            text(bumpName(k), "  v", verStr(current), " → v", verStr(applyBump(current, k))),
            description);
    }

    writeln();
    auto choice = select("Version bump:", options, defaultIndex,
        auto_ ? PromptPolicy.takeDefault : PromptPolicy.interactive,
        stdioPromptIo(), theme);
    return choice.hasValue ? kinds[choice.value] : suggested;
}

private AgentSpec promptAgent(const(AgentSpec)[] avail, in Theme theme)
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import sparkles.core_cli.prompts : PromptPolicy, select, SelectOption, stdioPromptIo;

    auto options = avail.map!(a => SelectOption(a.key, a.binary)).array;
    auto choice = select("Choose an agent:", options, 0,
        PromptPolicy.interactive, stdioPromptIo(), theme);
    return cast(AgentSpec) avail[choice.hasValue ? choice.value : 0];
}

/// The closing receipt: what was created, how far it went, and (when a GitHub
/// release exists) a clickable link — with the natural next command as footer.
private void printReceipt(Stage stage, string tag, string notesBody, in Theme theme)
{
    import std.string : lineSplitter;
    import sparkles.core_cli.ui.osc_link : oscLink;
    import sparkles.core_cli.ui.theme : Semantic;

    string subject = tag;
    foreach (line; notesBody.lineSplitter)
    {
        subject = line;
        break;
    }

    string[] lines = [
        "tag      " ~ tag ~ " (annotated)",
        "subject  " ~ subject,
    ];
    if (stageAtLeast(stage, Stage.pushTag))
        lines ~= "pushed   origin " ~ theme.mark(Semantic.success);
    if (stageAtLeast(stage, Stage.createGhReleaseDraft))
    {
        const published = stageAtLeast(stage, Stage.publishGhRelease);
        const url = ghReleaseUrl(tag);
        lines ~= "release  " ~ (url.length ? oscLink(url, url) : "created")
            ~ (published ? " (published)" : " (draft)");
    }

    const next = stage == Stage.publishGhRelease
        ? cast(string) null
        : "next: release --stage=" ~ stageToken(cast(Stage)(stage + 1));

    writeln();
    writeln(drawBox(lines,
        theme.mark(Semantic.success) ~ " released " ~ tag,
        BoxProps(footer: next)));
    stdout.flush();
}

/// The GitHub release URL for `tag` via `gh` (empty when unavailable) — only
/// called for stages where `checkGhReady` already verified `gh`.
private string ghReleaseUrl(string tag)
{
    import std.string : strip;

    auto r = runCaptured(["gh", "release", "view", tag, "--json", "url", "-q", ".url"]);
    return r.succeeded ? r.stdout.strip : null;
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
