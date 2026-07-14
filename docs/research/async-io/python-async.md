# Python (asyncio, uvloop, Trio)

Python's async story is a study in contrasts: a callback-driven stdlib **readiness** event loop (`asyncio`) layered under coroutines/`await`; a Cython drop-in (`uvloop`) that swaps the multiplexer for [libuv]'s; and `Trio`, a from-scratch runtime whose **nurseries** and **cancel scopes** defined the modern _structured-concurrency_ model that later flowed back into the stdlib's `TaskGroup`/`timeout`.

| Field         | Value                                                                                                        |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| Language      | Python (CPython; quoted sources from the `main`/3.16-alpha tree and Trio `0.33.0+dev`)                       |
| License       | CPython: PSF-2.0 · Trio: MIT or Apache-2.0 · uvloop: MIT or Apache-2.0                                       |
| Repository    | [python/cpython] · [python-trio/trio] · [MagicStack/uvloop]                                                  |
| Documentation | [asyncio docs] · [Trio docs] · [uvloop docs]                                                                 |
| Key Authors   | Guido van Rossum (asyncio / [PEP 3156]); Yury Selivanov (asyncio core, uvloop); Nathaniel J. Smith (Trio)    |
| Pattern       | **Reactor (readiness)** on Unix via `selectors` (epoll/kqueue) + **Proactor (completion)** on Windows (IOCP) |
| Encoding      | `async`/`await` coroutines driven by a callback event loop; **no stdlib io_uring** (GIL + readiness model)   |

---

## Overview

### What it solves

Python is single-threaded for CPU-bound work — the Global Interpreter Lock (GIL) serializes bytecode execution. But the dominant Python workload is I/O-bound (web servers, scrapers, RPC fan-out), where the bottleneck is _waiting_ on sockets, not computing. An event loop lets one OS thread juggle thousands of concurrent connections by multiplexing readiness over a single `epoll`/`kqueue` syscall and resuming whichever coroutine just became unblocked. This is the same niche occupied by [libuv] in Node.js, the [Go netpoller], [Tokio] in Rust, and .NET's [`SocketAsyncEngine`][dotnet] — but Python layers it on top of _generator-based coroutines_ and the `await` keyword rather than green threads or poll-based futures.

The ecosystem splits three ways:

- **`asyncio`** (stdlib, [PEP 3156], code-named _Tulip_, provisional in 3.4, stable in 3.6) — the reference event loop. A _callback_ multiplexer (`add_reader`/`add_writer`) at the bottom, a _transport/protocol_ layer in the middle (Twisted-style), and `coroutine`/`Task`/`Future` + `await` on top. Portable but historically baroque, with a large surface and several reworks (the event-loop-policy deprecations, `asyncio.run`, `TaskGroup`).
- **`uvloop`** — a binary-compatible _drop-in_ that replaces only the loop implementation with a Cython wrapper around [libuv], yielding 2–4× throughput while keeping the entire `asyncio` API.
- **`Trio`** — a clean-room runtime ("an async/await-native library for ... concurrency and I/O") built around **structured concurrency**. It is not asyncio-compatible (the bridge is `trio-asyncio`/`anyio`), and its nursery + cancel-scope model is the most influential idea in the space.

### Design philosophy

- **Coroutines, not callbacks (at the top).** Since Python 3.5, `async def`/`await` compile to coroutine objects; `await fut` suspends by _yielding the Future out_ through the coroutine chain until a `Task` catches it. The loop itself, however, is pure callbacks — coroutines are an upper layer glued on by `Task`.
- **Readiness, not completion (on Unix).** `asyncio`'s `SelectorEventLoop` asks the OS "tell me when this fd is readable", then issues the `recv` itself — the epoll/kqueue model shared with [Tokio]'s [mio] and the [Go netpoller]. Only the _Windows_ `ProactorEventLoop` is completion-based (IOCP). See [primitives] and [techniques] for the readiness-vs-completion dichotomy.
- **No stdlib `io_uring`.** Unlike [Tokio], [Glommio], or [Eio][eio], CPython ships _no_ `io_uring` backend. The readiness model maps poorly onto `io_uring`'s submission/completion rings, file I/O is delegated to a thread pool anyway, and the GIL caps the syscall-batching upside. (Third-party experiments exist, but nothing is in the stdlib — see [io-uring/index].)
- **Structured concurrency as a retrofit (asyncio) vs. a foundation (Trio).** Trio makes _every_ task live inside a nursery and _every_ blocking point a cancellation checkpoint. asyncio bolted the same idea on in 3.11 (`TaskGroup`, `timeout`) atop its older unstructured `create_task`/`gather` core.

### Three designs at a glance

| Axis                | asyncio (stdlib)                                | uvloop                          | Trio                                          |
| ------------------- | ----------------------------------------------- | ------------------------------- | --------------------------------------------- |
| Loop implementation | Pure Python + C `Future`/`Task`                 | Cython over [libuv] (C)         | Pure Python (`unrolled_run` generator)        |
| API surface         | `asyncio` API                                   | _same_ `asyncio` API (drop-in)  | distinct `trio` API                           |
| Unix backend        | `selectors` (epoll/kqueue), readiness           | libuv (epoll/kqueue), readiness | epoll (`EPOLLONESHOT`)/kqueue, readiness      |
| Windows backend     | IOCP (`ProactorEventLoop`), completion          | libuv IOCP                      | IOCP (`WindowsIOManager`)                     |
| Spawn model         | unstructured `create_task` + `TaskGroup` (3.11) | inherits asyncio                | **only** via nurseries                        |
| Cancellation        | per-task `cancel()` + scoped `timeout()` (3.11) | inherits asyncio                | scoped (`CancelScope`), mandatory checkpoints |
| Relative speed      | baseline                                        | ~2–4× asyncio                   | comparable to asyncio (pure Python)           |
| Platforms           | Linux/macOS/BSD/Windows                         | Unix only                       | Linux/macOS/BSD/Windows                       |

---

## Core abstractions and types

| Concept                     | asyncio                                                                | Trio                                                    |
| --------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------- |
| Loop / runtime object       | `BaseEventLoop` (`base_events.py`)                                     | `Runner` + `unrolled_run` generator (`_core/_run.py`)   |
| Multiplexer (Unix)          | `selectors.DefaultSelector` (epoll/kqueue) via `BaseSelectorEventLoop` | `EpollIOManager` / `KqueueIOManager` (`_core/_io_*.py`) |
| Multiplexer (Windows)       | `IocpProactor` + `ProactorEventLoop`                                   | `WindowsIOManager` (IOCP)                               |
| Schedulable unit            | `Task` (subclass of `Future`; C-accelerated `_asyncio.Task`)           | `Task` (`_core/_run.py`, `NoPublicConstructor`)         |
| Awaitable result            | `Future` (C-accelerated `_asyncio.Future`)                             | trap return value via `wait_task_rescheduled`           |
| Immediate callback handle   | `events.Handle`                                                        | run-queue entry (`runner.runq`)                         |
| Timer handle                | `events.TimerHandle` (in the `_scheduled` heap)                        | `CancelScope` deadline (in `Deadlines` heap)            |
| Ready queue                 | `self._ready` (`collections.deque`)                                    | `runner.runq`                                           |
| Timer queue                 | `self._scheduled` (`heapq`)                                            | `runner.deadlines` (`Deadlines`, a min-heap)            |
| Structured-concurrency unit | `asyncio.TaskGroup` (3.11)                                             | `Nursery` via `open_nursery()`                          |
| Timeout primitive           | `asyncio.timeout()` / `Timeout` (3.11)                                 | `move_on_after` / `fail_after` (`_timeouts.py`)         |
| Cancellation token          | per-task `cancel()`/`uncancel()`/`cancelling()`                        | `CancelScope` (`cancel()`, `deadline`, `shield`)        |
| Entry point                 | `asyncio.run` / `asyncio.Runner` (`runners.py`)                        | `trio.run` (`_core/_run.py`)                            |
| Callback I/O layer          | transports + protocols (`transports.py`/`protocols.py`)                | streams (`SocketStream`, `Channel`) — no callback layer |

### The asyncio loop object

`BaseEventLoop` ([`Lib/asyncio/base_events.py`]) is, in its own words, "a multiplexer (the part responsible for notifying us of I/O events) and the event loop proper, which wraps a multiplexer with functionality for scheduling callbacks." It holds two queues:

```python
# Lib/asyncio/base_events.py  (BaseEventLoop.__init__, abridged)
self._ready = collections.deque()   # callbacks ready to run *now*
self._scheduled = []                # min-heap of TimerHandle (call_later/call_at)
```

`call_soon(cb, *args)` appends an `events.Handle` to `_ready`; `call_later`/`call_at` push a `TimerHandle` onto the `_scheduled` heap via `heapq.heappush`. Everything else — coroutines, transports, futures — is built on top of these two primitives.

### The Trio runtime object

Trio's loop is a _generator_ (`unrolled_run`) driven by a thin `run()`/`GuestState` shell, with all mutable state on a `Runner` ([`src/trio/_core/_run.py`]). The famous self-documenting comment marks the loop body:

```python
# src/trio/_core/_run.py  (unrolled_run, abridged)
# You know how people talk about "event loops"? This 'while' loop right
# here is our event loop:
while runner.tasks:
    if runner.runq:
        timeout = 0
    else:
        deadline = runner.deadlines.next_deadline()
        timeout = runner.clock.deadline_to_sleep_time(deadline)
    ...
    events = yield timeout                     # driver calls io_manager.get_events(timeout)
    runner.io_manager.process_events(events)
    ...
    batch = list(runner.runq); runner.runq.clear()
    while batch:
        task = batch.pop()
        ... task.coro.send(next_send) ...      # resume the coroutine
```

Yielding `timeout` out of the generator is how Trio supports _guest mode_ (running the Trio loop on top of another loop's clock): the host decides how to actually sleep for `timeout` and feeds the I/O events back in.

---

## How it works

### asyncio: one turn of the loop

The heart of asyncio is `BaseEventLoop._run_once()` ([`Lib/asyncio/base_events.py`]), called repeatedly by `run_forever`. Each turn does exactly four things, in order:

```python
# Lib/asyncio/base_events.py  (_run_once, abridged)
def _run_once(self):
    ...
    timeout = None
    if self._ready or self._stopping:
        timeout = 0                                   # work pending -> don't block
    elif self._scheduled:
        timeout = self._scheduled[0]._when - self.time()   # sleep until next timer
        if timeout > MAXIMUM_SELECT_TIMEOUT:
            timeout = MAXIMUM_SELECT_TIMEOUT          # 24h cap
        elif timeout < 0:
            timeout = 0

    event_list = self._selector.select(timeout)       # THE blocking syscall
    self._process_events(event_list)                  # turn I/O into ready callbacks

    end_time = self.time() + self._clock_resolution
    while self._scheduled:                             # move due timers -> _ready
        handle = self._scheduled[0]
        if handle._when >= end_time:
            break
        handle = heapq.heappop(self._scheduled)
        self._ready.append(handle)

    ntodo = len(self._ready)                           # snapshot length
    for i in range(ntodo):                             # run THIS turn's callbacks only
        handle = self._ready.popleft()
        if handle._cancelled:
            continue
        handle._run()
```

Two subtleties worth noting. First, the loop computes its `select()` timeout from the soonest scheduled timer (capped at `MAXIMUM_SELECT_TIMEOUT = 24 * 3600` to dodge OS limits) — there is no timing wheel, just a `heapq`. Cancelled timers are garbage-collected lazily (when `>50%` of `>=100` scheduled handles are cancelled, the heap is rebuilt). Second, `_run_once` snapshots `len(self._ready)` _before_ running callbacks: callbacks scheduled _during_ this turn run on the _next_ turn, "after another I/O poll," which guarantees fairness between I/O and CPU-bound callback chains.

### asyncio: the selector multiplexer (Unix)

`BaseSelectorEventLoop` ([`selector_events.py`]) builds its multiplexer from the stdlib `selectors` module:

```python
# Lib/asyncio/selector_events.py
if selector is None:
    selector = selectors.DefaultSelector()
self._selector = selector
```

`selectors.DefaultSelector` ([`Lib/selectors.py`]) picks the best available backend at import time:

```python
# Lib/selectors.py  (best implementation: epoll|kqueue|devpoll > poll > select)
if _can_use('kqueue'):     DefaultSelector = KqueueSelector     # macOS/BSD
elif _can_use('epoll'):    DefaultSelector = EpollSelector      # Linux
elif _can_use('devpoll'):  DefaultSelector = DevpollSelector    # Solaris
elif _can_use('poll'):     DefaultSelector = PollSelector
else:                       DefaultSelector = SelectSelector    # last resort, FD_SETSIZE cap
```

Registration is **readiness-based** and _callback-based_ — there is no coroutine at this layer. `_add_reader(fd, callback, *args)` wraps the callback in an `events.Handle` and registers `EVENT_READ` interest, storing a `(reader, writer)` tuple as the selector key's data:

```python
# Lib/asyncio/selector_events.py
def _add_reader(self, fd, callback, *args, context=None):
    handle = events.Handle(callback, args, self, context=context)
    key = self._selector.get_map().get(fd)
    if key is None:
        self._selector.register(fd, selectors.EVENT_READ, (handle, None))
    else:
        mask, (reader, writer) = key.events, key.data
        self._selector.modify(fd, mask | selectors.EVENT_READ, (handle, writer))
        if reader is not None:
            reader.cancel()
    return handle
```

When `_run_once` calls `_process_events`, each ready fd's stored handle is moved to `_ready`:

```python
# Lib/asyncio/selector_events.py
def _process_events(self, event_list):
    for key, mask in event_list:
        fileobj, (reader, writer) = key.fileobj, key.data
        if mask & selectors.EVENT_READ and reader is not None:
            if reader._cancelled:  self._remove_reader(fileobj)
            else:                  self._add_callback(reader)   # -> self._ready.append
        if mask & selectors.EVENT_WRITE and writer is not None:
            ...
```

The reader callback (set up by a transport, e.g. `_SelectorSocketTransport._read_ready`) then performs the actual `sock.recv()` and feeds the bytes to a protocol — _the loop never reads the bytes itself_, mirroring [Tokio]'s `ScheduledIo`/`AsyncFd` readiness contract.

### asyncio: the proactor multiplexer (Windows, IOCP)

Windows has no usable readiness API for sockets, so `ProactorEventLoop` ([`proactor_events.py`] + [`windows_events.py`]) is genuinely **completion-based** — the only place asyncio behaves like a Proactor. The `IocpProactor` owns an I/O completion port:

```python
# Lib/asyncio/windows_events.py  (IocpProactor.__init__)
self._iocp = _overlapped.CreateIoCompletionPort(
    _overlapped.INVALID_HANDLE_VALUE, NULL, 0, concurrency)
self._cache = {}                       # overlapped address -> (Future, ov, obj, callback)
```

`recv`/`send`/`accept`/`connect` _submit_ an `OVERLAPPED` operation (`ov.WSARecv(...)`, `ov.WSASend(...)`) and return a `Future`. The loop's `select(timeout)` drains completions from the port:

```python
# Lib/asyncio/windows_events.py  (IocpProactor._poll, abridged)
status = _overlapped.GetQueuedCompletionStatus(self._iocp, ms)   # THE blocking call
err, transferred, key, address = status
f, ov, obj, callback = self._cache.pop(address)
value = callback(transferred, key, ov)                            # ov.getresult()
f.set_result(value)
self._results.append(f)
```

Because the result already landed, `BaseProactorEventLoop._process_events` is a no-op — completions are turned into resolved Futures inside `_poll` itself. The submission/completion structure here is the closest thing in CPython to `io_uring`'s SQ/CQ rings (see [io-uring/index]), but bounded to Windows.

### asyncio: coroutines, Tasks, and `await`

Coroutines are inert until wrapped in a `Task`. A `Task` ([`tasks.py`]) is a `Future` subclass that _drives_ a coroutine one `send` at a time. Its private `__step` is scheduled with `loop.call_soon(self.__step, ...)`:

```python
# Lib/asyncio/tasks.py  (Task.__step_run_and_handle_result, abridged)
result = coro.send(None)                      # resume coroutine until next await
...
blocking = getattr(result, '_asyncio_future_blocking', None)
if blocking is not None:                      # coroutine yielded a Future
    result._asyncio_future_blocking = False
    result.add_done_callback(self.__wakeup, context=self._context)   # re-arm on completion
    self._fut_waiter = result
elif result is None:
    self._loop.call_soon(self.__step, context=self._context)         # bare yield -> reschedule
```

The protocol: `await fut` ultimately yields the `Future` object out through the coroutine stack (its `__await__` sets `_asyncio_future_blocking = True`). The driving `Task` catches it, registers `__wakeup` as a done-callback, and parks. When the Future resolves (e.g. a transport got data), `__wakeup` calls `__step` again, which `coro.send`s the result back in. This is the bridge from the callback loop to `async`/`await`.

In CPython this hot path is reimplemented in C: `_asynciomodule.c` ([`Modules/_asynciomodule.c`]) exports `_asyncio.Task` and `_asyncio.Future`, swapped in at the bottom of `tasks.py`/`futures.py`:

```python
# Lib/asyncio/tasks.py
try:
    import _asyncio
except ImportError:
    pass
else:
    Task = _CTask = _asyncio.Task          # C-accelerated Task replaces the pure-Python one
```

The C module also maintains the `future_add_to_awaited_by`/`future_discard_from_awaited_by` call-graph used by `asyncio.tools` and `TaskGroup`.

### asyncio: the transports/protocols callback layer

Beneath the coroutine-friendly `streams` API (`open_connection`, `StreamReader`/`StreamWriter`) sits asyncio's older, Twisted-derived **transport/protocol** layer ([`transports.py`], [`protocols.py`]). A _transport_ (`BaseTransport`, `ReadTransport`, `WriteTransport`, `Transport`, `DatagramTransport`) abstracts a connection and owns the buffering and the `add_reader`/`add_writer` registrations; a _protocol_ (`BaseProtocol`, `Protocol`, `BufferedProtocol`, `DatagramProtocol`, `SubprocessProtocol`) is _user code_ the transport calls back into. The `Protocol` docstring spells out the callback state machine explicitly:

```python
# Lib/asyncio/protocols.py  (Protocol)
# State machine of calls:
#   start -> CM [-> DR*] [-> ER?] -> CL -> end
#   CM: connection_made()   DR: data_received()
#   ER: eof_received()      CL: connection_lost()
```

So a `_SelectorSocketTransport`'s `_read_ready` callback (scheduled by `_process_events`) does the `sock.recv()` and pushes the bytes into `protocol.data_received(data)`; flow control (`pause_writing`/`resume_writing`, `_FlowControlMixin`) backpressures the writer when the send buffer fills. This is the _pure-callback_ substrate; `streams` and every higher framework (aiohttp, the gRPC bindings) ultimately drive it. Trio deliberately has **no** equivalent callback layer — its `SocketStream`/`Channel` are awaited directly, since a coroutine _is_ the continuation a protocol callback would otherwise encode.

### asyncio: file I/O and DNS — the thread pool

asyncio has _no_ asynchronous file I/O and _no_ async `getaddrinfo`. Blocking calls are shipped to a `concurrent.futures.ThreadPoolExecutor` via `run_in_executor`:

```python
# Lib/asyncio/base_events.py  (run_in_executor, abridged)
if executor is None:
    executor = self._default_executor
    if executor is None:
        executor = concurrent.futures.ThreadPoolExecutor(...)
        self._default_executor = executor
return futures.wrap_future(executor.submit(func, *args), loop=self)
```

`getaddrinfo` and `loop.run_in_executor`-based file helpers all hop to this pool — the same "no portable non-blocking file syscall" workaround [Tokio]'s blocking pool uses, except here it is also where DNS lives.

### asyncio: structured concurrency (3.11+) — TaskGroup and timeout

For a decade asyncio's concurrency was _unstructured_: `asyncio.create_task` spawns a detached task that outlives its creator, and `asyncio.gather` neither cancels siblings on first error (without `return_exceptions`) nor guarantees cleanup. Python 3.11 added **`asyncio.TaskGroup`** ([`taskgroups.py`]) — a direct port of Trio's nursery, "Adapted with permission from the EdgeDB project" — as an async context manager:

```python
async with asyncio.TaskGroup() as group:
    group.create_task(coro1())
    group.create_task(coro2())
# both tasks have completed (or all cancelled) here
```

The mechanics mirror Trio precisely. On `__aexit__`, the group `await`s an internal Future until `self._tasks` is empty; if any child raises a non-`CancelledError`, `_on_task_done` calls `self._abort()` (cancelling all siblings) and _cancels the parent task_ so the `async with` body unwinds:

```python
# Lib/asyncio/taskgroups.py  (_on_task_done, abridged)
if not self._aborting and not self._parent_cancel_requested:
    self._abort()                              # cancel all sibling tasks
    self._parent_cancel_requested = True
    self._parent_task.cancel()
...
# in _aexit: collected child errors become an ExceptionGroup
raise BaseExceptionGroup('unhandled errors in a TaskGroup', self._errors)
```

Crucially, errors are aggregated into a `BaseExceptionGroup` (the `except*` machinery of [PEP 654]) rather than the first-error-wins behaviour of `gather`. The companion **`asyncio.timeout()`** ([`timeouts.py`], also 3.11) is an async context manager that schedules a `loop.call_at` to `task.cancel()` the body, then converts the resulting `CancelledError` into `TimeoutError` on exit — leaning on the new `Task.uncancel()`/`cancelling()` cancel-count APIs (also 3.11) to compose correctly when nested:

```python
# Lib/asyncio/timeouts.py  (abridged)
def _on_timeout(self):
    self._task.cancel()
    self._state = _State.EXPIRING
...
# __aexit__:
if self._task.uncancel() <= self._cancelling and exc_type is not None:
    if issubclass(exc_type, exceptions.CancelledError):
        raise TimeoutError from exc_val
```

### asyncio: the entry point

`asyncio.run(main())` is sugar over `runners.Runner` ([`runners.py`]), which creates a fresh loop with `events.new_event_loop()`, runs the coroutine to completion, then shuts down async generators and the default executor:

```python
# Lib/asyncio/runners.py
if self._loop_factory is None:
    self._loop = events.new_event_loop()
    ...
else:
    self._loop = self._loop_factory()        # <- the uvloop hook
```

The `loop_factory` parameter is the supported drop-in seam (see uvloop below).

### Trio: the run loop, tasks, and traps

Trio runs the `unrolled_run` generator shown above. A `Task` ([`src/trio/_core/_run.py`]) wraps a coroutine; the runner resumes it with `coro.send(...)`. A task blocks by _awaiting a trap_ — Trio's equivalent of asyncio's "yield a Future." The fundamental trap is `wait_task_rescheduled(abort_fn)` ([`_core/_traps.py`]), which removes the task from the run queue until someone calls `reschedule(task, value)`:

```python
# how a blocking primitive is built (pattern from _io_epoll.py)
def abort(_):
    setattr(waiters, attr_name, None)
    self._update_registrations(fd)
    return _core.Abort.SUCCEEDED        # tell Trio the cancellation can take effect
await _core.wait_task_rescheduled(abort)
```

The `abort` callback is the cancellation contract: when the task is cancelled while parked, Trio calls `abort`; returning `Abort.SUCCEEDED` lets the `Cancelled` exception be raised, while `Abort.FAILED` means "I can't unwind right now, reschedule me normally." Every blocking call in Trio is therefore a **checkpoint** — a point where `Cancelled` may be injected and where the scheduler may switch tasks. This is enforced as a design invariant ("checkpoints"), unlike asyncio where only `await` on something that actually suspends is a cancellation point.

### Trio: the epoll I/O manager

`EpollIOManager` ([`_core/_io_epoll.py`]) is Trio's Linux multiplexer. Like asyncio it is readiness-based, but it makes one striking choice: **everything uses `EPOLLONESHOT`**. The code's own long commentary explains why — because user code may `close()` a fd Trio is waiting on (or `dup()` it) without telling Trio, a level-triggered registration could get stuck returning a stale fd forever and "burn 100% of the CPU doing nothing." One-shot registration self-disarms after each event, so a stale fd can fire at most once:

```python
# src/trio/_core/_io_epoll.py  (_update_registrations, abridged)
try:
    self._epoll.modify(fd, wanted_flags | select.EPOLLONESHOT)   # try MOD first
except OSError:
    self._epoll.register(fd, wanted_flags | select.EPOLLONESHOT) # new fd -> ADD
```

`get_events(timeout)` is the single `epoll_wait`; `process_events` reschedules the parked read/write task and re-arms only what is still wanted:

```python
# src/trio/_core/_io_epoll.py
def process_events(self, events):
    for fd, flags in events:
        waiters = self._registered[fd]
        waiters.current_flags = 0                       # EPOLLONESHOT cleared it
        if flags & ~select.EPOLLIN and waiters.write_task is not None:
            _core.reschedule(waiters.write_task); waiters.write_task = None
        if flags & ~select.EPOLLOUT and waiters.read_task is not None:
            _core.reschedule(waiters.read_task); waiters.read_task = None
        self._update_registrations(fd)
```

A `WakeupSocketpair` fd is also registered so signals / cross-thread `force_wakeup()` can break a blocked `epoll_wait`. Trio selects the backend at import (`_core/_run.py`): `WindowsIOManager` (IOCP) on `win32`, `EpollIOManager` on Linux/Android, else `KqueueIOManager` ([`_core/_io_kqueue.py`], which stores `select.kevent`s) on BSD/macOS.

### Trio: nurseries (structured concurrency)

A **nursery** is the only way to spawn concurrent tasks in Trio. `open_nursery()` returns a `NurseryManager` async context manager ([`src/trio/_core/_run.py`]); on entry it creates a `CancelScope`, on exit it blocks until every child has finished:

```python
async with trio.open_nursery() as nursery:
    nursery.start_soon(worker, 1)
    nursery.start_soon(worker, 2)
# control does not pass this line until BOTH workers have exited
```

`start_soon` is synchronous — it spawns and returns immediately:

```python
# src/trio/_core/_run.py  (Nursery.start_soon, abridged)
def start_soon(self, async_fn, *args, name=None):
    GLOBAL_RUN_CONTEXT.runner.spawn_impl(async_fn, args, self, name)
```

The invariant (quoting the docstring): "Nurseries ensure the absence of orphaned Tasks, since all running tasks will belong to an open Nursery." If a child raises, the nursery cancels all siblings and re-raises — wrapped in an `ExceptionGroup` under `strict_exception_groups=True` (the default since 0.25). This is the model Nathaniel Smith laid out in _["Notes on structured concurrency, or: Go statement considered harmful"][njs-go]_ (2018), and it is the direct ancestor of asyncio's `TaskGroup`, [Java's `StructuredTaskScope`][java], and Kotlin's `coroutineScope`.

### Trio: cancel scopes

Cancellation in Trio is _scoped_, not per-task. A `CancelScope` ([`src/trio/_core/_run.py`]) is a `with`-block that can be cancelled by `.cancel()` or by an expiring `.deadline`; the `Cancelled` exception is raised at the next checkpoint inside the block:

```python
with trio.move_on_after(5):          # a CancelScope with deadline = now + 5s
    await some_long_operation()       # Cancelled raised here if it overruns
```

The timeout helpers ([`_timeouts.py`]) are thin wrappers over `CancelScope`: `move_on_after(s)` → `CancelScope(relative_deadline=s)` (catches and swallows `Cancelled`), while `fail_after(s)` additionally raises `TooSlowError` if the scope fired:

```python
# src/trio/_timeouts.py
@contextmanager
def fail_after(seconds, *, shield=False):
    with move_on_after(seconds, shield=shield) as scope:
        yield scope
    if scope.cancelled_caught:
        raise TooSlowError
```

Scopes nest and form a tree (`CancelStatus` parent links); a `shield=True` scope protects its body from _outer_ cancellation. Deadlines live in a `Deadlines` min-heap on the `Runner`, and `unrolled_run` calls `runner.deadlines.expire(now)` each turn to cancel any scope whose deadline passed. This is structurally identical to [Eio][eio]'s `Switch`-based cancellation and far more robust than asyncio's per-task `cancel()`, which 3.11's `timeout()` had to paper over with the `uncancel`/`cancelling` count.

### uvloop: the libuv drop-in

`uvloop` is "a fast, drop-in replacement of the built-in asyncio event loop ... implemented in Cython and uses libuv under the hood," making "asyncio 2-4x faster" (per the [MagicStack/uvloop] README, verified). It reimplements the _entire_ `asyncio.AbstractEventLoop` protocol — including `add_reader`, transports, and protocols — as thin Cython objects wrapping [libuv]'s C structs (`uv_loop_t`, `uv_tcp_t`, `uv_poll_t`, etc.), so existing asyncio code runs unchanged. (CPython even vendored uvloop's `events.py` policy code, per the SPDX header in `Lib/asyncio/events.py`.) Installation hooks the `loop_factory` seam:

```python
# modern (Python 3.11+): no global policy mutation
import asyncio, uvloop
with asyncio.Runner(loop_factory=uvloop.new_event_loop) as runner:
    runner.run(main())

# or simply
uvloop.run(main())

# legacy
uvloop.install(); asyncio.run(main())
```

The speedup comes from doing the loop in compiled C — libuv's batched event handling, buffer management, and avoidance of the per-callback Python-object churn that `_run_once` incurs — while preserving asyncio semantics ("any deviation from the behavior of the reference asyncio event loop is considered a bug"). It is the analogue of using [libuv] directly (as Node.js does) but behind the Python asyncio API. uvloop requires Python 3.8+ and is Unix-only (no Windows IOCP backend).

### Why there is no stdlib io_uring

No CPython event loop targets `io_uring` (see [io-uring/index] for the interface). The reasons compound:

- **Readiness vs. completion mismatch.** asyncio and Trio are built on the readiness model (`add_reader`/`wait_readable`); `io_uring` is completion-based with owned buffers, which would require a parallel transport stack rather than a backend swap.
- **The GIL caps the upside.** `io_uring`'s headline win — batching many syscalls per `io_uring_enter` and avoiding per-op syscall overhead — matters most for thread-per-core, syscall-bound runtimes ([Glommio], [Monoio]). A single GIL-bound Python thread cannot saturate a ring the way those can.
- **File I/O already uses threads.** asyncio's blocking-pool answer to file I/O removes the main motivation (async files) that drives `io_uring` adoption in [Tokio].

The space is left to third-party projects; none has reached the stdlib. Contrast [Eio][eio] (OCaml) and [Tokio]'s experimental backend, which _do_ expose `io_uring`.

---

## Performance approach

- **One syscall per turn.** Both loops block in exactly one `select()`/`epoll_wait`/`GetQueuedCompletionStatus` per iteration, draining a batch of events; the timeout is computed from the next due timer (asyncio `heapq`, Trio `Deadlines` heap).
- **Lazy timer cleanup.** asyncio does _not_ remove cancelled `TimerHandle`s eagerly; it rebuilds the `_scheduled` heap only when cancellation density crosses a threshold (`_MIN_SCHEDULED_TIMER_HANDLES = 100`, `>50%` cancelled), amortizing churn.
- **C acceleration.** CPython's `_asynciomodule.c` reimplements `Future`/`Task` (the per-`await` hot path) in C; uvloop pushes the entire loop + transports into compiled Cython over libuv for the 2–4× win.
- **`EPOLLONESHOT` everywhere (Trio).** Self-disarming registrations avoid busy-loops on stale fds _and_ save an explicit deregister on the wakeup path ("a bit more efficient in general," per the source).
- **No green-thread stacks.** Suspended coroutines are just coroutine objects with a saved frame; there is no stack to copy (unlike [Eio][eio]/Loom green threads).
- **Single-threaded by design.** The GIL means one loop = one core for Python bytecode; scaling out means multiple processes (each with its own loop) or offloading CPU work to a `ProcessPoolExecutor`.

---

## Strengths

- **Coroutines + `await` read sequentially.** Direct-style control flow, far more legible than callback chains or [Tokio]'s manual `poll`.
- **Portable.** asyncio covers Linux/macOS/BSD (readiness) _and_ Windows (IOCP completion) from one API; uvloop accelerates the Unix path transparently.
- **Drop-in acceleration.** uvloop gives 2–4× with a one-line change and no API churn.
- **Mature, batteries-included (asyncio).** Transports/protocols, streams, subprocess, SSL, DNS, timers, and now structured concurrency in the stdlib.
- **Best-in-class structured concurrency (Trio).** Nurseries + cancel scopes make orphaned tasks and leaked cancellations _structurally impossible_; this model is now the industry reference.
- **Cancellation correctness (Trio).** Every checkpoint is a cancellation point with an explicit abort contract; `shield` and deadline scopes compose cleanly.
- **Interoperability (Trio).** `anyio`/`trio-asyncio` let Trio-style code run on the asyncio loop and vice versa.

## Weaknesses

- **No stdlib `io_uring`; no async files.** File I/O and DNS hop to a thread pool, paying a context-switch per call; no zero-syscall batching path exists.
- **GIL ceiling.** One loop saturates one core for Python work; CPU-bound concurrency needs processes.
- **asyncio's unstructured legacy.** `create_task`/`gather`/bare `Task.cancel()` predate `TaskGroup`; cancellation is famously subtle (a `CancelledError` can be swallowed; `gather` doesn't cancel on error by default), and the event-loop-policy API churned for years.
- **Two incompatible worlds.** asyncio and Trio do not share a loop natively; libraries must pick one or target `anyio`.
- **uvloop is Unix-only** and a separate C-extension dependency (no Windows, no pure-Python fallback for the loop itself).
- **Readiness double-handling.** On Unix, the loop learns "fd readable" then a transport issues the `recv` — an extra dispatch hop versus a true completion API.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                          | Trade-off                                                                                |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Callback loop + coroutine layer (asyncio)               | Reuse Twisted-style transports; add `await` on top without rewriting the core      | Two mental models; coroutines must "yield a Future" through `Task.__step` to suspend     |
| Readiness on Unix, completion only on Windows (asyncio) | Match each OS's best native API (epoll/kqueue vs IOCP) behind one loop interface   | Behaviour differs subtly across platforms; no unified completion path                    |
| `selectors.DefaultSelector` auto-pick                   | Portable "best available" multiplexer with no user config                          | `select()` fallback caps fds at `FD_SETSIZE` (~1024)                                     |
| Thread pool for files & DNS (asyncio)                   | Portable async API with no non-blocking file/`getaddrinfo` syscall                 | Per-call thread handoff; no batching; the GIL still serializes the Python side           |
| C-accelerated `Future`/`Task` (`_asynciomodule.c`)      | Remove interpreter overhead from the per-`await` hot path                          | Two implementations to keep in sync; pure-Python fallback only for non-CPython           |
| `TaskGroup`/`timeout` retrofitted in 3.11               | Bring Trio's proven structured concurrency to the stdlib without breaking old code | Bolted onto an unstructured core; required `ExceptionGroup` + `uncancel`/`cancelling`    |
| uvloop = Cython-over-libuv drop-in                      | 2–4× speedup with zero API change via `loop_factory`/`install`                     | Extra C dependency; Unix-only; tracks asyncio semantics as a hard constraint             |
| No `io_uring` backend (asyncio & Trio)                  | GIL caps batching upside; readiness model + thread-pool files remove the motive    | Forgoes `io_uring`'s syscall batching available to [Tokio]/[Glommio]/[Eio][eio]          |
| Nurseries: every task in a scope (Trio)                 | No orphans; errors and cancellation propagate structurally                         | Cannot "fire and forget"; spawning requires an open nursery in scope                     |
| Cancel scopes + mandatory checkpoints (Trio)            | Deterministic, composable cancellation with `shield` and deadlines                 | Every blocking call is a potential `Cancelled`; library authors must place checkpoints   |
| `EPOLLONESHOT` for all fds (Trio)                       | Survive user-closed/stale fds without CPU-spinning busy-loops                      | A `MOD`-then-`ADD` re-arm per wait; rules out `EPOLLEXCLUSIVE` thundering-herd avoidance |

---

## Sources

- [python/cpython] — CPython source (all `Lib/asyncio/*.py`, `Lib/selectors.py`, `Modules/_asynciomodule.c` quoted above)
- [python-trio/trio] — Trio source (`src/trio/_core/_run.py`, `_io_epoll.py`, `_io_kqueue.py`, `_timeouts.py`)
- [MagicStack/uvloop] — uvloop repository (libuv-backed, Cython, "2-4x faster", `loop_factory`/`install` usage — verified)
- [asyncio docs] — asyncio API reference; `TaskGroup` and `timeout()` "Added in version 3.11" (verified)
- [PEP 3156] — _Asynchronous IO Support Rebooted: the "asyncio" Module_ (Guido van Rossum) — the reference design ("Tulip")
- [PEP 654] — _Exception Groups and except\*_ — foundation for `TaskGroup` error aggregation
- [njs-go] — _Notes on structured concurrency, or: Go statement considered harmful_ (Nathaniel J. Smith, 2018) — the nursery/structured-concurrency manifesto
- [Trio docs] — Trio nurseries, cancel scopes, checkpoints reference
- [uvloop docs] — uvloop usage and design
- [epoll(7) man page][epoll-man] — `EPOLLONESHOT`, `EPOLLEXCLUSIVE` semantics
- Sibling docs: [primitives], [techniques], [comparison], [effects-and-event-loops], [d-landscape], [io-uring/index], [Tokio], [Glommio], [Monoio], [libuv], [Go netpoller][go-netpoller], [dotnet], [java], [Eio][eio]

<!-- References -->

[python/cpython]: https://github.com/python/cpython
[python-trio/trio]: https://github.com/python-trio/trio
[MagicStack/uvloop]: https://github.com/MagicStack/uvloop
[asyncio docs]: https://docs.python.org/3/library/asyncio.html
[Trio docs]: https://trio.readthedocs.io/en/stable/
[uvloop docs]: https://uvloop.readthedocs.io/
[PEP 3156]: https://peps.python.org/pep-3156/
[PEP 654]: https://peps.python.org/pep-0654/
[njs-go]: https://vorpus.org/blog/notes-on-structured-concurrency-or-go-statement-considered-harmful/
[epoll-man]: https://man7.org/linux/man-pages/man7/epoll.7.html
[`Lib/asyncio/base_events.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/base_events.py
[`selector_events.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/selector_events.py
[`Lib/selectors.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/selectors.py
[`proactor_events.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/proactor_events.py
[`windows_events.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/windows_events.py
[`tasks.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/tasks.py
[`taskgroups.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/taskgroups.py
[`timeouts.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/timeouts.py
[`runners.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/runners.py
[`transports.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/transports.py
[`protocols.py`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Lib/asyncio/protocols.py
[`Modules/_asynciomodule.c`]: https://github.com/python/cpython/blob/357c6500589ca7e065a6c263accfa1307d93c990/Modules/_asynciomodule.c
[`src/trio/_core/_run.py`]: https://github.com/python-trio/trio/blob/976c11b5749db70559ffd81bfeddeed51b250dd0/src/trio/_core/_run.py
[`_core/_io_epoll.py`]: https://github.com/python-trio/trio/blob/976c11b5749db70559ffd81bfeddeed51b250dd0/src/trio/_core/_io_epoll.py
[`_core/_io_kqueue.py`]: https://github.com/python-trio/trio/blob/976c11b5749db70559ffd81bfeddeed51b250dd0/src/trio/_core/_io_kqueue.py
[`_core/_traps.py`]: https://github.com/python-trio/trio/blob/976c11b5749db70559ffd81bfeddeed51b250dd0/src/trio/_core/_traps.py
[`_timeouts.py`]: https://github.com/python-trio/trio/blob/976c11b5749db70559ffd81bfeddeed51b250dd0/src/trio/_timeouts.py
[primitives]: ./primitives.md
[techniques]: ./techniques.md
[comparison]: ./comparison.md
[effects-and-event-loops]: ./effects-and-event-loops.md
[d-landscape]: ./d-landscape.md
[io-uring/index]: ./io-uring/index.md
[Tokio]: ./tokio.md
[mio]: ./tokio.md
[Glommio]: ./glommio.md
[Monoio]: ./monoio.md
[libuv]: ./libuv.md
[go-netpoller]: ./go-netpoller.md
[Go netpoller]: ./go-netpoller.md
[dotnet]: ./dotnet.md
[java]: ./java.md
[eio]: ../algebraic-effects/ocaml-eio.md
