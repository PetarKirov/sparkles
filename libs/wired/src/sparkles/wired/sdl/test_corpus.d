/** The repository's recipes as a test corpus, for the editing property tests
(editing SDE1, SDE2, SDE11, SDE14), and a counting allocator for the
allocation tests.

Every function is a template, so nothing here is compiled into a build that
does not call it.
*/
module sparkles.wired.sdl.test_corpus;

/// Every `dub.sdl` and every embedded recipe under `apps`, `libs` and `docs`.
package string[] repositoryRecipes()()
{
    import sparkles.wired.sdl.embedded : hasEmbeddedRecipeHeader;
    import std.algorithm.comparison : among;
    import std.algorithm.searching : canFind;
    import std.file : dirEntries, exists, readText, SpanMode;
    import std.path : baseName, buildNormalizedPath, dirName, extension, pathSplitter;

    const root = buildNormalizedPath(__FILE_FULL_PATH__.dirName, "../../../../../..");
    string[] paths;
    foreach (top; ["apps", "libs", "docs"])
    {
        const dir = buildNormalizedPath(root, top);
        if (!dir.exists)
            continue;
        foreach (entry; dirEntries(dir, SpanMode.depth))
        {
            // Components, not `/`-joined text: Windows separates with `\`.
            const path = entry.name;
            if (!entry.isFile
                || path.pathSplitter.canFind!(part => part.among(".dub", "node_modules", "build")))
                continue;
            if (path.baseName == "dub.sdl"
                || (path.extension == ".d" && hasEmbeddedRecipeHeader(readText(path))))
                paths ~= path;
        }
    }
    return paths;
}

/// Parses a recipe file, or the recipe a `.d` file embeds.
package auto parseRecipe()(scope const(char)[] text, string path)
{
    import core.lifetime : move;
    import sparkles.wired.sdl.config : sdlDubRecipe;
    import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;
    import sparkles.wired.sdl.reader : parseSdlDocument;

    if (path[$ - 2 .. $] != ".d")
        return parseSdlDocument!sdlDubRecipe(text, path);
    auto embedded = parseEmbeddedSdlDocument!sdlDubRecipe(text, path);
    return move(embedded.parsed);
}

/** The first difference between two parsed documents, field by field — the
SDE14 oracle — or `null` when they are equal: the source, the content, every
cell's name, spans, layout and links, every value and attribute with its
payload, the comments and the line table. Each document's names and payloads
must also lie in its own source and pool, so a splice that borrows from the
document it was made from is caught. */
package string documentDifference(A, B)(ref const A a, ref const B b) @system
{
    import std.conv : to;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.wired.sdl.document : SdlCore, SdlScalar, SdlScalarKind;
    import sparkles.wired.sdl.writer : writeSdlScalar;

    static string spelled(in SdlScalar s)
    {
        UniqueBuffer!char text;
        if (writeSdlScalar(s, text).hasError)
            return "<unwritable>";
        return text[].idup ~ "@" ~ s.span.startOffset.to!string ~ ".." ~ s.span.endOffset.to!string
            ~ (s.kind == SdlScalarKind.zonedDateTime ? "|" ~ s.zonedDateTime.zone.idup : "");
    }

    static bool within(scope const(void)[] slice, scope const(void)[] owner)
        => slice.length == 0
            || (slice.ptr >= owner.ptr && slice.ptr + slice.length <= owner.ptr + owner.length);

    static string owned(D)(ref const D d)
    {
        const core = d.core;
        foreach (i, ref node; core.nodes)
            if (!within(node.qualifiedName.localName, core.source)
                || !within(node.qualifiedName.namespace_, core.source))
                return "node " ~ i.to!string ~ "'s name is not in its source";
        foreach (i, ref attribute; core.attributes)
            if (!within(attribute.qualifiedName.localName, core.source)
                || !within(attribute.value.borrowedBytes, d.pool))
                return "attribute " ~ i.to!string ~ " is not in its document";
        foreach (i, ref value; core.values)
            if (!within(value.value.borrowedBytes, d.pool))
                return "value " ~ i.to!string ~ "'s payload is not in its pool";
        return null;
    }

    if (a.valid != b.valid)
        return "validity";
    if (!a.valid)
        return null;
    if (auto why = owned(a))
        return why;
    if (auto why = owned(b))
        return why;
    const x = a.core, y = b.core;
    if (a.sourceName != b.sourceName)
        return "source name";
    if (x.source != y.source)
        return "source";
    if (x.content != y.content)
        return "content";
    if (x.nodes.length != y.nodes.length)
        return "node count " ~ x.nodes.length.to!string ~ " vs " ~ y.nodes.length.to!string;
    foreach (i; 0 .. x.nodes.length)
    {
        const p = x.nodes[i], q = y.nodes[i];
        const where = "node " ~ i.to!string ~ " (" ~ p.qualifiedName.localName.idup ~ "): ";
        if (p.qualifiedName != q.qualifiedName)
            return where ~ "name";
        static foreach (field; ["nameSpan", "span", "extent", "openBrace", "closeBrace",
            "terminator", "valueStart", "valueCount", "attributeStart", "attributeCount",
            "childStart", "childCount", "depth", "hasBlock", "aloneOnLines"])
            if (__traits(getMember, p, field) != __traits(getMember, q, field))
                return where ~ field ~ " " ~ __traits(getMember, p, field).to!string ~ " vs "
                    ~ __traits(getMember, q, field).to!string;
    }
    if (x.childIndexes != y.childIndexes)
        return "child indexes";
    if (x.values.length != y.values.length)
        return "value count";
    foreach (i; 0 .. x.values.length)
        if (spelled(x.values[i].value) != spelled(y.values[i].value))
            return "value " ~ i.to!string ~ ": " ~ spelled(x.values[i].value) ~ " vs "
                ~ spelled(y.values[i].value);
    if (x.attributes.length != y.attributes.length)
        return "attribute count";
    foreach (i; 0 .. x.attributes.length)
    {
        const p = x.attributes[i], q = y.attributes[i];
        if (p.qualifiedName != q.qualifiedName || p.nameSpan != q.nameSpan || p.span != q.span
            || spelled(p.value) != spelled(q.value))
            return "attribute " ~ i.to!string;
    }
    if (x.comments != y.comments)
        return "comments";
    if (x.lines.lineStarts != y.lines.lineStarts)
        return "line starts";
    return null;
}

/// What a $(LREF CountingAllocator) has allocated.
package struct AllocationCounts
{
    size_t calls; /// successful `allocate` calls
    size_t bytes; /// bytes those calls returned
    size_t live;  /// blocks not yet deallocated
}

/** A stateful allocator over `Mallocator` that counts into `counts`: its
copies share the counts, as the copies an `SdlOpenDocument` hands its
documents must share one allocator's state. */
package struct CountingAllocator()
{
    import std.experimental.allocator.mallocator : Mallocator;

    AllocationCounts* counts;

    enum uint alignment = Mallocator.alignment;

    void[] allocate(size_t bytes) @safe pure nothrow @nogc
    {
        auto block = Mallocator.instance.allocate(bytes);
        if (block !is null)
        {
            counts.calls++;
            counts.bytes += block.length;
            counts.live++;
        }
        return block;
    }

    bool deallocate(void[] block) @system pure nothrow @nogc
    {
        if (block is null)
            return true;
        counts.live--;
        return Mallocator.instance.deallocate(block);
    }
}
