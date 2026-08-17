/**
The S4 loc inventory — pinned `Loc.fileOffset()` semantics per parse-time
node kind, for every construct family in the proposal's hard list
(`docs/research/code-formatting/dmd-lsp-baseline.md`, Q-e).

Each test asserts where a node kind's loc $(B anchors) in the source. These
are the facts the AST-oracle table (M3) is designed against; the M0 decision
record summarizes them as a table. The taxonomy the tests pin:

$(LIST
    * $(B Keyword anchors): `version`/`static if` (declaration and statement
        forms, plus their conditions), `extern` linkage (`LinkDeclaration`
        and `Nspace` — `extern (C++, ns)` parses as `Nspace`, not
        `CPPNamespaceDeclaration`), `invariant` (both forms), `unittest`,
        every `mixin` form, `asm` (`CompoundAsmStatement`; the
        per-instruction `AsmStatement` locs are unusable, but `TOK.asm_` is
        self-identifying so no oracle marker is needed at all), `is(…)` and
        `__traits(…)` expressions. Extents follow by bracket matching from
        the keyword — the S2 lookahead pattern.
    * $(B Identifier anchors): aggregates (`struct`/`class`/`enum`), `alias`
        and variable declarations — like functions, the loc points at the
        declared name, so a group builder must adopt the tokens before it.
    * $(B Invalid locs): `UserAttributeDeclaration` carries `Loc.initial` —
        UDA clusters have no oracle anchor and must be recognized from the
        `@` token alone.
    * $(B Both arms parse): `version`/`static if` keep both branches in the
        parse tree (arm selection is semantic), so both arms have oracle
        facts — the "both arms format" requirement is satisfiable.
)

Test-only: the inventory's value at runtime is zero; its value is failing
loudly when a fork rebase changes any of these facts.
*/
module sparkles.dmd_fmt.loc_inventory;

version (unittest):

import sparkles.dmd_fmt.oracle : ensureFrontendGlobals;
import sparkles.dmd_fmt.spine : dmdGlobalsLock;

/// One recorded (node kind, anchor) observation.
private struct Rec
{
    string tag;
    bool valid;
    uint off;
}

/// Parse `source` and record the loc of every node kind the inventory
/// tracks, in visit order.
private Rec[] probeLocs(string source) @system
{
    synchronized (dmdGlobalsLock)
    {
        ensureFrontendGlobals();

        import dmd.frontend : parseModule;

        auto parsed = parseModule("dmd_fmt_loc_inventory.d", source);
        Rec[] recs;
        if (parsed.module_ is null)
            return recs;
        scope v = new InventoryVisitor(&recs);
        if (parsed.module_.members)
            foreach (m; *parsed.module_.members)
                m.accept(v);
        return recs;
    }
}

import dmd.visitor : SemanticTimeTransitiveVisitor;

private extern (C++) final class InventoryVisitor : SemanticTimeTransitiveVisitor
{
    import dmd.attrib : ConditionalDeclaration, StaticIfDeclaration,
        LinkDeclaration, MixinDeclaration, UserAttributeDeclaration;
    import dmd.declaration : AliasDeclaration, VarDeclaration;
    import dmd.dclass : ClassDeclaration;
    import dmd.denum : EnumDeclaration;
    import dmd.dstruct : StructDeclaration;
    import dmd.dtemplate : TemplateMixin;
    import dmd.expression : IsExp, TraitsExp;
    import dmd.func : InvariantDeclaration, UnitTestDeclaration;
    import dmd.location : Loc;
    import dmd.nspace : Nspace;
    import dmd.statement : AsmStatement, CompoundAsmStatement,
        ConditionalStatement, MixinStatement;

    alias visit = SemanticTimeTransitiveVisitor.visit;

    Rec[]* recs;

    extern (D) this(Rec[]* recs) scope @safe pure nothrow @nogc
    {
        this.recs = recs;
    }

    extern (D) private void rec(string tag, Loc loc)
    {
        *recs ~= Rec(tag, loc.isValid, loc.isValid ? loc.fileOffset : 0);
    }

    override void visit(StaticIfDeclaration d)
    {
        rec("staticIfDecl", d.loc);
        rec("staticIfDecl.cond", d.condition.loc);
        super.visit(d);
    }

    override void visit(ConditionalDeclaration d)
    {
        rec("versionDecl", d.loc);
        rec("versionDecl.cond", d.condition.loc);
        super.visit(d);
    }

    override void visit(ConditionalStatement s)
    {
        rec("condStmt", s.loc);
        rec("condStmt.cond", s.condition.loc);
        super.visit(s);
    }

    override void visit(LinkDeclaration d) { rec("linkDecl", d.loc); super.visit(d); }
    override void visit(Nspace n) { rec("nspace", n.loc); super.visit(n); }
    override void visit(UserAttributeDeclaration d) { rec("udaDecl", d.loc); super.visit(d); }
    override void visit(MixinDeclaration d) { rec("mixinDecl", d.loc); super.visit(d); }
    override void visit(MixinStatement s) { rec("mixinStmt", s.loc); super.visit(s); }
    override void visit(TemplateMixin m) { rec("templateMixin", m.loc); super.visit(m); }
    override void visit(CompoundAsmStatement s) { rec("asmBlock", s.loc); super.visit(s); }
    override void visit(AsmStatement s) { rec("asmInstr", s.loc); super.visit(s); }
    override void visit(InvariantDeclaration d) { rec("invariant_", d.loc); super.visit(d); }
    override void visit(UnitTestDeclaration d) { rec("unittest_", d.loc); super.visit(d); }
    override void visit(StructDeclaration d) { rec("structDecl", d.loc); super.visit(d); }
    override void visit(ClassDeclaration d) { rec("classDecl", d.loc); super.visit(d); }
    override void visit(EnumDeclaration d) { rec("enumDecl", d.loc); super.visit(d); }
    override void visit(AliasDeclaration d) { rec("aliasDecl", d.loc); super.visit(d); }
    override void visit(VarDeclaration d) { rec("varDecl", d.loc); super.visit(d); }
    override void visit(IsExp e) { rec("isExp", e.loc); super.visit(e); }
    override void visit(TraitsExp e) { rec("traitsExp", e.loc); super.visit(e); }
}

/// The offset of `needle`'s `n`-th occurrence in `hay` (0-based).
private uint offsetOf(string hay, string needle, size_t n = 0) @safe pure
{
    import std.algorithm.searching : countUntil;

    size_t base = 0;
    foreach (skip; 0 .. n + 1)
    {
        const at = hay[base .. $].countUntil(needle);
        assert(at >= 0, "fixture needle not found: " ~ needle);
        base += at + (skip < n ? needle.length : 0);
    }
    return cast(uint) base;
}

/// The single record with `tag`, asserting it exists and is unique.
private Rec one(const Rec[] recs, string tag) @safe pure
{
    Rec found;
    size_t n;
    foreach (r; recs)
        if (r.tag == tag)
        {
            found = r;
            n++;
        }
    assert(n == 1, "expected exactly one " ~ tag);
    return found;
}

/// All records with `tag`, in visit order.
private Rec[] all(const Rec[] recs, string tag) @safe pure
{
    Rec[] found;
    foreach (r; recs)
        if (r.tag == tag)
            found ~= r;
    return found;
}

@("loc_inventory.version-and-static-if.keyword-anchors-both-arms-parse")
@system unittest
{
    enum src = "version (Foo)\n{\n    int a;\n}\nelse\n{\n    int b;\n}\n"
        ~ "version (Bar) int c;\n"
        ~ "static if (is(int == int))\n    enum e0 = 1;\nelse\n    enum e1 = 2;\n";
    auto recs = probeLocs(src);

    const vers = all(recs, "versionDecl");
    assert(vers.length >= 2);
    assert(vers[0].valid && vers[0].off == offsetOf(src, "version (Foo)"));
    // The condition anchors at the version *identifier* — inside the paren
    // span that follows the keyword, the property the group builder checks.
    const conds = all(recs, "versionDecl.cond");
    assert(conds.length >= 2);
    assert(conds[0].valid && conds[0].off == offsetOf(src, "Foo"));

    const sif = one(recs, "staticIfDecl");
    assert(sif.valid && sif.off == offsetOf(src, "static if"));

    // Both arms are in the parse tree: a, b, c and both enums were visited.
    assert(all(recs, "varDecl").length == 5);
}

@("loc_inventory.conditional-statements.keyword-anchors")
@system unittest
{
    enum src = "void f()\n{\n"
        ~ "    static if (true) { int u; }\n"
        ~ "    version (Baz) { int v; }\n"
        ~ "}\n";
    auto recs = probeLocs(src);
    const stmts = all(recs, "condStmt");
    assert(stmts.length == 2);
    assert(stmts[0].valid && stmts[0].off == offsetOf(src, "static if"));
    assert(stmts[1].valid && stmts[1].off == offsetOf(src, "version (Baz)"));
}

@("loc_inventory.extern-linkage.keyword-anchors-and-nspace")
@system unittest
{
    // `extern (C++, ns)` parses as Nspace — not CPPNamespaceDeclaration.
    enum src = "extern (C++, ns) { void cppf(); }\n"
        ~ "extern (C) void cf();\n";
    auto recs = probeLocs(src);
    const ns = one(recs, "nspace");
    assert(ns.valid && ns.off == offsetOf(src, "extern (C++"));
    const link = one(recs, "linkDecl");
    assert(link.valid && link.off == offsetOf(src, "extern (C)"));
}

@("loc_inventory.aggregates-and-simple-decls.identifier-anchors")
@system unittest
{
    enum src = "struct S { int x; }\nclass C {}\nenum E { one }\n"
        ~ "alias Int = int;\nint gVar = 1;\n";
    auto recs = probeLocs(src);
    assert(one(recs, "structDecl").off == offsetOf(src, "S"));
    assert(one(recs, "classDecl").off == offsetOf(src, "C"));
    assert(one(recs, "enumDecl").off == offsetOf(src, "E {"));
    assert(one(recs, "aliasDecl").off == offsetOf(src, "Int"));
    const vars = all(recs, "varDecl");
    assert(vars.length == 2); // x and gVar
    assert(vars[1].off == offsetOf(src, "gVar"));
}

@("loc_inventory.invariant-unittest-mixin.keyword-anchors")
@system unittest
{
    enum src = "struct S\n{\n    int x;\n"
        ~ "    invariant (x > 0);\n"
        ~ "    invariant { assert(x > 0); }\n"
        ~ "    mixin Helper!int;\n"
        ~ "}\n"
        ~ "mixin(\"int mixedIn = 3;\");\n"
        ~ "unittest\n{\n    mixin(\"int w;\");\n}\n";
    auto recs = probeLocs(src);
    const invs = all(recs, "invariant_");
    assert(invs.length == 2);
    assert(invs[0].off == offsetOf(src, "invariant ("));
    assert(invs[1].off == offsetOf(src, "invariant {"));
    assert(one(recs, "templateMixin").off == offsetOf(src, "mixin Helper"));
    assert(one(recs, "mixinDecl").off == offsetOf(src, "mixin(\"int mixedIn"));
    assert(one(recs, "unittest_").off == offsetOf(src, "unittest"));
    assert(one(recs, "mixinStmt").off == offsetOf(src, "mixin(\"int w"));
}

@("loc_inventory.asm.block-anchors-at-keyword-instructions-unusable")
@system unittest
{
    enum src = "void withAsm()\n{\n    asm { nop; }\n}\n";
    auto recs = probeLocs(src);
    const blk = one(recs, "asmBlock");
    assert(blk.valid && blk.off == offsetOf(src, "asm {"));
    // The per-instruction AsmStatement loc does NOT anchor at the
    // instruction — pinned so a fork rebase changing this gets noticed.
    // (Irrelevant for the formatter: TOK.asm_ is self-identifying and the
    // block extent is brace-matched; asm needs no oracle marker at all.)
    const instr = all(recs, "asmInstr");
    assert(instr.length == 1);
    assert(instr[0].off != offsetOf(src, "nop"));
}

@("loc_inventory.expressions.is-and-traits-keyword-anchors")
@system unittest
{
    enum src = "void f()\n{\n"
        ~ "    auto t = __traits(hasMember, int, \"init\");\n"
        ~ "    auto i2 = is(int == int);\n"
        ~ "}\n";
    auto recs = probeLocs(src);
    assert(one(recs, "traitsExp").off == offsetOf(src, "__traits"));
    assert(one(recs, "isExp").off == offsetOf(src, "is(int"));
}

@("loc_inventory.uda-declaration-loc-is-invalid")
@system unittest
{
    // Pinned sharp edge: UserAttributeDeclaration carries Loc.initial, so
    // UDA clusters have no oracle anchor — they must be recognized from the
    // `@` token in the spine.
    enum src = "@safe @(\"uda\") int gVar = 1;\n";
    auto recs = probeLocs(src);
    const uda = all(recs, "udaDecl");
    assert(uda.length >= 1);
    foreach (r; uda)
        assert(!r.valid);
}
