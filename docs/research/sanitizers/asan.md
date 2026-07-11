# AddressSanitizer + LeakSanitizer (LLVM `compiler-rt`)

The survey's **memory-error workhorse**: a shadow-memory + redzone tool that catches
heap/stack/global overflows, use-after-free, and stack-use-after-return, with
LeakSanitizer folded in as a leak detector that runs at exit — both fully usable from
LDC today, and both with sharp, D-specific blind spots at the garbage collector.

| Field                                          | Value                                                                                                                                        |
| ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Tools                                          | AddressSanitizer (ASan) + LeakSanitizer (LSan), one LLVM `compiler-rt` runtime family                                                        |
| [Instrumentation locus][locus]                 | **LLVM IR pass** (`AddressSanitizer.cpp`, optimizer tail) — inherited by any LLVM frontend, so LDC gets it "for free"                        |
| Reachable from                                 | **LDC** (`-fsanitize=address` / `-fsanitize=leak`); **not** DMD (no sanitizer flag), **not** nixpkgs GDC (see [d-toolchain.md][d-toolchain]) |
| [Runtime linked][runtime-selection] (this box) | **GCC 15.2 `libasan.so.8` / `liblsan.so.0`** via LDC's gcc link fallback — nixpkgs LDC ships **no** `compiler-rt`                            |
| [Shadow][shadow]                               | 1 byte per 8 app bytes; `Shadow = (Mem >> 3) + 0x00007fff8000`                                                                               |
| Versions                                       | LDC 1.41.0 (LLVM 18.1.8 pass) · runtime GCC 15.2 libsanitizer · source read compiler-rt [`73802c2e`][llvm-src]                               |
| Verification                                   | `[hw-verified: x86_64-linux]` — five runnable probes + experiments E1–E11                                                                    |

> [!NOTE]
> **LSan is folded into this page, not given its own.** It is the same runtime family,
> the same flag machinery, and its D story is one cross-cutting section
> ([LeakSanitizer and the D GC](#leaksanitizer-and-the-d-gc)) rather than a separate
> survey subject. All hardware claims here were recorded on **Linux 6.18.26**, an **AMD
> Ryzen 9 7940HX** (Zen 4), **LDC 1.41.0**, against **GCC 15.2**'s libsanitizer runtimes
> — the runtime nixpkgs LDC actually links (see concern 2).

> [!WARNING]
> **A three-way version skew, disclosed honestly.** The IR instrumentation is LDC's
> **LLVM 18.1.8** ASan pass; the **linked runtime is GCC 15.2's `libasan.so.8`** (a
> _newer_ compiler-rt merge — a strict API superset of compiler-rt 18, concern 2); the
> **source read for locators is compiler-rt HEAD [`73802c2e`][llvm-src]**. Every
> `path:line` below is against that HEAD; the runtime behaviour is GCC 15.2's and the
> instrumentation is LLVM 18's, and the two agree everywhere this page tested.

---

## Overview

### What it catches

ASan is an [allocator- and stack-instrumenting][allocator-interception] tool built on
[shadow memory](./concepts.md#shadow-memory): it maps every eight application bytes to one shadow
byte encoding their addressability, poisons [redzones][redzone] around every heap,
stack, and global object, and holds freed heap chunks in a [quarantine][quarantine] so
their poison outlives the `free`. An instrumented load or store that lands on poison is
a bug, reported immediately with allocation and (for freed memory) deallocation stacks.
The defect classes, all verified from D here:

- **heap-use-after-free** — reading a freed block while it sits in quarantine
  (`0xfd` poison; probe [`asan-heap-uaf.d`](./examples/asan-heap-uaf.d)).
- **heap / stack / global-buffer-overflow** — an access into a redzone
  (`0xfa` / `0xf1`–`0xf3` / `0xf9`; probe
  [`asan-global-overflow.d`](./examples/asan-global-overflow.d)).
- **stack-use-after-return** — a pointer to a local read after its frame returns,
  caught via the [fake stack](./concepts.md#fake-stack-and-stack-use-after-return) (`0xf5`; probe
  [`asan-stack-uar.d`](./examples/asan-stack-uar.d)).
- **memory leaks** — via the folded-in LSan (see
  [LeakSanitizer and the D GC](#leaksanitizer-and-the-d-gc)).

The load-bearing **blind spots** are also D-specific and recur across the survey:
uninstrumented frames (druntime/Phobos ship without instrumentation, so a bug whose
faulting access is entirely inside them is not seen — a coverage gap, _not_ a false
positive), and — the flagship D miss — **memory obtained from the GC**, which is
`mmap`'d rather than `malloc`'d and so never passes through ASan's allocator (see [the
GC memory blind spot][gc-blind-spot] and [d-toolchain.md][d-toolchain]).

### Design philosophy: instrument once, link any compatible runtime

ASan's ABI is deliberately versioned so that instrumented objects and the runtime are
decoupled — the property that makes LDC's use of _GCC's_ runtime sound. From the
runtime's own header ([`lib/asan/asan_init_version.h:20-23`][llvm-src]):

> "Every time the ASan ABI changes we also change the version number in the `__asan_init`
> function name. Objects built with incompatible ASan ABI versions will not link with
> run-time."

`[source-verified]` This is load-bearing: because the ABI is gated by a single version
symbol (`__asan_version_mismatch_check_v8`) rather than a matching build, an object
emitted by the LLVM-18 pass links and runs against _any_ runtime that exports `_v8` —
GCC 15.2's `libasan.so.8` or a realized compiler-rt 18 alike (concern 2). ASan's cost is
modest by design — the docs quote a "typical slowdown … of **2x**"
([`clang/docs/AddressSanitizer.rst:24`][clang-asan]) `[literature]` — which is what makes
it a unit-test-time tool rather than a production one.

---

## How it works

### Heap poisoning, redzones, and the quarantine

The shadow map is a fixed shift-and-offset of the address space: `Shadow = (Mem >>
ASAN_SHADOW_SCALE) + offset`, scale **3** (eight bytes per shadow byte), canonical
Linux/x86-64 offset `0x00007fff8000` ([`lib/asan/asan_mapping.h:182`, `:299`][llvm-src];
LLVM-side constants [`AddressSanitizer.cpp:100-105`][llvm-src]). A shadow byte records how
many of its eight bytes are addressable, or a poison marker: heap-left-redzone `0xfa`,
freed-heap `0xfd`, stack-left/mid/right `0xf1`/`0xf2`/`0xf3`, stack-after-return `0xf5`,
global-redzone `0xf9` ([`asan_internal.h:141-151`][llvm-src]). `[source-verified]`

Every heap block is wrapped in [redzones][redzone] — default **16** bytes, growable to
`max_redzone` **2048** ([`asan_flags.inc:31-35`][llvm-src]) — so a small overrun lands on
poison. On `free`, the chunk enters state `CHUNK_QUARANTINE` and is withheld from reuse
by a FIFO [quarantine][quarantine], default **256 MB**
([`asan_allocator.cpp:160-162,216-283`][llvm-src]; [`asan_flags.cpp:187-191`][llvm-src]),
so its poison — and thus use-after-free detection — survives until the chunk is evicted
and its address recycled. Both are _detection windows_: an overflow that overshoots the
redzone into a valid neighbour, or a use-after-free after quarantine eviction, is missed.
Uninstrumented libc entry points are covered by **interceptors** — 37 explicit
`INTERCEPTOR`s in `asan_interceptors.cpp` (`strcpy`, `pthread_create`, …) plus the shared
`sanitizer_common_interceptors.inc` table ([`interceptor`][interceptor];
`[source-verified]`).

### Stack instrumentation and the fake stack

Detecting a pointer to a local that escapes its frame needs the local to _not_ live on
the real stack, where the slot is reused immediately. ASan can move address-taken locals
into heap-allocated [fake-stack](./concepts.md#fake-stack-and-stack-use-after-return) frames that stay
poisoned (`0xf5`) after return. The compiler emits this per
`-fsanitize-address-use-after-return = never | runtime | always`, default **runtime**
([`AddressSanitizer.cpp:283-295`][llvm-src]); LDC mirrors the option with the same default
and help text "Requires druntime support"
([`driver/cl_options_sanitizers.cpp:155-173`][ldc-src]). In `runtime` mode the fake-stack
code is gated on the runtime global `__asan_option_detect_stack_use_after_return`, driven
by the flag `detect_stack_use_after_return` — whose compiler-rt source default is **true**
on Linux non-Android ([`asan_flags.inc:52-54`][llvm-src]). On this box's linked runtime,
**GCC 15.2's `libasan.so.8` enables it by default**, so the catch needs no options
`[hw-verified: x86_64-linux]` (recorded also by [d-toolchain.md][d-toolchain]'s
`fiber-asan.d`); probe [`asan-stack-uar.d`](./examples/asan-stack-uar.d) pins it
explicitly for determinism, showing the catch at the default and the silent stale read
under `detect_stack_use_after_return=0`.

### Global instrumentation and redzones

Instrumented globals are padded with redzones (`0xf9`) and registered with the runtime
via `__asan_register_globals`, so a one-past-the-end access is a `global-buffer-overflow`
naming the variable and its size. Probe
[`asan-global-overflow.d`](./examples/asan-global-overflow.d) reads one element past a
module-level `__gshared int[8]` through `.ptr` (which sidesteps D's own bounds check —
`table[8]` would be a compile-time error or a `RangeError`) and ASan traps it, exit 1.
`[hw-verified: x86_64-linux]`

---

## The seven concerns

The concern order is fixed across the survey. For ASan every concern applies — none is a
blank — and several are the point of the page.

### Defect classes and blind spots

**Concern 1 — the catalog above, plus D's two blind spots.** ASan catches heap
use-after-free, heap/stack/global overflow, stack-use-after-return, use-after-scope, and
(with the ODR/init-order checks) global-init-order bugs; LSan adds leaks. The two misses
that matter for a D runner are **uninstrumented frames** (a coverage gap, not a false
positive) and **GC-pool memory** — a use-after-free _inside_ GC memory is invisible to
ASan because GC pools are `mmap`'d and never reach ASan's allocator, demonstrated by
[d-toolchain.md][d-toolchain]'s `gc-uaf-blindspot.d` and defined once at [the GC memory
blind spot][gc-blind-spot]. Leaks are a third, closable class, handled by
[LSan](#leaksanitizer-and-the-d-gc).

### Instrumentation model and recompile scope

**Concern 2 — the runtime reality on LDC is a GCC-libsanitizer hybrid.** LDC's ASan is a
stock LLVM IR pass registered at the optimizer tail; each function gets an LLVM
`SanitizeAddress` attribute and, when built with `-fsanitize=address`, LDC predefines the
`version (LDC_AddressSanitizer)` identifier (the probes' compile-time gate). The runtime,
though, is not compiler-rt: **nixpkgs LDC ships zero `clang_rt` libraries** and its
`ldc2.conf` compiler-rt lib-dir is a dead store path, so LDC's sanitizer-library search
misses and falls through to handing `-fsanitize=address` to the C compiler used as linker
— GCC 15.2 — which links `libasan.so.8` ([`driver/linker-gcc.cpp:331-371`][ldc-src]). The
fallback is a single line ([`:368-371`][ldc-src]):

> `// When we reach here, we did not find the sanitizer library.`
> `// Fallback, requires Clang.`

`[source-verified]` — and despite the comment it works with **gcc**, which is this box's
entire ASan reality.

The hybrid is sound, and measured to be a **strict superset**, not a lossy substitute.
`nm -D` on GCC 15.2's `libasan.so.8` versus compiler-rt 18.1.8's
`libclang_rt.asan-x86_64.so`, filtered to the `__asan_` / `__lsan_` / `__sanitizer_`
prefixes, shows **compiler-rt exports nothing GCC's runtime lacks** (`comm -13` empty);
both define the ABI gate `__asan_version_mismatch_check_v8`; and `ASAN_OPTIONS=help=1`
enumerates a **byte-identical 134-flag surface** on both. `[hw-verified: x86_64-linux]`
GCC's _extras_ are its bundled `libbacktrace`/`libiberty` self-symbolization machinery
(the `__asan_backtrace_*` / `__asan_cplus_demangle_*` symbols — why its reports carry
`file:line` with no external symbolizer, concern 5) and a handful of post-LLVM-18
interface additions, evidence that GCC 15.2 carries a _newer_ compiler-rt merge than the
LLVM-18 pass emitting the IR.

Real compiler-rt **can** be restored: realize `nixpkgs#llvmPackages_18.compiler-rt` and
point an edited `ldc2.conf` copy (via `-conf=`) at its `lib/linux`, and LDC links the
static `libclang_rt.asan-x86_64.a` explicitly, dropping `-fsanitize=address` from the gcc
link line ([`getFullCompilerRTLibPathCandidates`, `linker-gcc.cpp:293-330`][ldc-src] —
only `ldc2.conf` `lib-dirs`, never `-L` flags, participate in the search). The one
behavioural regression is symbolization (concern 5). `[hw-verified: x86_64-linux]` (E7).

**Recompile scope for ASan is user code only.** Unlike MSan's
[instrumented-world requirement][instrumented-world], instrumenting only the program (and
leaving druntime/Phobos uninstrumented) costs _coverage_ of their frames, not
correctness — no false positives arise from the uninstrumented world because ASan's
allocator interception is process-wide. dub ≥ 1.42.0-beta.1 additionally treats
`-fsanitize=` as ABI-critical and propagates it across the whole dependency closure, so a
mixed-instrumentation build cannot arise through dub channels; the details, and the
`DFLAGS` false-green trap, live in [d-toolchain.md][d-toolchain].

### D and druntime interaction

**Concern 3 — a clean baseline, one blind spot, and an integration seam.** A trivial
GC-using program is clean under both `-fsanitize=address` and `-fsanitize=leak` with
`detect_leaks=1` — druntime and GC startup/shutdown produce **zero** ASan/LSan findings
(E1) — so a `--sanitize=address` runner mode starts from a green baseline, no suppression
file required for the trivial case. The **GC memory blind spot** (concern 1) is the one
architectural miss ASan cannot close even against a fully instrumented druntime. On the
fiber side, LDC's druntime carries fake-stack GC-scanning
(`scanStackForASanFakeStack`) and [fiber-switch annotation][fiber-annotation] hooks in
source but compiles them into **no shipped build**, so a fiber's basic ASan operation is
sound (the faulting read is in instrumented user code) while GC scanning of fake-stack
frames is a latent hazard — all detailed in [d-toolchain.md][d-toolchain]. The concrete
integration opportunity is `__lsan_register_root_region` over the GC's pools, which would
turn the LSan false positive below into a true negative (untested; see the LSan section).

### Runtime control and report capture

**Concern 4 — the core runner-facing surface, exercised end to end from D.** This is the
[weak-hook control surface][weak-hook] made concrete for ASan; probe
[`asan-report-capture.d`](./examples/asan-report-capture.d) drives the two capture paths.

- **`ASAN_OPTIONS` grammar.** Separators are space/comma/colon/newline/tab/CR, values are
  `name=value` with optional quotes, and an unknown flag is fatal ("Flag parsing failed")
  ([`sanitizer_flag_parser.cpp:74-105`][llvm-src]). `include=<file>` and
  `include_if_exists=<file>` are themselves flags, with `%b` (binary basename) and `%p`
  (pid) substitution ([`sanitizer_flags.cpp:39-120`][llvm-src]) — both honoured on this
  box `[hw-verified: x86_64-linux]`.
- **`log_path` routing.** `log_path=P` makes each _process_ open `P.<pid>` lazily at its
  first report write ([`sanitizer_file.cpp:37-75`][llvm-src], naming `"%s.%zu"` at `:67`;
  `log_exe_name=1` → `P.<exe>.<pid>`; `log_suffix` appended); `stdout`/`stderr` are
  accepted specials. With `log_path` set the child's stderr carries **zero** report bytes,
  a clean run creates **no** file, and the exit code is unchanged. Two erroring children
  under one prefix produce two distinct `P.<pidA>` / `P.<pidB>` files — ideal for
  [process-per-test][process-per-test] attribution, useless for segmenting an in-process
  many-test binary (one file per process regardless of test count). `[hw-verified:
x86_64-linux]` (E3).

  > "Write logs to \"log_path.pid\". The special values are \"stdout\" and \"stderr\". If
  > unspecified, defaults to \"stderr\"." — [`sanitizer_flags.inc:55-57`][llvm-src]

- **Report callback.** `__asan_set_error_report_callback` registers a D `extern(C)`
  handler that receives the **full** composed report text (`ERROR:` line through
  `SUMMARY:`, ~6–7 KB captured) _before_ the process dies: the `ScopedInErrorReport`
  destructor copies the buffer, logs it, calls the callback, and only then
  `Report("ABORTING\n"); Die()` ([`asan_report.cpp:190-221`, setter `:548-550`][llvm-src]).
  **Proven caveat:** `Die()` ends in `internal__exit` ([`sanitizer_termination.cpp:44-60`][llvm-src])
  which does **not** flush stdio, so a handler's buffered `printf` is lost — the handler
  must write-and-close its own sink (the probe `fwrite`+`fclose`s a file; a runner would
  write a pipe/fd). `__sanitizer_set_death_callback` (fires inside `Die()`) and the weak
  `__asan_on_error` hook are also present. `[hw-verified: x86_64-linux]` (E4).
- **`__asan_default_options` precedence.** A plain `extern(C)` D definition of
  `__asan_default_options` returning an options string overrides the runtime's weak
  default even with a shared `libasan` (the `.so` references the symbol, so the exe
  exports it — no `-rdynamic` needed); the environment still wins over it. Precedence:
  **default < hook < `ASAN_OPTIONS`** (`exitcode=42` from the hook, but env `exitcode=7`
  won). `[hw-verified: x86_64-linux]` (E5).
- **Halt vs recover, and exit codes.** ASan **halts** by default (`halt_on_error` true,
  [`asan_flags.inc:161-163`][llvm-src]):

  > "Crash the program after printing the first error report (WARNING: USE AT YOUR OWN
  > RISK!)"

  Surviving a finding requires **both** the compile-time `-fsanitize-recover=address`
  (LDC accepts recover only for address/memory, [`cl_options_sanitizers.cpp:176`][ldc-src])
  **and** the runtime `halt_on_error=0`; a recovered run then prints its report(s) and
  **exits 0**. The load-bearing consequence for a continue-mode runner: **recovered errors
  do not touch the exit code**, so report capture must count reports (callback or log),
  never read exit codes ([halt vs recover][halt-vs-recover]). The death path is
  user-death-callback → internal callbacks → `Abort()` if `abort_on_error` else
  `internal__exit(exitcode)`; defaults `exitcode=1`, `abort_on_error` true only on
  Android/Apple. Verified codes: `1` (default), `77` (`exitcode=77`), SIGABRT → shell
  `134` (`abort_on_error=1`); standalone LSan `23`. `[hw-verified: x86_64-linux]` (E2). The
  full cross-tool table is in [concepts.md][halt-vs-recover] and [comparison.md][comparison].

### Symbolization and suppressions

**Concern 5 — self-symbolizing reports, but no D demangling, and two opt-out channels.**
GCC's runtime self-symbolizes to `file:line` with **no external tool** (its bundled
`libbacktrace`), which is why every probe here asserts `asan-*.d` file locators appear in
the report on a bare `PATH`. Real compiler-rt does not: it emits module+offset until
`llvm-symbolizer` is on `PATH` (then `file:line:column`, and it demangles `_Dmain` → "D
main") or `allow_addr2line=1` is set. **Neither runtime demangles D beyond `_Dmain`**, so
reports and suppressions both work in **mangled** names — a `ddemangle` post-processing
pass is wanted either way. `[hw-verified: x86_64-linux]`

Two opt-out channels exist. At **runtime**, `ASAN_OPTIONS=suppressions=<file>` takes
one-line `type:pattern` [suppressions][suppression] (glob, not regex) matched against
every frame's mangled function/file/module; LSan additionally honours the weak
`__lsan_default_suppressions` hook. At **compile time**, `-fsanitize-blacklist=<file>`
(compiler-rt's `SpecialCaseList`) excludes named code from instrumentation entirely — a
`fun:` entry matches the **mangled** D name (`mangleExact`), a `src:` entry the source
filename; per-sanitizer `[address]` sections are ignored, only the empty global section is
read ([`cl_options_sanitizers.cpp:223-259`][ldc-src], W3 E7). The druntime UDA
`@noSanitize("address")` is the per-function equivalent. `[source-verified + hw-verified:
x86_64-linux]` (W3).

### Test-runner integration semantics

**Concern 6 — three per-test attribution designs, in preference order.** All three were
reproduced from D; the runner-side survey is in [runner-integrations.md][runner-integrations].

1. **[Process-per-test][process-per-test] + `log_path`.** One prefix, one `P.<pid>` file
   per crashed child, no empty-file ambiguity (files appear only on report). Any nonzero
   exit is that one test's failure. This is the most robust and the least coupled to ASan
   internals, and sparkles' extract-and-recompile drivers are most of an `--isolate` mode.
2. **In-process + report callback accumulation** with `-fsanitize-recover=address` +
   `halt_on_error=0`, counting reports in the [windowing][report-windowing] style — but
   the recovered run exits 0, so the count, not the exit code, is the verdict, and
   callback/flag state is **process-global**, so parallel workers blur attribution unless
   bounded to `-t 1` or per-worker windows.
3. **Per-test LSan** via `leak_check_at_exit=0` + `__lsan_do_recoverable_leak_check()` at
   each test boundary (see the LSan section).

### Platform, toolchain, and overhead

**Concern 7 — LDC-only among D compilers, Linux-verified, ~2× overhead.** ASan is
reachable only from **LDC** among the D compilers: DMD has no sanitizer flags at all, and
nixpkgs GDC needs a `-B`/`-L` + `--param asan-globals=0` workaround (all in
[d-toolchain.md][d-toolchain]). Linux is hardware-verified here; on **Darwin**,
`abort_on_error` defaults on, so a caught error yields shell exit **134**
`[hw-verified: aarch64-darwin]` (see [macos-windows.md][macos-windows]). The
literature overhead figure is **2×** ([`AddressSanitizer.rst:24`][clang-asan],
`[literature]`); measured D numbers are consolidated in [comparison.md][comparison].

---

## LeakSanitizer and the D GC

LSan runs two ways: **standalone** (`-fsanitize=leak`, its own runtime) or **folded into
ASan** (plain `-fsanitize=address` runs a leak check at exit). Its own docs state the
combination and its cheapness ([`clang/docs/LeakSanitizer.rst:11-15`][clang-lsan]):

> "LeakSanitizer is a run-time memory leak detector. It can be combined with
> AddressSanitizer to get both memory error and leak detection, or used in a stand-alone
> mode. LSan adds almost no performance overhead until the very end of the process, at
> which point there is an extra leak detection phase."

`[literature]`

### The scan model versus a conservative GC

At exit LSan does a **[stop-the-world root scan][stw-root-scan]** much like a GC: it
`clone()`s a tracer task and `ptrace(PTRACE_ATTACH)`es every thread — non-cooperative, no
signal handlers ([`sanitizer_stoptheworld_linux_libcdep.cpp:74-88`][llvm-src]) — then does
a conservative aligned-word scan from globals, thread stacks/registers/TLS, and
root-regions, and flood-fills reachability. Crucially, the flood fill follows pointers
**only through registered allocator chunks** (`ClassifyAllChunks`,
[`lsan_common.cpp:721-747`][llvm-src]); anything unreachable is a leak. D's GC, by
contrast, suspends the world with a **signal handshake** — a mechanism mismatch that is
benign for LSan (single-threaded here) but livelocks TSan (see [tsan.md][tsan]). This
model, applied to D's split heap, produces a four-quadrant verdict, all from probe
[`lsan-gc-interplay.d`](./examples/lsan-gc-interplay.d):

| Quadrant | Allocation and reachability                         | LSan verdict                            |
| -------- | --------------------------------------------------- | --------------------------------------- |
| Q1       | `malloc(1001)`, unreachable                         | **reported** — a true leak              |
| Q2       | `malloc(2002)` referenced **only** from a GC array  | **reported — a FALSE POSITIVE**         |
| Q3       | `new ubyte[4004]` dropped                           | **invisible** — GC pools aren't chunks  |
| Q4       | `malloc(5005)` referenced from a `__gshared` global | **silent** — data-segment roots scanned |

`[hw-verified: x86_64-linux]` (E6). Q2 is the sharp one: because the flood fill only
traverses registered chunks, a pointer that lands _inside_ a GC pool terminates the walk,
so a `malloc` block reachable solely through GC memory is reported as a "Direct leak" even
though it is live. Q3 is the mirror image — a genuinely dropped GC allocation is never
reported, because it never was an LSan chunk. Q4 confirms `.data`/`.bss` roots work
(`ProcessGlobalRegions`).

### The composition refutation and the per-test recipe

A natural per-test design — set `detect_leaks=0`, then call `__lsan_do_leak_check()`
manually at each boundary — **does not work**: the manual entry points are themselves
gated on `detect_leaks`, so `detect_leaks=0` makes them no-ops
([`lsan_common.cpp:1192-1198`][llvm-src]; hw-confirmed — the program survived the fatal
call and exited 0). The composable recipe is the opposite: keep `detect_leaks=1`, set
`leak_check_at_exit=0`, and call `__lsan_do_recoverable_leak_check()` per test — repeatable,
non-fatal, returns 1/0 ([`DoRecoverableLeakCheck`, `:945-950`][llvm-src]). The flag text
names the interaction directly:

> "Invoke leak checking in an atexit handler. Has no effect if detect_leaks=false, or if
> `__lsan_do_leak_check()` is called before the handler has a chance to run." —
> [`sanitizer_flags.inc:80-84`][llvm-src]

`[source-verified]` The fatal `__lsan_do_leak_check` is once-only (an `already_done`
latch) and dies via `Die`. Exit codes: standalone LSan **23** (`cf.exitcode = 23`,
[`lsan.cpp:61`][llvm-src], also rewritten over an app's own `_exit(0)` after reported
leaks); under ASan-integrated LSan it is ASan's `exitcode` default **1**. No
`LDC_LeakSanitizer` version identifier exists (LDC predefines only
address/coverage/memory/thread, [`driver/main.cpp:1029-1041`][ldc-src]), so an LSan probe
must detect instrumentation with `dlsym`, as `lsan-gc-interplay.d` does. `[hw-verified:
x86_64-linux]`

### The druntime leak-noise policy

The clean E1 baseline does **not** survive a real test suite. Plain ASan's exit-time leak
check flags druntime's `defaultTraceHandler` trace-info allocations — mallocs of exception
backtrace metadata, made for every caught `Throwable` and never freed — as "Direct leak
of 4224 byte(s) in 4 object(s)", turning a green "278 passed" into **exit 1**; the GC
pools being invisible to LSan (Q3) will generally add more of this class. `[hw-verified:
x86_64-linux]` (W3 E5c). A `--sanitize=address` runner mode must therefore default
`ASAN_OPTIONS=detect_leaks=0` **or** ship a curated LSan suppression file — this is
mandatory policy, not a nicety. The false-positive mitigations for a leak-checking mode
(all present in both runtimes, untested here) are `__lsan_register_root_region` over the
GC's pools, `__lsan_disable`/`enable` scopes, `__lsan_ignore_object`, and suppression
files.

---

## Strengths

- **Reachable from LDC today with no toolchain surgery** — the gcc link fallback links a
  strict-superset runtime that self-symbolizes to `file:line` with no `llvm-symbolizer`.
- **A complete, catch-verified defect catalog** — heap/stack/global overflow,
  use-after-free, stack-use-after-return, all reproduced from D against a stock nixpkgs
  druntime.
- **A rich, program-steerable control surface** — options grammar, `log_path` routing,
  report/death callbacks, and `__asan_default_options` precedence, every one exercised
  from a D `extern(C)` seam.
- **LSan for free** — a leak detector at almost no extra overhead, folded into the same
  `-fsanitize=address` build.
- **A clean startup baseline** — a trivial GC program is ASan/LSan-clean, so a
  `--sanitize=address` mode does not begin under a pile of druntime noise.

## Weaknesses

- **The GC memory blind spot is unclosable by ASan** — a use-after-free inside GC memory
  is invisible even against a fully instrumented druntime ([gc-blind-spot][gc-blind-spot]).
- **LSan false-positives GC-referenced `malloc` blocks** (Q2) and misses dropped GC
  allocations (Q3) — its reachability walk cannot see D's split heap.
- **No D name demangling** in either runtime beyond `_Dmain` — reports and suppression
  globs work in mangled names; `ddemangle` post-processing is needed for readable output.
- **Recovered errors exit 0** — a continue-mode runner cannot use exit codes and must
  count reports; and `Die()` does not flush stdio, so a naive report callback loses its
  output.
- **A green suite fails at exit under default LSan** — druntime's `defaultTraceHandler`
  leaks force `detect_leaks=0` or a suppression file as mandatory runner policy.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                               | Trade-off                                                                                     |
| ------------------------------------------------------------ | ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| ABI gated by one version symbol (`__asan_..._v8`)            | Instrumented objects decouple from the exact runtime build              | Any `_v8` runtime links — including GCC's, so what you _link_ is a packaging accident         |
| gcc link fallback when no `clang_rt` is found                | Sanitizers work on a compiler-rt-less LDC with zero user setup          | The runtime is GCC's, not LLVM's — self-symbolizes but never demangles D                      |
| Redzones + quarantine as fixed-size detection windows        | Bounds overruns and use-after-free caught immediately, cheaply          | An overshoot into a valid neighbour, or reuse after quarantine eviction, is missed            |
| ASan needs only user code instrumented                       | A drop-in `-fsanitize=address` build, no instrumented-world requirement | Uninstrumented druntime/Phobos frames are a coverage gap; GC memory is a permanent blind spot |
| LSan reachability walks only registered allocator chunks     | O(live heap) leak detection with no per-object bookkeeping              | A `malloc` reachable only via GC memory is a false positive; a dropped GC block is invisible  |
| `detect_leaks` gates even the manual leak-check entry points | One flag turns leak detection fully off                                 | The obvious `detect_leaks=0` + manual-check per-test recipe silently no-ops                   |

---

## Sources

- LLVM `compiler-rt` at [`73802c2e`][llvm-src] — `lib/asan/{asan_mapping.h, asan_flags.inc,
asan_internal.h, asan_allocator.cpp, asan_interceptors.cpp, asan_report.cpp,
asan_init_version.h}`, `lib/lsan/{lsan.cpp, lsan_common.cpp}`,
  `lib/sanitizer_common/{sanitizer_flags.inc, sanitizer_flag_parser.cpp, sanitizer_file.cpp,
sanitizer_termination.cpp, sanitizer_stoptheworld_linux_libcdep.cpp}` — all quoted/cited above.
- LDC at [`v1.41.0`][ldc-src] — `driver/{linker-gcc.cpp, cl_options_sanitizers.cpp, main.cpp}`
  (the gcc fallback, recover set, blacklist sections, version identifiers).
- clang sanitizer docs — [AddressSanitizer][clang-asan] (2× overhead), [LeakSanitizer][clang-lsan]
  (standalone-vs-combined).
- GCC 15.2 libsanitizer runtimes (`libasan.so.8` / `liblsan.so.0`), audited by `nm -D` and
  `ASAN_OPTIONS=help=1` — the strict-superset / 134-flag-parity finding.
- Runnable probes: [`asan-heap-uaf.d`](./examples/asan-heap-uaf.d) ·
  [`asan-stack-uar.d`](./examples/asan-stack-uar.d) ·
  [`asan-global-overflow.d`](./examples/asan-global-overflow.d) ·
  [`asan-report-capture.d`](./examples/asan-report-capture.d) ·
  [`lsan-gc-interplay.d`](./examples/lsan-gc-interplay.d).
- The D-toolchain reality (GCC-runtime hybrid, `DFLAGS` trap, GC blind spot, fibers,
  `defaultTraceHandler` leak noise, `-fsanitize-blacklist`): [d-toolchain.md][d-toolchain].
- Shared vocabulary: [concepts.md][concepts] ([shadow memory][shadow], [redzone][redzone],
  [quarantine][quarantine], [fake stack][fake-stack], [the GC memory blind spot][gc-blind-spot],
  [halt vs recover][halt-vs-recover], [weak-hook control surface][weak-hook],
  [stop-the-world root scanning][stw-root-scan]).

<!-- References -->

[index]: ./
[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[runtime-selection]: ./concepts.md#sanitizer-runtime-selection
[interceptor]: ./concepts.md#interceptor
[allocator-interception]: ./concepts.md#allocator-interception
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[instrumented-world]: ./concepts.md#instrumented-world-requirement
[shadow]: ./concepts.md#shadow-memory
[redzone]: ./concepts.md#redzone
[quarantine]: ./concepts.md#quarantine
[fake-stack]: ./concepts.md#fake-stack-and-stack-use-after-return
[stw-root-scan]: ./concepts.md#stop-the-world-root-scanning
[fiber-annotation]: ./concepts.md#fiber-annotation
[halt-vs-recover]: ./concepts.md#halt-vs-recover
[weak-hook]: ./concepts.md#weak-hook-control-surface
[suppression]: ./concepts.md#suppression
[report-windowing]: ./concepts.md#report-windowing
[process-per-test]: ./concepts.md#process-per-test-isolation
[interceptor]: ./concepts.md#interceptor
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[valgrind]: ./valgrind.md
[d-toolchain]: ./d-toolchain.md
[macos-windows]: ./macos-windows.md
[hardware-assisted]: ./hardware-assisted.md
[comparison]: ./comparison.md
[runner-integrations]: ./runner-integrations.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./integration-proposal.md
[llvm-src]: https://github.com/llvm/llvm-project/tree/73802c2e9d102a4fb646bc039754779fca3ea476
[ldc-src]: https://github.com/ldc-developers/ldc/tree/v1.41.0
[clang-asan]: https://clang.llvm.org/docs/AddressSanitizer.html
[clang-lsan]: https://clang.llvm.org/docs/LeakSanitizer.html
