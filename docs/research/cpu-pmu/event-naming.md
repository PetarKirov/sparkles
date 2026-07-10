# Event naming & encoding (libpfm4 / PAPI / LIKWID / vendor tables)

The [seventh concern][c-naming] of the survey: the layer that turns `RETIRED_OPS`
into `{type=4, config=0xc1}` — and where it runs out. A human event name
(`RETIRED_INSTRUCTIONS`, `ex_ret_instr`, `INST_RETIRED.ANY`) is meaningless to
`perf_event_open(2)`; something has to map it onto the raw
`perf_event_attr.{type, config, exclude_*}` bits the ABI programs. This page
surveys the five layers that do the mapping — [libpfm4][pfmlib-h] (the shared
engine), [PAPI][papi-repo], [LIKWID][likwid-repo], Intel's public
[`intel/perfmon`][perfmon-repo], and the kernel's in-tree
[`pmu-events`][amdzen4] — and charts the two boundaries every one of them hits:
**ISA** (none covers RISC-V but the kernel) and **OS** (none reaches Windows or
macOS).

| Field           | Value                                                                                                                               |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Subject         | Event naming & encoding — symbolic name → `perf_event_attr`                                                                         |
| Naming layers   | **libpfm4** (engine) · [PAPI][papi-repo] · [LIKWID][likwid-repo] · [`intel/perfmon`][perfmon-repo] · kernel [`pmu-events`][amdzen4] |
| Encoding target | Linux `perf_event_attr.{type, config, config1, exclude_*}` (see [linux-perf-events][linux])                                         |
| Concern         | 7 of 7 — [event naming & encoding][c-naming]                                                                                        |
| ISA reach       | x86 (AMD + Intel), ARMv6–v9, POWER4–10, SPARC, s390x, MIPS, Itanium, Cell — **∅ RISC-V** in libpfm4/PAPI/LIKWID (kernel-only)       |
| OS reach        | Linux `perf_events` **only** — no Windows or macOS naming layer anywhere in the field                                               |
| Verification    | `[hw-verified: x86_64-linux]` (probe E1/E2) + `[source-verified]` (five pinned repos)                                               |
| Last reviewed   | July 11, 2026                                                                                                                       |

> [!NOTE]
> **Verification bed.** The live round trip (E1/E2 below) was run on `x86_64-linux`:
> kernel **6.18.26**, AMD **Ryzen 9 7940HX** (Zen 4, family 25 / model `0x61`),
> `perf_event_paranoid = -1`, **libpfm 4.13.0** (nixpkgs), LDC 1.41. Every ISA/OS
> coverage claim for ARM, POWER, and RISC-V is `[source-verified]` reading of the
> pinned tables — there is no non-x86 hardware, and (as this page shows) no
> non-Linux naming layer to verify against in the first place.

---

## Overview

### What it solves

`perf_event_open` takes a `perf_event_attr` whose `type`/`config` fields _are_ the
hardware programming value — for a raw x86 core event, `config` is literally the
`PERFEVTSEL` bytes (`event | umask<<8 | …`). Nobody wants to hand-assemble those.
The naming layer owns per-microarchitecture tables that translate a symbolic
string into those bits, and libpfm4 is the one most of the ecosystem shares. Its
own manual states the contract ([`pfm_get_os_event_encoding.3`][man-encode]):

> _"This is the key function to retrieve the encoding of an event for a specific
> operating system interface. … The event string, `str`, may contains sub-event
> masks (umask) and any other supported modifiers."_

Two things are load-bearing in that sentence. First, "for a specific operating
system interface" — libpfm4 does not just emit raw MSR bits, it emits them
_shaped for an OS's counter ABI_ (on Linux, `perf_events`). Second, the event
string is a small grammar (`event:umask:modifier`), not just a name.

### The field: one engine, several alternates

| Layer                   | Names from                                    | Encodes to                      | Derived metrics            | MSR-direct? | Uses libpfm4?      |
| ----------------------- | --------------------------------------------- | ------------------------------- | -------------------------- | ----------- | ------------------ |
| **libpfm4**             | own per-µarch tables (`lib/events/`)          | `perf_event_attr` (or raw PMU)  | no                         | no          | —                  |
| **PAPI**                | `papi_events.csv` presets → native names      | via **vendored** libpfm4        | yes (`DERIVED_*` RPN)      | no          | **yes** (vendored) |
| **LIKWID**              | own `perfmon_*_events.txt`                    | `perf_event` **or** raw MSR/PCI | yes (`groups/*` formulas)  | **yes**     | **no**             |
| **`intel/perfmon`**     | Intel JSON (`EventCode`/`UMask`)              | data only → perf JSON / VTune   | yes (TMA metrics)          | n/a         | no                 |
| **kernel `pmu-events`** | in-tree JSON (`amdzen4/`, `arm64/`, `riscv/`) | perf-tool `//` event syntax     | `recommended.json` metrics | no          | no                 |

libpfm4 is the hub: `perf` and PAPI both route encoding through it, and it is the
only layer that turns a bare name into a filled `perf_event_attr` with a single
C call. The others are either **independent** re-implementations (LIKWID) or
**data-only** catalogs (`intel/perfmon`, kernel `pmu-events`) that a tool must
compile itself. The rest of this page walks libpfm4 first (because everything
compares against it), then each alternate, then the two coverage boundaries.

---

## libpfm4: the name→encoding pipeline

### The entry point and its ABI-checked argument

The perf encoding call is one function ([`pfmlib.h`][pfmlib-h], `:1050`):

```c
int pfm_get_os_event_encoding(const char *str, int dfl_plm,
                              pfm_os_t os, void *args);
```

With `os == PFM_OS_PERF_EVENT`, `args` is a `pfm_perf_encode_arg_t` whose `attr`
field points at a caller-supplied `perf_event_attr` — libpfm fills it in place
([`pfmlib_perf_event.h`][pfm-perf-event-h], `:37-45`):

```c
typedef struct {
    struct perf_event_attr *attr;  /* in/out: perf_event struct pointer */
    char **fstr;                   /* out/in: fully qualified event string */
    size_t size;                   /* sizeof struct */
    int idx, cpu, flags, pad0;
} pfm_perf_encode_arg_t;
```

`[source-verified]` The `size` field is **ABI-checked** against `PFM_PERF_ENCODE_ABI0`
= **40** on LP64 (pointer, pointer, `size_t`, four `int`s including the explicit 4-byte
`pad0`); a binding with the wrong layout — classically a missing trailing pad — fails
the call. The [probe][probe] declares the D struct as exactly 40 bytes for this reason.

### PMU detection is CPUID-based

libpfm does not read `/proc/cpuinfo` to decide which table applies. `pfm_amd64_detect`
runs `cpuid(0)` for the `"AuthenticAMD"` vendor string and `cpuid(1)` for
family/model/stepping (extended family folded in when base family `== 0xf`), then
`amd64_get_revision` maps family/model onto a `PFM_PMU_*` revision; each family
PMU's `pfm_amd64_family_detect` activates only when `revision == pmu->cpu_family`.
`[source-verified]` [`pfmlib_amd64.c`][amd64-c] `:322-367`. In git HEAD the family-25
branch is:

```c
} else if (cfg->family == 25) { /* family 19h */
    if ((cfg->model >= 0x60) || (cfg->model >= 0x10 && cfg->model <= 0x1f))
        rev = PFM_PMU_AMD64_FAM19H_ZEN4;   /* covers model 0x61 */
    else
        rev = PFM_PMU_AMD64_FAM19H_ZEN3;
```

`[source-verified]` [`pfmlib_amd64.c:191-196`][amd64-c] — covering this box's model
`0x61`. (Released **4.13.0** does _not_; that is [the auto-detect hazard](#the-auto-detect-hazard).)

### The `event:umask:modifier` grammar

The event string is split on `PFMLIB_ATTR_DELIM`, defined as `":."` — **both** `:`
and `.` separate attributes ([`pfmlib_priv.h:36`][pfmlib-priv-h]). After the event
name come unit masks (`umask`) and modifiers. The AMD modifier set (`amd64_mods`,
[`pfmlib_amd64.c:37-44`][amd64-c]) is:

| Modifier | Meaning                                  | Lands in          |
| -------- | ---------------------------------------- | ----------------- |
| `k`      | monitor at privilege level 0 (kernel)    | `exclude_kernel`  |
| `u`      | monitor at privilege levels 1/2/3 (user) | `exclude_user`    |
| `e`      | edge                                     | `config` MSR bits |
| `i`      | invert                                   | `config` MSR bits |
| `c=N`    | counter-mask, range `[0-255]`            | `config` MSR bits |
| `h`      | monitor in hypervisor                    | `exclude_hv`      |
| `g`      | measure in guest                         | `exclude_guest`   |

The `e`/`i`/`c` modifiers stay in the raw `config`; `k`/`u`/`h`/`g` are lifted out
of it — [the OS-layer split](#the-os-layer-split) below.

### RAW vs HARDWARE encoding

Two encoding targets fall out of the naming layers:

- A **generic** name (`PERF_COUNT_HW_CPU_CYCLES`) resolves through the always-present
  software `perf` PMU to `type = PERF_TYPE_HARDWARE` (`0`), `config = 0` — the
  OS-abstracted event, portable across vendors, no per-µarch table needed.
- A **µarch-specific** name (`RETIRED_INSTRUCTIONS` from the `amd64_fam19h_zen4`
  table) resolves to `type = PERF_TYPE_RAW` (`4`), `config = 0xc0` — the raw AMD
  PMC event-select, which is exactly the table entry's `.code` field
  (`RETIRED_INSTRUCTIONS`, `.code = 0xc0`, [`amd64_events_fam19h_zen4.h:1603-1606`][amd64-events-h]).

`pfm_amd64_get_perf_encoding` sets `attr->type = PERF_TYPE_RAW` by default and only
reads a dynamic sysfs type (via `find_pmu_type_by_name`) when the PMU carries a
`perf_name` — the case for the IBS PMUs. `[source-verified]`
[`pfmlib_amd64_perf_event.c:59-116`][amd64-perf-c].

---

## The OS-layer split

The reason `PFM_OS_PERF_EVENT` exists — rather than just `PFM_OS_NONE`, which emits
raw PMU bits — is that perf*events owns some of the config bits itself, through
`attr.exclude*\*`rather than the MSR. After computing the raw encoding,`pfm_amd64_get_perf_encoding`**zeroes** the`EN`/`INT`/`OS`/`USR`/`GUEST`/`HOST`selector bits of`config` ([`pfmlib_amd64_perf_event.c:98-114`][amd64-perf-c]):

> _"suppress the bits which are under the control of perf_events / they will be
> ignore by the perf tool and the kernel interface / the OS/USR bits are controlled
> by the attr.exclude_\* fields / the EN/INT bits are controlled by the kernel"\_

So a `:u` modifier does **not** change `config`; it flips `attr.exclude_kernel`.
That is the whole point of naming to an _OS interface_ instead of raw silicon, and
the [probe][probe] shows it live — same `config = 0xc0`, `exclude_kernel` moving
`0 → 1`:

```text
libpfm interface version 4.0 (release: see nixpkgs libpfm)

== generic perf name (PERF_TYPE_HARDWARE) ==
  generic       PERF_COUNT_HW_CPU_CYCLES
        type=0 config=0x0  exclude_user=0 exclude_kernel=0
        fstr=perf::PERF_COUNT_HW_CPU_CYCLES:u=1:k=1:h=0:mg=0:mh=1
        count over workload window: 45369527

== µarch-specific names via the amd64_fam19h_zen4 table (PERF_TYPE_RAW) ==
  zen4-native   amd64_fam19h_zen4::RETIRED_INSTRUCTIONS
        type=4 config=0xc0  exclude_user=0 exclude_kernel=0
        fstr=amd64_fam19h_zen4::RETIRED_INSTRUCTIONS:e=0:i=0:c=0:g=0:u=1:k=1:h=0:mg=0:mh=1
        count over workload window: 75120278
  with-umask    amd64_fam19h_zen4::RETIRED_SSE_AVX_FLOPS:ADD_SUB_FLOPS
        type=4 config=0x103  exclude_user=0 exclude_kernel=0
        fstr=…RETIRED_SSE_AVX_FLOPS:ADD_SUB_FLOPS:e=0:i=0:c=0:g=0:u=1:k=1:h=0:mg=0:mh=1
        count over workload window: 3000001
  with-modifier amd64_fam19h_zen4::RETIRED_INSTRUCTIONS:u
        type=4 config=0xc0  exclude_user=0 exclude_kernel=1
        fstr=…RETIRED_INSTRUCTIONS:e=0:i=0:c=0:g=0:u=1:k=0:h=0:mg=0:mh=1
        count over workload window: 75000087
```

`[hw-verified: x86_64-linux]` Three things are self-verifying in that output. The
generic name lands `type=0`; the native name lands `type=4 config=0xc0` (the table
`.code`); the `:ADD_SUB_FLOPS` umask lands in `config[15:8]` → `0x103`; and its
count — **3,000,001** — matches the probe's 3,000,000-iteration FP-add loop exactly,
proving the encoding is live, not merely plausible. The `:u` case is the OS-layer
split caught in the act.

### There is no non-Linux OS layer

`pfm_os_t` has exactly three values ([`pfmlib.h:901-905`][pfmlib-h]):

```c
typedef enum {
    PFM_OS_NONE = 0,       /* only PMU */
    PFM_OS_PERF_EVENT,     /* perf_events PMU attribute subset + PMU */
    PFM_OS_PERF_EVENT_EXT, /* perf_events all attributes + PMU */
    PFM_OS_MAX,
} pfm_os_t;
```

`[source-verified]` `PFM_OS_NONE` is raw PMU bits; the other two are both
**perf_events**, differing only in how many `perf_event_attr` fields they populate
(`_EXT` adds the perf-only attributes — sampling `period`, `precise_ip`, etc.).
There is no `PFM_OS_WINDOWS`, no `PFM_OS_DARWIN`, no anything else. The entire OS
abstraction in libpfm4 _is_ Linux perf_events — the first half of why [no naming
layer spans OSes](#coverage-boundaries).

---

## PAPI: presets over a vendored libpfm4

PAPI does not re-implement encoding: it **vendors an in-tree copy** of libpfm4 at
`src/libpfm4` (a plain directory, not a submodule) and calls it — the perf_event
component invokes `pfm_get_os_event_encoding(name, …, PFM_OS_PERF_EVENT_EXT, …)`
for the actual bits. `[source-verified]` [`papi@ec16e00f`][papi-bridge]
`src/components/perf_event/pe_libpfm4_events.c:199-201`.

What PAPI adds on top is a **preset** layer. `src/papi_events.csv` holds 179
`CPU,<libpfm-pmu>` sections (keyed by libpfm4 PMU name — `amd64_k7`,
`amd64_fam19h_zen4`, `arm_ac76`, …), each mapping a portable `PAPI_*` name onto
native events plus optional arithmetic ([`papi_events.csv`][papi-csv]):

```text
CPU,amd64_fam19h_zen4
PRESET,PAPI_TOT_INS,NOT_DERIVED,RETIRED_INSTRUCTIONS
PRESET,PAPI_FP_OPS,DERIVED_SUB,RETIRED_MMX_AND_FP_INSTRUCTIONS:…,DISPATCHED_FPU:OPS_STORE
```

`[source-verified]` The derivations (`DERIVED_ADD`/`DERIVED_SUB`/`DERIVED_POSTFIX`,
the last an RPN expression) make a preset a per-µarch _arithmetic combination_ of
native events, not just an alias.

> [!NOTE]
> **Refuted hypothesis.** A prior guess held that PAPI's presets are unmapped on
> modern microarchitectures. They are **not**: `papi_events.csv` carries explicit
> `CPU,amd64_fam19h_zen4` **and** `CPU,amd64_fam1ah_zen5` sections (`:514-515`).
> PAPI's boundary is the one it inherits from libpfm4 — `arm_*` sections but **no
> RISC-V and no Apple** — a refuted prompt hypothesis, recorded in the survey's
> internal QA ledger.

---

## LIKWID: an independent stack with a wider OS reach

LIKWID is fully independent of libpfm4 (`grep -ril libpfm src/` → **empty**). It
ships its own hand-maintained event lists (`src/includes/perfmon_zen4_events.txt`,
authored "Thomas Gruber (tr)"), its own per-arch counter maps, and its own
derived-metric groups. `[source-verified]` [`likwid@f23c6663`][likwid-events].

Two things distinguish it from the libpfm4/PAPI stack:

**A three-way access split.** LIKWID can reach counters three ways
([`likwid.h:297-301`][likwid-h], [`access.c`][likwid-access]):

| `ACCESSMODE` | Value | Path                    | Reaches                          |
| ------------ | ----- | ----------------------- | -------------------------------- |
| `PERF`       | `-1`  | `perf_event_open`       | core PMUs, unprivileged          |
| `DIRECT`     | `0`   | raw MSR / PCI           | + uncore, frequency (root)       |
| `DAEMON`     | `1`   | setuid `likwid-accessD` | + uncore via a privileged broker |

The direct/daemon modes reach uncore and frequency that the perf naming path
cannot — the source is explicit: _"Cannot manipulate Uncore frequency with
ACCESSMODE=perf_event"_ ([`frequency_uncore.c:191`][likwid-access]). This is the
[MSR-direct][c-uncore] alternative to going through `perf_event_attr` at all.

**Performance groups.** A LIKWID group bundles an `EVENTSET` (named events → counter
slots), a `METRICS` block (formulas over those slots), and a `LONG` prose
description — e.g. [`groups/zen4/CPI.txt`][likwid-cpi]:

```text
EVENTSET
PMC0  RETIRED_INSTRUCTIONS
PMC1  CPU_CLOCKS_UNHALTED
METRICS
CPI PMC1/PMC0
IPC PMC0/PMC1
```

Crucially, **LIKWID out-covers libpfm4 on the OS/vendor axis**: it is the only
surveyed layer shipping an **Apple M1** event table (`perfmon_applem1_events.txt`),
alongside **Graviton3** and **A64FX** (`perfmon_graviton3_events.txt`,
`perfmon_a64fx_events.txt`) — and AMD L3/uncore events inside its Zen 4 list.
`[source-verified]` [`src/includes/perfmon_*`][likwid-apple]. But the Apple M1 table
is a LIKWID-internal event list, **not** a macOS OS API — it still narrows to the
[macOS `kpep`][macos] database at acquisition time.

---

## `intel/perfmon` and the kernel's tables: data, not engines

Intel publishes its event catalog as JSON in the public [`intel/perfmon`][perfmon-repo]
repo. Each event carries `EventCode`, `UMask`, `EventName`, `BriefDescription`,
`Counter`, `PublicDescription`, `PEBS`, `Deprecated` (uncore events add `Unit`,
`PortMask`, `FCMask`, `UMaskExt`, `Filter`); files are keyed to silicon by
`mapfile.csv` (`GenuineIntel-6-XX` → `Filename`, `EventType`, `Core Type`).
`[source-verified]` [`intel-perfmon@683a4d0b`][perfmon-mapfile] `mapfile.csv`,
[`SKX/events/*.json`][perfmon-skx]. Separately it ships **TMA metric** JSONs
(`ICX/metrics/icelakex_metrics.json` — 282 metrics with `MetricName`, TMA `Level`,
`Events[]`, `Formula`) plus a `metrics/perf/` variant already in perf-tool syntax.
`[source-verified]` [`ICX/metrics/…`][perfmon-metrics].

The provenance is the surprising part. `intel/perfmon` is not just a reference — its
own `scripts/create_perf_json.py` (© Intel + Google) is documented to emit, verbatim:

> _"OUTPUT: A perf json directory suitable for the tools/perf folder."_

`[source-verified]` [`scripts/create_perf_json.py:12`][perfmon-genjson]. Intel
**self-generates** the kernel's Intel `pmu-events` from this repo; it is the
machine-readable upstream of what perf ships.

---

## The vendor-table asymmetry

AMD has **no public analogue** of `intel/perfmon`. `ls intel-perfmon | grep -i amd`
is empty and every `mapfile.csv` key is `GenuineIntel-*`. The AMD event tables live
_only_ in the kernel tree, contributed directly by AMD:

`tools/perf/pmu-events/arch/x86/amdzen4/{branch,cache,core,data-fabric,floating-point,memory,memory-controller,other,pipeline,recommended}.json`,
keyed `AuthenticAMD-25-[[:xdigit:]]+,v1,amdzen4,core`, and authored by
`Sandipan Das <sandipan.das@amd.com>` ("perf vendor events amd: Add Zen 4 core
events"). `recommended.json` even carries perf-syntax metrics —
`branch_misprediction_ratio` with `MetricExpr = d_ratio(ex_ret_brn_misp, ex_ret_brn)`.
`[source-verified]` [`linux@e43ffb69e043`][amdzen4] `mapfile.csv`, `amdzen4/`,
`git log`.

So the provenance is asymmetric — Intel maintains a public generator, AMD pushes
JSON straight into the kernel — and so are the **name spaces**. The same 0xc0
event-select is `RETIRED_INSTRUCTIONS` in libpfm4 but `ex_ret_instr` in the kernel's
`amdzen4/core.json` ([`core.json:34-36`][amdzen4-core]). There is **no single
canonical AMD event vocabulary**; a backend that wants to accept both must carry a
cross-walk.

---

## Coverage boundaries

Two axes bound every layer: which **ISA** it has tables for, and which **OS** it can
target. Cells give the covering table, `∅` for none, or a qualifier.

| Layer                   | x86            | ARM                                 | POWER       | RISC-V                      | Windows                       | macOS |
| ----------------------- | -------------- | ----------------------------------- | ----------- | --------------------------- | ----------------------------- | ----- |
| **libpfm4**             | AMD + Intel    | armv6–v9, Cortex, uncore            | 4–10        | **∅**                       | ∅                             | ∅     |
| **PAPI**                | via libpfm4    | via libpfm4                         | via libpfm4 | **∅**                       | ∅                             | ∅     |
| **LIKWID**              | own + uncore   | A57, **Apple M1**, Graviton3, A64FX | ∅           | **∅**                       | ∅ (M1 table is not an OS API) | ∅     |
| **`intel/perfmon`**     | **Intel only** | ∅                                   | ∅           | ∅                           | (data feeds VTune)            | ∅     |
| **kernel `pmu-events`** | AMD + Intel    | arm64 (per-vendor)                  | powerpc     | **sifive, thead, andes, …** | ∅                             | ∅     |

`[source-verified]` Two findings stand out. libpfm4/PAPI/LIKWID/`intel-perfmon`
carry **zero** RISC-V tables — libpfm4 has no `lib/events/*riscv*` and no
`lib/pfmlib_*riscv*` at all — yet the kernel `pmu-events` tree _does_
(`arch/riscv/{sifive,thead,andes,openhwgroup,starfive}/`), the one surveyed layer
with any RISC-V naming (see [riscv][riscv]). And **nothing spans operating systems**:
every layer above targets Linux `perf_events` or is OS-agnostic _data_ that a Linux
tool consumes.

The two non-Linux OSes are covered by their own deep-dives, and neither offers a
name→encoding layer resembling libpfm4:

- **Windows** — the only curated name set is the small architected list behind
  `EnableThreadProfiling`/`ReadThreadProfilingData`; arbitrary events go through raw
  `ProfileSource` IDs or vendor drivers (VTune SEP, AMD uProf) with private tables.
  This is [capability curation][c-curation], not open naming → [windows][windows].
- **macOS** — naming is Apple's `kpep` `.plist` database consumed by `kpc`/Instruments;
  M-series remap onto PMUv3-style numbers. LIKWID's `applem1` table is the closest
  portable Apple name set, but it is LIKWID-internal, not an OS API → [macos][macos].

**Implication for the sparkles backend:** it must own its event-name vocabulary. No
existing layer spans Linux + Windows + macOS, so a portable harness cannot delegate
naming to one library the way it can delegate Linux _acquisition_ to `perf_event_open`.

---

## The auto-detect hazard

> [!WARNING]
> **A shipped libpfm can be too old for the silicon in the machine.** Stock
> **libpfm 4.13.0** (the current nixpkgs build) **fails to auto-detect** this Ryzen 9
> 7940HX's core PMU. Its released family-25 detect maps only decimal-17 (`model == 0x11`)
> to Zen 4 (`if (model <= 0x0f || (model >= 0x20 && model <= 0x5f)) ZEN3; else if
(model == 17) ZEN4;`), so model `0x61` matches nothing, `revision` stays
> `PFM_PMU_NONE`, and a bare `pfm_get_os_event_encoding("RETIRED_INSTRUCTIONS", …)`
> returns `PFM_ERR_NOTFOUND (-4)`. Only the software `perf`/`perf_raw` PMUs activate.
> `[hw-verified: x86_64-linux]` (probe E2) + `[source-verified]` (nixpkgs 4.13.0 src).
> **git HEAD fixes it** (`model >= 0x60`, [`pfmlib_amd64.c:191-196`][amd64-c]).

The table is _compiled in_ — `strings libpfm.so.4.13.0 | grep amd64_fam19h_zen4`
shows every symbol present — it is only **inert** because detection never selected it.
Two workarounds are proven live (E2): `LIBPFM_FORCE_PMU=amd64_fam19h_zen4` (bare
native names resolve, but generic `cycles`/`instructions` then fail — forcing is
exclusive), **or** `LIBPFM_ENCODE_INACTIVE=1` plus an explicit `amd64_fam19h_zen4::`
prefix (which is what the [probe][probe] does). `[hw-verified: x86_64-linux]`.

**Design lesson.** Do not trust libpfm auto-detect on very recent silicon. A robust
backend derives the correct table name from CPUID itself — exactly what a fixed
`detect()` would pick — and forces the PMU, or requires a libpfm new enough for the
part. The probe mirrors the _fixed_ `amd64_get_revision` in D from `/proc/cpuinfo` for
precisely this reason.

---

## The seven concerns

Naming is concern 7, but it is the connective tissue for the others: every counting
or sampling request is a _named event_ before it is a `config` value. The
interactions worth flagging:

| #   | Concern                             | How naming touches it                                                                                                       | Owner                       |
| --- | ----------------------------------- | --------------------------------------------------------------------------------------------------------------------------- | --------------------------- |
| 1   | [Scalar counting][c-counting]       | Naming produces the `config` counting reads; the [OS-layer split](#the-os-layer-split) routes `u`/`k` into `exclude_*`      | [linux][linux] · this page  |
| 2   | Overflow / IP sampling              | Same name→`config`; sampling-only attrs (`period`, `precise_ip`) are added at `PFM_OS_PERF_EVENT_EXT`, not in the name      | [linux][linux]              |
| 3   | [Precise data-source][c-datasrc]    | **"No precise mode on AMD"**: libpfm compacts the `precise` attr out for AMD; IBS is modeled as flagged events, no selector | [precise-sampling][precise] |
| 4   | Code-space decode                   | Orthogonal — naming stops at the encoding; symbolization is downstream                                                      | [elfutils][linux]           |
| 5   | Event-space & tracing               | Tracepoints/branch records are named through perf's own schemas, not libpfm4                                                | [linux][linux]              |
| 6   | [NUMA & topology][c-uncore]         | Uncore event names diverge per layer; LIKWID's `ACCESSMODE_DIRECT` reaches uncore the perf naming path cannot               | [arm][arm] · this page      |
| 7   | [Event naming & encoding][c-naming] | **This page** — five layers, two boundaries (∅ RISC-V but kernel; ∅ non-Linux)                                              | this page                   |

On concern 3, the naming layer is where the vendors' precise engines show their
seams. libpfm's perf validator **compacts the `precise` (`PERF_ATTR_PR`) attribute
out for AMD** — the source comment reads _"No precise mode on AMD"_
([`pfmlib_amd64_perf_event.c:144`][amd64-perf-c]) — and models **IBS** instead as
ordinary events flagged `AMD64_FL_IBSFE`/`AMD64_FL_IBSOP`, whose encoding merely sets
`reg.ibsfetch.en` / `reg.ibsop.en` with **no per-event selector**
([`pfmlib_amd64.c:76-84,452-455`][amd64-c]). On Intel, by contrast, PEBS is surfaced
as a first-class **`PEBS` field in the `intel/perfmon` JSON**, not as a name modifier.
Same concept, three different naming representations — the reason the
[precise-sampling][precise] page owns the cross-vendor semantics.

---

## Strengths

- **One call, one filled `perf_event_attr`.** libpfm4 turns a symbolic string into
  the exact ABI struct `perf_event_open` consumes — no hand-assembled `config`.
- **The OS-layer split is principled.** Privilege/hypervisor/guest filtering lives in
  `attr.exclude_*`, not the raw MSR, so a name is portable across the same event's
  different privilege framings.
- **Mature, wide ISA coverage.** x86 (AMD + Intel), ARMv6–v9, POWER4–10, SPARC,
  s390x, MIPS, Itanium, Cell — the broadest single table set in the field.
- **PAPI adds portable presets with arithmetic** (`DERIVED_*`), and its modern-AMD
  presets are present, not stale.
- **LIKWID reaches where perf can't** — raw MSR/PCI for uncore and frequency, plus the
  only Apple-Silicon / Graviton3 / A64FX tables in the survey.
- **Vendor catalogs are machine-readable and (Intel) self-generating** — `intel/perfmon`
  emits the kernel's own perf JSON.

## Weaknesses

- **Zero RISC-V** in libpfm4/PAPI/LIKWID/`intel-perfmon`; only the kernel `pmu-events`
  tree has (nascent, per-vendor) RISC-V event JSON.
- **No non-Linux OS layer anywhere.** `pfm_os_t` is Linux perf_events only; Windows and
  macOS have curated/private naming, not an open libpfm-style engine.
- **Auto-detect lags new silicon** — a shipped libpfm (4.13.0) misses a family-25/model-`0x61`
  Zen 4; the naming layer's usefulness is gated on the library being new enough.
- **No single AMD name space** — `RETIRED_INSTRUCTIONS` (libpfm) vs `ex_ret_instr`
  (kernel) for the same 0xc0; a consumer must cross-walk.
- **AMD provenance is kernel-only** — no public `intel/perfmon` analogue, so AMD names
  are harder to consume outside the kernel tree.
- **Precise sampling is unevenly named** — AMD has no `precise` attribute (IBS is a
  flagged event with no selector); Intel PEBS is a JSON flag; the abstraction leaks.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                               | Trade-off                                                                          |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| Reuse libpfm4 for Linux x86/ARM naming                           | Mature, matches `perf`, one call fills `perf_event_attr`                | ∅ RISC-V / Windows / macOS; auto-detect lag on new silicon                         |
| Encode to `PFM_OS_PERF_EVENT` (not raw `PFM_OS_NONE`)            | Privilege/HV/guest filters land in `attr.exclude_*`, kernel owns EN/INT | Ties the encoding to Linux perf_events — no other OS layer exists                  |
| Force the PMU from CPUID, don't trust auto-detect                | Survives a libpfm too old for the part (the 4.13.0 / model-`0x61` gap)  | Backend must carry its own family/model → table map, kept in sync with libpfm HEAD |
| Own a cross-OS event vocabulary in the backend                   | No layer spans Linux + Windows + macOS; naming can't be delegated       | Must maintain name↔`{type,config}` walks per ISA/OS, and an AMD libpfm↔kernel walk |
| Keep LIKWID/`intel-perfmon` as data references, not runtime deps | Avoids a second encoding engine; harvest their tables/metrics offline   | Manual harvest; TMA/derived-metric formulas must be re-expressed for the harness   |

---

## Sources

- [`pfm_get_os_event_encoding.3`][man-encode] — the encoding call's contract (the
  Overview quote).
- [`include/perfmon/pfmlib.h`][pfmlib-h] — `pfm_get_os_event_encoding` signature,
  `pfm_os_t` enum (no non-Linux OS layer).
- [`include/perfmon/pfmlib_perf_event.h`][pfm-perf-event-h] — `pfm_perf_encode_arg_t`
  (40-byte LP64 ABI).
- [`lib/pfmlib_amd64.c`][amd64-c] — CPUID detection, the family-25 branch (HEAD fix),
  the modifier set, IBS-as-flagged-events.
- [`lib/pfmlib_amd64_perf_event.c`][amd64-perf-c] — RAW default, the bit-suppression
  quote (OS-layer split), "No precise mode on AMD".
- [`lib/pfmlib_priv.h`][pfmlib-priv-h] — `PFMLIB_ATTR_DELIM ":."` grammar delimiter.
- [`lib/events/amd64_events_fam19h_zen4.h`][amd64-events-h] — `RETIRED_INSTRUCTIONS`
  `.code = 0xc0`.
- [PAPI `papi_events.csv`][papi-csv] · [`pe_libpfm4_events.c`][papi-bridge] — preset CSV
  (zen4/zen5 sections) + the vendored-libpfm4 bridge.
- [LIKWID `perfmon_zen4_events.txt`][likwid-events] · [`likwid.h`][likwid-h] ·
  [`access.c`/`frequency_uncore.c`][likwid-access] · [`groups/zen4/CPI.txt`][likwid-cpi] ·
  [`perfmon_applem1_events.txt` (+graviton3/a64fx)][likwid-apple] — independent stack,
  ACCESSMODE split, groups, Apple/ARM tables.
- [`intel/perfmon` `mapfile.csv`][perfmon-mapfile] · [`SKX/events/*.json`][perfmon-skx] ·
  [`ICX/metrics/…`][perfmon-metrics] · [`scripts/create_perf_json.py`][perfmon-genjson]
  — Intel JSON schema, TMA metrics, the self-generation provenance quote.
- [kernel `amdzen4/`][amdzen4] · [`amdzen4/core.json`][amdzen4-core] ·
  [`recommended.json`][amdzen4-recommended] — AMD's kernel-only tables (`ex_ret_instr`,
  `branch_misprediction_ratio`).
- The [`pfm4-name-roundtrip.d`][probe] probe — the E1/E2 evidence on this box.

> [!NOTE]
> **The runnable CI example for this page is [`pfm4-name-roundtrip.d`][probe]** — it
> encodes the four names above, opens each on this thread, and counts a fixed workload,
> `SKIP:`-ing cleanly on any host without libpfm or with `perf_event_paranoid` too high.
> Its self-verifying case (the `0x103` umask counting exactly 3,000,001) is the primary
> evidence the encodings are live. libpfm4 was cloned from the canonical
> `git.code.sf.net` perfmon2 repository; the SourceForge links below resolve to the
> pinned `6870a9f` commit.

<!-- References -->

[c-counting]: ./concepts.md#counting
[c-datasrc]: ./concepts.md#data-source-attribution
[c-uncore]: ./concepts.md#uncore-pmu
[c-naming]: ./concepts.md#event-naming-and-encoding
[c-curation]: ./concepts.md#capability-curation
[linux]: ./linux-perf-events.md
[precise]: ./precise-sampling.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[windows]: ./windows.md
[macos]: ./macos.md
[probe]: ./examples/pfm4-name-roundtrip.d
[pfmlib-h]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/include/perfmon/pfmlib.h
[pfm-perf-event-h]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/include/perfmon/pfmlib_perf_event.h
[amd64-c]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/lib/pfmlib_amd64.c
[amd64-perf-c]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/lib/pfmlib_amd64_perf_event.c
[pfmlib-priv-h]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/lib/pfmlib_priv.h
[amd64-events-h]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/lib/events/amd64_events_fam19h_zen4.h
[man-encode]: https://sourceforge.net/p/perfmon2/libpfm4/ci/6870a9f00412/tree/docs/man3/pfm_get_os_event_encoding.3
[papi-repo]: https://github.com/icl-utk-edu/papi
[papi-csv]: https://github.com/icl-utk-edu/papi/blob/ec16e00f/src/papi_events.csv
[papi-bridge]: https://github.com/icl-utk-edu/papi/blob/ec16e00f/src/components/perf_event/pe_libpfm4_events.c
[likwid-repo]: https://github.com/RRZE-HPC/likwid
[likwid-events]: https://github.com/RRZE-HPC/likwid/blob/f23c6663/src/includes/perfmon_zen4_events.txt
[likwid-h]: https://github.com/RRZE-HPC/likwid/blob/f23c6663/src/includes/likwid.h
[likwid-access]: https://github.com/RRZE-HPC/likwid/blob/f23c6663/src/access.c
[likwid-cpi]: https://github.com/RRZE-HPC/likwid/blob/f23c6663/groups/zen4/CPI.txt
[likwid-apple]: https://github.com/RRZE-HPC/likwid/blob/f23c6663/src/includes/perfmon_applem1_events.txt
[perfmon-repo]: https://github.com/intel/perfmon
[perfmon-mapfile]: https://github.com/intel/perfmon/blob/683a4d0b/mapfile.csv
[perfmon-skx]: https://github.com/intel/perfmon/tree/683a4d0b/SKX/events
[perfmon-metrics]: https://github.com/intel/perfmon/blob/683a4d0b/ICX/metrics/icelakex_metrics.json
[perfmon-genjson]: https://github.com/intel/perfmon/blob/683a4d0b/scripts/create_perf_json.py
[amdzen4]: https://github.com/torvalds/linux/tree/e43ffb69e043/tools/perf/pmu-events/arch/x86/amdzen4
[amdzen4-core]: https://github.com/torvalds/linux/blob/e43ffb69e043/tools/perf/pmu-events/arch/x86/amdzen4/core.json
[amdzen4-recommended]: https://github.com/torvalds/linux/blob/e43ffb69e043/tools/perf/pmu-events/arch/x86/amdzen4/recommended.json
