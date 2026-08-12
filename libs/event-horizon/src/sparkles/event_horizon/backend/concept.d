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

version (OSX)
    private enum bool conceptHasKevent = true;
else version (EventHorizonLibkqueue)
    private enum bool conceptHasKevent = true;
else
    private enum bool conceptHasKevent = false;

static if (conceptHasKevent)
{
    private extern (C) int kevent(int kq, const(void)* changelist, int nchanges,
        void* eventlist, int nevents, const(void)* timeout) nothrow @nogc;
}

version (linux)
{
    private extern (C) int syscall(int sysno, ...) nothrow @nogc;
}

/**
The thread-safe wake handle (SPEC §5.6) — the ONLY loop-associated object
callable off-thread. Obtained from `EventLoop.waker()`; a copyable value.

The trigger is backend-native when the backend implements `nativeWaker`
(O29): `EVFILT_USER`/`NOTE_TRIGGER` on kqueue, a `FUTEX_WAKE` on uring,
`PostQueuedCompletionStatus` on IOCP. The portable fallback is a `write(2)`
to the loop's wake channel (an `eventfd` on Linux, a pipe elsewhere) —
thread-safe and async-signal-safe. Native wake is thread-safe and
coalescing; it is not promised async-signal-safe (`kevent`/`futex` are
not in the POSIX signal-safe set). Wakes coalesce; a wake before the
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
        package int fd = -1;              /// kqueue fd, or write side of the wake channel
        package uint ident;               /// 0 = `write(fd)`; else `EVFILT_USER` ident
        package shared(uint)* futex;      /// if set, `FUTEX_WAKE` this word (uring)
    }

    /// `false` for a default (never-armed) handle.
    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        version (Windows)
            return port !is null;
        else
            return futex !is null || fd >= 0;
    }

    /// Wakes the loop's wait. Callable from any thread. Coalescing; never
    /// blocks. The fd-write fallback is also async-signal-safe.
    void wake() const @trusted nothrow @nogc
    {
        version (Windows)
        {
            if (port !is null)
                cast(void) PostQueuedCompletionStatus(port, 0, 0, ov);
        }
        else
        {
            if (futex !is null)
            {
                import core.atomic : atomicOp;

                // Bump first so a re-arm that snapshots the word cannot
                // lose this wake; then wake whoever is already parked.
                // `wake` is `const` (the handle is a value); the word lives
                // in the backend.
                auto word = cast(shared(uint)*) futex;
                atomicOp!"+="(*word, 1);
                futexWake(word);
                return;
            }
            if (ident != 0 && fd >= 0)
            {
                triggerKqueueUser(fd, ident);
                return;
            }
            if (fd < 0)
                return;
            version (linux)
            {
                import core.sys.posix.unistd : write;

                ulong one = 1; // eventfd counter increment (8 bytes, mandated)
                cast(void) write(fd, &one, one.sizeof);
            }
            else version (Posix)
            {
                import core.sys.posix.unistd : write;

                ubyte one = 1; // pipe byte; EAGAIN when full = wake already pending
                cast(void) write(fd, &one, 1);
            }
        }
    }
}

/// Optional native-wake capability: a backend that can deliver a wake
/// completion with no armed read op. The loop prefers this over the
/// portable fd path (O29).
enum bool hasNativeWake(B) = __traits(compiles, {
    Waker w = lvalueOf!B.nativeWaker(OpToken.init);
});

version (Posix)
{
    private void futexWake(scope shared(uint)* word) @trusted nothrow @nogc
    {
        version (linux)
        {
            version (X86_64)
                enum SYS_futex = 202;
            else version (AArch64)
                enum SYS_futex = 98;
            else version (X86)
                enum SYS_futex = 240;
            else
                enum SYS_futex = 0;

            static if (SYS_futex != 0)
            {
                enum FUTEX_WAKE = 1;
                enum FUTEX_PRIVATE_FLAG = 128;
                cast(void) syscall(SYS_futex, cast(void*) word,
                    FUTEX_WAKE | FUTEX_PRIVATE_FLAG, 1, null, null, 0);
            }
        }
        else
            cast(void) word;
    }

    private void triggerKqueueUser(int kq, uint ident) @trusted nothrow @nogc
    {
        static if (conceptHasKevent)
        {
            // Layout matches BSD `struct kevent` / this package's `kevent_t`.
            struct kevent_t
            {
                size_t ident;
                short filter;
                ushort flags;
                uint fflags;
                ptrdiff_t data;
                void* udata;
            }

            enum short EVFILT_USER = -10;
            enum uint NOTE_TRIGGER = 0x0100_0000;
            kevent_t ch;
            ch.ident = ident;
            ch.filter = EVFILT_USER;
            ch.fflags = NOTE_TRIGGER;
            cast(void) kevent(kq, &ch, 1, null, 0, null);
        }
        else
        {
            cast(void) kq;
            cast(void) ident;
        }
    }
}
