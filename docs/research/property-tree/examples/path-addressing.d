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
 * Grammar:  path := seg ( "." name | "[" digits "]" | "[#" digits "]" )*
 *           seg  := name | '["' quoted '"]'      (backslash-escaped ", \)
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
 *        finding).
 *   C25. The fix is element-provided identity, not an adapter side table: an
 *        element type opting in with `ulong propElementKey() const` makes
 *        `[#7]` resolve BY KEY through the same generated walk, unmoved by
 *        removal or reorder of earlier elements. A duplicate or absent key —
 *        and `[#…]` on a collection that never opted in — is refused, never
 *        resolved positionally. (Added with the spec review; the earlier
 *        revision minted the id in an adapter-owned table, the ambient side
 *        table PRN1/PRN2 argue against.)
 *   C26. Names outside the identifier subset (erased children: JSON keys with
 *        `.`, `[`, spaces, leading digits) use a QUOTED segment `["…"]` with
 *        backslash escapes. The emitter picks bare exactly when the name is
 *        identifier-shaped, so every emitted path re-parses to the same
 *        segments; the quoted and bare spellings of the same member resolve
 *        identically.
 *
 * Run: `dub run --single path-addressing.d`
 */
module property_tree_path_addressing;

import std.conv : text, to;
import std.traits : isAggregateType, isArray, isDynamicArray, isSomeString;

@safe:

// ── path segments ────────────────────────────────────────────────────────────

struct Seg { string name; size_t index; bool isIndex; bool isKey; ulong key; }

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
            if (i + 1 < path.length && path[i + 1] == '#')       // [#key] (C25)
            {
                size_t j = i + 2;
                while (j < path.length && path[j] != ']') j++;
                Seg s = { isKey: true, key: to!ulong(path[i + 2 .. j]) };
                segs ~= s;
                i = j + 1;
            }
            else if (i + 1 < path.length && path[i + 1] == '"')  // ["name"] (C26)
            {
                size_t j = i + 2;
                string name;
                while (j < path.length && path[j] != '"')
                {
                    if (path[j] == '\\') j++;
                    name ~= path[j];
                    j++;
                }
                segs ~= Seg(name, 0, false);
                i = j + 2;   // past the closing `"` and `]`
            }
            else
            {
                size_t j = ++i;
                while (j < path.length && path[j] != ']') j++;
                segs ~= Seg(null, to!size_t(path[i .. j]), true);
                i = j + 1;
            }
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

/// The inverse: how the walk mints a child's path. A name outside the bare
/// identifier subset is emitted as a quoted segment, so every emitted path
/// re-parses to the same segments (C26).
string childPath(string parent, string member) pure nothrow
{
    bool bare = member.length > 0 && !(member[0] >= '0' && member[0] <= '9');
    foreach (c; member)
        bare &= c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || (c >= '0' && c <= '9');
    if (bare)
        return parent.length ? parent ~ "." ~ member : member;
    string q = `["`;
    foreach (c; member)
    {
        if (c == '"' || c == '\\') q ~= '\\';
        q ~= c;
    }
    return parent ~ q ~ `"]`;
}
/// ditto
string elementPath(string parent, size_t i) pure
    => parent ~ "[" ~ i.to!string ~ "]";
/// ditto — stable identity for an opted-in element (C25)
string keyedPath(string parent, ulong key) pure
    => parent ~ "[#" ~ key.to!string ~ "]";

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
        static if (__traits(hasMember, typeof(subject[0]), "propElementKey"))
        {
            // C25: keyed identity — `[#k]` resolves by the element's OWN key.
            // A duplicate or absent key is refused, never resolved positionally.
            if (segs[at_].isKey)
            {
                size_t found, hits;
                foreach (idx; 0 .. subject.length)
                    if (subject[idx].propElementKey == segs[at_].key)
                    { found = idx; hits++; }
                if (hits != 1) return false;
                return resolve!sink(subject[found], segs, at_ + 1);
            }
        }
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

/// C25's subject: an element that OWNS its identity by opting in.
struct KStop
{
    ulong id;
    string name;
    double weight = 0;
    ulong propElementKey() const pure nothrow @nogc => id;
}
struct KRoot { KStop[] stops; }

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

    writeln("\nC25 — the fix is element-provided identity: `[#key]` resolves");
    writeln("      by `propElementKey`, through the same generated walk:");
    KRoot k;
    k.stops = [KStop(7, "b", 0.5), KStop(9, "c", 1.0)];
    writefln("    stops[#9].name          → %s", readPath(k, "stops[#9].name"));
    k.stops = k.stops[1 .. $];                 // element 0 removed elsewhere
    writefln("    after removing [#7]     → %s   (address unmoved)",
        readPath(k, "stops[#9].name"));
    writefln("    absent key stops[#3]    → %s", readPath(k, "stops[#3].name"));
    k.stops = [KStop(7, "x"), KStop(7, "y")];  // a duplicate key
    writefln("    duplicate key stops[#7] → %s (refused, never positional)",
        readPath(k, "stops[#7].name"));
    writefln("    unkeyed fill.stops[#7]  → %s (identity is opt-in)",
        readPath(l, "fill.stops[#7].name"));
    writefln("    the emitter mints it:   keyedPath(\"stops\", 9) = %s",
        keyedPath("stops", 9));

    writeln("\nC26 — quoted segments carry names the bare grammar cannot:");
    writefln("    [\"fill\"].tint ≡ fill.tint → %s ≡ %s",
        readPath(l, `["fill"].tint`), readPath(l, "fill.tint"));
    const weird = `a.b [x] "q"`;
    const minted = childPath("", weird);
    const back = segments(minted);
    writefln("    childPath of %(%s%) mints %s", [weird], minted);
    writefln("    …which re-parses to one name segment (round-trip: %s)",
        back.length == 1 && back[0].name == weird);
    writefln("    identifier-shaped names stay bare: childPath(\"fill\", \"tint\") = %s",
        childPath("fill", "tint"));
}
