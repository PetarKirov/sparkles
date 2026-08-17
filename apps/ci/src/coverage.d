/**
 * Reading D's `-cov` listings, and turning a directory of them into per-package
 * numbers.
 *
 * `dub test <pkg> -b unittest-cov` writes one `.lst` per compiled module. Each
 * line is prefixed with its execution count and a `|`; a line the compiler
 * emitted no code for has a blank count. The listing ends with a trailer naming
 * the source file and its percentage:
 *
 * ---
 *       5|    => e.match!(
 *       1|        (in KeyEvent _) => InteractionTier.interactive,
 * 0000000|        (in PointerEvent _) => InteractionTier.interactive,
 *        |}
 * libs/input/src/sparkles/input/tier.d is 92% covered
 * ---
 *
 * The trailer's percentage is deliberately $(I not) what this module reports.
 * Percentages cannot be summed: averaging a 100%-covered ten-line module with a
 * 10%-covered thousand-line one says 55%, which describes nothing. Counting the
 * lines and dividing once at the end says 10.9%, which is the number a reader
 * means. So the counts come from the body and the trailer supplies only the
 * path.
 *
 * Two things every caller needs to know about the listings:
 *
 * $(LIST
 *   * A run emits listings for $(B every) module it compiled, dependencies
 *     included — testing `sparkles:input` also writes listings for
 *     `sparkles:base`. Attribution is the caller's job; see $(LREF ownedBy).
 *   * Without `--DRT-covopt=dstpath:DIR` they are written to the process's
 *     working directory, which for `dub test` is the repository root.
 * )
 */
module coverage;

import std.algorithm : startsWith;
import sparkles.code_instrumentation.coverage.formats.dmd : parseDmdCoverage;

/// One source file's line coverage, counted from a `.lst` body.
struct FileCoverage
{
    string path;      /// repository-relative source path, from the listing's trailer
    size_t covered;   /// coverable lines executed at least once
    size_t coverable; /// lines the compiler emitted counters for

    /// Percentage covered, `100` when there is nothing to cover — matching
    /// `-cov`'s own treatment of a module with no code.
    double percent() const @safe pure nothrow @nogc
        => coverable == 0 ? 100.0 : (100.0 * covered) / coverable;
}

/// Aggregated coverage for one sub-package.
struct PackageCoverage
{
    string name;
    FileCoverage[] files;
    size_t covered;
    size_t coverable;

    /// ditto
    double percent() const @safe pure nothrow @nogc
        => coverable == 0 ? 100.0 : (100.0 * covered) / coverable;
}

/**
 * Parses one `-cov` listing.
 *
 * Returns: the counted file, or a `FileCoverage` with an empty `path` when the
 *   text is not a listing (no trailer) or does not parse — a caller skips
 *   those rather than guessing a path for them.
 *
 *   A malformed counter column is now a parse error rather than a silently
 *   miscounted line, and an unreadable listing is skipped the same way a
 *   trailer-less one always was.
 */
FileCoverage parseCoverageListing(const(char)[] contents) @safe
{
    auto parsed = parseDmdCoverage(contents);
    if (!parsed)
        return FileCoverage.init;
    const file = parsed.value;
    return FileCoverage(file.sourcePath, file.coveredLines, file.coverableLines);
}

/**
 * Whether `path` is a source file of sub-package `pkg`.
 *
 * A run's listings cover its dependencies too, so a package's number would
 * otherwise include everything beneath it — and `sparkles:base`'s coverage
 * would be counted once per package in the repository.
 *
 * Params:
 *   path = a repository-relative source path from a listing's trailer
 *   pkgDir = the sub-package directory as the root manifest spells it
 *      (`libs/input`, `apps/ci`)
 */
bool ownedBy(scope const(char)[] path, scope const(char)[] pkgDir) @safe pure nothrow
{
    import std.algorithm : startsWith;

    return path.startsWith(pkgDir) && path.length > pkgDir.length
        && path[pkgDir.length] == '/';
}

@("ci.coverage.parseCoverageListing")
@safe
unittest
{
    // The shape `-cov` actually writes: counted lines, an uncovered line as
    // `0000000`, uncounted lines blank, and a trailer naming the file.
    enum listing = "      5|    auto x = f();\n"
        ~ "      1|    if (x)\n"
        ~ "0000000|        neverRun();\n"
        ~ "       |}\n"
        ~ "libs/input/src/sparkles/input/tier.d is 66% covered\n";

    const cov = parseCoverageListing(listing);
    assert(cov.path == "libs/input/src/sparkles/input/tier.d");
    assert(cov.coverable == 3, "the blank-count line is not coverable");
    assert(cov.covered == 2, "0000000 is uncovered, not covered");
    assert(cov.percent > 66.0 && cov.percent < 67.0);
}

@("ci.coverage.parseCoverageListing.malformedIsSkipped")
@safe
unittest
{
    // A counter column that is not a number used to be read as zero and the
    // line counted as covered. An unreadable listing is now skipped the same
    // way a trailer-less one always was, rather than contributing a wrong
    // number to the package total.
    const junk = parseCoverageListing("   abc|    x();\nlibs/x/src/m.d is 0% covered\n");
    assert(junk.path is null);
    assert(junk.coverable == 0 && junk.covered == 0);
}

@("ci.coverage.parseCoverageListing.noCodeAndNonListings")
@safe
unittest
{
    // A module with nothing to cover still names itself, and counts as fully
    // covered rather than dragging an aggregate down with a 0/0.
    const empty = parseCoverageListing("       |module m;\nlibs/x/src/m.d has no code\n");
    assert(empty.path == "libs/x/src/m.d");
    assert(empty.coverable == 0 && empty.percent == 100.0);

    // Anything without a trailer is not a listing; the caller skips it.
    assert(parseCoverageListing("      1|    x();\n").path is null);
    assert(parseCoverageListing("").path is null);
}

@("ci.coverage.ownedBy")
@safe pure nothrow
unittest
{
    // A package owns its own tree and nothing else — a run's listings include
    // every dependency it compiled.
    assert("libs/input/src/sparkles/input/tier.d".ownedBy("libs/input"));
    assert(!"libs/base/src/sparkles/base/smallbuffer.d".ownedBy("libs/input"));

    // A prefix that is not a path component must not match: `libs/ui` does not
    // own `libs/ui-tui`, which is a different sub-package.
    assert(!"libs/ui-tui/src/sparkles/ui_tui/session.d".ownedBy("libs/ui"));
    assert("libs/ui/src/sparkles/ui/canvas.d".ownedBy("libs/ui"));

    // The directory itself is not one of its own files.
    assert(!"libs/ui".ownedBy("libs/ui"));
}

/**
 * Aggregates the listings in `dir` that belong to `pkgDir`.
 *
 * Params:
 *   dir = directory the run's `.lst` files were written to
 *   name = the sub-package's short name, for reporting
 *   pkgDir = its directory, for $(LREF ownedBy) attribution
 */
PackageCoverage collectCoverage(string dir, string name, string pkgDir)
{
    import std.algorithm : filter, map, sort;
    import std.array : array;
    import std.file : dirEntries, readText, SpanMode;

    PackageCoverage r;
    r.name = name;
    foreach (entry; dir.dirEntries("*.lst", SpanMode.shallow))
    {
        const cov = parseCoverageListing(entry.name.readText);
        if (cov.path is null || !cov.path.ownedBy(pkgDir))
            continue;
        r.files ~= cov;
        r.covered += cov.covered;
        r.coverable += cov.coverable;
    }
    r.files.sort!((a, b) => a.percent < b.percent);
    return r;
}
