/** Bounded Thompson-NFA glob compilation and matching. */
module sparkles.fuzzy.glob;

import sparkles.base.text.analysis : AnalysisCase, AnalysisError,
    AnalysisOptions, AnalysisWorkspace, analyzeText, TextUnit;

import sparkles.fuzzy.common : DefaultFuzzyCaps, FuzzyError, FuzzyErrorCode,
    FuzzyExpected, PathFlavor, fuzzyErr, fuzzyOk;

import sparkles.test_runner.attributes : benchmark;

/// NFA instruction kind.
enum GlobOp : ubyte
{
    literal,
    anySegment,
    starSegment,
    starAny,
    charClass,
    split,
    jump,
    accept,
}

/// Inclusive character-class range.
struct GlobRange
{
    uint first;
    uint last;
}

/// One NFA instruction. Ordinary consuming instructions continue at `pc + 1`.
struct GlobInstruction
{
    GlobOp op;
    uint value;
    size_t out1;
    size_t out2;
    size_t rangeStart;
    size_t rangeCount;
    bool negated;
}

/// Borrowed immutable NFA program, suitable for storage in a shared arena.
struct GlobProgramView
{
private:
    const(GlobInstruction)[] instructions_;
    const(GlobRange)[] ranges_;
    PathFlavor pathFlavor_;
    bool caseSensitive_;

package:
    this(return scope const(GlobInstruction)[] instructions,
        return scope const(GlobRange)[] ranges, PathFlavor pathFlavor,
        bool caseSensitive) @trusted pure nothrow @nogc
    {
        instructions_ = instructions;
        ranges_ = ranges;
        pathFlavor_ = pathFlavor;
        caseSensitive_ = caseSensitive;
    }
}

/// Fixed compiled program.
struct GlobProgram(size_t MaxInstructions = DefaultFuzzyCaps.maxGlobInstructions,
    size_t MaxRanges = DefaultFuzzyCaps.maxGlobRanges)
if (MaxInstructions > 0 && MaxRanges > 0)
{
    private GlobInstruction[MaxInstructions] instructions_ = void;
    private GlobRange[MaxRanges] ranges_ = void;
    private size_t instructionCount_;
    private size_t rangeCount_;
    private PathFlavor pathFlavor_;
    private bool caseSensitive_;

    const(GlobInstruction)[] instructions() const return scope
        @safe pure nothrow @nogc
        => instructions_[0 .. instructionCount_];

    const(GlobRange)[] ranges() const return scope @safe pure nothrow @nogc
        => ranges_[0 .. rangeCount_];

    PathFlavor pathFlavor() const @safe pure nothrow @nogc => pathFlavor_;
    bool caseSensitive() const @safe pure nothrow @nogc => caseSensitive_;

    GlobProgramView view() const return scope @safe pure nothrow @nogc
        => globProgramView(this);
}

private GlobProgramView globProgramView(size_t MaxInstructions,
    size_t MaxRanges)(return scope ref const GlobProgram!(MaxInstructions,
        MaxRanges) program) @trusted pure nothrow @nogc
{
    return GlobProgramView(
        program.instructions_[0 .. program.instructionCount_],
        program.ranges_[0 .. program.rangeCount_],
        program.pathFlavor_, program.caseSensitive_);
}

/// Caller-owned NFA state and path-analysis storage.
struct GlobMatchWorkspace(size_t MaxInstructions = DefaultFuzzyCaps.maxGlobInstructions,
    size_t MaxPathUnits = DefaultFuzzyCaps.maxCandidateUnits,
    size_t MaxSegmentUnits = DefaultFuzzyCaps.maxNormalizationSegment)
if (MaxInstructions > 0 && MaxPathUnits > 0 && MaxSegmentUnits > 0)
{
    private bool[MaxInstructions] current = void;
    private bool[MaxInstructions] next = void;
    private size_t[MaxInstructions] queue = void;
    private AnalysisWorkspace!(MaxPathUnits, MaxSegmentUnits) analysis;
}

private struct GlobCompiler(size_t MaxInstructions, size_t MaxRanges)
{
    GlobProgram!(MaxInstructions, MaxRanges)* program;
    const(TextUnit)[] units;
    size_t at;
    bool interpretEscapes;
    size_t[MaxInstructions] jumps = void;
    size_t jumpCount;
    FuzzyError error;

    bool failed() const scope @safe pure nothrow @nogc
        => error.code != FuzzyErrorCode.none;

    size_t emit(GlobInstruction instruction) scope @safe pure nothrow @nogc
    {
        if (program.instructionCount_ == MaxInstructions)
        {
            error = FuzzyError(FuzzyErrorCode.globTooComplex, at);
            return size_t.max;
        }
        const index = program.instructionCount_;
        program.instructions_[program.instructionCount_++] = instruction;
        return index;
    }

    bool compileSequence(uint stop1 = uint.max, uint stop2 = uint.max,
        uint depth = 0) scope @safe pure nothrow @nogc
    {
        while (at < units.length)
        {
            const value = units[at].value;
            if (interpretEscapes && value == '\\')
            {
                const sourceOffset = units[at].sourceStart;
                ++at;
                if (at == units.length)
                {
                    error = FuzzyError(FuzzyErrorCode.invalidEscape,
                        sourceOffset, "trailing glob escape");
                    return false;
                }
                GlobInstruction instruction;
                instruction.op = GlobOp.literal;
                instruction.value = units[at++].value;
                if (emit(instruction) == size_t.max)
                    return false;
                continue;
            }
            if (value == stop1 || value == stop2)
                return true;
            if (value == '{')
            {
                if (!compileBrace(depth + 1))
                    return false;
                continue;
            }
            if (value == '}')
            {
                error = FuzzyError(FuzzyErrorCode.malformedGlob,
                    units[at].sourceStart, "unmatched closing brace");
                return false;
            }
            if (value == '*')
            {
                ++at;
                GlobInstruction instruction;
                if (at < units.length && units[at].value == '*')
                {
                    ++at;
                    instruction.op = GlobOp.starAny;
                }
                else
                    instruction.op = GlobOp.starSegment;
                if (emit(instruction) == size_t.max)
                    return false;
                continue;
            }
            if (value == '?')
            {
                ++at;
                GlobInstruction instruction;
                instruction.op = GlobOp.anySegment;
                if (emit(instruction) == size_t.max)
                    return false;
                continue;
            }
            if (value == '[')
            {
                if (!compileClass())
                    return false;
                continue;
            }
            ++at;
            GlobInstruction instruction;
            instruction.op = GlobOp.literal;
            instruction.value = value;
            if (emit(instruction) == size_t.max)
                return false;
        }
        return true;
    }

    bool compileBrace(uint depth) scope @safe pure nothrow @nogc
    {
        if (depth > 32)
        {
            error = FuzzyError(FuzzyErrorCode.globTooComplex,
                units[at].sourceStart, "brace nesting exceeds 32");
            return false;
        }
        ++at; // opening brace
        if (at == units.length || units[at].value == ',' || units[at].value == '}')
        {
            error = FuzzyError(FuzzyErrorCode.malformedGlob,
                at < units.length ? units[at].sourceStart : units[$ - 1].sourceEnd,
                "empty brace alternative");
            return false;
        }

        const jumpStart = jumpCount;
        size_t split = emit(GlobInstruction(GlobOp.split));
        if (split == size_t.max)
            return false;
        for (;;)
        {
            program.instructions_[split].out1 = program.instructionCount_;
            if (!compileSequence(',', '}', depth))
                return false;
            if (jumpCount == MaxInstructions)
            {
                error = FuzzyError(FuzzyErrorCode.globTooComplex, at);
                return false;
            }
            const jump = emit(GlobInstruction(GlobOp.jump));
            if (jump == size_t.max)
                return false;
            jumps[jumpCount++] = jump;

            if (at == units.length)
            {
                error = FuzzyError(FuzzyErrorCode.unexpectedEnd,
                    units[$ - 1].sourceEnd, "unclosed brace");
                return false;
            }
            if (units[at].value == '}')
            {
                ++at;
                program.instructions_[split].out2
                    = program.instructions_[split].out1;
                const end = program.instructionCount_;
                foreach (i; jumpStart .. jumpCount)
                    program.instructions_[jumps[i]].out1 = end;
                jumpCount = jumpStart;
                return true;
            }
            ++at; // comma
            if (at == units.length || units[at].value == ',' || units[at].value == '}')
            {
                error = FuzzyError(FuzzyErrorCode.malformedGlob,
                    at < units.length ? units[at].sourceStart : units[$ - 1].sourceEnd,
                    "empty brace alternative");
                return false;
            }
            const nextSplit = emit(GlobInstruction(GlobOp.split));
            if (nextSplit == size_t.max)
                return false;
            program.instructions_[split].out2 = nextSplit;
            split = nextSplit;
        }
    }

    bool compileClass() scope @safe pure nothrow @nogc
    {
        const sourceOffset = units[at].sourceStart;
        ++at;
        bool negated;
        if (at < units.length && (units[at].value == '!' || units[at].value == '^'))
        {
            negated = true;
            ++at;
        }
        const rangeStart = program.rangeCount_;
        while (at < units.length && units[at].value != ']')
        {
            uint first;
            if (!readClassLiteral(first, sourceOffset))
                return false;
            uint last = first;
            if (at + 1 < units.length && units[at].value == '-'
                && units[at + 1].value != ']')
            {
                ++at;
                if (!readClassLiteral(last, sourceOffset))
                    return false;
                if (last < first)
                {
                    error = FuzzyError(FuzzyErrorCode.malformedGlob,
                        sourceOffset, "descending character-class range");
                    return false;
                }
            }
            if (program.rangeCount_ == MaxRanges)
            {
                error = FuzzyError(FuzzyErrorCode.globTooComplex, sourceOffset,
                    "too many character-class ranges");
                return false;
            }
            program.ranges_[program.rangeCount_++] = GlobRange(first, last);
        }
        if (at == units.length)
        {
            error = FuzzyError(FuzzyErrorCode.unexpectedEnd,
                sourceOffset, "unclosed character class");
            return false;
        }
        ++at;
        if (program.rangeCount_ == rangeStart)
        {
            error = FuzzyError(FuzzyErrorCode.malformedGlob,
                sourceOffset, "empty character class");
            return false;
        }
        GlobInstruction instruction;
        instruction.op = GlobOp.charClass;
        instruction.rangeStart = rangeStart;
        instruction.rangeCount = program.rangeCount_ - rangeStart;
        instruction.negated = negated;
        return emit(instruction) != size_t.max;
    }

    bool readClassLiteral(out uint value, size_t sourceOffset)
        scope @safe pure nothrow @nogc
    {
        if (at == units.length)
        {
            error = FuzzyError(FuzzyErrorCode.unexpectedEnd, sourceOffset,
                "unclosed character class");
            return false;
        }
        if (interpretEscapes && units[at].value == '\\')
        {
            const escapeOffset = units[at].sourceStart;
            ++at;
            if (at == units.length)
            {
                error = FuzzyError(FuzzyErrorCode.invalidEscape,
                    escapeOffset, "trailing character-class escape");
                return false;
            }
        }
        value = units[at++].value;
        return true;
    }
}

/** Compile a glob containing backslash escapes. */
FuzzyExpected!void compileGlob(size_t MaxInstructions, size_t MaxRanges)(
    scope const(char)[] pattern, PathFlavor pathFlavor, bool caseSensitive,
    ref GlobProgram!(MaxInstructions, MaxRanges) program)
    @safe pure nothrow @nogc
{
    return compileGlobImpl(pattern, pathFlavor, caseSensitive, true, program);
}

/** Compile an already-unescaped glob; every byte is grammar-significant. */
FuzzyExpected!void compileGlobDecoded(size_t MaxInstructions, size_t MaxRanges)(
    scope const(char)[] pattern, PathFlavor pathFlavor, bool caseSensitive,
    ref GlobProgram!(MaxInstructions, MaxRanges) program)
    @safe pure nothrow @nogc
{
    return compileGlobImpl(pattern, pathFlavor, caseSensitive, false, program);
}

private FuzzyExpected!void compileGlobImpl(size_t MaxInstructions,
    size_t MaxRanges)(scope const(char)[] pattern, PathFlavor pathFlavor,
    bool caseSensitive, bool interpretEscapes,
    ref GlobProgram!(MaxInstructions, MaxRanges) program)
    @safe pure nothrow @nogc
{
    if (pathFlavor != PathFlavor.unix && pathFlavor != PathFlavor.windows)
        return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration);
    program.instructionCount_ = 0;
    program.rangeCount_ = 0;
    program.pathFlavor_ = pathFlavor;
    program.caseSensitive_ = caseSensitive;

    AnalysisWorkspace!(MaxInstructions, 64) analysis;
    const options = AnalysisOptions.codePath(caseSensitive
        ? AnalysisCase.sensitive : AnalysisCase.simpleFold);
    const analyzed = analyzeText(pattern, options, analysis);
    if (analyzed.error == AnalysisError.outputFull
        || analyzed.error == AnalysisError.sourceTooLong)
        return fuzzyErr!void(FuzzyErrorCode.globTooComplex, analyzed.sourceOffset);
    if (analyzed.error == AnalysisError.invalidOptions)
        return fuzzyErr!void(FuzzyErrorCode.invalidConfiguration,
            analyzed.sourceOffset);
    if (analyzed.error == AnalysisError.segmentTooLong)
        return fuzzyErr!void(FuzzyErrorCode.normalizationSegmentTooLong,
            analyzed.sourceOffset);
    if (analysis.output.length == 0)
        return fuzzyErr!void(FuzzyErrorCode.emptyValue);

    GlobCompiler!(MaxInstructions, MaxRanges) compiler;
    compiler.program = &program;
    compiler.units = analysis.output;
    compiler.interpretEscapes = interpretEscapes;
    if (!compiler.compileSequence())
        return fuzzyErr!void(compiler.error.code, compiler.error.offset,
            compiler.error.context);
    if (compiler.at != compiler.units.length)
        return fuzzyErr!void(FuzzyErrorCode.malformedGlob,
            compiler.units[compiler.at].sourceStart);
    if (compiler.emit(GlobInstruction(GlobOp.accept)) == size_t.max)
        return fuzzyErr!void(compiler.error.code, compiler.error.offset,
            compiler.error.context);
    return fuzzyOk();
}

/** Match an entire path against a compiled glob. */
FuzzyExpected!bool globMatch(size_t MaxInstructions, size_t MaxRanges,
    size_t MaxPathUnits, size_t MaxSegmentUnits)(
    in GlobProgram!(MaxInstructions, MaxRanges) program,
    scope const(char)[] path,
    ref GlobMatchWorkspace!(MaxInstructions, MaxPathUnits, MaxSegmentUnits) workspace)
    @safe pure nothrow @nogc
{
    return globMatch(program.view, path, workspace);
}

/// Match against an immutable program borrowed from a caller-owned arena.
FuzzyExpected!bool globMatch(size_t MaxInstructions, size_t MaxPathUnits,
    size_t MaxSegmentUnits)(in GlobProgramView program,
    scope const(char)[] path,
    ref GlobMatchWorkspace!(MaxInstructions, MaxPathUnits,
        MaxSegmentUnits) workspace) @safe pure nothrow @nogc
{
    if (program.instructions_.length == 0
        || program.instructions_.length > MaxInstructions)
        return fuzzyErr!bool(FuzzyErrorCode.invalidConfiguration,
            program.instructions_.length);
    const options = AnalysisOptions.codePath(program.caseSensitive_
        ? AnalysisCase.sensitive : AnalysisCase.simpleFold);
    const analyzed = analyzeText(path, options, workspace.analysis);
    if (analyzed.error == AnalysisError.outputFull)
        return fuzzyErr!bool(FuzzyErrorCode.candidateTooComplex,
            analyzed.sourceOffset);
    if (analyzed.error == AnalysisError.sourceTooLong)
        return fuzzyErr!bool(FuzzyErrorCode.candidateTooLong,
            analyzed.sourceOffset);
    if (analyzed.error == AnalysisError.invalidOptions)
        return fuzzyErr!bool(FuzzyErrorCode.invalidConfiguration,
            analyzed.sourceOffset);
    if (analyzed.error == AnalysisError.segmentTooLong)
        return fuzzyErr!bool(FuzzyErrorCode.normalizationSegmentTooLong,
            analyzed.sourceOffset);

    foreach (i; 0 .. MaxInstructions)
        workspace.current[i] = false;
    workspace.current[0] = true;
    epsilonClosure(program, workspace.current, workspace.queue);

    foreach (unit; workspace.analysis.output)
    {
        foreach (i; 0 .. MaxInstructions)
            workspace.next[i] = false;
        foreach (pc; 0 .. program.instructions_.length)
        {
            if (!workspace.current[pc])
                continue;
            const instruction = program.instructions_[pc];
            bool accepts;
            final switch (instruction.op)
            {
            case GlobOp.literal:
                accepts = instruction.value == unit.value
                    || (isUnitSeparator(instruction.value,
                            program.pathFlavor_)
                        && isUnitSeparator(unit.value,
                            program.pathFlavor_));
                break;
            case GlobOp.anySegment:
                accepts = !isUnitSeparator(unit.value, program.pathFlavor_);
                break;
            case GlobOp.starSegment:
                if (!isUnitSeparator(unit.value, program.pathFlavor_))
                    workspace.next[pc] = true;
                continue;
            case GlobOp.starAny:
                workspace.next[pc] = true;
                continue;
            case GlobOp.charClass:
                bool found;
                foreach (i; instruction.rangeStart
                    .. instruction.rangeStart + instruction.rangeCount)
                    found |= program.ranges_[i].first <= unit.value
                        && unit.value <= program.ranges_[i].last;
                accepts = !isUnitSeparator(unit.value, program.pathFlavor_)
                    && (instruction.negated ? !found : found);
                break;
            case GlobOp.split:
            case GlobOp.jump:
            case GlobOp.accept:
                continue;
            }
            if (accepts && pc + 1 < program.instructions_.length)
                workspace.next[pc + 1] = true;
        }
        epsilonClosure(program, workspace.next, workspace.queue);
        workspace.current[] = workspace.next[];
    }
    epsilonClosure(program, workspace.current, workspace.queue);
    foreach (pc; 0 .. program.instructions_.length)
        if (workspace.current[pc]
            && program.instructions_[pc].op == GlobOp.accept)
            return fuzzyOk(true);
    return fuzzyOk(false);
}

private void epsilonClosure(size_t MaxInstructions)(in GlobProgramView program,
    ref bool[MaxInstructions] states, ref size_t[MaxInstructions] queue)
    @safe pure nothrow @nogc
{
    size_t head;
    size_t tail;
    foreach (pc; 0 .. program.instructions_.length)
        if (states[pc])
            queue[tail++] = pc;
    while (head < tail)
    {
        const pc = queue[head++];
        const instruction = program.instructions_[pc];
        void add(size_t target)
        {
            if (target < program.instructions_.length && !states[target])
            {
                states[target] = true;
                queue[tail++] = target;
            }
        }
        switch (instruction.op)
        {
        case GlobOp.starSegment:
        case GlobOp.starAny:
            add(pc + 1);
            break;
        case GlobOp.split:
            add(instruction.out1);
            add(instruction.out2);
            break;
        case GlobOp.jump:
            add(instruction.out1);
            break;
        default:
            break;
        }
    }
}

private bool isUnitSeparator(uint value, PathFlavor flavor)
    @safe pure nothrow @nogc
    => value == '/' || (flavor == PathFlavor.windows && value == '\\');

@("fuzzy.glob.syntaxAndMatching")
@safe pure nothrow @nogc
unittest
{
    GlobProgram!(64, 16) program;
    GlobMatchWorkspace!(64, 64, 16) workspace;
    assert(!compileGlob("**/*.{rs,md}", PathFlavor.unix, false, program).hasError);
    assert(globMatch(program, "src/main.rs", workspace).value);
    assert(globMatch(program, "docs/readme.MD", workspace).value);
    assert(!globMatch(program, "src/main.d", workspace).value);

    assert(!compileGlob(`literal/\*.d`, PathFlavor.unix, true, program).hasError);
    assert(globMatch(program, "literal/*.d", workspace).value);
    assert(!globMatch(program, "literal/main.d", workspace).value);

    assert(!compileGlob("src/*.d", PathFlavor.windows, true, program).hasError);
    assert(globMatch(program, `src\main.d`, workspace).value);
    assert(!compileGlob("src/[!a].d", PathFlavor.windows, true, program).hasError);
    assert(!globMatch(program, `src\.d`, workspace).value,
        "a character class must not cross a path separator");

    assert(!compileGlob("src/[!a-c]?.d", PathFlavor.unix, true, program).hasError);
    assert(globMatch(program, "src/z1.d", workspace).value);
    assert(!globMatch(program, "src/a1.d", workspace).value);
}

@("fuzzy.glob.malformedAndBounded")
@safe pure nothrow @nogc
unittest
{
    GlobProgram!(8, 2) program;
    assert(compileGlob("{a,}", PathFlavor.unix, true, program).error.code
        == FuzzyErrorCode.malformedGlob);
    assert(compileGlob("[z-a]", PathFlavor.unix, true, program).error.code
        == FuzzyErrorCode.malformedGlob);
    assert(compileGlob("abcdefghijk", PathFlavor.unix, true, program).error.code
        == FuzzyErrorCode.globTooComplex);
    assert(compileGlob("a", cast(PathFlavor) ubyte.max, true, program).error.code
        == FuzzyErrorCode.invalidConfiguration);
}

@("fuzzy.glob.simpleGrammarMatchesExhaustiveOracle")
@safe pure nothrow @nogc
unittest
{
    static immutable char[] patternAlphabet = ['a', 'b', '?', '*'];
    static immutable char[] pathAlphabet = ['a', 'b', '/'];
    GlobProgram!(32, 8) program;
    GlobMatchWorkspace!(32, 16, 8) workspace;
    char[4] pattern = void;
    char[4] path = void;
    foreach (patternLength; 1 .. pattern.length + 1)
    foreach (patternCode; 0 .. integerPower(
            patternAlphabet.length, patternLength))
    {
        decodeWord(patternCode, patternAlphabet,
            pattern[0 .. patternLength]);
        auto compiled = compileGlob(pattern[0 .. patternLength],
            PathFlavor.unix, true, program);
        assert(!compiled.hasError);
        foreach (pathLength; 0 .. path.length + 1)
        foreach (pathCode; 0 .. integerPower(pathAlphabet.length, pathLength))
        {
            decodeWord(pathCode, pathAlphabet, path[0 .. pathLength]);
            auto actual = globMatch(program, path[0 .. pathLength], workspace);
            assert(actual.hasValue);
            assert(actual.value == slowSimpleGlob(
                pattern[0 .. patternLength], path[0 .. pathLength]));
        }
    }
}

private size_t integerPower(size_t base, size_t exponent)
    @safe pure nothrow @nogc
{
    size_t result = 1;
    foreach (_; 0 .. exponent)
        result *= base;
    return result;
}

private void decodeWord(size_t code, scope const(char)[] alphabet,
    scope char[] output) @safe pure nothrow @nogc
{
    foreach (ref value; output)
    {
        value = alphabet[code % alphabet.length];
        code /= alphabet.length;
    }
}

private bool slowSimpleGlob(scope const(char)[] pattern,
    scope const(char)[] path, size_t patternAt = 0, size_t pathAt = 0)
    @safe pure nothrow @nogc
{
    if (patternAt == pattern.length)
        return pathAt == path.length;
    if (pattern[patternAt] == '*')
    {
        const crossesSeparators = patternAt + 1 < pattern.length
            && pattern[patternAt + 1] == '*';
        const nextPattern = patternAt + (crossesSeparators ? 2 : 1);
        if (slowSimpleGlob(pattern, path, nextPattern, pathAt))
            return true;
        return pathAt < path.length
            && (crossesSeparators || path[pathAt] != '/')
            && slowSimpleGlob(pattern, path, patternAt, pathAt + 1);
    }
    return pathAt < path.length
        && path[pathAt] != '/'
        && (pattern[patternAt] == '?' || pattern[patternAt] == path[pathAt])
        && slowSimpleGlob(pattern, path, patternAt + 1, pathAt + 1);
}

@("fuzzy.glob.bench.reusedProgram")
@benchmark @safe
unittest
{
    import sparkles.test_runner.bench : benchIter, blackBox;

    GlobProgram!(64, 16) program;
    assert(!compileGlob("**/{src,libs}/**/[a-z]*.{d,md}",
        PathFlavor.unix, false, program).hasError);
    class Context
    {
        bool alternate;
        GlobMatchWorkspace!(64, 128, 32) workspace;
    }
    auto context = new Context;
    benchIter({
        context.alternate = !context.alternate;
        const path = context.alternate
            ? "workspace/libs/fuzzy/src/sparkles/fuzzy/match.d"
            : "workspace/src/generated/parser/readme.md";
        auto result = globMatch(program, blackBox(path), context.workspace);
        assert(result.hasValue);
        blackBox(result.value);
    }, ["profile": "codePath", "tier": "glob-execute",
        "construction": "compiled-program-excluded",
        "corpus": "single-path"]);
}
