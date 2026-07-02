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

/// A $(LREF firstAttr) predicate matching UDAs whose `.target` is `tgt`. One
/// shared predicate template keeps broad and slot-targeted scans of the same
/// symbol on the same memoized `firstAttr` instantiations.
private template targetIs(WireTarget tgt)
{
    alias targetIs = (a) => a.target == tgt;
}

private alias broadTarget = targetIs!(WireTarget.all);
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

/// The first `Attr` UDA on `sym` passing `pred`, preferring an exact-`F` tag
/// over `AnyFormat` — the one resolution rule every `@Wire*` attribute follows
/// (§5.1). `found` tells whether one matched; `uda` exists only when it did.
/// The `AnyFormat` scan is not instantiated when the exact-`F` scan hits, and
/// an unannotated symbol — the overwhelmingly common case in a type walk —
/// short-circuits before any `getUDAs` scan is instantiated at all.
private template pickAttr(alias sym, alias Attr, F, alias pred)
{
    static if (__traits(getAttributes, sym).length == 0)
        enum found = false;
    else static if (firstAttr!(sym, Attr, F, pred) >= 0)
    {
        enum found = true;
        enum uda = getUDAs!(sym, Attr)[firstAttr!(sym, Attr, F, pred)];
    }
    else static if (firstAttr!(sym, Attr, AnyFormat, pred) >= 0)
    {
        enum found = true;
        enum uda = getUDAs!(sym, Attr)[firstAttr!(sym, Attr, AnyFormat, pred)];
    }
    else
        enum found = false;
}

/// $(LREF pickAttr) across `syms` in order — field override(s) first, then the
/// type — each stop preferring exact-`F` over `AnyFormat`.
private template pickAttrAcross(alias Attr, alias pred, F, syms...)
{
    static if (syms.length == 0)
        enum found = false;
    else static if (pickAttr!(syms[0], Attr, F, pred).found)
    {
        enum found = true;
        enum uda = pickAttr!(syms[0], Attr, F, pred).uda;
    }
    else
    {
        private alias rest = pickAttrAcross!(Attr, pred, F, syms[1 .. $]);
        enum found = rest.found;
        static if (rest.found)
            enum uda = rest.uda;
    }
}

/// The `CaseStyle` resolved for format `F` across `syms` (field override(s) first,
/// then the type), preferring an exact-`F` `WireCase` over its `AnyFormat` form,
/// and falling back to `CaseStyle.original`. Only broad (`WireTarget.all`)
/// `WireCase` participates here.
template resolveCaseStyle(F, syms...)
{
    private alias p = pickAttrAcross!(WireCaseAttr, broadTarget, F, syms);
    static if (p.found)
        enum CaseStyle resolveCaseStyle = p.uda.style;
    else
        enum CaseStyle resolveCaseStyle = CaseStyle.original;
}

/// The `Repr` resolved for format `F` across `syms` (field override(s) first, then
/// the type), preferring exact-`F` over `AnyFormat`, defaulting to `Repr.name`.
/// Only broad (`WireTarget.all`) `WireRepr` participates here.
template resolveRepr(F, syms...)
{
    private alias p = pickAttrAcross!(WireReprAttr, broadTarget, F, syms);
    static if (p.found)
        enum Repr resolveRepr = p.uda.repr;
    else
        enum Repr resolveRepr = Repr.name;
}

/// The wire name of enum member (or aggregate field) `sym` under format `F`,
/// given the resolved case `style`: an explicit `@WireName!F` wins, then
/// `@WireName!Any`, else the identifier recased by `convertCase!style`.
template wireName(F, alias sym, CaseStyle style)
{
    private alias p = pickAttr!(sym, WireNameAttr, F, anyAttr);
    static if (p.found)
        enum string wireName = p.uda.name;
    else
        enum string wireName = convertCase!style(__traits(identifier, sym));
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
    pickAttr!(field, WireOptionalAttr, F, anyAttr).found;

/// The resolved `@WireOptional` policy for `field` under `F` (exact `F` over
/// `AnyFormat`). Instantiable only when $(LREF isOptional) is true.
template optionalPolicy(F, alias field)
if (isOptional!(F, field))
{
    enum optionalPolicy = pickAttr!(field, WireOptionalAttr, F, anyAttr).uda;
}

/// The `SumType` decode strategy resolved for `field` under `F`: a
/// `@(WireMatch.…!F)`, then `@(WireMatch.…!Any)`, else `MatchStrategy.exactlyOne`
/// (§4.7).
template resolveMatch(F, alias field)
{
    private alias p = pickAttr!(field, WireMatchPolicy, F, anyAttr);
    static if (p.found)
        enum MatchStrategy resolveMatch = p.uda.strategy;
    else
        enum MatchStrategy resolveMatch = MatchStrategy.exactlyOne;
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
/// for `F` or `AnyFormat` (§8). An unannotated symbol skips the `getUDAs` scans.
template hasConvert(F, syms...)
{
    static if (syms.length == 0)
        enum hasConvert = false;
    else static if (__traits(getAttributes, syms[0]).length == 0)
        enum hasConvert = hasConvert!(F, syms[1 .. $]);
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
    bool[string] seen;
    foreach (n; names)
    {
        if (n in seen)
            return n;
        seen[n] = true;
    }
    return null;
}

/// Compile-time check that enum `E`'s resolved member names are unique under
/// format `F` (after `WireName` and `WireCase` resolution) — the requirement for
/// serializing `E` by `Repr.name` (§5.5). Evaluates to `true`, or fails a
/// `static assert` naming the colliding name.
template checkUniqueMemberNames(F, E)
if (is(E == enum))
{
    private enum dup = firstDuplicate(wireNames!(F, E, resolveCaseStyle!(F, E)));
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
    private enum dup = () {
        string[] keys;
        foreach (p; fieldPolicies!(F, S))
            keys ~= p.key;
        return firstDuplicate(keys);
    }();
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

/// The §5.2 lattice shared by the slot-targeted resolvers: targeted-field
/// (`!F` then `!Any`) → broad-field (`!F` then `!Any`) → broad on the slot
/// type (`!F` then `!Any`). `slot == WireTarget.all` skips the targeted rows.
private template pickSlotAttr(alias Attr, F, WireTarget slot, alias field, Type)
{
    static if (slot != WireTarget.all && pickAttr!(field, Attr, F, targetIs!slot).found)
    {
        enum found = true;
        enum uda = pickAttr!(field, Attr, F, targetIs!slot).uda;
    }
    else static if (pickAttr!(field, Attr, F, broadTarget).found)
    {
        enum found = true;
        enum uda = pickAttr!(field, Attr, F, broadTarget).uda;
    }
    else static if (pickAttr!(Type, Attr, F, broadTarget).found)
    {
        enum found = true;
        enum uda = pickAttr!(Type, Attr, F, broadTarget).uda;
    }
    else
        enum found = false;
}

/// The `CaseStyle` resolved for the `slot` branch of `field` (whose target type
/// at that slot is `Type`) under format `F`, following the §5.2 lattice:
/// targeted-field `!F` → targeted-field `!Any` → broad-field `!F` → broad-field
/// `!Any` → type `!F` → type `!Any` → `CaseStyle.original`. `slot` is
/// `WireTarget.key` or `WireTarget.value`; `WireTarget.all` skips the targeted
/// rows.
template resolveCaseFor(F, WireTarget slot, alias field, Type)
{
    private alias p = pickSlotAttr!(WireCaseAttr, F, slot, field, Type);
    static if (p.found)
        enum CaseStyle resolveCaseFor = p.uda.style;
    else
        enum CaseStyle resolveCaseFor = CaseStyle.original;
}

/// The `Repr` resolved for the `slot` branch of `field` (whose enum at that slot
/// is `E`) under `F`, following the same §5.2 lattice as $(LREF resolveCaseFor),
/// defaulting to `Repr.name`.
template resolveReprFor(F, WireTarget slot, alias field, E)
{
    private alias p = pickSlotAttr!(WireReprAttr, F, slot, field, E);
    static if (p.found)
        enum Repr resolveReprFor = p.uda.repr;
    else
        enum Repr resolveReprFor = Repr.name;
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

// ─────────────────────────────────────────────────────────────────────────────
// Aggregated policy gathering
// ─────────────────────────────────────────────────────────────────────────────
//
// The fine-grained resolvers above answer one question about one symbol and are
// the normative §5 semantics. A format backend walking a whole aggregate would
// ask them ~10 times per field, instantiating a getUDAs scan each time. The
// aggregated views below make one pass per (format, type) instead, reading
// `__traits(getAttributes, …)` inline in a single CTFE initializer and reducing
// every value-carrying attribute to a plain data table the walk indexes into.
// Only `@WireConvert` stays on the per-symbol path — it carries alias transforms
// that cannot live in a value.

/// Recases `ident` under a run-time `style` — the dispatch `convertCase` needs
/// when the style is a CTFE value rather than a template argument.
private string convertCaseOf(CaseStyle style, string ident) @safe pure
{
    final switch (style)
    {
        static foreach (m; __traits(allMembers, CaseStyle))
        {
            case __traits(getMember, CaseStyle, m):
                return convertCase!(__traits(getMember, CaseStyle, m))(ident);
        }
    }
}

/// The value-level policy of one aggregate field under a format: everything the
/// struct walk needs about the field except its (alias-carrying) `@WireConvert`.
/// Produced by $(LREF fieldPolicies); the slot lattice is finished by
/// $(LREF caseFor) / $(LREF reprFor) once the slot type's own policy is known.
struct FieldPolicy
{
    string key;                 /// the resolved wire key (§5.1, §6)
    bool optional;              /// carries `@WireOptional` (§5.4)
    WireSkip skip = WireSkip.never;                 /// encode omission policy
    WireInvalid onInvalid = WireInvalid.reject;     /// present-but-invalid policy
    MatchStrategy match = MatchStrategy.exactlyOne; /// `SumType` strategy (§4.7)
    bool[3] hasCase;            /// field-level `WireCase` present, per target
    CaseStyle[3] caseStyle;     /// … and its style, per target
    bool[3] hasRepr;            /// field-level `WireRepr` present, per target
    Repr[3] repr;               /// … and its repr, per target

    /// The §5.2-resolved `CaseStyle` for `slot`, given `typeStyle` — the slot
    /// type's own broad resolution (which already folds in the default).
    CaseStyle caseFor(WireTarget slot, CaseStyle typeStyle) const @safe pure nothrow @nogc
    {
        if (slot != WireTarget.all && hasCase[slot])
            return caseStyle[slot];
        if (hasCase[WireTarget.all])
            return caseStyle[WireTarget.all];
        return typeStyle;
    }

    /// The §5.2-resolved `Repr` for `slot`, given `typeRepr` — the slot type's
    /// own broad resolution (which already folds in the default).
    Repr reprFor(WireTarget slot, Repr typeRepr) const @safe pure nothrow @nogc
    {
        if (slot != WireTarget.all && hasRepr[slot])
            return repr[slot];
        if (hasRepr[WireTarget.all])
            return repr[WireTarget.all];
        return typeRepr;
    }
}

/// The per-field policies of aggregate `T` under format `F`, resolved in one
/// compile-time pass: one entry per field of `T.tupleof`, excluding the hidden
/// context pointer of a nested struct. Exact-`F` attributes win over `AnyFormat`
/// ones, first-written wins within a tier, and field keys apply an explicit
/// `@WireName` else the identifier recased by `T`'s aggregate `@WireCase` (§5.1).
template fieldPolicies(F, T)
if (is(T == struct))
{
    // `static immutable`, not `enum`: a manifest-constant array is re-copied at
    // every use site (each `fieldPolicies!(F, T)[i]` would re-materialize all N
    // entries in CTFE — O(N²) over a struct walk); this is built once and its
    // reads constant-fold.
    static immutable FieldPolicy[] fieldPolicies = () {
        // Tier per slot: 0 = unset, 1 = AnyFormat, 2 = exact-F; higher wins,
        // first-written wins within a tier (matching pickAttr's scan order).
        int aggTier = 0;
        CaseStyle aggStyle = CaseStyle.original;
        static foreach (uda; __traits(getAttributes, T))
        {
            static if (is(typeof(uda) == WireCaseAttr!F))
            {
                if (uda.target == WireTarget.all && aggTier < 2)
                {
                    aggStyle = uda.style;
                    aggTier = 2;
                }
            }
            else static if (is(typeof(uda) == WireCaseAttr!AnyFormat))
            {
                if (uda.target == WireTarget.all && aggTier < 1)
                {
                    aggStyle = uda.style;
                    aggTier = 1;
                }
            }
        }

        FieldPolicy[] r;
        static foreach (i; 0 .. T.tupleof.length - __traits(isNested, T))
        {{
            FieldPolicy p;
            string explicitName;
            int nameTier, optTier, matchTier;
            int[3] caseTier, reprTier;

            static foreach (uda; __traits(getAttributes, T.tupleof[i]))
            {{
                static if (is(typeof(uda) == WireNameAttr!F))
                    enum tier = 2;
                else static if (is(typeof(uda) == WireNameAttr!AnyFormat))
                    enum tier = 1;
                static if (is(typeof(tier)))
                {
                    if (nameTier < tier)
                    {
                        explicitName = uda.name;
                        nameTier = tier;
                    }
                }

                static if (is(typeof(uda) == WireCaseAttr!F))
                    enum caseT = 2;
                else static if (is(typeof(uda) == WireCaseAttr!AnyFormat))
                    enum caseT = 1;
                static if (is(typeof(caseT)))
                {
                    if (caseTier[uda.target] < caseT)
                    {
                        p.hasCase[uda.target] = true;
                        p.caseStyle[uda.target] = uda.style;
                        caseTier[uda.target] = caseT;
                    }
                }

                static if (is(typeof(uda) == WireReprAttr!F))
                    enum reprT = 2;
                else static if (is(typeof(uda) == WireReprAttr!AnyFormat))
                    enum reprT = 1;
                static if (is(typeof(reprT)))
                {
                    if (reprTier[uda.target] < reprT)
                    {
                        p.hasRepr[uda.target] = true;
                        p.repr[uda.target] = uda.repr;
                        reprTier[uda.target] = reprT;
                    }
                }

                static if (is(typeof(uda) == WireOptionalAttr!F))
                    enum optT = 2;
                else static if (is(typeof(uda) == WireOptionalAttr!AnyFormat))
                    enum optT = 1;
                static if (is(typeof(optT)))
                {
                    if (optTier < optT)
                    {
                        p.optional = true;
                        p.skip = uda.skip;
                        p.onInvalid = uda.onInvalid;
                        optTier = optT;
                    }
                }

                static if (is(typeof(uda) == WireMatchPolicy!F))
                    enum matchT = 2;
                else static if (is(typeof(uda) == WireMatchPolicy!AnyFormat))
                    enum matchT = 1;
                static if (is(typeof(matchT)))
                {
                    if (matchTier < matchT)
                    {
                        p.match = uda.strategy;
                        matchTier = matchT;
                    }
                }
            }}

            p.key = nameTier
                ? explicitName
                : convertCaseOf(aggStyle, __traits(identifier, T.tupleof[i]));
            r ~= p;
        }}
        return r;
    }();
}

/// The resolved wire names of `E`'s members under format `F` at case `style`,
/// in declaration order, computed in one compile-time pass: an explicit
/// `@WireName!F` wins, then `@WireName!Any`, else the identifier recased by
/// `convertCase!style` — member-for-member identical to $(LREF wireName).
template wireNames(F, E, CaseStyle style)
if (is(E == enum))
{
    // `static immutable` for the same reason as `fieldPolicies`: per-member
    // `names[i]` reads must not re-copy the whole array.
    static immutable string[] wireNames = () {
        string[] r;
        static foreach (m; __traits(allMembers, E))
        {{
            string explicitName;
            int nameTier;
            static foreach (uda; __traits(getAttributes, __traits(getMember, E, m)))
            {{
                static if (is(typeof(uda) == WireNameAttr!F))
                    enum tier = 2;
                else static if (is(typeof(uda) == WireNameAttr!AnyFormat))
                    enum tier = 1;
                static if (is(typeof(tier)))
                {
                    if (nameTier < tier)
                    {
                        explicitName = uda.name;
                        nameTier = tier;
                    }
                }
            }}
            r ~= nameTier ? explicitName : convertCase!style(m);
        }}
        return r;
    }();
}

// The aggregated views must agree with the fine-grained resolvers they
// summarize — every FieldPolicy component is cross-checked against the §5
// resolver answering the same question.
@("wired.policy.aggregate.matchesResolvers")
@safe pure unittest
{
    struct Json
    {
    }

    @WireCase!Json(CaseStyle.snakeCase)
    enum Mode { fastPath, @WireName!Json("turbo") slowPath }

    @WireCase!Json(CaseStyle.snakeCase)
    static struct S
    {
        @WireName!Json("id") int identifier;
        @WireCase!Json(CaseStyle.kebabCase, WireTarget.value) Mode[] modeList;
        @WireRepr(Repr.value, WireTarget.key) int[Mode] modeTable;
        @WireOptional(WireSkip.whenDefault, WireInvalid.useDefault) int optCount;
        @(WireMatch.first!Json) int matchField;
        int plainField;
    }

    alias P = fieldPolicies!(Json, S);
    enum aggStyle = resolveCaseStyle!(Json, S);
    static assert(P.length == S.tupleof.length);

    static foreach (i; 0 .. P.length)
        static assert(P[i].key == wireName!(Json, S.tupleof[i], aggStyle));

    static assert(P[1].caseFor(WireTarget.value, resolveCaseStyle!(Json, Mode))
        == resolveCaseFor!(Json, WireTarget.value, S.tupleof[1], Mode));
    static assert(P[2].reprFor(WireTarget.key, resolveRepr!(Json, Mode))
        == resolveReprFor!(Json, WireTarget.key, S.tupleof[2], Mode));
    static assert(P[2].reprFor(WireTarget.value, resolveRepr!(Json, Mode))
        == resolveReprFor!(Json, WireTarget.value, S.tupleof[2], Mode));

    static assert(P[3].optional == isOptional!(Json, S.tupleof[3]));
    static assert(P[3].skip == optionalPolicy!(Json, S.tupleof[3]).skip);
    static assert(P[3].onInvalid == optionalPolicy!(Json, S.tupleof[3]).onInvalid);
    static assert(P[4].match == resolveMatch!(Json, S.tupleof[4]));

    static assert(!P[5].optional && P[5].skip == WireSkip.never);
    static assert(P[5].match == MatchStrategy.exactlyOne);

    // Member names agree with the per-member resolver, tier by tier.
    alias names = wireNames!(Json, Mode, resolveCaseStyle!(Json, Mode));
    static assert(names == ["fast_path", "turbo"]);
    static foreach (i, m; __traits(allMembers, Mode))
        static assert(names[i]
            == wireName!(Json, __traits(getMember, Mode, m), resolveCaseStyle!(Json, Mode)));
}

// A nested struct's hidden context pointer is not a field: the policy table
// covers only declared fields.
@("wired.policy.aggregate.nestedContextPointer")
@safe pure unittest
{
    struct Json
    {
    }

    int captured = 3;
    struct Nested
    {
        int visibleField;
        int peek() => captured; // forces a context pointer
    }

    static assert(__traits(isNested, Nested));
    static assert(fieldPolicies!(Json, Nested).length == 1);
    static assert(fieldPolicies!(Json, Nested)[0].key == "visibleField");
}
