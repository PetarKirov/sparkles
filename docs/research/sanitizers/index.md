# Sanitizers for the D test runner

Whether — and how — [`sparkles:test-runner`][design-doc] can drive a memory or
threading sanitizer over a D `unittest` suite and surface each finding against
the test that produced it. The survey grounds the LLVM `compiler-rt` stack
(`asan`/`lsan`/`tsan`/`msan`/`ubsan`/`hwasan`/`gwp_asan`) and the Valgrind family
on the **D toolchain** (LDC/GDC/DMD, druntime, `dub`), surveys how the field's
runners attribute a finding **per test**, maps the story onto **macOS/Windows**
and the **hardware-assisted** frontier, audits today's runner, and lands in a
capability matrix and a milestoned `--sanitize`/`--valgrind`/`--isolate`
proposal. Every page is grounded twice over: claims carry pinned
`repo@commit path:line` locators or recorded experiments, and locally-demonstrable
behavior is backed by [runnable probes](#the-runnable-probes) CI compiles and runs.

**Last reviewed:** July 11, 2026

This survey answers thirteen questions:

1. Can LDC actually sanitize D — which `-fsanitize=` kinds, and which runtime
   really links? → [d-toolchain][d-toolchain]
2. Which of the three D compilers reaches which tool? → [d-toolchain][d-toolchain]
3. What does D's garbage collector hide from every memory tool? → the
   [GC blind spot][c-gc] · [asan][asan] · [d-toolchain][d-toolchain]
4. Is UndefinedBehaviorSanitizer reachable from D at all? → [ubsan][ubsan]
5. What does AddressSanitizer catch, and what are its D-specific blind spots? →
   [asan][asan]
6. Can a test runner attribute a race/leak/fault to the test that caused it? →
   [runner-integrations][runner-integrations] + [tsan][tsan]
7. What deterministically **livelocks** under a sanitizer, and why? → [tsan][tsan]
8. Is MemorySanitizer usable for D? → [d-toolchain § MSan][d-toolchain-msan]
9. What is the **no-recompile** path a DMD-built binary can use? → [valgrind][valgrind]
10. How does the field's tooling surface a sanitizer finding per test? →
    [runner-integrations][runner-integrations]
11. What happens **today** when a sparkles test crashes mid-run? → [baseline][baseline]
12. What changes when the runner leaves Linux for macOS or Windows? →
    [macos-windows][macos-windows]
13. What is the hardware-assisted / post-ASan story for D (HWASan, MTE, GWP-ASan,
    RTSan, TySan)? → [hardware-assisted][hardware-assisted]

Where does sparkles stand against all of it, and what should it build? →
[baseline][baseline] + the [delta table][comparison-delta] → [proposal][proposal].

---

## The seven concerns

Every tool in the tree is analyzed against the same seven-concern spine, in fixed
order — and where a concern does not apply (UBSan has no instrumentation to
control; MTE has no runner-facing option surface), the page says so, because the
_absence_ of a capability is itself a finding:

1. **Defect classes and blind spots** — what it catches, and what it structurally
   cannot (the [GC memory blind spot][c-gc], [redzone][c-redzone] limits,
   [definedness vs addressability][c-def]).
2. **Instrumentation model and recompile scope** — the
   [instrumentation locus][c-locus] and whether user code, the whole
   [instrumented world][c-iworld], or nothing must be rebuilt.
3. **D and druntime interaction** — the GC, fibers, and the signal-based
   [stop-the-world scan][c-stw] against a tool built for `malloc`/`free` C.
4. **Runtime control and report capture** — [halt vs recover][c-halt], the
   [weak-hook surface][c-weak], and Valgrind's [client requests][c-creq].
5. **Symbolization and suppressions** — who demangles D (almost nobody), and the
   two [suppression][c-supp] formats.
6. **Test-runner integration semantics** — the three attribution designs
   ([windowing][c-window] / [process-per-test][c-ppt] / [wrapper-and-parse][c-wrap]).
7. **Platform, toolchain, and overhead** — LDC/GDC/DMD reach, off-Linux columns,
   and the measured cost.

## Master catalog

| Subject                 | What it is                                             | Concern focus | Verification bed                           | Link                                          |
| ----------------------- | ------------------------------------------------------ | ------------- | ------------------------------------------ | --------------------------------------------- |
| Concepts                | the tree's shared vocabulary                           | all           | tool sources                               | [concepts.md][concepts]                       |
| AddressSanitizer + LSan | the memory-error workhorse (shadow + redzones)         | 1, 3, 4       | `x86_64-linux` hw                          | [asan.md][asan]                               |
| UBSan                   | a documented **absence** — unreachable from D          | 2             | source + one GDC hw datum                  | [ubsan.md][ubsan]                             |
| ThreadSanitizer         | the happens-before data-race detector                  | 3, 6          | `x86_64-linux` hw                          | [tsan.md][tsan]                               |
| The D toolchain         | LDC/GDC/DMD × druntime × `dub`; owns the MSan story    | 2, 3, 7       | `x86_64-linux` hw                          | [d-toolchain.md][d-toolchain]                 |
| Valgrind                | `memcheck`/`helgrind`/`DRD` — no recompile, DMD's path | 1, 2, 6       | `x86_64-linux` hw (LDC + DMD)              | [valgrind.md][valgrind]                       |
| Runner integrations     | how Go/Rust/Swift/Zig/CTest/Bazel/pytest attribute     | 6             | source; one Go hw battery                  | [runner-integrations.md][runner-integrations] |
| macOS & Windows         | the two off-Linux columns                              | 7             | source/lit; one `aarch64-darwin` datum     | [macos-windows.md][macos-windows]             |
| Hardware-assisted       | HWASan · MTE · GWP-ASan · RTSan · TySan                | 1, 2, 7       | `x86_64-linux` hw (3 of 5); MTE source/lit | [hardware-assisted.md][hardware-assisted]     |
| sparkles baseline       | today's runner, as observed under audit                | audit target  | in-repo (private clone)                    | [sparkles-baseline.md][baseline]              |
| Integration proposal    | milestoned `--sanitize`/`--valgrind`/`--isolate`       | design        | —                                          | [integration-proposal.md][proposal]           |
| Comparison              | capability matrix · trade-offs · delta table           | synthesis     | —                                          | [comparison.md][comparison]                   |

## Taxonomies

### By instrumentation locus

The axis that decides which D compiler can reach a tool at all
([concepts § instrumentation locus][c-locus]).

| Locus                      | Tools                                            | D-reachability                                        | Pages                                                                                          |
| -------------------------- | ------------------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| LLVM IR pass               | ASan, LSan, TSan, MSan, HWASan, RTSan            | inherited by LDC once the flag is plumbed             | [asan][asan], [tsan][tsan], [d-toolchain][d-toolchain], [hardware-assisted][hardware-assisted] |
| clang CodeGen only         | UBSan, TySan                                     | **unreachable** — no IR pass for a non-clang frontend | [ubsan][ubsan], [hardware-assisted][hardware-assisted]                                         |
| Dynamic binary translation | Valgrind `memcheck`/`helgrind`/`DRD`, Dr. Memory | every compiler incl. **DMD**, no recompile            | [valgrind][valgrind], [macos-windows][macos-windows]                                           |
| Hardware tag check         | Arm MTE                                          | a _deployment_, needs MTE silicon                     | [hardware-assisted][hardware-assisted]                                                         |
| Sampling allocator         | GWP-ASan                                         | C-heap only; a production, not test, tool             | [hardware-assisted][hardware-assisted]                                                         |

### By defect class

Which tool catches what — and the D caveat on each.

| Defect class                               | Caught by                                    | Not caught by / D caveat                                                           |
| ------------------------------------------ | -------------------------------------------- | ---------------------------------------------------------------------------------- |
| Heap/stack/global overflow, use-after-free | ASan, HWASan, `memcheck`, GWP-ASan (sampled) | all blind to **GC-pool** memory; `memcheck` has no redzones                        |
| Stack-use-after-return                     | ASan (fake stack) — the flagship fiber catch | runtime-gated by `detect_stack_use_after_return`                                   |
| Uninitialized-value read (definedness)     | `memcheck`, MSan                             | ASan structurally cannot; MSan needs an [instrumented world][c-iworld]             |
| Data race                                  | TSan, `helgrind`/`DRD`                       | `helgrind`/`DRD` blind to `core.atomic`/`SpinLock`; a serialized schedule hides it |
| Memory leak                                | LSan, `memcheck`                             | GC-referenced `malloc` = LSan false positive; a dropped GC block is invisible      |
| Undefined behaviour (shifts, `int.min/-1`) | UBSan (C/C++ only)                           | unreachable from every D compiler                                                  |
| Real-time-safety violation                 | RTSan                                        | LDC blocked on an LLVM ≥ 20 bump                                                   |
| Strict-aliasing (TBAA)                     | TySan                                        | **never** for D — no `!tbaa`, no aliasing rules                                    |

### By toolchain

| Compiler     | Reaches                                                                  | Via                                                                       |
| ------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| **LDC**      | ASan, LSan, TSan, MSan (`-conf=`/tarball), Valgrind                      | `-fsanitize=` IR passes + the gcc-runtime fallback; Valgrind no-recompile |
| **GDC 11.5** | ASan (`--param asan-globals=0`), LSan, TSan, Valgrind; UBSan check-empty | GCC `libsanitizer` + a `-B`/`-L` workaround                               |
| **DMD**      | **Valgrind only**                                                        | no `-fsanitize` at all — DBI is its sole path                             |

### By verification level

| Level                           | What carries it                                                                                                                                                |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `[hw-verified: x86_64-linux]`   | ASan/LSan/TSan/MSan(`-conf=`)/HWASan(aliasing)/GWP-ASan/RTSan/TySan catches, the `dub`-channel + druntime experiments, and the eleven probes — the primary bed |
| `[hw-verified: aarch64-darwin]` | **one** datum: the recon Apple-clang ASan smoke test; the D-on-darwin runs were blocked (rerun kit staged)                                                     |
| `[source-verified]`             | LDC/GDC/DMD flag sets, `compiler-rt`/Valgrind/`dub` source, the Windows link branches, the MTE kernel ABI                                                      |
| `[literature]`                  | vendor docs (MS Learn, Apple MIE, Android), the overhead headline figures, the saved papers                                                                    |

> [!IMPORTANT]
> The honest boundary: the `x86_64-linux` box is the only full bed. **macOS is
> mechanism-verified, not run-verified** — the `mac-bsn` transcripts were blocked
> and one Apple-clang C datum stands in; **Windows has no hardware at all**; and
> **no MTE silicon is in reach** (the project's only aarch64 box, an Apple M4, has
> no MTE). Every such gap is tagged in place and carried into
> [comparison § open questions][comparison-open].

## Milestones

When the field's tools landed. Coarse dates are `[literature]`; the Valgrind
design papers are `[source-verified]` (archived locally).

| When      | What                                                                                                                                |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| 2002      | Valgrind's first public release (DBI memory checking) `[literature]`                                                                |
| 2007      | Valgrind's design papers — the framework at **PLDI 2007**, "How to Shadow Every Byte of Memory" at **VEE 2007** `[source-verified]` |
| 2011      | **AddressSanitizer** lands in LLVM (paper USENIX ATC 2012) `[literature]`                                                           |
| 2011–2012 | **ThreadSanitizer v2** (the v3 shadow rewrite follows in 2021) `[literature]`                                                       |
| ~2013     | **LeakSanitizer** ships alongside ASan `[literature]`                                                                               |
| 2015      | **MemorySanitizer** paper at CGO 2015 `[literature]`                                                                                |
| 2018      | **Arm MTE** announced (arXiv 1802.09517) `[literature]`                                                                             |
| 2019      | **HWASan** becomes Android 10's production memory-safety tool; **GWP-ASan** enters production fleets `[literature]`                 |
| 2021      | **MSVC `/fsanitize=address`** reaches GA in Visual Studio 16.9 `[literature]`                                                       |
| 2023-11   | first **MTE** handset: Google Pixel 8 / Tensor G3; the GWP-ASan paper (arXiv 2311.09394) `[literature]`                             |
| 2024      | first **MTE** datacenter CPU: AmpereOne `[literature]`                                                                              |
| 2025-03   | **RTSan** and experimental **TySan** ship in LLVM/Clang 20 `[literature]`                                                           |
| 2025-09   | Apple **Memory Integrity Enforcement** (EMTE) debuts on the A19 / iPhone 17 — no M-series `[literature]`                            |

## The runnable probes

Standalone `dub` single-file programs under [`examples/`](#quick-navigation); CI
compiles and runs each, and every one `SKIP:`s cleanly on a host or toolchain
that lacks the capability (an uninstrumented or DMD build). Environment: Linux
6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.0, against GCC 15.2's `libasan`/`libtsan`
via LDC's gcc link fallback.

| Probe                                     | Demonstrates                                                         | Backs                                            |
| ----------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------ |
| [asan-heap-uaf.d][ex-uaf]                 | heap use-after-free caught, self-symbolized, exit 1                  | [asan][asan] concern 1                           |
| [asan-stack-uar.d][ex-uar]                | stack-use-after-return + the `detect_stack_use_after_return` gate    | [asan][asan] concern 1                           |
| [asan-global-overflow.d][ex-global]       | global-buffer-overflow via `.ptr` past a `__gshared` array           | [asan][asan] concern 1                           |
| [asan-report-capture.d][ex-capture]       | `log_path` routing + report callback (the attribution material)      | [asan][asan] concern 4                           |
| [lsan-gc-interplay.d][ex-lsan]            | LSan × GC four quadrants; `detect_leaks` gates the manual check      | [asan § LSan][asan-lsan]                         |
| [tsan-data-race.d][ex-tsan]               | race caught, `core.atomic` silent; `halt_on_error=false`, exit 66    | [tsan][tsan] concerns 3/4                        |
| [gc-uaf-blindspot.d][ex-gcuaf]            | GC-pool UAF invisible while the `malloc` twin is caught              | [d-toolchain § GC blind spot][d-toolchain-gc]    |
| [fiber-asan.d][ex-fiber]                  | fiber stack-use-after-return (the event-horizon bug), stock druntime | [d-toolchain § fibers][d-toolchain-fiber]        |
| [valgrind-memcheck-catch.d][ex-vgcatch]   | no-recompile XML + exit-code pipeline (DMD too)                      | [valgrind][valgrind] concern 4                   |
| [valgrind-client-requests.d][ex-vgclient] | `etc.valgrind` driving `memcheck`'s A/V bits from D                  | [valgrind][valgrind] concern 3                   |
| [valgrind-attribution.d][ex-vgattr]       | `VALGRIND_PRINTF` marker-window per-test attribution                 | [valgrind § runner integration][valgrind-runner] |

All eleven are `platforms "linux"` by design ([macos-windows][macos-windows]
explains why a darwin port is a new file, not a `platforms` toggle); the `ci`
helper `⊘`-skips them on the macOS CI row. Run them with:

```bash
dub run :ci -- -x --files 'docs/research/sanitizers/examples/*.d'
```

## Quick navigation

- **"I'm designing the sparkles `--sanitize` mode"** — [concepts][concepts] →
  [d-toolchain][d-toolchain] → [tsan][tsan]/[asan][asan] →
  [runner-integrations][runner-integrations] → [baseline][baseline] →
  [proposal][proposal]; the [comparison matrix + delta][comparison] ties it
  together, and [valgrind][valgrind] before the `--valgrind` mode.
- **"Which tool catches what?"** — [comparison § matrix][comparison] →
  [asan][asan] / [tsan][tsan] / [valgrind][valgrind] → vocabulary in
  [concepts][concepts].
- **"What breaks off Linux?"** — [macos-windows][macos-windows] →
  [d-toolchain][d-toolchain] (the link branches) → [valgrind][valgrind] (dead on
  macOS) → [comparison § open questions][comparison-open].
- **"The hardware-assisted future"** — [hardware-assisted][hardware-assisted] →
  [concepts § memory tagging][c-tag] → [proposal § M7][proposal-m7].
- **Vocabulary lookup** — [concepts.md][concepts].

## Sources

Per-page Sources sections carry the primary references; repos are pinned by SHA
there. The reads behind the survey are LLVM `compiler-rt`/clang/llvm at
`73802c2e`, Valgrind at `218cee2f` (tag `VALGRIND_3_26_0`), LDC `v1.41.0`, DMD
`e6baf474`, `dub` `5efed360`, and the Linux kernel at `e43ffb69` (v7.1-rc6) for
the MTE ABI; the runner-integration survey adds Go, Rust/cargo-nextest, SwiftPM,
Zig, googletest, CMake, and pytest-valgrind at their pinned SHAs. The sanitizer
papers (ASan, TSan, MSan, the two Valgrind papers, GWP-ASan, and the MTE
whitepaper) are archived locally under `papers/sanitizers/`. The survey's own
experimental evidence is the eleven [runnable probes](#the-runnable-probes) plus
the recon `mac-bsn` Apple-clang smoke test, with every experiment's environment
recorded alongside its output.

<!-- References -->

[concepts]: ./concepts.md
[asan]: ./asan.md
[asan-lsan]: ./asan.md#leaksanitizer-and-the-d-gc
[ubsan]: ./ubsan.md
[tsan]: ./tsan.md
[d-toolchain]: ./d-toolchain.md
[d-toolchain-msan]: ./d-toolchain.md#msan-the-instrumented-world-requirement
[d-toolchain-gc]: ./d-toolchain.md#the-gc-blind-spot-asan-cannot-see-gc-pools
[d-toolchain-fiber]: ./d-toolchain.md#fibers-under-asan-fake-stacks-and-stack-use-after-return
[valgrind]: ./valgrind.md
[valgrind-runner]: ./valgrind.md#runner-integration-semantics
[runner-integrations]: ./runner-integrations.md
[macos-windows]: ./macos-windows.md
[hardware-assisted]: ./hardware-assisted.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./integration-proposal.md
[proposal-m7]: ./integration-proposal.md#_9-m7-later-tier-the-hardware-and-realtime-frontier
[comparison]: ./comparison.md
[comparison-delta]: ./comparison.md#the-delta-table-the-survey-vs-the-sparkles-baseline
[comparison-open]: ./comparison.md#open-questions-gaps
[design-doc]: ../../libs/test-runner/explanation/design.md
[ex-uaf]: ./examples/asan-heap-uaf.d
[ex-uar]: ./examples/asan-stack-uar.d
[ex-global]: ./examples/asan-global-overflow.d
[ex-capture]: ./examples/asan-report-capture.d
[ex-lsan]: ./examples/lsan-gc-interplay.d
[ex-tsan]: ./examples/tsan-data-race.d
[ex-gcuaf]: ./examples/gc-uaf-blindspot.d
[ex-fiber]: ./examples/fiber-asan.d
[ex-vgcatch]: ./examples/valgrind-memcheck-catch.d
[ex-vgclient]: ./examples/valgrind-client-requests.d
[ex-vgattr]: ./examples/valgrind-attribution.d
[c-locus]: ./concepts.md#instrumentation-locus
[c-iworld]: ./concepts.md#instrumented-world-requirement
[c-gc]: ./concepts.md#the-gc-memory-blind-spot
[c-def]: ./concepts.md#definedness-vs-addressability
[c-redzone]: ./concepts.md#redzone
[c-tag]: ./concepts.md#memory-tagging
[c-stw]: ./concepts.md#stop-the-world-root-scanning
[c-halt]: ./concepts.md#halt-vs-recover
[c-weak]: ./concepts.md#weak-hook-control-surface
[c-creq]: ./concepts.md#client-request
[c-supp]: ./concepts.md#suppression
[c-window]: ./concepts.md#report-windowing
[c-ppt]: ./concepts.md#process-per-test-isolation
[c-wrap]: ./concepts.md#wrapper-and-parse
