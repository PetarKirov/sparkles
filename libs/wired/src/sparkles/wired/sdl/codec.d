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
import std.traits : fullyQualifiedName,
    ForeachType,
    KeyType,
    OriginalType,
    TemplateArgsOf,
    Unqual,
    ValueType,
    isAssociativeArray,
    isDynamicArray,
    isFloatingPoint,
    isIntegral,
    isSigned,
    isSomeChar,
    isStaticArray,
    isUnsigned;
import std.sumtype : isSumType;
import std.typecons : Nullable, Ternary;

import optional : Optional, some;

import sparkles.base.smallbuffer : SmallBuffer;
import std.experimental.allocator.mallocator : Mallocator;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.wired.policy : Repr, WireInvalid, WireTarget, convertOf,
    hasConvert, resolveCaseStyle, resolveRepr, resolvedFieldPolicies, wireNames;
import sparkles.wired.schema : NodeKind, ScalarKind;
import sparkles.wired.sdl.config : SdlParserConfig, sdlFull;
import sparkles.wired.sdl.document : SdlNode, SdlQualifiedName, SdlScalar,
    SdlScalarKind;
import sparkles.wired.policy : MatchStrategy, WireSkip;
import sparkles.wired.sdl.document : SdlAttributeView, SdlSpan;
import sparkles.wired.sdl.error : SdlError, SdlErrorCode, SdlErrorStage,
    SdlExpected, sdlErr, sdlOk;
import sparkles.wired.sdl.schema_annotations : SdlFieldRole;
import sparkles.wired.sdl.reader : parseSdlDocument;
import sparkles.wired.sdl.writer : SdlString, writeSdlDocument;
import sparkles.wired.sdl.schema_annotations : Sdl, SdlAttribute, SdlChild,
    SdlChildShape, SdlExtra, SdlRoleKind, SdlTagNamespace, SdlTagName,
    SdlTagValue, sdlAggregateRoles;

version (unittest)
{
    import std.sumtype : SumType;
    import std.sumtype : match;
}

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
    static if (is(T == Nullable!N, N) || is(T == Optional!O, O))
        enum isNullAwareType = true;
    else static if (__traits(isSame, T, Ternary))
        enum isNullAwareType = true;
    else
        enum isNullAwareType = false;
}

/// Absence test shared by every channel: null-aware wrappers report their
/// empty state; plain values are always present.
private bool encAbsent(V)(scope const ref V v)
{
    static if (isNullAwareType!(V))
    {
        static if (__traits(isSame, Unqual!V, Ternary))
            return v == Ternary.unknown;
        else
        {
            const empty = V.init;
            return v == empty;
        }
    }
    else
        return false;
}

/// Runtime unwrap of a present null-aware wrapper (Ternary → bool).
private auto encPayload(V)(scope const ref V v)
{
    static if (isNullAwareType!(V))
    {
        static if (__traits(isSame, Unqual!V, Ternary))
            return v == Ternary.yes;
        else static if (is(V == Nullable!N, N))
            return v.get;
        else
            return v.front;
    }
    else
        return v;
}

/// Whether aggregate `T` declares dynamic identity fields.
private template HasIdentity(T)
{
    static if (is(T == struct))
    {
        static immutable bool HasIdentity = () {
            alias r2 = sdlAggregateRoles!(Unqual!T).sdlFieldRoles;
            foreach (role; r2.roles)
                if (role.dynamicName || role.dynamicNamespace)
                    return true;
            return false;
        }();
    }
    else
        static immutable bool HasIdentity = false;
}

private template EncPayload(V)
{
    static if (is(V == Nullable!N, N))
        alias EncPayload = N;
    else static if (is(V == Optional!O, O))
        alias EncPayload = O;
    else static if (__traits(isSame, V, Ternary))
        alias EncPayload = bool;
    else
        alias EncPayload = V;
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

private template WrapContained(T, C)
{
    static if (is(T == Nullable!N, N) && is(C == N))
        static WrapContained = T(C.init);
    else static if (is(T == Optional!O, O) && is(C == O))
        static WrapContained = T(O(C.init));
    else
        static WrapContained = T.init;
}

private template Contained2(T)
{
    static if (is(T == Nullable!N, N))
        alias Contained2 = N;
    else static if (is(T == Optional!O, O))
        alias Contained2 = O;
    else
        alias Contained2 = void;
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
    else static if (isNullAwareType!(T))
    {
        // Direct null-aware targets unwrap their payload and rewrap.
        auto r = decodeScalar!(EncPayload!T, enumStyle, enumRepr)(s, failure);
        if (r.failed)
            return DRes!T(true);
        static if (__traits(isSame, Unqual!T, Ternary))
            return DRes!T(false, r.value ? Ternary.yes : Ternary.no);
        else static if (is(T == Nullable!N, N))
            return DRes!T(false, T(r.value));
        else
            () @trusted { return DRes!T(false, some(r.value)); }();
    }
    else
        static assert(false, "wired.sdl: unsupported scalar target "
            ~ U.stringof);
}

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


/// Field assignment for freshly decoded values. SumType (and any other
/// type with an `@system opAssign` inherited from its storage) taints plain
/// copies; the decode path only assigns newly built values into default-
/// initialized slots, which is memory-safe by construction.
/// Narrow-trust moves for result payloads whose storage type declares an
/// `@system opAssign` (SumType's tagged storage). Values here are always
/// freshly decoded locals.
private DRes!T trustMove(T)(ref DRes!T r) @trusted
{
    DRes!T copy = void;
    () @trusted { copy = r; }();
    return copy;
}

private DRes!T trustFail(T)() @trusted => DRes!T(true);

private DRes!T trustInit(T)() @trusted
{
    static if (is(T == void))
        return DRes!T(false);
    else
        return DRes!T(false, T.init);
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
                        auto r = decodeElement!(M, symbol, policies, i)(
                            firstValueOf(m), path, failure);
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
            assignField(result.tupleof[i], identityString!(V)(node.qualifiedName.localName));
        }
        else static if (R.role == SdlRoleKind.tagNamespace)
        {
            assignField(result.tupleof[i], identityString!(V)(
                node.qualifiedName.namespace_));
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

/// Applies a child value's dynamic tag-name/namespace fields as overrides.
/// Empty string identities do not override: the declared name is emitted so a
/// zero-init aggregate keeps its schema identity (canonical stability).
private void encChildName(T)(scope const ref T v, ref EncBuilder b,
    ref string ns, ref string local)
{
    alias roles = sdlAggregateRoles!(T).sdlFieldRoles;
    static foreach (j; 0 .. roles.roles.length)
    {{
        enum RJ = roles.roles[j];
        static if (RJ.role == SdlRoleKind.tagName)
        {
            const candidate = identityString!(typeof(T.tupleof[j]))(
                v.tupleof[j]);
            if (candidate.length)
                local = candidate;
        }
        else static if (RJ.role == SdlRoleKind.tagNamespace)
        {
            const candidate = identityString!(typeof(T.tupleof[j]))(
                v.tupleof[j]);
            if (candidate.length)
                ns = candidate;
        }
    }}
}

private V identityString(V)(scope const(char)[] raw)
{
    static if (is(V == string))
        return raw.idup;
    else static if (is(V == enum))
    {
        foreach (m; __traits(allMembers, V))
            if (raw == __traits(identifier, m))
                return __traits(getMember, V, m);
        assert(false, "dynamic tag name must match a declared member");
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
    private import std.algorithm.searching : canFind;
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

    private static struct Scalars
    {
        @SdlTagValue(0) bool flagB;
        @SdlTagValue(1) char narrow;
        @SdlTagValue(2) dchar wide;
        @SdlTagValue(3) int smallInt;
        @SdlTagValue(4) long bigInt;
        @SdlTagValue(5) float f32;
        @SdlTagValue(6) double f64;
        @SdlTagValue(7) real dec;
        @SdlTagValue(8) string label;
    }

    private static struct Slots
    {
        @SdlTagValue(0) int a;
        @SdlTagValue(1) int[2] pair;
        @SdlTagValue(3) string[] tail;
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

// ── Typed canonical emission (SPEC §6/§9) ────────────────────────────────────

/** Builds a temporary ordered arena from a D value, mirroring the decode
walk field-for-field so `writeSDL` can reuse $(LREF writeSdlDocument)'s
canonical-form kernels verbatim. */
private struct EncBuilder
{
    import sparkles.wired.sdl.document : SdlAttributeCell, SdlDocument,
        SdlNodeCell, SdlValueCell;

    SdlDocument!(Mallocator) doc;
    size_t[][] kids;            // child arena indices per node, in order
    SdlValueCell[][] vals;      // positional values per node
    SdlAttributeCell[][] attrs; // attributes per node
    char[][] strings;           /// keeps temporary/converter payloads alive
    SdlError failure;
    WalkPath path;
}

private size_t encAppendNode(ref EncBuilder b, scope const(char)[] ns,
    scope const(char)[] local, uint depth)
{
    import sparkles.wired.sdl.document : SdlNodeCell;

    SdlNodeCell cell;
    cell.qualifiedName = SdlQualifiedName(ns, local);
    cell.depth = depth;
    b.doc.nodes ~= cell;
    b.kids.length = b.doc.nodes.length;
    b.vals.length = b.doc.nodes.length;
    b.attrs.length = b.doc.nodes.length;
    return b.doc.nodes.length - 1;
}

private void encAddValue(ref EncBuilder b, size_t node,
    scope const ref SdlScalar s)
{
    import sparkles.wired.sdl.document : SdlValueCell;

    () @trusted {
        auto cell = SdlValueCell.init;
        cell.value = s;
        b.doc.values ~= cell;
        b.vals[node] ~= cell;
    }();
}

private void encAddAttribute(ref EncBuilder b, size_t node,
    SdlQualifiedName name, scope const ref SdlScalar s)
{
    import sparkles.wired.sdl.document : SdlAttributeCell;

    SdlAttributeCell cell;
    cell.qualifiedName = name;
    cell.value = s;
    b.doc.attributes ~= cell;
    b.attrs[node] ~= cell;
}

private string encOwn(ref EncBuilder b, scope const(char)[] s)
{
    string owned = s.idup;
    () @trusted { b.strings ~= owned.dup; }();
    return owned;
}

/** Flattens per-node extents into the arena and links child indices. */
private void encFinish(ref EncBuilder b)
{
    size_t valueCursor;
    foreach (i, ref node; b.doc.nodes)
    {
        node.valueStart = valueCursor;
        node.valueCount = b.vals[i].length;
        foreach (cell; b.vals[i])
            b.doc.values ~= cell;
        valueCursor += b.vals[i].length;
    }
    size_t attrCursor;
    foreach (i, ref node; b.doc.nodes)
    {
        node.attributeStart = attrCursor;
        node.attributeCount = b.attrs[i].length;
        foreach (cell; b.attrs[i])
            b.doc.attributes ~= cell;
        attrCursor += b.attrs[i].length;
    }
    size_t childCursor;
    foreach (i, ref node; b.doc.nodes)
    {
        node.childStart = childCursor;
        node.childCount = b.kids[i].length;
        node.hasBlock = b.kids[i].length != 0;
        childCursor += b.kids[i].length;
    }
    b.doc.childIndexes.length = childCursor;
    foreach (i, kids; b.kids)
        foreach (pos, child; kids)
            b.doc.childIndexes[b.doc.nodes[i].childStart + pos] = child;
}

/// Builds the canonical $(LREF SdlScalar) payload for one wire value.
/// Rejects non-finite binary floating values before emission (SPEC §9: SDL
/// has no portable literal for them); finite values keep their exact kind.
private SdlScalar encFiniteScalar(T)(T v, ref EncBuilder b)
{
    import std.math : isFinite;

    if (!isFinite(v))
    {
        b.failure = attachPath(b.path, encBaseError(
            SdlErrorCode.valueOutOfRange,
            "non-finite floats have no SDL literal representation"));
        return SdlScalar.init;
    }
    static if (T.sizeof <= 4)
        return SdlScalar(v);
    else
        return SdlScalar(cast(double) v);
}

private SdlScalar encScalar(T)(scope const ref T v, ref EncBuilder b,
    CaseStyle enumStyle = CaseStyle.original, Repr enumRepr = Repr.name)
{
    alias U = Unqual!T;
    static if (is(U == bool))
        return SdlScalar(v);
    else static if (is(U == string))
        return SdlScalar(encOwn(b, v));
    else static if (isSomeChar!U)
        return SdlScalar(cast(dchar) v);
    else static if (isIntegral!U)
    {
        static if (isSigned!U)
            return U.sizeof <= 4 ? SdlScalar(cast(int) v)
                : SdlScalar(cast(long) v);
        else static if (U.sizeof <= 4)
            return SdlScalar(cast(int) v);
        else
        {
            if (v > cast(ulong) long.max)
            {
                b.failure = attachPath(b.path, encBaseError(
                    SdlErrorCode.valueOutOfRange,
                    "unsigned value exceeds SDL's signed literal range"));
                return SdlScalar.init;
            }
            return SdlScalar(cast(long) v);
        }
    }
    else static if (isFloatingPoint!U && U.sizeof <= 4)
        return encFiniteScalar(cast(float) v, b);
    else static if (isFloatingPoint!U && U.sizeof <= 8)
        return encFiniteScalar(cast(double) v, b);
    else static if (isFloatingPoint!U)
    {
        import std.math : isFinite;

        if (!isFinite(v))
        {
            b.failure = attachPath(b.path, encBaseError(
                SdlErrorCode.valueOutOfRange,
                "non-finite floats have no SDL literal representation"));
            return SdlScalar.init;
        }
        return SdlScalar.decimal(cast(real) v);
    }
    else static if (is(U == enum))
    {
        static if (enumRepr == Repr.name)
        {
            enum memberNames = wireNames!(Sdl, U, enumStyle);
            foreach (i2, m; __traits(allMembers, U))
                if (__traits(getMember, U, m) == v)
                    return SdlScalar(encOwn(b, memberNames[i2]));
            assert(false, "wired.sdl: enum value has no wire name");
        }
        else
            return SdlScalar(cast(long) v);
    }
    else
        static assert(false, "wired.sdl: unsupported scalar source "
            ~ U.stringof);
}



// ── Aggregate emission ───────────────────────────────────────────────────────

private SdlError encBaseError(SdlErrorCode code,
    scope const(char)[] reason)
{
    import sparkles.wired.sdl.error : SdlErrorStage;

    SdlError e;
    e.stage = SdlErrorStage.encode;
    e.code = code;
    e.reason ~= reason.idup;
    return e;
}

/// Result carrier for converter application on the encode side.
private struct EncWire(T)
{
    T value;
    bool failed;
}

/// The wire type a converter produces for source type `V`.
private template ConvWire(alias Conv, V)
{
    static if (is(Conv == void))
        alias ConvWire = V;
    else
    {
        alias Raw = typeof(Conv.to(V.init));
        static if (__traits(compiles, Raw.init.value))
            alias ConvWire = typeof(Raw.init.value);
        else
            alias ConvWire = Raw;
    }
}

/// Applies an optional field converter, funnelling throw- and Expected-style
/// failures into the builder's structured channel.
private EncWire!(ConvWire!(Conv, V)) encConverted(alias Conv, V)(
    scope const ref V v, ref EncBuilder b, scope const(char)[] site)
{
    alias R = ConvWire!(Conv, V);

    static if (is(Conv == void))
        return EncWire!(R)(v, false);
    else
    {
        try
        {
            alias Raw = typeof(Conv.to(v));
            static if (__traits(compiles, Raw.init.value))
            {
                auto r = Conv.to(v);
                if (r.hasError)
                {
                    b.failure = attachPath(b.path, encBaseError(
                        SdlErrorCode.conversionFailed,
                        "converter rejected the value at " ~ site ~ ": "
                        ~ r.error.reason[].idup));
                    return EncWire!(R)(R.init, true);
                }
                return EncWire!(R)(r.value, false);
            }
            else
                return EncWire!(R)(Conv.to(v), false);
        }
        catch (Exception e)
        {
            b.failure = attachPath(b.path, encBaseError(
                SdlErrorCode.conversionFailed,
                "converter rejected the value at " ~ site ~ ": " ~ e.msg));
            return EncWire!(R)(R.init, true);
        }
    }
}

/** Emits one aggregate's fields into `b` under `nodeIdx`: positional values
by declared slot order, attributes with repeats for sequences, children last
in declaration order (SPEC §6/§9). */
private void encodeAggregate(T)(ref EncBuilder b, scope const ref T value,
    size_t nodeIdx)
if (is(T == struct))
{
    import std.algorithm.sorting : sort;

    if (b.failure.reason.length)
        return;

    alias roles = sdlAggregateRoles!(T).sdlFieldRoles;
    alias policies = resolvedFieldPolicies!(Sdl, T);

    // ── Positional values ────────────────────────────────────────────────
    SdlScalar[size_t] slotScalars;
    size_t suffixStart = size_t.max;
    bool haveSuffix;
    SdlScalar[] suffixItems;

    static foreach (i, symbol; T.tupleof)
    {{
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC = convertOf!(Sdl, symbol, V);
        else
            alias FC = void;

        static if (R.role == SdlRoleKind.tagValue && !isNullAwareType!(V))
        {
            static if (R.dynamicValueSuffix)
            {
                suffixStart = R.positionalIndex;
                haveSuffix = true;
                foreach (elem; value.tupleof[i])
                {
                    auto wire = encConverted!(FC, typeof(elem))(elem, b,
                        "<value[" ~ R.positionalIndex.to!string ~ "]>");
                    if (wire.failed)
                        return;
                    const mark = b.path.text.length;
                    b.path.text ~= "<value[" ~ R.positionalIndex.to!string ~ "]>";
                    auto s = encScalar(wire.value, b);
                    popSegment(b.path, mark);
                    if (b.failure.reason.length)
                        return;
                    suffixItems ~= s;
                }
            }
            else static if (R.staticCount != 0)
            {
                static foreach (k; 0 .. R.staticCount)
                {{
                    enum slotLabel = "<value["
                        ~ (R.positionalIndex + k).to!string ~ "]>";
                    auto wire_k = encConverted!(FC, typeof(
                        value.tupleof[i][k]))(value.tupleof[i][k], b,
                        slotLabel);
                    if (wire_k.failed)
                        return;
                    const mark = b.path.text.length;
                    b.path.text ~= slotLabel;
                    auto s_k = encScalar(wire_k.value, b);
                    popSegment(b.path, mark);
                    if (b.failure.reason.length)
                        return;
                    slotScalars[R.positionalIndex + k] = s_k;
                }}
            }
            else
            {
                auto wire_i = encConverted!(FC, V)(value.tupleof[i], b,
                    "<value[" ~ R.positionalIndex.to!string ~ "]>");
                if (wire_i.failed)
                    return;
                const mark = b.path.text.length;
                b.path.text ~= "<value[" ~ R.positionalIndex.to!string ~ "]>";
                auto s_i = encScalar(wire_i.value, b);
                popSegment(b.path, mark);
                if (b.failure.reason.length)
                    return;
                slotScalars[R.positionalIndex] = s_i;
            }
        }
    }}

    // Contiguity: fixed slots must occupy exactly 0 .. count-1 so the
    // declared suffix start equals their count; gapped layouts have no
    // positional representation and are structured encode errors.
    size_t maxFixed;
    bool gap;
    foreach (slot, s; slotScalars)
    {
        if (s.kind == SdlScalarKind.none)
            return;
        maxFixed = slot > maxFixed ? slot : maxFixed;
    }
    if (slotScalars.length)
        foreach (slot; 0 .. maxFixed + 1)
            if ((slot in slotScalars) is null)
                gap = true;
    if (gap || haveSuffix && suffixStart != maxFixed + 1)
    {
        b.failure = attachPath(b.path, encBaseError(
            SdlErrorCode.valueOutOfRange,
            "positional slots must be contiguous for canonical emission "
            ~ "(a dynamic suffix's declared index must equal the number of "
            ~ "fixed values)"));
        return;
    }

    auto orderedSlots = slotScalars.keys.dup;
    sort(orderedSlots);
    foreach (slot; orderedSlots)
        encAddValue(b, nodeIdx, slotScalars[slot]);
    foreach (s; suffixItems)
        encAddValue(b, nodeIdx, s);

    // ── Attributes ───────────────────────────────────────────────────────
    static foreach (i, symbol; T.tupleof)
    {{
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC2 = convertOf!(Sdl, symbol, V);
        else
            alias FC2 = void;

        static if (R.role == SdlRoleKind.attribute)
        {
            const attrName = SdlQualifiedName(encOwn(b, R.namespace_),
                encOwn(b, R.localName));
            const seg = "@" ~ attrKey(R.namespace_, R.localName);

            bool emitAttr = true;
            {
                static if (isNullAwareType!(V))
                    emitAttr = !encAbsent(value.tupleof[i]);
                else static if (policies[i].optional
                    && policies[i].skip == WireSkip.whenDefault)
                    emitAttr = !(value.tupleof[i] == V.init);
            }

            if (emitAttr)
            {
                const mark = b.path.text.length;
                b.path.text ~= seg;
                scope (exit) popSegment(b.path, mark);

                static if (isDynamicArray!(Unqual!V) && !is(V == string))
                {
                    alias E = ForeachType!(Unqual!V);
                    foreach (elem; value.tupleof[i])
                    {
                        auto wire = encConverted!(FC2, E)(elem, b, seg);
                        if (wire.failed)
                            return;
                        auto s = encScalar(wire.value, b);
                        if (b.failure.reason.length)
                            return;
                        encAddAttribute(b, nodeIdx, attrName, s);
                    }
                }
                else
                {
                    auto wire = encConverted!(FC2, V)(value.tupleof[i], b,
                        seg);
                    if (wire.failed)
                        return;
                    auto s = encScalar(wire.value, b);
                    if (b.failure.reason.length)
                        return;
                    encAddAttribute(b, nodeIdx, attrName, s);
                }
            }
        }    }}

    // ── Children ─────────────────────────────────────────────────────────
    static foreach (i, symbol; T.tupleof)
    {{
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC3 = convertOf!(Sdl, symbol, V);
        else
            alias FC3 = void;

        static if (R.role == SdlRoleKind.child && !isNullAwareType!(V))
        {
            const childDepth = nodeIdx == 0 ? 0u
                : cast(uint) (b.doc.nodes[nodeIdx].depth + 1);

            static if (!isDynamicArray!(Unqual!V)
                && !isAssociativeArray!(Unqual!V))
            {
                // Scalar or aggregate single child (null-aware absence is
                // handled by the dedicated wrapper branch below).
                string ns = R.namespace_;
                string local = R.localName;
                static if (__traits(hasMember, typeof(value.tupleof[i]),
                        "init") && HasIdentity!(typeof(value.tupleof[i])))
                    encChildName(value.tupleof[i], b, ns, local);

                const mark = b.path.text.length;
                b.path.text ~= "." ~ local ~ "[0]";
                const cIdx = encAppendNode(b, ns, local, childDepth);
                scope (exit) popSegment(b.path, mark);

                static if (is(Unqual!(EncPayload!V) == struct)
                    && !is(EncPayload!V == bool) && !isSomeChar!(EncPayload!V)
                    && !is(EncPayload!V == string))
                {
                    alias P = EncPayload!(V);
                    P payload = cast(P) encPayload(value.tupleof[i]);
                    encodeAggregate!(P)(b, payload, cIdx);
                }
                else
                {
                    auto wire = encConverted!(FC3, EncPayload!(V))(
                        encPayload(value.tupleof[i]), b,
                        "." ~ local ~ "[0]");
                    if (wire.failed)
                        return;
                    encAddValue(b, cIdx, encScalar(wire.value, b));
                    if (b.failure.reason.length)
                        return;
                }
                () @trusted { b.kids[nodeIdx] ~= cIdx; }();
            }
            else static if (isDynamicArray!(Unqual!V) && !is(V == string)
                && !isAssociativeArray!(Unqual!V))
            {
                alias E = ForeachType!(Unqual!V);
                static if (is(E == struct) && !isSomeChar!E && !is(E == enum))
                {
                    // Aggregate sequence: one sibling per element.
                    foreach (elem; value.tupleof[i])
                    {
                        string ns = R.namespace_;
                        string local = R.localName;
                        static if (HasIdentity!E)
                            encChildName(elem, b, ns, local);

                        const mark = b.path.text.length;
                        b.path.text ~= "." ~ local ~ "["
                            ~ b.kids[nodeIdx].length.to!string ~ "]";
                        const cIdx = encAppendNode(b, ns, local, childDepth);
                        scope (exit) popSegment(b.path, mark);

                        encodeAggregate!(E)(b, elem, cIdx);
                        () @trusted { b.kids[nodeIdx] ~= cIdx; }();
                        if (b.failure.reason.length)
                            return;
                    }
                }
                else
                {
                    // Scalar sequence: ONE child holding every element. An
                    // empty sequence emits no occurrence (SPEC §5.2: an empty
                    // sequence emits none), keeping canonical output stable.
                    if (value.tupleof[i].length == 0)
                        return;
                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ R.localName ~ "[0]";
                    const cIdx = encAppendNode(b, R.namespace_, R.localName,
                        childDepth);
                    scope (exit) popSegment(b.path, mark);

                    foreach (elem; value.tupleof[i])
                    {
                        auto wire = encConverted!(FC3, E)(elem, b,
                            "." ~ R.localName ~ "[0]");
                        if (wire.failed)
                            return;
                        auto s = encScalar(wire.value, b);
                        if (b.failure.reason.length)
                            return;
                        encAddValue(b, cIdx, s);
                    }
                    () @trusted { b.kids[nodeIdx] ~= cIdx; }();
                }
            }
            else static if (isAssociativeArray!(Unqual!V))
            {
                alias K = KeyType!(Unqual!V);
                alias M = ValueType!(Unqual!V);

                // Compile-time names claimed by other child fields; the AA
                // consumes every remaining same-namespace sibling so entry
                // tags may be arbitrarily named.
                static immutable string[] claimedNames = () {
                    string[] r;
                    static foreach (j; 0 .. roles.roles.length)
                        static if (roles.roles[j].role == SdlRoleKind.child
                            && j != i)
                            r ~= roles.roles[j].localName;
                    return r;
                }();

                struct Entry { string key; M value; }
                Entry[] entries;
                foreach (k, mv; value.tupleof[i])
                {
                    string spelling = keyFromString!(K)(k, SdlSpan.init, b.path,
                        b.failure);
                    entries ~= Entry(spelling, mv);
                }
                entries = entries.sort!((x, y) => x.key < y.key).release;

                foreach (entry; entries)
                {
                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ R.localName ~ "[" ~ entry.key ~ "]";
                    const cIdx = encAppendNode(b, R.namespace_, entry.key,
                        childDepth);
                    scope (exit) popSegment(b.path, mark);

                    static if (is(M == struct) && !isSomeChar!M && !is(M == enum))
                        encodeAggregate!(M)(b, entry.value, cIdx);
                    else
                    {
                        auto wire = encConverted!(FC3, M)(entry.value, b,
                            "." ~ R.localName ~ "[" ~ entry.key ~ "]");
                        if (wire.failed)
                            return;
                        encAddValue(b, cIdx, encScalar(wire.value, b));
                        if (b.failure.reason.length)
                            return;
                    }
                    () @trusted { b.kids[nodeIdx] ~= cIdx; }();
                }
            }
            else static if (isNullAwareType!(V))
            {
                if (encAbsent(value.tupleof[i]))
                    continue;

                alias C = Contained!(V);
                string ns = R.namespace_;
                string local = R.localName;
                const mark = b.path.text.length;
                b.path.text ~= "." ~ local ~ "[0]";
                const cIdx = encAppendNode(b, ns, local, childDepth);
                scope (exit) popSegment(b.path, mark);

                static if (__traits(isSame, Unqual!V, Ternary))
                {
                    encAddValue(b, cIdx, encScalar(value.tupleof[i]
                        .yes ? true : false, b));
                }
                else static if (is(C == struct) && !isSomeChar!C
                    && !is(C == string))
                {
                    encodeAggregate!(C)(b, encPayload(value.tupleof[i]), cIdx);
                }
                else
                {
                    auto wire = encConverted!(FC3, C)(
                        encPayload(value.tupleof[i]), b,
                        "." ~ local ~ "[0]");
                    if (wire.failed)
                        return;
                    encAddValue(b, cIdx, encScalar(wire.value, b));
                    if (b.failure.reason.length)
                        return;
                }
                () @trusted { b.kids[nodeIdx] ~= cIdx; }();
            }
        }
    }}

    // Dynamic identity overrides for THIS node come from its own fields;
    // they were applied by the parent before this call when the field is a
    // child role, so nothing to do here for non-root nodes.
}

/** Emits `value` as canonical SDL text through the shared schema walk
(SPEC §9): declaration order governs fields, input order governs sequences,
canonical lexicographic key order governs AA entries. Dynamic tag-name and
tag-namespace fields override each occurrence's identity; null-aware absent
wrappers emit nothing.

The arena built here feeds $(LREF writeSdlDocument) directly, so indentation,
ordering, and every scalar spelling come from the S4 kernels — there is no
second canonical-form implementation. Encode failures carry stage=encode,
a stable code, and a composed role path naming field and channel
(e.g. `$.dependency[1]@version`).
*/
SdlExpected!void writeSDL(T, Writer)(scope const auto ref T value,
    ref Writer writer)
if (is(T == struct))
{
    EncBuilder b;
    const root = encAppendNode(b, null, null, uint.max);
    encodeAggregate!(T)(b, value, root);
    if (b.failure.reason.length)
        return sdlErr!void(b.failure);
    encFinish(b);
    return writeSdlDocument(b.doc, writer);
}

/// ditto — renders into an owned $(LREF SdlString). A non-empty document
/// ends with exactly one LF (SPEC §11 file conventions); an empty one is
/// empty.
SdlExpected!SdlString toSDL(T)(scope const auto ref T value)
if (is(T == struct))
{
    SdlString buf;
    auto written = writeSDL!(T, SdlString)(value, buf);
    if (written.hasError)
        return sdlErr!SdlString(written.error);
    return sdlOk(buf);
}

/** SDL acceptance predicate for the SPEC §10 typed value law: `T`'s root is
an unconverted aggregate whose projected roles instantiate — i.e. exactly the
shapes `fromSDL`/`writeSDL` accept. The shared expressiveness contract has
not landed this name yet; until it does, this template documents the SDL-side
predicate and stands in for it. */
template isWireRoundTrippable(F, T)
{
    static if (is(T == struct) && __traits(isSame, F, Sdl))
        enum bool isWireRoundTrippable = __traits(compiles,
            sdlAggregateRoles!(Unqual!T));
    else
        enum bool isWireRoundTrippable = false;
}

// ── Encode tests ─────────────────────────────────────────────────────────────

version (unittest)
{
    // DUB-shaped recipe fixture set (SPEC §7 golden gate).
    private static struct Dependency
    {
        @SdlTagValue(0) string name;
        @WireName!Sdl("version") @SdlAttribute() string ver_;
        @WireName!Sdl("optional")
        @WireOptional(WireSkip.whenDefault) @SdlAttribute() bool optional_;
    }

    private static struct Configuration
    {
        @SdlTagValue(0) string name;
        @SdlChild() string[] platforms;
        @SdlChild() Dependency[] dependency;
    }

    private static struct Item
    {
        @SdlTagName() string kind;
        @SdlTagNamespace() string ns;
        @SdlTagValue(0) int v;
    }

    private static struct Recipe
    {
        @SdlChild() string[] authors;
        @SdlChild() Dependency[] dependency;
        @SdlChild() Configuration[] configuration;
        @SdlChild() Item[] items;
    }

    private auto encodeRecipe(ref const Recipe r)
    {
        return toSDL(r);
    }
}

@("wired.sdl.codec.writeSDL.recipeGolden")
@system unittest
{
    Recipe r;
    r.authors = ["alice", "bob"];
    r.dependency = [
        Dependency("vibe-d", "~>0.9", false),
        Dependency("optional-pkg", "1.0.0", true),
    ];
    r.configuration = [
        Configuration("library", ["windows", "linux"],
            [Dependency("cfg-dep", "2.0", false)]),
    ];
    Item itemA = { kind: "tool", ns: "x", v: 1 };
    Item itemB = { kind: "sub", ns: "y", v: -2 };
    r.items = [itemA, itemB];

    enum expected =
        `authors "alice" "bob"` ~ "\n"
        ~ `dependency "vibe-d" version="~>0.9"` ~ "\n"
        ~ `dependency "optional-pkg" version="1.0.0" optional=true` ~ "\n"
        ~ `configuration "library" {` ~ "\n"
        ~ `    platforms "windows" "linux"` ~ "\n"
        ~ `    dependency "cfg-dep" version="2.0"` ~ "\n"
        ~ `}` ~ "\n"
        ~ `x:tool 1` ~ "\n"
        ~ `y:sub -2` ~ "\n";

    const rendered = toSDL(r);
    assert(rendered.hasValue, rendered.error.toString);
    assert(rendered.value[] == expected, rendered.value[].idup);

    // LAW 2: canonical idempotence — write(parse(write(v))) byte-stable.
    //
    // Only statically named channels participate: an occurrence whose tag
    // carries a dynamic identity (`x:tool`) matches no declared field name,
    // so under the default ignore policy it is not re-decoded into `items`
    // (SPEC §6 matches children by full declared identity; §8 leaves
    // unmatched occurrences to the unknown policy). The law therefore runs
    // on the static channels; the dynamic golden has its own test below.
    Recipe staticRecipe;
    staticRecipe.authors = r.authors;
    staticRecipe.dependency = r.dependency;
    staticRecipe.configuration = r.configuration;
    auto reparsed = parseSdlDocument!sdlFull(rendered.value[], "golden.sdl");
    assert(reparsed.hasValue);
    auto back = fromSDL!(Recipe)(reparsed.document.root);
    assert(back.hasValue, back.error.toString);
    const decodedRecipe = back.value;
    assert(decodedRecipe.authors == r.authors);
    assert(decodedRecipe.dependency.length == 2
        && decodedRecipe.dependency[1].optional_ == true);
    assert(decodedRecipe.configuration.length == 1
        && decodedRecipe.configuration[0].platforms == ["windows", "linux"]);
    assert(decodedRecipe.items.length == 0);

    auto once = toSDL(staticRecipe);
    assert(once.hasValue, once.error.toString);
    auto reparse = parseSdlDocument!sdlFull(once.value[], "law.sdl");
    assert(reparse.hasValue);
    auto decodedStatic = fromSDL!(Recipe)(reparse.document.root);
    assert(decodedStatic.hasValue, decodedStatic.error.toString);
    const twice = toSDL(decodedStatic.value);
    assert(twice.hasValue && twice.value[] == once.value[]);
}

/// Encode-only canonical bytes for dynamic-identity occurrences: the emitted
/// spelling comes entirely from each element's tag-name/tag-namespace fields.
@("wired.sdl.codec.writeSDL.dynamicIdentityGolden")
@system unittest
{
    Item itemA = { kind: "tool", ns: "x", v: 1 };
    Item itemB = { kind: "sub", ns: "y", v: -2 };
    static struct ItemsDoc
    {
        @SdlChild() Item[] items;
    }
    ItemsDoc doc;
    doc.items = [itemA, itemB];

    enum expected = `x:tool 1` ~ "\n" ~ `y:sub -2` ~ "\n";
    const rendered = toSDL(doc);
    assert(rendered.hasValue, rendered.error.toString);
    assert(rendered.value[] == expected);

    // Node-rooted decode fills the identity fields from the occurrence, and
    // the round trip closes on one element at a time.
    auto parsed = parseSdlDocument!sdlFull(expected, "dyn.sdl");
    assert(parsed.hasValue);
    size_t index;
    foreach (child; parsed.document.root.byChild)
    {
        auto item = fromSDL!(Item)(child);
        assert(item.hasValue, item.error.toString);
        assert(item.value.v == (index == 0 ? 1 : -2));
        assert(item.value.kind == (index == 0 ? "tool" : "sub"));
        assert(item.value.ns == (index == 0 ? "x" : "y"));
        // A dynamically named tag is never a root value: the rewrite goes
        // through the same wrapper the golden uses.
        ItemsDoc wrapper;
        wrapper.items = [item.value];
        auto rewritten = toSDL(wrapper);
        assert(rewritten.hasValue && rewritten.value[] ==
            (index == 0 ? "x:tool 1\n" : "y:sub -2\n"));
        index++;
    }
    assert(index == 2);
}

@("wired.sdl.codec.writeSDL.writerTemplates")
@system unittest
{
    import std.array : appender;

    static struct FullDocT
    {
        @SdlChild() Full config;
    }
    FullDocT doc;
    doc.config.name = "w";
    doc.config.bounds = [1, 2];
    doc.config.verbose = true;

    SmallBuffer!(char, 256) viaSmallBuffer;
    assert(!writeSDL(doc, viaSmallBuffer).hasError);

    auto viaAppender = appender!string;
    assert(!writeSDL(doc, viaAppender).hasError);

    assert(viaSmallBuffer[] == viaAppender[]);

    // Empty sequences emit no occurrence; the zero-init dynamic identity
    // fields fall back to the declared `config` name; the declared singular
    // `dep` child is emitted with its default attribute.
    enum expectedFull = `config "w" 1 2 verbose=true {` ~ "\n"
        ~ `    dep id=""` ~ "\n"
        ~ "}" ~ "\n";
    assert(viaSmallBuffer[] == expectedFull, viaSmallBuffer[].idup);
}

// Deterministic AA emission across hash randomization: identical bytes for
// repeated encodes of the same value in-process.
@("wired.sdl.codec.writeSDL.aaDeterministic")
@system unittest
{
    static struct AaHolder
    {
        @SdlChild() Dep[string] deps;
    }
    AaHolder h;
    h.deps["zeta"] = Dep("3");
    h.deps["alpha"] = Dep("1");
    h.deps["mid"] = Dep("2");

    const first = toSDL(h);
    assert(first.hasValue, first.error.toString);
    foreach (_; 0 .. 8)
    {
        const again = toSDL(h);
        assert(again.hasValue && again.value[] == first.value[]);
    }
    // Canonical lexicographic key order governs entries.
    enum expected =
        `alpha id="1"` ~ "\n"
        ~ `mid id="2"` ~ "\n"
        ~ `zeta id="3"` ~ "\n";
    assert(first.value[] == expected);
}

@("wired.sdl.codec.writeSDL.scalarKinds")
@system unittest
{
    Scalars s;
    s.flagB = true;
    s.narrow = 'q';
    s.wide = '€';
    s.smallInt = -7;
    s.bigInt = long.max;
    s.f32 = -0.0f;
    s.f64 = 0.25;
    s.dec = 0.125L;
    s.label = "e\nsc";

    enum expected =
        `s true 'q' '€' -7 9223372036854775807L -0F 0.25D 0.125BD "e\nsc"`
        ~ "\n";

    static struct ScalarsDoc
    {
        @SdlChild() Scalars s;
    }

    ScalarsDoc sd = ScalarsDoc(s);
    const out_ = toSDL(sd);
    assert(out_.hasValue, out_.error.toString);
    assert(out_.value[] == expected, out_.value[].idup);

    // Round-trip retains every payload exactly.
    auto parsed = parseSdlDocument!sdlFull(out_.value[], "rt.sdl");
    assert(parsed.hasValue);
    const back = fromSDL!(Scalars)(parsed.document.root.byChild.front);
    assert(back.hasValue, back.error.toString);
    assert(back.value.smallInt == s.smallInt && back.value.bigInt == s.bigInt);
    assert(back.value.f32 is s.f32 && back.value.f64 is s.f64
        && back.value.dec is s.dec);
    assert(back.value.label == s.label);
    assert(back.value.narrow == s.narrow && back.value.wide == s.wide);
}

@("wired.sdl.codec.writeSDL.encodeErrorsAndPaths")
@system unittest
{
    static struct NonFinite
    {
        @SdlTagValue(0) double bad;
        @SdlChild() Dep inner;
    }

    NonFinite nf;
    nf.bad = double.nan;
    nf.inner.id = "x";
    const nanResult = toSDL(nf);
    assert(nanResult.hasError
        && nanResult.error.code == SdlErrorCode.valueOutOfRange);
    assert(nanResult.error.rolePath[].canFind("<value[0]>"));

    static string encBoom(int)
    {
        throw new Exception("converter refused to encode");
    }

    static struct Throwing
    {
        // WireConvert!(toWire, fromWire): the encode direction refuses.
        @WireConvert!(encBoom, v => to!int(v))
        @SdlAttribute() int port;
    }
    Throwing t;
    t.port = 8080;
    static struct ThrowingDoc
    {
        @SdlChild() Throwing t;
    }
    ThrowingDoc td = ThrowingDoc(t);
    const convResult = toSDL(td);
    assert(convResult.hasError
        && convResult.error.code == SdlErrorCode.conversionFailed);
    assert(convResult.error.rolePath[] == ".t[0]@port");
}

// Typed value law (SPEC §10 law 3): fromSDL(writeSDL(v)) == v over generated
// bounded values. `isWireRoundTrippable!(Sdl, T)` does not exist in code yet;
// this test instantiates the SDL predicate defined above instead.
@("wired.sdl.codec.roundTripLaw.generated")
@system unittest
{
    uint rng = 0x5EED_C0DE;
    foreach (_; 0 .. 200)
    {
        rng = rng * 1_664_525 + 1_013_904_223;

        Scalars s;
        s.flagB = rng % 2 == 0;
        s.narrow = cast(char) ('a' + rng % 26);
        s.wide = 'α' + rng % 10;
        s.smallInt = cast(int) rng;
        s.bigInt = cast(long) rng << 8 ^ rng;
        switch (rng % 6)
        {
        case 0: s.f32 = 0.0f; break;
        case 1: s.f32 = -0.0f; break;
        case 2: s.f32 = 0.5f; break;
        case 3: s.f32 = -1.25f; break;
        case 4: s.f32 = float.max; break;
        default: s.f32 = cast(float) (rng % 97) / 4; break;
        }
        s.f64 = (rng % 2 ? 1.0 : -1.0) * (rng % 1000) / 8.0;
        s.dec = (rng % 2 ? 1.0L : -1.0L) * (rng % 500) / 32.0L;
        s.label = ["plain", "with \"quote\"", "line\nbreak"][rng % 3];

        // A positional-only aggregate is not a root value: the law drives
        // the round trip through the same document wrapper as the golden.
        static struct ScalarsDoc
        {
            @SdlChild() Scalars s;
        }
        ScalarsDoc doc = ScalarsDoc(s);
        const encoded = toSDL(doc);
        assert(encoded.hasValue, encoded.error.toString);
        auto parsed = parseSdlDocument!sdlFull(encoded.value[], "law.sdl");
        assert(parsed.hasValue, parsed.error.toString);
        const decoded = fromSDL!(Scalars)(parsed.document.root.byChild.front);
        assert(decoded.hasValue, decoded.error.toString);
        const d = decoded.value;

        assert(d.flagB == s.flagB);
        assert(d.narrow == s.narrow && d.wide == s.wide);
        assert(d.smallInt == s.smallInt && d.bigInt == s.bigInt);
        assert(d.f32 is s.f32 && d.f64 is s.f64 && d.dec is s.dec);
        assert(d.label == s.label);

        // LAW 2 spot check on generated input.
        ScalarsDoc decodedDoc = ScalarsDoc(d);
        const rewritten = toSDL(decodedDoc);
        assert(rewritten.hasValue && rewritten.value[] == encoded.value[]);
    }
}
