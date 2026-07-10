# Grounding ledger — `libnuma.md`

Claim-by-claim verification of `docs/research/cpu-pmu/libnuma.md` against the pinned
tree `numactl@93c1fe5` (libnuma 2.0.19, read 2026-06-30). Source-only.
`$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                     | Type       | Source (local + locator)                                                                                         | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------- | ---------- | ---------------------------------------------------------------------------------------------------------------- | ------ |
| L1  | Mempolicy syscalls exposed as thin `WEAK` shims: `get_mempolicy`, `set_mempolicy`, `mbind`, `migrate_pages`, `move_pages` | fact       | `syscall.c:223`/`:238`/`:231`/`:246`/`:257`                                                                      | ✓      |
| L2  | `numa_alloc_onnode` = `mmap` + `dombind` → `mbind`                                                                        | quote      | `libnuma.c:1150`, `:324` (_"static int dombind(… mbind(…) …"_, verbatim)                                         | ✓      |
| L3  | `numa_set_membind` = `set_mempolicy(MPOL_BIND)`; `numa_move_pages` = `move_pages`                                         | fact       | `libnuma.c:1206`, `:1913`                                                                                        | ✓      |
| L4  | Node enumeration is `opendir("/sys/devices/system/node")`                                                                 | fact       | `libnuma.c:371`                                                                                                  | ✓      |
| L5  | Per-node CPU mask read from `.../node<N>/cpumap` → `getdelim` → `numa_parse_bitmap`                                       | fact       | `libnuma.c:1571`                                                                                                 | ✓      |
| L6  | Inter-node distance (ACPI SLIT) from `.../node<N>/distance` via `read_distance_table` → `numa_distance`                   | fact       | `distance.c:47`, `:105`; `struct bitmask {size; maskp}` `numa.h:44`                                              | ✓      |
| L7  | **No VA→node helper** — the query exists only as a raw syscall in the numactl _tool_, not `libnuma.c`                     | quote      | `test/mynode.c:10` — _"get_mempolicy(&nd, NULL, 0, man, MPOL_F_NODE\|MPOL_F_ADDR)"_ (verbatim); also `shm.c:307` | ✓      |
| L8  | Alternative VA→node path: `move_pages` **query mode** (`NULL` target-nodes → node in `status[]`)                          | behavior   | `numa_move_pages`→`move_pages` (`libnuma.c:1913`); query-mode semantics                                          | ✓      |
| L9  | `numa_police_memory` only **faults pages in** — it does **not** query their node                                          | behavior   | `libnuma.c` (`numa_police_memory` touches pages, no node read)                                                   | ✓      |
| L10 | No `numa.pc` ships → `pkg-config libnuma` fails                                                                           | fact       | pinned tree has no `.pc`; contrast elfutils                                                                      | ✓      |
| L11 | UMA collapse: on Apple Silicon the entire node axis is moot                                                               | exposition | cross-ref `macos.md` (UMA)                                                                                       | ✓      |

## Discrepancies

- **⚠ D-LN1 — libnuma has no "which node backs this VA" helper.** The headline
  finding. The brief hypothesized a library wrapper; there is none — the VA→node
  query is the raw `get_mempolicy(MPOL_F_NODE | MPOL_F_ADDR)` (used by the numactl
  _tool_, `test/mynode.c:10` / `shm.c:307`) or `move_pages` query mode. The page
  makes this its central point and quotes the raw call. `[source-verified]` This is
  the exact gap `precise-sampling.md` (W2) builds its node classifier on.
- **⚠ D-LN2 — `numa_police_memory` faults, it does not query.** A tempting
  near-miss: the brief hypothesized `numa_police_memory` queries the backing node;
  it only faults pages in. Corrected in the page (WARNING/NOTE + the Weaknesses
  "false friend" bullet). `[source-verified]`
- **Note — no runnable probe on this page.** libnuma is source-only in this drop;
  the VA→node path it documents is exercised by W2's precise-sampling probe
  (`mem-latency-numa.d`), not here. The page is tagged `[source-verified]`
  throughout.

**Net:** 0 substantive discrepancies. The two verbatim quotes (`dombind`→`mbind`;
the raw `get_mempolicy` VA→node call) are exact from the pinned tree. Both ⚠ items
are brief-vs-source corrections about _absence_ (no VA→node helper;
`numa_police_memory` does not query) — precisely the findings the page is built to
surface, and the ones the precise-sampling classifier depends on.
