#!/usr/bin/env dub
/+ dub.sdl:
    name "table"
    dependency "sparkles:core-cli" version="*"
    targetPath "build"
+/

import sparkles.core_cli.ui.demo : Section, runDemo;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.styled_template : styledText;

void main()
{
    runDemo(
        header: "drawTable Demo - All Features",
        content: [
            Section(
                header: "Single Cell",
                content: [["Hello"]].drawTable,
            ),
            Section(
                header: "Single Row",
                content: [["Name", "Age", "City"]].drawTable,
            ),
            Section(
                header: "Basic Table",
                content: [
                    ["Name", "Age", "City"],
                    ["Alice", "30", "New York"],
                    ["Bob", "25", "San Francisco"],
                    ["Charlie", "35", "Chicago"],
                ].drawTable,
            ),
            Section(
                header: "Varying Column Widths",
                content: [
                    ["ID", "Description", "Status"],
                    ["1", "Short", "OK"],
                    ["2", "A much longer description here", "Pending"],
                    ["3", "Medium length", "Failed"],
                ].drawTable,
            ),
            Section(
                header: "Bold Headers",
                content: [
                    [styledText(i"{bold Name}"), styledText(i"{bold Status}"), styledText(i"{bold Priority}")],
                    ["Task 1", "Done", "High"],
                    ["Task 2", "In Progress", "Medium"],
                    ["Task 3", "Pending", "Low"],
                ].drawTable,
            ),
            Section(
                header: "Color-Coded Status",
                content: [
                    [styledText(i"{bold Metric}"), styledText(i"{bold Value}"), styledText(i"{bold Status}")],
                    ["CPU Usage", "45%", styledText(i"{green OK}")],
                    ["Memory", "78%", styledText(i"{yellow Warning}")],
                    ["Disk", "92%", styledText(i"{red Critical}")],
                    ["Network", "12%", styledText(i"{green OK}")],
                ].drawTable,
            ),
            Section(
                header: "Mixed Styles",
                content: [
                    ["Status", "Description"],
                    [styledText(i"{green OK}"), "Everything is working fine"],
                    [styledText(i"{yellow WARN}"), "Some issues detected"],
                    [styledText(i"{red FAIL}"), "Critical failure"],
                ].drawTable,
            ),
            Section(
                header: "Multiple Styles Combined",
                content: [
                    [styledText(i"{bold.underline.cyan Type}"), styledText(i"{bold.underline.cyan Message}")],
                    [styledText(i"{bold.blue INFO}"), styledText(i"{dim Application started}")],
                    [styledText(i"{dim.italic.magenta DEBUG}"), styledText(i"{italic Loading configuration...}")],
                    [styledText(i"{bold.inverse.red ERROR}"), styledText(i"{bold.red Connection failed!}")],
                ].drawTable,
            ),
            Section(
                header: "Fully Styled Table",
                content: [
                    [
                        styledText(i"{bold.underline.brightCyan Server}"),
                        styledText(i"{bold.underline.brightCyan Status}"),
                        styledText(i"{bold.underline.brightCyan Load}"),
                    ],
                    [styledText(i"{bold.brightGreen web-01}"), styledText(i"{inverse.green UP}"), styledText(i"{green 23%}")],
                    [styledText(i"{bold.brightGreen web-02}"), styledText(i"{inverse.green UP}"), styledText(i"{bold.yellow 45%}")],
                    [styledText(i"{bold.strikethrough.brightRed db-01}"), styledText(i"{bold.inverse.red DOWN}"), styledText(i"{dim.italic 0%}")],
                ].drawTable,
            ),
            Section(
                header: "Alignment Stress Test",
                content: [
                    [styledText(i"{red A}"), "This is a very long description that should align properly"],
                    [styledText(i"{green OK}"), "Short"],
                    [styledText(i"{yellow WARN}"), "Medium length text here"],
                ].drawTable,
            ),
        ],
    );
}
