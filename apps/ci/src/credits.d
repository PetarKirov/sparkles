/++
Check that the credits document (`docs/credits/`) names every third-party
component the applications link or ship, and nothing they do not
(`docs/specs/terminal/pages.md` `TPG12`–`TPG14`).

The document is one markdown $(I part) per component
(`docs/credits/parts/<id>.md`) and one page per application
(`docs/credits/<app>.md`) composed of parts by VitePress file inclusion. A part
opens with a field table the check reads:

---md
### raylib

| Field          | Value                                             |
| -------------- | ------------------------------------------------- |
| Version source | nixpkgs `raylib`                                  |
| Licence        | `Zlib`                                            |
| Home           | https://www.raylib.com                            |
| Ships as       | `libraylib.a` in the APKs; `-lraylib` on desktops |
---

The components themselves are read from the build inputs, never from a list
kept beside them ($(LREF scanShipped)):

$(LIST
    $(ITEM `nix/dub-lock.json` and each application's `dub.selections.json`
        — every dub package, project-wide;)
    $(ITEM each application's dub manifest and its `sparkles:*` closure — the
        dub packages (`dub:<name>`) and native libraries (`-l<name>`) it links;)
    $(ITEM the APK builders — the static archives they link (`libX.a`), the
        dub packages they compile in (`dubDeps`, transitive ones included), the
        font files they bundle, and the tree-sitter grammar bundle;)
    $(ITEM `nix/packages/fonts.nix` — the font packages the shared bundle copies,
        for a builder that bundles all of it.)
)

A part provides the tokens in its $(B Ships as) row, plus `dub:<name>` when its
version source is a dub package. Every scanned token must be provided by a part,
every part must provide a scanned token, and each application page must include
exactly the parts its own tokens are provided by.

Split out from `app.d` so the readers and the matcher are unit-tested (the main
source file is excluded from the auto-generated test runner).
+/
module credits;

import std.algorithm : any, canFind, endsWith, filter, map, sort, startsWith, uniq;
import std.array : array, join, split;
import std.json : JSONType, parseJSON;
import std.path : baseName, buildNormalizedPath, dirName, globMatch, stripExtension;
import std.regex : ctRegex, matchAll, matchFirst, replaceAll;
import std.string : indexOf, lineSplitter, strip;
import sparkles.base.text.case_text : asciiLower;

/// An application with its own credits page, and where its inputs are named.
struct CreditedApp
{
    string name;           /// the page stem: `docs/credits/<name>.md`
    string appDir;         /// its dub package directory
    string[] apkBuilders;  /// the Nix files that assemble its APK
    string[] nixBuilders;  /// other Nix files naming what it links or ships
}

/// The applications whose credits pages the check composes.
immutable CreditedApp[] creditedApps = [
    CreditedApp(
        name: "terminal",
        appDir: "apps/terminal",
        apkBuilders: ["nix/packages/android/terminal.nix"],
        nixBuilders: [],
    ),
    CreditedApp(
        name: "hue",
        appDir: "apps/hue",
        apkBuilders: ["nix/packages/android/hue.nix"],
        nixBuilders: ["nix/packages/hue.nix"],
    ),
];

/// Repo-relative paths the check reads.
enum creditsDir = "docs/credits";
enum partsDir = "docs/credits/parts"; /// ditto
enum dubLockPath = "nix/dub-lock.json"; /// ditto
enum fontBundlePath = "nix/packages/fonts.nix"; /// ditto

/// One component's part, as its field table states it.
struct CreditPart
{
    string id;             /// the file stem: `parts/<id>.md`
    string name;           /// the first `### ` heading
    string versionSource;  /// the $(B Version source) cell, verbatim
    string licence;        /// the $(B Licence) cell
    string home;           /// the $(B Home) cell
    string[] shipsAs;      /// the backticked tokens of the $(B Ships as) cell
    string[] includes;     /// the files the part includes, as written
    string[] errors;       /// what the part is missing or gets wrong

    /// The tokens this part answers for: its $(B Ships as) tokens, plus
    /// `dub:<name>` when the version source is a dub package.
    string[] provides() const @safe
    {
        auto result = shipsAs.dup;
        const dub = dubPackageOf(versionSource);
        if (dub.length)
            result ~= "dub:" ~ dub;
        return result;
    }
}

/// The package named by a `` dub package `name` `` version source, or `null`.
string dubPackageOf(string versionSource) @safe
{
    const m = versionSource.matchFirst(ctRegex!"^dub package `([^`]+)`");
    return m.empty ? null : m[1];
}

/// The backticked spans of a table cell.
string[] backticked(string cell) @safe
    => cell.matchAll(ctRegex!"`([^`]+)`").map!(m => m[1]).array;

/// The targets of every VitePress include directive in `text`, as written
/// (region and line-range suffixes are kept; the check never uses them).
string[] includeTargets(string text) @safe
    => text.matchAll(ctRegex!`<!--\s*@include:\s*(.*?)\s*-->`).map!(m => m[1]).array;

@("credits.includeTargets.readsEveryDirective")
@safe unittest
{
    const text = "a\n<!-- @include: ./parts/raylib.md -->\n```text\n"
        ~ "<!--@include:../licenses/raylib/LICENSE-->\n```\n";
    assert(includeTargets(text) == ["./parts/raylib.md", "../licenses/raylib/LICENSE"]);
}

/++
Reads a part. Field names are matched case-insensitively; a part missing its
heading, a field, a home, or a licence include of its own reports it in
`errors` rather than failing the read, so one run lists every broken part.
+/
CreditPart parsePart(string id, string text) @safe
{
    CreditPart part;
    part.id = id;
    bool inFence;
    foreach (raw; text.lineSplitter)
    {
        const line = raw.strip;
        if (line.startsWith("```"))
            inFence = !inFence;
        if (inFence)
            continue;
        if (!part.name.length && line.startsWith("### "))
            part.name = line["### ".length .. $].strip;
        if (!line.startsWith("|"))
            continue;
        auto cells = line.split("|").map!strip.array;
        // `| a | b |` splits into ["", "a", "b", ""].
        if (cells.length != 4)
            continue;
        const value = cells[2];
        switch (cells[1].asciiLower)
        {
            case "version source": part.versionSource = value; break;
            case "licence": part.licence = value; break;
            case "home": part.home = value; break;
            case "ships as": part.shipsAs = backticked(value); break;
            default: break;
        }
    }
    part.includes = includeTargets(text);

    if (!part.name.length)
        part.errors ~= "no `### ` heading naming the component";
    if (!part.versionSource.length)
        part.errors ~= "no `Version source` field";
    else if (part.versionSource.matchFirst(
            ctRegex!"^(flake input|nixpkgs|dub package|grammar bundle) `[^`]+`").empty)
        part.errors ~= "`Version source` is not one of: flake input `…`, nixpkgs `…`, "
            ~ "dub package `…`, grammar bundle `…`";
    if (!backticked(part.licence).length)
        part.errors ~= "no `Licence` field with a backticked SPDX expression";
    if (!part.home.startsWith("https://") && !part.home.startsWith("<https://"))
        part.errors ~= "no `Home` field with an https URL";
    if (!part.shipsAs.length && !dubPackageOf(part.versionSource).length)
        part.errors ~= "no `Ships as` field naming what ships";

    const own = "../licenses/" ~ id ~ "/";
    if (!part.includes.any!(t => t.startsWith(own)))
        part.errors ~= "includes no licence text from `" ~ own ~ "…`";
    foreach (t; part.includes)
        if (!t.startsWith(own))
            part.errors ~= "includes `" ~ t ~ "`, outside its own `" ~ own ~ "`";
    return part;
}

@("credits.parsePart.readsTheFieldTable")
@safe unittest
{
    const text = "### raylib\n\n"
        ~ "| Field          | Value              |\n"
        ~ "| -------------- | ------------------ |\n"
        ~ "| Version source | nixpkgs `raylib`   |\n"
        ~ "| Licence        | `Zlib`             |\n"
        ~ "| Home           | https://raylib.com |\n"
        ~ "| Ships as       | `libraylib.a`; `-lraylib` |\n\n"
        ~ "Prose.\n\n````text\n<!-- @include: ../licenses/raylib/LICENSE -->\n````\n";
    const part = parsePart("raylib", text);
    assert(part.errors.length == 0, part.errors.join("; "));
    assert(part.name == "raylib");
    assert(part.provides == ["libraylib.a", "-lraylib"]);
    assert(part.includes == ["../licenses/raylib/LICENSE"]);
}

@("credits.parsePart.dubPackagesProvideThemselves")
@safe unittest
{
    const text = "### bolts\n\n| Field | Value |\n| - | - |\n"
        ~ "| Version source | dub package `bolts` |\n| Licence | `BSL-1.0` |\n"
        ~ "| Home | https://code.dlang.org/packages/bolts |\n\n"
        ~ "<!-- @include: ../licenses/bolts/LICENSE -->\n";
    const part = parsePart("bolts", text);
    assert(part.errors.length == 0, part.errors.join("; "));
    assert(part.provides == ["dub:bolts"]);
}

@("credits.parsePart.reportsWhatIsMissing")
@safe unittest
{
    const part = parsePart("x", "### X\n\n| Field | Value |\n| - | - |\n"
        ~ "| Version source | somewhere |\n<!-- @include: ../licenses/y/LICENSE -->\n");
    assert(part.errors.canFind!(e => e.canFind("Version source")));
    assert(part.errors.canFind!(e => e.canFind("Licence")));
    assert(part.errors.canFind!(e => e.canFind("Home")));
    assert(part.errors.canFind!(e => e.canFind("Ships as")));
    assert(part.errors.canFind!(e => e.canFind("includes no licence text")));
    assert(part.errors.canFind!(e => e.canFind("outside its own")));
}

/// A component the build inputs name, and who names it.
struct ShippedToken
{
    string token;   /// `dub:bolts`, `-lraylib`, `libz.a`, `DejaVuSansMono.ttf`, …
    string app;     /// the application it ships in; empty for project-wide
    string origin;  /// the file that named it
}

/// The packages a dub lock or selections file pins.
string[] dubPackagesIn(string json) @safe
{
    auto root = parseJSON(json);
    foreach (key; ["dependencies", "versions"])
        if (auto obj = key in root.objectNoRef)
            if (obj.type == JSONType.object)
                return obj.objectNoRef.keys.sort.release;
    return null;
}

@("credits.dubPackagesIn.readsLocksAndSelections")
@safe unittest
{
    assert(dubPackagesIn(`{"dependencies": {"silly": {}, "bolts": {}}}`) == ["bolts", "silly"]);
    assert(dubPackagesIn(`{"fileVersion": 1, "versions": {"during": "0.5.0"}}`) == ["during"]);
}

/// A dub manifest up to its `unittest` configuration, which nothing ships.
string shippedManifest(string sdl) @safe pure
{
    const at = sdl.indexOf(`configuration "unittest"`);
    return at < 0 ? sdl : sdl[0 .. at];
}

/// Strips `//` line comments, so a manifest's prose is not read as recipe.
private string withoutLineComments(string sdl) @safe pure
    => sdl.lineSplitter
        .map!((l) { const c = l.indexOf("//"); return c < 0 ? l : l[0 .. c]; })
        .join("\n");

/// The `sparkles:*` libraries a manifest pulls in: its dependencies and the
/// sibling sources it includes directly (`../<name>/src`).
string[] sparklesEdges(string sdl) @safe
{
    const text = shippedManifest(sdl).withoutLineComments;
    string[] names;
    foreach (m; text.matchAll(ctRegex!`dependency "sparkles:([a-z0-9-]+)"`))
        names ~= m[1];
    foreach (m; text.matchAll(ctRegex!`"\.\./(?:\.\./libs/)?([a-z0-9-]+)/src"`))
        names ~= m[1];
    return names;
}

/// The third-party dub packages (`dub:<name>`) and native libraries
/// (`-l<name>`) a manifest links, from every configuration but `unittest`.
string[] manifestTokens(string sdl) @safe
{
    const text = shippedManifest(sdl).withoutLineComments;
    string[] tokens;
    foreach (m; text.matchAll(ctRegex!`dependency "([a-z0-9][a-z0-9_-]*)(?::[a-z0-9_-]+)?"`))
        if (m[1] != "sparkles")
            tokens ~= "dub:" ~ m[1];
    foreach (m; text.matchAll(ctRegex!`(?m)^\s*libs\s+([^\n]*)`))
    {
        // `platform="linux"` is an attribute, not a library.
        const values = m[1].replaceAll(ctRegex!`[A-Za-z]+="[^"]*"`, "");
        foreach (lib; values.matchAll(ctRegex!`"([^"]+)"`))
            tokens ~= "-l" ~ lib[1];
    }
    return tokens;
}

@("credits.manifestTokens.readsDependenciesAndLibs")
@safe unittest
{
    const sdl = `dependency "raylib-d" version="~>6.0.1"
dependency "sparkles:base" path="../.."
dependency "dmd:frontend" repository="git+https://example.org/dmd.git"
// dependency "commented" version="1"
libs "raylib" "freetype2"
configuration "application" {
    libs "curl"
    libs "kqueue" platform="linux"
}
configuration "unittest" {
    dependency "silly" version="~>1.1"
    libs "never"
}`;
    assert(manifestTokens(sdl).sort.release == [
        "-lcurl", "-lfreetype2", "-lkqueue", "-lraylib", "dub:dmd", "dub:raylib-d",
    ]);
    assert(sparklesEdges(sdl) == ["base"]);
}

/// The static archives an APK builder links (`lib/${abi}/libX.a`).
string[] staticArchives(string nix) @safe
    => nix.matchAll(ctRegex!`/lib/\$\{abi\}/(lib[A-Za-z0-9_.+-]+\.a)`).map!(m => m[1]).array;

/// The dub packages an APK builder compiles in (`dubDeps`), transitive ones
/// included — the manifests name only direct dependencies.
string[] apkDubPackages(string nix) @safe
    => nix.matchAll(ctRegex!`name = "([a-z0-9][a-z0-9_-]*)";\s*src = inputs\.dub-`)
        .map!(m => "dub:" ~ m[1]).array;

/// The font files an APK builder bundles by name, and the globs it copies
/// from the shared bundle (`${fonts.fontBundle}/fonts/Noto*`).
string[] namedFonts(string nix) @safe
{
    string[] fonts;
    foreach (m; nix.matchAll(ctRegex!`"([A-Za-z0-9_-]+\.(?:ttf|otf))"`))
        fonts ~= m[1];
    foreach (m; nix.matchAll(ctRegex!`fontBundle\}/fonts/([A-Za-z0-9_-]*\*)`))
        fonts ~= m[1];
    return fonts;
}

/// Whether an APK builder copies the whole shared font bundle.
bool copiesWholeFontBundle(string nix) @safe
    => !nix.matchFirst(ctRegex!`fontBundle\}/fonts\s`).empty;

/// The font packages the shared bundle (`fonts.nix`) copies faces from.
string[] fontBundlePackages(string nix) @safe
    => nix.matchAll(ctRegex!`\$\{(pkgs\.[A-Za-z0-9_.-]+|maple-mono)\}/share/fonts`)
        .map!(m => m[1]).array.sort.uniq.array;

/// Whether a builder ships the tree-sitter grammar bundle.
bool shipsGrammars(string nix) @safe
    => !nix.matchFirst(ctRegex!`config\.packages\.ts-grammars(?:-android)?\b`).empty;

@("credits.builderReaders.readWhatTheBuildersName")
@safe unittest
{
    const apk = `staticLibs = abi: [
        "${config.packages.raylib-android}/lib/${abi}/libraylib.a"
        "${config.packages.freetype-android}/lib/${abi}/libpng16.a"
    ];
    bundledFonts = [
        "FiraCodeNerdFontMono-Regular.ttf"
    ];
        cp ${fonts.fontBundle}/fonts/Noto* $out/fonts/
        grammarLibDir = "${config.packages.ts-grammars-android}/lib/${t.abi}";`;
    assert(staticArchives(apk) == ["libraylib.a", "libpng16.a"]);
    assert(apkDubPackages("dubDeps = [\n  {\n    name = \"bolts\";\n    src = inputs.dub-bolts;\n  }\n];")
        == ["dub:bolts"]);
    assert(namedFonts(apk) == ["FiraCodeNerdFontMono-Regular.ttf", "Noto*"]);
    assert(!copiesWholeFontBundle(apk));
    assert(copiesWholeFontBundle("cp -rL ${fonts.fontBundle}/fonts $out/fonts"));
    assert(shipsGrammars(apk));
    assert(fontBundlePackages("cp ${pkgs.dejavu_fonts}/share/fonts/truetype/$f\n"
        ~ "for f in ${maple-mono}/share/fonts/truetype/*.ttf; do")
        == ["maple-mono", "pkgs.dejavu_fonts"]);
}

/++
Whether a scanned token is the component a part's $(B Ships as) entry names.
Equal spellings match; a part's glob (`DejaVuSansMono*.ttf`) matches the file
names it covers; and a builder's glob (`Noto*`) matches every part whose
pattern starts inside it, since it copies all of them.
+/
bool tokenMatches(string token, string pattern) @safe pure
{
    if (token == pattern)
        return true;
    if (pattern.canFind('*') && globMatch(token, pattern))
        return true;
    const star = token.indexOf('*');
    if (star >= 0)
    {
        const prefix = token[0 .. star];
        const literal = pattern[0 .. pattern.indexOf('*') < 0 ? $ : pattern.indexOf('*')];
        return literal.length >= prefix.length && literal.startsWith(prefix);
    }
    return false;
}

@("credits.tokenMatches.globsBothWays")
@safe pure unittest
{
    assert(tokenMatches("libz.a", "libz.a"));
    assert(!tokenMatches("libz.a", "libzstd.a"));
    assert(tokenMatches("DejaVuSansMono-Bold.ttf", "DejaVuSansMono*.ttf"));
    assert(!tokenMatches("DejaVuSerif.ttf", "DejaVuSansMono*.ttf"));
    assert(tokenMatches("Noto*", "NotoSans*.ttf"));
    assert(tokenMatches("Noto*", "NotoColorEmoji.ttf"));
    assert(!tokenMatches("Noto*", "DejaVuSansMono*.ttf"));
}

/// Reads a repo-relative file; `null` when it does not exist.
alias FileReader = string delegate(string relPath) @safe;

/++
Every component the build inputs name. Reports a reader that found nothing
where it must find something (a builder with no static archive, a font bundle
with no package) in `problems`: a pattern gone stale must fail the check, not
quietly credit nothing.
+/
ShippedToken[] scanShipped(scope FileReader read, ref string[] problems) @safe
{
    ShippedToken[] found;

    const lock = read(dubLockPath);
    if (lock is null)
        problems ~= "cannot read " ~ dubLockPath;
    else
        foreach (name; dubPackagesIn(lock))
            found ~= ShippedToken("dub:" ~ name, null, dubLockPath);

    const bundle = read(fontBundlePath);
    const bundlePackages = bundle is null ? null : fontBundlePackages(bundle);
    if (!bundlePackages.length)
        problems ~= "found no font package in " ~ fontBundlePath;

    foreach (app; creditedApps)
    {
        const selections = app.appDir ~ "/dub.selections.json";
        if (const text = read(selections))
            foreach (name; dubPackagesIn(text))
                found ~= ShippedToken("dub:" ~ name, null, selections);

        // The app's `sparkles:*` closure, as buildSparklesApp derives it.
        string[] seen;
        string[] frontier = [app.appDir];
        while (frontier.length)
        {
            const dir = frontier[0];
            frontier = frontier[1 .. $];
            if (seen.canFind(dir))
                continue;
            seen ~= dir;
            const manifest = dir ~ "/dub.sdl";
            const sdl = read(manifest);
            if (sdl is null)
            {
                problems ~= "cannot read " ~ manifest;
                continue;
            }
            foreach (t; manifestTokens(sdl))
                found ~= ShippedToken(t, app.name, manifest);
            foreach (lib; sparklesEdges(sdl))
                frontier ~= "libs/" ~ lib;
        }

        foreach (builder; app.apkBuilders ~ app.nixBuilders)
        {
            const nix = read(builder);
            if (nix is null)
            {
                problems ~= "cannot read " ~ builder;
                continue;
            }
            const archives = staticArchives(nix);
            if (app.apkBuilders.canFind(builder) && !archives.length)
                problems ~= "found no static archive in " ~ builder;
            foreach (a; archives)
                found ~= ShippedToken(a, app.name, builder);
            foreach (d; apkDubPackages(nix))
                found ~= ShippedToken(d, app.name, builder);
            foreach (f; namedFonts(nix))
                found ~= ShippedToken(f, app.name, builder);
            if (copiesWholeFontBundle(nix))
                foreach (p; bundlePackages)
                    found ~= ShippedToken(p, app.name, fontBundlePath);
            if (shipsGrammars(nix))
                found ~= ShippedToken("ts-grammars", app.name, builder);
        }
    }
    return found;
}

/// What `--check-credits` found.
struct CreditsReport
{
    string[] problems;       /// unreadable inputs, stale readers, malformed parts
    ShippedToken[] uncredited; /// shipped, and no part provides it
    string[] unshipped;      /// part ids that provide nothing shipped
    string[] pageErrors;     /// pages that include the wrong set of parts
    size_t partCount;        /// parts read
    size_t tokenCount;       /// distinct tokens scanned

    /// True when the document and the build agree.
    bool ok() const @safe pure nothrow @nogc
        => problems.length == 0 && uncredited.length == 0
            && unshipped.length == 0 && pageErrors.length == 0;
}

/// The part ids a page includes (`./parts/<id>.md`), in order.
string[] includedParts(string page) @safe
    => includeTargets(page)
        .filter!(t => t.startsWith("./parts/") || t.startsWith("parts/"))
        .map!(t => t.baseName.stripExtension)
        .array;

/++
Checks the credits document against the build inputs.

`parts` maps a part id to its text; `pages` maps a page stem (`index`, or an
application name) to its text.
+/
CreditsReport checkCredits(scope FileReader read, in string[string] parts,
    in string[string] pages) @safe
{
    CreditsReport report;
    const shipped = scanShipped(read, report.problems);

    CreditPart[] parsed;
    foreach (id; parts.keys.sort)
    {
        auto part = parsePart(id, parts[id]);
        foreach (e; part.errors)
            report.problems ~= partsDir ~ "/" ~ id ~ ".md: " ~ e;
        parsed ~= part;
    }
    report.partCount = parsed.length;
    report.tokenCount = shipped.map!(s => s.token[]).array.sort.uniq.array.length;

    bool answers(ref const CreditPart p, string token)
        => p.provides.any!(pattern => tokenMatches(token, pattern));

    string[] reported;
    foreach (s; shipped)
        if (!parsed.any!(p => answers(p, s.token)) && !reported.canFind(s.token))
        {
            report.uncredited ~= s;
            reported ~= s.token;
        }

    foreach (p; parsed)
        if (!shipped.any!(s => answers(p, s.token)))
            report.unshipped ~= p.id;

    void comparePage(string stem, string[] expected)
    {
        const page = stem in pages;
        if (page is null)
        {
            report.pageErrors ~= creditsDir ~ "/" ~ stem ~ ".md does not exist";
            return;
        }
        const included = includedParts(*page);
        foreach (id; included)
            if (!(id in parts))
                report.pageErrors ~= creditsDir ~ "/" ~ stem ~ ".md includes parts/"
                    ~ id ~ ".md, which does not exist";
        foreach (id; expected)
            if (!included.canFind(id))
                report.pageErrors ~= creditsDir ~ "/" ~ stem ~ ".md does not include parts/"
                    ~ id ~ ".md";
        foreach (id; included)
            if ((id in parts) && !expected.canFind(id))
                report.pageErrors ~= creditsDir ~ "/" ~ stem ~ ".md includes parts/"
                    ~ id ~ ".md, which " ~ stem ~ " does not ship";
        foreach (i, id; included)
            if (included[0 .. i].canFind(id))
                report.pageErrors ~= creditsDir ~ "/" ~ stem ~ ".md includes parts/"
                    ~ id ~ ".md twice";
    }

    comparePage("index", parsed.map!(p => p.id).array);
    foreach (app; creditedApps)
        comparePage(app.name, parsed
            .filter!(p => shipped.any!(s => s.app == app.name && answers(p, s.token)))
            .map!(p => p.id)
            .array);
    return report;
}

version (unittest)
{
    private enum fixtureLock = `{"dependencies": {"bolts": {}}}`;
    private enum fixtureFonts = "cp ${pkgs.dejavu_fonts}/share/fonts/truetype/$f $out/\n";
    private enum fixtureApk = `"${config.packages.raylib-android}/lib/${abi}/libraylib.a"`
        ~ "\ncp -rL ${fonts.fontBundle}/fonts $out/fonts\n";

    private string[string] fixtureTree() @safe pure
    {
        return [
            dubLockPath: fixtureLock,
            fontBundlePath: fixtureFonts,
            "apps/terminal/dub.sdl": `dependency "sparkles:base" path="../.."`,
            "libs/base/dub.sdl": `dependency "bolts" version="~>1.3"` ~ "\n"
                ~ `libs "raylib"`,
            "apps/hue/dub.sdl": `dependency "sparkles:base" path="../.."`,
            "nix/packages/android/terminal.nix": fixtureApk,
            "nix/packages/android/hue.nix": fixtureApk,
            "nix/packages/hue.nix": "",
        ];
    }

    private string fixturePart(string name, string source, string ships) @safe pure
    {
        return "### " ~ name ~ "\n\n| Field | Value |\n| - | - |\n"
            ~ "| Version source | " ~ source ~ " |\n| Licence | `MIT` |\n"
            ~ "| Home | https://example.org |\n| Ships as | " ~ ships ~ " |\n\n"
            ~ "<!-- @include: ../licenses/" ~ name ~ "/LICENSE -->\n";
    }

    private string[string] fixtureParts() @safe
    {
        return [
            "bolts": fixturePart("bolts", "dub package `bolts`", ""),
            "raylib": fixturePart("raylib", "nixpkgs `raylib`", "`libraylib.a`, `-lraylib`"),
            "dejavu": fixturePart("dejavu", "nixpkgs `dejavu_fonts`", "`pkgs.dejavu_fonts`"),
        ];
    }

    private enum allParts = "<!-- @include: ./parts/bolts.md -->\n"
        ~ "<!-- @include: ./parts/dejavu.md -->\n<!-- @include: ./parts/raylib.md -->\n";
}

@("credits.checkCredits.cleanWhenTheDocumentMatchesTheBuild")
@safe unittest
{
    const tree = fixtureTree();
    const report = checkCredits((p) => p in tree ? tree[p] : null, fixtureParts(),
        ["index": allParts, "terminal": allParts, "hue": allParts]);
    assert(report.ok, report.problems.join("; ") ~ report.pageErrors.join("; "));
}

@("credits.checkCredits.failsOnARemovedPart")
@safe unittest
{
    const tree = fixtureTree();
    auto parts = fixtureParts();
    parts.remove("raylib");
    const report = checkCredits((p) => p in tree ? tree[p] : null, parts,
        ["index": allParts, "terminal": allParts, "hue": allParts]);
    assert(!report.ok);
    assert(report.uncredited.map!(s => s.token[]).array.sort.uniq.array
        == ["-lraylib", "libraylib.a"]);
    // The pages still include it, so they are wrong too.
    assert(report.pageErrors.canFind!(e => e.canFind("raylib.md, which does not exist")));
}

@("credits.checkCredits.failsOnAPartNothingShips")
@safe unittest
{
    const tree = fixtureTree();
    auto parts = fixtureParts();
    parts["glfw"] = fixturePart("glfw", "nixpkgs `glfw`", "`-lglfw`");
    const report = checkCredits((p) => p in tree ? tree[p] : null, parts,
        [
            "index": allParts ~ "<!-- @include: ./parts/glfw.md -->\n",
            "terminal": allParts, "hue": allParts,
        ]);
    assert(report.unshipped == ["glfw"]);
}

@("credits.checkCredits.pagesIncludeWhatTheirAppShips")
@safe unittest
{
    auto tree = fixtureTree();
    // hue bundles no fonts here, so its page must not credit DejaVu.
    tree["nix/packages/android/hue.nix"] =
        `"${config.packages.raylib-android}/lib/${abi}/libraylib.a"`;
    const report = checkCredits((p) => p in tree ? tree[p] : null, fixtureParts(),
        [
            "index": allParts, "terminal": "<!-- @include: ./parts/raylib.md -->\n",
            "hue": allParts,
        ]);
    assert(report.pageErrors.canFind(
        "docs/credits/terminal.md does not include parts/bolts.md"));
    assert(report.pageErrors.canFind(
        "docs/credits/hue.md includes parts/dejavu.md, which hue does not ship"));
}
