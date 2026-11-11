/**
The fileset value: leaves, the algebra over them, and evaluation
(FSV1–FSV5).

A `Filesets` arena holds every fileset built from it. A `Fileset` is an index
into that arena, so union, intersection and difference are total: they only
append a node (FSV1). There is no complement (FSV2); difference against
`everything()` is its spelling. Construction from patterns is fallible and
returns `FilesetExpected` (FSV5); evaluation is not.

Evaluation is three-valued. A directory gets `DirVerdict.skip` when no file
beneath it can be a member, `acceptAll` when every file beneath it is, and
`descend` otherwise; a file gets `FileVerdict.undecided` when its membership
depends on metadata not yet known (FSA3, FSA4). Each leaf contributes one of
`no`, `maybe`, `yes`; union, intersection and difference combine them as
Kleene's logic does (maximum, minimum, and minimum against the negation), so
every combined verdict is as sound as the leaves' (FSA1).

A directory's evaluation state is a short array of words that the caller
owns: each pattern leaf keeps one word of `PatternSet` positions, each
`.gitignore` leaf one word per rule plus its latch. `FilesetEvaluator.enter`
computes a child's state from its parent's without allocating.

Specified in `docs/specs/build-primitives/filesets/SPEC.md` §4–§6.
*/
module sparkles.build_primitives.fileset.value;

import sparkles.base.buffer : HeapBuffer, UniqueBuffer;
import sparkles.base.unique : Unique, makeUnique;

import sparkles.build_primitives.fileset.ignore : IgnoreDecisionRef, IgnoreScopes, IgnoreState;
import sparkles.build_primitives.fileset.pattern : CasePolicy, FilesetErrorCode, FilesetExpected,
    MatchScratch, PatternSet, filesetErr, filesetOk;

/// A fileset: a node of the `Filesets` arena that built it.
struct Fileset
{
    package uint node = uint.max;

    /// Whether this names a node, rather than being `Fileset.init`.
    bool valid() const @safe pure nothrow @nogc => node != uint.max;
}

/// What a node computes.
enum FilesetOp : ubyte
{
    nothing,      /// no file
    everything,   /// every file
    glob,         /// files a pattern selects (FSG1)
    executable,   /// files with the executable bit; needs a `stat` (FSA4)
    ignored,      /// files a root `.gitignore` excludes
    gitignored,   /// files the `.gitignore` scopes found by a resolution exclude (FSI)
    union_,       ///
    intersection, ///
    difference,   ///
}

/// A three-valued truth: `no` and `yes` are proofs, `maybe` is not.
enum Tri : ubyte
{
    no = 0,    ///
    maybe = 1, ///
    yes = 2,   ///
}

/// The verdict on a directory (FSA3).
enum DirVerdict : ubyte
{
    skip,      /// no file beneath it is a member: do not enumerate it
    descend,   /// enumerate it and evaluate its entries
    acceptAll, /// every file beneath it is a member; no further matching
}

/// The verdict on a file (FSA4).
enum FileVerdict : ubyte
{
    reject,    ///
    undecided, /// membership depends on metadata not yet known
    accept,    ///
}

/// What is known about a file when its verdict is asked for.
struct EntryFacts
{
    bool statKnown;  /// whether the fields below were read
    bool executable; /// meaningful only when `statKnown`

    /// Facts read from a `stat`.
    static EntryFacts stat(bool executable) @safe pure nothrow @nogc
        => EntryFacts(true, executable);
}

/// The verdict a `Tri` stands for, for a directory and for a file.
DirVerdict toDirVerdict(Tri t) @safe pure nothrow @nogc
    => t == Tri.no ? DirVerdict.skip : t == Tri.yes ? DirVerdict.acceptAll : DirVerdict.descend;

/// ditto
FileVerdict toFileVerdict(Tri t) @safe pure nothrow @nogc
    => t == Tri.no ? FileVerdict.reject : t == Tri.yes ? FileVerdict.accept
        : FileVerdict.undecided;

/// One node of the arena. Children always precede their parents.
struct FilesetNode
{
    FilesetOp op; ///
    uint a;       /// left child; a `glob`'s pattern; an `ignored` leaf's first rule
    uint b;       /// right child; an `ignored` leaf's rule count
    uint state;   /// a leaf's first word of directory state
}

/// One rule of an `ignored` leaf.
struct IgnoreRule
{
    uint pattern;  /// into the arena's `PatternSet`
    bool negated;  /// a `!` rule re-includes
    uint line;     /// 1-based line of the rule in its source (FSI3)
}

/**
The arena every fileset is built in. Move-only. Building allocates, from the
process heap; evaluation, through `FilesetEvaluator`, never does.
*/
struct Filesets
{
    @disable this(this);

    package PatternSet patterns;
    package HeapBuffer!FilesetNode nodes;
    package HeapBuffer!IgnoreRule rules;
    private UniqueBuffer!(char[], 4) owned_; // translated `.gitignore` patterns
    private uint stateWords_;
    private uint gitignoredNode_ = uint.max;

    /// An empty arena whose patterns match under `policy` (FSG3).
    this(CasePolicy policy) @safe pure nothrow @nogc
    {
        patterns = PatternSet(policy);
    }

    ~this() @safe nothrow @nogc
    {
        import core.memory : pureFree;

        foreach (s; owned_[])
            (() @trusted => pureFree(s.ptr))();
    }

    /// The matching policy.
    CasePolicy casePolicy() const @safe pure nothrow @nogc => patterns.casePolicy;

    /// Words of directory state an evaluator of this arena needs.
    size_t stateWords() const @safe pure nothrow @nogc => stateWords_;

    /// The node a fileset names.
    FilesetNode opIndex(Fileset f) const @safe pure nothrow @nogc
    in (f.node < nodes.length, "a fileset from another arena")
        => nodes[f.node];

    /// The empty fileset.
    Fileset nothing() @safe pure nothrow @nogc => add(FilesetNode(FilesetOp.nothing));

    /// Every file beneath the root: the universe a difference is taken
    /// against (FSV2).
    Fileset everything() @safe pure nothrow @nogc => add(FilesetNode(FilesetOp.everything));

    /// Every file whose executable bit is set. Deciding it needs a `stat`.
    Fileset executable() @safe pure nothrow @nogc => add(FilesetNode(FilesetOp.executable));

    /**
    The files git's `.gitignore` scopes exclude (FSI1–FSI4): those of the
    fileset root, of each directory between it and a start root, and of every
    directory a resolution enters, each applying to the paths beneath its own
    directory. A resolution reads them as it walks; an excluded directory's
    `.gitignore` is never read. Only a resolution knows the scopes, so
    `FilesetEvaluator.contains`, which has none, finds this leaf empty. Make
    the fileset root the repository's root so its `.gitignore` applies.

    Every call returns the same leaf: an arena has one scope chain per
    resolution.
    */
    Fileset gitignored() @safe pure nothrow @nogc
    {
        if (gitignoredNode_ == uint.max)
            gitignoredNode_ = addLeaf(FilesetNode(FilesetOp.gitignored), 1).node;
        return Fileset(gitignoredNode_);
    }

    /**
    The files `pattern` selects (FSG1): those it matches, and every file
    beneath a directory it matches. The pattern is borrowed and must outlive
    the arena (invariant 3).
    */
    FilesetExpected!Fileset glob(string pattern) @safe nothrow @nogc
    {
        auto p = patterns.add(pattern);
        if (p.hasError)
            return filesetErr!Fileset(p.error.code, p.error.offset, p.error.context);
        return filesetOk(addLeaf(FilesetNode(FilesetOp.glob, p.value), 1));
    }

    /**
    The files a `.gitignore` at the fileset root whose text is `source`
    excludes: within the scope, the last matching rule decides, and nothing
    beneath an excluded directory is re-included (FSI4's first and third
    clauses; nested scopes are `gitignored`'s). Each line is read as git
    reads it (`readIgnoreLine`). The arena keeps its own translation of the
    text. An error's offset is the failing line's, plus the offset within
    its translated pattern.
    */
    FilesetExpected!Fileset ignored(string source) @safe nothrow @nogc
    {
        import sparkles.build_primitives.fileset.ignore : IgnoreLineKind, ignoreLineRoom,
            readIgnoreLine, skipUtf8Bom;

        const first = rules.length;
        auto text = ownText(ignoreLineRoom(source.length));
        size_t used;
        uint line;
        // Git skips a leading byte order mark.
        size_t start = source.length - skipUtf8Bom(source).length;
        foreach (i; 0 .. source.length + 1)
        {
            if (i < source.length && source[i] != '\n')
                continue;
            ++line;
            const lineText = source[start .. i];
            const at = start;
            start = i + 1;
            const read = readIgnoreLine(lineText, text[used .. used + ignoreLineRoom(lineText.length)]);
            if (read.kind == IgnoreLineKind.blank)
                continue;
            // The arena owns the translation until it is destroyed.
            auto pattern = (() @trusted => cast(string) text[used .. used + read.length])();
            used += read.length;
            auto p = patterns.add(pattern);
            if (p.hasError)
            {
                rules.length = first;
                return filesetErr!Fileset(p.error.code, at + p.error.offset, p.error.context);
            }
            rules ~= IgnoreRule(p.value, read.negated, line);
        }
        const count = rules.length - first;
        return filesetOk(addLeaf(FilesetNode(FilesetOp.ignored, cast(uint) first,
            cast(uint) count), 1 + count));
    }

    // Text the arena owns until it is destroyed; `n` bytes, uninitialized.
    private char[] ownText(size_t n) @safe nothrow @nogc
    {
        import core.exception : onOutOfMemoryError;
        import core.memory : pureMalloc;

        if (n == 0)
            return null;
        auto s = (() @trusted {
            auto p = cast(char*) pureMalloc(n);
            return p is null ? null : p[0 .. n];
        })();
        if (s is null)
            onOutOfMemoryError();
        owned_ ~= s;
        return s;
    }

    /// The files in `a` or `b`. Total (FSV1).
    Fileset union_(Fileset a, Fileset b) @safe pure nothrow @nogc
        => add(FilesetNode(FilesetOp.union_, a.node, b.node));

    /// The files in both `a` and `b`. Total (FSV1).
    Fileset intersection(Fileset a, Fileset b) @safe pure nothrow @nogc
        => add(FilesetNode(FilesetOp.intersection, a.node, b.node));

    /// The files in `a` and not in `b`. Total (FSV1).
    Fileset difference(Fileset a, Fileset b) @safe pure nothrow @nogc
        => add(FilesetNode(FilesetOp.difference, a.node, b.node));

    /// The union of every fileset in `sets`; `nothing()` for none.
    Fileset unionOf(scope const Fileset[] sets...) @safe pure nothrow @nogc
    {
        if (sets.length == 0)
            return nothing();
        Fileset acc = sets[0];
        foreach (s; sets[1 .. $])
            acc = union_(acc, s);
        return acc;
    }

    private Fileset add(FilesetNode n) @safe pure nothrow @nogc
    in (n.op < FilesetOp.union_ || (n.a < nodes.length && n.b < nodes.length),
        "a fileset from another arena")
    {
        nodes ~= n;
        return Fileset(cast(uint)(nodes.length - 1));
    }

    private Fileset addLeaf(FilesetNode n, size_t words) @safe pure nothrow @nogc
    {
        n.state = stateWords_;
        stateWords_ += cast(uint) words;
        return add(n);
    }
}

/// FSV1: the algebra is closed and total; FSV2: there is no complement.
@("fileset.value.algebra")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const d = sets.glob("src/**/*.d").value;
    const md = sets.glob("*.md").value;
    const both = sets.union_(d, md);
    const neither = sets.difference(sets.everything, both);
    assert(sets[neither].op == FilesetOp.difference);
    static assert(!__traits(hasMember, Filesets, "complement"));
    static assert(!__traits(hasMember, Filesets, "not"));
    // Composition has no failure mode: its result is a plain `Fileset`.
    static assert(is(typeof(sets.union_(d, md)) == Fileset));
    static assert(is(typeof(sets.intersection(d, md)) == Fileset));
    static assert(is(typeof(sets.difference(d, md)) == Fileset));
}

/// FSV5: building from a pattern is fallible.
@("fileset.value.globFails")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    assert(sets.glob("a/[b").error.code == FilesetErrorCode.malformedPattern);
    assert(sets.ignored("ok\n[z-a]\n").error.code == FilesetErrorCode.malformedPattern);
    assert(sets.rules.length == 0, "a failed leaf leaves no rule behind");
    // An unclosed `[` is no error to git: the line matches nothing.
    assert(!sets.ignored("ok\n[bad\n").hasError);
}

/**
Evaluates one fileset of one arena. It owns the scratch evaluation needs
(the glob engine's workspace and one verdict per node), allocated when it is
made, so no evaluation allocates (invariant 2). Make one per thread.
*/
struct FilesetEvaluator
{
    @disable this(this);

    private Unique!MatchScratch scratch_;
    private HeapBuffer!Tri tri;
    private HeapBuffer!Tri inc; // `tri` with every difference's exclusions set aside
    private HeapBuffer!bool reachable;
    private HeapBuffer!ulong pathState;
    private Fileset root_;
    private size_t words;
    private uint scopeWord_ = uint.max;

    /// Prepares to evaluate `root` of `sets`. Allocates.
    this(ref const Filesets sets, Fileset root) @safe nothrow @nogc
    in (root.node < sets.nodes.length, "a fileset from another arena")
    {
        root_ = root;
        words = sets.stateWords;
        scratch_ = makeUnique!MatchScratch();
        tri.length = root.node + 1;
        inc.length = root.node + 1;
        reachable.length = root.node + 1;
        pathState.length = 2 * words;
        reachable[root.node] = true;
        foreach_reverse (i; 0 .. root.node + 1)
        {
            if (!reachable[i])
                continue;
            const n = sets.nodes[i];
            if (n.op >= FilesetOp.union_)
            {
                reachable[n.a] = true;
                reachable[n.b] = true;
            }
            else if (n.op == FilesetOp.gitignored)
                scopeWord_ = n.state;
        }
    }

    /// The state word of the fileset's `gitignored` leaf, or `uint.max` when it
    /// has none: a resolution reads `.gitignore` files only if it has one.
    uint gitignoredWord() const @safe pure nothrow @nogc => scopeWord_;

    /// The fileset this evaluator evaluates.
    Fileset root() const @safe pure nothrow @nogc => root_;

    /// The words of state one directory needs.
    size_t stateWords() const @safe pure nothrow @nogc => words;

    /// Matching statistics: glob-engine calls and segment comparisons.
    ulong engineCalls() const @safe pure nothrow @nogc => scratch_.get.engineCalls;
    /// ditto
    ulong segmentMatches() const @safe pure nothrow @nogc => scratch_.get.segmentMatches;

    /// Writes the state of the fileset root into `state`.
    void rootState(ref const Filesets sets, scope ulong[] state) @safe nothrow @nogc
    in (state.length >= words)
    {
        state[] = 0;
        foreach (i; 0 .. root_.node + 1)
        {
            if (!reachable[i])
                continue;
            const n = sets.nodes[i];
            if (n.op == FilesetOp.glob)
                state[n.state] = sets.patterns.start(n.a);
            else if (n.op == FilesetOp.ignored)
                foreach (r; 0 .. n.b)
                    state[n.state + 1 + r] = sets.patterns.start(sets.rules[n.a + r].pattern);
            else if (n.op == FilesetOp.gitignored)
                state[n.state] = IgnoreState.init.word;
        }
    }

    /// The verdict on a directory whose state is `state`.
    DirVerdict dirVerdict(ref const Filesets sets, scope const ulong[] state) @safe nothrow @nogc
    in (state.length >= words)
    {
        foreach (i; 0 .. root_.node + 1)
        {
            if (!reachable[i])
                continue;
            const n = sets.nodes[i];
            Tri t;
            final switch (n.op)
            {
                case FilesetOp.nothing: t = Tri.no; break;
                case FilesetOp.everything: t = Tri.yes; break;
                case FilesetOp.executable: t = Tri.maybe; break;
                case FilesetOp.glob:
                    const s = state[n.state];
                    t = (s & PatternSet.matchedBit) ? Tri.yes : s == 0 ? Tri.no : Tri.maybe;
                    break;
                case FilesetOp.ignored:
                    t = state[n.state] ? Tri.yes : n.b == 0 ? Tri.no : Tri.maybe;
                    break;
                case FilesetOp.gitignored:
                    // A deeper `.gitignore` may yet exclude what is not
                    // excluded already.
                    t = IgnoreState(state[n.state]).excluded ? Tri.yes : Tri.maybe;
                    break;
                case FilesetOp.union_, FilesetOp.intersection, FilesetOp.difference:
                    t = combine(n, tri[n.a], tri[n.b]);
                    break;
            }
            tri[i] = t;
            inc[i] = n.op == FilesetOp.difference ? inc[n.a]
                : n.op >= FilesetOp.union_ ? combine(n, inc[n.a], inc[n.b]) : t;
        }
        return toDirVerdict(tri[root_.node]);
    }

    /**
    Whether the fileset selects the whole content of the directory last given
    a verdict by `dirVerdict` or `enter`, once every difference's excluded
    side is set aside: the reading of "the selection holds this empty
    directory" FSV4 reports by (D5). `src/**` and `everything - gitignored`
    select a directory's whole content; `*.md` does not.
    */
    bool wholeContent() const @safe pure nothrow @nogc => inc[root_.node] == Tri.yes;

    /**
    Computes into `child` the state of the directory `name` in a directory
    whose state is `parent`, and returns the child's verdict.
    */
    DirVerdict enter(ref const Filesets sets, scope const ulong[] parent, scope const(char)[] name,
        scope ulong[] child) @safe nothrow @nogc
        => enterIn(sets, null, parent, name, child);

    /// ditto, stepping the `gitignored` leaf through `scopes`, which must have
    /// room for the child's block (`IgnoreScopes.overflowed` says when not).
    DirVerdict enter(ref const Filesets sets, ref IgnoreScopes scopes, scope const ulong[] parent,
        scope const(char)[] name, scope ulong[] child) @safe nothrow @nogc
        => enterIn(sets, &scopes, parent, name, child);

    private DirVerdict enterIn(ref const Filesets sets, scope IgnoreScopes* scopes,
        scope const ulong[] parent, scope const(char)[] name, scope ulong[] child) @safe nothrow @nogc
    in (parent.length >= words && child.length >= words)
    {
        foreach (i; 0 .. root_.node + 1)
        {
            if (!reachable[i])
                continue;
            const n = sets.nodes[i];
            if (n.op == FilesetOp.glob)
                child[n.state] = sets.patterns.enterDir(n.a, parent[n.state], name, *scratch_);
            else if (n.op == FilesetOp.ignored)
                enterIgnored(sets, n, parent, name, child);
            else if (n.op == FilesetOp.gitignored)
            {
                IgnoreState c = IgnoreState(parent[n.state]);
                if (scopes !is null && scopes.ready)
                    cast(void) scopes.enter(IgnoreState(parent[n.state]), name, *scratch_, c);
                child[n.state] = c.word;
            }
        }
        return dirVerdict(sets, child);
    }

    /// The verdict on the non-directory `name` in a directory whose state is
    /// `state`, given `facts` (FSA4).
    FileVerdict fileVerdict(ref const Filesets sets, scope const ulong[] state,
        scope const(char)[] name, EntryFacts facts) @safe nothrow @nogc
        => fileVerdictIn(sets, null, state, name, facts);

    /// ditto, deciding the `gitignored` leaf through `scopes`.
    FileVerdict fileVerdict(ref const Filesets sets, ref IgnoreScopes scopes,
        scope const ulong[] state, scope const(char)[] name, EntryFacts facts) @safe nothrow @nogc
        => fileVerdictIn(sets, &scopes, state, name, facts);

    /**
    The rule of `scopes` deciding the entry `name` (a directory when `isDir`)
    in a directory whose state is `state`, for tracing (FSI3). Undecided when
    the fileset has no `gitignored` leaf, and beneath an excluded directory.
    */
    IgnoreDecisionRef ignoreDecision(ref const IgnoreScopes scopes, scope const ulong[] state,
        scope const(char)[] name, bool isDir) @safe nothrow @nogc
    {
        if (scopeWord_ == uint.max || !scopes.ready)
            return IgnoreDecisionRef.init;
        const st = IgnoreState(state[scopeWord_]);
        return isDir ? scopes.decideDir(st, name, *scratch_) : scopes.decideFile(st, name, *scratch_);
    }

    private FileVerdict fileVerdictIn(ref const Filesets sets, scope IgnoreScopes* scopes,
        scope const ulong[] state, scope const(char)[] name, EntryFacts facts) @safe nothrow @nogc
    in (state.length >= words)
    {
        foreach (i; 0 .. root_.node + 1)
        {
            if (!reachable[i])
                continue;
            const n = sets.nodes[i];
            Tri t;
            final switch (n.op)
            {
                case FilesetOp.nothing: t = Tri.no; break;
                case FilesetOp.everything: t = Tri.yes; break;
                case FilesetOp.executable:
                    t = !facts.statKnown ? Tri.maybe : facts.executable ? Tri.yes : Tri.no;
                    break;
                case FilesetOp.glob:
                    t = sets.patterns.matchesFile(n.a, state[n.state], name, *scratch_)
                        ? Tri.yes : Tri.no;
                    break;
                case FilesetOp.ignored:
                    t = ignoresFile(sets, n, state, name) ? Tri.yes : Tri.no;
                    break;
                case FilesetOp.gitignored:
                    const st = IgnoreState(state[n.state]);
                    t = st.excluded || (scopes !is null && scopes.ready
                        && scopes.excludesFile(st, name, *scratch_)) ? Tri.yes : Tri.no;
                    break;
                case FilesetOp.union_, FilesetOp.intersection, FilesetOp.difference:
                    t = combine(n, tri[n.a], tri[n.b]);
                    break;
            }
            tri[i] = t;
        }
        return toFileVerdict(tri[root_.node]);
    }

    /**
    The verdict on the file at `path`, relative to the fileset root, given
    `facts`. Walks the path's directories; never fails (FSV5).
    */
    FileVerdict verdictOf(ref const Filesets sets, scope const(char)[] path, EntryFacts facts)
        @safe nothrow @nogc
    {
        auto a = pathState[0 .. words], b = pathState[words .. 2 * words];
        rootState(sets, a);
        size_t from = 0;
        foreach (i, c; path)
        {
            if (c != '/')
                continue;
            if (i > from)
            {
                if (enter(sets, a, path[from .. i], b) == DirVerdict.skip)
                    return FileVerdict.reject;
                auto t = a;
                a = b;
                b = t;
            }
            from = i + 1;
        }
        return fileVerdict(sets, a, path[from .. $], facts);
    }

    /**
    The verdict on the directory at `path`, relative to the fileset root
    (`""` for the root): `skip` when no file beneath it can be a member.
    Walks the path's directories; never fails (FSV5).
    */
    DirVerdict dirVerdictOf(ref const Filesets sets, scope const(char)[] path) @safe nothrow @nogc
    {
        auto a = pathState[0 .. words], b = pathState[words .. 2 * words];
        rootState(sets, a);
        DirVerdict d = dirVerdict(sets, a);
        size_t from = 0;
        foreach (i; 0 .. path.length + 1)
        {
            if (i < path.length && path[i] != '/')
                continue;
            if (i > from)
            {
                d = enter(sets, a, path[from .. i], b);
                if (d == DirVerdict.skip)
                    return d;
                auto t = a;
                a = b;
                b = t;
            }
            from = i + 1;
        }
        return d;
    }

    /// Whether the file at `path` with the executable bit `executable` is a
    /// member (FSV5: a value, never an error).
    bool contains(ref const Filesets sets, scope const(char)[] path, bool executable = false)
        @safe nothrow @nogc
        => verdictOf(sets, path, EntryFacts.stat(executable)) == FileVerdict.accept;

    private void enterIgnored(ref const Filesets sets, in FilesetNode n, scope const ulong[] parent,
        scope const(char)[] name, scope ulong[] child) @safe nothrow @nogc
    {
        if (parent[n.state])
        {
            child[n.state .. n.state + 1 + n.b] = parent[n.state .. n.state + 1 + n.b];
            return;
        }
        bool excluded;
        foreach (r; 0 .. n.b)
        {
            const rule = sets.rules[n.a + r];
            const next = sets.patterns.step(rule.pattern, parent[n.state + 1 + r], name, *scratch_);
            child[n.state + 1 + r] = next;
            if (sets.patterns.complete(rule.pattern, next))
                excluded = !rule.negated;
        }
        child[n.state] = excluded ? 1 : 0;
    }

    private bool ignoresFile(ref const Filesets sets, in FilesetNode n, scope const ulong[] state,
        scope const(char)[] name) @safe nothrow @nogc
    {
        if (state[n.state])
            return true;
        bool excluded;
        foreach (r; 0 .. n.b)
        {
            const rule = sets.rules[n.a + r];
            if (sets.patterns[rule.pattern].dirOnly)
                continue;
            const next = sets.patterns.step(rule.pattern, state[n.state + 1 + r], name, *scratch_);
            if (sets.patterns.complete(rule.pattern, next))
                excluded = !rule.negated;
        }
        return excluded;
    }
}

///
@("fileset.value.contains")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const sources = sets.difference(sets.glob("src/**/*.d").value, sets.glob("**/gen/").value);
    auto ev = FilesetEvaluator(sets, sources);
    assert(ev.contains(sets, "src/a.d"));
    assert(ev.contains(sets, "src/x/b.d"));
    assert(!ev.contains(sets, "src/gen/c.d"));
    assert(!ev.contains(sets, "lib/a.d"));
}

/// FSV3: a pattern naming a directory selects the files beneath it.
@("fileset.value.directoryNamesSubtree")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const docs = sets.glob("docs").value;
    auto ev = FilesetEvaluator(sets, docs);
    assert(ev.contains(sets, "docs/a/b.md"));
    assert(ev.contains(sets, "x/docs/c"));
    assert(ev.contains(sets, "docs"), "a file named docs matches too");
}

/// FSA3 and FSA4: directory and file verdicts.
@("fileset.value.verdicts")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const tree = sets.glob("vendor/**").value;
    const scripts = sets.intersection(sets.glob("bin/*").value, sets.executable);
    const f = sets.union_(tree, scripts);
    auto ev = FilesetEvaluator(sets, f);
    ulong[8] root, child;
    ev.rootState(sets, root[]);
    assert(ev.enter(sets, root[], "vendor", child[]) == DirVerdict.acceptAll);
    assert(ev.enter(sets, root[], "docs", child[]) == DirVerdict.skip);
    assert(ev.enter(sets, root[], "bin", child[]) == DirVerdict.descend);
    assert(ev.fileVerdict(sets, child[], "run", EntryFacts.init) == FileVerdict.undecided);
    assert(ev.fileVerdict(sets, child[], "run", EntryFacts.stat(true)) == FileVerdict.accept);
    assert(ev.fileVerdict(sets, child[], "run", EntryFacts.stat(false)) == FileVerdict.reject);
}

/// The `.gitignore` leaf: last rule wins, and an excluded directory stays
/// excluded beneath.
@("fileset.value.ignored")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const ign = sets.ignored("# build output\n*.o\n!keep.o\nbuild/\n!build/x.c\n").value;
    auto ev = FilesetEvaluator(sets, ign);
    assert(ev.contains(sets, "a/b.o"));
    assert(!ev.contains(sets, "a/keep.o"));
    assert(ev.contains(sets, "build/y.c"));
    assert(ev.contains(sets, "build/x.c"), "no re-inclusion beneath an excluded directory");
    assert(!ev.contains(sets, "src/x.c"));
    assert(sets.rules[2].line == 4, "rules keep their line (FSI3)");
}

/// The `.gitignore` leaf reads each line as git does: braces are literal,
/// `\!` escapes, an escaped trailing space stays and a trailing tab is kept.
@("fileset.value.ignoredReadsAsGit")
@safe nothrow @nogc unittest
{
    auto sets = Filesets(CasePolicy.sensitive);
    const ign = sets.ignored("\\!bang\n*.{c,h}\nkeep\\ \nspaced   \ntab\t\n").value;
    auto ev = FilesetEvaluator(sets, ign);
    assert(ev.contains(sets, "!bang"));
    assert(ev.contains(sets, "a.{c,h}") && !ev.contains(sets, "a.c"));
    assert(ev.contains(sets, "keep ") && !ev.contains(sets, "keep"));
    assert(ev.contains(sets, "spaced"));
    assert(ev.contains(sets, "tab\t") && !ev.contains(sets, "tab"));

    // Bracket expressions as `git check-ignore` reads them.
    const cls = sets.ignored("[[:digit:]].o\n[]a].b\n[^x].c\n[[:graph:]].d\n").value;
    auto classes = FilesetEvaluator(sets, cls);
    assert(classes.contains(sets, "1.o") && !classes.contains(sets, "a.o"));
    assert(classes.contains(sets, "a.b") && classes.contains(sets, "].b") && !classes.contains(sets, "c.b"));
    assert(classes.contains(sets, "y.c") && !classes.contains(sets, "x.c"));
    assert(classes.contains(sets, "!.d") && classes.contains(sets, "z.d") && !classes.contains(sets, " .d"));
}

private Tri combine(in FilesetNode n, Tri a, Tri b) @safe pure nothrow @nogc
{
    import std.algorithm.comparison : max, min;

    switch (n.op)
    {
        case FilesetOp.union_: return max(a, b);
        case FilesetOp.intersection: return min(a, b);
        default: return min(a, cast(Tri)(Tri.yes - b));
    }
}
