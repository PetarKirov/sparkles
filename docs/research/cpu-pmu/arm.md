# ARM PMUv3 / SPE / BRBE (AArch64)

The ARMv8-A/ARMv9-A mapping of the survey's [seven concerns][concepts]: a
_specification-architected_ counting model (**PMUv3**) whose event space, counter
count, and privilege filters are all discoverable from system registers, plus two
hardware sampling engines — **SPE** for [precise, data-source-attributed
sampling][precise-page] and **BRBE** for [branch records][branch-records] — and,
as a deliberately-separated sidebar, Apple Silicon: an ARM core that is _not_
PMUv3.

| Field            | Value                                                                                                                                                               |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| ISA              | ARMv8-A / ARMv9-A (AArch64)                                                                                                                                         |
| Counting API     | PMUv3 via [`perf_event_open(2)`][linux] (`type=PERF_TYPE_RAW`, `config`=event; a per-PMU `type` selects a cluster or uncore PMU)                                    |
| Precise sampling | **SPE** (Statistical Profiling Extension) → perf [AUX ring][aux]                                                                                                    |
| Branch records   | **BRBE** (Branch Record Buffer Extension) → perf `branch_stack`                                                                                                     |
| Self-monitoring  | `PMEVCNTR<n>_EL0` reads gated by `PMUSERENR_EL0` + the `perf_user_access` sysctl (the [`rdpmc` analog][self-monitoring])                                            |
| Event catalog    | [`ARM-software/data`][arm-data] JSON (per core) + in-tree [`tools/perf/pmu-events/arch/arm64`][pmu-events-arm64]                                                    |
| Kernel read      | v7.1-rc6, [`linux@e43ffb69e043`][arm-pmuv3-c]                                                                                                                       |
| Spec             | Arm ARM **DDI 0487** issue **K.a** — _"The Performance Monitors Extension"_ / _"The Statistical Profiling Extension"_ chapters (**GATED**, see [Sources](#sources)) |
| Verification     | `[source-verified]` throughout; `[hw-verified: aarch64-darwin]` for the Apple microarch reference; **no `[hw-verified: aarch64-linux]`**                            |

> [!IMPORTANT]
> **No `aarch64-linux` hardware was available for this survey.** Every ARM-Linux
> claim on this page is _source reading_ of the kernel driver at
> [`linux@e43ffb69e043`][arm-pmuv3-c], tagged `[source-verified]` — never a
> hardware observation. The only ARM silicon actually measured is Apple's, on
> macOS (`mac-bsn`, M4 Max), and it is neither Linux nor PMUv3; it lives in the
> [Apple Silicon sidebar](#apple-silicon-microarchitecture-reference) tagged
> `[hw-verified: aarch64-darwin]`. Where a spec figure comes from the Arm ARM
> (DDI 0487) it is tagged `[literature]` and cited by chapter name, because the
> PDF is [gated](#sources).

---

## Overview

### What it acquires

On ARM-Linux the acquisition surface is the same [`perf_event_open(2)`][linux] hub
as everywhere else — the ARM specificity is entirely in _what the hardware
exposes and how it is discovered_. PMUv3 (the "Performance Monitors Extension,
version 3") is the **architected** core-PMU model: a bank of event counters
(`PMEVCNTR<n>_EL0`), one event-select register each (`PMEVTYPER<n>_EL0`), a
control register (`PMCR_EL0`) that also reports the counter count, and two
capability bitmaps (`PMCEID0/1_EL0`) that publish _which architected events this
particular core actually implements_. A portable harness never has to guess: it
reads the registers.

The one place that discipline breaks is Apple Silicon, whose PMU is
implementation-defined and undocumented — which the Linux driver author records
with unusual candour ([`apple_m1_cpu_pmu.c:31-40`][apple-m1-c]):

> _"Description of the events we actually know about, as well as those with a
> specific counter affinity. Yes, this is a grand total of two known counters,
> and the rest is anybody's guess."_

That single sentence frames the whole page: everywhere PMUv3 is architected and
self-describing; Apple is the reverse-engineered exception, and even its event
_numbering_ [changed at M4](#apple-silicon-microarchitecture-reference).

### Design philosophy: discoverable, not tabulated

ARM's design bet is **capability discovery over static tables**. Intel needs a
per-model event table to know what a core can count; PMUv3 lets the core answer
for itself through `PMCEID*` and `PMCR.N`. The kernel driver leans on this
directly — it will only expose a "common" event through sysfs or accept it in
`map_event` if the corresponding `PMCEID` bit is set
([`arm_pmuv3.c:1261-1264`][arm-pmuv3-c]: _"Only expose micro/arch events supported
by this PMU"_). The trade-off is that _naming_ still needs
[per-microarchitecture tables][event-naming] (`ARM-software/data`,
`pmu-events/arch/arm64`), because discovery tells you an event _exists_, not what
to _call_ it.

---

## How it works

The AArch64 core PMU is a set of `EL0`/`EL1` system registers, wrapped by the
`arm_pmu` framework and surfaced to userspace as one or more sysfs PMU devices
(`/sys/bus/event_source/devices/armv8_*`). A `perf_event_open` with
`type=PERF_TYPE_RAW` and `config`=event-number programs one `PMEVTYPER<n>`, arms
the matching `PMEVCNTR<n>`, and — for sampling — routes counter overflow to a
per-CPU interrupt. On big.LITTLE parts there is _more than one_ such device (one
per microarchitecture cluster), so the `type` field, not just `config`, chooses
the PMU. SPE and BRBE hang off this same core PMU: SPE as a separate sysfs device
feeding an [AUX ring][aux], BRBE as a `branch_stack` capability probed _inside_
the core-PMU probe. The rest of this page walks the register model concern by
concern.

---

## PMUv3 event model

### The event space and its two-boundary layout

The `PMEVTYPER.EVENT` selector is **16-bit** (`ARMV8_PMU_EVTYPE_EVENT
GENMASK(15,0)`, [`arm_pmuv3.h:239`][arm-pmuv3-h]). The number line has two
boundaries, not one:

| Range           | Meaning                                                                                                                                            | Discovery                     |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| `0x0000–0x003F` | **common** architectural + microarchitectural events (64 slots)                                                                                    | `PMCEID0/1_EL0` bit per event |
| `0x0040–0x3FFF` | **IMPDEF** ("recommended implementation-defined") events                                                                                           | vendor tables only            |
| `0x4000+`       | **architected extensions** — SPE `0x4000–0x4003`, AMUv1 `0x4004–5`, long-latency-miss `0x4006–0x400B`, trace-buffer/-unit `0x400C+`, MTE `0x4024+` | `PMCEID` extended half        |

`[source-verified]` `linux@e43ffb69e043 include/linux/perf/arm_pmu.h:125`
(`ARMV8_PMUV3_MAX_COMMON_EVENTS 0x40`); [`arm_pmuv3.h:16-206`][arm-pmuv3-h]
(the `0x00-0x3F` common block, then `ARMV8_IMPDEF_*` at `0x40+`) and `:82-119`
(the `0x4000+` extension ranges).

### PMCEID: per-core capability bitmaps

`PMCEID0_EL0` and `PMCEID1_EL0` are the [capability-curation][curation] mechanism
built into the ISA: each bit says _"this core implements common event N."_ The
driver reads them into `pmceid_bitmap` (events `0x00–0x3F`) and
`pmceid_ext_bitmap` (the `0x4000–0x403F` half) at probe time, and every later
visibility/mapping decision consults them. `[source-verified]`
[`arm_pmuv3.c:1333-1343`][arm-pmuv3-c] (read + `bitmap_from_arr32`), `:1261-1264`
(the "only expose supported events" gate), `:281-289` (sysfs visibility gate).

### The three-way taxonomy: a refinement of "common vs IMPDEF"

The naïve reading is a two-way split at `0x40`: _common_ below, _IMPDEF_ above.
That boundary is real and correct, but ARM's own machine-readable catalog
([`ARM-software/data`][arm-data]) refines it into **three** tiers by carrying an
explicit `architectural: true/false` flag on every event
([architected-vs-implementation-defined][arch-vs-impdef]):

| Tier                           | Example (arm-data)                                 | Membership                                    |
| ------------------------------ | -------------------------------------------------- | --------------------------------------------- |
| **architectural** (mandatory)  | `SW_INCR` code 0 → `architectural: true`           | a small mandatory subset _inside_ `0x00–0x3F` |
| **common** (present-if-PMCEID) | `L1I_CACHE_REFILL` code 1 → `architectural: false` | most of `0x00–0x3F`; microarchitectural       |
| **IMPDEF**                     | anything `0x0040+`                                 | vendor-specific                               |

So `architectural ⊂ common ⊂ all`: the mandatory events are a stricter subset
_within_ the common range, presence of the rest is a per-core `PMCEID` fact, and
`0x40+` is vendor territory. `[source-verified]`
`arm-data@0806afb1 pmu/neoverse-n1.json` (the `architectural` field;
`counters: 6`; 110 events; `armv8.2-a`), `pmu/c1-ultra.json` (`armv9.2-a`).
Linux's in-tree cross-reference lives under
[`tools/perf/pmu-events/arch/arm64/{arm,ampere,hisilicon,nvidia,…}/`][pmu-events-arm64]
plus `recommended.json` — and notably ships **no `apple/` directory**.

### Generic-event mapping

`armv8_pmuv3_perf_map` maps the portable `PERF_TYPE_HARDWARE` events onto common
PMUv3 numbers: `CPU_CYCLES(0x11)`, `INST_RETIRED(0x08)`, `L1D_CACHE_REFILL(0x03)`
for cache-misses, `BR_MIS_PRED(0x10)`, and `STALL_FRONTEND`/`STALL_BACKEND`.
`BRANCH_INSTRUCTIONS` is special-cased to `BR_RETIRED(0x21)`, falling back to
`PC_WRITE_RETIRED(0x0C)` when `PMCEID` says `BR_RETIRED` is absent — a discovery
decision made at runtime. Older or irregular cores (A53/A57/A73/ThunderX/Vulcan)
carry override cache maps. `[source-verified]` [`arm_pmuv3.c:45-160`][arm-pmuv3-c]
(maps), `:1198-1214` (branch special-case), `:1275-1300` (per-uarch `map_event`).

A `FEAT_PMUv3_TH` core additionally exposes **threshold counting**
(`PMEVTYPER.TH`/`TC`: only count when the per-cycle event value crosses a
threshold), surfaced through perf `config1` fields and capped by `PMMIR.THWIDTH`.
`[source-verified]` `arm_pmuv3.c:311-360, 416-441, 1142-1152`.

---

## Counters and width evolution

The counter _count_ is discoverable, and the counter _width_ has grown across
PMUv3 revisions — the single most version-sensitive fact for a harness that wants
to avoid [multiplexing][multiplexing] or counter overflow.

- **Count.** `PMCR.N` (bits 15:11) reports the number of event counters;
  `armv8pmu_probe_pmu` reads it with `FIELD_GET(ARMV8_PMU_PMCR_N, …)` and then
  reserves the [fixed counters][fixed-counters]: cycle counter at index **31**,
  and — on PMUv3p9 — a dedicated instruction counter at index **32**.
  `[source-verified]` [`arm_pmuv3.c:1322-1331`][arm-pmuv3-c];
  [`arm_pmuv3.h:9-11,219`][arm-pmuv3-h].
- **Cycle counter** (idx 31) is **always 64-bit**.
- **PMUv3p5 long event counters.** `is_pmuv3p5(pmuver)` (arm64 only) sets
  `PMCR.LP`, making _event_ counters 64-bit ("long event"). `[source-verified]`
  `arm_pmuv3.c:489-492` (`has_long_event`), `:1189-1190` (`PMCR_LP` at reset).
- **Pre-p5 chaining.** Without long events, a 64-bit event is formed by
  **chaining two adjacent 32-bit counters**; the driver reads the high/low pair
  and biases the 32-bit-overflow interrupt point accordingly.
  `[source-verified]` `arm_pmuv3.c:504-513` (`event_is_chained`), `:545-553`
  (chained read), `:555-583` (overflow bias).
- **PMUv3p9 dedicated instruction counter.** `FEAT_PMUv3_ICNTR` (Armv9.4) adds a
  fixed `PMICNTR_EL0` at index 32, discovered via `ID_AA64DFR1_EL1.PMICNTR`.
  `[source-verified]` [`arch/arm64/include/asm/arm_pmuv3.h:57-62,92-97`][arm64-pmuv3-h]
  (`pmuv3_has_icntr`, `PMICNTR_EL0` access); [`arm_pmuv3.h:11`][arm-pmuv3-h]
  (`INSTR_IDX 32`).

> [!NOTE]
> **Width is a milestone.** A pre-p5 core needs _two_ physical counters for one
> 64-bit event (halving the group budget); a p5 core gets 64-bit event counters
> for free; a p9 core additionally frees a general counter by moving instructions
> to `PMICNTR`. A cross-generation harness must probe `PMCR.LP`/`ID_AA64DFR1` — it
> cannot assume any of the three.

---

## Counting privilege, overflow sampling, and self-monitoring

### EL-exclusion filters

ARM's privilege axis is the **Exception Level**. The counter's event-filter bits
select which EL it counts at — `EXCLUDE_EL0/EL1/NS_EL1/NS_EL0`, `INCLUDE_EL2`,
`EXCLUDE_EL3` — and perf's `exclude_user`/`exclude_kernel`/`exclude_hv`/
`exclude_host`/`exclude_guest` map onto them in a VHE-aware way. `exclude_idle`
has no PMUv3 equivalent and returns `EOPNOTSUPP`. `[source-verified]`
[`arm_pmuv3.h:246-251`][arm-pmuv3-h]; [`arm_pmuv3.c:1090-1160`][arm-pmuv3-c]
(esp. `:1099-1102` for `exclude_idle`, `:1117-1136` for the EL mapping).

### Overflow / IP sampling

[Overflow sampling][overflow] is ordinary PMUv3: program a counter toward
overflow, take the per-core [PMI][pmi] (a normal PPI, not an NMI), and read the
interrupted IP from `pt_regs`. Everything downstream of the interrupt — the
[precise-vs-skid][precise-page] story, ring-buffer consumption, and
[symbolization][symbolization] — is Linux-generic and identical to x86; ARM's
_precise_ answer is [SPE](#spe-the-statistical-profiling-extension), covered
below, not the overflow path.

### Self-monitoring: userspace counter reads (the `rdpmc` analog)

> The cross-check pass asked whether arm64 has an equivalent of x86's
> `cap_user_rdpmc` userpage. **It does** — this is the answer, source-verified at
> `linux@e43ffb69e043`.

arm64 supports direct EL0 counter reads without a syscall, the lowest-overhead
[self-monitoring][self-monitoring] path, and it is **doubly gated**. First, a
per-event opt-in: the `rdpmc` bit is `config1[1:1]`
(`ATTR_CFG_FLD_rdpmc → config1`, [`arm_pmuv3.c:309-311,324,336-339`][arm-pmuv3-c]),
and a user-readable event must be **task-bound** (`PERF_ATTACH_TASK`) and land in
a **single, unchained** counter (`arm_pmuv3.c:1249-1258`). Second, a global
sysctl `/proc/sys/kernel/perf_user_access` (default **0**, `mode 0644`, range
`[0,1]`; `sysctl_perf_user_access`, `arm_pmuv3.c:329`, `:1412-1422`) — writing 0
IPIs every CPU to slam the door (`armv8pmu_disable_user_access_ipi`, `:1396-1410`).
When both gates pass and a user-access event is scheduled, `armv8pmu_start` calls
`armv8pmu_enable_user_access`, which writes **`PMUSERENR_EL0`** with the
`ER | CR | UEN` bits to open EL0 counter/cycle reads, first zeroing or masking
(`PMUACR` on PMUv3p9) the _unused_ counters so their contents can't leak
(`arm_pmuv3.c:790-821`, `:836-849`). Finally `arch_perf_update_userpage` publishes
`cap_user_rdpmc` and `pmc_width` (32 or 64) in the mmap'd `perf_event_mmap_page`,
exactly as x86 does (`arm_pmuv3.c:1605-1622`) — so the seqlock-protected
[user page][self-monitoring] contract is byte-for-byte the same ABI. One
deliberate asymmetry: the dedicated instruction counter is **never** exposed to
userspace, _"as userspace may not know how to handle it"_ (`arm_pmuv3.c:1034-1045`).
Feature history: arm64 userspace counter access landed in **Linux 5.17** (2022);
the exact commit was not cheaply re-derivable within the source-check timebox
(the shallow-history `-S` search surfaces only the v6.4 driver relocation), so the
kernel _version_ is stated from known history while the _mechanism_ above is fully
source-verified. `[source-verified]`

---

## SPE: the Statistical Profiling Extension

SPE is the ARM analog of Intel **PEBS** / AMD **IBS**: instead of an interrupt
handler sampling a skewed IP, the _hardware_ tags operations and writes richly
attributed sample packets into a memory buffer, which perf surfaces as an
[AUX ring][aux]. It is the source of ARM's [precise, data-source-attributed
samples][precise-page]; W2's [precise-sampling page][precise-page] owns the
cross-vendor data-source semantics, so this section stays on the ARM register
mechanics.

### The AUX-buffer model

A hardware profiling buffer bounded by `PMBLIMITR_EL1`/`PMBPTR_EL1` is filled in
memory and handed to perf through `arm_spe_perf_aux_output_begin`. Each record
carries a PC, a data virtual address, an optional data physical address, access
latency, a data-source code, and a timestamp. `[source-verified]`
[`arm_spe_pmu.c:64-108`][arm-spe-c] (buffer regs), `:497-620` (AUX
begin/pad/next-offset), `:880-923` (start: program filter/latency/interval/PMSCR).

### The PMS\* register map (driven from perf `config`/`config1..4`)

| Register                       | perf field carries                                                                     |
| ------------------------------ | -------------------------------------------------------------------------------------- |
| `PMSCR_EL1`                    | `TS` (timestamp), `PA` (phys-addr), `PCT` (phys-timestamp), `E0SPE`/`E1SPE` EL enables |
| `PMSIRR_EL1`                   | sample interval + `RND` (interval jitter)                                              |
| `PMSFCR_EL1`                   | filter by op class — branch / load / store / SIMD / FP + per-class masks               |
| `PMSEVFR_EL1` / `PMSNEVFR_EL1` | event filter / inverse-event filter                                                    |
| `PMSLATFR_EL1`                 | minimum-latency threshold                                                              |
| `PMSDSFR_EL1`                  | data-source filter (`FEAT_SPE_FDS`)                                                    |

`[source-verified]` `arm_spe_pmu.c:200-260` (field defs with register comments),
`:367-386` (`to_pmscr`), `:388-421` (`to_pmsirr`), `:421-481` (filter builders),
`:893-922` (register writes).

### Feature probe (`PMSIDR_EL1`) and buffer ownership (`PMBIDR_EL1`)

The driver discovers SPE's shape from `PMSIDR_EL1` — the presence of event
filtering (`FE`), inverse (`FnE`), type (`FT`), latency (`FL`) filters,
`ArchInst`, `LDS`, `ERnd`, SIMD-FP filtering (`EFT`), the data-source filter
(`FDS`), the recommended minimum interval (256–4096), the max record size (≤2 KB),
and the 12/16-bit latency-counter width. If `PMBIDR_EL1.P` is set the profiling
buffer is _"owned by higher exception level"_ (a hypervisor or secure world) and
the driver bails out. `[source-verified]` [`arm_spe_pmu.c:1105-1223`][arm-spe-c],
esp. `:1122-1128` (`PMBIDR.P`, quoted below), `:1140-1169` (feature bits),
`:1171-1201` (min-interval lookup).

> _"profiling buffer owned by higher exception level"_ — [`arm_spe_pmu.c:1125-1126`][arm-spe-c]

### The physical-address paranoia gate

Physical-address and physical-timestamp collection is the ARM equivalent of the
information that KPTI/Meltdown hardening restricts, so `event_init` refuses it
unless kernel-level profiling is permitted: if the event sets `PMSCR.PA` or
`PMSCR.PCT` the init returns [`perf_allow_kernel()`][gating] — governed by
`perf_event_paranoid`. Context packets (`PMSCR.CX`, PID in `CONTEXTIDR`) are gated
the same way. `[source-verified]` [`arm_spe_pmu.c:873-877`][arm-spe-c]
(PA/PCT → `perf_allow_kernel()`), `:42-55` (`set_spe_event_has_cx`):

> `if (reg & (PMSCR_EL1_PA | PMSCR_EL1_PCT))` / `return perf_allow_kernel();` —
> [`arm_spe_pmu.c:874-875`][arm-spe-c]

The data-address → NUMA-node classification built on those physical addresses is
W2's territory — see [precise-sampling.md][precise-page].

---

## BRBE: the Branch Record Buffer Extension

BRBE (`FEAT_BRBE`, Armv9.2) is the ARM analog of Intel **LBR**: a hardware ring of
the last N taken control-flow transfers, frozen at sample time and surfaced
through perf's `branch_stack` — the input [AutoFDO][branch-records] and bottleneck
analyses consume.

- **Banked records.** Up to **64** records in two banks of 32
  (`BRBE_BANK_MAX_ENTRIES 32`), selected via `BRBFCR_EL1.BANK`. Each entry is
  `BRBSRC` (source PC) + `BRBTGT` (target PC) + `BRBINF` (valid, branch type,
  mispredict `MPRED`, cycle-count `CC`, EL, transaction/last-failed).
  `[source-verified]` [`arm_brbe.c:29-61`][arm-brbe-c] (bank layout), `:144-212`
  (field extractors), [`arm_brbe.h:14-24`][arm-brbe-h].
- **Filtering + enable.** `BRBFCR_EL1` filters branch classes
  (DIRECT/INDIRECT/RTN/INDCALL/DIRCALL/CONDDIR); `BRBCR_ELx` enables per-EL
  recording (`E0BRE` at EL0, `ExBRE` at EL1/EL2) plus `CC` (cycle count), `MPRED`
  (mispredict), `EXCEPTION`/`ERTN`, `FZP` (freeze on PMU overflow), and
  `TS=VIRTUAL`. `brbe_branch_attr_valid` rejects `exclude_host` and requires user
  or kernel recording. `[source-verified]` `arm_brbe.c:14-19, 371-425, 430-464`.
- **Driven by the core PMU, not a standalone device.** BRBE is probed inside
  `__armv8pmu_probe_pmu` (`brbe_probe`), its records are allocated per-CPU on the
  PMU, and it is requested through perf's `branch_stack` (`has_branch_stack` in
  `set_event_filter`) — not opened as its own event source. `[source-verified]`
  [`arm_pmuv3.c:1104-1109, 1351, 1354-1368`][arm-pmuv3-c]; [`arm_brbe.h:14-24`][arm-brbe-h].

---

## big.LITTLE / DynamIQ and uncore

This is where ARM's heterogeneity forces harness discipline. The
[uncore][uncore]/topology concern has two halves: heterogeneous _core_ PMUs and
genuinely shared _uncore_ PMUs.

### Per-cluster core PMUs

The `arm_pmu` framework tracks each PMU's `supported_cpus`, prints it via the
sysfs `cpumask` attribute, and constrains a `cpu==-1` event to migrate only
_within_ that mask. A big.LITTLE / DynamIQ system therefore surfaces **multiple
CPU PMUs** (e.g. `armv8_cortex_a53` beside `armv8_cortex_a72`), one per
microarchitecture cluster, and **a harness pinned to a core must open its events
against the PMU whose `cpumask` contains that core** — a `LITTLE`-core event
opened on the `big` PMU simply never counts. `[source-verified]`
[`arm_pmu.c:566-573`][arm-pmu-c] (`cpumask_show`), `:519-524` (migration
constraint), `:347,540-552` (per-CPU gating); affinity parsed from the
devicetree `interrupt-affinity` in [`arm_pmu_platform.c:59-121`][arm-pmu-platform].
Consumers name a specific PMU through `PERF_PMU_CAP_EXTENDED_HW_TYPE` (set
alongside `PERF_PMU_CAP_EXTENDED_REGS`; `PERF_PMU_CAP_NO_EXCLUDE` is added when a
PMU offers no EL-exclusion). `[source-verified]` [`arm_pmu.c:891-896, 935-940`][arm-pmu-c].

### Uncore PMUs: system/cluster-scoped, device-specific encodings

| Device                          | Scope                     | Counter block / encoding                                                                                                                                                                                             | Binding                                                            |
| ------------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| **CMN** (Coherent Mesh Network) | system-wide interconnect  | A tree of nodes; the DTC node holds `PMEVCNT`/`PMCCNTR`/`PMCR`/`PMOVSR`. `config` packs `TYPE[15:0]` \| `EVENTID[26:16]` \| `OCCUPID[30:27]` \| `BYNODEID[31]` \| `NODEID[47:32]` (distinct watchpoint sub-encoding) | single CPU via `cpumask`                                           |
| **DSU** (DynamIQ Shared Unit)   | one cluster's L3/SCU      | `CLUSTERPMCR` mirrors `PMCR` (N counters, ≤32 HW, cycle idx 31 = `DSU_PMU_EVT_CYCLES 0x11`); `event=config:0-31`                                                                                                     | two masks: `associated_cpus` (cluster) + `active_cpu` (the reader) |
| **DMC-620**                     | one DDR memory controller | 8-bit `eventid` + `clkdiv2`; several DMC instances share one IRQ via a driver list; each instance a separate PMU device                                                                                              | bound to a CPU                                                     |

`[source-verified]` [`arm-cmn.c:123-147,163-187,664-688`][arm-cmn]
(the DTC counter regs — _"The DTC node is where the magic happens"_,
[`arm-cmn.c:123`][arm-cmn]), [`arm_dsu_pmu.c:35-67,97-160,164`][arm-dsu],
[`arm_dmc620_pmu.c:70-91,110-128`][arm-dmc620].

**Harness consequence.** Every uncore PMU is per-_domain_, never per-thread: its
counts belong to a socket, cluster, or memory-controller aggregate and **cannot
be attributed to one benchmarked thread**; on a UMA / single-cluster part they
collapse to "whole chip". A harness that pins a thread and wants
thread-attributable numbers must confine itself to that core's cluster PMU and
treat uncore as ambient context — the ARM instance of the general
[uncore][uncore] rule. `[source-verified]` (consequence of the three devices
above).

---

## Code-space decode

There is essentially **no ARM-specific decode path**: SPE and PMUv3 sampling emit
the same `PERF_RECORD_MMAP2` + IP/branch/stack records as x86, and
[symbolization][symbolization] runs through `libelf`/`libdw`/`libdwfl` exactly as
[W1 describes][elfutils]. The one ARM wrinkle is that AAPCS64 keeps a frame chain
by default, so frame-pointer [unwinding][symbolization] is usually viable without
DWARF-CFI copies. Detail is deferred to [linux-perf-events.md][linux] and
[elfutils.md][elfutils]. `[source-verified]` (absence of ARM-specific decode in
`drivers/perf/`; the consumer side is `tools/perf/util/*`).

---

## Apple Silicon microarchitecture reference

> [!WARNING]
> **This section is a macOS-observed microarchitecture reference, not
> ARM-Linux.** Apple Silicon is an AArch64 core that is _not_ PMUv3; the numbers
> below are `[hw-verified: aarch64-darwin]` off `mac-bsn` (Apple **M4 Max**,
> `Mac16,5`, SoC `T6041`, `hw.cpufamily 0x17d5b93a`, macOS **26.3.1** build
> 25D771280a, SIP enabled, non-root) and `[source-verified]` against the Linux
> `apple_m1_cpu_pmu.c` driver. It is placed here — a sidebar — precisely because
> it does **not** generalize to ARM-Linux. For the full macOS acquisition story
> (`kpc`/`kperf`/kpep), see [macos.md][macos].

### The IMPDEF register model

Apple's PMU uses proprietary system registers, not PMUv3: `PMCR0-4`
(`S3_1_c15_c0..4_0`), `PMESR0/1` (`S3_1_c15_c5/6_0`) selecting events for counters
2–5 and 6–9 respectively, `PMSR` (`S3_1_c15_c13_0`), and `PMC0-9`
(`S3_2_c15_*`) — **10 counters**, #0/#1 fixed to cycles/instructions, an **8-bit
event field per counter**, and per-event _counter-affinity_ constraints (some
events only run on specific counters). Counter width is 48-bit on M1
(`ARMPMU_EVT_47BIT`) and 64-bit on M2+ (`ARMPMU_EVT_63BIT`). `[source-verified]`
[`apple_m1_cpu_pmu.c:22-168`][apple-m1-c] (event enum + affinity), `:227-270`
(`PMC0-9`), `:379-419` (`PMESR0/1`), `:546-566` (width);
[`apple_m1_pmu.h:10-50`][apple-m1-h]; `applecpu@0e6bc3f6 timer-hacks/PMCKext2.c:5-32`.

### Linux exposes only a 4-event PMUv3-compat shim

`m1_pmu_pmceid_map` maps exactly four PMUv3 names onto Apple numbers —
`INST_RETIRED→INST_ALL`, `CPU_CYCLES→CORE_ACTIVE_CYCLE`, `BR_RETIRED→INST_BRANCH`,
`BR_MIS_PRED_RETIRED→BRANCH_MISPRED_NONSPEC` — and every other event is a raw
Apple number via `event=config:0-7`. `[source-verified]`
[`apple_m1_cpu_pmu.c:170-187,215-220,568-586`][apple-m1-c]. The driver author
anticipated exactly the break that follows:

> _"If we eventually find out that the events are different across
> implementations, we'll have to introduce per cpu-type tables."_ —
> [`apple_m1_cpu_pmu.c:44-48`][apple-m1-c]

### The M4 encoding change (`[hw-verified: aarch64-darwin]`)

The real Apple event catalog is macOS's **kpep** database (`/usr/share/kpep/`,
world-readable `-rw-r--r-- root wheel`, so no privilege was needed — plists were
copied to `/tmp` and read with `python3`/`plutil`). This box's
`hw.cpufamily 0x17d5b93a` resolves through the symlink
`cpu_100000c_2_17d5b93a.plist → as4-1.plist` — the M4-Max P-core catalog.
Comparing kpep across generations shows Apple **changed its event numbering at
M4**: M1/A14/M3 (`as1`/`a14`/`as3`) use the Apple numbers the Linux driver
reverse-engineered; M4/M5 (`as4`/`as5`) **remap the common subset onto PMUv3
architected numbers** and add 12 `ARM_`-prefixed events. The break is
unambiguous and monotone across the common subset:

```text
event                       as1     a14     as3     as4-1   as5
INST_ALL                    0x8c    0x8c    0x8c    0x8     0x8
CORE_ACTIVE_CYCLE           0x2     0x2     0x2     0x11    0x11
INST_BRANCH                 0x8d    0x8d    0x8d    0x21    0x21
RETIRE_UOP                  0x1     0x1     0x1     0x3a    0x3a
BRANCH_MISPRED_NONSPEC      0xcb    0xcb    0xcb    0x22    0x22
L1D_CACHE_MISS_LD           0x5a3   0xa3    0x5a3   0x5a3   0x5a3
FETCH_RESTART               0x1de   0xde    0x1de   0x1de   0x1de
ARM_L1D_CACHE               -       -       -       0x4     0x4
ARM_BR_MIS_PRED             -       -       -       0x10    0x10
n_events                    66      60      66      103     103
n_ARM_prefixed              0       0       0       12      12
fixed_counters              3       3       3       3       3
config_counters             1020    1020    1020    1020    1020
```

(`as1`=M1, `a14`=A14, `as3`=M3, `as4-1`=M4 Max, `as5`=M5.) The full M4-Max
catalog is 103 events with a large SME block (`SME_ENGINE_SM_ENABLE`,
`INST_SME_ENGINE_ALU`, `LDST_SME_*`) reflecting M4's SME; a sample entry reads
`INST_ALL => {'counters_mask': 252, 'number': 8, ...}` (mask 252 = counters 2–7).
`[hw-verified: aarch64-darwin]` `mac-bsn:/usr/share/kpep/{as1,a14,as3,as4-1,as5}.plist`

- `[source-verified]` for the driver's TODO ([`apple_m1_cpu_pmu.c:44-48`][apple-m1-c]).
  The access _mechanism_ stays Apple-proprietary; only the low event _numbers_ now
  overlap PMUv3, and no M4 Linux driver exists yet.

### 8-bit under-exposure, and filtering Linux never programs

Two consequences follow. First, `M1_PMU_CFG_EVENT = GENMASK(7,0)` and
`event=config:0-7` cap the Linux driver at events `0x00–0xFF`, but kpep uses wider
selectors even on M1 (`L1D_CACHE_MISS_LD=0x5a3`, `FETCH_RESTART=0x1de`,
`L1I_CACHE_MISS_DEMAND=0x1db`) and up to `0x4006` on M4 — so Linux **structurally
under-exposes** Apple's event space, and the reverse-engineered narrow values
(`0xa3`, `0xde`) actually match Apple's _A14_ encoding, not M1's wide one.
`[source-verified]` + `[hw-verified: aarch64-darwin]`
[`apple_m1_cpu_pmu.c:24,215`][apple-m1-c]. Second, applecpu documents advanced
filtering the Linux driver never touches — `OPMAT0/1` + `OPMSK0/1` (opcode
match/mask) and `PMTRHLD2/4/6` (event thresholds) alongside `PMCR2-4`.
`[source-verified]` `applecpu@0e6bc3f6 timer-hacks/PMCKext2.c:13-32`. And kpep
reports **3** fixed counters on every Apple generation while the Linux driver
models only **2** (idx 0 cycles, idx 1 instructions) — an unresolved
discrepancy, carried as an open question in [the comparison][comparison-open].

---

## The seven concerns

A compact map from the survey's [seven concerns][concepts] to where each is
answered above (and which page owns the shared machinery).

| #   | Concern                      | ARM answer                                                                               | Section / owner                                                                                                                                              |
| --- | ---------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | Scalar counting              | PMUv3 counters (`PMCR.N`, `PMCEID` discovery, p5/p9 width); EL0 `rdpmc` analog           | [event model](#pmuv3-event-model) · [counters](#counters-and-width-evolution) · [self-monitoring](#self-monitoring-userspace-counter-reads-the-rdpmc-analog) |
| 2   | Overflow / IP sampling       | PMUv3 counter-overflow PPI; EL-exclusion filters; IP from `pt_regs`                      | [privilege & overflow](#counting-privilege-overflow-sampling-and-self-monitoring)                                                                            |
| 3   | Precise data-source sampling | **SPE** → AUX ring; PA/PCT `perf_allow_kernel()` gate                                    | [SPE](#spe-the-statistical-profiling-extension) · [precise-sampling.md][precise-page]                                                                        |
| 4   | Code-space decode            | Linux-generic (`libdwfl`); AAPCS64 keeps frame pointers                                  | [code-space decode](#code-space-decode) · [elfutils.md][elfutils]                                                                                            |
| 5   | Event space & tracing        | **BRBE** branch records → `branch_stack`; trace-buffer/-unit events at `0x400C+`         | [BRBE](#brbe-the-branch-record-buffer-extension)                                                                                                             |
| 6   | NUMA & topology              | per-cluster core PMUs + `cpumask`; CMN/DSU/DMC uncore, not thread-attributable           | [big.LITTLE & uncore](#big-little-dynamiq-and-uncore)                                                                                                        |
| 7   | Event naming & encoding      | 16-bit selector; three-way architectural/common/IMPDEF; `ARM-software/data` + Apple kpep | [event model](#the-three-way-taxonomy-a-refinement-of-common-vs-impdef) · [event-naming.md][event-naming]                                                    |

---

## Strengths

- **Architected discoverability.** `PMCEID*` + `PMCR.N` + `ID_AA64DFR1` let a
  harness _read_ what a core can count and how wide its counters are — no
  per-model table needed to know the shape of the machine.
- **Three precise/branch engines with clean perf mappings.** SPE ([AUX][aux]) and
  BRBE (`branch_stack`) map onto the same Linux ABIs as PEBS/IBS and LBR, so a
  cross-vendor consumer sees uniform records.
- **SPE is unusually rich** — per-op-class filtering, latency thresholds, event
  and inverse-event filters, data-source filters — all discoverable from
  `PMSIDR_EL1`.
- **Low-overhead self-monitoring** via `PMUSERENR_EL0` + `perf_user_access`, the
  same seqlock userpage ABI as x86 `rdpmc`.
- **Machine-readable vendor catalog** (`ARM-software/data`) with an explicit
  `architectural` flag, mirrored in-tree under `pmu-events/arch/arm64`.

## Weaknesses

- **No `aarch64-linux` hardware verification in this survey** — every ARM-Linux
  claim is source-reading only.
- **Heterogeneity is a harness burden.** big.LITTLE means multiple core PMUs;
  pinning to the wrong cluster's PMU silently counts nothing.
- **Uncore is not thread-attributable** — CMN/DSU/DMC counts are domain-scoped,
  useless for per-thread benchmarking.
- **Width and feature drift** (pre-p5 chaining vs p5 long vs p9 `PMICNTR`) force
  version probes; assuming any one generation is wrong on the others.
- **Apple Silicon is off-model**: not PMUv3, reverse-engineered, its encoding
  [changed at M4](#apple-silicon-microarchitecture-reference), Linux
  under-exposes it (8-bit field), and no M4 driver exists.
- **The authoritative spec (DDI 0487) is gated** — all encodings here are grounded
  in the in-kernel header and arm-data JSON, not the PDF (see [Sources](#sources)).

## Key design decisions and trade-offs

| Decision                                               | Rationale                                                                | Trade-off                                                                 |
| ------------------------------------------------------ | ------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| Architected events + `PMCEID` discovery                | Core answers "what can I count?" itself; no per-model event table        | Naming still needs per-uarch tables; discovery ≠ human names              |
| 16-bit selector, common/IMPDEF/extension layout        | Room for vendor + architected-extension (SPE/AMU/MTE) growth             | Portable names cover only the common `0x00–0x3F` subset                   |
| Counter width by revision (chain → p5 long → p9 icntr) | Grows precision without a hard ABI break                                 | A harness must probe `PMCR.LP`/`ID_AA64DFR1`; group budget varies by gen  |
| EL-based exclusion filters                             | Matches ARM's privilege model exactly (EL0/1/2/3, VHE-aware)             | `exclude_idle` unsupported; mapping is non-trivial under virtualization   |
| SPE as a separate AUX-streaming device                 | Hardware writes attributed packets → skid-free, data-source-rich samples | PA/PCT gated by `perf_allow_kernel()`; buffer may be owned by a higher EL |
| BRBE folded into the core PMU, not a standalone dev    | Branch capture is intrinsically per-CPU and PMU-synchronized             | Requested only via `branch_stack`; can't be opened independently          |
| Per-cluster core PMUs + uncore `cpumask` servicing     | Correctly models heterogeneous cores + shared domains                    | Pin-to-PMU discipline; uncore not thread-attributable                     |
| Apple: 4-event PMUv3 shim over an IMPDEF PMU           | Gets cycles/instructions/branches working with zero Apple tables         | Under-exposes the real event space; wrong across the M4 encoding change   |

---

## Sources

- [`drivers/perf/arm_pmuv3.c`][arm-pmuv3-c] — PMUv3 core driver: event maps,
  `PMCEID`/`PMCR.N` probe, EL-exclusion, chaining, `perf_user_access`, userpage.
- [`include/linux/perf/arm_pmuv3.h`][arm-pmuv3-h] · [`arm_pmu.h`][arm-pmu-h] ·
  [`arch/arm64/include/asm/arm_pmuv3.h`][arm64-pmuv3-h] — event enums, selector
  mask, fixed-counter indices, `PMICNTR` access.
- [`drivers/perf/arm_pmu.c`][arm-pmu-c] · [`arm_pmu_platform.c`][arm-pmu-platform]
  — the `arm_pmu` framework: `cpumask`, migration, PMU caps, DT affinity.
- [`drivers/perf/arm_spe_pmu.c`][arm-spe-c] — SPE: AUX buffer, `PMS*`/`PMB*`
  register map, `PMSIDR` probe, PA/PCT gate.
- [`drivers/perf/arm_brbe.c`][arm-brbe-c] · [`arm_brbe.h`][arm-brbe-h] — BRBE
  banked records, filters, `branch_stack`.
- [`drivers/perf/arm-cmn.c`][arm-cmn] · [`arm_dsu_pmu.c`][arm-dsu] ·
  [`arm_dmc620_pmu.c`][arm-dmc620] — uncore: mesh, cluster L3, DDR controller.
- [`drivers/perf/apple_m1_cpu_pmu.c`][apple-m1-c] ·
  [`arch/arm64/include/asm/apple_m1_pmu.h`][apple-m1-h] — Apple IMPDEF PMU + 4-event shim.
- [`tools/perf/pmu-events/arch/arm64/`][pmu-events-arm64] — in-tree per-uarch event tables (no `apple/`).
- [`ARM-software/data`][arm-data] `pmu/*.json` — vendor event catalog with the
  `architectural` flag (`neoverse-n1.json`, `c1-ultra.json`).
- [`dougallj/applecpu`][applecpu] `timer-hacks/PMCKext2.c` — reverse-engineered
  Apple PMU registers (opcode-match, thresholds).
- `mac-bsn:/usr/share/kpep/*.plist` — macOS's Apple event catalog (`as1`/`a14`/
  `as3`/`as4-1`/`as5`), the M4 encoding-change evidence. `[hw-verified: aarch64-darwin]`
- Arm ARM **DDI 0487** issue **K.a** — _"The Performance Monitors Extension"_ and
  _"The Statistical Profiling Extension"_ chapters. **GATED**: the [developer.arm.com
  PDF][ddi0487] is a JavaScript SPA behind an Akamai CDN that returns HTTP 403 to
  direct fetches, and the Internet Archive holds only ~7–8 KB HTML shells (no
  `application/pdf` binary on any Arm CDN host). All ARM encodings on this page are
  grounded in the in-kernel header (which mirrors that chapter) and the arm-data
  JSON, not the PDF. `[literature]`

> [!NOTE]
> **No runnable CI example ships with this page.** The survey's convention is a
> [CI-compiled probe][linux] per deep-dive, but there is no `aarch64-linux`
> hardware in CI to run a PMUv3 probe against, and CI cannot reach `mac-bsn`. The
> in-page **E2 kpep transcript** is the primary evidence for the Apple claims; the
> ARM-Linux claims are source-verified against `linux@e43ffb69e043`. A
> host-agnostic PMUv3 raw-`config` encoder would compile everywhere but could only
> print a `SKIP:` line off-ARM, so it was omitted as non-load-bearing.

<!-- References -->

[concepts]: ./concepts.md
[fixed-counters]: ./concepts.md#fixed-and-configurable-counters
[multiplexing]: ./concepts.md#multiplexing-and-scaling
[self-monitoring]: ./concepts.md#self-monitoring-and-user-space-counter-reads
[pmi]: ./concepts.md#pmi-performance-monitoring-interrupt
[overflow]: ./concepts.md#overflow-sampling
[aux]: ./concepts.md#aux-buffer
[branch-records]: ./concepts.md#branch-records
[symbolization]: ./concepts.md#symbolization
[uncore]: ./concepts.md#uncore-pmu
[arch-vs-impdef]: ./concepts.md#architected-vs-implementation-defined-events
[curation]: ./concepts.md#capability-curation
[gating]: ./concepts.md#privilege-gating
[linux]: ./linux-perf-events.md
[precise-page]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[event-naming]: ./event-naming.md
[macos]: ./macos.md
[comparison-open]: ./comparison.md#open-questions-gaps
[arm-pmuv3-c]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_pmuv3.c
[arm-pmuv3-h]: https://github.com/torvalds/linux/blob/e43ffb69e043/include/linux/perf/arm_pmuv3.h
[arm-pmu-h]: https://github.com/torvalds/linux/blob/e43ffb69e043/include/linux/perf/arm_pmu.h
[arm64-pmuv3-h]: https://github.com/torvalds/linux/blob/e43ffb69e043/arch/arm64/include/asm/arm_pmuv3.h
[arm-pmu-c]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_pmu.c
[arm-pmu-platform]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_pmu_platform.c
[arm-spe-c]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_spe_pmu.c
[arm-brbe-c]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_brbe.c
[arm-brbe-h]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_brbe.h
[arm-cmn]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm-cmn.c
[arm-dsu]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_dsu_pmu.c
[arm-dmc620]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/arm_dmc620_pmu.c
[apple-m1-c]: https://github.com/torvalds/linux/blob/e43ffb69e043/drivers/perf/apple_m1_cpu_pmu.c
[apple-m1-h]: https://github.com/torvalds/linux/blob/e43ffb69e043/arch/arm64/include/asm/apple_m1_pmu.h
[pmu-events-arm64]: https://github.com/torvalds/linux/tree/e43ffb69e043/tools/perf/pmu-events/arch/arm64
[arm-data]: https://github.com/ARM-software/data
[applecpu]: https://github.com/dougallj/applecpu
[ddi0487]: https://web.archive.org/web/20260309021822/https://developer.arm.com/documentation/ddi0487/ak
