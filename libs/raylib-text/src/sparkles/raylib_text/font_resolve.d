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
