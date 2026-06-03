# Effect Systems & Event Loops

How a runtime turns **"suspend on an I/O operation"** into **"resume on its
completion"** — and where the event loop (epoll readiness, `io_uring` completion, a
thread pool) sits in that round trip. This is the cross-cutting companion to the
language-specific deep-dives: it surveys the _suspension mechanism_ (algebraic effect,
delimited continuation, stackful fiber, virtual thread, `Future`/`Waker` poll, stack
switch) independently of the _backend_ that actually waits on the kernel.

> **Scope.** This document is survey question Q5. It does **not** re-explain each
> system's effect model — for that, follow the cross-links into the
> [algebraic-effects corpus][ae-index]. It explains the _interplay_: the moment a
> computation says "I am blocked on this read" and the moment the loop says "your read
> is done, run on." The canonical worked example — an OCaml 5 `Suspend` effect handed to
> the `eio_linux` scheduler, resumed by an `io_uring` CQE — lives in
> [Eio's io_uring backend][eio-backend]; read that first if you want the mechanics in
> full source detail. Here we generalise it across nine families of runtime.

---

## The universal shape

Every async runtime in this survey, no matter how different its surface syntax, is built
from the same five moving parts. The differences are entirely in _how_ each part is
realised and _which_ are hidden from the programmer.

| Part              | What it is                                                            | Realisations across systems                                                                                            |
| ----------------- | --------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| **Suspend**       | The act of giving up the CPU at an I/O call                           | `perform Suspend` (effect), `Fiber.yield` (stackful), `Continuation.yield`, `Future::poll → Pending`, `suspend` (Wasm) |
| **Reified state** | What "the rest of this computation" is captured as                    | One-shot delimited continuation, saved stack/registers, a state-machine struct, an instruction tree                    |
| **Registration**  | Telling the loop what to wait for, tagged so the result can be routed | SQE with `user_data`, epoll interest set keyed by `pollDesc`, a `Waker` in a slot                                      |
| **Wait / demux**  | The blocking call that learns what is ready/done                      | `io_uring_enter` (CQE), `epoll_wait` (readiness), `kqueue`, GCD, a thread pool's blocking syscall                      |
| **Resume**        | Delivering the result back into the suspended computation             | `continue k v`, `Fiber.call`, `goready`, `Waker::wake` → re-poll, `resume` (Wasm)                                      |

The survey-central question — _how does a kernel completion map back onto a suspended
computation?_ — is answered by the **Registration → Wait → Resume** triangle. The tag
attached at registration (`user_data`, a `pollDesc`, a slot index) is the thread that the
loop pulls to find the right Suspend and undo it. Whether that "undo" is a single
machine-level `continue` of a captured continuation or a re-`poll` of a future is the
main axis of variation.

There are two orthogonal classifications worth fixing up front:

- **Readiness vs. completion** (the _backend_ axis, covered in
  [primitives][primitives] and [techniques][techniques]). A _readiness_ loop
  (epoll/kqueue) tells you _when_ an fd is ready and you do the syscall+copy yourself; a
  _completion_ loop (`io_uring`, IOCP) does the syscall in the kernel and hands you the
  finished result. The [Eio backend][eio-backend] shows both: `io_uring` CQEs _are_ the
  wakeup, while `eio_posix` resumes a fiber with "the fd is ready, now go read."
- **Effects-as-values vs. hidden suspension** (the _frontend_ axis, this document). Does
  the language reify "the rest of the computation" as a first-class object the program
  can name and a handler can install — or is suspension an invisible runtime service the
  programmer never sees? OCaml/Koka/WasmFX sit at the first pole; Go/Loom sit at the
  second; the fiber-runtime libraries (ZIO, Cats Effect, Effect-TS) and stackful-fiber
  designs (Zig, Seastar) sit in between.

---

## The spectrum, end to end

We walk the spectrum from "the continuation is a first-class language value with a
user-installable handler" to "there is no continuation the program can ever see."

### 1. Native one-shot continuations: OCaml 5 effects + Eio

OCaml 5 is the purest realisation of the universal shape, because every part is a
language primitive. An I/O call `perform (Suspend f)` transfers control to the nearest
handler, which receives a **one-shot delimited continuation** `k` representing the rest
of the fiber. The scheduler stores `k` (boxed in a `Suspended.t` record), submits the
operation to the loop, and returns to its run loop. When the result arrives, the
scheduler calls `Effect.Deep.continue k v` — and the original `perform` site _returns_
`v`, so the fiber runs forward in ordinary direct style. See
[OCaml 5 effects][ocaml-effects] for the handler model (`match_with`, `effc`, deep vs.
shallow) and [Eio's capabilities API][ocaml-eio] for the user-facing concurrency model.

The mechanics, fully sourced, are in [Eio's io_uring backend][eio-backend]. The essential
mapping there:

- **Suspend** = `perform (Enter fn)` or the generic `perform (Suspend f)`.
- **Reified state** = a `Suspended.t = { fiber; k }`, where `k` is the one-shot
  continuation captured by `Effect.Deep.match_with`.
- **Registration** = an `io_uring` SQE whose `user_data` is a typed `io_job` value (e.g.
  `Job k`) — _the continuation is literally stored inside the submission_.
- **Wait** = `Uring.wait` / `get_cqe_nonblocking` (`io_uring_enter`).
- **Resume** = `handle_complete` pattern-matches the CQE's `io_job` tag and calls
  `Suspended.continue k result`, i.e. `Effect.Deep.continue`.

The slogan from that doc: _a CQE is decoded into a `continue` of the exact continuation
that was suspended at the I/O call site._ No callback, no promise, no monad — the kernel
result flows straight back into the fiber's stack. On kernels without `io_uring`, the same
`Suspend`/`Fork` effect interface is interpreted by `eio_posix`, a `ppoll` _readiness_
scheduler with the identical run-queue skeleton; the effect interface is the portable
contract and the scheduler is the swappable interpreter.

Why **one-shot** matters here: because each continuation is resumed exactly once, the
runtime can resume _in place_ (no stack copy), and a complete-vs-cancel race is safe by
construction — exactly one of `continue`/`discontinue` ever fires (see
[OCaml 5 effects, performance][ocaml-effects] and the cancellation section of the
[Eio backend][eio-backend]). The cost is that backtracking / multi-shot patterns
(nondeterminism) are ruled out, which is fine for I/O scheduling.

### 2. Multi-prompt delimited control in C: Koka and the libuv-wrapping lineage

[Koka][koka] tracks effects in the type system (row-polymorphic effect rows) and compiles
handlers via **evidence passing** — threading a vector of handler implementations so an
operation finds its handler by O(1) index rather than a runtime stack walk (see
[Koka][koka] and the deeper [theory & compilation][theory-compilation] treatment). Koka's
operation kinds (`fun` tail-resumptive, `ctl` general, `final ctl` non-resuming) are a
direct knob on the Suspend/Resume cost: a tail-resumptive `fun` op never captures a
continuation at all and compiles to a direct call, while only a `ctl` op pays for a
delimited capture. For an event loop this means "register interest" can be a `ctl`
operation that captures the continuation and parks it, while cheap synchronous queries
stay allocation-free.

The C-level substrate under this style is **multi-prompt delimited control**: the
[libmprompt][libmprompt] library (from the Koka project) provides in-place growable
stacklets and multi-prompt `mp_prompt`/`mp_yield` primitives — the low-level analogue of
OCaml's fiber stacks, but as a portable C library rather than a runtime. The same delimited-
control style can be layered over an existing callback loop: a library function that would
normally take a completion callback instead `perform`s/`mp_yield`s an async effect, the
handler registers the request and yields, and the callback resumes the captured continuation
with the result (Daan Leijen's earlier `libhandler`-based `nodec` experiment wrapped libuv
this way). This is precisely the OCaml/Eio pattern, expressed in C over a _readiness+thread-
pool_ loop ([libuv][libuv]) instead of `io_uring`: the event loop is unchanged; the
delimited-control library is what turns its callbacks into straight-line code.

| Part          | Koka / libmprompt + nodec                                                               |
| ------------- | --------------------------------------------------------------------------------------- |
| Suspend       | `ctl` operation / `mp_yield` to a prompt; nodec `perform` of an async op                |
| Reified state | Multi-prompt delimited continuation (in-place growable stacklet)                        |
| Registration  | libuv request (`uv_read_start`, `uv_fs_*`) with the continuation as the callback's data |
| Wait / demux  | `uv_run` (epoll/kqueue/IOCP readiness + worker threadpool)                              |
| Resume        | libuv callback invokes `resume`/`mp_resume` with the result                             |

### 3. Hidden continuations / virtual threads: Java Loom and Go goroutines

Here the continuation still exists — it is a real captured stack — but the _programmer
never names it_. There is no `perform`, no handler, no `Future`. You write blocking-
looking code; the runtime does the Suspend/Resume invisibly.

**Java Loom** ([deep-dive][java-loom], [JVM async-I/O landscape][java]). A virtual thread
is a `java.lang.Thread` backed internally by a `jdk.internal.vm.Continuation` — a scoped,
stackful, **one-shot delimited continuation** that is _not_ part of the public API. When
a virtual thread blocks on a socket read, the JVM calls `Continuation.yield`, unmounts the
virtual thread from its carrier (a `ForkJoinPool` platform thread), and frees the carrier
to run another virtual thread. The blocked operation is registered with the JDK's NIO
_netpoller_ (epoll/kqueue/IOCP readiness); when it fires, the virtual thread is remounted
and `Continuation.run` resumes it. As the Loom doc notes, this is structurally identical
to an effect handler — blocking I/O is the "effect," the virtual-thread scheduler is the
"handler" — but Loom deliberately keeps the continuation private (safety, evolvability),
so you _cannot_ build generators or custom effect handlers on it. The loop is readiness-
based; Loom does **not** use `io_uring`, though it composes with an `io_uring`-backed blocking
facade for files (where readiness has no meaning — see [JUring + Loom][java]).

**Go goroutines** ([netpoller deep-dive][go-netpoller]). Go reaches the same direct-style
win a decade earlier and even more invisibly: there is _no user-facing event loop at
all_. A goroutine is a stackful green thread; `conn.Read(buf)` looks blocking. Under the
hood `poll.FD.Read` issues a non-blocking `read(2)`, and only on `EAGAIN` does it call
`runtime_pollWait → netpollblock → gopark`, which parks the goroutine off its OS thread.
The per-fd `pollDesc` holds the parked goroutine pointer in its `rg`/`wg` slot — _that is
the "reified continuation," a `g` pointer rather than a delimited `k`_. `netpoll(delay)`
(`epoll_wait`) returns a list of newly-ready goroutines; the scheduler transitions each
to runnable via `goready`, and the goroutine resumes _inside_ `netpollblock` just after
`gopark`, re-issues `read`, and now succeeds. The continuation is the whole goroutine
stack; the program never sees it. Like Loom, Go is firmly readiness/epoll and has
[declined io_uring in the runtime][go-netpoller] (issue #31908, Unplanned).

**Haskell green threads** ([deep-dive][haskell]). GHC's threaded RTS is the third
hidden-continuation runtime here, and the closest sibling to Go: the runtime _owns_ the
loop and multiplexes millions of cheap green threads onto a few OS-thread "capabilities".
A green thread doing `recv` calls `threadWaitRead`, which registers the fd with the in-RTS
**IO manager** (the MIO reactor — one `epoll`/`kqueue` instance _per capability_) and parks
the green thread on an `MVar`-style wait, yielding the capability without blocking the OS
thread; when the fd is readable the IO manager's callback completes the wait and the
scheduler re-runs the green thread, which retries the now-succeeding syscall. The reified
continuation is the whole green-thread stack (parked by the RTS, not nameable by the
program), and Suspend/Resume is park/unpark — exactly Go's shape, readiness-based and with
no user-facing loop. The twist for this survey is the _block-I/O_ gap: regular files have
no readiness signal, so file reads go to a blocking safe-FFI OS thread, and the separate
[`blockio-uring`][haskell] _library_ (not the RTS) closes that with `io_uring` — but as a pure
_batching_ layer with **no continuation machinery of its own**: its "suspension" is an
ordinary `takeMVar` on the submitting green thread (cheap precisely because layer 1 makes
green-thread blocking free), woken when a per-capability completion thread reaps the CQE and
`putMVar`s the result. There is no `io_uring` in the RTS itself (an unmerged, multi-year
proposal), so Haskell's _network_ path stays readiness/`epoll` while its fastest _disk_ path
is completion/`io_uring` — a split worth noting for a completion-first design.

The shared lesson: a **stackful green thread _is_ a reified continuation**; parking it is
Suspend and `goready`/remount is Resume. Hiding it buys a zero-learning-curve programming
model at the cost of giving up user-defined effects.

### 4. Instruction / fiber runtimes: ZIO, Cats Effect, Effect-TS

This family reifies the computation as **data** rather than as a stack or a native
continuation: an `IO`/`ZIO`/`Effect` value is an immutable _tree of instructions_ that a
runtime interpreter (a trampolined "fiber loop") walks. There is no language-level
continuation; "the rest of the computation" is the interpreter's own continuation stack
of pending instructions. Async is bolted on via a single primitive — variously
`Async.async`, `ZIO.async`, `Effect.async` — that hands the runtime a _register-a-
callback_ function:

> "Run this side-effecting registration now; when the external thing completes, call this
> callback with the result, and I (the runtime) will schedule the fiber to continue."

That callback, when invoked from the event-loop thread, **enqueues a resume message for
the fiber** onto the work-stealing scheduler; the fiber is then picked up by some worker
thread and its instruction walk continues from where the `async` node paused. So the
Suspend is "interpreter parks this fiber and records the async node," and the Resume is "a
callback fired from the loop posts a message that re-admits the fiber to the run queue."

| System                     | Reified state                 | "Suspend" primitive | Resume trigger                         | Backend / loop                                                             |
| -------------------------- | ----------------------------- | ------------------- | -------------------------------------- | -------------------------------------------------------------------------- |
| [Cats Effect][cats-effect] | `IO[A]` instruction tree      | `Async[F].async`    | callback → enqueue fiber on WS pool    | epoll/kqueue selector thread; **`io_uring` integrated runtime (CE 3.6.0)** |
| [ZIO][zio]                 | `ZIO[R,E,A]` instruction tree | `ZIO.async`         | callback → enqueue fiber on WS pool    | JVM NIO selector / blocking pool                                           |
| [Effect-TS][effect-ts]     | `Effect<A,E,R>` (generators)  | `Effect.async`      | callback → enqueue fiber on event loop | Node.js / browser event loop (libuv under Node)                            |

Two notes that connect to the rest of the survey:

- **Cats Effect's `io_uring` integration** (CE 3.6.0's "integrated runtime") is the most
  directly relevant point for an `io_uring`-first design: rather than a separate selector
  thread, the fiber scheduler drives an `io_uring` ring, with a reported ~3.5x throughput
  improvement for http4s Ember HTTP microservices ([Cats Effect][cats-effect]). The
  `Async.async` callback is completed from a CQE instead of an epoll readiness event — the
  same Registration→Wait→Resume triangle, now completion-based.
- These are **fiber runtimes, not algebraic-effect handlers**. ZIO and Cats Effect have a
  _fixed_ effect set (typed-error + environment channels, or a typeclass hierarchy), not
  arbitrary user-defined operations with resumable handlers; Effect-TS is explicitly an
  "industrial effect framework adjacent to algebraic handlers." The continuation is the
  interpreter's, captured as data, resumed by re-entering the interpreter — closer to a
  free-monad fold than to OCaml's stack switch. The cross-cutting effect-system framing is
  in the [algebraic-effects comparison][ae-comparison].

**Lean 4 `Std.Async`** ([deep-dive][lean]) is a fourth point on this family, even though it
has no fiber interpreter and no effect system: its reified state is an **unresolved
`Task`**, and the "register a callback" role is played by an `IO.Promise`. Every backend
primitive (`Timer.next`, `TCP.connect`, `recv?`, …) arms a [libuv][libuv] request and
returns an `IO.Promise α` — and crucially an `IO.Promise` _is literally a pre-allocated
`Task` token_ (`o->m_result = t` in the C runtime), so `await` is just `Task.bind` and
"suspending" means "this task isn't resolved yet." Suspend = "return an unresolved promise";
Resume = the libuv completion callback (running on Lean's single dedicated loop thread)
calls `lean_promise_resolve`, i.e. `g_task_manager->resolve(...)`, which fulfils the token
and schedules the bound continuation onto Lean's ordinary task worker pool. There is **no
continuation capture and no handler** — it is the instruction/poll family's
register-a-callback shape, but with the kernel side driven by a libuv _readiness_ reactor
(`epoll`/`kqueue`/event-ports/IOCP, **no io_uring**) rather than a CQE. It is the other
"libuv from a managed language" data point alongside Python's uvloop, differing only in
that the callback resolves a `Task` instead of resuming a coroutine frame.

**Unison abilities** ([deep-dive][unison]) sit between this family and §1: Unison reifies
async as a true **algebraic effect** (an _ability_), so the frontend is genuinely
effects-as-values — but the _runtime_ is an ANF-bytecode abstract machine (written in
Haskell) that captures **delimited continuations on its own `K` stack** when an ability
request is handled, much like the instruction-tree runtimes capture the interpreter's
continuation. The backend is not an event loop at all: every `IO`/concurrency primitive is
bridged straight to the **GHC runtime system** (`forkIO`/`MVar`/`threadDelay`/STM), so
Unison ultimately rides on the same RTS IO manager (epoll/kqueue green threads) described
for [Haskell][haskell] — there is no `io_uring` and no Unison-level loop. Suspend = an ability
`Request` captures the machine continuation; Resume = the handler resumes it, with the actual
_waiting_ delegated to the GHC RTS underneath. It is the survey's example of a real
effect-handler frontend layered over a hidden-continuation green-thread backend.

Rust's [Tokio][tokio] belongs to the same _frontend_ family with a crucial twist: the
reified state is a **compiler-generated state-machine `Future`**, and the "register a
callback" role is played by the `Waker`. `poll` returns `Pending` after stashing the
task's `Waker` in the resource's slot (e.g. mio's epoll registration); when the reactor
sees readiness it calls `Waker::wake`, which re-schedules the task to be `poll`ed again.
Suspend = "return `Pending`"; Resume = "`wake` → re-`poll`." Tokio's loop is readiness/mio
by default with an _experimental_ `io_uring` backend; the completion-native Rust thread-per-
core runtimes are [Glommio][glommio] and [Monoio][monoio].

### 5. Stackful-fiber backends without effects-as-values: Zig std.Io, Seastar, Glommio

These designs get direct-style, blocking-looking suspension from **stackful fibers**
(context switches), but expose _no_ effect or continuation as a language value — the fiber
is an implementation detail of a library or framework, not a `perform`-able operation.

**Zig `std.Io`** ([deep-dive][zig-io]) is the sharpest illustration because it reaches
the _same goal as Eio_ — colorless, direct-style I/O selectable between blocking and
evented backends — _without_ effects and _without_ a coroutine transform. `Io` is a plain
value (a `userdata + *const VTable` fat pointer) threaded explicitly through code, "the
same capability-passed-as-a-value intuition that Eio reaches through OCaml 5 effect
handlers, but Zig does it without effects." On the `Io.Uring` backend, an I/O call parks a
stackful fiber: it fills an SQE tagged with the _fiber pointer_ as `user_data`, yields to
the thread's idle context, and the idle loop (the reactor) drains CQEs, recovers the
parked fiber from `cqe.user_data`, writes the result into the fiber's slot, and re-queues
it as ready. That is _exactly_ the Eio mapping — except the reified state is a saved
register set on a fiber stack, not a delimited continuation, and there is no handler the
program can install. `Io.Threaded` runs the same source on a blocking thread pool; the
choice is made at the construction site, not in the function's type (no function
coloring).

**Seastar** ([deep-dive][seastar]) and **Glommio** ([deep-dive][glommio]) are thread-per-
core, share-nothing runtimes. Seastar's user-facing concurrency is _future/promise
continuations_ (a `.then()` chain — closer in spirit to the instruction-runtime family),
with C++20 coroutines (`co_await`) layered on for direct-style code; either way
one reactor is pinned per core over a pluggable backend (linux-aio, epoll, `io_uring`) and
there is no cross-core shared state — wakeups between shards are explicit lock-free
messages. Glommio is the Rust thread-per-core sibling: native `async`/`await` `Future`s
(so technically the poll/`Waker` model of §4) but **completion-native on `io_uring` with no
reactor fallback** (Linux-only by construction). Its ByteDance cousin [Monoio][monoio] is
the same thread-per-core + `Future`/`Waker` shape but keeps an _optional_ epoll/kqueue
fallback driver (via mio) for kernels and platforms without `io_uring`. Both make the same
architectural bet as a prospective Sparkles loop — one `io_uring` ring per core, cross-core
handoff by message — without any algebraic-effects machinery.

The takeaway for §5: **you do not need language-level effects to get direct-style async.**
A stackful fiber plus a tagged SQE (`user_data` = fiber pointer) is sufficient, and it is
the design every `io_uring` runtime in this survey actually uses at the bottom — Eio's
`Suspended.t`, Zig's `*Fiber`, and a D `Fiber*` are the _same idea_ wearing different
type-system clothes. Effects add _user-installable handlers_ and (with a type system)
_static effect tracking_; they do not change the Suspend→Register→Wait→Resume plumbing.

### 6. Stack switching as a compilation target: WasmFX

[WasmFX][wasmfx] (the WebAssembly typed-continuations / stack-switching proposal, Phase 3
as of early 2026) is not a runtime but a _target_: a minimal set of instructions
(`cont.new`, `suspend`, `resume`, `cont.bind`, `resume_throw`, `switch`) onto which
compilers can lower async/await, generators, coroutines, lightweight threads, _and_
effect handlers. A control tag is a "resumable exception" carrying a payload type and a
resume type; `suspend $tag` reifies the current stack as a `(ref $ct)` continuation and
hands it to the matching `(on $tag …)` clause of an enclosing `resume`. Continuations are
**one-shot** (linear) — the same constraint as OCaml 5 and Loom, and for the same reasons
(no GC of continuation objects, in-place resume).

WasmFX matters to event loops in two ways. First, it is the substrate on which a language
like OCaml or Koka could _compile_ its effect-based scheduler to Wasm: `perform` lowers to
`suspend`, the handler to `resume` clauses, and the host's event loop (a JS Promise, a
WASI poll) drives the wait. Second, it makes the Suspend/Resume _itself_ a portable
instruction rather than a per-language runtime hack (CPS or Asyncify whole-program
transforms), preserving the natural call stack so debuggers and backtraces keep working.
The lowering table in the [WasmFX doc][wasmfx] is explicit that effect handlers,
lightweight threads, and async/await all map to the same tags+resume mechanism — i.e. the
universal shape, standardised as bytecode.

---

## The cost / compilation angle

_Why_ a system chose effects, fibers, or a state machine is largely a question of what the
Suspend/Resume costs and what the compiler can prove. The
[theory & compilation][theory-compilation] and [parallelism][parallelism] docs cover this
in depth; the load-bearing facts for an event-loop designer:

- **Tail-resumptive operations are free.** The overwhelming majority of effect operations
  in real programs resume the continuation in tail position and do nothing after — these
  need _no_ continuation capture at all and compile to a direct call (Leijen reports up to
  ~150M tail-resumptive ops/sec vs ~10M for full capture in his C implementation). For an
  event loop, this means cheap synchronous primitives (read a clock, check a flag) cost
  nothing, while only the genuinely-blocking "register and wait" operation pays for a
  delimited capture. Koka's `fun`/`ctl` split and evidence passing exist to exploit
  exactly this; see [theory & compilation][theory-compilation].
- **Direct stack manipulation is the fastest _blocking_ mechanism.** OCaml 5 fibers, GHC
  primops, WasmFX, and (informally) every stackful-fiber runtime here use native call
  conventions with zero CPS/monadic overhead on the fast path — at the cost of requiring
  runtime support. This is why Eio reports "no per-await heap promise as in Lwt": a
  suspend is a continuation capture, a resume is one `continue`.
- **State-machine/poll models trade allocation for portability.** Rust's `Future`s
  (Tokio/Glommio/Monoio) and the instruction-tree runtimes (ZIO/Cats Effect/Effect-TS)
  avoid runtime stack-switching support, but pay with state-machine size or per-bind
  interpreter overhead, and need a `Waker`/callback to re-admit the task — the indirection
  the stackful designs skip.
- **One-shot is the universal pragmatic choice.** OCaml 5, Loom, WasmFX, and Zig fibers
  are all one-shot/linear. Multi-shot (backtracking, nondeterminism) is a research
  frontier, and [parallel algebraic handlers][parallelism] (combining handlers with
  multicore resumption) is newer still — neither is needed for an I/O scheduler, where
  each in-flight operation corresponds to exactly one suspended computation.

---

## Master comparison table

Each system mapped onto the universal shape. "One-shot?" refers to the reified
continuation; "Event loop / backend" is the wait mechanism that triggers resume.

| System                              | Suspend mechanism                                         | Resume trigger                                         | Continuation kind (one-shot?)                                  | Event loop / backend                                                                                                               |
| ----------------------------------- | --------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| **OCaml 5 + Eio** [→][eio-backend]  | `perform (Suspend/Enter f)` effect                        | `Effect.Deep.continue k v` from a CQE/readiness        | Native delimited continuation — **one-shot**                   | `io_uring` completion (`eio_linux`); `ppoll` readiness (`eio_posix`)                                                               |
| **Koka + nodec** [→][koka]          | `ctl` operation / `mp_yield` to a prompt                  | libuv callback invokes `resume`                        | Multi-prompt delimited control — one-shot (scoped)             | libuv (epoll/kqueue/IOCP readiness + threadpool)                                                                                   |
| **Java Loom** [→][java-loom]        | `Continuation.yield` (hidden, on blocking I/O)            | remount + `Continuation.run` on NIO readiness          | Hidden stackful continuation — **one-shot**                    | JDK NIO netpoller (epoll/kqueue/IOCP readiness)                                                                                    |
| **Go goroutines** [→][go-netpoller] | `gopark` on `EAGAIN` (hidden)                             | `goready` from `netpoll` ready-list                    | Whole goroutine stack (`g` ptr) — **one-shot**                 | Runtime netpoller (epoll/kqueue/IOCP readiness)                                                                                    |
| **Cats Effect** [→][cats-effect]    | `Async[F].async` parks fiber at instruction               | callback → enqueue fiber on work-stealing pool         | Instruction-tree (interpreter cont.) — one-shot                | epoll/kqueue selector; **`io_uring` integrated (CE 3.6.0)**                                                                        |
| **ZIO** [→][zio]                    | `ZIO.async` parks fiber at instruction                    | callback → enqueue fiber on work-stealing pool         | Instruction-tree (interpreter cont.) — one-shot                | JVM NIO selector + blocking pool                                                                                                   |
| **Effect-TS** [→][effect-ts]        | `Effect.async` parks fiber                                | callback → enqueue fiber on event loop                 | Generator/instruction (interpreter cont.) — one-shot           | Node.js / browser loop (libuv under Node)                                                                                          |
| **Tokio** [→][tokio]                | `Future::poll → Pending`, stash `Waker`                   | `Waker::wake` → re-`poll` the task                     | Compiler state-machine `Future` — one-shot                     | mio readiness (epoll/kqueue/IOCP); experimental `io_uring`                                                                         |
| **Zig std.Io (Uring)** [→][zig-io]  | stackful `fiber` context switch (`ev.yield`)              | idle reactor recovers `*Fiber` from `cqe.user_data`    | Saved register set on fiber stack — **one-shot**               | `io_uring` completion (`Io.Uring`); thread pool (`Io.Threaded`)                                                                    |
| **Seastar** [→][seastar]            | `.then()` continuation / `co_await` coroutine             | reactor runs the continuation on completion            | Future/promise chain (or C++20 coroutine frame) — one-shot     | thread-per-core: epoll / linux-aio / `io_uring`                                                                                    |
| **Glommio / Monoio** [→][glommio]   | `Future::poll → Pending` (thread-per-core)                | `Waker::wake` from `io_uring` CQE                      | Compiler state-machine `Future` — one-shot                     | `io_uring` completion, one ring fabric per core (Glommio: Linux-only, no fallback; Monoio: optional epoll/kqueue fallback via mio) |
| **WasmFX** [→][wasmfx]              | `suspend $tag` reifies stack as `(ref $ct)`               | `resume`/`switch` the continuation                     | Typed continuation `(ref $ct)` — **one-shot** (linear)         | host loop (JS Promise / WASI poll) — it is a _target_, not a loop                                                                  |
| **Haskell (GHC RTS)** [→][haskell]  | `threadWaitRead`/`takeMVar` parks a green thread (hidden) | RTS IO manager callback / completion-thread `putMVar`  | Whole green-thread stack — **one-shot**                        | RTS MIO reactor (epoll/kqueue/IOCP, per-capability); `blockio-uring` `io_uring` for block I/O                                      |
| **Lean 4 Std.Async** [→][lean]      | return an unresolved `IO.Promise` (a `Task` token)        | libuv callback → `lean_promise_resolve` → task manager | Pre-allocated `Task` token — one-shot                          | libuv readiness reactor (epoll/kqueue/event-ports/IOCP); no `io_uring`                                                             |
| **Unison abilities** [→][unison]    | ability `Request` captures the machine `K` stack          | handler resumes the delimited continuation             | Delimited continuation on the ANF machine `K` stack — one-shot | GHC RTS (`forkIO`/`MVar`/STM) — no event loop, no `io_uring`                                                                       |

Reading the table top to bottom is reading the frontend spectrum: language-native
effects (rows 1–2) → hidden continuations (rows 3–4) → instruction/poll runtimes
(rows 5–8) → stackful-fiber libraries (rows 9–11) → compilation target (row 12). Reading
the rightmost column is reading the _backend_ spectrum (readiness vs completion) — and
note that the two axes are independent: Eio and Zig are completion-native with a
language-native-effect vs. stackful-fiber-library frontend, while Go and Loom are both
readiness with a hidden-continuation frontend.

---

## Implications for a D event loop

D sits in a specific, well-defined spot on the spectrum, and that spot dictates what an
event-horizon loop _can_ and _cannot_ do. The full ecosystem survey and gap analysis is in
[the D landscape][d-landscape]; here is the effects-and-loops reading of it.

**What D has.** D ships **stackful fibers in druntime** (`core.thread.Fiber`): a
register save/restore + stack-pointer swap (hand-written assembly), `yield`/`getThis`/
`state` are `nothrow @nogc`, and a terminated fiber can be `reset` and reused. That is
_exactly_ the reified-continuation primitive of §5 — the same mechanism as a Go goroutine
stack, a Loom virtual thread's hidden continuation, or a Zig `*Fiber`. Combined with
[`during`][d-landscape] (a `@nogc nothrow betterC` `io_uring` SQE/CQE binding), D already has
both halves of the Registration→Wait→Resume triangle: a `Fiber` to park, and a `user_data`
slot on the SQE to tag it with. The loop is the gap — _park a `Fiber` on `Fiber.yield`,
store its pointer as the SQE's `user_data`, and on the CQE look the fiber up and call
`fib.call()` to resume._ This is the Eio/Zig mapping with `Fiber*` in the role of
`Suspended.t`/`*Fiber`.

**What D enables (the §5 sweet spot).**

- **Completion-native direct-style I/O with zero GC pressure.** Because `Fiber` switching
  is `@nogc` and `during` is `@nogc nothrow betterC`, the whole Suspend→Resume path can be
  allocation-free — something the GC-coupled D frameworks (vibe-core, Photon) cannot offer
  and that even Eio pays for with a GC-tracked closure per in-flight op. D can put the loop
  on the _completion_ side natively (`io_uring`) rather than emulating it on epoll.
- **Tagged-SQE resume with no lookup table.** Storing the `Fiber*` directly in `user_data`
  (as Eio stores `io_job` and Zig stores `*Fiber`) makes resume a pointer recovery, not a
  hash lookup — the technique the fastest runtimes here all use.
- **Thread-per-core sharding** (à la Glommio/Seastar) with one ring per core and
  `MSG_RING`/eventfd cross-core wakeups, using a lean `@nogc` channel for handoff in place
  of `std.concurrency`'s GC messages.
- **Colorless I/O without function coloring** in the Zig sense: a blocking-looking API on
  fibers, where the same code can run on an `io_uring` backend or a fallback, chosen at
  construction.

**What D precludes (no language-level effects/continuations).**

- **No user-installable handlers, no effects-as-values.** D has no `perform`/`handle`, no
  delimited-continuation primitive, and no row-typed effect system. You cannot write a
  generic `Suspend` effect that an arbitrary scheduler interprets, nor offer the
  user-extensible handler composition that OCaml/Koka provide. Suspension is a _library_
  service over `Fiber`, like Go/Loom/Zig — not a language feature. (This is the same
  trade-off Loom made deliberately, for the same simplicity reasons.)
- **No static effect tracking.** Unlike Koka's row types or Cats Effect's typeclass
  constraints, D's type system will not tell you which functions block; the `@safe`/`@nogc`/
  `nothrow`/`pure` attribute set is the closest analogue, and it constrains _purity and
  allocation_, not _which effects a function performs_. (Capability-passing in the Eio/Zig
  style — threading a loop handle explicitly — is the pragmatic substitute, and aligns with
  D's named-argument and DbI idioms.)
- **No multi-shot / no compiler CPS transform.** `Fiber` resumption is naturally one-shot
  (resume by `call`), which is _fine_ for I/O (one in-flight op ↔ one suspended fiber) and
  matches every `io_uring` runtime here, but it rules out backtracking-style control. There
  is no Koka-style selective-CPS or evidence-passing compilation to optimise tail-resumptive
  effects, because there are no effects to optimise — the unit of suspension is always a
  full fiber stack (the "memory tax" of M:N stackful scheduling that
  [the D landscape][d-landscape] flags).

**Net position.** D lands squarely in §5 — _stackful-fiber backend without effects-as-
values_ — alongside Zig `std.Io`, Seastar, and Glommio, and adjacent to Go/Loom on the
frontend axis (hidden suspension over a fiber) while differing from them on the backend
axis (completion-native `io_uring` rather than readiness epoll). It gets the direct-style
ergonomics and the fast tagged-SQE resume of the §1 systems _without_ their language-effect
machinery, at the cost of the user-extensible handlers and static effect tracking that
machinery buys. For how that niche compares to the cross-language field and what a
concrete Sparkles loop would add on top of `during` + `Fiber`, see
[the D landscape & gap analysis][d-landscape]; for the underlying readiness-vs-completion
mechanisms, see [primitives][primitives] and [techniques][techniques]; and for the
canonical end-to-end completion→continuation worked example to imitate, see
[Eio's io_uring backend][eio-backend].

---

## Sources

This is a synthesis document; every claim is sourced from the deep-dives it links. Primary
anchors:

- [Eio io_uring backend][eio-backend] — the canonical CQE → `continue` worked example
- [OCaml 5 effects][ocaml-effects] · [Eio capabilities][ocaml-eio] — native one-shot continuations
- [Koka][koka] · [theory & compilation][theory-compilation] — evidence passing, operation kinds, libmprompt
- [Java Loom][java-loom] · [Java async-I/O landscape][java] — hidden continuations / virtual threads
- [Go netpoller][go-netpoller] — goroutine park/unpark over epoll readiness
- [Cats Effect][cats-effect] · [ZIO][zio] · [Effect-TS][effect-ts] — instruction/fiber runtimes; CE `io_uring`
- [Tokio][tokio] · [Glommio][glommio] · [Monoio][monoio] — `Future`/`Waker` poll model; completion thread-per-core
- [Zig std.Io][zig-io] · [Seastar][seastar] — stackful fibers without effects-as-values
- [WasmFX][wasmfx] — stack switching as a compilation target
- [parallelism][parallelism] — parallel algebraic handlers (research frontier)
- [D landscape][d-landscape] — `core.thread.Fiber`, `during`, and the Sparkles gap

<!-- References -->

<!-- Sibling async-io docs -->

[eio-backend]: ./eio-backend.md
[go-netpoller]: ./go-netpoller.md
[java]: ./java.md
[zig-io]: ./zig-io.md
[tokio]: ./tokio.md
[glommio]: ./glommio.md
[monoio]: ./monoio.md
[seastar]: ./seastar.md
[libuv]: ./libuv.md
[haskell]: ./haskell.md
[lean]: ./lean.md
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[d-landscape]: ./d-landscape.md

<!-- Effect-system corpus -->

[ae-index]: ../algebraic-effects/index.md
[ae-comparison]: ../algebraic-effects/comparison.md
[ocaml-effects]: ../algebraic-effects/ocaml-effects.md
[ocaml-eio]: ../algebraic-effects/ocaml-eio.md
[koka]: ../algebraic-effects/koka.md
[java-loom]: ../algebraic-effects/java-loom.md
[cats-effect]: ../algebraic-effects/scala-cats-effect.md
[zio]: ../algebraic-effects/scala-zio.md
[effect-ts]: ../algebraic-effects/typescript-effect.md
[unison]: ../algebraic-effects/unison.md
[wasmfx]: ../algebraic-effects/wasmfx.md
[theory-compilation]: ../algebraic-effects/theory-compilation.md
[parallelism]: ../algebraic-effects/parallelism.md

<!-- External -->

[libmprompt]: https://github.com/koka-lang/libmprompt
