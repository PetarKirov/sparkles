/**
The loop's error vocabulary: `sparkles.base.io.errors`, re-exported, plus the
forms that take a raw `errno`.

Every failure is the shared `IoError`, whose `kind` is computed here, where a
completion's `res` or a call's `errno` first becomes a value (SPEC §9.1). The
module stays a leaf of the library: it imports only `sparkles:base`, the
loop-free error table of `sparkles:event-horizon-sys` and `expected`, so every
other module can use it without touching ring code.
*/
module sparkles.event_horizon.errors;

public import sparkles.base.io.errors;

import expected : err;

import sparkles.event_horizon.sys.error_kinds : errnoKind;

/// The shared constructors, overloaded below with the `errno` forms.
alias ioErr = sparkles.base.io.errors.ioErr;

/**
An $(LREF IoError) for the host `errno` value `code`, classified once
through `errnoKind`. `code` may be 0 for a failure that is not the
operating system's, which classifies as `ErrorKind.other`.
*/
IoError ioError(int code, OpKind op = OpKind.none,
    IoErrorStage stage = IoErrorStage.completion, string context = null)
    @safe pure nothrow @nogc
    => IoError(errnoKind(code), code, op, stage, context);

/// A failed `IoResult!T` for the host `errno` value `code`:
/// `return ioErr!uint(EAGAIN, OpKind.send, IoErrorStage.submit);`
IoResult!T ioErr(T)(int code, OpKind op,
    IoErrorStage stage = IoErrorStage.completion, string context = null)
    => err!(T, NoGcHook)(ioError(code, op, stage, context));

/// The single point where a raw completion `res` (`>= 0` payload, a byte
/// count or a new descriptor, or `-errno`) becomes typed.
IoResult!uint fromRes(int res, OpKind op) @safe pure nothrow @nogc
    => res < 0 ? ioErr!uint(-res, op) : ioOk(cast(uint) res);

version (unittest)
{
    /// The `skipTest` reason for an `IoError` that degrades a test to a SKIP.
    /// Reuses the error's own borrowed CTFE literal, so the skip line reads
    /// exactly like the diagnostic the production path would have emitted.
    /// NB by value, not `in`: `-preview=in` makes the parameter `scope`, and
    /// dip1000 then rejects returning the borrowed `context` slice out of it.
    package(sparkles.event_horizon) string skipReason(const IoError e)
        @safe pure nothrow @nogc
        => e.context.length ? e.context : "io_uring unavailable";
}

@("errors.ioErr.errnoForm")
@safe pure nothrow @nogc
unittest
{
    import core.stdc.errno : EAGAIN;

    auto bad = ioErr!int(EAGAIN, OpKind.recv, IoErrorStage.submit, "sq full");
    assert(bad.hasError);
    assert(bad.error.kind == ErrorKind.wouldBlock);
    assert(bad.error.code == EAGAIN);
    assert(bad.error.op == OpKind.recv);
    assert(bad.error.stage == IoErrorStage.submit);
    assert(bad.error.context == "sq full");
}

/// The kind form still resolves to the shared constructor: an `ErrorKind`
/// argument is an exact match there, where here it would need a conversion.
@("errors.ioErr.kindFormStillShared")
@safe pure nothrow @nogc
unittest
{
    auto bad = ioErr!int(ErrorKind.notFound, OpKind.openAt, 2);
    assert(bad.error.kind == ErrorKind.notFound);
    assert(bad.error.code == 2);
}

@("errors.fromRes")
@safe pure nothrow @nogc
unittest
{
    import core.stdc.errno : ECONNRESET;

    auto count = fromRes(4096, OpKind.read);
    assert(count.hasValue && count.value == 4096);

    auto failed = fromRes(-ECONNRESET, OpKind.recv);
    assert(failed.hasError);
    assert(failed.error.kind == ErrorKind.connectionReset);
    assert(failed.error.code == ECONNRESET);
    assert(failed.error.stage == IoErrorStage.completion);
}

@("errors.ioError.unclassified")
@safe pure nothrow @nogc
unittest
{
    import core.stdc.errno : EIO;

    assert(ioError(EIO).kind == ErrorKind.other);
    assert(ioError(0, OpKind.none, IoErrorStage.setup).kind == ErrorKind.other);
}
