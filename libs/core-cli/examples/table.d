#!/usr/bin/env dub

/+ dub.sdl:
name "table"
dependency "sparkles:core-cli" version="*"
targetPath "build"
+/

import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.term_style : Style, stylize;
import std.stdio : writeln;

void main()
{
    writeln("═══════════════════════════════════════════════════════════════");
    writeln("                    drawTable Examples");
    writeln("═══════════════════════════════════════════════════════════════\n");

    // Simple single-cell table
    writeln("1. Single cell:");
    drawTable([["Hello"]]).writeln;

    // Single row with multiple columns
    writeln("2. Single row:");
    drawTable([["Name", "Age", "City"]]).writeln;

    // Multiple rows and columns
    writeln("3. Basic table:");
    drawTable([
        ["Name", "Age", "City"],
        ["Alice", "30", "New York"],
        ["Bob", "25", "San Francisco"],
        ["Charlie", "35", "Chicago"]
    ]).writeln;

    // Varying column widths
    writeln("4. Varying column widths:");
    drawTable([
        ["ID", "Description", "Status"],
        ["1", "Short", "OK"],
        ["2", "A much longer description here", "Pending"],
        ["3", "Medium length", "Failed"]
    ]).writeln;

    // =========================================================================
    // STYLED CONTENT EXAMPLES - Tests ANSI escape code handling
    // =========================================================================

    writeln("═══════════════════════════════════════════════════════════════");
    writeln("                    Styled Content Tests");
    writeln("═══════════════════════════════════════════════════════════════\n");

    // Styled headers
    writeln("5. Bold headers:");
    drawTable([
        ["Name".stylize(Style.bold), "Status".stylize(Style.bold), "Priority".stylize(Style.bold)],
        ["Task 1", "Done", "High"],
        ["Task 2", "In Progress", "Medium"],
        ["Task 3", "Pending", "Low"]
    ]).writeln;

    // Color-coded status
    writeln("6. Color-coded status (tests alignment with different escape code lengths):");
    drawTable([
        ["Metric".stylize(Style.bold), "Value".stylize(Style.bold), "Status".stylize(Style.bold)],
        ["CPU Usage", "45%", "OK".stylize(Style.green)],
        ["Memory", "78%", "Warning".stylize(Style.yellow)],
        ["Disk", "92%", "Critical".stylize(Style.red)],
        ["Network", "12%", "OK".stylize(Style.green)]
    ]).writeln;

    // Mixed styles - the key test for proper alignment
    writeln("7. Mixed styles (short styled vs long unstyled):");
    drawTable([
        ["Status", "Description"],
        ["OK".stylize(Style.green), "Everything is working fine"],
        ["WARN".stylize(Style.yellow), "Some issues detected"],
        ["FAIL".stylize(Style.red), "Critical failure"]
    ]).writeln;

    // Multiple styles per cell
    writeln("8. Multiple styles combined:");
    drawTable([
        ["Type".stylize(Style.bold).stylize(Style.underline).stylize(Style.cyan), "Message".stylize(Style.bold).stylize(Style.underline).stylize(Style.cyan)],
        ["INFO".stylize(Style.blue).stylize(Style.bold), "Application started".stylize(Style.dim)],
        ["DEBUG".stylize(Style.magenta).stylize(Style.dim).stylize(Style.italic), "Loading configuration...".stylize(Style.italic)],
        ["ERROR".stylize(Style.red).stylize(Style.bold).stylize(Style.inverse), "Connection failed!".stylize(Style.red).stylize(Style.bold)]
    ]).writeln;

    // Styled content in all cells
    writeln("9. Fully styled table:");
    drawTable([
        [
            "Server".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
            "Status".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
            "Load".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
        ],
        ["web-01".stylize(Style.brightGreen).stylize(Style.bold), "UP".stylize(Style.green).stylize(Style.inverse), "23%".stylize(Style.green)],
        ["web-02".stylize(Style.brightGreen).stylize(Style.bold), "UP".stylize(Style.green).stylize(Style.inverse), "45%".stylize(Style.yellow).stylize(Style.bold)],
        ["db-01".stylize(Style.brightRed).stylize(Style.bold).stylize(Style.strikethrough), "DOWN".stylize(Style.red).stylize(Style.inverse).stylize(Style.bold), "0%".stylize(Style.dim).stylize(Style.italic)]
    ]).writeln;

    // Edge case: very short styled text next to long unstyled
    writeln("10. Alignment stress test (short styled vs long unstyled):");
    drawTable([
        ["A".stylize(Style.red), "This is a very long description that should align properly"],
        ["OK".stylize(Style.green), "Short"],
        ["WARN".stylize(Style.yellow), "Medium length text here"]
    ]).writeln;

    writeln("═══════════════════════════════════════════════════════════════");
    writeln("If all tables above have properly aligned columns, the fix works!");
    writeln("═══════════════════════════════════════════════════════════════");
}
