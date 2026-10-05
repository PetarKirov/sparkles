/** Manifest-authenticated raw Unicode access for independent conformance
 * interpretation. Property membership uses owned ASCII parsing and intervals,
 * not the generated tables or compiler Unicode sets.
 */
module sparkles.text_conformance.ucd;

import std.algorithm : startsWith;
import std.file : exists, mkdirRecurse, readText;
import std.digest.sha : sha256Of;
import std.json : parseJSON;
import std.format : format;
version (TextConformanceNoCurl) {} // offline build: no libcurl linkage
else import std.net.curl : HTTP, CurlException, CurlOption;
import std.path : buildPath, dirName;

import sparkles.core_cli.common_dirs : cacheDir;

import sparkles.text_conformance.config : Config;

/// Base URL of the Unicode Character Database.
enum ucdBaseUrl = "https://www.unicode.org/Public";

/// Raw-UCD inputs the Layer-1 width oracle classifies code points from.
struct WidthData
{
    CodepointRanges wide;        /// East-Asian Wide/Fullwidth (`W`, `F`).
    CodepointRanges zeroCat;     /// Marks + format: `Mn | Mc | Me | Cf`.
    CodepointRanges controls;    /// General category `Cc`.
    CodepointRanges emojiVsBase; /// Bases with an `emoji style` (FE0F) sequence.
    CodepointRanges mn, mc, me, cf;
}

/// All raw artifacts are authenticated against the implementation's manifest.
string ucdText(string ver, string remoteRelPath, in Config cfg)
{
    if (ver != cfg.versionIdentity)
        throw new Exception("Unicode release differs from generated manifest");
    return authenticatedFetch("ucd/" ~ remoteRelPath, cfg);
}

string emojiTestText(in Config cfg)
{
    return authenticatedFetch("emoji/emoji-test.txt", cfg);
}

private string authenticatedFetch(string relativePath, in Config cfg)
{
    const manifestText = readText(cfg.manifestPath);
    auto manifestHash = sha256Of(cast(const(ubyte)[]) manifestText);
    string identity;
    foreach (byteValue; manifestHash) identity ~= format("%02x", byteValue);
    if (identity != cfg.manifestIdentity)
        throw new Exception("conformance manifest differs from generated implementation");
    auto manifest = parseJSON(manifestText);
    foreach (artifact; manifest["artifacts"].array)
    {
        if (artifact["path"].str != relativePath) continue;
        const text = cachedFetch(cfg.versionIdentity ~ "/" ~ relativePath, relativePath, cfg);
        auto hash = sha256Of(cast(const(ubyte)[]) text);
        string actual;
        foreach (byteValue; hash) actual ~= format("%02x", byteValue);
        if (actual != artifact["sha256"].str)
            throw new Exception("conformance artifact SHA-256 mismatch: " ~ relativePath);
        return text;
    }
    throw new Exception("conformance artifact absent from manifest: " ~ relativePath);
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
    const dest = buildPath(cache, "sparkles-text-conformance", cfg.manifestIdentity, cacheRelPath);
    if (dest.exists)
        return dest.readText;

    if (cfg.noNetwork)
        throw new Exception(format("--no-network and cache miss for %s", urlSuffix));

    mkdirRecurse(dest.dirName);
    download(ucdBaseUrl ~ "/" ~ urlSuffix, dest);
    return dest.readText;
}

/// Download `ucdBaseUrl/urlSuffix` into `dest` via libcurl. Mirrors `curl -fSL`.
/// In the offline (`TextConformanceNoCurl`) build there is no libcurl linkage,
/// so any cache miss is a hard error directing the caller to `--ucd-dir`.
private void download(string url, string dest)
{
    version (TextConformanceNoCurl)
        throw new Exception("built without curl (offline config); "
            ~ "provide --ucd-dir with a cached copy of " ~ url);
    else
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
}

/// Load independently interpreted raw width inputs from the single manifest.
WidthData loadWidthData(in Config cfg)
{
    const eaw = ucdText(cfg.versionIdentity, "EastAsianWidth.txt", cfg);
    const gc = ucdText(cfg.versionIdentity, "extracted/DerivedGeneralCategory.txt", cfg);
    const emojiVs = ucdText(cfg.versionIdentity, "emoji/emoji-variation-sequences.txt", cfg);

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

/// Owned sorted half-open intervals for the independently interpreted oracle.
struct CodepointRanges
{
    private struct Interval { uint begin, end; }
    private Interval[] intervals;

    void add(uint begin, uint end)
    {
        if (begin >= end || end > 0x110000) throw new Exception("invalid codepoint interval");
        size_t lo;
        while (lo < intervals.length && intervals[lo].end < begin) ++lo;
        size_t hi = lo;
        while (hi < intervals.length && intervals[hi].begin <= end)
        {
            if (intervals[hi].begin < begin) begin = intervals[hi].begin;
            if (intervals[hi].end > end) end = intervals[hi].end;
            ++hi;
        }
        const oldLength = intervals.length;
        if (hi == lo)
        {
            intervals.length = oldLength + 1;
            for (size_t i = oldLength; i > lo; --i) intervals[i] = intervals[i - 1];
        }
        else if (hi > lo + 1)
        {
            foreach (i; hi .. oldLength) intervals[lo + 1 + i - hi] = intervals[i];
            intervals.length = oldLength - (hi - lo - 1);
        }
        intervals[lo] = Interval(begin, end);
    }
    bool opIndex(dchar cp) const scope @safe pure nothrow @nogc
    {
        size_t lo, hi = intervals.length;
        while (lo < hi)
        {
            const mid = lo + (hi - lo) / 2;
            if (intervals[mid].end <= cp) lo = mid + 1; else hi = mid;
        }
        return lo < intervals.length && intervals[lo].begin <= cp;
    }
    CodepointRanges opBinary(string op)(scope const CodepointRanges rhs) const
        if (op == "|")
    {
        CodepointRanges result;
        result.intervals = intervals.dup;
        foreach (interval; rhs.intervals) result.add(interval.begin, interval.end);
        return result;
    }
}
private bool asciiWhite(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}
private string asciiTrim(string text) @safe pure nothrow @nogc
{
    size_t a, b = text.length;
    while (a < b && asciiWhite(text[a])) ++a;
    while (b > a && asciiWhite(text[b-1])) --b;
    return text[a .. b];
}
private uint rawHex(string text)
{
    if (!text.length) throw new Exception("empty codepoint field");
    uint n;
    foreach (char c; text)
    {
        const d = c >= '0' && c <= '9' ? c - '0' :
            c >= 'A' && c <= 'F' ? c - 'A' + 10 :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : uint.max;
        if (d >= 16 || n > (0x10FFFF - d) / 16) throw new Exception("invalid codepoint field");
        n = n * 16 + d;
    }
    return n;
}
/// Parse membership independently of the production generator. Comment bytes
/// never participate in field decoding, and only ASCII separates data fields.
CodepointRanges ucdCodepoints(alias valueMatches)(string text)
{
    CodepointRanges set;
    size_t start;
    while (start < text.length)
    {
        size_t end = start;
        while (end < text.length && text[end] != '\n') ++end;
        auto line = text[start .. end]; start = end + 1;
        size_t comment;
        while (comment < line.length && line[comment] != '#') ++comment;
        line = asciiTrim(line[0 .. comment]);
        if (!line.length) continue;
        size_t semicolon;
        while (semicolon < line.length && line[semicolon] != ';') ++semicolon;
        if (semicolon == line.length) throw new Exception("property row missing value");
        auto code = asciiTrim(line[0 .. semicolon]);
        auto rest = line[semicolon + 1 .. $];
        size_t next;
        while (next < rest.length && rest[next] != ';') ++next;
        const value = asciiTrim(rest[0 .. next]);
        if (!valueMatches(value)) continue;
        size_t tokenEnd;
        while (tokenEnd < code.length && !asciiWhite(code[tokenEnd])) ++tokenEnd;
        code = code[0 .. tokenEnd];
        size_t dot;
        while (dot < code.length && code[dot] != '.') ++dot;
        uint first, last;
        if (dot == code.length) first = last = rawHex(code);
        else
        {
            if (dot + 2 >= code.length || code[dot + 1] != '.')
                throw new Exception("malformed property range");
            first = rawHex(code[0 .. dot]); last = rawHex(code[dot + 2 .. $]);
        }
        if (first > last) throw new Exception("reversed property range");
        set.add(first, last + 1);
    }
    return set;
}

unittest
{
    import std.exception : assertThrown;
    auto set = ucdCodepoints!(v => v == "W")(
        "# Unicode comment\n10000..10002; W # supplementary\n0041; W\n0042; N\n10FFFF; W\n");
    assert(set[0x41] && !set[0x42] && set[0x10000] && set[0x10002]);
    assert(!set[0xFFFF] && !set[0x10003] && set[0x10FFFF]);
    set.add(0x42, 0x45);
    assert(set[0x44] && !set[0x45]);
    assertThrown!Exception(ucdCodepoints!(v => true)("0042..0041; W\n"));
    assertThrown!Exception(ucdCodepoints!(v => true)("110000; W\n"));
    assertThrown!Exception(ucdCodepoints!(v => true)("0041.0042; W\n"));
}
