# Native CPU-PMU Integration

How to build a native CPU-performance-monitoring data layer for the sparkles
benchmarking harness — [`sparkles:test-runner --bench`][bench-docs] and the
[`wired` runtime bench][wired-bench]. The survey grounds the Linux stack
(`perf_event_open` and its decoder libraries — elfutils, libtraceevent,
libnuma), maps it onto **ARMv8+** and **RISC-V**, surveys the alternative
acquisition APIs on **Windows** and **macOS**, and lands in a capability
matrix, an audit baseline, and a milestoned backend proposal. Every page is
grounded twice over: claims carry pinned `repo@commit path:line` locators or
recorded experiments, and locally-demonstrable behavior is backed by
[runnable probes](#the-runnable-probes) CI compiles and runs.

**Last reviewed:** July 11, 2026

This survey answers ten questions:

1. What does `perf_event_open` actually provide — counting, sampling, and the
   contracts underneath (groups, multiplexing, the ring buffer, rdpmc)? →
   [linux-perf-events][linux]
2. How do the four Linux decoder libraries divide the work, and where do they
   stop? → [elfutils][elfutils], [libtraceevent][libtraceevent],
   [libnuma][libnuma]
3. How does precise memory sampling work on each vendor engine (IBS, PEBS,
   SPE), and how does a sampled data address become a NUMA node? →
   [precise-sampling][precise]
4. How does the model map onto ARMv8+/ARMv9 — PMUv3's event space, SPE, BRBE,
   big.LITTLE, uncore — and what is Apple Silicon really? → [arm][arm]
5. How does it map onto RISC-V, and which capabilities simply do not exist
   there yet? → [riscv][riscv]
6. What can a Windows profiler use without a kernel driver, and what only
   with one? → [windows][windows]
7. What can a macOS process measure at each privilege level, and what is
   fenced behind root, entitlements, and the event allowlist? →
   [macos][macos]
8. How do human event names become hardware encodings, and which naming layer
   covers which ISA and OS? → [event-naming][naming]
9. Where does the sparkles harness stand today against all of the above? →
   [sparkles-baseline][baseline] + the [delta table][comparison-delta]
10. What should sparkles build? → [backend-proposal][proposal]

---

## The seven concerns

Every subject in the tree is analyzed against the same seven-concern spine —
where a concern does not apply, the page says so, because the _absence_ of a
capability is itself a finding:

1. **Scalar [counting][c-counting]** — groups, exactness, multiplexing.
2. **[Overflow/IP sampling][c-sampling]** — periods, PMIs, ring buffers.
3. **[Precise data-source/address sampling][c-datasrc]** — skidless engines,
   latency, data addresses.
4. **[Code-space decode & symbolization][c-symbolization]** — address-space
   models, debug info, unwinding.
5. **[Event-space & tracing][c-eventspace]** — tracepoints/ETW/kdebug, branch
   records.
6. **[NUMA & topology][c-numa]** — nodes, uncore scoping, page→node oracles.
7. **[Event naming & encoding][c-naming]** — name→selector tables and their
   coverage boundaries.

## Master catalog

| Subject             | What it is                                      | Concern focus          | Verification bed                  | Link                              |
| ------------------- | ----------------------------------------------- | ---------------------- | --------------------------------- | --------------------------------- |
| Concepts            | the tree's shared vocabulary                    | all                    | —                                 | [concepts.md][concepts]           |
| Linux `perf_events` | the acquisition hub (reference model)           | 1, 2                   | `x86_64-linux` hw                 | [linux-perf-events.md][linux]     |
| elfutils            | code-space decoder (`libelf`/`libdw`/`libdwfl`) | 4                      | `x86_64-linux` hw                 | [elfutils.md][elfutils]           |
| libtraceevent       | event-space decoder (tracefs `format`)          | 5                      | source                            | [libtraceevent.md][libtraceevent] |
| libnuma             | topology/placement decoder                      | 6                      | `x86_64-linux` hw (single-node)   | [libnuma.md][libnuma]             |
| Precise sampling    | IBS · PEBS · SPE → one ABI; address→node        | 3, 6                   | IBS hw; PEBS/SPE source           | [precise-sampling.md][precise]    |
| ARMv8+              | PMUv3, SPE, BRBE, big.LITTLE, uncore, Apple     | 1–7 mapping            | source; Apple `aarch64-darwin` hw | [arm.md][arm]                     |
| RISC-V              | SBI indirection, Sscofpmf, CTR                  | 1–7 mapping (absences) | source + spec                     | [riscv.md][riscv]                 |
| Windows             | HCP, ETW, ring-0 drivers, PDB, Win32 NUMA       | 1–7 mapping            | docs + open consumers             | [windows.md][windows]             |
| macOS               | kpc/kperf, rusage, Instruments, dyld/dSYM       | 1–7 mapping            | `aarch64-darwin` hw               | [macos.md][macos]                 |
| Event naming        | libpfm4, PAPI, LIKWID, vendor tables            | 7                      | `x86_64-linux` hw                 | [event-naming.md][naming]         |
| Comparison          | capability matrix · trade-offs · delta table    | synthesis              | —                                 | [comparison.md][comparison]       |
| sparkles baseline   | today's counter layer, as observed              | audit target           | in-repo                           | [sparkles-baseline.md][baseline]  |
| Backend proposal    | milestoned per-OS acquisition core, in D        | design                 | —                                 | [backend-proposal.md][proposal]   |

## Taxonomies

### By ISA

| ISA            | Counting model                          | Precise engine          | Branch records              | Pages                                |
| -------------- | --------------------------------------- | ----------------------- | --------------------------- | ------------------------------------ |
| x86_64 (AMD)   | `perf_event_open`, 6 PMCs               | IBS (skid 0)            | LBR                         | [linux][linux], [precise][precise]   |
| x86_64 (Intel) | `perf_event_open`, fixed+GP             | PEBS (`precise_ip` 1–3) | LBR                         | [precise][precise], [naming][naming] |
| ARMv8+/v9      | PMUv3 (PMCEID-probed), per-cluster PMUs | SPE (AUX)               | BRBE                        | [arm][arm]                           |
| RISC-V         | SBI-mediated `mhpmcounter`              | **none**                | CTR (ratified, no consumer) | [riscv][riscv]                       |
| Apple Silicon  | proprietary CPMU, 2 fixed + 8           | **none exposed**        | none exposed                | [arm][arm] §Apple, [macos][macos]    |

### By OS

| OS      | Acquisition surface                              | Event policy                     | Decode stack                        | Page               |
| ------- | ------------------------------------------------ | -------------------------------- | ----------------------------------- | ------------------ |
| Linux   | one syscall, all modes                           | open selectors, `paranoid`-gated | MMAP2 + DWARF (elfutils)            | [linux][linux]     |
| Windows | HCP + ETW + closed ring-0 drivers                | curated + global registration    | image-load events + PDB (DbgHelp)   | [windows][windows] |
| macOS   | kpc/kperf (root) · rusage (unpriv) · Instruments | kernel allowlist, even for root  | dyld map + dSYM (CoreSymbolication) | [macos][macos]     |

### By verification level

| Level                           | What carries it                                                                                                         |
| ------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `[hw-verified: x86_64-linux]`   | Linux counting/sampling/unwinding, IBS, libpfm4 round trip, NUMA round trip — the five probes below                     |
| `[hw-verified: aarch64-darwin]` | kpep catalogs, kpc EPERM matrix, rusage counting, xctrace, dyld/atos — mac-bsn transcripts in [macos][macos]/[arm][arm] |
| `[source-verified]`             | ARM-Linux drivers, RISC-V kernel/SBI/firmware, PEBS, xnu/dtrace, krabsetw, all pinned repos                             |
| `[literature]`                  | vendor docs (saved), gated specs cited by section                                                                       |

## Milestones

When the key capabilities landed. Coarse dates are `[literature]`; entries
verified in this survey's sources are tagged.

| When       | What                                                                                                                                                                            |
| ---------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ~2000      | Intel **PEBS** ships with NetBurst (Pentium 4) `[literature]`                                                                                                                   |
| 2007       | AMD **IBS** ships with Family 10h (Barcelona) `[literature]`                                                                                                                    |
| 2009       | Linux 2.6.31 merges **`perf_event_open`** `[literature]`; Windows 7 ships **HCP** thread profiling (min-version per the API docs) `[source-verified]`                           |
| 2016       | Armv8.2 defines **SPE** `[literature]`                                                                                                                                          |
| 2019       | Win10 1903 allows **raw ProfileSource registration**; 19H1 makes **ETW LBR** public `[source-verified]` (docs); Armv8.5/PMUv3p5 makes event counters 64-bit `[source-verified]` |
| 2021       | RISC-V **Sscofpmf** ratified; SBI 0.3 adds the **PMU extension** `[literature]`; Armv9.2 defines **BRBE** `[source-verified]`                                                   |
| 2024-11-22 | RISC-V **CTR** (Smctr/Ssctr) v1.0 **ratified** `[source-verified]` — still no Linux consumer at v7.1-rc6                                                                        |
| 2024       | Apple **M4** remaps its common PMU events onto PMUv3 architected numbers `[hw-verified: aarch64-darwin]`                                                                        |

## The runnable probes

Standalone `dub` single-file programs under [`examples/`](#quick-navigation);
CI compiles and runs each (they `SKIP` cleanly on hosts lacking a capability).
Environment: Linux 6.18.26, AMD Ryzen 9 7940HX, LDC 1.41.

| Probe                               | Demonstrates                                         | Backs                               |
| ----------------------------------- | ---------------------------------------------------- | ----------------------------------- |
| [counting-group.d][ex-counting]     | grouped IPC (exact) + forced multiplex scaling       | [linux][linux] concern 1            |
| [sampling-symbolize.d][ex-sampling] | ring-buffer IP sampling → libdwfl symbolization      | [linux][linux] concern 2/4          |
| [unwind-stack-user.d][ex-unwind]    | DWARF-CFI unwind of a frame-pointer-less build       | [linux][linux]/[elfutils][elfutils] |
| [mem-latency-numa.d][ex-mem]        | IBS data-source/latency sampling + page→node oracles | [precise][precise]                  |
| [pfm4-name-roundtrip.d][ex-pfm4]    | libpfm4 name→`perf_event_attr`→open→count            | [naming][naming]                    |

## Quick navigation

- **"I'm designing the sparkles backend"** — [concepts][concepts] →
  [sparkles-baseline][baseline] → [linux-perf-events][linux] →
  [event-naming][naming] → [comparison][comparison] (matrix + delta) →
  [backend-proposal][proposal]; add [precise-sampling][precise] before
  milestone 5 and [macos][macos]/[windows][windows] before 3/4.
- **"Why is my profile lying to me?"** — [concepts § skid][c-skid] →
  [precise-sampling][precise] → [linux § build-id hazard][linux].
- **"What breaks off x86-Linux?"** — [arm][arm] → [riscv][riscv] →
  [windows][windows] → [macos][macos] → [comparison § open questions][comparison-open].
- **Vocabulary lookup** — [concepts.md][concepts].

## Sources

Per-page Sources sections carry the primary references; repos are pinned by
SHA and papers archived locally (see each deep-dive). The five probes and the
mac-bsn transcripts are the survey's own experimental evidence; experiment
environments are recorded alongside every quoted output.

<!-- References -->

[concepts]: ./concepts.md
[linux]: ./linux-perf-events.md
[elfutils]: ./elfutils.md
[libtraceevent]: ./libtraceevent.md
[libnuma]: ./libnuma.md
[precise]: ./precise-sampling.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[windows]: ./windows.md
[macos]: ./macos.md
[naming]: ./event-naming.md
[comparison]: ./comparison.md
[comparison-delta]: ./comparison.md#the-delta-table-the-survey-vs-the-sparkles-baseline
[comparison-open]: ./comparison.md#open-questions-gaps
[baseline]: ./sparkles-baseline.md
[proposal]: ./backend-proposal.md
[bench-docs]: ../../libs/test-runner/how-to/benchmark.md
[wired-bench]: ../../../libs/wired/bench/runtime/
[ex-counting]: ./examples/counting-group.d
[ex-sampling]: ./examples/sampling-symbolize.d
[ex-unwind]: ./examples/unwind-stack-user.d
[ex-mem]: ./examples/mem-latency-numa.d
[ex-pfm4]: ./examples/pfm4-name-roundtrip.d
[c-counting]: ./concepts.md#counting
[c-sampling]: ./concepts.md#overflow-sampling
[c-datasrc]: ./concepts.md#data-source-attribution
[c-symbolization]: ./concepts.md#symbolization
[c-eventspace]: ./concepts.md#event-space-and-tracepoints
[c-numa]: ./concepts.md#numa-topology-and-page-node-oracles
[c-naming]: ./concepts.md#event-naming-and-encoding
[c-skid]: ./concepts.md#precise-sampling-and-skid
