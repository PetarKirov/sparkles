/**
`FXL8`: the tree-sitter grammar `fileset` is the D parser's. Over the corpus
below, valid and invalid, the grammar's tree has an error exactly when the
parser fails, and on every byte of every token of a query that parses, its
highlight capture is the parser's token kind.

Needs the grammar bundle (`$SPARKLES_TS_GRAMMAR_PATH`); skipped without it.
*/
module grammar_test;

import std.algorithm.searching : startsWith;
import std.array : appender;
import std.conv : text;

import sparkles.build_primitives.fileset.query : parseQuery, TokenKind;
import sparkles.syntax.event : HighlightEvent;
import sparkles.syntax.label : LabelSet;
import sparkles.syntax.ts.highlighter : highlightInjected, ParsedLayer;
import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.syntax.ts.registry : GrammarRegistry;

/// Queries the grammar and the parser must agree on.
immutable string[] corpus = [
    "a",
    "src/**/*.d - **/*_test.d",
    "a | b & c - d",
    "(a | b) & (c - d)",
    "a-b/*.d | -x",
    "*.{d,di} | {a,{b,c}}/x",
    "\"#foo#\" | \"a b\" | \"say \\\"hi\\\"\"",
    "a#b # comment\n| c",
    "# only a comment",
    "",
    "all - gitignored | exec & none | gitTracked",
    "unions(a, b, c) & intersection(d, e) - difference(f, g)",
    "unions(unions(a), (b | c))",
    "fileFilter(hasExt(\"d\") && !name == \"x.d\" || type == \"symlink\")",
    "fileFilter(!(hasExt(\"d\") || name == \"README.md\"))",
    "name | type | hasExt", // outside fileFilter these are globs
    // invalid
    "(a | b",
    "a |",
    "| a",
    "a b",
    "unions()",
    "fileFilter(a)",
    "fileFilter(name \"x\")",
    "\"open",
    "a)",
];

private TokenKind kindOfLabel(const(char)[] name)
{
    if (name.startsWith("string.special"))
        return TokenKind.glob;
    if (name.startsWith("string"))
        return TokenKind.string_;
    if (name.startsWith("constant"))
        return TokenKind.keyword;
    if (name.startsWith("function"))
        return TokenKind.function_;
    if (name.startsWith("property") || name.startsWith("variable"))
        return TokenKind.predicate;
    if (name.startsWith("comment"))
        return TokenKind.comment;
    if (name.startsWith("operator"))
        return TokenKind.operator;
    if (name.startsWith("punctuation"))
        return TokenKind.punctuation;
    assert(0, "an unexpected capture: " ~ name);
}

@("fileset_explorer.FXL8.grammarIsTheParser")
@system unittest
{
    import std.process : environment;
    import sparkles.test_runner.skip : skipTest;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        return skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    static GrammarRegistry registry;
    registry = GrammarRegistry.fromEnvironment();
    const labels = LabelSet.standard();
    auto cache = TsConfigCache.create(&registry, labels);

    foreach (source; corpus)
    {
        const q = parseQuery(source);
        auto sink = appender!(HighlightEvent[]);
        ParsedLayer*[] layers;
        const r = highlightInjected(cache, "fileset", source, sink, layers);
        assert(!r.hasError, "the fileset grammar did not load: " ~ source);
        assert(layers.length && layers[0].tree.rootHasError == !q.ok,
            text("`", source, "`: the parser says ", q.ok ? "ok" : q.error.message,
                ", the grammar ", layers[0].tree.rootHasError ? "has an error" : "does not"));
        if (!q.ok)
            continue;

        // The capture over each byte, innermost first.
        auto byteKind = new int[](source.length);
        byteKind[] = -1;
        const(char)[][] stack;
        foreach (e; sink[])
            final switch (e.kind)
            {
                case HighlightEvent.Kind.push: stack ~= labels.name(e.label); break;
                case HighlightEvent.Kind.pop: stack = stack[0 .. $ - 1]; break;
                case HighlightEvent.Kind.source:
                    if (stack.length)
                        foreach (i; e.start .. e.end)
                            byteKind[i] = kindOfLabel(stack[$ - 1]);
                    break;
            }
        foreach (ref t; q.tokens)
            foreach (i; t.span.start .. t.span.end)
                assert(byteKind[i] == t.kind, text("`", source, "` byte ", i, " (`", source[t.span.start .. t.span.end],
                    "`): the parser says ", t.kind, ", the grammar ",
                    byteKind[i] < 0 ? "nothing" : text(cast(TokenKind) byteKind[i])));
    }
}
