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
payload, the comments, the line table and positions, read through the core's
accessors and again through the public views, so a shared document's runs are
checked on both paths. Each document must also keep the ownership rule of
editing §10.1: every name it returns lies in its own source, and every
payload in the pool of a block it holds, so a splice that borrows from the
document it was made from is caught. */
package string documentDifference(A, B)(ref const A a, ref const B b) @system
{
    import std.conv : to;
    import sparkles.base.buffer : UniqueBuffer;
    import sparkles.wired.sdl.document : SdlAttributeView, SdlCore, SdlNode, SdlScalar,
        SdlScalarKind;
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
        bool held(scope const(void)[] payload)
        {
            if (payload.length == 0)
                return true;
            foreach (block; core.blocks)
                if (within(payload, block.pool))
                    return true;
            return false;
        }
        bool named(in typeof(core.nodeAt(0).qualifiedName) name)
            => within(name.localName, core.source) && within(name.namespace_, core.source);
        foreach (i; 0 .. core.nodeCount)
            if (!named(core.nodeAt(i).qualifiedName) || !named(SdlNode(core, i).qualifiedName))
                return "node " ~ i.to!string ~ "'s name is not in its source";
        foreach (i; 0 .. core.attributeCount)
            if (!named(core.attributeAt(i).qualifiedName)
                || !named(SdlAttributeView(core, i).qualifiedName)
                || !held(core.attributeAt(i).value.borrowedBytes))
                return "attribute " ~ i.to!string ~ " is not in its document";
        foreach (i; 0 .. core.valueCount)
            if (!held(core.valueAt(i).value.borrowedBytes))
                return "value " ~ i.to!string ~ "'s payload is not in a block it holds";
        return null;
    }

    // What a node's views show: its scalars, its attributes and its children.
    static string viewed(scope const(SdlCore)* core, size_t i)
    {
        const node = SdlNode(core, i);
        string text = node.qualifiedName.namespace_.idup ~ ":" ~ node.qualifiedName.localName.idup
            ~ " " ~ node.span.to!string ~ node.nameSpan.to!string ~ node.extent.to!string
            ~ node.aloneOnLines.to!string ~ node.hasBlock.to!string;
        foreach (k; 0 .. node.valueCount)
            text ~= " v" ~ spelled(node.valueAt(k));
        foreach (value; node.byValue)
            text ~= " " ~ spelled(value);
        foreach (attribute; node.byAttribute)
            text ~= " " ~ attribute.qualifiedName.namespace_.idup ~ ":"
                ~ attribute.qualifiedName.localName.idup ~ attribute.nameSpan.to!string
                ~ attribute.span.to!string ~ "=" ~ spelled(attribute.value);
        size_t children;
        foreach (child; node.byChild)
        {
            text ~= " #" ~ child.cellIndex.to!string;
            children++;
        }
        return children == node.childCount ? text : text ~ " (child count)";
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
    if (x.nodeCount != y.nodeCount)
        return "node count " ~ x.nodeCount.to!string ~ " vs " ~ y.nodeCount.to!string;
    foreach (i; 0 .. x.nodeCount)
    {
        const p = x.nodeAt(i), q = y.nodeAt(i);
        const where = "node " ~ i.to!string ~ " (" ~ q.qualifiedName.localName.idup ~ "): ";
        if (p.qualifiedName != q.qualifiedName)
            return where ~ "name";
        static foreach (field; ["nameSpan", "span", "extent", "openBrace", "closeBrace",
            "terminator", "valueStart", "valueCount", "attributeStart", "attributeCount",
            "subtreeSize", "childCount", "depth", "hasBlock", "aloneOnLines"])
            if (__traits(getMember, p, field) != __traits(getMember, q, field))
                return where ~ field ~ " " ~ __traits(getMember, p, field).to!string ~ " vs "
                    ~ __traits(getMember, q, field).to!string;
        const v = viewed(x, i), w = viewed(y, i);
        if (v != w)
            return where ~ "views: " ~ v ~ " vs " ~ w;
        foreach (offset; [p.span.startOffset, p.span.endOffset])
            if (a.position(offset) != b.position(offset))
                return where ~ "position of " ~ offset.to!string;
    }
    if (x.valueCount != y.valueCount)
        return "value count";
    foreach (i; 0 .. x.valueCount)
        if (spelled(x.valueAt(i).value) != spelled(y.valueAt(i).value))
            return "value " ~ i.to!string ~ ": " ~ spelled(x.valueAt(i).value) ~ " vs "
                ~ spelled(y.valueAt(i).value);
    if (x.attributeCount != y.attributeCount)
        return "attribute count";
    foreach (i; 0 .. x.attributeCount)
    {
        const p = x.attributeAt(i), q = y.attributeAt(i);
        if (p.qualifiedName != q.qualifiedName || p.nameSpan != q.nameSpan || p.span != q.span
            || spelled(p.value) != spelled(q.value))
            return "attribute " ~ i.to!string;
    }
    if (x.commentCount != y.commentCount)
        return "comment count";
    foreach (i; 0 .. x.commentCount)
        if (x.commentAt(i) != y.commentAt(i) || a.comments[i] != b.comments[i])
            return "comment " ~ i.to!string;
    if (x.lineZero != y.lineZero || x.lineCount != y.lineCount)
        return "line count";
    foreach (i; 0 .. x.lineCount)
        if (x.lineStart(i) != y.lineStart(i))
            return "line start " ~ i.to!string;
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
