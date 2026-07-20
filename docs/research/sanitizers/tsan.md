# ThreadSanitizer (TSan)

LLVM's happens-before data-race detector — the one sanitizer besides ASan that D
can reach today (through LDC's `-fsanitize=thread`), and the one whose per-test
integration Go has already engineered a copyable design for.

| Field                 | Value                                                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| Tool                  | `ThreadSanitizer` (TSan) — dynamic data-race detector                                                                           |
| Instrumentation locus | [LLVM IR pass][locus] (`ThreadSanitizer`), inherited by LDC for free; DMD has no `-fsanitize`, GDC links GCC's own `libtsan`    |
| Flag                  | `-fsanitize=thread` (LDC); predefines `version (LDC_ThreadSanitizer)`                                                           |
| Runtime generation    | **v3** — four 32-bit [shadow][shadow] cells per 8-byte granule (`Sid`+epoch), **2×** application memory                         |
| Linked runtime here   | **GCC 15.2 `libtsan.so.2`** (LDC's gcc-fallback link — the nixpkgs LDC ships no `clang_rt`; see [runtime selection][selection]) |
| Defect class          | [Data races][hb] (+ thread leaks, mutex misuse, signal-unsafety / errno-in-signal, lock-order inversion)                        |
| Default on finding    | [report-and-continue][halt] (`halt_on_error=false`); the process exits **66** only at `Finalize`                                |
| Versions              | IR pass **LLVM 18.1.8** (LDC 1.41) · runtime **GCC 15.2** · source read **compiler-rt `73802c2e`**                              |
| Verification          | `[hw-verified: x86_64-linux]` — probe [`tsan-data-race.d`][probe] + Experiments E1–E8                                           |

> [!NOTE]
> This page covers the TSan **runtime and its D interaction** — the shadow model,
> the runner-facing control surface, and the `go test -race` seam _as a runtime
> mechanism_. The `go test` CLI/UX and the cross-language survey of per-test
> attribution belong to [runner-integrations.md][runner-integrations]; this page
> owns the TSan-specific mechanics and cross-links there for the design layer. All
> hardware experiments were recorded on **Linux 6.18.26** (NixOS 25.11), an **AMD
> Ryzen 9 7940HX** (Zen 4, 16c/32t), **LDC 1.41.0** / **DMD 2.112.1** / **dub
> 1.42.0-beta.1**, against **GCC 15.2**'s `libtsan.so.2`.

> [!WARNING]
> **Three-way version skew, disclosed up front.** On this box the IR
> instrumentation is LDC's **LLVM 18.1.8** `ThreadSanitizer` pass, but the
> **linked runtime is GCC 15.2's `libtsan.so.2`** (a _newer_ periodic compiler-rt
> merge), while the **source read is compiler-rt HEAD `73802c2e`** (post-18). GCC
> 15.2's flag surface matches compiler-rt at the pinned SHA on every flag checked
> _except_ the brand-new `adaptive_delay*` injection family, which GCC lacks (see
> [Symbolization and suppressions](#symbolization-and-suppressions)). Source
> locators below are at `73802c2e`; runtime figures are from GCC 15.2 `libtsan`.

---

## Overview

### What it detects

TSan finds **data races**: two accesses to the same memory location, from
different threads, at least one a write, with no [happens-before][hb] edge ordering
them. It is a pure dynamic detector — it reports races on the schedule that
actually executed, catches nothing on a path not taken, and (like every
vector-clock detector) can be fooled into a false negative by a serialized
schedule that orders a genuine race away. Beyond plain races it also flags **thread
leaks**, **mutex misuse** (destroying a held lock, unlocking from the wrong
thread), **signal-unsafety** (calling non-async-signal-safe code, or spoiling
`errno`, in a handler), and — nominally — **lock-order inversion**, though that
last detector barely functions (see
[Defect classes and blind spots](#defect-classes-and-blind-spots)).

### Design philosophy: report and keep running

TSan v3 is built around a compact per-access shadow and a happens-before engine
that models synchronization through [interceptors][interceptor] and atomics — not
a lockset. Its second design stance, the one that shapes every runner integration,
is that **a report is not fatal**. The default is baked into the flag definition
([`tsan_flags.inc:45`][llvm-src]):

> `TSAN_FLAG(bool, halt_on_error, false, "Exit after first reported error.")`

`[source-verified]` The process prints the race, continues, and only flips its
exit status at `Finalize`. That is the opposite of ASan's halt-by-default, and it
is exactly what makes in-process [report windowing][windowing] possible without
`-fsanitize-recover` (which LDC does not even offer for `thread`): TSan is
_already_ report-and-continue, so a runner can poll a report counter around each
test and never needs to survive a `Die()`. `[source-verified]`

---

## How it works

### The v3 shadow model

Each application access is recorded in a **shadow cell** that is a single 32-bit
word — `enum class RawShadow : u32`, `kShadowSize = sizeof(RawShadow)` = 4
([`tsan_defs.h:83-84`][llvm-src]). Four cells cover one 8-byte granule
(`kShadowCnt = 4`, `kShadowCell = 8`), so shadow memory is
`kShadowSize * kShadowCnt / kShadowCell` = **2×** application memory
([`tsan_defs.h:77-87`][llvm-src]). Each cell packs an 8-bit access byte-mask, an
8-bit thread-slot id, a 14-bit epoch, and read/atomic bits —
`struct Parts { u8 access_; Sid sid_; u16 epoch_ : 14; u16 is_read_ : 1;
u16 is_atomic_ : 1; }`, guarded by `static_assert(sizeof(Shadow) == kShadowSize)`
([`tsan_shadow.h:148-179`][llvm-src]). Thread slots are 8-bit (`enum class Sid : u8`,
`kFreeSid = 255`) and epochs 14-bit (`kEpochBits = 14`) — the v3 economy that
replaced v2's 8×64-bit cells ([`tsan_defs.h:57-66`][llvm-src]). Freed memory is
stamped with `kFreeAccess = 0x81` cells (`FreedInfo`), which is how TSan reports
use-after-free of `malloc`'d blocks ([`tsan_shadow.h:140-146`][llvm-src]).
`[source-verified]`

> [!NOTE]
> **The public algorithm wiki still documents v2 — cite the source, not the
> wiki.** google/sanitizers' canonical `ThreadSanitizerAlgorithm` page describes
> the older v2 layout (eight 64-bit shadow cells per granule). The runtime shipped
> since the 2021 rewrite is v3 (four 32-bit cells, `Sid`+epoch), and `history_size`
> — for which v2 guidance recommends `history_size=7` — now **defaults to 0**,
> because v3 grows trace parts dynamically ([`tsan_flags.inc:61-64`][llvm-src]).
> Every claim here is grounded in `tsan_shadow.h` / `tsan_defs.h` at `73802c2e`.
> `[source-verified]` `[literature]` (the 2021 v3-rewrite dating).

### Atomics as synchronization: `core.atomic` through the pass

The load-bearing fact for D is that `core.atomic` is _real_ atomics all the way
down, so TSan models it correctly. LDC lowers the `core.atomic` intrinsics to LLVM
atomic instructions with no instrumentation at all:

```text
atomicOp!"+="(c, n)          →  atomicrmw add ptr @…counter, i32 %n seq_cst
atomicLoad!(MemoryOrder.acq) →  load atomic i32, ptr %p acquire
atomicStore!(…rel)           →  store atomic i32 %v, ptr %p release
cas(&c, e, d)                →  cmpxchg ptr %p, i32 %e, i32 %d seq_cst seq_cst
```

Recompile the same module under `-fsanitize=thread` and the pass rewrites those
into runtime calls — `__tsan_atomic32_fetch_add` / `_load` / `_store` /
`_compare_exchange_val` — rewrites plain accesses to `__tsan_read4` / `__tsan_write4`,
and brackets every function with `__tsan_func_entry` / `__tsan_func_exit`
`[hw-verified: x86_64-linux]` (Experiment E1, `atomics-tsan.ll`). Because the
atomics become runtime calls, **TSan treats a `core.atomic` operation as a
synchronization event**: the probe's racy plain `counter++` is caught, and the
byte-for-byte-equivalent `atomicOp!"+="` version is silent. This is the clang
instrumentation model reproduced exactly for D.

### Interceptors and the fiber API

Uninstrumented code — druntime, Phobos, libc — is seen _only_ through
[interceptors][interceptor]: TSan models `pthread_mutex_*`, thread create/join, and
condition variables as happens-before edges, but a plain load or store the compiler
never rewrote is invisible. GCC 15.2's `libtsan.so.2` also exports the full
**fiber API** — `nm -D` shows `__tsan_create_fiber`, `__tsan_destroy_fiber`,
`__tsan_get_current_fiber`, `__tsan_set_fiber_name`, and `__tsan_switch_to_fiber`
all `T`-exported `[hw-verified: x86_64-linux]`. In the runtime each fiber gets a
full `ThreadState`, and a switch is itself a happens-before edge keyed on the fiber
pointer: `FiberSwitch` does `Release(thr, …)` before and `Acquire(fiber, …)` after
the context move unless `FiberSwitchFlagNoSync` ([`tsan_rtl_thread.cpp:356-390`,
`tsan_interface.cpp:59-84`][llvm-src]). The public header states the calling
contract verbatim ([`tsan_interface.h:158-159`][llvm-src]):

> `__tsan_switch_to_fiber should be called immediately before switch to fiber, such as call of swapcontext.`

`[source-verified]` **No shipped druntime calls any of these** — `grep -rn "__tsan"`
over both the LDC-fork and upstream druntime trees returns zero matches, and LDC's
`SupportSanitizers` machinery has no TSan entries (it is ASan-only). `[source-verified]`
(Experiment E6). What that costs, and why it does _not_ cost soundness, is
[Concern 3](#d-and-druntime-interaction).

---

## The seven concerns

The concern order is fixed across the survey. **All seven apply to TSan** — none is
N/A — though Concern 1's "leaks" means _thread_ leaks (memory leaks are
[LSan][asan]'s), which is itself worth stating.

### Defect classes and blind spots

TSan detects the race classes above plus, via `report_atomic_races` (default
**true** — "Report races between atomic and plain memory accesses",
[`tsan_flags.inc:36-37`][llvm-src], runtime-confirmed `[hw-verified: x86_64-linux]`),
races between an atomic and a plain access to the same location. Use-after-free of
`malloc`'d memory is caught via the `kFreeAccess` freed-cell mechanism above.

**Lock-order inversion is nominally on but effectively dead.** `detect_deadlocks`
defaults true ([`sanitizer_flags.inc:123`][llvm-src], runtime-confirmed), and the
runtime creates a detector — but the version compiled into C/C++ TSan is
generation **1**, a bit-vector lock-order graph whose own header is blunt about its
maturity ([`sanitizer_deadlock_detector.h:9-17`][llvm-src]):

> `FIXME: this is work in progress, nothing really works yet.`

`[source-verified]` The second-generation detector exists in-tree
(`sanitizer_deadlock_detector2.cpp`) but only Go's build defines
`SANITIZER_DEADLOCK_DETECTOR_VERSION=2`, and Go then disables deadlock detection
entirely (`cf.detect_deadlocks = false` under `SANITIZER_GO`). Treat TSan as a
**race detector, not a deadlock detector**, for D. `[source-verified]`

Blind spots that matter for D, in ascending nastiness:

- **Fence-based lock-free protocols.** A structure synchronized only by
  `atomicFence` with no atomic on the object itself (an event-horizon deque
  precedent) can present accesses TSan sees no ordering edge for. Fences are the
  weakest signal TSan models; hand-rolled lock-free code is where its false
  positives and negatives concentrate.
- **GC-managed memory** — [the GC memory blind spot][gc-blind-spot]. Use-after-free
  _inside_ a GC pool is invisible to every [allocator-interception][alloc]-based
  view, because the GC's pools are `mmap`'d, never routed through an intercepted
  `malloc`/`free`. TSan's race detection over GC memory still works (it instruments
  the accesses), but it inherits druntime's own uninstrumented synchronization as
  noise (Concern 3).
- **`suppress_equal_stacks` dedup.** TSan deduplicates identical race stacks
  globally by default, so a report-counting runner attributes each _unique_ race to
  the first test that exhibits it — the same semantics Go documents for its own
  counter. Not a detection gap, an _attribution_ one; note it in any per-test design.

### Instrumentation model and recompile scope

TSan is a compile-time [LLVM IR pass][locus] plus a linked runtime. The recompile
scope is **every module whose accesses you want checked**: uninstrumented code is
seen only through interceptors, so leaving druntime and Phobos uninstrumented costs
_coverage_ of their internal races (and produces the noise in Concern 3), not
correctness of user-code detection. There is no [instrumented-world
requirement][instrumented-world] as MSan has — instrumenting only user modules is a
valid, useful configuration.

In D the whole-closure channel is a dub **buildType**, not `DFLAGS`. A
`buildType "tsan" { buildOptions "unittests" "debugMode" "debugInfo" dflags
"-fsanitize=thread" "-allinst" }` propagates `-fsanitize=thread` to **all** packages
in the graph (verified per-artifact across `expected`, `base`, `core-cli`,
`test-runner-impl`, and the root test build), applies `-unittest` only to the root
test configuration, and keys the dub cache on the buildType name so instrumented and
normal artifacts never collide `[hw-verified: x86_64-linux]` (Experiment E4b). The
`DFLAGS` recipe that looks equivalent is a silent false green — see
[Test-runner integration semantics](#test-runner-integration-semantics) and
[d-toolchain.md][d-toolchain] for the buildType-channel mechanics in full.

### D and druntime interaction

This is the page's centre. Instrumenting user code while druntime and Phobos ship
uninstrumented and un-annotated produces three distinct behaviours: a small,
suppressible noise floor; one catastrophic failure mode; and — pleasantly — sound
fiber operation.

#### The two druntime noise classes

Running the real runner (`dub test :versions -b tsan`, 167 tests, `TaskPool` at 32
threads) completes: **167/167 pass** with exactly **two** druntime noise classes and
**zero** reports from the runner's own `TaskPool`/atomics/output machinery
`[hw-verified: x86_64-linux]` (Experiment E4):

- **31×** `signal handler spoils errno` in druntime's `thread_suspendHandler` — the
  GC stop-the-world suspend signal (signal 34), raised under `Condition.wait` /
  `Thread.join` / GC.
- **1×** `data race` on `rt.monitor_` `initMutex` vs `lockMutex` — lazy Object-monitor
  initialization in uninstrumented druntime.

Both classes are fully silenced by a **two-line** suppression file:

```text
signal:thread_suspendHandler
race:_D2rt8monitor*
```

`print_suppressions=1` confirms the match — `ThreadSanitizer: Matched 32
suppressions`, `31 signal:thread_suspendHandler`, `1 race:_D2rt8monitor*`, exit 0
`[hw-verified: x86_64-linux]`. The mangled `_D2rt8monitor*` glob and the `signal:`
type are covered under [Symbolization and suppressions](#symbolization-and-suppressions).
This refutes the "TSan drowns the runner" hypothesis: the noise is druntime's, it is
small, and it is disjoint from the event-horizon suppression list (whose `race:`
globs cover GC-alloc/thread/array-runtime races) — a shipped file needs the _union_,
and specifically the `signal:` type they lack.

> [!WARNING]
> **GC-heavy multi-threaded D deterministically livelocks under TSan.** This is the
> hard ceiling. With **two or more allocating worker threads** plus `GC.collect`, a
> program **hangs forever** — ~300% CPU, no report, no crash (3/3 runs; a `timeout
30` yields exit 124 with zero output) `[hw-verified: x86_64-linux]` (Experiment
> E5). The mechanism is a collision between druntime's signal-based
> [stop-the-world root scanning][stw] and TSan's async-signal deferral. `strace`
> over a 15-second window shows the suspender `tgkill`-ing the world with `SIGRT_2`
> (signal 34), then parking on a futex waiting for acknowledgements; one target
> parks correctly in `rt_sigsuspend`, but the other **returns from its kernel signal
> frame without parking** (TSan wraps and defers the async signal) and then spins —
> **509,898 `sched_yield` calls in 15 s**:
>
> ```text
> 1725622 tgkill(…, 1725623, SIGRT_2)          # suspender signals the world
> 1725623 --- SIGRT_2 --- ; rt_sigreturn()      # returns WITHOUT parking
> 1725613 --- SIGRT_2 --- ; rt_sigsuspend(…)    # this one parks (resume=RT_3)
> 1725622 futex(…, FUTEX_WAIT_BITSET…)          # suspender waits for acks forever
> 1725623 sched_yield() × 509 898               # livelock
> ```
>
> A hang with no output is the **worst possible CI outcome**, and it is the concrete
> reason Go instruments a _cooperating_ runtime instead of the stock one. Any
> `--sanitize=thread` runner mode needs a **watchdog timeout**, and GC-heavy / highly
> parallel suites must document this as a blind wall. With a single worker thread the
> same program completes (8 errno-spoil warnings, exit 66); the livelock needs ≥2
> mutators suspended mid-runtime.

#### Fibers under TSan: cleaner than expected

Despite druntime calling none of the [fiber-annotation][fiber] API, fibers run
soundly `[hw-verified: x86_64-linux]` (Experiment E7). Three shapes all exit 0 with
zero warnings: same-thread ping-pong (2,000 yields); a fiber created on `main` and
run on another thread; and _one_ fiber whose slices alternate across two threads
behind a `Mutex`/`Condition` handoff. The handoff is `pthread`-interceptor-visible,
so the fiber's slices are happens-before-ordered even though TSan has no fiber
identity. And a **real** race between fiber code and a thread on a `__gshared int`
_is_ caught, with the fiber-side stack symbolized correctly
(`deepInFiber … fiber_race.d:11` → `fiber_entryPoint`), attributed to the OS thread
that ran the fiber. The refuted hypothesis was "fibers cause false races or crashes";
they do not, on these shapes. The fiber API's residual value is fiber _identity_ in
reports and correctness under runtime-internal (non-interceptor) handoffs — not basic
soundness. See [d-toolchain.md][d-toolchain] for the shared no-`SupportSanitizers`
finding across ASan and TSan.

#### `shared` and `core.atomic`

Correct `shared` discipline is _silent_ under TSan: the atomics are modeled as
synchronization (How it works, above), so a properly-atomic counter produces no
report while its racy plain-`int` sibling does `[hw-verified: x86_64-linux]`
(Experiments E1/E3, the [probe][probe]). TSan is, in effect, a checker for whether
your `shared` data is _actually_ synchronized. `-betterC`, `extern(C)` boundaries,
and TLS raise no TSan-specific issue here beyond the universal rule that only
recompiled modules are checked.

### Runtime control and report capture

TSan reads `TSAN_OPTIONS` (Go's build uses `GORACE` instead —
`env_name = SANITIZER_GO ? "GORACE" : "TSAN_OPTIONS"`, [`tsan_rtl.cpp:721`][llvm-src]).
The runner-relevant defaults, all runtime-verified:

- **`halt_on_error=false`** — report-and-continue (quoted above). A race prints,
  execution continues, and only `Finalize` flips the exit:
  `return failed ? common_flags()->exitcode : 0;`
  ([`tsan_rtl.cpp:800-836`][llvm-src]).
- **Exit code 66** — a TSan-specific override of the sanitizer-common default 1
  (`cf.exitcode = 66;`, [`tsan_flags.cpp:95-110`][llvm-src]). Runtime-confirmed: a
  racy program printed its final `counter = …` line _and_ exited 66; with
  `halt_on_error=1` the line is absent (it died at the report); with `exitcode=0`
  the status is 0 `[hw-verified: x86_64-linux]` (Experiment E2). `-fsanitize-recover`
  is irrelevant for TSan — the default is already continue.
- **`log_path`** routes each process's report to a PID-suffixed `path.<pid>` file;
  **`TSAN_SYMBOLIZER_PATH`** is TSan's own symbolizer override (set in the same
  `tsan_flags.cpp` block as the exit code).

The [weak-hook control surface][weak-hooks] a D program can claim — the seam the
proposal is built on — is three-fold, and all three fire **today** against GCC
`libtsan`, needing only that the executable export its dynamic symbols
(`-L--export-dynamic`, which the sparkles unittest configs already pass on
linux-ldc):

1. **`__tsan_on_finalize(int failed)`** — resolved by `dlsym(RTLD_DEFAULT,
"__tsan_on_finalize")`, not weak linking ([`tsan_platform_posix.cpp:76-80`][llvm-src]);
   its return value decides the exit verdict, contract verbatim
   ([`tsan_interface.h:175-178`][llvm-src]):

   > `Return 0 if TSan should exit as if no issues were detected. Return nonzero if TSan should exit as if issues were detected.`

   A D `extern (C) int __tsan_on_finalize(int)` returning 0 turned a raced run's exit
   66 into exit 0 `[hw-verified: x86_64-linux]` (Experiment E8).

2. **`__tsan_on_report`** — a weak per-report callback invoked for every report just
   before the `halt_on_error` check ([`tsan_rtl_report.cpp:48-50,715`][llvm-src]);
   `nm` shows it `W` in GCC `libtsan`. A D override incrementing a `shared uint` gave
   exact per-window counts (racy window 1, clean window 0) `[hw-verified: x86_64-linux]`.
3. **`__tsan_default_options` / `__tsan_default_suppressions`** — a D
   `__tsan_default_options()` returning `"atexit_sleep_ms=0"` was consumed (`help=1`
   shows `Current Value: 0` vs 1000 in a plain binary) `[hw-verified: x86_64-linux]`.

Without `--export-dynamic` none of these fire. `[hw-verified: x86_64-linux]`

### Symbolization and suppressions

GCC's `libtsan` **self-symbolizes** via `libbacktrace` — no `llvm-symbolizer`
needed (a consequence of [runtime selection][selection]) — but it does **not
demangle D**: symbols print mangled (`_D2rt8monitor_9lockMutex…`), and sparkles
frames still resolve to `runner_impl.d:564` etc. `[hw-verified: x86_64-linux]`. The
practical consequence is that a D [suppression][suppression] glob must target
**mangled** text.

A suppression file is named by `TSAN_OPTIONS=suppressions=<path>` and parsed at
runtime init; two compile/link-time channels also exist (the weak
`__tsan_default_suppressions()` and hard-coded `std_suppressions` for libstdc++,
[`tsan_suppressions.cpp:26-40,52-61`][llvm-src]). Suppression types are `race`,
`race_top`, `mutex`, `thread`, `signal`, `called_from_lib`, `deadlock`
([`tsan_suppressions.h:20-27`][llvm-src]) — note that `signal:` covers both
signal-unsafe and errno-in-signal reports, which is why the druntime noise floor
needs a `signal:` entry, not just `race:`. A `race:` pattern is matched against the
**function, file, and module of every frame** of a reported stack. The pattern
language is `TemplateMatch` ([`sanitizer_common.cpp:229-262`][llvm-src]): plain text
is a **substring** match, `*` is a wildcard, `^` anchors the start, `$` anchors the
end — **not** a regex. So the two-line druntime file above reads: silence any report
whose signal frame is `thread_suspendHandler`, and any race any of whose frames
mangles-prefix-matches `_D2rt8monitor` `[hw-verified: x86_64-linux]` (Experiment E4d).

On the GCC-vs-compiler-rt flag surface: `TSAN_OPTIONS=help=1` against GCC 15.2
`libtsan` lists 114 flags; every flag checked (`halt_on_error`, `exitcode`,
`report_atomic_races`, `detect_deadlocks`, `history_size`, `suppressions`,
`log_path`, `atexit_sleep_ms`) matches compiler-rt's defaults — only the new
`adaptive_delay*` family (compiler-rt HEAD) is absent, as expected for a periodic
merge `[hw-verified: x86_64-linux]` `[source-verified]`.

### Test-runner integration semantics

The runner-facing results collapse to four facts and one transferable design.

**The recorded `DFLAGS` recipe is a silent false green.** On dub 1.42.0-beta.1,
`DFLAGS="-fsanitize=thread -allinst" dub test` prints `Performing "$DFLAGS" build`
and **replaces** the `unittest` buildType's flags — `-unittest` and `-g` vanish. The
binary links `libtsan` yet contains **zero** unittests (`nm | grep -c unittest_L` =
0), the discovery shim's `version (unittest):` hook never registers, druntime prints
`All unit tests have been run successfully.`, exit 0 `[hw-verified: x86_64-linux]`
(Experiment E4a). Adding `-unittest` to `$DFLAGS` does not repair it — the flag
propagates verbatim to every dependency and breaks `core-cli`'s library config
(`box.d(784): Error: unable to read module string`). The working channel is the
custom buildType (Concern 2). This false-green story is
[sparkles-baseline.md][baseline]'s to tell in full; here it is one sentence and a
link.

**`-t 1` gives a green, warning-free run.** Same instrumented binary: `-t 1` → **0
warnings, exit 0, 20.7 ms**; default parallelism → 32 warnings, exit 66, ~47 ms
`[hw-verified: x86_64-linux]` (Experiment E4d). Single-threading the _runner_
silences the druntime stop-the-world noise entirely, while tests that spawn their
own threads stay fully checked (the probe proves it). This is the evidence for a
**`-t 1`-default policy** under `--sanitize=thread` (or `-t 1` plus the two-line
suppression file for a parallel run) — and, combined with the livelock above, `-t 1`
is not merely quieter but _safer_.

**dub launders the exit code.** A test binary exiting 66 makes dub print
`Error Program exited with code 66` and itself exit **2** — a runner or CI consuming
`dub test`'s exit code cannot distinguish "tests failed" from "TSan reported". Run
the built binary directly to preserve 66, or capture reports in-process
`[hw-verified: x86_64-linux]`.

**The Go seam, as a runtime mechanism.** Go's `go test -race` is the gold-standard
per-test [report windowing][windowing] design, and its runtime seam transfers to D
wholesale. Go's runtime is a **prebuilt** TSan pinned to an exact LLVM commit and
checked into the tree ([`race/README:1-3`][go-src]):

> `runtime/race package contains the data race detector runtime library. It is based on ThreadSanitizer race detector, that is currently a part of the LLVM project.`

`[source-verified]` The windowing chain is: `race.Errors()` polls the runtime report
counter via `racecall(&__tsan_report_count, …)` ([`race.go:48-52`][go-src]); the
testing package snapshots it per test with `t.resetRaces()` immediately before the
test body ([`testing.go:2185-2186`][go-src]) and `t.checkRaces()` in `tRunner`'s
deferred epilogue ([`:2158`][go-src]); `checkRaces` ([`testing.go:1847-1885`][go-src])
CAS-updates `lastRaceErrors` and on the first delta fails **the test, not the
process**:

```go
if c.raceErrorLogged.CompareAndSwap(false, true) {
    c.Errorf("race detected during execution of test")
}
```

Attribution is a count-delta over the test's time window, and Go documents its own
limit honestly ([`testing.go:1944-1947`][go-src]): a background goroutine racing while
a test is paused means "we will misattribute the background race to some other test,
or to no test at all" — the caveat any D port should copy. Go's exit protocol
matches: `racefini()` runs only on otherwise-clean exit paths (`if raceenabled {
racefini() }` at `main` return and `if exitCode == 0 && raceenabled` in
`os_beforeExit`, [`proc.go:330-348`][go-src]), so a failed `go test` exits 1 through
`os.Exit(1)`, _bypassing_ `__tsan_fini`; 66 is only the backstop for a program that
would otherwise exit 0 with unhandled reports.

**The D reproduction — the centerpiece.** The entire pattern runs from D today
against GCC `libtsan`, with **one substitution**: GCC `libtsan` does not export
`__tsan_report_count` (it is `SANITIZER_GO`-only), but the weak `__tsan_on_report`
callback substitutes fully. Overriding `__tsan_on_report` to count into a `shared
uint`, snapshotting it around two windows, and defining `__tsan_on_finalize` to own
the exit gave exact per-window counts and a clean exit 0
`[hw-verified: x86_64-linux]` (Experiment E8b). It works because the sparkles
unittest configs already pass `lflags "--export-dynamic"` — a lucky, load-bearing
coincidence worth stating in the proposal. The one caveat carries over from Go:
`suppress_equal_stacks` dedup means counting attributes each unique race to the first
test that exhibits it. The go-test _CLI/UX_ layer and the cross-language comparison
(cargo-nextest's [process-per-test][process-per-test], SwiftPM, CTest, pytest-valgrind)
are [runner-integrations.md][runner-integrations]'s; this page owns the seam.

### Platform, toolchain, and overhead

In D-land TSan is **LDC-only**: LDC accepts `-fsanitize=thread` and predefines
`version (LDC_ThreadSanitizer)` ([`driver/main.cpp:1032`][ldc-src], binary-confirmed
in `-v` predefs) `[hw-verified: x86_64-linux]` `[source-verified]`. **DMD** has no
`-fsanitize` at all — Valgrind's [`helgrind`/`DRD`][valgrind] are DMD's only
race-detection path (and both have their own limits). **GDC** inherits GCC's
`-fsanitize=thread`, but its D-frontend story is covered in
[d-toolchain.md][d-toolchain]. **macOS** (LDC via clang runtimes) is deferred to
[macos-windows.md][macos-windows].

Overhead on the `:versions` suite (runner-reported): plain **8.8 ms** parallel /
4.5 ms `-t 1`; TSan **46.9–49.1 ms** parallel / 20.7 ms `-t 1` — **≈ 5×**
`[hw-verified: x86_64-linux]`, at the low end of the documented 5–15× because the
tests are tiny. Memory cost is the structural 2× shadow plus a full per-thread
`ThreadState`. See [d-toolchain.md][d-toolchain] for the `buildType` channel that
makes any of this reachable, and [comparison.md][comparison] for TSan's row in the
overhead/exit-code matrix.

---

## Strengths

- **Reachable from LDC for free.** As an [LLVM IR pass][locus], TSan needs no D
  frontend work — the flag is already plumbed, and `version (LDC_ThreadSanitizer)`
  lets probes self-detect.
- **Correct `core.atomic` modeling.** D atomics lower to real LLVM atomics, which
  the pass rewrites to `__tsan_atomic*` and models as synchronization — so TSan is a
  precise checker of whether `shared` data is actually synchronized.
- **Small, suppressible druntime noise.** 167 tests, two noise classes, a two-line
  suppression file — or `-t 1` for zero warnings. The runner's own machinery adds
  nothing.
- **Report-and-continue by default**, so in-process per-test windowing needs no
  recover flag; the runner-facing seams (`__tsan_on_report` / `__tsan_on_finalize` /
  `__tsan_default_options`) all work today given `--export-dynamic`.
- **A proven integration design to copy** — Go's `checkRaces` count-delta windowing,
  reproduced from D end-to-end.
- **Fibers are sound** without any druntime annotation, and real races in fiber code
  are caught with usable, correctly-symbolized stacks.

## Weaknesses

- **GC-heavy multi-threaded code deterministically livelocks** — a hang, not a
  report. The hard ceiling; needs a watchdog and a `-t 1` policy.
- **No D demangling** in the GCC runtime — reports and suppression globs are in
  mangled names.
- **Deadlock detection does not really work** (generation-1 detector, disabled even
  in Go); TSan is a race detector only.
- **`DFLAGS` is a silent false green** on current dub, and **dub launders exit 66 to
  2** — both trip the naive integration.
- **Blind to fence-only lock-free protocols and to use-after-free inside GC memory**
  ([the GC blind spot][gc-blind-spot]).
- **~5× time and 2× memory**, and a serialized schedule can order a real race away
  into a false negative.

## Key design decisions and trade-offs

| Decision                                                   | Rationale                                                                        | Trade-off                                                                                       |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| v3 shadow: four 32-bit `Sid`+epoch cells per granule       | 2× memory (vs v2's larger cells), dynamic trace growth (`history_size=0`)        | The public algorithm wiki still documents v2 — guidance and mental models drift from the source |
| `halt_on_error=false` (report-and-continue) by default     | In-process per-test windowing works with no `-fsanitize-recover`                 | "Nonzero exit = failed" no longer holds; exit is 66 only at `Finalize`, and dub launders it     |
| Model `core.atomic` (real LLVM atomics) as synchronization | Correctly-synchronized `shared` data is silent; only genuine races report        | Fence-only lock-free protocols, which carry no atomic on the object, can be mis-ordered         |
| Leave druntime/Phobos uninstrumented                       | User code is checkable without rebuilding the world (no instrumented-world need) | A small errno-in-signal + monitor noise floor, and the GC stop-the-world **livelock**           |
| GCC-runtime self-symbolization via `libbacktrace`          | No `llvm-symbolizer` dependency in the toolchain                                 | No D demangling — reports and suppression globs must target mangled names                       |
| Windowing seam (`__tsan_on_report` / `__tsan_on_finalize`) | The Go per-test design reproduces from D, needing only `--export-dynamic`        | `__tsan_report_count` is Go-only; dedup means unique races attribute to the first test          |

---

## Sources

- compiler-rt TSan runtime, read at [llvm-project `73802c2e`][llvm-src]:
  `lib/tsan/rtl/{tsan_shadow.h, tsan_defs.h, tsan_flags.inc, tsan_flags.cpp,
tsan_interface.cpp, tsan_suppressions.{cpp,h}, tsan_rtl.cpp, tsan_rtl_report.cpp,
tsan_rtl_thread.cpp, tsan_platform_posix.cpp}`, `include/sanitizer/tsan_interface.h`,
  and `lib/sanitizer_common/{sanitizer_flags.inc, sanitizer_common.cpp,
sanitizer_deadlock_detector.h}` — all quoted/cited above
- Go's prebuilt-TSan seam, read at [go `0153438`][go-src]: `src/runtime/race/README`,
  `src/runtime/race.go`, `src/runtime/proc.go`, `src/testing/testing.go`
- [LDC][ldc-src] `driver/main.cpp` (the `LDC_ThreadSanitizer` predefine)
- GCC 15.2 `libtsan.so.2` — `nm -D` symbol audit and `TSAN_OPTIONS=help=1` flag dump
  (the linked runtime on this box)
- Runnable probe: [`tsan-data-race.d`][probe] — the racy-vs-`core.atomic` catch
  (Experiments E1/E3), child-process pattern, DMD-SKIP
- Related pages: [d-toolchain.md][d-toolchain] (buildType channel, `SupportSanitizers`),
  [valgrind.md][valgrind] (`helgrind`/`DRD`, DMD's path),
  [runner-integrations.md][runner-integrations] (the go-test UX layer),
  [sparkles-baseline.md][baseline] (the false-green story), [comparison.md][comparison]
- Shared vocabulary: [concepts.md][concepts] ([happens-before][hb],
  [interceptor][interceptor], [fiber annotation][fiber], [halt vs recover][halt],
  [weak-hook control surface][weak-hooks], [suppression][suppression], [report
  windowing][windowing], [stop-the-world root scanning][stw], [the GC memory blind
  spot][gc-blind-spot])

<!-- References -->

[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[selection]: ./concepts.md#sanitizer-runtime-selection
[interceptor]: ./concepts.md#interceptor
[alloc]: ./concepts.md#allocator-interception
[hb]: ./concepts.md#vector-clocks-and-happens-before
[shadow]: ./concepts.md#shadow-memory
[fiber]: ./concepts.md#fiber-annotation
[halt]: ./concepts.md#halt-vs-recover
[weak-hooks]: ./concepts.md#weak-hook-control-surface
[suppression]: ./concepts.md#suppression
[windowing]: ./concepts.md#report-windowing
[process-per-test]: ./concepts.md#process-per-test-isolation
[stw]: ./concepts.md#stop-the-world-root-scanning
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[instrumented-world]: ./concepts.md#instrumented-world-requirement
[asan]: ./asan.md
[d-toolchain]: ./d-toolchain.md
[valgrind]: ./valgrind.md
[runner-integrations]: ./runner-integrations.md
[macos-windows]: ./macos-windows.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[probe]: ./examples/tsan-data-race.d
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[go-src]: https://github.com/golang/go/tree/015343854b5d9e2829481df30dbcae2ca6682d25
[ldc-src]: https://github.com/ldc-developers/ldc/tree/90e39b6a6e61d36ef5f5d0ab6ae0667130fd8549
