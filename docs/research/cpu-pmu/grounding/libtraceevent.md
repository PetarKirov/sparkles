# Grounding ledger — `libtraceevent.md`

Claim-by-claim verification of `docs/research/cpu-pmu/libtraceevent.md` against the
pinned tree `libtraceevent@51d47b0` (1.9.0, read 2026-05-29). The acquisition-side
tracefs gate was observed on **Linux 6.18.26** (AMD Ryzen 9 7940HX). Source-only
otherwise. `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

Status key: ✓ verified · ≈ paraphrase-verified · ⚠ discrepancy · ◯ not locally groundable · 🌐 web-only.
Types: quote · fact · figure · behavior · exposition · opinion.

| #   | Claim                                                                                                                                              | Type     | Source (local + locator)                                                                                                   | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------- | ------ |
| L1  | Parses a caller-supplied `format` **buffer**; documents (but does not fetch) the tracefs `format` path                                             | quote    | `src/event-parse.c:8462` — _"These files currently come from: /sys/kernel/debug/tracing/events/.../.../format"_ (verbatim) | ✓      |
| L2  | Handle lifecycle `tep_alloc`/`tep_free`; schema parse `tep_parse_event` / `tep_parse_format` return `enum tep_errno`                               | fact     | `event-parse.h:584`, `:458`; producer `src/event-parse.c:8469`/`:8491`                                                     | ✓      |
| L3  | Event lookup `tep_find_event_by_name` / `tep_find_event_by_record`                                                                                 | fact     | `event-parse.h:523` / `:525`                                                                                               | ✓      |
| L4  | Field extraction by name: `tep_find_field` → `struct tep_format_field {name,type,offset,size,flags}`                                               | fact     | `event-parse.h:506`, `:105`                                                                                                | ✓      |
| L5  | Value read by offset/size: `tep_read_number_field` (sizes 1/2/4/8 only) or `tep_get_field_val`; record blob `struct tep_record {data,size,ts,cpu}` | fact     | `event-parse.h:516` (`src/event-parse.c:4414`), `:29`                                                                      | ✓      |
| L6  | libtraceevent does **not** read the tracefs file — no `tracefs` reader exists (3 grep hits, all comments); that is `libtracefs`'s job              | behavior | grep of the pinned tree; boundary comment at `event-parse.c:8462`                                                          | ✓      |
| L7  | Public header is `include/traceevent/event-parse.h` (impl in `src/event-parse.c`)                                                                  | fact     | pinned tree layout                                                                                                         | ✓      |
| L8  | Acquisition-side gate: a tracepoint `id` lives in `.../events/<sys>/<event>/id`, root-only (`0700`) on hardened boxes                              | behavior | sparkles `--syscalls` encounter on the test box (see `sparkles-baseline.md`)                                               | ✓ (hw) |

## Discrepancies

- **⚠ D-LT1 — public header path.** An early note placed the header at
  `src/event-parse.h`; the installed public header is
  `include/traceevent/event-parse.h`, with the implementation in
  `src/event-parse.c`. Corrected in the page (metadata row + a "Discrepancy
  resolved" NOTE). `[source-verified]`
- **⚠ D-LT2 — the parser/reader boundary.** The library does **not** read tracefs
  files (a plausible assumption for a "trace event" library); reading the `format`
  file is `libtracefs`'s job. The page makes this its central design point and
  quotes the boundary comment. `[source-verified]`
- **Note — no hardware decode experiment.** libtraceevent has no runnable probe in
  this drop; the acquisition-side gate (L8) is the only `[hw-verified]` item, and it
  is _upstream_ of the library (the events cannot be opened unprivileged, so the
  decoder is never reached on this box). The page frames the page itself as
  `[source-verified]` and the gate as `[hw-verified]`.

**Net:** 0 substantive discrepancies. The one verbatim quote (the tracefs-`format`
provenance comment) is exact; the two ⚠ items are brief-vs-source corrections
(header path, does-not-read-tracefs) that the page now states as its core boundary.
The only soft spot — no decode probe — is honest: the library is unreachable on the
test box because its input events are root-gated, which the page states plainly.
