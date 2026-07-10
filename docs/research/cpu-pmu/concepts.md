# CPU-PMU Concepts

The shared vocabulary of the CPU-PMU survey. Every term is defined **once**, here;
the [deep-dives][index] link back to these definitions instead of re-explaining
them. Definitions are grounded in the Linux `perf_events` implementation (the
survey's reference model, [linux-perf-events.md][linux]) with per-ISA and per-OS
variations noted where they exist.

**Last reviewed:** July 11, 2026

---

## The two acquisition modes

### Counting

Reading the _aggregate value_ of a hardware event counter over a time window:
enable, run the workload, read one number (e.g. "60,049,109 instructions
retired"). Counting is cheap (no interrupts, no buffers — one register read per
counter), perturbs the workload near-zero, and is the natural mode for a
benchmarking harness that reports per-iteration averages. On Linux it is
`perf_event_open(2)` + `read(2)`; on Windows the [curated][capability-curation]
`ReadThreadProfilingData` path; on macOS `kpc_get_thread_counters` (root) or
`proc_pid_rusage` (unprivileged). Contrast [sampling](#sampling).

### Sampling

Recording a _snapshot per event occurrence_ — canonically every N-th occurrence
([overflow sampling](#overflow-sampling)) — containing at minimum the
interrupted instruction pointer, and optionally registers, stack, data address,
or [branch records](#branch-records). Sampling answers _where_ (which code, which
data), not just _how much_, at the cost of interrupt overhead and a consumer-side
decode pipeline ([symbolization](#symbolization)). A profile is a statistical
estimate: sample counts approximate the true distribution only if samples are
unbiased — the motivation for [precise sampling](#precise-sampling-and-skid).

---

## Counting machinery

### Fixed and configurable counters

PMUs split counters into a few **fixed-function** counters hard-wired to one
event each (cycles, instructions — Intel's fixed counters, Apple's `PMC0`/`PMC1`)
and N **configurable** (general-purpose) counters programmed via a per-counter
event-select register (x86 `PERFEVTSELx`, ARM `PMEVTYPER<n>_EL0`, RISC-V
`mhpmevent3..31`). The configurable count bounds how many events can be measured
simultaneously without [multiplexing](#multiplexing-and-scaling) — 6 core PMCs on
AMD Zen 4, typically 6 + 3 fixed on modern Intel, 5 + 2 fixed exposed by macOS
`kpc` on Apple M-series.

### Event group

A set of events scheduled onto the PMU **as one atomic unit** so their values are
mutually comparable (a valid IPC needs cycles and instructions counted over the
_same_ window). In Linux a group is built by opening sibling events with
`group_fd` = the leader's fd, and the kernel guarantees all-or-nothing
scheduling: _"Groups can be scheduled in as one unit only"_
(`kernel/events/core.c`). A group that exceeds the free counters is simply not
scheduled — it does not partially count. `PERF_FORMAT_GROUP` reads the whole
group atomically in one `read(2)`. Windows/macOS have no user-visible grouping
seam; their counting APIs read whatever the (globally configured) counters hold.

### Multiplexing and scaling

When more events are enabled than counters exist, the kernel time-slices
("rotates") them and reports, per event, how long it was **enabled** vs actually
**running** on the PMU. The consumer scales the raw value by
`enabled / running` to estimate the full-window count — the formula is spelled
out in the uAPI header: `count = quot * enabled + (rem * enabled) / running`.
Scaled counts are _estimates_: sub-millisecond running slices produce visible
error, and an event may get zero PMU time (`running == 0`, perf's
`<not counted>`). A harness avoids multiplexing by keeping its
[group](#event-group) within the physical counter budget — the reason the
sparkles [baseline][baseline] drops its LLC pair when calibration detects
rotation.

### Self-monitoring and user-space counter reads

Reading a counter from the measured thread itself without a syscall: x86 `rdpmc`,
ARMv8 `PMEVCNTR<n>_EL0` reads (gated by `PMUSERENR_EL0`), RISC-V `rdcycle`/
`rdinstret` (gated by `scounteren`). Linux exposes this through the mmap'd
`perf_event_mmap_page`: a seqlock-protected page publishing the counter index,
offset, and width when `cap_user_rdpmc` is set. This is the lowest-overhead
acquisition path (tens of cycles) and the natural fit for per-iteration bracketing
inside a benchmark loop; its availability is arch- and OS-policy-dependent.

---

## Sampling machinery

### PMI: performance monitoring interrupt

The interrupt a PMU raises when a counter overflows: x86 uses an NMI (which is
why the NMI watchdog permanently occupies one counter), ARM a normal PPI per
core, RISC-V the Sscofpmf **LCOFI** local interrupt (bit 13). The PMI handler
captures the sample context and writes it to the output buffer. Everything about
sampling quality — [skid](#precise-sampling-and-skid), blind spots in
interrupt-disabled regions — follows from PMI delivery mechanics.

### Overflow sampling

Program a counter to `-N`, let it overflow every N events, and record a sample
per [PMI](#pmi-performance-monitoring-interrupt) — the canonical IP-profiling
mode (`sample_period`/`sample_freq` + `PERF_SAMPLE_IP` on Linux; ETW
`TraceProfileSourceConfigInfo` → `PERF_PMC_PROFILE` on Windows; `kperf`
timer/PMI actions on macOS). Frequency mode (`sample_freq`) lets the kernel
auto-adjust the period to hit a target rate.

### Precise sampling and skid

**Skid** is the distance between the instruction that caused a counter overflow
and the IP the [PMI](#pmi-performance-monitoring-interrupt) handler observes —
on an out-of-order core the architectural interrupt point lands several to
hundreds of instructions later, biasing profiles. **Precise sampling** removes
skid by making the _hardware_ capture the sample: Intel **PEBS** (the counter
arms a hardware assist that writes a record to a memory buffer), AMD **IBS**
(hardware tags a random micro-op and reports its retirement facts — skid 0 by
construction), ARM **SPE** (hardware writes sample packets to a
[profiling buffer](#aux-buffer)). Linux models the request as
`perf_event_attr.precise_ip` (0–3). RISC-V has no precise mechanism — its
sampled IP is the trapped `xepc`. See [precise-sampling.md][precise].

### Data-source attribution

The star payload of [precise sampling](#precise-sampling-and-skid): for a sampled
memory access, _which level of the memory hierarchy served it_ (L1/L2/L3/local
DRAM/remote node/…), the access latency, and the data virtual/physical address.
Linux normalizes all three vendor engines (PEBS, IBS, SPE) into one ABI union —
`perf_mem_data_src` — plus `PERF_SAMPLE_{ADDR,PHYS_ADDR,WEIGHT}`. The
NUMA-locality signal in the union is deliberately coarse (IBS reports only a
"remote" bit); node-precise attribution needs the
[page→node oracles](#numa-topology-and-page-node-oracles). No public equivalent
exists on Windows or macOS.

### AUX buffer

A second, high-bandwidth mmap area attached to a perf event, into which
_hardware_ (not the PMI handler) streams records: ARM SPE profiling packets,
Intel PT instruction traces. The kernel manages ownership handoff; userspace
decodes the vendor packet format after the fact. Contrast the ordinary perf ring
buffer, which the _kernel_ writes one sample record at a time.

### Branch records

A hardware ring of the last N taken control-flow transfers (source, target,
prediction outcome, optionally cycle count): Intel **LBR** (32 entries), ARM
**BRBE** (up to 64), RISC-V **CTR** (16–256, ratified 2024 but without a Linux
consumer yet). Frozen at sample time, branch records give the _path leading to_
a sample — the input AutoFDO and bottleneck analyses need. Exposed on Linux via
`PERF_SAMPLE_BRANCH_STACK`; on Windows via ETW `TraceLbrConfigurationInfo`
(public since Win10 19H1).

---

## The decode side

### Symbolization

Turning sampled instruction pointers into human meaning:
address → module → symbol → source line (+ inline expansion). Requires two
inputs: an **address-space model** (which file is mapped where — Linux
`PERF_RECORD_MMAP2` records plus `/proc/PID/maps` synthesis; macOS the dyld image
list with a single shared-cache slide; Windows ETW image-load events) and a
**debug-info decoder** (ELF/DWARF via [elfutils][elfutils]' `libdwfl`; PE/PDB via
DbgHelp/DIA; Mach-O/dSYM via CoreSymbolication/`atos`).

### Build-id

A content-derived identity stamped into a binary (ELF `NT_GNU_BUILD_ID` note; the
PE analog is the PDB **GUID+Age**; Mach-O the LC*UUID) that lets a consumer prove
the on-disk file it symbolizes against is the \_same build* that was executing.
Symbolizing against a since-rebuilt binary produces silently wrong results — the
**stale-binary hazard**. Linux can embed the build-id directly in mmap records
(`PERF_RECORD_MISC_MMAP_BUILD_ID`), removing the race entirely.

### Unwinding

Reconstructing the call stack at sample time. Two families: **frame-pointer**
walking (cheap, in-kernel — `PERF_SAMPLE_CALLCHAIN` — but requires the code to
keep a frame chain) and **DWARF-CFI** unwinding (copy the raw stack top +
registers with `PERF_SAMPLE_STACK_USER`/`REGS_USER`, replay call-frame
information offline via `libdwfl` — works on frame-pointer-less builds at the
cost of per-sample stack copies).

### Event-space and tracepoints

Beyond hardware counters, kernels expose _software event schemas_: Linux
**tracepoints** (declared under tracefs with a self-describing `format` file,
countable and sampleable through `perf_event_open` with
`PERF_TYPE_TRACEPOINT`, decoded by [libtraceevent][libtraceevent]); Windows
**ETW** providers (TDH schemas); macOS **kdebug**/DTrace probes. This is the
"event-space" concern: gating and enriching PMU data with OS-level events
(syscalls, scheduling, faults).

---

## Topology

### Uncore PMU

A PMU attached to a shared resource _outside_ any core — L3/system-level cache,
memory controller, interconnect mesh (Intel uncore boxes, AMD L3/DF PMUs, ARM
CMN/DSU/DMC). Uncore events are per-_domain_, not per-thread: they cannot be
attributed to one benchmarked thread, only to a socket/cluster-wide aggregate,
and their drivers restrict reads to one servicing CPU (a sysfs `cpumask`).
Big.LITTLE systems extend the same pattern to _core_ PMUs: one PMU device per
microarchitecture cluster, and an event must be opened on the PMU owning the
pinned core.

### NUMA topology and page-node oracles

The placement decoder: enumerate nodes and distances (Linux sysfs
`/sys/devices/system/node`, wrapped by [libnuma][libnuma]), and answer _"which
node backs this page?"_ for a sampled data address. Linux offers two oracles —
`get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR)` and `move_pages()` in query mode
(pages = the addresses, nodes = NULL) — notably **not** wrapped by any libnuma
helper. Windows' analog is `QueryWorkingSetEx` (a per-page `Node` field); Apple
Silicon is UMA, so the entire axis collapses there.

---

## Naming, encoding, policy

### Architected vs implementation-defined events

Whether an event's number and meaning are fixed by the ISA specification or left
to each implementation. ARM PMUv3 architects a **common** event space
(`0x0000–0x003F`, discoverable per-core via the `PMCEID*` registers) and leaves
`0x0040+` implementation-defined; RISC-V architects _no_ hardware event numbers
at all (only the SBI _classes_; the `mhpmevent` selector values are per-vendor);
x86 has vendor-architected subsets (Intel's architectural events) plus large
model-specific tables. The practical consequence: portable event names exist
only as far as somebody maintains per-microarchitecture
[encoding tables](#event-naming-and-encoding).

### Event naming and encoding

The mapping from a human event name (`RETIRED_INSTRUCTIONS`,
`ex_ret_instr`, `INST_RETIRED.ANY`) to the hardware programming value —
on Linux, `perf_event_attr.{type, config}`. The maintained mappings are
per-microarchitecture tables: [libpfm4][naming] (the engine under PAPI),
LIKWID's event files, Intel's public `intel/perfmon` repo, AMD's kernel-tree
JSONs, ARM's `ARM-software/data`, Apple's on-disk kpep plists. No two agree on
names for the same event, and none spans Linux + Windows + macOS — see
[event-naming.md][naming].

### Capability curation

The policy stance of an OS that exposes only a _vetted list_ of events rather
than raw selectors: Windows' HAL profile-sources (a small architected set;
custom events need a system-global registration) and macOS's kernel
`RESTRICT_TO_KNOWN` allowlist (102 events on M4 Max — even root cannot program
an unlisted selector). Linux is the outlier: any `config` value can be opened by
an unprivileged process (subject to
[privilege gating](#privilege-gating)). Curation is why a cross-OS backend must
advertise _capabilities_, not assume them.

### Privilege gating

Every OS gates PMU access, each differently: Linux's `perf_event_paranoid`
sysctl (per-level: raw kernel profiling → CPU-wide events → any unprivileged
use) plus seccomp/LSM; tracefs file permissions (root-only tracepoint `id`s on
hardened systems); ARM SPE's physical-address collection gated on
`perf_allow_kernel()`; Windows' `SeSystemProfilePrivilege`/administrators for
ETW kernel sessions; macOS's "root or the blessed pid" `ktrace` ownership for
`kpc`, with SIP standing behind it. A portable harness treats _"counter opened"_
as a runtime capability probe, never an assumption — degradation must be
detected and reported, not silently absorbed.

<!-- References -->

[index]: ./
[linux]: ./linux-perf-events.md
[precise]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[libtraceevent]: ./libtraceevent.md
[libnuma]: ./libnuma.md
[naming]: ./event-naming.md
[baseline]: ./sparkles-baseline.md
