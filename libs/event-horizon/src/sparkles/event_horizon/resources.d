/// Lexical socket ownership over the existing copyable handle views.
module sparkles.event_horizon.resources;

version (linux):

import core.stdc.errno : errno;
import core.sys.posix.unistd : close;
import core.lifetime : move;
import std.traits : ReturnType, TemplateArgsOf;
import expected : Expected;
import sparkles.event_horizon.errors : IoResult, IoError, NoGcHook, OpKind, ioErr;
import sparkles.event_horizon.io : Stream, Listener, DgramSocket;

/**
Consumes an acquisition result and lends the socket to a synchronous/fiber body.
The body returns `IoResult!T` and must finish or join every user before returning;
it must not close the handle or retain a copy. This is a lexical owner, not a
replacement for a structured scope. No scope cleanup-registration slot is used.

Body failure wins over close failure; close failure is reported after success.
Escaped exceptions/defects close through the existing synchronous fallback.
Close is not retried (Linux releases the fd even on EINTR). No destructor parks.
This checked-close contract is Linux-specific; raw handle APIs remain portable.
*/
auto withSocket(H, F)(Expected!(H, IoError, NoGcHook) opened, scope F body)
if (is(H == Stream) || is(H == Listener) || is(H == DgramSocket))
{
    alias R = ReturnType!F;
    alias T = TemplateArgsOf!R[0];
    static assert(is(R == IoResult!T), "withSocket body must return IoResult!T");
    if (opened.hasError)
        return ioErr!T(opened.error);
    auto handle = opened.value;
    scope(exit) handle.close();
    auto result = () {
        try return body(handle);
        catch (Throwable error)
        {
            handle.close();
            throw error;
        }
    }();
    const rc = (() @trusted => close(handle.fd))();
    const error = errno;
    handle.fd = -1;
    if (!result.hasError && rc < 0)
        return ioErr!T(error, OpKind.close);
    return move(result);
}

@("resources.withSocket.closesAndPropagates") @system unittest
{
    import core.sys.posix.sys.socket : socketpair, AF_UNIX, SOCK_STREAM;
    import core.sys.posix.fcntl : fcntl, F_GETFD;
    import core.stdc.errno : EIO;
    import sparkles.event_horizon.errors : ioOk;

    int[2] fds;
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0);
    auto peer = Stream(fds[1]);
    scope(exit) peer.close();
    auto result = withSocket(ioOk(Stream(fds[0])), (ref Stream stream) {
        assert(stream.fd == fds[0]);
        return ioErr!int(EIO, OpKind.recv);
    });
    assert(result.error.errnoValue == EIO);
    assert(fcntl(fds[0], F_GETFD) == -1);
    bool called;
    auto rejected = withSocket(ioErr!Stream(EIO, OpKind.connect), (ref Stream stream) {
        called = true;
        return ioOk();
    });
    assert(rejected.hasError && !called);
}
