/**
Format-aware `@Wire*` policy attributes and their value vocabulary.

This module is the format-agnostic policy layer of `sparkles:wired`: it defines
the marker sentinel `AnyFormat`, the policy enums (`Repr`, `WireTarget`,
`WireSkip`, `WireInvalid`), and the `@Wire*` user-defined attributes a type
author annotates enum members, fields, and types with. A concrete format backend
(e.g. `sparkles.wired.json`) resolves these against its own format tag.

Each value-carrying attribute is a **factory function** (`WireName`, `WireCase`,
`WireRepr`, `WireOptional`) returning a format-parameterized `*Attr` struct — so
both `@WireName("x")` and `@WireName!Json("x")` work as ordinary compile-time
calls. Resolvers detect and read the attributes through the `*Attr` structs.

See `docs/specs/wired/SPEC.md` §5 for the normative surface.
*/
module sparkles.wired.policy;

import std.traits : getUDAs;

import sparkles.base.text.case_style : CaseStyle, convertCase;

/// The sentinel format: an untagged `@Wire*` UDA applies under every format.
struct AnyFormat
{
}

/// Enum serialization representation — by member name or underlying value (§7).
enum Repr
{
    name,  /// the member's serialized name
    value, /// the member's underlying value (via `OriginalType`)
}

/// Which slot of a wrapped field a slot-targeted `WireCase`/`WireRepr` applies
/// to (§5.2).
enum WireTarget
{
    all,   /// every eligible target on any branch (the default)
    key,   /// only enums reached in an associative-array key position
    value, /// only the value branch (array element, AA value, nullable contained)
}

/// Encode omission policy for `@WireOptional` (§5.4).
enum WireSkip
{
    never,       /// always emit the field
    whenEmpty,   /// omit an empty null-aware value (the default)
    whenDefault, /// omit a field equal to its declared default
}

/// Present-but-invalid decode policy for `@WireOptional` (§5.4).
enum WireInvalid
{
    reject,     /// a malformed present value is a decode error (the default)
    useDefault, /// fall back to the field's default value
}

/// `SumType` decode disambiguation strategy, selected via $(LREF WireMatch).
enum MatchStrategy
{
    exactlyOne, /// exactly one variant must decode (the default)
    first,      /// the first variant that decodes, in declaration order
}

/// The attribute produced by $(LREF WireName): an explicit member/field name
/// tagged with the format it applies under.
struct WireNameAttr(Format_ = AnyFormat)
{
    string name;           /// the explicit wire name
    alias Format = Format_; /// the format this name applies under
}

/// `@WireName!F("text")` — the serialized member or field name under format `F`.
WireNameAttr!Format WireName(Format = AnyFormat)(string name) @safe pure nothrow @nogc
    => WireNameAttr!Format(name);

/// The attribute produced by $(LREF WireCase).
struct WireCaseAttr(Format_ = AnyFormat)
{
    CaseStyle style;                    /// the case to recase into
    WireTarget target = WireTarget.all; /// which slot the recasing applies to
    alias Format = Format_;             /// the format this recasing applies under
}

/// `@WireCase!F(style[, target])` — recase member/field names under `F` (§6).
WireCaseAttr!Format WireCase(Format = AnyFormat)(
    CaseStyle style, WireTarget target = WireTarget.all) @safe pure nothrow @nogc
    => WireCaseAttr!Format(style, target);

/// The attribute produced by $(LREF WireRepr).
struct WireReprAttr(Format_ = AnyFormat)
{
    Repr repr;                          /// name vs value
    WireTarget target = WireTarget.all; /// which slot the representation applies to
    alias Format = Format_;             /// the format this representation applies under
}

/// `@WireRepr!F(repr[, target])` — serialize an enum by member name vs
/// underlying value under `F` (§7).
WireReprAttr!Format WireRepr(Format = AnyFormat)(
    Repr repr, WireTarget target = WireTarget.all) @safe pure nothrow @nogc
    => WireReprAttr!Format(repr, target);

/// The attribute produced by $(LREF WireOptional).
struct WireOptionalAttr(Format_ = AnyFormat)
{
    WireSkip skip = WireSkip.whenEmpty;         /// encode omission policy
    WireInvalid onInvalid = WireInvalid.reject; /// present-but-invalid decode policy
    alias Format = Format_;                     /// the format this policy applies under
}

/// `@WireOptional!F(skip, onInvalid)` — tune a field's absence, encode omission,
/// and invalid-value handling under `F` (§5.4). The arg-less default is spelled
/// `@WireOptional()` (or `@WireOptional!Json()`).
WireOptionalAttr!Format WireOptional(Format = AnyFormat)(
    WireSkip skip = WireSkip.whenEmpty,
    WireInvalid onInvalid = WireInvalid.reject) @safe pure nothrow @nogc
    => WireOptionalAttr!Format(skip, onInvalid);

/// `@WireConvert!(toWire, fromWire[, F])` — an arbitrary value transform at the
/// wire boundary (§8). `fromWire` may be `void` for a serialize-only converter.
/// This one is a type UDA (all-template, no value arguments): `@WireConvert!(a, b)`.
struct WireConvert(alias toWire, alias fromWire = void, Format = AnyFormat)
{
    alias to = toWire;     /// the encode transform (source → wire)
    alias from = fromWire; /// the decode transform (wire → source), or `void`
    alias format = Format; /// the format this converter applies under
}

/// The resolved `SumType` match policy carried by a `@(WireMatch.strategy!F)`
/// attribute.
struct WireMatchPolicy(Format_ = AnyFormat)
{
    MatchStrategy strategy; /// the selected strategy
    alias Format = Format_; /// the format this strategy applies under
}

/// Namespace for the `SumType` decode-strategy attributes: written as
/// `@(WireMatch.first!F)` or `@(WireMatch.exactlyOne!F)` — the format tag is a
/// template argument on the strategy (§4.7). Omitting it targets `AnyFormat`.
struct WireMatch
{
    /// `@(WireMatch.first!F)` — first variant that decodes wins.
    template first(Format = AnyFormat)
    {
        enum first = WireMatchPolicy!Format(MatchStrategy.first);
    }

    /// `@(WireMatch.exactlyOne!F)` — exactly one variant must decode.
    template exactlyOne(Format = AnyFormat)
    {
        enum exactlyOne = WireMatchPolicy!Format(MatchStrategy.exactlyOne);
    }
}

// Validate that every accepted §5.1 UDA form attaches and reads back, across an
// enum member/type and aggregate fields, in both the AnyFormat and
// format-specific spellings.
@("wired.policy.udaForms")
@safe pure unittest
{
    import std.traits : getUDAs, hasUDA;

    struct Json
    {
    }

    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode
    {
        @WireName!Json("turbo") fastPath,
        slowPath,
    }

    static struct S
    {
        @WireName("plain") int a;
        @WireName!Json("tagged") int b;
        @WireCase(CaseStyle.snakeCase) int c;
        @WireCase!Json(CaseStyle.snakeCase, WireTarget.key) int[Mode] d;
        @WireRepr!Json(Repr.value) Mode e;
        @WireOptional() int f;
        @WireOptional!Json() int g;
        @WireOptional(WireSkip.whenDefault, WireInvalid.useDefault) int h;
        @WireOptional(onInvalid: WireInvalid.useDefault) int hn;
        @(WireMatch.first!()) int i;
        @(WireMatch.first!Json) int j;
    }

    // Enum-member and type UDAs.
    static assert(hasUDA!(Mode.fastPath, WireNameAttr));
    static assert(getUDAs!(Mode.fastPath, WireNameAttr)[0].name == "turbo");
    static assert(is(getUDAs!(Mode.fastPath, WireNameAttr)[0].Format == Json));
    static assert(hasUDA!(Mode, WireCaseAttr));

    // Field UDAs — instances carry their values and formats.
    static assert(getUDAs!(S.a, WireNameAttr)[0].name == "plain");
    static assert(is(getUDAs!(S.a, WireNameAttr)[0].Format == AnyFormat));
    static assert(is(getUDAs!(S.b, WireNameAttr)[0].Format == Json));
    static assert(getUDAs!(S.c, WireCaseAttr)[0].style == CaseStyle.snakeCase);
    static assert(getUDAs!(S.d, WireCaseAttr)[0].target == WireTarget.key);
    static assert(getUDAs!(S.e, WireReprAttr)[0].repr == Repr.value);

    // WireOptional: bare (defaults), positional, and named-argument forms.
    static assert(getUDAs!(S.f, WireOptionalAttr)[0].skip == WireSkip.whenEmpty);
    static assert(getUDAs!(S.f, WireOptionalAttr)[0].onInvalid == WireInvalid.reject);
    static assert(is(getUDAs!(S.g, WireOptionalAttr)[0].Format == Json));
    static assert(getUDAs!(S.h, WireOptionalAttr)[0].skip == WireSkip.whenDefault);
    static assert(getUDAs!(S.h, WireOptionalAttr)[0].onInvalid == WireInvalid.useDefault);
    static assert(getUDAs!(S.hn, WireOptionalAttr)[0].skip == WireSkip.whenEmpty);
    static assert(getUDAs!(S.hn, WireOptionalAttr)[0].onInvalid == WireInvalid.useDefault);

    // WireMatch strategy attributes carry their resolved policy value.
    static assert(getUDAs!(S.i, WireMatchPolicy)[0].strategy == MatchStrategy.first);
    static assert(getUDAs!(S.j, WireMatchPolicy)[0].strategy == MatchStrategy.first);
    static assert(is(getUDAs!(S.j, WireMatchPolicy)[0].Format == Json));
}

// ─────────────────────────────────────────────────────────────────────────────
// Policy resolution
// ─────────────────────────────────────────────────────────────────────────────

private bool broadTarget(A)(A a) => a.target == WireTarget.all;
private bool anyAttr(A)(A a) => true;

/// Index of the first `Attr` UDA on `sym` whose format is exactly `Fmt` and that
/// passes `pred`, or -1. CTFE helper underpinning the resolvers.
private template firstAttr(alias sym, alias Attr, Fmt, alias pred)
{
    enum ptrdiff_t firstAttr = () {
        static foreach (i, uda; getUDAs!(sym, Attr))
            static if (is(typeof(uda).Format == Fmt))
                if (pred(uda))
                    return cast(ptrdiff_t) i;
        return cast(ptrdiff_t)(-1);
    }();
}

/// The `CaseStyle` resolved for format `F` across `syms` (field override(s) first,
/// then the type), preferring an exact-`F` `WireCase` over its `AnyFormat` form,
/// and falling back to `CaseStyle.original`. Only broad (`WireTarget.all`)
/// `WireCase` participates here.
template resolveCaseStyle(F, syms...)
{
    enum CaseStyle resolveCaseStyle = () {
        static foreach (sym; syms)
        {
            static if (firstAttr!(sym, WireCaseAttr, F, broadTarget) >= 0)
                return getUDAs!(sym, WireCaseAttr)[firstAttr!(sym, WireCaseAttr, F, broadTarget)].style;
            else static if (firstAttr!(sym, WireCaseAttr, AnyFormat, broadTarget) >= 0)
                return getUDAs!(sym, WireCaseAttr)[firstAttr!(sym, WireCaseAttr, AnyFormat, broadTarget)].style;
        }
        return CaseStyle.original;
    }();
}

/// The `Repr` resolved for format `F` across `syms` (field override(s) first, then
/// the type), preferring exact-`F` over `AnyFormat`, defaulting to `Repr.name`.
/// Only broad (`WireTarget.all`) `WireRepr` participates here.
template resolveRepr(F, syms...)
{
    enum Repr resolveRepr = () {
        static foreach (sym; syms)
        {
            static if (firstAttr!(sym, WireReprAttr, F, broadTarget) >= 0)
                return getUDAs!(sym, WireReprAttr)[firstAttr!(sym, WireReprAttr, F, broadTarget)].repr;
            else static if (firstAttr!(sym, WireReprAttr, AnyFormat, broadTarget) >= 0)
                return getUDAs!(sym, WireReprAttr)[firstAttr!(sym, WireReprAttr, AnyFormat, broadTarget)].repr;
        }
        return Repr.name;
    }();
}

/// The wire name of enum member (or aggregate field) `sym` under format `F`,
/// given the resolved case `style`: an explicit `@WireName!F` wins, then
/// `@WireName!Any`, else the identifier recased by `convertCase!style`.
template wireName(F, alias sym, CaseStyle style)
{
    enum string wireName = () {
        static if (firstAttr!(sym, WireNameAttr, F, anyAttr) >= 0)
            return getUDAs!(sym, WireNameAttr)[firstAttr!(sym, WireNameAttr, F, anyAttr)].name;
        else static if (firstAttr!(sym, WireNameAttr, AnyFormat, anyAttr) >= 0)
            return getUDAs!(sym, WireNameAttr)[firstAttr!(sym, WireNameAttr, AnyFormat, anyAttr)].name;
        else
            return convertCase!style(__traits(identifier, sym));
    }();
}

@("wired.policy.resolve.caseReprAndName")
@safe pure unittest
{
    struct Json
    {
    }

    struct Toml
    {
    }

    @WireCase!Json(CaseStyle.snakeCase)
    @WireCase(CaseStyle.kebabCase) // AnyFormat fallback
    enum Mode
    {
        fastPath,
        @WireName!Json("turbo") slowPath,
    }

    @WireRepr!Json(Repr.value)
    enum Priority { low, high }

    // Case: exact format beats AnyFormat beats the default.
    static assert(resolveCaseStyle!(Json, Mode) == CaseStyle.snakeCase);
    static assert(resolveCaseStyle!(Toml, Mode) == CaseStyle.kebabCase);
    static assert(resolveCaseStyle!(Json, Priority) == CaseStyle.original);

    // Repr: exact format, else the Repr.name default.
    static assert(resolveRepr!(Json, Priority) == Repr.value);
    static assert(resolveRepr!(Toml, Priority) == Repr.name);

    // Member names: @WireName!F wins; otherwise recase by the resolved style.
    static assert(wireName!(Json, Mode.fastPath, resolveCaseStyle!(Json, Mode)) == "fast_path");
    static assert(wireName!(Json, Mode.slowPath, resolveCaseStyle!(Json, Mode)) == "turbo");
    static assert(wireName!(Toml, Mode.slowPath, resolveCaseStyle!(Toml, Mode)) == "slow-path");
}

@("wired.policy.resolve.fieldOverridesType")
@safe pure unittest
{
    struct Json
    {
    }

    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode { fastPath, slowPath }

    static struct S
    {
        @WireCase!Json(CaseStyle.kebabCase) Mode a; // field override
        Mode b;                                     // uses the type policy
    }

    // Field override beats the type policy for that field's enum.
    static assert(resolveCaseStyle!(Json, S.a, Mode) == CaseStyle.kebabCase);
    static assert(resolveCaseStyle!(Json, S.b, Mode) == CaseStyle.snakeCase);
}
