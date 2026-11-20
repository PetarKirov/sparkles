/// `ci check` and `ci fix`: the repository's pass/fail checks, and the two
/// that can rewrite what they check (reference links, the spec-evidence
/// backlog).
module commands.check;

import blob_paths : BlobPathReport, BlobRef, BlobResult, BlobStatus, parseBlobRefs, resolveClone;
import cli : FileSelection;
import commands.files : InputFiles, collectInputFiles, detectRepoRoot;
import commands.output : uiWidth;
import core.time : seconds;
import docs_sidebar : checkDocsSidebar;
import dub_deps : inTreePackageNames;
import sparkles.base.expected : andThen, ok;
import sparkles.base.logger : error, info, warning;
import sparkles.base.text.case_text : asciiLower, unicodeLower;
import sparkles.core_cli.args : failRun, ranOk, RunExpected;
import sparkles.docs.glossary :
    checkGlossary, frontMatterOwner, glossaryDataPath, glossaryReferences, GlossaryReference,
    loadGlossary;
import sparkles.docs.sidebar : loadDocsConfig, loadSidebar, sidebarDataPath;
import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;
import spec_evidence :
    backlogPath, Citation, citationsIn, ratchet, renderBacklog, unresolvedCitations;
import std.algorithm : any, canFind, filter, map, sort, startsWith;
import std.array : array, join;
import std.conv : text, to;
import std.file : exists, readText, remove, write;
import std.path : baseName, buildPath;
import std.process : environment, execute;
import std.regex : regex, matchFirst;
import std.stdio : stderr, stdout, writeln;
import std.string : endsWith, lineSplitter, replace, strip;

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

private auto refDefRegex() => regex(r"^\[([^\]]+)\]:\s+(https?://\S+)");

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

/// Runs the detailed commit scope check for a commit message file.
/// This is invoked by the pre-commit commit-msg hook.
/// Returns 0 on success (allow commit), 1 on failure (block).
/// Check the given commit message (file path or "-" / empty for stdin) for
/// detailed scope compliance. Returns 0 on success (allow), 1 on violation (block).
RunExpected!void runCheckCommitScope(string msgSource)
{
    import std.file : readText;
    import std.process : execute;
    import std.regex : regex, matchFirst;
    import std.stdio : stderr;
    import std.string : lineSplitter, strip;

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
            return failRun("could not read the commit message file " ~ msgSource);
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
        return ranOk(); // nothing to check

    // Match conventional type(scope)?: or type:
    const subjectRe = regex(`^([a-zA-Z0-9_-]+)(?:\(([^)]*)\))?:\s*`);
    auto m = subject.matchFirst(subjectRe);
    if (m.empty)
        return ranOk(); // not a conventional subject we care about

    string scopeText = m.captures.length > 2 ? m.captures[2].strip : "";
    if (scopeText.length == 0)
        return ranOk(); // no scope present — allowed

    // Check useless scopes
    auto lowered = scopeText.asciiLower;
    if (badScopes.canFind(lowered))
    {
        stderr.writeln("✗ Useless commit scope detected.\n");
        stderr.writeln("  Subject: ", subject);
        stderr.writeln;
        stderr.writeln("Use a descriptive scope that helps `git log` readers locate the change.\n");
        stderr.writeln("Preferred patterns (examples):");
        stderr.writeln("  docs(research/window-system-integration)");
        stderr.writeln("  fix(base.buffer)");
        stderr.writeln("  feat(core-cli.ui.table)");
        stderr.writeln("  feat(core-cli/examples)");
        stderr.writeln("  feat(terminal)            # short is ok for small/cohesive packages");
        stderr.writeln("  config(lychee)");
        stderr.writeln;
        stderr.writeln("See docs/guidelines/AGENTS.md § \"Commit messages\".\n");
        stderr.writeln("Bypass (use sparingly): SKIP=detailed-scope git commit ...");
        stderr.writeln("or:                    git commit --no-verify");
        return failRun("useless commit scope `" ~ scopeText ~ "`");
    }

    // Heuristic for large bare package scopes
    if (largeBareScopes.canFind(scopeText))
    {
        auto diffRes = execute(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR"]);
        if (diffRes.status != 0)
            return ranOk(); // can't compute suggestion, allow

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
            return failRun("commit scope `" ~ scopeText ~ "` could be " ~ suggestion);
        }
    }

    return ranOk();
}

/// Given a list of staged paths (from git diff --cached --name-only), returns
/// a suggested more-detailed scope string (e.g. "base.buffer" or
/// "docs(research/foo)") or empty if no good suggestion.
private string computeDetailedScopeSuggestion(string[] changed)
{
    import std.regex : regex, matchFirst;
    import std.string : replace;

    const reResearch   = regex(`^docs/research/([^/]+)`);
    const reGuidelines = regex(`^docs/guidelines/([^/]+)`);
    const rePkgDeep    = regex(`^(libs|apps)/([^/]+)/.*/([^/.]+)\.(d|md)$`);
    const rePkgSrc     = regex(`^(libs|apps)/([^/]+)/src/.*/([^/.]+)\.d$`);
    const rePkgRoot    = regex(`^(libs|apps)/([^/]+)/([^/.]+)\.(d|md)$`);

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

/// `ci check reference-links` and `ci fix reference-links`.
RunExpected!void runReferenceLinksCommand(in FileSelection files, bool fix, bool dryRun = false)
{
    return collectInputFiles(files, InputFiles.markdown, fix ? "ci fix reference-links" : "ci check reference-links")
        .andThen!(mdFiles => runReferenceLinkMode(mdFiles, fix, dryRun));
}

/// `ci check vcs-urls`.
RunExpected!void runCheckVcsUrlsCommand(in FileSelection files)
{
    return collectInputFiles(files, InputFiles.markdown, "ci check vcs-urls")
        .andThen!(mdFiles => runCheckVcsUrls(mdFiles));
}

/// `ci check blob-paths`.
RunExpected!void runCheckBlobPathsCommand(in FileSelection files, string cloneRoot)
{
    return collectInputFiles(files, InputFiles.markdown, "ci check blob-paths")
        .andThen!(mdFiles => runCheckBlobPaths(mdFiles, cloneRoot));
}

private RunExpected!void runReferenceLinkMode(string[] mdFiles, bool fix, bool dryRun = false)
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
        return missingFiles > 0 ? failRun(text(missingFiles, " file(s) not found")) : ranOk();
    }

    printDuplicateGroups(duplicateGroups);

    if (!fix)
        return failRun(text(duplicateGroups.length, " duplicate reference group(s)"));

    auto changedFiles = fixDuplicateGroups(existingFiles, duplicateGroups, dryRun);

    writeln();
    if (dryRun)
        info(i"{green ✓} Would update $(changedFiles.length) file(s) (--dry-run: nothing written).");
    else
        info(i"{green ✓} Updated $(changedFiles.length) file(s).");
    foreach (filePath; changedFiles)
        writeln("  ", filePath);

    return missingFiles > 0 ? failRun(text(missingFiles, " file(s) not found")) : ranOk();
}

private RunExpected!void runCheckVcsUrls(string[] files)
{
    import std.file : readText;
    import std.regex : regex, matchAll, matchFirst;
    import std.string : lineSplitter;
    import std.algorithm : canFind;

    // The github blob/tree path is optional: a directory link like
    // `github.com/o/r/tree/main` (a moving branch ref, no trailing file path)
    // must still be caught, so the ref group stands alone and `(?:/…)?` wraps
    // the path. Capture indices are unchanged (the wrapper is non-capturing).
    const urlRe = regex(`https?://(?:raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/([^#\s"'()\]]*)|(?:www\.)?github\.com/([^/]+)/([^/]+)/(blob|tree)/([^/#\s"'()\]]+)(?:/([^#\s"'()\]]*))?)`);
    const shaRe = regex(`^[0-9a-fA-F]{40}$`);

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
        return failRun(text(totalErrors, " unpinned GitHub URL(s)"));
    }

    info(i"{green ✓} All checked GitHub URLs refer to specific commit SHAs.");
    return ranOk();
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

Complements `ci check vcs-urls`, which proves only that a citation carries a
commit SHA rather than a moving ref. See `blob_paths` for why this is a local
check and why an unclonable repository is reported rather than failed.
+/
private RunExpected!void runCheckBlobPaths(string[] files, string cloneRoot)
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
        return failRun("no clone root: pass --clone-root DIR or set REPOS");
    }
    if (!root.exists || !root.isDir)
    {
        stderr.writefln("✗ Clone root is not a directory: %s", root);
        return failRun("clone root is not a directory: " ~ root);
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
            return failRun(filePath ~ ": could not read file");
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
        stderr.writeln("These 404 upstream. ci check vcs-urls cannot catch them: it "
            ~ "verifies the ref, not the path.");
        return failRun("SHA-pinned citation(s) name paths that do not exist");
    }

    info(i"{green ✓} All $(report.okCount) verifiable blob citation(s) resolve at their pinned commit.");
    return ranOk();
}

/// Verify the VitePress sidebar is consistent with published docs pages
/// (pages → sidebar and sidebar → pages). Invoked by the pre-commit
/// `check-docs-sidebar` hook. Returns 0 when both directions are clean, 1
/// when pages are missing from the sidebar or sidebar links are dangling.

/++
`ci check adhoc-sdl`: no D source matches SDL text by hand (`sdl_audit`).

Whole-tree, like `ci check spec-evidence`: every tracked D source is read. A hit
the allowlist does not name fails, and so does an allowlist entry that names
no hit any more, so the list only shrinks.
+/
RunExpected!void runCheckAdHocSdl()
{
    import std.file : exists, readText;
    import std.path : buildPath, extension;
    import std.string : splitLines;
    import sdl_audit : AdHocSdlHit, auditSource, parseAllowlist;

    const repoRoot = detectRepoRoot();
    const listed = execute(["git", "-C", repoRoot, "ls-files", "--", "*.d"]);
    if (listed.status != 0)
    return failRun("Failed to enumerate D sources with git ls-files");

    const allowlistPath = buildPath(repoRoot, "apps", "ci", "sdl-audit-allowlist.txt");
    size_t badLine;
    const allowed = allowlistPath.exists ? parseAllowlist(allowlistPath.readText, badLine) : null;
    if (badLine)
    return failRun(text(i"$(allowlistPath):$(badLine): expected `path | literal | reason`"));
    auto used = new bool[allowed.length];

    AdHocSdlHit[] unlisted;
    size_t files;
    foreach (rel; splitLines(listed.output))
    {
        const path = rel.strip;
        if (path.extension != ".d" || !buildPath(repoRoot, path).exists)
            continue;
        files++;
        foreach (hit; auditSource(path, readText(buildPath(repoRoot, path))))
        {
            bool found;
            foreach (i, entry; allowed)
                if (entry.path == hit.path && entry.literal == hit.literal.strip)
                    found = used[i] = true;
            if (!found)
                unlisted ~= hit;
        }
    }

    foreach (hit; unlisted)
        error(i"$(hit.path):$(hit.line): `$(hit.call)` matches SDL text `$(hit.literal)`; use sparkles.wired.sdl or the dub.sdl schema, or allowlist it with a reason");
    size_t stale;
    foreach (i, entry; allowed)
        if (!used[i])
        {
            error(i"$(allowlistPath): `$(entry.path) | $(entry.literal)` matches nothing; delete it");
            stale++;
        }
    if (unlisted.length || stale)
        return failRun(text(unlisted.length + stale, " ad-hoc SDL match(es) or stale allowlist entries"));
    info(i"✓ No ad-hoc SDL: $(files) D sources checked, $(allowed.length) allowlisted matches reviewed.");
    return ranOk();
}

/++
`ci check opaque-recipes`: the recipe entries no input set can hold
(`opaque_recipes`), on every host the repository builds on.

Each is reported with what to write instead. One the allowlist does not name
fails, and so does an allowlist entry that names none any more, so a new
opaque entry is a reviewed decision and the list only shrinks.
+/
RunExpected!void runCheckOpaqueRecipes()
{
    import std.file : exists, readText;
    import std.path : buildPath;
    import opaque_recipes : opaqueEntries, repositoryHosts;
    import sdl_audit : parseAllowlist;
    import sparkles.build_primitives.workspace.discovery : readWorkspaceAt;

    const repoRoot = detectRepoRoot();
    auto workspace = readWorkspaceAt(repoRoot);
    if (workspace.hasError)
    {
        const detail = workspace.error.detail;
        return failRun(text(i"cannot read the workspace: $(detail)"));
    }

    const allowlistPath = buildPath(repoRoot, "apps", "ci", "opaque-recipe-allowlist.txt");
    size_t badLine;
    const allowed = allowlistPath.exists ? parseAllowlist(allowlistPath.readText, badLine) : null;
    if (badLine)
    return failRun(text(i"$(allowlistPath):$(badLine): expected `recipe | entry | reason`"));
    auto used = new bool[allowed.length];

    const entries = opaqueEntries(workspace.value.rootName, workspace.value.recipes, repositoryHosts);
    size_t unlisted;
    foreach (ref e; entries)
    {
        bool found;
        foreach (i, a; allowed)
            if (a.path == e.recipe && a.literal == e.entry)
                found = used[i] = true;
        const line = e.diagnostic;
        if (found)
            info(i"$(line) (allowlisted)");
        else
        {
            error(i"$(line) Allowlist it with a reason only if it cannot go.");
            unlisted++;
        }
    }
    size_t stale;
    foreach (i, a; allowed)
        if (!used[i])
        {
            const recipe = a.path, entry = a.literal;
            error(i"$(allowlistPath): `$(recipe) | $(entry)` matches nothing; delete it");
            stale++;
        }
    if (unlisted || stale)
        return failRun(text(unlisted + stale, " opaque recipe entr(ies) or stale allowlist entries"));
    info(i"✓ Opaque recipe entries: $(entries.length) found, each allowlisted with a reason.");
    return ranOk();
}

/++
`ci check spec-evidence`: every symbol a spec's evidence column cites must exist.

Whole-tree, like `ci check sidebar`: a requirement's traceability claim is
not a property of the diff that touched it, and the rows that rot are precisely
the ones nobody is editing.
+/
RunExpected!void runCheckSpecEvidence(bool updateBacklog, bool dryRun = false)
{
    import std.file : exists, readText, write;
    import std.path : buildPath, extension;
    import std.string : splitLines;

    const repoRoot = detectRepoRoot();

    const specs = execute(["git", "-C", repoRoot, "ls-files", "--", "docs/specs"]);
    if (specs.status != 0)
    return failRun("Failed to enumerate spec files with git ls-files");

    const srcList = execute(["git", "-C", repoRoot, "ls-files"]);
    if (srcList.status != 0)
    return failRun("Failed to enumerate D sources with git ls-files");

    // Paths resolve against every tracked file; identifiers only against D
    // sources, whose contents are the only ones worth reading for a symbol.
    string[] paths;
    string[string] sources;
    foreach (rel; splitLines(srcList.output))
    {
        const path = rel.strip;
        if (path.length == 0)
            continue;
        paths ~= path;
        if (path.extension != ".d")
            continue;
        try
            sources[path] = readText(buildPath(repoRoot, path));
        catch (Exception)
        {
        }
    }

    Citation[] cites;
    size_t files;
    foreach (rel; splitLines(specs.output))
    {
        const path = rel.strip;
        if (path.length == 0 || path.extension != ".md")
            continue;
        ++files;
        try
            cites ~= citationsIn(path, readText(buildPath(repoRoot, path)));
        catch (Exception)
        {
        }
    }

    const bad = unresolvedCitations(cites, sources, paths);
    const backlogFile = buildPath(repoRoot, backlogPath);

    if (updateBacklog)
    {
        if (dryRun)
        {
            info(i"✓ Would write $(backlogPath) (--dry-run: nothing written): $(bad.length) unresolved citation(s) of $(cites.length) in $(files) spec files.");
            return ranOk();
        }
        writeAtomically(backlogFile, renderBacklog(bad));
        info(i"✓ Wrote $(backlogPath): $(bad.length) unresolved citation(s) of $(cites.length) in $(files) spec files.");
        return ranOk();
    }

    const r = ratchet(bad, backlogFile.exists ? readText(backlogFile) : "");
    foreach (u; r.fresh)
        error(i"$(u.cite.file):$(u.cite.line): $(u.cite.id) cites `$(u.cite.token)` — no `$(u.name)` anywhere in the tree");
    foreach (key; r.stale)
        error(i"$(backlogPath): `$(key)` resolves now (or its row is gone) — delete the line");

    if (r.fresh.length || r.stale.length)
    {
        if (r.fresh.length)
            error(i"✗ $(r.fresh.length) new unresolved citation(s) of $(cites.length) in $(files) spec files — an evidence column that names nothing turns the delivery gate into decoration.");
        if (r.stale.length)
        return failRun(text(i"$(r.stale.length) line(s) in $(backlogPath) no longer apply — the backlog only shrinks."));
    }

    if (r.known)
        info(i"✓ Spec evidence: no new unresolved citations of $(cites.length) across $(files) spec files; $(r.known) known ones remain in $(backlogPath).");
    else
        info(i"✓ Spec evidence resolves: all $(cites.length) cited symbols across $(files) spec files name something in the tree.");
    return ranOk();
}

/++
`ci check glossary`: the glossary data is well formed, and every docs link into
it names an entry (`sparkles.docs.glossary.checkGlossary`).

Whole-tree, like `ci check sidebar`: deleting an entry breaks pages the
change never touched.
+/
RunExpected!void runCheckGlossary()
{
    const repoRoot = detectRepoRoot();

    auto entries = loadGlossary(repoRoot);
    if (entries.hasError)
    return failRun(text(i"Could not read the glossary $(glossaryDataPath): $(entries.error)"));

    const listed = execute(["git", "-C", repoRoot, "ls-files", "--", "docs"]);
    if (listed.status != 0)
    return failRun("Failed to enumerate docs files with git ls-files");

    GlossaryReference[] refs;
    // A draft specification may own terms before its package exists, so an
    // owner declared in a spec page's front matter counts as known.
    string[] owners = inTreePackageNames(repoRoot);
    size_t files;
    foreach (path; listed.output.lineSplitter.filter!(l => l.endsWith(".md")))
    {
        const full = repoRoot.buildPath(path);
        if (!full.exists) // deleted in the working tree, not yet staged
            continue;
        const markdown = full.readText;
        refs ~= glossaryReferences(path.idup, markdown);
        if (path.startsWith("docs/specs/"))
            if (const owner = frontMatterOwner(markdown))
                if (!owners.canFind(owner))
                    owners ~= owner.idup;
        ++files;
    }

    const report = checkGlossary(entries.value, owners, refs);
    foreach (id; report.unused)
        info(i"Glossary entry $(id) is not linked from any docs page.");

    if (!report.ok)
    {
        foreach (e; report.errors)
            error(i"✗ $(e)");
        return failRun(text(i"$(report.errors.length) glossary problem(s); see docs/guidelines/spec-prose.md#link-terms-to-the-glossary."));
    }

    info(i"✓ Glossary is consistent: $(entries.value.length) entries, $(refs.length) links from $(files) docs pages.");
    return ranOk();
}

/// TC23's gate; see `derivation_pin.checkToolchainCached`.
RunExpected!void runCheckPinCache()
{
    version (Posix)
    {
        import derivation_pin : checkToolchainCached;

        auto checked = checkToolchainCached(environment.get("CACHIX_CACHE", "sparkles"));
        if (!checked.hasError)
            return ranOk();
        return failRun(checked.error);
    }
    else
    return failRun("ci check pin-cache needs a POSIX host");
}

/// `ci check credits`: the credits document against the build inputs (`credits`).
RunExpected!void runCheckCredits()
{
    import credits : checkCredits, creditsDir, partsDir;
    import std.file : dirEntries, isFile, SpanMode;
    import std.path : stripExtension;
    import std.stdio : stderr;

    const repoRoot = detectRepoRoot();
    string readOrNull(string rel) @safe
    {
        const path = buildPath(repoRoot, rel);
        return path.exists ? readText(path) : null;
    }

    string[string] parts;
    const partsPath = buildPath(repoRoot, partsDir);
    if (partsPath.exists)
        foreach (e; dirEntries(partsPath, "*.md", SpanMode.shallow))
            parts[e.name.baseName.stripExtension] = readText(e.name);

    string[string] pages;
    foreach (e; dirEntries(buildPath(repoRoot, creditsDir), "*.md", SpanMode.shallow))
        pages[e.name.baseName.stripExtension] = readText(e.name);

    const report = checkCredits(&readOrNull, parts, pages);
    if (report.ok)
    {
        info(i"{green ✓} Credits are complete: $(report.partCount) parts cover the $(report.tokenCount) components the build inputs name, and every page includes exactly its own parts.");
        return ranOk();
    }

    void section(string title, in string[] lines)
    {
        if (!lines.length)
            return;
        stderr.writefln("✗ %s (%d):", title, lines.length);
        foreach (line; lines)
            stderr.writefln("  %s", line);
        stderr.writeln;
    }

    section("Malformed inputs or parts", report.problems);
    section("Shipped, and credited by no part — add docs/credits/parts/<id>.md naming it in `Ships as`",
        report.uncredited
            .map!(s => s.token ~ "  (" ~ (s.app.length ? s.app ~ ", " : "") ~ "from " ~ s.origin ~ ")")
            .array);
    section("Parts that name nothing the build ships — remove the part or fix its `Ships as`",
        report.unshipped.map!(s => partsDir ~ "/" ~ s ~ ".md").array);
    section("Pages that include the wrong parts", report.pageErrors);
    return failRun("the credits do not match the build inputs");
}

RunExpected!void runCheckDocsSidebar()
{
    import std.stdio : stderr;

    const repoRoot = detectRepoRoot();

    // The sidebar tree and srcExclude list are data files `config.mts` imports;
    // see sparkles.docs.sidebar. A malformed or missing file is a hard error — never an
    // empty link set that would flag every page as unlinked.
    auto sidebar = loadSidebar(repoRoot);
    if (sidebar.hasError)
    return failRun(text(i"Could not read the docs sidebar: $(sidebar.error)"));

    auto docsConfig = loadDocsConfig(repoRoot);
    if (docsConfig.hasError)
    return failRun(text(i"Could not read the docs config: $(docsConfig.error)"));

    // Tracked docs markdown only (excludes untracked WIP and docs/public assets).
    const result = execute(["git", "-C", repoRoot, "ls-files", "--", "docs"]);
    if (result.status != 0)
    return failRun("Failed to enumerate docs files with git ls-files");

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
        return ranOk();
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

    return failRun("the docs sidebar does not match the published pages");
}

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

    const lower = label.unicodeLower;
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

private string[] fixDuplicateGroups(string[] mdFiles, DuplicateGroup[] groups, bool dryRun = false)
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
            // Every file's rewrite is computed before any is written; each
            // write replaces its file whole (§5.6).
            if (!dryRun)
                writeAtomically(filePath, rewritten);
            changedFiles ~= filePath;
        }
    }

    return changedFiles;
}

/// Replaces `path` with `content` whole: written beside it, then renamed
/// over it, so a reader sees the old file or the new one (ci task-DAG §5.6).
void writeAtomically(string path, scope const(char)[] content)
{
    import std.conv : text;
    import std.file : rename, write;
    import std.process : thisProcessID;

    const staging = text(path, ".ci-", thisProcessID, ".tmp");
    write(staging, content);
    rename(staging, path);
}
