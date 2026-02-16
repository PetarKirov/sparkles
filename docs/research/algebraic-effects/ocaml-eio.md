# Eio (OCaml)

Effects-based direct-style I/O library for OCaml 5, providing structured concurrency and capability-based security without monadic encoding.

| Field         | Value                                                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Language      | OCaml 5.x                                                                                                              |
| License       | ISC                                                                                                                    |
| Repository    | [github.com/ocaml-multicore/eio](https://github.com/ocaml-multicore/eio)                                               |
| Documentation | [OCaml Package](https://ocaml.org/p/eio/latest) / [API Docs](https://ocaml-multicore.github.io/eio/eio/Eio/index.html) |
| Key Authors   | Thomas Leonard, KC Sivaramakrishnan, Anil Madhavapeddy                                                                 |
| Encoding      | Direct-style I/O over OCaml 5 algebraic effects with capability passing                                                |

---

## Overview

### What It Solves

Before OCaml 5, concurrent I/O required monadic libraries like Lwt or Async, which simulate multiple stacks on the heap using monadic bind. This imposes allocation overhead, breaks backtraces, and forces a different coding style where every I/O operation must be threaded through monadic combinators. Eio eliminates this by building on OCaml 5's native [algebraic effect handlers](ocaml-effects.md), allowing concurrent code to be written in ordinary direct style -- plain function calls, `try...with` for error handling, and natural backtraces.

### Design Philosophy

Eio follows three guiding principles:

1. **Direct style**: No monadic encoding. Concurrent code looks identical to sequential code. A function that reads a file calls `Eio.Path.load` directly, not a monadic bind chain.

2. **Capability-based security**: I/O operations require explicit capability values. A function cannot access the file system unless it receives a file system capability as an argument. This follows the principle that the lambda calculus already contains a security system -- a function can only access what is in its scope.

3. **Structured concurrency**: Every fiber belongs to a `Switch` that governs its lifetime. When a switch completes, all its fibers have terminated and all its resources have been released. There are no orphaned background tasks.

---

## Core Abstractions and Types

### Entry Point

Every Eio program begins with `Eio_main.run`, which sets up the event loop, selects the appropriate platform backend, and provides the root environment:

```ocaml
let () =
  Eio_main.run @@ fun env ->
    let fs = Eio.Stdenv.fs env in
    let net = Eio.Stdenv.net env in
    main ~fs ~net
```

The `env` value is of type `Eio.Stdenv.t` and bundles all system capabilities. Programs should extract only the capabilities they need and pass them to subsystems explicitly.

### Capabilities from Stdenv

`Eio.Stdenv.t` provides access to system resources following the principle of least authority:

| Capability         | Accessor                | Type                     | Description                     |
| ------------------ | ----------------------- | ------------------------ | ------------------------------- |
| File system (full) | `Eio.Stdenv.fs`         | `_ Eio.Path.t`           | Unrestricted file system access |
| Current directory  | `Eio.Stdenv.cwd`        | `_ Eio.Path.t`           | Sandboxed to working directory  |
| Network            | `Eio.Stdenv.net`        | `_ Eio.Net.t`            | TCP/UDP socket operations       |
| Clock              | `Eio.Stdenv.clock`      | `_ Eio.Time.clock`       | Wall-clock time                 |
| Monotonic clock    | `Eio.Stdenv.mono_clock` | `_ Eio.Time.Mono.t`      | Monotonic time for intervals    |
| Domain manager     | `Eio.Stdenv.domain_mgr` | `_ Eio.Domain_manager.t` | Spawn OS-level domains          |
| Stdout             | `Eio.Stdenv.stdout`     | `_ Eio.Flow.sink`        | Standard output                 |
| Stderr             | `Eio.Stdenv.stderr`     | `_ Eio.Flow.sink`        | Standard error                  |

Functions should request only the capabilities they need:

```ocaml
module Status : sig
  val check : clock:_ Eio.Time.clock -> net:_ Eio.Net.t -> bool
end
```

---

## How Effects Are Declared

Eio does not expose its internal effects to users. Instead, it uses OCaml 5 effects internally for fiber scheduling, I/O suspension, and cancellation. From the user's perspective, I/O operations are ordinary function calls:

```ocaml
(* Reading a file -- no monadic bind, no effect declaration *)
let contents = Eio.Path.load (fs / "config.txt")

(* Writing a file *)
let () = Eio.Path.save ~create:(`Exclusive 0o600)
    (dir / "output.txt") "data"

(* Network connection *)
let response = Eio.Net.with_tcp_connect net ~host ~service:"http"
    @@ fun flow ->
  Eio.Flow.copy_string request flow;
  Eio.Flow.read_all flow

(* Clock operations *)
let now = Eio.Time.now clock
let () = Eio.Time.sleep clock 1.0
```

When a fiber calls an I/O function like `Eio.Path.load`, Eio internally performs an effect that suspends the fiber. The scheduler handles the effect by registering the I/O operation with the OS backend and resuming the fiber when the operation completes.

---

## How Handlers/Interpreters Work

### Switches and Structured Concurrency

A `Switch` groups fibers together and ensures they all complete before the switch exits. This is the primary mechanism for structured concurrency:

```ocaml
Eio.Switch.run @@ fun sw ->
  (* Fork fibers within this switch *)
  Eio.Fiber.fork ~sw (fun () ->
    traceln "Task A running");
  Eio.Fiber.fork ~sw (fun () ->
    traceln "Task B running")
  (* Both tasks complete before Switch.run returns *)
```

### Concurrent Combinators

```ocaml
(* Run two tasks concurrently, wait for both *)
Eio.Fiber.both
  (fun () -> for x = 1 to 3 do traceln "x = %d" x; Eio.Fiber.yield () done)
  (fun () -> for y = 1 to 3 do traceln "y = %d" y; Eio.Fiber.yield () done)

(* Run a list of tasks concurrently *)
Eio.Fiber.all [
  (fun () -> download ~net url1);
  (fun () -> download ~net url2);
  (fun () -> download ~net url3);
]
```

`Fiber.both` and `Fiber.all` run tasks concurrently within the current domain. If any task raises an exception, the others are cancelled automatically.

### Cancellation and Daemon Fibers

Cancellation propagates structurally through switches. When a switch is failed via `Switch.fail`, all its fibers receive a `Cancelled` exception. Critical sections can be protected with `Eio.Cancel.protect`. `Fiber.fork_daemon` creates background fibers that are automatically cancelled when their switch finishes:

```ocaml
Eio.Switch.run @@ fun sw ->
  Eio.Fiber.fork_daemon ~sw (fun () ->
    while true do Eio.Time.sleep clock 60.0; heartbeat ~net done);
  Eio.Fiber.fork ~sw (fun () ->
    try long_running_op ()
    with Eio.Cancel.Cancelled _ -> traceln "Cleaning up...")
```

---

## Performance Approach

Lwt and Async simulate concurrent stacks by allocating promise chains on the heap. Eio uses real stacks (fibers) via OCaml 5's effect runtime, so suspending and resuming a fiber is a stack switch with no heap allocation for control flow.

### Platform-Optimized Backends

| Backend       | Platform          | Mechanism                                 |
| ------------- | ----------------- | ----------------------------------------- |
| `eio_linux`   | Linux             | io_uring for asynchronous batched I/O     |
| `eio_posix`   | macOS, BSD, POSIX | kqueue / poll-based I/O                   |
| `eio_windows` | Windows           | In progress                               |
| `eio_main`    | Any               | Selects appropriate backend automatically |

The io_uring backend writes I/O operations to a ring buffer shared with the kernel, minimizing system call overhead and enabling I/O batching.

### Comparison with Lwt

Eio avoids heap allocations for concurrency, provides correct backtraces, and allows natural use of `try...with` in concurrent code. In practice, comparisons are nuanced: Lwt's scheduling can interact favorably with system-level mechanisms (e.g., Nagle's algorithm), sometimes requiring Eio to add explicit buffering to match throughput. The Eio team continues optimizing I/O performance across backends.

---

## Composability Model

The root `Eio.Stdenv.t` can be subdivided into narrower capabilities. A web server receives only `net` and `clock`; a file processor receives only `fs`. This enables testing with mocks:

```ocaml
(* Production *)
Eio_main.run @@ fun env ->
  Server.start ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)

(* Testing *)
Eio_main.run @@ fun _env ->
  Server.start ~net:(Eio_mock.Net.make ()) ~clock:(Eio_mock.Clock.make ())
```

File system capabilities are sandboxed. `Eio.Stdenv.cwd` restricts access to the working directory; `Eio.Path.with_open_dir` creates further-restricted capabilities. Symlinks escaping the sandbox are rejected, preventing path traversal attacks. Eio also provides `Eio_lwt` for incremental migration from Lwt codebases.

---

## Strengths

- **Direct-style programming** eliminates monadic boilerplate and preserves natural OCaml idioms
- **Capability-based security** makes I/O dependencies explicit and testable
- **Structured concurrency** prevents resource leaks and orphaned fibers
- **Real stack backtraces** work correctly, unlike Lwt where backtraces are fragmented
- **Platform-optimized backends** including io_uring on Linux for high-performance I/O
- **No heap allocation** for concurrency control flow, unlike promise-based libraries
- **Sandboxed file system access** prevents path traversal by default
- **Incremental migration** from Lwt via interoperability layer

## Weaknesses

- **Requires OCaml 5.1+**, limiting adoption on older compiler versions
- **Ecosystem maturity** lags behind Lwt, which has over a decade of library support
- **Untyped effects underneath** inherit the lack of static effect tracking from OCaml 5
- **Windows backend incomplete**, limiting cross-platform use
- **Performance tuning required** for some workloads where Lwt's scheduling incidentally helps
- **Learning curve** for developers accustomed to monadic concurrency patterns
- **Capability passing verbosity** requires threading capabilities through function arguments

## Key Design Decisions and Trade-offs

| Decision                          | Rationale                                        | Trade-off                                     |
| --------------------------------- | ------------------------------------------------ | --------------------------------------------- |
| Direct style over monadic         | Natural code; real backtraces; no bind overhead  | Requires OCaml 5 effects                      |
| Capability passing                | Explicit dependencies; testable; least authority | Verbose signatures; threading required        |
| Structured concurrency via Switch | No orphaned fibers; automatic resource cleanup   | Less flexible than unstructured spawn         |
| Effects hidden from users         | Simpler API; ordinary function calls             | Cannot compose with user-defined effects      |
| Multiple platform backends        | Optimized I/O per platform (io_uring, kqueue)    | Subtle behavioral differences across backends |
| Path sandboxing by default        | Prevents path traversal attacks                  | Must opt in to unrestricted access            |

---

## Sources

- [Eio GitHub Repository](https://github.com/ocaml-multicore/eio)
- [Eio 1.0 Release Announcement (Tarides)](https://tarides.com/blog/2024-03-20-eio-1-0-release-introducing-a-new-effects-based-i-o-library-for-ocaml/)
- [Eio on OCaml Packages](https://ocaml.org/p/eio/latest)
- [Eio API Documentation](https://ocaml-multicore.github.io/eio/eio/Eio/index.html)
- [Eio.Fiber API](https://ocaml-multicore.github.io/eio/eio/Eio/Fiber/index.html)
- [Eio.Path API](https://ocaml-multicore.github.io/eio/eio/Eio/Path/index.html)
- [Eio 1.0 -- Effects-based IO for OCaml 5 (OCaML'23 paper)](https://kcsrk.info/papers/eio_ocaml23a.pdf)
- [OCaml 5 Effects (companion document)](ocaml-effects.md)
- [OCaml 5 Performance Analysis (Thomas Leonard)](https://roscidus.com/blog/blog/2024/07/22/performance/)
- [Eio 0.1 Announcement (OCaml Discuss)](https://discuss.ocaml.org/t/eio-0-1-effects-based-direct-style-io-for-ocaml-5/9298)
