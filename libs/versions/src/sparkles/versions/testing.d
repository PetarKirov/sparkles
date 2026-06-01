/**
`version(unittest)` test helpers shared by the scheme modules.

Each helper is generic over a scheme `S` (any
$(REF isVersionScheme, sparkles,versions,traits)): it drives `S.parse`
(or `S.parseLoose`) and `S.toString`, throwing a recycled `AssertError`
on mismatch so callers stay `@safe pure nothrow @nogc`.

See `docs/specs/versions/PLAN.md` §M1.
*/
module sparkles.versions.testing;

version (unittest):

import core.exception : AssertError;

import sparkles.core_cli.lifetime : recycledErrorInstance;
import sparkles.core_cli.smallbuffer : checkToString;

import sparkles.versions.parsing : ParseExpected;

/// Throws a recycled AssertError with a fixed message. `@trusted` because
/// `recycledErrorInstance` is `@system` (it parks the Error in a static
/// buffer).
private void throwAssert(in char[] msg, string file, size_t line)
    @trusted pure nothrow @nogc
{
    throw recycledErrorInstance!AssertError(msg, file, line);
}

/// Resolves the parse entry point: `loose` selects `S.parseLoose` (when the
/// scheme provides it), otherwise `S.parse`.
private auto doParse(S)(string s, bool loose) @safe
{
    static if (__traits(hasMember, S, "parseLoose"))
    {
        if (loose)
            return S.parseLoose(s);
    }
    return S.parse(s);
}

/**
Parses `s` for scheme `S`; throws a recycled `AssertError` on parse failure
so the caller stays `@safe pure nothrow @nogc`. `file`/`line` default to the
call site.
*/
S.Version checkParse(S)(
    string s,
    bool loose = false,
    string file = __FILE__, size_t line = __LINE__,
) @safe
{
    auto result = doParse!S(s, loose);
    if (!result.hasValue)
        throwAssert("parse failed", file, line);
    return result.value;
}

/**
Parses `s` and asserts `toString` reproduces `expected` (or `s` itself when
`expected` is null).
*/
void checkRoundTrip(S)(
    string s,
    string expected = null,
    bool loose = false,
    string file = __FILE__, size_t line = __LINE__,
) @safe
{
    auto v = checkParse!S(s, loose, file, line);
    checkToString(v, expected.length ? expected : s, file, line);
}

/// Asserts that `s` is rejected by `S`'s parser.
void checkRejects(S)(
    string s,
    bool loose = false,
    string file = __FILE__, size_t line = __LINE__,
) @safe
{
    if (doParse!S(s, loose).hasValue)
        throwAssert("expected rejection", file, line);
}

/**
Parses each string and asserts the resulting versions form a strictly
ascending chain. A typesafe variadic so callers write
`checkAscending!S("a", "b", "c")` without an array literal.
*/
void checkAscending(S)(string[] series...) @safe
{
    foreach (i; 1 .. series.length)
    {
        const lhs = checkParse!S(series[i - 1]);
        const rhs = checkParse!S(series[i]);
        if (!(lhs < rhs))
            throwAssert("ascending order violated", __FILE__, __LINE__);
    }
}
