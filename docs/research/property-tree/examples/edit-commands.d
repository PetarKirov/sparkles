#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_edit_commands"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The mutation contract (fork D5), with read-write as the default
 * and read-only as a policy (fork D6, as decided).
 *
 * Under test:
 *   C12. An edit is a VALUE — `(path, newValue, phase)` — not a callback.
 *        Applying one returns its INVERSE, so undo/redo is a host-owned stack
 *        of the same value type and the component contains no transaction
 *        machinery. (The corpus rule "undo belongs to the host", made cheap.)
 *   C13. `@readOnly` and a component-level policy both refuse the write at the
 *        SAME place — inside the generated dispatch — so no view can bypass it.
 *   C14. `phase` separates a drag's previews from its commit (Unreal's
 *        `SetValue` flags). Previews mutate; only a commit yields an undo
 *        entry. This is the distinction Godot's `changing` flag does NOT make.
 *   C15. The D-specific wrinkle: `SumType.opAssign` is `@system` when another
 *        member has indirections, so a variant switch needs one `@trusted`
 *        seam — and the edit vocabulary needs a `variant` case, because a
 *        switch is not an assignment of any leaf type.
 *
 * Run: `dub run --single edit-commands.d`
 */
module property_tree_edit_commands;

import std.conv : text, to;
import std.sumtype : match, SumType;
import std.traits : hasUDA, isAggregateType, isArray, isSomeString;

@safe:

enum readOnly;

// ── the edit vocabulary (C12) ────────────────────────────────────────────────

enum Phase : ubyte { preview, commit }

/// Every leaf the component can produce an edit for, as one value type.
struct EditValue
{
    enum Kind : ubyte { none, boolean, integral, floating, text, variant }
    Kind kind;
    bool b; long i; double f; string s;

    static EditValue of(bool v)   => EditValue(Kind.boolean, v);
    static EditValue of(long v)   => EditValue(Kind.integral, false, v);
    static EditValue of(double v) => EditValue(Kind.floating, false, 0, v);
    static EditValue of(string v) => EditValue(Kind.text, false, 0, 0, v);
    static EditValue variantOf(string name)
        => EditValue(Kind.variant, false, 0, 0, name);

    string toString() const pure
    {
        final switch (kind)
        {
            case Kind.none:     return "∅";
            case Kind.boolean:  return b ? "true" : "false";
            case Kind.integral: return i.to!string;
            case Kind.floating: return f.to!string;
            case Kind.text:     return `"` ~ s ~ `"`;
            case Kind.variant:  return "=" ~ s;
        }
    }
}

/// The whole mutation API surface: one value.
struct Edit
{
    string path;
    EditValue value;
    Phase phase = Phase.commit;
}

/// Why a write was refused — the view renders this, it is not an exception.
enum Refusal : ubyte { none, noSuchPath, readOnlyField, readOnlyPolicy, typeMismatch }

struct Applied
{
    Refusal refusal;
    Edit inverse;             /// valid when refusal == none && phase == commit
    bool ok() const pure nothrow @nogc => refusal == Refusal.none;
}

// ── applying an edit ─────────────────────────────────────────────────────────

struct Policy { bool readOnly; }

/// Assigns `v` from an `EditValue` when the types line up; reports the old
/// value as an `EditValue` so the caller can build the inverse.
private bool assignLeaf(V)(ref V v, in EditValue e, out EditValue old)
{
    static if (is(V == bool))
    {
        if (e.kind != EditValue.Kind.boolean) return false;
        old = EditValue.of(v); v = e.b; return true;
    }
    else static if (is(V == enum))
    {
        if (e.kind != EditValue.Kind.text) return false;
        old = EditValue.of(v.to!string);
        switch (e.s)
        {
            static foreach (m; __traits(allMembers, V))
            {
            case m: v = __traits(getMember, V, m); return true;
            }
            default: return false;
        }
    }
    else static if (__traits(isIntegral, V))
    {
        if (e.kind != EditValue.Kind.integral) return false;
        old = EditValue.of(cast(long) v); v = cast(V) e.i; return true;
    }
    else static if (__traits(isFloating, V))
    {
        if (e.kind != EditValue.Kind.floating) return false;
        old = EditValue.of(cast(double) v); v = cast(V) e.f; return true;
    }
    else static if (isSomeString!V)
    {
        if (e.kind != EditValue.Kind.text) return false;
        // dip1000 earns its keep: an `in Edit` is scope, so its text cannot
        // be stored into the subject without a copy. The compiler says so.
        old = EditValue.of(v.idup); v = e.s.idup; return true;
    }
    else
        return false;
}

/// The generated dispatch: one walk, parameterised by TYPE only ([`open-set-descent.d`](./open-set-descent.d)).
/// `@readOnly` is consulted HERE (C13) — a view cannot route around it.
private Refusal applyAt(T)(ref T subject, in Seg[] segs, size_t at_,
    in Edit e, in Policy pol, out EditValue old)
{
    static if (is(T == U*, U))
    {
        if (subject is null) return Refusal.noSuchPath;
        return applyAt(*subject, segs, at_, e, pol, old);
    }
    else static if (isAggregateType!T && !isSomeString!T)
    {
        if (at_ >= segs.length || segs[at_].isIndex) return Refusal.noSuchPath;
        switch (segs[at_].name)
        {
            static foreach (name; __traits(allMembers, T))
            {{
                alias F = __traits(getMember, T, name);
                static if (__traits(compiles, typeof(F))
                    && !is(typeof(F) == function))
                {
            case name:
                    static if (hasUDA!(F, readOnly))
                        return Refusal.readOnlyField;
                    else
                    {
                        if (at_ + 1 == segs.length)
                            return assignLeaf(__traits(getMember, subject, name),
                                e.value, old)
                                ? Refusal.none : Refusal.typeMismatch;
                        return applyAt(__traits(getMember, subject, name),
                            segs, at_ + 1, e, pol, old);
                    }
                }
            }}
            default: return Refusal.noSuchPath;
        }
    }
    else static if (isArray!T && !isSomeString!T)
    {
        if (at_ >= segs.length || !segs[at_].isIndex
            || segs[at_].index >= subject.length) return Refusal.noSuchPath;
        if (at_ + 1 == segs.length)
            return assignLeaf(subject[segs[at_].index], e.value, old)
                ? Refusal.none : Refusal.typeMismatch;
        return applyAt(subject[segs[at_].index], segs, at_ + 1, e, pol, old);
    }
    else
        return Refusal.noSuchPath;
}

/// The public verb. Read-only policy is refused before the walk (C13).
Applied apply(T)(ref T subject, in Edit e, in Policy pol = Policy.init)
{
    if (pol.readOnly) return Applied(Refusal.readOnlyPolicy);
    EditValue old;
    const r = applyAt(subject, segments(e.path), 0, e, pol, old);
    if (r != Refusal.none) return Applied(r);
    // C12: the inverse is the same value type, built from what was there.
    return Applied(Refusal.none, Edit(e.path, old, Phase.commit));
}

// ── path segments ([`path-addressing.d`](./path-addressing.d), verbatim) ────────────────────────────────────────

struct Seg { string name; size_t index; bool isIndex; }

Seg[] segments(scope const(char)[] path) pure
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

// ── the subject ──────────────────────────────────────────────────────────────

enum Cap { butt, round, square }
struct Stroke { double width = 1; Cap cap; }
struct Layer
{
    string name = "layer";
    bool visible = true;
    int order;
    Stroke stroke;
    @readOnly ulong id = 42;
}

// C15: the sum type.
struct Solid { uint rgba; }
struct Gradient { string from, to; int stops = 2; }
alias Paint = SumType!(Solid, Gradient);

/// The one `@trusted` seam a variant switch needs, and its precondition.
/// PRECONDITION: no reference into the old payload outlives this call — which
/// the frame model guarantees, since rows are rebuilt after every edit.
void switchTo(V)(ref Paint p, V v) @trusted { p = v; }

void main()
{
    import std.stdio : writefln, writeln;

    Layer l;
    Edit[] undo;

    void run(Edit e, Policy pol = Policy.init)
    {
        const r = apply(l, e, pol);
        writefln("  %-22s %-10s %-8s → %-14s %s", e.path, e.value.toString,
            e.phase, r.refusal,
            r.ok && e.phase == Phase.commit
                ? "inverse " ~ r.inverse.value.toString : "");
        if (r.ok && e.phase == Phase.commit) undo ~= r.inverse;
    }

    writeln("C12/C13 — edits as values; every write returns its inverse\n");
    writefln("  %-22s %-10s %-8s   %-14s %s",
        "path", "value", "phase", "refusal", "undo");
    run(Edit("name", EditValue.of("background")));
    run(Edit("visible", EditValue.of(false)));
    run(Edit("stroke.width", EditValue.of(2.5)));
    run(Edit("stroke.cap", EditValue.of("round")));
    run(Edit("id", EditValue.of(7L)));                       // @readOnly field
    run(Edit("order", EditValue.of("nope")));                // type mismatch
    run(Edit("stroke.nope", EditValue.of(1L)));              // no such path
    run(Edit("name", EditValue.of("x")), Policy(readOnly: true));  // policy

    writefln("\n  subject now: %s", l);

    writeln("\nC12 — undo is the host replaying the inverses, newest first:");
    foreach_reverse (e; undo)
    {
        const r = apply(l, e);
        writefln("    undo %-14s %-12s %s", e.path, e.value.toString, r.refusal);
    }
    writefln("  subject restored: %s", l);

    writeln("\nC14 — a drag: previews mutate, only the commit records undo");
    undo = null;
    foreach (w; [1.5, 2.0, 2.5, 3.0])
        run(Edit("stroke.width", EditValue.of(w), Phase.preview));
    run(Edit("stroke.width", EditValue.of(3.0), Phase.commit));
    writefln("  undo entries after the whole drag: %s (width=%s)",
        undo.length, l.stroke.width);
    writeln("  NOTE: the inverse of the COMMIT is the value at the drag's end,");
    writeln("  not its start — so a host that wants one undo per drag must");
    writeln("  keep the first preview's prior value. That is a spec decision.");

    writeln("\nC15 — the variant switch is not an assignment of any leaf type");
    Paint p = Solid(0xff0000ff);
    writefln("  before: %s", p.match!(s => text("Solid ", s.rgba),
        g => text("Gradient ", g.stops)));
    // The rule is DIRECTIONAL, and finer than "SumType assignment is @system":
    // `opAssign` is unsafe when the variant being OVERWRITTEN may hold
    // indirections, because a reference into the old payload would dangle.
    writefln("  q = Gradient(...) over a maybe-Solid   @safe? %s",
        __traits(compiles, () @safe { Paint q; q = Gradient("a", "b"); }())
            ? "yes — Solid has no indirections" : "no");
    writefln("  q = Solid(...)    over a maybe-Gradient @safe? %s",
        __traits(compiles, () @safe { Paint q; q = Solid(1); }())
            ? "yes" : "no — Gradient holds strings, so the overwrite is @system");
    switchTo(p, Gradient("black", "white", 3));
    writefln("  after switchTo (one @trusted seam): %s",
        p.match!(s => text("Solid ", s.rgba), g => text("Gradient ", g.stops)));
    writeln("  so the edit vocabulary needs EditValue.Kind.variant, and the");
    writeln("  component needs exactly one @trusted function, not @trusted rows.");
}
