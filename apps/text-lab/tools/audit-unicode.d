#!/usr/bin/env dub
/+ dub.sdl:
name "text-lab-audit-unicode"
targetPath "../../../build"
dependency "sparkles:font" path="../../.."
dflags "-I$PACKAGE_DIR/../src" "-i=unicode_samples"
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
+/
/** Audits the showcase's declared fallback sets against actual font cmaps. */
module audit_unicode;

import std.conv : to;
import std.exception : enforce;
import std.file : exists, read;
import std.path : buildPath;
import std.stdio : stderr, writeln, writefln;
import std.string : join;
import sparkles.font : charMap, CharMap, openFace;
import sparkles.base.text.unicode_tables : generalCategory;
import unicode_samples : showcaseFonts, unicodeSamples;

void main(string[] args)
{
    enforce(args.length == 2, "usage: audit-unicode.d <font-directory>");
    CharMap[] maps = new CharMap[showcaseFonts.length];
    bool[] loaded = new bool[showcaseFonts.length];
    const(ubyte)[][] retained;
    bool complete = true;
    foreach (i, font; showcaseFonts)
    {
        const path = buildPath(args[1], font.filename);
        if (!path.exists)
        {
            stderr.writeln("MISSING FONT: ", font.filename);
            complete = false;
            continue;
        }
        const bytes = cast(const(ubyte)[]) read(path);
        retained ~= bytes;
        const face = openFace(bytes, font.faceIndex);
        enforce(face.hasValue, "invalid font: " ~ path);
        const map = charMap(face.value);
        enforce(map.hasValue, "invalid cmap: " ~ path);
        maps[i] = map.value;
        loaded[i] = true;
    }
    writeln("group\tlabel\tplanes\tcategories\tmissing");
    foreach (sample; unicodeSamples)
    {
        uint planes;
        bool[string] categories;
        string[] missing;
        foreach (dchar cp; sample.text)
        {
            planes |= 1u << (cp >> 16);
            const category = generalCategory(cp).to!string;
            categories[category] = true;
            if (category == "Cf" || cp >= 0xFE00 && cp <= 0xFE0F
                    || cp >= 0xE0100 && cp <= 0xE01EF)
                continue;
            bool covered;
            foreach (i, font; showcaseFonts)
                if (loaded[i] && font.pages & (1u << cast(uint) sample.group))
                    covered |= maps[i].glyph(cp) != 0;
            if (!covered)
            {
                import std.format : format;
                missing ~= format("U+%04X", cp);
            }
        }
        string[] planeNames;
        foreach (plane; 0 .. 17) if (planes & (1u << plane)) planeNames ~= plane.to!string;
        writefln("%s\t%s\t%s\t%s\t%s", sample.group, sample.label,
            planeNames.join(","), categories.keys.join(","), missing.join(","));
        complete &= missing.length == 0;
    }
    enforce(complete, "showcase coverage is incomplete; see missing fonts/scalars above");
}
