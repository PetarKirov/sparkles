/**
Loop-group topology configuration and lifecycle (SPEC §11): `LoopGroup`
owns the per-worker schedulers and hands the root fiber the root `Scope` and
the live capability row `Env` — all authority originates here (the Eio
`Eio_main.run env` shape).

M9 ships the `single` topology (one loop on the calling thread); the
`threadPerCore` and `workStealing` topologies follow.
*/
module sparkles.event_horizon.group;

version (Posix)  :  // rides Sched; CPU pinning is linux-guarded internally

import core.lifetime : move;
import core.time : Duration, seconds;

import std.experimental.allocator.mallocator : Mallocator;
import std.typecons : Flag, No, Yes;

import sparkles.event_horizon.cause : Cause, Interrupt, InterruptKind, Outcome,
    outcomeErr, outcomeOk;
import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.event_horizon.live : Env, RingClock, RingNet;
import sparkles.event_horizon.sched : Sched, SchedOptions;
import sparkles.event_horizon.scope_ : Scope, ScopeOptions, withScope;
import sparkles.event_horizon.loop : LoopConfig;

/// The blessed live scope instantiation handed to the root fiber (SPEC §7.2,
/// §11): a `Scope` over the ring-backed `Sched` executor with the `IoError`
/// channel.
alias RootScope = Scope!(Sched, IoError);

/// Scheduler topology (SPEC §11).
enum Topology : ubyte
{
    single,        /// one loop on the calling thread; zero cross-thread machinery
    threadPerCore, /// N pinned workers, one exclusive-mode ring each (M9b)
    workStealing,  /// per-worker rings; only never-started tasks are stealable (M9c)
}

/// Loop-group configuration (DIP1030 named arguments).
struct LoopGroupConfig
{
    Topology topology = Topology.single; /// see `Topology`
    uint workers = 0;                    /// 0 = one per online CPU (non-single)
    uint sqEntries = 256;                /// SQ ring entries per worker
    Flag!"pinToCpu" pinToCpu = Yes.pinToCpu;  /// sched_setaffinity per worker
    Flag!"futexPark" futexPark = Yes.futexPark; /// in-ring futex idle parking (>= 6.7)
    uint maxFibers = 256;                /// fiber-slab size per worker
    // OPEN (open-issues O21): a per-worker Allocator knob lands here.
}

/**
A running loop group. Non-copyable; owns its worker scheduler(s).
*/
struct LoopGroup
{
    @disable this(this);

    /// Probes the kernel and starts the group. `io_uring` probe failure is a
    /// hard error (SPEC §3.4 — no epoll fallback).
    static IoResult!void start(out LoopGroup group, in LoopGroupConfig cfg = LoopGroupConfig())
    {
        // workStealing lands in M9c; single and threadPerCore are wired.
        assert(cfg.topology != Topology.workStealing,
            "workStealing lands in M9c");

        group._cfg = cfg;
        if (cfg.topology == Topology.single)
        {
            // The single topology's one worker is created eagerly on the
            // calling thread; thread-per-core creates each worker's Sched on
            // its own thread (Sched/ring/fiber are thread-affine).
            SchedOptions opts;
            opts.maxFibers = cfg.maxFibers;
            LoopConfig loopCfg;
            loopCfg.backend.sqEntries = cfg.sqEntries;
            auto r = Sched.create(group._sched, opts, loopCfg);
            if (r.hasError)
                return r;
        }
        group._started = true;
        return ioOk();
    }

    /// Worker threads for the thread-per-core topology (0 = one per online CPU).
    uint workerCount() const @safe pure nothrow @nogc
    {
        import std.parallelism : totalCPUs;

        if (_cfg.topology == Topology.single)
            return 1;
        return _cfg.workers != 0 ? _cfg.workers : totalCPUs;
    }

    /// Tears down the group's workers.
    void shutdown(Duration grace = 5.seconds) @safe nothrow
    {
        if (_started)
        {
            if (_cfg.topology == Topology.single)
                _sched.destroy();
            _started = false;
        }
    }

    ~this()
    {
        shutdown();
    }

    /**
    Runs `main` as the root fiber inside the root scope, handing it the live
    capability row. All authority originates here. Blocks the calling thread
    until the root scope joins; the group is then shut down.
    */
    Outcome!T run(T)(scope T delegate(ref RootScope root, ref Env env) main)
    {
        auto env = Env(RingClock(&_sched), RingNet(&_sched));

        // The Outcome cannot be default-constructed (NoGcHook), so record the
        // result field-by-field from inside the root fiber and rebuild after.
        bool isErr;
        Cause!IoError cause;
        static if (!is(T == void))
            T value;

        _sched.run(() {
            auto outcome = withScope!((ref RootScope sc) {
                static if (is(T == void))
                    main(sc, env);
                else
                    return main(sc, env);
            }, IoError)(_sched);

            if (outcome.hasError)
            {
                isErr = true;
                cause = outcome.error;
            }
            else
            {
                static if (!is(T == void))
                    value = move(outcome.value);
            }
        });

        if (isErr)
            return outcomeErr!(T, IoError)(cause);
        static if (is(T == void))
            return outcomeOk!IoError();
        else
            return outcomeOk!IoError(move(value));
    }

    /**
    Runs `main` on every worker, share-nothing (SPEC §11 thread-per-core):
    each worker owns its own ring, scheduler, and live `Env`, and there is no
    shared mutable state — cross-worker coordination is the app's, over its
    own channels. Worker 0 runs on the calling thread; the rest run on pinned
    threads. Blocks until all workers' root scopes join.

    `main` receives the worker id, its root scope, and its `Env`. It is called
    concurrently on every worker, so anything it closes over must be safe to
    share (typically `shared`/atomic counters or nothing).
    */
    void runEach(scope void delegate(uint workerId, ref RootScope root, ref Env env) main)
    {
        import core.thread : Thread;

        const n = workerCount();
        auto cfg = _cfg;

        void runWorker(uint id) @trusted
        {
            SchedOptions opts;
            opts.maxFibers = cfg.maxFibers;
            LoopConfig loopCfg;
            loopCfg.backend.sqEntries = cfg.sqEntries;
            Sched sched;
            if (Sched.create(sched, opts, loopCfg).hasError)
                return; // a worker whose ring won't open is silently skipped
            scope (exit) sched.destroy();

            if (cfg.pinToCpu)
                pinToCpu(id);

            auto env = Env(RingClock(&sched), RingNet(&sched));
            sched.run(() {
                cast(void) withScope!((ref RootScope sc) {
                    main(id, sc, env);
                }, IoError)(sched);
            });
        }

        // A by-value factory: `id` is a fresh function parameter per call, so
        // each thread's closure captures its own worker id (a plain
        // `() => runWorker(id)` over the loop variable would capture one
        // shared reference — the classic D loop-capture bug).
        Thread makeWorker(uint id)
        {
            return new Thread(() => runWorker(id));
        }

        // Workers 1..n-1 on their own threads; worker 0 on this thread.
        Thread[] threads;
        foreach (uint id; 1 .. n)
        {
            auto t = makeWorker(id);
            t.start();
            threads ~= t;
        }
        runWorker(0);
        foreach (t; threads)
            t.join();
    }

    /// The worker's scheduler (single topology: the only one).
    ref Sched worker() return @safe nothrow @nogc => _sched;

private:
    static void pinToCpu(uint cpu) @trusted nothrow @nogc
    {
        version (linux)
        {
            import core.sys.linux.sched : CPU_SET, cpu_set_t, sched_setaffinity;
            import std.parallelism : totalCPUs;

            cpu_set_t set;
            CPU_SET(cpu % totalCPUs, &set);
            cast(void) sched_setaffinity(0, cpu_set_t.sizeof, &set);
        }
        // Non-Linux: CPU pinning via the platform primitive is a follow-up;
        // the topology still works, just unpinned.
    }

    Sched _sched;
    LoopGroupConfig _cfg;
    bool _started;
}

@("group.single.runsRootWithEnv")
@system
unittest
{
    import sparkles.event_horizon.capability : hasCaps;

    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) group.shutdown();

    int fromClock;
    auto outcome = group.run((ref root, ref env) {
        static assert(hasCaps!(typeof(env), "clock", "net"));
        // The live clock's monotonic time is nonzero and advances.
        const t0 = env.clock.now();
        assert(t0 > typeof(t0).zero);
        fromClock = 1;
        return 42;
    });
    assert(!outcome.hasError);
    assert(outcome.value == 42);
    assert(fromClock == 1);
}

@("group.single.loopbackEchoThroughEnvNet")
@system
unittest
{
    import core.lifetime : move;

    import sparkles.base.smallbuffer : SmallBuffer;
    import sparkles.event_horizon.io : accept, recv, send;
    import sparkles.event_horizon.net : ipv4;

    LoopGroup group;
    if (LoopGroup.start(group).hasError)
        return; // SKIP
    scope (exit) group.shutdown();

    static immutable payload = cast(immutable ubyte[]) "env.net echo";

    bool verified;
    auto outcome = group.run((ref root, ref env) {
        // Bind on an ephemeral port, recover it, then connect a client and
        // echo one message — all through the live net capability + scopes.
        auto listener = env.net.listen(ipv4("127.0.0.1", 0)).value;

        // Recover the kernel-assigned port from the listener fd.
        ushort port = boundPort(listener.fd);

        root.spawn(() {
            auto conn = listener.accept;
            if (conn.hasError)
                return;
            auto peer = conn.value;
            scope (exit) peer.close();
            SmallBuffer!(ubyte, 64) buf;
            buf.length = 64;
            auto got = peer.recv(move(buf));
            buf = move(got.buf);
            if (!got.res.hasError && got.res.value > 0)
            {
                buf.length = got.res.value;
                cast(void) peer.send(move(buf));
            }
        });

        auto client = env.net.connect(ipv4("127.0.0.1", port)).value;
        scope (exit) client.close();
        SmallBuffer!(ubyte, 64) msg;
        msg ~= payload[];
        cast(void) client.send(move(msg));

        SmallBuffer!(ubyte, 64) back;
        back.length = 64;
        auto echoed = client.recv(move(back));
        if (!echoed.res.hasError)
            verified = echoed.buf[][0 .. echoed.res.value] == payload[];

        listener.close();
    });
    assert(!outcome.hasError);
    assert(verified);
}

version (unittest)
private ushort boundPort(int fd) @trusted nothrow @nogc
{
    import core.sys.posix.arpa.inet : ntohs;
    import core.sys.posix.netinet.in_ : sockaddr_in;
    import core.sys.posix.sys.socket : getsockname, sockaddr, socklen_t;

    sockaddr_in a;
    socklen_t len = a.sizeof;
    getsockname(fd, cast(sockaddr*) &a, &len);
    return ntohs(a.sin_port);
}

@("group.threadPerCore.shareNothingWorkers")
@system
unittest
{
    import core.atomic : atomicOp;
    import core.time : msecs;

    LoopGroup group;
    LoopGroupConfig cfg;
    cfg.topology = Topology.threadPerCore;
    cfg.workers = 4;
    if (LoopGroup.start(group, cfg).hasError)
        return; // SKIP: io_uring unavailable
    scope (exit) group.shutdown();
    assert(group.workerCount == 4);

    shared uint ran;
    shared ulong idMask;
    group.runEach((uint id, ref root, ref env) {
        // Each worker drives its own ring — the live clock's in-ring TIMEOUT
        // sleep proves it — then records that it ran (share-nothing but for
        // the atomic tallies).
        cast(void) env.clock.sleep(1.msecs);
        atomicOp!"+="(ran, 1);
        atomicOp!"|="(idMask, 1UL << id);
    });

    assert(ran == 4, "every worker ran its own root on its own ring");
    assert(idMask == 0b1111, "all four worker ids distinct");
}
