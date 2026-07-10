# Grounding ledger — `elfutils.md`

Claim-by-claim verification of `docs/research/cpu-pmu/elfutils.md` against the
pinned tree `elfutils@6f8f78c` (source 0.195; probes linked against 0.194,
nixpkgs). Hardware experiments recorded on **Linux 6.18.26**, **AMD Ryzen 9
7940HX** (Zen 4), **LDC 1.41**. `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                             | Type     | Source (local + locator)                                                                                           | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------ | ------ |
| L1  | `libdwfl` session: `dwfl_begin(&cb)` → `dwfl_linux_proc_report(dwfl, pid)` (parses `/proc/PID/maps`) → `dwfl_report_end`                          | fact     | `libdwfl/libdwfl.h:104`, `:384`, `:190`; callbacks `:72`                                                           | ✓      |
| L2  | Standard callbacks `dwfl_linux_proc_find_elf` / `dwfl_standard_find_debuginfo` are taken by address                                               | fact     | `libdwfl.h:393` / `:319`                                                                                           | ✓      |
| L3  | Resolution pipeline: `dwfl_addrmodule` → `dwfl_module_addrinfo` → `dwfl_module_getsrc` → `dwfl_lineinfo`                                          | fact     | `libdwfl.h:231`, `:514`, `:590`, `:606`                                                                            | ✓      |
| L4  | elfutils recommends `addrinfo` over the older `addrsym`                                                                                           | fact     | `libdwfl.h:520`                                                                                                    | ✓      |
| L5  | `dwfl_module_addrinfo`'s `offset` (arg 3) and `sym` (arg 4) **cannot be NULL** — a `NULL` segfaults                                               | quote    | `libdwfl.h:499` (_"OFFSET cannot be NULL … SYM cannot be NULL"_) + `__nonnull_attribute__ (3, 4)` on the prototype | ✓ (hw) |
| L6  | Inline expansion: `dwfl_module_addrdie` → `dwarf_getscopes` (innermost-first) + `dwarf_decl_file`/`dwarf_decl_line`                               | fact     | `libdwfl.h:567`; `libdw/libdw.h:859`, `:929`/`:932`                                                                | ✓      |
| L7  | DWARF-CFI unwind: `dwfl_attach_state` (callbacks `{next_thread, memory_read, set_initial_registers}`) → `dwfl_getthread_frames` → `dwfl_frame_pc` | fact     | `libdwfl.h:725`, `:661`, `:815`, `:825`; register seeding `:783`/`:775`                                            | ✓      |
| L8  | Per-frame PC/activation contract: subtract 1 from `*PC` when `*ISACTIVATION` is false                                                             | quote    | `libdwfl.h:820` (*"Typically you need to subtract 1 from *PC if _ACTIVATION is false…"_, verbatim)                 | ✓      |
| L9  | CFI comes from `dwfl_module_dwarf_cfi` (`.debug_frame`) / `dwfl_module_eh_cfi` (`.eh_frame`)                                                      | fact     | `libdwfl.h:657` / `:658`                                                                                           | ✓      |
| L10 | `numa_alloc_onnode`-style module reporting reads the **same** `/proc/PID/maps` perf synthesizes MMAP2 from                                        | behavior | `dwfl_linux_proc_report` (`:384`); cross-check `linux-perf-events.md` L8                                           | ✓      |
| L11 | Version skew recorded honestly: source 0.195 vs runtime 0.194; all cited APIs exist in both                                                       | fact     | `configure.ac`/`NEWS` at `6f8f78c`; nixpkgs runtime 0.194                                                          | ✓      |
| E2  | Symbolized ~2000 live IPs → `sumSquares` (1852) / `mixHash` (130) with `file:line`                                                                | figure   | Experiment B (`sampling-symbolize.d`)                                                                              | ✓ (hw) |
| E3  | Frame-pointer-less 5-frame DWARF-CFI unwind offline (`level3→…→run`)                                                                              | figure   | Experiment C (`unwind-stack-user.d`)                                                                               | ✓ (hw) |

## Discrepancies

- **⚠ D-EF1 — perf reports modules with `dwfl_report_elf`, not `dwfl_report_module`.**
  An early hypothesis named `dwfl_report_module` for perf's user unwinder; the
  source shows `tools/perf/util/unwind-libdw.c` leaves `.find_elf` unset and uses
  `dwfl_report_elf()` (`unwind-libdw.c:66`, `:114`). Both entry points are valid;
  the page states this explicitly and uses `dwfl_linux_proc_report` in the probes.
  Corrected in the page (the "Discrepancy resolved" NOTE). `[source-verified]`
- **⚠ D-EF2 — `dwfl_module_addrsym` vs `dwfl_module_addrinfo` + the non-NULL trap.**
  The brief named `addrsym`; elfutils documents `addrinfo` as preferred, and
  `addrinfo`'s `offset`/`sym` must be non-NULL — a real segfault hit on the first
  probe run on a live IP. Corrected: the page uses `addrinfo` and carries the
  WARNING. `[hw-verified: x86_64-linux]`
- **Note — version skew (L11).** Source read 0.195, probes linked 0.194. Every API
  cited exists in both; the page records **0.194 as the tested version** and
  flags the skew in a WARNING.

**Net:** 0 substantive discrepancies remaining. Both header quotes (the non-NULL
`addrinfo` contract and the PC/activation rule) are verbatim from `libdwfl.h`; both
hardware experiments reproduced. The two ⚠ items were brief-vs-source corrections
(`dwfl_report_elf`, `addrinfo`) that the page now states correctly, and the version
skew is disclosed.
