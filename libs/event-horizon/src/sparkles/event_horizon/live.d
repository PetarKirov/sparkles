/**
Live (ring-backed) capability implementations (SPEC §10.3, §11): the
production `RingClock`/`RingNet` that `LoopGroup` hands to the root fiber as
the `Env` row. They mirror the effects-side test doubles (`TestClock`,
`SimNet`) exactly — any function generic over its `Ctx` runs unmodified
against either.

Loop-side module: these capabilities close over the scheduler and issue real
ring ops, so they cannot live effects-side.
*/
module sparkles.event_horizon.live;

version (linux)  :  // rides the linux Sched; generalizes with M10

import core.time : Duration, MonoTime;

import sparkles.event_horizon.capability : CtxOf;
import sparkles.event_horizon.errors : IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.io : Listener, Stream, accept, connect;
import sparkles.event_horizon.net : SockAddr;
import sparkles.event_horizon.sched : Sched;

/// The live clock capability: monotonic time and an in-ring timer sleep.
struct RingClock
{
    enum string capName = "clock";

    private Sched* _sched;

    /// Binds to the scheduler whose ring backs the timer.
    this(Sched* sched) @safe pure nothrow @nogc
    {
        _sched = sched;
    }

    /// The current monotonic time.
    MonoTime now() const @safe nothrow @nogc => MonoTime.currTime;

    /// Parks the calling fiber for `d` on an in-ring `TIMEOUT`.
    IoResult!void sleep(Duration d)
    {
        import sparkles.event_horizon.io : sleep_ = sleep;

        return sleep_(*_sched, d);
    }
}

/// The live net capability: sockets, listeners, and connections over the
/// ring. `Stream`/`Listener` are the tier-B `io` handles, so the direct
/// verbs (`recv`/`send`/`accept`) apply by UFCS.
struct RingNet
{
    enum string capName = "net";

    /// The connected-stream handle type (SPEC §10.3 `isNet`).
    alias Stream = .Stream;

    /// The listening-socket handle type.
    alias Listener = .Listener;

    private Sched* _sched;

    /// Binds to the scheduler whose ring backs the socket ops.
    this(Sched* sched) @safe pure nothrow @nogc
    {
        _sched = sched;
    }

    /// Creates a TCP socket, binds it to `at`, and listens.
    IoResult!Listener listen(SockAddr at, int backlog = 128) @trusted nothrow
    {
        import core.sys.posix.netinet.in_ : sockaddr;
        import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, SOL_SOCKET,
            SO_REUSEADDR, bind, listen_ = listen, setsockopt, socket;

        const fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0)
            return ioErr!Listener(errnoNow, OpKind.none, IoErrorStage.setup,
                "socket() failed");
        int one = 1;
        cast(void) setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, one.sizeof);
        if (bind(fd, cast(sockaddr*) at.storage.ptr, at.len) != 0
            || listen_(fd, backlog) != 0)
        {
            closeFd(fd);
            return ioErr!Listener(errnoNow, OpKind.none, IoErrorStage.setup,
                "bind/listen failed");
        }
        return ioOk(Listener(fd));
    }

    /// Creates a TCP socket and connects it to `to` (parks on the ring).
    IoResult!Stream connect(SockAddr to)
    {
        import core.sys.posix.sys.socket : AF_INET, SOCK_STREAM, socket;

        const fd = (() @trusted => socket(AF_INET, SOCK_STREAM, 0))();
        if (fd < 0)
            return ioErr!Stream(errnoNow, OpKind.none, IoErrorStage.setup,
                "socket() failed");
        auto s = Stream(fd);
        auto r = .connect(s, to);
        if (r.hasError)
        {
            s.close();
            return ioErr!Stream(r.error);
        }
        return ioOk(s);
    }

    private static int errnoNow() @trusted nothrow @nogc
    {
        import core.stdc.errno : errno;

        return errno;
    }

    private static void closeFd(int fd) @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : close;

        close(fd);
    }
}

/// The default live capability row handed to the root fiber (SPEC §11);
/// grows with the M7 domains (`RingFs`, `RingProc`, …) as they gain
/// capability wrappers.
alias Env = CtxOf!(RingClock, RingNet);

version (unittest)
{
    import sparkles.event_horizon.capability : hasCaps;
    import sparkles.event_horizon.clock : isClock;
    import sparkles.event_horizon.net : isNet;

    static assert(isClock!RingClock);
    static assert(isNet!RingNet);
    static assert(hasCaps!(Env, "clock", "net"));
}
