/**
Which font files a request names, without loading any: the cell face a
family or path resolves to, and the faces text falls back to where it has no
glyph. Raylib-free, so a canvas that draws with another renderer — the
Vulkan arm, on the desktop or on Android — resolves the same faces the
raylib arm's $(REF FontSet, sparkles,raylib_text,font_set) loads.
*/
module sparkles.raylib_text.font_resolve;

import std.algorithm.searching : canFind, endsWith;
import std.string : strip;

import sparkles.raylib_text.font_discovery : FontSources, fallbackFacePaths, resolveFontInDirs;
// The two system font databases, behind one seam. Which one `useSystemFontDb`
// means is a platform fact, decided once here rather than at each call site.
import sparkles.raylib_text.font_fontconfig : fcRun;
version (OSX)
    import sparkles.raylib_text.font_coretext : fallbackFaces, resolveFamilyList;

/**
The font file `nameOrPath` names: itself when it is an existing path; else
the system font database's best match for the family or preference list
(fontconfig, or Core Text on macOS), or the best match among `sources.dirs`
when the request names its own directories. Empty when nothing resolves.

Raylib-free, so a canvas that draws with another renderer resolves the same
face the raylib arm loads — the Vulkan arm sizes its cells from it.
*/
string resolveFontPath(string nameOrPath, FontSources sources = FontSources.init) @system
{
    import std.file : exists;

    string fontPath = nameOrPath;
    if (!fontPath.exists)
    {
        if (sources.useSystemFontDb)
        {
            version (OSX)
                fontPath = resolveFamilyList(nameOrPath);
            else
            {
                auto res = fcRun(["fc-match", "-f", "%{file}", nameOrPath]);
                fontPath = res.status == 0 ? res.output.strip.idup : null;
            }
        }
        else
            fontPath = resolveFontInDirs(nameOrPath, sources.dirs);
    }
    return fontPath.length && fontPath.exists ? fontPath : null;
}

/**
The faces text falls back to where the cell font at `primaryPath` has no
glyph, found as `FontSet` finds them: from the system font database —
fontconfig's `monospace` order, its first Nerd Font and its first common
monospace face, or Core Text's on macOS — or, when the request names its
own directories, the best of `sources.dirs` (`fallbackFacePaths`). With
them a colour emoji face: fontconfig's, or the directories'. Empty where
there is none; `primaryPath` is never its own fallback.

Raylib-free, like `resolveFontPath`, so every arm falls back to the same faces.
*/
void systemFallbackFacePaths(string primaryPath, FontSources sources, out string nerd,
    out string regular, out string emoji) @system
{
    if (!sources.useSystemFontDb)
        return fallbackFacePaths(primaryPath, sources.dirs, nerd, regular, emoji);
    version (OSX)
    {
        // The `fc-match monospace -s` analog, over Core Text's family
        // enumeration. Apple Color Emoji is a collection, which is skipped.
        fallbackFaces(primaryPath, nerd, regular);
    }
    else
    {
        import std.string : splitLines;

        auto fbRes = fcRun(["fc-match", "-f", "%{file}\\n", "monospace", "-s"]);
        if (fbRes.status == 0)
        {
            foreach (line; fbRes.output.splitLines)
            {
                string path = line.strip.idup;
                if (path.length == 0 || path == primaryPath)
                    continue;
                const isNerd = path.canFind("NerdFont") || path.canFind("Nerd Font");
                if (isNerd && nerd is null)
                    nerd = path;
                else if (!isNerd && regular is null
                    && (path.canFind("DejaVu") || path.canFind("FreeMono")
                        || path.canFind("LiberationMono")))
                    regular = path;
                if (nerd !is null && regular !is null)
                    break;
            }
        }
        auto emojiRes = fcRun(["fc-match", "-f", "%{file}", "emoji:color=true"]);
        const found = emojiRes.status == 0 ? emojiRes.output.strip.idup : null;
        if (found.canFind("Emoji") && !found.endsWith(".ttc"))
            emoji = found;
    }
}

/**
Resolves the interface family `family` to its regular and bold files, the way
`FontSet` resolves the cell font: through the system font database when
`sources` uses one (fontconfig, or CoreText on macOS, so `"sans-serif"` names
the desktop's own interface face), otherwise from `sources.dirs` (the bundled
fonts on Android). A path to a font file names that file, its bold the
sibling beside it. `bold` is `""` when the family has no bold file. Returns
whether a regular face was found.
*/
bool resolveUiFace(string family, in FontSources sources, out string regular,
    out string bold) @trusted
{
    import std.file : exists, isFile;
    import sparkles.raylib_text.font_discovery : fontVariantPaths;

    if (family.exists && family.isFile)
    {
        regular = family;
        string italic, boldItalic;
        fontVariantPaths(regular, bold, italic, boldItalic);
    }
    else if (sources.useSystemFontDb)
    {
        version (OSX)
        {
            regular = resolveFamilyList(family);
            bold = resolveFamilyList(family ~ " Bold");
        }
        else
        {
            auto r = fcRun(["fc-match", "-f", "%{file}", family]);
            if (r.status == 0)
                regular = r.output.strip.idup;
            auto b = fcRun(["fc-match", "-f", "%{file}", family ~ ":bold"]);
            if (b.status == 0)
                bold = b.output.strip.idup;
        }
        if (bold == regular)
            bold = "";
    }
    else
    {
        regular = resolveFontInDirs(family, sources.dirs);
        if (regular.length)
        {
            string italic, boldItalic;
            fontVariantPaths(regular, bold, italic, boldItalic);
        }
    }
    if (regular.length == 0 || !regular.exists)
    {
        regular = bold = "";
        return false;
    }
    return true;
}

version (RaylibTextTests)
@("raylib_text.font_resolve.resolveUiFace.bundledFamily")
@system unittest
{
    import std.path : baseName;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmp = TmpFS.create("sparkles-ui-face-test");
    foreach (f; ["Roboto-Regular.ttf", "Roboto-Bold.ttf", "FiraCodeNerdFontMono-Regular.ttf"])
        tmp.writeFileAt(f, "x");
    const sources = FontSources([tmp.dir], useSystemFontDb: false);

    string regular, bold;
    assert(resolveUiFace("Roboto", sources, regular, bold));
    assert(regular.baseName == "Roboto-Regular.ttf" && bold.baseName == "Roboto-Bold.ttf");

    assert(!resolveUiFace("Inter", sources, regular, bold), "a family the dirs lack");
    assert(regular == "" && bold == "");

    // A file names itself, whatever the sources; its bold is its sibling.
    const file = tmp.dir ~ "/Roboto-Regular.ttf";
    assert(resolveUiFace(file, FontSources.init, regular, bold));
    assert(regular == file && bold.baseName == "Roboto-Bold.ttf");
}
