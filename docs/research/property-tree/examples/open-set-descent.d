#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_open_set_descent"
    targetPath "build"
    dependency "sparkles:ui" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * Descent driven by the OPENED SET, over the real `TreeData`/`DisclosureState`.
 *
 * Three claims under test:
 *
 *  C1. The escape from the CTFE recursion limit is NOT an erasure boundary —
 *      it is parameterising the walk by TYPE ONLY. `reflect-descent.d` failed
 *      because its template took (depth, prefix, Seen...), so each path was a
 *      fresh instantiation. A walk whose only template parameter is `T`
 *      instantiates once per type and recurses at RUNTIME, with no delegate.
 *
 *  C2. If descent is driven by the user's opened set, no cycle guard is needed
 *      (the corpus rule: guard only the walk nobody drove). A cyclic value
 *      yields a finite tree, one level per open.
 *
 *  C3. `DisclosureState.allOpen()` — a polarity flip, O(1) by design — is a
 *      TRAP here: it makes the walk undriven, and it does not terminate
 *      without a depth cap.
 *
 * Run: `dub run --single open-set-descent.d`
 */
module property_tree_open_set_descent;

import std.conv : text;
import std.traits : FieldNameTuple, Fields, isAggregateType, isArray,
    isPointer, isSomeString, PointerTarget;

import sparkles.ui.components.tree_widget : flatten, TreeData;
import sparkles.ui.state : DisclosureState;

@safe:

/// The row model. `composite` is a TYPE fact, known even when the node is
/// closed and its children were never materialised.
struct PropNode
{
    string path;      /// the Key: a dotted path
    string label;     /// last segment
    string typeName;  ///
    string value;     /// presented scalar, empty for composites
    bool composite;   /// the type has children
    bool capped;      /// composite, open, but the depth cap refused to descend
}

private enum bool isLeafType(T) = isSomeString!T || !isAggregateType!T;

/// Everything the walk needs, as one value — so the walk itself takes only `T`.
struct Descent
{
    TreeData!PropNode data;
    DisclosureState!string open;
    int maxDepth = 8;   /// the cap that makes an undriven walk finite
    size_t maxNodes = 5000;
    size_t visited;     /// nodes materialised
}

/**
 * The walk. Note the signature: `T` is the ONLY template parameter — path and
 * depth are runtime arguments. That is what makes a self-referential type
 * compile: `descend!Node` calls `descend!Node`, an ordinary recursive function.
 */
void descend(T)(ref Descent d, ref T value, uint parent, string prefix, int depth)
{
    static foreach (i, name; FieldNameTuple!T)
    {{
        alias F = Fields!T[i];
        static if (isPointer!F && isAggregateType!(PointerTarget!F))
            alias Target = PointerTarget!F;
        else
            alias Target = F;

        const path = prefix.length ? prefix ~ "." ~ name : name;

        static if (isLeafType!Target)
        {
            d.data.add(PropNode(path, name, F.stringof,
                present(__traits(getMember, value, name)), false, false), parent);
            d.visited++;
        }
        else
        {
            const wantOpen = d.open.isOpen(path);
            const capped = wantOpen && depth + 1 >= d.maxDepth;
            const node = d.data.add(PropNode(path, name, F.stringof,
                composite: true, capped: capped), parent);
            d.visited++;
            if (wantOpen && !capped && d.visited < d.maxNodes)
            {
                static if (isPointer!F)
                {
                    auto p = __traits(getMember, value, name);
                    if (p !is null)
                        descend!Target(d, *p, node, path, depth + 1);
                }
                else
                    descend!Target(d, __traits(getMember, value, name), node,
                        path, depth + 1);
            }
        }
    }}
}

private string present(T)(in T v)
{
    static if (isSomeString!T)
        return `"` ~ v.idup ~ `"`;
    else
        return text(v);
}

// ── the subject ──────────────────────────────────────────────────────────────

struct Vec2 { float x = 0, y = 0; }
struct Material { string name; Vec2 offset; }
struct Node
{
    string label;
    Vec2 position;
    Material material;
    Node* parent;     // the cycle
}

// ── driving ──────────────────────────────────────────────────────────────────

Descent build(ref Node subject, DisclosureState!string open, int maxDepth = 8)
{
    auto d = Descent(open: open, maxDepth: maxDepth);
    descend!Node(d, subject, uint.max, "", 0);
    return d;
}

void dump(ref Descent d)
{
    import std.stdio : writefln;

    auto rows = flatten!PropNode(d.data,
        (uint n) => d.open.isOpen(d.data.nodes[n].value.path));
    foreach (r; rows)
    {
        auto n = d.data.nodes[r.node].value;
        string indent;
        foreach (_; 0 .. r.depth) indent ~= "  ";
        const marker = !n.composite ? "  "
            : n.capped ? "⋯ "
            : d.open.isOpen(n.path) ? "▾ " : "▸ ";
        writefln("%s%s%-12s %-10s %s", indent, marker, n.label, n.typeName,
            n.composite ? (n.capped ? "(capped)" : "") : n.value);
    }
    writefln("  → %s rows materialised", rows.length);
}

void main()
{
    import std.stdio : writeln, writefln;

    Node root = Node("root");
    () @trusted { root.parent = &root; }();

    writeln("C1 — a walk parameterised by TYPE ONLY compiles on a cyclic type.");
    writeln("     (this program built; `reflect-descent.d` could not)\n");

    writeln("C2 — nothing open: one level, composites marked closed");
    auto d0 = build(root, DisclosureState!string.allClosed());
    dump(d0);

    writeln("\nC2 — the reader opens `parent`, then `parent.parent`:");
    auto open = DisclosureState!string.allClosed()
        .opened("parent").opened("parent.parent");
    auto d1 = build(root, open);
    dump(d1);

    writeln("\nC2 — same opened set, subject MUTATED: expansion survives");
    root.label = "renamed";
    root.position.x = 3;
    auto d2 = build(root, open);
    dump(d2);

    writeln("\nC3 — allOpen(): the walk is now undriven. Depth cap = 4:");
    auto d3 = build(root, DisclosureState!string.allOpen(), 4);
    dump(d3);
    writefln("     without a cap this does not terminate; with it: %s nodes",
        d3.visited);
}
