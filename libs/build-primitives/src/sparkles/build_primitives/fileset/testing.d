/**
The fileset oracles of SPEC.md §12, and the fixture set they run over.

$(UL
    $(LI `naiveContains` interprets a fileset by backtracking over the pattern
        source text, independently of `PatternSet`'s compiled automata: the
        brute-force oracle's predicate.)
    $(LI `bruteForceFiles` enumerates every non-directory beneath a root,
        ignoring every verdict: the brute-force walk.)
    $(LI `fixtureSet` is the hand-written fixtures, and `randomFixture` a
        seeded generator of trees and filesets, so the gates run over many
        more shapes than anyone writes by hand.)
)

Test support only: excluded from the library configuration. The oracle is
written for ASCII names and patterns; Unicode matching is pinned by
`pattern.d`'s own tests.
*/
module sparkles.build_primitives.fileset.testing;

import std.algorithm.searching : canFind;
import std.array : join, split;
import std.ascii : toLower;
import std.conv : octal, text, to;
import std.random : Mt19937, uniform;

import sparkles.base.io.errors : ErrorKind;
import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : EntryKind, Rights;

import sparkles.build_primitives.fileset.driver : PathCollector, resolve, resolveWith;
import sparkles.build_primitives.fileset.fso : EntryOrder, FsoMetadata, Traversal;
import sparkles.build_primitives.fileset.machine : ResolutionErrorCode, ResolutionLimits;
import sparkles.build_primitives.fileset.pattern : CasePolicy;
import sparkles.build_primitives.fileset.value : Fileset, FilesetOp, Filesets;

/// One non-directory found by a walk.
struct FoundFile
{
    string path;     /// relative to the walk's root
    EntryKind kind;  /// `regular` or `symlink`
    bool executable; ///
}

/**
Every non-directory beneath `dir`, depth first, in byte order of path,
ignoring every verdict: the brute-force walk. Links are never followed.
*/
FoundFile[] bruteForceFiles(V, Rights R)(DirRef!(V, R) dir, string prefix = "")
{
    import std.algorithm.sorting : sort;

    FoundFile[] found;
    string[] subdirs;
    auto listing = dir.list();
    assert(!listing.hasError, "brute-force walk: list failed");
    for (;;)
    {
        auto more = listing.value.next();
        assert(!more.hasError, "brute-force walk: list failed");
        if (!more.value)
            break;
        auto e = listing.value.front;
        const name = e.name.idup;
        auto kind = e.kind;
        bool exec;
        auto st = dir.statAt(name);
        assert(!st.hasError, "brute-force walk: stat failed");
        kind = st.value.kind;
        exec = kind == EntryKind.regular && st.value.executable;
        if (kind == EntryKind.directory)
            subdirs ~= name;
        else if (kind == EntryKind.regular || kind == EntryKind.symlink)
            found ~= FoundFile(prefix ~ name, kind, exec);
    }
    foreach (name; subdirs)
    {
        auto child = dir.openDir(name);
        assert(!child.hasError, "brute-force walk: openDir failed");
        found ~= bruteForceFiles(child.value.borrow, prefix ~ name ~ "/");
    }
    found.sort!((a, b) => a.path < b.path);
    return found;
}

/**
Whether `path` is a member of `f`, by backtracking over each pattern's source
text: the brute-force oracle's predicate, sharing nothing with `PatternSet`
but the sources and the arena's node structure.
*/
bool naiveContains(ref const Filesets sets, Fileset f, string path, bool executable) @safe
{
    const fold = sets.casePolicy == CasePolicy.insensitive;
    auto comps = path.split('/');
    bool eval(uint node)
    {
        const n = sets.nodes[node];
        final switch (n.op)
        {
            case FilesetOp.nothing: return false;
            case FilesetOp.everything: return true;
            case FilesetOp.executable: return executable;
            // The scopes are known only to a resolution; a path alone has none.
            case FilesetOp.gitignored: return false;
            case FilesetOp.union_: return eval(n.a) || eval(n.b);
            case FilesetOp.intersection: return eval(n.a) && eval(n.b);
            case FilesetOp.difference: return eval(n.a) && !eval(n.b);
            case FilesetOp.glob:
                const src = sets.patterns[n.a].source;
                foreach (k; 1 .. comps.length + 1)
                    if (matchesExactly(src, comps[0 .. k], k < comps.length, fold))
                        return true;
                return false;
            case FilesetOp.ignored:
                // Git's rule: an excluded directory excludes everything
                // beneath it; otherwise the last matching rule decides.
                foreach (k; 1 .. comps.length + 1)
                {
                    const isDir = k < comps.length;
                    int decision = -1;
                    foreach (r; 0 .. n.b)
                    {
                        const rule = sets.rules[n.a + r];
                        if (matchesExactly(sets.patterns[rule.pattern].source, comps[0 .. k],
                                isDir, fold))
                            decision = rule.negated ? 0 : 1;
                    }
                    if (decision == 1)
                        return true;
                }
                return false;
        }
    }
    return eval(f.node);
}

/// Whether the pattern `source` matches exactly the path `comps`, a
/// directory when `isDir`.
bool matchesExactly(string source, const(string)[] comps, bool isDir, bool fold) @safe
{
    auto p = source;
    bool dirOnly, anchored;
    if (p.length && p[$ - 1] == '/')
    {
        dirOnly = true;
        p = p[0 .. $ - 1];
    }
    if (p.length && p[0] == '/')
    {
        anchored = true;
        p = p[1 .. $];
    }
    if (p.canFind('/'))
        anchored = true;
    if (dirOnly && !isDir)
        return false;
    auto segs = p.split('/');
    if (!anchored)
        segs = "**" ~ segs;
    return segmentsMatch(segs, comps, fold);
}

private bool segmentsMatch(const(string)[] ps, const(string)[] xs, bool fold) @safe
{
    if (ps.length == 0)
        return xs.length == 0;
    if (ps[0] == "**")
        return segmentsMatch(ps[1 .. $], xs, fold)
            || (xs.length > 0 && segmentsMatch(ps, xs[1 .. $], fold));
    return xs.length > 0 && wildmatch(ps[0], xs[0], fold) && segmentsMatch(ps[1 .. $], xs[1 .. $], fold);
}

/// A backtracking matcher for one component: `*`, `?`, `[…]` with `!` or
/// `^`, `{a,b}`, and `\` escapes.
bool wildmatch(string p, string s, bool fold) @safe
{
    // Braces first: expand the first top-level group.
    {
        size_t open = size_t.max;
        int depth;
        for (size_t i = 0; i < p.length; ++i)
        {
            if (p[i] == '\\')
            {
                ++i;
                continue;
            }
            if (p[i] == '[')
            {
                // Skip a class, whose braces are literal.
                size_t j = i + 1;
                if (j < p.length && (p[j] == '!' || p[j] == '^'))
                    ++j;
                if (j < p.length && p[j] == ']')
                    ++j;
                while (j < p.length && p[j] != ']')
                    ++j;
                i = j;
                continue;
            }
            if (p[i] == '{')
            {
                if (depth == 0)
                    open = i;
                ++depth;
            }
            else if (p[i] == '}' && depth > 0)
            {
                --depth;
                if (depth == 0)
                {
                    string[] alts;
                    size_t from = open + 1;
                    int d;
                    for (size_t k = open + 1; k < i; ++k)
                    {
                        if (p[k] == '\\')
                        {
                            ++k;
                            continue;
                        }
                        if (p[k] == '{')
                            ++d;
                        else if (p[k] == '}')
                            --d;
                        else if (p[k] == ',' && d == 0)
                        {
                            alts ~= p[from .. k];
                            from = k + 1;
                        }
                    }
                    alts ~= p[from .. i];
                    foreach (alt; alts)
                        if (wildmatch(p[0 .. open] ~ alt ~ p[i + 1 .. $], s, fold))
                            return true;
                    return false;
                }
            }
        }
    }
    return simpleMatch(p, s, fold);
}

private bool simpleMatch(string p, string s, bool fold) @safe
{
    if (p.length == 0)
        return s.length == 0;
    switch (p[0])
    {
        case '*':
            foreach (k; 0 .. s.length + 1)
                if (simpleMatch(p[1 .. $], s[k .. $], fold))
                    return true;
            return false;
        case '?':
            return s.length > 0 && simpleMatch(p[1 .. $], s[1 .. $], fold);
        case '[':
            if (s.length == 0)
                return false;
            size_t j = 1;
            bool negated;
            if (j < p.length && (p[j] == '!' || p[j] == '^'))
            {
                negated = true;
                ++j;
            }
            bool found;
            char c = fold ? toLower(s[0]) : s[0];
            while (j < p.length && p[j] != ']')
            {
                char lo = p[j];
                if (lo == '\\' && j + 1 < p.length)
                    lo = p[++j];
                char hi = lo;
                if (j + 2 < p.length && p[j + 1] == '-' && p[j + 2] != ']')
                {
                    hi = p[j + 2];
                    if (hi == '\\' && j + 3 < p.length)
                        hi = p[++j + 2];
                    j += 2;
                }
                if (fold)
                {
                    lo = toLower(lo);
                    hi = toLower(hi);
                }
                if (c >= lo && c <= hi)
                    found = true;
                ++j;
            }
            if (found == negated)
                return false;
            return simpleMatch(p[j + 1 .. $], s[1 .. $], fold);
        case '\\':
            if (p.length < 2)
                return false;
            goto default;
        default:
            const lit = p[0] == '\\' ? p[1] : p[0];
            const adv = p[0] == '\\' ? 2 : 1;
            if (s.length == 0)
                return false;
            if (fold ? toLower(lit) != toLower(s[0]) : lit != s[0])
                return false;
            return simpleMatch(p[adv .. $], s[1 .. $], fold);
    }
}

@("fileset.testing.wildmatch")
@safe unittest
{
    assert(wildmatch("*.d", "a.d", false));
    assert(!wildmatch("*.d", "a.dd", false));
    assert(wildmatch("{x,y}.*", "y.md", false));
    assert(wildmatch("[ab]*", "b", false));
    assert(!wildmatch("[!ab]*", "b", false));
    assert(wildmatch("A.MD", "a.md", true));
    assert(matchesExactly("src/*.d", ["src", "x.d"], false, false));
    assert(!matchesExactly("src/*.d", ["lib", "src", "x.d"], false, false));
    assert(matchesExactly("*.md", ["a", "b.md"], false, false));
    assert(!matchesExactly("/*.md", ["a", "b.md"], false, false));
}

// ------------------------------------------------------------------ fixtures

/// A fixture: a tree literal and the filesets to resolve against it.
struct Fixture
{
    string name;                              ///
    string tree;                              /// a tree literal
    CasePolicy policy;                        ///
    Fileset delegate(ref Filesets) @safe[] filesets; ///
}

/// The hand-written fixtures.
Fixture[] fixtureSet() @safe
{
    Fixture[] all;

    Fileset g(ref Filesets s, string p) @safe
    {
        auto r = s.glob(p);
        assert(!r.hasError, p);
        return r.value;
    }

    enum project = `
        README.md = hello
        docs/index.md
        docs/guide/a.md
        docs/empty/
        src/a.d
        src/x/b.d
        src/x/gen/c.d
        src/run.sh +x
        lib/src/y.d
        lib/z.md
        build/out.o
        build/obj/x.o
        build/keep.txt
        bin/tool +x
        bin/notes
        link -> src
        a.b/x
        a/x
        a.md/inner.txt
    `;
    all ~= Fixture("project", project, CasePolicy.sensitive, [
        delegate(ref Filesets s) => g(s, "*.md"),
        delegate(ref Filesets s) => g(s, "src/*.d"),
        delegate(ref Filesets s) => g(s, "/*.md"),
        delegate(ref Filesets s) => g(s, "src/**/*.d"),
        delegate(ref Filesets s) => s.union_(g(s, "src/**"), g(s, "lib/**")),
        delegate(ref Filesets s) => s.intersection(g(s, "src/**"), g(s, "lib/**")),
        delegate(ref Filesets s) => s.intersection(g(s, "src/**"), g(s, "src/x/**")),
        delegate(ref Filesets s) => s.difference(s.everything, g(s, "build/")),
        delegate(ref Filesets s) => s.intersection(g(s, "bin/*"), s.executable),
        delegate(ref Filesets s) => s.difference(s.executable, g(s, "src/**")),
        delegate(ref Filesets s) => s.union_(s.difference(s.everything, s.ignored("build/\n*.o\n").value),
            g(s, "build/**/*.o")),
        delegate(ref Filesets s) => s.ignored("*.o\n!keep.o\nbuild/\n!build/keep.txt\ndocs/*\n!docs/guide/\n").value,
        delegate(ref Filesets s) => g(s, "docs"),
        delegate(ref Filesets s) => g(s, "a"),
        delegate(ref Filesets s) => g(s, "a.*/"),
        delegate(ref Filesets s) => g(s, "link"),
        delegate(ref Filesets s) => s.nothing,
        delegate(ref Filesets s) => s.everything,
    ]);

    all ~= Fixture("case", `
        README.md
        docs/Guide.MD
        Src/a.D
    `, CasePolicy.insensitive, [
        delegate(ref Filesets s) => g(s, "*.md"),
        delegate(ref Filesets s) => g(s, "src/*.d"),
        delegate(ref Filesets s) => g(s, "readme.MD"),
    ]);

    all ~= Fixture("deep", `
        a/b/c/d/e/f/g/h.d
        a/b/c/x.d
        a/b/y.txt
        z/
    `, CasePolicy.sensitive, [
        delegate(ref Filesets s) => g(s, "**/c/**"),
        delegate(ref Filesets s) => g(s, "a/**/h.d"),
        delegate(ref Filesets s) => g(s, "a/*/c/"),
        delegate(ref Filesets s) => g(s, "?/b/**/*.{d,txt}"),
    ]);
    return all;
}

/// A seeded random tree literal: `count` entries over a small alphabet that
/// makes collisions, extensions and nesting likely.
string randomTree(ref Mt19937 rng, size_t count = 24) @safe
{
    static immutable names = ["a", "b", "a.b", "x.d", "y.md", "src", "lib", "build",
        "keep.o", "z.o", "gen", "sub", "A.MD", "run"];
    string[] lines;
    bool[string] files, dirs;
    foreach (_; 0 .. count)
    {
        string[] comps;
        const depth = uniform(1, 5, rng);
        foreach (__; 0 .. depth)
            comps ~= names[uniform(0, names.length, rng)];
        const path = comps.join("/");
        // A path may not run through a file, nor repeat an entry.
        bool clash = (path in files) !is null || (path in dirs) !is null;
        foreach (k; 1 .. comps.length)
            clash |= (comps[0 .. k].join("/") in files) !is null;
        if (clash)
            continue;
        foreach (k; 1 .. comps.length)
            dirs[comps[0 .. k].join("/")] = true;
        const roll = uniform(0, 10, rng);
        if (roll == 0)
        {
            dirs[path] = true;
            lines ~= path ~ "/";
        }
        else
        {
            files[path] = true;
            lines ~= roll == 1 ? path ~ " +x" : path;
        }
    }
    return lines.join("\n");
}

/// A seeded random pattern over segments that exercise every glob feature.
string randomPattern(ref Mt19937 rng) @safe
{
    static immutable segs = ["*", "**", "a", "*.d", "*.md", "src", "?", "[ab]*", "{x,y}.*",
        "b*", "*.o", "gen", "lib", "build", "a.b", "*.[dD]", "[!a]*"];
    string[] parts;
    const n = uniform(1, 4, rng);
    foreach (_; 0 .. n)
        parts ~= segs[uniform(0, segs.length, rng)];
    auto p = parts.join("/");
    if (uniform(0, 4, rng) == 0)
        p = "/" ~ p;
    if (uniform(0, 5, rng) == 0)
        p ~= "/";
    return p;
}

/// A seeded random fileset of depth at most `depth` built in `sets`.
Fileset randomFileset(ref Filesets sets, ref Mt19937 rng, uint depth = 3) @safe
{
    const roll = uniform(0, depth == 0 ? 5 : 9, rng);
    switch (roll)
    {
        case 0: return sets.everything;
        case 1: return sets.executable;
        case 2:
            string rules;
            foreach (_; 0 .. uniform(1, 4, rng))
                rules ~= (uniform(0, 3, rng) == 0 ? "!" : "") ~ randomPattern(rng) ~ "\n";
            auto r = sets.ignored(rules);
            return r.hasError ? sets.nothing : r.value;
        case 3, 4:
            auto r = sets.glob(randomPattern(rng));
            return r.hasError ? sets.nothing : r.value;
        case 5, 6:
            return sets.union_(randomFileset(sets, rng, depth - 1), randomFileset(sets, rng, depth - 1));
        case 7:
            return sets.intersection(randomFileset(sets, rng, depth - 1),
                randomFileset(sets, rng, depth - 1));
        default:
            return sets.difference(randomFileset(sets, rng, depth - 1),
                randomFileset(sets, rng, depth - 1));
    }
}

// ---------------------------------------------------------------- the M1 gate

/// Opens a tree literal's root read-only on a fresh `MemVfs`.
auto openFixture(string literal)
{
    import sparkles.build_primitives.fileset.tree_literal : memTree;

    auto made = memTree(literal);
    assert(!made.hasError, made.hasError ? made.error.context : "");
    return made;
}

/**
M1's gate: on every fixture, hand-written and generated, the compiled
predicate and the brute-force oracle agree on every file the brute-force walk
finds.
*/
@("fileset.gate.m1.predicateAgreesWithOracle")
@system unittest
{
    import std.conv : text;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator;

    size_t compared;
    void check(string literal, CasePolicy policy,
        scope Fileset delegate(ref Filesets) @safe make, string label)
    {
        auto tree = openFixture(literal);
        auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        assert(!root.hasError);
        const files = bruteForceFiles(root.value.borrow);
        auto sets = Filesets(policy);
        const f = make(sets);
        auto ev = FilesetEvaluator(sets, f);
        foreach (file; files)
        {
            const want = naiveContains(sets, f, file.path, file.executable);
            const got = ev.contains(sets, file.path, file.executable);
            assert(got == want, text(label, ": ", file.path, " compiled ", got, ", oracle ", want));
            ++compared;
        }
    }

    foreach (fx; fixtureSet())
        foreach (i, make; fx.filesets)
            check(fx.tree, fx.policy, make, text(fx.name, "#", i));

    auto rng = Mt19937(20_261_107);
    foreach (round; 0 .. 300)
    {
        const literal = randomTree(rng);
        foreach (k; 0 .. 8)
        {
            auto seed = rng.front;
            rng.popFront();
            const policy = (seed & 1) ? CasePolicy.insensitive : CasePolicy.sensitive;
            check(literal, policy, (ref Filesets s) @safe {
                auto local = Mt19937(seed);
                return randomFileset(s, local);
            }, text("random round ", round, " seed ", seed));
        }
    }
    assert(compared > 10_000, "the gate compared too little to mean anything");
}

// ---------------------------------------------------------------- the M2 gate

/// What a planned walk found, and what it cost.
struct PlannedWalk
{
    string[] members;           /// in byte order
    size_t stats;               /// `statAt` calls made
    ulong matchesUnderAcceptAll; /// segment matches made beneath `acceptAll`
}

/**
Resolves `f` beneath `root` the way the plan says to: from each start root,
skipping `skip` directories, collecting `acceptAll` ones without matching, and
stat-ing a file only when its verdict is `undecided` (FSA1–FSA4).
*/
PlannedWalk plannedWalk(V, Rights R)(DirRef!(V, R) root, ref const Filesets sets, Fileset f)
{
    import std.algorithm.sorting : sort;

    import sparkles.build_primitives.fileset.plan : plan, rootState;
    import sparkles.build_primitives.fileset.value : DirVerdict, EntryFacts, FileVerdict,
        FilesetEvaluator;

    PlannedWalk result;
    auto ev = FilesetEvaluator(sets, f);
    auto p = plan(sets, f);

    void collectAll(D)(D dir, string prefix)
    {
        const before = ev.segmentMatches;
        foreach (file; bruteForceFiles(dir, prefix))
            result.members ~= file.path;
        result.matchesUnderAcceptAll += ev.segmentMatches - before;
    }

    void walk(D)(D dir, ulong[] state, string prefix)
    {
        auto listing = dir.list();
        assert(!listing.hasError);
        string[] names;
        EntryKind[] kinds;
        for (;;)
        {
            auto more = listing.value.next();
            assert(!more.hasError);
            if (!more.value)
                break;
            names ~= listing.value.front.name.idup;
            kinds ~= listing.value.front.kind;
        }
        foreach (i, name; names)
        {
            auto kind = kinds[i];
            if (kind == EntryKind.unknown)
            {
                ++result.stats;
                kind = dir.statAt(name).value.kind;
            }
            if (kind == EntryKind.directory)
            {
                auto child = new ulong[](ev.stateWords);
                const v = ev.enter(sets, state, name, child);
                if (v == DirVerdict.skip)
                    continue;
                auto sub = dir.openDir(name);
                assert(!sub.hasError);
                if (v == DirVerdict.acceptAll)
                    collectAll(sub.value.borrow, prefix ~ name ~ "/");
                else
                    walk(sub.value.borrow, child, prefix ~ name ~ "/");
            }
            else if (kind == EntryKind.regular || kind == EntryKind.symlink)
            {
                auto v = ev.fileVerdict(sets, state, name, EntryFacts.init);
                if (v == FileVerdict.undecided)
                {
                    ++result.stats;
                    v = ev.fileVerdict(sets, state, name,
                        EntryFacts.stat(dir.statAt(name).value.executable));
                }
                if (v == FileVerdict.accept)
                    result.members ~= prefix ~ name;
            }
        }
    }

    foreach (r; 0 .. p.length)
    {
        const start = p[r].idup;
        auto state = new ulong[](ev.stateWords), scratch = new ulong[](ev.stateWords);
        const v = rootState(ev, sets, start, state, scratch);
        if (v == DirVerdict.skip)
            continue;
        const prefix = start.length ? start ~ "/" : "";
        if (start.length == 0)
        {
            if (v == DirVerdict.acceptAll)
                collectAll(root, prefix);
            else
                walk(root, state, prefix);
            continue;
        }
        auto dir = root.walk(start);
        if (dir.hasError)
            continue; // an absent or non-directory root holds no member
        if (v == DirVerdict.acceptAll)
            collectAll(dir.value.borrow, prefix);
        else
            walk(dir.value.borrow, state, prefix);
    }
    result.members.sort();
    return result;
}

/**
M2's gate, which runs on every fixture for the life of the library: for every
fileset, the planned walk and a brute-force walk that ignores every verdict
produce the same members (FSA1), and a fileset the plan proves empty has
none (FSA6).
*/
@("fileset.gate.m2.plannedEqualsBruteForce")
@system unittest
{
    import std.algorithm.iteration : filter, map;
    import std.array : array;
    import std.conv : text;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.plan : plan;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator;

    size_t filesets, emptyProofs;
    void check(string literal, CasePolicy policy,
        scope Fileset delegate(ref Filesets) @safe make, string label)
    {
        auto tree = openFixture(literal);
        auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        auto sets = Filesets(policy);
        const f = make(sets);
        auto ev = FilesetEvaluator(sets, f);
        const brute = bruteForceFiles(root.value.borrow)
            .filter!(file => ev.contains(sets, file.path, file.executable))
            .map!(file => file.path).array;
        const planned = plannedWalk(root.value.borrow, sets, f);
        assert(planned.members == brute, text(label, ":\n planned ", planned.members,
            "\n brute   ", brute));
        assert(planned.matchesUnderAcceptAll == 0, label);
        if (plan(sets, f).staticallyEmpty)
        {
            assert(brute.length == 0, text(label, ": statically empty, yet ", brute));
            ++emptyProofs;
        }
        ++filesets;
    }

    foreach (fx; fixtureSet())
        foreach (i, make; fx.filesets)
            check(fx.tree, fx.policy, make, text(fx.name, "#", i));

    auto rng = Mt19937(20_261_108);
    foreach (round; 0 .. 300)
    {
        const literal = randomTree(rng);
        foreach (k; 0 .. 8)
        {
            auto seed = rng.front;
            rng.popFront();
            const policy = (seed & 1) ? CasePolicy.insensitive : CasePolicy.sensitive;
            check(literal, policy, (ref Filesets s) @safe {
                auto local = Mt19937(seed);
                return randomFileset(s, local);
            }, text("random round ", round, " seed ", seed));
        }
    }
    assert(filesets > 2000 && emptyProofs > 0, text(filesets, " filesets, ", emptyProofs,
        " empty proofs"));
}

/// FSA3: a fileset naming a whole subtree accepts it without matching
/// beneath it; FSA4: only `undecided` files are stat-ed.
@("fileset.plan.FSA3.acceptAllWithoutMatching")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("vendor/a/b/c.d\nvendor/x\nsrc/a.d\nbin/run +x\nbin/notes\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const vendored = sets.glob("vendor/**").value;
    auto w = plannedWalk(root.value.borrow, sets, vendored);
    assert(w.members == ["vendor/a/b/c.d", "vendor/x"]);
    assert(w.matchesUnderAcceptAll == 0 && w.stats == 0);

    const scripts = sets.intersection(sets.glob("bin/*").value, sets.executable);
    auto s = plannedWalk(root.value.borrow, sets, scripts);
    assert(s.members == ["bin/run"]);
    assert(s.stats == 2, "one stat per undecided file, none elsewhere");
}

/// FSA5: a fileset admitting files beneath an ignored directory enters it.
@("fileset.plan.FSA5.forcedEntry")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("src/a.d\nbuild/a.o\nbuild/obj/b.o\nbuild/log.txt\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const tracked = sets.difference(sets.everything, sets.ignored("build/\n").value);
    auto alone = plannedWalk(root.value.borrow, sets, tracked);
    assert(alone.members == ["src/a.d"]);
    const withObjects = sets.union_(tracked, sets.glob("build/**/*.o").value);
    auto forced = plannedWalk(root.value.borrow, sets, withObjects);
    assert(forced.members == ["build/a.o", "build/obj/b.o", "src/a.d"]);
}

// ---------------------------------------------------------------- M3

/// Resolves `f` beneath `root` with the machine and the inline executor.
PathCollector machineResolve(V, Rights R)(DirRef!(V, R) root, ref const Filesets sets, Fileset f,
    ResolutionLimits limits = ResolutionLimits.init, size_t budget = 4096)
{
    PathCollector sink;
    auto r = resolve(root, sets, f, sink, limits, budget);
    assert(!r.hasError, r.hasError ? r.error.context : "");
    return sink;
}

/// Writes the tree of a tree literal beneath the directory `dir` on disk.
void materialize(string literal, string dir) @system
{
    import std.algorithm.searching : findSplit;
    import std.file : mkdirRecurse, setAttributes, write;
    import std.path : buildPath, dirName;
    import std.string : lineSplitter, strip;

    foreach (raw; literal.lineSplitter)
    {
        auto line = raw.strip;
        if (line.length == 0 || line[0] == '#')
            continue;
        if (auto link = line.findSplit(" -> "))
        {
            mkdirRecurse(buildPath(dir, link[0]).dirName);
            version (Posix)
            {
                import std.file : symlink;

                symlink(link[2], buildPath(dir, link[0]));
            }
            else
            {
                import sparkles.test_runner.skip : skipTest;

                skipTest("the tree holds a symbolic link, which needs POSIX here");
            }
            continue;
        }
        if (line[$ - 1] == '/' && !line.canFind(" = "))
        {
            mkdirRecurse(buildPath(dir, line));
            continue;
        }
        string content;
        auto path = line;
        if (auto eq = line.findSplit(" = "))
        {
            import std.array : replace;

            path = eq[0];
            // The tree literal's escapes: `\n` a newline, `\\` a backslash.
            content = eq[2].replace(`\\`, "\x00").replace(`\n`, "\n").replace("\x00", `\`);
        }
        bool exec;
        if (path.length > 3 && path[$ - 3 .. $] == " +x")
        {
            exec = true;
            path = path[0 .. $ - 3];
        }
        const full = buildPath(dir, path);
        mkdirRecurse(full.dirName);
        write(full, content);
        version (Posix)
            setAttributes(full, exec ? octal!755 : octal!644);
    }
}


/// A fresh scratch directory for one native fixture.
string scratchTree(string label) @system
{
    import std.conv : to;
    import std.file : mkdirRecurse, tempDir;
    import std.path : buildPath;
    import std.process : thisProcessID;

    static size_t counter;
    const dir = buildPath(tempDir, "sparkles-fileset-" ~ thisProcessID.to!string ~ "-" ~ label
        ~ "-" ~ (++counter).to!string);
    mkdirRecurse(dir);
    return dir;
}

/**
Whether the filesystem of `scratchTree` folds names: on one that ignores case
(by default macOS's APFS and Windows' NTFS), `A` and `a` are one entry, so
a tree holding both cannot be materialized there.
*/
bool scratchFoldsCase() @system
{
    import std.file : exists, rmdirRecurse, write;
    import std.path : buildPath;

    static int known = -1;
    if (known < 0)
    {
        const dir = scratchTree("case-probe");
        scope (exit) rmdirRecurse(dir);
        write(buildPath(dir, "A"), "");
        known = exists(buildPath(dir, "a"));
    }
    return known == 1;
}

/**
M3's gate, first half: on M1's fixture set, the machine resolves the same
members as the planned walk and the brute-force walk; with a budget of one it
produces the same transcript as with an unbounded one (FSM6).
*/
@("fileset.gate.m3.machineAgreesWithOracles")
@system unittest
{
    import std.algorithm.iteration : filter, map;
    import std.algorithm.sorting : sort;
    import std.array : array;
    import std.conv : text;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.value : FilesetEvaluator;

    size_t checked;
    void check(string literal, CasePolicy policy,
        scope Fileset delegate(ref Filesets) @safe make, string label, bool tiny)
    {
        auto tree = openFixture(literal);
        auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
        auto sets = Filesets(policy);
        const f = make(sets);
        auto ev = FilesetEvaluator(sets, f);
        const brute = bruteForceFiles(root.value.borrow)
            .filter!(file => ev.contains(sets, file.path, file.executable))
            .map!(file => file.path).array;
        auto got = machineResolve(root.value.borrow, sets, f);
        auto members = got.members.dup;
        members.sort();
        assert(members == brute, text(label, ":\n machine ", members, "\n brute   ", brute));
        assert(members == plannedWalk(root.value.borrow, sets, f).members, label);
        if (tiny)
            assert(machineResolve(root.value.borrow, sets, f, ResolutionLimits.init, 1).transcript
                == got.transcript, label ~ ": a budget of one changed the result");
        ++checked;
    }

    foreach (fx; fixtureSet())
        foreach (i, make; fx.filesets)
            check(fx.tree, fx.policy, make, text(fx.name, "#", i), true);

    auto rng = Mt19937(20_261_109);
    foreach (round; 0 .. 200)
    {
        const literal = randomTree(rng);
        foreach (k; 0 .. 6)
        {
            auto seed = rng.front;
            rng.popFront();
            const policy = (seed & 1) ? CasePolicy.insensitive : CasePolicy.sensitive;
            check(literal, policy, (ref Filesets s) @safe {
                auto local = Mt19937(seed);
                return randomFileset(s, local);
            }, text("random round ", round, " seed ", seed), k == 0);
        }
    }
    assert(checked > 1000);
}

version (Posix)
{
    /**
    M3's gate, second half: the one adapter over `MemVfs`, `BlockingVfs` and
    `RingVfs` (the latter on scheduler fibers, concurrently) produces
    byte-identical transcripts over one fixture set (FSD1).
    */
    @("fileset.gate.m3.threeBackends")
    @system unittest
    {
        import std.conv : text;
        import std.file : rmdirRecurse;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.build_primitives.fileset.driver : filesetRights;
        import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
        import sparkles.event_horizon.admission : Admission;
        import sparkles.event_horizon.sched : Sched;
        import sparkles.event_horizon.sys : BlockingVfs;
        import sparkles.event_horizon.vfs : RingVfs;

        Sched s;
        schedOrSkip(s);

        size_t compared;
        uint peak;
        void check(string literal, CasePolicy policy,
            scope Fileset delegate(ref Filesets) @safe make, string label)
        {
            auto sets = Filesets(policy);
            const f = make(sets);

            auto tree = openFixture(literal);
            auto memRoot = openRoot!filesetRights(&tree.value.get().vfs, "", ambientAuthority());
            const mem = machineResolve(memRoot.value.borrow, sets, f).transcript;

            const dir = scratchTree("diff");
            scope (exit) rmdirRecurse(dir);
            materialize(literal, dir);
            auto blocking = new BlockingVfs;
            auto blockingRoot = openRoot!filesetRights(blocking, dir, ambientAuthority());
            assert(!blockingRoot.hasError);
            const native = machineResolve(blockingRoot.value.borrow, sets, f).transcript;

            string ring;
            auto r = s.run(() {
                auto rv = new RingVfs;
                auto ringRoot = openRoot!filesetRights(rv, dir, ambientAuthority());
                auto budget = new Admission(4);
                auto exec = LoopExecutor!Sched(&s, budget);
                PathCollector sink;
                auto res = resolveWith(ringRoot.value.borrow, sets, f, sink, exec);
                assert(!res.hasError);
                ring = sink.transcript;
                if (exec.peak > peak)
                    peak = exec.peak;
            });
            assert(!r.hasError);
            assert(mem == native && native == ring, text(label, "\nMemVfs:\n", mem,
                "BlockingVfs:\n", native, "RingVfs:\n", ring));
            ++compared;
        }

        foreach (fx; fixtureSet())
            foreach (i, make; fx.filesets)
                check(fx.tree, fx.policy, make, text(fx.name, "#", i));
        auto rng = Mt19937(20_261_110);
        foreach (round; 0 .. 30)
        {
            const literal = randomTree(rng);
            auto seed = rng.front;
            rng.popFront();
            check(literal, CasePolicy.sensitive, (ref Filesets st) @safe {
                auto local = Mt19937(seed);
                return randomFileset(st, local);
            }, text("random round ", round));
        }
        assert(compared > 50);
        assert(peak > 1, "the event-horizon driver never ran two requests at once");
    }

    /// FSS6: with a budget of one in-flight operation the event-horizon
    /// driver completes and never exceeds it.
    @("fileset.driver.FSS6.budgetOfOne")
    @system unittest
    {
        import std.file : rmdirRecurse;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.build_primitives.fileset.driver : filesetRights;
        import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
        import sparkles.event_horizon.admission : Admission;
        import sparkles.event_horizon.sched : Sched;
        import sparkles.event_horizon.vfs : RingVfs;

        Sched s;
        schedOrSkip(s);
        const dir = scratchTree("budget");
        scope (exit) rmdirRecurse(dir);
        materialize("a/x +x\na/y\nb/z +x\nc/\nd/e/f +x\n", dir);
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.executable;
        string[] members;
        uint peak;
        auto r = s.run(() {
            auto rv = new RingVfs;
            auto root = openRoot!filesetRights(rv, dir, ambientAuthority());
            auto budget = new Admission(1);
            auto exec = LoopExecutor!Sched(&s, budget);
            PathCollector sink;
            assert(!resolveWith(root.value.borrow, sets, f, sink, exec).hasError);
            members = sink.members;
            peak = exec.peak;
        });
        assert(!r.hasError);
        assert(members == ["a/x", "b/z", "d/e/f"]);
        assert(peak == 1);
    }
}

/// FSM1: the machine's modules import nothing that performs I/O. Checked by
/// reading their sources, not by inspection.
@("fileset.machine.FSM1.importsNothingEffectful")
@system unittest
{
    import std.algorithm.searching : canFind, startsWith;
    import std.file : readText;
    import std.path : buildPath, dirName;
    import std.string : lineSplitter, strip;

    static immutable machineModules = ["machine.d", "plan.d", "value.d", "pattern.d", "ignore.d", "fso.d"];
    static immutable forbidden = ["std.file", "std.stdio", "std.process", "std.socket",
        "core.sys", "core.stdc.stdio", "sparkles.event_horizon", "sparkles.base.vfs.handles",
        "sparkles.base.vfs.mem", "sparkles.base.vfs.walk", "sparkles.base.io.fd"];
    foreach (m; machineModules)
    {
        const src = readText(buildPath(__FILE_FULL_PATH__.dirName, m));
        bool inUnittest;
        foreach (raw; src.lineSplitter)
        {
            const line = raw.strip;
            if (!line.canFind("import "))
                continue;
            foreach (bad; forbidden)
                assert(!line.canFind(" " ~ bad), m ~ " imports " ~ bad ~ ": " ~ line);
        }
    }
}

/// An executor that runs a batch inline, recording each batch's kinds, and
/// calls `beforeStats` once, just before the first batch of stats runs.
struct RecordingExecutor
{
    import sparkles.build_primitives.fileset.machine : Request, RequestKind;

    size_t[] sizes;             /// each batch's length
    size_t stats;               /// stat requests performed
    size_t links;               /// readlink requests performed
    string[] reads;             /// the name of each `readFile` request
    string[] names;             /// the name of every request, in order
    void delegate() beforeStats; /// called once, if set

    /// Runs `batch` inline.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        sizes ~= batch.length;
        bool anyStat;
        foreach (ref r; batch)
        {
            names ~= r.name.idup;
            if (r.kind == RequestKind.readFile)
                reads ~= r.name.idup;
            stats += r.kind == RequestKind.stat;
            links += r.kind == RequestKind.readlink;
            anyStat |= r.kind == RequestKind.stat;
        }
        if (anyStat && beforeStats !is null)
        {
            beforeStats();
            beforeStats = null;
        }
        foreach (i; 0 .. batch.length)
            perform(i);
    }

    /// Runs a scheme's `work` now.
    void spawn(Work)(scope Work work)
    {
        work();
    }

    /// Nothing is left running.
    void join()
    {
    }
}

/// FSM3: the requests one directory's entries need arrive as one batch.
@("fileset.machine.FSM3.oneBatchPerDirectory")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("d/a +x\nd/b\nd/c +x\nd/e\nd/f\nd/s1/\nd/s2/x\nd/s3/\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.executable;
    PathCollector sink;
    RecordingExecutor exec;
    assert(!resolveWith(root.value.borrow, sets, f, sink, exec).hasError);
    // The root's listing, `d`'s listing, `d`'s 5 stats, `d`'s 3 subdirectories,
    // `s2`'s stat.
    assert(exec.sizes == [1, 1, 5, 3, 1]);
    assert(exec.stats == 6);
    assert(sink.members == ["d/a", "d/c"]);
}

/// FSO4's machine half: a fileset whose verdicts need no metadata issues no
/// `stat` request; a stream sees a directory before its children (FSS3).
@("fileset.machine.noStatWithoutNeed")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("src/a.d\nsrc/b/c.d\nsrc/b/d.txt\nvendor/x/y\ndocs/z.md\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.union_(sets.glob("src/**/*.d").value, sets.glob("vendor/").value);
    PathCollector sink;
    RecordingExecutor exec;
    assert(!resolveWith(root.value.borrow, sets, f, sink, exec).hasError);
    assert(exec.stats == 0);
    assert(sink.members == ["src/a.d", "src/b/c.d", "vendor/x/y"], "a stream sees units pre-order");
}

/// FSV4: an entered directory with no member and no entered subdirectory is
/// reported, and is not a member.
@("fileset.machine.FSV4.emptyDirectories")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("src/a.d\nsrc/empty/\nsrc/deep/er/\ndocs/x.md\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    auto got = machineResolve(root.value.borrow, sets, sets.glob("src/**").value);
    assert(got.members == ["src/a.d"]);
    assert(got.emptyDirs == ["src/deep/er", "src/empty"]);
}

/// FSV4, D5: only a directory whose whole content the fileset selects, once
/// exclusions are set aside, is reported; a pattern's search is not.
@("fileset.machine.FSV4.wholeContentOnly")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("src/a.d\nsrc/empty/\ndocs/x.md\ndocs/none/\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    auto md = machineResolve(root.value.borrow, sets, sets.glob("*.md").value);
    assert(md.members == ["docs/x.md"]);
    assert(md.emptyDirs == []);
    const both = sets.union_(sets.glob("src/**").value, sets.glob("*.md").value);
    assert(machineResolve(root.value.borrow, sets, both).emptyDirs == ["src/empty"]);
    const minus = sets.difference(sets.everything, sets.glob("*.d").value);
    assert(machineResolve(root.value.borrow, sets, minus).emptyDirs == ["docs/none", "src/empty"]);
}

/// FSM6: a cursor is valid only for its resolution and its step.
@("fileset.machine.FSM6.staleCursor")
@system unittest
{
    import sparkles.build_primitives.fileset.machine : Resolution, StepKind;

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;
    auto a = Resolution(sets, f), b = Resolution(sets, f);
    auto ca = a.start(), cb = b.start();
    StepKind kind;
    assert(!a.step(sets, cb, 16, kind));
    assert(a.error.code == ResolutionErrorCode.staleCursor);
    auto old = cb;
    assert(b.step(sets, cb, 16, kind) && kind == StepKind.needIO);
    assert(!b.step(sets, old, 16, kind), "an old cursor of the same resolution");
}

/// FSM7: nesting and name length are bounded, and exceeding either is a
/// returned error.
@("fileset.machine.FSM7.bounds")
@system unittest
{
    import std.array : replicate;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto deep = openFixture("d/".replicate(65) ~ "f\n");
    auto root = openRoot!(Rights.readOnly)(&deep.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    PathCollector sink;
    auto r = resolve(root.value.borrow, sets, sets.everything, sink);
    assert(r.hasError && r.error.code == ResolutionErrorCode.depthExceeded);
    auto shallow = openFixture("d/".replicate(64) ~ "f\n");
    auto ok = openRoot!(Rights.readOnly)(&shallow.value.get().vfs, "", ambientAuthority());
    assert(!resolve(ok.value.borrow, sets, sets.everything, sink).hasError, "64 is within");

    auto named = openFixture("short\n" ~ "n".replicate(16) ~ "\n");
    auto nroot = openRoot!(Rights.readOnly)(&named.value.get().vfs, "", ambientAuthority());
    ResolutionLimits lim;
    lim.maxNameLength = 15;
    auto n = resolve(nroot.value.borrow, sets, sets.everything, sink, lim);
    assert(n.hasError && n.error.code == ResolutionErrorCode.nameTooLong);
}

/// FSM2: a request a driver cannot perform fails the resolution, naming its
/// kind.
@("fileset.machine.FSM2.unsupportedRequest")
@system unittest
{
    import sparkles.base.io.errors : ErrorKind;
    import sparkles.build_primitives.fileset.machine : RequestKind, Resolution, StepKind;

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.executable;
    auto m = Resolution(sets, f);
    auto c = m.start();
    StepKind kind;
    assert(m.step(sets, c, 64, kind) && kind == StepKind.needIO);
    assert(m.batch[0].kind == RequestKind.readDir);
    m.entry(0, "tool", EntryKind.regular);
    m.listed(0);
    assert(m.step(sets, c, 64, kind) && kind == StepKind.needIO);
    assert(m.batch.length == 1 && m.batch[0].kind == RequestKind.stat);
    m.failed(0, ErrorKind.unsupported);
    assert(!m.step(sets, c, 64, kind));
    assert(m.error.code == ResolutionErrorCode.unsupportedRequest);
    assert(m.error.kind == RequestKind.stat);
}

/// FSE2: a request that fails with the unclassified kind, as `EIO` does, is
/// a failure, not an answer: the entry is reported incomplete.
@("fileset.machine.FSE2.unclassifiedFailure")
@system unittest
{
    import sparkles.base.io.errors : ErrorKind;
    import sparkles.build_primitives.fileset.machine : RequestKind, Resolution, StepKind;

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.executable;
    auto m = Resolution(sets, f);
    auto c = m.start();
    StepKind kind;
    assert(m.step(sets, c, 64, kind) && kind == StepKind.needIO);
    m.entry(0, "tool", EntryKind.regular);
    m.listed(0);
    assert(m.step(sets, c, 64, kind) && kind == StepKind.needIO);
    assert(m.batch.length == 1 && m.batch[0].kind == RequestKind.stat);
    m.failed(0, ErrorKind.other);
    string[] incomplete;
    for (;;)
    {
        assert(m.step(sets, c, 64, kind));
        if (kind == StepKind.incomplete)
            incomplete ~= text(m.incompletePath, ": ", m.incompleteKind);
        if (kind == StepKind.done)
            break;
        assert(kind != StepKind.needIO, "a failed stat is not asked again");
    }
    assert(incomplete == ["tool: other"], text(incomplete));
}

/// A start root whose listing fails part-way leaves nothing behind: the
/// entries it listed before failing are not the next root's.
@("fileset.machine.FSE1.failedRootListing")
@system unittest
{
    import sparkles.base.io.errors : ErrorKind;
    import sparkles.build_primitives.fileset.machine : Resolution, StepKind;

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.union_(sets.glob("a/**").value, sets.glob("b/**").value);
    auto m = Resolution(sets, f);
    auto c = m.start();
    StepKind kind;
    assert(m.step(sets, c, 64, kind) && kind == StepKind.needIO);
    m.entry(0, "x", EntryKind.regular);
    m.failed(0, ErrorKind.permission);
    string[] incomplete, members;
    for (;;)
    {
        assert(m.step(sets, c, 64, kind));
        if (kind == StepKind.incomplete)
            incomplete ~= text(m.incompletePath, ": ", m.incompleteKind);
        else if (kind == StepKind.needIO)
        {
            m.entry(0, "y", EntryKind.regular);
            m.listed(0);
        }
        else if (kind == StepKind.unit)
            foreach (u; m.unitEntries)
                members ~= text(m.unitPath, "/", u.name);
        else if (kind == StepKind.done)
            break;
    }
    assert(incomplete == ["a: permission"], text(incomplete));
    assert(members == ["b/y"], text(members));
}

/// FSE3: an entry gone between `readDir` and `stat` is recorded as
/// incomplete, and the resolution completes.
@("fileset.machine.FSE3.vanishingEntry")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("d/a +x\nd/b +x\nd/c\n");
    auto vfs = &tree.value.get().vfs;
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    PathCollector sink;
    RecordingExecutor exec;
    exec.beforeStats = () { assert(vfs.remove("d/a")); };
    assert(!resolveWith(root.value.borrow, sets, sets.executable, sink, exec).hasError);
    assert(sink.members == ["d/b"]);
    assert(sink.unreadable == ["d/a: notFound"]);
}

/// FSD5: a directory renamed mid-walk still resolves the entries already
/// enumerated beneath it, through the handle the walk holds.
@("fileset.driver.FSD5.renameMidWalk")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture("d/a +x\nd/b\nd/c +x\n");
    auto vfs = &tree.value.get().vfs;
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    PathCollector sink;
    RecordingExecutor exec;
    exec.beforeStats = () { assert(vfs.rename("d", "moved")); };
    assert(!resolveWith(root.value.borrow, sets, sets.executable, sink, exec).hasError);
    assert(sink.members == ["d/a", "d/c"]);
    assert(sink.unreadable.length == 0);
}

/// FSD6: a link out of the root resolves nothing outside it under either
/// policy; under `symlinks = beneath` a link to a sibling directory resolves
/// to that directory's entries.
@("fileset.driver.FSD6.confinement")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : ResolvePolicy, SymlinkPolicy;

    enum literal = "outside/secret\nr/real/x.d\nr/alias -> real\nr/etc -> /outside\nr/up -> ../outside\n";
    auto tree = openFixture(literal);
    auto vfs = &tree.value.get().vfs;
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    auto plain = openRoot!(Rights.readOnly)(vfs, "r", ambientAuthority());
    auto byDefault = machineResolve(plain.value.borrow, sets, f);
    assert(byDefault.members == ["alias", "etc", "up", "real/x.d"],
        "by default every link is a member, its target data");

    ResolvePolicy beneath;
    beneath.symlinks = SymlinkPolicy.beneath;
    auto followed = openRoot!(Rights.readOnly)(vfs, "r", ambientAuthority(), beneath);
    auto got = machineResolve(followed.value.borrow, sets, f);
    import std.algorithm.sorting : sort;
    auto members = got.members.dup;
    members.sort();
    assert(members == ["alias/x.d", "real/x.d"]);
    assert(got.unreadable == ["etc: escapesRoot", "up: escapesRoot"]);
}

/// FSD7: a mount beneath the root is not crossed by default, and the
/// boundary is reported; a root opened with `crossMounts` crosses it.
@("fileset.driver.FSD7.mounts")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : ResolvePolicy;

    auto tree = openFixture("r/a\nr/m/b\n");
    auto vfs = &tree.value.get().vfs;
    assert(vfs.mount("r/m"));
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    auto confined = openRoot!(Rights.readOnly)(vfs, "r", ambientAuthority());
    auto got = machineResolve(confined.value.borrow, sets, f);
    assert(got.members == ["a"]);
    assert(got.unreadable == ["m: crossesMount"]);

    ResolvePolicy crossing;
    crossing.crossMounts = true;
    auto open = openRoot!(Rights.readOnly)(vfs, "r", ambientAuthority(), crossing);
    assert(machineResolve(open.value.borrow, sets, f).members == ["a", "m/b"]);
}

version (Posix)
{
    // Makes `s`, or skips the test where the host has no event loop for it.
    private void schedOrSkip(ref imported!"sparkles.event_horizon.sched".Sched s) @trusted
    {
        import sparkles.event_horizon.sched : Sched;
        import sparkles.test_runner.skip : skipTest;

        auto created = Sched.create(s);
        if (created.hasError)
            skipTest("no event loop on this host");
    }
}

// ---------------------------------------------------------------- M4

/**
Nested `.gitignore` scopes exercising each clause of FSI4: the root's rules,
a deeper scope re-including (`src`) and anchoring to its own directory
(`/gen/`), a scope inside an excluded directory that must never be read
(`build`), and one deep scope (`lib/x`).
*/
enum string nestedScopes = `
    .gitignore = *.log\nbuild/\n/top.txt\nlib/x/z.c
    top.txt
    a.log
    keep/
    src/.gitignore = !*.log\n/gen/
    src/a.log
    src/x.d
    src/gen/out.d
    src/sub/gen/in.d
    build/.gitignore = !*
    build/o.o
    lib/x/.gitignore = *.d
    lib/x/y.d
    lib/x/z.c
    lib/w.d
`;

/// What `nestedScopes` leaves when the scopes' exclusions are taken away.
static immutable string[] nestedScopesKept = [".gitignore", "lib/w.d", "lib/x/.gitignore",
    "src/.gitignore", "src/a.log", "src/sub/gen/in.d", "src/x.d"];

/// Members of `f` over a tree literal, sorted, with the requests' record.
private string[] resolveSorted(string literal, scope Fileset delegate(ref Filesets) @safe make,
    out RecordingExecutor exec) @system
{
    import std.algorithm.sorting : sort;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;

    auto tree = openFixture(literal);
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    assert(!root.hasError);
    auto sets = Filesets(CasePolicy.sensitive);
    const f = make(sets);
    PathCollector sink;
    auto r = resolveWith(root.value.borrow, sets, f, sink, exec);
    assert(!r.hasError, r.hasError ? r.error.context : "");
    return sink.members.sort.release;
}

/// FSI4, on the in-memory driver: each clause of git's precedence.
@("fileset.machine.FSI4.nestedScopes")
@system unittest
{
    RecordingExecutor exec;
    const kept = resolveSorted(nestedScopes,
        (ref Filesets s) @safe => s.difference(s.everything, s.gitignored), exec);
    assert(kept == nestedScopesKept, kept.to!string);
    // The excluded `build/` is never entered, so its `.gitignore` is not read.
    assert(exec.reads == [".gitignore", ".gitignore", ".gitignore"], exec.reads.to!string);
}

/// The scopes above a start root are read before it is listed, and none is
/// read inside an excluded directory; forced entry still reaches beneath one
/// (FSA5).
@("fileset.machine.FSI.prefixScopes")
@system unittest
{
    import std.algorithm.sorting : sort;

    RecordingExecutor exec;
    // `lib/x` starts the walk; the root's `lib/x/z.c` still applies.
    assert(resolveSorted(nestedScopes,
        (ref Filesets s) @safe => s.difference(s.glob("lib/x/**").value, s.gitignored), exec)
        == ["lib/x/.gitignore"]);
    assert(exec.reads == [".gitignore", "lib/.gitignore", ".gitignore"], exec.reads.to!string);

    // The root's `build/` excludes the start root: nothing beneath is read.
    RecordingExecutor excluded;
    assert(resolveSorted(nestedScopes,
        (ref Filesets s) @safe => s.difference(s.glob("build/**").value, s.gitignored), excluded)
        .length == 0);
    assert(excluded.reads == [".gitignore"], excluded.reads.to!string);

    RecordingExecutor forced;
    const both = resolveSorted(nestedScopes, (ref Filesets s) @safe => s.union_(
        s.difference(s.everything, s.gitignored), s.glob("build/**/*.o").value), forced);
    assert(both == (nestedScopesKept.dup ~ "build/o.o").sort.release, both.to!string);
}

/// FSM2: a root opened without read rights cannot read a `.gitignore`, and
/// says so rather than resolving without the scopes.
@("fileset.driver.FSI.needsReadRights")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.driver : filesetRights;
    import sparkles.build_primitives.fileset.machine : RequestKind, ResolutionErrorCode;

    auto tree = openFixture(nestedScopes);
    auto root = openRoot!filesetRights(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.difference(sets.everything, sets.gitignored);
    PathCollector sink;
    const r = resolve(root.value.borrow, sets, f, sink);
    assert(r.hasError && r.error.code == ResolutionErrorCode.unsupportedRequest
        && r.error.kind == RequestKind.readFile);
}

/// FSI2: the scope arena holds at most one scope per directory with a
/// `.gitignore`, and is released as the walk leaves each subtree.
@("fileset.machine.FSI2.residency")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.mem : MemVfs;
    import sparkles.build_primitives.fileset.driver : FilesetDriver;
    import sparkles.build_primitives.fileset.machine : Resolution, StepKind;

    // Two siblings with scopes, each with a nested one: four `.gitignore`s,
    // three of them never on the walk's path at once.
    auto tree = openFixture(`
        .gitignore = *.o
        a/.gitignore = *.a
        a/deep/.gitignore = *.b
        a/deep/f.c
        b/.gitignore = *.c
        b/g.d
    `);
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.difference(sets.everything, sets.gitignored);
    auto m = Resolution(sets, f);
    auto driver = FilesetDriver!(MemVfs, Rights.readOnly)(ResolutionLimits.init.maxFrames);
    auto cursor = m.start();
    for (StepKind kind; m.step(sets, cursor, 4096, kind) && kind != StepKind.done; )
    {
        driver.retire(m.retired);
        if (kind == StepKind.needIO)
            foreach (i; 0 .. m.batch.length)
                driver.perform(m, root.value.borrow, i);
    }
    assert(m.error.code == ResolutionErrorCode.none);
    assert(m.ignorePeakScopes == 3, m.ignorePeakScopes.to!string);
}

/// FSD1 with scopes: the three backends read the same `.gitignore` files
/// and resolve the same members.
version (Posix)
@("fileset.driver.FSI.threeBackends")
@system unittest
{
    import std.file : rmdirRecurse;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.sched : Sched;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.event_horizon.vfs : RingVfs;

    Sched s;
    schedOrSkip(s);
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.difference(sets.everything, sets.gitignored);

    auto tree = openFixture(nestedScopes);
    auto memRoot = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    const mem = machineResolve(memRoot.value.borrow, sets, f).transcript;

    const dir = scratchTree("scopes");
    scope (exit) rmdirRecurse(dir);
    materialize(nestedScopes, dir);
    auto blocking = new BlockingVfs;
    auto blockingRoot = openRoot!(Rights.readOnly)(blocking, dir, ambientAuthority());
    const native = machineResolve(blockingRoot.value.borrow, sets, f).transcript;

    string ring;
    auto r = s.run(() {
        auto rv = new RingVfs;
        auto ringRoot = openRoot!(Rights.readOnly)(rv, dir, ambientAuthority());
        auto exec = LoopExecutor!Sched(&s, new Admission(4));
        PathCollector sink;
        assert(!resolveWith(ringRoot.value.borrow, sets, f, sink, exec).hasError);
        ring = sink.transcript;
    });
    assert(!r.hasError);
    assert(mem == native && native == ring, "MemVfs:\n" ~ mem ~ "BlockingVfs:\n" ~ native
        ~ "RingVfs:\n" ~ ring);
}

/// FSD6, D6: under `symlinks = beneath`, a link back to a directory the walk
/// is inside is one incomplete entry and the resolution completes, on every
/// backend; a second link to a directory that is not an ancestor is walked.
version (Posix)
@("fileset.driver.FSD6.cycle")
@system unittest
{
    import std.file : rmdirRecurse;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : ResolvePolicy, SymlinkPolicy;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.sched : Sched;
    import sparkles.event_horizon.sys : BlockingVfs;
    import sparkles.event_horizon.vfs : RingVfs;

    enum literal = "a/x.d\na/self -> .\na/b/y.d\ntwin -> a\n";
    enum expected = "members:\na/x.d\na/b/y.d\ntwin/x.d\ntwin/b/y.d\nempty:\n\n"
        ~ "incomplete:\na/self: symlinkLoop\ntwin/self: symlinkLoop\n";
    ResolvePolicy beneath;
    beneath.symlinks = SymlinkPolicy.beneath;
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    auto tree = openFixture(literal);
    auto memRoot = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority(), beneath);
    const mem = machineResolve(memRoot.value.borrow, sets, f).transcript;
    assert(mem == expected, mem);

    Sched s;
    schedOrSkip(s);
    const dir = scratchTree("cycle");
    scope (exit) rmdirRecurse(dir);
    materialize(literal, dir);
    auto blocking = new BlockingVfs;
    auto blockingRoot = openRoot!(Rights.readOnly)(blocking, dir, ambientAuthority(), beneath);
    const native = machineResolve(blockingRoot.value.borrow, sets, f).transcript;

    string ring;
    auto r = s.run(() {
        auto rv = new RingVfs;
        auto ringRoot = openRoot!(Rights.readOnly)(rv, dir, ambientAuthority(), beneath);
        auto exec = LoopExecutor!Sched(&s, new Admission(4));
        PathCollector sink;
        assert(!resolveWith(ringRoot.value.borrow, sets, f, sink, exec).hasError);
        ring = sink.transcript;
    });
    assert(!r.hasError);
    assert(native == expected && ring == expected, "BlockingVfs:\n" ~ native ~ "RingVfs:\n" ~ ring);
}

version (Posix)
{
    // The transcripts of `f` beneath `dir` on `BlockingVfs` and on
    // `RingVfs`, the root opened with `policy`.
    private string[2] nativeTranscripts(string dir, imported!"sparkles.base.vfs.types".ResolvePolicy policy,
        ref const Filesets sets, Fileset f) @system
    {
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
        import sparkles.event_horizon.admission : Admission;
        import sparkles.event_horizon.sched : Sched;
        import sparkles.event_horizon.sys : BlockingVfs;
        import sparkles.event_horizon.vfs : RingVfs;

        Sched s;
        schedOrSkip(s);
        auto blocking = new BlockingVfs;
        auto blockingRoot = openRoot!(Rights.readOnly)(blocking, dir, ambientAuthority(), policy);
        assert(!blockingRoot.hasError, dir);
        const native = machineResolve(blockingRoot.value.borrow, sets, f).transcript;
        string ring;
        auto r = s.run(() {
            auto rv = new RingVfs;
            auto ringRoot = openRoot!(Rights.readOnly)(rv, dir, ambientAuthority(), policy);
            auto exec = LoopExecutor!Sched(&s, new Admission(4));
            PathCollector sink;
            assert(!resolveWith(ringRoot.value.borrow, sets, f, sink, exec).hasError);
            ring = sink.transcript;
        });
        assert(!r.hasError);
        return [native, ring];
    }
}

/// FSD6 on the native backends: the confinement fixture resolves as it does
/// on `MemVfs`, under either policy, on `BlockingVfs` and `RingVfs`.
version (Posix)
@("fileset.driver.FSD6.confinementNative")
@system unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    import sparkles.base.vfs.types : ResolvePolicy, SymlinkPolicy;

    // The absolute link names a path that exists on no test host.
    enum literal = "outside/secret\nr/real/x.d\nr/alias -> real\n"
        ~ "r/etc -> /sparkles-fsd6-outside\nr/up -> ../outside\n";
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;
    const dir = scratchTree("confinement");
    scope (exit) rmdirRecurse(dir);
    materialize(literal, dir);
    const root = buildPath(dir, "r");

    enum byDefault = "members:\nalias\netc\nup\nreal/x.d\nempty:\n\nincomplete:\n\n";
    foreach (i, t; nativeTranscripts(root, ResolvePolicy.init, sets, f))
        assert(t == byDefault, text(i ? "RingVfs" : "BlockingVfs", ":\n", t));

    ResolvePolicy beneath;
    beneath.symlinks = SymlinkPolicy.beneath;
    enum followed = "members:\nalias/x.d\nreal/x.d\nempty:\n\n"
        ~ "incomplete:\netc: escapesRoot\nup: escapesRoot\n";
    foreach (i, t; nativeTranscripts(root, beneath, sets, f))
        assert(t == followed, text(i ? "RingVfs" : "BlockingVfs", ":\n", t));
}

/// FSD6: under `symlinks = beneath`, a link whose target climbs out of its
/// own directory but stays beneath the root resolves; one that leaves the
/// root still fails with `escapesRoot`. On every backend.
version (Posix)
@("fileset.driver.FSD6.climbingLinkInsideRoot")
@system unittest
{
    import std.file : rmdirRecurse;
    import std.path : buildPath;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : ResolvePolicy, SymlinkPolicy;

    enum literal = "outside/secret\nr/a/link -> ../b\nr/a/deep/up -> ../../b\n"
        ~ "r/a/out -> ../../outside\nr/a/up -> ..\nr/b/x\n";
    // `a/up` names the root itself: a cycle, reported once (D6).
    enum expected = "members:\na/deep/up/x\na/link/x\nb/x\nempty:\n\n"
        ~ "incomplete:\na/out: escapesRoot\na/up: symlinkLoop\n";
    ResolvePolicy beneath;
    beneath.symlinks = SymlinkPolicy.beneath;
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    auto tree = openFixture(literal);
    auto memRoot = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "r", ambientAuthority(), beneath);
    const mem = machineResolve(memRoot.value.borrow, sets, f).transcript;
    assert(mem == expected, mem);

    const dir = scratchTree("climbing");
    scope (exit) rmdirRecurse(dir);
    materialize(literal, dir);
    foreach (i, t; nativeTranscripts(buildPath(dir, "r"), beneath, sets, f))
        assert(t == expected, text(i ? "RingVfs" : "BlockingVfs", ":\n", t));
}

/// FSD7 on a real mount: `/dev/shm` is its own file system beneath `/dev`
/// on Linux. A root at `/dev` does not cross into it by default, and reports
/// the boundary; with `crossMounts` it reads a file written there.
version (linux)
@("fileset.driver.FSD7.realMount")
@system unittest
{
    import std.file : exists, getAttributes, mkdirRecurse, rmdirRecurse, write;
    import std.path : buildPath;
    import std.process : thisProcessID;

    import sparkles.base.vfs.types : ResolvePolicy;
    import sparkles.test_runner.skip : skipTest;

    import core.sys.posix.sys.stat : stat, stat_t;
    import std.string : toStringz;

    stat_t dev, shm;
    if (stat("/dev".toStringz, &dev) != 0 || stat("/dev/shm".toStringz, &shm) != 0
        || dev.st_dev == shm.st_dev)
        return skipTest("/dev/shm is not a separate mount on this host");
    const name = text("sparkles-fsd7-", thisProcessID);
    const dir = buildPath("/dev/shm", name);
    try
        mkdirRecurse(dir);
    catch (Exception e)
        return skipTest("/dev/shm is not writable: " ~ e.msg);
    scope (exit) rmdirRecurse(dir);
    write(buildPath(dir, "f"), "x");

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.glob(text("shm/", name, "/**")).value;
    foreach (i, t; nativeTranscripts("/dev", ResolvePolicy.init, sets, f))
    {
        assert(t == text("members:\n\nempty:\n\nincomplete:\nshm/", name, ": crossesMount\n"),
            text(i ? "RingVfs" : "BlockingVfs", ":\n", t));
    }
    ResolvePolicy crossing;
    crossing.crossMounts = true;
    foreach (i, t; nativeTranscripts("/dev", crossing, sets, f))
        assert(t == text("members:\nshm/", name, "/f\nempty:\n\nincomplete:\n\n"),
            text(i ? "RingVfs" : "BlockingVfs", ":\n", t));
}

/// A `TestSched` that runs out of fibers after `allowed` spawns, as a
/// scheduler whose fiber slab is exhausted does.
struct StarvedSched
{
    import sparkles.event_horizon.capability : SpawnOptions;
    import sparkles.event_horizon.cause : CancelContext, FiberContext;
    import sparkles.event_horizon.testing : TestSched;

    TestSched* sched; ///
    uint allowed;     ///

    ///
    FiberContext* currentContext() @safe nothrow @nogc => sched.currentContext();
    ///
    FiberContext* spawnFiber(scope CancelContext* cc, in SpawnOptions o, void delegate() fn) @trusted nothrow
    {
        if (!allowed)
            return null;
        --allowed;
        return sched.spawnFiber(cc, o, fn);
    }
    ///
    void park() @trusted nothrow { sched.park(); }
    ///
    void wake(FiberContext* f) @trusted nothrow @nogc { sched.wake(f); }
}

/// An interrupted resolving fiber still waits in `LoopExecutor.run` until
/// every request of the batch has finished, since each uses its frame.
@("fileset.driver_loop.runOutlivesNoRequest")
@system unittest
{
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.capability : SpawnOptions;
    import sparkles.event_horizon.cause : FiberContext, Interrupt, InterruptKind, interruptFiber;
    import sparkles.event_horizon.testing : TestSched;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.build_primitives.fileset.machine : Request;

    TestSched sched;
    auto budget = new Admission(4);
    auto gate = Admission(1, inUse: 1); // closed until the interrupter opens it
    uint finished, atReturn = uint.max;
    FiberContext* runner;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            runner = sched.currentContext();
            auto exec = LoopExecutor!TestSched(&sched, budget);
            Request[2] batch;
            exec.run(batch[], (size_t i) {
                assert(!gate.acquire(sched).hasError);
                gate.release();
                ++finished;
            });
            atReturn = finished;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            interruptFiber(runner, Interrupt(InterruptKind.cancelled));
            // Opened only after the woken runner has had its turn.
            cast(void) sched.spawnFiber(null, SpawnOptions.init, () { gate.release(); });
        });
    });
    assert(atReturn == 2, "run returned before its requests finished");
}

/// FSS6: a request performed on the resolving fiber because no fiber was
/// left is admitted by the shared budget like any other.
@("fileset.driver_loop.FSS6.fallbackIsAdmitted")
@system unittest
{
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.capability : SpawnOptions;
    import sparkles.event_horizon.testing : TestSched;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.build_primitives.fileset.machine : Request;

    TestSched sched;
    auto budget = new Admission(1);
    auto gate = Admission(1, inUse: 1);
    uint live, peakLive, finished;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            auto starved = StarvedSched(&sched, 1);
            auto exec = LoopExecutor!StarvedSched(&starved, budget);
            Request[3] batch;
            exec.run(batch[], (size_t i) {
                if (++live > peakLive)
                    peakLive = live;
                assert(!gate.acquire(sched).hasError);
                gate.release();
                --live;
                ++finished;
            });
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () { gate.release(); });
    });
    assert(finished == 3);
    assert(peakLive == 1, text(peakLive, " requests in flight under a budget of one"));
}

/// Work a scheme spawns runs after the call that spawned it has returned,
/// so `LoopExecutor.spawn` keeps its context on the heap: a closure over
/// `visit`'s frame, run once `visit` is gone, reads what it captured. The
/// scheme aborts, so the work also runs on the failure path.
version (Posix)
@("fileset.driver_loop.spawnedWorkOutlivesItsCreator")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.event_horizon.admission : Admission;
    import sparkles.event_horizon.sched : Sched;
    import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
    import sparkles.build_primitives.fileset.machine : ResolutionErrorCode;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    static struct Aborting
    {
        alias Result = bool;
        uint* spawned, done;
        bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
        {
            foreach (_; 0 .. 3)
            {
                ++*spawned;
                auto d = done;
                exec.spawn(() { ++*d; });
            }
            return false;
        }
        bool incomplete(scope const(char)[] path, ErrorKind kind) => true;
        bool finish() => true;
    }

    import std.file : rmdirRecurse;
    import sparkles.event_horizon.vfs : RingVfs;

    const dir = scratchTree("fss7");
    scope (exit) rmdirRecurse(dir);
    materialize("a\nb\n", dir);
    auto sets = Filesets(CasePolicy.sensitive);
    Sched sched;
    schedOrSkip(sched);
    uint spawned, done, doneAtReturn = uint.max;
    bool schemeFailed;
    auto ran = sched.run(() {
        auto root = openRoot!(Rights.readOnly)(new RingVfs, dir, ambientAuthority());
        auto exec = LoopExecutor!Sched(&sched, new Admission(1));
        auto s = Aborting(&spawned, &done);
        const r = resolveScheme(root.value.borrow, sets, sets.everything, s, exec);
        schemeFailed = r.hasError && r.error.code == ResolutionErrorCode.schemeFailed;
        doneAtReturn = done;
    });
    assert(!ran.hasError);
    assert(schemeFailed);
    assert(spawned == 3 && doneAtReturn == 3, text(doneAtReturn, " of ", spawned, " spawned jobs ran"));
}

/// An executor that runs a batch inline but holds a scheme's spawned work
/// until `join`, so a resolution that does not join leaves it unrun.
struct DeferringExecutor
{
    import sparkles.build_primitives.fileset.machine : Request;

    void delegate()[] deferred; ///

    /// Runs `batch` inline.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        foreach (i; 0 .. batch.length)
            perform(i);
    }

    /// Holds `work` until `join`.
    void spawn(void delegate() work)
    {
        deferred ~= work;
    }

    /// Runs everything spawned.
    void join()
    {
        foreach (w; deferred)
            w();
        deferred = null;
    }
}

/// FSS7 on the failure path: a scheme that spawns work and then aborts
/// fails the resolution only once that work has run.
@("fileset.scheme.FSS7.failureJoins")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.machine : ResolutionErrorCode;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    static struct Aborting
    {
        alias Result = bool;
        uint spawned, done;
        bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
        {
            foreach (_; 0 .. 3)
            {
                ++spawned;
                exec.spawn(() { ++done; });
            }
            return false;
        }
        bool incomplete(scope const(char)[] path, ErrorKind kind) => true;
        bool finish() => true;
    }

    auto tree = openFixture("a\nb\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    DeferringExecutor exec;
    Aborting s;
    const r = resolveScheme(root.value.borrow, sets, sets.everything, s, exec);
    assert(r.hasError && r.error.code == ResolutionErrorCode.schemeFailed);
    assert(s.spawned == 3 && s.done == 3, text(s.done, " of ", s.spawned, " spawned jobs ran"));
}

/// A sink that records which rule decided each entry (FSI3).
struct DecisionCollector
{
    PathCollector paths;  /// the members, as `PathCollector` collects them
    string[string] rules; /// `source:line` by path
    bool[string] excludedDirs; /// the directories a rule excluded

    /// Receives a resolved directory.
    void directory(Members)(scope const(char)[] path, Members names, bool empty)
        => paths.directory(path, names, empty);

    /// Receives an entry that could not be read.
    void incomplete(scope const(char)[] path, ErrorKind kind) => paths.incomplete(path, kind);

    /// Receives the rule deciding an entry.
    void ignoreDecision(scope const(char)[] path, bool isDir, bool excluded,
        scope const(char)[] source, uint line, scope const(char)[] pattern)
    {
        import std.conv : text;

        rules[path.idup] = text(source, ":", line);
        if (isDir && excluded)
            excludedDirs[path.idup] = true;
    }
}

version (Posix)
{
    import sparkles.build_primitives.testing : TmpGitRepo, gitAvailable;

    /// Materializes `literal` in a fresh repository and resolves `everything -
    /// gitignored - /.git` there, recording decisions.
    private DecisionCollector resolveInRepository(ref TmpGitRepo repo, string literal) @system
    {
        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.event_horizon.sys : BlockingVfs;

        materialize(literal, repo.dir);
        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, repo.dir, ambientAuthority());
        assert(!root.hasError);
        auto sets = Filesets(CasePolicy.sensitive);
        const f = sets.difference(sets.difference(sets.everything, sets.gitignored),
            sets.glob("/.git").value);
        DecisionCollector sink;
        const r = resolve(root.value.borrow, sets, f, sink);
        assert(!r.hasError, r.hasError ? r.error.context : "");
        return sink;
    }

    // Git with no global excludes file, so only the repository's rules apply.
    private auto gitOracle(ref TmpGitRepo repo, string[] args) @safe
    {
        import std.path : buildPath;

        return repo.git(["-c", "core.excludesFile=" ~ buildPath(repo.dir, ".git", "no-such-file")]
            ~ args);
    }

    /// FSI4's detection: on the nested fixture, the members are exactly the
    /// files git reports as untracked and not ignored.
    @("fileset.machine.FSI4.matchesGit")
    @system unittest
    {
        import std.algorithm.sorting : sort;
        import std.array : array;
        import std.string : lineSplitter;

        import sparkles.build_primitives.testing : TmpGitRepo, gitAvailable;
        import sparkles.test_runner.skip : skipTest;

        if (!gitAvailable)
            return skipTest("git is not on PATH");
        auto repo = TmpGitRepo.create();
        auto got = resolveInRepository(repo, nestedScopes).paths.members.sort.release;
        const listed = gitOracle(repo, ["ls-files", "--others", "--exclude-standard"]);
        assert(listed.status == 0, listed.output);
        auto want = listed.output.lineSplitter.array.sort.release;
        assert(got == want, "machine: " ~ got.to!string ~ "\ngit:     " ~ want.to!string);
        assert(got == nestedScopesKept);
    }

    /// FSI3's detection: for every path of the fixture, the file and line
    /// of the deciding rule are those `git check-ignore -v` reports; beneath
    /// an excluded directory, git names the rule that excluded it.
    @("fileset.machine.FSI3.checkIgnoreParity")
    @system unittest
    {
        import std.algorithm.searching : findSplit, startsWith;
        import std.algorithm.sorting : sort;
        import std.array : array, join;
        import std.file : SpanMode, dirEntries;
        import std.path : relativePath;
        import std.string : lineSplitter;

        import sparkles.build_primitives.testing : TmpGitRepo, gitAvailable;
        import sparkles.test_runner.skip : skipTest;

        if (!gitAvailable)
            return skipTest("git is not on PATH");
        auto repo = TmpGitRepo.create();
        auto seen = resolveInRepository(repo, nestedScopes);

        string[] paths;
        foreach (e; dirEntries(repo.dir, SpanMode.breadth, false))
        {
            const p = relativePath(e.name, repo.dir);
            if (p != ".git" && !p.startsWith(".git/"))
                paths ~= p;
        }
        paths.sort;

        // `-n` reports every path, `::` when no rule matched.
        const asked = gitOracle(repo, ["check-ignore", "-v", "-n", "--no-index", "--"] ~ paths);
        string[string] git;
        foreach (line; asked.output.lineSplitter)
        {
            auto tab = line.findSplit("\t");
            auto where = tab[0];
            // `source:line:pattern`: the pattern may hold `:` itself.
            auto first = where.findSplit(":");
            auto second = first[2].findSplit(":");
            git[tab[2]] = first[0].length ? first[0] ~ ":" ~ second[0] : "";
        }
        assert(git.length == paths.length, asked.output);

        string ours(string p)
        {
            // Beneath an excluded directory, the rule that excluded it.
            foreach (i, c; p)
                if (c == '/' && p[0 .. i] in seen.excludedDirs)
                    return seen.rules[p[0 .. i]];
            if (auto r = p in seen.rules)
                return *r;
            return "";
        }

        string[] mismatches;
        foreach (p; paths)
            if (ours(p) != git[p])
                mismatches ~= p ~ ": machine `" ~ ours(p) ~ "`, git `" ~ git[p] ~ "`";
        assert(mismatches.length == 0, mismatches.join("\n"));
    }
}

// ------------------------------------------------------------------ M5: schemes

/// A stream recording each directory's entries as `name` (a file),
/// `name/` (a directory) or `name->target` (a link), and the order it saw
/// directories in.
struct RecordingScheme(EntryOrder o, FsoMetadata m = FsoMetadata.none)
{
    import sparkles.build_primitives.fileset.fso : FsoFingerprint, FsoKind;

    enum order = o;
    enum metadata = m;
    alias Result = string[];

    string[] dirs;            /// each directory's path, in visiting order
    string[][string] entries; /// each directory's entries
    long[string] mtimes;      /// the mtime of each member that has one
    bool[string] executable;  /// each member file's executable bit
    FsoFingerprint[string] fingerprints; /// each member file's, when declared

    bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
    {
        dirs ~= path.idup;
        string[] got;
        foreach (e; es)
        {
            const full = (path.length ? path ~ "/" ~ e.name : e.name).idup;
            final switch (e.node.kind)
            {
                case FsoKind.directory:
                    got ~= e.name.idup ~ "/";
                    break;
                case FsoKind.regular:
                    got ~= e.name.idup;
                    executable[full] = e.node.executable;
                    break;
                case FsoKind.symlink:
                    got ~= e.name.idup ~ "->" ~ e.node.target.idup;
                    break;
            }
            if (e.hasFingerprint)
                fingerprints[full] = e.fingerprint;
            if (e.hasMtime)
                mtimes[full] = e.mtimeNs;
        }
        entries[path.idup] = got;
        return true;
    }

    bool incomplete(scope const(char)[] path, ErrorKind kind) => true;

    string[] finish() => dirs;
}

/// A fold rendering each directory as `[entry,…]`, a subdirectory as its
/// name followed by its own rendering.
struct RenderingFold(EntryOrder o)
{
    import sparkles.build_primitives.fileset.fso : FsoKind;

    enum order = o;
    enum traversal = Traversal.fold;
    alias Value = string;
    alias Result = string;

    string[] seen; /// each directory's path, in the order it was folded

    bool fold(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec,
        out string value)
    {
        assert(!seen.canFind(path), "a directory is folded once");
        seen ~= path.idup;
        string[] parts;
        foreach (e; es)
            parts ~= e.node.kind == FsoKind.directory ? e.name.idup ~ e.value : e.name.idup;
        value = "[" ~ parts.join(",") ~ "]";
        return true;
    }

    bool incomplete(scope const(char)[] path, ErrorKind kind) => true;

    string finish(ref string root) => root;
}

/// Resolves `f` on a fresh in-memory tree with `scheme`, recording requests.
auto schemeResolve(S)(string literal, ref const Filesets sets, Fileset f, ref S scheme,
    out RecordingExecutor exec)
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto tree = openFixture(literal);
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto r = resolveScheme(root.value.borrow, sets, f, scheme, exec);
    assert(!r.hasError, r.hasError ? r.error.context : "");
    return r.value;
}

/// FSS1: each order, pinned by the `a` versus `a.b` fixture (a link `0`
/// tells `partitionedOrder` apart), for a stream and for a fold.
@("fileset.scheme.FSS1.orders")
@system unittest
{
    enum literal = "a/x\na.b\n0 -> x\n";
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;
    RecordingExecutor exec;

    RecordingScheme!(EntryOrder.narOrder) nar;
    schemeResolve(literal, sets, f, nar, exec);
    assert(nar.entries[""] == ["0->", "a/", "a.b"]);
    RecordingScheme!(EntryOrder.gitTreeOrder) git;
    schemeResolve(literal, sets, f, git, exec);
    assert(git.entries[""] == ["0->", "a.b", "a/"]);
    RecordingScheme!(EntryOrder.partitionedOrder) part;
    schemeResolve(literal, sets, f, part, exec);
    assert(part.entries[""] == ["a/", "a.b", "0->"]);

    RenderingFold!(EntryOrder.narOrder) narFold;
    assert(schemeResolve(literal, sets, f, narFold, exec) == "[0,a[x],a.b]");
    RenderingFold!(EntryOrder.gitTreeOrder) gitFold;
    assert(schemeResolve(literal, sets, f, gitFold, exec) == "[0,a.b,a[x]]");
}

/// FSS5: a fold over `none` does not compile; over a declared order it does.
@("fileset.scheme.FSS5.foldNeedsOrder")
@system unittest
{
    import sparkles.base.vfs.mem : MemVfs;
    import sparkles.build_primitives.fileset.scheme : resolveScheme, shapeOf;

    alias Bad = RenderingFold!(EntryOrder.none);
    alias Good = RenderingFold!(EntryOrder.gitTreeOrder);
    static assert(!__traits(compiles, shapeOf!Bad));
    static assert(!__traits(compiles, (DirRef!(MemVfs, Rights.readOnly) r, ref const Filesets s,
        Fileset f, ref Bad b, ref RecordingExecutor e) => resolveScheme(r, s, f, b, e)));
    static assert(__traits(compiles, (DirRef!(MemVfs, Rights.readOnly) r, ref const Filesets s,
        Fileset f, ref Good g, ref RecordingExecutor e) => resolveScheme(r, s, f, g, e)));
    // A stream may leave its order undeclared.
    static assert(shapeOf!(RecordingScheme!(EntryOrder.none)).order == EntryOrder.none);
}

/// FSS3, FSM5: a fold sees each directory once, after all its
/// subdirectories, and the directories above the start roots last, the
/// fileset root holding everything; a stream sees each directory before its
/// subdirectories.
@("fileset.scheme.FSS3.traversal")
@system unittest
{
    enum literal = "src/a.d\nsrc/b/c.d\nsrc/b/d.txt\ndocs/i.md\nother/x\nlib/x/y/z.d\n";
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;

    const planned = sets.unionOf(sets.glob("/src/**/*.d").value, sets.glob("/docs/*.md").value,
        sets.glob("/lib/x/y/*.d").value);
    RenderingFold!(EntryOrder.narOrder) fold;
    assert(schemeResolve(literal, sets, planned, fold, exec)
        == "[docs[i.md],lib[x[y[z.d]]],src[a.d,b[c.d]]]");
    assert(fold.seen == ["docs", "lib/x/y", "lib/x", "lib", "src/b", "src", ""], fold.seen.join(" "));

    // A start root that holds nothing leaves the fileset root empty.
    RenderingFold!(EntryOrder.narOrder) none;
    assert(schemeResolve(literal, sets, sets.glob("/nope/*.d").value, none, exec) == "[]");
    // The fileset root as the start root.
    RenderingFold!(EntryOrder.narOrder) all;
    assert(schemeResolve("a/b\nc\n", sets, sets.everything, all, exec) == "[a[b],c]");

    RecordingScheme!(EntryOrder.none) stream;
    assert(schemeResolve(literal, sets, sets.everything, stream, exec)
        == ["", "docs", "lib", "lib/x", "lib/x/y", "other", "src", "src/b"]);
}

/// A stream that declares `leave` hears each directory end once its subtree
/// is done, the handle of its entries still open; a stream that does not is
/// never told, and a fold may not declare it.
@("fileset.scheme.FSS3.leave")
@system unittest
{
    import sparkles.base.vfs.mem : MemVfs;
    import sparkles.base.vfs.types : OpenMode;
    import sparkles.build_primitives.fileset.fso : FsoKind;
    import sparkles.build_primitives.fileset.scheme : FsoRef, shapeOf;

    static struct Leaving
    {
        alias Result = string[];
        string[] events;
        string[] laterFiles; // a directory's files, read again at its `leave`
        FsoRef!(MemVfs, Rights.readOnly)[][string] refs;

        bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
        {
            events ~= "visit " ~ path.idup;
            foreach (e; es)
                if (e.node.kind == FsoKind.regular)
                    refs[path.idup] ~= e.ref_;
            return true;
        }

        bool leave(Exec)(scope const(char)[] path, ref Exec exec)
        {
            events ~= "leave " ~ path.idup;
            foreach (r; refs.get(path.idup, null))
            {
                auto file = r.dir.openFile!(OpenMode.read)(r.name);
                assert(!file.hasError, "a directory's handle is open until its leave");
                laterFiles ~= r.name.idup;
            }
            return true;
        }

        bool incomplete(scope const(char)[] path, ErrorKind kind) => false;
        string[] finish() => events;
    }

    static assert(shapeOf!Leaving.leave);
    static assert(!shapeOf!(RecordingScheme!(EntryOrder.none)).leave);
    static struct FoldLeaving
    {
        enum order = EntryOrder.narOrder;
        enum traversal = Traversal.fold;
        alias Value = int;
        alias Result = int;
        bool leave(Exec)(scope const(char)[] path, ref Exec exec) => true;
    }
    static assert(!__traits(compiles, shapeOf!FoldLeaving));

    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    Leaving s;
    const events = schemeResolve("a/b/y\na/x\nc\nd/\n", sets, sets.everything, s, exec);
    assert(events == ["visit ", "visit a", "visit a/b", "leave a/b", "leave a", "visit d",
        "leave d", "leave "], events.join(" | "));
    assert(s.laterFiles == ["y", "x", "c"], s.laterFiles.join(" "));
}

/// FSS2, FSO4: what a scheme declares, and only that, is requested; a
/// declared mtime arrives with the stat that brings the executable bit.
@("fileset.scheme.FSS2.metadata")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    enum literal = "bin/run +x\nbin/notes\nlink -> bin/run\n";
    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    RecordingExecutor bare;
    RecordingScheme!(EntryOrder.narOrder) none;
    schemeResolve(literal, sets, f, none, bare);
    assert(bare.stats == 0 && bare.links == 0, "a scheme declaring nothing causes no stat");
    assert(none.executable["bin/run"] == false, "an undeclared bit reads false");
    assert(none.mtimes.length == 0);

    RecordingExecutor exe;
    RecordingScheme!(EntryOrder.narOrder, FsoMetadata.executable) bits;
    schemeResolve(literal, sets, f, bits, exe);
    assert(exe.stats == 2 && exe.links == 0, "one stat per member file, none for the link");
    assert(bits.executable["bin/run"] && !bits.executable["bin/notes"]);

    auto tree = openFixture(literal);
    assert(tree.value.get().vfs.setMtime("bin/notes", 1_234_567_890));
    assert(tree.value.get().vfs.setMtime("link", 42));
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    RecordingExecutor timed;
    RecordingScheme!(EntryOrder.narOrder, cast(FsoMetadata)(FsoMetadata.mtime | FsoMetadata.executable)) times;
    assert(!resolveScheme(root.value.borrow, sets, f, times, timed).hasError);
    assert(timed.stats == 3, "a declared mtime stats links too, in the same batch");
    assert(times.mtimes["bin/notes"] == 1_234_567_890 && times.mtimes["link"] == 42);
    assert("bin" !in times.mtimes, "a directory carries no mtime");
}

/// FSC2: a declared fingerprint arrives for each member file, from the one
/// stat that brings its size, both times and its identity; a link, which
/// a cache compares by its target, causes no stat on its account.
@("fileset.scheme.FSC2.fingerprint")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;
    auto tree = openFixture("bin/run +x\nbin/notes\nlink -> bin/run\n");
    auto vfs = &tree.value.get().vfs;
    vfs.clockNs = 70;
    assert(vfs.writeFile("bin/notes", cast(const(ubyte)[]) "twelve bytes"));
    assert(vfs.setMtime("bin/notes", 5));
    auto root = openRoot!(Rights.readOnly)(vfs, "", ambientAuthority());

    RecordingExecutor exec;
    RecordingScheme!(EntryOrder.narOrder, FsoMetadata.fingerprint) s;
    assert(!resolveScheme(root.value.borrow, sets, f, s, exec).hasError);
    assert(exec.stats == 2, "one stat per member file, none for the link");
    assert(s.fingerprints.length == 2 && "link" !in s.fingerprints);
    const notes = s.fingerprints["bin/notes"], run = s.fingerprints["bin/run"];
    assert(notes.size == 12 && notes.mtimeNs == 5 && notes.ctimeNs == 70);
    assert(run.ctimeNs == 0 && run.device == notes.device && run.inode != notes.inode);
    assert(s.mtimes.length == 0, "a fingerprint is not a declared mtime");
}

/// FSO2: a link's target is data. Reading it names only the link; nothing
/// is ever asked of the target's path, inside the root or outside it.
@("fileset.scheme.FSO2.linkTargetsAreData")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    auto tree = openFixture("secret/key\nr/f\nr/out -> /etc/passwd\nr/up -> ../secret/key\nr/d/in -> ../f\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "r", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    RecordingScheme!(EntryOrder.narOrder, FsoMetadata.linkTarget) s;
    assert(!resolveScheme(root.value.borrow, sets, sets.everything, s, exec).hasError);
    assert(s.entries[""] == ["d/", "f", "out->/etc/passwd", "up->../secret/key"]);
    assert(s.entries["d"] == ["in->../f"]);
    assert(exec.links == 3 && exec.stats == 0);
    foreach (n; exec.names)
        assert(!n.canFind("etc") && !n.canFind("secret") && n != "../f", n);
    // A link whose verdict needs the executable bit is decided without a stat.
    RecordingExecutor exe;
    RecordingScheme!(EntryOrder.narOrder) plain;
    assert(!resolveScheme(root.value.borrow, sets, sets.executable, plain, exe).hasError);
    assert(exe.stats == 1 && exe.links == 0, "only the regular file `f` is stat-ed");
}

/// A fold digesting its members' content, read through each entry's
/// reference (FSS4); it fails on a file reading `bad` (FSE1), and refuses a
/// resolution with any incomplete entry unless told to tolerate them (FSE2).
struct DigestFold
{
    import sparkles.build_primitives.fileset.fso : FsoKind;

    enum order = EntryOrder.gitTreeOrder;
    enum traversal = Traversal.fold;
    alias Value = ulong;
    alias Result = ulong;

    bool tolerate;
    string why;

    bool fold(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec,
        out ulong value)
    {
        import sparkles.base.vfs.types : OpenMode;

        ulong h = 1_469_598_103_934_665_603;
        void mix(scope const(char)[] bytes)
        {
            foreach (c; bytes)
                h = (h ^ c) * 1_099_511_628_211;
        }

        foreach (e; es)
        {
            mix(e.name);
            if (e.node.kind == FsoKind.directory)
            {
                h = (h ^ e.value) * 1_099_511_628_211;
                continue;
            }
            auto file = e.ref_.dir.openFile!(OpenMode.read)(e.ref_.name);
            if (file.hasError)
                return failWith("a member could not be opened");
            ubyte[64] buf;
            auto n = file.value.read(buf[]);
            if (n.hasError)
                return failWith("a member could not be read");
            const text = cast(const(char)[]) buf[0 .. n.value];
            if (text == "bad")
                return failWith("a member is corrupt");
            mix(text);
        }
        value = h;
        return true;
    }

    bool incomplete(scope const(char)[] path, ErrorKind kind)
        => tolerate || failWith("the resolution is incomplete");

    string failure() => why;

    ulong finish(ref ulong root) => root;

    private bool failWith(string s)
    {
        why = s;
        return false;
    }
}

/// FSE1, FSE2, FSE4: a scheme failing mid-file aborts the resolution; an
/// incomplete one completes and says so, and a consumer needing
/// completeness refuses it; each scheme's result is its own type.
@("fileset.scheme.FSE.failures")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : PathScheme, SchemeResult, resolveScheme;

    static assert(is(typeof(SchemeResult!PathScheme.init.value) == PathScheme.Paths));
    static assert(is(typeof(SchemeResult!DigestFold.init.value) == ulong));

    auto sets = Filesets(CasePolicy.sensitive);
    const f = sets.everything;

    auto good = openFixture("a = one\nd/b = two\n");
    auto goodRoot = openRoot!(Rights.readOnly)(&good.value.get().vfs, "", ambientAuthority());
    RecordingExecutor exec;
    DigestFold digest;
    auto ok = resolveScheme(goodRoot.value.borrow, sets, f, digest, exec);
    assert(!ok.hasError && ok.value != 0);
    assert(exec.reads.length == 0, "the machine requested no content (FSM4)");

    auto bad = openFixture("a = one\nd/b = bad\n");
    auto badRoot = openRoot!(Rights.readOnly)(&bad.value.get().vfs, "", ambientAuthority());
    DigestFold failing;
    auto aborted = resolveScheme(badRoot.value.borrow, sets, f, failing, exec);
    assert(aborted.hasError && aborted.error.code == ResolutionErrorCode.schemeFailed);
    assert(aborted.error.context == "a member is corrupt");

    auto mounted = openFixture("a = one\nm/b = two\n");
    assert(mounted.value.get().vfs.mount("m"));
    auto mRoot = openRoot!(Rights.readOnly)(&mounted.value.get().vfs, "", ambientAuthority());
    PathScheme paths;
    auto listed = resolveScheme(mRoot.value.borrow, sets, f, paths, exec);
    assert(!listed.hasError);
    assert(listed.value.members == ["a"] && listed.value.unreadable == ["m: crossesMount"]);
    DigestFold strict;
    auto refused = resolveScheme(mRoot.value.borrow, sets, f, strict, exec);
    assert(refused.hasError && refused.error.context == "the resolution is incomplete");
    DigestFold lenient;
    lenient.tolerate = true;
    assert(!resolveScheme(mRoot.value.borrow, sets, f, lenient, exec).hasError);
}

/// FSS8: a scheme can verify an entry against a tree supplied out of band —
/// here a sibling `.idsig`, located through the entry's reference — without
/// reading the entry itself.
@("fileset.scheme.FSS8.suppliedTree")
@system unittest
{
    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.base.vfs.types : OpenMode;
    import sparkles.build_primitives.fileset.scheme : resolveScheme;

    static struct Verifier
    {
        enum order = EntryOrder.narOrder;
        alias Result = string[];
        string[string] expected; // the root each artifact must have
        string[] opened, verified;

        bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
        {
            foreach (e; es)
            {
                const want = e.name in expected;
                if (want is null)
                    continue;
                const sig = (e.ref_.name ~ ".idsig").idup;
                opened ~= sig;
                auto file = e.ref_.dir.openFile!(OpenMode.read)(sig);
                if (file.hasError)
                    return false;
                ubyte[64] buf;
                auto n = file.value.read(buf[]);
                if (n.hasError || cast(const(char)[]) buf[0 .. n.value] != *want)
                    return false;
                verified ~= e.name.idup;
            }
            return true;
        }

        bool incomplete(scope const(char)[] path, ErrorKind kind) => false;

        string[] finish() => verified;
    }

    auto tree = openFixture("app.apk = payload\napp.apk.idsig = 7f3a\n");
    auto root = openRoot!(Rights.readOnly)(&tree.value.get().vfs, "", ambientAuthority());
    auto sets = Filesets(CasePolicy.sensitive);
    RecordingExecutor exec;
    Verifier v;
    v.expected["app.apk"] = "7f3a";
    auto r = resolveScheme(root.value.borrow, sets, sets.glob("*.apk").value, v, exec);
    assert(!r.hasError && r.value == ["app.apk"]);
    assert(v.opened == ["app.apk.idsig"], "the artifact itself is never opened");
}

/// FSO3: membership ignores timestamps and every permission bit but the
/// executable one, on a native file system.
@("fileset.scheme.FSO3.excludedMetadata")
@system unittest
{
    import std.datetime.systime : SysTime;
    import std.file : rmdirRecurse, setAttributes, setTimes;
    import std.path : buildPath;

    import sparkles.base.vfs.handles : ambientAuthority, openRoot;
    import sparkles.build_primitives.fileset.scheme : PathScheme, resolveScheme;
    import sparkles.event_horizon.sys : BlockingVfs;

    enum literal = "src/a.d\nsrc/b.d\nbin/run +x\nbin/tool +x\n";
    string[] resolveWithModes(uint fileMode, uint exeMode, long stamp, Fileset delegate(ref Filesets) make)
    {
        const dir = scratchTree("fso3");
        scope (exit) rmdirRecurse(dir);
        materialize(literal, dir);
        foreach (p; ["src/a.d", "src/b.d"])
        {
            setAttributes(buildPath(dir, p), fileMode);
            setTimes(buildPath(dir, p), SysTime(stamp), SysTime(stamp));
        }
        foreach (p; ["bin/run", "bin/tool"])
        {
            setAttributes(buildPath(dir, p), exeMode);
            setTimes(buildPath(dir, p), SysTime(stamp), SysTime(stamp));
        }
        auto vfs = new BlockingVfs;
        auto root = openRoot!(Rights.readOnly)(vfs, dir, ambientAuthority());
        auto sets = Filesets(CasePolicy.sensitive);
        RecordingExecutor exec;
        PathScheme paths;
        auto r = resolveScheme(root.value.borrow, sets, make(sets), paths, exec);
        assert(!r.hasError);
        return r.value.members;
    }

    Fileset delegate(ref Filesets)[] makers = [delegate(ref Filesets s) => s.everything,
        delegate(ref Filesets s) => s.executable,
        delegate(ref Filesets s) => s.difference(s.everything, s.executable)];
    foreach (make; makers)
    {
        const a = resolveWithModes(octal!644, octal!755, 0, make);
        const b = resolveWithModes(octal!600, octal!700, 1_000_000_000_000_000, make);
        assert(a.length && a == b, a.join(",") ~ " | " ~ b.join(","));
    }
}

version (Posix)
{
    /**
    FSS4, FSS6, FSS7 on the event-horizon driver: a stream that reads the
    two halves of each member concurrently, each through its own handle on
    the entry's directory. With a budget of one in-flight operation shared
    with the walk, nothing ever runs two at once, and the result is not
    returned before every half was read.
    */
    @("fileset.scheme.FSS4.schemeOwnedReads")
    @system unittest
    {
        import std.file : rmdirRecurse;

        import sparkles.base.vfs.handles : ambientAuthority, openRoot;
        import sparkles.base.vfs.types : OpenMode;
        import sparkles.build_primitives.fileset.driver : filesetRights;
        import sparkles.build_primitives.fileset.driver_loop : LoopExecutor;
        import sparkles.build_primitives.fileset.scheme : resolveScheme;
        import sparkles.event_horizon.admission : Admission;
        import sparkles.event_horizon.sched : Sched;
        import sparkles.event_horizon.vfs : RingVfs;

        static struct Halves
        {
            import sparkles.build_primitives.fileset.fso : FsoKind;

            enum order = EntryOrder.narOrder;
            alias Result = size_t;
            size_t spawned, done, bytes;

            bool visit(Entries, Exec)(scope const(char)[] path, Entries es, bool empty, ref Exec exec)
            {
                foreach (e; es)
                {
                    if (e.node.kind != FsoKind.regular)
                        continue;
                    // Opened now, while the reference is valid; read later.
                    foreach (half; 0 .. 2)
                        if (!launch(exec, e.ref_.dir.openFile!(OpenMode.read)(e.ref_.name), half))
                            return false;
                }
                return true;
            }

            // Spawns the read of one half of `opened`, which the closure owns.
            bool launch(Exec, F)(ref Exec exec, F opened, size_t half)
            {
                import core.lifetime : move;

                if (opened.hasError)
                    return false;
                // On the heap: a struct a closure captures is still destroyed
                // when this frame ends.
                auto held = new typeof(opened.value)[1];
                held[0] = move(opened.value);
                ++spawned;
                exec.spawn(() {
                    ubyte[4] buf;
                    // The second half skips the first.
                    if (half == 1)
                        assert(!held[0].read(buf[]).hasError);
                    auto n = held[0].read(buf[]);
                    assert(!n.hasError && n.value == 4);
                    bytes += n.value;
                    ++done;
                });
                return true;
            }

            bool incomplete(scope const(char)[] path, ErrorKind kind) => false;

            size_t finish()
            {
                assert(done == spawned, "the result came before the scheme's work");
                return bytes;
            }
        }

        Sched s;
        schedOrSkip(s);
        const dir = scratchTree("halves");
        scope (exit) rmdirRecurse(dir);
        materialize("a = 01234567\nd/b = abcdefgh\nd/c = ABCDEFGH\n", dir);
        auto sets = Filesets(CasePolicy.sensitive);
        size_t bytes;
        uint peak;
        auto r = s.run(() {
            auto rv = new RingVfs;
            auto root = openRoot!(Rights.readOnly)(rv, dir, ambientAuthority());
            auto budget = new Admission(1);
            auto exec = LoopExecutor!Sched(&s, budget);
            Halves h;
            auto got = resolveScheme(root.value.borrow, sets, sets.everything, h, exec);
            assert(!got.hasError, got.hasError ? got.error.context : "");
            bytes = got.value;
            peak = exec.peak;
        });
        assert(!r.hasError);
        assert(bytes == 24);
        assert(peak == 1);
    }
}
