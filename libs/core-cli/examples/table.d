#!/usr/bin/env dub
/+ dub.sdl:
    name "table"
    dependency "sparkles:core-cli" version="*"
    targetPath "build"
+/

import sparkles.core_cli.ui.demo : Section, runDemo;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.term_style : Style, stylize;

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
                    ["Name".stylize(Style.bold), "Status".stylize(Style.bold), "Priority".stylize(Style.bold)],
                    ["Task 1", "Done", "High"],
                    ["Task 2", "In Progress", "Medium"],
                    ["Task 3", "Pending", "Low"],
                ].drawTable,
            ),
            Section(
                header: "Color-Coded Status",
                content: [
                    ["Metric".stylize(Style.bold), "Value".stylize(Style.bold), "Status".stylize(Style.bold)],
                    ["CPU Usage", "45%", "OK".stylize(Style.green)],
                    ["Memory", "78%", "Warning".stylize(Style.yellow)],
                    ["Disk", "92%", "Critical".stylize(Style.red)],
                    ["Network", "12%", "OK".stylize(Style.green)],
                ].drawTable,
            ),
            Section(
                header: "Mixed Styles",
                content: [
                    ["Status", "Description"],
                    ["OK".stylize(Style.green), "Everything is working fine"],
                    ["WARN".stylize(Style.yellow), "Some issues detected"],
                    ["FAIL".stylize(Style.red), "Critical failure"],
                ].drawTable,
            ),
            Section(
                header: "Multiple Styles Combined",
                content: [
                    ["Type".stylize(Style.bold).stylize(Style.underline).stylize(Style.cyan), "Message".stylize(Style.bold).stylize(Style.underline).stylize(Style.cyan)],
                    ["INFO".stylize(Style.blue).stylize(Style.bold), "Application started".stylize(Style.dim)],
                    ["DEBUG".stylize(Style.magenta).stylize(Style.dim).stylize(Style.italic), "Loading configuration...".stylize(Style.italic)],
                    ["ERROR".stylize(Style.red).stylize(Style.bold).stylize(Style.inverse), "Connection failed!".stylize(Style.red).stylize(Style.bold)],
                ].drawTable,
            ),
            Section(
                header: "Fully Styled Table",
                content: [
                    [
                        "Server".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
                        "Status".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
                        "Load".stylize(Style.bold).stylize(Style.underline).stylize(Style.brightCyan),
                    ],
                    ["web-01".stylize(Style.brightGreen).stylize(Style.bold), "UP".stylize(Style.green).stylize(Style.inverse), "23%".stylize(Style.green)],
                    ["web-02".stylize(Style.brightGreen).stylize(Style.bold), "UP".stylize(Style.green).stylize(Style.inverse), "45%".stylize(Style.yellow).stylize(Style.bold)],
                    ["db-01".stylize(Style.brightRed).stylize(Style.bold).stylize(Style.strikethrough), "DOWN".stylize(Style.red).stylize(Style.inverse).stylize(Style.bold), "0%".stylize(Style.dim).stylize(Style.italic)],
                ].drawTable,
            ),
            Section(
                header: "Alignment Stress Test",
                content: [
                    ["A".stylize(Style.red), "This is a very long description that should align properly"],
                    ["OK".stylize(Style.green), "Short"],
                    ["WARN".stylize(Style.yellow), "Medium length text here"],
                ].drawTable,
            ),
        ],
    );
}
