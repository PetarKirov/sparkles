/**
A compile's search probes (build-graph SPEC BGK2): the roots its import and
string-import searches went through, in order, and where each lookup
resolved, as the compiler's `--makedeps-probes` writes them.

The absent candidates a manifest must hold absent are a product: every
candidate of a module under every root before the one it resolved in, and
the candidates before its own in that root. The compiler writes the
factors, a few thousand short lines where the expanded list is tens of
thousands of long ones, and $(LREF eachAbsent) expands them where a check
needs the paths:

---
format 1
candidates .di .d /package.di /package.d .i .h .c
root libs/ui/src
root libs/base/src
root .
probe 1 1 sparkles/base/text
probe - - sparkles/missing
string-root gen
string 0 effects.glsl
absent include/never.h
---

`probe 1 1 sparkles/base/text` resolved at root 1 as its candidate 1
(`libs/base/src/sparkles/base/text.d`), so every candidate under
`libs/ui/src` and `libs/base/src/sparkles/base/text.di` were absent;
`probe - -` failed under every root. `string K name` resolved at
string-root `K`, `string - name` nowhere. An `absent` line is a probed
path no rule above covers, kept as it is.

A root in the Nix store holds no candidate a check needs: a store path's
contents are its name's, so nothing can appear in it
($(LREF isImmutableRoot)). $(LREF Probes.withoutImmutableRoots) drops the
lookups that stand for nothing else.
*/
module sparkles.build_graph.probes;

import std.conv : text, to;

/// A lookup that resolved nowhere.
enum size_t unresolved = size_t.max;

/// One module lookup: where it resolved (BGK2).
struct ModuleProbe
{
    string stem;                  /// the module's path without its extension (`sparkles/base/text`)
    size_t root = unresolved;     /// the root it resolved under, or `unresolved`
    size_t candidate;             /// the candidate it resolved as, under `root`
}

/// One string-import lookup: where it resolved (BGK2).
struct StringProbe
{
    string name;              /// the import expression's file name
    size_t root = unresolved; /// the string-root it resolved under, or `unresolved`
}

/// A compile's search probes (BGK2).
struct Probes
{
    string[] candidates;   /// what a module's stem is tried with, in order (`.di`, `/package.d`, …)
    string[] roots;        /// the import roots, in search order
    ModuleProbe[] modules; /// in first-lookup order
    string[] stringRoots;  /// the string-import roots, in search order
    StringProbe[] strings; /// in first-lookup order

    /// The canonical text, as the compiler writes it.
    string text() const @safe pure
    {
        import std.array : appender, join;

        auto s = appender!string;
        s ~= "format 1\ncandidates " ~ candidates.join(" ") ~ "\n";
        foreach (r; roots)
            s ~= "root " ~ r ~ "\n";
        foreach (ref m; modules)
            s ~= m.root == unresolved ? "probe - - " ~ m.stem ~ "\n"
                : "probe " ~ m.root.to!string ~ " " ~ m.candidate.to!string ~ " " ~ m.stem ~ "\n";
        foreach (r; stringRoots)
            s ~= "string-root " ~ r ~ "\n";
        foreach (ref p; strings)
            s ~= "string " ~ (p.root == unresolved ? "-" : p.root.to!string) ~ " " ~ p.name ~ "\n";
        return s[];
    }

    /// The SHA-256 of $(LREF Probes.text): the name a store keeps it under.
    string digest() const @safe pure
    {
        import std.digest : toHexString, LetterCase;
        import std.digest.sha : sha256Of;

        return sha256Of(text).toHexString!(LetterCase.lower).idup;
    }

    /**
    These probes with each root and string-root named by `name`, and without
    the lookups whose every absent candidate lies under an immutable root
    (item 2 of BGS5's manifests): they stand for nothing a check reads.
    */
    Probes withoutImmutableRoots(scope string delegate(string) @safe name) const @safe
    {
        Probes p;
        p.candidates = candidates.dup;
        foreach (r; roots)
            p.roots ~= name(r);
        foreach (r; stringRoots)
            p.stringRoots ~= name(r);
        bool allImmutable(const string[] rs, size_t below)
        {
            foreach (r; rs[0 .. below < rs.length ? below : rs.length])
                if (!isImmutableRoot(r))
                    return false;
            return true;
        }
        foreach (ref m; modules)
        {
            const before = m.root == unresolved ? p.roots.length : m.root;
            const inOwn = m.root != unresolved && m.candidate > 0 && !isImmutableRoot(p.roots[m.root]);
            if (!allImmutable(p.roots, before) || inOwn)
                p.modules ~= m;
        }
        foreach (ref s; strings)
            if (!allImmutable(p.stringRoots, s.root == unresolved ? p.stringRoots.length : s.root))
                p.strings ~= s;
        return p;
    }
}

/// Whether nothing can appear under `root`: a Nix store path.
bool isImmutableRoot(string root) @safe pure nothrow @nogc
    => root.length >= 11 && root[0 .. 11] == "/nix/store/";

// `rel` under `root`; `.` is the working directory, whose candidates are bare.
package string under(string root, string rel) @safe pure nothrow
{
    import std.algorithm.searching : canFind;
    import std.path : buildNormalizedPath;

    const path = root == "." || root.length == 0 ? rel : root ~ "/" ~ rel;
    // A string import may climb (`import("../x")`), as the paths named() keeps do not.
    return rel.canFind("..") ? buildNormalizedPath(path) : path;
}

/**
Parses `source`, the compiler's `--makedeps-probes` output or a stored
probe block, into `p`, with its `absent` lines in `absent`. False when it
is not in format 1 or a line is malformed: the caller then keys
conservatively, as on no dependency output.
*/
bool parseProbes(const(char)[] source, out Probes p, out string[] absent) @safe pure
{
    import std.algorithm.iteration : splitter;
    import std.array : array;
    import std.string : indexOf;

    bool formatSeen;
    static bool field(return ref const(char)[] rest, out const(char)[] f)
    {
        const sp = rest.indexOf(' ');
        if (sp <= 0)
            return false;
        f = rest[0 .. sp];
        rest = rest[sp + 1 .. $];
        return true;
    }
    static bool index(const(char)[] f, size_t bound, out size_t i)
    {
        if (f == "-")
        {
            i = unresolved;
            return true;
        }
        try
            i = f.to!size_t;
        catch (Exception)
            return false;
        return i < bound;
    }
    // LF only: a CR, like any byte but LF, may be part of a file name the
    // compiler probed (`import("optional\r")`).
    foreach (line; source.splitter('\n'))
    {
        if (!line.length)
            continue;
        const sp = line.indexOf(' ');
        if (sp <= 0)
            return false;
        const word = line[0 .. sp];
        const(char)[] rest = line[sp + 1 .. $];
        switch (word)
        {
        case "format":
            if (rest != "1")
                return false;
            formatSeen = true;
            break;
        case "candidates":
            p.candidates = rest.idup.splitter(' ').array;
            break;
        case "root":
            p.roots ~= rest.idup;
            break;
        case "string-root":
            p.stringRoots ~= rest.idup;
            break;
        case "probe":
            const(char)[] r, c;
            ModuleProbe m;
            if (!field(rest, r) || !field(rest, c) || !rest.length || !index(r, p.roots.length, m.root))
                return false;
            if (m.root == unresolved ? c != "-" : !index(c, p.candidates.length, m.candidate) || m.candidate == unresolved)
                return false;
            m.stem = rest.idup;
            p.modules ~= m;
            break;
        case "string":
            const(char)[] k;
            StringProbe s;
            if (!field(rest, k) || !rest.length || !index(k, p.stringRoots.length, s.root))
                return false;
            s.name = rest.idup;
            p.strings ~= s;
            break;
        case "absent":
            absent ~= rest.idup;
            break;
        default:
            return false;
        }
    }
    return formatSeen && p.candidates.length;
}

/**
Calls `dg` with each absent candidate `p` stands for, in probing order,
skipping those under an immutable root; stops when `dg` returns false.
Returns whether it went through them all.
*/
bool eachAbsent(Dg)(const ref Probes p, scope Dg dg)
{
    foreach (ref m; p.modules)
    {
        const last = m.root == unresolved ? p.roots.length : m.root + 1;
        foreach (i; 0 .. last)
        {
            if (isImmutableRoot(p.roots[i]))
                continue;
            const below = m.root == unresolved || i < m.root ? p.candidates.length : m.candidate;
            foreach (c; p.candidates[0 .. below])
                if (!dg(under(p.roots[i], m.stem ~ c)))
                    return false;
        }
    }
    foreach (ref s; p.strings)
    {
        const last = s.root == unresolved ? p.stringRoots.length : s.root;
        foreach (r; p.stringRoots[0 .. last])
            if (!isImmutableRoot(r) && !dg(under(r, s.name)))
                return false;
    }
    return true;
}

/// Each absent candidate, in probing order (tests and diagnostics).
package string[] absentPaths(const ref Probes p) @safe
{
    string[] all;
    cast(void) eachAbsent(p, (string path) { all ~= path; return true; });
    return all;
}

/// The rules expand to what the compiler's `--makedeps-absent` lists:
/// roots before the resolving one in full, its own candidates before the
/// resolved one, an unresolved lookup everywhere; the text round-trips.
@("build_graph.probes.expand")
@safe unittest
{
    Probes p;
    string[] absent;
    assert(parseProbes("format 1\ncandidates .di .d /package.di\nroot a\nroot b\nroot .\n"
        ~ "probe 1 1 x/y\nprobe 0 2 z\nprobe - - w\nstring-root g\nstring-root h\nstring 1 f.txt\n"
        ~ "string - e.txt\nabsent inc/n.h\n", p, absent));
    assert(absent == ["inc/n.h"]);
    assert(absentPaths(p) == ["a/x/y.di", "a/x/y.d", "a/x/y/package.di", "b/x/y.di", "a/z.di", "a/z.d",
        "a/w.di", "a/w.d", "a/w/package.di", "b/w.di", "b/w.d", "b/w/package.di", "w.di", "w.d", "w/package.di",
        "g/f.txt", "g/e.txt", "h/e.txt"]);
    Probes back;
    string[] none;
    assert(parseProbes(p.text, back, none) && back == p && !none.length);
    assert(p.digest.length == 64 && p.digest == back.digest);
}

/// A malformed or other-format text is refused.
@("build_graph.probes.refusals")
@safe unittest
{
    Probes p;
    string[] absent;
    assert(!parseProbes("format 2\ncandidates .d\n", p, absent));
    assert(!parseProbes("format 1\ncandidates .d\nprobe 0 0 x\n", p, absent), "no root 0");
    assert(!parseProbes("format 1\ncandidates .d\nroot a\nprobe 0 1 x\n", p, absent), "no candidate 1");
    assert(!parseProbes("format 1\ncandidates .d\nroot a\nwhat x\n", p, absent));
    assert(!parseProbes("root a\n", p, absent), "no format line");
}

/// Lookups whose absent candidates all lie in the store are dropped, and
/// their candidates are never expanded.
@("build_graph.probes.withoutImmutableRoots")
@safe unittest
{
    Probes p;
    string[] absent;
    assert(parseProbes("format 1\ncandidates .di .d\nroot /nix/store/abc-druntime\nroot src\n"
        ~ "probe 1 0 app\nprobe 0 1 core/stdc\nprobe 0 0 object\nprobe - - gone\nprobe 1 1 lib\n", p, absent));
    const q = p.withoutImmutableRoots((string r) => r);
    assert(q.modules.length == 2 && q.modules[0].stem == "gone" && q.modules[1].stem == "lib", q.text);
    assert(absentPaths(q) == ["src/gone.di", "src/gone.d", "src/lib.di"]);
}

/// A CR is part of a name, not a line end: a string import probed as
/// `optional\r` stays that name, so creating it is seen.
@("build_graph.probes.crInAName")
@safe unittest
{
    Probes p;
    string[] absent;
    assert(parseProbes("format 1\ncandidates .d\nstring-root g\nstring - optional\r\nabsent x\ry\n", p, absent));
    assert(p.strings.length == 1 && p.strings[0].name == "optional\r");
    assert(absent == ["x\ry"]);
    assert(absentPaths(p) == ["g/optional\r"]);
}
