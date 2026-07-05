# `sparkles:event-horizon` — Specification

_Audience: developers and coding agents building against the library. This
document is normative and self-contained — it states what the library
provides, not why. For the delivery plan, see [PLAN.md](./PLAN.md); for
unresolved design questions, see [open-issues.md](./open-issues.md); for the
research that motivated each decision, see the
[async-io](../../research/async-io/index.md) and
[algebraic-effects](../../research/algebraic-effects/index.md) surveys._

## 1. Overview

`sparkles:event-horizon` is a completion-first (proactor) event loop with a
native algebraic-effect layer. On Linux it drives `io_uring` directly (via the
[`during`](https://github.com/tchaloupka/during) binding) — there is **no
epoll fallback**: a Linux system without a working `io_uring` fails loop
creation with a structured error (§3.4). macOS (kqueue) and Windows (IOCP)
are peer backends behind the same seam (§3.1), not degraded fallbacks.

One loop, three programming tiers, each a public API:

| Tier  | Model                   | Modules        | Suspension                      |
| ----- | ----------------------- | -------------- | ------------------------------- |
| **A** | callback / completion   | `loop`, `op`   | none — completion callbacks     |
| **B** | direct-style fibers     | `sched`, `io`  | `core.thread.Fiber` park/resume |
| **C** | `Effect!T` descriptions | `effect` (§12) | lowered onto tier B             |

Tier A is the substrate the other tiers build on _and_ a supported public API
(`@nogc nothrow`, function-pointer callbacks, no fibers). Tier B gives
blocking-looking code with no function coloring. Tier C is a thin monadic
veneer whose combinators are defined in terms of tier B (§12).

The target ergonomics, end to end (tier B):

<!-- md-example-skip: sparkles:event-horizon not implemented until M9 (LoopGroup + live Env row) -->

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "event_horizon_overview"
    dependency "sparkles:event-horizon" version="*"
+/
import core.lifetime : move;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.event_horizon;

void main()
{
    LoopGroup group;
    auto started = LoopGroup.start(group,
        LoopGroupConfig(topology: Topology.single));
    if (started.hasError)
        assert(false, started.error.context);
    group.run((ref RootScope sc, ref Env env) {
        auto listener = env.net.listen(ipv4("127.0.0.1", 8080)).value;
        sc.spawnDaemon({
            for (;;)
            {
                auto conn = listener.accept;      // parks; resumes on CQE
                if (conn.hasError)
                    break;                        // interrupted / closed
                sc.spawn(() => echo(conn.value)); // child bound to sc
            }
        });
        // … run until a shutdown condition, then:
        sc.cancel(Interrupt(InterruptKind.shutdown));
    });                                           // joins/cancels all children
}

void echo(Stream conn)
{
    scope (exit) conn.close();                    // runs even on Interrupt
    SmallBuffer!(ubyte, 4096) buf;
    buf.length = 4096;                            // grow-with-default (M4 base prerequisite)
    for (;;)
    {
        auto r = conn.recv(move(buf));            // buffer moves in …
        buf = move(r.buf);                        // … and comes back
        if (r.res.hasError || r.res.value == 0)
            return;                               // error / interrupt / EOF
        auto w = conn.send(move(buf), 0, r.res.value);
        buf = move(w.buf);
        if (w.res.hasError)
            return;
    }
}
```

```[Output]

```

## 2. Package and module layout

| Identifier      | Value                                            |
| --------------- | ------------------------------------------------ |
| Dub sub-package | `sparkles:event-horizon`                         |
| Source root     | `libs/event-horizon/src/sparkles/event_horizon/` |
| Package module  | `sparkles.event_horizon`                         |

Modules are split into two strata by an **import firewall**: _effects-side_
modules never import ring, loop, or scheduler modules (nor `during`), so a
future extraction into a standalone `sparkles:effects` package is mechanical.
_Loop-side_ modules may import anything.

| Module                           | Stratum      | Contents                                                                                                                             |
| -------------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------------ |
| `errors`                         | effects-side | `OpKind`, `IoError`, `IoErrorStage`, `NoGcHook`, `IoResult`, `ioOk`/`ioErr`, `fromRes` (§9.1) — leaf                                 |
| `cause`                          | effects-side | `Cause`, `Interrupt`, `Outcome`, `widen`; `FiberContext`, `CancelContext`, `CancelFn`, `cancelTree` (§8, §9.2)                       |
| `capability`                     | effects-side | `isCapability`, `Ctx`, `hasCaps`, `CtxOf`; the `isWaker` and `isFiberExecutor` seams (§10)                                           |
| `scope_`                         | effects-side | `Scope`, `withScope`, `withDeadline`, `protect`, `checkCancellation`, `JoinHandle` (§8)                                              |
| `schedule`                       | effects-side | `Schedule` values + `retry`/`repeat`/`timeout`/`race` drivers (§10.4)                                                                |
| `clock`                          | effects-side | `isClock` + `TestClock` (§10.3)                                                                                                      |
| `net`                            | effects-side | `SockAddr` + helpers (`ipv4`, …), `isNet`, `isByteStream` + `SimNet` (§10.3)                                                         |
| `testing`                        | effects-side | `TestSched` (deterministic executor) + `advanceAndSettle` (§10.3)                                                                    |
| `buffer`                         | loop-side    | `Buf`, `BufOrigin`, `BufGroupId`, `BufResult`, `BufferPool`, `BufRing`, `isOwnedIoBuf` (§6)                                          |
| `op`                             | loop-side    | op descriptors, `KernelTimespec`, `OpToken`, `OpClass`, `OpSlot`/`OpSlab`, `Completion`, `OpCallback` (§4); re-exports `SockAddr`    |
| `handle`                         | loop-side    | `LoopHandle` — opt-in type-erased loop access for loop-side plumbing and `-betterC` users (§5.5)                                     |
| `backend.concept`                | loop-side    | `isCompletionBackend` + optional-capability traits, `RawCompletion`, `BackendConfig`, `Waker` (§3.1)                                 |
| `backend.probe`                  | loop-side    | `BackendCaps`, `LoopMode`, `ModePolicy`, `probeSystem` (§3.2–3.4)                                                                    |
| `backend.uring`                  | loop-side    | `UringBackend` over `during` (§3.5); `backend.kqueue` / `backend.iocp` follow in M10/M11                                             |
| `loop`                           | loop-side    | `EventLoop!Backend`, `LoopConfig`, `DefaultLoop` — tier A (§5)                                                                       |
| `sched`                          | loop-side    | `Sched`, `SchedOptions`, `FiberTask`, `currentTask`, `RootScope` — tier B scheduler (§7)                                             |
| `io`                             | loop-side    | direct-style verbs (`read`/`write`/`recv`/`send`/`accept`/`connect`/`sleep`) and the `Stream`/`Listener`/`FileHandle` handles (§7.3) |
| `live`                           | loop-side    | ring-backed capability implementations (`RingClock`, `RingNet`, …) and the `Env` row (§10.3, §11)                                    |
| `fs`, `proc`, `signals`, `watch` | effects-side | capability concepts + test doubles; their ring implementations join `live` (loop-side); land in M7                                   |
| `group`                          | loop-side    | `LoopGroup`, `LoopGroupConfig`, `Topology` (§11)                                                                                     |
| `effect`                         | effects-side | the `Effect!T` veneer (§12); lands in M12                                                                                            |
| `package`                        | —            | public re-exports                                                                                                                    |

**Foundation:** `sparkles:base` supplies `SmallBuffer` (staging buffers, test
helpers) and `recycledErrorInstance`; the `expected` package (`~>0.4.1`)
supplies `Expected`. `during` (`~>0.5.0`) is the Linux substrate and is not
re-exported — user code never sees an SQE.

## 3. Backends and capability probing

### 3.1 The completion-backend concept

A backend is a struct satisfying the `isCompletionBackend!B` capability trait
— no interface, no vtable. The loop is `EventLoop!Backend`; submission
lowering is a statically dispatched overload set that inlines. The concept is
defined by **CQE semantics**, not by `io_uring`: a backend that synthesizes
completion over readiness (kqueue) must still deliver `(userData, res, flags)`
triples where `res` is a byte count / fd or `-errno`, and multishot streams
set the `more` flag on every non-final completion.

```d
/// What the backend hands the loop per completion.
struct RawCompletion { ulong userData; int res; uint rawFlags; }

enum bool isCompletionBackend(B) = __traits(compiles, {
    BackendConfig cfg;
    IoResult!void o = lvalueOf!B.open(cfg);
    auto caps = lvalueOf!B.caps();
    bool queued = lvalueOf!B.trySubmit(OpNop(), OpToken.init); // false = SQ full
    IoResult!uint f = lvalueOf!B.flush();
    IoResult!uint w = lvalueOf!B.submitAndWait(1u, cast(const(KernelTimespec)*) null);
    uint n = lvalueOf!B.reap((ref const RawCompletion c) {});  // non-blocking drain
    auto wk = lvalueOf!B.waker();                              // thread-safe wake
    lvalueOf!B.close();
}) && canSubmitOp!(B, OpNop);

/// Per-descriptor submission capability; the backend owns the lowering.
/// The probe passes an rvalue: descriptors carrying an owned Buf are
/// move-only, so submission moves the op (§5.2) — an lvalue probe would
/// statically reject every buffer-carrying op.
enum bool canSubmitOp(B, Op) = __traits(compiles, {
    bool r = lvalueOf!B.trySubmit(Op.init, OpToken.init);
});

/// Thread-safe wake handle — the ONLY backend object callable off-thread.
struct Waker { void wake() shared const nothrow @nogc; }
```

Optional capabilities are separate traits; absence degrades, never breaks:

| Trait                    | Gates                                                        |
| ------------------------ | ------------------------------------------------------------ |
| `hasRegisteredBuffers!B` | `READ_FIXED`/`WRITE_FIXED` lowering via `BufferPool` (§6.3)  |
| `hasBufRing!B`           | provided-buffer rings (§6.4)                                 |
| `hasMultishot!(B, kind)` | multishot accept/recv (runtime-caps-backed)                  |
| `hasNativeCancel!B`      | `ASYNC_CANCEL` submission (§8.5)                             |
| `hasNativeTimeout!B`     | in-ring `TIMEOUT` ops; absent → the loop's timer heap (§5.3) |
| `hasMsgRing!B`           | cross-ring completion posting (§11)                          |
| `hasDirectFds!B`         | registered file descriptors                                  |

### 3.2 Operating modes

```d
enum LoopMode : ubyte
{
    exclusive,    /// SINGLE_ISSUER + DEFER_TASKRUN — the thread-per-core default
    cooperative,  /// COOP_TASKRUN + TASKRUN_FLAG — the single-threaded default
}

enum ModePolicy : ubyte
{
    exact,         /// requested mode unavailable → error(stage: probe)
    bestAvailable, /// degrade exclusive → cooperative; result recorded in caps
}
```

`exclusive` mode makes the loop's thread affinity **structural**: the kernel
enforces one submitting thread (`-EEXIST` otherwise), and completions are
delivered only inside `runOnce` (§5.4).

### 3.3 The kernel baseline and the three probe tiers

The v1 Linux baseline is **kernel ≥ 6.1**. This guarantees both operating
modes and the whole tier-3 feature set at or below 5.19 (registered
buffers/files, provided buffer rings, multishot accept) plus multishot recv
and `SINGLE_ISSUER` (6.0) and `DEFER_TASKRUN` (6.1). Consequently there are
**no per-op degradation paths on Linux for baseline features** — the probe
verifies the floor once. Features newer than the floor remain probe-gated:

| Feature                         | Kernel | On absence                               |
| ------------------------------- | ------ | ---------------------------------------- |
| futex ops (`FUTEX_WAIT`/`WAKE`) | 6.7    | idle parking degrades to ring-wait (§11) |
| `RECV_ZC` (zero-copy receive)   | 6.15   | not in v1 (post-v1 series)               |

(`SEND_ZC`, kernel 6.0, is floor-guaranteed but deliberately outside v1 for
lifetime-complexity reasons — [open-issues](./open-issues.md) O6.)

Probing is resolved **once, at loop creation**, into an immutable
`BackendCaps` value, in three tiers:

1. **Backend selection** — `io_uring_setup` succeeds, or creation fails
   (§3.4). Peer platforms select kqueue/IOCP here.
2. **Opcode probe** — `IORING_REGISTER_PROBE` gates the portable `OpKind`
   set; `caps.supports(kind)` answers per-op availability.
3. **Feature flags** — negotiated `IORING_FEAT_*` bits and accepted setup
   flags (e.g. `extArg` selects inline-timespec waits; `nodrop` is asserted).

```d
struct BackendCaps
{
    BackendId backend;              // uring | kqueue | iocp
    KernelVersion kernel;
    LoopMode mode;                  // mode actually negotiated
    ulong opBits;                   // bit per OpKind
    bool singleIssuer, deferTaskrun, coopTaskrun;
    bool registeredBuffers, registeredFiles, bufRing;
    bool multishotAccept, multishotRecv;
    bool futexOps, msgRing, extArg, nodrop;
    bool supports(OpKind k) const @safe pure nothrow @nogc;
}
```

Static traits answer "does this backend have the code"; `BackendCaps` answers
"does this kernel/OS have the feature". A feature path runs only when both
agree.

### 3.4 Hard-error semantics on Linux

If `io_uring_setup` fails — `ENOSYS` (kernel too old or compiled out),
`EPERM`/`EACCES` (seccomp, the `io_uring_disabled` sysctl, container
lockdown) — or the kernel is below the 6.1 floor, loop creation returns
`IoError(errnoValue, OpKind.none, IoErrorStage.setup, "io_uring unavailable")`
(or `stage: probe` for the floor). **There is no epoll fallback.** Tests for
this path follow the repo's `SKIP` convention on hosts where the condition
cannot be produced.

### 3.5 The uring backend

`UringBackend` wraps a `during` `Uring` handle. Lowering is an overload set:
each `trySubmit(op, token)` fills the next SQE via the matching `prepXxx`
helper and sets `user_data = token.raw`. `Buf.origin == registered` selects
`prepReadFixed`/`prepWriteFixed` automatically — "fixed" is an optimization
the user never spells. `submitAndWait` uses `EXT_ARG` inline timespecs when
negotiated. (Known substrate defects in `during` 0.5.0, worked around in the
backend until upstream tags fixes: `prepCancel`'s default-flag path is
mis-typed, so the `ASYNC_CANCEL` SQE is hand-rolled; and
`submitAndWait(want, args)` silently drops `args` when the submission queue
is empty — a deadline wait would block unboundedly — so the backend flushes
and calls `wait(want, args)` explicitly.)

kqueue (M10) synthesizes completions: readiness arms a non-blocking syscall
performed by the backend at reap time; regular-file ops go to a small worker
pool. Worker-pool results are pushed onto a thread-safe completed queue owned
by the backend; `reap` drains that queue into the same `RawCompletion` stream
as readiness-synthesized completions, so the loop never distinguishes the two
paths, and a worker that finishes while the loop is blocked in
`submitAndWait` wakes it via the backend's own waker.

IOCP (M11) is natively completion-based: each op slot's kernel-stable operand
store embeds the op's `OVERLAPPED`; at `GetQueuedCompletionStatusEx` time the
backend maps the returned `OVERLAPPED*` back to its containing slot and emits
the slot's `OpToken` as `userData` — the `OVERLAPPED` shares exactly the
slot-and-buffer lifetime invariant of §4.3.

## 4. Operations and completions

### 4.1 Descriptors

One POD struct per operation kind; `op.d` is portable (no backend imports).
A descriptor may contain (a) values copied into the SQE, (b) an owned `Buf`
(moves into the op slot, pinned until the terminal completion), (c) values
needing kernel-stable storage (`sockaddr`, `timespec`) — copied into the
slot's operand store at submit, so the descriptor itself may die immediately.

```d
struct OpNop     { enum kind = OpKind.nop; }
struct OpRead    { enum kind = OpKind.read;    int fd; Buf buf; ulong offset; }
struct OpWrite   { enum kind = OpKind.write;   int fd; Buf buf; ulong offset; }
struct OpRecv    { enum kind = OpKind.recv;    int fd; Buf buf; }
struct OpSend    { enum kind = OpKind.send;    int fd; Buf buf; }
struct OpConnect { enum kind = OpKind.connect; int fd; SockAddr addr; }
struct OpAccept  { enum kind = OpKind.accept;  int listenFd; }
struct OpAcceptMultishot { enum kind = OpKind.acceptMultishot; int listenFd; }

/// Datagram (UDP) ops. The peer address rides the slot's operand store on
/// send; on receive it is written there by the kernel and copied into the
/// completion. msghdr/iovec-based sendMsg/recvMsg are deferred
/// (open-issues O19).
struct OpSendTo   { enum kind = OpKind.sendTo;   int fd; Buf buf; SockAddr to; }
struct OpRecvFrom { enum kind = OpKind.recvFrom; int fd; Buf buf; }

/// recv with kernel buffer selection: NO buffer at submit; the completion
/// carries a ring-leased Buf (§6.4). multishot keeps one submission armed.
struct OpRecvSelect { enum kind = OpKind.recvSelect; int fd; BufGroupId group; uint maxLen; bool multishot; }

enum bool isOpDesc(Op) = __traits(compiles, { enum OpKind k = Op.kind; });
```

`SockAddr` (a 128-byte `sockaddr_storage`-sized POD plus a length) lives in
`net` with its construction helpers (`ipv4`, …) — effects-side address
vocabulary usable by test doubles — and is re-exported by `op`;
`KernelTimespec` (a `__kernel_timespec` mirror) is a library-owned POD in
`op`. Peer backends satisfy the concept without importing `during`.

`accept` returns the new fd only; the peer address is fetched on demand
(`getpeername`) rather than inflating every op slot by a `sockaddr_storage`.

### 4.2 Tokens and the op-slot slab

`user_data` carries a packed **slot token**, never a raw pointer:

```d
/// ABA-safe packed user_data: | class:8 | generation:24 | index:32 |.
struct OpToken
{
    ulong raw;   // raw == 0 is reserved invalid
    uint index() const;
    uint generation() const;
    OpClass cls() const;    // user | timer | wake | internal
}

/// Public, copyable reference to an in-flight op (cancel/detach target).
struct OpHandle { /* wraps an OpToken */ }
```

Slots live in a fixed slab allocated at loop creation (`pureMalloc`; default
capacity `2 × cqEntries`). A slot holds the completion target (callback +
context — tier B stores its fiber-resume trampoline in the same fields), the
lifetime state, the **cancel provenance** (interrupt vs linked timeout,
§8.5), the pinned `Buf`, and the kernel-stable operand store. Resolution is
one indexed load plus a generation compare; a stale token (recycled slot)
never resolves.

### 4.3 The slot lifetime state machine

```
free ──submit──▶ armed ──terminal CQE──▶ (callback) ──▶ free
armed ──CQE with flags.more──▶ armed              (multishot fan-out)
armed ──cancel()──▶ cancelRequested ──terminal CQE──▶ (callback) ──▶ free
armed | cancelRequested ──detach()──▶ detached ──terminal CQE──▶ free (silent)
```

(Buffering of non-terminal multishot completions and their backpressure
policy: [open-issues](./open-issues.md) O16.)

Invariant: **a slot and its pinned buffer stay alive until the terminal
completion arrives — always**, including after cancellation (the kernel may
still write to the buffer until the CQE lands) and after `detach` (the
Monoio "Ignored" discipline). A linked pair (op + `LINK_TIMEOUT`) expects two
CQEs before the slot is released.

### 4.4 Completions

```d
enum CompletionFlags : uint
{
    none           = 0,
    more           = 1 << 0,  /// multishot: not the last completion
    bufferSelected = 1 << 1,  /// buf carries a ring lease (§6.4)
}

/// Passed by ref: the callback may `move(done.buf)` to keep the buffer;
/// otherwise the loop recycles it to its origin.
struct Completion
{
    OpToken token;
    OpKind kind;
    int res;                       /// raw result: >= 0 payload or -errno
    CompletionFlags flags;
    Buf buf;
    IoResult!uint result() @safe pure nothrow @nogc;  // fromRes(res, kind)
    bool isFinal() const @safe pure nothrow @nogc;    // !(flags & more)
}

alias OpCallback = void function(void* ctx, ref Completion done) nothrow @nogc;
```

Callbacks are `@nogc nothrow` **function pointers with an explicit context
pointer**, not delegates: the callback is stored until an arbitrary future
completion, which `scope`/dip1000 cannot check for a closure, and the
function-pointer shape is the `-betterC`/C-ABI floor. (Synchronous sinks that
are _not_ stored — e.g. the backend's `reap` sink — are `scope` delegates.)

Multishot is a property of completion semantics (`flags.more`), not an
`io_uring`-ism: kqueue's `EV_CLEAR` readiness synthesizes it naturally.

## 5. The callback tier (tier A)

### 5.1 The loop

```d
struct LoopConfig
{
    BackendConfig backend;   // sqEntries (256), cqEntries (0 = 2× sq), mode, modePolicy
    uint opSlots = 0;        // 0 = 2 × cqEntries
}

/// runOnce's report: what ended the iteration.
enum RunStatus : ubyte { dispatched, timedOut, stopped, drained }

struct EventLoop(Backend = UringBackend)
if (isCompletionBackend!Backend)
{
    @disable this(this);

    /// Out-parameter factory (the during `setup(ref Uring, …)` shape):
    /// EventLoop is move-only, and IoResult cannot return a non-copyable
    /// payload by value (§9.1).
    static IoResult!void create(out EventLoop loop, in LoopConfig cfg = LoopConfig());
    void destroy();                        // requires inFlight == 0

    ref const(BackendCaps) caps() const return;

    IoResult!OpHandle submit(Op)(Op op, OpCallback cb, void* ctx)
    if (isOpDesc!Op && canSubmitOp!(Backend, Op));

    IoResult!OpHandle submitAfter(Duration rel, OpCallback cb, void* ctx);
    IoResult!OpHandle submitAt(MonoTime deadline, OpCallback cb, void* ctx);

    IoResult!void cancel(OpHandle h);      // fire-and-forget; see §8.5
    void detach(OpHandle h);               // callback never runs; silent recycle

    Waker waker();                         // the only off-thread door

    IoResult!RunStatus runOnce(Duration timeout = Duration.max);
    IoResult!void run();                   // until stop() or drained
    void stop();

    uint inFlight() const;
    uint sqSpace() const;
    MonoTime now() const;                  // cached per runOnce iteration
}

version (linux) alias DefaultLoop = EventLoop!UringBackend;
```

The loop is **thread-affine and non-copyable** (`SINGLE_ISSUER` made
structural): every member except `Waker.wake` must be called from the owning
thread.

### 5.2 Submission and backpressure

`submit` moves buffer fields in (the op is taken by value — the kernel
escapes the pointers, so `scope` must not be claimed); the buffer comes back
via `Completion.buf`. Submission is non-blocking: on a full submission queue
the loop performs one implicit `flush` retry, then returns
`IoError(EAGAIN, kind, submit, "sq full")`. An exhausted slot slab returns
`IoError(ENOBUFS, kind, submit, "op slab full")`.

### 5.3 Timers

Timers are in-ring `TIMEOUT` operations when `hasNativeTimeout!Backend`;
otherwise the loop degrades to a binary-heap timer feeding `submitAndWait`'s
deadline. Handles and cancellation behave identically either way. The clock
is `MonoTime` (monotonic). (Coalescing many sleepers onto one armed deadline
instead of one `TIMEOUT` op per timer: [open-issues](./open-issues.md) O18.)

### 5.4 Running and re-entrancy

`runOnce` performs: flush → `submitAndWait(1, timeout)` → two-phase reap
(batch-copy CQEs, advance the CQ head, **then** dispatch callbacks). Under
`exclusive` mode this is the only point where completions are delivered — the
`DEFER_TASKRUN` contract. Callbacks run on the loop thread and **may submit
but must not re-enter `runOnce`** (contract-checked). CQ overflow (`-EBADR`
under `nodrop`) triggers an internal drain cycle before surfacing an error.
`run()` loops `runOnce` until `stop()` or until the loop is drained (no live
ops, no timers). Off-thread stop: set the flag, then `waker().wake()`.

### 5.5 Type-erased access

The backend seam is DbI-only; erasure exists one level up, opt-in.
`LoopHandle` (`handle.d`) is a betterC-safe function-pointer table over a
concrete loop — one indirect call per submit, no descriptor-specific
inlining. It exists for **loop-side** plumbing that must not be templated on
the backend and for `-betterC` consumers; it is itself loop-side (it imports
`op`). Effects-side modules never hold a `LoopHandle` — they reach the
scheduler only through the `isFiberExecutor`/`isWaker` seams (§10.3). Hot
paths hold the concrete `EventLoop`.

## 6. Buffers

### 6.1 The pinned-buffer currency

Completion I/O forces ownership transfer: the kernel holds the buffer pointer
from submission to terminal completion, so the bytes must not move or be
freed in that window. The tier-A currency is `Buf` — a **move-only handle
over pinned, stable memory**:

```d
enum BufOrigin : ubyte { none, pool, registered, ringLease, foreign }

struct Buf
{
    @disable this(this);                       // exactly one owner, or the kernel
    inout(ubyte)[] opSlice() inout return scope;   // dip1000: views can't escape
    @property uint length() const;             // valid bytes (CQE res on receive)
    @property uint capacity() const;
    @property BufOrigin origin() const;
    static Buf fromForeign(ubyte[] mem, /* deleter */) @system;
    void release();                            // return to origin; ~this() calls it
}
```

> [!IMPORTANT]
> `SmallBuffer` is **not** a valid tier-A transfer currency: its small-buffer
> optimization stores the payload inline, so moving the struct relocates the
> bytes — under a kernel-held pointer that is a silent use-after-move.
> `SmallBuffer` remains the staging/assembly type at the edges; `Buf` (pool,
> registered slot, ring lease, or pinned foreign memory) is what crosses the
> submission boundary at tier A.

### 6.2 `BufResult`

The owned-transfer result shape shared by tier-A completions and tier-B
verbs — the buffer always comes back, success or failure:

```d
struct BufResult(Buf)
{
    Buf buf;               /// ownership returned — the kernel is done with it
    IoResult!uint res;     /// bytes transferred, or the error
}
```

### 6.3 Pools and registered buffers

`BufferPool` carves same-size `Buf`s out of one contiguous slab. When the
backend supports registered buffers the slab is registered once and every
`Buf` carries its slot index; lowering then selects the FIXED opcodes purely
from `Buf.origin`. On a backend without the capability the pool works
identically, unregistered (recorded in caps — same API, honest degradation).

### 6.4 Provided buffer rings

`BufRing` hands the kernel a ring of buffers; a `recvSelect` op commits no
buffer while idle — the completion carries a ring-leased `Buf`
(`flags.bufferSelected`), and releasing that `Buf` replenishes the ring tail
without a syscall. This decouples buffer count from connection count. On
kqueue/IOCP the backend draws from the pool at completion-synthesis time —
the API and the decoupling survive.

### 6.5 Tier-B generic buffers

Tier-B verbs are generic over any **owned** buffer type:

```d
/// requires: `ubyte[] opSlice()` whose memory is stable while the value
/// itself is not moved.
enum bool isOwnedIoBuf(Buf) = /* exact-expression checks */;
```

At tier B the moved-in buffer lives in the suspended verb's stack frame, and
the fiber resumes **only at the terminal completion** (§8.5) — so the frame,
and therefore the buffer, provably outlives kernel use. This is why
inline-storage types (`SmallBuffer!ubyte`) are sound as tier-B transfer
buffers even though they are banned at tier A, and why borrowed-slice
convenience overloads (`readInto(fd, scope ubyte[])`) are sound at tier B. A
future "kill a fiber without resumption" feature would break exactly this
invariant and is therefore excluded.

## 7. The fiber tier (tier B)

### 7.1 Fiber tasks

`FiberTask` subclasses `core.thread.Fiber` (the `std.concurrency.Generator`
pattern): the current task is one downcast of `Fiber.getThis`, and pooling is
`Fiber.reset` on a terminated instance. Tasks live in a fixed slab sized at
scheduler init — steady-state spawn is `@nogc nothrow`; slab exhaustion fails
the spawn (growth is opt-in and allocates). Fiber _construction_ (stack mmap,
GC stack registration) is inherently not `@nogc`; the slab front-loads it.

Every live fiber stack is a conservative-GC scan root; the default stack size
is a `SchedOptions` knob (see [open-issues](./open-issues.md) O4).

### 7.2 The scheduler

One `Sched` per worker thread, never `shared` — the `SINGLE_ISSUER`
discipline extends to all scheduler state. Cross-worker traffic travels only
through group-level messages (§11).

Run-queue discipline:

- a FIFO intrusive ready queue — all CQE wakes and fresh spawns enqueue at
  the tail (fairness under batched CQ drains);
- a 1-entry LIFO slot for same-worker fiber-to-fiber wakes (cache-hot
  handoff), bounded by a budget against starvation;
- CQE handlers **enqueue, never resume inline**: a tick is
  drain CQ batch → run ready (budgeted) → submit accumulated SQEs → wait —
  one `io_uring_enter` per tick under `exclusive` mode.

`SchedOptions` carries the tuning knobs: `defaultStackSize` (see
[open-issues](./open-issues.md) O4), `maxFibers` (the task-slab size),
`lifoBudget`, and `resumeBudget` (fibers run per tick before re-draining the
CQ). `currentTask()` returns the running `FiberTask` (one downcast of
`Fiber.getThis`; asserts off-fiber).

`Sched.run(root)` wraps the root fiber in an **implicit root scope**; there
is no detached spawn (§8.1). `sched` also exports the blessed live scope
instantiation used across tiers B/C:

```d
alias RootScope = Scope!(Sched, IoError);
```

### 7.3 The await seam and the direct-style verbs

Every I/O verb funnels through one choke point:

1. **Checkpoint**: if an interrupt is pending, return
   `ioErr!T(ECANCELED, op, IoErrorStage.submit)` without submitting (a
   cancelled scope does no new work).
2. Acquire a slot with the current fiber as completion target; lower the op;
   `user_data = token`.
3. Install the fiber's one-shot cancel function (§8.4) pointing at the slot.
4. Park. Submission is batched into the tick.
5. Resume on the **terminal** completion: clear the cancel function, map
   `res` through `fromRes`, surface a latched interrupt after the result is
   delivered (no silently lost bytes).

The verbs (module `io`) are thin shims over this seam. `Stream`, `Listener`,
`DgramSocket`, and `FileHandle` (module `io`) are small **copyable
fd-carrying handles with an explicit `close()`** — they own no memory and
carry no ring state; the verbs resolve the scheduler from the current fiber,
which is why only the fiber-level verbs (`sleep`, `yieldNow`) name `Sched`
explicitly. Sockets, listeners, and files are **created only through
capabilities** (`env.net`, `env.fs`, §10.3); the `io` verbs operate on the
handles those capabilities return.

```d
BufResult!Buf read(Buf)(FileHandle f, Buf buf, ulong offset = ulong.max)
if (isOwnedIoBuf!Buf);
BufResult!Buf write(Buf)(FileHandle f, Buf buf, ulong offset = ulong.max)
if (isOwnedIoBuf!Buf);
BufResult!Buf recv(Buf)(ref Stream s, Buf buf) if (isOwnedIoBuf!Buf);
BufResult!Buf send(Buf)(ref Stream s, Buf buf, size_t offset = 0,
    size_t len = size_t.max) if (isOwnedIoBuf!Buf);

/// Datagram verbs (UDP); msghdr-based variants are deferred (open-issues O19).
BufResult!Buf sendTo(Buf)(ref DgramSocket s, Buf buf, in SockAddr to)
if (isOwnedIoBuf!Buf);
BufResult!Buf recvFrom(Buf)(ref DgramSocket s, Buf buf, out SockAddr from)
if (isOwnedIoBuf!Buf);

/// Hot path: the kernel picks the buffer from a provided ring at completion;
/// the returned Buf is a ring lease (origin == ringLease, §6.4).
IoResult!Buf recv(ref Stream s, ref BufRing ring);

IoResult!Stream accept(ref Listener l);
IoResult!void connect(ref Stream s, in SockAddr addr);
IoResult!void sleep(ref Sched s, Duration d);
IoResult!void yieldNow(ref Sched s);      // cooperative reschedule + checkpoint
```

Every verb is a cancellation checkpoint, parks at most once, and resumes only
at its terminal completion (multishot consumption and its backpressure:
[open-issues](./open-issues.md) O16).

## 8. Structured concurrency

### 8.1 Scopes

`Scope` transcribes Eio's `Switch` / Trio's nursery:

- the body counts as a member fiber — the scope cannot finish while it runs;
- **exit joins all children**, on normal and failing paths alike;
- the first `fail`/`die` cause cancels the remaining siblings
  (`OnChildFailure.cancelSiblings`, the default) or lets them finish
  (`collect`); the first cause wins the outcome, later ones are counted
  (§9.2);
- daemon children (`spawnDaemon`) do not keep the scope alive and are reaped
  with `InterruptKind.daemon` once only daemons remain;
- the join itself is **uncancellable** — structured concurrency never
  abandons children; outer cancellation reaches the children instead;
- `onExit` hooks run LIFO at scope exit, inside `protect`.

```d
template withScope(alias fn)
{
    /// Runs fn(ref Scope); returns Outcome!(T, E). Exit protocol:
    /// body returns → policy cancellation → join children → reap daemons →
    /// run onExit hooks (LIFO, protected) → outcome.
    auto withScope(X)(ref X exec, ScopeOptions opts = ScopeOptions())
    if (isFiberExecutor!X);
}

struct Scope(X, E = IoError)
{
    void spawn(scope void delegate() body_);
    void spawn(scope Expected!(void, E, NoGcHook) delegate() body_); // error → Fail
    void spawnDaemon(scope void delegate() body_);
    void spawnPinned(scope void delegate() body_);      // opt out of stealing (§11)
    void fork(T)(ref JoinHandle!(T, E) handle,
        scope Expected!(T, E, NoGcHook) delegate() body_);
    void cancel(Interrupt reason = Interrupt(InterruptKind.cancelled));
    void fail(Cause!E cause);                           // Eio Switch.fail
    void onExit(scope void delegate() nothrow hook);
}

/// Exact-expression scope trait: what the §10.4/§12 drivers constrain on.
enum bool isScope(Sc) = /* spawn/fork/cancel/fail expression checks */;

struct JoinHandle(T, E = IoError)
{
    Outcome!(T, E) join();    // parks until the forked fiber finishes
}
```

Spawn bodies are **ordinary delegates, not `scope`**: a child runs after the
spawning call returns, so a capturing closure's frame must be heap-allocated
(the compiler does this automatically for non-`scope` delegate parameters).
The tempting `scope`-plus-`@trusted` storage trick is unsound — the captured
frame is typically the scope _body_ lambda's, which dies when the body
returns while children still run during the join (verified with
AddressSanitizer during M5). Allocation-free spawning uses a non-capturing
delegate: a member delegate over caller-frame state (`JoinHandle.runShell`
is the blessed pattern) or a function pointer. The library's documented
dip1000 escapes are the address-pinned intrusive structures (`CancelContext`
trees, handles), whose lifetime the join guarantees.

### 8.2 The cancellation tree

Every scope owns one `CancelContext` node; nodes form a tree mirroring scope
nesting. `protect` pushes a **protected** child node that parent cancellation
does not descend into (for cleanup paths); a pending interrupt is delivered
at the first checkpoint after `protect` returns. `cancelTree(node, reason)`
marks non-protected nodes cancelling and fires each member fiber's one-shot
cancel function **exactly once** (swap-to-null before invoking — the Eio
discipline that makes the complete-vs-cancel race impossible by
construction). Cancellation requests stop work; they do not report errors —
failures travel via `Scope.fail`.

### 8.3 Deadlines

A deadline **is** a cancel scope (Trio): `withDeadline(exec, timeout, fn)`
arms the executor's deadline timer (an in-ring `TIMEOUT` whose expiry calls
`cancelTree(node, Interrupt(deadline))`), runs `withScope`, disarms. Expiry
surfaces as `Cause.interrupted` with `InterruptKind.deadline`.

### 8.4 Interrupt delivery and checkpoints

A fiber observes cancellation at **checkpoints**: every I/O verb (before
submitting), `yieldNow`, `checkCancellation`, and every park. Delivery
latches `interrupted` on the fiber's context; the fiber shell (§8.6) makes
the latch authoritative — a body that swallows the `ECANCELED` error still
yields an interrupt outcome ("you cannot silently drop a cancel").

For a fiber parked on I/O, the installed cancel function does **not** wake
the fiber; it submits `ASYNC_CANCEL` for the awaited op on the owner ring
(via a group message when invoked cross-worker). The single wake is always
the terminal CQE. For non-I/O parks (a `JoinHandle.join` — the only non-I/O
park in v1; a cross-fiber channel primitive is a recognized gap, see
[open-issues](./open-issues.md) O20), the cancel function latches the
interrupt and wakes immediately.

### 8.5 In-flight cancellation state machine

Using the slot states of §4.3:

```
armed ── cancel requested ──▶ cancelRequested ── terminal CQE ──▶ free
armed ──────────────────── terminal CQE ───────────────────────▶ free
```

- cancel request: swap the fiber's cancel fn to null (one-shot), latch the
  interrupt, record **cancel provenance** on the slot (interrupt vs linked
  timeout), submit `ASYNC_CANCEL` (owner ring only), do not wake.
- the `ASYNC_CANCEL` op's own CQE (`0` / `-ENOENT` / `-EALREADY`) is internal
  bookkeeping.
- the original op's terminal CQE always still arrives: `-ECANCELED` if the
  cancel won, the real result if it raced. Either way the parked frame — and
  the buffer it holds — outlives kernel use.
- provenance disambiguates `-ECANCELED`: interrupt provenance → the verb's
  caller sees the interrupt (outcome `Cause.interrupted`); linked-timeout
  provenance → a typed `IoError` deadline failure on the Fail channel.

### 8.6 The fiber shell and graceful shutdown

Every spawned body runs inside a shell that maps its ending to an outcome:
interrupt latched → `Cause.interrupted`; body returned `err(e)` →
`Cause.fail(e)`; a `Throwable` escaped (caught via `call(Rethrow.no)`) →
`Cause.die(t)`. The shell decrements the scope's live count, reaps daemons
when only daemons remain, wakes the joiner at zero, and recycles itself into
the task slab.

Graceful shutdown is scope teardown writ large: cancel the accept/multishot
ops, drain until every in-flight op reaches its terminal CQE, run `onExit`
hooks, then unregister buffers/files and destroy the loop (`destroy`
requires `inFlight == 0` — the scope discipline guarantees it).

## 9. Errors

### 9.1 `IoError` and `IoResult`

Module `errors` is a leaf (imports only `expected`) and mirrors
`sparkles.base.text.errors` exactly — struct error, hook, alias, helper
constructors:

```d
enum OpKind : ubyte
{
    none, nop, read, write, recv, recvSelect, send, sendTo, recvFrom,
    accept, acceptMultishot, connect, shutdown,
    openAt, close, statx, fsync,
    timeout, linkTimeout, cancel,
    futexWait, futexWake, msgRing, waitid,
}

enum IoErrorStage : ubyte { setup, probe, registration, submit, completion, cancel }

struct IoError
{
    int errnoValue;                           /// positive errno; 0 = not an OS error
    OpKind op = OpKind.none;
    IoErrorStage stage = IoErrorStage.completion;
    string context = null;                    /// borrowed CTFE-literal detail
}

struct NoGcHook
{
    static immutable bool enableDefaultConstructor = false;
    /// Removes Expected's copying value-accessor fallback so IoResult
    /// instantiates with move-only payloads (extraction via move(r.value)).
    static void onAccessEmptyValue(E)(E err) @safe pure nothrow @nogc
        => assert(0, "accessed value of an error IoResult");
}

alias IoResult(T) = Expected!(T, IoError, NoGcHook);

IoResult!T ioOk(T)(T value) @safe pure nothrow @nogc;
IoResult!void ioOk() @safe pure nothrow @nogc;
IoResult!T ioErr(T)(IoError error) @safe pure nothrow @nogc;
IoResult!T ioErr(T)(int errnoValue, OpKind op,
    IoErrorStage stage = IoErrorStage.completion, string context = null)
    @safe pure nothrow @nogc;

/// The single point where a raw CQE res becomes typed.
IoResult!uint fromRes(int res, OpKind op) @safe pure nothrow @nogc;
```

Move-only payloads (an `expected` 0.4.x constraint): the hook's
`onAccessEmptyValue` makes `IoResult!T` _instantiable_ for non-copyable `T`
(a ring-leased `Buf`, a future RAII handle) with extraction via
`move(r.value)`, but combinators that return the payload by value (`orElse`
and friends) still require copyable `T`. Factories for non-copyable _owners_
(`EventLoop.create`, `LoopGroup.start`) therefore use the out-parameter shape
(`IoResult!void create(out EventLoop loop, …)` — the `during`
`setup(ref Uring, …)` precedent). This hook member is a deliberate divergence
from `sparkles.base.text.errors.NoGcHook`
([open-issues](./open-issues.md) O13).

### 9.2 `Cause` and `Outcome`

Fiber outcomes use a three-way cause (ZIO's `Cause`, flattened for `@nogc` —
no `Then`/`Both` tree; the first cause wins and later ones are counted):

```d
enum InterruptKind : ubyte { cancelled, deadline, raceLost, shutdown, daemon }
struct Interrupt { InterruptKind kind; }

struct Cause(E = IoError)
{
    enum Kind : ubyte { fail, die, interrupt }
    Kind kind;
    // fail: the typed error E (retryable);
    // die: a borrowed Throwable defect (never retried);
    // interrupt: an Interrupt (never retried).
    ushort suppressedCount;          /// causes after the first
    static Cause fail(E e);
    static Cause die(Throwable t);
    static Cause interrupted(Interrupt i);
    bool isTimeout() const;          // interrupt && deadline
}

/// What Scope.join / JoinHandle.join / LoopGroup.run yield.
alias Outcome(T, E = IoError) = Expected!(T, Cause!E, NoGcHook);

/// Lift an op-level result into the fiber-level channel (error → Fail).
Outcome!(T, E) widen(T, E)(Expected!(T, E, NoGcHook) r);
```

The split is load-bearing: capability methods and verbs return `IoResult!T`
(op-level, retryable); joins return `Outcome!(T, E)` because `die` and
`interrupt` are not `IoError`s. `retry` consumes only the `fail` channel —
retrying a defect or a cancellation is always wrong (§10.4).

## 10. Capabilities and effect rows

### 10.1 Capabilities

A capability is a plain struct value naming its row label; handlers are
values — swapping a handler is passing a different one:

```d
enum bool isCapability(C) = is(C == struct)
    && is(typeof(C.capName) : string) && C.capName.length > 0;
```

Effect concepts are exact-expression capability traits (house DbI style):

```d
enum bool isClock(C) = isCapability!C && C.capName == "clock"
    && __traits(compiles, (ref C c) {
        MonoTime t = c.now();
        IoResult!void r = c.sleep(msecs(1));
    });
```

Dispatch is monomorphized: `ctx.clock.now()` is a constant-offset field
access plus a direct, inlinable call — the evidence lookup costs zero
instructions, and every capability operation is tail-resumptive by
construction (the only suspension is the fiber park _inside_ an
implementation, a scheduler service, never a reified continuation).

### 10.2 The row

```d
struct Ctx(Caps...)
if (allSatisfy!(isCapability, Caps) && labelsAreUnique!Caps)
{
    Caps caps;
    ref cap(string name)() inout return;            // ctx.cap!"clock"
    ref opDispatch(string name)() inout return;     // ctx.clock
    // sub/withCap are mutable-receiver only: an inout receiver cannot
    // rebuild a row of pointer-holding (i.e. all live) capabilities —
    // inout(C) does not convert to C when C has indirections.
    auto sub(names...)() scope;                     // row projection
    auto withCap(C)(C c) scope;                     // extend / override (lexical)
}

auto ctx(Caps...)(Caps caps);
alias CtxOf(Caps...) = Ctx!(StaticSortByLabel!Caps); // canonical ordering

enum bool hasCaps(C, names...);   // structural row check
```

The effect-row convention: a function needing **one** capability takes it
bare (`ref Clk clock` constrained by `isClock`); one needing several takes a
`Ctx` constrained by `hasCaps`. Subset projection along template call chains
is implicit — a callee constrained on a subset accepts any superset row
unchanged; `sub` exists for non-template boundaries. `withCap` is the
innermost-handler-wins analogue, lexically scoped. `dip1000` `scope`/`return
scope` on accessors keeps handles from escaping their scope.

The row is a **testability and least-authority convention, not an enforcement
boundary** — D has ambient authority (any function can issue a syscall); the
row buys swappability, auditability, and deterministic tests.

### 10.3 Blessed capabilities and their doubles

Capability modules are effects-side and ship the concept plus a deterministic
test double; live ring-backed implementations live loop-side (module `live`)
and are constructed by `LoopGroup` into the root row:

| Concept                                  | Test double                                                   | Live implementation     |
| ---------------------------------------- | ------------------------------------------------------------- | ----------------------- |
| `isClock`                                | `TestClock` (virtual time)                                    | `RingClock` (`TIMEOUT`) |
| `isNet`                                  | `SimNet` (in-memory, fault-injectable, latency via any Clock) | `RingNet`               |
| `isFs`, `isProc`, `isWatch`, `isSignals` | land in M7                                                    | land in M7              |

The `isFs`/`isProc`/`isWatch`/`isSignals` concept shapes follow the `isClock`
pattern and are specified as an amendment to this section as the first task
of M7. `isNet` requires `capName == "net"`, member types `Stream`/`Listener`,
and `listen(SockAddr)`/`connect(SockAddr)` returning `IoResult`s of them;
`isByteStream` requires the owned-buffer `recv`/`send` shapes of §7.3 plus
`shutdown()` — both as exact-expression traits, `isClock`-style.

`TestClock.advance` wakes due sleepers in deadline order; the deterministic
test executor `TestSched` (module `testing`, effects-side — it builds on
`core.thread.Fiber` directly, which the firewall permits, and satisfies
`isFiberExecutor`) pairs it as `advanceAndSettle(ref TestSched, ref
TestClock, Duration)`: run until quiescent (no fiber ready and no due
sleeper), advance, repeat. `SimNet` parameterized over `TestClock` gives
fully virtual network timing. Test doubles suspend fibers through the
loop-free `isWaker` seam:

```d
/// Minimal one-shot park/wake concept; sched.d provides the live one, tests
/// may provide a synchronous stub. Wake-before-park makes the park a no-op.
enum bool isWaker(W) = is(W.Handle) && __traits(compiles, (ref W w) {
    W.Handle h = w.prepare();
    w.park(h);
    w.wake(h);
});
```

`scope_.d` drives the scheduler through the wider `isFiberExecutor` seam
(current context, spawn, park, wake, optional deadline timer) — a mock
executor makes every scope semantic unit-testable with no ring.

### 10.4 Schedules and the drivers

`Schedule` values are immutable PODs — state (including jitter RNG) lives in
a separate `State`, the step is pure, and composition is by expression
template, so `enum policy = exponential(100.msecs) & recurs(5);` folds at
CTFE. Composition uses `&` (both continue, max delay) and `|` (either
continues, min delay) with named aliases `both`/`either` — D does not permit
overloading `&&`/`||`.

```d
Recurs recurs(size_t n);
Spaced spaced(Duration interval);
Exponential exponential(Duration base, double factor = 2.0);
auto jittered(S)(S s, double lo = 0.8, double hi = 1.2, ulong seed = 0);
auto upTo(S)(S s, Duration limit);
```

The drivers are ordinary template functions over fibers (`scope` delegates —
no closure allocation under dip1000; attributes infer):

```d
// Sc is any scope type (isScope!Sc, §8.1) — RootScope in live code, a
// TestSched-backed scope in tests.
Outcome!(T, E) retry(S, Clk, Sc, T, E)(ref Sc sc, ref Clk clock, S policy,
    scope Expected!(T, E, NoGcHook) delegate() op)
if (isSchedule!S && isClock!Clk && isScope!Sc);
Outcome!(T, E) repeat(S, Clk, Sc, T, E)(/* mirror image, on success */);
Outcome!(T, E) timeout(Clk, Sc, T, E)(ref Sc sc, ref Clk clock, Duration limit,
    scope Expected!(T, E, NoGcHook) delegate() body_);
Outcome!(T, E) race(Sc, T, E)(ref Sc sc,
    scope Expected!(T, E, NoGcHook) delegate()[] contenders...);
```

`retry` retries only `Cause.fail` outcomes; sleeps ride the passed clock, so
`TestClock` virtualizes backoff. `timeout` is `withDeadline` with a result
type. `race` cancels losers on the first terminal contender (both-can-win
races drop the straggler's result; `raceWith` reconciles when that matters).

## 11. Scheduler topologies

```d
enum Topology : ubyte
{
    single,        /// one loop on the calling thread; zero cross-thread machinery
    threadPerCore, /// N pinned workers, one exclusive-mode ring each; no migration
    workStealing,  /// per-worker rings; ONLY never-started tasks are stealable
}

struct LoopGroupConfig
{
    Topology topology = Topology.single;
    uint workers = 0;                        // 0 = one per online CPU
    uint sqEntries = 256;
    Flag!"pinToCpu" pinToCpu = Yes.pinToCpu;
    Flag!"futexPark" futexPark = Yes.futexPark;  // degrades below kernel 6.7
    uint fiberStackPages = 16;
    uint recvBufRingEntries = 0;             // per-worker provided ring (0 = off)
}

struct LoopGroup
{
    @disable this(this);
    /// Out-parameter factory: LoopGroup owns move-only workers (§9.1).
    static IoResult!void start(out LoopGroup group, in LoopGroupConfig cfg);
    Outcome!T run(T)(scope T delegate(ref RootScope root, ref Env env) main);
    IoResult!void postTo(size_t i, void function(void*) @nogc nothrow fn, void* ctx);
    ref DefaultLoop workerLoop(size_t i) return; // tier-A access, owner thread only
    IoResult!void shutdown(Duration grace = 5.seconds);
}

/// The live capability row handed to the root fiber; grows with M7.
alias Env = CtxOf!(RingClock, RingNet /* , RingFs, RingProc, … after M7 */);
```

`LoopGroup.run` hands the root fiber the root `RootScope` and the live
capability row `Env` — all authority originates there (the Eio
`Eio_main.run env` shape).

**Lifecycle.** `LoopGroup` owns the per-worker `EventLoop`s and `Sched`s: it
constructs them in `start` and destroys them in `shutdown`. `run` returning
triggers an implicit `shutdown` with the default grace; calling `shutdown`
explicitly is idempotent. Shutdown ordering: cancel the root scope → each
worker drains to terminal CQEs → `onExit` hooks → unregister buffers/files →
`EventLoop.destroy` → join worker threads. If the grace period expires with
ops still in flight, `shutdown` returns `IoError(ETIMEDOUT, OpKind.none,
IoErrorStage.cancel)` and **intentionally leaks the affected ring and its
slab** rather than freeing kernel-visible memory — the §4.3 invariant
outranks the deadline.

**The spawn × topology contract.**

- `single` / `threadPerCore`: a child always runs on the spawning worker.
- `workStealing`: a child enters the local queue; an idle worker may steal it
  **only before its first resume**. Once a fiber has executed, it is pinned
  to that worker for life. `spawnPinned` opts a child out of stealing
  entirely; `postTo` is the only explicit cross-ring placement.

The pinning invariant is load-bearing, forced by three independent
constraints: `SINGLE_ISSUER` forbids remote submission (a resumed fiber
immediately submits to its owner's ring); op slots, buffers, and deadline
timers are ring-local; and migrating a started `core.thread.Fiber` between
threads is undefined behavior under LDC when any live frame has cached a TLS
address (druntime's `CheckFiberMigration` exists for exactly this). Stealing
therefore balances **task starts**, not running fibers — the Glommio/Monoio
semantics, not Tokio/Go.

**Idle parking and cross-worker signalling.** With `futexPark` on kernel
≥ 6.7, an idle worker parks in an in-ring `FUTEX_WAIT` on its own futex word,
so one wait observes CQE arrivals, steal wakes, and message-ring traffic
alike; peers publish work by bumping the word plus `FUTEX_WAKE`. Below 6.7
this degrades (per-feature, via caps — not an error) to plain ring-wait
parking with `MSG_RING` nudges. Cross-worker wakes, cancels, and spawn
injection travel as `MSG_RING` messages to the owner ring; `wake()` asserts
owner-worker identity. The M9 benchmark decides the default handoff mix
(futex-wake vs `MSG_RING` vs eventfd — [open-issues](./open-issues.md) O2).

## 12. The `Effect!T` veneer (tier C — non-normative sketch)

Lands in M12; recorded here so tiers A/B are built with it in mind.

`Effect!(T, E)` is a lazy, typed description of a fiber computation. There is
deliberately **no `R` parameter**: the environment channel is the `Ctx` type
supplied at `run`, checked at compile time via `hasCaps` constraints and
erased at run time (the Kyo lesson — ZIO's `R` generalizes to an open row,
and D's `Ctx` _is_ that row, resolved statically).

```d
auto succeed(T)(T v);
auto effect(alias fn)();                       // lift a direct-style body
auto map(alias f, Eff)(Eff e);
auto andThen(alias f, Eff)(Eff e);
auto zipPar(A, B)(A a, B b);
auto withRetry(S, Eff)(Eff e, S policy);
auto withTimeout(Eff)(Eff e, Duration limit);

Outcome!(Eff.Value, Eff.Error) run(Eff, Sc, C)(Eff eff, ref Sc sc, ref C ctx)
if (isEffect!Eff && isScope!Sc);
```

The interpreter is a **compile-time fold**, not a runtime instruction loop:
`run` static-dispatches on node types; `Pure`/`Mapped`/`Chained` lower to
nested inlined calls on the current fiber (`e.map!f.map!g` fuses to
`g(f(…))`), and only `Zipped`/`Retried`/`Deadlined` touch the scheduler — by
calling `sc.spawn`/`retry`/`timeout`. The veneer has no semantics of its own;
parity with the direct core holds by construction and is enforced by the M12
parity suite.

## 13. Public API surface

Re-exported from `sparkles.event_horizon` (`package.d`):

| Area         | Symbols                                                                                                                                                                                                           |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Errors       | `IoError`, `IoErrorStage`, `OpKind`, `NoGcHook`, `IoResult`, `ioOk`, `ioErr`, `fromRes`                                                                                                                           |
| Causes       | `Cause`, `Interrupt`, `InterruptKind`, `Outcome`, `widen`                                                                                                                                                         |
| Tier A       | `EventLoop`, `DefaultLoop`, `LoopConfig`, `RunStatus`, `OpHandle`, `OpClass`, `Completion`, `CompletionFlags`, `OpCallback`, op descriptors, `SockAddr`, `KernelTimespec`, `BackendConfig`, `Waker`, `LoopHandle` |
| Buffers      | `Buf`, `BufOrigin`, `BufGroupId`, `BufResult`, `BufferPool`, `BufRing`, `isOwnedIoBuf`                                                                                                                            |
| Probing      | `BackendCaps`, `BackendId`, `LoopMode`, `ModePolicy`, `probeSystem`                                                                                                                                               |
| Tier B       | `Sched`, `SchedOptions`, `RootScope`, the `io` verbs, `Stream`, `Listener`, `DgramSocket`, `FileHandle`, `currentTask`                                                                                            |
| Scopes       | `Scope`, `isScope`, `withScope`, `withDeadline`, `protect`, `checkCancellation`, `JoinHandle`, `ScopeOptions`, `OnChildFailure`                                                                                   |
| Capabilities | `isCapability`, `Ctx`, `ctx`, `CtxOf`, `hasCaps`, `isWaker`, `isFiberExecutor`, `isClock`, `TestClock`, `isNet`, `isByteStream`, `SimNet`, `TestSched`, `advanceAndSettle`, `ipv4`, `ipv6`, `unixSocket`, `Env`   |
| Schedules    | `recurs`, `spaced`, `exponential`, `jittered`, `upTo`, `retry`, `repeat`, `timeout`, `race`                                                                                                                       |
| Topology     | `LoopGroup`, `LoopGroupConfig`, `Topology`                                                                                                                                                                        |
| Veneer (M12) | `succeed`, `effect`, `map`, `andThen`, `zipPar`, `withRetry`, `withTimeout`, `run`                                                                                                                                |

Attribute policy (normative): non-template functions carry explicit
`@safe`/`pure`/`nothrow`/`@nogc` where true; templates and anything generic
over a backend, buffer, capability, or callable let attributes infer;
`@trusted` appears only on minimal syscall-edge lambdas and the documented
address-pinning seams (§8.1). Ref-returning accessors use bare
`return` (ReturnRef) — adjacent `return scope` means ReturnScope and is
reserved for functions returning pointer-carrying values (`Buf.opSlice`);
template inference masks the difference, non-templates do not. Unittests
static-assert the inferred attributes of
`EventLoop!UringBackend.submit`/`runOnce` and the `io` verbs.
