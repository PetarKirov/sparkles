module sparkles.test_utils.diff_tools;

enum DiffTools
{
    deltaUserConfig = "delta --file-style omit --hunk-header-style omit %s %s",
    deltaPlainConfig = "delta --no-gitconfig --keep-plus-minus-markers --file-style omit --diff-so-fancy --hunk-header-style omit %s %s",
    diffSoFancy = "git diff --no-index -- %s %s | diff-so-fancy",
}

@safe
string diffWithToolExplain(string actual, string expected, bool disableColor = false,
        string toolFormatString = DiffTools.deltaUserConfig)
{
    return "---\nError: Actual string does not match expected string:\n---\n" ~
        diffWithTool("actual", "expected", disableColor, toolFormatString) ~
        "---\n" ~
        diffWithTool(actual, expected, disableColor, toolFormatString) ~
        "---\n";
}

@safe
string diffWithTool(string actual, string expected, bool disableColor = false,
        string toolFormatString = DiffTools.deltaUserConfig)
{
    import std.algorithm : skipOver;
    import std.format : format;
    import std.process : executeShell;
    import sparkles.test_utils.tmpfs : TmpFS;

    auto tmpfs = TmpFS.create();

    string cmd = format(toolFormatString, tmpfs.writeFile(actual ~ "\n"),
            tmpfs.writeFile(expected ~ "\n"));

    string output = executeShell(cmd).output;
    output.skipOver!(x => x == '\n');
    return disableColor ? output.omitAnsiEscapes : output;
}

@safe
string omitAnsiEscapes(string s)
{
    import std.conv : to;
    import std.regex : regex, replaceAll;

    auto re = regex(`\x1b\[[0-9;]*m`, "g");
    return replaceAll(s, re, "");
}

@safe
unittest
{
    auto diff(string actual, string expected)
    {
        return diffWithTool(actual, expected, true, DiffTools.deltaPlainConfig);
    }

    assert(diff("", "") == "");
    assert(diff("a", "a") == "");
    assert(diff("a", "b") == "-a\n+b\n");
    assert(diff("a\nb", "a\nc") == " a\n-b\n+c\n");
    assert(diff("a\nb", "a\nc\nd") == " a\n-b\n+c\n+d\n");
    assert(diff("a\nb\nc\nd", "a\nk\nd") == " a\n-b\n-c\n+k\n d\n");
}
