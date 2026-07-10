/**
The three-tier capability probe (SPEC §3.2–§3.4), resolved into one
immutable `BackendCaps` value at loop creation:

$(NUMBERED_LIST
    $(ITEM backend selection — `io_uring_setup` succeeds, or creation fails
        with the hard error of SPEC §3.4 (there is $(B no) epoll fallback))
    $(ITEM opcode probe — `IORING_REGISTER_PROBE` gates the portable
        `OpKind` set)
    $(ITEM feature flags — negotiated `IORING_FEAT_*` bits and accepted
        setup flags)
)

Static traits (`backend.concept`) answer "does this backend have the code";
`BackendCaps` answers "does this kernel/OS have the feature". A feature path
runs only when both agree.
*/
module sparkles.event_horizon.backend.probe;

import sparkles.event_horizon.errors : IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;

/// Which backend implementation a loop runs on.
enum BackendId : ubyte
{
    uring,  /// Linux `io_uring` (the reference backend)
    kqueue, /// macOS/BSD kqueue, completion-synthesizing (M10)
    iocp,   /// Windows IOCP (M11)
}

/// Parsed `uname` release, for feature gates keyed on kernel versions.
struct KernelVersion
{
    ushort major; /// e.g. 6
    ushort minor; /// e.g. 18

    /// `true` when this version is `major.minor` or newer.
    bool atLeast(ushort maj, ushort min) const @safe pure nothrow @nogc
        => major > maj || (major == maj && minor >= min);
}

/// Ring operating mode (SPEC §3.2).
enum LoopMode : ubyte
{
    exclusive,   /// `SINGLE_ISSUER + DEFER_TASKRUN` — the thread-per-core default
    cooperative, /// `COOP_TASKRUN + TASKRUN_FLAG` — the single-threaded default
}

/// What mode negotiation does when the requested mode is unavailable.
enum ModePolicy : ubyte
{
    exact,         /// requested mode unavailable → `IoError(stage: probe)`
    bestAvailable, /// degrade `exclusive` → `cooperative`; result recorded in caps
}

/**
The negotiated capability surface — immutable after loop creation.
*/
struct BackendCaps
{
    BackendId backend;       /// which backend this is
    KernelVersion kernel;    /// the running kernel
    LoopMode mode;           /// operating mode actually negotiated
    ulong opBits;            /// bit per `OpKind` (see `supports`)
    bool singleIssuer;       /// `SINGLE_ISSUER` accepted
    bool deferTaskrun;       /// `DEFER_TASKRUN` accepted
    bool coopTaskrun;        /// `COOP_TASKRUN` accepted
    bool registeredBuffers;  /// registered-buffer support
    bool registeredFiles;    /// registered-file support
    bool bufRing;            /// provided buffer rings (5.19)
    bool multishotAccept;    /// multishot accept (5.19)
    bool multishotRecv;      /// multishot recv (6.0)
    bool futexOps;           /// in-ring futex ops (6.7)
    bool msgRing;            /// `MSG_RING` (5.18)
    bool extArg;             /// `IORING_FEAT_EXT_ARG` (inline-timespec waits)
    bool nodrop;             /// `IORING_FEAT_NODROP` (asserted by the floor)

    /// Whether the kernel implements the given portable op.
    bool supports(OpKind k) const @safe pure nothrow @nogc
        => ((opBits >> k) & 1) != 0;
}

static assert(OpKind.max < 64, "opBits packs one bit per OpKind");

/// The v1 Linux baseline (SPEC §3.3): both operating modes and the whole
/// ≤ 5.19 tier-3 feature set are guaranteed at or above this version.
enum KernelVersion kernelFloor = KernelVersion(6, 1);

version (EventHorizonLibkqueue) {} else version (linux)
{
    /// The running kernel's version, parsed from `uname(2)`'s release
    /// string (e.g. `"6.18.26-gentoo"` → 6.18).
    KernelVersion kernelVersion() @trusted nothrow @nogc
    {
        import core.sys.posix.sys.utsname : uname, utsname;

        utsname u;
        if (uname(&u) != 0)
            return KernelVersion(0, 0);

        // Hand-rolled parse: "major.minor…", stopping at the first
        // non-digit after each field (std.conv would GC-allocate on error).
        static ushort parseField(scope const(char)[] s, ref size_t i) @safe pure nothrow @nogc
        {
            ushort v;
            while (i < s.length && s[i] >= '0' && s[i] <= '9')
            {
                v = cast(ushort) (v * 10 + (s[i] - '0'));
                ++i;
            }
            return v;
        }

        const(char)[] rel = () @trusted {
            import core.stdc.string : strlen;
            return u.release[0 .. strlen(u.release.ptr)];
        }();

        size_t i;
        const major = parseField(rel, i);
        if (i >= rel.length || rel[i] != '.')
            return KernelVersion(major, 0);
        ++i;
        const minor = parseField(rel, i);
        return KernelVersion(major, minor);
    }

    /**
    Builds the negotiated `BackendCaps` for an already-set-up ring —
    shared by `UringBackend.open` (which probes on its real ring) and
    $(LREF probeSystem) (which probes on a throwaway one).

    `accepted` are the setup flags the kernel took; `mode` is the
    operating mode they encode.
    */
    package BackendCaps buildUringCaps(Uring)(ref Uring io, LoopMode mode,
        bool singleIssuer, bool deferTaskrun, bool coopTaskrun) nothrow @nogc
    {
        import during : Operation, SetupFeatures;

        BackendCaps caps;
        caps.backend = BackendId.uring;
        caps.kernel = kernelVersion();
        caps.mode = mode;
        caps.singleIssuer = singleIssuer;
        caps.deferTaskrun = deferTaskrun;
        caps.coopTaskrun = coopTaskrun;

        // Tier 3 — negotiated feature flags.
        const features = io.params().features;
        caps.extArg = (features & SetupFeatures.EXT_ARG) != 0;
        caps.nodrop = (features & SetupFeatures.NODROP) != 0;

        // Tier 2 — the opcode probe (IORING_REGISTER_PROBE, 5.6 — always
        // present above the 6.1 floor, but a probe failure still degrades
        // to "nothing supported" rather than failing loop creation).
        auto probe = io.probe();
        if (cast(bool) probe)
        {
            static immutable Operation[OpKind.max + 1] lowering = [
                OpKind.none: Operation.NOP,
                OpKind.nop: Operation.NOP,
                OpKind.read: Operation.READ,
                OpKind.write: Operation.WRITE,
                OpKind.recv: Operation.RECV,
                OpKind.recvSelect: Operation.RECV,
                OpKind.send: Operation.SEND,
                OpKind.sendTo: Operation.SENDMSG,
                OpKind.recvFrom: Operation.RECVMSG,
                OpKind.accept: Operation.ACCEPT,
                OpKind.acceptMultishot: Operation.ACCEPT,
                OpKind.connect: Operation.CONNECT,
                OpKind.shutdown: Operation.SHUTDOWN,
                OpKind.openAt: Operation.OPENAT,
                OpKind.close: Operation.CLOSE,
                OpKind.statx: Operation.STATX,
                OpKind.fsync: Operation.FSYNC,
                OpKind.timeout: Operation.TIMEOUT,
                OpKind.linkTimeout: Operation.LINK_TIMEOUT,
                OpKind.cancel: Operation.ASYNC_CANCEL,
                OpKind.futexWait: Operation.FUTEX_WAIT,
                OpKind.futexWake: Operation.FUTEX_WAKE,
                OpKind.msgRing: Operation.MSG_RING,
                OpKind.waitid: Operation.WAITID,
            ];
            foreach (kind, lowered; lowering)
                if (kind != 0 && probe.isSupported(lowered))
                    caps.opBits |= 1UL << kind;
        }

        // Version-keyed features with no opcode of their own.
        caps.multishotAccept = caps.kernel.atLeast(5, 19) && caps.supports(OpKind.accept);
        caps.multishotRecv = caps.kernel.atLeast(6, 0) && caps.supports(OpKind.recv);
        caps.bufRing = caps.kernel.atLeast(5, 19);
        caps.registeredBuffers = caps.supports(OpKind.read);  // READ_FIXED since 5.1
        caps.registeredFiles = caps.supports(OpKind.read);    // FIXED_FILE since 5.1
        caps.futexOps = caps.supports(OpKind.futexWait);
        caps.msgRing = caps.supports(OpKind.msgRing);

        return caps;
    }

    /**
    Diagnostics-only standalone probe: creates a throwaway ring, negotiates
    the requested mode, builds `BackendCaps`, and destroys the ring.
    `EventLoop.create` probes on its real ring instead — one setup, not two.

    Linux hard-error semantics (SPEC §3.4): if `io_uring_setup` fails —
    `ENOSYS` (kernel too old or compiled out), `EPERM`/`EACCES` (seccomp,
    the `io_uring_disabled` sysctl, container lockdown) — this returns
    `IoError(errno, OpKind.none, IoErrorStage.setup)`. If the kernel is
    below the 6.1 floor, `IoError(0, OpKind.none, IoErrorStage.probe)`.
    There is no epoll fallback.
    */
    IoResult!BackendCaps probeSystem(
        LoopMode requested = LoopMode.exclusive,
        ModePolicy policy = ModePolicy.bestAvailable) @trusted nothrow @nogc
    {
        import during : SetupFlags, Uring, setup;

        static IoResult!BackendCaps tryMode(LoopMode mode) @trusted nothrow @nogc
        {
            const flags = mode == LoopMode.exclusive
                ? SetupFlags.SINGLE_ISSUER | SetupFlags.DEFER_TASKRUN | SetupFlags.COOP_TASKRUN
                : SetupFlags.COOP_TASKRUN | SetupFlags.TASKRUN_FLAG;

            Uring io;
            const ret = io.setup(8, flags);
            if (ret < 0)
                return ioErr!BackendCaps(-ret, OpKind.none, IoErrorStage.probe,
                    "operating-mode setup flags rejected");

            const exclusive = mode == LoopMode.exclusive;
            auto caps = buildUringCaps(io, mode,
                exclusive, exclusive, true);
            return ioOk(caps);
        }

        // Tier 1 — backend selection: does io_uring exist at all?
        {
            Uring plain;
            const ret = plain.setup(8);
            if (ret < 0)
                return ioErr!BackendCaps(-ret, OpKind.none, IoErrorStage.setup,
                    "io_uring unavailable");
        }

        if (!kernelVersion().atLeast(kernelFloor.major, kernelFloor.minor))
            return ioErr!BackendCaps(0, OpKind.none, IoErrorStage.probe,
                "kernel below the 6.1 baseline");

        auto r = tryMode(requested);
        if (r.hasError && policy == ModePolicy.bestAvailable
            && requested == LoopMode.exclusive)
            return tryMode(LoopMode.cooperative);
        return r;
    }
}

@("probe.KernelVersion.atLeast")
@safe pure nothrow @nogc
unittest
{
    const v = KernelVersion(6, 7);
    assert(v.atLeast(6, 7));
    assert(v.atLeast(6, 1));
    assert(v.atLeast(5, 19));
    assert(!v.atLeast(6, 8));
    assert(!v.atLeast(7, 0));
}

version (EventHorizonLibkqueue) {} else version (linux)
{
    @("probe.kernelVersion.parses")
    @safe nothrow @nogc
    unittest
    {
        const v = kernelVersion();
        // Any host running these tests has a versioned kernel.
        assert(v.major > 0);
    }

    @("probe.probeSystem.capsOrSkip")
    @safe nothrow
    unittest
    {
        auto r = probeSystem();
        if (r.hasError)
        {
            // SKIP-style: io_uring genuinely unavailable (container/seccomp)
            // or pre-6.1 kernel — the hard-error path is itself the test.
            assert(r.error.stage == IoErrorStage.setup
                || r.error.stage == IoErrorStage.probe);
            return;
        }
        const caps = r.value;
        assert(caps.backend == BackendId.uring);
        assert(caps.kernel.atLeast(6, 1));
        assert(caps.supports(OpKind.nop));
        assert(caps.supports(OpKind.accept));
        assert(caps.nodrop, "NODROP negotiated since 5.5 — required");
        // Floor-guaranteed tier-3 features (SPEC §3.3).
        assert(caps.multishotAccept);
        assert(caps.multishotRecv);
        assert(caps.bufRing);
    }
}
