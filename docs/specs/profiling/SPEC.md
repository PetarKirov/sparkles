---
status: draft
owner: sparkles:profiling
reviewed: 2026-11-02
---

# `sparkles:profiling` — Frame statistics and profiling

## Abstract

`sparkles:profiling` records what each frame of an interactive program did and
how long it took, and reduces a run to the figures a game engine is judged by:
frame-time percentiles, the slowest one percent, hitches measured against the
display's refresh, and the cause of each hitch. On top of it,
`sparkles:vulkan-wsi` times the device's work in named scopes, learns when a
frame reached the display, reads the device's memory budget and its pipeline
compilations, and the native arm of `sparkles:ui-app` exports a run as a trace
that standard tools open. Recording costs a fixed amount of memory, allocates
nothing per frame and never waits on the device.

## Introduction

A frame-time mean and a maximum say little about how a program feels. A run
whose mean is 4 ms can stutter every second; a run whose slowest frame is
80 ms may have had that frame once, while its window was being created. What
an engine developer asks of a run is a distribution (how slow is the slowest
one percent?), a reference (did a frame miss the display's refresh, and by how
many?), a cause (was the slow frame a swapchain rebuild, a pipeline compile, or
the application's own work?), and the device's side of the story (did the GPU
take the time, or the CPU, and when did the image actually appear?).

The repository's programs measured frames before this library, each in its own
way: the Vulkan triangles kept counters by hand, then a shared `FrameStats`
with a mean, a maximum and two fixed thresholds; the native arm kept a
per-phase `FrameTiming` and a private GPU timer, printed as trace lines. None
kept a history, none attributed a slow frame to its cause, and none could be
opened in a profiler.

The approach separates what is CPU-only and portable from what needs a GPU.
`sparkles:profiling` depends on `sparkles:base` alone, so the Vulkan, raylib
and terminal arms can all record into it: a frame record, a fixed-size history
of them, a log-scaled histogram, the run's statistics, and the exports.
`sparkles:vulkan-wsi` fills the device-side fields — GPU scopes, calibrated
timestamps, presentation times, the memory budget — where the driver supports
each, and says where it does not. The native arm wires both to `--debug`
switches.

This specification does not cover a sampling CPU profiler, allocation
tracking, or an in-application flame graph; `perf`, Tracy and the operating
system's tools do those better. It promises no particular accuracy for a
driver's timestamps beyond what the driver reports.

## The contract at a glance

1. A frame is one fixed-size record: its number, its start, its CPU phases,
   its GPU scopes, and flags for what happened in it.
2. A history keeps the last N records in a ring; nothing allocates per frame.
3. A run's statistics are a distribution — percentiles, the 1% low, variance
   — and hitches counted against the refresh interval, each attributed to its
   frame's flags.
4. The device's time is measured in named scopes, read frames late so nothing
   waits, and placed on the CPU's timeline where the driver allows.
5. When a frame reached the display is recorded where the platform reports it.
6. A run exports as one summary line, as JSON, and as a Chrome trace.
7. Every device-side measurement says whether the driver supports it.

## Records and history

**PRF1: The frame record.** `FrameRecord` **must** hold, without indirection:
the frame's number (monotonic over the run, `ulong`); its start, as a
`MonoTime`-derived offset from the run's origin; the CPU duration of each
phase of `FramePhase` (`wait`, `build`, `acquire`, `record`, `submit`,
`present`, `rebuild`); its total CPU time; up to `maxGpuScopes` (16) GPU
scopes, each a name index, a start and a duration; its CPU zones' times
(`PRF22`); and `FrameFlags`. A record **must** be copyable, `@safe pure nothrow
@nogc` to fill, and at most 768 bytes.

**PRF2: Frame flags.** `FrameFlags` **must** be a bit set with at least
`rebuilt` (the swapchain was rebuilt before the frame), `suboptimal`,
`outOfDate`, `skipped` (built, not presented), `pipelineCompiled` (a pipeline
was compiled during the frame), `deviceLost`, and `firstFrame`. A record **may**
carry several.

**PRF3: The history.** `FrameHistory!N` **must** keep the last `N` records in a
ring of fixed capacity, overwrite the oldest when full, iterate oldest to
newest, and report how many records it ever saw. Adding a record **must not**
allocate.

**PRF4: An injectable clock.** Timing **must** go through a clock the caller
can replace (`FrameClock`), so a test gives exact durations and checks exact
results; the default clock is `MonoTime`.

## Statistics

**PRF5: The histogram.** `FrameHistogram` **must** count durations in
logarithmic bins from 0.1 ms to 1 s, 64 bins per decade, with an underflow and
an overflow bin. A percentile read from it **must** be within one bin's width
(3.7 %) of the exact percentile of the same samples. Outside
the range a percentile **must** read as the extreme seen: the slowest
frame for the overflow bin, the fastest for the underflow one.

**PRF6: Run statistics.** `FrameStats` **must** report: the frames counted, the
mean, the slowest, the variance (by Welford's method, so a long run loses no
precision), the 50th, 95th and 99th percentiles, and the "1% low": the frame
rate of the mean of the slowest one percent of frames. A frame is noted in
constant time.

**PRF7: Hitches against the refresh.** `FrameStats` **must** take a refresh
interval (by default 1/60 s; a caller that knows the display's sets it) and
count a frame as a hitch when it takes more than 1.5 intervals, and the
refreshes it missed as `ceil(took / interval) - 1`. The fixed 50 ms and 100 ms
counts **must** remain, as lanes check them.

**PRF8: Hitch attribution.** For each hitch, `FrameStats` **must** count which
of its frame's flags were set, so a summary says how many hitches came with a
rebuild, a pipeline compile, a first frame, or none of these.

**PRF9: The summary line.** `FrameStats` **must** write a one-line summary
through any output range, keeping the existing prefix (`N frames: mean …,
slowest …, K over 50 ms, L over 100 ms`) and appending the percentiles, the 1%
low and the attributed hitches.

## Device timing

**PRF10: GPU scopes.** `sparkles:vulkan-wsi` **must** provide `GpuProfiler`,
which times named scopes of a frame's command buffer with timestamp queries:
one query pool per frame slot, up to `maxGpuScopes` scopes per frame, nested or
sequential. A slot's results **must** be read when the slot comes round again,
after its fence, so reading never waits. A queue whose timestamps carry no valid
bits **must** yield no scopes and say so; the counter's wrap **must** be honoured
(the valid-bits mask).

**PRF11: Calibration.** Where `VK_KHR_calibrated_timestamps` (or the EXT) is
present, `GpuProfiler` **must** convert a scope's GPU timestamps to the CPU's
monotonic timeline, recalibrating at most once a second; where it is absent, a
scope keeps its duration and has no CPU-timeline start.

**PRF12: Labels for external tools.** Where `VK_EXT_debug_utils` is enabled, a
GPU scope **must** also be a debug label in the command buffer, so RenderDoc,
Nsight and RGP show the same structure.

**PRF13: Presentation time.** Where the device has `VK_KHR_present_id` and
`VK_KHR_present_wait`, the presenter **must** tag each present with the frame's
number and learn, without blocking the frame, when it completed. On Wayland,
`sparkles:wsi` **must** offer `wp_presentation` feedback for a window's next
commit, delivered as an event carrying the time it was shown, the refresh
interval and whether it was zero-copy. A record **must** keep the time its
frame was shown, where known.

**PRF14: Latency and refresh.** Where presentation times are known, the
statistics **must** report the time from a frame's start to its display, and
use the reported refresh interval for `PRF7` instead of the default.

## Resources

**PRF15: Memory budget.** Where `VK_EXT_memory_budget` is present, the native
arm **must** read each heap's budget and usage at most once a second and report
the peak.

**PRF16: Pipeline compiles.** Each pipeline creation **must** report whether it
was compiled or found in the cache (pipeline creation feedback), and set
`pipelineCompiled` on the frame it happened in.

## Exports

**PRF17: JSON.** `FrameStats` **must** be expressible as a plain struct of
numbers (`FrameSummary`) that `sparkles:wired` serializes without custom code.

**PRF18: Chrome trace.** A history **must** export as Chrome trace event JSON
(the format Perfetto and `chrome://tracing` open): one track for CPU phases,
one for GPU scopes (on the CPU timeline where calibrated), and instant events
for the flags, written through any output range.

**PRF19: Native arm switches.** The native arm **must** expose `--debug
frame-trace=PATH` (write the Chrome trace at exit), `gpu-timing` (measure GPU
scopes), and print the extended summary under any frame switch.

**PRF20: Tracy, optional.** With `version (SparklesTracy)`, frame marks and
CPU zones **may** be sent to Tracy; without it, nothing of Tracy is compiled.

**PRF22: CPU zones.** `cpuZone!"name"` **must** time the rest of its scope and
add it, by name, to the frame the calling thread is recording; on another
thread, or between frames, it **must** add nothing. A frame **must** keep up to
`maxCpuZones` (16) names' summed times and entry counts, and `ZoneStats` **must**
summarize each name's mean and 95th percentile over the frames that entered it.
The native arm **must** print that summary under any frame switch. Zones
**must** allocate nothing, and with `PRF20`'s version each is a Tracy zone too.

## Overhead

**PRF21: Cost.** Recording a frame **must** cost under 0.05 ms of CPU on the
development machine, allocate nothing, and never wait on the device. A
benchmark **must** measure it.

## Decisions

**A package of its own.** The statistics need no GPU, and the raylib and
terminal arms draw frames too; putting them in `sparkles:vulkan-wsi` would tie
them to Vulkan. `sparkles:profiling` depends on `sparkles:base` only.

**A histogram, not a sorted sample.** Exact percentiles need every sample, and
a long run has millions. A log-scaled histogram is fixed-size, constant-time to
update, and accurate to a bin's width, which at 3.7 % is finer than the
run-to-run noise of a frame time.

**Hitches by the refresh, not by fixed milliseconds.** 50 ms means nothing on a
120 Hz display, where a hitch is anything past 12.5 ms. The fixed counts stay
only because existing lanes check them.

**Read late, never wait.** Reading a timestamp query or a present wait at once
would serialize the CPU and the GPU — exactly the stall being measured.

**JSON through a plain struct.** `sparkles:profiling` stays free of
`sparkles:wired`; a caller that wants JSON serializes `FrameSummary`.

**Tracy by a version, not a switch.** A runtime switch would link Tracy's
client into every build, and the client listens on a port from the moment the
program starts. Behind `version (SparklesTracy)`, set by `sparkles:profiling`'s
`tracy` configuration, a build that does not opt in compiles no Tracy code and
names no Tracy symbol, and `sparkles:profiling` still depends on
`sparkles:base` alone; the API stays callable either way, so callers need no
`version` blocks. The zones are the phases `FrameRecord` already laps, so
Tracy and the frame trace (`PRF18`) show the same structure.

## Evidence

| ID         | Status   | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Gap                                                                                                                                                                                                                        |
| ---------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PRF1, PRF2 | verified | `FrameRecord`, `FrameFlags` (a static assert bounds the size); `profiling.frame.timerLapsPhases`, `profiling.frame.latencyAndScopes`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | —                                                                                                                                                                                                                          |
| PRF3       | verified | `FrameHistory`; `profiling.history.keepsTheNewest`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | —                                                                                                                                                                                                                          |
| PRF4       | verified | `FrameClock`, `FrameTimer`; `profiling.frame.timerLapsPhases` runs on a test clock                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  | —                                                                                                                                                                                                                          |
| PRF5       | verified | `FrameHistogram`; `profiling.histogram.percentilesWithinABin` (p50, p95, p99 of 1–1000 ms within half a bin)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | —                                                                                                                                                                                                                          |
| PRF6–PRF9  | verified | `FrameStats`; `profiling.stats.notesAndWrites`, `profiling.stats.hitchesFollowTheRefresh`, `profiling.stats.varianceAndLatency`; the Wayland triangle lane's line                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | —                                                                                                                                                                                                                          |
| PRF10      | verified | `GpuProfiler`, `VulkanDevice.timestampValidBits`; `vulkan_wsi.gpu_profiler.nestedScopesReadLate`, `vulkan_wsi.gpu_profiler.unendedAndExcessScopes`, `vulkan_wsi.gpu_profiler.validBitsWrap`, `vulkan_wsi.gpu_profiler.unsupportedQueueDoesNothing`; the Wayland triangle lane's `gpuFrames` line (lavapipe)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         | —                                                                                                                                                                                                                          |
| PRF11      | verified | `GpuProfiler.collect`, `onCpuTimeline`, `VulkanDevice.calibratedTimestamps`, `planCalibration`; `vulkan_wsi.gpu_profiler.calibratedConversion`, `vulkan_wsi.gpu_profiler.calibratedStartsAndLabels`, `vulkan_wsi.device.calibrationNeedsBothClocks`; the lane's `gpuLagMinMs`/`gpuLagMaxMs` (lavapipe, the EXT)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | Windows' `QueryPerformanceCounter` domain untested                                                                                                                                                                         |
| PRF12      | partial  | `GpuProfiler.begin` labels each scope where `VulkanDevice.debugUtils`; `ContextRequest.debugLabels`; `vulkan_wsi.gpu_profiler.calibratedStartsAndLabels`; the lane reports `labels`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | no capture in RenderDoc, Nsight or RGP has shown them                                                                                                                                                                      |
| PRF13      | partial  | `WaylandWsi.requestPresentationFeedback`, `PresentedEvent`; `wsi.events.presentedEventReadsItsTimes`, `wsi.wayland.presentationTimesAreOnMonoTime`, and `libs/wsi/scripts/verify-wayland-weston.sh` (a commit presented, one superseded, one discarded with its window, on headless Weston); `VulkanDevice.presentWait`, `PresentWait`, `pollCompleted`; `vulkan_wsi.presenter.presentsCarryIdsAndCompleteWithoutWaiting`; `DisplayTimes` (`VK_GOOGLE_display_timing`), `vulkan_wsi.display_timing.pollReadsEveryBatchAndTheRefresh`; the native arm takes display times from the device where the window system gives none (`onShown`); text-lab on a Moto e13 (Mali, 60 Hz): 287 of 300 frames shown, latency 53.1 ms mean; on a Xiaomi Pad (Adreno, 120 Hz): 296 of 300 shown, latency 29.0 ms mean, hitches measured against the reported 8.3 ms refresh; on X11 (XWayland, RADV) through present wait: latency 13.3 ms mean, 23 of 301 unpaced frames shown, each on a refresh | present wait times a present's completion as a poll saw it, an upper bound; unpaced X11 presents several frames a refresh, and keeps eight outstanding, so most frames have no display time; X11 reports no refresh period |
| PRF14      | verified | `FrameRecord.latency`, `FrameStats.meanLatency`, `FrameStats.noteLatency`, `FrameStats.noteRefresh`, `FrameHistory.markShown`; `profiling.stats.varianceAndLatency`, `profiling.stats.lateLatencyAndTheReportedRefresh`, `profiling.history.marksAFrameShownLate`; text-lab on headless Weston: 118 of 120 frames shown, latency 24.5 ms mean, the 60 Hz refresh taken from the compositor                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Wayland only, as `PRF13`                                                                                                                                                                                                   |
| PRF15      | verified | `VulkanDevice.memoryBudget`, `MemoryPeaks`; `vulkan_wsi.memory_budget.keepsThePeak`; text-lab on headless Weston prints its heaps' peaks (lavapipe's one heap is system memory)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | no device with its own memory checked                                                                                                                                                                                      |
| PRF16      | verified | `PipelineCompiles`; `ui_vulkan.pipelines.compilesFollowTheFeedback`; text-lab on Weston attributes its first frame's hitch to `compiled`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | below Vulkan 1.3 a pipeline counts as built                                                                                                                                                                                |
| PRF17      | verified | `FrameSummary`; `profiling.stats.summaryRoundTripsThroughJson` (`sparkles:wired`, no custom code)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | —                                                                                                                                                                                                                          |
| PRF18      | verified | `writeChromeTrace`; `profiling.trace.writesChromeTraceEvents` (parsed back as JSON)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 | —                                                                                                                                                                                                                          |
| PRF19      | verified | `NativeDebug` (`gpu-timing`, `frame-trace`); `writeFrameTrace`; `libs/ui-app/scripts/verify-native-profiling.sh` (text-lab on headless Weston and Xvfb: summaries, GPU scopes, display times, the trace)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | —                                                                                                                                                                                                                          |
| PRF20      | verified | `tracyFrameMark`, `tracyZone`, `TracyZone`, `tracyPlot`, `tracyMessage` (`sparkles.profiling.tracy`, ImportC of TracyC.h); `profiling.tracy.zonesFramesAndPlots`, `profiling.tracy.enabledByTheVersion` under both the `unittest` and `unittest-tracy` configurations; `libs/ui-app/scripts/verify-native-tracy.sh` (text-lab `-c tracy` on headless Weston, captured by `tracy-capture`: 120 frame marks, 120 `frame` zones and their phases, the `frame ms` and `gpu ms` plots); a default build names no Tracy symbol                                                                                                                                                                                                                                                                                                                                                                                                                                                            | GPU scopes reach Tracy as the `gpu ms` plot, not as GPU zones; the native arm only                                                                                                                                         |
| PRF21      | verified | `profiling.recordOneFrame`: 0.33 µs a frame (timer, history and statistics; debug build, the development machine)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | measured on one machine; the native arm's per-frame query read and feedback request are outside the benchmark                                                                                                              |
