/**
What the viewer can show of a file, decided before opening it (terminal
`TDV1`): an open request for a kind the viewer supports opens in the
application, anything else keeps the platform's handler.

The kinds are the loader's (`DocumentPipeline.detect`) plus images. Source
is decided by its bytes, not its extension: valid UTF-8 without NUL bytes in
the first 4 KiB opens (highlighted when a grammar knows the language);
anything else is binary, and unsupported.
*/
module sparkles.doc_view.kind;

import std.algorithm.searching : canFind, endsWith;
import std.path : extension;
import std.string : chompPrefix, toLower;

/// The viewer's content kinds.
enum ViewKind : ubyte
{
    unsupported, /// a binary file, or an image format the backend cannot decode
    code,        /// source in a language the highlighter knows
    markdown,    /// the decorated markdown preview
    dsv,         /// delimiter-separated values, as a grid
    diff,        /// a unified diff
    twoslash,    /// a twoslash payload
    text,        /// plain text
    image,       /// a raster image
}

/// The image extensions the GPU pane decodes (raylib's default formats).
immutable string[] imageExtensions = ["png", "gif", "qoi"];

/// The kind `path` would open as by its name alone; `unsupported` means
/// "decide by sniffing the file" for an unknown extension.
ViewKind viewKindOfName(string path) @safe
{
    import sparkles.syntax : canonicalLanguageOfPath;

    const ext = path.extension.chompPrefix(".").toLower;
    if (ext == "txt" || ext == "text" || ext == "log")
        return ViewKind.text;
    if (imageExtensions.canFind(ext))
        return ViewKind.image;
    if (path.endsWith(".twoslash.json"))
        return ViewKind.twoslash;
    if (ext == "patch" || ext == "diff")
        return ViewKind.diff;
    if (ext == "csv" || ext == "tsv" || ext == "psv" || ext == "ssv")
        return ViewKind.dsv;
    const lang = canonicalLanguageOfPath(path);
    if (lang == "markdown")
        return ViewKind.markdown;
    return ViewKind.unsupported;
}

/**
The kind `path` opens as: by name, else by sniffing its first bytes. A path
that cannot be read is `unsupported` (the caller reports why).
*/
ViewKind viewKindOf(string path) @system
{
    const byName = viewKindOfName(path);
    if (byName != ViewKind.unsupported)
        return byName;
    if (path.endsWith(".md") || path.endsWith(".markdown"))
        return ViewKind.markdown;
    try
        return looksLikeText(headOf(path)) ? ViewKind.code : ViewKind.unsupported;
    catch (Exception)
        return ViewKind.unsupported;
}

/// Whether `head` reads as text: no NUL, valid UTF-8 (a code point cut at the
/// end of the sample is allowed).
bool looksLikeText(scope const(ubyte)[] head) @safe pure nothrow @nogc
{
    import sparkles.base.text.utf8 : indexOfInvalidUtf8;

    foreach (b; head)
        if (b == 0)
            return false;
    const bad = indexOfInvalidUtf8(cast(const(char)[]) head);
    return bad == head.length || head.length - bad < 4;
}

private ubyte[] headOf(string path) @system
{
    import std.stdio : File;

    auto f = File(path, "rb");
    ubyte[4096] buf;
    return f.rawRead(buf[]).dup;
}

@("kind.viewKindOfName.byExtension")
@safe unittest
{
    assert(viewKindOfName("a/README.md") == ViewKind.markdown);
    // Source is decided by its bytes: any text file opens, highlighted when
    // a grammar knows its language.
    assert(viewKindOfName("x.d") == ViewKind.unsupported);
    assert(viewKindOfName("data.csv") == ViewKind.dsv);
    assert(viewKindOfName("pic.PNG") == ViewKind.image);
    assert(viewKindOfName("fix.patch") == ViewKind.diff);
    assert(viewKindOfName("notes.txt") == ViewKind.text);
    assert(viewKindOfName("photo.heic") == ViewKind.unsupported);
}

@("kind.looksLikeText.sniff")
@safe pure nothrow @nogc unittest
{
    assert(looksLikeText(cast(const(ubyte)[]) "plain\ntext\n"));
    assert(looksLikeText(cast(const(ubyte)[]) "caf\xc3\xa9"));
    assert(!looksLikeText(cast(const(ubyte)[]) "ELF\x00\x01"));
    assert(!looksLikeText(cast(const(ubyte)[]) "\xff\xfe binary \xff\xfe"));
}
