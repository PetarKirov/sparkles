/**
The address wait (primitives.md §12): waiting for a memory word to change,
the way a futex does, but through the parking lot, so that a fiber that waits
suspends (DS10).

A waiter parks under the word's address while the word holds the value it
expects, checked under the bucket lock (SYW1); only `wakeOne` and `wakeAll`
on the same word wake it, never a store alone (SYW3). As with a futex, a
woken waiter returns without reading the word again: callers loop on their
own condition.

A word used with the address wait **must not** also be a `LockBits` word
(SYL3, SYP14).
*/
module sparkles.base.sync.address_wait;

import core.time : MonoTime;

import sparkles.base.sync.interruptible_mutex : WaitStatus;
import sparkles.base.sync.parker : observesCancellation;
import sparkles.base.sync.parking_lot;
import sparkles.base.sync.platform : NativePlatform, Order;
import sparkles.base.sync.protocol;
import sparkles.base.sync.seam : Deadline;

/// The address wait over platform `P`, for words of type `A` (an atomic of 1, 2, 4 or 8 bytes).
template AddressWait(P)
{
    /**
    Parks while `word` equals `expected` (SYW1): returns at once without
    parking if it already differs, and otherwise after a wake on `word`.
    */
    void waitWhile(A, T)(ref A word, T expected)
    {
        cast(void) waitWhileTicks(word, expected, Deadline.never, false);
    }

    /**
    As `waitWhile`, by `deadline` or interruptibly: `timedOut` or `cancelled`
    only if the caller parked and was not woken (SYW1).
    */
    WaitStatus waitWhileUntil(A, T)(ref A word, T expected, MonoTime deadline, bool interruptible = false)
        => waitWhileTicks(word, expected,
            deadline == MonoTime.max ? Deadline.never : Deadline.at(deadline), interruptible);

    /// `waitWhileUntil` with a deadline in platform ticks (the model's virtual clock).
    WaitStatus waitWhileTicks(A, T)(ref A word, T expected, Deadline d, bool interruptible)
    {
        alias V = typeof(P.load!(Order.relaxed)(word));
        static assert(V.sizeof == 1 || V.sizeof == 2 || V.sizeof == 4 || V.sizeof == 8,
            "the address wait takes a word of 1, 2, 4 or 8 bytes (SYW1)");
        if (P.load!(Order.acquire)(word) != expected)
            return WaitStatus.ok;
        const r = park!P(keyOf(word), ParkOptions(Protocol.addressWait, deadline: d,
                interruptible: observesCancellation!P(interruptible)),
            (ref const LockedKey!P lk) => P.load!(Order.relaxed)(word) == expected);
        final switch (r.outcome)
        {
        case ParkOutcome.invalid:
            // The validation's read was relaxed; this is the acquire.
            cast(void) P.load!(Order.acquire)(word);
            return WaitStatus.ok;
        case ParkOutcome.unparked:
            return WaitStatus.ok;
        case ParkOutcome.timedOut:
            return WaitStatus.timedOut;
        case ParkOutcome.cancelled:
            return WaitStatus.cancelled;
        }
    }

    /// Wakes the earliest waiter of `word`; returns how many it woke, 0 or 1 (SYW2).
    uint wakeOne(A)(ref A word)
        => unparkOne!P(keyOf(word), Protocol.addressWait,
            (ref const LockedKey!P lk, UnparkResult res) => UnparkDecision(0)).unparked;

    /// Wakes every waiter of `word`; returns how many it woke (SYW2).
    uint wakeAll(A)(ref A word)
        => unparkAll!P(keyOf(word), Protocol.addressWait,
            (ref const LockedKey!P lk, UnparkResult res) => UnparkDecision(0)).unparked;

    private size_t keyOf(A)(ref A word) @trusted => cast(size_t) &word;
}

/// Parks while `word` equals `expected` (SYW1).
void waitWhile(T)(ref shared T word, T expected) @safe nothrow @nogc
    => AddressWait!NativePlatform.waitWhile(word, expected);

/// Parks while `word` equals `expected`, by `deadline` or interruptibly (SYW1).
WaitStatus waitWhileUntil(T)(ref shared T word, T expected, MonoTime deadline, bool interruptible = false)
    @safe nothrow @nogc
    => AddressWait!NativePlatform.waitWhileUntil(word, expected, deadline, interruptible);

/// Wakes the earliest waiter of `word` (SYW2).
uint wakeOne(T)(ref shared T word) @safe nothrow @nogc => AddressWait!NativePlatform.wakeOne(word);

/// Wakes every waiter of `word` (SYW2).
uint wakeAll(T)(ref shared T word) @safe nothrow @nogc => AddressWait!NativePlatform.wakeAll(word);
