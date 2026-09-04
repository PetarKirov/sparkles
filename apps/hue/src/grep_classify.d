/**
Does a grep hit look like a $(B definition) or a mention (`PKC14`)?

A byte heuristic, run during the scan where it must be nearly free. The
expensive answer — a tree-sitter parse — is affordable exactly once, on the
row the reader selects, from the parse the preview already performed. That
is Zoekt's principle: do the costly classification where it is affordable,
and let the cheap one rank.

The shape is fff's `classify.rs`; the content deliberately is not. fff's is
a self-described POC that scans for a keyword anywhere on the line and never
checks that the $(B match) falls inside the identifier that keyword
introduces — so searching `Foo` marks `struct Bar { Foo x; }` a definition
of `Foo`. This one requires the overlap, which is the difference between a
signal and a coin flip.

Language-agnostic on purpose: the keyword set is the union across the
languages hue highlights, and a false positive costs a ranking nudge rather
than a wrong answer. `PKC13` uses it as one term in a composite, never as a
filter.
*/
module grep_classify;

/// What a hit's line looks like.
enum HitKind : ubyte
{
    /// A use of the name.
    mention,
    /// A declaration or definition OF the name that matched.
    definition,
}

/**
Keywords that introduce a name, across the languages hue highlights.

Union rather than per-language because the scan has no language in hand —
it has bytes and a path — and because the cost of a wrong guess is a
ranking term, not a filter.
*/
private immutable string[] introducers = [
    // D, C, C++, C#, Java, Rust, Go, Swift, Zig, Kotlin, TypeScript…
    "struct", "class", "enum", "union", "interface", "trait", "impl",
    "protocol", "extension", "actor", "record", "template", "typedef",
    "namespace", "module", "package", "alias", "type", "using",
    // callables
    "fn", "func", "function", "def", "proc", "sub", "method", "constructor",
    // bindings that commonly introduce a top-level name
    "const", "let", "var", "val", "static", "data", "newtype", "object",
];

/// Modifiers that may precede the introducer without changing the shape.
private immutable string[] modifiers = [
    "public", "private", "protected", "internal", "package", "pub",
    "export", "extern", "static", "final", "abstract", "override",
    "virtual", "inline", "async", "unsafe", "const", "mut", "readonly",
    "shared", "immutable", "deprecated", "partial", "sealed", "open",
    "declare", "default", "lateinit", "operator", "suspend",
];

private bool isIdentByte(char c) @safe pure nothrow @nogc
    => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
        || (c >= '0' && c <= '9') || c == '_' || c == '$';

/// The next identifier word after `from`, or empty when none follows on
/// this line before a non-identifier, non-space byte.
private const(char)[] peekWord(return scope const(char)[] line, size_t from)
    @safe pure nothrow @nogc
{
    size_t i = from;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        ++i;
    const start = i;
    while (i < line.length && isIdentByte(line[i]))
        ++i;
    return line[start .. i];
}

private bool contains(scope const(string)[] set, scope const(char)[] word)
    @safe pure nothrow @nogc
{
    foreach (w; set)
        if (w.length == word.length && w == word)
            return true;
    return false;
}

/**
Classify one line (`PKC14`).

`matchStart`/`matchLen` are byte offsets $(B within `line`). The line is
read as: optional whitespace, zero or more modifiers, an introducer, then
the introduced name. The hit is a definition only when it $(B overlaps that
name) — the check fff's version omits.

A leading `#`, `//`, `--` or `*` short-circuits to `mention`: a keyword
inside a comment or a preprocessor line introduces nothing.
*/
HitKind classifyLine(scope const(char)[] line, size_t matchStart,
    size_t matchLen) @safe pure nothrow @nogc
{
    size_t i;
    while (i < line.length && (line[i] == ' ' || line[i] == '\t'))
        ++i;
    if (i >= line.length)
        return HitKind.mention;

    // Comments and preprocessor lines introduce nothing.
    if (line[i] == '#' || line[i] == '*')
        return HitKind.mention;
    if (i + 1 < line.length
        && ((line[i] == '/' && (line[i + 1] == '/' || line[i + 1] == '*'))
            || (line[i] == '-' && line[i + 1] == '-')))
        return HitKind.mention;

    // Walk words until an introducer is found, allowing modifiers before it.
    bool sawIntroducer;
    while (i < line.length)
    {
        while (i < line.length && !isIdentByte(line[i]))
        {
            // Only whitespace may separate the modifier/introducer chain; a
            // `(` or `=` means the shape has ended.
            if (line[i] != ' ' && line[i] != '\t')
                return HitKind.mention;
            ++i;
        }
        const wordStart = i;
        while (i < line.length && isIdentByte(line[i]))
            ++i;
        if (wordStart == i)
            return HitKind.mention;
        const word = line[wordStart .. i];

        if (sawIntroducer)
        {
            // `word` is the introduced name. The hit counts only if it
            // overlaps — this is the check that separates a definition of
            // the matched name from a definition that merely mentions it.
            const matchEnd = matchStart + matchLen;
            return matchStart < i && matchEnd > wordStart
                ? HitKind.definition : HitKind.mention;
        }
        const introduces = contains(introducers, word);
        const modifies = contains(modifiers, word);

        // `static`, `const` and `package` are in BOTH sets — `static class
        // Widget` uses one as a modifier, `const MAX = 10` uses the same
        // word as the introducer. One word of lookahead settles it: if what
        // follows continues the chain, this word was a modifier.
        if (introduces && modifies)
        {
            const ahead = peekWord(line, i);
            if (ahead.length && (contains(introducers, ahead)
                    || contains(modifiers, ahead)))
                continue; // a modifier; the real introducer is next
            sawIntroducer = true;
            continue;
        }
        if (introduces)
        {
            sawIntroducer = true;
            continue;
        }
        if (modifies)
            continue;
        return HitKind.mention; // an ordinary statement
    }
    return HitKind.mention;
}

@("grep_classify.theMatchMustBeTheIntroducedName")
@safe pure nothrow @nogc
unittest
{
    // The check fff's classifier omits, and the reason this one is a signal
    // rather than a coin flip. Both lines contain `struct` AND `Foo`; only
    // the first defines `Foo`.
    static HitKind of(string line, string needle) @safe pure nothrow @nogc
    {
        size_t at = size_t.max;
        foreach (i; 0 .. line.length - needle.length + 1)
            if (line[i .. i + needle.length] == needle)
            {
                at = i;
                break;
            }
        return at == size_t.max ? HitKind.mention
            : classifyLine(line, at, needle.length);
    }

    assert(of("struct Foo", "Foo") == HitKind.definition);
    assert(of("struct Bar { Foo x; }", "Foo") == HitKind.mention,
        "a definition of something ELSE that mentions the name");

    // Modifiers before the introducer do not change the shape.
    assert(of("    public static class Widget : Base", "Widget")
        == HitKind.definition);
    assert(of("pub fn parse(input: &str)", "parse") == HitKind.definition);
    assert(of("private void helper()", "helper") == HitKind.mention,
        "`void` is not an introducer, so this shape is not recognised");

    // The introducer itself is not the introduced name.
    assert(of("struct Foo", "struct") == HitKind.mention,
        "matching the KEYWORD is not defining anything");
}

@("grep_classify.ordinaryLinesAndCommentsAreMentions")
@safe pure nothrow @nogc
unittest
{
    static HitKind of(string line, size_t at, size_t len)
        @safe pure nothrow @nogc => classifyLine(line, at, len);

    // A call, an assignment, an import — all mentions.
    assert(of("    auto x = parse(input);", 13, 5) == HitKind.mention);
    assert(of("import parse;", 7, 5) == HitKind.mention,
        "`import` is not in the introducer set");
    assert(of("foo.parse();", 4, 5) == HitKind.mention);

    // A keyword inside a comment introduces nothing.
    assert(of("// struct Foo is defined elsewhere", 10, 3) == HitKind.mention);
    assert(of("/* struct Foo */", 10, 3) == HitKind.mention);
    assert(of("   * struct Foo", 12, 3) == HitKind.mention, "ddoc body");
    assert(of("-- type Foo", 8, 3) == HitKind.mention, "SQL/Haskell comment");
    assert(of("#define Foo 1", 8, 3) == HitKind.mention, "preprocessor");

    // Degenerate input must not reach past the end.
    assert(of("", 0, 0) == HitKind.mention);
    assert(of("   ", 0, 0) == HitKind.mention);
    assert(of("struct", 0, 6) == HitKind.mention, "no name follows");
}

@("grep_classify.aDefinitionOutranksAMention")
@safe pure nothrow @nogc
unittest
{
    // `PKC13`: the term is a nudge in a composite, never a filter — a false
    // positive costs a place in the order, not a missing row.
    import picker_grep : grepScore;

    const def = grepScore(HitKind.definition);
    const use = grepScore(HitKind.mention);
    assert(def.total > use.total, "a definition ranks above a mention");
    assert(use.total > 0, "but a mention still ranks — it is not filtered out");
    assert(use.definition == 0);
    assert(def.base == use.base, "the base is flat: a literal match is exact");
}
