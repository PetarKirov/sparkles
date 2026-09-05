# Coming from libasync

Libasync attaches asynchronous objects to an `EventLoop` and reports results
through callbacks. Event Horizon's fiber layer keeps the continuation in the
calling function: an I/O verb parks, then returns a result and its buffer.

The [libasync baseline][libasync] is
`20c29c20cecd367ff38bf4cf9d7f210cd97c04ac`. Its README explicitly describes
thread-pool file and DNS operations, one event loop per thread, and manual error
management. Those are useful migration boundaries, not reasons to assume every
backend or workload behaves identically.

## Translate notification semantics carefully

| libasync concept             | Event Horizon counterpart           | Caveat                                                                   |
| ---------------------------- | ----------------------------------- | ------------------------------------------------------------------------ |
| `EventLoop` and its dispatch | `LoopGroup.run`                     | The default group owns one calling-thread scheduler.                     |
| Socket callback              | `accept`, `recv`, `send` in a fiber | Partial transfers still need loops.                                      |
| `AsyncTimer`                 | `env.clock.sleep`, `Ticker`         | Choose a delay or absolute cadence.                                      |
| Thread-pool file callback    | `openFile`, `read`, `closeFile`     | Linux io_uring performs file operations; other backends may use workers. |
| `AsyncSignal`                | A cross-thread notification design  | It is **not** equivalent to `SignalFd`.                                  |
| Callback status              | `IoResult!T`                        | Check errors explicitly instead of treating all failures as EOF.         |

The distinction in the signal row matters: [libasync's `AsyncSignal`][signal]
enqueues a callback on its owner's loop when triggered from another thread.
Event Horizon's Linux `SignalFd` receives POSIX signals such as `SIGUSR1`.
Likewise, a scheduler-local `Channel` must not be presented as a drop-in
cross-thread notification mechanism.

## Read a file with explicit ownership

The example opens an isolated fixture and reads to EOF. The file and buffer
remain owned until their operations finish; cleanup runs before deleting the file.

<<< @/libs/event-horizon/tutorial/snippets/eh_file_read.d [event-horizon]

```ansi
read 18 bytes: hello from a file

```

## Capture a subprocess

If an application also shells out, use a process primitive rather than treating
child pipes as unrelated callbacks. `capture` drains stdout and stderr and reaps
the root. A nonzero exit status is data, not necessarily an I/O error.

<<< @/libs/event-horizon/tutorial/snippets/eh_exec.d [event-horizon]

```ansi
stdout: out

stderr: err

exit code: 3
```

See [Running the examples](./running-examples.md) for Linux support boundaries,
streaming supervision, and the test commands. The programs run Event Horizon;
they do not require an old libasync release to compile on a current compiler.

<!-- References -->

[libasync]: https://github.com/etcimon/libasync/blob/20c29c20cecd367ff38bf4cf9d7f210cd97c04ac/README.md
[signal]: https://github.com/etcimon/libasync/blob/20c29c20cecd367ff38bf4cf9d7f210cd97c04ac/source/libasync/signal.d
