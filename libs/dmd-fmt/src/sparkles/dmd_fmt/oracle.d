/**
The AST oracle — sorted offset arrays of structural facts, dfmt's
`ASTInformation` shape on the DMD parse tree.

This module is the proposal's M0-S2/S4 spike grown into the seed of M3: parse
once (never `fullSemantic`), walk the parse tree with a transitive visitor,
reduce it to flat arrays of byte offsets, and $(B never consult the AST
again) — the group builder ([sparkles.dmd_fmt.groups]) works from the token
spine plus these arrays alone.

Loc-semantics findings this spike pins (each exercised by a unittest here or
in `groups.d`; these are the S4 facts for the constructs covered so far):

$(LIST
    * `Loc.fileOffset()` is populated at parse time for every node kind the
        oracle records (declarations, constraint expressions, contract
        statements, function bodies).
    * A `TemplateDeclaration`'s / `FuncDeclaration`'s `loc` points at the
        declared $(B identifier), not at the first token of the declaration
        (`auto`, the return type, or an attribute). An oracle anchor is
        therefore "somewhere inside the declaration's first line", and the
        group builder must treat it as a marker to associate with the
        enclosing token run, not as the group's first byte.
    * A template constraint's `constraint.loc` points $(B inside) the
        `if (…)` — at the top expression's operator (`&&` for a conjunction),
        not at `if` or `(` — so the builder anchors constraint groups at the
        `if` $(I keyword) token and verifies the oracle marker falls within
        the keyword's following paren span.
    * Contract locs depend on the contract's $(B form): the expression forms
        (`in (…)`, `out (r; …)`) carry the loc of the $(B keyword itself)
        (`frequires[i].loc` / `fensures[i].ensure.loc`); the block forms
        (`in { … }`, `out (r) { … }`) carry a loc $(B inside the braces). The
        builder accepts either anchor and recovers the extent by token
        lookahead.
    * `fbody.loc` points at the body's `{` (or the single statement), which
        is what lets the builder tell a $(B block contract's) `{` from the
        function body's — the "first `{` at declaration depth" heuristic is
        wrong exactly there.
    * The synthesized `TemplateDeclaration` wrapping an $(B eponymous)
        function template carries `Loc.initial` — and `Loc.fileOffset()` on an
        invalid Loc $(B underflows) dmd's global file table instead of failing
        cleanly (an upstream library sharp edge; every fileOffset call in this
        module is `isValid`-guarded). The declaration anchor is taken from the
        member function instead, which also supplies template identity.
    * `SemanticTimeTransitiveVisitor.visitEponymousMember` short-circuits the
        eponymous member through `visitFuncBody`, so the virtual
        `visit(FuncDeclaration)` $(B never fires) for an eponymous function
        template — its facts must be recorded from `visit(TemplateDeclaration)`.
)

Like the spine, the oracle serializes on the process-wide DMD lock and
initializes DMD's globals on first use (`initDMD`, parse-only parameters).
*/
module sparkles.dmd_fmt.oracle;

import sparkles.dmd_fmt.spine : dmdGlobalsLock;

/**
Structural facts as sorted byte-offset arrays, queried by binary search.

An empty instance (`parsed == false` or all arrays empty) is a valid oracle:
the group builder then produces bracket-only structure — the degraded path a
formatter takes on input that does not parse.
*/
struct StructuralFacts
{
    /// `loc` of each function/template declaration (points at the declared
    /// identifier — see the module doc).
    uint[] declMarkers;
    /// The subset of [declMarkers] that are `TemplateDeclaration`s — the fact
    /// that lets the builder read `foo(T)(T a)` as tparams+params while
    /// `const(int) h(int x)` keeps one param list (brackets alone cannot
    /// tell those apart; this is oracle work by necessity).
    uint[] templateMarkers;
    /// `constraint.loc` of each template constraint (inside the `if (…)`).
    uint[] constraintMarkers;
    /// `frequires[i].loc` of each `in` contract (inside its parens/braces).
    uint[] inContractMarkers;
    /// `fensures[i].ensure.loc` of each `out` contract (inside parens/braces).
    uint[] outContractMarkers;
    /// `fbody.loc` of each function body (its `{`, or the lone statement).
    uint[] bodyMarkers;
    /// Whether the parse completed without errors. Facts collected from an
    /// erroneous parse are still usable — they cover whatever did parse.
    bool parsed;
}

/// Whether sorted `haystack` contains `needle` (binary search).
bool containsOffset(scope const uint[] haystack, uint needle) @safe pure nothrow @nogc
{
    import std.range : assumeSorted;

    return haystack.assumeSorted.contains(needle);
}

/// Whether sorted `haystack` has any element in `[lo, hi]` (inclusive).
bool containsOffsetIn(scope const uint[] haystack, uint lo, uint hi) @safe pure nothrow @nogc
{
    import std.range : assumeSorted;

    auto upper = haystack.assumeSorted.upperBound(hi);
    const belowOrIn = haystack.length - upper.length;
    auto lower = haystack.assumeSorted.lowerBound(lo);
    return belowOrIn > lower.length;
}

/**
Parse `source` and reduce the parse tree to [StructuralFacts].

Parse only — no semantic analysis, no import resolution. Diagnostics are
swallowed (a formatter's oracle degrades on broken input; it does not
report).
*/
StructuralFacts collectFacts(const(char)[] source) @system
{
    synchronized (dmdGlobalsLock)
    {
        ensureFrontendGlobals();
        return collectFactsImpl(source);
    }
}

private __gshared bool frontendGlobalsReady;

// Parse needs the full frontend global state (Type._init, target, Module
// machinery …), which initDMD sets up. The diagnostic handler swallows
// everything: the oracle's contract on broken input is "return what parsed",
// not "report". initDMD also runs Id.initialize, so the spine's lexer-state
// guarantee is subsumed once the oracle has run.
//
// `package`: the S4 loc-inventory tests parse through the same globals.
package void ensureFrontendGlobals() @system
{
    if (frontendGlobalsReady)
        return;
    import dmd.frontend : initDMD;
    import dmd.globals : global;

    initDMD((const ref loc, headerColor, header, messageFormat, args, p1, p2)
        nothrow => true);
    // S4 finding: without this flag the parser stores a unittest body as
    // raw tokens (fbody is null), so every declaration, contract and
    // statement inside one is invisible to the oracle and the region
    // degrades to bracket-only structure. A formatter must see unittest
    // bodies; parse-only use has no codegen cost.
    global.params.useUnitTests = true;
    frontendGlobalsReady = true;
}

private StructuralFacts collectFactsImpl(const(char)[] source) @system
{
    import std.algorithm.sorting : sort;

    import dmd.frontend : parseModule;
    import dmd.globals : global;

    const errorsBefore = global.errors;
    auto parsed = parseModule("dmd_fmt_oracle.d", source);

    StructuralFacts facts;
    facts.parsed = parsed.module_ !is null && global.errors == errorsBefore;
    if (parsed.module_ is null)
        return facts;

    scope visitor = new FactsVisitor(&facts);
    if (parsed.module_.members)
        foreach (member; *parsed.module_.members)
            member.accept(visitor);

    static sortAll(ref StructuralFacts f) @safe
    {
        f.declMarkers.sort;
        f.templateMarkers.sort;
        f.constraintMarkers.sort;
        f.inContractMarkers.sort;
        f.outContractMarkers.sort;
        f.bodyMarkers.sort;
    }

    sortAll(facts);
    return facts;
}

import dmd.visitor : SemanticTimeTransitiveVisitor;

private extern (C++) final class FactsVisitor : SemanticTimeTransitiveVisitor
{
    import dmd.dtemplate : TemplateDeclaration;
    import dmd.func : FuncDeclaration;

    alias visit = SemanticTimeTransitiveVisitor.visit;

    StructuralFacts* facts;

    extern (D) this(StructuralFacts* facts) scope @safe pure nothrow @nogc
    {
        this.facts = facts;
    }

    override void visit(TemplateDeclaration td)
    {
        // Two parse-tree sharp edges, found by this spike:
        //
        // 1. The synthesized wrapper of an *eponymous* function template
        //    carries `Loc.initial` — and `Loc.fileOffset()` on an invalid
        //    Loc underflows dmd's global file table (bounds error), so every
        //    fileOffset call here is isValid-guarded.
        // 2. The transitive visitor's `visitEponymousMember` visits the
        //    member function via `visitFuncBody` directly — the virtual
        //    `visit(FuncDeclaration)` never fires — so the eponymous
        //    function's facts must be recorded from here.
        if (auto fd = eponymousFunc(td))
        {
            recordFunc(fd);
            if (fd.loc.isValid)
                facts.templateMarkers ~= fd.loc.fileOffset;
        }
        else if (td.loc.isValid)
        {
            facts.declMarkers ~= td.loc.fileOffset;
            facts.templateMarkers ~= td.loc.fileOffset;
        }
        if (td.constraint && td.constraint.loc.isValid)
            facts.constraintMarkers ~= td.constraint.loc.fileOffset;
        super.visit(td);
    }

    override void visit(FuncDeclaration fd)
    {
        recordFunc(fd);
        super.visit(fd);
    }

    private extern (D) static FuncDeclaration eponymousFunc(TemplateDeclaration td)
    {
        if (!td.members || td.members.length != 1)
            return null;
        auto one = (*td.members)[0];
        return one.ident == td.ident ? one.isFuncDeclaration() : null;
    }

    private extern (D) void recordFunc(FuncDeclaration fd)
    {
        if (fd.loc.isValid)
            facts.declMarkers ~= fd.loc.fileOffset;
        if (fd.frequires)
            foreach (req; *fd.frequires)
                if (req.loc.isValid)
                    facts.inContractMarkers ~= req.loc.fileOffset;
        if (fd.fensures)
            foreach (ens; *fd.fensures)
                if (ens.ensure.loc.isValid)
                    facts.outContractMarkers ~= ens.ensure.loc.fileOffset;
        if (fd.fbody && fd.fbody.loc.isValid)
            facts.bodyMarkers ~= fd.fbody.loc.fileOffset;
    }
}

@("oracle.collectFacts.function-template-with-contracts")
@system unittest
{
    enum src = "auto transmogrify(T, U)(T input, U seed) @safe pure\n"
        ~ "if (isInputRange!T && is(U : int))\n"
        ~ "in (seed > 0)\n"
        ~ "out (r; r !is null)\n"
        ~ "{\n"
        ~ "    return null;\n"
        ~ "}\n";
    auto facts = collectFacts(src);
    assert(facts.parsed);
    assert(facts.declMarkers.length >= 1);
    assert(facts.constraintMarkers.length == 1);
    assert(facts.inContractMarkers.length == 1);
    assert(facts.outContractMarkers.length == 1);
    assert(facts.bodyMarkers.length == 1);

    // The S4 loc findings, pinned: every marker is a real, in-range offset;
    // the decl marker sits at the identifier; the constraint marker inside
    // the if-parens; the body marker at its `{`.
    import std.algorithm.searching : countUntil;

    const declAt = cast(uint) src.countUntil("transmogrify");
    assert(facts.declMarkers[0] == declAt);
    const ifAt = cast(uint) src.countUntil("if (");
    assert(facts.constraintMarkers[0] > ifAt + 3);
    const bodyAt = cast(uint) src.countUntil("{");
    assert(facts.bodyMarkers[0] == bodyAt);
}

@("oracle.collectFacts.broken-input-degrades")
@system unittest
{
    // The formatter's LSP posture: broken input still yields whatever facts
    // parsed, never a crash. (dfmt's documented degradation.)
    auto facts = collectFacts("void f( {\n int x = ;\n");
    assert(!facts.parsed);
}

@("oracle.containsOffsetIn.bounds")
@safe pure nothrow unittest
{
    const uint[] xs = [3, 10, 20];
    assert(containsOffset(xs, 10));
    assert(!containsOffset(xs, 11));
    assert(containsOffsetIn(xs, 4, 10));
    assert(containsOffsetIn(xs, 10, 10));
    assert(!containsOffsetIn(xs, 4, 9));
    assert(containsOffsetIn(xs, 0, 100));
    assert(!containsOffsetIn(xs, 21, 100));
}

@("oracle.collectFacts.unittest-bodies-are-parsed")
@system unittest
{
    // S4 finding, pinned: the oracle sets global.params.useUnitTests, so
    // declarations and contracts inside unittest bodies produce facts.
    // (Without the flag the parser keeps only the body's tokens and this
    // fixture yields no markers at all beyond the unittest itself.)
    enum src = "unittest\n{\n"
        ~ "    int local(int x)\n"
        ~ "    in (x > 0)\n"
        ~ "    {\n        return x;\n    }\n"
        ~ "}\n";
    auto facts = collectFacts(src);
    assert(facts.parsed);
    assert(facts.inContractMarkers.length == 1);
    assert(facts.bodyMarkers.length >= 1);
}
