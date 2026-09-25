/**
LDC's rules for dcompute device code, reported during analysis (spec `TGT7`,
`TGT8`).

A `@compute` module compiles for a GPU, which has no garbage collector, no
exceptions, no strings, no globals and no calls into host code. The dcompute
LDC enforces that in a pass of its own after semantic analysis
(`gen/semantic-dcompute.cpp`) — a pass DMD's frontend does not have, so an
analysis that stopped at semantic would call a module clean that the real
build rejects. This is that pass, ported: the same rules, the same messages
word for word, so the editor says exactly what `shader-compile` would.

Two further checks come from the fork's `@fragment` stage
(`gen/dcompute/targetVulkan.cpp`, `gen/uda.cpp`): a fragment entry point's
parameters are each an `@input`, a `@uniform` or a `Sampler2D`, and
`@fragment` appears only in `@compute` modules.

What is not ported: checks that need the LLVM ABI (a parameter the ABI
rewrites), which no frontend-only analysis can make.
*/
module sparkles.dmd_lsp.dcompute;

import dmd.aggregate;
import dmd.arraytypes : Expressions;
import dmd.astenums;
import dmd.attrib;
import dmd.dclass;
import dmd.declaration;
import dmd.dmodule;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dtemplate;
import dmd.errors : error;
import dmd.expression;
import dmd.func;
import dmd.id;
import dmd.identifier;
import dmd.location;
import dmd.mtype;
import dmd.statement;
import dmd.staticassert : StaticAssert;
import dmd.tokens : EXP;
import dmd.typesem : toBasetype;
import dmd.visitor;

/// Where a module compiles, as LDC reads its `@compute` attribute.
enum CompileFor
{
    hostOnly,      /// no `@compute`
    deviceOnly,    /// `@compute(CompileFor.deviceOnly)`
    hostAndDevice, /// `@compute(CompileFor.hostAndDevice)`
}

/// `m`'s `@ldc.dcompute.compute` attribute, evaluated.
CompileFor compileForOf(Module m)
{
    if (auto sle = magicAttribute(m, "compute"))
    {
        import dmd.expressionsem : toInteger;

        if (sle.elements && sle.elements.length && (*sle.elements)[0])
            return cast(CompileFor)(1 + toInteger((*sle.elements)[0]));
        return CompileFor.deviceOnly;
    }
    return CompileFor.hostOnly;
}

/**
Runs LDC's device-code rules over `m` when it is a `@compute` module; every
violation is reported through the frontend's diagnostic handler, like any
other semantic error. Call after `fullSemantic`, and only when it reported no
errors — the rules assume a semantically sound tree.
*/
void dcomputeSemantic(Module m)
{
    if (compileForOf(m) == CompileFor.hostOnly || !m.members)
        return;

    scope v = new DComputeRules;
    foreach (sym; *m.members)
    {
        v.currentFunction = null;
        if (sym)
            sym.accept(v);
    }
}

/**
The `StructLiteralExp` of `sym`'s user-defined attribute of type
`ldc.dcompute.<ident>`, or null — LDC's `getMagicAttribute` over the one
module this pass cares about.
*/
StructLiteralExp magicAttribute(Dsymbol sym, string ident)
{
    import dmd.attribsem : getAttributes;
    import dmd.dinterpret : ctfeInterpret;
    import dmd.globals : global;

    if (!sym || !sym.userAttribDecl)
        return null;

    StructLiteralExp found;
    void scan(Expressions* exps)
    {
        if (!exps)
            return;
        foreach (e; *exps)
        {
            if (!e || found)
                continue;
            if (auto te = e.isTupleExp())
            {
                scan(te.exps);
                continue;
            }
            const gag = global.startGagging();
            auto value = e.ctfeInterpret();
            if (global.endGagging(gag))
                continue;
            if (auto sle = value.isStructLiteralExp())
                if (sle.sd && sle.sd.ident.toString() == ident && isFromDCompute(sle.sd))
                    found = sle;
        }
    }
    scan(getAttributes(sym.userAttribDecl));
    return found;
}

/// Whether `sym` is declared in `ldc.dcompute`.
bool isFromDCompute(Dsymbol sym) => isFromLdcModule(sym, "dcompute");

private bool isFromLdcModule(Dsymbol sym, string name)
{
    auto m = sym ? sym.getModule() : null;
    if (!m || !m.md)
        return false;
    auto packages = m.md.packages;
    return packages.length == 1 && packages[0].toString() == "ldc"
        && m.md.id.toString() == name;
}

// druntime's array comparison hooks (`__cmp`, `__equals` and their helpers):
// host modules, but the lowering of array `<`/`==` in device code.
private bool isDeviceArrayComparisonHook(Dsymbol sym)
{
    auto m = sym ? sym.getModule() : null;
    if (!m || !m.md)
        return false;
    auto packages = m.md.packages;
    const id = m.md.id.toString();
    return packages.length == 3 && packages[0].toString() == "core"
        && packages[1].toString() == "internal" && packages[2].toString() == "array"
        && (id == "comparison" || id == "equality");
}

private enum dcReflect = "__dcompute_reflect";

// `DComputeSemanticAnalyser`, over DMD's semantic-time transitive walk.
// Returning without calling `super.visit` is LDC's `stop = true`: the node's
// children are not walked.
private extern (C++) final class DComputeRules : SemanticTimeTransitiveVisitor
{
    alias visit = SemanticTimeTransitiveVisitor.visit;

    FuncDeclaration currentFunction;

    // In @compute code only calls to other @compute modules are allowed — plus
    // the target-neutral and device-only helpers, and a template alias
    // function argument (whose module is the instantiating one).
    bool isNonComputeCallExpValid(CallExp ce)
    {
        FuncDeclaration f = ce.f;
        if (f.ident.toString() == dcReflect)
            return true;
        if (isDeviceArrayComparisonHook(f))
            return true;
        if (isFromLdcModule(f, "intrinsics") || isFromDCompute(f))
            return true;
        if (!currentFunction)
            return false;
        auto inst = currentFunction.isInstantiated();
        if (!inst || !inst.tiargs)
            return false;
        foreach (o; *inst.tiargs)
            if (auto e = isExpression(o))
                if (auto fe = e.isFuncExp())
                    if (fe.fd is f)
                        return true;
        return false;
    }

    // --- declarations -----------------------------------------------------

    override void visit(InterfaceDeclaration decl)
    {
        error(decl.loc, "interfaces and classes not allowed in `@compute` code");
    }

    override void visit(ClassDeclaration decl)
    {
        error(decl.loc, "interfaces and classes not allowed in `@compute` code");
    }

    override void visit(VarDeclaration decl)
    {
        import core.stdc.string : strncmp;

        if (decl.isDataseg())
        {
            // `synchronized` is reported once, at its call; typeid is ignored
            // by codegen.
            if (strncmp(decl.toChars(), "__critsec", 9) && strncmp(decl.toChars(), "typeid", 6))
                error(decl.loc, "global variables not allowed in `@compute` code");
            return;
        }
        if (!decl.type)
            return super.visit(decl);

        if (decl.type.ty == Taarray)
        {
            error(decl.loc, "associative arrays not allowed in `@compute` code");
            return;
        }
        if (decl.type.ty == Tclass)
            error(decl.loc, "interfaces and classes not allowed in `@compute` code");
        super.visit(decl);
    }

    override void visit(PragmaDeclaration decl)
    {
        if (decl.ident == Id.lib)
        {
            error(decl.loc, "linking additional libraries not supported in `@compute` code");
            return;
        }
        visitIncluded(decl);
    }

    // Semantic analysis already chose each attribute block's members (the
    // active `version`/`static if` branch, the expanded `mixin`); the parse
    // time walk would visit both branches of a condition, including code no
    // compile ever sees.
    private void visitIncluded(AttribDeclaration decl)
    {
        import dmd.dsymbolsem : include;

        if (auto members = decl.include(null))
            foreach (sym; *members)
                if (sym)
                    sym.accept(this);
    }

    static foreach (T; AliasSeq!(AttribDeclaration, StorageClassDeclaration,
        DeprecatedDeclaration, LinkDeclaration, CPPMangleDeclaration,
        CPPNamespaceDeclaration, VisibilityDeclaration, AlignDeclaration,
        AnonDeclaration, ConditionalDeclaration, StaticIfDeclaration,
        StaticForeachDeclaration, MixinDeclaration, UserAttributeDeclaration))
        override void visit(T decl) { visitIncluded(decl); }

    // Compile-time only: the build never sees a `static assert`'s message.
    override void visit(StaticAssert) {}

    override void visit(FuncDeclaration fd)
    {
        if (magicAttribute(fd, "_kernel") && fd.vthis)
        {
            error(fd.loc, "`@kernel` functions must not require `this`");
            return;
        }
        if (magicAttribute(fd, "_shader"))
            checkFragmentParameters(fd);

        currentFunction = fd;
        super.visit(fd);
    }

    // The `@fragment` interface (`addShaderEntry`): every parameter becomes an
    // input variable, a uniform or an image binding, so it must say which.
    private void checkFragmentParameters(FuncDeclaration fd)
    {
        if (!fd.parameters)
            return;
        foreach (vd; *fd.parameters)
        {
            if (magicAttribute(vd, "_input") || magicAttribute(vd, "_uniform"))
                continue;
            auto ts = vd.type ? vd.type.toBasetype().isTypeStruct() : null;
            if (ts && ts.sym.ident.toString() == "Sampler2D" && isFromDCompute(ts.sym))
                continue;
            error(vd.loc, "`@fragment` parameter `%s` must be marked `@input` or "
                ~ "`@uniform`, or be a `Sampler2D`", vd.ident.toChars());
        }
    }

    // Uninstantiated templates have nothing to check yet.
    override void visit(TemplateDeclaration) {}

    override void visit(TemplateInstance ti)
    {
        // Host-side instantiations (TypeInfo, `object.RTInfo`, Phobos) are
        // skipped by codegen too.
        if (ti.tempdecl)
            if (auto m = ti.tempdecl.getModule())
                if (compileForOf(m) == CompileFor.hostOnly)
                    return;
        visitMembers(ti);
    }

    override void visit(TemplateMixin tm) { visitMembers(tm); }

    private void visitMembers(ScopeDsymbol sds)
    {
        if (sds.members)
            foreach (sym; *sds.members)
                if (sym)
                    sym.accept(this);
    }

    // --- expressions ------------------------------------------------------

    override void visit(ArrayLiteralExp e)
    {
        if (!e.type || e.type.ty != Tarray || !e.elements || !e.elements.length)
            return super.visit(e);
        error(e.loc, "array literal in `@compute` code not allowed");
    }

    override void visit(NewExp e)
    {
        error(e.loc, "cannot use `new` in `@compute` code");
    }

    override void visit(DeleteExp e)
    {
        error(e.loc, "cannot use `delete` in `@compute` code");
    }

    override void visit(AssignExp e)
    {
        if (e.e1.op == EXP.arrayLength)
        {
            error(e.loc, "setting `length` in `@compute` code not allowed");
            return;
        }
        super.visit(e);
    }

    override void visit(CatAssignExp e)
    {
        error(e.loc, "cannot use operator `~=` in `@compute` code");
    }

    override void visit(CatExp e)
    {
        error(e.loc, "cannot use operator `~` in `@compute` code");
    }

    override void visit(TypeidExp e)
    {
        error(e.loc, "typeinfo not available in `@compute` code");
    }

    override void visit(StringExp e)
    {
        error(e.loc, "string literals not allowed in `@compute` code");
    }

    override void visit(ThrowExp e)
    {
        error(e.loc, "no exceptions in `@compute` code");
    }

    override void visit(CallExp e)
    {
        if (!e.f)
        {
            error(e.loc, "function pointers and delegates are not allowed in `@compute` code");
            return;
        }

        // `synchronized` lowers to _d_criticalenter/_d_criticalexit around a
        // `__critsec` global: reported once, here.
        if (e.f.ident == Id.criticalenter)
        {
            error(e.loc, "cannot use `synchronized` in `@compute` code");
            return;
        }
        if (e.f.ident == Id.criticalexit)
            return;

        auto m = e.f.getModule();
        if ((m is null || compileForOf(m) == CompileFor.hostOnly) && !isNonComputeCallExpValid(e))
        {
            error(e.loc, "can only call functions from other `@compute` modules in `@compute` code");
            return;
        }
        super.visit(e);
    }

    // --- statements -------------------------------------------------------

    override void visit(AsmStatement s)
    {
        error(s.loc, "asm not allowed in `@compute` code");
    }

    override void visit(CompoundAsmStatement s)
    {
        error(s.loc, "asm not allowed in `@compute` code");
    }

    // `try … finally` stays legal (it is how `scope (exit)` lowers); `catch`
    // is dead code where nothing throws.
    override void visit(TryCatchStatement s)
    {
        error(s.loc, "no exceptions in `@compute` code");
    }

    override void visit(ThrowStatement s)
    {
        error(s.loc, "no exceptions in `@compute` code");
    }

    override void visit(SwitchStatement s)
    {
        if (auto ce = s.condition ? s.condition.isCallExp() : null)
            if (ce.f && ce.f.ident == Id.__switch)
            {
                error(s.loc, "cannot `switch` on strings in `@compute` code");
                return;
            }
        super.visit(s);
    }

    override void visit(IfStatement s)
    {
        // `if (__ctfe)` bodies never reach the device.
        if (auto ve = s.condition.isVarExp())
            if (ve.var && ve.var.ident == Id.ctfe)
            {
                if (s.elsebody)
                    s.elsebody.accept(this);
                return;
            }
        if (auto ne = s.condition.isNotExp())
            if (auto ve = ne.e1.isVarExp())
                if (ve.var && ve.var.ident == Id.ctfe)
                {
                    if (s.ifbody)
                        s.ifbody.accept(this);
                    return;
                }
        // `if (__dcompute_reflect(ReflectTarget.Host))` is explicitly host
        // code, free to call anything.
        if (auto ce = s.condition.isCallExp())
            if (ce.f && ce.f.ident.toString() == dcReflect && ce.arguments && ce.arguments.length)
            {
                import dmd.expressionsem : toInteger;

                if (toInteger((*ce.arguments)[0]) == 0)
                    return;
            }
        super.visit(s);
    }
}

private import std.meta : AliasSeq;
