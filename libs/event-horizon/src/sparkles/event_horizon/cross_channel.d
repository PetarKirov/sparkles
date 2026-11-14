/**
The bounded cross-worker channel (SPEC §14.1): `Channel`'s semantics for
producers and consumers on different workers of a `LoopGroup` or pool, and on
threads no scheduler runs.

It adds no wake mechanism of its own. One `sparkles.base.sync.Mutex` guards
the buffer, and the two sides wait on two `Condition`s, so a wait parks
through the caller's current parker: a `Sched` fiber suspends alone and is
woken on its owner through the fiber parker (fiber-parker.md EFP9, EFP12),
and any other thread sleeps on its thread parker. Nothing spins or polls,
and every backend with the fiber parker carries it.

`put`/`take` are cancellation checkpoints with `Channel`'s discipline (SPEC
§8.4): the fiber verbs check the latch first, and a parked fiber's one-shot
cancel function resumes it into `ECANCELED` without touching the buffer.
`close` is idempotent: putters fail `EPIPE`; takers drain, then `EPIPE`.
Every slot transition happens under the lock, so each stored item is taken
exactly once.

The channel is address-pinned (SPEC §8.1) and must outlive every user:
close it, join every scope that puts or takes, then destroy it.
*/
module sparkles.event_horizon.cross_channel;

import core.lifetime : move;
import core.stdc.errno : ECANCELED, EPIPE;

import sparkles.base.sync : Condition, Mutex, WaitStatus;

import sparkles.event_horizon.capability : hasFiberParker, isFiberExecutor;
import sparkles.event_horizon.cause : interruptRequested;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/**
A bounded FIFO channel of `T` (moved in and out — `T` need not be
copyable), capacity `N`, shared by fibers of any workers and by threads.
*/
struct CrossChannel(T, uint N = 16)
if (N > 0)
{
    @disable this(this); // waiters and the lock's queue hold its address

    ~this()
    {
        assert(_parkedPutters == 0 && _parkedTakers == 0,
            "a CrossChannel destroyed while a waiter is parked on it (SPEC §14.1)");
    }

    /**
    Delivers `item` from a fiber of `exec`, parking while the buffer is full.
    `EPIPE` when closed; `ECANCELED` when the fiber is interrupted, before or
    while parked. On error nothing was stored, and the item is destroyed with
    the parameter.
    */
    IoResult!void put(X)(ref X exec, T item)
    if (isFiberExecutor!X && hasFiberParker!X)
    {
        if (interruptRequested(*exec.currentContext()))
            return interruptedErr!void("cross-channel put interrupted");
        return putParking(item);
    }

    /// As the fiber `put`, from any thread: it parks through the caller's
    /// current parker and has no up-front checkpoint (SPEC §14.1).
    IoResult!void put(T item) => putParking(item);

    /**
    Takes the oldest item from a fiber of `exec`, parking while the buffer is
    empty. Buffered items outlive `close`: `EPIPE` arrives only once drained.
    */
    IoResult!T take(X)(ref X exec)
    if (isFiberExecutor!X && hasFiberParker!X)
    {
        if (interruptRequested(*exec.currentContext()))
            return interruptedErr!T("cross-channel take interrupted");
        return takeParking();
    }

    /// As the fiber `take`, from any thread.
    IoResult!T take() => takeParking();

    /// Non-parking put; `false` when full or closed, leaving `item` with the
    /// caller.
    bool tryPut(ref T item)
    {
        auto g = _lock.guard();
        if (_closed || _count >= N)
            return false;
        store(item);
        return true;
    }

    /// Non-parking take; `false` when empty.
    bool tryTake(out T item)
    {
        auto g = _lock.guard();
        if (_count == 0)
            return false;
        item = remove();
        return true;
    }

    /// Closes the channel (idempotent) and wakes every parked waiter.
    void close() @safe nothrow @nogc
    {
        auto g = _lock.guard();
        if (_closed)
            return;
        _closed = true;
        cast(void) _notFull.notifyAll();
        cast(void) _notEmpty.notifyAll();
    }

    /// `true` once `close` ran (buffered items may still be takeable).
    bool closed() @safe nothrow @nogc
    {
        auto g = _lock.guard();
        return _closed;
    }

    /// Buffered items, a snapshot.
    uint length() @safe nothrow @nogc
    {
        auto g = _lock.guard();
        return _count;
    }

    /// Putters parked on a full buffer, a snapshot.
    uint parkedPutters() @safe nothrow @nogc
    {
        auto g = _lock.guard();
        return _parkedPutters;
    }

    /// Takers parked on an empty buffer, a snapshot.
    uint parkedTakers() @safe nothrow @nogc
    {
        auto g = _lock.guard();
        return _parkedTakers;
    }

    /// The fixed capacity.
    enum uint capacity = N;

private:
    IoResult!void putParking(ref T item)
    {
        auto g = _lock.guard();
        for (;;)
        {
            if (_closed)
                return closedErr!void();
            if (_count < N)
            {
                store(item);
                return ioOk();
            }
            // Cancelled means not selected (base.sync SYC7): no
            // notification is lost with this waiter.
            ++_parkedPutters;
            const st = _notFull.waitInterruptible(g);
            --_parkedPutters;
            if (st == WaitStatus.cancelled)
                return interruptedErr!void("cross-channel put interrupted");
        }
    }

    IoResult!T takeParking()
    {
        auto g = _lock.guard();
        for (;;)
        {
            if (_count > 0)
                return ioOk(remove());
            if (_closed)
                return closedErr!T();
            ++_parkedTakers;
            const st = _notEmpty.waitInterruptible(g);
            --_parkedTakers;
            if (st == WaitStatus.cancelled)
                return interruptedErr!T("cross-channel take interrupted");
        }
    }

    /// Under the lock, with room: stores and notifies one taker.
    void store(ref T item)
    {
        _items[(_head + _count) % N] = move(item);
        ++_count;
        cast(void) _notEmpty.notifyOne();
    }

    /// Under the lock, non-empty: removes the oldest and notifies one putter.
    T remove()
    {
        auto item = move(_items[_head]);
        _head = (_head + 1) % N;
        --_count;
        cast(void) _notFull.notifyOne();
        return item;
    }

    static IoResult!R interruptedErr(R)(string msg)
        => ioErr!R(ECANCELED, OpKind.none, IoErrorStage.submit, msg);

    static IoResult!R closedErr(R)()
        => ioErr!R(EPIPE, OpKind.none, IoErrorStage.submit, "cross-channel closed");

    Mutex _lock;
    Condition _notFull, _notEmpty;
    T[N] _items;
    uint _head;
    uint _count;
    uint _parkedPutters;
    uint _parkedTakers;
    bool _closed;
}
