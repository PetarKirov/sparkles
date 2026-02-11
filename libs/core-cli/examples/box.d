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
import sparkles.core_cli.styled_template : styledText;
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
                    styledText(i"{bold Status:    }{green Running}"),
                    styledText(i"{bold Mode:      }{yellow Production}"),
                    styledText(i"{bold Health:    }{brightGreen Healthy}"),
                    styledText(i"{bold Uptime:    }{cyan 3 days, 14 hours}"),
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
                ).prettyPrint(PrettyPrintOptions!void(softMaxWidth: 0)).drawBox("Config"),
            ),
            Section(
                header: "Dashboard Example",
                content: [
                    [styledText(i"{bold Metric}"), styledText(i"{bold Value}"), styledText(i"{bold Status}")],
                    ["CPU Usage", "45%", styledText(i"{green OK}")],
                    ["Memory", "2.1 GB", styledText(i"{green OK}")],
                    ["Disk", "89%", styledText(i"{yellow Warning}")],
                    ["Network", "1.2 Gbps", styledText(i"{green OK}")],
                ].drawTable.drawBox("Metrics"),
            ),
            Section(
                header: "Color Palette Box",
                content: [
                    styledText(i"{bold Foreground Colors:}"),
                    "  " ~ [Style.red, Style.green, Style.yellow, Style.blue, Style.magenta, Style.cyan]
                        .map!styleSample.joiner(" ").to!string,
                    "",
                    styledText(i"{bold Bright Colors:}"),
                    "  " ~ [Style.brightRed, Style.brightGreen, Style.brightYellow, Style.brightBlue]
                        .map!styleSample.joiner(" ").to!string,
                    "",
                    styledText(i"{bold Styles:}"),
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
                ).prettyPrint(PrettyPrintOptions!void(softMaxWidth: 60)).drawBox("Cluster"),
            ),
            Section(
                header: "Box with Footer",
                content: [
                    "Build started at 14:32:01",
                    "Compiling 42 modules...",
                    "Linking executable...",
                    "Build completed in 3.2s",
                ].drawBox("Build Log", BoxProps(footer: styledText(i"{green ✓ Success}"))),
            ),
            Section(
                header: "Task Status with Footer",
                content: [
                    styledText(i"{bold Task:      }Deploy to production"),
                    styledText(i"{bold Started:   }2024-01-15 10:30"),
                    styledText(i"{bold Duration:  }45 seconds"),
                ].drawBox(
                    styledText(i"{cyan deploy-v2.1.0}"),
                    BoxProps(footer: styledText(i"{red ✗ Failed}")),
                ),
            ),
        ],
    );
}
