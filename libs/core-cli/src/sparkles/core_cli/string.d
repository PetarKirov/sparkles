module sparkles.core_cli.string;

import std.conv : to;
import std.exception : assertThrown;

string lowerCaseFirst(string r)
{
    import std.range : save, popFront, chain, front, only;
    import std.uni : toLower;

    string rest = r.save;
    rest.popFront();
    return chain(r.front.toLower.only, rest).to!string;
}

string camelCaseToCapitalCase(string camelCase)
{
    import std.algorithm : splitWhen, map, joiner;
    import std.conv : to;
    import std.uni : isLower, isUpper, asUpperCase;

    return camelCase
        .splitWhen!((a, b) => isLower(a) && isUpper(b))
        .map!asUpperCase
        .joiner("_")
        .to!string;
}

@("camelCaseToCapitalCase")
unittest
{
    assert(camelCaseToCapitalCase("camelCase") == "CAMEL_CASE");

    assert(camelCaseToCapitalCase("") == "");
    assert(camelCaseToCapitalCase("_") == "_");
    assert(camelCaseToCapitalCase("a") == "A");
    assert(camelCaseToCapitalCase("ab") == "AB");
    assert(camelCaseToCapitalCase("aB") == "A_B");
    assert(camelCaseToCapitalCase("aBc") == "A_BC");
    assert(camelCaseToCapitalCase("aBC") == "A_BC");
    assert(camelCaseToCapitalCase("aBCD") == "A_BCD");
    assert(camelCaseToCapitalCase("aBcD") == "A_BC_D");

    assert(camelCaseToCapitalCase("rpcUrl") == "RPC_URL");
    assert(camelCaseToCapitalCase("parsedJSON") == "PARSED_JSON");
    assert(camelCaseToCapitalCase("fromXmlToJson") == "FROM_XML_TO_JSON");
    assert(camelCaseToCapitalCase("fromXML2JSON") == "FROM_XML2JSON");
}

string kebabCaseToCamelCase(string kebabCase)
{
    import std.algorithm : map;
    import std.string : capitalize;
    import std.array : join, split;

    return kebabCase
        .split("-")
        .map!capitalize
        .join
        .to!string
        .lowerCaseFirst;
}

@("kebabCaseToCamelCase")
unittest
{
    assert(kebabCaseToCamelCase("kebab-case") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case-") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case--") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case--a") == "kebabCaseA");
    assert(kebabCaseToCamelCase("kebab-case--a-") == "kebabCaseA");

    assert(kebabCaseToCamelCase(
            "once-upon-a-midnight-dreary-while-i-pondered-weak-and-weary" ~
            "-over-many-a-quaint-and-curious-volume-of-forgotten-lore" ~
            "-while-i-nodded-nearly-napping-suddenly-there-came-a-tapping" ~
            "-as-of-someone-gently-rapping-rapping-at-my-chamber-door" ~
            "-tis-some-visitor-i-muttered-tapping-at-my-chamber-door" ~
            "-only-this-and-nothing-more") == "onceUponAMidnightDrearyWhileIPonderedWeakAndWeary" ~
            "OverManyAQuaintAndCuriousVolumeOfForgottenLore" ~ "WhileINoddedNearlyNappingSuddenlyThereCameATapping" ~
            "AsOfSomeoneGentlyRappingRappingAtMyChamberDoor" ~
            "TisSomeVisitorIMutteredTappingAtMyChamberDoor" ~
            "OnlyThisAndNothingMore");

}

struct StringRepresentation
{
    string repr;
}

string enumToString(E)(in E value) if (is(E == enum))
{
    import std.traits : EnumMembers, hasUDA, getUDAs;

    final switch (value)
    {
        static foreach (enumMember; EnumMembers!E)
        {
            case enumMember:
            {
                static if (hasUDA!(enumMember, StringRepresentation))
                    return getUDAs!(enumMember, StringRepresentation)[0].repr;
                else
                    return enumMember.to!string;
            }
        }
    }
}

@("enumToString")
unittest
{
    enum TestEnum
    {
        a1,
        b2,
        c3
    }

    assert(enumToString(TestEnum.a1) == "a1");
    assert(enumToString(TestEnum.b2) == "b2");
    assert(enumToString(TestEnum.c3) == "c3");

    enum TestEnumWithRepr
    {
        @StringRepresentation("field1") a,
        @StringRepresentation("field_2") b,
        @StringRepresentation("field-3") c
    }

    assert(enumToString(TestEnumWithRepr.a) == "field1");
    assert(enumToString(TestEnumWithRepr.b) == "field_2");
    assert(enumToString(TestEnumWithRepr.c) == "field-3");
}

E enumFromString(E)(in string value) if (is(E == enum))
{
    import std.traits : EnumMembers;

    switch (value) {
        static foreach (variant; EnumMembers!E)
            case variant.enumToString: return variant;
        default:
            assert(0, "Expected JSON string, actual: " ~ value ~ " while deserializing type " ~ E.stringof);
    }
}

@("enumFromString")
unittest
{
    enum TestEnum
    {
        a1,
        b2,
        c3
    }

    assert(enumFromString!TestEnum("a1") == TestEnum.a1);
    assert(enumFromString!TestEnum("b2") == TestEnum.b2);
    assert(enumFromString!TestEnum("c3") == TestEnum.c3);

    enum TestEnumWithRepr
    {
        @StringRepresentation("field1") a,
        @StringRepresentation("field_2") b,
        @StringRepresentation("field-3") c
    }

    assert(enumFromString!TestEnumWithRepr("field1") == TestEnumWithRepr.a);
    assert(enumFromString!TestEnumWithRepr("field_2") == TestEnumWithRepr.b);
    assert(enumFromString!TestEnumWithRepr("field-3") == TestEnumWithRepr.c);

    assertThrown!Error(enumFromString!TestEnum("invalid"));
}

enum size_t getMaxEnumMemberNameLength(E) = ()
{
    import std.traits : EnumMembers;

    size_t max = 0;
    foreach (member; [EnumMembers!E])
    {
        const name = member.enumToString();
        max = name.length > max ? name.length : max;
    }

    return max;
}();

@("getMaxEnumMemberNameLength")
unittest
{
    enum EnumLen
    {
        @StringRepresentation("a1") a,
        @StringRepresentation("b12") b,
        @StringRepresentation("c123") c
    }

    static assert(getMaxEnumMemberNameLength!EnumLen == 4);
}

struct MaxWidth
{
    ushort value;
}

void writeRecordAsTable(bool ansiColors = true, T, Writer)(in T obj, auto ref Writer w)
{
    import std.format : formattedWrite;
    import std.traits : hasUDA, getUDAs;

    const gray = ansiColors ? "\x1b[90m" : "";
    const bold = ansiColors ? "\x1b[1m" : "";
    const normal = ansiColors ? "\x1b[0m" : "";

    w.formattedWrite("│");
    static foreach (idx, field; T.tupleof)
    {{
        // If the field is an enum, get the maximum length of the enum member names
        static if (is(typeof(field) == enum))
            const width = getMaxEnumMemberNameLength!(typeof(field));

        // If the field is a bool, set the width to "false".length
        else static if (is(typeof(field) : bool))
            const width = 5;

        // If the field has a UDA MaxWidth, set the width to the value of the UDA
        else static if (hasUDA!(field, MaxWidth))
            const width = getUDAs!(field, MaxWidth)[0].value;

        else
            const width = 0;

        w.formattedWrite(
            " %s%s%s: %s%*-s%s │",
            gray, __traits(identifier, field), normal,
            bold, width, obj.tupleof[idx], normal
        );
    }}
    w.formattedWrite("\n");
}

@("writeRecordAsTable")
unittest
{
    import std.array : appender;

    struct TestStruct
    {
        int num;
        @MaxWidth(4) int otherNum;
        bool bool1;
        bool bool2;
        @MaxWidth(10) string someString;
    }

    const t = TestStruct(1, 20, true, false, "test");
    auto result = appender!string;
    t.writeRecordAsTable!false(result);
    assert(result.data == "│ num: 1 │ otherNum: 20   │ bool1: true  │ bool2: false │ someString: test       │\n");
}

import std.string : chomp, stripLeft;

/**
 * Appends a path segment to a base URL string.
 *
 * This function ensures that exactly one forward slash separator exists between
 * the `baseUrl` and the `path`. It handles cases where either string may or
 * may not already contain a slash, preventing double slashes (e.g., `//`).
 *
 * Params:
 * baseUrl = The starting URL (e.g., "https://api.example.com").
 * path    = The path segment to append (e.g., "/v1/users").
 *
 * Returns:
 * A new string containing the combined URL.
 *
 * Example:
 * ---
 * string url = appendUrlPath("https://dlang.org", "/spec");
 * assert(url == "https://dlang.org/spec");
 *
 * // Handles redundant slashes gracefully
 * assert(appendUrlPath("http://site.com/", "/api") == "http://site.com/api");
 * ---
 */
string appendUrlPath(string baseUrl, string path)
{
    if (baseUrl.length == 0)
    {
        return path;
    }
    if (path.length == 0)
    {
        return baseUrl;
    }

    return baseUrl.chomp("/") ~ "/" ~ path.stripLeft("/");
}

@("appendUrlPath.standardJoining")
unittest
{
    assert(appendUrlPath("https://dlang.org", "spec") == "https://dlang.org/spec");
    assert(appendUrlPath("localhost:8080", "api/v1") == "localhost:8080/api/v1");
}

@("appendUrlPath.slashNormalization")
unittest
{
    // Test trailing slash on base
    assert(appendUrlPath("http://example.com/", "path") == "http://example.com/path");

    // Test leading slash on path
    assert(appendUrlPath("http://example.com", "/path") == "http://example.com/path");

    // Test both slashes present
    assert(appendUrlPath("http://example.com/", "/path") == "http://example.com/path");
}

@("appendUrlPath.emptyInputs")
unittest
{
    assert(appendUrlPath("", "only-path") == "only-path");
    assert(appendUrlPath("only-base", "") == "only-base");
    assert(appendUrlPath("", "") == "");
}

@("appendUrlPath.multipleLeadingSlashes")
unittest
{
    // Ensure it cleans up accidental triple slashes in the path segment
    assert(appendUrlPath("http://api.com", "///v1/user") == "http://api.com/v1/user");
}

@("appendUrlPath.rootPath")
unittest
{
    // Ensure appending a single slash results in a valid trailing slash URL
    assert(appendUrlPath("http://site.com", "/") == "http://site.com/");
}
