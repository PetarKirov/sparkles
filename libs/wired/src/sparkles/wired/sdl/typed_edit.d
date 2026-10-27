/** Lossless typed write-back (editing §3, "update from a typed value").

`updateSDL` changes a parsed node so that it decodes as a given typed value,
through the lossless editor: it encodes the value canonically, then walks the
original node beside the encoding, field by field of the schema, and edits
only what differs — a positional value, an attribute, a child added, removed
or changed. Everything the schema does not claim (unknown tags such as DUB's
`x:` extensions, comments, layout) is never touched, and spellings that mean
the same scalar (`"a"` and `` `a` ``) are left as written.

Writing a value decoded from a document back without changes therefore
produces no edit at all, which is the lossless round-trip law (SPEC §10).
*/
module sparkles.wired.sdl.typed_edit;

import std.range.primitives : put;
import std.traits : isDynamicArray, isAssociativeArray, Unqual;

import sparkles.base.buffer : UniqueBuffer;
import sparkles.wired.sdl.codec : claimantOf, encodeSdlTree, isOtherChildLocal,
    SdlEncodedTree;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.schema_annotations : sdlAggregateRoles, SdlChildShape,
    SdlRoleKind;
import sparkles.wired.sdl.writer : SdlWriteOptions, writeSdlChildren, writeSdlScalar;

/** Edits `node` — of the document `editor` edits — so that it decodes as
`value`, changing only what differs (see the module documentation). An
encoding failure becomes the editor's failure; `write` reports it. */
void updateSDL(T, Editor)(ref Editor editor, scope SdlNode node, scope const ref T value)
if (is(T == struct))
{
    SdlEncodedTree tree;
    encodeSdlTree(value, tree);
    if (tree.failed)
        return editor.failWith(tree.failure);
    patch!(Unqual!T)(editor, node, tree.root, SdlNode.init, 0);
}

private alias Leaf(V) = Unqual!V;

/// The element a child field holds: its sequence element, its map value, or
/// itself.
private template ElementOf(V)
{
    static if (isAssociativeArray!V)
        alias ElementOf = Unqual!(typeof(V.init.values[0]));
    else static if (isDynamicArray!V && !is(Unqual!V == string))
        alias ElementOf = Unqual!(typeof(V.init[0]));
    else
        alias ElementOf = Unqual!V;
}

/// Whether a child element is patched field by field: a plain aggregate.
private enum bool patchable(E) = is(E == struct)
    && __traits(compiles, sdlAggregateRoles!E.sdlFieldRoles)
    && !__traits(hasMember, E, "match") // a SumType is replaced whole
    && !__traits(hasMember, E, "isNull") && !__traits(hasMember, E, "empty");

/// `node`'s canonical rendering — its subtree as the writer spells it —
/// into `text`, `node` being child `position` of `parent`.
private bool render(scope SdlNode parent, size_t position, ref UniqueBuffer!char text)
{
    text.clear();
    return !writeSdlChildren(parent, text, SdlWriteOptions.init, position).hasError;
}

private bool sameScalar(in SdlScalar left, in SdlScalar right)
{
    UniqueBuffer!(char, 64) a, b;
    return !writeSdlScalar(left, a).hasError && !writeSdlScalar(right, b).hasError
        && a[] == b[];
}

private bool sameValues(scope SdlNode left, scope SdlNode right)
{
    if (left.valueCount != right.valueCount)
        return false;
    auto r = right.byValue;
    foreach (value; left.byValue)
    {
        if (!sameScalar(value, r.front))
            return false;
        r.popFront();
    }
    return true;
}

/// A child of some parent, with its position there.
private struct Kid
{
    SdlNode node;
    size_t position;
}

/// `e` is child `ePosition` of `eParent` in the encoding (the root has none).
private void patch(U, Editor)(ref Editor editor, scope SdlNode d, scope SdlNode e,
    scope SdlNode eParent, size_t ePosition)
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;

    // A node whose identity changes is a different node: replace it whole.
    if (d.cellIndex != 0 && d.qualifiedName != e.qualifiedName)
    {
        UniqueBuffer!char text;
        if (render(eParent, ePosition, text))
            editor.replaceNode(d, text[]);
        return;
    }

    // Positional values belong to the node, whichever fields declare them.
    if (d.cellIndex != 0 && !sameValues(d, e))
    {
        UniqueBuffer!SdlScalar values;
        foreach (value; e.byValue)
            () @trusted { values ~= value; }();
        editor.setValues(d, values[]);
    }

    // New children of a node without a block must arrive in one block.
    UniqueBuffer!char appended;
    static foreach (i; 0 .. roles.roles.length)
    {{
        enum R = roles.roles[i];
        static if (R.role == SdlRoleKind.attribute)
            patchAttributes!(U, i)(editor, d, e);
        else static if (R.role == SdlRoleKind.child)
            patchChildren!(U, i)(editor, d, e, appended);
    }}
    if (appended.length)
        editor.append(d, appended[]);
}

private void patchAttributes(U, size_t i, Editor)(ref Editor editor, scope SdlNode d,
    scope SdlNode e)
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    enum R = roles.roles[i];
    const name = SdlQualifiedName(R.namespace_, R.localName);

    UniqueBuffer!SdlAttributeView mine, theirs;
    foreach (attribute; d.byAttribute)
        if (claimantOf!(U, SdlRoleKind.attribute)(attribute.qualifiedName) == i)
            () @trusted { mine ~= attribute; }();
    foreach (attribute; e.byAttribute)
        if (attribute.qualifiedName == name)
            () @trusted { theirs ~= attribute; }();

    if (mine.length == theirs.length)
    {
        foreach (k; 0 .. mine.length)
            if (!sameScalar(mine[k].value, theirs[k].value))
                // Keep the spelling of the name the source used (an alias).
                editor.replaceAttribute(mine[k], mine[k].qualifiedName, theirs[k].value);
        return;
    }
    foreach (k; 0 .. mine.length)
        editor.removeAttribute(mine[k]);
    foreach (k; 0 .. theirs.length)
        editor.insertAttribute(d, name, theirs[k].value);
}

private void patchChildren(U, size_t i, Editor)(ref Editor editor, scope SdlNode d,
    scope SdlNode e, ref UniqueBuffer!char appended)
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    enum R = roles.roles[i];
    alias E = ElementOf!(typeof(U.tupleof[i]));
    enum isMap = R.childShape == SdlChildShape.map;

    bool claims(bool encoded, scope SdlNode child)
    {
        const name = child.qualifiedName;
        static if (isMap)
            return name.namespace_ == R.namespace_
                && !isOtherChildLocal!(U, i)(name.localName);
        else
            return encoded ? name == SdlQualifiedName(R.namespace_, R.localName)
                : claimantOf!(U, SdlRoleKind.child)(name) == i;
    }

    UniqueBuffer!Kid mine, theirs;
    size_t position;
    foreach (child; d.byChild)
    {
        if (claims(false, child))
            () @trusted { mine ~= Kid(child, position); }();
        position++;
    }
    position = 0;
    foreach (child; e.byChild)
    {
        if (claims(true, child))
            () @trusted { theirs ~= Kid(child, position); }();
        position++;
    }

    UniqueBuffer!char left, right;
    // A scalar sequence's values flatten across its occurrences, and the
    // typed value keeps no boundary between them: equal values are no edit;
    // otherwise the first occurrence takes them all.
    static if (R.childShape == SdlChildShape.scalarSequence)
    {
        UniqueBuffer!SdlScalar was, now;
        foreach (k; 0 .. mine.length)
            foreach (value; mine[k].node.byValue)
                () @trusted { was ~= value; }();
        foreach (k; 0 .. theirs.length)
            foreach (value; theirs[k].node.byValue)
                () @trusted { now ~= value; }();
        bool same = was.length == now.length;
        foreach (k; 0 .. same ? was.length : 0)
            same &= sameScalar(was[k], now[k]);
        if (same)
            return;
        if (!mine.length)
        {
            foreach (k; 0 .. theirs.length)
                insertChild(editor, mine[], e, theirs[k], appended, right);
            return;
        }
        if (now.length)
            editor.setValues(mine[0].node, now[]);
        else
            editor.remove(mine[0].node);
        foreach (k; 1 .. mine.length)
            editor.remove(mine[k].node);
        return;
    }
    // A map pairs by key, every other shape by position.
    else static if (isMap)
    {
        foreach (k; 0 .. mine.length)
        {
            size_t match = size_t.max;
            foreach (j; 0 .. theirs.length)
                if (theirs[j].node.qualifiedName == mine[k].node.qualifiedName)
                    match = j;
            if (match == size_t.max)
                editor.remove(mine[k].node);
            else
                patchChild!E(editor, d, mine[k], e, theirs[match], left, right);
        }
        foreach (j; 0 .. theirs.length)
        {
            bool present;
            foreach (k; 0 .. mine.length)
                present |= mine[k].node.qualifiedName == theirs[j].node.qualifiedName;
            if (!present)
                insertChild(editor, mine[], e, theirs[j], appended, right);
        }
    }
    else
    {
        const paired = mine.length < theirs.length ? mine.length : theirs.length;
        foreach (k; 0 .. paired)
            patchChild!E(editor, d, mine[k], e, theirs[k], left, right);
        foreach (k; paired .. mine.length)
            editor.remove(mine[k].node);
        foreach (k; paired .. theirs.length)
            insertChild(editor, mine[], e, theirs[k], appended, right);
    }
}

private void patchChild(E, Editor)(ref Editor editor, scope SdlNode d, in Kid mine,
    scope SdlNode e, in Kid theirs, ref UniqueBuffer!char left, ref UniqueBuffer!char right)
{
    static if (patchable!E)
        patch!E(editor, mine.node, theirs.node, e, theirs.position);
    else
    {
        if (!render(d, mine.position, left) || !render(e, theirs.position, right)
            || left[] == right[])
            return;
        // A scalar child changes its values; anything else is replaced.
        if (!mine.node.hasBlock && !theirs.node.hasBlock && mine.node.attributeCount == 0
            && theirs.node.attributeCount == 0
            && mine.node.qualifiedName == theirs.node.qualifiedName)
        {
            UniqueBuffer!SdlScalar values;
            foreach (value; theirs.node.byValue)
                () @trusted { values ~= value; }();
            editor.setValues(mine.node, values[]);
        }
        else
            editor.replaceNode(mine.node, right[]);
    }
}

/// Inserts the encoded child after the field's last existing child, or
/// queues it for one append to the parent when the field has none.
private void insertChild(Editor)(ref Editor editor, scope const Kid[] mine,
    scope SdlNode e, in Kid theirs, ref UniqueBuffer!char appended,
    ref UniqueBuffer!char text)
{
    if (!render(e, theirs.position, text))
        return;
    if (mine.length)
        editor.insertAfter(mine[$ - 1].node, text[]);
    else
        put(appended, text[]);
}

version (unittest)
{
    import std.experimental.allocator.mallocator : Mallocator;
    import sparkles.wired.policy : WireName, WireOptional, WireSkip;
    import sparkles.wired.sdl.policy : Sdl;
    import sparkles.wired.sdl.codec : fromSDL;
    import sparkles.wired.sdl.config : sdlFull;
    import sparkles.wired.sdl.editor : sdlEditor;
    import sparkles.wired.sdl.reader : parseSdlDocument;
    import sparkles.wired.sdl.schema_annotations : SdlAttribute, SdlTagValue;

    private struct Dep
    {
        @SdlTagValue(0) string name;
        @WireName!Sdl("version") @WireOptional(WireSkip.whenDefault) @SdlAttribute() string version_;
        @WireOptional(WireSkip.whenDefault) @SdlAttribute() string path;
    }

    private struct Config
    {
        @SdlTagValue(0) string name;
        @WireOptional(WireSkip.whenDefault) string targetType;
        @WireName!Sdl("dependency") Dep[] deps;
    }

    private struct Recipe
    {
        string name;
        @WireOptional(WireSkip.whenDefault) string description;
        @WireName!Sdl("dependency") Dep[] deps;
        @WireName!Sdl("configuration") Config[] configurations;
    }

    /// `source` after writing back what `change` makes of its decoded value.
    private string writtenBack(alias change)(string source)
    {
        auto parsed = parseSdlDocument!sdlFull(source);
        assert(parsed.hasValue, parsed.error.toString);
        auto decoded = fromSDL!Recipe(parsed.document.root);
        assert(decoded.hasValue, decoded.error.toString);
        Recipe value = decoded.value;
        change(value);
        auto editor = sdlEditor(parsed.document, source);
        updateSDL(editor, parsed.document.root, value);
        UniqueBuffer!char output;
        Mallocator allocator;
        const written = editor.write(output, allocator);
        assert(!written.hasError, written.error.toString);
        // The output means the changed value.
        auto reparsed = parseSdlDocument!sdlFull(output[]);
        assert(reparsed.hasValue);
        assert(fromSDL!Recipe(reparsed.document.root).value == value);
        return output[].idup;
    }
}

@("sdl.typedEdit.unchangedIsByteIdentical")
@system unittest
{
    // Comments, raw strings, an unknown tag, odd spacing and CRLF all stay.
    enum source = "// the recipe\r\nname `demo`   # raw\r\nx:ddox \"keep\"\r\n"
        ~ "dependency \"a\"  version=\"*\"\r\nconfiguration \"lib\" {\r\n\ttargetType \"library\"\r\n}\r\n";
    assert(writtenBack!((ref Recipe v) {})(source) == source);
}

@("sdl.typedEdit.changesOnlyWhatDiffers")
@system unittest
{
    enum source = "name \"demo\" // keep\ndependency \"a\" version=\"*\"\n"
        ~ "configuration \"lib\" {\n    targetType \"library\"\n}\n";
    // An attribute value.
    assert(writtenBack!((ref Recipe v) { v.deps[0].version_ = "~>1.0"; })(source)
        == "name \"demo\" // keep\ndependency \"a\" version=\"~>1.0\"\n"
            ~ "configuration \"lib\" {\n    targetType \"library\"\n}\n");
    // An attribute replaced by another (version → path).
    assert(writtenBack!((ref Recipe v) { v.deps[0].version_ = null; v.deps[0].path = "../.."; })(source)
        == "name \"demo\" // keep\ndependency \"a\" path=\"../..\"\n"
            ~ "configuration \"lib\" {\n    targetType \"library\"\n}\n");
    // A scalar child, and an optional one added at the end of the root.
    assert(writtenBack!((ref Recipe v) { v.name = "other"; v.description = "d"; })(source)
        == "name \"other\" // keep\ndependency \"a\" version=\"*\"\n"
            ~ "configuration \"lib\" {\n    targetType \"library\"\n}\ndescription \"d\"\n");
    // Sequence elements appended after the last, and removed.
    assert(writtenBack!((ref Recipe v) { v.deps ~= Dep("b", "1.0"); })(source)
        == "name \"demo\" // keep\ndependency \"a\" version=\"*\"\ndependency \"b\" version=\"1.0\"\n"
            ~ "configuration \"lib\" {\n    targetType \"library\"\n}\n");
    assert(writtenBack!((ref Recipe v) { v.configurations = null; })(source)
        == "name \"demo\" // keep\ndependency \"a\" version=\"*\"\n");
    // A nested aggregate: a child inserted into an existing block.
    assert(writtenBack!((ref Recipe v) { v.configurations[0].deps ~= Dep("c"); })(source)
        == "name \"demo\" // keep\ndependency \"a\" version=\"*\"\n"
            ~ "configuration \"lib\" {\n    targetType \"library\"\n    dependency \"c\"\n}\n");
}
