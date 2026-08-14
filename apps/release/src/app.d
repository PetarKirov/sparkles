/++
`release` — automate the middle of the sparkles release process.

Scans git tags (as SemVer), summarizes the commits since the latest one, suggests
a SemVer bump from the conventional commits, gathers the release notes (your
`$EDITOR` or a CLI LLM agent), and then carries the release as far as `--stage`
allows: a local annotated tag (default), a pushed tag, a draft GitHub release, or
a published one.

With `--split`, the unreleased backlog is instead associated with the PRs that
introduced it (GitHub GraphQL), segmented into a chain of releases by the
agent, and — after plan review — each segment is tagged/pushed/released in
turn. See `docs/specs/release/SPEC.md` §6–§7.

See `docs/guidelines/release.md` for the policy this encodes.

Usage:
    release [--stage=create-tag|push-tag|create-gh-release-draft|publish-gh-release]
            [--auto] [--agent=<key>] [--bump=major|minor|patch]
            [--notes=manual|agent] [--split] [--no-verify] [--log-level=<level>]
+/
module sparkles.release.app;

import std.stdio : writeln, writefln, write, stdout;
import std.typecons : Nullable;

import sparkles.base.logger : initLogger, LogLevel, info, warning, error;
import sparkles.base.term_style : Style, stylize;
import sparkles.core_cli.args : Command, HelpInfo, Option, runCli, Subcommands;
import sparkles.core_cli.process_utils : isInPath, runCaptured;
import sparkles.base.term_caps : detectTermCaps;
import sparkles.ui.components.box : drawBox, BoxProps;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import sparkles.ui.components.live : LiveRegion, stdoutLiveRegion;
import sparkles.ui.components.table : drawTable;
import sparkles.ui.components.tasklist : TaskReporter;
import sparkles.ui.components.theme : makeTheme, Theme;
import sparkles.versions.schemes.semver : SemVer;

import sparkles.release.agents : AgentSpec, availableAgents, buildAgentPrompt, buildSegmentationPrompt, capLogStat, buildSegmentationRetryCoda, buildSegmentNotesSection, findAgent, runAgent, resolveBinary;
import sparkles.release.artifacts : ArtifactSink, makeArtifactSink;
import sparkles.release.bump : applyBump, BumpKind, parseBumpKind, suggestBump;
import sparkles.release.conventional : CommitType;
import sparkles.release.git : authorCounts, countCommitsNotOn, createAnnotatedTag, currentBranch, diffStat, latestTag, listTags, logRange, logStatRange, numstat, pushTag, remoteUrl, repoRoot, tagExists;
import sparkles.release.notes : openInEditor, seedEditorBuffer, seedReviewBuffer, stripComments;
import sparkles.release.pr : associatePrs, parseRemoteUrl, PrRef;
import sparkles.release.preflight : runPreflight, PreflightProgress, PreflightResult;
import sparkles.release.result : Result;
import sparkles.release.store.run : applicationId, RunOptions, runPublish;
import sparkles.release.store.stage : defaultStage, PublishStage, publishStageNames, tryParseStage;
import sparkles.release.store.version_map : apkVersionForTag, describe;
import std.sumtype : SumType;
import sparkles.release.json_utils : parseJsonText;
import sparkles.release.segment : AgentReply, buildPlan, BumpOrigin, parseSegmentReply, ReleasePlan, SegmentInput, SegmentPlan, stripJsonFence;
import sparkles.release.stages : Stage, parseStage, stageAtLeast, stageToken;
import sparkles.release.stats : tallyCommits, typeCounts, ReleaseStats, Commit, CommitTally, AuthorCount, FileStat, AreaStat, areaBreakdown;

/// CLI options (validated string fields for the hyphenated/closed vocabularies;
/// only `--log-level` is a real enum, which getopt binds directly).
///
/// `isDefault` keeps bare `release` meaning what it always has — cut a release.
/// The subcommands are the operations that act on a tag that already exists,
/// which the cut-a-release flow cannot express: it is built to compute the
/// *next* version.
@(Command("release",
    shortDescription: "Scan tags, summarize commits, suggest a bump, write notes, tag and publish",
    helpSections: ["description"],
    isDefault: true,
))
struct CliParams
{
    @(Option(`s|stage`, description:
        "Cumulative stage: create-tag (default), push-tag, "
        ~ "create-gh-release-draft, publish-gh-release, publish-apps. Each implies "
        ~ "the earlier ones; publish-apps needs the signing tokens, so it only runs "
        ~ "on the workstation."))
    string stage = "create-tag";

    @(Option(`a|auto`, description:
        "Non-interactive: take the suggested bump and run the agent for notes "
        ~ "without opening $EDITOR."))
    bool auto_;

    @(Option(`g|agent`, description:
        "CLI LLM agent key for agent notes (claude-code, codex, gemini, ...). "
        ~ "Only agents found on PATH are offered."))
    string agent;

    @(Option(`b|bump`, description: "Override the suggested bump: major, minor, or patch."))
    string bump;

    @(Option(`n|notes`, description:
        "Release-notes mode: manual (open $EDITOR) or agent (LLM summary)."))
    string notes;

    @(Option(`S|split`, description:
        "Segment the unreleased backlog into multiple chained releases "
        ~ "(associates commits with PRs via gh; an LLM agent proposes the split)."))
    bool split;

    @(Option(`N|no-verify`, description: "Skip the pre-flight checks (clean tree, on main, ci tests)."))
    bool noVerify;

    @(Option(`L|log-level`, description: "trace, info, warning, error (default info)."))
    LogLevel logLevel = LogLevel.info;

    @Subcommands
    SumType!(PathCmd, PublishCmd, VersionCmd) command;

    int run()
    {
        initLogger(logLevel);
        try
            return runCut(this);
        catch (Exception e)
        {
            error(i"$(e.msg)");
            return 1;
        }
    }
}


// ---------------------------------------------------------------------------
// Subcommands — operations on a tag that already exists
// ---------------------------------------------------------------------------

/// Shared by the tag-taking subcommands.
private enum tagOption = `t|tag`;

@(Command("version",
    shortDescription: "Show the app version a release tag maps to",
    helpSections: ["description"],
))
struct VersionCmd
{
    @(Option(tagOption, description: "Release tag, with or without the leading v"))
    string tag;

    int run()
    {
        if (!tag.length)
            return failCmd("--tag is required");

        const mapped = apkVersionForTag(tag);
        if (!mapped.ok)
            return failCmd(tag ~ ": " ~ describe(mapped.error));

        writefln("versionName %s", mapped.version_.name);
        writefln("versionCode %s", mapped.version_.code);
        return 0;
    }
}

@(Command("path",
    shortDescription: "Print the store path a tag's app artifact resolves to",
    helpSections: ["description"],
))
struct PathCmd
{
    @(Option(tagOption, description: "Release tag, with or without the leading v"))
    string tag;

    @(Option(`f|flake`, description: "Flake reference to evaluate"))
    string flake = ".";

    /// The handoff between CI and the signing machine: CI prints this after
    /// pushing to the cache, and the workstation must resolve the same string
    /// or it is about to sign something other than what was built.
    int run()
    {
        import sparkles.release.store.tools : evalApkPath;
        import std.path : absolutePath;

        if (!tag.length)
            return failCmd("--tag is required");

        const mapped = apkVersionForTag(tag);
        if (!mapped.ok)
            return failCmd(tag ~ ": " ~ describe(mapped.error));

        auto evaluated = evalApkPath(flake.absolutePath, mapped.version_.name, mapped.version_.code);
        if (!evaluated.succeeded)
            return failCmd(evaluated.stderr);

        writeln(lastNonEmptyLine(evaluated.stdout));
        return 0;
    }
}

@(Command("publish",
    shortDescription: "Sign and publish an existing tag's artifacts to the app stores",
    helpSections: ["description"],
))
struct PublishCmd
{
    @(Option(tagOption, description: "Release tag, with or without the leading v"))
    string tag;

    @(Option(`s|stage`,
        description: "How far to go; cumulative. One of: build, sign, pull, index, deploy"))
    string stage = "index";

    @(Option(`n|dry-run`, description: "Report what would happen and stop"))
    bool dryRun;

    @(Option(`w|workdir`, description: "Scratch directory; must not be the repository checkout"))
    string workdir;

    @(Option(`m|metadata-dir`, description: "Committed F-Droid configuration"))
    string metadataDir = "apps/hue/fdroid";

    @(Option(`f|flake`, description: "Flake reference to build the artifact from"))
    string flake = ".";

    @(Option(`r|rclone-remote`, description: "rclone remote name, as named in config.yml"))
    string rcloneRemote = "sparkles";

    @(Option(`require-cached`,
        description: "Require the artifact to come from the binary cache rather than a local build"))
    bool requireCached = true;

    @(Option(`substituter`, description: "Binary cache CI pushes the unsigned artifact to"))
    string substituter = "https://sparkles.cachix.org";

    int run()
    {
        import std.conv : text;
        import std.file : exists, tempDir;
        import std.path : absolutePath, buildPath;
        import std.process : thisProcessID;

        if (!tag.length)
            return failCmd("--tag is required");

        PublishStage parsed;
        if (!tryParseStage(stage, parsed))
            return failCmd("unknown --stage " ~ stage
                ~ " (expected one of: " ~ publishStageNames ~ ")");

        auto dir = workdir.length
            ? workdir
            : buildPath(tempDir, text("sparkles-publish-", thisProcessID));

        // fdroidserver publishes the working directory's git state in
        // repo/status/*.json — including untracked and modified files — so
        // running it inside a checkout leaks it.
        if (buildPath(dir.absolutePath, ".git").exists)
            return failCmd(dir ~ " is a git checkout.\n"
                ~ "  fdroid update records the working directory's git state — commit id,\n"
                ~ "  dirty flag, and the modified and untracked file lists — in\n"
                ~ "  repo/status/*.json, which is published. Use a scratch directory.");

        return runPublish(RunOptions(
            tag: tag,
            stage: parsed,
            dryRun: dryRun,
            workDir: dir,
            metadataDir: metadataDir,
            flakeRef: flake.absolutePath,
            rcloneRemote: rcloneRemote,
            requireCached: requireCached,
            substituter: substituter,
        ));
    }
}

/// A scratch directory for the publish stage. Never the checkout: fdroidserver
/// records the working directory's git state in `repo/status/*.json`, which is
/// published.
private string publishWorkDir()
{
    import std.conv : text;
    import std.file : tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    return buildPath(tempDir, text("sparkles-publish-", thisProcessID));
}

/// Reports a subcommand usage/precondition failure the same way everywhere.
///
/// Straight to stderr rather than through the logger: these are CLI errors, not
/// log events, and a subcommand has not initialised the logger — routing them
/// through it swallowed them entirely.
private int failCmd(string message)
{
    import std.stdio : stderr;

    stderr.writeln("error: ", message);
    return 1;
}

/// The last non-empty line of a command's output.
private string lastNonEmptyLine(string s) @safe pure
{
    import std.string : lineSplitter, strip;

    string last;
    foreach (line; s.lineSplitter)
        if (line.strip.length)
            last = line.strip;
    return last;
}

int main(string[] args) => runCli!CliParams(args);

private int runCut(CliParams cli)
{
    const theme = makeTheme(detectTermCaps());

    // ----- validate the closed-vocabulary options up front -----
    auto stage = parseStage(cli.stage);
    if (stage.isNull)
        return fail("unknown --stage `" ~ cli.stage
            ~ "` (create-tag, push-tag, create-gh-release-draft, publish-gh-release, "
            ~ "publish-apps)");

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

    if (cli.split)
    {
        if (cli.bump.length)
            return fail("--bump is incompatible with --split "
                ~ "(bumps are per-segment; the plan table shows them)");
        return runSplit(cli, stage.get, notesMode.get, theme);
    }

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

    // ----- fail fast if a requested stage is unusable -----
    if (auto e = checkGhReady(stage.get))
        return fail(e);
    // Checked before the tag exists: a version the Android channel cannot
    // represent is better refused now than discovered after the tag is public.
    if (auto e = checkFdroidReady(stage.get, tag))
        return fail(e);
    warnIfUnpublishableOnAndroid(tag, stage.get);

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
        s ~= " and publish a GitHub release (the release workflow fires)";
    else if (stageAtLeast(stage, Stage.createGhReleaseDraft))
        s ~= " and create a draft GitHub release";
    return s;
}

// ---------------------------------------------------------------------------
// Split mode (SPEC §6–§7)
// ---------------------------------------------------------------------------

/// The `--split` pipeline: associate the backlog with its PRs, let the agent
/// segment it, review the plan (remainder decision included), then drive the
/// per-tag machinery once per segment, oldest first.
private int runSplit(in CliParams cli, Stage stage, NotesMode notesMode, in Theme theme)
{
    import std.conv : text;
    import std.range : retro;
    import std.array : array;
    import sparkles.core_cli.prompts : confirm, PromptPolicy, select, SelectOption, stdioPromptIo;

    // Split needs gh for the association even at --stage create-tag.
    if (auto e = checkGhReady(stage, needGhAnyway: true))
        return fail(e);

    // One agent serves the segmentation and every segment's notes.
    auto specR = pickAgent(cli, theme);
    if (specR.hasError)
        return fail(specR.error);
    const spec = specR.value;

    // ----- range (oldest first) -----
    auto tagsR = listTags();
    if (tagsR.hasError)
        return fail(tagsR.error);
    const latest = latestTag(tagsR.value);
    const firstRelease = latest.isNull;
    const fromRef = firstRelease ? "" : latest.get.tag;
    auto commitsR = logRange(fromRef, "HEAD");
    if (commitsR.hasError)
        return fail(commitsR.error);
    auto commits = commitsR.value.retro.array;
    if (commits.length == 0)
    {
        const since = firstRelease ? "the initial commit" : latest.get.tag;
        info(i"No commits since $(since); nothing to split.");
        return 0;
    }
    const current = firstRelease ? SemVer(major: 0, minor: 0, patch: 0)
        : latest.get.version_;

    // ----- GitHub slug -----
    auto urlR = remoteUrl();
    if (urlR.hasError)
        return fail(urlR.error);
    const slug = parseRemoteUrl(urlR.value);
    if (slug.isNull)
        return fail("origin remote `" ~ urlR.value
            ~ "` is not a GitHub repository (--split associates commits via gh)");

    const root = repoRoot();
    auto sink = makeArtifactSink(root.hasValue ? root.value : ".");

    writeln();
    writeln(drawHeader(text("Split: ", firstRelease ? "(initial)" : fromRef,
        "..HEAD (", commits.length, " commits)"),
        HeaderProps(style: HeaderStyle.banner)));
    stdout.flush();

    // ----- PR association (live progress) -----
    PrRef[] prRefs;
    {
        auto region = stdoutLiveRegion();
        scope (exit)
            region.finish();
        auto tasks = TaskReporter(&region, theme);
        const id = tasks.add("associate commits with PRs (gh api graphql)");
        tasks.start(id);
        auto prsR = associatePrs(commits, slug.get,
            (done, total) { tasks.output(id, text(done, "/", total, " commits")); });
        if (prsR.hasError)
        {
            tasks.fail(id, prsR.error);
            region.finish();
            return fail(prsR.error);
        }
        prRefs = prsR.value;
        tasks.succeed(id, text(commits.length, " commits"));
    }

    SegmentInput[] rows;
    rows.reserve(commits.length);
    foreach (i, ref c; commits)
        rows ~= SegmentInput(sha: c.sha, prNumber: prRefs[i].number,
            prTitle: prRefs[i].title, subject: c.subject);

    // ----- segmentation (retry once on an invalid reply) -----
    auto promptR = buildSegmentationPrompt(rows, current);
    if (promptR.hasError)
        return fail(promptR.error);
    sink.save("segmentation-prompt.md", promptR.value.forArtifact);

    ReleasePlan plan;
    AgentReply reply;
    {
        string lastError;
        bool valid = false;
        foreach (attempt; 1 .. 3)
        {
            // A corrective coda only makes sense after an *invalid reply*;
            // after a failed agent run the original prompt is retried as-is.
            const prompt = lastError.length
                ? promptR.value.forAgent ~ buildSegmentationRetryCoda(lastError)
                : promptR.value.forAgent;
            info(i"Segmenting with $(spec.key) (attempt $(attempt))…");
            auto rawR = runAgent(spec, prompt);
            if (rawR.hasError)
            {
                warning(i"$(rawR.error)");
                continue;
            }
            // A reply that (fence-stripped) parses as JSON is saved
            // pretty-printed as `.json`; anything malformed stays raw `.txt`.
            auto extractedDom = parseJsonText(stripJsonFence(rawR.value));
            const isJson = extractedDom.hasValue;
            sink.save(text("segmentation-reply-", attempt, isJson ? ".json" : ".txt"),
                isJson ? extractedDom.value.toPrettyString : rawR.value);

            auto parsed = parseSegmentReply(rawR.value);
            if (parsed.hasError)
            {
                lastError = parsed.error;
                warning(i"$(parsed.error)");
                continue;
            }
            auto planR = buildPlan(parsed.value, rows, commits, current);
            if (planR.hasError)
            {
                lastError = planR.error;
                warning(i"$(planR.error)");
                continue;
            }
            reply = parsed.value;
            plan = planR.value;
            valid = true;
            break;
        }
        if (!valid)
            return fail("segmentation failed after retry"
                ~ (lastError.length ? ": " ~ lastError : "")
                ~ " (see " ~ sink.dir ~ ")");
    }

    // Planned tags must be fresh (stray tags can shadow chained versions).
    foreach (ref seg; plan.segments)
    {
        auto ex = tagExists(seg.tag);
        if (ex.hasError)
            return fail(ex.error);
        if (ex.value)
            return fail("planned tag " ~ seg.tag ~ " already exists");
    }

    renderPlan(plan, rows, theme);

    // ----- remainder decision (SPEC §7.4) -----
    if (plan.remainderBegin < rows.length)
    {
        writeln();
        writeln("Unreleased remainder:");
        foreach (ref row; rows[plan.remainderBegin .. $])
            writeln("  " ~ row.sha[0 .. 8] ~ " " ~ row.subject);
        writeln();

        auto choice = select("Remainder:", [
            SelectOption("leave unreleased",
                "re-running --split later picks these up"),
            SelectOption("extend " ~ plan.segments[$ - 1].tag,
                "include the remainder in the last release"),
        ], 0, cli.auto_ ? PromptPolicy.takeDefault : PromptPolicy.interactive,
            stdioPromptIo(), theme);
        if (choice.hasValue && choice.value == 1)
        {
            auto extended = reply;
            extended.segments = reply.segments.dup;
            extended.segments[$ - 1].boundary = rows[$ - 1].sha;
            extended.remainderNote = null;
            auto planR = buildPlan(extended, rows, commits, current);
            if (planR.hasError)
                return fail(planR.error);      // cannot happen structurally
            plan = planR.value;
            renderPlan(plan, rows, theme);
        }
    }
    sink.save("plan.json", planJson(plan));

    // ----- plan approval -----
    {
        auto go = confirm(
            text("Create ", plan.segments.length, " release(s) as planned?"),
            defaultYes: true,
            policy: cli.auto_ ? PromptPolicy.takeDefault : PromptPolicy.interactive,
            io: stdioPromptIo(),
            theme: theme);
        if (go.hasError)
            return fail(go.error);
        if (!go.value)
        {
            info(i"Aborted; nothing was created.");
            return 0;
        }
    }

    // ----- pre-flight (once, against HEAD) -----
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

    // ----- one outward gate enumerating every tag -----
    if (stageAtLeast(stage, Stage.pushTag))
    {
        auto go = confirm(
            "About to " ~ describeOutwardStagesMulti(stage, plan.segments)
            ~ ". Pushed tags are immutable (code.dlang.org ingests them). Proceed?",
            defaultYes: true,
            policy: cli.auto_ ? PromptPolicy.takeDefault : PromptPolicy.interactive,
            io: stdioPromptIo(),
            theme: theme);
        if (go.hasError)
            return fail(go.error);
        if (!go.value)
        {
            info(i"Aborted before any outward stage; nothing was created.");
            return 0;
        }
    }

    // ----- per-segment execution, oldest first (SPEC §7.5) -----
    const(SegmentPlan)[] done;
    string prevBoundary = fromRef;
    foreach (ref seg; plan.segments)
    {
        const subject = seg.tag ~ " — " ~ seg.theme;
        auto notesR = acquireNotesRange(notesMode, &spec, subject,
            prevBoundary, seg.boundarySha,
            buildSegmentNotesSection(seg.highlights, priorContextLines(rows[0 .. seg.begin])),
            cli.auto_, sink, seg.tag);
        if (notesR.hasError)
        {
            printSplitReceipt(stage, done, plan.segments.length, theme);
            return fail(notesR.error);
        }
        const notesBody = notesR.value;
        if (notesBody.length == 0)
        {
            info(i"Empty notes for $(seg.tag); stopping before it. Created tags stand.");
            printSplitReceipt(stage, done, plan.segments.length, theme);
            return 0;
        }
        sink.save("notes-" ~ seg.tag ~ ".txt", notesBody);

        const rc = executeStages(stage, seg.tag, notesBody, theme, seg.boundarySha);
        if (rc != 0)
        {
            printSplitReceipt(stage, done, plan.segments.length, theme);
            return rc;
        }
        done ~= seg;
        prevBoundary = seg.boundarySha;
    }

    printSplitReceipt(stage, done, plan.segments.length, theme);
    return 0;
}

/// The plan table plus its footer warnings (SPEC §7.4).
private void renderPlan(in ReleasePlan plan, in SegmentInput[] rows, in Theme theme)
{
    import std.conv : text;
    import sparkles.base.text.width : Align;
    import sparkles.base.term_caps : terminalSize;
    import sparkles.ui.components.table : TableProps;

    string[][] table = [["Version", "Commits", "PRs", "Theme", "Bump"]];
    foreach (ref seg; plan.segments)
        table ~= [
            seg.tag,
            (seg.end - seg.begin).text,
            formatPrList(seg.prNumbers),
            seg.theme,
            formatBump(seg),
        ];

    writeln();
    writeln(drawTable(table, TableProps(title: "Release plan", headerRows: 1,
        columnAligns: [Align.left, Align.right, Align.left, Align.left, Align.left],
        maxWidth: terminalSize().width)));

    if (plan.remainderBegin < rows.length)
    {
        const note = plan.remainderNote.length ? ": " ~ plan.remainderNote : "";
        writeln(stylize(text(rows.length - plan.remainderBegin,
            " commits left unreleased (remainder)", note), Style.yellow));
    }
    if (plan.noPrCommits)
        writeln(text(plan.noPrCommits, " commits have no associated PR"));
    auto unpushed = countCommitsNotOn("origin/main", "HEAD");
    if (unpushed.hasValue && unpushed.value > 0)
        writeln(stylize(text(unpushed.value, " tip commits are not on origin/main"
            ~ " — pushing a tag publishes them"), Style.yellow));
    stdout.flush();
}

/// `#47 #52 #58 … (+11)` — the first PRs of a segment, elided past three.
private string formatPrList(const(uint)[] prs) @safe pure
{
    import std.conv : text;

    if (prs.length == 0)
        return "—";
    string s;
    foreach (i, p; prs[0 .. prs.length > 3 ? 3 : prs.length])
        s ~= (i ? " #" : "#") ~ p.text;
    if (prs.length > 3)
        s ~= text(" … (+", prs.length - 3, ")");
    return s;
}

/// The bump cell: escalations/fallbacks marked, a 1.0 crossing highlighted.
private string formatBump(in SegmentPlan seg) @safe pure
{
    string s = bumpName(seg.bump);
    final switch (seg.bumpOrigin)
    {
        case BumpOrigin.agent:
            break;
        case BumpOrigin.escalated:
            s = stylize(s ~ " ↑ escalated", Style.yellow);
            break;
        case BumpOrigin.fallback:
            s = stylize(s ~ " (fallback)", Style.yellow);
            break;
    }
    if (seg.bump == BumpKind.major && seg.version_.major == 1)
        s ~= stylize(" → 1.0!", Style.red);
    return s;
}

/// `sha7 subject` per prior-segment commit, for the arc-completion context.
private string[] priorContextLines(const(SegmentInput)[] prior) @safe pure
{
    string[] lines;
    lines.reserve(prior.length);
    foreach (ref row; prior)
        lines ~= row.sha[0 .. 7] ~ " " ~ row.subject;
    return lines;
}

/// The outward gate line for many tags: `push v0.5.0, v0.6.0 (2 tags) to origin …`.
private string describeOutwardStagesMulti(Stage stage, const(SegmentPlan)[] segs) @safe pure
{
    import std.conv : text;

    string tags;
    foreach (i, ref seg; segs)
        tags ~= (i ? ", " : "") ~ seg.tag;
    string s = text("push ", tags, " (", segs.length, " tags) to origin");
    if (stageAtLeast(stage, Stage.publishGhRelease))
        s ~= " and publish their GitHub releases (the release workflow fires)";
    else if (stageAtLeast(stage, Stage.createGhReleaseDraft))
        s ~= " and create their draft GitHub releases";
    return s;
}

/// The split summary receipt: every tag that completed, and — when the run
/// stopped early or stayed local — the natural next command.
private void printSplitReceipt(
    Stage stage, const(SegmentPlan)[] done, size_t planned, in Theme theme)
{
    import std.conv : text;
    import sparkles.ui.components.layout : kvList;
    import sparkles.ui.components.theme : Semantic;

    if (done.length == 0)
    {
        info(i"No release was completed.");
        return;
    }

    string[2][] pairs;
    foreach (ref seg; done)
        pairs ~= [seg.tag, seg.theme ~ " (" ~ text(seg.end - seg.begin) ~ " commits)"];
    if (stageAtLeast(stage, Stage.pushTag))
        pairs ~= ["pushed", "origin " ~ theme.mark(Semantic.success)];

    string footer = null;
    if (done.length < planned)
        footer = "resume: release --split (the backlog re-segments from the last tag)";
    else if (!stageAtLeast(stage, Stage.pushTag))
    {
        string tags;
        foreach (ref seg; done)
            tags ~= " " ~ seg.tag;
        footer = "push: git push origin" ~ tags;
    }

    writeln();
    writeln(drawBox(kvList(pairs),
        theme.mark(done.length == planned ? Semantic.success : Semantic.warning)
        ~ text(" released ", done.length, "/", planned, " planned tags"),
        BoxProps(footer: footer)));
    stdout.flush();
}

/// The validated plan as pretty JSON for the `.result/` artifact (best-effort:
/// an encode failure yields an explanatory stub instead of aborting anything).
private string planJson(in ReleasePlan plan)
{
    import sparkles.release.json_utils : encodeJson;

    // `toJSON` yields minified `JsonString` text now, so the pretty rendering
    // goes through `encodeJson`'s `writeJSON` path rather than a JSONValue.
    auto encoded = encodeJson(plan, pretty: true);
    if (encoded.hasError)
        return `{"error": "could not encode the plan"}`;
    return encoded.value;
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
    size_t current;
    auto progress = PreflightProgress(
        started: (string label) {
            const id = tasks.add(label);
            ids[label] = id;
            current = id;
            tasks.start(id);
        },
        finished: (string label, bool ok, string detail) {
            if (auto id = label in ids)
                ok ? tasks.succeed(*id) : tasks.fail(*id, detail);
        },
        // ci output streams into the running check's bounded tail pane.
        output: (scope const(char)[] line) { tasks.output(current, line); },
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
    import sparkles.base.term_caps : terminalSize;
    import sparkles.ui.components.table : TableProps;

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

    // Conventional-commit type breakdown (only non-zero rows), with a
    // count-proportional bar per row.
    import std.algorithm.comparison : max;
    import sparkles.ui.components.meter : meter;

    size_t maxTypeCount = 0;
    foreach (count; rs.typeCounts)
        maxTypeCount = max(maxTypeCount, count);

    string[][] types = [["Type", "Count", ""]];
    static foreach (t; __traits(allMembers, CommitType))
        if (rs.typeCounts[__traits(getMember, CommitType, t)] > 0)
            types ~= [t,
                rs.typeCounts[__traits(getMember, CommitType, t)].text,
                meter(rs.typeCounts[__traits(getMember, CommitType, t)], maxTypeCount, 12)];
    if (types.length > 1)
    {
        writeln();
        writeln(drawTable(types, TableProps(title: "Commits by type",
            headerRows: 1, columnAligns: [Align.left, Align.right, Align.left],
            maxWidth: cap)));
    }

    if (rs.areas.length)
    {
        // The per-area rows are a pre-ordered (label, depth) walk — exactly the
        // flat tree form, so the stub column gets real guides instead of the
        // old two-space indent.
        import std.algorithm.iteration : map;
        import std.array : array;
        import sparkles.ui.components.tree : renderTree, TreeNode;

        const guides = renderTree(rs.areas.map!(a => TreeNode(a.label, a.depth)).array);
        string[][] areaRows = [["Area", "Changed"]];
        foreach (i, a; rs.areas)
            areaRows ~= [
                guides[i],
                "+" ~ a.insertions.text ~ " / -" ~ a.deletions.text,
            ];
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
    import sparkles.release.result : failure;

    const(AgentSpec)* spec = null;
    AgentSpec picked;
    if (mode == NotesMode.agent)
    {
        auto specR = pickAgent(cli, theme);
        if (specR.hasError)
            return failure!string(specR.error);
        picked = specR.value;
        spec = &picked;
    }
    return acquireNotesRange(mode, spec, suggestedSubject, fromRef, "HEAD",
        null, cli.auto_);
}

/// The range-aware notes core both modes share: `fromRef..toRef` seeds the
/// editor/agent, `spec` is the pre-picked agent (null in manual mode), and
/// `extraPromptSection` is appended to the agent prompt (the split mode's
/// highlights/deferral section; empty classically). With an enabled `sink`
/// and an `artifactTag`, the agent prompt is persisted for review.
private Result!string acquireNotesRange(
    NotesMode mode, scope const(AgentSpec)* spec, string suggestedSubject,
    string fromRef, string toRef, string extraPromptSection, bool auto_,
    in ArtifactSink sink = ArtifactSink.init, string artifactTag = null)
{
    import sparkles.release.result : success;

    auto logStatR = logStatRange(fromRef, toRef);
    const logStat = logStatR.hasValue ? logStatR.value : "";
    const range = fromRef.length ? fromRef ~ ".." ~ toRef : toRef;

    if (mode == NotesMode.manual)
    {
        auto edited = openInEditor(seedEditorBuffer(suggestedSubject, logStat));
        if (edited.hasError)
            return edited;
        return success(stripComments(edited.value));
    }

    assert(spec !is null, "agent mode needs a pre-picked agent");
    info(i"Summarizing $(spec.key) → release notes…");

    // The prompt reaches the agent as a file, so its size is unconstrained;
    // the log is still capped to keep a huge range's diffstat noise from
    // crowding out the notes (the editor path above stays complete).
    const prompt = buildAgentPrompt(suggestedSubject, range, capLogStat(logStat))
        ~ extraPromptSection;
    if (artifactTag.length)
        sink.save("notes-prompt-" ~ artifactTag ~ ".txt", prompt);

    auto generated = runAgent(*spec, prompt);
    if (generated.hasError)
        return generated;

    if (auto_)
        return success(generated.value);     // verbatim; non-empty checked by runAgent

    // Interactive: let the user review/edit the agent output.
    auto edited = openInEditor(seedReviewBuffer(generated.value));
    if (edited.hasError)
        return edited;
    return success(stripComments(edited.value));
}

private Result!(AgentSpec) pickAgent(in CliParams cli, in Theme theme)
{
    import expected : mapError;

    import sparkles.release.result : success, failure;

    auto avail = availableAgents();

    if (cli.agent.length)
    {
        auto spec = findAgent(cli.agent);
        if (spec is null)
            return failure!AgentSpec("unknown agent `" ~ cli.agent ~ "`");
        return resolveBinary(*spec).mapError!(_ =>
            "agent `" ~ cli.agent ~ "` (" ~ spec.binary ~ ") is not on PATH");
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

/// Runs the tag/push/draft/publish checklist for one tag. `target` is the
/// committish the annotated tag lands on (HEAD when null; the split mode
/// passes each segment's boundary commit).
private int executeStages(Stage chosen, string tag, string notesBody, in Theme theme,
    string target = null)
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
    const fdroidId = tasks.add("publish the app stores");

    int failStage(size_t id, string message)
    {
        tasks.fail(id, message);
        region.finish();
        return fail(message);
    }

    tasks.start(tagId);
    auto tagR = createAnnotatedTag(tag, notesPath, target);
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
        tasks.succeed(publishId, "the release workflow will fire");
    }
    else
        tasks.skip(publishId, "beyond --stage");

    // The Android channel. Signing keys live on hardware tokens, so this stage
    // only works on the machine holding them — reaching it from CI is meant to
    // fail. The real guards (no reused versionCode, no local rebuild in place
    // of what CI built, certificate pinned) are inside `fdroid-publish`; this
    // is only the invocation.
    //
    // It also cannot run immediately after `publish-gh-release` in the same
    // breath as CI: the release workflow has to build and cache the unsigned
    // APK first. `fdroid-publish` reports that clearly rather than rebuilding.
    if (stageAtLeast(chosen, Stage.publishApps))
    {
        tasks.start(fdroidId);
        // In-process, not a subprocess: the version mapping and the publish
        // pipeline are this tool's own modules now, so there is no boundary
        // across which they could disagree.
        const rc = runPublish(RunOptions(
            tag: tag,
            stage: PublishStage.deploy,
            workDir: publishWorkDir(),
            metadataDir: "apps/hue/fdroid",
            flakeRef: ".",
            rcloneRemote: "sparkles",
            requireCached: true,
            substituter: "https://sparkles.cachix.org",
        ));
        if (rc != 0)
            return failStage(fdroidId,
                "publishing the app stores failed — the source release stands; retry with:\n"
                ~ "  release publish --tag " ~ tag ~ " --stage deploy");
        tasks.succeed(fdroidId);
    }
    else
        tasks.skip(fdroidId, "beyond --stage");

    return 0;
}

/// Returns an error string if `gh` is needed but missing or unauthenticated:
/// for GitHub stages, or unconditionally with `needGhAnyway` (the split mode
/// needs `gh` for PR association even at `create-tag`).
private string checkGhReady(Stage stage, bool needGhAnyway = false)
{
    if (!needGhAnyway && !stageAtLeast(stage, Stage.createGhReleaseDraft))
        return null;
    if (!isInPath("gh"))
        return needGhAnyway
            ? "--split needs the `gh` CLI, which is not on PATH"
            : "stage `" ~ stageToken(stage) ~ "` needs the `gh` CLI, which is not on PATH";
    auto auth = runCaptured(["gh", "auth", "status"]);
    if (auth.status != 0)
        return "`gh` is not authenticated (run `gh auth login`)";
    return null;
}

/**
Returns an error string if the Android channel cannot be published.

Two checks, both run *before* anything is tagged, because a version that cannot
reach the app channel is better refused than discovered after the tag is
public.

The version check delegates to `fdroid-publish version`, rather than
reimplementing the mapping here: `versionCode` is `Tiny.orderKey` of the tag,
which packs minor and patch into 8 bits each, so `v0.256.0` has no
representation. Shelling out keeps that rule in one tested place.
*/
private string checkFdroidReady(Stage stage, string tag)
{
    if (!stageAtLeast(stage, Stage.publishApps))
        return null;
    const mapped = apkVersionForTag(tag);
    if (!mapped.ok)
        return "the app stores cannot publish " ~ tag ~ ": " ~ describe(mapped.error);
    return null;
}

/// Warns when a version is fine for the source release but unreachable on the
/// Android channel — the tag is still allowed, since the two channels are
/// independent, but silence here would surface as a failure much later.
private void warnIfUnpublishableOnAndroid(string tag, Stage stage)
{
    if (stageAtLeast(stage, Stage.publishApps))
        return; // already a hard error above

    const mapped = apkVersionForTag(tag);
    if (mapped.ok)
        return;

    const why = describe(mapped.error);
    warning(i`$(tag) cannot be published to the app stores: $(why)`);
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
    import sparkles.ui.components.osc_link : oscLink;
    import sparkles.ui.components.theme : Semantic;

    import sparkles.ui.components.layout : kvList;

    string subject = tag;
    foreach (line; notesBody.lineSplitter)
    {
        subject = line;
        break;
    }

    string[2][] pairs = [
        ["tag", tag ~ " (annotated)"],
        ["subject", subject],
    ];
    if (stageAtLeast(stage, Stage.pushTag))
        pairs ~= ["pushed", "origin " ~ theme.mark(Semantic.success)];
    if (stageAtLeast(stage, Stage.createGhReleaseDraft))
    {
        const published = stageAtLeast(stage, Stage.publishGhRelease);
        const url = ghReleaseUrl(tag);
        pairs ~= ["release", (url.length ? oscLink(url, url) : "created")
            ~ (published ? " (published)" : " (draft)")];
    }
    auto lines = kvList(pairs);

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
