/**
The bounded intra-worker fiber channel (SPEC §14) — the producer/consumer
handoff the UI loop's fibers ride (input fiber → UI fiber, PTY reader →
render fiber; SPEC §15.3, open-issues O20).

Effects-side: parking goes through the `isFiberExecutor` seam, never the
ring, so a channel works identically on the live `Sched` and on the
deterministic `TestSched`. All users belong to ONE executor; across workers
and threads, use `CrossChannel` (`sparkles.event_horizon.cross_channel`,
SPEC §14.1).

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

import sparkles.event_horizon.admission : Admission;
import sparkles.event_horizon.capability : SpawnOptions, isFiberExecutor;
import sparkles.event_horizon.cause : interruptRequested;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/**
A bounded FIFO channel of `T` (moved in and out — `T` need not be
copyable), capacity `N`, for fibers of one executor.

Its bound is two admission budgets (SPEC §14.2): free slots, which a put
acquires and a take releases, and buffered items, which start all in use and
which a put releases and a take acquires. Each side parks on its own budget.
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
        if (interruptRequested(*exec.currentContext()))
            return ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit,
                "channel put interrupted");
        if (_closed)
            return ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit, "channel closed");
        auto slot = _space.acquire(exec);
        if (slot.hasError)
            return slot.error.code == ECANCELED
                ? ioErr!void(ECANCELED, OpKind.none, IoErrorStage.submit,
                    "channel put interrupted")
                : ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit, "channel closed");
        if (_closed)
        {
            // A take freed a slot after the close woke this putter.
            _space.release();
            return ioErr!void(EPIPE, OpKind.none, IoErrorStage.submit, "channel closed");
        }
        store(move(item));
        return ioOk();
    }

    /// Takes the oldest item, parking while the buffer is empty. Buffered
    /// items outlive `close`: `EPIPE` arrives only once drained.
    IoResult!T take(X)(ref X exec)
    if (isFiberExecutor!X)
    {
        auto got = _items.acquire(exec);
        if (got.hasError)
            return got.error.code == ECANCELED
                ? ioErr!T(ECANCELED, OpKind.none, IoErrorStage.submit,
                    "channel take interrupted")
                : ioErr!T(EPIPE, OpKind.none, IoErrorStage.submit, "channel closed");
        return ioOk(load());
    }

    /// Non-parking put; `false` when full or closed.
    bool tryPut(T item)
    {
        if (_closed || !_space.tryAcquire())
            return false;
        store(move(item));
        return true;
    }

    /// Non-parking take; `false` when empty.
    bool tryTake(out T item)
    {
        if (!_items.tryAcquire())
            return false;
        item = load();
        return true;
    }

    /// Closes the channel (idempotent) and wakes every parked fiber.
    void close() @safe nothrow @nogc
    {
        if (_closed)
            return;
        _closed = true;
        _space.close();
        _items.close();
    }

    /// `true` once `close` ran (buffered items may still be takeable).
    bool closed() const @safe pure nothrow @nogc => _closed;

    /// Buffered items.
    uint length() const @safe pure nothrow @nogc => _count;

    /// The fixed capacity.
    enum uint capacity = N;

private:
    // Stores into a slot the caller acquired, and hands a taker the item.
    void store(T item)
    {
        _items_[(_head + _count) % N] = move(item);
        ++_count;
        _items.release();
    }

    // Removes the oldest item, whose unit the caller acquired, and frees
    // its slot for a putter.
    T load()
    {
        auto item = move(_items_[_head]);
        _head = (_head + 1) % N;
        --_count;
        _space.release();
        return move(item);
    }

    T[N] _items_;
    uint _head;
    uint _count;
    bool _closed;
    Admission _space = Admission(N);
    Admission _items = Admission(N, N);
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
        assert(p.hasError && p.error.code == EPIPE);

        // Buffered items survive the close; only then EPIPE.
        auto a = ch.take(sched);
        auto b = ch.take(sched);
        assert(a.hasValue && a.value == 1);
        assert(b.hasValue && b.value == 2);
        auto end = ch.take(sched);
        sawDrainThenClose = end.hasError && end.error.code == EPIPE;
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
            takerEnded = r.hasError && r.error.code == EPIPE;
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
