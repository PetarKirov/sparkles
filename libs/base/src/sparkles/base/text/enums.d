/**
Enum text conversion policy.

This module is the single source of truth for an enum's human-readable
member-name policy: members render as their source member name unless
annotated with $(LREF StringRepresentation). It deliberately stays format-
agnostic (no JSON, no styling) so the conventional views can build on it:

$(UL
    $(LI $(LREF enumToString) — the borrowed-string view (this module).)
    $(LI `writeEnumMemberName` (`sparkles.base.text.writers`) — the
        output-range writer view.)
    $(LI `readEnumString` (`sparkles.base.text.readers`) — the
        slice-advancing reader view (the inverse).)
)
*/
module sparkles.base.text.enums;

/// Optional enum-member UDA that overrides the member's textual name.
struct StringRepresentation
{
    string repr; /// replacement text for the enum member
}

/**
The textual name policy for a single enum `member`, resolved at compile time:
the $(LREF StringRepresentation) override when present, else the source
member identifier. This is the shared primitive the string / writer / reader
views all derive from.
*/
template enumMemberName(alias member)
if (is(typeof(member) == enum))
{
    import std.traits : getUDAs, hasUDA;

    static if (hasUDA!(member, StringRepresentation))
        enum string enumMemberName = getUDAs!(member, StringRepresentation)[0].repr;
    else
        enum string enumMemberName = __traits(identifier, member);
}

/**
Returns the text representation for `value` as a borrowed compile-time string
(a string literal — no allocation, so callers stay `@nogc`).

Valid enum values render as the member name, or the
$(LREF StringRepresentation) override when present. Invalid enum values
trigger an assertion; use the output-range writer `writeEnumMemberName`
(`sparkles.base.text.writers`) when invalid bit-flag combinations need a
numeric fallback, or the reader `readEnumString`
(`sparkles.base.text.readers`) for the inverse direction.
*/
string enumToString(E)(in E value)
if (is(E == enum))
{
    bool matched;
    string result;

    static foreach (memberName; __traits(allMembers, E))
    {{
        alias member = __traits(getMember, E, memberName);
        if (!matched && value == member)
        {
            result = enumMemberName!member;
            matched = true;
        }
    }}

    assert(matched, "Invalid enum value");
    return result;
}

@("text.enums.enumToString.defaultNames")
@safe pure nothrow @nogc
unittest
{
    enum Color { red, green, blue }

    assert(enumToString(Color.green) == "green");
}

@("text.enums.enumToString.stringRepresentation")
@safe pure nothrow @nogc
unittest
{
    enum WireKind
    {
        @StringRepresentation("wire-kind") wireKind,
        defaultKind,
    }

    assert(enumToString(WireKind.wireKind) == "wire-kind");
    assert(enumToString(WireKind.defaultKind) == "defaultKind");
}
