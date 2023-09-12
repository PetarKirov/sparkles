module sparkles.core_cli.ui.box;

import std.algorithm.iteration : map;
import std.algorithm.searching : maxElement;
import std.range : walkLength, repeat;
import std.format : format;

import sparkles.core_cli.term_unstyle : unstyledLenght;

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
    const outputWidth = content.map!(x => x.unstyledLenght).maxElement;
    const titleWidth = title.unstyledLenght;

    const prefix = props.omitLeftBorder ? ""d : props.verticalLine ~ " "d;
    const prefixLen = prefix.length;

    auto topLine = props.horizontalLine.repeat(outputWidth + prefixLen - titleWidth - 7);
    auto bottomLine = props.horizontalLine.repeat(outputWidth + prefixLen - 10);

    auto top = "╭──╼ %s ╾%s─╮".format(title, topLine);
    auto bottom = "╰────────%s──╯".format(bottomLine);

    string result = top ~ '\n';

    foreach (line; content)
    {
        const rightPadLen = outputWidth - line.unstyledLenght;
        result ~= "%s%s%s %s\n".format(prefix, line, ' '.repeat(rightPadLen), props.verticalLine);
    }

    result ~= bottom;

    return result;
}

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
