/**
The S2 spike: reconstruct a correctly $(B nested) group tree from the token
spine plus the AST oracle's sorted offset arrays — the AST itself is never
consulted at build time.

This is the seam the proposal names as its one genuinely novel combination
(no surveyed formatter pairs a token-spine input with a `Doc`-style nested
IR; see decision 1 in `docs/research/code-formatting/dmd-fmt-proposal.md`).
The experiment: drive nested groups for a function declaration with template
constraints and `in`/`out` contracts from three ingredients only —

$(LIST
    * $(B bracket matching) over the token stream, which recovers most
        nesting for free;
    * $(B oracle markers) ([sparkles.dmd_fmt.oracle]) consulted by binary
        search, which name the constructs bracket matching cannot: which
        identifier heads a declaration, which `if` is a template constraint,
        which `{` is a $(I block contract) rather than the function body (the
        "first `{` at declaration depth" heuristic fails exactly there), and
        which paren list is template parameters rather than a return type's;
    * $(B bounded token lookahead) from an anchor keyword to its matching
        closer, which converts a marker $(I inside) a construct (where DMD's
        locs point — see the oracle's findings) into the construct's extent.
        This is also the S4 answer for these constructs: end positions are
        recovered from the token stream, not stored by the oracle.
)

With an empty oracle (input that does not parse) the builder degrades to
bracket-only structure and never fails — the formatter's LSP posture.

Spike-grade by design: GC arrays, one linear pass, no `Doc` semantics yet
(`group`/`fill`/`indent` arrive in M2 — this proves the $(I shape) can be
built, which is what M2's engine needs as input).
*/
module sparkles.dmd_fmt.groups;

import sparkles.dmd_fmt.oracle : containsOffset, containsOffsetIn, StructuralFacts;
import sparkles.dmd_fmt.spine : SpineToken, TokenSpine;

import dmd.tokens : TOK;

/// What a reconstructed group is.
enum GroupKind : ubyte
{
    document,       /// the root; spans every entry
    brackets,       /// a `(…)`, `[…]` or `{…}` span — pure token nesting
    decl,           /// a function/template declaration (oracle-anchored)
    templateParams, /// the template parameter list of a `decl`
    runtimeParams,  /// the runtime parameter list of a `decl`
    constraint,     /// a template constraint `if (…)`
    inContract,     /// an `in (…)` / `in { … }` contract
    outContract,    /// an `out (…)` / `out (r) { … }` contract
    body_,          /// the function body braces
}

/// One node of the reconstructed tree. Leaf tokens are implicit: every spine
/// entry in `[firstEntry, lastEntry]` not covered by a child belongs to this
/// group directly.
struct Group
{
    GroupKind kind;
    /// Spine entry span of this group, inclusive.
    uint firstEntry, lastEntry;
    Group[] children;
}

/**
Build the group tree for `spine` guided by `facts`.

Never fails: unbalanced brackets close at end of input, and an empty oracle
yields bracket-only structure.
*/
// `const`, not `in`: the unittest build inherits `-preview=in`/`dip1000`
// from the test-runner shim's dflags (dub propagates dependency dflags), and
// the builder retains the spine's slices for its whole run — exactly what a
// `scope` parameter forbids.
Group buildGroups(const TokenSpine spine, const StructuralFacts facts) @safe
{
    auto builder = Builder(spine, facts);
    return builder.run();
}

private struct Builder
{
    const TokenSpine spine;
    const StructuralFacts facts;

    // One frame per group under construction. `closeAfterEntry` closes the
    // frame once that entry index has been processed (used by the clause
    // groups, whose extent is known up front via lookahead); brackets close
    // on their matching closer; a decl closes on a direct `;` or when its
    // body child closes.
    static struct Frame
    {
        Group group;
        size_t closeAfterEntry = size_t.max;
        // First entry of the current statement run directly in this frame —
        // where a retroactively-opened decl group starts (a decl marker
        // points at the declared identifier, so return type, attributes and
        // their bracket children before it must be adopted).
        uint boundary;
    }

    Frame[] stack;

    Group run() @safe
    {
        const entries = spine.entries;
        stack ~= Frame(Group(GroupKind.document, 0,
            entries.length ? cast(uint) entries.length - 1 : 0));

        for (size_t i = 0; i < entries.length; i++)
        {
            const t = entries[i];
            if (!t.isTrivia)
                processToken(i, t);
            // Close every frame whose predetermined extent ends here.
            while (stack.length > 1 &&
                stack[$ - 1].closeAfterEntry != size_t.max &&
                stack[$ - 1].closeAfterEntry <= i)
                popFrame(i);
        }

        // Broken input: close whatever is still open at end of input.
        while (stack.length > 1)
            popFrame(entries.length ? entries.length - 1 : 0);

        auto root = stack[0].group;
        labelParamLists(root);
        return root;
    }

    private void processToken(size_t i, in SpineToken t) @safe
    {
        switch (t.kind)
        {
            case TOK.leftParenthesis, TOK.leftBracket:
                pushFrame(GroupKind.brackets, i);
                break;

            case TOK.leftCurly:
                // The oracle is what tells the function body's `{` from a
                // block contract's — both sit at declaration depth.
                if (top.group.kind == GroupKind.decl &&
                    containsOffset(facts.bodyMarkers, t.start))
                    pushFrame(GroupKind.body_, i);
                else
                    pushFrame(GroupKind.brackets, i);
                break;

            case TOK.rightParenthesis, TOK.rightBracket, TOK.rightCurly:
                if (top.group.kind == GroupKind.brackets ||
                    top.group.kind == GroupKind.body_)
                    popFrame(i);
                // else: stray closer in broken input — leave it as a leaf.
                break;

            case TOK.semicolon:
                if (top.group.kind == GroupKind.decl)
                    popFrame(i); // a bodyless declaration ends here
                else
                    top.boundary = cast(uint) i + 1;
                break;

            case TOK.identifier:
                if (containsOffset(facts.declMarkers, t.start))
                    openDeclAt(i);
                break;

            case TOK.if_:
                openClause(i, GroupKind.constraint, facts.constraintMarkers,
                    /*maxSpans*/ 1);
                break;

            case TOK.in_:
                openClause(i, GroupKind.inContract, facts.inContractMarkers,
                    /*maxSpans*/ 1);
                break;

            case TOK.out_:
                // `out (r) { … }`: the identifier parens carry no marker; the
                // marker is in the brace span that follows.
                openClause(i, GroupKind.outContract, facts.outContractMarkers,
                    /*maxSpans*/ 2);
                break;

            default:
                break;
        }
    }

    /// Open a decl group retroactively: it starts at the current statement
    /// boundary of the enclosing frame and adopts any bracket children the
    /// parent accumulated since (a return type's `const(int)`, a UDA's
    /// `@(…)`).
    private void openDeclAt(size_t i) @trusted
    {
        auto parent = &stack[$ - 1];
        if (parent.group.kind == GroupKind.decl)
            return; // eponymous template: template and function share the marker

        const start = parent.boundary;
        Frame frame = Frame(Group(GroupKind.decl, start, cast(uint) i));
        frame.boundary = start;

        size_t firstAdopted = parent.group.children.length;
        while (firstAdopted > 0 &&
            parent.group.children[firstAdopted - 1].firstEntry >= start)
            firstAdopted--;
        frame.group.children = parent.group.children[firstAdopted .. $].dup;
        parent.group.children.length = firstAdopted;

        stack ~= frame;
    }

    /// Open a clause group (`if` constraint, `in`/`out` contract) at its
    /// keyword — but only when the oracle names this keyword as a clause.
    /// The marker sits either $(B at the keyword itself) (expression-form
    /// contracts: `frequires`/`fensures` statement locs) or $(B inside) one
    /// of the following bracket spans (constraints, whose loc is the top
    /// expression's operator; block-form contracts, whose loc is in the
    /// braces). Either way the clause's extent is the anchor-owning span —
    /// recovered by token lookahead, never stored. This is what separates a
    /// constraint from an `if` statement, and a contract keyword from
    /// anything else spelled `in`/`out`.
    private void openClause(size_t i, GroupKind kind, in uint[] markers,
        int maxSpans) @safe
    {
        if (top.group.kind != GroupKind.decl)
            return;

        const anchoredAtKeyword = containsOffset(markers, spine.entries[i].start);
        size_t j = nextNonTrivia(i + 1);
        foreach (span; 0 .. maxSpans)
        {
            if (j >= spine.entries.length || !isOpener(spine.entries[j].kind))
                return;
            const k = matchingCloser(j);
            if (anchoredAtKeyword || containsOffsetIn(markers,
                spine.entries[j].start, spine.entries[k].start))
            {
                auto frame = Frame(Group(kind, cast(uint) i, cast(uint) i));
                frame.closeAfterEntry = k;
                frame.boundary = cast(uint) i + 1;
                stack ~= frame;
                return;
            }
            j = nextNonTrivia(k + 1);
        }
    }

    private void pushFrame(GroupKind kind, size_t i) @safe
    {
        // The frame's content — and so its statement boundary for decl
        // adoption — starts after its opening token. (A defaulted boundary
        // of 0 once let a nested decl adopt siblings back to entry 0,
        // escaping its parent; the corpus test caught it.)
        auto frame = Frame(Group(kind, cast(uint) i, cast(uint) i));
        frame.boundary = cast(uint) i + 1;
        stack ~= frame;
    }

    private void popFrame(size_t i) @safe
    {
        auto frame = stack[$ - 1];
        stack.length--;
        frame.group.lastEntry = cast(uint) i;

        auto parent = &stack[$ - 1];
        parent.group.children ~= frame.group;
        // A completed non-bracket construct can never belong to a later
        // declaration; brackets can (`const(int) h(…)` — adopted on demand).
        if (frame.group.kind != GroupKind.brackets)
            parent.boundary = cast(uint) i + 1;

        // The body closing closes its declaration with it.
        if (frame.group.kind == GroupKind.body_ &&
            parent.group.kind == GroupKind.decl)
            parent.closeAfterEntry = i;
    }

    private ref Frame top() @trusted => stack[$ - 1];

    private size_t nextNonTrivia(size_t i) @safe pure nothrow @nogc
    {
        while (i < spine.entries.length && spine.entries[i].isTrivia)
            i++;
        return i;
    }

    /// Entry index of the closer matching the opener at `i` (or the last
    /// entry, for unbalanced input).
    private size_t matchingCloser(size_t i) @safe pure nothrow @nogc
    {
        int depth = 0;
        for (size_t j = i; j < spine.entries.length; j++)
        {
            const k = spine.entries[j].kind;
            if (isOpener(k))
                depth++;
            else if (isCloser(k) && --depth == 0)
                return j;
        }
        return spine.entries.length ? spine.entries.length - 1 : 0;
    }

    /// Label a decl's parameter-list parens: the bracket children after the
    /// decl's identifier and before any clause/body are the parameter lists —
    /// two for a template (oracle fact), one otherwise. Parens $(I before)
    /// the identifier (return types, UDAs) keep their bracket kind.
    private void labelParamLists(ref Group g) @safe
    {
        foreach (ref child; g.children)
            labelParamLists(child);
        if (g.kind != GroupKind.decl)
            return;

        const declEntry = declIdentifierEntry(g);
        if (declEntry == size_t.max)
            return;
        const isTemplate = containsOffset(facts.templateMarkers,
            spine.entries[declEntry].start);

        size_t seen = 0;
        foreach (ref child; g.children)
        {
            if (child.kind != GroupKind.brackets)
            {
                if (child.firstEntry > declEntry)
                    break; // clauses/body reached
                continue;
            }
            if (child.firstEntry < declEntry ||
                spine.entries[child.firstEntry].kind != TOK.leftParenthesis)
                continue;
            if (isTemplate && seen == 0)
                child.kind = GroupKind.templateParams;
            else if (seen == (isTemplate ? 1 : 0))
                child.kind = GroupKind.runtimeParams;
            else
                break;
            seen++;
        }
    }

    /// The entry index of the decl's marker identifier, or `size_t.max`.
    private size_t declIdentifierEntry(in Group g) @safe
    {
        foreach (i; g.firstEntry .. g.lastEntry + 1)
        {
            const t = spine.entries[i];
            if (t.kind == TOK.identifier && containsOffset(facts.declMarkers, t.start))
                return i;
        }
        return size_t.max;
    }
}

private bool isOpener(TOK k) @safe pure nothrow @nogc
    => k == TOK.leftParenthesis || k == TOK.leftBracket || k == TOK.leftCurly;

private bool isCloser(TOK k) @safe pure nothrow @nogc
    => k == TOK.rightParenthesis || k == TOK.rightBracket || k == TOK.rightCurly;

/**
Render the tree's shape as an s-expression — the golden format the S2 tests
compare (`(doc (decl (tparams) (params) (if (paren)) …))`). Structure only;
leaf tokens are elided.
*/
void writeSexpr(Writer)(in TokenSpine spine, in Group g, ref Writer w)
{
    w.put('(');
    w.put(label(spine, g));
    foreach (ref child; g.children)
    {
        w.put(' ');
        writeSexpr(spine, child, w);
    }
    w.put(')');
}

/// Convenience: [writeSexpr] into a string.
string sexpr(in TokenSpine spine, in Group g) @safe
{
    import std.array : appender;

    auto w = appender!string;
    writeSexpr(spine, g, w);
    return w[];
}

private string label(in TokenSpine spine, in Group g) @safe pure nothrow @nogc
{
    final switch (g.kind)
    {
        case GroupKind.document: return "doc";
        case GroupKind.decl: return "decl";
        case GroupKind.templateParams: return "tparams";
        case GroupKind.runtimeParams: return "params";
        case GroupKind.constraint: return "if";
        case GroupKind.inContract: return "in";
        case GroupKind.outContract: return "out";
        case GroupKind.body_: return "body";
        case GroupKind.brackets:
            switch (spine.entries[g.firstEntry].kind)
            {
                case TOK.leftBracket: return "bracket";
                case TOK.leftCurly: return "brace";
                default: return "paren";
            }
    }
}

version (unittest)
{
    import sparkles.dmd_fmt.oracle : collectFacts;
    import sparkles.dmd_fmt.spine : lexSpine;

    /// Lex + parse + build + render in one step.
    private string shapeOf(string source) @system
    {
        auto spine = lexSpine(source);
        auto facts = collectFacts(source);
        return sexpr(spine, buildGroups(spine, facts));
    }
}

@("groups.s2.function-template-with-constraint-and-contracts")
@system unittest
{
    // The proposal's S2 construct: template params, runtime params, a
    // constraint, expression-form in/out contracts, and a body containing an
    // `if` statement that must NOT read as a constraint.
    enum src = "auto transmogrify(T, U)(T input, U seed) @safe pure\n"
        ~ "if (isInputRange!T && is(U : int))\n"
        ~ "in (seed > 0)\n"
        ~ "out (r; r !is null)\n"
        ~ "{\n"
        ~ "    if (seed > 1) { return frob(input, seed); }\n"
        ~ "    return null;\n"
        ~ "}\n";
    const got = shapeOf(src);
    assert(got ==
        "(doc (decl (tparams) (params) (if (paren (paren))) (in (paren)) "
        ~ "(out (paren)) (body (paren) (brace (paren)))))", got);
}

@("groups.s2.block-contracts-do-not-close-the-decl")
@system unittest
{
    // The depth-0 `{` trap: both block contracts open braces at declaration
    // depth before the real body. Only the oracle's body marker may close
    // the decl.
    enum src = "int f(int x)\n"
        ~ "in { assert(x > 0); }\n"
        ~ "out (r) { assert(r > x); }\n"
        ~ "do\n"
        ~ "{\n"
        ~ "    return bar(x);\n"
        ~ "}\n";
    const got = shapeOf(src);
    assert(got ==
        "(doc (decl (params) (in (brace (paren))) (out (paren) (brace (paren))) "
        ~ "(body (paren))))", got);
}

@("groups.s2.return-type-parens-are-adopted-not-params")
@system unittest
{
    // The decl marker points at `h`, after const(int)'s parens: the decl
    // group must adopt them retroactively, and the labeler must not mistake
    // them for a parameter list.
    enum src = "const(int) h(int x)\n{\n    return x;\n}\n";
    const got = shapeOf(src);
    assert(got == "(doc (decl (paren) (params) (body)))", got);
}

@("groups.s2.bodyless-declaration-ends-at-semicolon")
@system unittest
{
    enum src = "void g(int x);\nint y;\n";
    const got = shapeOf(src);
    assert(got == "(doc (decl (params)))", got);
}

@("groups.s2.degraded-empty-oracle-yields-brackets-only")
@system unittest
{
    // The LSP posture: with no oracle at all the same input still builds a
    // well-formed, bracket-only tree.
    enum src = "auto transmogrify(T, U)(T input, U seed) @safe pure\n"
        ~ "if (isInputRange!T && is(U : int))\n"
        ~ "in (seed > 0)\n"
        ~ "out (r; r !is null)\n"
        ~ "{\n"
        ~ "    if (seed > 1) { return frob(input, seed); }\n"
        ~ "    return null;\n"
        ~ "}\n";
    auto spine = lexSpine(src);
    assert(sexpr(spine, buildGroups(spine, StructuralFacts.init)) ==
        "(doc (paren) (paren) (paren (paren)) (paren) (paren) "
        ~ "(brace (paren) (brace (paren))))");
}

@("groups.s2.broken-input-never-fails")
@system unittest
{
    enum src = "void f( {\n int x = ;\n";
    auto spine = lexSpine(src);
    auto facts = collectFacts(src);
    const shape = sexpr(spine, buildGroups(spine, facts));
    assert(shape.length >= "(doc)".length);
    assert(shape[0 .. 4] == "(doc");
}

/**
Check the tree's structural invariants: children lie within their parent's
span, in order, without overlap.

Returns: `null` when well-formed, else a description of the first violation.
*/
string validateGroups(const Group g) @safe
{
    import std.format : format;

    uint cursor = g.firstEntry;
    foreach (i, ref child; g.children)
    {
        if (child.firstEntry < g.firstEntry || child.lastEntry > g.lastEntry)
            return format!"child %s [%s..%s] escapes parent [%s..%s]"(
                i, child.firstEntry, child.lastEntry, g.firstEntry, g.lastEntry);
        if (child.firstEntry < cursor)
            return format!"child %s [%s..%s] overlaps its predecessor"(
                i, child.firstEntry, child.lastEntry);
        if (child.lastEntry < child.firstEntry)
            return format!"child %s has inverted span [%s..%s]"(
                i, child.firstEntry, child.lastEntry);
        if (const err = validateGroups(child))
            return err;
        cursor = child.lastEntry + 1;
    }
    return null;
}

@("groups.s2.corpus.builds-well-formed-trees")
@system unittest
{
    // The S2 corpus leg: every D source in the repo trees the spine corpus
    // covers must yield a well-formed group tree — oracle-guided where it
    // parses, brackets-only where it does not, never a crash.
    import core.exception : AssertError;
    import std.file : dirEntries, read, SpanMode;
    import std.path : buildPath, dirName;

    import sparkles.dmd_fmt.oracle : collectFacts;
    import sparkles.dmd_fmt.spine : lexSpine;

    enum thisDir = __FILE_FULL_PATH__.dirName;
    enum repoRoot = thisDir.dirName.dirName.dirName.dirName.dirName;
    static immutable corpusDirs = [
        "libs/base/src",
        "libs/dmd-fmt/src",
        "libs/dmd-lsp/src",
    ];

    size_t files, decls;
    foreach (dir; corpusDirs)
        foreach (entry; dirEntries(buildPath(repoRoot, dir), "*.d", SpanMode.depth))
        {
            const source = cast(string) read(entry.name);
            auto spine = lexSpine(source);
            auto facts = collectFacts(source);
            auto root = buildGroups(spine, facts);
            if (const err = validateGroups(root))
                throw new AssertError(entry.name ~ ": " ~ err);
            decls += countKind(root, GroupKind.decl);
            files++;
        }
    assert(files > 20, "corpus unexpectedly small — path resolution broke?");
    assert(decls > 100, "oracle found implausibly few declarations");
}

version (unittest)
private size_t countKind(const Group g, GroupKind kind) @safe pure nothrow
{
    size_t n = g.kind == kind ? 1 : 0;
    foreach (ref child; g.children)
        n += countKind(child, kind);
    return n;
}
