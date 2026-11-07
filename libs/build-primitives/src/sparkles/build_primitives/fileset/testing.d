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
import std.random : Mt19937, uniform;

import sparkles.base.vfs.handles : DirRef;
import sparkles.base.vfs.types : EntryKind, Rights;

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
        exec = st.value.executable;
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
