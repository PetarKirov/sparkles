# Grounding ledger — cpu-pmu survey

Internal QA evidence for `docs/research/cpu-pmu/`. One ledger per page, a
master discrepancy register, and the [local-artifact map](./_sources.md).

> Not published research. Do not link to it from the survey pages.

**Status legend:** `✓` verified against a local artifact · `≈`
paraphrase-verified · `⚠` discrepancy found (see register) · `◯` not locally
groundable / open · `🌐` web-only fallback.
**Claim types:** quote · fact · figure · behavior · exposition · opinion.

## Per-page index

| Page                                                                                | Ledger                                      | Status     |
| ----------------------------------------------------------------------------------- | ------------------------------------------- | ---------- |
| linux-perf-events.md                                                                | [linux-perf-events](./linux-perf-events.md) | see ledger |
| elfutils.md                                                                         | [elfutils](./elfutils.md)                   | see ledger |
| libtraceevent.md                                                                    | [libtraceevent](./libtraceevent.md)         | see ledger |
| libnuma.md                                                                          | [libnuma](./libnuma.md)                     | see ledger |
| precise-sampling.md                                                                 | [precise-sampling](./precise-sampling.md)   | see ledger |
| arm.md                                                                              | [arm](./arm.md)                             | see ledger |
| riscv.md                                                                            | [riscv](./riscv.md)                         | see ledger |
| windows.md                                                                          | [windows](./windows.md)                     | see ledger |
| macos.md                                                                            | [macos](./macos.md)                         | see ledger |
| event-naming.md                                                                     | [event-naming](./event-naming.md)           | see ledger |
| index.md · concepts.md · comparison.md · sparkles-baseline.md · backend-proposal.md | [synthesis-pages](./synthesis-pages.md)     | see ledger |

## Master discrepancy register

Corrections of the research brief's embedded hypotheses (`R1`–`R16`, `R21`,
`R22`) and load-bearing surprises the survey itself established (`R17`–`R20`).
"Fixed?" = the survey pages state the corrected fact.

| #   | Page                        | Claim (as hypothesized / naively assumed)                                 | Correction                                                                                                                                                                                                                                    | Source                                                                         | Fixed? |
| --- | --------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------ |
| R1  | precise-sampling            | "Intel/AMD PEBS/IBS are all testable on the primary box"                  | AMD Zen 4 box has **no PEBS**; `cpu` PMU `caps/max_precise = 0`; IBS is the only precise engine — PEBS stays source/literature                                                                                                                | sysfs (this host); `arch/x86/events/amd/ibs.c`                                 | ✓      |
| R2  | precise-sampling            | "fall back to `cpu` PMU `precise_ip>0` if IBS unavailable"                | no precise mode exists on the AMD core PMU; `precise_ip` 1–2 is forwarded to `ibs_op`, `>2` → `-EOPNOTSUPP`                                                                                                                                   | `ibs.c:240-258`                                                                | ✓      |
| R3  | riscv                       | "`drivers/perf/riscv_ctr.c`" exists to read                               | file does not exist at `linux@e43ffb69e043` (v7.1-rc6); zero Smctr/Ssctr code tree-wide                                                                                                                                                       | tree grep (recorded)                                                           | ✓      |
| R4  | riscv                       | "CTR, ratified 2025"                                                      | ratified **2024-11-22**, v1.0, extension names **Smctr/Ssctr**; corroborated by the GitHub v1.0 "Ratified release" (2024-11-23)                                                                                                               | `riscv-ctr@42e299ca header.adoc`; release asset                                | ✓      |
| R5  | riscv                       | "AIA/`Ssaia` dependency for sampling (incl. guests)"                      | **host** sampling needs only Sscofpmf; AIA is required specifically for **guest** overflow delivery (`HVIEN` bit 13)                                                                                                                          | `arch/riscv/kvm/aia.c:565-567`                                                 | ✓      |
| R6  | macos                       | "document the DTrace `cpc` provider; run a `cpc` one-liner"               | no `cpc` provider exists anywhere in Apple's stack (xnu provider set + dtrace-413); SIP additionally blocks unprivileged dtrace                                                                                                               | `xnu bsd/dev/dtrace/`; `apple-dtrace@dtrace-413`; mac-bsn transcript           | ✓      |
| R7  | windows                     | "HCP's curated set = cycle-only"                                          | HCP surfaces up to 16 PMCs via `HwCounters[]` — but only under a WDK driver (`KeSetHardwareCounterConfiguration`, system-global, single-tenant); the _driver-free_ datum is `CycleTime` only                                                  | `win-enablethreadprofiling.html`, `wdk-kesethardwarecounterconfiguration.html` | ✓      |
| R8  | windows                     | `EnableThreadProfiling` lives in `realtimeapiset.h`                       | lives in **winbase.h** (tech root `hcp`); the `nf-realtimeapiset-*` URLs 404                                                                                                                                                                  | saved doc URLs                                                                 | ✓      |
| R9  | linux/elfutils              | perf reports unwind modules via `dwfl_report_module`                      | perf uses **`dwfl_report_elf`** ("`.find_elf` is not set as we use dwfl_report_elf() instead.")                                                                                                                                               | `tools/perf/util/unwind-libdw.c:66`                                            | ✓      |
| R10 | elfutils                    | `dwfl_module_addrsym` is the symbol lookup                                | `dwfl_module_addrinfo` is documented-preferred, and its `offset`/`sym` args **must be non-NULL** — NULL segfaults (hardware-hit)                                                                                                              | `libdwfl.h:495-520`; probe crash log                                           | ✓      |
| R11 | libnuma                     | libnuma wraps an address→node query                                       | **no such helper exists**; the query is raw `get_mempolicy(MPOL_F_NODE\|MPOL_F_ADDR)` / `move_pages` query mode; `numa_police_memory` only faults pages in                                                                                    | `numactl@93c1fe5 libnuma.c`, `shm.c:307`, `test/mynode.c:10`                   | ✓      |
| R12 | libtraceevent               | libtraceevent reads tracefs `format` files                                | it parses **caller-supplied buffers** only (file I/O is libtracefs's job); public header is `include/traceevent/event-parse.h`                                                                                                                | `libtraceevent@51d47b0 src/event-parse.c:8462-8467`                            | ✓      |
| R13 | precise-sampling / examples | link libnuma via `libs "numa"` (pkg-config)                               | numactl ships **no `numa.pc`**, and `get_mempolicy`/`move_pages` aren't in glibc — the probe calls the raw syscalls instead                                                                                                                   | `pkg-config --exists numa` (fails); numactl tree                               | ✓      |
| R14 | event-naming                | "PAPI presets unmapped/derived on modern µarchs"                          | `papi_events.csv` has explicit `amd64_fam19h_zen4` and `_zen5` preset sections                                                                                                                                                                | `papi@ec16e00f src/papi_events.csv:483-550`                                    | ✓      |
| R15 | event-naming                | libpfm4 name→encoding "just works" on current silicon                     | stock **libpfm 4.13.0 fails to auto-detect** family 25 model `0x61` (this Zen 4) — `PFM_ERR_NOTFOUND` for native names; fixed in git HEAD; backends must force the PMU from CPUID                                                             | 4.13.0 realized src vs `libpfm4@6870a9f`; probe E2                             | ✓      |
| R16 | arm                         | "architected `0x00-0x3F` vs IMPDEF `0x40+`" (two-way split)               | the catalog is **three-way**: architected (e.g. `SW_INCR`) ⊂ common `0x00-0x3F` (presence via `PMCEID*`) ⊂ IMPDEF `0x40+`; plus arch-extension space `0x4000+`                                                                                | `arm-data@0806afb1 pmu/*.json` (`architectural` flag); `arm_pmuv3.h`           | ✓      |
| R17 | arm/macos                   | (survey finding) Apple event numbering is stable across generations       | **M4/M5 remap the common subset onto PMUv3 architected numbers** (`INST_ALL` `0x8c`→`0x8`, `CORE_ACTIVE_CYCLE` `0x2`→`0x11`); M1–M3 use Apple numbers; Linux ships no M4 table and its 8-bit event field can't express kpep's wider selectors | kpep plists (mac-bsn) + `xnu cpc_arm64_events.c` + `apple_m1_cpu_pmu.c`        | ✓      |
| R18 | arm/macos                   | kpep `fixed_counters: 3` vs kpc `KPC_CLASS_FIXED` = 2 vs Linux driver = 2 | **unresolved** — the identity of the third kpep fixed counter is unknown (candidate: a fixed reference/uptime counter)                                                                                                                        | kpep plists vs `kern_kpc.c` / `apple_m1_cpu_pmu.c:22`                          | ☐ OPEN |
| R19 | linux-perf-events           | (naive assumption) MMAP2 records describe the whole address space         | `PERF_RECORD_MMAP2` is emitted **only for mappings created while the event is enabled**; pre-existing code must be synthesized from `/proc/PID/maps` — the build-id/stale-binary hazard for a self-profiling harness                          | probe (0 MMAP2 until forced); `tools/perf/util/machine.c`                      | ✓      |
| R20 | precise-sampling            | (naive attr) IBS opens like a core-PMU event                              | bare `exclude_kernel`/`exclude_hv` → `-EINVAL` on Zen 4 (no `IBS_CAPS_BIT63_FILTER`); privilege filtering needs the `swfilt` bit (`config2:0`); `exclude_hv` never accepted                                                                   | `ibs.c:346-370`; E2 errno matrix                                               | ✓      |
| R21 | arm                         | Arm ARM (DDI 0487) + SPE whitepaper fetchable to papers/                  | **GATED** — developer.arm.com is a JS SPA, direct PDFs 403 (Akamai), Wayback holds only HTML shells (CDX sweep recorded); cited by chapter name + issue **K.a**; grounded via in-kernel headers + arm-data                                    | CDX transcripts in [arm ledger](./arm.md)                                      | ✓      |
| R22 | macos                       | kpc per-thread counting demonstrable with recorded entitlement/root needs | confirmed **root-only** ("root or the blessed pid"); the `com.apple.private.ktrace-allow` escape is compiled only into DEVELOPMENT/DEBUG kernels; unprivileged floor is `proc_pid_rusage` (hw-verified EPERM matrix)                          | `kern_kpc.c:405-408`, `kern_ktrace.c:273-297`; Exp. a                          | ✓      |

## Environment / integrity notes

- `$REPOS/linux` reused read-only at a pre-existing detached checkout
  (`e43ffb69e043`, v7.1-rc6); never fetched or modified during the survey.
- mac-bsn runs xnu-12377.**91.3** while the open-source drop read is
  xnu-12377.**1.9** — same 12377 base for the T6041; line numbers cite the
  public drop (noted in the [macos ledger](./macos.md)).
- elfutils version skew: source read 0.195 (`6f8f78c`), runtime-linked/tested
  0.194 (nixpkgs) — all cited APIs exist in both.
- All experiments on the primary box ran unprivileged at
  `perf_event_paranoid = -1`; all mac-bsn experiments ran unprivileged with
  SIP enabled (`sudo -n` unavailable) — nothing was escalated or disabled.
