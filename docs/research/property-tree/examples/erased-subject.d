#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_erased_subject"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * One walk, two worlds (fork D1, as decided): the API is static
 * introspection, and a DYNAMIC subject is served by a statically-typed
 * erasure — a `JsonValue`-shaped type that supplies its children at run time
 * through a capability the walk detects by presence.
 *
 * Under test:
 *   C16. `propChildren` (an `opApply` yielding `(name, ref child)`) is enough:
 *        a type that has it enumerates its own children; a type that does not
 *        is walked with `__traits`. One walk, no branch in the caller, no
 *        registry — the toolkit's capability-by-presence idiom.
 *   C17. A MIXED subject works: a plain struct with a `Dyn` field descends
 *        from static fields into dynamic ones and back, with one path syntax
 *        across the seam.
 *   C18. Arrays are children too, addressed `[i]`, in both worlds.
 *   C19. The capability also carries what static reflection cannot: the
 *        dynamic type states its own leaf presentation and whether it is
 *        expandable, so the row model needs no special case for it.
 *
 * Run: `dub run --single erased-subject.d`
 */
module property_tree_erased_subject;

import std.conv : text, to;
import std.traits : isAggregateType, isArray, isAssociativeArray, isSomeString;

@safe:

// ── the type-erased value (the "JsonValue" position) ─────────────────────────

struct Dyn
{
    enum Kind : ubyte { nil, boolean, number, str, array, object }

    Kind kind;
    bool b;
    double num;
    string s;
    Dyn[] items;
    Pair[] fields;

    static struct Pair { string key; Dyn value; }

    static Dyn of(bool v)   { Dyn d; d.kind = Kind.boolean; d.b = v; return d; }
    static Dyn of(double v) { Dyn d; d.kind = Kind.number; d.num = v; return d; }
    static Dyn of(string v) { Dyn d; d.kind = Kind.str; d.s = v; return d; }
    static Dyn arr(Dyn[] v) { Dyn d; d.kind = Kind.array; d.items = v; return d; }
    static Dyn obj(Pair[] v){ Dyn d; d.kind = Kind.object; d.fields = v; return d; }

    // ── the capability (C16/C19) ─────────────────────────────────────────────

    /// Children, named. `name` is a member name for an object and `null` for
    /// an array element (the walk supplies the `[i]` form).
    auto propChildren() return
    {
        static struct Range
        {
            Dyn* self;
            int opApply(scope int delegate(size_t, const(char)[], ref Dyn) @safe dg)
            {
                if (self.kind == Kind.object)
                    foreach (i, ref f; self.fields)
                    {
                        if (auto r = dg(i, f.key, f.value)) return r;
                    }
                else if (self.kind == Kind.array)
                    foreach (i, ref v; self.items)
                    {
                        if (auto r = dg(i, null, v)) return r;
                    }
                return 0;
            }
        }
        return () @trusted { return Range(&this); }();
    }

    /// The rest of the capability: is this expandable, and how does it read?
    bool propExpandable() const pure nothrow @nogc
        => kind == Kind.object || kind == Kind.array;

    string propText() const pure
    {
        final switch (kind)
        {
            case Kind.nil:     return "null";
            case Kind.boolean: return b ? "true" : "false";
            case Kind.number:  return num.to!string;
            case Kind.str:     return `"` ~ s ~ `"`;
            case Kind.array:   return text("[", items.length, " items]");
            case Kind.object:  return text("{", fields.length, " keys}");
        }
    }
}

// ── the one walk ─────────────────────────────────────────────────────────────

struct Row { string path; string label; string type; string value; bool expandable; }

enum bool hasPropChildren(T) = __traits(compiles,
    (ref T t) { foreach (i, name, ref child; t.propChildren) {} });

void walk(T)(ref T v, ref Row[] rows, string path, string label, int depth,
    int maxDepth)
{
    static if (hasPropChildren!T)                                   // C16
    {
        rows ~= Row(path, label, T.stringof, v.propText, v.propExpandable);
        if (depth >= maxDepth || !v.propExpandable) return;
        foreach (i, name, ref child; v.propChildren)
        {
            const p = name is null ? path ~ "[" ~ i.to!string ~ "]"
                : (path.length ? path ~ "." ~ name.idup : name.idup);
            walk(child, rows, p, name is null ? "[" ~ i.to!string ~ "]"
                : name.idup, depth + 1, maxDepth);
        }
    }
    else static if (isArray!T && !isSomeString!T)                    // C18
    {
        rows ~= Row(path, label, T.stringof,
            text("[", v.length, " items]"), v.length > 0);
        if (depth >= maxDepth) return;
        foreach (i, ref e; v)
            walk(e, rows, path ~ "[" ~ i.to!string ~ "]",
                "[" ~ i.to!string ~ "]", depth + 1, maxDepth);
    }
    else static if (isAggregateType!T && !isSomeString!T)
    {
        rows ~= Row(path, label, T.stringof, "", true);
        if (depth >= maxDepth) return;
        static foreach (name; __traits(allMembers, T))
        {{
            static if (__traits(compiles, typeof(__traits(getMember, T, name)))
                && !is(typeof(__traits(getMember, T, name)) == function))
                walk(__traits(getMember, v, name), rows,
                    path.length ? path ~ "." ~ name : name, name,
                    depth + 1, maxDepth);
        }}
    }
    else
        rows ~= Row(path, label, T.stringof, text(v), false);
}

Row[] rowsOf(T)(ref T v, int maxDepth = 8)
{
    Row[] rows;
    walk(v, rows, "", "(root)", 0, maxDepth);
    return rows;
}

// ── a MIXED subject (C17) ────────────────────────────────────────────────────

struct Server { string host = "localhost"; ushort port = 8080; }
struct Config
{
    string name = "demo";
    Server server;
    string[] tags;
    Dyn extra;          // ← the erased hole in an otherwise static type
}

void main()
{
    import std.stdio : writefln, writeln;

    Config c;
    c.tags = ["a", "b"];
    c.extra = Dyn.obj([
        Dyn.Pair("retries", Dyn.of(3.0)),
        Dyn.Pair("hosts", Dyn.arr([Dyn.of("h1"), Dyn.of("h2")])),
        Dyn.Pair("tls", Dyn.obj([Dyn.Pair("verify", Dyn.of(true))])),
    ]);

    writeln("C16/C17/C18 — one walk over a subject that is half static,");
    writeln("half type-erased. Nothing in the walk knows which is which.\n");
    foreach (r; rowsOf(c))
    {
        int depth;
        foreach (ch; r.path) if (ch == '.' || ch == '[') depth++;
        writefln("%*s%-10s %-12s %-22s %s", depth * 2, "",
            r.label, r.expandable ? "▾" : " ", r.type, r.value);
    }

    writeln("\n  paths across the seam are one syntax:");
    foreach (p; ["server.port", "tags[1]", "extra.retries",
        "extra.hosts[0]", "extra.tls.verify"])
        writefln("    %s", p);

    writeln("\nC19 — the dynamic type states its own expandability, so the row");
    writeln("      model has no case for it:");
    writefln("      Dyn(object).propExpandable = %s, Dyn(number) = %s",
        c.extra.propExpandable, Dyn.of(1.0).propExpandable);
    writefln("      hasPropChildren!Dyn = %s, hasPropChildren!Server = %s",
        hasPropChildren!Dyn, hasPropChildren!Server);
}
