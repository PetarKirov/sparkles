/**
`hue site`'s **discovery** ([`DSC1`](../../../docs/specs/docs/discovery.md)):
from the docs' published markdown to the set of source files that get listing
pages, plus the skip records the manifest carries (`DSC2`).

Link-driven, not a blanket walk: only files the docs actually reference — and
the renderable subtrees of directories they reference — get pages. The scan
honors `srcExclude` (an unpublished page's links do not count), the descent
and the `.gitignore`/glob filtering come from `sparkles:build-primitives`
through the document set, and the policy knobs are `docs/hue-site.json`
(`sparkles.docs.site.SiteConfig`).

Pure vocabulary (link extraction, routes, skip reasons, the manifest text)
lives in `sparkles.docs.site`; this module is the filesystem orchestration,
and `app.executeSite` the rendering.
*/
module site;

import std.algorithm.sorting : sort;
import std.conv : text;
import std.file : exists, getSize, isDir, readText;
import std.path : absolutePath, baseName, buildNormalizedPath, buildPath,
    dirName, extension, relativePath;
import std.string : endsWith, startsWith;

import sparkles.build_primitives.glob_walk : globWalkGitRepository, passesGlobs;
import sparkles.docs.sidebar : isSrcExcluded;
import sparkles.docs.site : extensionAllowed, extractMarkdownLinks,
    resolveLinkTarget, SiteConfig, SkippedFile, SkipReason, skipReasonName;
import sparkles.docs.source_set : isRenderable, plainTally, SourceEntry, SourceSet;

/// What discovery found: the document set (sorted by path, repo-relative
/// `relPath`/`outPath`, mirrored under the output root) and the skip records.
struct SiteDiscovery
{
    SourceSet set;
    SkippedFile[] skipped;
}

/**
Resolves the site's document set from the markdown under `cfg.linkRoots`
(relative to `repoRoot`), per the parked loader's semantics with the policy
applied uniformly:

$(LIST
    $(ITEM every published (`srcExclude`-filtered) page's links are read;
        external, pure-anchor, and site-absolute targets are ignored)
    $(ITEM a linked $(B directory) expands to its renderable subtree — the
        `.gitignore`-aware document-set walk, filtered by the extension
        allow-list (extensionless conventional files pass by base name))
    $(ITEM a linked $(B file) is explicit intent: exempt from the allow-list,
        but the binary deny-list, `excludeGlobs`, and `maxFileSize` still
        apply — a failure is recorded as skipped, never silently published)
    $(ITEM the size cap applies to every candidate)
    $(ITEM `cfg.sourceRoots` join the linked-directory set unconditionally,
        so an opted-in subtree publishes whether or not the docs mention it)
)

Targets outside the repository, and links that do not resolve to an existing
path, drop out silently — they were never candidates.
*/
SiteDiscovery discoverSite(string repoRoot, in SiteConfig cfg,
    string[] srcExclude) @system
{
    const absRoot = repoRoot.absolutePath.buildNormalizedPath;

    bool[string] directFiles;
    bool[string] dirTargets;

    // `sourceRoots` (`DSC8`): standing links. A configured root enters the
    // same set a linked directory does, so it inherits the whole policy —
    // the `.gitignore` walk, the allow-list, the globs, the size cap — and
    // nothing downstream needs to know it was not written in a page.
    foreach (rootRel; cfg.sourceRoots)
    {
        const abs = buildPath(absRoot, rootRel);
        if (abs.exists && abs.isDir)
            dirTargets[rootRel] = true;
    }

    foreach (rootRel; cfg.linkRoots)
    {
        const rootAbs = buildPath(absRoot, rootRel);
        if (!rootAbs.exists)
            continue;
        foreach (pageRel; globWalkGitRepository(rootAbs))
        {
            if (!pageRel.endsWith(".md") || isSrcExcluded(pageRel, srcExclude))
                continue;
            const pageAbs = buildPath(rootAbs, pageRel);
            string src;
            try
                src = readText(pageAbs);
            catch (Exception)
                continue;
            const pageDir = pageAbs.dirName;
            foreach (link; extractMarkdownLinks(src))
            {
                const target = resolveLinkTarget(link);
                if (target is null)
                    continue;
                const abs = buildPath(pageDir, target).buildNormalizedPath;
                const rel = repoRelative(absRoot, abs);
                if (rel is null || !abs.exists)
                    continue;
                if (abs.isDir)
                    dirTargets[rel] = true;
                else if (!rel.endsWith(".md"))
                    directFiles[rel] = true;
            }
        }
    }

    bool[string] included;
    SkippedFile[] skipped;
    bool[string] skippedSeen;

    void skip(string rel, SkipReason r)
    {
        if (rel in skippedSeen)
            return;
        skippedSeen[rel] = true;
        skipped ~= SkippedFile(rel, skipReasonName(r));
    }

    // Directory expansion through the document set. An allow-list miss here is
    // the policy working, not an event — only *linked* things earn a skip
    // record, so the manifest stays link-relevant.
    foreach (dirRel; dirTargets.byKey)
    {
        import sparkles.docs.source_set : collectSources;

        auto sub = collectSources(buildPath(absRoot, dirRel), false,
            recursive: true, root: absRoot, null, cfg.excludeGlobs);
        foreach (ref e; sub.entries)
        {
            if (!extensionAllowed(e.relPath, cfg.extensions)
                && e.relPath.baseName.extension.length != 0)
                continue;
            included[e.relPath] = true;
        }
    }

    // Directly-linked files: explicit intent, so no allow-list — but the
    // deny-list, the globs, and (below) the size cap still hold, with the
    // verdict recorded (`DSC2`).
    foreach (rel; directFiles.byKey)
    {
        if (rel in included)
            continue;
        if (!passesGlobs(rel, null, cfg.excludeGlobs))
        {
            skip(rel, SkipReason.excluded);
            continue;
        }
        if (!isRenderable(rel, false))
        {
            skip(rel, SkipReason.ext);
            continue;
        }
        included[rel] = true;
    }

    string[] files;
    foreach (rel; included.byKey)
    {
        ulong size;
        try
            size = getSize(buildPath(absRoot, rel));
        catch (Exception)
            continue;
        if (size > cfg.maxFileSize)
        {
            skip(rel, SkipReason.size_);
            continue;
        }
        files ~= rel;
    }
    files.sort;

    SourceEntry[] entries;
    foreach (rel; files)
    {
        const abs = buildPath(absRoot, rel);
        string summary;
        try
            summary = plainTally(rel, readText(abs));
        catch (Exception)
            summary = "unreadable";
        entries ~= SourceEntry(path: abs, name: rel.baseName, summary: summary,
            relPath: rel, outPath: rel ~ ".html");
    }
    return SiteDiscovery(set: SourceSet(entries: entries), skipped: skipped);
}

/// `abs` relative to `absRoot` with `/` separators, or `null` when `abs` is
/// not strictly inside it (a listing tree cannot contain `..` or the root
/// itself).
private string repoRelative(string absRoot, string abs) @system
{
    const rel = relativePath(abs, absRoot);
    if (rel == "." || rel.startsWith(".."))
        return null;
    version (Windows)
    {
        import std.string : replace;

        return rel.replace("\\", "/");
    }
    else
        return rel;
}

// ---------------------------------------------------------------------------

version (unittest)
{
    /// A throwaway repo tree: `files` are `path → text` pairs written under a
    /// fresh root, returned for the caller to delete.
    private string makeSiteTree(scope const(string[2])[] files) @system
    {
        import std.file : mkdirRecurse, tempDir, write;
        import std.uuid : randomUUID;

        const root = buildPath(tempDir(), "hue-site-" ~ randomUUID.toString);
        foreach (ref f; files)
        {
            const path = buildPath(root, f[0]);
            mkdirRecurse(path.dirName);
            write(path, f[1]);
        }
        return root;
    }
}

/// Link-driven end to end: a page links a file and a directory; the directory
/// expands (allow-list applied, `.gitignore` honored), the direct link is
/// exempt from the allow-list, and unpublished pages' links do not count.
@("site.discoverSite.linkDrivenExpansionAndPolicy")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : rmdirRecurse;

    const root = makeSiteTree([
        ["libs/a/.gitignore", "build/\n"],
        ["docs/index.md", "See [a](../libs/a/src/x.d) and [the lib](../libs/a).\n"],
        ["docs/hidden/page.md", "[secret](../../libs/secret.rs)\n"],
        ["docs/notes.md", "[readme](../README.rst)\n"],
        ["libs/a/src/x.d", "module x;\n"],
        ["libs/a/src/y.rs", "fn y() {}\n"],   // not in the allow-list
        ["libs/a/Makefile", "all:\n"],        // extensionless, conventional
        ["libs/a/build/out.d", "ignored\n"],  // gitignored
        ["libs/secret.rs", "fn s() {}\n"],
        ["README.rst", "hi\n"],               // directly linked: allow-list exempt
    ]);
    scope (exit)
        rmdirRecurse(root);

    const cfg = SiteConfig().withDefaults;
    auto d = discoverSite(root, cfg, ["**/hidden/**"]);

    assert(d.set.entries.map!(e => e.relPath).array
        == ["README.rst", "libs/a/Makefile", "libs/a/src/x.d"],
        d.set.entries.map!(e => e.relPath).array.idup.text);
    // The excluded page's link produced nothing — not even a skip record.
    assert(d.skipped.length == 0, d.skipped.text);
    // Pages mirror repo paths.
    assert(d.set.entries[2].outPath == "libs/a/src/x.d.html");
    assert(d.set.entries[2].summary == "d · 1 line");
}

/// The policy on directly-linked files is recorded, not silent: too large →
/// `size`, binary → `ext`, glob-excluded → `excluded` (`DSC2`).
@("site.discoverSite.skipsAreRecordedWithReasons")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : rmdirRecurse;

    char[] big;
    big.length = 100;
    big[] = 'x';
    const root = makeSiteTree([
        ["docs/index.md", "[b](../big.txt) [p](../logo.png) [l](../x.log)\n"
            ~ "[ok](../ok.txt)\n"],
        ["big.txt", big.idup],
        ["logo.png", "\x89PNG\n"],
        ["x.log", "line\n"],
        ["ok.txt", "fine\n"],
    ]);
    scope (exit)
        rmdirRecurse(root);

    auto cfg = SiteConfig(maxFileSize: 50, excludeGlobs: ["*.log"]).withDefaults;
    auto d = discoverSite(root, cfg, null);

    assert(d.set.entries.map!(e => e.relPath).array == ["ok.txt"]);
    auto sk = d.skipped.dup;
    sk.sort!((a, b) => a.path < b.path);
    assert(sk.map!(s => s.path ~ ":" ~ s.reason).array
        == ["big.txt:size", "logo.png:ext", "x.log:excluded"], sk.text);
}

/// `sourceRoots` publish a subtree the docs never link (`DSC8`), through the
/// same policy a linked directory gets: allow-list, `.gitignore`, globs.
@("site.discoverSite.sourceRootsPublishUnlinkedSubtrees")
@system
unittest
{
    import std.algorithm.iteration : map;
    import std.array : array;
    import std.file : rmdirRecurse;

    const root = makeSiteTree([
        ["libs/a/.gitignore", "build/\n"],
        ["docs/index.md", "no links here\n"],
        ["libs/a/src/x.d", "module x;\n"],
        ["libs/a/src/y.rs", "fn y() {}\n"],   // allow-list miss, as when linked
        ["libs/a/build/out.d", "ignored\n"],  // gitignored
        ["apps/b/main.d", "void main() {}\n"],
        ["other/z.d", "module z;\n"],         // outside the roots
    ]);
    scope (exit)
        rmdirRecurse(root);

    auto cfg = SiteConfig(sourceRoots: ["apps", "libs", "absent"]).withDefaults;
    auto d = discoverSite(root, cfg, null);

    assert(d.set.entries.map!(e => e.relPath).array
        == ["apps/b/main.d", "libs/a/src/x.d"],
        d.set.entries.map!(e => e.relPath).array.idup.text);
    assert(d.skipped.length == 0, d.skipped.text);
}
