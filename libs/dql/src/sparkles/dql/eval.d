module sparkles.dql.eval;

import std.math : isNaN;
import std.regex : matchFirst;
import std.sumtype : SumType, match;
import std.traits : isBoolean, isFloatingPoint, isIntegral, isSomeString,
    isUnsigned;

import sparkles.base.text.span : TextSpan;
import sparkles.base.text.utf : decodeFirstUtf8;
import sparkles.reflection.kind : TypeKind, typeKindOf;
import sparkles.dql.ast;
import sparkles.dql.engine : DqlEngine;
import sparkles.dql.resolve : resolveDqlCategory, resolveDqlPath;
import sparkles.dql.schema : DqlResolution, enumValueMatches;
import sparkles.fuzzy.common : CandidateView;
import sparkles.fuzzy.glob : globMatch;
import sparkles.fuzzy.match : MatchKind, match;

@safe:

/// Compares two typed AST `DqlValue` literals under relational or equality operator `op`.
bool compareValues(ref const DqlEngine engine, in DqlValue actual, DqlOp op, in DqlValue target) pure nothrow @nogc
{
    return actual.match!((auto ref a) => target.match!(
        (auto ref t) => compareLiteral(engine, a, op, t)));
}

private bool compareLiteral(A, T)(ref const DqlEngine engine, in A actual,
    DqlOp op, in T target) @safe pure nothrow @nogc
{
    static if (is(A == TextSpan) && is(T == TextSpan))
        return compareString(engine.textOf(actual), op, engine.textOf(target));
    else static if (is(A == typeof(null)) && is(T == typeof(null)))
        return op == DqlOp.eq;
    else static if (is(A == bool) && is(T == bool))
        return compareScalar(actual, op, target);
    else static if (is(A == long) && is(T == long))
        return compareScalar(actual, op, target);
    else static if (is(A == long) && is(T == ulong))
        return actual < 0 ? compareOrder(NumericOrder.less, op)
            : compareScalar(cast(ulong) actual, op, target);
    else static if (is(A == ulong) && is(T == long))
        return target < 0 ? compareOrder(NumericOrder.greater, op)
            : compareScalar(actual, op, cast(ulong) target);
    else static if (is(A == ulong) && is(T == ulong))
        return compareScalar(actual, op, target);
    else static if (is(A == long) && is(T == double))
        return compareOrder(orderSignedDouble(actual, target), op);
    else static if (is(A == double) && is(T == long))
        return compareOrder(reverse(orderSignedDouble(target, actual)), op);
    else static if (is(A == ulong) && is(T == double))
        return compareOrder(orderUnsignedDouble(actual, target), op);
    else static if (is(A == double) && is(T == ulong))
        return compareOrder(reverse(orderUnsignedDouble(target, actual)), op);
    else static if (is(A == double) && is(T == double))
        return compareScalar(actual, op, target);
    else
        return false;
}

private enum NumericOrder : ubyte { less, equal, greater, unordered }

private bool compareOrder(NumericOrder order, DqlOp op) @safe pure nothrow @nogc
{
    if (order == NumericOrder.unordered)
        return op == DqlOp.neq;
    final switch (op)
    {
        case DqlOp.eq:  return order == NumericOrder.equal;
        case DqlOp.neq: return order != NumericOrder.equal;
        case DqlOp.lt:  return order == NumericOrder.less;
        case DqlOp.lte: return order != NumericOrder.greater;
        case DqlOp.gt:  return order == NumericOrder.greater;
        case DqlOp.gte: return order != NumericOrder.less;
    }
}

private NumericOrder orderOf(T)(T a, T b) @safe pure nothrow @nogc
    => a < b ? NumericOrder.less
        : a > b ? NumericOrder.greater : NumericOrder.equal;

private NumericOrder reverse(NumericOrder order) @safe pure nothrow @nogc
{
    final switch (order)
    {
        case NumericOrder.less: return NumericOrder.greater;
        case NumericOrder.equal: return NumericOrder.equal;
        case NumericOrder.greater: return NumericOrder.less;
        case NumericOrder.unordered: return NumericOrder.unordered;
    }
}

private NumericOrder orderSignedUnsigned(long a, ulong b)
    @safe pure nothrow @nogc
    => a < 0 ? NumericOrder.less : orderOf(cast(ulong) a, b);

private NumericOrder orderUnsignedSigned(ulong a, long b)
    @safe pure nothrow @nogc
    => reverse(orderSignedUnsigned(b, a));

private NumericOrder orderSignedDouble(long a, double b)
    @safe pure nothrow @nogc
{
    if (isNaN(b))
        return NumericOrder.unordered;
    enum double lower = -9_223_372_036_854_775_808.0;
    enum double upper = 9_223_372_036_854_775_808.0;
    if (b < lower)
        return NumericOrder.greater;
    if (b >= upper)
        return NumericOrder.less;
    const integral = cast(long) b;
    const compared = orderOf(a, integral);
    if (compared != NumericOrder.equal)
        return compared;
    return cast(double) integral < b ? NumericOrder.less
        : cast(double) integral > b ? NumericOrder.greater
        : NumericOrder.equal;
}

private NumericOrder orderUnsignedDouble(ulong a, double b)
    @safe pure nothrow @nogc
{
    if (isNaN(b))
        return NumericOrder.unordered;
    if (b < 0)
        return NumericOrder.greater;
    enum double upper = 18_446_744_073_709_551_616.0;
    if (b >= upper)
        return NumericOrder.less;
    const integral = cast(ulong) b;
    const compared = orderOf(a, integral);
    if (compared != NumericOrder.equal)
        return compared;
    return cast(double) integral < b ? NumericOrder.less
        : cast(double) integral > b ? NumericOrder.greater
        : NumericOrder.equal;
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
    auto matched = globMatch(engine.globPrograms[payload.globIndex], text, engine.globWorkspace());
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

    auto result = match(engine.fuzzyQueries[payload.fuzzyIndex], candidate, engine.matcherWorkspace());
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

private bool resolveFieldUInt(Resolver)(auto ref Resolver resolver, scope const(char)[] path, out ulong value) @safe
{
    static if (__traits(compiles, () @safe => resolver.resolveUInt(path, value)))
        return resolver.resolveUInt(path, value);
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

private bool evalCompareTarget(T, Resolver)(ref DqlEngine engine,
    scope const(char)[] path, DqlOp op, in T target,
    scope ref Resolver resolver)
{
    static if (is(T == TextSpan))
    {
        const(char)[] actual;
        return resolveFieldString(resolver, path, actual)
            && compareString(actual, op, engine.textOf(target));
    }
    else static if (is(T == typeof(null)))
    {
        bool isNull;
        if (resolveFieldNull(resolver, path, isNull))
            return op == DqlOp.eq ? isNull : !isNull;
        const(char)[] s;
        double d;
        bool b;
        long i;
        ulong u;
        const present = resolveFieldString(resolver, path, s)
            || resolveFieldNumber(resolver, path, d)
            || resolveFieldBool(resolver, path, b)
            || resolveFieldInt(resolver, path, i)
            || resolveFieldUInt(resolver, path, u);
        return present && op == DqlOp.neq;
    }
    else static if (is(T == bool))
    {
        bool actual;
        return resolveFieldBool(resolver, path, actual)
            && compareScalar(actual, op, target);
    }
    else static if (is(T == long))
    {
        long actualInt;
        if (resolveFieldInt(resolver, path, actualInt))
            return compareScalar(actualInt, op, target);
        ulong actualUInt;
        if (resolveFieldUInt(resolver, path, actualUInt))
            return target < 0 ? compareOrder(NumericOrder.greater, op)
                : compareScalar(actualUInt, op, cast(ulong) target);
        double actualNum;
        return resolveFieldNumber(resolver, path, actualNum)
            && compareOrder(reverse(orderSignedDouble(target, actualNum)), op);
    }
    else static if (is(T == ulong))
    {
        ulong actualUInt;
        if (resolveFieldUInt(resolver, path, actualUInt))
            return compareScalar(actualUInt, op, target);
        long actualInt;
        if (resolveFieldInt(resolver, path, actualInt))
            return actualInt < 0 ? compareOrder(NumericOrder.less, op)
                : compareScalar(cast(ulong) actualInt, op, target);
        double actualNum;
        return resolveFieldNumber(resolver, path, actualNum)
            && compareOrder(reverse(orderUnsignedDouble(target, actualNum)), op);
    }
    else static if (is(T == double))
    {
        double actualNum;
        if (resolveFieldNumber(resolver, path, actualNum))
            return compareScalar(actualNum, op, target);
        long actualInt;
        if (resolveFieldInt(resolver, path, actualInt))
            return compareOrder(orderSignedDouble(actualInt, target), op);
        ulong actualUInt;
        return resolveFieldUInt(resolver, path, actualUInt)
            && compareOrder(orderUnsignedDouble(actualUInt, target), op);
    }
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
            return cmp.target.match!((auto ref target) =>
                evalCompareTarget(engine, path, cmp.op, target, resolver));
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
            long i;
            if (resolveFieldInt(resolver, path, i))
                return !nc.isNull;
            ulong u;
            if (resolveFieldUInt(resolver, path, u))
                return !nc.isNull;
            return false;
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

/// `true` when a reflected leaf of type `V` is comparable and matchable as
/// UTF-8 text: the `text` kind (strings $(B and) `char[N]` inline storage),
/// restricted to char-element slices — `wchar`/`dchar` strings would need
/// transcoding and no vocabulary carries one, so they stay unsupported.
private enum bool isTextLeaf(V) = typeKindOf!V == TypeKind.text
    && is(typeof(V.init[]) : const(char)[]);

/// Decodes `s` as exactly one UTF-8 code point.
private bool singleCodePoint(scope const(char)[] s, out dchar cp)
    @safe pure nothrow @nogc
{
    if (!s.length)
        return false;
    cp = decodeFirstUtf8(s);
    const c0 = cast(ubyte) s[0];
    const len = c0 < 0x80 ? 1 : c0 < 0xE0 ? 2 : c0 < 0xF0 ? 3 : 4;
    return s.length == len;
}

private bool compareReflected(V)(ref DqlEngine engine, in V actual,
    DqlOp op, in DqlValue target)
{
    static if (is(V == enum))
        return target.match!(
            (in TextSpan text) => (op == DqlOp.eq || op == DqlOp.neq)
                && (enumValueMatches!V(actual, engine.textOf(text))
                    == (op == DqlOp.eq)),
            _ => false,
        );
    else static if (isTextLeaf!V)
        return target.match!(
            (in TextSpan text) => compareString(actual[], op,
                engine.textOf(text)),
            _ => false,
        );
    else static if (typeKindOf!V == TypeKind.character)
        // A char leaf answers both spellings: a one-code-point text literal
        // (`key.ch == \`a\``) and the numeric code point (`key.ch == 97`),
        // ordered as code points either way.
        return target.match!(
            (in TextSpan text) {
                dchar cp;
                return singleCodePoint(engine.textOf(text), cp)
                    && compareScalar(cast(uint) actual, op, cast(uint) cp);
            },
            (auto ref t) => compareLiteral(engine, cast(ulong) actual, op, t),
        );
    else static if (isBoolean!V)
        return compareValues(engine, DqlValue(cast(bool) actual), op, target);
    else static if (isIntegral!V && isUnsigned!V)
        return compareValues(engine, DqlValue(cast(ulong) actual), op, target);
    else static if (isIntegral!V)
        return compareValues(engine, DqlValue(cast(long) actual), op, target);
    else static if (isFloatingPoint!V)
        return compareValues(engine, DqlValue(cast(double) actual), op, target);
    else
        return false;
}

private struct CompareSink
{
    DqlEngine* engine;
    DqlOp op;
    DqlValue target;
    bool* result;

    void opCall(V)(in V value)
    {
        *result = compareReflected!V(*engine, value, op, target);
    }
}

private struct IgnoreSink
{
    void opCall(V)(in V) @safe pure nothrow @nogc {}
}

private struct RegexSink
{
    DqlEngine* engine;
    RegexPayload pattern;
    bool* result;

    void opCall(V)(in V value)
    {
        static if (isTextLeaf!V)
            *result = evalRegex(*engine, value[], pattern);
    }
}

private struct GlobSink
{
    DqlEngine* engine;
    GlobPayload pattern;
    bool* result;

    void opCall(V)(in V value)
    {
        static if (isTextLeaf!V)
            *result = evalGlob(*engine, value[], pattern);
    }
}

private struct FuzzySink
{
    DqlEngine* engine;
    FuzzyPayload pattern;
    bool* result;

    void opCall(V)(in V value)
    {
        static if (isTextLeaf!V)
            *result = evalFuzzy(*engine, value[], pattern);
    }
}

private bool evalReflectedNode(Schema)(ref DqlEngine engine,
    scope ref const DqlFilter filter, uint nodeIndex,
    scope ref const Schema.Subject subject)
{
    if (nodeIndex >= filter.nodes.length)
        return true;
    const node = filter.nodes[nodeIndex];
    return node.payload.match!(
        (in CategoryPayload category) => resolveDqlCategory!Schema(subject,
            engine.textOf(category.name)),
        (in BinaryPayload binary) => node.kind == DqlNodeKind.and_
            ? evalReflectedNode!Schema(engine, filter, binary.left, subject)
                && evalReflectedNode!Schema(engine, filter, binary.right, subject)
            : evalReflectedNode!Schema(engine, filter, binary.left, subject)
                || evalReflectedNode!Schema(engine, filter, binary.right, subject),
        (in UnaryPayload unary) => !evalReflectedNode!Schema(engine, filter,
            unary.child, subject),
        (in ComparePayload comparison) {
            bool result;
            CompareSink sink = {
                engine: &engine,
                op: comparison.op,
                target: comparison.target,
                result: &result,
            };
            const resolved = resolveDqlPath!Schema(subject,
                engine.textOf(comparison.path), sink);
            return resolved == DqlResolution.value && result;
        },
        (in NullCheckPayload check) {
            const resolved = resolveDqlPath!Schema(subject,
                engine.textOf(check.path), IgnoreSink.init);
            return check.isNull ? resolved == DqlResolution.absent
                : resolved == DqlResolution.value;
        },
        (in RegexPayload pattern) {
            bool result;
            RegexSink sink = { engine: &engine, pattern: pattern,
                result: &result };
            return resolveDqlPath!Schema(subject,
                engine.textOf(pattern.path), sink) == DqlResolution.value
                && result;
        },
        (in GlobPayload pattern) {
            bool result;
            GlobSink sink = { engine: &engine, pattern: pattern,
                result: &result };
            return resolveDqlPath!Schema(subject,
                engine.textOf(pattern.path), sink) == DqlResolution.value
                && result;
        },
        (in FuzzyPayload pattern) {
            bool result;
            FuzzySink sink = { engine: &engine, pattern: pattern,
                result: &result };
            return resolveDqlPath!Schema(subject,
                engine.textOf(pattern.path), sink) == DqlResolution.value
                && result;
        },
        (in CustomPayload) => true,
    );
}

/// Evaluates a filter directly against its reflected schema subject.
bool evalDql(Schema)(ref DqlEngine engine, scope ref const DqlFilter filter,
    scope ref const Schema.Subject subject)
{
    if (filter.empty)
        return filter.allowAllByDefault;
    return evalReflectedNode!Schema(engine, filter, filter.rootIndex, subject);
}

@("dql.eval: reflected schemas distinguish absent variants")
@safe
unittest
{
    import sparkles.dql.parser : parseDql;
    import sparkles.dql.schema : DqlSchema;

    struct AEvent { int value; }
    struct BEvent { bool enabled; }
    alias Event = SumType!(AEvent, BEvent);
    alias Schema = DqlSchema!Event;
    DqlEngine engine;
    Event event = AEvent(9);

    auto value = parseDql!Schema(engine, "a.value == 9");
    assert(value.hasValue && evalDql!Schema(engine, value.value, event));
    auto absent = parseDql!Schema(engine, "b.enabled == null");
    assert(absent.hasValue && evalDql!Schema(engine, absent.value, event));
}

@("dql.eval: character and char-array leaves compare as text")
@safe
unittest
{
    import sparkles.dql.parser : parseDql;
    import sparkles.dql.schema : DqlSchema;

    struct KeyedEvent
    {
        dchar ch;
        char[4] tag;
    }

    struct OtherEvent
    {
        int n;
    }

    alias Event = SumType!(KeyedEvent, OtherEvent);
    alias Schema = DqlSchema!Event;

    DqlEngine engine;
    Event event = KeyedEvent('a', "abcd");

    foreach (query, expected; [
        "keyed.ch == `a`": true,
        "keyed.ch != `a`": false,   // the negation really is the complement
        "keyed.ch == 97": true,     // the numeric code-point spelling
        "keyed.ch >= `a`": true,
        "keyed.ch < `b`": true,
        "keyed.ch == `ab`": false,  // not a single code point
        "keyed.tag == `abcd`": true,
        "keyed.tag != `abcd`": false,
        "regexMatch(keyed.tag, `^ab`)": true,
        "globMatch(keyed.tag, `ab*`)": true,
    ])
    {
        auto parsed = parseDql!Schema(engine, query);
        assert(parsed.hasValue, parsed.error.message);
        assert(evalDql!Schema(engine, parsed.value, event) == expected, query);
    }

    // A non-ASCII code point works through both spellings.
    Event accented = KeyedEvent('\u00e9', "\u00e9\u00e9");
    foreach (query; ["keyed.ch == `\u00e9`", "keyed.ch == 233"])
    {
        auto parsed = parseDql!Schema(engine, query);
        assert(parsed.hasValue, parsed.error.message);
        assert(evalDql!Schema(engine, parsed.value, accented), query);
    }
}

@("dql.eval: typed value comparisons")
@safe pure nothrow @nogc
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
    assert(compareValues(engine, DqlValue(-1L), DqlOp.lt, DqlValue(0UL)));
    assert(compareValues(engine, DqlValue(ulong.max), DqlOp.gt,
        DqlValue(long.max)));
    assert(!compareValues(engine, DqlValue(9_007_199_254_740_993L),
        DqlOp.eq, DqlValue(9_007_199_254_740_992.0)));

    assert(compareValues(engine, DqlValue(true), DqlOp.eq, DqlValue(true)));
    assert(compareValues(engine, DqlValue(false), DqlOp.neq, DqlValue(true)));
}

@("dql.eval: unknown and present integer paths are not null")
@safe
unittest
{
    import sparkles.dql.parser : parseDql;

    struct Resolver
    {
        bool resolveCategory(scope const(char)[]) @safe pure nothrow @nogc
            => false;

        bool resolveInt(scope const(char)[] path, out long value)
            @safe pure nothrow @nogc
        {
            if (path != "n")
                return false;
            value = 12;
            return true;
        }
    }

    DqlEngine engine;
    Resolver resolver;
    foreach (query, expected; [
        "n == null": false,
        "n != null": true,
        "missing == null": false,
        "missing != null": false,
    ])
    {
        auto parsed = parseDql(engine, query);
        assert(parsed.hasValue);
        assert(evalDql(engine, parsed.value, resolver) == expected);
    }
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
