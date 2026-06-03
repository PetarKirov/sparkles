# Eio (OCaml)

Effects-based direct-style I/O library for OCaml 5: structured concurrency via switches and capability-based security, built on three internal [OCaml 5] effects (`Fork`, `Suspend`, `Get_context`) and one-shot continuations, with no monadic encoding exposed to users.

| Field          | Value                                                                              |
| -------------- | ---------------------------------------------------------------------------------- |
| Language       | OCaml (current release Eio 1.3 requires OCaml >= 5.2.0; Eio 1.0 required >= 5.1.0) |
| License        | ISC                                                                                |
| Repository     | [Eio GitHub Repository] (`ocaml-multicore/eio`)                                    |
| Latest release | Eio 1.3 (20 Jul 2025); 1.0 milestone March 2024                                    |
| Documentation  | [Eio on OCaml Packages] / [Eio API Documentation]                                  |
| Key Authors    | Thomas Leonard (`@talex5`), KC Sivaramakrishnan, Anil Madhavapeddy, contributors   |
| Encoding       | Direct-style I/O over [OCaml 5] effect handlers with capability passing            |

---

## Overview

### What It Solves

Before [OCaml 5], concurrent I/O required monadic libraries like Lwt or Async. As Eio's own `README.md` puts it, these "allow writing code as if there were multiple threads of execution, each with their own stack, but the stacks are simulated using the heap." That simulation imposes allocation overhead, fragments backtraces, and forces a monadic coding style where every I/O step threads through `bind`.

OCaml 5 added effect handlers, and Eio's README enumerates the four payoffs it exploits: (1) it is faster, because no heap allocations are needed to simulate a stack; (2) concurrent code is written in the same style as plain non-concurrent code; (3) real stacks mean exception backtraces work as expected; (4) ordinary language features like `try ... with ...` work inside concurrent code. A function that reads a file calls `Eio.Path.load` directly — a plain function call that internally performs an effect.

### Design Philosophy

Eio is built on three pillars, all visible in the source:

1. **Direct style** — no monad in the public API. The internal effects (`Fork`, `Suspend`, `Get_context`) live in `lib_eio/core/` and are never exposed to application code.

2. **Capability-based security** — I/O authority flows from a single privileged root (`env`, passed to `Eio_main.run`'s callback) and is sub-divided as it is passed down. The README's "Design Note: Capabilities" states the thesis directly: "the lambda calculus already contains a perfectly good security system: a function can only access things that are in its scope." A function cannot touch the network unless it receives a `net` value.

3. **Structured concurrency** — every fiber belongs to a `Switch`, which the docs explicitly call "a 'nursery' or 'bundle' in some other systems" (`lib_eio/core/eio__core.mli`). A switch cannot finish until every fiber and resource attached to it has terminated, so there are no orphaned background tasks.

For how OCaml 5's effect runtime itself works (deep handlers, `match_with`, one-shot continuations, fibers as heap-allocated stack segments), see the [OCaml 5 effects companion document]. This doc focuses on what Eio _builds on top of_ that runtime.

---

## Core Abstractions and Types

### Entry Point

Every Eio program begins with `Eio_main.run`, which installs the platform backend's effect handler and provides the root environment:

```ocaml
(* Public API surface in lib_eio/eio.ml *)
let () =
  Eio_main.run @@ fun env ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    main ~net ~clock
```

### Capabilities from `Stdenv`

`env` is not a record but an **object with row-polymorphic methods**. The `Eio.Stdenv` accessors in `lib_eio/eio.ml` are one-line method projections, which is why each returns a capability without exposing the rest:

```ocaml
(* lib_eio/eio.ml *)
module Stdenv = struct
  let stdin  (t : <stdin  : _ Flow.source; ..>) = t#stdin
  let stdout (t : <stdout : _ Flow.sink;   ..>) = t#stdout
  let stderr (t : <stderr : _ Flow.sink;   ..>) = t#stderr
  let net (t : <net : _ Net.t; ..>) = t#net
  let process_mgr (t : <process_mgr : _ Process.mgr; ..>) = t#process_mgr
  let domain_mgr (t : <domain_mgr : _ Domain_manager.t; ..>) = t#domain_mgr
  let clock (t : <clock : _ Time.clock; ..>) = t#clock
  let mono_clock (t : <mono_clock : _ Time.Mono.t; ..>) = t#mono_clock
  let secure_random (t: <secure_random : _ Flow.source; ..>) = t#secure_random
  let fs (t : <fs : _ Path.t; ..>) = t#fs
  let cwd (t : <cwd : _ Path.t; ..>) = t#cwd
  (* ... *)
end
```

| Capability         | Accessor                 | Type                     | Notes                                     |
| ------------------ | ------------------------ | ------------------------ | ----------------------------------------- |
| File system (full) | `Eio.Stdenv.fs`          | `_ Eio.Path.t`           | Unrestricted; can reach `/etc/passwd`     |
| Current directory  | `Eio.Stdenv.cwd`         | `_ Eio.Path.t`           | Sandboxed below cwd (see Path sandboxing) |
| Network            | `Eio.Stdenv.net`         | `_ Eio.Net.t`            | `connect`/`listen`/datagram sockets       |
| Clock              | `Eio.Stdenv.clock`       | `_ Eio.Time.clock`       | Wall-clock time                           |
| Monotonic clock    | `Eio.Stdenv.mono_clock`  | `_ Eio.Time.Mono.t`      | Intervals / timeouts                      |
| Domain manager     | `Eio.Stdenv.domain_mgr`  | `_ Eio.Domain_manager.t` | Spawn OS-level domains for parallelism    |
| Process manager    | `Eio.Stdenv.process_mgr` | `_ Eio.Process.mgr`      | Spawn subprocesses                        |
| Stdout / Stderr    | `Eio.Stdenv.stdout` / …  | `_ Eio.Flow.sink`        | Standard streams                          |

### The internal types: `Cancel.t` and `fiber_context`

The whole concurrency machinery rests on two record types defined in `lib_eio/core/cancel.ml`. A `Cancel.t` is a node in a per-domain tree of cancellation contexts; a `fiber_context` is the per-fiber state that points at its current context and carries its cancel function:

```ocaml
(* lib_eio/core/cancel.ml *)
type t = {
  id : Trace.id;
  mutable state : state;            (* On | Cancelling of exn * bt | Finished *)
  children : t Lwt_dllist.t;
  fibers : fiber_context Lwt_dllist.t;
  protected : bool;
  domain : Domain.id;               (* Prevent access from other domains *)
}
and fiber_context = {
  tid : Trace.id;
  mutable cancel_context : t;
  mutable cancel_node : fiber_context Lwt_dllist.node option;
  mutable cancel_fn : exn -> unit;  (* Encourage the current operation to finish *)
  mutable vars : Hmap.t;            (* Fiber-local variables *)
}
```

`Switch.t` (in `lib_eio/core/switch.ml`) wraps a `Cancel.t` and adds fiber accounting (`fibers`, `daemon_fibers`), an exception accumulator (`exs`), and a list of `on_release` cleanup hooks.

---

## How Effects Are Declared

Eio defines exactly three user-visible-to-the-scheduler effects, all in `lib_eio/core/` and re-exported (for backend authors only) under `Eio.Private.Effects` in `lib_eio/core/eio__core.mli`. Application code never performs them.

**1. `Suspend` — block a fiber and hand control to the scheduler** (`lib_eio/core/suspend.ml`):

```ocaml
(* lib_eio/core/suspend.ml *)
type 'a enqueue = ('a, exn) result -> unit
type _ Effect.t += Suspend : (Cancel.fiber_context -> 'a enqueue -> unit) -> 'a Effect.t

let enter_unchecked op fn =
  Trace.suspend_fiber op;
  Effect.perform (Suspend fn)

let enter op fn =
  enter_unchecked op @@ fun fiber enqueue ->
  match Cancel.Fiber_context.get_error fiber with
  | None -> fn fiber enqueue
  | Some ex -> enqueue (Error ex)
```

`Suspend fn` carries a callback that the scheduler runs _in its own context_, passing the suspended fiber's context and an `enqueue` resume function. `enter` first checks the fiber isn't already cancelled before calling `fn`; `enter_unchecked` skips that. This is _the_ primitive: `Promise.await`, `Fiber.yield`, stream takes, and every blocking I/O call ultimately route through `Suspend.enter`.

**2. `Fork` — create a new fiber** (`lib_eio/core/fiber.ml`):

```ocaml
(* lib_eio/core/fiber.ml *)
type _ Effect.t += Fork : Cancel.fiber_context * (unit -> unit) -> unit Effect.t

let fork_raw new_fiber f =
  Effect.perform (Fork (new_fiber, f))
```

The payload is a freshly-made `fiber_context` plus the function to run. The comment in the source is load-bearing: "`[f]` must not raise an exception, as that would terminate the whole scheduler" — so the public `fork` wraps `f` in a handler that routes failures to `Switch.fail`.

**3. `Get_context` — read the current fiber's context without suspending** (`lib_eio/core/cancel.ml`):

```ocaml
(* lib_eio/core/cancel.ml *)
type _ Effect.t += Get_context : fiber_context Effect.t
```

Used by `Fiber.check`, `Cancel.protect`, `Fiber.get`/`with_binding`, etc. — anything that needs the current cancellation context or fiber-local vars synchronously.

Crucially, **these effects are one-shot**: the scheduler resumes each continuation exactly once. The backend's effect handler (below) calls `continue k` / `discontinue k` per resumption, matching OCaml 5's one-shot continuation discipline described in the [OCaml 5 effects companion document].

---

## How Handlers/Interpreters Work

### The scheduler is the effect handler

Eio's interpreter is the per-domain run loop in each backend. For Linux that is `lib_eio_linux/sched.ml`'s `run`, which uses `Effect.Deep.match_with` to install handlers for the three core effects plus backend-specific ones. The handler clause for each effect is short and revealing:

```ocaml
(* lib_eio_linux/sched.ml — inside [fork ~new_fiber fn] *)
effc = fun (type a) (e : a Effect.t) : ((a, _) continuation -> _) option ->
  match e with
  | Get -> Some (fun k -> continue k st)
  | Eio.Private.Effects.Get_context -> Some (fun k -> continue k fiber)
  | Eio.Private.Effects.Suspend f -> Some (fun k ->
      let k = { Suspended.k; fiber } in
      f fiber (function
          | Ok v -> enqueue_thread st k v
          | Error ex -> enqueue_failed_thread st k ex
        );
      schedule st                       (* run the next ready fiber *)
    )
  | Eio.Private.Effects.Fork (new_fiber, f) -> Some (fun k ->
      let k = { Suspended.k; fiber } in
      enqueue_at_head st k ();          (* parent goes to head of run queue *)
      fork ~new_fiber f                 (* child runs immediately *)
    )
  | ... (* Await_readable, Await_writable, Run_in_systhread, Enter, Cancel *)
```

When a fiber performs `Suspend f`, the handler captures the one-shot continuation `k`, bundles it with the `fiber_context` into a `Suspended.t`, and calls `f` to register how the fiber gets resumed (typically by submitting an `io_uring` SQE and setting a cancel function). It then calls `schedule st` to pick the next runnable fiber. `Fork` is even more direct: the parent is pushed to the _head_ of the run queue and the child runs synchronously, which is exactly why `Fiber.fork`/`both`/`first` document that "`f` runs immediately, without switching to any other fiber first."

The backend-specific I/O effects (`Enter`, `Await_readable`, `Await_writable`, `Run_in_systhread`, `Cancel`) and the `io_uring` submission/completion ring mechanics are covered in detail in the [Async I/O Eio backend deep-dive]; this doc treats them as the layer beneath `Suspend`.

### Switches and structured concurrency

`Switch.run` (in `lib_eio/core/switch.ml`) is built directly on `Cancel.sub_checked`, so every switch _is_ a cancellation sub-context:

```ocaml
(* lib_eio/core/switch.ml *)
let run ?name fn = Cancel.sub_checked ?name Switch (fun cc -> run_internal (create cc) fn)
```

`run_internal` runs the main function, then `await_idle` _blocks until `t.fibers = 0`_, then runs `on_release` hooks in LIFO order, then re-raises any accumulated exception. Fiber accounting is the heart of it:

```ocaml
(* lib_eio/core/switch.ml *)
let dec_fibers t =
  t.fibers <- t.fibers - 1;
  if t.daemon_fibers > 0 && t.fibers = t.daemon_fibers then
    Cancel.cancel t.cancel Exit;            (* only daemons left → cancel them *)
  if t.fibers = 0 then
    Single_waiter.wake_if_sleeping t.waiter (* let Switch.run finish *)
```

That second clause is the daemon-fiber rule: once every _non-daemon_ fiber has finished, the switch cancels its daemons with `Exit`. The main function itself counts as a fiber (`create` initialises `fibers = 1`), so the switch can't finish while user code is still running.

### Forking into a switch

`Fiber.fork` (in `lib_eio/core/fiber.ml`) makes a child `fiber_context` _inside the switch's cancel context_, registers it as an in-flight operation via `Switch.with_op`, and wraps the body so any exception is funnelled to `Switch.fail`:

```ocaml
(* lib_eio/core/fiber.ml *)
let fork ~sw f =
  Switch.check_our_domain sw;
  if Cancel.is_on sw.cancel then (
    let vars = Cancel.Fiber_context.get_vars () in
    let new_fiber = Cancel.Fiber_context.make ~cc:sw.cancel ~vars in
    fork_raw new_fiber @@ fun () ->
    Switch.with_op sw @@ fun () ->
    try f ()
    with ex ->
      let bt = Printexc.get_raw_backtrace () in
      Switch.fail ~bt sw ex
  )
```

Note the child _inherits the switch's cancellation context and the parent's fiber-local `vars`_. The structured-concurrency combinators are then trivially defined on top — `both`, `all`, and `pair` just open a private switch and fork into it:

```ocaml
(* lib_eio/core/fiber.ml *)
let all xs  = Switch.run ~name:"all"  @@ fun sw -> forks ~sw xs
let both f g = Switch.run ~name:"both" @@ fun sw -> forks ~sw [f; g]
let pair f g =
  Switch.run ~name:"pair" @@ fun sw ->
  let x = fork_promise ~sw f in
  let y = g () in
  (Promise.await_exn x, y)
```

`forks` runs the _last_ function in the current fiber "for efficiency and less cluttered traces" rather than forking all of them.

### Racing: `Fiber.first` / `any`

`Fiber.first`/`any` are `any_gen`, which installs a sub-context `Cancel.sub_unchecked Any` and, the moment the first fiber returns, calls `Cancel.cancel cc Not_first` to cancel the losers. The source comment warns that "it is always possible that both operations will succeed" because a winner sitting in the run queue hasn't stopped the loser yet — so a `combine` function reconciles two results if both land.

### Promises

`Promise` (`lib_eio/core/promise.ml`) is an `Atomic` cell that is either `Resolved x` or `Unresolved of Broadcast.t`. `await` suspends via `Suspend.enter "Promise.await"`, registering a `Broadcast` waiter, and uses `compare_and_set` to win the race against concurrent resolution. Because the state is atomic, "promises are thread-safe and so can be shared between domains and used to communicate between them" (`eio__core.mli`). On suspend it installs a cancel function so a cancelled awaiter is woken with the cancellation exception:

```ocaml
(* lib_eio/core/promise.ml — inside await *)
Cancel.Fiber_context.set_cancel_fn ctx (fun ex ->
    if Broadcast.cancel request then enqueue (Error ex))
```

### Cancellation propagation

Cancellation lives entirely in `lib_eio/core/cancel.ml` and is _tree-structured per domain_. `Switch.fail` records the exception and calls `Cancel.cancel`, which:

1. `cancel_internal` walks the context subtree marking each non-`protected` node `Cancelling (ex, bt)` and collecting every registered `fiber_context`. Because "modifying the cancellation tree can only be done from our domain, this is effectively an atomic operation."
2. For each collected fiber it swaps `cancel_fn` for `ignore` (so it can't fire twice) and calls the old `cancel_fn cex`, which "encourages the current operation to finish" — e.g. submitting an `io_uring` cancel SQE for the in-flight job.

```ocaml
(* lib_eio/core/cancel.ml *)
let rec cancel_internal t ex acc_fibers =
  match t.state with
  | Finished -> invalid_arg "Cancellation context finished!"
  | Cancelling _ -> acc_fibers
  | On ->
    let bt = Printexc.get_raw_backtrace () in
    t.state <- Cancelling (ex, bt);
    Trace.error t.id ex;
    let acc_fibers = Lwt_dllist.fold_r List.cons t.fibers acc_fibers in
    Lwt_dllist.fold_r (cancel_child ex) t.children acc_fibers
and cancel_child ex t acc =
  if t.protected then acc else cancel_internal t ex acc
```

`Cancel.protect` runs a body in a `protected:true` sub-context, so cancellation of the parent does _not_ reach it — this is how `Switch.on_release` cleanup runs even on a cancelled switch. Critically, the docs note cancellation "is to stop fibers quickly, not to report errors": use `Switch.fail` to record an error. Cancellation always raises `Cancel.Cancelled ex`, and `Fiber.check ()` lets a fiber poll for it.

### Daemon fibers

`Fiber.fork_daemon` forks via `Switch.with_daemon` (which increments both `fibers` and `daemon_fibers`). Its body must return ``[`Stop_daemon]``, and it specifically tolerates the auto-cancellation when all real fibers finish:

```ocaml
(* lib_eio/core/fiber.ml — inside fork_daemon's body *)
match f () with
| `Stop_daemon -> ()
| exception Cancel.Cancelled Exit when not (Cancel.is_on sw.cancel) ->
    (* cancelled because all non-daemon fibers are finished *) ()
| exception ex ->
    let bt = Printexc.get_raw_backtrace () in
    Switch.fail ~bt sw ex
```

The Linux backend itself uses this: `sched.ml`'s `run` forks `monitor_event_fd` as a daemon so the event-fd reader is torn down automatically when the program's main fiber exits.

---

## Performance Approach

Lwt and Async simulate concurrent stacks by allocating promise chains on the heap. Eio uses real fibers (OCaml 5 stack segments) via the effect runtime, so suspending and resuming is a continuation switch, not a heap allocation for control flow — the README's claimed advantage #1. Backtraces survive because the real stack is preserved (advantage #3).

### Platform-optimised backends

| Backend       | opam package  | Platform          | Mechanism                                                        |
| ------------- | ------------- | ----------------- | ---------------------------------------------------------------- |
| `eio_linux`   | `eio_linux`   | Linux             | `io_uring` via the `uring` library                               |
| `eio_posix`   | `eio_posix`   | macOS, BSD, POSIX | `kqueue` / `poll`-based readiness                                |
| `eio_windows` | `eio_windows` | Windows           | Incomplete (help wanted)                                         |
| `eio_js`      | `eio_js`      | Browser           | `js_of_ocaml` scheduler (separate `ocaml-multicore/eio_js` repo) |
| `eio_main`    | `eio_main`    | Any               | Selects the appropriate backend at runtime                       |

The Linux backend depends on the `uring` opam package (repo `ocaml-multicore/ocaml-uring`); Eio's dev `dune-project` pins `(uring (>= 2.7.0))`. The scheduler in `lib_eio_linux/sched.ml` keeps a lock-free run queue (`Lf_queue`), a timer wheel (`Zzz`), and a fixed `io_uring` submission/completion ring; its `schedule` loop drains ready fibers, fires due timers, harvests completions with `Uring.get_cqe_nonblocking`, and otherwise sleeps in `Uring.wait`, waking on an `eventfd` when another domain enqueues work. It even opts into recent kernel ring features:

```ocaml
(* lib_eio_linux/sched.ml *)
let uring_create ~queue_depth ?polling_timeout () =
  let flags = Uring.Setup_flags.(single_issuer + defer_taskrun + taskrun_flag) in
  (* Requires Linux >= 6.1 *)
  match Uring.create ~queue_depth ~flags ?polling_timeout () with
  | exception Unix.Unix_error(EINVAL, _, _) -> Uring.create ~queue_depth ?polling_timeout ()
  | x -> x
```

The full ring lifecycle, SQE/CQE plumbing, cancellation SQEs, and fixed-buffer pool are documented in the [Async I/O Eio backend deep-dive].

### Comparison with Lwt

Eio avoids heap allocation for concurrency control, gives correct backtraces, and lets `try ... with` work in concurrent code. Real-world comparison is nuanced: as Thomas Leonard's [performance analysis] documents, Lwt's scheduling can incidentally interact with system mechanisms (e.g. Nagle's algorithm) in ways that flatter throughput, sometimes requiring Eio to add explicit buffering to match. For deeper treatment of effects-vs-callbacks and event-loop integration, see [Effects and event loops].

---

## Composability Model

The single root `env` is sub-divided into narrower capabilities as it flows down the call graph. A web server gets only `net` and `clock`; a file processor gets only `fs`. Because the accessors return interface-typed values, you can substitute mocks (`Eio_mock.Net`, `Eio_mock.Clock`) in tests without touching production code. The README's capability note shows how this makes "does this program modify the filesystem / send telemetry?" auditable by following the authority rather than reading the whole codebase.

**Path sandboxing.** `Eio.Stdenv.cwd` is a `Path.t` confined to the working directory. As `lib_eio/path.mli` states, "it is normally not permitted to access anything above the base directory, even by following a symlink"; only `Eio.Stdenv.fs` reaches the whole filesystem (`fs / "/etc/passwd"`). `Path.open_dir` / `with_open_dir` create _further-restricted_ sub-directory capabilities. On Linux the backend enforces this with `openat`-relative operations and `O_RESOLVE_BENEATH`-style confinement; the `Eio_unix.Cap` module (added in Eio 1.0) can additionally enter Capsicum mode on supporting systems.

**Cross-runtime interop.** Eio code can call into Lwt libraries (and vice-versa) via the `Lwt_eio` shim, enabling incremental migration. Effects are _not_ exposed for user-defined composition — the three core effects are private to the scheduler — so unlike a Koka or an effect-tracked language, you cannot define and handle your own effects through Eio's machinery. (Contrast with the algebraic-effects languages surveyed in the [comparison] and the design [evolution] of the field.)

---

## Strengths

- **Direct-style programming** eliminates monadic boilerplate; concurrent code reads like sequential code.
- **Real stack backtraces** work correctly, because fibers are real OCaml 5 stacks, not heap-simulated.
- **No heap allocation for control flow** — suspend/resume is a continuation switch.
- **Structured concurrency** via `Switch` guarantees no orphaned fibers and LIFO resource cleanup; the switch's main function is itself counted, so it can't finish early.
- **Capability-based security** makes I/O authority explicit, auditable, and mockable.
- **Sandboxed filesystem** by default (`cwd` confined; symlink escapes rejected; optional Capsicum mode).
- **Platform-optimised backends** including `io_uring` on Linux (with `single_issuer`/`defer_taskrun` on recent kernels).
- **Thread-safe promises and streams** usable across domains for shared-memory parallelism.
- **Incremental migration** from Lwt via `Lwt_eio`.

## Weaknesses

- **Requires OCaml 5** (Eio 1.0 required >= 5.1.0; the current 1.3 release and dev `main` require >= 5.2.0), excluding the OCaml 4.x ecosystem.
- **Ecosystem maturity** still trails Lwt's decade-plus of library support.
- **Untyped effects underneath** — OCaml 5 has no static effect tracking, so the type system does not show which functions perform I/O or may block.
- **Windows backend incomplete** (`eio_windows` is explicitly help-wanted).
- **Effects hidden from users** — you cannot define/handle your own effects through Eio; the three core effects are private.
- **Performance tuning required** for some workloads where Lwt's scheduling incidentally helps.
- **Capability-passing verbosity** — threading `net`, `clock`, `fs`, `sw` through signatures.
- **One-shot continuation discipline** — backend authors must resume each suspended fiber exactly once and handle the cancel-vs-complete race (documented at length in `eio__core.mli`).

## Key Design Decisions and Trade-offs

| Decision                                               | Rationale                                                        | Trade-off                                                         |
| ------------------------------------------------------ | ---------------------------------------------------------------- | ----------------------------------------------------------------- |
| Three private effects (`Fork`/`Suspend`/`Get_context`) | Minimal scheduler interface; everything else builds on them      | Backend must handle all three correctly; not user-extensible      |
| One-shot continuations                                 | Matches OCaml 5 runtime; cheap resume                            | Must resume exactly once; cancel-vs-complete race handling        |
| Direct style over monadic                              | Natural code; real backtraces; no bind overhead                  | Requires OCaml 5 effects                                          |
| Capability passing from `env`                          | Explicit authority; auditable; testable; least authority         | Verbose signatures; threading required                            |
| Structured concurrency via `Switch`                    | No orphaned fibers; LIFO cleanup; main counts as a fiber         | Less flexible than unstructured spawn                             |
| Per-domain cancellation tree                           | Cancellation is a local, effectively-atomic tree walk            | Cross-domain resume needs atomic CAS in cancel functions          |
| Daemon fibers cancelled when reals finish              | Background tasks (e.g. event-fd monitor) tear down automatically | Daemons must tolerate `Cancelled Exit`; return ``[`Stop_daemon]`` |
| Path sandboxing by default                             | Prevents path traversal even via symlinks                        | Must opt in to full `fs` access                                   |
| Multiple platform backends                             | Optimised I/O per platform (`io_uring`, kqueue, js)              | Subtle behavioural differences; Windows incomplete                |

---

## Sources

- [Eio GitHub Repository] — source under `lib_eio/`, `lib_eio/core/`, `lib_eio_linux/`
- [Eio 1.0 Release Announcement (Tarides)]
- [Eio on OCaml Packages]
- [Eio API Documentation]
- [Eio.Fiber API]
- [Eio.Path API]
- [Eio 1.0 -- Effects-based IO for OCaml 5 (OCaML'23 paper)]
- [ocaml-uring (uring library) repository]
- [OCaml 5 effects companion document]: ocaml-effects.md
- [performance analysis] (Thomas Leonard)
- [Eio 0.1 Announcement (OCaml Discuss)]
- [Async I/O Eio backend deep-dive]
- [Effects and event loops]
- [io_uring survey]
- [comparison]
- [evolution]

<!-- References -->

[OCaml 5]: ocaml-effects.md
[OCaml 5 effects companion document]: ocaml-effects.md
[Async I/O Eio backend deep-dive]: ../async-io/eio-backend.md
[Effects and event loops]: ../async-io/effects-and-event-loops.md
[io_uring survey]: ../async-io/io-uring/index.md
[comparison]: ./comparison.md
[evolution]: ./evolution.md
[Eio GitHub Repository]: https://github.com/ocaml-multicore/eio
[Eio 1.0 Release Announcement (Tarides)]: https://tarides.com/blog/2024-03-20-eio-1-0-release-introducing-a-new-effects-based-i-o-library-for-ocaml/
[Eio on OCaml Packages]: https://ocaml.org/p/eio/latest
[Eio API Documentation]: https://ocaml-multicore.github.io/eio/eio/Eio/index.html
[Eio.Fiber API]: https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html
[Eio.Path API]: https://ocaml-multicore.github.io/eio/eio/Eio/Path/index.html
[Eio 1.0 -- Effects-based IO for OCaml 5 (OCaML'23 paper)]: https://kcsrk.info/papers/eio_ocaml23a.pdf
[ocaml-uring (uring library) repository]: https://github.com/ocaml-multicore/ocaml-uring
[performance analysis]: https://roscidus.com/blog/blog/2024/07/22/performance/
[Eio 0.1 Announcement (OCaml Discuss)]: https://discuss.ocaml.org/t/eio-0-1-effects-based-direct-style-io-for-ocaml-5/9298
