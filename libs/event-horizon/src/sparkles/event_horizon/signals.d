/**
Async signal handling (PLAN M7): a `signalfd` driven through the ring —
signals become ordinary completions on the one wait point instead of
async-unsafe handler interruptions.

Loop-side module (the capability concept + test double join `live`/`Env` in
M9).
*/
module sparkles.event_horizon.signals;

version (linux)  :  // signalfd is Linux; kqueue maps EVFILT_SIGNAL (M10)

import core.sys.linux.sys.signalfd;
import core.sys.posix.signal : SIG_BLOCK, sigaddset, sigemptyset, sigprocmask, sigset_t;

import sparkles.event_horizon.buffer : Buf;
import sparkles.event_horizon.errors;
import sparkles.event_horizon.op;
import sparkles.event_horizon.sched : Sched;

/// A signalfd bound to a blocked signal set.
struct SignalFd
{
    @disable this(this);

    /// Blocks `signals` process-wide and opens a signalfd for them (the
    /// standard signalfd discipline: blocked-then-read).
    static IoResult!void create(out SignalFd s, scope const int[] signals)
        @trusted nothrow @nogc
    {
        sigset_t set = void;
        sigemptyset(&set);
        foreach (sig; signals)
            sigaddset(&set, sig);
        if (sigprocmask(SIG_BLOCK, &set, null) != 0)
            return ioErr!void(22 /* EINVAL */, OpKind.none, IoErrorStage.setup,
                "sigprocmask failed");
        const fd = signalfd(-1, &set, SFD_CLOEXEC);
        if (fd < 0)
            return ioErr!void(24 /* EMFILE */, OpKind.none, IoErrorStage.setup,
                "signalfd failed");
        s._fd = fd;
        return ioOk();
    }

    /// Parks until one of the bound signals arrives; its number.
    IoResult!int nextSignal(ref Sched sched) @trusted
    {
        import core.lifetime : move;

        // The siginfo record lives on this parked frame (§6.5).
        ubyte[signalfd_siginfo.sizeof] raw = void;
        auto foreign = Buf.fromForeign(raw[], null);
        foreign.length = foreign.capacity;
        auto o = sched.await(OpRead(_fd, move(foreign), ulong.max));
        if (o.res < 0)
            return ioErr!int(-o.res, OpKind.read);
        if (o.res != signalfd_siginfo.sizeof)
            return ioErr!int(74 /* EBADMSG */, OpKind.read,
                IoErrorStage.completion, "short signalfd read");
        const info = cast(const(signalfd_siginfo)*) raw.ptr;
        return ioOk(cast(int) info.ssi_signo);
    }

    /// Closes the descriptor (the signal mask stays blocked).
    void close() @trusted nothrow @nogc
    {
        import core.sys.posix.unistd : close_ = close;

        if (_fd >= 0)
            close_(_fd);
        _fd = -1;
    }

    ~this() @safe nothrow @nogc
    {
        close();
    }

private:
    int _fd = -1;
}

@("signals.signalfd.throughRing")
@safe
unittest
{
    import core.sys.posix.signal : SIGUSR1, raise;

    Sched s;
    if (Sched.create(s).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) s.destroy();

    SignalFd sig;
    if (SignalFd.create(sig, [SIGUSR1]).hasError)
        return; // SKIP: sandboxed
    scope (exit) sig.close();

    int seen;
    auto r = s.run(() {
        cast(void) s.spawn(() @trusted {
            raise(SIGUSR1); // queued: SIGUSR1 is blocked process-wide
        });
        auto got = sig.nextSignal(s);
        assert(got.hasValue);
        seen = got.value;
    });
    assert(!r.hasError);
    assert(seen == SIGUSR1);
}
