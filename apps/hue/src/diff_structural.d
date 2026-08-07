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
// The verdict comes at two granularities from the same pair of parses: the
// whole file (someone ran the formatter over it) and each hunk (someone
// reflowed one function while editing another). Both are conservative in the
// same direction — any doubt is "not equivalent", so a real change can never
// be dismissed as noise.
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

/// Whether to consult the grammar at all (decision 6: the pass auto-engages
/// when it is cheap, and `--diff-structural` is the override).
enum StructuralPolicy : ubyte
{
    /// Never parse — the text-level layers (`DVN1`/`DVN2`) stand alone.
    off,
    /// Parse when a grammar exists and both sides are under the size ceiling.
    automatic,
    /// Parse whenever a grammar exists, ceiling or not. For the case the
    /// ceiling exists for: a generated or vendored file large enough to trip
    /// it is exactly the one worth proving is noise.
    on,
}

/// Parses a `--diff-structural` spelling; `ok` is false for an unknown one,
/// so the caller can warn in its own voice.
StructuralPolicy parseStructuralPolicy(scope const(char)[] spelling,
    out bool ok) @safe pure nothrow @nogc
{
    ok = true;
    switch (spelling)
    {
        case "off":  return StructuralPolicy.off;
        case "auto": return StructuralPolicy.automatic;
        case "on":   return StructuralPolicy.on;
        default:
            ok = false;
            return StructuralPolicy.automatic;
    }
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
    Token[] a, b;
    return compareTokenStreams(cache, language, oldText, newText, a, b);
}

/// ditto, keeping the two token streams for a caller that wants to ask
/// narrower questions about the same parses (`structuralVerdicts`).
StructuralVerdict compareTokenStreams(ref TsConfigCache cache,
    const(char)[] language, scope const(char)[] oldText,
    scope const(char)[] newText, out Token[] oldTokens, out Token[] newTokens)
    @system
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

    if (!tokenize(oldTree.rootNode, oldText, oldTokens)
        || !tokenize(newTree.rootNode, newText, newTokens))
    {
        oldTokens = null;
        newTokens = null;
        return StructuralVerdict.unknown;
    }
    return tokensEqual(oldTokens, oldText, newTokens, newText)
        ? StructuralVerdict.equivalent : StructuralVerdict.differs;
}

/**
Per-hunk verdicts over one file pair, from the same two parses.

A whole-file verdict only reaches the case where the formatter touched
everything. The common review case is narrower: one function was reflowed
while another was edited, and the reflowed hunk deserves the same demotion
its file-wide cousin gets. `spans` are the hunks' unified-header coordinates
in document order; `verdicts` (same length) receives one verdict each.

A hunk's verdict compares the token subsequences **overlapping** its line
range on each side — overlapping, not starting inside, so a string or block
comment that begins above the hunk and changes within it still counts as a
difference. The return value is the whole-file verdict; on `unknown` every
per-hunk entry is `unknown` too, and a caller must treat both like `differs`.
*/
StructuralVerdict structuralVerdicts(ref TsConfigCache cache,
    const(char)[] language, scope const(char)[] oldText,
    scope const(char)[] newText, scope const(HunkSpan)[] spans,
    scope StructuralVerdict[] verdicts) @system
in (spans.length == verdicts.length)
{
    verdicts[] = StructuralVerdict.unknown;

    Token[] a, b;
    const file = compareTokenStreams(cache, language, oldText, newText, a, b);
    if (file == StructuralVerdict.unknown)
        return file;
    if (file == StructuralVerdict.equivalent)
    {
        // The grammar sees no change anywhere, so it sees none in any hunk.
        verdicts[] = StructuralVerdict.equivalent;
        return file;
    }

    foreach (i, span; spans)
    {
        const x = tokensInLines(a, span.oldStart, span.oldCount);
        const y = tokensInLines(b, span.newStart, span.newCount);
        verdicts[i] = tokensEqual(x, oldText, y, newText)
            ? StructuralVerdict.equivalent : StructuralVerdict.differs;
    }
    return file;
}

/// One hunk's unified-header coordinates (1-based first line and line count
/// per side) — `sparkles.diff.model.Hunk`'s first four fields, repeated here
/// so this module stays independent of the diff model.
struct HunkSpan
{
    uint oldStart;
    uint oldCount;
    uint newStart;
    uint newCount;
}

/// One leaf token: byte range into its side's source plus the rows it spans.
/// Positions rather than slices, so the sequence stays pointer-free.
struct Token
{
    uint start;
    uint end;
    uint startRow;
    uint endRow;

    const(char)[] text(return scope const(char)[] source)
        const @safe pure nothrow @nogc => source[start .. end];
}

/// Do the two token sequences carry the same texts in the same order?
private bool tokensEqual(scope const(Token)[] a, scope const(char)[] aSrc,
    scope const(Token)[] b, scope const(char)[] bSrc) @safe pure nothrow @nogc
{
    if (a.length != b.length)
        return false;
    foreach (i, t; a)
        if (t.text(aSrc) != b[i].text(bSrc))
            return false;
    return true;
}

/// The tokens overlapping `count` lines starting at 1-based `start`. Tokens
/// are position-ordered, so this is a bounded scan from a binary search
/// rather than a pass over the file.
private const(Token)[] tokensInLines(return scope const(Token)[] toks,
    uint start, uint count) @safe pure nothrow @nogc
{
    if (count == 0 || start == 0 || toks.length == 0)
        return toks[0 .. 0];
    const firstRow = start - 1;
    const lastRow = firstRow + count - 1;

    // Lower bound on `startRow`, then walk back over the multi-line tokens
    // that begin above the range but reach into it.
    size_t lo, hi = toks.length;
    while (lo < hi)
    {
        const mid = lo + (hi - lo) / 2;
        if (toks[mid].startRow < firstRow)
            lo = mid + 1;
        else
            hi = mid;
    }
    while (lo != 0 && toks[lo - 1].endRow >= firstRow)
        --lo;

    auto end = lo;
    while (end < toks.length && toks[end].startRow <= lastRow)
        ++end;
    return toks[lo .. end];
}

/// Collects a tree's leaves in document order. `false` means the walk hit its
/// guards (depth or token cap) and its result must not be trusted.
private bool tokenize(TSNode root, scope const(char)[] source,
    out Token[] tokens) @system
{
    auto walk = TokenWalk(root, source);
    Token t;
    while (walk.next(t))
    {
        if (tokens.length >= maxTokens)
            return false;
        tokens ~= t;
    }
    return !walk.overflowed;
}

/// A depth-first walk over a tree's leaves. An explicit stack rather than
/// recursion: the depth cap is then a property of the walker instead of the
/// C stack.
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

    /// The next leaf, or `false` when the walk is done.
    bool next(out Token token) @system
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
                if (r.end_byte > source.length || r.start_byte > r.end_byte)
                {
                    // A range outside the source: refuse to guess.
                    overflowed = true;
                    return false;
                }
                token = Token(r.start_byte, r.end_byte,
                    r.start_point.row, r.end_point.row);
                return true;
            }
            if (depth == maxDepth)
            {
                overflowed = true;
                return false;
            }
            stack[depth++] = Frame(child, 0, kids);
        }
        return false;
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

@("diff_structural.structuralVerdicts.perHunk")
@system unittest
{
    import sparkles.syntax : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    // Two functions: the first only reflowed, the second actually edited.
    // A whole-file verdict has to say `differs` and give up on both; the
    // per-hunk one demotes the reflow and keeps the edit.
    enum before =
        "int f(int a,int b)\n{\nreturn a+b;\n}\n\n"
        ~ "int g()\n{\n    return 1;\n}\n";
    enum after =
        "int f(int a, int b)\n{\n    return a + b;\n}\n\n"
        ~ "int g()\n{\n    return 2;\n}\n";

    const spans = [HunkSpan(1, 4, 1, 4), HunkSpan(6, 4, 6, 4)];
    auto verdicts = new StructuralVerdict[](spans.length);
    assert(structuralVerdicts(cache, "d", before, after, spans, verdicts)
        == StructuralVerdict.differs);
    assert(verdicts[0] == StructuralVerdict.equivalent);
    assert(verdicts[1] == StructuralVerdict.differs);

    // A file the grammar sees no change in at all stamps every hunk, without
    // consulting the line ranges.
    enum reflowed =
        "int f(int a, int b)\n{\n    return a + b;\n}\n\n"
        ~ "int g()\n{\n    return 1;\n}\n";
    assert(structuralVerdicts(cache, "d", before, reflowed, spans, verdicts)
        == StructuralVerdict.equivalent);
    assert(verdicts[0] == StructuralVerdict.equivalent);
    assert(verdicts[1] == StructuralVerdict.equivalent);

    // And no claim stays no claim, per hunk as well as per file.
    assert(structuralVerdicts(cache, "no-such-language", before, after, spans,
        verdicts) == StructuralVerdict.unknown);
    assert(verdicts[0] == StructuralVerdict.unknown);
    assert(verdicts[1] == StructuralVerdict.unknown);
}

@("diff_structural.structuralVerdicts.multiLineTokenReachingIntoAHunk")
@system unittest
{
    import sparkles.syntax : LabelSet;
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;

    if (!haveGrammars())
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto cache = TsConfigCache.create(&reg, LabelSet.standard());

    // The change is on line 3, inside a block comment that STARTS on line 1.
    // A token bucketed by its start row would land outside the hunk and the
    // hunk would read as noise; overlap semantics catch it.
    enum before = "/* one\n   two\n   three\n*/\nint x = 1;\n";
    enum after  = "/* one\n   two\n   THREE\n*/\nint x = 1;\n";
    const spans = [HunkSpan(3, 1, 3, 1)];
    auto verdicts = new StructuralVerdict[](spans.length);
    structuralVerdicts(cache, "d", before, after, spans, verdicts);
    assert(verdicts[0] == StructuralVerdict.differs);
}

@("diff_structural.parseStructuralPolicy")
@safe pure nothrow @nogc unittest
{
    bool ok;
    assert(parseStructuralPolicy("off", ok) == StructuralPolicy.off && ok);
    assert(parseStructuralPolicy("auto", ok) == StructuralPolicy.automatic && ok);
    assert(parseStructuralPolicy("on", ok) == StructuralPolicy.on && ok);
    assert(parseStructuralPolicy("yes", ok) == StructuralPolicy.automatic);
    assert(!ok);
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
