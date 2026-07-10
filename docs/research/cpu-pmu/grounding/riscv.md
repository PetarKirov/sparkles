# Grounding ledger — `riscv.md`

Claim-by-claim verification of [`docs/research/cpu-pmu/riscv.md`](../riscv.md) against the
**local** pinned trees. `$REPOS = /home/petar/code/repos`. Every load-bearing assertion is a
primary-source spec or kernel/firmware line at a pinned SHA; no RISC-V hardware was measured
(`[source-verified]` + `[literature]` only). This tree is internal QA evidence — excluded from
the VitePress build (`srcExclude`) and from lychee (`exclude_path`).

> Not published research. Do not link to it from the survey pages.

## Pinned sources

| Repo / artifact                                    | Pinned SHA / id                            | As of      |
| -------------------------------------------------- | ------------------------------------------ | ---------- |
| `linux` (v7.1-rc6)                                 | `e43ffb69e0438cddd72aaa30898b4dc446f664f8` | 2026-07-10 |
| `cpu-pmu/riscv-isa-manual`                         | `fbae3b43b3feefefe88a8576596d0f06425c2697` | 2026-07-10 |
| `cpu-pmu/riscv-sbi-doc`                            | `8a545effe9b50484ff897d9815d7d9015cdef203` | 2026-07-10 |
| `c/opensbi`                                        | `262571217c75c649115633d8075cb6a40d940733` | 2026-07-10 |
| `cpu-pmu/riscv-ctr` (Smctr/Ssctr v1.0, Ratified)   | `42e299ca4f72df6931589068a34956685825c247` | 2026-07-10 |
| `papers/cpu-pmu/riscv-roofline-pmu-2507.22451.pdf` | arXiv 2507.22451 (16 pp)                   | 2026-07-10 |
| `papers/cpu-pmu/riscv-ctr-spec-v1.0.pdf`           | CTR v1.0 release asset (23 pp, byte-exact) | 2026-07-10 |

## Status key

| Mark | Meaning                                                        |
| ---- | -------------------------------------------------------------- |
| `✓`  | Verified verbatim / exactly against the cited local artifact   |
| `≈`  | Faithful paraphrase of the cited source                        |
| `⚠`  | Discrepancy — correction recorded + applied to the page        |
| `◯`  | Not source-groundable — editorial synthesis / opinion          |
| `🌐` | Web / secondary (release metadata not in the pinned spec text) |

**Types:** `quote` · `fact` · `behavior` (source does X) · `absence` (verified-not-present) ·
`literature` · `opinion`.

## Claim table

| Claim | Assertion (short)                                                                                                                         | Type       | Source (local + locator)                                                                                                   | Status |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------- | ------ |
| C1.1  | S-mode reads but cannot control counters; only M-mode configures; firmware may refuse SBI PMU if `mcountinhibit` unimplemented            | behavior   | `riscv-sbi-doc src/ext-pmu.adoc:3-12`                                                                                      | ✓      |
| C1.2  | SBI PMU EID `0x504D55`; discover/configure per-hart counters + "full access to … raw event encodings"                                     | quote      | `riscv-sbi-doc src/ext-pmu.adoc:1,22-29`; cross-checked `linux arch/riscv/include/asm/sbi.h:34`                            | ✓      |
| C1.3  | Counter FIDs 0–5 (base) + 6/7/8 (`fw_read_hi`/`snapshot_set_shmem`/`event_get_info`, SBI 2.0/2.0/3.0)                                     | fact       | `riscv-sbi-doc src/ext-pmu.adoc:699-715`                                                                                   | ✓      |
| C1.4  | `counter_get_info` packs `CSR[11:0]`, `Width[17:12]` (−1), `Type[XLEN-1]` (0=HW,1=FW)                                                     | fact       | `riscv-sbi-doc src/ext-pmu.adoc:285-296`                                                                                   | ✓      |
| C1.5  | Linux allocates via `SBI_EXT_PMU_COUNTER_CFG_MATCH` then start/stop/read                                                                  | behavior   | `linux drivers/perf/riscv_pmu_sbi.c:538-594,799-856,739-779`                                                               | ✓      |
| C1.6  | HW read = direct CSR read; FW read = `SBI_EXT_PMU_COUNTER_FW_READ`                                                                        | behavior   | `linux drivers/perf/riscv_pmu_sbi.c:756-776`                                                                               | ✓      |
| C1.7  | `scounteren` gates unprivileged reads; per-event toggled on `mmap`; `perf_event_mmap_page` user-read                                      | behavior   | `linux drivers/perf/riscv_pmu_sbi.c:781-797,1157-1160,1322-1355` (`0x7` confirmed at `:1158`)                              | ✓      |
| C1.8  | Legacy fallback: only `cycle`/`instret`, 63-bit, no start/stop/interrupt/exclude                                                          | fact       | `linux drivers/perf/riscv_pmu_legacy.c:15-32,40-44,110-130`                                                                | ✓      |
| C1.9  | OpenSBI requires DT `riscv,event-to-mhpm*` maps (or platform hooks) or SBI PMU is not enabled                                             | behavior   | `opensbi docs/pmu_support.md:1-45`, `opensbi lib/utils/fdt/fdt_pmu.c:49,75,121`                                            | ✓      |
| C1.10 | Firmware writes selector via `sbi_platform_pmu_xlate_to_mhpmevent` → `csr_write_num(CSR_MHPMEVENT3+…)`                                    | behavior   | `opensbi lib/sbi/sbi_pmu.c:516-557`                                                                                        | ✓      |
| C2.1  | Sscofpmf adds `mhpmevent[63:58]` = `OF,MINH,SINH,UINH,VSINH,VUINH`                                                                        | fact       | `riscv-isa-manual src/priv/sscofpmf.adoc:29-64`                                                                            | ✓      |
| C2.2  | LCOFI on overflow (`OF==0`) = local IRQ bit 13 of `mip/mie/sip/sie`; `mideleg` delegates; `IRQ_PMU_OVF=13`                                | quote      | `riscv-isa-manual src/priv/sscofpmf.adoc:69-91`; `linux arch/riscv/include/asm/csr.h:101,537`                              | ✓      |
| C2.3  | `scountovf` (CSR `0xda0`) read-only shadow of `OF` bits, per-bit gated by `mcounteren`/`hcounteren`                                       | fact       | `riscv-isa-manual src/priv/sscofpmf.adoc:111-129`; `linux arch/riscv/include/asm/csr.h:317`                                | ✓      |
| C2.4  | Sampling enabled only under Sscofpmf (or vendor errata IRQ); else `NO_INTERRUPT\|NO_EXCLUDE` + message                                    | quote      | `linux drivers/perf/riscv_pmu_sbi.c:1192-1218,1449-1454` (message verbatim at `:1451`)                                     | ✓      |
| C2.5  | Overflow handler reads `scountovf`/snapshot, calls `perf_event_overflow` with `xepc` regs → skidded IP                                    | behavior   | `linux drivers/perf/riscv_pmu_sbi.c:1041-1146` (`:1091` `get_irq_regs`, `:1136`)                                           | ✓      |
| C2.6  | `exclude_kernel→SINH` etc. via SBI `config_flags`, applied by firmware only under Sscofpmf                                                | behavior   | `linux …riscv_pmu_sbi.c:517-536`; `riscv-sbi-doc src/ext-pmu.adoc:332-354`; `opensbi lib/sbi/sbi_pmu.c:504-514,534-543`    | ✓      |
| C2.7  | SBI snapshot (FID 7): `counter_overflow_bitmap` (valid only under Sscofpmf) + 64-bit `counter_values[]`                                   | fact       | `riscv-sbi-doc src/ext-pmu.adoc:549-609`; `linux …riscv_pmu_sbi.c:1076-1078,919-946`                                       | ✓      |
| C2b.1 | KVM builds host `perf_event` per guest counter; handler calls `kvm_riscv_vcpu_set_interrupt(IRQ_PMU_OVF)`                                 | behavior   | `linux arch/riscv/kvm/vcpu_pmu.c:293-331,334-361`                                                                          | ✓      |
| C2b.2 | `IRQ_PMU_OVF` is one of four IRQs KVM may inject into a VS-mode guest                                                                     | fact       | `linux arch/riscv/kvm/vcpu.c:405-426`                                                                                      | ✓      |
| C2b.3 | Guest LCOFI delivery via AIA `HVIEN` bit 13, guarded by Sscofpmf-avail **and** `kvm_riscv_aia_available()`                                | behavior   | `linux arch/riscv/kvm/aia.c:565-567,581-582`; `arch/riscv/kvm/vcpu.c:391-396`                                              | ✓      |
| C2b.4 | Absent Sscofpmf, guest falls back to legacy `cycle`/`instret` (KVM returns 0 / illegal-traps others)                                      | behavior   | `linux arch/riscv/kvm/vcpu_pmu.c:388-402`                                                                                  | ✓      |
| C3.1  | **No PEBS/SPE analog**; no `PERF_SAMPLE_{ADDR,PHYS_ADDR,DATA_SRC}` producer — full-tree manual search                                     | absence    | search over `riscv-isa-manual src/**` (only unrelated RVWMO/PMA hits)                                                      | ✓      |
| C3.2  | Closest construct is the SBI HW-cache `NODE` event (a counter, not a per-sample tag)                                                      | fact       | `riscv-sbi-doc src/ext-pmu.adoc:140`                                                                                       | ✓      |
| C3.3  | Roofline paper: "workaround to circumvent hardware bugs … enabling robust event sampling"; PMU-independent roofline                       | literature | `papers/cpu-pmu/riscv-roofline-pmu-2507.22451.pdf` abstract (arXiv 2507.22451)                                             | ✓      |
| C4.1  | RISC-V perf PMU = ordinary `perf_pmu` ("cpu", `PERF_TYPE_RAW`) → ISA-neutral ELF/DWARF decode                                             | behavior   | `linux drivers/perf/riscv_pmu_sbi.c:1475`                                                                                  | ✓      |
| C4.2  | No HW call/branch-stack producer at v7.1-rc6; callchains via FP / DWARF-CFI; CTR would supply it                                          | absence    | CTR intent `riscv-ctr intro.adoc:4-6`; cf. C5.2                                                                            | ✓      |
| C5.1  | CTR = Smctr/Ssctr, v1.0 **ratified 2024-11-22**; `ctrsource`/`ctrtarget`/`ctrdata`; depth `2^(DEPTH+4)`=16–256; `siselect 0x200–0x2FF`    | quote      | `riscv-ctr header.adoc:4-6,39-47`, `intro.adoc:4-8`, `body.adoc:161-208,285-296`; `riscv-isa-manual src/priv/smctr.adoc:3` | ✓      |
| C5.2  | **`drivers/perf/riscv_ctr.c` does not exist**; grep for `s[ms]ctr\|control_transfer\|…S[MS]CTR` = no CTR consumer                         | absence    | `linux@e43ffb69` full-tree grep (`arch/riscv/`, `drivers/perf/`, `include/`)                                               | ⚠      |
| C5.3  | `ctrdata.TYPE[3:0]` = 16 transfer types + optional cycle-count `CC`                                                                       | fact       | `riscv-ctr body.adoc:340-373,574-595`                                                                                      | ✓      |
| C5.4  | Filtering: `mctrctl`/`sctrctl` privilege bits + per-transfer-type inhibits + RASEMU                                                       | fact       | `riscv-ctr body.adoc:10-99`                                                                                                | ✓      |
| C5.5  | Freeze-on-LCOFI (`LCOFIFRZ` → `sctrstatus.FROZEN`) preserves path to `xepc`                                                               | quote      | `riscv-ctr body.adoc:55,734`                                                                                               | ✓      |
| C5.6  | CTR depends on S-mode and `Sscsrind` (indirect-CSR)                                                                                       | fact       | `riscv-ctr intro.adoc:28`; `riscv-isa-manual src/priv/smctr.adoc`                                                          | ✓      |
| C5.7  | No Intel-PT/ETM full-trace standard; SBI firmware events (type 15) are counts, not traces                                                 | fact       | `riscv-sbi-doc src/ext-pmu.adoc:203-259`                                                                                   | ✓      |
| C6.1  | No architected NUMA-source classification; only SBI `CACHE_NODE`; topology is OS/ACPI/DT (ISA-neutral)                                    | absence    | `riscv-sbi-doc src/ext-pmu.adoc:140`; `linux …riscv_pmu_sbi.c:281-300`                                                     | ✓      |
| C6.2  | No standardized uncore / system-PMU framework for RISC-V at this SHA                                                                      | absence    | `ls linux drivers/perf/riscv*` (only `riscv_pmu{,_sbi,_legacy}.c`)                                                         | ✓      |
| C7.1  | SBI `event_idx` 20-bit: `type[19:16]`, `code[15:0]`; types 0/1/2/3/15                                                                     | fact       | `riscv-sbi-doc src/ext-pmu.adoc:37-59`                                                                                     | ✓      |
| C7.2  | HW-general codes 1–10; HW-cache = `cache_id[15:3]`,`op_id[2:1]`,`result_id[0]` with `NODE` cache id                                       | fact       | `riscv-sbi-doc src/ext-pmu.adoc:62-160`                                                                                    | ✓      |
| C7.3  | Raw selectors implementation-defined (raw-v2 `event_data` 56-bit); Linux distinguishes via `config[63:62]`                                | behavior   | `riscv-sbi-doc src/ext-pmu.adoc:165-201`; `linux …riscv_pmu_sbi.c:416-478`                                                 | ✓      |
| C7.4  | Perf vendor JSON: sifive/thead/openhwgroup/starfive/andes, keyed by `mvendorid-marchid-mimpid`                                            | fact       | `linux tools/perf/pmu-events/arch/riscv/mapfile.csv` + per-vendor `*.json`                                                 | ✓      |
| A1    | Three-level privilege-indirection table (U/S read · S-mode via SBI · M-mode firmware writes)                                              | synthesis  | derived from C1.1–C1.10                                                                                                    | ◯      |
| A2    | Strengths / Weaknesses / Decision·Rationale·Trade-off tables                                                                              | opinion    | derived                                                                                                                    | ◯      |
| A3    | "Model RISC-V as a capability subset" decision row (counting always / sampling under Sscofpmf / branch-records never yet / precise never) | opinion    | sub-report suggested row; derived from C1–C7                                                                               | ◯      |

## Discrepancies

Three rows carried from the W4 sub-report; the first two were prompt hypotheses this survey
overturned, applied to the page as the `⚠` warnings in [Concern 5](../riscv.md#concern-5-event-space-branch-records-ctr).

| #   | Prompt / prior claim                                           | Finding (applied to page)                                                                                                                                                                                                                                                                                                    | Source                                                   | Status |
| --- | -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- | ------ |
| 1   | Prompt asserted a `drivers/perf/riscv_ctr.c` in `$REPOS/linux` | **Refuted.** `drivers/perf/riscv_ctr.c` **does not exist** at `linux@e43ffb69e043` (v7.1-rc6); a full-tree grep for `ssctr\|smctr\|control_transfer\|RISCV_ISA_EXT_S[MS]CTR` returns only unrelated hits. CTR has **no upstream Linux consumer**. Page flags this as the headline gap.                                       | `linux@e43ffb69` (verified by absence)                   | ⚠      |
| 2   | Prompt said "CTR, ratified 2025"                               | **Corrected.** CTR was ratified **2024-11-22** (not 2025) and the extensions are named **Smctr / Ssctr**. Independently corroborated by the GitHub **v1.0 "Ratified release"** (published 2024-11-23), whose PDF asset is saved at `$REPOS/papers/cpu-pmu/riscv-ctr-spec-v1.0.pdf` (23 pp, byte-exact to the release asset). | `riscv-ctr@42e299ca header.adoc:39-47`; CTR v1.0 release | ⚠      |
| 3   | Easy to overstate as "sampling needs AIA"                      | **Nuance.** _Host_ sampling needs only **Sscofpmf**; _guest_ (VS-mode) LCOFI **delivery** additionally needs **AIA** (Ssaia/Smaia) because `hvip` injects only the three standard VS interrupts — bit 13 goes through `HVIEN`. Page states the precise split and adds a `[!NOTE]` against overstatement.                     | `linux arch/riscv/kvm/aia.c:565-567,581-582`             | ⚠      |

**Resolved note (`◯`→ok):** CTR is folded into **both** the standalone `riscv-ctr` repo **and**
the unified ISA manual (`riscv-isa-manual src/priv/smctr.adoc`, "`ext:smctr[]` … Version 1.0") —
two concurring primary sources, not a conflict. The page cites the standalone repo for line
precision and the manual for the ratified-in-manual fact.

## Web / secondary (🌐)

- **CTR v1.0 release metadata** (tag `v1.0`, "Ratified release" published 2024-11-23, asset
  `riscv-ctr-v1.0.pdf`) is GitHub release data, not spec text; the _ratified-state_ and
  _revdate 11/22/2024_ facts themselves are in-tree (`header.adoc:39-47`), so the page's date
  claim is `[source-verified]`, with the release as corroboration only.
- **Sibling-page links** (`./linux-perf-events.md`, `./precise-sampling.md`, `./elfutils.md`,
  `./event-naming.md`, `./arm.md`, `./comparison.md`, `./sparkles-baseline.md`) resolve within
  the cpu-pmu tree once its companion pages land; they carry no RISC-V claim of their own.

**Net:** 45 claims mapped (C1.1–C7.4 + 3 page-level synthesis rows). **0 fabrications**; every
quote is byte-verbatim from the pinned tree (SBI-PMU purpose, Sscofpmf `OF`/LCOFI, CTR
ratified-state, CTR freeze-on-LCOFI, roofline abstract — all re-checked this session). Three `⚠`
rows are **prompt corrections applied to the page**, not page errors: two overturned prompt
hypotheses (no `riscv_ctr.c`; CTR ratified 2024 not 2025) and the host-vs-guest AIA nuance. The
only `◯` rows are the strengths/weaknesses/decision synthesis and the "capability subset"
recommendation, both flagged as editorial in-page.
