/** Complete-transfer conveniences over the direct-style completion API.

The caller's owned buffer stays in this fiber's frame until every submitted
operation is terminal. These helpers do not change the single-transfer verbs.
*/
module sparkles.event_horizon.transfer;

version (Posix) version = EhTransfer;
version (Windows) version = EhTransfer;
version (EhTransfer):

import core.lifetime : move;
import core.stdc.errno : EIO, EOVERFLOW, EFBIG;
import sparkles.base.buffer : UniqueBuffer, HeapBuffer;
import sparkles.event_horizon.buffer : Buf, isOwnedIoBuf;
import sparkles.event_horizon.errors : IoResult, IoErrorStage, OpKind, ioErr, ioOk;
import sparkles.event_horizon.io : FileHandle, Stream, read, recv;
import sparkles.event_horizon.sched : currentScheduler;
import sparkles.event_horizon.op : OpRead, OpWrite, OpRecv, OpSend;

/// Ownership and completed prefix are returned even on failure. `res` describes
/// completion of the whole request, not only the last system call.
struct TransferResult(B)
{
    B buf;
    size_t transferred;
    IoResult!void res;
}

/// Sends all valid bytes (`buf[]`). A zero-progress send is EIO.
///
/// The buffer conveniences below require exclusive access for the duration of
/// the call, just like the moved-buffer primitives.
TransferResult!B sendAll(B)(ref Stream stream, B buf) if (isOwnedIoBuf!B)
    => complete!OpSend(stream.fd, move(buf));

/// Writes all valid bytes. `ulong.max` uses the current file position.
TransferResult!B writeAll(B)(FileHandle file, B buf, ulong offset = ulong.max)
if (isOwnedIoBuf!B)
    => complete!OpWrite(file.fd, move(buf), offset);

/// Fills the valid-length window (`buf[]`), not spare capacity. Set the buffer
/// length to the requested frame size first. Premature EOF is EIO; the completed
/// prefix remains available through `transferred` on failure.
TransferResult!B readExactly(B)(ref Stream stream, B buf) if (isOwnedIoBuf!B)
    => complete!OpRecv(stream.fd, move(buf));

/// ditto, for a file.
TransferResult!B readExactly(B)(FileHandle file, B buf, ulong offset = ulong.max)
if (isOwnedIoBuf!B)
    => complete!OpRead(file.fd, move(buf), offset);

/// Single-transfer in-place adapter. Temporarily moves the owner into `recv`
/// and restores it after terminal completion, on success or ordinary failure.
/// The caller must not access the buffer concurrently from another fiber.
IoResult!uint recvInto(B)(ref Stream stream, ref B buf) if (isOwnedIoBuf!B)
{
    auto result = recv(stream, move(buf));
    buf = move(result.buf);
    return result.res;
}

/// ditto, for file reads (same spare-capacity semantics as `read`).
IoResult!uint readInto(B)(FileHandle file, ref B buf, ulong offset = ulong.max)
if (isOwnedIoBuf!B)
{
    auto result = read(file, move(buf), offset);
    buf = move(result.buf);
    return result.res;
}

private TransferResult!B complete(Op, B)(int fd, B buf, ulong offset = ulong.max)
{
    auto bytes = buf[];
    size_t total;
    // Validate the entire positioned range before any side effect. The sentinel
    // is not a usable positioned offset.
    if (offset != ulong.max && bytes.length > ulong.max - offset)
        return TransferResult!B(move(buf), 0,
            ioErr!void(EOVERFLOW, Op.kind, IoErrorStage.submit, "offset overflow"));
    while (total < bytes.length)
    {
        const count = bytes.length - total > int.max ? int.max : bytes.length - total;
        auto view = (() @trusted => Buf.fromForeign(bytes[total .. total + count], null))();
        view.length = cast(uint) count;
        static if (is(Op == OpRead) || is(Op == OpWrite))
            auto done = currentScheduler().await(Op(fd, move(view),
                offset == ulong.max ? offset : offset + total));
        else
            auto done = currentScheduler().await(Op(fd, move(view)));
        if (done.res < 0)
            return TransferResult!B(move(buf), total, ioErr!void(-done.res, Op.kind));
        if (done.res == 0)
            return TransferResult!B(move(buf), total,
                ioErr!void(EIO, Op.kind, IoErrorStage.completion,
                    "incomplete transfer: EOF or zero progress"));
        total += done.res;
    }
    return TransferResult!B(move(buf), total, ioOk());
}

/// Reads through EOF with an explicit byte limit. Allocates owned storage, not
/// GC storage. On error the accumulated prefix is discarded. At the limit one
/// additional byte is consumed to distinguish exact-size EOF from EFBIG.
/// File reads use and advance the current file position.
IoResult!(HeapBuffer!ubyte) readToEnd(H)(ref H handle, size_t maxBytes)
if (is(H == FileHandle) || is(H == Stream))
{
    alias Bytes = HeapBuffer!ubyte;
    Bytes result;
    UniqueBuffer!(ubyte, 4096) chunk;
    for (;;)
    {
        const remaining = maxBytes - result.length;
        chunk.length = remaining >= 4096 ? 4096 : remaining + 1;
        // The primitive's generic owned-buffer read uses spare capacity. Give
        // it an explicitly bounded foreign window instead, kept alive here
        // until terminal completion, so the limit probe consumes only one byte.
        auto window = (() @trusted => Buf.fromForeign(chunk[], null))();
        window.length = cast(uint) chunk.length;
        static if (is(H == FileHandle))
            auto got = read(handle, move(window));
        else
            auto got = recv(handle, move(window));
        if (got.res.hasError)
            return ioErr!Bytes(got.res.error);
        const n = got.res.value;
        if (n == 0)
            return ioOk(move(result));
        if (n > remaining)
            return ioErr!Bytes(EFBIG, is(H == FileHandle) ? OpKind.read : OpKind.recv);
        result ~= chunk[][0 .. n];
    }
}

/// GC-allocating byte-preserving text convenience. No Unicode validation or
/// normalization is performed; use a decoder when input validity matters.
IoResult!string readText(H)(ref H handle, size_t maxBytes)
if (is(H == FileHandle) || is(H == Stream))
{
    auto bytes = readToEnd(handle, maxBytes);
    if (bytes.hasError)
        return ioErr!string(bytes.error);
    return ioOk((cast(const(char)[]) bytes.value[]).idup);
}

version (Posix)
@("transfer.completeAndShortEof") @system unittest
{
    import core.sys.posix.unistd : pipe;
    import sparkles.event_horizon.sched : Sched, schedOrSkip;

    Sched sched;
    schedOrSkip(sched);
    scope(exit) sched.destroy();
    int[2] fds;
    assert(pipe(fds) == 0);
    auto input = FileHandle(fds[0]);
    auto output = FileHandle(fds[1]);
    scope(exit) input.close();
    scope(exit) output.close();
    auto ran = sched.run(() {
        UniqueBuffer!(ubyte, 8) invalid;
        invalid ~= cast(ubyte) 42;
        auto rejected = readInto(FileHandle(-1), invalid);
        assert(rejected.hasError && invalid.length == 1 && invalid[0] == 42);
        assert(sched.spawn(() {
            UniqueBuffer!(ubyte, 8) bytes;
            bytes ~= cast(const(ubyte)[]) "hello";
            auto sent = writeAll(output, move(bytes));
            assert(!sent.res.hasError && sent.transferred == 5);
            output.close();
        }));
        UniqueBuffer!(ubyte, 8) bytes;
        bytes.length = 8;
        auto got = readExactly(input, move(bytes));
        assert(got.res.hasError && got.res.error.errnoValue == EIO);
        assert(got.transferred == 5 && got.buf[][0 .. 5] == cast(const(ubyte)[]) "hello");
    });
    assert(!ran.hasError);
}

@("transfer.emptyAndOverflowDoNotSubmit") @system unittest
{
    UniqueBuffer!(ubyte, 8) bytes;
    auto empty = writeAll(FileHandle(-1), move(bytes));
    assert(!empty.res.hasError && empty.transferred == 0);
    bytes = move(empty.buf);
    bytes.length = 8;
    auto overflow = writeAll(FileHandle(-1), move(bytes), ulong.max - 4);
    assert(overflow.res.error.errnoValue == EOVERFLOW);
    assert(overflow.transferred == 0 && overflow.buf.length == 8);
}

version (Posix)
@("transfer.deadlineRestoresOwnership") @system unittest
{
    import core.time : msecs;
    import core.stdc.errno : ECANCELED;
    import core.sys.posix.unistd : pipe;
    import sparkles.event_horizon.sched : Sched, schedOrSkip;
    import sparkles.event_horizon.scope_ : withDeadline;

    Sched sched;
    schedOrSkip(sched);
    scope(exit) sched.destroy();
    int[2] fds;
    assert(pipe(fds) == 0);
    auto input = FileHandle(fds[0]);
    auto output = FileHandle(fds[1]);
    scope(exit) input.close();
    scope(exit) output.close();
    auto ran = sched.run(() {
        auto timed = withDeadline!((ref sc) {
            UniqueBuffer!(ubyte, 8) bytes;
            bytes.length = 8;
            auto got = readExactly(input, move(bytes));
            assert(got.res.hasError && got.res.error.errnoValue == ECANCELED);
            assert(got.transferred == 0 && got.buf.length == 8);
        })(sched, 1.msecs);
        assert(timed.error.isTimeout);
    });
    assert(!ran.hasError);
}
