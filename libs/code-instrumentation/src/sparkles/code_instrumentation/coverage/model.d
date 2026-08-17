/**
 * Unified data models for source-level code coverage.
 *
 * Captures line-level counters, branch outcomes, function execution counts,
 * and sub-line byte span AST blocks across any coverage format (DMD, gcov,
 * llvm-cov, V8/Vitest, LCOV).
 */
module sparkles.code_instrumentation.coverage.model;

import sparkles.base.text.span : TextSpan;
import sparkles.test_runner.attributes : betterC;

/// The coverage state of a single source line.
enum LineState : ubyte
{
    nonCode,   /// Not executable / no code generated (comments, whitespace, declarations)
    uncovered, /// Coverable, but executed 0 times (missed)
    covered,   /// Executed at least once
    partial,   /// Partially covered (e.g. some conditional branches not taken)
}

/// Execution coverage data for one 1-based source line.
struct LineCoverage
{
    size_t lineNumber;       /// 1-based source line number
    ulong executionCount;    /// Number of times line was executed
    LineState state;         /// Coverage state
    uint branchesTaken;      /// Branches taken on this line
    uint branchesTotal;      /// Total branches on this line
}

/// Sub-line / AST block byte range coverage (e.g. from V8 or LLVM region coverage).
struct SpanCoverage
{
    TextSpan span;           /// Byte range in file
    ulong executionCount;    /// Execution count of this byte span
    bool isBlockCoverage;    /// Whether this denotes an AST block
}

/// Coverage for a single named function.
struct FunctionCoverage
{
    string functionName;     /// Function or method symbol name
    size_t startLine;        /// 1-based start line
    ulong executionCount;    /// Function execution count
}

/// Execution coverage for a single source file.
struct FileCoverage
{
    string sourcePath;               /// Normalized or relative source file path
    LineCoverage[] lines;            /// Per-line coverage records
    SpanCoverage[] spans;            /// Optional sub-line span coverage
    FunctionCoverage[] functions;    /// Optional function coverage records

    /// The file's physical line count where the format states it (a DMD
    /// `.lst` and V8, which is handed the source); otherwise the highest line
    /// the report describes. It is an upper bound on the lines a viewer will
    /// decorate, never a claim about the file on disk.
    size_t totalLines;
    size_t coveredLines;             /// Lines executed >= 1 time
    size_t coverableLines;           /// Lines the compiler emitted code/counters for
    size_t totalBranches;            /// Total conditional branches
    size_t coveredBranches;          /// Branches taken >= 1 time

    /**
    Percentage of coverable lines that executed.

    Returns: the percentage, or `100.0` when the file has no coverable lines
        — a module that emits no code is fully covered, not zero percent.
    */
    double linePercent() const @safe pure nothrow @nogc scope
        => coverableLines == 0 ? 100.0 : (100.0 * coveredLines) / coverableLines;

    /**
    Percentage of conditional branches taken.

    Returns: the percentage, or `100.0` when the file records no branches.
    */
    double branchPercent() const @safe pure nothrow @nogc scope
        => totalBranches == 0 ? 100.0 : (100.0 * coveredBranches) / totalBranches;

    /**
    Looks up one line's coverage.

    Params:
        lineNumber = the 1-based source line

    Returns: a pointer into `lines`, or `null` when the report did not
        describe that line. Only a DMD `.lst` describes every line; the other
        formats record a subset, so `null` means "not stated", not "not
        covered".
    */
    ///
    /// Indexed rather than `foreach (ref const l; lines)`: the loop variable is
    /// not always a true alias for the element, and taking its address is
    /// rejected outright in a `-betterC` build ("address of stack-allocated
    /// local variable").
    const(LineCoverage)* lineAt(size_t lineNumber) return scope const @safe pure nothrow @nogc
    {
        foreach (i; 0 .. lines.length)
            if (lines[i].lineNumber == lineNumber)
                return &lines[i];
        return null;
    }
}

/**
Whether `suffix` matches the tail of `path` at a path-component boundary, so
`src/m.d` matches `/repo/src/m.d` but `m.d` does not match `stream.d`.

Hand-rolled rather than `std.algorithm.searching.endsWith`, which does not
instantiate under `-betterC` for `const(char)[]` and would deny this module
the druntime-free build its `@betterC` test asks for. It also lets the
separator set cover Windows, and rejects an empty `suffix` — a record whose
path never got resolved must not swallow every lookup.

Params:
    path   = The full path being tested.
    suffix = The trailing components to match.

Returns: `true` when `path` ends with `suffix` on a component boundary.
*/
private bool isPathSuffix(scope const(char)[] path, scope const(char)[] suffix)
    @safe pure nothrow @nogc
{
    if (suffix.length == 0 || suffix.length > path.length)
        return false;
    if (path[$ - suffix.length .. $] != suffix)
        return false;
    if (path.length == suffix.length)
        return true;
    const separator = path[$ - suffix.length - 1];
    return separator == '/' || separator == '\\';
}

// No `@betterC` marker despite being `@nogc`-clean: the extracted program is
// its own module, so it cannot reach a `private` helper. `-betterC` coverage
// for this module comes from `coverage.model.percentages` via the public API.
@("coverage.model.isPathSuffix")
@safe pure nothrow @nogc
unittest
{
    assert(isPathSuffix("/repo/src/m.d", "src/m.d"));
    assert(isPathSuffix("/repo/src/m.d", "/repo/src/m.d"));
    assert(isPathSuffix(`C:\repo\src\m.d`, `src\m.d`));

    // A partial component is not a suffix.
    assert(!isPathSuffix("/repo/src/stream.d", "m.d"));
    // Nor is the empty path, however many records carry one.
    assert(!isPathSuffix("/repo/src/m.d", ""));
    assert(!isPathSuffix("m.d", "/repo/src/m.d"));
}

/**
Summary metrics aggregated across a whole report.

The percentages follow $(LREF FileCoverage)'s convention: an empty
denominator reads as fully covered.
*/
struct CoverageSummary
{
    size_t totalFiles;
    size_t coveredFiles;
    size_t totalLines;
    size_t coveredLines;
    size_t coverableLines;
    size_t totalBranches;
    size_t coveredBranches;

    /// Aggregate line coverage percentage.
    double linePercent() const @safe pure nothrow @nogc scope
        => coverableLines == 0 ? 100.0 : (100.0 * coveredLines) / coverableLines;

    /// Aggregate branch coverage percentage.
    double branchPercent() const @safe pure nothrow @nogc scope
        => totalBranches == 0 ? 100.0 : (100.0 * coveredBranches) / totalBranches;
}

/// A complete code coverage report covering one or more source files.
struct CoverageReport
{
    FileCoverage[] files;

    /**
    Finds the file record for `path`: an exact match first, then a
    whole-component suffix match in either direction — a report may record
    `/repo/src/m.d` for a document opened as `src/m.d`, or the reverse.

    Returns: A pointer into `files`, or `null` when nothing matches.
    */
    const(FileCoverage)* findFile(scope const(char)[] path) return scope const
        @safe pure nothrow @nogc
    {
        if (path.length == 0)
            return null;

        foreach (i; 0 .. files.length)
            if (files[i].sourcePath == path)
                return &files[i];

        foreach (i; 0 .. files.length)
            if (isPathSuffix(files[i].sourcePath, path)
                || isPathSuffix(path, files[i].sourcePath))
                return &files[i];

        return null;
    }

    /**
    Aggregates every file's counters.

    Returns: the summary. `coveredFiles` counts a file with no coverable
        lines as covered, matching `linePercent`'s convention rather than
        penalising a module that emits no code.
    */
    CoverageSummary summary() const @safe pure nothrow @nogc
    {
        CoverageSummary s;
        s.totalFiles = files.length;
        foreach (ref const f; files)
        {
            if (f.coveredLines > 0 || f.coverableLines == 0)
                s.coveredFiles++;
            s.totalLines += f.totalLines;
            s.coveredLines += f.coveredLines;
            s.coverableLines += f.coverableLines;
            s.totalBranches += f.totalBranches;
            s.coveredBranches += f.coveredBranches;
        }
        return s;
    }
}

@("coverage.model.percentages")
@betterC
unittest
{
    FileCoverage f;
    f.coverableLines = 10;
    f.coveredLines = 8;
    assert(f.linePercent == 80.0);

    FileCoverage empty;
    assert(empty.linePercent == 100.0);
}

@("coverage.model.findFile")
@safe pure nothrow
unittest
{
    CoverageReport rep;
    rep.files = [
        FileCoverage(sourcePath: "libs/input/src/sparkles/input/tier.d"),
        FileCoverage(sourcePath: "libs/base/src/sparkles/base/text/span.d"),
    ];

    assert(rep.findFile("libs/input/src/sparkles/input/tier.d") !is null);
    assert(rep.findFile("sparkles/input/tier.d") !is null);
    assert(rep.findFile("tier.d") !is null);
    assert(rep.findFile("nonexistent.d") is null);
}
