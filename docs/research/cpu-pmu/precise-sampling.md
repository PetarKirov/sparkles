# Precise sampling & NUMA data-source attribution

Precise, low-skid sampling that attributes each memory access to a PC, a data
address, a cache/DRAM source, and a latency — and the address→NUMA-node oracle
that turns a coarse "remote" bit into a concrete node.

| Dimension               | AMD IBS                                   | Intel PEBS                                        | ARM SPE                                     |
| ----------------------- | ----------------------------------------- | ------------------------------------------------- | ------------------------------------------- |
| Mechanism               | Micro-op tagging → per-op MSR reads       | Counter-overflow assist → DS-area memory buffer   | Statistical profiling → AUX-buffer packets  |
| Verification bed        | `[hw-verified: x86_64-linux]` (Zen 4)     | `[source-verified]` / `[literature]`              | `[source-verified]` (no `aarch64` hardware) |
| Precise levels          | `precise_ip` 1–2 (skid 0 by construction) | `precise_ip` 1–3 (level 3 = zero-skid PDIR/PDist) | AUX stream (no `precise_ip` scale)          |
| Data-source granularity | 3-bit legacy / 5-bit Zen 4 `DataSrc`      | per-µarch `pebs_data_source[]` tables             | MIDR-dispatched, implementation-defined     |
| NUMA signal             | coarse "remote" bit → `HOPS(1)`           | coarse (per-table)                                | implementation-defined                      |
| Linux ABI target        | `perf_mem_data_src` union                 | `perf_mem_data_src` union                         | `perf_mem_data_src` union                   |

> [!NOTE]
> **Hardware bed.** Every `[hw-verified: x86_64-linux]` claim on this page was
> checked on Linux **6.18.26**, an **AMD Ryzen 9 7940HX** (Zen 4, family `0x19`
> model `0x61`), `perf_event_paranoid = -1`, **single NUMA node**, LDC 1.41.
> Kernel source (`path:line`) is read at `linux@e43ffb69e043` (v7.1-rc6). This is
> an **AMD** part, so the precise engine here is **IBS**, not PEBS — PEBS claims
> are `[source-verified]` / `[literature]` only, and ARM SPE has no local
> hardware. See [The seven concerns](#the-seven-concerns) for scope.

---

## Overview

A profile is only ever a statistical estimate of the true event distribution,
and it is unbiased only if the recorded [instruction pointer][sampling] is the
one that actually caused the event. On an out-of-order core it usually is not:
the [PMI][pmi] fires several to hundreds of instructions past the culprit, and
that distance — [**skid**][skid] — smears samples onto whatever happened to
retire when the interrupt was taken. **Precise sampling** removes skid by making
the _hardware_ capture the sample at retirement instead of leaving it to the
interrupt handler.

Skid is only half the problem. A memory-analysis profile needs more than _where_
the access came from in the code — it needs _which level of the memory hierarchy
served it_ (L1/L2/L3/local DRAM/remote node), how long it took, and the data
address touched. None of that survives to the interrupt handler: by the time the
PMI is taken, the load's µop is long retired and its cache-lookup outcome is
gone. Only the hardware, at the moment of retirement, still holds it. This is
[data-source attribution][data-source], and it is the reason precise sampling
exists at all. From the AMD64 Architecture Programmer's Manual, Vol. 2 (§13.3),
describing what an IBS-tagged op reports `[literature]`:

> "For a load or store op: – Whether the load or store missed in the data
> cache. – Whether the load or store address hit or missed in the TLBs. – The
> linear and physical address of the data operand associated with the load or
> store operation. – Source information for cache, DRAM, MMIO, or I/O accesses."

Three vendors implement this three different ways — AMD **IBS**, Intel **PEBS**,
ARM **SPE** — but Linux funnels all three into a single ABI so a consumer decodes
the payload once. This page is that story: the shared ABI, the three engines,
and the address→node oracle that upgrades the ABI's deliberately coarse
locality bit into a real NUMA node.

---

## How it works: three engines, one ABI

The vendor-neutral seam is the `perf_mem_data_src` union plus four sample fields
requested through `perf_event_attr.sample_type`:

- `PERF_SAMPLE_ADDR` — the data **virtual** address of the sampled access.
- `PERF_SAMPLE_PHYS_ADDR` — its **physical** address ([privilege][privilege]-gated).
- `PERF_SAMPLE_DATA_SRC` — the `perf_mem_data_src` union (level/op/snoop/TLB/hops).
- `PERF_SAMPLE_WEIGHT` — the access latency (cycles).

The union is one little-endian `u64` of contiguous bitfields `[source-verified]`
(`include/uapi/linux/perf_event.h:1319-1459`):

```c
union perf_mem_data_src {
    __u64 val;
    struct {
        __u64 mem_op       : 5,   /* type of opcode: load/store/prefetch/exec */
              mem_lvl      : 14,   /* legacy memory hierarchy level  */
              mem_snoop     : 5,   /* snoop mode                     */
              mem_lock      : 2,   /* lock instruction               */
              mem_dtlb      : 7,   /* dTLB access                    */
              mem_lvl_num   : 4,   /* memory hierarchy level number  */
              mem_remote    : 1,   /* remote                         */
              mem_snoopx    : 2,   /* snoop mode, ext                */
              mem_blk       : 3,   /* access blocked                 */
              mem_hops      : 3,   /* hop level                      */
              mem_region    : 5,   /* access memory region          */
              mem_rsvd     : 13;
    };
};
```

The composite fields are the modern truth: `mem_lvl_num` names the level
(`PERF_MEM_LVLNUM_L1..L4`, `ANY_CACHE = 0xb`, `LFB = 0xc`, `RAM = 0xd`,
`PMEM = 0xe`, `CXL = 9`, `IO = 0xa`, `NA = 0xf`), `mem_remote` flags off-node,
and `mem_hops` (`PERF_MEM_HOPS_0..3`) counts the distance. The wide `mem_lvl`
field it replaces is on the way out `[source-verified]`
(`include/uapi/linux/perf_event.h:1368-1370`):

> "The PERF*MEM_LVL*\* namespace is being deprecated to some extent in favour of
> newer composite PERF*MEM*{LVLNUM*,REMOTE*,SNOOPX\_} fields."

Because IBS, PEBS, and SPE all fill this same union `[source-verified]`
(`include/uapi/linux/perf_event.h:1319-1459`), a backend writes _one_ decoder —
the `memLvlStr`/`snoopStr`/`tlbStr` functions in the [probe][probe] are exactly
that decoder — and it serves every engine. The engines differ only in _how_ the
bits get filled, which is the next three sections.

---

## Data-source & data-address sampling: AMD IBS

`[hw-verified: x86_64-linux]` — this is the engine that runs on the test box.

**No PEBS; IBS is the only precise engine.** On this AMD part the core `cpu` PMU
reports `caps/max_precise = 0`, i.e. it has _no_ precise mode at all; the two IBS
PMUs (`ibs_op` type `11`, `ibs_fetch` type `10`) carry the whole burden, and
`ibs_op/caps/zen4_ibs_extensions = 1` `[hw-verified: x86_64-linux]` (sysfs, E1).
So the "fall back to the `cpu` PMU with `precise_ip > 0`" recipe from the Intel
world **does not exist on AMD** — the [probe][probe] keeps a structurally-present
`cpu`/`precise_ip` branch but labels it Intel-only and it is unreachable here.

**Micro-op tagging, not counter overflow.** IBS increments an internal 27-bit
counter either per core clock (`IbsOpCntCtl = 0`) or per dispatched op
(`IbsOpCntCtl = 1`); when it reaches `IbsOpMaxCnt` the hardware tags one random
retired micro-op and records its retirement facts `[literature]` (AMD64 APM Vol 2
§13.3). This is _instruction-based_ and independent of any PMC event — the
fundamental structural difference from PEBS, which extends a _counter_ overflow.

**Skid 0, and the `precise_ip` forward.** A core-PMU `precise_ip` request is
transparently rerouted to `ibs_op` by `forward_event_to_ibs`, which returns
`-EOPNOTSUPP` for `!precise_ip || precise_ip > 2` `[source-verified]`
(`arch/x86/events/amd/ibs.c:240-258`). The in-tree comment states the guarantee:

> "The rip of IBS samples has skid 0. Thus, IBS supports precise levels 1 and 2
> and the PERF_EFLAGS_EXACT is set."

**Filling the union.** IBS populates `perf_mem_data_src` from `IBS_OP_DATA2.DataSrc`
plus `IBS_OP_DATA3` bits: `mem_op` (from the `ld_op`/`st_op` flags), `mem_lvl` +
`mem_lvl_num` (via lookup tables), `mem_snoop` (`HITM` for cache-to-cache),
`mem_dtlb` (L1/L2 hit/miss) and `mem_lock`, dispatched through
`perf_ibs_get_data_src` `[source-verified]` (`arch/x86/events/amd/ibs.c:1016-1253`,
dispatcher at `:1242`). **Zen 4 widens `DataSrc` to 5 bits**
(`data_src_hi<<3 | data_src_lo`), selecting `g_zen4_data_src[32]` instead of the
legacy `g_data_src[8]` — so it distinguishes near-CCX from far-CCX cache, plus
PMEM, CXL / extension memory, and peer-agent memory. It is gated on
`IBS_CAPS_ZEN4` (`1U<<11`), which this host advertises
`[source-verified + hw-verified: x86_64-linux]`
(`arch/x86/events/amd/ibs.c:1033-1069`; enum `arch/x86/include/asm/amd/ibs.h:12-26`;
`arch/x86/include/asm/perf_event.h:644`).

**Latency and addresses are valid-bit gated.** `WEIGHT` carries the DC-miss
latency `dc_miss_lat`, but only for a load that _missed_ the data cache
(`dc_miss && mem_op == LOAD`); `ADDR` comes from `IBSDCLINAD` under
`dc_lin_addr_valid`, and `PHYS_ADDR` from `IBSDCPHYSAD` under `dc_phy_addr_valid`
`[source-verified + hw-verified: x86_64-linux]`
(`arch/x86/events/amd/ibs.c:1296-1317`). A sample with a cache _hit_ therefore
has no meaningful weight — which is why the probe leads with cache-miss samples.

**A hardware load-latency filter.** Zen 4 exposes `IBS_CAPS_OPLDLAT`: `config1`
sets a latency threshold in `[128, 2048]` cycles and the IRQ handler drops ops
below it — the AMD analog of Intel PEBS `ldlat` `[source-verified]`
(`arch/x86/events/amd/ibs.c:281-287, 407-419, 1464-1478`).

### The `swfilt` / `exclude_*` gotcha

> [!WARNING]
> A backend that carries the usual perf-attr habits into IBS will fail to open a
> memory-sampling event. This Zen 4 lacks `IBS_CAPS_BIT63_FILTER`, so a bare
> `exclude_kernel`, `exclude_user`, or `exclude_hv` returns `-EINVAL`. Kernel/user
> filtering must instead engage the **software filter** — the `swfilt` bit
> (`config2:0`, `IBS_SW_FILTER_MASK`) — and `exclude_hv` is _never_ accepted by
> IBS `[hw-verified: x86_64-linux + source-verified]`
> (`arch/x86/events/amd/ibs.c:346-370`).

The errno matrix from E2 (opening `ibs_op` with
`sample_type = IP|ADDR|DATA_SRC|WEIGHT|PHYS_ADDR`, varying the filters):

```text
full, exclude_kernel=1, exclude_hv=1                : -22 (EINVAL)
full, exclude_kernel=1, exclude_hv=0                : -22 (EINVAL)
full, exclude_kernel=0, exclude_hv=0                :   3 (ok)
full, exclude_kernel=0, exclude_hv=1                : -22 (EINVAL)
full, exclude_kernel=1, config2=1 (swfilt)          :   3 (ok)   ← the recipe
```

`PHYS_ADDR` opened cleanly at `perf_event_paranoid = -1`; on a stricter host it
is the first field to drop (see [privilege gating][privilege]). Relatedly,
`perf mem` on AMD is a single `mem-ldst` event on `ibs_op`, not the Intel split
of `mem-loads,ldlat=%u` + `mem-stores` `[source-verified + hw-verified: x86_64-linux]`
(`tools/perf/arch/x86/util/mem-events.c:24-34`; `perf mem report` shows
`event 'ibs_op//'`).

### End to end

The [probe][probe] `./examples/mem-latency-numa.d` pointer-chases a 64 MiB buffer
(wider than the per-CCX L3, so dependent loads miss to DRAM) and decodes every
IBS sample. Its output on the test box:

```text
== precise memory-access sampling: AMD IBS (ibs_op, zen4_ibs_extensions) ==
  PMU type=11  period=20000  sample_type=IP|ADDR|DATA_SRC|WEIGHT|PHYS_ADDR
  workload=64 MiB  home node(get_mempolicy)=0  NUMA nodes online=1
  sampled data accesses (8 of 3390; cache-miss samples first):
    ip                 addr               op     level      snoop  tlb      lat  node[gmp/mvp]
    0x..3c4f 0x000078b2b8e08c10 LOAD   RAM hit    N/A    L2 miss   415  0/0
    0x..3c4f 0x000078b2b9c32980 LOAD   L2 hit     N/A    L2 hit     11  0/0
    0x..3c4f 0x000078b2b8739b38 LOAD   L3 hit     HitM   L2 miss    45  0/0
    ...
  data-source levels across 3390 resolved samples: RAM hit 143  L1 hit 3204  L2 hit 17  L3 hit 26
  node classification: 3389 on home node 0 (get_mempolicy == move_pages), 0 elsewhere; gmp errors=1, mvp errors=1
  DC-miss latency (WEIGHT) on 180 load samples: min=11 median=412 max=1845 cycles
```

Every pointer-chase load attributes to one zero-skid IP (`…3c4f`, the
`i = words[i]` load) — demonstrating IBS's skid-0 IP, the full data-source decode,
and the valid-bit-gated latency in one run. The decode vocabulary
(`L1 hit`, `L2 hit`, `N/A`, TLB `L1 hit`) was byte-checked against
`perf mem report` (E4), whose decoder is `tools/perf/util/mem-events.c:370-559`
`[source-verified + hw-verified: x86_64-linux]`. The probe exits `0` and degrades
to a `SKIP:` line on any host without IBS, a refused `perf_event_open`, or no
data-address samples.

---

## Intel PEBS: the counter-overflow analog

`[source-verified]` / `[literature]` — **not testable on this AMD host** (no PEBS;
`cpu/caps/max_precise = 0`).

Where IBS tags a random op, **Precise Event-Based Sampling** arms a hardware
assist off a _counter overflow_: the tagged event's PMC crosses zero, the assist
writes a record into the Debug-Store (DS) area of memory, and the kernel converts
that record after the fact. Its precise levels are 1/2/3, and **level 3 is the
zero-skid tier** (PDIR / PDist), which requires a specific counter — the kernel
special-cases `precise_ip == 3` throughout counter scheduling `[source-verified]`
(`arch/x86/events/intel/core.c`, `precise_ip == 3` at
`:5239, 5260, 5278, 5298, 5358, 5398, 5511`).

Its data source is read from the DS-area record's `dse` status field and mapped
through **per-microarchitecture** `pebs_data_source[]` tables
(`load_latency_data` / `__grt_latency_data`); latency is `pebs->lat` and the data
address `pebs->dla` `[source-verified]`
(`arch/x86/events/intel/ds.c:125-260, 455-708, 2131-2202`). The truth thus lives
in a hardware-written memory buffer decoded by a µarch-specific table — a
different shape of ground truth from IBS's per-op MSR reads — yet it lands in the
_same_ `perf_mem_data_src` union `[source-verified]`
(`include/uapi/linux/perf_event.h:1319-1459`), which is why one decoder covers both.

| Axis                | AMD IBS                                                                     | Intel PEBS                                                           |
| ------------------- | --------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| Tagging model       | random retired µop, instruction-based (independent of any PMC)              | counter-overflow assist — extends a specific PMC event               |
| Precise levels      | `precise_ip` 1–2, skid 0 by construction                                    | `precise_ip` 1–3; level 3 (PDIR/PDist) is zero-skid, needs a counter |
| Data-source truth   | per-op `IBS_OP_DATA2/3` MSR reads → `g_data_src[8]` / `g_zen4_data_src[32]` | DS-area record `dse` field → per-µarch `pebs_data_source[]`          |
| Latency (`WEIGHT`)  | `dc_miss_lat`, load-miss only                                               | `pebs->lat`                                                          |
| Load-latency filter | `config1` threshold `[128, 2048]` cyc (`IBS_CAPS_OPLDLAT`)                  | `mem-loads,ldlat=N`                                                  |
| `perf mem` event    | single `mem-ldst` on `ibs_op`                                               | `mem-loads,ldlat=%u` + `mem-stores` split                            |

---

## From data address to NUMA node

`[hw-verified: x86_64-linux]` for the API round-trip; the [NUMA concern][index]'s
_attribution edge_.

The `perf_mem_data_src` locality signal is deliberately **coarse**. When IBS sees
a remote-node access (`op_data2.rmt_node`) the kernel unconditionally ORs in
`REM | HOPS(1)` (or `REM_RAM1` for DRAM) — never a node number `[source-verified]`
(`arch/x86/events/amd/ibs.c:1113-1119, 1128-1134`), with the in-tree rationale:

> "HOPS_1 because IBS doesn't provide remote socket detail"

So `DATA_SRC` alone answers _local vs remote_, not _which node_. (PEBS is
similarly coarse; SPE's is per-implementation.) Node-precise attribution needs a
second, complementary oracle: resolve the sampled **data address** to a node
directly. Linux offers two [page→node oracles][numa-oracles], both raw syscalls
(**not** glibc functions) `[source-verified + hw-verified: x86_64-linux]`
(`arch/x86/entry/syscalls/syscall_64.tbl:237-239, 279`;
`include/uapi/asm-generic/unistd.h:601-608`; `numaif.h:11-46`):

- **`get_mempolicy(mode, NULL, 0, addr, MPOL_F_NODE | MPOL_F_ADDR)`** — writes the
  node of the page containing `addr` into `mode` (syscall `239` on x86_64,
  `236` on the asm-generic table).
- **`move_pages(0, n, pages, NULL, status, 0)`** in _query_ mode (`nodes == NULL`)
  — fills `status[i]` with each page's node, or a negative `-errno` (syscall `279`
  on x86_64, `239` asm-generic).

The [probe][probe] queries both for every resolved data address and cross-checks
them against the buffer's home node; on the test box both return `0` for every
sample, and the two oracles agree.

> [!WARNING]
> **Single-node host — round-trip, not classification.** This box has one NUMA
> node (`/sys/devices/system/node` holds only `node0`), so every sampled address
> resolves to node 0 and the two oracles _trivially_ agree. What is demonstrated
> is the address→node API round-trip and single-node consistency;
> cross-node _classification_ is **not** shown — that needs a multi-socket box
> `[hw-verified: x86_64-linux]`.

**No `numa.pc`, so no linking.** numactl ships no `numa.pc`, so `pkg-config numa`
fails; the library is a plain `libnuma.so` (`-lnuma`), and its own
`get_mempolicy`/`move_pages` are themselves thin syscall wrappers
`[hw-verified: x86_64-linux]` (`pkg-config --exists numa` → "No package 'numa'
found"; numactl `93c1fe5`, v2.0.19). Linking `libnuma` would turn a host that
lacks it into a _build_-time failure, so the probe calls the two syscalls
directly — identical kernel path, zero external C dependency, green on any host.
For the node/distance-enumeration side of the same concern, see [libnuma][libnuma].

---

## ARM SPE: the AUX-buffer analog

`[source-verified]` — no `aarch64-linux` hardware on hand; source + literature only.

The **Statistical Profiling Extension** is the ARM member of the family, but it
does not emit ordinary perf sample records. It is an [AUX-buffer][aux] PMU:
hardware streams profiling packets into a second, high-bandwidth mmap region that
userspace decodes after the fact. The driver exposes format attrs `pa_enable`
(`PMSCR_EL1.PA`, physical-address collection), `load_filter` / `store_filter`
(`PMSFCR_EL1`), `min_latency` (`PMSLATFR_EL1.MINLAT`, 12-bit), and an event
filter (`PMSEVFR_EL1`) `[source-verified]`
(`drivers/perf/arm_spe_pmu.c:81-91, 203-324`). Each decoded record carries
`virt_addr` + `phys_addr` + `context_id` + `latency` for the sampled op
`[source-verified]` (`tools/perf/util/arm-spe-decoder/arm-spe-decoder.h:112-125`)
— the same PC-plus-data-address-plus-latency payload IBS and PEBS deliver, only
streamed through AUX rather than a single sample record.

The split worth carrying into the ARM survey: SPE's _packet framing_ is
architected, but its **data source is implementation-defined**. Userspace decodes
`record->source` by **MIDR dispatch** — a Neoverse "common" table plus separate
AmpereOne and HiSilicon HIP tables — into the same `perf_mem_data_src` levels
`[source-verified]` (`tools/perf/util/arm-spe.c:585-705`,
`arm_spe__synth_data_source_common` at `:651`; enums `arm-spe-decoder.h:77-108`).
Even the "common" table is a guess pinned to today's parts:

> "Even though four levels of cache hierarchy are possible, no known production
> Neoverse systems currently include more than three levels so for the time being
> we assume three exist."

Full treatment of ARM PMUv3 + SPE, including the architected-vs-implementation
event split, is in [arm][arm].

---

## The seven concerns

This page is the survey's precise-sampling spoke. Its place in the seven-concern
spine:

| #   | Concern                                     | Coverage here                                                                                                  |
| --- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1   | Scalar [counting][counting]                 | Out of scope → [linux-perf-events][linux]                                                                      |
| 2   | Overflow / IP [sampling][overflow]          | Touched: precise sampling _is_ the low-skid variant of IP sampling (`precise_ip`) — see [Overview](#overview)  |
| 3   | Precise data-source & data-address sampling | **This page** — the [ABI](#how-it-works-three-engines-one-abi) + all three engine sections                     |
| 4   | Symbolization                               | Out of scope → [elfutils][elfutils] (and W1's `sampling-symbolize.d`)                                          |
| 5   | Tracing / event-space                       | Out of scope → [linux-perf-events][linux]                                                                      |
| 6   | NUMA topology & placement                   | Its _attribution edge_: [From data address to NUMA node](#from-data-address-to-numa-node) → [libnuma][libnuma] |
| 7   | Event [naming & encoding][naming-concept]   | Out of scope → [event-naming][naming]                                                                          |

---

## Strengths

- **Zero (or near-zero) skid on the IP** — IBS is skid 0 by construction; PEBS
  reaches zero-skid at `precise_ip == 3`. The sampled PC is the culprit, so memory
  hot spots pin to the exact load.
- **Full data-source truth per sample** — level, snoop, TLB, op type, data VA/PA,
  and latency, captured by hardware at retirement where the interrupt handler
  could never reconstruct it.
- **One ABI across three vendors** — `perf_mem_data_src` + the four sample fields
  are engine-agnostic, so a backend writes a single decoder.
- **Composable with the address→node oracle** — the union's coarse locality bit
  plus `get_mempolicy`/`move_pages` yields node-precise attribution with no extra
  kernel privilege beyond what the physical address already needs.
- **Load-latency pre-filtering in hardware** (IBS `IBS_CAPS_OPLDLAT`, PEBS
  `ldlat`) keeps only the expensive accesses, cutting sample volume at the source.

## Weaknesses

- **Vendor-specific and non-portable capture** — IBS ≠ PEBS ≠ SPE in tagging
  model, precise levels, and data-source encoding; only the _output_ union is
  shared. AMD has _no_ PEBS-style `cpu`/`precise_ip` fallback at all.
- **The locality bit is deliberately coarse** — "remote" is `HOPS(1)`, never a
  node; node attribution _requires_ the second address→node oracle.
- **Attribute-shape footguns** — IBS rejects a bare `exclude_kernel`/`exclude_hv`
  with `-EINVAL` and needs the `swfilt` bit; the usual perf habits fail silently.
- **Physical addresses and kernel visibility are [privilege][privilege]-gated** —
  `PHYS_ADDR` (and SPE physical-address collection) drop on a hardened host.
- **SPE's data source is implementation-defined** — MIDR-dispatched userspace
  tables that lag new silicon, unlike its architected packet framing.
- **Path context is a separate mechanism** — the _leading_ control flow lives in
  [branch records][branch-records] (LBR/BRBE), not in the data-source sample.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                              | Trade-off                                                                                |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Capture in hardware at retirement (vs. in the PMI handler)      | Only the hardware still holds the cache-lookup outcome, data address, and true PC      | Vendor-specific silicon; each engine (IBS/PEBS/SPE) has its own capture path             |
| Normalize every engine to `perf_mem_data_src` + 4 sample fields | One decoder in the consumer; engine choice is a runtime capability probe               | The union is a lowest-common-denominator — it flattens vendor-specific detail            |
| Keep the locality signal coarse ("remote" bit, not a node)      | The sampling hardware genuinely lacks remote-socket detail (`ibs.c:1113`)              | Node attribution needs a second, complementary address→node oracle round-trip            |
| Resolve data addresses via raw `get_mempolicy`/`move_pages`     | No `numa.pc`; libnuma is a thin syscall wrapper — direct syscalls stay dependency-free | Two syscalls per sampled address; single-node hosts can only demonstrate the round-trip  |
| IBS micro-op tagging (vs. PEBS counter-overflow assist)         | Instruction-based, event-independent sampling with skid 0 at levels 1–2                | Only levels 1–2 (no zero-skid level 3); needs the `swfilt` bit for kernel/user filtering |
| Stream SPE through an AUX buffer (vs. per-sample records)       | High-bandwidth hardware profiling without a PMI per sample                             | A separate decode pipeline; data-source is implementation-defined, MIDR-dispatched       |

---

## Sources

- **Linux kernel** at `e43ffb69e043` (v7.1-rc6) — [tree][linux-src]:
  - `include/uapi/linux/perf_event.h:1319-1459` — the `perf_mem_data_src` union
    and `PERF_MEM_*` constants (the vendor-neutral ABI).
  - `arch/x86/events/amd/ibs.c` — IBS→perf conversion, data-source tables,
    `forward_event_to_ibs`, `swfilt`, `ldlat` (`:240-258, 281-287, 346-370,
1016-1253, 1296-1317, 1464-1478`).
  - `arch/x86/include/asm/amd/ibs.h:12-26`, `arch/x86/include/asm/perf_event.h:644`
    — Zen 4 `DataSrc` enum and `IBS_CAPS_ZEN4`.
  - `arch/x86/events/intel/ds.c`, `arch/x86/events/intel/core.c` — PEBS DS-area
    decode and `precise_ip == 3` scheduling.
  - `tools/perf/util/mem-events.c:370-559`,
    `tools/perf/arch/x86/util/mem-events.c:24-34` — perf's decode strings and the
    AMD `mem-ldst` event.
  - `drivers/perf/arm_spe_pmu.c`, `tools/perf/util/arm-spe.c`,
    `tools/perf/util/arm-spe-decoder/arm-spe-decoder.h` — SPE format attrs, record
    layout, MIDR-dispatched data-source synthesis.
  - `arch/x86/entry/syscalls/syscall_64.tbl`, `include/uapi/asm-generic/unistd.h`
    — `get_mempolicy` / `move_pages` syscall numbers.
- **AMD64 Architecture Programmer's Manual, Vol. 2: System Programming**
  (publication `24593`, §13.3 Instruction-Based Sampling) — the architectural
  framing of what an IBS-tagged op reports. The _extended_ Zen 4 `DataSrc`
  encodings are documented in the family **PPR 55898** (cited by
  `arch/x86/include/asm/amd/ibs.h:5-8`).
- **Intel SDM, Vol. 3** (PEBS, chapters 20–21) — cited by section; the PDF is
  gated and not reproduced here.
- **numactl** `93c1fe5` (v2.0.19) — `numa.h` / `numaif.h`
  (`get_mempolicy`/`move_pages`/`MPOL_F_*`).
- **Runnable probe:** [`./examples/mem-latency-numa.d`][probe] — the end-to-end
  IBS + NUMA demonstration whose output is quoted above (CI-compiled and run).
- **Concepts:** [precise sampling & skid][skid], [data-source attribution][data-source],
  [AUX buffer][aux], [NUMA page→node oracles][numa-oracles].
- **Related deep-dives:** [linux-perf-events][linux] · [libnuma][libnuma] ·
  [arm][arm] · [elfutils][elfutils] · [event-naming][naming].

<!-- References -->

[index]: ./
[sampling]: ./concepts.md#sampling
[counting]: ./concepts.md#counting
[skid]: ./concepts.md#precise-sampling-and-skid
[data-source]: ./concepts.md#data-source-attribution
[overflow]: ./concepts.md#overflow-sampling
[pmi]: ./concepts.md#pmi-performance-monitoring-interrupt
[aux]: ./concepts.md#aux-buffer
[numa-oracles]: ./concepts.md#numa-topology-and-page-node-oracles
[privilege]: ./concepts.md#privilege-gating
[branch-records]: ./concepts.md#branch-records
[naming-concept]: ./concepts.md#event-naming-and-encoding
[linux]: ./linux-perf-events.md
[libnuma]: ./libnuma.md
[arm]: ./arm.md
[elfutils]: ./elfutils.md
[naming]: ./event-naming.md
[probe]: ./examples/mem-latency-numa.d
[linux-src]: https://github.com/torvalds/linux/tree/e43ffb69e043
