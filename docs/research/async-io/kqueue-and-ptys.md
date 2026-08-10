# kqueue, PTYs and signals on macOS

What a kqueue-based event loop can and cannot watch on macOS, how ten production
systems answer the same three questions — _can I poll this fd, how do I hear about a
signal, how do I hear about a child exiting_ — and which of their answers
`sparkles:event-horizon` should adopt.

| Field        | Value                                                                                                              |
| ------------ | ------------------------------------------------------------------------------------------------------------------ |
| Scope        | kqueue on macOS (and, where they differ, the BSDs); PTY/TTY descriptors; signal delivery; child-process reaping    |
| Motivated by | Porting `apps/terminal`, `apps/hue` and `apps/ui-gallery` to macOS ([terminal-view spec][tvw], `TVW8`)             |
| Systems read | libuv, libxev, libevent, libtorque, mio · ghostty, alacritty, kitty, wezterm, tmux                                 |
| Complements  | [primitives][primitives] (the signal/subprocess tiers), [techniques][techniques] (feature probing), [libuv][libuv] |
| Not covered  | `io_uring` (see the [io_uring reference][uring-index]), IOCP, Windows PTYs (ConPTY)                                |

> **Source anchors.** Every repository below was cloned and read at the commit named
> in [Sources](#sources); file paths are repo-relative and every citation links to the
> pinned tree. Quotes are verbatim.

> [!IMPORTANT]
> Two claims on this page are backed by **measurement on an M4 Max (macOS 25.6)**
> rather than by reading alone, and are marked _(probed)_. They are not currently
> CI-verified: the programs need a live kqueue and a PTY, so they cannot run on the
> Linux CI leg. See [Reproducing the probes](#reproducing-the-probes) for the code.

**Last reviewed:** August 10, 2026

---

## Why this page exists

Porting the Sparkles terminal stack to macOS turned up a class of bug that reading the
kqueue man page does not prevent: **the op you can submit and the fd you can submit it
against are different questions.** `sparkles:event-horizon` answers the first at
compile time (`canSubmitOp!(DefaultBackend, OpRead)`) and, until this survey, did not
ask the second at all.

The survey also exists as a correction. Early in the port a probe appeared to show that
kqueue never reports readability on a PTY master, and a capability was gated off on that
basis. The conclusion was wrong — the probe was watching a master whose child had been
spawned suspended and so had never written anything (see
[the spawn-flag trap](#the-spawn-flag-trap)). Apple's own regression test asserts the
opposite behaviour, and a corrected probe agrees with it. The lesson is recorded here
because the failure mode is general: **a negative result about an event loop is usually
a result about the fd you handed it.**

---

## What kqueue will not watch

kqueue is not uniform across descriptor types, and the exclusions are platform-specific.
libuv concentrates the whole question into one function, `uv__io_check_fd`
([`src/unix/kqueue.c`][uv-kqueue]):

```c
/* On FreeBSD, kqueue only supports EVFILT_READ notification for regular files
 * and always reports ready events for writing, resulting in busy-looping.
 *
 * On Darwin, DragonFlyBSD, NetBSD and OpenBSD, kqueue reports ready events for
 * regular files as readable and writable only once, acting like an EV_ONESHOT.
 *
 * Neither of the above cases should be added to the kqueue.
 */
if (S_ISREG(sb.st_mode) || S_ISDIR(sb.st_mode))
  return UV_EINVAL;
```

and then, for Darwin specifically:

```c
/* On Darwin (both macOS and iOS), in addition to regular files, FIFOs also don't
 * work properly with kqueue: the disconnection from the last writer won't trigger
 * an event for kqueue in spite of what the man pages say. Thus, we also disallow
 * the case of S_IFIFO. */
```

Two details are worth stealing outright:

1. **`stat` cannot distinguish a FIFO from a pipe or a kqueue fd** — they share
   `S_IFIFO`. libuv separates them with `fcntl(fd, F_GETPATH, path)`, exploiting the
   fact that only a real FIFO has a filesystem path.
2. **The final check is a trial registration**, not a table lookup:

   ```c
   EV_SET(ev, fd, EVFILT_READ, EV_ADD, 0, 0, 0);
   EV_SET(ev + 1, fd, EVFILT_READ, EV_DELETE, 0, 0, 0);
   if (kevent(loop->backend_fd, ev, 2, NULL, 0, NULL))
     return UV__ERR(errno);
   ```

   Add, delete, report the errno. Nothing else is trustworthy across BSD variants.

libuv goes further for descriptors that pass the static checks but still misbehave.
`uv__stream_try_select` ([`src/unix/stream.c`][uv-stream]) opens a scratch kqueue,
registers the fd with a tiny timeout **"because we only want to capture EINVALs"**, and
on failure moves that fd to a dedicated `select()` thread, bridged back to the loop by
an async handle and a semaphore. Its rationale is one sentence:

```c
/*
 * kqueue doesn't work with some files from /dev mount on osx.
 * select(2) in separate thread for those fds
 */
```

### How the other loops handle the same gap

| System        | Detection                                            | Fallback                                                  |
| ------------- | ---------------------------------------------------- | --------------------------------------------------------- |
| [libuv][uv]   | Automatic: static `stat` rules + trial registration  | `select()` thread per bad fd, bridged by `uv_async_t`     |
| [libxev][xev] | **Caller declares** (`threadpool: bool` on a stream) | Shared thread pool; regular files always take it          |
| [mio][mio]    | None — registers whatever `SourceFd` it is given     | None; pushed to the caller (Tokio uses its blocking pool) |

libxev's file watcher hardcodes the decision (`src/watcher/file.zig`,
`.threadpool = true`), while its stream watcher exposes it as an option
(`src/watcher/stream.zig`: `/// True to schedule the read/write on the threadpool.`).
mio declines the problem entirely, which is consistent with its position as a thin
selector rather than a runtime.

---

## PTYs specifically

The question that mattered for the terminal port: **does kqueue report readability and
EOF on a PTY master?**

**Yes.** Three independent lines of evidence:

1. **Apple asserts it.** XNU's own regression suite contains `master_read_data_set`
   ([`tests/kevent_pty.c`][xnu-kevent-pty]), which opens a pair with `openpty()`,
   attaches a `DISPATCH_SOURCE_TYPE_READ` (a kqueue `EVFILT_READ` under the hood) to the
   **master**, writes from the slave, and asserts `dispatch_source_get_data()` is
   non-zero.
2. **Alacritty ships it.** It registers the PTY with its poller in level-triggered mode
   and reads it on the loop thread — no helper thread
   ([`alacritty_terminal/src/event_loop.rs`][alacritty-loop]):
   `let poll_opts = PollMode::Level;` … `self.pty.register(&self.poll, interest, poll_opts)`.
3. **Measured _(probed)_.** On a pair this process owned both ends of:

   ```text
   A1 after slave write: n=1 flags=0x11 data=7        <-- readability, 7 bytes
   A3 after slave close: n=1 flags=0x8011 EV_EOF=true <-- EOF via EV_EOF
   ```

Note that libuv's exclusion list never mentions TTYs; its `/dev` caveat is about _some_
device files, and it keeps the runtime probe precisely because the set is not
enumerable.

### But most terminals still use a thread

Reading the PTY on the event loop is _possible_; it is not what most emulators do.

| Emulator            | PTY read path                                                    |
| ------------------- | ---------------------------------------------------------------- |
| [alacritty][alac]   | On the loop, `PollMode::Level`                                   |
| [ghostty][gt]       | Dedicated thread: `poll(2)` over `{pty, quit, idle}` + `read(2)` |
| [wezterm][wez]      | Thread, blocking `read`                                          |
| [kitty][kitty-repo] | Own loop thread                                                  |
| [tmux][tmux-repo]   | libevent on the pty fd                                           |

Ghostty is the interesting case because it is written by libxev's author and uses libxev
for the PTY **write** side (`xev.Stream.initFd(pty_fds.write)`) and the process exit
watch, while reading on a hand-rolled thread
([`src/termio/Exec.zig`][gt-exec]). The comments make clear this is a throughput
decision, not a correctness one — the loop implements a buffer ring with condvar
backpressure, bounded spin-retry across refill gaps, and a latency budget:

> _"For a saturated stream the kernel queue momentarily runs dry while the writer refills
> it in parallel, so we bridge those gaps with spin retries and a short poll instead of
> delivering a tiny batch."_

The takeaway for `TVW8` is that parking a read on the ring is legitimate, and that the
alternative is chosen for batching under saturation rather than to dodge a kqueue defect.

---

## Signals

The three viable mechanisms, and who uses which:

| System              | Mechanism                                                                  |
| ------------------- | -------------------------------------------------------------------------- |
| [libevent][le]      | **`EVFILT_SIGNAL`** (`kq_sig_add`)                                         |
| [libtorque][lt]     | **`EVFILT_SIGNAL`** on FreeBSD; `signalfd` on Linux, behind one API        |
| [tmux][tmux-repo]   | via libevent → `EVFILT_SIGNAL` (`signal_set(&tp->ev_sigwinch, SIGWINCH…)`) |
| [libuv][uv]         | Self-pipe: `sigaction` handler writes `signal_pipefd[1]`                   |
| [kitty][kitty-repo] | Self-pipe (`self_pipe(ld->signal_fds, true)` + `SA_SIGINFO \| SA_RESTART`) |
| [libxev][xev]       | **None** — "Signal handlers" is a README roadmap item                      |
| [mio][mio]          | **None**                                                                   |
| [ghostty][gt]       | None needed — GUI; resize arrives from the window system                   |

### `EVFILT_SIGNAL` and `signalfd` are not the same primitive

libtorque's `signal.c` quotes both man pages side by side, which is the clearest
statement of the difference in any of these trees
([`src/libtorque/events/signal.c`][lt-signal]):

| Property               | `EVFILT_SIGNAL` (BSD/macOS)                                                                            | `signalfd` (Linux)                                 |
| ---------------------- | ------------------------------------------------------------------------------------------------------ | -------------------------------------------------- |
| Must block the signal? | **No** — "coexists with the signal() and sigaction() facilities"                                       | **Yes** — "should be blocked using sigprocmask(2)" |
| `SIG_IGN`'d signals    | **Still reported** — "records all attempts to deliver … even if the signal has been marked as SIG_IGN" | n/a                                                |
| Ordering               | "notification happens **after** normal signal delivery processing"                                     | replaces delivery                                  |
| Coalescing             | `data` = **number of occurrences** since the last `kevent()`                                           | one queued `signalfd_siginfo` per signal           |
| Trigger mode           | "automatically sets the **EV_CLEAR** flag internally" (edge)                                           | level-triggered readable fd                        |
| Registration shape     | **one per signal number** (`ident` = the signal)                                                       | **one fd for a whole `sigset_t`**                  |

That last row is a structural difference an abstraction has to absorb, and libtorque
shows the shape:

```c
#ifdef TORQUE_LINUX_SIGNALFD
    fd = signalfd(-1, sigs, SFD_NONBLOCK | SFD_CLOEXEC);   /* ONE fd for N signals */
    add_fd_to_evhandler(ctx, evq, fd, signalfd_demultiplexer, NULL, ctx, 0);
#elif defined(TORQUE_FREEBSD)
    for (z = 1 ; z < ctx->eventtables.sigarraysize ; ++z) {   /* N registrations */
        if (!sigismember(sigs, z)) continue;
        EV_SET(&k, z, EVFILT_SIGNAL, EV_ADD | EVEDGET, 0, 0, NULL);
        if (Kevent(evq->efd, &k, 1, NULL, 0)) return TORQUE_ERR_ASSERT;
    }
#else
#error "No signal event implementation on this OS"
#endif
```

Note also that the Linux arm degrades rather than aborts: `signalfd` returning `ENOSYS`
becomes `TORQUE_ERR_UNAVAIL`.

### The `SIGCHLD` trap

libevent registers the filter and then **still installs a disposition**
([`kqueue.c`][le-kqueue]):

```c
/* We can set the handler for most signals to SIG_IGN and
 * still have them reported to us in the queue.  However,
 * if the handler for SIGCHLD is SIG_IGN, the system reaps
 * zombie processes for us, and we don't get any notification.
 * This appears to be the only signal with this quirk. */
if (evsig_set_handler_(base, nsignal, nsignal == SIGCHLD ? SIG_DFL : SIG_IGN) == -1)
        return (-1);
```

Read together with libtorque's man-page extract this stops being a mystery: because
`EVFILT_SIGNAL` reports even `SIG_IGN`'d signals, `SIG_IGN` is being used purely to
suppress a signal's _default action_, not to hide it from the queue. `SIGCHLD` is the
exception because there `SIG_IGN` changes kernel **reaping** semantics — the child is
auto-reaped, so there is nothing left to report.

The practical rule for a loop that adopts `EVFILT_SIGNAL`: register the filter, set
`SIG_IGN` for every signal whose default action would kill or stop the process, and
never set `SIG_IGN` on `SIGCHLD`.

---

## Child-process exit

| System        | Mechanism                                                                    |
| ------------- | ---------------------------------------------------------------------------- |
| [libxev][xev] | `EVFILT_PROC` with `NOTE_EXIT \| NOTE_EXITSTATUS`                            |
| [libuv][uv]   | `EVFILT_PROC` (see `ev->filter == EVFILT_PROC` in `uv__io_poll`) + `SIGCHLD` |
| [ghostty][gt] | `xev.Process.wait` → libxev's `EVFILT_PROC`                                  |

libxev's choice of flags is the notable one
([`src/backend/kqueue.zig`][xev-kqueue]): on macOS it requests
`NOTE.EXIT | NOTE.EXITSTATUS`, so the exit status arrives **in the kevent itself** and no
follow-up `waitpid`/`waitid` is required:

```zig
if (ev.fflags & NOTE_EXIT_FLAGS > 0) {
    const data: u32 = @intCast(ev.data);
    if (posix.W.IFEXITED(data)) break :res .{ .proc = posix.W.EXITSTATUS(data) };
}
```

Two caveats it does **not** handle, which a `waitid`-shaped API must:

- **The already-exited race.** Registering `EVFILT_PROC` against a pid that has already
  died fails with `ESRCH`. That is the _common_ case for a reap issued after the exit was
  noticed. libxev's test for it tolerates an error result (`r catch 0`); a loop whose op
  contract promises a status has to perform the wait inline and complete synthetically.
- **`siginfo_t` is not one struct.** Linux buries `si_status` in the `_sifields._sigchld`
  union arm; the BSDs and macOS expose it as a plain field.

---

## Creating the PTY: four systems, one answer

Every terminal surveyed passes the window size **at creation** and sets the controlling
terminal **explicitly**:

| Emulator          | Creation                                     | Controlling terminal                         |
| ----------------- | -------------------------------------------- | -------------------------------------------- |
| [ghostty][gt]     | `openpty(&m, &s, null, null, &winsize)`      | `setsid()` then `ioctl(slave, TIOCSCTTY, 0)` |
| [alacritty][alac] | `openpty(None, Some(&size.to_winsize()))`    | `ioctl(fd, TIOCSCTTY, 0)`                    |
| [wezterm][wez]    | `libc::openpty(…, &size)`                    | `ioctl(0, TIOCSCTTY, 0)`                     |
| [tmux][tmux-repo] | `fdforkpty(ptm_fd, &master, tty, NULL, &ws)` | via `forkpty`/`login_tty`                    |

None uses `posix_openpt` + `posix_spawn`. That is not an accident: **`posix_spawn` has no
file action that can issue `TIOCSCTTY`**, so a spawn-based PTY must rely on the implicit
"a session leader's first TTY open becomes its controlling terminal" rule. Ghostty pays
for the guarantee with a full `fork`/`exec` and a `childPreExec` that also resets a long
list of signal dispositions to default (`SIGCHLD`, `HUP`, `INT`, `PIPE`, `TERM`, `QUIT`,
…) and sets `FD_CLOEXEC` on the master so only the slave is inherited.

### Why winsize-at-creation matters _(probed)_

Setting the size afterwards on the master is not equivalent on macOS, because the TTY does
not exist until the slave is first opened:

```text
set-before: TIOCSWINSZ on master rc=-1 errno=25   (ENOTTY)
set-before: slave sees             rows=0  cols=0
set-after:  TIOCSWINSZ on master rc=0
set-after:  slave sees             rows=24 cols=80
```

A caller that ignores the `ioctl` return — as `sparkles:event-horizon`'s `spawnPty` did —
gets a child at `0x0` and no error anywhere.

### The spawn-flag trap

The same `spawnPty` carried a second defect worth recording as a general hazard:

```d
enum POSIX_SPAWN_SETSID = 0x80; // glibc and musl agree
```

They do agree. Darwin does not: there `0x80` is `POSIX_SPAWN_START_SUSPENDED`, and
`POSIX_SPAWN_SETSID` is `0x400` (XNU `bsd/sys/spawn.h`). The flag therefore did not merely
fail to create a session — it started **every** child stopped, so the child never `exec`d,
the master never became readable, and a `wait` on it blocked forever. Diagnosed by
resuming one: wait status `0x7f` (`_WSTOPPED`), and after `SIGCONT` the child ran to
completion with its script's exit status. **This is the probe that produced the false
"kqueue cannot watch PTY masters" conclusion.**

---

## What this means for `sparkles:event-horizon`

| Finding                                                     | Consequence for the Sparkles loop                                                                                                                    |
| ----------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| kqueue rejects regular files/dirs, and FIFOs on Darwin      | `canSubmitOp!(B, OpRead)` is a **compile-time answer to a runtime question**. Add a libuv-shaped `checkFd` probe (static rules + trial registration) |
| Bad fds need somewhere to go                                | Either libuv's automatic `select()` thread or libxev's caller-declared thread-pool flag; today there is no fallback at all                           |
| kqueue does watch PTY masters                               | `TVW8`'s ring pump is sound on macOS; the thread is an optional throughput optimisation, not a fix                                                   |
| `EVFILT_SIGNAL` ≠ `signalfd`                                | A kqueue signal path must **not** `sigprocmask`, is edge-triggered, coalesces into `data`, and needs one registration per signal                     |
| The `SIGCHLD` / `SIG_IGN` interaction                       | Encode libevent's rule if the signal path is ever extended past `SIGWINCH`                                                                           |
| `NOTE_EXITSTATUS` carries the status                        | Our `EVFILT_PROC` lowering could drop its follow-up `waitid` — but only for an API that does not promise a caller-filled `siginfo_t`                 |
| `posix_spawn` cannot `TIOCSCTTY`                            | `spawnPty`'s controlling-terminal acquisition is implicit and unverified; `openpty` + `fork`/`exec` is the consensus                                 |
| Everyone passes winsize to `openpty`                        | Replaces the "hold the slave open across the spawn" workaround with one call                                                                         |
| Ghostty resets child signal dispositions and sets `CLOEXEC` | `POSIX_SPAWN_SETSIGDEF` and `FD_CLOEXEC` on the master are both absent from `spawnPty`                                                               |

The open design choice is the signal mechanism. `EVFILT_SIGNAL` is the smaller change
against the existing `SignalFd` seam; a **self-pipe** (libuv, kitty) would collapse the
Linux and BSD paths into one implementation at the cost of a handler and a pipe. Both are
production-proven; the trade is "two correct backends" against "one backend with a
handler".

### Reproducing the probes

The measurements marked _(probed)_ came from two short D programs run against the
`sparkles` dev shell on macOS 25.6 (M4 Max):

- **kqueue on a PTY master** — `posix_openpt`/`grantpt`/`unlockpt`, open the slave in the
  same process, then a one-shot `EVFILT_READ` registration with a 1–2 s timeout before a
  write, after a write, and after closing the slave.
- **`TIOCSWINSZ` ordering** — the same setup, setting the size before vs. after the slave
  is opened and reading it back with `TIOCGWINSZ` from the slave.

Both need a live kqueue and a PTY, so neither can run on the Linux CI leg; they are
described rather than committed as examples. Wiring them into a macOS CI job
(`docs/specs`-tracked work) would make these two rows CI-verified like the rest of the
corpus.

---

## Sources

Repositories were cloned to `~/code/repos` and read at these commits:

| Repository | Commit                  |
| ---------- | ----------------------- |
| libuv      | [`a6d06ba`][uv-tree]    |
| libxev     | [`9ce8e8e`][xev-tree]   |
| libevent   | [`c96ddc2`][le-tree]    |
| libtorque  | [`ec94356`][lt-tree]    |
| mio        | [`52cfaa4`][mio-tree]   |
| ghostty    | [`156bc8c`][gt-tree]    |
| alacritty  | [`1b2b36a`][alac-tree]  |
| kitty      | [`e7d41ff`][kitty-tree] |
| wezterm    | [`e723cf5`][wez-tree]   |
| tmux       | [`851c5a9`][tmux-tree]  |
| XNU tests  | [`f6217f8`][xnu-tree]   |

Man pages quoted second-hand through libtorque's `signal.c` (FreeBSD 6.4 `kevent(2)`,
Linux 2.6.31 `signalfd(2)`) were spot-checked against current documentation.

### See also

- [Event-loop primitives][primitives] — the signal and subprocess tiers this page deepens
- [Implementation techniques][techniques] — feature probing as a general pattern
- [Grand Central Dispatch][gcd] — the same kqueue interfaces as macOS's own concurrency service exercises them (`EV_DISPATCH` sources, `kevent_qos`/`kevent_id`, `EVFILT_PROC` exit status)
- [libuv deep-dive][libuv] — the same library from the portability-abstraction angle
- [Zig `std.Io`][zig-io] — the other Kqueue-backend design in this corpus
- [terminal-view spec][tvw] — `TVW8`, the consumer these findings feed

<!-- References -->

<!-- Sibling docs -->

[primitives]: ./primitives.md
[techniques]: ./techniques.md
[libuv]: ./libuv.md
[gcd]: ./gcd/index.md
[zig-io]: ./zig-io.md
[uring-index]: ./io-uring/index.md
[tvw]: ../../specs/ui-app/terminal-view.md

<!-- Pinned source files -->

[uv-kqueue]: https://github.com/libuv/libuv/blob/a6d06ba716b6facdf00e29306aa5013d51e070d4/src/unix/kqueue.c
[uv-stream]: https://github.com/libuv/libuv/blob/a6d06ba716b6facdf00e29306aa5013d51e070d4/src/unix/stream.c
[xev-kqueue]: https://github.com/mitchellh/libxev/blob/9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf/src/backend/kqueue.zig
[le-kqueue]: https://github.com/libevent/libevent/blob/c96ddc2727a4ed0ca744500efff7230316b4118d/kqueue.c
[lt-signal]: https://github.com/dankamongmen/libtorque/blob/ec94356088f8fe757d378770d6620249efb21f89/src/libtorque/events/signal.c
[alacritty-loop]: https://github.com/alacritty/alacritty/blob/1b2b36a64e88068ad02c95fad00ee2fad31c00bf/alacritty_terminal/src/event_loop.rs
[gt-exec]: https://github.com/ghostty-org/ghostty/blob/156bc8c814292349981f3adbfb1120c3d4f02020/src/termio/Exec.zig
[xnu-kevent-pty]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/tests/kevent_pty.c

<!-- Pinned trees -->

[uv-tree]: https://github.com/libuv/libuv/tree/a6d06ba716b6facdf00e29306aa5013d51e070d4
[xev-tree]: https://github.com/mitchellh/libxev/tree/9ce8e8e6ff89e583258a7f8e7adeeeaeae8611bf
[le-tree]: https://github.com/libevent/libevent/tree/c96ddc2727a4ed0ca744500efff7230316b4118d
[lt-tree]: https://github.com/dankamongmen/libtorque/tree/ec94356088f8fe757d378770d6620249efb21f89
[mio-tree]: https://github.com/tokio-rs/mio/tree/52cfaa4168e8545bc197cd333f81f254e25c59b5
[gt-tree]: https://github.com/ghostty-org/ghostty/tree/156bc8c814292349981f3adbfb1120c3d4f02020
[alac-tree]: https://github.com/alacritty/alacritty/tree/1b2b36a64e88068ad02c95fad00ee2fad31c00bf
[kitty-tree]: https://github.com/kovidgoyal/kitty/tree/e7d41ff7f47405061cb2065823c3f38f89653539
[wez-tree]: https://github.com/wezterm/wezterm/tree/e723cf5005098fde4ef05cf73d7f40d29d85ad5f
[tmux-tree]: https://github.com/tmux/tmux/tree/851c5a933d4838c32ad06c248b2ba975d106149c
[xnu-tree]: https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea

<!-- Project homes -->

[uv]: https://github.com/libuv/libuv
[xev]: https://github.com/mitchellh/libxev
[le]: https://github.com/libevent/libevent
[lt]: https://github.com/dankamongmen/libtorque
[mio]: https://github.com/tokio-rs/mio
[gt]: https://github.com/ghostty-org/ghostty
[alac]: https://github.com/alacritty/alacritty
[kitty-repo]: https://github.com/kovidgoyal/kitty
[wez]: https://github.com/wezterm/wezterm
[tmux-repo]: https://github.com/tmux/tmux
