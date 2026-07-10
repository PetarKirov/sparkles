# Grounding ledger — `linux-perf-events.md`

Claim-by-claim verification of `docs/research/cpu-pmu/linux-perf-events.md` against
the pinned local trees: `linux` v7.1-rc6 (`e43ffb69e043`), and druntime (LDC
1.41.0). Hardware experiments recorded on **Linux 6.18.26**, **AMD Ryzen 9 7940HX**
(Zen 4, 6 core PMCs), `perf_event_paranoid = -1`. `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                                          | Type       | Source (local + locator)                                                                   | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------------------ | ------ |
| L1  | `perf_event_open` takes `perf_event_attr` (`type`/`config`/bitfield block), returns an fd; fds group via `group_fd`                                            | fact       | `include/uapi/linux/perf_event.h:393` (struct), `:418` (bitfield), `:576` (`IOC_*`)        | ✓      |
| L2  | A group is scheduled all-or-nothing; a partial group is rolled back                                                                                            | quote      | `kernel/events/core.c:2886` — _"Groups can be scheduled in as one unit only…"_ (verbatim)  | ✓      |
| L3  | `PERF_FORMAT_GROUP` → one `read(2)` returns `{nr, time_enabled, time_running, value[nr]}`                                                                      | fact       | read-format enum `perf_event.h:365`; producer `core.c:6154`, `nr` at `:6168`               | ✓      |
| L4  | Multiplexing: hrtimer rotation; scale by `enabled/running`; formula documented in the uAPI                                                                     | quote      | `core.c:4587`/`:744`; formula block `perf_event.h:685` (quoted verbatim in page)           | ✓      |
| L5  | `rdpmc` self-monitoring: mmap-page seqlock loop; `cap_user_rdpmc`/`pmc_width` are **arch**-set                                                                 | quote      | `perf_event.h:596`/`:608`/`:646`/`:663`; `core.c:6825`/`:6815`; `arch/x86/events/core.c`   | ✓      |
| L6  | Sampling arms `sample_period`/`sample_freq` + `sample_type`; overflow writes `RECORD_SAMPLE` to the mmap ring (page 0 control, `data_head`/`data_tail`)        | fact       | `perf_event.h:142`/`:1059`/`:749`/`:750`/`:1061`                                           | ✓      |
| L7  | Ring drain is a seqcount: acquire `data_head`, process `[tail,head)` mod size, release `data_tail`                                                             | behavior   | Experiment B parses it directly                                                            | ✓ (hw) |
| L8  | `PERF_RECORD_MMAP2` emitted **only** for mappings made while enabled; perf synthesizes the rest from `/proc/PID/maps`                                          | behavior   | `perf_event.h:1091`; Exp B captured **0** MMAP2 until a mid-window `mmap(PROT_EXEC)`       | ✓ (hw) |
| L9  | perf consumer pipeline: MMAP2 → `dso_id` → `map__new` → `thread__find_map` → `map__map_ip` → `dso__find_symbol`                                                | fact       | `machine.c:1728`; `map.h:107`; `maps.c:1122`; `symbol.c:412`                               | ✓      |
| L10 | Build-id disambiguates the on-disk binary; a mismatch is rejected                                                                                              | behavior   | `build-id.c:863` (`dso__build_id_mismatch`)                                                | ✓      |
| L11 | `type`/`config` are opaque numbers here; human names are external (concern 7)                                                                                  | exposition | libpfm4 et al. — see `event-naming.md` grounding                                           | ✓      |
| L12 | Tracepoints countable/sampleable via `PERF_TYPE_TRACEPOINT` + `PERF_SAMPLE_RAW`; `id` files root-gated                                                         | behavior   | concern-5 boundary; tracefs `id` root gate on this box (`--syscalls` encounter)            | ✓ (hw) |
| L13 | druntime `core.sys.linux.perf_event` models the mmap page, records, and every `PERF_SAMPLE_*` → **pure-D sampler needs no C shim**                             | behavior   | druntime `core/sys/linux/perf_event.d` (LDC 1.41); all three probes compile without a shim | ✓      |
| E1  | `counting-group.d`: fitting group `scale=1.0000`, IPC 3.977; 10 counters / 6 PMCs multiplex, scaled estimates cluster at ~60.05M, two events `<not scheduled>` | figure     | Experiment A output (reproduced verbatim in page)                                          | ✓ (hw) |
| E2  | `sampling-symbolize.d`: 1996 IP samples → `sumSquares` (1852) / `mixHash` (130) with source lines; 1 captured MMAP2 names the same image                       | figure     | Experiment B output                                                                        | ✓ (hw) |
| E3  | `unwind-stack-user.d`: 5-frame DWARF-CFI backtrace on `--frame-pointer=none` (`level3→…→run`)                                                                  | figure     | Experiment C output                                                                        | ✓ (hw) |

## Discrepancies

- **⚠ D-L1 — perf-tool symbol naming drift (v7.1-rc6).** The `tools/perf` consumer
  API has churned: `build_id__sprintf` → `build_id__snprintf`; `dso__build_id`
  accessor → `dso__bid()`; `sample__resolve` → `machine__resolve`; user-side
  `maps__insert` → `thread__insert_map` → `maps__fixup_overlap_and_insert`; and
  `struct map` is now a `DECLARE_RC_STRUCT` (ref-counted, accessor-only). **Not a
  page error** — the page's L9 pipeline deliberately uses the _current_
  `e43ffb69e043` names (`machine__process_mmap2_event`, `thread__find_map`,
  `map__map_ip`, `dso__find_symbol`), not older tutorial names. Recorded so a
  reader hitting an older/newer tree knows the names are version-pinned.
- **Note — multiplexing formula locator.** The scaling formula is the comment block
  at `perf_event.h:685` (`quot`/`rem`/`count = quot*enabled + (rem*enabled)/running`),
  confirmed verbatim; the surrounding `enabled += delta` pseudocode runs `:681-687`.
- **Note — `cap_user_rdpmc` is arch-set (L5).** The generic
  `arch_perf_update_userpage` (`core.c:6815`) is a `__weak` no-op; x86 sets the
  cap/width in `arch/x86/events/core.c`. The ARM `arm_pmuv3` userpage path is
  W3's — the page hands it off explicitly (link to `arm.md`).

**Net:** 0 substantive discrepancies. Every quote (groups all-or-nothing, the
multiplexing formula, the `rdpmc` seqlock) is verbatim from the uAPI/kernel; all
three hardware experiments reproduced their outputs on the recorded box. The one ⚠
is version-naming drift in the `tools/perf` consumer, which the page sidesteps by
using the pinned-tree names.
