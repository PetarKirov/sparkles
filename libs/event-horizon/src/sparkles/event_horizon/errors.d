/**
`Expected`-based error vocabulary for the event loop, mirroring
`sparkles.base.text.errors`: struct error + hook + alias + helper
constructors. Deliberately a leaf module — it imports only `expected` — so
every other module (including the effects-side ones) can use it without
touching ring code.
*/
module sparkles.event_horizon.errors;

import expected : Expected, err, ok;

/**
Portable operation vocabulary — the $(I kind) only; operands live in the
`op` descriptors. Lives here (not in `op`) so $(LREF IoError) can name the
failing operation while this module stays a leaf.
*/
enum OpKind : ubyte
{
    none,            /// no operation (loop-level failure)
    nop,             /// no-op round-trip
    read,            /// positioned read
    write,           /// positioned write
    recv,            /// socket receive (caller-supplied buffer)
    recvSelect,      /// receive with kernel buffer selection (provided ring)
    send,            /// socket send
    sendTo,          /// datagram send to an address
    recvFrom,        /// datagram receive with source address
    accept,          /// accept one connection
    acceptMultishot, /// armed accept stream
    connect,         /// outbound connect
    shutdown,        /// socket shutdown
    openAt,          /// open a file
    close,           /// close a descriptor
    statx,           /// stat a path
    fsync,           /// flush a file
    timeout,         /// timer
    linkTimeout,     /// per-op deadline linked to the previous op
    cancel,          /// cancellation of another op
    futexWait,       /// in-ring futex wait
    futexWake,       /// in-ring futex wake
    msgRing,         /// cross-ring message
    waitid,          /// child-process reap
}

/// Which stage of an operation's life produced the failure.
enum IoErrorStage : ubyte
{
    setup,        /// ring/backend creation (`io_uring_setup` `ENOSYS`/`EPERM`, …)
    probe,        /// capability probing / operating-mode negotiation
    registration, /// registering buffers / files / a buffer ring
    submit,       /// submission time (SQ full after flush, slab exhausted, …)
    completion,   /// the completion itself carried `-errno` (the common case)
    cancel,       /// an `ASYNC_CANCEL` round-trip failed
}

/**
Structured I/O error: a positive `errno` (a completion's negative `res`,
negated), the $(LREF OpKind) that failed, the $(LREF IoErrorStage) it failed
at, and an optional borrowed detail (typically a CTFE literal).
*/
struct IoError
{
    int errnoValue;                               /// positive errno; 0 = not an OS error
    OpKind op = OpKind.none;                      /// which portable op failed
    IoErrorStage stage = IoErrorStage.completion; /// where in the op's life
    string context = null;                        /// borrowed detail (CTFE literal)
}

/**
`expected` hook shared by every event-horizon result: disables default
construction so a result is always explicitly `ok` or `err`, and removes
`Expected`'s copying value-accessor fallback so $(LREF IoResult) instantiates
with move-only payloads (extraction via `move(r.value)`).
*/
struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;

    /// Called on `.value` access of an errored result; `assert(0)` keeps the
    /// hook (and everything instantiating it) `@safe pure nothrow @nogc`.
    static void onAccessEmptyValue(E)(E err) @safe pure nothrow @nogc
        => assert(0, "accessed the value of an error IoResult");
}

/// The I/O result currency of the callback and fiber tiers.
alias IoResult(T) = Expected!(T, IoError, NoGcHook);

/// Constructs a successful $(LREF IoResult) carrying `value`.
/// (Attributes infer, and the payload is forwarded: a move-only payload
/// with a non-trivial destructor — `Buf` — must neither be rejected by a
/// forced `pure`/`@safe` nor copied on the way in.)
IoResult!T ioOk(T)(auto ref T value)
{
    import core.lifetime : forward;

    return ok!(IoError, NoGcHook)(forward!value);
}

/// ditto — success with no payload (`IoResult!void`).
/// (Explicitly attributed: as a non-template it cannot infer them.)
IoResult!void ioOk() @safe pure nothrow @nogc
    => ok!(IoError, NoGcHook)();

/// Constructs a failed $(LREF IoResult)`!T` carrying `error`. `T` is
/// explicit (there is no value to infer it from); attributes infer.
IoResult!T ioErr(T)(IoError error)
    => err!(T, NoGcHook)(error);

/// ditto — the common `errno` + op form:
/// `return ioErr!uint(EAGAIN, OpKind.send, IoErrorStage.submit);`
IoResult!T ioErr(T)(int errnoValue, OpKind op,
    IoErrorStage stage = IoErrorStage.completion, string context = null)
    => err!(T, NoGcHook)(IoError(errnoValue, op, stage, context));

/// The single point where a raw completion `res` (`>= 0` payload — byte
/// count or new fd — or `-errno`) becomes typed.
IoResult!uint fromRes(int res, OpKind op) @safe pure nothrow @nogc
    => res < 0 ? ioErr!uint(-res, op) : ioOk(cast(uint) res);

@("errors.ioOk")
@safe pure nothrow @nogc
unittest
{
    auto good = ioOk(42);
    assert(good.hasValue);
    assert(good.value == 42);

    auto empty = ioOk();
    assert(!empty.hasError);
}

@("errors.ioErr")
@safe pure nothrow @nogc
unittest
{
    auto bad = ioErr!int(11, OpKind.recv, IoErrorStage.submit, "sq full");
    assert(bad.hasError);
    assert(bad.error.errnoValue == 11);
    assert(bad.error.op == OpKind.recv);
    assert(bad.error.stage == IoErrorStage.submit);
    assert(bad.error.context == "sq full");
}

@("errors.fromRes")
@safe pure nothrow @nogc
unittest
{
    auto count = fromRes(4096, OpKind.read);
    assert(count.hasValue && count.value == 4096);

    auto failed = fromRes(-104, OpKind.recv); // -ECONNRESET
    assert(failed.hasError);
    assert(failed.error.errnoValue == 104);
    assert(failed.error.stage == IoErrorStage.completion);
}

@("errors.moveOnlyPayload")
@safe pure nothrow @nogc
unittest
{
    import core.lifetime : move;

    // The onAccessEmptyValue hook member removes Expected's copying
    // accessor fallback, so IoResult instantiates with move-only payloads
    // (SPEC §9.1) — this test locks that in.
    static struct MoveOnly
    {
        @disable this(this);
        int fd = -1;
    }

    auto r = ioOk(MoveOnly(3));
    assert(r.hasValue);
    auto extracted = move(r.value);
    assert(extracted.fd == 3);

    auto e = ioErr!MoveOnly(38, OpKind.none, IoErrorStage.setup);
    assert(e.hasError);
    assert(e.error.errnoValue == 38);
}
