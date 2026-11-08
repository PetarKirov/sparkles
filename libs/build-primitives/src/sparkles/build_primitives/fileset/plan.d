/**
Planning: the start roots of a fileset and its static emptiness (FSA2,
FSA6).

Each fileset node gets a set of literal path prefixes such that every member
lies beneath one of them. A pattern contributes its leading literal
directories; an unanalysable leaf contributes the fileset root itself (`⊤`,
the empty prefix). Union takes the union of the sets, intersection the longer
of each comparable pair (a member of both lies beneath both prefixes, so they
are comparable and it lies beneath the longer), difference its left
operand's. An empty set proves the fileset empty without touching a file
system.

A literal segment becomes part of a root only when no other byte string can
match it under the fileset's matching policy: an ASCII segment, matched
case-sensitively, with none of `K`, `` ` `` or `;`. Matching normalizes to
NFC, whose canonical singletons map U+212A, U+1FEF and U+037E onto exactly
those three characters, so a directory named `Keep` matches the pattern
`Keep` and opening `Keep` directly would miss it. Such a segment stays a name
filter, applied by the directory verdicts after listing; the plan only starts
higher up.

Specified in `docs/specs/build-primitives/filesets/SPEC.md` §6.
*/
module sparkles.build_primitives.fileset.plan;

import sparkles.base.buffer : HeapBuffer;

import sparkles.build_primitives.fileset.pattern : CasePolicy, PatternInfo, Segment, SegmentKind,
    uniqueUnderNfc;
import sparkles.build_primitives.fileset.value : DirVerdict, Fileset, FilesetEvaluator,
    FilesetOp, Filesets;

/**
The plan for one fileset: the directories its resolution starts from, each a
path relative to the fileset root (`""` is the root itself), no one beneath
another, in path order: by component, each by bytes, so `a/b` comes before
`a-c` as the directory `a` comes before `a-c`. That keeps each directory's
descendants together, and is NAR's order of a tree.
*/
struct Plan
{
    @disable this(this);

    private HeapBuffer!char text;
    private HeapBuffer!Span roots_;

    /// The number of start roots.
    size_t length() const @safe pure nothrow @nogc => roots_.length;

    /// The start root `i`.
    const(char)[] opIndex(size_t i) const return scope @safe pure nothrow @nogc
        => text[][roots_[i].start .. roots_[i].start + roots_[i].length];

    /// Whether the prefix lattice proves the fileset empty (FSA6). A
    /// diagnostic, not an error; a fileset can be empty without this.
    bool staticallyEmpty() const @safe pure nothrow @nogc => roots_.length == 0;
}

/// Derives the start roots of `f` (FSA2, FSA6). Allocates; never fails.
Plan plan(ref const Filesets sets, Fileset f) @safe nothrow @nogc
in (f.node < sets.nodes.length, "a fileset from another arena")
{
    Lattice l;

    l.build(sets, f.node);

    Plan p;
    const own = l.sets_[f.node];
    foreach (k; 0 .. own.length)
    {
        const s = l.prefixes[own.start + k];
        p.roots_ ~= Span(p.text.length, s.length);
        p.text ~= l.text[][s.start .. s.start + s.length];
    }
    sortRoots(p);
    return p;
}

///
@("fileset.plan.roots")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    auto p = plan(sets, sets.glob("src/**/*.d").value);
    assert(p.length == 1 && p[0] == "src");

    auto both = plan(sets, sets.union_(sets.glob("src/**").value, sets.glob("libs/**").value));
    assert(both.length == 2 && both[0] == "libs" && both[1] == "src");

    // An unanalysable operand starts at the fileset root, which subsumes the rest.
    auto top = plan(sets, sets.union_(sets.glob("src/**").value, sets.glob("*.md").value));
    assert(top.length == 1 && top[0] == "");

    auto deep = plan(sets, sets.glob("/docs/specs/*/SPEC.md").value);
    assert(deep.length == 1 && deep[0] == "docs/specs");
}

/// FSA6: disjoint literal prefixes prove an intersection empty.
@("fileset.plan.staticallyEmpty")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const src = sets.glob("src/**").value;
    assert(plan(sets, sets.intersection(src, sets.glob("libs/**").value)).staticallyEmpty);
    auto narrowed = plan(sets, sets.intersection(src, sets.glob("src/a/**").value));
    assert(!narrowed.staticallyEmpty && narrowed.length == 1 && narrowed[0] == "src/a");
    assert(plan(sets, sets.nothing).staticallyEmpty);
    assert(plan(sets, sets.difference(sets.nothing, src)).staticallyEmpty);
    assert(!plan(sets, sets.difference(src, sets.everything)).staticallyEmpty,
        "a diagnostic, not a decision procedure");
}

/// A literal that NFC or case folding could match under another spelling is
/// never opened directly.
@("fileset.plan.unsafeLiterals")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    auto kelvin = plan(sets, sets.glob("src/Keep/*.d").value);
    assert(kelvin.length == 1 && kelvin[0] == "src");
    auto accent = plan(sets, sets.glob("café/x/*").value);
    assert(accent.length == 1 && accent[0] == "");

    auto folded = Filesets(CasePolicy.insensitive);
    auto any = plan(folded, folded.glob("src/**").value);
    assert(any.length == 1 && any[0] == "");
}

/**
Whether a literal segment may name a start root: no other byte string
matches it under `policy`.
*/
bool rootSafe(in Segment s, CasePolicy policy) @safe pure nothrow @nogc
{
    if (s.kind != SegmentKind.literal || !s.ascii || policy != CasePolicy.sensitive)
        return false;
    return uniqueUnderNfc(s.text);
}

/**
Writes into `state` the evaluation state of the start root `root`, by entering
each of its components from the fileset root, and returns the root's verdict.
`scratch` must hold `ev.stateWords` words.
*/
DirVerdict rootState(ref FilesetEvaluator ev, ref const Filesets sets, scope const(char)[] root,
    scope ulong[] state, scope ulong[] scratch) @safe nothrow @nogc
in (state.length >= ev.stateWords && scratch.length >= ev.stateWords)
{
    ev.rootState(sets, state);
    auto verdict = ev.dirVerdict(sets, state);
    size_t from;
    foreach (i; 0 .. root.length + 1)
    {
        if (i < root.length && root[i] != '/')
            continue;
        if (i > from)
        {
            if (verdict != DirVerdict.descend)
                return verdict;
            verdict = ev.enter(sets, state, root[from .. i], scratch);
            state[0 .. ev.stateWords] = scratch[0 .. ev.stateWords];
        }
        from = i + 1;
    }
    return verdict;
}

private struct Span
{
    size_t start;
    size_t length;
}

// A node's set: `length` prefixes from `start` in `Lattice.prefixes`.
private struct NodeSet
{
    size_t start;
    size_t length;
    bool built;
}

private struct Lattice
{

    HeapBuffer!char text;
    HeapBuffer!Span prefixes;
    HeapBuffer!NodeSet sets_;

    void build(ref const Filesets sets, uint root) @safe nothrow @nogc
    {
        sets_.length = root + 1;
        foreach (i; 0 .. root + 1)
            node(sets, i);
    }

    void node(ref const Filesets sets, uint i) @safe nothrow @nogc
    {
        const n = sets.nodes[i];
        const start = prefixes.length;
        final switch (n.op)
        {
            case FilesetOp.nothing:
                break;
            case FilesetOp.everything, FilesetOp.executable, FilesetOp.ignored,
                FilesetOp.gitignored:
                prefixes ~= Span(0, 0);
                break;
            case FilesetOp.glob:
                globRoot(sets, sets.patterns[n.a]);
                break;
            case FilesetOp.union_:
                append(sets_[n.a]);
                append(sets_[n.b]);
                break;
            case FilesetOp.intersection:
                const a = sets_[n.a], b = sets_[n.b];
                foreach (x; 0 .. a.length)
                    foreach (y; 0 .. b.length)
                    {
                        const p = prefixes[a.start + x], q = prefixes[b.start + y];
                        if (beneath(q, p))
                            prefixes ~= q;
                        else if (beneath(p, q))
                            prefixes ~= p;
                    }
                break;
            case FilesetOp.difference:
                append(sets_[n.a]);
                break;
        }
        minimize(start);
        sets_[i] = NodeSet(start, prefixes.length - start, true);
    }

    void globRoot(ref const Filesets sets, in PatternInfo p) @safe nothrow @nogc
    {
        if (!p.anchored)
        {
            prefixes ~= Span(0, 0);
            return;
        }
        const start = text.length;
        // Every segment but the last: the last may name the member itself.
        foreach (k; 0 .. p.count - 1)
        {
            const s = sets.patterns.segment(p, k);
            if (!rootSafe(s, sets.casePolicy))
                break;
            if (text.length > start)
                text ~= '/';
            text ~= s.text;
        }
        prefixes ~= Span(start, text.length - start);
    }

    void append(NodeSet s) @safe nothrow @nogc
    {
        foreach (k; 0 .. s.length)
            prefixes ~= prefixes[s.start + k];
    }

    // Drops every prefix at or beneath another of the same set.
    void minimize(size_t start) @safe nothrow @nogc
    {
        size_t kept = start;
        foreach (i; start .. prefixes.length)
        {
            const q = prefixes[i];
            bool covered;
            foreach (j; start .. prefixes.length)
            {
                if (i == j)
                    continue;
                const p = prefixes[j];
                // `q` is covered by a distinct `p` above it, or by an equal
                // one that comes first.
                if (beneath(q, p) && (!same(p, q) || j < i))
                    covered = true;
            }
            if (!covered)
                prefixes[kept++] = q;
        }
        prefixes.length = kept;
    }

    bool same(Span a, Span b) const @safe pure nothrow @nogc
        => text[][a.start .. a.start + a.length] == text[][b.start .. b.start + b.length];

    // Whether `q` is `p` or beneath it, component-wise.
    bool beneath(Span q, Span p) const @safe pure nothrow @nogc
    {
        if (p.length == 0)
            return true;
        if (q.length < p.length)
            return false;
        const a = text[][q.start .. q.start + q.length], b = text[][p.start .. p.start + p.length];
        return a[0 .. b.length] == b && (a.length == b.length || a[b.length] == '/');
    }
}

/// Whether the path `a` comes before `b` component by component: bytes,
/// with the separator below every byte a name can hold.
bool pathBefore(scope const(char)[] a, scope const(char)[] b) @safe pure nothrow @nogc
{
    foreach (i; 0 .. a.length < b.length ? a.length : b.length)
    {
        if (a[i] == b[i])
            continue;
        const x = a[i] == '/' ? 0 : a[i] + 1, y = b[i] == '/' ? 0 : b[i] + 1;
        return x < y;
    }
    return a.length < b.length;
}

///
@("fileset.plan.pathBefore")
@safe pure nothrow @nogc unittest
{
    assert(pathBefore("a/b", "a-c"));
    assert(!pathBefore("a-c", "a/b"));
    assert(pathBefore("a", "a/b"));
    assert(pathBefore("a/z", "a0"));
    assert(pathBefore("", "a"));
    assert(!pathBefore("b", "b"));
}

private void sortRoots(ref Plan p) @safe nothrow @nogc
{
    // Insertion sort: plans have a handful of roots.
    foreach (i; 1 .. p.roots_.length)
    {
        auto x = p.roots_[i];
        size_t j = i;
        while (j > 0 && pathBefore(p.text[][x.start .. x.start + x.length],
                p.text[][p.roots_[j - 1].start .. p.roots_[j - 1].start + p.roots_[j - 1].length]))
        {
            p.roots_[j] = p.roots_[j - 1];
            --j;
        }
        p.roots_[j] = x;
    }
}
