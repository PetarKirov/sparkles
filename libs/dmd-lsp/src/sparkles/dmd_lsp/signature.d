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
import dmd.expression : Expression;
import dmd.hdrgen : HdrGenState, stcToBuffer, toCBuffer;
import dmd.id : Id;
import dmd.mtype : attributesApply, MODtoBuffer, Type, TypeFunction;
import dmd.statement : Statement;

/// A parenthesized list the renderer may explode one item per line.
///
/// `stage` is the staging order, not a nesting depth: the runtime parameter
/// list (stage 0) breaks before the template list (stage 1), because a reader
/// scanning a call cares about the arguments they pass first.
struct BreakGroup
{
    uint open;   /// byte offset of `(`
    uint close;  /// byte offset of `)`
    ubyte stage;
}

/// A place a line may break, always *before* `offset`.
struct BreakPoint
{
    uint offset;
    ubyte group; /// index into `SignatureInfo.groups`
}

/// Why a run of text is collapsible.
enum AbbrevKind : ubyte
{
    nestedTemplateArgs, /// `Foo!(Bar!(…))` — the inner arguments
    modulePrefix,       /// `sparkles.math.vector.Vector` — everything before `Vector`
}

/// A run the renderer may replace with `shortText` until the reader expands it.
/// The expansion is the slice itself, so the full form is never duplicated on
/// the wire and offsets never shift when it opens.
struct Abbrev
{
    uint offset;
    uint length;
    string shortText; /// `"…"`, or empty to elide the run entirely
    AbbrevKind kind;
}

/// Which of the four memory-safety states a function declares. `unspecified`
/// is a symbol that cannot carry one at all (a variable that is not `@system`).
enum SigTrust : ubyte { unspecified, system, trusted, safe }

/// A run of the signature text the renderer lifts out and draws as a chip.
/// The span covers the attribute word and the space that separates it, so
/// deleting every span leaves no double space behind.
struct EffectSpan
{
    uint offset; /// byte offset into the rendered signature
    uint length; /// byte length, separator included
}

/// The four effect attributes, as data rather than as trailing words.
struct Effects
{
    SigTrust trust;
    bool isPure, isNothrow, isNogc;

    /// The attributes are inferred per instantiation and this is the
    /// *uninstantiated* template, so a `false` above means "not yet known",
    /// not "not so" — a renderer must show those as unknown rather than as a
    /// denial.
    bool inferred;

    EffectSpan[] spans; /// ascending, disjoint

    /// Whether anything here is worth a chip row.
    bool any() const @safe pure nothrow @nogc
        => trust != SigTrust.unspecified || isPure || isNothrow || isNogc;
}

/// `in`/`out`, as written rather than as lowered.
enum ContractKind : ubyte { in_, out_ }

/// ditto
struct Contract
{
    ContractKind kind;
    string resultId; /// the `r` of `out (r; …)`; empty for `in` and `out (; …)`
    string text;     /// the expression, or the whole block when `isBlock`
    bool isBlock;    /// `in { … }` rather than `in (…)`
}

/// Everything the renderer needs about a signature that its text cannot say.
struct SignatureInfo
{
    Effects effects;
    Contract[] contracts;
    string constraint; /// the body of a template's `if (…)`, empty when none
    BreakGroup[] groups;
    BreakPoint[] breaks; /// ascending by offset
    Abbrev[] abbrevs;    /// ascending by offset, disjoint
}

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
    SignatureInfo ignored;
    return renderSignature(decl, td, ignored);
}

/// ditto, also reporting what the text alone cannot carry: the effect
/// attributes (lifted out of the words), the `in`/`out` contracts (which live
/// on the declaration, not on the type hdrgen renders) and a template's
/// constraint.
string renderSignature(Declaration decl, TemplateDeclaration td,
    out SignatureInfo info) @system
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

    readEffects(tf, td !is null, info.effects);

    if (td !is null)
        writePrefixFrame(tf, decl, td, buf, hgs, info);
    else
        writePostfixFrame(tf, decl, buf, hgs, info);

    scanTemplateArgs(buf[], info);

    if (auto fd = decl.isFuncDeclaration())
        info.contracts = readContracts(fd, hgs);
    if (td !is null && td.constraint !is null)
        info.constraint = exprText(td.constraint, hgs);

    return cast(string) buf.extractSlice();
}

/**
hdrgen's `visitFuncIdentWithPostfix`: `ret name(params) mod attrs…`.

The linkage prefix is deliberately absent — `hgs.ddoc` suppresses it upstream,
and the tip has always been rendered with ddoc on.
*/
private void writePostfixFrame(TypeFunction tf, Declaration decl,
    ref OutBuffer buf, ref HdrGenState hgs, ref SignatureInfo info) @system
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
    writeParameterList(tf, buf, hgs, info, runtimeStage);

    if (tf.mod)
    {
        buf.put(' ');
        MODtoBuffer(buf, tf.mod);
    }

    // The separator belongs to the span: excising `" @safe"` whole is what
    // keeps the remaining text from growing a double space.
    attributesApply(tf, (string str) {
        const at = cast(uint) buf.length;
        buf.put(' ');
        buf.put(str);
        if (isEffectWord(str))
            info.effects.spans ~= EffectSpan(at, cast(uint) buf.length - at);
    });
}

/**
hdrgen's `visitFuncIdentWithPrefix`: `attrs… ret name(tparams)(params) mod`.

`return`/`scope` are skipped in the attribute run and re-emitted as suffixes,
and a constructor drops both its return type and a leading `ref` — all of that
is upstream's shape, mirrored so the two texts agree.
*/
private void writePrefixFrame(TypeFunction tf, Declaration decl,
    TemplateDeclaration td, ref OutBuffer buf, ref HdrGenState hgs,
    ref SignatureInfo info) @system
{
    const ident = decl.getIdent();

    attributesApply(tf, (string str) {
        if (str == "return" || str == "scope")
            return;
        if (ident is Id.ctor && str == "ref")
            return;
        const at = cast(uint) buf.length;
        buf.put(str);
        buf.put(' ');
        // Prefix style puts the separator *after* the word, so the span runs
        // the other way — still one contiguous excision.
        if (isEffectWord(str))
            info.effects.spans ~= EffectSpan(at, cast(uint) buf.length - at);
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
        const group = cast(ubyte) info.groups.length;
        const open = cast(uint) buf.length;
        buf.put('(');
        foreach (i, p; *td.origParameters)
        {
            if (i)
                buf.put(", ");
            info.breaks ~= BreakPoint(cast(uint) buf.length, group);
            toCBuffer(p, buf, hgs);
        }
        info.groups ~= BreakGroup(open, cast(uint) buf.length, templateStage);
        buf.put(')');
    }

    writeParameterList(tf, buf, hgs, info, runtimeStage);

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
    ref HdrGenState hgs, ref SignatureInfo info, ubyte stage) @system
{
    import dmd.hdrgen : parameterToChars;

    auto pl = tf.parameterList;
    const group = cast(ubyte) info.groups.length;
    const open = cast(uint) buf.length;
    buf.put('(');
    foreach (i; 0 .. pl.length)
    {
        if (i)
            buf.put(", ");
        // The break belongs *before* the parameter, so an exploded list reads
        // one argument per line with the comma left on the line above.
        info.breaks ~= BreakPoint(cast(uint) buf.length, group);
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
    info.groups ~= BreakGroup(open, cast(uint) buf.length, stage);
    buf.put(')');
}

/// The four the user asked to see as chips. Everything else hdrgen emits in
/// that run (`@property`, `ref`, `scope`, `return`) describes the type, not an
/// effect, and stays in the text.
private bool isEffectWord(scope const(char)[] w) @safe pure nothrow @nogc
    => w == "pure" || w == "nothrow" || w == "@nogc"
        || w == "@safe" || w == "@trusted" || w == "@system";

/// Reads the effect attributes as data. `TRUSTformatSystem` is deliberate:
/// with the default format `attributesApply` stays silent when `trust` is
/// `TRUST.default_`, which is why an undecorated function has never shown
/// `@system` — but "not memory-safe" is exactly what a chip should say.
private void readEffects(TypeFunction tf, bool uninstantiated, ref Effects e) @system
{
    import dmd.astenums : PURE, TRUST;

    e.isPure = tf.purity != PURE.impure;
    e.isNothrow = tf.isNothrow;
    e.isNogc = tf.isNogc;
    e.inferred = uninstantiated;

    final switch (tf.trust)
    {
        // `TRUST.default_` means two different things. On an ordinary function
        // it is D's default — the function is not memory-safe, and saying so is
        // the point of the chip. On an uninstantiated template it means the
        // attribute has not been inferred yet, and claiming `@system` there
        // would be a lie the reader cannot check.
        case TRUST.default_:
            e.trust = uninstantiated ? SigTrust.unspecified : SigTrust.system;
            break;
        case TRUST.system:  e.trust = SigTrust.system;  break;
        case TRUST.trusted: e.trust = SigTrust.trusted; break;
        case TRUST.safe:    e.trust = SigTrust.safe;    break;
    }
}

/**
The `in`/`out` contracts, as written.

They never reached the signature before because they hang off
`FuncDeclaration` while hdrgen renders the `TypeFunction`. Read the
$(B unlowered) `frequires`/`fensures` — `frequire`/`fensure` are the generated
blocks, which read as compiler output rather than as the source.

The parser desugars `in (e)` into `assert(e)`, so unwrap it; upstream's
`contractsToBuffer` asserts on that shape, but a tooltip would rather show the
block than die on a form it did not expect.
*/
private Contract[] readContracts(FuncDeclaration fd, ref HdrGenState hgs) @system
{
    import dmd.expression : AssertExp;

    Contract[] result;

    if (auto reqs = fd.frequires)
        foreach (st; *reqs)
        {
            if (st is null)
                continue;
            if (auto es = st.isExpStatement())
                if (auto ae = es.exp ? es.exp.isAssertExp() : null)
                {
                    result ~= Contract(ContractKind.in_, null,
                        exprText(ae.e1, hgs), false);
                    continue;
                }
            result ~= Contract(ContractKind.in_, null, stmtText(st, hgs), true);
        }

    if (auto ens = fd.fensures)
        foreach (e; *ens)
        {
            if (e.ensure is null)
                continue;
            const id = e.id ? e.id.toString().idup : null;
            if (auto es = e.ensure.isExpStatement())
                if (auto ae = es.exp ? es.exp.isAssertExp() : null)
                {
                    result ~= Contract(ContractKind.out_, id,
                        exprText(ae.e1, hgs), false);
                    continue;
                }
            result ~= Contract(ContractKind.out_, id, stmtText(e.ensure, hgs), true);
        }

    return result;
}

/// ditto
private string exprText(Expression e, ref HdrGenState hgs) @system
{
    if (e is null)
        return null;
    OutBuffer b;
    toCBuffer(e, b, hgs);
    return cast(string) b.extractSlice();
}

/// ditto
private string stmtText(Statement st, ref HdrGenState hgs) @system
{
    if (st is null)
        return null;
    OutBuffer b;
    toCBuffer(st, b, hgs);
    return cast(string) b.extractSlice();
}

/**
Finds the template argument lists and the runs worth collapsing.

This is the one place a scan is unavoidable: hdrgen hands back a name like
`std.array.array!(MapResult!(__lambda_L8_C30, FilterResult!(…)))` as a single
opaque leaf, and `tiargsToBuffer` is private, so the structure inside it can
only be recovered by reading the text. That is tractable here because the
grammar is known and tiny — `!(`, brackets, and the three string forms — unlike
a scan of a whole signature, which cannot tell an attribute from a default
argument.

Records:
$(UL
$(LI a `templateStage` group per `!(…)`, so the renderer can explode one
    argument per line;)
$(LI an `Abbrev` over each $(I nested) argument list — depth 2 and beyond,
    since the outermost one is usually the interesting part;)
$(LI an `Abbrev` over each module qualifier, `a.b.C` → `C`.)
)

Abbreviations come back ascending and disjoint: a qualifier inside an already
collapsed argument list is dropped, because the renderer replaces whole runs.
*/
private void scanTemplateArgs(scope const(char)[] text, ref SignatureInfo info)
    @safe pure
{
    Abbrev[] nested;

    // One frame per open `!(`: where it started, and where its arguments
    // begin. The group index is only known when it closes, so the breaks are
    // held here and attached then.
    static struct Frame
    {
        uint open;
        uint[] argStarts;
        bool isTemplateArgs;
    }

    Frame[] stack;

    size_t i;
    while (i < text.length)
    {
        const c = text[i];

        // Strings and character literals hide everything: `!"+"`, `["x)", "y"]`
        // and a CTFE constant's body all live inside a signature.
        if (c == '"' || c == '`' || c == '\'')
        {
            i = skipLiteral(text, i);
            continue;
        }

        if (c == '!' && i + 1 < text.length && text[i + 1] == '(')
        {
            stack ~= Frame(cast(uint)(i + 1), [cast(uint)(i + 2)], true);
            i += 2;
            continue;
        }

        if (c == '(' && stack.length)
        {
            // A parenthesis inside an argument list — track it so the matching
            // close does not end the list early, and so a comma inside it is
            // not mistaken for an argument separator.
            stack ~= Frame(cast(uint) i, null, false);
            i++;
            continue;
        }

        if (c == ',' && stack.length && stack[$ - 1].isTemplateArgs)
        {
            // The next argument starts after the separator's space.
            uint at = cast(uint)(i + 1);
            while (at < text.length && text[at] == ' ')
                at++;
            stack[$ - 1].argStarts ~= at;
            i++;
            continue;
        }

        if (c == ')' && stack.length)
        {
            auto frame = stack[$ - 1];
            stack = stack[0 .. $ - 1];
            if (frame.isTemplateArgs)
            {
                const group = cast(ubyte) info.groups.length;
                info.groups ~= BreakGroup(frame.open, cast(uint) i, templateStage);
                // Without these the list has nowhere to break and "exploding"
                // it only moves its `)` to a line of its own.
                foreach (at; frame.argStarts)
                    if (at < i)
                        info.breaks ~= BreakPoint(at, group);
                // Depth 2+: the argument list of an argument.
                if (stack.length)
                    nested ~= Abbrev(frame.open + 1, cast(uint)(i - frame.open - 1),
                        "…", AbbrevKind.nestedTemplateArgs);
            }
            i++;
            continue;
        }

        i++;
    }

    info.abbrevs = mergeAbbrevs(nested, scanModulePrefixes(text));
}

/**
The leading module qualifier of a dotted chain, as the run to elide.

Only the $(I leading) run: `std.range.iota!(int, int).Result` elides `std.range.`
and keeps `iota!(int, int).Result`, because everything from the first
instantiated or capitalized component onward names types and members rather
than packages. Eliding to the last dot instead would silently drop `.Result`,
which is the part carrying the meaning.

The test is D's own naming convention — packages and modules are lowercase —
so it is a heuristic, but a wrong guess only ever hides a qualifier the reader
can expand again.
*/
private Abbrev[] scanModulePrefixes(scope const(char)[] text) @safe pure
{
    Abbrev[] result;
    size_t i;
    while (i < text.length)
    {
        const c = text[i];
        if (c == '"' || c == '`' || c == '\'')
        {
            i = skipLiteral(text, i);
            continue;
        }
        if (!isIdentStart(c))
        {
            i++;
            continue;
        }

        const start = i;
        size_t elideEnd; // one past the last dot that is still a qualifier
        while (i < text.length)
        {
            const compStart = i;
            while (i < text.length && isIdentChar(text[i]))
                i++;

            // A qualifier component is followed by a dot and another
            // identifier; a lone trailing name (or `1.5`) is not one.
            const dotted = i + 1 < text.length && text[i] == '.'
                && isIdentStart(text[i + 1]);
            if (!dotted)
                break;

            const instantiated = i < text.length && text[i] == '!';
            const capitalized = text[compStart] >= 'A' && text[compStart] <= 'Z';
            if (instantiated || capitalized)
                break; // a type or a member — the qualifier ended before it

            elideEnd = i + 1;
            i++; // past the dot
        }

        // Skip whatever remains of the chain so its members are not rescanned
        // as fresh qualifiers.
        while (i < text.length && (isIdentChar(text[i])
            || (text[i] == '.' && i + 1 < text.length && isIdentStart(text[i + 1]))))
            i++;

        if (elideEnd > start)
            result ~= Abbrev(cast(uint) start, cast(uint)(elideEnd - start),
                null, AbbrevKind.modulePrefix);
    }
    return result;
}

/// Ascending and disjoint: a qualifier inside a collapsed argument list is
/// dropped, because the renderer swaps whole runs and a nested marker would
/// have nothing to attach to.
private Abbrev[] mergeAbbrevs(Abbrev[] nested, Abbrev[] prefixes) @safe pure
{
    import std.algorithm.sorting : sort;

    auto result = nested.dup;
    foreach (px; prefixes)
    {
        bool covered;
        foreach (n; nested)
            if (px.offset >= n.offset && px.offset + px.length <= n.offset + n.length)
            {
                covered = true;
                break;
            }
        if (!covered)
            result ~= px;
    }
    result.sort!((a, b) => a.offset < b.offset);
    return result;
}

/// Past the string or character literal starting at `i`, escapes included.
private size_t skipLiteral(scope const(char)[] text, size_t i) @safe pure nothrow @nogc
{
    const quote = text[i];
    i++;
    while (i < text.length)
    {
        if (quote != '`' && text[i] == '\\' && i + 1 < text.length)
        {
            i += 2;
            continue;
        }
        if (text[i] == quote)
            return i + 1;
        i++;
    }
    return i; // unterminated: consume the rest rather than rescan it as code
}

/// The engine's own identifier predicates, so a scan over hdrgen's output
/// agrees with the lexer that produced it. `dmd.doc` takes a pointer because it
/// decodes UTF-8 for the non-ASCII ranges; these signatures are ASCII by
/// construction, so a one-character view is enough.
private bool isIdentStart(char c) @trusted pure nothrow @nogc
{
    import dmd.doc : isIdStart;

    const char[2] buf = [c, '\0'];
    return isIdStart(buf.ptr);
}

/// ditto
private bool isIdentChar(char c) @trusted pure nothrow @nogc
{
    import dmd.doc : isIdTail;

    const char[2] buf = [c, '\0'];
    return isIdTail(buf.ptr);
}

/// The staging order the renderer walks: the runtime list explodes before the
/// template one.
private enum ubyte runtimeStage = 0;
/// ditto
private enum ubyte templateStage = 1;

/// The `const(char)*` hdrgen hands back, as a slice.
private const(char)[] toDStr(const(char)* s) @system
{
    import core.stdc.string : strlen;

    return s is null ? null : s[0 .. strlen(s)];
}

@("signature.scanTemplateArgs.ignoresStringsAndLiterals")
@safe pure unittest
{
    // A signature carries `!"+"`, `["x", "y"]` and lambdas; a scanner that
    // reads a `)` inside a literal as structure corrupts every later offset.
    SignatureInfo info;
    enum text = `Vector!(float, 4LU, ["x)", "y!("]) test.opBinary!"+"(int a)`;
    scanTemplateArgs(text, info);

    foreach (g; info.groups)
    {
        assert(g.open < g.close && g.close < text.length);
        assert(text[g.open] == '(' && text[g.close] == ')',
            text[g.open .. g.close + 1]);
    }
    foreach (a; info.abbrevs)
        assert(a.offset + a.length <= text.length);
}

@("signature.scanModulePrefixes.elidesQualifiersOnly")
@safe pure unittest
{
    // The qualifier is the run up to and including the last dot, and a dot
    // that is not between two identifiers is not one.
    static string[] elided(string text)
    {
        string[] r;
        foreach (a; scanModulePrefixes(text))
            r ~= text[a.offset .. a.offset + a.length];
        return r;
    }

    assert(elided("sparkles.math.vector.Vector") == ["sparkles.math.vector."]);
    assert(elided("int test.f(int x)") == ["test."]);
    assert(elided("auto f(double d = 1.5)") == []);
    assert(elided(`f(string s = "a.b.c")`) == [], "a literal is not a qualifier");

    // Stop at the first component that names a type or an instantiation:
    // eliding to the last dot would drop `.Result`, which carries the meaning.
    assert(elided("std.range.iota!(int, int).Result") == ["std.range."]);
    assert(elided("core.internal.array.construction._d_arrayliteralTX!(char[])")
        == ["core.internal.array.construction."]);
    assert(elided("sparkles.math.vector.Vector!(float, 2LU).opEquals")
        == ["sparkles.math.vector."]);
}

@("signature.renderSignature.offsetsAreSaneAndUtf8Aligned")
@system unittest
{
    // Everything the renderer slices by must land inside the text and on a
    // UTF-8 boundary — it splits styled spans at exactly these points.
    import std.algorithm.searching : canFind;

    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;
        import std.traits : isIntegral;

        int plain(int a, int b) pure @safe { return a + b; }
        T twice(T)(T x, string label = "a, b") if (isIntegral!T) { return x * 2; }
        int none() { return 0; }
    };

    withAnalysis(src, (m) {
        size_t checked;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            const text = renderSignature(decl, td, info);
            if (text is null)
                return;
            ++checked;

            assertOffsetsSane(text, info);
        });
        assert(checked >= 3);
    });
}

@("signature.renderSignature.breaksMatchTheParameters")
@system unittest
{
    // One break before each parameter, and the runtime list stages ahead of
    // the template one.
    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;
        T pick(T, U)(T first, U second, int third) { return first; }
    };

    withAnalysis(src, (m) {
        size_t seen;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            const text = renderSignature(decl, td, info);
            if (text is null || td is null)
                return;
            ++seen;

            size_t runtime, template_;
            foreach (b; info.breaks)
            {
                if (info.groups[b.group].stage == runtimeStage)
                    ++runtime;
                else
                    ++template_;
            }
            assert(runtime == 3, text);   // first, second, third
            assert(template_ == 2, text); // T, U

            // The first parameter of each list starts right after its `(`.
            foreach (b; info.breaks)
                if (b.offset == info.groups[b.group].open + 1)
                    assert(text[b.offset] != ',', text);
        });
        assert(seen == 1);
    });
}

@("signature.readEffects.dataNotWords")
@system unittest
{
    // The four effects come off the type, not out of the text — so a default
    // argument that happens to spell one cannot forge it, and an undecorated
    // function reports `@system` even though hdrgen stays silent about it.
    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;

        int decorated(int x) pure nothrow @nogc @safe { return x; }
        int bare(string s = "pure nothrow @nogc @safe") { return 0; }
        int trusted(int x) @trusted { return x; }
    };

    withAnalysis(src, (m) {
        SignatureInfo[string] byName;
        string[string] textByName;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            const text = renderSignature(decl, td, info);
            if (text is null)
                return;
            byName[decl.ident.toString().idup] = info;
            textByName[decl.ident.toString().idup] = text;
        });

        const dec = byName["decorated"];
        assert(dec.effects.isPure && dec.effects.isNothrow && dec.effects.isNogc);
        assert(dec.effects.trust == SigTrust.safe);
        assert(dec.effects.spans.length == 4, "one span per effect word");

        const bare = byName["bare"];
        assert(!bare.effects.isPure && !bare.effects.isNothrow && !bare.effects.isNogc,
            "a string literal is not an attribute");
        assert(bare.effects.trust == SigTrust.system, "undecorated is @system");
        assert(bare.effects.spans.length == 0, textByName["bare"]);

        assert(byName["trusted"].effects.trust == SigTrust.trusted);
        assert(!dec.effects.inferred, "an ordinary function's effects are known");
    });
}

@("signature.readEffects.uninstantiatedTemplateIsUnknownNotDenied")
@system unittest
{
    // A template's attributes are inferred per instantiation, so rendering the
    // declaration and reporting `@system`/not-pure would state as fact what
    // the compiler has not decided.
    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;
        T inferAll(T)(T x) { return x; }
        T explicit(T)(T x) @safe pure { return x; }
    };

    withAnalysis(src, (m) {
        SignatureInfo[string] byName;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            if (renderSignature(decl, td, info) !is null && td !is null)
                byName[decl.ident.toString().idup] = info;
        });

        const a = byName["inferAll"].effects;
        assert(a.inferred, "an uninstantiated template infers its attributes");
        assert(a.trust == SigTrust.unspecified, "not @system — merely unknown");

        // What the source states explicitly is still known.
        const e = byName["explicit"].effects;
        assert(e.trust == SigTrust.safe && e.isPure);
    });
}

@("signature.readEffects.spansAreExcisable")
@system unittest
{
    // The renderer deletes these ranges and draws chips instead; doing so must
    // leave text that still reads as a signature.
    import std.algorithm.searching : canFind;
    import std.string : strip;

    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;
        int f(int x) pure nothrow @nogc @safe { return x; }
    };

    withAnalysis(src, (m) {
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            const text = renderSignature(decl, td, info);
            if (text is null || !info.effects.spans.length)
                return;

            // Excise back to front so earlier offsets stay valid.
            string cut = text;
            foreach_reverse (sp; info.effects.spans)
                cut = cut[0 .. sp.offset] ~ cut[sp.offset + sp.length .. $];

            assert(cut == "int test.f(int x)", cut);
            assert(!cut.canFind("  "), "excision left a double space: " ~ cut);
            assert(cut.strip == cut, "excision left an edge space: " ~ cut);
        });
    });
}

@("signature.readContracts.inOutAsWritten")
@system unittest
{
    // Contracts hang off the declaration, not the type, which is why the
    // signature never carried them.
    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;

        int guarded(int x)
        in (x > 0)
        out (r; r > x)
        {
            return x + 1;
        }

        int blockForm(int x)
        in { assert(x > 0); }
        out { }
        do { return x; }

        int anonymousOut(int x) out (; true) { return x; }
    };

    withAnalysis(src, (m) {
        SignatureInfo[string] byName;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            if (renderSignature(decl, td, info) !is null)
                byName[decl.ident.toString().idup] = info;
        });

        const g = byName["guarded"];
        assert(g.contracts.length == 2, "expected one in and one out");
        assert(g.contracts[0].kind == ContractKind.in_);
        assert(g.contracts[0].text == "x > 0", g.contracts[0].text);
        assert(!g.contracts[0].isBlock);
        assert(g.contracts[1].kind == ContractKind.out_);
        assert(g.contracts[1].resultId == "r", g.contracts[1].resultId);
        assert(g.contracts[1].text == "r > x", g.contracts[1].text);

        assert(byName["blockForm"].contracts.length == 2);
        assert(byName["blockForm"].contracts[0].isBlock, "in { … } is a block");

        const a = byName["anonymousOut"];
        assert(a.contracts.length == 1 && a.contracts[0].resultId.length == 0,
            "out (; …) names no result");
    });
}

@("signature.renderSignature.templateConstraint")
@system unittest
{
    // The constraint is the one clause hdrgen already prints for a template
    // *symbol*; for the function itself it lives on the TemplateDeclaration.
    import std.algorithm.searching : canFind;

    import sparkles.dmd_lsp.testing : withAnalysis;

    enum src = q{
        module test;
        import std.traits : isIntegral;

        T twice(T)(T x) if (isIntegral!T) { return x * 2; }
    };

    withAnalysis(src, (m) {
        size_t seen;
        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            if (renderSignature(decl, td, info) is null || td is null)
                return;
            ++seen;
            assert(info.constraint.canFind("isIntegral"), info.constraint);
        });
        assert(seen == 1, "the eponymous template was not reached");
    });
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
    size_t files, checked, diverged, prefixFrame, withAbbrevs;
    string firstDiff;
    foreach (path; candidates)
    {
        if (!path.exists)
            continue;
        ++files;

        auto analyzer = Analyzer(analyzerConfigForTest());
        auto m = analyzer.analyze(path, readText(path));

        walkFunctions(m.module_, (Declaration decl, TemplateDeclaration td) {
            SignatureInfo info;
            const mine = renderSignature(decl, td, info);
            const theirs = viaHdrgen(decl, td);
            if (theirs is null)
                return;
            ++checked;
            if (mine !is null)
            {
                assertOffsetsSane(mine, info);
                if (info.abbrevs.length)
                    ++withAbbrevs;
            }
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
    // Real modules are full of qualified names; a scan that found nothing to
    // collapse would be silently inert.
    assert(withAbbrevs > 20, "the abbreviation scan found almost nothing");
    assert(diverged == 0, firstDiff);
}

version (unittest)
{
    import dmd.dmodule : Module;
    import dmd.attrib : AttribDeclaration;
    import dmd.dsymbol : Dsymbol, ScopeDsymbol;
    import dmd.hdrgen : functionToBufferFull, functionToBufferWithIdent;

    /// Every offset the renderer will slice by: inside the text, on a UTF-8
    /// boundary, and — for abbreviations — disjoint and ascending, since the
    /// renderer swaps whole runs.
    private void assertOffsetsSane(string text, in SignatureInfo info) @safe pure
    {
        static bool aligned(string t, size_t at)
            => at == t.length || (t[at] & 0xC0) != 0x80;

        foreach (g; info.groups)
        {
            assert(g.open < g.close && g.close < text.length, text);
            assert(text[g.open] == '(' && text[g.close] == ')', text);
            assert(g.stage == runtimeStage || g.stage == templateStage, text);
        }
        foreach (b; info.breaks)
        {
            assert(b.offset <= text.length && aligned(text, b.offset), text);
            assert(b.group < info.groups.length, text);
            const g = info.groups[b.group];
            assert(b.offset > g.open && b.offset <= g.close, text);
        }
        uint prevEnd;
        foreach (a; info.abbrevs)
        {
            assert(a.offset + a.length <= text.length, text);
            assert(aligned(text, a.offset) && aligned(text, a.offset + a.length), text);
            assert(a.offset >= prevEnd, "abbrevs must be disjoint: " ~ text);
            prevEnd = a.offset + a.length;
        }
        foreach (sp; info.effects.spans)
            assert(sp.offset + sp.length <= text.length, text);
    }

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
