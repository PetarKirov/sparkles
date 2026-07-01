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

/// Whether aggregate field `field` is optional under format `F` — i.e. carries a
/// `@WireOptional` for `F` or for `AnyFormat` (§5.4).
enum bool isOptional(F, alias field) =
    firstAttr!(field, WireOptionalAttr, F, anyAttr) >= 0
    || firstAttr!(field, WireOptionalAttr, AnyFormat, anyAttr) >= 0;

/// The resolved `@WireOptional` policy for `field` under `F` (exact `F` over
/// `AnyFormat`). Instantiable only when $(LREF isOptional) is true.
template optionalPolicy(F, alias field)
if (isOptional!(F, field))
{
    static if (firstAttr!(field, WireOptionalAttr, F, anyAttr) >= 0)
        enum optionalPolicy = getUDAs!(field, WireOptionalAttr)[firstAttr!(field, WireOptionalAttr, F, anyAttr)];
    else
        enum optionalPolicy = getUDAs!(field, WireOptionalAttr)[firstAttr!(field, WireOptionalAttr, AnyFormat, anyAttr)];
}

/// The `SumType` decode strategy resolved for `field` under `F`: a
/// `@(WireMatch.…!F)`, then `@(WireMatch.…!Any)`, else `MatchStrategy.exactlyOne`
/// (§4.7).
template resolveMatch(F, alias field)
{
    enum MatchStrategy resolveMatch = () {
        static if (firstAttr!(field, WireMatchPolicy, F, anyAttr) >= 0)
            return getUDAs!(field, WireMatchPolicy)[firstAttr!(field, WireMatchPolicy, F, anyAttr)].strategy;
        else static if (firstAttr!(field, WireMatchPolicy, AnyFormat, anyAttr) >= 0)
            return getUDAs!(field, WireMatchPolicy)[firstAttr!(field, WireMatchPolicy, AnyFormat, anyAttr)].strategy;
        else
            return MatchStrategy.exactlyOne;
    }();
}

@("wired.policy.resolve.optionalAndMatch")
@safe pure unittest
{
    struct Json
    {
    }

    struct Toml
    {
    }

    static struct S
    {
        int required;
        @WireOptional() int opt;
        @WireOptional!Json(WireSkip.whenDefault, WireInvalid.useDefault) int jopt;
        int plainSum;
        @(WireMatch.first!Json) int jmatch;
        @(WireMatch.first!()) int amatch;
    }

    // Optionality and its resolved policy.
    static assert(!isOptional!(Json, S.required));
    static assert(isOptional!(Json, S.opt));
    static assert(optionalPolicy!(Json, S.opt).skip == WireSkip.whenEmpty);
    static assert(optionalPolicy!(Json, S.jopt).skip == WireSkip.whenDefault);
    static assert(optionalPolicy!(Json, S.jopt).onInvalid == WireInvalid.useDefault);

    // Match strategy: exact format, AnyFormat, and the exactlyOne default.
    static assert(resolveMatch!(Json, S.plainSum) == MatchStrategy.exactlyOne);
    static assert(resolveMatch!(Json, S.jmatch) == MatchStrategy.first);
    static assert(resolveMatch!(Toml, S.jmatch) == MatchStrategy.exactlyOne); // !Json inert under Toml
    static assert(resolveMatch!(Toml, S.amatch) == MatchStrategy.first);      // AnyFormat applies
}

/// Index of the first `WireConvert` type UDA on `sym` whose format is `Fmt`, or
/// -1. `WireConvert` is a type UDA, so its format is read from the template
/// arguments rather than an instance field.
private template firstConvert(alias sym, Fmt)
{
    import std.traits : TemplateArgsOf;

    enum ptrdiff_t firstConvert = () {
        static foreach (i, uda; getUDAs!(sym, WireConvert))
            static if (is(TemplateArgsOf!(uda)[2] == Fmt))
                return cast(ptrdiff_t) i;
        return cast(ptrdiff_t)(-1);
    }();
}

/// Whether a `WireConvert` applies for format `F` across `syms` (field then type),
/// for `F` or `AnyFormat` (§8).
template hasConvert(F, syms...)
{
    static if (syms.length == 0)
        enum hasConvert = false;
    else
        enum hasConvert = firstConvert!(syms[0], F) >= 0
            || firstConvert!(syms[0], AnyFormat) >= 0
            || hasConvert!(F, syms[1 .. $]);
}

/// The resolved `WireConvert` type for format `F` across `syms` (field override(s)
/// first, then the type; exact `F` over `AnyFormat`). Access its transforms via
/// `.to` / `.from`. Instantiable only when $(LREF hasConvert) is true.
template convertOf(F, syms...)
if (hasConvert!(F, syms))
{
    alias sym = syms[0];
    static if (firstConvert!(sym, F) >= 0)
        alias convertOf = getUDAs!(sym, WireConvert)[firstConvert!(sym, F)];
    else static if (firstConvert!(sym, AnyFormat) >= 0)
        alias convertOf = getUDAs!(sym, WireConvert)[firstConvert!(sym, AnyFormat)];
    else
        alias convertOf = convertOf!(F, syms[1 .. $]);
}

@("wired.policy.resolve.convert")
@safe pure unittest
{
    struct Json
    {
    }

    struct Toml
    {
    }

    static struct S
    {
        int plain;
        @WireConvert!(x => x + 1, x => x - 1) int any;
        @WireConvert!(x => x * 10, x => x / 10, Json) int json;
        @WireConvert!(x => x + 1, x => x - 1)
        @WireConvert!(x => x * 10, x => x / 10, Json) int both;
    }

    static assert(!hasConvert!(Json, S.plain));
    static assert(hasConvert!(Json, S.any));

    // AnyFormat converter applies under any format.
    static assert(convertOf!(Json, S.any).to(4) == 5);
    static assert(convertOf!(Toml, S.any).from(5) == 4);

    // Exact-format converter wins over the AnyFormat one under its format...
    static assert(convertOf!(Json, S.both).to(3) == 30);
    // ...but the AnyFormat one still applies under a different format.
    static assert(convertOf!(Toml, S.both).to(3) == 4);
}

/// The first value in `names` that equals an earlier one, or `null` when all are
/// distinct. CTFE helper for the uniqueness checks (§5.5).
private string firstDuplicate(const(string)[] names)
{
    foreach (i, n; names)
        foreach (m; names[0 .. i])
            if (n == m)
                return n;
    return null;
}

/// Compile-time check that enum `E`'s resolved member names are unique under
/// format `F` (after `WireName` and `WireCase` resolution) — the requirement for
/// serializing `E` by `Repr.name` (§5.5). Evaluates to `true`, or fails a
/// `static assert` naming the colliding name.
template checkUniqueMemberNames(F, E)
if (is(E == enum))
{
    private enum style = resolveCaseStyle!(F, E);
    private enum string[] names = () {
        string[] r;
        static foreach (m; __traits(allMembers, E))
            r ~= wireName!(F, __traits(getMember, E, m), style);
        return r;
    }();
    private enum dup = firstDuplicate(names);
    static assert(dup is null,
        "wired: duplicate member name \"" ~ dup ~ "\" for enum " ~ E.stringof
        ~ " under format " ~ F.stringof);
    enum checkUniqueMemberNames = true;
}

/// Compile-time check that aggregate `S`'s resolved field keys are unique under
/// format `F` (after field `WireName` and aggregate `WireCase` resolution, §5.5).
/// Evaluates to `true`, or fails a `static assert` naming the colliding key.
template checkUniqueFieldKeys(F, S)
if (is(S == struct))
{
    private enum style = resolveCaseStyle!(F, S);
    private enum string[] keys = () {
        string[] r;
        static foreach (i, field; S.tupleof)
            r ~= wireName!(F, S.tupleof[i], style);
        return r;
    }();
    private enum dup = firstDuplicate(keys);
    static assert(dup is null,
        "wired: duplicate field key \"" ~ dup ~ "\" for " ~ S.stringof
        ~ " under format " ~ F.stringof);
    enum checkUniqueFieldKeys = true;
}

@("wired.policy.uniqueness")
@safe pure unittest
{
    struct Json
    {
    }

    // The CTFE duplicate finder.
    static assert(firstDuplicate(["a", "b", "c"]) is null);
    static assert(firstDuplicate(["a", "b", "a"]) == "a");

    // Distinct resolved names/keys pass.
    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode { fastPath, @WireName!Json("turbo") slowPath }
    static assert(checkUniqueMemberNames!(Json, Mode));

    static struct S
    {
        @WireName!Json("id") int identifier;
        int count;
    }
    static assert(checkUniqueFieldKeys!(Json, S));

    // A rename collision is detected by the finder (a real one would fail the
    // static assert at compile time).
    @WireCase!Json(CaseStyle.snakeCase)
    enum Clash { fastPath, @WireName!Json("fast_path") slowPath }
    enum names = () {
        string[] r;
        static foreach (m; __traits(allMembers, Clash))
            r ~= wireName!(Json, __traits(getMember, Clash, m), resolveCaseStyle!(Json, Clash));
        return r;
    }();
    static assert(firstDuplicate(names) == "fast_path");
}

/// Index of the first `Attr` UDA on `sym` with format `Fmt` and `.target == tgt`,
/// or -1. Target-filtered variant of $(LREF firstAttr) for `WireCase`/`WireRepr`.
private template firstAttrTarget(alias sym, alias Attr, Fmt, WireTarget tgt)
{
    enum ptrdiff_t firstAttrTarget = () {
        static foreach (i, uda; getUDAs!(sym, Attr))
            static if (is(typeof(uda).Format == Fmt))
                if (uda.target == tgt)
                    return cast(ptrdiff_t) i;
        return cast(ptrdiff_t)(-1);
    }();
}

/// The `CaseStyle` resolved for the `slot` branch of `field` (whose target type
/// at that slot is `Type`) under format `F`, following the §5.2 lattice:
/// targeted-field `!F` → targeted-field `!Any` → broad-field `!F` → broad-field
/// `!Any` → type `!F` → type `!Any` → `CaseStyle.original`. `slot` is
/// `WireTarget.key` or `WireTarget.value`; `WireTarget.all` skips the targeted
/// rows.
template resolveCaseFor(F, WireTarget slot, alias field, Type)
{
    enum CaseStyle resolveCaseFor = () {
        static if (slot != WireTarget.all && firstAttrTarget!(field, WireCaseAttr, F, slot) >= 0)
            return getUDAs!(field, WireCaseAttr)[firstAttrTarget!(field, WireCaseAttr, F, slot)].style;
        else static if (slot != WireTarget.all && firstAttrTarget!(field, WireCaseAttr, AnyFormat, slot) >= 0)
            return getUDAs!(field, WireCaseAttr)[firstAttrTarget!(field, WireCaseAttr, AnyFormat, slot)].style;
        else static if (firstAttrTarget!(field, WireCaseAttr, F, WireTarget.all) >= 0)
            return getUDAs!(field, WireCaseAttr)[firstAttrTarget!(field, WireCaseAttr, F, WireTarget.all)].style;
        else static if (firstAttrTarget!(field, WireCaseAttr, AnyFormat, WireTarget.all) >= 0)
            return getUDAs!(field, WireCaseAttr)[firstAttrTarget!(field, WireCaseAttr, AnyFormat, WireTarget.all)].style;
        else static if (firstAttrTarget!(Type, WireCaseAttr, F, WireTarget.all) >= 0)
            return getUDAs!(Type, WireCaseAttr)[firstAttrTarget!(Type, WireCaseAttr, F, WireTarget.all)].style;
        else static if (firstAttrTarget!(Type, WireCaseAttr, AnyFormat, WireTarget.all) >= 0)
            return getUDAs!(Type, WireCaseAttr)[firstAttrTarget!(Type, WireCaseAttr, AnyFormat, WireTarget.all)].style;
        else
            return CaseStyle.original;
    }();
}

/// The `Repr` resolved for the `slot` branch of `field` (whose enum at that slot
/// is `E`) under `F`, following the same §5.2 lattice as $(LREF resolveCaseFor),
/// defaulting to `Repr.name`.
template resolveReprFor(F, WireTarget slot, alias field, E)
{
    enum Repr resolveReprFor = () {
        static if (slot != WireTarget.all && firstAttrTarget!(field, WireReprAttr, F, slot) >= 0)
            return getUDAs!(field, WireReprAttr)[firstAttrTarget!(field, WireReprAttr, F, slot)].repr;
        else static if (slot != WireTarget.all && firstAttrTarget!(field, WireReprAttr, AnyFormat, slot) >= 0)
            return getUDAs!(field, WireReprAttr)[firstAttrTarget!(field, WireReprAttr, AnyFormat, slot)].repr;
        else static if (firstAttrTarget!(field, WireReprAttr, F, WireTarget.all) >= 0)
            return getUDAs!(field, WireReprAttr)[firstAttrTarget!(field, WireReprAttr, F, WireTarget.all)].repr;
        else static if (firstAttrTarget!(field, WireReprAttr, AnyFormat, WireTarget.all) >= 0)
            return getUDAs!(field, WireReprAttr)[firstAttrTarget!(field, WireReprAttr, AnyFormat, WireTarget.all)].repr;
        else static if (firstAttrTarget!(E, WireReprAttr, F, WireTarget.all) >= 0)
            return getUDAs!(E, WireReprAttr)[firstAttrTarget!(E, WireReprAttr, F, WireTarget.all)].repr;
        else static if (firstAttrTarget!(E, WireReprAttr, AnyFormat, WireTarget.all) >= 0)
            return getUDAs!(E, WireReprAttr)[firstAttrTarget!(E, WireReprAttr, AnyFormat, WireTarget.all)].repr;
        else
            return Repr.name;
    }();
}

@("wired.policy.resolve.targetedSlots")
@safe pure unittest
{
    struct Json
    {
    }

    enum Mode { off, on }
    enum Status { good, bad }

    static struct S
    {
        // §5.2 example: Mode keys by value; Status values by name.
        @WireRepr!Json(Repr.name)
        @WireRepr!Json(Repr.value, WireTarget.key)
        Status[Mode] states;

        // value-slot recasing reaches the array element enum.
        @WireCase!Json(CaseStyle.snakeCase, WireTarget.value)
        Mode[] modes;
    }

    // Targeted key wins for the key slot; broad applies to the value slot.
    static assert(resolveReprFor!(Json, WireTarget.key, S.states, Mode) == Repr.value);
    static assert(resolveReprFor!(Json, WireTarget.value, S.states, Status) == Repr.name);

    // Value-targeted case reaches the element; the (absent) key slot falls back.
    static assert(resolveCaseFor!(Json, WireTarget.value, S.modes, Mode) == CaseStyle.snakeCase);
    static assert(resolveCaseFor!(Json, WireTarget.all, S.states, Status) == CaseStyle.original);
}
