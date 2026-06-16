module sparkles.core_cli.ui.box;

import std.algorithm.comparison : max;
import std.algorithm.iteration : map;
import std.algorithm.searching : maxElement, canFind;
import std.range : walkLength, repeat;
import std.format : format;

import sparkles.base.text.grapheme : visibleWidth;

struct BoxProps
{
    bool omitLeftBorder = false;
    string footer = null;

    /// Lower/upper bounds on the box's total visible width (frame included), in the
    /// same units as `HeaderProps.width` — set both equal for a fixed-width box.
    ///
    /// `maxWidth`, if non-zero, wraps each content line so the box stays within this
    /// many columns (0 = no wrapping, the box expands to fit the longest line). A
    /// title or unbreakable content line wider than `maxWidth` still wins — the box
    /// is never truncated below what it must show. Styled content keeps its
    /// colours/links across wrapped rows and is reset before the border so style
    /// never bleeds onto the padding or frame.
    ///
    /// `minWidth`, if non-zero, pads the box out to at least this many columns so
    /// short content still produces a full-width frame.
    size_t maxWidth = 0;
    size_t minWidth = 0; /// ditto

    dchar topLeft = '╭';
    dchar topRight = '╮';
    dchar bottomLeft = '╰';
    dchar bottomRight = '╯';

    dchar horizontalLine = '─';
    dchar verticalLine = '│';

    dchar titlePrefix = '╼';
    dchar titleSuffix = '╾';
}

string drawBox(string[] content, string title, BoxProps props = BoxProps.init)
{
    const prefix = props.omitLeftBorder ? ""d : props.verticalLine ~ " "d;
    const prefixLen = prefix.length;

    // The frame eats `prefixLen` columns on the left plus " │" (2) on the right, so
    // a box of total width W has a content area of `W - frameOverhead` columns. The
    // public min/maxWidth are total-box widths; convert them to content widths here.
    const frameOverhead = prefixLen + 2;
    const contentMax = props.maxWidth > frameOverhead ? props.maxWidth - frameOverhead : 0;
    const contentMin = props.minWidth > frameOverhead ? props.minWidth - frameOverhead : 0;

    // Optionally re-flow each content line to the maxWidth-derived content area,
    // keeping styles/links across rows and resetting before the border.
    string[] lines = contentMax > 0 ? wrapContent(content, contentMax) : content;

    // Minimum width to fit: ╭──╼ {title} ╾─╮ (overhead = 9) and bottom: ╰──────────╯ (overhead = 10)
    const titleWidth = title.visibleWidth;
    const footerWidth = props.footer !is null ? props.footer.visibleWidth : 0;
    const minTitleWidth = titleWidth + 9;
    const minFooterWidth = footerWidth > 0 ? footerWidth + 9 : 10;  // ╰──╼ {footer} ╾──╯ or ╰──────────╯
    const titleFloor = max(minTitleWidth, minFooterWidth) - prefixLen;
    const contentWidth = lines.map!(x => x.visibleWidth).maxElement;
    const outputWidth = max(contentWidth, titleFloor, contentMin);

    auto topLine = props.horizontalLine.repeat(outputWidth + prefixLen - titleWidth - 7);

    auto top = "╭──╼ %s ╾%s─╮".format(title, topLine);

    string result = top ~ '\n';

    foreach (line; lines)
    {
        const rightPadLen = outputWidth - line.visibleWidth;
        result ~= "%s%s%s %s\n".format(prefix, line, ' '.repeat(rightPadLen), props.verticalLine);
    }

    // Bottom line with optional footer
    if (props.footer !is null)
    {
        auto bottomLine = props.horizontalLine.repeat(outputWidth + prefixLen - footerWidth - 7);
        result ~= "╰──╼ %s ╾%s─╯".format(props.footer, bottomLine);
    }
    else
    {
        auto bottomLine = props.horizontalLine.repeat(outputWidth + prefixLen - 10);
        result ~= "╰────────%s──╯".format(bottomLine);
    }

    return result;
}

/// Overload that accepts a single string and splits it into lines internally.
string drawBox(string content, string title, BoxProps props = BoxProps.init)
{
    import std.array : array;
    import std.string : lineSplitter;

    return drawBox(content.lineSplitter.array, title, props);
}

/// Wrap each content line to `width` visible columns, returning the resulting
/// box rows. A row that contains any escape is reset (`\x1b[0m`) so an open style
/// cannot bleed onto the box's padding or border.
private string[] wrapContent(string[] content, size_t width)
{
    import std.array : appender;
    import std.string : lineSplitter;

    import sparkles.base.text.wrap : wrapText, WrapOptions, WhitespaceMode;

    auto rows = appender!(string[]);
    foreach (line; content)
        foreach (row; line.wrapText(
                WrapOptions(width: width, whitespace: WhitespaceMode.collapse)).lineSplitter)
            rows ~= row.canFind('\x1b') ? row ~ "\x1b[0m" : row.idup;
    return rows[];
}

@("drawBox.basic.singleLine")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Hello"].drawBox("T") == `
        ╭──╼ T ╾───╮
        │ Hello    │
        ╰──────────╯`.outdent(2));
}

@("drawBox.basic.multiLine")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Line 1", "Line 2", "Line 3"].drawBox("Title") == `
        ╭──╼ Title ╾───╮
        │ Line 1       │
        │ Line 2       │
        │ Line 3       │
        ╰──────────────╯`.outdent(2));
}

@("drawBox.basic.varyingLineWidths")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Short", "A longer line", "Mid"].drawBox("Box") == `
        ╭──╼ Box ╾──────╮
        │ Short         │
        │ A longer line │
        │ Mid           │
        ╰───────────────╯`.outdent(2));
}

@("drawBox.width.contentWiderThanTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["This is a very long content line"].drawBox("T") == `
        ╭──╼ T ╾───────────────────────────╮
        │ This is a very long content line │
        ╰──────────────────────────────────╯`.outdent(2));
}

@("drawBox.width.titleWiderThanContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // This tests the fix for the underflow bug
    assert(["Hi"].drawBox("Long Title Here") == `
        ╭──╼ Long Title Here ╾───╮
        │ Hi                     │
        ╰────────────────────────╯`.outdent(2));
}

@("drawBox.width.minimalContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Single character content and title - tests minimum box size
    assert(["x"].drawBox("T") == `
        ╭──╼ T ╾───╮
        │ x        │
        ╰──────────╯`.outdent(2));
}

@("drawBox.width.emptyTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Content"].drawBox("") == `
        ╭──╼  ╾────╮
        │ Content  │
        ╰──────────╯`.outdent(2));
}

@("drawBox.props.omitLeftBorder")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Line 1", "Line 2"].drawBox("Title", BoxProps(omitLeftBorder: true)) == `
        ╭──╼ Title ╾───╮
        Line 1         │
        Line 2         │
        ╰──────────────╯`.outdent(2));
}

@("drawBox.props.omitLeftBorderWithLongTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // When omitLeftBorder is true, prefix is empty, affecting minWidth calculation
    assert(["Hi"].drawBox("Very Long Title", BoxProps(omitLeftBorder: true)) == `
        ╭──╼ Very Long Title ╾───╮
        Hi                       │
        ╰────────────────────────╯`.outdent(2));
}

@("drawBox.props.footer")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Content"].drawBox("Title", BoxProps(footer: "Done")) == `
        ╭──╼ Title ╾───╮
        │ Content      │
        ╰──╼ Done ╾────╯`.outdent(2));
}

@("drawBox.props.footerWiderThanContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Footer wider than content should expand the box
    assert(["Hi"].drawBox("T", BoxProps(footer: "Completed successfully")) == `
        ╭──╼ T ╾────────────────────────╮
        │ Hi                            │
        ╰──╼ Completed successfully ╾───╯`.outdent(2));
}

@("drawBox.props.footerWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // Styled footer should not affect width calculation
    auto styledFooter = "✓ OK".stylize(Style.green);
    assert(["Content"].drawBox("Title", BoxProps(footer: styledFooter)) ==
        "╭──╼ Title ╾───╮\n" ~
        "│ Content      │\n" ~
        "╰──╼ \x1b[32m✓ OK\x1b[39m ╾────╯");
}

@("drawBox.styled.contentWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // ANSI codes should not affect box width calculation
    auto styledContent = "Hello".stylize(Style.bold);
    assert([styledContent].drawBox("T") ==
        "╭──╼ T ╾───╮\n" ~
        "│ \x1b[1mHello\x1b[22m    │\n" ~
        "╰──────────╯");
}

@("drawBox.styled.titleWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // Styled title should not affect width calculation
    auto styledTitle = "Title".stylize(Style.cyan);
    assert(["Content here"].drawBox(styledTitle) ==
        "╭──╼ \x1b[36mTitle\x1b[39m ╾───╮\n" ~
        "│ Content here │\n" ~
        "╰──────────────╯");
}

@("drawBox.overload.singleString")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Test the single-string overload that splits on newlines
    assert("Line 1\nLine 2".drawBox("T") == `
        ╭──╼ T ╾───╮
        │ Line 1   │
        │ Line 2   │
        ╰──────────╯`.outdent(2));
}

@("drawBox.overload.singleStringMultipleNewlines")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert("A\nBB\nCCC".drawBox("X") == `
        ╭──╼ X ╾───╮
        │ A        │
        │ BB       │
        │ CCC      │
        ╰──────────╯`.outdent(2));
}

// Legacy test using test files
unittest
{
    import std.algorithm.iteration : each;
    import std.array : array;
    import std.string : lineSplitter;
    import std.stdio : writeln;
    import sparkles.core_cli.test_utils : readFromTestDir;

    void drawFileInBox(string path, bool omitLeftBorder = false)
    {
        path
            .readFromTestDir
            .lineSplitter.array
            .drawBox("Sample Title", BoxProps(omitLeftBorder))
            .writeln;
    }

    drawFileInBox("out0.txt");
    drawFileInBox("out1.txt", true);
}

// function draw_box {
//   local title="$1"
//   local draw_left_box_side="${2:-}"
//   local reset_esc_seq="${3:-}"
//   local title_len=${#title}
//   title="${bold}${title}${offbold}"

//   local output
//   output="$(cat)"

//   local output_width
//   output_width="$(echo "$output" | remove_ansi_escapes | wc -L)"

//   local prefix
//   if [[ "$draw_left_box_side" != false ]]; then
//     prefix='│ '
//   else
//     prefix=''
//   fi

//   prefix_len="${#prefix}"

//   local topline
//   topline="$(draw_line $((output_width + prefix_len - title_len - 7 )))"

//   local bottomline
//   bottomline="$(draw_line $((output_width + prefix_len - 10 )))"

//   echo "╭──╼ ${title} ╾${topline}─╮"

//   while IFS="" read -r line
//   do
//     local line_length
//     line_length="$(echo "$line" | remove_ansi_escapes | wc -L)"

//     local rightPadLen=$((output_width - line_length))
//     local rightPad
//     rightPad="$(repeatStr "$rightPadLen" ' ')"

//     printf '%s%s%s │\n' "$prefix" "$line" "$rightPad"
//   done <<< "$output"

//   echo "╰────────${bottomline}──╯${reset_esc_seq}"
// }

@("drawBox.wrap.disabledByDefault")
@system unittest
{
    import std.string : splitLines;

    // maxWidth defaults to 0 -> no wrapping, box expands to fit the long line.
    const box = drawBox(["aaaa bbbb cccc"], "T");
    assert(box.splitLines.length == 3); // top + one content row + bottom
}

@("drawBox.wrap.wrapsLongLine")
@system unittest
{
    import std.string : splitLines;
    import std.algorithm.searching : canFind;

    // maxWidth is the total box width; with the 4-column frame overhead this
    // leaves a 4-column content area, so "aaaa bbbb cccc" wraps to three rows.
    const box = drawBox(["aaaa bbbb cccc"], "T", BoxProps(maxWidth: 8));
    assert(box.splitLines.length == 5); // top + three content rows + bottom
    assert(box.canFind("aaaa") && box.canFind("bbbb") && box.canFind("cccc"));
}

@("drawBox.wrap.styledNoBleed")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.term_style : stylize, Style;

    // A styled line wrapped across rows is reset before the border, so colour
    // cannot bleed onto the padding or frame.
    const styled = "red red red".stylize(Style.red);
    const box = drawBox([styled], "T", BoxProps(maxWidth: 11));
    assert(box.canFind("\x1b[0m"));
}

@("drawBox.width.minWidthPads")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // minWidth pads a short box out to a fixed total width so stacked boxes align.
    const box = drawBox(["x"], "T", BoxProps(minWidth: 40));
    foreach (line; box.splitLines)
        assert(line.visibleWidth == 40);
}

@("drawBox.width.minMaxEqualFixedWidth")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // Setting minWidth == maxWidth yields a fixed-width box: long content wraps in,
    // short content pads out, every row lands on the requested total width.
    const box = drawBox(["aaaa bbbb cccc dddd eeee", "short"], "T",
        BoxProps(minWidth: 20, maxWidth: 20));
    foreach (line; box.splitLines)
        assert(line.visibleWidth == 20);
}
