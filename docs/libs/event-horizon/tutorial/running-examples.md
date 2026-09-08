# Running the comparison examples

Each of the eight migration guides compares ten concepts using complete source
files under `docs/libs/event-horizon/tutorial/snippets/`. The ten Event Horizon
fiber programs are shared; each library has its own ten counterparts. The
eventcore and vibe-core guides additionally share six native callback programs,
bringing the original contract suite to 96 programs. Separate concise tutorials
are being added alongside them: 36 currently cover the Node.js and vibe-core
guides. The eight articles retain 172 displayed outputs in total. VitePress shows
complete files, each with a separately verified output tab.

The D files are single-file DUB packages. Node.js uses native `.mjs` files with
`node:assert/strict` in the contract suite, not pseudo-JavaScript or a D translation. Native-library
operations and application-side adapters are distinguished in the articles.

## Prerequisites and commands

These fixtures target Linux with a usable io_uring backend. They use the current
repository through a relative DUB dependency, not a published package version.
The signal and process examples also require normal POSIX facilities and `sh`.
The comparison verifier requires Node.js 24 and GNU coreutils `timeout`.
Run from a checkout with the project's D toolchain available:

```bash
dub run --single apps/ci/tools/prepare-event-horizon-comparisons.d --temp-build -b checked
dub run --single docs/libs/event-horizon/tutorial/snippets/tutorial/eh_timers.d -b checked
node docs/libs/event-horizon/tutorial/snippets/tutorial/node_timers.mjs
# The standalone contract version remains runnable too:
dub run --single docs/libs/event-horizon/tutorial/snippets/eh_timers.d -b checked
dub run :ci -- --verify --include-files 'docs/libs/event-horizon/tutorial/coming-from-*.md'
```

Run a D source from its original location: its relative dependencies resolve
from that file. Copying only its body into an unrelated directory omits the
package recipe and changes that resolution. No line-sliced imports are used.

## Dependency baselines

| Counterpart   | Recipe baseline                                      | Integration notes                                                              |
| ------------- | ---------------------------------------------------- | ------------------------------------------------------------------------------ |
| Node.js       | Tested runtime: 24.19.0                              | Native promise, stream, process and signal APIs; no npm packages.              |
| vibe-core     | 2.14.0                                               | Uses the package's eventcore dependency.                                       |
| eventcore     | 0.9.39                                               | Default Linux driver; not a certification of every selectable driver.          |
| libasync      | 0.9.8                                                | Linux callback API; explicit worker adapters for processes and POSIX signals.  |
| Photon        | 0.19.3                                               | `initPhoton`, scheduler, channels and offloaded worker adapters.               |
| EVE           | `c72f75135de636987e91bcd8ec5a22d32d34a197`           | Public Codeberg Git dependency; not a personal checkout path.                  |
| Collie        | `f1e58e38a2c36366766e4778d3ea655ebac6962c` (0.10.16) | Isolated compatibility checkout; low-level event examples use its Kiss engine. |
| Kiss          | `6d07c263c2b9bdec493996b7f4cedb95b5812271` (0.4.9)   | Explicit transitive override for Collie, prepared below.                       |
| Hunt-net      | 0.7.1                                                | Hunt Task/queue adapters are not native structured supervision.                |
| event-horizon | This Sparkles checkout                               | Requires usable Linux io_uring; no silent fallback or skip.                    |

The preparation command clones Collie and Kiss into the ignored
`snippets/.deps/` directory and applies checked-in patches. It does **not** edit
registered DUB packages or the source checkouts used for research. Collie's patch
parenthesizes assignment expressions and adds a missing timer import. Kiss's
patch sizes the flag array to include index 16 (`ETMode`), fixes an eight-byte
timerfd read into a four-byte variable, closes its
wakeup channel during selector disposal, and avoids allocating a log message
from GC finalization. These are patched baselines, not claims that the original
releases pass unchanged. Re-running preparation checks the pinned revisions.

Hunt's standalone fixtures also stop and join its startup DateTime daemon before
creating application threads. The pinned graph otherwise leaves that daemon
alive during runtime shutdown. This explicitly asserted, process-owned adapter
is explained in [the Hunt-net guide](./coming-from-hunt-net.md); it is not advice
to stop arbitrary host threads when embedding the library.

The local compiler baseline is LDC 1.42.0 (D 2.112). Exact direct recipe versions
and the source-review revisions serve different purposes: a linked research
revision does not replace the dependency actually resolved by DUB. Transitive
registry dependencies retain their upstream constraints; clean-cache verification
checks the resulting graph rather than assuming local-cache success is enough.

## What the verifier guarantees

Migration pages are being split into two suites. The Node.js and vibe-core pages display
concise executable programs from `snippets/tutorial/` and links the original
assertion-heavy programs in `snippets/` after each comparison. The other six
pages still display their original contract programs until their conversion is
complete. Both kinds are standalone single-file programs, not source fragments.

For a converted page, `ci --verify` executes each displayed tutorial, checks its
output, and independently runs its contract counterpart with assertions enabled.
It rejects missing counterparts, mixed suites, symlink aliases and attempts to
revert a converted page to contract imports. Full source paths—not basenames—
identify programs, so a passing contract cannot stand in for a failing tutorial.
Only displayed tutorial output blocks are candidates for `--update`.

Each `coming-from-*.md` page must contain all ten concepts, with full-file
source imports and adjacent `ansi [implementation output]` tabs. The eventcore
and vibe-core pages additionally require callback and fiber implementations for
timers, concurrency, deadlines, TCP, file reads and retries. Missing styles or pairs,
missing or ambiguous outputs, missing sources, sliced imports and paths escaping
the documentation tree fail validation. Quoted Markdown is not executed.
Imported outputs use literal comparisons (including empty output); legacy
wildcard matching does not weaken this contract.

The verifier builds D programs in `checked` mode in isolated DUB/TMP directories,
then runs the cached artifacts so compiler diagnostics do not become expected
program output. It executes each shared source once per invocation but compares
every displayed output occurrence independently. Node.js runs through the same
exit-status and process-group deadline checks. A stuck launcher and its ordinary
descendants receive TERM, then KILL after two seconds. This is not containment
for a deliberately escaping descendant.

`SPARKLES_CI_JOBS` controls parallel builds; `SPARKLES_CI_EXAMPLE_TIMEOUT` sets
the per-build/per-run deadline in seconds (strict comparisons retain a finite
default even when the legacy timeout setting is disabled). To regenerate output
after an intentional source change, use the same command with `--update` instead
of `--verify`. It updates Markdown output spans, never imported source files.

`checked` keeps assertions enabled in the contract suite. Tutorials instead
handle expected failures and report errors at the application boundary. An
unavailable backend is an explicit failure, not silently reported as a
successful demonstration.

The default `LoopGroup` topology is one scheduler on the calling thread. Fibers
can run concurrently without running simultaneously on multiple CPU cores.
Do not share scheduler-local channels or handles across worker threads.

## Completion interface, backend-specific implementation

Linux io_uring submits operations and reports their completion. Event Horizon's
kqueue backend synthesizes completions over readiness; it does not turn kqueue
into an io_uring-style ring. Backend support is not identical, and the Windows
supervision port remains deferred. Consult [PLAN.md][plan] before relying on an
operation outside the tested Linux path.

Moving a buffer transfers its ownership through an operation. It does not prove
zero-copy transport, eliminate every alias, or make the whole application
`@nogc`. Setup, callbacks, and integrations can allocate or throw. Blocking host
work needs an explicit worker boundary; a fiber does not make arbitrary blocking
calls cooperative.

## I/O results versus scope outcomes

| Result          | What to check                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------- |
| `IoResult!T`    | `hasError` before reading `value`; errors carry errno, operation, and stage.                  |
| `Outcome!T`     | Scope success, failure, interruption, or defect; do not discard the outer `group.run` result. |
| Process result  | Inspect both the I/O result and exit status; a nonzero child exit is normal result data.      |
| Channel receive | `EPIPE` means closed and drained; cancellation is not normal end-of-stream.                   |

Joining structured children does not preempt CPU-bound code. A deadline is
cooperative and can take longer than its requested duration while children and
protected cleanup finish. See [the scope and cancellation specification][spec].

## Deadlines and cleanup

The sleep is interrupted, but the small protected cleanup completes before the
deadline outcome is returned.

<<< @/libs/event-horizon/tutorial/snippets/eh_deadline.d [event-horizon]

```ansi
sleep returned: ECANCELED
timed out: true
cleaned up: true
```

## TCP is a byte stream

Neither a send nor a receive is guaranteed to transfer an entire application
message. The echo fixture uses an ephemeral loopback port and loops over partial
transfers. Its five-byte exchange is a fixture protocol, not a general decoder.

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi
echoed: hello
```

## Capture versus streaming supervision

Use `capture` to collect stdout/stderr and the root's exit status. Use `supervise`
for framed output callbacks, resource samples, and termination policy. Callback
line bytes are borrowed: copy them if they must outlive the callback.

<<< @/libs/event-horizon/tutorial/snippets/eh_spawn.d [event-horizon]

The sample requests cancellation only after receiving both expected lines, then
asserts a cancelled outcome, root reap status, SIGTERM and natural EOF for this
specific Linux fixture. `exec sleep` avoids a shell descendant retaining the
pipe. The deadline example separately demonstrates timeout delivery. General
supervision may escalate to KILL and report degraded containment; this small
fixture does not prove those paths or portable signal numbers.

Tree containment is capability-dependent. Linux cgroups strengthen the boundary,
but post-spawn migration can race a child that forks immediately; process groups
do not contain a descendant that creates another session. Degradation and leaked
cgroup telemetry remain meaningful results, not guarantees to omit from a caller.

## POSIX signals are not cross-thread messages

Create `SignalFd` before starting other threads that should inherit the blocked
signal mask. This fixture sends `SIGUSR1` to itself, then consumes it through the
scheduler. It is distinct from a library's in-process notification object.

<<< @/libs/event-horizon/tutorial/snippets/eh_signal.d [event-horizon]

```ansi
got signal SIGUSR1
```

## Retry with a clock capability

This policy combines exponential delays with a finite recurrence limit. The
example uses portable `EAGAIN` rather than a Linux numeric literal.

<<< @/libs/event-horizon/tutorial/snippets/eh_retry.d [event-horizon]

```ansi
succeeded on attempt 3
```

Return to the [library overview](../index.md) to choose a source-library guide.

<!-- References -->

[plan]: ../../../specs/event-horizon/PLAN.md
[spec]: ../../../specs/event-horizon/SPEC.md
