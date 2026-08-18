/**
Enum ↔ text/value conversion.

Format-agnostic primitives for an enum's two serialized forms:

$(UL
    $(LI $(LREF enumMemberName) — a value's member name, recased per a
        $(REF CaseStyle, sparkles,base,text,case_style).)
    $(LI $(LREF enumMemberNameOr) — the same, for an enum whose members are not
        distinctly valued, and for a value that may not be a declared member at
        all.)
    $(LI $(LREF enumCommonPrefix) — the prefix every member name shares, so a
        C-derived enum can be rendered without it.)
    $(LI $(LREF enumFromValue) — a membership-checked underlying value back to
        the enum.)
)

$(B Enums that come from C) are why the last three exist. A `.h` translated by
ImportC routinely declares several members with the same value — an extension
enumerator promoted to core keeps its old spelling as an alias — and every
member repeats the type's name as a prefix, because C has no enum scope. The
`final switch` in $(LREF enumMemberName) rejects the first outright (duplicate
`case` labels), and nothing here would strip the second.

The module is unopinionated — it applies no per-member name override (that is a
policy concern for a layer such as `@WireName` in `sparkles:wired`). The inverse
name direction is `readEnumString` (`sparkles.base.text.readers`); the
output-range writers are `writeEnumMemberName` / `writeEnumValue`
(`sparkles.base.text.writers`).
*/
module sparkles.base.text.enums;

import std.traits : OriginalType;

import sparkles.base.text.case_style : CaseStyle, convertCase;
import sparkles.base.text.errors : ParseExpected;

/**
The name of the declared member equal to `value`, recased per `style` as a
compile-time string literal (so the call allocates nothing).

`value` must be a declared member of `E`. The generated `final switch` rejects a
duplicate-valued enum at compile time (duplicate `case` labels) and asserts on a
value that is not a declared member.
*/
string enumMemberName(CaseStyle style = CaseStyle.original, E)(in E value)
if (is(E == enum))
{
    final switch (value)
    {
        static foreach (name; __traits(allMembers, E))
        {
            case __traits(getMember, E, name):
            {
                enum string result = convertCase!style(name);
                return result;
            }
        }
    }
}

@("text.enums.enumMemberName.defaultOriginal")
@safe pure nothrow @nogc
unittest
{
    enum Color { red, green, blue }

    assert(enumMemberName(Color.green) == "green");
}

@("text.enums.enumMemberName.recased")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fastPath, slowPath }

    assert(enumMemberName!(CaseStyle.snakeCase)(Mode.fastPath) == "fast_path");
    assert(enumMemberName!(CaseStyle.kebabCase)(Mode.slowPath) == "slow-path");
    assert(enumMemberName(Mode.fastPath) == "fastPath"); // original by default
}

/**
The name of the $(I first) declared member equal to `value`, recased per `style`
as a compile-time string literal; `fallback` when no member matches.

The total, duplicate-tolerant counterpart to $(LREF enumMemberName), and the one
to reach for on an enum translated from C. It is a `static foreach` of `if`s
rather than a `final switch` — the same shape $(LREF enumFromValue) already uses
— so neither restriction of the switch form applies:

$(UL
$(LI $(B Duplicate values are allowed), and the first declaration wins. That is
    the useful rule for a promoted extension enumerator: the header declares the
    core name before the alias that kept the old spelling.)
$(LI $(B An undeclared value returns `fallback`) instead of asserting. A value
    read back from a C library is not a declared member merely because the
    header this was compiled against had no name for it — a newer driver
    reporting an enumerator from a later spec is ordinary, not a bug.)
)

`prefix` and `suffix`, when given, are removed from the member's identifier
$(I before) it is recased. Pair `prefix` with $(LREF enumCommonPrefix) to render
a C enum without the type name every member repeats; `suffix` covers a trailing
marker the caller knows its own enum carries, such as a vendor tag. A member not
carrying an affix keeps it. Neither is stripped from `fallback`, which is the
caller's own string and carries no affix to begin with; that asymmetry is why
stripping belongs here rather than at the call site, where slicing the returned
name would run off the end of a short fallback.

The cost of both is a linear scan the switch would have had a jump table for.
For the diagnostic paths this serves that is not a consideration; where it would
be, $(LREF enumMemberName) is still there.
*/
string enumMemberNameOr(CaseStyle style = CaseStyle.original, string prefix = "",
    string suffix = "", E)
    (in E value, string fallback)
if (is(E == enum))
{
    static foreach (name; __traits(allMembers, E))
        if (value == __traits(getMember, E, name))
        {
            enum string result = convertCase!style(withoutAffixes!(name, prefix, suffix));
            return result;
        }
    return fallback;
}

// `name` less whichever of `prefix`/`suffix` it actually carries. Stripping
// before the recase rather than after is not a detail: `convertCase` to a style
// that drops separators does not preserve length, so slicing a recased name by
// the raw affix's length would cut it in the wrong place.
private template withoutAffixes(string name, string prefix, string suffix)
{
    enum string withoutAffixes = () {
        string s = name;
        if (prefix.length && s.length > prefix.length && s[0 .. prefix.length] == prefix)
            s = s[prefix.length .. $];
        if (suffix.length && s.length > suffix.length && s[$ - suffix.length .. $] == suffix)
            s = s[0 .. $ - suffix.length];
        return s;
    }();
}

@("text.enums.enumMemberNameOr.firstDeclarationWins")
@safe pure nothrow @nogc
unittest
{
    // The shape every ImportC enum has: an alias kept for source compatibility
    // after the extension was promoted to core. `enumMemberName` cannot be
    // instantiated for this enum at all.
    enum Promoted { core = 1, legacyAlias = 1, other = 2 }

    static assert(!__traits(compiles, enumMemberName(Promoted.core)),
        "the final-switch form must still reject a duplicate-valued enum");

    assert(enumMemberNameOr(Promoted.core, "?") == "core");
    assert(enumMemberNameOr(Promoted.legacyAlias, "?") == "core");
    assert(enumMemberNameOr(Promoted.other, "?") == "other");
}

@("text.enums.enumMemberNameOr.undeclaredValueTakesTheFallback")
@safe pure nothrow @nogc
unittest
{
    enum Color { red, green }

    assert(enumMemberNameOr(Color.green, "unknown") == "green");
    // What a C library hands back when it knows an enumerator this build does
    // not: a value, not a member. Asserting would be wrong.
    assert(enumMemberNameOr(cast(Color) 99, "unknown") == "unknown");
}

@("text.enums.enumMemberNameOr.recasedLikeEnumMemberName")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fastPath, slowPath }

    assert(enumMemberNameOr!(CaseStyle.kebabCase)(Mode.fastPath, "?") == "fast-path");
    assert(enumMemberNameOr!(CaseStyle.snakeCase)(Mode.slowPath, "?") == "slow_path");

    // Same answer as the switch form wherever that form is usable at all.
    assert(enumMemberNameOr(Mode.fastPath, "?") == enumMemberName(Mode.fastPath));
}

@("text.enums.enumMemberNameOr.stripsThePrefixBeforeRecasing")
@safe pure nothrow @nogc
unittest
{
    enum Mode { VK_PRESENT_MODE_IMMEDIATE, VK_PRESENT_MODE_FIFO_RELAXED }
    enum prefix = enumCommonPrefix!Mode;

    assert(enumMemberNameOr!(CaseStyle.kebabCase, prefix)(
        Mode.VK_PRESENT_MODE_FIFO_RELAXED, "unknown") == "fifo-relaxed");

    // Order matters. A style that drops separators does not preserve length, so
    // stripping after the recase would cut in the wrong place — this is the
    // case that catches it.
    assert(enumMemberNameOr!(CaseStyle.camelCase, prefix)(
        Mode.VK_PRESENT_MODE_FIFO_RELAXED, "unknown") == "fifoRelaxed");

    // The fallback is the caller's own string and is never stripped — the
    // reason a caller must not slice the result itself.
    assert(enumMemberNameOr!(CaseStyle.kebabCase, prefix)(
        cast(Mode) 42, "unknown") == "unknown");

    // A prefix a member does not carry leaves that member alone.
    assert(enumMemberNameOr!(CaseStyle.original, "NOPE_")(
        Mode.VK_PRESENT_MODE_IMMEDIATE, "?") == "VK_PRESENT_MODE_IMMEDIATE");
}

@("text.enums.enumMemberNameOr.stripsATrailingAffixToo")
@safe pure nothrow @nogc
unittest
{
    // A vendor tag the caller knows its own enum carries. Only some members
    // have it, so the ones that do not must come through unharmed.
    enum Mode
    {
        VK_PRESENT_MODE_FIFO_KHR,
        VK_PRESENT_MODE_LATEST_READY_EXT,
    }
    enum prefix = enumCommonPrefix!Mode;

    assert(enumMemberNameOr!(CaseStyle.kebabCase, prefix, "_KHR")(
        Mode.VK_PRESENT_MODE_FIFO_KHR, "?") == "fifo");
    assert(enumMemberNameOr!(CaseStyle.kebabCase, prefix, "_KHR")(
        Mode.VK_PRESENT_MODE_LATEST_READY_EXT, "?") == "latest-ready-ext");

    // A suffix that would consume the whole remaining name is not applied —
    // there would be nothing left to render.
    assert(enumMemberNameOr!(CaseStyle.original, prefix, "FIFO_KHR")(
        Mode.VK_PRESENT_MODE_FIFO_KHR, "?") == "FIFO_KHR");
}

/**
The longest prefix shared by every member name of `E`, cut back to the last `_`.

A C enum has no scope of its own, so its members carry the type's name:
`VK_FORMAT_UNDEFINED`, `VK_FORMAT_R8G8B8A8_UNORM`. Rendering one for a human
means dropping that, and hand-writing the prefix at each call site is a
literal that silently stops matching when the enum is renamed. This derives it.

Cutting back to an underscore is what keeps the result a whole word. The members
of an enum that all began `VK_FORMAT_R` would otherwise have the `R` taken too,
leaving names that read as truncated rather than shortened.

Evaluates to `""` for an enum whose members share nothing, and for an enum with
a single member (whose name is entirely its own prefix, which would leave nothing
to render). Both are the safe answer: the caller renders the full name.
*/
template enumCommonPrefix(E)
if (is(E == enum))
{
    // An eponymous value, not a niladic function: this is written as a template
    // argument (`enumMemberNameOr!(style, enumCommonPrefix!E)`), and a function
    // template there names the function rather than calling it.
    enum string enumCommonPrefix = () {
        static if (__traits(allMembers, E).length < 2)
            return "";
        else
        {
            string prefix;
            bool first = true;
            static foreach (name; __traits(allMembers, E))
            {{
                if (first)
                {
                    prefix = name;
                    first = false;
                }
                else
                {
                    size_t i;
                    while (i < prefix.length && i < name.length && prefix[i] == name[i])
                        ++i;
                    prefix = prefix[0 .. i];
                }
            }}

            while (prefix.length && prefix[$ - 1] != '_')
                prefix = prefix[0 .. $ - 1];
            return prefix;
        }
    }();
}

@("text.enums.enumCommonPrefix.derivesTheSharedPrefix")
@safe pure nothrow @nogc
unittest
{
    enum Format { VK_FORMAT_UNDEFINED, VK_FORMAT_R8_UNORM, VK_FORMAT_MAX_ENUM }
    static assert(enumCommonPrefix!Format == "VK_FORMAT_");

    // Cut back to the underscore: the members share "VK_FORMAT_R", but stopping
    // there would render "8_UNORM" and "16_SFLOAT".
    enum Narrow { VK_FORMAT_R8_UNORM, VK_FORMAT_R16_SFLOAT }
    static assert(enumCommonPrefix!Narrow == "VK_FORMAT_");
}

@("text.enums.enumCommonPrefix.degradesRatherThanGuesses")
@safe pure nothrow @nogc
unittest
{
    // Nothing in common: the caller renders whole names.
    enum Mixed { alpha, beta }
    static assert(enumCommonPrefix!Mixed == "");

    // One member is entirely its own prefix — stripping it would leave nothing.
    enum Lone { VK_ONLY_ONE }
    static assert(enumCommonPrefix!Lone == "");

    // A shared prefix that never reaches an underscore is not a prefix.
    enum NoBoundary { abcd, abce }
    static assert(enumCommonPrefix!NoBoundary == "");
}

@("text.enums.enumCommonPrefix.isCompileTimeEvaluable")
@safe pure nothrow @nogc
unittest
{
    // The point of the primitive: a call site uses it as a template argument,
    // so it has to fold rather than run.
    enum Sample { PFX_A, PFX_B }
    static assert(enumCommonPrefix!Sample == "PFX_");
    enum stripped = Sample.PFX_A.stringof[enumCommonPrefix!Sample.length .. $];
    static assert(stripped == "PFX_A"[enumCommonPrefix!Sample.length .. $]);
}

/// The enum's declared underlying values joined as `"1, 5"` (or, for a string-
/// backed enum, `"a, b"`), computed at compile time — the body of the
/// `"expected one of: …"` detail $(LREF enumFromValue) attaches to an
/// `unknownValue` error.
private template enumValueList(E)
if (is(E == enum))
{
    enum string enumValueList = {
        import std.conv : to;

        string s;
        static foreach (i, memberName; __traits(allMembers, E))
        {
            static if (i)
                s ~= ", ";
            s ~= (cast(OriginalType!E) __traits(getMember, E, memberName)).to!string;
        }
        return s;
    }();
}

/**
Validates an underlying `value` back into a declared member of enum `E`.

The parameter is the enum's `OriginalType`, so string-, char-, or any
non-integer-backed enum is supported, not only integral enums. On a match the
result is `parseOk` of the member; otherwise it is a `ParseError` with code
`unknownValue` and an `"expected one of: …"` context listing the declared
underlying values. Never throws, never allocates.
*/
ParseExpected!E enumFromValue(E)(OriginalType!E value)
if (is(E == enum))
{
    import sparkles.base.text.errors : ParseErrorCode, parseErr, parseOk;

    static foreach (memberName; __traits(allMembers, E))
        if (value == cast(OriginalType!E) __traits(getMember, E, memberName))
            return parseOk(__traits(getMember, E, memberName));

    enum string msg = "expected one of: " ~ enumValueList!E;
    return parseErr!E(ParseErrorCode.unknownValue, 0, msg);
}

@("text.enums.enumFromValue.integerBacked")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.text.errors : ParseErrorCode;

    enum Priority { low = 1, high = 5 }

    assert(enumFromValue!Priority(1).value == Priority.low);
    assert(enumFromValue!Priority(5).value == Priority.high);

    auto bad = enumFromValue!Priority(2);
    assert(!bad.hasValue);
    assert(bad.error.code == ParseErrorCode.unknownValue);
    assert(bad.error.context == "expected one of: 1, 5");
}

@("text.enums.enumFromValue.stringBacked")
@safe pure nothrow @nogc
unittest
{
    enum Mode : string { fast = "fast-path", slow = "slow-path" }

    assert(enumFromValue!Mode("slow-path").value == Mode.slow);
    assert(!enumFromValue!Mode("nope").hasValue);
    assert(enumFromValue!Mode("nope").error.context
        == "expected one of: fast-path, slow-path");
}
