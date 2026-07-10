# Grounding ledger — `event-naming.md`

Claim-by-claim source verification of [`docs/research/cpu-pmu/event-naming.md`](../event-naming.md).
Every naming-layer claim is checked against a **local** pinned repo; the live round
trip (E1/E2) is `[hw-verified: x86_64-linux]` off the 7940HX box. `$REPOS = /home/petar/code/repos`.

Pinned trees (read-only): **libpfm4** `$REPOS/c/libpfm4@6870a9f` (perfmon2, cloned
from the canonical `git.code.sf.net/p/perfmon2/libpfm4`, **not** the `wcohen/libpfm4`
GitHub mirror — see [Discrepancies](#discrepancies)); **PAPI** `$REPOS/c/papi@ec16e00f`;
**LIKWID** `$REPOS/c/likwid@f23c6663`; **`intel/perfmon`** `$REPOS/cpu-pmu/intel-perfmon@683a4d0b`;
**linux** `$REPOS/linux@e43ffb69e043` (v7.1-rc6). Hardware bed: kernel **6.18.26**, AMD
**Ryzen 9 7940HX** (Zen 4, family 25 / model `0x61`), `perf_event_paranoid = -1`,
**libpfm 4.13.0** (nixpkgs), LDC 1.41.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                   |
| ---- | ------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)              |
| `≈`  | Faithful paraphrase / inference from absence (no single line to point at) |
| `⚠`  | Discrepancy — hypothesis refuted, or a hazard the page must flag          |
| `◯`  | Not locally groundable — synthesis/consequence, or cross-page dependency  |
| `🌐` | Web / secondary only (not asserted as a tree fact)                        |

**Types:** `quote` (verbatim) · `src` (repo source-read, `[source-verified]`) ·
`hw` (7940HX, `[hw-verified: x86_64-linux]`) · `lit` (`[literature]`) · `synth` (derived).

## Claim ledger

| #   | Claim (short)                                                                                          | Type   | Source (local + locator)                                                                                           | Status |
| --- | ------------------------------------------------------------------------------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------ | ------ |
| 1   | `pfm_get_os_event_encoding` signature; `pfm_perf_encode_arg_t` = 40 B on LP64 (ABI-checked)            | src    | `libpfm4 include/perfmon/pfmlib.h:1050`; `pfmlib_perf_event.h:37-45` (`PFM_PERF_ENCODE_ABI0 40`)                   | ✓      |
| 2   | `pfm_os_t` = `{NONE, PERF_EVENT, PERF_EVENT_EXT}` — **no non-Linux OS layer**                          | src    | `pfmlib.h:901-905`                                                                                                 | ✓      |
| 3   | PMU detection is CPUID-based (`cpuid(0)` vendor, `cpuid(1)` family/model), not `/proc/cpuinfo`         | src    | `lib/pfmlib_amd64.c:322-367` (`pfm_amd64_detect`, `amd64_get_revision`)                                            | ✓      |
| 4   | **git HEAD**: family 25 `model>=0x60 \|\| 0x10..0x1f` → `FAM19H_ZEN4` (covers `0x61`)                  | src    | `lib/pfmlib_amd64.c:191-196`                                                                                       | ✓      |
| 5   | **released 4.13.0**: only `model==17` (0x11) → ZEN4; `0x61` matches nothing → `PFM_ERR_NOTFOUND`       | src    | nixpkgs libpfm **4.13.0** realized `lib/pfmlib_amd64.c` family-25 branch                                           | ⚠ ✓    |
| 6   | Grammar delimiter `PFMLIB_ATTR_DELIM ":."`; `amd64_mods` = `k/u/e/i/c/h/g`                             | src    | `lib/pfmlib_priv.h:36`; `lib/pfmlib_amd64.c:37-44`                                                                 | ✓      |
| 7   | AMD encoding defaults `PERF_TYPE_RAW`; zeroes `EN/INT/OS/USR/GUEST/HOST` config bits → `exclude_*`     | src+hw | `lib/pfmlib_amd64_perf_event.c:59-116`; probe: `:u` keeps `config 0xc0`, sets `exclude_kernel=1`                   | ✓      |
| 8   | **No precise mode on AMD**; IBS modeled as flagged events (`AMD64_FL_IBSFE/IBSOP`), no selector        | src    | `pfmlib_amd64_perf_event.c:144`; `pfmlib_amd64.c:76-84,452-455` (`reg.ibsfetch.en`/`reg.ibsop.en`)                 | ✓      |
| 9   | ISA coverage: x86/ARMv6–v9/POWER4–10/SPARC/s390x/MIPS/Itanium/Cell; **∅ RISC-V**                       | src    | `lib/events/` (no `*riscv*`); `lib/` (no `pfmlib_*riscv*`)                                                         | ✓      |
| 10  | On 7940HX only `perf`/`perf_raw` present; zen4 table compiled-but-inert; 2 workarounds live            | hw     | probe E2; `strings libpfm.so.4.13.0 \| grep amd64_fam19h_zen4`; `pfmlib_common.c:1361-1401` (activation)           | ✓      |
| 11  | PAPI **vendors** libpfm4 (`src/libpfm4`, plain dir) and bridges it for encoding                        | src    | `papi src/libpfm4/`; `src/components/perf_event/pe_libpfm4_events.c:199-201`                                       | ✓      |
| 12  | Presets in `papi_events.csv`: `CPU,<pmu>` sections, `PRESET,<name>,<deriv>,<events>`; `DERIVED_*`      | src    | `papi src/papi_events.csv:8,10,17,20,514`                                                                          | ✓      |
| 13  | **PAPI zen4 + zen5 preset sections EXIST** (refutes "unmapped"); **∅ RISC-V / Apple**                  | src    | `papi_events.csv:514-515` (`amd64_fam19h_zen4`, `amd64_fam1ah_zen5`); only `arm_*` beyond x86                      | ⚠ ✓    |
| 14  | LIKWID does **not** use libpfm4; own event lists (`perfmon_zen4_events.txt`, "Thomas Gruber")          | src    | `grep -ril libpfm src/` → empty; `likwid src/includes/perfmon_zen4_events.txt`                                     | ✓      |
| 15  | `ACCESSMODE` = `PERF`(-1) / `DIRECT`(0) / `DAEMON`; direct/daemon reach uncore + frequency             | src    | `likwid.h:297-301`; `access.c`; `frequency_uncore.c:191` ("Cannot manipulate Uncore frequency with … perf")        | ✓      |
| 16  | Groups carry `EVENTSET` + `METRICS` + `LONG`; `CPI = CPU_CLOCKS_UNHALTED/RETIRED_INSTRUCTIONS`         | src    | `likwid groups/zen4/CPI.txt`                                                                                       | ✓      |
| 17  | LIKWID ships **Apple M1**, Graviton3, A64FX tables — wider OS/vendor axis than libpfm4/PAPI            | src    | `likwid src/includes/perfmon_{applem1,graviton3,a64fx,a57}_events.txt`                                             | ✓      |
| 18  | `intel/perfmon` JSON schema (`EventCode/UMask/EventName/…/PEBS/Deprecated`); `mapfile.csv` keying      | src    | `intel-perfmon mapfile.csv`; `SKX/events/*.json` (`"PEBS": "0"`)                                                   | ✓      |
| 19  | TMA/metric JSONs (`Level`, `Events[]`, `Formula`); `metrics/perf/` variant in perf syntax              | src    | `intel-perfmon ICX/metrics/icelakex_metrics.json`                                                                  | ✓      |
| 20  | **Provenance surprise**: `create_perf_json.py` self-generates the kernel's perf JSON                   | quote  | `intel-perfmon scripts/create_perf_json.py:12` ("OUTPUT: A perf json directory suitable for the tools/perf …")     | ✓      |
| 21  | **AMD asymmetry**: no public analogue; kernel `amdzen4/` AMD-authored, keyed `AuthenticAMD-25-…`       | src    | `linux tools/perf/pmu-events/arch/x86/{mapfile.csv,amdzen4/}`; `git log` (`Sandipan Das <sandipan.das@amd.com>`)   | ✓      |
| 22  | **Name-space divergence**: `RETIRED_INSTRUCTIONS` (libpfm) vs `ex_ret_instr` (kernel) for 0xc0         | src    | `amd64_events_fam19h_zen4.h:1603-1606` (`.code 0xc0`) vs `amdzen4/core.json:34-36` (`ex_ret_instr`, `0xc0`)        | ✓      |
| 23  | **No cross-OS naming layer**: Windows curated `ProfileSource`; macOS `kpep`; backend must own one      | lit≈   | claim 2 (libpfm Linux-only) + W5 [windows][w], W6 [macos][m]                                                       | ≈      |
| Q1  | _"This is the key function … The event string … may contains sub-event masks (umask) …"_               | quote  | `libpfm4 docs/man3/pfm_get_os_event_encoding.3:11-18`                                                              | ✓      |
| Q2  | _"suppress the bits which are under the control of perf_events … the OS/USR bits … exclude_\*"\_       | quote  | `lib/pfmlib_amd64_perf_event.c:98-114`                                                                             | ✓      |
| Q3  | _"No precise mode on AMD"_                                                                             | quote  | `lib/pfmlib_amd64_perf_event.c:144`                                                                                | ✓      |
| Q4  | _"OUTPUT: A perf json directory suitable for the tools/perf folder."_                                  | quote  | `intel-perfmon scripts/create_perf_json.py:12`                                                                     | ✓      |
| A1  | **Addition**: kernel `pmu-events` **does** carry per-vendor RISC-V JSON (sifive/thead/andes/…)         | src    | `linux tools/perf/pmu-events/arch/riscv/{sifive,thead,andes,openhwgroup,starfive}/`                                | ✓      |
| A2  | **Addition**: Intel event JSON carries a first-class `PEBS` field (vs AMD's flagged IBS)               | src    | `intel-perfmon SKX/events/*.json` (`"PEBS": "0"`)                                                                  | ✓      |
| A3  | **Addition**: `recommended.json` uses field `MetricExpr` (not `Formula`) for AMD perf metrics          | src    | `amdzen4/recommended.json:3-5` (`branch_misprediction_ratio`, `MetricExpr = d_ratio(ex_ret_brn_misp, ex_ret_brn)`) | ✓      |
| E1  | Round trip: generic→type0/0x0; native→type4/0xc0; umask→0x103 count **3,000,001**; `:u`→exclude_kernel | hw     | probe `pfm4-name-roundtrip.d` (verbatim block reproduced in-page)                                                  | ✓      |
| E2  | Auto-detect failure root cause + workarounds (`LIBPFM_FORCE_PMU`, `LIBPFM_ENCODE_INACTIVE`)            | hw+src | probe; realized 4.13.0 `pfmlib_amd64.c` family-25 branch (claim 5)                                                 | ✓      |

## Discrepancies

- **⚠ Hypothesis REFUTED — "PAPI presets unmapped on modern µarchs"** (claim 13). The
  prompt hypothesis is false for Zen 4/Zen 5: `papi_events.csv:514-515` has explicit
  `CPU,amd64_fam19h_zen4` **and** `CPU,amd64_fam1ah_zen5` sections with real `PRESET`
  rows. The page states the refutation directly (Overview note under PAPI) and cites the
  lines. What _is_ true is the inherited boundary: PAPI has no RISC-V and no Apple
  presets, because it vendors libpfm4.
- **⚠ Hazard — libpfm 4.13.0 auto-detect failure on model `0x61`** (claims 5, 10). Not a
  page error but a real design constraint the page must flag: the prompt-implied
  "`pfm_get_os_event_encoding('RETIRED_OPS')` just works" is **false on this box** —
  stock 4.13.0 fails to detect the family-25/model-`0x61` Zen 4 and returns
  `PFM_ERR_NOTFOUND`. Surfaced as the page's `[!WARNING]` (**The auto-detect hazard**);
  root cause confirmed against the realized 4.13.0 source, fix confirmed at HEAD
  (`pfmlib_amd64.c:191-196`), both workarounds proven live in E2. `hw`+`src`.
- **Provenance surprise — `intel/perfmon` self-generates the perf JSON** (claims 20–22).
  `create_perf_json.py` emits "a perf json directory suitable for the tools/perf folder"
  — Intel maintains the machine-readable upstream, whereas AMD contributes JSON straight
  into the kernel (`sandipan.das@amd.com`). Asymmetric provenance → asymmetric name
  spaces (`RETIRED_INSTRUCTIONS` vs `ex_ret_instr` for the same 0xc0). Documented in
  **The vendor-table asymmetry**; not a contradiction, a finding.
- **Enrichment — RISC-V is `∅` for four layers but present in the kernel** (addition A1).
  libpfm4/PAPI/LIKWID/`intel-perfmon` carry zero RISC-V tables, but `linux`'s
  `pmu-events/arch/riscv/` ships per-vendor JSON (sifive/thead/andes/openhwgroup/starfive).
  The page's coverage table and the ∅-RISC-V finding are sharpened accordingly (kernel is
  the sole exception), cross-linking [riscv][r]. Beyond the 23 sub-report claims but
  locator-grounded.
- **libpfm4 canonical-source note.** The pinned libpfm4 tree is the perfmon2 SourceForge
  repository (`git.code.sf.net/p/perfmon2/libpfm4`), **not** the widely-linked
  `wcohen/libpfm4` GitHub mirror. Chosen for canonicity: SourceForge is upstream, the
  mirror lags. The page's external libpfm4 links therefore point at
  `sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/…` (line anchors unavailable
  in the SourceForge tree view; locators are recorded in this ledger's `file:line` form
  instead). Recorded so a future reader does not "correct" the links to the mirror.

## Claims dropped / weakened

- **Claim 23 (no cross-OS naming layer)** is `≈ lit`: the libpfm-side half is
  source-verified (claim 2, Linux-only `pfm_os_t`); the Windows/macOS half is a
  cross-page dependency on [windows][w] / [macos][m] (W5/W6), stated as synthesis, not
  re-derived here.
- **Minor correction applied (A3):** the sub-report rendered the AMD metric field as
  `Formula`; the kernel's `recommended.json` field is actually `MetricExpr`. The page
  uses `MetricExpr = d_ratio(ex_ret_brn_misp, ex_ret_brn)` verbatim.
- **Released-4.13.0 detect (claim 5)** carries no browsable hyperlink — it is the nixpkgs
  _realized_ source, not a commit in the pinned SourceForge tree; grounded as the hazard
  and cited by version + branch shape, with the HEAD fix linked for contrast.
- Nothing else dropped; the page carries all 23 sub-report claims, the four quote
  candidates (Q1–Q4; the kernel-commit "Add Zen 4 core events" line is folded into
  claim 21), both experiments (E1/E2), and three locator-grounded additions (A1–A3).

**Net:** 0 fabrications. Every naming-layer mechanism is source-verified against the five
pinned repos; the live round trip and the auto-detect failure are `[hw-verified: x86_64-linux]`
on the 7940HX. **One refuted hypothesis** (PAPI presets — mapped, not missing, for
zen4/zen5) and **one flagged hazard** (libpfm 4.13.0 vs model `0x61`), both surfaced in
the page. The two prompt boundary questions are **both confirmed**: libpfm4 has ∅ RISC-V
(kernel-only) and no non-Linux OS layer.

<!-- References -->

[w]: ../windows.md
[m]: ../macos.md
[r]: ../riscv.md
