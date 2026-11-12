/** Application-facing recovery service; initialization and cleanup use a CPU worker. */
module session_runtime;

import core.time : Duration, MonoTime, msecs, seconds;
import editor_document : Document;
import session_archive : ArchiveCleanup, pruneSessionArchive;
import session_checkpoint : CheckpointWriter;
import session_directory : SessionDirectory;
import session_snapshot : SessionSnapshot;
import sparkles.event_horizon.raw_pool : CpuJob, RawCompletion, RawCpuPool, RawPoolResult;

private enum Maintenance : ubyte { initialize, cleanup }

private final class MaintenanceJob
{
    Maintenance kind;
    string base, root, error;
    SessionDirectory directory;
    ArchiveCleanup cleanup;
    ulong through;
    bool done;
}

/**
Observe state on the application thread, poll with the host clock, and flush
before orderly exit. Archive creation and retention run on a maintenance
worker independently of checkpoint serialization. Shutdown releases the lease
only after both workers stop; it does not promise to submit unflushed state.
*/
final class RecoverySession
{
    private alias Pool = RawCpuPool!(2, 2, CpuJob);
    private Pool pool;
    private MaintenanceJob job;
    private SessionDirectory directory;
    private CheckpointWriter writer;
    private SessionSnapshot latest;
    private string base, root, initializationError, cleanupNotice;
    private ulong revision, cleanedThrough, flushedRevision;
    private MonoTime firstObserved, retryAt;
    private bool started, stopped, flushing, haveFirstObserved;

    /// The platform supplies an existing durable namespace root enclosing the archive registry.
    this(string base, string root) @safe nothrow
    {
        this.base = base;
        this.root = root;
        poll();
    }

    ulong currentRevision() const @safe pure nothrow @nogc => revision;
    ulong durableRevision() const @safe pure nothrow @nogc => writer is null ? 0 : writer.durableRevision;
    ulong durableGeneration() const @safe pure nothrow @nogc => writer is null ? 0 : writer.durableGeneration;
    string directoryPath() const @safe pure nothrow @nogc => directory is null ? null : directory.path;
    bool pending() const @safe pure nothrow @nogc => revision > durableRevision;
    bool ready() const @safe pure nothrow @nogc => writer !is null;
    bool maintenanceBusy() const @safe pure nothrow @nogc => job !is null;
    string error() const @safe pure nothrow @nogc
        => initializationError.length ? initializationError : writer is null ? null : writer.error;
    string notice() const @safe pure nothrow @nogc
        => cleanupNotice.length ? cleanupNotice : writer is null ? null : writer.notice;

    /// Capture only changed state, retaining text roots without flattening bytes on this thread.
    void observe(scope Document[] documents, ulong active, string acceptedTheme,
        MonoTime now = MonoTime.currTime) @safe nothrow
    {
        if (stopped || (latest !is null && latest.matches(documents, active, acceptedTheme))) return;
        if (revision == ulong.max)
        {
            initializationError = "Recovery observation identities are exhausted.";
            return;
        }
        latest = SessionSnapshot.capture(documents, active, acceptedTheme, ++revision);
        if (!haveFirstObserved) { firstObserved = now; haveFirstObserved = true; }
        if (writer !is null)
        {
            writer.request(latest, now);
            haveFirstObserved = false;
        }
    }

    /// Publish maintenance/checkpoint receipts and schedule bounded background work.
    void poll(MonoTime now = MonoTime.currTime) @safe nothrow
    {
        if (stopped) return;
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        if (job !is null && job.done)
        {
            auto finished = job;
            job = null;
            if (finished.kind == Maintenance.initialize)
            {
                initializationError = finished.error;
                if (finished.directory !is null)
                {
                    directory = finished.directory;
                    writer = new CheckpointWriter(directory);
                    if (latest !is null) writer.request(latest, haveFirstObserved ? firstObserved : now);
                    haveFirstObserved = false;
                }
                else retryAt = now + 1.seconds;
            }
            else if (finished.cleanup.issues.length) cleanupNotice = finished.cleanup.issues[0];
        }
        if (writer is null)
        {
            if (job is null && now >= retryAt)
            {
                auto requested = new MaintenanceJob;
                requested.base = base;
                requested.root = root;
                if (!submit(requested)) retryAt = now + 1.seconds;
            }
            return;
        }
        if (flushing && writer.currentRevision > flushedRevision)
        {
            flushedRevision = writer.currentRevision;
            writer.flush(now);
        }
        else writer.poll(now);
        if (job is null && writer.durableGeneration > cleanedThrough)
        {
            auto requested = new MaintenanceJob;
            requested.kind = Maintenance.cleanup;
            requested.directory = directory;
            requested.through = writer.durableGeneration;
            if (submit(requested)) cleanedThrough = requested.through;
        }
    }

    /// Stay in flush mode through initialization and any later observations until the latest receipt.
    void flush(MonoTime now = MonoTime.currTime) @safe nothrow
    {
        flushing = true;
        flushedRevision = 0;
        poll(now);
    }

    /// Resume periodic checkpoints after cancelling an orderly exit.
    void resume() @safe nothrow @nogc { flushing = false; }

    bool overdue(MonoTime now) const @safe pure nothrow @nogc
        => writer !is null ? writer.overdue(now)
            : pending && haveFirstObserved && now - firstObserved >= 1.seconds;

    Duration nextPoll(MonoTime now) const @safe pure nothrow @nogc
    {
        if (job !is null) return 8.msecs;
        if (writer !is null) return writer.nextPoll(now);
        return retryAt > now ? retryAt - now : 0.msecs;
    }

    /// Stop maintenance before closing the archive lease owned by the checkpoint writer.
    void shutdown() @safe nothrow
    {
        if (stopped) return;
        stopped = true;
        if (started) pool.shutdown(true);
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        if (writer !is null) writer.shutdown();
        else if (job !is null && job.directory !is null) job.directory.close();
    }

    private bool submit(MaintenanceJob requested) @safe nothrow
    {
        if (!started) started = Pool.start(pool, 1) == RawPoolResult.accepted;
        if (!started)
        {
            initializationError = "The recovery maintenance worker could not start.";
            return false;
        }
        job = requested;
        if (pool.submit(CpuJob(&work, &completed,
            (() @trusted => cast(void*) requested)(), requested.through)) == RawPoolResult.accepted) return true;
        job = null;
        initializationError = "Recovery maintenance could not be queued.";
        return false;
    }

    private static void work(void* raw) @safe nothrow
    {
        auto requested = (() @trusted => cast(MaintenanceJob) raw)();
        if (requested.kind == Maintenance.initialize)
        {
            auto created = SessionDirectory.create(requested.base, requested.root);
            if (created.hasError) requested.error = created.error.message;
            else requested.directory = created.value;
        }
        else requested.cleanup = pruneSessionArchive(requested.directory, requested.through);
    }

    private static void completed(void* raw, bool cancelled) @safe nothrow @nogc
    {
        auto requested = (() @trusted => cast(MaintenanceJob) raw)();
        if (cancelled) requested.error = "Recovery maintenance was cancelled.";
        requested.done = true;
    }
}

/// Initialization retains the newest edits and explicit flush acknowledges them before closure.
@("editor.recovery.backgroundInitializationAndFlush")
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
    import editor_document : Document;
    import session_archive : readSessionGeneration;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto recovery = new RecoverySession(buildPath(fixture.dir, "sessions"), fixture.dir);
    scope (exit) recovery.shutdown();
    auto document = new Document(7, "draft");
    Document[] documents = [document];
    document.field.insert("before");
    recovery.observe(documents, 7, "github-dark");
    document.field.insert(" after");
    recovery.observe(documents, 7, "github-dark");
    assert(recovery.currentRevision == 2 && recovery.pending);
    recovery.flush();
    const deadline = MonoTime.currTime + 3.seconds;
    while (recovery.pending && MonoTime.currTime < deadline)
    {
        recovery.poll();
        (() @trusted => Thread.yield())();
    }
    assert(!recovery.pending && recovery.durableRevision == 2 && !recovery.error.length);
    const saved = readSessionGeneration(recovery.directoryPath, recovery.durableGeneration);
    assert(saved.hasValue && saved.value.tabs[0].content == "before after");
    const path = recovery.directoryPath;
    recovery.shutdown();
    import session_directory : SessionDirectory;
    auto reclaimed = SessionDirectory.claim(path);
    assert(reclaimed.hasValue);
    reclaimed.value.close();
}
