module sparkles.core_cli.ui.table;

import std.array : array;
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
    size_t[] maxColumnWidths = columnWidths(cells);

    size_t fullWidth = maxColumnWidths.sum +
        (maxColumnWidths.length - 1) * 3 +
        4;

    string result;
    result ~= format("%s%s%s\n",
        props.topLeft,
        props.horizontalLine.repeat(fullWidth - 2),
        props.topRight);

    foreach (row; cells)
        result ~= format("%s %-(%s%| | %) %s\n", props.verticalLine,
            row,
            props.verticalLine);

    result ~= format("%s%s%s\n",
        props.bottomLeft,
        props.horizontalLine.repeat(fullWidth - 2),
        props.bottomRight);
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
