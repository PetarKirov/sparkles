# A measured path to 120 fps font previews

The Android preview currently needs CPU work removed from the frame path.
A 120 Hz frame has 8.33 ms available. Even a warm, unchanged font exceeds that
budget because the specimen is shaped again on every redraw. Changing size
and axes adds rasterization and produces much larger tails. GPU execution is
below the budget in these measurements; it still needs headroom before more
work is moved there.

This is a profiling report and proposed implementation order, not a claim
that the [font preview](../../../specs/ui-app/font-preview.md) meets 120 fps.

## Measurement conditions

The baseline is commit `2bedc4e08e9557c5459397595c5e94f16d6662f0`, built with
LDC 1.43 in `checked` mode. The device was a Xiaomi 11T Pro (`2107113SG`),
Android 14, at 1080 × 2400 in the display's 120 Hz mode. The specimen was the
bundled Noto Sans. The interface used its stable font except in the explicit
UI-follow workload. The loupe was disabled.

The investigation used three complementary measurements:

- An unmodified-APK `simpleperf` capture: `cpu-clock:u`, 1000 Hz, DWARF call
  chains, 12 seconds of repeated ADB weight drags. It recorded 9,178 samples
  with none lost; 8,138 belonged to the native render thread.
- Temporary CPU scopes and the host's existing frame trace and Vulkan
  timestamp queries. Nine workloads ran three times, in different orders.
  Each ran 420 automatic updates; discarding the first 60 recorded passes
  left 363 CPU and 361 GPU records per run. Size varied from 8 to 32 pt;
  weight varied over its declared domain; the combined workload varied size
  and both declared axes. Frozen controls requested redraws without changing
  the font, so they measured rendering rather than idle skipping.
- Perfetto scheduler/frequency traces, including a capture correlated with
  the temporary scope timestamps. GPU timestamps were not calibrated to the
  host clock: their elapsed durations are usable, but they do not establish
  input-to-display latency.

CPU-side frame time below is elapsed time through build, drawing, submission,
and present. Nested scope times overlap and must not be added. CPU and GPU
also overlap. Instrumentation overhead was not subtracted. These scripted
sweeps differ from the earlier short, externally driven weight-drag samples.

The phone reported 15% battery, 50°C battery temperature, and Android thermal
status 0. Clock and placement conditions were not fixed: one trace observed
CPU 7 between 0.845 and 1.306 GHz; a sysfs inspection reported a 1.670 GHz
scaling ceiling versus a 2.842 GHz hardware maximum. CPU time varied markedly
between repetitions. These observations do not establish why that policy was
in effect. Report ranges rather than treating cross-run differences as clean
causal speedups, and validate the implementation in both cooler and sustained
operating conditions without bypassing thermal controls.

## Results

Ranges below are the minimum and maximum across the three repetitions, not
confidence intervals. The GPU column is the largest per-run p95.

| Workload                  | CPU-side mean range | CPU-side p95 range | GPU p95 maximum |
| ------------------------- | ------------------: | -----------------: | --------------: |
| Frozen font, sheet closed |       7.23–18.76 ms |     11.37–32.34 ms |         3.37 ms |
| Frozen font, sheet open   |       9.89–19.62 ms |     14.40–37.29 ms |         4.38 ms |
| Weight, sheet open        |      15.56–24.76 ms |     22.31–47.14 ms |         5.44 ms |
| Size, sheet open          |      16.74–23.03 ms |     32.13–46.55 ms |         5.62 ms |
| Size + axes, sheet open   |      18.63–27.22 ms |     39.40–50.08 ms |         5.65 ms |
| Size + axes, UI follows   |      23.90–26.17 ms |     46.69–50.36 ms |         5.35 ms |

The per-run summary, checked in at
`docs/public/profiles/text-lab-120fps-summary.csv`, includes all scopes, native
phases, and the unshaped/unhinted diagnostic controls. Disabling
shaping changes layout and fallback behavior; those controls are not proposed
optimizations or clean, geometry-preserving A/B comparisons. Scope call counts
apply to the `*_ns` rows; other rows use zero for that unrecorded field.

A correlated frozen-font run measured 9.710 ms per frame, of which scheduler
slices show 9.663 ms actually running on CPU. Runnable waiting was about
0.031 ms, sleeping 0.010 ms, and uninterruptible waiting 0.006 ms. The render
thread ran mainly on CPUs 4–6 in that capture. The warm path therefore already
needs less computation, independently of presentation pacing.

### Where the work goes

In the first frozen-font, sheet-open run, specimen painting averaged 6.83 ms
and settings drawing 1.90 ms. There were **352 natural-width measurements and
351 natural draws per frame**, across two specimen panels. Width measurement
averaged 3.13 ms and natural drawing 3.30 ms, despite zero coverage-atlas
misses after warmup. The natural painter shapes once to measure a token and
again to draw it; the dark and light panels repeat the same text.

In the first weight sweep, specimen painting averaged 12.12 ms. Width
measurement used 4.52 ms, natural drawing 7.22 ms, and coverage-atlas misses
3.56 ms inside that drawing work, with about 91 miss-path calls per frame.
Settings used 1.53 ms. Preparing the instance used 0.038 ms and binding it
0.185 ms; atlas staging used 0.296 ms. Warm file loading is not the present
bottleneck.

The independent sampling capture supports that attribution. Inclusive shares
of **all app CPU samples** were specimen painting 69.6%, shaping 34.1%,
coverage-atlas lookup/rasterization 26.5%, settings drawing 9.3%, and atlas
staging 2.1%. They overlap. `Face.record` alone had 7.5% self time. HarfBuzz's
advance callback reaches `advance`, which constructs `AdvanceSource` and reads
`hmtx`/`HVAR` views repeatedly. This makes cached metric sources a concrete
candidate, rather than a reason to change compiler flags.

The code also paints both complete specimen panels before the opaque sheet,
and the atlas starts over wholesale when full. Occlusion work and atlas reset
frequency need explicit counters in the next experiments; this investigation
does not assign them an unmeasured saving.

## Proposed implementation order

Each step should have a separate measured before/after result. The following
budgets are targets, not predicted speedups.

1. **Keep a reproducible device gate.** Add a supported Android profiling entry
   for the deterministic workloads and retain generation, CPU-phase, GPU,
   atlas-miss/reset, upload-byte, allocation, and presentation measurements.
   Correlate submitted font generations with actual compositor presents where
   supported. Include prepared face switching as its own workload; the
   current timed matrix isolates size and axes, not that case.
2. **Prepare text once and reuse it.** Introduce a bounded prepared-run seam
   carrying glyph IDs, selected fallback face, advances, offsets, and width.
   Measure and draw consume that result. Reuse it across the dark/light
   panels and across unchanged frames; avoid shaping repeated spaces and
   identical tokens again. Keys include exact face identity, normalized
   coordinates, size, text, style, direction/features, and fallback-set
   identity. Variation-sensitive layout must invalidate correctly. Keep
   foreground-dependent color rasterization separate from layout caching.
   First gate: unchanged-font redraws fit 8.33 ms at p99 before proceeding.
3. **Cache metric sources and remove redundant glyph preparation.** Retain
   parsed `hmtx`/`HVAR` views per face and evaluated variation data per
   instance, so advance callbacks do not reconstruct them for every glyph.
   Inspect the measure/raster path for repeated outline expansion and
   hinting, and prepare those once where contracts permit. Preserve checked
   arithmetic, malformed-font errors, shaping, and the selected hinting mode.
   Optimize `Face.record` only as part of this measured path: its 7.5% self
   share alone cannot provide the required reduction.
4. **Avoid work hidden by the controls.** Lay out the overlay before specimen
   painting and cull regions it fully covers. Cache the stable settings tree,
   layout, and display-list portions; update active values without rebuilding
   every unchanged row. Cache invalidation includes viewport, theme, focus,
   visibility, subject identity, and UI-font generation. Preserve captured
   slider geometry, undo, and the UI-follow behavior. Target settings work
   below 0.5 ms at p95 in stable-UI mode; remeasure UI-follow separately.
   Put this reuse in the shared settings components so the terminal benefits
   without growing another renderer.
5. **Batch CPU glyph jobs through Event Horizon.** Once the frame has a
   prepared run, collect its unique misses and submit bounded batches to
   `RawCpuPool`. Compare 1/2/3/4 workers on this phone instead of equating
   logical CPUs with useful parallelism. Each worker owns raster/outline
   scratch and produces immutable tiles; font bytes and instance data stay
   pinned. The renderer owns atlas placement and upload. Bound pending work,
   coalesce superseded requests, and commit coherent generations. Separate
   persistent interface/fallback pages from specimen churn and measure page
   eviction against the current whole-atlas reset. Do not grow a cache
   without a memory bound or trade deadline misses for an unbounded queue.
6. **Prototype GPU coverage rasterization if CPU misses still exceed budget.**
   Use the existing `libs/shaders` build path to rasterize prepared outlines
   into atlas tiles. Measure the combined upload, compute, and render cost:
   a current GPU p95 of 5.65 ms leaves only 2.68 ms before the refresh budget.
   Compare coverage, hinting, variable outlines, color/fallback behavior, and
   compositing against the CPU oracle with GPU readback tests. Retain a CPU
   fallback for unsupported paths. Adopt the prototype only if it improves
   the measured critical path; also measure staging-buffer reuse and merged
   dirty regions if upload tails remain significant.
7. **Tune pacing after computation fits.** Revisit callback lead time,
   frames in flight, and event draining with the scheduler/presentation
   trace. Current fence wait and acquire times are small, so there is no
   evidence for starting with a swapchain rewrite. Avoid deeper queues that
   improve swap throughput while the displayed font falls behind input.

## Delivery gate

Use 120 distinct prepared font configurations per second, not merely 120
swaps of an unchanged specimen. Proposed CPU-side budgets are p95 ≤6 ms and
p99 ≤7.5 ms; use the same GPU budgets so neither side consumes all 8.33 ms.
Validate the actual presentation cadence separately: at least 99% of fresh
frames within 1.1 refresh intervals, no unexplained gap above two intervals,
and generation latency reported alongside throughput.

Run three ten-second measurements after warmup for fixed-font redraw, size,
weight, combined axes/size, and prepared face switching, with controls closed,
open, and UI-follow enabled. Include multilingual text, fallback glyphs,
changing cache contents, and sustained temperature/clock conditions. Keep
startup and cold-face latency as separate async-loading results. Preserve the
pixel/readback and interaction tests; scaled bitmap previews, disabled
shaping, and stale generations do not satisfy this gate.

All temporary instrumentation was removed after this investigation, and the
validated normal APK was restored on the device. No performance optimization
from this plan has been implemented by the profiling pass.
