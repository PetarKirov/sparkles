# Grounding ledger — `valgrind.md`

Claim-by-claim verification of `docs/research/sanitizers/valgrind.md` against the
pinned tree `valgrind@218cee2f` (tag `VALGRIND_3_26_0` = source 3.26.0 = the
runtime-tested nixpkgs build — **no version skew**), druntime at `dmd@e6baf474`
and the LDC fork `ldc@f4d2f831`. Hardware experiments recorded on **Linux
6.18.26**, **AMD Ryzen 9 7940HX** (Zen 4), **valgrind 3.26.0**, **LDC 1.41.0**
and **DMD 2.112.1** (every experiment run on both compilers' binaries).
`$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable / open · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                                                                                                      | Type       | Source (local + locator)                                                                                               | Status          |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------------- | --------------- |
| L1  | `memcheck` shadows every byte with 8 V-bits (definedness) + 1 A-bit (addressability); compressed to 2 bits/byte (`VA_BITS2_NOACCESS/UNDEFINED/DEFINED/PARTDEFINED`), exact V-bits for partial bytes in a secondary table   | quote      | `memcheck/mc_main.c:100` (_"every byte value has 8 V bits … 8 V bits and one A bit"_ verbatim); encodings `:238`       | ✓               |
| L2  | Shadow layout: 2²⁰ primary map over bottom 64 GB (address bits 16..35), sparse aux table, 3 distinguished secondary maps share 64 KB chunks                                                                                | fact       | `mc_main.c:120-150`                                                                                                    | ✓               |
| L3  | No read-only state — `makeMemNoAccess` is all-or-nothing ("we have no way of marking memory as read-only")                                                                                                                 | quote      | `mc_main.c:157` (verbatim)                                                                                             | ✓               |
| L4  | Headline 10-50× slowdown — "adds code to check every memory access and every value computed, making it run 10-50 times slower than natively"                                                                               | quote      | `docs/xml/manual-core.xml:59` (verbatim)                                                                               | ✓               |
| L5  | DBI: the VEX JIT re-translates every instruction incl. libc and all dynamically-linked libraries; nothing recompiled                                                                                                       | quote      | `manual-core.xml:64-70`; [locus][locus] (concepts)                                                                     | ✓ (hw)          |
| L6  | amd64 client-request preamble: four `rolq` on `%rdi` (3,13,61,51 — net no-op) + `xchgq %rbx,%rbx`; args in `%rax`, result in `%rdx`                                                                                        | fact       | `include/valgrind.h.in:422-455`; probe `valgrind-attribution.d`                                                        | ✓ (hw)          |
| L7  | VEX matches the bytes → `Ijk_ClientReq`; scheduler dispatches (RUNNING*ON_VALGRIND, PRINTF\*, STACK*\*)                                                                                                                    | fact       | `VEX/priv/guest_amd64_toIR.c:32270-32296`; `coregrind/m_scheduler/scheduler.c:2040-2129`                               | ✓               |
| L8  | `--track-origins`: 32-bit tag = 30-bit ECU + 2-bit kind (`HEAP/STACK/USER/UNKNOWN`); "halves Memcheck's speed and increases memory use by ≥100MB"; measured 1.126 → 1.602 s                                                | quote      | `memcheck/mc_include.h:179-210`; `memcheck/docs/mc-manual.xml:1100` (verbatim); Experiment E3                          | ✓ (hw)          |
| L9  | No recompile; `-g` buys `file:line` only; frames demangled from ELF symtab without it; LDC and DMD byte-equivalent verdicts (`InvalidRead` `uaf.d:10`, exit 99)                                                            | behavior   | Experiment E1 (`valgrind-memcheck-catch.d`)                                                                            | ✓ (hw)          |
| L10 | `etc.valgrind.valgrind` wraps exactly 7 memcheck requests (`makeMem{NoAccess,Undefined,Defined}`, `get/setVBits`, `en/disableAddrReportingInRange`); module gated `debug(VALGRIND):`; doc recipe demands `-debug=VALGRIND` | quote      | `druntime/src/etc/valgrind/valgrind.d:1` (verbatim), `:48`, `:50-85`                                                   | ✓               |
| L11 | The C side (`_d_valgrind_*`, in `valgrind.c`) is compiled **unconditionally** into shipped druntime; the D wrapper bodies are not                                                                                          | fact       | `druntime/Makefile:391`; `nm` on `libdruntime-ldc.a` / `libphobos2.a` (7× `T`, D-module object `__ModuleInfo`-only)    | ✓ (hw)          |
| L12 | Working user recipe (no rebuild): `--d-debug=VALGRIND -i=etc.valgrind`; both LDC 1.41 & DMD 2.112 ship `etc/valgrind/valgrind.d` in their import trees                                                                     | behavior   | Experiment E8 (`valgrind-client-requests.d`)                                                                           | ✓ (hw)          |
| L13 | DMD + shared Phobos link-fails (`undefined reference _d_valgrind_*`; `libphobos2.so` exports 0 dynamic); sparkles' linux-dmd unittest config passes `-defaultlib=libphobos2.so`                                            | behavior   | Experiment E8; `nm -D libphobos2.so`; sparkles unittest dub.sdl                                                        | ✓ (hw)          |
| L14 | Hand-rolled request (~20 lines D `asm`) works under DMD+LDC on x86_64; deprecated `0x1401` aborts (`va_list` size check); pass `ap` not `&ap`                                                                              | behavior   | `coregrind/m_scheduler/scheduler.c:2049-2052`; Experiment E5 (`valgrind-attribution.d`)                                | ✓ (hw)          |
| L15 | druntime GC carries `debug(VALGRIND)`-gated memcheck hooks (alloc-path make-mem, sentinel NOACCESS, scan reporting), NOT in shipped runtime; added `7cdae6e3bb` (#15304, 2023-06-15)                                       | fact       | `gc.d:69,616,2511,2567,2796,5165-5180,5482-5520`; git blame                                                            | ✓               |
| L16 | GC noise on `:base` (278 tests, `-t 1`) = exactly 6 errors / 6 contexts (1 `UninitCondition` in `Gcx.mark`; 4 `Leak_PossiblyLost` + 1 `Leak_DefinitelyLost` from `defaultTraceHandler`/GC-init)                            | figure     | Experiment E2                                                                                                          | ✓ (hw)          |
| L17 | 3-entry wildcarded suppression file → `0 errors from 0 contexts (suppressed: 29 from 6)`, exit 0; `--undef-value-errors=no` also clean but disables all V-bit checking                                                     | behavior   | Experiment E2; the 3 patterns reproduced in the page                                                                   | ✓ (hw)          |
| L18 | GC use-after-free is invisible to stock memcheck: `GC.malloc → GC.free → read` = 0 `Invalid*` (mmap'd pool, no malloc-replacement A-bits)                                                                                  | behavior   | Experiment E7 (scratch `uafgc.d`)                                                                                      | ✓ (hw)          |
| L19 | Closable with no druntime rebuild: compile shipped `gc.d` + `valgrind.d` with `-debug=VALGRIND` → exactly 1 pinpointed `Invalid read` at `uafgc.d:12`, scan noise gone; LDC include tree omits `rt/lifetime.d`             | behavior   | Experiment E7; `druntime/test/valgrind/Makefile:17-26` (the same trick)                                                | ✓ (hw)          |
| L20 | `gc.d:3907` is dead code — gates `version (VALGRIND)` while the file (incl. the import) uses `debug (VALGRIND)`; the test harness only sets `-debug=VALGRIND`                                                              | behavior   | `gc.d:3907` (verified `version (VALGRIND) makeMemNoAccess(baseAddr[0..poolsize]);`); `test/valgrind/Makefile:26`       | ✓ (⚠ D-V2)      |
| L21 | Upstream druntime never registers fiber stacks (`core/thread/` grep empty); LDC fork's fiber `SupportSanitizers` machinery is ASan-only                                                                                    | fact       | grep over `dmd@e6baf474` + `ldc@f4d2f831` `runtime/druntime/src/core/thread/`                                          | ✓               |
| L22 | Fibers under memcheck: no crash, no user-frame false positives; at most 3 rate-limited "client switching stacks?" warnings + GC-scan noise                                                                                 | behavior   | `coregrind/m_stacks.c:368` (`static Int complaints = 3`); Experiment E4                                                | ✓ (hw)          |
| L23 | Stack-switch heuristic: SP delta > `--max-stackframe` (default 2,000,000) = switch, permissions left alone; only the main stack auto-registered (id 0)                                                                     | quote      | `m_stacks.c:359` (verbatim), `:84` (verbatim); `coregrind/m_options.c:189`                                             | ✓               |
| L24 | `VALGRIND_STACK_REGISTER` from user code works: registered fiber got stack id 1 and stopped warning; unregistered fiber still warned; DMD identical                                                                        | behavior   | Experiment E4                                                                                                          | ✓ (hw)          |
| L25 | The <2 MB fiber-stack adjacency hazard (unregistered switch corrupts a neighbour's shadow) is source-derived, not observed                                                                                                 | exposition | `m_stacks.c:358-425` logic; not reproduced (all observed deltas >2 MB)                                                 | ◯               |
| L26 | `-betterC` is N/A: no druntime linked → no GC, no fibers, no `etc.valgrind`; memcheck works on the bare binary                                                                                                             | exposition | reasoned from the `-betterC` build model                                                                               | ✓               |
| L27 | Configured by CLI flags only — no `ASAN_OPTIONS` analog steering it (`$VALGRIND_OPTS` exists but flags are the story)                                                                                                      | fact       | `manual-core.xml` (options chapter)                                                                                    | ✓               |
| L28 | `--error-exitcode=N`: default 0 passes the child's code; `N` returned iff errors reported; suppressed errors do NOT trigger it; `--exit-on-first-error` for fail-fast                                                      | behavior   | `manual-core.xml:1269-1300`; Experiments E1/E2 (clean suppressed run exit 0 with `--error-exitcode=99`)                | ✓ (hw)          |
| L29 | Report-and-continue (contrast ASan default halt): the UAF child printed its read-after-free value and exited normally; all findings in one pass                                                                            | behavior   | Experiment E1                                                                                                          | ✓ (hw)          |
| L30 | Built-in DWARF reader + built-in D demangler — no `llvm-symbolizer`/`ddemangle`; `D main` / `Gcx.mark!(…)` appear demangled                                                                                                | behavior   | Experiment E1                                                                                                          | ✓ (hw)          |
| L31 | Protocol-4 XML: one `<valgrindoutput>` stream/process, `<protocolversion>4` + `<protocoltool>`; RUNNING window = "Zero or more of (ERRORCOUNTS, TOOLSPECIFIC, or CLIENTMSG)"; `<error>`/`<frame>` grammar                  | quote      | `docs/internals/xml-output-protocol4.txt:192` (verbatim), `:400-458`, `:230-258`                                       | ✓ (hw)          |
| L32 | memcheck `<kind>` enum (`UninitValue`, `UninitCondition`, `InvalidRead/Write`, `SyscallParam`, `ClientCheck`, `Leak_*`); helgrind `<kind>Race`                                                                             | fact       | `xml-output-protocol4.txt:495-560`; verified in captured output                                                        | ✓ (hw)          |
| L33 | Suppressions use **mangled** `fun:` frames (what `--gen-suppressions` emits), even though reports self-demangle                                                                                                            | fact       | Experiment E2; `manual-core.xml:1590-1650`                                                                             | ✓ (hw)          |
| L34 | `VALGRIND_PRINTF` → `<clientmsg>` records interleave with `<error>` in program order (m1 < e1 < m2 < e2) — marker-window per-test attribution                                                                              | figure     | `xml-output-protocol4.txt:679-715`; Experiment E5 (`valgrind-attribution.d`)                                           | ✓ (hw)          |
| L35 | Two attribution caveats: valgrind dedups by error context (marker window sees first occurrence only); no error timestamps (only `<time>` on status records)                                                                | behavior   | Experiment E5; protocol-4 status vs error records                                                                      | ✓ (hw)          |
| L36 | In-process parallelism is pathological: `-t 1` 1.156 s, `-t auto` 156.5 s (spread 12.5–180 s), `--fair-sched=yes` → 1.268 s; `-t 4` 12.3 → 1.17 s                                                                          | figure     | Experiment E3                                                                                                          | ✓ (hw)          |
| L37 | Slowdown table (medians of 3): memcheck 4.4×, +origins 6.4×, helgrind 2.1× marginal on a CPU-bound fixture; startup ≈ 0.25 s fixed                                                                                         | figure     | Experiment E3                                                                                                          | ✓ (hw)          |
| L38 | helgrind on `:base`: `-t 1` = 0 errors / 0 suppressed; `-t 4` = 3,249 errors / 142 ctx (+22,045 supp); DRD `-t 4` = 15,863; GC `SpinLock` (atomics, not pthread) invisible                                                 | figure     | Experiment E6                                                                                                          | ✓ (hw)          |
| L39 | Both tools MISS a short no-rendezvous `counter++` race (serialization + druntime global thread-start lock = happens-before); adding a rendezvous makes both report it; TSan catches the no-rendezvous program              | behavior   | Experiment E6; TSan smoke test                                                                                         | ✓ (⚠ D-V4)      |
| L40 | DRD quieter on druntime sync (1 vs 17 suppressed ctx on a Mutex fixture) but floods 200 k per-access instances on a real race; helgrind dedups (2 ctx) + adds lock-order                                                   | figure     | Experiment E6                                                                                                          | ✓ (hw)          |
| L41 | nixpkgs `default.supp` `helgrind-glibc2X-005` = `Helgrind:Race` + `obj:*/lib*/libc.so.6` blankets all of libc (glibc 2.34 merged libpthread); upstream 2009 FIXME; ate 65 occ / 17 ctx                                     | quote      | `default.supp:1016`; `glibc-2.X-helgrind.supp.in:75` (template) & `:4` (FIXME, verbatim); Experiment E6                | ✓ (hw) (⚠ D-V5) |
| L42 | Both are happens-before vector-clock detectors; helgrind detects 3 classes (API-misuse, lock-order, race), DRD detects races + contention + API-misuse (no lock-order)                                                     | fact       | `helgrind/libhb_core.c:4-10`; `helgrind/docs/hg-manual.xml:28-43`; `drd/drd_thread.h:67-68`; `drd/docs/drd-manual.xml` | ✓               |
| L43 | Compiler-independent (LDC = GDC = DMD); DMD's only dynamic verification path (DMD 2.112 has zero `-fsanitize` flags)                                                                                                       | behavior   | recon (DMD flag scan); every experiment ran on both LDC 1.41 and DMD 2.112                                             | ✓ (hw)          |
| L44 | Stock upstream valgrind's `configure.ac` hard-errors past Darwin 17.x (macOS 10.13, 2017); no Apple-Silicon port; `LouisBrunner/valgrind-macos` fork carries macOS forward                                                 | quote      | `configure.ac:476` (verbatim `AC_MSG_ERROR([Valgrind works on Darwin 10.x … 17.x …])`); W6 fork README                 | ✓ (src)         |
| L45 | The "Valgrind PLDI 2007" citation is two distinct papers: PLDI 2007 (framework/DBI) and VEE 2007 ("How to Shadow Every Byte…")                                                                                             | fact       | `$REPOS/papers/sanitizers/{valgrind-framework-pldi-2007,memcheck-shadow-every-byte-vee-2007}.pdf`                      | ✓ (⚠ D-V3)      |
| E1  | memcheck catch parity + protocol-4 XML + `--error-exitcode`, LDC = DMD (backs L9, L28-L30)                                                                                                                                 | figure     | `valgrind-memcheck-catch.d`                                                                                            | ✓ (hw)          |
| E2  | GC noise catalog + `--gen-suppressions` round-trip → 3-entry clean run (backs L16, L17, L33)                                                                                                                               | figure     | scratch `:base` binary + `druntime.supp`                                                                               | ✓ (hw)          |
| E5  | Marker-window attribution: markers interleave in XML stream order (backs L14, L34, L35)                                                                                                                                    | figure     | `valgrind-attribution.d`                                                                                               | ✓ (hw)          |
| E8  | `etc.valgrind` importability & link matrix (backs L10-L13)                                                                                                                                                                 | figure     | `valgrind-client-requests.d` + `nm` evidence                                                                           | ✓ (hw)          |

## Discrepancies

- **⚠ D-V1 — the `etc.valgrind` mechanism (register R10).** The brief assumed
  importing `etc.valgrind` compiles the client-request macros into the caller.
  The D module only declares `extern(C) _d_valgrind_*`; the macros live in
  `valgrind.c`, compiled **unconditionally into the shipped runtime**
  (`Makefile:391`). User code needs `-debug=VALGRIND -i=etc.valgrind`, and it
  **breaks under DMD's shared Phobos** (0 dynamic `_d_valgrind_*` exports) — the
  linux-dmd unittest configuration. Corrected in the page (a NOTE + a WARNING).
  `[hw-verified: x86_64-linux]`
- **⚠ D-V2 — `gc.d:3907` is dead code (register R11).** The pool-baseAddr
  `makeMemNoAccess` gates on `version (VALGRIND)` while the whole file (including
  the import that makes the symbol visible) uses `debug (VALGRIND)`; druntime's
  own test harness only ever sets `-debug=VALGRIND`, so the line never compiles.
  Stated in the page as an upstream bug candidate (a NOTE). `[source-verified]`
- **⚠ D-V3 — two Valgrind papers conflated (register R12).** The "PLDI 2007 (how
  to shadow every byte)" citation merges the PLDI 2007 framework/DBI paper with
  the VEE 2007 shadow-memory paper. The page's Sources names them as two distinct
  papers. `[literature]`
- **⚠ D-V4 — helgrind/DRD miss the short serialized race (register R22).** The
  naive expectation was that a data-race detector catches a two-thread
  `counter++`. Valgrind's serialization plus druntime's global thread-start/exit
  lock impose a real happens-before edge; both tools report **zero** (persists
  with `--default-suppressions=no`), while TSan catches the same program. A
  rendezvous makes both report it. Stated in the runner concern as a structural
  false-negative class. `[hw-verified: x86_64-linux]`
- **⚠ D-V5 — nixpkgs helgrind default suppressions over-blanket libc (register
  R23).** `helgrind-glibc2X-005` was assumed to target libpthread; since glibc
  2.34 merged libpthread into `libc.so.6` the generated pattern
  (`obj:*/lib*/libc.so.6`) now suppresses **any** race whose innermost frame is
  anywhere in libc — real `mem*`/`str*` races included. Upstream carries a 2009
  FIXME. Stated in the page as a WARNING. `[hw-verified: x86_64-linux]` `[source-verified]`

## Open / not-locally-groundable

- **◯ L25 — the <2 MB fiber-stack shadow-corruption hazard** is derived from the
  `m_stacks.c` stack-growth/switch logic but was not reproduced (every observed
  fiber switch had a >2 MB SP delta, so it took the "no mess with permissions"
  path). Source-verified, behavior-open; matches open question Q7-adjacent notes
  in the master register.

## Surprises (recorded, not discrepancies)

- The in-process parallel runner under the **default** scheduler is not merely
  slow but _pathologically variable_ — 12.5–180 s on a 4 ms suite (a ~40,000×
  worst case) — and `--fair-sched=yes` fully fixes the timing while doing nothing
  for the thread-tool noise. Both are in the page (the runner concern).
- GC noise is far smaller than feared: 6 errors on 278 tests at `-t 1`, and zero
  helgrind errors at `-t 1`. The "GC noise" story is really a "parallel-mode
  noise" story — the page states it that way.
- The GC use-after-free blind spot is closable with **no** druntime rebuild by
  compiling the shipped `gc.d` + `valgrind.d` into the app — a technique the page
  documents and druntime's own `test/valgrind` harness independently uses.

**Net:** 0 substantive discrepancies remaining. The five ⚠ items (D-V1..D-V5)
are brief-vs-source / naive-assumption corrections the page now states correctly,
and map to master-register rows R10, R11, R12, R22, R23. Every verbatim quote
(the V/A-bit model, the read-only aside, the 10-50× line, the origin-tracking
cost, the `etc.valgrind` module doc, the two `m_stacks.c` stack quotes, the
protocol-4 RUNNING-window grammar, the glibc FIXME, and the macOS `configure.ac`
hard-error) was re-checked against the pinned tree. All three probes and the
scratch experiments reproduced on both LDC 1.41 and DMD 2.112; the one open item
(L25) is a source-derived hazard flagged as such.

<!-- References -->

[locus]: ../concepts.md#instrumentation-locus
