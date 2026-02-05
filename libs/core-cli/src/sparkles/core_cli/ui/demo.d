/++
Demo runner utilities for showcasing UI components.

Provides a structured way to display multiple sections with headers,
useful for examples and demonstrations.
+/
module sparkles.core_cli.ui.demo;

import std.stdio : writeln;

import sparkles.core_cli.ui.header : drawHeader, HeaderProps, HeaderStyle;

@safe:

/// A section in a demo with a header and content.
struct Section
{
    string header;
    string content;
}

/// Configuration for demo rendering.
struct DemoProps
{
    size_t width = 67;
    string endTitle = "Demo Complete";
}

/// Runs a demo by printing a header banner, sections, and closing banner.
///
/// Params:
///   header = The demo header shown in the opening banner
///   content = Array of sections to display
///   props = Configuration options
///
/// Example:
/// ---
/// runDemo(
///     header: "My Demo",
///     content: [
///         Section(header: "First", content: "Some content here"),
///         Section(header: "Second", content: "More content"),
///     ],
/// );
/// ---
void runDemo(string header, Section[] content, DemoProps props = DemoProps.init)
{
    header.drawHeader(HeaderProps(style: HeaderStyle.banner, width: props.width)).writeln("\n");

    foreach (section; content)
    {
        section.header.drawHeader.writeln;
        section.content.writeln("\n");
    }

    props.endTitle.drawHeader(HeaderProps(style: HeaderStyle.banner, width: props.width)).writeln;
}

/// Section initialization
@("demo.Section.init")
@safe pure nothrow @nogc
unittest
{
    const section = Section(header: "Title", content: "Body text");
    assert(section.header == "Title");
    assert(section.content == "Body text");
}

/// DemoProps defaults
@("demo.DemoProps.defaults")
@safe pure nothrow @nogc
unittest
{
    const props = DemoProps.init;
    assert(props.width == 67);
    assert(props.endTitle == "Demo Complete");
}
