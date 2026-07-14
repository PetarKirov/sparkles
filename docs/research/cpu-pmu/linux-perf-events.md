# Linux `perf_events`

The survey's reference model: one syscall — `perf_event_open(2)` — is the single
acquisition hub for _both_ [counting][counting] and [sampling][sampling], and four
independent libraries decode what it produces without ever touching the PMU.

| Field        | Value                                                                                                                 |
| ------------ | --------------------------------------------------------------------------------------------------------------------- |
| Subsystem    | `perf_events` (kernel `kernel/events/`) + the `tools/perf` userspace consumer                                         |
| Entry point  | `perf_event_open(2)` — returns one fd per event; fds compose into [groups][group]                                     |
| ABI          | `struct perf_event_attr` (uAPI `include/uapi/linux/perf_event.h`) in, records + counter reads out                     |
| Kernel read  | v7.1-rc6, [`linux@e43ffb69e043`][uapi]                                                                                |
| Role         | Hub-and-decoders: the syscall _acquires_; `libdwfl`/`libtraceevent`/`libnuma` _interpret_                             |
| Decoders     | [code space][elfutils] (`libdwfl`) · [event space][libtraceevent] (`libtraceevent`) · [topology][libnuma] (`libnuma`) |
| Verification | `[hw-verified: x86_64-linux]` — Linux 6.18.26, AMD Ryzen 9 7940HX (Zen 4), LDC 1.41                                   |

> [!NOTE]
> All three hardware experiments on this page were recorded on **Linux 6.18.26**,
> an **AMD Ryzen 9 7940HX** (Zen 4, 6 general-purpose core PMCs), with
> `/proc/sys/kernel/perf_event_paranoid = -1`, built with **LDC 1.41** over
> druntime's `core.sys.linux.perf_event`. Each is a runnable probe under
> [`examples/`](./examples/counting-group.d) that CI compiles and runs.

---

## Overview

### What it acquires

Every other page in this survey describes a _variation on_, or a _decoder for_,
the machinery here. Linux is the survey's reference model for a reason: it is the
one platform where a single, uniform, unprivileged-capable syscall covers the
whole acquisition surface. `perf_event_open(2)` opens **one event** — described
by a `struct perf_event_attr` — and returns a file descriptor. Whether that event
_counts_ (accumulate one number, read it with `read(2)`) or _samples_ (write a
record stream into an mmap'd ring on every counter overflow) is a property of the
same `attr`, not a different API. Windows splits this across ETW, the HAL, and
`ReadThreadProfilingData`; macOS across `kpc` and `kperf`; Linux unifies it.

The `perf_event_attr` ABI is wide but flat: a major `type`
(`PERF_TYPE_HARDWARE`, `PERF_TYPE_TRACEPOINT`, …), a `config` number selecting the
event within that type, and a bitfield block of modifiers (`disabled`,
`exclude_kernel`, `exclude_hv`, `precise_ip`, `sample_type`, …)
([`perf_event.h:393`][uapi-attr] for the struct, [`:418`][uapi-bitfield] for the
modifier block). `linux@e43ffb69e043 include/uapi/linux/perf_event.h`.
`[source-verified]`

### The hub-and-decoders model

The load-bearing architectural fact — the one that shapes every other page — is
that **none of the four decoder libraries is required to acquire data; each is
required only to interpret it.** `perf_event_open` and `read`/`mmap` give you raw
numbers, raw instruction pointers, and raw record blobs. Turning those into
meaning is delegated:

| Decoder                                | Decodes         | From                                                  | Owns concern |
| -------------------------------------- | --------------- | ----------------------------------------------------- | ------------ |
| [`libelf`/`libdw`/`libdwfl`][elfutils] | **code space**  | IP → module → symbol → line + DWARF-CFI unwind        | 4            |
| [`libtraceevent`][libtraceevent]       | **event space** | a tracefs `format` schema → typed field extraction    | 5            |
| [`libnuma`][libnuma]                   | **topology**    | sysfs `/sys/devices/system/node` + mempolicy syscalls | 6            |
| [`libpfm4` etc.][naming]               | **naming**      | human event name → `attr.{type, config}`              | 7            |

A [group][group] is scheduled onto the PMU **as one atomic unit** — the property
that makes a valid IPC possible ([counting][counting] cycles and instructions over
the _same_ window). If the whole group cannot fit on the hardware it is rolled
back and not scheduled at all, verbatim from the kernel
([`kernel/events/core.c:2886`][core-group]):

> `/* Groups can be scheduled in as one unit only, so undo any partial group before returning: */`

That all-or-nothing contract is why a benchmarking harness sizes its group to the
physical counter budget rather than hoping the kernel partial-counts — it never
will. `[source-verified]`

---

## How it works

The lifecycle of an event is four phases: **open** (`perf_event_open` with a
filled `attr`), **arm** (`PERF_EVENT_IOC_RESET` + `PERF_EVENT_IOC_ENABLE` via
`ioctl`, [`:576`][uapi-attr]), **run** (the workload executes), **harvest**
(`read(2)` for counting; drain the mmap ring for sampling). Grouping and
enable/disable can address a whole group at once with the
`PERF_IOC_FLAG_GROUP` ioctl flag: enabling the leader enables every sibling.

The kernel side is a per-CPU/per-task context of scheduled events. When more
events are enabled than there are counters, a per-CPU hrtimer
([`perf_rotate_context`, core.c:4587][core-rotate]) time-slices them, and the
kernel accounts, per event, how long it was **enabled** versus actually
**running** on hardware ([`__perf_update_times`, core.c:744][core-times]). Those
two timestamps are the entire basis of [multiplexing scaling][multiplexing],
below. `[source-verified]`

---

## The seven concerns

This survey scores every backend against the same seven concerns. Linux is where
five of them are _acquired_ and two (3, then the decode halves of 4–7) are
_deferred to a decoder_. The concern order is fixed across the tree.

### Scalar counting: groups, `PERF_FORMAT_GROUP`, and multiplexing

**Concern 1 — acquired here.** A counting event is opened with
`attr.disabled = 1` on the leader; sibling events
pass the leader's fd as `group_fd`, which joins the [group][group]
([`perf_event.h:393`][uapi-attr]). The leader carries the read format. With
`PERF_FORMAT_GROUP` set, a single `read(2)` on the leader returns the whole group
atomically as `{nr, time_enabled, time_running, value[nr]}`
([read-format enum `:365`][uapi-readfmt]; producer
[`perf_read_group`, core.c:6154][core-readgroup], with
`nr = 1 + leader->nr_siblings`). Counting is cheap: no interrupts, no buffers, one
register read per counter, near-zero perturbation — the natural mode for a
per-iteration benchmark harness. `[source-verified]`

**Multiplexing.** When enabled events exceed the counter budget, the reader must
scale each raw count by `time_enabled / time_running` to estimate the full-window
value. The exact formula is documented in the uAPI header itself
([`perf_event.h:685`][uapi-scale]):

```text
/* include/uapi/linux/perf_event.h:685 */
 *   quot = count / running;
 *   rem  = count % running;
 *   count = quot * enabled + (rem * enabled) / running;
```

Scaled counts are _estimates_: a sub-millisecond running slice produces visible
error, and an event that got zero PMU time (`running == 0`) reads as perf's
`<not counted>` — a zero read is not a measurement. A harness avoids the whole
problem by keeping its group inside the physical counter budget — the reason the
sparkles [baseline][baseline] drops its LLC pair when calibration detects
rotation. `[source-verified]`

**Experiment A** — [`counting-group.d`](./examples/counting-group.d) — reads a
fitting `cycles`+`instructions` group (exact IPC, `scale == 1`), then deliberately
oversubscribes 10 instruction counters onto 6 Zen-4 PMCs to force multiplexing:

```text
== Demo 1: fitting group (kernel+user) ==
  nr=2  time_enabled=3020595 ns  time_running=3020595 ns  scale=1.0000
  cycles=15099126  instructions=60049109  IPC=3.977
== Demo 2: 10 instruction counters, 6 general-purpose PMCs ==
  ev   raw_running_count      enabled_ns    running_ns   scale   estimate
   0             13444336        3337469        762700    4.38   58830542
   3             60058404        3332911       3332911    1.00   60058404   ← fit, exact
   7             10661419        3320297        582933    5.70   60725808
   8                    0        3316961             0       —   <not scheduled>
  multiplexing observed: yes
```

The scaled estimates cluster at the true ~60.05M retired instructions; two events
got **zero** PMU time (perf's `<not counted>` state); the extreme 5.70× scale from
a 0.58 ms slice is visibly the noisiest recovery — a caution for the harness's
LLC-pair-drop heuristic and any pinned, oversubscribed group.
`[hw-verified: x86_64-linux]`

#### `rdpmc` self-monitoring and the mmap-page seqlock

The lowest-overhead counter read skips the syscall entirely. The mmap'd
`perf_event_mmap_page` (page 0 of the ring mapping, [`perf_event.h:596`][uapi-page])
publishes the counter `index`, `offset`, `pmc_width`, and a `cap_user_rdpmc`
capability bit ([`:646`][uapi-caps]/[`:663`][uapi-width]). The
[self-monitoring][rdpmc] read is a userspace seqlock loop that reads the counter
with the `rdpmc` instruction, verbatim from the uAPI
([`perf_event.h:608`][uapi-rdpmc]):

```text
/* include/uapi/linux/perf_event.h:608 */
 *   do {
 *     seq = pc->lock;
 *     barrier()
 *     ...
 *     index = pc->index;
 *     count = pc->offset;
 *     if (pc->cap_user_rdpmc && index) {
 *       width = pc->pmc_width;
 *       pmc = rdpmc(index - 1);
 *     }
 *     barrier();
 *   } while (pc->lock != seq);
```

The kernel republishes the page under an incrementing `lock` seqcount in
`perf_event_update_userpage` ([core.c:6825][core-userpage], `++userpg->lock` +
`barrier()`). One caveat for the per-ISA pages that follow:
**`cap_user_rdpmc` and `pmc_width` are set by _arch_ code, not the generic
core** — the `__weak arch_perf_update_userpage` stub at
[core.c:6815][core-weakstub] is a no-op, and x86 fills the fields in
`arch/x86/events/core.c`. The ARM `arm_pmuv3` userpage path is its own story (see
[arm.md][arm]). `[source-verified]`

### Overflow sampling: the ring buffer, `PERF_RECORD_MMAP2`, and IP symbolization

**Concern 2 — acquired here.** [Sampling][sampling] arms `attr.sample_period` (or `attr.sample_freq` with
`attr.freq = 1`) plus a `sample_type` bitmask selecting which fields each record
carries ([`PERF_SAMPLE_IP = 1<<0` … `STACK_USER = 1<<13` … `DATA_SRC = 1<<15`,
`:142`][uapi-sample]). On each [overflow][overflow] the [PMI][pmi] handler writes
a `PERF_RECORD_SAMPLE` (record type `9`, [`:1059`][uapi-rectype]) into the mmap
ring: page 0 is the control `perf_event_mmap_page` (`data_head`/`data_tail`,
[`:749`][uapi-head]/[`:750`][uapi-tail]); pages 1.. are the data area. The
sample's field order (IP, TID, TIME, …, `REGS_USER`, `STACK_USER`, …) is fixed by
the `sample_type` bit order and documented at the record comment
[`:1061`][uapi-recsample]. `[source-verified]`

**Consumer ordering.** The reader-side contract is a seqcount: acquire-load
`data_head`, process `[data_tail, data_head)` wrapping modulo the data size, then
release-store the new `data_tail` back. Experiment B parses this directly.
`[hw-verified: x86_64-linux]`

**The `MMAP2` / stale-binary hazard.** The single biggest surprise for anyone
writing a self-profiler: **`PERF_RECORD_MMAP2` (record type `10`,
[`:1091`][uapi-mmap2]) is emitted only for executable mappings created _while the
event is enabled_.** The kernel does **not** re-emit already-mapped code — your
own binary, libc, everything that was mapped before you enabled sampling produces
_zero_ `MMAP2` records. This is why the `perf` tool _synthesizes_ `MMAP2` for
pre-existing regions from `/proc/PID/maps` at start, and why
[`libdwfl`][elfutils]'s `dwfl_linux_proc_report` reads that same file. For a
harness this is a real [build-id][build-id]/[stale-binary][build-id] hazard:
symbolization must lean on `/proc/self/maps` or synthesize `MMAP2`, and must
validate [build-ids][build-id] or risk silently symbolizing against a rebuilt
binary. Perf's build-id path validates and rejects on mismatch
([`build-id.c:863`][perf-buildid], `dso__build_id_mismatch`).
`[hw-verified: x86_64-linux]` — the probe captured **0** `MMAP2` records until a
mid-window `mmap(PROT_EXEC)` of `/proc/self/exe` forced one.

**Experiment B** — [`sampling-symbolize.d`](./examples/sampling-symbolize.d) —
samples `cycles` at ~4 kHz, drains `SAMPLE` + `MMAP2` from the ring, and hands the
IPs to `libdwfl`:

```text
captured: 1 PERF_RECORD_MMAP2 mappings, 1996 IP samples
top self-symbols (dwfl: name — samples — file:line):
  …sumSquares…   1852   sampling-symbolize.d:137
  …mixHash…       130   sampling-symbolize.d:129
PERF_RECORD_MMAP2 captured during the window: 1 record(s)
  [0x798b80c68000, 0x798b80c69000) pgoff=0x0 prot=0x5 …/build/cpu_pmu_sampling_symbolize
model check: hottest symbol …sumSquares… (IP 0x55c5…) was symbolized by libdwfl,
and a captured MMAP2 names the same image.
```

The IPs land purely on the acquisition side here; the address → symbol → line
decode is elfutils' job — see [elfutils.md § "Address → module → symbol →
line"][elfutils-addr]. `[hw-verified: x86_64-linux]`

### Precise sampling and data-source attribution

**Concern 3 — deferred to [precise-sampling.md][precise].**
`perf_event_open` _acquires_ the precise-sampling request and its payload — the
attr carries `precise_ip` (0–3) and the `sample_type` bits
`PERF_SAMPLE_ADDR`, `PERF_SAMPLE_DATA_SRC`, `PERF_SAMPLE_PHYS_ADDR`,
`PERF_SAMPLE_WEIGHT` — but the _semantics_ (Intel PEBS, AMD IBS, ARM SPE, the
`perf_mem_data_src` union, [skid][skid] removal, and node classification) are one
whole page of their own. This concern is covered end-to-end in
[precise-sampling.md][precise]; the [data-source attribution][datasrc] payload it
decodes is captured through this same syscall.

### Code-space decode: the record → address model and stack capture

**Concern 4 — address model here, decode → [elfutils.md][elfutils].**
The kernel hands you records; turning them into a symbol requires an
**address-space model** (which file is mapped where) and a **debug-info decoder**.
Linux acquires the first and _defers the second_ to [`libdwfl`][elfutils].

**The perf consumer pipeline (the address model).** Perf's own record → symbol
path is the reference wiring: `MMAP2` → `machine__process_mmap2_event` builds a
`struct dso_id` (the [build-id][build-id] if
`PERF_RECORD_MISC_MMAP_BUILD_ID` is present, else `maj/min/ino`) + `map__new` +
`thread__insert_map` ([machine.c:1728][perf-machine]); then a sampled IP resolves
via `thread__find_map` (a `maps__find` bsearch, [maps.c:1122][perf-maps]) →
`map__map_ip` rebases the runtime VA to a file offset ([map.h:107][perf-map]) →
`map__find_symbol` → `dso__find_symbol` (rbtree containment,
[symbol.c:412][perf-symbol]). `[source-verified]`

#### Stack unwinding: `STACK_USER` + `REGS_USER` and DWARF CFI

For a [call-graph profile][unwinding] on a frame-pointer-less build, the
frame-pointer chain-walk is impossible, so the sample additionally carries the
interrupted
thread's **register file** (`PERF_SAMPLE_REGS_USER`) and a copied slab of its
**user stack** (`PERF_SAMPLE_STACK_USER`) — `attr.sample_regs_user` is the
register mask, `attr.sample_stack_user` the slab size. The DWARF-CFI _replay_ that
turns those into a backtrace is again elfutils' — see [elfutils.md § "DWARF-CFI
stack unwinding"][elfutils-unwind]. This page owns only the capture.

**Experiment C** — [`unwind-stack-user.d`](./examples/unwind-stack-user.d) —
samples with `REGS_USER`+`STACK_USER` on a `--frame-pointer=none` build and
reconstructs a 5-frame backtrace **offline** from `.eh_frame`/`.debug_frame` CFI:

```text
captured: 125 samples with REGS_USER+STACK_USER (0 had ABI_NONE)
chosen sample: leaf IP 0x… (…level3…+0x50)  regs ABI=2  RIP=0x… RSP=0x… captured stack=2776 bytes
DWARF-CFI backtrace (5 frames, frame pointers OMITTED …):
  #0 …level3…+0x50   #1 …level2…+0x12   #2 …level1…+0x12   #3 …workload…+0x71   #4 …run…+0x29A
```

This is byte-for-byte the wiring perf uses in
[`tools/perf/util/unwind-libdw.c`][perf-unwind]. The perf → DWARF x86-64 register
permutation lives in the probe; ARM and RISC-V need their own maps (see
[arm.md][arm] / [riscv.md][riscv]). `[hw-verified: x86_64-linux]`

### Event-space and tracing: `PERF_TYPE_TRACEPOINT` + `PERF_SAMPLE_RAW`

**Concern 5 — raw blob here, decode → [libtraceevent.md][libtraceevent].**
Beyond hardware counters, `perf_event_open` counts and samples kernel
[software-event schemas][eventspace]. Opening an event with
`attr.type = PERF_TYPE_TRACEPOINT` and `attr.config` set to a tracepoint's numeric
`id` makes that tracepoint countable; adding `PERF_SAMPLE_RAW` to `sample_type`
attaches the tracepoint's raw record blob to each sample. The blob is _typed_ only
by the tracepoint's tracefs `format` schema, which [`libtraceevent`][libtraceevent]
parses — see [libtraceevent.md][libtraceevent]. Two boundaries matter here: the
numeric `id` comes from reading `.../events/<sys>/<event>/id` under tracefs (whose
files are **root-only** on hardened boxes — the gate the sparkles `--syscalls`
layer hits on this machine), and `libtraceevent` decodes the blob but does _not_
read the tracefs files (libtracefs does). `[source-verified]`

### NUMA and topology

**Concern 6 — n/a to the syscall → [libnuma.md][libnuma].**
The `perf_event_open` syscall has **no** topology concern — it neither enumerates
nodes nor attributes a sampled data address to a node. A sample can _carry_ the
data virtual/physical address (`PERF_SAMPLE_ADDR`/`PERF_SAMPLE_PHYS_ADDR`, concern
3), but answering _"which node backs this page?"_ is a separate decoder: sysfs
`/sys/devices/system/node` topology plus the mempolicy syscalls, wrapped (mostly)
by [`libnuma`][libnuma]. See [libnuma.md][libnuma] — including the
[missing VA→node helper][libnuma] that [precise-sampling.md][precise] must
open-code.

### Event naming and encoding

**Concern 7 — opaque numbers here → [event-naming.md][naming].**
On this page `attr.type` and `attr.config` are **opaque numbers**. The syscall
takes `PERF_COUNT_HW_INSTRUCTIONS` (an architected enum) or a raw
`PERF_TYPE_RAW` `config` and asks no questions about what it means. The mapping
from a human name (`ex_ret_instr`, `INST_RETIRED.ANY`) to those numbers is a
per-microarchitecture table maintained _outside_ the kernel — [libpfm4][naming],
LIKWID, `intel/perfmon` — and is [event-naming.md][naming]'s whole subject. The
kernel exposes `config` freely to unprivileged processes (subject to
[privilege gating][privilege]), which — unlike Windows/macOS
[capability curation][curation] — is why Linux is the survey's _"any event"_
outlier.

---

## Strengths

- **One uniform acquisition hub.** Counting and sampling are the same syscall and
  the same `attr` ABI; there is no second API to learn for profiling vs
  benchmarking. Windows and macOS both split this across several subsystems.
- **Atomic [group][group] scheduling** makes derived metrics (IPC, MPKI) honest —
  the co-scheduled counts share one window or the group does not schedule at all.
- **User-space counter reads** via `rdpmc` + the mmap page reach tens-of-cycles
  overhead, the natural fit for per-iteration bracketing inside a benchmark loop.
- **Self-describing sampling records.** The `sample_type` bitmask makes each
  record's layout deterministic; druntime's `core.sys.linux.perf_event` already
  models the mmap page, headers, and every `PERF_SAMPLE_*`, so a **pure-D**
  sampler needs _no_ C shim for the ring buffer (only `libdwfl` needs
  `extern(C)`).
- **Unprivileged by default** (`perf_event_paranoid` permitting): any `config`
  value is openable without a global registration step.
- **A public, reference consumer** (`tools/perf`) whose record → symbol pipeline
  is readable source, not a black box.

## Weaknesses

- **The `MMAP2`/stale-binary hazard** (concern 2): a naive self-profiler captures
  _zero_ mmap records and must synthesize the address-space model from
  `/proc/PID/maps` and validate [build-ids][build-id], or it symbolizes against
  the wrong binary silently.
- **[Multiplexing][multiplexing] error is real and unbounded** below a
  millisecond of running time — a sub-ms slice can inflate the scale to 5×+
  (Experiment A). The harness must detect rotation and shrink the group, not trust
  the estimate.
- **`rdpmc` capability is arch- and policy-dependent**: `cap_user_rdpmc` is set by
  arch code and may be disabled by sysadmin policy; a portable path must probe it,
  never assume it.
- **The decode surface is four separate libraries**, each with its own ABI and
  version skew — the acquisition is trivial, the _interpretation_ is where the
  engineering lives.
- **[Privilege gating][privilege] is multi-dimensional**: `perf_event_paranoid`
  levels, tracefs file permissions (concern 5), and SPE physical-address gating
  (concern 3) each fail differently and must be treated as runtime capability
  probes.

## Key design decisions and trade-offs

| Decision                                                               | Rationale                                                                           | Trade-off                                                                                            |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| One syscall for counting _and_ sampling (`perf_event_open`)            | A single flat `attr` ABI covers the whole surface; nothing to unify at the consumer | The `attr` struct is wide and versioned; every capability is a bit or field to probe                 |
| All-or-nothing [group][group] scheduling                               | Co-scheduled counts share one window → derived metrics are valid                    | A group larger than the counter budget silently does not schedule — sizing is the caller's job       |
| `time_enabled`/`time_running` + a documented scaling formula           | The reader can recover a full-window estimate under [multiplexing][multiplexing]    | Estimates degrade sharply below a millisecond of running time; `running == 0` is unrecoverable       |
| `rdpmc` + a seqlock'd mmap page for user-space reads                   | Tens-of-cycles counter reads, no syscall, ideal for per-iteration bracketing        | Capability is arch-set and policy-gated; needs a seqcount retry loop and a probe                     |
| `MMAP2` only for mappings made _while enabled_                         | The kernel avoids re-dumping the entire (large, static) address space per event     | Self-profilers capture nothing pre-existing → must synthesize from `/proc/maps` + validate build-ids |
| Decoders (`libdwfl`/`libtraceevent`/`libnuma`) live outside the kernel | The acquisition path stays minimal; decode complexity is opt-in and swappable       | Four ABIs, four version-skew surfaces, and none of them portable off Linux                           |
| `config` openable by unprivileged processes (paranoia-gated)           | No global event registration; any raw selector is reachable                         | Shifts the [curation][curation] burden to userspace — a portable backend must advertise, not assume  |

---

## Sources

- [`perf_event_open(2)` — man page][man] (the authoritative prose; the uAPI header is its source)
- [`include/uapi/linux/perf_event.h`][uapi] — `perf_event_attr`, read/sample formats, the mmap page, the scaling formula, and the `rdpmc` seqlock (all quoted above)
- [`kernel/events/core.c`][core] — group scheduling ([all-or-nothing][core-group]), group reads, multiplex rotation, the userpage seqcount
- [`arch/x86/events/core.c`][x86core] — where `cap_user_rdpmc`/`pmc_width` are actually set
- [`tools/perf/util/`][perf-util] — the reference consumer: `machine.c`, `map.h`, `maps.c`, `symbol.c`, `build-id.c`, `unwind-libdw.c`
- druntime `core.sys.linux.perf_event` (LDC 1.41) — the pure-D `attr`/record/mmap-page layout the probes use
- Runnable probes: [`counting-group.d`](./examples/counting-group.d) · [`sampling-symbolize.d`](./examples/sampling-symbolize.d) · [`unwind-stack-user.d`](./examples/unwind-stack-user.d)
- The decoders this hub defers to: [elfutils][elfutils] · [libtraceevent][libtraceevent] · [libnuma][libnuma] · [event naming][naming]
- Shared vocabulary: [concepts.md][concepts]

<!-- References -->

[concepts]: ./concepts.md
[counting]: ./concepts.md#counting
[sampling]: ./concepts.md#sampling
[group]: ./concepts.md#event-group
[multiplexing]: ./concepts.md#multiplexing-and-scaling
[rdpmc]: ./concepts.md#self-monitoring-and-user-space-counter-reads
[pmi]: ./concepts.md#pmi-performance-monitoring-interrupt
[overflow]: ./concepts.md#overflow-sampling
[skid]: ./concepts.md#precise-sampling-and-skid
[datasrc]: ./concepts.md#data-source-attribution
[build-id]: ./concepts.md#build-id
[unwinding]: ./concepts.md#unwinding
[eventspace]: ./concepts.md#event-space-and-tracepoints
[curation]: ./concepts.md#capability-curation
[privilege]: ./concepts.md#privilege-gating
[elfutils]: ./elfutils.md
[elfutils-addr]: ./elfutils.md#address-→-module-→-symbol-→-line
[elfutils-unwind]: ./elfutils.md#dwarf-cfi-stack-unwinding
[libtraceevent]: ./libtraceevent.md
[libnuma]: ./libnuma.md
[precise]: ./precise-sampling.md
[naming]: ./event-naming.md
[arm]: ./arm.md
[riscv]: ./riscv.md
[baseline]: ./sparkles-baseline.md
[man]: https://man7.org/linux/man-pages/man2/perf_event_open.2.html
[uapi]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h
[uapi-attr]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L393
[uapi-bitfield]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L418
[uapi-readfmt]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L365
[uapi-scale]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L685
[uapi-page]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L596
[uapi-rdpmc]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L608
[uapi-caps]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L646
[uapi-width]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L663
[uapi-sample]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L142
[uapi-rectype]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L1059
[uapi-recsample]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L1061
[uapi-mmap2]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L1091
[uapi-head]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L749
[uapi-tail]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/include/uapi/linux/perf_event.h#L750
[core]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c
[core-group]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L2886
[core-readgroup]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L6154
[core-rotate]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L4587
[core-times]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L744
[core-userpage]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L6825
[core-weakstub]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/kernel/events/core.c#L6815
[x86core]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/arch/x86/events/core.c
[perf-util]: https://github.com/torvalds/linux/tree/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util
[perf-machine]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/machine.c#L1728
[perf-map]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/map.h#L107
[perf-maps]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/maps.c#L1122
[perf-symbol]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/symbol.c#L412
[perf-buildid]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/build-id.c#L863
[perf-unwind]: https://github.com/torvalds/linux/blob/e43ffb69e0438cddd72aaa30898b4dc446f664f8/tools/perf/util/unwind-libdw.c
