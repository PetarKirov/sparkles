/** Bounded asynchronous native document reads and saves. */
module document_io;

import sparkles.base.expected : Expected, err, ok;
import sparkles.event_horizon.job_queue : Drain, JobQueue, SubmitRefusal;
import sparkles.text_buffer.text : Text;
import document_files : FinalLink, readRegularBytes, saveAtomic, SaveAuthorization, SaveReceipt;
import sparkles.base.text.envelope : decodeEnvelope, encodeEnvelope, LineEnding, TextEnvelope;

enum FileOperation : ubyte { open, probe, save }
struct FileTicket { ulong value; }

/// Published only after completion; callers receive const references.
class FileResult
{
    FileOperation operation;
    FileTicket ticket;
    ulong document;
    string path;
    Text revision;
    TextEnvelope decoded;
    string bytes;
    SaveReceipt receipt;
    string error;
    bool destinationExists, externalChange;
    private bool bom;
    private SaveAuthorization authorization;
    private string baseline;
    private bool baselineKnown;

    /// The worker's half: validation and persistent-text construction happen here.
    void run() @safe nothrow
    {
        try
        {
            if (operation == FileOperation.probe)
            {
                import std.file : exists;
                destinationExists = (() @trusted => exists(path))();
                if (!destinationExists) return;
                const read = readRegularBytes(path, 512UL << 20, FinalLink.follow);
                if (read.hasError) { error = read.error; return; }
                bytes = read.value;
                externalChange = !baselineKnown || read.value != baseline;
            }
            else if (operation == FileOperation.open)
            {
                const read = readRegularBytes(path, 512UL << 20, FinalLink.follow);
                if (read.hasError) { error = read.error; return; }
                const decoded = decodeEnvelope(read.value);
                if (decoded.hasError) { error = decoded.error; return; }
                this.decoded = decoded.value;
                bytes = read.value;
                revision = Text(decoded.value.content);
            }
            else
            {
                auto content = new char[revision.length];
                revision.copyTo(0, content.length, content);
                bytes = encodeEnvelope(TextEnvelope((() @trusted => cast(string) content)(), bom));
                const saved = saveAtomic(path, bytes, authorization);
                if (saved.hasError) { error = saved.error; return; }
                receipt = saved.value;
            }
        }
        catch (Exception)
        {
            error = "The document operation failed.";
        }
    }

    /// Shutdown cancelled this job before it ran.
    void cancelled() @safe nothrow { error = "The document operation was cancelled."; }
}

/// At most eight outstanding jobs. The caller owns this session through shutdown.
class DocumentIo
{
    private JobQueue!(FileResult, 8) queue;

    this() @safe nothrow { queue = new JobQueue!(FileResult, 8); }

    /// Queue a read; validation and persistent-text construction happen on the worker.
    Expected!FileTicket open(string path) @safe
    {
        auto job = new FileResult;
        job.operation = FileOperation.open;
        job.path = path;
        return submit(job);
    }

    /// Save the captured revision, even if the document continues changing after submission.
    Expected!FileTicket save(string path, in Text revision, bool bom, ulong document,
        SaveAuthorization authorization = SaveAuthorization.createOnly) @safe
    {
        auto job = new FileResult;
        job.operation = FileOperation.save;
        job.path = path;
        job.document = document;
        job.revision = Text(revision);
        job.bom = bom;
        job.authorization = authorization;
        return submit(job);
    }

    /// Inspect an existing destination before the UI asks for an informed replacement decision.
    Expected!FileTicket probe(string path, in Text revision, bool bom, ulong document,
        string baseline, bool baselineKnown) @safe
    {
        auto job = new FileResult;
        job.operation = FileOperation.probe;
        job.path = path;
        job.document = document;
        job.revision = Text(revision);
        job.bom = bom;
        job.baseline = baseline;
        job.baselineKnown = baselineKnown;
        return submit(job);
    }

    /// Drain and publish completed immutable results in submission order.
    const(FileResult)[] poll() @safe => queue.poll();

    bool busy() const scope @safe pure nothrow @nogc => !queue.stopped && queue.busy;

    /// Queued jobs cancel; running calls finish. Poll once afterwards to collect their receipts.
    void shutdown() @safe nothrow { queue.shutdown(Drain.cancel); }

    private Expected!FileTicket submit(FileResult job) @safe
    {
        // The ticket is the queue's next one; the worker never reads it.
        job.ticket = FileTicket(queue.nextTicket.value);
        const queued = queue.submit(job);
        if (queued.hasValue) return ok(job.ticket);
        final switch (queued.error)
        {
            case SubmitRefusal.stopped: return err!FileTicket("The document worker is stopped.");
            case SubmitRefusal.full:
                return err!FileTicket("The document queue is full; try again after pending work completes.");
            case SubmitRefusal.exhausted: return err!FileTicket("Document request identities are exhausted.");
            case SubmitRefusal.startFailed: return err!FileTicket("The document worker could not start.");
            case SubmitRefusal.rejected: return err!FileTicket("The document request could not be queued.");
        }
    }
}

/// A save acknowledges its captured revision, and reads arrive validated and prepared for the UI.
@("editor.documentIo.capturedRevisionAndPreparedOpen")
@safe unittest
{
    version (Posix) {}
    else
    {
        import sparkles.test_runner.skip : skipTest;
        skipTest("The native POSIX file adapter is not available.");
    }
    import core.thread : Thread;
    import core.time : MonoTime, seconds;
    import sparkles.test_utils.tmpfs : TmpFS;
    import std.path : buildPath;
    import std.file : readText;
    auto fixture = TmpFS.create();
    const path = buildPath(fixture.dir, "saved.txt");
    auto io = new DocumentIo;
    scope (exit) io.shutdown();
    const revision = Text("old\r\n");
    const requested = io.save(path, revision, true, 42);
    assert(requested.hasValue);
    const(FileResult)[] saved;
    const until = MonoTime.currTime + 3.seconds;
    while (!saved.length && MonoTime.currTime < until)
    {
        saved = io.poll();
        (() @trusted => Thread.yield())();
    }
    assert(saved.length == 1 && !saved[0].error.length && saved[0].document == 42 && saved[0].revision == revision);
    assert((() @trusted => readText(path))() == "\xef\xbb\xbfold\r\n");
    assert(io.open(path).hasValue);
    const(FileResult)[] opened;
    const readUntil = MonoTime.currTime + 3.seconds;
    while (!opened.length && MonoTime.currTime < readUntil)
    {
        opened = io.poll();
        (() @trusted => Thread.yield())();
    }
    assert(opened.length == 1 && !opened[0].error.length && opened[0].decoded.bom);
    assert(opened[0].decoded.predominant == LineEnding.crlf && opened[0].revision == revision);
    assert(io.probe(path, revision, true, 42, "different baseline", true).hasValue);
    const(FileResult)[] inspected;
    const probeUntil = MonoTime.currTime + 3.seconds;
    while (!inspected.length && MonoTime.currTime < probeUntil)
    {
        inspected = io.poll();
        (() @trusted => Thread.yield())();
    }
    assert(inspected.length == 1 && !inspected[0].error.length);
    assert(inspected[0].destinationExists && inspected[0].externalChange);
}

/// Outstanding requests are bounded even when workers finish before the UI polls.
@("editor.documentIo.outstandingCapacityAndShutdown")
@safe unittest
{
    auto io = new DocumentIo;
    scope (exit) io.shutdown();
    foreach (i; 0 .. 8) assert(io.open("/path-that-does-not-exist/sparkles-editor").hasValue);
    assert(io.open("/one-too-many").hasError);
    assert(io.busy);
    io.shutdown();
    assert(!io.busy && io.open("/after-shutdown").hasError);
    const stoppedResults = io.poll();
    assert(stoppedResults.length == 8);
    foreach (result; stoppedResults) assert(result.error.length);
    assert(io.poll().length == 0);
}
