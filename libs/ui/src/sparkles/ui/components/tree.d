/++
Tree-view rendering over flat, pre-ordered `(label, depth)` node lists — the
storage the [tree-view case study](../../../../../../docs/research/tui-libraries/tree-view-case-study.md)
recommends: no recursive node objects, parent/child structure implied entirely
by order and depth, so any depth-first traversal (e.g. the release tool's
per-area breakdown) renders directly.

`renderTree` is a pure producer returning one guide-prefixed line per node
(`├─`/`└─` connectors, `│` continuation rails); an ASCII fallback charset
covers non-UTF-8 terminals.
+/
module sparkles.ui.components.tree;

/// One node of a flattened tree: pre-order position + depth define the shape.
/// A node is a child of the nearest preceding node with a smaller depth.
struct TreeNode
{
    string label;
    size_t depth;
}

/// The guide charset. Each entry is one 3-cell prefix segment.
struct TreeGlyphs
{
    string tee    = "├─ "; /// A child with later siblings.
    string corner = "└─ "; /// The last child of its parent.
    string rail   = "│  "; /// Continuation under an ancestor with later siblings.
    string blank  = "   "; /// Continuation under a completed ancestor.
}

/// The charset for a terminal's unicode capability.
TreeGlyphs treeGlyphs(bool unicode) @safe pure nothrow @nogc
{
    if (unicode)
        return TreeGlyphs.init;
    return TreeGlyphs(tee: "|- ", corner: "`- ", rail: "|  ", blank: "   ");
}

/// Render `nodes` as guide-prefixed lines, one per node in order. Root-level
/// nodes (`depth == 0`) carry no guides; deeper nodes get a connector at their
/// own level and rails/blanks under their ancestors, computed from whether the
/// ancestor has a later sibling. Malformed depth jumps (a node more than one
/// level deeper than its predecessor) are clamped visually by treating the
/// missing levels as blanks — rendering never fails.
string[] renderTree(in TreeNode[] nodes, in TreeGlyphs glyphs = TreeGlyphs.init) @safe pure
{
    import sparkles.ui.components.tree_model : treeRows;

    const rows = treeRows(nodes);

    // Rich's four-state guide model: `railAtLevel[d]` says whether the ancestor
    // that owns level `d` still has later siblings, so a rail is drawn under it
    // rather than a blank. Each row updates its own level for the rows beneath.
    bool[] railAtLevel;
    string[] lines;
    lines.reserve(nodes.length);
    foreach (i, ref node; nodes)
    {
        const row = rows[i];
        if (railAtLevel.length <= row.depth)
            railAtLevel.length = row.depth + 1;

        string prefix;
        if (row.depth > 0)
        {
            foreach (level; 1 .. row.depth)
                prefix ~= railAtLevel[level] ? glyphs.rail : glyphs.blank;
            prefix ~= row.isLastChild ? glyphs.corner : glyphs.tee;
        }
        railAtLevel[row.depth] = !row.isLastChild;
        lines ~= prefix ~ node.label;
    }
    return lines;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("tree.renderTree.guides")
@safe pure unittest
{
    auto nodes = [
        TreeNode("apps", 0),
        TreeNode("ci", 1),
        TreeNode("release", 1),
        TreeNode("src", 2),
        TreeNode("libs", 0),
        TreeNode("base", 1),
    ];
    assert(renderTree(nodes) == [
        "apps",
        "├─ ci",
        "└─ release",
        "   └─ src",
        "libs",
        "└─ base",
    ]);
}

@("tree.renderTree.railsUnderOpenAncestors")
@safe pure unittest
{
    auto nodes = [
        TreeNode("a", 0),
        TreeNode("b", 1),
        TreeNode("c", 2),   // b still has the later sibling d -> rail under it
        TreeNode("d", 1),
        TreeNode("e", 2),
    ];
    assert(renderTree(nodes) == [
        "a",
        "├─ b",
        "│  └─ c",
        "└─ d",
        "   └─ e",
    ]);
}

@("tree.renderTree.asciiAndEmpty")
@safe pure unittest
{
    assert(renderTree([]) == cast(string[]) []);
    auto nodes = [TreeNode("root", 0), TreeNode("leaf", 1)];
    assert(renderTree(nodes, treeGlyphs(false)) == ["root", "`- leaf"]);
}
