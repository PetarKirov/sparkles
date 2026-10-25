/++
Find the `@slow` unittests in a package's sources, without building it.

`ci --test` leaves `@slow` tests out (it passes the runner's `--skip-slow`),
and `ci --test-slow` runs them, one CI job per test. The job list has to exist
before anything is built, so it comes from the source text: every `unittest`
declaration whose attributes include `@slow`, named by its `@("…")` string.

A text scan can miss a test the compiler sees (an attribute applied through a
`@slow:` label or block, say). `--test-slow` therefore also asks the built test
binary for its slow tests (`--list --only-slow`) and fails when the two lists
differ, so a miss turns red instead of going unrun.

Split out from `app.d` so the scanner can be unit-tested (the main source file
is excluded from the auto-generated test runner).
+/
module slow_tests;

import std.algorithm : among, canFind, endsWith, startsWith;
import std.array : appender, array;
import std.string : lineSplitter, strip;

/// One `@slow` unittest found in a source file.
struct SlowTest
{
    string name; /// its `@("…")` name; empty when it has none
    size_t line; /// 1-based line of the `unittest` keyword
}

/**
Every `@slow` unittest declared in `source`, in source order.

A test is `@slow` when `@slow` appears among the attributes before its
`unittest` keyword: the text back to the previous `;`, `{` or `}`, with
comments and string contents out of the way. A test without a string name is
returned with an empty `name`, for the caller to reject.
*/
SlowTest[] slowTestsInSource(scope const(char)[] source) @safe pure
{
    const code = maskCommentsAndStrings(source);
    SlowTest[] found;
    size_t line = 1, counted = 0;
    for (size_t at = 0; at < code.length; ++at)
    {
        if (!isWordAt(code, at, "unittest"))
            continue;
        const after = skipSpace(code, at + "unittest".length);
        if (after >= code.length || code[after] != '{')
            continue; // `version (unittest)`, `debug (unittest)`, …

        size_t start = at;
        while (start > 0 && !code[start - 1].among(';', '{', '}'))
            --start;
        const prefix = code[start .. at];
        if (!hasSlowAttribute(prefix))
            continue;

        foreach (c; code[counted .. at])
            line += c == '\n';
        counted = at;
        found ~= SlowTest(name: firstStringUda(source, code, start, at).idup, line: line);
    }
    return found;
}

@("slow_tests.slowTestsInSource.namedAndUnnamed")
@safe pure
unittest
{
    const source = `
@("fast") @safe unittest {}

/// Doc comment; with a semicolon and } a brace.
@("oracle.raster.freeType")
@slow @system
unittest
{
    assert(1);
}

@slow @safe unittest {}
`;
    const tests = slowTestsInSource(source);
    assert(tests.length == 2);
    assert(tests[0] == SlowTest(name: "oracle.raster.freeType", line: 7));
    assert(tests[1] == SlowTest(name: "", line: 12));
}

@("slow_tests.slowTestsInSource.ignoresCommentsStringsAndVersions")
@safe pure
unittest
{
    const source = `
version (unittest)
{
    // @slow unittest {}
    /* @slow */ @("a") unittest {}
    /+ /+ nested +/ @slow +/ @("b") unittest {}
    enum s = "@slow unittest {}";
    enum t = q{ @slow };
    @("c") @nogc unittest { auto c = '}'; }
    @("d") @slow @safe unittest {}
}
`;
    const tests = slowTestsInSource(source);
    assert(tests.length == 1);
    assert(tests[0].name == "d");
}

@("slow_tests.slowTestsInSource.attributeSpellings")
@safe pure
unittest
{
    // The name may come before or after the marker, and `@slow()` is the
    // same attribute; `@slowly` is a different one.
    assert(slowTestsInSource(`@slow @("x") unittest {}`)[0].name == "x");
    assert(slowTestsInSource(`@("y") @slow() unittest {}`)[0].name == "y");
    assert(slowTestsInSource(`@("z") @slowly unittest {}`).length == 0);
    assert(slowTestsInSource(`@("w")
        @slow @system nothrow
        unittest {}`)[0].name == "w");
}

/**
The names of the slow tests a test binary listed: the lines of
`--list --only-slow --no-colors` output, ` <module> <name> <markers>`, that
carry the `@slow` marker.
*/
string[] slowTestsInListing(scope const(char)[] listing) @safe pure
{
    string[] names;
    foreach (raw; listing.lineSplitter)
    {
        auto line = raw.strip;
        if (!line.endsWith("@slow") && !line.canFind("@slow "))
            continue;
        // Drop the module, then the trailing markers (`@slow`, `@ctfe`, …).
        size_t space = 0;
        while (space < line.length && line[space] != ' ')
            ++space;
        auto rest = line[space .. $].strip;
        while (true)
        {
            size_t lastSpace = rest.length;
            while (lastSpace > 0 && rest[lastSpace - 1] != ' ')
                --lastSpace;
            if (lastSpace == 0 || !rest[lastSpace .. $].startsWith("@"))
                break;
            rest = rest[0 .. lastSpace].strip;
        }
        names ~= rest.idup;
    }
    return names;
}

@("slow_tests.slowTestsInListing")
@safe pure
unittest
{
    const listing = " sparkles.font_oracle.raster oracle.raster.freeType @slow\n"
        ~ " sparkles.font_oracle.raster oracle.raster.flatteningAccuracy @betterC @slow\n"
        ~ " sparkles.font_oracle.shaping oracle.shaping.manifest\n"
        ~ "\n";
    assert(slowTestsInListing(listing)
        == ["oracle.raster.freeType", "oracle.raster.flatteningAccuracy"]);
    assert(slowTestsInListing("").length == 0);
}

/**
The runner's `-i` pattern that selects exactly the tests named `names`.

The runner matches `-i` against `<fullName> <name>`, so each name is anchored
to the end and preceded by the separating space.
*/
string exactNamesPattern(in string[] names) @safe pure
{
    auto pattern = appender!string;
    pattern ~= " (";
    foreach (i, name; names)
    {
        if (i)
            pattern ~= "|";
        foreach (c; name)
        {
            if (c.among('\\', '^', '$', '.', '|', '?', '*', '+', '(', ')', '[', ']', '{', '}'))
                pattern ~= '\\';
            pattern ~= c;
        }
    }
    pattern ~= ")$";
    return pattern[];
}

@("slow_tests.exactNamesPattern")
@safe
unittest
{
    import std.regex : matchFirst;

    const pattern = exactNamesPattern(["oracle.raster.freeType", "a(b)"]);
    assert(pattern == ` (oracle\.raster\.freeType|a\(b\))$`);
    assert(!matchFirst("m.__unittest_L1_C1 oracle.raster.freeType", pattern).empty);
    assert(!matchFirst("m.__unittest_L1_C1 a(b)", pattern).empty);
    assert(matchFirst("m.__unittest_L1_C1 oracle.raster.freeTypeX", pattern).empty);
    assert(matchFirst("m.__unittest_L1_C1 xoracle.raster.freeType", pattern).empty);
}

/// One job of the `slow-tests` CI matrix.
struct SlowTestJob
{
    string packageName; /// the sub-package, as `dub test :<packageName>` takes it
    string test;        /// the test's name
}

/**
The jobs as the JSON array a workflow's `fromJSON` expands into a matrix
dimension: `[{"package":"font-oracle","test":"oracle.raster.freeType"}]`.
*/
string matrixJson(in SlowTestJob[] jobs) @safe pure
{
    auto json = appender!string;
    json ~= "[";
    foreach (i, job; jobs)
    {
        if (i)
            json ~= ",";
        json ~= `{"package":`;
        putJsonString(json, job.packageName);
        json ~= `,"test":`;
        putJsonString(json, job.test);
        json ~= "}";
    }
    json ~= "]";
    return json[];
}

@("slow_tests.matrixJson")
@safe pure
unittest
{
    assert(matrixJson([]) == "[]");
    assert(matrixJson([SlowTestJob("font-oracle", "oracle.raster.freeType"),
            SlowTestJob("x", `q"\`)])
        == `[{"package":"font-oracle","test":"oracle.raster.freeType"},`
        ~ `{"package":"x","test":"q\"\\"}]`);
}

private:

void putJsonString(Writer)(ref Writer json, scope const(char)[] s)
{
    import std.format : formattedWrite;

    json ~= '"';
    foreach (c; s)
    {
        if (c == '"' || c == '\\')
        {
            json ~= '\\';
            json ~= c;
        }
        else if (c < 0x20)
            json.formattedWrite!`\u%04x`(c);
        else
            json ~= c;
    }
    json ~= '"';
}

/// Whether `prefix` (masked declaration text) applies `@slow`.
bool hasSlowAttribute(scope const(char)[] prefix) @safe pure nothrow @nogc
{
    foreach (i; 0 .. prefix.length)
    {
        if (prefix[i] != '@')
            continue;
        const at = skipSpace(prefix, i + 1);
        if (isWordAt(prefix, at, "slow"))
            return true;
    }
    return false;
}

/// The contents of the first `@("…")` in `source[start .. end]`, found in its
/// masked copy `code`; empty when there is none.
const(char)[] firstStringUda(return scope const(char)[] source, scope const(char)[] code,
    size_t start, size_t end) @safe pure nothrow @nogc
{
    foreach (i; start .. end)
    {
        if (code[i] != '@')
            continue;
        auto at = skipSpace(code, i + 1);
        if (at >= end || code[at] != '(')
            continue;
        at = skipSpace(code, at + 1);
        if (at >= end || code[at] != '"')
            continue;
        size_t close = at + 1;
        while (close < end && code[close] != '"')
            ++close;
        return source[at + 1 .. close];
    }
    return null;
}

bool isIdentChar(char c) @safe pure nothrow @nogc
    => c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9');

/// Whether the identifier `word` starts at `code[at]` and is not part of a
/// longer one.
bool isWordAt(scope const(char)[] code, size_t at, string word) @safe pure nothrow @nogc
    => at + word.length <= code.length
        && code[at .. at + word.length] == word
        && (at == 0 || !isIdentChar(code[at - 1]))
        && (at + word.length == code.length || !isIdentChar(code[at + word.length]));

size_t skipSpace(scope const(char)[] code, size_t at) @safe pure nothrow @nogc
{
    while (at < code.length && (code[at] == ' ' || code[at] == '\t'
            || code[at] == '\n' || code[at] == '\r'))
        ++at;
    return at;
}

/**
A copy of `source` of the same length in which comments become spaces and the
contents of string and character literals become `x` (their quotes stay),
newlines kept, so a byte offset means the same thing in both.

Covers line, block and nesting comments, `"…"` with escapes, `r"…"`,
backquoted strings, `'…'`, `q{…}` and the bracket forms of `q"(…)"`. A
heredoc string is left alone: nothing in this repository writes one before a
unittest.
*/
char[] maskCommentsAndStrings(scope const(char)[] source) @safe pure nothrow
{
    auto code = source.dup;
    size_t i = 0;

    void blank(size_t from, size_t to, char fill)
    {
        foreach (k; from .. to)
            if (code[k] != '\n')
                code[k] = fill;
    }

    while (i < code.length)
    {
        const c = code[i];
        const next = i + 1 < code.length ? code[i + 1] : '\0';
        if (c == '/' && next == '/')
        {
            size_t end = i;
            while (end < code.length && code[end] != '\n')
                ++end;
            blank(i, end, ' ');
            i = end;
        }
        else if (c == '/' && next == '*')
        {
            size_t end = i + 2;
            while (end + 1 < code.length && !(code[end] == '*' && code[end + 1] == '/'))
                ++end;
            end = end + 2 < code.length ? end + 2 : code.length;
            blank(i, end, ' ');
            i = end;
        }
        else if (c == '/' && next == '+')
        {
            size_t end = i + 2, depth = 1;
            while (end < code.length && depth)
            {
                if (end + 1 < code.length && code[end] == '/' && code[end + 1] == '+')
                {
                    ++depth;
                    end += 2;
                }
                else if (end + 1 < code.length && code[end] == '+' && code[end + 1] == '/')
                {
                    --depth;
                    end += 2;
                }
                else
                    ++end;
            }
            blank(i, end, ' ');
            i = end;
        }
        else if (c == 'q' && next == '{' && (i == 0 || !isIdentChar(code[i - 1])))
        {
            size_t end = i + 2, depth = 1;
            while (end < code.length && depth)
            {
                depth += code[end] == '{';
                depth -= code[end] == '}';
                ++end;
            }
            blank(i, end, 'x');
            i = end;
        }
        else if (c == 'q' && next == '"' && i + 2 < code.length
            && code[i + 2].among('(', '[', '{', '<') && (i == 0 || !isIdentChar(code[i - 1])))
        {
            const open = code[i + 2];
            const close = open == '(' ? ')' : open == '[' ? ']' : open == '{' ? '}' : '>';
            size_t end = i + 3, depth = 1;
            while (end < code.length && depth)
            {
                depth += code[end] == open;
                depth -= code[end] == close;
                ++end;
            }
            end = end < code.length ? end + 1 : code.length; // the closing `"`
            blank(i, end, 'x');
            i = end;
        }
        else if (c == '"' || c == '`' || c == '\'')
        {
            const raw = c == '`' || (c == '"' && i > 0 && code[i - 1] == 'r'
                && (i == 1 || !isIdentChar(code[i - 2])));
            size_t end = i + 1;
            while (end < code.length && code[end] != c)
                end += !raw && code[end] == '\\' ? 2 : 1;
            end = end < code.length ? end : code.length;
            blank(i + 1, end, 'x');
            i = end + 1;
        }
        else
            ++i;
    }
    return code;
}

@("slow_tests.maskCommentsAndStrings")
@safe pure nothrow
unittest
{
    assert(maskCommentsAndStrings(`a // b`) == `a     `);
    assert(maskCommentsAndStrings("a /* b\n */ c") == "a     \n    c");
    assert(maskCommentsAndStrings(`a /+ /+ b +/ +/ c`) == `a               c`);
    assert(maskCommentsAndStrings(`f("a\"b", 'c')`) == `f("xxxx", 'x')`);
    assert(maskCommentsAndStrings(`r"a\" b`) == `r"xx" b`);
    assert(maskCommentsAndStrings("`a\\` b") == "`xx` b");
    assert(maskCommentsAndStrings(`q{ } } x`) == `xxxx } x`);
    assert(maskCommentsAndStrings(`q"(a(b))" x`) == `xxxxxxxxx x`);
    // The two copies stay the same length, newlines included.
    const source = "@(\"n\")\n/* ; */ @slow unittest {}";
    assert(maskCommentsAndStrings(source).length == source.length);
}
