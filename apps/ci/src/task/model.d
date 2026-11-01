/++
The task vocabulary ([SPEC §5](../../../../docs/specs/ci/task-dag/SPEC.md)):
task ids, nodes, edges, resource claims, outcomes, and events.

This module is a leaf: beside Phobos and `sparkles:base` it imports only the
action vocabulary ($(MREF task,action)). It knows no command, executor,
reporter, Event Horizon, or UI module.

Within a validated graph a task is referred to by its $(LREF TaskIndex) — its
position in presentation order. Outcomes and events carry indices rather than
ids, so they hold no pointers: a `SumType` of pointer-free members stays
`@safe` to assign, and an event can cross a channel without borrowing.
+/
module task.model;

import core.time : Duration, MonoTime;
import std.range.primitives : put;
import std.sumtype : match, SumType;

import sparkles.base.expected : Expected, err, ok;
import sparkles.base.text.errors : NoGcHook;

import sparkles.base.text.case_style : CaseStyle;
import sparkles.base.text.wire_names : AnyFormat, WireCase;

public import task.action : TaskAction;

/**
A fallible planning result: `Expected` under `NoGcHook`, so `value` and
`error` stay `pure nothrow` and reading the wrong side asserts.
*/
alias PlanExpected(T, E) = Expected!(T, E, NoGcHook);

/// `ok`/`err` for $(LREF PlanExpected).
PlanExpected!(T, E) planOk(E, T)(T value) => ok!(E, NoGcHook)(value);

/// ditto
PlanExpected!(T, E) planErr(T, E)(E error) => err!(T, NoGcHook)(error);

// ─────────────────────────────────────────────────────────────────────────────
// Identity
// ─────────────────────────────────────────────────────────────────────────────

/**
A task's stable, printable identity: `:`-separated segments derived from
semantic identity — `test:sparkles.base:unittest`,
`docs:verify:README.md:readme_versions`.

It never contains a memory address, random number, temporary path, or
discovery index ([SPEC §5.1]). Ids order by their text.
*/
struct TaskId
{
    private string text_;

    /// The id's text.
    string text() const @safe pure nothrow @nogc => text_;

    /// Whether this is the `.init` (empty) id.
    bool empty() const @safe pure nothrow @nogc => text_.length == 0;

    int opCmp(const TaskId rhs) const @safe pure nothrow @nogc
        => text_ < rhs.text_ ? -1 : text_ > rhs.text_;

    bool opEquals(const TaskId rhs) const @safe pure nothrow @nogc => text_ == rhs.text_;

    size_t toHash() const @safe pure nothrow => hashOf(text_);

    void toString(Writer)(ref Writer w) const => put(w, text_);
}

/// Why a segment list is not a valid $(LREF TaskId).
@WireCase(CaseStyle.kebabCase)
enum TaskIdError
{
    noSegments,   /// no segment at all
    emptySegment, /// a segment is empty
    reservedChar, /// a segment holds `:`, whitespace, or a control character
}

/**
Joins `segments` into a $(LREF TaskId). A segment may hold any character but
`:`, whitespace, and control characters; a package's qualified name is a
segment once passed through $(LREF qualifiedNameSegment).
*/
PlanExpected!(TaskId, TaskIdError) taskId(scope const(char[])[] segments...) @safe pure nothrow
{
    if (segments.length == 0)
        return planErr!TaskId(TaskIdError.noSegments);
    size_t length = segments.length - 1;
    foreach (segment; segments)
    {
        if (segment.length == 0)
            return planErr!TaskId(TaskIdError.emptySegment);
        foreach (c; segment)
            if (c == ':' || c <= ' ' || c == '\x7f')
                return planErr!TaskId(TaskIdError.reservedChar);
        length += segment.length;
    }
    auto text = new char[length];
    size_t at;
    foreach (i, segment; segments)
    {
        if (i)
            text[at++] = ':';
        text[at .. at + segment.length] = segment[];
        at += segment.length;
    }
    return planOk!TaskIdError(TaskId(() @trusted { return cast(string) text; }()));
}

///
@("task.model.taskId.formatting")
@safe pure nothrow
unittest
{
    assert(taskId("test", qualifiedNameSegment("sparkles:base"), "unittest").value.text
        == "test:sparkles.base:unittest");
    assert(taskId("docs", "verify", "README.md", "readme_versions").value.text
        == "docs:verify:README.md:readme_versions");
    assert(taskId("plan").value.text == "plan");

    assert(taskId().error == TaskIdError.noSegments);
    assert(taskId("test", "").error == TaskIdError.emptySegment);
    assert(taskId("test", "sparkles:base").error == TaskIdError.reservedChar);
    assert(taskId("a b").error == TaskIdError.reservedChar);
    assert(taskId("a\tb").error == TaskIdError.reservedChar);

    assert(taskId("a", "b").value < taskId("a", "c").value);
    assert(taskId("a", "b").value == taskId("a", "b").value);
}

/// A qualified package name as one id segment: `sparkles:base` →
/// `sparkles.base`. Package names never contain `.`, so the map is
/// injective.
string qualifiedNameSegment(scope const(char)[] qualifiedName) @safe pure nothrow
{
    auto segment = qualifiedName.dup;
    foreach (ref c; segment)
        if (c == ':')
            c = '.';
    return (() @trusted => cast(string) segment)();
}

/**
A task's position in a validated graph's presentation order. Outcomes and
events refer to tasks by index; the graph maps an index back to its node.
*/
struct TaskIndex
{
    uint value = uint.max; ///

    /// Whether this names a task (the `.init` index names none).
    bool valid() const @safe pure nothrow @nogc => value != uint.max;

    int opCmp(const TaskIndex rhs) const @safe pure nothrow @nogc
        => value < rhs.value ? -1 : value > rhs.value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Nodes
// ─────────────────────────────────────────────────────────────────────────────

/// The class of work a node performs; decides its default claim.
@WireCase(CaseStyle.kebabCase)
enum TaskKind
{
    plan,        /// a planning step: discovery, selection, a marker scan
    scan,        /// a pure scan, parse, or git query
    build,       /// `dub build` of a package
    test,        /// ordinary `dub test` of a package (a coverage attempt too)
    specialTest, /// an extracted `--better-c` or `--wasm` test
    example,     /// one standalone or markdown D example build/run
    classify,    /// a package-result classification
    reduce,      /// a reducer: coverage merge, file verdict, aggregation
    rewrite,     /// a mutating documentation rewrite
    fetch,       /// a network request
    report,      /// a final report or summary
    cleanup,     /// idempotent cleanup under cancellation protection
}

/**
Where a node sits in dry-run output, buffered replay, failure replay, and
summaries ([SPEC §5.1]): command phase, then package/file key, then work-kind
key, then within-owner ordinal, compared in that order.
*/
struct PresentationKey
{
    uint phase;   ///
    string owner; /// the package id or repository-relative file path
    uint work;    ///
    uint ordinal; ///

    int opCmp(const PresentationKey rhs) const @safe pure nothrow @nogc
    {
        if (phase != rhs.phase)
            return phase < rhs.phase ? -1 : 1;
        if (owner != rhs.owner)
            return owner < rhs.owner ? -1 : 1;
        if (work != rhs.work)
            return work < rhs.work ? -1 : 1;
        return ordinal < rhs.ordinal ? -1 : ordinal > rhs.ordinal;
    }
}

/**
What a node holds while it runs ([SPEC §5.3]). The executor admits a node only
when every exclusive key is free and `jobsWeight` tokens are available.
*/
struct ResourceClaim
{
    uint jobsWeight = 1;    /// >= 1 for runnable work
    ulong memoryHintBytes;  /// a planning and reporting hint, not a second scheduler
    string[] exclusiveKeys; /// semantic resources: `workspace-write:README.md`, `coverage-publish`

    /// The weight actually taken from `capacity` tokens: a claim larger than
    /// the capacity is clamped, so it runs alone rather than deadlocking.
    uint admittedWeight(uint capacity) const @safe pure nothrow @nogc
        => jobsWeight < capacity ? jobsWeight : capacity;
}

/**
The default claim for a `kind` of work ([SPEC §5.3]'s weight table). A
compiler-bearing node weighs 2; everything else 1. A mutating rewrite also
needs its `workspace-write:<path>` key — see $(LREF rewriteClaim). Package
overrides (a DMD-frontend-heavy package weighs 4) are the planner's.
*/
ResourceClaim defaultClaim(TaskKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
        case TaskKind.build:
        case TaskKind.test:
        case TaskKind.specialTest:
        case TaskKind.example:
            return ResourceClaim(jobsWeight: 2);
        case TaskKind.plan:
        case TaskKind.scan:
        case TaskKind.classify:
        case TaskKind.reduce:
        case TaskKind.rewrite:
        case TaskKind.fetch:
        case TaskKind.report:
        case TaskKind.cleanup:
            return ResourceClaim(jobsWeight: 1);
    }
}

/// The claim of a mutating rewrite of `path`: weight 1 plus the exclusive
/// `workspace-write:<path>` key.
ResourceClaim rewriteClaim(string path) @safe pure nothrow
    => ResourceClaim(jobsWeight: 1, exclusiveKeys: ["workspace-write:" ~ path]);

@("task.model.ResourceClaim.defaultsAndClamp")
@safe pure nothrow
unittest
{
    assert(defaultClaim(TaskKind.test).jobsWeight == 2);
    assert(defaultClaim(TaskKind.scan).jobsWeight == 1);
    assert(rewriteClaim("README.md").exclusiveKeys == ["workspace-write:README.md"]);

    const heavy = ResourceClaim(jobsWeight: 4);
    assert(heavy.admittedWeight(8) == 4);
    assert(heavy.admittedWeight(3) == 3, "a claim over capacity runs alone");
}

/// Whether a node's failure is authoritative.
@WireCase(CaseStyle.kebabCase)
enum FailurePolicy
{
    /// A failure is the package's or file's result and may trigger fail-fast.
    authoritative,
    /// A failure is classified by a later node (a coverage attempt whose
    /// plain retry decides): it never triggers fail-fast ([SPEC §8]).
    provisional,
}

/// What the reporter keeps of a node's output.
@WireCase(CaseStyle.kebabCase)
enum OutputPolicy
{
    /// Buffer the output and replay it as the node's block.
    replay,
    /// Keep a bounded tail, shown only if the node does not succeed.
    tailOnFailure,
    /// The node writes nothing worth showing (a pure reducer).
    none,
}

/// A unit of work in a task graph ([SPEC §5.1]).
struct TaskNode
{
    TaskId id;                   ///
    TaskKind kind;               ///
    string label;                /// a short human label
    PresentationKey order;       ///
    ResourceClaim resources;     ///
    TaskAction action;           ///
    FailurePolicy failurePolicy; ///
    OutputPolicy outputPolicy;   ///
}

// ─────────────────────────────────────────────────────────────────────────────
// Edges
// ─────────────────────────────────────────────────────────────────────────────

/// When an edge lets its dependent start ([SPEC §5.2]).
@WireCase(CaseStyle.kebabCase)
enum EdgeCondition
{
    /// The prerequisite succeeded, was degraded, or was skipped.
    onSuccess,
    /// The prerequisite failed: a fallback.
    onFailure,
    /// The prerequisite reached any outcome but cancellation: a reducer.
    onCompletion,
    /// The prerequisite reached any outcome at all: cleanup.
    always,
}

/// Why an edge exists; shown by a dry run.
@WireCase(CaseStyle.kebabCase)
enum EdgeReason
{
    packageDependency, /// the dependent package depends on the prerequisite
    planning,          /// a planning step feeds the work it planned
    coverageFallback,  /// a plain retry of a failed coverage attempt
    classification,    /// an attempt feeds its package's classification
    reduction,         /// a result feeds a reducer
    publication,       /// a reducer feeds its atomic write
    summary,           /// a result feeds the run summary
    cleanup,           /// work feeds its cleanup
}

/// A directed edge: `dependent` waits on `prerequisite` under `condition`.
struct TaskEdge
{
    TaskId prerequisite;     ///
    TaskId dependent;        ///
    EdgeCondition condition; ///
    EdgeReason reason;       ///
}

// ─────────────────────────────────────────────────────────────────────────────
// Outcomes
// ─────────────────────────────────────────────────────────────────────────────

/// Authoritative work completed and its contract holds.
struct Succeeded
{
}

/// Why a task failed.
@WireCase(CaseStyle.kebabCase)
enum FailureReason
{
    exitStatus,  /// the process exited nonzero
    signal,      /// the process was killed by a signal
    timeout,     /// the action exceeded its timeout
    spawnFailed, /// the process could not start
    planning,    /// a planning node found an error (a missing selected file)
    contract,    /// an in-process action's contract does not hold
}

/// Work ran, or could not start, and its authoritative contract does not hold.
struct Failed
{
    FailureReason reason; ///
    /// The exit status or signal number, when `reason` has one.
    int status;
}

/// Why work was excluded.
@WireCase(CaseStyle.kebabCase)
enum SkipReason
{
    platform,  /// the host does not satisfy the package's or file's platforms
    directive, /// a source directive excluded it
}

/// A declared eligibility rule excluded the work.
struct Skipped
{
    SkipReason reason; ///
}

/// Why work was cancelled.
@WireCase(CaseStyle.kebabCase)
enum CancelReason
{
    notAdmitted, /// pending when admission closed
    interrupted, /// running when its scope was cancelled
}

/// Work was admitted or pending but interrupted by fail-fast, signal, or
/// shutdown. Adds no failure of its own.
struct Cancelled
{
    CancelReason reason; ///
}

/// Why a task was blocked.
@WireCase(CaseStyle.kebabCase)
enum BlockReason
{
    /// A required prerequisite failed.
    prerequisiteFailed,
    /// A required prerequisite was cancelled.
    prerequisiteCancelled,
    /// A required prerequisite was itself blocked.
    prerequisiteBlocked,
    /// The prerequisite's outcome made the edge's condition impossible
    /// without being a failure (an `onFailure` edge from a success).
    conditionUnmet,
}

/**
A required prerequisite did not succeed or its edge condition became
impossible. `cause` is the immediate prerequisite; `root` is the task whose
outcome started the chain. `fromFailure` says whether that root failed —
the block then fails the command ([SPEC §5.4]).
*/
struct Blocked
{
    BlockReason reason; ///
    TaskIndex cause;    ///
    TaskIndex root;     ///
    bool fromFailure;   ///
}

/// Why a result is degraded.
@WireCase(CaseStyle.kebabCase)
enum DegradedReason
{
    noCoverage,        /// tests passed only without coverage
    partialPopulation, /// some statistics pages are missing
    usageUnavailable,  /// process RSS/CPU sampling is unavailable
    evidenceMissing,   /// optional evidence (a clone, a revision) is unavailable
}

/// The authoritative contract passed, but optional evidence or measurement
/// is unavailable.
struct Degraded
{
    DegradedReason reason; ///
}

/// A task's terminal outcome ([SPEC §5.4]). Every member is pointer-free.
alias TaskOutcome = SumType!(Succeeded, Failed, Skipped, Cancelled, Blocked, Degraded);

/// The member a $(LREF TaskOutcome) holds, as a plain enum: what edge
/// resolution and counting switch over.
@WireCase(CaseStyle.kebabCase)
enum OutcomeKind
{
    succeeded, ///
    failed,    ///
    skipped,   ///
    cancelled, ///
    blocked,   ///
    degraded,  ///
}

/// The kind of `outcome`.
OutcomeKind kindOf(const TaskOutcome outcome) @safe pure nothrow @nogc
    => outcome.match!(
        (const Succeeded _) => OutcomeKind.succeeded,
        (const Failed _) => OutcomeKind.failed,
        (const Skipped _) => OutcomeKind.skipped,
        (const Cancelled _) => OutcomeKind.cancelled,
        (const Blocked _) => OutcomeKind.blocked,
        (const Degraded _) => OutcomeKind.degraded,
    );

/// Whether `outcome` fails the command on its own ([SPEC §5.4]): a failure,
/// or a block that descends from one.
bool failsCommand(const TaskOutcome outcome) @safe pure nothrow @nogc
    => outcome.match!(
        (const Failed _) => true,
        (const Blocked b) => b.fromFailure,
        _ => false,
    );

@("task.model.TaskOutcome.kindAndFailure")
@safe pure nothrow @nogc
unittest
{
    assert(kindOf(TaskOutcome(Degraded(DegradedReason.noCoverage))) == OutcomeKind.degraded);
    assert(failsCommand(TaskOutcome(Failed(FailureReason.exitStatus, 1))));
    assert(failsCommand(TaskOutcome(Blocked(BlockReason.prerequisiteFailed,
        TaskIndex(0), TaskIndex(0), fromFailure: true))));
    assert(!failsCommand(TaskOutcome(Blocked(BlockReason.prerequisiteCancelled,
        TaskIndex(0), TaskIndex(0), fromFailure: false))));
    assert(!failsCommand(TaskOutcome(Cancelled(CancelReason.notAdmitted))));
    assert(!failsCommand(TaskOutcome(Skipped(SkipReason.platform))));

    // Pointer-free members keep reassignment `@safe`.
    auto outcome = TaskOutcome(Succeeded());
    outcome = TaskOutcome(Failed(FailureReason.timeout));
    assert(kindOf(outcome) == OutcomeKind.failed);
}

// ─────────────────────────────────────────────────────────────────────────────
// Events
// ─────────────────────────────────────────────────────────────────────────────

/// The validated graph is about to run.
struct GraphPlanned
{
    size_t nodes;   ///
    size_t edges;   ///
    uint capacity;  /// total weighted capacity
}

/// Every edge condition of a task is satisfied.
struct TaskReady
{
    TaskIndex task; ///
}

/// A task was admitted and its action began.
struct TaskStarted
{
    TaskIndex task; ///
}

/// A task's output stream.
@WireCase(CaseStyle.kebabCase)
enum OutputStream
{
    stdout, ///
    stderr, ///
}

/**
One assembled output line of a task. `line` excludes the terminator;
`unterminated` marks the final fragment of a stream that did not end in a
newline, emitted exactly once ([SPEC §5.5]).
*/
struct TaskOutput
{
    TaskIndex task;      ///
    OutputStream stream; ///
    ulong streamSeq;     /// this stream's line number, from 0
    ulong chunkSeq;      /// the task's line number across both streams, from 0
    string line;         ///
    bool unterminated;   ///
}

/// A resource-usage observation of a running task.
struct TaskUsage
{
    TaskIndex task;      ///
    ulong rssBytes;      ///
    Duration cpu;        ///
}

/// A task reached its terminal outcome.
struct TaskFinished
{
    TaskIndex task;      ///
    TaskOutcome outcome; ///
    Duration elapsed;    ///
}

/// Why the run's scope was cancelled.
@WireCase(CaseStyle.kebabCase)
enum CancelCause
{
    failFast,  /// an authoritative failure under `--fail-fast`
    interrupt, /// SIGINT
    terminate, /// SIGTERM
}

/// The run's scope was cancelled; emitted exactly once.
struct CancellationRequested
{
    CancelCause cause; ///
    /// The failure that triggered fail-fast; invalid for a signal.
    TaskIndex causalTask;
}

/// Every task is terminal.
struct RunFinished
{
    int exitCode; ///
}

/// What happened ([SPEC §5.5]).
alias TaskEventPayload = SumType!(GraphPlanned, TaskReady, TaskStarted, TaskOutput,
    TaskUsage, TaskFinished, CancellationRequested, RunFinished);

/// An event: a run-local sequence number and monotonic timestamp around
/// its payload. The executor is the sole producer.
struct TaskEvent
{
    ulong sequence;           ///
    MonoTime at;              ///
    TaskEventPayload payload; ///
}
