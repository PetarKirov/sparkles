/**
The editor's checkpoint writer: `sparkles:recovery`'s coalescing background
writer over session snapshots, in the editor's archive layout.
*/
module session_checkpoint;

import core.time : Duration, msecs;
import session_archive : sessionLayout;
import session_snapshot : SessionSnapshot;
import sparkles.recovery.directory : LeasedDirectory;
import RecoveryWriter = sparkles.recovery.writer;

/// One running write and one latest desired snapshot (`sparkles.recovery.writer.CheckpointWriter`).
final class CheckpointWriter : RecoveryWriter.CheckpointWriter!SessionSnapshot
{
    /// Supply a freshly created archive, or the highest attempted generation in an existing one.
    this(LeasedDirectory directory, ulong lastGeneration = 0, Duration interval = 250.msecs) @safe nothrow
    {
        super(directory, sessionLayout, lastGeneration, interval);
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
    import session_snapshot : SessionSnapshot;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
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
    import core.time : MonoTime, seconds;
    import session_snapshot : SessionSnapshot;
    import editor_document : Document;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    auto fixture = TmpFS.create();
    auto directory = LeasedDirectory.create(buildPath(fixture.dir, "archives"), fixture.dir);
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
