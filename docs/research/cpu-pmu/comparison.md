# CPU-PMU capability comparison

The survey's capstone: the **capability matrix** — the seven
[analysis concerns][spine] against every ISA × OS combination surveyed — the
consensus acquisition model, the architectural trade-offs behind the
differences, and the **delta table** mapping each capability onto where the
[sparkles baseline][baseline] stands today. Ends with the open questions the
survey could not close from this hardware.

**Last reviewed:** July 11, 2026

Verification tags: `[hw-verified: x86_64-linux]` (AMD Ryzen 9 7940HX, kernel
6.18.26) · `[hw-verified: aarch64-darwin]` (Apple M4 Max, macOS 26.3.1) ·
`[source-verified]` (pinned repos, see the deep-dives' Sources) ·
`[literature]`. There is **no** `aarch64-linux`, RISC-V, or Windows hardware
bed — those columns carry no hardware tags by construction.

---

## The capability matrix

One row per concern; each cell names the concrete mechanism (API / struct /
driver), links the owning deep-dive, and carries its strongest verification
tag. **Absent** cells are explicit — absence is a finding.

### Concern 1: scalar counting

| Platform       | Mechanism                                                                                                                                                                                                             | Tag                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| Linux · x86_64 | [`perf_event_open`][linux] + [event groups][c-group] (`PERF_FORMAT_GROUP`, all-or-nothing scheduling, [multiplex scaling][c-multiplex])                                                                               | `[hw-verified: x86_64-linux]`   |
| Linux · ARMv8+ | same syscall over [PMUv3][arm] (`PMCEID*` capability bitmaps; one PMU **per big.LITTLE cluster**, events must open on the pinned core's PMU)                                                                          | `[source-verified]`             |
| Linux · RISC-V | same syscall over the [SBI PMU indirection][riscv] (kernel → SBI `0x504D55` → M-mode firmware writes `mhpmevent`); legacy fallback = `cycle`/`instret` only                                                           | `[source-verified]`             |
| Windows        | [HCP][windows] `EnableThreadProfiling`/`ReadThreadProfilingData` — driver-free datum is `CycleTime` **only**; 16 PMC slots require a WDK driver (system-global, single-tenant); ETW `-pmc` logs PMCs on kernel events | `[literature]`                  |
| macOS          | [`kpc_set_thread_counting`][macos] (**root** — "root or the blessed pid"); unprivileged floor = `proc_pid_rusage(RUSAGE_INFO_V4)` → `ri_instructions`/`ri_cycles`                                                     | `[hw-verified: aarch64-darwin]` |

### Concern 2: overflow / IP sampling

| Platform       | Mechanism                                                                                                                                                                                                             | Tag                                                             |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| Linux · x86_64 | `sample_period`/`sample_freq` → NMI → [`PERF_RECORD_SAMPLE` ring buffer][linux]                                                                                                                                       | `[hw-verified: x86_64-linux]`                                   |
| Linux · ARMv8+ | PMUv3 overflow IRQ, same ring; EL-based privilege filters                                                                                                                                                             | `[source-verified]`                                             |
| Linux · RISC-V | **iff `Sscofpmf`** (LCOFI interrupt 13, `scountovf` shadow); without it the PMU is `NO_INTERRUPT` and `NO_EXCLUDE`; sampled IP = trapped `xepc` (skidded); **guest** delivery additionally needs AIA (`HVIEN` bit 13) | `[source-verified]`                                             |
| Windows        | ETW PMC-overflow: `TraceSetInformation(TraceProfileSourceConfigInfo)` → `PERF_PMC_PROFILE` events, `-stackwalk pmcinterrupt`; admin + `SeSystemProfilePrivilege`                                                      | `[literature]`                                                  |
| macOS          | [kperf][macos] timer/PMI actions into the kperf buffer; hardware **PC-capture on overflow** (`S3_1_C15_C14_1`); reachable via root or Instruments/`xctrace` (which runs unprivileged)                                 | `[source-verified]` + `[hw-verified: aarch64-darwin]` (xctrace) |

### Concern 3: precise data-source / address sampling

| Platform               | Mechanism                                                                                                                                                                                                             | Tag                                |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Linux · x86_64 (AMD)   | [IBS][precise]: `ibs_op` micro-op tagging, skid 0, fills [`perf_mem_data_src`][c-datasrc] + `WEIGHT` latency + data VA/PA; `swfilt` needed for privilege filtering on Zen 4                                           | `[hw-verified: x86_64-linux]`      |
| Linux · x86_64 (Intel) | [PEBS][precise]: `precise_ip` 1–3, hardware DS-area records, per-µarch `pebs_data_source[]`; **no PEBS on AMD** (`cpu` PMU `max_precise = 0`)                                                                         | `[source-verified]`                |
| Linux · ARMv8+         | [SPE][arm]: [AUX-buffer][c-aux] packets carrying PC + data VA/PA + latency; packet framing architected, **data-source decode implementation-defined** (MIDR-dispatched); PA collection gated by `perf_allow_kernel()` | `[source-verified]`                |
| Linux · RISC-V         | **Absent** — no ratified PEBS/SPE analog anywhere in the ISA manual                                                                                                                                                   | `[source-verified]` (absence)      |
| Windows                | **Absent publicly** — no data-address class in `TRACE_QUERY_INFO_CLASS`; kernel has internal-only PEBS plumbing (`EventTracePebsTracingInformation` in the undocumented enum); LBR is public but branch-only          | `[source-verified]`/`[literature]` |
| macOS                  | **Absent** — CPMU PC-capture only; no data VA/PA/latency packet surface (hardware `PMTRHLD*` thresholds exist but are not exposed as an API)                                                                          | `[source-verified]`                |

### Concern 4: code-space decode & symbolization

| Platform         | Mechanism                                                                                                                                                                                                                                                                                                                         | Tag                                |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- |
| Linux (all ISAs) | address-space model from [`PERF_RECORD_MMAP2`][linux] + `/proc/PID/maps` synthesis (MMAP2 is emitted **only for mappings created while enabled**); decode via [elfutils][elfutils] `libdwfl` (addr → module → symbol → line + inline); [build-id][c-buildid] validation; [DWARF-CFI unwind][c-unwind] of `STACK_USER`+`REGS_USER` | `[hw-verified: x86_64-linux]`      |
| Windows          | ETW image-load events; [DbgHelp/DIA][windows] over out-of-band PDB; build-id analog = PDB **GUID+Age**; symbol servers                                                                                                                                                                                                            | `[literature]`/`[source-verified]` |
| macOS            | [dyld image list][macos] (`_dyld_get_image_*`, `TASK_DYLD_INFO`) with a **single shared-cache slide**; Mach-O + dSYM via `atos`/CoreSymbolication (closed framework)                                                                                                                                                              | `[hw-verified: aarch64-darwin]`    |

### Concern 5: event-space & tracing

| Platform               | Mechanism                                                                                                                                                                                                  | Tag                                                          |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Linux                  | [tracepoints][c-eventspace] (`PERF_TYPE_TRACEPOINT`, tracefs `format` schemas, decode via [libtraceevent][libtraceevent] — which does **not** read tracefs itself); `id` files root-only on hardened hosts | `[hw-verified: x86_64-linux]` (gating) / `[source-verified]` |
| Linux · branch records | x86 LBR; ARM [BRBE][arm] (≤64 records, type filters, `branch_stack`); RISC-V [CTR][riscv] ratified v1.0 (2024-11-22) but **no Linux consumer** at v7.1-rc6                                                 | `[source-verified]`                                          |
| Windows                | [ETW][windows] providers + TDH schemas (krabsetw = the open consumption model; kernel-logger enable uses the undocumented `PERFINFO_GROUPMASK` path); LBR public since Win10 19H1                          | `[source-verified]`                                          |
| macOS                  | kdebug/ktrace (kperf emits kdebug); DTrace exists but has **no `cpc` provider** (never ported from Solaris) and SIP blocks unprivileged use                                                                | `[hw-verified: aarch64-darwin]` + `[source-verified]`        |

### Concern 6: NUMA & topology

| Platform       | Mechanism                                                                                                                                                                                                                                                                               | Tag                                                    |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Linux          | sysfs `/sys/devices/system/node` (+ SLIT distances) wrapped by [libnuma][libnuma]; page→node oracles = raw `get_mempolicy(MPOL_F_NODE\|MPOL_F_ADDR)` / `move_pages` query (**no libnuma helper exists**); [uncore PMUs][c-uncore] are per-domain (`cpumask`), never thread-attributable | `[hw-verified: x86_64-linux]` (single-node round-trip) |
| Linux · ARMv8+ | CMN (mesh, node-typed encodings) / DSU (cluster L3) / DMC-620 (DDR) uncore drivers, each cpumask-bound                                                                                                                                                                                  | `[source-verified]`                                    |
| Linux · RISC-V | SBI `CACHE_NODE` **counter** only; no uncore driver framework at v7.1-rc6                                                                                                                                                                                                               | `[source-verified]`                                    |
| Windows        | `GetLogicalProcessorInformationEx` (topology), `VirtualAllocExNuma` (placement), `QueryWorkingSetEx` → per-page `Node` (the `move_pages`-query analog); **no sampled-address→node path** (follows from concern 3)                                                                       | `[source-verified]`/`[literature]`                     |
| macOS          | **Collapses** — Apple Silicon is UMA; the only topology axis is P/E `perflevels`                                                                                                                                                                                                        | `[hw-verified: aarch64-darwin]`                        |

### Concern 7: event naming & encoding

| Platform       | Mechanism                                                                                                                                                                                                                                                                                 | Tag                                                   |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- |
| Linux · x86_64 | [libpfm4][naming] (the engine under PAPI; CPUID detect + per-µarch tables; **auto-detect lags new silicon** — 4.13.0 misses Zen 4 model 0x61); Intel: public `intel/perfmon` self-generates the kernel's perf JSON; AMD: kernel-tree-only JSONs, different name space for the same events | `[hw-verified: x86_64-linux]`                         |
| Linux · ARMv8+ | `ARM-software/data` JSON catalog (`architectural: true/false` — the split is **three-way**: architected ⊂ common `0x00-0x3F` ⊂ IMPDEF); kernel `pmu-events/arch/arm64` (no `apple/` directory)                                                                                            | `[source-verified]`                                   |
| Linux · RISC-V | SBI standardizes the 20-bit `event_idx` **classes**; actual `mhpmevent` selectors implementation-defined (DT `riscv,event-to-mhpmevent`); vendor JSONs for 5 vendors                                                                                                                      | `[source-verified]`                                   |
| Windows        | curated HAL profile-sources (`-pmcsources`); raw events registerable since Win10 1903 but only **system-globally** (WPRP/registry `Event`/`Unit`/`ExtendedBits`), not per-open; cross-ISA at the profile-source layer                                                                     | `[literature]`                                        |
| macOS          | kpep plist DBs per cpufamily (world-readable); kernel `RESTRICT_TO_KNOWN` allowlist (102 events on T6041) — **even root cannot program unlisted selectors**; **M4 remapped the common subset onto PMUv3 architected numbers** (M1–M3 use Apple numbers)                                   | `[hw-verified: aarch64-darwin]` + `[source-verified]` |

> [!NOTE]
> No naming layer spans operating systems. libpfm4/PAPI are Linux-perf only;
> LIKWID reaches furthest across _vendors_ (it ships an Apple-M1 table) but is
> Linux-only too; Windows and macOS each curate their own vocabulary. A
> cross-OS harness must own its event vocabulary — the finding the
> [backend proposal][proposal] (§M1/M2) is built on.

---

## The consensus standard

The field's de-facto reference model is Linux `perf_events` — the
**hub-and-decoders architecture** ([linux-perf-events.md][linux]):

- **One acquisition hub.** A single syscall + one `perf_event_attr` ABI covers
  counting _and_ sampling on every ISA; hardware diversity is absorbed by
  per-PMU drivers below the ABI, not by per-vendor userspace APIs above it.
  Even the three mutually-alien precise engines (PEBS, IBS, SPE) surface
  through **one** `perf_mem_data_src` union.
- **Independent decoders.** Code-space (elfutils), event-space
  (libtraceevent), topology (libnuma) are libraries that never touch the PMU;
  the hub never interprets. Each side is replaceable without the other.
- **Capability by probe.** `PMCEID*` bitmaps, sysfs `caps/`, open-time errno —
  a consumer discovers, per host, what exists.

Everything else surveyed is either a **subset** of this model (Windows: three
disjoint surfaces — curated HCP, ETW, closed ring-0 drivers; macOS: a capable
CPMU fenced behind root/entitlements/allowlist with Instruments as the
sanctioned broker) or the same model behind an **indirection** (RISC-V: the
identical perf ABI with firmware owning the counters via SBI).

## Architectural trade-offs

| Axis                    | Poles                                                                | Where each lands                                                                                                                                                     |
| ----------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Event access policy     | open selectors ↔ [curated lists][c-curation]                         | Linux open (any `config`, `paranoid`-gated) · Windows curated + global registration escape · macOS allowlist even for root                                           |
| Precise-sampling engine | counter-extension (PEBS) ↔ op-tagging (IBS) ↔ buffer-streaming (SPE) | PEBS: precise _per event_, DS-area; IBS: skid-0 by construction, event-agnostic, coarse NUMA bit; SPE: highest bandwidth, userspace decode, impl-defined data-source |
| Decode inputs           | in-band (records carry identity) ↔ out-of-band (separate artifacts)  | Linux MMAP2 + in-ELF DWARF (+ optional in-record build-id) · Windows PDB by GUID+Age via symbol servers · macOS dSYM + shared-cache slide                            |
| Counter ownership       | kernel-arbitrated per-event ↔ global single-tenant                   | Linux per-fd scheduling/multiplex · Windows driver config is system-global, one profiler at a time · macOS single-owner CPMU arbitration (`EBUSY`)                   |
| Control plane           | direct MSR/sysreg in kernel ↔ firmware indirection                   | x86/ARM: kernel programs hardware · RISC-V: M-mode firmware programs `mhpmevent`, kernel asks via SBI                                                                |
| Naming ownership        | vendor-published ↔ kernel-tree ↔ OS-curated                          | Intel publishes (`intel/perfmon`) · AMD contributes in-kernel only · ARM publishes JSON · Apple ships kpep plists · Windows HAL curates                              |

---

## The delta table: the survey vs. the sparkles baseline

Each survey capability against [today's layer][baseline], with the
[proposal][proposal] milestone that closes the gap.

| Capability (best practice found)                                           | sparkles today                                                  | Gap                                                                   | Closes in                                   |
| -------------------------------------------------------------------------- | --------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------- |
| Grouped counting, exact (all-or-nothing groups)                            | ✅ 7-event group, calibration-drop of LLC pair                  | none — matches the survey's exact-counts stance                       | —                                           |
| Labeled multiplex estimates (`enabled/running` scaling, ~1% at 10-on-6)    | ❌ avoided entirely (columns dropped instead)                   | estimates never offered, coverage silently narrows                    | M2 (`countingScaled`)                       |
| Raw / per-µarch event selectors + naming tables                            | ❌ 7 hardcoded generics                                         | no vocabulary beyond `PERF_COUNT_*`; nothing µarch-specific reachable | M2 (`countingRaw`, `eventNaming`)           |
| [Self-monitoring][c-rdpmc] reads (rdpmc seqlock, ~10× cheaper bracket)     | ❌ `read(2)`/`ioctl(2)` per pass                                | syscall-priced brackets on very short bodies                          | M2 (`selfMonitoring`)                       |
| Overflow/IP sampling + flat profiles                                       | ❌ absent                                                       | "what regressed" but never "where"                                    | M6 (`ipSampling`)                           |
| Precise memory sampling (IBS skid-0 on this hardware; `perf_mem_data_src`) | ❌ absent                                                       | no latency distributions, no data addresses                           | M5 (`preciseMemory`)                        |
| Symbolization + build-id validation (libdwfl; stale-binary hazard)         | ❌ absent                                                       | nothing to attribute samples to                                       | M6 (`symbolization`)                        |
| Event-space gating (tracepoints beyond syscalls; PSI, sched)               | ⚠️ syscall counting only, root-gated tracefs correctly detected | no scheduling/fault/pressure context                                  | [delivery plan][plan] M5 (PSI) / M9 (sched) |
| NUMA topology + page→node oracles                                          | ❌ absent                                                       | single-node today, but zero awareness even of that                    | M5 (`numaAttribution`)                      |
| macOS floor (`proc_pid_rusage` unprivileged instructions/cycles)           | ❌ stub                                                         | loses _all_ counters on a platform that offers a real floor           | M3                                          |
| Windows floor (`CycleTime` driver-free; ETW when elevated)                 | ❌ stub                                                         | same cliff                                                            | M4                                          |
| Capability reporting ("unavailable because X")                             | ⚠️ per-tier `status()` strings                                  | absences not enumerated per capability                                | M1                                          |

---

## Open questions & gaps

What stayed `[literature]`/`[source-verified]` for lack of hardware, plus
known hazards the harness must carry forward:

1. **ARM-Linux is entirely source-verified.** SPE sampling, PMUv3 counter
   behavior, BRBE, CMN/DSU/DMC uncore, big.LITTLE per-PMU opening, and the
   `perf_user_access` userpage path have **no hardware verification** — no
   `aarch64-linux` box existed. First target when one appears: re-run the
   [counting probe][ex-counting] and an SPE capture on a Neoverse or
   big.LITTLE part.
2. **RISC-V has never been executed.** Sscofpmf sampling, SBI counter
   behavior, and CTR are spec + kernel + firmware reading. CTR additionally
   has **no Linux consumer** to even read yet; vendor `mhpmevent` tables
   (5 vendors in-tree) are unexercised. QEMU was deliberately not used for
   counts (it does not model PMUs faithfully).
3. **Intel PEBS is unverified locally** — the test bed is AMD (no PEBS;
   `max_precise = 0`). PEBS claims trace to `ds.c` + docs; a PDIR/`precise_ip
= 3` experiment needs Intel silicon.
4. **Cross-node NUMA classification is undemonstrated** — the box has one
   node; the oracles round-trip but never disagree with anything. Multi-socket
   verification (and IBS's remote-bit behavior across real hops) is open.
5. **SNC/NPS uncore-topology caveats** `[literature]`: Intel Sub-NUMA
   Clustering and AMD NPS BIOS modes multiply visible nodes and re-scope
   uncore counters; a NUMA-aware backend must re-probe topology per boot and
   never cache node counts across configuration changes. Undemonstrable on
   this laptop-class part (which exposes no L3/DF uncore PMUs at all —
   itself worth re-checking on desktop/server Zen).
6. **The Apple third fixed counter.** kpep advertises `fixed_counters: 3` on
   every generation; xnu's `kpc` FIXED class and Linux's driver model 2
   (cycles, instructions). What the third is remains unresolved — carried as
   an open discrepancy in the survey's internal QA ledger.
7. **Apple M4 on Linux.** The M4 encoding remap is hw-confirmed from macOS,
   but Linux's `apple_m1_cpu_pmu.c` has no M4 table and its 8-bit event field
   cannot express the wider kpep selectors — whether/when upstream grows a
   per-cpu-type table is open.
8. **Windows PEBS-class ETW** exists in the undocumented internal enum only.
   Whether it ever becomes public API is unknowable from outside; the survey
   records the boundary as of Server 23H2 docs.
9. **Build-id / stale-binary hazard** (for the harness, on every OS): Linux
   MMAP2 arrives only for live mappings (synthesize + validate build-ids);
   Windows needs GUID+Age matching; macOS needs dSYM discipline (`dsymutil`
   on a one-shot build yields an _empty_ dSYM). Encoded as M6 acceptance
   criteria in the [proposal][proposal].
10. **libpfm4's silicon lag** is structural: any naming layer bundled today
    will meet unrecognized CPUs tomorrow — the backend must force PMU tables
    from CPUID and fail _loudly_ into `unavailableBecause`, never silently
    misencode. `[hw-verified: x86_64-linux]` (4.13.0 vs model 0x61).
11. **Gated primaries.** Arm ARM DDI 0487 (issue K.a) and the SPE whitepaper
    could not be acquired (CDN-gated; Wayback holds only HTML shells) — ARM
    architectural claims rest on the in-kernel headers + `arm-data`, cited by
    chapter name. Intel SDM and the Zen 4 PPR are cited by section for the
    same reason.

## Sources

Aggregated from the deep-dives; every cell's locator lives in its page's
Sources section (repos pinned by SHA in the survey's internal QA ledger).
Direct experiment evidence: the five [runnable probes][ex-counting] and the
mac-bsn transcripts quoted in [macos.md][macos]/[arm.md][arm].

<!-- References -->

[spine]: ./#the-seven-concerns
[baseline]: ./sparkles-baseline.md
[proposal]: ./backend-proposal.md
[plan]: ../../specs/test-runner/PLAN.md
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
[ex-counting]: ./examples/counting-group.d
[c-group]: ./concepts.md#event-group
[c-multiplex]: ./concepts.md#multiplexing-and-scaling
[c-datasrc]: ./concepts.md#data-source-attribution
[c-aux]: ./concepts.md#aux-buffer
[c-buildid]: ./concepts.md#build-id
[c-unwind]: ./concepts.md#unwinding
[c-eventspace]: ./concepts.md#event-space-and-tracepoints
[c-uncore]: ./concepts.md#uncore-pmu
[c-curation]: ./concepts.md#capability-curation
[c-rdpmc]: ./concepts.md#self-monitoring-and-user-space-counter-reads
