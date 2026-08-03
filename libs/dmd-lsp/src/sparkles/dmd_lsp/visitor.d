/**
The `dmdserver` type oracle: a whole-AST visitor that answers positional
queries (tooltip, definition, identifier classification, completion,
references) against a semantically analyzed `Module`.

Ported near-verbatim from $(LINK2 https://github.com/dlang/visuald, Visual D)'s
`vdc/dmdserver/semvisitor.d` — Copyright (c) 2012 by Rainer Schuetze,
distributed under the Boost Software License, Version 1.0. Upstream code style
(brace placement, `extern(C++)` visitor classes, terse helpers) is kept so the
two files stay diffable; leading tabs became 4 spaces for this repo's
editorconfig.

$(H2 Deviation: filename matching)

Upstream builds against Visual D's `dmdlocation.d`, a whole-module replacement
of `dmd.location` that interns filenames, which makes `loc.filename is filename`
a valid identity test. The pinned fork uses stock `dmd.location`, whose `Loc` is
a `uint` index into a global line table and whose `filename` accessor returns a
pointer into that table's `BaseLoc`. That pointer is normally still identical
for one file, but nothing guarantees it (a `#line` substitution or a second
`BaseLoc` for the same path would break it), so every upstream
`loc.filename is filename` became $(REF sameFilename, sparkles,dmd_lsp,visitor):
the pointer compare first, a content compare as fallback. Likewise upstream's
`mod.srcfile.toString().toLocFilename.ptr` became
$(REF locFilename, sparkles,dmd_lsp,visitor).

$(H2 Other deviations)

$(LIST
    * `stdext`'s `TypeReferenceKind`, `DenseSet` and `contains` are vendored
        into $(MREF sparkles,dmd_lsp,support) rather than imported.
    * `Array.dim` is deprecated in the fork, so the ~30 length reads became
        `.length` (`TypeSArray.dim`, which is a dimension $(I expression),
        is untouched).
    * `findTipData` has no upstream counterpart: it is `findTip`'s query with
        the structured `TipData` returned instead of the rendered string.
    * `IdentifierTypesVisitor` was lifted out of `findIdentifierTypes` to
        module scope, and its recording sites funnel through one overridable
        `record` seam that also carries the object a tip query would resolve
        at that position. The base class ignores it, so `findIdentifierTypes`
        is unchanged; $(REF collectTips, sparkles,dmd_lsp,visitor) — also not
        upstream — overrides the seam to answer "tip every identifier" in one
        walk instead of one walk per identifier.
)

Everything else is ported, including the three functions that only serve
Visual D's editor chrome (`getModuleOutline`, `findBinaryIsInLocations`,
`findParameterStorageClass`) — they carry no extra dependencies, and keeping
them lets the file be diffed against upstream wholesale.
*/
module sparkles.dmd_lsp.visitor;

import sparkles.dmd_lsp.signature : renderSignature, SignatureInfo;
import sparkles.dmd_lsp.support : contains, DenseSet, TypeReferenceKind;
import dmd.access;
import dmd.aggregate;
import dmd.aliasthis;
import dmd.arraytypes;
import dmd.astenums;
import dmd.attrib;
import dmd.ast_node;
import dmd.builtin;
import dmd.cond;
import dmd.console;
import dmd.dclass;
import dmd.declaration;
import dmd.denum;
import dmd.dimport;
import dmd.dinterpret;
import dmd.dmodule;
import dmd.dscope;
import dmd.dstruct;
import dmd.dsymbol;
import dmd.dsymbolsem;
import dmd.dtemplate;
import dmd.templatesem;
import dmd.errors;
import dmd.expression;
import dmd.expressionsem;
import dmd.func;
import dmd.globals;
import dmd.hdrgen;
import dmd.id;
import dmd.identifier;
import dmd.init;
import dmd.location;
import dmd.mtype;
import dmd.objc;
import dmd.visitor.postorder;
import dmd.semantic2;
import dmd.semantic3;
import dmd.statement;
import dmd.staticassert;
import dmd.target;
import dmd.tokens;
import dmd.typesem;
import dmd.visitor;

import dmd.common.charactertables;
import dmd.common.outbuffer;
import dmd.root.file;
import dmd.root.filename;
import dmd.root.rmem;
import dmd.rootobject;

import std.algorithm;
import std.string;
import std.conv;
import std.functional;
import core.stdc.string;

/**
Whether two `Loc` filenames name the same file.

The port's one substantive deviation (see the module header): upstream relies
on interned filenames and compares pointers, which stock `dmd.location` does
not promise. The pointer test stays as the fast path.
*/
bool sameFilename(const(char)* a, const(char)* b) nothrow @nogc
{
    if (a is b)
        return true;
    if (a is null || b is null)
        return false;
    return strcmp(a, b) == 0;
}

/// Whether `loc` points into `filename`. Replaces upstream's
/// `loc.filename is filename`.
bool inFile(const ref Loc loc, const(char)* filename) nothrow
{
    return sameFilename(loc.filename, filename);
}

/// The filename pointer positional queries match `Loc`s against. Replaces
/// upstream's `mod.srcfile.toString().toLocFilename.ptr`, which interned the
/// name through Visual D's `dmdlocation.d`.
const(char)* locFilename(Module mod) nothrow
{
    return mod.srcfile.toChars();
}

// walk the complete AST (declarations, statement and expressions)
// assumes being started on module/declaration level
extern(C++) class ASTVisitor : StoppableVisitor
{
    bool unconditional; // take both branches in conditional declarations/statements

    alias visit = StoppableVisitor.visit;

    DenseSet!ASTNode visited;

    void visitRecursive(T)(T node)
    {
        if (stop || !node || visited.contains(node))
            return;

        visited.insert(node);

        if (walkPostorder(node, this))
            stop = true;
    }

    void visitExpression(Expression expr)
    {
        visitRecursive(expr);
    }

    void visitStatement(Statement stmt)
    {
        visitRecursive(stmt);
    }

    void visitDeclaration(Dsymbol sym)
    {
        if (stop || !sym)
            return;

        sym.accept(this);
    }

    void visitParameter(Parameter p, Declaration decl)
    {
        visitType(p.parsedType);
        visitExpression(p.defaultArg);
        if (p.userAttribDecl)
            visit(p.userAttribDecl);
    }

    // default to being permissive
    override void visit(Parameter p)
    {
        visitParameter(p, null);
    }
    override void visit(TemplateParameter) {}

    // expressions
    override void visit(Expression expr)
    {
        if (expr.original && expr.original != expr)
            visitExpression(expr.original);
    }

    override void visit(ErrorExp errexp)
    {
        visit(cast(Expression)errexp);
    }

    override void visit(CastExp expr)
    {
        visitType(expr.parsedTo);
        if (expr.parsedTo != expr.to)
            visitType(expr.to);
        super.visit(expr);
    }

    override void visit(IsExp ie)
    {
        // TODO: has ident
        if (ie.targ)
            ie.targ.accept(this);
        if (ie.originaltarg && ie.originaltarg !is ie.targ)
            ie.originaltarg.accept(this);

        visit(cast(Expression)ie);
    }

    override void visit(DeclarationExp expr)
    {
        visitDeclaration(expr.declaration);
        visit(cast(Expression)expr);
    }

    override void visit(TypeExp expr)
    {
        visitType(expr.type);
        visit(cast(Expression)expr);
    }

    override void visit(FuncExp expr)
    {
        visitDeclaration(expr.fd);
        visitDeclaration(expr.td);

        visit(cast(Expression)expr);
    }

    override void visit(NewExp ne)
    {
        if (ne.member)
            ne.member.accept(this);

        visitType(ne.parsedType);
        if (ne.newtype != ne.parsedType)
            visitType(ne.newtype);

        super.visit(ne);
    }

    override void visit(ScopeExp expr)
    {
        if (auto ti = expr.sds.isTemplateInstance())
            visitTemplateInstance(ti);
        super.visit(expr);
    }

    override void visit(TraitsExp te)
    {
        if (te.args)
        {
            foreach(a; (*te.args))
                if (auto t = a.isType())
                    visitType(t);
                else if (auto e = a.isExpression())
                    visitExpression(e);
                //else if (auto s = a.isSymbol())
                //    visitSymbol(s);
        }

        super.visit(te);
    }

    void visitTemplateInstance(TemplateInstance ti)
    {
        if (ti.tiargs && ti.parsedArgs)
        {
            size_t args = min(ti.tiargs.length, ti.parsedArgs.length);
            for (size_t a = 0; a < args; a++)
                if (Type tip = (*ti.parsedArgs)[a].isType())
                    visitType(tip);
        }
    }

    // types
    void visitType(Type type)
    {
        if (type)
            type.accept(this);
    }

    override void visit(Type t)
    {
    }

    override void visit(TypeSArray tsa)
    {
        visitExpression(tsa.dim);
        super.visit(tsa);
    }

    override void visit(TypeAArray taa)
    {
        if (taa.resolvedTo)
            visitType(taa.resolvedTo);
        else
        {
            visitType(taa.index);
            super.visit(taa);
        }
    }

    override void visit(TypeNext tn)
    {
        visitType(tn.next);
        super.visit(tn);
    }

    override void visit(TypeFunction tf)
    {
        // Not upstream. A function type's parameters hang off its parameter
        // list, not the `next` chain `TypeNext` follows, so this walk reached
        // only the return type. `visit(FuncDeclaration)` compensates for a
        // declared function, but a function type written anywhere else had no
        // tips at all on the identifiers inside it: hovering `S`, `s` or `n`
        // in `alias F = void function(in S s, int n);` answered nothing while
        // the same spellings resolved everywhere else in the file.
        if (auto params = tf.parameterList.parameters)
            foreach (p; *params)
                if (!stop && p !is null)
                    p.accept(this);
        visit(cast(TypeNext) tf);
    }

    override void visit(TypeTypeof t)
    {
        visitExpression(t.exp);
        super.visit(t);
    }

    // symbols
    override void visit(Dsymbol) {}

    override void visit(ScopeDsymbol scopesym)
    {
        super.visit(scopesym);

        // optimize to only visit members in approriate source range
        size_t mcnt = scopesym.members ? scopesym.members.length : 0;
        for (size_t m = 0; !stop && m < mcnt; m++)
        {
            Dsymbol s = (*scopesym.members)[m];
            s.accept(this);
        }
    }

    // declarations
    override void visit(VarDeclaration decl)
    {
        visitType(decl.parsedType);
        if (decl.originalType != decl.parsedType)
            visitType(decl.originalType);
        if (decl.type != decl.originalType && decl.type != decl.parsedType)
            visitType(decl.type); // not yet semantically analyzed (or a template declaration)

        visit(cast(Declaration)decl);

        if (!stop && decl._init)
            decl._init.accept(this);
    }

    override void visit(AliasDeclaration ad)
    {
        visitType(ad.originalType);
        super.visit(ad);
    }

    override void visit(AliasAssign aa)
    {
        if (aa.type)
            visitType(aa.type);
        super.visit(aa);
    }

    override void visit(AttribDeclaration decl)
    {
        visit(cast(Declaration)decl);

        if (!stop)
        {
            if (unconditional)
            {
                if (decl.decl)
                    foreach(d; *decl.decl)
                        if (!stop)
                            d.accept(this);
            }
            else
            {
                auto oldErrors = decl.errors;
                scope(exit) decl.errors = oldErrors;
                decl.errors = false; // ignore errors on members
                if (auto inc = decl.include(null))
                    foreach(d; *inc)
                        if (!stop)
                            d.accept(this);
            }
        }
    }

    override void visit(UserAttributeDeclaration decl)
    {
        if (decl.atts)
            foreach(e; *decl.atts)
                visitExpression(e);

        super.visit(decl);
    }

    override void visit(ConditionalDeclaration decl)
    {
        if (!stop && decl.condition)
            decl.condition.accept(this);

        visit(cast(AttribDeclaration)decl);

        if (!stop && unconditional && decl.elsedecl)
            foreach(d; *decl.elsedecl)
                if (!stop)
                    d.accept(this);
    }

    override void visit(FuncDeclaration decl)
    {
        visit(cast(Declaration)decl);

        // function declaration only
        if (auto tf = decl.type ? decl.type.isTypeFunction() : null)
        {
            if (tf.parameterList.parameters)
                foreach(i, p; *tf.parameterList.parameters)
                    if (!stop)
                    {
                        if (decl.parameters && i < decl.parameters.length)
                            visitParameter(p, (*decl.parameters)[i]);
                        else
                            p.accept(this);
                    }
        }
        else if (decl.parameters)
        {
            foreach(p; *decl.parameters)
                if (!stop)
                    p.accept(this);
        }

        if (decl.frequires)
            foreach(s; *decl.frequires)
                visitStatement(s);
        if (decl.fensures)
            foreach(e; *decl.fensures)
                visitStatement(e.ensure); // TODO: check result ident

        visitStatement(decl.frequire);
        visitStatement(decl.fensure);
        visitStatement(decl.fbody);
    }

    override void visit(ClassDeclaration cd)
    {
        if (cd.baseclasses)
            foreach (bc; *(cd.baseclasses))
                visitType(bc.parsedType);

        super.visit(cd);
    }

    // condition
    override void visit(Condition) {}

    override void visit(StaticIfCondition cond)
    {
        visitExpression(cond.exp);
        visit(cast(Condition)cond);
    }

    // initializer
    override void visit(Initializer) {}

    override void visit(ExpInitializer einit)
    {
        visitExpression(einit.exp);
    }

    override void visit(VoidInitializer vinit)
    {
    }

    override void visit(ErrorInitializer einit)
    {
        if (einit.original)
            einit.original.accept(this);
    }

    override void visit(StructInitializer sinit)
    {
        foreach (i, const id; sinit.field)
            if (auto iz = sinit.value[i])
                iz.accept(this);
    }

    override void visit(ArrayInitializer ainit)
    {
        foreach (i, ex; ainit.index)
        {
            if (ex)
                ex.accept(this);
            if (auto iz = ainit.value[i])
                iz.accept(this);
        }
    }

    // statements
    override void visit(Statement stmt)
    {
        if (stmt.original)
            visitStatement(stmt.original);
    }

    override void visit(ExpStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(ConditionalStatement stmt)
    {
        if (!stop && stmt.condition)
        {
            stmt.condition.accept(this);

            if (unconditional)
            {
                visitStatement(stmt.ifbody);
                visitStatement(stmt.elsebody);
            }
            else if (stmt.condition.include(null))
                visitStatement(stmt.ifbody);
            else
                visitStatement(stmt.elsebody);
        }
        visit(cast(Statement)stmt);
    }

    override void visit(MixinStatement stmt)
    {
        if (stmt.exps)
            foreach(e; *stmt.exps)
                if (!stop)
                    e.accept(this);
        visit(cast(Statement)stmt);
    }

    override void visit(WhileStatement stmt)
    {
        visitExpression(stmt.condition);
        visit(cast(Statement)stmt);
    }

    override void visit(DoStatement stmt)
    {
        visitExpression(stmt.condition);
        visit(cast(Statement)stmt);
    }

    override void visit(ForStatement stmt)
    {
        visitExpression(stmt.condition);
        visitExpression(stmt.increment);
        visit(cast(Statement)stmt);
    }

    override void visit(ForeachStatement stmt)
    {
        if (stmt.parameters)
            foreach(p; *stmt.parameters)
                if (!stop)
                    p.accept(this);
        visitExpression(stmt.aggr);
        visit(cast(Statement)stmt);
    }

    override void visit(ForeachRangeStatement stmt)
    {
        if (!stop && stmt.param)
            stmt.param.accept(this);
        visitExpression(stmt.lwr);
        visitExpression(stmt.upr);
        visit(cast(Statement)stmt);
    }

    override void visit(IfStatement stmt)
    {
        // prm converted to DeclarationExp as part of condition
        //if (!stop && stmt.prm)
        //    stmt.prm.accept(this);
        visitExpression(stmt.condition);
        visit(cast(Statement)stmt);
    }

    override void visit(PragmaStatement stmt)
    {
        if (!stop && stmt.args)
            foreach(a; *stmt.args)
                if (!stop)
                    a.accept(this);
        visit(cast(Statement)stmt);
    }

    override void visit(StaticAssertStatement stmt)
    {
        visitExpression(stmt.sa.exp);
        if (stmt.sa.msgs)
            foreach(e; *stmt.sa.msgs)
                visitExpression(e);
        visit(cast(Statement)stmt);
    }

    override void visit(SwitchStatement stmt)
    {
        visitExpression(stmt.condition);
        visit(cast(Statement)stmt);
        if (stmt.cases)
            foreach(s; *stmt.cases)
                visitStatement(s);
    }

    override void visit(CaseStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(CaseRangeStatement stmt)
    {
        visitExpression(stmt.first);
        visitExpression(stmt.last);
        visit(cast(Statement)stmt);
    }

    override void visit(GotoCaseStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(ReturnStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(SynchronizedStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(WithStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(TryCatchStatement stmt)
    {
        // variables not looked at by PostorderStatementVisitor
        if (!stop && stmt.catches)
            foreach(c; *stmt.catches)
            {
                if (c.var)
                    visitDeclaration(c.var);
                else
                    visitType(c.parsedType);
            }

        visit(cast(Statement)stmt);
    }

    override void visit(ThrowStatement stmt)
    {
        visitExpression(stmt.exp);
        visit(cast(Statement)stmt);
    }

    override void visit(ImportStatement stmt)
    {
        if (!stop && stmt.imports)
            foreach(i; *stmt.imports)
                visitDeclaration(i);
        visit(cast(Statement)stmt);
    }
}

Loc endLocation(Statement s)
{
    Loc endloc;
    if (auto ss = s.isScopeStatement())
        endloc = ss.endloc;
    else if (auto ws = s.isWhileStatement())
        endloc = ws.endloc;
    else if (auto ds = s.isDoStatement())
        endloc = ds.endloc;
    else if (auto fs = s.isForStatement())
        endloc = fs.endloc;
    else if (auto fs = s.isForeachStatement())
        endloc = fs.endloc;
    else if (auto fs = s.isForeachRangeStatement())
        endloc = fs.endloc;
    else if (auto ifs = s.isIfStatement())
        endloc = ifs.endloc;
    else if (auto ws = s.isWithStatement())
        endloc = ws.endloc;
    return endloc;
}

extern(C++) class FindASTVisitor : ASTVisitor
{
    const(char*) filename;
    int startLine;
    int startIndex;
    int endLine;
    int endIndex;

    alias visit = ASTVisitor.visit;
    RootObject found;
    ScopeDsymbol foundScope;

    this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
    {
        this.filename = filename;
        this.startLine = startLine;
        this.startIndex = startIndex;
        this.endLine = endLine;
        this.endIndex = endIndex;
    }

    void foundNode(RootObject obj)
    {
        if (obj)
        {
            found = obj;
            // do not stop until the scope is also set
        }
    }

    void checkScope(ScopeDsymbol sc)
    {
        if (found && sc && !foundScope)
        {
            foundScope = sc;
            stop = true;
        }
    }

    bool foundExpr(Expression expr)
    {
        if (auto se = expr.isScopeExp())
            foundNode(se.sds);
        else if (auto ve = expr.isVarExp())
            foundNode(ve.var);
        else if (auto te = expr.isTypeExp())
            foundNode(te.type);
        else
            return false;
        return true;
    }

    bool foundResolved(Expression expr)
    {
        if (!expr)
            return false;
        CommaExp ce;
        while ((ce = expr.isCommaExp()) !is null)
        {
            if (foundExpr(ce.e1))
                return true;
            expr = ce.e2;
        }
        return foundExpr(expr);
    }

    bool matchIdentifier(ref const Loc loc, Identifier ident)
    {
        if (ident)
            if (inFile(loc, filename))
                if (loc.linnum == startLine && loc.linnum == endLine)
                    if (loc.charnum <= startIndex && loc.charnum + ident.toString().length >= endIndex)
                        return true;
        return false;
    }

    bool matchDotIdentifier(ref const Loc dotloc, ref const Loc loc, Identifier ident)
    {
        if (!dotloc.filename)
            return matchIdentifier(loc, ident);
        if (ident)
            if (inFile(loc, filename))
                if (dotloc.linnum < startLine ||
                    (dotloc.linnum == startLine && dotloc.charnum < startIndex))
                    if ((loc.linnum == endLine && loc.charnum + ident.toString().length >= endIndex) ||
                        loc.linnum > endLine)
                        return true;
        return false;
    }

    extern(D) bool visitPackages(Module mod, IdentifierAtLoc[] packages)
    {
        if (!mod || !packages)
            return false;

        Package pkg = mod.parent ? mod.parent.isPackage() : null;
        for (size_t p; pkg && p < packages.length; p++)
        {
            size_t q = packages.length - 1 - p;
            if (!found && matchIdentifier(packages[q].loc, packages[q].ident))
            {
                foundNode(pkg);
                return true;
            }
            pkg = pkg.parent ? pkg.parent.isPackage() : null;
        }
        return false;
    }

    bool matchLoc(ref const(Loc) loc, int len)
    {
        if (inFile(loc, filename))
            if (loc.linnum == startLine && loc.linnum == endLine)
                if (loc.charnum <= startIndex && loc.charnum + len >= endIndex)
                    return true;
        return false;
    }

    override void visit(Dsymbol sym)
    {
        if (sym.isFuncLiteralDeclaration())
            return;
        if (!found && matchIdentifier(sym.loc, sym.ident))
            foundNode(sym);
    }

    override void visit(StaticAssert sa)
    {
        visitExpression(sa.exp);
        if (sa.msgs)
            foreach(e; *sa.msgs)
                visitExpression(e);
        super.visit(sa);
    }

    override void visitParameter(Parameter sym, Declaration decl)
    {
        super.visitParameter(sym, decl);
        if (!found && matchIdentifier(sym.ident.loc, sym.ident))
            foundNode(decl ? decl : sym);
    }

    override void visit(Module mod)
    {
        if (mod.md)
        {
            visitPackages(mod, mod.md.packages);

            if (!found && matchIdentifier(mod.md.loc, mod.md.id))
                foundNode(mod);
        }
        visit(cast(Package)mod);
    }

    override void visit(Import imp)
    {
        visitPackages(imp.mod, imp.packages);

        if (!found && matchIdentifier(imp.loc, imp.id))
            foundNode(imp.mod);

        for (int n = 0; !found && n < imp.names.length && n < imp.aliasdecls.length; n++)
            if (matchIdentifier(imp.names[n].loc, imp.names[n].ident) ||
                matchIdentifier(imp.aliases[n].loc, imp.aliases[n].ident))
                foundNode(imp.aliasdecls[n]);

        // symbol has ident of first package, so don't forward
    }

    override void visit(DVCondition cond)
    {
        if (!found && matchIdentifier(cond.loc, cond.ident))
            foundNode(cond);
    }

    override void visit(AliasAssign aa)
    {
        if (!found && matchIdentifier(aa.loc, aa.ident))
            foundNode(aa);
        if (aa.type)
            super.visit(aa);
        if (aa.aliassym)
            super.visit(aa.aliassym);
    }

    override void visit(Expression expr)
    {
        super.visit(expr);
    }

    override void visit(CompoundStatement cs)
    {
        // optimize to only visit members in approriate source range
        size_t scnt = cs.statements ? cs.statements.length : 0;
        for (size_t i = 0; i < scnt && !stop; i++)
        {
            Statement s = (*cs.statements)[i];
            if (!s)
                continue;
            if (visited.contains(s))
                continue;

            if (s.loc.filename)
            {
                if (!inFile(s.loc, filename) || s.loc.linnum > endLine)
                    continue;
                Loc endloc = endLocation(s);
                if (endloc.filename && endloc.linnum < startLine)
                    continue;
            }
            s.accept(this);
        }
        visit(cast(Statement)cs);
    }

    override void visit(ScopeDsymbol scopesym)
    {
        // optimize to only visit members in approriate source range
        // unfortunately, some members don't have valid locations
        size_t mcnt = scopesym.members ? scopesym.members.length : 0;
        for (size_t m = 0; m < mcnt && !stop; m++)
        {
            Dsymbol s = (*scopesym.members)[m];
            if (s.isTemplateInstance)
                continue;
            if (s.loc.filename)
            {
                if (!inFile(s.loc, filename) || s.loc.linnum > endLine)
                    continue;
                Loc endloc;
                if (auto fd = s.isFuncDeclaration())
                    endloc = fd.endloc;
                if (endloc.filename && endloc.linnum < startLine)
                    continue;
            }
            s.accept(this);
        }
        checkScope(scopesym);
    }

    override void visit(ScopeStatement ss)
    {
        visit(cast(Statement)ss);
        checkScope(ss.scopesym);
    }

    override void visit(ForStatement fs)
    {
        visit(cast(Statement)fs);
        checkScope(fs.scopesym);
    }

    override void visit(TemplateInstance ti)
    {
        // skip members added by semantic
        visit(cast(ScopeDsymbol)ti);
    }

    override void visit(TemplateDeclaration td)
    {
        if (!found && td.ident)
            if (matchIdentifier(td.loc, td.ident))
                foundNode(td);

        auto instances = cast(TemplateInstance[TemplateInstanceBox])td.instances;
        foreach(ti; instances)
            if (!stop)
                visit(ti);

        visit(cast(ScopeDsymbol)td);
    }

    override void visitTemplateInstance(TemplateInstance ti)
    {
        if (!found && ti.name)
            if (matchIdentifier(ti.loc, ti.name))
                foundNode(ti);

        super.visitTemplateInstance(ti);
    }

    override void visit(CallExp expr)
    {
        super.visit(expr);
    }

    override void visit(SymbolExp expr)
    {
        if (!found && expr.var)
            if (matchIdentifier(expr.loc, expr.var.ident))
                foundNode(expr);
        super.visit(expr);
    }

    override void visit(IdentifierExp expr)
    {
        if (!found && expr.ident)
        {
            if (matchIdentifier(expr.loc, expr.ident))
            {
                if (expr.type)
                    foundNode(expr.type);
                else if (expr.resolvedTo)
                    foundResolved(expr.resolvedTo);
            }
        }
        visit(cast(Expression)expr);
    }

    override void visit(DotIdExp de)
    {
        if (!found)
            if (de.ident)
                if (matchDotIdentifier(de.dotloc, de.identloc, de.ident))
                {
                    if (!de.type && de.resolvedTo && !de.resolvedTo.isErrorExp())
                        foundResolved(de.resolvedTo);
                    else
                        foundNode(de);
                }
    }

    override void visit(DotExp de)
    {
        if (!found)
        {
            // '.' of erroneous DotIdExp
            if (matchLoc(de.loc, 2))
                foundNode(de);
        }
        super.visit(de);
    }

    override void visit(DotTemplateExp dte)
    {
        if (!found && dte.td && dte.td.ident)
            if (matchIdentifier(dte.identloc, dte.td.ident))
                foundNode(dte);
        super.visit(dte);
    }

    override void visit(TemplateExp te)
    {
        if (!found && te.td && te.td.ident)
            if (matchIdentifier(te.identloc, te.td.ident))
                foundNode(te);
        super.visit(te);
    }

    override void visit(DotVarExp dve)
    {
        if (!found && dve.var && dve.var.ident)
            if (matchIdentifier(dve.varloc.filename ? dve.varloc : dve.loc, dve.var.ident))
                foundNode(dve);
    }

    override void visit(EnumDeclaration ed)
    {
        if (!found && ed.ident)
            if (matchIdentifier(ed.loc, ed.ident))
                foundNode(ed);

        visit(cast(ScopeDsymbol)ed);
    }

    override void visit(AggregateDeclaration ad)
    {
        if (!found && ad.ident)
            if (matchIdentifier(ad.loc, ad.ident))
                foundNode(ad);

        visit(cast(ScopeDsymbol)ad);
    }

    override void visit(FuncDeclaration decl)
    {
        super.visit(decl);

        checkScope(decl.scopesym);

        visitType(decl.originalType);
    }

    override void visit(TypeQualified tq)
    {
        foreach (i, id; tq.idents)
        {
            RootObject obj = id;
            if (obj.dyncast() == DYNCAST.identifier)
            {
                auto ident = cast(Identifier)obj;
                if (matchIdentifier(id.loc, ident))
                    if (tq.parentScopes.length > i + 1)
                        foundNode(tq.parentScopes[i + 1]);
            }
        }
        super.visit(tq);
    }

    override void visit(TypeIdentifier otype)
    {
        if (found)
            return;

        for (TypeIdentifier ti = otype; ti; ti = ti.copiedFrom)
            if (ti.parentScopes.length)
            {
                otype = ti;
                break;
            }

        if (matchIdentifier(otype.loc, otype.ident))
        {
            if (otype.parentScopes.length > 0)
                foundNode(otype.parentScopes[0]);
            else
                foundNode(otype);
        }
        super.visit(otype);
    }

    override void visit(TypeInstance ti)
    {
        if (found)
            return;

        for (TypeInstance cti = ti; cti; cti = cti.copiedFrom)
            if (cti.parentScopes.length)
            {
                ti = cti;
                break;
            }

        if (ti.tempinst && matchIdentifier(ti.loc, ti.tempinst.name))
        {
            if (ti.parentScopes.length > 0)
                foundNode(ti.parentScopes[0]);
            return;
        }
        visitTemplateInstance(ti.tempinst);
        super.visit(ti);
    }
}

RootObject _findAST(Dsymbol sym, const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
{
    scope FindASTVisitor fav = new FindASTVisitor(filename, startLine, startIndex, endLine, endIndex);
    sym.accept(fav);

    return fav.found;
}

RootObject findAST(Module mod, int startLine, int startIndex, int endLine, int endIndex)
{
    auto filename = locFilename(mod);
    return _findAST(mod, filename, startLine, startIndex, endLine, endIndex);
}

bool isUnnamedSelectiveImportAlias(AliasDeclaration ad)
{
    if (!ad || !ad._import)
        return false;
    auto imp = ad._import.isImport();
    if (!imp)
        return false;

    for (int n = 0; n < imp.aliasdecls.length && n < imp.aliases.length; n++)
        if (ad == imp.aliasdecls[n])
            return !imp.aliases[n].ident;
    return false;
}

////////////////////////////////////////////////////////////////////////////////

extern(C++) class FindTipVisitor : FindASTVisitor
{
    string tip;

    /// Not upstream: `findTipData` wants the node, not the rendering, and
    /// `tipForObject` is the expensive half. Clearing this skips it.
    bool renderTip = true;

    alias visit = FindASTVisitor.visit;

    this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
    {
        super(filename, startLine, startIndex, endLine, endIndex);
    }

    void visitCallExpression(CallExp expr)
    {
        if (!found)
        {
            // replace function type with actual
            visitExpression(expr);
            if (found is expr.e1)
            {
                foundNode(expr);
            }
        }
    }

    override void foundNode(RootObject obj)
    {
        // Not upstream. A lowering's temporary carries the location of the
        // code it was generated from — `foreach (v; 0 .. n)` puts DMD's
        // `__limit` on `v` itself — so resolving one answers a hover with a
        // name the user never wrote. Worse, it is not even stable: which of
        // the two symbols this walk reaches first depends on their order in
        // DMD's name-hashed symbol table, and `Identifier.generateId` numbers
        // temporaries with a process-wide counter, so the same query answered
        // `v` or `__limit225` depending on what had been analyzed before.
        // Skipping them keeps the walk going and lands on the real symbol —
        // which is also what `collectTips` reports (`TipOccurrence` parity).
        if (isLoweringTemporary(obj))
            return;

        found = obj;
        if (obj)
        {
            if (renderTip)
                tip = tipForObject(obj);
            stop = true;
        }
    }
}

/**
Whether `obj` is a compiler-introduced temporary — a lowered `foreach`'s
`__limit`/`__key`, an inliner's scratch variable — rather than a declaration
the user wrote.

`STC.temp` alone is not the test: a lowered `foreach` marks the loop variable
the user *did* write with `STC.temp | STC.foreach_` too. What separates them is
the name, since every synthetic one comes from `Identifier.generateId` and so
begins with `__`.
*/
private bool isLoweringTemporary(RootObject obj)
{
    if (obj is null)
        return false;

    Dsymbol sym = obj.isDsymbol();
    if (sym is null)
        if (auto e = obj.isExpression())
            if (e.op == EXP.variable || e.op == EXP.symbolOffset)
                sym = (cast(SymbolExp) e).var;

    if (auto v = sym !is null ? sym.isVarDeclaration() : null)
        return (v.storage_class & STC.temp) != 0
            && v.ident !is null && v.ident.toString().startsWith("__");
    return false;
}

string quoteCode(bool quote, string s)
{
    if (!quote || s.empty)
        return s;
    return "`" ~ s ~ "`";
}

struct TipData
{
    string kind;
    string code;
    string doc;
    string sna; // size and aligmment
    Dsymbol symbol; // owner of `doc` when known (sparkles extension, for ddoc rendering)

    // Where `code` may break, what of it collapses, and the effects and
    // contracts lifted out of it (sparkles extension, `TIP5`). Populated for
    // functions only, whose `kind` is empty — every offset indexes `code`, so
    // anything that prefixes it (an alias) must drop this rather than carry
    // offsets that no longer point where they say.
    SignatureInfo sig;
}

string tipForObject(RootObject obj)
{
    TipData tip = tipDataForObject(obj);

    string txt;
    if (tip.kind.length)
        txt = "(" ~ tip.kind ~ ")";
    if (tip.code.length && txt.length)
        txt ~= " ";
    txt ~= quoteCode(true, tip.code);
    if (tip.doc.length && txt.length)
        txt ~= "\n\n";
    if (tip.doc.length)
        txt ~= strip(tip.doc);
    if (tip.sna.length)
        txt ~= "\n" ~ strip(tip.sna);
    return txt;
}

TipData tipForAlias(Dsymbol sym, Type t, string kind, string txt)
{
    TipData tip;
    if (sym)
        tip = tipDataForObject(sym);
    else if (t)
        tip = tipDataForObject(t);
    if (sym && tip.kind.length)
        kind = "alias " ~ tip.kind;
    if (tip.code.length)
        txt ~= " = " ~ tip.code;
    return TipData(kind, txt, "", tip.sna);
}

TipData tipForDeclaration(Declaration decl)
{
    if (auto func = decl.isFuncDeclaration())
    {
        auto fntype = decl.type ? decl.type.isTypeFunction() : null;
        auto td = fntype && decl.parent ? decl.parent.isTemplateDeclaration() : null;

        SignatureInfo info;
        if (auto text = renderSignature(decl, td, info))
            return TipData("", text, "", "", null, info);

        // No function type (or a self-referential one `renderSignature`
        // declines): the name alone, as before.
        OutBuffer buf;
        buf.writestring(decl.toPrettyChars(true));
        return TipData("", cast(string) buf.extractSlice());
    }

    bool fqn = true;
    string txt;
    string kind;
    if (decl.isParameter())
    {
        if (decl.parent)
            if (auto fd = decl.parent.isFuncDeclaration())
                if (fd.ident.toString().startsWith("__foreachbody"))
                    kind = "foreach variable";
        if (kind.empty)
            kind = "parameter";
        fqn = false;
    }
    else if (auto em = decl.isEnumMember())
    {
        kind = "enum value";
        txt = decl.toPrettyChars(fqn).to!string;
        if (em.origValue)
            txt ~= " = " ~ cast(string)em.origValue.toString();
        return TipData(kind, txt);
    }
    else if (decl.storage_class & STC.manifest)
        kind = "constant";
    else if (auto ad = decl.isAliasDeclaration())
    {
        kind = "alias";
        txt = to!string(fqn ? decl.toPrettyChars(fqn) : decl.toChars());
        return tipForAlias(ad.aliassym, ad.type, kind, txt);
    }
    else if (auto aa = decl.isAliasAssign())
    {
        kind = "alias";
        txt = to!string(fqn ? decl.toPrettyChars(fqn) : decl.toChars());
        return tipForAlias(aa.aliassym, aa.type, kind, txt);
    }
    else if (decl.isField())
        kind = "field";
    else if (decl.semanticRun >= PASS.semanticdone) // avoid lazy semantic analysis
    {
        if (!decl.isDataseg() && !decl.isCodeseg())
        {
            kind = "local variable";
            fqn = false;
        }
        else if (decl.isThreadlocal())
            kind = "thread local global";
        else if (decl.type && decl.type.isShared())
            kind = "shared global";
        else if (decl.type && decl.type.isConst())
            kind = "constant global";
        else if (decl.type && decl.type.isImmutable())
            kind = "immutable global";
        else if (decl.type && decl.type.ty != Terror)
            kind = "__gshared global";
    }

    // `@system` variables (D 2.100+) carry their marker as a storage class, not
    // in the type, so nothing in the type printer above would ever show it —
    // and "you may not touch this from @safe code" is the whole point of the
    // annotation.
    if (decl.storage_class & STC.system)
        txt ~= "@system ";
    if (decl.type)
        txt ~= to!string(decl.type.toPrettyChars(true)) ~ " ";
    txt ~= to!string(fqn ? decl.toPrettyChars(fqn) : decl.toChars());
    if (decl.storage_class & STC.manifest)
        if (auto var = decl.isVarDeclaration())
            if (var._init)
                txt ~= " = " ~ toString(var._init);
    return TipData(kind, txt);
}

bool showSizeAndAlignment = false;

string tipSizeAndAlignment(Type t)
{
    if (auto cd = t.isClassHandle())
    {
        if (cd.sizeok != Sizeok.done)
            return "";
        return "Size: " ~ to!string(cd.structsize) ~ ", Alignment: " ~ to!string(cd.alignsize);
    }
    auto sz = t.size();
    if (sz == SIZE_INVALID)
        return "";
    return "Size: " ~ to!string(sz) ~ ", Alignment: " ~ to!string(t.alignsize());
}

TipData tipForType(Type t)
{
    string kind;
    if (t.isTypeIdentifier())
        kind = "unresolved type";
    else if (auto tc = t.isTypeClass())
        kind = tc.sym.isInterfaceDeclaration() ? "interface" : "class";
    else if (auto ts = t.isTypeStruct())
        kind = ts.sym.isUnionDeclaration() ? "union" : "struct";
    else
        kind = t.kind().to!string;
    string txt = t.toPrettyChars(true).to!string;
    string doc;
    Dsymbol docSym;
    if (auto sym = typeSymbol(t))
        if (sym.comment)
        {
            doc = sym.comment.to!string;
            docSym = sym;
        }
    string sna;
    if (showSizeAndAlignment)
        sna = tipSizeAndAlignment(t);
    return TipData(kind, txt, doc, sna, docSym);
}

TipData tipForDotIdExp(DotIdExp die)
{
    auto resolvedTo = die.resolvedTo;
    bool isConstant = resolvedTo.isConstantExpr();
    bool isEnumValue = false;
    if (auto ve = resolvedTo.isVarExp())
        if (auto em = ve.var ? ve.var.isEnumMember() : null)
        {
            isConstant = isEnumValue = true;
            resolvedTo = em.origValue;
        }

    Expression e1;
    if (!isConstant && !resolvedTo.isArrayLengthExp() && die.type)
    {
        e1 = isAALenCall(resolvedTo);
        if (!e1 && die.ident == Id.ptr && resolvedTo.isCastExp())
            e1 = resolvedTo;
        if (!e1 && resolvedTo.isTypeExp())
            return tipForType(die.type);
    }
    if (!e1)
        e1 = die.e1;
    string kind = isEnumValue ? "enum value" : isConstant ? "constant" : "field";
    string tip = isEnumValue ? "" : resolvedTo.type.toPrettyChars(true).to!string ~ " ";
    tip ~= e1.type && !e1.isConstantExpr() ? die.e1.type.toPrettyChars(true).to!string : e1.toString();
    tip ~= "." ~ die.ident.toString();
    if (isConstant)
        tip ~= " = " ~ resolvedTo.toString();
    return TipData(kind, tip);
}

TipData tipForTemplate(TemplateExp te)
{
    Dsymbol ds = te.fd;
    if (!ds)
        ds = te.td.onemember ? te.td.onemember : te.td;
    string kind = ds.isFuncDeclaration() ? "template function" : "template";
    string tip = ds.toPrettyChars(true).to!string;
    return TipData(kind, tip);
}

/// Whether a doc comment is nothing but `ditto` — case-insensitive, with
/// whitespace either side (`dmd.doc.isDitto`, which is private to that module;
/// the rule is frozen by `DDC11` and is five lines, so it is restated rather
/// than patched into the fork).
private bool isDitto(const(char)* comment) @system
{
    import core.stdc.string : strlen;
    import std.ascii : toLower;
    import std.string : strip;

    if (comment is null)
        return false;
    auto c = comment[0 .. strlen(comment)].strip;
    if (c.length != 5)
        return false;
    foreach (i, ch; c)
        if (ch.toLower != "ditto"[i])
            return false;
    return true;
}

/**
The comment a `/// ditto` declaration inherits: the nearest preceding sibling
with one of its own.

DMD's own resolution is a side effect of generating a documentation file — it
pushes the symbol onto the last emitted `DocComment` — so nothing about it
survives into an analysis-only run. Walking the enclosing scope's members
backwards reproduces it for the one symbol being asked about, which is all a
hover needs. Attribute blocks (`private:`, `@safe { … }`) are flattened, since
they are scopes for lookup but not for `ditto`.
*/
private const(char)[] dittoTarget(Dsymbol s) @system
{
    auto sds = s.parent !is null ? s.parent.isScopeDsymbol() : null;
    if (sds is null || sds.members is null)
        return null;

    Dsymbol[] flat;
    void flatten(Dsymbols* members)
    {
        if (members is null)
            return;
        foreach (m; *members)
        {
            if (m is null)
                continue;
            if (auto ad = m.isAttribDeclaration())
            {
                flatten(ad.decl);
                continue;
            }
            flat ~= m;
        }
    }
    flatten(sds.members);

    // A templated function is a `TemplateDeclaration` in the member list, so
    // look for whichever of the two is actually there.
    auto self = s;
    if (auto td = s.parent.isTemplateDeclaration())
        self = td;

    size_t at = size_t.max;
    foreach (i, m; flat)
        if (m is self || m is s)
        {
            at = i;
            break;
        }
    if (at == size_t.max)
        return null;

    foreach_reverse (m; flat[0 .. at])
        if (m.comment !is null && !isDitto(m.comment))
            return m.comment[0 .. strlen(m.comment)];
    return null;
}

/**
The doc comment that belongs to `var`, following the two indirections that
separate a symbol from the declaration its documentation was written on
(spec `DOC4`).

$(UL
$(LI $(B Template desugaring.) An eponymous member's comment lives on its
    `TemplateDeclaration`, and Phobos routinely nests one inside another —
    `template map(fun...) { auto map(Range)(Range r) … }` — so the instance a
    call site resolves to is two hops from the documented declaration.)
$(LI $(B Aliases.) A selective import (`import std.algorithm : map;`) makes an
    `AliasDeclaration` that carries no comment of its own; the docs are the
    target's.)
)

Only these links are walked — never a plain enclosing scope, which would hand
a local variable the docs of the function it sits in.
*/
string docForSymbol(Dsymbol var)
{
    // Bounded: alias chains and nested eponymous templates are both short in
    // practice, and a cycle here would wedge the whole analysis.
    enum maxHops = 8;

    // Collected innermost-first as the walk climbs, emitted outermost-first.
    // A member and its template each hold half of the documentation — Phobos
    // keeps `map`'s prose on `template map(fun...)` and its `Params:`/
    // `Returns:` on the eponymous `map(Range)` inside — and
    // `dmd.doc.emitComment` emits both, so stopping at the first comment found
    // showed half the docs.
    const(char)[][] found;

    static string joinOutermostFirst(const(char)[][] parts)
    {
        if (parts.length == 0)
            return null;
        string joined;
        foreach_reverse (p; parts)
        {
            if (joined.length)
                joined ~= "\n\n";
            joined ~= p.idup;
        }
        return joined;
    }

    static const(char)[] commentOf(Dsymbol s)
    {
        if (s is null || s.comment is null)
            return null;
        // `/// ditto` means "the previous declaration's docs". DMD resolves it
        // in `emitComment` via `sc.lastdc`, which this translator never runs,
        // so a ditto'd overload used to render the literal word.
        if (isDitto(s.comment))
            return dittoTarget(s);
        return s.comment[0 .. strlen(s.comment)];
    }

    // `onemember` is upstream's guard against handing an arbitrary member its
    // template's docs. It is null whenever the body holds anything else —
    // Phobos's `template map(fun...)` has a local `import` — so an eponymous
    // member (same identifier as the template) qualifies too: the comment was
    // written for exactly that declaration.
    static bool documents(TemplateDeclaration td, Dsymbol from)
        => td !is null && td.comment !is null &&
            (td.onemember !is null ||
                (from !is null && from.ident !is null && from.ident is td.ident));

    auto sym = var;
    if (auto c = commentOf(sym))
        found ~= c;

    foreach (_; 0 .. maxHops)
    {
        if (sym is null)
            break;

        if (auto ad = sym.isAliasDeclaration())
        {
            auto target = ad.aliassym !is null ? ad.aliassym : ad.toAlias();
            if (target !is null && target !is sym)
            {
                sym = target;
                if (auto c = commentOf(sym))
                    found ~= c;
                continue;
            }
        }

        auto parent = sym.parent;
        if (parent is null)
            break;

        // Only template links are followed. A plain enclosing scope would
        // hand a local variable the docs of the function it sits in.
        if (auto td = parent.isTemplateDeclaration())
        {
            if (documents(td, sym))
                found ~= commentOf(td);
            sym = td;
            continue;
        }
        if (auto ti = parent.isTemplateInstance())
        {
            auto td = ti.tempdecl !is null ? ti.tempdecl.isTemplateDeclaration() : null;
            if (documents(td, sym))
                found ~= commentOf(td);
            // The eponymous member of a nested template: step to the inner
            // declaration and let the next hop look at *its* template.
            sym = td !is null ? cast(Dsymbol) td : cast(Dsymbol) ti;
            continue;
        }
        break;
    }
    return joinOutermostFirst(found);
}

string rootObjectToString(RootObject obj)
{
    final switch (obj.dyncast())
    {
        case DYNCAST.identifier:
        case DYNCAST.dsymbol:
        case DYNCAST.type:          // https://issues.dlang.org/show_bug.cgi?id=1215
        case DYNCAST.expression:    // https://issues.dlang.org/show_bug.cgi?id=1215
        case DYNCAST.object:
        case DYNCAST.tuple:
        case DYNCAST.parameter:
        case DYNCAST.statement:
        case DYNCAST.templateparameter:
        case DYNCAST.initializer:
            return obj.toString().dup;
        case DYNCAST.condition:
            auto cond = cast(Condition)obj;
            if (auto dc = cond.isDebugCondition())
                return dc.ident.toString().dup;
            if (auto vc = cond.isVersionCondition())
                return vc.ident.toString().dup;
            assert(0);
    }
    return "";
}

TipData tipDataForObject(RootObject obj)
{
    TipData tip;
    string doc;
    Dsymbol docSym;

    if (auto t = obj.isType())
    {
        tip = tipForType(t.mutableOf().unSharedOf());
    }
    else if (auto e = obj.isExpression())
    {
        switch(e.op)
        {
            case EXP.variable:
            case EXP.symbolOffset:
                tip = tipForDeclaration((cast(SymbolExp)e).var);
                doc = docForSymbol((cast(SymbolExp)e).var);
                docSym = (cast(SymbolExp)e).var;
                break;
            case EXP.dotVariable:
                tip = tipForDeclaration((cast(DotVarExp)e).var);
                doc = docForSymbol((cast(DotVarExp)e).var);
                docSym = (cast(DotVarExp)e).var;
                break;
            case EXP.dotIdentifier:
                auto die = e.isDotIdExp();
                if (die.resolvedTo && die.resolvedTo.type)
                {
                    tip = tipForDotIdExp(die);
                    break;
                }
                goto default;
            case EXP.template_:
                tip = tipForTemplate((cast(TemplateExp)e));
                break;
            default:
                if (e.type)
                    tip = tipForType(e.type);
                break;
        }
    }
    else if (auto s = obj.isDsymbol())
    {
        if (auto imp = s.isImport())
            if (imp.mod)
                s = imp.mod;
        auto ad = s.isAliasDeclaration();
        if (isUnnamedSelectiveImportAlias(ad) && !ad.aliassym && ad.type) // selective import of type
        {
            tip = tipForType(ad.type.mutableOf().unSharedOf());
        }
        else if (auto decl = s.isDeclaration())
        {
            tip = tipForDeclaration(decl);
            doc = docForSymbol(s);
            docSym = s;
        }
        else
        {
            tip.kind = s.kind().to!string;
            tip.code = s.toPrettyChars(true).to!string;
            doc = docForSymbol(s);
            docSym = s;
        }
        if (showSizeAndAlignment)
            if (auto aggr = s.isAggregateDeclaration())
                if (auto t = aggr.type)
                    tip.sna = tipSizeAndAlignment(t);
    }
    else if (auto p = obj.isParameter())
    {
        if (auto t = p.type ? p.type : p.parsedType)
            tip.code = t.toPrettyChars(true).to!string;
        if (p.ident && tip.code.length)
            tip.code ~= " ";
        if (p.ident)
            tip.code ~= p.ident.toString;
        tip.kind = "parameter";
    }
    if (!tip.code.length)
    {
        tip.code = rootObjectToString(obj);
    }
    // append doc; the symbol is kept even without one (the facade resolves a
    // parameter's docs from its enclosing function's Params: section)
    if (doc.length)
        tip.doc = doc;
    if (docSym !is null)
        tip.symbol = docSym;
    return tip;
}

static const(char)* printSymbolWithLink(Dsymbol sym, bool qualifyTypes)
{
    const(char)* s = qualifyTypes ? sym.toPrettyCharsHelper() : sym.toChars();

    if (auto ti = sym.isTemplateInstance())
        if (ti.tempdecl)
            if (auto td = ti.tempdecl.isTemplateDeclaration())
                sym = td.onemember ? td.onemember : td;

    if (!sym.loc.filename)
        return s;

    import dmd.root.string : toDString;
    import dmd.root.utf;
    auto str = s.toDString();
    size_t p = 0;
    while (p < str.length)
    {
        char c = str[p];
        if (c < 0x80)
        {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'))
                break;
            p++;
        }
        else
        {
            dchar dch;
            size_t pos = p;
            if (utf_decodeChar(str, pos, dch) !is null)
                break;
            if (!isAnyIdentifierCharacter(dch))
                break;
            p = pos;
        }
    }
    OutBuffer lnkbuf;
    lnkbuf.writestring("#<");
    lnkbuf.writestring(str[0..p]);
    lnkbuf.writeByte('#');
    lnkbuf.writestring(sym.loc.filename);
    if (sym.loc.linnum > 0) // no lineno for modules
    {
        lnkbuf.writeByte(',');
        lnkbuf.print(sym.loc.linnum);
        lnkbuf.writeByte(',');
        lnkbuf.print(sym.loc.charnum);
    }
    lnkbuf.writestring("#>");
    lnkbuf.writestring(str[p..$]);
    return lnkbuf.extractChars();
}

string findTip(Module mod, int startLine, int startIndex, int endLine, int endIndex, bool addlinks, bool addsize)
{
    auto old = Dsymbol.prettyPrintSymbolHandler;
    if (addlinks)
        Dsymbol.prettyPrintSymbolHandler = toDelegate(&printSymbolWithLink);
    scope(exit) Dsymbol.prettyPrintSymbolHandler = old;
    showSizeAndAlignment = addsize;
    scope(exit) showSizeAndAlignment = false; // tips also used by findExpansions

    auto filename = locFilename(mod);
    scope FindTipVisitor ftv = new FindTipVisitor(filename, startLine, startIndex, endLine, endIndex);
    mod.accept(ftv);

    return ftv.tip;
}

// Not upstream: findTip's query with the structured TipData kept instead of
// tipForObject's rendering, so callers (sparkles.dmd_lsp.api.AnalyzedModule.tipAt)
// need not re-parse "(kind) `code`\n\ndoc" back apart. `addlinks` has no
// counterpart here — the `#<...#>` markup it injects is Visual D's tooltip
// hyperlink syntax, which only makes sense in the rendered string.
TipData findTipData(Module mod, int startLine, int startIndex, int endLine, int endIndex, bool addsize)
{
    showSizeAndAlignment = addsize;
    scope(exit) showSizeAndAlignment = false; // tips also used by findExpansions

    auto filename = locFilename(mod);
    scope FindTipVisitor ftv = new FindTipVisitor(filename, startLine, startIndex, endLine, endIndex);
    ftv.renderTip = false; // the string form is discarded here; don't build it
    mod.accept(ftv);

    return ftv.found ? tipDataForObject(ftv.found) : TipData.init;
}

////////////////////////////////////////////////////////////////

extern(C++) class FindDefinitionVisitor : FindASTVisitor
{
    Loc loc;

    alias visit = FindASTVisitor.visit;

    this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
    {
        super(filename, startLine, startIndex, endLine, endIndex);
    }

    override void foundNode(RootObject obj)
    {
        found = obj;
        while (obj) // resolving aliases
        {
            if (auto t = obj.isType())
            {
                if (auto sym = typeSymbol(t))
                    loc = sym.loc;
            }
            else if (auto e = obj.isExpression())
            {
                switch(e.op)
                {
                    case EXP.variable:
                    case EXP.symbolOffset:
                        loc = (cast(SymbolExp)e).var.loc;
                        break;
                    case EXP.dotVariable:
                        loc = (cast(DotVarExp)e).var.loc;
                        break;
                    default:
                        loc = e.loc;
                        break;
                }
            }
            else if (auto s = obj.isDsymbol())
            {
                auto ad = s.isAliasDeclaration();
                if (ad && ad._import) // selective import
                {
                    if (ad.aliassym)
                    {
                        found = obj = ad.aliassym;
                        continue;
                    }
                    else if (ad.type)
                    {
                        found = obj = ad.type;
                        continue;
                    }
                }
                if (!s.loc.isValid())
                {
                    if (auto td = s.isTemplateDeclaration())
                    {
                        if (td.onemember)
                        {
                            found = obj = td.onemember;
                            continue;
                        }
                    }
                }
                loc = s.loc;
            }
            break;
        }
    }
}

string findDefinition(Module mod, ref int line, ref int index)
{
    auto filename = locFilename(mod);
    scope FindDefinitionVisitor fdv = new FindDefinitionVisitor(filename, line, index, line, index + 1);
    mod.accept(fdv);

    if (!fdv.loc.filename)
        return null;
    line = fdv.loc.linnum;
    index = fdv.loc.charnum;
    return to!string(fdv.loc.filename);
}

////////////////////////////////////////////////////////////////////////////////

Loc[] findBinaryIsInLocations(Module mod)
{
    extern(C++) class BinaryIsInVisitor : ASTVisitor
    {
        Loc[] locdata;
        const(char)* filename;

        alias visit = ASTVisitor.visit;

        final void addLocation(const ref Loc loc)
        {
            if (inFile(loc, filename))
                locdata ~= loc;
        }

        override void visit(InExp e)
        {
            addLocation(e.oploc);
            super.visit(e);
        }
        override void visit(IdentityExp e)
        {
            addLocation(e.oploc);
            super.visit(e);
        }
    }

    scope BinaryIsInVisitor biiv = new BinaryIsInVisitor;
    biiv.filename = locFilename(mod);
    biiv.unconditional = true;
    mod.accept(biiv);

    return biiv.locdata;
}

////////////////////////////////////////////////////////////////////////////////
struct IdTypePos
{
    int type;
    int line;
    int col;
}

alias FindIdentifierTypesResult = IdTypePos[][const(char)[]];

/**
The identifier-classification walk behind `findIdentifierTypes`.

$(B Deviation:) upstream nests this class inside `findIdentifierTypes`. It is
lifted to module scope here so `TipCollectVisitor` can derive from it, and its
~25 recording sites were funnelled through one overridable seam, `record`,
which each site now also hands the $(I object) $(REF FindASTVisitor,
sparkles,dmd_lsp,visitor) would have resolved at that position (`null` where
there is no counterpart). The base class ignores that object and behaves
exactly as upstream, so `findIdentifierTypes`' result is unchanged.
*/
extern(C++) class IdentifierTypesVisitor : ASTVisitor
{
    FindIdentifierTypesResult idTypes;
    const(char)* filename;

    alias visit = ASTVisitor.visit;

    extern(D)
    final void addTypePos(const(char)[] ident, int type, int line, int col)
    {
        if (line <= 0)
            return; // not visible
        if (auto pid = ident in idTypes)
        {
            // merge sorted
            import std.range;
            auto a = assumeSorted!"a.line < b.line || (a.line == b.line && a.col < b.col)"(*pid);
            auto itp = IdTypePos(type, line, col);
            auto sections = a.trisect(itp);
            if (!sections[1].empty)
            {} // do not overwrite identical location
            else if (!sections[2].empty && sections[2][0].type == type) // upperbound
                sections[2][0] = itp; // extend lowest location
            else if (sections[0].empty || sections[0][$-1].type != type) // lowerbound
                // insert new entry if last lower location is different type
                *pid = (*pid)[0..sections[0].length] ~ itp ~ (*pid)[sections[0].length..$];
        }
        else
            idTypes[ident] = [IdTypePos(type, line, col)];
    }

    /**
    The one place every recording site funnels through (not upstream).

    `obj` is what a positional tip query at `loc` would have resolved to —
    see the class docs. The base class records the classification only, which
    is what upstream does inline at each site.
    */
    protected void record(ref const Loc loc, Identifier ident, int type, RootObject obj)
    {
        addTypePos(ident.toString(), type, loc.linnum, loc.charnum);
    }

    void addIdent(ref const Loc loc, Identifier ident, int type, RootObject obj = null)
    {
        if (ident && inFile(loc, filename))
            record(loc, ident, type, obj);
    }

    void addIdentByType(ref const Loc loc, Identifier ident, Type t, RootObject obj = null)
    {
        if (ident && t && inFile(loc, filename))
        {
            int type = TypeReferenceKind.Unknown;
            switch (t.ty)
            {
                case Tstruct:   type = TypeReferenceKind.Struct; break;
                //case Tunion:  type = TypeReferenceKind.Union; break;
                case Tclass:    type = TypeReferenceKind.Class; break;
                case Tenum:     type = TypeReferenceKind.Enum; break;
                default: break;
            }
            if (type != TypeReferenceKind.Unknown)
                record(loc, ident, type, obj);
        }
    }

    // `mod` (not upstream) is the module the packages qualify, so each package
    // identifier can carry the `Package` FindASTVisitor.visitPackages resolves
    // it to — that walk pairs the *last* package with `mod`'s parent and works
    // outwards, while the recording order stays upstream's (first to last).
    extern(D) void addPackages(IdentifierAtLoc[] packages, Dsymbol mod = null)
    {
        if (packages)
            for (size_t p; p < packages.length; p++)
            {
                Package pkg = mod && mod.parent ? mod.parent.isPackage() : null;
                foreach (_; p .. packages.length - 1)
                    pkg = pkg && pkg.parent ? pkg.parent.isPackage() : null;
                addIdent(packages[p].loc, packages[p].ident, TypeReferenceKind.Package, pkg);
            }
    }

    void addDeclaration(ref const Loc loc, Declaration decl, RootObject obj = null)
    {
        auto ident = decl.ident;
        if (auto func = decl.isFuncDeclaration())
        {
            if (func.isFuncLiteralDeclaration())
                return; // ignore generated identifiers
            auto p = decl.toParent2;
            if (p && p.isAggregateDeclaration)
                addIdent(loc, ident, TypeReferenceKind.Method, obj);
            else
                addIdent(loc, ident, TypeReferenceKind.Function, obj);
        }
        else if (decl.isParameter())
            addIdent(loc, ident, TypeReferenceKind.ParameterVariable, obj);
        else if (decl.isEnumMember())
            addIdent(loc, ident, TypeReferenceKind.EnumValue, obj);
        else if (decl.storage_class & STC.manifest)
            addIdent(loc, ident, TypeReferenceKind.Constant, obj);
        else if (auto ad = decl.isAliasDeclaration())
        {
            if (isUnnamedSelectiveImportAlias(ad) && !ad.aliassym && ad.type)
                addIdentByType(loc, ident, ad.type, obj);
            else
                addIdent(loc, ident, TypeReferenceKind.Alias, obj);
        }
        else if (decl.isField())
            addIdent(loc, ident, TypeReferenceKind.MemberVariable, obj);
        else if (!decl.isDataseg() && !decl.isCodeseg())
            addIdent(loc, ident, TypeReferenceKind.LocalVariable, obj);
        else if (decl.isThreadlocal())
            addIdent(loc, ident, TypeReferenceKind.TLSVariable, obj);
        else if (decl.type && decl.type.isShared())
            addIdent(loc, ident, TypeReferenceKind.SharedVariable, obj);
        else
            addIdent(loc, ident, TypeReferenceKind.GSharedVariable, obj);
    }

    override void visit(TypeQualified tid)
    {
        foreach (i, id; tid.idents)
        {
            RootObject obj = id;
            if (obj.dyncast() == DYNCAST.identifier)
            {
                auto ident = cast(Identifier)obj;
                if (tid.parentScopes.length > i + 1)
                    addObject(id.loc, tid.parentScopes[i + 1]);
            }
        }
        super.visit(tid);
    }

    override void visit(TypeIdentifier tid)
    {
        while (tid.copiedFrom)
        {
            if (tid.parentScopes.length > 0)
                break;
            tid = tid.copiedFrom;
        }
        if (tid.parentScopes.length > 0)
            addObject(tid.loc, tid.parentScopes[0]);
        super.visit(tid);
    }

    override void visit(TypeInstance tid)
    {
        if (!tid.tempinst)
            return;
        if (tid.parentScopes.length > 0)
            addObject(tid.loc, tid.parentScopes[0]);
        super.visit(tid);
    }

    void addObject(ref const Loc loc, RootObject obj)
    {
        if (auto t = obj.isType())
            visitType(t);
        else if (auto s = obj.isDsymbol())
        {
            if (auto imp = s.isImport())
                if (imp.mod)
                    s = imp.mod;
            // the tip query resolves the unsubstituted object (and repeats
            // the Import -> Module step itself), so `obj`, not `s`
            addSymbol(loc, s, obj);
        }
        else if (auto e = obj.isExpression())
            e.accept(this);
    }

    void addSymbol(ref const Loc loc, Dsymbol sym, RootObject obj = null)
    {
        if (auto decl = sym.isDeclaration())
            addDeclaration(loc, decl, obj);
        else if (sym.isUnionDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Union, obj);
        else if (sym.isStructDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Struct, obj);
        else if (sym.isInterfaceDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Interface, obj);
        else if (sym.isClassDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Class, obj);
        else if (sym.isEnumDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Enum, obj);
        else if (sym.isModule())
            addIdent(loc, sym.ident, TypeReferenceKind.Module, obj);
        else if (sym.isPackage())
            addIdent(loc, sym.ident, TypeReferenceKind.Package, obj);
        else if (sym.isTemplateDeclaration())
            addIdent(loc, sym.ident, TypeReferenceKind.Template, obj);
        else
            addIdent(loc, sym.ident, TypeReferenceKind.Variable, obj);
    }

    override void visit(Dsymbol sym)
    {
        addSymbol(sym.loc, sym, sym);
    }

    override void visitParameter(Parameter sym, Declaration decl)
    {
        super.visitParameter(sym, decl);
        addIdent(sym.ident.loc, sym.ident, TypeReferenceKind.ParameterVariable,
            decl ? decl : cast(RootObject) sym);
    }

    override void visit(Module mod)
    {
        if (mod.md)
        {
            addPackages(mod.md.packages, mod);
            addIdent(mod.md.loc, mod.md.id, TypeReferenceKind.Module, mod);
        }
        visit(cast(Package)mod);
    }

    override void visit(Import imp)
    {
        addPackages(imp.packages, imp.mod);

        addIdent(imp.loc, imp.id, TypeReferenceKind.Module, imp.mod);

        for (int n = 0; n < imp.names.length; n++)
        {
            // the tip query resolves both the imported name and its alias to
            // the selective-import AliasDeclaration
            RootObject decl = n < imp.aliasdecls.length ? imp.aliasdecls[n] : null;
            if (n < imp.aliasdecls.length && imp.aliasdecls[n].aliassym)
                addSymbol(imp.names[n].loc, imp.aliasdecls[n].aliassym, decl);
            else if (n < imp.aliasdecls.length && imp.aliasdecls[n].type)
                addIdentByType(imp.names[n].loc, imp.names[n].ident, imp.aliasdecls[n].type, decl);
            else
                addIdent(imp.names[n].loc, imp.names[n].ident, TypeReferenceKind.Alias, decl);
            if (imp.aliases[n].ident && n < imp.aliasdecls.length)
                addIdent(imp.aliases[n].loc, imp.aliases[n].ident, TypeReferenceKind.Alias, decl);
        }
        // symbol has ident of first package, so don't forward
    }

    override void visit(DebugCondition cond)
    {
        addIdent(cond.loc, cond.ident, TypeReferenceKind.VersionIdentifier, cond);
    }

    override void visit(VersionCondition cond)
    {
        addIdent(cond.loc, cond.ident, TypeReferenceKind.VersionIdentifier, cond);
    }

    override void visit(SymbolExp expr)
    {
        if (expr.var && expr.var.ident)
            addDeclaration(expr.loc, expr.var, expr);
        super.visit(expr);
    }

    void addIdentExp(Expression expr, Type t)
    {
        if (auto ie = expr.isIdentifierExp())
        {
            addIdentByType(ie.loc, ie.ident, t, identifierExpObject(ie));
        }
        else if (auto die = expr.isDotIdExp())
        {
            addIdentByType(die.ident.loc, die.ident, t, dotIdExpObject(die));
        }
    }

    void addOriginal(Expression expr, Type t)
    {
        for (auto ce = expr.isCommaExp(); ce; ce = expr.isCommaExp())
        {
            addIdentExp(ce.e1, t);
            expr = ce.e2;
        }
        addIdentExp(expr, t);
    }

    override void visit(TypeExp expr)
    {
        if (expr.original && expr.type)
            addOriginal(expr.original, expr.type);

        super.visit(expr);
    }

    override void visit(IdentifierExp expr)
    {
        if (expr.resolvedTo)
            if (auto se = expr.resolvedTo.isScopeExp())
                addSymbol(expr.loc, se.sds, identifierExpObject(expr));

//            if (expr.type)
//                addIdentByType(expr.loc, expr.ident, expr.type);
//            else if (expr.original && expr.original.type)
//                addIdentByType(expr.loc, expr.ident, expr.original.type);
//            else
            super.visit(expr);
    }

    override void visit(DotIdExp expr)
    {
        auto orig = expr.resolvedTo;
        if (orig && orig.type && orig.isConstantExpr())
            addIdent(expr.identloc, expr.ident, TypeReferenceKind.Constant,
                dotIdExpObject(expr));
        else if (orig && orig.type &&
                (orig.isArrayLengthExp() || orig.isAALenCall() || (expr.ident == Id.ptr && orig.isCastExp())))
            addIdent(expr.identloc, expr.ident, TypeReferenceKind.MemberVariable,
                dotIdExpObject(expr));
        else
            super.visit(expr);
    }

    override void visit(DotVarExp dve)
    {
        if (dve.var && dve.var.ident)
            addDeclaration(dve.varloc.filename ? dve.varloc : dve.loc, dve.var, dve);
        super.visit(dve);
    }

    override void visit(EnumDeclaration ed)
    {
        addIdent(ed.loc, ed.ident, TypeReferenceKind.Enum, ed);
        super.visit(ed);
    }

    override void visit(FuncDeclaration decl)
    {
        super.visit(decl);

        if (decl.originalType)
        {
            auto ot = decl.originalType ? decl.originalType.isTypeFunction() : null;
            visitType(ot ? ot.nextOf() : null); // the return type
        }
    }

    override void visit(AggregateDeclaration ad)
    {
        if (ad.isInterfaceDeclaration)
            addIdent(ad.loc, ad.ident, TypeReferenceKind.Interface, ad);
        else if (ad.isClassDeclaration)
            addIdent(ad.loc, ad.ident, TypeReferenceKind.Class, ad);
        else if (ad.isUnionDeclaration)
            addIdent(ad.loc, ad.ident, TypeReferenceKind.Union, ad);
        else
            addIdent(ad.loc, ad.ident, TypeReferenceKind.Struct, ad);
        super.visit(ad);
    }

    override void visit(AliasDeclaration ad)
    {
        // the alias identifier can be both before and after the aliased type,
        //  but we rely on so ascending locations in addTypePos
        // as a work around, add the declared identifier before and after
        //  by processing it twice
        super.visit(ad);
        super.visit(ad);
    }
}

// The object a tip query resolves an expression to, mirroring
// FindASTVisitor.foundExpr (not upstream; used by the recording sites above).
private RootObject directExpObject(Expression expr)
{
    if (auto se = expr.isScopeExp())
        return se.sds;
    if (auto ve = expr.isVarExp())
        return ve.var;
    if (auto te = expr.isTypeExp())
        return te.type;
    return null;
}

/// ditto, for FindASTVisitor.foundResolved (unwrapping comma expressions).
private RootObject resolvedExpObject(Expression expr)
{
    if (!expr)
        return null;
    CommaExp ce;
    while ((ce = expr.isCommaExp()) !is null)
    {
        if (auto obj = directExpObject(ce.e1))
            return obj;
        expr = ce.e2;
    }
    return directExpObject(expr);
}

/// ditto, for FindASTVisitor.visit(IdentifierExp).
private RootObject identifierExpObject(IdentifierExp expr)
{
    // A leading `.` — module-scope lookup — parses as an `IdentifierExp` with
    // an empty spelling, which covers no column, so the query's extent test
    // can never match it. (The identifier walk still records the resolved
    // module's name there, which is why this is checked here and not in
    // `record`: by then the spelling is the module's, not the source's.)
    if (expr.ident is null || expr.ident.toString().length == 0)
        return null;
    return expr.type ? cast(RootObject) expr.type : resolvedExpObject(expr.resolvedTo);
}

/// ditto, for FindASTVisitor.visit(DotIdExp).
private RootObject dotIdExpObject(DotIdExp de)
    => !de.type && de.resolvedTo && !de.resolvedTo.isErrorExp()
        ? resolvedExpObject(de.resolvedTo)
        : de;

FindIdentifierTypesResult findIdentifierTypes(Module mod)
{
    scope IdentifierTypesVisitor itv = new IdentifierTypesVisitor;
    itv.filename = locFilename(mod);
    mod.accept(itv);

    return itv.idTypes;
}

////////////////////////////////////////////////////////////////////////////////
// Not upstream: the batch counterpart of findTipData. See collectTips.

/// One identifier occurrence and the tip resolved for it. Unlike
/// `IdTypePos`, this is per-occurrence, not run-length.
struct TipOccurrence
{
    /// 1-based line, as `Loc` spells it.
    int line;

    /// 1-based column of the identifier's first character.
    int col;

    /// What `findTipData` at that position resolves (modulo the caveats on
    /// `collectTips`).
    TipData tip;
}

/**
Every identifier occurrence in `mod` with its tip, from a $(I single) AST
walk (sparkles extension, no upstream counterpart).

`findTipData` answers one position per full-module walk, which makes
"tip every identifier" quadratic. This rides `IdentifierTypesVisitor` — whose
recording sites already coincide with the identifier occurrences a positional
query resolves — and renders each site's object through a memoizing wrapper
over `tipDataForObject`, so a symbol used a thousand times is formatted once.

$(B Not a drop-in replacement for a per-position `findTipData` sweep.) Two
kinds of difference remain, both measured against a full sweep of dmd's own
`expressionsem.d` (37,537 occurrences, 32 of them — 0.09% — divergent):

$(LIST
    * $(B Under-coverage, by design.) Positions where the identifier walk
        records nothing, or has no object to resolve, are simply absent — as
        are the ones this deliberately suppresses to match the query's
        stop-at-first-match order (see `TipCollectVisitor`). A caller wanting
        every position falls back to `findTipData` for the ones missing here,
        which is what makes the difference invisible in the pipeline.
    * $(B Residual disagreement, ~0.1%.) Where a compiler-generated node
        shares a source location with the identifier the user wrote, the two
        walks reach different nodes: an `a[i]` rewritten to `opIndex` tips as
        `i` here and as the operator overload under a positional query, and a
        `cast(T)`'s type name tips as `T` here and as nothing there. The
        parity unittests pin every shape that has been reconciled; these are
        the ones that have not. (A lowered `foreach` used to belong on this
        list — its generated `__limit`/`__key` sit on the loop variable — and
        is now reconciled from the other end: neither walk reports a
        temporary, see `isLoweringTemporary`.)
)

The size/alignment suffix is off for the whole walk (`addsize: false`).

The result is sorted by line, then column; each position appears once (the
deliberate double visit of an `AliasDeclaration` collapses to one entry).
*/
TipOccurrence[] collectTips(Module mod)
{
    const oldSize = showSizeAndAlignment;
    showSizeAndAlignment = false;
    scope(exit) showSizeAndAlignment = oldSize;

    scope TipCollectVisitor tcv = new TipCollectVisitor;
    tcv.filename = locFilename(mod);
    mod.accept(tcv);

    auto occurrences = tcv.occurrences;
    occurrences.sort!((a, b) => a.line != b.line ? a.line < b.line : a.col < b.col);
    return occurrences;
}

/// The walk behind `collectTips`: `IdentifierTypesVisitor` with the
/// classification bookkeeping replaced by tip rendering.
extern(C++) class TipCollectVisitor : IdentifierTypesVisitor
{
    TipOccurrence[] occurrences;

    alias visit = IdentifierTypesVisitor.visit;

    // FindASTVisitor's ForStatement override replaces ASTVisitor's, dropping
    // its explicit descent into the condition and increment expressions — so
    // a positional query resolves nothing inside `for (…; i < n; i++)`, and
    // neither may we. (A lowered `foreach` puts the loop variable's location
    // on generated nodes there, so this is not a rare corner.)
    override void visit(ForStatement fs)
    {
        visit(cast(Statement)fs);
    }

    // Template instances are reached from their declaration, never as a
    // member of the scope they were instantiated into — FindASTVisitor's
    // member loop skips them, so positions inside an instantiated body
    // resolve to nothing there and must stay unrecorded here.
    override void visit(TemplateInstance) {}

    // ... and that declaration-driven walk takes the instantiations first,
    // so a position covered by both an uninstantiated member and its
    // instantiation tips as the latter (`test.ST!int`, not `test.ST(T)`).
    // Occurrences are first-come, so mirror the order too.
    override void visit(TemplateDeclaration td)
    {
        auto instances = cast(TemplateInstance[TemplateInstanceBox])td.instances;
        foreach(ti; instances)
            visit(cast(ScopeDsymbol)ti);

        visit(cast(ScopeDsymbol)td);
    }

    // Keyed by the AST node the tip is rendered from; a module's identifiers
    // resolve to far fewer distinct symbols/types than they have occurrences.
    private TipData[void*] declTips;
    private TipData[void*] symbolTips;
    private TipData[void*] typeTips;
    private int[2][][int] claimed;

    protected override void record(ref const Loc loc, Identifier ident, int type, RootObject obj)
    {
        if (obj is null || loc.linnum <= 0)
            return;

        // Same rule as the positional query (`FindTipVisitor.foundNode`): a
        // lowering's temporary sits on the user's own code — a `foreach`'s
        // `__key`/`__limit` on the loop variable — and reporting it would put
        // a generated, run-varying name in the overlay.
        if (isLoweringTemporary(obj))
            return;

        // A positional query matches a whole identifier extent, not just its
        // start (`FindASTVisitor.matchIdentifier`), and stops at the first
        // node that covers the position. So an occurrence claims the columns
        // its spelling covers, and a later one starting inside an earlier
        // claim is dropped: at that column the query answers with the
        // earlier node, which we cannot report from here. (A rewritten
        // operator is the case in point — `a + b`'s `DotVarExp` sits on the
        // `+` and covers the next seven columns as `opBinary`.) An empty
        // spelling — an anonymous symbol, a `static assert` — covers no
        // column at all and can never be matched.
        const length = cast(int) ident.toString().length;
        if (length == 0)
            return;
        const int[2] extent = [cast(int) loc.charnum, cast(int) loc.charnum + length];
        if (auto line = loc.linnum in claimed)
        {
            foreach (span; *line)
                if (loc.charnum >= span[0] && loc.charnum < span[1])
                    return;
            *line ~= extent;
        }
        else
            claimed[loc.linnum] = [extent];

        occurrences ~= TipOccurrence(loc.linnum, loc.charnum, tipFor(obj));
    }

    /**
    `tipDataForObject` with its two hot paths memoized.

    The dispatch below mirrors that function branch for branch — keep the two
    in step. Only the branches whose result depends solely on a symbol or a
    type are cached; a `DotIdExp`'s tip embeds its receiver expression and a
    parameter's is cheap, so both render per site.
    */
    extern(D) final TipData tipFor(RootObject obj)
    {
        if (auto t = obj.isType())
            return withCode(typeTip(t.mutableOf().unSharedOf()), obj);

        if (auto e = obj.isExpression())
        {
            switch (e.op)
            {
                case EXP.variable:
                case EXP.symbolOffset:
                    return withCode(declTip((cast(SymbolExp)e).var), obj);
                case EXP.dotVariable:
                    return withCode(declTip((cast(DotVarExp)e).var), obj);
                case EXP.dotIdentifier:
                    auto die = e.isDotIdExp();
                    if (die.resolvedTo && die.resolvedTo.type)
                        return tipDataForObject(obj);
                    goto default;
                case EXP.template_:
                    return tipDataForObject(obj);
                default:
                    return withCode(e.type ? typeTip(e.type) : TipData.init, obj);
            }
        }

        if (auto s = obj.isDsymbol())
            return symbolTip(s);

        return tipDataForObject(obj); // parameters, conditions, …
    }

    // tipDataForObject's closing "if the branch produced no code, spell the
    // object out" step, which the cached branches skip.
    extern(D) private static TipData withCode(TipData tip, RootObject obj)
    {
        if (!tip.code.length)
            tip.code = rootObjectToString(obj);
        return tip;
    }

    // tipDataForObject's EXP.variable / EXP.symbolOffset / EXP.dotVariable
    // branches, which share one shape: the declaration plus its docs.
    extern(D) private TipData declTip(Declaration var)
    {
        if (var is null)
            return TipData.init;
        if (auto cached = cast(void*) var in declTips)
            return *cached;

        auto tip = tipForDeclaration(var);
        if (auto doc = docForSymbol(var))
            tip.doc = doc;
        tip.symbol = var;
        declTips[cast(void*) var] = tip;
        return tip;
    }

    // tipDataForObject's whole Dsymbol branch (import substitution, selective
    // import aliases and all), which depends on nothing but the symbol.
    extern(D) private TipData symbolTip(Dsymbol sym)
    {
        if (auto cached = cast(void*) sym in symbolTips)
            return *cached;

        auto tip = tipDataForObject(sym);
        symbolTips[cast(void*) sym] = tip;
        return tip;
    }

    // Keyed by the type as passed to tipForType: the Type branch normalizes
    // through mutableOf/unSharedOf (which dmd interns) before calling, the
    // fallback expression branch does not.
    extern(D) private TipData typeTip(Type t)
    {
        if (auto cached = cast(void*) t in typeTips)
            return *cached;

        auto tip = tipForType(t);
        typeTips[cast(void*) t] = tip;
        return tip;
    }
}

////////////////////////////////////////////////////////////////////////////////
struct ParameterStorageClassPos
{
    int type; // ref, out, lazy
    int line;
    int col;
}

ParameterStorageClassPos[] findParameterStorageClass(Module mod)
{
    extern(C++) class ParameterStorageClassVisitor : ASTVisitor
    {
        ParameterStorageClassPos[] stcPos;
        const(char)* filename;

        alias visit = ASTVisitor.visit;

        final void addParamPos(int type, int line, int col)
        {
            auto psp = ParameterStorageClassPos(type, line, col);
            stcPos ~= psp;
        }
        final void addParamPos(int type, Expression expr)
        {
            if (inFile(expr.loc, filename))
                addParamPos(type, expr.loc.linnum, expr.loc.charnum);
        }
        final void addLazyParamPos(int type, Expression expr)
        {
            if (!expr.loc.filename)
                // drill into generated function for lazy parameter
                if (expr.op == EXP.function_)
                    if (auto fd = (cast(FuncExp)expr).fd)
                        if (fd.fbody)
                            if (auto cs = fd.fbody.isCompoundStatement())
                                if (cs.statements && cs.statements.length)
                                    if (auto rs = (*cs.statements)[0].isReturnStatement())
                                        expr = rs.exp;

            if (inFile(expr.loc, filename))
                addParamPos(type, expr.loc.linnum, expr.loc.charnum);
        }

        override void visit(CallExp expr)
        {
            if (expr.arguments && expr.arguments.length)
            {
                if (auto tf = expr.f ? expr.f.type.isTypeFunction() : null)
                {
                    if (auto params = tf.parameterList.parameters)
                    {
                        size_t cnt = min(expr.arguments.length, params.length);
                        for (size_t p = 0; p < cnt; p++)
                        {
                            auto stc = (*params)[p].storageClass;
                            if (stc & STC.ref_)
                            {
                                if (stc & (STC.in_ | STC.const_))
                                    continue;
                                if((*params)[p].type && !(*params)[p].type.isMutable())
                                    continue;
                                addParamPos(0, (*expr.arguments)[p]);
                            }
                            else if (stc & STC.out_)
                                addParamPos(1, (*expr.arguments)[p]);
                            else if (stc & STC.lazy_)
                                addLazyParamPos(2, (*expr.arguments)[p]);
                        }
                    }
                }
            }
            super.visit(expr);
        }
    }

    scope psv = new ParameterStorageClassVisitor;
    psv.filename = locFilename(mod);
    mod.accept(psv);

    return psv.stcPos;
}

////////////////////////////////////////////////////////////////////////////////
struct Reference
{
    Loc loc;
    Identifier ident;
}

Reference[] findReferencesInModule(Module mod, int line, int index)
{
    auto filename = locFilename(mod);
    scope FindDefinitionVisitor fdv = new FindDefinitionVisitor(filename, line, index, line, index + 1);
    mod.accept(fdv);

    if (!fdv.found)
        return null;

    extern(C++) class FindReferencesVisitor : ASTVisitor
    {
        RootObject search;
        Reference[] references;
        const(char)* filename;

        alias visit = ASTVisitor.visit;

        extern(D)
        void addReference(ref const Loc loc, Identifier ident)
        {
            if (inFile(loc, filename) && ident && loc.linnum > 0)
                if (!references.contains(Reference(loc, ident)))
                    references ~= Reference(loc, ident);
        }

        void addResolved(ref const Loc loc, Expression resolved)
        {
            if (resolved)
                if (auto se = resolved.isScopeExp())
                    if (se.sds is search)
                        addReference(loc, se.sds.ident);
        }

        extern(D) void addPackages(Module mod, IdentifierAtLoc[] packages)
        {
            if (!mod || !packages)
                return;

            Package pkg = mod.parent ? mod.parent.isPackage() : null;
            for (size_t p; pkg && p < packages.length; p++)
            {
                size_t q = packages.length - 1 - p;
                if (pkg is search)
                    addReference(packages[q].loc, packages[q].ident);
                if (auto parent = pkg.parent)
                    pkg = parent.isPackage();
            }
        }

        override void visit(Dsymbol sym)
        {
            if (sym is search)
                addReference(sym.loc, sym.ident);
            super.visit(sym);
        }
        override void visit(Module mod)
        {
            if (mod.md)
            {
                addPackages(mod, mod.md.packages);
                if (mod is search)
                    addReference(mod.md.loc, mod.md.id);
            }
            visit(cast(Package)mod);
        }

        override void visit(Import imp)
        {
            addPackages(imp.mod, imp.packages);

            if (imp.mod is search)
                addReference(imp.loc, imp.id);

            for (int n = 0; n < imp.names.length; n++)
            {
                // names? (imp.names[n].loc, imp.names[n].ident)
                if (n < imp.aliasdecls.length)
                    if (imp.aliasdecls[n].aliassym is search)
                        addReference(imp.names[n].loc, imp.names[n].ident);
            }
            // symbol has ident of first package, so don't forward
        }

        override void visit(SymbolExp expr)
        {
            if (expr.var is search)
                addReference(expr.loc, expr.var.ident);
            super.visit(expr);
        }
        override void visit(SymOffExp expr)
        {
            // skip this SymbolExp, it is not an original and has bad location
            super.visit(cast(Expression)expr);
        }
        override void visit(DotVarExp dve)
        {
            if (dve.var is search)
                addReference(dve.varloc.filename ? dve.varloc : dve.loc, dve.var.ident);
            super.visit(dve);
        }
        override void visit(TypeExp te)
        {
            if (auto ts = typeSymbol(te.type))
                if (ts is search)
                    addReference(te.loc, ts.ident);
            super.visit(te);
        }

        override void visit(IdentifierExp expr)
        {
            addResolved(expr.loc, expr.resolvedTo);
            super.visit(expr);
        }

        override void visit(DotIdExp expr)
        {
            addResolved(expr.identloc, expr.resolvedTo);
            super.visit(expr);
        }

        override void visit(TypeQualified tid)
        {
            foreach (i, id; tid.idents)
            {
                RootObject obj = id;
                if (obj.dyncast() == DYNCAST.identifier)
                {
                    auto ident = cast(Identifier)obj;
                    if (tid.parentScopes.length > i + 1)
                        if (tid.parentScopes[i + 1] is search)
                            addReference(id.loc, ident);
                }
            }
            super.visit(tid);
        }

        override void visit(TypeIdentifier tid)
        {
            while (tid.copiedFrom)
            {
                if (tid.parentScopes.length > 0)
                    break;
                tid = tid.copiedFrom;
            }
            if (tid.parentScopes.length > 0)
                if (tid.parentScopes[0] is search)
                    addReference(tid.loc, tid.ident);

            super.visit(tid);
        }

        override void visit(TypeInstance tid)
        {
            if (!tid.tempinst)
                return;
            if (tid.parentScopes.length > 0)
                if (tid.parentScopes[0] is search)
                    addReference(tid.loc, tid.tempinst.name);

            super.visit(tid);
        }

        override void visitParameter(Parameter p, Declaration decl)
        {
            if (decl is search)
                addReference(decl.loc, decl.ident);
            super.visitParameter(p, decl);
        }
    }

    scope FindReferencesVisitor frv = new FindReferencesVisitor();

    if (auto t = fdv.found.isType())
    {
        if (t.ty == Tstruct)
            fdv.found = (cast(TypeStruct)t).sym;
    }
    else if (auto e = fdv.found.isExpression())
    {
        switch(e.op)
        {
            case EXP.variable:
            case EXP.symbolOffset:
                fdv.found = (cast(SymbolExp)e).var;
                break;
            case EXP.dotVariable:
                fdv.found = (cast(DotVarExp)e).var;
                break;
            default:
                break;
        }
    }
    frv.search = fdv.found;
    frv.filename = filename;
    mod.accept(frv);

    return frv.references;
}

////////////////////////////////////////////////////////////////////////////////
string symbol2ExpansionType(Dsymbol sym)
{
    if (sym.isInterfaceDeclaration())
        return "IFAC";
    if (sym.isClassDeclaration())
        return "CLSS";
    if (sym.isUnionDeclaration())
        return "UNIO";
    if (sym.isStructDeclaration())
        return "STRU";
    if (sym.isEnumDeclaration())
        return "ENUM";
    if (sym.isEnumMember())
        return "EVAL";
    if (sym.isAliasDeclaration())
        return "ALIA";
    if (sym.isTemplateDeclaration())
        return "TMPL";
    if (sym.isTemplateMixin())
        return "NMIX";
    if (sym.isModule())
        return "MOD";
    if (sym.isPackage())
        return "PKG";
    if (sym.isFuncDeclaration())
    {
        auto p = sym.toParent2;
        return p && p.isAggregateDeclaration ? "MTHD" : "FUNC";
    }
    if (sym.isVarDeclaration())
    {
        auto p = sym.toParent2;
        return p && p.isAggregateDeclaration ? "PROP" : "VAR"; // "SPRP"?
    }
    if (sym.isOverloadSet())
        return "OVR";
    return "TEXT";
}

string symbol2ExpansionLine(Dsymbol sym)
{
    string type = symbol2ExpansionType(sym);
    string tip = tipForObject(sym);
    return type ~ ":" ~ tip.replace("\n", "\a").replace("\r", "");
}

string[string] initSymbolProperties(int kind)
{
    string[string] props;
    // generic
    props["init"] = "PROP:A type's or variable's static initializer expression";
    props["sizeof"] = "PROP:Size of a type or variable in bytes";
    props["alignof"] = "PROP:Variable alignment";
    props["mangleof"] = "PROP:String representing the ‘mangled’ representation of the type";
    props["stringof"] = "PROP:String representing the source representation of the type";

    switch (kind)
    {
        case 0:
            // numeric types
            props["max"] = "PROP:Maximum value";
            props["min"] = "PROP:Minimum value";
            break;
        case 1:
            // floating point
            props["infinity"] = "PROP:Infinity value";
            props["nan"] = "PROP:Not-a-Number value";
            props["dig"] = "PROP:Number of decimal digits of precision";
            props["epsilon"] = "PROP:Smallest increment to the value 1";
            props["mant_dig"] = "PROP:Number of bits in mantissa";
            props["max_10_exp"] = "PROP:Maximum int value such that 10^max_10_exp is representable";
            props["max_exp"] = "PROP:Maximum int value such that 2^max_exp-1 is representable";
            props["min_10_exp"] = "PROP:Minimum int value such that 10^max_10_exp is representable";
            props["min_exp"] = "PROP:Minimum int value such that 2^max_exp-1 is representable";
            props["min_normal"] = "PROP:Number of decimal digits of precision";
            // require this
            props["re"] = "PROP:Real part of a complex number";
            props["im"] = "PROP:Imaginary part of a complex number";
            break;
        case 2:
            // arrays (require this)
            props["length"] = "PROP:Array length";
            props["dup"] = "PROP:Create a dynamic array of the same size and copy the contents of the array into it.";
            props["idup"] = "PROP:Creates immutable copy of the array";
            props["reverse"] = "PROP:Reverses in place the order of the elements in the array. Returns the array.";
            props["sort"] = "PROP:Sorts in place the order of the elements in the array. Returns the array.";
            props["ptr"] = "PROP:Returns pointer to the array";
            break;
        case 3:
            // assoc array (require this)
            props["length"] = "PROP:Returns number of values in the associative array. Unlike for dynamic arrays, it is read-only.";
            props["keys"] = "PROP:Returns dynamic array, the elements of which are the keys in the associative array.";
            props["values"] = "PROP:Returns dynamic array, the elements of which are the values in the associative array.";
            props["rehash"] = "PROP:Reorganizes the associative array in place so that lookups are more efficient." ~
                " rehash is effective when, for example, the program is done loading up a symbol table and now needs fast lookups in it." ~
                " Returns a reference to the reorganized array.";
            props["byKey"] = "PROP:Returns a delegate suitable for use as an aggregate to a `foreach` which will iterate over the keys of the associative array.";
            props["byValue"] = "PROP:Returns a delegate suitable for use as an aggregate to a `foreach` which will iterate over the values of the associative array.";
            props["get"] = "Looks up key; if it exists returns corresponding value else evaluates and returns defaultValue.";
            props["remove"] = "remove(key) does nothing if the given key does not exist and returns false. If the given key does exist, it removes it from the AA and returns true.";
            break;
        case 4:
            // static array (require this)
            props["length"] = "PROP:Returns number of values in the type tuple.";
            break;
        case 5:
            // delegate (require this)
            props["ptr"] = "PROP:The .ptr property of a delegate will return the frame pointer value as a void*.";
            props["funcptr"] = "PROP:The .funcptr property of a delegate will return the function pointer value as a function type.";
            break;
        case 6:
            // class (require this)
            props["classinfo"] = "PROP:Information about the dynamic type of the class";
            break;
        case 7:
            // struct
            props["sizeof"] = "PROP:Size in bytes of struct";
            props["alignof"] = "PROP:Size boundary struct needs to be aligned on";
            props["tupleof"] = "PROP:Gets type tuple of fields";
            break;
        default:
            break;
    }
    return props;
}

const string[string] genericProps;
const string[string] integerProps;
const string[string] floatingProps;
const string[string] dynArrayProps;
const string[string] assocArrayProps;
const string[string] staticArrayProps;
const string[string] delegateProps;
const string[string] classProps;
const string[string] structProps;

shared static this()
{
    genericProps     = initSymbolProperties (-1);
    integerProps     = initSymbolProperties (0);
    floatingProps    = initSymbolProperties (1);
    dynArrayProps    = initSymbolProperties (2);
    assocArrayProps  = initSymbolProperties (3);
    staticArrayProps = initSymbolProperties (4);
    delegateProps    = initSymbolProperties (5);
    classProps       = initSymbolProperties (6);
    structProps      = initSymbolProperties (7);
}

void addSymbolProperties(ref string[] expansions, RootObject sym, Type t, string tok)
{
    bool hasThis = sym && sym.isExpression();
    if (!t)
        return;

    const string[string] props = t.isTypeClass()    && hasThis ? classProps
                            : t.isTypeStruct()              ? structProps
                            : t.isTypeDelegate() && hasThis ? delegateProps
                            : t.isTypeSArray()   && hasThis ? staticArrayProps
                            : t.isTypeAArray()   && hasThis ? assocArrayProps
                            : t.isTypeDArray()   && hasThis ? dynArrayProps
                            : t.isFloating()     ? floatingProps
                            : t.isIntegral()     ? integerProps
                            : genericProps;
    foreach (id, p; props)
        if (id.startsWith(tok))
            expansions ~= id ~ ":" ~ p;
}

////////////////////////////////////////////////////////////////

extern(C++) class FindExpansionsVisitor : FindASTVisitor
{
    alias visit = FindASTVisitor.visit;

    this(const(char*) filename, int startLine, int startIndex, int endLine, int endIndex)
    {
        super(filename, startLine, startIndex, endLine, endIndex);
    }

    override void visit(IdentifierExp expr)
    {
        if (!found && expr.ident)
        {
            if (matchIdentifier(expr.loc, expr.ident))
            {
                foundNode(expr);
            }
        }
        // skip base class to avoid matching resolved expression
        visit(cast(Expression)expr);
    }

    override void visit(SymbolExp expr)
    {
        if (!found && expr.var && !expr.original) // do not match lowered VarExp
            if (matchIdentifier(expr.loc, expr.var.ident))
                foundNode(expr);
        // skip base class to avoid matching lowered expression
        visit(cast(Expression)expr);
    }

    override void visit(DotVarExp dve)
    {
        if (!found && dve.var && dve.var.ident)
            if (matchIdentifier(dve.varloc.filename ? dve.varloc : dve.loc, dve.var.ident))
                foundNode(dve);
    }

    override void visit(DotIdExp de)
    {
        if (!found && de.ident)
            if (matchDotIdentifier(de.dotloc, de.identloc, de.ident))
                foundNode(de);
    }

    override void checkScope(ScopeDsymbol sc)
    {
        if (sc && !foundScope)
        {
            if (!inFile(sc.loc, filename) || sc.loc.linnum > endLine)
                return;
            if (sc.loc.linnum == endLine && sc.loc.charnum > endIndex)
                return;
            if (sc.endlinnum < startLine)
                return;
            if (sc.endlinnum == startLine && sc.endcharnum < startIndex)
                return;

            foundScope = sc;
            stop = true;
        }
    }
}

string[] findExpansions(Module mod, int line, int index, string tok)
{
    auto filename = locFilename(mod);
    scope FindExpansionsVisitor fdv = new FindExpansionsVisitor(filename, line, index, line, index + 1);
    mod.accept(fdv);

    if (!fdv.found && !fdv.foundScope)
        fdv.foundScope = mod;

    int flags = 0;
    Type type = fdv.found ? fdv.found.isType() : null;
    if (auto e = fdv.found ? fdv.found.isExpression() : null)
    {
        Type getType(Expression e, bool recursed)
        {
            switch(e.op)
            {
                case EXP.variable:
                case EXP.symbolOffset:
                    if(recursed)
                        return (cast(SymbolExp)e).var.type;
                    return null;

                case EXP.dotVariable:
                case EXP.dotIdentifier:
                    flags |= SearchOpt.localsOnly;
                    if (recursed)
                        if (auto dve = e.isDotVarExp())
                            if (dve.varloc.filename)  // skip compiler generated idents (alias this)
                                return dve.var.type;

                    auto e1 = (cast(UnaExp)e).e1;
                    return getType(e1, true);

                case EXP.dot:
                    flags |= SearchOpt.localsOnly;
                    return (cast(DotExp)e).e1.type;
                default:
                    return recursed ? e.type : null;
            }
        }
        if (auto t = getType(e, false))
            type = t;
    }
    if (!type)
        if (auto sym = fdv.found ? fdv.found.isDsymbol() : null)
            if (auto em = sym.isEnumMember())
                type = em.ed.type;

    if (type && type.isTypeEnum())
        flags |= SearchOpt.localsOnly;

    auto sds = fdv.foundScope;
    if (type)
        if (auto sym = typeSymbol(type))
            sds = sym;
    if (!sds)
        sds = mod;

    string[void*] idmap; // doesn't work with extern(C++) classes
    DenseSet!ScopeDsymbol searched;

    void searchScope(ScopeDsymbol sds, int flags)
    {
        if (searched.contains(sds))
            return;
        searched.insert(sds);

        static Dsymbol uplevel(Dsymbol s)
        {
            if (auto ad = s.isAggregateDeclaration())
                if (ad.enclosing)
                    return ad.enclosing;
            return s.toParent;
        }
        // TODO: struct/class not going to parent if accessed from elsewhere (but does if nested)
        // TODO: UFCS
        for (Dsymbol ds = sds; ds; ds = uplevel(ds))
        {
            ScopeDsymbol sd = ds.isScopeDsymbol();
            if (!sd)
                continue;

            //foreach (pair; sd.symtab.tab.asRange)
            if (sd.symtab)
            {
                foreach (kv; sd.symtab.tab.asRange)
                {
                    //Dsymbol s = pair.value;
                    if (!symbolIsVisible(mod, kv.value))
                        continue;
                    auto ident = /*pair.*/(cast(Identifier)kv.key).toString();
                    if (ident.startsWith(tok))
                        idmap[cast(void*)kv.value] = ident.idup;
                }
            }

            void searchScopeSymbol(ScopeDsymbol sym)
            {
                if (!sym)
                    return;
                int sflags = SearchOpt.localsOnly;
                if (sym.getModule() == mod)
                    sflags |= SearchOpt.ignoreVisibility;
                searchScope(sym, sflags);
            }
            // base classes
            if (auto cd = ds.isClassDeclaration())
            {
                if (auto bcs = cd.baseclasses)
                    foreach (bc; *bcs)
                        searchScopeSymbol(bc.sym);
            }
            // with statement
            if (auto ws = ds.isWithScopeSymbol())
            {
                Expression eold = null;
                for (Expression e = ws.withstate.exp; e != eold; e = resolveAliasThis(ws._scope, e))
                {
                    if (auto se = e.isScopeExp())
                        searchScopeSymbol(se.sds);
                    else if (auto te = e.isTypeExp())
                        searchScopeSymbol(te.type.toDsymbol(null).isScopeDsymbol());
                    else
                        searchScopeSymbol(e.type.toBasetype().toDsymbol(null).isScopeDsymbol());
                    eold = e;
                }
            }
            // alias this
            if (auto ad = ds.isAggregateDeclaration())
            {
                Declaration decl = ad.aliasthis && ad.aliasthis.sym ? ad.aliasthis.sym.isDeclaration() : null;
                if (decl)
                {
                    Type t = decl.type;
                    if (auto ts = t.isTypeStruct())
                        searchScopeSymbol(ts.sym);
                    else if (auto tc = t.isTypeClass())
                        searchScopeSymbol(tc.sym);
                    else if (auto ti = t.isTypeInstance())
                        searchScopeSymbol(ti.tempinst);
                    else if (auto te = t.isTypeEnum())
                        searchScopeSymbol(te.sym);
                }
            }

            if (flags & SearchOpt.localsOnly)
                break;

            // imported modules
            size_t cnt = sd.importedScopes ? sd.importedScopes.length : 0;
            for (size_t i = 0; i < cnt; i++)
            {
                if ((flags & SearchOpt.ignorePrivateImports) && sd.visibilities[i] == Visibility.Kind.private_)
                    continue;
                auto ss = (*sd.importedScopes)[i].isScopeDsymbol();
                if (!ss)
                    continue;

                int sflags = 0;
                if (ss.isModule())
                {
                    if (flags & SearchOpt.localsOnly)
                        continue;
                    sflags |= SearchOpt.ignorePrivateImports;
                }
                else // mixin template
                {
                    if (flags & SearchOpt.importsOnly)
                        continue;
                    sflags |= SearchOpt.localsOnly;
                }
                searchScope(ss, sflags | SearchOpt.ignorePrivateImports);
            }
        }
    }
    searchScope(sds, flags);

    string[] idlist;
    foreach(sym, id; idmap)
        if (!id.startsWith("__"))
            idlist ~= id ~ ":" ~ symbol2ExpansionLine(cast(Dsymbol)sym);

    if (type)
        addSymbolProperties(idlist, fdv.found, type, tok);

    return idlist;
}

////////////////////////////////////////////////////////////////////////////////
string[] getModuleOutline(Module mod, int maxdepth)
{
    extern(C++) class OutlineVisitor : ASTVisitor
    {
        string[] lines;
        int maxdepth;
        int depth = 1;

        alias visit = ASTVisitor.visit;

        extern(D)
        void addOutline(ref const Loc loc, int endln, Dsymbol decl)
        {
            if (!loc.filename) // ignore compiler added symbols
                return;

            import dmd.root.string : toDString;
            auto desc = toDString(decl.toPrettyChars());
            if (auto fd = decl.isFuncDeclaration())
                if (auto tf = fd.type ? fd.type.isTypeFunction() : null)
                {
                    auto td = decl.parent ? decl.parent.isTemplateDeclaration() : null;
                    if (!td || fd != td.onemember) // parameters already printed in function templates
                        desc ~= toDString(parametersTypeToChars(tf.parameterList));
                }

            string txt = depth.to!string ~ ":" ~ loc.linnum.to!string ~ ":" ~ endln.to!string ~ ":";
            string cat = symbol2ExpansionType(decl);
            txt ~= cat ~ ":" ~ desc;
            lines ~= txt;
        }

        override void visit(FuncDeclaration fd)
        {
            addOutline(fd.loc, fd.endloc.linnum, fd);
            if (depth < maxdepth)
            {
                depth++;
                super.visit(fd);
                depth--;
            }
        }

        override void visit(EnumDeclaration ed)
        {
            if (ed.ident)
                addOutline(ed.loc, ed.endlinnum, ed);
            if (depth < maxdepth)
            {
                depth++;
                super.visit(ed);
                depth--;
            }
        }

        override void visit(AggregateDeclaration ad)
        {
            addOutline(ad.loc, ad.endlinnum, ad);
            if (depth < maxdepth)
            {
                depth++;
                super.visit(ad);
                depth--;
            }
        }

        override void visit(TemplateDeclaration td)
        {
            addOutline(td.loc, td.endlinnum, td);
            if (!td.loc.filename)
                super.visit(td);
            else if (depth < maxdepth)
            {
                depth++;
                super.visit(td);
                depth--;
            }
        }

    }

    scope ov = new OutlineVisitor();
    ov.maxdepth = maxdepth;
    mod.accept(ov);

    return ov.lines;
}

////////////////////////////////////////////////////////////////////////////////

bool isConstantExpr(Expression expr)
{
    switch(expr.op)
    {
        case EXP.int64, EXP.float64, EXP.complex80:
        case EXP.null_, EXP.void_:
        case EXP.string_:
        case EXP.arrayLiteral, EXP.assocArrayLiteral, EXP.structLiteral:
        case EXP.classReference:
            //case EXP.type:
        case EXP.vector:
        case EXP.function_, EXP.delegate_:
        case EXP.symbolOffset, EXP.address:
        case EXP.typeid_:
        case EXP.slice:
            return true;
        default:
            return false;
    }
}

// return first argument to aaLen()
Expression isAALenCall(Expression expr)
{
    // unpack first argument of _aaLen(aa)
    if (auto ce = expr.isCallExp())
        if (auto ve = ce.e1.isVarExp())
            if (ve.var.ident is Id._d_aaLen)
                if (ce.arguments && ce.arguments.length > 0)
                    return (*ce.arguments)[0];
    return null;
}

////////////////////////////////////////////////////////////////////////////////

ScopeDsymbol typeSymbol(Type type)
{
    if (auto ts = type.isTypeStruct())
        return ts.sym;
    if (auto tc = type.isTypeClass())
        return tc.sym;
    if (auto te = type.isTypeEnum())
        return te.sym;
    return null;
}

Module cloneModule(Module mo)
{
    if (!mo)
        return null;
    Loc mloc = Loc.singleFilename(mo.srcfile.toString());
    Module m = new Module(mloc, mo.srcfile.toString(), mo.ident, cast(bool)mo.docfile, cast(bool)mo.hdrfile);
    *cast(FileName*)&(m.srcfile) = mo.srcfile; // keep identical source file name pointer
    m.isPackageFile = mo.isPackageFile;
    m.md = mo.md;
    mo.syntaxCopy(m);

    extern(C++) class AdjustModuleVisitor : ASTVisitor
    {
        // avoid allocating capture
        Module m;
        this (Module m)
        {
            this.m = m;
            unconditional = true;
        }

        alias visit = ASTVisitor.visit;

        override void visit(ConditionalStatement cond)
        {
            if (auto dbg = cond.condition.isDebugCondition())
                cond.condition = new DebugCondition(dbg.loc, m, dbg.ident);
            else if (auto ver = cond.condition.isVersionCondition())
                cond.condition = new VersionCondition(ver.loc, m, ver.ident);
            super.visit(cond);
        }

        override void visit(ConditionalDeclaration cond)
        {
            if (auto dbg = cond.condition.isDebugCondition())
                cond.condition = new DebugCondition(dbg.loc, m, dbg.ident);
            else if (auto ver = cond.condition.isVersionCondition())
                cond.condition = new VersionCondition(ver.loc, m, ver.ident);
            super.visit(cond);
        }

        override void visit(ScopeDsymbol scopesym)
        {
            if (scopesym.symtab)
                scopesym.symtab = null;
            super.visit(scopesym);
        }
        override void visit(FuncDeclaration fd)
        {
            if (fd.localsymtab)
                fd.localsymtab = null;
            super.visit(fd);
        }
    }

    import dmd.visitor.permissive;
    scope v = new AdjustModuleVisitor(m);
    m.accept(v);
    return m;
}

Module createModuleFromText(string filename, string text)
{
    import std.path;

    text ~= "\0\0\0\0"; // parser needs 4 trailing zeroes
    string name = stripExtension(baseName(filename));
    auto id = Identifier.idPool(name);
    Loc mloc = Loc.singleFilename(filename);
    auto mod = new Module(mloc, filename, id, true, false);
    mod.src = cast(ubyte[])text;
    mod.read(Loc.initial);
    mod.importedFrom = mod; // avoid skipping unittests
    mod.parse();
    return mod;
}

////////////////////////////////////////////////////////////////////////////////


////////////////////////////////////////////////////////////////////////////////
// Tests
//
// The corpus is `dmdserver`'s `semanalysis.do_unittests` slice, re-indented
// (upstream's one-tab indent became this repo's four spaces) and with the
// module renamed: `Analyzer.analyze` names its in-memory file `test.d`, so
// symbols read `test.X` where upstream reads `source.X`. Line numbers are
// load-bearing — line 1 of each `q{}` is the line the `q{` itself is on, which
// is why every source opens with a `// Line 1` marker.

version (unittest)
{
    import sparkles.dmd_lsp.testing : checkTip, withAnalysis;

    // Upstream's struct corpus.
    private enum structSource = q{                    // Line 1
        struct S
        {
            int field1 = 3;
            static long stat1 = 7;                    // Line 5
            int fun(int par) { return field1 + par; }
        }
        void foo()
        {
            S anS;                                    // Line 10
            int x = anS.fun(1);
        }
        int fun(S s)
        {
            auto p = new S(1);                        // Line 15
            auto seven = S.stat1;
            return s.field1;
        }
    };

    // Upstream's class corpus, plus a `catch` binding so one tip resolves into
    // druntime rather than the analyzed file.
    private enum classSource = q{                     // Line 1
        class C
        {
            int field1 = 3;
            int fun(int par) { return field1 + par; } // Line 5
        }
        void foo()
        {
            C aC = new C;
            int x = aC.fun(1);                        // Line 10
            try { }
            catch (Exception e) { auto s = e.msg; }
        }
    };

    // Enum values and a renamed selective import (upstream's `pkg.source`
    // corpus, minus its `module` declaration — see the note on
    // `visitor.findTip.importedPackageAndModule`).
    private enum enumSource = q{                      // Line 1
        enum EE { E1 = 3, E2 }
        void foo()
        {
            auto ee = EE.E1;                          // Line 5
        }
        import core.cpuid : cpu_vendor = vendor, processor;
        string cpuInfo()
        {
            return cpu_vendor ~ " " ~ processor;      // Line 10
        }
    };

    // Upstream's manifest-constant corpus.
    private enum constantSource = q{                  // Line 1
        enum TTT = 9;
        void fun(int y = TTT)
        {
            int x = TTT;                              // Line 5
            static assert(msg.length == 4);
        }
        static assert(TTT == 9, msg);
        enum msg = "fail";
    };

    // Upstream's template-struct corpus, given an instantiation.
    private enum templateSource = q{                  // Line 1
        struct ST(T)
        {
            T f;
        }                                             // Line 5
        void use()
        {
            ST!int v;
            v.f = 1;
        }                                             // Line 10
    };

    // No upstream equivalent: doc comments on a function, an aggregate and a
    // field, for spec DOC1.
    private enum docSource = q{                       // Line 1
        /// Adds two numbers.
        int add(int a, int b) { return a + b; }

        /// A point in the plane.
        struct Point                                  // Line 6
        {
            /// The horizontal coordinate.
            int x;
        }
        void use()                                    // Line 11
        {
            Point p;
            int n = add(p.x, 1);
        }
    };

    // No upstream equivalent: the three shapes where the identifier walk and
    // a positional query disagree unless `collectTips` mirrors
    // `FindASTVisitor` — a rewritten operator (whose `opBinary` extent
    // swallows the columns it precedes), a template aggregate (whose
    // instantiation outranks its declaration) and a lambda instantiated
    // inside another template (whose body a positional query never reaches).
    private enum rewriteSource = q{                   // Line 1
        import std.algorithm.iteration : map;
        import std.range : iota;
        struct Vec2                                   // Line 4
        {
            double x, y;
            Vec2 opBinary(string op)(Vec2 rhs) const
                => Vec2(mixin("x " ~ op ~ " rhs.x"), mixin("y " ~ op ~ " rhs.y"));
        }
        auto sum = Vec2(1, 2) + Vec2(3, 4);           // Line 10
        auto squares(int n) { return iota(n).map!(x => x * x); }
    };

    // No upstream equivalent: two more positions the identifier walk records
    // but a positional query cannot answer — a `for` condition/increment
    // (which `FindASTVisitor` does not descend into, and which a lowered
    // `foreach` fills with the loop variable's location) and a module-scope
    // `.name` lookup (an `IdentifierExp` whose empty spelling covers no
    // column, though the walk records the resolved module's name there).
    private enum loweredSource = q{                   // Line 1
        void log(int value) { }
        void run(int[] xs)
        {
            for (size_t i = 0; i < xs.length; i++)    // Line 5
                .log(xs[i]);
            foreach (v; 0 .. xs.length)
                .log(cast(int) v);
        }
    };
}

@("visitor.findTip.structMembers")
@system unittest
{
    withAnalysis(structSource, (m) {
        checkTip(m,  2, 16, "(struct) `test.S`");
        checkTip(m,  4, 17, "(field) `int test.S.field1`");
        checkTip(m,  5, 25, "(thread local global) `long test.S.stat1`");
        checkTip(m,  6, 17, "`int test.S.fun(int par)`");
        checkTip(m,  6, 25, "(parameter) `int par`");
        checkTip(m,  6, 39, "(field) `int test.S.field1`");   // use in the body
        checkTip(m,  6, 48, "(parameter) `int par`");         // use in the body
        checkTip(m,  8, 14, "`void test.foo()`");
        checkTip(m, 10, 13, "(struct) `test.S`");
        checkTip(m, 10, 15, "(local variable) `test.S anS`");
        checkTip(m, 11, 21, "(local variable) `test.S anS`");
        checkTip(m, 11, 25, "`int test.S.fun(int par)`");     // through the dot
        checkTip(m, 13, 19, "(parameter) `test.S s`");
        checkTip(m, 15, 18, "(local variable) `test.S* p`");
        checkTip(m, 16, 28, "(thread local global) `long test.S.stat1`");
        checkTip(m, 17, 22, "(field) `int test.S.field1`");
    });
}

@("visitor.findTip.nothingBetweenIdentifiers")
@system unittest
{
    // A position that is not inside an identifier resolves to nothing at all —
    // the assertion upstream writes as `checkTip(m, 5, 11, "")`.
    withAnalysis(structSource, (m) {
        checkTip(m,  2, 15, "");    // the space before `S`
        checkTip(m,  4, 23, "");    // one past the end of `field1`
        checkTip(m, 11, 24, "");    // the `.` in `anS.fun`
    });
}

@("visitor.findTip.classMembers")
@system unittest
{
    withAnalysis(classSource, (m) {
        checkTip(m,  2, 15, "(class) `test.C`");
        checkTip(m,  4, 17, "(field) `int test.C.field1`");
        checkTip(m,  5, 17, "`int test.C.fun(int par)`");
        checkTip(m,  5, 25, "(parameter) `int par`");
        checkTip(m,  9, 13, "(class) `test.C`");
        checkTip(m,  9, 15, "(local variable) `test.C aC`");
        checkTip(m,  9, 24, "(class) `test.C`");              // the `new C`
        checkTip(m, 10, 24, "`int test.C.fun(int par)`");
    });
}

@("visitor.findTip.druntimeSymbols")
@system unittest
{
    // Resolving out of the analyzed file and into druntime. Matched by prefix,
    // like upstream: `object.d` is ddoc-commented and imports now retain their
    // comments (`DOC4`), so each tip carries druntime's documentation after
    // the signature.
    withAnalysis(classSource, (m) {
        checkTip(m, 12, 20, "(class) `object.Exception`...");
        checkTip(m, 12, 30, "(local variable) `object.Exception e`...");
        checkTip(m, 12, 46, "(field) `string object.Throwable.msg`...");
    });
}

@("visitor.findTip.enumValues")
@system unittest
{
    withAnalysis(enumSource, (m) {
        checkTip(m, 2, 14, "(enum) `test.EE`");
        checkTip(m, 2, 19, "(enum value) `test.EE.E1 = 3`");
        checkTip(m, 2, 27, "(enum value) `test.EE.E2 = 4`");  // implicit value
        checkTip(m, 5, 18, "(local variable) `test.EE ee`");
        checkTip(m, 5, 23, "(enum) `test.EE`");
        checkTip(m, 5, 26, "(enum value) `test.EE.E1 = 3`");
    });
}

@("visitor.findTip.importedPackageAndModule")
@system unittest
{
    // Prefix matches from the module down: `core.cpuid` and the symbols a
    // selective import aliases are all documented in druntime, and `DOC4`
    // surfaces those comments on the hover.
    withAnalysis(enumSource, (m) {
        checkTip(m, 7, 16, "(package) `core`");
        checkTip(m, 7, 21, "(module) `core.cpuid`...");
        checkTip(m, 7, 29, "(alias) `test.cpu_vendor = string core.cpuid.vendor()"
            ~ " pure nothrow @nogc @property @trusted`...");
        checkTip(m, 7, 42, "(alias) `test.cpu_vendor = string core.cpuid.vendor()"
            ~ " pure nothrow @nogc @property @trusted`...");
        checkTip(m, 7, 50, "(alias) `test.processor = string core.cpuid.processor()"
            ~ " pure nothrow @nogc @property @trusted`...");
        checkTip(m, 10, 20, "`string core.cpuid.vendor() pure nothrow @nogc"
            ~ " @property @trusted`...");
    });
}

@("visitor.docForSymbol.dittoInheritsThePrecedingComment")
@system unittest
{
    // `DDC11`: `/// ditto` is resolved by `emitComment`'s `sc.lastdc`, which
    // only runs while generating a documentation file — so every ditto'd
    // overload used to hover as the literal word "ditto".
    enum src = q{
        /// Rounds x toward zero.
        int truncate(double x) => cast(int) x;       // Line 3
        /// ditto
        long truncate(real x) => cast(long) x;       // Line 5
        /// ditto
        long truncate(float x) => cast(long) x;      // Line 7

        private:
        /// In an attribute block.
        int inner(double x) => cast(int) x;          // Line 11
        /// ditto
        int inner(real x) => cast(int) x;            // Line 13
    };

    withAnalysis(src, (m) {
        assert(m.tipAt(3, 13).doc == "Rounds `x` toward zero.", m.tipAt(3, 13).doc);
        assert(m.tipAt(5, 14).doc == "Rounds `x` toward zero.", m.tipAt(5, 14).doc);
        // A chain of dittos all reach back to the one real comment.
        assert(m.tipAt(7, 14).doc == "Rounds `x` toward zero.", m.tipAt(7, 14).doc);
        // `private:` is a scope for lookup but not for ditto.
        assert(m.tipAt(13, 13).doc == "In an attribute block.", m.tipAt(13, 13).doc);
    });
}

@("visitor.docForSymbol.importedSymbolsCarryTheirDocs")
@system unittest
{
    // `DOC4`: DMD loads imports with `doDocComment = 0`, which drops every
    // comment outside the root module — `Analyzer` overrides that. Each of
    // these positions used to answer with a signature and nothing else.
    import std.algorithm.searching : canFind;

    enum src = q{
        import std.algorithm.iteration : map;         // Line 2
        auto squares(int[] xs)
        {
            return xs.map!(x => x * x);               // Line 5
        }
    };

    withAnalysis(src, (m) {
        // the module of a plain import, the selectively-imported name, and
        // the call site that instantiates it
        assert(m.tipAt(2, 30).doc.canFind("iteration"), "module ddoc");

        const sel = m.tipAt(2, 42);
        assert(sel.doc.canFind("homonym function"), "selective import ddoc");

        // The call site resolves to the eponymous member *inside*
        // `template map(fun...)`: the prose lives on the template, the
        // `Params:`/`Returns:` on the member, and both belong on the hover.
        const call = m.tipAt(5, 23);
        assert(call.doc.canFind("homonym function"), "template prose at the call site");
        assert(call.tags.canFind!(t => t.length > 1 && t[0] == "returns"),
            "the member's Returns: section");
    });
}

@("visitor.findTip.systemVariableKeepsItsMarker")
@system unittest
{
    // A `@system` variable's marker is a storage class, not part of its type,
    // so the tip used to drop the one annotation that changes how the symbol
    // may be used.
    enum src = "module test;\n"
        ~ "@system int unsafeGlobal;\n"
        ~ "int plainGlobal;\n";

    withAnalysis(src, (m) {
        checkTip(m, 2, 13, "(thread local global) `@system int test.unsafeGlobal`");
        checkTip(m, 3, 5, "(thread local global) `int test.plainGlobal`");
    });
}

@("visitor.findTip.aliasFunctionTypeParameters")
@system unittest
{
    // A function type's identifiers are as pointable as any others. The walk
    // used to follow only the `next` chain, so everything inside the
    // parentheses answered nothing while the same spellings resolved
    // elsewhere in the file — an underline with no tooltip behind it.
    enum src = "module test;\n"
        ~ "struct S { int x; }\n"
        ~ "alias F = void function(in S s, int n);\n";

    withAnalysis(src, (m) {
        checkTip(m, 3, 7, "(alias) `test.F = void function(in test.S s, int n)`");
        checkTip(m, 3, 28, "(struct) `test.S`");
        checkTip(m, 3, 30, "(parameter) `const(test.S) s`");
        checkTip(m, 3, 37, "(parameter) `int n`");
    });
}

@("visitor.findTip.ownModuleDeclaration")
@system unittest
{
    // The analyzed file's own `module pkg.source;` declaration takes effect
    // (upstream's `(package)`/`(module)` assertions): `Analyzer.analyze`
    // runs `Module.resolvePackage`, which `dmd.frontend.parseModule` alone
    // does not — without it every tip carries the filename-derived name.
    withAnalysis("module pkg.source;\nint x;\n", (m) {
        checkTip(m, 1, 8, "(package) `pkg`");
        checkTip(m, 1, 12, "(module) `pkg.source`");
        checkTip(m, 2, 5, "(thread local global) `int pkg.source.x`");
    });
}

@("visitor.findTip.manifestConstants")
@system unittest
{
    withAnalysis(constantSource, (m) {
        checkTip(m, 2, 14, "(constant) `int test.TTT = 9`");
        checkTip(m, 3, 14, "`void test.fun(int y = 9)`");
        checkTip(m, 3, 26, "(constant) `int test.TTT = 9`");  // in a default arg
        checkTip(m, 5, 21, "(constant) `int test.TTT = 9`");
        checkTip(m, 6, 27, "(constant) `string test.msg = \"fail\"`");
        checkTip(m, 6, 31, "(constant) `ulong \"fail\".length = 4LU`");
        checkTip(m, 8, 23, "(constant) `int test.TTT = 9`");  // in a static assert
        checkTip(m, 9, 14, "(constant) `string test.msg = \"fail\"`");
    });
}

@("visitor.findTip.templateInstance")
@system unittest
{
    withAnalysis(templateSource, (m) {
        checkTip(m, 2, 16, "(struct) `test.ST!int`");
        checkTip(m, 4, 13, "(alias) `T = int`");              // the type parameter
        checkTip(m, 4, 15, "(field) `int test.ST!int.f`");
        checkTip(m, 8, 13, "(struct) `test.ST!int`");
        checkTip(m, 8, 20, "(local variable) `test.ST!int v`");
    });
}

@("visitor.findTip.docComments")
@system unittest
{
    // Spec DOC1: a declaration's doc comment reaches the tip. `initAnalyzer`
    // sets `ddoc.doOutput` so the frontend keeps comments at all.
    withAnalysis(docSource, (m) {
        checkTip(m, 3, 13, "`int test.add(int a, int b)`\n\nAdds two numbers.");
        checkTip(m, 6, 16, "(struct) `test.Point`\n\nA point in the plane.");
        checkTip(m, 9, 17, "(field) `int test.Point.x`\n\nThe horizontal coordinate.");
        checkTip(m, 14, 21, "`int test.add(int a, int b)`\n\nAdds two numbers.");
    });
}

@("visitor.findTipData.structuredDoc")
@system unittest
{
    // The same query through the facade: kind / code / doc arrive apart
    // instead of pre-rendered, which is what the twoslash overlay needs.
    withAnalysis(docSource, (m) {
        auto fn = m.tipAt(3, 13);
        assert(fn.found);
        assert(fn.kind == "", fn.kind);           // functions render as bare code
        assert(fn.code == "int test.add(int a, int b)", fn.code);
        assert(fn.doc == "Adds two numbers.", fn.doc);

        auto field = m.tipAt(9, 17);
        assert(field.kind == "field", field.kind);
        assert(field.code == "int test.Point.x", field.code);
        assert(field.doc == "The horizontal coordinate.", field.doc);

        auto undocumented = m.tipAt(13, 19);
        assert(undocumented.kind == "local variable", undocumented.kind);
        assert(undocumented.doc == "", undocumented.doc);

        assert(!m.tipAt(13, 18).found);           // the space before `p`
    });
}

@("visitor.findDefinition.sameFile")
@system unittest
{
    withAnalysis(structSource, (m) {
        // `anS.fun(1)` -> the method declaration.
        auto method = m.definitionAt(11, 25);
        assert(method.found);
        assert(method.filename == "test.d", method.filename);
        assert(method.line == 6 && method.col == 17, "got " ~ method.filename);

        // `new S(1)` -> the struct declaration.
        auto type = m.definitionAt(15, 26);
        assert(type.line == 2 && type.col == 16);

        // `s.field1` -> the field declaration.
        auto field = m.definitionAt(17, 22);
        assert(field.line == 4 && field.col == 17);
    });
}

@("visitor.findDefinition.notFound")
@system unittest
{
    withAnalysis(structSource, (m) {
        assert(!m.definitionAt(2, 15).found);   // the space before `S`
    });
}

@("visitor.collectTips.perOccurrence")
@system unittest
{
    import std.conv : text;

    withAnalysis(structSource, (m) {
        auto tips = collectTips(m.module_);

        // Per occurrence, not run-length: `S` is one `IdentSpan` (see
        // `visitor.findIdentifierTypes.classification`) but five tips — its
        // declaration plus every use.
        int[2][] atS;
        foreach (o; tips)
            if (o.tip.code == "test.S")
                atS ~= [o.line, o.col];
        assert(atS == [[2, 16], [10, 13], [13, 17], [15, 26], [16, 26]], atS.text);

        // Ascending, one entry per position (the AliasDeclaration double
        // visit and the like collapse).
        foreach (i; 1 .. tips.length)
            assert(tips[i - 1].line < tips[i].line
                || (tips[i - 1].line == tips[i].line && tips[i - 1].col < tips[i].col),
                text(tips[i - 1], " then ", tips[i]));
    });
}

@("visitor.collectTips.matchesFindTipData")
@system unittest
{
    // The parity probe the batch pipeline rests on: at every position the
    // collector reports, its cached rendering must equal what a fresh
    // single-position walk resolves. Cheap here (small module, ~20 walks) and
    // far stronger than sampling.
    static void checkParity(string source, string file = __FILE__, size_t line = __LINE__)
    {
        import std.conv : text;

        withAnalysis(source, (m) {
            auto tips = collectTips(m.module_);
            assert(tips.length, "no occurrences collected");
            foreach (o; tips)
            {
                const one = findTipData(m.module_, o.line, o.col, o.line, o.col + 1,
                    addsize: false);
                assert(o.tip.kind == one.kind && o.tip.code == one.code
                    && o.tip.doc == one.doc && o.tip.symbol is one.symbol,
                    text("at ", o.line, ":", o.col, "\n  collected: ", o.tip,
                        "\n  findTipData: ", one, "\n  (from ", file, ":", line, ")"));
            }
        });
    }

    checkParity(structSource);
    checkParity(classSource);
    checkParity(enumSource);
    checkParity(constantSource);
    checkParity(templateSource);
    checkParity(docSource);
    checkParity(rewriteSource);
    checkParity(loweredSource);
}

@("visitor.findIdentifierTypes.classification")
@system unittest
{
    import std.conv : text;
    import sparkles.dmd_lsp.api : IdentSpan, TypeReferenceKind;

    withAnalysis(structSource, (m) {
        // The model is run-length (see `AnalyzedModule.identifierSpans`), which is
        // why `fun` appears twice — Method from line 6, then Function from line 13
        // — while `S`, used consistently, appears once.
        static immutable IdentSpan[] expected = [
            IdentSpan("S",       2, 16, TypeReferenceKind.Struct),
            IdentSpan("field1",  4, 17, TypeReferenceKind.MemberVariable),
            IdentSpan("stat1",   5, 25, TypeReferenceKind.TLSVariable),
            IdentSpan("fun",     6, 17, TypeReferenceKind.Method),
            IdentSpan("par",     6, 25, TypeReferenceKind.ParameterVariable),
            IdentSpan("foo",     8, 14, TypeReferenceKind.Function),
            IdentSpan("anS",    10, 15, TypeReferenceKind.LocalVariable),
            IdentSpan("x",      11, 17, TypeReferenceKind.LocalVariable),
            IdentSpan("fun",    13, 13, TypeReferenceKind.Function),
            IdentSpan("s",      13, 19, TypeReferenceKind.ParameterVariable),
            IdentSpan("p",      15, 18, TypeReferenceKind.LocalVariable),
            IdentSpan("seven",  16, 18, TypeReferenceKind.LocalVariable),
        ];

        auto actual = m.identifierSpans;
        assert(actual == expected, text("\n  expected: ", expected, "\n  actual:   ", actual));
    });
}
