/**
Stream sources: the native host reads a descriptor's bytes as they arrive and
hands them to the application's sink, independent of frames
([output-latency.md](../../../../../docs/specs/ui-app/output-latency.md) §2,
`OPL1`–`OPL9`, `OPL11`).

Where the event loop offers multishot reads (`OPL10`, Linux 6.7), one read
stays armed per source over a provided buffer ring, and the kernel picks the
buffer each read fills. Elsewhere a multishot readiness poll is armed and the
host reads with `read(2)`, never more than the turn's remaining budget, so
the bytes it has not taken stay in the kernel.

A loop turn delivers at most `budget` bytes across all sources (`OPL5`):
bytes beyond it stay in their buffers, pending, and are delivered first in a
later turn. When every buffer of a source is pending, its read ends dry
(`-ENOBUFS`) and the kernel's own pipe or pty buffer throttles the producer
(`OPL6`).
*/
module sparkles.event_horizon.stream_ingest;

import core.lifetime : move;

import sparkles.event_horizon.loop : DefaultLoop;
import sparkles.event_horizon.backend.concept : canSubmitOp;
import sparkles.event_horizon.backend.select : DefaultBackend;
import sparkles.event_horizon.buffer : Buf, BufGroupId, BufRing;
import sparkles.event_horizon.op : Completion, OpHandle, OpPollAdd, OpReadMultishot, PollEvents;

/// What a stream source hands its bytes and its end to. Both callbacks run on
/// the loop's thread; `context` must stay valid until the source is closed.
struct StreamSink
{
    void* context; /// passed back to both callbacks
    /// The next bytes of the stream, in order. The slice is valid only
    /// during the call.
    void function(void* context, scope const(ubyte)[] bytes) nothrow @nogc onBytes;
    /// The stream ended: `0` for end of file, else the error number (`EIO`
    /// is a pty's child gone). Called once, after every byte.
    void function(void* context, int error) nothrow @nogc onEnd;
}

/// Names an open source; `StreamId.init` names none.
struct StreamId
{
    uint value; /// slot index + 1 in the low byte, generation above it

    /// Whether this names a source at all.
    bool opCast(T : bool)() const @safe pure nothrow @nogc => value != 0;
}

/// Whether the event loop can read stream sources at all: a POSIX descriptor
/// and a readiness poll are the floor every path needs.
version (Posix)
    enum bool canIngestStreams = canSubmitOp!(DefaultBackend, OpPollAdd);
else
    enum bool canIngestStreams = false;

/// Whether it can read them through multishot reads, where the kernel has
/// them.
enum bool canReadMultishot = canSubmitOp!(DefaultBackend, OpReadMultishot);

/**
The host's stream sources (`OPL1`–`OPL9`). Lives where the loop does, never
moves while a source is open, and is closed (`close`) before the loop is
destroyed.
*/
struct StreamIngest
{
    /// The most sources open at once.
    enum maxSources = 16;
    /// The most buffers a source's ring has.
    enum maxBuffers = 64;

    DefaultLoop* loop;              /// the loop reading for us
    size_t budget = 256 * 1024;     /// bytes delivered per loop turn (`OPL5`)
    uint buffers = 64;              /// buffers per source ring, a power of two ≤ `maxBuffers`
    uint bufferSize = 16 * 1024;    /// bytes per buffer
    bool hideMultishot;             /// read as if the kernel had no multishot reads (tests)
    ushort firstGroup = 0x5300;     /// buffer group ids are `firstGroup + slot`

    /// Bytes were delivered since this was last cleared: a frame pass is
    /// due (`OPL12`).
    bool delivered;

    /// Every byte delivered so far, across sources (`OPL25`).
    ulong position;

    @disable this(this);

    /**
    Opens a source on `fd`, which must be non-blocking (`OPL11`). Returns
    `StreamId.init` where it cannot: no loop, no free slot, a blocking
    descriptor, or no readiness poll on this loop.
    */
    StreamId open(int fd, StreamSink sink) @system nothrow @nogc
    {
        static if (!canIngestStreams)
            return StreamId.init;
        else
        {
            import core.sys.posix.fcntl : F_GETFL, fcntl, O_NONBLOCK;

            if (loop is null || fd < 0 || sink.onBytes is null)
                return StreamId.init;
            const flags = fcntl(fd, F_GETFL);
            if (flags < 0 || (flags & O_NONBLOCK) == 0)
                return StreamId.init;
            foreach (i, ref s; slots)
            {
                if (s.state != State.free)
                    continue;
                s = Source.init;
                s.owner = &this;
                s.index = cast(ubyte) i;
                s.generation = ++generation_;
                s.fd = fd;
                s.sink = sink;
                if (!s.start())
                {
                    s.releaseResources();
                    s.state = State.free;
                    return StreamId.init;
                }
                return s.id;
            }
            return StreamId.init;
        }
    }

    /**
    Closes source `id` (`OPL9`): no sink callback runs after it returns, and
    its pending bytes are dropped. Its kernel operation is cancelled; the
    buffers are released once the kernel reports it ended, or when the
    ingest closes.
    */
    void close(StreamId id) @system nothrow @nogc
    {
        if (auto s = find(id))
            s.close();
    }

    /// Delivers every pending byte of `id` now, ignoring the budget, without
    /// reading the descriptor (`OPL7`).
    void flush(StreamId id) @system nothrow @nogc
    {
        if (auto s = find(id))
        {
            // Only what is held: the fallback holds nothing, its bytes wait
            // in the kernel.
            if (s.multishot)
                s.deliverPending(size_t.max);
            s.deliverEnd();
            s.resume();
        }
    }

    /// Whether source `id` reads through a multishot read (`OPL2`), not the
    /// readiness fallback (`OPL3`).
    bool readsMultishot(StreamId id) @system nothrow @nogc
    {
        if (auto s = find(id))
            return s.multishot;
        return false;
    }

    /// The bytes source `id` has delivered so far.
    ulong positionOf(StreamId id) @system nothrow @nogc
    {
        if (auto s = find(id))
            return s.position;
        return 0;
    }

    /**
    Starts a loop turn: the turn's budget is refilled and spent on pending
    bytes first, round-robin from the source after the one that started the
    last turn, and dry or stopped reads are re-armed. Call it before each
    turn of the loop.
    */
    void beginTurn() @system nothrow @nogc
    {
        left_ = budget;
        rotate_ = (rotate_ + 1) % maxSources;
        foreach (k; 0 .. maxSources)
        {
            auto s = &slots[(rotate_ + k) % maxSources];
            if (s.state == State.free || s.state == State.closing)
                continue;
            s.deliver(left_);
            s.resume();
        }
    }

    /// Whether a source holds bytes, or has bytes left in the kernel, that
    /// the next turn delivers without waiting: its park must not wait.
    bool hasPending() const @safe pure nothrow @nogc
    {
        foreach (ref s; slots)
            if (s.state != State.free && s.state != State.closing
                && (s.count != 0 || s.moreToRead || s.endPending))
                return true;
        return false;
    }

    /// Closes every source and waits for the kernel to give back every
    /// buffer. The loop may run a few turns.
    void closeAll() @system nothrow
    {
        import core.time : Duration;

        foreach (ref s; slots)
            if (s.state != State.free && s.state != State.closing)
                s.close();
        foreach (_; 0 .. 256)
        {
            bool busy;
            foreach (ref s; slots)
                busy |= s.state != State.free;
            if (!busy || loop is null || loop.runOnce(Duration.zero).hasError)
                break;
        }
        // A completion that never came (a loop that failed): free what we
        // can; the kernel ring dies with the loop.
        foreach (ref s; slots)
            if (s.state != State.free)
            {
                s.releaseResources();
                s.state = State.free;
            }
    }

    /// The open sources, for tests and diagnostics.
    size_t openCount() const @safe pure nothrow @nogc
    {
        size_t n;
        foreach (ref s; slots)
            n += s.state != State.free && s.state != State.closing;
        return n;
    }

private:
    enum State : ubyte
    {
        free,      // unused
        reading,   // a multishot read is armed
        dry,       // the read ended for want of buffers; re-armed on delivery
        polling,   // fallback: a readiness poll is armed
        ended,     // the stream ended; the end is delivered after the bytes
        closing,   // closed by the application; the kernel op is ending
    }

    static struct Source
    {
        StreamIngest* owner;
        ubyte index;
        uint generation;
        int fd = -1;
        StreamSink sink;
        State state;
        bool multishot;      // reading through the buffer ring
        bool armed;          // a kernel op is in flight
        OpHandle op;
        bool sawBytes;       // the read delivered at least once
        bool moreToRead;     // fallback: the kernel may hold more
        bool endPending;     // the end is known, not yet delivered
        int endError;
        ulong position;

        // The ring and its pending leases, in stream order.
        BufRing!()* ring;
        Buf[maxBuffers] pending;
        uint head, count;    // FIFO over `pending`
        uint headOffset;     // bytes of the head already delivered

        StreamId id() const @safe pure nothrow @nogc
            => StreamId((generation << 8) | (index + 1));

        bool start() @system nothrow @nogc
        {
            static if (canReadMultishot)
                if (!owner.hideMultishot && owner.loop.caps().multishotRead
                    && startMultishot())
                    return true;
            return startPolling();
        }

        static if (canReadMultishot)
        bool startMultishot() @system nothrow @nogc
        {
            import core.memory : pureCalloc, pureFree;

            const n = owner.buffers;
            if (n == 0 || n > maxBuffers || (n & (n - 1)) != 0)
                return false;
            // Zeroed memory is an empty ring (its destructor checks for
            // one); it lives on the heap because every lease points at it.
            ring = cast(BufRing!()*) pureCalloc(1, BufRing!().sizeof);
            if (ring is null)
                return false;
            const group = BufGroupId(cast(ushort) (owner.firstGroup + index));
            if (BufRing!().create(*ring, group, n, owner.bufferSize).hasError)
            {
                pureFree(ring);
                ring = null;
                return false;
            }
            if (owner.loop.registerBufRing(group.value, ring.entries, ring.ringAddr).hasError)
            {
                ring.destroy();
                pureFree(ring);
                ring = null;
                return false;
            }
            multishot = true;
            state = State.reading;
            return armRead();
        }

        bool armRead() @system nothrow @nogc
        {
            static if (canReadMultishot)
            {
                auto h = owner.loop.submit(OpReadMultishot(fd, ring.group), &onRead, &this);
                if (h.hasError)
                    return false;
                op = h.value;
                armed = true;
                state = State.reading;
                return true;
            }
            else
                return false;
        }

        bool startPolling() @system nothrow @nogc
        {
            multishot = false;
            state = State.polling;
            moreToRead = true; // bytes may already wait: read before the first edge
            return armPoll();
        }

        bool armPoll() @system nothrow @nogc
        {
            static if (canIngestStreams)
            {
                auto h = owner.loop.submit(OpPollAdd(fd, PollEvents.readable, true), &onReady, &this);
                if (h.hasError)
                    return false;
                op = h.value;
                armed = true;
                return true;
            }
            else
                return false;
        }

        // A multishot read's completion.
        static void onRead(void* ctx, ref Completion done) nothrow @nogc
        {
            import core.stdc.errno : ECANCELED, EINVAL, ENOBUFS, EOPNOTSUPP;
            // Only Linux names it, and only io_uring reports it here.
            version (linux)
                import core.stdc.errno : EBADFD;
            else
                enum EBADFD = EINVAL;

            auto s = cast(Source*) ctx;
            if (done.isFinal)
                s.armed = false;
            if (s.state == State.closing)
            {
                // The leases of a closed source go straight back.
                if (done.res > 0)
                {
                    auto b = s.ring.lease(done.bufferId, cast(uint) done.res);
                    b.release();
                }
                if (done.isFinal)
                    s.finishClosing();
                return;
            }
            if (done.res > 0)
            {
                s.sawBytes = true;
                auto b = s.ring.lease(done.bufferId, cast(uint) done.res);
                // The ring has as many buffers as the queue has places: the
                // kernel cannot fill a buffer that is still queued.
                assert(s.count < maxBuffers);
                s.pending[(s.head + s.count) % maxBuffers] = move(b);
                ++s.count;
                if (done.isFinal)
                    s.state = State.dry; // re-armed once delivery frees a buffer
                s.deliver(s.owner.left_);
                return;
            }
            if (!done.isFinal)
                return;
            const err = -done.res;
            if (done.res == -ENOBUFS)
                s.state = State.dry;
            else if (done.res == 0)
                s.endWith(0);
            else if (err == ECANCELED)
                s.state = State.dry; // not ours: try again
            else if (!s.sawBytes && (err == EINVAL || err == EBADFD || err == EOPNOTSUPP))
            {
                // Refused for this descriptor (`OPL3`): read it the other way.
                s.dropRing();
                if (!s.startPolling())
                    s.endWith(err);
            }
            else
                s.endWith(err);
        }

        // A fallback readiness completion.
        static void onReady(void* ctx, ref Completion done) nothrow @nogc
        {
            auto s = cast(Source*) ctx;
            if (done.isFinal)
                s.armed = false;
            if (s.state == State.closing)
            {
                if (done.isFinal)
                    s.finishClosing();
                return;
            }
            if (done.res >= 0)
            {
                s.moreToRead = true;
                s.deliver(s.owner.left_);
            }
            // A poll the kernel ended is re-armed by the next turn.
        }

        void endWith(int error) nothrow @nogc
        {
            endPending = true;
            endError = error;
            state = State.ended;
            deliverEnd();
        }

        // Delivers up to `allowance` bytes (`size_t.max`: all), charging the
        // turn's budget, then the end once nothing precedes it.
        void deliver(size_t allowance) nothrow @nogc
        {
            if (multishot)
                deliverPending(allowance);
            else if (moreToRead)
                readSome(allowance);
            deliverEnd();
            resume();
        }

        void deliverPending(size_t allowance) nothrow @nogc
        {
            const gen = generation;
            while (count != 0 && allowance != 0 && state != State.closing && gen == generation)
            {
                ref b = pending[head];
                const all = b[][headOffset .. $];
                const n = all.length <= allowance ? all.length : allowance;
                hand(all[0 .. n]);
                if (state == State.closing || gen != generation)
                    return; // the sink closed us: pending is dropped
                if (allowance != size_t.max)
                    allowance -= n;
                headOffset += cast(uint) n;
                if (headOffset == b.length)
                {
                    b.release(); // the buffer goes back to the kernel
                    head = (head + 1) % maxBuffers;
                    --count;
                    headOffset = 0;
                }
            }
        }

        // Fallback: read at most `allowance` bytes, so what the budget
        // leaves stays in the kernel (`OPL5`).
        void readSome(size_t allowance) nothrow @nogc
        {
            static if (canIngestStreams)
                readSomePosix(allowance);
            else
                moreToRead = false;
        }

        static if (canIngestStreams)
        void readSomePosix(size_t allowance) nothrow @nogc
        {
            import core.stdc.errno : EAGAIN, EINTR, errno, EWOULDBLOCK;
            import core.sys.posix.unistd : read;

            ubyte[16 * 1024] chunk = void;
            const gen = generation;
            while (moreToRead && allowance != 0 && state == State.polling && gen == generation)
            {
                const want = allowance < chunk.length ? allowance : chunk.length;
                const n = (() @trusted => read(fd, chunk.ptr, want))();
                if (n > 0)
                {
                    hand(chunk[0 .. n]);
                    if (allowance != size_t.max)
                        allowance -= n;
                    continue;
                }
                if (n < 0 && errno == EINTR)
                    continue;
                if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
                {
                    moreToRead = false;
                    break;
                }
                moreToRead = false;
                if (armed)
                    cast(void) owner.loop.cancel(op);
                endWith(n == 0 ? 0 : errno);
                break;
            }
        }

        void hand(scope const(ubyte)[] bytes) nothrow @nogc
        {
            if (bytes.length == 0)
                return;
            owner.left_ = owner.left_ > bytes.length ? owner.left_ - bytes.length : 0;
            position += bytes.length;
            owner.position += bytes.length;
            owner.delivered = true;
            sink.onBytes(sink.context, bytes);
        }

        void deliverEnd() nothrow @nogc
        {
            if (!endPending || count != 0 || state == State.closing)
                return;
            endPending = false;
            auto sinkEnd = sink.onEnd;
            auto ctx = sink.context;
            owner.delivered = true;
            if (sinkEnd !is null)
                sinkEnd(ctx, endError);
        }

        // Re-arms a read that ended dry, or a poll the kernel ended.
        void resume() nothrow @nogc
        {
            if (armed)
                return;
            if (state == State.dry && count < owner.buffers)
                cast(void) (() @trusted => armRead())();
            else if (state == State.polling && !moreToRead)
                cast(void) (() @trusted => armPoll())();
        }

        void close() nothrow @nogc
        {
            sink = StreamSink.init;
            // Pending leases go back now; the generation bump stops any
            // delivery loop the sink closed us from.
            foreach (k; 0 .. count)
                pending[(head + k) % maxBuffers].release();
            head = count = headOffset = 0;
            ++generation;
            state = State.closing;
            if (armed)
                cast(void) owner.loop.cancel(op);
            else
                finishClosing();
        }

        void finishClosing() nothrow @nogc
        {
            if (armed)
                return;
            releaseResources();
            state = State.free;
        }

        void dropRing() nothrow @nogc
        {
            static if (canReadMultishot)
                if (ring !is null)
                {
                    import core.memory : pureFree;

                    foreach (k; 0 .. count)
                        pending[(head + k) % maxBuffers].release();
                    head = count = headOffset = 0;
                    cast(void) owner.loop.unregisterBufRing(ring.group.value);
                    ring.destroy();
                    pureFree(ring);
                    ring = null;
                }
            multishot = false;
        }

        void releaseResources() nothrow @nogc => dropRing();
    }

    Source* find(StreamId id) @safe pure nothrow @nogc return
    {
        const index = (id.value & 0xff);
        if (index == 0 || index > maxSources)
            return null;
        auto s = &slots[index - 1];
        if (s.state == State.free || s.state == State.closing || s.id != id)
            return null;
        return s;
    }

    Source[maxSources] slots;
    uint generation_;
    size_t left_;
    uint rotate_;
}

// The tests use pipes and `fcntl`.
version (Posix):

version (unittest)
{
    import core.time : Duration, msecs;

    import sparkles.event_horizon.loop : LoopConfig;
    import sparkles.test_runner.skip : skipTest;

    // A sink that keeps what it is given, and can close its own source.
    private struct Kept
    {
        ubyte[4096] bytes;
        size_t length;
        uint calls;
        uint ends;
        int endError = int.min;
        size_t lengthAtEnd;
        StreamIngest* closeFrom;
        StreamId self;

        StreamSink sink() @system nothrow @nogc return
            => StreamSink(&this, &onBytes, &onEnd);

        static void onBytes(void* ctx, scope const(ubyte)[] got) nothrow @nogc
        {
            auto k = cast(Kept*) ctx;
            k.bytes[k.length .. k.length + got.length] = got[];
            k.length += got.length;
            ++k.calls;
            if (k.closeFrom !is null)
                k.closeFrom.close(k.self);
        }

        static void onEnd(void* ctx, int error) nothrow @nogc
        {
            auto k = cast(Kept*) ctx;
            ++k.ends;
            k.endError = error;
            k.lengthAtEnd = k.length;
        }
    }

    // A non-blocking pipe's read end and its write end.
    private struct Pipe
    {
        int[2] fds = [-1, -1];

        static Pipe open(bool nonBlocking = true) @system nothrow @nogc
        {
            import core.sys.posix.fcntl : F_GETFL, F_SETFL, fcntl, O_NONBLOCK;
            import core.sys.posix.unistd : pipe;

            Pipe p;
            if (pipe(p.fds) != 0)
                skipTest("pipe failed (descriptor limit)");
            if (nonBlocking)
                fcntl(p.fds[0], F_SETFL, fcntl(p.fds[0], F_GETFL) | O_NONBLOCK);
            return p;
        }

        // Writes `n` bytes counting up from `from`.
        void write(size_t n, ubyte from = 0) @system nothrow @nogc
        {
            import core.sys.posix.unistd : write;

            ubyte[4096] b;
            foreach (i; 0 .. n)
                b[i] = cast(ubyte) (from + i);
            assert(write(fds[1], b.ptr, n) == n);
        }

        // The bytes still in the pipe.
        int unread() @system nothrow @nogc
        {
            import core.sys.posix.sys.ioctl : FIONREAD, ioctl;

            int n;
            assert(ioctl(fds[0], FIONREAD, &n) == 0);
            return n;
        }

        void closeWriter() @system nothrow @nogc
        {
            import core.sys.posix.unistd : close;

            if (fds[1] >= 0)
                close(fds[1]);
            fds[1] = -1;
        }

        ~this() @system nothrow @nogc
        {
            import core.sys.posix.unistd : close;

            closeWriter();
            if (fds[0] >= 0)
                close(fds[0]);
        }
    }

    // One loop turn as the native loop runs it.
    private void turn(ref StreamIngest ingest, ref DefaultLoop loop) @system nothrow @nogc
    {
        ingest.beginTurn();
        cast(void) loop.runOnce(ingest.hasPending ? Duration.zero : 5.msecs);
    }

    private bool turnsUntil(ref StreamIngest ingest, ref DefaultLoop loop,
        scope bool delegate() nothrow @nogc done) @system nothrow @nogc
    {
        foreach (_; 0 .. 200)
        {
            if (done())
                return true;
            turn(ingest, loop);
        }
        return done();
    }

    // Runs `check` once reading through multishot reads (where the kernel
    // has them) and once through the readiness fallback.
    private void bothPaths(scope void delegate(ref StreamIngest, ref DefaultLoop) @system check)
        @system
    {
        static if (!canIngestStreams)
            skipTest("this event loop cannot read stream sources");
        foreach (hide; [false, true])
        {
            DefaultLoop loop;
            if (DefaultLoop.create(loop, LoopConfig()).hasError)
                skipTest("no event loop here (a sandbox without io_uring)");
            scope (exit) loop.destroy();
            StreamIngest ingest;
            ingest.loop = &loop;
            ingest.hideMultishot = hide;
            scope (exit) ingest.closeAll();
            check(ingest, loop);
        }
    }

    private bool inOrder(ref const Kept k, size_t n, ubyte from = 0) @safe pure nothrow @nogc
    {
        if (k.length != n)
            return false;
        foreach (i; 0 .. n)
            if (k.bytes[i] != cast(ubyte) (from + i))
                return false;
        return true;
    }
}

@("stream_ingest.bytesArriveWithoutAFrame")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        const id = ingest.open(p.fds[0], k.sink);
        assert(id, "a non-blocking pipe opens");
        assert(ingest.readsMultishot(id) == (!ingest.hideMultishot && loop.caps().multishotRead),
            "OPL2/OPL3: the path follows the kernel");
        p.write(5);
        assert(turnsUntil(ingest, loop, () => k.length == 5), "OPL1: delivered by loop turns alone");
        assert(inOrder(k, 5));
        assert(ingest.delivered, "OPL12: a delivery asks for a frame");
        assert(ingest.positionOf(id) == 5 && ingest.position == 5, "OPL25: positions count");
    });
}

@("stream_ingest.aTurnDeliversAtMostTheBudget")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        ingest.budget = 100;
        assert(ingest.open(p.fds[0], k.sink));
        p.write(1000);
        size_t last;
        uint turns;
        foreach (_; 0 .. 400)
        {
            turn(ingest, loop);
            assert(k.length - last <= 100, "OPL5: no turn delivers past its budget");
            last = k.length;
            ++turns;
            if (k.length == 1000)
                break;
        }
        assert(inOrder(k, 1000), "OPL4: in order, each byte once");
        assert(turns >= 10, "the budget spread the burst over turns");
        turn(ingest, loop); // the fallback learns the pipe is empty by reading it
        assert(!ingest.hasPending);
    });
}

@("stream_ingest.aFullSourceLeavesTheRestToTheKernel")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        ingest.buffers = 4;
        ingest.bufferSize = 16;
        ingest.budget = 0; // deliver nothing: every read stays pending
        assert(ingest.open(p.fds[0], k.sink));
        p.write(200);
        foreach (_; 0 .. 20)
            turn(ingest, loop);
        assert(k.length == 0);
        assert(p.unread >= 200 - 4 * 16, "OPL6: at most the ring's bytes leave the kernel");
        ingest.budget = 256 * 1024;
        assert(turnsUntil(ingest, loop, () => k.length == 200));
        assert(inOrder(k, 200), "OPL4: re-armed reads resume in order");
    });
}

@("stream_ingest.flushDeliversWhatIsHeldAndReadsNothing")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        ingest.budget = 0;
        const id = ingest.open(p.fds[0], k.sink);
        p.write(30);
        foreach (_; 0 .. 10)
            turn(ingest, loop);
        const inKernel = p.unread;
        ingest.flush(id);
        assert(k.length + inKernel == 30, "OPL7: everything held, and only that, is delivered");
        assert(p.unread == inKernel, "OPL7: a flush does not read");
        assert(inOrder(k, k.length));
    });
}

@("stream_ingest.theEndFollowsTheLastByteOnce")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        ingest.budget = 64;
        assert(ingest.open(p.fds[0], k.sink));
        p.write(300);
        p.closeWriter();
        assert(turnsUntil(ingest, loop, () => k.ends != 0));
        foreach (_; 0 .. 5)
            turn(ingest, loop);
        assert(k.ends == 1, "OPL8: the end is delivered once");
        assert(k.endError == 0, "end of file");
        assert(k.lengthAtEnd == 300 && inOrder(k, 300), "OPL8: after every byte");
    });
}

@("stream_ingest.aClosedSourceIsSilentAndGivesEverythingBack")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        ingest.budget = 0;
        const id = ingest.open(p.fds[0], k.sink);
        p.write(50);
        foreach (_; 0 .. 5)
            turn(ingest, loop);
        ingest.close(id);
        ingest.budget = 256 * 1024;
        p.write(50);
        foreach (_; 0 .. 10)
            turn(ingest, loop);
        assert(k.calls == 0 && k.ends == 0, "OPL9: no callback after close");
        assert(ingest.openCount == 0);
        ingest.flush(id); // a stale id names nothing
        ingest.closeAll();
        assert(loop.inFlight == 0, "OPL9: no kernel operation outlives the source");
    });
}

@("stream_ingest.aSinkMayCloseItsSource")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open();
        Kept k;
        k.closeFrom = &ingest;
        k.self = ingest.open(p.fds[0], k.sink);
        p.write(40);
        assert(turnsUntil(ingest, loop, () => k.calls != 0));
        foreach (_; 0 .. 5)
            turn(ingest, loop);
        assert(k.calls == 1, "nothing is delivered after the sink closed its source");
        assert(ingest.openCount == 0);
    });
}

@("stream_ingest.aBlockingDescriptorIsRefused")
@system unittest
{
    bothPaths((ref StreamIngest ingest, ref DefaultLoop loop) {
        auto p = Pipe.open(nonBlocking: false);
        Kept k;
        assert(!ingest.open(p.fds[0], k.sink), "OPL11: a blocking descriptor is refused");
        StreamIngest none;
        assert(!none.open(p.fds[0], k.sink), "no loop, no source");
    });
}
