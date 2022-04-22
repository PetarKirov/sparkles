module sparkles.test_utils.string;

/++
Removes leading whitespace indentation from each line in the range.

Params:
    range = range of characters on which to operate
    levelsOfIndentation = number of repetition of indent; 1 level by default
    indent = whitespace used for indentation; 4 spaces by default

Returns:
    The resulting range with each line stripped from `levelsOfIndentation` number of occurances of `indent`.
++/
auto outdent(Range)(auto ref Range range, uint levelsOfIndentation = 1, string indent = "    ")
{
    import std.array : array;
    import std.algorithm : map, joiner;
    import std.range : repeat;
    import std.string : lineSplitter, skipPrefix = chompPrefix;
    import std.typecons : Yes;
    import std.conv;

    auto leadingIndent = indent.repeat(levelsOfIndentation).joiner.array;

    return range
        .skipPrefix("\n")
        .lineSplitter!(Yes.keepTerminator)
        .map!(line => line.skipPrefix(leadingIndent))
        .joiner
        .to!string;
}

pure @safe
unittest
{
    import std.array : array;
    import std.string : splitLines;
	auto s = "
    Transaction {
      from: 0xDcE029Dc77087DE89ED1B9DAe8b6007272fbFc2A
      to: 0x2bc71FD2010fD525885491ff0Db7C530F1a207E4
    }".outdent;

    assert(s.array.splitLines == [
        "Transaction {"d,
        "  from: 0xDcE029Dc77087DE89ED1B9DAe8b6007272fbFc2A",
        "  to: 0x2bc71FD2010fD525885491ff0Db7C530F1a207E4",
        "}"
	]);
}
