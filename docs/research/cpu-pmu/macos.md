# macOS (kpc / kperf / DTrace / Instruments)

The macOS mapping of the survey's [seven concerns][concepts]: a genuinely
capable Apple-Silicon CPMU that is **fenced behind root-or-entitlement and a
kernel event allowlist**, reached by third parties either through
**Instruments/`xctrace`** (an entitled broker) or through the one unprivileged
door — `proc_pid_rusage`, the fixed-counter [counting][counting] path that on
this box turns out _richer_ than Linux `/proc`.

| Field              | Value                                                                                                                            |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------- |
| OS                 | macOS **26.3.1** (build 25D771280a)                                                                                              |
| ISA                | ARMv8 / Apple Silicon (not [PMUv3][arm]) — the CPMU                                                                              |
| Hardware           | Apple **M4 Max** (`Mac16,5`, SoC **T6041**, `hw.cpufamily 0x17d5b93a`) `[hw-verified: aarch64-darwin]`                           |
| Counting APIs      | `proc_pid_rusage(RUSAGE_INFO_V4)` (unprivileged) · `kpc` via `kperf.framework` (root) · `xctrace` (unprivileged, brokered)       |
| Sampling           | `kperf` PET/PMI + hardware PC-capture (`S3_1_C15_C14_1`) — root/blessed or Instruments only                                      |
| Symbolization      | Mach-O + dSYM (DWARF) via `atos`/`symbols`, engine `CoreSymbolication.framework` (closed)                                        |
| Event catalog      | on-disk **kpep** DB plists (`/usr/share/kpep/`, world-readable) + the kernel `RESTRICT_TO_KNOWN` allowlist (102 events on T6041) |
| Open-source anchor | **xnu-12377.1.9** + **dtrace-413** (source drops); **dyld** open, not cloned                                                     |
| Verification       | `[hw-verified: aarch64-darwin]` for `mac-bsn` transcripts; `[source-verified]` for xnu/dtrace reads                              |

> [!IMPORTANT]
> **This page is grounded in recorded `mac-bsn` transcripts, not a CI probe.**
> There is no `aarch64-darwin` machine in CI and CI cannot reach `mac-bsn`, so —
> unlike the Linux deep-dives — no runnable example ships here; the five in-page
> experiment transcripts (Exp. a–e) _are_ the hardware evidence, tagged
> `[hw-verified: aarch64-darwin]`. Everything read from the kernel is tagged
> `[source-verified]` against the open-source drop. **One version skew to keep in
> mind:** `mac-bsn` _runs_ kernel **xnu-12377.91.3** (`RELEASE_ARM64_T6041`), but
> the public source drop is **xnu-12377.1.9** — same `12377` base for the same
> die, so the code read is representative, but every line number below is from
> `12377.1.9`. All experiments ran **unprivileged (uid 501)**; `sudo -n` needs a
> password on this box, so nothing requiring root was attempted — the EPERM
> boundary is observed from the outside.

---

## Overview

### What it acquires

Apple Silicon has a full-featured core performance-monitoring unit (the **CPMU**):
2 fixed counters, 5 configurable counters exposed to software, counter-overflow
PMIs, and hardware PC-capture. The catch is entirely one of _policy_. The real
configuration-and-read surface is the kernel's **`kpc`** subsystem, and almost
every `kpc` operation is gated behind `ktrace_read_check()` — which the source
states in one comment ([`kern_kpc.c:405-408`][kpc-c]):

> _"Require kperf access to read or write anything else. / This is either root or
> the blessed pid."_

Only three `kpc` sysctls — `classes`, `config_count`, `counter_count` — answer
before that check; everything that would actually _program_ or _read_ a counter
returns `EPERM` to an unprivileged caller. On a stock release kernel there is
**no entitlement escape**: the `com.apple.private.ktrace-allow` path is compiled
in only under `DEVELOPMENT || DEBUG` ([`kern_ktrace.c:279-282`][ktrace-c]). And
even root cannot program an _arbitrary_ raw selector — a kernel-baked allowlist
(`RESTRICT_TO_KNOWN`, 102 events on T6041) stands behind the privilege gate.

So a third party has exactly three ways in, and the whole page is the story of
those three tiers:

1. **`proc_pid_rusage`** — unprivileged, whole-process, the two fixed counters.
2. **`kpc`** (via the private `kperf.framework`) — root/blessed, full 2+5 counting
   and sampling.
3. **`xctrace`/Instruments** — unprivileged but _brokered_ through an entitled
   helper; the sanctioned UI.

### Design philosophy: capable but curated

macOS's bet is the opposite of Linux's. Linux lets any unprivileged process open
almost any `config` value (subject to [`perf_event_paranoid`][gating]); macOS
_curates_ — it exposes a vetted event list and a privilege wall, and points third
parties at Instruments. This puts it in the same [capability-curation][curation]
family as [Windows][windows] (whose HAL profile-sources are likewise a small
architected set), and squarely against Linux's open-selector stance. The
practical upshot for a portable harness is that "counter opened" must be a
_runtime capability probe_, never an assumption — the survey's recurring theme,
and nowhere more true than here.

---

## How it works

Three layers sit between a consumer and the CPMU. The kernel core is open; the
userspace frameworks and the symbolication engine are closed and only
reverse-engineered.

| Layer                 | Component                                               | Open?      | Role                                                                                                |
| --------------------- | ------------------------------------------------------- | ---------- | --------------------------------------------------------------------------------------------------- |
| **1 — kernel core**   | XNU `kpc` / `kperf` / `cpc` / `monotonic`               | open (xnu) | counter config/read, PMI sampling, single-owner CPMU arbitration, fixed-counter (`monotonic`) reads |
| **2 — userspace**     | `kperf.framework` / `kperfdata.framework`               | **closed** | thin `kpc_*` / `kpep_*` wrappers over the `kpc.*` sysctls and the kpep DBs                          |
| **3 — sanctioned UI** | Instruments / `xctrace` + `CoreSymbolication.framework` | **closed** | the entitled broker that reaches `kperf` for unprivileged users; symbolizes via dSYM                |

```text
  consumers   proc_pid_rusage(V4)      kpc.* sysctls          xctrace / Instruments
              (unprivileged)           (root or blessed)      (unprivileged, brokered)
                    │                        │                        │
                    │                        ▼                        ▼
                    │                  kperf.framework          entitled helper
                    │                  kperfdata.framework            │
                    ▼                        ▼                        ▼
  XNU core     monotonic  ◄──────  kpc  ◄─────  kperf (PET/PMI, callstacks)  ──►  kdebug
              (2 fixed PMCs)        │                                             (ktrace)
                                    ▼
                                   cpc   (single-owner CPMU arbitration; RESTRICT_TO_KNOWN)
                                    │
                                    ▼
                          CPMU hardware — Apple M4 Max / T6041
```

The `kpc` sysctl dispatcher (`kpc_sysctl`, [`kern_kpc.c:380-500`][kpc-c]) is the
gate: it breaks out early for the three public enumeration requests, then calls
`ktrace_read_check()` for everything else. `ktrace_read_check()` resolves to
_"current proc owns ktrace, **or** is superuser"_
([`kern_ktrace.c:288-297`][ktrace-c] → `_current_task_can_own_ktrace`,
[`:273-285`][ktrace-c]). The rest of this page walks the CPMU concern by concern.

---

## Scalar counting: three privilege tiers

Counting is where macOS is most interesting, because the three tiers land at
different privilege levels with different granularity. `[source-verified]` +
`[hw-verified: aarch64-darwin]`.

| Tier  | Path                                          | Privilege                   | Counters                                 | Granularity / notes                                          |
| ----- | --------------------------------------------- | --------------------------- | ---------------------------------------- | ------------------------------------------------------------ |
| **0** | `proc_pid_rusage(RUSAGE_INFO_V4)`             | **unprivileged**            | 2 fixed (`ri_instructions`, `ri_cycles`) | whole-process aggregate; true retired instructions           |
| **1** | `kpc` via `kperf.framework` / `kpc.*` sysctls | **root or blessed pid**     | 2 fixed + 5 configurable                 | per-thread (`kpc_get_thread_counters`); single-owner `EBUSY` |
| **2** | `xctrace record --template 'CPU Counters'`    | **unprivileged (brokered)** | via the entitled `kperf` helper          | Instruments-mediated; deferred trace                         |

### Tier 0: `proc_pid_rusage`, the unprivileged fixed counters

`proc_pid_rusage(pid, RUSAGE_INFO_V4, …)` returns per-process `ri_instructions`
and `ri_cycles` with **no root and no entitlement**
([field defs `bsd/sys/resource.h:365-366`][resource-h]). These are the XNU
"monotonic" fixed counters — `MT_CORE_INSTRS` / `MT_CORE_CYCLES`, read directly
from the fixed cycle PMC `S3_2_C15_C0_0` (= PMC0)
([`kern_monotonic.c:154,167,182-199`][monotonic-c]). This is the macOS analog of
the sparkles [`tier0`][baseline] cheap counters — and, unlike Linux `/proc`, it
delivers _true retired-instruction and core-cycle_ counts. Measured over a spin
loop (Exp. b): a delta of **300,055,815 instructions / 106,386,622 cycles**, an
[IPC][counting] of **2.82** `[hw-verified: aarch64-darwin]`.

### Tier 1: `kpc`, and the EPERM boundary

Everything richer than the two fixed counters lives behind `kpc`. Only three
`kpc` sysctls are public — `REQ_CLASSES`, `REQ_CONFIG_COUNT`, `REQ_COUNTER_COUNT`
break out of the dispatcher _before_ the access check
([`kern_kpc.c:398-413`][kpc-c]); the `default:` case calls `ktrace_read_check()`.
Exp. a probes the boundary from an unprivileged process, and it matches the
source exactly — enumeration succeeds, every configure/read is `EPERM`:

```text
== kpc unprivileged acquisition probe ==   (uid=501)
-- public enumeration (no access check) --
  sysctl kpc.classes              = 11        # FIXED(1) | CONFIGURABLE(2) | RAWPMU(8)
  sysctl kpc.pc_capture_supported = 1
  kpc_get_counter_count(FIXED)    = 2
  kpc_get_counter_count(CONFIG)   = 5
  kpc_get_config_count(CONFIG)    = 5
-- gated configure / read (ktrace_read_check) --
  sysctl kpc.thread_counters      -> EPERM (errno 1)
  sysctl kpc.counting             -> EPERM (errno 1)
  kpc_set_config(CONFIG)          -> EPERM (errno 1)
  kpc_set_thread_counting(F|C)    -> EPERM (errno 1)
  kpc_set_counting(F|C)           -> EPERM (errno 1)
  kpc_get_thread_counters         -> EPERM (errno 1)
  kpc_force_all_ctrs_get / _set   -> EPERM (errno 1)
```

`[hw-verified: aarch64-darwin]` (Exp. a). Two footnotes to the transcript.
`kpc_get_classes` is **not** exported by the framework (resolves to `0x0`); the
class mask is read via the `kpc.classes` sysctl, and `POWER(4)` is absent to
userspace (`classes=11 = FIXED|CONFIGURABLE|RAWPMU`). And `force_all_ctrs` is
**no longer a userspace lever** — older reverse-engineered headers expose
`kpc_force_all_ctrs_set`, but on `12377` the whole-machine arbitration moved
inside the kernel (see below) and the framework call just returns `EPERM`
unprivileged regardless. The fixed counters here are the same
`MT_CORE_CYCLES`/`MT_CORE_INSTRS` that Tier 0 reads without any of this.

### Single-owner arbitration: `EBUSY`

The CPMU is a **single-owner** resource. Even a privileged `kpc` caller is refused
with `EBUSY` when the hardware is already claimed (e.g. by a running Instruments
session): `kpc_sysctl` checks `cpc_hw_in_use(CPC_HW_CPMU)` and returns `EBUSY`
before touching the hardware ([`kern_kpc.c:417-419`][kpc-c]). The arbitration is
an atomic `cmpxchg NULL→owner` in `cpc_hw_acquire` / `cpc_hw_in_use`
([`cpc.c:44-70`][cpc-c], with the power-management handoff in
[`kpc_common.c:167-264`][kpc-common-c]). There is no Linux-style per-event
[grouping][event-group] seam here — the CPMU is claimed whole, by one owner.

> [!NOTE]
> **Tier 2 (`xctrace`) is the third-party escape hatch.** `xctrace record
--template 'CPU Counters'` ran **unprivileged** on `mac-bsn` and produced a
> trace with real counter data (Exp. e, below): it brokers `kperf` through an
> entitled helper rather than opening `kpc` directly. It is the sanctioned path
> a non-root tool uses when it needs the configurable counters or sampling.

---

## Overflow and IP sampling: `kperf` and PC-capture

[Sampling][sampling] on macOS is `kperf`. Two triggers drive `kperf_sample`,
which walks the user/kernel callstack into the kperf buffer: **timers**
(`kptimer.c`) and **counter PMIs**. **PET** ("Profile Every Thread") samples all
threads on a timer tick ([`pet.c:30-46`][pet-c]):

> _"Profile Every Thread (PET) provides a profile of all threads on the system
> when a timer fires."_

On a counter [overflow][overflow] PMI, `kpc_sample_kperf` routes into
`kperf_sample` ([`kpc_common.c:556-579`][kpc-common-c]). Hardware **PC-capture on
overflow** — the Apple-Silicon precise-IP analog — is present: the PMI handler
reads special register `S3_1_C15_C14_1` and extracts the captured PC
(`HAS_CPMU_PC_CAPTURE`, `PC_CAPTURE_PC`, [`arm64/kpc.c:824-838`][arm64-kpc-c]),
with `kpc.pc_capture_supported = 1` confirmed on the box (Exp. a). When a counter
lacks PC-capture it falls back to the interrupt-frame PC — i.e. ordinary
[skid][precise]. Crucially, the whole sampling surface is reachable **only** via
`kperf` (root/blessed) or Instruments; there is no unprivileged sampling door
analogous to Tier 0's counting. `[source-verified]` + `[hw-verified: aarch64-darwin]`.

---

## Precise data-source sampling: absent

**No PEBS/SPE-style data-source or data-address sampling is exposed to third
parties.** The CPMU carries a PC on overflow (above), but the `kpc`/`kperf`
interface surfaces **no data virtual/physical address, no access latency, and no
memory-hierarchy source packet** — there is nothing analogous to Linux's
`perf_mem_data_src` union or its [data-source attribution][datasrc]. The kernel
sources bear this out: `bsd/kern/kern_kpc.c` and `osfmk/kern/kpc*.c` expose only
counter values, configs, periods, and action-ids — no data-source union.
`[source-verified]` (absence).

The hardware _has_ the raw ingredients — Apple's latency-threshold registers
`PMTRHLD*` exist (documented in the [ARM deep-dive's][arm] Apple sidebar via
`applecpu`'s `PMCKext2.c`) — but they are not surfaced as a data-source sampling
API. This is the concern that simply has no answer on macOS, the way it has no
answer on [RISC-V][riscv]; the rich cross-vendor data-source story
([`precise-sampling.md`][precise-page]) is a Linux-and-`perf` phenomenon.

---

## Code-space decode: dyld, Mach-O and dSYM

macOS's [symbolization][symbolization] inputs differ structurally from Linux's,
in two ways worth a harness's attention.

### The address-space model comes from dyld, not per-mmap records

The module map is read from **dyld**: `_dyld_image_count` /
`_dyld_get_image_{header,name,vmaddr_slide}` in-process (or `task_info(…,
TASK_DYLD_INFO)` → `dyld_all_image_infos` for another process). Exp. b enumerated
**45 images** this way `[hw-verified: aarch64-darwin]`. The structural contrast
with Linux is the **shared cache single slide**: all system dylibs live in the
**dyld shared cache** (one mapped region), so they share **one** `vmaddr_slide`,
whereas the main executable has its own:

```text
_dyld_image_count() = 45
  [ 0] hdr=0x104a08000 slide=0x4a08000  /private/tmp/mt_probe        # main exe: own slide
  [ 1] hdr=0x191aab000 slide=0x1b00000  /usr/lib/libSystem.B.dylib   # shared cache…
  [ 2] hdr=0x191aa5000 slide=0x1b00000  /usr/lib/system/libcache.dylib
  … [44] slide=0x1b00000  /usr/lib/libc++.1.dylib                     # …all one slide
```

Where Linux emits one `PERF_RECORD_MMAP2` per DSO segment, macOS gives one slide
for the entire system-library set plus a per-executable slide. `dyld` is
open-source (`apple-oss-distributions/dyld`) but was **not cloned** — the public
`<mach-o/dyld.h>` API was exercised directly.

### Debug info: Mach-O + dSYM via CoreSymbolication

Symbolization to `file:line` needs Mach-O + a **dSYM** (DWARF) bundle, resolved by
`atos` / `symbols`; the engine is the closed **`CoreSymbolication.framework`**.
Exp. c: `atos -o <dSYM> 0x…460` → `square (in sym2) (sym2.c:2)`; `symbols` reports
`[… Dwarf, FunctionStarts]` provenance. `dladdr` alone gives only symbol-table
names — no `file:line`. `[hw-verified: aarch64-darwin]`.

> [!WARNING]
> **A one-shot `clang -g src.c -o bin` yields an _empty_ dSYM.** `dsymutil` needs
> the intermediate `.o` retained to find the DWARF; a single-step build deletes
> the temp object, and `dsymutil` then warns _"no debug symbols in executable"_
> and `atos` degrades to symbol-only (no line). The fix is a two-step build that
> keeps the object: `clang -g -O0 -c sym2.c -o sym2.o && clang -g -O0 sym2.o -o
sym2 && dsymutil sym2`. This is the macOS analog of Linux's
> [build-id / stale-binary hazard][build-id] — get the debug-info plumbing wrong
> and symbolization silently degrades rather than failing loudly.

The [unwinding][unwinding] and DWARF details themselves are the same story as
Linux (deferred to [`elfutils.md`][elfutils]); only the container (Mach-O/dSYM)
and the engine (CoreSymbolication) are macOS-specific.

---

## Event-space and tracing: kdebug, DTrace, no `cpc` provider

macOS's [event-space][eventspace] is **kdebug/ktrace** (kperf emits kdebug events
that Instruments consumes) plus **DTrace**. The survey opened with a hypothesis
that macOS might offer a DTrace `cpc` (CPU-performance-counter) provider — the
Solaris `dcpc` one-liner path. **It does not.**

> [!WARNING]
> **Refuted: there is no DTrace `cpc` provider on macOS.** xnu's `bsd/dev/dtrace/`
> ships `fbt`, `sdt`, `systrace`, `profile_prvd`, `fasttrap`, `lockstat`, and
> `lockprof` — but **no `dcpc`/`cpc`** — and `apple-dtrace@dtrace-413` contains no
> `*cpc*` source at all. The Solaris `dcpc` provider was never ported. So even
> _with_ root, the CPU-counter-via-DTrace path does not exist on macOS.
> `[source-verified]` ([`bsd/dev/dtrace/`][dtrace-tree] provider set; the
> [`dtrace`][dtrace-repo] tree). Recorded as a corrected hypothesis in the
> survey's internal QA ledger.

DTrace is unusable unprivileged under **SIP** anyway — `dtrace -l -P cpc` (and any
`dtrace -l`) fails at init (Exp. d):

```text
$ dtrace -l -P cpc
dtrace: system integrity protection is on, some features will not be available
dtrace: failed to initialize dtrace: DTrace requires additional privileges
```

`[hw-verified: aarch64-darwin]`. SIP is the outer wall behind the "root or blessed
pid" check — the macOS end of the survey's [privilege-gating][gating] concern.

---

## NUMA and topology: the axis collapses

Apple Silicon is **UMA** — a single memory pool, no NUMA nodes — so the
[NUMA/page→node][numa] concern that [`libnuma.md`][libnuma] models on Linux has
**nothing to model** here. Exp. e: `hw.memsize` is a single value, there are no
`hw.*node*` sysctls, and the only topology axis is the P/E core split
(`hw.nperflevels = 2`):

```text
$ sysctl hw.physicalcpu hw.nperflevels hw.perflevel0.name hw.perflevel1.name hw.memsize hw.pagesize hw.cachelinesize
hw.physicalcpu: 14   hw.nperflevels: 2
hw.perflevel0.name: Performance   (10 cores)
hw.perflevel1.name: Efficiency    (4 cores)
hw.memsize: 38654705664   hw.pagesize: 16384   hw.cachelinesize: 128
```

`[hw-verified: aarch64-darwin]`. The page size is **16 KiB** and the cache line
**128 B** — both larger than the x86 defaults a harness might assume. The
heterogeneous-core wrinkle (P vs E) is the Apple echo of ARM's
[big.LITTLE][arm] story, but without Linux's per-cluster PMU device model to
express it.

---

## Event naming and the kernel allowlist

Two layers stand between an event _name_ and the hardware selector, and the
second one is unusual: the kernel itself curates the allowed events.

### kpep DBs: the name→selector tables

Event names map to PMESR selectors through on-disk **kpep** database plists in
`/usr/share/kpep/`, one per `cpufamily`, **world-readable** (`-rw-r--r-- root
wheel`, no root needed), consumed by the closed `kperfdata.framework` (`kpep_*`).
This box's DB is reached by symlink: `cpu_100000c_2_17d5b93a.plist -> as4-1.plist`
(the M4-Max P-core catalog). `[hw-verified: aarch64-darwin]` (Exp. e). This is
macOS's entry in the [event-naming][naming] survey — the per-microarchitecture
table analog of libpfm4 / `ARM-software/data`.

### `RESTRICT_TO_KNOWN`: the allowlist even root cannot bypass

The kernel enforces an event **allowlist** by default on release kernels:
`_cpc_event_policy = CPC_EVPOL_DEFAULT` ([`cpc_arm64_events.c:74`][cpc-events-c]),
and `CPC_EVPOL_DEFAULT` resolves to **`RESTRICT_TO_KNOWN`** when `!CPC_INSECURE`
([`cpc_arm64.h:34-43`][cpc-h]). A configurable-counter event must be in a
kernel-baked list (`cpc_event_allowed`, [`:92-111`][cpc-events-c]), so **even root
cannot program an arbitrary raw PMESR selector** on a stock release kernel. The
allowlist is per-die: **102 events for T6041** (M4 Max) versus **59 for T6000**
(M1 Pro/Max) ([`cpc_arm64_events.c:379-485`][cpc-events-c]). The policy-setter's
own doc comment frames it ([`cpc_arm64.h:47-49`][cpc-h]):

> _"Change how event restrictions are applied."_

This is the direct macOS parallel to [Windows'][windows] curated architected event
set — both OSes curate the event space, and both contrast with Linux's open
`config` — the essence of the [capability-curation][curation] concern.

### T6041 uses PMUv3-architected selectors: the M4 remap, kernel-side

T6041 (M4) uses **PMUv3-architected selectors** for the common subset —
`INST_ALL=0x0008`, `CORE_ACTIVE_CYCLE=0x0011`, `ARM_BR_MIS_PRED=0x0010`,
`ARM_STALL_FRONTEND/BACKEND=0x23/0x24` — where T6000 (M1) used Apple-proprietary
numbers (`INST_ALL=0x8c`, `CORE_ACTIVE_CYCLE=0x02`). It also adds an `SME_ENGINE_*`
block. `[source-verified]` ([`cpc_arm64_events.c:382-484`][cpc-events-c] for
T6041 vs [`:118-177`][cpc-events-c] for T6000). This confirms — **from the kernel
side** — the [ARM deep-dive's][arm] M4 encoding-change finding, which reached the
same conclusion independently from the kpep DBs.

---

## The seven concerns

A compact map from the survey's [seven concerns][concepts] to where each is
answered above, and how macOS lands relative to the Linux reference model.

| #   | Concern                      | macOS answer                                                                                             | Section                                                               |
| --- | ---------------------------- | -------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| 1   | Scalar counting              | three tiers: `rusage` (unpriv, 2 fixed) · `kpc` (root, 2+5) · `xctrace` (brokered); `EBUSY` single-owner | [three tiers](#scalar-counting-three-privilege-tiers)                 |
| 2   | Overflow / IP sampling       | `kperf` PET/PMI + hardware PC-capture (`S3_1_C15_C14_1`); root/blessed or Instruments only               | [sampling](#overflow-and-ip-sampling-kperf-and-pc-capture)            |
| 3   | Precise data-source sampling | **absent** — PC-capture only; no data-VA/PA/latency packet interface exposed                             | [absent](#precise-data-source-sampling-absent)                        |
| 4   | Code-space decode            | dyld image list (shared-cache single slide) + Mach-O/dSYM via `atos`/CoreSymbolication                   | [code-space](#code-space-decode-dyld-mach-o-and-dsym)                 |
| 5   | Event space & tracing        | kdebug/ktrace + DTrace **minus a `cpc` provider**; SIP gate                                              | [event-space](#event-space-and-tracing-kdebug-dtrace-no-cpc-provider) |
| 6   | NUMA & topology              | **collapses** — UMA; only P/E perflevels                                                                 | [NUMA](#numa-and-topology-the-axis-collapses)                         |
| 7   | Event naming & encoding      | kpep DB plists + kernel `RESTRICT_TO_KNOWN` allowlist (102 events T6041); PMUv3-architected remap        | [naming](#event-naming-and-the-kernel-allowlist)                      |

---

## Strengths

- **Free, unprivileged, per-process IPC — richer than Linux `/proc`.**
  `proc_pid_rusage(V4)` gives true retired-instruction and core-cycle counts with
  no privilege, no entitlement, no counter arbitration; the Linux `/proc`/tier0
  equivalent gives context-switch/fault-style counters, not instructions. For
  whole-process measurement macOS's low-privilege story is genuinely _better_.
- **A capable CPMU** — 2 fixed + 5 configurable counters, counter-overflow PMIs,
  and hardware PC-capture — when the privilege is there (root/blessed) or brokered
  (Instruments).
- **A sanctioned unprivileged path exists** — `xctrace record --template 'CPU
Counters'` reaches the configurable counters and sampling without root.
- **World-readable event catalog.** The kpep plists are readable with no
  privilege, so a tool can build a name→selector map offline even where it cannot
  program the counter.
- **Open kernel core.** The entire XNU acquisition path (`kpc`, `kperf`, `cpc`,
  `monotonic`) is open source, so the policy is fully auditable — this page's
  boundary claims are source-verified, not reverse-engineered guesses.

## Weaknesses

- **No root-free per-region raw events.** The one thing a benchmarking harness
  most wants — arbitrary configurable events bracketed around a code region —
  needs root/blessed access; unprivileged tools get only the two fixed counters
  (whole-process) or the Instruments broker.
- **Even root is fenced by the allowlist.** `RESTRICT_TO_KNOWN` refuses raw PMESR
  selectors outside `_known_cpmu_events`, so root is _not_ the escape hatch it is
  on Linux.
- **No entitlement escape on release kernels** — `com.apple.private.ktrace-allow`
  is `DEVELOPMENT || DEBUG`-only.
- **No precise data-source sampling** — no PEBS/SPE analog surfaced; concern 3 has
  no answer.
- **Single-owner CPMU** — `EBUSY` when Instruments (or any owner) holds it; no
  concurrent independent sessions.
- **Closed userspace + symbolication.** `kperf.framework`, `kperfdata.framework`,
  `CoreSymbolication.framework`, and Instruments internals are all closed and
  reverse-engineered; a native backend either links private frameworks or shells
  out to `xctrace`/`atos`.
- **dSYM plumbing is a silent foot-gun** — a one-shot build produces an empty
  dSYM and degrades symbolization to symbol-only without erroring.

## Key design decisions and trade-offs

| Decision                                            | Rationale                                                                                                           | Trade-off                                                                                 |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `kpc` gated by "root or blessed pid"                | Keeps raw counter programming out of untrusted hands                                                                | No unprivileged configurable-event access; harness must broker or run as root             |
| Unprivileged `proc_pid_rusage` fixed counters       | A safe, cheap, whole-process IPC number for any process                                                             | Only 2 fixed counters, no per-region granularity, no configurable events                  |
| `xctrace`/Instruments as the entitled broker        | Third parties get sampling/counters without shipping a privileged helper                                            | Deferred-trace UX; opaque export format; single-owner `EBUSY` contention                  |
| `RESTRICT_TO_KNOWN` event allowlist (even for root) | Curated, vetted events; matches Windows' curation stance                                                            | No raw selectors even with root; per-die allowlist must be kept current                   |
| No entitlement escape on release kernels            | Hard privilege wall behind SIP                                                                                      | Dev/debug-only `com.apple.private.ktrace-allow`; no production side-door                  |
| Single-owner CPMU arbitration (`cpc` cmpxchg)       | One coherent owner of the shared hardware                                                                           | `EBUSY` blocks concurrent sessions; whole-CPMU claim, no per-event grouping               |
| dyld shared-cache single slide                      | One relocation for the whole system-library set                                                                     | Decode differs from Linux per-DSO `MMAP2`; needs the dyld image-list API                  |
| PC-capture only (no data-source packets)            | Skid-free IP on capable counters, cheaply                                                                           | No data-VA/PA/latency; concern 3 unanswerable to third parties                            |
| **Sparkles backend capabilities advertised**        | `{process-IPC: yes (rusage) · configurable-events: no (needs root) · sampling/symbolication: via-Instruments-only}` | a macOS backend ships Tier-0 counting universally; richer modes are opt-in and privileged |

---

## Sources

**Open (read + verified).** The entire XNU acquisition path, the DTrace tree, and
the on-disk kpep DBs are open and were read directly:

- [`bsd/kern/kern_kpc.c`][kpc-c] — the `kpc_sysctl` dispatcher: public
  enumeration vs `ktrace_read_check()` gate, the "root or blessed pid" comment,
  the `EBUSY` single-owner check.
- [`bsd/kern/kern_ktrace.c`][ktrace-c] — `ktrace_read_check` /
  `_current_task_can_own_ktrace`; the `DEVELOPMENT || DEBUG`-only entitlement.
- [`osfmk/kern/kpc_common.c`][kpc-common-c] — PMI → `kperf_sample`; power-management
  arbitration handoff.
- [`osfmk/kern/cpc.c`][cpc-c] — single-owner CPMU acquisition (`cmpxchg`).
- [`osfmk/kern/kern_monotonic.c`][monotonic-c] — `MT_CORE_INSTRS`/`MT_CORE_CYCLES`
  ← fixed PMC0 (`S3_2_C15_C0_0`).
- [`osfmk/arm64/kpc.c`][arm64-kpc-c] — `kpc_pmi_handler`, PC-capture
  (`S3_1_C15_C14_1`).
- [`osfmk/arm64/cpc_arm64_events.c`][cpc-events-c] · [`cpc_arm64.h`][cpc-h] —
  `RESTRICT_TO_KNOWN` policy + the 102-event T6041 allowlist + PMUv3 remap.
- [`osfmk/kperf/pet.c`][pet-c] — PET ("Profile Every Thread").
- [`bsd/sys/resource.h`][resource-h] — `rusage_info_v4`, `ri_instructions`/`ri_cycles`.
- [`bsd/dev/dtrace/`][dtrace-tree] (xnu) + the [`apple-oss-distributions/dtrace`][dtrace-repo]
  tree — the provider set, confirming **no `cpc`/`dcpc`** provider.
- `apple-oss-distributions/dyld` — open, **not cloned**; the public
  `<mach-o/dyld.h>` API was exercised directly (Exp. b).

**Closed (reverse-engineered surfaces only).** `kperf.framework`,
`kperfdata.framework`, `CoreSymbolication.framework`, and Instruments/`xctrace`
internals are not open; their behavior here is observed from the outside
(`dlopen` symbol resolution, `xctrace` transcripts, `atos` output), never read.

- `mac-bsn:/usr/share/kpep/*.plist` — the world-readable kpep event catalog
  (`cpu_100000c_2_17d5b93a.plist → as4-1.plist`). `[hw-verified: aarch64-darwin]`

> [!NOTE]
> **No runnable CI example ships with this page.** The survey's convention is a
> [CI-compiled probe][linux] per deep-dive, but the acquisition surface here is
> macOS-and-Apple-Silicon-only and CI has no `aarch64-darwin` host. The five
> in-page transcripts (Exp. a — the `kpc` EPERM matrix; b — `rusage` IPC + dyld
> map; c — `atos`/dSYM; d — DTrace/SIP; e — topology/kpep/`xctrace`) are the
> primary evidence, tagged `[hw-verified: aarch64-darwin]`; the kernel mechanics
> are `[source-verified]` against `xnu-12377.1.9` / `dtrace-413`. Probe sources
> (`kpc_probe.c`, `mt_probe.c`, `symtest.sh`, `tools.sh`) are kept in the job
> scratchpad and on `mac-bsn:/tmp`.

<!-- References -->

[concepts]: ./concepts.md
[counting]: ./concepts.md#counting
[event-group]: ./concepts.md#event-group
[sampling]: ./concepts.md#sampling
[overflow]: ./concepts.md#overflow-sampling
[precise]: ./concepts.md#precise-sampling-and-skid
[datasrc]: ./concepts.md#data-source-attribution
[symbolization]: ./concepts.md#symbolization
[build-id]: ./concepts.md#build-id
[unwinding]: ./concepts.md#unwinding
[eventspace]: ./concepts.md#event-space-and-tracepoints
[numa]: ./concepts.md#numa-topology-and-page-node-oracles
[naming]: ./concepts.md#event-naming-and-encoding
[curation]: ./concepts.md#capability-curation
[gating]: ./concepts.md#privilege-gating
[linux]: ./linux-perf-events.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[precise-page]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[libnuma]: ./libnuma.md
[windows]: ./windows.md
[baseline]: ./sparkles-baseline.md
[kpc-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_kpc.c
[ktrace-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/kern_ktrace.c
[kpc-common-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/kpc_common.c
[cpc-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/cpc.c
[monotonic-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kern/kern_monotonic.c
[arm64-kpc-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm64/kpc.c
[cpc-events-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm64/cpc_arm64_events.c
[cpc-h]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/arm64/cpc_arm64.h
[pet-c]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/kperf/pet.c
[resource-h]: https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/resource.h
[dtrace-tree]: https://github.com/apple-oss-distributions/xnu/tree/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/dev/dtrace
[dtrace-repo]: https://github.com/apple-oss-distributions/dtrace
