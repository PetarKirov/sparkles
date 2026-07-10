# Ledger — synthesis pages (index · concepts · comparison · sparkles-baseline · backend-proposal)

> Not published research. Do not link to it from the survey pages.

Key: `✓` verified · `≈` paraphrase-verified · `⚠` discrepancy (see
[master register](./index.md)) · `◯` open / not locally groundable · `🌐` web.
Synthesis pages aggregate the deep-dives; rows below verify the claims these
pages _originate_ (aggregations, timeline entries, baseline observations) —
cell-level facts re-stated from a deep-dive are checked in that page's ledger.

## index.md

| #   | Claim                                                                                                                                   | Type     | Source                                                                                                               | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------- | ------ |
| I1  | Master-catalog verification beds per row (which pages carry hw tags)                                                                    | fact     | per-page ledgers                                                                                                     | ✓      |
| I2  | Timeline: PEBS ~2000 (NetBurst); IBS 2007 (Fam 10h); perf_event_open Linux 2.6.31 (2009); SPE Armv8.2 (2016); Sscofpmf + SBI 0.3 (2021) | fact     | `[literature]` — coarse, marked as such in-page                                                                      | 🌐     |
| I3  | Timeline: HCP min Windows 7; LBR public 19H1; raw ProfileSource 1903                                                                    | fact     | saved MS docs (`win-enablethreadprofiling.html`, `etw-trace-query-info-class.html`, `wpt-recording-pmu-events.html`) | ✓      |
| I4  | Timeline: PMUv3p5 64-bit event counters (Armv8.5); BRBE (Armv9.2)                                                                       | fact     | `arm_pmuv3.c:489-492`, `arm_brbe.c`                                                                                  | ✓      |
| I5  | Timeline: CTR ratified 2024-11-22; no Linux consumer at v7.1-rc6                                                                        | fact     | `riscv-ctr@42e299ca header.adoc`; tree grep                                                                          | ✓      |
| I6  | Timeline: M4 PMUv3-number remap (2024 silicon)                                                                                          | fact     | kpep plists + `cpc_arm64_events.c`                                                                                   | ✓      |
| I7  | Probe table (what each demonstrates, env: 6.18.26 / 7940HX / LDC 1.41)                                                                  | behavior | probe outputs in sub-reports; probes in `examples/`                                                                  | ✓      |

## concepts.md

| #   | Claim                                                                                       | Type        | Source                                                                            | Status     |
| --- | ------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------- | ---------- |
| C1  | Group all-or-nothing quote ("scheduled in as one unit only")                                | quote       | `kernel/events/core.c:2886`                                                       | ✓          |
| C2  | Scaling formula quote (`count = quot * enabled + …`)                                        | quote       | `include/uapi/linux/perf_event.h:685`                                             | ✓          |
| C3  | Counter budgets: 6 PMCs Zen 4; 5+2 exposed by kpc on M-series                               | figure      | sysfs (this host); mac-bsn Exp. a                                                 | ✓          |
| C4  | NMI watchdog occupies a counter (x86)                                                       | fact        | bench-baseline.md observation + perf.d calibration behavior; widely documented    | ≈          |
| C5  | Sscofpmf LCOFI = interrupt bit 13                                                           | fact        | `sscofpmf.adoc:69-91`; `csr.h:101`                                                | ✓          |
| C6  | IBS skid-0; PEBS assist; SPE buffer — engine one-liners                                     | fact        | `ibs.c:240-243`; `ds.c`; `arm_spe_pmu.c`                                          | ✓          |
| C7  | LBR 32 / BRBE ≤64 / CTR 16–256 depths                                                       | figure      | `[literature]` (LBR) / `arm_brbe.c:29-61` / `riscv-ctr body.adoc:161-208`         | ✓ (LBR 🌐) |
| C8  | MMAP2-while-enabled; `MISC_MMAP_BUILD_ID`; GUID+Age; LC_UUID                                | fact        | probe + `machine.c`; PE/Mach-O `[literature]`                                     | ✓/≈        |
| C9  | No libnuma VA→node helper; the two oracles; `QueryWorkingSetEx.Node`; Apple UMA             | fact        | R11; windows/macos ledgers                                                        | ✓          |
| C10 | Curation: HAL profile-sources; `RESTRICT_TO_KNOWN` 102 events on M4 Max                     | fact/figure | `wpt-recording-pmu-events.html`; `cpc_arm64_events.c:379-485`                     | ✓          |
| C11 | Gating: paranoid levels; SPE PA gate; `SeSystemProfilePrivilege`; "root or the blessed pid" | fact        | uAPI header; `arm_spe_pmu.c:873-877`; `etw-starttrace.html`; `kern_kpc.c:405-408` | ✓          |

## comparison.md

| #   | Claim                                                        | Type       | Source                                                                                     | Status           |
| --- | ------------------------------------------------------------ | ---------- | ------------------------------------------------------------------------------------------ | ---------------- |
| M1  | Capability-matrix cells                                      | fact       | each cell restates a deep-dive claim; verified in the owning page's ledger                 | ✓ (by reference) |
| M2  | "No naming layer spans OSes"                                 | fact       | event-naming ledger (libpfm4 `pfm_os_t`; LIKWID Linux-only; kpep/profile-sources OS-local) | ✓                |
| M3  | Consensus/trade-off tables (aggregation, no new facts)       | exposition | deep-dives                                                                                 | ✓                |
| M4  | Delta-table "sparkles today" column                          | behavior   | sparkles-baseline ledger rows B1–B14                                                       | ✓                |
| M5  | Open questions 1–4 (no ARM-Linux/RISC-V/Intel/multi-node hw) | fact       | `_sources.md` environment table                                                            | ✓                |
| M6  | SNC/NPS re-scope nodes/uncore; must re-probe per boot        | fact       | `[literature]` — flagged as such in-page                                                   | 🌐               |
| M7  | Third Apple fixed counter unresolved                         | ◯          | R18                                                                                        | ◯                |
| M8  | rdpmc bracket "~10× cheaper" figure in delta table           | figure     | `[literature]` order-of-magnitude (uAPI design intent); not measured here                  | 🌐               |

## sparkles-baseline.md

Observed-behavior rows; line numbers are the in-repo tree at survey date.

| #   | Claim                                                                                                                     | Type     | Source                                                              | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------- | ------ |
| B1  | 7-event group layout, leader cycles, `pid:0,cpu:-1`                                                                       | behavior | `perf.d:74-88,199-201`                                              | ✓      |
| B2  | `read_format = GROUP\|TOTAL_TIME_ENABLED\|TOTAL_TIME_RUNNING`; plain `read(2)`; no rdpmc/mmap                             | behavior | `perf.d:194-197`; `perf_group.d`                                    | ✓      |
| B3  | Calibration handshake: ~2 ms spin; `< 0.98` → drop LLC pair; zero-time → unavailable                                      | behavior | `perf.d:129-154,214-227`                                            | ✓      |
| B4  | Kernel+user → user-only fallback (`exclude_kernel`)                                                                       | behavior | `perf.d:158-168`                                                    | ✓      |
| B5  | Off-Linux stub, identical surface, `available == false`                                                                   | behavior | `perf.d:293-311`                                                    | ✓      |
| B6  | Bracket: RESET once; ENABLE→timed→DISABLE per iter; `between` untimed; per-pass time base (RESET zeroes values not times) | behavior | `perf_group.d:61-121`                                               | ✓      |
| B7  | tier0 = getrusage + `/proc/self/io` raw-read (`std.file` size-0 trap); self-cost median-of-9 subtracted                   | behavior | `tier0.d:218-248,335-369`                                           | ✓      |
| B8  | syscalls tier: `raw_syscalls:sys_enter` leader + ≤62 named; tracefs ids; `inherit=1`; root-only gate detected             | behavior | `syscalls.d:77-168`                                                 | ✓      |
| B9  | `MetricClass`/`MetricCell`/`MetricDescriptor` shapes as quoted                                                            | fact     | `metrics.d:29-63`                                                   | ✓      |
| B10 | `rowCells`/`catalog`/`visibleMetrics`/`selectsSource` render path; `--metrics` opens tiers transitively                   | behavior | `metrics.d:250-260,514-539,645-692`                                 | ✓      |
| B11 | Bencher protocol: double-until-5ms, 32 samples, median/MAD; MonoTime ticks; counting pass separate, capped 100k iters     | behavior | `bench.d:82-98,294-331,434-440`                                     | ✓      |
| B12 | "One field + one line in each of open/close/countInto" extension contract                                                 | quote    | `bench.d:377-419` module doc                                        | ✓      |
| B13 | wired bench reuses runner `--perf`; no private backend; per-byte derivation; LLC drop on this host (NMI watchdog)         | behavior | `runner.d:8-9`; `bench-baseline.md:22-24,63-99`                     | ✓      |
| B14 | Seven-concern absence table (concerns 2,3,4,6 absent; 5,7 partial)                                                        | behavior | absence of any sampling/symbolization/NUMA code in the five modules | ✓      |

## backend-proposal.md

| #   | Claim                                                                                                                                                       | Type       | Source                                                               | Status           |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------- | ---------------- |
| P1  | Design constraints imported (libpfm force-PMU; swfilt; rusage floor; CycleTime floor; oracles; MMAP2 hazard; addrinfo non-NULL; PMUSERENR/scounteren gates) | fact       | the owning deep-dive ledgers (R2, R10, R11, R13, R15, R19, R20, R22) | ✓ (by reference) |
| P2  | `isCounterBackend`/`Capability` D sketches compile-shaped against `metrics.d` seam                                                                          | exposition | design sketch — not compiled; marked as sketch                       | ◯                |
| P3  | Milestone dependency/effort ordering                                                                                                                        | opinion    | design judgment                                                      | ◯                |

**Net:** synthesis pages originate few facts; the load-bearing ones are ✓
against pinned artifacts. Deliberate `[literature]`/🌐 rows: coarse timeline
dates (I2), SNC/NPS caveat (M6), rdpmc cost figure (M8). Open: R18 (M7), and
the D sketches are design artifacts, not compiled code (P2).
