/**
 * Unicode Character Database access: download (with an XDG cache), an offline
 * `--ucd-dir` override, and the generic `code[..code] ; VALUE # comment` parser.
 *
 * The download/parse machinery mirrors `libs/base/tools/gen_unicode_tables.d`
 * deliberately — it is the established pattern in this repo. The crucial
 * difference for the conformance harness is that the Layer-1 oracle reads
 * *general categories* straight from `DerivedGeneralCategory.txt` rather than
 * from Phobos `std.uni`, so a bug or version skew shared with the library under
 * test cannot hide.
 */
module sparkles.text_conformance.ucd;

import std.algorithm : canFind, map, filter, splitter, startsWith, findSplit;
import std.array : array;
import std.file : exists, mkdirRecurse, readText;
import std.format : format, formattedRead;
import std.net.curl : HTTP, CurlException, CurlOption;
import std.path : buildPath, buildNormalizedPath, dirName;
import std.string : strip, lineSplitter;
import std.uni : CodepointSet, isWhite;

import sparkles.core_cli.common_dirs : cacheDir;

import sparkles.text_conformance.config : Config;

/// Base URL of the Unicode Character Database.
enum ucdBaseUrl = "https://www.unicode.org/Public";

/// Raw-UCD inputs the Layer-1 width oracle classifies code points from.
struct WidthData
{
    CodepointSet wide;        /// East-Asian Wide/Fullwidth (`W`, `F`).
    CodepointSet zeroCat;     /// Marks + format: `Mn | Mc | Me | Cf`.
    CodepointSet controls;    /// General category `Cc`.
    CodepointSet emojiVsBase; /// Bases with an `emoji style` (FE0F) sequence.
    // Individual mark categories, kept for diagnostic bucketing in Layer 1.
    CodepointSet mn, mc, me, cf;
}

/// Read a UCD file's text for `ver`. Resolution order: `--ucd-dir` (offline,
/// reading `<dir>/<remoteRelPath>` so a mirrored UCD tree works) → XDG cache →
/// download (unless `--no-network`). Downloads are cached under a
/// version-scoped subdir so the width and segmentation versions never collide.
string ucdText(string ver, string remoteRelPath, in Config cfg)
    => cachedFetch(ver ~ "/ucd/" ~ remoteRelPath, buildPath(ver, remoteRelPath), cfg);

/// Read `emoji-test.txt` for the segmentation version. Unicode publishes it
/// under `/Public/emoji/<major.minor>/`, not the UCD tree — hence the separate
/// URL/cache layout. (`15.0.0` → emoji `15.0`.)
string emojiTestText(in Config cfg)
{
    const emojiVer = emojiVersionOf(cfg.segVersion);
    return cachedFetch("emoji/" ~ emojiVer ~ "/emoji-test.txt",
        buildPath("emoji-" ~ emojiVer, "emoji-test.txt"), cfg);
}

/// Map a UCD version (`major.minor.patch`) to its emoji `major.minor` line.
private string emojiVersionOf(string ucdVersion)
{
    auto parts = ucdVersion.splitter('.').array;
    return parts.length >= 2 ? parts[0] ~ "." ~ parts[1] : ucdVersion;
}

/// Resolve a Unicode file by `urlSuffix` (appended to the Public base) with an
/// XDG cache at `cacheRelPath`. Offline `--ucd-dir` reads `<dir>/<cacheRelPath>`
/// so a mirrored layout works; `--no-network` fails on a cache miss.
private string cachedFetch(string urlSuffix, string cacheRelPath, in Config cfg)
{
    if (cfg.ucdDir.length)
    {
        const local = buildPath(cfg.ucdDir, cacheRelPath);
        if (!local.exists)
            throw new Exception(format("--ucd-dir given but %s is missing", local));
        return local.readText;
    }

    const cache = cacheDir();
    if (!cache.length)
        throw new Exception("cannot determine cache dir; pass --ucd-dir");
    const dest = buildPath(cache, "sparkles-text-conformance", cacheRelPath);
    if (dest.exists)
        return dest.readText;

    if (cfg.noNetwork)
        throw new Exception(format("--no-network and cache miss for %s", urlSuffix));

    mkdirRecurse(dest.dirName);
    download(ucdBaseUrl ~ "/" ~ urlSuffix, dest);
    return dest.readText;
}

/// Download `ucdBaseUrl/urlSuffix` into `dest` via libcurl. Mirrors `curl -fSL`.
private void download(string url, string dest)
{
    import std.net.curl : download;
    import std.stdio : stderr;
    stderr.writeln("  fetching ", url);

    auto http = HTTP();
    http.handle.set(CurlOption.failonerror, 1L);
    try
        download(url, dest, http);
    catch (CurlException e)
        throw new Exception(format("download failed for %s:\n%s", url, e.msg));
}

/// Load the three raw-UCD inputs the width oracle needs, for `cfg.widthVersion`.
WidthData loadWidthData(in Config cfg)
{
    const eaw = ucdText(cfg.widthVersion, "EastAsianWidth.txt", cfg);
    const gc = ucdText(cfg.widthVersion, "extracted/DerivedGeneralCategory.txt", cfg);
    const emojiVs = ucdText(cfg.widthVersion, "emoji/emoji-variation-sequences.txt", cfg);

    WidthData d;
    d.wide = eaw.ucdCodepoints!(v => v == "W" || v == "F");
    d.mn = gc.ucdCodepoints!(v => v == "Mn");
    d.mc = gc.ucdCodepoints!(v => v == "Mc");
    d.me = gc.ucdCodepoints!(v => v == "Me");
    d.cf = gc.ucdCodepoints!(v => v == "Cf");
    d.controls = gc.ucdCodepoints!(v => v == "Cc");
    d.zeroCat = d.mn | d.mc | d.me | d.cf;
    d.emojiVsBase = emojiVs.ucdCodepoints!(v => v.startsWith("emoji style"));
    return d;
}

/// Collect the leading code-point column of every data record whose value
/// field (after the first `;`) satisfies `valueMatches`, as a `CodepointSet`.
/// Handles bare `AAAA`, ranges `AAAA..BBBB`, and the `BASE VS` form.
CodepointSet ucdCodepoints(alias valueMatches)(string text)
{
    CodepointSet set;
    foreach (fields; text
        .lineSplitter
        .map!stripComment
        .map!(line => line.splitter(';').map!strip.array)
        .filter!(rec => rec.length >= 2 && valueMatches(rec[1])))
    {
        auto code = fields[0].splitter!isWhite.front;
        uint[] cps;
        code.formattedRead!"%(%x%|..%)"(cps);
        set.add(cps[0], cps[$ - 1] + 1);
    }
    return set;
}

/// Strip a trailing `# comment` and surrounding whitespace from a UCD line.
private string stripComment(string line) => line.findSplit("#")[0].strip;
