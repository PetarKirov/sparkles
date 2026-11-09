---
status: draft
owner: sparkles:ui-app
reviewed: 2026-11-09
---

# `sparkles:ui-app` — Output-to-photon latency on the native arm

## Abstract

When another process writes to a Sparkles window — a shell into a terminal
pane, a build log into a viewer — the bytes should reach the screen as soon
as the display can show them, and a flood of output should move as fast as
the pipe allows. This page specifies how `sparkles:ui-app` achieves both
for windows it draws with Vulkan on Linux: output is read and parsed the
moment it arrives, through io_uring multishot reads into kernel-filled
buffers; each frame starts at the last moment that still makes the earliest
refresh it can reach, so it carries the newest bytes without being shown
any later; and the present path learns when each frame turned into light
from `VK_EXT_present_timing`, Wayland's presentation feedback or
`VK_KHR_present_wait2`, whichever is best available. It also defines how
that latency is measured.

## Introduction

A terminal emulator is judged on two numbers its user feels without a
stopwatch. One is throughput: `cat` of a large file or a compiler's output
must not slow the program producing it. The other is latency: a key echoed
by the shell, or a progress line, must appear on the next refresh, not two
or three later. Both depend on the path from a `write(2)` in a child process
to the first pixel lit on the display. That path is long: a pty, a wake-up
of the application's thread, parsing, a frame's layout and recording, the
GPU, the compositor's own frame, and scan-out.

The application this page governs is the **native arm** of
`sparkles:ui-app`: a window opened through `sparkles:wsi` and drawn by
`sparkles:ui-vulkan`, as opposed to its terminal and raylib arms. Its loop
reads window-system events and its own descriptors through one
`sparkles:event-horizon` event loop on one thread.

A frame-driven application handles this path badly. If it reads its input
only while preparing a frame, it reads once per refresh, and any output
beyond what the pty buffers, about 40 KB on Linux, waits: the producer
blocks until the next frame. A feasibility measurement on the reference
configuration of §5 found frame-driven reads moving 2.4 MB/s through a pty
that sustains 28.5 MB/s. If it draws as soon as the compositor signals a
frame opportunity, it parses nothing more between that signal and the
refresh its frame is shown at, so the frame misses bytes that arrived in
that gap although it could have included them. And if it waits for its own
presents by blocking, it reads nothing while it waits.

This page's approach separates three stages that frame-driven code fuses,
and runs them on the application's one thread. **Ingest** reads and parses
output when the event loop reports it, independent of frames, with a
bounded amount of work per loop turn. **Scheduling** predicts the display's
next refresh from presentation feedback and starts the frame only as early
as the frame's measured cost requires, so the ingest stage runs until the
last useful moment. **Presenting** tags every frame and reads back when it
was shown, without blocking, through the best of the mechanisms §4 lists
that the device offers. The stages communicate through two facts only:
whether the application's state is dirty, meaning it differs from what the
last frame showed, and when the next frame must start. Starting late never
delays a frame's display: the start is computed back from the earliest
refresh the frame can still reach.

The target is Linux on Wayland with Vulkan, on a kernel with io_uring
multishot reads (6.7 or later). The page names the fallbacks for older
kernels and drivers; each delivers the same bytes in the same order, only
with more system calls or later.
X11, Win32, AppKit and Android keep their pacing, specified elsewhere
([WSI §4.4](../window-system-integration/SPEC.md#44-pacing)). Tearing
presentation, a parser on its own thread, and measurement with a camera are
out of scope; the decisions section records each with the evidence that
would reopen it.

§1 defines the vocabulary. §2 specifies ingest, §3 frame scheduling, §4 the
present path, and §5 the measurement. §6 records the decisions and their
evidence, §7 the delivery slices, §8 the evidence ledger, and §9 the open
questions.

### The contract at a glance

1. The bytes a source delivers reach its sink in order, exactly once,
   whatever path read them.
2. No byte waits for a frame to be read.
3. A loop turn ingests a bounded amount; the rest waits in buffers whose
   total is bounded, and the producer is throttled by the kernel, never by
   data loss.
4. A frame starts no earlier than the next reachable refresh requires, and
   never later.
5. The loop thread never blocks on a present on Wayland.
6. Every enabled timing source reports in `MonoTime`, and every latency the
   page claims is measured from the producer's `write` to a reported
   presentation time.

## 1. Model

A **stream source** is a readable, non-blocking file descriptor whose bytes
an application consumes in order, such as a pty master. The application
registers it with the host together with a **sink**: the two callbacks that
receive its bytes and its end. The host owns the reading; the application
owns the descriptor and closes it after closing the source.

**Ingest** is the delivery of bytes to a sink. A **loop turn** is one pass
of the native loop's event loop (`tickNative`): it waits for at most a
timeout and dispatches every completion that is ready. The **ingest budget**
`B` is the number of bytes the host delivers to all sinks during one loop
turn. Bytes read but not yet delivered are **pending**.

A **frame opportunity** is the window system's signal that a new frame may
be committed. On Wayland it is the surface's frame callback
([WSI §4.4](../window-system-integration/SPEC.md#44-pacing)).

The **presentation time** of a frame is when its first pixel was shown,
on `MonoTime`, as reported by the best source available (§4). The **refresh
interval** `T` is the display's period as reported with it; `T = 0` means
unknown or variable.

The **frame cost** `C` of a frame is the time from the start of its frame
pass to the return of its present submission. The **latch deadline** `D` of
a refresh at predicted presentation time `P` is `P − C₉₅ − M`, where `C₉₅`
is the 95th percentile of recent frame costs and `M` the **compositor
margin**: the time the compositor needs between a commit and that refresh.

The **write-to-photon latency** of a byte is the time from the producer's
`write` that contained it to the presentation time of the first frame whose
state included it. A frame **includes** a byte when the stream position
delivered before the frame pass started is past the byte's offset.

## 2. Ingest

The ingest mechanism, OPL1–OPL11, is owned by `sparkles:event-horizon`: it
needs nothing but the event loop, and a component that reads a stream names
its types without depending on a host. The native host of `sparkles:ui-app`
owns its use: the budget, the turn it starts before each wait of the loop,
and the frame pass a delivery asks for (OPL12). A component reaches the
host's stream sources by introspection, as it reaches `spawnDaemon`
([`HST15`](./feature-requirements.md)); a host without them leaves the
component on its polled path.

**OPL1: Ingest on arrival.** Bytes that become readable on an open stream
source **must** be delivered to its sink during the loop turn that observes
them, subject to OPL5, whether or not a frame pass runs in that turn.

_Rationale:_ Reading in the frame pass is what limits throughput to one pty
buffer per refresh; the feasibility measurement in §6 found nine times the
throughput when reading on arrival.

**OPL2: Kernel-filled buffers.** Where the event loop reports multishot
reads (OPL10), the host **must** keep one multishot read armed per source
over a provided buffer ring of `N` buffers of `S` bytes each, and deliver
each completion's bytes from the buffer the kernel chose. The defaults are
`N = 64` and `S = 16 KiB`. A completion that ends the multishot read without
ending the stream (`-ENOBUFS`, or a final completion with bytes) **must** be
followed by a new read once a buffer is free.

**OPL3: Fallback without multishot reads.** Where multishot reads are absent
or refused for the descriptor, the host **must** keep a multishot readiness
poll armed for it and read with `read(2)` into a host buffer. It **must**
continue reading a source it stopped reading for budget in a later turn
without waiting for a new readiness edge. Where multishot polls are also
absent, the host uses one-shot polls re-armed after each edge.

**OPL4: Order and exactly once.** A sink **must** receive the source's bytes
in stream order, each byte exactly once, across re-arms, budget deferral,
fallback, and flushes.

**OPL5: Bounded work per turn.** The host **must** deliver at most `B` bytes
per loop turn across all sources, round-robin between sources with pending
bytes; the default is `B = 256 KiB`. Bytes beyond the budget stay pending,
are delivered before any byte read later, and **must** cause the next park
to be zero-length while no frame is due.

_Rationale:_ A flood must not delay a due frame by more than the time to
parse `B` bytes. At the 2 ns per byte of the feasibility model, 256 KiB is
half a millisecond.

**OPL6: Bounded memory and backpressure.** A source's pending bytes **must**
never exceed `N × S`. When every buffer is pending, the host **must** stop
reading that source until one is delivered, and the producer is then
throttled by the kernel's own pty or pipe buffer.

**OPL7: Flush.** `flushStream` **must** deliver every pending byte of the
source before it returns, ignoring the budget. It **must not** read the
descriptor: bytes still in the kernel stay there.

_Rationale:_ A terminal encodes a key only after applying the output that
preceded it (`TVW8`'s drain-before-encode); pending bytes are the only ones
that can be out of order with respect to that output.

**OPL8: End of stream.** When the read reports end of file (`0`) or an
error other than `EAGAIN`, `EINTR` and `ENOBUFS`, the host **must** deliver
every byte read before it and then call the sink's end callback exactly
once, with `0` or the error number. A pty master reports its child's exit
as `EIO`. After the end callback the source delivers nothing and holds no
kernel operation.

**OPL9: Close.** After `closeStream` returns, no sink callback for the source
**must** run and its pending bytes are dropped. It **must** cancel the
source's kernel operation; the buffers and the buffer group are released
when the kernel reports that operation ended, and no later than when the
host closes. Closing the host **must** close every source and leave no
kernel operation of theirs in flight.

_Rationale:_ Waiting for the cancellation inside `closeStream` would run
the event loop from inside the application's own code, dispatching
unrelated completions there.

**OPL10: Multishot read.** `sparkles:event-horizon` **must** offer an
operation that reads a descriptor repeatedly into buffers the kernel picks
from a registered provided buffer ring, posting one completion per read
with the byte count, the buffer's id and a flag while further completions
follow. It is present on the io_uring backend where the opcode probe
reports `IORING_OP_READ_MULTISHOT` (Linux 6.7), reported as the capability
`multishotRead`, and absent on the other backends.

**OPL11: A non-blocking descriptor.** A stream source's descriptor **must**
have `O_NONBLOCK` set; `openStream` **must** refuse one without it.

_Rationale:_ A multishot read on a blocking pty master never completes:
the feasibility spike in §6 hung on Linux 6.18 until the master was made
non-blocking.

**OPL12: A delivered byte asks for a frame.** Delivering bytes to a sink
**must** make the next loop decision treat the application as having
received input: a frame pass runs, subject to §3's schedule.

## 3. Frame scheduling

Frame scheduling is owned by the native loop of `sparkles:ui-app`. Its
policy is a pure state machine with time as an input, so its decisions are
testable without a display.

**OPL13: Prediction.** The scheduler **must** predict the next presentation
time from the most recent reported presentation time `S` and refresh
interval `T`: the earliest `P = S + kT` with `k ≥ 1` such that `P − C₉₅ − M`
is not in the past. It **must** take presentation times from the best source
§4 enables, in the order `VK_EXT_present_timing`, Wayland presentation
feedback, `VK_KHR_present_wait2` or `VK_KHR_present_wait` completion.

**OPL14: Late latch.** With a prediction and `T > 0`, a frame pass that is
due because the application is dirty **must** start at the latch deadline
`D` of the predicted refresh, or at once if `D` has passed, and the loop
**must** keep ingesting until then. Where the window system gates frames on
frame opportunities, the pass also waits for one.

**OPL15: Frame cost.** `C₉₅` **must** be computed over the last 64 presented
frames' costs; before 8 frames are known it is the refresh interval's half.

**OPL16: Margin adaptation.** `M` **must** start at 2 ms and adapt to
presentation feedback: a frame shown later than half a refresh after its
target raises `M` by 1 ms, at most to half the refresh interval; 32
consecutive frames shown at their target lower it by 0.25 ms, at least to
0.5 ms.

_Rationale:_ No protocol reports when a compositor latches a commit for a
refresh. Feedback reports whether the frame made the refresh it was aimed
at, which is enough to find the latch point from either side.

**OPL17: Unknown or variable refresh.** Where `T = 0`, or no presentation
time has been reported for 1 s, a dirty frame pass **must** start as soon
as the window system allows, with no latch delay.

**OPL18: Schedule policy.** `RunConfig` **must** offer the policy `late` (the
default) and `asap`; `asap` applies OPL17's rule always.

**OPL19: Feedback when scheduling late.** Under the `late` policy the native
arm **must** request a presentation time for every presented frame from the
best source, whether or not frame statistics are recorded.

## 4. The present path

The device and swapchain obligations are owned by `sparkles:vulkan-wsi`;
their use in the frame loop by `sparkles:ui-app`. An extension listed here
is enabled only where the device, and for surface-dependent ones the
surface, reports support; its absence selects the next mechanism, never an
error.

**OPL20: Present identification.** Where the device and surface support
`VK_KHR_present_id2` and `VK_KHR_present_wait2`, the swapchain **must** be
created for them and every present **must** carry an id through them; else,
where `VK_KHR_present_id` and `VK_KHR_present_wait` are present, through
those. Ids are strictly increasing per swapchain.

**OPL21: Non-blocking completion.** On a window system with frame
opportunities the loop **must** learn of present completion only by polling
with a zero timeout, after a frame pass and after each loop turn. The
blocking wait that paces X11 is outside this page.

**OPL22: Present timing.** Where the device and surface support
`VK_EXT_present_timing` with a time domain on `CLOCK_MONOTONIC`, the
presenter **must** size the swapchain's timing queue to at least the frames
in flight plus one, request the first-pixel-visible stage for every present
(first-pixel-out where visible is not offered), and read the results
without blocking. A present aimed at a predicted refresh **must** carry it
as an absolute target time where `presentAtAbsoluteTime` is supported.
Results in another time domain are not used.

**OPL23: Present-mode switching.** Where `VK_EXT_swapchain_maintenance1`
(or `VK_KHR_swapchain_maintenance1`) and `VK_EXT_surface_maintenance1` (or
`VK_KHR_surface_maintenance1`) are supported, the swapchain **must** be
created with every present mode the surface reports compatible with the
chosen one, and a present-mode change between compatible modes **must** take
effect on the next present without recreating the swapchain.

**OPL24: Reported capabilities.** The native arm **must** log, once per
device, which of the mechanisms in OPL20, OPL22 and OPL23 it enabled, and
which present-time source OPL13 selected.

## 5. Measurement

**OPL25: Stream positions in the frame record.** Each frame record **must**
carry the total number of bytes delivered to sinks before its frame pass
started, so a byte offset maps to the first frame that included it.

**OPL26: Latency probe.** `terminal-benchmark` **must** offer a `latency`
scenario: a probe child writes records of 1 to 64 bytes at random intervals
of 1 to 50 ms, logging each write's offset and `MonoTime`. The terminal
writes its frame records, and the harness joins the two into the
distribution of write-to-photon latency, reporting its 50th, 95th and 99th
percentiles and the share of writes whose frame was never shown.

**OPL27: Throughput scenario.** `terminal-benchmark` **must** offer a
`throughput` scenario that times `seq 1 2000000` from the child's start to
its exit inside the terminal.

### Performance targets

The targets apply to the reference configuration: Linux 6.18, GNOME Shell
49.4 on Wayland, Mesa 25.2.6 RADV on an AMD Radeon RX 9070 XT, 60 Hz.

- **Throughput** is a hard target: `seq 1 2000000` **must** complete no
  slower than the pre-1.0 libghostty-vt build, 1.6 s on the reference
  configuration, measured by OPL27 with five repetitions.
- **Latency** targets are set from the first baseline OPL26 measures with
  the `asap` policy; §8 records it. The `late` policy **must** lower the
  50th percentile against that baseline and **must not** raise the share of
  writes whose frame was never shown.

## 6. Decisions

**OPLD1: The loop thread ingests (accepted).** The feasibility spike
(§8) flooded a pty with 32 MiB while a
consumer rendered every 16.7 ms with a busy loop of `R` ms and parsed at
2 ns per byte. At `R = 4 ms`, frame-driven reads moved 2.4 MB/s; a
multishot read handled as completions arrive moved 22.5 MB/s with
`DEFER_TASKRUN`, 22.9 MB/s with `COOP_TASKRUN` and 21.0 MB/s with `SQPOLL`; a
reader thread moved 28.5 MB/s, the pty's ceiling with no rendering. At
`R = 12 ms` every ring mode fell to about 8.5 MB/s, while the reader thread
kept 27.4 MB/s. The kernel performs no reads while the loop thread computes,
in any ring mode. We ingest on the loop thread because it captures most of
the gain without a second thread touching the terminal state, and keep the
loop's ring mode. Revisit when a measured frame cost under a flood exceeds a
quarter of the refresh interval: the next design is a reader thread filling
the provided buffers, with the loop thread still parsing.

**OPLD2: Tearing presentation (deferred).** `wp_tearing_control_v1` with an
immediate present mode removes the wait for a refresh, but GNOME Shell 49.4
offers no such global, and torn text is a visible defect. Revisit with a
compositor that offers it, as an opt-in policy.

**OPLD3: Variable refresh (accepted as OPL17).** Under variable refresh a
commit starts a refresh, so the lowest latency comes from presenting as
soon as a frame is ready. Wayland's presentation feedback reports
`refresh = 0` when the interval is unknown, which OPL17 treats as variable.

## 7. Delivery

Each slice is one or more commits, each green on its own.

| Slice | Obligations      | Deliverable                                                            | Acceptance                                                                          |
| ----- | ---------------- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| L1    | OPL10            | `OpReadMultishot` and the `multishotRead` capability                   | a pipe read through a 4-buffer ring: ids, `more`, `-ENOBUFS`, end of file           |
| L2    | OPL1–OPL9, OPL11 | the host's stream sources, both read paths                             | pipe tests per obligation, run on the multishot path and with it hidden             |
| L3    | OPL12, OPL25     | the terminal view reads its pty as a stream source; stream positions   | `dub test :terminal-view`; OPL27 on the reference configuration                     |
| L4    | OPL26, OPL27     | the `latency` and `throughput` scenarios                               | the baseline recorded in §8                                                         |
| L5    | OPL13–OPL19      | the scheduler, as a pure state machine, and its use in the native loop | scripted traces for prediction, latch, adaptation and variable refresh; OPL26 vs §8 |
| L6    | OPL20–OPL24      | `present_id2`/`present_wait2`, swapchain maintenance, present timing   | per-extension tests where the driver offers it; capability log                      |

## 8. Evidence

The decision OPLD1 rests on [`ingest-spike.c`](./output-latency/ingest-spike.c),
run on the reference configuration as its header describes; §6 gives its
figures.

| Obligation        | Status      | Evidence                                                                                                                                                             |
| ----------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OPL10             | verified    | `OpReadMultishot`, `loop.readMultishot.streamsIntoProvidedBuffers` (Linux 6.18)                                                                                      |
| OPL1–OPL9, OPL11  | verified    | `StreamIngest`; the `stream_ingest.*` tests, each on the multishot path and the fallback (Linux 6.18)                                                                |
| OPL12             | partial     | `NativeHost.openStream`; the terminal reads its pty through it (`TerminalView.startReading`). No test drives a delivery to a frame pass headless                     |
| Throughput target | verified    | `throughput` on the reference configuration, five runs each: this arm 788–959 ms; the pre-1.0 build 1075–2320 ms; frame-driven reads woken by readiness 1971–3230 ms |
| OPL25             | verified    | `FrameRecord.streamPosition`, written by `--debug latency-log`; on the reference configuration a probe's 9942 bytes ended at stream position 9942                    |
| OPL26             | verified    | `joinLatency`, `bench.joinLatency.firstCoveringShownFrame`, `bench.joinLatency.supersededAndNeverShown`; the baseline below                                          |
| OPL27             | verified    | `runThroughput`; the figures above                                                                                                                                   |
| OPL13–OPL24       | not started | none                                                                                                                                                                 |

The latency baseline, the `asap` behaviour: `latency` on the reference
configuration, three runs of 300 writes, measured the 50th percentile at
20.5–22.4 ms, the 95th at 36.9–37.9 ms and the 99th at 40.4–44.7 ms, with
no write unshown and one superseded. Frames took 20.4 ms on average from the
start of their pass to their display.

## 9. Open questions

- **Q1: Present timing on the reference driver.** Mesa 25.2.6 RADV does not
  offer `VK_EXT_present_timing`, so OPL22 cannot be verified on the
  reference configuration. It blocks OPL22's verification, not L6's other
  obligations.
- **Q2: The compositor's latch point.** OPL16 assumes a compositor latches
  commits a roughly constant time before each refresh. Mutter adjusts its
  own deadline to its measured render time. If L5's traces show `M`
  oscillating, the scheduler needs a slower adaptation; L5's acceptance
  decides.
