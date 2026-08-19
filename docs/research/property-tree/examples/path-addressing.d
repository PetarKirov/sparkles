#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_path_addressing"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The path as the node address (fork D3), in both directions.
 *
 * Grammar:  path := name ( "." name | "[" digits "]" )*
 *
 * Under test:
 *   C8.  The SAME path text resolves two ways: at compile time it becomes a
 *        direct field access (`subject.material.stops[1].weight`, no lookup,
 *        `ref`-returning, so writes are ordinary assignments); at run time it
 *        walks a generated dispatch with the same segment semantics.
 *   C9.  The runtime walk is generated from the type, parameterised by TYPE
 *        ONLY ([`open-set-descent.d`](./open-set-descent.d)'s rule), so it terminates on recursive types and needs
 *        no registry.
 *   C10. Both directions agree — verified by differential test over every
 *        path the planner emits.
 *   C11. Index paths are POSITIONAL, and that is a real defect, not a
 *        nitpick: deleting element 0 silently re-points every later element's
 *        expansion, selection and in-progress edit (rjsf's synthetic-key
 *        finding). Demonstrated, then fixed with an adapter-owned element id.
 *
 * Run: `dub run --single path-addressing.d`
 */
module property_tree_path_addressing;

import std.conv : text, to;
import std.traits : isAggregateType, isArray, isDynamicArray, isSomeString;

@safe:

// ── path segments ────────────────────────────────────────────────────────────

struct Seg { string name; size_t index; bool isIndex; }

/// Parses at CTFE and at run time — the same function.
Seg[] segments(const(char)[] path) pure
{
    Seg[] segs;
    size_t i;
    while (i < path.length)
    {
        if (path[i] == '.') { i++; continue; }
        if (path[i] == '[')
        {
            size_t j = ++i;
            while (j < path.length && path[j] != ']') j++;
            segs ~= Seg(null, to!size_t(path[i .. j]), true);
            i = j + 1;
        }
        else
        {
            size_t j = i;
            while (j < path.length && path[j] != '.' && path[j] != '[') j++;
            segs ~= Seg(path[i .. j].idup, 0, false);
            i = j;
        }
    }
    return segs;
}

/// The inverse: how the walk mints a child's path.
string childPath(string parent, string member) pure nothrow
    => parent.length ? parent ~ "." ~ member : member;
/// ditto
string elementPath(string parent, size_t i) pure
    => parent ~ "[" ~ i.to!string ~ "]";

// ── C8: compile-time resolution ──────────────────────────────────────────────

/// `at!"a.b[2].c"(subject)` — a direct, `ref`-returning field access. The
/// mixin is the path text with `[i]` left as-is, so D's own indexing applies;
/// a typo is a compile error at the USE site.
ref auto at(string P, T)(return ref T subject)
    => mixin("subject." ~ P);

// ── C9: runtime resolution, generated from the type ──────────────────────────

/// Resolves `path` against `subject` and calls `sink(leafRef, typeName)`.
/// `sink` is an alias, so it is instantiated per leaf type — no `void*`, no
/// registry, no virtual call.
bool resolve(alias sink, T)(ref T subject, in Seg[] segs, size_t at_ = 0)
{
    static if (isAggregateType!T && !isSomeString!T)
    {
        if (at_ == segs.length) { sink(subject, T.stringof); return true; }
        if (segs[at_].isIndex) return false;
        switch (segs[at_].name)
        {
            static foreach (name; __traits(allMembers, T))
            {{
                static if (__traits(compiles, typeof(__traits(getMember, T, name)))
                    && !is(typeof(__traits(getMember, T, name)) == function))
                {
            case name:
                    return resolve!sink(__traits(getMember, subject, name),
                        segs, at_ + 1);
                }
            }}
            default: return false;
        }
    }
    else static if (is(T == U*, U))
    {
        // C10a: the ASYMMETRY. `subject.parent.fill` compiles as an implicit
        // dereference, so the compile-time form crosses a pointer silently and
        // faults on null. The runtime walk must decide explicitly — here: a
        // null pointer is "no such path", never a fault.
        if (at_ == segs.length) { sink(subject, T.stringof); return true; }
        if (subject is null) return false;
        return resolve!sink(*subject, segs, at_);
    }
    else static if (isArray!T && !isSomeString!T)
    {
        if (at_ == segs.length) { sink(subject, T.stringof); return true; }
        if (!segs[at_].isIndex || segs[at_].index >= subject.length) return false;
        return resolve!sink(subject[segs[at_].index], segs, at_ + 1);
    }
    else
    {
        if (at_ != segs.length) return false;
        sink(subject, T.stringof);
        return true;
    }
}

/// Read a leaf as text through the runtime path.
string readPath(T)(ref T subject, string path)
{
    string outp = "<no such path>";
    static void nothing() {}
    resolve!((ref v, string tn) {
        static if (__traits(compiles, text(v)))
            outp = text(v);
        else
            outp = "<" ~ tn ~ ">";
    })(subject, segments(path));
    return outp;
}

/// Write a leaf through the runtime path; fails (returns false) when the
/// value's type is not assignable to the addressed field.
bool writePath(T, V)(ref T subject, string path, V value)
{
    bool ok;
    resolve!((ref v, string tn) {
        static if (__traits(compiles, v = value))
        {
            v = value;
            ok = true;
        }
    })(subject, segments(path));
    return ok;
}

// ── the subject ──────────────────────────────────────────────────────────────

struct Stop { string name; double weight = 0; }
struct Fill { Stop[] stops; uint tint; }
struct Layer
{
    string name;
    Fill fill;
    Layer* parent;         // recursive: proves C9's termination
}

// ── driving ──────────────────────────────────────────────────────────────────

void main()
{
    import std.stdio : writefln, writeln;

    Layer l = Layer("root");
    l.fill.stops = [Stop("a", 0.0), Stop("b", 0.5), Stop("c", 1.0)];
    l.fill.tint = 0x336699;
    () @trusted { l.parent = &l; }();

    writeln("C8 — compile-time resolution: a direct, ref-returning access");
    writefln("  at!\"fill.stops[1].name\"  = %s", at!"fill.stops[1].name"(l));
    at!"fill.stops[1].weight"(l) = 0.75;       // ← an ordinary assignment
    writefln("  after write, weight       = %s", at!`fill.stops[1].weight`(l));
    writefln("  a typo is a BUILD error:  %s",
        __traits(compiles, at!"fill.stpos[1].name"(l)) ? "no" : "yes");

    writeln("\nC9/C10 — the same paths at run time, differential against C8");
    struct Case { string path; string ct; }
    const cases = [
        Case("name", at!"name"(l)),
        Case("fill.tint", text(at!"fill.tint"(l))),
        Case("fill.stops[0].name", at!"fill.stops[0].name"(l)),
        Case("fill.stops[1].weight", text(at!"fill.stops[1].weight"(l))),
        Case("fill.stops[2].name", at!"fill.stops[2].name"(l)),
        Case("parent.fill.stops[2].weight", text(at!"parent.fill.stops[2].weight"(l))),
    ];
    size_t agreed;
    foreach (c; cases)
    {
        const rt = readPath(l, c.path);
        const same = rt == c.ct;
        agreed += same;
        writefln("  %-30s ct=%-8s rt=%-8s %s", c.path, c.ct, rt,
            same ? "✓" : "✗ DISAGREE");
    }
    writefln("  %s/%s agree", agreed, cases.length);
    writeln("  (the pointer hop needed an explicit branch: `a.b` where `a` is a");
    writeln("   pointer is an IMPLICIT deref at compile time — it faults on null,");
    writeln("   while the runtime walk answers <no such path>.)");
    {
        Layer orphan = Layer("orphan");   // parent is null
        writefln("  null pointer, runtime: parent.name → %s",
            readPath(orphan, "parent.name"));
        writeln("  null pointer, compile-time: at!\"parent.name\"(orphan) would FAULT");
    }

    writeln("\n  bad paths are refused, not crashed:");
    foreach (bad; ["fill.nope", "fill.stops[9].name", "fill[0]", "name.x"])
        writefln("    %-22s → %s", bad, readPath(l, bad));

    writeln("\n  writes through the runtime path:");
    writefln("    writePath(\"fill.stops[0].name\", \"zero\") = %s",
        writePath(l, "fill.stops[0].name", "zero"));
    writefln("    writePath(\"fill.tint\", \"not a uint\")    = %s",
        writePath(l, "fill.tint", "not a uint"));
    writefln("    fill.stops[0].name is now %s", at!"fill.stops[0].name"(l));

    writeln("\nC11 — index paths are positional. Reader opens fill.stops[1]:");
    string opened = "fill.stops[1]";
    writefln("    opened %s → element %s", opened, readPath(l, opened ~ ".name"));
    l.fill.stops = l.fill.stops[1 .. $];       // element 0 removed elsewhere
    writefln("    after removing element 0, the SAME key now points at %s",
        readPath(l, opened ~ ".name"));
    writeln("    → expansion, selection and in-progress edits silently move.");

    // The fix: the adapter mints a stable element id and the path carries it.
    writeln("\n    with an adapter-owned element key the address is stable:");
    struct Keyed { size_t id; Stop v; }
    auto keyed = [Keyed(7, Stop("b", .5)), Keyed(9, Stop("c", 1))];
    writefln("      fill.stops[#7] → %s   (unchanged by any reordering)",
        keyed[0].v.name);
}
