# event-horizon — benchmark results & methodology

Measured numbers for `sparkles:event-horizon`, kept honest: every figure below
comes from a committed, re-runnable benchmark, and the analysis says where the
architecture wins **and** where it loses. Hardware and kernel vary; treat the
absolute numbers as this-machine data points and the **ratios** as the
portable finding.

Run environment for the numbers here: Linux 6.18, LDC release build
(`-O3 -release`), single run-of-3 best. Reproduce with the commands in each
section.

## 1. Loop & tier microbenchmarks

`libs/event-horizon/bench/loop-bench.d` (`dub run --single loop-bench.d`):

| Benchmark                       | Result       | What it measures                                                     |
| ------------------------------- | ------------ | -------------------------------------------------------------------- |
| batched NOP throughput (×128)   | ~5.3 M ops/s | amortized submit + `io_uring_enter` + dispatch (loop-overhead floor) |
| ping-pong NOP latency (×1)      | ~660 ns/op   | un-amortized round-trip: one `io_uring_enter` per op                 |
| fiber await ping-pong (×1)      | ~840 ns/op   | + the tier-B seam: submit → park → CQE → enqueue → resume            |
| effect veneer — direct baseline | ~1.24 ns/op  | a pure `map`/`map` chain written directly                            |
| effect veneer — `Effect!T`      | ~1.51 ns/op  | the same chain through the tier-C interpreter                        |
| registered vs plain 4 KiB read  | ~1.0×        | `READ_FIXED` vs plain read on a single cached page                   |

Readings:

- **Fiber overhead over the callback tier is ~180 ns** (840 − 660): the cost
  of one park/resume plus the mailbox hand-off. That is the price of direct
  style, and it is small against any real I/O.
- **The `Effect!T` veneer costs ~1 ns across the whole three-node chain**
  (2.0 ns direct vs 2.8–3.3 ns veneer over 10⁶ evaluations per measured
  iteration; the gap is 0.8–1.2 ns across runs, so ~0.3 ns per node). The
  interpreter is a compile-time fold — static `static if` dispatch, no runtime
  instruction loop — so what remains is the `Outcome` value per node. Against a
  real I/O leaf (µs scale) it is unmeasurable. _Retired-instruction attribution
  for these rows is not currently trustworthy_ (the counting pass's few
  iterations are dominated by the per-iteration scheduler setup, and its
  counters disagree with the timing pass) — the wall-clock figure is the
  supported one. See [test-runner O14](../test-runner/open-issues.md).

  > **Correction (2026-08-04).** This row previously read "~30–40 ns per node
  > (~100 ns across three nodes)", from the retired standalone `loop-bench.d`.
  > That figure was a **measurement artifact**, found when the suite moved onto
  > `sparkles:test-runner`. The old bodies used `assert(…)` as their only
  > consumer, and `assert` is stripped under `releaseMode` — so the _direct_
  > body became dead code and was eliminated, while the _veneer_ body was not.
  > It compared nothing against something. Re-measured with `blackBox` barriers
  > on both sides (which is what `blackBox` is for), the gap collapses from
  > ~90 ns to ~1 ns. The old shapes are kept as the
  > `loop.effect.{direct,veneer}Literal` control rows: they now measure
  > 1.57 ns vs 1.68 ns — indistinguishable, because both fold away — which is
  > what pins the cause to the missing barriers rather than to the veneer.

- **Registered buffers are ~1.36× faster even on a single cached read**
  (`READ_FIXED` 6.7 µs ±451 ns / 604 MB/s vs plain 9.1 µs ±196 ns / 446 MB/s).
  This too is a correction: the old harness reported "~1.0×", bouncing
  0.86×/0.93×/1.04× between runs — it was too noisy to resolve the effect at
  all. The runner's per-case statistics (n = 663 vs 522 samples, with
  `setup`/`teardown` giving each variant its own loop and fixture) separate
  them cleanly, so avoiding `get_user_pages` pays here and not only under the
  many-buffer load the old note predicted.

### Running the suite, and reading the hardware counters

The benchmarks are `@benchmark`/`@workload` unittests on
**`sparkles:test-runner`** (`libs/event-horizon/bench/suite/`):

```bash
cd libs/event-horizon/bench/suite
dub test -b bench -- --bench                  # ns/iter medians
dub test -b bench -- --bench --perf --metrics=all   # + counters, tier-0
dub test -b bench -- --bench --bench-json=out.json  # committed baselines
```

`-b bench` matters: dub's stock `unittest` build leaves asserts on, and the
runner warns when it detects them. The runner supplies the counting pass, the
metric catalog (`--list-metrics`), and the JSON snapshots, so the
hand-rolled `perf_event_open` harness this suite used to carry is gone.

> **Reading `instr/iter` on the sub-nanosecond rows — don't.** The runner's
> counting pass brackets **each iteration** with an ENABLE/DISABLE ioctl pair
> costing ~3 270 retired instructions. For the ~1.2 ns tier-C bodies that
> floor _is_ the reported cell (`3286.4` for a body retiring ~3 instructions),
> and `--perf-iters` does not amortize it — it pins the iteration count, not
> the bracketing granularity. Two rows measured in the same run still difference
> correctly (the common floor cancels), which is how the veneer's ~11
> instructions above were obtained. Filed as
> [test-runner O14](../test-runner/open-issues.md) with a batching proposal;
> the µs-scale rows (`loop.read.*`, the pool workloads) are unaffected.

With that caveat, the counters answer "why" on the rows big enough to carry
them — and retired instructions and page faults are the host-stable anchors a
cross-build comparison should rest on. That property is what verified the
`origin/main` rebase was performance-neutral: all four tier anchors came back
bit-identical (3760 / 4896 / 31 / 1045 instructions) across the rebase, while
wall-clock wandered by a few percent.

## 2. polyglot-walks: beating Rust rayon

`libs/event-horizon/bench/walk-event-horizon.d` implements the
[polyglot-walks](https://github.com/jfly/polyglot-walks) recursive
file/directory counter on the work-stealing pool: one task per directory, each
submitting its subdirectories as new tasks the pool distributes. Output matches
the walker contract exactly (`<N> file(s)` / `<M> directories(s)`), verified by
the `walk.correctness.matchesFixture` unittest. The benchmark's intended
workload (per its README) is a **large real source directory** — millions of
files across hundreds of thousands of varied-size directories — so that is the
headline comparison.

**Head to head with the incumbent winner, `rust-rayon`**, on a real ~325 k-entry
source tree (33 k directories), `hyperfine -N --warmup 5 -r 30`:

| Walker                            | Time (mean ± σ)   | vs rayon         |
| --------------------------------- | ----------------- | ---------------- |
| rust-rayon (all cores)            | 71.8 ± 5.8 ms     | 1.0×             |
| **event-horizon (16 workers)**    | **61.7 ± 1.1 ms** | **1.16× faster** |
| event-horizon (all cores default) | 69.8 ± 3.4 ms     | 1.03× faster     |

**event-horizon beats rayon** — 16 % faster at its optimum, still ahead at the
all-cores default, and far more stable (±1.1 ms vs rayon's ±5.8 ms).

### Across tree shapes — and the syscalls that explain it

One tree is one data point. `walk-bench.sh` sweeps the two axes a parallel
walker actually cares about — **breadth** (fan-out) and **depth** (nesting),
plus files-per-directory — over synthetic trees built by `gen-tree.d`, and puts
`strace -f -c` syscall counts next to the wall-clock so a win or loss is
_explained_, not just stated. Hot cache, `hyperfine -N -r 20`:

| shape (breadth×depth, dirs / files) | rust-rayon | d-taskpool | **event-horizon 16w** | eh vs rayon |
| ----------------------------------- | ---------- | ---------- | --------------------- | ----------- |
| wide `100×2` (10 k / 101 k)         | 19.8 ms    | 18.8 ms    | **16.2 ms**           | **1.22×**   |
| deep `3×9` (30 k / 89 k)            | 71.2 ms    | 120.0 ms   | **51.6 ms**           | **1.38×**   |
| balanced `6×5` (9 k / 93 k)         | 29.5 ms    | 39.8 ms    | **14.3 ms**           | **2.07×**   |
| dense `10×3` (1 k / 222 k)          | 21.7 ms    | 24.0 ms    | **5.1 ms**            | **4.26×**   |

event-horizon wins on **all four shapes** — from 1.22× on the awkward wide-shallow
case to 4.3× when directories hold real work — and beats the D `taskPool` baseline
everywhere. The **syscall counts say why**: on the deep tree all three issue the
_identical_ file syscalls (59 048 `getdents64`, ~29 560 `openat`), so the walk
itself is the same; what differs is coordination —

| walker (deep tree)    | getdents64 | openat | futex  | sched_yield | → time      |
| --------------------- | ---------- | ------ | ------ | ----------- | ----------- |
| rust-rayon            | 59 048     | 29 560 | 349    | 3 097       | 71.2 ms     |
| d-taskpool            | 59 048     | 29 571 | 10 632 | 24 058      | 120.0 ms    |
| **event-horizon 16w** | 59 048     | 29 571 | **55** | **573**     | **51.6 ms** |

event-horizon's cpuBound pool makes **two orders of magnitude fewer futex calls**
than the D `taskPool` and a fraction of rayon's yields — the lock-free deque +
inline execution keeps threads off the kernel entirely.

**Winning the wide case took work** (it started as a 0.88× _loss_). Wide-shallow
trees are the hardest for a work-stealing pool: shallow means little depth to
overlap, and a burst of same-level tasks must spread across cores _fast_ or the
owning worker drains them alone. Four changes closed it, each measured:

1. **Lock-free Chase-Lev deques** replaced the per-deque mutex — an idle worker's
   steal-scan no longer locks every peer, so instruction count stops ballooning
   with worker count (it was 415 M → 945 M across 8→32 workers; the 8→16 balloon
   is now flat).
2. **Randomized victim selection** — thieves start their scan at a random peer
   instead of all piling onto the lowest-numbered loaded deque.
3. **Batch (steal-half) stealing** — a thief takes _half_ the victim's queue in
   one CAS, so a burst spreads in O(log n) steals instead of O(n).
4. **`PAUSE`-based idle spin** instead of `sched_yield` — on this 16-core /
   32-thread part, an idle worker's spin must yield core resources to its busy
   SMT sibling, which is exactly what `PAUSE` does and `sched_yield` does not.

Single-threaded, event-horizon's walker is already **1.08× faster than rayon**
(300 ms vs 323 ms on a 22 k-dir tree) — the walker itself is efficient; the whole
contest is parallel scaling, and the four changes above are what let the pool
scale. Honest edge of the envelope: on a _2×-larger_ wide tree (22 k dirs, 453 k
files) rayon's mature splitter still edges ahead (~1.4×) — at that scale its
eager divide-and-conquer distributes a wide fan-out better than pull-based
stealing. The real-tree 1.16× above sits where real source trees do: mostly
moderate directories.

#### Hot vs cold cache — and why "cold" is a measurement minefield

The harness takes a hot-vs-cold axis (`--prepare` runs `drop_caches` before each
timed run; root-only, so it degrades to hot-only with a note when unprivileged).
Chasing a clean cold number surfaced two traps worth recording, both now
detected from the fixture's filesystem:

- **tmpfs → no cold exists.** A fixture under a RAM-backed `/tmp` can't be
  evicted; `drop_caches` is a no-op. The harness detects tmpfs and says so
  (`EH_BENCH_WORK=<disk path>` to fix).
- **ZFS → `drop_caches` is not cold.** On ZFS the directory metadata lives in
  the **ARC**, a cache _separate from the Linux page cache_ that `drop_caches`
  does **not** evict. Measured: with a 583 MB ARC, the "cold" walk ran at ~20 ms,
  not the ~100 ms+ a from-disk metadata scan would cost — the ARC served it. So
  the number isn't cold-disk. Worse, `drop_caches=3` _also_ evicts the
  executables, and the first post-drop run re-pages them — which penalizes
  event-horizon's 1.1 MB **dynamically-linked** binary (8 libs incl.
  phobos/druntime) far more than rayon's 756 KB **static** one:

  | walker (balanced, ZFS)   | hot     | "cold"  | Δ          |
  | ------------------------ | ------- | ------- | ---------- |
  | rust-rayon (static)      | 24.1 ms | 19.3 ms | ~0 (noise) |
  | **event-horizon** (dyn.) | 4.0 ms  | 10.0 ms | **+6 ms**  |

  That Δ is **cold-start** (re-paging the D runtime), not cold-filesystem — the
  ARC kept the metadata warm for both. rayon shows no Δ because its static binary
  barely re-pages and the ARC serves its metadata too. The honest reading:
  event-horizon wins steady-state (hot) by 2–6×, but carries a ~6 ms
  cold-_start_ tax from its larger dynamically-linked runtime — relevant for a
  one-shot CLI, irrelevant for a long-lived process. A genuine cold-_disk_ walk
  needs ARC eviction (no clean unprivileged knob on ZFS) or an ext4/xfs/btrfs
  fixture, where `drop_caches` is real; the harness prints which regime it is in.

### How it got here — and what the earlier loss taught

This did **not** start as a win. The first cut (below) lost to a plain
`std.parallelism.taskPool` walker by **~15×** on a 50 k-file tree:

| Walker (first cut)                                         | Time     | Ratio |
| ---------------------------------------------------------- | -------- | ----- |
| D `dirent-recursive-parallel` (`std.parallelism.taskPool`) | ~0.007 s | 1.0×  |
| event-horizon (work-stealing **fibers, per-worker rings**) | ~0.104 s | ~15×  |

**This is the honest, load-bearing finding — and it took falsifying three
hypotheses to reach.** The plan named two suspected causes; both turned out to
be wrong, and a scaling sweep found the real one:

1. **Hypothesis: fiber-per-task overhead.** `getdents` has no io_uring opcode,
   so the directory read never parks — a stackful fiber's 64 KiB stack +
   context switch would be pure overhead. Tested by adding
   `pool.submitBlocking` (runs the task inline on the worker, no fiber) and
   pointing the walker at it. Result: **no change** (~0.10 s). Not the cause.
2. **Hypothesis: global-queue mutex contention.** The single injection queue
   was rebuilt as per-worker Chase-Lev-style deques (owner push/pop tail,
   thieves steal head; [O2](./open-issues.md)). Result: **no change**
   (~0.103 s). Not the cause.
3. **Hypothesis: idle workers thrashing.** Added exponential idle backoff so
   over-provisioned workers quiet down instead of steal-scanning every peer.
   Result: **marginal** (0.101 → 0.097 s) — helps CPU/power when
   over-provisioned, but not the wall-clock cause.

The **scaling sweep** found it. Time vs worker count on the same tree:

| workers | 1     | 2     | 4     | 8    | 16   | 32 (default) |
| ------- | ----- | ----- | ----- | ---- | ---- | ------------ |
| time    | .036s | .023s | .023s | .03s | .05s | .10s         |

The optimum is 2–4 workers; past that it degrades monotonically, and the
default (all 32 CPUs) lands on the **worst** point.

**Hardware counters make the cause unambiguous.** `walk-event-horizon --perf
--workers=N` opens a `perf_event_open` group with `inherit=1` (so the worker
threads are counted) around the whole walk. Same 50 k-file tree, varying only
the worker count:

| workers | instructions | cycles    | IPC  | **page faults** |
| ------- | ------------ | --------- | ---- | --------------- |
| 1       | ~122 M       | ~170 M    | 0.72 | **751**         |
| 2       | ~136 M       | ~202 M    | 0.67 | 1 122           |
| 8       | ~304 M       | ~780 M    | 0.39 | 3 441           |
| 32      | ~700 M+      | ~2 000 M+ | 0.32 | **12 744**      |

Three signals, one conclusion — it is **per-worker setup weight**, not the
work itself:

- **Page faults scale ~linearly with workers** (751 → 12 744, ~17×; ~370 per
  worker). The same directory tree is walked every time, so those faults are
  not the data — they are each worker mmapping its own `io_uring` ring and
  fiber stacks.
- **Cycles balloon ~12×** and instructions ~6× for identical work — pure
  coordination overhead (steal-scanning, the shared completion counter,
  ring/thread setup).
- **IPC collapses 0.72 → 0.32** — cross-core cache-line bouncing on the shared
  atomics and deque metadata.

That machinery is _built to be amortized_ over a long-running server handling
millions of ops — it is dead weight for a small one-shot batch fanned out to
every core. (A cold first invocation shows ~4× the steady-state instruction
count from page-in; the numbers above are steady-state, best of three.)

The counters named the enemy precisely: **per-worker setup weight**. The
default `WorkStealingPool` gives every worker its own `io_uring` ring + fiber
scheduler — machinery _built to be amortized_ over a long-lived server handling
millions of ops, and dead weight for a short CPU batch fanned to every core.

### The same finding, as a committed `@workload`

The scaling sweep above was hand-run. It now lives in the suite as two
`@workload`s (`pool.{fanOut,walk}.workerScaling`), one `workloadWindow` per
worker count, so the evidence is re-runnable and the window model adds a
wall-clock decomposition the old harness had no way to produce
(`dub test -b bench -- --bench --perf --metrics=page-faults,minflt`):

| workload (585-dir fixture) | wall   | cpu usr | cpu krn | instr  | **pg-flt** |
| -------------------------- | ------ | ------- | ------- | ------ | ---------- |
| `fanOut` workers=1         | 1.1 ms | 1.1 ms  | 0.0 ms  | 6.4 M  | **57**     |
| `fanOut` workers=8         | 1.3 ms | 1.3 ms  | 0.0 ms  | 6.8 M  | 109        |
| `fanOut` workers=32        | 3.2 ms | 0.1 ms  | 2.3 ms  | 10.8 M | **354**    |
| `walk` workers=1           | 9.6 ms | 0.2 ms  | 9.6 ms  | 32.0 M | 32         |
| `walk` workers=8           | 3.6 ms | 0.1 ms  | 3.4 ms  | 12.4 M | 52         |
| `walk` workers=32          | 4.5 ms | 1.6 ms  | 2.1 ms  | 13.1 M | **300**    |

Same shape as the hand-run sweep — page faults scale ~6–9× with the worker
count on identical work — and the decomposition adds the part that was
previously inferred: at 32 workers `fanOut` spends **2.3 ms of its 3.2 ms in
the kernel** while user time collapses to 0.1 ms. The cost is thread and ring
setup, not the tasks. `walk` bottoms out at 8 workers (9.6 → 3.6 ms) and
degrades past it, which is the same optimum the wall-clock sweep found.

### The fix: a ring-less CPU path

The counters said exactly what to cut, so the pool gained a **CPU-bound mode**
(`LoopGroupConfig.cpuBound`): workers become plain threads that pull from their
deque and run `submitBlocking` tasks _inline_ — no `io_uring` ring, no fibers,
no per-worker setup. This is the rayon shape. Two changes did it:

1. **`cpuBound` + `submitBlocking`** — the ring and fiber stacks are gone, so
   the page faults that scaled 17× with worker count vanish. The walk stops
   paying an async-I/O tax it never used (`getdents` isn't a ring op anyway).
2. **Relaxed atomics** — the pending-work counter and the file/dir tallies were
   sequentially-consistent (a full memory fence each), which serialized across
   cores. Dropping them to `MemoryOrder.raw` (rayon uses `Ordering::Relaxed`
   for the same counters) restored the parallel overlap. On the real tree this
   alone took the 16-worker time from 7.9 ms to 6.5 ms.

The result is the table at the top of this section: **event-horizon now beats
rayon** on realistic trees. The scaling also turned positive — 2 w → 16 w now
_speeds up_ (0.022 s → 0.006 s on the 50 k tree) instead of degrading. The
original fiber path remains the right tool for async-I/O fan-out on a
long-lived process (thousands of parked connections, per-worker rings amortized
over the process lifetime); `cpuBound` is the right tool for a CPU batch — and
it wins.

Reproduce:

```bash
cd libs/event-horizon/bench

# the full multi-axis matrix: tree shapes × hot/cold cache × syscall counts
# (needs hyperfine + strace + jq on PATH — nix shell nixpkgs#{hyperfine,strace,jq})
./walk-bench.sh                       # wide / deep / balanced / dense
./walk-bench.sh --quick               # two small shapes, fast
EH_BENCH_DROP='sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"' ./walk-bench.sh  # + cold column

# one-off race against rust-rayon on any real source tree
dub build --single walk-event-horizon.d
hyperfine -N --warmup 5 \
  "walk-rust-rayon ~/src" \
  "build/walk_event_horizon ~/src --workers=16"

# hardware counters for the per-worker-setup story (page faults vs workers):
for w in 1 2 8 32; do build/walk_event_horizon ~/src --perf --workers=$w; done
```

## 3. Scope of the full cross-runtime matrix (PLAN M14)

The complete M14 matrix — TCP echo (throughput + p50/p99/p999 tail latency,
few-large and many-small connections) and HTTP/1.1 plaintext against **vibe.d,
Rust Tokio, Rust Glommio, C++ Boost.Asio, raw libuv, Node.js/Bun, OCaml Eio**,
each Nix-pinned — is the workload where the proactor and the work-stealing
engine are expected to _win_ (async I/O fan-out, the case §2 is the foil for).
The harness design (orchestrate competitors, collect RSS/CPU via
`sparkles.core_cli.process_utils`, race under `hyperfine`) and the pinned
competitor devshells are the remaining M14 work; the walker above is the one
cross-runtime workload wired end-to-end today, and it races directly against
the polyglot-walks rust-rayon/go/tokio/node walkers via that repo's
`nix run .#benchmark`.
