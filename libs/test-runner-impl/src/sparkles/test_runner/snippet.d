/**
 * Source-context rendering for caught test failures.
 *
 * The runner is linked into packages both as a prebuilt library and by source.
 * `sparkles:syntax` is an optional capability at compile-time: the prebuilt
 * impl library depends on it and provides full tree-sitter highlighting, while
 * runner-closure packages that source-include the impl without syntax fall back
 * to the source bytes unchanged.
 */
module sparkles.test_runner.snippet;

import sparkles.base.source_uri : resolveSourcePath;

/// Whether the host build makes the syntax engine available. The prebuilt
/// `sparkles:test-runner-impl` library depends on `sparkles:syntax` directly;
/// the guard remains only for packages in the runner's dependency closure
/// (e.g. `sparkles:base`) that source-include the runner modules directly.
private enum bool hasSyntax = __traits(compiles, {
    import sparkles.syntax : AnsiOptions, builtinDark, ColorDepth,
        GrammarRegistry, HighlightEvent, LabelSet, renderAnsi, resolveTheme,
        TsConfigCache, highlightInjected;
});

/**
Renders `context` lines either side of `line`, with a numbered gutter.

Unreadable files and out-of-range/zero locations yield an empty string: source
context is diagnostic help and must never obscure the original failure.
*/
string renderCodeSnippet(
    scope const(char)[] file,
    size_t line,
    bool colored,
    size_t context = 2,
) @safe
{
    import std.algorithm.comparison : min;
    import std.array : array;
    import std.conv : text;
    import std.file : exists, readText;
    import std.path : absolutePath;
    import std.range : repeat;
    import std.string : lineSplitter, stripRight;

    if (!file.length || line == 0)
        return null;

    string path;
    string source;
    try
    {
        path = resolveSourcePath(file.idup);
        if (!path.exists && file.exists)
            path = file.idup.absolutePath;
        source = path.readText;
    }
    catch (Exception)
        return null;

    auto lines = source.lineSplitter.array;
    if (line > lines.length)
        return null;

    const first = line > context ? line - context : 1;
    const last = line + min(context, lines.length - line);
    const numberWidth = text(last).length;

    string[] renderedLines;
    static if (hasSyntax)
    {
        if (colored)
        {
            string selected;
            foreach (lineNumber; first .. last + 1)
                selected ~= (lineNumber == first ? "" : "\n")
                    ~ lines[lineNumber - 1].stripRight("\r");

            string highlighted;
            try
                highlighted = (() @trusted => highlightD(selected))();
            catch (Exception)
                highlighted = null;
            if (highlighted.length)
                renderedLines = highlighted.lineSplitter.array;
        }
    }

    string result;
    foreach (lineNumber; first .. last + 1)
    {
        const number = text(lineNumber);
        const padding = repeat(' ', numberWidth - number.length).array;
        const code = renderedLines.length == last - first + 1
            ? renderedLines[lineNumber - first]
            : lines[lineNumber - 1].stripRight("\r");

        result ~= lineNumber == line
            ? colored
                ? "  \x1b[1;31m>\x1b[0m " ~ padding ~ number ~ " │ " ~ code ~ "\n"
                : "  > " ~ padding ~ number ~ " │ " ~ code ~ "\n"
            : "    " ~ padding ~ number ~ " │ " ~ code ~ "\n";
    }
    return result;
}

static if (hasSyntax)
{
    /// Tree-sitter's C boundary is `@system`; all owned inputs and outputs stay
    /// alive for the call, and the narrow trusted lambda above contains it.
    private string highlightD(string source) @system
    {
        import std.array : appender;
        import sparkles.syntax : AnsiOptions, builtinDark, ColorDepth,
            GrammarRegistry, HighlightEvent, LabelSet, renderAnsi, resolveTheme,
            TsConfigCache, highlightInjected;

        auto labels = LabelSet.standard();
        auto registry = GrammarRegistry.fromEnvironment();
        auto cache = TsConfigCache.create(&registry, labels);
        auto events = appender!(HighlightEvent[]);
        if (highlightInjected(cache, "d", source, events).hasError)
            return null;

        const theme = resolveTheme(builtinDark, labels);
        auto output = appender!string;
        renderAnsi(source, events.data, theme, output,
            AnsiOptions(depth: ColorDepth.ansi256));
        return output.data;
    }
}

@("snippet.renderCodeSnippet.gutterAndContext")
@system
unittest
{
    import std.file : remove, tempDir, write;
    import std.path : buildPath;
    import std.uuid : randomUUID;

    const path = buildPath(tempDir,
        "sparkles-test-runner-snippet-" ~ randomUUID.toString ~ ".d");
    scope (exit) remove(path);
    write(path, "one\ntwo\nassert(false);\nfour\nfive\nsix\n");

    assert(renderCodeSnippet(path, 3, false) ==
        "    1 │ one\n" ~
        "    2 │ two\n" ~
        "  > 3 │ assert(false);\n" ~
        "    4 │ four\n" ~
        "    5 │ five\n");
    assert(renderCodeSnippet(path, 1, false) ==
        "  > 1 │ one\n" ~
        "    2 │ two\n" ~
        "    3 │ assert(false);\n");

    import std.algorithm.searching : canFind;

    const colored = renderCodeSnippet(path, 3, true);
    static if (hasSyntax)
        assert(colored.canFind("\x1b["), colored);
    assert(renderCodeSnippet(path, 99, false) is null);
    assert(renderCodeSnippet(path ~ ".missing", 1, false) is null);
}
