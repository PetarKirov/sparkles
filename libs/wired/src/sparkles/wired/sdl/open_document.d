/** An SDL document kept open across edits, with node handles that survive
commits (editing spec §9, SDE11–SDE13).

An `SdlOpenDocument` owns a copy of its host — a recipe, or a D program that
embeds one — and the document parsed from it. Edits go through an
`SdlEditor` it lends; `commit` writes them into the host, keeps the re-parsed
document, and carries every node handle issued so far to its node's
counterpart, or retires it when an operation replaced the node.
*/
module sparkles.wired.sdl.open_document;

import std.experimental.allocator.common : stateSize;
import std.experimental.allocator.mallocator : Mallocator;

import sparkles.base.buffer : HeapBuffer, UniqueBuffer;
import sparkles.base.pool.heap_slot_table : Handle, HeapSlotTable, PoolError,
    PoolResult, poolErr, poolOk;
import sparkles.base.text.edits : mapOffset, TextEdit;
import sparkles.wired.sdl.config : SdlParserConfig, sdlFull;
import sparkles.wired.sdl.document;
import sparkles.wired.sdl.editor : SdlEditor, SdlReplacedCells;
import sparkles.wired.sdl.embedded : parseEmbeddedSdlDocument;
import sparkles.wired.sdl.error;
import sparkles.wired.sdl.reader : parseSdlDocument, SdlParseResult;

/// Tags node handles, so they are a type of their own (POOL2).
struct SdlNodeTag {}

/// The identity of one node of an `SdlOpenDocument`, across commits.
alias SdlNodeHandle = Handle!SdlNodeTag;

/// What an open document's host is.
enum SdlHostKind : ubyte
{
    recipe, /// The host is the SDL text itself.
    embedded, /// The host is a D program whose leading comment embeds the recipe.
}

/**
An SDL host, its parsed document and its node handles, kept across commits.

The open document is movable and not copyable. Moving it invalidates nothing
but the views and editors borrowed from it, as moving an `SdlDocument` does.

Every document it parses allocates through `Allocator`. A stateful allocator
is given to the constructor and kept by value, and each document parsed
through it keeps a copy of its own, as `parseSdlDocument` does, and frees its
arenas through that copy. The copies must therefore share one allocator's
state — a pointer to it, or a reference-counted handle such as `RCIAllocator`
— never duplicate it, and that state must outlive the open document.
*/
struct SdlOpenDocument(SdlParserConfig config = sdlFull, Allocator = Mallocator)
{
    private UniqueBuffer!char _host;
    private SdlDocument!Allocator _document;
    private HeapSlotTable!SdlNodeHandle _table;
    private HeapBuffer!uint _cellOf; // by slot: the node it names
    private HeapBuffer!uint _slotOf; // by cell: its slot + 1, or 0 for none
    static if (stateSize!Allocator)
        private Allocator _allocator;

    @disable this(this);

    static if (stateSize!Allocator)
    {
        /// An open document whose documents allocate through `allocator`.
        this(Allocator allocator)
        {
            _allocator = move(allocator);
        }
    }

    /** Copies `host` and parses it as `kind` says; any document opened
    before, and its handles, are dropped. On failure nothing changes. */
    SdlExpected!void open(scope const(char)[] host, scope const(char)[] sourceName = null,
        SdlHostKind kind = SdlHostKind.recipe)
    {
        SdlParseResult!Allocator parsed;
        if (kind == SdlHostKind.recipe)
        {
            static if (stateSize!Allocator)
                parsed = parseSdlDocument!config(host, sourceName, _allocator);
            else
                parsed = parseSdlDocument!(config, Allocator)(host, sourceName);
        }
        else
        {
            static if (stateSize!Allocator)
                auto embedded = parseEmbeddedSdlDocument!config(host, sourceName, _allocator);
            else
                auto embedded = parseEmbeddedSdlDocument!(config, Allocator)(host, sourceName);
            if (!embedded.recipe.found || embedded.recipe.isJson)
            {
                SdlError error;
                error.stage = SdlErrorStage.edit;
                error.code = SdlErrorCode.editTargetMissing;
                error.sourceName ~= sourceName;
                error.reason ~= "the host embeds no SDL recipe";
                return sdlErr!void(error);
            }
            parsed = move(embedded.parsed);
        }
        if (parsed.hasError)
            return sdlErr!void(parsed.error);
        _host.clear(releaseStorage: false);
        _host ~= host;
        _document = move(parsed.document);
        _table.clear();
        _slotOf.clear(releaseStorage: false);
        return sdlOk();
    }

    /// The document parsed from the host as it now stands.
    ref const(SdlDocument!Allocator) document() const return => _document;

    /// The host as it now stands.
    const(char)[] host() const return scope => _host[];

    /** The handle of `node`, issuing one the first time it is asked;
    `PoolError.invalid` for a view of another document. */
    PoolResult!SdlNodeHandle handleOf(scope SdlNode node)
    {
        if (!_document.valid || node.core !is (() @trusted => _document.core)())
            return poolErr!SdlNodeHandle(PoolError.invalid);
        const cell = node.cellIndex;
        if (_slotOf.length != _document.core.nodes.length)
            _slotOf.length = _document.core.nodes.length;
        if (_slotOf[cell])
            return poolOk(_table.handleAt(_slotOf[cell] - 1));
        auto issued = _table.insert();
        if (issued.hasError)
            return issued;
        const slot = issued.value.index;
        if (_cellOf.length <= slot)
            _cellOf.length = slot + 1;
        _cellOf[slot] = cast(uint) cell;
        _slotOf[cell] = slot + 1;
        return issued;
    }

    /** The node `handle` names in the current document: `PoolError.stale`
    once a commit replaced it (SDE12), `invalid` for `Handle.init` or a
    handle this document never issued. */
    PoolResult!SdlNode node(in SdlNodeHandle handle) const return scope
    {
        const slot = _table.resolve(handle);
        if (slot.hasError)
            return poolErr!SdlNode(slot.error);
        return poolOk((() @trusted => SdlNode(_document.core, _cellOf[slot.value]))());
    }

    /// The number of live handles.
    size_t handleCount() const @safe pure nothrow @nogc => _table.liveCount;

    /// An editor over the current document and host, to `commit`.
    auto editor() return scope
        => SdlEditor!(config, Allocator)(_document, _host[]);

    /** Writes `editor`'s edits into the host, keeps the re-parsed document
    and carries every handle over (SDE11) or retires it (SDE12). On failure
    — the editor failed, belongs to another document, or its result does not
    re-parse — nothing changes (SDE13). Either way the editor is spent: it
    borrowed the document this replaces. An editor with no edits replaces
    nothing: the host, the document and every handle stay as they are, and
    nothing is parsed (§10). */
    SdlExpected!void commit(ref SdlEditor!(config, Allocator) editor)
    {
        if (!_document.valid || !editor.borrows((() @trusted => _document.core)()))
        {
            SdlError error;
            error.stage = SdlErrorStage.edit;
            error.code = SdlErrorCode.editTargetMissing;
            error.sourceName ~= _document.sourceName;
            error.reason ~= "the editor belongs to another document";
            return sdlErr!void(error);
        }

        UniqueBuffer!char output;
        UniqueBuffer!TextEdit edits;
        SdlParseResult!Allocator parsed;
        static if (stateSize!Allocator)
            alias allocator = _allocator;
        else
            Allocator allocator;
        auto rendered = editor.render(allocator, output, edits, parsed);
        if (rendered.hasError)
            return rendered;
        if (edits.length == 0)
        {
            // The output is the host, and the document is its parse.
            editor.retire();
            return sdlOk();
        }

        carryHandles(editor.replaced, edits[], parsed.document);
        editor.retire();
        _host = move(output);
        _document = move(parsed.document);
        return sdlOk();
    }

    /// Maps each live handle to its node's counterpart in `next`, or
    /// removes it (§9).
    private void carryHandles(scope const(SdlReplacedCells)[] replaced,
        scope const TextEdit[] edits, ref const SdlDocument!Allocator next)
    {
        HeapBuffer!uint slots;
        if (_table.liveCount)
            slots.length = next.core.nodes.length;
        const old = (() @trusted => _document.core)();
        const fresh = (() @trusted => next.core)();

        UniqueBuffer!SdlNodeHandle live;
        foreach (handle; _table.byLive)
            live ~= handle;
        foreach (handle; live[])
        {
            const cell = _cellOf[handle.index];
            const target = counterpart(old, fresh, cell, replaced, edits);
            if (target == size_t.max || slots[target])
            {
                _table.remove(handle);
                continue;
            }
            _cellOf[handle.index] = cast(uint) target;
            slots[target] = handle.index + 1;
        }
        _slotOf = move(slots);
    }
}

/** The cell of `next` that is old cell `cell`'s counterpart after `edits`,
or `size_t.max` when an operation replaced it or its anchor no longer starts
a node of its name (editing §9). */
private size_t counterpart(scope const(SdlCore)* old, scope const(SdlCore)* next,
    size_t cell, scope const(SdlReplacedCells)[] replaced, scope const TextEdit[] edits)
    @safe pure nothrow @nogc
{
    if (cell == 0)
        return 0;
    foreach (range; replaced)
        if (cell >= range.first && cell < range.end)
            return size_t.max;
    const was = old.nodes[cell];
    const anchor = mapOffset(edits, was.span.startOffset);
    // Cells after the root are in preorder, so their span starts increase.
    size_t low = 1, high = next.nodes.length;
    while (low < high)
    {
        const mid = low + (high - low) / 2;
        if (next.nodes[mid].span.startOffset < anchor)
            low = mid + 1;
        else
            high = mid;
    }
    if (low == next.nodes.length || next.nodes[low].span.startOffset != anchor
        || next.nodes[low].qualifiedName != was.qualifiedName)
        return size_t.max;
    return low;
}

private auto move(T)(ref T value)
{
    import core.lifetime : move_ = move;

    return move_(value);
}

version (unittest)
{
    import sparkles.wired.sdl.config : sdlDubRecipe;

    private SdlNode child(SdlNode node, size_t index) @safe
    {
        size_t i;
        foreach (c; node.byChild)
            if (i++ == index)
                return c;
        assert(0, "no such child");
    }
}

@("sdl.open_document.handlesFollowTheirNodes")
@system unittest
{
    SdlOpenDocument!() open;
    assert(!open.open("a 1\nb 2 {\n    c 3\n}\nd 4\n", "x.sdl").hasError);
    auto root = open.document.root;
    const a = open.handleOf(child(root, 0)).value;
    const b = open.handleOf(child(root, 1)).value;
    const c = open.handleOf(child(child(root, 1), 0)).value;
    const d = open.handleOf(child(root, 2)).value;
    assert(open.handleOf(child(root, 0)).value == a); // asked twice, one handle
    assert(open.handleCount == 4);

    // Insert before `a` (unindented: at its anchor), change `d`'s value.
    auto editor = open.editor;
    editor.insertBefore(child(root, 0), "z 0");
    editor.replaceValue(child(root, 2), 0, SdlScalar(40));
    assert(!open.commit(editor).hasError);
    assert(open.host == "z 0\na 1\nb 2 {\n    c 3\n}\nd 40\n");
    assert(open.node(a).value.qualifiedName.localName == "a");
    assert(open.node(c).value.qualifiedName.localName == "c");
    assert(open.node(d).value.byValue.front.integer == 40);
    assert(open.node(b).value.childCount == 1);

    // The spent editor fails instead of reading the old document.
    editor.append(open.document.root, "y 1");
    assert(!editor.ok);
}

@("sdl.open_document.replacedNodesGoStale")
@system unittest
{
    import sparkles.base.text.span : TextSpan;

    SdlOpenDocument!() open;
    assert(!open.open("a 1\nb {\n    c 3\n    e 5\n}\nd 4\nf 6\n").hasError);
    auto root = open.document.root;
    const a = open.handleOf(child(root, 0)).value;
    const b = open.handleOf(child(root, 1)).value;
    const c = open.handleOf(child(child(root, 1), 0)).value;
    const d = open.handleOf(child(root, 2)).value;
    const f = open.handleOf(child(root, 3)).value;

    auto editor = open.editor;
    editor.replaceBody(child(root, 1), "c 30");     // b survives, c is replaced
    editor.replaceNode(child(root, 0), "a 10");     // a is replaced
    editor.remove(child(root, 2));                  // d is removed
    const fSpan = child(root, 3).span;
    editor.replaceRegion(TextSpan(fSpan.startOffset, fSpan.startOffset + 1), "f"); // f
    assert(!open.commit(editor).hasError);
    assert(open.host == "a 10\nb {\n    c 30\n}\nf 6\n");

    assert(open.node(b).hasValue);
    foreach (gone; [a, c, d, f])
        assert(open.node(gone).error == PoolError.stale);
    assert(open.handleCount == 1);
    // The node that took `a`'s place gets a handle of its own.
    const a2 = open.handleOf(child(open.document.root, 0)).value;
    assert(a2 != a && open.node(a2).hasValue);

    assert(open.node(SdlNodeHandle.init).error == PoolError.invalid);
    assert(open.node(SdlNodeHandle(99, 1)).error == PoolError.invalid);
}

@("sdl.open_document.anonymousAndEmbedded")
@system unittest
{
    // An anonymous node's anchor is its first value; replacing it keeps the
    // node, since the replacement starts where the value did.
    SdlOpenDocument!() open;
    assert(!open.open("1 2\nx 3\n").hasError);
    const anon = open.handleOf(child(open.document.root, 0)).value;
    auto editor = open.editor;
    editor.replaceValue(child(open.document.root, 0), 0, SdlScalar("one"));
    assert(!open.commit(editor).hasError);
    assert(open.host == "\"one\" 2\nx 3\n");
    assert(open.node(anon).value.byValue.front.stringValue == "one");

    // An embedded recipe: the host is the D program.
    SdlOpenDocument!sdlDubRecipe program;
    enum host = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"p\"\n+/\nvoid main() {}\n";
    assert(!program.open(host, "p.d", SdlHostKind.embedded).hasError);
    const name = program.handleOf(child(program.document.root, 0)).value;
    auto e = program.editor;
    e.append(program.document.root, "version \"1\"");
    assert(!program.commit(e).hasError);
    assert(program.host
        == "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"p\"\n    version \"1\"\n+/\nvoid main() {}\n");
    assert(program.node(name).value.byValue.front.stringValue == "p");
    assert(program.open("void main() {}\n", "q.d", SdlHostKind.embedded).hasError);
}

@("sdl.open_document.failedCommitsChangeNothing")
@system unittest
{
    SdlOpenDocument!() open;
    assert(!open.open("a 1\nb 2\n").hasError);
    const a = open.handleOf(child(open.document.root, 0)).value;
    const b = open.handleOf(child(open.document.root, 1)).value;

    // A good commit, a conflicting one, an invalid fragment, a good one.
    auto first = open.editor;
    first.replaceValue(child(open.document.root, 0), 0, SdlScalar(10));
    assert(!open.commit(first).hasError);

    const before = open.host.idup;
    auto conflicting = open.editor;
    conflicting.replaceValue(child(open.document.root, 0), 0, SdlScalar(11));
    conflicting.replaceValue(child(open.document.root, 0), 0, SdlScalar(12));
    const failed = open.commit(conflicting);
    assert(failed.hasError && failed.error.code == SdlErrorCode.editConflict);
    assert(open.host == before && open.handleCount == 2);
    assert(open.node(a).hasValue && open.node(b).hasValue);

    auto invalid = open.editor;
    invalid.append(open.document.root, "c {");
    assert(open.commit(invalid).hasError);
    assert(open.host == before && open.node(a).hasValue);

    // An editor of another document is refused.
    SdlOpenDocument!() other;
    assert(!other.open("x 1\n").hasError);
    auto foreign = other.editor;
    assert(open.commit(foreign).error.code == SdlErrorCode.editTargetMissing);

    auto last = open.editor;
    last.replaceValue(child(open.document.root, 1), 0, SdlScalar(20));
    assert(!open.commit(last).hasError);
    assert(open.host == "a 10\nb 20\n");
    assert(open.node(a).value.byValue.front.integer == 10);
    assert(open.node(b).value.byValue.front.integer == 20);
}

@("sdl.open_document.unchangedCommitParsesNothing")
@system unittest
{
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator;

    alias Counting = CountingAllocator!();
    AllocationCounts counts;
    auto open = SdlOpenDocument!(sdlFull, Counting)(Counting(&counts));
    enum host = "a 1\nb {\n    c 2\n}\n";
    assert(!open.open(host).hasError);
    const a = open.handleOf(child(open.document.root, 0)).value;
    const c = open.handleOf(child(child(open.document.root, 1), 0)).value;
    const core = open.document.core;
    const calls = counts.calls;

    // The same document, host and handles, and nothing allocated or parsed.
    auto editor = open.editor;
    assert(!open.commit(editor).hasError);
    assert(open.document.core is core && open.host == host && counts.calls == calls);
    assert(open.node(a).value.cellIndex == 1 && open.node(c).value.cellIndex == 3);
    assert(open.handleCount == 2);
    // The editor is spent, as after any commit.
    editor.append(open.document.root, "d 4");
    assert(!editor.ok);
}

@("sdl.open_document.statefulAllocator")
@system unittest
{
    import sparkles.wired.sdl.test_corpus : AllocationCounts, CountingAllocator;

    alias Counting = CountingAllocator!();
    AllocationCounts counts;
    {
        auto open = SdlOpenDocument!(sdlFull, Counting)(Counting(&counts));
        UniqueBuffer!char source;
        foreach (i; 0 .. 4000)
            source ~= "node 1 \"two\" k=3 {\n    leaf on\n}\n";
        assert(!open.open(source[]).hasError);
        const opened = counts;
        SdlNode last;
        foreach (node; open.document.root.byChild)
            last = node;
        const handle = open.handleOf(last).value;

        auto editor = open.editor;
        editor.replaceValue(open.node(handle).value, 0, SdlScalar(10));
        assert(!open.commit(editor).hasError);
        assert(open.node(handle).value.byValue.front.integer == 10);
        // The commit took the region path, which sizes each array once where
        // the opening parse grew them; the replaced document's blocks went.
        assert(counts.calls - opened.calls < opened.calls);
        assert(counts.live == opened.live);

        // An embedded host, through a copy of the same allocator.
        auto program = SdlOpenDocument!(sdlDubRecipe, Counting)(Counting(&counts));
        enum host = "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"p\"\n+/\nvoid main() {}\n";
        assert(!program.open(host, "p.d", SdlHostKind.embedded).hasError);
        auto e = program.editor;
        e.append(program.document.root, "version \"1\"");
        assert(!program.commit(e).hasError);
        assert(program.host
            == "#!/usr/bin/env dub\n/+ dub.sdl:\n    name \"p\"\n    version \"1\"\n+/\nvoid main() {}\n");
    }
    assert(counts.live == 0);
}

@("sdl.open_document.properties.repositoryRecipes")
@system unittest
{
    import std.file : readText;
    import sparkles.wired.sdl.test_corpus : repositoryRecipes;

    // The model: every node, in preorder, as an id with a depth. Each commit
    // applies one operation to the model and to the document; then every
    // model id must be the document's node at its position, with the handle
    // it had (SDE11), and every replaced id's handle must be stale (SDE12).
    static struct Entry
    {
        size_t id;
        uint depth;
    }

    static void preorder(SdlNode node, uint depth, ref SdlNode[] nodes, ref uint[] depths)
    {
        foreach (c; node.byChild)
        {
            nodes ~= c;
            depths ~= depth;
            preorder(c, depth + 1, nodes, depths);
        }
    }

    static size_t subtreeEnd(const Entry[] model, size_t at)
    {
        size_t end = at + 1;
        while (end < model.length && model[end].depth > model[at].depth)
            end++;
        return end;
    }

    enum Op { replaceValue, setAttribute, removeAttribute, remove, insertBefore, appendRoot, replaceBody }

    const paths = repositoryRecipes();
    assert(paths.length > 100, "the repository walk found too few recipes");
    uint state = 0x9E37_79B9;
    uint next(uint bound)
    {
        state = state * 1_103_515_245 + 12_345;
        return (state >> 8) % bound;
    }

    size_t commits, refused, kept, stale;
    foreach (path; paths)
    {
        const text = readText(path);
        SdlOpenDocument!sdlDubRecipe open;
        const kind = path[$ - 2 .. $] == ".d" ? SdlHostKind.embedded : SdlHostKind.recipe;
        if (open.open(text, path, kind).hasError)
            continue; // a JSON recipe, or a fixture that is meant to fail

        Entry[] model;
        SdlNodeHandle[size_t] handles;
        size_t ids;
        SdlNode[] nodes;
        uint[] depths;
        preorder(open.document.root, 0, nodes, depths);
        foreach (i, n; nodes)
        {
            model ~= Entry(ids, depths[i]);
            handles[ids++] = open.handleOf(n).value;
        }

        foreach (round; 0 .. 6)
        {
            nodes = null;
            depths = null;
            preorder(open.document.root, 0, nodes, depths);
            assert(nodes.length == model.length, path);
            auto before = model.dup;
            SdlNodeHandle[] retired;
            auto editor = open.editor;
            const op = cast(Op) next(Op.max + 1);
            const at = nodes.length ? next(cast(uint) nodes.length) : 0;
            final switch (op)
            {
            case Op.replaceValue:
                if (!nodes.length || !nodes[at].valueCount)
                    continue;
                editor.replaceValue(nodes[at], 0, SdlScalar("v"));
                break;
            case Op.setAttribute:
                if (!nodes.length)
                    continue;
                editor.setAttribute(nodes[at], SdlQualifiedName(null, "probe"), SdlScalar("p"));
                break;
            case Op.removeAttribute:
                if (!nodes.length || !nodes[at].attributeCount)
                    continue;
                editor.removeAttribute(nodes[at].byAttribute.front);
                break;
            case Op.remove:
                if (!nodes.length)
                    continue;
                editor.remove(nodes[at]);
                const end = subtreeEnd(model, at);
                foreach (gone; model[at .. end])
                    retired ~= handles[gone.id];
                model = model[0 .. at] ~ model[end .. $];
                break;
            case Op.insertBefore:
                if (!nodes.length)
                    continue;
                editor.insertBefore(nodes[at], `probe "1"`);
                model = model[0 .. at] ~ Entry(ids++, model[at].depth) ~ model[at .. $];
                break;
            case Op.appendRoot:
                editor.append(open.document.root, `probe "2"`);
                model ~= Entry(ids++, 0);
                break;
            case Op.replaceBody:
                if (!nodes.length || !nodes[at].hasBlock)
                    continue;
                editor.replaceBody(nodes[at], `probe "3"`);
                const end = subtreeEnd(model, at);
                foreach (gone; model[at + 1 .. end])
                    retired ~= handles[gone.id];
                model = model[0 .. at + 1] ~ Entry(ids++, model[at].depth + 1) ~ model[end .. $];
                break;
            }
            const host = open.host.idup;
            const committed = open.commit(editor);
            if (committed.hasError)
            {
                // A layout the editor does not support (a one-line block)
                // is refused, and the refusal changes nothing (SDE13).
                assert(committed.error.code == SdlErrorCode.editUnsupportedLayout,
                    path ~ ": " ~ committed.error.reason[].idup);
                assert(open.host == host, path);
                model = before;
                retired = null;
                refused++;
            }
            else
                commits++;

            nodes = null;
            depths = null;
            preorder(open.document.root, 0, nodes, depths);
            assert(nodes.length == model.length, path);
            foreach (i, n; nodes)
            {
                assert(depths[i] == model[i].depth, path);
                const id = model[i].id;
                if (auto h = id in handles)
                {
                    assert(open.handleOf(n).value == *h, path);
                    assert(open.node(*h).value.cellIndex == n.cellIndex, path);
                    kept++;
                }
                else
                    handles[id] = open.handleOf(n).value; // a new node, a new handle
            }
            foreach (h; retired)
            {
                assert(open.node(h).error == PoolError.stale, path);
                stale++;
            }
            assert(open.handleCount == nodes.length, path);
        }
    }
    assert(commits > 500 && stale > 100 && kept > 10_000,
        "the property test exercised too little");
}
