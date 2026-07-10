# Grounding sources — local-artifact map

Lookup table for the per-page verification pass. Every external citation in the
CPU-PMU survey maps here to a **local** artifact: a repo cloned under `$REPOS`
(pinned below), a PDF/HTML capture under `$REPOS/papers/cpu-pmu/`, or a recorded
experiment transcript. Web is a fallback **only** for the artifacts marked
_gated_. `$REPOS` = `/home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

**Acquisition:** 2026-07-10/11, by seven research workstreams (W1–W7). All
repos read at the pinned SHA; `$REPOS/linux` was a pre-existing clean checkout
(detached, **not** modified) reused read-only by W1–W4 and W7.

## Source repos (pinned to reviewed HEAD)

| Repo                           | Path                              | Pinned SHA          | As of      |
| ------------------------------ | --------------------------------- | ------------------- | ---------- |
| linux (v7.1-rc6)               | `$REPOS/linux`                    | `e43ffb69e043`      | 2026-05-31 |
| elfutils (0.195 src)           | `$REPOS/c/elfutils`               | `6f8f78c`           | 2026-07-09 |
| libtraceevent (1.9.0)          | `$REPOS/c/libtraceevent`          | `51d47b0`           | 2026-05-29 |
| numactl / libnuma (2.0.19)     | `$REPOS/c/numactl`                | `93c1fe5`           | 2026-06-30 |
| ARM-software/data              | `$REPOS/cpu-pmu/arm-data`         | `0806afb1`          | 2026-05-01 |
| applecpu (dougallj)            | `$REPOS/cpu-pmu/applecpu`         | `0e6bc3f6`          | 2023-07-13 |
| riscv-isa-manual               | `$REPOS/cpu-pmu/riscv-isa-manual` | `fbae3b43`          | 2026-07-10 |
| riscv-sbi-doc                  | `$REPOS/cpu-pmu/riscv-sbi-doc`    | `8a545eff`          | 2026-07-10 |
| riscv-control-transfer-records | `$REPOS/cpu-pmu/riscv-ctr`        | `42e299ca`          | 2026-07-10 |
| opensbi                        | `$REPOS/c/opensbi`                | `26257121`          | 2026-07-10 |
| krabsetw (Microsoft)           | `$REPOS/cpp/krabsetw`             | `6900de05`          | 2026-04-14 |
| windows-d (rumbu13)            | `$REPOS/dlang/windows-d`          | `f34527e`           | 2026-06-03 |
| xnu (apple-oss)                | `$REPOS/c/xnu`                    | tag `xnu-12377.1.9` | 2026-07-10 |
| dtrace (apple-oss)             | `$REPOS/c/apple-dtrace`           | tag `dtrace-413`    | 2026-07-10 |
| libpfm4 (perfmon2 canonical)   | `$REPOS/c/libpfm4`                | `6870a9f00412`      | 2026-07-11 |
| PAPI                           | `$REPOS/c/papi`                   | `ec16e00f8b48`      | 2026-07-11 |
| LIKWID                         | `$REPOS/c/likwid`                 | `f23c66630d1d`      | 2026-07-11 |
| intel/perfmon                  | `$REPOS/cpu-pmu/intel-perfmon`    | `683a4d0bdd08`      | 2026-07-11 |

Reference (not cloned): LDC 1.41.0 druntime `core/sys/linux/perf_event.d` and
`core/sys/windows/{dbghelp,psapi}.d`, read from the toolchain install resolved
via `ldc2.conf`; nixpkgs **libpfm 4.13.0** realized source (auto-detect
comparison against libpfm4 git HEAD); mac-bsn on-disk kpep plists
`/usr/share/kpep/{as1,a14,as3,as4-1,as5}.plist` (world-readable, macOS 26.3.1).

## Papers & captures — `$REPOS/papers/cpu-pmu/`

| Artifact                                                         | File                                                                                                  | Provenance                                                                                       |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| AMD64 APM Vol 2 (24593), IBS §13.3, 806 pp                       | `amd64-apm-vol2-24593.pdf`                                                                            | via verified Wayback snapshot, 2026-07-10                                                        |
| RISC-V CTR (Smctr/Ssctr) v1.0, **Ratified**, 23 pp               | `riscv-ctr-spec-v1.0.pdf`                                                                             | GitHub release `v1.0` asset (published 2024-11-23), 2026-07-10                                   |
| "Dissecting RISC-V Performance…" (arXiv 2507.22451), 16 pp       | `riscv-roofline-pmu-2507.22451.pdf`                                                                   | arXiv, 2026-07-10                                                                                |
| 28 Microsoft Learn pages (HCP, ETW, WPT/WPR, DbgHelp, NUMA, WDK) | `win-*.html`, `etw-*.html`, `wpt-*.html`, `wpr-*.html`, `dbghelp-*.html`, `numa-*.html`, `wdk-*.html` | `learn.microsoft.com`, retrieved 2026-07-10 (full URL map in the [windows ledger](./windows.md)) |

## Gated primaries → cite-by-name + secondary grounding

| Citation                                                 | Why gated                                                                                                                                                  | Ground instead against                                                                      |
| -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Arm ARM **DDI 0487** (latest = issue **K.a**)            | developer.arm.com is a JS SPA; direct PDF = Akamai HTTP-403; Wayback holds only HTML shells (CDX sweep 2026-07-10, recorded in the [arm ledger](./arm.md)) | in-kernel `include/linux/perf/arm_pmuv3.h` + `arm-data` JSON; cite chapters by name + issue |
| Arm **SPE whitepaper** / SPE "learn the architecture"    | same CDN gating, live 403/404                                                                                                                              | `drivers/perf/arm_spe_pmu.c` + Arm ARM SPE chapter by name                                  |
| Intel **SDM Vol 3** (PEBS chapters)                      | licence-gated download                                                                                                                                     | `arch/x86/events/intel/ds.c` + intel/perfmon JSONs; cite by section                         |
| AMD Zen 4 **PPR 55898** (extended IBS DataSrc encodings) | not openly downloadable at AMD docs URLs                                                                                                                   | APM Vol 2 §13.3 + `arch/x86/include/asm/amd/ibs.h` (which cites PPR 55898)                  |

## Experiment environments (recorded per experiment in pages + ledgers)

| Bed                        | Facts                                                                                                                                                                                                                                                                                                                        |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `x86_64-linux` (primary)   | NixOS, kernel **6.18.26**, AMD **Ryzen 9 7940HX** (Zen 4, family 0x19 model 0x61, 6 core PMCs), `perf_event_paranoid = -1`, single NUMA node, tracefs `id` files root-only; LDC **1.41.0**; elfutils **0.194** (runtime) / 0.195 (source); libpfm **4.13.0** (nixpkgs); numactl 2.0.19                                       |
| `aarch64-darwin` (mac-bsn) | Apple **M4 Max** (`Mac16,5`, die T6041, `hw.cpufamily 0x17d5b93a`), macOS **26.3.1** (25D771280a), **SIP enabled**, non-root (`sudo -n` unavailable); running kernel xnu-**12377.91.3** vs source drop xnu-**12377.1.9** (same 12377 base — version-skew note in the [macos ledger](./macos.md)); clang 21.0.0, xctrace 16.0 |
| `aarch64-linux`            | **none** — all ARM-Linux claims are source-reading of `linux@e43ffb69e043`, never hardware-verified                                                                                                                                                                                                                          |
| RISC-V                     | **none** — spec + kernel + firmware source only; QEMU deliberately not used for counts (does not model PMU counts faithfully)                                                                                                                                                                                                |
| Windows                    | **none** — official docs (saved) + open-source consumers (krabsetw, windows-d) only                                                                                                                                                                                                                                          |
