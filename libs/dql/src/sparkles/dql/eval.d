module sparkles.dql.eval;

import std.regex : matchFirst;
import std.sumtype : match;

import sparkles.base.text.span : TextSpan;
import sparkles.dql.ast;
import sparkles.dql.engine : DqlEngine;
import sparkles.fuzzy.common : CandidateView;
import sparkles.fuzzy.glob : globMatch;
import sparkles.fuzzy.match : MatchKind, match;

@safe:

/// Compares two typed AST `DqlValue` literals under relational or equality operator `op`.
bool compareValues(ref const DqlEngine engine, in DqlValue actual, DqlOp op, in DqlValue target) pure nothrow @nogc
{
    return actual.match!(
        (in TextSpan aSpan) => target.match!(
            (in TextSpan tSpan) => compareString(engine.textOf(aSpan), op, engine.textOf(tSpan)),
            _ => false
        ),
        (in typeof(null)) => target.match!(
            (in typeof(null)) => (op == DqlOp.eq),
            _ => false
        ),
        (in bool aBool) => target.match!(
            (in bool tBool) => (op == DqlOp.eq) ? (aBool == tBool) : ((op == DqlOp.neq) ? (aBool != tBool) : false),
            _ => false
        ),
        (in long aInt) => target.match!(
            (in bool tBool) => false,
            (in long tInt) => compareScalar(aInt, op, tInt),
            (in double tNum) => compareScalar(cast(double) aInt, op, tNum),
            _ => false
        ),
        (in double aNum) => target.match!(
            (in bool tBool) => false,
            (in long tInt) => compareScalar(aNum, op, cast(double) tInt),
            (in double tNum) => compareScalar(aNum, op, tNum),
            _ => false
        ),
    );
}

/// Compares two string slices under the specified operator.
bool compareString(scope const(char)[] actual, DqlOp op, scope const(char)[] target) pure nothrow @nogc
{
    final switch (op)
    {
        case DqlOp.eq:  return actual == target;
        case DqlOp.neq: return actual != target;
        case DqlOp.lt:  return actual < target;
        case DqlOp.lte: return actual <= target;
        case DqlOp.gt:  return actual > target;
        case DqlOp.gte: return actual >= target;
    }
}

/// Compares two scalar numbers under the specified operator.
private bool compareScalar(T, U)(T actual, DqlOp op, U target) pure nothrow @nogc
{
    final switch (op)
    {
        case DqlOp.eq:  return actual == target;
        case DqlOp.neq: return actual != target;
        case DqlOp.lt:  return actual < target;
        case DqlOp.lte: return actual <= target;
        case DqlOp.gt:  return actual > target;
        case DqlOp.gte: return actual >= target;
    }
}

/// Evaluates a regular expression against an input string using the engine's compiled regex storage.
bool evalRegex(ref DqlEngine engine, scope const(char)[] text, in RegexPayload payload)
{
    if (payload.regexIndex >= engine.regexHolders.length)
        return false;
    return () @trusted {
        return !matchFirst(text, engine.regexHolders[payload.regexIndex].regex).empty;
    }();
}

/// Evaluates a precompiled glob pattern reusing the engine's storage and workspace.
bool evalGlob(ref DqlEngine engine, scope const(char)[] text, in GlobPayload payload) nothrow @nogc
{
    if (payload.globIndex >= engine.globPrograms.length)
        return false;
    auto matched = globMatch(engine.globPrograms[payload.globIndex], text, engine.globWorkspace);
    if (matched.hasError)
        return false;
    return matched.value;
}

/// Evaluates a pre-parsed fuzzy query reusing the engine's storage and workspace.
bool evalFuzzy(ref DqlEngine engine, scope const(char)[] text, in FuzzyPayload payload) nothrow @nogc
{
    if (payload.fuzzyIndex >= engine.fuzzyQueries.length)
        return false;
    CandidateView candidate;
    candidate.path = text;
    candidate.filenameOffset = 0;

    auto result = match(engine.fuzzyQueries[payload.fuzzyIndex], candidate, engine.matcherWorkspace);
    if (result.hasError)
        return false;
    return result.value.kind != MatchKind.rejected;
}

private bool resolveFieldString(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out const(char)[] value) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveString(path, value)))
        return resolver.resolveString(path, value);
    else static if (__traits(compiles, () @safe => resolver.resolveValue(path, value)))
        return resolver.resolveValue(path, value);
    else
        return false;
}

private bool resolveFieldNumber(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out double value) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveNumber(path, value)))
        return resolver.resolveNumber(path, value);
    else static if (__traits(compiles, () @safe => resolver.resolveValue(path, value)))
        return resolver.resolveValue(path, value);
    else
        return false;
}

private bool resolveFieldInt(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out long value) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveInt(path, value)))
        return resolver.resolveInt(path, value);
    else static if (__traits(compiles, () @safe => resolver.resolveValue(path, value)))
        return resolver.resolveValue(path, value);
    else
        return false;
}

private bool resolveFieldBool(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out bool value) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveBool(path, value)))
        return resolver.resolveBool(path, value);
    else static if (__traits(compiles, () @safe => resolver.resolveValue(path, value)))
        return resolver.resolveValue(path, value);
    else
        return false;
}

private bool resolveFieldNull(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out bool isNull) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveIsNull(path, isNull)))
        return resolver.resolveIsNull(path, isNull);
    else
        return false;
}

/// Evaluates a `DqlFilter` AST node against a path resolver.
bool evalAstNode(Resolver)(
    ref DqlEngine engine,
    scope ref const DqlFilter filter,
    uint nodeIndex,
    scope ref Resolver resolver
)
{
    if (nodeIndex >= filter.nodes.length)
        return true;

    const node = filter.nodes[nodeIndex];
    return node.payload.match!(
        (in CategoryPayload cat) => resolver.resolveCategory(engine.textOf(cat.name)),
        (in BinaryPayload bin) {
            if (node.kind == DqlNodeKind.and_)
                return evalAstNode(engine, filter, bin.left, resolver) && evalAstNode(engine, filter, bin.right, resolver);
            else
                return evalAstNode(engine, filter, bin.left, resolver) || evalAstNode(engine, filter, bin.right, resolver);
        },
        (in UnaryPayload un) => !evalAstNode(engine, filter, un.child, resolver),
        (in ComparePayload cmp) {
            const path = engine.textOf(cmp.path);
            return cmp.target.match!(
                (in TextSpan tSpan) {
                    const(char)[] actualStr;
                    if (!resolveFieldString(resolver, path, actualStr))
                        return false;
                    return compareString(actualStr, cmp.op, engine.textOf(tSpan));
                },
                (in typeof(null)) {
                    bool isNull;
                    if (resolveFieldNull(resolver, path, isNull))
                        return (cmp.op == DqlOp.eq) ? isNull : !isNull;
                    const(char)[] s;
                    if (resolveFieldString(resolver, path, s))
                        return (cmp.op == DqlOp.neq);
                    double d;
                    if (resolveFieldNumber(resolver, path, d))
                        return (cmp.op == DqlOp.neq);
                    bool b;
                    if (resolveFieldBool(resolver, path, b))
                        return (cmp.op == DqlOp.neq);
                    return (cmp.op == DqlOp.eq);
                },
                (in bool tBool) {
                    bool actualBool;
                    if (!resolveFieldBool(resolver, path, actualBool))
                        return false;
                    return (cmp.op == DqlOp.eq) ? (actualBool == tBool) : ((cmp.op == DqlOp.neq) ? (actualBool != tBool) : false);
                },
                (in long tInt) {
                    long actualInt;
                    if (resolveFieldInt(resolver, path, actualInt))
                        return compareScalar(actualInt, cmp.op, tInt);
                    double actualNum;
                    if (resolveFieldNumber(resolver, path, actualNum))
                        return compareScalar(actualNum, cmp.op, cast(double) tInt);
                    return false;
                },
                (in double tNum) {
                    double actualNum;
                    if (!resolveFieldNumber(resolver, path, actualNum))
                        return false;
                    return compareScalar(actualNum, cmp.op, tNum);
                }
            );
        },
        (in RegexPayload reg) {
            const(char)[] s;
            if (!resolveFieldString(resolver, engine.textOf(reg.path), s))
                return false;
            return evalRegex(engine, s, reg);
        },
        (in GlobPayload glb) {
            const(char)[] s;
            if (!resolveFieldString(resolver, engine.textOf(glb.path), s))
                return false;
            return evalGlob(engine, s, glb);
        },
        (in FuzzyPayload fz) {
            const(char)[] s;
            if (!resolveFieldString(resolver, engine.textOf(fz.path), s))
                return false;
            return evalFuzzy(engine, s, fz);
        },
        (in NullCheckPayload nc) {
            const path = engine.textOf(nc.path);
            bool isNull;
            if (resolveFieldNull(resolver, path, isNull))
                return nc.isNull ? isNull : !isNull;
            const(char)[] s;
            if (resolveFieldString(resolver, path, s))
                return !nc.isNull;
            double d;
            if (resolveFieldNumber(resolver, path, d))
                return !nc.isNull;
            bool b;
            if (resolveFieldBool(resolver, path, b))
                return !nc.isNull;
            return nc.isNull;
        },
        (in CustomPayload c) => true,
    );
}

/// Evaluates a `DqlFilter` against an event resolver using `engine`.
bool evalDql(Resolver)(ref DqlEngine engine, scope ref const DqlFilter filter, scope auto ref Resolver resolver)
{
    if (filter.empty)
        return filter.allowAllByDefault;
    return evalAstNode(engine, filter, filter.rootIndex, resolver);
}

@("dql.eval: typed value comparisons")
pure nothrow @nogc
unittest
{
    DqlEngine engine;
    auto s1 = engine.intern("alpha");
    auto s2 = engine.intern("beta");
    assert(compareValues(engine, DqlValue(s1), DqlOp.lt, DqlValue(s2)));
    assert(compareValues(engine, DqlValue(s1), DqlOp.eq, DqlValue(s1)));
    assert(compareValues(engine, DqlValue(s1), DqlOp.neq, DqlValue(s2)));

    assert(compareValues(engine, DqlValue(42.0), DqlOp.eq, DqlValue(42.0)));
    assert(compareValues(engine, DqlValue(100.5), DqlOp.gt, DqlValue(50.2)));
    assert(compareValues(engine, DqlValue(10L), DqlOp.lt, DqlValue(20L)));

    assert(compareValues(engine, DqlValue(true), DqlOp.eq, DqlValue(true)));
    assert(compareValues(engine, DqlValue(false), DqlOp.neq, DqlValue(true)));
}

@("dql.eval: end-to-end filter evaluation with engine")
unittest
{
    import sparkles.dql.parser : parseDql;

    DqlEngine engine;
    auto res1 = parseDql(engine, "pointer.phase == pressed && pointer.x > 100");
    assert(!res1.hasError);
    ref const f1 = res1.value;

    struct TestResolver
    {
        bool resolveCategory(scope const(char)[] cat) scope pure nothrow @nogc { return true; }
        bool resolveValue(scope const(char)[] path, out const(char)[] value) scope pure nothrow @nogc
        {
            if (path == "pointer.phase") { value = "pressed"; return true; }
            return false;
        }
        bool resolveValue(scope const(char)[] path, out double value) scope pure nothrow @nogc
        {
            if (path == "pointer.x") { value = 200.0; return true; }
            return false;
        }
    }

    TestResolver resolver;
    assert(evalDql(engine, f1, resolver));

    auto res2 = parseDql(engine, "regexMatch(title, `^[A-Z]+$`)");
    assert(!res2.hasError);
    ref const f2 = res2.value;
    struct RegexResolver
    {
        bool resolveCategory(scope const(char)[] cat) scope pure nothrow @nogc { return true; }
        bool resolveValue(scope const(char)[] path, out const(char)[] value) scope pure nothrow @nogc
        {
            value = "HELLO";
            return true;
        }
    }
    RegexResolver reResolver;
    assert(evalDql(engine, f2, reResolver));

    auto res3 = parseDql(engine, "globMatch(path, `*.png`)");
    assert(!res3.hasError);
    ref const f3 = res3.value;
    struct GlobResolver
    {
        bool resolveCategory(scope const(char)[] cat) scope pure nothrow @nogc { return true; }
        bool resolveValue(scope const(char)[] path, out const(char)[] value) scope pure nothrow @nogc
        {
            value = "image.png";
            return true;
        }
    }
    GlobResolver globResolver;
    assert(evalDql(engine, f3, globResolver));
}
