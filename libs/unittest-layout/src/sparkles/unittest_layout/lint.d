/**
The unittest layout lint (build-graph SPEC BGV4–BGV5).

A test root compiles with `-unittest`, which turns `version (unittest)` on in
every module it imports, its dependencies' included; the dependency
libraries it links were compiled without it. So `version (unittest)` in a
library must change nothing a dependent's compile or link can observe, or the
test binary sees one declaration, layout or template instance and links
code compiled against another.

$(LREF checkLayout) parses a module with DMD's parser, without semantic
analysis, so it sees both branches of every `version (unittest)` and every
template body, instantiated or not. It reports, by line:

$(LIST
    * a declaration visible outside its module (`public`, `package`,
        `protected` or `export`) in a `version (unittest)` branch, at any level;
        * an aggregate member of any visibility there: a field, a virtual method,
        a destructor, a postblit or a copy constructor;
        * a template there, whatever its visibility;
        * any `version (unittest)` inside a template, or inside the body of a
        function a dependent compiles: an `auto`-returning function, one in a
        template, or one under `pragma(inline, true)`;
        * a module-scope import there of a module the library configuration does
        not depend on.
)

A `private`, non-template, module-level declaration is exempt when its
`version (unittest)` has no `else` branch. Without `-unittest` it does not
exist, so code outside the tests that used it would not compile as a
library at all: only tests can use it. With an `else` branch, code outside
the tests sees a different declaration, and that is reported.
*/
module sparkles.unittest_layout.lint;

import std.algorithm.searching : startsWith;

/// One violation of the layout rule.
struct LayoutViolation
{
    uint line;     ///
    string what;   /// what the `version (unittest)` changes, as a phrase
}

/// What $(LREF checkLayout) found.
struct LayoutReport
{
    LayoutViolation[] violations; /// sorted by line
    /// Whether the module parsed. A module that does not parse is not
    /// checked; planning reports it instead of passing it.
    bool parsed;
}

/**
Checks one module of a library against the layout rule.

Params:
    fileName = the name diagnostics would use; nothing is read from it
    source = the module's text
    dependedOn = whether the library configuration depends on the package
        of a module, by its dotted name: an import of any other module under
        `version (unittest)` is a test-only dependency

Returns: the violations, or a report that the module did not parse.
*/
LayoutReport checkLayout(string fileName, const(char)[] source,
    scope bool delegate(const(char)[] module_) @safe dependedOn,
    scope bool delegate(const(char)[] identifier) @safe versionSet = null) @trusted
{
    import sparkles.d_source.dmd_globals : withDmdGlobals;

    // DMD's parser reads its process-wide state, which the lock guards.
    LayoutReport report;
    withDmdGlobals(() { report = checkLayoutImpl(fileName, source, dependedOn, versionSet); });
    return report;
}

///
@("unittest_layout.checkLayout.fieldAndExemptHelper")
@safe unittest
{
    const r = checkLayout("m.d", `
        module m;
        struct S
        {
            int a;
            version (unittest) int testOnly;
        }
        version (unittest) private int helper() { return 1; }
        unittest { version (unittest) {} }
    `, (m) => true);
    assert(r.parsed);
    assert(r.violations == [LayoutViolation(6, "a field")], r.violations.length ? r.violations[0].what : "");
}

private:

__gshared bool frontendReady;

LayoutReport checkLayoutImpl(string fileName, const(char)[] source,
    scope bool delegate(const(char)[] module_) @safe dependedOn,
    scope bool delegate(const(char)[] identifier) @safe versionSet) @system
{
    import dmd.frontend : initDMD, parseModule;
    import dmd.globals : global;

    if (!frontendReady)
    {
        // Diagnostics are swallowed: a module that does not parse is reported
        // as such, and its compile reports why.
        initDMD((const ref loc, headerColor, header, messageFormat, args, p1, p2) nothrow => true);
        frontendReady = true;
    }

    // Gagging also unwinds `global.errors`, which would otherwise end the
    // process once enough modules failed to parse (libs/dmd-fmt's oracle).
    const gagged = global.startGagging();
    auto parsed = parseModule(fileName, source);
    const errors = global.endGagging(gagged);

    LayoutReport report;
    report.parsed = parsed.module_ !is null && !errors;
    if (!report.parsed)
        return report;

    scope visitor = new LayoutVisitor(dependedOn, versionSet, source);
    if (parsed.module_.members)
        foreach (member; *parsed.module_.members)
            member.accept(visitor);

    import std.algorithm.sorting : sort;

    report.violations = visitor.found;
    report.violations.sort!((a, b) => a.line != b.line ? a.line < b.line : a.what < b.what);
    return report;
}

// Declared out here: a delegate type spelled inside an `extern (C++)` class
// takes C++ linkage.
alias DependedOn = bool delegate(const(char)[] module_) @safe;
alias VersionSet = bool delegate(const(char)[] identifier) @safe;

import dmd.visitor : SemanticTimeTransitiveVisitor;

extern (C++) final class LayoutVisitor : SemanticTimeTransitiveVisitor
{
    import dmd.astenums : STC;
    import dmd.attrib : ConditionalDeclaration, PragmaDeclaration, VisibilityDeclaration;
    import dmd.cond : Condition;
    import dmd.dclass : ClassDeclaration;
    import dmd.declaration : AliasDeclaration, VarDeclaration;
    import dmd.denum : EnumDeclaration;
    import dmd.dimport : Import;
    import dmd.dstruct : StructDeclaration;
    import dmd.dsymbol : Dsymbol, Visibility;
    import dmd.dtemplate : TemplateDeclaration;
    import dmd.func : CtorDeclaration, DtorDeclaration, FuncDeclaration, FuncLiteralDeclaration,
        InvariantDeclaration, NewDeclaration, PostBlitDeclaration, SharedStaticCtorDeclaration,
        SharedStaticDtorDeclaration, StaticCtorDeclaration, StaticDtorDeclaration, UnitTestDeclaration;
    import dmd.statement : ConditionalStatement;
    import dmd.root.array : peekSlice;
    import dmd.location : Loc;

    alias visit = SemanticTimeTransitiveVisitor.visit;

    // Where the walk is.
    static struct Context
    {
        bool underUnittest;  // in a branch of a `version (unittest)`
        bool hasElse;        // ... which has an `else` branch
        Visibility.Kind visibility = Visibility.Kind.public_;
        bool inAggregate;    // a member of an aggregate
        bool inClass;        // ... of a class or interface
        bool inTemplate;     // in a template, or a templated aggregate or function
        bool inFunction;     // in a function body
        bool compiledByDependent; // ... of a function a dependent compiles
        bool inline;         // under `pragma(inline, …)`
        bool explicitVisibility; // under a visibility attribute
        bool unreachedImports;   // in a branch the variant does not compile
    }

    Context at;
    LayoutViolation[] found;
    DependedOn dependedOn;
    VersionSet versionSet;
    // Where each line of the source starts, by byte offset.
    size_t[] lineStarts;

    extern (D) this(DependedOn dependedOn, VersionSet versionSet, const(char)[] source) @trusted
    {
        this.dependedOn = dependedOn;
        this.versionSet = versionSet;
        lineStarts ~= 0;
        foreach (i, c; source)
            if (c == '\n')
                lineStarts ~= i + 1;
    }

    // The 1-based line of `loc`, counting `\n` only: DMD's own line numbers
    // also count U+2028 and U+2029, as the language does, so they drift from
    // an editor's past one in a string literal.
    extern (D) uint lineOf(const ref Loc loc)
    {
        import std.range : assumeSorted;

        if (!loc.isValid)
            return 0;
        return cast(uint) lineStarts.assumeSorted.lowerBound(loc.fileOffset + 1).length;
    }

    extern (D) void report(uint line, string what)
    {
        found ~= LayoutViolation(line, what);
    }

    // Which branch of `c` the variant compiles: 1 the first, 2 the `else`,
    // 0 either (a predefined identifier, a `debug` or `static if`, or no
    // version set given).
    extern (D) int liveBranch(Condition c)
    {
        import dmd.cond : VersionCondition;

        if (versionSet is null || c is null)
            return 0;
        auto v = c.isVersionCondition();
        if (v is null || v.ident is null)
            return 0;
        const id = v.ident.toString();
        if (VersionCondition.isReserved(id))
            return 0;
        return versionSet(id) ? 1 : 2;
    }

    extern (D) static bool isUnittestVersion(Condition c)
    {
        if (c is null)
            return false;
        if (auto v = c.isVersionCondition())
            return v.ident !is null && v.ident.toString() == "unittest";
        return false;
    }

    // A declaration in a `version (unittest)` branch, outside a function body.
    extern (D) void declared(uint line, string kind, bool isTemplate)
    {
        if (!at.underUnittest || at.inFunction)
            return;
        const visible = at.visibility != Visibility.Kind.private_ && at.visibility != Visibility.Kind.none;
        if (visible)
            report(line, "a " ~ visibilityName(at.visibility) ~ " " ~ kind);
        else if (isTemplate)
            report(line, "a private " ~ kind);
        else if (!at.inAggregate && at.hasElse)
            report(line, "a private " ~ kind ~ " that differs outside the tests (an `else` branch)");
    }

    extern (D) static string visibilityName(Visibility.Kind k)
    {
        final switch (k)
        {
            case Visibility.Kind.undefined: return "public";
            case Visibility.Kind.none: return "private";
            case Visibility.Kind.private_: return "private";
            case Visibility.Kind.package_: return "package";
            case Visibility.Kind.protected_: return "protected";
            case Visibility.Kind.public_: return "public";
            case Visibility.Kind.export_: return "export";
        }
    }

    override void visit(ConditionalDeclaration d)
    {
        if (!isUnittestVersion(d.condition))
        {
            // A user-defined `version` the variant does not set (or does)
            // makes one branch dead for it: its imports are not the
            // library's. Every other hazard is judged in both branches.
            const live = liveBranch(d.condition);
            const saved = at.unreachedImports;
            at.unreachedImports = saved || live == 2;
            foreach (de; d.decl.peekSlice())
                de.accept(this);
            at.unreachedImports = saved || live == 1;
            foreach (de; d.elsedecl.peekSlice())
                de.accept(this);
            at.unreachedImports = saved;
            return;
        }
        if (at.inTemplate)
            report(lineOf(d.loc), "a `version (unittest)` inside a template");
        else if (at.compiledByDependent)
            report(lineOf(d.loc), "a `version (unittest)` in the body of a function a dependent compiles");
        const saved = at;
        at.underUnittest = true;
        at.hasElse = d.elsedecl !is null && d.elsedecl.length > 0;
        foreach (de; d.decl.peekSlice())
            de.accept(this);
        foreach (de; d.elsedecl.peekSlice())
            de.accept(this);
        at = saved;
    }

    override void visit(ConditionalStatement s)
    {
        if (isUnittestVersion(s.condition))
        {
            if (at.inTemplate)
                report(lineOf(s.loc), "a `version (unittest)` inside a template");
            else if (at.compiledByDependent)
                report(lineOf(s.loc), "a `version (unittest)` in the body of a function a dependent compiles");
        }
        if (s.ifbody)
            s.ifbody.accept(this);
        if (s.elsebody)
            s.elsebody.accept(this);
    }

    override void visit(VisibilityDeclaration d)
    {
        const saved = at;
        at.visibility = d.visibility.kind;
        at.explicitVisibility = true;
        foreach (de; d.decl.peekSlice())
            de.accept(this);
        at.visibility = saved.visibility;
        at.explicitVisibility = saved.explicitVisibility;
    }

    override void visit(PragmaDeclaration d)
    {
        const saved = at.inline;
        if (d.ident !is null && d.ident.toString() == "inline")
            at.inline = true;
        foreach (de; d.decl.peekSlice())
            de.accept(this);
        at.inline = saved;
    }

    // Unittest blocks compile only in their own package's test root.
    override void visit(UnitTestDeclaration) {}

    override void visit(Import imp)
    {
        if (!at.underUnittest || at.inFunction || at.inAggregate || at.unreachedImports)
            return;
        string name;
        foreach (p; imp.packages)
            name ~= p.ident.toString() ~ ".";
        name ~= imp.id.toString();
        // An import is private unless marked otherwise.
        const marked = at.explicitVisibility ? at.visibility : imp.visibility.kind;
        if (marked == Visibility.Kind.public_ || marked == Visibility.Kind.export_)
            report(lineOf(imp.loc), "a public import of `" ~ name ~ "`");
        else if (!dependedOn(name))
            report(lineOf(imp.loc), "an import of `" ~ name ~ "`, which the library does not depend on");
    }

    override void visit(TemplateDeclaration td)
    {
        // An eponymous template's wrapper is synthesized, and its location is no
        // line of the declaration: its member's is.
        uint line = lineOf(td.loc);
        if (td.members && td.members.length == 1 && (*td.members)[0].ident is td.ident)
            line = lineOf((*td.members)[0].loc);
        else if (line == 0 && td.members && td.members.length)
            line = lineOf((*td.members)[0].loc);
        declared(line, td.ismixin ? "mixin template" : "template", true);
        const saved = at;
        at.inTemplate = true;
        at.visibility = Visibility.Kind.public_;
        if (!at.inFunction)
            at.underUnittest = false; // its members are judged as a template's
        foreach (m; td.members.peekSlice())
            m.accept(this);
        at = saved;
    }

    extern (D) void aggregate(Dsymbol d, Dsymbol[] members, bool isClass, string kind)
    {
        declared(lineOf(d.loc), kind, false);
        const saved = at;
        at.inAggregate = true;
        at.inClass = isClass;
        at.visibility = Visibility.Kind.public_;
        // An aggregate declared under `version (unittest)` is one finding, or
        // exempt as a whole; its members are judged only by a `version
        // (unittest)` of their own.
        at.underUnittest = false;
        at.hasElse = false;
        foreach (m; members)
            m.accept(this);
        at = saved;
    }

    override void visit(StructDeclaration d)
    {
        aggregate(d, d.members.peekSlice(), false, d.isUnionDeclaration() ? "union" : "struct");
    }

    override void visit(ClassDeclaration d)
    {
        aggregate(d, d.members.peekSlice(), true, d.isInterfaceDeclaration() ? "interface" : "class");
    }

    override void visit(EnumDeclaration d)
    {
        declared(lineOf(d.loc), "enum", false);
    }

    override void visit(AliasDeclaration d)
    {
        declared(lineOf(d.loc), "alias", false);
    }

    override void visit(VarDeclaration d)
    {
        if (!at.underUnittest || at.inFunction)
            return;
        const isStatic = (d.storage_class & (STC.static_ | STC.manifest | STC.gshared)) != 0;
        if (at.inAggregate && !isStatic)
            report(lineOf(d.loc), "a field");
        else
            declared(lineOf(d.loc), (d.storage_class & STC.manifest) ? "manifest constant" : "variable", false);
    }

    extern (D) void function_(FuncDeclaration f, string kind, bool layoutHazard, bool declaration = true)
    {
        if (declaration && at.underUnittest && !at.inFunction)
        {
            if (at.inAggregate && layoutHazard)
                report(lineOf(f.loc), (kind[0] == 'i' ? "an " : "a ") ~ kind);
            else
                declared(lineOf(f.loc), kind, false);
        }
        // Its body: a dependent compiles it when the function is in a
        // template, infers its return type, or is to be inlined.
        const saved = at;
        at.inFunction = true;
        at.compiledByDependent = at.compiledByDependent || at.inTemplate || f.inferRetType || at.inline
            || (f.storage_class & STC.auto_) != 0;
        if (at.compiledByDependent || at.inTemplate)
            visitFuncBody(f);
        at = saved;
    }

    override void visit(FuncDeclaration f)
    {
        const isStatic = (f.storage_class & (STC.static_ | STC.final_)) != 0;
        const virtual = at.inClass && !isStatic && at.visibility != Visibility.Kind.private_;
        function_(f, virtual ? "virtual method" : at.inAggregate ? "method" : "function", virtual);
    }

    override void visit(FuncLiteralDeclaration f)
    {
        // A literal is an expression, not a declaration: only its body counts.
        function_(f, "function literal", false, declaration: false);
    }

    override void visit(CtorDeclaration f)
    {
        import dmd.mtype : TypeFunction;

        // A copy constructor takes one `ref` parameter.
        bool copy;
        if (auto tf = f.type ? f.type.isTypeFunction() : null)
            copy = tf.parameterList.length == 1 && (tf.parameterList[0].storageClass & STC.ref_) != 0;
        function_(f, copy ? "copy constructor" : "constructor", copy);
    }

    override void visit(DtorDeclaration f)
    {
        function_(f, "destructor", true);
    }

    override void visit(PostBlitDeclaration f)
    {
        function_(f, "postblit", true);
    }

    // The visitor sends these to their bodies without `visit(FuncDeclaration)`;
    // a module constructor is visible to no one, an invariant changes the
    // aggregate's code.
    override void visit(StaticCtorDeclaration f) { function_(f, "static constructor", false, declaration: false); }
    override void visit(SharedStaticCtorDeclaration f) { function_(f, "static constructor", false, declaration: false); }
    override void visit(StaticDtorDeclaration f) { function_(f, "static destructor", false, declaration: false); }
    override void visit(SharedStaticDtorDeclaration f) { function_(f, "static destructor", false, declaration: false); }
    override void visit(InvariantDeclaration f) { function_(f, "invariant", true); }
    override void visit(NewDeclaration f) { function_(f, "allocator", false); }
}

@("unittest_layout.checkLayout.oracle8Hazards")
@safe unittest
{
    // Oracle 8: one instance of each hazard, each failing with its location.
    static void expect(string source, uint line, string what)
    {
        const r = checkLayout("m.d", source, (m) => m != "sparkles.test_utils");
        assert(r.parsed, source);
        assert(r.violations.length == 1 && r.violations[0] == LayoutViolation(line, what),
            r.violations.length ? r.violations[0].what : "none");
    }

    expect("struct S {\nversion (unittest) int x;\n}", 2, "a field");
    expect("class C {\nversion (unittest) void f() {}\n}", 2, "a virtual method");
    expect("struct S {\nversion (unittest) ~this() {}\n}", 2, "a destructor");
    expect("version (unittest)\nenum E { a }", 2, "a public enum");
    expect("void f(T)() {\nversion (unittest) {}\n}", 2, "a `version (unittest)` inside a template");
    expect("version (unittest)\nimport sparkles.test_utils;", 2,
        "an import of `sparkles.test_utils`, which the library does not depend on");

    // The same declarations inside a unittest block pass.
    const inside = checkLayout("m.d", "unittest {\nstruct S { int x; ~this() {} }\nenum E { a }\n"
        ~ "import sparkles.test_utils;\n}", (m) => false);
    assert(inside.parsed && inside.violations.length == 0);
}

@("unittest_layout.checkLayout.moreHazards")
@safe unittest
{
    static LayoutViolation[] check(string source)
    {
        const r = checkLayout("m.d", source, (m) => true);
        assert(r.parsed, source);
        return r.violations.dup;
    }

    // A public helper is visible to dependents; a private one is not, unless
    // an `else` branch gives code outside the tests another one.
    assert(check("version (unittest) int helper;") == [LayoutViolation(1, "a public variable")]);
    assert(check("version (unittest) private int helper;") == []);
    assert(check("version (unittest) private enum n = 1; else private enum n = 2;")
        == [LayoutViolation(1, "a private manifest constant that differs outside the tests (an `else` branch)"),
            LayoutViolation(1, "a private manifest constant that differs outside the tests (an `else` branch)")]);
    // Templates and the bodies dependents compile.
    assert(check("version (unittest) private void t(T)() {}") == [LayoutViolation(1, "a private template")]);
    assert(check("auto f() {\nversion (unittest) {}\nreturn 1;\n}")
        == [LayoutViolation(2, "a `version (unittest)` in the body of a function a dependent compiles")]);
    assert(check("int f() {\nversion (unittest) {}\nreturn 1;\n}") == []);
    assert(check("pragma(inline, true) int f() {\nversion (unittest) {}\nreturn 1;\n}")
        == [LayoutViolation(2, "a `version (unittest)` in the body of a function a dependent compiles")]);
    // Members: a postblit and a copy constructor, whatever their visibility;
    // a private struct method changes no layout.
    assert(check("struct S {\nversion (unittest) private this(this) {}\n}") == [LayoutViolation(2, "a postblit")]);
    assert(check("struct S {\nversion (unittest) private this(ref S) {}\n}")
        == [LayoutViolation(2, "a copy constructor")]);
    assert(check("struct S {\nversion (unittest) private void f() {}\n}") == []);
    // A public import re-exports; a private one of a dependency is fine.
    assert(check("version (unittest) public import std.stdio;")
        == [LayoutViolation(1, "a public import of `std.stdio`")]);
    assert(check("version (unittest) import std.stdio;") == []);
    // A module constructor's locals are no declarations of the module; an
    // invariant changes what every method of the aggregate runs.
    assert(check("version (unittest) shared static this() { int local; }") == []);
    assert(check("struct S {\nversion (unittest) invariant { }\n}") == [LayoutViolation(2, "an invariant")]);
    // The colon form covers the rest of the scope.
    assert(check("version (unittest):\nint a;\nprivate int b;") == [LayoutViolation(2, "a public variable")]);
}

@("unittest_layout.checkLayout.unparsable")
@safe unittest
{
    const r = checkLayout("m.d", "struct {", (m) => true);
    assert(!r.parsed);
}

// `sparkles:d-source` carries its own copy of D's predefined version
// identifiers, since `dmd:lexer` lacks the frontend's list; this package
// links the frontend, so it checks the copy against the authority.
@("unittest_layout.predefinedVersionsAreReserved")
@trusted unittest
{
    import dmd.cond : VersionCondition;
    import sparkles.d_source.mentions : predefinedVersions;
    import sparkles.d_source.dmd_globals : withDmdGlobals;

    withDmdGlobals(() {
        foreach (id; predefinedVersions)
            assert(VersionCondition.isReserved(id), id);
        assert(!VersionCondition.isReserved("SparklesTrace"));
    });
}

@("unittest_layout.checkLayout.linesCountNewlinesOnly")
@safe unittest
{
    // U+2028 and U+2029 end lines in D, not in an editor or in git.
    const r = checkLayout("m.d", "enum s = \"a\u2028b\u2029c\";\nstruct S {\nversion (unittest) int x;\n}", (m) => true);
    assert(r.violations == [LayoutViolation(3, "a field")]);
}

@("unittest_layout.checkLayout.importsInBranchesTheVariantDoesNotCompile")
@safe unittest
{
    // A module the `gui` configuration alone compiles, whose tests import
    // what only that configuration depends on.
    enum source = "version (UiGui):\nversion (unittest) import gui.events;\n"
        ~ "version (Other) {} else { version (unittest) import gui.types; }\n";
    bool dependedOn(const(char)[] m) @safe => !m.startsWith("gui.");
    bool set(const(char)[] id) @safe => false;
    // Without the variant's versions, both imports are test-only.
    assert(checkLayout("m.d", source, &dependedOn).violations.length == 2);
    // A variant without `UiGui` compiles neither.
    assert(checkLayout("m.d", source, &dependedOn, &set).violations.length == 0);
}
