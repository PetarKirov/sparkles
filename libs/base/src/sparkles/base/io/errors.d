/**
The I/O error vocabulary every Sparkles I/O path shares.

A failure is an $(LREF IoError) carried by $(LREF IoResult). Its
$(LREF ErrorKind) is the portable classification callers match on, computed
once by whoever turned the native result into a value; `code` keeps the raw
`errno` or `NTSTATUS` for diagnostics only. The capability VFS
(`docs/specs/base/vfs/SPEC.md`, VFE1–VFE4) defines the file-system kinds;
`sparkles:event-horizon` re-exports this module and defines the network and
process kinds.

The module is a leaf: it imports only `expected` and the shared
$(REF NoGcHook, sparkles,base,text,errors).
*/
module sparkles.base.io.errors;

import std.traits : Unqual;

import expected : Expected, err, ok;

public import sparkles.base.text.errors : NoGcHook;

/// The portable classification of a failure.
enum ErrorKind : ubyte
{
    other,              /// anything unclassified; `code` carries the detail
    notFound,           /// the named entry does not exist
    exists,             /// a create found an entry already there
    notADirectory,      /// a directory was required and the entry is not one
    isADirectory,       /// a non-directory was required and the entry is a directory
    notEmpty,           /// a directory removal found entries
    permission,         /// the operating system denied access
    busy,               /// the entry is in use in a way that blocks the operation
    invalidName,        /// a name or link target failed validation
    escapesRoot,        /// the operation would leave the root
    dotDotRefused,      /// a `..` component under the `reject` policy
    symlinkRefused,     /// a symbolic link where the policy forbids one
    symlinkLoop,        /// more links followed than the symlink hop limit allows
    crossesMount,       /// a step entered a different file system
    nameTooLong,        /// a name or path exceeds its length limit
    bufferTooSmall,     /// a caller-supplied buffer cannot hold the result
    depthExceeded,      /// a walk or removal exceeded its depth limit
    raceRetryExhausted, /// the kernel reported a race on every retry
    unsupported,        /// the backend or platform cannot provide what was asked
}

/**
The operation that failed. Operands live with the operation; this names only
its kind, so $(LREF IoError) can say what failed while this module stays a
leaf.
*/
enum OpKind : ubyte
{
    none,            /// no operation (a loop- or library-level failure)
    nop,             /// no-op round-trip
    read,            /// read from a file or descriptor
    write,           /// write to a file or descriptor
    recv,            /// socket receive (caller-supplied buffer)
    recvSelect,      /// receive with kernel buffer selection
    send,            /// socket send
    sendTo,          /// datagram send to an address
    recvFrom,        /// datagram receive with source address
    accept,          /// accept one connection
    acceptMultishot, /// armed accept stream
    connect,         /// outbound connect
    shutdown,        /// socket shutdown
    openAt,          /// open one entry relative to a directory
    mkdirAt,         /// create a directory relative to a directory
    statAt,          /// stat one entry relative to a directory, or an open file
    readlinkAt,      /// read a symbolic link's target
    symlinkAt,       /// create a symbolic link
    unlinkAt,        /// remove a non-directory entry
    rmdirAt,         /// remove an empty directory
    renameAt,        /// rename an entry
    readDir,         /// list a directory
    resolve,         /// resolve a whole path in one call
    close,           /// close a handle
    fsync,           /// flush a file to stable storage
    timeout,         /// timer
    linkTimeout,     /// per-op deadline linked to the previous op
    cancel,          /// cancellation of another op
    futexWait,       /// in-ring futex wait
    futexWake,       /// in-ring futex wake
    msgRing,         /// cross-ring message
    waitid,          /// child-process reap
    pollAdd,         /// foreign-descriptor readiness
}

/// Which stage of an operation's life produced the failure.
enum IoErrorStage : ubyte
{
    setup,        /// creating a ring, backend or root
    probe,        /// capability probing
    registration, /// registering buffers, files or a buffer ring
    submit,       /// submission time
    completion,   /// the operation itself failed (the common case)
    cancel,       /// a cancellation round-trip failed
}

/// A structured I/O failure.
struct IoError
{
    ErrorKind kind;                               /// what callers match on
    int code;                                     /// raw errno or NTSTATUS; 0 = not an OS error
    OpKind op = OpKind.none;                      /// the operation that failed
    IoErrorStage stage = IoErrorStage.completion; /// where in its life
    string context = null;                        /// borrowed detail (a CTFE literal)
}

/// The result of every I/O operation.
alias IoResult(T) = Expected!(T, IoError, NoGcHook);

/// Constructs a successful $(LREF IoResult) carrying `value`. Attributes
/// infer and the payload is forwarded, so a move-only payload is neither
/// rejected nor copied.
IoResult!(Unqual!T) ioOk(T)(auto ref T value)
{
    import core.lifetime : forward;

    static if (is(Unqual!T == T))
        return ok!(IoError, NoGcHook)(forward!value);
    else
    {
        Unqual!T copy = value; // a const scalar or struct without indirections
        return ok!(IoError, NoGcHook)(copy);
    }
}

/// ditto: success with no payload.
IoResult!void ioOk() @safe pure nothrow @nogc
    => ok!(IoError, NoGcHook)();

/// Constructs a failed $(LREF IoResult)`!T` carrying `error`.
IoResult!T ioErr(T)(IoError error)
    => err!(T, NoGcHook)(error);

/// ditto: the common form, `return ioErr!Dir(ErrorKind.notFound, OpKind.openAt);`
IoResult!T ioErr(T)(ErrorKind kind, OpKind op, int code = 0,
    IoErrorStage stage = IoErrorStage.completion, string context = null)
    => err!(T, NoGcHook)(IoError(kind, code, op, stage, context));

/// ditto: re-types the failure of another result.
IoResult!T ioErr(T, R)(auto ref R failed)
if (is(typeof(failed.error) : const IoError))
{
    IoError copy = failed.error;
    return err!(T, NoGcHook)(copy);
}

@("io.errors.ioOk")
@safe pure nothrow @nogc
unittest
{
    auto r = ioOk(42);
    static assert(is(typeof(r) == IoResult!int));
    assert(!r.hasError && r.value == 42);
    assert(!ioOk().hasError);
}

@("io.errors.ioErr")
@safe pure nothrow @nogc
unittest
{
    auto r = ioErr!int(ErrorKind.notFound, OpKind.openAt, 2);
    assert(r.hasError);
    assert(r.error.kind == ErrorKind.notFound);
    assert(r.error.code == 2);
    assert(r.error.op == OpKind.openAt);
    assert(r.error.stage == IoErrorStage.completion);

    auto retyped = ioErr!(char[])(r);
    assert(retyped.error == r.error);
}

@("io.errors.moveOnlyPayload")
@safe pure nothrow @nogc
unittest
{
    import core.lifetime : move;

    static struct Owner
    {
        int fd;
        @disable this(this);
    }

    auto r = ioOk(Owner(3));
    Owner o = move(r.value);
    assert(o.fd == 3);
}

@("io.errors.composition")
@safe unittest
{
    import expected : andThen, map;

    auto doubled = ioOk(21).map!(x => x * 2, NoGcHook);
    static assert(is(typeof(doubled) == IoResult!int));
    assert(doubled.value == 42);
    auto failed = ioErr!int(ErrorKind.busy, OpKind.read).andThen!((int x) => ioOk());
    assert(failed.hasError && failed.error.kind == ErrorKind.busy);
}
