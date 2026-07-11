# `sparkles:test-runner` — Benchmark-measurement delivery plan

_Companion to [SPEC.md](./SPEC.md): the milestones that make the marked
target sections true. Each milestone is independently green (builds + tests +
lints). Two tracks interleave: the **M-track** (workload harness — the
[I/O-bench roadmap](#shipped-m1-m3-and-riders)'s M4–M11) and the **B-track**
(native PMU backends — the research
[backend proposal](../../research/cpu-pmu/backend-proposal.md)'s milestones
1–6, referenced here as B1–B6 to keep both numbering schemes unambiguous).
The audit of the shipped layer is
[sparkles-baseline.md](../../research/cpu-pmu/sparkles-baseline.md); the
gap-to-milestone mapping is the
[delta table](../../research/cpu-pmu/comparison.md#the-delta-table-the-survey-vs-the-sparkles-baseline)._

## Shipped: M1-M3 and riders

Merged via PR [#88](https://github.com/PetarKirov/sparkles/pull/88) and
audited by the baseline page:

- **M1 — metric catalog** (`metrics.d`): `MetricDescriptor`/`MetricCell`/
  `MetricClass`, `--metrics`/`--list-metrics`, transitive source opening
  (SPEC §5).
- **M2 — tier-0 counters** (`tier0.d`): `getrusage` + `/proc/self/io` deltas
  with calibrated self-cost subtraction (SPEC §6.1).
- **M3 — syscall tracepoints** (`syscalls.d`): in-process `strace -c` via
  `perf_event` tracepoints, tracefs-root-gated (SPEC §6.1, §9).
- Riders: `--bench-json` + `--bench-min-time`, `skipTest`, `--group-by`/
  `--sort-by`, the live results ticker, per-pass enabled/running multiplex
  deltas, raw-tick timing, `benchCase` matrix benchmarks (SPEC §3, §4, §7,
  §8).

The delta-table row "grouped counting, exact" is closed ("none — matches");
every other row maps to a milestone below.

## Design invariants

Carried from the original roadmap, amended by the research:

- **The catalog seam composes everything** (SPEC §5): a new source is one
  `Nullable!XStats` field, three lifecycle lines, and a cells/family pair.
- **Two source shapes** (SPEC §6.1): bracketed (per-iteration ioctl window)
  and snapshot/delta (window-friendly). **Degrade, never fail**; capability
  is a **runtime probe result**, never a compile-time assumption.
- **Quantitative vs diagnostic is structural** (SPEC §1): reported/gated
  numbers read only quantitative fields; diagnostic renders separately.
- **Acquisition stays pure D.** druntime's `core.sys.linux.perf_event`
  models the full ring-buffer/record/mmap-page ABI — even the B6 sampler
  needs no C shim. C libraries enter only as _soft_ dependencies that
  degrade to advertised absence: libpfm4 (B2) and libdw (B6) via dlopen or
  an opt-in build config; **never libnuma** (no `numa.pc`, the syscalls are
  not in glibc — call raw `get_mempolicy`/`move_pages`); no libtraceevent
  (it decodes caller-supplied buffers only — M9 scopes a small pure-D decode
  core instead). **Naming data is offline-only**: LIKWID / intel-perfmon /
  kernel pmu-events JSONs are references to harvest, never runtime deps.
  Nix: nixpkgs libpfm ships no `.pc` → devshell `buildInputs` +
  `NIX_LDFLAGS`, needed in **both** the shellHook and the `ci` wrapper (the
  research probes' proven CI path); elfutils (tested 0.194) enters
  `buildInputs` likewise if B6 takes the link-time arm.
- **Verification-bed honesty** (SPEC §9): the hardware beds are Zen 4 Linux
  (Ryzen 9 7940HX, `perf_event_paranoid = −1`) and M4 Max macOS (mac-bsn,
  unprivileged transcripts). ARM-Linux, RISC-V, Intel PEBS, multi-node NUMA,
  and Windows have **no hardware bed** — those aspects ship
  source-verified/literature-gated, with `skipTest` degradation and no
  `[hw-verified]` claims. All paranoid > −1 behavior is literature-derived
  until probed ([open-issues § O1](./open-issues.md)).
- **Units seam** (SPEC §5.3): symbol-as-label, `Mode` as the rate stand-in;
  all format semantics behind `scaled`/`fixed` so the `sparkles.quantities`
  convergence is localized ([open-issues § O6](./open-issues.md)).

## Milestone order

Interleaved by value; B-track numbers alias
[backend-proposal.md](../../research/cpu-pmu/backend-proposal.md) §2–§7.

| #   | ID  | Milestone                                                                | Gate / permissions                          |
| --- | --- | ------------------------------------------------------------------------ | ------------------------------------------- |
| 1   | B1  | Capability seam (`Capability`/`CapabilityReport`, backend trait)         | none                                        |
| 2   | B2  | Linux counting depth (raw events, naming, labeled scaling, rdpmc)        | none (soft libpfm4)                         |
| 3   | M4  | `@workload` window mode + wall decomposition                             | none                                        |
| 4   | M5  | PSI stall integrals                                                      | `CONFIG_PSI`                                |
| 5   | B3  | macOS floor (`proc_pid_rusage` counting tier)                            | none (mac-bsn verification)                 |
| 6   | M6  | Page-cache regime control + residency verify                             | `drop_caches` = root                        |
| 7   | M7  | Storage provenance fingerprint                                           | none                                        |
| 8   | M8  | cgroup-v2 isolation + `memory.max` sweep                                 | root / systemd delegation                   |
| 9   | B5  | Precise memory tier (IBS-first) + NUMA oracles + `LatencyHistogram`      | paranoid; IBS hardware                      |
| 10  | B6  | Sampling & symbolization (`--bench-profile`)                             | paranoid; `perf_event_mlock_kb`; soft libdw |
| 11  | M9  | Off-CPU profiler (rebuilt on B6) + biolatency floor                      | tracefs root (Tier B)                       |
| 12  | M10 | CO-safe open-loop load generator                                         | none                                        |
| —   | B4  | Windows floor (`CycleTime`; ETW elevated tier)                           | **blocked: no Windows hardware**            |
| —   | M11 | Gated spikes (eBPF, block tracepoints, SCHED_FIFO, ARM SPE/BRBE, RISC-V) | caps / hardware                             |

Sequencing rationale: B1 is pure reporting value and gives every later
milestone one absence vocabulary; B2 deepens the mode the harness lives in
today (raw events make wired's per-byte tables µarch-portable); M4 is the
keystone the workload track (M5–M8) hangs off; B3 kills the
"all counters vanish off Linux" cliff cheaply; B5/B6 add the _where_
dimension and are the only milestones with new soft C dependencies; M9 is
deliberately after B6 so its Tier B reuses the sampling infrastructure
instead of hand-rolling one; M10 is independent and can move earlier if
needed. Each milestone gets a detailed re-plan when reached.

Milestones that cite SPEC sections make those `(target)` passages true;
milestones without a citation (M7, M8, M10, M11) fold their surface into
SPEC as new sections when they land.

## B1 — Capability seam

> **Shipped** (branch `feat/test-runner-capability-seam`): `capability.d`
> (enum, report, trait, host probes), per-tier `capabilities()` observers,
> the `CounterGroups` merge, the `--list-metrics` block, and the
> report-derived bench-header notes. One design deviation from the research
> sketch, recorded in SPEC §6.2: `tryOpen` keeps returning the group
> (arities diverge; call sites depend on it) and `capabilities()` is a
> separate const observer; the reason map is an ordered absence array, not
> an AA. Acceptance verified on the dev box: `preciseMemory` absent with a
> "hardware present (ibs_op PMU)" reason, `eventTracing` absent via the
> tracefs gate, `--perf` table rendering unchanged.

_(backend-proposal §2; SPEC §6.2.)_ `Capability` bitflag enum (one flag per
survey concern plus real-world sub-splits: `counting`, `countingRaw`,
`countingScaled`, `selfMonitoring`, `ipSampling`, `preciseMemory`,
`symbolization`, `eventTracing`, `numaAttribution`, `eventNaming`);
`CapabilityReport { available; unavailableBecause }`; a DbI
`isCounterBackend` trait making `CounterGroups`' implicit contract nameable,
with optional primitives detected by presence. `--list-metrics` gains a
per-backend capability block; the bench header prints one line per
absent-but-requested capability.

Hardening from the grounding ledger: the proposal's D sketches are
**uncompiled design artifacts** (ledger P2) — compile-validate the trait
against `metrics.d` before freezing the seam. Workload-track sources (M5
PSI, M6 regime, M8 cgroup) adopt `CapabilityReport` too.

Acceptance: on the dev box the report reproduces the survey's findings —
`preciseMemory` present via `ibs_op`, `eventTracing` absent (tracefs `0700`);
`--perf` table output unchanged.

## B2 — Linux counting depth

> **Shipped** (branch `feat/test-runner-capability-seam`, four commits —
> one per capability): `raw.d` (`--metrics=raw:r<hex>` columns in their own
> counter group), `--perf-scaled` labeled estimates (`≈` cells,
> `estimatedMetrics` in schema-2 JSON — O4 resolved; sub-millisecond scaled
> passes render unavailable), `event_naming.d` (dlopen-soft libpfm4 with the
> ENCODE_INACTIVE + table-prefix recipe; `pfm:<name>` selectors), and
> `rdpmc.d` (the selfMonitoring primitive + the O2 bracket-cost
> measurement: ioctl pair 2.2 µs vs rdpmc read 30 ns vs read(2) 551 ns on
> the dev box — the rdpmc case asserts each read is real, not the index-0
> early exit). Switching the counting pass to the rdpmc bracket remains
> open-issue O2. A post-B2 adversarial review round (9 confirmed findings)
> hardened the estimate thresholds, the raw column visibility/dedup/
> truncation contracts, sort-by-header support, and the bracketCost
> measurement itself.

_(backend-proposal §3; SPEC §6.3, §7.)_ Four capabilities, all probed:

- **`countingRaw`** — `raw:r<hex>` selectors → `PERF_TYPE_RAW`; unlocks
  umask-qualified µarch events.
- **`eventNaming`** via **soft** libpfm4, with the proven recipe: encode
  through `PFM_OS_PERF_EVENT` (privilege modifiers land in
  `attr.exclude_*`, not config bits); **force tables from CPUID** — stock
  libpfm 4.13.0 misses Zen 4 model 0x61 — using `LIBPFM_ENCODE_INACTIVE=1`
  plus an explicit `table::` prefix, **not** `LIBPFM_FORCE_PMU` (exclusive:
  it breaks generic `cycles`/`instructions` resolution); the D binding must
  pin `pfm_perf_encode_arg_t` at exactly 40 bytes on LP64 (the ABI0 size
  check). Reference implementation:
  [`pfm4-name-roundtrip.d`](../../research/cpu-pmu/examples/pfm4-name-roundtrip.d).
  Absent libpfm → `eventNaming` advertised absent; numeric selectors still
  work.
- **`countingScaled`** (opt-in, labeled): enabled/running scaling per the
  uAPI formula, with the SPEC §6.3 quality gates — `running == 0` renders
  "not counted", never 0; sub-millisecond running slices are flagged (the
  probe measured a 5.7× scale error on a 0.58 ms slice); `--bench-json`
  marks estimated cells ([open-issues § O4](./open-issues.md)). Default
  stays exact-or-drop. The seam includes the **group-refused** branch
  (RISC-V refuses unplaceable groups outright).
- **`selfMonitoring`** — rdpmc mmap-page seqlock fast path for very short
  bodies; `cap_user_rdpmc` is arch-set and policy-disableable, so probe and
  keep the `read(2)` fallback; PMUSERENR (ARM) / `scounteren` (RISC-V) share
  the flag per-ISA. **Measure the "~10× cheaper" literature claim on-host
  before advertising it** ([open-issues § O2](./open-issues.md)).

## M4 — `@workload` window mode

_(SPEC §1, §3, §4.)_ New `@workload` marker + `isWorkload` trait;
`WorkloadWindow` (deliberately **not** `BenchStats` — its per-iteration
fields misrepresent a single window), `runWorkload`, in-body
`workloadWindow`; the phase-model driver and `WallDecomposition` with its
honesty caveats (only runqueue + disk are true per-cause durations; PSI-io
can overlap runqueue, so the residual clamps at 0 with a status note).
Renders as its own table. Research amendments: sources report through B1's
`CapabilityReport`; never assume 4 KiB pages / 64 B lines in window
accounting (Apple Silicon: 16 KiB / 128 B). JSON serialization of windows is
[open-issues § O7](./open-issues.md).

## M5 — PSI stall integrals

_(SPEC §4.)_ `PsiSource` (snapshot/delta): parse the monotonic `total=<µs>`
accumulator from `/proc/pressure/{io,memory,cpu}` (ignore the decaying
averages); window delta = stall-time integral (quantitative); feeds
`WallDecomposition.offCpuDisk`. Per-cgroup `*.pressure` reuses the parser
under M8. `CONFIG_PSI=n` → absence via B1's vocabulary.

## B3 — macOS floor

_(backend-proposal §4; SPEC §9.)_ `proc_pid_rusage(RUSAGE_INFO_V4)` →
`ri_instructions`/`ri_cycles` as a snapshot-pair tier: true unprivileged
instructions/cycles/IPC — richer than Linux tier-0 — with the honest scope
note (process-wide fixed counters, not per-bracket configurable events).
Capability ads for the rest: kpc is root-or-blessed-pid with the
`RESTRICT_TO_KNOWN` allowlist (102 events on T6041) and single-owner `EBUSY`
(Instruments running) as a distinct status; **no DTrace cpc provider
exists — never plan that route**; sampling is xctrace-brokered only.
kpep-plist parsing (world-readable, keyed by `hw.cpufamily`) is the naming
groundwork — **never hardcode Apple selectors**: M4/M5 chips remapped the
common events onto PMUv3 architected numbers while M1–M3 use Apple numbers,
and the fixed-counter count is itself unresolved
([open-issues § O8](./open-issues.md)). Portability rider shared with M7: on
P/E-core hosts (`hw.nperflevels`) record per-run core-type provenance.
Verification: mac-bsn transcripts (no darwin CI; build with `ldc2` directly —
dub fork-ENOMEMs on that box).

## M6 — Page-cache regime control

_(SPEC §4.)_ `CacheRegime { cold, warm, steadyState }`; in-body
`workloadFiles(regime, paths)`; cold = `posix_fadvise(DONTNEED)` per file
(drop_caches only as root, else downgrade + note); warm = explicit preload;
residency verified via `mmap` + `mincore` before/after, stamped on every row
(`CacheRegimeStamp{requested, effective, residentFraction*, note}`).
Validity probes: tmpfs ⇒ cold impossible (`effective = steadyState`); zfs ⇒
cold partial (ARC survives — noted). Amendments: page-size portability
(16 KiB pages change `mincore` stride and working-set math); B5's
data-source columns are the future diagnostic "why" for regime effects.

## M7 — Storage provenance fingerprint

Run-level `StorageProvenance{fsType, mountOptions, ioScheduler, deviceClass,
readaheadKb, thpState, ioModel}` from pure `/proc` + `/sys` reads; declared
(not sniffable) properties render "declared, not measured"; prints as a
header banner; degrades field-by-field. Amendment: **re-probe topology per
boot** — SNC/NPS BIOS modes multiply visible NUMA nodes and re-scope uncore
counters; never cache node counts across configuration changes.

## M8 — cgroup-v2 isolation and `memory.max` sweep

`CgroupV2{tryCreate, moveSelfIn, setMemoryMax, readStat, destroy}` +
`CgroupStat` (workingset_refault, file, ioR/Wbytes, cpuUsageUs,
memPressureTotalUs). Two uses: clean per-window accounting, and
`memoryMaxSweep(caps, body)` → a performance-vs-cache-size curve rendered as
sibling rows. Permission reality: root or systemd user delegation
(`systemd-run --user --scope -p Delegate=yes`); anything less →
`tryCreate` fails → keep per-process counters, report absence via B1.

## B5 — Precise memory tier

_(backend-proposal §6; SPEC §8.1, §9.)_ Engine-select-then-configure:
**probe the `ibs_op` sysfs PMU before `cpu/caps/max_precise`** — gating on
`max_precise` alone silently excludes all AMD. The hw-verified IBS recipe:
`sample_type = IP|ADDR|DATA_SRC|WEIGHT|PHYS_ADDR`; **privilege filtering via
the `swfilt` bit (`config2:0`) — bare `exclude_kernel` is `EINVAL` on Zen 4
and `exclude_hv` is never accepted**; the degrade ladder drops `PHYS_ADDR`
first (the privilege-gated field); hardware load-latency pre-filter
(`config1` threshold in [128, 2048] cycles) iff `IBS_CAPS_OPLDLAT`. One
vendor-neutral `perf_mem_data_src` decoder (the composite
`mem_lvl_num`/`mem_remote`/`mem_hops`/`mem_snoopx` fields, not the
deprecated `PERF_MEM_LVL_*` namespace). `WEIGHT` latency aggregates **only
over DC-miss load samples** (valid-bit gating); hit/miss level histograms
render separately. Page→node attribution via raw
`get_mempolicy(MPOL_F_NODE|MPOL_F_ADDR)`/`move_pages` (per-arch syscall
numbers tabulated in the probe). libpfm strips precise attrs on AMD — the
IBS-vs-PEBS split lives in backend logic, not the naming layer. The PEBS
branch is structurally present but Intel-hardware-gated (`skipTest`); SPE is
deferred (AUX buffer + MIDR-dispatched decode tables; no aarch64-linux bed).
Cross-node classification tests `skipTest` on single-node hosts. Reference
implementation:
[`mem-latency-numa.d`](../../research/cpu-pmu/examples/mem-latency-numa.d).
All columns `diagnostic`. **Introduces the shared GC-free `LatencyHistogram`
module** (log-linear buckets) as its percentile carrier — M9 and M10 consume
it later (first consumer introduces, keeping every milestone green).

## B6 — Sampling and symbolization

_(backend-proposal §7; SPEC §7, §8.1.)_ `--bench-profile`: a third pass
(like counting — never touching the timing pass) that turns "IPC fell" into
"IPC fell in `sumSquares` at `readers.d:137`".

- **Pure-D ring consumer**: acquire-load `data_head`, process, release-store
  `data_tail`; account `PERF_RECORD_LOST` so aggregates are never silently
  biased. Ring size gated by `perf_event_mlock_kb`.
- **Address-space model synthesized from `/proc/self/maps` at enable time** —
  `PERF_RECORD_MMAP2` arrives only for mappings created while enabled
  (hw-verified: zero records for pre-existing code) — with build-id
  validation modeled on perf's `dso__build_id_mismatch` (the stale-binary
  hazard is a bench-harness reality: rebuilt binary vs old-run comparison).
- **Symbolization via soft libdw**: `dwfl_report_elf` →
  `dwfl_module_addrinfo` (**`offset`/`sym` arguments non-NULL — NULL
  segfaults, hardware-hit**) → `dwfl_module_getsrc`; **inline attribution
  from day one** (`dwarf_getscopes` chains, innermost-first) — benchmark
  binaries are `-O` builds, so hot LDC-inlined leaves otherwise
  misattribute to their callers; **`pc -= 1` before symbolizing
  non-activation caller frames**. Absent libdw ⇒ `symbolization` advertised
  absent, samples still counted.
- **Optional DWARF-CFI unwind** (`REGS_USER` + `STACK_USER`; hw-verified
  5-frame backtrace on a `--frame-pointer=none` build); the perf→DWARF
  register map is **x86-64-only** — per-ISA gate.
- Output: per-case flat top-N profile (with inline chains) as a `diagnostic`
  section. Reference implementations:
  [`sampling-symbolize.d`](../../research/cpu-pmu/examples/sampling-symbolize.d),
  [`unwind-stack-user.d`](../../research/cpu-pmu/examples/unwind-stack-user.d).

## M9 — Off-CPU profiler and biolatency floor

Rebuilt on B6. Tier A (zero-perm floor): helper-thread sampling of
`/proc/self/task/*/{stat,wchan}` → off-CPU %-by-state + wchan histogram.
Tier B: **B6's ring consumer pointed at `sched:sched_switch`** — callchain
at switch-out, switch-out→in pairing per tid, symbolization from B6 (the
old hand-rolled maps/symtab/demangle layer is dropped). Tier B additionally
needs what B6 does not provide: **typed tracepoint decode** of the
`PERF_SAMPLE_RAW` blob against the tracefs `format` schema — name-based
field lookup, never fixed struct casts (offsets shift across kernels), plus
a string/array getter (`prev_comm`) — scoped as a small pure-D decode core
(libtraceevent's decode split without the C dependency; it does no tracefs
I/O anyway). Tier B's gate is tracefs readability (root-only `0700` on
hardened hosts — the same gate as `--syscalls`, independent of paranoid).
**biolatency here is the `/proc/diskstats` delta floor only**; the
block-tracepoint tier stays in M11. Consumes B5's `LatencyHistogram`.
Rendered as labeled blocks below the numeric table.

## M10 — Open-loop load generator

`driveOpenLoop(request, LoadSchedule)`: precomputed intended send times
(fixed or Poisson), absolute-deadline wakeups
(`clock_nanosleep(TIMER_ABSTIME)`), **latency measured from the intended
send time** — the structural coordinated-omission fix; a naive actual-send
clock is prohibited. Overload surfaces as queue depth + schedule skew, never
silent throttling. Driver hot path is allocation-free; server counters are
per-tid or cgroup-scoped so driver overhead never pollutes them. Intended
latency histogram (B5's `LatencyHistogram`) is the quantitative headline;
service latency and backpressure are diagnostic.

## B4 — Windows floor (blocked)

_(backend-proposal §5; SPEC §9.)_ Blocked on a Windows hardware bed — the
Wine cross pipeline only proves the degrade path, and nothing on this
platform is hw-verified. Scope when unblocked: driver-free `CycleTime` via
`EnableThreadProfiling`/`ReadThreadProfilingData` (winbase.h, Win 7+);
elevated ETW PMC tier (admin + `SeSystemProfilePrivilege`; 3–4 PMC hard
budget with **no enabled/running scaling — size groups to fit or split
runs**); `QueryWorkingSetEx` as the `move_pages` analog for NUMA groundwork;
bindings vendored from the windows-d generated modules, not hand-written
`extern(Windows)`. Explicit infeasibility verdicts to encode: public
PEBS-class sampling absent; arbitrary event registration is system-global
only (out of scope). Version floors: LBR Win10 19H1+, raw ProfileSource
1903+.

## M11 — Gated spikes

Feasibility-spike-first items, each behind a runtime permission probe:

- **eBPF off-CPU** (in-kernel aggregation): pursue only after a spike proves
  cross-kernel verifier acceptance and the permission probe passes; dead by
  default where `unprivileged_bpf_disabled=2`.
- **Block-tracepoint biolatency** (system-wide; paranoid ≤ 0 / CAP_PERFMON).
- **Load-gen follow-ons**: subprocess/socket targets, `SCHED_FIFO` driver
  pinning (CAP_SYS_NICE), client-tail ↔ server-PSI correlation.
- **ARM-Linux validation bundle** (when an aarch64-linux bed exists):
  big.LITTLE cpumask-PMU discipline plus a "counted 0 with enabled > 0"
  sanity check (wrong-cluster opens count zero silently); `exclude_idle` is
  `EOPNOTSUPP` on PMUv3; event presence is **three-tier** (`PMCEID*`
  bitmaps for the common `0x00–0x3F` set; `0x40+` IMPDEF; `0x4000+`
  arch-extension); SPE and BRBE as separate gated items.
- **RISC-V bundle** (spec-driven; no hardware): a capability subset by
  construction — counting always (SBI), sampling iff Sscofpmf, `exclude_*`
  iff Sscofpmf, precise/data-source permanently absent, branch records
  blocked until a `riscv_ctr.c` consumer lands; skid on the sampled `xepc`
  is unremovable (document, don't fix); event names only from vendored
  kernel pmu-events JSON (libpfm4/PAPI/LIKWID have no RISC-V tables).

## Cross-cutting honesty

Ship these caveats; never paper over them:

- **Quantitative vs diagnostic is enforced structurally** — reductions
  producing reported/gated numbers read only quantitative fields.
- **"Not counted" is not zero**; multiplex estimates are labeled everywhere
  they appear, including `--bench-json`.
- **Off-CPU by cause without eBPF is partial**: runqueue + disk are real
  durations; lock/sleep is a count annotation on a clamped residual.
- **Cache regime is stamped `effective`** (tmpfs ⇒ cold impossible; zfs ⇒
  partial; drop_caches ⇒ root) so mismatched runs are never compared.
- **Coordinated omission is an invariant** (intended-time latency
  mandatory).
- **Permissions degrade, never fail** — and the paranoid/tracefs/per-field
  gates are independent axes, each probed separately; the paranoid > −1
  matrix is literature-derived until probed.
- **The MMAP2/build-id stale-binary hazard** applies to every self-profiling
  feature: synthesize mappings, validate build-ids.
- **The event vocabulary is harness-owned** — no naming layer spans OSes.
- **User-stack quality is build-flag dependent**, softened by B6's CFI
  unwind; **big.LITTLE wrong-cluster opens count zero silently** — keep the
  sanity check.

## Verification

Every milestone lands as independently green commits: full suites
(`dub test :test-runner-impl -- --self-test`, `dub test :base`,
`nix run .#ci -- --test --fail-fast`), plus per-milestone gates:

- **B1** — `--list-metrics` shows the capability block; on the dev box the
  report matches the survey (preciseMemory via `ibs_op`; eventTracing
  absent); `--perf` table output unchanged.
- **B2** — `--metrics=raw:r<hex>` counts on the dev box; libpfm-absent build
  still passes with `eventNaming` reported absent; scaled cells carry the
  estimate marker; rdpmc bracket cost measured and recorded.
- **M4/M5** — window rows render with decomposition; Σ(parts) ≤ wall with
  clamped residual; PSI-less kernel degrades with a reason.
- **B3** — mac-bsn transcript shows instructions/cycles/IPC columns
  unprivileged; Linux/stub builds unchanged.
- **M6–M8** — regime stamps present on every row; tmpfs downgrade observed;
  unprivileged cgroup run reports absence and still passes.
- **B5/B6/M9** — parity runs against the research probes
  (`mem-latency-numa.d`, `sampling-symbolize.d`, `unwind-stack-user.d`);
  `skipTest` on hosts lacking IBS/paranoid headroom; profile sections render
  below tables, never as columns.
- **M10** — CO self-test: an injected stall shows up in intended-time
  latency; schedule-skew reported.

Every backend ships its Linux (or per-OS) body plus an identical-surface
stub, and environment-dependent tests call `skipTest(reason)`.
