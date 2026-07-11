# Sanitizers Concepts

The shared vocabulary of the sanitizers survey. Every term is defined **once**,
here; the [deep-dives][index] link back to these definitions instead of
re-explaining them. The reference model is the LLVM `compiler-rt` stack
(`asan`/`lsan`/`tsan`/`msan`/`ubsan`/`hwasan`/`gwp_asan`, read in
[d-toolchain.md][d-toolchain] and the tool pages) together with the Valgrind
family ([valgrind.md][valgrind]); per-tool, per-toolchain (LDC/GDC/DMD), and
per-OS variations are noted where they exist. Definitions are grounded in the
tool sources and the survey's own experiments; the D and druntime consequences
that make a term load-bearing for a **test runner** are called out inline.

**Last reviewed:** July 11, 2026

---

## Instrumentation and runtimes

### Instrumentation locus

_Where_ a sanitizer's checks are injected — the taxonomy that decides which D
compiler can reach a tool at all. Five loci recur across the survey:

- **LLVM IR pass** — a transform registered at the optimizer tail
  (`AddressSanitizer`, `ThreadSanitizer`, `MemorySanitizer`, `HWAddressSanitizer`,
  `RealtimeSanitizer`). Because it runs on IR, _any_ LLVM frontend inherits it, so
  LDC gets it "for free" once the flag is plumbed. See [d-toolchain.md][d-toolchain].
- **Clang-CodeGen-only** — checks emitted inline by clang's C/C++ frontend, with
  **no IR pass** to borrow (`UndefinedBehaviorSanitizer`'s `EmitCheck` sites; the
  `!tbaa` metadata `TypeSanitizer` consumes). A non-clang frontend has nothing to
  switch on, which is exactly why UBSan and TySan are **unreachable** from LDC and
  from GDC's D frontend. See [ubsan.md][ubsan] and [hardware-assisted.md][hardware-assisted].
- **Binary translation** (dynamic binary instrumentation, DBI) — a JIT re-translates
  every machine instruction at run time (Valgrind's VEX, Dr. Memory's DynamoRIO).
  Nothing is recompiled; this is what makes Valgrind DMD's only path. See
  [valgrind.md][valgrind].
- **Hardware-assisted** — the CPU itself performs the check against
  [memory tags](#memory-tagging) (Arm MTE), with little or no code instrumentation.
- **Sampling allocator** — a drop-in `malloc` replacement that guards a random
  fraction of allocations (GWP-ASan), instrumenting no code. See [the
  sampling allocator](#sampling-allocator).

The locus is the first thing every tool page states, and the axis
[comparison.md][comparison] cuts the capability matrix along.

### Sanitizer runtime selection

An IR-instrumented object is inert until it links a **runtime library** that owns
the shadow, interceptors, allocator, and reporting. The two implementations are
LLVM `compiler-rt` and **GCC's `libsanitizer`**, a periodically-merged, ABI-compatible
fork of it — objects built by an LLVM-18 pass link and run against either, because
the ABI is gated by a version symbol (`__asan_version_mismatch_check_v8`). Which one
you get is a packaging accident: the nixpkgs LDC ships _no_ `compiler-rt`, so LDC's
documented gcc link fallback hands `-fsanitize=` to `gcc` and links GCC's
`libasan.so`/`libtsan.so` — which self-symbolize via `libbacktrace` (no
`llvm-symbolizer` needed) but never demangle D names. Real `compiler-rt` can be
restored with an edited `ldc2.conf`, at the cost of needing `llvm-symbolizer` again.
Go takes the extreme case: it checks a **prebuilt** TSan runtime, pinned to an exact
LLVM commit, into its own tree. Neither runtime demangles D, so reports and
[suppressions](#suppression) both work in mangled names. See
[d-toolchain.md][d-toolchain].

### Interceptor

A function the runtime **interposes** in front of a libc/pthread entry point
(`malloc`, `free`, `memcpy`, `strcpy`, `pthread_create`, …) so it can update shadow,
model synchronization, or check arguments before delegating. ASan defines dozens of
explicit interceptors plus a large shared table; TSan models `pthread_mutex_*` and
thread create/join as [happens-before](#vector-clocks-and-happens-before) edges
through interceptors. Uninstrumented code is seen _only_ through this interceptor
layer — a load or store the compiler never rewrote is invisible. On Linux
interception is ELF symbol interposition; on Windows it is runtime **hotpatching** of
function prologues, which can fail on a too-short prologue and deliberately
`debugbreak` (see [macos-windows.md][macos-windows]). Valgrind achieves the same
effect structurally, by translating every instruction.

### Allocator interception

The special case of [interception](#interceptor) that replaces the heap allocator:
`malloc`/`free` route through the sanitizer's own allocator so every heap block
carries [redzones](#redzone) and a [quarantine](#quarantine) history. The load-bearing
consequence is what it _cannot_ see: memory obtained directly from the kernel with
`mmap` never passes through the intercepted allocator, so it has no shadow state and
no allocation metadata. This is not a bug but the boundary of the technique — and in
D it collides head-on with the garbage collector (see [the GC memory blind
spot](#the-gc-memory-blind-spot)).

### The GC memory blind spot

D's garbage collector obtains its pools with `mmap` (`core/internal/gc/os.d`), not
`malloc`, so GC memory sits _outside_ every sanitizer allocator. Two D-specific
consequences follow, and they recur on every memory tool in the survey. First, a
**use-after-free inside GC memory is invisible**: ASan, `memcheck`, HWASan, and
GWP-ASan all see nothing, because the GC's own free never poisons any shadow they
own — even a fully ASan-instrumented druntime cannot close this, since GC memory
never reaches ASan's allocator. `[hw-verified: x86_64-linux]` Second, a `malloc`
block reachable _only_ through a pointer stored in GC memory is a **LeakSanitizer
false positive** ("Direct leak"): LSan's [root scan](#stop-the-world-root-scanning)
follows pointers through registered allocator chunks only, so a pointer that lands
inside a GC pool terminates the walk. `[hw-verified: x86_64-linux]` The `memcheck`
half of the blind spot is closable without rebuilding druntime — compile the shipped
`gc.d` plus `etc/valgrind/valgrind.d` into the program with `-debug=VALGRIND` (see
[the client request](#client-request)). See [d-toolchain.md][d-toolchain],
[asan.md][asan], [valgrind.md][valgrind], and [hardware-assisted.md][hardware-assisted].

### Instrumented-world requirement

MemorySanitizer's defining constraint: because it tracks
[definedness](#definedness-vs-addressability) by _propagating_ shadow through
compiled code, **all** code that touches memory must be instrumented — the program,
every library it links, and libc. An uninstrumented function that writes a value
leaves stale poison behind, which surfaces later as a false "use of uninitialized
value". The runner consequence is concrete: MSan is unusable for D by default because
druntime and Phobos ship uninstrumented, so the honest finding is "MSan needs an
instrumented druntime+Phobos world we do not build," not a TODO. Contrast ASan and
TSan, where instrumenting only user code costs _coverage_ of the uninstrumented
frames, not correctness. See [d-toolchain.md][d-toolchain] and the MSan column of
[comparison.md][comparison].

---

## Shadow memory and the memory-error model

### Shadow memory

An out-of-band map from each application byte to metadata the runtime consults on
every access. The scale is the tool's fingerprint: ASan keeps **1 shadow byte per 8
app bytes** (a byte encodes how many of the eight are addressable, plus poison
markers like `0xfa` heap-left-redzone, `0xfd` freed, `0xf5` stack-after-return);
MSan keeps a **bit-exact 1:1** shadow (poison = uninitialized); TSan v3 keeps four
32-bit cells per 8-byte granule (**2×** app memory); `memcheck` compresses **2 bits
per byte** (see [definedness vs addressability](#definedness-vs-addressability));
[HWASan](#memory-tagging) keeps **1 tag byte per 16-byte granule**; TySan keeps **8
shadow bytes per byte** (a type-descriptor pointer). The shadow is what an
uninstrumented load never updates — the root of both the
[instrumented-world requirement](#instrumented-world-requirement) and the [GC memory
blind spot](#the-gc-memory-blind-spot).

### Redzone

Poisoned guard bytes ASan inserts around each heap and global allocation (default 16
bytes, growable to 2048) and between stack locals. An access that lands in a redzone
is a buffer overflow, caught immediately. The limit is precise: an overflow that
overshoots the redzone into a _valid_ neighbouring object is missed, and `memcheck`
has no redzones at all, so it cannot catch a small overrun _within_ an allocation the
way ASan can. Redzone size trades detection distance against memory overhead.

### Quarantine

A FIFO of recently-freed heap chunks (ASan default 256 MB) that the allocator refuses
to recycle, so their shadow stays poisoned and a
[use-after-free](#the-gc-memory-blind-spot) is caught. It is a _detection window_:
once a chunk is evicted from quarantine and its address reused, the same
use-after-free becomes invisible. Larger quarantine widens the window at the cost of
resident memory. Valgrind's analogue is `--freelist-vol`.

### Fake stack and stack-use-after-return

To detect a pointer to a local that escapes its frame, ASan can move address-taken
locals off the real stack into heap-allocated **fake stack** frames that stay
poisoned (`0xf5`) after the function returns; a later read through the escaped
pointer then hits poison. The behaviour is runtime-gated by
`detect_stack_use_after_return` (compile default "runtime"; the GCC runtime defaults
it **on**, `clang_rt` on Linux enables it too). For D this cuts both ways: the flagship
fiber stack-use-after-return catch works out of the box because the faulting read is
in instrumented user code, but a conservative GC must learn to scan fake-stack frames
(`scanStackForASanFakeStack`) or references living only there can be collected — and
no shipped druntime does. See [d-toolchain.md][d-toolchain] and
[fiber annotation](#fiber-annotation).

### Definedness vs addressability

The axis that separates `memcheck` from ASan. ASan's shadow encodes
**addressability** only — _may the program touch this byte_ (is it mapped, not in a
redzone, not freed) — so it can never report the use of an _uninitialized_ value.
`memcheck` additionally tracks **definedness**: eight **V-bits** per byte (is each
value bit defined) beside one **A-bit** (addressability), which is where its
`UninitCondition`/`UninitValue` reports come from and why it catches a class ASan
structurally cannot. MemorySanitizer is the third point — compile-time definedness
with a bit-exact [shadow](#shadow-memory), subject to the
[instrumented-world requirement](#instrumented-world-requirement). See
[valgrind.md][valgrind] for the V-bit/A-bit machinery and
[comparison.md][comparison] for the per-cell verdicts.

---

## The concurrency model

### Vector clocks and happens-before

The primitive under every data-race detector. Synchronization events (mutex
lock/unlock, atomics, thread create/join) impose a partial order — the
**happens-before** relation — tracked with per-thread **vector clocks**; two accesses
to the same location from different threads with **no** happens-before edge between
them are a race. TSan v3 records, per [shadow](#shadow-memory) cell, the accessing
thread slot (`Sid`), an epoch, and read/atomic bits, and models `core.atomic` (which
LDC lowers to real LLVM atomics) as synchronization, so a racy plain counter is caught
while its atomic fix is silent. Valgrind's `helgrind` and `DRD` are also
happens-before vector-clock detectors, but they model _pthread_ primitives, not raw
atomics, so D's `core.internal.spinlock`-built and `core.atomic`-built locks are
invisible to them and everything under a GC `SpinLock` looks racy under `-t > 1`.
Every such detector shares one blind spot: a serialized scheduler (Valgrind, or a
short test where one thread finishes before another starts) can order-away a genuine
race into a false negative. See [tsan.md][tsan] and [valgrind.md][valgrind].

---

## Hardware-assisted and sampling variants

### Memory tagging

Tag a pointer and the memory it points at with a small value, and check them on every
access. **HWASan** does this in software: 1 tag byte per 16-byte granule, the tag
carried in the pointer's unused top bits — aarch64 **TBI** (top-byte-ignore, 8 tag
bits), `x86_64` Intel **LAM** (6 bits, Intel-only; fatal on AMD, which has no LAM), or
`x86_64` page-**aliasing** mode (3 bits, heap-only, fork-unsafe but runnable on this
box). `[hw-verified: x86_64-linux]` **Arm MTE** does it in hardware: a 4-bit
allocation tag per 16-byte granule held in physical memory and checked by the CPU,
built on TBI, selected per thread as **SYNC** (a precise `SIGSEGV` at the faulting
address) or **ASYNC** (delayed, `si_addr = 0` — the faulting address is unknown by
design, so precise per-access reports are not available). Two D consequences: a
conservative GC scan reads tagged memory through an _untagged_ pointer and trips a
tag-mismatch `[hw-verified: x86_64-linux]`, and LDC cannot emit `-fsanitize=hwaddress`
today. No MTE silicon is in reach (Apple's M4 has none). `[literature]` See
[hardware-assisted.md][hardware-assisted].

### Sampling allocator

A production-grade allocator (GWP-ASan) that places a random **1/`SampleRate`**
fraction of allocations on guard pages, so an overflow or use-after-free on a _sampled_
allocation faults with full allocation and deallocation stacks, at near-zero amortized
overhead. It is the inverse of a test-time tool: detection is probabilistic, so it is
the right tool for a production fleet and the _wrong_ tool for deterministic unit
tests. It is reachable via `-fsanitize=scudo`, hooks into a host `malloc`, and — like
every [allocator interceptor](#allocator-interception) — sees only C-heap traffic,
never D GC memory (see [the GC memory blind spot](#the-gc-memory-blind-spot)). See
[hardware-assisted.md][hardware-assisted].

---

## The D and druntime interaction surface

### Stop-the-world root scanning

Both LeakSanitizer and D's GC must freeze every thread and conservatively scan its
stack and registers for pointers — but by different mechanisms, and the mismatch is a
hazard. LSan `clone()`s a tracer task and `ptrace(PTRACE_ATTACH)`es every thread:
non-cooperative, no signal handlers involved. D's GC suspends the world with a
**signal handshake** (`thread_suspendAll`). Under TSan, that signal handshake
**deterministically livelocks** once two or more mutator threads are suspended
mid-runtime (TSan wraps and defers async signals) — a hang with no report, the worst
possible CI outcome, and the concrete reason Go instruments a cooperating runtime
instead. `[hw-verified: x86_64-linux]` A `--sanitize=thread` mode therefore needs a
watchdog and a `-t 1` policy. See [tsan.md][tsan] and [d-toolchain.md][d-toolchain].

### Fiber annotation

The API a coroutine runtime calls to tell a sanitizer that the stack pointer has
jumped to a _different_ stack, rather than grown by an implausible amount:
`__sanitizer_start_switch_fiber`/`__sanitizer_finish_switch_fiber` (ASan),
`__tsan_create_fiber`/`__tsan_switch_to_fiber` (TSan), `VALGRIND_STACK_REGISTER`
(Valgrind). Without it a tool may mistake a switch for enormous stack motion, corrupt
a neighbouring fiber's shadow, or lose [fake-stack](#fake-stack-and-stack-use-after-return)
GC roots. The survey's finding is that **druntime calls none of these in any shipped
build**, yet basic fiber operation is sound anyway — a stack-use-after-return is
caught, a real race in fiber code is caught — because the faulting access is in
instrumented user code and interceptor-visible handoffs order the switches. The API's
value is fiber _identity_ in reports, correctness under runtime-internal handoffs, and
GC scanning of fake stacks. See [d-toolchain.md][d-toolchain] and [tsan.md][tsan].

---

## Runtime control and report capture

### Halt vs recover

Whether a tool dies on the first finding or reports and continues — the policy a
runner must own, because the tools disagree and their exit codes differ. ASan halts by
default (`halt_on_error` true); surviving a finding needs _both_ the compile-time
`-fsanitize-recover=address` and the runtime `halt_on_error=0`, and a recovered ASan
run **exits 0**, so report capture must count reports, not read exit codes. TSan is
report-and-continue by default and only flips the process exit at finalize.
`abort_on_error` raises `SIGABRT` instead of exiting (default on Apple and Android, so
darwin ASan yields shell exit 134). The per-tool defaults are irreconcilable — a
`--sanitize` mode cannot assume "nonzero exit = failed test":

| Tool / mode                         | Default on finding                      | Exit code                                     | Verified                        |
| ----------------------------------- | --------------------------------------- | --------------------------------------------- | ------------------------------- |
| ASan (integrated LSan)              | halt                                    | 1                                             | `[hw-verified: x86_64-linux]`   |
| LeakSanitizer, standalone           | report at exit                          | 23                                            | `[hw-verified: x86_64-linux]`   |
| TSan                                | report-and-continue                     | 66 (at finalize)                              | `[hw-verified: x86_64-linux]`   |
| HWASan                              | halt                                    | 99                                            | `[hw-verified: x86_64-linux]`   |
| RTSan (`-fsanitize=realtime`)       | halt (`halt_on_error` true)             | 43                                            | `[hw-verified: x86_64-linux]`   |
| TySan (`-fsanitize=type`)           | continue (`halt_on_error` false)        | 0                                             | `[hw-verified: x86_64-linux]`   |
| GWP-ASan (via `-fsanitize=scudo`)   | `SIGSEGV` (non-recoverable)             | 139                                           | `[hw-verified: x86_64-linux]`   |
| Valgrind                            | continue, all findings in one pass      | `--error-exitcode` (opt-in; else child's own) | `[hw-verified: x86_64-linux]`   |
| ASan on Darwin (`abort_on_error=1`) | abort                                   | 134                                           | `[hw-verified: aarch64-darwin]` |
| MSVC ASan (`continue_on_error`)     | continue (runtime env, no compile flag) | app's own                                     | `[literature]`                  |

See [asan.md][asan], [tsan.md][tsan], [valgrind.md][valgrind], and the
overhead/exit-code tables in [comparison.md][comparison].

### Weak-hook control surface

The set of weak symbols and setters a runtime lets the _program_ define to steer its
options, capture its reports, and own its exit — the runner-facing seam. The load-bearing
ones: `__asan_default_options`/`__tsan_default_options` (return an options string,
overridden by the environment); `__asan_set_error_report_callback` (hands the full
report text to a D handler _before_ `Die()` — but `Die()` does not flush stdio, so the
handler must write-and-close its own sink); `__sanitizer_set_death_callback`;
`__tsan_on_report` (a weak per-report callback, the basis of count-delta
[windowing](#report-windowing)); `__tsan_on_finalize` (`dlsym`-resolved, return 0 to
force a clean exit); and `log_path`, which routes each process's report to a
PID-suffixed `path.<pid>` file. These fire only if the executable exports its dynamic
symbols (`--export-dynamic`, which the sparkles unittest configs already pass). See
[asan.md][asan], [tsan.md][tsan], and [integration-proposal.md][proposal].

### Client request

Valgrind's in-band annotation channel, and its recompile-free counterpart to the
[weak-hook surface](#weak-hook-control-surface). A magic no-op instruction sequence (a
register-rotation preamble plus an `xchg`) that Valgrind's JIT recognizes and traps,
passing arguments in registers — so an unmodified binary can talk to the tool.
`VALGRIND_PRINTF` (stream markers for per-test [attribution](#wrapper-and-parse)),
`VALGRIND_STACK_REGISTER` (see [fiber annotation](#fiber-annotation)), `MAKE_MEM_*`,
`DO_LEAK_CHECK`, `COUNT_ERRORS`, and `RUNNING_ON_VALGRIND` are the load-bearing ones.
druntime's `etc.valgrind` wraps seven `memcheck` requests, gated `debug(VALGRIND)`,
with the C side prebuilt into the shipped runtime and the D side needing
`-i=etc.valgrind` — the mechanism that closes the [GC memory blind
spot](#the-gc-memory-blind-spot) for `memcheck` without a druntime rebuild. See
[valgrind.md][valgrind].

### Suppression

A pattern that silences a known-benign or false finding, in one of two formats.
compiler-rt uses a **one-line** `type:pattern` (e.g. `race:_D2rt8monitor*`), where
the pattern is a substring/glob (`TemplateMatch`: `*`, `^`, `$` — not a regex) matched
against the function, file, and module of _every_ frame of a reported stack, and the
file is named by `*SAN_OPTIONS=suppressions=`. Valgrind uses a multi-line **block**
(`{ name; Tool:Kind; fun:/obj: frames; ... }`), which `--gen-suppressions` emits
ready to paste. Both match **mangled** D names, because the runtimes self-symbolize but
do not demangle (and `--gen-suppressions` writes mangled `fun:` frames), so a D
suppression glob must target mangled text. CTest is the only surveyed runner with a
first-class checked-in suppression-file setting. See [tsan.md][tsan],
[valgrind.md][valgrind], and [runner-integrations.md][runner-integrations].

---

## Per-test attribution

### Report windowing

The **in-process** attribution design: poll a runtime error counter (or receive a
[weak callback](#weak-hook-control-surface)) immediately before and after each test's
body, and attribute the count _delta_ to the currently-running test. Go's `go test
-race` is the gold standard (its `checkRaces` fails the _test_, not the process);
googletest's documented integration overrides `__tsan_on_report`/`__asan_on_error` to
call `FAIL()`; pytest-valgrind takes `VALGRIND_COUNT_ERRORS` deltas — and all three
were reproduced from D. It keeps one process and one build but needs
[continue-semantics](#halt-vs-recover) (TSan by default, ASan via recover, Valgrind
always) and mis-attributes cross-test background activity (Go documents the hazard).
It is where sparkles' in-process `TaskPool` runner already sits; `-t 1` or per-worker
windows bound the attribution blur. See [runner-integrations.md][runner-integrations]
and [tsan.md][tsan].

### Process-per-test isolation

The design that makes attribution and crash containment fall out of the OS process
boundary: run each test in its own process, and any nonzero exit — TSan's 66, an ASan
`SIGABRT`, a segfault — is _that one test's_ failure and cannot cancel its siblings.
cargo-nextest ("now, and will always be, process-per-test"), SwiftPM's `--parallel`,
and Bazel at target/shard granularity all rely on it, and none need sanitizer-specific
configuration. It costs process spawn and forbids shared in-memory state. sparkles'
existing extract-and-recompile machinery (the `--better-c`/`--wasm` drivers) is most
of an `--isolate` mode and is exactly what closes the runner's current
"SEGV-kills-the-whole-run" gap. See [runner-integrations.md][runner-integrations],
[sparkles-baseline.md][baseline], and [integration-proposal.md][proposal].

### Wrapper-and-parse

The design that needs no cooperation from the payload: wrap each test invocation,
route the tool's output to a per-test sink — `log_path=MemoryChecker.<index>.log`, or
[`VALGRIND_PRINTF`](#client-request) markers, or `--xml` — then parse the sink into a
defect count and attribution. CTest's MemCheck mode is the industrial version
(regex-per-tool over per-test log files, with first-class suppression config);
pytest-valgrind's log side is the same idea. It composes with either of the other two
designs. The survey's `--valgrind` proposal is this pattern over Valgrind's XML
protocol 4, a stronger transport than regex-over-text. See
[runner-integrations.md][runner-integrations] and [valgrind.md][valgrind].

<!-- References -->

[index]: ./
[asan]: ./asan.md
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[valgrind]: ./valgrind.md
[runner-integrations]: ./runner-integrations.md
[macos-windows]: ./macos-windows.md
[hardware-assisted]: ./hardware-assisted.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./integration-proposal.md
