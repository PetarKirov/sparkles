/**
The DQL path grammar (SPEC §2.1) as a reader and a writer of steps.

A path is `Segment ( "." Segment | "[" Digits "]" | "[" String "]" )*`, where
a segment is an identifier or a quoted `["…"]` name in JSON string escaping.
The grammar itself is implemented once, in `sparkles.base.text.value_path`,
below every package that addresses data by it; this module names it in DQL's
vocabulary. `validateDqlPath` reports the first fault at its byte offset as a
`DqlParseError`; `dqlPathSteps` walks a valid path without allocating; a
step's `nameEquals` and `writeName` see its decoded name. `writeDqlSegment`
writes a name back, quoted when it is not an identifier, so a printed path
parses to the same steps. Hosts that address their own data by DQL paths —
the SDL selector in `sparkles:wired-sdl-select` — read paths here rather than
re-implement the grammar.
*/
module sparkles.dql.path;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.value_path : PathFault, PathNameBytes, PathStep,
    PathStepKind, PathSteps, isIdentifierPathSegment, isPathSegmentByte,
    pathSteps, readPathStep, samePath, validatePath, writePathSegment;
import sparkles.dql.engine : DqlParseError;

/// What one step of a path addresses.
alias DqlPathStepKind = PathStepKind;
/// One step of a path: a segment's name, or an index.
alias DqlPathStep = PathStep;
/// Forward range over the steps of a path $(LREF validateDqlPath) accepted.
alias DqlPathSteps = PathSteps;
/// Input range over a name's decoded UTF-8 bytes.
alias DqlNameBytes = PathNameBytes;
/// Whether `c` may appear in an identifier segment.
alias isDqlSegmentByte = isPathSegmentByte;
/// Whether a name can be written as an identifier segment.
alias isDqlIdentifierSegment = isIdentifierPathSegment;
/// Writes a name as the next segment of a path.
alias writeDqlSegment = writePathSegment;
/// The steps of a path, which $(LREF validateDqlPath) has accepted.
alias dqlPathSteps = pathSteps;
/// Whether two paths are the same step by step (`["x"].y` is `x.y`).
alias sameDqlPath = samePath;

private DqlParseError toDql(PathFault fault) @safe pure nothrow @nogc
    => DqlParseError(fault.message, fault.offset, fault.length);

/** Reads the step at `at`, advancing it; `first` selects the leading
segment, which has no `.` before it. A fault is left in `fault`. */
package(sparkles.dql) DqlPathStep readStep(return scope const(char)[] path, ref size_t at,
    bool first, out DqlParseError fault) @safe pure nothrow @nogc
{
    PathFault pathFault;
    auto step = readPathStep(path, at, first, pathFault);
    fault = toDql(pathFault);
    return step;
}

/** The number of steps in `path`, or the first fault in it at its byte
offset. An empty path is a fault. */
Expected!(size_t, DqlParseError) validateDqlPath(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    auto result = validatePath(path);
    if (result.hasError)
        return err!size_t(toDql(result.error));
    return ok!DqlParseError(result.value);
}

///
@("dql.path.validateDqlPath.faults")
@safe pure nothrow @nogc
unittest
{
    // The grammar's own cases live with it (`sparkles.base.text.value_path`);
    // DQL reports them as its parse errors, at the same byte span.
    assert(validateDqlPath(`build["my.tool"].dependency`).value == 3);
    const fault = validateDqlPath(`a["bad\q"]`);
    assert(fault.hasError && fault.error.offset == 6 && fault.error.length == 2);
    assert(fault.error.message == "bad escape in a quoted segment");
    assert(validateDqlPath("").error.message == "empty path");

    size_t at;
    DqlParseError stepFault;
    const step = readStep(`["a.b"].c`, at, true, stepFault);
    assert(stepFault.message is null && step.nameEquals("a.b") && at == 7);
}
