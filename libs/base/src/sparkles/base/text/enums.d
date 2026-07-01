/**
Enum ↔ text/value conversion.

Format-agnostic primitives for an enum's two serialized forms:

$(UL
    $(LI $(LREF enumMemberName) — a value's member name, recased per a
        $(REF CaseStyle, sparkles,base,text,case_style).)
    $(LI $(LREF enumFromValue) — a membership-checked underlying value back to
        the enum.)
)

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
