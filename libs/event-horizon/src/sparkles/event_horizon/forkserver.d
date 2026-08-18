/**
The fork + shared-memory server (SPEC §17): process-level isolation with
copy-on-write inheritance for work that mutates process-global state — the
DMD frontend's globals being the motivating client (dmd-fmt's formatter,
dmd-lsp's one-analysis-per-process limit, hue's live-types oracle).

The shape is a $(B zygote): a child forked while the host process is still
$(B single-threaded) (the one moment a D process may fork safely — druntime
installs no GC/malloc atfork handlers on the default GC, so a thread holding
a lock at fork time would deadlock the child forever). The zygote runs an
optional `childInit` once (e.g. `initDMD`) and then serves requests from a
`SOCK_SEQPACKET` socketpair, forking a $(B grandchild) per request. The
grandchild inherits everything the zygote initialized by CoW at zero cost,
runs the registered handler over a slot of the shared arena, and `_exit`s —
its heap, its globals and its crashes all die with it. The zygote is its own
only thread, so its forks are always safe.

The arena is one anonymous $(B shared) mapping (`MAP_SHARED | MAP_ANON`)
created before the fork, so parent, zygote and every grandchild see the same
pages with no name, no fd and no platform split: request bytes go in
zero-copy, result bytes come back zero-copy, and only the fixed-size frames
travel over the socket. Untouched slack pages cost nothing.

v1 is deliberately minimal: one registered handler (a `kind` tag demuxes),
fixed-size slots, and a zygote that serves $(B serially) — the client this
ships for (hue's format preview) is single-flight by design. Parallel
grandchild fan-out (per-process globals mean no lock) is recorded follow-up,
not built.
*/
module sparkles.event_horizon.forkserver;

version (Posix)  :  // fork/socketpair/mmap; Windows has no fork

import core.sys.posix.sys.mman : MAP_ANON, MAP_FAILED, MAP_SHARED, mmap,
    munmap, PROT_READ, PROT_WRITE;
import core.sys.posix.sys.socket : AF_UNIX, recv, send, SOCK_SEQPACKET,
    socketpair;
import core.sys.posix.sys.wait : waitpid, WEXITSTATUS, WIFEXITED, WIFSIGNALED,
    WTERMSIG;
import core.sys.posix.unistd : _exit, close, fork, pid_t;
import core.stdc.errno : EAGAIN, ECHILD, EINVAL, EMSGSIZE, ENOMEM, EPIPE,
    errno, EWOULDBLOCK;

import sparkles.event_horizon.errors : IoErrorStage, IoResult, ioErr, ioOk,
    OpKind;

/// The grandchild's work function: `input` and `output` are views into the
/// shared arena's slot ($(B never) retained past the call), `kind` demuxes
/// request types. Returns the bytes written into `output`, or `size_t.max`
/// when the result cannot fit (the grandchild exits with
/// $(LREF forkOverflowExit)). Runs in a forked child: keep it free of
/// threads, of stdio, and of anything that must outlive `_exit`.
alias ForkHandler = size_t function(
    scope const(ubyte)[] input, uint kind, scope ubyte[] output) @system;

/// Runs once in the $(B zygote) before it starts serving — the CoW hook
/// (e.g. `initDMD`): every grandchild inherits its effects for free.
alias ForkChildInit = void function() @system;

/// The grandchild's exit status when the handler reported overflow.
enum int forkOverflowExit = 101;

/// ditto — the handler threw.
enum int forkThrowExit = 102;

/// Sizing. Slots bound the outstanding requests the parent may hold
/// un-released; each slot carries `slotBytes` of input and `slotBytes` of
/// output space in the shared arena (virtual — untouched pages are free).
struct ForkServerConfig
{
    uint slots = 2;
    size_t slotBytes = 8 * 1024 * 1024;
    ForkChildInit childInit = null;
}

/// One completed request: `output` is a view into the arena slot — copy what
/// must outlive it, then $(LREF ForkServer.release) the slot. `status` is 0
/// on success, the grandchild's exit code on failure (see
/// $(LREF forkOverflowExit)), or `-signal` when it died to one (a crash is
/// one lost request, never a lost host).
struct ForkResponse
{
    uint tag;
    int status;
    uint slot;
    const(ubyte)[] output;

    bool ok() const @safe pure nothrow @nogc => status == 0;
}

private struct ReqFrame
{
    uint tag;
    uint kind;
    uint slot;
    ulong inLen;
}

private struct RespFrame
{
    uint tag;
    int status;
    uint slot;
    ulong outLen;
}

// Per-slot header in the arena: the grandchild publishes its output length
// here (shared pages), the zygote reads it after the wait.
private struct SlotHeader
{
    ulong outLen;
}

/**
The server. Non-copyable (the zygote holds the socket's other end).
`start` $(B must) run while the process is single-threaded; it refuses —
with an error, never an assert — otherwise, so callers can fall back to a
worker-thread backend when started late.
*/
struct ForkServer
{
    @disable this(this);

    private int ctrl = -1;       // parent's end of the socketpair
    private pid_t zygote = -1;
    private ubyte* arena = null;
    private size_t arenaBytes;
    private ForkServerConfig cfg;
    private bool[] slotBusy;
    private uint nextTag;
    private uint outstanding;

    /// `true` once `start` succeeded and `shutdown` has not run.
    bool running() const @safe pure nothrow @nogc => zygote > 0;

    /// Outstanding = submitted and not yet taken + taken and not released.
    uint inFlight() const @safe pure nothrow @nogc => outstanding;

    /// The fd completions arrive on — registerable with the loop's `pollAdd`
    /// so a response wakes an event-driven host.
    int completionFd() const @safe pure nothrow @nogc => ctrl;

    /**
    Forks the zygote. Single-threaded-parent is the load-bearing precondition
    (see the module doc); a multi-threaded caller gets `EINVAL` back and no
    child. `handler` and `cfg.childInit` are plain function pointers — the
    forked zygote shares the code, nothing is serialized.
    */
    static IoResult!void start(out ForkServer s, ForkHandler handler,
        ForkServerConfig cfg = ForkServerConfig()) @system
    {
        import core.thread : Thread;

        if (handler is null || cfg.slots == 0 || cfg.slotBytes == 0)
            return ioErr!void(EINVAL, OpKind.none, IoErrorStage.submit,
                "forkserver: bad configuration");
        if (Thread.getAll().length != 1)
            return ioErr!void(EINVAL, OpKind.none, IoErrorStage.submit,
                "forkserver: the process is already multi-threaded — fork is unsafe");

        s.cfg = cfg;
        s.arenaBytes = cfg.slots * slotSpan(cfg);
        auto mem = mmap(null, s.arenaBytes, PROT_READ | PROT_WRITE,
            MAP_SHARED | MAP_ANON, -1, 0);
        if (mem == MAP_FAILED)
            return ioErr!void(errno ? errno : ENOMEM, OpKind.none,
                IoErrorStage.submit, "forkserver: arena mmap failed");
        s.arena = cast(ubyte*) mem;

        int[2] fds;
        if (socketpair(AF_UNIX, SOCK_SEQPACKET, 0, fds) != 0)
        {
            s.teardownArena();
            return ioErr!void(errno, OpKind.none, IoErrorStage.submit,
                "forkserver: socketpair failed");
        }

        const pid = fork();
        if (pid < 0)
        {
            close(fds[0]);
            close(fds[1]);
            s.teardownArena();
            return ioErr!void(errno, OpKind.none, IoErrorStage.submit,
                "forkserver: fork failed");
        }
        if (pid == 0)
        {
            // The zygote. Its only thread is this one, so its own forks are
            // safe by construction. It never returns.
            close(fds[0]);
            zygoteServe(fds[1], s.arena, cfg, handler);
        }
        close(fds[1]);
        s.ctrl = fds[0];
        s.zygote = pid;
        s.slotBusy = new bool[](cfg.slots);
        return ioOk();
    }

    /// Queue `input` under `kind`. Returns the request's tag; `EAGAIN` when
    /// every slot is held, `EMSGSIZE` when `input` exceeds a slot.
    IoResult!uint submit(scope const(ubyte)[] input, uint kind = 0) @system
    {
        if (!running)
            return ioErr!uint(EPIPE, OpKind.send, IoErrorStage.submit,
                "forkserver: not running");
        if (input.length > cfg.slotBytes)
            return ioErr!uint(EMSGSIZE, OpKind.send, IoErrorStage.submit,
                "forkserver: input exceeds the slot size");
        uint slot = uint.max;
        foreach (i, busy; slotBusy)
            if (!busy)
            {
                slot = cast(uint) i;
                break;
            }
        if (slot == uint.max)
            return ioErr!uint(EAGAIN, OpKind.send, IoErrorStage.submit,
                "forkserver: every slot is in flight");

        inputArea(slot)[0 .. input.length] = input[];
        header(slot).outLen = 0;
        const tag = ++nextTag;
        const frame = ReqFrame(tag, kind, slot, input.length);
        if (!sendFrame(ctrl, &frame, frame.sizeof))
            return ioErr!uint(errno, OpKind.send, IoErrorStage.submit,
                "forkserver: request send failed");
        slotBusy[slot] = true;
        ++outstanding;
        return ioOk(cast(uint) tag);
    }

    /// Non-blocking: `true` with a completed response when one is waiting.
    bool tryTake(out ForkResponse r) @system
        => takeImpl(r, blocking: false);

    /// Blocking take — for synchronous callers and tests.
    IoResult!ForkResponse wait() @system
    {
        ForkResponse r;
        if (!takeImpl(r, blocking: true))
            return ioErr!ForkResponse(errno ? errno : EPIPE, OpKind.recv,
                IoErrorStage.completion, "forkserver: response recv failed");
        return ioOk(r);
    }

    /// Return `r`'s slot to the free pool (its `output` view dies here).
    void release(in ForkResponse r) @safe pure nothrow @nogc
    in (r.slot < slotBusy.length && slotBusy[r.slot], "release of a free slot")
    {
        slotBusy[r.slot] = false;
    }

    /// Stop the zygote (idempotent). Closing our socket end is the signal;
    /// the zygote's blocked `recv` returns 0 and it exits.
    void shutdown() @system
    {
        if (ctrl >= 0)
        {
            close(ctrl);
            ctrl = -1;
        }
        if (zygote > 0)
        {
            int st;
            waitpid(zygote, &st, 0);
            zygote = -1;
        }
        teardownArena();
        slotBusy = null;
        outstanding = 0;
    }

    ~this() @system
    {
        shutdown();
    }

    // ── plumbing ────────────────────────────────────────────────────────────

    private static size_t slotSpan(in ForkServerConfig cfg) @safe pure nothrow @nogc
        => SlotHeader.sizeof + 2 * cfg.slotBytes;

    private ref SlotHeader header(uint slot) @system
        => *cast(SlotHeader*)(arena + slot * slotSpan(cfg));

    private ubyte[] inputArea(uint slot) @system
        => (arena + slot * slotSpan(cfg) + SlotHeader.sizeof)[0 .. cfg.slotBytes];

    private ubyte[] outputArea(uint slot) @system
        => (arena + slot * slotSpan(cfg) + SlotHeader.sizeof
            + cfg.slotBytes)[0 .. cfg.slotBytes];

    private void teardownArena() @system
    {
        if (arena !is null)
        {
            munmap(arena, arenaBytes);
            arena = null;
        }
    }

    private bool takeImpl(out ForkResponse r, bool blocking) @system
    {
        if (ctrl < 0)
            return false;
        RespFrame frame;
        const flags = blocking ? 0 : msgDontWait;
        const n = recv(ctrl, &frame, frame.sizeof, flags);
        if (n != frame.sizeof)
            return false; // EAGAIN (nothing yet), 0 (zygote died), or error
        r = ForkResponse(frame.tag, frame.status, frame.slot,
            outputArea(frame.slot)[0 .. cast(size_t) frame.outLen]);
        --outstanding;
        return true;
    }

    version (linux)
        private enum int msgDontWait = 0x40; // MSG_DONTWAIT
    else
        private enum int msgDontWait = 0x80; // MSG_DONTWAIT (BSD/macOS)
}

// One send/recv helper pair: SEQPACKET keeps message boundaries, so a frame
// either travels whole or not at all.
private bool sendFrame(int fd, scope const(void)* buf, size_t len) @system
{
    version (linux)
        enum int noSigpipe = 0x4000; // MSG_NOSIGNAL
    else
        enum int noSigpipe = 0;
    return send(fd, buf, len, noSigpipe) == cast(ptrdiff_t) len;
}

/// The zygote's whole life. Never returns; never touches druntime teardown
/// (`_exit`). Serial by design (v1): read → fork → wait → respond.
private void zygoteServe(int fd, ubyte* arena, in ForkServerConfig cfg,
    ForkHandler handler) @system
{
    if (cfg.childInit !is null)
        cfg.childInit();

    const span = SlotHeader.sizeof + 2 * cfg.slotBytes;
    for (;;)
    {
        ReqFrame req;
        const n = recv(fd, &req, req.sizeof, 0);
        if (n != req.sizeof)
            _exit(0); // the parent closed its end (or a torn frame): done

        auto head = cast(SlotHeader*)(arena + req.slot * span);
        auto inp = (arena + req.slot * span + SlotHeader.sizeof)
            [0 .. cast(size_t) req.inLen];
        auto outp = (arena + req.slot * span + SlotHeader.sizeof
            + cfg.slotBytes)[0 .. cfg.slotBytes];

        const pid = fork();
        if (pid == 0)
        {
            // The grandchild: private CoW heap, inherited init, crash-isolated.
            size_t wrote;
            try
                wrote = handler(inp, req.kind, outp);
            catch (Throwable)
                _exit(forkThrowExit);
            if (wrote == size_t.max)
                _exit(forkOverflowExit);
            head.outLen = wrote; // shared pages: visible to the zygote/parent
            _exit(0);
        }

        RespFrame resp = {tag: req.tag, slot: req.slot};
        if (pid < 0)
        {
            resp.status = -errno;
        }
        else
        {
            int st;
            waitpid(pid, &st, 0);
            resp.status = WIFSIGNALED(st) ? -cast(int) WTERMSIG(st)
                : WIFEXITED(st) ? WEXITSTATUS(st) : -EINVAL;
            resp.outLen = resp.status == 0 ? head.outLen : 0;
        }
        if (!sendFrame(fd, &resp, resp.sizeof))
            _exit(0);
    }
}

// ── tests ───────────────────────────────────────────────────────────────────
// The real fork path needs a single-threaded process: run these with
//     dub test :event-horizon -- -t 1 -i forkserver
// (with worker threads alive they skip — an early return would count a
// degraded environment as a pass).

version (unittest)
{
    // Handlers must be top-level functions: the zygote runs the pointer.
    private size_t echoHandler(scope const(ubyte)[] input, uint kind,
        scope ubyte[] output) @system
    {
        if (kind == 2)
            *(cast(int*) 8) = 1; // deliberate crash: SIGSEGV
        if (kind == 3)
            return size_t.max;   // deliberate overflow report
        output[0 .. input.length] = input[];
        return input.length;
    }

    private bool singleThreadedOrSkip() @system
    {
        import core.thread : Thread;

        import sparkles.test_runner.skip : skipTest;

        if (Thread.getAll().length == 1)
            return true;
        skipTest("needs a single-threaded process (run with -t 1)");
        assert(0);
    }
}

@("forkserver.echoRoundTrip")
@system unittest
{
    singleThreadedOrSkip();

    ForkServer s;
    auto r = ForkServer.start(s, &echoHandler,
        ForkServerConfig(slots: 2, slotBytes: 4096));
    assert(!r.hasError, "start failed");
    scope (exit)
        s.shutdown();
    assert(s.running);

    const tag = s.submit(cast(const(ubyte)[]) "hello, zygote");
    assert(!tag.hasError);
    auto resp = s.wait();
    assert(!resp.hasError);
    assert(resp.value.ok);
    assert(resp.value.tag == tag.value);
    assert(cast(const(char)[]) resp.value.output == "hello, zygote");
    s.release(resp.value);

    // Serial queueing: two submits complete in order on distinct slots.
    const t1 = s.submit(cast(const(ubyte)[]) "one");
    const t2 = s.submit(cast(const(ubyte)[]) "two");
    assert(!t1.hasError && !t2.hasError);
    auto r1 = s.wait();
    auto r2 = s.wait();
    assert(!r1.hasError && !r2.hasError);
    assert(r1.value.tag == t1.value && r2.value.tag == t2.value);
    assert(cast(const(char)[]) r1.value.output == "one");
    assert(cast(const(char)[]) r2.value.output == "two");
    assert(r1.value.slot != r2.value.slot, "distinct in-flight slots");
    s.release(r1.value);
    s.release(r2.value);
}

@("forkserver.crashIsOneLostRequestNotTheHost")
@system unittest
{
    import core.sys.posix.signal : SIGSEGV;

    singleThreadedOrSkip();

    ForkServer s;
    assert(!ForkServer.start(s, &echoHandler,
        ForkServerConfig(slots: 1, slotBytes: 4096)).hasError);
    scope (exit)
        s.shutdown();

    // kind 2 → the grandchild SIGSEGVs; the response reports −signal and the
    // server keeps serving.
    assert(!s.submit(cast(const(ubyte)[]) "boom", kind: 2).hasError);
    auto crash = s.wait();
    assert(!crash.hasError);
    assert(crash.value.status == -SIGSEGV);
    assert(crash.value.output.length == 0);
    s.release(crash.value);

    // kind 3 → the handler reports overflow via the documented exit code.
    assert(!s.submit(cast(const(ubyte)[]) "big", kind: 3).hasError);
    auto over = s.wait();
    assert(!over.hasError);
    assert(over.value.status == forkOverflowExit);
    s.release(over.value);

    // …and a normal request still round-trips after both failures.
    assert(!s.submit(cast(const(ubyte)[]) "alive").hasError);
    auto fine = s.wait();
    assert(!fine.hasError && fine.value.ok);
    assert(cast(const(char)[]) fine.value.output == "alive");
    s.release(fine.value);
}

@("forkserver.slotBackpressureAndSizeGuard")
@system unittest
{
    import core.stdc.errno : EAGAIN, EMSGSIZE;

    singleThreadedOrSkip();

    ForkServer s;
    assert(!ForkServer.start(s, &echoHandler,
        ForkServerConfig(slots: 1, slotBytes: 64)).hasError);
    scope (exit)
        s.shutdown();

    // Over the slot size refuses up front.
    ubyte[65] big;
    auto tooBig = s.submit(big[]);
    assert(tooBig.hasError && tooBig.error.errnoValue == EMSGSIZE);

    // One slot: the second submit refuses with EAGAIN until a release.
    assert(!s.submit(cast(const(ubyte)[]) "a").hasError);
    auto refused = s.submit(cast(const(ubyte)[]) "b");
    assert(refused.hasError && refused.error.errnoValue == EAGAIN);
    auto done = s.wait();
    assert(!done.hasError);
    s.release(done.value);
    assert(!s.submit(cast(const(ubyte)[]) "b").hasError);
    auto second = s.wait();
    assert(!second.hasError && second.value.ok);
    s.release(second.value);
}

@("forkserver.tryTakeIsNonBlockingAndFdIsExposed")
@system unittest
{
    import core.thread : Thread;
    import core.time : msecs;

    singleThreadedOrSkip();

    ForkServer s;
    assert(!ForkServer.start(s, &echoHandler,
        ForkServerConfig(slots: 1, slotBytes: 4096)).hasError);
    scope (exit)
        s.shutdown();

    assert(s.completionFd() >= 0, "the pollAdd target exists");
    ForkResponse r;
    assert(!s.tryTake(r), "nothing completed yet");
    assert(!s.submit(cast(const(ubyte)[]) "ping").hasError);
    bool got;
    foreach (_; 0 .. 2000)
    {
        if (s.tryTake(r))
        {
            got = true;
            break;
        }
        Thread.sleep(1.msecs);
    }
    assert(got && r.ok);
    assert(cast(const(char)[]) r.output == "ping");
    s.release(r);
}
