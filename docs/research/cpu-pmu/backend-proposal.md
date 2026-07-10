# Native CPU-PMU backends for sparkles: enhancement proposal

A milestoned plan for a thin per-OS acquisition core under the sparkles
benchmarking harness, sketched in D against the existing
[`metrics.d` seam][baseline-seam] — `MetricDescriptor`/`MetricCell`/
`MetricClass` plus the `CounterGroups` open/close/count contract. Each backend
**advertises capabilities** aligned with the survey's [seven concerns][spine];
the harness reports _"capability unavailable"_ instead of silently degraded
results. Every milestone cross-links the prior art it borrows from.

**Last reviewed:** July 11, 2026

| Field            | Value                                                                                      |
| ---------------- | ------------------------------------------------------------------------------------------ |
| Target           | `sparkles:test-runner --bench` + [`wired` runtime bench][wired-bench]                      |
| Composition seam | [`MetricDescriptor`/`MetricCell`/`MetricClass`][baseline-seam] + `CounterGroups`           |
| Baseline audited | [sparkles-baseline.md][baseline] (gap analysis §[Gap analysis][baseline-gaps])             |
| Evidence base    | [comparison.md][comparison] capability matrix + the per-subject deep-dives                 |
| Shape            | 6 milestones: seam → Linux depth → macOS floor → Windows floor → precise memory → sampling |

---

## 1. Abstract & problem statement

The [baseline][baseline] is a Linux-only counting layer with a closed set of
seven generic events and honest-but-empty stubs elsewhere. The survey found
that (a) Linux exposes far more than the layer uses — per-microarchitecture
[event vocabularies][naming], [multiplex-scaled estimates][c-multiplex],
[user-space counter reads][c-rdpmc], [precise memory sampling][precise], and a
complete decode stack; (b) macOS and Windows have real, _smaller_ floors — an
unprivileged per-process instructions/cycles read on macOS
([`proc_pid_rusage`][macos], `[hw-verified: aarch64-darwin]`) and a
driver-free `CycleTime` plus admin-gated ETW counting on Windows
([windows.md][windows]); and (c) no existing library spans these — [libpfm4
has no RISC-V and no non-Linux OS layer, and nothing portable names events
across OSes][naming-boundary].

The conclusion the proposal operationalizes: **the harness must own a small
capability-typed backend interface**, implement it per OS at whatever depth
that OS permits, and make every absence explicit. Linux advertises the full
set across ISAs; Windows/macOS advertise subsets; the reporting layer renders
what is advertised and _names_ what is not.

Non-goals: a general profiler UI; kernel-driver work on any OS; wrapping
closed vendor drivers (VTune SEP / uProf).

---

## 2. Milestone 1: the capability-typed backend seam

**Goal:** make "what can this host measure?" a first-class, reportable value,
and turn `CounterGroups`'s implicit contract into an interface new backends
implement.

### 2.1 The capability model

One flag per survey concern (plus sub-capabilities where the survey found
real-world splits), advertised per backend instance _after_ its open
handshake — capability is a **runtime probe result**, never a compile-time
assumption ([privilege gating][c-privilege] varies per box: `paranoid`,
tracefs modes, SIP, allowlists).

```d
/// What an opened backend can actually deliver on this host, this run.
enum Capability : uint
{
    none            = 0,
    counting        = 1 << 0,  /// concern 1: scalar counting
    countingRaw     = 1 << 1,  ///   + raw/µarch-specific event selectors
    countingScaled  = 1 << 2,  ///   + multiplexed estimates (labeled)
    selfMonitoring  = 1 << 3,  ///   + user-space reads (rdpmc/PMUSERENR)
    ipSampling      = 1 << 4,  /// concern 2: overflow/IP sampling
    preciseMemory   = 1 << 5,  /// concern 3: data-source/address sampling
    symbolization   = 1 << 6,  /// concern 4: address → symbol/line
    eventTracing    = 1 << 7,  /// concern 5: OS-event gating (tracepoints/ETW)
    numaAttribution = 1 << 8,  /// concern 6: page → node classification
    eventNaming     = 1 << 9,  /// concern 7: name → encoding tables
}

struct CapabilityReport
{
    Capability available;
    /// Why each absent capability is absent — rendered by --list-metrics
    /// and the bench header, e.g. "preciseMemory: no IBS/PEBS PMU (cpu
    /// max_precise=0)" or "eventTracing: tracefs ids unreadable (0700)".
    string[Capability] unavailableBecause;
}
```

### 2.2 The backend interface

Design-by-Introspection like the rest of sparkles: a backend is any type with
the required primitives; optional primitives unlock optional capabilities
(same pattern as the [DbI guidelines][dbi]). The required surface is exactly
what `CounterGroups` already demands of a tier, made nameable:

```d
enum isCounterBackend(B) =
       is(typeof(B.init.tryOpen()) == CapabilityReport)
    && is(typeof(B.init.close()))
    && is(typeof(B.init.family(true)) == MetricDescriptor[])
    && is(typeof((ref BenchStats row, scope void delegate() timed,
                  scope void delegate() between, ulong iters)
              => B.init.countInto(row, timed, between, iters)));
// Optional: B.preciseSample(...), B.classifyPages(...), B.resolveName(...)
// — presence detected by introspection, reflected in the CapabilityReport.
```

`BenchStats` grows one `Nullable!XStats` per backend exactly as today
([the documented one-field-plus-three-lines contract][baseline-seam]); the
catalog seam is untouched — a backend ships its `XCells`/`XFamily` pair and
every downstream consumer (table, `--metrics`, `--list-metrics`,
`--bench-json`) works unchanged.

### 2.3 Reporting absences

`--list-metrics` gains a per-backend capability block, and the bench header
prints one line per _absent-but-requested_ capability from
`unavailableBecause`. Acceptance: on the survey's own hosts the report matches
the survey's findings — the Zen 4 box shows `preciseMemory` present via
`ibs_op` but `eventTracing` absent (root-only tracefs, as
[today's `--syscalls` correctly detects][baseline]); mac-bsn shows `counting`
present-unprivileged only as process-scope rusage.

**Borrows:** the availability handshake and status-string discipline of
[`perf.d`][baseline]; the "absence is a finding" spine of the
[comparison matrix][comparison].

---

## 3. Milestone 2: Linux counting depth (naming, scaling, self-monitoring)

**Goal:** lift the three counting-tier gaps the audit found, in place, behind
`Capability` flags.

### 3.1 `countingRaw` + `eventNaming`

Accept raw selectors (`--metrics 'raw:r04c2'`-style, mapping to
`perf_event_attr{type: RAW, config: 0x…}`) and, optionally, _named_
µarch events resolved through libpfm4 when present. Two survey findings
constrain the design ([event-naming.md][naming]):

- **Auto-detect lags silicon.** Stock libpfm 4.13.0 fails to detect the Zen 4
  test box (family 25/model `0x61`) — the backend must resolve the PMU name
  from CPUID itself and force it (`LIBPFM_FORCE_PMU` semantics via the API),
  not trust `pfm_initialize` detection. `[hw-verified: x86_64-linux]`
- **Modifiers ride `exclude_*`.** The `:u`/`:k` grammar maps to attr fields,
  not config bits — the probe [pfm4-name-roundtrip.d][ex-pfm4] demonstrates
  the exact round trip the backend needs, including the 40-byte
  `pfm_perf_encode_arg_t` ABI check.

libpfm4 stays a _soft_ dependency (dlopen or link-time optional): without it,
`countingRaw` still works with numeric selectors; `eventNaming` is advertised
absent with reason "libpfm unavailable".

### 3.2 `countingScaled`

Where a requested event set exceeds the PMU (the baseline's LLC-drop
scenario), offer labeled estimates instead of silent column loss: read
`time_enabled`/`time_running`, scale by the [kernel-documented
formula][c-multiplex], and render scaled cells with an explicit marker (the
survey's [counting probe][ex-counting] validates the estimate to ~1% on a
10-events-on-6-PMCs oversubscription, and also shows the failure mode — a
5.7× scale from a 0.58 ms slice is visibly noisy, hence _labeled_).
Default stays exact-or-drop; scaling is opt-in.

### 3.3 `selfMonitoring`

For very short bodies where the per-iteration `ioctl`/`read` bracket dominates,
add an rdpmc fast path: mmap the leader's `perf_event_mmap_page`, check
`cap_user_rdpmc`, and read counters in-loop via the documented seqlock
(`lock`/`index`/`offset`/`pmc_width` — [linux-perf-events.md][linux] quotes
the uAPI pseudocode verbatim). On ARM the same userpage is gated by
`PMUSERENR`/`perf_user_access` ([arm.md][arm]); on RISC-V by `scounteren`
([riscv.md][riscv]) — same capability flag, per-ISA probe.

**Borrows:** [`perf_group.d`][baseline]'s bracket (unchanged for the syscall
path); the uAPI rdpmc contract; libpfm4's encoding pipeline; the
[wired bench][wired-bench]'s need for per-byte normalization (raw events make
`cyc/B` per-engine tables µarch-portable).

---

## 4. Milestone 3: the macOS floor

**Goal:** replace the empty Darwin stub with the two things macOS actually
permits unprivileged, per [macos.md][macos] (`[hw-verified: aarch64-darwin]`).

- **`counting` (process scope):** `proc_pid_rusage(RUSAGE_INFO_V4)` →
  `ri_instructions`/`ri_cycles` — true retired instructions and cycles with no
  root and no entitlement (measured IPC 2.82 on mac-bsn). Delivered as a
  tier-0-style backend: snapshot pairs around the counting pass, per-iteration
  averages, `quantitative` class. Note the scope honestly: process-wide fixed
  counters, not per-bracket configurable events.
- **Capability ads for the rest:** configurable per-region events →
  `unavailableBecause = "kpc requires root ('root or the blessed pid',
xnu kern_kpc.c); event allowlist RESTRICT_TO_KNOWN"`; sampling/symbolication
  → "via Instruments/xctrace only". An _optional_ root-mode `kpc` backend
  (dlopen `kperf.framework`, kpep-plist naming) is sketched but explicitly
  deferred — the survey shows even root cannot program unlisted selectors, and
  the private-framework surface is unstable across releases.

Build note: the mac toolchain path is `ldc2` driven directly (dub
fork-ENOMEMs on the reference box); the backend is version-gated D in the same
modules, no new packages.

**Borrows:** the [three-tier privilege map][macos] (rusage / kpc / xctrace)
and its EPERM matrix; [tier0.d][baseline]'s snapshot-pair shape.

---

## 5. Milestone 4: the Windows floor

**Goal:** a Windows backend advertising exactly what an unelevated (and,
separately, an elevated) process can get, per [windows.md][windows].

- **`counting` (thread scope, driver-free):** `EnableThreadProfiling` /
  `ReadThreadProfilingData` → `CycleTime` only — the sole hardware datum that
  needs no kernel driver. Rendered as one `quantitative` column; the 16
  `HwCounters` slots are advertised absent with reason "requires
  KeSetHardwareCounterConfiguration driver (system-global, single-tenant)".
- **`counting` under elevation (later, optional):** ETW kernel-logger PMC
  counting on context switches (`TracePmcCounterListInfo`), admin +
  `SeSystemProfilePrivilege` gated; consumption model per krabsetw.
- **`numaAttribution` groundwork:** `GetLogicalProcessorInformationEx` +
  `QueryWorkingSetEx` (the `move_pages`-query analog) — cheap, documented,
  unprivileged.
- **D bindings:** druntime `core.sys.windows` covers only DbgHelp+psapi;
  the HCP/ETW/NUMA declarations are pulled from the `windows-d` generated
  modules (`hardwarecounterprofiling.d`, `etw.d`, `systeminformation.d`,
  `processstatus.d`) rather than hand-written `extern(Windows)` prototypes.

**Borrows:** the [W1-role-replacement table][windows] (which Linux role each
Windows surface substitutes); krabsetw's session/provider split for any future
ETW work.

---

## 6. Milestone 5: precise memory tier (Linux)

**Goal:** a `preciseMemory` backend delivering data-source / latency /
address→node columns on hardware that has an engine, per
[precise-sampling.md][precise].

- **One decoder, three engines.** Target the vendor-neutral
  [`perf_mem_data_src`][c-datasrc] union; open `ibs_op` on AMD (with the
  **`swfilt` recipe** — bare `exclude_kernel` is `EINVAL` on Zen 4
  `[hw-verified: x86_64-linux]`), `cpu` + `precise_ip` on Intel (PEBS), SPE on
  ARM (deferred until aarch64-linux hardware exists to verify against —
  advertised absent with reason until then).
- **Node classification.** Sampled data addresses classified via the raw
  `get_mempolicy(MPOL_F_NODE|MPOL_F_ADDR)` / `move_pages` query oracles (no
  `libs "numa"` link — numactl ships no `numa.pc` and the syscalls aren't in
  glibc; the probe [mem-latency-numa.d][ex-mem] is the reference
  implementation). The IBS "remote" bit alone is _not_ node attribution —
  hardware says remote/local, the oracle says which node.
- **Rendering.** New `diagnostic` columns: latency percentiles
  (`WEIGHT`), data-source level distribution, local/remote split. All absent
  (with reasons) on hosts without an engine — exactly what the capability
  seam exists for.

**Borrows:** the IBS attr matrix and decode tables from the survey
experiments; [libnuma.md][libnuma]'s missing-helper finding; the
[single-NUMA-node caveat][precise] (cross-node classification remains
`[literature]`-verified until multi-socket hardware is available — an open
question carried in [comparison.md][comparison-open]).

---

## 7. Milestone 6: sampling & symbolization tier (Linux)

**Goal:** `ipSampling` + `symbolization` — turn "IPC fell" into "IPC fell in
`sumSquares` at `readers.d:137`".

- **Ring-buffer consumption is pure D.** druntime's
  `core.sys.linux.perf_event` already carries the mmap page, record headers,
  and sample formats — the survey's [sampling probe][ex-sampling] consumes
  `PERF_RECORD_SAMPLE`/`MMAP2` with no C shim.
- **Address-space model + build-id discipline.** `PERF_RECORD_MMAP2` arrives
  only for mappings created _while enabled_; pre-existing code comes from
  `/proc/self/maps` (or `dwfl_linux_proc_report`, which reads the same file).
  Build-ids are validated before symbolizing — the [stale-binary
  hazard][c-buildid] is a bench-harness reality (rebuilt-binary + old-run
  comparisons).
- **Symbolization via libdwfl** (`dwfl_addrmodule` → `dwfl_module_addrinfo` →
  `dwfl_module_getsrc`), with the survey's hw-hit gotcha encoded: `addrinfo`'s
  `offset`/`sym` arguments must be non-NULL. Soft dependency like libpfm4:
  absent libdw ⇒ `symbolization` advertised absent, samples still counted.
- **Optional DWARF-CFI unwind** (`STACK_USER`+`REGS_USER` →
  `dwfl_getthread_frames`) for frame-pointer-less builds — the
  [unwind probe][ex-unwind] proved the full path in-process on a
  `--frame-pointer=none` build.
- **Output shape:** a per-case flat profile (top-N symbols by samples) as a
  `diagnostic` table section, off by default (`--bench-profile`), never
  polluting the timing pass.

**Borrows:** perf's consumer ordering ([linux-perf-events.md][linux]);
elfutils' documented call sequence ([elfutils.md][elfutils]); the counting/
timing pass separation from [`bench.d`][baseline] (the profile pass is a third
pass, like counting).

---

## 8. Milestone summary

| #   | Milestone                | Capabilities unlocked                                            | Depends on | Evidence base                                                 |
| --- | ------------------------ | ---------------------------------------------------------------- | ---------- | ------------------------------------------------------------- |
| 1   | Capability seam          | reporting of absences (all backends)                             | —          | [baseline][baseline], [comparison][comparison]                |
| 2   | Linux counting depth     | `countingRaw`, `eventNaming`, `countingScaled`, `selfMonitoring` | 1          | [linux][linux], [event-naming][naming], [probes][ex-counting] |
| 3   | macOS floor              | `counting` (process scope) on Darwin                             | 1          | [macos][macos] `[hw-verified]`                                |
| 4   | Windows floor            | `counting` (CycleTime), NUMA groundwork                          | 1          | [windows][windows]                                            |
| 5   | Precise memory tier      | `preciseMemory`, `numaAttribution`                               | 1, 2       | [precise-sampling][precise] `[hw-verified]`                   |
| 6   | Sampling & symbolization | `ipSampling`, `symbolization`                                    | 1          | [linux][linux], [elfutils][elfutils], probes                  |

Sequencing rationale: M1 is pure refactoring value (better reporting today);
M2 deepens the mode the harness already lives in; M3/M4 are small,
independent, and kill the "all counters vanish off Linux" cliff; M5/M6 add the
_where_ dimension and are the only milestones with new soft C dependencies
(libdw, libpfm4) — both degrade to advertised absence.

ISA notes carried across milestones: on big.LITTLE ARM the backend must open
events on the PMU whose `cpumask` contains the pinned core
([arm.md][arm]); on RISC-V the backend is a capability _subset_ by
construction — counting always (SBI), sampling iff Sscofpmf, branch records
never until a CTR consumer lands ([riscv.md][riscv]).

## Sources

- [sparkles-baseline.md][baseline] — the audited system and its gap analysis.
- [comparison.md][comparison] — the capability matrix this proposal's flags
  mirror, and the open questions its deferred items point at.
- Per-subject deep-dives: [linux-perf-events][linux], [elfutils][elfutils],
  [libnuma][libnuma], [precise-sampling][precise], [arm][arm], [riscv][riscv],
  [windows][windows], [macos][macos], [event-naming][naming].
- Runnable evidence: [counting-group.d][ex-counting],
  [sampling-symbolize.d][ex-sampling], [unwind-stack-user.d][ex-unwind],
  [mem-latency-numa.d][ex-mem], [pfm4-name-roundtrip.d][ex-pfm4].

<!-- References -->

[baseline]: ./sparkles-baseline.md
[baseline-seam]: ./sparkles-baseline.md#the-metric-catalog-seam
[baseline-gaps]: ./sparkles-baseline.md#gap-analysis-what-the-audit-starts-from
[comparison]: ./comparison.md
[comparison-open]: ./comparison.md#open-questions-gaps
[spine]: ./#the-seven-concerns
[linux]: ./linux-perf-events.md
[elfutils]: ./elfutils.md
[libnuma]: ./libnuma.md
[precise]: ./precise-sampling.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[windows]: ./windows.md
[macos]: ./macos.md
[naming]: ./event-naming.md
[naming-boundary]: ./event-naming.md
[wired-bench]: ../../../libs/wired/bench/runtime/
[dbi]: ../../guidelines/design-by-introspection-01-guidelines.md
[ex-counting]: ./examples/counting-group.d
[ex-sampling]: ./examples/sampling-symbolize.d
[ex-unwind]: ./examples/unwind-stack-user.d
[ex-mem]: ./examples/mem-latency-numa.d
[ex-pfm4]: ./examples/pfm4-name-roundtrip.d
[c-multiplex]: ./concepts.md#multiplexing-and-scaling
[c-rdpmc]: ./concepts.md#self-monitoring-and-user-space-counter-reads
[c-datasrc]: ./concepts.md#data-source-attribution
[c-buildid]: ./concepts.md#build-id
[c-privilege]: ./concepts.md#privilege-gating
