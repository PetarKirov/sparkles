# Fused vs separate fit sizing: benchmark notes

The question: Clay computes each element's intrinsic ("fit") size while the
tree is built (`Clay__CloseElement`, clay.h:1867). Is that cheaper end to end
than building the tree first and then running a separate bottom-up pass, which
could read only hot layout data (SoA) and might use SIMD?

Machine: AMD Ryzen 9 7940HX (Zen 4, 32 MB L3 per CCD, AVX-512), Linux 6.18,
pinned to one core with `taskset -c 4`, desktop otherwise idle (load around 2,
mostly a browser). LDC 1.43 (LLVM 24) and DMD 2.115, both from the sparkles
dev shell.

## Code layout

`fitbench.d` is a single file that also works as a `dub --single` recipe.

- **Event stream (`Ev`, 12 B).** This stands in for the user's UI code. It is a
  pre-order list of `open(axis, grow, pad, gap)`, `label(textLen)` and `close`
  events. Every variant replays the same stream, and replaying it is counted as
  part of the build.
  - **`list`:** root col > panel col > (header row, scroll col > N/4 ×
    `row(label, label(grow), label)`). Depth 5, fan-out N/4.
  - **`panels`:** random nested panels. Fan-out is mostly 2–8, about 10 % of
    nodes with a large budget get 50–1000 children, depth is at most 12,
    and the axis and grow flags are random. N is exact.
- **Build.** Each element appends a node in pre-order to a reused, preallocated
  buffer. A stack of `Frame`s supplies the parent index, child count and grow
  count. A label's size is `textLen × 8` by 16, a stand-in for a cached measure.
  - **AoS record `Node!SIZE`:** a 64 B hot head (parent, kind, axis, grow,
    childCount, growCount, gap, pad[2], textLen, sz[2], fit[2], pos[2], text
    ptr) followed by `SIZE - 64` B of payload. The whole record is
    initialised, as `*nd = Node.init` would do it, and an id, a style word and
    a colour are written into the payload. SIZE is 64, 128 or 328 (328 is
    today's `Widget`).
  - **SoA (`Soa!SIZE`):** hot arrays (parent, flags, childCount, growCount, gap,
    pad, sz, fit, pos) plus a cold array (text, len, id, the same payload), so
    the total size per node is the same as the AoS record's.
- **Variants.** Every variant computes identical sizes; this is checked by a
  checksum over the float bits.

  | name         | what                                                                                                                                                                                                                                                                                                     |
  | ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `fused-aos`  | Clay-style but with accumulators: each `Frame` carries sum(main) and max(cross); on close it finalises w and h, writes them into the record, and adds them to the parent's frame                                                                                                                         |
  | `sep-aos`    | plain build, then a reverse pre-order sweep over the fat records: finalise node i, then `sz[parent] += / max=`                                                                                                                                                                                           |
  | `sep-soa`    | SoA build, then the same reverse sweep over the hot arrays only                                                                                                                                                                                                                                          |
  | `fused-soa`  | fused accumulation, writing into the SoA arrays                                                                                                                                                                                                                                                          |
  | `sep-soa-rc` | `sep-soa`, but the current parent's accumulator stays in registers while consecutive nodes share that parent (an experiment)                                                                                                                                                                             |
  | `level-soa`  | SIMD attempt: the build also writes a depth byte; a stable counting sort by depth makes each parent's children contiguous; the arrays are gathered; a bottom-up pass per level does a vectorised `@fastmath` sum/max per parent; the results are scattered back. The "aux" column is the reduction alone |
  | `rest-aos`   | after a fused build+fit (not timed): Clay-style grow pass on x (root 1920), grow pass on y (root 1080), then positions. Each is a forward pre-order sweep that reads the parent. "aux" is grow x+y                                                                                                       |
  | `rest-soa`   | the same three passes on SoA                                                                                                                                                                                                                                                                             |

- **Harness.** 3 warm-up repetitions, then the median of 31 (LDC) or 21 (DMD)
  repetitions, reported in ns per node. Every repetition is a full frame:
  replay, build, fit. Counters come from an in-process `perf_event_open`
  group (user space only), which is snapshotted at phase boundaries outside
  the timed intervals: cycles, instructions, L1D read misses, L2 misses
  (generic `cache-misses`, which on Zen is `l2_cache_req_stat.ic_dc_miss_in_l2`)
  and DRAM fills (raw `ls_any_fills_from_sys.dram_io_all`, 0x4844, prefetch
  fills included). The generic LLC event is not supported on Zen. An external
  `perf stat` run agreed: for panels/10^6/328 B, sep-aos minus fused-aos came
  to about 70 cycles per node both ways.

## Commands

From the repository root (stock compilers suffice):

```bash
nix develop -c bash -c 'cd docs/research/ui-authoring/experiments/layout-fit-bench && \
  ldc2 -O3 -mcpu=native -release -boundscheck=off -of=fitbench-ldc fitbench.d && \
  dmd  -O -release -inline -boundscheck=off      -of=fitbench-dmd fitbench.d && \
  taskset -c 4 ./fitbench-ldc --reps 31 > results-ldc.md && \
  taskset -c 4 ./fitbench-dmd --reps 21 > results-dmd.md'
# or: dub run --single fitbench.d --build=bench --compiler=ldc2 -- [flags]
# flags: --shape list,panels  --n 1000,...  --fat 64,128,328  --variant a,b  --reps R
```

The binaries are git-ignored. `-release` drops the asserts: these are
measurement builds of a program whose correctness check is the checksum every
variant prints, not an assertion.

Files:

- `results-ldc.md` and `results-dmd.md`: full tables with every counter, the
  pass-only counters and the checksums. None of them reports a mismatch.
- `summary-ldc.md` and `summary-dmd.md`: the condensed tables below.

## Results (LDC, ns/node, median)

`total` is build + fit. The value in parentheses is the separate pass alone.
`rest-*` is grow x + grow y + positions, measured on its own.

| shape  |    N | fat B | fused-aos | sep-aos (pass) | fused-soa | sep-soa (pass) | sep-soa-rc pass | level-soa (reduce) | rest-aos | rest-soa |
| ------ | ---: | ----: | --------: | -------------: | --------: | -------------: | --------------: | -----------------: | -------: | -------: |
| list   | 10^3 |    64 |      3.41 |    4.11 (1.70) |      3.91 |    4.81 (1.70) |            2.20 |        9.12 (0.90) |     2.61 |     2.61 |
| list   | 10^3 |   128 |      4.01 |    5.21 (2.40) |      4.91 |    5.81 (1.70) |            2.20 |        9.92 (1.00) |     2.81 |     2.61 |
| list   | 10^3 |   328 |      5.91 |    7.72 (2.51) |      6.51 |    7.62 (1.70) |            2.20 |       11.62 (0.90) |     3.21 |     2.61 |
| list   | 10^4 |    64 |      3.49 |    4.41 (1.79) |      4.19 |    5.06 (1.79) |            2.32 |        9.45 (0.90) |     2.79 |     2.65 |
| list   | 10^4 |   128 |      4.39 |    5.48 (2.12) |      4.94 |    5.90 (1.79) |            2.31 |       10.16 (1.01) |     3.88 |     2.73 |
| list   | 10^4 |   328 |      6.26 |    7.74 (2.29) |      7.58 |    7.83 (1.75) |            2.26 |       11.95 (0.95) |     5.14 |     2.62 |
| list   | 10^5 |    64 |      3.72 |    4.75 (1.98) |      4.36 |    5.37 (1.89) |            2.36 |        9.77 (0.91) |     2.93 |     2.75 |
| list   | 10^5 |   128 |      4.44 |    5.63 (2.13) |      5.20 |    6.22 (1.98) |            2.34 |       10.56 (1.03) |     4.00 |     2.81 |
| list   | 10^5 |   328 |      8.85 |   12.13 (4.07) |      9.57 |   10.65 (1.80) |            2.25 |       15.35 (0.95) |     7.50 |     2.77 |
| list   | 10^6 |    64 |      4.55 |    9.36 (4.27) |      4.92 |    6.57 (1.94) |            2.34 |       11.34 (1.00) |    11.44 |     3.53 |
| list   | 10^6 |   128 |      9.45 |   16.37 (6.66) |      9.15 |   10.42 (2.03) |            2.27 |       15.36 (1.12) |    19.22 |     3.56 |
| list   | 10^6 |   328 |     28.99 |  38.68 (10.57) |     26.80 |   28.02 (2.07) |            2.29 |       32.40 (1.07) |    29.67 |     4.77 |
| panels | 10^3 |    64 |      3.40 |    4.90 (2.50) |      4.00 |    5.40 (2.30) |            2.90 |        9.80 (1.30) |     2.90 |     2.80 |
| panels | 10^3 |   128 |      4.10 |    5.30 (2.50) |      4.90 |    6.30 (2.30) |            2.90 |       10.60 (1.20) |     3.00 |     2.90 |
| panels | 10^3 |   328 |      6.10 |    7.80 (2.50) |      6.60 |    8.10 (2.30) |            2.90 |       12.40 (1.20) |     3.20 |     2.80 |
| panels | 10^4 |    64 |      3.42 |    4.97 (2.54) |      4.01 |    5.70 (2.46) |            2.90 |       10.13 (1.22) |     3.10 |     2.91 |
| panels | 10^4 |   128 |      4.14 |    5.58 (2.57) |      4.96 |    6.57 (2.45) |            2.93 |       11.14 (1.26) |     4.34 |     2.97 |
| panels | 10^4 |   328 |      6.38 |    8.19 (2.72) |      6.83 |    8.47 (2.43) |            2.89 |       13.05 (1.20) |     4.87 |     2.90 |
| panels | 10^5 |    64 |      5.04 |    8.46 (4.24) |      5.76 |    8.66 (3.74) |            4.04 |       14.12 (3.21) |     5.66 |     5.24 |
| panels | 10^5 |   128 |      5.62 |    9.02 (4.32) |      6.48 |    9.37 (3.69) |            4.02 |       15.23 (3.31) |     7.05 |     5.21 |
| panels | 10^5 |   328 |      9.85 |   21.68 (9.09) |     16.34 |   15.46 (3.62) |            3.88 |       20.57 (3.08) |     9.61 |     5.04 |
| panels | 10^6 |    64 |      5.46 |    9.39 (4.68) |      6.14 |    9.27 (3.82) |            4.05 |       16.15 (2.90) |    10.43 |     5.77 |
| panels | 10^6 |   128 |      9.05 |   18.52 (9.39) |      9.42 |   12.45 (3.67) |            3.90 |       20.57 (3.01) |    20.70 |     5.79 |
| panels | 10^6 |   328 |     28.20 |  41.56 (14.49) |     25.82 |   29.27 (3.82) |            4.09 |       38.34 (2.89) |    32.43 |     6.33 |

The exact N values are the generator's: 998, 9 998 and so on for `list`,
and exactly 10^k for `panels`.

Stability:

- Configurations that fit in cache repeat within about 3 % from run to run.
- Configurations whose working set is about the size of the L3 (10^5 × 328 B,
  roughly 33 MB per array set) move by ±20 % between runs. In other runs,
  panels/10^5/328 gave fused-soa 12.3–13.5 and sep-soa 15.1–15.9. Do not read
  rankings from those rows.

DMD (`summary-dmd.md`):

- The build is 2–3× slower than LDC's: 7–15 ns/node, against 3.4–6 for LDC.
  DMD copies `.init` and inlines less.
- The fit pass costs about the same as under LDC: a separate sweep is 2.2–2.6
  ns/node on SoA. Fusion still saves 1.0–1.5 ns/node.
- On DMD, `fused-soa` beats `fused-aos` for 64 and 128 B records, because DMD
  writes the fat record badly.

### Counters (LDC, per node)

| config            | variant   | cyc total | ins total | pass cyc | pass L1D miss | pass DRAM fills |
| ----------------- | --------- | --------: | --------: | -------: | ------------: | --------------: |
| panels 10^4, 64 B | fused-aos |      16.9 |      83.6 |        – |             – |               – |
|                   | sep-aos   |      24.4 |     103.7 |     12.4 |          1.00 |               0 |
|                   | sep-soa   |      27.5 |     113.0 |     11.9 |          0.47 |               0 |
|                   | level-soa |      49.0 |     154.6 |     32.4 |          2.14 |               0 |
| list 10^6, 328 B  | fused-aos |       142 |      94.5 |        – |             – |    2.23 (build) |
|                   | sep-aos   |       190 |     113.8 |     52.1 |          1.51 |            0.74 |
|                   | sep-soa   |       138 |     122.5 |     10.3 |          0.47 |            0.06 |
|                   | rest-aos  |       149 |      43.3 |      149 |          5.10 |            3.88 |
|                   | rest-soa  |      23.5 |      44.8 |     23.5 |          1.31 |            0.31 |

## Conclusions

1. **Fusion saves about 0.7–1.8 ns/node in end-to-end time when the data is in
   cache.** That is 17–30 % of build + fit, for both AoS and SoA.
   - The separate sweep costs 1.7–2.5 ns/node: 9–12 cycles and about 20
     instructions per node, bound by the load→add/max→store chain into the
     parent's `sz`. The `panels` shape is worse (12–19 cycles) because its
     random axes make the parent-axis branch mispredict.
   - Fusion adds only 0.7–1.0 ns/node to the build. It costs almost no extra
     instructions, about 5 cycles of latency, and largely overlaps with the
     build's own stores.
   - At 10^4 nodes (a big real UI), the separate pass costs about 20–25 µs
     per frame and fusion saves about 10–15 µs. Both are small against a
     16 ms frame.
2. **SoA does not make a separate pass as cheap as fusion.**
   - In cache, `sep-soa` is slower than `fused-aos` by 1.4–2.4 ns/node (25–60
     %). The SoA sweep is no faster than the AoS sweep while everything is in
     L1/L2, because it is latency- and IPC-bound, not bandwidth-bound.
   - The SoA build itself is about 0.6 ns/node slower at 64–128 B: it writes
     about 11 store streams instead of one record.
   - SoA only wins once the fat records spill out of the cache: from 10^6
     nodes at 64 B, and from 10^5 at 328 B. There `sep-aos` re-streams the
     whole fat buffer (1.0–1.5 L1D misses/node and up to 0.8 DRAM fills/node;
     the pass rises to 4–15 ns/node), while the `sep-soa` pass stays at about
     2–4 ns/node.
   - At 10^6 × 328 B, `sep-soa` comes within about 3 % of `fused-aos`, and
     `fused-soa` is fastest overall (about 26–27 ns/node). At that size the
     build's 328 B record stores (about 2.2 DRAM fills/node) dominate
     everything else.
3. **The two choices can be combined: `fused-soa` keeps nearly all of the
   fusion win.** It is within 0.4–1.3 ns/node of `fused-aos` in cache and the
   best variant beyond it.
4. **SIMD does not pay off.** `level-soa` loses everywhere, by 4–6 ns/node
   against `sep-soa`.
   - The depth counting sort, the gather and the scatter cost about 5 ns/node,
     which is already more than the whole scalar sweep.
   - Even if the data were already in level order, the reduction alone runs at
     0.9–1.2 ns/node on `list` and about 3 ns/node on `panels` against 1.8–3.8
     scalar. That is at most a 2× gain on a pass already at about 2 ns/node.
   - It resists SIMD for three reasons:
     - Pre-order interleaves sibling subtrees, so a parent's children are not
       contiguous.
     - The scatter into the parent conflicts by construction, because every
       sibling targets the same parent. AVX-512 conflict detection serialises
       exactly the common case.
     - The typical fan-out is 2–4, and each element costs only one add and
       one max. Vector lanes stay mostly empty, and the per-parent overhead
       and the axis branch dominate.
   - Wide lists (1000 labels) do vectorise, but they are a minority of the
     parents.
   - Carrying the accumulator in registers (`sep-soa-rc`) is also slower,
     2.2–4 against 1.7–3.8 ns/node: the extra compare and branch on every node
     costs more than the store-forward it avoids. A branch-free parent-axis
     select made `panels` 10^6 faster (3.1 against 3.8) but cache-resident
     sizes slower, so it was not kept.
5. **The fit pass is a minor share of layout. The other passes are where the
   layout of the data matters.**
   - In cache, with SoA, build + separate fit + rest runs at about 8–9 ns/node,
     for example panels 10^4/64: build 3.2, fit 2.5, rest 2.9. A separate fit
     pass is 25–30 % of that, and fusion recovers 12–18 % of the whole.
   - The top-down passes (grow x, grow y, positions) on fat AoS records cost
     10–32 ns/node once the records leave the cache (5.1 L1D misses and up to
     3.9 DRAM fills per node). On SoA they cost 3.5–6.3. That is a 3–6×
     factor, against the roughly 1.3× that fusion offers.
6. **Clay's own design does not get all of the fusion win.** Clay fuses only
   the first estimate. `Clay__CalculateFinalLayout` (clay.h:2645) always runs
   a separate bottom-up DFS that recomputes heights after text wrapping, and
   its close re-reads each child's record through a child-index buffer
   instead of keeping accumulators.

**Recommendation for `sparkles:ui`:**

- Keep the hot layout fields in SoA, or at least out of the 328 B `Widget`,
  because of the grow and position passes.
- Compute width fit at close into those arrays, as `fused-soa` does. It costs
  about one accumulator frame on the build stack.
- If a design reason requires a separate fit pass (for example text wrapping
  that forces re-fitting, as in Clay), a scalar reverse sweep over SoA costs
  about 2–4 ns/node and is acceptable. Do not bother with a SIMD version.

## Caveats

- The model leaves out min/max clamps, minDimensions, aspect ratio,
  floating elements, scroll clipping, text wrapping and iterative grow/shrink
  equalisation. These add the same work to every variant's per-node
  finalisation.
- All sizes are integer-valued floats, so sums are exact and the
  reassociation done by `@fastmath` cannot change the checksum.
- The steady state assumes the buffers are reused every frame; no allocation
  or page faults are timed.
- The machine was mostly idle, not isolated: a browser was running.
