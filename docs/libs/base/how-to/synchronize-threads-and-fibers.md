# Synchronize threads and fibers

`sparkles.base.sync` provides locks, a condition variable and a one-time
initializer whose state is one byte or one word and whose operations never
allocate. The same primitive serves threads and fibers: a thread that waits
sleeps, and a fiber that waits under a scheduler's parker suspends without
blocking its loop. Import the package, or a single module from it:

```d
import sparkles.base.sync : Condition, Guarded, Mutex, Once;
```

| See also                                                 |                                                       |
| -------------------------------------------------------- | ----------------------------------------------------- |
| [Specification](../../../specs/base/sync/SPEC.md)        | the parking lot, parkers and cancellation             |
| [The primitives](../../../specs/base/sync/primitives.md) | each primitive's contract, requirement by requirement |
| [The parking lot](../explanation/parking-lot.md)         | why the design is shaped the way it is                |

## Protect data with a mutex

`Mutex` is one byte. Its `.init` is unlocked, it cannot be copied, and its
address is its identity, so declare it where it will stay: a field, a
`__gshared` global, or a `shared` variable. `guard` locks it and returns a
guard that unlocks when it leaves scope:

```d
__gshared Mutex queueLock;
__gshared int queued;

void push()
{
    auto g = queueLock.guard();
    ++queued;
} // unlocked here
```

`lock` and `unlock` are there for code that cannot use a scope, along with
`tryLock`, which takes a free mutex without waiting, and `lockUntil`, which
gives up at a `MonoTime` deadline and returns `false` holding nothing. The
mutex records no owner and is not recursive; unlocking a mutex that is not
held fails an assertion.

A `Mutex` is for short critical sections that never suspend. Holding one pins
the caller to the thread parker (SYK9): a fiber that waits while holding it
blocks its thread instead of suspending. For a section that suspends, use an
[`InterruptibleMutex`](#lock-across-a-suspension).

## Keep data behind its lock with `Guarded!T`

`Guarded!T` holds a `T` and a `Mutex`, and the `T` is reachable only through
the guard that `lock` returns. The guard's `get` is `return scope`, so under
`-preview=dip1000` no reference into the payload outlives the guard:

```d
struct Counted
{
    int n;
}

Guarded!Counted counter;
{
    auto guard = counter.lock();
    guard.get.n = 5;
    assert(!counter.tryLock().holds); // the guard still holds the mutex
}
assert(counter.lock().get.n == 5);
```

`tryLock` and `lockUntil` return an empty guard when they fail; check `holds`
before calling `get`, which asserts on an empty guard.

`scope` protects the reference to the payload, not what the payload points
to, so a payload with mutable indirections is rejected at compile time
(SYG3): `Guarded!(int[])`, `Guarded!(int*)` and `Guarded!Object` do not
compile, while `Guarded!string` does, because its characters are immutable. A
struct that owns its indirections and hands them out only through
`return scope` members can declare itself `@contained`:

```d
import sparkles.base.buffer : UniqueBuffer;
import sparkles.base.sync : contained, Guarded;

@contained
struct Transcript
{
    private UniqueBuffer!(char, 64) text;

    void append(in char[] s) scope @safe => text.put(s);
    const(char)[] view() const return scope @safe => text[];
}

Guarded!Transcript transcript;
transcript.lock().get.append("hello");
```

The attribute is a promise the compiler cannot check: a member that returned
`text[]` without `return scope` would let the slice escape the lock.

## Wait for a condition

`Condition` is one word. Wait on it with the guard of the lock that protects
the state, in a loop on the state itself; notify while holding the same lock:

```d
__gshared Mutex queueLock;
__gshared Condition queueReady;
__gshared int queued;

void consume()
{
    auto g = queueLock.guard();
    while (queued == 0)
        queueReady.wait(g);
    --queued;
}

void produce()
{
    auto g = queueLock.guard();
    ++queued;
    queueReady.notifyOne();
}
```

`wait` releases the lock, sleeps until a notification selects the caller, and
returns with the lock held again. It never returns spuriously, but the loop
is still needed: another consumer can take the item between the notification
and the waiter's return.

`notifyOne` returns whether it selected a waiter, and `notifyAll` how many it
selected. A notification with no waiters is one atomic load, so notifying
unconditionally is cheap. A notification made while the lock is held moves
the waiters onto the lock's queue instead of waking them, so `notifyAll`
wakes one waiter per release rather than all of them at once.

The waiting forms with a deadline or cancellation return with the lock held
too, whatever ended the wait:

```d
const deadline = MonoTime.currTime + 10.msecs;
{
    auto g = queueLock.guard();
    while (queued == 0)
        if (!queueReady.waitUntil(g, deadline))
            break; // timed out, holding the lock
}
```

`waitInterruptible(guard, deadline = MonoTime.max)` returns a `WaitStatus`:
`ok`, `timedOut` or `cancelled`. Cancellation is reported only while the
waiter waits for a notification, never while it takes the lock back (SYC3),
and only under a parker that cancels: the thread parker never does, so on a
plain thread it behaves as `waitUntil`.

A condition accepts the guard of a `Mutex`, `LockBits`, `InterruptibleMutex`,
`Guarded!T` or `InterruptibleGuarded!T` (SYC9), but only one lock at a time:
waiting with a second lock while waiters of the first remain fails an
assertion.

## Lock across a suspension

`InterruptibleMutex` is for critical sections that may suspend, for example
across I/O on an event loop. Holding it does not pin the caller, and a
cancelled fiber stops waiting for it with nothing held. It has no `unlock`:
`lock` returns an `Acquisition`, the guard and how the wait ended, and only
the guard's destruction releases the mutex (SYJ1):

```d
__gshared InterruptibleMutex connectionLock;

WaitStatus send()
{
    auto a = connectionLock.lock();
    if (!a)
        return a.status; // cancelled or timed out; nothing is held
    // ... write, suspending while the socket is busy ...
    return WaitStatus.ok;
} // a.guard releases the mutex here
```

`lockUntil(deadline)` adds a deadline, and `tryLock` succeeds only when the
mutex is free and nobody is queued. Results are values, not exceptions, so
every operation stays `nothrow`. A grant that lands before a cancellation is
kept: the waiter returns holding the mutex and the cancellation stays pending
for its next interruptible wait (SYJ3).

Waiters are served in queue order by direct handoff, so a holder that
suspends for a long time does not let a running locker starve the queue.
That fairness costs a wake on every contended release; for short sections, a
`Mutex` is faster.

`InterruptibleGuarded!T` is `Guarded!T` over an `InterruptibleMutex`. Its
`lock` returns an acquisition whose `guard.get` reaches the payload:

```d
InterruptibleGuarded!Counted state;
auto a = state.lock();
if (a)
    a.guard.get.n += 1;
```

## Embed a lock in a word you already have

`LockBits` runs the mutex's algorithm on three bits of an atomic integer of
1, 2, 4 or 8 bytes, keyed by the integer's address. Every operation changes
only those three bits, so the rest of the word can hold a counter or flags
that other code updates concurrently:

```d
alias HeaderLock = LockBits!(uint, 1, 2, 4); // locked, parked, designated

shared uint header = 0x8000_0000; // the top bit belongs to the caller

HeaderLock.lock(header);
HeaderLock.unlock(header);
assert(header == 0x8000_0000);

{
    auto g = HeaderLock.guard(header);
    // ...
}
```

`lockUntil(word, deadline)` and `tryLock(word)` behave as the mutex's do, and
the guard works with `Condition`. A word carries at most one embedded lock,
and is not also used as the key of another primitive (SYL3).

## Initialize once

`Once` is one byte. `call` runs its initializer unless one has already
completed, and every caller returns only after one has; callers that arrive
while it runs wait for it. Once complete, `call` is a single acquire load:

```d
__gshared Once tableReady;
__gshared int[256] table;

void useTable()
{
    tableReady.call(() { table[] = 1; });
    // table is initialized here, in every thread
}
```

An initializer that throws an `Exception` returns the `Once` to incomplete,
and the exception propagates to that caller; the next caller, or one that was
waiting, runs the initializer again and sees what the failed attempt wrote.
An initializer that throws an `Error` poisons the `Once`: waiting callers
are woken, and every later `call` fails an assertion.

`callUntil(init, deadline, interruptible = false)` bounds only the wait for
another caller's initializer and returns a `WaitStatus`; a timeout or a
cancellation leaves that initializer running. A caller that runs the
initializer itself runs it to completion. `isComplete` reports whether one
has completed.

## Run the primitives on your own scheduler

Every blocking operation parks through the calling thread's current parker,
which is the thread parker unless a scheduler installs its own. A scheduler
installs its parker when it resumes a fiber and restores the previous one
when the fiber suspends or ends:

```d
auto previous = installParker(fiberParker);
scope (exit)
    installParker(previous);
```

A `Parker` is a `ParkerVtbl` of function pointers and a context pointer; its
operations and the guarantees each must give are in
[SPEC §4](../../../specs/base/sync/SPEC.md#_4-parkers) and
[§4a](../../../specs/base/sync/SPEC.md#_4a-cancellation).
`sparkles:event-horizon`'s fiber parker is the reference implementation; its
contract is the [fiber parker specification](../../../specs/event-horizon/fiber-parker.md).
While a caller holds a `Mutex`, a `LockBits` lock or a `Guarded!T`, it is
pinned, and its waits use the thread parker whatever is installed.
