/** The SDL recipe a D single-file package embeds (editing SDE7).

DUB reads a single-file package's recipe from a leading `/+ dub.sdl: … +/`
comment — after an optional `#!` line — and ends it at the first `+/`. This
module is the one place that locates such a recipe, renders the host for
parsing, and parses it, so every tool reads embedded recipes the same way.

The rendering has the host's length and keeps every logical newline sequence
byte for byte, blanking every other byte outside the recipe to a space, so a
document parsed from it reports the host's own offsets, lines and columns, and
an edit to the document applies to the host unchanged.
*/
module sparkles.wired.sdl.embedded;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;
import std.range.primitives : put;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.readers : skipWhile, tryConsume;
import sparkles.wired.sdl.config : SdlParserConfig, sdlDubRecipe;
import sparkles.wired.sdl.document : SdlSpan;
import sparkles.wired.sdl.reader : parseSdlDocumentIn, SdlParseResult;

/// Where a host's embedded recipe is, from $(LREF locateEmbeddedRecipe).
struct SdlEmbeddedRecipe
{
    /// The recipe's bytes: after `dub.sdl:` (or `dub.json:`), up to the
    /// first `+/`; invalid when not `found`.
    SdlSpan content;
    /// The `+/` that ends it; invalid when not `found`.
    SdlSpan close;
    bool isJson; /// The comment is `/+ dub.json: … +/`.
    bool found;  /// The host opens with a closed recipe comment.

    /// The recipe text of `host`, which this was located in.
    const(char)[] recipe(return scope const(char)[] host) const @safe pure nothrow @nogc
        => found ? content.sliceOf(host) : null;
}

/** The offset just past a recipe header — `/+`, spaces, then `dub.sdl:` or
`dub.json:` — at the start of `host`, after an optional `#!` line; `size_t.max`
when there is none. `isJson` reports which. Reads only the header, so a caller
may pass the first few kilobytes of a file. */
size_t embeddedRecipeHeaderEnd(scope const(char)[] host, out bool isJson)
    @safe pure nothrow @nogc
{
    static bool isSpace(char c) => c == ' ' || c == '\t' || c == '\n' || c == '\r';

    const(char)[] rest = host;
    if (tryConsume(rest, "#!"))
    {
        skipWhile!(c => c != '\n')(rest);
        tryConsume(rest, '\n');
    }
    skipWhile!isSpace(rest);
    if (!tryConsume(rest, "/+"))
        return size_t.max;
    skipWhile!isSpace(rest);
    if (tryConsume(rest, "dub.json:"))
        isJson = true;
    else if (!tryConsume(rest, "dub.sdl:"))
        return size_t.max;
    return host.length - rest.length;
}

/// Whether `head` — a whole host or its first bytes — opens with an
/// embedded `dub.sdl` or `dub.json` recipe header.
bool hasEmbeddedRecipeHeader(scope const(char)[] head) @safe pure nothrow @nogc
{
    bool isJson;
    return embeddedRecipeHeaderEnd(head, isJson) != size_t.max;
}

/// Locates the recipe in `host`'s leading `/+ dub.sdl: … +/` (or `dub.json`)
/// comment; DUB ends it at the first `+/`, and so does this.
SdlEmbeddedRecipe locateEmbeddedRecipe(scope const(char)[] host) @safe pure nothrow @nogc
{
    bool isJson;
    const start = embeddedRecipeHeaderEnd(host, isJson);
    if (start == size_t.max || host.length >= uint.max)
        return SdlEmbeddedRecipe.init;
    foreach (i; start .. host.length ? host.length - 1 : 0)
        if (host[i] == '+' && host[i + 1] == '/')
            return SdlEmbeddedRecipe(content: SdlSpan(start, i), close: SdlSpan(i, i + 2),
                isJson: isJson, found: true);
    return SdlEmbeddedRecipe.init;
}

/** The length of the logical newline sequence at `host[at]` — `\n`, `\r`,
`\r\n`, U+2028 or U+2029 — or `0`. */
package size_t newlineWidthAt(scope const(char)[] host, size_t at) @safe pure nothrow @nogc
{
    if (at >= host.length)
        return 0;
    if (host[at] == '\n')
        return 1;
    if (host[at] == '\r')
        return at + 1 < host.length && host[at + 1] == '\n' ? 2 : 1;
    if (at + 2 < host.length && cast(ubyte) host[at] == 0xE2 && cast(ubyte) host[at + 1] == 0x80
        && (cast(ubyte) host[at + 2] == 0xA8 || cast(ubyte) host[at + 2] == 0xA9))
        return 3;
    return 0;
}

/** Writes the parse rendering of `host` for `recipe`: `host`'s length, the
recipe's bytes unchanged, every logical newline sequence outside it kept byte
for byte, and every other byte blanked to a space. */
void writeEmbeddedRendering(Writer)(ref Writer writer, scope const(char)[] host,
    in SdlEmbeddedRecipe recipe)
in (recipe.found, "no embedded recipe to render")
{
    void blank(size_t from, size_t to)
    {
        size_t at = from;
        while (at < to)
        {
            const width = newlineWidthAt(host, at);
            if (width && at + width <= to)
            {
                put(writer, host[at .. at + width]);
                at += width;
                continue;
            }
            const char[1] space = ' ';
            put(writer, space[]);
            at++;
        }
    }

    blank(0, recipe.content.startOffset);
    put(writer, recipe.content.sliceOf(host));
    blank(recipe.content.endOffset, host.length);
}

/// Whether `rendering` is $(LREF writeEmbeddedRendering)'s output for
/// `host` and `recipe`, compared without building it.
package bool isEmbeddedRendering(scope const(char)[] rendering, scope const(char)[] host,
    in SdlEmbeddedRecipe recipe) @safe pure nothrow @nogc
{
    if (!recipe.found || rendering.length != host.length)
        return false;
    size_t at;
    while (at < host.length)
    {
        if (at >= recipe.content.startOffset && at < recipe.content.endOffset)
        {
            if (rendering[at] != host[at])
                return false;
            at++;
            continue;
        }
        const width = newlineWidthAt(host, at);
        const end = recipe.content.startOffset > at ? recipe.content.startOffset : host.length;
        if (width && at + width <= end)
        {
            if (rendering[at .. at + width] != host[at .. at + width])
                return false;
            at += width;
            continue;
        }
        if (rendering[at] != ' ')
            return false;
        at++;
    }
    return true;
}

/// The result of $(LREF parseEmbeddedSdlDocument): the located recipe and,
/// when it was found, its parse.
struct SdlEmbeddedParse(Allocator = Mallocator)
{
    SdlEmbeddedRecipe recipe; /// Where the recipe is; `found` is false when absent.
    SdlParseResult!Allocator parsed; /// Meaningful only when `recipe.found`.
}

/** Parses the SDL recipe `host` embeds, reporting `host`'s own offsets,
lines and columns; node extents stay inside the recipe. A JSON recipe is
located but not parsed. */
SdlEmbeddedParse!Allocator parseEmbeddedSdlDocument(
    SdlParserConfig config = sdlDubRecipe, Allocator = Mallocator)(
    scope const(char)[] host, scope const(char)[] sourceName = null)
if (stateSize!Allocator == 0)
{
    SdlEmbeddedParse!Allocator result;
    result.recipe = locateEmbeddedRecipe(host);
    if (!result.recipe.found || result.recipe.isJson)
        return result;
    UniqueBuffer!char rendering;
    rendering.reserve(host.length);
    writeEmbeddedRendering(rendering, host, result.recipe);
    result.parsed = parseSdlDocumentIn!(config, Allocator)(rendering[], sourceName,
        result.recipe.content);
    return result;
}

@("sdl.embedded.locateEmbeddedRecipe.shapes")
@safe pure nothrow @nogc
unittest
{
    const host = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"s\"\n+/\nvoid main() {}\n";
    const recipe = locateEmbeddedRecipe(host);
    assert(recipe.found && !recipe.isJson);
    assert(recipe.recipe(host) == "\n    name \"s\"\n");
    assert(recipe.close.sliceOf(host) == "+/");

    assert(locateEmbeddedRecipe("/+dub.json: {} +/").isJson);
    assert(!locateEmbeddedRecipe("module m;\n/+ dub.sdl: +/").found);
    assert(!locateEmbeddedRecipe("/+ dub.sdl: name \"x\"").found);
    // DUB stops at the first `+/`, even inside a nested `/+ +/`.
    const nested = "/+ dub.sdl: name \"a\" /+ x +/ +/";
    assert(locateEmbeddedRecipe(nested).recipe(nested) == " name \"a\" /+ x ");

    assert(hasEmbeddedRecipeHeader("#!/bin/dub\n\n/+  dub.sdl:"));
    assert(!hasEmbeddedRecipeHeader("// dub.sdl:"));
}

@("sdl.embedded.writeEmbeddedRendering.keepsEveryNewline")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkWriter;

    const host = "#!x\r\n/+ dub.sdl:  name \"s\"\r+/ é\n";
    const recipe = locateEmbeddedRecipe(host);
    assert(recipe.found);
    checkWriter!((ref w) => writeEmbeddedRendering(w, host, recipe))(
        "   \r\n             name \"s\"\r     \n");
    UniqueBuffer!char rendering;
    writeEmbeddedRendering(rendering, host, recipe);
    assert(rendering.length == host.length);
    assert(isEmbeddedRendering(rendering[], host, recipe));
    assert(!isEmbeddedRendering(host, host, recipe));
}

@("sdl.embedded.parseEmbeddedSdlDocument.hostPositions")
@safe unittest
{
    // Lines: `#!x`, an empty line ended by a lone CR, the header, then
    // U+2028 starts `name`, and `bad =` is line 5.
    const host = "#!x\n\r/+ dub.sdl:  name \"s\"\n bad =\n+/\nvoid main() {}\n";
    auto result = parseEmbeddedSdlDocument(host, "x.d");
    assert(result.recipe.found && result.parsed.hasError);
    assert(result.parsed.error.startPosition.line == 5);

    auto good = parseEmbeddedSdlDocument("/+ dub.sdl: name \"s\" +/\n");
    assert(good.parsed.hasValue);
    const node = good.parsed.document.root.byChild.front;
    assert(node.extent.startOffset >= good.recipe.content.startOffset);
    assert(node.extent.endOffset <= good.recipe.content.endOffset);
}
