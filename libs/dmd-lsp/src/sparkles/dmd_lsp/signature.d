/**
The structured hover signature (spec `TIP5`).

A hover's signature is one long line today — `int std.array.array!(MapResult!(…))(…)
pure nothrow @nogc @safe` — because `dmd.hdrgen` prints declarations for a header
file, where a line is a line. A viewer wants more: where the line $(I may) break,
which parts are noise it can collapse, and which trailing words are effects that
belong in chips rather than in the text.

None of that survives a scan of the finished string. The two hdrgen frames put
attributes on opposite sides, so a scanner cannot tell a template parameter list
from a runtime one without consulting the AST anyway; `pure` can occur inside a
default argument (`int f(string s = "pure")`); and contracts never reach the
string at all, because they hang off `FuncDeclaration` while hdrgen renders the
`TypeFunction`.

So this module re-walks the frames — `visitFuncIdentWithPrefix` and
`visitFuncIdentWithPostfix` (`dmd.hdrgen`) — and lets hdrgen print every leaf,
recording structure as it goes. This first slice is the $(B frame only): it
reproduces today's text byte for byte and reports nothing else, so the
differential test below is free to be the regression net for everything built on
top of it.
*/
module sparkles.dmd_lsp.signature;

import dmd.astenums : LINK, MODFlags, STC, VarArg;
import dmd.common.outbuffer : OutBuffer;
import dmd.declaration : Declaration;
import dmd.dtemplate : TemplateDeclaration;
import dmd.func : FuncDeclaration;
import dmd.hdrgen : HdrGenState, stcToBuffer, toCBuffer;
import dmd.id : Id;
import dmd.mtype : attributesApply, MODtoBuffer, Type, TypeFunction;

/**
Renders `decl`'s signature exactly as the hover shows it today.

`td` is the enclosing template for the eponymous-template shape (hdrgen's
"prefix" frame: attributes first, a bare identifier, and two parameter lists);
pass null for everything else, which takes the "postfix" frame (attributes last,
a fully-qualified name).

Returns the rendered signature, or null when `decl` has no function type — the
caller keeps its own fallback for that.
*/
string renderSignature(Declaration decl, TemplateDeclaration td) @system
{
    auto tf = decl.type ? decl.type.isTypeFunction() : null;
    if (tf is null)
        return null;

    // `inuse` is hdrgen's recursion guard for a self-referential type; it bails
    // rather than looping, and so must we, or the two texts diverge.
    if (tf.inuse)
        return null;

    HdrGenState hgs = { ddoc: true, fullQual: true };
    OutBuffer buf;

    if (td !is null)
        writePrefixFrame(tf, decl, td, buf, hgs);
    else
        writePostfixFrame(tf, decl, buf, hgs);

    return cast(string) buf.extractSlice();
}

/**
hdrgen's `visitFuncIdentWithPostfix`: `ret name(params) mod attrs…`.

The linkage prefix is deliberately absent — `hgs.ddoc` suppresses it upstream,
and the tip has always been rendered with ddoc on.
*/
private void writePostfixFrame(TypeFunction tf, Declaration decl,
    ref OutBuffer buf, ref HdrGenState hgs) @system
{
    if (tf.next)
    {
        hgs.inFuncReturn = true;
        toCBuffer(tf.next, buf, null, hgs);
        hgs.inFuncReturn = false;
        buf.put(' ');
    }
    else
        buf.put("auto ");

    buf.put(decl.toPrettyChars(true).toDStr);
    writeParameterList(tf, buf, hgs);

    if (tf.mod)
    {
        buf.put(' ');
        MODtoBuffer(buf, tf.mod);
    }

    attributesApply(tf, (string str) { buf.put(' '); buf.put(str); });
}

/**
hdrgen's `visitFuncIdentWithPrefix`: `attrs… ret name(tparams)(params) mod`.

`return`/`scope` are skipped in the attribute run and re-emitted as suffixes,
and a constructor drops both its return type and a leading `ref` — all of that
is upstream's shape, mirrored so the two texts agree.
*/
private void writePrefixFrame(TypeFunction tf, Declaration decl,
    TemplateDeclaration td, ref OutBuffer buf, ref HdrGenState hgs) @system
{
    const ident = decl.getIdent();

    attributesApply(tf, (string str) {
        if (str == "return" || str == "scope")
            return;
        if (ident is Id.ctor && str == "ref")
            return;
        buf.put(str);
        buf.put(' ');
    });

    // A constructor/destructor/unittest prints no return type: upstream detects
    // it by the identifier rendering differently in "H" form.
    const suppressReturn = ident !is null
        && ident.toHChars2().toDStr != ident.toChars().toDStr;
    if (suppressReturn)
    {
        // nothing
    }
    else if (tf.next)
    {
        hgs.inFuncReturn = true;
        toCBuffer(tf.next, buf, null, hgs);
        hgs.inFuncReturn = false;
        if (ident !is null)
            buf.put(' ');
    }
    else
        buf.put("auto ");

    if (ident !is null)
        buf.put(ident.toHChars2().toDStr);

    if (td.origParameters !is null)
    {
        buf.put('(');
        foreach (i, p; *td.origParameters)
        {
            if (i)
                buf.put(", ");
            toCBuffer(p, buf, hgs);
        }
        buf.put(')');
    }

    writeParameterList(tf, buf, hgs);

    // With ddoc on, the type constructor reads better after the parameters.
    if (tf.mod)
    {
        buf.put(' ');
        MODtoBuffer(buf, tf.mod);
    }

    if (tf.isReturnScope && !tf.isReturnInferred)
        buf.put(" return scope");
    else if (tf.isScopeQual && !tf.isScopeInferred)
        buf.put(" scope");
    if (tf.isReturn && !tf.isReturnScope && !tf.isReturnInferred)
        buf.put(" return");
}

/**
hdrgen's `parametersToBuffer`, which is private to that module.

Each parameter goes through the public `parameterToChars`, whose one divergence
is that it builds a fresh `HdrGenState` carrying only `fullQual` — it drops the
`ddoc` flag, which upstream consults when a parameter's own type is a function
or delegate with non-D linkage. `signature.matchesHdrgen` is what proves that
never bites in practice; if it ever does, the fix is to widen the fork's public
surface rather than to guess here.
*/
private void writeParameterList(TypeFunction tf, ref OutBuffer buf,
    ref HdrGenState hgs) @system
{
    import dmd.hdrgen : parameterToChars;

    auto pl = tf.parameterList;
    buf.put('(');
    foreach (i; 0 .. pl.length)
    {
        if (i)
            buf.put(", ");
        buf.put(parameterToChars(pl[i], tf, hgs.fullQual).toDStr);
    }

    final switch (pl.varargs)
    {
        case VarArg.none:
        case VarArg.KRvariadic:
            break;

        case VarArg.variadic:
            if (pl.length)
                buf.put(", ");
            if (stcToBuffer(buf, pl.stc))
                buf.put(' ');
            goto case VarArg.typesafe;

        case VarArg.typesafe:
            // `parameterToChars` already appended the `...` of a typesafe
            // variadic to its last parameter.
            if (pl.varargs == VarArg.variadic)
                buf.put("...");
            break;
    }
    buf.put(')');
}

/// The `const(char)*` hdrgen hands back, as a slice.
private const(char)[] toDStr(const(char)* s) @system
{
    import core.stdc.string : strlen;

    return s is null ? null : s[0 .. strlen(s)];
}

@("signature.renderSignature.matchesHdrgen")
@system unittest
{
    // The regression net for everything built on this frame: over a corpus that
    // covers both hdrgen shapes, the re-walked text must equal the string the
    // hover renders today, byte for byte.
    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;

        import core.stdc.stdarg; // the C-variadic case below needs it

        int plain(int x) { return x; }
        int attrs(in char[] s, ref int n) pure nothrow @nogc @safe { return n; }
        T eponymous(T)(T value, string label = "pure nothrow") { return value; }
        void variadic(int first, ...) {}
        void typesafeVariadic(int[] xs...) {}
        auto inferred(int x) { return x; }

        struct S
        {
            int method(int x) const @safe { return x; }
            this(int x) {}
            ~this() {}
            static int stat(int x) { return x; }
        }
    };

    withAnalysis(src, (m) {
        size_t checked;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            const mine = renderSignature(decl, td);
            const theirs = viaHdrgen(decl, td);
            if (theirs is null)
                return;
            assert(mine == theirs,
                "\n  hdrgen: " ~ theirs ~ "\n  ours:   " ~ (mine is null ? "(null)" : mine));
            ++checked;
        });
        assert(checked >= 8, "the corpus stopped covering the frames");
    });
}

@("signature.renderSignature.matchesHdrgenOnRealSources")
@system unittest
{
    // The synthetic corpus above pins the shapes; this one pins reality. Real
    // sources are where the divergence risks live — `parameterToChars` drops
    // the `ddoc` flag, templates nest, and Phobos types qualify to absurd
    // lengths — so run the same equality over whole modules of this repo.
    import std.file : exists, readText;

    import sparkles.dmd_lsp.api : Analyzer, AnalyzedModule;
    import sparkles.dmd_lsp.testing : analyzerConfigForTest;

    static immutable candidates = [
        "libs/base/src/sparkles/base/smallbuffer.d",
        "libs/versions/src/sparkles/versions/schemes/semver.d",
        "libs/math/src/sparkles/math/vector.d",
    ];

    // One analysis per Analyzer (COR2), so each file gets its own session.
    size_t files, checked, diverged, prefixFrame;
    string firstDiff;
    foreach (path; candidates)
    {
        if (!path.exists)
            continue;
        ++files;

        auto analyzer = Analyzer(analyzerConfigForTest());
        auto m = analyzer.analyze(path, readText(path));

        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            const mine = renderSignature(decl, td);
            const theirs = viaHdrgen(decl, td);
            if (theirs is null)
                return;
            ++checked;
            if (td !is null)
                ++prefixFrame;
            if (mine != theirs)
            {
                ++diverged;
                if (!firstDiff.length)
                    firstDiff = path ~ ":\n  hdrgen: " ~ theirs
                        ~ "\n  ours:   " ~ (mine is null ? "(null)" : mine);
            }
        });
    }

    if (files == 0)
    {
        version (Have_sparkles_test_runner)
        {
            import sparkles.test_runner.skip : skipTest;

            skipTest("run from the repo root to check real sources");
        }
        return;
    }

    // `semver.d`/`vector.d` are where the *prefix* frame lives (uninstantiated
    // eponymous templates), which is the half a synthetic corpus under-covers.
    assert(checked > 100, "too few functions to be a real check");
    // A sweep that only ever took the postfix frame would pass while leaving
    // the harder half untested.
    assert(prefixFrame > 0, "the sweep never hit the prefix frame");
    assert(diverged == 0, firstDiff);
}

version (unittest)
{
    import dmd.dmodule : Module;
    import dmd.attrib : AttribDeclaration;
    import dmd.dsymbol : Dsymbol, ScopeDsymbol;
    import dmd.hdrgen : functionToBufferFull, functionToBufferWithIdent;

    /// What the hover renders today — the oracle both differential tests
    /// compare against.
    private string viaHdrgen(Declaration decl, TemplateDeclaration td) @system
    {
        auto tf = decl.type ? decl.type.isTypeFunction() : null;
        if (tf is null)
            return null;
        HdrGenState hgs = { ddoc: true, fullQual: true };
        OutBuffer buf;
        if (td !is null)
            functionToBufferFull(tf, buf, decl.getIdent(), hgs, td);
        else
            functionToBufferWithIdent(tf, buf, decl.toPrettyChars(true), hgs,
                decl.isFuncDeclaration().isStatic);
        return cast(string) buf.extractSlice();
    }

    /// Visits every function declaration in `sym`, paired with the enclosing
    /// template when it is an eponymous member (the prefix frame's trigger,
    /// mirroring `visitor.tipForDeclaration`).
    private void walkFunctions(Dsymbol sym,
        scope void delegate(Declaration, TemplateDeclaration) @system dg) @system
    {
        if (sym is null)
            return;
        if (auto fd = sym.isFuncDeclaration())
        {
            auto td = fd.type && fd.parent
                ? fd.parent.isTemplateDeclaration() : null;
            dg(fd, td);
        }
        // `@safe:` / `version (…) { … }` / `private:` wrap their members in an
        // AttribDeclaration, which is not a ScopeDsymbol — without this the
        // walk misses most of a real module.
        if (auto ad = sym.isAttribDeclaration())
        {
            if (ad.decl !is null)
                foreach (member; *ad.decl)
                    walkFunctions(member, dg);
            return;
        }
        if (auto sds = sym.isScopeDsymbol())
            if (sds.members !is null)
                foreach (member; *sds.members)
                    walkFunctions(member, dg);
    }
}
