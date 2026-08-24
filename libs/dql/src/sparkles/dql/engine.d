module sparkles.dql.engine;

import expected : Expected, err, ok;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.span : TextSpan;
import sparkles.dql.ast;
import sparkles.fuzzy.glob : GlobMatchWorkspace, GlobProgram;
import sparkles.fuzzy.match : MatcherWorkspace;
import sparkles.fuzzy.query : QueryStorage;

@safe:

/// Structure representing a parse error with precise source span.
struct DqlParseError
{
    string message;
    size_t offset;
    size_t length;
}

/// Execution engine owning the interned string pool, compiled matchers, and reusable evaluation workspaces.
struct DqlEngine
{
    SmallBuffer!(char, 64, true) stringPool;
    SmallBuffer!(GlobProgram!(), 2, true) globPrograms;
    SmallBuffer!(QueryStorage!(), 2, true) fuzzyQueries;
    SmallBuffer!(RegexHolder, 2, true) regexHolders;
    GlobMatchWorkspace!() globWorkspace;
    MatcherWorkspace!() matcherWorkspace;

    /// Interns `str` into `stringPool`, returning its `TextSpan` handle.
    TextSpan intern(scope const(char)[] str) @safe pure nothrow @nogc
    {
        if (str.length == 0)
            return TextSpan.of(0, 0);

        const uint start = cast(uint) stringPool.length;
        stringPool ~= str;
        return TextSpan.of(start, cast(uint)(start + str.length));
    }

    /// Resolves a `TextSpan` back to its string slice.
    const(char)[] textOf(in TextSpan span) return scope const @safe pure nothrow @nogc
    {
        if (span.length == 0 || span.startOffset >= stringPool.length)
            return "";
        const size_t end = span.startOffset + span.length;
        if (end > stringPool.length)
            return "";
        return stringPool[][span.startOffset .. end];
    }

    /// Registers a compiled `GlobProgram` and returns its handle index.
    uint registerGlob(GlobProgram!() prog) @safe pure nothrow @nogc
    {
        const uint idx = cast(uint) globPrograms.length;
        globPrograms ~= prog;
        return idx;
    }

    /// Registers a parsed `QueryStorage` and returns its handle index.
    uint registerFuzzy(QueryStorage!() q) @safe pure nothrow @nogc
    {
        const uint idx = cast(uint) fuzzyQueries.length;
        fuzzyQueries ~= q;
        return idx;
    }

    /// Registers a compiled `RegexHolder` and returns its handle index.
    uint registerRegex(RegexHolder r) @safe pure nothrow @nogc
    {
        const uint idx = cast(uint) regexHolders.length;
        regexHolders ~= r;
        return idx;
    }
}
