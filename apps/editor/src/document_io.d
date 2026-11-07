/** Bounded asynchronous native document reads and saves. */
module document_io;

import sparkles.base.expected : Expected, err, ok;
import sparkles.event_horizon.raw_pool : CpuJob, RawCompletion, RawCpuPool, RawPoolResult;
import sparkles.text_buffer.text : Text;
import document_files : readRegularBytes, saveAtomic, SaveAuthorization, SaveReceipt;
import document_text : decodeDocument, DocumentBytes, encodeDocument;

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
    DocumentBytes decoded;
    string bytes;
    SaveReceipt receipt;
    string error;
    bool destinationExists, externalChange;
    private bool bom, done;
    private SaveAuthorization authorization;
    private string baseline;
    private bool baselineKnown;
}

/// At most eight outstanding jobs. The caller owns this session through shutdown.
class DocumentIo
{
    private alias Pool = RawCpuPool!(8, 8, CpuJob);
    private Pool pool;
    private FileResult[] jobs;
    private bool started, stopped;
    private ulong nextTicket;

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
    const(FileResult)[] poll() @safe
    {
        RawCompletion completion;
        while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        const(FileResult)[] results;
        foreach (job; jobs) if (job.done) results ~= job;
        if (results.length)
        {
            size_t kept;
            foreach (job; jobs) if (!job.done) jobs[kept++] = job;
            jobs[kept .. $] = null;
            jobs.length = kept;
        }
        return results;
    }

    bool busy() const scope @safe pure nothrow @nogc => !stopped && jobs.length != 0;

    /// Queued jobs cancel; running calls finish. Poll once afterwards to collect their receipts.
    void shutdown() @safe nothrow
    {
        if (stopped) return;
        stopped = true;
        if (started)
        {
            pool.shutdown(false);
            RawCompletion completion;
            while (pool.pollCompletion(completion) == RawPoolResult.accepted) completion.dispatch();
        }
    }

    private Expected!FileTicket submit(FileResult job) @safe
    {
        if (stopped) return err!FileTicket("The document worker is stopped.");
        if (jobs.length == 8) return err!FileTicket("The document queue is full; try again after pending work completes.");
        if (nextTicket == ulong.max) return err!FileTicket("Document request identities are exhausted.");
        if (!started)
        {
            if (Pool.start(pool, 1) != RawPoolResult.accepted)
                return err!FileTicket("The document worker could not start.");
            started = true;
        }
        job.ticket = FileTicket(++nextTicket);
        const queued = pool.submit(CpuJob(&work, &completed,
            (() @trusted => cast(void*) job)(), job.ticket.value));
        if (queued != RawPoolResult.accepted)
            return err!FileTicket("The document request could not be queued.");
        jobs ~= job;
        return ok(job.ticket);
    }

    private static void work(void* raw) @safe nothrow
    {
        auto job = (() @trusted => cast(FileResult) raw)();
        try
        {
            if (job.operation == FileOperation.probe)
            {
                import std.file : exists;
                job.destinationExists = (() @trusted => exists(job.path))();
                if (!job.destinationExists) return;
                const read = readRegularBytes(job.path);
                if (read.hasError) { job.error = read.error; return; }
                job.bytes = read.value;
                job.externalChange = !job.baselineKnown || read.value != job.baseline;
            }
            else if (job.operation == FileOperation.open)
            {
                const read = readRegularBytes(job.path);
                if (read.hasError) { job.error = read.error; return; }
                const decoded = decodeDocument(read.value);
                if (decoded.hasError) { job.error = decoded.error; return; }
                job.decoded = decoded.value;
                job.bytes = read.value;
                job.revision = Text(decoded.value.content);
            }
            else
            {
                auto bytes = new char[job.revision.length];
                job.revision.copyTo(0, bytes.length, bytes);
                const content = (() @trusted => cast(string) bytes)();
                job.bytes = encodeDocument(DocumentBytes(content, job.bom));
                const saved = saveAtomic(job.path, job.bytes, job.authorization);
                if (saved.hasError) { job.error = saved.error; return; }
                job.receipt = saved.value;
            }
        }
        catch (Exception)
        {
            job.error = "The document operation failed.";
        }
    }

    private static void completed(void* raw, bool cancelled) @safe nothrow @nogc
    {
        auto job = (() @trusted => cast(FileResult) raw)();
        if (cancelled) job.error = "The document operation was cancelled.";
        job.done = true;
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
    assert(opened[0].decoded.predominant == "\r\n" && opened[0].revision == revision);
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
