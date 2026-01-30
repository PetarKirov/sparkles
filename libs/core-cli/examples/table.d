#!/usr/bin/env dub

/+ dub.sdl:
name "table"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import sparkles.core_cli.ui.table;
import sparkles.core_cli.ui.box : BoxProps;
import std.stdio : writeln;

void main()
{
    // Simple single-cell table
    writeln("Single cell:");
    drawTable([["Hello"]]).writeln;

    // Single row with multiple columns
    writeln("Single row:");
    drawTable([["Name", "Age", "City"]]).writeln;

    // Multiple rows and columns
    writeln("User data:");
    drawTable([
        ["Name", "Age", "City"],
        ["Alice", "30", "New York"],
        ["Bob", "25", "San Francisco"],
        ["Charlie", "35", "Chicago"]
    ]).writeln;

    // Varying column widths
    writeln("Varying widths:");
    drawTable([
        ["ID", "Description", "Status"],
        ["1", "Short", "OK"],
        ["2", "A much longer description here", "Pending"],
        ["3", "Medium length", "Failed"]
    ]).writeln;

    // Numeric data
    writeln("Numeric data:");
    drawTable([
        ["Product", "Price", "Qty", "Total"],
        ["Widget", "$10.00", "5", "$50.00"],
        ["Gadget", "$25.50", "2", "$51.00"],
        ["Gizmo", "$5.25", "10", "$52.50"]
    ]).writeln;
}
