// `DVN7`: containers whose child order the language does not care about.
//
// Sorting a block of imports is a diff of N removals and N additions, and it
// reads like a rewrite. Nothing changed: the grammar has a container there
// whose children commute. `DVN3` cannot see that on its own — its token
// streams differ, correctly, because the tokens really are in a different
// order.
//
// Whether an order is irrelevant is CONTEXT-DEPENDENT, and getting it wrong
// is not a cosmetic mistake: reordering D or C struct fields changes the
// layout and the ABI, while reordering imports is a refactor nobody needs to
// read. So commutativity is declared per language and per node kind
// (Mergiraf's `LangProfile` shape) rather than inferred, the defaults are the
// two cases that are unambiguous, and `--diff-commutative` is how a project
// says it has more.
module diff_commutative;

import sparkles.tree_sitter : nodeChild, nodeChildCount, nodeRange, nodeType,
    TSNode;

/// One declared commutative container: within `language`, a run of sibling
/// `node`s may be permuted without meaning changing.
///
/// The child kind alone is the key, not a (container, child) pair: a D
/// `import_declaration` commutes with its siblings whether they sit at module
/// scope or inside a function body, and naming every container that can hold
/// one would be a list to keep in sync with the grammar for no gain.
struct CommutativeKind
{
    const(char)[] language;
    const(char)[] node;
}

/// The conservative defaults. Both are cases where the language genuinely has
/// no opinion: D resolves imports as a set, and a markdown reference
/// definition is looked up by label from anywhere in the document.
///
/// Deliberately absent: struct/class members (layout and ABI), enum members
/// (values), function parameters (call sites), array literals. A project that
/// knows better about its own code adds kinds through `--diff-commutative`.
immutable CommutativeKind[] defaultCommutativeKinds = [
    CommutativeKind("d", "import_declaration"),
    CommutativeKind("markdown", "link_reference_definition"),
];

/// A line range (0-based rows, inclusive) a permutation was found in.
struct RowRange
{
    uint start;
    uint end;

    bool overlaps(uint first, uint last) const @safe pure nothrow @nogc
        => start <= last && end >= first;
}

/// Where the two sides' trees hold the same commutative children in a
/// different order.
struct Permutation
{
    RowRange oldRows;
    RowRange newRows;
}

/**
Finds the commutative containers whose children were only permuted.

A group qualifies when both sides hold the same multiset of children — keyed
by the child's text with whitespace runs collapsed, so a re-indented import
still matches itself — in a different order. Anything else (a member added,
one edited, the group counts disagreeing) is not a permutation and gets no
entry, which leaves it a real change.

Groups are paired between the sides by order of appearance. A shift caused by
an unrelated edit therefore compares the wrong pair — and that pair's
multisets will not match, so the answer degrades to "no claim" rather than to
a wrong one.
*/
Permutation[] findPermutations(TSNode oldRoot, scope const(char)[] oldText,
    TSNode newRoot, scope const(char)[] newText, const(char)[] language,
    scope const(CommutativeKind)[] kinds) @system
{
    if (language.length == 0)
        return null;
    auto a = collectGroups(oldRoot, oldText, language, kinds);
    auto b = collectGroups(newRoot, newText, language, kinds);
    if (a.length == 0 || a.length != b.length)
        return null;

    Permutation[] found;
    foreach (i, ref ga; a)
    {
        auto gb = b[i];
        if (ga.keys.length != gb.keys.length || ga.kind != gb.kind)
            continue;
        if (ga.keys == gb.keys)
            continue; // same order: not this pass's business
        if (!sameMultiset(ga.keys, gb.keys))
            continue; // something was added, removed or edited
        found ~= Permutation(ga.rows, gb.rows);
    }
    return found;
}

/// One run of sibling nodes of a commutative kind.
private struct Group
{
    const(char)[] kind;
    string[] keys;
    RowRange rows;
}

private Group[] collectGroups(TSNode root, scope const(char)[] source,
    const(char)[] language, scope const(CommutativeKind)[] kinds) @system
{
    // Nothing declared for this language: no walk at all.
    bool any;
    foreach (k; kinds)
        if (k.language == language)
        {
            any = true;
            break;
        }
    if (!any)
        return null;

    bool commutes(const(char)[] nodeKind) @safe pure nothrow @nogc
    {
        foreach (k; kinds)
            if (k.language == language && k.node == nodeKind)
                return true;
        return false;
    }

    enum maxDepth = 512;
    Group[] groups;
    TSNode[] stack = [root];
    while (stack.length != 0)
    {
        auto node = stack[$ - 1];
        --stack.length;
        const count = nodeChildCount(node);

        // A run of siblings of one commutative kind is a group; a different
        // kind in between closes it, because "these three moved past that
        // declaration" is not something this pass is entitled to call noise.
        Group open;
        foreach (i; 0 .. count)
        {
            auto child = nodeChild(node, i);
            const kind = nodeType(child);
            if (commutes(kind) && (open.keys.length == 0 || open.kind == kind))
            {
                const r = nodeRange(child);
                if (r.end_byte > source.length)
                    continue;
                if (open.keys.length == 0)
                {
                    open.kind = kind;
                    open.rows = RowRange(r.start_point.row, r.end_point.row);
                }
                else
                    open.rows.end = r.end_point.row;
                open.keys ~= normalizedText(source[r.start_byte .. r.end_byte]);
            }
            else
            {
                if (open.keys.length > 1)
                    groups ~= open;
                open = Group.init;
            }
            if (nodeChildCount(child) != 0 && stack.length < maxDepth)
                stack ~= child;
        }
        if (open.keys.length > 1)
            groups ~= open;
    }
    return groups;
}

/// Text with whitespace runs collapsed to one space and the ends trimmed — so
/// a re-indented or re-wrapped construct still matches itself, and `DVN7`
/// composes with `DVN1` rather than fighting it. Shared with `DVN6`, whose
/// block alignment wants exactly the same notion of "the same content".
string normalizedText(scope const(char)[] text) @safe pure nothrow
{
    char[] out_;
    bool pendingSpace, seen;
    foreach (c; text)
    {
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
        {
            pendingSpace = seen;
            continue;
        }
        if (pendingSpace)
            out_ ~= ' ';
        pendingSpace = false;
        seen = true;
        out_ ~= c;
    }
    return out_.idup;
}

private bool sameMultiset(in string[] a, in string[] b) @safe
{
    import std.algorithm.sorting : sort;

    if (a.length != b.length)
        return false;
    auto x = a.dup.sort.release;
    auto y = b.dup.sort.release;
    return x == y;
}

/**
Parses a `--diff-commutative` value into the kinds in force.

`off` declares nothing commutative. An empty value keeps
$(LREF defaultCommutativeKinds). Anything else is a comma-separated list of
`language:node` entries ADDED to the defaults — a project extends the policy
for its own code without having to restate what already works.
*/
CommutativeKind[] parseCommutativeKinds(const(char)[] spec, out bool ok) @safe
{
    import std.algorithm.iteration : splitter;
    import std.string : indexOf, strip;

    ok = true;
    if (spec == "off")
        return null;
    if (spec.length == 0 || spec == "default")
        return defaultCommutativeKinds.dup;

    auto kinds = defaultCommutativeKinds.dup;
    foreach (entry; spec.splitter(','))
    {
        const e = entry.strip;
        if (e.length == 0)
            continue;
        const colon = e.indexOf(':');
        if (colon <= 0 || colon + 1 >= e.length)
        {
            ok = false;
            continue;
        }
        kinds ~= CommutativeKind(e[0 .. colon].idup, e[colon + 1 .. $].idup);
    }
    return kinds;
}

// ── Tests ───────────────────────────────────────────────────────────────────

@("diff_commutative.parseCommutativeKinds")
@safe unittest
{
    bool ok;
    assert(parseCommutativeKinds("off", ok) is null && ok);
    assert(parseCommutativeKinds("", ok) == defaultCommutativeKinds && ok);
    assert(parseCommutativeKinds("default", ok) == defaultCommutativeKinds && ok);

    // Additions extend the defaults rather than replacing them.
    auto extended = parseCommutativeKinds("d:attribute_declaration", ok);
    assert(ok);
    assert(extended.length == defaultCommutativeKinds.length + 1);
    assert(extended[$ - 1] == CommutativeKind("d", "attribute_declaration"));

    // A malformed entry is reported, and the rest still parse.
    auto partial = parseCommutativeKinds("nonsense,ini:section", ok);
    assert(!ok);
    assert(partial[$ - 1] == CommutativeKind("ini", "section"));
}

@("diff_commutative.normalizedText.collapsesWhitespace")
@safe pure nothrow unittest
{
    assert(normalizedText("  import  std.stdio ;\n") == "import std.stdio ;");
    assert(normalizedText("import\n    std.stdio;") == "import std.stdio;");
}

@("diff_commutative.findPermutations.sortedImports")
@system unittest
{
    import sparkles.syntax.ts.registry : GrammarRegistry;
    import sparkles.test_runner.skip : skipTest;
    import sparkles.tree_sitter : ParseGuards, TsError, TsParser;
    import std.process : environment;

    if (environment.get("SPARKLES_TS_GRAMMAR_PATH", "").length == 0)
        skipTest("SPARKLES_TS_GRAMMAR_PATH not set (enter `nix develop`)");

    auto reg = GrammarRegistry.fromEnvironment();
    auto g = reg.grammar("d");
    assert(!g.hasError);
    auto parser = TsParser.create();
    parser.setLanguage(g.value.language);

    static struct Parsed { const(char)[] text; }
    TsError err;

    enum before = "module a;\nimport std.stdio;\nimport std.conv;\n"
        ~ "import std.file;\n";
    enum sorted = "module a;\nimport std.conv;\nimport std.file;\n"
        ~ "import std.stdio;\n";
    auto ta = parser.parse(before, err, ParseGuards());
    auto tb = parser.parse(sorted, err, ParseGuards());
    assert(ta.valid && tb.valid);

    auto perms = findPermutations(ta.rootNode, before, tb.rootNode, sorted,
        "d", defaultCommutativeKinds);
    assert(perms.length == 1, "the import block was permuted");
    assert(perms[0].oldRows == RowRange(1, 3));
    assert(perms[0].newRows == RowRange(1, 3));

    // One import ADDED is not a permutation, however the rest were sorted.
    enum added = "module a;\nimport std.array;\nimport std.conv;\n"
        ~ "import std.file;\nimport std.stdio;\n";
    auto tc = parser.parse(added, err, ParseGuards());
    assert(findPermutations(ta.rootNode, before, tc.rootNode, added, "d",
        defaultCommutativeKinds) is null, "an added member is a real change");

    // And a language with nothing declared never claims anything.
    assert(findPermutations(ta.rootNode, before, tb.rootNode, sorted, "d",
        null) is null);
}
