/**
Coalesced background checkpoints with separately acknowledged revisions.

A host observes its state on the application thread as immutable snapshots
and hands the latest to a `CheckpointWriter`, which keeps one write running
and one snapshot waiting. Each write encodes its snapshot on a worker and
appends it as a fresh generation (`sparkles.recovery.archive`); a revision
is acknowledged only once its generation is durable, and a failed or
unconfirmed write is retried under a new generation, never over the old one.

A snapshot is a class with, found by introspection:

$(TABLE
$(TR $(TH Member) $(TH Meaning))
$(TR $(TD `ulong revision() const`) $(TD increases with each observation; never zero))
$(TR $(TD `Expected!string encode(ulong generation) const`) $(TD the payload, on a worker))
)
*/
module sparkles.recovery.writer;

import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.base.expected : Expected;
import sparkles.event_horizon.job_queue : Drain, JobQueue;
import sparkles.recovery.archive : appendGeneration, ArchiveLayout, WriteReceipt;
import sparkles.recovery.directory : LeasedDirectory;

/// Whether `S` can be checkpointed: a class with `revision` and `encode`.
enum isSnapshot(S) = is(S == class) && __traits(compiles, (const S s) @safe nothrow {
    ulong r = s.revision;
    Expected!string bytes = s.encode(r);
});

/**
One running write and one latest desired snapshot. The supplied directory's
lease transfers to this writer, which closes it only after stopping its worker.
File generations increase per attempt, including retries after an unconfirmed
commit. Observation revisions identify captured application state separately.
*/
class CheckpointWriter(Snapshot)
if (isSnapshot!Snapshot)
{
    private static final class Job
    {
        Snapshot snapshot;
        string directory, error;
        ulong generation;
        ArchiveLayout layout;
        WriteReceipt receipt;

        void run() @safe nothrow
        {
            const bytes = snapshot.encode(generation);
            if (bytes.hasError) { error = bytes.error; return; }
            const written = appendGeneration(directory, generation, bytes.value, layout);
            if (written.hasError) error = written.error;
            else receipt = written.value;
        }

        void cancelled() @safe nothrow { error = "The recovery checkpoint was cancelled."; }
    }

    private JobQueue!(Job, 2) queue;
    private LeasedDirectory directory;
    private ArchiveLayout layout;
    private Snapshot wanted;
    private Job job;
    private Duration interval;
    private ulong nextGeneration, durableGeneration_, durableRevision_, submittedRevision_;
    private string error_, notice_;
    private bool stopped, scheduled, submitted, haveSince, haveAfterFlight;
    private MonoTime due, lastSubmitted, since, afterFlight;

    /// Supply a freshly created archive, or the highest attempted generation in an existing one.
    this(LeasedDirectory directory, ArchiveLayout layout = ArchiveLayout.init, ulong lastGeneration = 0,
        Duration interval = 250.msecs) @safe nothrow
    in (interval >= 0.msecs && interval <= 500.msecs)
    {
        this.directory = directory;
        this.layout = layout;
        this.interval = interval;
        nextGeneration = lastGeneration;
        queue = new JobQueue!(Job, 2);
        if (directory is null || !directory.owned) error_ = "The recovery archive lease is unavailable.";
        else startWorker();
    }

    /// The newest requested revision, or zero.
    ulong currentRevision() const @safe pure nothrow @nogc => wanted is null ? 0 : wanted.revision;
    /// The newest revision whose generation is durable.
    ulong durableRevision() const @safe pure nothrow @nogc => durableRevision_;
    /// That generation.
    ulong durableGeneration() const @safe pure nothrow @nogc => durableGeneration_;
    /// The revision of the latest submitted write.
    ulong submittedRevision() const @safe pure nothrow @nogc => submittedRevision_;
    /// The archive's path, while this writer holds it.
    string directoryPath() const @safe pure nothrow @nogc => directory is null ? null : directory.path;
    /// The latest failure, until a write succeeds.
    string error() const @safe pure nothrow @nogc => error_;
    /// The latest successful write's warning.
    string notice() const @safe pure nothrow @nogc => notice_;
    /// Whether a requested revision is not yet durable.
    bool pending() const @safe pure nothrow @nogc => currentRevision > durableRevision_;
    /// Whether a write is running.
    bool busy() const @safe pure nothrow @nogc => job !is null;
    /// Whether pending state has waited a second or more.
    bool overdue(MonoTime now) const @safe pure nothrow @nogc
        => haveSince && now - since >= 1.seconds;

    /// Retain the latest immutable state; continuous input never postpones its existing deadline.
    void request(Snapshot snapshot, MonoTime now = MonoTime.currTime) @safe nothrow
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

    /// Drain worker receipts, then submit the latest due state without encoding on this thread.
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
        auto requested = new Job;
        requested.snapshot = wanted;
        requested.directory = directory.path;
        requested.layout = layout;
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

version (unittest)
{
    /// A snapshot whose payload is its text, for the writer's tests.
    private final class TextSnapshot
    {
        string text;
        ulong revision_;
        this(string text, ulong revision) @safe pure nothrow { this.text = text; revision_ = revision; }
        ulong revision() const @safe pure nothrow @nogc => revision_;
        Expected!string encode(ulong) const @safe nothrow
        {
            import sparkles.base.expected : ok;
            string payload = text;
            return ok(payload);
        }
    }

    // Polls with `poll` until `until` holds, or three seconds pass.
    private void drain(scope void delegate() @safe nothrow poll, scope bool delegate() @safe nothrow until) @safe
    {
        import core.thread : Thread;
        const deadline = MonoTime.currTime + 3.seconds;
        while (!until() && MonoTime.currTime < deadline)
        {
            poll();
            (() @trusted => Thread.yield())();
        }
    }
}

/// A receipt acknowledges its captured revision while later input remains pending.
@("recovery.writer.capturedRevisionAndFlush")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.recovery.archive : readGeneration;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    static assert(isSnapshot!TextSnapshot);
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter!TextSnapshot(directory.value);
    scope (exit) writer.shutdown();
    const start = MonoTime.currTime;
    writer.request(new TextSnapshot("first", 1), start);
    writer.poll(start + 250.msecs);
    assert(writer.busy);
    writer.request(new TextSnapshot("firstlater", 2), start + 251.msecs);
    drain(() => writer.poll(start + 300.msecs), () => writer.durableRevision >= 1);
    assert(writer.durableRevision == 1 && writer.pending && writer.currentRevision == 2);
    assert(!writer.overdue(start + 1.seconds));
    assert(readGeneration(writer.directoryPath, writer.durableGeneration).value == "first");
    writer.flush(start + 301.msecs);
    drain(() => writer.poll(start + 350.msecs), () => !writer.pending);
    assert(!writer.pending && writer.durableRevision == 2 && !writer.error.length);
    assert(readGeneration(writer.directoryPath, writer.durableGeneration).value == "firstlater");
}

/// Continuous input leaves the first checkpoint deadline fixed and coalesces pending states.
@("recovery.writer.continuousRequestsDoNotStarve")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter!TextSnapshot(directory.value);
    scope (exit) writer.shutdown();
    const start = MonoTime.currTime;
    writer.request(new TextSnapshot("", 1), start);
    foreach (i; 1 .. 31)
    {
        const now = start + (i * 10).msecs;
        writer.request(new TextSnapshot("x", i + 1), now);
        writer.poll(now);
    }
    assert(writer.currentRevision == 31 && writer.submittedRevision == 26,
        "Input every 10 ms must still submit the captured state at 250 ms.");
    writer.flush(start + 501.msecs);
    drain(() => writer.poll(start + 501.msecs), () => !writer.pending);
    assert(!writer.pending && writer.durableRevision == 31 && !writer.error.length);
}

/// A failed encode is an error and a retry under the next generation, never acknowledgment.
@("recovery.writer.encodeFailureRetries")
@safe unittest
{
    version (linux) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("Recovery directory leases currently require Linux.");
    }
    import sparkles.base.expected : err;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;

    static final class Refusing
    {
        ulong revision() const @safe pure nothrow @nogc => 1;
        Expected!string encode(ulong) const @safe nothrow => err!string("cannot encode");
    }

    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
    assert(directory.hasValue);
    auto writer = new CheckpointWriter!Refusing(directory.value);
    scope (exit) writer.shutdown();
    const start = MonoTime.currTime;
    writer.request(new Refusing, start);
    writer.flush(start);
    drain(() => writer.poll(start), () => !writer.busy);
    assert(writer.error == "cannot encode" && writer.pending && writer.durableRevision == 0);
    assert(writer.nextPoll(start) == 1.seconds, "the retry waits a second");
}
