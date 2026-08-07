// The structural noise oracle (`DVN3`, first cut): does the grammar see any
// difference between two versions of a file?
//
// `DVN1` asks the question with a whitespace policy and `DVN2` with a
// text-level verdict; both reason about bytes. This asks the parser. Two
// sides whose TOKEN STREAMS are identical differ only in things the language
// does not have an opinion about — indentation, line breaks inside an
// expression, alignment padding, a trailing comma's surrounding space. That
// is a strictly stronger statement than "the same after collapsing runs of
// spaces", and it costs one parse per side.
//
// Why here and not in `sparkles:diff`: the engine is deliberately
// tree-sitter-free (diff-view.md decision 5), and the structural pass lives
// where `sparkles:syntax` already is. This module is that seam.
//
// What this first cut deliberately does NOT do: per-hunk verdicts, or the
// node-level alignment of an opt-in structural VIEW. It answers one question
// about a whole file, which is the shape the common case takes — someone ran
// the formatter — and it answers it conservatively: any doubt is "not
// equivalent", so a real change can never be dismissed as noise.
module diff_structural;

import sparkles.syntax.ts.injection : TsConfigCache;
import sparkles.tree_sitter : nodeChild, nodeChildCount, nodeRange,
    ParseGuards, TsError, TsParser, TSNode;

/// A cap on the tokens compared per side (`DVM6`'s family): past this the
/// oracle declines rather than walking a pathological tree. Chosen so a
/// 10k-line source file fits comfortably.
enum size_t maxTokens = 200_000;

/// The verdict. `unknown` is not a failure — it is "no grammar, too big, or a
/// parse that did not succeed", and every caller must treat it exactly like
/// `differs`: no claim, no demotion.
enum StructuralVerdict : ubyte
{
    /// The oracle could not answer (no grammar, guard tripped, parse failed).
    unknown,
    /// The token streams are identical — the grammar sees no change.
    equivalent,
    /// The token streams differ somewhere.
    differs,
}

/**
Compares the two sides' token streams under `language`'s grammar.

Returns $(D StructuralVerdict.equivalent) only when both sides parse and
produce exactly the same sequence of leaf token texts. Anything else — a
missing grammar, a parse error, a token cap trip, one differing token — is
`unknown` or `differs`, and neither licenses calling a change noise.

Comments are tokens in the grammars we ship, so an edited comment is a real
change here. That is the right default for a review tool: a comment is where
the intent lives.
*/
StructuralVerdict compareTokenStreams(ref TsConfigCache cache,
    const(char)[] language, scope const(char)[] oldText,
    scope const(char)[] newText) @system
{
    if (language.length == 0 || oldText.length == 0 || newText.length == 0)
        return StructuralVerdict.unknown;
    // Identical bytes are not this pass's business — the differ would not
    // have produced a hunk, and answering `equivalent` would invite callers
    // to skip work they still need to do.
    if (oldText == newText)
        return StructuralVerdict.equivalent;

    // Through the registry rather than the resolved highlight config: the
    // config's grammar handle is package-private to `sparkles:syntax`, and
    // this pass wants the language itself, not a highlight query.
    auto g = cache.registry.grammar(language);
    if (g.hasError)
        return StructuralVerdict.unknown;

    auto parser = TsParser.create();
    if (parser.setLanguage(g.value.language).hasError)
        return StructuralVerdict.unknown;

    TsError err;
    auto oldTree = parser.parse(oldText, err, ParseGuards());
    if (!oldTree.valid)
        return StructuralVerdict.unknown;
    auto newTree = parser.parse(newText, err, ParseGuards());
    if (!newTree.valid)
        return StructuralVerdict.unknown;

    // Walk both leaf sequences in lockstep rather than materializing them:
    // the answer is almost always "differs", and the first mismatch ends it.
    auto a = TokenWalk(oldTree.rootNode, oldText);
    auto b = TokenWalk(newTree.rootNode, newText);
    size_t seen;
    for (;;)
    {
        const x = a.next();
        const y = b.next();
        if (a.overflowed || b.overflowed || ++seen > maxTokens)
            return StructuralVerdict.unknown;
        if (x is null || y is null)
            return x is null && y is null
                ? StructuralVerdict.equivalent : StructuralVerdict.differs;
        if (x != y)
            return StructuralVerdict.differs;
    }
}

/// A depth-first walk over a tree's leaves, yielding each token's source text.
/// An explicit stack rather than recursion: the depth cap is then a property
/// of the walker instead of the C stack.
private struct TokenWalk
{
    private enum maxDepth = 512;

    private static struct Frame
    {
        TSNode node;
        uint next;
        uint count;
    }

    private Frame[maxDepth] stack;
    private size_t depth;
    private const(char)[] source;
    /// The tree was deeper than `maxDepth`, so the walk is incomplete and its
    /// result must not be trusted.
    bool overflowed;

    this(TSNode root, scope return const(char)[] src) @system
    {
        source = src;
        stack[0] = Frame(root, 0, nodeChildCount(root));
        depth = 1;
    }

    /// The next leaf's text, or `null` when the walk is done.
    const(char)[] next() @system
    {
        while (depth != 0)
        {
            auto f = &stack[depth - 1];
            if (f.next >= f.count)
            {
                --depth;
                continue;
            }
            auto child = nodeChild(f.node, f.next++);
            const kids = nodeChildCount(child);
            if (kids == 0)
            {
                const r = nodeRange(child);
                if (r.end_byte <= source.length && r.start_byte <= r.end_byte)
                    return source[r.start_byte .. r.end_byte];
                return null; // a range outside the source: refuse to guess
            }
            if (depth == maxDepth)
            {
                overflowed = true;
                return null;
            }
            stack[depth++] = Frame(child, 0, kids);
        }
        return null;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

private bool haveGrammars() @safe
{
    import std.process : environment;

    return environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length != 0;
}

@("diff_structural.compareTokenStreams.formattingIsInvisibleToTheGrammar")
@system unittest
{
    import sparkles.syntax : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    // Re-indentation, a line break moved, alignment padding: the parser sees
    // none of it. This is the case `DVN1` needs a policy for and `DVN2` can
    // only reach by collapsing runs.
    enum before = "int f(int a,int b)\n{\n\treturn a+b;\n}\n";
    enum after  = "int f(int a, int b)\n{\n    return a + b;\n}\n";
    assert(compareTokenStreams(cache, "d", before, after)
        == StructuralVerdict.equivalent);

    // A joined line is still the same tokens.
    enum joined = "int f(int a, int b) { return a + b; }\n";
    assert(compareTokenStreams(cache, "d", after, joined)
        == StructuralVerdict.equivalent);

    // But a real edit is a real edit, however it is spaced.
    enum edited = "int f(int a, int b)\n{\n    return a - b;\n}\n";
    assert(compareTokenStreams(cache, "d", after, edited)
        == StructuralVerdict.differs);

    // And so is a renamed identifier, which no whitespace policy would catch.
    enum renamed = "int f(int a, int c)\n{\n    return a + b;\n}\n";
    assert(compareTokenStreams(cache, "d", after, renamed)
        == StructuralVerdict.differs);
}

@("diff_structural.compareTokenStreams.commentsAreRealChanges")
@system unittest
{
    import sparkles.syntax : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    // A comment is a token in the grammars we ship, so editing one is a
    // change — the right default for a review tool, where the comment is
    // often where the intent lives.
    enum a = "// explains why\nint x = 1;\n";
    enum b = "// explains why not\nint x = 1;\n";
    assert(compareTokenStreams(cache, "d", a, b) == StructuralVerdict.differs);
}

@("diff_structural.compareTokenStreams.declinesRatherThanGuessing")
@system unittest
{
    import sparkles.syntax : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    // No grammar for the language, or nothing to compare: `unknown`, which
    // every caller must treat exactly like `differs`.
    assert(compareTokenStreams(cache, "no-such-language", "a\n", "b\n")
        == StructuralVerdict.unknown);
    assert(compareTokenStreams(cache, "", "a\n", "b\n")
        == StructuralVerdict.unknown);
    assert(compareTokenStreams(cache, "d", "", "x\n")
        == StructuralVerdict.unknown);

    // Identical input is equivalent without consulting the grammar at all.
    assert(compareTokenStreams(cache, "d", "int x;\n", "int x;\n")
        == StructuralVerdict.equivalent);
}
