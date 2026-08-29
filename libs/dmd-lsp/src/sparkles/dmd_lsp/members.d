/**
Type-scoped member enumeration: what an aggregate $(I contains), as opposed to
what may be typed at a position.

$(H2 Why this is not `findExpansions` with a flag)

`findExpansions` answers "what may I type here", and does it by climbing the
`uplevel` chain from the position's scope and fanning out over every public
import — which is exactly right for a completion list and exactly wrong for
"what does this type contain". Only a $(B dot expression) sets
`SearchOpt.localsOnly` and stops that climb, so `p.` enumerates `Point`'s
members while a bare `Point` enumerates the module plus druntime. The
difference is over a hundred entries, and it is not a filter: the strangers and
the members arrive from the same walk with nothing to tell them apart.

Passing `localsOnly` into `findExpansions` for the dot-less case is not the fix
either. That function's callers are completion lists, whose whole job is the
climb; changing it would silently break them to serve a different question.

So this is its own walk, and it lives in its own module rather than in
$(MREF sparkles,dmd_lsp,visitor): that file is ported from VisualD's
`semvisitor` and the fork's rebase story depends on keeping non-upstream
additions out of it.

$(H2 What it walks)

An aggregate's own `symtab`, then each base class transitively, then the
`alias this` target — each member tagged with the aggregate that declared it,
so a view can group inherited members without a second query. Bounded by a
visited set, exactly as `searchScope` bounds itself, because a cycle here would
hang a frame rather than fail one.
*/
module sparkles.dmd_lsp.members;

import dmd.aggregate : AggregateDeclaration;
import dmd.dclass : ClassDeclaration;
import dmd.declaration : Declaration;
import dmd.denum : EnumDeclaration;
import dmd.dmodule : Module;
import dmd.dscope : Scope;
import dmd.dstruct : StructDeclaration;
import dmd.dsymbol : Dsymbol, ScopeDsymbol;
import dmd.dtemplate : TemplateDeclaration, TemplateInstance;
import dmd.func : FuncDeclaration;
import dmd.mtype : Type;
// `isType`/`isExpression`/`isDsymbol` are free functions over `RootObject`
// living in `dtemplate`, reached by UFCS — the ported walk imports these
// modules whole for the same reason.
import dmd.dtemplate : isDsymbol, isExpression, isType;
import dmd.expression;
import dmd.rootobject;

import sparkles.dmd_lsp.visitor : docForSymbol, findAST, symbol2ExpansionType,
    tipForObject, typeSymbol;

/**
One member of an aggregate, as an explorer renders it.

`decl` comes from the same `tipForObject` that backs a hover's own `code`, so a
member row and that member's own popup cannot disagree about what it says.
*/
struct MemberItem
{
    /// The identifier as declared.
    string name;
    /// The `symbol2ExpansionType` category — `MTHD`, `PROP`, `STRU`, … — which
    /// already distinguishes a method from a free function and a field from a
    /// local, because it asks whether the parent is an aggregate.
    string kind;
    /// The rendered declaration, e.g. `int s.Point.dot(Point o)`.
    string decl;
    /// The aggregate that declared it: this type's own name, or a base class,
    /// or an `alias this` target. A view groups inherited members by it with no
    /// second query.
    string declaredIn;
    /// Whether its own type is itself an aggregate or enum — so a tree knows
    /// whether the row can be drilled into before asking.
    bool drillable;
}

/**
The aggregate or enum the position `line`:`col` (both 1-based) resolves to, or
`null`.

Shares `findExpansions`' object → type derivation and stops there: no `uplevel`
climb, no `importedScopes` fan-out, no `with` statement, no built-in properties.
*/
ScopeDsymbol aggregateAt(Module mod, int line, int col) @system
{
    auto found = findAST(mod, line, col, line, col + 1);
    if (found is null)
        return null;

    Type type = found.isType();
    if (type is null)
        if (auto e = found.isExpression())
            type = e.type;
    if (type is null)
        if (auto sym = found.isDsymbol())
        {
            // A declaration names its own type; a bare aggregate name IS one.
            if (auto ad = sym.isAggregateDeclaration())
                return ad;
            if (auto ed = sym.isEnumDeclaration())
                return ed;
            if (auto d = sym.isDeclaration())
                type = d.type;
        }
    return type is null ? null : typeSymbol(type);
}

/**
`sds`' members, with inherited ones included and tagged.

Deterministically ordered: `symtab.tab.asRange` is a hash iteration and its
order is not stable across runs, so a caller that rendered it directly would
produce a different list each time. Sorted by `(kind group, name)` — fields
before methods before nested types — so the grouping a view wants falls out of
the ordering instead of costing a second pass.
*/
MemberItem[] membersIn(ScopeDsymbol sds) @system
{
    import std.algorithm.sorting : sort;

    MemberItem[] items;
    if (sds is null)
        return items;

    bool[void*] visited;
    bool[string] seen;

    void collect(ScopeDsymbol s, string owner)
    {
        if (s is null || (cast(void*) s) in visited)
            return;
        visited[cast(void*) s] = true;

        if (s.symtab !is null)
            foreach (kv; s.symtab.tab.asRange)
            {
                auto sym = cast(Dsymbol) kv.value;
                if (sym is null || sym.ident is null)
                    continue;
                const nm = sym.ident.toString().idup;
                // A derived class's own member hides a base's of the same
                // name, and the derived one is walked first.
                if (nm in seen)
                    continue;
                seen[nm] = true;
                items ~= MemberItem(
                    name: nm,
                    kind: symbol2ExpansionType(sym),
                    decl: tipForObject(sym),
                    declaredIn: owner,
                    drillable: isDrillable(sym));
            }

        // Base classes, then the `alias this` target — the same order a member
        // lookup resolves in, so `declaredIn` matches where D would find it.
        if (auto cd = s.isClassDeclaration())
            if (cd.baseclasses !is null)
                foreach (b; *cd.baseclasses)
                    if (b !is null && b.sym !is null)
                        collect(b.sym, b.sym.ident is null
                            ? owner : b.sym.ident.toString().idup);
    }

    collect(sds, sds.ident is null ? "" : sds.ident.toString().idup);
    items.sort!((a, b) => a.kindRank == b.kindRank
        ? a.name < b.name : a.kindRank < b.kindRank);
    return items;
}

/// Whether `sym`'s own type is an aggregate or enum, so a row can be expanded.
/// A template DECLARATION is never drillable: it has no instantiated members to
/// show, and `typeSymbol` on one is null.
private bool isDrillable(Dsymbol sym) @system
{
    if (sym.isTemplateDeclaration() !is null)
        return false;
    if (sym.isAggregateDeclaration() !is null || sym.isEnumDeclaration() !is null)
        return true;
    if (auto d = sym.isDeclaration())
        return d.type !is null && typeSymbol(d.type) !is null;
    return false;
}

/// The sort group: fields, then properties, then methods, then nested types,
/// then everything else. Ordering rather than a second grouping pass.
private int kindRank(in MemberItem m) @safe pure nothrow @nogc
{
    switch (m.kind)
    {
        case "PROP": return 0;
        case "VAR": return 1;
        case "MTHD": return 2;
        case "FUNC": case "OVR": return 3;
        case "STRU": case "CLSS": case "IFAC": case "UNIO": case "ENUM":
            return 4;
        case "EVAL": return 5;
        case "ALIA": return 6;
        case "TMPL": case "NMIX": return 7;
        default: return 8;
    }
}

@("members.membersIn.isTypeScopedNotAScopeWalk")
@system unittest
{
    // The distinction the spike in `api.d` measured: `completionsAt` at a bare
    // type name answers the enclosing scope plus druntime; this answers the
    // type. Both are correct answers to different questions.
    import sparkles.dmd_lsp.testing : withAnalysis;

    withAnalysis(q{
        module s;
        struct Point
        {
            int x;
            int y;
            int dot(Point o) { return 0; }
            static Point zero() { return Point(); }
        }
        void use()
        {
            Point p;
        }
    }, (m) {
        auto sds = aggregateAt(m.module_, 12, 13);
        assert(sds !is null, "the bare type name resolves to its aggregate");

        const items = membersIn(sds);
        assert(items.length >= 4, "its own members");

        bool sawX, sawDot, sawZero, sawStranger;
        foreach (it; items)
        {
            if (it.name == "x") sawX = true;
            if (it.name == "dot") sawDot = true;
            if (it.name == "zero") sawZero = true;
            if (it.name == "Exception" || it.name == "ClassInfo")
                sawStranger = true;
        }
        assert(sawX && sawDot && sawZero);
        assert(!sawStranger, "and nothing from the enclosing scope");

        // Fields sort before methods, so a view groups by taking a prefix
        // rather than by walking the list twice.
        size_t firstMethod = items.length;
        foreach (i, it; items)
            if (it.kind == "MTHD" && firstMethod == items.length)
                firstMethod = i;
        foreach (i, it; items)
            if (it.kind == "PROP")
                assert(i < firstMethod, "fields come first");
    });
}

@("members.membersIn.inheritedMembersAreTaggedWithTheirDeclarer")
@system unittest
{
    import sparkles.dmd_lsp.testing : withAnalysis;

    withAnalysis(q{
        module s;
        class Base { int b; void hello() {} }
        class Derived : Base { int d; }
        void use() { Derived x; }
    }, (m) {
        auto sds = aggregateAt(m.module_, 5, 22);
        assert(sds !is null);

        const items = membersIn(sds);
        string ownerOf(string n)
        {
            foreach (it; items)
                if (it.name == n)
                    return it.declaredIn;
            return null;
        }

        assert(ownerOf("d") == "Derived", "its own");
        assert(ownerOf("b") == "Base",
            "and the base's, tagged — so a view groups them with no second query");
        assert(ownerOf("hello") == "Base");
    });
}

@("members.membersIn.orderIsTotalAcrossRuns")
@system unittest
{
    // `symtab.tab.asRange` is a hash iteration and its order is not stable, so
    // a caller rendering it directly would produce a different tree each run —
    // and every golden over it would flake.
    import sparkles.dmd_lsp.testing : withAnalysis;

    withAnalysis(q{
        module s;
        struct Wide
        {
            int a; int b; int c; int d; int e;
            void f() {} void g() {} void h() {}
        }
        void use() { Wide w; }
    }, (m) {
        auto sds = aggregateAt(m.module_, 8, 22);
        assert(sds !is null);

        const first = membersIn(sds);
        const second = membersIn(sds);
        assert(first.length == second.length);
        foreach (i, it; first)
            assert(it.name == second[i].name && it.kind == second[i].kind);
    });
}
