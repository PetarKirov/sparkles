/** Coalesced background recovery writes with separately acknowledged revisions. */
module session_checkpoint;

import core.time : Duration, MonoTime, msecs, seconds;
import session_archive : appendSessionGeneration;
import session_directory : SessionDirectory;
import session_snapshot : SessionSnapshot;
import document_files : SaveReceipt;
import sparkles.event_horizon.job_queue : Drain, JobQueue;

private final class CheckpointJob
{
    SessionSnapshot snapshot;
    string directory, error;
    ulong generation;
    SaveReceipt receipt;

    void run() @safe nothrow
    {
        const record = snapshot.record(generation);
        const written = appendSessionGeneration(directory, record);
        if (written.hasError) error = written.error;
        else receipt = written.value;
    }

    void cancelled() @safe nothrow { error = "The recovery checkpoint was cancelled."; }
}

/**
One running write and one latest desired snapshot. The supplied directory's
lease transfers to this writer, which closes it only after stopping its worker.
File generations increase per attempt, including retries after an unconfirmed
commit. Observation revisions identify captured application state separately.
*/
class CheckpointWriter
{
    private JobQueue!(CheckpointJob, 2) queue;
    private SessionDirectory directory;
    private SessionSnapshot wanted;
    private CheckpointJob job;
    private Duration interval;
    private ulong nextGeneration, durableGeneration_, durableRevision_, submittedRevision_;
    private string error_, notice_;
    private bool stopped, scheduled, submitted, haveSince, haveAfterFlight;
    private MonoTime due, lastSubmitted, since, afterFlight;

    /// Supply a freshly created archive, or the highest attempted generation in an existing one.
    this(SessionDirectory directory, ulong lastGeneration = 0, Duration interval = 250.msecs) @safe nothrow
    in (interval >= 0.msecs && interval <= 500.msecs)
    {
        this.directory = directory;
        this.interval = interval;
        nextGeneration = lastGeneration;
        queue = new JobQueue!(CheckpointJob, 2);
        if (directory is null || !directory.owned) error_ = "The recovery archive lease is unavailable.";
        else startWorker();
    }

    ulong currentRevision() const @safe pure nothrow @nogc => wanted is null ? 0 : wanted.revision;
    ulong durableRevision() const @safe pure nothrow @nogc => durableRevision_;
    ulong durableGeneration() const @safe pure nothrow @nogc => durableGeneration_;
    ulong submittedRevision() const @safe pure nothrow @nogc => submittedRevision_;
    string directoryPath() const @safe pure nothrow @nogc => directory is null ? null : directory.path;
    string error() const @safe pure nothrow @nogc => error_;
    string notice() const @safe pure nothrow @nogc => notice_;
    bool pending() const @safe pure nothrow @nogc => currentRevision > durableRevision_;
    bool busy() const @safe pure nothrow @nogc => job !is null;
    bool overdue(MonoTime now) const @safe pure nothrow @nogc
        => haveSince && now - since >= 1.seconds;

    /// Retain the latest immutable state; continuous input never postpones its existing deadline.
    void request(SessionSnapshot snapshot, MonoTime now = MonoTime.currTime) @safe nothrow
    {
        if (stopped || snapshot is null || snapshot.revision <= currentRevision) return;
        wanted = snapshot;
        if (!haveSince) { since = now; haveSince = true; }
        if (job !is null && !haveAfterFlight) { afterFlight = now; haveAfterFlight = true; }
        if (!scheduled)
        {
            scheduled = true;
            due = submitted ? lastSubmitted + interval : now + interval;
            if (due < now) due = now;
        }
    }

    /// Drain worker receipts, then submit the latest due state without flattening on this thread.
    void poll(MonoTime now = MonoTime.currTime) @safe nothrow
    {
        foreach (completed; queue.poll())
        {
            assert(completed is job, "one checkpoint is in flight at a time");
            job = null;
            if (completed.error.length || !completed.receipt.durable)
            {
                error_ = completed.error.length ? completed.error : completed.receipt.warning;
                if (!error_.length) error_ = "Recovery durability could not be acknowledged.";
                scheduleRetry(now);
            }
            else
            {
                durableRevision_ = completed.snapshot.revision;
                durableGeneration_ = completed.generation;
                error_ = null;
                notice_ = completed.receipt.warning;
                if (pending)
                {
                    since = haveAfterFlight ? afterFlight : now;
                    haveSince = true;
                }
                else { haveSince = false; scheduled = false; }
            }
        }
        if (stopped || job !is null || !scheduled || !pending || now < due) return;
        if (directory is null || !directory.owned)
        {
            error_ = "The recovery archive lease is unavailable.";
            scheduleRetry(now);
            return;
        }
        if (!queue.started && !startWorker()) { scheduleRetry(now); return; }
        if (nextGeneration == ulong.max)
        {
            error_ = "Recovery generation identities are exhausted.";
            scheduled = false;
            return;
        }
        auto requested = new CheckpointJob;
        requested.snapshot = wanted;
        requested.directory = directory.path;
        requested.generation = ++nextGeneration;
        if (queue.submit(requested).hasError)
        {
            error_ = "The recovery checkpoint could not be queued.";
            scheduleRetry(now);
            return;
        }
        job = requested;
        submittedRevision_ = wanted.revision;
        submitted = true;
        lastSubmitted = now;
        haveAfterFlight = false;
        scheduled = false;
    }

    /// Request immediate completion of current state, including a later snapshot behind a running write.
    void flush(MonoTime now = MonoTime.currTime) @safe nothrow
    {
        if (stopped || !pending) return;
        scheduled = true;
        due = now;
        poll(now);
    }

    /// Earliest useful service time; running jobs need completion polling.
    Duration nextPoll(MonoTime now) const @safe pure nothrow @nogc
    {
        if (busy) return 8.msecs;
        if (!scheduled || !pending) return Duration.max;
        return due > now ? due - now : 0.msecs;
    }

    /// Drain accepted writes and publish receipts before releasing the lease.
    /// Newer unsubmitted snapshots still require flush before orderly closure.
    void shutdown() @safe nothrow
    {
        if (stopped) return;
        stopped = true;
        queue.shutdown(Drain.run);
        poll();
        if (directory !is null) directory.close();
    }

    private bool startWorker() @safe nothrow
    {
        const started = queue.start();
        if (!started) error_ = "The recovery checkpoint worker could not start.";
        return started;
    }

    private void scheduleRetry(MonoTime now) @safe nothrow @nogc
    {
        scheduled = true;
        due = now + 1.seconds;
    }
}


/// A receipt acknowledges its captured revision while later input remains pending.
@("editor.sessionCheckpoint.capturedRevisionAndFlush")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native recovery archive currently requires Linux.");
    }
    import core.thread : Thread;
    import core.time : MonoTime, msecs, seconds;
    import editor_document : Document;
    import session_archive : readSessionGeneration;
    import session_directory : SessionDirectory;
    import session_snapshot : SessionSnapshot;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = SessionDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter(directory.value);
    scope (exit) writer.shutdown();
    auto document = new Document(7, "draft");
    document.field.insert("first");
    Document[] documents = [document];
    const start = MonoTime.currTime;
    writer.request(SessionSnapshot.capture(documents, 7, "github-dark", 1), start);
    writer.poll(start + 250.msecs);
    assert(writer.busy);
    document.field.insert("later");
    writer.request(SessionSnapshot.capture(documents, 7, "github-dark", 2), start + 251.msecs);
    const deadline = MonoTime.currTime + 3.seconds;
    while (writer.durableRevision < 1 && MonoTime.currTime < deadline)
    {
        writer.poll(start + 300.msecs);
        (() @trusted => Thread.yield())();
    }
    assert(writer.durableRevision == 1 && writer.pending && writer.currentRevision == 2);
    assert(!writer.overdue(start + 1.seconds));
    const captured = readSessionGeneration(writer.directoryPath, writer.durableGeneration);
    assert(captured.hasValue && captured.value.tabs[0].content == "first");
    writer.flush(start + 301.msecs);
    while (writer.pending && MonoTime.currTime < deadline)
    {
        writer.poll(start + 350.msecs);
        (() @trusted => Thread.yield())();
    }
    assert(!writer.pending && writer.durableRevision == 2 && !writer.error.length);
    const latest = readSessionGeneration(writer.directoryPath, writer.durableGeneration);
    assert(latest.hasValue && latest.value.tabs[0].content == "firstlater");
}

/// Continuous input leaves the first checkpoint deadline fixed and coalesces pending states.
@("editor.sessionCheckpoint.continuousEditsDoNotStarve")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native recovery archive currently requires Linux.");
    }
    import core.thread : Thread;
    import editor_document : Document;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = SessionDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter(directory.value);
    scope (exit) writer.shutdown();
    auto document = new Document(7, "draft");
    Document[] documents = [document];
    const start = MonoTime.currTime;
    writer.request(SessionSnapshot.capture(documents, 7, "github-dark", 1), start);
    foreach (i; 1 .. 31)
    {
        document.field.insert("x");
        const now = start + (i * 10).msecs;
        writer.request(SessionSnapshot.capture(documents, 7, "github-dark", i + 1), now);
        writer.poll(now);
    }
    assert(writer.currentRevision == 31 && writer.submittedRevision == 26,
        "Input every 10 ms must still submit the captured state at 250 ms.");
    writer.flush(start + 501.msecs);
    const deadline = MonoTime.currTime + 3.seconds;
    while (writer.pending && MonoTime.currTime < deadline)
    {
        writer.poll(start + 501.msecs);
        (() @trusted => Thread.yield())();
    }
    assert(!writer.pending && writer.durableRevision == 31 && !writer.error.length);
}
