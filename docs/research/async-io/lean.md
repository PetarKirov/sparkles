# Lean 4 (Std.Async)

How a theorem prover's general-purpose programming side does async I/O: a libuv event loop running on its own runtime thread, where each "blocking-looking" I/O action starts a libuv request whose C callback resolves an `IO.Promise`, and that promise is just a `Task` token the existing Lean task scheduler can rejoin — no algebraic effects, no coroutines, just monadic `Task` plumbing over readiness/callback I/O.

| Field         | Value                                                                                             |
| ------------- | ------------------------------------------------------------------------------------------------- |
| Language      | Lean 4 (`Std.Async` shipped 4.17.0, 2025-03-03; TCP/UDP/Select in 4.20.0, 2025-06-02)             |
| License       | Apache-2.0                                                                                        |
| Repository    | [leanprover/lean4]                                                                                |
| Documentation | [Lean release notes] · [Lean 4.17.0 notes] · [Lean 4.20.0 notes]                                  |
| Key Authors   | Sofia Rodrigues, Henrik Böving, Markus Himmel, Mac Malone (Lean FRO)                              |
| Pattern       | Reactor (libuv `epoll`/`kqueue`/IOCP, callbacks) over Lean's `Task` scheduler — **no io_uring**   |
| Encoding      | Monadic: each I/O op returns an `IO.Promise` (a `Task` token); `await` = monadic bind on the task |

> **Scope.** This deep-dive covers two layers that ship inside the Lean 4 standard
> library and its C runtime: the user-facing `Std.Async` monad/typeclass API
> (`src/Std/Async/`) and the libuv-backed event-loop backend underneath it
> (`src/Std/Internal/UV/` plus the C runtime in `src/runtime/uv/`). All paths below
> are relative to the [Lean 4 repository][leanprover/lean4]. The central question the
> survey cares about: **how does a kernel-level I/O completion resume a suspended Lean
> computation?** The short answer — _a libuv callback running on Lean's dedicated
> event-loop thread calls `lean_io_promise_resolve`, which hands a value to the task
> manager; that fulfils the `Task` token the user's `await` was bound on, and Lean's
> ordinary task scheduler runs the continuation._ There is no continuation capture and
> no effect handler: the "suspension" is just an unresolved `Task`.

---

## Overview

### What it solves

Lean 4 is both a proof assistant and a general-purpose functional language; its
runtime already had a `Task` type and a work-stealing task scheduler for pure parallel
computation, but no first-class asynchronous I/O. `Std.Async` (added in Lean 4.17.0,
"implements a basic async framework as well as asynchronously running timers using
libuv", PR #6505) closes that gap by layering an async API over [libuv], the same C
event loop that backs Node.js. Networking (TCP/UDP), DNS, process/system queries,
signals, and an IO-multiplexing `Select` primitive followed in Lean 4.20.0 (PRs #8055,
#8078, #8139). libuv itself became a hard build dependency of Lean back in 4.12.0.

The design goal is _direct-style-looking_ code without coroutines or effects. A program
writes:

```lean
def main : IO Unit := do
  let task ← (Std.Async.sleep 100).toIO   -- returns an AsyncTask Unit
  -- ... do other work ...
  task.block                              -- join the result
```

`sleep` _looks_ like it blocks for 100 ms, but it actually arms a libuv timer and hands
back a `Task` (via an `IO.Promise`) that the rest of the program can `await` or `block`
on. The OS thread is never blocked: the libuv loop services the timer on its own thread
and resolves the promise when the deadline fires.

### Design philosophy

- **Monadic, not effectful.** Unlike OCaml Eio (which suspends a _fiber_ via
  [algebraic effects][eio-backend]) or Koka (which compiles [effect handlers][koka] to
  multi-prompt delimited continuations), Lean has no effect system in play here. The
  whole API is built from `Task`, `IO.Promise`, and monad transformers. "Awaiting" is
  literally `Task.bind`; "suspending" is "the `Task` isn't resolved yet."
- **The promise is the bridge.** Every backend primitive returns
  `IO (IO.Promise …)`. The fallible ones (`Socket.connect`, `Socket.recv?`,
  `DNS.getAddrInfo`, UDP `recv`, …) wrap the result as `IO (IO.Promise (Except IO.Error α))`;
  the infallible ones carry the bare value (`Timer.next : IO (IO.Promise Unit)`,
  `Signal.next : IO (IO.Promise Int)`), which is why the timer wrappers use the
  `ofPurePromise` constructor rather than the `Except`-decoding `ofPromise`. In all cases
  the C side stashes that promise in the libuv request's `data` field and resolves it from
  the completion callback. `IO.Promise`'s `result?`/`result!` expose the underlying `Task`,
  so promise resolution and task scheduling are the _same mechanism_.
- **Readiness/callback, not completion.** libuv is a reactor: it multiplexes readiness
  over `epoll` (Linux), `kqueue` (BSD/macOS), event ports (Solaris), or IOCP (Windows),
  and runs C callbacks when handles are ready, doing the actual non-blocking syscall
  inside the callback. Lean inherits exactly this model. There is **no io_uring** path;
  see [io_uring: the unified async interface][io-uring-index] for the proactor model
  Lean does _not_ use, and [libuv][libuv] for the shared backend.
- **One event loop on one dedicated thread.** Lean runs `uv_run` on a thread spawned at
  startup, guarded by a mutex; user `IO` actions on other threads lock the loop, mutate
  it, and nudge it via a `uv_async_t`. This makes the thread-unsafe libuv loop usable
  from Lean's multi-threaded task pool.

### Relationship to the rest of the survey

Lean shares its backend with two other entries in this corpus. [libuv][libuv] is the
identical C library; this doc focuses on how Lean _drives_ it and maps callbacks onto
`Task`s. Python's [uvloop][python-async] is the other "libuv from a managed language"
data point — but where uvloop drives coroutines via `epoll`/`kqueue` callbacks resuming
generator frames, Lean drives `Task`s via the same callbacks resolving promises. For the
broad picture of "the event loop as the interpreter of a suspension primitive", see
[Effects and event loops][effects-and-event-loops].

---

## Core abstractions and types

The vocabulary splits cleanly into the **Lean-level monadic API** (in `Std/Async/`) and
the **backend types** (in `Std/Internal/UV/` and the C runtime). The module docstring in
`src/Std/Async/Basic.lean` frames the layering as "Monadic Types" vs. "Concurrent Units
of Work".

### Concrete units of work: `Task`, `ETask`, `AsyncTask`

These are the _handles_ to in-flight or finished computations. From `Std/Async/Basic.lean`:

```lean
-- src/Std/Async/Basic.lean
abbrev ETask (ε : Type) (α : Type) : Type := ExceptT ε Task α
abbrev AsyncTask := ETask IO.Error
```

`Task α` is Lean's existing core task type (a value that _will_ resolve to an `α`,
scheduled on the runtime's task worker pool). `ETask ε α` is a `Task` that may carry an
error of type `ε` (it is `ExceptT ε Task α`, i.e. a `Task (Except ε α)`), and `AsyncTask`
fixes `ε = IO.Error`. The docstring is explicit that "These types should not be created
directly" — they are produced by `async` and consumed by `await`.

### Monadic contexts: `BaseAsync`, `EAsync`, `Async`

These wrap a _computation_ (not yet a task) so it can be chained with `>>=`/`do`. Again
from `Basic.lean`:

```lean
-- src/Std/Async/Basic.lean
@[expose] def BaseAsync (α : Type) := BaseIO (MaybeTask α)
@[expose] def EAsync (ε : Type) (α : Type) := BaseAsync (Except ε α)
abbrev Async (α : Type) := EAsync IO.Error α
```

- `BaseAsync` is an infallible async computation: a `BaseIO` that yields a `MaybeTask α`.
- `EAsync ε` adds an error channel of type `ε`.
- `Async = EAsync IO.Error` is the everyday alias — "an asynchronous computation that may
  produce an error of type `IO.Error`".

The `MaybeTask` optimization is worth noting: rather than always allocating a `Task`,
`BaseAsync` returns

```lean
-- src/Std/Async/Basic.lean
inductive MaybeTask (α : Type)
  | pure  : α → MaybeTask α        -- value already available, no task
  | ofTask : Task α → MaybeTask α  -- genuinely asynchronous
```

so a synchronous step in an `Async` pipeline never touches the scheduler — only a real
suspension produces a `Task`.

### The `MonadAsync` / `MonadAwait` typeclasses

The whole API is generic over two typeclasses (from `Basic.lean`):

```lean
-- src/Std/Async/Basic.lean
class MonadAwait (t : Type → Type) (m : Type → Type) where
  await : t α → m α

class MonadAsync (t : Type → Type) (m : Type → Type) where
  async (x : m α) (prio := Task.Priority.default) : m (t α)
```

`async` "extracts a concrete asynchronous task from a computation … runs the computation
in the background and returns a task handle"; `await` "takes a task and re-inserts it into
the monadic context … pausing to wait for that result". The instances thread these through
`StateT`/`ReaderT`/`ExceptT` (all marked `@[default_instance]`) so the API composes with
monad transformers. There are concrete instances such as `MonadAwait AsyncTask Async`,
`MonadAwait IO.Promise Async`, and `MonadAsync AsyncTask Async`. The docstring's advice:
prefer the higher-level combinators (`race`, `raceAll`, `concurrently`, `concurrentlyAll`,
`background`) over `async`/`await` directly.

### `IO.Promise` — the load-bearing bridge

This is the single most important type for understanding the backend. From
`src/Init/System/Promise.lean`:

```lean
-- src/Init/System/Promise.lean
structure Promise (α : Type) : Type where
  private prom : PromisePointed.type
  private h    : Nonempty α

@[extern "lean_io_promise_new"]
opaque Promise.new [Nonempty α] : BaseIO (Promise α)

@[extern "lean_io_promise_resolve"]
opaque Promise.resolve (value : α) (promise : @& Promise α) : BaseIO Unit

@[extern "lean_io_promise_result_opt"]
opaque Promise.result? (promise : @& Promise α) : Task (Option α)
```

A `Promise α` is "a `Task α` whose value is provided later by calling `resolve`".
`promise.result?` exposes that underlying `Task (Option α)` (the `none` case = the promise
was dropped without resolution, e.g. on cancellation), and `result!` is the panicking
variant. Crucially, the C implementation in `src/runtime/object.cpp` shows the promise
_is_ a task token:

```cpp
// src/runtime/object.cpp
obj_res lean_promise_new() {
    ...
    lean_task_object * t = (lean_task_object*)lean_alloc_small_object(sizeof(lean_task_object));
    ...
    lean_promise_object * o = ...;
    o->m_result = t; // the promise takes ownership of one task token
    return (lean_object *) o;
}
void lean_promise_resolve(obj_arg value, b_obj_arg promise) {
    g_task_manager->resolve(lean_to_promise(promise)->m_result, mk_option_some(value));
}
```

So **resolving a promise = handing a value to the task manager for an already-allocated
`Task` token.** Any `Task.bind`/`chainTask` continuation registered on that token becomes
runnable on Lean's task worker threads. This is why `await` can be "just monadic bind":
the bind is registered on the promise's task, and the libuv callback's `resolve` triggers
it.

### Backend handle types

In `Std/Internal/UV/` each domain has an opaque handle wrapping a libuv handle:

| Lean type (`Std.Internal.UV`)      | Wraps (libuv)           | Defined in                              |
| ---------------------------------- | ----------------------- | --------------------------------------- |
| `Loop` (functions only, no handle) | `uv_loop_t`             | `src/Std/Internal/UV/Loop.lean`         |
| `Timer`                            | `uv_timer_t`            | `src/Std/Internal/UV/Timer.lean`        |
| `TCP.Socket`                       | `uv_tcp_t`              | `src/Std/Internal/UV/TCP.lean`          |
| `UDP.Socket`                       | `uv_udp_t`              | `src/Std/Internal/UV/UDP.lean`          |
| `Signal`                           | `uv_signal_t`           | `src/Std/Internal/UV/Signal.lean`       |
| (DNS, System — functions only)     | `uv_getaddrinfo_t` etc. | `.../UV/DNS.lean`, `.../UV/System.lean` |

Each is a `private opaque … : NonemptyType` whose methods are `@[extern "lean_uv_…"]`
opaque calls into the C runtime, e.g. in `Timer.lean`:

```lean
-- src/Std/Internal/UV/Timer.lean
@[extern "lean_uv_timer_mk"]
opaque mk (timeout : UInt64) (repeating : Bool) : IO Timer

@[extern "lean_uv_timer_next"]
opaque next (timer : @& Timer) : IO (IO.Promise Unit)
```

`next` is the canonical shape: arm the libuv handle, return a promise that the
completion callback will resolve.

---

## How it works

### The event loop on a dedicated thread

libuv's `uv_loop_t` is not thread-safe, but Lean's task scheduler is multi-threaded.
`src/runtime/libuv.cpp` reconciles this by spawning the loop on its own thread at
runtime initialization:

```cpp
// src/runtime/libuv.cpp
extern "C" void initialize_libuv() {
    initialize_libuv_timer();
    initialize_libuv_tcp_socket();
    initialize_libuv_udp_socket();
    initialize_libuv_signal();
    initialize_libuv_loop();
    lthread([]() { event_loop_run_loop(&global_ev); });   // loop runs here, forever
}
```

There is a single global event loop, `event_loop_t global_ev`
(`src/runtime/uv/event_loop.h`), holding `uv_default_loop()` plus the synchronization
primitives that make it shareable:

```cpp
// src/runtime/uv/event_loop.h
typedef struct {
    uv_loop_t  * loop;      // The libuv event loop.
    uv_mutex_t   mutex;     // Mutex for protecting `loop`.
    uv_cond_t    cond_var;  // Condition variable for signaling that `loop` is free.
    uv_async_t   async;     // Async handle to interrupt `loop`.
    _Atomic(int) n_waiters; // Atomic counter for managing waiters for `loop`.
} event_loop_t;
```

The loop thread runs `UV_RUN_ONCE` in a loop, yielding the mutex whenever another thread
wants in (`src/runtime/uv/event_loop.cpp`):

```cpp
// src/runtime/uv/event_loop.cpp
void event_loop_run_loop(event_loop_t * event_loop) {
    while (uv_loop_alive(event_loop->loop)) {
        uv_mutex_lock(&event_loop->mutex);
        while (event_loop->n_waiters != 0) {
            uv_cond_wait(&event_loop->cond_var, &event_loop->mutex);
        }
        uv_run(event_loop->loop, UV_RUN_ONCE);
        uv_mutex_unlock(&event_loop->mutex);
    }
}
```

The file's own header comment explains the trick: the loop _always_ has the `uv_async_t`
registered, so `uv_run` never returns from running out of work; it returns only when
`uv_stop` is called from `async_callback`, which fires when another thread wants the
loop. That other thread takes the mutex via `event_loop_lock`:

```cpp
// src/runtime/uv/event_loop.cpp
void event_loop_lock(event_loop_t * event_loop) {
    if (uv_mutex_trylock(&event_loop->mutex) != 0) {
        event_loop->n_waiters++;
        event_loop_interrupt(event_loop);   // uv_async_send -> async_callback -> uv_stop
        uv_mutex_lock(&event_loop->mutex);
        event_loop->n_waiters--;
    }
}
```

So the protocol is: a Lean `IO` action that needs to touch libuv calls
`event_loop_lock` (which interrupts the running loop via `uv_async_send`), mutates the
loop (arms a timer, starts a read, …), then `event_loop_unlock` (which signals the
condition variable so the loop thread resumes `uv_run`). This is how the
thread-_unsafe_ libuv loop is safely shared by Lean's thread pool.

### From a "blocking-looking" I/O action to a libuv request

Trace a TCP connect. The user writes `Async.Client.connect`
(`src/Std/Async/TCP.lean`), which is a thin wrapper that turns the backend promise into
an `Async`:

```lean
-- src/Std/Async/TCP.lean
def connect (s : Client) (addr : SocketAddress) : Async Unit :=
  Async.ofPromise <| s.native.connect addr
```

`s.native.connect` is the `@[extern "lean_uv_tcp_connect"]` opaque from
`src/Std/Internal/UV/TCP.lean`, returning `IO (IO.Promise (Except IO.Error Unit))`. The C
side (`src/runtime/uv/tcp.cpp`) creates a fresh promise, stores it in the request's
`data`, locks the loop, and submits `uv_tcp_connect` with a completion callback:

```cpp
// src/runtime/uv/tcp.cpp
extern "C" LEAN_EXPORT lean_obj_res lean_uv_tcp_connect(b_obj_arg socket, b_obj_arg addr) {
    ...
    lean_object* promise = lean_promise_new();
    mark_mt(promise);
    connect_data->promise = promise;
    ...
    event_loop_lock(&global_ev);
    int result = uv_tcp_connect(uv_connect, tcp_socket->m_uv_tcp, (sockaddr*)&addr_struct,
        [](uv_connect_t* req, int status) {
            tcp_connect_data* tup = (tcp_connect_data*) req->data;
            lean_promise_resolve_with_code(status, tup->promise);   // <-- resolve here
            lean_dec(tup->socket);
            lean_dec(tup->promise);
            free(req->data);
            free(req);
        });
    event_loop_unlock(&global_ev);
    ...
    return lean_io_result_mk_ok(promise);
}
```

`lean_promise_resolve_with_code` (`src/runtime/uv/event_loop.cpp`) maps a libuv status
code into the `Except` and resolves:

```cpp
// src/runtime/uv/event_loop.cpp
void lean_promise_resolve_with_code(int status, obj_arg promise) {
    obj_arg res = status == 0 ? mk_except_ok(lean_box(0))
                              : mk_except_err(lean_decode_uv_error(status, nullptr));
    lean_promise_resolve(res, promise);
}
```

So the full resume path is:

1. The Lean action `connect` returns an unresolved `IO.Promise`; `Async.ofPromise` wraps
   it as an `Async Unit` whose `MaybeTask` is `ofTask promise.result?`.
2. The user `await`s it — under the hood this is `Task.bind` on the promise's task token.
   The Lean computation is now "suspended" only in the sense that this task isn't done.
3. The libuv loop thread, inside `uv_run`, sees the socket become writable, performs the
   connect, and invokes the registered C callback.
4. The callback calls `lean_promise_resolve`, i.e. `g_task_manager->resolve(...)` on the
   promise's task token.
5. The task manager marks the token resolved and schedules the bound continuation onto a
   Lean task worker thread, which runs the rest of the user's `do` block.

That is the whole trick, and it is deliberately _not_ a continuation capture: **the
"suspension" is an unresolved `Task`, and the libuv callback's job is to resolve it.**

### The readiness pattern: TCP `recv?`

`recv?` shows the reactor model most clearly. The Lean side
(`src/Std/Internal/UV/TCP.lean`) documents that the promise "resolves when data is
available", and the C side uses libuv's `uv_read_start` with an _allocation_ callback and
a _read_ callback:

```cpp
// src/runtime/uv/tcp.cpp  (lean_uv_tcp_recv, abridged)
int result = uv_read_start((uv_stream_t*)tcp_socket->m_uv_tcp,
  [](uv_handle_t* handle, size_t suggested_size, uv_buf_t* buf) {       // alloc_cb
      lean_uv_tcp_socket_object* s = lean_to_uv_tcp_socket((lean_object*)handle->data);
      buf->base = (char*)lean_sarray_cptr(s->m_byte_array);
      buf->len  = lean_sarray_capacity(s->m_byte_array);
  },
  [](uv_stream_t* stream, ssize_t nread, const uv_buf_t* buf) {         // read_cb
      uv_read_stop(stream);
      lean_uv_tcp_socket_object* s = lean_to_uv_tcp_socket((lean_object*)stream->data);
      lean_object* promise = s->m_promise_read;
      lean_object* byte_array = s->m_byte_array;
      s->m_promise_read = nullptr; s->m_byte_array = nullptr;
      if (nread >= 0) {
          lean_sarray_set_size(byte_array, nread);
          lean_promise_resolve(mk_except_ok(lean::mk_option_some(byte_array)), promise);
      } else if (nread == UV_EOF) {
          lean_dec(byte_array);
          lean_promise_resolve(mk_except_ok(lean::mk_option_none()), promise);   // none = EOF
      } else {
          lean_dec(byte_array);
          lean_promise_resolve(mk_except_err(lean_decode_uv_error(nread, nullptr)), promise);
      }
      lean_dec(promise);
      lean_dec((lean_object*)stream->data);
  });
```

This is textbook readiness/reactor: libuv multiplexes the socket via `epoll`/`kqueue`,
and when the fd is readable it calls back, allocates into a pre-sized `ByteArray`,
performs the non-blocking read, then resolves the socket's `m_promise_read`. The Lean
`Option ByteArray` return type maps directly: `some bytes` on data, `none` on EOF, an
`Except` error otherwise. Only one read may be outstanding per socket — a second `recv?`
while `m_promise_read != nullptr` returns `UV_EALREADY`.

### The timer state machine

Timers are the simplest end-to-end example and the first thing `Std.Async` shipped. The
backend `Timer` is a three-state machine — _initial → running → finished_ — driven from
both Lean (`Std/Internal/UV/Timer.lean`) and C (`src/runtime/uv/timer.cpp`). `Timer.next`
arms the libuv timer and returns the promise; the completion callback resolves it:

```cpp
// src/runtime/uv/timer.cpp
void handle_timer_event(uv_timer_t* handle) {
    lean_uv_timer_object * timer = lean_to_uv_timer((lean_object*)handle->data);
    if (timer->m_repeating) {
        if (timer->m_promise != NULL && !timer_promise_is_finished(timer))
            lean_dec(lean_io_promise_resolve(lean_box(0), timer->m_promise));
    } else {
        if (timer->m_promise != NULL)
            lean_dec(lean_io_promise_resolve(lean_box(0), timer->m_promise));
        uv_timer_stop(timer->m_uv_timer);
        timer->m_state = TIMER_STATE_FINISHED;
        lean_dec(obj);                    // loop no longer keeps the timer alive
    }
}
```

The high-level wrappers `Sleep` (one-shot) and `Interval` (repeating) live in
`src/Std/Async/Timer.lean`. `Sleep.wait` is just `Async.ofPurePromise s.native.next` —
arm the timer, await its promise. `Interval.tick` is the same over a repeating timer. Note
the documented hazard, copied verbatim from the source: if you `stop` a timer while another
`Async` is binding on its promise, "it will hang forever without further intervention" —
because nothing will ever resolve the dropped promise. (The dropped-promise case is why
`result?` returns an `Option`: a dropped promise yields `none`.)

### Tasks and the `IO` monad, integrated

The integration story is that **promise resolution and task scheduling are one
mechanism** (see `IO.Promise` above). The `Async` combinators in `Basic.lean` are written
entirely in terms of `Task`/`IO.Promise`:

- `Async.concurrently x y` runs both via `MonadAsync.async` (turning each into an
  `AsyncTask`), then `await`s both — i.e. spawns two tasks, binds on both.
- `Async.race` creates a fresh `IO.Promise`, chains both tasks' results onto it with
  `BaseIO.chainTask`, and `await`s the promise; the first task to finish resolves it (the
  loser's result is discarded and _not cancelled_, per the docstring).
- `background action` is `discard (async action)` — fire-and-forget a task.

`ContextAsync` (`src/Std/Async/ContextAsync.lean`) layers cooperative cancellation on top:
`ContextAsync α := ReaderT CancellationContext Async α`. Cancellation here is _cooperative_
— the docstring states operations "must explicitly check `isCancelled` or use
`awaitCancellation`". Forking child contexts (`ctx.fork`) and the `concurrently`/`raceAll`
variants cancel siblings on failure, giving structured-concurrency-like scoping built from
plain `Async` + a cancellation token, not from a runtime-level cancel tree.

### IO multiplexing: `Selectable` / `Selector`

`src/Std/Async/Select.lean` provides "a fair and data-loss free IO multiplexing
primitive" — Lean's answer to Go's `select`. The two structures are:

```lean
-- src/Std/Async/Select.lean
structure Selector (α : Type) where
  tryFn      : Async (Option α)        -- non-blocking attempt
  registerFn : Waiter α → Async Unit   -- register interest, race to win on readiness
  unregisterFn : Async Unit            -- cleanup after a winner is chosen

structure Selectable (α : Type) where
  {β : Type}
  selector : Selector β
  cont     : β → Async α               -- continuation run on the winning value
```

`Selectable.one` runs the documented protocol: shuffle the selectables randomly (for
fairness, using `IO.getRandomBytes` to seed `mkStdGen`), try each `tryFn` once, and if
none are immediately ready, register a `Waiter` with each `Selector`. A `Waiter` holds an
`IO.Ref Bool` "finished" flag and an `IO.Promise`; `Waiter.race` atomically claims the
win via `finished.modifyGet`. The first event source to fire resolves the waiter; the
others' `unregisterFn` are called (e.g. `cancelRecv`/`cancelAccept`/timer `cancel`), and
the winner's `cont` runs. The "data-loss free" guarantee is the rule that "data is never
actually consumed from the event source unless `Waiter.race` wins". Concrete selectors
ship for `Sleep` (`Sleep.selector`), TCP accept/recv (`acceptSelector`/`recvSelector`),
UDP recv, signals, and cancellation (`Selector.cancelled`).

### Domain APIs

All domain modules follow the same shape — a thin `Std.Async.*` wrapper over a
`Std.Internal.UV.*` extern that returns a promise. Summary of the surface:

| Domain  | Lean module (`Std/Async/`) | Backend (`Std/Internal/UV/`) | Representative ops (libuv handle/req)                                                 |
| ------- | -------------------------- | ---------------------------- | ------------------------------------------------------------------------------------- |
| Timer   | `Timer.lean`               | `Timer.lean`                 | `Sleep`/`Interval` over `uv_timer_t`                                                  |
| TCP     | `TCP.lean`                 | `TCP.lean`                   | `Server.{bind,listen,accept}`, `Client.{connect,send,recv?,shutdown}` over `uv_tcp_t` |
| UDP     | `UDP.lean`                 | `UDP.lean`                   | `Socket.{bind,connect,send,recv,setMulticast*}` over `uv_udp_t`                       |
| DNS     | `DNS.lean`                 | `DNS.lean`                   | `getAddrInfo`/`getNameInfo` via `uv_getaddrinfo`/`uv_getnameinfo`                     |
| Process | `Process.lean`             | `System.lean`                | `getId`, `getResourceUsage`, `getExecutablePath`, memory queries (sync)               |
| Signal  | `Signal.lean`              | `Signal.lean`                | `Signal.Waiter.{wait,stop}` over `uv_signal_t`                                        |
| System  | `System.lean`              | `System.lean`                | `getSystemInfo`, `getCPUInfo`, env vars, `getCurrentUser` (sync)                      |

Notable details grounded in the source:

- **DNS uses the libuv event loop, not a separate threadpool wrapper.** `dns.cpp` calls
  `uv_getaddrinfo(global_ev.loop, resolver, cb, …)` / `uv_getnameinfo(...)` — libuv
  internally dispatches these to its worker threadpool, but Lean issues them through the
  loop and resolves the promise from the libuv callback like everything else.
- **Signals** map a Lean `Signal` enum to `Int32` in `Std/Async/Signal.lean`'s
  `toInt32`, with the source noting these "are then mapped to the underlying
  architecture's values in runtime/uv/signal.cpp". `SIGKILL`/`SIGSTOP` are absent
  (uncatchable), as are `SIGBUS`/`SIGFPE`/`SIGILL`/`SIGSEGV` ("cannot be caught safely by
  libuv") and `SIGPIPE` (ignored by the runtime).
- **Process/System queries are synchronous `IO`, not `Async`.** `getCwd`, `getId`,
  `getResourceUsage`, `getEnvVar`, `getCPUInfo`, etc. are direct libuv calls returning
  `IO α` — they're cheap and don't need the promise machinery.

### Version gating and platform fallback

Lean does **no `io_uring` feature detection** because it never uses `io_uring` — the gating
question is entirely "is libuv available?". libuv abstracts the multiplexer per platform
(`epoll`/`kqueue`/event ports/IOCP) internally, so Lean's backend is portable by
construction. The one explicit conditional in the source is the WebAssembly case: every
`runtime/uv/*.cpp` file is wrapped in `#ifndef LEAN_EMSCRIPTEN`, and the Emscripten branch
replaces each extern with a `lean_always_assert(false && "Please build a version of Lean4
with libuv to invoke this.")`. So on Wasm the async API exists but panics on use; on every
native platform it runs over libuv. (libuv has been a required Lean build dependency since
4.12.0.) The `Loop.configure` options (`accumulateIdleTime`, `blockSigProfSignal`) are the
only loop-level tunables, and the `SIGPROF`-blocking one is itself guarded by
`#if !defined(WIN32)`.

---

## Performance approach

- **Reactor with non-blocking syscalls.** Like all libuv users, Lean pays one
  `epoll_wait`/`kqueue` per loop turn and then does the actual `read`/`write`/`accept`
  inside the callback. There is no submission batching or completion queue as with
  [io_uring][io-uring-index] — the wins and costs are exactly libuv's. See [libuv][libuv]
  for the multiplexer details and its blocking-op threadpool.
- **`MaybeTask` avoids allocating tasks for synchronous steps.** A `BaseAsync` step that
  already has its value returns `MaybeTask.pure a`, so chaining synchronous work in an
  `Async` pipeline never allocates a `Task` or touches the scheduler — only a genuine
  suspension produces `MaybeTask.ofTask`.
- **The promise _is_ a pre-allocated task token.** `lean_promise_new` allocates the task
  object up front and `resolve` just fills it in, so there's no separate "create a task to
  deliver the result" step on the completion path.
- **One loop, one thread, lock-coalesced mutations.** All libuv state lives on one thread;
  cross-thread mutations coalesce through the mutex + `uv_async_t` doorbell. This keeps
  the loop single-threaded (matching libuv's contract) without per-handle locking, at the
  cost of a loop interrupt per cross-thread operation.
- **`sync := true` fast-path on task binds.** Many internal binds (e.g.
  `ofPurePromise`, `MaybeTask.joinTask`, `Selectable.one`'s registration) pass
  `sync := true`, running the continuation inline on the resolving thread rather than
  re-dispatching to a worker, shaving scheduler hops on hot paths.
- **Continuations run on Lean's task worker pool.** Once a promise resolves, the
  continuation is ordinary `Task` work, scheduled by the existing multi-threaded task
  manager — so CPU-bound post-processing of I/O results parallelizes across cores
  independently of the single loop thread.

---

## Strengths

- **No new programming model.** Async is built from `Task`, `IO.Promise`, and monad
  transformers that Lean already had. There is no effect system, no coroutine transform,
  no colored-function discipline beyond "it's in `Async`/`IO`". The learning surface is
  small for anyone who knows Lean's `IO`.
- **Promise/Task unification.** Because an `IO.Promise` is literally a `Task` token,
  `await` is monadic bind and "the libuv callback resolves the promise" composes directly
  with Lean's existing parallel task scheduler — I/O results and pure parallel work share
  one runtime.
- **Portable by construction.** Leaning on libuv means `epoll`/`kqueue`/event-ports/IOCP
  are all covered with one codebase; the only special case is Wasm (panics).
- **Fair, data-loss-free multiplexing.** `Selectable.one` randomizes order and uses an
  atomic win/lose `Waiter` protocol with explicit `unregisterFn` cleanup — a careful
  Go-`select`-equivalent that guarantees a non-winning source keeps its data.
- **Structured-concurrency-style scoping.** `ContextAsync` + `CancellationContext` give
  forked child contexts, sibling cancellation on failure, and `background`/`disown`
  lifetimes, built from plain primitives.

## Weaknesses

- **No `io_uring`.** Lean is purely a reactor over libuv; it gets none of `io_uring`'s
  syscall-batching or true async-file wins. File I/O in particular has no readiness model
  in libuv and falls to the threadpool — Lean inherits that limitation. Contrast the
  proactor backends in [Eio][eio-backend] and the Java `io_uring` bindings.
- **Cooperative cancellation only.** `ContextAsync.isCancelled` must be polled; an
  in-flight libuv op isn't forcibly aborted by context cancellation in general (individual
  ops like `cancelRecv`/`cancelAccept`/timer `cancel` exist, but there's no universal
  cancel-the-syscall mechanism). Dropped promises "hang forever without further
  intervention", a documented footgun.
- **Single-loop thread is a serialization point.** Every cross-thread I/O submission must
  interrupt and lock the one loop; under heavy concurrent submission this mutex +
  `uv_async_t` round-trip is a contention point that a per-core ring (e.g. Glommio,
  Monoio) avoids.
- **One outstanding op per socket.** A second `recv?`/`accept` while one is pending
  returns `UV_EALREADY`; concurrency on a single socket is explicitly unsupported (the
  docs suggest binding multiple sockets to the same address instead).
- **Manual lifetime management in the C layer.** The backend hand-balances `lean_inc`/
  `lean_dec` and `malloc`/`free` around every libuv request; the promise-ownership rules
  are intricate and a mismatch is a native crash, not a Lean error.
- **Young API, still moving.** It first shipped in 4.17.0 (2025) and was still being
  refactored as late as 4.25.0 (the whole module moved to the unified `Async` type, and
  signals/notify/broadcast/cancellation-tokens were added); the surface is not yet
  long-term-stable.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                  | Trade-off                                                                       |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| libuv reactor instead of `io_uring`                               | Portable across Linux/macOS/BSD/Windows with one codebase; reuse Node's battle-tested loop | No proactor/batching wins; file I/O stuck on the threadpool                     |
| Monadic `Task`/`IO.Promise` instead of effects/coroutines         | No new runtime mechanism; "await" is `Task.bind`; composes with the existing scheduler     | Code is monadic (`do`/`>>=`), not true direct style; no zero-cost stack capture |
| Promise = pre-allocated `Task` token (`o->m_result = t`)          | Resolution and scheduling are one mechanism; no extra task alloc on completion             | A dropped/unresolved promise's task never runs — "hangs forever"                |
| Single global loop on a dedicated thread, mutex + `uv_async_t`    | Makes the thread-unsafe libuv loop safe to share from Lean's task pool                     | Cross-thread submissions serialize through one mutex + a loop interrupt         |
| `MaybeTask.pure`/`ofTask` in `BaseAsync`                          | Synchronous steps skip task allocation and the scheduler entirely                          | Extra sum-type branch on every `Async` bind                                     |
| Cooperative cancellation via `ContextAsync`/`CancellationContext` | Simple, predictable; structured-concurrency scoping in pure Lean                           | Must poll `isCancelled`; no forced abort of an arbitrary in-flight syscall      |
| `Selectable.one`: shuffle + atomic `Waiter.race` + `unregisterFn` | Fair, data-loss-free Go-`select` equivalent                                                | Per-select random shuffle + a promise/ref per waiter                            |
| One outstanding read/accept per socket (`UV_EALREADY`)            | Keeps the per-socket promise slot simple and race-free                                     | No single-socket concurrency; must fan out across sockets                       |
| Wasm: externs panic (`#ifndef LEAN_EMSCRIPTEN`)                   | Lets the API type-check everywhere; libuv simply isn't there on Emscripten                 | The async API is non-functional on the Wasm target                              |

---

## Sources

- [leanprover/lean4] — source of all `Std/Async/*`, `Std/Internal/UV/*`, and
  `src/runtime/uv/*` paths quoted above
- [Lean 4.17.0 notes] — "#6505 implements a basic async framework as well as
  asynchronously running timers using libuv"
- [Lean 4.20.0 notes] — async IO multiplexing framework (#8055), `Selector` for TCP
  (#8078) and UDP (#8139), channel multiplexing (#8150)
- [Lean release notes] — overall release history (libuv required since 4.12.0;
  `lean_setup_libuv` in 4.22.0; signals/notify/broadcast/cancellation in 4.25.0)
- [libuv] — the cross-platform reactor Lean drives
- [Companion: libuv (C)][libuv] — the shared backend in detail
- [Companion: Python asyncio/uvloop/Trio][python-async] — the other "libuv from a managed
  language" data point
- [Companion: OCaml Eio io_uring backend][eio-backend] — a proactor contrast
- [Companion: Koka effect handlers][koka] — the effect-system contrast to Lean's monadic model
- [Companion: Effects and event loops][effects-and-event-loops]
- [Companion: io_uring overview][io-uring-index] — the kernel interface Lean does _not_ use

<!-- References -->

[leanprover/lean4]: https://github.com/leanprover/lean4
[Lean release notes]: https://lean-lang.org/doc/reference/latest/releases/
[Lean 4.17.0 notes]: https://lean-lang.org/doc/reference/latest/releases/v4.17.0/
[Lean 4.20.0 notes]: https://lean-lang.org/doc/reference/latest/releases/v4.20.0/
[libuv]: ./libuv.md
[python-async]: ./python-async.md
[eio-backend]: ./eio-backend.md
[koka]: ../algebraic-effects/koka.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[io-uring-index]: ./io-uring/index.md
