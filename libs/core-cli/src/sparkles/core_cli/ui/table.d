module sparkles.core_cli.ui.table;

import std.array : array;
import std.conv : to;
import std.algorithm : map, all, maxElement, sum;
import std.range : walkLength, repeat, iota;
import std.format : format;

import sparkles.core_cli.ui.box : BoxProps;

bool hasRectangularShape(T)(const T[][] array)
{
    size_t width = array[0].length;
    return array.all!(row => row.length == width);
}

unittest
{
    assert([[]].hasRectangularShape());
    assert([[1]].hasRectangularShape());
    assert([[], []].hasRectangularShape());
    assert([[1], [2]].hasRectangularShape());
    assert([[], [], []].hasRectangularShape());
    assert([[1], [2], [3]].hasRectangularShape());
    assert([[1, 2], [3, 4], [5, 6]].hasRectangularShape());
    assert([[1, 2, 3], [4, 5, 6], [7, 8, 9]].hasRectangularShape());

    assert(![[], [1], [1, 2]].hasRectangularShape());
    assert(![[1, 2], [1], [1, 2]].hasRectangularShape());
    assert(![[1], [2], [3, 3], []].hasRectangularShape());
    assert(![[1, 2], [3, 4], []].hasRectangularShape());
}

size_t[] columnWidths(string[][] cells)
in (hasRectangularShape(cells))
{
    return cells[0].length
        .iota
        .map!(col => cells.map!(row => row[col].length).maxElement())
        .array;
}

unittest
{
    assert(columnWidths([[""]]) == [0]);
    assert(columnWidths([
       ["1", "123"],
       ["12", ""]
    ]) == [2, 3]);
    assert(columnWidths([
       ["1234", "1"],
       ["1", ""],
       ["123", "12345"],
       ["", "12"]
    ]) == [4, 5]);
}

// Future directions:
//
// * Implement different styles, like these:
//   * https://ozh.github.io/ascii-tables/


string drawTable(string[][] cells, BoxProps props = BoxProps.init)
in (hasRectangularShape(cells))
{
    size_t[] maxColWidths = columnWidths(cells);
    size_t numCols = maxColWidths.length;

    // Build top border with column separators
    string result;
    result ~= props.topLeft;
    foreach (i, width; maxColWidths)
    {
        result ~= props.horizontalLine.repeat(width + 2).to!string;
        if (i < numCols - 1)
            result ~= '┬';
    }
    result ~= props.topRight;
    result ~= '\n';

    // Build each row with padded cells
    foreach (row; cells)
    {
        result ~= props.verticalLine;
        foreach (i, cell; row)
        {
            result ~= format(" %-*s ", maxColWidths[i], cell);
            if (i < numCols - 1)
                result ~= props.verticalLine;
        }
        result ~= props.verticalLine;
        result ~= '\n';
    }

    // Build bottom border with column separators
    result ~= props.bottomLeft;
    foreach (i, width; maxColWidths)
    {
        result ~= props.horizontalLine.repeat(width + 2).to!string;
        if (i < numCols - 1)
            result ~= '┴';
    }
    result ~= props.bottomRight;
    result ~= '\n';

    return result;
}

unittest
{
    import sparkles.test_utils.string : outdent;
    import std.stdio;
    void check(string actual, string expected)
    {
        import sparkles.test_utils;
        if (actual != expected)
        {
            diffWithTool(actual, expected, false, DiffTools.deltaUserConfig).writeln;
            assert(0);
        }
    }

    check(drawTable([["x"]]), `
        ╭───╮
        │ x │
        ╰───╯
        `.outdent(2));

    check(drawTable([["123"]]), `
        ╭─────╮
        │ 123 │
        ╰─────╯
        `.outdent(2));

    check(drawTable([["123", "ab"], ["c", "asdasd"]]), `
        ╭─────┬────────╮
        │ 123 │ ab     │
        │ c   │ asdasd │
        ╰─────┴────────╯
        `.outdent(2));
}
