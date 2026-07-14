# libnuma

The survey's **topology / placement decoder**: it enumerates NUMA nodes and their
distances from sysfs and wraps the memory-policy syscalls — but it has **no helper
for the one query a data-source profiler needs**: _which node backs this address?_

| Field            | Value                                                                                                    |
| ---------------- | -------------------------------------------------------------------------------------------------------- |
| Library          | `libnuma` (shipped in the `numactl` package)                                                             |
| Role             | Enumerate nodes + inter-node distances (sysfs) and wrap the mempolicy syscalls                           |
| Version          | **2.0.19**, [`numactl@93c1fe5`][numactl-repo]                                                            |
| Sysfs root       | `/sys/devices/system/node`                                                                               |
| pkg-config       | **None ships** — there is no `numa.pc`, so `pkg-config --cflags libnuma` fails                           |
| Touches the PMU? | **No.** Pure decoder — the [Linux hub][linux]'s concern-6 delegate, and the classifier half of concern 3 |
| Verification     | `[source-verified]` — read against the pinned `numactl@93c1fe5` tree                                     |

> [!NOTE]
> libnuma covers one of the survey's seven concerns (topology, concern 6) and is
> the _classifier_ half of a second (precise data-source attribution, concern 3) —
> the other five are **not applicable**. The headline finding is an **absence**:
> the VA→node query that concern 3 depends on is _not wrapped by any libnuma
> helper_. On UMA platforms (Apple Silicon) the whole layer collapses — see
> [macos.md][macos].

---

## Overview

### What it decodes

Where [elfutils][elfutils] decodes code space and [libtraceevent][libtraceevent]
decodes event space, libnuma decodes **placement**: it answers _how many nodes are
there, how far apart are they, and which CPUs belong to each_, and it wraps the
kernel's memory-policy syscalls (`mbind`, `set_mempolicy`, `move_pages`, …) so a
program can bind memory to a node. For the CPU-PMU survey it is the layer that
_would_ turn a sampled data address into a NUMA node — the last mile of
[data-source attribution][datasrc] — except that the crucial query is one it does
not expose.

### Design philosophy: thin syscall shims + a sysfs reader

libnuma is deliberately thin. Its placement primitives are near-direct syscall
shims, and its topology is read straight from sysfs. The convenience allocators
are one syscall under the hood — `numa_alloc_onnode` is just `mmap` followed by an
`mbind`, verbatim ([`libnuma.c:324`][libnuma-c]):

> `static int dombind(void *mem, size_t size, int pol, struct bitmask *bmp) { if (mbind(mem, size, pol, bmp ? bmp->maskp : NULL, bmp ? bmp->size : 0, mbind_flags) < 0) {`

And the one query a data-source profiler actually wants — _which node backs this
virtual address?_ — appears **only in the numactl `test/` tool**, as a raw syscall,
because there is no library wrapper for it ([`test/mynode.c:10`][mynode-c]):

> `if (get_mempolicy(&nd, NULL, 0, man, MPOL_F_NODE|MPOL_F_ADDR) < 0)`

`[source-verified]` Those two excerpts frame the whole page: libnuma wraps
_placement_ generously and _introspection of an address_ not at all.

---

## How it works

libnuma has two faces — a set of syscall wrappers and a sysfs topology reader —
with a thin layer of placement convenience on top.

**Syscall wrappers.** The mempolicy syscalls are exposed as thin `WEAK` shims:
`get_mempolicy`, `set_mempolicy`, `mbind`, `migrate_pages`, and `move_pages`
([`syscall.c:223`][syscall-c] / `:238` / `:231` / `:246` / `:257`). The public
placement helpers build directly on these: `numa_alloc_onnode` = `mmap` + `dombind`
→ `mbind` ([`libnuma.c:1150`][libnuma-c], `:324`); `numa_set_membind` =
`set_mempolicy(MPOL_BIND)` ([`:1206`][libnuma-c]); `numa_move_pages` = `move_pages`
([`:1913`][libnuma-c]). `[source-verified]`

**Sysfs topology and distances.** Topology comes entirely from sysfs, not a
syscall. Node enumeration is `opendir("/sys/devices/system/node")`
([`libnuma.c:371`][libnuma-c]); each node's CPU set is read from
`.../node<N>/cpumap` via `getdelim` → `numa_parse_bitmap` ([`:1571`][libnuma-c]);
and the inter-node distance matrix (the ACPI SLIT) is read from
`.../node<N>/distance` by `read_distance_table` ([`distance.c:47`][distance-c]) and
exposed as `numa_distance` ([`distance.c:105`][distance-c]). A CPU/node set is
carried in a `struct bitmask {size; maskp}` ([`numa.h:44`][numactl-repo]).
`[source-verified]`

> [!WARNING]
> **No `numa.pc` ships.** `libnuma` provides no pkg-config file, so
> `pkg-config --cflags --libs libnuma` fails — a build integrating it must add
> `-lnuma` and the header path by hand (contrast elfutils, which ships `.pc`
> files). One more integration papercut for a would-be backend.

---

## The seven concerns

The concern order is fixed across the survey. libnuma owns concern 6, is the
classifier half of concern 3, and is not applicable to the rest.

### Scalar counting

**Concern 1 — not applicable.** libnuma reads no counters and opens no
[`perf_event`][linux].

### Overflow sampling

**Concern 2 — not applicable.** libnuma does not sample. It only ever receives a
data _address_ that a sample already carried.

### Precise sampling and data-source attribution

**Concern 3 — the classifier half, and the finding [precise-sampling.md][precise]
builds on.** A [precise sample][precise] can carry a data virtual/physical address
(`PERF_SAMPLE_ADDR`/`PERF_SAMPLE_PHYS_ADDR`) and a coarse `perf_mem_data_src`
locality hint, but turning that into a _node_ — "this L3 miss was served from
remote node 1" — requires a VA→node lookup. libnuma is where that lookup would
live, and **it does not exist as a helper** (see [the missing VA-to-node
helper](#the-missing-va-to-node-helper) below). So concern 3's node-precise
classifier is _open-coded on top of libnuma's syscall shims_, not called from it —
the exact gap [precise-sampling.md][precise] depends on.

### Code-space decode and symbolization

**Concern 4 — not applicable.** Addresses become symbols via [elfutils][elfutils],
not libnuma.

### Event-space and tracing

**Concern 5 — not applicable.** Tracepoint records are decoded by
[libtraceevent][libtraceevent].

### NUMA and topology

**Concern 6 — the entire page.** Everything in [How it works](#how-it-works) is
this concern: node/distance enumeration from sysfs, and the mempolicy syscall
wrappers. Node enumeration + distances give a placement decoder everything it needs
to _describe_ the machine; what it cannot do is introspect an address.

#### The missing VA-to-node helper

The single most important finding on this page: **libnuma exposes no "which node
backs this virtual address?" helper.** The query exists only as a raw syscall,
used by the numactl _tool_ (never by `libnuma.c` itself):

- `get_mempolicy(&node, NULL, 0, addr, MPOL_F_NODE | MPOL_F_ADDR)` — returns, in
  `node`, the node backing the page containing `addr` ([`test/mynode.c:10`][mynode-c];
  also `shm.c:307`), or
- `numa_move_pages(pid, n, pages, NULL, status, 0)` in **query mode** (a `NULL`
  target-nodes array) — after which each `status[i]` holds the current node of
  `pages[i]`.

A tempting near-miss, `numa_police_memory`, does **not** do this — it only _faults
pages in_ (touches them to force allocation); it never _queries_ their node. So a
data-source profiler that wants node-precise attribution must open-code one of the
two raw calls above; there is no `numa_addr_to_node(...)` to reach for.
`[source-verified]`

> [!NOTE]
> **Discrepancy resolved.** An early hypothesis held that `numa_police_memory`
> queries the backing node. It does not — it faults pages in. The VA→node query is
> the raw `get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR)` / `move_pages` query-mode path.
> This correction is exactly what [precise-sampling.md][precise]'s node classifier
> is built on. `[source-verified]`

### Event naming and encoding

**Concern 7 — not applicable.** Node numbers are not hardware-event selectors;
event naming is [event-naming.md][naming]'s.

---

## Strengths

- **Complete topology description**: node count, per-node CPU masks, and the full
  ACPI SLIT distance matrix, all read straight from a stable sysfs layout.
- **Thin, predictable syscall wrappers**: `numa_alloc_onnode`, `numa_set_membind`,
  and `numa_move_pages` are one syscall each — easy to reason about and to
  reimplement.
- **Placement is well-served**: binding memory to a node, migrating pages, and
  setting policy are all first-class.
- **Stable, ubiquitous ABI**: `libnuma`/`numactl` is present on essentially every
  Linux NUMA system.

## Weaknesses

- **No VA→node helper** — the one query a data-source profiler needs is absent from
  the library and must be open-coded as a raw `get_mempolicy`/`move_pages` call
  (the headline finding).
- **`numa_police_memory` is a false friend**: it faults pages, it does not query
  their node — an easy trap.
- **No `numa.pc`**: no pkg-config integration, so build systems wire `-lnuma` by
  hand.
- **Coarse upstream signal**: the `perf_mem_data_src` locality hint libnuma would
  refine is itself coarse (IBS reports only a "remote" bit), so even a correct
  VA→node lookup only sharpens an already-lossy signal — see
  [precise-sampling.md][precise].
- **Linux-only and moot on UMA**: on Apple Silicon (UMA) the entire node axis
  collapses ([macos.md][macos]).

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                              | Trade-off                                                                                    |
| ------------------------------------------------------------ | ---------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Topology from sysfs, not a syscall                           | `/sys/devices/system/node` is a stable, parseable, unprivileged source | Ties the reader to the sysfs layout; a container without it sees no topology                 |
| Thin `WEAK` syscall shims for mempolicy                      | Near-zero overhead; the kernel policy is the source of truth           | The library is a thin veneer — anything the syscalls do not offer, it does not either        |
| Placement helpers (`numa_alloc_onnode`) but no VA→node query | Optimizes the common _placement_ path (bind memory to a node)          | Leaves _introspection_ (which node backs an address) unwrapped — profilers must open-code it |
| Ship no pkg-config file                                      | Historical; the ABI is stable enough to link by hand                   | Every consumer wires `-lnuma` and the include path manually                                  |

---

## Sources

- [numactl / libnuma — GitHub repository][numactl-repo] (`libnuma.c`, `syscall.c`, `distance.c`, `numa.h`, `shm.c`, `test/mynode.c`, read at `numactl@93c1fe5`, 2.0.19)
- [`libnuma.c`][libnuma-c] — node enumeration, `numa_parse_bitmap`, `dombind`→`mbind`, `numa_alloc_onnode`/`numa_set_membind`/`numa_move_pages`
- [`syscall.c`][syscall-c] — the `WEAK` mempolicy shims (`get_mempolicy`/`set_mempolicy`/`mbind`/`migrate_pages`/`move_pages`)
- [`distance.c`][distance-c] — `read_distance_table` / `numa_distance` (the ACPI SLIT)
- [`test/mynode.c`][mynode-c] — the raw `get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR)` VA→node query that libnuma itself never wraps
- The classifier this decoder feeds: [precise-sampling.md][precise]; the [acquisition hub][linux] it serves; the sibling decoders [elfutils][elfutils] · [libtraceevent][libtraceevent]; and the UMA collapse on [macOS][macos]
- Shared vocabulary: [concepts.md][concepts] ([NUMA topology and page→node oracles][numa-concept], [data-source attribution][datasrc])

<!-- References -->

[concepts]: ./concepts.md
[numa-concept]: ./concepts.md#numa-topology-and-page-node-oracles
[datasrc]: ./concepts.md#data-source-attribution
[linux]: ./linux-perf-events.md
[precise]: ./precise-sampling.md
[elfutils]: ./elfutils.md
[libtraceevent]: ./libtraceevent.md
[macos]: ./macos.md
[naming]: ./event-naming.md
[numactl-repo]: https://github.com/numactl/numactl
[libnuma-c]: https://github.com/numactl/numactl/blob/93c1fe5fabf38502ca315598bf74699c41300df9/libnuma.c
[syscall-c]: https://github.com/numactl/numactl/blob/93c1fe5fabf38502ca315598bf74699c41300df9/syscall.c
[distance-c]: https://github.com/numactl/numactl/blob/93c1fe5fabf38502ca315598bf74699c41300df9/distance.c
[mynode-c]: https://github.com/numactl/numactl/blob/93c1fe5fabf38502ca315598bf74699c41300df9/test/mynode.c
