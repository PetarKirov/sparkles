/** Bounded native clipboard transfers, retaining request identities until delivery. */
module sparkles.ui_app.clipboard_reads;

version (UiAppGuiVulkan):

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.input : Event, pasteChunks;
import sparkles.wsi.clipboard : TransferId, TransferStatus;
import sparkles.wsi.events : DataOfferAction;
import sparkles.wsi.types : OfferId;

private struct ReadSink
{
    UniqueBuffer!ubyte bytes;
    size_t maximum;
    TransferStatus status;
    bool oversized;
    private shared bool finished;

    bool done() const @safe nothrow @nogc => atomicLoad!(MemoryOrder.acq)(finished);

    void chunk(TransferId id, scope const(ubyte)[] data) @safe nothrow
    {
        if (done || oversized) return;
        if (data.length > maximum - bytes.length) oversized = true;
        else bytes ~= data;
    }

    void finish(TransferId id, TransferStatus status) @safe nothrow @nogc
    {
        if (done) return;
        this.status = status;
        atomicStore!(MemoryOrder.rel)(finished, true);
    }
}

private final class ReadJob
{
    uint request;
    TransferId transfer;
    ReadSink sink;
}

/**
Eight independently rooted native reads, each bounded to 16 MiB by default.
Only complete valid UTF-8 becomes paste chunks; failed/oversized transfers
produce an empty tagged completion and a consumable error. Poll after native
dispatch, and close against the same window system before it is destroyed.
WSI cancellation synchronously finishes a live sink or reports a stale id.
*/
final class ClipboardReads
{
    private ReadJob[8] jobs;
    private OfferId offer;
    private string mime, error_;
    private size_t maximum;
    private uint nextRequest, lastRequest;
    private bool closed;

    /// Maximum bytes retained by one transfer; rejection never publishes its prefix.
    this(size_t maximum = 16 * 1024 * 1024) @safe nothrow @nogc
    in (maximum != 0)
    { this.maximum = maximum; }

    /// Allocate from the native host's shared request namespace; zero reports exhaustion.
    uint allocate() @safe nothrow @nogc
    {
        if (closed || nextRequest == uint.max)
        {
            error_ = "Clipboard request identities are unavailable.";
            return 0;
        }
        return ++nextRequest;
    }

    /// Retain only offer identities and canonical MIME names, never borrowed event text.
    void note(OfferId source, DataOfferAction action, scope const(char)[] type)
        @safe pure nothrow @nogc
    {
        if (action == DataOfferAction.withdrawn && source == offer)
        { offer = OfferId.init; mime = null; return; }
        if (action != DataOfferAction.offered) return;
        if (source != offer) { offer = source; mime = null; }
        if (type == "text/plain;charset=utf-8") mime = "text/plain;charset=utf-8";
        else if (type == "text/plain" && !mime.length) mime = "text/plain";
    }

    /// Start a fresh increasing request. A synchronous rejection retains no sink reference.
    bool read(Wsi)(ref Wsi wsi, uint request)
    {
        if (closed || !request || request <= lastRequest)
        { error_ = "The clipboard request identity is stale."; return false; }
        // An offer with no text type answers like an empty clipboard: one
        // empty tagged paste (`INP25`), with the reason kept as a diagnostic.
        const textless = offer.valid && !mime.length;
        foreach (ref slot; jobs)
        {
            if (slot !is null) continue;
            auto job = new ReadJob;
            job.request = request;
            job.sink.maximum = maximum;
            slot = job; // Root the sink's stable class field before WSI retains its reference.
            if (offer.valid && !textless)
            {
                auto begun = wsi.receive(offer, mime, job.sink);
                if (begun.hasError)
                {
                    job.sink.bytes.clear();
                    slot = null;
                    error_ = "The native clipboard transfer could not start.";
                    return false;
                }
                job.transfer = begun.value;
            }
            else job.sink.finish(TransferId.init, TransferStatus.completed);
            lastRequest = request;
            if (request > nextRequest) nextRequest = request;
            error_ = textless ? "The clipboard has no UTF-8 text offer." : null;
            return true;
        }
        error_ = "Too many native clipboard reads are pending.";
        return false;
    }

    /// Publish finished transfers with their original host request; failed bytes never become edits.
    void poll(Sink)(scope Sink emit)
    {
        foreach (index; 0 .. jobs.length)
        {
            auto job = jobs[index];
            if (job is null || !job.sink.done) continue;
            // Keep a post-emission reference: the callback may allocate or reenter,
            // while pasteChunks still borrows this job's malloc-backed bytes.
            scope (exit) { job.sink.bytes.clear(); jobs[index] = null; }
            const bytes = (() @trusted => cast(const(char)[]) job.sink.bytes[])();
            const failed = job.sink.status != TransferStatus.completed || job.sink.oversized
                || validateUtf8(bytes).hasError;
            if (failed)
            {
                error_ = job.sink.oversized ? "Clipboard text exceeds the native read limit."
                    : job.sink.status != TransferStatus.completed ? "The native clipboard transfer failed."
                    : "Clipboard text is not valid UTF-8.";
                pasteChunks("", emit, job.request);
            }
            else pasteChunks(bytes, emit, job.request);
        }
    }

    /// Consume the latest diagnostic without exposing clipboard contents.
    string takeError() @safe pure nothrow @nogc
    {
        const error = error_;
        error_ = null;
        return error;
    }

    /// Release all sink references through the WSI's cancellation contract before dropping roots.
    void close(Wsi)(ref Wsi wsi)
    {
        if (closed) return;
        closed = true;
        foreach (ref job; jobs)
        {
            if (job is null) continue;
            if (!job.sink.done && job.transfer.valid) cast(void) wsi.cancelTransfer(job.transfer);
            job.sink.bytes.clear();
            job = null;
        }
    }
}

/// Two pending native reads keep their identities when the second completes first.
@("ui_app.nativeClipboard.outOfOrder")
@system unittest
{
    import sparkles.input : Event, match, PasteEvent;
    import sparkles.wsi.clipboard : SinkRef, TransferId, TransferStatus;
    import sparkles.wsi.events : DataOfferAction;
    import sparkles.wsi.types : OfferId, WsiResult, wsiOk;
    static struct Wsi
    {
        SinkRef[8] sinks;
        uint count;
        WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mime, ref S sink)
        {
            auto id = TransferId(count++, 1);
            sinks[id.index] = SinkRef.to(sink);
            return wsiOk(id);
        }
        void complete(uint index, string text)
        {
            const id = TransferId(index, 1);
            sinks[index].chunk(id, cast(const(ubyte)[]) text);
            sinks[index].finish(id, TransferStatus.completed);
            sinks[index] = SinkRef.init;
        }
        WsiResult!void cancelTransfer(TransferId id)
        {
            sinks[id.index].finish(id, TransferStatus.cancelled);
            sinks[id.index] = SinkRef.init;
            return wsiOk();
        }
    }
    Wsi wsi;
    auto reads = new ClipboardReads;
    scope (exit) reads.close(wsi);
    reads.note(OfferId(0, 1), DataOfferAction.offered, "text/plain;charset=utf-8");
    assert(reads.read(wsi, 11) && reads.read(wsi, 22));
    uint[] requests;
    string[] texts;
    auto emit = (in Event event) {
        event.match!((in PasteEvent paste) {
            assert(paste.last);
            requests ~= paste.request;
            texts ~= paste.text[].idup;
        }, (in _) { assert(false); });
    };
    wsi.complete(1, "B");
    reads.poll(emit);
    wsi.complete(0, "A");
    reads.poll(emit);
    assert(requests == [22u, 11u] && texts == ["B", "A"]);
}

/// Invalid and oversized transfers produce no partial edit, then a valid read still succeeds.
@("ui_app.nativeClipboard.rejectsPartialPayloads")
@system unittest
{
    import sparkles.input : match, PasteEvent;
    import sparkles.wsi.clipboard : SinkRef;
    import sparkles.wsi.types : WsiResult, wsiOk;
    static struct Wsi
    {
        SinkRef sink;
        uint next;
        WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mime, ref S receiver)
        {
            sink = SinkRef.to(receiver);
            return wsiOk(TransferId(next++, 1));
        }
        void complete(string bytes)
        {
            const id = TransferId(next - 1, 1);
            sink.chunk(id, cast(const(ubyte)[]) bytes);
            sink.finish(id, TransferStatus.completed);
        }
        WsiResult!void cancelTransfer(TransferId id)
        { sink.finish(id, TransferStatus.cancelled); return wsiOk(); }
    }
    Wsi wsi;
    auto reads = new ClipboardReads(3);
    scope (exit) reads.close(wsi);
    reads.note(OfferId(0, 1), DataOfferAction.offered, "text/plain;charset=utf-8");
    string[] delivered;
    auto emit = (in Event event) {
        event.match!((in PasteEvent p) { assert(p.last); delivered ~= p.text[].idup; }, (in _) {});
    };
    assert(reads.read(wsi, 1));
    wsi.complete("four");
    reads.poll(emit);
    assert(delivered == [""] && reads.takeError().length);
    assert(reads.read(wsi, 2));
    wsi.complete("\xC0\xAF");
    reads.poll(emit);
    assert(delivered == ["", ""] && reads.takeError().length);
    assert(reads.read(wsi, 3));
    wsi.complete("OK");
    reads.poll(emit);
    assert(delivered == ["", "", "OK"] && !reads.takeError().length);
}

/// Capacity rejection retains no extra sink, and shutdown cancels all live references once.
@("ui_app.nativeClipboard.capacityAndClose")
@system unittest
{
    import sparkles.wsi.clipboard : SinkRef;
    import sparkles.wsi.types : WsiResult, wsiOk;
    static struct Wsi
    {
        SinkRef[8] sinks;
        uint count, cancelled;
        WsiResult!TransferId receive(S)(OfferId offer, scope const(char)[] mime, ref S sink)
        {
            auto id = TransferId(count++, 1);
            sinks[id.index] = SinkRef.to(sink);
            return wsiOk(id);
        }
        WsiResult!void cancelTransfer(TransferId id)
        {
            ++cancelled;
            sinks[id.index].finish(id, TransferStatus.cancelled);
            sinks[id.index] = SinkRef.init;
            return wsiOk();
        }
    }
    Wsi wsi;
    auto reads = new ClipboardReads;
    scope (exit) reads.close(wsi);
    reads.note(OfferId(0, 1), DataOfferAction.offered, "text/plain;charset=utf-8");
    foreach (_; 0 .. 8) assert(reads.read(wsi, reads.allocate()));
    assert(!reads.read(wsi, reads.allocate()) && reads.takeError().length);
    assert(wsi.count == 8);
    reads.close(wsi);
    reads.close(wsi);
    assert(wsi.cancelled == 8 && reads.allocate() == 0);
    reads.poll((in Event event) @safe { assert(false, "Closed reads cannot deliver a stale answer."); });
}
