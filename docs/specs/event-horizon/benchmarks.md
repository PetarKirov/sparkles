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

## 2. polyglot-walks: work-stealing vs a thread-pool of closures

`libs/event-horizon/bench/walk-event-horizon.d` implements the
[polyglot-walks](https://github.com/jfly/polyglot-walks) recursive
file/directory counter on the work-stealing pool: one task per directory,
each submitting its subdirectories as new tasks the pool distributes. Output
matches the walker contract exactly (`<N> file(s)` / `<M> directories(s)`),
verified against the fixture by the `walk.correctness.matchesFixture` unittest.

On a 50 000-file / 2 551-directory tree (best of 3):

| Walker                                                     | Time     | Ratio |
| ---------------------------------------------------------- | -------- | ----- |
| D `dirent-recursive-parallel` (`std.parallelism.taskPool`) | ~0.007 s | 1.0×  |
| **event-horizon (work-stealing fibers)**                   | ~0.104 s | ~15×  |

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

The takeaway is a **correct characterization of the tool**, now backed by the
sweep: the work-stealing engine is for _async-I/O fan-out on a long-lived
process_ — thousands of connections each parking on the ring, per-worker rings
amortized over the process lifetime. It is the wrong tool for a short
CPU/syscall-bound batch over-provisioned to all cores, where a
thread-pool-of-closures with no rings (`taskPool`/rayon) wins. The walker is
deliberately the adversarial case; it is included precisely because a
benchmark suite that only reports wins is not measuring. (`submitBlocking`,
the deques, and the backoff all landed and are sound general improvements —
they just don't move _this_ workload, whose cost is elsewhere.)

Reproduce:

```bash
# build a fixture
root=$(mktemp -d)
for i in $(seq 1 50); do for j in $(seq 1 50); do
  mkdir -p "$root/d$i/d$j"; for k in $(seq 1 20); do : > "$root/d$i/d$j/f$k"; done
done; done
# time it
dub run --single libs/event-horizon/bench/walk-event-horizon.d -- "$root"
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
