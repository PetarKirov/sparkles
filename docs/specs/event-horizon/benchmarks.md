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

**This is the honest, load-bearing finding, not a footnote.** The
work-stealing engine _loses badly_ on this workload, and the reason is
architectural and was anticipated by the plan:

1. **`getdents` has no io_uring opcode.** The directory read is an ordinary
   syscall, so there is nothing for a fiber to _await_. A stackful fiber earns
   its keep by suspending cheaply across async I/O latency; when the task is a
   sub-microsecond syscall that never parks, the fiber's 64 KiB stack alloc,
   context switch, and GC-stack registration are pure overhead. `taskPool`
   (and Rust rayon, the incumbent winner) carry each unit of work as a
   lightweight closure on a thread — no per-task stack.
2. **One global injection queue with a mutex.** Every directory does a
   lock/unlock to submit its subdirectories; 2 551 submits + pulls contend on
   one lock. rayon uses per-worker deques with work-stealing only on empty —
   near-zero contention. event-horizon's per-worker-deque + `MSG_RING`-targeted
   stealing is [open-issue O2](./open-issues.md); until it lands, the global
   queue is the bottleneck this benchmark exposes.

The takeaway is a **correct characterization of the tool**: the work-stealing
fiber scheduler is built for _async-I/O fan-out_ — thousands of connections
each parking on the ring — where suspension amortizes over I/O latency and the
proactor does real work. It is the wrong tool for CPU/syscall-bound parallel
fan-out with sub-microsecond tasks, where a thread-pool-of-closures wins. A
walker is deliberately the adversarial case; it is included precisely because
a benchmark suite that only reports wins is not measuring.

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
