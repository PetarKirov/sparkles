#!/usr/bin/env dub
/+ dub.sdl:
    name "gen_unicode_tables"
    dependency "sparkles:base" path="../../.."
    dependency "sparkles:core-cli" path="../../.."
    libs "curl"
+/

/**
 * Generator for `sparkles.base.text.unicode_tables`.
 *
 * Emits the handful of Unicode properties that Phobos's `std.uni` does NOT ship
 * — East Asian Width (UAX #11) and the emoji variation-selector bases (UTS #51)
 * — as `@safe pure nothrow @nogc` binary-search membership functions, using
 * Phobos's own `CodepointSet.toSourceCode`. Everything else the width/wrap code
 * needs (Mn|Me|Cf, Ideographic, Regional_Indicator, Variation_Selector) already
 * lives in `std.uni`'s `unicode.*` and is used directly — not regenerated here.
 *
 * Usage — regenerate the in-tree table for the pinned Unicode version:
 *   dub run --single gen_unicode_tables.d
 *
 * With no arguments it downloads `EastAsianWidth.txt` and
 * `emoji-variation-sequences.txt` from unicode.org (via `curl`) into a temp
 * directory, generates the module, and writes it back into the source tree.
 * Overrides:
 *   --unicode-version <ver>   target a different Unicode version (default below)
 *   --ucd-dir <dir>           use local UCD files instead of downloading
 *   --out-file <path>         write somewhere other than the in-tree module
 *
 * When `--ucd-dir` is given, `<dir>` must contain `EastAsianWidth.txt` and
 * `emoji-variation-sequences.txt`.
 */
module sparkles.base.tools.gen_unicode_tables;

import std.algorithm : splitter, map, filter, canFind, sum, findSplit;
import std.array : join, array;
import std.conv : to;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format, formattedRead;
import std.net.curl : download, HTTP, CurlException, CurlOption;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
import std.string : strip, startsWith, lineSplitter, outdent;
import std.uni : CodepointSet, isWhite;

import sparkles.base.styled_template : styledWriteln, styledWritelnErr;
import sparkles.core_cli.args : CliOption, HelpInfo, parseCliArgs;

/// Unicode version this generator targets by default. Keep matched to the
/// toolchain's std.uni grapheme tables; bump when you upgrade the compiler.
enum pinnedUnicodeVersion = "17.0.0";

/// Base URL of the Unicode Character Database.
enum ucdBaseUrl = "https://www.unicode.org/Public";

/// Default output: the in-tree generated module, resolved relative to this
/// source file so `dub run --single` writes straight into the work tree.
enum defaultOutFile = __FILE_FULL_PATH__
    .dirName
    .buildNormalizedPath("../src/sparkles/base/text/unicode_tables.d");

struct CliParams
{
    @CliOption(`u|ucd-dir`, "Directory with EastAsianWidth.txt and emoji-variation-sequences.txt. If omitted, they are downloaded from unicode.org for --unicode-version.")
    string ucdDir;

    @CliOption(`o|out-file`, "Path to write the generated module (default: the in-tree unicode_tables.d).")
    string outFile = defaultOutFile;

    @CliOption(`V|unicode-version`, "Unicode version to generate for. Keep matched to the toolchain's std.uni grapheme tables.")
    string unicodeVersion = pinnedUnicodeVersion;
}

int main(string[] args)
{
    const cli = args.parseCliArgs!CliParams(
        HelpInfo(
            "gen_unicode_tables",
            "Generate sparkles.base.text.unicode_tables from the Unicode Character Database",
        ),
    );

    const ver = cli.unicodeVersion;
    const outFile = buildNormalizedPath(cli.outFile);

    styledWritelnErr(i"{dim unicode version}: {cyan $(ver)}");
    styledWritelnErr(i"{dim output file}:     {cyan $(outFile)}");
    if (cli.ucdDir.length)
        styledWritelnErr(i"{dim source}:          {dim local} {cyan $(cli.ucdDir)}");
    else
        styledWritelnErr(i"{dim source}:          {dim downloading from unicode.org}");

    // Without --ucd-dir, fetch the two UCD inputs for `ver` into a temp dir
    // and remove them afterwards.
    string ucdDir = cli.ucdDir;
    string tmpDir;
    scope (exit) if (tmpDir.length) rmdirRecurse(tmpDir);

    if (!ucdDir.length)
    {
        tmpDir = tempDir.buildPath("gen_unicode_tables-" ~ thisProcessID.to!string);
        mkdirRecurse(tmpDir);
        fetchUcd(ver, "EastAsianWidth.txt", buildPath(tmpDir, "EastAsianWidth.txt"));
        fetchUcd(ver, "emoji/emoji-variation-sequences.txt",
            buildPath(tmpDir, "emoji-variation-sequences.txt"));
        ucdDir = tmpDir;
    }

    auto eaw = ucdDir.buildPath("EastAsianWidth.txt").readText;
    auto emojiVs = ucdDir.buildPath("emoji-variation-sequences.txt").readText;
    auto wide = parseEastAsianWidth(eaw, ["W", "F"]);
    auto ambiguous = parseEastAsianWidth(eaw, ["A"]);
    auto emojiVsBase = parseEmojiVsBases(emojiVs);

    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(wide))} wide");
    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(ambiguous))} ambiguous");
    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(emojiVsBase))} emoji-vs bases");

    write(outFile, [
        header(ver),
        wide.toSourceCode("isEastAsianWide"),
        ambiguous.toSourceCode("isEastAsianAmbiguous"),
        emojiVsBase.toSourceCode("isEmojiVsBase"),
    ].join("\n"));

    styledWriteln(i"{green wrote} {cyan $(outFile)}");
    styledWriteln(i"Review the diff and commit the regenerated module.");
    return 0;
}

/// Download a UCD input for Unicode `ver` into `dest` via libcurl
/// (`std.net.curl`). Mirrors `curl -fSL`: follow redirects and fail on an HTTP
/// error status instead of writing the error page to `dest`.
private void fetchUcd(string ver, string remotePath, string dest)
{
    const url = ucdBaseUrl ~ "/" ~ ver ~ "/ucd/" ~ remotePath;
    styledWritelnErr(i"{dim fetching} $(url)");

    auto http = HTTP();
    http.handle.set(CurlOption.failonerror, 1L); // -f: 4xx/5xx → throw, no body
    try
        download(url, dest, http);
    catch (CurlException e)
        throw new Exception(format("download failed for %s:\n%s", url, e.msg));
}

/// Parse a UCD property file (`code[..code] ; VALUE # comment`) collecting the
/// code points whose property value is one of `wanted`.
CodepointSet parseEastAsianWidth(string text, const(string)[] wanted)
    => text.ucdCodepoints!(v => wanted.canFind(v));

/// Parse emoji-variation-sequences.txt, collecting the base code points that
/// have an `emoji style` (… FE0F) presentation sequence — i.e. the bases VS16
/// promotes to emoji (width 2). Lines look like: `0023 FE0F ; emoji style; # …`.
CodepointSet parseEmojiVsBases(string text)
    => text.ucdCodepoints!(v => v.startsWith("emoji style"));

/// Collect, into a `CodepointSet`, the leading code-point column of every data
/// record whose value field (the column after the first `;`) satisfies
/// `valueMatches`. For each record: strip the trailing `# comment`, split on `;`
/// into whitespace-trimmed fields (comment-only and blank lines collapse to one
/// empty field and are dropped), take the first whitespace-separated token of the
/// code-point column, and read it as a `..`-separated hex sequence — so a bare
/// `AAAA` adds one code point, `AAAA..BBBB` adds the inclusive range, and the
/// `BASE VS` form (e.g. `0023 FE0F`) adds just `BASE`.
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
        set.add(cps[0], cps[$ - 1] + 1); // add takes a half-open [a, b) interval
    }
    return set;
}

/// Strip a trailing `# comment` and surrounding whitespace from a UCD line.
/// `findSplit("#")[0]` is the text before the first `#`, or the whole line when
/// there is none.
private string stripComment(string line) => line.findSplit("#")[0].strip;

private size_t countCodePoints(CodepointSet set)
{
    return set.byInterval
        .map!(ival => ival[1] - ival[0])
        .sum;
}

private string header(string ver)
{
    return format(`
        // Generated by libs/base/tools/gen_unicode_tables.d — DO NOT EDIT.
        //
        // Unicode %s East Asian Width (UAX #11) and emoji variation
        // selector bases (UTS #51) — the properties std.uni does not ship.
        // Pinned to match the toolchain's std.uni grapheme tables. Regenerate
        // by running ./libs/base/tools/gen_unicode_tables.d.
        module sparkles.base.text.unicode_tables;
    `.outdent[1 .. $], ver);
}
