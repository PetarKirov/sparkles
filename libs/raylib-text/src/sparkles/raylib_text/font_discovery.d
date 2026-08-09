/**
Font discovery without fontconfig: resolving a family name to a file, finding
its styled siblings, and reading a coverage sidecar — by looking at plain
directories.

$(B No raylib.) That is the point of the split. `font_set.d` needs a GL context
for everything it does, so `raylib-text/dub.sdl` states that only pure code
carries unittests and the rest is covered by the apps' screenshot goldens.
These helpers broke that split by living there: raylib-free, and the only half
under test (`IXR29`).

The strategy is selected by $(LREF FontSources). The desktop default shells out
to fontconfig; `useFontconfig: false` scans directories instead — which is what
Android needs (no fontconfig, no subprocesses) and what any portable or
deterministic build wants, since `fc-match`'s answer varies with the host's
configuration and costs up to six subprocesses at startup.

Promotion to a library of its own waits for a consumer outside `raylib-text`
(a software rasteriser, an sdl3_ttf path); `apps/terminal --font-dir` and the
Android build are both still inside it.
*/
module sparkles.raylib_text.font_discovery;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, endsWith;
import std.string : indexOf, strip, split, toLower;
import std.uni : icmp;

import sparkles.base.smallbuffer : SmallBuffer;

/**
Where face resolution looks for font files.

The default — no dirs, `useSystemFontDb: true` — asks the operating system's
own font database, which is a different subsystem on each platform and so a
different module: `fc-match`/`fc-query`/`fc-scan` subprocesses on Linux and the
BSDs, and CoreText
($(REF resolveFamilyList, sparkles,raylib_text,font_coretext)) on macOS, where
fontconfig is normally not installed at all.

With `useSystemFontDb: false` nothing outside `dirs` is consulted: names
resolve by scanning them in order ($(LREF resolveFontInDirs)), styled variants
by the sibling-file naming convention ($(LREF fontVariantPaths)), and coverage
from a `<font>.charset` sidecar (written at build time from
`fc-query --format=%{charset}`; without one, on-demand atlas growth is simply
disabled). That is what Android needs — no fontconfig, no subprocesses — and
what any portable or deterministic build wants, since a system font database's
answer varies with the host.

$(B The field is not named `useFontconfig` any more.) It was, and the name
quietly asserted that "ask the system" and "run fontconfig" are the same thing
— which is exactly the assumption that made every GUI arm die on macOS, where
the subprocess does not exist and `std.process.execute` throws rather than
reporting a status.
*/
struct FontSources
{
    string[] dirs;
    bool useSystemFontDb = true;
}

// The default is the entire guarantee that adding `FontSources` changed no
// desktop behaviour: every pre-existing caller passes fewer arguments and so
// gets `FontSources.init`. A one-character edit here would silently move them
// all onto the directory scanner, so it is pinned rather than trusted.
static assert(FontSources.init.useSystemFontDb && FontSources.init.dirs is null,
    "FontSources.init must stay the system-font-database path — it is what "
    ~ "every pre-existing tryLoad caller resolves to.");

/// Lowercase with spaces and dashes stripped — the normalization under which a
/// family name ("FiraCode Nerd Font Mono") matches a font file's basename
/// ("FiraCodeNerdFontMono-Regular").
private string normalizeFontName(scope const(char)[] s) @safe pure
{
    import std.ascii : toLower;
    import std.array : array;
    import std.utf : byChar;

    return s.byChar.filter!(c => c != ' ' && c != '-').map!(c => c.toLower).array.idup;
}

/// The `.ttf`/`.otf` files under `dirs` (shallow, sorted per dir for
/// determinism), scanned in order — earlier dirs win.
///
/// An unreadable or vanishing directory is skipped, not propagated:
/// `dirEntries` throws on a directory it cannot open, and `exists`/`isDir`
/// can race with it, so without the catch a font directory with the wrong
/// permissions would turn `FontSet.tryLoad` — documented to return `false`
/// when it cannot resolve a font — into a startup exception. (Collections,
/// `.ttc`, are excluded because raylib's `LoadFontEx` cannot load them.)
package string[] fontFilesInDirs(const(string)[] dirs) @safe
{
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.file : dirEntries, exists, isDir, SpanMode;
    import std.path : extension;

    string[] result;
    foreach (dir; dirs)
    {
        try
        {
            if (!dir.exists || !dir.isDir)
                continue;
            auto files = dirEntries(dir, SpanMode.shallow)
                .map!(e => e.name)
                .filter!((string p) {
                    const ext = p.extension.toLower;
                    return ext == ".ttf" || ext == ".otf";
                })
                .array;
            sort(files);
            result ~= files;
        }
        catch (Exception) { /* unreadable dir → skip it, keep the rest */ }
    }
    return result;
}

/**
Resolve a font family name — or a fontconfig-style comma-separated preference
list ("FiraCode Nerd Font Mono,JetBrains Mono,monospace") — against plain
directories of font files, without fontconfig. For each name in order, the
candidates are files whose normalized basename contains the normalized name;
among them the best-ranked wins ($(LREF faceRank)). Returns the first name's
winner, or `""` when nothing matches (generic aliases like "monospace" match
no file and simply fall through to the next name).

Ties keep the earlier candidate, so the caller's directory order is the
tie-breaker — `fontFilesInDirs` yields earlier directories first, which is
the precedence it documents. (Comparing paths lexicographically instead, as
this once did, silently handed the decision to whichever absolute path sorted
first: hue's `[<dataDir>/fonts, /system/fonts]` only worked because `/data`
happens to precede `/system`.)
*/
/// (Public deliberately: `apps/terminal --font-dir` resolves through it, so
/// this is API, not an implementation detail. Its siblings —
/// `fontVariantPaths`, `parseCharsetTokens` — stay private until something
/// outside the module asks for them.)
string resolveFontInDirs(const(char)[] nameOrList, const(string)[] dirs) @safe
{
    import std.path : baseName, stripExtension;

    const files = fontFilesInDirs(dirs);
    foreach (rawName; nameOrList.split(','))
    {
        const name = normalizeFontName(rawName.strip);
        if (name.length == 0)
            continue;

        string best;
        int bestRank = int.max;
        foreach (path; files)
        {
            const rank = faceRank(path, name);
            if (rank < bestRank)
            {
                best = path;
                bestRank = rank;
            }
        }
        if (best.length != 0)
            return best;
    }
    return "";
}

/// How well the font file at `path` answers to the normalized family
/// `name` — lower is better, `int.max` for "not a candidate at all":
/// an exact stem match, then an explicit `…-Regular` face, then a stem that
/// merely *starts* with the name, then any undecorated stem, then anything
/// containing it. `int.max` when the name does not appear.
///
/// The `startsWith` tier matters against a system font directory: plain
/// containment lets a short family name match a superset family (`"Mono"`
/// inside `MapleMono-Regular`), and with ~200 `Noto*` files on Android an
/// absent family would otherwise resolve to an arbitrary unrelated one.
package int faceRank(scope const(char)[] path, scope const(char)[] name) @safe
{
    import std.algorithm.searching : startsWith;
    import std.path : baseName, stripExtension;

    const stem = normalizeFontName(path.baseName.stripExtension);
    if (!stem.canFind(name))
        return int.max;
    if (stem == name)
        return 0;
    if (stem == name ~ "regular")
        return 1;
    const undecorated = isUndecoratedFace(path);
    if (stem.startsWith(name))
        return undecorated ? 2 : 4;
    return undecorated ? 3 : 5;
}

/// `true` when the file's stem names an explicit `Regular` face.
package bool isRegularFace(scope const(char)[] path) @safe
{
    import std.algorithm.searching : endsWith;
    import std.path : baseName, stripExtension;

    return normalizeFontName(path.baseName.stripExtension).endsWith("regular");
}

/// `true` when the file's stem carries no weight/slant decoration — the
/// closest thing to "the plain face" when no explicit Regular exists.
package bool isUndecoratedFace(scope const(char)[] path) @safe
{
    import std.path : baseName, stripExtension;

    const stem = normalizeFontName(path.baseName.stripExtension);
    return !stem.canFind("bold") && !stem.canFind("italic")
        && !stem.canFind("oblique");
}

// A collision-free scratch directory. The runner executes tests in parallel
// *threads*, which a fixed name survives — but two concurrent test
// *processes* (a CI matrix leg beside a local `dub test`, or a retried job)
// would share it, and one run's `rmdirRecurse` would delete the other's
// fixture mid-assert.
version (unittest)
private string uniqueTestDir(string stem) @safe
{
    import std.file : tempDir;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    return buildPath(tempDir, stem ~ "-" ~ randomUUID().toString());
}

@("resolveFontInDirs.preferenceListAndRanking")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-resolve-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    foreach (f; ["FiraCodeNerdFontMono-Regular.ttf", "FiraCodeNerdFontMono-Bold.ttf",
        "FiraCodeNerdFontMono-Italic.ttf", "DejaVuSansMono.ttf", "notafont.txt"])
        write(buildPath(dir, f), "x");

    // Preference list: first resolvable name wins; the -Regular face beats
    // the styled siblings; generic "monospace" matches nothing and falls
    // through.
    assert(resolveFontInDirs("monospace,FiraCode Nerd Font Mono", [dir])
        == buildPath(dir, "FiraCodeNerdFontMono-Regular.ttf"));
    // Exact stem match (no -Regular suffix on the file).
    assert(resolveFontInDirs("DejaVu Sans Mono", [dir])
        == buildPath(dir, "DejaVuSansMono.ttf"));
    // Unresolvable everything → "".
    assert(resolveFontInDirs("Comic Sans,monospace", [dir]) == "");
    // Non-font files are never candidates.
    assert(resolveFontInDirs("notafont", [dir]) == "");
    // Missing dirs are skipped, not errors.
    assert(resolveFontInDirs("DejaVu Sans Mono", [buildPath(dir, "absent"), dir])
        == buildPath(dir, "DejaVuSansMono.ttf"));
}

@("resolveFontInDirs.dirPrecedenceBeatsPathOrder")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    // Two directories holding the SAME family at the same rank. The caller's
    // order must decide — not which absolute path sorts first, which is what
    // a lexicographic tie-break did (hue passes [<dataDir>/fonts,
    // /system/fonts] and only worked because "/data" precedes "/system").
    const root = uniqueTestDir("sparkles-font-precedence-test");
    const zFirst = buildPath(root, "zzz");
    const aSecond = buildPath(root, "aaa");
    mkdirRecurse(zFirst);
    mkdirRecurse(aSecond);
    scope (exit) rmdirRecurse(root);
    write(buildPath(zFirst, "SomeMono-Regular.ttf"), "x");
    write(buildPath(aSecond, "SomeMono-Regular.ttf"), "x");

    // Listed first wins, despite sorting later.
    assert(resolveFontInDirs("SomeMono", [zFirst, aSecond])
        == buildPath(zFirst, "SomeMono-Regular.ttf"));
    // …and symmetrically.
    assert(resolveFontInDirs("SomeMono", [aSecond, zFirst])
        == buildPath(aSecond, "SomeMono-Regular.ttf"));
}

@("resolveFontInDirs.prefixBeatsInteriorMatch")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-prefix-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    // "Mono" appears inside MapleMono but at the START of MonoLisa.
    write(buildPath(dir, "MapleMono-Regular.ttf"), "x");
    write(buildPath(dir, "MonoLisa-Regular.ttf"), "x");

    // Without a startsWith tier both are rank-1 and the tie went to whichever
    // came first — an arbitrary family. This matters against /system/fonts,
    // where ~200 Noto* files make interior matches abundant.
    assert(resolveFontInDirs("Mono", [dir]) == buildPath(dir, "MonoLisa-Regular.ttf"));
    // An exact family still wins outright.
    assert(resolveFontInDirs("Maple Mono", [dir]) == buildPath(dir, "MapleMono-Regular.ttf"));
}

/**
The sibling-file naming convention that stands in for fc-scan: given the
primary face's path, the styled variants are `<Base>-Bold`, `-Italic` (or
`-Oblique`), and `-BoldItalic` (or `-BoldOblique`) next to it, where `<Base>`
is the primary's stem minus a trailing `-Regular`. Nerd-Font and DejaVu
releases both follow it. Out-params are `""` when the file does not exist.
*/
package void fontVariantPaths(string primaryPath,
    out string bold, out string italic, out string boldItalic) @safe
{
    import std.file : exists;
    import std.path : baseName, buildPath, dirName, extension, stripExtension;

    const dir = primaryPath.dirName;
    const ext = primaryPath.extension;
    string stem = primaryPath.baseName.stripExtension;
    // Compared in place rather than `stem.toLower.endsWith(...)`: that would
    // slice the ORIGINAL by the lowered string's length, and std.uni.toLower
    // is not length-preserving in general (U+0130 expands). Unreachable for
    // ASCII font names, but the assumption is free to remove.
    enum regularSuffix = "-Regular";
    if (stem.length >= regularSuffix.length
        && icmp(stem[$ - regularSuffix.length .. $], regularSuffix) == 0)
        stem = stem[0 .. $ - regularSuffix.length];

    string pick(scope string[] suffixes...) @safe
    {
        foreach (s; suffixes)
        {
            const p = buildPath(dir, stem ~ s ~ ext);
            if (p.exists)
                return p;
        }
        return "";
    }

    bold = pick("-Bold");
    italic = pick("-Italic", "-Oblique");
    boldItalic = pick("-BoldItalic", "-BoldOblique");
}

@("fontVariantPaths.namingConvention")
@system unittest
{
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;

    const dir = uniqueTestDir("sparkles-font-variant-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    foreach (f; ["Mono-Regular.ttf", "Mono-Bold.ttf", "Mono-BoldOblique.ttf",
        "Solo.otf", "Solo-Italic.otf"])
        write(buildPath(dir, f), "x");

    string b, i, bi;
    // -Regular stem: bold present, italic absent, bold-italic via -BoldOblique.
    fontVariantPaths(buildPath(dir, "Mono-Regular.ttf"), b, i, bi);
    assert(b == buildPath(dir, "Mono-Bold.ttf"));
    assert(i == "");
    assert(bi == buildPath(dir, "Mono-BoldOblique.ttf"));
    // Bare stem (no -Regular), .otf, only italic present.
    fontVariantPaths(buildPath(dir, "Solo.otf"), b, i, bi);
    assert(b == "");
    assert(i == buildPath(dir, "Solo-Italic.otf"));
    assert(bi == "");
}

/// Parse fontconfig charset syntax (space-separated `lo-hi` hex ranges and
/// bare hex singletons — `fc-query --format=%{charset}` output, also the
/// `<font>.charset` sidecar format) into the sorted lo/hi bound buffers.
/// Malformed tokens are skipped, the rest kept.
package void parseCharsetTokens(const(char)[] text,
    ref SmallBuffer!(int, 256, true) lo, ref SmallBuffer!(int, 256, true) hi) @safe
{
    import std.conv : to;

    foreach (tok; text.strip.split)
    {
        if (tok.length == 0)
            continue;
        const dash = tok.indexOf('-');
        try
        {
            if (dash < 0)
            {
                const v = tok.to!int(16);
                lo ~= v;
                hi ~= v;
            }
            else
            {
                lo ~= tok[0 .. dash].to!int(16);
                hi ~= tok[dash + 1 .. $].to!int(16);
            }
        }
        catch (Exception) { /* skip a malformed token, keep the rest */ }
    }
}

@("parseCharsetTokens.rangesSingletonsMalformed")
@safe unittest
{
    SmallBuffer!(int, 256, true) lo, hi;
    parseCharsetTokens("20-7e a0 100-17f zz 1f600-1f64f", lo, hi);
    assert(lo[] == [0x20, 0xa0, 0x100, 0x1f600]);
    assert(hi[] == [0x7e, 0xa0, 0x17f, 0x1f64f]);

    SmallBuffer!(int, 256, true) lo2, hi2;
    parseCharsetTokens("", lo2, hi2);
    assert(lo2.length == 0 && hi2.length == 0);
}
