/**
The PNG decoder (`sparkles.image.png`) against stb_image, which raylib
links: PngSuite and libpng's test images, decoded both ways, byte for byte.
stb_image is the oracle because it is what the raylib arm decoded kitty
graphics with before the toolkit had a decoder of its own; the two must
agree on every file both read.
*/
module sparkles.ui_raylib.png_oracle;

version (unittest):

import std.algorithm : endsWith, filter, map, sort;
import std.array : array;
import std.file : dirEntries, exists, read, SpanMode;
import std.format : format;
import std.path : baseName, buildPath;
import std.process : environment;

import raylib : Image, ImageFormat, LoadImageFromMemory, PixelFormat, UnloadImage;

import sparkles.image.png : decodePngAlloc;

// The corpus: libpng's sources, a flake input the dev shell exports.
private string corpusRoot() @safe
{
    const root = environment.get("SPARKLES_FLAKE_INPUT_LIBPNG_SRC");
    assert(root !is null, "SPARKLES_FLAKE_INPUT_LIBPNG_SRC is unset: run inside `nix develop`");
    assert(root.buildPath("contrib/pngsuite").exists, root ~ " has no contrib/pngsuite");
    return root;
}

private string[] pngsIn(string dir) @safe
    => dir.exists ? dirEntries(dir, SpanMode.shallow).map!(e => e.name)
        .filter!(n => n.endsWith(".png")).array.sort.release : null;

// stb_image's RGBA, through raylib, or `null` where it refuses the file.
private ubyte[] stbDecode(in ubyte[] data, out int w, out int h) @trusted
{
    Image img = LoadImageFromMemory(".png", data.ptr, cast(int) data.length);
    if (img.data is null)
        return null;
    scope (exit)
        UnloadImage(img);
    ImageFormat(&img, PixelFormat.PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    w = img.width;
    h = img.height;
    return (cast(ubyte*) img.data)[0 .. size_t(w) * h * 4].dup;
}

@("ui_raylib.png_oracle.decodesAsStbImageDoes")
@system unittest
{
    import raylib : SetTraceLogLevel, TraceLogLevel;

    SetTraceLogLevel(TraceLogLevel.LOG_WARNING);
    const root = corpusRoot();
    string[] files = pngsIn(root.buildPath("contrib/pngsuite"))
        ~ pngsIn(root.buildPath("contrib/pngsuite/interlaced"))
        ~ pngsIn(root.buildPath("contrib/testpngs"));
    assert(files.length > 150, format("only %s corpus files", files.length));

    string[] differ;
    size_t agreed, bothRefused;
    foreach (f; files)
    {
        const data = cast(const(ubyte)[]) read(f);
        int sw, sh;
        const theirs = stbDecode(data, sw, sh);
        const decoded = decodePngAlloc(data);
        const ours = decoded.hasValue ? decoded.value.rgba : null;
        const w = decoded.hasValue ? decoded.value.width : 0, h = decoded.hasValue ? decoded.value.height : 0;
        if (theirs is null && ours is null)
            ++bothRefused;
        else if (theirs is null || ours is null)
            differ ~= format("%s: %s", f.baseName, theirs is null ? "only ours decodes"
                : "only stb_image decodes");
        else if (w != sw || h != sh || ours != theirs)
        {
            size_t at;
            while (at < ours.length && at < theirs.length && ours[at] == theirs[at])
                ++at;
            differ ~= format("%s: first difference at byte %s (%s×%s)", f.baseName, at, w, h);
        }
        else
            ++agreed;
    }
    assert(!differ.length, format("%s of %s files differ:\n%-(%s\n%)", differ.length,
        files.length, differ));
    assert(agreed > 140, format("only %s agreed (%s both refused)", agreed, bothRefused));
}

@("ui_raylib.png_oracle.hostileFilesNeverCrash")
@system unittest
{
    // libpng's crashers and bad palettes: refused or decoded, never a crash.
    const root = corpusRoot();
    foreach (f; pngsIn(root.buildPath("contrib/testpngs/crashers"))
            ~ pngsIn(root.buildPath("contrib/testpngs/badpal")))
    {
        cast(void) decodePngAlloc(cast(const(ubyte)[]) read(f));
    }
}
