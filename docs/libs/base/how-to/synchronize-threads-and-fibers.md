# Synchronize threads and fibers

`sparkles.base.sync` provides locks, a condition variable, a one-time
initializer, a reader–writer lock, a semaphore, events, a latch, a barrier
and a futex-style wait on any word. Each primitive's state is one byte or
one word, and no operation allocates. The same primitive serves threads and fibers: a thread that waits
sleeps, and a fiber that waits under a scheduler's parker suspends without
blocking its loop. Import the package, or a single module from it:

```d
import sparkles.base.sync : Condition, Guarded, Mutex, Once, RwLock, Semaphore;
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

## Share data among readers with `RwLock`

`RwLock` is one word with three modes: shared for readers, exclusive for
a writer, and upgradable, which coexists with readers and can later become
exclusive. `read`, `write` and `upgradableRead` return a guard that
releases its mode when it leaves scope:

```d
__gshared RwLock routesLock;
__gshared int[string] routes;

int lookup(string name)
{
    auto g = routesLock.read();
    return routes.get(name, -1);
}

void add(string name, int port)
{
    auto g = routesLock.write();
    routes[name] = port;
}
```

Once a writer is waiting, new readers queue behind it instead of
overtaking it (SYR3), so a steady stream of readers cannot starve writers.
A release hands the lock to the head of the queue directly: one writer, or
every reader up to the first writer.

An upgradable guard reads alongside other readers, then upgrades when it
decides to write. The upgrade waits only for the readers already inside
and goes ahead of every queued writer (SYR4):

```d
void addIfMissing(string name, int port)
{
    auto g = routesLock.upgradableRead();
    if (name in routes)
        return;
    g.upgrade(); // exclusive from here
    routes[name] = port;
}
```

Only one upgradable holder exists at a time. `upgradeUntil(deadline)`
gives up at a deadline and leaves the caller in upgradable mode;
`downgrade` turns an exclusive or upgradable guard back into a reader.
The raw operations (`lockShared`/`unlockShared`, `lock`/`unlock`,
`lockUpgradable`/`unlockUpgradable`) have `try` and `Until` forms that
return `false` holding nothing. Like `Mutex`, an `RwLock` is for short
sections: holding any mode pins the caller, and acquisition is never
interruptible. Taking shared mode while already holding the lock is a
programming error; with a writer queued it deadlocks.

## Limit concurrency with a semaphore

`Semaphore` is one word of permits. `acquire` takes one, waiting while
none is available; `release(n)` adds `n`. Its `.init` holds no permits, so
construct it with a count:

```d
__gshared Semaphore downloads;

shared static this()
{
    downloads = Semaphore(4); // at most four at once
}

void download(string url)
{
    downloads.acquire();
    scope (exit)
        downloads.release();
    // ...
}
```

While anyone waits, `release` hands its permits to the waiters in queue
order instead of raising the count, so a waiter is never overtaken by a
caller that arrived later (SYS3). `tryAcquire` takes a permit without
waiting, and `acquireUntil(deadline, interruptible = false)` returns a
`WaitStatus`; a waiter that was handed a permit keeps it even if its
deadline passes or a cancellation arrives before it returns (SYS4).

## Signal with events

`ManualResetEvent` and `AutoResetEvent` are one byte each. A manual-reset
event stays set until `reset` and releases every waiter; an auto-reset
event releases one waiter per `set`, or, with nobody waiting, stays set
until the next `wait` consumes it:

```d
__gshared ManualResetEvent configLoaded;
__gshared AutoResetEvent workAvailable;

void worker()
{
    configLoaded.wait(); // every worker passes once the config is in
    while (true)
    {
        workAvailable.wait(); // one worker per signal
        // ...
    }
}
```

`waitUntil(deadline, interruptible = false)` returns a `WaitStatus`, and
`tryWait` never waits: it reports whether the event is set and, for an
auto-reset event, consumes the signal. Setting a set event does nothing
more, so signals do not accumulate; count them with a `Semaphore` if they
must.

## Wait for a count or a rendezvous

`Latch(n)` opens once `countDown` has been called `n` times and stays open:
every `wait`, before or after, returns once the count reaches zero.
`Barrier(n)` releases all `n` parties when the last arrives, returns `true`
to exactly one of them, and is then ready for the next round:

```d
enum workers = 4;
__gshared Latch started;
__gshared Barrier phase;

shared static this()
{
    started = Latch(workers);
    phase = Barrier(workers);
}

void work()
{
    started.countDown();
    foreach (step; 0 .. 10)
    {
        // ... this step's share of the work ...
        if (phase.arriveAndWait())
        {
            // exactly one party gets here per step
        }
    }
}

void supervise()
{
    started.wait(); // every worker is running
}
```

`arriveAndWaitUntil(deadline, interruptible = false)` returns an `Arrival`:
its `status`, and whether this party completed the round (`leader`). A party
that times out or is cancelled before the round completes withdraws its
arrival, so the round still needs all `n` parties (SYB2). The latch's
`waitUntil` leaves the count unchanged when it gives up, and counting below
zero fails an assertion.

## Wait on a word

`waitWhile(word, expected)` waits, as a futex does, while an atomic word of
1, 2, 4 or 8 bytes holds `expected`, and `wakeOne(word)` and `wakeAll(word)`
wake its waiters and return how many they woke. The waiters queue in the
parking lot, so a fiber that waits suspends:

```d
shared uint generation;

void awaitNext(uint seen)
{
    while (atomicLoad(generation) == seen)
        waitWhile(generation, seen);
}

void publish()
{
    atomicOp!"+="(generation, 1);
    wakeAll(generation);
}
```

A store alone wakes nobody: only `wakeOne` and `wakeAll` on the same word
do (SYW3). A woken waiter returns without reading the word again, so wait
in a loop on your own condition. `waitWhileUntil(word, expected, deadline,
interruptible = false)` reports `timedOut` or `cancelled` only if the caller
waited and was not woken. A word used this way cannot also carry a
`LockBits` lock (SYL3).

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
While a caller holds a `Mutex`, a `LockBits` lock, a `Guarded!T` or an
`RwLock`, it is pinned, and its waits use the thread parker whatever is installed.
