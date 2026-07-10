# Grounding ledger — `windows.md`

Claim-by-claim source verification of [`docs/research/cpu-pmu/windows.md`](../windows.md).
**No Windows hardware exists for this survey** — every row is either `[literature]`
(read from an official Microsoft Learn page saved to `$REPOS/papers/cpu-pmu/<file>.html`,
retrieved 2026-07-10, all HTTP 200) or `[source-verified]` (read from a pinned
open-source tree or ldc-1.41.0 druntime). **No `[hw-verified]` tag appears anywhere.**

Locators: `krabsetw` = `$REPOS/cpp/krabsetw @ 6900de05` (cloned this session,
`6900de05d8ad7a38867719974f0406d5fd57af02`, 2026-04-14); `windows-d` =
`$REPOS/dlang/windows-d @ f34527e` (`f34527ed18958ca94749c3934167ff66ec0156cc`,
2026-06-03); `druntime` = ldc-1.41.0 `.../include/d/core/sys/windows` (resolved via
`ldc2.conf`); `docs` = `$REPOS/papers/cpu-pmu/<file>.html` (base URL
`https://learn.microsoft.com`). `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                         |
| ---- | ------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (saved doc or repo, locator recorded) |
| `≈`  | Faithful paraphrase / inference from absence (no single line to point at)       |
| `⚠`  | Discrepancy vs the prompt's hypothesis — corrected + reflected in the page      |
| `◯`  | Not locally groundable — synthesis/consequence, or standard PE/PDB knowledge    |
| `🌐` | Web/secondary (none load-bearing on this page)                                  |

**Types:** `lit` (`[literature]`, saved Microsoft Learn doc) · `src`
(`[source-verified]`, krabsetw / windows-d / druntime read) · `quote` (verbatim) ·
`synth` (derived consequence / inference from absence).

## Claim ledger

Numbering follows the W5 sub-report (claims 1–36 + quote candidates Q1–Q6).

### Concern 1 — Scalar counting

| #   | Claim (short)                                                                                                                           | Type      | Source (local + locator)                                                                     | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------- | --------- | -------------------------------------------------------------------------------------------- | ------ |
| 1   | HCP counting path: `EnableThreadProfiling`/`ReadThreadProfilingData`/`Disable`/`Query`, `winbase.h`, Kernel32, min Win7/Server 2008 R2  | lit       | `win-enablethreadprofiling.html`, `win-hcp-overview.html`                                    | ✓      |
| 2   | `HardwareCounters` bitmask selects up to 16 counters **by zero-based index**, not by event                                              | lit/quote | `win-enablethreadprofiling.html` (Q2)                                                        | ✓      |
| 3   | `EnableThreadProfiling` handle **"must be the current thread"**                                                                         | lit       | `win-enablethreadprofiling.html`                                                             | ✓      |
| 4   | Counters **configured globally by a kernel driver** before profiling                                                                    | lit/quote | `win-enablethreadprofiling.html` (Q1)                                                        | ✓      |
| 5   | `PERFORMANCE_DATA` fields; **only driver-free hardware datum is `CycleTime`**; PMCs via `HwCounters[]`                                  | lit       | `win-performance-data.html`                                                                  | ✓      |
| 6   | `HARDWARE_COUNTER_DATA = {Type; Reserved; Value}`                                                                                       | lit/src   | `win-hardware-counter-data.html`; `windows-d …/performance/hardwarecounterprofiling.d:26-32` | ✓      |
| 7   | `KeSetHardwareCounterConfiguration` (ntddk.h, WDK): global, single-tenant; `HalAllocate/FreeHardwareCounters`                           | lit/quote | `wdk-kesethardwarecounterconfiguration.html` (Q3)                                            | ✓      |
| 8   | ETW counting: PMCs logged on ETW events (`CSwitch`); `xperf -pmc InstructionRetired,TotalCycles CSWITCH strict`; WPRP `HardwareCounter` | lit       | `wpt-recording-pmu-events.html`                                                              | ✓      |

### Concern 2 — Overflow / IP sampling

| #   | Claim (short)                                                                                                                                                                                       | Type      | Source (local + locator)                                           | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ------------------------------------------------------------------ | ------ |
| 9   | ETW PMC-overflow sampling; `xperf -on …+pmc_profile -pmcprofile … -stackwalk pmcinterrupt`; WPRP `SampledCounter Interval` (events)                                                                 | lit       | `wpt-recording-pmu-events.html`                                    | ✓      |
| 10  | Config classes in `TRACE_QUERY_INFO_CLASS`: `TraceSampledProfileIntervalInfo=5`, `TraceProfileSourceConfigInfo=6`, `…List=7`, `TracePmcEventListInfo=8`, `TracePmcCounterListInfo=9`; min Win7/Win8 | lit/quote | `etw-trace-query-info-class.html` (Q4 for 6)                       | ✓      |
| 11  | `TraceMaxPmcCounterQuery=22` (19H1), `TracePmcCounterOwners=25` (21H2); budget = 3 PMCs (4 w/ ctx-switch)                                                                                           | lit       | `etw-trace-query-info-class.html`; `wpt-recording-pmu-events.html` | ✓      |

### Concern 3 — Precise data-source / address sampling

| #   | Claim (short)                                                                                                                                              | Type             | Source (local + locator)                                           | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | ------------------------------------------------------------------ | ------ |
| 12  | **No public data-address/PEBS class** in `TRACE_QUERY_INFO_CLASS` (full 0–28 read); docs describe only IP+stack                                            | src/lit (ABSENT) | `etw-trace-query-info-class.html`, `wpt-recording-pmu-events.html` | ✓      |
| 13  | Kernel PEBS plumbing exists but **walled off**: undocumented internal `EVENT_TRACE_INFORMATION_CLASS` lists `EventTracePebsTracingInformation`             | src              | `krabsetw krabs/krabs/perfinfo_groupmask.hpp:155-176`              | ✓      |
| 14  | Public analogs: **LBR** `TraceLbrConfigurationInfo=20`/`…EventListInfo=21` (Win10 19H1), branch-only; `TraceContextRegisterInfo=28` (Server 23H2), GP regs | lit              | `etw-trace-query-info-class.html`                                  | ✓      |
| 15  | Arbitrary events need a **ring-0 driver** (VTune SEP, AMD uProf, closed); supported enum = `wpr/xperf -pmcsources`                                         | lit              | `wpt-recording-pmu-events.html` (+ claims 4/7)                     | ✓      |

### Concern 4 — Code-space decode & symbolization

| #   | Claim (short)                                                                                                                                             | Type  | Source (local + locator)                                                            | Status |
| --- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- | ----------------------------------------------------------------------------------- | ------ |
| 16  | DbgHelp present in druntime as lazy fn-ptrs: `SymInitialize`/`StackWalk64`/`SymSetOptions`/`SymGetLineFromAddr64`/`SymGetSymFromAddr64`/`SymLoadModule64` | src   | `druntime dbghelp.d:27-92`                                                          | ✓      |
| 17  | windows-d has modern DbgHelp `extern(Windows)` decls: `SymInitialize`/`SymFromAddr`/`SymGetLineFromAddr64`                                                | src   | `windows-d …/diagnostics/debug_/package.d:7046,7176,7252`                           | ✓      |
| 18  | PDB **out-of-band**; build-id analog = **PDB GUID+Age** (CodeView `RSDS`); symbol servers via `_NT_SYMBOL_PATH`                                           | lit/◯ | `dbghelp-symfromaddr.html`, `dbghelp-symgetlinefromaddr64.html` (+ standard PE/PDB) | ✓      |
| 19  | `MMAP2`→symbolization analog = ETW image-load events + `TraceProviderBinaryTracking=18` (Win10 1709)                                                      | lit   | `etw-trace-query-info-class.html`                                                   | ✓      |
| 20  | psapi module-enum in druntime: `EnumProcessModules`/`GetModuleInformation`/`GetMappedFileNameW`                                                           | src   | `druntime psapi.d:102,108,133`                                                      | ✓      |

### Concern 5 — Event-space & tracing

| #   | Claim (short)                                                                                                                                                          | Type      | Source (local + locator)                                                            | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ----------------------------------------------------------------------------------- | ------ |
| 21  | krabsetw = open ETW consumption model: `trace<T>` (`ut`/`kt`), `open()`→`register/enable/open_trace`→`process_trace()`; provider/parser split by `ProviderId` via TDH  | src       | `krabsetw etw.hpp:180-211`, `kt.hpp:174-186`, `kernel_providers.hpp`                | ✓      |
| 22  | Kernel-logger enablement via **undocumented** extended group-mask (`Nt[Query/Set]SystemInformation(SystemPerformanceTraceInformation)`); `PERF_PMC_PROFILE=0x20000400` | src/quote | `krabsetw kt.hpp:120-146,63-66` (Q6), `perfinfo_groupmask.hpp:61`                   | ✓      |
| 23  | Documented per-session seam = `set_trace_information` → `TraceSetInformation(handle, class, …)`                                                                        | src       | `krabsetw etw.hpp:199-211`                                                          | ✓      |
| 24  | ETW control APIs: `StartTrace`/`StopTrace` + `EVENT_TRACE_PROPERTIES(_V2)`, `EnableTraceEx2`, `ProcessTrace`, `TdhGetProperty`                                         | lit       | `etw-starttrace.html`, `etw-event-trace-properties.html`, `etw-enabletraceex2.html` | ✓      |
| 25  | Session control gated: admins / Performance Log Users / LocalSystem; PMC sessions need `SeSystemProfilePrivilege`                                                      | lit/quote | `etw-starttrace.html`                                                               | ✓      |

### Concern 6 — NUMA & topology

| #   | Claim (short)                                                                                                                                      | Type           | Source (local + locator)                                                                                       | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------------- | -------------------------------------------------------------------------------------------------------------- | ------ |
| 26  | druntime `core.sys.windows` has **zero** NUMA/`*InformationEx` topology APIs (grep)                                                                | src (ABSENT)   | `druntime` (grep: no `GetLogicalProcessorInformation(Ex)`/`GetNuma*`/`VirtualAllocExNuma`/`QueryWorkingSetEx`) | ✓      |
| 27  | windows-d has `GetLogicalProcessorInformationEx` + `SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX`, `GetNumaHighestNodeNumber`, `GetNumaProcessorNodeEx` | src            | `windows-d …/system/systeminformation.d:769,1009`                                                              | ✓      |
| 28  | `VirtualAllocExNuma` node-targeted allocation                                                                                                      | src            | `windows-d …/system/memory/package.d:743`; `numa-virtualallocexnuma.html`                                      | ✓      |
| 29  | `move_pages`-query analog = `QueryWorkingSetEx` → `PSAPI_WORKING_SET_EX_BLOCK.Node` per-page                                                       | src            | `windows-d …/system/processstatus.d:80,99,102`; `numa-queryworkingsetex.html`                                  | ✓      |
| 30  | **No sampled-data-address → node** path (follows from concern-3 absence); page→node only for a known VA                                            | synth (ABSENT) | derived from claims 12, 29                                                                                     | ✓      |

### Concern 7 — Event naming & encoding

| #   | Claim (short)                                                                                                                                                                                                           | Type      | Source (local + locator)                                              | Status |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | --------------------------------------------------------------------- | ------ |
| 31  | `HARDWARE_COUNTER_TYPE = {PMCCounter, MaxHardwareCounterType}` — a single real value; no generic encoding type at HCP                                                                                                   | lit       | `win-hardware-counter-type.html`                                      | ✓      |
| 32  | Named surface = curated architectural profile-sources (`Timer`, `TotalCycles`, `InstructionRetired`, `LLCMisses`, … + `*Fixed`) via `-pmcsources`                                                                       | lit/quote | `wpt-recording-pmu-events.html`, `wpt-using-xperf-profiles.html` (Q5) | ✓      |
| 33  | Raw/non-arch events registerable **since Win10 1903**, but only **system-global** (WPRP `ProfileSource Event/Unit/ExtendedBits` or registry), not inline; Intel `ExtendedBits` = CMask/CMaskInvert/AnyThread/EdgeDetect | lit       | `wpt-recording-pmu-events.html`                                       | ✓      |
| 34  | Naming surface is CPU-vendor-neutral, **cross-ISA** (Intel/AMD/ARM64; doc registers a Snapdragon counter) — abstracts above `perf_event_attr.config`                                                                    | lit       | `wpt-recording-pmu-events.html`                                       | ✓      |

### D-bindings reality check (feeds the backend proposal)

| #   | Claim (short)                                                                                                                                                                                                                      | Type | Source (local + locator)                | Status |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---- | --------------------------------------- | ------ |
| 35  | druntime present = `dbghelp.d`, `psapi.d`; missing = all ETW (`evntrace/evntcons/tdh`), all HCP, all NUMA/topology `*Ex`                                                                                                           | src  | `druntime` (grep)                       | ✓      |
| 36  | windows-d `@ f34527e` has every gap with exact signatures — HCP (`hardwarecounterprofiling.d:51,44`), ETW (`etw.d:143,1539,2279`), NUMA (`systeminformation.d`/`memory/package.d`/`processstatus.d`), DbgHelp (`debug_/package.d`) | src  | `windows-d` (module:line refs as cited) | ✓      |

### Quote candidates (verbatim)

| #   | Quote (subject)                                                                                                                                               | Source (local + locator)                                           | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ | ------ |
| Q1  | _"To profile hardware performance counters, you need a driver … see the KeSetHardwareCounterConfiguration function in the Windows Driver Kit (WDK)."_         | `win-enablethreadprofiling.html` (Remarks)                         | ✓      |
| Q2  | _"You can specify up to 16 performance counters. Each bit relates directly to the zero-based hardware counter index …"_                                       | `win-enablethreadprofiling.html` (`HardwareCounters`)              | ✓      |
| Q3  | _"The operating system supports only one profiling application at a time. … A thread can enable thread profiling for itself but not for other threads."_      | `wdk-kesethardwarecounterconfiguration.html`                       | ✓      |
| Q4  | _"Configures the list of profiling sources … collected counters will be emitted as part of the `PERF_PMC_PROFILE` event."_                                    | `etw-trace-query-info-class.html` (`TraceProfileSourceConfigInfo`) | ✓      |
| Q5  | _"Only a small subset of PMU events in CPU vendor's documents are implemented in Windows HAL by default. However, WPR provides a way to extend PMU events …"_ | `wpt-recording-pmu-events.html`                                    | ✓      |
| Q6  | _"Enables the configured kernel rundown flags. This ETW feature is undocumented and should be used with caution."_                                            | `krabsetw krabs/krabs/kt.hpp:63-66`                                | ✓      |

## Saved-docs URL map

Local artifacts for this page: `$REPOS/papers/cpu-pmu/*.html`, all retrieved
2026-07-10 (HTTP 200) via `curl -A Mozilla/5.0`, base URL `https://learn.microsoft.com`.
This is the local-artifact map — each `[literature]` row above cites one of these files.

| File                                         | URL path                                                                             |
| -------------------------------------------- | ------------------------------------------------------------------------------------ |
| `win-enablethreadprofiling.html`             | `/windows/win32/api/winbase/nf-winbase-enablethreadprofiling`                        |
| `win-readthreadprofilingdata.html`           | `/windows/win32/api/winbase/nf-winbase-readthreadprofilingdata`                      |
| `win-disablethreadprofiling.html`            | `/windows/win32/api/winbase/nf-winbase-disablethreadprofiling`                       |
| `win-querythreadprofiling.html`              | `/windows/win32/api/winbase/nf-winbase-querythreadprofiling`                         |
| `win-performance-data.html`                  | `/windows/win32/api/winnt/ns-winnt-performance_data`                                 |
| `win-hardware-counter-data.html`             | `/windows/win32/api/winnt/ns-winnt-hardware_counter_data`                            |
| `win-hardware-counter-type.html`             | `/windows/win32/api/winnt/ne-winnt-hardware_counter_type`                            |
| `win-hcp-overview.html`                      | `/windows/win32/api/_hcp/`                                                           |
| `wdk-kesethardwarecounterconfiguration.html` | `/windows-hardware/drivers/ddi/ntddk/nf-ntddk-kesethardwarecounterconfiguration`     |
| `etw-tracesetinformation.html`               | `/windows/win32/api/evntrace/nf-evntrace-tracesetinformation`                        |
| `etw-trace-query-info-class.html`            | `/windows/win32/api/evntrace/ne-evntrace-trace_query_info_class`                     |
| `etw-event-trace-properties.html`            | `/windows/win32/api/evntrace/ns-evntrace-event_trace_properties`                     |
| `etw-event-trace-properties-v2.html`         | `/windows/win32/api/evntrace/ns-evntrace-event_trace_properties_v2`                  |
| `etw-starttrace.html`                        | `/windows/win32/api/evntrace/nf-evntrace-starttracew`                                |
| `etw-enabletraceex2.html`                    | `/windows/win32/api/evntrace/nf-evntrace-enabletraceex2`                             |
| `etw-nt-kernel-logger-privilege.html`        | `/windows/win32/etw/configuring-and-starting-the-nt-kernel-logger-session`           |
| `wpt-recording-pmu-events.html`              | `/windows-hardware/test/wpt/recording-pmu-events`                                    |
| `wpt-using-xperf-profiles.html`              | `/windows-hardware/test/wpt/using-xperf-profiles`                                    |
| `wpt-xperf-profiles.html`                    | `/windows-hardware/test/wpt/xperf-profiles`                                          |
| `wpr-reference.html`                         | `/windows-hardware/test/wpt/wpr-reference`                                           |
| `wpr-recorder.html`                          | `/windows-hardware/test/wpt/windows-performance-recorder`                            |
| `dbghelp-symfromaddr.html`                   | `/windows/win32/api/dbghelp/nf-dbghelp-symfromaddr`                                  |
| `dbghelp-symgetlinefromaddr64.html`          | `/windows/win32/api/dbghelp/nf-dbghelp-symgetlinefromaddr64`                         |
| `dbghelp-syminitialize.html`                 | `/windows/win32/api/dbghelp/nf-dbghelp-syminitialize`                                |
| `numa-getlogicalprocessorinformationex.html` | `/windows/win32/api/sysinfoapi/nf-sysinfoapi-getlogicalprocessorinformationex`       |
| `numa-getnumahighestnodenumber.html`         | `/windows/win32/api/systemtopologyapi/nf-systemtopologyapi-getnumahighestnodenumber` |
| `numa-virtualallocexnuma.html`               | `/windows/win32/api/memoryapi/nf-memoryapi-virtualallocexnuma`                       |
| `numa-queryworkingsetex.html`                | `/windows/win32/api/psapi/nf-psapi-queryworkingsetex`                                |

Repo reads (no saved HTML — read in place): `krabsetw @ 6900de05` (`etw.hpp`,
`kt.hpp`, `perfinfo_groupmask.hpp`, `kernel_providers.hpp`), `windows-d @ f34527e`
(the four generated modules), druntime via `ldc2.conf` import path (`dbghelp.d`,
`psapi.d`, grep for absences).

## Discrepancies

These are corrections/refinements against the **prompt's** hypotheses, each reflected
in the page — not open contradictions in the source material.

- **⚠ "Curated set = cycle-only + `HARDWARE_COUNTER_DATA`": partially refuted.** HCP is
  **not** cycle-only — it can surface up to 16 PMCs via `HwCounters[]` (claim 5). But
  those require a WDK driver; the only _driver-free_ hardware datum is `CycleTime`. So
  "cycle-only" is true for the pure-usermode subset and false in general. The page
  states this precisely (metadata "driver-free = `CycleTime` only";
  [How it works (a)](../windows.md#a-hardware-counter-profiling--per-thread-counting)).
- **⚠ HCP lives in `winbase.h`, not `realtimeapiset.h`.** The sub-report's initial URL
  guesses `nf-realtimeapiset-*` 404'd; the correct pages are `nf-winbase-*` (the HCP
  `tech.root` is `hcp`). The page and every claim-1/2/3/4 citation use `winbase.h`.
- **The `TRACE_INFO_CLASS` ≡ `TRACE_QUERY_INFO_CLASS` surprise.** They are the **same
  typedef**; `TraceSetInformation`'s documented `InformationClass` parameter says "see
  `TRACE_QUERY_INFO_CLASS`". The page uses `TRACE_QUERY_INFO_CLASS` throughout (the
  name that carries the enumeration) to avoid the ambiguity.
- **1903 raw-registration refinement (sharpens concern 7).** Contrary to a naïve
  "Windows only exposes a fixed curated set", raw non-architectural events **are**
  configurable since Win10 1903 (claim 33) — but via **system-global registration**
  (WPRP/registry with `Event`/`Unit`/`ExtendedBits`), a structurally different seam
  than an inline `perf_event_attr.config` field. Presented in the page as an explicit
  refinement, not a contradiction.
- **PEBS-absent finding: CONFIRMED and sharpened.** The public `TRACE_QUERY_INFO_CLASS`
  has no PEBS/data-address class (claim 12), yet the undocumented internal enum in
  krabs (`EventTracePebsTracingInformation`, claim 13) shows the kernel _has_ the
  capability, walled off from third parties. LBR is public but branch-only; context
  registers are public on Server 23H2+ (GP regs only). Not a discrepancy — a confirmed
  and sharpened absence.
- **D-bindings gap larger than expected.** druntime has _no NUMA APIs whatsoever_ (not
  even `GetNumaHighestNodeNumber`) and no ETW/HCP — three of the four Windows surfaces
  have zero druntime coverage (claims 26, 35); windows-d covers all (claims 27–29, 36).
  Reflected in the page's [D-bindings callout](../windows.md#d-bindings).

## Claims dropped / weakened

- **Nothing dropped.** The page carries all 36 sub-report claims (1–36) and all six
  quote candidates (Q1–Q6).
- **Row 18 (PDB GUID+Age build-id analog)** rests partly on standard PE/PDB knowledge
  (the CodeView `RSDS` directory layout) beyond the two saved DbgHelp pages; the
  saved docs ground the DbgHelp API surface, the GUID+Age identity is flagged `◯`
  where it exceeds them (consistent with the sub-report's own `[literature]` marking).
- **Row 30 (no sampled-address → node)** is an `≈`/`synth` inference from the joint
  absence of claims 12 and 29, not a single cited line; labelled as derived in-page.

**Net:** 0 fabrications. Every claim is `[literature]` (a saved Microsoft Learn page,
named by file, retrieved 2026-07-10) or `[source-verified]` (`krabsetw @ 6900de05`,
`windows-d @ f34527e`, or ldc-1.41.0 druntime); **no hardware, no `[hw-verified]`
tags.** Two prompt-hypothesis corrections (HCP is not cycle-only; HCP is in
`winbase.h`, not `realtimeapiset.h`) are folded into the page; the precise-sampling
absence is **confirmed and sharpened** via the undocumented internal PEBS enum; the
Win10-1903 raw-registration path refines — but does not overturn — the curated-event
thesis.
