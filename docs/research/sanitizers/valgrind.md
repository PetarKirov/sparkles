# Valgrind (memcheck / helgrind / DRD)

The survey's **no-recompile** tool family: `memcheck`, `helgrind`, and `DRD`
find memory and threading defects in an **unmodified** LDC, GDC, or DMD binary,
with D names demangled and no sanitizer flag anywhere in the build — which makes
Valgrind the only dynamic verification path DMD has at all.

| Field                 | Value                                                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tools                 | `memcheck` (memory errors + definedness), `helgrind` / `DRD` (data races), plus Nulgrind/cachegrind/… out of scope                                      |
| Instrumentation locus | [Dynamic binary translation (DBI)][locus] — the VEX JIT re-translates every instruction; **nothing is recompiled**                                      |
| Version               | **3.26.0** (runtime-tested, nixpkgs) / source read at [`valgrind@218cee2f`][vg-src] (tag `VALGRIND_3_26_0`)                                             |
| License / Repository  | GPL-2.0 · [sourceware `valgrind.git`][vg-src]                                                                                                           |
| Documentation         | [Valgrind manual][vg-manual] (`memcheck` / `helgrind` / `DRD` chapters)                                                                                 |
| D toolchains          | LDC = GDC = DMD (compiler-independent by construction — it instruments the binary, not the IR); **DMD's only path** — see [d-toolchain.md][d-toolchain] |
| druntime read         | `dmd@e6baf474` (upstream druntime: GC, `etc.valgrind`, fibers); LDC fork `ldc@f4d2f831` (same `etc/valgrind/` shape, no fiber hooks)                    |
| Verification          | `[hw-verified: x86_64-linux]` — Experiments E1–E9, both LDC 1.41.0 and DMD 2.112.1                                                                      |

> [!NOTE]
> Everything on this page was recorded on **Linux 6.18.26**, an **AMD Ryzen 9
> 7940HX** (Zen 4, 16c/32t), **valgrind 3.26.0** (nixpkgs, via `nix shell
nixpkgs#valgrind`), **LDC 1.41.0** and **DMD 2.112.1**. Every experiment was
> run on both compilers' binaries and produced identical verdicts unless noted.
> The three runnable probes ([`valgrind-memcheck-catch.d`](./examples/valgrind-memcheck-catch.d),
> [`valgrind-client-requests.d`](./examples/valgrind-client-requests.d),
> [`valgrind-attribution.d`](./examples/valgrind-attribution.d)) lock the
> load-bearing behaviours into CI.

---

## Overview

### What it detects

`memcheck` shadows every byte of the address space with two kinds of metadata
and checks them on every access: **addressability** (may the program touch this
byte) and **definedness** (is each value bit initialized). From that it reports
`InvalidRead`/`InvalidWrite` (unaddressable access — heap use-after-free,
out-of-bounds past a `malloc` block, a freed stack), `UninitValue` and
`UninitCondition` (a computation or branch on an undefined value),
`InvalidFree`, `MismatchedFree`, `Overlap` (overlapping `memcpy`), `SyscallParam`
(a syscall handed unaddressable/undefined memory), `ClientCheck`, and the
`Leak_DefinitelyLost`/`Leak_PossiblyLost`/`Leak_IndirectlyLost`/`Leak_StillReachable`
taxonomy from its exit-time leak scan. `helgrind` and `DRD` detect data
[races][vector-clocks], and additionally lock-ordering (helgrind) or lock
contention (DRD) and pthread-API misuse.

The **definedness** axis is the capability [ASan][asan] structurally lacks:
ASan's [shadow][shadow] encodes addressability only, so it can never report an
uninitialized read, while `memcheck`'s per-bit V-bits can — this is the
[definedness-vs-addressability][def-vs-addr] split the survey draws between the
two. The mirror-image weakness: `memcheck` has **no [redzones][redzone]**, so a
small overrun that stays _inside_ a `malloc` block (or steps into a valid
neighbour) is invisible where ASan would catch it.

### Design philosophy: shadow every byte, recompile nothing

`memcheck`'s model is stated plainly at the top of its shadow engine
([`memcheck/mc_main.c:100`][vg-src]):

> Conceptually, every byte value has 8 V bits, which track whether Memcheck
> thinks the corresponding value bit is defined. And every memory byte has an A
> bit, which tracks whether Memcheck thinks the program can access it safely (ie.
> it's mapped, and has at least one of the RWX permission bits set). So every
> N-bit register is shadowed with N V bits, and every memory byte is shadowed
> with 8 V bits and one A bit.

`[source-verified]` This is the whole model: 8 V-bits + 1 A-bit per byte,
carried through registers as well as memory. It is richer than ASan on the
definedness axis and — because it is applied by re-translating machine code
rather than by an instrumentation pass — it needs **no recompilation and no
special flags**, which is exactly what puts it within DMD's reach where every
LLVM-IR-pass tool is not. The cost side of the same coin is the headline
slowdown: `memcheck` "adds code to check every memory access and every value
computed, making it run 10-50 times slower than natively"
([`docs/xml/manual-core.xml:59`][vg-src]). `[source-verified]`

---

## How it works

### The V-bit / A-bit shadow

The 9-bits-per-byte model is compressed two ways
([`memcheck/mc_main.c:100`][vg-src], encodings `:238`). Each byte's
addressability + definedness collapses to **2 bits** — `VA_BITS2_NOACCESS`,
`VA_BITS2_UNDEFINED`, `VA_BITS2_DEFINED`, `VA_BITS2_PARTDEFINED` — and only a
_partially defined_ byte spends its exact 8 V-bits in a secondary table. On
64-bit the shadow is a 2²⁰-entry primary map over the bottom 64 GB (address bits
16..35) with a sparse auxiliary table above, and three **distinguished secondary
maps** (`noaccess`/`undefined`/`defined`) that every uniform 64 KB chunk shares
by pointer instead of materializing ([`mc_main.c:120`][vg-src]). `[source-verified]`

One deliberate imprecision is worth stating because it bounds what `memcheck`
can model ([`mc_main.c:157`][vg-src]):

> Aside: the V+A bits are less precise than they could be -- we have no way of
> marking memory as read-only.

`[source-verified]` There is no read-only state (a fifth `VA_BITSn_READONLY`
would need 2.3 bits, which does not pack), so `makeMemNoAccess` is
all-or-nothing: memory is addressable or it is not.

### Dynamic binary translation and the client-request trapdoor

Valgrind is a [DBI][locus] framework: the VEX JIT disassembles each basic block
to an IR, the active tool instruments that IR, and the block is re-emitted and
run — so **all** code is covered, including libc and every dynamically-linked
library the program pulls in. The one channel a program has to talk _back_ to
the tool without being recompiled is the [client request][client-request]: a
magic no-op instruction sequence the JIT recognizes byte-for-byte. On amd64 it
is a 16-byte preamble of four `rolq` rotations on `%rdi` (`3, 13, 61, 51` — a
net 128-bit no-op) followed by `xchgq %rbx,%rbx`
([`include/valgrind.h.in:422`][vg-src]); VEX matches the exact bytes at
translation time and emits an `Ijk_ClientReq` exit
([`VEX/priv/guest_amd64_toIR.c:32270`][vg-src]), and the scheduler dispatches on
the request code with the argument block addressed by `%rax` and the result in
`%rdx` ([`coregrind/m_scheduler/scheduler.c:2040`][vg-src]). Outside Valgrind
the same bytes execute as harmless arithmetic and the default result flows
through, so the annotation is safe to leave compiled into production code.
`[source-verified]` This trapdoor is what makes `VALGRIND_PRINTF` markers,
`MAKE_MEM_*`, `STACK_REGISTER`, and `RUNNING_ON_VALGRIND` reachable from an
unmodified binary — the mechanism the D probes drive.

---

## The seven concerns

The concern order is fixed across the survey; where one does not apply, the
absence is the finding.

### Defect classes: memcheck kinds, races, and the blind spots

`memcheck`'s error taxonomy is enumerated above; the survey's structural point
is the **definedness** capability ([def-vs-addr][def-vs-addr]) — `UninitValue`
/ `UninitCondition` come from the V-bits and have no ASan analog — set against
three blind spots that recur on every memory tool here:

- **GC use-after-free is invisible.** D's GC allocates pools with `mmap`, not
  `malloc`, so a `GC.free`'d block never passes through `memcheck`'s malloc
  replacement and its A-bits are never cleared. A `GC.malloc → GC.free → read`
  produced **zero** `Invalid*` reports under stock `memcheck` — only
  conservative-scan noise. This is the [GC memory blind spot][gc-blind-spot],
  and it is the one half of it that is _closable without a druntime rebuild_
  (see [the GC interaction](#the-d-and-druntime-interaction)). `[hw-verified: x86_64-linux]`
- **No redzones, no small-overflow catch.** With no [redzone][redzone] between
  allocations, an overrun that stays inside a `malloc` block is not caught the
  way ASan catches it. `memcheck` catches the overrun only once it crosses into
  _unaddressable_ memory (past the block, into a freed region). `[source-verified]`
- **Serialization orders races away.** `helgrind`/`DRD` share the false-negative
  class of every [happens-before][vector-clocks] detector: a serialized
  scheduler can impose an ordering a real race doesn't have. Verified below and
  contrasted with [TSan][tsan], which catches the same program.

`helgrind` detects three classes — pthread-API misuse, lock-ordering (potential
deadlock), and data races ([`helgrind/docs/hg-manual.xml:28`][vg-src]); `DRD`
detects races, lock contention (`--exclusive-threshold`), and API misuse, but
has **no** lock-order detector. Both are vector-clock happens-before engines:
helgrind's `libhb` ("a library for implementing and checking the happens-before
relationship", [`helgrind/libhb_core.c:4`][vg-src]) with per-thread VTS clocks;
DRD's per-thread segment lists with vector clocks
([`drd/drd_thread.h:67`][vg-src]). `[source-verified]`

### Instrumentation model: dynamic binary translation, no recompile

The [instrumentation locus][locus] is DBI, and the practical consequences are
the spine of Valgrind's fit for a D runner:

- **Nothing is recompiled; `-g` buys only `file:line`.** The same source built
  by LDC and DMD with no special flags produced byte-equivalent verdicts
  (`InvalidRead` at `uaf.d:10`, exit 99). Without `-g`, frames still carry
  demangled D function names from the ELF symbol table; `-g` adds file and line.
  This is [DMD's only sanitizer path][d-toolchain], at full fidelity —
  DMD 2.112.1 has zero `-fsanitize` flags, and every experiment here ran
  identically on its binaries. `[hw-verified: x86_64-linux]`
- **`--track-origins` is the definedness upgrade, at a measured cost.** An
  origin tag is 32 bits — a 30-bit execontext id plus a 2-bit kind
  (`HEAP`/`STACK`/`USER`/`UNKNOWN`, [`memcheck/mc_include.h:179`][vg-src]) — so a
  `UninitValue` report can name _where the undefined bytes were born_. The manual
  is blunt about the price: "It halves Memcheck's speed and increases memory use
  by a minimum of 100MB" ([`memcheck/docs/mc-manual.xml:1100`][vg-src]); measured
  here it was 1.126 s → 1.602 s on a CPU-bound fixture (a 1.4× marginal add).
  `[source-verified]` `[hw-verified: x86_64-linux]`
- **The client-request channel is the recompile-free annotation seam**, and a
  _targeted_ `-debug=VALGRIND` recompile — of the GC into the app, not the whole
  world — is the one fidelity upgrade that closes the GC blind spot. Both are
  covered under [the D interaction](#the-d-and-druntime-interaction).

### The D and druntime interaction

This is where Valgrind stops being generic and starts being D-specific. Three
sub-stories: the `etc.valgrind` client-request wrappers, the GC's shadow
interaction, and fibers.

#### Client requests: driving the A/V bits from D

druntime ships a D wrapper for the client API,
[`etc/valgrind/valgrind.d`][druntime-src], gated `debug(VALGRIND):`, whose module
doc is the recipe ([`:1`][druntime-src]):

> D wrapper for the Valgrind client API. Note that you must include this file
> into your program's compilation and compile with `-debug=VALGRIND` to access
> the declarations below.

`[source-verified]` It wraps **exactly seven** `memcheck` requests —
`makeMemNoAccess`/`makeMemUndefined`/`makeMemDefined`, `get`/`setVBits`,
`disable`/`enableAddrReportingInRange` — and **nothing else**: no
`RUNNING_ON_VALGRIND`, no `STACK_REGISTER`, no `VALGRIND_PRINTF`, no
`DO_LEAK_CHECK`. The mechanism is subtle enough that the research brief's
hypothesis was wrong on it:

> [!NOTE]
> **Discrepancy resolved: the D module does not carry the request macros.** The
> naive assumption was that importing `etc.valgrind` compiles the client-request
> assembly into the caller. It does not — the D wrappers only declare
> `extern(C) _d_valgrind_*`; the real `VALGRIND_*` macro expansions live in
> [`etc/valgrind/valgrind.c`][druntime-src], which is compiled
> **unconditionally into the shipped runtime** ([`druntime/Makefile:391`][druntime-src],
> `OBJS+=…valgrind$(DOTOBJ)`). Verified by `nm`: `libdruntime-ldc.a`'s
> `valgrind.c.o` defines all seven `_d_valgrind_*` `T` symbols, while the D
> module's object (built without `-debug=VALGRIND`) holds only `__ModuleInfo`;
> DMD's `libphobos2.a` likewise. So a consumer must compile the D wrapper
> _bodies_ itself (`-i=etc.valgrind`) while the `extern(C)` implementations
> resolve from the shipped runtime. `[hw-verified: x86_64-linux]`

The working user-code recipe, no druntime rebuild required, is therefore
`ldc2 --d-debug=VALGRIND -i=etc.valgrind app.d` (dub: `debugVersions "VALGRIND"`

- `dflags "-i=etc.valgrind"`) — verified to compile, link, run, and drive
  `memcheck`'s A/V bits from **both** compilers, whose import trees both ship
  `etc/valgrind/valgrind.d`. [`valgrind-client-requests.d`](./examples/valgrind-client-requests.d)
  is that recipe in CI: it marks a live block `NOACCESS` and reads it
  (`InvalidRead`), marks initialized memory `UNDEFINED` and branches on it
  (`UninitCondition`), and uses `getVBits`'s return value as a
  `RUNNING_ON_VALGRIND` substitute (druntime wraps no such request).
  `[hw-verified: x86_64-linux]`

> [!WARNING]
> **`etc.valgrind` breaks under DMD's shared Phobos — the configuration
> sparkles' linux-dmd unittests use.** `dmd -debug=VALGRIND -i=etc.valgrind
-defaultlib=libphobos2.so` fails to link (`undefined reference to
_d_valgrind_make_mem_noaccess`): DMD's shared `libphobos2.so` exports **zero**
> dynamic `_d_valgrind_*` symbols (they are `T` in the _static_ `libphobos2.a`
> only). sparkles' `unittest` configs pass exactly `-defaultlib=libphobos2.so`
> on linux-dmd, so `etc.valgrind` is unusable there without a workaround:
> hand-rolled requests (below), compiling `valgrind.c`'s ~38 lines into the
> build, or static Phobos. LDC's `--link-defaultlib-shared` is unaffected — its
> `libdruntime-ldc-shared.so` _does_ export the symbols. `[hw-verified: x86_64-linux]`

The escape hatch is a **hand-rolled** client request in ~20 lines of D inline
`asm` — the amd64 preamble plus `xchg`, args through `%rax`, result through
`%rdx` — which works under DMD and LDC alike on `x86_64`.
[`valgrind-attribution.d`](./examples/valgrind-attribution.d) uses it to
implement `RUNNING_ON_VALGRIND` (0x1001) and `VALGRIND_PRINTF` (0x1403). Two
traps a hand-roller must know:

- The **deprecated** `VG_USERREQ__PRINTF` (0x1401) hard-aborts on amd64: the
  scheduler runs `if (sizeof(va_list) != sizeof(UWord)) goto
va_list_casting_error` ([`scheduler.c:2049`][vg-src]). Use
  `PRINTF_VALIST_BY_REF` (0x1403) instead.
- On `linux-x86_64` D's `va_list` is _already_ the pointer to the `__va_list_tag`
  record, so `0x1403` wants `ap`, **not** `&ap` — passing `&ap` truncated the
  XML mid-record and aborted the run with exit 1. `[hw-verified: x86_64-linux]`

#### The GC interaction: noise, the blind-spot fix, and a dead-code bug

druntime carries `debug(VALGRIND)`-gated `memcheck` hooks in the conservative GC
(`makeMemUndefined`/`makeMemDefined` on alloc paths, sentinel `NOACCESS`, and
`disable`/`enableAddrReportingInRange` around scans —
[`gc.d:69,616,2511,5165,5482`][druntime-src]), added by
[`7cdae6e3bb`][druntime-src] ("Add Valgrind GC integration", 2023-06-15). They
are **not** in any shipped runtime (same gate as the D wrappers). Three findings:

- **GC noise on a real suite is tiny.** `memcheck` over the whole `:base`
  unittest binary (278 tests, `-t 1`) produced exactly **6 errors / 6 contexts**:
  one `UninitCondition` in `Gcx.mark` (the conservative scanner reading
  uninitialized stack words via `thread_scanAll` ← `fullcollect` ← `gc_term`),
  four `Leak_PossiblyLost` + one `Leak_DefinitelyLost` (three 1056-byte
  `defaultTraceHandler` allocations from `_d_throw_exception` in tests that
  deliberately throw, plus a 32-byte GC-init `malloc`). The "GC noise" story is
  really a "parallel-mode noise" story — see the runner concern. `[hw-verified: x86_64-linux]`
- **A 3-entry suppression file cleans the whole suite.** `--gen-suppressions=all`
  emits ready-to-paste blocks (in _mangled_ `fun:` frames); hand-minimized with
  wildcards to three entries:

  ```
  {
     druntime-gc-conservative-mark-uninit
     Memcheck:Cond
     fun:_D4core8internal2gc4impl12conservative*3Gcx*4mark*
  }
  {
     druntime-throwable-traceinfo-leak
     Memcheck:Leak
     fun:malloc
     fun:_D4core7runtime19defaultTraceHandlerFPvZC6object9Throwable9TraceInfo
  }
  {
     druntime-gc-initialize-leak
     Memcheck:Leak
     fun:malloc
     fun:_D4core8internal2gc4impl12conservative*initializeFZ*
  }
  ```

  This yields `ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 29 from 6)`
  and exit 0 under `--error-exitcode=99 --leak-check=full`. (Fiber-heavy
  programs add `Memcheck:Value8` in the same `Gcx.mark` frames plus
  `GCBits.set`/`test`; a 5-entry file covers those.) `--undef-value-errors=no`
  also gives a clean run but disables all V-bit checking — the whole point of
  `memcheck` — so [suppressions][suppression] are the right tool. `[hw-verified: x86_64-linux]`

- **The GC use-after-free blind spot is closable with no druntime rebuild.**
  Compiling the _shipped_ `gc.d` + `valgrind.d` sources into the app
  (`ldc2 --d-debug=VALGRIND uafgc.d $INC/core/internal/gc/impl/conservative/gc.d
$INC/etc/valgrind/valgrind.d`) lets the app's objects win over the archive
  members at link; the identical `GC.malloc → GC.free → read` program then
  reports **exactly one** error — `Invalid read of size 4 … uafgc.d:12`, the
  real bug — and the conservative-scan noise disappears. This is the same trick
  druntime's own `test/valgrind` harness uses. Caveat: LDC's include tree ships
  `gc.d` but **not** `rt/lifetime.d`, so the array-stomping hooks can't be added
  this way from the shipped tree alone. `[hw-verified: x86_64-linux]`

> [!NOTE]
> **Upstream bug candidate: `gc.d:3907` is dead code.** The pool-baseAddr
> poisoning `version (VALGRIND) makeMemNoAccess(baseAddr[0..poolsize]);` gates on
> **`version`** while everything else in the file — including the `import` that
> makes `makeMemNoAccess` visible — uses **`debug (VALGRIND)`**. druntime's own
> test harness sets only `-debug=VALGRIND`
> ([`druntime/test/valgrind/Makefile:26`][druntime-src]), never
> `-version=VALGRIND`, so this line never compiles anywhere; compiling with only
> `-version=VALGRIND` would be an error (no import). Pool-baseAddr marking is
> therefore effectively unimplemented. `[source-verified]`

#### Fibers: warnings, the 2 MB heuristic, and optional registration

Upstream druntime **never** registers fiber stacks with Valgrind — a grep over
`core/thread/` for `VALGRIND`/`STACK_REGISTER` is empty, and the LDC fork's
fiber `SupportSanitizers` machinery is ASan-only. Yet a `core.thread.fiber.Fiber`
program runs correctly under `memcheck`: no crash, no user-frame false positives.
The whole cost is cosmetic — Valgrind prints `Warning: client switching stacks?`
at most **three** times (a hard-coded rate limit,
[`coregrind/m_stacks.c:368`][vg-src] `static Int complaints = 3`) plus the same
GC-scan noise. `[hw-verified: x86_64-linux]`

The heuristic behind the warning is why registration is _optional_ here. An SP
delta beyond `--max-stackframe` (default 2,000,000 — [`m_options.c:189`][vg-src])
is read as a stack switch, and Valgrind deliberately leaves permissions alone
([`m_stacks.c:359`][vg-src]):

> if a stack switch happens, it seems best not to mess at all with memory
> permissions … Really the only remaining difficulty is knowing exactly when a
> stack switch is happening.

`[source-verified]` Valgrind auto-registers only the main stack
([`m_stacks.c:84`][vg-src]: "No other stacks are automatically registered by
Valgrind, however."), and `VALGRIND_STACK_REGISTER` from user code works —
a hand-rolled request returned stack id 1, and the registered fiber's switches
stopped warning while an unregistered fiber kept warning (identical under DMD).

> [!WARNING]
> **The <2 MB-adjacency hazard is real but source-derived, not observed.** If
> two fiber stacks are `mmap`'d within 2 MB of each other, an _unregistered_
> switch would look like ordinary stack growth and Valgrind would rewrite the
> other fiber's A/V shadow (`die_mem_stack` on the way up, [`m_stacks.c`][vg-src]
> logic). This is precisely what [`VALGRIND_STACK_REGISTER`][fiber-annotation]
> exists to prevent; no shipped druntime calls it, and the survey did not
> reproduce a corruption (all observed switches had >2 MB deltas). Registration
> is the only robust guard for the sub-2 MB regime. `[source-verified]`

**`-betterC` is N/A with a reason:** a `-betterC` build links no druntime, so
there is no GC, no fiber machinery, and no `etc.valgrind` module — `memcheck`
just works on the bare binary, and none of this concern applies.

### Runtime control and report capture

Valgrind is configured entirely by **CLI flags** — there is no `ASAN_OPTIONS`
analog steering it from the environment (`$VALGRIND_OPTS` exists but flags are
the story), which is one fewer runner-owned surface than the LLVM tools. The
[weak-hook control surface][halt-vs-recover] the compiler-rt tools expose is
replaced here by the CLI plus [client requests][client-request]. The flags a
`--valgrind` runner mode drives:

- **`--xml=yes --xml-file=<path>`** emits the machine-readable **protocol-4**
  stream (below) — a stronger transport than regex-over-text.
- **`--error-exitcode=N`** turns "any error was reported" into exit code `N`;
  the default 0 passes the child's own code through, and — the load-bearing
  detail — **suppressed** errors do _not_ trigger it (a clean suppressed run
  exits 0 with `--error-exitcode=99` set). `--exit-on-first-error=yes` is the
  fail-fast switch. `[hw-verified: x86_64-linux]`
- **`--suppressions=<file>`** (repeatable) + **`--gen-suppressions=yes|all`**
  (emits ready-to-paste, [mangled][suppression] blocks) is the noise-management
  loop demonstrated above.
- **`--track-origins=yes`**, **`--undef-value-errors=no`**, **`--leak-check=full`**,
  **`--fair-sched=yes`** (see the runner concern), **`--max-stackframe=N`** tune
  definedness depth, the leak scan, and the fiber/scheduler behaviour.
- **Client requests** add in-band control an unmodified binary can issue:
  `VALGRIND_PRINTF` (stream markers), `VALGRIND_DO_LEAK_CHECK`,
  `VALGRIND_COUNT_ERRORS`, and the `MAKE_MEM_*` family.

Unlike ASan's default halt, `memcheck` is **report-and-continue** — the
[halt-vs-recover][halt-vs-recover] policy is _always_ "recover" here: the
use-after-free child printed its read-after-free value and ran to a normal exit,
with every finding of the run collected in one pass. The end-to-end no-recompile
pipeline — XML output plus `--error-exitcode`, on an uninstrumented binary — is
what [`valgrind-memcheck-catch.d`](./examples/valgrind-memcheck-catch.d) drives
and asserts (exit 99, `<kind>InvalidRead</kind>` at the right `<file>`/`<line>`,
and the child surviving past the defect). `[hw-verified: x86_64-linux]`

### Symbolization and report quality

Valgrind carries **its own DWARF reader and its own D demangler** — no
`llvm-symbolizer`, no `ddemangle`, nothing external in the pipeline.
`D main` and `core.internal.gc.impl.conservative.gc.Gcx.mark!(…).mark(…)` appear
demangled in reports with no tooling, and `<frame>` records in the XML carry
`{ip, [obj], [fn], [dir], [file], [line]}` ([`xml-output-protocol4.txt:230`][vg-src]).
This is a categorical improvement over the [LLVM runtimes][d-toolchain], whose
GCC-libsanitizer fallback self-symbolizes via `libbacktrace` but **never**
demangles D. The one place mangled names return is [suppressions][suppression]:
`--gen-suppressions` writes `fun:` frames in mangled form, so a D suppression
glob must target mangled text (as the 3-entry file above does).

The **protocol-4** XML is the report format a runner parses: one
`<valgrindoutput>` stream per process, `<protocolversion>4` +
`<protocoltool>memcheck|helgrind|drd`, preamble, then — inside the RUNNING
window — "Zero or more of (either ERRORCOUNTS, TOOLSPECIFIC, or CLIENTMSG)"
([`docs/internals/xml-output-protocol4.txt:192`][vg-src]), then FINISHED, the
post-run leak errors, and `SUPPCOUNTS`. Each `<error>` is
`{unique, tid, [threadname], kind, what/xwhat, STACK, auxwhats, [suppression]}`
([`:400`][vg-src]); memcheck's `<kind>` enum includes `UninitValue`,
`UninitCondition`, `InvalidRead`, `InvalidWrite`, `SyscallParam`, `ClientCheck`,
and the `Leak_*` set, and helgrind's includes `Race`. `[source-verified]`
`[hw-verified: x86_64-linux]`

### Runner integration semantics

The **process is the isolation unit**: a `--valgrind` mode wraps the test
binary, it does not link anything into it — the [wrapper-and-parse][wrapper-and-parse]
design, over Valgrind's XML rather than regex-over-text. Three semantics follow.

**Per-test attribution works via marker windows.** `VALGRIND_PRINTF` /
`VALGRIND_PRINTF_BACKTRACE` become `<clientmsg>` records that **interleave with
`<error>` records in program order** ([`xml-output-protocol4.txt:679`][vg-src]),
so a marker emitted before each test segments that process's error stream:
everything between marker _N_ and marker _N+1_ belongs to test _N_.
[`valgrind-attribution.d`](./examples/valgrind-attribution.d) proves it —
`clientmsg(test=1)` at stream offset m1 < `error(InvalidRead)` at e1 < `clientmsg(test=2)`
at m2 < `error(InvalidWrite)` at e2 — and locks it in CI. This is the survey's
in-process [report-windowing][report-windowing] design realized over Valgrind's
transport, and it is the same pattern pytest-valgrind uses. Two caveats a runner
must own: (i) Valgrind **deduplicates by error context**, so a repeat of an
already-reported error emits no new `<error>` (only end-of-run
`<errorcounts>` totals) — marker-window attribution sees each context's _first_
occurrence only; (ii) there are **no error timestamps** (status records carry a
human `<time>`, errors do not), so the markers are the _only_ segmentation
available — in a parallel run the windows must be kept per `<tid>`, which is moot
once the mode forces `-t 1`. `[hw-verified: x86_64-linux]`

**The mode must force `-t 1` and pass `--fair-sched=yes`.** sparkles' in-process
`TaskPool` runner is pathological under Valgrind's default scheduler, which
serializes all threads on one unfair pipe-based lock that starves the worker
actually holding the queue:

| Configuration                          | native  | memcheck | +origins | helgrind |
| -------------------------------------- | ------- | -------- | -------- | -------- |
| `:base` suite `-t 1`                   | 0.004 s | 1.156 s  | —        | 0.867 s  |
| `:base` suite `-t auto` (32 threads)   | 0.007 s | 156.5 s  | —        | 37.0 s   |
| `:base` `-t auto` + `--fair-sched=yes` | —       | 1.268 s  | —        | —        |
| cpuwork (0.200 s CPU-bound)            | 0.200 s | 1.126 s  | 1.602 s  | 0.624 s  |
| startup (trivial `void main`)          | 0.001 s | 0.255 s  | 0.332 s  | 0.209 s  |
| marginal ratio (cpuwork)               | 1×      | 4.4×     | 6.4×     | 2.1×     |

The `-t auto` memcheck run was not merely slow but _pathologically variable_
(spread 12.5–180 s on a 4 ms suite); `--fair-sched=yes` (round-robin ticket
lock) collapses it to 1.27 s and drops `-t 4` from 12.3 s to 1.17 s. The
tiny-suite figures are startup-dominated (~0.25 s fixed); the marginal ratios
(hot ALU loop) flatter the manual's 10-50× headline — both should be reported.
`[hw-verified: x86_64-linux]`

**Thread tools are clean only at `-t 1`.** `helgrind` on `:base` at `-t 1` = **0
errors, 0 suppressed** (perfectly clean); at `-t 4` = **3,249 errors from 142
contexts** (+22,045 suppressed occurrences), and `DRD` at `-t 4` = 15,863
errors. The top noise frames are `Gcx.smallAlloc`, `SpinLock.lock`/`unlock`, and
`Pool.setBits`: the GC's `core.internal.spinlock`-built, atomics-based `SpinLock`
is **invisible** to helgrind/DRD, which model pthread primitives not raw atomics
([vector-clocks][vector-clocks]), so everything under the GC lock looks racy.
Both tools also **miss a genuine short race** — a two-thread `counter++` with no
rendezvous reported **zero** races from both, because Valgrind's serialization
plus druntime's global thread-start/exit lock created a real happens-before edge
covering all accesses; adding a two-way atomic rendezvous made both report it,
and [TSan][tsan] catches the no-rendezvous program because its threads genuinely
overlap. This is a structural false-negative class for any serialized-scheduler
detector on short tests.

> [!WARNING]
> **nixpkgs' `default.supp` blankets all of libc for helgrind.** The generated
> entry `helgrind-glibc2X-005` is `Helgrind:Race` with a single frame
> `obj:*/lib*/libc.so.6`. The upstream template targeted `@GLIBC_LIBPTHREAD_PATH@`
> ([`glibc-2.X-helgrind.supp.in:75`][vg-src]), but since glibc 2.34 merged
> libpthread into `libc.so.6`, the pattern now suppresses **any** race whose
> innermost frame is anywhere in libc — real `memcpy`/`memmove` races on user
> buffers included. Upstream carries a 2009 FIXME
> ([`glibc-2.X-helgrind.supp.in:4`][vg-src]): "helgrind-glibc2X-005 overlaps with
> a lot of other stuff. They should be removed." Observed eating 65 occurrences /
> 17 contexts on the race fixture. `[hw-verified: x86_64-linux]` `[source-verified]`

Between the two thread tools: `DRD` is intrinsically quieter on druntime's
primitives (1 suppressed context vs helgrind's 17 on a correct-`Mutex` fixture)
and needs no glibc blanket, but floods per-_access_ counts on a real race
(200,000 instances from 2 contexts). `helgrind` dedups tersely (2 contexts with
both stacks) and adds a lock-order class. The proposal's recommendation:
`helgrind` as default (terse dedup, lock ordering, same XML), `DRD` as a second
opinion, `-t 1` forced for both, and neither replacing TSan for short races.

### Platform and toolchain coverage

Valgrind is **compiler-independent** by construction: it instruments the binary,
so LDC, GDC, and DMD are all first-class, and DMD — with no `-fsanitize` support
of any kind — reaches its _only_ dynamic memory/threading verification path here,
at full fidelity (see [d-toolchain.md][d-toolchain]). Every claim on this page is
`[hw-verified: x86_64-linux]` on both LDC 1.41 and DMD 2.112; the overhead is the
table in the runner concern (fixed ~0.25 s startup, marginal 4.4×/6.4×/2.1× for
memcheck/+origins/helgrind on a hot loop).

macOS is the gap. Stock upstream Valgrind's `configure.ac` hard-errors on any
Darwin newer than 17.x — macOS 10.13 High Sierra, 2017 —
([`configure.ac:476`][vg-src]: `AC_MSG_ERROR([Valgrind works on Darwin 10.x …
17.x (Mac OS X 10.6/7/8/9/10/11 and macOS 10.12/13)])`), so it does not build on
any current macOS and has **no** Apple-Silicon port at all; the community
[`LouisBrunner/valgrind-macos`][louisbrunner] fork carries macOS support forward
but is outside nixpkgs and outside the survey's `aarch64-darwin` bed. `[source-verified]`
Full treatment — and the Windows story, where [Dr. Memory][macos-windows] is the
no-recompile analog — is in [macos-windows.md][macos-windows].

---

## Strengths

- **No recompilation, no flags, every compiler.** An unmodified LDC/GDC/DMD
  binary is checked as-is; `-g` only adds `file:line`. This is what makes it
  DMD's only path and a zero-build-change runner mode.
- **Definedness that ASan cannot reach.** Per-bit V-bits catch
  `UninitValue`/`UninitCondition` — a whole error class outside ASan's
  addressability-only shadow.
- **Built-in D demangling and DWARF reading.** Reports and stacks are readable
  with no `llvm-symbolizer`/`ddemangle` — a categorical win over the D-blind
  LLVM runtimes.
- **Machine-readable protocol-4 XML** with in-stream `<clientmsg>` markers gives
  clean, parseable, per-test attribution — a stronger transport than
  regex-over-log.
- **Report-and-continue** collects every finding of a run in one pass, with an
  opt-in `--error-exitcode` for a cheap pass/fail signal.
- **The GC blind spot is closable without a druntime rebuild** — compile the
  shipped `gc.d` + `valgrind.d` with `-debug=VALGRIND`.

## Weaknesses

- **10-50× headline slowdown** (though marginal ratios on hot code are far
  lower), and a **pathological in-process-parallel interaction** — 156 s vs
  1.16 s on a 4 ms suite — that forces `-t 1` + `--fair-sched=yes`.
- **No redzones**: a small overrun inside a `malloc` block is missed where ASan
  catches it.
- **GC use-after-free is invisible** by default (the `mmap`'d-pool blind spot),
  and the shipped GC hooks are dead (`debug`-gated, plus the `gc.d:3907`
  `version` bug).
- **`etc.valgrind` breaks under DMD's shared Phobos** — the sparkles linux-dmd
  unittest configuration — needing a hand-rolled or static-Phobos workaround.
- **helgrind/DRD are unusable at `-t > 1`** on druntime (GC `SpinLock` invisible)
  and **miss short serialized races** that TSan catches; nixpkgs' helgrind
  default suppressions over-blanket libc.
- **No environment-variable control surface** and **no error timestamps** — CLI
  flags and stream markers are the only levers.
- **Effectively dead on macOS** (configure hard-error past 2017; no Apple-Silicon
  port outside a community fork).

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                             | Trade-off                                                                                            |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Dynamic binary translation (VEX JIT) over an instrumentation pass | Works on any unmodified binary from any compiler; DMD's only path; covers libc and all libraries      | 10-50× headline slowdown; every instruction is re-translated                                         |
| 8 V-bits + 1 A-bit per byte, compressed to 2 bits                 | Tracks _definedness_ per bit, not just addressability — the `UninitCondition` class ASan can't report | 9-bits-of-metadata cost; no read-only state; no redzones (small in-block overruns missed)            |
| Client requests via a magic no-op instruction sequence            | An unmodified binary can annotate the tool (markers, `MAKE_MEM_*`, stack registration)                | The D `etc.valgrind` wrappers ship source-only + C-prebuilt, and break under DMD shared Phobos       |
| Report-and-continue, opt-in `--error-exitcode`                    | All findings in one pass; a cheap pass/fail signal on demand                                          | A runner must decide the exit-code policy; suppressed errors deliberately don't trigger the code     |
| Serialize all threads on one scheduler lock (default unfair)      | Highest throughput for sequential-thread workloads                                                    | Pathological + wildly variable for an in-process parallel runner; forces `-t 1` + `--fair-sched=yes` |
| Model pthread primitives in helgrind/DRD                          | Catches the common mutex/lock-order/API-misuse bugs                                                   | Blind to `core.atomic`/`SpinLock` — everything under the GC lock is a false race at `-t > 1`         |
| Built-in DWARF reader + D demangler                               | Readable reports with no external symbolizer                                                          | Suppressions still use mangled `fun:` frames (what `--gen-suppressions` emits)                       |

---

## Sources

- [Valgrind manual][vg-manual] and the [source tree][vg-src] (read at
  `valgrind@218cee2f`, tag `VALGRIND_3_26_0`): `memcheck/mc_main.c` (V/A-bit
  model, shadow layout, read-only aside), `include/valgrind.h.in` +
  `VEX/priv/guest_amd64_toIR.c` + `coregrind/m_scheduler/scheduler.c` (client
  requests), `coregrind/m_stacks.c` + `m_options.c` (stack switching),
  `docs/internals/xml-output-protocol4.txt` (protocol 4),
  `docs/xml/manual-core.xml` + `memcheck/docs/mc-manual.xml` (slowdown, origins,
  `--error-exitcode`, `--fair-sched`), `helgrind/`/`drd/` docs + `libhb_core.c` /
  `drd_thread.h`, `glibc-2.X-helgrind.supp.in` (the over-broad suppression),
  `configure.ac` (the macOS hard-error) — all cited inline
- druntime at [`dmd@e6baf474`][druntime-src]: `etc/valgrind/{valgrind.d,valgrind.c}`
  (the seven wrappers, the ship matrix), `core/internal/gc/impl/conservative/gc.d`
  (the `debug(VALGRIND)` hooks and the `:3907` `version` bug), `Makefile` +
  `test/valgrind/Makefile` (unconditional C object, the source-into-app trick);
  LDC fork `ldc@f4d2f831` (same `etc/valgrind/` shape, no fiber hooks)
- Runnable probes: [`valgrind-memcheck-catch.d`](./examples/valgrind-memcheck-catch.d)
  (the no-recompile XML/exit-code pipeline, E1) ·
  [`valgrind-client-requests.d`](./examples/valgrind-client-requests.d)
  (`etc.valgrind` driving A/V bits, E8) ·
  [`valgrind-attribution.d`](./examples/valgrind-attribution.d) (marker-window
  attribution, E5)
- The Valgrind papers (Nethercote & Seward, PLDI 2007 framework + VEE 2007
  shadow-memory — two distinct papers)
- Sibling pages: [asan.md][asan] (the shadow/redzone contrast), [tsan.md][tsan]
  (the race it catches where helgrind/DRD miss), [d-toolchain.md][d-toolchain]
  (DMD's only path; the LLVM-runtime demangling gap), [macos-windows.md][macos-windows]
  (the macOS/Dr. Memory story), [comparison.md][comparison]
- Shared vocabulary: [concepts.md][concepts] ([instrumentation locus][locus],
  [definedness vs addressability][def-vs-addr], [client request][client-request],
  [the GC memory blind spot][gc-blind-spot], [suppression][suppression],
  [halt vs recover][halt-vs-recover], [report windowing][report-windowing],
  [wrapper-and-parse][wrapper-and-parse], [fiber annotation][fiber-annotation],
  [allocator interception][allocator-interception])

<!-- References -->

[concepts]: ./concepts.md
[locus]: ./concepts.md#instrumentation-locus
[def-vs-addr]: ./concepts.md#definedness-vs-addressability
[shadow]: ./concepts.md#shadow-memory
[redzone]: ./concepts.md#redzone
[client-request]: ./concepts.md#client-request
[suppression]: ./concepts.md#suppression
[halt-vs-recover]: ./concepts.md#halt-vs-recover
[report-windowing]: ./concepts.md#report-windowing
[wrapper-and-parse]: ./concepts.md#wrapper-and-parse
[fiber-annotation]: ./concepts.md#fiber-annotation
[gc-blind-spot]: ./concepts.md#the-gc-memory-blind-spot
[allocator-interception]: ./concepts.md#allocator-interception
[vector-clocks]: ./concepts.md#vector-clocks-and-happens-before
[asan]: ./asan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[macos-windows]: ./macos-windows.md
[comparison]: ./comparison.md
[vg-src]: https://sourceware.org/git/?p=valgrind.git;a=tree
[vg-manual]: https://valgrind.org/docs/manual/manual.html
[druntime-src]: https://github.com/dlang/dmd/tree/master/druntime/src
[louisbrunner]: https://github.com/LouisBrunner/valgrind-macos
