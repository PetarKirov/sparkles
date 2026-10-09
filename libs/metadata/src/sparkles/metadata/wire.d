/**
The format vocabulary: the tags that name a serialization format, and the
`@WireName`, `@WireCase` and `@WireRepr` attributes that say how an enum member
or a field is spelled in one.

$(B A format is the context.) An enum has several reasonable spellings — a
pretty-printed dump, a D string mixin, a JSON string, a JSON number, a theme
file's leaf — and the format being written decides which. Each attribute is
tagged with the format it applies under: `@WireName!Json("x")` for one format,
`@WireName("x")` ($(LREF AnyFormat)) for every format that uses wire names.

$(B Name sources.) A format tag may declare `enum nameSource`
($(LREF NameSource)). A $(LREF NameSource.wire) format (the default: JSON, a
theme file, CLI arguments) honours `AnyFormat` names. A
$(LREF NameSource.identifier) format ($(LREF Pretty), $(LREF DSource)) spells
a member by its D identifier and honours only attributes tagged with itself, so
a type annotated for serde needs nothing extra to be dumped or turned into
compilable D.

This module holds data only. Resolution — which attribute wins for a format —
is `sparkles.base.text.wire_names`; the serde backends are `sparkles:wired`.
*/
module sparkles.metadata.wire;

public import sparkles.metadata.case_style : CaseStyle;

/// The sentinel format: an untagged `@Wire*` attribute applies under every
/// format whose $(LREF NameSource) is `wire`.
struct AnyFormat
{
}

/// Where a format's member and field names come from.
enum NameSource
{
    wire,       /// `@WireName!F`, then `@WireName` (any format), then the identifier
    identifier, /// `@WireName!F`, then the D identifier; `AnyFormat` names ignored
}

/// The pretty-printing format (`prettyPrint`, `writeValue`): a debugging view,
/// so a member is spelled as in the source a developer greps.
struct Pretty
{
    enum nameSource = NameSource.identifier; ///
}

/// The D-source format: string mixins and generated code, where a member must
/// be spelled as compilable D. `@WireName!DSource` customises the rare case.
struct DSource
{
    enum nameSource = NameSource.identifier; ///
}

/// The name source of format `F`: its `nameSource` member, else `wire`.
template nameSourceOf(F)
{
    static if (is(typeof(F.nameSource) : NameSource))
        enum NameSource nameSourceOf = F.nameSource;
    else
        enum NameSource nameSourceOf = NameSource.wire;
}

/// Enum serialization representation — by member name or underlying value.
enum Repr
{
    name,  /// the member's serialized name
    value, /// the member's underlying value (via `OriginalType`)
}

/// Which slot of a wrapped field a slot-targeted `WireCase`/`WireRepr` applies
/// to.
enum WireTarget
{
    all,   /// every eligible target on any branch (the default)
    key,   /// only enums reached in an associative-array key position
    value, /// only the value branch (array element, AA value, nullable contained)
}

/// The attribute produced by $(LREF WireName): an explicit member/field name
/// tagged with the format it applies under.
struct WireNameAttr(Format_ = AnyFormat)
{
    string name;           /// the explicit wire name
    alias Format = Format_; /// the format this name applies under
}

/// `@WireName!F("text")` — the member or field name under format `F`.
WireNameAttr!Format WireName(Format = AnyFormat)(string name) @safe pure nothrow @nogc
    => WireNameAttr!Format(name);

/// The attribute produced by $(LREF WireCase).
struct WireCaseAttr(Format_ = AnyFormat)
{
    CaseStyle style;                    /// the case to recase into
    WireTarget target = WireTarget.all; /// which slot the recasing applies to
    alias Format = Format_;             /// the format this recasing applies under
}

/// `@WireCase!F(style[, target])` — recase member/field names under `F`.
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

/// `@WireRepr!F(repr[, target])` — write an enum by member name vs underlying
/// value under `F`.
WireReprAttr!Format WireRepr(Format = AnyFormat)(
    Repr repr, WireTarget target = WireTarget.all) @safe pure nothrow @nogc
    => WireReprAttr!Format(repr, target);

@("metadata.wire.attributesCarryTheirFormat")
@safe pure nothrow @nogc unittest
{
    struct Json
    {
    }

    enum n = WireName("x");
    static assert(is(typeof(n) == WireNameAttr!AnyFormat) && n.name == "x");
    enum j = WireName!Json("y");
    static assert(is(typeof(j).Format == Json));
    static assert(WireCase(CaseStyle.kebabCase).style == CaseStyle.kebabCase);
    static assert(WireRepr!Json(Repr.value).repr == Repr.value);

    // A tag without `nameSource` uses wire names; the identifier formats say so.
    static assert(nameSourceOf!Json == NameSource.wire);
    static assert(nameSourceOf!AnyFormat == NameSource.wire);
    static assert(nameSourceOf!Pretty == NameSource.identifier);
    static assert(nameSourceOf!DSource == NameSource.identifier);
}
