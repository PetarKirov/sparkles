#!/usr/bin/env dub
/+ dub.sdl:
    name "layout"
    dependency "sparkles:core-cli" path="../../.."
    targetPath "build"
+/

// Horizontal composition (`sparkles.core_cli.ui.layout`): `hjoin` zips
// pre-rendered blocks side by side (top-aligned, padded by visible width, so
// boxes sit next to tables next to plain text, ANSI styling and all), and
// `kvList` renders aligned label/value lines — the release tool's receipt.

module layout_example;

import std.stdio : writeln;

import sparkles.base.text.width : Align;
import sparkles.core_cli.ui.box : BoxProps, drawBox;
import sparkles.core_cli.ui.layout : hjoin, kvList;
import sparkles.core_cli.ui.table : drawTable, TableProps;

void main()
{
    // A box, a table, and a plain block side by side.
    const box = drawBox(["one", "two"], "box");
    const table = drawTable([["a", "b"], ["1", "2"]],
        TableProps(columnAligns: [Align.left, Align.right]));
    const notes = "plain\ntext\nblock";
    writeln(hjoin([box, table, notes]));

    writeln();

    // kvList: aligned label/value pairs — frame it for a receipt.
    auto pairs = kvList([
        ["tag", "v0.6.0 (annotated)"],
        ["subject", "v0.6.0 — live TUI components"],
        ["pushed", "origin ✔"],
    ]);
    writeln(drawBox(pairs, "✔ released v0.6.0",
        BoxProps(footer: "next: release --stage=publish-gh-release")));
}
