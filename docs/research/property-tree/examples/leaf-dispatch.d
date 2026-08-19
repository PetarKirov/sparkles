#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_leaf_dispatch"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Leaf dispatch and the metadata channel (forks D2 + D4).
 *
 * Under test:
 *   C4. A closed `static if` ladder over D's type space classifies every leaf
 *       into a small `LeafKind` the view can dispatch on, at compile time,
 *       with no registry and no dynamic dispatch surface.
 *   C5. A UDA vocabulary carries the rest — label, group, range, read-only,
 *       hidden — and a per-field OVERRIDE of the chosen editor is just a
 *       symbol resolved at compile time (the derive-crates' `custom_func_mut`).
 *   C6. What a UDA canNOT carry is a condition over the VALUE: `@ShowIf` has
 *       to be a function pointer evaluated per frame.
 *   C7. The escape hatch: a type the ladder cannot classify is `opaque`, and
 *       an opaque row is presented via its own `toString` — VS Code's
 *       `Complex` posture, which is also what read-only targets need.
 *
 * Run: `dub run --single leaf-dispatch.d`
 */
module property_tree_leaf_dispatch;

import std.conv : text;
import std.traits : EnumMembers, hasUDA, getUDAs, isAggregateType, isArray,
    isAssociativeArray, isBoolean, isFloatingPoint, isIntegral, isPointer,
    isSomeString, OriginalType;

@safe:

// ── the metadata vocabulary (C5) ─────────────────────────────────────────────

struct Label { string text; }             /// display name override
struct Group { string name; }             /// category
struct Range { double lo, hi, step = 0; } /// numeric bounds → slider/stepper
struct Doc { string text; }               /// tooltip / details row
enum hidden;                              /// never presented
enum readOnly;                            /// presented, never editable
struct Editor { string name; }            /// force a leaf editor by name
struct ShowIf { string cond; }            /// a condition over the VALUE (C6)

// ── the leaf classification (C4) ─────────────────────────────────────────────

enum LeafKind : ubyte
{
    boolean, integral, floating, text, enumeration, opaque
}

template leafKindOf(T)
{
    static if (is(T == enum))            enum leafKindOf = LeafKind.enumeration;
    else static if (isBoolean!T)         enum leafKindOf = LeafKind.boolean;
    else static if (isIntegral!T)        enum leafKindOf = LeafKind.integral;
    else static if (isFloatingPoint!T)   enum leafKindOf = LeafKind.floating;
    else static if (isSomeString!T)      enum leafKindOf = LeafKind.text;
    else                                 enum leafKindOf = LeafKind.opaque;
}

/// Is `T` a leaf at all? Aggregates descend; everything else is a leaf — and
/// an aggregate that answers `toString` but has no presentable fields is an
/// opaque leaf, not a subtree (C7).
enum bool isLeaf(T) = !isAggregateType!T || isSomeString!T
    || (hasUDA!(T, opaqueValue) && true);

enum opaqueValue;   /// a type marks ITSELF as never-descended

// ── what a row tells the view ────────────────────────────────────────────────

struct LeafPlan(T)
{
    string path, label, group, doc, typeName;
    LeafKind kind;
    string editor;          /// "" = the kind's default editor
    bool editable;
    bool hasRange;
    Range range;
    string[] choices;       /// enumeration members
    string why;             /// the @ShowIf source text, "" = unconditional
    bool function(ref const T) @safe visible;  /// null = unconditional
}

/// The compile-time plan for one aggregate's leaves. Type-only template
/// parameter, per [`open-set-descent.d`](./open-set-descent.d).
LeafPlan!T[] planOf(T)(string prefix = "") pure nothrow
{
    LeafPlan!T[] rows;
    static foreach (name; __traits(allMembers, T))
    {{
        static if (__traits(compiles, typeof(__traits(getMember, T, name)))
            && !is(typeof(__traits(getMember, T, name)) == function))
        {
            alias F = typeof(__traits(getMember, T, name));
            alias M = __traits(getMember, T, name);
            static if (!hasUDA!(M, hidden))
            {{
                LeafPlan!T p;
                p.path = prefix.length ? prefix ~ "." ~ name : name;
                p.typeName = F.stringof;
                p.kind = leafKindOf!F;
                p.editable = !hasUDA!(M, readOnly);

                static if (hasUDA!(M, Label))
                    p.label = getUDAs!(M, Label)[0].text;
                else
                    p.label = name;
                static if (hasUDA!(M, Group))
                    p.group = getUDAs!(M, Group)[0].name;
                static if (hasUDA!(M, Doc))
                    p.doc = getUDAs!(M, Doc)[0].text;
                static if (hasUDA!(M, Range))
                {
                    p.hasRange = true;
                    p.range = getUDAs!(M, Range)[0];
                }
                static if (hasUDA!(M, Editor))
                    p.editor = getUDAs!(M, Editor)[0].name;
                static if (hasUDA!(M, ShowIf))
                {
                    // The condition is a compile-time-checked EXPRESSION over
                    // the subject, not an untyped callback: it becomes a typed
                    // `@safe` predicate with no cast anywhere (C6).
                    enum src = getUDAs!(M, ShowIf)[0].cond;
                    p.why = src;
                    p.visible = (ref const T v) @safe => mixin("v." ~ src);
                }
                static if (is(F == enum))
                    static foreach (e; EnumMembers!F)
                        p.choices ~= __traits(identifier, e);
                rows ~= p;
            }}
        }
    }}
    return rows;
}

/// The default editor for a kind — a closed set, chosen at compile time.
string defaultEditor(LeafKind k, bool hasRange, bool editable) pure nothrow
{
    if (!editable) return "readout";
    final switch (k)
    {
        case LeafKind.boolean:     return "checkbox";
        case LeafKind.integral:    return hasRange ? "slider-int" : "stepper";
        case LeafKind.floating:    return hasRange ? "slider" : "number";
        case LeafKind.text:        return "line-edit";
        case LeafKind.enumeration: return "picker";
        case LeafKind.opaque:      return "readout+escape";  // C7
    }
}

// ── the subject ──────────────────────────────────────────────────────────────

enum FillKind { solid, gradient, texture }

/// A type that refuses to be descended into: presented by `toString` (C7).
@opaqueValue struct Handle
{
    ulong bits;
    string toString() const pure => text("Handle(", bits, ")");
}

struct Style
{
    @Group("identity") @Doc("shown in the layer list")
    string name = "unnamed";

    @Group("fill")
    FillKind kind;

    @Group("fill") @Range(0, 1, 0.01)
    double opacity = 1;

    @Group("fill") @ShowIf("kind == FillKind.gradient")
    int stops = 2;

    @Group("layout") @Range(0, 4096)
    int width = 100;

    @Group("layout") @Label("H") @Range(0, 4096)
    int height = 100;

    @Group("advanced") @readOnly
    Handle handle;

    @hidden
    uint revision;

    @Group("advanced") @Editor("color-swatch")
    uint tint = 0xff00ff;
}

// ── driving ──────────────────────────────────────────────────────────────────

enum plan = planOf!Style();   // ← the whole plan is a compile-time constant

void main()
{
    import std.stdio : writefln, writeln;

    writefln("C4/C5 — %s presented leaves, planned at compile time"
        ~ " (`revision` is @hidden and absent)\n", plan.length);
    writefln("%-10s %-9s %-13s %-9s %-16s %s",
        "label", "group", "type", "kind", "editor", "extra");
    foreach (p; plan)
    {
        string extra;
        if (p.hasRange) extra ~= text("[", p.range.lo, "..", p.range.hi, "] ");
        if (p.choices.length) extra ~= text(p.choices, " ");
        if (!p.editable) extra ~= "read-only ";
        if (p.visible !is null) extra ~= "if(" ~ p.why ~ ") ";
        if (p.doc.length) extra ~= "“" ~ p.doc ~ "” ";
        writefln("%-10s %-9s %-13s %-9s %-16s %s", p.label, p.group, p.typeName,
            p.kind, p.editor.length ? p.editor ~ "*"
                : defaultEditor(p.kind, p.hasRange, p.editable), extra);
    }

    writeln("\nC6 — the same plan, filtered per frame against a live value:");
    Style s;
    foreach (twice; 0 .. 2)
    {
        if (twice) s.kind = FillKind.gradient;
        string[] visible;
        foreach (p; plan)
            if (p.visible is null || p.visible(s))
                visible ~= p.label;
        writefln("  kind=%-9s → %s", s.kind, visible);
    }

    writeln("\nC7 — the opaque escape: a @opaqueValue type is a LEAF,");
    writefln("      presented by its own toString: %s", s.handle);
    writefln("      isLeaf!Handle = %s, isLeaf!Style = %s",
        isLeaf!Handle, isLeaf!Style);
}
