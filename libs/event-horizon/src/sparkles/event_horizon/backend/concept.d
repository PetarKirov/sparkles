/**
The DbI completion-backend concept (SPEC §3.1). A backend is a struct
satisfying `isCompletionBackend!B` — capability traits, no interface, no
vtable: the loop is `EventLoop!Backend`, submission lowering is a statically
dispatched overload set, and the whole submit path inlines.

The concept is defined by completion $(I semantics), not by `io_uring`: a
backend that synthesizes completion over readiness (kqueue) must still
deliver `(userData, res, flags)` triples where `res` is a byte count / fd or
`-errno`.
*/
module sparkles.event_horizon.backend.concept;

import std.traits : lvalueOf;

import sparkles.event_horizon.errors : IoResult, OpKind;
import sparkles.event_horizon.op : KernelTimespec, OpNop, OpSlot, OpToken;

/// What the backend hands the loop per completion — the raw
/// `(user_data, res, flags)` triple; the loop resolves the token and builds
/// the typed `Completion`.
struct RawCompletion
{
    ulong userData; /// the submitted `OpToken.raw`
    int res;        /// `>= 0` payload or `-errno`
    uint rawFlags;  /// backend-native completion flags
}

/// Backend-level configuration (the loop's `LoopConfig` embeds this).
struct BackendConfig
{
    uint sqEntries = 256; /// submission-queue entries (rounded to a power of two)
    uint cqEntries = 0;   /// completion-queue entries; 0 = backend default (uring: 2× sq)
    ubyte mode;           /// requested `LoopMode` (kept `ubyte` to stay leaf-friendly)
    ubyte modePolicy;     /// `ModePolicy` for mode negotiation
}

/**
Per-descriptor submission capability; the backend owns the lowering and
receives the op's slot (`ref OpSlot`) — the loop has already moved owned
buffers into `slot.pinned` and kernel-stable operands into `slot.operands`,
so the SQE points only at slot-stable memory (SPEC §4.1).

The probe passes an rvalue op: descriptors carrying an owned buffer are
move-only, so submission moves the op — an lvalue probe would statically
reject every buffer-carrying op (SPEC §3.1).
*/
enum bool canSubmitOp(B, Op) = __traits(compiles, {
    bool r = lvalueOf!B.trySubmit(Op.init, OpToken.init, lvalueOf!OpSlot);
});

/**
Required backend primitives — checked as the exact expressions the loop
calls (DbI guidelines §4.3). All must infer `nothrow @nogc` for the uring
backend; the unittests static-assert that.

Two contracts the expressions cannot state, both load-bearing:

$(UL
$(LI `trySubmit` returns `false` for $(B backpressure only) — a submission
    resource is full, so `flush()` and retry. It never means the kernel
    rejected the operation: a rejected submission arrives as an ordinary
    completion carrying `-errno`, whether it was a bad SQE (uring) or a
    rejected change-list entry (kqueue, O27). The loop's retry path depends on
    this: a `false` it cannot clear by flushing is an infinite retry.)
$(LI `flush()` returns $(B submission-side units flushed, backend-defined) —
    SQEs on uring, change entries on kqueue, where one cancel adds an entry of
    its own. Forcing a shared unit would make a backend count things it did not
    submit, for a number no caller reads beyond "did progress happen".)
)
*/
enum bool isCompletionBackend(B) = __traits(compiles, {
    BackendConfig cfg;
    IoResult!void o = lvalueOf!B.open(cfg);
    auto caps = lvalueOf!B.caps();
    bool queued = lvalueOf!B.trySubmit(OpNop(), OpToken.init, lvalueOf!OpSlot); // false = full
    IoResult!uint f = lvalueOf!B.flush();
    IoResult!uint w = lvalueOf!B.submitAndWait(1u, cast(const(KernelTimespec)*) null);
    uint n = lvalueOf!B.reap((ref const RawCompletion c) {});  // non-blocking drain
    lvalueOf!B.close();
}) && canSubmitOp!(B, OpNop);

// Optional capabilities (SPEC §3.1) — absence degrades, never breaks. The
// remaining traits (hasRegisteredBuffers, hasBufRing, hasNativeCancel,
// hasNativeTimeout, hasMsgRing, hasDirectFds) land with the features that
// consume them (M3+); defining them before any generic code dispatches on
// them would leave them untested.

/// Multishot support is runtime-caps-backed; the trait gates the call shape.
enum bool hasMultishot(B) = __traits(compiles, {
    bool r = lvalueOf!B.supportsMultishot(OpKind.init);
});

version (Windows)
{
    private extern (Windows) int PostQueuedCompletionStatus(
        void* port, uint bytes, size_t key, void* ov) nothrow @nogc;
}

/**
The thread-safe wake handle (SPEC §5.6) — the ONLY loop-associated object
callable off-thread. Obtained from `EventLoop.waker()`; a copyable value.

On Posix it holds the write side of the loop's wake channel — an `eventfd`
on Linux, a pipe elsewhere — and `wake()` is a single `write(2)`:
thread-safe AND async-signal-safe. On Windows it posts a zero-byte packet
to the completion port (`PostQueuedCompletionStatus` — thread-safe; signal
handlers are not a Windows concept). Wakes coalesce; a wake before the
loop waits makes the next wait return immediately.

The handle borrows loop-owned resources: `wake()` after the loop's
`destroy()` is harmless (an `EBADF` write / a post to a closed port is
ignored) but delivers nothing.
*/
struct Waker
{
    version (Windows)
    {
        package void* port; /// the completion port
        package void* ov;   /// the persistent wake op's `OVERLAPPED*`
    }
    else
    {
        package int fd = -1; /// write side of the wake channel
    }

    /// `false` for a default (never-armed) handle.
    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        version (Windows)
            return port !is null;
        else
            return fd >= 0;
    }

    /// Wakes the loop's wait. Callable from any thread (and, on Posix, from
    /// signal handlers). Coalescing; never blocks.
    void wake() const @trusted nothrow @nogc
    {
        version (Windows)
        {
            if (port !is null)
                cast(void) PostQueuedCompletionStatus(port, 0, 0, ov);
        }
        else version (linux)
        {
            import core.sys.posix.unistd : write;

            if (fd >= 0)
            {
                ulong one = 1; // eventfd counter increment (8 bytes, mandated)
                cast(void) write(fd, &one, one.sizeof);
            }
        }
        else version (Posix)
        {
            import core.sys.posix.unistd : write;

            if (fd >= 0)
            {
                ubyte one = 1; // pipe byte; EAGAIN when full = wake already pending
                cast(void) write(fd, &one, 1);
            }
        }
    }
}

/// Optional native-wake capability: a backend that can deliver a wake
/// completion with no armed read op (IOCP's completion-port post). The
/// loop prefers the portable fd path where a read lowering exists.
enum bool hasNativeWake(B) = __traits(compiles, {
    Waker w = lvalueOf!B.nativeWaker(OpToken.init);
});
