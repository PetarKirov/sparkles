#!/usr/bin/env dub
/+ dub.sdl:
    name "styled_template"
    dependency "sparkles:core-cli" version="*"
    targetPath "build"
+/

import sparkles.core_cli.styled_template;
import sparkles.core_cli.ui.box : drawBox;
import sparkles.core_cli.ui.demo : Section, runDemo;

void main()
{
    runDemo(
        header: "styledTemplate Demo - IES Style Syntax",
        content: [
            Section(
                header: "Single Style",
                content: [
                    styledText(i"{red This text is red}"),
                    styledText(i"{green This text is green}"),
                    styledText(i"{blue This text is blue}"),
                    styledText(i"{yellow This text is yellow}"),
                ].drawBox("Colors"),
            ),
            Section(
                header: "Chained Styles",
                content: [
                    styledText(i"{bold.red Bold and red}"),
                    styledText(i"{italic.cyan Italic and cyan}"),
                    styledText(i"{underline.magenta Underlined magenta}"),
                    styledText(i"{bold.italic.green Bold, italic, and green}"),
                ].drawBox("Combined"),
            ),
            Section(
                header: "Text Attributes",
                content: [
                    styledText(i"{bold Bold text}"),
                    styledText(i"{dim Dim text}"),
                    styledText(i"{italic Italic text}"),
                    styledText(i"{underline Underlined text}"),
                    styledText(i"{strikethrough Strikethrough text}"),
                ].drawBox("Attributes"),
            ),
            Section(
                header: "Background Colors",
                content: [
                    styledText(i"{bgRed White on red}"),
                    styledText(i"{bgGreen Black on green}"),
                    styledText(i"{bgBlue White on blue}"),
                    styledText(i"{bgYellow.black Black on yellow}"),
                ].drawBox("Backgrounds"),
            ),
            Section(
                header: "Nested Blocks",
                content: [
                    styledText(i"{bold Bold {red with red} back to bold}"),
                    styledText(i"{cyan Cyan {bold.underline bold underlined} just cyan}"),
                    styledText(i"{dim Dim {brightWhite bright} dim again}"),
                ].drawBox("Nesting"),
            ),
            Section(
                header: "Style Negation",
                content: [
                    styledText(i"{bold.red Bold red {~red just bold} bold red again}"),
                    styledText(i"{italic.underline Both {~italic underline only} both}"),
                ].drawBox("Negation with ~"),
            ),
            Section(
                header: "Complex Combinations",
                content: complexExamples().drawBox("Advanced"),
            ),
            Section(
                header: "With Interpolation",
                content: interpolationExamples().drawBox("Variables"),
            ),
            Section(
                header: "Escaped Braces",
                content: [
                    styledText(i"Use {{style text}} syntax for styling"),
                    styledText(i"{bold Literal braces: {{these}} are not styles}"),
                    styledText(i`JSON example: {{"key": "value"}}`),
                ].drawBox("Escaping"),
            ),
            Section(
                header: "Practical Examples",
                content: practicalExamples().drawBox("Real World"),
            ),
        ],
    );
}

string[] interpolationExamples()
{
    int cpu = 75;
    int memory = 42;
    string status = "running";
    double temperature = 65.5;

    return [
        styledText(i"CPU: {red $(cpu)%}"),
        styledText(i"Memory: {green $(memory)%}"),
        styledText(i"Status: {bold.cyan $(status)}"),
        styledText(i"Temp: {yellow $(temperature)}C"),
    ];
}

string[] complexExamples()
{
    return [
        // Deep nesting: 4 levels with style changes at each
        styledText(i"{bold.italic.red L1:{~red.underline L2:{cyan L3:{~bold.~italic L4}L3}L2}L1}"),

        // Multiple negations then restore
        styledText(i"{bold.italic.underline ALL {~bold.~underline just italic} ALL again}"),

        // Negation combined with addition
        styledText(i"{bold.red start {~red.cyan swap colors} back to red}"),

        // Three-level nesting with additions
        styledText(i"{red outer {bold middle {underline.cyan inner} middle} outer}"),

        // Style accumulation through levels
        styledText(i"{bold B {italic BI {underline BIU {red BIUR} BIU} BI} B}"),

        // Toggle effect: remove and re-add
        styledText(i"{bold.red on {~bold off {bold on} off} on}"),
    ];
}

string[] practicalExamples()
{
    string errorMsg = "Connection refused";
    string filename = "config.json";
    int line = 42;
    int errors = 3;
    int warnings = 7;

    return [
        styledText(i"{red.bold ERROR:} $(errorMsg)"),
        styledText(i"{yellow WARNING:} Deprecated API usage"),
        styledText(i"{green.bold SUCCESS:} Build completed"),
        styledText(i"{dim $(filename):$(line)} - {red $(errors) errors}, {yellow $(warnings) warnings}"),
        styledText(i"Press {bold.cyan q} to quit, {bold.cyan h} for help"),
    ];
}
