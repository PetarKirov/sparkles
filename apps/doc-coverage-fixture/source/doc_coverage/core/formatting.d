module doc_coverage.core.formatting;

/// Style values rendered in diagnostics.
enum UiStyle
{
    plain,
    warning,
    error,
}

/// Wrapper struct used for docs and nested members.
struct StyleTag
{
    UiStyle style;
    string label;

    this(UiStyle style, string label)
    {
        this.style = style;
        this.label = label;
    }

    string render() const
    {
        return label;
    }
}

/// Formats a command line for display.
///
/// Example:
/// ---
/// assert(formatLine("move", UiStyle.warning) == "[warning] move");
/// ---
string formatLine(string line, UiStyle style = UiStyle.plain)
{
    return "[" ~ style.to!string ~ "] " ~ line;
}

import std.conv : to;

@("docCoverage.core.formatting.formatLine")
@safe
unittest
{
    assert(formatLine("quit", UiStyle.error) == "[error] quit");
}
