# RISC-V PMU

RISC-V PMU: a firmware-mediated counter stack whose sampling and branch-record
capabilities are spec-ratified but only partly landed in Linux.

| Field                    | Value                                                                                        |
| ------------------------ | -------------------------------------------------------------------------------------------- |
| Privilege layering       | kernel (S-mode) → SBI ecall → M-mode firmware                                                |
| Counting                 | `Zicntr` / `Zihpm` counters + **SBI PMU** extension (EID `0x504D55`)                         |
| Sampling                 | **Sscofpmf** — LCOFI local interrupt, `sip`/`sie` **bit 13**                                 |
| Guest (VS-mode) sampling | + **Ssaia/Smaia** (AIA) — KVM injects via `HVIEN` bit 13                                     |
| Branch records           | **Smctr/Ssctr** (CTR v1.0, ratified **2024-11-22**) — **no Linux consumer** at v7.1-rc6      |
| Precise data sampling    | **none** — no PEBS/SPE analog in ratified RISC-V                                             |
| Firmware                 | [OpenSBI][opensbi] (reference SBI implementation)                                            |
| Kernel drivers           | `riscv_pmu.c` · `riscv_pmu_sbi.c` · `riscv_pmu_legacy.c` @ Linux **v7.1-rc6**                |
| Verification scope       | `[source-verified]` + `[literature]` **only** — no RISC-V silicon, no `[hw-verified]` claims |

> [!IMPORTANT]
> **Scope: spec and source, not silicon.** Every claim on this page is grounded in
> ratified RISC-V specification text or in Linux/OpenSBI source at a pinned SHA — no
> RISC-V hardware was measured, so there are no `[hw-verified]` figures. Unlike the
> other deep-dives in this tree, this page ships **no runnable `examples/` probe**:
> nothing an x86 CI runner could execute would exercise the SBI/Sscofpmf path
> meaningfully, so the grounding is primary-source line citations instead of a
> compiled program. The survey's internal QA ledger records the two prompt
> hypotheses this page **refutes** (see [Concern 5](#concern-5-event-space-branch-records-ctr)).

---

## Overview

### What it solves

RISC-V exposes performance counters through a **three-level privilege indirection**
that is unlike x86 (`rdpmc` + `wrmsr` from ring 0) or ARM (`PMEVTYPER<n>_EL0`
written directly by EL1). On RISC-V, supervisor mode — where Linux runs — can
_read_ the counters but **cannot select, start, or stop them**. Only M-mode may
write the `mcountinhibit` and `mhpmeventX` control CSRs. The kernel therefore
drives counting by asking firmware to do it, over the **SBI PMU extension**, and
[OpenSBI][opensbi] performs the actual register writes.

| Level                         | Runs                          | Reads counters                               | Selects / starts / stops events                             |
| ----------------------------- | ----------------------------- | -------------------------------------------- | ----------------------------------------------------------- |
| **U / S-mode (unprivileged)** | user code, Linux kernel       | yes — `cycle`, `instret`, `hpmcounterX` CSRs | **no**                                                      |
| **S-mode via SBI**            | `riscv_pmu_sbi.c` perf driver | HW counters directly; FW counters via SBI    | requests through an SBI `ecall` (`config_match`/start/stop) |
| **M-mode firmware (OpenSBI)** | the SBI implementation        | —                                            | **yes** — writes `mhpmeventX`, `mcountinhibit`              |

The counting CSRs come from the base ISA's `Zicntr` (`cycle`, `time`, `instret`)
and `Zihpm` (`hpmcounter3..31`) extensions; a firmware SBI implementation may even
refuse the SBI PMU extension entirely if `mcountinhibit` is unimplemented, since
without it firmware cannot atomically freeze a group
(`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:3-12`).

### Design philosophy

The SBI PMU extension is deliberately shaped to back a Linux `perf` PMU. From its
specification (`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:22-29`):

> _"The SBI PMU extension provides: 1. An interface for supervisor-mode software to
> discover and configure per-hart hardware/firmware counters 2. A typical Linux perf
> compatible interface for hardware/firmware performance counters and events 3. Full
> access to microarchitecture's raw event encodings"_

Three consequences shape the whole stack:

1. **Counter allocation is firmware's job.** The kernel never picks a physical
   counter; it hands firmware an event and asks it to _find_ a counter that can
   monitor it ([`config_match`](#how-it-works)). This keeps the S-mode driver
   microarchitecture-agnostic at the cost of an `ecall` per configuration.
2. **The event→register mapping is implementation-defined.** The SBI standardizes
   event _classes_ ([`event_idx`](#event-encoding-the-sbi-event-idx)); the concrete
   `mhpmeventX` selector values are per-vendor, supplied to firmware out-of-band via
   the device tree. This is the RISC-V flavour of
   [architected-vs-implementation-defined events][arch-vs-impl].
3. **Sampling is a separate, optional extension.** Base counting is always
   available; overflow interrupts, privilege filtering, and (eventually) branch
   records each ride on a distinct ratified extension the platform may or may not
   implement. The kernel treats each as a runtime-probed capability — the theme of
   [the seven concerns](#the-seven-concerns) below.

---

## How it works

### Event encoding: the SBI `event_idx`

Every event the kernel wants counted is named by a 20-bit `event_idx`
(`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:37-59`):

| `type` (`event_idx[19:16]`) | Class      | `code` (`event_idx[15:0]`)                                            |
| --------------------------- | ---------- | --------------------------------------------------------------------- |
| `0`                         | HW general | `1..10` — `CPU_CYCLES` … `REF_CPU_CYCLES`                             |
| `1`                         | HW cache   | `cache_id[15:3]`, `op_id[2:1]`, `result_id[0]`                        |
| `2`                         | raw v1     | selector programmed into `mhpmevent[0:47]`                            |
| `3`                         | raw v2     | selector programmed into `mhpmevent[0:55]`                            |
| `15`                        | firmware   | firmware-counted software events (RFENCE/IPI/SFENCE counts, traps, …) |

HW-cache codes compose a cache id (`L1D`/`L1I`/`LL`/`DTLB`/`ITLB`/`BPU`/`NODE`)
with an operation (`READ`/`WRITE`/`PREFETCH`) and a result (`ACCESS`/`MISS`)
(`src/ext-pmu.adoc:62-160`). For raw events the supervisor passes an `event_data`
blob that firmware programs into the low bits of `mhpmevent`, firmware owning the
top bits (`src/ext-pmu.adoc:165-201`). See
[Concern 7](#concern-7-event-naming-encoding) for how Linux maps `PERF_TYPE_RAW`
onto this.

### The counter lifecycle: `config_match` → start / stop / read

The SBI PMU interface is a small set of function IDs
(`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:699-715`):

| FID | Function                          | Since   |
| --- | --------------------------------- | ------- |
| 0   | `sbi_pmu_num_counters`            | base    |
| 1   | `sbi_pmu_counter_get_info`        | base    |
| 2   | `sbi_pmu_counter_config_matching` | base    |
| 3   | `sbi_pmu_counter_start`           | base    |
| 4   | `sbi_pmu_counter_stop`            | base    |
| 5   | `sbi_pmu_counter_fw_read`         | base    |
| 6   | `sbi_pmu_counter_fw_read_hi`      | SBI 2.0 |
| 7   | `sbi_pmu_snapshot_set_shmem`      | SBI 2.0 |
| 8   | `sbi_pmu_event_get_info`          | SBI 3.0 |

Linux allocates a counter by calling `SBI_EXT_PMU_COUNTER_CFG_MATCH` — firmware
picks a free counter able to monitor the event and returns its index
(`linux@e43ffb69 drivers/perf/riscv_pmu_sbi.c:538-594`, `pmu_sbi_ctr_get_idx`) —
then starts, stops, and reads it via the matching calls (`:799-856`, `:739-779`).
`counter_get_info` (FID 1) packs the counter's CSR number in `bits[11:0]`, its
`Width` (minus one) in `[17:12]`, and a `Type` bit at `[XLEN-1]` distinguishing a
hardware counter (`0`) from a firmware counter (`1`)
(`src/ext-pmu.adoc:285-296`). That `Type` bit decides how the kernel reads it: a
**hardware** counter is a direct CSR read (`riscv_pmu_ctr_read_csr(info.csr)`), a
**firmware** counter is another SBI call, `SBI_EXT_PMU_COUNTER_FW_READ`
(`riscv_pmu_sbi.c:756-776`).

### Firmware-side selector translation

OpenSBI cannot invent the per-vendor `mhpmevent` selector for an architected
event, so a platform supplies the mapping out-of-band — via the device-tree
properties `riscv,event-to-mhpmcounters` and `riscv,event-to-mhpmevent`, or via
platform hooks; **without them SBI PMU is not enabled**
(`opensbi@26257121 docs/pmu_support.md:1-45`,
`opensbi@26257121 lib/utils/fdt/fdt_pmu.c:49,75,121`). At `config_match` time
firmware translates the `event_idx` to a raw selector with
`sbi_platform_pmu_xlate_to_mhpmevent(...)`, then writes it into the counter's
control register with `csr_write_num(CSR_MHPMEVENT3 + ctr_idx - 3, …)`
(`opensbi@26257121 lib/sbi/sbi_pmu.c:516-557`). The generic platform simply
zero-extends the `event_idx` as the selector for HW-general and HW-cache events.

### User-space direct reads: the RISC-V self-monitoring story

RISC-V's [self-monitoring / user-space counter read][self-mon] path is
`rdcycle`/`rdinstret`/`rdhpmcounter`, gated by the `scounteren` CSR. The SBI driver
programs `scounteren` to control which counters an unprivileged read can see,
toggling the mapped event's bit as the counter is `mmap`'d and un-`mmap`'d
(`riscv_pmu_sbi.c:781-797`, `:1157-1160`), and supports the
`perf_event_mmap_page` user-read seam that x86's `rdpmc` path also uses
(`:1322-1355`). This is the lowest-overhead acquisition path — the natural fit for
per-iteration bracketing inside a benchmark loop — but, exactly as
[the concepts note][self-mon], its availability is arch- and OS-policy-dependent.

---

## The seven concerns

This tree analyses every backend against the same seven-concern spine. RISC-V's
headline is how many cells are **explicit absences** — the survey's value here is
recording precisely _what the ratified ISA does not yet standardize_ and what has
not yet reached Linux.

| #   | Concern                                                                   | RISC-V status                                               |
| --- | ------------------------------------------------------------------------- | ----------------------------------------------------------- |
| 1   | [Scalar counting](#concern-1-scalar-counting)                             | ✅ SBI PMU; `cycle`/`instret` legacy fallback               |
| 2   | [Overflow / IP sampling](#concern-2-overflow-ip-sampling)                 | ⚠️ conditional on **Sscofpmf**; skidded IP; guest needs AIA |
| 3   | [Precise data-source sampling](#concern-3-precise-data-source-sampling)   | ❌ **absent** — no PEBS/SPE analog                          |
| 4   | [Code-space decode](#concern-4-code-space-decode-symbolization)           | ✅ ISA-neutral ELF/DWARF; no HW branch stack yet            |
| 5   | [Event-space & branch records](#concern-5-event-space-branch-records-ctr) | ⚠️ **CTR ratified, no Linux consumer**                      |
| 6   | [NUMA & topology](#concern-6-numa-topology)                               | ◐ SBI `CACHE_NODE` counter only; topology is ISA-neutral    |
| 7   | [Event naming & encoding](#concern-7-event-naming-encoding)               | ✅ SBI classes + impl-defined selectors; perf vendor JSON   |

### Concern 1: Scalar counting

**Available.** [Counting][counting] is the mature path: the driver discovers
counters, allocates them by `config_match`, and reads them per the lifecycle
above. When SBI PMU (≥ 0.3) is absent the kernel falls back to
`riscv_pmu_legacy.c`, which exposes only two [fixed counters][fixed-config] —
`cycle` (index 0) and `instret` (index 2), 63-bit — with **no start/stop, no
interrupt, and no exclude** (`PERF_PMU_CAP_NO_INTERRUPT | PERF_PMU_CAP_NO_EXCLUDE`)
(`linux@e43ffb69 drivers/perf/riscv_pmu_legacy.c:15-32,40-44,110-130`). A harness
that stays within the physical counter budget avoids
[multiplexing][mux] the same way it does on any other backend; because firmware
owns allocation, a group that firmware cannot place is simply refused rather than
scaled.

### Concern 2: Overflow / IP sampling

**Available, but conditional on the Sscofpmf extension.** [Overflow
sampling][overflow] needs an interrupt on counter overflow — the RISC-V
[PMI][pmi]. That interrupt is defined by **Sscofpmf**, which adds to
`mhpmevent[63:58]` the fields `OF, MINH, SINH, UINH, VSINH, VUINH`: `OF` is a
sticky overflow-and-interrupt-disable bit, and the `xINH` bits inhibit counting
per privilege mode (`riscv-isa-manual@fbae3b43 src/priv/sscofpmf.adoc:29-64`).
When a counter overflows with `OF == 0`, hardware raises a **Local Count-Overflow
Interrupt (LCOFI)** — standard local interrupt **bit 13** of `mip`/`mie`/`sip`/`sie`,
delegable to S-mode via `mideleg` (`sscofpmf.adoc:69-91`;
kernel `IRQ_PMU_OVF = 13`, `RV_IRQ_PMU` at
`linux@e43ffb69 arch/riscv/include/asm/csr.h:101,537`). The specification is
explicit about the dual role of `OF` (`sscofpmf.adoc:69-73`):

> _"If an `hpmcounter` overflows while the associated OF bit is zero, then a "`count
overflow interrupt request`" is generated. If the OF bit is one, then no interrupt
> request is generated. Consequently the OF bit also functions as a count overflow
> interrupt disable for the associated `hpmcounter`."_

To let the S-mode handler find which counters overflowed without an SBI round-trip,
Sscofpmf adds `scountovf` (CSR `0xda0`) — a **read-only** 32-bit shadow of the `OF`
bits of `mhpmevent3..31`, per-bit gated by `mcounteren`/`hcounteren`
(`sscofpmf.adoc:111-129`; `csr.h:317`). The overflow handler reads `scountovf` (or
the SBI snapshot bitmap, below), stops counters, and for each sampling event whose
`OF` bit is set calls `perf_event_overflow(event, &data, regs)`
(`riscv_pmu_sbi.c:1041-1146`, esp. `:1091` `get_irq_regs`, `:1136`
`perf_event_overflow`).

> [!WARNING]
> **The sampled IP is inherently skidded.** `PERF_SAMPLE_IP` is the trapped program
> counter (`xepc`) at the point the LCOFI is taken — not a hardware-tagged
> retirement address. RISC-V has no mechanism to remove [skid][precise-skid]; the
> IP lands some distance past the instruction that caused the overflow, exactly the
> bias [precise sampling][precise] corrects on x86 (PEBS) and ARM (SPE). See
> [Concern 3](#concern-3-precise-data-source-sampling).

**Degradation without Sscofpmf.** The kernel enables sampling _only_ if `RV_IRQ_PMU`
(Sscofpmf) — or the T-Head C9xx / Andes vendor errata IRQs — is present; otherwise
`pmu_sbi_setup_irqs` returns `-EOPNOTSUPP` and the PMU advertises
`PERF_PMU_CAP_NO_INTERRUPT | PERF_PMU_CAP_NO_EXCLUDE`, logging _"Perf
sampling/filtering is not supported as sscof extension is not available"_
(`riscv_pmu_sbi.c:1192-1218,1449-1454`). This is the RISC-V analogue of the way the
sparkles [baseline harness][baseline] degrades under a restrictive
[`perf_event_paranoid`][priv-gating]: sampling and privilege filtering are runtime
capabilities to probe, never to assume.

**Privilege filtering rides on the same extension.** `exclude_kernel → SINH`,
`exclude_user → UINH`, and the guest variants `→ VSINH/VUINH` are threaded through
the SBI `config_flags` `SET_{V,}{U,S,M}INH` bits, which firmware applies to
`mhpmevent` — **and firmware only applies them when Sscofpmf is present**
(`pmu_update_inhibit_flags` guards on `SBI_HART_EXT_SSCOFPMF`)
(`riscv_pmu_sbi.c:517-536`; `src/ext-pmu.adoc:332-354`;
`opensbi@26257121 lib/sbi/sbi_pmu.c:504-514,534-543`). So `exclude_user`/
`exclude_kernel` is not free with base counting — it is a Sscofpmf capability,
matching the `NO_EXCLUDE` fallback.

**SBI counter snapshot (SBI 2.0).** FID 7 registers a shared-memory page carrying a
`counter_overflow_bitmap` (valid only under Sscofpmf) and 64-bit
`counter_values[]`, so the overflow handler reads overflow state and values without
per-counter SBI calls (`src/ext-pmu.adoc:549-609`; consumer
`riscv_pmu_sbi.c:1076-1078,919-946`).

#### Guest (VS-mode) sampling needs AIA on top

Host sampling needs only Sscofpmf. **Guest** sampling needs more. KVM builds a real
host `perf_event` per guest counter with an overflow handler
`kvm_riscv_pmu_overflow` that calls
`kvm_riscv_vcpu_set_interrupt(vcpu, IRQ_PMU_OVF)`
(`linux@e43ffb69 arch/riscv/kvm/vcpu_pmu.c:293-331,334-361`). But injecting bit 13
into a guest is not something the base hypervisor extension can do — `hvip` can only
inject the three standard VS interrupts (soft/timer/external). Delivery of the LCOFI
to a guest therefore requires **AIA** (Ssaia/Smaia): `kvm_riscv_aia_enable` sets
`csr_set(CSR_HVIEN, BIT(IRQ_PMU_OVF))`, guarded by both
`__riscv_isa_extension_available(NULL, RISCV_ISA_EXT_SSCOFPMF)` and
`kvm_riscv_aia_available()` (`arch/riscv/kvm/aia.c:565-567,581-582`;
guest-side sync `arch/riscv/kvm/vcpu.c:391-396`).

> [!NOTE]
> Do not overstate this as "sampling needs AIA". The precise statement: **host**
> sampling needs only Sscofpmf; **guest** sampling needs Sscofpmf **and** AIA. Absent
> Sscofpmf a guest falls back to the legacy driver reading only `cycle`/`instret`
> (KVM returns 0 for those and traps other `hpmcounter` reads as illegal)
> (`arch/riscv/kvm/vcpu_pmu.c:388-402`).

### Concern 3: Precise data-source sampling

**Absent.** There is **no PEBS/IBS/SPE analog** in ratified RISC-V. A full-tree
search of the unified ISA manual for a sampled-data-address, load-latency, or
[data-source-attribution][data-src] mechanism found nothing relevant — only the
unrelated RVWMO "data source register" and PMA "imprecise trap" text
(search over `riscv-isa-manual@fbae3b43 src/**`). Concretely, there is no RISC-V
producer for `PERF_SAMPLE_ADDR`, `PERF_SAMPLE_PHYS_ADDR`, or
`PERF_SAMPLE_DATA_SRC`: the SBI/Sscofpmf sampling path carries **IP plus counter
deltas only**. The closest standardized construct is the SBI HW-cache **`NODE`**
event (`SBI_PMU_HW_CACHE_NODE`, "NUMA node cache event") — a _counter_, not a
per-sample data-source tag (`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:140`).

This immaturity is corroborated by field experience. The "Dissecting RISC-V
Performance" roofline paper `[literature]` reports needing a _"workaround to
circumvent hardware bugs in one of the popular RISC-V implementations, enabling
robust event sampling"_ and deliberately builds a **PMU-independent** compiler
roofline because hardware PMUs are unreliable
([arXiv 2507.22451][roofline], abstract). In the tree's [comparison][comparison]
the whole precise-sampling / data-source column reads "unavailable" for RISC-V.

### Concern 4: Code-space decode & symbolization

**ISA-neutral.** The RISC-V perf PMU registers as an ordinary `perf_pmu` (name
`"cpu"`, `PERF_TYPE_RAW`) producing standard `perf_event` samples
(`linux@e43ffb69 drivers/perf/riscv_pmu_sbi.c:1475`), so
address → module → symbol → line [symbolization][symbolize] is the same ELF/DWARF
pipeline every architecture uses — [`libelf`/`libdw`/`libdwfl`][elfutils], with no
RISC-V-specific seam. Likewise there is **no hardware call-stack or branch-stack
producer** at v7.1-rc6 (no CTR consumer — see
[Concern 5](#concern-5-event-space-branch-records-ctr)), so [callchains][unwind]
rely on frame-pointer or DWARF-CFI userspace unwinding exactly as elsewhere. When
CTR lands it would supply the LBR-style branch stack that AutoFDO and path-sensitive
analyses want (`riscv-ctr@42e299ca intro.adoc:4-6`).

### Concern 5: Event-space & branch records (CTR)

The RISC-V [branch-record][branch-records] extension is **CTR — Control Transfer
Records (Smctr/Ssctr), v1.0, ratified 2024-11-22.** It is the direct LBR/BRBE
analog: a circular FIFO recording qualified control transfers, each entry holding a
source PC (`ctrsource`), target PC (`ctrtarget`), and metadata (`ctrdata`), with a
software-selectable depth of `2^(DEPTH+4)` = **16 … 256** entries, accessed via the
indirect-CSR window `siselect` `0x200–0x2FF`
(`riscv-ctr@42e299ca header.adoc:4-6,39-47`, `intro.adoc:4-8`,
`body.adoc:161-208,285-296`). The header carries the ratified-state banner
(`header.adoc:39-47`):

> _"This document is in the [Ratified state]. No changes are allowed. Any desired or
> needed changes can be the subject of a follow-on new extension. Ratified extensions
> are never revised."_

`ctrdata.TYPE[3:0]` classifies each transfer into 16 kinds
(`body.adoc:340-373,574-595`):

| `TYPE` | Transfer         | `TYPE`  | Transfer                                  |
| ------ | ---------------- | ------- | ----------------------------------------- |
| `1`    | Exception        | `9`     | Direct call                               |
| `2`    | Interrupt        | `10`    | Indirect jump                             |
| `3`    | Trap return      | `11`    | Direct jump                               |
| `4`    | Not-taken branch | `12`    | Co-routine swap                           |
| `5`    | Taken branch     | `13`    | Function return                           |
| `8`    | Indirect call    | `14/15` | Other indirect / direct jump-with-linkage |

Filtering is rich: `mctrctl`/`sctrctl` select **privilege modes** (U/S/M) and
apply **per-transfer-type inhibits** (`EXCINH`, `INTRINH`, `TRETINH`, `TKBRINH`,
`NTBREN`, `INDCALLINH`, `DIRCALLINH`, `INDJMPINH`, `DIRJMPINH`, `CORSWAPINH`,
`RETINH`, …), plus **RASEMU** (return-address-stack emulation mode) and an optional
per-record cycle count `CC` (mantissa + exponent) (`body.adoc:10-99,340-373`). CTR
depends on S-mode and the `Sscsrind` indirect-CSR extension
(`intro.adoc:28`; `src/priv/smctr.adoc`).

The seam that ties CTR to sampling is **freeze-on-LCOFI**: `LCOFIFRZ` sets
`sctrstatus.FROZEN` on a local count-overflow interrupt so the branch history
leading to the sampled `xepc` is preserved for the ISR — the exact LBR-at-sample
pattern (`body.adoc:55,734`):

> _"Freeze on LCOFI ensures that the execution path leading to the sampled
> instruction (`xepc`) is preserved, and that the local counter overflow interrupt
> (LCOFI) and associated Interrupt Service Routine (ISR) do not displace any recorded
> transfer history state."_

> [!WARNING]
> **CTR is ratified but has no Linux consumer at v7.1-rc6.** `drivers/perf/riscv_ctr.c`
> **does not exist** in the tree, and a full-tree grep for
> `ssctr|smctr|control_transfer|RISCV_ISA_EXT_S[MS]CTR` across `arch/riscv/`,
> `drivers/perf/`, and `include/` returns only unrelated hits
> (`linux@e43ffb69`, "Linux 7.1-rc6", 2026-05-31). The ratified branch-record
> capability exists only as spec: no kernel driver publishes a
> `PERF_SAMPLE_BRANCH_STACK` on RISC-V yet. This refutes a prompt hypothesis and is
> the page's headline gap — carried in [the comparison's open questions][comparison-open].

CTR is also already folded into the unified ISA manual as `src/priv/smctr.adoc`
("`ext:smctr[]` … Version 1.0"), so the ratified extension has two concurring
primary sources; this page cites the standalone `riscv-ctr` repo for line precision.

Beyond CTR and counters, there is **no Intel-PT / Arm-ETM-style full
instruction-trace standard**. The only other standardized "event space" is SBI
**firmware events** (type `15`: RFENCE/IPI/SFENCE/HFENCE counts, misaligned and
access-fault traps, …) — and those are counts, not traces
(`riscv-sbi-doc@8a545eff src/ext-pmu.adoc:203-259`).

### Concern 6: NUMA & topology

**Collapses to a single counter.** There is no architected NUMA-source PMU
classification analogous to the vendor [data-source][data-src] engines. The only
NUMA-aware PMU construct is the SBI HW-cache `NODE` event above — a counter, not a
per-sample tag (`src/ext-pmu.adoc:140`; kernel cache-event map
`linux@e43ffb69 drivers/perf/riscv_pmu_sbi.c:281-300`). Node and topology discovery
itself is the ISA-neutral OS/ACPI/DT path — [`libnuma`][numa] and sysfs — not a
RISC-V-specific seam. There is likewise **no standardized uncore / system-PMU
framework** ([uncore PMU][uncore]) analogous to Arm CMN/DSU/DMC in `drivers/perf/`
at this SHA — only the `riscv_pmu*.c` core plus SBI and legacy drivers exist
(`ls linux@e43ffb69 drivers/perf/riscv*`).

### Concern 7: Event naming & encoding

**Two layers: standardized classes, implementation-defined selectors.** The SBI
standardizes the `event_idx` [class encoding][naming-concept] above (HW-general,
HW-cache, raw-v1/v2, firmware), but the **actual `mhpmevent` selector values are
per-vendor** — RISC-V architects _no_ hardware event numbers, only the SBI classes,
matching its position on the [architected-vs-implementation-defined axis][arch-vs-impl].
Linux distinguishes raw / firmware / platform-firmware events via `config[63:62]` and
maps `PERF_TYPE_RAW` onto the SBI raw class (`riscv_pmu_sbi.c:416-478`;
`src/ext-pmu.adoc:165-201`).

The perf tool carries per-microarchitecture JSON tables under
`tools/perf/pmu-events/arch/riscv/`, keyed by `mvendorid-marchid-mimpid`:

| Vendor        | Microarchitectures (JSON dirs)                     |
| ------------- | -------------------------------------------------- |
| `sifive`      | `bullet`, `bullet-07`, `bullet-0d`, `p550`, `p650` |
| `thead`       | `c900-legacy`                                      |
| `openhwgroup` | `cva6`                                             |
| `starfive`    | `dubhe-80`                                         |
| `andes`       | `ax45`                                             |

Entries are `{EventName, EventCode, BriefDescription}` (or `ArchStdEvent`
references for the standard firmware events)
(`linux@e43ffb69 tools/perf/pmu-events/arch/riscv/mapfile.csv` and the per-vendor
`*.json`). The cross-ISA naming story — how these relate to libpfm4, PAPI, and the
other ISAs' tables — is [`event-naming.md`][naming]'s subject.

---

## Strengths

- **Microarchitecture-agnostic S-mode driver.** Firmware owns counter allocation
  and selector translation, so the kernel driver is small and portable; adding a new
  core is a device-tree map plus (optionally) a perf JSON, not a kernel change.
- **Clean, ratified sampling primitive.** Sscofpmf's LCOFI + `scountovf` shadow give
  a well-specified overflow-interrupt path with per-privilege-mode inhibit bits
  standardized in the ISA rather than bolted on per vendor.
- **User-space direct reads are first-class.** `rdcycle`/`rdinstret` gated by
  `scounteren`, wired through `perf_event_mmap_page`, give a genuinely low-overhead
  counting path suited to per-iteration benchmark bracketing.
- **Branch records are already ratified.** CTR is a complete, ratified LBR/BRBE-class
  design (16 transfer types, depth 16–256, RASEMU, freeze-on-LCOFI) — the
  specification work is done, ahead of silicon and software.
- **Firmware-counted software events** (RFENCE/IPI/trap counts) come "for free" as a
  standardized class alongside hardware events.

## Weaknesses

- **No precise sampling at all.** No PEBS/IBS/SPE analog: no de-skidded IP, no
  sampled data address, no data-source or load-latency attribution. Memory-hierarchy
  analysis that other backends get from precise sampling is simply unavailable.
- **Branch records are spec-only.** CTR is ratified but has **no Linux consumer** at
  v7.1-rc6 — no `PERF_SAMPLE_BRANCH_STACK` on RISC-V, so AutoFDO / path-sensitive
  tooling has nothing to consume.
- **Sampling and privilege filtering are optional.** Without Sscofpmf the PMU is
  counting-only (`NO_INTERRUPT | NO_EXCLUDE`); `exclude_user`/`exclude_kernel` cannot
  be assumed.
- **An extra indirection on every configuration.** Counter config crosses an SBI
  `ecall` into M-mode firmware; the S-mode driver never touches the control CSRs
  directly.
- **Fragmented, immature implementations.** Per the roofline paper, real RISC-V PMUs
  carry hardware bugs and platform-specific defects that force workarounds
  `[literature]`.
- **No uncore / system-PMU framework** and no NUMA data-source classification beyond a
  single `CACHE_NODE` counter.

---

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                       | Trade-off                                                                                                                                               |
| ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Counting via M-mode firmware over an SBI ecall (not direct S-mode)       | S-mode cannot write the control CSRs; firmware indirection keeps the kernel driver portable     | An `ecall` per configuration; behaviour depends on the firmware/platform DT map being present                                                           |
| Firmware picks the physical counter (`config_match`)                     | Kernel stays microarchitecture-agnostic; no per-core counter-allocation logic in Linux          | The kernel cannot pin a specific counter; placement policy lives in opaque firmware                                                                     |
| Sampling as a separate extension (Sscofpmf), probed at runtime           | Small cores can ship counting-only silicon; the interrupt path is opt-in                        | Sampling **and** privilege filtering degrade to `NO_INTERRUPT \| NO_EXCLUDE` without Sscofpmf                                                           |
| Skidded `xepc` as the sampled IP; no precise mechanism                   | Keeps the sampling path to a single overflow interrupt + trap frame                             | Biased profiles on out-of-order cores; no data-address / data-source attribution at all                                                                 |
| Guest LCOFI delivery layered on AIA (`HVIEN`) rather than base H-ext     | The base hypervisor extension can only inject three standard VS interrupts                      | Guest sampling adds an Ssaia/Smaia dependency on top of Sscofpmf                                                                                        |
| Event classes standardized; `mhpmevent` selectors implementation-defined | Portable event _names_ without dictating hardware encodings                                     | Portable names exist only as far as per-microarchitecture JSON/DT maps are maintained                                                                   |
| **Model RISC-V as a capability subset in the sparkles backend**          | Cleanly mirrors the ratified/landed reality and the runtime-probe discipline the tree advocates | Advertise counting always, sampling only under Sscofpmf, privilege filtering with it, **branch records never (yet)**, and precise/data-source **never** |

The last row is the survey's recommendation for how a portable harness should treat
RISC-V: not as a reduced x86, but as a distinct capability set to advertise and probe
— counting is a given, sampling is conditional, and precise/branch-record features are
absent (one permanently, one pending a Linux driver). This is the same
capability-not-assumption stance the [privilege-gating concept][priv-gating] and the
[baseline harness][baseline] apply elsewhere.

---

## Sources

**Linux kernel `[source-verified]`** — `linux@e43ffb69e0438cddd72aaa30898b4dc446f664f8`
(v7.1-rc6, 2026-05-31):

- `drivers/perf/riscv_pmu_sbi.c` — SBI PMU driver: allocation, start/stop/read,
  overflow handler, `scounteren`, snapshot, `PERF_TYPE_RAW` mapping
- `drivers/perf/riscv_pmu_legacy.c` — `cycle`/`instret`-only fallback
- `drivers/perf/riscv_pmu.c` — shared core; `tools/perf/pmu-events/arch/riscv/**` vendor JSON
- `arch/riscv/kvm/{vcpu_pmu,vcpu,aia}.c` — guest counters and AIA-mediated LCOFI injection
- `arch/riscv/include/asm/csr.h` — `IRQ_PMU_OVF`, `scountovf` CSR number

**RISC-V specifications `[source-verified]`:**

- [RISC-V ISA Manual][isa-manual] `@fbae3b43` — `src/priv/sscofpmf.adoc` (Sscofpmf,
  LCOFI, `scountovf`), `src/priv/smctr.adoc` (CTR in the unified manual)
- [RISC-V SBI Specification][sbi-doc] `@8a545eff` — `src/ext-pmu.adoc` (SBI PMU:
  `event_idx`, FIDs, snapshot, firmware events)
- [RISC-V Control Transfer Records (Smctr/Ssctr) v1.0][ctr-repo] `@42e299ca` —
  `header.adoc`, `intro.adoc`, `body.adoc` (ratified 2024-11-22; PDF asset on the
  [v1.0 "Ratified release"][ctr-release])
- [OpenSBI][opensbi] `@26257121` — `lib/sbi/sbi_pmu.c`, `lib/utils/fdt/fdt_pmu.c`,
  `docs/pmu_support.md` (selector translation, DT maps)

**Literature `[literature]`:**

- [Dissecting RISC-V Performance: Practical PMU Profiling and Hardware-Agnostic
  Roofline Analysis on Emerging Platforms][roofline] — arXiv 2507.22451 (PMU
  immaturity, sampling workaround)

**Related pages:** [concepts][concepts] · [Linux perf_events][linux] ·
[precise sampling][precise] · [ARMv8+][arm] · [event naming & encoding][naming] ·
[comparison][comparison].

<!-- References -->

[concepts]: ./concepts.md
[counting]: ./concepts.md#counting
[sampling]: ./concepts.md#sampling
[fixed-config]: ./concepts.md#fixed-and-configurable-counters
[mux]: ./concepts.md#multiplexing-and-scaling
[self-mon]: ./concepts.md#self-monitoring-and-user-space-counter-reads
[pmi]: ./concepts.md#pmi-performance-monitoring-interrupt
[overflow]: ./concepts.md#overflow-sampling
[precise-skid]: ./concepts.md#precise-sampling-and-skid
[data-src]: ./concepts.md#data-source-attribution
[branch-records]: ./concepts.md#branch-records
[symbolize]: ./concepts.md#symbolization
[unwind]: ./concepts.md#unwinding
[uncore]: ./concepts.md#uncore-pmu
[numa]: ./concepts.md#numa-topology-and-page-node-oracles
[arch-vs-impl]: ./concepts.md#architected-vs-implementation-defined-events
[naming-concept]: ./concepts.md#event-naming-and-encoding
[priv-gating]: ./concepts.md#privilege-gating
[linux]: ./linux-perf-events.md
[precise]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[naming]: ./event-naming.md
[arm]: ./arm.md
[comparison]: ./comparison.md
[baseline]: ./sparkles-baseline.md
[comparison-open]: ./comparison.md#open-questions-gaps
[isa-manual]: https://github.com/riscv/riscv-isa-manual/blob/fbae3b43b3feefefe88a8576596d0f06425c2697/src/priv/sscofpmf.adoc
[sbi-doc]: https://github.com/riscv-non-isa/riscv-sbi-doc/blob/8a545effe9b50484ff897d9815d7d9015cdef203/src/ext-pmu.adoc
[ctr-repo]: https://github.com/riscv/riscv-control-transfer-records/blob/42e299ca4f72df6931589068a34956685825c247/body.adoc
[ctr-release]: https://github.com/riscv/riscv-control-transfer-records/releases/tag/v1.0
[opensbi]: https://github.com/riscv-software-src/opensbi/blob/262571217c75c649115633d8075cb6a40d940733/lib/sbi/sbi_pmu.c
[roofline]: https://arxiv.org/abs/2507.22451
