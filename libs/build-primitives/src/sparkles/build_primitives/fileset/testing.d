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
import std.conv : octal;
import std.random : Mt19937, uniform;

import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : EntryKind, Rights;

import sparkles.build_primitives.fileset.driver : PathCollector, resolve, resolveWith;
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
        if (line[$ - 1] == '/')
        {
            mkdirRecurse(buildPath(dir, line));
            continue;
        }
        string content;
        auto path = line;
        if (auto eq = line.findSplit(" = "))
        {
            path = eq[0];
            content = eq[2];
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

    static immutable machineModules = ["machine.d", "plan.d", "value.d", "pattern.d", "ignore.d"];
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
    void delegate() beforeStats; /// called once, if set

    /// Runs `batch` inline.
    void run(Perform)(scope const(Request)[] batch, scope Perform perform)
    {
        sizes ~= batch.length;
        if (batch.length && batch[0].kind == RequestKind.stat)
        {
            stats += batch.length;
            if (beforeStats !is null)
            {
                beforeStats();
                beforeStats = null;
            }
        }
        foreach (i; 0 .. batch.length)
            perform(i);
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
/// `stat` request; FSM5: units arrive after their children.
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
    assert(sink.members == ["src/b/c.d", "src/a.d", "vendor/x/y"], "units arrive post-order");
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
    assert(byDefault.members == ["real/x.d", "alias", "etc", "up"],
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
    assert(machineResolve(open.value.borrow, sets, f).members == ["m/b", "a"]);
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
