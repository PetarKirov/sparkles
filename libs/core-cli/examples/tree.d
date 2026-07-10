#!/usr/bin/env dub
/+ dub.sdl:
    name "tree"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// Tree views (`sparkles.core_cli.ui.tree`) over flat, pre-ordered
// `(label, depth)` nodes — no recursive node objects; any depth-first walk
// renders directly, with `├─`/`└─` connectors and `│` rails computed from
// later-sibling lookahead. The guides also compose as a table stub column.

module tree_example;

import std.stdio : writeln;

import sparkles.base.text.width : Align;
import sparkles.core_cli.ui.table : drawTable, TableProps;
import sparkles.core_cli.ui.tree : renderTree, TreeNode, treeGlyphs;

void main()
{
    auto nodes = [
        TreeNode("apps", 0),
        TreeNode("ci", 1),
        TreeNode("release", 1),
        TreeNode("src", 2),
        TreeNode("libs", 0),
        TreeNode("base", 1),
        TreeNode("core-cli", 1),
    ];

    foreach (line; renderTree(nodes))
        writeln(line);

    writeln();
    foreach (line; renderTree(nodes[0 .. 4], treeGlyphs(false))) // ASCII fallback
        writeln(line);

    // Tree guides inside a table's first column (the release tool's per-area
    // breakdown does exactly this).
    writeln();
    const guides = renderTree(nodes);
    string[][] rows = [["Area", "Changed"]];
    const changed = ["+1355 / -181", "+120 / -15", "+980 / -60", "+910 / -55",
        "+622 / -204", "+310 / -104", "+312 / -100"];
    foreach (i, guide; guides)
        rows ~= [guide, changed[i]];
    writeln(drawTable(rows, TableProps(title: "Changed by area",
        headerRows: 1, columnAligns: [Align.left, Align.right])));
}
