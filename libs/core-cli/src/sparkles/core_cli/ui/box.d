module sparkles.core_cli.ui.box;

import std.algorithm.comparison : max;
import std.algorithm.iteration : map;
import std.algorithm.searching : maxElement;
import std.range : walkLength, repeat;
import std.format : format;

import sparkles.core_cli.term_unstyle : unstyledLength;

struct BoxProps
{
    bool omitLeftBorder = false;

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

    // Minimum width to fit: ╭──╼ {title} ╾─╮ (overhead = 9) and bottom: ╰──────────╯ (overhead = 10)
    const titleWidth = title.unstyledLength;
    const minWidth = max(titleWidth + 9, 10) - prefixLen;
    const contentWidth = content.map!(x => x.unstyledLength).maxElement;
    const outputWidth = max(contentWidth, minWidth);

    auto topLine = props.horizontalLine.repeat(outputWidth + prefixLen - titleWidth - 7);
    auto bottomLine = props.horizontalLine.repeat(outputWidth + prefixLen - 10);

    auto top = "╭──╼ %s ╾%s─╮".format(title, topLine);
    auto bot = "╰────────%s──╯".format(bottomLine);

    string result = top ~ '\n';

    foreach (line; content)
    {
        const rightPadLen = outputWidth - line.unstyledLength;
        result ~= "%s%s%s %s\n".format(prefix, line, ' '.repeat(rightPadLen), props.verticalLine);
    }

    result ~= bot;

    return result;
}

/// Overload that accepts a single string and splits it into lines internally.
string drawBox(string content, string title, BoxProps props = BoxProps.init)
{
    import std.array : array;
    import std.string : lineSplitter;

    return drawBox(content.lineSplitter.array, title, props);
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

@("drawBox.styled.contentWithAnsiCodes")
@system unittest
{
    import sparkles.core_cli.term_style : Style, stylize;

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
    import sparkles.core_cli.term_style : Style, stylize;

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
