/**
Typed SDL decode over the shared wired schema (SPEC §6).

$(LREF fromSDL) fills a D aggregate from a parsed $(LREF SdlNode) by walking
the reified `wireSchemaOf!(Sdl, T)` arena through the S5 role projection
(`sdlAggregateRoles`): channels match by declared role, positional values by
slot index, attributes and children by full `(namespace, localName)` identity,
and repetitions compose in source order (`authors "a" "b"` plus a later
`authors "c"` merge into one sequence).

Shared-policy precedence mirrors the JSON backend: `@WireConvert` wraps leaf
payloads, `@WireOptional` governs absence (including `onInvalid: useDefault`
fallbacks), enums resolve through the shared name/case/repr policy, null-aware
wrappers absorb SDL `null` and absent channels, and `SumType`s trial-decode
their variants under the shared $(LREF MatchStrategy).

Every failure carries `stage = decode`, a stable code, the offending token/tag
span (or the containing tag's terminating span when a required member is
missing), and composed SDL role paths exactly as SPEC §7 defines them.
*/
module sparkles.wired.sdl.codec;

import std.conv : to;
import std.traits : ForeachType, KeyType, OriginalType, TemplateArgsOf, Unqual, ValueType, isAssociativeArray, isDynamicArray, isFloatingPoint, isIntegral, isSomeChar, isStaticArray, isUnsigned;
import std.sumtype : isSumType;

import optional : Optional, some;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.wired.policy : Repr, WireInvalid, WireTarget, convertOf,
    hasConvert, resolveCaseStyle, resolveRepr, resolvedFieldPolicies, wireNames;
import sparkles.wired.schema : NodeKind, ScalarKind;
import sparkles.wired.sdl.config : SdlParserConfig, sdlFull;
import sparkles.wired.sdl.document : SdlNode, SdlQualifiedName, SdlScalar,
    SdlScalarKind;
import sparkles.wired.policy : MatchStrategy;
import sparkles.wired.sdl.document : SdlAttributeView, SdlSpan;
import sparkles.wired.sdl.error : SdlError, SdlErrorCode, SdlErrorStage,
    SdlExpected, sdlErr, sdlOk;
import sparkles.wired.sdl.schema_annotations : SdlFieldRole;
import sparkles.wired.sdl.reader : parseSdlDocument;
import sparkles.wired.sdl.schema_annotations : Sdl, SdlAttribute, SdlChild,
    SdlChildShape, SdlExtra, SdlRoleKind, SdlTagNamespace, SdlTagName,
    SdlTagValue, sdlAggregateRoles;

version (unittest)
{
    import std.sumtype : SumType;
    import std.sumtype : match;
}
version (unittest) import std.typecons : Nullable, Ternary;

/** The parser profile used by the text convenience overload.

SPEC pins no per-type parser configuration, so the default is the complete
deterministic $(LREF sdlFull) dialect; consumers needing a narrower profile
(e.g. `sdlDubRecipe` over known recipes) pass an explicit `config`.
*/
template sdlParserConfigFor(T)
{
    enum SdlParserConfig sdlParserConfigFor = sdlFull;
}

// ── Walk plumbing ────────────────────────────────────────────────────────────

/// Internal walk result: flat struct, no per-node `Expected` instantiations.
private struct DRes(T)
{
    bool failed;
    static if (!is(T == void))
        T value;
}

private DRes!T dOk(T)(T value)
{
    DRes!T r;
    r.value = value;
    return r;
}

private DRes!T dFail(T)(ref SdlError failure, SdlError e)
{
    failure = e;
    return DRes!T(true);
}

/// Composed SDL role path shared across one decode walk (SPEC §7).
private struct WalkPath
{
    SmallBuffer!(char, 96) text;
}

private void popSegment(ref WalkPath p, size_t mark) @safe
{
    () @trusted { p.text.length = mark; }();
}

/// Attaches the composed role path to a freshly built error.
private SdlError attachPath(ref WalkPath path, SdlError e) @safe
{
    () @trusted { e.rolePath ~= path.text[]; }();
    return e;
}

private SdlError baseError(SdlErrorCode code, SdlSpan span,
    scope const(char)[] reason) @safe
{
    SdlError e;
    e.stage = SdlErrorStage.decode;
    e.code = code;
    e.span = span;
    e.reason ~= reason.idup;
    return e;
}

private SdlError typedError(T)(SdlErrorCode code, SdlSpan span,
    scope const(char)[] reason) @safe
{
    auto e = baseError(code, span, reason);
    e.targetType = T.stringof;
    return e;
}

/// Zero-width span at a tag's terminator — the SPEC §6 missing-member site.
private SdlSpan endSpan(scope const ref SdlNode node) @safe
{
    const end = node.span.end;
    return SdlSpan(end, end);
}

private bool isNullScalar(scope const ref SdlScalar s) @safe
{
    return s.kind == SdlScalarKind.null_;
}

private template isNullAwareType(T)
{
    static if (__traits(compiles, { T x = T.init; }))
    {
        static if (is(T == Nullable!N, N) || is(T == Optional!O, O))
            enum isNullAwareType = true;
        else static if (is(T == Ternary))
            enum isNullAwareType = true;
        else
            enum isNullAwareType = false;
    }
    else
        enum isNullAwareType = false;
}

private template Contained(T)
{
    static if (is(T == Nullable!N, N))
        alias Contained = N;
    else static if (is(T == Optional!O, O))
        alias Contained = O;
    else
        alias Contained = void;
}

// ── Scalar kernels ───────────────────────────────────────────────────────────

/** Decodes one SDL scalar into target type `T` with exact-kind mapping.

Integers coerce across widths/signedness under range checks
(`numberOutOfRange`); floating targets accept only floating scalar kinds and
narrowing overflow becomes `valueOutOfRange`; strings copy decoded bytes;
enums resolve through the shared name/case or repr-value policy.
*/
private DRes!T decodeScalar(T, CaseStyle enumStyle = CaseStyle.original,
    Repr enumRepr = Repr.name)(scope const ref SdlScalar s,
    ref SdlError failure)
{
    static if (!is(T == Unqual!T))
    {
        auto mutable_ = decodeScalar!(Unqual!T, enumStyle, enumRepr)(s,
            failure);
        if (mutable_.failed)
            return DRes!T(true);
        return DRes!T(false, cast(T) mutable_.value);
    }
    else
    {
        alias U = T;
        static if (is(U == bool))
    {
        if (s.kind != SdlScalarKind.boolean)
            return dFail!T(failure, typedError!U(SdlErrorCode.unexpectedKind,
                s.span, "expected an SDL boolean"));
        return DRes!U(false, s.boolean);
    }
    else static if (is(U == string))
    {
        if (s.kind != SdlScalarKind.string_)
            return dFail!T(failure, typedError!U(SdlErrorCode.unexpectedKind,
                s.span, "expected an SDL string"));
        return DRes!U(false, s.stringValue.idup);
    }
    else static if (isSomeChar!U)
    {
        if (s.kind != SdlScalarKind.character)
            return dFail!T(failure, typedError!U(SdlErrorCode.unexpectedKind,
                s.span, "expected an SDL character"));
        const c = s.character;
        static if (U.sizeof >= 4)
            return DRes!U(false, cast(U) c);
        else static if (U.sizeof == 2)
        {
            if (c > 0xFFFF)
                return dFail!T(failure, typedError!U(
                    SdlErrorCode.numberOutOfRange, s.span,
                    "character is outside the UTF-16 range"));
            return DRes!U(false, cast(U) c);
        }
        else
        {
            if (c > 0x7F)
                return dFail!T(failure, typedError!U(
                    SdlErrorCode.numberOutOfRange, s.span,
                    "character is outside the ASCII range"));
            return DRes!U(false, cast(U) c);
        }
    }
    else static if (isIntegral!U && !is(U == enum))
    {
        switch (s.kind) with (SdlScalarKind)
        {
        case integer:
            static if (isUnsigned!U)
            {
                if (s.integer < 0)
                    return dFail!T(failure, typedError!U(
                        SdlErrorCode.numberOutOfRange, s.span,
                        "negative integer for unsigned target"));
                return DRes!U(false, cast(U) s.integer);
            }
            else
            {
                if (s.integer < U.min || s.integer > U.max)
                    return dFail!T(failure, typedError!U(
                        SdlErrorCode.numberOutOfRange, s.span,
                        "integer is outside the target range"));
                return DRes!U(false, cast(U) s.integer);
            }
        case longInteger:
            static if (isUnsigned!U)
            {
                if (s.longInteger < 0 || cast(ulong) s.longInteger > U.max)
                    return dFail!T(failure, typedError!U(
                        SdlErrorCode.numberOutOfRange, s.span,
                        "integer is outside the unsigned target range"));
                return DRes!U(false, cast(U) s.longInteger);
            }
            else
            {
                if (s.longInteger < U.min || s.longInteger > U.max)
                    return dFail!T(failure, typedError!U(
                        SdlErrorCode.numberOutOfRange, s.span,
                        "integer is outside the target range"));
                return DRes!U(false, cast(U) s.longInteger);
            }
        default:
            return dFail!T(failure, typedError!U(SdlErrorCode.unexpectedKind,
                s.span, "expected an SDL integer"));
        }
    }
    else static if (isFloatingPoint!U && !is(U == enum))
    {
        import std.math : isFinite;

        real raw;
        switch (s.kind) with (SdlScalarKind)
        {
        case float_: raw = s.floatValue; break;
        case double_: raw = s.doubleValue; break;
        case decimal: raw = s.decimalValue; break;
        default:
            return dFail!T(failure, typedError!U(SdlErrorCode.unexpectedKind,
                s.span, "expected an SDL floating-point scalar"));
        }
        const narrowed = cast(U) raw;
        if (!isFinite(narrowed) && isFinite(raw))
            return dFail!T(failure, typedError!U(SdlErrorCode.valueOutOfRange,
                s.span, "floating-point value is outside the target range"));
        return DRes!U(false, narrowed);
    }
    else static if (is(U == enum))
    {
        static if (enumRepr == Repr.name)
        {
            if (s.kind != SdlScalarKind.string_)
                return dFail!T(failure, typedError!U(
                    SdlErrorCode.unexpectedKind, s.span,
                    "expected an SDL string naming an enum member"));
            enum memberNames = wireNames!(Sdl, U, enumStyle);
            size_t index = size_t.max;
            foreach (i, name; memberNames)
                if (s.stringValue == name)
                {
                    index = i;
                    break;
                }
            if (index == size_t.max)
                return dFail!T(failure, typedError!U(
                    SdlErrorCode.unknownMember, s.span,
                    "no enum member is named \"" ~ s.stringValue.idup ~ "\""));
            U found = U.init;
            bool hit;
            static foreach (memberIndex, m; __traits(allMembers, U))
                if (!hit && memberIndex == index)
                {
                    found = __traits(getMember, U, m);
                    hit = true;
                }
            assert(hit);
            return DRes!U(false, found);
        }
        else
        {
            long wanted;
            switch (s.kind) with (SdlScalarKind)
            {
            case integer: wanted = s.integer; break;
            case longInteger: wanted = s.longInteger; break;
            default:
                return dFail!T(failure, typedError!U(
                    SdlErrorCode.unexpectedKind, s.span,
                    "expected an SDL integer for a value-repr enum"));
            }
            static foreach (m; __traits(allMembers, U))
                if (wanted == cast(long) __traits(getMember, U, m))
                    return DRes!U(false, __traits(getMember, U, m));
            return dFail!T(failure, typedError!U(SdlErrorCode.unknownMember,
                s.span, "no enum member carries that value"));
        }
    }
    else
        static assert(false, "wired.sdl: unsupported scalar target "
            ~ U.stringof);
    }
}

/// Effective enum case/repr for a field under SDL: field all-slot override
/// first, then the enum type's own resolution (JSON's non-slotted order).

// ── Converters and unions ────────────────────────────────────────────────────

/** Decodes a leaf payload through an optional shared `@WireConvert`.

The converter's wire type is decoded from SDL first, then `from` produces the
D value; converter failures surface as `conversionFailed` at the offending
span with their reason retained.
*/
private DRes!Field decodeLeaf(Field, alias Conv = void,
    CaseStyle enumStyle = CaseStyle.original,
    Repr enumRepr = Repr.name)(scope const ref SdlScalar s,
    ref WalkPath path, ref SdlError failure)
{
    pragma(msg, "LEAF=", Field, " conv=", Conv);
    static if (!is(Conv == void))
    {
        alias Raw = typeof(Conv.to(Field.init));
        static if (__traits(compiles, Raw.init.value))
            alias Wire = typeof(Raw.init.value);
        else
            alias Wire = Raw;

        auto raw = decodeScalar!(Wire, enumStyle, enumRepr)(s, failure);
        if (raw.failed)
            return DRes!(Field)(true);

        try
        {
            return dOk(cast(Field) Conv.from(raw.value));
        }
        catch (Exception e)
        {
            return dFail!(Field)(failure, attachPath(path,
                baseError(SdlErrorCode.conversionFailed, s.span,
                    "converter rejected the value: " ~ e.msg)));
        }
    }
    else
    {
        auto r = decodeScalar!(Field, enumStyle, enumRepr)(s, failure);
        if (r.failed)
            () @trusted { failure.rolePath ~= path.text[]; }();
        return r;
    }
}

/// Trial-decodes SumType variants against one scalar under `strat`.
/// `@trusted` because SumType's storage declares an `@system opAssign`, which
/// otherwise taints every by-value move of the result; this kernel only ever
/// moves freshly decoded variant values into a default-initialized SumType.
@trusted
private DRes!ST decodeSumTypeScalar(ST, MatchStrategy strat)(
    scope const ref SdlScalar s, ref WalkPath path, ref SdlError failure)
if (isSumType!ST)
{
    alias Variants = TemplateArgsOf!ST;
    size_t successes;
    ST chosen;
    bool haveChosen;
    bool haveReason;
    SdlError lastReason;

    static foreach (V; Variants)
    {{
        SdlError variantFailure;
        auto attempt = decodeScalar!(V)(s, variantFailure);
        if (!attempt.failed)
        {
            successes++;
            if (!haveChosen)
            {
                () @trusted { chosen = ST(attempt.value); }();
                haveChosen = true;
            }
        }
        else if (!haveReason)
        {
            haveReason = true;
            lastReason = attachPath(path, variantFailure);
        }
    }}

    static if (strat == MatchStrategy.first)
    {
        if (successes == 0)
            return dFail!ST(failure, attachPath(path, baseError(
                SdlErrorCode.conversionFailed, s.span,
                "no SumType variant decodes this value")));
        return dOk(chosen);
    }
    else
    {
        if (successes == 0)
            return dFail!ST(failure, attachPath(path, baseError(
                SdlErrorCode.conversionFailed, s.span,
                "no SumType variant decodes this value")));
        if (successes > 1)
            return dFail!ST(failure, attachPath(path, baseError(
                SdlErrorCode.duplicateRole, s.span,
                "multiple SumType variants decode this value")));
        return dOk(chosen);
    }
}

/** One singular scalar-bearing channel slot: absence, SDL null, unions,
converters, and optionality in shared-policy order. */
private bool decodeSingular(alias Parent, size_t i, V, alias Conv = void)(
    bool present, scope const ref SdlScalar s, SdlSpan absentSpan,
    scope const(char)[] missingReason, ref WalkPath path,
    ref SdlError failure, ref V out_)
{
    alias policies = resolvedFieldPolicies!(Sdl, Parent);

    // Absence: optional/null-aware targets take their empty value; a
    // required field is a missingRole at the containing tag's terminator.
    if (!present)
    {
        static if (isNullAwareType!(V))
            assignField(out_, V.init);
        else static if (policies[i].optional)
            assignField(out_, V.init);
        else
        {
            failure = attachPath(path, baseError(
                SdlErrorCode.missingRole, absentSpan, missingReason));
            return true;
        }
        return false;
    }

    // SDL null maps only to null-aware targets (SPEC §6).
    if (isNullScalar(s))
    {
        static if (isNullAwareType!(V))
            assignField(out_, V.init);
        else
        {
            failure = attachPath(path, typedError!(V)(
                SdlErrorCode.unexpectedKind, s.span,
                "SDL null maps only to null-aware targets"));
            return true;
        }
        return false;
    }

    static if (isNullAwareType!(V))
    {
        alias C = Contained!(V);

        static if (__traits(isSame, Unqual!V, Ternary))
        {
            if (s.kind != SdlScalarKind.boolean)
            {
                failure = attachPath(path, baseError(
                    SdlErrorCode.unexpectedKind, s.span,
                    "expected an SDL boolean for a ternary"));
                return true;
            }
            () @trusted { out_ = s.boolean ? Ternary.yes : Ternary.no; }();
            return false;
        }
        else
        {
            auto r = decodeLeaf!(C, Conv)(s, path, failure);
            if (r.failed)
            {
                static if (policies[i].optional
                    && policies[i].onInvalid == WireInvalid.useDefault)
                {
                    failure = SdlError.init;
                    () @trusted { out_ = V(r.value); }();
                    return false;
                }
                return true;
            }
            static if (is(V == Nullable!N, N))
                assignField(out_, V(r.value));
            else static if (is(V == Optional!O, O))
                () @trusted { out_ = some(r.value); }();
            else
                assert(false, "wired.sdl: unreachable null-aware family");
            return false;
        }
    }
    else static if (isSumType!(V))
    {
        auto r = decodeSumTypeScalar!(V, policies[i].match)(s, path, failure);
        if (r.failed)
        {
            static if (policies[i].optional
                && policies[i].onInvalid == WireInvalid.useDefault)
            {
                failure = SdlError.init;
                assignField(out_, V.init);
                return false;
            }
            return true;
        }
        assignField(out_, r.value);
        return false;
    }
    else static if (is(V == enum))
    {
        enum enumStyle = policies[i].caseFor(WireTarget.value,
            resolveCaseStyle!(Sdl, V));
        enum enumRepr = policies[i].reprFor(WireTarget.value,
            resolveRepr!(Sdl, V));
        auto r = decodeLeaf!(V, void, enumStyle, enumRepr)(s, path, failure);
        if (r.failed)
        {
            static if (policies[i].optional
                && policies[i].onInvalid == WireInvalid.useDefault)
            {
                failure = SdlError.init;
                assignField(out_, V.init);
                return false;
            }
            return true;
        }
        assignField(out_, r.value);
        return false;
    }
    else
    {
        auto r = decodeLeaf!(V, Conv)(s, path, failure);
        if (r.failed)
        {
            static if (policies[i].optional
                && policies[i].onInvalid == WireInvalid.useDefault)
            {
                failure = SdlError.init;
                assignField(out_, V.init);
                return false;
            }
            return true;
        }
        assignField(out_, r.value);
        return false;
    }

    assert(false, "wired.sdl: unreachable singular decode branch");
}

// ── Channel collection ───────────────────────────────────────────────────────

/// Matching direct children in source order, by full qualified identity.
private size_t collectChildren(scope const ref SdlNode node,
    scope const(char)[] ns, scope const(char)[] local,
    ref SmallBuffer!(SdlNode, 4) matches) @safe
{
    matches.clear();
    foreach (child; node.byChild)
    {
        const name = child.qualifiedName;
        if (name.namespace_ == ns && name.localName == local)
            () @trusted { matches ~= child; }();
    }
    return matches.length;
}

/// Narrow trust: copies one borrowed scalar (its payload slices stay owned
/// by the document pool; callers treat the copy as equally short-lived).
private SdlScalar copyBorrowedScalar(scope const ref SdlScalar s) @trusted
{
    const ps = &s;
    return *ps;
}

private SdlScalar firstValueOf(scope const ref SdlNode n) @safe
{
    foreach (v; n.byValue)
        return copyBorrowedScalar(v);
    assert(false, "scalar channel requires positional value 0");
}


private void assignField(T)(ref T slot, T value) @trusted
{
    static if (__traits(compiles, { import core.lifetime : move; slot = move(value); }))
    {
        import core.lifetime : move;

        slot = move(value);
    }
    else
        slot = value;
}

// ── Aggregate walk ───────────────────────────────────────────────────────────

private size_t collectAttributes(scope const ref SdlNode node,
    scope const(char)[] ns, scope const(char)[] local,
    ref SmallBuffer!(SdlAttributeView, 4) matches) @safe
{
    matches.clear();
    foreach (attribute; node.byAttribute)
    {
        const name = attribute.qualifiedName;
        if (name.namespace_ == ns && name.localName == local)
            () @trusted { matches ~= attribute; }();
    }
    return matches.length;
}

private SdlScalar valueAt(scope const ref SdlNode node, size_t index,
    ref bool found) @safe
{
    size_t seen;
    found = false;
    foreach (value; node.byValue)
    {
        if (seen++ == index)
        {
            found = true;
            return copyBorrowedScalar(value);
        }
    }
    return SdlScalar.init;
}

/// Collection-element decode: converters/enums/unions without the singular
/// absence machinery (`useDefault` fallbacks apply only to singular fields).
private DRes!V decodeElement(alias Parent, size_t i, V, alias Conv = void)(
    SdlScalar s, ref WalkPath path, ref SdlError failure)
{
    alias policies = resolvedFieldPolicies!(Sdl, Parent);
    static if (isSumType!(V))
        return decodeSumTypeScalar!(V, policies[i].match)(s, path, failure);
    else static if (is(V == enum))
    {
        enum enumStyle = policies[i].caseFor(WireTarget.value,
            resolveCaseStyle!(Sdl, V));
        enum enumRepr = policies[i].reprFor(WireTarget.value,
            resolveRepr!(Sdl, V));
        return decodeLeaf!(V, void, enumStyle, enumRepr)(s, path, failure);
    }
    else
        return decodeLeaf!V(s, path, failure);
}

/** Decodes aggregate `T` from one SDL node, filling every declared role. */
private DRes!T decodeAggregate(T)(scope const ref SdlNode node,
    ref WalkPath path, ref SdlError failure) @safe
if (is(T == struct))
{
    import std.traits : isNested;

    alias U = Unqual!T;
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    alias policies = resolvedFieldPolicies!(Sdl, U);
    U result;

    static assert(roles.roles.length == U.tupleof.length);
    static foreach (i, symbol; U.tupleof)
    {{
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        enum ident = __traits(identifier, symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FieldConv = convertOf!(Sdl, symbol, V);
        else
            alias FieldConv = void;

        static if (R.role == SdlRoleKind.child)
        {
            SmallBuffer!(SdlNode, 4) matches;
            const count = collectChildren(node, R.namespace_, R.localName,
                matches);

            static if (R.childShape == SdlChildShape.scalarSingle
                || R.childShape == SdlChildShape.aggregateSingle)
            {
                if (count > 1)
                {
                    const mark = path.text.length;
                    pushDup(path, R.localName);
                    failure = attachPath(path, baseError(
                        SdlErrorCode.duplicateRole, matches[1].span(),
                        "duplicate singular child \"" ~ R.localName ~ "\""));
                    popSegment(path, mark);
                    return DRes!(U)(true);
                }

                // Null-aware aggregates absorb absence; scalars go through
                // the shared singular pipeline (absence/null/unions).
                static if (R.childShape == SdlChildShape.scalarSingle)
                {
                    const mark = path.text.length;
                    path.text ~= "." ~ R.localName ~ "[0]";
                    scope (exit) popSegment(path, mark);

                    V slot = V.init;
                    if (count == 0)
                    {
                        SdlScalar none_ = SdlScalar(null);
                        if (decodeSingular!(U, i, V, FieldConv)(false, none_,
                                endSpan(node), "missing child \""
                                ~ R.localName ~ "\"", path, failure, slot))
                            return DRes!(U)(true);
                    }
                    else
                    {
                        const s0 = firstValueOf(matches[0]);
                        if (decodeSingular!(U, i, V, FieldConv)(true, s0, endSpan(node),
                                null, path, failure, slot))
                            return DRes!(U)(true);
                    }
                    assignField(result.tupleof[i], slot);
                }
                else static if (isNullAwareType!(V))
                {
                    if (count == 0)
                        assignField(result.tupleof[i], V.init);
                    else
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ R.localName ~ "[0]";
                        auto r = decodeAggregate!(Contained!(V))(matches[0],
                            path, failure);
                        popSegment(path, mark);
                        if (r.failed)
                            return DRes!(U)(true);
                        static if (is(V == Nullable!N, N))
                            assignField(result.tupleof[i], V(r.value));
                        else static if (is(V == Optional!O, O))
                            assignField(result.tupleof[i], some(r.value));
                        else
                            assignField(result.tupleof[i], Ternary.yes);
                    }
                }
                else
                {
                    if (count == 0)
                    {
                        static if (!policies[i].optional)
                        {
                            const mark = path.text.length;
                            path.text ~= "." ~ R.localName ~ "[0]";
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(node),
                                "missing child \"" ~ R.localName ~ "\""));
                            popSegment(path, mark);
                            return DRes!(U)(true);
                        }
                        else
                            assignField(result.tupleof[i], V.init);
                    }
                    else
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ R.localName ~ "[0]";
                        auto r = decodeAggregate!(V)(matches[0], path, failure);
                        popSegment(path, mark);
                        if (r.failed)
                            return DRes!(U)(true);
                        assignField(result.tupleof[i], r.value);
                    }
                }
            }
            else static if (R.childShape == SdlChildShape.scalarSequence)
            {
                alias E = ForeachType!V;
                E[] items;
                foreach (occurrence; 0 .. count)
                {
                    const m = matches[occurrence];
                    const mark = path.text.length;
                    path.text ~= "." ~ R.localName ~ "["
                        ~ occurrence.to!string ~ "]";
                    scope (exit) popSegment(path, mark);
                    foreach (value; m.byValue)
                    {
                        auto r = decodeElement!(U, i, E, FieldConv)(value,
                            path, failure);
                        if (r.failed)
                            return DRes!(U)(true);
                        items ~= r.value;
                    }
                }
                static if (R.staticCount != 0)
                {
                    if (items.length != R.staticCount)
                    {
                        failure = attachPath(path, baseError(
                            SdlErrorCode.missingRole, endSpan(node),
                            "static-array child requires exactly "
                            ~ R.staticCount.to!string ~ " total values"));
                        return DRes!(U)(true);
                    }
                }
                assignField(result.tupleof[i], items);
            }
            else static if (R.childShape == SdlChildShape.aggregateSequence)
            {
                alias E = ForeachType!V;
                E[] items;
                foreach (occurrence; 0 .. count)
                {
                    const mark = path.text.length;
                    path.text ~= "." ~ R.localName ~ "["
                        ~ occurrence.to!string ~ "]";
                    auto r = decodeAggregate!(E)(matches[occurrence], path,
                        failure);
                    popSegment(path, mark);
                    if (r.failed)
                        return DRes!(U)(true);
                    items ~= r.value;
                }
                assignField(result.tupleof[i], items);
            }
            else static if (R.childShape == SdlChildShape.map)
            {
                alias K = KeyType!V;
                alias M = ValueType!V;
                static if (!(is(K == string) || is(K == enum)))
                    static assert(false, "wired.sdl: unreachable AA key kind");

                // Compile-time set of local names claimed by *other* child
                // fields; the AA consumes every remaining same-namespace
                // sibling so its tags may be arbitrarily named.
                static immutable string[] claimedNames = () {
                    string[] r;
                    static foreach (j; 0 .. roles.roles.length)
                        static if (roles.roles[j].role == SdlRoleKind.child
                            && j != i)
                            r ~= roles.roles[j].localName;
                    return r;
                }();

                SmallBuffer!(SdlNode, 4) aaMatches;
                foreach (child; node.byChild)
                {
                    if (child.qualifiedName.namespace_ != R.namespace_)
                        continue;
                    bool taken;
                    foreach (cn; claimedNames)
                        if (cn == child.qualifiedName.localName)
                        {
                            taken = true;
                            break;
                        }
                    if (!taken)
                        () @trusted { aaMatches ~= child; }();
                }

                K[] seenKeys;
                M[string] table;
                foreach (occurrence; 0 .. aaMatches.length)
                {
                    const m = aaMatches[occurrence];
                    const rawKey = m.qualifiedName.localName;
                    K key = keyFromString!(K)(rawKey, m.nameSpan(), path,
                        failure);
                    if (failure.reason.length && failure.stage
                        == SdlErrorStage.decode)
                        return DRes!(U)(true);
                    if (keyIn(seenKeys, key))
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ R.localName ~ "[" ~ rawKey ~ "]";
                        failure = attachPath(path, baseError(
                            SdlErrorCode.duplicateRole, m.nameSpan(),
                            "duplicate map key \"" ~ rawKey.idup ~ "\""));
                        popSegment(path, mark);
                        return DRes!(U)(true);
                    }
                    seenKeys ~= key;
                    const mark = path.text.length;
                    path.text ~= "." ~ R.localName ~ "[" ~ rawKey ~ "]";
                    scope (exit) popSegment(path, mark);
                    static if (is(M == struct) && !isSomeChar!M
                        && !is(M == enum))
                    {
                        auto r = decodeAggregate!(M)(m, path, failure);
                        if (r.failed)
                            return DRes!(U)(true);
                        table[key] = r.value;
                    }
                    else
                    {
                        auto r = decodeElement!(U, i, M)(firstValueOf(m),
                            path, failure);
                        if (r.failed)
                            return DRes!(U)(true);
                        table[key] = r.value;
                    }
                }
                assignField(result.tupleof[i], table);
            }
            else
                static assert(false, "wired.sdl: unreachable child shape");
        }
        else static if (R.role == SdlRoleKind.attribute)
        {
            SmallBuffer!(SdlAttributeView, 4) attrs;
            const acount = collectAttributes(node, R.namespace_, R.localName,
                attrs);

            // NOTE: string is a dynamic array in D but a *scalar* channel
            // value; only genuine array types mean "repeated attribute".
            static if (is(V == string) || !isDynamicArray!(Unqual!V))
            {
                if (acount > 1)
                {
                    const mark = path.text.length;
                    path.text ~= "@" ~ attrKey(R.namespace_, R.localName);
                    failure = attachPath(path, baseError(
                        SdlErrorCode.duplicateRole, attrs[1].value.span(),
                        "duplicate attribute"));
                    popSegment(path, mark);
                    return DRes!(U)(true);
                }
                const mark = path.text.length;
                path.text ~= "@" ~ attrKey(R.namespace_, R.localName);
                scope (exit) popSegment(path, mark);
                const attrScalar = acount ? attrs[0].value : SdlScalar(null);
                V slot = V.init;
                if (decodeSingular!(U, i, V, FieldConv)(acount == 1, attrScalar,
                        endSpan(node), "missing attribute \"" ~ R.localName
                        ~ "\"", path, failure, slot))
                    return DRes!(U)(true);
                assignField(result.tupleof[i], slot);
            }
            else
            {
                alias E = ForeachType!V;
                E[] items;
                foreach (a; 0 .. acount)
                {
                    const view = attrs[a];
                    const mark = path.text.length;
                    path.text ~= "@" ~ attrKey(R.namespace_, R.localName);
                    scope (exit) popSegment(path, mark);
                    auto r = decodeElement!(U, i, E, FieldConv)(view.value,
                        path, failure);
                    if (r.failed)
                        return DRes!(U)(true);
                    items ~= r.value;
                }
                assignField(result.tupleof[i], items);
            }
        }
        else static if (R.role == SdlRoleKind.tagValue)
        {
            static if (!R.dynamicValueSuffix && R.staticCount == 0)
            {
                bool found;
                const s = valueAt(node, R.positionalIndex, found);
                const mark = path.text.length;
                path.text ~= "<value[" ~ R.positionalIndex.to!string ~ "]>";
                scope (exit) popSegment(path, mark);
                V slot = V.init;
                if (decodeSingular!(U, i, V, FieldConv)(found, s, endSpan(node),
                        "missing positional value "
                        ~ R.positionalIndex.to!string, path, failure, slot))
                    return DRes!(U)(true);
                assignField(result.tupleof[i], slot);
            }
            else static if (R.staticCount != 0)
            {
                alias E = typeof(V.init[0]);
                V slot = void;
                foreach (offset; 0 .. R.staticCount)
                {
                    bool found;
                    const s = valueAt(node, R.positionalIndex + offset, found);
                    const mark = path.text.length;
                    path.text ~= "<value["
                        ~ (R.positionalIndex + offset).to!string ~ "]>";
                    scope (exit) popSegment(path, mark);
                    auto r = decodeElement!(U, i, E, FieldConv)(s, path,
                        failure);
                    if (r.failed || !found)
                    {
                        if (!found)
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(node),
                                "missing positional value "
                                ~ (R.positionalIndex + offset).to!string));
                        return DRes!(U)(true);
                    }
                    slot[offset] = r.value;
                }
                assignField(result.tupleof[i], slot);
            }
            else
            {
                alias E = ForeachType!V;
                E[] items;
                foreach (offset; 0 .. node.valueCount)
                {
                    if (R.positionalIndex + offset >= node.valueCount)
                        break;

                    bool found;
                    const s = valueAt(node, R.positionalIndex + offset, found);
                    if (!found)
                        break;
                    const mark = path.text.length;
                    path.text ~= "<value["
                        ~ (R.positionalIndex + offset).to!string ~ "]>";
                    scope (exit) popSegment(path, mark);
                    auto r = decodeElement!(U, i, E, FieldConv)(s, path,
                        failure);
                    popSegment(path, mark);
                    if (r.failed)
                        return DRes!(U)(true);
                    items ~= r.value;
                }
                assignField(result.tupleof[i], items);
            }
        }
        else static if (R.role == SdlRoleKind.tagName)
        {
            if (decodeIdentity!V(node.qualifiedName.localName, node.nameSpan(),
                    path, failure, result.tupleof[i]))
                return DRes!(U)(true);
        }
        else static if (R.role == SdlRoleKind.tagNamespace)
        {
            if (decodeIdentity!V(node.qualifiedName.namespace_,
                    node.nameSpan(), path, failure, result.tupleof[i]))
                return DRes!(U)(true);
        }
        else
        {
            // extra: captured by S8's unknown-field milestone.
        }
    }}
    return DRes!(U)(false, result);
}

private void pushDup(ref WalkPath p, scope const(char)[] local) @safe
{
    p.text ~= "." ~ local ~ "[1]";
}

private string attrKey(scope const(char)[] ns,
    scope const(char)[] local) @safe
{
    return ns.length ? ns.idup ~ ":" ~ local.idup : local.idup;
}

private bool keyIn(K)(K[] keys, K probe)
{
    foreach (k; keys)
        if (k == probe)
            return true;
    return false;
}

private K keyFromString(K)(scope const(char)[] raw, SdlSpan span,
    ref WalkPath path, ref SdlError failure)
{
    static if (is(K == string))
        return raw.idup;
    else static if (is(K == enum))
    {
        enum names = wireNames!(Sdl, K, resolveCaseStyle!(Sdl, K));
        foreach (i, name; names)
            if (raw == name)
            {
                K found = K.init;
                bool hit;
                static foreach (mi, m; __traits(allMembers, K))
                    if (!hit && mi == i)
                    {
                        found = __traits(getMember, K, m);
                        hit = true;
                    }
                assert(hit);
                return found;
            }
        failure = attachPath(path, typedError!K(SdlErrorCode.unknownMember,
            span, "no enum member is named \"" ~ raw.idup ~ "\""));
        return K.init;
    }
    else
        static assert(false, "wired.sdl: unreachable AA key type");
}

/** Reads a tag's own name or namespace into a dynamic identity field.

An enum-typed identity resolves through the shared name policy, exactly like
any other name-represented enum — matching the bare D member identifier would
ignore the `@WireCase`/`@WireName` spelling that `nameBearing` gates the field
on in the first place.

A name matching no member is ordinary bad input, so it is a structured decode
error at the tag's name span rather than an assertion: SPEC §7 admits no
throwing path, and the input is untrusted.
*/
private bool decodeIdentity(V)(scope const(char)[] raw, SdlSpan span,
    ref WalkPath path, ref SdlError failure, ref V out_)
{
    static if (is(V == string))
    {
        assignField(out_, raw.idup);
        return false;
    }
    else static if (is(V == enum))
    {
        enum names = wireNames!(Sdl, V, resolveCaseStyle!(Sdl, V));
        foreach (i, name; names)
            if (raw == name)
            {
                V found = V.init;
                bool hit;
                static foreach (mi, m; __traits(allMembers, V))
                    if (!hit && mi == i)
                    {
                        found = __traits(getMember, V, m);
                        hit = true;
                    }
                assert(hit);
                assignField(out_, found);
                return false;
            }
        failure = attachPath(path, typedError!V(SdlErrorCode.unknownMember,
            span, "no enum member is named \"" ~ raw.idup ~ "\""));
        return true;
    }
    else
        static assert(false, "wired.sdl: unreachable identity type");
}

// ── Public entries ───────────────────────────────────────────────────────────

/** Decodes aggregate `T` rooted at one already-parsed SDL node (SPEC §11).

The node is the containing tag for `T`: its channels are the aggregate's
declared roles. The document owning the node must outlive only the call —
every decoded string/binary payload is copied, so the returned value never
borrows the arena.

Root aggregates may not declare $(LREF SdlTagName) or $(LREF SdlTagNamespace)
fields (SPEC §5); the S5 projection rejects those shapes at compile time.
*/
SdlExpected!T fromSDL(T)(return scope SdlNode node) @safe
if (is(T == struct))
{
    WalkPath path;
    SdlError failure;
    auto r = decodeAggregate!(T)(node, path, failure);
    if (r.failed)
        return sdlErr!T(failure);
    return sdlOk(r.value);
}

/// ditto — parses `text` under `config` first; lex/parse failures propagate
/// unchanged with their own stages, codes, spans, and owned source name.
SdlExpected!T fromSDL(T, alias config = sdlParserConfigFor!T)(
    scope const(char)[] text, scope const(char)[] sourceName = null) @safe
if (is(T == struct))
{
    auto parsed = parseSdlDocument!config(text, sourceName);
    if (!parsed.hasValue)
        return sdlErr!T(parsed.error);
    return fromSDL!T(parsed.document.root);
}

// ── Tests ────────────────────────────────────────────────────────────────────
version (unittest)
{
    private import std.algorithm.sorting : sort;

    import sparkles.wired.policy : WireCase, WireConvert, WireMatch,
        WireName, WireOptional, WireRepr, WireSkip;

    private struct Dep
    {
        @SdlAttribute() string id;
    }

    private static struct Full
    {
        @SdlTagValue(0) string name;
        @SdlTagValue(1) int[2] bounds;
        @SdlTagValue(3) string[] extraArgs;
        @SdlAttribute() bool verbose;
        @SdlAttribute() string[] aliases;
        @SdlChild() Dep dep;
        @SdlChild() string[] authors;
        @SdlChild() Dep[] node;
        @SdlChild() Dep[string] byKey;
        @SdlTagName() string tagName_;
        @SdlTagNamespace() string tagNs;
    }

    /// Text-form wrapper: the synthetic root consumes the single `config`
    /// tag; Full's declared roles live on that tag.
    private static struct FullDoc
    {
        @SdlChild() Full config;
    }

    private Full decodeFull(string source)
    {
        auto parsed = parseSdlDocument!sdlFull(source, "full.sdl");
        assert(parsed.hasValue, parsed.error.toString);
        auto result = fromSDL!(Full)(parsed.document.root.byChild.front);
        assert(result.hasValue, result.error.toString);
        return result.value;
    }
}

private enum fullSource =
    "config \"svc\" 10 20 \"--fast\" verbose=true aliases=\"a\" aliases=\"b\" {\n"
    ~ "dep id=\"p\"\n"
    ~ "authors \"a1\" \"a2\"\n"
    ~ "authors \"a3\"\n"
    ~ "node id=\"n1\"\n"
    ~ "node id=\"n2\"\n"
    ~ "k1 id=\"v1\"\n"
    ~ "k2 id=\"v2\"\n"
    ~ "}\n";

// One fixture exercising all three channels together (SPEC §6 gate).
@("wired.sdl.codec.allChannelsFixture")
@system unittest
{
    const v = decodeFull(fullSource);
    assert(v.name == "svc");
    assert(v.bounds == [10, 20]);
    assert(v.extraArgs == ["--fast"]);
    assert(v.verbose);
    assert(v.aliases == ["a", "b"]);
    assert(v.dep.id == "p");
    assert(v.authors == ["a1", "a2", "a3"]); // repeated occurrences merge
    assert(v.node.length == 2 && v.node[1].id == "n2");
    assert(!("k1" !in v.byKey) && v.byKey["k1"].id == "v1"
        && v.byKey["k2"].id == "v2");
    assert(v.tagName_ == "config" && v.tagNs.length == 0);

    // Text entry agrees with the node-rooted walk field by field.
    const textual = fromSDL!(FullDoc, sdlFull)(fullSource, "full.sdl");
    assert(textual.hasValue);
    const w = textual.value.config;
    assert(w.name == v.name && w.bounds == v.bounds
        && w.extraArgs == v.extraArgs && w.verbose == v.verbose
        && w.aliases == v.aliases && w.dep == v.dep
        && w.authors == v.authors && w.node == v.node
        && !w.tagNs.length && w.tagName_ == v.tagName_);
}

@("wired.sdl.codec.repetitionAndDuplicateRules")
@system unittest
{
    static struct DupChildDoc
    {
        @SdlChild() Dep dep;
    }

    // Duplicate singular child: second occurrence's span wins.
    auto dup = fromSDL!(DupChildDoc, sdlFull)("dep id=\"a\"\ndep id=\"b\"");
    assert(dup.hasError, "expected duplicate");
    assert(dup.error.code == SdlErrorCode.duplicateRole);
    assert(dup.error.rolePath[] == ".dep[1]");
    assert(dup.error.span.start.byteOffset > 0);

    static struct AADoc
    {
        @SdlChild() Dep[string] k;
    }

    // Duplicate AA key rejects the second occurrence.
    auto dupKey = fromSDL!(AADoc, sdlFull)("k id=\"1\"\nk id=\"2\"");
    assert(dupKey.hasError);
    assert(dupKey.error.code == SdlErrorCode.duplicateRole);
    assert(dupKey.error.rolePath[] == ".k[k]");
    assert(dupKey.error.span.start.byteOffset > 0);

    // Missing required singular child reports at the root terminator.
    auto missingChild = fromSDL!(DupChildDoc, sdlFull)("");
    assert(missingChild.hasError
        && missingChild.error.code == SdlErrorCode.missingRole);
    assert(missingChild.error.rolePath[] == ".dep[0]");
    assert(missingChild.error.span.start.byteOffset == 0);

    static struct AttrReq
    {
        @SdlAttribute() bool verbose;
    }
    static struct AttrReqDoc
    {
        @SdlChild() AttrReq a;
    }

    // Missing required attribute reports at the containing tag's terminator.
    auto missingAttr = fromSDL!(AttrReqDoc, sdlFull)("a\n");
    assert(missingAttr.hasError
        && missingAttr.error.code == SdlErrorCode.missingRole);
    assert(missingAttr.error.rolePath[] == ".a[0]@verbose");
    assert(missingAttr.error.span.start.byteOffset == 2);

    static struct Slots
    {
        @SdlTagValue(0) int a;
        @SdlTagValue(1) int[2] pair;
        @SdlTagValue(3) string[] tail;
    }
    static struct SlotsDoc
    {
        @SdlChild() Slots s;
    }

    // Missing required positional slot keeps its index in the path.
    auto missingSlot = fromSDL!(SlotsDoc, sdlFull)("s 7\n");
    assert(missingSlot.hasError
        && missingSlot.error.code == SdlErrorCode.missingRole);
    assert(missingSlot.error.rolePath[] == ".s[0]<value[1]>");

    // Static arrays occupy exactly their positions.
    auto shortBounds = fromSDL!(SlotsDoc, sdlFull)("s 7 8\n");
    assert(shortBounds.hasError
        && shortBounds.error.code == SdlErrorCode.missingRole);
    assert(shortBounds.error.rolePath[] == ".s[0]<value[2]>");

    // Dynamic suffix may legitimately be empty or consume the remainder.
    auto noneSuffix = fromSDL!(SlotsDoc, sdlFull)("s 7 8 9\n");
    assert(noneSuffix.hasValue);
    assert(noneSuffix.value.s.tail.length == 0);
    auto someSuffix = fromSDL!(SlotsDoc, sdlFull)("s 7 8 9 \"t\"\n");
    assert(someSuffix.hasValue);
    assert(someSuffix.value.s.tail == ["t"]);
}

@("wired.sdl.codec.enumPolicy")
@system unittest
{
    // Type-level case style applies to plain members; an explicit
    // @WireName!Sdl beats the case machinery.
    @WireCase!Sdl(CaseStyle.kebabCase)
    enum Level { low, highVal }

    enum Aliased
    {
        low,
        @WireName!Sdl("peak") highVal,
    }

    static struct Holder
    {
        @SdlAttribute() Level level;
        @WireCase!Sdl(CaseStyle.snakeCase, WireTarget.value)
        @SdlAttribute() Level renamed;
        @SdlAttribute() Aliased aliased;
    }

    static struct HolderDoc
    {
        @SdlChild() Holder h;
    }
    auto doc = fromSDL!(HolderDoc, sdlFull)(
        "h level=\"high-val\" renamed=\"high_val\" aliased=\"peak\"");
    assert(doc.hasValue, doc.error.toString);
    const hv = doc.value.h;
    assert(hv.level == Level.highVal);
    assert(hv.renamed == Level.highVal);
    assert(hv.aliased == Aliased.highVal);

    auto unknown = fromSDL!(HolderDoc, sdlFull)("h level=\"nope\"");
    assert(unknown.hasError
        && unknown.error.code == SdlErrorCode.unknownMember);

    // Repr.value enums take integer spellings.
    @WireRepr!Sdl(Repr.value)
    enum Codes { one = 1, two = 2 }
    static struct Coded
    {
        @SdlAttribute() Codes code;
    }
    static struct CodedDoc
    {
        @SdlChild() Coded c;
    }
    auto byValue = fromSDL!(CodedDoc, sdlFull)("c code=2");
    assert(byValue.hasValue && byValue.value.c.code == Codes.two);
    auto badValue = fromSDL!(CodedDoc, sdlFull)("c code=9");
    assert(badValue.hasError
        && badValue.error.code == SdlErrorCode.unknownMember);
}

@("wired.sdl.codec.converters")
@system unittest
{
    static struct Shifted
    {
        @WireConvert!(v => v + 1, v => v - 1) @SdlAttribute() int base;
        @SdlAttribute() int plain;
    }

    static struct ShiftedDoc
    {
        @SdlChild() Shifted s;
    }
    auto good = fromSDL!(ShiftedDoc, sdlFull)("s base=6 plain=1");
    assert(good.hasValue, good.error.toString);
    assert(good.value.s.base == 5 && good.value.s.plain == 1);

    // Converter failures keep their span and a structured code.
    static struct Throwing
    {
        @WireConvert!(v => v.to!string, v => to!int(v)) @SdlAttribute() int port;
    }
    static struct ThrowingDoc
    {
        @SdlChild() Throwing t;
    }
    auto rejected = fromSDL!(ThrowingDoc, sdlFull)(`t port="oops"`);
    assert(rejected.hasError
        && rejected.error.code == SdlErrorCode.conversionFailed);
    assert(rejected.error.reason.length > 0);
}

@("wired.sdl.codec.nullAwareMatrix")
@system unittest
{
    static struct Opt
    {
        @SdlAttribute() Nullable!int maybe;
        @SdlChild() Optional!string label;
        @SdlAttribute() Ternary tri;
        @SdlAttribute() int strict;
    }

    static struct OptDoc
    {
        @SdlChild() Opt o;
    }
    auto allSet = fromSDL!(OptDoc, sdlFull)(
        "o maybe=7 tri=true strict=1 {\nlabel \"hi\"\n}");
    assert(allSet.hasValue);
    const o = allSet.value.o;
    assert(!o.maybe.isNull && o.maybe.get == 7);
    assert(o.label == some("hi"));
    assert(o.tri == Ternary.yes);

    auto nulled = fromSDL!(OptDoc, sdlFull)(
        "o maybe=null tri=null strict=1 {\nlabel null\n}");
    assert(nulled.hasValue, nulled.error.toString);
    assert(nulled.value.o.maybe.isNull
        && nulled.value.o.label == Optional!string()
        && nulled.value.o.tri == Ternary.unknown);

    auto absent = fromSDL!(OptDoc, sdlFull)("o strict=1");
    assert(absent.hasValue);
    assert(absent.value.o.maybe.isNull
        && absent.value.o.label == Optional!string()
        && absent.value.o.tri == Ternary.unknown);

    // SDL null into a non-null-aware target is a kind error at the scalar.
    auto plainNull = fromSDL!(OptDoc, sdlFull)("o strict=null");
    assert(plainNull.hasError
        && plainNull.error.code == SdlErrorCode.unexpectedKind
        && plainNull.error.targetType == "int");
}

@("wired.sdl.codec.scalarWidthMatrix")
@system unittest
{
    static struct Widths
    {
        @SdlTagValue(0) int asInt;
        @SdlTagValue(1) uint asUint;
        @SdlTagValue(2) short asShort;
        @SdlTagValue(3) long asLong;
        @SdlTagValue(4) float asFloat;
        @SdlTagValue(5) double asDouble;
        @SdlTagValue(6) real asReal;
        @SdlTagValue(7) dchar asDchar;
        @SdlTagValue(8) char asChar;
        @SdlTagValue(9) bool asBool;
    }
    static struct WidthsDoc
    {
        @SdlChild() Widths w;
    }
    auto ok = fromSDL!(WidthsDoc, sdlFull)(
        "w -5 9 83 42L .5F .25D .125BD '€' 'q' true");
    assert(ok.hasValue, ok.error.toString);
    assert(ok.value.w.asShort == 'S' && ok.value.w.asReal == 0.125L);
    assert(ok.value.w.asDchar == '€' && ok.value.w.asChar == 'q');

    foreach (source; [
            "w 5000000000 1 2 3L .5F .25D .125BD 'a' 'b' true",
            "w 1 -1 2 3L .5F .25D .125BD 'a' 'b' true",
            "w 1 2 70000 3L .5F .25D .125BD 'a' 'b' true",
            "w 1 2 3 4L .5F .25D .125BD 'a' '€' true",
            ])
    {
        const rejected = fromSDL!(WidthsDoc, sdlFull)(source);
        assert(rejected.hasError
            && rejected.error.code == SdlErrorCode.numberOutOfRange, source);
    }

    // Float narrowing overflow is valueOutOfRange.
    import std.array : replicate;

    auto overflow = fromSDL!(WidthsDoc, sdlFull)(
        "w 1 2 3 4L " ~ "9".replicate(39) ~ "F .25D .125BD 'a' 'b' true");
    assert(overflow.hasError, overflow.error.toString);
    assert(overflow.error.code == SdlErrorCode.valueOutOfRange
        || overflow.error.code == SdlErrorCode.numberOutOfRange,
        overflow.error.toString);

    // Kind mismatches surface as unexpectedKind with the target type named.
    auto kindMismatch = fromSDL!(WidthsDoc, sdlFull)(
        `w 1 2 3 4L .5F .25D .125BD 'a' 'b' "x"`);
    assert(kindMismatch.hasError
        && kindMismatch.error.code == SdlErrorCode.unexpectedKind
        && kindMismatch.error.targetType == "bool");
}

@("wired.sdl.codec.presenceAndDefaults")
@safe unittest
{
    static struct Presence
    {
        @SdlTagValue(0) @WireOptional(WireSkip.whenDefault) int defaulted;
        @SdlTagValue(1) Optional!int wrapper;
    }
    auto allAbsent = fromSDL!(Presence, sdlFull)("p");
    assert(allAbsent.hasValue);
    assert(allAbsent.value.defaulted == 0
        && allAbsent.value.wrapper == Optional!int());

    static struct Fallback
    {
        @SdlAttribute() @WireOptional(onInvalid: WireInvalid.useDefault)
            int port;
    }
    auto fellBack = fromSDL!(Fallback, sdlFull)(`f port="oops"`);
    assert(fellBack.hasValue && fellBack.value.port == 0);
}

@("wired.sdl.codec.unionDecode")
@system unittest
{
    static struct Unioned
    {
        @SdlAttribute() SumType!(int, string) choice;
        @(WireMatch.first!Sdl) @SdlAttribute()
            SumType!(double, long) prioritized;
    }

    static struct UnionedDoc
    {
        @SdlChild() Unioned u;
    }
    auto mixed = fromSDL!(UnionedDoc, sdlFull)(`u choice="txt" prioritized=2`);
    assert(mixed.hasValue, mixed.error.toString);
    import std.conv : to;

    auto describe(T)(T s) => s.match!(a => T.stringof ~ ":" ~ a.to!string);
    assert(describe(mixed.value.u.choice) == describe(
        SumType!(int, string)("txt")));
    // first-strategy: long decodes the integer 2 fine and wins.
    assert(describe(mixed.value.u.prioritized) == describe(
        SumType!(double, long)(2L)));

    auto noVariant = fromSDL!(UnionedDoc, sdlFull)("u choice=true prioritized=1");
    assert(noVariant.hasError
        && noVariant.error.code == SdlErrorCode.conversionFailed);
}

@("wired.sdl.codec.namespacedChildrenAndTextPropagation")
@system unittest
{
    static struct Namespaced
    {
        @SdlAttribute() @WireName!Sdl("x:plat") string plat;
        @SdlChild() @WireName!Sdl("y:dep") Dep inner;
    }

    static struct NamespacedDoc
    {
        @SdlChild() Namespaced n;
    }
    auto ok = fromSDL!(NamespacedDoc, sdlFull)(
        "n x:plat=\"w\" {\ny:dep id=\"i\"\n}");
    assert(ok.hasValue, ok.error.toString);
    assert(ok.value.n.plat == "w" && ok.value.n.inner.id == "i");

    // A default-namespaced sibling does not satisfy the namespaced role.
    auto wrongNs = fromSDL!(NamespacedDoc, sdlFull)(
        "n plat=\"w\" {\ndep id=\"i\"\n}");
    assert(wrongNs.hasError
        && wrongNs.error.code == SdlErrorCode.missingRole);

    // Lex/parse failures propagate unchanged through the text overload.
    auto lexical = fromSDL!(NamespacedDoc, sdlFull)(`n plat="open`, "bad.sdl");
    assert(lexical.hasError
        && lexical.error.stage == SdlErrorStage.lex
        && lexical.error.code == SdlErrorCode.unterminatedString);
    auto syntactic = fromSDL!(NamespacedDoc, sdlFull)(`n plat="w" {`, "bad.sdl");
    assert(syntactic.hasError, syntactic.error.toString);
    assert(syntactic.error.stage == SdlErrorStage.parse);
    assert(syntactic.error.code == SdlErrorCode.unexpectedEof,
        syntactic.error.code.to!string);
    assert(syntactic.error.sourceName[] == "bad.sdl");
}
