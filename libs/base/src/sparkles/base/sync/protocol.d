/**
Protocol tags and unpark tokens shared by the primitives.

Every record carries its primitive's protocol tag, and a key holds records of
one protocol at a time (SYP14). An unpark token says what the unparker did
for the woken waiter; the tokens here are the ones that cross primitives, as
a condition waiter moved onto a lock's queue is then woken by that lock.
*/
module sparkles.base.sync.protocol;

/// The protocol of a key's records (SYP14).
enum Protocol : ubyte
{
    none,
    mutex,
    interruptibleMutex,
    condition,
    rwLock,
    rwUpgrade,
    once,
    semaphore,
    event,
    barrier,
    latch,
    addressWait,
}

/// The lock was handed to the woken waiter, which holds it (SYM8, SYJ5).
enum size_t tokenHandoff = 1;
/// The woken waiter is the lock's designated waker (SYM6).
enum size_t tokenDesignated = 2;
/// A notification selected the waiter and the lock was free: it must acquire.
enum size_t tokenNotified = 3;

/// A park token: the waiter asks the next unlock to hand it the lock (SYM8).
enum size_t parkHandoffRequest = 1;
