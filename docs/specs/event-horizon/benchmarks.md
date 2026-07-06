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
| effect veneer — direct baseline | ~29 ns/op    | a pure `map`/`map` chain written directly                            |
| effect veneer — `Effect!T`      | ~130 ns/op   | the same chain through the tier-C interpreter                        |
| registered vs plain 4 KiB read  | ~1.0×        | `READ_FIXED` vs plain read on a single cached page                   |

Readings:

- **Fiber overhead over the callback tier is ~180 ns** (840 − 660): the cost
  of one park/resume plus the mailbox hand-off. That is the price of direct
  style, and it is small against any real I/O.
- **The `Effect!T` veneer adds ~30–40 ns per node** (~100 ns across three
  nodes). The interpreter is a compile-time fold — static `static if` dispatch,
  no runtime instruction loop — so this is not dispatch cost but the `Outcome`
  value constructed per node. Against a real I/O leaf (μs scale) it vanishes;
  for pure in-memory pipelines it is measurable and you would stay in direct
  style.
- **Registered buffers show ~1.0× on a single small cached read.** Honest: the
  `get_user_pages` avoidance that `REGISTER_BUFFERS` buys only pays under
  many-buffer / high-concurrency load, not one 4 KiB page already in cache.
  The registration path is kept as a regression tracker; the win belongs to
  the (future) concurrent-echo matrix.

### Hardware counters — the "why" behind the ns/op

`loop-bench.d` also runs a dedicated `perf_event_open(2)` counting pass per
tier (`libs/event-horizon/bench/perf/`, adapted from the wired runtime bench).
Each timed body runs 256 inner ops so the ~2-ioctl measurement floor
amortizes; the reported numbers are true per-op:

| benchmark       | instrs/op | IPC  | cycles/op | notes                                    |
| --------------- | --------- | ---- | --------- | ---------------------------------------- |
| `nop-pingpong`  | ~3 760    | 1.17 | ~3 210    | the `io_uring_enter` round-trip          |
| `fiber-await`   | ~4 900    | 1.21 | ~4 050    | **+~1 140 instrs** for the tier-B seam   |
| `effect-direct` | ~31       | 0.93 | ~33       | three int ops written directly           |
| `effect-veneer` | ~1 050    | 1.95 | ~535      | **+~1 015 instrs** Outcome-boxing / node |

Now the tier costs are exact, not inferred from wall-clock: the fiber
park/resume seam is **~1 140 retired instructions** over the raw callback loop,
and the `Effect!T` veneer's three-node pure chain is **~1 015 instructions**
of `Outcome` construction over the direct version (IPC 1.95 — it is
well-pipelined compute, not stalls). Counters degrade gracefully: absent off
Linux or under `perf_event_paranoid`.

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
all-cores default, and far more stable (±1.1 ms vs rayon's ±5.8 ms). On a
denser synthetic tree (250 k files, 100 per directory) the margin widens to
**1.9×**, using half the CPU (104 ms vs 206 ms) — rayon parallelizes per _entry_
(`into_par_iter` over each directory's files), which is pure overhead when
directories are large; event-horizon parallelizes per _directory_, a coarser
grain that amortizes far better. (On a pathologically sparse tree — 10 files per
directory — the tasks are too tiny to amortize and rayon's structured fork-join
edges it back; that case is dominated by measurement noise on a ~5 ms run.)

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
# race the walker against rust-rayon on any real source tree
eh=libs/event-horizon/bench/walk-event-horizon.d
dub build --single "$eh"
hyperfine -N --warmup 5 \
  "walk-rust-rayon ~/src" \
  "libs/event-horizon/bench/build/walk_event_horizon ~/src --workers=16"

# hardware counters for the per-worker-setup story (page faults vs workers):
for w in 1 2 8 32; do
  libs/event-horizon/bench/build/walk_event_horizon ~/src --perf --workers=$w
done
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
