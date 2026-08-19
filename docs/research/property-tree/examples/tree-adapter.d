#!/usr/bin/env dub
/+ dub.sdl:
    name "property_tree_tree_adapter"
    targetPath "build"
    dependency "sparkles:ui" path="../../../.."
    dflags "-preview=in" "-preview=dip1000"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
/**
 * The whole thing as an ADAPTER over the existing components:
 * `TreeData!PropNode` + `TreeViewState!string` + `activate`/`collapseOrUp` +
 * `treeText`. No new interaction machinery.
 *
 * Under test:
 *   C20. A property tree needs NOTHING new from the tree component except a
 *        rebuild: `TreeStep.rebuild` already means "the opened set changed",
 *        which for us means "re-walk the subject".
 *   C21. `state.open` keyed by the path string is the whole persistence story.
 *   C22. The one real toolkit gap: `TreeData.hasChildren` is STRUCTURAL, so a
 *        closed composite whose children were never materialised renders as a
 *        leaf and `collapseOrUp` will not close it. `activate` already reads an
 *        `expandable` capability off the node value; `treeView`/`writeTreeText`
 *        and `collapseOrUp` do not.
 *   C23. An edit ([`edit-commands.d`](./edit-commands.d)) followed by a rebuild refreshes the badges and
 *        preserves cursor and expansion — the frame model's whole promise.
 *
 * Run: `dub run --single tree-adapter.d`
 */
module property_tree_tree_adapter;

import std.conv : text, to;
import std.traits : hasUDA, isAggregateType, isArray, isSomeString;

import sparkles.ui.components.inspector : treeText;
import sparkles.ui.components.tree_view : activate, collapseOrUp,
    measureContent, TreeStep, TreeViewState;
import sparkles.ui.components.tree_widget : flatten, TreeData, TreeGlyphs;

@safe:

enum readOnly;

/// The node value, carrying exactly the capabilities the existing views read:
/// `label`, `badge` — plus `expandable`, which `activate` already honours.
struct PropNode
{
    string path;
    string label;
    string badge;       /// the presented value; empty for composites
    bool expandable;
    bool editable = true;
}

// ── the adapter ──────────────────────────────────────────────────────────────

/// NOTE (C24): the adapter does NOT store a pointer to the subject. Under
/// dip1000 a struct holding `T*` into a caller's stack becomes `scope`, and
/// every non-scope member call on it is then refused in `@safe` code. Taking
/// `ref T` per rebuild is both safer and simpler — and it matches the frame
/// model, where the subject is whatever the host has THIS frame.
struct PropTree(T)
{
    TreeData!PropNode data;
    TreeViewState!string state;
    int maxDepth = 16;

    void rebuild(ref T subject)
    {
        data = TreeData!PropNode.init;
        walk(subject, uint.max, "", 0);
        state.rows = flatten!PropNode(data, (uint n) => isOpen(n));
        state.measureContent(data);
        state.clamp();
    }

    bool isOpen(uint node) const => state.open.isOpen(data.nodes[node].value.path);
    string keyOf(uint node) const => data.nodes[node].value.path;

    private void walk(U)(ref U v, uint parent, string prefix, int depth)
    {
        static foreach (name; __traits(allMembers, U))
        {{
            alias M = __traits(getMember, U, name);
            static if (__traits(compiles, typeof(M)) && !is(typeof(M) == function))
            {{
                alias F = typeof(M);
                const path = prefix.length ? prefix ~ "." ~ name : name;
                static if (isAggregateType!F && !isSomeString!F)
                {
                    const node = data.add(PropNode(path, name, "", true,
                        !hasUDA!(M, readOnly)), parent);
                    if (state.open.isOpen(path) && depth + 1 < maxDepth)
                        walk(__traits(getMember, v, name), node, path, depth + 1);
                }
                else static if (isArray!F && !isSomeString!F)
                {
                    auto ref arr = __traits(getMember, v, name);
                    const node = data.add(PropNode(path, name,
                        text("[", arr.length, "]"), arr.length > 0,
                        !hasUDA!(M, readOnly)), parent);
                    if (state.open.isOpen(path) && depth + 1 < maxDepth)
                        foreach (i, ref e; arr)
                        {
                            const ep = path ~ "[" ~ i.to!string ~ "]";
                            data.add(PropNode(ep, "[" ~ i.to!string ~ "]",
                                text(e), false, !hasUDA!(M, readOnly)), node);
                        }
                }
                else
                    data.add(PropNode(path, name,
                        text(__traits(getMember, v, name)), false,
                        !hasUDA!(M, readOnly)), parent);
            }}
        }}
    }
}

// ── the subject ──────────────────────────────────────────────────────────────

enum Cap { butt, round }
struct Stroke { double width = 1; Cap cap; }
struct Layer
{
    string name = "layer";
    bool visible = true;
    Stroke stroke;
    int[] dashes;
    @readOnly ulong id = 42;
}

// ── driving a session ────────────────────────────────────────────────────────

void main()
{
    import std.stdio : write, writefln, writeln;

    Layer l;
    l.dashes = [4, 2];
    PropTree!Layer t;
    t.state.width = 40;
    t.state.height = 14;
    t.rebuild(l);

    void show(string what)
    {
        writefln("\n── %s  (cursor=%s, rows=%s) ─────────", what, t.state.sel,
            t.state.rows.length);
        write(treeText(t.data, t.state.rows));
    }

    show("closed");

    writeln("\nC20/C22 — Enter on `stroke`: `activate` reads `expandable` from");
    writeln("          the node value, so a not-yet-materialised composite");
    writeln("          still toggles. It returns rebuild; the adapter obeys.");
    t.state.moveSel(2);                        // → stroke
    auto step = activate(t.state, t.data, (uint n) => t.keyOf(n));
    writefln("          activate → %s   key = %s", step, t.keyOf(t.state.selectedNode));
    if (step == TreeStep.rebuild) t.rebuild(l);
    show("stroke open");

    writeln("\nC22 — the gap: Left on the SAME node. `collapseOrUp` asks");
    writeln("      `data.hasChildren`, which is structural, so it closes only");
    writeln("      because the children happen to be materialised now:");
    const before = t.state.open.isOpen("stroke");
    step = collapseOrUp(t.state, t.data, (uint n) => t.keyOf(n));
    writefln("      collapseOrUp → %s   stroke open: %s → %s", step, before,
        t.state.open.isOpen("stroke"));
    if (step == TreeStep.rebuild) t.rebuild(l);
    writeln("      With the node CLOSED, its children are gone, so a second");
    writeln("      Left cannot distinguish `stroke` from a leaf — it climbs to");
    writeln("      the parent instead. `collapseOrUp` needs the same");
    writeln("      `expandable` capability `activate` already has.");

    writeln("\nC21/C23 — open two nodes, move the cursor, then EDIT:");
    t.state.open = t.state.open.opened("stroke").opened("dashes");
    t.rebuild(l);
    t.state.sel = 4;
    show("two open, cursor on stroke.cap");

    l.stroke.width = 3.5;                       // an edit lands ([`edit-commands.d`](./edit-commands.d))
    l.dashes = [8, 4, 1];                       // and a structural one
    t.rebuild(l);
    show("after the edit — badges refreshed, expansion and cursor kept");

    writefln("\n  opened set survived as data: %s", t.state.open.exceptions);
    writefln("  read-only field is marked: id.editable = %s",
        t.data.nodes[t.state.rows[$ - 1].node].value.editable);
}
