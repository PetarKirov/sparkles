/**
Small vendored utilities the `semvisitor` port (`sparkles.dmd_lsp.visitor`)
depends on.

Ported from $(LINK2 https://github.com/dlang/visuald, Visual D) — Copyright
(c) 2012 by Rainer Schuetze, distributed under the Boost Software License,
Version 1.0:

$(LIST
    * `TypeReferenceKind` — `vdc/ivdserver.d`
    * `DenseSet` — `stdext/denseset.d`
    * `contains` — `stdext/array.d`
)

Only the declarations `visitor.d` actually uses are vendored; the rest of
those modules is Visual-Studio integration and stays upstream.
*/
module sparkles.dmd_lsp.support;

/**
The identifier categories the type oracle classifies spans into (`vdc.ivdserver`).

Kept verbatim, including `Package = Module` (upstream's `// todo`): the
duplicate lets the visitor spell the intent at the call site even though the
two collapse to one value.
*/
enum TypeReferenceKind : uint
{
    Unknown,

    Interface,
    Enum,
    EnumValue,
    Template,
    Class,
    Struct,
    Union,
    TemplateTypeParameter,

    Constant,
    LocalVariable,
    ParameterVariable,
    TLSVariable,
    SharedVariable,
    GSharedVariable,
    MemberVariable,
    Variable,

    Alias,
    Module,
    Package = Module, // todo
    Function,
    Method,
    BasicType,

    DebugIdentifier,
    VersionIdentifier,
}

import core.memory : GC; // DenseSet's default allocator

/**
An open-addressed identity set of reference types (`stdext.denseset`).

The visitor uses it as the "already walked this node" marker across an AST
that is a DAG rather than a tree, so hashing the *address* is exactly right.
*/
struct DenseSet(T, ALLOC = GC)
{
    static assert(is(T == class)); // only reference objects

    ~this()
    {
        if (entries)
            ALLOC.free(entries);
    }

    bool contains(T p)
    {
        return findSlot(cast(S) cast(void*) p) !is null;
    }

    bool insert(T p)
    {
        if (dim == 0)
            rehash(16);
        else if (used >= dim / 2)
            // Deviation from upstream, which grows only in `findSlot`. That is
            // sound for the visitor, whose every `insert` is guarded by a
            // `contains`, but leaves `insert` on its own spinning forever in
            // `findSlotInsert`'s probe loop once the table fills. Growing here
            // too cannot change the guarded callers' behaviour — it only moves
            // a rehash the next `contains` would have done anyway.
            rehash(dim * 2);
        return findSlotInsert(cast(S) cast(void*) p) !is null;
    }

    bool remove(T p)
    {
        auto pp = findSlot(cast(S) cast(void*) p);
        if (!pp)
            return false;
        *pp = entryDeleted;
        deleted++;
        return true;
    }

private:
    S* findSlot(S p)
    {
        if (dim == 0)
            return null;
        else if (used >= dim / 2)
            rehash(dim * 2);

        size_t off = calcHash(p) & (dim - 1);
        for (int j = 1;; ++j)
        {
            if (entries[off] == p)
                return entries + off;
            if (!entries[off])
                return null;
            off = (off + j) & (dim - 1);
        }
    }

    S* findSlotInsert(S p)
    {
        S* del = null;
        size_t off = calcHash(p) & (dim - 1);
        for (int j = 1;; ++j)
        {
            if (entries[off] == p)
                return entries + off;

            if (!del && entries[off] == entryDeleted)
                // remember the first deleted entry
                del = entries + off;

            if (!entries[off])
            {
                if (del)
                {
                    *del = p;
                    deleted--;
                    return del;
                }
                entries[off] = p;
                used++;
                return entries + off;
            }
            off = (off + j) & (dim - 1);
        }
    }

    size_t calcHash(S p)
    {
        size_t addr = p;
        return addr ^ (addr >>> 4);
    }

    void rehash(size_t sz)
    {
        assert((sz & (sz - 1)) == 0);
        assert(sz > used - deleted);
        S* oentries = entries;
        entries = cast(S*) ALLOC.calloc(sz * S.sizeof);
        size_t odim = dim;

        dim = sz;
        used = 0;
        deleted = 0;
        for (int i = 0; i < odim; i++)
        {
            if (oentries[i] && oentries[i] != entryDeleted)
                findSlotInsert(oentries[i]);
        }
        ALLOC.free(oentries);
    }

    alias S = size_t;
    enum entryDeleted = cast(S) ~0;

    size_t dim;
    size_t used;
    size_t deleted;

    S* entries;
}

@("dmd_lsp.support.DenseSet.identity")
@system unittest
{
    static class Node {}

    DenseSet!Node set;
    auto a = new Node;
    auto b = new Node;

    assert(!set.contains(a));
    set.insert(a);
    assert(set.contains(a));
    assert(!set.contains(b));

    set.insert(b);
    assert(set.contains(b));
    assert(set.remove(a));
    assert(!set.contains(a));
    assert(set.contains(b));
}

@("dmd_lsp.support.DenseSet.growth")
@system unittest
{
    static class Node {}

    // Well past the initial 16 slots, through repeated rehashes.
    DenseSet!Node set;
    Node[] nodes;
    foreach (_; 0 .. 200)
    {
        auto n = new Node;
        nodes ~= n;
        set.insert(n);
    }
    foreach (n; nodes)
        assert(set.contains(n));
}

@("dmd_lsp.support.DenseSet.visitorProtocol")
@system unittest
{
    static class Node {}

    // How the visitor uses it: check, then insert, and never re-walk.
    DenseSet!Node set;
    Node[] nodes;
    foreach (_; 0 .. 200)
        nodes ~= new Node;

    size_t walked;
    foreach (_; 0 .. 3)
        foreach (n; nodes)
        {
            if (set.contains(n))
                continue;
            set.insert(n);
            walked++;
        }
    assert(walked == nodes.length);
}

/// Linear search by value (`stdext.array`); returns a pointer to the element,
/// or `null`. The visitor uses it to de-duplicate reference hits.
T* contains(T)(T[] arr, T val)
{
    foreach (ref t; arr)
        if (t == val)
            return &t;
    return null;
}

@("dmd_lsp.support.contains")
@safe unittest
{
    int[] xs = [1, 2, 3];
    assert(xs.contains(2) is &xs[1]);
    assert(xs.contains(4) is null);
}
