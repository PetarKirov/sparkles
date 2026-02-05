#!/usr/bin/env dub
/+ dub.sdl:
    name "box"
    dependency "sparkles:core-cli" version="*"
    targetPath "build"
+/

import std.algorithm : map, joiner;
import std.conv : to;

import sparkles.core_cli.ui.box : drawBox, BoxProps;
import sparkles.core_cli.ui.demo : Section, runDemo;
import sparkles.core_cli.ui.table : drawTable;
import sparkles.core_cli.term_style : Style, stylize, styleSample;
import sparkles.core_cli.term_style : stb = stylizedTextBuilder;
import sparkles.core_cli.prettyprint : prettyPrint, PrettyPrintOptions;

struct Config
{
    string host;
    int port;
    bool ssl;
    string[] endpoints;
}

struct Server
{
    string name;
    string ip;
    int port;
}

struct Cluster
{
    string name;
    Server[] servers;
    bool active;
}

void main()
{
    runDemo(
        header: "drawBox Demo - All Features",
        content: [
            Section(
                header: "Simple Box",
                content: ["1"]
                    .drawBox("1"),
            ),
            Section(
                header: "Box with Styled Content",
                content: [
                    "Status:    ".stylize(Style.bold) ~ "Running".stylize(Style.green),
                    "Mode:      ".stylize(Style.bold) ~ "Production".stylize(Style.yellow),
                    "Health:    ".stylize(Style.bold) ~ "Healthy".stylize(Style.brightGreen),
                    "Uptime:    ".stylize(Style.bold) ~ "3 days, 14 hours".stylize(Style.cyan),
                ].drawBox("Status"),
            ),
            Section(
                header: "Box without Left Border",
                content: ["This is line number 1", "This is line number 2", "This is line number 3"]
                    .drawBox("No Border", BoxProps(omitLeftBorder: true)),
            ),
            Section(
                header: "Box with Embedded Table",
                content: [
                    ["Name", "Age", "Role"],
                    ["Alice", "30", "Engineer"],
                    ["Bob", "25", "Designer"],
                    ["Carol", "35", "Manager"],
                ].drawTable.drawBox("Team"),
            ),
            Section(
                header: "Box with prettyPrint Output",
                content: Config(
                    host: "localhost",
                    port: 8080,
                    ssl: true,
                    endpoints: ["/api", "/health", "/metrics"],
                ).prettyPrint(PrettyPrintOptions(softMaxWidth: 0)).drawBox("Config"),
            ),
            Section(
                header: "Dashboard Example",
                content: [
                    ["Metric".stylize(Style.bold), "Value".stylize(Style.bold), "Status".stylize(Style.bold)],
                    ["CPU Usage", "45%", "OK".stylize(Style.green)],
                    ["Memory", "2.1 GB", "OK".stylize(Style.green)],
                    ["Disk", "89%", "Warning".stylize(Style.yellow)],
                    ["Network", "1.2 Gbps", "OK".stylize(Style.green)],
                ].drawTable.drawBox("Metrics"),
            ),
            Section(
                header: "Color Palette Box",
                content: [
                    "Foreground Colors:".stylize(Style.bold),
                    "  " ~ [Style.red, Style.green, Style.yellow, Style.blue, Style.magenta, Style.cyan]
                        .map!styleSample.joiner(" ").to!string,
                    "",
                    "Bright Colors:".stylize(Style.bold),
                    "  " ~ [Style.brightRed, Style.brightGreen, Style.brightYellow, Style.brightBlue]
                        .map!styleSample.joiner(" ").to!string,
                    "",
                    "Styles:".stylize(Style.bold),
                    "  " ~ [Style.bold, Style.dim, Style.italic, Style.underline, Style.strikethrough]
                        .map!styleSample.joiner(" ").to!string,
                ].drawBox("Styles"),
            ),
            Section(
                header: "Complex Data Structure",
                content: Cluster(
                    name: "Production",
                    servers: [
                        Server("web-01", "192.168.1.10", 80),
                        Server("web-02", "192.168.1.11", 80),
                        Server("db-01", "192.168.1.20", 5432),
                    ],
                    active: true,
                ).prettyPrint(PrettyPrintOptions(softMaxWidth: 60)).drawBox("Cluster"),
            ),
        ],
    );
}
