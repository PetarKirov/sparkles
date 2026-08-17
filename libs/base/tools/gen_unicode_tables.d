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
 * Emits East Asian Width (UAX #11), emoji variation-selector bases (UTS #51),
 * and the normalization/case-fold/word-break tables needed by the bounded text
 * analyzer as `@safe pure nothrow @nogc` lookup functions. Property sets use
 * Phobos's `CodepointSet.toSourceCode`; sequence mappings use compact sorted
 * indexes over flat immutable data arrays.
 *
 * Usage — regenerate the in-tree table for the pinned Unicode version:
 *   dub run --single gen_unicode_tables.d
 *
 * With no arguments it downloads the width, emoji, normalization, case-fold,
 * and word-break inputs from unicode.org (via `curl`) into a temp directory,
 * generates the module, and writes it back into the source tree.
 * Overrides:
 *   --unicode-version <ver>   target a different Unicode version (default below)
 *   --ucd-dir <dir>           use local UCD files instead of downloading
 *   --out-file <path>         write somewhere other than the in-tree module
 *
 * When `--ucd-dir` is given, `<dir>` must contain `EastAsianWidth.txt`,
 * `emoji-variation-sequences.txt`, `UnicodeData.txt`, `CaseFolding.txt`,
 * `DerivedNormalizationProps.txt`, and `WordBreakProperty.txt`.
 */
module sparkles.base.tools.gen_unicode_tables;

import std.algorithm : splitter, map, filter, canFind, sort, sum, findSplit;
import std.array : appender, join, array;
import std.conv : to;
import std.file : mkdirRecurse, readText, rmdirRecurse, tempDir, write;
import std.format : format, formattedRead, formattedWrite;
import std.net.curl : download, HTTP, CurlException, CurlOption;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : thisProcessID;
import std.string : strip, startsWith, lineSplitter, outdent;
import std.uni : CodepointSet, isWhite;

import sparkles.base.styled_template : styledWriteln, styledWritelnErr;
import sparkles.core_cli.args : HelpInfo, Option, parseCli, reportCliError;

/// Unicode version this generator targets by default. All properties consumed
/// by the bounded analyzer, including canonical combining classes, are emitted
/// here so its behavior does not silently follow the compiler's `std.uni`.
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
    @(Option(`u|ucd-dir`, description: "Directory with the six documented UCD/emoji inputs. If omitted, they are downloaded from unicode.org for --unicode-version."))
    string ucdDir;

    @(Option(`o|out-file`, description: "Path to write the generated module (default: the in-tree unicode_tables.d)."))
    string outFile = defaultOutFile;

    @(Option(`V|unicode-version`, description: "Unicode version to generate for."))
    string unicodeVersion = pinnedUnicodeVersion;
}

int main(string[] args)
{
    auto parsed = parseCli!CliParams(
        args,
        HelpInfo(
            "gen_unicode_tables",
            "Generate sparkles.base.text.unicode_tables from the Unicode Character Database",
        ),
    );
    if (!parsed)
        return reportCliError(parsed.error);
    const cli = parsed.value;

    const ver = cli.unicodeVersion;
    const outFile = buildNormalizedPath(cli.outFile);

    styledWritelnErr(i"{dim unicode version}: {cyan $(ver)}");
    styledWritelnErr(i"{dim output file}:     {cyan $(outFile)}");
    if (cli.ucdDir.length)
        styledWritelnErr(i"{dim source}:          {dim local} {cyan $(cli.ucdDir)}");
    else
        styledWritelnErr(i"{dim source}:          {dim downloading from unicode.org}");

    // Without --ucd-dir, fetch every pinned input for `ver` into a temp dir
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
        fetchUcd(ver, "UnicodeData.txt", buildPath(tmpDir, "UnicodeData.txt"));
        fetchUcd(ver, "CaseFolding.txt", buildPath(tmpDir, "CaseFolding.txt"));
        fetchUcd(ver, "DerivedNormalizationProps.txt",
            buildPath(tmpDir, "DerivedNormalizationProps.txt"));
        fetchUcd(ver, "auxiliary/WordBreakProperty.txt",
            buildPath(tmpDir, "WordBreakProperty.txt"));
        ucdDir = tmpDir;
    }

    auto eaw = ucdDir.buildPath("EastAsianWidth.txt").readText;
    auto emojiVs = ucdDir.buildPath("emoji-variation-sequences.txt").readText;
    auto unicodeData = ucdDir.buildPath("UnicodeData.txt").readText;
    auto caseFolding = ucdDir.buildPath("CaseFolding.txt").readText;
    auto normalizationProps = ucdDir
        .buildPath("DerivedNormalizationProps.txt").readText;
    auto wordBreak = ucdDir.buildPath("WordBreakProperty.txt").readText;
    auto wide = parseEastAsianWidth(eaw, ["W", "F"]);
    auto ambiguous = parseEastAsianWidth(eaw, ["A"]);
    auto emojiVsBase = parseEmojiVsBases(emojiVs);
    auto analysis = buildAnalysisTables(
        unicodeData, caseFolding, normalizationProps, wordBreak);

    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(wide))} wide");
    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(ambiguous))} ambiguous");
    styledWritelnErr(i"ℹ️ {bold $(countCodePoints(emojiVsBase))} emoji-vs bases");
    styledWritelnErr(i"ℹ️ {bold $(analysis.canonical.length)} canonical mappings");
    styledWritelnErr(i"ℹ️ {bold $(analysis.compatibility.length)} compatibility mappings");
    styledWritelnErr(i"ℹ️ {bold $(analysis.fullFold.length)} full-fold mappings");

    write(outFile, [
        header(ver),
        wide.toSourceCode("isEastAsianWide"),
        ambiguous.toSourceCode("isEastAsianAmbiguous"),
        emojiVsBase.toSourceCode("isEmojiVsBase"),
        analysis.toSourceCode,
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

private struct UcdRecord
{
    string category;
    bool compatibility;
    uint[] decomposition;
}

private struct SequenceMapping
{
    uint codepoint;
    uint[] values;
}

private struct ScalarMapping
{
    uint codepoint;
    uint value;
}

private struct CompositionMapping
{
    uint first;
    uint second;
    uint value;
}

private struct WordBreakRange
{
    uint first;
    uint last;
    string property;
}

private struct AnalysisTables
{
    SequenceMapping[] canonical;
    SequenceMapping[] compatibility;
    SequenceMapping[] fullFold;
    ScalarMapping[] simpleFold;
    CompositionMapping[] compositions;
    WordBreakRange[] wordBreak;
    CodepointSet marks;
    CodepointSet uppercase;
    ScalarMapping[] canonicalClasses;

    string toSourceCode()
    {
        return [
            analysisTypesSource,
            marks.toSourceCode("isUnicodeMark"),
            uppercase.toSourceCode("isUnicodeUppercase"),
            scalarPropertyTableSource("canonicalCombiningClass",
                canonicalClasses),
            sequenceTableSource("canonicalDecomposition", canonical),
            sequenceTableSource("compatibilityDecomposition", compatibility),
            sequenceTableSource("fullCaseFold", fullFold),
            scalarTableSource("simpleCaseFold", simpleFold),
            compositionTableSource(compositions),
            wordBreakTableSource(wordBreak),
        ].join("\n");
    }
}

private AnalysisTables buildAnalysisTables(string unicodeData,
    string caseFolding, string normalizationProps, string wordBreak)
{
    AnalysisTables result;
    UcdRecord[uint] records;

    foreach (line; unicodeData.lineSplitter)
    {
        auto fields = line.splitter(';').array;
        if (fields.length < 15)
            continue;
        const cp = parseHex(fields[0]);
        const category = fields[2];
        const canonicalClass = fields[3].to!uint;
        if (canonicalClass != 0)
            result.canonicalClasses ~= ScalarMapping(cp, canonicalClass);
        if (category == "Mn" || category == "Mc" || category == "Me")
            result.marks.add(cp, cp + 1);
        if (category == "Lu" || category == "Lt")
            result.uppercase.add(cp, cp + 1);

        UcdRecord rec;
        rec.category = category;
        auto decomp = fields[5].strip;
        if (decomp.length)
        {
            auto pieces = decomp.splitter.array;
            size_t first;
            if (pieces[0].startsWith("<"))
            {
                rec.compatibility = true;
                first = 1;
            }
            foreach (piece; pieces[first .. $])
                rec.decomposition ~= parseHex(piece);
        }
        if (rec.decomposition.length)
            records[cp] = rec;
    }

    uint[][uint] canonicalMemo;
    uint[][uint] compatibilityMemo;
    foreach (cp, rec; records)
    {
        auto canonical = expandDecomposition(
            cp, false, records, canonicalMemo);
        if (canonical.length != 1 || canonical[0] != cp)
            result.canonical ~= SequenceMapping(cp, canonical);

        auto compatibility = expandDecomposition(
            cp, true, records, compatibilityMemo);
        if (compatibility.length != 1 || compatibility[0] != cp)
            result.compatibility ~= SequenceMapping(cp, compatibility);
    }
    result.canonical.sort!((a, b) => a.codepoint < b.codepoint);
    result.compatibility.sort!((a, b) => a.codepoint < b.codepoint);
    result.canonicalClasses.sort!((a, b) => a.codepoint < b.codepoint);

    auto exclusions = normalizationProps.ucdCodepoints!(
        value => value == "Full_Composition_Exclusion");
    foreach (cp, rec; records)
    {
        if (!rec.compatibility && rec.decomposition.length == 2
            && !(cp in exclusions))
        {
            result.compositions ~= CompositionMapping(
                rec.decomposition[0], rec.decomposition[1], cp);
        }
    }
    result.compositions.sort!((a, b) {
        return a.first != b.first ? a.first < b.first : a.second < b.second;
    });

    SequenceMapping[uint] simple;
    SequenceMapping[uint] full;
    foreach (rawLine; caseFolding.lineSplitter)
    {
        auto line = stripComment(rawLine);
        if (!line.length)
            continue;
        auto fields = line.splitter(';').map!strip.array;
        if (fields.length < 3)
            continue;
        const cp = parseHex(fields[0]);
        uint[] values;
        foreach (piece; fields[2].splitter)
            values ~= parseHex(piece);
        switch (fields[1])
        {
        case "C":
            simple[cp] = SequenceMapping(cp, values);
            full[cp] = SequenceMapping(cp, values);
            break;
        case "S":
            simple[cp] = SequenceMapping(cp, values);
            break;
        case "F":
            full[cp] = SequenceMapping(cp, values);
            break;
        default: // Turkic mappings are locale-specific and live in an adapter.
            break;
        }
    }
    foreach (cp, mapping; simple)
    {
        if (mapping.values.length == 1 && mapping.values[0] != cp)
            result.simpleFold ~= ScalarMapping(cp, mapping.values[0]);
    }
    foreach (cp, mapping; full)
    {
        if (mapping.values.length != 1 || mapping.values[0] != cp)
            result.fullFold ~= mapping;
    }
    result.simpleFold.sort!((a, b) => a.codepoint < b.codepoint);
    result.fullFold.sort!((a, b) => a.codepoint < b.codepoint);

    foreach (rawLine; wordBreak.lineSplitter)
    {
        auto line = stripComment(rawLine);
        if (!line.length)
            continue;
        auto fields = line.splitter(';').map!strip.array;
        if (fields.length < 2)
            continue;
        auto bounds = fields[0].splitter("..").array;
        const first = parseHex(bounds[0]);
        const last = bounds.length == 2 ? parseHex(bounds[1]) : first;
        result.wordBreak ~= WordBreakRange(first, last, fields[1]);
    }
    result.wordBreak.sort!((a, b) => a.first < b.first);
    return result;
}

private uint[] expandDecomposition(uint cp, bool compatibility,
    ref UcdRecord[uint] records, ref uint[][uint] memo)
{
    if (auto cached = cp in memo)
        return *cached;
    auto record = cp in records;
    if (record is null || !record.decomposition.length
        || (!compatibility && record.compatibility))
    {
        auto identity = [cp];
        memo[cp] = identity;
        return identity;
    }
    uint[] expanded;
    foreach (part; record.decomposition)
        expanded ~= expandDecomposition(part, compatibility, records, memo);
    memo[cp] = expanded;
    return expanded;
}

private uint parseHex(string text)
{
    uint value;
    text.formattedRead!"%x"(value);
    return value;
}

private enum analysisTypesSource = q{
/// A borrowed span inside one of the generated flat Unicode mapping arrays.
struct UnicodeMappingSpan
{
    uint offset;
    ubyte length;
}

private struct UnicodeSequenceIndex
{
    uint codepoint;
    uint offset;
    ubyte length;
}

private struct UnicodeScalarIndex
{
    uint codepoint;
    uint value;
}

private UnicodeMappingSpan findUnicodeSequence(scope const(UnicodeSequenceIndex)[] index,
    dchar ch) @safe pure nothrow @nogc
{
    size_t lo;
    size_t hi = index.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < ch)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < index.length && index[lo].codepoint == ch
        ? UnicodeMappingSpan(index[lo].offset, index[lo].length)
        : UnicodeMappingSpan.init;
}

private dchar findUnicodeScalar(scope const(UnicodeScalarIndex)[] index,
    dchar ch) @safe pure nothrow @nogc
{
    size_t lo;
    size_t hi = index.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < ch)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < index.length && index[lo].codepoint == ch
        ? cast(dchar) index[lo].value : ch;
}

private uint findUnicodeProperty(scope const(UnicodeScalarIndex)[] index,
    dchar ch) @safe pure nothrow @nogc
{
    size_t lo;
    size_t hi = index.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < ch)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < index.length && index[lo].codepoint == ch
        ? index[lo].value : 0;
}
};

private string sequenceTableSource(string name,
    const(SequenceMapping)[] mappings)
{
    auto data = appender!string;
    auto index = appender!string;
    uint offset;
    data.put("private immutable uint[] " ~ name ~ "Data = [\n    ");
    index.put("private immutable UnicodeSequenceIndex[] " ~ name
        ~ "Index = [\n");
    size_t column;
    foreach (mapping; mappings)
    {
        index.put(format("    UnicodeSequenceIndex(0x%X, %s, %s),\n",
            mapping.codepoint, offset, mapping.values.length));
        foreach (value; mapping.values)
        {
            if (column != 0)
                data.put(column % 10 == 0 ? "\n    " : " ");
            data.put(format("0x%X,", value));
            ++column;
        }
        offset += mapping.values.length.to!uint;
    }
    data.put("\n];\n");
    index.put("];\n");
    return data.data ~ index.data ~ format(q{
UnicodeMappingSpan %1$s(dchar ch) @safe pure nothrow @nogc
{
    return findUnicodeSequence(%1$sIndex, ch);
}

dchar %1$sValue(size_t offset) @safe pure nothrow @nogc
{
    return cast(dchar) %1$sData[offset];
}
}, name);
}

private string scalarTableSource(string name, const(ScalarMapping)[] mappings)
{
    auto source = appender!string;
    source.put("private immutable UnicodeScalarIndex[] " ~ name ~ "Index = [\n");
    foreach (mapping; mappings)
        source.put(format("    UnicodeScalarIndex(0x%X, 0x%X),\n",
            mapping.codepoint, mapping.value));
    source.put("];\n");
    source.put(format(q{
dchar %1$s(dchar ch) @safe pure nothrow @nogc
{
    return findUnicodeScalar(%1$sIndex, ch);
}
}, name));
    return source.data;
}

private string scalarPropertyTableSource(string name,
    const(ScalarMapping)[] mappings)
{
    auto source = appender!string;
    source.put("private immutable UnicodeScalarIndex[] " ~ name
        ~ "Index = [\n");
    foreach (mapping; mappings)
        source.put(format("    UnicodeScalarIndex(0x%X, 0x%X),\n",
            mapping.codepoint, mapping.value));
    source.put("];\n");
    source.put(format(q{
ubyte %1$s(dchar ch) @safe pure nothrow @nogc
{
    return cast(ubyte) findUnicodeProperty(%1$sIndex, ch);
}
}, name));
    return source.data;
}

private string compositionTableSource(const(CompositionMapping)[] mappings)
{
    auto source = appender!string;
    source.put(q{
private struct UnicodeComposition
{
    ulong key;
    uint value;
}

private immutable UnicodeComposition[] unicodeCompositions = [
});
    foreach (mapping; mappings)
    {
        const key = (cast(ulong) mapping.first << 21) | mapping.second;
        source.put(format("    UnicodeComposition(0x%X, 0x%X),\n",
            key, mapping.value));
    }
    source.put(q{];

dchar canonicalComposition(dchar first, dchar second)
    @safe pure nothrow @nogc
{
    const key = (cast(ulong) first << 21) | cast(uint) second;
    size_t lo;
    size_t hi = unicodeCompositions.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (unicodeCompositions[mid].key < key)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < unicodeCompositions.length && unicodeCompositions[lo].key == key
        ? cast(dchar) unicodeCompositions[lo].value : dchar.init;
}
});
    return source.data;
}

private string wordBreakMember(string property)
{
    switch (property)
    {
    case "CR": return "cr";
    case "LF": return "lf";
    case "Newline": return "newline";
    case "Extend": return "extend";
    case "ZWJ": return "zwj";
    case "Regional_Indicator": return "regionalIndicator";
    case "Format": return "format";
    case "Katakana": return "katakana";
    case "Hebrew_Letter": return "hebrewLetter";
    case "ALetter": return "aLetter";
    case "Single_Quote": return "singleQuote";
    case "Double_Quote": return "doubleQuote";
    case "MidNumLet": return "midNumLet";
    case "MidLetter": return "midLetter";
    case "MidNum": return "midNum";
    case "Numeric": return "numeric";
    case "ExtendNumLet": return "extendNumLet";
    case "WSegSpace": return "wSegSpace";
    default: return "other";
    }
}

private string wordBreakTableSource(const(WordBreakRange)[] ranges)
{
    auto source = appender!string;
    source.put(q{
enum WordBreakClass : ubyte
{
    other, cr, lf, newline, extend, zwj, regionalIndicator, format,
    katakana, hebrewLetter, aLetter, singleQuote, doubleQuote,
    midNumLet, midLetter, midNum, numeric, extendNumLet, wSegSpace,
}

private struct WordBreakRange
{
    uint first;
    uint last;
    WordBreakClass kind;
}

private immutable WordBreakRange[] wordBreakRanges = [
});
    foreach (range; ranges)
        source.put(format("    WordBreakRange(0x%X, 0x%X, WordBreakClass.%s),\n",
            range.first, range.last, wordBreakMember(range.property)));
    source.put(q{];

WordBreakClass wordBreakClass(dchar ch) @safe pure nothrow @nogc
{
    size_t lo;
    size_t hi = wordBreakRanges.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (wordBreakRanges[mid].last < ch)
            lo = mid + 1;
        else
            hi = mid;
    }
    return lo < wordBreakRanges.length
        && wordBreakRanges[lo].first <= ch
        ? wordBreakRanges[lo].kind : WordBreakClass.other;
}
});
    return source.data;
}

private string header(string ver)
{
    return format(`
        // Generated by libs/base/tools/gen_unicode_tables.d — DO NOT EDIT.
        //
        // Unicode %s width, emoji, normalization, folding, combining-class,
        // and word-break properties used by sparkles' text primitives.
        // Regenerate by running ./libs/base/tools/gen_unicode_tables.d.
        module sparkles.base.text.unicode_tables;
    `.outdent[1 .. $], ver);
}
