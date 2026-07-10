# Windows CPU-PMU acquisition (HCP · ETW · ring-0 drivers)

The Windows mapping of the survey's [seven concerns][concepts]. Where Linux exposes
one open, uniform hub — [`perf_event_open(2)`][linux] — Windows splits the same
counting and sampling roles across **three disjoint surfaces** that share no common
seam: a curated usermode **Hardware Counter Profiling (HCP)** API, the **ETW**
kernel-logger PMC/LBR pipeline, and a **closed ring-0 driver** model (Intel VTune
SEP, AMD uProf) for arbitrary events.

| Field             | Value                                                                                                                                                                                  |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OS / SDK          | Windows 7 → Windows Server 23H2 (feature timeline; HCP min **Win7 / Server 2008 R2**, PMC ETW classes min **Win8**, LBR min **Win10 19H1**)                                            |
| Counting API      | HCP `EnableThreadProfiling`/`ReadThreadProfilingData` (`winbase.h`, Kernel32); ETW `-pmc` PMCs logged on kernel events                                                                 |
| Overflow sampling | ETW PMC-overflow → `PERF_PMC_PROFILE` event (`TraceProfileSourceConfigInfo`; `xperf -pmcprofile … -stackwalk pmcinterrupt`)                                                            |
| Precise sampling  | **Absent publicly** — no data-address/PEBS class in `TRACE_QUERY_INFO_CLASS`; kernel PEBS plumbing exists but is walled off (see [Concern 3](#concern-3-precise-data-source-sampling)) |
| Branch records    | **LBR** via `TraceLbrConfigurationInfo` (`TraceLbrEventListInfo`), branch-only, public since Win10 19H1                                                                                |
| Event catalog     | Curated HAL profile-sources via [`wpr -pmcsources`][wpt-pmu] / `xperf -pmcsources`; raw events registerable system-globally since Win10 1903                                           |
| Consumers read    | [`krabsetw`][krabs] `@ 6900de05` (open ETW consumer); [`windows-d`][winmd] `@ f34527e` (win32metadata → D projection); druntime `core.sys.windows` (ldc 1.41.0)                        |
| Verification      | `[literature]` (saved Microsoft Learn docs, named by file, retrieved 2026-07-10) + `[source-verified]` (krabsetw / windows-d / druntime reads); **no hardware**                        |

> [!IMPORTANT]
> **No Windows hardware was available for this survey.** Every claim on this page
> is either `[literature]` — read from an official Microsoft Learn page saved to
> `$REPOS/papers/cpu-pmu/<file>.html` (retrieved 2026-07-10, all HTTP 200) — or
> `[source-verified]` — read from a pinned open-source tree ([`krabsetw`][krabs]
> `@ 6900de05`, [`windows-d`][winmd] `@ f34527e`) or ldc-1.41.0 druntime. There is
> **no `[hw-verified]` tag anywhere.** Several load-bearing facts (the internal
> PEBS enum, the extended group-mask enable path) come from **undocumented** APIs
> that krabs uses and Microsoft does not commit to; those are flagged inline with a
> GitHub alert at each use. Encodings and version floors trace to saved copies of
> the official documentation (retrieved 2026-07-10), not to a running system.

---

## Overview

### What it acquires

There is no Windows equivalent of `perf_event_open` — no single call that opens a
counter, selects an event by encoding, groups siblings atomically, and streams
samples through a ring buffer. Instead each of the survey's concerns lands on a
_different_ surface, and two of them (arbitrary events, precise data-source
sampling) fall off the public API entirely. The organizing fact is **curation**:
Windows exposes a small, HAL-vetted vocabulary of events, and the raw hardware
event space is reachable only through a kernel driver or a system-global
registration — never inline per acquisition. The WPT documentation states the
policy directly ([`recording-pmu-events`][wpt-pmu]):

> _"Only a small subset of PMU events in CPU vendor's documents are implemented in
> Windows HAL by default. However, WPR provides a way to extend PMU events that are
> not exposed as the available profile sources."_

That sentence frames the whole page. Everywhere Linux says _"any `config` value,
subject to `perf_event_paranoid`"_, Windows says _"a curated list, plus a
privileged escape hatch"_ — the [capability-curation][curation] stance the survey's
[comparison][comparison] contrasts against Linux's open model. ([macOS][macos]
curates even more strictly, allowlisting events even for root.)

### Design philosophy: three surfaces, no common seam

The three surfaces are not layers of one stack; they are unrelated APIs owned by
different teams, with different privilege models, different event vocabularies, and
no shared data type:

- **HCP** (`winbase.h`, Kernel32) is a _per-thread accumulated-count_ API. It is
  the only usermode-friendly counting path, but its sole driver-free datum is
  `CycleTime`; real PMCs require a kernel driver to program the counters first.
- **ETW** (`evntrace.h`) is the real event-space and sampling backbone: a
  system-wide logger that emits PMC counts on selected kernel events, PMC-overflow
  IP samples, and LBR branch records into a trace session consumed after the fact.
- **Ring-0 drivers** (VTune SEP, AMD uProf) own arbitrary-event acquisition. They
  are closed-source; the only _supported_ enumeration of what the HAL will expose
  is `wpr -pmcsources`.

A portable harness therefore cannot "open a counter" on Windows the way it does on
Linux; it must pick a surface per concern and accept that three of the seven roles
(precise sampling, arbitrary events, sampled-address → NUMA node) have no
usermode-portable answer at all.

---

## How it works

### (a) Hardware Counter Profiling: per-thread counting

HCP is the documented usermode counting path: `EnableThreadProfiling`,
`ReadThreadProfilingData`, `DisableThreadProfiling`, `QueryThreadProfiling` — all in
`winbase.h`, exported from Kernel32.dll, minimum **Windows 7 / Server 2008 R2**.
`[literature]` The signature is:

```c
// winbase.h
BOOL EnableThreadProfiling(
    HANDLE ThreadHandle, DWORD Flags, DWORD64 HardwareCounters,
    HANDLE *PerformanceDataHandle);
```

Three properties make it structurally unlike `perf_event_open`. First, **the
`HardwareCounters` bitmask selects counters by _index_, never by event encoding**
([`enablethreadprofiling`][hcp-enable]):

> _"You can specify up to 16 performance counters. Each bit relates directly to the
> zero-based hardware counter index for the hardware performance counters that you
> configured."_

Second, those counters must have been **configured globally by a kernel driver**
before profiling begins — HCP itself cannot program a PMU:

> _"To profile hardware performance counters, you need a driver to configure the
> counters. The performance counters are configured globally for the system … see
> the KeSetHardwareCounterConfiguration function in the Windows Driver Kit (WDK)."_
> `[literature]`

Third, `EnableThreadProfiling`'s `ThreadHandle` **"must be the current thread"** — a
thread can profile only itself. `[literature]`

The read side fills a `PERFORMANCE_DATA` (`winnt.h`) with `CycleTime`,
`ContextSwitchCount`, `WaitReasonBitMap`, and — only under the
`READ_THREAD_PROFILING_FLAG_HARDWARE_COUNTERS` flag — an array
`HARDWARE_COUNTER_DATA HwCounters[MAX_HW_COUNTERS]` (16 slots). The **only
guaranteed hardware datum without a driver is `CycleTime`** ("cycle time of the
thread … excludes time spent interrupted"); there is no retired-instructions or
other named PMC field — every real PMC value flows through `HwCounters[]`, which is
populated only when a driver has configured the counters. `[literature]` Each slot is
a bare `HARDWARE_COUNTER_DATA = { HARDWARE_COUNTER_TYPE Type; DWORD Reserved; DWORD64
Value; }`, and `HARDWARE_COUNTER_TYPE` has exactly one real value, `PMCCounter`
(plus the `MaxHardwareCounterType` sentinel) — there is **no generic event-encoding
type** at the HCP layer. `[literature]`

The driver routine is `KeSetHardwareCounterConfiguration` (`ntddk.h`, WDK), and its
effect is **global and single-tenant** ([`kesethardwarecounterconfiguration`][wdk-ke]):

> _"The operating system supports only one profiling application at a time.
> Concurrent instances of a thread-profiling application are not supported. A thread
> can enable thread profiling for itself but not for other threads."_

Drivers coordinate counter ownership through `HalAllocateHardwareCounters` /
`HalFreeHardwareCounters`, and a single `KeSetHardwareCounterConfiguration` call
"sets the hardware counter configuration to use for thread profiling across all
processors." `[literature]` The upshot: HCP is a real per-thread counting API, but it
delegates the entire PMU-programming step to a WDK driver that owns the machine's
counters system-wide — the opposite of Linux's per-fd, kernel-arbitrated model.

ETW offers a second counting mode, "PMU events on ETW events": PMC values are logged
whenever selected ETW events fire (e.g. `CSwitch`), producing WPA's
Cycles-per-Instruction table. `[literature]`

```bash
# Count PMCs sampled at each context switch (WPA CPI table)
xperf -pmc InstructionRetired,TotalCycles CSWITCH strict
```

### (b) The ETW pipeline

ETW is a producer/consumer logging system, and PMU acquisition rides it as a set of
_configuration classes_ layered on the ordinary session lifecycle. The control side
is `StartTrace` (with an `EVENT_TRACE_PROPERTIES` or `_V2` block) → `EnableTraceEx2`
→ the PMU config call `TraceSetInformation` → `ProcessTrace`; field extraction on the
consumer side uses `TdhGetProperty`. `[literature]` The PMU knobs are members of
`TRACE_QUERY_INFO_CLASS` (`evntrace.h`), passed to
[`TraceSetInformation`][etw-tsi] — minimum Win7, but the PMC classes require Win8:

| Class (value)                         | Role                                                             | Min version |
| ------------------------------------- | ---------------------------------------------------------------- | ----------- |
| `TraceSampledProfileIntervalInfo` (5) | Timer sample interval                                            | Win7        |
| `TraceProfileSourceConfigInfo` (6)    | Profiling sources collected into the `PERF_PMC_PROFILE` event    | Win8        |
| `TraceProfileSourceListInfo` (7)      | Query available profile sources                                  | Win8        |
| `TracePmcEventListInfo` (8)           | PMC-on-event counting list                                       | Win8        |
| `TracePmcCounterListInfo` (9)         | PMC counter list                                                 | Win8        |
| `TraceProviderBinaryTracking` (18)    | Provider-GUID → module-path map into buffers / the `.etl` header | Win10 1709  |
| `TraceLbrConfigurationInfo` (20)      | LBR (branch record) configuration                                | Win10 19H1  |
| `TraceLbrEventListInfo` (21)          | LBR event list                                                   | Win10 19H1  |
| `TraceMaxPmcCounterQuery` (22)        | Max profiling sources usable simultaneously                      | Win10 19H1  |
| `TracePmcCounterOwners` (25)          | PMCs currently in use system-wide                                | Win10 21H2  |
| `TraceContextRegisterInfo` (28)       | GP register contents at the moment a related event fires         | Server 23H2 |

The counter budget is shared and small: with CPU sampling enabled only **3** PMCs
are usable (the timer needs one); **4** if attached to context-switch events —
`TraceMaxPmcCounterQuery` reports the ceiling, `TracePmcCounterOwners` the current
occupants. `[literature]`

The **open consumption model** is [`krabsetw`][krabs] (`[source-verified]`). A
session is a `krabs::trace<T>` (`T` = `ut` user-trace or `kt` kernel-trace);
`trace_manager<T>::open()` calls `register_trace()` → `enable_providers()` →
`open_trace()`, then `process_trace()` (`ProcessTrace`). Each `EVENT_RECORD` is
dispatched by `ProviderId` to the matching `krabs::provider`, which parses fields via
the TDH schema — the open analog of Linux's [`libtraceevent`][libtraceevent] + tracefs
`format` files. `[source-verified]` The documented per-session config seam is
`trace_manager<T>::set_trace_information` → `TraceSetInformation`, through which a
consumer sets `TracePmcCounterListInfo` / `TraceLbrConfigurationInfo`.
`[source-verified]`

Reaching the newer kernel-logger providers requires an **undocumented** path. The
classic 32-bit `EnableFlags` cannot address them, so krabs reads and writes the
extended **`PERFINFO_GROUPMASK`** via `NtQuerySystemInformation` /
`NtSetSystemInformation(SystemPerformanceTraceInformation, …)`;
`PERF_PMC_PROFILE = 0x20000400` is one such group-mask bit. `[source-verified]`

> [!WARNING]
> **The group-mask enable path is undocumented.** krabs annotates it itself
> ([`kt.hpp:63-66`][krabs-kt]): _"Enables the configured kernel rundown flags. This
> ETW feature is undocumented and should be used with caution."_ A backend that
> depends on it inherits that risk — Microsoft does not commit to the
> `PERFINFO_GROUPMASK` bit layout or the `SystemPerformanceTraceInformation`
> contract across releases.

### (c) The closed ring-0 driver model

Arbitrary events — anything outside the curated HAL profile-sources — require a
**kernel driver**. Intel's VTune ships **SEP**, AMD's uProf ships its own; both are
closed-source, and both program the PMU below the ETW/HCP layer. The only
_supported_ way to enumerate what the HAL will expose is
`wpr -pmcsources` / `xperf -pmcsources`. `[literature]` This is the same driver
requirement HCP's `KeSetHardwareCounterConfiguration` documents from the other
direction: usermode Windows never programs an event selector itself.

---

## The seven concerns

The uniform survey spine, each concern stating the Windows mechanism or its explicit
absence.

| #   | Concern                                                                 | Windows answer                                                                                   |
| --- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| 1   | [Scalar counting](#concern-1-scalar-counting)                           | HCP `EnableThreadProfiling` (driver-free = `CycleTime` only) + ETW `-pmc`                        |
| 2   | [Overflow / IP sampling](#concern-2-overflow-ip-sampling)               | ETW PMC-overflow → `PERF_PMC_PROFILE`; `-pmcprofile … -stackwalk pmcinterrupt`                   |
| 3   | [Precise data-source sampling](#concern-3-precise-data-source-sampling) | **Absent publicly** — LBR only; PEBS internal-only; context regs Server 23H2                     |
| 4   | [Code-space decode](#concern-4-code-space-decode)                       | DbgHelp/PDB; build-id analog = PDB GUID+Age; symbol servers                                      |
| 5   | [Event space & tracing](#concern-5-event-space-tracing)                 | ETW + krabsetw; admin / Performance-Log-Users / `SeSystemProfilePrivilege`                       |
| 6   | [NUMA & topology](#concern-6-numa-topology)                             | `GetLogicalProcessorInformationEx` / `VirtualAllocExNuma`; `QueryWorkingSetEx.Node` (query only) |
| 7   | [Event naming & encoding](#concern-7-event-naming-encoding)             | Curated `-pmcsources` + Win10-1903 raw `ProfileSource` registration; cross-ISA                   |

### Concern 1: Scalar counting

Two paths, covered in [How it works (a)](#a-hardware-counter-profiling-per-thread-counting).
HCP gives per-thread accumulated [counts][counting]; without a WDK driver the only
hardware datum is `CycleTime`, and real PMCs need `KeSetHardwareCounterConfiguration`
to program the (system-global, single-tenant) counters first. Counters are selected
by **index**, not by event encoding, and there is no user-visible
[event-group][event-group] seam — the counters read whatever the global driver
config holds. ETW's `-pmc` mode is the alternative: PMCs logged on kernel events into
a trace session. `[literature]`

### Concern 2: Overflow / IP sampling

ETW's PMC-overflow mode is the [overflow-sampling][overflow] analog: a counter counts
down _N_ events, overflow raises an interrupt, and the handler captures a sample.
`TraceProfileSourceConfigInfo` selects which sources land in the sample
([`trace_query_info_class`][etw-tqic]):

> _"Configures the list of profiling sources that will be collected when the
> performance monitoring counter profile event fires. The collected counters will be
> emitted as part of the `PERF_PMC_PROFILE` event."_ `[literature]`

The interval is "in number of events of that type" — the [PMI][pmi]-per-N model.

```bash
# Sample the interrupted IP + stack every 100000 retired instructions
xperf -on … +pmc_profile -pmcprofile instructionretired -stackwalk pmcinterrupt
```

```xml
<!-- WPRP form: sample on PMC overflow -->
<HardwareCounter>
  <SampledCounters>
    <SampledCounter Value="InstructionRetired" Interval="100000"/>
  </SampledCounters>
</HardwareCounter>
```

The sample carries the interrupted instruction pointer and, with
`-stackwalk pmcinterrupt`, a call stack — never a data address. `[literature]`

### Concern 3: Precise data-source sampling

**Absent from the public surface.** This is the sharpest Windows finding, and it is
_not_ merely "unimplemented": the full `TRACE_QUERY_INFO_CLASS` enumeration (values
0–28) was read, and it contains PMC, profile-source, LBR, stack, and context-register
classes but **no PEBS / data-address / memory-latency class**. The
[`recording-pmu-events`][wpt-pmu] documentation describes only IP + stack capture
(`-stackwalk pmcinterrupt`), never a sampled data address. `[literature]`

Yet the kernel _does_ have PEBS plumbing — it is simply walled off from third
parties. The **undocumented** internal `EVENT_TRACE_INFORMATION_CLASS` enum
reproduced in krabs lists `EventTracePebsTracingInformation` alongside
`EventTraceProfileCounterListInformation` and
`EventTraceProfileEventListInformation`; krabs reaches these through
`NtSetSystemInformation`, not the documented API. `[source-verified]`

> [!NOTE]
> **PEBS exists in the kernel but is not exposed.** The presence of
> `EventTracePebsTracingInformation` in the internal enum
> ([`perfinfo_groupmask.hpp:155-176`][krabs-pgm]) proves the capability is plumbed;
> the absence of any matching class in the documented `TRACE_QUERY_INFO_CLASS` proves
> it is not offered to third-party code. There is no supported way to obtain
> [data-source attribution][data-source] on Windows.

The two public analogs are both narrower than Intel [PEBS][precise] / ARM SPE (the
cross-vendor precise-sampling story is [precise-sampling.md][precise-page]'s subject):

- **LBR** [branch records][branch-records] — `TraceLbrConfigurationInfo` (20) /
  `TraceLbrEventListInfo` (21), public since Win10 19H1 / Server 1903. This is the
  LBR/BRBE analog, but **branch-only**: no data virtual/physical address, no latency
  packet. `[literature]`
- `TraceContextRegisterInfo` (28), Server 23H2+ — "CPU register contents at the moment
  the specified related event is fired" — general-purpose registers, not a
  data-address/latency record. `[literature]`

### Concern 4: Code-space decode

[Symbolization][symbolization] uses **DbgHelp**: `SymInitialize`, `SymFromAddr`,
`SymGetLineFromAddr64`, `StackWalk64`. `[source-verified]` (present in both druntime
and windows-d — see the [D-bindings callout](#d-bindings)). PDB debug info is
**out-of-band** — a separate `.pdb` file, unlike DWARF-in-ELF — and is resolved via
symbol servers keyed by `_NT_SYMBOL_PATH`. The [build-id][build-id] analog is the
**PDB GUID + Age** carried in the CodeView `RSDS` debug directory; matching it guards
the stale-binary hazard exactly as an ELF build-id does. `[literature]` The
address-space model (Linux's `PERF_RECORD_MMAP2`) is supplied by ETW image-load
events (loader keyword) plus `TraceProviderBinaryTracking` (18, Win10 1709+), which
emits a provider-GUID → module-path map. `[literature]` Module enumeration lives in
`psapi` (`EnumProcessModules`, `GetModuleInformation`, `GetMappedFileNameW`).
`[source-verified]`

### Concern 5: Event space & tracing

ETW _is_ the [event-space][event-space] concern on Windows, and [`krabsetw`][krabs]
is the open consumption model — the pipeline and the undocumented
`PERFINFO_GROUPMASK` enable path are covered in
[How it works (b)](#b-the-etw-pipeline). Access is gated
([`starttrace`][etw-start]):

> _"Only users with administrative privileges, users in the Performance Log Users
> group, and services running as LocalSystem …"_ `[literature]`

PMC / system-logger sessions additionally require `SeSystemProfilePrivilege` —
effectively elevation. This is the Windows face of the survey's
[privilege-gating][gating] concern.

### Concern 6: NUMA & topology

Topology enumeration is `GetLogicalProcessorInformationEx` (with the
`RelationNumaNode` relationship in `SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX`),
`GetNumaHighestNodeNumber`, `GetNumaProcessorNodeEx`; node-targeted allocation is
`VirtualAllocExNuma`. `[source-verified]` The [page → node oracle][numa] — Linux's
`move_pages()` in query mode — has one analog: `QueryWorkingSetEx`, whose
`PSAPI_WORKING_SET_EX_INFORMATION.VirtualAttributes` union
(`PSAPI_WORKING_SET_EX_BLOCK`) carries a per-page **`Node`** field. `[source-verified]`

But this answers "which node backs _this VA_?", not "which node served _this sampled
access_?" Because [Concern 3](#concern-3-precise-data-source-sampling) has no
sampled-address path, **there is no sampled-data-address → NUMA-node attribution on
Windows** the way `PERF_SAMPLE_PHYS_ADDR` + `move_pages` provides on Linux. Page → node
is queryable only for a VA already known to the profiler. `[literature]` (derived from
the concern-3 absence).

### Concern 7: Event naming & encoding

The named-event surface is a **curated architectural profile-source set** enumerated
by `wpr -pmcsources` / `xperf -pmcsources`: `Timer`, `TotalIssues`,
`BranchInstructions`, `CacheMisses`, `BranchMispredictions`, `TotalCycles`,
`UnhaltedCoreCycles`, `InstructionRetired`, `UnhaltedReferenceCycles`, `LLCReference`,
`LLCMisses` (plus `*Fixed` names for fixed counters). `[literature]` This is the
curated counterpart to [`libpfm4`][event-naming]'s name → `{type, config}` table; the
cross-OS naming problem it lands in is [event-naming.md][event-naming-page]'s subject.

Raw, non-architectural events **are** registerable **since Win10 1903** — but only as
a **system-global registration**, never as an inline per-acquisition encoding. The
registration lives in a WPRP fragment or the registry, keyed by exact CPU
family/model:

```xml
<!-- WPRP: register a raw Intel event as a named profile source (system-global) -->
<MicroArchitecturalConfig>
  <ProfileSource Architecture="INTEL" Event="0x48" Unit="0x01"
                 ExtendedBits="01000100" Name="…" Interval="…"/>
</MicroArchitecturalConfig>
```

```text
Registry equivalent (per exact CPU family/model):
  HKLM\SYSTEM\CurrentControlSet\Control\WMI\ProfileSource\<Model>\<Name>
  values: Event, Unit, Interval
```

The Intel `ExtendedBits` field decodes to "CMask CMaskInvert AnyThread EdgeDetect".
This is the [`perf_event_attr.{type, config}`][event-naming] analog **minus** the
inline-per-open flexibility: the encoding lives in a registered table, not in the
acquisition call. Notably the naming surface is **CPU-vendor-neutral and cross-ISA** —
the same ETW/profile-source layer serves Intel, AMD, and **ARM64** (the WPT doc's
example registers a Qualcomm Snapdragon custom counter), abstracting across ISAs at
the profile-source layer where Linux keeps a per-arch `perf_event_attr.config`.
`[literature]`

---

## The W1 role-replacement table

Each Linux (W1) acquisition mechanism and its nearest Windows equivalent, with the
source that grounds it and the verification tag.

| Linux (W1) role                                           | Windows equivalent                                                                    | Source                                                                  | Tag                                |
| --------------------------------------------------------- | ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------- |
| [`perf_event_open`][linux] counting (`PERF_FORMAT_GROUP`) | HCP `EnableThreadProfiling` / `ReadThreadProfilingData`; ETW `-pmc` on events         | `winbase.h`; [`recording-pmu-events`][wpt-pmu]                          | `[literature]`                     |
| `perf_event_open` sampling + ring buffer                  | ETW PMC-overflow (`TraceProfileSourceConfigInfo` → `PERF_PMC_PROFILE`); `-pmcprofile` | [`trace_query_info_class`][etw-tqic]; `recording-pmu-events`            | `[literature]`                     |
| [PEBS][precise] / `PERF_SAMPLE_DATA_SRC` precise          | **none public**; LBR (`TraceLbrConfigurationInfo`); PEBS internal-only                | `trace_query_info_class`; [`perfinfo_groupmask.hpp:155-176`][krabs-pgm] | `[source-verified]`/`[literature]` |
| [`libdwfl`][elfutils] addr → line + inline                | DbgHelp `SymGetLineFromAddr64` + PDB / DIA SDK                                        | [`dbghelp`][dbg-line]; druntime `dbghelp.d`                             | `[source-verified]`/`[literature]` |
| [`libtraceevent`][libtraceevent] + tracefs `format`       | ETW TDH schema + krabs provider/parser                                                | [`krabsetw`][krabs] `etw.hpp`, `kernel_providers.hpp`                   | `[source-verified]`                |
| [`libnuma`][libnuma] `set_mempolicy` / `move_pages`       | `VirtualAllocExNuma`; `QueryWorkingSetEx.Node` (query only)                           | [`windows-d`][winmd] `memory`, `processstatus`; [`numa`][numa-qws]      | `[source-verified]`/`[literature]` |
| [`libpfm4`][event-naming] name → `{type, config}`         | `-pmcsources` curated names + `ProfileSource` registry `Event`/`Unit`                 | [`recording-pmu-events`][wpt-pmu]                                       | `[literature]`                     |
| [Build-id][build-id] (ELF `NT_GNU_BUILD_ID`)              | PDB **GUID + Age** (CodeView `RSDS`)                                                  | (PE/PDB standard)                                                       | `[literature]`                     |

---

## D bindings

> [!IMPORTANT]
> **druntime covers only two of the seven Windows roles.** ldc-1.41.0
> `core.sys.windows` has DbgHelp and psapi — and **nothing else**: no ETW, no
> HCP/thread-profiling, no NUMA/topology `*Ex` at all (a full grep found none of
> `EnableThreadProfiling`, `TraceSetInformation`, `GetLogicalProcessorInformationEx`,
> `VirtualAllocExNuma`, `QueryWorkingSetEx`). `winperf.d` is the registry PDH
> counter path, not the PMU. Three of the four Windows surfaces have **zero**
> druntime coverage. `[source-verified]`

What druntime **does** ship, and can be reused directly:

- `dbghelp.d` — lazily-loaded function pointers via `GetProcAddress`: `SymInitialize`,
  `StackWalk64`, `SymSetOptions`, `SymGetLineFromAddr64`, `SymGetSymFromAddr64`,
  `SymLoadModule64` (`dbghelp.d:27-92`). `[source-verified]`
- `psapi.d` — `EnumProcessModules`, `GetModuleInformation`, `GetMappedFileNameW`
  (`psapi.d:102,108,133`). `[source-verified]`

The gaps are all already generated by [`windows-d`][winmd] `@ f34527e` (a
win32metadata → D projection). **Recommendation for the backend proposal: pull these
four generated modules rather than hand-write `extern(Windows)` prototypes.**
`[source-verified]`

| Role    | `windows-d` module                                                               | Key symbols (line)                                                                                                                                                           |
| ------- | -------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HCP     | `…/system/performance/hardwarecounterprofiling.d`                                | `EnableThreadProfiling` (51); `PERFORMANCE_DATA` with `HARDWARE_COUNTER_DATA[16] HwCounters` (44); `HARDWARE_COUNTER_DATA` (26-32)                                           |
| ETW     | `…/system/diagnostics/etw.d`                                                     | `TRACE_QUERY_INFO_CLASS` (143); `EVENT_TRACE_PROPERTIES` (1539); `StartTraceW` (2279)                                                                                        |
| NUMA    | `…/system/systeminformation.d`, `…/memory/package.d`, `…/system/processstatus.d` | `GetLogicalProcessorInformationEx` (769), `GetNumaHighestNodeNumber` (1009); `VirtualAllocExNuma` (743); `QueryWorkingSetEx` / `PSAPI_WORKING_SET_EX_BLOCK.Node` (80,99,102) |
| DbgHelp | `…/system/diagnostics/debug_/package.d`                                          | `SymInitialize` (7046), `SymFromAddr` (7176), `SymGetLineFromAddr64` (7252)                                                                                                  |

---

## Strengths

- **Per-thread accumulated counting works in usermode** without a session — HCP's
  `CycleTime` needs no driver, and `HwCounters[]` surfaces up to 16 PMCs once a driver
  configures them.
- **ETW is a genuinely rich event-space backbone** — PMC-on-event counting, PMC
  overflow IP+stack sampling, and LBR branch records, all through one logger with a
  documented config-class surface and an open consumer ([`krabsetw`][krabs]).
- **Cross-ISA event naming at the profile-source layer** — the same `-pmcsources`
  vocabulary and `ProfileSource` registration serve Intel, AMD, and ARM64, above the
  vendor encoding.
- **Out-of-band PDB + GUID/Age build-id** give a clean stale-binary guard and a
  mature symbol-server ecosystem for [symbolization][symbolization].
- **NUMA topology and placement are fully covered** by Win32 (`*InformationEx`,
  `VirtualAllocExNuma`), and per-page node is queryable via `QueryWorkingSetEx`.

## Weaknesses

- **No unified acquisition API** — three disjoint surfaces (HCP, ETW, ring-0 driver)
  with different privilege models, vocabularies, and data types, versus Linux's single
  `perf_event_open`.
- **Arbitrary events need a closed kernel driver** (VTune SEP / AMD uProf); the HAL
  exposes only a curated profile-source list to unprivileged callers.
- **No public precise / data-source sampling** — PEBS is plumbed in the kernel but
  walled off ([`EventTracePebsTracingInformation`][krabs-pgm]); the only public
  precise-ish signals are branch-only LBR and (Server 23H2) GP-register capture.
- **No sampled-address → NUMA-node attribution** — page → node is queryable only for a
  known VA, never for a sampled memory access.
- **Counter model is system-global and single-tenant** — one profiling application at
  a time; counters selected by index, programmed by a driver for the whole machine.
- **The load-bearing kernel-logger paths are undocumented** — the extended
  `PERFINFO_GROUPMASK` enable and the internal PEBS enum are krabs-reverse-engineered,
  not contract.
- **druntime coverage is minimal** — only DbgHelp + psapi; ETW/HCP/NUMA must come from
  `windows-d` or be hand-written.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                      | Trade-off                                                                         |
| ------------------------------------------------------------ | -------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| Three disjoint surfaces (HCP / ETW / ring-0 driver)          | Each role served by the team/subsystem that owns it            | No common seam; a harness picks per concern and stitches three data models        |
| HCP delegates PMU programming to a WDK driver                | Keeps the usermode API tiny and safe; counters owned centrally | Driver-free = `CycleTime` only; real PMCs need ring-0 config, system-global       |
| Counters selected by **index**, not event encoding           | Usermode never touches raw event selectors                     | Cannot express an arbitrary event inline; the encoding lives in a driver/registry |
| Single-tenant, system-global counter configuration           | One arbiter avoids cross-tool counter contention               | Only one profiling application at a time; no per-fd scheduling like Linux         |
| Curated HAL profile-sources + global raw registration escape | Small vetted vocabulary; raw events possible but controlled    | No inline `perf_event_attr.config`; raw events need a system-global registration  |
| PEBS kept internal to the kernel                             | (Microsoft's choice; capability exists)                        | No public precise/data-source sampling; third parties get LBR + context regs only |
| ETW as the sampling + event-space backbone                   | One logger, documented config classes, TDH-typed events        | Newer providers need the undocumented `PERFINFO_GROUPMASK` path                   |
| Out-of-band PDB + GUID/Age identity                          | Ships stripped binaries; symbol servers resolve on demand      | Symbolization needs `_NT_SYMBOL_PATH` + exact GUID+Age match                      |

---

## Sources

- [`_hcp/` — Hardware Counter Profiling overview][hcp-overview] ·
  [`EnableThreadProfiling`][hcp-enable] · [`ReadThreadProfilingData`][hcp-read] —
  `winbase.h` per-thread counting, index-not-encoding, driver requirement. `[literature]`
- [`PERFORMANCE_DATA`][ns-perfdata] · [`HARDWARE_COUNTER_DATA`][ns-hcdata] ·
  [`HARDWARE_COUNTER_TYPE`][ne-hctype] — `winnt.h` structures; `CycleTime` the only
  driver-free datum; `PMCCounter` the only real type. `[literature]`
- [`KeSetHardwareCounterConfiguration`][wdk-ke] — WDK driver routine; global,
  single-tenant counter configuration. `[literature]`
- [`TraceSetInformation`][etw-tsi] · [`TRACE_QUERY_INFO_CLASS`][etw-tqic] ·
  [`EVENT_TRACE_PROPERTIES`][etw-props] · [`StartTraceW`][etw-start] — ETW control +
  PMU config classes with version floors. `[literature]`
- [WPT — Recording PMU Events][wpt-pmu] · [Using xperf profiles][wpt-xperf] — `-pmc`,
  `-pmcprofile`, `-pmcsources`, WPRP `HardwareCounter`, raw `ProfileSource`
  registration, the curated-HAL-subset quote. `[literature]`
- [`SymFromAddr`][dbg-sym] · [`SymGetLineFromAddr64`][dbg-line] — DbgHelp
  symbolization; PDB GUID+Age build-id analog. `[literature]`
- [`GetLogicalProcessorInformationEx`][numa-glpi] · [`VirtualAllocExNuma`][numa-vaen] ·
  [`QueryWorkingSetEx`][numa-qws] — Win32 topology, placement, page → node query.
  `[literature]`
- [`krabsetw`][krabs] `@ 6900de05` — open ETW consumer: `etw.hpp` (trace lifecycle,
  `set_trace_information`), `kt.hpp` (undocumented group-mask enable),
  [`perfinfo_groupmask.hpp:155-176`][krabs-pgm] (internal `EVENT_TRACE_INFORMATION_CLASS`
  incl. `EventTracePebsTracingInformation`), `kernel_providers.hpp`. `[source-verified]`
- [`windows-d`][winmd] `@ f34527e` — win32metadata → D projection carrying every gap
  druntime lacks (HCP, ETW, NUMA), recommended for the backend proposal.
  `[source-verified]`
- druntime `core.sys.windows` (ldc-1.41.0) — `dbghelp.d:27-92`, `psapi.d:102,108,133`
  present; ETW/HCP/NUMA absent (grep). `[source-verified]`
- Claim-by-claim provenance and the full saved-docs URL map are recorded in the
  survey's internal QA ledger (repos and captures pinned by SHA/date).

> [!NOTE]
> **No runnable CI example ships with this page.** The survey's convention is a
> [CI-compiled probe][linux] per deep-dive, but there is no Windows host in CI and
> no Windows hardware was available; every claim here is `[literature]` (saved docs)
> or `[source-verified]` (open-source reads). A D program built against the
> [`windows-d`][winmd] HCP/ETW modules would compile only on Windows and could only
> print a `SKIP:` line off-platform, so it is deferred to the
> [backend proposal][comparison] rather than shipped as a non-load-bearing example.

<!-- References -->

[concepts]: ./concepts.md
[counting]: ./concepts.md#counting
[event-group]: ./concepts.md#event-group
[overflow]: ./concepts.md#overflow-sampling
[pmi]: ./concepts.md#pmi-performance-monitoring-interrupt
[precise]: ./concepts.md#precise-sampling-and-skid
[data-source]: ./concepts.md#data-source-attribution
[branch-records]: ./concepts.md#branch-records
[symbolization]: ./concepts.md#symbolization
[build-id]: ./concepts.md#build-id
[event-space]: ./concepts.md#event-space-and-tracepoints
[numa]: ./concepts.md#numa-topology-and-page-node-oracles
[event-naming]: ./concepts.md#event-naming-and-encoding
[curation]: ./concepts.md#capability-curation
[gating]: ./concepts.md#privilege-gating
[linux]: ./linux-perf-events.md
[precise-page]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[libtraceevent]: ./libtraceevent.md
[libnuma]: ./libnuma.md
[event-naming-page]: ./event-naming.md
[macos]: ./macos.md
[comparison]: ./comparison.md
[krabs]: https://github.com/microsoft/krabsetw/tree/6900de05d8ad7a38867719974f0406d5fd57af02
[krabs-kt]: https://github.com/microsoft/krabsetw/blob/6900de05d8ad7a38867719974f0406d5fd57af02/krabs/krabs/kt.hpp#L63-L66
[krabs-pgm]: https://github.com/microsoft/krabsetw/blob/6900de05d8ad7a38867719974f0406d5fd57af02/krabs/krabs/perfinfo_groupmask.hpp#L155-L176
[winmd]: https://github.com/rumbu13/windows-d/tree/f34527ed18958ca94749c3934167ff66ec0156cc
[hcp-overview]: https://learn.microsoft.com/windows/win32/api/_hcp/
[hcp-enable]: https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-enablethreadprofiling
[hcp-read]: https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-readthreadprofilingdata
[ns-perfdata]: https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-performance_data
[ns-hcdata]: https://learn.microsoft.com/windows/win32/api/winnt/ns-winnt-hardware_counter_data
[ne-hctype]: https://learn.microsoft.com/windows/win32/api/winnt/ne-winnt-hardware_counter_type
[wdk-ke]: https://learn.microsoft.com/windows-hardware/drivers/ddi/ntddk/nf-ntddk-kesethardwarecounterconfiguration
[etw-tsi]: https://learn.microsoft.com/windows/win32/api/evntrace/nf-evntrace-tracesetinformation
[etw-tqic]: https://learn.microsoft.com/windows/win32/api/evntrace/ne-evntrace-trace_query_info_class
[etw-props]: https://learn.microsoft.com/windows/win32/api/evntrace/ns-evntrace-event_trace_properties
[etw-start]: https://learn.microsoft.com/windows/win32/api/evntrace/nf-evntrace-starttracew
[wpt-pmu]: https://learn.microsoft.com/windows-hardware/test/wpt/recording-pmu-events
[wpt-xperf]: https://learn.microsoft.com/windows-hardware/test/wpt/using-xperf-profiles
[dbg-sym]: https://learn.microsoft.com/windows/win32/api/dbghelp/nf-dbghelp-symfromaddr
[dbg-line]: https://learn.microsoft.com/windows/win32/api/dbghelp/nf-dbghelp-symgetlinefromaddr64
[numa-glpi]: https://learn.microsoft.com/windows/win32/api/sysinfoapi/nf-sysinfoapi-getlogicalprocessorinformationex
[numa-vaen]: https://learn.microsoft.com/windows/win32/api/memoryapi/nf-memoryapi-virtualallocexnuma
[numa-qws]: https://learn.microsoft.com/windows/win32/api/psapi/nf-psapi-queryworkingsetex
