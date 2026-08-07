/**
The bounded intra-worker fiber channel (SPEC §14) — the producer/consumer
handoff the UI loop's fibers ride (input fiber → UI fiber, PTY reader →
render fiber; SPEC §15.3, open-issues O20).

Effects-side: parking goes through the `isFiberExecutor` seam, never the
ring, so a channel works identically on the live `Sched` and on the
deterministic `TestSched`. All users belong to ONE executor — cross-worker
channels are the M9 `MSG_RING` work.

`put`/`take` are cancellation checkpoints: a parked fiber's one-shot cancel
function (SPEC §8.4) wakes it, and the verb returns `ECANCELED` without
touching the buffer. `close` is idempotent and wakes everyone: putters fail
`EPIPE` immediately; takers drain the buffered items first, then observe
`EPIPE` — no data loss on graceful shutdown.

The channel is address-pinned like every intrusive structure (SPEC §8.1):
create it in a frame that outlives all users — scope join order makes that
natural.
*/
module sparkles.event_horizon.channel;

import core.lifetime : move;
import core.stdc.errno : ECANCELED, EPIPE;

import sparkles.event_horizon.capability : SpawnOptions, isFiberExecutor;
import sparkles.event_horizon.cause : FiberContext, Interrupt, interruptRequested;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/**
A bounded FIFO channel of `T` (moved in and out — `T` need not be
copyable), capacity `N`, for fibers of one executor.
*/
struct Channel(T, uint N = 16)
if (N > 0)
{
    @disable this(this); // waiters hold the channel's address while parked

    /// Delivers `item`, parking while the buffer is full. `EPIPE` when
    /// closed; `ECANCELED` when the fiber is interrupted (the item is
    /// returned to the caller's ownership only conceptually — on error it
    /// was never stored and has been destroyed with the parameter).
    IoResult!void put(X)(ref X exec, T item)
    if (isFiberExecutor!X)
    {
        for (;;)
        {
            if (interruptRequested(*exec.currentContext()))
                return ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit,
                    "channel put interrupted");
            if (_closed)
                return ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit,
                    "channel closed");
            if (_count < N)
            {
                _items[(_head + _count) % N] = move(item);
                ++_count;
                wakeOne(_takers);
                return ioOk();
            }
            parkOn(exec, _putters);
        }
    }

    /// Takes the oldest item, parking while the buffer is empty. Buffered
    /// items outlive `close`: `EPIPE` arrives only once drained.
    IoResult!T take(X)(ref X exec)
    if (isFiberExecutor!X)
    {
        for (;;)
        {
            if (interruptRequested(*exec.currentContext()))
                return ioErr!T(ECANCELED, OpKind.none, IoErrorStage.submit,
                    "channel take interrupted");
            if (_count > 0)
            {
                auto item = move(_items[_head]);
                _head = (_head + 1) % N;
                --_count;
                wakeOne(_putters);
                return ioOk(move(item));
            }
            if (_closed)
                return ioErr!T(EPIPE, OpKind.none, IoErrorStage.submit,
                    "channel closed");
            parkOn(exec, _takers);
        }
    }

    /// Non-parking put; `false` when full or closed.
    bool tryPut(T item)
    {
        if (_closed || _count >= N)
            return false;
        _items[(_head + _count) % N] = move(item);
        ++_count;
        wakeOne(_takers);
        return true;
    }

    /// Non-parking take; `false` when empty.
    bool tryTake(out T item)
    {
        if (_count == 0)
            return false;
        item = move(_items[_head]);
        _head = (_head + 1) % N;
        --_count;
        wakeOne(_putters);
        return true;
    }

    /// Closes the channel (idempotent) and wakes every parked fiber.
    void close() @safe nothrow @nogc
    {
        if (_closed)
            return;
        _closed = true;
        wakeAll(_putters);
        wakeAll(_takers);
    }

    /// `true` once `close` ran (buffered items may still be takeable).
    bool closed() const @safe pure nothrow @nogc => _closed;

    /// Buffered items.
    uint length() const @safe pure nothrow @nogc => _count;

    /// The fixed capacity.
    enum uint capacity = N;

private:
    /// One parked fiber; lives on the parked verb's stack frame (address-
    /// stable until the wake — the SPEC §6.5 argument, non-I/O edition).
    static struct Waiter
    {
        FiberContext* fiber;
        void function(void* execPtr, FiberContext* f) nothrow @nogc wakeFn;
        void* execPtr;
        Waiter* next;
        Waiter** owner; /// the list this waiter is queued on (for unlink)
    }

    void parkOn(X)(ref X exec, ref Waiter* list)
    {
        Waiter w;
        w.fiber = exec.currentContext();
        w.wakeFn = function(void* p, FiberContext* f) nothrow @nogc {
            (() @trusted => (cast(X*) p).wake(f))();
        };
        w.execPtr = (() @trusted => cast(void*) &exec)();
        w.owner = (() @trusted => &list)();

        // FIFO append.
        auto tail = (() @trusted => &list)();
        while (*tail !is null)
            tail = (() @trusted => &(*tail).next)();
        *tail = (() @trusted => &w)();

        // The one-shot cancel hook (SPEC §8.4, non-I/O park): latching has
        // already happened in interruptFiber; we only need the wake.
        auto ctx = w.fiber;
        ctx.cancelFn = function(void* p, Interrupt) nothrow @nogc {
            auto self = (() @trusted => cast(Waiter*) p)();
            self.wakeFn(self.execPtr, self.fiber);
        };
        ctx.cancelCtx = (() @trusted => cast(void*) &w)();

        exec.park();

        ctx.cancelFn = null;
        ctx.cancelCtx = null;
        unlink(w);
    }

    /// Removes a waiter from its list if still queued (a woken waiter was
    /// already popped; a cancel-woken one was not).
    void unlink(ref Waiter w) @trusted nothrow @nogc
    {
        if (w.owner is null)
            return;
        for (auto p = w.owner; *p !is null; p = &(*p).next)
            if (*p is &w)
            {
                *p = w.next;
                break;
            }
        w.owner = null;
    }

    void wakeOne(ref Waiter* list) @trusted nothrow @nogc
    {
        auto w = list;
        if (w is null)
            return;
        list = w.next;
        w.owner = null;
        w.wakeFn(w.execPtr, w.fiber);
    }

    void wakeAll(ref Waiter* list) @trusted nothrow @nogc
    {
        while (list !is null)
            wakeOne(list);
    }

    T[N] _items;
    uint _head;
    uint _count;
    bool _closed;
    Waiter* _putters;
    Waiter* _takers;
}

// ── tests (deterministic, ring-free, via TestSched) ─────────────────────────

version (unittest)
{
    import sparkles.event_horizon.testing : TestSched;
}

@("channel.putTake.fifoThroughBackpressure")
@safe
unittest
{
    TestSched sched;
    Channel!(int, 4) ch;

    int[] got;
    bool producerDone, consumerDone;
    sched.run(() {
        // Producer: 16 items through a 4-slot buffer — must park on the
        // full buffer and resume as the consumer drains.
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            foreach (i; 0 .. 16)
                assert(!ch.put(sched, i).hasError);
            producerDone = true;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            foreach (_; 0 .. 16)
            {
                auto r = ch.take(sched);
                assert(r.hasValue);
                got ~= r.value;
            }
            consumerDone = true;
        });
    });
    assert(producerDone && consumerDone);
    assert(got.length == 16);
    foreach (i, v; got)
        assert(v == i, "FIFO order survives backpressure parking");
}

@("channel.close.drainsThenEpipe")
@safe
unittest
{
    import core.stdc.errno : EPIPE;

    TestSched sched;
    Channel!(int, 8) ch;

    bool sawDrainThenClose;
    sched.run(() {
        assert(ch.tryPut(1) && ch.tryPut(2));
        ch.close();
        assert(ch.closed);

        assert(!ch.tryPut(3), "put after close is refused");
        auto p = ch.put(sched, 3);
        assert(p.hasError && p.error.errnoValue == EPIPE);

        // Buffered items survive the close; only then EPIPE.
        auto a = ch.take(sched);
        auto b = ch.take(sched);
        assert(a.hasValue && a.value == 1);
        assert(b.hasValue && b.value == 2);
        auto end = ch.take(sched);
        sawDrainThenClose = end.hasError && end.error.errnoValue == EPIPE;
    });
    assert(sawDrainThenClose);
}

@("channel.close.wakesParkedTaker")
@safe
unittest
{
    import core.stdc.errno : EPIPE;

    TestSched sched;
    Channel!(int, 2) ch;

    bool takerEnded;
    sched.run(() {
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            auto r = ch.take(sched); // parks: nothing buffered
            takerEnded = r.hasError && r.error.errnoValue == EPIPE;
        });
        cast(void) sched.spawnFiber(null, SpawnOptions.init, () {
            ch.close(); // wakes the parked taker
        });
    });
    assert(takerEnded, "close wakes a parked taker into EPIPE");
}

@("channel.moveOnly.elementsTransfer")
@safe
unittest
{
    static struct Box
    {
        @disable this(this);
        int v;
    }

    TestSched sched;
    Channel!(Box, 2) ch;

    bool moved;
    sched.run(() {
        assert(!ch.put(sched, Box(41)).hasError);
        auto r = ch.take(sched);
        assert(r.hasValue);
        auto box = move(r.value);
        moved = box.v == 41;
    });
    assert(moved, "non-copyable elements move through the channel");
}
