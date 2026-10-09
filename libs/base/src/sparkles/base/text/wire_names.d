/**
How a member is spelled in a format: the one resolution rule behind every
format-aware enum name, shared by the text writers and readers and by
`sparkles:wired`'s serde backends.

The vocabulary — the format tags and the `@WireName`, `@WireCase` and
`@WireRepr` attributes — is data in $(MREF sparkles,metadata,wire); this module
decides which attribute wins for a format `F`:

$(OL
    $(LI an attribute tagged with `F` itself;)
    $(LI if `F` uses wire names ($(REF NameSource, sparkles,metadata,wire)
        `.wire`, the default), one tagged $(REF AnyFormat, sparkles,metadata,wire);)
    $(LI otherwise the default: the D identifier, recased by the type's
        resolved $(REF CaseStyle, sparkles,metadata,case_style); `Repr.name`.)
)

So an identifier format — `Pretty`, `DSource` — spells a serde-annotated enum
by its D identifiers unless it is annotated for that format specifically.
Resolution sees member- and type-level attributes only: a field-level override
is a serde concern, resolved by `sparkles:wired` on top of this.
*/
module sparkles.base.text.wire_names;

import std.traits : getUDAs;

public import sparkles.metadata.wire;
import sparkles.base.text.case_style : convertCase;

private bool anyAttr(A)(A) => true;
private bool broadTarget(A)(A a) => a.target == WireTarget.all;

/// Index of the first `Attr` attribute on `sym` whose format is exactly `Fmt`
/// and that passes `pred`, or -1.
private template firstFormatAttr(alias sym, alias Attr, Fmt, alias pred)
{
    enum ptrdiff_t firstFormatAttr = () {
        static foreach (i, uda; getUDAs!(sym, Attr))
            static if (is(typeof(uda).Format == Fmt))
                if (pred(uda))
                    return cast(ptrdiff_t) i;
        return cast(ptrdiff_t)(-1);
    }();
}

/**
The `Attr` attribute on `sym` that applies under format `F` and passes
`pred`: one tagged `F` first, then — only when `F` uses wire names — one tagged
`AnyFormat`. `found` says whether one did; `uda` exists only when it did. An
unannotated symbol, the common case in a type walk, short-circuits before any
`getUDAs` scan is instantiated.
*/
template pickFormatAttr(alias sym, alias Attr, F, alias pred = anyAttr)
{
    static if (__traits(getAttributes, sym).length == 0)
        enum found = false;
    else static if (firstFormatAttr!(sym, Attr, F, pred) >= 0)
    {
        enum found = true;
        enum uda = getUDAs!(sym, Attr)[firstFormatAttr!(sym, Attr, F, pred)];
    }
    else static if (nameSourceOf!F == NameSource.wire
        && firstFormatAttr!(sym, Attr, AnyFormat, pred) >= 0)
    {
        enum found = true;
        enum uda = getUDAs!(sym, Attr)[firstFormatAttr!(sym, Attr, AnyFormat, pred)];
    }
    else
        enum found = false;
}

/// Whether `symbol` carries a `@WireName` that applies under format `F`.
template hasExplicitWireName(F, alias symbol)
{
    enum hasExplicitWireName = pickFormatAttr!(symbol, WireNameAttr, F).found;
}

/// The case style type `T`'s names take under format `F`: its broad
/// (`WireTarget.all`) `@WireCase` that applies under `F`, else `original`.
template resolveCaseStyle(F, T)
{
    private alias p = pickFormatAttr!(T, WireCaseAttr, F, broadTarget);
    static if (p.found)
        enum CaseStyle resolveCaseStyle = p.uda.style;
    else
        enum CaseStyle resolveCaseStyle = CaseStyle.original;
}

/// How enum `T` is written under format `F`: its broad `@WireRepr` that
/// applies under `F`, else by name.
template resolveRepr(F, T)
{
    private alias p = pickFormatAttr!(T, WireReprAttr, F, broadTarget);
    static if (p.found)
        enum Repr resolveRepr = p.uda.repr;
    else
        enum Repr resolveRepr = Repr.name;
}

/**
The names of `E`'s members under format `F` at case `style` (by default the
type's own, $(LREF resolveCaseStyle)), in declaration order, computed in one
compile-time pass: the member's `@WireName` that applies under `F`, else its
identifier recased. The names must be unique; a clash is a compile error.
*/
template enumNames(F, E, CaseStyle style = resolveCaseStyle!(F, E))
if (is(E == enum))
{
    // `static immutable` so a per-member `enumNames[i]` read does not copy
    // the whole array.
    static immutable string[] enumNames = () {
        string[] r;
        static foreach (m; __traits(allMembers, E))
        {{
            alias p = pickFormatAttr!(__traits(getMember, E, m), WireNameAttr, F);
            static if (p.found)
                r ~= p.uda.name;
            else
                r ~= convertCase!style(m);
        }}
        return r;
    }();

    private enum dupName = firstDuplicate(enumNames);
    static assert(dupName is null,
        "duplicate member name \"" ~ dupName ~ "\" for enum " ~ E.stringof
        ~ " under format " ~ F.stringof);
}

/// The first name in `names` that occurs twice, or `null`.
string firstDuplicate(const(string)[] names) @safe pure nothrow
{
    foreach (i, a; names)
        foreach (b; names[i + 1 .. $])
            if (a == b)
                return a;
    return null;
}

///
@("text.wire_names.formatsResolveNamesByTheirSource")
@safe pure nothrow unittest
{
    struct Json
    {
    }

    @WireCase(CaseStyle.kebabCase)
    enum Mode
    {
        fastPath,
        @WireName("slow") slowPath,
        @WireName!Pretty("SLOW") @WireName!Json("turbo") turboPath,
    }

    // A wire format: its own tag, then AnyFormat, then the identifier recased
    // by the AnyFormat case.
    static assert(enumNames!(Json, Mode) == ["fast-path", "slow", "turbo"]);
    // An identifier format ignores AnyFormat names and case, but honours its
    // own tag.
    static assert(enumNames!(Pretty, Mode) == ["fastPath", "slowPath", "SLOW"]);
    static assert(enumNames!(DSource, Mode) == ["fastPath", "slowPath", "turboPath"]);
    // AnyFormat itself is a wire format.
    static assert(enumNames!(AnyFormat, Mode) == ["fast-path", "slow", "turbo-path"]);

    static assert(resolveCaseStyle!(Json, Mode) == CaseStyle.kebabCase);
    static assert(resolveCaseStyle!(Pretty, Mode) == CaseStyle.original);
    static assert(hasExplicitWireName!(Json, Mode.slowPath));
    static assert(!hasExplicitWireName!(DSource, Mode.slowPath));
}

@("text.wire_names.reprFollowsTheFormat")
@safe pure nothrow unittest
{
    struct Json
    {
    }

    struct Toml
    {
    }

    @WireRepr!Json(Repr.value) enum Priority { low, high }
    @WireRepr(Repr.value) enum Level { a, b }

    static assert(resolveRepr!(Json, Priority) == Repr.value);
    static assert(resolveRepr!(Toml, Priority) == Repr.name);
    static assert(resolveRepr!(Toml, Level) == Repr.value);
    static assert(resolveRepr!(Pretty, Level) == Repr.name, "identifier formats skip AnyFormat");
}

@("text.wire_names.firstDuplicate")
@safe pure nothrow unittest
{
    static assert(firstDuplicate(["a", "b", "c"]) is null);
    static assert(firstDuplicate(["a", "b", "a"]) == "a");
}
