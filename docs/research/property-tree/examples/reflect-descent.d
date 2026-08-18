#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_reflect_descent"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * What a compile-time descent over `T` actually yields, and where it stops.
 *
 * Backs [../concepts.md](../concepts.md) § _descent decision_ and
 * [../sparkles-baseline.md](../sparkles-baseline.md) § _Recursion_: every
 * surveyed library decides "leaf or subtree?" at **runtime** — from a converter
 * ([../winforms-propertygrid.md](../winforms-propertygrid.md)), a
 * `ReflectRef` discriminant ([../bevy-inspector-egui.md](../bevy-inspector-egui.md)),
 * or a `PropertyInfo.type` ([../godot-inspector.md](../godot-inspector.md)).
 * In D the same decision is a `static if` over `isAggregateType`, and that moves
 * two failure modes from run time to compile time:
 *
 *   1. **A recursive type diverges at compile time, not at expand time.** Godot
 *      lets a reader unfold a self-referencing resource for as long as they keep
 *      clicking; the equivalent D descent never finishes compiling. The visited
 *      *type* set below is not an optimization — without it this program does
 *      not build: both ldc2 2.111 and dmd 2.112 stop with
 *      `Error: template instance ... recursive expansion exceeded allowed
 *      nesting limit` after 500 levels. That is a stronger guarantee than any
 *      surveyed library offers, and a harder constraint.
 *   2. **The whole tree is a value, not a walk.** `describe!T` runs in CTFE and
 *      returns a flat, pre-ordered row array, so the row count of a type is
 *      knowable before a frame is drawn.
 *
 * Run: `dub run --single reflect-descent.d`
 */
module property_tree_reflect_descent;

import std.stdio : writefln, writeln;
import std.traits : FieldNameTuple, Fields, isAggregateType, isPointer,
    PointerTarget;

@safe:

/// One presented row of a reflected type: what a renderer needs before values.
struct FieldRow
{
    string path;      /// dotted path from the root
    string type;      /// the field's static type
    size_t depth;     /// nesting level; 0 is a direct field of the root
    bool expandable;  /// an aggregate we descended into
    bool cut;         /// descent stopped here: the type is already on the path
}

/// The types a leaf editor exists for. Everything else is a candidate subtree.
private enum bool isLeafType(T) = is(T == string) || !isAggregateType!T;

/**
Flattens `T` into pre-ordered rows at compile time.

`Seen` is the set of aggregate types already open on the current path. It is
what makes the function total: a type that contains itself (directly or through
a pointer) is cut with `cut = true` instead of re-entering.
*/
FieldRow[] describe(T, size_t depth = 0, string prefix = "", Seen...)() pure nothrow
{
    FieldRow[] rows;
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias F = Fields!T[i];
        // A pointer is presented as the type it points at — that is what makes
        // `Node*` a cycle rather than an opaque address.
        static if (isPointer!F && isAggregateType!(PointerTarget!F))
            alias Target = PointerTarget!F;
        else
            alias Target = F;

        enum path = prefix ~ name;
        enum bool leaf = isLeafType!Target;
        enum bool seen = anyIs!(Target, Seen);

        rows ~= FieldRow(path, F.stringof, depth, !leaf && !seen, !leaf && seen);
        static if (!leaf && !seen)
            rows ~= describe!(Target, depth + 1, path ~ ".", Seen, Target)();
    }}
    return rows;
}

private enum bool anyIs(T, Seen...) = ()
{
    bool found;
    static foreach (S; Seen)
        found = found || is(T == S);
    return found;
}();

// ---------------------------------------------------------------------------
// A subject with the three shapes that matter: a plain leaf, a nested
// aggregate, and a type that reaches itself.
// ---------------------------------------------------------------------------

struct Vec2
{
    float x = 0, y = 0;
}

struct Material
{
    string name;
    Vec2 offset;
    bool twoSided;
}

struct Node
{
    string label;
    Vec2 position;
    Material material;
    Node* parent; // the cycle
}

void main()
{
    // The whole tree is computed at compile time — this is a manifest constant,
    // not a walk performed while painting.
    enum rows = describe!Node();

    writefln("%s rows for Node, all known at compile time", rows.length);
    writeln();
    foreach (r; rows)
    {
        char[] indent;
        foreach (_; 0 .. r.depth)
            indent ~= "  ";
        const mark = r.cut ? " [cut: type already on path]"
            : r.expandable ? " [subtree]" : "";
        writefln("%s%s : %s%s", indent, r.path, r.type, mark);
    }

    writeln();
    // The counts are compile-time facts too, which is what makes a static row
    // budget possible at all.
    size_t leaves, subtrees, cuts;
    foreach (r; rows)
    {
        if (r.cut)
            cuts++;
        else if (r.expandable)
            subtrees++;
        else
            leaves++;
    }
    writefln("leaves=%s subtrees=%s cuts=%s", leaves, subtrees, cuts);
}
