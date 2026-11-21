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
 *     `sparkles:base`. Attribution is the caller's job; see $(LREF reportedUnder).
 *   * Without `--DRT-covopt=dstpath:DIR` they are written to the process's
 *     working directory, which for `dub test` is the repository root.
 * )
 */
module coverage;

import sparkles.build_primitives.workspace.package_graph : longestPrefixOwner;
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
 * Whether `path` is reported under the sub-package at `pkgDir`: whether it is
 * the owner of the path among `packageDirs`, the package whose directory is
 * the longest prefix of it (`longestPrefixOwner`, the repository's one
 * ownership rule).
 *
 * A run's listings cover its dependencies too, so a package's number would
 * otherwise include everything beneath it — and `sparkles:base`'s coverage
 * would be counted once per package in the repository. A nested package's
 * files are its own, not also its enclosing package's.
 *
 * Params:
 *   path = a repository-relative source path from a listing's trailer
 *   pkgDir = the sub-package directory as the root manifest spells it
 *      (`libs/input`, `apps/ci`)
 *   packageDirs = every sub-package's directory, `pkgDir` among them
 */
bool reportedUnder(scope const(char)[] path, scope const(char)[] pkgDir, scope const(string)[] packageDirs)
    @safe pure nothrow
{
    const at = longestPrefixOwner!(d => d)(packageDirs, path);
    return at >= 0 && packageDirs[at] == pkgDir && path.length > pkgDir.length;
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

@("ci.coverage.reportedUnder")
@safe pure nothrow
unittest
{
    static immutable string[4] dirs = ["libs/input", "libs/base", "libs/base/text-wasm", "libs/ui"];

    // A package reports its own tree and nothing else — a run's listings
    // include every dependency it compiled.
    assert("libs/input/src/sparkles/input/tier.d".reportedUnder("libs/input", dirs[]));
    assert(!"libs/base/src/sparkles/base/buffer.d".reportedUnder("libs/input", dirs[]));

    // A prefix that is not a path component must not match: `libs/ui` does not
    // own `libs/ui-tui`, which is a different sub-package.
    assert(!"libs/ui-tui/src/sparkles/ui_tui/session.d".reportedUnder("libs/ui", dirs[]));
    assert("libs/ui/src/sparkles/ui/canvas.d".reportedUnder("libs/ui", dirs[]));

    // A nested package's files are its own, not its enclosing package's.
    assert("libs/base/text-wasm/src/t.d".reportedUnder("libs/base/text-wasm", dirs[]));
    assert(!"libs/base/text-wasm/src/t.d".reportedUnder("libs/base", dirs[]));

    // The directory itself is not one of its own files.
    assert(!"libs/ui".reportedUnder("libs/ui", dirs[]));
}

/**
 * Aggregates the listings in `dir` that belong to `pkgDir`.
 *
 * Params:
 *   dir = directory the run's `.lst` files were written to
 *   name = the sub-package's short name, for reporting
 *   pkgDir = its directory
 *   packageDirs = every sub-package's directory, for $(LREF reportedUnder)
 */
PackageCoverage collectCoverage(string dir, string name, string pkgDir, scope const(string)[] packageDirs)
{
    import std.algorithm : filter, map, sort;
    import std.array : array;
    import std.file : dirEntries, readText, SpanMode;

    PackageCoverage r;
    r.name = name;
    foreach (entry; dir.dirEntries("*.lst", SpanMode.shallow))
    {
        const cov = parseCoverageListing(entry.name.readText);
        if (cov.path is null || !cov.path.reportedUnder(pkgDir, packageDirs))
            continue;
        r.files ~= cov;
        r.covered += cov.covered;
        r.coverable += cov.coverable;
    }
    r.files.sort!((a, b) => a.percent < b.percent);
    return r;
}

/**
Merges two `-cov` listings of one source file, as druntime's `merge:1` does
when a second process writes over the first's (ci task-DAG CIC7): each line's
counter is the sum of both, a line either listing counted is coverable, and
the trailer is recomputed from the merged counters. The listings' source
lines must agree; `null` when they do not, and the caller keeps them apart.
*/
string mergeListings(const(char)[] a, const(char)[] b) @safe pure
{
    import std.algorithm.searching : findSplit;
    import std.array : appender;
    import std.conv : ConvException, to;
    import std.format : format;
    import std.string : strip;

    // Lines end at `\n` alone: a source line may hold U+2028 or NEL, which
    // `lineSplitter` would also split at.
    auto as = linesOf(a), bs = linesOf(b);
    if (as.length != bs.length || as.length == 0)
        return null;
    auto out_ = appender!string;
    size_t covered, coverable;
    const(char)[] path;
    foreach (i; 0 .. as.length - 1)
    {
        auto x = as[i].findSplit("|"), y = bs[i].findSplit("|");
        if (!x[1].length || !y[1].length || x[2] != y[2])
            return null;
        const cx = x[0].strip, cy = y[0].strip;
        if (!cx.length && !cy.length)
        {
            out_ ~= x[0];
        }
        else
        {
            ulong n;
            try
                n = (cx.length ? cx.to!ulong : 0) + (cy.length ? cy.to!ulong : 0);
            catch (ConvException)
                return null;
            ++coverable;
            covered += n > 0;
            out_ ~= n ? format("%7d", n) : "0000000";
        }
        out_ ~= "|";
        out_ ~= x[2];
        out_ ~= "\n";
    }
    // The trailer: `<path> is N% covered` or `<path> has no code`.
    const trailer = as[$ - 1];
    if (auto is_ = trailer.findSplit(" is "))
        path = is_[0];
    else if (auto none = trailer.findSplit(" has no code"))
        path = none[0];
    else
        return null;
    out_ ~= coverable ? format("%s is %d%% covered\n", path, covered * 100 / coverable)
        : format("%s has no code\n", path);
    return out_[];
}

// `text`'s lines, each without its `\n` (and a `\r` before it).
private const(char)[][] linesOf(const(char)[] text) @safe pure
{
    import std.algorithm.iteration : splitter;

    const(char)[][] result;
    foreach (l; text.splitter('\n'))
        result ~= l.length && l[$ - 1] == '\r' ? l[0 .. $ - 1] : l;
    if (result.length && result[$ - 1].length == 0)
        result = result[0 .. $ - 1];
    return result;
}

///
@("coverage.mergeListings.sumsCounters")
@safe
unittest
{
    const a = "       |module m;\n      2|f();\n0000000|g();\nm.d is 50% covered\n";
    const b = "       |module m;\n0000000|f();\n      1|g();\nm.d is 50% covered\n";
    assert(mergeListings(a, b) == "       |module m;\n      2|f();\n      1|g();\nm.d is 100% covered\n");
    // Different sources are different listings.
    assert(mergeListings(a, "       |module n;\n      2|f();\n0000000|g();\nm.d is 50% covered\n") is null);
    // A merged listing parses as one.
    const merged = parseCoverageListing(mergeListings(a, b));
    assert(merged.path == "m.d" && merged.covered == 2 && merged.coverable == 2);
    // A line separator inside a source line does not end the line.
    const sep = "      1|s = \u2028;\nm.d is 100% covered\n";
    assert(mergeListings(sep, sep) == "      2|s = \u2028;\nm.d is 100% covered\n");
}
