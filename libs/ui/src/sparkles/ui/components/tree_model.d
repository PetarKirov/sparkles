/++
The presentation-free half of the tree component: flat node lists in, guide
state out. No glyphs, no styles, no renderer.

This is the split the
[tree-view case study](../../../../../../docs/research/tui-libraries/tree-view-case-study.md)
identifies as the central design insight — data, interaction state and view as
three layers, with $(B flatten as a pure free function) between them rather than
a method that also loads children and applies filters. $(LREF treeRows) is that
function: given pre-ordered `(label, depth)` nodes it yields one $(LREF TreeRow)
per node carrying the depth and whether the node is the last child of its
parent, which is everything a renderer needs to draw guides.

Precomputing `isLastChild` also removes a quadratic: the previous renderer
answered "does this ancestor have a later sibling?" by scanning forward from
every node at every level. One backward pass answers it for all nodes at once,
which is what broot precomputes as its `left_branches` array.
+/
module sparkles.ui.components.tree_model;

import sparkles.ui.components.tree : TreeNode;

@safe:

/// One flattened row: where the node sits, and the one fact a renderer cannot
/// derive locally. `depth` is copied from the node so a renderer needs only the
/// row.
struct TreeRow
{
    size_t index;     /// index into the input node list
    size_t depth;     /// nesting level; `0` is a root
    bool isLastChild; /// no later sibling at this depth before the walk rises above it
}

/**
Flattens `nodes` into one $(LREF TreeRow) each, in input order.

Pure and total: a malformed depth jump (a node more than one level deeper than
its predecessor) yields rows all the same, leaving the renderer to decide how to
draw the gap.

Runs in `O(nodes.length + maxDepth)`.
*/
TreeRow[] treeRows(in TreeNode[] nodes) pure nothrow
{
    auto rows = new TreeRow[](nodes.length);
    if (!nodes.length)
        return rows;

    // Backward pass: `laterAtLevel[d]` records whether a node at depth `d` has
    // been seen since the walk last rose above `d`. Visiting a node at depth `d`
    // closes every deeper level — anything below it belongs to a different
    // parent — so those flags reset.
    size_t maxDepth;
    foreach (ref n; nodes)
        if (n.depth > maxDepth)
            maxDepth = n.depth;

    auto laterAtLevel = new bool[](maxDepth + 1);
    foreach_reverse (i, ref node; nodes)
    {
        const d = node.depth;
        rows[i] = TreeRow(index: i, depth: d, isLastChild: !laterAtLevel[d]);
        laterAtLevel[d] = true;
        foreach (k; d + 1 .. laterAtLevel.length)
            laterAtLevel[k] = false;
    }
    return rows;
}

@("tree_model.treeRows.lastChildFlags")
@safe pure unittest
{
    // apps has two children (ci, release); release is the last, and its own
    // child src is a last child too.
    const nodes = [
        TreeNode("apps", 0),
        TreeNode("ci", 1),
        TreeNode("release", 1),
        TreeNode("src", 2),
        TreeNode("libs", 0),
        TreeNode("base", 1),
    ];
    const rows = treeRows(nodes);
    assert(rows.length == nodes.length);
    assert(!rows[0].isLastChild); // apps — libs follows at depth 0
    assert(!rows[1].isLastChild); // ci — release follows at depth 1
    assert(rows[2].isLastChild);  // release — nothing after it at depth 1
    assert(rows[3].isLastChild);  // src
    assert(rows[4].isLastChild);  // libs — the final root
    assert(rows[5].isLastChild);  // base
}

@("tree_model.treeRows.reopenedLevel")
@safe pure unittest
{
    // b is not a last child (d follows at the same depth), so a rail is drawn
    // under it; c and e are.
    const nodes = [
        TreeNode("a", 0),
        TreeNode("b", 1),
        TreeNode("c", 2),
        TreeNode("d", 1),
        TreeNode("e", 2),
    ];
    const rows = treeRows(nodes);
    assert(!rows[1].isLastChild); // b
    assert(rows[2].isLastChild);  // c
    assert(rows[3].isLastChild);  // d
    assert(rows[4].isLastChild);  // e
}

@("tree_model.treeRows.empty")
@safe pure unittest
{
    assert(treeRows([]).length == 0);
}

@("tree_model.treeRows.matchesForwardScan")
@safe pure unittest
{
    // The backward pass must agree with the obvious quadratic definition on
    // every shape, including malformed depth jumps.
    static bool laterSiblingByScan(in TreeNode[] nodes, size_t i, size_t level)
    {
        foreach (j; i + 1 .. nodes.length)
        {
            if (nodes[j].depth < level)
                return false;
            if (nodes[j].depth == level)
                return true;
        }
        return false;
    }

    static immutable size_t[][] shapes = [
        [0, 1, 1, 2, 0, 1],
        [0, 1, 2, 1, 2],
        [0, 2, 1, 0],       // malformed jump 0 -> 2
        [2, 2, 0],          // starts deep
        [0],
        [0, 0, 0],
    ];
    foreach (shape; shapes)
    {
        TreeNode[] nodes;
        foreach (d; shape)
            nodes ~= TreeNode("n", d);
        const rows = treeRows(nodes);
        foreach (i, ref row; rows)
            assert(row.isLastChild == !laterSiblingByScan(nodes, i, nodes[i].depth));
    }
}
