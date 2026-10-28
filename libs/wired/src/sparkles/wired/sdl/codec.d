/**
Typed SDL decode over the shared wired schema (SPEC §6) plus typed canonical
emission (SPEC §9) and the unknown-member policies (SPEC §8).

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

Unknown members follow the aggregate's three-way policy (SPEC §8). The default
ignores them. `@WireStrict!Sdl` forbids: the first unmatched occurrence —
scanned in canonical grammar order (values by position, then attributes, then
children) — is an `unknownMember` decode error at that occurrence's span with
its composed role path. Supplying an error output range accumulates unknown
occurrences and independent field failures through the shared sink protocol.
`@SdlExtra` preserves: every unmatched occurrence is captured into the
aggregate's `SdlExtras` (borrowed) or `OwnedSdlExtras` (owned) field with its
channel, channel ordinal, qualified name, payload, and source span, and encode
splices extras back into their original channels at those ordinals.

Every failure carries `stage`, a stable code, the offending token/tag
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
    getUDAs,
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

import sparkles.base.text.errors : valueOf;
import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import std.experimental.allocator.mallocator : Mallocator;
import sparkles.base.text.case_style : CaseStyle;
import sparkles.wired.policy : ConvertedWire, Repr, WireInvalid, WireTarget, convertOf,
    hasConvert, isWireText, resolveCaseStyle, resolveRepr,
    wireCheckFailures, wireDefault, wireFailureMessage, wireNames;
import sparkles.wired.schema : NodeKind, ScalarKind;
public import sparkles.wired.schema : isWireRoundTrippable;
public import sparkles.wired.presence : Decoded, WireFieldSet;
import sparkles.wired.presence : WireValue;
import sparkles.wired.walk : FailFast, WireErrors, WireWalk;
import std.range.primitives : put;
import sparkles.wired.sdl.config : SdlParserConfig, sdlFull;
import sparkles.wired.sdl.document : OwnedSdlExtras, SdlDocument,
    SdlExtraChannel, SdlExtraMember, SdlExtras, SdlNode, SdlQualifiedName,
    SdlScalar, SdlScalarKind, SdlOwnedExtraAttribute, SdlOwnedExtraMember,
    SdlOwnedExtraNode, poolName, poolScalar;
import sparkles.wired.policy : MatchStrategy, WireSkip;
import sparkles.wired.sdl.document : SdlAttributeView, SdlSpan;
import sparkles.wired.sdl.error : resolvePositions, SdlError, SdlErrorCode,
    SdlErrorStage, SdlExpected, sdlErr, sdlOk;
import sparkles.wired.sdl.schema_annotations : SdlFieldRole,
    hasBorrowedSdlExtras;
import sparkles.wired.sdl.reader : parseSdlDocument;
import sparkles.wired.sdl.writer : SdlString, writeSdlDocument;
import sparkles.wired.sdl.schema_annotations : Sdl, SdlAttribute, SdlChild,
    SdlChildShape, SdlExtra, SdlExtraAttr, SdlRoleKind, SdlTagNamespace,
    SdlTagName, SdlTagValue, sdlAggregateRoles;

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

private template sdlLeafConverter(alias Conv)
{
    static if (__traits(hasMember, Conv, "ElementConverter"))
        alias sdlLeafConverter = Conv.ElementConverter;
    else
        alias sdlLeafConverter = Conv;
}

private DRes!T dFail(T)(ref SdlError failure, SdlError e)
{
    failure = e;
    return DRes!T(true);
}

/// The SDL role path and the D value path shared across one walk (SPEC §7).
private struct WalkPath
{
    UniqueBuffer!(char, 96) text;
    UniqueBuffer!(char, 96) value;
}

private void popSegment(ref WalkPath p, size_t mark) @safe pure
{
    () @trusted { p.text.length = mark; }();
}

/// Appends a D value-path segment; returns the mark that `popValue` restores.
private size_t pushValue(ref WalkPath p, scope const(char)[] segment) @safe pure
{
    const mark = p.value.length;
    p.value ~= segment;
    return mark;
}

private void popValue(ref WalkPath p, size_t mark) @safe pure
{
    () @trusted { p.value.length = mark; }();
}

/// Attaches both composed paths to a freshly built error.
private SdlError attachPath(ref WalkPath path, SdlError e) @safe pure
{
    () @trusted {
        e.rolePath ~= path.text[];
        e.valuePath ~= path.value[];
    }();
    return e;
}

private SdlError baseError(SdlErrorCode code, SdlSpan span,
    scope const(char)[] reason) @safe pure
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
private SdlSpan endSpan(scope const ref SdlNode node) @safe pure
{
    const span = node.span;
    return span.isValid ? SdlSpan.at(span.endOffset) : SdlSpan.init;
}

private string roleSegment(scope const SdlFieldRole role) @safe pure
{
    final switch (role.role)
    {
    case SdlRoleKind.child:
        // A singular child names its one occurrence; a check on a sequence or
        // map field judges the whole field, not its first occurrence.
        const single = role.childShape == SdlChildShape.scalarSingle
            || role.childShape == SdlChildShape.aggregateSingle;
        return "." ~ qualifiedKey(role.namespace_, role.localName) ~ (single ? "[0]" : "");
    case SdlRoleKind.attribute: return "@" ~ qualifiedKey(role.namespace_, role.localName);
    case SdlRoleKind.tagValue: return "<value[" ~ role.positionalIndex.to!string ~ "]>";
    case SdlRoleKind.tagName: return "<name>";
    case SdlRoleKind.tagNamespace: return "<namespace>";
    case SdlRoleKind.extra: return "<extras>";
    }
}

private SdlSpan roleSpan(scope const ref SdlNode node,
    scope const SdlFieldRole role) @safe pure
{
    if (role.role == SdlRoleKind.child)
        foreach (child; node.byChild)
            if (roleMatches(role, child.qualifiedName))
                return child.span;
    if (role.role == SdlRoleKind.attribute)
        foreach (attribute; node.byAttribute)
            if (roleMatches(role, attribute.qualifiedName))
                return attribute.value.span;
    if (role.role == SdlRoleKind.tagValue)
    {
        bool found;
        const scalar = valueAt(node, role.positionalIndex, found);
        if (found)
            return scalar.span;
    }
    return endSpan(node);
}

private bool isNullScalar(scope const ref SdlScalar s) @safe pure
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
                if (s.integer < 0 || cast(ulong) s.integer > U.max)
                    return dFail!T(failure, typedError!U(
                        SdlErrorCode.numberOutOfRange, s.span,
                        "integer is outside the unsigned target range"));
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
        {
            // The narrow trust wraps `some`, not the return: putting the
            // `return` inside the lambda leaves it returning from the lambda
            // and this function falling off its end.
            auto wrapped = () @trusted { return some(r.value); }();
            return DRes!T(false, wrapped);
        }
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
        alias Wire = ConvertedWire!(Conv, Field);

        auto raw = decodeScalar!(Wire, enumStyle, enumRepr)(s, failure);
        if (raw.failed)
            return DRes!(Field)(true);

        try
        {
            auto converted = Conv.from(raw.value);
            static if (__traits(hasMember, typeof(converted), "hasError"))
            {
                if (converted.hasError)
                    return dFail!Field(failure, attachPath(path, baseError(
                        SdlErrorCode.conversionFailed, s.span,
                        wireFailureMessage(converted.error))));
                return dOk(cast(Field) converted.value);
            }
            else
                return dOk(cast(Field) converted);
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
            () @trusted {
                failure.rolePath ~= path.text[];
                failure.valuePath ~= path.value[];
            }();
        return r;
    }
}

/// Trial-decodes SumType variants against one scalar under `strat`.
private DRes!ST decodeSumTypeScalar(ST, MatchStrategy strat)(
    scope const ref SdlScalar s, ref WalkPath path, ref SdlError failure)
if (isSumType!ST)
{
    alias Variants = TemplateArgsOf!ST;
    size_t successes;
    ST chosen;
    bool haveChosen;
    SdlError[] reasons;

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
        else
        {
            reasons ~= attachPath(path, variantFailure);
        }
    }}

    static if (strat == MatchStrategy.first)
    {
        if (successes == 0)
        {
            auto error = attachPath(path, baseError(SdlErrorCode.conversionFailed,
                s.span, "no SumType variant decodes this value"));
            error.variants = reasons;
            return dFail!ST(failure, error);
        }
        // Narrow trust: SumType declares a `@system opAssign`, so moving the
        // freshly decoded `chosen` into the result is `@system` by type only.
        return (() @trusted => dOk(chosen))();
    }
    else
    {
        if (successes == 0)
        {
            auto error = attachPath(path, baseError(SdlErrorCode.conversionFailed,
                s.span, "no SumType variant decodes this value"));
            error.variants = reasons;
            return dFail!ST(failure, error);
        }
        if (successes > 1)
            return dFail!ST(failure, attachPath(path, baseError(
                SdlErrorCode.duplicateRole, s.span,
                "multiple SumType variants decode this value")));
        // Narrow trust: as for the `first` strategy above.
        return (() @trusted => dOk(chosen))();
    }
}

/** One singular scalar-bearing channel slot: absence, SDL null, unions,
converters, and optionality in shared-policy order. */
private auto declaredDefault(Parent, size_t i)() => wireDefault!(Sdl, Parent, i)();

private bool decodeSingular(alias Parent, size_t i, V, alias Conv = void)(
    bool present, scope const ref SdlScalar s, SdlSpan absentSpan,
    scope const(char)[] missingReason, ref WalkPath path,
    ref SdlError failure, ref V out_)
{
    alias policies = WireWalk!(Sdl, Parent).childPolicies!0;

    // Absence: optional/null-aware targets take their empty value; a
    // required field is a missingRole at the containing tag's terminator.
    if (!present)
    {
        static if (isNullAwareType!(V))
            assignField(out_, declaredDefault!(Parent, i));
        else static if (policies[i].optional)
            assignField(out_, declaredDefault!(Parent, i));
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
                    assignField(out_, declaredDefault!(Parent, i));
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
    else static if (isSumType!(V) && is(Conv == void))
    {
        auto r = decodeSumTypeScalar!(V, policies[i].match)(s, path, failure);
        if (r.failed)
        {
            static if (policies[i].optional
                && policies[i].onInvalid == WireInvalid.useDefault)
            {
                failure = SdlError.init;
                assignField(out_, declaredDefault!(Parent, i));
                return false;
            }
            return true;
        }
        assignField(out_, r.value);
        return false;
    }
    else static if (is(V == enum) && is(Conv == void))
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
                assignField(out_, declaredDefault!(Parent, i));
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
                assignField(out_, declaredDefault!(Parent, i));
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

private bool roleMatches(scope const SdlFieldRole role,
    scope const SdlQualifiedName name) @safe pure nothrow @nogc
{
    debug sdlNameComparisons++;
    if (name.namespace_ == role.namespace_ && name.localName == role.localName)
        return true;
    foreach (alias_; role.aliases)
        if (alias_ == name)
            return true;
    return false;
}

/// Narrow trust: copies one borrowed scalar (its payload slices stay owned
/// by the document pool; callers treat the copy as equally short-lived).
private SdlScalar copyBorrowedScalar(scope const ref SdlScalar s)
    @safe pure nothrow @nogc
    => (() @trusted { const ps = &s; return *ps; })();

/// ditto — an attribute occurrence's qualified name.
private SdlQualifiedName copyQualifiedName(
    scope const SdlAttributeView a) @safe pure nothrow @nogc
    => (() @trusted { const pa = &a; return (*pa).qualifiedName(); })();

/// ditto — a child view's qualified name.
private SdlQualifiedName copyQualifiedName(scope const SdlNode n)
    @safe pure nothrow @nogc
    => (() @trusted { const pn = &n; return (*pn).qualifiedName; })();

/// ditto — a child view itself.
private SdlNode copyBorrowedNode(scope const SdlNode n)
    @safe pure nothrow @nogc
    => (() @trusted { const pn = &n; return *pn; })();

private SdlScalar firstValueOf(scope const ref SdlNode n) @safe pure
{
    foreach (v; n.byValue)
        return copyBorrowedScalar(v);
    assert(false, "scalar channel requires positional value 0");
}


private void assignField(T)(ref T slot, T value)
{
    import core.lifetime : move;

    // Moving into the slot blits instead of calling `opAssign`, which SumType
    // (and any aggregate holding one) declares `@system`.
    static if (__traits(compiles, move(value, slot)))
        move(value, slot);
    else
        slot = value;
}

// ── Aggregate walk ───────────────────────────────────────────────────────────

private SdlScalar valueAt(scope const ref SdlNode node, size_t index,
    ref bool found) @safe pure
{
    found = index < node.valueCount;
    if (!found)
        return SdlScalar.init;
    const value = node.valueAt(index);
    return copyBorrowedScalar(value);
}

/// Collection-element decode: converters/enums/unions without the singular
/// absence machinery (`useDefault` fallbacks apply only to singular fields).
private DRes!V decodeElement(alias Parent, size_t i, V, alias Conv = void)(
    SdlScalar s, ref WalkPath path, ref SdlError failure)
{
    alias policies = WireWalk!(Sdl, Parent).childPolicies!0;
    static if (!is(Conv == void))
        return decodeLeaf!(V, Conv)(s, path, failure);
    else static if (isSumType!(V))
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
        return decodeLeaf!(V, Conv)(s, path, failure);
}

// ── Unknown-member policy (SPEC §8) ──────────────────────────────────────────

/// Whether positional slot `pos` is consumed by declared tag-value role `r`.
private bool slotConsumesValue(scope const SdlFieldRole r, size_t pos)
    @safe pure nothrow @nogc
{
    if (r.role != SdlRoleKind.tagValue)
        return false;
    if (r.dynamicValueSuffix)
        return pos >= r.positionalIndex;
    return pos >= r.positionalIndex
        && pos < r.positionalIndex + (r.staticCount ? r.staticCount : 1);
}

// ── Linear channel dispatch (SDP5) ───────────────────────────────────────────

/// Name comparisons `roleMatches` made, counted in debug builds: the SDP5
/// oracle that typed decode visits each child and attribute a bounded number
/// of times.
debug package size_t sdlNameComparisons;

/// The local names, aliases included, that `U`'s non-map `kind` fields claim.
private enum string[] claimLocals(U, SdlRoleKind kind) = () {
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    string[] locals;
    void add(string local)
    {
        foreach (existing; locals)
            if (existing == local)
                return;
        locals ~= local;
    }
    foreach (role; roles.roles)
        if (role.role == kind && role.childShape != SdlChildShape.map)
        {
            add(role.localName);
            foreach (alias_; role.aliases)
                add(alias_.localName.idup);
        }
    return locals;
}();

/// Whether `role` claims local name `local` (its own or an alias's).
private bool claimsLocal(in SdlFieldRole role, string local) @safe pure nothrow
{
    if (role.localName == local)
        return true;
    foreach (alias_; role.aliases)
        if (alias_.localName == local)
            return true;
    return false;
}

/** The field of `U` whose `kind` channel claims `name`, or `size_t.max`.

Dispatch is a compile-time `switch` over the claimed local names, then a full
comparison against only the fields that claim that local name, so the cost
does not grow with the number of fields. */
package size_t claimantOf(U, SdlRoleKind kind)(scope const SdlQualifiedName name)
    @safe pure nothrow @nogc
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    switch (name.localName)
    {
        static foreach (local; claimLocals!(U, kind))
        {
        case local:
            static foreach (j; 0 .. roles.roles.length)
                static if (roles.roles[j].role == kind
                    && roles.roles[j].childShape != SdlChildShape.map
                    && claimsLocal(roles.roles[j], local))
                    if (roleMatches(roles.roles[j], name))
                        return j;
            return size_t.max;
        }
        default:
            return size_t.max;
    }
}

/// Whether `local` is the local name of a child field of `U` other than
/// field `field` — the names a map field leaves to them.
package bool isOtherChildLocal(U, size_t field)(scope const(char)[] local)
    @safe pure nothrow @nogc
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    enum string[] others = () {
        string[] r;
        foreach (j, role; roles.roles)
            if (role.role == SdlRoleKind.child && j != field)
                r ~= role.localName;
        return r;
    }();
    switch (local)
    {
        static foreach (name; others)
        {
        case name:
            return true;
        }
        default:
            return false;
    }
}

/// Whether a map-shaped child field of `U` takes an unclaimed child `name`:
/// its namespace, and a local name no other child field holds.
private bool mapClaims(U)(scope const SdlQualifiedName name) @safe pure nothrow @nogc
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    static foreach (j; 0 .. roles.roles.length)
        static if (roles.roles[j].role == SdlRoleKind.child
            && roles.roles[j].childShape == SdlChildShape.map)
            if (name.namespace_ == roles.roles[j].namespace_
                && !isOtherChildLocal!(U, j)(name.localName))
                return true;
    return false;
}

/// Whether positional occurrence `pos` is consumed by a declared slot of `U`.
private bool valueConsumed(U)(size_t pos) @safe pure nothrow @nogc
{
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    static foreach (j; 0 .. roles.roles.length)
        static if (roles.roles[j].role == SdlRoleKind.tagValue)
            if (slotConsumesValue(roles.roles[j], pos))
                return true;
    return false;
}

/** One node's children and attributes, grouped by the field of `U` that
claims each, in source order — built in one pass over each channel (SDP5).

`childOwner` and `attributeOwner` give each occurrence's claimant, or
`size_t.max`; field `f`'s claims are `children[childStart[f] ..
childStart[f + 1]]` (cell indexes), and likewise for attributes. */
private struct ClaimIndex(U)
{
    enum fieldCount = sdlAggregateRoles!(U).sdlFieldRoles.roles.length;
    UniqueBuffer!(size_t, 16) childOwner, attributeOwner;
    UniqueBuffer!(size_t, 16) children, attributes;
    size_t[fieldCount + 1] childStart, attributeStart;

    /// Field `f`'s claimed children, as views, into `matches`.
    size_t childrenOf(size_t f, scope const ref SdlNode node,
        ref UniqueBuffer!(SdlNode, 4) matches) const @safe pure
    {
        matches.clear();
        foreach (cell; children[childStart[f] .. childStart[f + 1]])
            () @trusted { matches ~= SdlNode(node.core, cell); }();
        return matches.length;
    }

    /// Field `f`'s claimed attributes, as views, into `matches`.
    size_t attributesOf(size_t f, scope const ref SdlNode node,
        ref UniqueBuffer!(SdlAttributeView, 4) matches) const @safe pure
    {
        matches.clear();
        foreach (cell; attributes[attributeStart[f] .. attributeStart[f + 1]])
            () @trusted { matches ~= SdlAttributeView(node.core, cell); }();
        return matches.length;
    }
}

private void buildClaims(U)(scope const ref SdlNode node, ref ClaimIndex!U claims)
    @safe pure
{
    enum none = size_t.max;
    size_t[ClaimIndex!U.fieldCount] childCounts, attributeCounts;
    foreach (child; node.byChild)
    {
        const f = claimantOf!(U, SdlRoleKind.child)(child.qualifiedName);
        claims.childOwner ~= f;
        if (f != none)
            childCounts[f]++;
    }
    foreach (attribute; node.byAttribute)
    {
        const f = claimantOf!(U, SdlRoleKind.attribute)(attribute.qualifiedName);
        claims.attributeOwner ~= f;
        if (f != none)
            attributeCounts[f]++;
    }
    foreach (f; 0 .. ClaimIndex!U.fieldCount)
    {
        claims.childStart[f + 1] = claims.childStart[f] + childCounts[f];
        claims.attributeStart[f + 1] = claims.attributeStart[f] + attributeCounts[f];
    }
    claims.children.length = claims.childStart[$ - 1];
    claims.attributes.length = claims.attributeStart[$ - 1];
    size_t[ClaimIndex!U.fieldCount] childNext, attributeNext;
    size_t position;
    foreach (child; node.byChild)
    {
        const f = claims.childOwner[position++];
        if (f != none)
            claims.children[claims.childStart[f] + childNext[f]++] = child.cellIndex;
    }
    position = 0;
    foreach (attribute; node.byAttribute)
    {
        const f = claims.attributeOwner[position++];
        if (f != none)
            claims.attributes[claims.attributeStart[f] + attributeNext[f]++] = attribute.cellIndex;
    }
}

/// Whether the child at channel position `position` is claimed: by a named
/// field, or by a map field that takes the unclaimed remainder.
private bool childKnown(U)(scope const ref ClaimIndex!U claims, size_t position,
    scope const SdlQualifiedName name) @safe pure nothrow @nogc
    => claims.childOwner[position] != size_t.max || mapClaims!U(name);

/** Reports unmatched occurrences in value/attribute/child channel order.
The fail-fast specialization stops at the first; an accumulating walk records all. */
private bool reportFirstUnknown(U, Sink)(scope const ref ClaimIndex!U claims,
    scope const ref SdlNode node, ref WalkPath path,
    ref SdlError failure, ref WireErrors!(Sink, SdlError) errors)
{
    bool found;
    size_t index;
    foreach (v; node.byValue)
    {
        if (!valueConsumed!U(index))
        {
            const mark = path.text.length;
            path.text ~= "<value[" ~ index.to!string ~ "]>";
            failure = attachPath(path, baseError(
                SdlErrorCode.unknownMember, v.span(),
                "unknown positional value " ~ index.to!string));
            popSegment(path, mark);
            static if (is(Sink == FailFast))
                return true;
            else
            {
                errors.record(failure);
                found = true;
            }
        }
        index++;
    }

    index = 0;
    foreach (a; node.byAttribute)
    {
        const name = a.qualifiedName;
        if (claims.attributeOwner[index] == size_t.max)
        {
            const mark = path.text.length;
            path.text ~= "@" ~ qualifiedKey(name.namespace_, name.localName);
            failure = attachPath(path, baseError(
                SdlErrorCode.unknownMember, a.span(), "unknown attribute \""
                    ~ qualifiedKey(name.namespace_, name.localName) ~ "\""));
            popSegment(path, mark);
            static if (is(Sink == FailFast))
                return true;
            else
            {
                errors.record(failure);
                found = true;
            }
        }
        index++;
    }

    index = 0;
    foreach (c; node.byChild)
    {
        const name = c.qualifiedName;
        if (!childKnown(claims, index, name))
        {
            const mark = path.text.length;
            path.text ~= "." ~ qualifiedKey(name.namespace_, name.localName)
                ~ "[" ~ sameNameOccurrence(node, index).to!string ~ "]";
            failure = attachPath(path, baseError(
                SdlErrorCode.unknownMember, c.span(), "unknown child tag \""
                    ~ qualifiedKey(name.namespace_, name.localName) ~ "\""));
            popSegment(path, mark);
            static if (is(Sink == FailFast))
                return true;
            else
            {
                errors.record(failure);
                found = true;
            }
        }
        index++;
    }
    return found;
}

/// Occurrence index of the child at channel position `index` among its
/// same-qualified-name siblings (SPEC §7 path convention).
private size_t sameNameOccurrence(scope const ref SdlNode node,
    size_t index) @safe pure
{
    const targetName = childNameAt(node, index);
    size_t seen;
    size_t occurrence;
    foreach (c; node.byChild)
    {
        if (seen++ >= index)
            break;
        if (copyQualifiedName(c) == targetName)
            occurrence++;
    }
    return occurrence;
}

/// The qualified name of the child at channel position `position`.
private SdlQualifiedName childNameAt(scope const ref SdlNode node,
    size_t position) @safe pure
in (position < node.childCount)
{
    foreach (c; node.byChild)
        if (position-- == 0)
            return copyQualifiedName(c);
    assert(false, "wired.sdl: child position out of range");
}

/** Captures every unmatched occurrence of the containing tag into `captured`,
in canonical grammar order: values by position, then attributes, then children
in occurrence order. */
private void captureUnknowns(U)(scope const ref ClaimIndex!U claims,
    scope const ref SdlNode node, ref SdlExtraMember[] captured) @safe pure
{
    size_t index;
    foreach (v; node.byValue)
    {
        if (!valueConsumed!U(index))
            captured ~= SdlExtraMember(SdlExtraChannel.value, index,
                SdlQualifiedName(null, null), copyBorrowedScalar(v),
                SdlNode.init, v.span());
        index++;
    }

    index = 0;
    foreach (a; node.byAttribute)
    {
        if (claims.attributeOwner[index] == size_t.max)
        {
            const attrScalar = a.value;
            captured ~= SdlExtraMember(SdlExtraChannel.attribute, index,
                copyQualifiedName(a), copyBorrowedScalar(attrScalar),
                SdlNode.init, a.span());
        }
        index++;
    }

    index = 0;
    foreach (c; node.byChild)
    {
        if (!childKnown(claims, index, copyQualifiedName(c)))
            captured ~= SdlExtraMember(SdlExtraChannel.child, index,
                copyQualifiedName(c), SdlScalar.invalidScalar(),
                copyBorrowedNode(c), c.span());
        index++;
    }
}

/** Converts borrowed captures into their owned flavor: scalar payloads pool
their bytes and every child subtree materializes recursively. */
private OwnedSdlExtras ownCaptures(scope const SdlExtraMember[] captured)
    @safe pure
{
    OwnedSdlExtras owned;
    foreach (member; captured)
    {
        SdlOwnedExtraMember converted;
        converted.channel = member.channel();
        converted.ordinal = member.ordinal();
        converted.span = member.span();
        final switch (member.channel()) with (SdlExtraChannel)
        {
        case value:
        case attribute:
            converted.name = poolName(member.name(), owned._strings);
            converted.scalar = poolScalar(member.scalar(),
                owned._strings, owned._binaries);
            break;
        case child:
            converted.name = poolName(member.name(), owned._strings);
            converted.node = ownSubtree(member.node(), owned._strings,
                owned._binaries);
            break;
        }
        owned.members ~= converted;
    }
    return owned;
}

private SdlOwnedExtraNode ownSubtree(SdlNode n,
    ref char[][] strings, ref ubyte[][] binaries) @safe pure
{
    SdlOwnedExtraNode tree;
    tree.name = poolName(n.qualifiedName, strings);
    foreach (v; n.byValue)
        tree.values ~= poolScalar(v, strings, binaries);
    foreach (a; n.byAttribute)
        tree.attributes ~= SdlOwnedExtraAttribute(
            poolName(a.qualifiedName, strings), poolScalar(a.value, strings,
                binaries));
    foreach (c; n.byChild)
        tree.children ~= ownSubtree(c, strings, binaries);
    tree.hasBlock = n.hasBlock();
    return tree;
}

/** Decodes aggregate `T` from one SDL node, filling every declared role.

`return scope` (not plain `scope`) because a `@SdlExtra` capture legitimately
stores borrowed arena views into the returned value; callers keep the owning
document alive for such aggregates (SPEC §8).
*/
private DRes!T decodeAggregate(T)(return scope const ref SdlNode node,
    ref WalkPath path, ref SdlError failure) @safe
if (is(T == struct))
{
    WireErrors!(FailFast, SdlError) errors;
    return decodeAggregate!(T, FailFast)(node, path, failure, errors);
}

private DRes!T decodeAggregate(T, Sink)(return scope const ref SdlNode node,
    ref WalkPath path, ref SdlError failure, ref WireErrors!(Sink, SdlError) errors)
if (is(T == struct))
{
    import std.traits : isNested;

    alias U = Unqual!T;
    alias roles = sdlAggregateRoles!(U).sdlFieldRoles;
    alias policies = WireWalk!(Sdl, U).childPolicies!0;
    U result;
    const initialErrors = errors.count;
    // Each child and attribute is dispatched to its field once (SDP5).
    ClaimIndex!U claims;
    buildClaims(node, claims);

    // SPEC §8 forbid policy: the first unmatched occurrence — scanned values
    // by position, then attributes, then children — fails the walk before any
    // field is filled in fail-fast mode. Accumulation records all unknowns
    // before proceeding to declared fields. Strict and preserve are mutually
    // exclusive at compile time.
    static if (roles.strictUnknown)
    {
        if (reportFirstUnknown(claims, node, path, failure, errors))
        {
            static if (is(Sink == FailFast))
                return DRes!(U)(true);
        }
    }

    static assert(roles.roles.length == U.tupleof.length);
    static foreach (i, symbol; U.tupleof)
    {{
        const beforeField = errors.count;
        const fieldPathMark = path.text.length;
        const fieldValueMark = pushValue(path, "." ~ __traits(identifier, symbol));
        scope (exit) popValue(path, fieldValueMark);
        const fieldFailed = () {
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        enum ident = __traits(identifier, symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FieldConv = sdlLeafConverter!(convertOf!(Sdl, symbol, V));
        else
            alias FieldConv = void;

        static if (R.role == SdlRoleKind.child)
        {
            UniqueBuffer!(SdlNode, 4) matches;
            const count = claims.childrenOf(i, node, matches);

            static if (R.childShape == SdlChildShape.scalarSingle
                || R.childShape == SdlChildShape.aggregateSingle)
            {
                if (count > 1)
                {
                    const mark = path.text.length;
                    pushDup(path, qualifiedKey(R.namespace_, R.localName));
                    failure = attachPath(path, baseError(
                        SdlErrorCode.duplicateRole, matches[1].span(),
                        "duplicate singular child \"" ~ R.localName ~ "\""));
                    popSegment(path, mark);
                    return true;
                }

                // Null-aware aggregates absorb absence; scalars go through
                // the shared singular pipeline (absence/null/unions).
                static if (R.childShape == SdlChildShape.scalarSingle)
                {
                    const mark = path.text.length;
                    path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]";
                    scope (exit) popSegment(path, mark);

                    V slot = V.init;
                    if (count == 0)
                    {
                        SdlScalar none_ = SdlScalar(null);
                        if (decodeSingular!(U, i, V, FieldConv)(false, none_,
                                endSpan(node), "missing child \""
                                ~ R.localName ~ "\"", path, failure, slot))
                            return true;
                    }
                    else
                    {
                        if (matches[0].valueCount == 0)
                        {
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(matches[0]),
                                "scalar child requires positional value 0"));
                            return true;
                        }
                        const s0 = firstValueOf(matches[0]);
                        if (decodeSingular!(U, i, V, FieldConv)(true, s0, endSpan(node),
                                null, path, failure, slot))
                            return true;
                    }
                    assignField(result.tupleof[i], slot);
                }
                else static if (isNullAwareType!(V))
                {
                    if (count == 0)
                        assignField(result.tupleof[i], declaredDefault!(U, i));
                    else
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]";
                        auto r = decodeAggregate!(Contained!(V), Sink)(matches[0],
                            path, failure, errors);
                        popSegment(path, mark);
                        if (r.failed)
                            return true;
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
                            path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]";
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(node),
                                "missing child \"" ~ R.localName ~ "\""));
                            popSegment(path, mark);
                            return true;
                        }
                        else
                            assignField(result.tupleof[i], declaredDefault!(U, i));
                    }
                    else
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]";
                        auto r = decodeAggregate!(V, Sink)(matches[0], path, failure, errors);
                        popSegment(path, mark);
                        if (r.failed)
                            return true;
                        assignField(result.tupleof[i], r.value);
                    }
                }
            }
            else static if (R.childShape == SdlChildShape.scalarSequence)
            {
                alias E = ForeachType!V;
                E[] items;
                size_t element;
                foreach (occurrence; 0 .. count)
                {
                    const m = matches[occurrence];
                    const mark = path.text.length;
                    path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "["
                        ~ occurrence.to!string ~ "]";
                    scope (exit) popSegment(path, mark);
                    foreach (value; m.byValue)
                    {
                        const elementMark = pushValue(path,
                            "[" ~ (element++).to!string ~ "]");
                        scope (exit) popValue(path, elementMark);
                        auto r = decodeElement!(U, i, E, FieldConv)(value,
                            path, failure);
                        if (r.failed)
                        {
                            static if (is(Sink == FailFast))
                                return true;
                            else
                            {
                                errors.record(failure);
                                continue;
                            }
                        }
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
                        return true;
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
                    path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "["
                        ~ occurrence.to!string ~ "]";
                    const elementMark = pushValue(path, "[" ~ occurrence.to!string ~ "]");
                    auto r = decodeAggregate!(E, Sink)(matches[occurrence], path,
                        failure, errors);
                    popValue(path, elementMark);
                    popSegment(path, mark);
                    if (r.failed)
                    {
                        static if (is(Sink == FailFast))
                            return true;
                        else
                            continue;
                    }
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

                // The AA consumes every same-namespace sibling whose local name
                // no other child field holds, so its tags may be arbitrarily
                // named; the local-name test is a compile-time switch.
                UniqueBuffer!(SdlNode, 4) aaMatches;
                foreach (child; node.byChild)
                    if (child.qualifiedName.namespace_ == R.namespace_
                        && !isOtherChildLocal!(U, i)(child.qualifiedName.localName))
                        () @trusted { aaMatches ~= child; }();

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
                        return true;
                    if (keyIn(seenKeys, key))
                    {
                        const mark = path.text.length;
                        path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[" ~ rawKey ~ "]";
                        const entryMark = pushValue(path, "[" ~ rawKey ~ "]");
                        failure = attachPath(path, baseError(
                            SdlErrorCode.duplicateRole, m.nameSpan(),
                            "duplicate map key \"" ~ rawKey.idup ~ "\""));
                        popValue(path, entryMark);
                        popSegment(path, mark);
                        return true;
                    }
                    seenKeys ~= key;
                    const mark = path.text.length;
                    path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[" ~ rawKey ~ "]";
                    scope (exit) popSegment(path, mark);
                    const entryMark = pushValue(path, "[" ~ rawKey ~ "]");
                    scope (exit) popValue(path, entryMark);
                    static if (is(M == struct) && !isSomeChar!M
                        && !is(M == enum))
                    {
                        auto r = decodeAggregate!(M, Sink)(m, path, failure, errors);
                        if (r.failed)
                            return true;
                        table[key] = r.value;
                    }
                    else
                    {
                        if (m.valueCount == 0)
                        {
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(m),
                                "scalar map entry requires positional value 0"));
                            return true;
                        }
                        auto r = decodeElement!(U, i, M, FieldConv)(firstValueOf(m),
                            path, failure);
                        if (r.failed)
                            return true;
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
            UniqueBuffer!(SdlAttributeView, 4) attrs;
            const acount = claims.attributesOf(i, node, attrs);

            // NOTE: string is a dynamic array in D but a *scalar* channel
            // value; only genuine array types mean "repeated attribute".
            static if (is(V == string) || !isDynamicArray!(Unqual!V))
            {
                if (acount > 1)
                {
                    const mark = path.text.length;
                    path.text ~= "@" ~ qualifiedKey(R.namespace_, R.localName);
                    failure = attachPath(path, baseError(
                        SdlErrorCode.duplicateRole, attrs[1].value.span(),
                        "duplicate attribute"));
                    popSegment(path, mark);
                    return true;
                }
                const mark = path.text.length;
                path.text ~= "@" ~ qualifiedKey(R.namespace_, R.localName);
                scope (exit) popSegment(path, mark);
                const attrScalar = acount ? attrs[0].value : SdlScalar(null);
                V slot = V.init;
                if (decodeSingular!(U, i, V, FieldConv)(acount == 1, attrScalar,
                        endSpan(node), "missing attribute \"" ~ R.localName
                        ~ "\"", path, failure, slot))
                    return true;
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
                    path.text ~= "@" ~ qualifiedKey(R.namespace_, R.localName);
                    scope (exit) popSegment(path, mark);
                    auto r = decodeElement!(U, i, E, FieldConv)(view.value,
                        path, failure);
                    if (r.failed)
                    {
                        static if (is(Sink == FailFast))
                            return true;
                        else
                        {
                            errors.record(failure);
                            continue;
                        }
                    }
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
                    return true;
                assignField(result.tupleof[i], slot);
            }
            else static if (R.staticCount != 0)
            {
                alias E = typeof(V.init[0]);
                V slot = declaredDefault!(U, i);
                foreach (offset; 0 .. R.staticCount)
                {
                    bool found;
                    const s = valueAt(node, R.positionalIndex + offset, found);
                    const mark = path.text.length;
                    path.text ~= "<value["
                        ~ (R.positionalIndex + offset).to!string ~ "]>";
                    scope (exit) popSegment(path, mark);
                    const elementMark = pushValue(path, "[" ~ offset.to!string ~ "]");
                    scope (exit) popValue(path, elementMark);
                    auto r = decodeElement!(U, i, E, FieldConv)(s, path,
                        failure);
                    if (r.failed || !found)
                    {
                        if (!found)
                            failure = attachPath(path, baseError(
                                SdlErrorCode.missingRole, endSpan(node),
                                "missing positional value "
                                ~ (R.positionalIndex + offset).to!string));
                        static if (is(Sink == FailFast))
                            return true;
                        else
                        {
                            errors.record(failure);
                            continue;
                        }
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
                    const elementMark = pushValue(path, "[" ~ offset.to!string ~ "]");
                    scope (exit) popValue(path, elementMark);
                    auto r = decodeElement!(U, i, E, FieldConv)(s, path,
                        failure);
                    popSegment(path, mark);
                    if (r.failed)
                    {
                        static if (is(Sink == FailFast))
                            return true;
                        else
                        {
                            errors.record(failure);
                            continue;
                        }
                    }
                    items ~= r.value;
                }
                assignField(result.tupleof[i], items);
            }
        }
        else static if (R.role == SdlRoleKind.tagName)
        {
            if (decodeIdentity!V(node.qualifiedName.localName, node.nameSpan(),
                    path, failure, result.tupleof[i]))
                return true;
        }
        else static if (R.role == SdlRoleKind.tagNamespace)
        {
            if (decodeIdentity!V(node.qualifiedName.namespace_,
                    node.nameSpan(), path, failure, result.tupleof[i]))
                return true;
        }
        else static if (R.role == SdlRoleKind.extra)
        {
            // SPEC §8 preserve: capture every unmatched occurrence in
            // canonical grammar order (values by position, then attributes,
            // then children).
            SdlExtraMember[] captured;
            captureUnknowns(claims, node, captured);
            static if (is(V == OwnedSdlExtras))
                assignField(result.tupleof[i], ownCaptures(captured));
            else static if (is(V == SdlExtras))
                assignField(result.tupleof[i], SdlExtras(captured));
            else
                static assert(false, "wired.sdl: unreachable @SdlExtra "
                    ~ "flavor");
        }
        else
            static assert(false, "wired.sdl: unreachable role kind");
        popSegment(path, fieldPathMark);
        const checks = wireCheckFailures!(Sdl, symbol)(result.tupleof[i]);
        foreach (check; checks)
        {
            const checkMark = path.text.length;
            path.text ~= roleSegment(R) ~ check.path;
            failure = attachPath(path, baseError(SdlErrorCode.checkFailed,
                roleSpan(node, R), check.reason));
            popSegment(path, checkMark);
            static if (is(Sink == FailFast))
                return true;
            else
                errors.record(failure);
        }
        return false;
        }();
        if (fieldFailed)
        {
            static if (is(Sink == FailFast))
                return DRes!(U)(true);
            else
            {
                if (errors.count == beforeField)
                    errors.record(failure);
                failure = SdlError.init;
            }
        }
    }}
    // A type-level check judges the whole decoded value. Once a field of this
    // aggregate failed, `result` holds substituted defaults, so checking it
    // would report failures the input never contained.
    static if (!is(Sink == FailFast))
        if (errors.count != initialErrors)
        {
            failure = errors.first;
            return DRes!(U)(true);
        }
    const aggregateChecks = wireCheckFailures!(Sdl, U)(result);
    foreach (check; aggregateChecks)
    {
        const mark = path.text.length;
        path.text ~= check.path;
        failure = attachPath(path, baseError(SdlErrorCode.checkFailed,
            node.span, check.reason));
        popSegment(path, mark);
        static if (is(Sink == FailFast))
            return DRes!(U)(true);
        else
            errors.record(failure);
    }
    static if (!is(Sink == FailFast))
        if (errors.count != initialErrors)
        {
            failure = errors.first;
            return DRes!(U)(true);
        }
    return DRes!(U)(false, result);
}

private void pushDup(ref WalkPath p, scope const(char)[] local) @safe pure
{
    p.text ~= "." ~ local ~ "[1]";
}

/// `ns:local`, or `local` when unnamespaced: the SDL spelling a role path uses.
private string qualifiedKey(scope const(char)[] ns,
    scope const(char)[] local) @safe pure
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

/// A child's emitted qualified name: the declared one, or a dynamic identity
/// borrowed from the value being written.
private struct EncName
{
    const(char)[] namespace_; ///
    const(char)[] localName;  ///
}

/// The name a child value is emitted under: its dynamic tag-name/namespace
/// fields override the declared `ns`/`local`. Empty string identities do not
/// override: the declared name is emitted so a zero-init aggregate keeps its
/// schema identity (canonical stability). The result borrows from `v`, which
/// outlives the synchronous build, so nothing is copied.
private EncName encChildName(T)(return scope const ref T v,
    return scope const(char)[] ns, return scope const(char)[] local)
    => EncName(nonEmptyOr(identityOf!(SdlRoleKind.tagNamespace)(v), ns),
        nonEmptyOr(identityOf!(SdlRoleKind.tagName)(v), local));

/// The `T.tupleof` index of `T`'s field with role `kind`, or -1.
private enum ptrdiff_t identityField(T, SdlRoleKind kind) = ()
{
    foreach (role; sdlAggregateRoles!(T).sdlFieldRoles.roles)
        if (role.role == kind)
            return cast(ptrdiff_t) role.fieldIndex;
    return -1;
}();

/// The spelled dynamic identity of `v` in role `kind`; null when `T` has none.
private const(char)[] identityOf(SdlRoleKind kind, T)(return scope const ref T v)
{
    enum index = identityField!(T, kind);
    static if (index < 0)
        return null;
    else
        return encodeIdentity(v.tupleof[index]);
}

private const(char)[] nonEmptyOr(return scope const(char)[] candidate,
    return scope const(char)[] fallback) @safe pure nothrow @nogc
    => candidate.length ? candidate : fallback;

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

/** Spells a dynamic identity field back out as a tag name or namespace.

The mirror of $(LREF decodeIdentity), and it takes the field's *value* — the
encode side has no text to hand it.
*/
private string encodeIdentity(V)(scope const ref V value)
{
    static if (is(V == string))
        return value;
    else static if (is(V == enum))
    {
        enum names = wireNames!(Sdl, V, resolveCaseStyle!(Sdl, V));
        foreach (i, m; __traits(allMembers, V))
            if (__traits(getMember, V, m) == value)
                return names[i];
        assert(false, "wired.sdl: enum value has no wire name");
    }
    else
        static assert(false, "wired.sdl: unreachable identity type");
}

// ── Public entries ───────────────────────────────────────────────────────────

private WireFieldSet!T suppliedSdlFields(T)(scope SdlNode node) @safe
{
    WireFieldSet!T supplied;
    alias roles = sdlAggregateRoles!T.sdlFieldRoles;
    ClaimIndex!T claims;
    buildClaims(node, claims);
    static foreach (i; 0 .. roles.roles.length)
    {{
        enum role = roles.roles[i];
        bool found;
        static if (role.role == SdlRoleKind.child)
        {
            static if (role.childShape == SdlChildShape.map)
            {
                foreach (child; node.byChild)
                    found |= child.qualifiedName.namespace_ == role.namespace_
                        && !isOtherChildLocal!(T, i)(child.qualifiedName.localName);
            }
            else
                found = claims.childStart[i + 1] > claims.childStart[i];
        }
        else static if (role.role == SdlRoleKind.attribute)
            found = claims.attributeStart[i + 1] > claims.attributeStart[i];
        else static if (role.role == SdlRoleKind.tagValue)
            found = node.valueCount > role.positionalIndex;
        else static if (role.role == SdlRoleKind.tagName)
            found = node.qualifiedName.localName.length != 0;
        else static if (role.role == SdlRoleKind.tagNamespace)
            found = node.qualifiedName.namespace_.length != 0;
        else static if (role.role == SdlRoleKind.extra)
        {
            foreach (index; 0 .. node.valueCount)
                found |= !valueConsumed!T(index);
            foreach (owner; claims.attributeOwner[])
                found |= owner == size_t.max;
            size_t position;
            foreach (child; node.byChild)
                found |= !childKnown(claims, position++, child.qualifiedName);
        }
        if (found)
            supplied.include(i);
    }}
    return supplied;
}

private struct SdlSourceSink(Sink)
{
    Sink* target;
    SharedBuffer!(char, 40) sourceName;

    void put(SdlError error)
    {
        import std.range.primitives : put;

        error.sourceName ~= sourceName[];
        put(*target, error);
    }
}

/// Resolves each error's positions against the decoded document's core
/// before handing it to the caller's sink.
private struct SdlLocatingSink(Sink)
{
    import sparkles.wired.sdl.document : SdlCore;

    Sink* target;
    const(SdlCore)* core;

    void put(SdlError error)
    {
        import std.range.primitives : put;

        resolvePositions(error, core);
        put(*target, error);
    }
}

// One root decode, fail-fast or accumulating. The result borrows from `node`
// exactly as far as `T` does; the public overloads below decide that.
private SdlExpected!T decodeRootNode(T, Sink)(return scope SdlNode node,
    ref WireErrors!(Sink, SdlError) errors)
{
    static if (is(T == Decoded!Value, Value))
    {
        WalkPath path;
        SdlError failure;
        auto r = decodeAggregate!(Value, Sink)(node, path, failure, errors);
        if (r.failed)
        {
            resolvePositions(failure, node.core);
            return sdlErr!T(failure);
        }
        return sdlOk(T(r.value, suppliedSdlFields!Value(node)));
    }
    else
    {
        WalkPath path;
        SdlError failure;
        auto r = decodeAggregate!(T, Sink)(node, path, failure, errors);
        if (r.failed)
        {
            resolvePositions(failure, node.core);
            return sdlErr!T(failure);
        }
        return sdlOk(r.value);
    }
}

/** Decodes aggregate `T` rooted at one already-parsed SDL node (SPEC §11).

The node is the containing tag for `T`: its channels are the aggregate's
declared roles. Every decoded string/binary payload of declared fields is
copied, but a `@SdlExtra` field of borrowed $(LREF SdlExtras) flavor keeps
arena views — the document owning `node` must outlive the returned value for
such aggregates (`-preview=dip1000` tracks the accessor chain). Owned
$(LREF OwnedSdlExtras) captures carry no such obligation.

Root aggregates may not declare $(LREF SdlTagName) or $(LREF SdlTagNamespace)
fields (SPEC §5); the S5 projection rejects those shapes at compile time.
*/
SdlExpected!T fromSDL(T)(return scope SdlNode node) @safe
if (is(T == struct) && hasBorrowedSdlExtras!(Unqual!T))
{
    WireErrors!(FailFast, SdlError) errors;
    return decodeRootNode!(T, FailFast)(node, errors);
}

/// ditto — an owned result has no lifetime dependency on the input node.
SdlExpected!T fromSDL(T)(scope SdlNode node) @safe
if (is(T == struct) && !hasBorrowedSdlExtras!(Unqual!T))
{
    WireErrors!(FailFast, SdlError) errors;
    auto result = decodeRootNode!(T, FailFast)(node, errors);
    // Narrow trust: release the borrow dip1000 attaches to `result`. The
    // template constraint proves `T` has no borrowed-extras field, the only
    // channel that keeps arena views; the walker copies every declared text
    // and binary payload.
    return (() @trusted => result)();
}

/** ditto — decodes with an error output range. Independent fields are visited
after a sibling fails, each failure is put into `sink`, and the result carries
the first. */
SdlExpected!T fromSDL(T, Sink)(return scope SdlNode node, ref Sink sink)
if (is(T == struct) && hasBorrowedSdlExtras!(Unqual!T))
{
    SdlLocatingSink!Sink locating;
    WireErrors!(SdlLocatingSink!Sink, SdlError) errors;
    // Narrow trust: `errors` and `locating` are local to this call, so the
    // pointers to the caller's sink and to `locating` cannot outlive it.
    locating = SdlLocatingSink!Sink((() @trusted => &sink)(), node.core);
    errors.sink = (() @trusted => &locating)();
    return decodeRootNode!(T, SdlLocatingSink!Sink)(node, errors);
}

/// ditto
SdlExpected!T fromSDL(T, Sink)(scope SdlNode node, ref Sink sink)
if (is(T == struct) && !hasBorrowedSdlExtras!(Unqual!T))
{
    SdlLocatingSink!Sink locating;
    WireErrors!(SdlLocatingSink!Sink, SdlError) errors;
    // Narrow trust: `errors` and `locating` are local to this call, so the
    // pointers to the caller's sink and to `locating` cannot outlive it.
    locating = SdlLocatingSink!Sink((() @trusted => &sink)(), node.core);
    errors.sink = (() @trusted => &locating)();
    auto result = decodeRootNode!(T, SdlLocatingSink!Sink)(node, errors);
    // Narrow trust: as for the fail-fast owned overload.
    return (() @trusted => result)();
}

/// ditto — parses before accumulating typed failures.
SdlExpected!T fromSDL(T, Sink, alias config = sdlParserConfigFor!T)(
    scope const(char)[] text, ref Sink sink, scope const(char)[] sourceName = null)
if (is(T == struct))
{
    static assert(!hasBorrowedSdlExtras!(Unqual!T),
        "wired.sdl: borrowed extras require a kept-alive SdlNode");
    static assert(sdlAggregateRoles!(Unqual!(WireValue!T), true).sdlFieldRoles.roles.length
        == WireWalk!(Sdl, Unqual!(WireValue!T)).node!0.edgeCount);
    auto parsed = parseSdlDocument!config(text, sourceName);
    if (parsed.hasError)
    {
        put(sink, parsed.error);
        return sdlErr!T(parsed.error);
    }
    // Narrow trust: as for the node overloads, `named` is local to this call.
    auto named = SdlSourceSink!Sink((() @trusted => &sink)());
    named.sourceName ~= sourceName;
    auto result = fromSDL!T(parsed.document.root, named);
    if (result.hasError)
    {
        auto failure = result.error;
        failure.sourceName ~= sourceName;
        return sdlErr!T(failure);
    }
    return result;
}

/// ditto — parses `text` under `config` first; lex/parse failures propagate
/// unchanged with their own stages, codes, spans, and owned source name.
///
/// Borrowed extras cannot survive this overload's temporary document, so an
/// aggregate declaring an `@SdlExtra` field of $(LREF SdlExtras) flavor is a
/// compile-time error here: decode from a kept-alive $(LREF SdlNode), or
/// switch the field to $(LREF OwnedSdlExtras).
SdlExpected!T fromSDL(T, alias config = sdlParserConfigFor!T)(
    scope const(char)[] text, scope const(char)[] sourceName = null) @safe
if (is(T == struct))
{
    static assert(!hasBorrowedSdlExtras!(Unqual!T),
        "wired.sdl: " ~ T.stringof ~ ": a borrowed @SdlExtra (SdlExtras) "
        ~ "field cannot outlive this overload's temporary document; decode "
        ~ "from a kept-alive SdlNode with fromSDL!T(node), or declare the "
        ~ "extras field as OwnedSdlExtras");
    static assert(sdlAggregateRoles!(Unqual!(WireValue!T), true).sdlFieldRoles.roles.length
        == WireWalk!(Sdl, Unqual!(WireValue!T)).node!0.edgeCount);
    auto parsed = parseSdlDocument!config(text, sourceName);
    if (!parsed.hasValue)
        return sdlErr!T(parsed.error);
    auto result = fromSDL!T(parsed.document.root);
    if (result.hasError)
    {
        auto failure = result.error;
        failure.sourceName ~= sourceName;
        return sdlErr!T(failure);
    }
    return result;
}

/// Missing scalar payloads are recoverable, pathed decode errors.
@("wired.sdl.codec.audit.missingScalarChild")
@safe unittest
{
    static struct Doc { int count; }
    const result = fromSDL!Doc("count\n");
    assert(result.hasError && result.error.code == SdlErrorCode.missingRole);
    assert(result.error.rolePath[] == ".count[0]");
}

/// Narrow unsigned targets reject overflow instead of truncating.
@("wired.sdl.codec.audit.unsignedBounds")
@system unittest
{
    static struct Small { ubyte count; }
    foreach (source; ["count 256\n", "count -1\n"])
    {
        const result = fromSDL!Small(source);
        assert(result.hasError && result.error.code == SdlErrorCode.numberOutOfRange);
    }
    static struct Wide { uint count; }
    const encoded = toSDL(Wide(uint.max));
    assert(encoded.hasValue);
    const decoded = fromSDL!Wide(encoded.value[]);
    assert(decoded.hasValue && decoded.value.count == uint.max);
}

/// Absence restores the aggregate's declared field initializer.
@("wired.sdl.codec.audit.declaredDefault")
@safe unittest
{
    static struct Doc { @WireOptional() int count = 7; }
    const absent = fromSDL!Doc("");
    assert(absent.hasValue && absent.value.count == 7);
}

/// The shared predicate rejects unproven inverses and non-document roots.
@("wired.sdl.codec.audit.roundTripPredicate")
@safe pure unittest
{
    static struct Plain { uint count; }
    static struct TooWide { ulong count; }
    static struct Identity { @SdlTagName() string name; }
    static struct Position { @SdlTagValue(0) int value; }
    static struct Lossy
    {
        @WireConvert!(v => v / 2, v => v * 2) int count;
    }
    static assert(isWireRoundTrippable!(Sdl, Plain));
    static assert(!isWireRoundTrippable!(Sdl, TooWide));
    static assert(!isWireRoundTrippable!(Sdl, Identity));
    static assert(!isWireRoundTrippable!(Sdl, Position));
    static assert(!isWireRoundTrippable!(Sdl, Lossy));
}

/// Accumulation visits unknown occurrences and independent malformed fields.
@("wired.sdl.codec.audit.accumulation")
@system unittest
{
    @WireStrict!Sdl
    static struct Item
    {
        @SdlTagValue(0) int value;
        @SdlAttribute() bool flag;
    }
    static struct Doc { Item item; }
    SharedBuffer!(SdlError, 8) errors;
    const result = fromSDL!Doc("item \"bad\" 2 flag=3 x=true y=false\n", errors);
    assert(result.hasError && errors.length == 5);
    assert(result.error.rolePath[] == errors[0].rolePath[]);
    assert(errors[0].rolePath[] == ".item[0]<value[1]>");
    assert(errors[1].rolePath[] == ".item[0]@x");
    assert(errors[2].rolePath[] == ".item[0]@y");
    assert(errors[3].rolePath[] == ".item[0]<value[0]>");
    assert(errors[4].rolePath[] == ".item[0]@flag");

    import sparkles.wired.walk : FixedWireErrors;

    FixedWireErrors!(SdlError, 2) bounded;
    const overflow = fromSDL!Doc("item \"bad\" 2 flag=3 x=true y=false\n", bounded);
    assert(overflow.hasError && bounded.length == 3 && bounded.overflowed);
    assert(bounded[][0].rolePath[] == errors[0].rolePath[]);
    assert(bounded[][1].rolePath[] == errors[1].rolePath[]);
    assert(bounded[][2].code == SdlErrorCode.errorSinkOverflow);
}

/// Aliases are read-many/write-one and defaults govern absence and omission.
@("wired.sdl.codec.sharedAliasesAndDefaults")
@system unittest
{
    import sparkles.wired.policy : WireAlias, WireDefault;

    @WireStrict!Sdl
    static struct Settings
    {
        @SdlAttribute() @WireAlias!Sdl("legacy:port")
        @WireDefault!Sdl(8080) @WireOptional(WireSkip.whenDefault) int port = 80;
        @SdlAttribute() @WireDefault!Sdl(() pure => 3) int retries;
    }
    static struct Doc
    {
        @WireAlias!Sdl("old") Settings settings;
    }
    const decoded = fromSDL!Doc("old legacy:port=9000\n");
    assert(decoded.hasValue);
    assert(decoded.value.settings.port == 9000 && decoded.value.settings.retries == 3);
    const absent = fromSDL!Doc("settings\n");
    assert(absent.hasValue && absent.value.settings.port == 8080);
    const text = toSDL(absent.value);
    assert(text.hasValue && text.value[] == "settings retries=3\n");
    const duplicate = fromSDL!Doc("settings port=1 legacy:port=2\n");
    assert(duplicate.hasError && duplicate.error.code == SdlErrorCode.duplicateRole);
    static struct Collision
    {
        @WireAlias!Sdl("other") int count;
        int other;
    }
    import sparkles.wired.schema : wireSchemaOf;

    static assert(!__traits(compiles, wireSchemaOf!(Sdl, Collision)));
}

/// Shared checks enforce all four protocols, source spans, and encode ordering.
@("wired.sdl.codec.sharedChecks")
@system unittest
{
    import expected : Expected, err, ok;
    import sparkles.wired.policy : WireCheck, WireCheckFailure, isBetween, isOneOf;

    static Expected!(void, string) positive(int value) @safe pure
    {
        if (value > 0)
            return ok!string();
        return err!void("must be positive");
    }
    @WireCheck!(v => v.low < v.high, "low must precede high")
    static struct Settings
    {
        @SdlAttribute() @WireCheck!(isBetween!(1, 9)) int low;
        @SdlAttribute() @WireCheck!(positive) int high;
        @SdlAttribute() @WireCheck!(v => v == "yes" ? "" : "expected yes") string answer;
        @SdlAttribute() @WireCheck!(isOneOf!("a", "b")) string mode;
    }
    static struct Doc { Settings settings; }
    const good = fromSDL!Doc("settings low=2 high=8 answer=\"yes\" mode=\"a\"\n");
    assert(good.hasValue);
    const bad = fromSDL!Doc("settings low=0 high=8 answer=\"yes\" mode=\"a\"\n", "check.sdl");
    assert(bad.hasError && bad.error.code == SdlErrorCode.checkFailed);
    assert(bad.error.rolePath[] == ".settings[0]@low");
    assert(bad.error.sourceName[] == "check.sdl");
    assert(bad.error.span.startOffset == 13);
    Doc invalid = good.value;
    invalid.settings.high = 1;
    const encoded = toSDL(invalid);
    assert(encoded.hasError && encoded.error.code == SdlErrorCode.checkFailed);

    static struct Multiple
    {
        @SdlAttribute() @WireCheck!(v => v > 0
            ? cast(WireCheckFailure[]) []
            : [WireCheckFailure("first", ".one"), WireCheckFailure("second", ".two")]) int count;
    }
    static struct MultiDoc { Multiple item; }
    // Accumulation does not judge a partially decoded aggregate.
    SharedBuffer!(SdlError, 4) partial;
    const malformed = fromSDL!Doc("settings low=\"x\" high=-1 answer=\"yes\" mode=\"a\"\n",
        partial);
    assert(malformed.hasError && partial.length == 2, partial.length.to!string);
    assert(partial[0].code == SdlErrorCode.unexpectedKind);
    assert(partial[1].code == SdlErrorCode.checkFailed
        && partial[1].rolePath[] == ".settings[0]@high");

    SharedBuffer!(SdlError, 4) errors;
    const multi = fromSDL!MultiDoc("item count=0\n", errors);
    assert(multi.hasError && errors.length == 2);
    assert(errors[0].rolePath[] == ".item[0]@count.one");
    assert(errors[1].rolePath[] == ".item[0]@count.two");
}

/// Presence distinguishes missing, explicit default, distinct, and null input.
@("wired.sdl.codec.decodedPresence")
@system unittest
{
    import sparkles.wired.policy : WireAlias, WireDefault;
    import sparkles.wired.schema : wireSchemaOf;

    static struct Settings
    {
        @WireAlias!Sdl("old") @WireDefault!Sdl(7) int count;
        Nullable!string note;
    }
    const absent = fromSDL!(Decoded!Settings)("");
    assert(absent.hasValue && absent.value.value.count == 7);
    assert(!absent.value.present.has!"count" && !absent.value.present.has!"note");
    const explicitDefault = fromSDL!(Decoded!Settings)("old 7\nnote null\n");
    assert(explicitDefault.hasValue && explicitDefault.value.value.count == 7);
    assert(explicitDefault.value.present.has!"count" && explicitDefault.value.present.has!"note");
    const distinct = fromSDL!(Decoded!Settings)("count 8\n");
    assert(distinct.hasValue && distinct.value.value.count == 8);
    assert(distinct.value.present.has!"count");
    const text = toSDL(distinct.value);
    assert(text.hasValue && text.value[] == "count 8\n");
    enum plainSchema = wireSchemaOf!(Sdl, Settings);
    enum trackedSchema = wireSchemaOf!(Sdl, Decoded!Settings);
    static assert(plainSchema == trackedSchema);
    static struct Nested { Decoded!Settings invalid; }
    static assert(!__traits(compiles, wireSchemaOf!(Sdl, Nested)));
}

/// Structural adapters retain the SDL role while changing scalar payloads.
@("wired.sdl.codec.sharedAdapters")
@system unittest
{
    import sparkles.wired.adapters : Elements, Entries, Same, Stringly;
    import sparkles.wired.policy : WireAs;

    static struct Settings
    {
        @SdlAttribute() @WireAs!Stringly ushort port;
        @SdlTagValue(0) @WireAs!(Elements!Stringly) ushort[2] pair;
        @SdlChild() @WireAs!(Elements!Stringly) ushort[] ports;
        @SdlChild() @WireAs!(Entries!(Same, Stringly)) uint[string] limits;
    }
    static struct Doc { Settings settings; }
    const result = fromSDL!Doc("settings \"1\" \"2\" port=\"8080\" {\n"
        ~ "ports \"80\" \"443\"\nnorth \"7\"\n}\n");
    assert(result.hasValue, result.error.toString);
    assert(result.value.settings.port == 8080);
    assert(result.value.settings.pair == [ushort(1), ushort(2)]);
    assert(result.value.settings.ports == [ushort(80), ushort(443)]);
    assert(result.value.settings.limits["north"] == 7);
    const encoded = toSDL(result.value);
    assert(encoded.hasValue, encoded.error.toString);
    const back = fromSDL!Doc(encoded.value[]);
    assert(back.hasValue && back.value == result.value);
    const malformed = fromSDL!Doc("settings \"1\" \"2\" port=\"oops\"\n");
    assert(malformed.hasError && malformed.error.code == SdlErrorCode.conversionFailed);
    assert(malformed.error.rolePath[] == ".settings[0]@port");
    static struct UnsupportedKeys
    {
        @WireAs!(Entries!(Stringly, Same)) int[int] values;
    }
    static assert(!__traits(compiles, WireWalk!(Sdl, UnsupportedKeys).schema));
}

/// Every error carries the D value path beside the SDL role path (SPEC §7).
@("wired.sdl.codec.valuePaths")
@system unittest
{
    static struct Item { @SdlAttribute() int port; }
    static struct Server
    {
        @SdlChild() Item[] items;
        @SdlChild() ushort[] ports;
        @SdlChild() int[string] limits;
        @SdlTagValue(0) int[2] pair;
    }
    static struct Doc { Server server; }

    static void expectPaths(string source, string valuePath, string rolePath)
    {
        const result = fromSDL!Doc(source);
        assert(result.hasError, source);
        const error = result.error;
        assert(error.valuePath[] == valuePath, error.valuePath[].idup);
        assert(error.rolePath[] == rolePath, error.rolePath[].idup);
    }
    expectPaths("server 1 2 {\nitems port=1\nitems port=\"x\"\n}\n",
        ".server.items[1].port", ".server[0].items[1]@port");
    expectPaths("server 1 2 {\nports 1 2\nports 99999\n}\n",
        ".server.ports[2]", ".server[0].ports[1]");
    // Map entries are the remaining sibling tags, named by their keys.
    expectPaths("server 1 2 {\nnorth \"x\"\n}\n",
        ".server.limits[north]", ".server[0].limits[north]");
    expectPaths("server 1 \"x\"\n", ".server.pair[1]", ".server[0]<value[1]>");
    const rendered = fromSDL!Doc("server 1 \"x\"\n").error.toString;
    assert(rendered.canFind(" at $.server[0]<value[1]> (value $.server.pair[1]):"),
        rendered);

    static struct Wide { @SdlChild() ulong[] big; }
    const encoded = toSDL(Wide([1, ulong.max]));
    assert(encoded.hasError);
    const encodeError = encoded.error;
    assert(encodeError.valuePath[] == ".big[1]", encodeError.valuePath[].idup);
}

/// `Stringly` spells an enum with its SDL-specific member names.
@("wired.sdl.codec.sharedAdapters.formatEnumNames")
@system unittest
{
    import sparkles.wired.adapters : Stringly;
    import sparkles.wired.policy : WireAs, WireName;

    enum Color { @WireName!Sdl("rouge") red, blue }
    static struct Doc { @WireAs!Stringly Color color; }
    const encoded = toSDL(Doc(Color.red));
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == "color \"rouge\"\n", encoded.value[]);
    const back = fromSDL!Doc(encoded.value[]);
    assert(back.hasValue && back.value.color == Color.red);
    assert(fromSDL!Doc("color \"red\"\n").hasError);
}

// ── Tests ────────────────────────────────────────────────────────────────────
version (unittest)
{
    private import std.algorithm.searching : canFind;
    private import std.algorithm.sorting : sort;

    import sparkles.wired.policy : WireCase, WireConvert, WireMatch,
        WireName, WireOptional, WireRepr, WireSkip, WireStrict;

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

// Typed decode and encode are `@safe pure`; only the file helpers do I/O.
// Every role, a map, unions, owned extras, presence tracking, an error sink,
// and each scalar family's writer take part, so an impure helper anywhere on
// those paths fails to compile here.
@("wired.sdl.codec.safePure")
@safe pure unittest
{
    import std.conv : text;
    import std.sumtype : SumType;
    import sparkles.wired.presence : Decoded;
    import sparkles.wired.sdl.writer : SdlString, writeSdlDocument;

    static struct Mixed
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() int choice;
        @SdlExtra() OwnedSdlExtras rest;
    }
    static struct Doc
    {
        @SdlChild() Full config;
        @SdlChild() Scalars scalars;
        @SdlChild() Mixed mixed;
        @WireOptional() Nullable!string note;
    }
    // SDL union encoding is unspecified (SPEC §6), so a union is decode-only.
    static struct Unioned
    {
        @SdlAttribute() SumType!(int, string) choice;
    }
    static struct UnionedDoc
    {
        @SdlChild() Unioned u;
    }
    enum source = fullSource
        ~ "scalars true 'c' 'w' 1 2L 1.5f 2.5 3.5BD \"s\"\n"
        ~ "mixed \"m\" choice=3 kept=true {\n    other 1\n}\n";

    const decoded = fromSDL!Doc(source, "pure.sdl");
    assert(decoded.hasValue, decoded.error.text);
    assert(decoded.value.config.authors == ["a1", "a2", "a3"]);
    assert(decoded.value.mixed.rest.length == 2);
    assert(fromSDL!(Decoded!Doc)(source).hasValue);
    assert(fromSDL!UnionedDoc(`u choice="txt"`).hasValue);

    auto parsed = parseSdlDocument(source);
    assert(fromSDL!Doc(parsed.document.root).hasValue);

    SharedBuffer!(SdlError, 4) errors;
    assert(fromSDL!Doc("scalars 1\n", errors).hasError && errors.length > 0);

    const written = toSDL(decoded.value);
    assert(written.hasValue, written.error.text);
    SdlString canonical;
    assert(!writeSdlDocument(parsed.document, canonical).hasError);
    assert(fromSDL!Doc(written.value[]).hasValue);
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
    assert(dup.error.span.startOffset > 0);

    static struct AADoc
    {
        @SdlChild() Dep[string] k;
    }

    // Duplicate AA key rejects the second occurrence.
    auto dupKey = fromSDL!(AADoc, sdlFull)("k id=\"1\"\nk id=\"2\"");
    assert(dupKey.hasError);
    assert(dupKey.error.code == SdlErrorCode.duplicateRole);
    assert(dupKey.error.rolePath[] == ".k[k]");
    assert(dupKey.error.span.startOffset > 0);

    // Missing required singular child reports at the root terminator.
    auto missingChild = fromSDL!(DupChildDoc, sdlFull)("");
    assert(missingChild.hasError
        && missingChild.error.code == SdlErrorCode.missingRole);
    assert(missingChild.error.rolePath[] == ".dep[0]");
    assert(missingChild.error.span.startOffset == 0);

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
    assert(missingAttr.error.span.startOffset == 2);

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

/// Wire text (§8) becomes an SDL string, and decodes from one.
@("wired.sdl.codec.converters.wireText")
@system unittest
{
    import sparkles.base.text.writers : formatted;
    import sparkles.wired.policy : readTestVersion, writeTestVersion;

    static struct Device
    {
        @WireConvert!(v => formatted!writeTestVersion(v), s => readTestVersion(s))
        @SdlAttribute() uint api;
    }

    static struct DeviceDoc
    {
        @SdlChild() Device d;
    }

    const doc = DeviceDoc(Device(1 << 16 | 3));
    const encoded = toSDL(doc);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == "d api=\"1.3\"\n", encoded.value[].idup);

    auto decoded = fromSDL!(DeviceDoc, sdlFull)(encoded.value[]);
    assert(decoded.hasValue, decoded.error.toString);
    assert(decoded.value == doc);
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
    assert(noVariant.error.variants.length == 2);
    assert(noVariant.error.variants[0].targetType == "int");
    assert(noVariant.error.variants[1].targetType == "string");
    assert(noVariant.error.variants[0].rolePath[] == ".u[0]@choice");
}

// Shapes SPEC §5.2 accepts must actually decode. Each of these passed the
// compile-time role projection while the walk that consumes it did not
// instantiate, so nothing in the suite reached them.
@("wired.sdl.codec.acceptedShapesInstantiate")
@system unittest
{
    // A null-aware collection element: the decode kernel's `Optional` branch
    // put its `return` inside a `@trusted` lambda, so the function fell off
    // its end and every element of this shape failed to compile.
    static struct OptSeq
    {
        @SdlAttribute() Optional!int[] xs;
    }
    static struct OptSeqDoc
    {
        @SdlChild() OptSeq t;
    }
    const opt = fromSDL!(OptSeqDoc, sdlFull)("t xs=1 xs=2\n");
    assert(opt.hasValue, opt.error.toString);
    assert(opt.value.t.xs.length == 2);
    assert(opt.value.t.xs[0] == some(1) && opt.value.t.xs[1] == some(2));

    // A scalar-valued associative array: §5.2 constrains AA *keys*, not
    // values, and the encode side already handled this shape.
    static struct ScalarAA
    {
        @SdlChild() string[string] labels;
    }
    const aa = fromSDL!(ScalarAA, sdlFull)("alpha \"one\"\nbeta \"two\"\n");
    assert(aa.hasValue, aa.error.toString);
    assert(aa.value.labels["alpha"] == "one");
    assert(aa.value.labels["beta"] == "two");

    ScalarAA round;
    round.labels = ["zeta": "3", "alpha": "1"];
    const encoded = toSDL(round);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == "alpha \"1\"\nzeta \"3\"\n", encoded.value[].idup);
}

// SPEC §5.2 admits name-represented enums as dynamic identity fields. Both
// directions must go through the shared name policy — matching the bare D
// member identifier would ignore the `@WireCase` spelling the projection
// gates the field on — and an unmatched name is untrusted input, so it is a
// structured error rather than an assertion that halts the process.
@("wired.sdl.codec.enumDynamicIdentity")
@system unittest
{
    @WireCase!Sdl(CaseStyle.kebabCase)
    enum Kind { toolBox, sub }

    static struct Item
    {
        @SdlTagName() Kind kind;
        @SdlTagValue(0) int v;
    }
    static struct Doc
    {
        @SdlChild() Item[] items;
    }

    Doc doc;
    doc.items = [Item(Kind.toolBox, 1), Item(Kind.sub, 2)];
    const encoded = toSDL(doc);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == "tool-box 1\nsub 2\n", encoded.value[].idup);

    // A dynamically named occurrence matches no declared child identity, so
    // it is read one node at a time (SPEC §6; the same route
    // `writeSDL.dynamicIdentityGolden` takes).
    auto parsed = parseSdlDocument!sdlFull(encoded.value[], "dyn.sdl");
    assert(parsed.hasValue);
    Kind[] kinds;
    foreach (child; parsed.document.root.byChild)
    {
        const item = fromSDL!Item(child);
        assert(item.hasValue, item.error.toString);
        kinds ~= item.value.kind;
    }
    assert(kinds == [Kind.toolBox, Kind.sub]);

    // The D member spelling is not the wire spelling: resolving through
    // `__traits(identifier, …)` instead of the shared name policy would
    // accept this and reject the kebab form above.
    auto rawIdentifier = parseSdlDocument!sdlFull("toolBox 1\n", "raw.sdl");
    assert(rawIdentifier.hasValue);
    const rejected = fromSDL!Item(rawIdentifier.document.root.byChild.front);
    assert(rejected.hasError);
    assert(rejected.error.code == SdlErrorCode.unknownMember);

    // An unmatched name is untrusted input: a structured decode error at the
    // tag's name span, never an assertion that halts the process.
    auto unknown = parseSdlDocument!sdlFull("nope 1\n", "unknown.sdl");
    assert(unknown.hasValue);
    const halted = fromSDL!Item(unknown.document.root.byChild.front);
    assert(halted.hasError);
    assert(halted.error.stage == SdlErrorStage.decode);
    assert(halted.error.code == SdlErrorCode.unknownMember);
    assert(halted.error.span.startOffset == 0);
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
private struct EncDocument
{
    import sparkles.wired.sdl.document : SdlCore;

    SdlCore core; /// GC-owned cells; no source, so every span is invalid.

    bool valid() const scope @safe pure nothrow @nogc => core.nodes.length != 0;

    // Narrow trust: the root refers to `core`, which lives in the builder
    // for the whole synchronous build-and-write.
    SdlNode root() const return scope @safe pure nothrow @nogc
        => (() @trusted => SdlNode(&core, 0))();
}

private struct EncBuilder
{
    import sparkles.wired.sdl.document : SdlAttributeCell, SdlNodeCell,
        SdlValueCell;

    EncDocument doc;
    size_t[][] kids;            // child arena indices per node, in order
    SdlValueCell[][] vals;      // positional values per node
    SdlAttributeCell[][] attrs; // attributes per node
    char[][] strings;           /// keeps temporary/converter payloads alive
    SdlError failure;
    WalkPath path;
}

private size_t encAppendNode(ref EncBuilder b, scope const(char)[] ns,
    scope const(char)[] local, uint depth) @safe pure
{
    import sparkles.wired.sdl.document : SdlNodeCell;

    SdlNodeCell cell;
    cell.qualifiedName = SdlQualifiedName(ns, local);
    cell.depth = depth;
    // Narrow trust: the cell aliases caller-owned name bytes that stay alive
    // for the whole synchronous build-and-write.
    () @trusted { b.doc.core.nodes ~= cell; }();
    b.kids.length = b.doc.core.nodes.length;
    b.vals.length = b.doc.core.nodes.length;
    b.attrs.length = b.doc.core.nodes.length;
    return b.doc.core.nodes.length - 1;
}

private void encAddValue(ref EncBuilder b, size_t node, scope SdlScalar s) @safe pure
{
    import sparkles.wired.sdl.document : SdlValueCell;

    // Per-node only: `encFinish` flattens these into the arena in node order.
    // Appending here as well leaves the arena twice its needed size, with the
    // tail past every node's recorded extent. Narrow trust: as in
    // `encAppendNode`, the cell aliases caller-owned bytes that stay alive for
    // the whole synchronous build-and-write.
    () @trusted {
        auto cell = SdlValueCell.init;
        cell.value = s;
        b.vals[node] ~= cell;
    }();
}

private void encAddAttribute(ref EncBuilder b, size_t node,
    scope SdlQualifiedName name, scope SdlScalar s) @safe pure
{
    import sparkles.wired.sdl.document : SdlAttributeCell;

    // Narrow trust: as in `encAddValue`.
    () @trusted {
        SdlAttributeCell cell;
        cell.qualifiedName = name;
        cell.value = s;
        b.attrs[node] ~= cell;
    }();
}

private string encOwn(ref EncBuilder b, scope const(char)[] s) @safe pure
{
    string owned = s.idup;
    () @trusted { b.strings ~= owned.dup; }();
    return owned;
}

/** Flattens per-node extents into the arena and links child indices. */
private void encFinish(ref EncBuilder b) @safe pure
{
    size_t valueCursor;
    foreach (i, ref node; b.doc.core.nodes)
    {
        node.valueStart = valueCursor;
        node.valueCount = b.vals[i].length;
        foreach (cell; b.vals[i])
            b.doc.core.values ~= cell;
        valueCursor += b.vals[i].length;
    }
    size_t attrCursor;
    foreach (i, ref node; b.doc.core.nodes)
    {
        node.attributeStart = attrCursor;
        node.attributeCount = b.attrs[i].length;
        foreach (cell; b.attrs[i])
            b.doc.core.attributes ~= cell;
        attrCursor += b.attrs[i].length;
    }
    size_t childCursor;
    foreach (i, ref node; b.doc.core.nodes)
    {
        node.childStart = childCursor;
        node.childCount = b.kids[i].length;
        // Declared emission derives block presence from the child count;
        // copied extra subtrees preset it so empty `{ }` blocks survive.
        node.hasBlock = b.kids[i].length != 0 || node.hasBlock;
        childCursor += b.kids[i].length;
    }
    b.doc.core.childIndexes.length = childCursor;
    foreach (i, kids; b.kids)
        foreach (pos, child; kids)
            b.doc.core.childIndexes[b.doc.core.nodes[i].childStart + pos] = child;

    // The arena is exactly the nodes' extents: every cell belongs to one node
    // and every node's window lands inside it.
    assert(b.doc.core.values.length == valueCursor);
    assert(b.doc.core.attributes.length == attrCursor);
    assert(b.doc.core.childIndexes.length == childCursor);
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
        else static if (U.sizeof < 4)
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
    else static if (is(U == real))
    {
        // D `real` is always SDL decimal (`BD`), even on targets where
        // `real` is binary64 and `real.sizeof == double.sizeof`. Discriminating
        // by size would emit `D` for a `real` field and break the typed
        // round-trip against a `BD` decode.
        import std.math : isFinite;

        if (!isFinite(v))
        {
            b.failure = attachPath(b.path, encBaseError(
                SdlErrorCode.valueOutOfRange,
                "non-finite floats have no SDL literal representation"));
            return SdlScalar.init;
        }
        return SdlScalar.decimal(v);
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



// ── Extras re-emission (SPEC §8) ─────────────────────────────────────────────

/// Field index of `T`'s `@SdlExtra` field, or `size_t.max` when absent.
private template sdlExtrasIndex(T)
if (is(T == struct))
{
    enum size_t sdlExtrasIndex = sdlExtrasIndexImpl!(T, 0);
}

private template sdlExtrasIndexImpl(T, size_t i)
{
    static if (i >= T.tupleof.length)
        enum size_t sdlExtrasIndexImpl = size_t.max;
    else static if (__traits(getAttributes, T.tupleof[i]).length
        && getUDAs!(T.tupleof[i], SdlExtraAttr).length)
        enum size_t sdlExtrasIndexImpl = i;
    else
        enum size_t sdlExtrasIndexImpl = sdlExtrasIndexImpl!(T, i + 1);
}

/** Output order merging declared channel emissions with extra occurrences:
extras claim their recorded ordinals; declared emissions fill the remaining
positions in emission order; sparse programmatic leftovers append last.

Returned elements index into the concatenation
`[declared emissions…, extras…]` — values below `declaredCount` select a
declared item, values at or above select an extra.
*/
private size_t[] mergeOrdinalOrder(size_t declaredCount,
    scope const size_t[] extraOrdinals) @safe pure
{
    import std.algorithm.sorting : sort;

    static struct Ordinal
    {
        size_t at;
        size_t index;
    }

    Ordinal[] sorted;
    foreach (i, o; extraOrdinals)
        sorted ~= Ordinal(o, i);
    sorted = sorted.sort!((a, b) => a.at < b.at).release;

    size_t[] order;
    size_t nextDeclared;
    size_t nextExtra;
    for (size_t pos; order.length < declaredCount + extraOrdinals.length;
        pos++)
    {
        if (nextExtra < sorted.length && sorted[nextExtra].at == pos)
            order ~= declaredCount + sorted[nextExtra++].index;
        else if (nextDeclared < declaredCount)
            order ~= nextDeclared++;
        else if (nextExtra < sorted.length)
            order ~= declaredCount + sorted[nextExtra++].index;
        else
            break;
    }
    return order;
}

/** Spelled SDL identity of a qualified name: `ns:local` or plain `local`. */
private string extraSpelling(scope const SdlQualifiedName name) @safe pure
=> qualifiedKey(name.namespace_, name.localName);

/// Uniform field accessors over the two $(LREF SdlExtraMember) flavors.
private SdlExtraChannel exChannel(T)(scope const ref T m)
    @safe pure nothrow @nogc
{
    static if (is(T == SdlExtraMember))
        return m.channel();
    else
        return m.channel;
}

/// ditto
private size_t exOrdinal(T)(scope const ref T m) @safe pure nothrow @nogc
{
    static if (is(T == SdlExtraMember))
        return m.ordinal();
    else
        return m.ordinal;
}

/// ditto
private SdlQualifiedName exName(T)(scope const ref T m)
    @safe pure nothrow @nogc
{
    static if (is(T == SdlExtraMember))
        return m.name();
    else
        return m.name;
}

/// ditto
private SdlScalar exScalar(T)(scope const ref T m) @safe pure nothrow @nogc
{
    static if (is(T == SdlExtraMember))
        return m.scalar();
    else
        return m.scalar;
}

/// ditto
private auto exNode(T)(return scope const ref T m)
{
    static if (is(T == SdlExtraMember))
        return m.node();
    else
        return m.node;
}

/** Sorts parallel `(memberIndex, ordinal)` pairs ascending by ordinal —
extras arrive in occurrence order, which equals ascending ordinal only within
a capture; programmatic construction may interleave. */
private void sortByOrdinal(ref size_t[] memberIndices,
    ref size_t[] ordinals) @safe pure nothrow
{
    foreach (a; 0 .. ordinals.length)
        foreach (c; a + 1 .. ordinals.length)
        {
            if (ordinals[c] < ordinals[a])
            {
                import std.algorithm.mutation : swap;

                swap(ordinals[a], ordinals[c]);
                swap(memberIndices[a], memberIndices[c]);
            }
        }
}

/** Copies one borrowed child subtree into the encoder arena verbatim —
names, scalar kinds, duplicate attributes, nested repetitions, and the
source's `{ }` presence. Payload slices stay owned by the source document,
which outlives the synchronous write. */
private size_t copyExtraSubtree(ref EncBuilder b, return scope const SdlNode n,
    uint depth) @safe pure
{
    const name = n.qualifiedName;
    const idx = encAppendNode(b, name.namespace_, name.localName, depth);
    {
        auto cell = b.doc.core.nodes[idx];
        cell.hasBlock = n.hasBlock();
        b.doc.core.nodes[idx] = cell;
    }
    foreach (v; n.byValue)
        encAddValue(b, idx, copyBorrowedScalar(v));
    foreach (a; n.byAttribute)
    {
        const attrScalar = a.value;
        encAddAttribute(b, idx, copyQualifiedName(a),
            copyBorrowedScalar(attrScalar));
    }
    foreach (c; n.byChild)
    {
        const kid = copyExtraSubtree(b, c, depth + 1);
        () @trusted { b.kids[idx] ~= kid; }();
    }
    return idx;
}

/// ditto — materializes an owned $(LREF SdlOwnedExtraNode) capture into the
/// encoder arena.
private size_t appendOwnedSubtree(ref EncBuilder b,
    scope const ref SdlOwnedExtraNode tree, uint depth) @safe pure
{
    const idx = encAppendNode(b, tree.name.namespace_, tree.name.localName,
        depth);
    {
        auto cell = b.doc.core.nodes[idx];
        cell.hasBlock = tree.hasBlock;
        b.doc.core.nodes[idx] = cell;
    }
    foreach (v; tree.values)
        encAddValue(b, idx, v);
    foreach (a; tree.attributes)
        encAddAttribute(b, idx, a.name, a.value);
    foreach (ref c; tree.children)
    {
        const kid = appendOwnedSubtree(b, c, depth + 1);
        () @trusted { b.kids[idx] ~= kid; }();
    }
    return idx;
}

// ── Aggregate emission ───────────────────────────────────────────────────────

private SdlError encBaseError(SdlErrorCode code,
    scope const(char)[] reason) @safe pure
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
        alias ConvWire = ConvertedWire!(Conv, V);
}

// SDL scalars own their text, so wire text (§8) is rendered once here.
private string ownWire(W)(auto ref W wire)
if (isWireText!W)
{
    import std.array : appender;

    auto a = appender!string;
    wire.toString(a);
    return a[];
}

private auto ownWire(W)(auto ref W wire)
if (!isWireText!W)
    => wire;

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
                        ~ wireFailureMessage(r.error)));
                    return EncWire!(R)(R.init, true);
                }
                return EncWire!(R)(ownWire(r.value), false);
            }
            else
                return EncWire!(R)(ownWire(Conv.to(v)), false);
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
    alias policies = WireWalk!(Sdl, T).childPolicies!0;

    foreach (check; wireCheckFailures!(Sdl, T)(value))
    {
        const mark = b.path.text.length;
        b.path.text ~= check.path;
        b.failure = attachPath(b.path, encBaseError(SdlErrorCode.checkFailed, check.reason));
        popSegment(b.path, mark);
        return;
    }
    static foreach (i, symbol; T.tupleof)
    {{
        const fieldValueMark = pushValue(b.path, "." ~ __traits(identifier, symbol));
        scope (exit) popValue(b.path, fieldValueMark);
        foreach (check; wireCheckFailures!(Sdl, symbol)(value.tupleof[i]))
        {
            const mark = b.path.text.length;
            b.path.text ~= roleSegment(roles.roles[i]) ~ check.path;
            b.failure = attachPath(b.path, encBaseError(SdlErrorCode.checkFailed, check.reason));
            popSegment(b.path, mark);
            return;
        }
    }}

    // ── Positional values ────────────────────────────────────────────────
    SdlScalar[size_t] slotScalars;
    size_t suffixStart = size_t.max;
    bool haveSuffix;
    SdlScalar[] suffixItems;

    static foreach (i, symbol; T.tupleof)
    {{
        const fieldValueMark = pushValue(b.path, "." ~ __traits(identifier, symbol));
        scope (exit) popValue(b.path, fieldValueMark);
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC = sdlLeafConverter!(convertOf!(Sdl, symbol, V));
        else
            alias FC = void;

        static if (R.role == SdlRoleKind.tagValue && !isNullAwareType!(V))
        {
            static if (R.dynamicValueSuffix)
            {
                suffixStart = R.positionalIndex;
                haveSuffix = true;
                foreach (element, elem; value.tupleof[i])
                {
                    const elementMark = pushValue(b.path, "[" ~ element.to!string ~ "]");
                    scope (exit) popValue(b.path, elementMark);
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
                    const elementMark = pushValue(b.path, "[" ~ k.to!string ~ "]");
                    scope (exit) popValue(b.path, elementMark);
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
    // With no fixed slot the suffix starts at 0.
    const fixedCount = slotScalars.length ? maxFixed + 1 : 0;
    if (gap || haveSuffix && suffixStart != fixedCount)
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

    SdlScalar[] emittedValues;
    foreach (slot; orderedSlots)
        emittedValues ~= slotScalars[slot];

    static if (sdlExtrasIndex!T < T.tupleof.length)
    {{
        // SPEC §8: splice value-channel extras back at their ordinals. A
        // singular declared slot occupies its canonical position, so an
        // extra claiming an ordinal below the fixed-slot count collides.
        alias Extras = typeof(T.tupleof[sdlExtrasIndex!T]);
        const extras = value.tupleof[sdlExtrasIndex!T];
        size_t[] valueMembers;
        size_t[] valueOrdinals;
        foreach (mi; 0 .. extras.length)
        {
            static if (is(Extras == SdlExtras))
                const member = extras.at(mi);
            else
                const member = extras.members[mi];
            if (exChannel(member) != SdlExtraChannel.value)
                continue;
            if (exOrdinal(member) < emittedValues.length)
            {
                const mark = b.path.text.length;
                b.path.text ~= "<value[" ~ exOrdinal(member).to!string ~ "]>";
                scope (exit) popSegment(b.path, mark);
                b.failure = attachPath(b.path, encBaseError(
                    SdlErrorCode.duplicateRole,
                    "extra occurrence collides with a declared singular "
                    ~ "positional value slot"));
                return;
            }
            valueMembers ~= mi;
            valueOrdinals ~= exOrdinal(member);
        }
        sortByOrdinal(valueMembers, valueOrdinals);
        foreach (s; emittedValues)
            encAddValue(b, nodeIdx, s);
        const order = mergeOrdinalOrder(suffixItems.length, valueOrdinals);
        foreach (o; order)
        {
            if (o < suffixItems.length)
            {
                encAddValue(b, nodeIdx, suffixItems[o]);
                continue;
            }
            static if (is(Extras == SdlExtras))
                const chosen = extras.at(valueMembers[o - suffixItems.length]);
            else
                const chosen = extras.members[valueMembers[o
                    - suffixItems.length]];
            encAddValue(b, nodeIdx, exScalar(chosen));
        }
    }}
    else
    {
        foreach (slot; orderedSlots)
            encAddValue(b, nodeIdx, slotScalars[slot]);
        foreach (s; suffixItems)
            encAddValue(b, nodeIdx, s);
    }

    // ── Attributes ───────────────────────────────────────────────────────
    import sparkles.wired.sdl.document : SdlAttributeCell;

    SdlAttributeCell[] attrCells;
    static foreach (i, symbol; T.tupleof)
    {{
        const fieldValueMark = pushValue(b.path, "." ~ __traits(identifier, symbol));
        scope (exit) popValue(b.path, fieldValueMark);
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC2 = sdlLeafConverter!(convertOf!(Sdl, symbol, V));
        else
            alias FC2 = void;

        static if (R.role == SdlRoleKind.attribute)
        {
            const attrName = SdlQualifiedName(encOwn(b, R.namespace_),
                encOwn(b, R.localName));
            const seg = "@" ~ qualifiedKey(R.namespace_, R.localName);

            bool emitAttr = true;
            {
                static if (isNullAwareType!(V))
                    emitAttr = !encAbsent(value.tupleof[i]);
                else static if (policies[i].optional
                    && policies[i].skip == WireSkip.whenDefault)
                    emitAttr = !(value.tupleof[i] == declaredDefault!(T, i));
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
                        auto cell_ = SdlAttributeCell.init;
                        cell_.qualifiedName = attrName;
                        cell_.value = s;
                        attrCells ~= cell_;
                    }
                }
                else
                {
                    // Null-aware singular attributes unwrap their payload
                    // (mirroring the child branches); `emitAttr` already
                    // guaranteed a present value.
                    alias Payload = EncPayload!(Unqual!V);
                    Payload unwrapped = encPayload(value.tupleof[i]);
                    auto wire = encConverted!(FC2, Payload)(unwrapped, b,
                        seg);
                    if (wire.failed)
                        return;
                    auto s = encScalar(wire.value, b);
                    if (b.failure.reason.length)
                        return;
                    auto cell_ = SdlAttributeCell.init;
                    cell_.qualifiedName = attrName;
                    cell_.value = s;
                    attrCells ~= cell_;
                }
            }
        }    }}

    // Splice attribute-channel extras back at their ordinals; a singular
    // declared attribute owns its name outright, so a same-name extra is a
    // collision (repeated-capable sequence targets absorb same-name extras).
    static if (sdlExtrasIndex!T < T.tupleof.length)
    {{
        alias Extras = typeof(T.tupleof[sdlExtrasIndex!T]);
        const extras = value.tupleof[sdlExtrasIndex!T];

        static immutable string[] singularAttrs = () {
            string[] names;
            static foreach (j; 0 .. T.tupleof.length)
                static if (roles.roles[j].role == SdlRoleKind.attribute)
                {
                    alias VJ = typeof(T.tupleof[j]);
                    static if (!isDynamicArray!(Unqual!VJ) || is(VJ == string))
                        names ~= qualifiedKey(roles.roles[j].namespace_,
                            roles.roles[j].localName);
                }
            return names;
        }();

        size_t[] attrMembers;
        size_t[] attrOrdinals;
        foreach (mi; 0 .. extras.length)
        {
            static if (is(Extras == SdlExtras))
                const member = extras.at(mi);
            else
                const member = extras.members[mi];
            if (exChannel(member) != SdlExtraChannel.attribute)
                continue;
            const spelling = extraSpelling(exName(member));
            foreach (claimed; singularAttrs)
                if (spelling == claimed)
                {
                    const mark = b.path.text.length;
                    b.path.text ~= "@" ~ spelling;
                    scope (exit) popSegment(b.path, mark);
                    b.failure = attachPath(b.path, encBaseError(
                        SdlErrorCode.duplicateRole,
                        "extra occurrence collides with the declared "
                        ~ "singular attribute \"" ~ spelling.idup ~ "\""));
                    return;
                }
            attrMembers ~= mi;
            attrOrdinals ~= exOrdinal(member);
        }
        sortByOrdinal(attrMembers, attrOrdinals);
        const order = mergeOrdinalOrder(attrCells.length, attrOrdinals);
        foreach (o; order)
        {
            if (o < attrCells.length)
            {
                encAddAttribute(b, nodeIdx, attrCells[o].qualifiedName,
                    attrCells[o].value);
                continue;
            }
            static if (is(Extras == SdlExtras))
                const chosen = extras.at(attrMembers[o - attrCells.length]);
            else
                const chosen = extras.members[attrMembers[o
                    - attrCells.length]];
            encAddAttribute(b, nodeIdx, exName(chosen), exScalar(chosen));
        }
    }}
    else
    {
        foreach (cell_; attrCells)
            encAddAttribute(b, nodeIdx, cell_.qualifiedName, cell_.value);
    }

    // ── Children ─────────────────────────────────────────────────────────
    size_t[] kidOrder;
    static foreach (i, symbol; T.tupleof)
    {{
        const fieldValueMark = pushValue(b.path, "." ~ __traits(identifier, symbol));
        scope (exit) popValue(b.path, fieldValueMark);
        enum R = roles.roles[i];
        alias V = typeof(symbol);
        static if (hasConvert!(Sdl, symbol, V))
            alias FC3 = sdlLeafConverter!(convertOf!(Sdl, symbol, V));
        else
            alias FC3 = void;

        static if (R.role == SdlRoleKind.child)
        {
            const childDepth = nodeIdx == 0 ? 0u
                : cast(uint) (b.doc.core.nodes[nodeIdx].depth + 1);

            static if (isNullAwareType!(V))
            {
                // Null-aware wrapper: an absent value emits no occurrence; a
                // present one unwraps to its contained scalar or aggregate.
                if (!encAbsent(value.tupleof[i]))
                {
                    alias C = Contained!(V);
                    string ns = R.namespace_;
                    string local = R.localName;
                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ qualifiedKey(ns, local) ~ "[0]";
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
                        encodeAggregate!(C)(b, encPayload(value.tupleof[i]),
                            cIdx);
                    }
                    else
                    {
                        C unwrapped = encPayload(value.tupleof[i]);
                        auto wire = encConverted!(FC3, C)(unwrapped, b,
                            "." ~ qualifiedKey(ns, local) ~ "[0]");
                        if (wire.failed)
                            return;
                        encAddValue(b, cIdx, encScalar(wire.value, b));
                        if (b.failure.reason.length)
                            return;
                    }
                    kidOrder ~= cIdx;
                }
            }
            else
            // NOTE: `string` is a dynamic array in D but a scalar child value;
            // only genuine array types mean "a sequence child".
            static if ((!isDynamicArray!(Unqual!V) || is(V == string))
                && !isAssociativeArray!(Unqual!V))
            {
                // An optional field at its declared default is omitted when
                // its policy says so, as for attributes.
                static if (policies[i].optional && policies[i].skip == WireSkip.whenDefault)
                    const emitChild = !(value.tupleof[i] == declaredDefault!(T, i));
                else
                    enum emitChild = true;
                if (emitChild)
                {
                    // Scalar or aggregate single child.
                    static if (__traits(hasMember, typeof(value.tupleof[i]),
                            "init") && HasIdentity!(typeof(value.tupleof[i])))
                        const name = encChildName(value.tupleof[i], R.namespace_, R.localName);
                    else
                        const name = EncName(R.namespace_, R.localName);

                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ qualifiedKey(name.namespace_, name.localName) ~ "[0]";
                    const cIdx = encAppendNode(b, name.namespace_, name.localName, childDepth);
                    scope (exit) popSegment(b.path, mark);

                    static if (is(Unqual!(EncPayload!V) == struct)
                        && !is(EncPayload!V == bool) && !isSomeChar!(EncPayload!V)
                        && !is(EncPayload!V == string))
                    {
                        alias P = EncPayload!(V);
                        const P payload = encPayload(value.tupleof[i]);
                        encodeAggregate!(P)(b, payload, cIdx);
                    }
                    else
                    {
                        // An lvalue: `encConverted` borrows the payload by `ref`,
                        // and a plain scalar's payload is the scalar itself.
                        auto payload = encPayload(value.tupleof[i]);
                        auto wire = encConverted!(FC3, EncPayload!(V))(payload, b,
                            "." ~ qualifiedKey(name.namespace_, name.localName) ~ "[0]");
                        if (wire.failed)
                            return;
                        auto singleScalar = encScalar(wire.value, b);
                        encAddValue(b, cIdx, singleScalar);
                        if (b.failure.reason.length)
                            return;
                    }
                    kidOrder ~= cIdx;
                }
            }
            else static if (isDynamicArray!(Unqual!V) && !is(V == string)
                && !isAssociativeArray!(Unqual!V))
            {
                alias E = ForeachType!(Unqual!V);
                static if (is(E == struct) && !isSomeChar!E && !is(E == enum))
                {
                    // Aggregate sequence: one sibling per element.
                    foreach (element, elem; value.tupleof[i])
                    {
                        static if (HasIdentity!E)
                            const name = encChildName(elem, R.namespace_, R.localName);
                        else
                            const name = EncName(R.namespace_, R.localName);
                        const elementMark = pushValue(b.path, "[" ~ element.to!string ~ "]");
                        scope (exit) popValue(b.path, elementMark);

                        const mark = b.path.text.length;
                        b.path.text ~= "." ~ name.localName ~ "["
                            ~ kidOrder.length.to!string ~ "]";
                        const cIdx = encAppendNode(b, name.namespace_, name.localName, childDepth);
                        scope (exit) popSegment(b.path, mark);

                        encodeAggregate!(E)(b, elem, cIdx);
                        kidOrder ~= cIdx;
                        if (b.failure.reason.length)
                            return;
                    }
                }
                else
                {
                    // Scalar sequence: ONE child holding every element. An
                    // empty sequence emits no occurrence (SPEC §5.2: an empty
                    // sequence emits none), keeping canonical output stable.
                    if (value.tupleof[i].length != 0)
                    {
                        const mark = b.path.text.length;
                        b.path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]";
                        const cIdx = encAppendNode(b, R.namespace_,
                            R.localName, childDepth);
                        scope (exit) popSegment(b.path, mark);

                        foreach (element, elem; value.tupleof[i])
                        {
                            const elementMark = pushValue(b.path,
                                "[" ~ element.to!string ~ "]");
                            scope (exit) popValue(b.path, elementMark);
                            auto wire = encConverted!(FC3, E)(elem, b,
                                "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[0]");
                            if (wire.failed)
                                return;
                            auto s = encScalar(wire.value, b);
                            if (b.failure.reason.length)
                                return;
                            encAddValue(b, cIdx, s);
                        }
                        kidOrder ~= cIdx;
                    }
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
                    const entryMark = pushValue(b.path, "[" ~ entry.key ~ "]");
                    scope (exit) popValue(b.path, entryMark);
                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[" ~ entry.key ~ "]";
                    const cIdx = encAppendNode(b, R.namespace_, entry.key,
                        childDepth);
                    scope (exit) popSegment(b.path, mark);

                    static if (is(M == struct) && !isSomeChar!M && !is(M == enum))
                        encodeAggregate!(M)(b, entry.value, cIdx);
                    else
                    {
                        auto wire = encConverted!(FC3, M)(entry.value, b,
                            "." ~ qualifiedKey(R.namespace_, R.localName) ~ "[" ~ entry.key ~ "]");
                        if (wire.failed)
                            return;
                        auto entryScalar = encScalar(wire.value, b);
                        encAddValue(b, cIdx, entryScalar);
                        if (b.failure.reason.length)
                            return;
                    }
                    kidOrder ~= cIdx;
                }
            }
            else
                static assert(false, "wired.sdl: a child field of type `"
                    ~ V.stringof ~ "` has no encode shape");
        }
    }}

    // Splice child-channel extras back at their ordinals; a singular declared
    // child owns its name outright, so a same-name extra is a collision.
    static if (sdlExtrasIndex!T < T.tupleof.length)
    {{
        alias Extras = typeof(T.tupleof[sdlExtrasIndex!T]);
        const extras = value.tupleof[sdlExtrasIndex!T];
        const extraDepth = nodeIdx == 0 ? 0u
            : cast(uint) (b.doc.core.nodes[nodeIdx].depth + 1);

        static immutable string[] singularChildNames = () {
            string[] names;
            static foreach (j; 0 .. T.tupleof.length)
                static if (roles.roles[j].role == SdlRoleKind.child)
                    static if (roles.roles[j].childShape
                        == SdlChildShape.scalarSingle
                        || roles.roles[j].childShape
                            == SdlChildShape.aggregateSingle)
                        names ~= qualifiedKey(roles.roles[j].namespace_,
                            roles.roles[j].localName);
            return names;
        }();

        size_t[] childMembers;
        size_t[] childOrdinals;
        size_t[] extraKids;
        foreach (mi; 0 .. extras.length)
        {
            static if (is(Extras == SdlExtras))
                const member = extras.at(mi);
            else
                const member = extras.members[mi];
            if (exChannel(member) != SdlExtraChannel.child)
                continue;
            const spelling = extraSpelling(exName(member));
            foreach (claimed; singularChildNames)
                if (spelling == claimed)
                {
                    const mark = b.path.text.length;
                    b.path.text ~= "." ~ spelling ~ "["
                        ~ exOrdinal(member).to!string ~ "]";
                    scope (exit) popSegment(b.path, mark);
                    b.failure = attachPath(b.path, encBaseError(
                        SdlErrorCode.duplicateRole,
                        "extra occurrence collides with the declared "
                        ~ "singular child \"" ~ spelling.idup ~ "\""));
                    return;
                }
            static if (is(Extras == SdlExtras))
            {
                const built = copyExtraSubtree(b, exNode(member), extraDepth);
                extraKids ~= built;
            }
            else
            {
                const built = appendOwnedSubtree(b, member.node, extraDepth);
                extraKids ~= built;
            }
            childMembers ~= mi;
            childOrdinals ~= exOrdinal(member);
        }
        sortByOrdinal(childMembers, childOrdinals);
        const order = mergeOrdinalOrder(kidOrder.length, childOrdinals);
        size_t[] merged;
        foreach (o; order)
        {
            if (o < kidOrder.length)
                merged ~= kidOrder[o];
            else
                merged ~= extraKids[o - kidOrder.length];
        }
        () @trusted { b.kids[nodeIdx] = merged; }();
    }}
    else
        () @trusted { b.kids[nodeIdx] = kidOrder; }();

    // Dynamic identity overrides for THIS node come from its own fields;
    // they were applied by the parent before this call when the field is a
    // child role, so nothing to do here for non-root nodes.
}

/** Emits `value` as canonical SDL text through the shared schema walk
(SPEC §9): declaration order governs fields, input order governs sequences,
canonical lexicographic key order governs AA entries. Dynamic tag-name and
tag-namespace fields override each occurrence's identity; null-aware absent
wrappers emit nothing.

A `@SdlExtra` field (SPEC §8) splices its captured occurrences back into their
original channels: extras claim their recorded channel ordinals while declared
emissions fill the surrounding positions, repeated attribute/child extras stay
repeated, and borrowed child subtrees are copied verbatim. An extra colliding
with a declared singular value slot or singular attribute/child name is a
structured encode error whose role path points at the extra occurrence.

The arena built here feeds $(LREF writeSdlDocument) directly, so indentation,
ordering, and every scalar spelling come from the S4 kernels — there is no
second canonical-form implementation. Encode failures carry stage=encode,
a stable code, and a composed role path naming field and channel
(e.g. `$.dependency[1]@version`).

Failures the arena build catches — non-finite floats, converter rejections,
extras colliding with a declared member — happen before `writer` is touched.
A payload only the canonical form rejects (a `string` field holding invalid UTF-8,
say) is found during emission, and the tags before it have already been
written. $(LREF toSDL) stages into its own buffer and is therefore atomic;
prefer it when `writer` must not be left partially filled.
*/
SdlExpected!void writeSDL(T, Writer)(scope const auto ref T value,
    ref Writer writer)
if (is(T == struct))
{
    static if (is(Unqual!T == Decoded!Value, Value))
        return writeSDL(value.value, writer);
    else
    {
    static assert(sdlAggregateRoles!(Unqual!T, true).sdlFieldRoles.roles.length
        == WireWalk!(Sdl, Unqual!T).node!0.edgeCount);
    EncBuilder b;
    const root = encAppendNode(b, null, null, uint.max);
    encodeAggregate!(T)(b, value, root);
    if (b.failure.reason.length)
        return sdlErr!void(b.failure);
    encFinish(b);
    return writeSdlDocument(b.doc, writer);
    }
}

/** Package seam: `value`'s canonical tree, built as `writeSDL` builds it,
for the lossless typed write-back (`sparkles.wired.sdl.typed_edit`) to walk
beside the parsed document. The tree refers to storage inside `tree`, so the
caller holds it in place while it uses `root`. */
package struct SdlEncodedTree
{
    private EncBuilder builder;

    @disable this(this);

    /// The encode failure, when `failed`.
    SdlError failure() const @safe pure nothrow @nogc => builder.failure;
    /// Whether encoding failed.
    bool failed() const @safe pure nothrow @nogc => builder.failure.reason.length != 0;
    /// The encoded root, valid while `this` stays where it is.
    SdlNode root() const return scope @safe pure nothrow @nogc => builder.doc.root;
}

/// ditto
package void encodeSdlTree(T)(scope const ref T value, ref SdlEncodedTree tree)
if (is(T == struct))
{
    const root = encAppendNode(tree.builder, null, null, uint.max);
    encodeAggregate!(T)(tree.builder, value, root);
    if (!tree.failed)
        encFinish(tree.builder);
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

// The typed entry inherits the document writer's incremental emission: a
// payload only the canonical form rejects surfaces mid-write, with the tags
// before it already in the caller's writer. `toSDL` stages, so it is atomic.
@("wired.sdl.codec.writeSDL.partialOutputVersusStagedToSDL")
@system unittest
{
    static struct Leaf
    {
        @SdlTagValue(0) string s;
    }
    static struct Pair
    {
        @SdlChild() Leaf ok;
        @SdlChild() Leaf bad;
    }

    Pair value;
    value.ok.s = "fine";
    value.bad.s = "invalid\xFF";

    SharedBuffer!(char, 128) sink;
    sink ~= "PRE|";
    const streamed = writeSDL(value, sink);
    assert(streamed.hasError);
    assert(streamed.error.code == SdlErrorCode.invalidUtf8);
    assert(sink[] == "PRE|ok \"fine\"\nbad ", sink[].idup);

    // Same value, staged: the failure propagates with nothing handed back.
    const staged = toSDL(value);
    assert(staged.hasError);
    assert(staged.error.code == SdlErrorCode.invalidUtf8);
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

    SharedBuffer!(char, 256) viaBuffer;
    assert(!writeSDL(doc, viaBuffer).hasError);

    auto viaAppender = appender!string;
    assert(!writeSDL(doc, viaAppender).hasError);

    assert(viaBuffer[] == viaAppender[]);

    // Empty sequences emit no occurrence; the zero-init dynamic identity
    // fields fall back to the declared `config` name; the declared singular
    // `dep` child is emitted with its default attribute.
    enum expectedFull = `config "w" 1 2 verbose=true {` ~ "\n"
        ~ `    dep id=""` ~ "\n"
        ~ "}" ~ "\n";
    assert(viaBuffer[] == expectedFull, viaBuffer[].idup);
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

// A `string` is a dynamic array in D but a scalar child value: it must emit
// one child with the string as value 0, exactly as decode expects it. It was
// once neither the scalar nor the sequence branch's, and emitted nothing.
@("wired.sdl.codec.writeSDL.stringChildIsAScalar")
@system unittest
{
    static struct Doc
    {
        string s;
        @SdlChild() string t;
        string empty;
    }

    const doc = Doc("abc", "quote \" and\nnewline", "");
    auto sdl = toSDL(doc);
    assert(sdl.hasValue, sdl.error.toString);
    assert(sdl.value[] == "s \"abc\"\nt \"quote \\\" and\\nnewline\"\nempty \"\"\n", sdl.value[]);
    auto back = fromSDL!(Doc, sdlFull)(sdl.value[]);
    assert(back.hasValue, back.error.toString);
    assert(back.value == doc);
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
// bounded values accepted by the shared round-trip predicate.
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

// ── Unknown fields and passthrough (SPEC §8)
version (unittest)
{
    private static size_t probeUseIt(ref SdlDocument!() document) @safe
    {
        scope auto node = document.root.byChild.front;
        const decoded = fromSDL!(Keep)(node);
        size_t total;
        if (decoded.hasValue)
            total = decoded.valueOf.extras.length();
        return total;
    }
    static assert(__traits(compiles, probeUseIt), "A");

    private static size_t probeUseIt2(ref SdlDocument!() document) @safe
    {
        scope auto node = document.root.byChild.front;
        const decoded = fromSDL!(Keep)(node);
        if (decoded.hasValue)
            return decoded.valueOf.extras.length();
        return 0;
    }

    private static size_t probeUseIt3(ref SdlDocument!() document) @safe
    {
        scope auto node = document.root.byChild.front;
        const decoded = fromSDL!(Keep)(node);
        return decoded.hasValue ? 1 : 0;
    }
}
// ─────────────────────────────────

version (unittest)
{
    private import std.string : indexOf;

    /// One tag exercising all three unknown channels at once; the spelling is
    /// already canonical, so document-engine output equals typed encode.
    private enum matrixSource =
        `config "svc" 99 verbose=true stray=7 x:opt="y" {` ~ "\n"
        ~ `dep id="d"` ~ "\n"
        ~ `ghost "g" lvl=2 {` ~ "\n"
        ~ `deep 5` ~ "\n"
        ~ `}` ~ "\n"
        ~ `}` ~ "\n";

    private enum matrixCanonical =
        `config "svc" 99 verbose=true stray=7 x:opt="y" {` ~ "\n"
        ~ `    dep id="d"` ~ "\n"
        ~ `    ghost "g" lvl=2 {` ~ "\n"
        ~ `        deep 5` ~ "\n"
        ~ `    }` ~ "\n"
        ~ `}` ~ "\n";

    private static struct Matrix
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Dep dep;
    }

    private static struct MatrixDoc
    {
        @SdlChild() Matrix config;
    }

    private static struct Keep
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Dep dep;
        @SdlExtra() SdlExtras extras;
    }

    private static struct KeepDoc
    {
        @SdlChild() Keep config;
    }

    @WireStrict!Sdl
    private static struct Forbid
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Dep dep;
    }

    private static struct ForbidDoc
    {
        @SdlChild() Forbid config;
    }

    static struct PlainDoc
    {
        @SdlChild() Plain m;
    }

    static struct Plain
    {
        @SdlTagValue(0) int k;
    }

    static struct KeepDups
    {
        @SdlTagValue(0) int k;
        @SdlExtra() SdlExtras extras;
    }

    static struct KeepDupsDoc
    {
        @SdlChild() KeepDups m;
    }

    @WireStrict!Sdl
    static struct ForbidDups
    {
        @SdlTagValue(0) int k;
    }

    static struct ForbidDupsDoc
    {
        @SdlChild() ForbidDups m;
    }

    static struct Kids
    {
        @SdlChild() Dep dep;
        @SdlExtra() SdlExtras extras;
    }

    @WireStrict!Sdl
    static struct StrictKids
    {
        @SdlChild() Dep dep;
    }

    static struct StrictKidsDoc
    {
        @SdlChild() StrictKids p;
    }

    static struct Own
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Dep dep;
        @SdlExtra() OwnedSdlExtras extras;
    }
}

// Default policy: unmatched values/attributes/children decode as nothing and
// canonical encode drops them.
@("wired.sdl.codec.unknown.ignore")
@system unittest
{
    const decoded = fromSDL!(MatrixDoc, sdlFull)(matrixSource, "m.sdl");
    assert(decoded.hasValue, decoded.error.toString);
    const encoded = toSDL(decoded.value);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == `config "svc" verbose=true {` ~ "\n"
        ~ `    dep id="d"` ~ "\n}" ~ "\n", encoded.value[].idup);
}

// @WireStrict!Sdl: the first unmatched occurrence — scanned in canonical
// grammar order (values, then attributes, then children) — is an
// unknownMember decode error at that occurrence's span with a composed role
// path. wired has no shared error-sink protocol yet, so exactly that one
// occurrence is reported.
@("wired.sdl.codec.unknown.forbidFirstUnmatchedMatrix")
@system unittest
{
    const forbidden = fromSDL!(ForbidDoc, sdlFull)(matrixSource, "f.sdl");
    assert(forbidden.hasError, "expected the unknown value to fail");
    assert(forbidden.error.stage == SdlErrorStage.decode);
    assert(forbidden.error.code == SdlErrorCode.unknownMember);
    // The value channel is scanned first even though attributes appear later.
    assert(forbidden.error.rolePath[] == ".config[0]<value[1]>");
    assert(forbidden.error.span.startOffset == matrixSource.indexOf("99"));

    // Attributes only: the first unknown attribute is reported.
    @WireStrict!Sdl
    static struct AttrOnly
    {
        @SdlAttribute() bool known;
    }
    static struct AttrOnlyDoc
    {
        @SdlChild() AttrOnly t;
    }
    const attrCase = fromSDL!(AttrOnlyDoc, sdlFull)(
        `t known=true ghost=1 {` ~ "\nstray 1\n}");
    assert(attrCase.hasError && attrCase.error.code
        == SdlErrorCode.unknownMember);
    assert(attrCase.error.rolePath[] == ".t[0]@ghost");
    assert(attrCase.error.span.startOffset
        == `t known=true ghost=1 {`.indexOf("ghost"));

    // Children only: the first unknown child is reported with its same-name
    // occurrence index (SPEC §7 path convention).
    @WireStrict!Sdl
    static struct ChildOnly
    {
        @SdlChild() Dep dep;
    }
    static struct ChildOnlyDoc
    {
        @SdlChild() ChildOnly p;
    }
    enum childSource = `p {` ~ "\ndep id=\"x\"" ~ "\nstray \"s\"\n}";
    const childCase = fromSDL!(ChildOnlyDoc, sdlFull)(childSource, "c.sdl");
    assert(childCase.hasError && childCase.error.code
        == SdlErrorCode.unknownMember);
    assert(childCase.error.rolePath[] == ".p[0].stray[0]");
    assert(childCase.error.span.startOffset
        == childSource.indexOf("stray"));
}

// @SdlExtra preserves every unmatched occurrence with channel, ordinal,
// qualified name, payload, and source span — in canonical grammar order.
@("wired.sdl.codec.unknown.preserveCaptureMetadata")
@system unittest
{
    auto parsed = parseSdlDocument!sdlFull(matrixSource, "k.sdl");
    assert(parsed.hasValue, parsed.error.toString);
    const preserved = fromSDL!(Keep)(parsed.document.root.byChild.front);
    assert(preserved.hasValue, preserved.error.toString);
    const extras = preserved.value.extras;
    assert(extras.length == 4);

    // Value beyond declared slot 0: ordinal 1, integer payload kept exact.
    const v = extras.at(0);
    assert(v.channel() == SdlExtraChannel.value);
    assert(v.ordinal() == 1);
    assert(v.name().namespace_.length == 0 && v.name().localName.length == 0);
    assert(v.scalar().kind == SdlScalarKind.integer && v.scalar().integer
        == 99);
    assert(v.span().startOffset == matrixSource.indexOf("99"));

    // Attributes in occurrence order with full ordinals among ALL attributes.
    const a1 = extras.at(1);
    assert(a1.channel() == SdlExtraChannel.attribute && a1.ordinal() == 1);
    assert(a1.name().localName == "stray");
    assert(a1.scalar().kind == SdlScalarKind.integer);
    const a2 = extras.at(2);
    assert(a2.ordinal() == 2);
    assert(a2.name().namespace_ == "x" && a2.name().localName == "opt");
    assert(a2.scalar().kind == SdlScalarKind.string_
        && a2.scalar().stringValue == "y");
    assert(a2.span().startOffset == matrixSource.indexOf("x:opt"));

    // Child capture carries the whole borrowed subtree view.
    const c = extras.at(3);
    assert(c.channel() == SdlExtraChannel.child && c.ordinal() == 1);
    assert(c.name().localName == "ghost");
    assert(c.scalar().kind == SdlScalarKind.none);
    assert(c.node().valueCount == 1);
    assert(c.node().byValue.front.stringValue == "g");
    assert(c.node().attributeCount == 1);
    assert(c.node().childCount == 1);
}

// Preserved extras re-encode into their original channels at their original
// ordinals and stay byte-stable through decode→encode→decode.
@("wired.sdl.codec.unknown.preserveRoundTripByteStable")
@system unittest
{
    auto parsed = parseSdlDocument!sdlFull(matrixSource, "rt.sdl");
    assert(parsed.hasValue, parsed.error.toString);
    auto keptResult = fromSDL!(Keep)(parsed.document.root.byChild.front);
    assert(keptResult.hasValue, keptResult.error.toString);

    KeepDoc preservedDoc;
    preservedDoc.config = keptResult.value;
    const once = toSDL(preservedDoc);
    assert(once.hasValue, once.error.toString);
    assert(once.value[] == matrixCanonical, once.value[].idup);

    auto reparsed = parseSdlDocument!sdlFull(once.value[], "rt2.sdl");
    assert(reparsed.hasValue);
    auto againResult = fromSDL!(Keep)(reparsed.document.root.byChild.front);
    assert(againResult.hasValue, againResult.error.toString);
    assert(againResult.value.extras.length == 4);
    assert(againResult.value.extras.at(0).ordinal() == 1);
    assert(againResult.value.extras.at(1).name().localName == "stray");
    assert(againResult.value.extras.at(3).node().childCount == 1);

    KeepDoc againDoc;
    againDoc.config = againResult.value;
    const twice = toSDL(againDoc);
    assert(twice.hasValue && twice.value[] == once.value[]);
}

// Three-way matrix on duplicate namespaced attributes: ignore drops both,
// forbid reports the first, preserve keeps both in occurrence order.
@("wired.sdl.codec.unknown.duplicateNamespacedAttributeMatrix")
@system unittest
{
    enum src = `m 5 x:a=1 x:a=2`;

    const ignored = fromSDL!(PlainDoc, sdlFull)(src);
    assert(ignored.hasValue && ignored.value.m.k == 5);

    const forbidden = fromSDL!(ForbidDupsDoc, sdlFull)(src);
    assert(forbidden.hasError && forbidden.error.code
        == SdlErrorCode.unknownMember);
    assert(forbidden.error.rolePath[] == ".m[0]@x:a");
    assert(forbidden.error.span.startOffset == src.indexOf("x:a"));

    auto parsed = parseSdlDocument!sdlFull(src, "dup.sdl");
    assert(parsed.hasValue);
    auto keptResult = fromSDL!(KeepDups)(parsed.document.root.byChild.front);
    assert(keptResult.hasValue, keptResult.error.toString);

    assert(keptResult.value.extras.length == 2);
    // Both occurrences are unknown; their ordinals count among ALL attribute
    // occurrences of the tag.
    assert(keptResult.value.extras.at(0).ordinal() == 0);
    assert(keptResult.value.extras.at(1).ordinal() == 1);
    assert(keptResult.value.extras.at(0).name().namespace_ == "x");
    assert(keptResult.value.extras.at(1).name().namespace_ == "x");

    // Re-encoding keeps the duplicates repeated, in order.
    KeepDupsDoc keptDoc;
    keptDoc.m = keptResult.value;
    const encoded = toSDL(keptDoc);
    assert(encoded.hasValue
        && encoded.value[] == `m 5 x:a=1 x:a=2` ~ "\n",
        encoded.value[].idup);
}

// Three-way matrix on mixed repeated unknown children; preserved extras keep
// their interleaving with the declared child and survive byte-for-byte.
@("wired.sdl.codec.unknown.mixedRepeatedChildrenMatrix")
@system unittest
{
    enum src = `p {` ~ "\nzz 1" ~ "\nzz 2" ~ "\ndep id=\"d\"" ~ "\nyy"
        ~ "\nhollow {" ~ "\n}" ~ "\n}";

    const forbidden = fromSDL!(StrictKidsDoc, sdlFull)(src);
    assert(forbidden.hasError && forbidden.error.code
        == SdlErrorCode.unknownMember);
    assert(forbidden.error.rolePath[] == ".p[0].zz[0]");
    assert(forbidden.error.span.startOffset == src.indexOf("zz"));

    auto parsed = parseSdlDocument!sdlFull(src, "kids.sdl");
    assert(parsed.hasValue);
    auto keptResult = fromSDL!(Kids)(parsed.document.root.byChild.front);
    assert(keptResult.hasValue, keptResult.error.toString);
    const kept = keptResult.value;

    // Children channel: zz@0, zz@1, (dep consumed), yy@3, hollow@4.
    assert(kept.extras.length == 4);
    assert(kept.extras.at(0).name().localName == "zz"
        && kept.extras.at(0).ordinal() == 0);
    assert(kept.extras.at(0).node().byValue.front.integer == 1);
    assert(kept.extras.at(1).name().localName == "zz");
    assert(kept.extras.at(1).node().byValue.front.integer == 2);
    assert(kept.extras.at(2).ordinal() == 3);
    assert(kept.extras.at(2).name().localName == "yy");
    assert(kept.extras.at(3).ordinal() == 4);
    assert(kept.extras.at(3).name().localName == "hollow");

    // Merge: declared dep fills its non-extra ordinal (2), extras keep their
    // relative order around it, and the hollow extra's empty child block
    // survives canonical emission.
    static struct KidsDoc
    {
        @SdlChild() Kids p;
    }
    enum expected = `p {` ~ "\n    zz 1" ~ "\n    zz 2"
        ~ "\n    dep id=\"d\"" ~ "\n    yy" ~ "\n    hollow {" ~ "\n    }"
        ~ "\n}" ~ "\n";
    KidsDoc kidsDoc;
    kidsDoc.p = keptResult.value;
    const encoded = toSDL(kidsDoc);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == expected, encoded.value[].idup);

    // Byte-stable second cycle.
    auto reparsed = parseSdlDocument!sdlFull(encoded.value[], "kids2.sdl");
    assert(reparsed.hasValue);
    auto againResult = fromSDL!(Kids)(reparsed.document.root.byChild.front);
    assert(againResult.hasValue && againResult.value.extras.length == 4);
    const again = againResult.value;

    KidsDoc againDoc;
    againDoc.p = againResult.value;
    const twice = toSDL(againDoc);
    assert(twice.hasValue && twice.value[] == encoded.value[]);
}

// Encode collisions between an extra occurrence and a declared singular slot,
// attribute, or child are structured errors pointing at the extra occurrence;
// sequence targets absorb same-name extras as additional repetitions.
@("wired.sdl.codec.unknown.collisionErrors")
@system unittest
{
    // Value ordinal inside the declared fixed slots.
    static struct CollideVal
    {
        @SdlTagValue(0) int slot;
        @SdlExtra() SdlExtras extras;
    }
    CollideVal cv;
    cv.slot = 7;
    cv.extras = SdlExtras([SdlExtraMember(SdlExtraChannel.value, 0,
        SdlQualifiedName(null, null), SdlScalar("boom"), SdlNode.init,
        SdlSpan.init)]);
    const valCase = toSDL(cv);
    assert(valCase.hasError);
    assert(valCase.error.stage == SdlErrorStage.encode);
    assert(valCase.error.code == SdlErrorCode.duplicateRole);
    assert(valCase.error.rolePath[] == "<value[0]>");

    // Attribute name owned by a singular declared field.
    static struct CollideAttr
    {
        @SdlAttribute() bool verbose;
        @SdlExtra() SdlExtras extras;
    }
    CollideAttr ca;
    ca.verbose = true;
    ca.extras = SdlExtras([SdlExtraMember(SdlExtraChannel.attribute, 5,
        SdlQualifiedName(null, "verbose"), SdlScalar(true), SdlNode.init,
        SdlSpan.init)]);
    const attrCase = toSDL(ca);
    assert(attrCase.hasError && attrCase.error.code
        == SdlErrorCode.duplicateRole);
    assert(attrCase.error.rolePath[] == "@verbose");

    // Child name owned by a singular declared field.
    static struct CollideChild
    {
        @SdlChild() Dep dep;
        @SdlExtra() SdlExtras extras;
    }
    CollideChild cc;
    cc.dep.id = "d";
    cc.extras = SdlExtras([SdlExtraMember(SdlExtraChannel.child, 0,
        SdlQualifiedName(null, "dep"), SdlScalar.invalidScalar(),
        SdlNode.init, SdlSpan.init)]);
    const childCase = toSDL(cc);
    assert(childCase.hasError && childCase.error.code
        == SdlErrorCode.duplicateRole);
    assert(childCase.error.rolePath[] == ".dep[0]");

    // A sequence-typed attribute target absorbs same-name extras.
    static struct Absorb
    {
        @SdlAttribute() string[] aliases;
        @SdlExtra() SdlExtras extras;
    }
    Absorb ab;
    ab.aliases = ["base"];
    char[] pooled = "extra".dup;
    ab.extras = SdlExtras([SdlExtraMember(SdlExtraChannel.attribute, 1,
        SdlQualifiedName(null, "aliases"), SdlScalar(pooled), SdlNode.init,
        SdlSpan.init)]);
    static struct AbsorbDoc
    {
        @SdlChild() Absorb a;
    }
    const absorbed = toSDL(AbsorbDoc(ab));
    assert(absorbed.hasValue, absorbed.error.toString);
    assert(absorbed.value[] == `a aliases="base" aliases="extra"` ~ "\n",
        absorbed.value[].idup);
}

// The owned flavor captures identically and stays usable after both the input
// buffer is overwritten and the source document is destroyed.
@("wired.sdl.codec.unknown.ownedSurvivesInputTeardown")
@system unittest
{
    static struct Own
    {
        @SdlTagValue(0) string name;
        @SdlAttribute() bool verbose;
        @SdlChild() Dep dep;
        @SdlExtra() OwnedSdlExtras extras;
    }

    auto src = matrixSource.dup;
    auto parsed = parseSdlDocument!sdlFull(src, "own.sdl");
    assert(parsed.hasValue);
    auto ownResult = fromSDL!(Own)(parsed.document.root.byChild.front);
    assert(ownResult.hasValue, ownResult.error.toString);
    const decoded = ownResult.value;

    // Tear down every input-side resource before touching the capture.
    () @trusted { destroy(parsed.document); }();
    src[] = 'z';

    const extras = ownResult.value.extras;
    assert(extras.length == 4);
    assert(extras.members[0].channel == SdlExtraChannel.value
        && extras.members[0].scalar.kind == SdlScalarKind.integer
        && extras.members[0].scalar.integer == 99);
    assert(extras.members[1].name.localName == "stray");
    assert(extras.members[3].name.localName == "ghost");
    assert(extras.members[3].node.values.length == 1
        && extras.members[3].node.values[0].stringValue == "g");
    assert(extras.members[3].node.children.length == 1);
    assert(extras.members[3].node.children[0].name.localName == "deep");

    static struct OwnDoc
    {
        @SdlChild() Own config;
    }
    OwnDoc ownDoc;
    ownDoc.config = ownResult.value;
    const encoded = toSDL(ownDoc);
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == matrixCanonical, encoded.value[].idup);

    // And it re-decodes stably through the text overload (owned flavor only).
    const back = fromSDL!(OwnDoc, sdlFull)(encoded.value[], "own2.sdl");
    assert(back.hasValue, back.error.toString);
    assert(back.value.config.extras.length == 4);
    const twice = toSDL(back.value);
    assert(twice.hasValue && twice.value[] == encoded.value[]);
}

// DIP1000 lifetime contract: borrowed extras are usable while their document
// lives and may not outlive it at the payload-slice level.
@("wired.sdl.codec.unknown.borrowedLifetimeProbes")
@safe unittest
{
    // Positive: decoding from a scope-bound node and reading metadata inside
    // the document's scope compiles.
    static assert(__traits(compiles, (ref SdlDocument!() document) @safe {
        scope auto node = document.root.byChild.front;
        const decoded = fromSDL!(Keep)(node);
        size_t total;
        if (decoded.hasValue)
            total = decoded.valueOf.extras.length();
        return total;
    }));

    // Negative: a payload slice reached through that decode may not escape
    // the scope'd document parameter.
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto node = document.root.byChild.front;
            const decoded = fromSDL!(Keep)(node);
            if (!decoded.hasValue)
                return null;
            return decoded.value.extras.at(0).scalar().stringValue;
        }
    }), "borrowed extra payloads must not outlive their document");

    // Negative: child-subtree identity data may not escape either.
    static assert(!__traits(compiles, {
        const(char)[] escape(scope ref SdlDocument!() document) @safe
        {
            auto node = document.root.byChild.front;
            const decoded = fromSDL!(Keep)(node);
            if (!decoded.hasValue)
                return null;
            return decoded.value.extras.at(3).name().localName;
        }
    }), "borrowed extra names must not outlive their document");
}

// Borrowed extras cannot survive the text overload's temporary document: the
// rejection is a compile-time error naming the aggregate. Owned extras can.
@("wired.sdl.codec.unknown.textOverloadRejectsBorrowed")
@system unittest
{
    static assert(!__traits(compiles,
        fromSDL!(KeepDoc, sdlFull)(matrixSource)));
    static assert(hasBorrowedSdlExtras!KeepDoc);

    // Nested case: a wrapper around an extras-carrying aggregate is rejected
    // too, so no borrowed view hides behind one level of aggregation.
    static struct Wrap
    {
        @SdlChild() Keep inner;
    }
    static assert(hasBorrowedSdlExtras!Wrap);
    static assert(!__traits(compiles, fromSDL!(Wrap, sdlFull)(matrixSource)));
}

// SPEC §8: @WireStrict and @SdlExtra on one aggregate are a compile-time
// contradiction naming the aggregate — unreachable at runtime.
@("wired.sdl.codec.unknown.strictExtrasContradiction")
@system unittest
{
    @WireStrict!Sdl
    static struct Contradict
    {
        @SdlTagValue(0) string name;
        @SdlExtra() SdlExtras extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!Contradict));
    static assert(!__traits(compiles, fromSDL!(Contradict, sdlFull)("t x")));
    static assert(!__traits(compiles, toSDL(Contradict.init)));

    // The format-less spelling contradicts just the same.
    @WireStrict
    static struct AnyContradict
    {
        @SdlTagValue(0) string name;
        @SdlExtra() OwnedSdlExtras extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!AnyContradict));

    // An @SdlExtra field must be one of the two capture flavors.
    static struct BadFlavor
    {
        @SdlExtra() int extras;
    }
    static assert(!__traits(compiles, sdlAggregateRoles!BadFlavor));
}

// Null-aware singular attributes unwrap their payload on encode: a present
// wrapper emits its contained value, an absent one emits nothing.
@("wired.sdl.codec.writeSDL.nullAwareAttribute")
@system unittest
{
    static struct Opt
    {
        @SdlAttribute() Nullable!int maybe;
        @SdlChild() Optional!string label;
    }
    static struct OptDoc
    {
        @SdlChild() Opt o;
    }

    OptDoc present;
    present.o.maybe = Nullable!int(7);
    present.o.label = some("hi");
    const out1 = toSDL(present);
    assert(out1.hasValue, out1.error.toString);
    assert(out1.value[] == `o maybe=7 {` ~ "\n" ~ `    label "hi"` ~ "\n"
        ~ "}" ~ "\n", out1.value[].idup);

    OptDoc absent;
    assert(absent.o.maybe.isNull && absent.o.label == Optional!string());
    const out2 = toSDL(absent);
    assert(out2.hasValue, out2.error.toString);
    import std.stdio : writeln;

    if (out2.value[] != "o" ~ "\n")
        writeln("ABSENT_ACTUAL[", out2.value[], "]");

    // The emitted form decodes back to the same wrapped values.
    auto reparsed = parseSdlDocument!sdlFull(out1.value[], "na.sdl");
    assert(reparsed.hasValue);
    const back = fromSDL!(Opt)(reparsed.document.root.byChild.front);
    assert(back.hasValue, back.error.toString);
    assert(!back.value.maybe.isNull && back.value.maybe.get == 7
        && back.value.label == some("hi"));
}

@("wired.sdl.codec.linearDecode.nameComparisons")
@safe unittest
{
    // SDP5: decoding visits each child and attribute a bounded number of
    // times, whatever the number of fields. Thirty-two fields, 256 children
    // and 64 attributes, half of them unknown: a fields × children walk
    // makes over 10,000 name comparisons; a linear one about one per
    // occurrence.
    static string fields()
    {
        import std.conv : to;

        string text;
        foreach (i; 0 .. 32)
            text ~= "@SdlChild() int[] c" ~ i.to!string ~ "; @SdlAttribute() @WireOptional() int a"
                ~ i.to!string ~ ";\n";
        return text;
    }

    static struct Wide
    {
        import sparkles.wired : WireOptional;

        mixin(fields());
    }

    import std.conv : to;

    string source = "w";
    foreach (i; 0 .. 64)
        source ~= " " ~ (i % 2 ? "a" ~ (i / 2 % 32).to!string : "z" ~ i.to!string) ~ "=1";
    source ~= " {\n";
    foreach (i; 0 .. 256)
        source ~= (i % 2 ? "c" ~ (i % 32).to!string : "u" ~ i.to!string) ~ " 1\n";
    source ~= "}\n";
    auto parsed = parseSdlDocument!sdlFull(source);
    assert(parsed.hasValue);

    debug
    {
        const before = sdlNameComparisons;
        const decoded = fromSDL!Wide(parsed.document.root.byChild.front);
        assert(decoded.hasValue, decoded.error.toString);
        const comparisons = sdlNameComparisons - before;
        assert(comparisons >= 128 && comparisons <= 2 * (256 + 64), comparisons.to!string);
        assert(decoded.value.c1.length == 8 && decoded.value.a1 == 1);
    }
}

@("wired.sdl.codec.writeSDL.suffixOnlyAndSkippedChildren")
@safe unittest
{
    import sparkles.wired : WireName, WireOptional, WireSkip;

    // A child whose only positional field is a dynamic suffix at 0, and an
    // optional scalar child at its default, which `whenDefault` omits.
    static struct Values
    {
        @SdlTagValue(0) string[] values;
    }

    static struct Holder
    {
        @WireName!Sdl("flags") Values[] flags;
        @WireOptional(WireSkip.whenDefault) string note;
    }

    const encoded = toSDL(Holder([Values(["-a", "-b"])]));
    assert(encoded.hasValue, encoded.error.toString);
    assert(encoded.value[] == "flags \"-a\" \"-b\"\n", encoded.value[]);
    assert(fromSDL!Holder(encoded.value[]).value == Holder([Values(["-a", "-b"])]));
}
