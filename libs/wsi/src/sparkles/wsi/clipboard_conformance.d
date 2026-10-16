/**
Backend-agnostic clipboard checks (`DT1`–`DT5`).

Separate from `checkWsiConformance` so a backend gains these properties when it
gains a clipboard, without moving the property counts its existing lanes pin.
A driver passes a live window; the properties offer data from it, read it back
through the platform, and end the offers they made.

Hooks, all optional:
$(LIST
    * `void step(Duration timeout)` — advance the backend's Event Horizon wait
        once. Without it the backend must offer `pumpTransfers()`, the
        recording backend's synchronous transfer dispatch.
    * `hooks.transferBytes` (a runtime `ulong`) — the round trip's size;
        1 MiB when absent. The `DT5` lane sets 32 MiB.
    * `enum size_t maxChunkBytes` — the largest chunk a sink may receive
        (`DT4`); 1 MiB when absent.
    * `enum transferDeadline` — how long one transfer may take in total.
)
*/
module sparkles.wsi.clipboard_conformance;

import core.time : Duration, MonoTime, msecs, seconds;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.op : Completion;
import sparkles.wsi.clipboard;
import sparkles.wsi.conformance : ConformanceOutcome;
import sparkles.wsi.events;
import sparkles.wsi.types;

/// Serves `size` bytes of a position-derived pattern without storing them.
struct PatternProvider
{
    ulong size;

    // Printable ASCII: valid UTF-8, so a backend whose clips carry only text
    // (Android without a `ContentProvider`) passes the same check.
    static ubyte at(ulong offset) @safe pure nothrow @nogc
        => cast(ubyte)('!' + (offset * 31 + (offset >> 8)) % 94);

    size_t fill(scope const(char)[], ulong offset, scope ubyte[] buffer)
        @safe pure nothrow @nogc
    {
        if (offset >= size)
            return 0;
        const n = size - offset < buffer.length
            ? cast(size_t)(size - offset) : buffer.length;
        foreach (i; 0 .. n)
            buffer[i] = at(offset + i);
        return n;
    }
}

/// Checks each byte against `PatternProvider` as it arrives; keeps nothing.
struct PatternSink
{
    ulong received;
    size_t chunks;
    size_t largestChunk;
    bool mismatch;
    uint finishes;
    TransferStatus status;

    void chunk(TransferId, scope const(ubyte)[] bytes) @safe pure nothrow @nogc
    {
        foreach (i, b; bytes)
            mismatch |= b != PatternProvider.at(received + i);
        received += bytes.length;
        ++chunks;
        if (bytes.length > largestChunk)
            largestChunk = bytes.length;
    }

    void finish(TransferId, TransferStatus how) @safe pure nothrow @nogc
    {
        ++finishes;
        status = how;
    }
}

private void timerComplete(void* context, ref Completion completion)
    nothrow @nogc
{
    *cast(bool*) context = completion.res == 0;
}

/**
Drives `wsi`'s clipboard through the shared properties from `window`, which
must be live and focused where the platform requires focus to read.
*/
ConformanceOutcome checkClipboardConformance(Backend, Hooks)(ref Backend wsi,
    ref DefaultLoop loop, ref Hooks hooks, WindowId window)
{
    ConformanceOutcome outcome;
    enum hasStep = is(typeof(hooks.step(Duration.init)));
    static assert(hasStep || is(typeof(wsi.pumpTransfers())),
        "a clipboard lane needs a step hook or a synchronous pumpTransfers");

    static if (is(typeof(Hooks.maxChunkBytes)))
        enum size_t maxChunk = Hooks.maxChunkBytes;
    else
        enum size_t maxChunk = 1 << 20;
    static if (is(typeof(Hooks.transferDeadline)))
        const deadlineSpan = Hooks.transferDeadline;
    else
        const deadlineSpan = 60.seconds;

    ulong transferBytes = 1 << 20;
    static if (is(typeof(hooks.transferBytes)))
        if (hooks.transferBytes != 0)
            transferBytes = hooks.transferBytes;

    void advance()
    {
        static if (hasStep)
            hooks.step(50.msecs);
        else
            wsi.pumpTransfers();
    }

    // Collects the offer events a drain delivers, reading each MIME type
    // while its drain runs (`ED8`).
    struct Announced
    {
        OfferId offer;
        DataOfferAction action;
        char[64] mime;
        size_t mimeLength;
    }

    Announced[16] announced;
    size_t announcedCount;

    void drainOffers()
    {
        assert(!wsi.drain((WindowEvent event) {
            event.payload.match!(
                (in DataOfferEvent e) {
                    if (announcedCount == announced.length)
                        return;
                    ref a = announced[announcedCount++];
                    a.offer = e.offer;
                    a.action = e.action;
                    assert(!wsi.withText(e.mimeType, (scope const(char)[] mime) {
                        const n = mime.length < a.mime.length
                            ? mime.length : a.mime.length;
                        a.mime[0 .. n] = mime[0 .. n];
                        a.mimeLength = n;
                    }).hasError, "an offer's MIME type is readable in its drain");
                },
                (_) {});
        }).hasError, "draining the event queue failed");
    }

    bool sawOffer(OfferId offer, DataOfferAction action, string mime = null)
    {
        foreach (ref a; announced[0 .. announcedCount])
            if (a.offer == offer && a.action == action
                && (mime is null || a.mime[0 .. a.mimeLength] == mime))
                return true;
        return false;
    }

    void waitFor(scope bool delegate() satisfied, string what)
    {
        const deadline = MonoTime.currTime + 10.seconds;
        drainOffers();
        while (!satisfied())
        {
            static if (hasStep)
            {
                assert(MonoTime.currTime < deadline, what);
                hooks.step(100.msecs);
                drainOffers();
            }
            else
                assert(false, what);
        }
    }

    void runTransfer(ref PatternSink sink, string what)
    {
        const deadline = MonoTime.currTime + deadlineSpan;
        while (sink.finishes == 0)
        {
            assert(MonoTime.currTime < deadline, what);
            advance();
        }
    }

    static immutable string textType = "text/plain;charset=utf-8";
    static immutable string testType = "application/x-sparkles-conformance";

    // Property (`DT1`): an offer is announced once per MIME type, naming the
    // offer and carrying no content.
    auto provider = PatternProvider(transferBytes);
    const(char)[][2] types = [textType, testType];
    auto offered = wsi.offerClipboard(window, types[], provider);
    assert(!offered.hasError, "offerClipboard failed");
    const offer = offered.value;
    waitFor(() => sawOffer(offer, DataOfferAction.offered, textType)
            && sawOffer(offer, DataOfferAction.offered, testType),
        "the offer was not announced once per MIME type");
    ++outcome.checked;

    // Property (`DT2`, `DT4`): the content streams back through the platform
    // byte for byte, in chunks no larger than the bound, and the transfer
    // ends exactly once.
    {
        PatternSink sink;
        auto started = wsi.receive(offer, testType, sink);
        assert(!started.hasError, "receive failed");

        // `DT5`: the loop keeps serving timers while bytes move.
        static if (hasStep)
        {
            bool timerFired;
            assert(!loop.submitAfter(10.msecs, &timerComplete, &timerFired)
                .hasError, "arming the transfer timer failed");
        }
        runTransfer(sink, "the round trip did not finish");
        assert(sink.finishes == 1 && sink.status == TransferStatus.completed,
            "the round trip did not complete exactly once");
        assert(sink.received == transferBytes && !sink.mismatch,
            "the round trip did not return the offered bytes");
        assert(sink.largestChunk <= maxChunk,
            "a chunk exceeded the bound a sink may receive");
        static if (hasStep)
        {
            const timerDeadline = MonoTime.currTime + 5.seconds;
            while (!timerFired)
            {
                assert(MonoTime.currTime < timerDeadline,
                    "a timer did not fire during the transfer");
                hooks.step(50.msecs);
            }
        }
        ++outcome.checked;
    }

    // Property (`DT2`): cancelling ends a transfer with `cancelled`, once,
    // and its sink then hears nothing more.
    {
        PatternSink sink;
        auto started = wsi.receive(offer, testType, sink);
        assert(!started.hasError, "receive failed");
        assert(!wsi.cancelTransfer(started.value).hasError, "cancel failed");
        assert(sink.finishes == 1 && sink.status == TransferStatus.cancelled,
            "a cancelled transfer did not finish as cancelled");
        const received = sink.received;
        foreach (_; 0 .. 3)
            advance();
        assert(sink.received == received && sink.finishes == 1,
            "a cancelled transfer kept delivering");
        assert(wsi.cancelTransfer(started.value).error.kind
            == WsiErrorKind.staleId, "an ended transfer was not stale");
        ++outcome.checked;
    }

    // Property (`DT1`, `DT3`): a new offer replaces the old one, which is
    // reported `withdrawn` and can no longer be read.
    {
        static immutable ubyte[5] hello = cast(immutable(ubyte)[5]) "hello";
        auto replaced = wsi.offerClipboard(window, textType, hello[]);
        assert(!replaced.hasError, "the whole-value offer failed");
        waitFor(() => sawOffer(offer, DataOfferAction.withdrawn),
            "the replaced offer was not reported withdrawn");
        PatternSink late;
        assert(wsi.receive(offer, testType, late).error.kind
            == WsiErrorKind.staleId, "a withdrawn offer was still readable");

        // The whole value round-trips too.
        static struct Collect
        {
            ubyte[16] bytes;
            size_t length;
            uint finishes;
            TransferStatus status;

            void chunk(TransferId, scope const(ubyte)[] b) @safe pure nothrow @nogc
            {
                const n = b.length < bytes.length - length
                    ? b.length : bytes.length - length;
                bytes[length .. length + n] = b[0 .. n];
                length += n;
            }

            void finish(TransferId, TransferStatus how) @safe pure nothrow @nogc
            {
                ++finishes;
                status = how;
            }
        }

        Collect collect;
        assert(!wsi.receive(replaced.value, textType, collect).hasError,
            "receiving the whole value failed");
        const deadline = MonoTime.currTime + deadlineSpan;
        while (collect.finishes == 0)
        {
            assert(MonoTime.currTime < deadline, "the whole value never arrived");
            advance();
        }
        assert(collect.status == TransferStatus.completed
            && collect.bytes[0 .. collect.length] == hello[],
            "the whole value did not round-trip");
        assert(!wsi.withdrawClipboard(replaced.value).hasError,
            "withdrawing an own offer failed");
        ++outcome.checked;
    }

    return outcome;
}

@("wsi.clipboard_conformance.recordingBackendPasses")
@system
unittest
{
    import sparkles.wsi.loop : RecordingWsi;

    DefaultLoop loop;
    RecordingWsi!(1, 32) wsi;
    WindowConfig config;
    config.logicalSize = LogicalSize(10, 10);
    const window = wsi.createWindow(config).value;

    static struct NoHooks {}
    NoHooks hooks;
    const outcome = checkClipboardConformance(wsi, loop, hooks, window);
    assert(outcome.checked == 4 && outcome.skipped == 0);
}
