/**
The DQL path grammar (SPEC §2.1) as a reader of steps.

A path is `Segment ( "." Segment | "[" Digits "]" )*`. A segment is a run of
the bytes the DQL lexer keeps inside one identifier, excluding `.`, `[` and
`]`, so every path the parser hands a resolver reads back step by step.
`validateDqlPath` reports the first fault at its byte offset; `dqlPathSteps`
walks a valid path without allocating. Hosts that address their own data by
DQL paths — the SDL selector in `sparkles:wired` — read paths here rather
than re-implement the grammar.
*/
module sparkles.dql.path;

import sparkles.base.expected : Expected, err, ok;
import sparkles.dql.engine : DqlParseError;

/// What one step of a path addresses.
enum DqlPathStepKind : ubyte
{
    member, /// A named segment.
    index,  /// A `[Digits]` positional index.
}

/// One step of a path: a segment's name, or an index.
struct DqlPathStep
{
    DqlPathStepKind kind; /// Which of the two the step is.
    const(char)[] name;   /// The segment, for a `member` step.
    size_t index;         /// The number, for an `index` step.
    size_t offset;        /// Byte offset of the step's first byte in the path.
}

/// Whether `c` may appear in a path segment: the DQL lexer keeps it inside
/// an identifier, and it is not `.`, `[` or `]`.
bool isDqlSegmentByte(char c) @safe pure nothrow @nogc
{
    switch (c)
    {
        case ' ', '\t', '\r', '\n', '(', ')', ',', '=', '!', '<', '>', '&', '|',
            '"', '\'', '`', '.', '[', ']':
            return false;
        default:
            return true;
    }
}

/// Reads the step at `at`, advancing it; `first` selects the leading
/// segment, which has no `.` before it. A fault is left in `fault`.
private DqlPathStep readStep(return scope const(char)[] path, ref size_t at, bool first,
    out DqlParseError fault) @safe pure nothrow @nogc
{
    const start = at;
    if (!first)
    {
        if (path[at] == '[')
        {
            at++;
            const digits = at;
            size_t value;
            while (at < path.length && path[at] >= '0' && path[at] <= '9')
            {
                const digit = path[at] - '0';
                if (value > (size_t.max - digit) / 10)
                {
                    fault = DqlParseError("index overflows", digits, at - digits + 1);
                    return DqlPathStep.init;
                }
                value = value * 10 + digit;
                at++;
            }
            if (at == digits)
                fault = DqlParseError("expected digits in an index", at, 1);
            else if (at >= path.length || path[at] != ']')
                fault = DqlParseError("unclosed index", start, at - start);
            if (fault.message !is null)
                return DqlPathStep.init;
            at++;
            return DqlPathStep(DqlPathStepKind.index, null, value, start);
        }
        if (path[at] != '.')
        {
            fault = DqlParseError("expected '.' or '[' between path steps", at, 1);
            return DqlPathStep.init;
        }
        at++;
    }
    const nameStart = at;
    while (at < path.length && isDqlSegmentByte(path[at]))
        at++;
    if (at == nameStart)
    {
        fault = DqlParseError(first && at < path.length && path[at] == '['
            ? "an index must follow a segment" : "empty path segment", nameStart, 1);
        return DqlPathStep.init;
    }
    return DqlPathStep(DqlPathStepKind.member, path[nameStart .. at], 0, nameStart);
}

/** The number of steps in `path`, or the first fault in it at its byte
offset. An empty path is a fault. */
Expected!(size_t, DqlParseError) validateDqlPath(scope const(char)[] path)
    @safe pure nothrow @nogc
{
    if (path.length == 0)
        return err!size_t(DqlParseError("empty path", 0, 0));
    size_t at, steps;
    while (at < path.length)
    {
        DqlParseError fault;
        readStep(path, at, steps == 0, fault);
        if (fault.message !is null)
            return err!size_t(fault);
        steps++;
    }
    return ok!DqlParseError(steps);
}

/// Forward range over the steps of a path $(LREF validateDqlPath) accepted.
struct DqlPathSteps
{
    private const(char)[] _path;
    private size_t _next;
    private DqlPathStep _front;
    private bool _empty;
    private bool _first = true;

    /// Positions the range on the first step of `path`.
    this(return scope const(char)[] path) @safe pure nothrow @nogc
    {
        _path = path;
        popFront();
    }

    /// Forward-range primitives.
    bool empty() const scope @safe pure nothrow @nogc => _empty;
    /// ditto
    DqlPathStep front() const return scope @safe pure nothrow @nogc
    in (!empty) => _front;
    /// ditto
    void popFront() scope @safe pure nothrow @nogc
    {
        if (_next >= _path.length)
        {
            _empty = true;
            return;
        }
        DqlParseError fault;
        _front = readStep(_path, _next, _first, fault);
        assert(fault.message is null, "dqlPathSteps: the path was not validated");
        _first = false;
    }
    /// ditto
    DqlPathSteps save() const return scope @safe pure nothrow @nogc => this;
}

/// The steps of `path`, which $(LREF validateDqlPath) has accepted.
DqlPathSteps dqlPathSteps(return scope const(char)[] path) @safe pure nothrow @nogc
    => DqlPathSteps(path);

///
@("dql.path.validateDqlPath.grammar")
@safe nothrow @nogc // not `pure`: `Expected.error` reaches an impure hook
unittest
{
    static struct Case { string path; size_t steps; size_t faultAt = size_t.max; }
    static immutable Case[] cases = [
        Case("a", 1),
        Case("pointer.phase", 2),
        Case("stops[0]", 2),
        Case("a[12].b-c:d[3]", 4),
        Case("a[0][1]", 3),
        Case("", 0, 0),
        Case(".a", 0, 0),
        Case("a.", 0, 2),
        Case("a..b", 0, 2),
        Case("[0]", 0, 0),
        Case("a[]", 0, 2),
        Case("a[x]", 0, 2),
        Case("a[1", 0, 1),
        Case("a]", 0, 1),
        Case("a b", 0, 1),
        Case("a[99999999999999999999]", 0, 2),
    ];
    foreach (c; cases)
    {
        const result = validateDqlPath(c.path);
        if (c.faultAt == size_t.max)
            assert(result.hasValue && result.value == c.steps, c.path);
        else
            assert(result.hasError && result.error.offset == c.faultAt, c.path);
    }
}

///
@("dql.path.dqlPathSteps.walk")
@safe pure nothrow @nogc
unittest
{
    const path = "configuration[1].dependency";
    assert(validateDqlPath(path).hasValue);
    auto steps = dqlPathSteps(path);
    assert(steps.front.kind == DqlPathStepKind.member && steps.front.name == "configuration");
    steps.popFront();
    assert(steps.front.kind == DqlPathStepKind.index && steps.front.index == 1);
    assert(steps.front.offset == 13);
    steps.popFront();
    assert(steps.front.name == "dependency" && steps.front.offset == 17);
    steps.popFront();
    assert(steps.empty);
}
