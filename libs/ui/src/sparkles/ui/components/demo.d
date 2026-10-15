/++
Demo runner utilities for showcasing UI components.

Provides a structured way to display multiple sections with headers,
useful for examples and demonstrations.
+/
module sparkles.ui.components.demo;

import std.stdio : write, writeln;

import sparkles.ui.components.header : drawHeader, HeaderProps, HeaderStyle;

@safe:

/// The type of $(LREF Section.writeContent): given a sink, writes the
/// section's content into it.
alias ContentWriter = void delegate(scope void delegate(const(char)[]) @safe sink) @safe;

/// A section in a demo with a header and content.
struct Section
{
    string header;  /// The section's banner.
    string content; /// Its content, as text.

    /// Or its content as a writer: called with a sink, which is an output
    /// range. Used instead of `content` when set.
    ContentWriter writeContent;

    /// A section of text.
    this(string header, string content) pure nothrow @nogc
    {
        this.header = header;
        this.content = content;
    }

    /// A section written by `writeContent` when the demo runs.
    this(string header, ContentWriter writeContent) pure nothrow @nogc
    {
        this.header = header;
        this.writeContent = writeContent;
    }

    /// A section whose content is any value that writes itself through
    /// `toString(Writer)`, such as `drawTable(cells)` or `prettyPrint(x)`: it is
    /// written when the demo runs, with no string built first.
    this(T)(string header, T content)
    if (!is(T : const(char)[]) && !is(T : ContentWriter) && isWritable!T)
    {
        this.header = header;
        this.writeContent = (sink) { content.toString(sink); };
    }
}

private enum bool isWritable(T) = __traits(compiles, (const T t) {
    scope void delegate(const(char)[]) @safe sink;
    t.toString(sink);
});

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
///         Section(header: "Table", content: drawTable([["a", "b"]])),
///     ],
/// );
/// ---
void runDemo(string header, Section[] content, DemoProps props = DemoProps.init)
{
    header.drawHeader(HeaderProps(style: HeaderStyle.banner, width: props.width)).writeln("\n");

    foreach (section; content)
    {
        section.header.drawHeader.writeln;
        if (section.writeContent !is null)
        {
            section.writeContent((const(char)[] text) { write(text); });
            write("\n\n");
        }
        else
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

/// A section's content can be any value that writes itself.
@("demo.Section.writeContent")
@safe unittest
{
    import sparkles.ui.components.table : drawTable;

    string got;
    const section = Section(header: "Table", content: drawTable([["a", "b"]]));
    section.writeContent((const(char)[] text) { got ~= text; });
    assert(got == "╭───┬───╮\n│ a │ b │\n╰───┴───╯\n");
}
