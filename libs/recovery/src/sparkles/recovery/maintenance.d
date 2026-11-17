/**
Recovery's maintenance jobs: the archive work that must stay off the
application thread but is not a checkpoint.

A host runs `MaintenanceTask`s, one at a time, on a
`MaintenanceQueue`: creating the archive (`InitializeTask`), retiring old
generations (`PruneTask`), and its own kinds, such as scanning for archives
to offer and retiring adopted ones, as subclasses. Each task records its
failure in `error`; a task shutdown cancelled says so.
*/
module sparkles.recovery.maintenance;

import sparkles.event_horizon.job_queue : JobQueue;
import sparkles.recovery.archive : ArchiveCleanup, ArchiveLayout, pruneArchive;
import sparkles.recovery.directory : LeasedDirectory;

/// One maintenance job; `run` executes on the worker.
abstract class MaintenanceTask
{
    /// The failure to show, or null.
    string error;

    /// The work.
    abstract void run() @safe nothrow;

    /// Shutdown cancelled this task before it ran.
    void cancelled() @safe nothrow { error = "Recovery maintenance was cancelled."; }
}

/// A queue for one maintenance task at a time, plus one waiting.
alias MaintenanceQueue = JobQueue!(MaintenanceTask, 2);

/// Creates a private archive under `base`, which lies within the durable `root`.
final class InitializeTask : MaintenanceTask
{
    string base, root;           ///
    LeasedDirectory directory;   /// the new archive's lease, on success

    ///
    this(string base, string root) @safe pure nothrow { this.base = base; this.root = root; }

    override void run() @safe nothrow
    {
        auto created = LeasedDirectory.create(base, root);
        if (created.hasError) error = created.error.message;
        else directory = created.value;
    }
}

/// Prunes an archive through an acknowledged generation (`pruneArchive`).
final class PruneTask : MaintenanceTask
{
    LeasedDirectory directory;  ///
    ulong through;              ///
    ArchiveLayout layout;       ///
    /// Null for a valid payload, the issue otherwise; null accepts every readable one.
    string delegate(ulong generation, string bytes) @safe nothrow validate;
    ArchiveCleanup cleanup;     /// the result

    ///
    this(LeasedDirectory directory, ulong through, ArchiveLayout layout,
        string delegate(ulong, string) @safe nothrow validate = null) @safe pure nothrow
    {
        this.directory = directory;
        this.through = through;
        this.layout = layout;
        this.validate = validate;
    }

    override void run() @safe nothrow { cleanup = pruneArchive(directory, through, layout, validate); }
}

/// Initialization and pruning run on the queue and come back with their results.
@("recovery.maintenance.initializeThenPrune")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import sparkles.event_horizon.job_queue : Drain;
    import sparkles.recovery.archive : appendGeneration, readGeneration;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    MaintenanceTask finish(MaintenanceQueue queue)
    {
        MaintenanceTask[] done;
        const deadline = MonoTime.currTime + 3.seconds;
        while (!done.length && MonoTime.currTime < deadline)
        {
            done = queue.poll();
            (() @trusted => Thread.yield())();
        }
        assert(done.length == 1);
        return done[0];
    }

    auto fixture = TmpFS.create();
    auto queue = new MaintenanceQueue;
    scope (exit) queue.shutdown(Drain.run);
    auto init = new InitializeTask(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(queue.submit(init).hasValue);
    assert(finish(queue) is init && init.error is null && init.directory.owned);
    scope (exit) init.directory.close();
    foreach (generation; 1UL .. 5UL)
        assert(appendGeneration(init.directory.path, generation, "payload").hasValue);
    auto prune = new PruneTask(init.directory, 4, ArchiveLayout.init);
    assert(queue.submit(prune).hasValue);
    assert(finish(queue) is prune && prune.cleanup.removed == [2, 1]);
    assert(readGeneration(init.directory.path, 3).hasValue);
}
