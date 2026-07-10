# Grounding ledger — `arm.md`

Claim-by-claim source verification of [`docs/research/cpu-pmu/arm.md`](../arm.md).
ARM-Linux claims are checked against the **local** pinned kernel tree
`linux@e43ffb69e043` (v7.1-rc6, read-only) and the vendor catalog
`arm-data@0806afb1` (`ARM-software/data`, commit 2026-05-01); the Apple
reverse-engineering repo is `applecpu@0e6bc3f6` (dougallj, 2023-07-13). Apple
observations are read off `mac-bsn` = Apple **M4 Max** (`Mac16,5`, SoC `T6041`,
`hw.cpufamily 0x17d5b93a`), macOS **26.3.1** (build 25D771280a), SIP enabled,
non-root. `$REPOS = /home/petar/code/repos` (`linux` at `$REPOS/linux`).

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                        |
| ---- | ------------------------------------------------------------------------------ |
| `✓`  | Verified against the cited local artifact (locator recorded)                   |
| `≈`  | Faithful paraphrase / inference from absence (no single line to point at)      |
| `⚠`  | Discrepancy — open contradiction, flagged in the page                          |
| `◯`  | Not locally groundable — synthesis/consequence, or source unobtainable (gated) |

**Types:** `quote` (verbatim) · `src` (kernel/repo source-read, `[source-verified]`) ·
`hw` (`mac-bsn`, `[hw-verified: aarch64-darwin]`) · `lit` (`[literature]`, gated) ·
`synth` (derived consequence).

## Verification note

**No `aarch64-linux` hardware exists for this survey** — every `src` row is
source-reading of the kernel driver, never a hardware observation. There is
therefore **no `[hw-verified: aarch64-linux]` tag anywhere** in `arm.md`; the only
hardware rows (`hw`) are Apple/macOS. This is by design, stated in the page's
opening scope alert.

## Claim ledger

| #   | Claim (short)                                                                                      | Type   | Source (local + locator)                                                                                                                                                                                                                                                                | Status |
| --- | -------------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| SM  | **Self-monitoring check** — arm64 has an EL0 `rdpmc` analog, doubly gated                          | src    | `arm_pmuv3.c:309-339` (`rdpmc`=config1[1:1] opt-in), `:790-821,836-849` (`PMUSERENR ER\|CR\|UEN`), `:1249-1258` (task-bound/unchained), `:1396-1422` (`perf_user_access` sysctl, default 0), `:1605-1622` (`cap_user_rdpmc`+`pmc_width` userpage), `:1034-1045` (instr ctr not exposed) | ✓      |
| SM′ | Feature landed in Linux **5.17** (2022)                                                            | lit    | Known kernel history; **not** re-derived from git in timebox (shallow `-S` surfaces only the v6.4 driver relocation)                                                                                                                                                                    | ◯      |
| C1  | Event space `0x00-0x3F` common / `0x40+` IMPDEF / `0x4000+` extensions; 16-bit selector            | src    | `arm_pmu.h:125` (`MAX_COMMON_EVENTS 0x40`); `arm_pmuv3.h:16-206` (common+IMPDEF), `:239` (`GENMASK(15,0)`), `:82-119` (ext)                                                                                                                                                             | ✓      |
| C2  | `PMCEID0/1_EL0` per-core capability bitmaps gate visibility + `map_event`                          | src    | `arm_pmuv3.c:1333-1343` (read), `:1261-1264` (expose gate), `:281-289` (sysfs gate)                                                                                                                                                                                                     | ✓      |
| C3  | `PMCR.N` (15:11) counter count; cycle idx 31, instr idx 32                                         | src    | `arm_pmuv3.c:1322-1331`; `arm_pmuv3.h:9-11,219`                                                                                                                                                                                                                                         | ✓      |
| C4  | Width: cycle 64-bit; p5 `PMCR.LP` long events; pre-p5 chaining; p9 `PMICNTR`                       | src    | `arm_pmuv3.c:489-492,504-513,545-553,555-583,1189-1190`; `arch/arm64/…/arm_pmuv3.h:57-62,92-97`; `arm_pmuv3.h:11`                                                                                                                                                                       | ✓      |
| C5  | `armv8_pmuv3_perf_map` generic→PMUv3; branch special-case; per-uarch overrides                     | src    | `arm_pmuv3.c:45-160,1198-1214,1275-1300`                                                                                                                                                                                                                                                | ✓      |
| C6  | Threshold counting `FEAT_PMUv3_TH` via `config1`, capped by `PMMIR.THWIDTH`                        | src    | `arm_pmuv3.c:311-360,416-441,1142-1152`                                                                                                                                                                                                                                                 | ✓      |
| C7  | Overflow sampling + EL-exclusion filters; `exclude_idle` EOPNOTSUPP; IP from `pt_regs`             | src    | `arm_pmuv3.h:246-251`; `arm_pmuv3.c:1090-1160` (`:1099-1102`, `:1117-1136`)                                                                                                                                                                                                             | ✓      |
| C8  | SPE = PEBS/IBS analog; hardware buffer → AUX ring; PC+VA+PA+latency+data-src+ts                    | src    | `arm_spe_pmu.c:64-108,497-620,880-923`                                                                                                                                                                                                                                                  | ✓      |
| C9  | SPE config → `PMSCR`/`PMSIRR`/`PMSFCR`/`PMSEVFR`/`PMSLATFR`/`PMSDSFR`                              | src    | `arm_spe_pmu.c:200-260,367-386,388-421,421-481,893-922`                                                                                                                                                                                                                                 | ✓      |
| C10 | Feature probe `PMSIDR_EL1`; buffer-ownership `PMBIDR_EL1.P` → bail                                 | src    | `arm_spe_pmu.c:1105-1223,1122-1128,1140-1169,1171-1201`                                                                                                                                                                                                                                 | ✓      |
| Q3  | _"profiling buffer owned by higher exception level"_                                               | quote  | `arm_spe_pmu.c:1125-1126`                                                                                                                                                                                                                                                               | ✓      |
| C11 | PA/PCT physical-address collection gated on `perf_allow_kernel()`; CX likewise                     | src    | `arm_spe_pmu.c:873-877,42-55`                                                                                                                                                                                                                                                           | ✓      |
| Q4  | `if (reg & (PMSCR_EL1_PA \| PMSCR_EL1_PCT)) / return perf_allow_kernel();`                         | quote  | `arm_spe_pmu.c:874-875`                                                                                                                                                                                                                                                                 | ✓      |
| C12 | Code-space decode is Linux-generic (`libdwfl`); AAPCS64 frame chain                                | src≈   | absence of ARM-specific decode in `drivers/perf/`; consumer side `tools/perf/util/*` (deferred to W1)                                                                                                                                                                                   | ≈      |
| C13 | BRBE ≤64 records, 2 banks of 32; `BRBSRC/BRBTGT/BRBINF` fields                                     | src    | `arm_brbe.c:29-61,144-212`; `arm_brbe.h:14-24`                                                                                                                                                                                                                                          | ✓      |
| C14 | BRBE `BRBFCR` class filters; `BRBCR` per-EL enable + CC/MPRED/FZP; rejects `exclude_host`          | src    | `arm_brbe.c:14-19,371-425,430-464`                                                                                                                                                                                                                                                      | ✓      |
| C15 | BRBE driven by core PMU (`brbe_probe` in `__armv8pmu_probe_pmu`); via `branch_stack`               | src    | `arm_pmuv3.c:1104-1109,1351,1354-1368`; `arm_brbe.h:14-24`                                                                                                                                                                                                                              | ✓      |
| C16 | One perf PMU per uarch cluster + sysfs `cpumask`; pinned harness must pick the right PMU           | src    | `arm_pmu.c:566-573,519-524,347,540-552`; `arm_pmu_platform.c:59-121`                                                                                                                                                                                                                    | ✓      |
| C17 | `PERF_PMU_CAP_EXTENDED_HW_TYPE` names a specific PMU; `NO_EXCLUDE` when no EL-exclusion            | src    | `arm_pmu.c:891-896,935-940`                                                                                                                                                                                                                                                             | ✓      |
| C18 | CMN uncore: DTC counter block; `config` node-type/eventid/occupid/bynodeid/nodeid packing          | src    | `arm-cmn.c:123-147,163-187,664-688`                                                                                                                                                                                                                                                     | ✓      |
| Q5  | _"The DTC node is where the magic happens"_                                                        | quote  | `arm-cmn.c:123`                                                                                                                                                                                                                                                                         | ✓      |
| C19 | DSU cluster PMU: `CLUSTERPMCR`, cycle idx 31 `0x11`, `config:0-31`; `associated_cpus`/`active_cpu` | src    | `arm_dsu_pmu.c:35-67,97-160,164`                                                                                                                                                                                                                                                        | ✓      |
| C20 | DMC-620 DDR PMU: 8-bit `eventid`+`clkdiv2`; shared IRQ; per-instance PMU bound to a CPU            | src    | `arm_dmc620_pmu.c:70-91,110-128`                                                                                                                                                                                                                                                        | ✓      |
| C21 | All uncore PMUs domain-scoped → not thread-attributable; collapse to "whole chip" on UMA           | synth  | consequence of C18–C20                                                                                                                                                                                                                                                                  | ◯      |
| C22 | `arm-data` catalog per core; three-way `architectural` flag; **no `apple/`** in-tree               | src    | `arm-data@0806afb1 pmu/neoverse-n1.json` (`architectural`, `counters:6`), `pmu/c1-ultra.json`; `linux …/pmu-events/arch/arm64/`                                                                                                                                                         | ✓      |
| C23 | Apple IMPDEF register model: `PMCR0-4`/`PMESR0/1`/`PMSR`/`PMC0-9`, 10 ctrs (2 fixed), 8-bit field  | src    | `apple_m1_cpu_pmu.c:22-168,227-270,379-419,546-566`; `apple_m1_pmu.h:10-50`; `applecpu …/PMCKext2.c:5-32`                                                                                                                                                                               | ✓      |
| Q1  | _"…a grand total of two known counters, and the rest is anybody's guess."_                         | quote  | `apple_m1_cpu_pmu.c:31-40`                                                                                                                                                                                                                                                              | ✓      |
| C24 | Linux Apple driver = 4-event PMUv3 shim (`m1_pmu_pmceid_map`); rest raw via `config:0-7`           | src    | `apple_m1_cpu_pmu.c:170-187,215-220,568-586`                                                                                                                                                                                                                                            | ✓      |
| C25 | **Apple changed event encoding at M4** (E2 table): `as1/a14/as3` Apple #s vs `as4/as5` PMUv3 #s    | hw+src | `mac-bsn:/usr/share/kpep/{as1,a14,as3,as4-1,as5}.plist` (E2); driver TODO `apple_m1_cpu_pmu.c:44-48`                                                                                                                                                                                    | ✓      |
| Q2  | _"…we'll have to introduce per cpu-type tables."_ (predicts the M4 break)                          | quote  | `apple_m1_cpu_pmu.c:44-48`                                                                                                                                                                                                                                                              | ✓      |
| C26 | Linux 8-bit Apple field (`GENMASK(7,0)`, `config:0-7`) under-exposes kpep's wider selectors        | src+hw | `apple_m1_cpu_pmu.c:24,215`; kpep `L1D_CACHE_MISS_LD=0x5a3`, `FETCH_RESTART=0x1de`, up to `0x4006` (M4)                                                                                                                                                                                 | ✓      |
| C27 | Apple advanced filtering (`OPMAT/OPMSK`, `PMTRHLD`, `PMCR2-4`) Linux never programs                | src    | `applecpu@0e6bc3f6 timer-hacks/PMCKext2.c:13-32`                                                                                                                                                                                                                                        | ✓      |
| E1  | This box's kpep = `as4-1.plist` via `cpu_100000c_2_17d5b93a.plist` symlink                         | hw     | `mac-bsn ls -la /usr/share/kpep \| grep 17d5b93a`                                                                                                                                                                                                                                       | ✓      |
| E3  | Full M4-Max catalog = 103 events; SME block; `INST_ALL => {counters_mask:252, number:8}`           | hw     | `mac-bsn:/usr/share/kpep/as4-1.plist` (`python3`/`plutil`)                                                                                                                                                                                                                              | ✓      |

## Discrepancies

- **D1 (major, documented).** Apple's **M4 event-encoding change** (C25). Upstream
  `apple_m1_cpu_pmu.c` has no M4 table and would mis-decode M4 raw event numbers;
  the driver's own TODO comment (Q2) predicts exactly this case. Confirmed by the
  E2 kpep transcript (monotone break across the common subset). Documented in the
  page's [Apple sidebar](../arm.md#the-m4-encoding-change-hw-verified-aarch64-darwin);
  not an open contradiction — a hardware-verified finding. `hw`+`src`.
- **D2 (documented).** Linux's **8-bit Apple event field** (C26) structurally cannot
  express macOS's wider selectors (`0x5a3`, `0x1de`, `0x4006`), so Linux
  under-exposes Apple's PMU even on supported silicon. Documented; `src`+`hw`.
- **D3 (OPEN ⚠).** kpep reports **`fixed_counters: 3`** on _every_ Apple generation
  (E2), but the Linux driver models only **2** fixed counters (idx 0 cycles, idx 1
  instructions; `apple_m1_cpu_pmu.c:22`). The third fixed counter macOS advertises is
  unmodeled by Linux (candidate: a fixed reference/uptime counter). **Flagged, not
  resolved** — carried as an open item in the page's Apple sidebar. `hw` vs `src`. ⚠
- **D4 (refinement, resolved).** The "architected vs implementation-defined" split is
  **three-way** in ARM's own catalog (C22): architectural (mandatory) ⊂ common
  (`0x00-0x3F`, presence via `PMCEID`) ⊂ all; `0x40+` IMPDEF. The naïve
  "`0x0000–0x003F` vs `0x0040+`" boundary is the _common/IMPDEF_ line, correct as
  stated, but "architectural" is a stricter subset inside it. Presented in the page as
  an explicit refinement of the two-way split, not a contradiction. `src`.
- **D5 (GATED ◯).** The **Arm ARM (DDI 0487, latest = issue K.a)** and the **SPE
  whitepaper** could not be downloaded, live or archived. Live:
  `developer.arm.com/documentation/ddi0487/latest/` serves only a JavaScript SPA
  shell; a direct `curl` of the print URL returned HTTP 403 (Akamai CDN) even with a
  browser UA; the SPE whitepaper URLs returned 403/404. **Wayback/CDX follow-up
  (2026-07-10):** every `ddi0487` capture is a `text/html` landing page (~7–8 KB); the
  one archived `.pdf` URL (`.../ddi0487/bb/DDI0487B_b_armv8_arm.pdf`, snapshot
  `20220120090340`) fetched via `web/<ts>id_/` is 12 KB of HTML, **not** a PDF; no
  `application/pdf` asset for the Arm ARM or SPE whitepaper exists on any Arm CDN host
  in the archive. **GATED stands.** All ARM encodings in the page are grounded in the
  **in-kernel header** (`arm_pmuv3.h`, which mirrors DDI 0487's _"Performance Monitors
  Extension"_ chapter) and the **arm-data** JSON, not the PDF; SPE maps to the Arm
  ARM's _"Statistical Profiling Extension"_ chapter. Cited by chapter name + issue K.a,
  PDF not reproduced (permitted by the guardrails). `lit`. ◯

## Claims dropped / weakened

- **SM′ (Linux 5.17 date)** softened from a hard fact to `◯ lit`: the mechanism is
  fully source-verified, but the introducing kernel _version_ was not re-derived from
  git within the source-check timebox, so the page states it as known history and
  flags it as such.
- Nothing else was dropped; the page carries all 27 sub-report claims (C1–C27), the
  five quote candidates (Q1–Q5), the three experiments (E1–E3), and the added
  self-monitoring source-check (SM).

**Net:** 0 fabrications. Every ARM-Linux encoding/mechanism is source-verified against
`linux@e43ffb69e043`; the Apple sidebar is `[hw-verified: aarch64-darwin]` off
`mac-bsn` plus the Linux driver. **One open discrepancy** (D3, Apple fixed-counter
count 3-vs-2, ⚠ flagged not resolved); **one gated source** (D5, DDI 0487 / SPE
whitepaper, grounded via the in-kernel header instead). The self-monitoring
cross-check resolved **affirmatively** — arm64 does have the `rdpmc` userpage analog.
