/** Lossless typed write-back (editing §3, "update from a typed value").

`updateSDL` changes a parsed node so that it decodes as a given typed value,
through the lossless editor: it encodes the value canonically, then walks the
original node beside the encoding, field by field of the schema, and edits
only what differs — a positional value, an attribute, a child added, removed
or changed. Elements of an aggregate sequence pair by identity — their name
and positional values — so an element removed, inserted or changed in the
middle edits only that element, and a reordered one moves with its bytes and
comments. Everything the schema does not claim (unknown
tags such as DUB's `x:` extensions, comments, layout) is never touched, and
spellings that mean the same scalar (`"a"` and `` `a` ``) are left as written.

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
import sparkles.wired.sdl.editor : SdlAttachedComments;
import sparkles.wired.sdl.schema_annotations : sdlAggregateRoles, SdlChildShape,
    SdlRoleKind;
import sparkles.wired.sdl.writer : SdlWriteOptions, writeSdlChildren, writeSdlScalar;

/** Edits `node` — of the document `editor` edits — so that it decodes as
`value`, changing only what differs (see the module documentation). `node`
may be the root or any node that decodes as `T`. An encoding failure becomes
the editor's failure; `write` reports it. */
void updateSDL(T, Editor)(ref Editor editor, scope SdlNode node, scope const ref T value)
if (is(T == struct))
{
    SdlEncodedTree tree;
    encodeSdlTree(value, tree);
    if (tree.failed)
        return editor.failWith(tree.failure);
    // The caller chose `node`, so its name is not compared with the
    // encoding's root, which has none.
    patch!(Unqual!T)(editor, node, tree.root, SdlNode.init, 0, false);
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

/// Whether a child element is patched field by field: a plain aggregate. A
/// SumType is not one: SDL unions are scalar (SPEC §6), and a scalar child
/// changes its values in place.
private enum bool patchable(E) = is(E == struct)
    && __traits(compiles, sdlAggregateRoles!E.sdlFieldRoles)
    && !__traits(hasMember, E, "match")
    && !__traits(hasMember, E, "isNull") && !__traits(hasMember, E, "empty");

/// Whether aggregate `U` takes its tag name or namespace from a field
/// (`@SdlTagName`, `@SdlTagNamespace`), making the name data.
private enum bool hasDynamicIdentity(U) = () {
    foreach (role; sdlAggregateRoles!U.sdlFieldRoles.roles)
        if (role.dynamicName || role.dynamicNamespace)
            return true;
    return false;
}();

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

/** `e` is child `ePosition` of `eParent` in the encoding (the root has none).
`named` when the field that claimed `d` compares names: a node whose name is
data and changes is a different node. Any other name `d` has is one its
field claims — an alias included — and is kept. */
private void patch(U, Editor)(ref Editor editor, scope SdlNode d, scope SdlNode e,
    scope SdlNode eParent, size_t ePosition, bool named = true)
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;

    static if (hasDynamicIdentity!U)
        if (named && d.cellIndex != 0 && d.qualifiedName != e.qualifiedName)
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
    // An aggregate sequence pairs by identity, anything else by position.
    else static if (patchable!E)
        patchSequence!E(editor, d, e, mine[], theirs[], appended, left, right);
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

/// Whether two elements have the same identity: name and positional values.
private bool sameIdentity(scope SdlNode left, scope SdlNode right)
    => left.qualifiedName == right.qualifiedName && sameValues(left, right);

/// A hash of an element's identity: its name and its values' canonical
/// spellings, so equal identities hash equally.
private size_t identityHash(scope SdlNode node)
{
    UniqueBuffer!(char, 128) text;
    const name = node.qualifiedName;
    put(text, name.namespace_);
    put(text, ":");
    put(text, name.localName);
    // A value without a spelling ends the hash early; `sameIdentity` decides.
    foreach (value; node.byValue)
    {
        put(text, " ");
        if (writeSdlScalar(value, text).hasError)
            break;
    }
    return hashOf(text[]);
}

/** Pairs an aggregate sequence's elements (editing §3.1): each new element
with the first unpaired old one of the same identity; of those pairs, a
longest run in the same relative order in both stays in place. Every other
identity pair moves, with its bytes and attached comments, to its new place.
Between two pairs left in place, the old and new elements without an
identity pair pair by position — they are changed in place — and the
surplus old ones are removed with their attached comments. Moved and new
elements go after the last node left in place before them, else above the
next one and its comments. Identities are hashed and the run is a patience
sort, so pairing is O(n log n) in the sequence's length. */
private void patchSequence(E, Editor)(ref Editor editor, scope SdlNode d, scope SdlNode e,
    scope const Kid[] mine, scope const Kid[] theirs, ref UniqueBuffer!char appended,
    ref UniqueBuffer!char left, ref UniqueBuffer!char right)
{
    enum none = size_t.max;

    // keep[j]: the old element new element `j` pairs with by identity, or
    // `none`; paired[k]: whether old element `k` has a partner.
    UniqueBuffer!size_t keep;
    UniqueBuffer!bool paired;
    keep.length = theirs.length;
    paired.length = mine.length;
    keep[][] = none;
    paired[][] = false;
    pairByIdentity(mine, theirs, keep[]);
    foreach (j; 0 .. theirs.length)
        if (keep[j] != none)
            paired[keep[j]] = true;

    // A longest run of pairs whose old positions increase: patience sort.
    // tails[l] ends the run of length l + 1 with the smallest old position.
    UniqueBuffer!size_t tails, before;
    tails.length = theirs.length;
    before.length = theirs.length;
    size_t runs;
    foreach (j; 0 .. theirs.length)
    {
        if (keep[j] == none)
            continue;
        size_t low, high = runs;
        while (low < high)
        {
            const mid = low + (high - low) / 2;
            if (keep[tails[mid]] < keep[j])
                low = mid + 1;
            else
                high = mid;
        }
        before[j] = low ? tails[low - 1] : none;
        tails[low] = j;
        if (low == runs)
            runs++;
    }
    UniqueBuffer!bool kept;
    kept.length = theirs.length;
    kept[][] = false;
    for (size_t j = runs ? tails[runs - 1] : none; j != none; j = before[j])
        kept[j] = true;

    UniqueBuffer!size_t group, free;
    UniqueBuffer!char inserted;
    size_t anchor = none; // the last old element left in place

    // Places `group` — moved and new elements, in order — after the anchor,
    // else just above `stationary` and its comments, else at the end.
    void place(size_t stationary)
    {
        if (!group.length)
            return;
        Place at;
        if (anchor != none)
            at = Place(mine[anchor].node, true, true);
        else if (stationary != none)
            at = placeAbove(d, mine, keep[], kept[], mine[stationary]);
        inserted.clear();
        foreach (t; group[])
        {
            const old = keep[t];
            if (old != none && at.has && editor.canMove(mine[old].node, at.node, at.after))
            {
                at.insert(editor, inserted[], appended);
                inserted.clear();
                at.move(editor, mine[old].node);
                patchChild!E(editor, d, mine[old], e, theirs[t], left, right);
                continue;
            }
            // Not movable here — more than one line, a line comment or
            // attached comments, bound between two nodes of one line —
            // so written afresh in its new place.
            if (old != none)
                editor.remove(mine[old].node, SdlAttachedComments.remove);
            if (render(e, theirs[t].position, right))
                put(inserted, right[]);
        }
        at.insert(editor, inserted[], appended);
        group.clear();
    }

    size_t k = 0, j = 0;
    for (;;)
    {
        // The gap up to the next kept pair, or to the end.
        size_t next = j;
        while (next < theirs.length && !kept[next])
            next++;
        const oldEnd = next < theirs.length ? keep[next] : mine.length;

        free.clear();
        foreach (q; k .. oldEnd)
            if (!paired[q])
                () @trusted { free ~= q; }();
        size_t q;
        foreach (t; j .. next)
        {
            if (keep[t] == none && q < free.length)
            {
                place(free[q]);
                patchChild!E(editor, d, mine[free[q]], e, theirs[t], left, right);
                anchor = free[q++];
            }
            else
                () @trusted { group ~= t; }();
        }
        foreach (r; q .. free.length)
            editor.remove(mine[free[r]].node, SdlAttachedComments.remove);

        if (next == theirs.length)
        {
            place(none);
            break;
        }
        place(keep[next]);
        patchChild!E(editor, d, mine[keep[next]], e, theirs[next], left, right);
        anchor = keep[next];
        k = keep[next] + 1;
        j = next + 1;
    }
}

/** Sets `keep[j]` to the first old element of new element `j`'s identity
not taken by an earlier new element. Old elements are grouped by identity
in an open-addressed table; each group is a list in source order with a
cursor at its first unpaired member, so duplicates pair first to first. */
private void pairByIdentity(scope const Kid[] mine, scope const Kid[] theirs, size_t[] keep)
{
    enum none = size_t.max;
    if (!mine.length)
        return;
    size_t capacity = 8;
    while (capacity < 2 * mine.length)
        capacity *= 2;
    const mask = capacity - 1;

    // slots: group + 1, or 0; per group its hash, first member, cursor and
    // last member; link[k]: the member after old element `k`.
    UniqueBuffer!size_t slots, hashes, first, cursor, last, link;
    slots.length = capacity;
    slots[][] = 0;
    link.length = mine.length;

    size_t find(size_t hash, scope SdlNode node, out size_t slot)
    {
        for (slot = hash & mask; slots[slot]; slot = (slot + 1) & mask)
        {
            const g = slots[slot] - 1;
            if (hashes[g] == hash && sameIdentity(mine[first[g]].node, node))
                return g;
        }
        return none;
    }

    foreach (k; 0 .. mine.length)
    {
        const hash = identityHash(mine[k].node);
        size_t slot;
        const g = find(hash, mine[k].node, slot);
        link[k] = none;
        if (g == none)
        {
            slots[slot] = hashes.length + 1;
            hashes ~= hash;
            first ~= k;
            cursor ~= k;
            last ~= k;
        }
        else
        {
            if (cursor[g] == none)
                cursor[g] = k;
            else
                link[last[g]] = k;
            last[g] = k;
        }
    }
    foreach (j; 0 .. theirs.length)
    {
        size_t slot;
        const g = find(identityHash(theirs[j].node), theirs[j].node, slot);
        if (g == none || cursor[g] == none)
            continue;
        keep[j] = cursor[g];
        cursor[g] = link[cursor[g]];
    }
}

/// Where a sequence's moved and new elements go: beside a sibling, or, with
/// none, appended to the field.
private struct Place
{
    SdlNode node;
    bool after;
    bool has;

    void insert(Editor)(ref Editor editor, scope const(char)[] text,
        ref UniqueBuffer!char appended)
    {
        if (!text.length)
            return;
        if (!has)
            put(appended, text); // the field has no element left
        else if (after)
            editor.insertAfter(node, text);
        else
            editor.insertBefore(node, text);
    }

    void move(Editor)(ref Editor editor, scope SdlNode moved)
    {
        if (after)
            editor.moveAfter(moved, node);
        else
            editor.moveBefore(moved, node);
    }
}

/** Just above `kid` and the comments above it: after the nearest sibling
before it that does not move away, else before `kid` itself. */
private Place placeAbove(scope SdlNode parent, scope const Kid[] mine, scope const size_t[] keep,
    scope const bool[] kept, in Kid kid)
{
    enum none = size_t.max;
    // The positions of the field's elements that move: paired, not kept.
    UniqueBuffer!bool moves;
    moves.length = kid.position;
    moves[][] = false;
    foreach (j; 0 .. keep.length)
        if (keep[j] != none && !kept[j] && mine[keep[j]].position < kid.position)
            moves[mine[keep[j]].position] = true;
    Place at = Place(kid.node, false, true);
    size_t position;
    foreach (sibling; parent.byChild)
    {
        if (position == kid.position)
            break;
        if (!moves[position])
            at = Place(sibling, true, true);
        position++;
    }
    return at;
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
    import sparkles.wired.sdl.codec : fromSDL, toSDL;
    import sparkles.wired.sdl.config : sdlFull;
    import sparkles.wired.sdl.editor : sdlEditor;
    import sparkles.wired.sdl.reader : parseSdlDocument;
    import sparkles.wired.sdl.schema_annotations : SdlAttribute, SdlChild, SdlTagValue;

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
    private string writtenBack(alias change, T = Recipe)(string source)
    {
        auto parsed = parseSdlDocument!sdlFull(source);
        assert(parsed.hasValue, parsed.error.toString);
        auto decoded = fromSDL!T(parsed.document.root);
        assert(decoded.hasValue, decoded.error.toString);
        T value = decoded.value;
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
        assert(fromSDL!T(reparsed.document.root).value == value);
        return output[].idup;
    }

    // Three commented dependencies and two configurations, by part.
    private enum keyedName = "name \"demo\"\n";
    private enum keyedA = "// a: the first\ndependency \"a\" version=\"1\"\n";
    private enum keyedB = "// b: the second\ndependency \"b\" version=\"2\" # keep b\n";
    private enum keyedC = "// c: the third\ndependency \"c\" version=\"3\"\n";
    private enum keyedLib = "\n// the library\nconfiguration \"lib\" {\n    targetType \"library\" // lib\n}\n";
    private enum keyedApp = "// the app\nconfiguration \"app\" {\n    targetType \"executable\"\n"
        ~ "    dependency \"x\" # x\n}\n";
    private enum keyedSource = keyedName ~ keyedA ~ keyedB ~ keyedC ~ keyedLib ~ keyedApp;
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

@("sdl.typedEdit.keyed.unchangedIsByteIdentical")
@system unittest
{
    assert(writtenBack!((ref Recipe v) {})(keyedSource) == keyedSource);
}

@("sdl.typedEdit.keyed.removeInsertChangeInTheMiddle")
@system unittest
{
    // Removing the first element takes its attached comment and nothing else.
    assert(writtenBack!((ref Recipe v) { v.deps = v.deps[1 .. $]; })(keyedSource)
        == keyedName ~ keyedB ~ keyedC ~ keyedLib ~ keyedApp);
    // Removing the middle one, likewise.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[0], v.deps[2]]; })(keyedSource)
        == keyedName ~ keyedA ~ keyedC ~ keyedLib ~ keyedApp);
    // Inserting in the middle goes after the element before it.
    assert(writtenBack!((ref Recipe v) { v.deps = v.deps[0 .. 1] ~ Dep("n", "9") ~ v.deps[1 .. $]; })(keyedSource)
        == keyedName ~ keyedA ~ "dependency \"n\" version=\"9\"\n" ~ keyedB ~ keyedC ~ keyedLib ~ keyedApp);
    // Inserting first goes after the sibling before the first kept element,
    // so that element keeps its comment.
    assert(writtenBack!((ref Recipe v) { v.deps = Dep("n") ~ v.deps; })(keyedSource)
        == keyedName ~ "dependency \"n\"\n" ~ keyedA ~ keyedB ~ keyedC ~ keyedLib ~ keyedApp);
    // A changed identity between kept neighbours changes in place: its
    // comments stay, and so do its neighbours'.
    assert(writtenBack!((ref Recipe v) { v.deps[1].name = "B"; })(keyedSource)
        == keyedName ~ keyedA ~ "// b: the second\ndependency \"B\" version=\"2\" # keep b\n"
            ~ keyedC ~ keyedLib ~ keyedApp);
}

@("sdl.typedEdit.keyed.nestedAggregates")
@system unittest
{
    // The first configuration goes with its comment; the second keeps every
    // byte but the changed value.
    assert(writtenBack!((ref Recipe v) {
        v.configurations = v.configurations[1 .. $];
        v.configurations[0].targetType = "dynamicLibrary";
    })(keyedSource)
        == keyedName ~ keyedA ~ keyedB ~ keyedC ~ "\n"
            ~ "// the app\nconfiguration \"app\" {\n    targetType \"dynamicLibrary\"\n"
            ~ "    dependency \"x\" # x\n}\n");
    // A new configuration between them; the app's dependency removed.
    assert(writtenBack!((ref Recipe v) {
        v.configurations = [v.configurations[0], Config("mid"), v.configurations[1]];
        v.configurations[2].deps = null;
    })(keyedSource)
        == keyedName ~ keyedA ~ keyedB ~ keyedC ~ keyedLib ~ "configuration \"mid\"\n"
            ~ "// the app\nconfiguration \"app\" {\n    targetType \"executable\"\n}\n");
}

@("sdl.typedEdit.keyed.reorderMovesTheElement")
@system unittest
{
    // `a` and `b` stay; `c` moves before them with its comment.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[2], v.deps[0], v.deps[1]]; })(keyedSource)
        == keyedName ~ keyedC ~ keyedA ~ keyedB ~ keyedLib ~ keyedApp);
    // A moved element is then changed in place, children included; the
    // blank line before the library stays with the library.
    assert(writtenBack!((ref Recipe v) {
        v.configurations = [v.configurations[1], v.configurations[0]];
        v.configurations[0].targetType = "dynamicLibrary";
        v.configurations[0].deps[0].version_ = "1";
    })(keyedSource)
        == keyedName ~ keyedA ~ keyedB ~ keyedC
            ~ "// the app\nconfiguration \"app\" {\n    targetType \"dynamicLibrary\"\n"
            ~ "    dependency \"x\" version=\"1\" # x\n}\n" ~ keyedLib);
    // Odd spacing, raw strings, tabs and trailing comments move as written.
    enum odd = "name \"o\"\n#\tabout x\ndependency   `x`\tversion=`1`  // x\n"
        ~ "dependency \"y\"   path=\"..\"   # y\n// z\n/* z */ dependency \"z\"\n";
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[2], v.deps[1], v.deps[0]]; })(odd)
        == "name \"o\"\n// z\n/* z */ dependency \"z\"\ndependency \"y\"   path=\"..\"   # y\n"
            ~ "#\tabout x\ndependency   `x`\tversion=`1`  // x\n");
}

@("sdl.typedEdit.keyed.reorderOnSharedLines")
@system unittest
{
    // Elements that share a line move with their bytes too: `a` stays,
    // `c` and `b` leave its line for lines of their own above it, `c`'s
    // comment with it; `a` keeps its own `;`.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[2], v.deps[1], v.deps[0]]; })(
        "name \"d\"\ndependency \"a\"; dependency \"b\"; dependency \"c\" /* c */\n")
        == "name \"d\"\ndependency \"c\" /* c */\ndependency \"b\"\ndependency \"a\";\n");
    // Within a one-line block, the element moves along the line.
    assert(writtenBack!((ref Recipe v) {
        v.configurations[0].deps = [v.configurations[0].deps[1], v.configurations[0].deps[0]];
    })("name \"d\"\nconfiguration \"lib\" {; dependency \"x\"; dependency `y`; }\n")
        == "name \"d\"\nconfiguration \"lib\" {; dependency `y`; dependency \"x\"; }\n");
    // Onto a shared line from a line of its own.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[0], v.deps[2], v.deps[1]]; })(
        "name \"d\"\ndependency \"a\"; dependency \"c\"\ndependency `b`  version=`1`\n")
        == "name \"d\"\ndependency \"a\"; dependency `b`  version=`1`; dependency \"c\"\n");
    // An element with an attached comment cannot go between two nodes of
    // one line: it is written afresh there, and its comment goes.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[0], v.deps[2], v.deps[1]]; })(
        "name \"d\"\ndependency \"a\"; dependency \"c\"\n// about b\ndependency `b`\n")
        == "name \"d\"\ndependency \"a\"; dependency \"b\"; dependency \"c\"\n");
}

@("sdl.typedEdit.keyed.duplicatesPairInOrder")
@system unittest
{
    // Equal identities pair in order: the first stays and changes.
    enum twice = "name \"t\"\ndependency \"a\" version=\"1\" # 1\ndependency \"a\" version=\"2\"\n";
    assert(writtenBack!((ref Recipe v) { v.deps = v.deps[1 .. $]; })(twice)
        == "name \"t\"\ndependency \"a\" version=\"2\" # 1\n");
    enum source = "name \"t\"\ndependency \"a\" version=\"1\" # one\ndependency \"b\"\n"
        ~ "dependency \"a\" version=\"2\" # two\n";
    // The two `a`s keep their order and bytes; `b` moves above them.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[1], v.deps[0], v.deps[2]]; })(source)
        == "name \"t\"\ndependency \"b\"\ndependency \"a\" version=\"1\" # one\n"
            ~ "dependency \"a\" version=\"2\" # two\n");
    // Swapping them pairs first with first: each changes in place.
    assert(writtenBack!((ref Recipe v) { v.deps = [v.deps[2], v.deps[1], v.deps[0]]; })(source)
        == "name \"t\"\ndependency \"a\" version=\"2\" # one\ndependency \"b\"\n"
            ~ "dependency \"a\" version=\"1\" # two\n");
}

@("sdl.typedEdit.keyed.largeSequenceIsFast")
@system unittest
{
    import std.algorithm.searching : canFind;
    import std.conv : text;
    import std.datetime.stopwatch : AutoStart, StopWatch;

    // 5000 commented elements, reversed and then shuffled: every element
    // keeps its bytes, and pairing stays O(n log n).
    enum count = 5000;
    string[] blocks;
    foreach (i; 0 .. count)
        blocks ~= text(i % 2 ? "" : text("// c", i, "\n"), "dependency \"d", i, "\" version=\"", i, "\"\n");
    string source = "name \"big\"\n";
    foreach (block; blocks)
        source ~= block;

    auto watch = StopWatch(AutoStart.yes);
    const reversed = writtenBack!((ref Recipe v) {
        Dep[] deps;
        foreach_reverse (dep; v.deps)
            deps ~= dep;
        v.deps = deps;
    })(source);
    const reverseTime = watch.peek;
    string expected = "name \"big\"\n";
    foreach_reverse (block; blocks)
        expected ~= block;
    assert(reversed == expected);

    // A fixed shuffle, by a linear congruential generator.
    size_t[] order;
    foreach (i; 0 .. count)
        order ~= i;
    uint state = 12345;
    foreach_reverse (i; 1 .. count)
    {
        state = state * 1664525 + 1013904223;
        const swap = state % (i + 1);
        const t = order[i];
        order[i] = order[swap];
        order[swap] = t;
    }
    watch.reset();
    const shuffled = writtenBack!((ref Recipe v) {
        Dep[] deps;
        foreach (i; order)
            deps ~= v.deps[i];
        v.deps = deps;
    })(source);
    const shuffleTime = watch.peek;
    foreach (block; blocks)
        assert(shuffled.canFind(block));
    assert(shuffled.length == source.length);

    // The quadratic pairing took seconds here; this takes milliseconds.
    import std.datetime : seconds;
    assert(reverseTime < 2.seconds && shuffleTime < 2.seconds,
        text("reverse ", reverseTime, ", shuffle ", shuffleTime));
}


@("sdl.typedEdit.aliasSpellingsStay")
@system unittest
{
    import sparkles.wired.policy : WireAlias;

    static struct Part
    {
        @SdlTagValue(0) string name;
        @WireOptional(WireSkip.whenDefault) int size;
    }
    static struct Doc
    {
        @WireAlias!Sdl("piece") Part[] part;
    }

    // An old spelling names the same field: it is changed, never replaced.
    enum source = "piece \"a\" { // old\n    size 1\n}\npart \"b\"\n";
    assert(writtenBack!((ref Doc v) {}, Doc)(source) == source);
    assert(writtenBack!((ref Doc v) { v.part[0].size = 2; }, Doc)(source)
        == "piece \"a\" { // old\n    size 2\n}\npart \"b\"\n");
}

@("sdl.typedEdit.updatesANonRootNode")
@system unittest
{
    enum source = "dependency \"a\" version=\"1\" # one\ndependency \"b\"\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    assert(parsed.hasValue);
    auto target = parsed.document.root.byChild;
    target.popFront();
    auto editor = sdlEditor(parsed.document, source);
    const value = Dep("b", "2");
    updateSDL(editor, target.front, value);
    UniqueBuffer!char output;
    Mallocator allocator;
    assert(!editor.write(output, allocator).hasError);
    assert(output[] == "dependency \"a\" version=\"1\" # one\ndependency \"b\" version=\"2\"\n", output[]);
}

@("sdl.typedEdit.unionsChangeInPlace")
@system unittest
{
    import std.sumtype : SumType;

    alias Choice = SumType!(int, string);
    static struct Leaf
    {
        @SdlTagValue(0) Choice id;
        @WireOptional(WireSkip.whenDefault) @SdlAttribute() Choice choice;
    }
    static struct Doc
    {
        Choice single;
        @WireName!Sdl("leaf") Leaf[] leaves;
    }

    enum source = "// s\nsingle `raw` # s\nleaf 1 choice=2 # one\nleaf \"two\" { // keep\n}\n";
    assert(writtenBack!((ref Doc v) {}, Doc)(source) == source);
    // A changed member — the same one, or another — is one value edit.
    assert(writtenBack!((ref Doc v) { v.single = 3; }, Doc)(source)
        == "// s\nsingle 3 # s\nleaf 1 choice=2 # one\nleaf \"two\" { // keep\n}\n");
    assert(writtenBack!((ref Doc v) { v.leaves[0].choice = "c"; v.leaves[1].id = 2; }, Doc)(source)
        == "// s\nsingle `raw` # s\nleaf 1 choice=\"c\" # one\nleaf 2 { // keep\n}\n");
}
