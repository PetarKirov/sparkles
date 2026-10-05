#!/usr/bin/env dub
/+ dub.sdl:
    name "gen_unicode_tables"
    libs "curl"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/** Manifest-driven Unicode generation. Missing inventories are acquired and
 * authenticated before generation; --no-network requires existing local bytes.
 * Generated queries own property semantics, including unassigned-scalar defaults.
 *
 * Acquire: dub run --single libs/base/tools/gen_unicode_tables.d -- --acquire
 * Generate: dub run --single libs/base/tools/gen_unicode_tables.d --
 *   --manifest libs/base/tools/unicode/manifest.json
 *   --ucd-dir libs/base/tools/unicode/18.0.0 --out-file /tmp/unicode_tables.d
 */
module sparkles.base.tools.gen_unicode_tables;

import std.algorithm : sort;
import std.array : appender;
import std.conv : to;
import std.digest.sha : sha256Of;
import std.file : read, readText, write, mkdirRecurse, rename, exists, remove;
import std.format : format, formattedWrite;
import std.json : parseJSON, JSONValue;
import std.net.curl : download, HTTP, CurlOption;
import std.path : buildPath, dirName;
import std.stdio : writeln, stderr;

// Tool-side parsing/emission allocates and performs explicit filesystem/network
// operations. Pure owned-byte primitives and emitted runtime queries tighten
// their attributes independently.
@system:

private enum generatorRevision = 1;
private enum schemaRevision = 1;
private enum reviewedManifestIdentity = "df3659783f974cb439f4f6436dc4e72f0d06313a45b865c04921dba1d938abcc";
private enum domain = 0x110000;
private enum defaultManifest = "libs/base/tools/unicode/manifest.json";
private enum defaultInputs = "libs/base/tools/unicode/18.0.0";
private enum defaultOutput = "libs/base/src/sparkles/base/text/unicode_tables.d";

private void require(bool condition, string message)
{
    if (!condition) throw new Exception(message);
}

// Deliberately byte-based ASCII field parsing: no Unicode decoding or compiler
// character properties are involved, even indirectly through whitespace ranges.
private bool white(char c) @safe pure nothrow @nogc
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}
private string trim(string s) @safe pure nothrow @nogc
{
    size_t a, b = s.length;
    while (a < b && white(s[a])) ++a;
    while (b > a && white(s[b - 1])) --b;
    return s[a .. b];
}
private string[] split(string s, char delimiter)
{
    string[] result;
    size_t start;
    foreach (size_t i; 0 .. s.length)
        if (s[i] == delimiter) { result ~= trim(s[start .. i]); start = i + 1; }
    result ~= trim(s[start .. $]);
    return result;
}
private string[] lines(string s) { return split(s, '\n'); }
private string[] words(string s)
{
    string[] result;
    size_t i;
    while (i < s.length)
    {
        while (i < s.length && white(s[i])) ++i;
        const start = i;
        while (i < s.length && !white(s[i])) ++i;
        if (i > start) result ~= s[start .. i];
    }
    return result;
}
private bool starts(string s, string prefix) @safe pure nothrow @nogc
{
    return s.length >= prefix.length && s[0 .. prefix.length] == prefix;
}
private string stripComment(string s)
{
    foreach (size_t i; 0 .. s.length) if (s[i] == '#') return trim(s[0 .. i]);
    return trim(s);
}
private uint number(string text, uint radix = 16)
{
    require(text.length != 0, "empty number");
    uint n;
    foreach (char c; text)
    {
        uint d = c >= '0' && c <= '9' ? c - '0' :
            c >= 'A' && c <= 'F' ? c - 'A' + 10 :
            c >= 'a' && c <= 'f' ? c - 'a' + 10 : uint.max;
        require(d < radix && n <= (uint.max - d) / radix, "invalid number: " ~ text);
        n = n * radix + d;
    }
    return n;
}
private uint parseHex(string s) { return number(s); }
private struct Bounds { uint first, last; }
private Bounds bounds(string s)
{
    auto pieces = split(s, '.');
    require(pieces.length == 1 || (pieces.length == 3 && pieces[1].length == 0), "invalid range: " ~ s);
    const a = number(pieces[0]);
    const b = pieces.length == 1 ? a : number(pieces[2]);
    require(a <= b && b < domain, "range outside Unicode domain: " ~ s);
    return Bounds(a, b);
}
private uint[] sequence(string s)
{
    uint[] result;
    foreach (part; words(s))
    {
        const cp = number(part);
        require(cp < domain && (cp < 0xD800 || cp > 0xDFFF), "mapping contains non-scalar");
        result ~= cp;
    }
    return result;
}
private string digest(scope const(ubyte)[] bytes)
{
    auto hash = sha256Of(bytes);
    auto writer = appender!string;
    foreach (b; hash) writer.formattedWrite("%02x", b);
    return writer.data;
}
private string key(string s)
{
    auto writer = appender!string;
    foreach (char c; s)
    {
        if (c == '_' || c == '-' || white(c)) continue;
        require(c < 128, "non-ASCII property identifier");
        writer.put(c >= 'A' && c <= 'Z' ? cast(char)(c + 32) : c);
    }
    return writer.data;
}
private string identifier(string s)
{
    require(s.length != 0, "empty identifier");
    auto writer = appender!string;
    foreach (char c; s)
    {
        require(c < 128 && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-' || white(c)), "bad identifier: " ~ s);
        writer.put(c == '-' || white(c) ? '_' : c);
    }
    auto result = writer.data;
    if (result[0] >= '0' && result[0] <= '9') result = "v" ~ result;
    if (result == "None") result = "none";
    return result;
}

private struct Artifact { string path, url, sha256, role; }
private struct Manifest
{
    string identity, release;
    uint schema;
    Artifact[] artifacts;
}
private Manifest loadManifest(string path)
{
    auto bytes = cast(ubyte[]) read(path);
    auto json = parseJSON(cast(string) bytes);
    Manifest m;
    m.identity = digest(bytes);
    require(m.identity == reviewedManifestIdentity, "manifest identity is not reviewed by this generator revision");
    m.release = json["release"].str;
    m.schema = cast(uint) json["schemaRevision"].integer;
    require(m.release == "18.0.0" && m.schema == schemaRevision &&
        json["generatorRevision"].integer == generatorRevision, "unsupported release/generator/schema");
    auto a = json["algorithms"];
    require(a["core"].str == m.release && a["bidi"].integer == 52 &&
        a["width"].integer == 46 && a["line"].integer == 57 &&
        a["normalization"].integer == 58 && a["segmentation"].integer == 49 &&
        a["properties"].integer == 38 && a["emoji"].integer == 31, "unreviewed algorithm revision");
    bool[string] seen;
    foreach (entry; json["artifacts"].array)
    {
        Artifact art = Artifact(entry["path"].str, entry["url"].str,
            entry["sha256"].str, entry["role"].str);
        require(art.path.length != 0 && art.path[0] != '/' &&
            !contains(art.path, "..") && !contains(art.path, "\\") &&
            (art.path !in seen), "unsafe/duplicate artifact path");
        require(art.sha256.length == 64, "invalid SHA-256 length");
        foreach (char c; art.sha256) require((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'), "invalid SHA-256");
        require(starts(art.url, "https://www.unicode.org/Public/18.0.0/") ||
            (art.path == "LICENSE.txt" && art.url == "https://www.unicode.org/license.txt"), "unversioned artifact URL");
        require(art.role == "source" || art.role == "test" || art.role == "license", "unknown artifact role");
        seen[art.path] = true;
        m.artifacts ~= art;
    }
    foreach (p; requiredArtifacts) require((p in seen) !is null, "missing manifest artifact: " ~ p);
    require(m.artifacts.length == requiredArtifacts.length, "unexpected manifest inventory");
    return m;
}
private bool contains(string s, string part) @safe pure nothrow @nogc
{
    if (part.length > s.length) return false;
    foreach (size_t i; 0 .. s.length - part.length + 1)
        if (s[i .. i + part.length] == part) return true;
    return false;
}
private enum string[] requiredArtifacts = [
    "ucd/UnicodeData.txt", "ucd/DerivedCoreProperties.txt", "ucd/PropList.txt",
    "ucd/PropertyAliases.txt", "ucd/PropertyValueAliases.txt",
    "ucd/auxiliary/GraphemeBreakProperty.txt", "ucd/auxiliary/WordBreakProperty.txt",
    "ucd/auxiliary/SentenceBreakProperty.txt", "ucd/LineBreak.txt", "ucd/EastAsianWidth.txt",
    "ucd/DerivedNormalizationProps.txt", "ucd/CompositionExclusions.txt", "ucd/CaseFolding.txt",
    "ucd/SpecialCasing.txt", "ucd/Scripts.txt", "ucd/ScriptExtensions.txt", "ucd/ArabicShaping.txt",
    "ucd/BidiBrackets.txt", "ucd/BidiMirroring.txt", "ucd/extracted/DerivedBidiClass.txt",
    "ucd/extracted/DerivedGeneralCategory.txt", "ucd/emoji/emoji-data.txt",
    "ucd/emoji/emoji-variation-sequences.txt", "ucd/auxiliary/GraphemeBreakTest.txt",
    "ucd/auxiliary/WordBreakTest.txt", "ucd/auxiliary/SentenceBreakTest.txt",
    "ucd/auxiliary/LineBreakTest.txt", "ucd/NormalizationTest.txt", "ucd/BidiTest.txt",
    "ucd/BidiCharacterTest.txt", "ucd/ReadMe.txt", "emoji/emoji-sequences.txt",
    "emoji/emoji-zwj-sequences.txt", "emoji/emoji-test.txt", "LICENSE.txt",
];
private string checkedText(Artifact artifact, const(ubyte)[] bytes)
{
    require(digest(bytes) == artifact.sha256, "SHA-256 mismatch: " ~ artifact.path);
    return cast(string) bytes;
}
private string[string] authenticate(Manifest m, string root)
{
    string[string] sources;
    foreach (art; m.artifacts)
    {
        auto bytes = cast(ubyte[]) read(buildPath(root, art.path));
        const text = checkedText(art, bytes);
        if (art.path != "ucd/UnicodeData.txt" && art.path != "LICENSE.txt")
            require(contains(text[0 .. (text.length < 4096 ? text.length : 4096)],
                starts(art.path, "emoji/") || starts(art.path, "ucd/emoji/") ? "18.0" : m.release),
                "release header mismatch: " ~ art.path);
        sources[art.path] = text;
    }
    auto license = sources["LICENSE.txt"];
    require(contains(license, "UNICODE LICENSE V3") && contains(license, "COPYRIGHT AND PERMISSION NOTICE") &&
        contains(license, "Permission is hereby granted"), "missing redistribution notice");
    return sources;
}
private void acquire(Manifest m, string root) @system
{
    // The entire inventory is staged, authenticated, then installed as one directory.
    require(!exists(root), "acquisition destination must not exist");
    const stage = root ~ ".acquiring";
    require(!exists(stage), "acquisition staging directory already exists");
    mkdirRecurse(stage);
    foreach (art; m.artifacts)
    {
        const path = buildPath(stage, art.path);
        mkdirRecurse(dirName(path));
        auto http = HTTP();
        http.handle.set(CurlOption.failonerror, 1L);
        download(art.url, path, http);
    }
    authenticate(m, stage);
    rename(stage, root);
}

private struct Property
{
    string name, enumName, functionName;
    string[] values, members;
    uint[] data;
    bool[] explicitValue;
    uint defaultValue;
    bool binary;
}
private class Tables
{
    Property[] properties;
    size_t[string] indexes;
    string[string] propertyAliases;
    string[string] valueAliases;
    SequenceMapping[][string] sequences;
    ScalarMapping[][string] scalars;
    CompositionMapping[] compositions;
    CaseRule[] caseRules;
    EmojiRecord[] emoji;
    string[] emojiKinds;
    string unicodeData;

    void aliases(string propertyText, string valueText)
    {
        foreach (line; lines(propertyText))
        {
            auto text = stripComment(line); if (!text.length) continue;
            auto f = split(text, ';'); require(f.length >= 2, "malformed property alias");
            foreach (v; f) propertyAliases[key(v)] = f[0];
        }
        foreach (line; lines(valueText))
        {
            auto text = stripComment(line); if (!text.length) continue;
            auto f = split(text, ';'); require(f.length >= 3, "malformed value alias");
            auto p = canonicalProperty(f[0]);
            foreach (v; f[1 .. $]) valueAliases[p ~ ":" ~ key(v)] = f[1];
        }
    }
    string canonicalProperty(string p)
    {
        auto v = key(p) in propertyAliases;
        require(v !is null, "unknown required property: " ~ p);
        return *v;
    }
    string canonicalValue(string p, string v)
    {
        auto a = p ~ ":" ~ key(v) in valueAliases;
        require(a !is null, "unknown required value: " ~ p ~ ";" ~ v);
        return *a;
    }
    size_t add(string p, string fallback, string enumName = "", string functionName = "",
        string[] fixedValues = null, string[] fixedMembers = null, bool binary = false)
    {
        p = canonicalProperty(p);
        if (auto found = p in indexes) return *found;
        Property prop;
        prop.name = p; prop.enumName = enumName; prop.functionName = functionName; prop.binary = binary;
        if (binary) { prop.values = ["N", "Y"]; prop.members = ["no", "yes"]; }
        else if (fixedValues.length)
        {
            foreach (v; fixedValues) prop.values ~= canonicalValue(p, v);
            prop.members = fixedMembers;
        }
        else
        {
            string[] values;
            foreach (aliasKey, value; valueAliases)
                if (starts(aliasKey, p ~ ":")) values ~= value;
            sort(values);
            foreach (v; values) if (!prop.values.length || prop.values[$ - 1] != v) prop.values ~= v;
            foreach (v; prop.values) prop.members ~= identifier(v);
        }
        require(prop.values.length != 0 && prop.values.length == prop.members.length, "empty property values");
        prop.defaultValue = valueIndex(prop, canonicalValue(p, fallback));
        prop.data = new uint[domain]; prop.data[] = prop.defaultValue;
        prop.explicitValue = new bool[domain];
        const i = properties.length;
        properties ~= prop; indexes[p] = i;
        return i;
    }
    uint valueIndex(ref Property p, string value)
    {
        foreach (i, v; p.values) if (v == value) return cast(uint) i;
        throw new Exception("unrecognized property value: " ~ p.name ~ ";" ~ value);
    }
    void assign(size_t i, Bounds r, uint value, bool missing)
    {
        auto p = &properties[i];
        foreach (uint cp; r.first .. r.last + 1)
        {
            if (missing) { if (!p.explicitValue[cp]) p.data[cp] = value; }
            else
            {
                require(!p.explicitValue[cp] || p.data[cp] == value,
                    format("conflicting %s range at U+%X", p.name, cp));
                p.data[cp] = value; p.explicitValue[cp] = true;
            }
        }
    }
    void assignValue(size_t i, Bounds r, string value, bool missing = false)
    {
        auto p = &properties[i];
        assign(i, r, valueIndex(*p, canonicalValue(p.name, value)), missing);
    }
    void propertyFile(string text, string fixedProperty = "")
    {
        // Defaults are layered broad-to-specific before explicit ranges; later
        // @missing declarations override earlier defaults, never explicit values.
        foreach (missing; [true, false]) foreach (raw; lines(text))
        {
            auto line = trim(raw);
            if (missing)
            {
                if (!starts(line, "# @missing:")) continue;
                line = trim(line[11 .. $]);
            }
            else { line = stripComment(line); if (!line.length) continue; }
            auto f = split(line, ';');
            require(f.length >= 2 && f.length <= 3, "malformed property row: " ~ line);
            auto p = canonicalProperty(fixedProperty.length ? fixedProperty : f[1]);
            const value = fixedProperty.length ? f[1] : f.length == 3 ? f[2] : "Y";
            size_t i;
            if (auto found = p in indexes) i = *found;
            else i = add(p, "N", "", "", null, null, true);
            assignValue(i, bounds(f[0]), value, missing);
        }
    }
}
private struct SequenceMapping { uint codepoint; uint[] values; }
private struct ScalarMapping { uint codepoint, value; }
private struct CompositionMapping { uint first, second, value; }
private struct CaseRule { uint codepoint; uint[] lower, title, upper; string condition; }
private struct EmojiRecord { uint[] values; string kind; }

int main(string[] args) @system
{
    try
    {
        string manifestPath = defaultManifest, root = defaultInputs, output = defaultOutput;
        bool acquisition, noNetwork;
        for (size_t i = 1; i < args.length; ++i)
        {
            auto arg = args[i];
            if (arg == "--acquire") acquisition = true;
            else if (arg == "--no-network") noNetwork = true;
            else if (arg == "--manifest" || arg == "--ucd-dir" || arg == "--out-file")
            {
                require(i + 1 < args.length, "missing option argument");
                auto value = args[++i];
                if (arg == "--manifest") manifestPath = value;
                else if (arg == "--ucd-dir") root = value;
                else output = value;
            }
            else throw new Exception("unknown argument: " ~ arg);
        }
        require(!(acquisition && noNetwork), "--acquire contradicts --no-network");
        auto manifest = loadManifest(manifestPath);
        if (acquisition) { acquire(manifest, root); return 0; }
        if (!exists(root))
        {
            require(!noNetwork, "Unicode inventory is missing and --no-network forbids acquisition: " ~ root);
            acquire(manifest, root);
        }
        auto sources = authenticate(manifest, root);
        auto tables = buildTables(sources);
        auto emitted = emit(tables, manifest, sources["LICENSE.txt"]);
        // All hashes, parsing, constraints, scalar-domain accelerator checks and
        // emission complete before the sole output is atomically replaced.
        mkdirRecurse(dirName(output));
        const stage = output ~ ".staging";
        require(!exists(stage), "output staging file already exists");
        scope(exit) if (exists(stage)) remove(stage);
        write(stage, emitted);
        require(readText(stage) == emitted, "staged output verification failed");
        rename(stage, output);
        writeln("Unicode ", manifest.release, " manifest ", manifest.identity, " -> ", output);
        return 0;
    }
    catch (Exception e) { stderr.writeln(e.msg); return 1; }
}

private Tables buildTables(string[string] sources)
{
    auto t = new Tables;
    t.aliases(sources["ucd/PropertyAliases.txt"], sources["ucd/PropertyValueAliases.txt"]);
    t.unicodeData = sources["ucd/UnicodeData.txt"];
    t.add("GCB", "Other", "GraphemeBreakClass", "graphemeBreakClass",
        ["Other","CR","LF","Control","Extend","ZWJ","Regional_Indicator","Prepend","SpacingMark","L","V","T","LV","LVT"],
        ["other","cr","lf","control","extend","zwj","regionalIndicator","prepend","spacingMark","l","v","t","lv","lvt"]);
    t.add("InCB", "None", "IndicConjunctBreakClass", "indicConjunctBreakClass",
        ["None","Consonant","Extend","Linker"], ["none","consonant","extend","linker"]);
    t.add("WB", "Other", "WordBreakClass", "wordBreakClass",
        ["Other","CR","LF","Newline","Extend","ZWJ","Regional_Indicator","Format","Katakana","Hebrew_Letter","ALetter",
            "Single_Quote","Double_Quote","MidNumLet","MidLetter","MidNum","Numeric","ExtendNumLet","WSegSpace"],
        ["other","cr","lf","newline","extend","zwj","regionalIndicator","format","katakana","hebrewLetter","aLetter",
            "singleQuote","doubleQuote","midNumLet","midLetter","midNum","numeric","extendNumLet","wSegSpace"]);
    t.add("gc", "Cn", "GeneralCategory", "generalCategory");
    t.add("SB", "Other", "SentenceBreakClass", "sentenceBreakClass");
    t.add("lb", "XX", "LineBreakClass", "lineBreakClass");
    t.add("ea", "N", "EastAsianWidthClass", "eastAsianWidthClass");
    t.add("bc", "L", "BidiClass", "bidiClass");
    t.add("sc", "Zzzz", "Script", "script");
    t.add("jt", "U", "JoiningType", "joiningType");
    t.add("jg", "No_Joining_Group", "JoiningGroup", "joiningGroup");
    foreach (name; ["NFD_QC","NFC_QC","NFKD_QC","NFKC_QC"]) t.add(name, "Y");
    foreach (pair; [
        ["ucd/auxiliary/GraphemeBreakProperty.txt","GCB"],
        ["ucd/auxiliary/WordBreakProperty.txt","WB"],
        ["ucd/auxiliary/SentenceBreakProperty.txt","SB"],
        ["ucd/LineBreak.txt","lb"], ["ucd/EastAsianWidth.txt","ea"],
        ["ucd/extracted/DerivedBidiClass.txt","bc"],
        ["ucd/extracted/DerivedGeneralCategory.txt","gc"], ["ucd/Scripts.txt","sc"]])
        t.propertyFile(sources[pair[0]], pair[1]);
    foreach (name; ["ucd/DerivedCoreProperties.txt","ucd/PropList.txt","ucd/emoji/emoji-data.txt"])
        t.propertyFile(sources[name]);
    readUnicodeData(t);
    readNormalization(t, sources["ucd/DerivedNormalizationProps.txt"], sources["ucd/CompositionExclusions.txt"]);
    readCaseFolding(t, sources["ucd/CaseFolding.txt"]);
    readSpecialCasing(t, sources["ucd/SpecialCasing.txt"]);
    readJoining(t, sources["ucd/ArabicShaping.txt"]);
    readScriptExtensions(t, sources["ucd/ScriptExtensions.txt"]);
    readBidi(t, sources["ucd/BidiBrackets.txt"], sources["ucd/BidiMirroring.txt"]);
    foreach (name; ["emoji/emoji-sequences.txt","emoji/emoji-zwj-sequences.txt",
        "emoji/emoji-test.txt","ucd/emoji/emoji-variation-sequences.txt"])
        readEmoji(t, sources[name], name);
    // The inventory must contain these algorithm-critical binary families.
    foreach (p; ["Extended_Pictographic","Cased","Case_Ignorable","Soft_Dotted",
        "Default_Ignorable_Code_Point","Full_Composition_Exclusion","Emoji_Presentation"])
        require((t.canonicalProperty(p) in t.indexes) !is null, "missing required property family: " ~ p);
    foreach (ref mappings; t.sequences)
    {
        sort!((a,b) => a.codepoint < b.codepoint)(mappings);
        foreach (i; 1 .. mappings.length) require(mappings[i - 1].codepoint < mappings[i].codepoint, "duplicate sequence mapping");
        foreach (m; mappings) require(m.values.length <= ushort.max, "mapping length overflow");
    }
    foreach (ref mappings; t.scalars)
    {
        sort!((a,b) => a.codepoint < b.codepoint)(mappings);
        foreach (i; 1 .. mappings.length) require(mappings[i - 1].codepoint < mappings[i].codepoint, "duplicate scalar mapping");
    }
    sort!((a,b) => a.first == b.first ? a.second < b.second : a.first < b.first)(t.compositions);
    foreach (i; 1 .. t.compositions.length)
        require(t.compositions[i-1].first != t.compositions[i].first ||
            t.compositions[i-1].second != t.compositions[i].second, "duplicate canonical composition");
    return t;
}

private struct UcdRecord { bool compatibility; uint[] decomposition; }
private UcdRecord[uint] records;

private void readUnicodeData(Tables t)
{
    records = null;
    uint previous;
    bool firstRow = true, pending;
    uint rangeStart;
    string[] firstFields;
    auto gc = t.indexes["gc"];
    foreach (raw; lines(t.unicodeData))
    {
        if (!raw.length) continue;
        auto f = split(raw, ';'); require(f.length == 15, "UnicodeData requires 15 fields");
        const cp = number(f[0]); require(cp < domain && (firstRow || cp > previous), "UnicodeData order/duplicate");
        firstRow = false; previous = cp;
        const isFirst = contains(f[1], ", First>");
        const isLast = contains(f[1], ", Last>");
        if (isFirst)
        {
            require(!pending, "nested UnicodeData First");
            pending = true; rangeStart = cp; firstFields = f;
            continue;
        }
        Bounds r = Bounds(cp, cp);
        if (isLast)
        {
            require(pending && cp > rangeStart &&
                f[1][0 .. f[1].length - 7] == firstFields[1][0 .. firstFields[1].length - 8],
                "unmatched UnicodeData Last");
            foreach (i; 2 .. 15) require(f[i] == firstFields[i], "First/Last property mismatch");
            r.first = rangeStart; pending = false;
        }
        else require(!pending, "UnicodeData missing Last");
        const category = t.valueIndex(t.properties[gc], t.canonicalValue("gc", f[2]));
        foreach (uint c; r.first .. r.last + 1)
            require(t.properties[gc].data[c] == category, "UnicodeData/category source disagreement");
        const ccc = number(f[3], 10); require(ccc <= 255, "combining class overflow");
        foreach (uint c; r.first .. r.last + 1)
            if (ccc) t.scalars["canonicalCombiningClass"] ~= ScalarMapping(c, ccc);
        if (f[5].length)
        {
            require(r.first == r.last, "decomposition on First/Last range");
            auto decomp = f[5];
            bool compatibility;
            if (decomp[0] == '<')
            {
                size_t end;
                while (end < decomp.length && decomp[end] != '>') ++end;
                require(end < decomp.length, "malformed decomposition tag");
                t.canonicalValue(t.canonicalProperty("dt"), decomp[1 .. end]);
                compatibility = true;
                decomp = trim(decomp[end+1 .. $]);
            }
            auto seq = sequence(decomp); require(seq.length != 0, "empty decomposition");
            records[cp] = UcdRecord(compatibility, seq);
        }
        foreach (pair; [[12,0], [13,1], [14,2]])
            if (f[pair[0]].length)
            {
                auto mapped = sequence(f[pair[0]]); require(mapped.length == 1 && r.first == r.last, "invalid simple casing");
                const name = ["simpleUppercase","simpleLowercase","simpleTitlecase"][pair[1]];
                t.scalars[name] ~= ScalarMapping(cp, mapped[0]);
                t.sequences[["fullUppercase","fullLowercase","fullTitlecase"][pair[1]]] ~= SequenceMapping(cp, mapped);
            }
        if (f[9] == "Y")
        {
            auto i = t.add("Bidi_Mirrored", "N", "", "", null, null, true);
            t.assignValue(i, r, "Y");
        }
        else require(f[9] == "N", "invalid bidi mirrored field");
    }
    require(!pending, "unterminated UnicodeData First");
}

private uint[] hangulDecomposition(uint cp)
{
    const s = cp - 0xAC00;
    uint[] values = [0x1100 + s / 588, 0x1161 + (s % 588) / 28];
    if (s % 28) values ~= 0x11A7 + s % 28;
    return values;
}
private uint[] expand(uint cp, bool compatibility, ref uint[][uint] memo, ref bool[uint] active)
{
    if (auto found = cp in memo) return *found;
    require(!(cp in active), "cyclic decomposition");
    active[cp] = true;
    scope(exit) active.remove(cp);
    uint[] result;
    if (cp >= 0xAC00 && cp <= 0xD7A3) result = hangulDecomposition(cp);
    else if (auto r = cp in records)
    {
        if (r.compatibility && !compatibility) result = [cp];
        else foreach (part; r.decomposition) result ~= expand(part, compatibility, memo, active);
    }
    else result = [cp];
    memo[cp] = result;
    return result;
}
private void readNormalization(Tables t, string text, string exclusions)
{
    auto fullExcluded = t.add("Full_Composition_Exclusion", "N", "", "", null, null, true);
    foreach (raw; lines(text))
    {
        auto line = trim(raw); bool missing = starts(line, "# @missing:");
        if (missing) line = trim(line[11 .. $]); else line = stripComment(line);
        if (!line.length) continue;
        auto f = split(line, ';'); require(f.length >= 2 && f.length <= 3, "malformed normalization row");
        auto p = t.canonicalProperty(f[1]); auto r = bounds(f[0]);
        if (p == t.canonicalProperty("NFKC_CF") || p == t.canonicalProperty("NFKC_SCF") || p == t.canonicalProperty("FC_NFKC"))
        {
            require(f.length == 3, "normalization mapping without value");
            if (missing) { require(f[2] == "<code point>", "unknown mapping default"); continue; }
            auto values = sequence(f[2]);
            auto name = p == t.canonicalProperty("NFKC_CF") ? "nfkcCaseFold" :
                p == t.canonicalProperty("NFKC_SCF") ? "nfkcSimpleCaseFold" : "fcNfkcClosure";
            foreach (uint cp; r.first .. r.last + 1) t.sequences[name] ~= SequenceMapping(cp, values);
        }
        else
        {
            size_t i;
            if (auto found = p in t.indexes) i = *found;
            else i = t.add(p, "N", "", "", null, null, true);
            t.assignValue(i, r, f.length == 3 ? f[2] : "Y", missing);
        }
    }
    foreach (raw; lines(exclusions))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        const r = bounds(line);
        foreach (uint cp; r.first .. r.last + 1)
            require(t.properties[fullExcluded].data[cp] == 1, "composition exclusion disagreement");
    }
    uint[][uint] canonicalMemo, compatibilityMemo;
    bool[uint] active;
    uint[] points;
    foreach (cp; records.keys) points ~= cp;
    // Include algorithmic syllables in complete mappings, not compiler probes.
    foreach (uint cp; 0xAC00 .. 0xD7A4) points ~= cp;
    sort(points);
    foreach (cp; points)
    {
        auto a = expand(cp, false, canonicalMemo, active);
        auto b = expand(cp, true, compatibilityMemo, active);
        if (a.length != 1 || a[0] != cp) t.sequences["canonicalDecomposition"] ~= SequenceMapping(cp, a);
        if (b.length != 1 || b[0] != cp) t.sequences["compatibilityDecomposition"] ~= SequenceMapping(cp, b);
    }
    foreach (cp, r; records)
        if (!r.compatibility && r.decomposition.length == 2 && !t.properties[fullExcluded].data[cp])
            t.compositions ~= CompositionMapping(r.decomposition[0], r.decomposition[1], cp);
}

private void readCaseFolding(Tables t, string text)
{
    bool[string] seen;
    foreach (raw; lines(text))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length == 4 && !f[3].length, "malformed CaseFolding row");
        auto cp = number(f[0]); auto values = sequence(f[2]);
        require(values.length != 0 && cp < domain, "empty case fold");
        const rowKey = f[0] ~ ";" ~ f[1]; require(!(rowKey in seen), "duplicate case fold"); seen[rowKey] = true;
        switch (f[1])
        {
        case "C": case "S":
            require(values.length == 1, "non-simple simple fold");
            t.scalars["simpleCaseFold"] ~= ScalarMapping(cp, values[0]);
            if (f[1] == "C") t.sequences["fullCaseFold"] ~= SequenceMapping(cp, values);
            break;
        case "F": t.sequences["fullCaseFold"] ~= SequenceMapping(cp, values); break;
        case "T": t.sequences["turkicCaseFold"] ~= SequenceMapping(cp, values); break;
        default: throw new Exception("unknown case folding status");
        }
    }
    // Turkic folding is full folding with the T rows overriding C/F rows,
    // not a sparse override API: an absent span continues to mean identity.
    auto overrides = t.sequences["turkicCaseFold"];
    auto turkic = t.sequences["fullCaseFold"].dup;
    foreach (entry; overrides)
        replaceMapping(turkic, entry.codepoint, entry.values);
    t.sequences["turkicCaseFold"] = turkic;
}
private void replaceMapping(ref SequenceMapping[] mappings, uint cp, uint[] values)
{
    foreach (ref mapping; mappings)
        if (mapping.codepoint == cp) { mapping.values = values; return; }
    mappings ~= SequenceMapping(cp, values);
}
private void readSpecialCasing(Tables t, string text)
{
    foreach (raw; lines(text))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';');
        require((f.length == 5 || (f.length == 6 && !f[5].length)), "malformed SpecialCasing row");
        CaseRule r = CaseRule(number(f[0]), sequence(f[1]), sequence(f[2]), sequence(f[3]), f[4]);
        require(r.codepoint < domain, "invalid special casing scalar");
        if (!r.condition.length)
        {
            replaceMapping(t.sequences["fullLowercase"], r.codepoint, r.lower);
            replaceMapping(t.sequences["fullTitlecase"], r.codepoint, r.title);
            replaceMapping(t.sequences["fullUppercase"], r.codepoint, r.upper);
        }
        else
        {
            foreach (condition; words(r.condition))
                require(condition == "tr" || condition == "az" || condition == "lt" ||
                    condition == "Final_Sigma" || condition == "After_Soft_Dotted" ||
                    condition == "More_Above" || condition == "Before_Dot" ||
                    condition == "Not_Before_Dot" || condition == "After_I", "unknown casing context");
            t.caseRules ~= r;
        }
    }
    sort!((a,b) => a.codepoint == b.codepoint ? a.condition < b.condition : a.codepoint < b.codepoint)(t.caseRules);
}

private void readJoining(Tables t, string text)
{
    auto jt = t.indexes["jt"], jg = t.indexes["jg"], gc = t.indexes["gc"];
    // UAX #44 defaults: Mn, Me, Cf are transparent, otherwise non-joining.
    const transparent = t.valueIndex(t.properties[jt], t.canonicalValue("jt", "T"));
    foreach (uint cp; 0 .. domain)
    {
        const category = t.properties[gc].values[t.properties[gc].data[cp]];
        if (category == "Mn" || category == "Me" || category == "Cf") t.properties[jt].data[cp] = transparent;
    }
    foreach (raw; lines(text))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length == 4, "malformed ArabicShaping row");
        auto r = bounds(f[0]); t.assignValue(jt, r, f[2]); t.assignValue(jg, r, f[3]);
    }
}
private void readScriptExtensions(Tables t, string text)
{
    auto sc = t.indexes["sc"];
    foreach (raw; lines(text))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length == 2, "malformed ScriptExtensions");
        uint[] values;
        foreach (v; words(f[1])) values ~= t.valueIndex(t.properties[sc], t.canonicalValue("sc", v));
        require(values.length != 0, "empty script extensions");
        sort(values);
        foreach (i; 1 .. values.length) require(values[i - 1] < values[i], "duplicate script extension");
        auto r = bounds(f[0]);
        foreach (uint cp; r.first .. r.last + 1) t.sequences["scriptExtensions"] ~= SequenceMapping(cp, values);
    }
}
private void readBidi(Tables t, string brackets, string mirrors)
{
    foreach (raw; lines(brackets))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length == 3 && (f[2] == "o" || f[2] == "c"), "malformed BidiBrackets");
        auto cp = sequence(f[0]), mate = sequence(f[1]); require(cp.length == 1 && mate.length == 1, "invalid bracket scalar");
        t.scalars["bidiBracket"] ~= ScalarMapping(cp[0], mate[0]);
        t.scalars["bidiBracketType"] ~= ScalarMapping(cp[0], f[2] == "o" ? 1 : 2);
    }
    foreach (raw; lines(mirrors))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length == 2, "malformed BidiMirroring");
        auto cp = sequence(f[0]), mate = sequence(f[1]); require(cp.length == 1 && mate.length == 1, "invalid mirror scalar");
        t.scalars["bidiMirror"] ~= ScalarMapping(cp[0], mate[0]);
    }
}
private void readEmoji(Tables t, string text, string path)
{
    bool variation = contains(path, "variation-sequences");
    foreach (raw; lines(text))
    {
        auto line = stripComment(raw); if (!line.length) continue;
        auto f = split(line, ';'); require(f.length >= 2 && f.length <= 3, "malformed emoji row");
        if (variation)
        {
            auto seq = sequence(f[0]); require(seq.length == 2 && (seq[1] == 0xFE0E || seq[1] == 0xFE0F), "invalid variation sequence");
            require(f[1] == "text style" || f[1] == "emoji style", "unknown variation style");
            t.emoji ~= EmojiRecord(seq, seq[1] == 0xFE0F ? "emojiStyle" : "textStyle");
            if (seq[1] == 0xFE0F) t.scalars["isEmojiVsBase"] ~= ScalarMapping(seq[0], 1);
            continue;
        }
        const kind = f[1];
        require(kind == "Basic_Emoji" || kind == "Emoji_Keycap_Sequence" ||
            kind == "RGI_Emoji_Flag_Sequence" || kind == "RGI_Emoji_Tag_Sequence" ||
            kind == "RGI_Emoji_Modifier_Sequence" || kind == "RGI_Emoji_ZWJ_Sequence" ||
            kind == "fully-qualified" || kind == "minimally-qualified" ||
            kind == "unqualified" || kind == "component", "unknown emoji sequence type");
        if (contains(f[0], ".."))
        {
            auto r = bounds(f[0]);
            foreach (uint cp; r.first .. r.last + 1)
            {
                require(cp < 0xD800 || cp > 0xDFFF, "emoji range includes non-scalar");
                t.emoji ~= EmojiRecord([cp], identifier(kind));
            }
        }
        else
        {
            auto seq = sequence(f[0]); require(seq.length != 0, "empty emoji sequence");
            t.emoji ~= EmojiRecord(seq, identifier(kind));
        }
    }
    foreach (r; t.emoji) t.emojiKinds ~= r.kind;
    sort(t.emojiKinds);
    string[] unique;
    foreach (k; t.emojiKinds) if (!unique.length || unique[$ - 1] != k) unique ~= k;
    t.emojiKinds = unique;
}

private struct PackedProperty { uint[] pages, values; }
private PackedProperty pack(scope const(uint)[] raw)
{
    require(raw.length == domain, "invalid property domain");
    PackedProperty result;
    // Hashes accelerate construction only: equality is also checked before
    // deduplicating a page. Assigned indexes follow source order, never AA order.
    uint[][ulong] candidates;
    foreach (size_t base; 0 .. domain / 256)
    {
        auto block = raw[base * 256 .. (base + 1) * 256];
        ulong h = 14695981039346656037UL;
        foreach (v; block) h = (h ^ v) * 1099511628211UL;
        uint page = uint.max;
        foreach (candidate; candidates.get(h, null))
            if (result.values[candidate * 256 .. (candidate + 1) * 256] == block)
            { page = candidate; break; }
        if (page == uint.max)
        {
            page = cast(uint)(result.values.length / 256);
            result.values ~= block;
            candidates[h] ~= page;
        }
        result.pages ~= page;
    }
    // Exhaustive accelerator proof compares compact addressing with the parser's
    // complete-domain representation before any installed output can change.
    foreach (size_t cp; 0 .. domain)
    {
        const index = cast(size_t) result.pages[cp >> 8] * 256 + (cp & 255);
        require(index < result.values.length && result.values[index] == raw[cp], "property accelerator mismatch");
    }
    return result;
}
private string numericArray(string type, string name, scope const(uint)[] data)
{
    auto writer = appender!string;
    writer.put("private immutable " ~ type ~ "[] " ~ name ~ " = [\n");
    foreach (i, value; data)
    {
        if (i % 16 == 0) writer.put("    ");
        writer.formattedWrite("%s,", value);
        writer.put(i % 16 == 15 || i + 1 == data.length ? "\n" : " ");
    }
    writer.put("];\n");
    return writer.data;
}
private string propertySource(ref Property p)
{
    auto packed = pack(p.data);
    const name = "property" ~ identifier(p.name);
    auto writer = appender!string;
    const pageType = packed.values.length / 256 <= ushort.max ? "ushort" : "uint";
    uint maximum;
    foreach (v; packed.values) if (v > maximum) maximum = v;
    const valueType = maximum <= ubyte.max ? "ubyte" : maximum <= ushort.max ? "ushort" : "uint";
    writer.put(numericArray(pageType, name ~ "Pages", packed.pages));
    writer.put(numericArray(valueType, name ~ "Values", packed.values));
    writer.formattedWrite(q{
private uint %1$s(dchar cp) @safe pure nothrow @nogc
{
    assert(cp <= 0x10FFFF, "not a Unicode code point");
    return %1$sValues[cast(size_t) %1$sPages[cp >> 8] * 256 + (cp & 255)];
}
}, name);
    if (p.enumName.length)
    {
        writer.put("enum " ~ p.enumName ~ " : " ~ (p.values.length <= 256 ? "ubyte" : "ushort") ~ "\n{\n");
        foreach (i, member; p.members) writer.formattedWrite("    %s = %s,\n", member, i);
        writer.put("}\n");
        writer.formattedWrite("%s %s(dchar cp) @safe pure nothrow @nogc { return cast(%s) %s(cp); }\n",
            p.enumName, p.functionName, p.enumName, name);
    }
    return writer.data;
}
private string coreSource(Tables t)
{
    uint[] raw = new uint[domain];
    auto g = &t.properties[t.indexes["GCB"]], i = &t.properties[t.indexes["InCB"]],
        c = &t.properties[t.indexes["gc"]], e = &t.properties[t.indexes["ea"]],
        p = &t.properties[t.indexes[t.canonicalProperty("Extended_Pictographic")]];
    require(g.values.length <= 16 && i.values.length <= 4 && c.values.length <= 64 && e.values.length <= 8,
        "core property bit budget exceeded");
    foreach (size_t cp; 0 .. domain)
        raw[cp] = g.data[cp] | (i.data[cp] << 4) | (p.data[cp] << 6) | (c.data[cp] << 7) | (e.data[cp] << 13);
    auto packed = pack(raw);
    auto writer = appender!string;
    writer.put(numericArray("ushort", "corePropertyPages", packed.pages));
    writer.put(numericArray("ushort", "corePropertyValues", packed.values));
    writer.put(q{
/// Fused raw properties, not a terminal-width policy.
struct UnicodeCoreProperties
{
    GraphemeBreakClass grapheme;
    IndicConjunctBreakClass indic;
    bool extendedPictographic;
    GeneralCategory category;
    EastAsianWidthClass eastAsianWidth;
}
UnicodeCoreProperties unicodeCoreProperties(dchar cp) @safe pure nothrow @nogc
{
    assert(cp <= 0x10FFFF, "not a Unicode code point");
    const v = corePropertyValues[cast(size_t) corePropertyPages[cp >> 8] * 256 + (cp & 255)];
    return UnicodeCoreProperties(cast(GraphemeBreakClass)(v & 15),
        cast(IndicConjunctBreakClass)((v >> 4) & 3), (v & 64) != 0,
        cast(GeneralCategory)((v >> 7) & 63), cast(EastAsianWidthClass)((v >> 13) & 7));
}
});
    return writer.data;
}

private enum mappingTypesSource = q{
/// Presence distinguishes a mapped deletion from an absent identity mapping.
struct UnicodeMappingSpan
{
    uint offset;
    ushort length;
    bool present;
}
private struct UnicodeSequenceIndex { uint codepoint, offset; ushort length; }
private struct UnicodeScalarIndex { uint codepoint, value; }
private UnicodeMappingSpan findUnicodeSequence(scope const(UnicodeSequenceIndex)[] index,
    dchar cp) @safe pure nothrow @nogc
{
    assert(cp <= 0x10FFFF, "not a Unicode code point");
    size_t lo, hi = index.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < cp) lo = mid + 1; else hi = mid;
    }
    return lo < index.length && index[lo].codepoint == cp
        ? UnicodeMappingSpan(index[lo].offset, index[lo].length, true) : UnicodeMappingSpan.init;
}
private uint findUnicodeScalar(scope const(UnicodeScalarIndex)[] index,
    dchar cp, uint fallback) @safe pure nothrow @nogc
{
    assert(cp <= 0x10FFFF, "not a Unicode code point");
    size_t lo, hi = index.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].codepoint < cp) lo = mid + 1; else hi = mid;
    }
    return lo < index.length && index[lo].codepoint == cp ? index[lo].value : fallback;
}
};
private string sequenceSource(string name, scope const(SequenceMapping)[] mappings)
{
    uint[] data;
    auto writer = appender!string;
    writer.put("private immutable UnicodeSequenceIndex[] " ~ name ~ "Index = [\n");
    foreach (m; mappings)
    {
        require(data.length <= uint.max - m.values.length, "mapping offset overflow");
        writer.formattedWrite("    UnicodeSequenceIndex(0x%X, %s, %s),\n", m.codepoint, data.length, m.values.length);
        data ~= m.values;
    }
    writer.put("];\n");
    writer.put(numericArray("uint", name ~ "Data", data));
    writer.formattedWrite(q{
UnicodeMappingSpan %1$s(dchar cp) @safe pure nothrow @nogc
{
    return findUnicodeSequence(%1$sIndex, cp);
}
%2$s %1$sValue(size_t offset) @safe pure nothrow @nogc
{
    assert(offset < %1$sData.length, "mapping offset out of bounds");
    return cast(%2$s) %1$sData[offset];
}
}, name, name == "scriptExtensions" ? "Script" : "dchar");
    return writer.data;
}
private string scalarSource(string name, scope const(ScalarMapping)[] mappings)
{
    auto writer = appender!string;
    writer.put("private immutable UnicodeScalarIndex[] " ~ name ~ "Index = [\n");
    foreach (m; mappings) writer.formattedWrite("    UnicodeScalarIndex(0x%X, %s),\n", m.codepoint, m.value);
    writer.put("];\n");
    const isBoolean = name == "isEmojiVsBase";
    const isNumeric = name == "canonicalCombiningClass" || name == "bidiBracketType";
    writer.formattedWrite("%s %s(dchar cp) @safe pure nothrow @nogc\n{\n    return %sfindUnicodeScalar(%sIndex, cp, %s)%s;\n}\n",
        isBoolean ? "bool" : isNumeric ? "ubyte" : "dchar", name,
        isBoolean ? "" : isNumeric ? "cast(ubyte) " : "cast(dchar) ", name,
        isBoolean || isNumeric ? "0" : "cp", isBoolean ? " != 0" : "");
    return writer.data;
}
private string compositionSource(scope const(CompositionMapping)[] mappings)
{
    auto writer = appender!string;
    writer.put("private struct UnicodeComposition { ulong key; uint value; }\n");
    writer.put("private immutable UnicodeComposition[] unicodeCompositions = [\n");
    foreach (m; mappings) writer.formattedWrite("    UnicodeComposition(0x%X, 0x%X),\n",
        (cast(ulong) m.first << 21) | m.second, m.value);
    writer.put(q{];
dchar canonicalComposition(dchar first, dchar second) @safe pure nothrow @nogc
{
    assert(first <= 0x10FFFF && second <= 0x10FFFF, "not a Unicode code point");
    if (first >= 0x1100 && first < 0x1113 && second >= 0x1161 && second < 0x1176)
        return cast(dchar)(0xAC00 + ((first - 0x1100) * 21 + second - 0x1161) * 28);
    if (first >= 0xAC00 && first <= 0xD7A3 && (first - 0xAC00) % 28 == 0 &&
        second > 0x11A7 && second < 0x11C3)
        return cast(dchar)(first + second - 0x11A7);
    const key = (cast(ulong) first << 21) | second;
    size_t lo, hi = unicodeCompositions.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (unicodeCompositions[mid].key < key) lo = mid + 1; else hi = mid;
    }
    return lo < unicodeCompositions.length && unicodeCompositions[lo].key == key
        ? cast(dchar) unicodeCompositions[lo].value : dchar.init;
}
});
    return writer.data;
}

private string casingSource(scope const(CaseRule)[] rules)
{
    auto writer = appender!string;
    uint[] data;
    writer.put(q{
struct UnicodeCaseRule
{
    dchar codepoint;
    UnicodeMappingSpan lower, title, upper;
    /// ASCII tokens: language tags and Unicode casing context predicates.
    string condition;
}
immutable UnicodeCaseRule[] contextualCaseRules = [
});
    foreach (r; rules)
    {
        writer.formattedWrite("    UnicodeCaseRule(0x%X,", r.codepoint);
        foreach (values; [r.lower, r.title, r.upper])
        {
            require(data.length <= uint.max - values.length && values.length <= ushort.max, "context mapping overflow");
            writer.formattedWrite(" UnicodeMappingSpan(%s, %s, true),", data.length, values.length);
            data ~= values;
        }
        writer.put(" \"" ~ r.condition ~ "\"),\n");
    }
    writer.put("];\n");
    writer.put(numericArray("uint", "contextualCaseData", data));
    writer.put(q{
dchar contextualCaseValue(size_t offset) @safe pure nothrow @nogc
{
    assert(offset < contextualCaseData.length);
    return cast(dchar) contextualCaseData[offset];
}
});
    return writer.data;
}
private string emojiSource(Tables t)
{
    auto writer = appender!string;
    writer.put("enum EmojiSequenceKind : ubyte\n{\n");
    foreach (i,k; t.emojiKinds) writer.formattedWrite("    %s = %s,\n", k, i);
    writer.put("}\nstruct EmojiSequenceRecord { UnicodeMappingSpan sequence; EmojiSequenceKind kind; }\n");
    writer.put("immutable EmojiSequenceRecord[] emojiSequences = [\n");
    uint[] data;
    // Deterministic ordering is lexical scalar sequence, then sequence kind.
    sort!((a,b) {
        foreach (i; 0 .. (a.values.length < b.values.length ? a.values.length : b.values.length))
            if (a.values[i] != b.values[i]) return a.values[i] < b.values[i];
        return a.values.length != b.values.length ? a.values.length < b.values.length : a.kind < b.kind;
    })(t.emoji);
    foreach (i, r; t.emoji)
    {
        if (i && t.emoji[i-1].values == r.values && t.emoji[i-1].kind == r.kind)
            throw new Exception("duplicate emoji inventory sequence");
        require(r.values.length <= ushort.max && data.length <= uint.max - r.values.length, "emoji offset overflow");
        writer.formattedWrite("    EmojiSequenceRecord(UnicodeMappingSpan(%s, %s, true), EmojiSequenceKind.%s),\n",
            data.length, r.values.length, r.kind);
        data ~= r.values;
    }
    writer.put("];\n"); writer.put(numericArray("uint", "emojiSequenceData", data));
    writer.put(q{
dchar emojiSequenceValue(size_t offset) @safe pure nothrow @nogc
{
    assert(offset < emojiSequenceData.length);
    return cast(dchar) emojiSequenceData[offset];
}
});
    return writer.data;
}
private string emit(Tables t, Manifest m, string license)
{
    auto writer = appender!string;
    writer.put("// Generated by libs/base/tools/gen_unicode_tables.d; DO NOT EDIT.\n");
    writer.put("// Unicode data attribution and license (retained in every distribution):\n");
    foreach (line; lines(license)) writer.put(line.length ? "// " ~ line ~ "\n" : "//\n");
    writer.put("module sparkles.base.text.unicode_tables;\n");
    writer.formattedWrite("enum unicodeVersion = \"%s\";\nenum unicodeManifestIdentity = \"%s\";\n",
        m.release, m.identity);
    writer.formattedWrite("enum uint unicodeSchemaRevision = %s;\nenum uint unicodeGeneratorRevision = %s;\n", m.schema, generatorRevision);
    writer.put(q{
/// All property, analysis and application cache keys must compare this identity.
bool matchesUnicodeManifest(scope const(char)[] identity) @safe pure nothrow @nogc
{
    return identity == unicodeManifestIdentity;
}
});
    // Property order is stable independent of associative-array implementation.
    sort!((a,b) => a.name < b.name)(t.properties);
    t.indexes = null;
    foreach (i,p; t.properties) t.indexes[p.name] = i;
    writer.put("enum UnicodeProperty : ushort\n{\n");
    foreach (i,p; t.properties) writer.formattedWrite("    %s = %s,\n", identifier(p.name), i);
    writer.put("}\n");
    foreach (ref p; t.properties) writer.put(propertySource(p));
    writer.put(q"UNICODE_QUERY
/// Enumerated values use the source's short PropertyValueAliases spelling.
uint unicodePropertyValue(dchar cp, UnicodeProperty property) @safe pure nothrow @nogc
{
    final switch (property)
    {
UNICODE_QUERY");
    foreach (p; t.properties) writer.formattedWrite("    case UnicodeProperty.%s: return property%s(cp);\n", identifier(p.name), identifier(p.name));
    writer.put("    }\n}\n");
    writer.put("string unicodePropertyValueName(UnicodeProperty property, uint value) @safe pure nothrow @nogc\n{\n    final switch(property)\n    {\n");
    foreach (p; t.properties)
    {
        writer.formattedWrite("    case UnicodeProperty.%s:\n", identifier(p.name));
        writer.put("        switch(value) {\n");
        foreach (i,v; p.values) writer.formattedWrite("        case %s: return \"%s\";\n", i, v);
        writer.put("        default: assert(0, \"invalid property value\");\n        }\n");
    }
    writer.put("    }\n}\n");
    writer.put("bool unicodeProperty(dchar cp, UnicodeProperty property) @safe pure nothrow @nogc\n{\n    switch(property)\n    {\n");
    foreach (p; t.properties) if (p.binary) writer.formattedWrite("    case UnicodeProperty.%s: return property%s(cp) != 0;\n", identifier(p.name), identifier(p.name));
    writer.put("    default: assert(0, \"not a binary Unicode property\");\n    }\n}\n");
    writer.put(coreSource(t));
    writer.put(q{
bool isEastAsianWide(dchar cp) @safe pure nothrow @nogc
{
    const width = eastAsianWidthClass(cp);
    return width == EastAsianWidthClass.W || width == EastAsianWidthClass.F;
}
bool isEastAsianAmbiguous(dchar cp) @safe pure nothrow @nogc
{
    return eastAsianWidthClass(cp) == EastAsianWidthClass.A;
}
bool isUnicodeMark(dchar cp) @safe pure nothrow @nogc
{
    const category = generalCategory(cp);
    return category == GeneralCategory.Mn || category == GeneralCategory.Mc || category == GeneralCategory.Me;
}
bool isUnicodeUppercase(dchar cp) @safe pure nothrow @nogc
{
    const category = generalCategory(cp);
    return category == GeneralCategory.Lu || category == GeneralCategory.Lt;
}
bool isUnicodeControl(dchar cp) @safe pure nothrow @nogc { return generalCategory(cp) == GeneralCategory.Cc; }
bool isUnicodeFormat(dchar cp) @safe pure nothrow @nogc { return generalCategory(cp) == GeneralCategory.Cf; }
});
    writer.formattedWrite("bool isExtendedPictographic(dchar cp) @safe pure nothrow @nogc { return property%s(cp) != 0; }\n",
        identifier(t.canonicalProperty("Extended_Pictographic")));
    writer.put(mappingTypesSource);
    string[] sequenceNames = t.sequences.keys;
    sort(sequenceNames);
    foreach (name; sequenceNames) writer.put(sequenceSource(name, t.sequences[name]));
    string[] scalarNames = t.scalars.keys;
    sort(scalarNames);
    foreach (name; scalarNames) writer.put(scalarSource(name, t.scalars[name]));
    writer.put(compositionSource(t.compositions));
    writer.put(casingSource(t.caseRules));
    writer.put(emojiSource(t));
    writer.put(blockOctantTableSource(t.unicodeData));
    return writer.data;
}

private string blockOctantTableSource(string unicodeData)
{
    static struct Borrowed { uint pattern, codepoint; string name; }
    static immutable Borrowed[] borrowed = [
        Borrowed(0, 0x0020, "SPACE"),
        Borrowed(1, 0x1CEA8, "LEFT HALF UPPER ONE QUARTER BLOCK"),
        Borrowed(2, 0x1CEAB, "RIGHT HALF UPPER ONE QUARTER BLOCK"),
        Borrowed(3, 0x1FB82, "UPPER ONE QUARTER BLOCK"),
        Borrowed(5, 0x2598, "QUADRANT UPPER LEFT"),
        Borrowed(10, 0x259D, "QUADRANT UPPER RIGHT"),
        Borrowed(15, 0x2580, "UPPER HALF BLOCK"),
        Borrowed(20, 0x1FBE6, "MIDDLE LEFT ONE QUARTER BLOCK"),
        Borrowed(40, 0x1FBE7, "MIDDLE RIGHT ONE QUARTER BLOCK"),
        Borrowed(63, 0x1FB85, "UPPER THREE QUARTERS BLOCK"),
        Borrowed(64, 0x1CEA3, "LEFT HALF LOWER ONE QUARTER BLOCK"),
        Borrowed(80, 0x2596, "QUADRANT LOWER LEFT"),
        Borrowed(85, 0x258C, "LEFT HALF BLOCK"),
        Borrowed(90, 0x259E, "QUADRANT UPPER RIGHT AND LOWER LEFT"),
        Borrowed(95, 0x259B, "QUADRANT UPPER LEFT AND UPPER RIGHT AND LOWER LEFT"),
        Borrowed(128, 0x1CEA0, "RIGHT HALF LOWER ONE QUARTER BLOCK"),
        Borrowed(160, 0x2597, "QUADRANT LOWER RIGHT"),
        Borrowed(165, 0x259A, "QUADRANT UPPER LEFT AND LOWER RIGHT"),
        Borrowed(170, 0x2590, "RIGHT HALF BLOCK"),
        Borrowed(175, 0x259C, "QUADRANT UPPER LEFT AND UPPER RIGHT AND LOWER RIGHT"),
        Borrowed(192, 0x2582, "LOWER ONE QUARTER BLOCK"),
        Borrowed(240, 0x2584, "LOWER HALF BLOCK"),
        Borrowed(245, 0x2599, "QUADRANT UPPER LEFT AND LOWER LEFT AND LOWER RIGHT"),
        Borrowed(250, 0x259F, "QUADRANT UPPER RIGHT AND LOWER LEFT AND LOWER RIGHT"),
        Borrowed(252, 0x2586, "LOWER THREE QUARTERS BLOCK"),
        Borrowed(255, 0x2588, "FULL BLOCK"),
    ];
    uint[256] table;
    bool[256] have;
    string[uint] names;
    foreach (raw; lines(unicodeData))
    {
        if (!raw.length) continue;
        auto f = split(raw, ';'); require(f.length == 15, "invalid UnicodeData octant row");
        auto cp = number(f[0]); const name = f[1]; names[cp] = name;
        enum prefix = "BLOCK OCTANT-";
        if (!starts(name, prefix)) continue;
        uint pattern;
        foreach (char c; name[prefix.length .. $])
        {
            require(c >= '1' && c <= '8', "invalid block octant digit");
            require(!(pattern & (1u << (c - '1'))), "duplicate block octant digit");
            pattern |= 1u << (c - '1');
        }
        require(!have[pattern], "duplicate block octant");
        have[pattern] = true; table[pattern] = cp;
    }
    foreach (b; borrowed)
    {
        require(!have[b.pattern] && names.get(b.codepoint, "") == b.name, "borrowed block glyph name mismatch");
        have[b.pattern] = true; table[b.pattern] = b.codepoint;
    }
    foreach (h; have) require(h, "missing block octant glyph");
    auto writer = appender!string;
    writer.put("/// Unicode row-major block-octant pattern glyphs.\nimmutable dchar[256] blockOctantGlyphs = [\n");
    foreach (i, cp; table)
    {
        if (i % 8 == 0) writer.put("    ");
        writer.formattedWrite("0x%X,", cp); writer.put(i % 8 == 7 ? "\n" : " ");
    }
    writer.put("];\n"); return writer.data;
}

unittest
{
    import std.exception : assertThrown;
    // Byte parsing must not accept locale/Unicode whitespace or partial numbers.
    assert(number("10FFFF") == 0x10FFFF);
    assertThrown!Exception(number("123Z"));
    assertThrown!Exception(number("100000000"));
    assertThrown!Exception(bounds("0041..003F"));
    assertThrown!Exception(bounds("0041.0042"));
    assertThrown!Exception(sequence("D800"));
    assert(words(" 0041\t0042\r ") == ["0041", "0042"]);
    assert(words("0041\u00A00042").length == 1);
    assert(digest(cast(const(ubyte)[]) "abc") ==
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}
unittest
{
    import std.exception : assertThrown;
    auto t = new Tables;
    t.aliases("gc; General_Category\nGCB; Grapheme_Cluster_Break\n",
        "gc; Cn; Unassigned\ngc; Lu; Uppercase_Letter\nGCB; XX; Other\nGCB; EX; Extend\n");
    auto i = t.add("Grapheme_Cluster_Break", "Other");
    t.propertyFile("# @missing: 0000..10FFFF; Other\n# @missing: 0100..01FF; Extend\n0041; Extend\n", "GCB");
    assert(t.properties[i].values[t.properties[i].data[0x41]] == "EX");
    assert(t.properties[i].values[t.properties[i].data[0x100]] == "EX");
    assert(t.properties[i].values[t.properties[i].data[0x200]] == "XX");
    assertThrown!Exception(t.propertyFile("0040..0042; Other\n", "GCB"));
    assertThrown!Exception(t.propertyFile("0043; Imaginary\n", "GCB"));
    assertThrown!Exception(t.propertyFile("0043\n", "GCB"));
    auto packed = pack(t.properties[i].data);
    assert(packed.values[packed.pages[0x100 >> 8] * 256] == t.properties[i].data[0x100]);
    assert(packed.values[packed.pages[0x10FFFF >> 8] * 256 + 255] == t.properties[i].data[0x10FFFF]);
}
unittest
{
    import std.exception : assertThrown;
    records = null;
    records[0xC5] = UcdRecord(false, [0x41, 0x30A]);
    records[0x212B] = UcdRecord(false, [0xC5]);
    records[0xFB00] = UcdRecord(true, [0x66, 0x66]);
    uint[][uint] memo;
    bool[uint] active;
    assert(expand(0x212B, false, memo, active) == [0x41, 0x30A]);
    assert(expand(0xAC01, false, memo, active) == [0x1100, 0x1161, 0x11A8]);
    assert(expand(0xFB00, false, memo, active) == [0xFB00]);
    memo = null;
    assert(expand(0xFB00, true, memo, active) == [0x66, 0x66]);
    records[0x41] = UcdRecord(false, [0x42]);
    records[0x42] = UcdRecord(false, [0x41]);
    memo = null;
    assertThrown!Exception(expand(0x41, false, memo, active));
    records = null;
}

unittest
{
    import std.exception : assertThrown;
    auto t = new Tables;
    t.aliases("gc; General_Category\n", "gc; Cn; Unassigned\ngc; Lo; Other_Letter\n");
    auto gc = t.add("gc", "Cn");
    t.assignValue(gc, Bounds(0x3400, 0x3402), "Lo");
    t.unicodeData =
        "3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;\n" ~
        "3402;<CJK Ideograph Extension A, Last>;Lo;0;L;;;;;N;;;;;\n";
    readUnicodeData(t);
    t.unicodeData = "3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;\n";
    assertThrown!Exception(readUnicodeData(t));
    t.unicodeData =
        "3400;<CJK Ideograph Extension A, First>;Lo;0;L;;;;;N;;;;;\n" ~
        "3402;<CJK Ideograph Extension B, Last>;Lo;0;L;;;;;N;;;;;\n";
    assertThrown!Exception(readUnicodeData(t));
    t.unicodeData = "3400;TRUNCATED;Lo\n";
    assertThrown!Exception(readUnicodeData(t));
}

unittest
{
    import std.exception : assertThrown;
    Artifact source = Artifact("fixture.txt", "", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "source");
    assert(checkedText(source, cast(const(ubyte)[]) "abc") == "abc");
    assertThrown!Exception(checkedText(source, cast(const(ubyte)[]) "abd"));
    assertThrown!Exception(checkedText(source, cast(const(ubyte)[]) "ab"));
}

unittest
{
    import std.exception : assertThrown;
    auto t = new Tables;
    t.aliases("Comp_Ex; Full_Composition_Exclusion\nNFKC_CF; NFKC_Casefold\n" ~
        "NFKC_SCF; NFKC_Simple_Casefold\nFC_NFKC; FC_NFKC_Closure\n",
        "Comp_Ex; N; No\nComp_Ex; Y; Yes\n");
    records = null;
    records[0xC5] = UcdRecord(false, [0x41, 0x30A]);
    records[0x344] = UcdRecord(false, [0x308, 0x301]);
    readNormalization(t, "0344; Full_Composition_Exclusion\n", "0344\n");
    assert(t.compositions.length == 1 &&
        t.compositions[0].first == 0x41 && t.compositions[0].second == 0x30A &&
        t.compositions[0].value == 0xC5);
    auto u = new Tables;
    u.aliases("Comp_Ex; Full_Composition_Exclusion\n",
        "Comp_Ex; N; No\nComp_Ex; Y; Yes\n");
    assertThrown!Exception(readNormalization(u, "", "00C5\n"));
    records = null;
}
unittest
{
    import std.exception : assertThrown;
    auto t = new Tables;
    readEmoji(t, "1F1E6 1F1E7; RGI_Emoji_Flag_Sequence; flag\n", "emoji/emoji-sequences.txt");
    assert(t.emoji[0].values == [0x1F1E6, 0x1F1E7] &&
        t.emoji[0].kind == "RGI_Emoji_Flag_Sequence");
    readEmoji(t, "1F1E6 1F1E7; fully-qualified # flag\n", "emoji/emoji-test.txt");
    assert(t.emoji[1].values == [0x1F1E6, 0x1F1E7] && t.emoji[1].kind == "fully_qualified");
    assertThrown!Exception(readEmoji(t, "D800; Basic_Emoji; invalid\n", "emoji/emoji-sequences.txt"));
    assertThrown!Exception(readEmoji(t, "D800..D801; Basic_Emoji; invalid\n", "emoji/emoji-sequences.txt"));
    assertThrown!Exception(readEmoji(t, "1F1E6; Invented_Emoji; invalid\n", "emoji/emoji-sequences.txt"));
}

@system
unittest
{
    auto tables = new Tables;
    readCaseFolding(tables,
        "0041; C; 0061;\n0049; C; 0069;\n0049; T; 0131;\n"
        ~ "0130; F; 0069 0307;\n0130; T; 0069;\n00DF; F; 0073 0073;\n");
    uint[] mapping(string name, uint scalar) @system
    {
        foreach (entry; tables.sequences[name])
            if (entry.codepoint == scalar)
                return entry.values;
        return null;
    }
    assert(mapping("fullCaseFold", 0x0049) == [0x0069]);
    assert(mapping("fullCaseFold", 0x0130) == [0x0069, 0x0307]);
    assert(mapping("turkicCaseFold", 0x0049) == [0x0131]);
    assert(mapping("turkicCaseFold", 0x0130) == [0x0069]);
    assert(mapping("turkicCaseFold", 0x0041) == [0x0061]);
    assert(mapping("turkicCaseFold", 0x00DF) == [0x0073, 0x0073]);
}
