module sparkles.dql.engine;

import core.lifetime : move;
import expected : Expected, err, ok;
import sparkles.base.buffer : HeapBuffer, Storage;
import sparkles.base.text.span : TextSpan;
import sparkles.base.unique : Unique, makeUnique;
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

/**
Execution engine: interned strings, compiled matchers, and reusable scratch.

Large glob/fuzzy workspaces are heap-owned (`Unique`) and allocated on first
use; the fuzzy matcher (~13.7 MiB) also supplies Unicode analysis scratch for
query parsing and glob compilation. Compiled programs live in heap-only
buffers so a 25 KiB `GlobProgram` is never inlined here. The engine struct
itself stays small enough for a worker-thread stack (512 KiB on macOS).

Every `DqlFilter` parsed through this engine contains handles into these
buffers. The engine must therefore outlive its filters and must not be moved
while one is evaluated.

Fuzzy queries borrow the heap-only string pool. Once a query is registered,
pool growth retains the old allocation until engine destruction, so later
interning cannot invalidate stored query text. Retained pools grow
geometrically with the current pool; no source arena is allocated per query.
*/
struct DqlEngine
{
    HeapBuffer!(char, Storage.unique) stringPool;
    HeapBuffer!(GlobProgram!(), Storage.unique) globPrograms;
    HeapBuffer!(QueryStorage!(), Storage.unique) fuzzyQueries;
    HeapBuffer!(RegexHolder, Storage.unique) regexHolders;

    /// Interns `str` into `stringPool`, returning its `TextSpan` handle.
    TextSpan intern(scope const(char)[] str) @safe pure nothrow @nogc
    {
        if (str.length == 0)
            return TextSpan.of(0, 0);

        const uint start = cast(uint) stringPool.length;
        if (fuzzyQueries.length && str.length > stringPool.capacity - stringPool.length)
        {
            // Do not realloc storage borrowed by an already-compiled query.
            HeapBuffer!(char, Storage.unique) replacement;
            replacement.reserve(stringPool.length + str.length);
            replacement ~= stringPool[];
            // Retired pools are genuine copyable owners; toShared transfers
            // the old block without allocation, leaving the hot pool unique.
            _retiredStringPools ~= stringPool.toShared();
            move(replacement, stringPool);
        }
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

    /// Glob NFA scratch, allocated on first use.
    ref GlobMatchWorkspace!() globWorkspace() return @safe pure nothrow @nogc
    {
        ensureGlobWorkspace();
        return _globWorkspace.get;
    }

    /// Fuzzy parsing, glob compilation, and matching scratch, allocated once.
    ref MatcherWorkspace!() matcherWorkspace() return @safe pure nothrow @nogc
    {
        ensureMatcherWorkspace();
        return _matcherWorkspace.get;
    }

private:
    HeapBuffer!(HeapBuffer!char, Storage.unique) _retiredStringPools;
    Unique!(GlobMatchWorkspace!()) _globWorkspace;
    Unique!(MatcherWorkspace!()) _matcherWorkspace;

    // Unique.opAssign is not `scope` (it swaps), so it cannot run inside a
    // `return`-ref method where `this` is `scope`. These helpers are void.
    void ensureGlobWorkspace() @safe pure nothrow @nogc
    {
        if (_globWorkspace.empty)
            _globWorkspace = makeUnique!(GlobMatchWorkspace!())();
        assert(!_globWorkspace.empty, "DqlEngine: workspace allocation failed");
    }

    void ensureMatcherWorkspace() @safe pure nothrow @nogc
    {
        if (_matcherWorkspace.empty)
            _matcherWorkspace = makeUnique!(MatcherWorkspace!())();
        assert(!_matcherWorkspace.empty, "DqlEngine: workspace allocation failed");
    }
}

static assert(DqlEngine.sizeof <= 256,
    "DqlEngine must remain a small stack value; large scratch lives on the heap");

@("dql.engine: engine is a small stack value; workspaces live on the heap")
@safe pure nothrow @nogc
unittest
{
    static assert(DqlEngine.sizeof <= 256);

    DqlEngine engine;
    auto span = engine.intern("alpha");
    assert(engine.textOf(span) == "alpha");

    auto glob = &engine.globWorkspace();
    auto matcher = &engine.matcherWorkspace();
    const engineAddr = (() @trusted => cast(size_t) &engine)();
    const globAddr = (() @trusted => cast(size_t) glob)();
    const matcherAddr = (() @trusted => cast(size_t) matcher)();
    assert(globAddr < engineAddr || globAddr >= engineAddr + DqlEngine.sizeof);
    assert(matcherAddr < engineAddr || matcherAddr >= engineAddr + DqlEngine.sizeof);
}
