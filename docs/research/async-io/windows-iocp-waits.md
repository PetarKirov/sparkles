# Windows IOCP Waits, Timers and Job Objects

How a single-port IOCP loop learns that a process exited and that a deadline passed, without a
threadpool callback, a helper thread or a polling loop — and what Job Objects promise about the
tree it supervises. The note behind `sparkles:event-horizon`'s Windows lowering
([SPEC §13.9][spec-13-9]; [PLAN M19][plan-m19] item 5).

| Field    | Value                                                                                                     |
| -------- | --------------------------------------------------------------------------------------------------------- |
| Scope    | wait completion packets, IOCP dequeue mapping, timer resolution, Job Objects, `CreateProcess` inheritance |
| Systems  | Windows NT kernel (`ntdll`), Go runtime, .NET threadpool, `win32-iocp-events`, smol `async-io`, QuickTick |
| Category | Concept / technique (cross-cutting over the [master catalog][index])                                      |
| Feeds    | [SPEC §13.9][spec-13-9]; `backend/iocp.d`, `live_windows.d`, `supervise.d`, `sampling_windows.d`          |

**Last reviewed:** November 1, 2026

> [!NOTE]
> A technique note, like [Process Supervision][process-supervision]: each section states what the
> sources establish, then what `event-horizon` does with it. Where no source settles a point, the
> note says so and names the test that does.

---

## Wait completion packets

### What they are

A wait completion packet turns "this waitable object signalled" into one packet on a completion
port. Microsoft's devnotes document three `ntdll` exports with no import library
([create][dn-create], [associate][dn-associate], [cancel][dn-cancel]); phnt declares them
behind `PHNT_VERSION >= PHNT_WINDOWS_8` ([`phnt/include/ntioapi.h`][phnt-ntioapi]):

```c
NTSTATUS NtCreateWaitCompletionPacket(PHANDLE WaitCompletionPacketHandle,
    ACCESS_MASK DesiredAccess, PCOBJECT_ATTRIBUTES ObjectAttributes);
NTSTATUS NtAssociateWaitCompletionPacket(HANDLE WaitCompletionPacketHandle,
    HANDLE IoCompletionHandle, HANDLE TargetObjectHandle, PVOID KeyContext,
    PVOID ApcContext, NTSTATUS IoStatus, ULONG_PTR IoStatusInformation,
    PBOOLEAN AlreadySignaled);
NTSTATUS NtCancelWaitCompletionPacket(HANDLE WaitCompletionPacketHandle,
    BOOLEAN RemoveSignaledPacket);
```

phnt's access mask for the object is `WAIT_COMPLETION_PACKET_ALL_ACCESS`
(`WAIT_COMPLETION_PACKET_SET_STATE | STANDARD_RIGHTS_REQUIRED`); `win32-iocp-events` and Go both
create with `GENERIC_ALL` ([`win32-iocp-events.cpp`][tringi-cpp]; [Go blog][go-timers]).

The same mechanism is what the Windows threadpool uses for its own waits. .NET's NativeAOT
write-up: from Windows 8 the threadpool "was changed to internally use I/O completion ports to
implement the wait", and "the relevant, undocumented system calls are
`NtCreateWaitCompletionPacket`, `NtAssociateWaitCompletionPacket`, and
`NtCancelWaitCompletionPacket`" ([awise.us][awise]). So `RegisterWaitForSingleObject` is this
packet plus a callback hop onto a pool worker; calling the exports directly removes the hop and
the worker.

### Semantics, checked against each claim in the code

| Claim                                                                                                                                                             | Evidence                                                                                                                                                                                                                                                                                              | Status                                                              |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| One association queues one packet; after pickup it must be associated again.                                                                                      | Devnotes: "When the packet is picked up, the association must be reestablished by calling this function again. An error is returned if the wait completion packet is already in use for an association." `win32-iocp-events.h`: "use to wait again, after the event completion was consumed".         | confirmed                                                           |
| The dequeued `OVERLAPPED_ENTRY` carries `KeyContext` as `lpCompletionKey`, `ApcContext` as `lpOverlapped`, `IoStatusInformation` as `dwNumberOfBytesTransferred`. | `win32-iocp-events` re-associates a dequeued entry by passing `lpCompletionKey`, `lpOverlapped` and `dwNumberOfBytesTransferred` back in those three positions ([`win32-iocp-events.cpp`][tringi-cpp]); Go dispatches on `entry.Key` ([Go blog][go-timers]).                                          | confirmed                                                           |
| `IoStatus` arrives as `Internal`.                                                                                                                                 | `NtRemoveIoCompletion` returns an `IO_STATUS_BLOCK` whose `Status` is the queued status ([devnotes][dn-remove]); phnt's `FILE_IO_COMPLETION_INFORMATION` is `{ KeyContext, ApcContext, IoStatusBlock }`. No source passes a non-zero status.                                                          | inferred; the code passes 0 and treats any status `< 0` as an error |
| An already-signalled target queues its packet at once; `AlreadySignaled` is informational.                                                                        | Devnotes: it "receives an indication of whether the target object was already signaled at the time of the association". `win32-iocp-events` commit `33e06da`: "no need to evaluate 'AlreadySignalled', the packet gets enqueued anyway" ([commit][tringi-33e06da]).                                   | confirmed; native test `iocp.waitHandle.signalAndAlreadySignalled`  |
| The target handle is not consumed (a process handle stays valid for `GetExitCodeProcess`).                                                                        | A wait on a process/event is a dispatcher wait; nothing in the API takes ownership of the target.                                                                                                                                                                                                     | native test asserts the event is still signalled afterwards         |
| `NtCancelWaitCompletionPacket(p, TRUE)` returning `STATUS_SUCCESS` means no packet will be dequeued.                                                              | Devnotes table: `STATUS_SUCCESS` success; `STATUS_PENDING` "may be pending and the packet cannot be immediately reused"; `STATUS_CANCELLED` "already been completed or … never been associated". `win32-iocp-events.h`: "if TRUE, if already signalled, the completion packet is removed from queue". | **not stated by any source** — settled by native tests              |

The last row is load-bearing: `trySubmitCancel` synthesizes the target's `-ECANCELED` only on
`STATUS_SUCCESS`, and lets the queued packet deliver otherwise. Two native tests decide it:
`iocp.waitHandle.cancelBeforeSignal` (cancel an unsignalled wait: exactly one `-ECANCELED`, and
a later signal delivers nothing) and `iocp.waitHandle.cancelAfterSignal` (signal, then cancel
before any dequeue: exactly one terminal completion for the target, whichever way the race went).

### Lifetimes

- The packet is closed after its pickup or after a successful cancel — never while associated.
  `win32-iocp-events`' example cancels with `TRUE`, then closes the packet, then the target, then
  the port ([`example.cpp`][tringi-example]).
- The target outlives the association. For a child, the process handle is closed only after
  its wait completed and `GetExitCodeProcess` read the status, so a recycled pid can never be
  waited on through a stale handle.
- A packet completion does not set an `OVERLAPPED.hEvent`. The backend's native-host event
  (folded into `MsgWaitForMultipleObjectsEx` by a Win32 message host) therefore misses a process
  exit until its next wake. Recorded as a limitation; the ordinary loop wait is the port.

### Availability

Wine 11 (`wine64`, the `.#win32` dev shell) exports none of the three; it does export
`wine_get_version`, which the tests use to tell an expected Wine gap from a native regression.
smol-rs declined the exports partly for this reason: "it has led to breakages on certain platforms
(e.g. Wine)" ([async-io#25][smol-25]). `event-horizon` resolves them at run time, clears the
`waitid` capability bit where any is missing, and has **no** threadpool or polling fallback.

---

## Timers: the port-wait timeout versus a high-resolution waitable timer

### The resolution evidence

- A wait's timeout is quantised to the clock interval. Windows Internals: "for most x86 and x64
  multiprocessors it is about 15 milliseconds"; `clockres` reports "Maximum timer interval:
  15.600 ms … Minimum timer interval: 0.500 ms" ([WI7][wi7], ch. 4, "Quantum").
- Lowering the interval is global: `timeBeginPeriod` "causes a global reprogramming of the kernel
  interval timer, meaning the scheduler wakes up in more frequent intervals, which can degrade
  system performance" ([WI7][wi7], ch. 4).
- Go's pre-1.23 `Sleep` passed the duration as the `GetQueuedCompletionStatusEx` timeout, whose
  "resolution is ~15.6ms". Go 1.23 arms a `CREATE_WAITABLE_TIMER_HIGH_RESOLUTION` timer and
  associates it with the netpoll port through a wait packet, "boosting resolution from ~15.6ms to
  ~0.5ms" ([Go blog][go-timers]).
- QuickTick measures the same timer class waited on directly: about 300 µs to signal, a minimum
  interval "around 0.518 ms", without `timeBeginPeriod`; high-resolution support arrived in
  "Windows 10 version 1803" ([QuickTick][quicktick]).

### Conclusion

The current IOCP timers round each deadline up to whole milliseconds and wait in
`GetQueuedCompletionStatusEx`, so a 1 ms `sleep` costs a full clock interval (≈15.6 ms) unless
some process raised the system rate. The evidence supports the Go design, and `event-horizon`
adopts it as the default with the port timeout kept as the fallback:

- one high-resolution waitable timer per backend, armed to the earliest software-timer
  deadline, and one persistent wait packet that bridges it to the port (re-associated after
  each pickup, per the one-shot rule above);
- the packet is backend-internal: its pickup is consumed in the dequeue, never surfaced as a
  completion; the software timer list still decides which timers expired;
- where the timer class or the exports are missing (Windows 10 before 1803, Wine) — or when
  `BackendConfig.coarseTimers` forces it, for A/B measurement — the port-wait timeout drives
  timers as before;
- the port-wait timeout stays as a backstop in both modes, so a failed re-arm costs latency,
  never a hang.

---

## Job Objects and process creation

From Windows Internals 7th ed., Part 1, ch. 3 ([WI7][wi7]):

- **Containment.** "A process's association with a job object can't be broken, and all
  processes created by the process and its descendants are associated with the same job object
  (unless child processes are created with the `CREATE_BREAKAWAY_FROM_JOB` flag and the job
  itself has not restricted it)." The run's job never sets `JOB_OBJECT_LIMIT_BREAKAWAY_OK`, so a
  descendant cannot leave it.
- **Accounting survives exit.** "The job object also records basic accounting information for
  all processes associated with the job and for all processes that were associated with the job
  but have since terminated." Totals are cumulative; peaks come from the extended limit
  information (`PeakJobMemoryUsed`, `PeakProcessMemoryUsed`).
- **CPU times are tick-sampled.** Clock-based accounting charges a thread only when it is
  running at a clock interrupt; short-lived threads "are not charged for much of their CPU time"
  ([WI7][wi7], ch. 3, Process Explorer). Job `TotalUserTime`/`TotalKernelTime` are therefore a
  `lowerBound`, not `exact`.
- **Nesting.** Since Windows 8 a process may belong to several jobs forming a hierarchy; "when a
  job is terminated (`TerminateJobObject`), all processes in the job and in child jobs are
  terminated". A CI runner that already places the test in a job does not stop a per-run job.
- **Assignment without a window.** `CREATE_SUSPENDED` keeps the initial thread from running
  ("Stage 6 … Unless the caller specified the `CREATE_SUSPENDED` flag, the initial thread is now
  resumed"), so assign-then-resume runs no child code outside the job. The `PS_CP_JOB_LIST`
  attribute (Win32 `PROC_THREAD_ATTRIBUTE_JOB_LIST`) closes it by construction instead: "If a job
  list was supplied … and this is the first thread in the process, then the process is assigned
  to all of the jobs". `event-horizon` keeps the owner's suspend/assign/resume sequence, which
  also lets it terminate and reap a child whose assignment failed.
- **Inheritance.** At creation "any inheritable handles are copied … A process attribute can also
  be used to specify only a subset of handles" (stage 21): `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`.
- **Job notifications.** A job can be associated with a completion port and posts messages there
  (limit violations, process creation and exit). They carry a process id, not an `OVERLAPPED`, so
  a port that maps every packet to an op context cannot share them; a run-level "active process
  count reached zero" signal for `ResidualPolicy.wait` would need its own port or a key-based
  dispatch. Not used yet.

---

## What changes in SPEC §13.9

| SPEC said                                                        | Finding                                                                                                     | Now                                                                               |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| process exit uses one `RegisterWaitForSingleObject` registration | that is a threadpool wait over the same packet, plus a callback on a worker                                 | one wait completion packet per process wait, associated with the scheduler's port |
| sampling uses "process/memory classes"                           | the job's basic-and-I/O accounting (class 8) and extended limit information (class 9) carry everything used | `QueryInformationJobObject` classes 8 and 9; CPU quality `lowerBound`             |
| (silent on timers)                                               | port-wait timeouts are clock-interval quantised                                                             | high-resolution waitable timer through a wait packet; port timeout as fallback    |

---

## Sources

- Microsoft, devnotes: [`NtCreateWaitCompletionPacket`][dn-create],
  [`NtAssociateWaitCompletionPacket`][dn-associate], [`NtCancelWaitCompletionPacket`][dn-cancel],
  [`NtRemoveIoCompletion`][dn-remove].
- System Informer phnt at `7c93cbaa`: [`ntioapi.h`][phnt-ntioapi] (wait packets, I/O completion),
  [`ntexapi.h`][phnt-ntexapi] (`NtCreateTimer2`, `NtSetTimerResolution`),
  [`ntpsapi.h`][phnt-ntpsapi] (job information classes).
- Go: [High-Resolution Timers on Windows][go-timers] (October 1, 2024).
- A. Wise: [.NET NativeAOT on the Windows threadpool][awise] (September 18, 2022).
- J. Tringi, `win32-iocp-events` at `695eaab7`: [`win32-iocp-events.cpp`][tringi-cpp],
  [`win32-iocp-events.h`][tringi-h], [`example.cpp`][tringi-example], [commit `33e06da`][tringi-33e06da].
- smol-rs `async-io`: [#14][smol-14] (waitable handles), [#25][smol-25] (`NtAssociateWaitCompletionPacket`).
- Uight, [QuickTick][quicktick] at `59064b6e`.
- P. Yosifovich, A. Ionescu, M. Russinovich, D. Solomon, _Windows Internals_, 7th ed., Part 1
  ([WI7][wi7]): ch. 3 "Processes and jobs" (Flow of `CreateProcess`, Jobs), ch. 4 "Threads"
  (clock interval, quantum), ch. 6 "I/O system" (I/O completion ports).

[index]: ./index.md
[process-supervision]: ./process-supervision.md

<!-- Sparkles -->

[spec-13-9]: ../../specs/event-horizon/SPEC.md#139-windows-lowering-m19
[plan-m19]: ../../specs/event-horizon/PLAN.md#m19--cross-platform-supervised-processes-for-appsci

<!-- External -->

[dn-create]: https://learn.microsoft.com/en-us/windows/win32/devnotes/ntcreatewaitcompletionpacket
[dn-associate]: https://learn.microsoft.com/en-us/windows/win32/devnotes/ntassociatewaitcompletionpacket
[dn-cancel]: https://learn.microsoft.com/en-us/windows/win32/devnotes/ntcancelwaitcompletionpacket
[dn-remove]: https://learn.microsoft.com/en-us/windows/win32/devnotes/ntremoveiocompletion
[phnt-ntioapi]: https://github.com/winsiderss/systeminformer/blob/7c93cbaad9395f3533451fd16f1691be792a690d/phnt/include/ntioapi.h
[phnt-ntexapi]: https://github.com/winsiderss/systeminformer/blob/7c93cbaad9395f3533451fd16f1691be792a690d/phnt/include/ntexapi.h
[phnt-ntpsapi]: https://github.com/winsiderss/systeminformer/blob/7c93cbaad9395f3533451fd16f1691be792a690d/phnt/include/ntpsapi.h
[go-timers]: https://devblogs.microsoft.com/go/high-resolution-timers-windows/
[awise]: https://www.awise.us/2022/09/18/dotnet-nativeaot-windows-threadpool.html
[tringi-cpp]: https://github.com/tringi/win32-iocp-events/blob/695eaab7470be02cc6552b06ae87a1ca8313fdd7/win32-iocp-events.cpp
[tringi-h]: https://github.com/tringi/win32-iocp-events/blob/695eaab7470be02cc6552b06ae87a1ca8313fdd7/win32-iocp-events.h
[tringi-example]: https://github.com/tringi/win32-iocp-events/blob/695eaab7470be02cc6552b06ae87a1ca8313fdd7/example.cpp
[tringi-33e06da]: https://github.com/tringi/win32-iocp-events/commit/33e06da9b4155c7ef50ed031bf5a2074e027b6f5
[smol-14]: https://github.com/smol-rs/async-io/issues/14
[smol-25]: https://github.com/smol-rs/async-io/issues/25
[quicktick]: https://github.com/Uight/QuickTick/tree/59064b6eb5e8ae7e8c153f5cb2d80dbb87d3b71c
[wi7]: https://www.microsoftpressstore.com/store/windows-internals-part-1-system-architecture-processes-9780735684188
