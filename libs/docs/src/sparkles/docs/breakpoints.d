/++
Responsive breakpoints in columns (design-system `WEB5`, D62): a generated page
changes layout at the widths where a terminal layout does, measured in columns
of the monospace face rather than device pixels.

The page's root element is the query container and is set in the mono face, so
a container query's `ch` is one mono column; `body` keeps its own font, so
nothing visible changes. A registered `--spk-col` carries that column into
rules whose own font differs, so "100 columns" means the same width everywhere
on the page.

Only generated pages use these: the VitePress site keeps VitePress's own media
queries (D62).
+/
module sparkles.docs.breakpoints;

@safe:

/// The column widths a layout may change at (`WEB5`): a terminal's narrow,
/// standard and wide surfaces.
enum Columns : uint
{
    compact = 80,  /// below this, side panels yield their width
    standard = 120, /// declared; no generated page has a rule here yet
    wide = 160,    /// from this, a content column may widen
}

/++
The container every column query is evaluated against: the root element, set
in the mono face (the theme's `code` role when the page carries the design
system's properties), and `--spk-col`, one of its columns as an absolute length
for rules on elements in other faces.
+/
enum string containerCss =
    "  @property --spk-col { syntax: '<length>'; inherits: true; initial-value: 1ch; }\n"
    ~ "  html { container: spk-page / inline-size;\n"
    ~ "         font-family: var(--spk-font-code, ui-monospace, monospace); --spk-col: 1ch; }\n";

/// The opening of a container query matching a page narrower than `cols`
/// columns; the caller closes it with `}`.
string below(Columns cols) @safe pure
{
    import std.conv : text;

    return text("  @container spk-page (width < ", cast(uint) cols, "ch) {\n");
}

/// ditto, at least `cols` columns wide.
string atLeast(Columns cols) @safe pure
{
    import std.conv : text;

    return text("  @container spk-page (width >= ", cast(uint) cols, "ch) {\n");
}

/// A length of `cols` mono columns, usable on an element in any face.
string columns(uint cols) @safe pure
{
    import std.conv : text;

    return text("calc(", cols, " * var(--spk-col))");
}

///
@("docs.breakpoints.queriesAreInMonoColumns")
@safe pure unittest
{
    import std.algorithm.searching : canFind;

    assert(below(Columns.compact) == "  @container spk-page (width < 80ch) {\n");
    assert(atLeast(Columns.wide) == "  @container spk-page (width >= 160ch) {\n");
    assert(columns(100) == "calc(100 * var(--spk-col))");
    // The container is the root, in the mono face, and the column is registered
    // as a length so it computes there and inherits as one.
    assert(containerCss.canFind("html { container: spk-page / inline-size;"));
    assert(containerCss.canFind("syntax: '<length>'; inherits: true;"));
}
