# OCaml Eio — io_uring Backend & Scheduler

How a Linux `io_uring` completion (CQE) resumes a one-shot delimited continuation captured by an OCaml 5 effect, turning batched asynchronous I/O into ordinary direct-style code.

| Field         | Value                                                                               |
| ------------- | ----------------------------------------------------------------------------------- |
| Language      | OCaml 5.2+                                                                          |
| License       | ISC                                                                                 |
| Repository    | [Eio GitHub Repository] · [ocaml-uring]                                             |
| Documentation | [Eio API Documentation] / [Eio_linux API]                                           |
| Key Authors   | Thomas Leonard, Anil Madhavapeddy, Patrick Ferris, KC Sivaramakrishnan              |
| Pattern       | Proactor (`io_uring` SQE/CQE) on Linux, Reactor (`poll`/`ppoll`) fallback on POSIX  |
| Encoding      | One-shot delimited continuations (`Effect.Deep`) resumed from a CQE-driven run loop |

> **Scope.** This is a _companion_ to [Eio's effects/capabilities API][eio-capabilities].
> That document covers the user-facing model — `Eio_main.run`, `Stdenv`, `Switch`,
> `Fiber`, capability passing. **This** document is about the _mechanics underneath_: the
> `eio_linux` scheduler (`lib_eio_linux/sched.ml`), the `io_uring` submission/completion
> loop, the core fiber/effect plumbing in `lib_eio/core` (the `Suspend` effect, the
> `Suspended` continuation record, `Cancel`, `Switch`), cross-domain wakeups via
> `eventfd`, and the `eio_posix` `poll`-based fallback. All file paths below are relative
> to the [Eio repository][Eio GitHub Repository]. The central question the survey cares
> about: **how does a kernel completion map back onto a suspended fiber?** The short
> answer — _a CQE carries an `io_job` tag whose payload is a `Suspended.t` record holding
> a one-shot continuation; resuming it is a single `Effect.Deep.continue`._

---

## Overview

### What it solves

Before OCaml 5, asynchronous I/O required monadic libraries (Lwt, Async) that simulate a
call stack on the heap via promise chains. Eio instead suspends a _real_ fiber stack using
[OCaml 5 algebraic effects][ocaml-effects]: an I/O call performs an effect, the handler
captures the rest of the fiber as a delimited continuation, registers the operation with
the OS, and returns control to the scheduler. When the OS reports completion, the
scheduler resumes the continuation with the result. From the programmer's perspective the
I/O call looks synchronous; from the runtime's perspective it is a cooperative
context-switch with no heap allocation for control flow.

On Linux this is implemented over **io_uring**, which is a _proactor_: you submit
_operations_ (read, write, accept, openat2, …) to a Submission Queue (SQ), and the kernel
performs them asynchronously and posts results to a Completion Queue (CQ). This is a
natural fit for the continuation model — each in-flight SQE corresponds to exactly one
suspended fiber, and each CQE carries enough information to find and resume it. See
[io_uring: the unified async interface][io-uring-index] for the kernel mechanism in
detail.

### Design philosophy of the backend

- **The CQE _is_ the wakeup.** There is no separate readiness step (as in epoll) followed
  by a blocking syscall. The completion already contains the result (bytes read, new fd,
  errno), so the scheduler can resume the fiber directly without re-issuing the operation.
- **One job tag per operation.** Every SQE is submitted with a typed `io_job` value as its
  user-data. When the matching CQE arrives, the scheduler pattern-matches on that tag to
  decide how to deliver the integer result back to the right fiber.
- **The run queue is lock-free and cross-domain.** Other domains (and signal handlers, GC
  finalizers) can push wakeups onto the run queue and nudge a sleeping domain via
  `eventfd`.
- **Graceful degradation.** If `io_uring` is unavailable (old kernel, denied by seccomp,
  not Linux), `eio_main` falls back to `eio_posix`, which uses the same scheduler shape
  with `ppoll`/`poll` readiness instead of completions.

---

## Core abstractions and types

These four types are the whole vocabulary of the backend. Three live in `lib_eio/core`
(shared by every backend); one (`io_job`) is specific to `eio_linux`.

### `Suspended.t` — a captured fiber

The bridge between the effect runtime and the scheduler. Defined in
`lib_eio/utils/suspended.ml`:

```ocaml
(* lib_eio/utils/suspended.ml *)
type 'a t = {
  fiber : Eio.Private.Fiber_context.t;
  k : ('a, [`Exit_scheduler]) continuation;
}

let continue t v = Trace.fiber (tid t); continue t.k v
let discontinue t ex = Trace.fiber (tid t); discontinue t.k ex
```

`k` is a **one-shot delimited continuation** captured by `Effect.Deep.match_with`: it
represents "the rest of this fiber, from the point of the I/O call onward". Its answer
type is ``[`Exit_scheduler]`` — resuming it eventually returns control to the scheduler
loop, never to the original `perform` site. `fiber` is the fiber's cancellation context.
`Suspended.continue k v` delivers a success value `v`; `Suspended.discontinue k ex`
delivers an exception. Because the continuation is one-shot, the scheduler must call
exactly one of these exactly once.

### `Fiber_context.t` — cancellation state

From `lib_eio/core/cancel.ml`. Each fiber owns one. The fields the scheduler touches:

```ocaml
(* lib_eio/core/cancel.ml *)
and fiber_context = {
  tid : Trace.id;
  mutable cancel_context : t;        (* node in the per-domain cancel tree *)
  mutable cancel_node : fiber_context Lwt_dllist.node option;
  mutable cancel_fn : exn -> unit;   (* "encourage the current operation to finish" *)
  mutable vars : Hmap.t;
}
```

The `cancel_fn` is the load-bearing field for cancellation of in-flight I/O: while an
operation is outstanding, the scheduler installs a `cancel_fn` that, when invoked,
submits an `io_uring` _cancel_ request for that operation.

### `io_job` — the SQE user-data tag (Linux only)

This is the key bridge between a CQE and a suspended fiber, in
`lib_eio_linux/sched.ml`:

```ocaml
(* lib_eio_linux/sched.ml *)
type io_job =
  | Read : rw_req -> io_job
  | Job_no_cancel : int Suspended.t -> io_job
  | Cancel_job : io_job
  | Job : int Suspended.t -> io_job   (* negative result = error / cancellation *)
  | Write : rw_req -> io_job
  | Job_fn : 'a Suspended.t * (int -> [`Exit_scheduler]) -> io_job
```

Each SQE is submitted with one of these as its user-data. `Uring.t` is parameterised on
this type — `uring : io_job Uring.t` — so a CQE comes back as
`{ data : io_job; result : int }`. The variant tells the scheduler how to deliver
`result`:

| Variant          | Carries                    | Completion behaviour                                                              |
| ---------------- | -------------------------- | --------------------------------------------------------------------------------- |
| `Read` / `Write` | `rw_req` (fixed-buffer op) | May resubmit on short read/write or `EAGAIN`; otherwise resume with byte count    |
| `Job`            | `int Suspended.t`          | Resume with result; if `result < 0` and fiber was cancelled, raise the cancel exn |
| `Job_no_cancel`  | `int Suspended.t`          | Resume unconditionally (used for `noop`, etc. — not cancellable)                  |
| `Job_fn`         | `Suspended.t * (int -> …)` | Run a callback with the result (used by `await_readable`/`await_writable`)        |
| `Cancel_job`     | nothing                    | The result of a cancel SQE — discarded, just reschedule                           |

### `t` — the scheduler state

The central loop object (`lib_eio_linux/sched.ml`). Annotated:

```ocaml
(* lib_eio_linux/sched.ml *)
type t = {
  uring: io_job Uring.t;                 (* the io_uring instance *)
  mem: Uring.Region.t option;            (* registered fixed buffer for read_fixed/write_fixed *)
  io_q: (t -> unit) Queue.t;             (* ops parked because the SQ was full *)
  mem_q : ... Lwt_dllist.t;              (* fibers waiting for a free fixed-buffer chunk *)
  run_q : runnable Lf_queue.t;           (* runnable fibers; other domains push here too *)
  eventfd : Eio_unix.Private.Rcfd.t;     (* cross-domain / cross-thread wakeup fd *)
  need_wakeup : bool Atomic.t;           (* "I am about to sleep; signal me" *)
  sleep_q: Zzz.t;                        (* timer wheel (priority queue of deadlines) *)
  thread_pool : Eio_unix.Private.Thread_pool.t;  (* for blocking syscalls off-ring *)
}
```

`run_q` holds `runnable` items:

```ocaml
type runnable =
  | IO : runnable                              (* a sentinel: "go check io_uring/timers" *)
  | Thread : 'a Suspended.t * 'a -> runnable   (* resume this fiber with this value *)
  | Failed_thread : 'a Suspended.t * exn -> runnable  (* resume this fiber with this exn *)
```

A single `IO` sentinel is permanently re-injected into `run_q`; it is the scheduler's
reminder to poll the ring and the timer queue once all immediately-runnable fibers have
been drained. `Lf_queue` is a Michael–Scott style lock-free queue (`Eio_utils.Lf_queue`),
chosen precisely so that _other domains_ can `push` wakeups without locking.

---

## How it works

### The three effects the scheduler interprets

`eio_linux` runs the program inside `Effect.Deep.match_with`, whose `effc` handler
matches three families of effects. Two are generic (defined in `lib_eio/core`), one is
backend-private.

1. **`Eio.Private.Effects.Suspend`** (from `lib_eio/core/suspend.ml`) — the _generic_
   suspension primitive:

   ```ocaml
   (* lib_eio/core/suspend.ml *)
   type 'a enqueue = ('a, exn) result -> unit
   type _ Effect.t += Suspend :
     (Cancel.fiber_context -> 'a enqueue -> unit) -> 'a Effect.t

   let enter op fn =
     enter_unchecked op @@ fun fiber enqueue ->
     match Cancel.Fiber_context.get_error fiber with
     | None -> fn fiber enqueue
     | Some ex -> enqueue (Error ex)
   ```

   The fiber performs `Suspend f`. The handler captures the continuation `k`, wraps it as
   a `Suspended.t`, and hands `f` an `enqueue` callback. `f` arranges for `enqueue` to be
   called later (on completion / wakeup); `enqueue (Ok v)` pushes `Thread (k, v)` and
   `enqueue (Error ex)` pushes `Failed_thread (k, ex)`. This is how _non-uring_ wakeups
   (mutexes, condition variables, cross-domain results) re-enter the scheduler.

2. **`Enter`** (backend-private, in `sched.ml`) — the _fast path_ for I/O that talks
   directly to the ring without an intermediate `enqueue` closure:

   ```ocaml
   (* lib_eio_linux/sched.ml *)
   type _ Effect.t +=
     | Enter : (t -> 'a Suspended.t -> unit) -> 'a Effect.t
     | Cancel : io_job Uring.job -> unit Effect.t
     | Get : t Effect.t
   ```

   The handler for `Enter fn` builds `k = { Suspended.k; fiber }`, calls `fn st k` (which
   submits an SQE tagged with a `Job k` referencing that very continuation), then calls
   `schedule st`. The fiber is now suspended with its continuation stored inside the SQE's
   user-data.

3. **`Fork`** (generic) — creates a child fiber. The handler re-injects the parent at the
   _head_ of `run_q` (`enqueue_at_head`) and recurses into `fork ~new_fiber f`, so the
   child runs first and the parent resumes promptly afterwards.

The full `effc` dispatch (abridged) shows all of them living together:

```ocaml
(* lib_eio_linux/sched.ml — Sched.run, effc *)
effc = fun (type a) (e : a Effect.t) ->
  match e with
  | Get -> Some (fun k -> continue k st)
  | Enter fn -> Some (fun k ->
      match Fiber_context.get_error fiber with
      | Some e -> discontinue k e          (* already cancelled: don't even submit *)
      | None ->
        let k = { Suspended.k; fiber } in
        fn st k;                            (* submit the SQE, storing [k] in its user-data *)
        schedule st)                        (* hand control back to the loop *)
  | Cancel job -> Some (fun k -> enqueue_cancel job st; continue k ())
  | Eio.Private.Effects.Suspend f -> Some (fun k ->
      let k = { Suspended.k; fiber } in
      f fiber (function Ok v -> enqueue_thread st k v
                      | Error ex -> enqueue_failed_thread st k ex);
      schedule st)
  | Eio.Private.Effects.Fork (new_fiber, f) -> Some (fun k ->
      let k = { Suspended.k; fiber } in
      enqueue_at_head st k ();
      fork ~new_fiber f)
  | Eio_unix.Private.Await_readable fd -> Some (fun k -> … poll_add … )
  | Eio_unix.Private.Await_writable fd -> Some (fun k -> … poll_add … )
  | Eio_unix.Private.Thread_pool.Run_in_systhread fn -> Some (fun k -> … submit to pool … )
  | e -> extra_effects.effc e
```

### From an I/O call to an SQE

Trace a read. `Eio.Flow.read` on a file ends up in `Low_level`
(`lib_eio_linux/low_level.ml`), which builds an `rw_req` and calls
`Sched.submit_rw_req`:

```ocaml
(* lib_eio_linux/low_level.ml *)
let enqueue_read st action (file_offset, fd, buf, len) =
  let req = { Sched.op = `R; file_offset; len; fd; cur_off = 0; buf; action } in
  Sched.submit_rw_req st req
```

`submit_rw_req` (in `sched.ml`) computes the offset into the registered fixed buffer and
submits the SQE through `with_cancel_hook`:

```ocaml
(* lib_eio_linux/sched.ml *)
let rec submit_rw_req st ({op; file_offset; fd; buf; len; cur_off; action} as req) =
  let off = Uring.Region.to_offset buf + cur_off in
  …
  let retry = with_cancel_hook ~action st (fun () ->
      match op with
      | `R -> Uring.read_fixed uring ~file_offset fd ~off ~len (Read req)
      | `W -> Uring.write_fixed uring ~file_offset fd ~off ~len (Write req))
  in
  if retry then Queue.push (fun st -> submit_rw_req st req) io_q  (* SQ full: park it *)
```

`with_cancel_hook` is where the proactor and the cancellation model meet:

```ocaml
(* lib_eio_linux/sched.ml *)
let with_cancel_hook ~action t fn =
  match Fiber_context.get_error action.Suspended.fiber with
  | Some ex -> enqueue_failed_thread t action ex; false   (* cancelled before submit *)
  | None ->
    match enqueue_job t fn with
    | None -> true                                        (* no SQE slots: retry later *)
    | Some job ->
      Fiber_context.set_cancel_fn action.fiber (fun _ -> cancel job);
      false
```

`enqueue_job` calls the supplied `fn` (which actually allocates the SQE and returns a
`Uring.job` handle); if the SQ is full it calls `submit t.uring` to flush and retries.
Once submitted, the fiber's `cancel_fn` is set to _submit a cancel SQE for this job_. The
continuation now lives inside the SQE's `Read req` / `Job action` user-data, and the fiber
is suspended (the `Enter` handler called `schedule st`).

### The scheduler loop — pulling completions

`schedule` is the heart (abridged from `sched.ml`). It is a _not-fair_ loop: it drains
`run_q`, then services timers, then the ring, sleeping only when nothing is runnable.

```ocaml
(* lib_eio_linux/sched.ml *)
let rec schedule ({run_q; sleep_q; uring; _} as st) : [`Exit_scheduler] =
  match Lf_queue.pop run_q with
  | Some Thread (k, v) ->                       (* a ready fiber: resume it *)
      Fiber_context.clear_cancel_fn k.fiber; Suspended.continue k v
  | Some Failed_thread (k, ex) ->
      Fiber_context.clear_cancel_fn k.fiber; Suspended.discontinue k ex
  | Some IO ->                                   (* the sentinel: check timers + ring *)
      let now = Mtime_clock.now () in
      match Zzz.pop ~now sleep_q with
      | `Due k -> Lf_queue.push run_q IO; (* re-inject *) … resume the timer …
      | `Wait_until _ | `Nothing as next_due ->
        match Uring.get_cqe_nonblocking uring with
        | Some { data = runnable; result } ->    (* a completion! *)
            Lf_queue.push run_q IO;              (* re-inject the sentinel first *)
            handle_complete st ~runnable (result :> int)
        | None ->
            (* nothing pending; submit queued SQEs and either spin or sleep *)
            if not (Lf_queue.is_empty st.run_q) then ( ignore (submit uring); … schedule st )
            else if timeout = None && Uring.active_ops uring = 0 then `Exit_scheduler
            else (
              Atomic.set st.need_wakeup true;
              Trace.suspend_domain Begin;
              let result = Uring.wait ~timeout uring in   (* io_uring_enter, blocking *)
              Trace.suspend_domain End;
              Atomic.set st.need_wakeup false;
              Lf_queue.push run_q IO;
              match result with
              | None -> schedule st               (* timeout / signal *)
              | Some { data = runnable; result } -> handle_complete st ~runnable (result :> int))
  | None -> assert false                          (* the IO sentinel is always present *)
```

Notable design points visible here:

- **Re-inject `IO` before doing anything else.** Every branch that consumes the `IO`
  sentinel pushes it back before resuming a fiber, guaranteeing the loop will revisit the
  ring after the fiber re-suspends or finishes.
- **Non-blocking drain first.** `Uring.get_cqe_nonblocking` is tried before the blocking
  `Uring.wait`; this is faster when completions are already available.
- **Exit condition.** When `run_q` is empty, there is no timer, and `Uring.active_ops = 0`
  (no in-flight SQEs), there is genuinely nothing to do — the loop returns
  `` `Exit_scheduler ``.
- **The `1e9` timeout hack.** `Uring.wait` is given a default 1-second timeout even when
  "infinite", so that the domain returns to OCaml mode periodically to run pending signal
  handlers — liburing would otherwise auto-retry `io_uring_enter` after `EINTR`
  ([eio#732]).

### From a CQE back to the fiber — `handle_complete`

This is the survey's central mapping. A CQE's `data` field is the `io_job` we submitted;
`handle_complete` dispatches on it:

```ocaml
(* lib_eio_linux/sched.ml *)
and handle_complete st ~runnable result =
  submit_pending_io st;                 (* an SQE slot freed up: submit a parked op *)
  match runnable with
  | Read req | Write req -> complete_rw_req st req result
  | Job k ->
      Fiber_context.clear_cancel_fn k.fiber;
      if result >= 0 then Suspended.continue k result
      else (match Fiber_context.get_error k.fiber with
            | None -> Suspended.continue k result          (* genuine errno (negative) *)
            | Some e -> Suspended.discontinue k e)         (* cancelled: raise instead *)
  | Job_no_cancel k -> Suspended.continue k result
  | Cancel_job -> schedule st            (* result of a cancel SQE: ignore, keep going *)
  | Job_fn (k, f) ->
      Fiber_context.clear_cancel_fn k.fiber;
      (match Fiber_context.get_error k.fiber with None -> f result | Some e -> Suspended.discontinue k e)
```

So the resume path is, in full:

1. The kernel posts a CQE `{ data = Job k; result = n }`.
2. `schedule` reads it via `get_cqe_nonblocking` / `wait`.
3. `handle_complete` matches `Job k`, clears the now-irrelevant `cancel_fn`, and calls
   `Suspended.continue k n`.
4. `Suspended.continue` is `Effect.Deep.continue k.k n` — it **resumes the one-shot
   delimited continuation**, so the fiber's `Uring.read …` call appears to _return_ `n`,
   and the fiber runs forward in ordinary direct style.

That is the whole trick: **a CQE is decoded into a `continue` of the exact continuation
that was suspended at the I/O call site.** No callbacks, no promise, no monad — the result
flows straight back into the fiber's stack.

`complete_rw_req` adds the short-read/retry logic for fixed-buffer reads and writes:

```ocaml
(* lib_eio_linux/sched.ml *)
and complete_rw_req st ({len; cur_off; action; _} as req) res =
  Fiber_context.clear_cancel_fn action.fiber;
  match res, len with
  | 0, _ -> Suspended.discontinue action End_of_file
  | e, _ when e < 0 ->
      (match Fiber_context.get_error action.fiber with
       | Some e -> Suspended.discontinue action e
       | None -> if errno_is_retry e             (* EINTR / EAGAIN(=EWOULDBLOCK) / ETIME *)
                 then (submit_rw_req st req; schedule st)
                 else Suspended.continue action e)
  | n, Exactly len when n < len - cur_off ->     (* short read: advance and resubmit *)
      req.cur_off <- req.cur_off + n; submit_rw_req st req; schedule st
  | _, Exactly len -> Suspended.continue action len
  | n, Upto _ -> Suspended.continue action n
```

### Which io_uring ops the backend uses

`Low_level` submits these operations through the [ocaml-uring] binding (`Uring.*`). They
map directly to `io_uring` opcodes:

| Eio operation                       | `Uring.*` call                      | `io_uring` opcode (effective)             |
| ----------------------------------- | ----------------------------------- | ----------------------------------------- |
| File/socket read (fixed buffer)     | `Uring.read_fixed`                  | `IORING_OP_READ_FIXED`                    |
| File/socket write (fixed buffer)    | `Uring.write_fixed`                 | `IORING_OP_WRITE_FIXED`                   |
| Vectored read / write               | `Uring.readv` / `Uring.writev`      | `IORING_OP_READV` / `IORING_OP_WRITEV`    |
| Zero-copy pipe transfer             | `Uring.splice`                      | `IORING_OP_SPLICE`                        |
| Open (sandboxed via `resolve`)      | `Uring.openat2`                     | `IORING_OP_OPENAT2`                       |
| Stat                                | `Uring.statx`                       | `IORING_OP_STATX`                         |
| Unlink / rmdir                      | `Uring.unlink`                      | `IORING_OP_UNLINKAT`                      |
| Connect                             | `Uring.connect`                     | `IORING_OP_CONNECT`                       |
| Accept                              | `Uring.accept`                      | `IORING_OP_ACCEPT`                        |
| Send / receive (incl. `SCM_RIGHTS`) | `Uring.send_msg` / `Uring.recv_msg` | `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` |
| Readiness poll (for `Await_*`)      | `Uring.poll_add`                    | `IORING_OP_POLL_ADD`                      |
| No-op (benchmark / liveness)        | `Uring.noop`                        | `IORING_OP_NOP`                           |
| Cancel an outstanding op            | `Uring.cancel`                      | `IORING_OP_ASYNC_CANCEL`                  |

See [io_uring opcodes reference][io-uring-opcodes] for the full opcode catalogue and their
kernel-version availability.

Note the _hybrid_ nature: even on the proactor backend, `Await_readable` / `Await_writable`
(used by `Eio_unix` for fds Eio doesn't own, e.g. wrapped third-party sockets) are
implemented by submitting a `poll_add` SQE — a one-shot readiness notification delivered as
a CQE. This is the reactor pattern expressed _through_ the proactor's completion queue.

### Version gating and the fallback path

`with_sched` in `sched.ml` does feature detection at startup:

```ocaml
(* lib_eio_linux/sched.ml *)
let uring_create ~queue_depth ?polling_timeout () =
  let flags = Uring.Setup_flags.(single_issuer + defer_taskrun + taskrun_flag) in
    (* Requires Linux >= 6.1 *)
  match Uring.create ~queue_depth ~flags ?polling_timeout () with
  | exception Unix.Unix_error(EINVAL, _, _) -> Uring.create ~queue_depth ?polling_timeout ()
  | x -> x

let with_sched ?(fallback=no_fallback) config fn =
  match uring_create ~queue_depth ?polling_timeout () with
  | exception Unix.Unix_error(ENOSYS, _, _) -> fallback (`Msg "io_uring is not available on this system")
  | exception Unix.Unix_error(EPERM, _, _)  -> fallback (`Msg "io_uring is not available (permission denied)")
  | uring ->
    let probe = Uring.get_probe uring in
    if not (Uring.op_supported probe Uring.Op.mkdirat) then (
      Uring.exit uring;
      fallback (`Msg "Linux >= 5.15 is required for io_uring support")
    ) else (
      if not !statx_works && Uring.op_supported probe Uring.Op.msg_ring then statx_works := true;
      …
    )
```

The gating, with the kernel facts verified against the `io_uring` manuals and LWN:

| Probe / flag                                   | Meaning                                                                                 | Kernel |
| ---------------------------------------------- | --------------------------------------------------------------------------------------- | ------ |
| `Uring.create` raises `ENOSYS`                 | `io_uring_setup(2)` not compiled in                                                     | < 5.1  |
| `Uring.create` raises `EPERM`                  | Blocked (seccomp, `io_uring_disabled` sysctl, container)                                | n/a    |
| `single_issuer + defer_taskrun + taskrun_flag` | Single-issuer + deferred task-run optimisation (with `EINVAL` fallback to plain create) | ≥ 6.1  |
| `Op.mkdirat` not supported → fall back         | `IORING_OP_MKDIRAT` is the minimum-feature canary                                       | ≥ 5.15 |
| `Op.msg_ring` supported → trust `statx`        | `IORING_OP_MSG_RING` as a proxy for "statx is reliable"                                 | ≥ 5.18 |

Three layers of fallback are therefore in play:

1. **Setup-flag fallback (in-backend):** if the kernel rejects the
   `single_issuer + defer_taskrun` flags with `EINVAL` (< 6.1), retry `Uring.create`
   without them. `io_uring` still works, just without the deferred-task-run optimisation.
2. **Backend fallback (in `eio_main`):** if `io_uring` is missing/blocked or the kernel is
   < 5.15, the `fallback` continuation is invoked and `eio_main` selects `eio_posix`:

   ```ocaml
   (* lib_main/eio_main.ml *)
   let run fn =
     match Sys.getenv_opt "EIO_BACKEND" with
     | Some ("io-uring" | "linux") -> force Linux_backend.run fn
     | Some "posix" -> force Posix_backend.run fn
     | None | Some "" ->
       Linux_backend.run fn ~fallback:(fun _ ->
         Posix_backend.run fn ~fallback:(fun _ -> force Windows_backend.run fn))
     | …
   ```

3. **Feature flag (`statx_works`):** a global set once when `msg_ring` is supported,
   recording that statx results can be trusted (statx over `io_uring` was unreliable before
   5.18). The `mkdirat` probe message text _says_ "Linux >= 5.15", which is the effective
   floor for the `io_uring` backend; older kernels silently use `eio_posix`.

`EIO_BACKEND=io-uring` forces the Linux backend (no fallback), and `EIO_BACKEND=posix`
forces the reactor backend even on a capable kernel — useful for testing both code paths.

### Cross-domain wakeups via `eventfd`

The run queue is lock-free and may be pushed from any domain (e.g. a worker domain
resolving a promise that a fiber on this domain is awaiting), from a systhread in the
blocking-syscall pool, or from a signal handler / GC finalizer. But a domain that is asleep
inside `Uring.wait` will not notice a new `run_q` entry. The `need_wakeup` /`eventfd`
protocol handles this:

```ocaml
(* lib_eio_linux/sched.ml *)
let wakeup t =
  Atomic.set t.need_wakeup false;          (* recipient will re-check run_q after the event *)
  Eio_unix.Private.Rcfd.use t.eventfd
    (fun fd -> let sent = Unix.single_write fd wake_buffer 0 8 in assert (sent = 8))
    ~if_closed:ignore

let enqueue_thread st k x =
  Lf_queue.push st.run_q (Thread (k, x));
  if Atomic.get st.need_wakeup then wakeup st
```

Before sleeping, the scheduler sets `need_wakeup := true` and then _re-checks_ `run_q` is
empty (the double-check in `schedule` between setting the flag and calling `Uring.wait`).
A producer pushes to `run_q`, then reads `need_wakeup`; if `true`, it writes 8 bytes to the
`eventfd`. The eventfd is itself monitored _by io_uring_: a daemon fiber
(`monitor_event_fd`) sits in a loop doing a `readv` (an `IORING_OP_READV`) on the eventfd,
so a write to it produces a CQE that wakes the blocked `Uring.wait`. After waking, the
scheduler drains `run_q` and resumes the newly-enqueued fiber:

```ocaml
(* lib_eio_linux/sched.ml — installed as a daemon fiber at startup *)
let monitor_event_fd t =
  let buf = Cstruct.create 8 in
  Eio_unix.Private.Rcfd.use ~if_closed:(fun () -> failwith "event_fd closed!") t.eventfd @@ fun fd ->
  while true do
    let got = read_eventfd fd buf in       (* suspends on a uring readv until written *)
    assert (got = 8)
    (* go back to sleep; the scheduler will re-scan run_q for new items *)
  done
```

The `eventfd` fd itself is wrapped in `Rcfd` (a reference-counted fd) so that producers and
the consumer can race on close without a use-after-free; `~if_closed:ignore` makes a wakeup
to an already-shut-down domain a harmless no-op. The `eio_eventfd` C stub
(`lib_eio_linux/eio_stubs.c`, bound as `caml_eio_eventfd`) creates the underlying
`eventfd(2)`.

### Cancellation over io_uring

Cancellation is structural (driven by `Cancel`/`Switch`, see
[Eio's capabilities doc][eio-capabilities]) but the _mechanism_ for an in-flight ring op is
specific to this backend. The sequence (documented inline in `sched.ml`):

1. Submit the op, obtaining a `Uring.job` handle.
2. Set the fiber's `cancel_fn` to `fun _ -> cancel job` (where `cancel` performs the
   `Cancel job` effect → `enqueue_cancel`, which submits an `IORING_OP_ASYNC_CANCEL` SQE
   tagged `Cancel_job`).
3. On completion, clear the `cancel_fn`.

If the context is cancelled while the op is running, `Cancel.cancel` walks the cancel tree
and invokes each fiber's `cancel_fn`, which submits the async-cancel SQE. Two CQEs then
arrive: the cancel SQE's result (`Cancel_job`, discarded — possible `ENOENT`/`EALREADY` are
ignored) and the original op's result. If the original op's CQE comes back with a negative
result _and_ the fiber's context is now in error, `handle_complete`/`complete_rw_req`
deliver the cancellation exception via `Suspended.discontinue` instead of the raw errno.
Because the continuation is one-shot, exactly one of `continue`/`discontinue` ever fires.

### The `eio_posix` fallback scheduler

`lib_eio_posix/sched.ml` (Thomas Leonard, 2023) is a _reactor_ with the same skeleton —
same `run_q`/`runnable`/`IO`-sentinel/`eventfd` design — but readiness instead of
completion. Differences:

- **No `io_job`.** There are no SQEs. Instead, a per-fd `fd_event_waiters` record holds two
  `Lwt_dllist`s of `unit Suspended.t` (one for read-readiness, one for write-readiness):

  ```ocaml
  (* lib_eio_posix/sched.ml *)
  type fd_event_waiters = { read : unit Suspended.t Lwt_dllist.t;
                            write : unit Suspended.t Lwt_dllist.t }
  ```

- **`poll`/`ppoll`, not `io_uring_enter`.** The loop calls
  `Poll.ppoll_or_poll t.poll (t.poll_maxi + 1) timeout` (via the `iomux` library). When an
  fd is ready, `ready` transfers the matching waiters into a pending list and `resume`s each
  by pushing `Thread (k, ())` onto `run_q`.
- **I/O itself is synchronous, off the loop.** Because `poll` only signals readiness, the
  actual `read`/`write`/`accept` syscalls run directly (often via the C stubs in
  `eio_posix_stubs.c` and the blocking-syscall thread pool). The fiber is resumed with
  `()` — "the fd is ready" — and then performs the syscall.
- **`eventfd` is a self-pipe.** Where `eio_linux` uses a real `eventfd(2)` monitored by a
  uring `readv`, `eio_posix` uses a non-blocking `Unix.pipe` whose read end is registered in
  the `poll` set; `clear_event_fd` drains it on wakeup. On macOS/BSD the underlying `iomux`
  `poll` may sit atop `kqueue`.

The `Suspend`/`Fork`/`Await_readable`/`Await_writable` effects are interpreted by the _same_
handler shape — the only thing that changes is what "register interest" and "wait for an
event" mean. This is why the same direct-style Eio program runs unchanged on either backend:
the effect interface (`lib_eio/core`) is the portable contract; the scheduler is the
swappable interpreter. For the broader pattern of "effects as the portable interface, event
loop as the interpreter", see [Effects and event loops][effects-and-event-loops].

---

## Performance approach

- **Batching at the ring.** Multiple SQEs accumulate and are flushed with a single
  `Uring.submit` (one `io_uring_enter`) when the loop is about to wait or when the SQ
  fills. `submit` is a no-op when `Uring.sqe_ready uring = 0`, so idle loops don't syscall.
- **Fixed (registered) buffers.** `read_fixed`/`write_fixed` operate on a pre-registered
  `Uring.Region.t` (the `mem` field), avoiding per-op buffer pinning in the kernel.
  Fibers that need a chunk but find none wait on `mem_q`.
- **`SINGLE_ISSUER` + `DEFER_TASKRUN`.** On Linux ≥ 6.1 these flags tell the kernel that one
  thread issues all requests and that completion task-work should be deferred until the next
  `io_uring_enter(GETEVENTS)` — reducing lock contention and spurious wakeups. Eio degrades
  gracefully (plain create) on older kernels.
- **Real stacks, no allocation for control flow.** Suspending a fiber is capturing a
  one-shot continuation; resuming it is `Effect.Deep.continue`. There is no per-await heap
  promise as in Lwt. (In practice some workloads still need explicit buffering to match
  Lwt's incidental batching — see the capabilities doc's performance notes.)
- **Non-fair, completion-first scheduling.** Timers run before other I/O, ready fibers
  before the ring is polled; the `IO` sentinel guarantees the ring is eventually serviced.
  The non-blocking CQE drain (`get_cqe_nonblocking`) avoids a syscall when completions are
  already queued.
- **Blocking syscalls off-ring.** Operations `io_uring` can't do asynchronously go to a
  `Thread_pool` (`Run_in_systhread` effect), keeping the loop responsive.

---

## Strengths

- **True direct-style I/O.** A CQE resumes the exact continuation suspended at the call
  site, so I/O reads as straight-line code with working backtraces and `try…with`.
- **Single coherent design across backends.** `run_q` + `IO` sentinel + `eventfd` wakeup is
  shared by `eio_linux` and `eio_posix`; only the wait primitive differs.
- **Proactor efficiency on modern kernels.** Batched submission, fixed buffers, and the
  6.1 setup flags exploit `io_uring`'s strengths; readiness (`poll_add`) is available within
  the same queue when needed.
- **Robust cancellation.** Async-cancel SQEs plus one-shot continuations make
  cancel-vs-complete races safe by construction.
- **Cross-domain safe.** Lock-free run queue with an `eventfd` doorbell integrates
  multi-domain wakeups, the systhread pool, and even GC finalizers.
- **Graceful degradation.** Three fallback layers (setup flags → posix backend → windows),
  selectable/forceable via `EIO_BACKEND`.

## Weaknesses

- **Linux-kernel floor.** The `io_uring` backend needs ≈ 5.15 for its feature canary and
  prefers ≥ 6.1; older systems silently drop to the `poll` reactor with different
  performance characteristics. `eio_linux` is `available: [os = "linux"]` only.
- **`io_uring` operational hazards.** Blocked by seccomp/`io_uring_disabled` in many hardened
  environments (returns `EPERM` → fallback); the surface has had a stream of kernel CVEs.
- **Behavioural skew between backends.** Completion vs. readiness semantics, short-read
  retry logic, and statx reliability differ; code must be tested on both.
- **Non-fair scheduler.** Timers and ready fibers always preempt fresh I/O; a busy CPU-bound
  fiber that never yields can starve the loop (mitigated by `Fiber.yield`).
- **Untyped effects underneath.** The `Suspend`/`Enter`/`Fork` effects are not tracked by
  OCaml's type system; a missing handler is a runtime `Unhandled` error.
- **Tied to ocaml-uring.** The backend depends on the `uring` package (≥ 2.7.0), which
  vendors liburing; the binding surface bounds which opcodes Eio can use.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                          | Trade-off                                                                |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| CQE user-data is a typed `io_job` holding the `Suspended.t` | Lets `handle_complete` resume the exact fiber with one `continue`; no lookup table | One GC-tracked closure per in-flight op; ring is monomorphic in `io_job` |
| One-shot delimited continuations (`Effect.Deep`)            | Direct style, real stacks, no per-await heap promise                               | Must call `continue`/`discontinue` exactly once; effects are untyped     |
| Single permanent `IO` sentinel in `run_q`                   | Cheap reminder to poll ring + timers after draining ready fibers                   | Scheduler must remember to re-inject it on every consuming branch        |
| Lock-free `run_q` + `eventfd` doorbell + `need_wakeup`      | Other domains/threads/signal handlers can wake a sleeping loop without locks       | Subtle double-check race window around `need_wakeup`; needs `Rcfd`       |
| `single_issuer + defer_taskrun`, with `EINVAL` retry        | Maximises `io_uring` throughput on ≥ 6.1                                           | Extra setup attempt; optimisation silently absent on older kernels       |
| `mkdirat` op-probe as the 5.15 feature floor                | Single reliable canary instead of querying a kernel version string                 | The "Linux ≥ 5.15" message is a proxy, not a precise version gate        |
| Fixed registered buffers for `read`/`write`                 | Avoids per-op kernel buffer pinning                                                | Fibers may block on `mem_q` when the region is exhausted                 |
| Same scheduler skeleton for the `poll` fallback             | One mental model; effect interface is the portable contract                        | Readiness vs. completion semantics leak into retry/short-read code       |
| Blocking syscalls dispatched to a systhread pool            | Keeps the loop responsive for ops `io_uring` can't do async                        | Thread-pool latency; extra cross-thread enqueue + wakeup                 |

---

## Sources

- [Eio GitHub Repository] — source of all `lib_eio*` paths quoted above
- [Eio_linux API] — the Linux/`io_uring` backend's public interface
- [Eio API Documentation] — overall Eio reference
- [ocaml-uring] — the `Uring.*` binding to liburing used by `eio_linux`
- [Eio 1.0 — Effects-based IO for OCaml 5 (OCaml'23 paper)] — design rationale
- [io_uring_setup(2) man page] — `IORING_SETUP_SINGLE_ISSUER` (≥ 6.0), `IORING_SETUP_DEFER_TASKRUN` (≥ 6.1)
- [io_uring: defer task work to when it is needed (LWN)] — `DEFER_TASKRUN` background
- [IORING_OP_MKDIRAT support commit (Linux 5.15)] — mkdirat/symlinkat/linkat added in 5.15
- [io_uring features in Linux 5.18 (Phoronix)] — statx stabilisation and `IORING_OP_MSG_RING`
- [Companion: Eio capabilities & effects API][eio-capabilities]
- [Companion: OCaml 5 effects][ocaml-effects]
- [Companion: Effects and event loops][effects-and-event-loops]
- [Companion: io_uring overview][io-uring-index] · [opcodes reference][io-uring-opcodes]

<!-- References -->

[Eio GitHub Repository]: https://github.com/ocaml-multicore/eio
[Eio API Documentation]: https://ocaml-multicore.github.io/eio/eio/Eio/index.html
[Eio_linux API]: https://ocaml-multicore.github.io/eio/eio_linux/Eio_linux/index.html
[ocaml-uring]: https://github.com/ocaml-multicore/ocaml-uring
[Eio 1.0 — Effects-based IO for OCaml 5 (OCaml'23 paper)]: https://kcsrk.info/papers/eio_ocaml23a.pdf
[io_uring_setup(2) man page]: https://man7.org/linux/man-pages/man2/io_uring_setup.2.html
[io_uring: defer task work to when it is needed (LWN)]: https://lwn.net/Articles/906470/
[IORING_OP_MKDIRAT support commit (Linux 5.15)]: https://github.com/torvalds/linux/commit/e34a02dc40c95d126bb6486dcf802bbb8d1624a0
[io_uring features in Linux 5.18 (Phoronix)]: https://www.phoronix.com/news/Linux-5.18-IO_uring
[eio#732]: https://github.com/ocaml-multicore/eio/issues/732
[eio-capabilities]: ../algebraic-effects/ocaml-eio.md
[ocaml-effects]: ../algebraic-effects/ocaml-effects.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[io-uring-index]: ./io-uring/index.md
[io-uring-opcodes]: ./io-uring/opcodes-reference.md
