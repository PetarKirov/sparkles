# Grounding ledger — `tsan.md`

Claim-by-claim verification of `docs/research/sanitizers/tsan.md` against the
pinned trees `llvm-project@73802c2e` (compiler-rt — the source of truth),
`go@0153438` (the `-race` seam), and `ldc@v1.41.0` (the driver predefine).
Hardware experiments recorded on **Linux 6.18.26** (NixOS 25.11), **AMD Ryzen 9
7940HX** (Zen 4, 16c/32t), **LDC 1.41.0** / **DMD 2.112.1** / **dub
1.42.0-beta.1**, against **GCC 15.2**'s `libtsan.so.2`. `$REPOS =
/home/petar/code/repos`. Experiment transcripts live in `…/scratchpad/w2/`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                                                                                                                                                                                   | Type         | Source (local + locator)                                                                            | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------- | ------ |
| L1  | v3 shadow cell is 32-bit (`RawShadow : u32`, `kShadowSize = 4`); four cells per 8-byte granule → shadow is **2×** app memory                                                                                                                                                                            | fact         | `tsan_defs.h:83-84`, `:77-87`                                                                       | ✓      |
| L2  | Cell layout `Parts{ u8 access_; Sid sid_; u16 epoch_:14; is_read_:1; is_atomic_:1 }`, `static_assert(sizeof==4)`; freed memory `kFreeAccess=0x81` → malloc UAF                                                                                                                                          | fact         | `tsan_shadow.h:148-179`, `:140-146`                                                                 | ✓      |
| L3  | Thread slots 8-bit (`Sid : u8`, `kFreeSid=255`), epochs 14-bit (`kEpochBits=14`) — the v3 economy that replaced v2's 8×64-bit cells                                                                                                                                                                     | fact         | `tsan_defs.h:57-66`                                                                                 | ✓      |
| L4  | The public `ThreadSanitizerAlgorithm` wiki still documents v2 (8×64-bit); v3-rewrite dated 2021                                                                                                                                                                                                         | exposition   | `google-sanitizers-wiki-threadsanitizeralgorithm.md` (saved, v2); dating                            | ⚠ / 🌐 |
| L5  | `history_size` defaults **0** at HEAD (v3 grows trace parts dynamically); v2 guidance (`history_size=7`) is stale                                                                                                                                                                                       | fact         | `tsan_flags.inc:61-64`                                                                              | ✓      |
| L6  | `report_atomic_races` defaults **true** ("Report races between atomic and plain memory accesses")                                                                                                                                                                                                       | fact         | `tsan_flags.inc:36-37`; runtime `Current Value: true` (`tsan-help-gcc15.txt`)                       | ✓ (hw) |
| L7  | LDC lowers `core.atomic` → LLVM atomics (`atomicrmw`/`load atomic`/`store atomic`/`cmpxchg`); the pass rewrites them to `__tsan_atomic32_*`, plain accesses to `__tsan_read4`/`__tsan_write4`, brackets functions with `__tsan_func_entry`/`_exit`                                                      | behavior     | Experiment E1 (`atomics.ll` / `atomics-tsan.ll`)                                                    | ✓ (hw) |
| L8  | Fiber API signatures (`__tsan_create/destroy/get_current/set_fiber_name/switch_to_fiber`); a switch is a HB edge (`Release` before / `Acquire` after, unless `NoSync`)                                                                                                                                  | fact         | `tsan_interface.h:153-169`; `tsan_rtl_thread.cpp:356-390`, `tsan_interface.cpp:59-84`               | ✓      |
| L9  | GCC 15.2 `libtsan.so.2` exports the full fiber API (`nm -D`: five `T __tsan_*fiber*`)                                                                                                                                                                                                                   | fact         | `nm -D libtsan.so.2` audit                                                                          | ✓ (hw) |
| L10 | `__tsan_switch_to_fiber` header contract quote: "should be called immediately before switch to fiber, such as call of `swapcontext`."                                                                                                                                                                   | quote        | `tsan_interface.h:158-159` (verbatim)                                                               | ✓      |
| L11 | No shipped druntime calls the fiber API — `grep -rn "__tsan"` = 0 over both druntime trees; LDC `SupportSanitizers` has no TSan entries                                                                                                                                                                 | fact         | Experiment E6; `ldc/sanitizers_optionally_linked.d`                                                 | ✓      |
| L12 | `detect_deadlocks` defaults true; the compiled detector is generation-**1**; DD2 exists but only Go sets `SANITIZER_DEADLOCK_DETECTOR_VERSION=2`, then Go disables DD entirely                                                                                                                          | fact         | `sanitizer_flags.inc:123`; `sanitizer_deadlock_detector_interface.h:18-19`; `tsan_flags.cpp:99-104` | ✓ (hw) |
| L13 | Deadlock-detector maturity quote: "FIXME: this is work in progress, nothing really works yet."                                                                                                                                                                                                          | quote        | `sanitizer_deadlock_detector.h:9-17` (verbatim `:17`)                                               | ✓      |
| L14 | `halt_on_error` defaults **false** ("Exit after first reported error."); report prints, execution continues, exit flips only at `Finalize` (`return failed ? exitcode : 0`)                                                                                                                             | quote        | `tsan_flags.inc:45`; `tsan_rtl.cpp:800-836`; `tsan_rtl_report.cpp:717-718`                          | ✓ (hw) |
| L15 | Exit code **66** is a TSan-specific override of the common default 1 (`cf.exitcode = 66;`); same block sets `TSAN_SYMBOLIZER_PATH`                                                                                                                                                                      | fact         | `tsan_flags.cpp:95-110`; 66 runtime-confirmed (E2)                                                  | ✓ (hw) |
| L16 | Env var is `GORACE` under `SANITIZER_GO`, else `TSAN_OPTIONS`                                                                                                                                                                                                                                           | fact         | `tsan_rtl.cpp:721`                                                                                  | ✓      |
| L17 | `__tsan_on_finalize` is `dlsym(RTLD_DEFAULT, …)`-resolved; its return decides the exit verdict; a D override returning 0 turned exit 66 → 0                                                                                                                                                             | behavior     | `tsan_platform_posix.cpp:76-80`, `tsan_rtl.cpp:69-77`; Experiment E8                                | ✓ (hw) |
| L18 | Exit-protocol contract quote: "Return `0` if TSan should exit as if no issues were detected. Return nonzero if TSan should exit as if issues were detected."                                                                                                                                            | quote        | `tsan_interface.h:174-178` (verbatim)                                                               | ✓      |
| L19 | `__tsan_on_report` is a weak per-report callback (invoked before the `halt_on_error` check); `W` in GCC `libtsan`; a D override gave exact per-window counts (racy 1 / clean 0)                                                                                                                         | behavior     | `tsan_rtl_report.cpp:48-50,715`; `nm`; Experiment E8b                                               | ✓ (hw) |
| L20 | `__tsan_default_options()` from D is consumed (`"atexit_sleep_ms=0"` → `Current Value: 0` vs 1000 plain); all three seams need `--export-dynamic`                                                                                                                                                       | behavior     | Experiment E8; `help=1` diff                                                                        | ✓ (hw) |
| L21 | `__tsan_report_count` is **not** exported by GCC `libtsan` — it is `SANITIZER_GO`-only; `__tsan_on_report` substitutes fully                                                                                                                                                                            | fact         | `nm -D` (absent); Experiment E8b                                                                    | ✓ (hw) |
| L22 | Suppression file named by `TSAN_OPTIONS=suppressions=`, parsed at init; also weak `__tsan_default_suppressions()` + hard-coded `std_suppressions`; types `race/race_top/mutex/thread/signal/called_from_lib/deadlock`; `signal:` covers errno-in-signal; matched per-frame against function/file/module | fact         | `tsan_suppressions.cpp:26-40,52-61`; `tsan_suppressions.h:20-27`; `IsSuppressed:96-123`             | ✓      |
| L23 | `TemplateMatch` pattern language: plain text = **substring**, `*` wildcard, `^` start, `$` end — **not** regex                                                                                                                                                                                          | fact         | `sanitizer_common.cpp:229-262`; glob runtime-verified (E4d)                                         | ✓ (hw) |
| L24 | GCC `libtsan` self-symbolizes via `libbacktrace` (no `llvm-symbolizer`) but does **not** demangle D → reports/suppressions target mangled text (`_D2rt8monitor…`)                                                                                                                                       | behavior     | runtime symbolization (E4)                                                                          | ✓ (hw) |
| L25 | GCC 15.2 `libtsan` `help=1` = 114 flags; all checked match compiler-rt defaults except the new `adaptive_delay*` family, which GCC lacks                                                                                                                                                                | fact         | `tsan-help-gcc15.txt`; `tsan_flags.inc:96-121`                                                      | ✓ (hw) |
| L26 | The `-b tsan` buildType propagates `-fsanitize=thread` to all five packages, applies `-unittest` only to the root test config, and keys the dub cache on the buildType name                                                                                                                             | behavior     | Experiment E4b (per-artifact `-of` audit; `build/{default,library}-tsan-<hash>/`)                   | ✓ (hw) |
| L27 | LDC predefines `version (LDC_ThreadSanitizer)` under `-fsanitize=thread`                                                                                                                                                                                                                                | fact         | `driver/main.cpp:1032`; `-v` predefs                                                                | ✓ (hw) |
| L28 | Go's `-race` runtime is a **prebuilt** TSan pinned to an exact LLVM commit, checked into the tree; README quote (verbatim)                                                                                                                                                                              | quote        | `go race/README:1-19` (`0153438`)                                                                   | ✓      |
| L29 | Go windowing chain: `race.Errors()`→`__tsan_report_count` (`race.go:48-52`); `resetRaces` before body (`testing.go:2185-2186`); `checkRaces` (`:1847-1885`)→`c.Errorf("race detected during execution of test")`; misattribution caveat (`:1944-1947`)                                                  | fact / quote | `go race.go`, `testing.go` (`0153438`)                                                              | ✓      |
| L30 | Go's `racefini()` runs only on otherwise-clean exit; a failed `go test` exits 1 via `os.Exit(1)` bypassing `__tsan_fini`; 66 is the backstop                                                                                                                                                            | fact         | `proc.go:330-348` (`0153438`)                                                                       | ✓      |
| L31 | Overhead ≈ **5×**: plain 8.8 ms parallel / 4.5 ms `-t 1`; TSan 46.9–49.1 ms parallel / 20.7 ms `-t 1` (`:versions`, 167 tests, tiny)                                                                                                                                                                    | figure       | Experiment E4d/E4e                                                                                  | ✓ (hw) |
| E1  | `core.atomic` IR lowering + TSan-pass rewrite (3× `__tsan_atomic32_fetch_add`, `__tsan_write4` on plain, `__tsan_func_entry/exit`)                                                                                                                                                                      | figure       | Experiment E1 (`atomics-tsan.ll`)                                                                   | ✓ (hw) |
| E2  | Default fatality: racy child prints final `counter = …` **and** exits 66; `halt_on_error=1` → line absent; `exitcode=0` → exit 0                                                                                                                                                                        | figure       | Experiment E2 (`race-default.out` / `race-halt.out`)                                                | ✓ (hw) |
| E3  | The probe: LDC-instrumented racy child exits 66 with `WARNING: … data race` + counter line; atomic child exits 0, exact 200 000; DMD SKIP                                                                                                                                                               | figure       | Experiment E3 ([`tsan-data-race.d`](../examples/tsan-data-race.d))                                  | ✓ (hw) |
| E4  | `dub test :versions -b tsan`: 167/167 pass; exactly **two** noise classes (31× `signal:thread_suspendHandler`, 1× `race:_D2rt8monitor*`); runner's own machinery = 0 reports                                                                                                                            | figure       | Experiment E4 (`dubtest-versions-tsan*.out`)                                                        | ✓ (hw) |
| E5  | GC-heavy (≥2 allocating threads + `GC.collect`) **deterministically livelocks** (3/3, `timeout 30`→124); strace: 509 898 `sched_yield` in 15 s; 1 worker completes (exit 66)                                                                                                                            | behavior     | Experiment E5 (`strace-gcheavy.log`, `gcheavy-hang-stacks.txt`)                                     | ✓ (hw) |
| E6  | `-t 1` → 0 warnings, exit 0, 20.7 ms vs 32 warnings / exit 66 / 46.9 ms; the 2-line suppression file → `Matched 32 suppressions`, exit 0                                                                                                                                                                | figure       | Experiment E4d (`versions-{t1,tN,supp}.out`, `druntime.supp`)                                       | ✓ (hw) |
| E7  | Fibers under TSan: ping-pong, cross-thread migration, mutex-handoff migration all exit 0 warning-free; a real fiber-vs-thread race caught (exit 66) with symbolized fiber frames                                                                                                                        | behavior     | Experiment E7 (`fibers.d`, `fiber_migrate.d`, `fiber_race.d`)                                       | ✓ (hw) |
| E8  | Go-pattern reproduced from D: `__tsan_on_finalize`→0 flips 66→0; `__tsan_on_report` per-window counts; `__tsan_default_options` consumed — all gated on `--export-dynamic`                                                                                                                              | behavior     | Experiment E8 (`hooks.d`, `onreport.d`)                                                             | ✓ (hw) |

## Discrepancies

Register cross-references are to the master register in
[`grounding/index.md`](./index.md) (`R4`–`R7`, `R26`).

- **⚠ D-TS1 — the public TSan wiki is v2; the runtime is v3 (L4).** The canonical
  `ThreadSanitizerAlgorithm` wiki page documents eight 64-bit shadow cells per
  granule; the source at `73802c2e` is v3 (four 32-bit cells, `Sid`+epoch,
  `history_size=0`). The page cites `tsan_shadow.h`/`tsan_defs.h`, carries a NOTE
  correcting the wiki, and flags the v2→v3 `history_size` guidance drift.
  `[source-verified]` (the 2021 rewrite dating is `[literature]`, hence 🌐 on L4).
- **⚠ D-TS2 (register R4) — `DFLAGS="-fsanitize=thread -allinst" dub test` is a
  silent false green.** `$DFLAGS` replaces the `unittest` buildType flags, drops
  `-unittest`/`-g`, compiles **zero** tests (the shim's `version (unittest):` hook
  never registers), druntime prints success, exit 0 — while `libtsan` is linked.
  Adding `-unittest` breaks `core-cli`'s library config. Fix stated in the page: the
  custom `buildType`. Whether dub semantics changed since 2026-07-10 or the recorded
  event-horizon recipe never ran as written is undecidable from this box (see
  index.md **Q1**). `[hw-verified: x86_64-linux]` (Experiment E4a).
- **⚠ D-TS3 (register R5) — "TSan drowns the runner" is refuted.** Only two druntime
  noise classes over 167 tests, silenced by a two-line file; the runner's own
  `TaskPool`/atomics/output reported zero. The observed classes
  (`signal:thread_suspendHandler`, `race:_D2rt8monitor*`) are also **disjoint** from
  the event-horizon suppression list (whose `race:` globs cover GC-alloc/thread/array
  races) — a shipped file needs the union and the `signal:` type they lack. Stated in
  the page's noise-class subsection. `[hw-verified: x86_64-linux]` (Experiment E4).
- **⚠ D-TS4 (register R6) — GC-heavy multithreaded D deterministically LIVELOCKS.**
  Not "noise" but a hang with zero output — the worst CI outcome (nastier than the
  hypothesized "drown in reports"). Druntime's signal-based stop-the-world is
  incompatible with TSan's async-signal deferral once ≥2 mutators are suspended
  mid-runtime. The page carries this as a `> [!WARNING]` with the strace excerpt and
  a watchdog recommendation. `[hw-verified: x86_64-linux]` (Experiment E5).
- **⚠ D-TS5 (register R7) — fibers under TSan do not crash or throw false races.**
  Three shapes clean; a real fiber-vs-thread race caught with correctly-symbolized
  fiber frames. No druntime fiber-API annotations needed for soundness; the API's
  value is fiber identity + runtime-internal-handoff correctness. Stated in the page's
  fibers subsection. `[hw-verified: x86_64-linux]` (Experiment E7).
- **⚠ D-TS6 (register R26) — dub launders the TSan exit code.** A test binary exiting
  66 makes dub print "Program exited with code 66" and itself exit **2** — "tests
  failed" and "TSan reported" are indistinguishable through `dub test`'s exit code
  unless the runner parses output or runs the binary directly. Stated in
  Test-runner integration. `[hw-verified: x86_64-linux]`.
- **Note — GCC-vs-compiler-rt flag drift (L25).** GCC 15.2 `libtsan` lacks the new
  `adaptive_delay*` injection family present at compiler-rt HEAD — expected for a
  periodic merge, useless locally today; disclosed in the page's version-skew WARNING
  and the Symbolization section. `[hw-verified: x86_64-linux]` `[source-verified]`.
- **Note — `__tsan_report_count` is Go-build-only (L21).** The Go `race.Errors()`
  counter symbol is `SANITIZER_GO`-only and absent from GCC `libtsan`; the weak
  `__tsan_on_report` callback substitutes fully, so the Go windowing pattern still
  reproduces from D. `[hw-verified: x86_64-linux]`.

**Net:** 0 substantive discrepancies remaining. Every source locator is at
`llvm-project@73802c2e` / `go@0153438` / `ldc@v1.41.0`; the four verbatim quotes
(`halt_on_error`, the deadlock-detector FIXME, the `__tsan_switch_to_fiber` /
`__tsan_on_finalize` header contracts, and Go's README) are quoted exactly. The six
`⚠` items are the brief-hypothesis corrections and headline surprises the page now
states correctly; they populate register rows `R4`–`R7` and `R26`. The lone hard
ceiling (E5 livelock) and the load-bearing coincidence (`--export-dynamic` already
set) are both reproduced on hardware.
