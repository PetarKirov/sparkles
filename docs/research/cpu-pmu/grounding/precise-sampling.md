# Grounding ledger — `precise-sampling.md`

Claim-by-claim verification of `docs/research/cpu-pmu/precise-sampling.md`. Primary
artifacts: the **local** Linux tree `$REPOS/linux` `e43ffb69e043` (v7.1-rc6,
2026-07-10), `$REPOS/papers/cpu-pmu/amd64-apm-vol2-24593.pdf` (AMD64 APM Vol 2,
§13.3), numactl `93c1fe5` (v2.0.19), and **host sysfs / `perf_event_open`** on the
test box (Linux 6.18.26, AMD Ryzen 9 7940HX / Zen 4, `perf_event_paranoid = -1`,
single NUMA node). `$REPOS = /home/petar/code/repos`. This tree is internal QA
evidence — excluded from the VitePress build and lychee.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                             |
| ---- | ------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact / host (locator recorded) |
| `≈`  | Faithful paraphrase of the source                                   |
| `⚠`  | Discrepancy — corrected + reflected in the page                     |
| `◯`  | Not locally groundable — editorial / synthesis                      |
| `🌐` | Web / secondary only                                                |

**Types:** `quote` · `fact` · `behavior` (code does X) · `figure` (number/bound) · `synth`.

## Claims

| #   | Claim                                                                                                                                                                                     | Type           | Source (local + locator)                                                                                                                      | Status |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| 1   | AMD has no PEBS; `cpu/caps/max_precise = 0`; IBS is the only precise engine (`ibs_op` 11, `ibs_fetch` 10, `zen4_ibs_extensions = 1`)                                                      | fact           | host sysfs `/sys/bus/event_source/devices/{cpu/caps/max_precise, ibs_op/type, ibs_fetch/type, ibs_op/caps/zen4_ibs_extensions}` (E1)          | ✓      |
| 2   | Core-PMU `precise_ip` forwarded to `ibs_op`; IBS skid 0, sets `PERF_EFLAGS_EXACT`; `precise_ip > 2` → `-EOPNOTSUPP`                                                                       | quote+behavior | `linux/arch/x86/events/amd/ibs.c:240-258` (`forward_event_to_ibs`)                                                                            | ✓      |
| 3   | IBS tags a random retired µop at a programmable op/cycle interval (27-bit counter, `IbsOpCntCtl`, `IbsOpMaxCnt`) — instruction-based, PMC-independent                                     | behavior       | `papers/cpu-pmu/amd64-apm-vol2-24593.pdf` §13.3                                                                                               | ✓      |
| 4   | IBS fills `perf_mem_data_src` from `IBS_OP_DATA2.DataSrc` + `IBS_OP_DATA3` (`mem_op`/`mem_lvl`/`mem_lvl_num`/`mem_snoop`/`mem_dtlb`/`mem_lock`)                                           | behavior       | `linux/arch/x86/events/amd/ibs.c:1016-1253` (dispatcher `perf_ibs_get_data_src` `:1242`)                                                      | ✓      |
| 5   | Zen 4 widens `DataSrc` to 5 bits (`data_src_hi<<3 \| data_src_lo`) → `g_zen4_data_src[32]` vs legacy `g_data_src[8]`; gated on `IBS_CAPS_ZEN4` (`1U<<11`), host advertises it             | behavior+fact  | `linux/arch/x86/events/amd/ibs.c:1033-1069`; `arch/x86/include/asm/amd/ibs.h:12-26`; `arch/x86/include/asm/perf_event.h:644`; host sysfs      | ✓      |
| 6   | IBS remote signal is coarse — `REM \| HOPS(1)` (or `REM_RAM1`) unconditionally, never a node; quote "HOPS_1 because IBS doesn't provide remote socket detail"                             | quote+behavior | `linux/arch/x86/events/amd/ibs.c:1113-1119, 1128-1134`                                                                                        | ✓      |
| 7   | `WEIGHT` = `dc_miss_lat` (load-miss only); `ADDR` = `IBSDCLINAD`/`dc_lin_addr_valid`; `PHYS_ADDR` = `IBSDCPHYSAD`/`dc_phy_addr_valid`                                                     | behavior       | `linux/arch/x86/events/amd/ibs.c:1296-1317`; host: median 412-cyc, max ~1.8k-cyc pointer-chase latencies (E3)                                 | ✓      |
| 8   | Zen 4 hardware load-latency filter `IBS_CAPS_OPLDLAT`: `config1` threshold `[128, 2048]` cyc; sub-threshold ops dropped in IRQ handler                                                    | behavior       | `linux/arch/x86/events/amd/ibs.c:281-287, 407-419, 1464-1478`                                                                                 | ✓      |
| 9   | No `IBS_CAPS_BIT63_FILTER` on this Zen 4 → bare `exclude_kernel`/`exclude_user`/`exclude_hv` = `-EINVAL`; kernel/user filtering needs `swfilt` (`config2:0`); `exclude_hv` never accepted | behavior       | `linux/arch/x86/events/amd/ibs.c:346-370`; host `perf_event_open` matrix (E2)                                                                 | ✓      |
| 10  | `perf mem` on AMD = single `mem-ldst` on `ibs_op` (not Intel's `mem-loads,ldlat=%u` + `mem-stores`)                                                                                       | behavior       | `linux/tools/perf/arch/x86/util/mem-events.c:24-34`; host `perf mem report` → `event 'ibs_op//'` (E4)                                         | ✓      |
| 11  | PEBS precise levels 1/2/3; level 3 = zero-skid (PDIR/PDist, needs a specific counter); kernel special-cases `precise_ip == 3`                                                             | behavior       | `linux/arch/x86/events/intel/core.c:5239, 5260, 5278, 5298, 5358, 5398, 5511`                                                                 | ✓      |
| 12  | PEBS data-source from DS-area record `dse` field → per-µarch `pebs_data_source[]` (`load_latency_data`/`__grt_latency_data`); latency `pebs->lat`, addr `pebs->dla`                       | behavior       | `linux/arch/x86/events/intel/ds.c:125-260, 455-708, 2131-2202`                                                                                | ✓      |
| 13  | Both PEBS and IBS target the identical `perf_mem_data_src` ABI union                                                                                                                      | fact           | `linux/include/uapi/linux/perf_event.h:1319-1459`                                                                                             | ✓      |
| 14  | Union layout (one LE `u64`: `mem_op:5`…`mem_rsvd:13`) + `PERF_MEM_LVLNUM_*` / `PERF_MEM_HOPS_*` constants                                                                                 | fact           | `linux/include/uapi/linux/perf_event.h:1319-1459`                                                                                             | ✓      |
| 15  | Canonical decode strings (`mem_lvlnum[]`/`mem_hops[]`/`snoop_access[]`/`tlb_access[]`) from perf; probe output matches `perf mem report`                                                  | quote+behavior | `linux/tools/perf/util/mem-events.c:370-559`; host cross-check (E4)                                                                           | ✓      |
| 16  | `get_mempolicy(…MPOL_F_NODE\|MPOL_F_ADDR)` / `move_pages(…query…)` return the page's node; raw syscalls (239/279 x86_64; 236/239 asm-generic), not glibc                                  | fact+behavior  | `linux/arch/x86/entry/syscalls/syscall_64.tbl:237-239, 279`; `include/uapi/asm-generic/unistd.h:601-608`; numactl `numaif.h:11-46`; host (E3) | ✓      |
| 17  | Single-node host: only `node0`, every address → node 0, oracles trivially agree; round-trip shown, cross-node classification not                                                          | fact           | host sysfs `/sys/devices/system/node`; probe (E3)                                                                                             | ✓      |
| 18  | numactl ships no `numa.pc` (`pkg-config numa` fails); libnuma is a plain `-lnuma` whose `get_mempolicy`/`move_pages` are thin syscall wrappers                                            | fact           | host `pkg-config --exists numa` → "No package 'numa' found"; numactl `93c1fe5` (v2.0.19)                                                      | ✓      |
| 19  | SPE is an AUX-buffer PMU; format attrs `pa_enable` (`PMSCR_EL1.PA`), `load_filter`/`store_filter` (`PMSFCR_EL1`), `min_latency` (`PMSLATFR_EL1.MINLAT`), event filter (`PMSEVFR_EL1`)     | behavior       | `linux/drivers/perf/arm_spe_pmu.c:81-91, 203-324`                                                                                             | ✓      |
| 20  | Each SPE record carries `virt_addr` + `phys_addr` + `context_id` + `latency`                                                                                                              | fact           | `linux/tools/perf/util/arm-spe-decoder/arm-spe-decoder.h:112-125`                                                                             | ✓      |
| 21  | SPE data-source is implementation-defined (MIDR-dispatched: Neoverse common + AmpereOne + HiSilicon HIP tables), framing architected; Neoverse 3-level quote                              | quote+behavior | `linux/tools/perf/util/arm-spe.c:585-705` (`arm_spe__synth_data_source_common` `:651`, quote `:654-660`); enums `arm-spe-decoder.h:77-108`    | ✓      |
| S1  | APM Overview quote ("For a load or store op: …")                                                                                                                                          | quote          | `papers/cpu-pmu/amd64-apm-vol2-24593.pdf` §13.3                                                                                               | ✓      |
| S2  | Legacy `PERF_MEM_LVL_*` deprecation quote                                                                                                                                                 | quote          | `linux/include/uapi/linux/perf_event.h:1368-1370`                                                                                             | ✓      |
| S3  | IBS-vs-PEBS contrast table; seven-concern mapping; Strengths/Weaknesses/decision tables                                                                                                   | synth          | derived from claims 1–21                                                                                                                      | ◯      |

## Discrepancies

All five are **prompt-vs-hardware** corrections surfaced during W2 research; each is
reflected in the page rather than left as a page error.

| #   | Prompt assumption                                                  | Reality (this host)                                                                                          | Reflected in page                                                              |
| --- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| D1  | "Intel PEBS + AMD IBS both testable here"                          | AMD Zen 4 box has **no PEBS** (`cpu/caps/max_precise = 0`); IBS is the sole precise engine                   | PEBS section tagged `[source-verified]`/`[literature]`, never `[hw-verified]`  |
| D2  | "Fall back to `cpu` PMU with `precise_ip > 0` if IBS unavailable"  | The AMD `cpu` PMU has **no precise mode at all**; the fallback is Intel-only and unreachable here            | Stated in the IBS section; probe's `cpu` branch labelled Intel-only/UNVERIFIED |
| D3  | Bare `exclude_kernel`/`exclude_hv` opens an IBS mem-sampling event | `-EINVAL` without `IBS_CAPS_BIT63_FILTER`; needs the `swfilt` bit; `exclude_hv` never accepted (E2)          | `swfilt`/`exclude_*` WARNING alert + E2 errno matrix                           |
| D4  | `DATA_SRC` gives a NUMA **node** for remote accesses               | IBS gives only a coarse **remote bit** (`HOPS(1)`); node needs the address→node oracle (complementary)       | Coarse-remote quote + "From data address to NUMA node" section                 |
| D5  | Link `libs "numa"` (pkg-config name) for the oracles               | numactl ships **no `numa.pc`**; `get_mempolicy`/`move_pages` aren't in glibc — probe calls syscalls directly | "No `numa.pc`" paragraph + single-node WARNING                                 |

**Net:** 0 page discrepancies. All 21 research claims + both added quote rows (S1/S2)
are grounded in the local Linux tree / AMD APM PDF / host sysfs+`perf_event_open`;
S3 is flagged synthesis (◯). The five prompt-vs-hardware corrections (D1–D5) are all
reflected honestly in the page. PEBS (D1) and ARM SPE are `[source-verified]`/`[literature]`
only — no local hardware — and the page marks them so; the sole `[hw-verified: x86_64-linux]`
claims are the AMD IBS + NUMA-round-trip ones actually exercised on the test box.
