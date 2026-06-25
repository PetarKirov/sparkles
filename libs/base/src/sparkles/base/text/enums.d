/**
Enum text conversion primitives.

These helpers provide a shared enum-name policy for code that needs a
human-readable textual representation without committing to a higher-level
format such as JSON. Enum members render as their source member name unless
annotated with $(LREF StringRepresentation).
*/
module sparkles.base.text.enums;

import sparkles.base.text.errors :
    ParseErrorCode, ParseExpected, parseErr, parseOk;

/// Optional enum-member UDA that overrides the member's textual name.
struct StringRepresentation
{
    string repr; /// replacement text for the enum member
}

private template enumMemberString(alias member)
if (is(typeof(member) == enum))
{
    import std.traits : getUDAs, hasUDA;

    static if (hasUDA!(member, StringRepresentation))
        enum string enumMemberString = getUDAs!(member, StringRepresentation)[0].repr;
    else
        enum string enumMemberString = __traits(identifier, member);
}

/**
Returns the text representation for `value`.

Valid enum values render as the member name, or the
$(LREF StringRepresentation) override when present. Invalid enum values
trigger an assertion; use writer-level helpers such as `writeEnumMemberName`
when invalid bit-flag combinations need a numeric fallback.
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
            result = enumMemberString!member;
            matched = true;
        }
    }}

    assert(matched, "Invalid enum value");
    return result;
}

/**
Parses an exact enum string representation.

This is intentionally not a slice-advancing reader: callers that already
have a delimited token, such as JSON object keys or JSON strings, can map it
directly to an enum. Empty input reports `emptyInput`; unknown strings report
`invalidIdentifier`.
*/
ParseExpected!E readEnumString(E)(scope const(char)[] value)
if (is(E == enum))
{
    if (value.length == 0)
        return parseErr!E(ParseErrorCode.emptyInput, 0);

    static foreach (memberName; __traits(allMembers, E))
    {{
        alias member = __traits(getMember, E, memberName);
        if (value == enumMemberString!member)
            return parseOk(member);
    }}

    return parseErr!E(ParseErrorCode.invalidIdentifier, 0);
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

@("text.enums.readEnumString.success")
@safe pure nothrow @nogc
unittest
{
    enum Mode
    {
        @StringRepresentation("fast-mode") fast,
        slow,
    }

    auto fast = readEnumString!Mode("fast-mode");
    assert(fast.hasValue);
    assert(fast.value == Mode.fast);

    auto slow = readEnumString!Mode("slow");
    assert(slow.hasValue);
    assert(slow.value == Mode.slow);
}

@("text.enums.readEnumString.emptyInput")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fast }

    auto result = readEnumString!Mode("");
    assert(!result.hasValue);
    assert(result.error.code == ParseErrorCode.emptyInput);
    assert(result.error.offset == 0);
}

@("text.enums.readEnumString.unknown")
@safe pure nothrow @nogc
unittest
{
    enum Mode { fast }

    auto result = readEnumString!Mode("slow");
    assert(!result.hasValue);
    assert(result.error.code == ParseErrorCode.invalidIdentifier);
    assert(result.error.offset == 0);
}
