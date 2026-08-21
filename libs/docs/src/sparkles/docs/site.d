/++
The site-discovery vocabulary behind `hue site`
([`DSC1`–`DSC3`](../../../../../docs/specs/docs/discovery.md)): the
`docs/hue-site.json` knobs, markdown link extraction, the skip policy and its
machine-readable reasons, the `/src/…` route model, and the `manifest.json`
writer — every part of the pipeline that needs no filesystem, so it is pure
and tested without one. The I/O orchestration (scanning the pages, expanding
directories, rendering) lives in hue's `site` subcommand.

The semantics port the parked VitePress loader (`[filepath].paths.ts` on
`parked/vitepress-source-listings`), with its two known defects fixed by
construction: the extension/size policy applies to $(I every) candidate — an
explicitly linked file that fails it is recorded in `manifest.skipped` rather
than published (a skipped file simply never gets its link rewritten, so no
dead link results, [`DSC4`](../../../../../docs/specs/docs/discovery.md)) —
and the knobs live in one data file instead of two drifting copies.
+/
module sparkles.docs.site;

import std.array : Appender, appender;
import std.conv : text;

import sparkles.wired.json : readJSONFile;
import sparkles.wired.policy : WireOptional;

import sparkles.docs.sidebar : LoadResult;

/// Path of the site-discovery knobs, relative to the repository root. JSON,
/// like its `sidebar.json` / `docs-config.json` siblings — the spec first
/// sketched this file as TOML, but the repository's data-file convention (and
/// its only structured-data codec, `sparkles:wired`) is JSON.
enum siteConfigPath = "docs/hue-site.json";

/++
The `docs/hue-site.json` knobs (`DSC1`). Every field is optional in the file;
$(LREF withDefaults) folds the defaults in, so an absent file and an empty
object mean the same thing.
+/
struct SiteConfig
{
    /// Directories whose published markdown pages are scanned for links,
    /// relative to the repository root.
    @WireOptional() string[] linkRoots;

    /// Extension allow-list (lower-case, no dot) for files reached by
    /// $(I directory) expansion. A directly linked file is exempt — the link
    /// is explicit intent — but still subject to the binary deny-list and
    /// `maxFileSize`.
    @WireOptional() string[] extensions;

    /// Largest file that gets a listing page, in bytes. Larger ones are
    /// recorded as skipped (`size`).
    @WireOptional() ulong maxFileSize;

    /// `--exclude`-style globs (matched against the repo-relative path and
    /// the base name) dropping files from the site regardless of how they
    /// were reached; recorded as skipped (`excluded`).
    @WireOptional() string[] excludeGlobs;

    /// `this` with every unset field replaced by its default.
    SiteConfig withDefaults() const @safe pure nothrow
    {
        SiteConfig c = SiteConfig(
            linkRoots: linkRoots.dup,
            extensions: extensions.dup,
            maxFileSize: maxFileSize,
            excludeGlobs: excludeGlobs.dup);
        if (c.linkRoots.length == 0)
            c.linkRoots = ["docs"];
        if (c.extensions.length == 0)
            c.extensions = defaultExtensions.dup;
        if (c.maxFileSize == 0)
            c.maxFileSize = 40 * 1024;
        return c;
    }
}

/// The stock allow-list for directory expansion — the parked loader's set.
immutable string[] defaultExtensions = [
    "build", "c", "d", "go", "h", "json", "sdl", "sh", "toml", "txt", "work",
    "yaml", "yml",
];

/// Loads $(LREF SiteConfig) from an explicit path (defaults NOT yet folded —
/// callers decide whether an absent file is an error or means "all defaults").
LoadResult!SiteConfig loadSiteConfig(string path)
    => readJSONFile!SiteConfig(path);

// ── markdown link extraction ────────────────────────────────────────────────

/++
Every link target in `md`, in document order: inline `[text](url)` and
reference definitions `[label]: url` — the parked loader's exact vocabulary
(autolinks and raw HTML are out of scope there and here). Targets are returned
raw; classify them with $(LREF resolveLinkTarget).

Deliberately a plain byte scan, not a markdown parse: the loader this ports
scanned raw page text (code fences included), and a false positive resolves to
a path that does not exist and drops out — cheap and self-correcting.
+/
string[] extractMarkdownLinks(scope const(char)[] md) @safe pure
{
    auto found = appender!(string[]);

    // Inline links: `](` up to the next `)`.
    size_t i = 0;
    while (i + 1 < md.length)
    {
        if (md[i] == ']' && md[i + 1] == '(')
        {
            size_t j = i + 2;
            while (j < md.length && md[j] != ')')
                ++j;
            if (j < md.length && j > i + 2)
                found ~= md[i + 2 .. j].idup;
            i = j;
        }
        ++i;
    }

    // Reference definitions: a line of the form `[label]: url`.
    size_t lineStart = 0;
    foreach (k; 0 .. md.length + 1)
    {
        if (k != md.length && md[k] != '\n')
            continue;
        const line = md[lineStart .. k];
        lineStart = k + 1;
        if (line.length < 4 || line[0] != '[')
            continue;
        size_t close = 1;
        while (close < line.length && line[close] != ']')
            ++close;
        if (close + 1 >= line.length || line[close + 1] != ':' || close == 1)
            continue;
        size_t s = close + 2;
        while (s < line.length && (line[s] == ' ' || line[s] == '\t'))
            ++s;
        size_t e = s;
        while (e < line.length && line[e] != ' ' && line[e] != '\t' && line[e] != '#')
            ++e;
        if (e > s)
            found ~= line[s .. e].idup;
    }

    return found[];
}

/++
The file-system half of a link target: the fragment stripped, or `null` for a
target discovery never follows — external (`http:`/`https:`/`mailto:`),
pure-anchor, site-absolute (`/…` is a VitePress route, not a relative file),
or empty after stripping.
+/
string resolveLinkTarget(scope const(char)[] link) @safe pure
{
    import std.algorithm.searching : startsWith;

    if (link.length == 0 || link[0] == '#' || link[0] == '/')
        return null;
    if (link.startsWith("http://", "https://", "mailto:"))
        return null;
    size_t hash = 0;
    while (hash < link.length && link[hash] != '#')
        ++hash;
    return hash == 0 ? null : link[0 .. hash].idup;
}

// ── the skip policy (DSC1/DSC2) ─────────────────────────────────────────────

/// Why a candidate got no page — `manifest.skipped` distinguishes "excluded on
/// purpose" from "no page" (`DSC2`).
enum SkipReason : ubyte
{
    none, /// not skipped
    size_, /// larger than `SiteConfig.maxFileSize`
    ext, /// extension outside the allow-list (directory expansion), or binary
    excluded, /// matched an `excludeGlobs` entry
}

/// The manifest spelling of a reason.
string skipReasonName(SkipReason r) @safe pure nothrow @nogc
{
    final switch (r)
    {
        case SkipReason.none: return "";
        case SkipReason.size_: return "size";
        case SkipReason.ext: return "ext";
        case SkipReason.excluded: return "excluded";
    }
}

/// `true` iff `relPath`'s extension (lower-cased, no dot) is in `extensions`.
/// An extensionless file is not decided here — the document set's conventional
/// base-name allow-list (`source_set.isRenderable`) covers it.
bool extensionAllowed(scope const(char)[] relPath, scope const(string)[] extensions)
    @safe pure
{
    import std.algorithm.searching : canFind;
    import std.path : baseName, extension;
    import std.string : chompPrefix;
    import std.uni : toLower;

    const ext = relPath.baseName.extension.chompPrefix(".").toLower;
    return ext.length != 0 && extensions.canFind(ext);
}

// ── the route model (DSC3) ──────────────────────────────────────────────────

/// The prefix namespacing every listing route inside the docs site.
enum siteRoutePrefix = "/src/";

/// The route of the listing page for the repo-relative file `rel`. Explicitly
/// `.html`: directory-index and trailing-slash resolution differ between Vite
/// dev, `vitepress preview`, and static hosting; a full file name does not.
string listingRoute(scope const(char)[] rel) @safe pure
    => text(siteRoutePrefix, rel, ".html");

/// The route of the index page for the repo-relative directory `rel` (empty =
/// the site root's own index).
string directoryRoute(scope const(char)[] rel) @safe pure
    => rel.length ? text(siteRoutePrefix, rel, "/index.html")
        : text(siteRoutePrefix, "index.html");

// ── manifest.json (DSC2) ────────────────────────────────────────────────────

/// One `manifest.skipped` row.
struct SkippedFile
{
    string path; /// repo-relative
    string reason; /// $(LREF skipReasonName)
}

/++
The `manifest.json` text (`DSC2`): `files` (repo-relative path → route),
`dirs` (directory → its index route), `skipped` (path + reason). The single
interface the VitePress side reads (`DSC4`).

Deterministic by construction — each section is sorted by path — so the file
is diffable across runs and the build is reproducible modulo page content.
+/
string manifestJson(string[] files, string[] dirs, SkippedFile[] skipped) @safe pure
{
    import std.algorithm.sorting : sort;

    auto fs = files.dup;
    fs.sort;
    auto ds = dirs.dup;
    ds.sort;
    auto sk = skipped.dup;
    sk.sort!((a, b) => a.path < b.path);

    auto w = appender!string;
    w ~= "{\n  \"files\": {";
    foreach (i, f; fs)
    {
        w ~= i ? ",\n    " : "\n    ";
        writeJsonString(w, f);
        w ~= ": ";
        writeJsonString(w, listingRoute(f));
    }
    w ~= fs.length ? "\n  },\n" : "},\n";
    w ~= "  \"dirs\": {";
    foreach (i, d; ds)
    {
        w ~= i ? ",\n    " : "\n    ";
        writeJsonString(w, d);
        w ~= ": ";
        writeJsonString(w, directoryRoute(d));
    }
    w ~= ds.length ? "\n  },\n" : "},\n";
    w ~= "  \"skipped\": [";
    foreach (i, s; sk)
    {
        w ~= i ? ",\n    " : "\n    ";
        w ~= "{ \"path\": ";
        writeJsonString(w, s.path);
        w ~= ", \"reason\": ";
        writeJsonString(w, s.reason);
        w ~= " }";
    }
    w ~= sk.length ? "\n  ]\n}\n" : "]\n}\n";
    return w[];
}

/// A JSON string literal for a path: quotes, backslashes, and control bytes
/// escaped (paths carry nothing else that needs it).
private void writeJsonString(ref Appender!string w, scope const(char)[] s) @safe pure
{
    w ~= '"';
    foreach (char c; s)
        switch (c)
        {
            case '"': w ~= `\"`; break;
            case '\\': w ~= `\\`; break;
            case '\n': w ~= `\n`; break;
            case '\t': w ~= `\t`; break;
            default:
                if (c < 0x20)
                {
                    import sparkles.base.text.writers : writeHexByte;

                    w ~= `\u00`;
                    writeHexByte(w, c);
                }
                else
                    w ~= c;
                break;
        }
    w ~= '"';
}

// ---------------------------------------------------------------------------

@("site.SiteConfig.withDefaults")
@safe pure
unittest
{
    const def = SiteConfig().withDefaults;
    assert(def.linkRoots == ["docs"]);
    assert(def.maxFileSize == 40 * 1024);
    assert(def.extensions == defaultExtensions);

    // A partially-filled file keeps what it set and defaults the rest.
    const some = SiteConfig(maxFileSize: 1024, excludeGlobs: ["*.log"]).withDefaults;
    assert(some.maxFileSize == 1024);
    assert(some.excludeGlobs == ["*.log"]);
    assert(some.linkRoots == ["docs"]);
}

@("site.extractMarkdownLinks.inlineAndReference")
@safe pure
unittest
{
    const md = "See [x](../libs/base/src/a.d) and [y](https://example.org).\n"
        ~ "[spec]: ../../docs/specs/hue/gallery.md#gal2\n"
        ~ "Empty [z]() stays out; `code [n](not/a/link)` counts (raw scan).\n";
    const links = extractMarkdownLinks(md);
    assert(links == ["../libs/base/src/a.d", "https://example.org",
        "not/a/link", "../../docs/specs/hue/gallery.md"], text(links));
}

@("site.resolveLinkTarget.classification")
@safe pure
unittest
{
    // Relative targets survive, fragment stripped.
    assert(resolveLinkTarget("../a/b.d") == "../a/b.d");
    assert(resolveLinkTarget("../a/b.md#sec") == "../a/b.md");
    // External, pure-anchor, site-absolute and empty targets do not.
    assert(resolveLinkTarget("https://x.org/a.d") is null);
    assert(resolveLinkTarget("mailto:a@b.c") is null);
    assert(resolveLinkTarget("#anchor") is null);
    assert(resolveLinkTarget("/overview") is null);
    assert(resolveLinkTarget("") is null);
}

@("site.extensionAllowed.lowercasedAndDotless")
@safe pure
unittest
{
    assert(extensionAllowed("libs/a/src/x.d", defaultExtensions));
    assert(extensionAllowed("x.SDL", defaultExtensions));
    assert(!extensionAllowed("x.rs", defaultExtensions));
    // Extensionless is not this predicate's call.
    assert(!extensionAllowed("Makefile", defaultExtensions));
}

@("site.routes.filesDirsAndRoot")
@safe pure
unittest
{
    assert(listingRoute("libs/base/src/a.d") == "/src/libs/base/src/a.d.html");
    assert(directoryRoute("libs/base") == "/src/libs/base/index.html");
    assert(directoryRoute("") == "/src/index.html");
}

@("site.manifestJson.sortedAndEscaped")
@safe pure
unittest
{
    import std.algorithm.searching : canFind;

    const json = manifestJson(
        ["b.d", "a \"q\".d"],
        ["libs", ""],
        [SkippedFile("big.txt", "size")]);

    // Sections sorted by path, quotes escaped, routes derived.
    assert(json.canFind(`"a \"q\".d": "/src/a \"q\".d.html"`), json);
    const aAt = json.canFind(`"a \"q\".d"`);
    assert(aAt, json);
    assert(json.canFind(`"b.d": "/src/b.d.html"`), json);
    assert(json.canFind(`"": "/src/index.html"`), json);
    assert(json.canFind(`"libs": "/src/libs/index.html"`), json);
    assert(json.canFind(`{ "path": "big.txt", "reason": "size" }`), json);

    // Empty sections stay valid JSON.
    assert(manifestJson(null, null, null).canFind(`"files": {},`));
}
