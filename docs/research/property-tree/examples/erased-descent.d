#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_erased_descent"
    targetPath "build"
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The escape from the compile-time recursion limit, and what it costs.
 *
 * [`reflect-descent.d`](./reflect-descent.d) shows that a descent written as one
 * CTFE walk over `T` **fails to build** on a recursive type — the visited-type
 * set is mandatory, and it cuts a type the *second* time it appears anywhere on
 * a path.
 *
 * The Tier-2 pass found that the field does not have this problem, and why.
 * Rust's [derive-macro inspectors](../derive-macro-inspectors.md) generate one
 * impl per type whose child walk crosses a `&mut dyn` boundary, so recursion is
 * a **runtime call**; [DevTools](../devtools-object-inspector.md) fetches each
 * level on expansion, so a cyclic graph is finite work per click; and
 * [`react-jsonschema-form`](../react-jsonschema-form.md) renders a detected
 * `$ref` cycle as an **Expand placeholder** — one level per press, with the cut
 * visible to the reader.
 *
 * This program is those three answers in D:
 *
 *   1. `rowsOf!T` is still compile-time — it reflects fields, labels and leaf-ness
 *      from the type — but the child walk is **erased behind a delegate**, so the
 *      template instantiates once per type rather than once per path, and a
 *      self-referential type compiles.
 *   2. Descent is driven by a **budget**, not by the type: rows are produced to a
 *      requested depth and anything deeper becomes a `cut` row.
 *   3. A `cut` row carries the delegate that would continue, so "expand" is one
 *      more bounded call — the rjsf affordance, in cells.
 *
 * The cost is stated honestly at the end: the erasure is a virtual call and an
 * allocation per open node, which is exactly what the CTFE walk avoided.
 *
 * Run: `dub run --single erased-descent.d`
 */
module property_tree_erased_descent;

import std.stdio : writefln, writeln;
import std.traits : FieldNameTuple, Fields, isAggregateType, isPointer,
    PointerTarget;

@safe:

/// One presented row. `expand` is non-null exactly when the row was cut.
struct Row
{
    string path;
    string type;
    size_t depth;
    bool isLeaf;
    Rows delegate() @safe expand; /// null unless this row is a cut
}

alias Rows = Row[];

/// The erasure boundary: a node knows how to produce its own child rows and
/// nothing about who asked. This is the `&mut dyn EguiProbe` of the Rust family.
alias ChildSource = Rows delegate(size_t budget, string prefix, size_t depth) @safe;

private enum bool isLeafType(T) = is(T == string) || !isAggregateType!T;

/// Presents `value` as rows, descending at most `budget` levels.
///
/// The recursion below is a **runtime** call through `ChildSource`, so this
/// template is instantiated once per type — not once per path — and a type that
/// contains itself is ordinary rather than fatal.
Rows rowsOf(T)(ref T value, size_t budget, string prefix = "", size_t depth = 0)
{
    Rows rows;
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias F = Fields!T[i];
        static if (isPointer!F && isAggregateType!(PointerTarget!F))
            alias Target = PointerTarget!F;
        else
            alias Target = F;

        const path = prefix ~ name;
        enum leaf = isLeafType!Target;

        static if (leaf)
        {
            rows ~= Row(path, F.stringof, depth, true, null);
        }
        else
        {
            // The child walk, erased. Capturing it as a delegate is what stops
            // the template from re-entering itself at compile time.
            ChildSource source = (size_t b, string p, size_t d) @safe {
                static if (isPointer!F)
                {
                    auto target = __traits(getMember, value, name);
                    if (target is null)
                        return Rows.init;
                    return rowsOf!Target(*target, b, p, d);
                }
                else
                    return rowsOf!Target(__traits(getMember, value, name), b, p, d);
            };

            if (budget == 0)
            {
                // The rjsf answer: a cut is a row with an affordance, not a hole.
                rows ~= Row(path, F.stringof, depth, false,
                    () @safe => source(1, path ~ ".", depth + 1));
            }
            else
            {
                rows ~= Row(path, F.stringof, depth, false, null);
                rows ~= source(budget - 1, path ~ ".", depth + 1);
            }
        }
    }}
    return rows;
}

// ---------------------------------------------------------------------------
// The same subject as reflect-descent.d, including the type that reaches itself.
// ---------------------------------------------------------------------------

struct Vec2
{
    float x = 0, y = 0;
}

struct Material
{
    string name;
    Vec2 offset;
}

struct Node
{
    string label;
    Vec2 position;
    Material material;
    Node* parent;
}

private void print(in Rows rows)
{
    foreach (r; rows)
    {
        char[] indent;
        foreach (_; 0 .. r.depth)
            indent ~= "  ";
        const mark = r.expand !is null ? "  ← cut (expandable)"
            : r.isLeaf ? "" : "  [subtree]";
        writefln("%s%s : %s%s", indent, r.path, r.type, mark);
    }
}

void main()
{
    // A genuinely cyclic value: the node is its own parent.
    Node root = Node("root");
    () @trusted { root.parent = &root; }();

    writeln("budget = 1 — one level, everything deeper is a cut row");
    auto shallow = rowsOf(root, 1);
    print(shallow);

    writeln();
    writefln("%s rows, %s of them cuts", shallow.length, countCuts(shallow));

    writeln();
    writeln("expanding the first cut — one more bounded level, on demand");
    foreach (r; shallow)
    {
        if (r.expand !is null)
        {
            print(r.expand());
            break;
        }
    }

    writeln();
    // The same value at three budgets: the row count is a function of the
    // budget, not of the (infinite) value graph.
    foreach (budget; 0 .. 4)
    {
        auto rows = rowsOf(root, budget);
        writefln("budget=%s → %s rows (%s cuts)", budget, rows.length,
            countCuts(rows));
    }

    writeln();
    writeln("cost: one delegate per open node, one virtual call per descent —");
    writeln("what the compile-time walk avoided, in exchange for terminating.");
}

private size_t countCuts(in Rows rows) pure nothrow @nogc
{
    size_t n;
    foreach (r; rows)
        if (r.expand !is null)
            n++;
    return n;
}
