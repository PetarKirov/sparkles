# libtraceevent

The survey's **event-space decoder**: given a tracepoint's tracefs `format` schema
and a raw record blob, it extracts typed fields by name — and it neither counts,
samples, nor reads a single file from disk.

| Field            | Value                                                                                                 |
| ---------------- | ----------------------------------------------------------------------------------------------------- |
| Library          | `libtraceevent` (the trace-event parsing library split out of the kernel `tools/lib/traceevent`)      |
| Role             | Parse a tracepoint `format` schema, then extract typed fields from a raw record blob by name          |
| Public header    | `include/traceevent/event-parse.h`                                                                    |
| Version          | **1.9.0**, [`libtraceevent@51d47b0`][lte-src]                                                         |
| Boundary         | Pairs with **`libtracefs`**, which reads the tracefs files; libtraceevent parses buffers it is handed |
| Touches the PMU? | **No.** Pure decoder — the [Linux hub][linux]'s concern-5 delegate                                    |
| Verification     | `[source-verified]` — the acquisition-side tracepoint gate is `[hw-verified: x86_64-linux]` (below)   |

> [!NOTE]
> Like the other decoders in this survey, libtraceevent is scoped to exactly one
> of the seven concerns — event-space (concern 5). The rest are **not applicable**,
> and saying so is a finding: it has no counter, no sampler, no symbol table, no
> topology. Source read at **1.9.0** (`libtraceevent@51d47b0`, 2026-05-29).

---

## Overview

### What it decodes

A [`perf_event_open`][linux] event opened with `PERF_TYPE_TRACEPOINT` and
`PERF_SAMPLE_RAW` delivers a raw, opaque byte blob per sample — the tracepoint's
argument record. That blob is _typed_ only by the tracepoint's tracefs `format`
schema. libtraceevent is the parser that turns the pair `(format schema, record
blob)` into named, typed field reads: given the `sched_switch` format and a raw
record, it answers `prev_comm`, `next_pid`, and so on. This is the
[event-space][eventspace] half of the survey — enriching and gating hardware PMU
data with OS-level events (syscalls, scheduling, faults).

### Design philosophy: a parser, not a reader

The library's defining boundary is stated in its own source. `tep_parse_format`
and `tep_parse_event` take the format text as a **buffer the caller supplies** —
the library documents where those buffers _come from_ but does not fetch them
([`src/event-parse.c:8462`][lte-src]):

> `* This parses the event format and creates an event structure * to quickly parse raw data for a given event. * * These files currently come from: * * /sys/kernel/debug/tracing/events/.../.../format`

`[source-verified]` That comment names the tracefs path — and then hands the file
I/O to somebody else. Reading `.../events/<system>/<event>/format` off disk is
**`libtracefs`**'s job (or the caller's); libtraceevent only ever sees a buffer.
A grep of the tree for a `tracefs` file reader turns up three hits, all in
comments — there is no such function. `[source-verified]`

---

## How it works

The lifecycle is: allocate a parser context, feed it one or more `format`
buffers to register event schemas, then repeatedly decode record blobs against
those schemas by field name.

**The `tep_handle` and the `format` parse.** A parser context is a
`struct tep_handle`, created with `tep_alloc` and released with `tep_free`
([`event-parse.h:584`][lte-src]). A schema is registered by parsing a `format`
buffer: `tep_parse_event(tep, buf, size, sys)` or the lower-level
`tep_parse_format(tep, &event, buf, size, sys)` ([`event-parse.h:458`][lte-src]),
both returning an `enum tep_errno`. After registration, an event is looked up by
name with `tep_find_event_by_name` ([`:523`][lte-src]) or, from a live record,
with `tep_find_event_by_record` ([`:525`][lte-src]). The producers are
`__parse_event` at [`src/event-parse.c:8469`][lte-src] / [`:8491`][lte-src].
`[source-verified]`

**Field extraction by name.** Once an event schema is parsed, a field is found by
name with `tep_find_field(event, name)` ([`event-parse.h:506`][lte-src]), returning
a `struct tep_format_field {name, type, offset, size, flags}`
([`:105`][lte-src]). The value is then read out of the raw record by
offset/size — `tep_read_number_field(field, data, &val)`
([`:516`][lte-src], implemented at [`src/event-parse.c:4414`][lte-src], and only for
field sizes 1/2/4/8) or the more general `tep_get_field_val`. The record blob
itself is a `struct tep_record {data, size, ts, cpu}` ([`:29`][lte-src]) — the
bytes plus a timestamp and originating CPU. `[source-verified]`

So the whole decode is: parse a `format` string once → get a `tep_event` → for
each raw record, `tep_find_field` + `tep_read_number_field` per field of interest.
Nothing in that path opens a file or reads a counter.

> [!NOTE]
> **Discrepancy resolved — the public header is `include/traceevent/event-parse.h`.**
> An early note placed the header at `src/event-parse.h`; the installed public
> header is `include/traceevent/event-parse.h`. The implementation lives in
> `src/event-parse.c`. `[source-verified]`

---

## The seven concerns

The concern order is fixed across the survey. For an event-space decoder, one
applies and six do not.

### Scalar counting

**Concern 1 — not applicable.** libtraceevent reads no counters; a tracepoint is
_counted_ through [`perf_event_open`][linux], and the number never passes through
this library.

### Overflow sampling

**Concern 2 — not applicable to acquisition.** The [ring buffer][linux] delivers
the `PERF_SAMPLE_RAW` blob; libtraceevent is the _downstream_ that types it
(concern 5).

### Precise sampling and data-source attribution

**Concern 3 — not applicable.** Precise-sampling payloads
([precise-sampling.md][precise]) are hardware-defined records, not tracepoint
schemas — a different decode path entirely.

### Code-space decode and symbolization

**Concern 4 — not applicable.** Turning an instruction pointer into a symbol is
[elfutils][elfutils]' job. libtraceevent decodes _event arguments_, not addresses.

### Event-space and tracing: `PERF_TYPE_TRACEPOINT` and `PERF_SAMPLE_RAW`

**Concern 5 — the entire page.** This is libtraceevent's whole reason to exist, and
everything in [How it works](#how-it-works) is this concern. It is the second half
of a two-part pipeline: the [Linux hub][linux-trace] _acquires_ the tracepoint (open
it with `PERF_TYPE_TRACEPOINT`, attach its record with `PERF_SAMPLE_RAW`);
libtraceevent _types_ the resulting blob against the `format` schema.

> [!IMPORTANT]
> **The decoder is only reachable once the events are opened — and opening them is
> gated.** A tracepoint's numeric `id` (the `config` value
> `perf_event_open` needs) lives in `.../events/<system>/<event>/id` under tracefs,
> whose files are **root-only** on hardened boxes. The sparkles `--syscalls` layer
> hits exactly this gate on the test machine — the tracepoint `id` files are
> `0700`, so an unprivileged process cannot even read the `id` to open the event,
> let alone reach libtraceevent's decode. This is a [privilege-gating][privilege]
> finding on the acquisition side; libtraceevent itself is blameless (it never
> touches the file). See [sparkles-baseline.md][baseline]. `[hw-verified: x86_64-linux]`

### NUMA and topology

**Concern 6 — not applicable.** No nodes, no distances, no placement. Topology is
[libnuma][libnuma].

### Event naming and encoding

**Concern 7 — not applicable in the hardware sense.** libtraceevent resolves a
tracepoint _field_ name from a `format` schema, but the hardware-event
`type`/`config` naming problem is [event-naming.md][naming]'s. The overlap is
nominal only.

---

## Strengths

- **A clean parser/reader split**: libtraceevent parses buffers; `libtracefs`
  reads files. A consumer can supply a captured or synthesized `format` string and
  decode without any tracefs mount at all.
- **Schema-driven, name-based field access**: `tep_find_field` +
  `tep_read_number_field` decode by field name, so a consumer is insulated from a
  tracepoint's exact byte layout.
- **Self-describing records**: the `format` schema fully types the blob — no
  hand-written struct per tracepoint.
- **Battle-tested provenance**: it is the kernel's own trace-event parser, split
  out of `tools/lib/traceevent`.

## Weaknesses

- **It decodes, it does not acquire**: the tracepoint must first be opened through
  [`perf_event_open`][linux], and that open is [privilege-gated][privilege] behind
  root-only tracefs `id` files on hardened systems — the real blocker in practice.
- **You must supply the schema**: without the `format` buffer (from `libtracefs`
  or a capture) there is nothing to parse against.
- **Numeric-field convenience only for 1/2/4/8-byte fields**:
  `tep_read_number_field` handles the common integer sizes; arrays/strings/complex
  fields need the more general `tep_get_field_val` path.
- **Two libraries for one job**: a full tracepoint pipeline pulls in both
  libtraceevent and libtracefs, each with its own ABI.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                                  | Trade-off                                                                       |
| ----------------------------------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Parse a caller-supplied `format` buffer, never read tracefs | Decouples parsing from file I/O; works on captured/synthesized schemas     | A consumer must also pull in `libtracefs` (or read the files itself) to feed it |
| Name-based field lookup (`tep_find_field`)                  | Insulates consumers from a tracepoint's byte layout across kernel versions | A per-field lookup + read, rather than a fixed struct cast                      |
| `tep_read_number_field` limited to 1/2/4/8-byte fields      | Covers the overwhelmingly common integer fields with a tight fast path     | Non-integer fields fall back to `tep_get_field_val`                             |
| Split out of the kernel tree as a standalone library        | Reusable by `perf`, `trace-cmd`, and third parties without the kernel tree | Version skew between the standalone library and the kernel it decodes for       |

---

## Sources

- [libtraceevent project page][lte-home] and its [source tree][lte-src] (`include/traceevent/event-parse.h`, `src/event-parse.c`, read at `libtraceevent@51d47b0`, 1.9.0)
- `include/traceevent/event-parse.h` — `tep_alloc`/`tep_free`, `tep_parse_event`/`tep_parse_format`, `tep_find_event_by_name`/`_by_record`, `tep_find_field`, `tep_read_number_field`, `struct tep_format_field`, `struct tep_record`
- `src/event-parse.c` — the `__parse_event` producer and the tracefs-`format` provenance comment quoted above
- The [acquisition hub][linux-trace] that opens the tracepoint (concern 5, acquisition half), and the sibling decoders [elfutils][elfutils] · [libnuma][libnuma]
- The acquisition-side [privilege gate][baseline] the sparkles `--syscalls` layer hits
- Shared vocabulary: [concepts.md][concepts] ([event-space and tracepoints][eventspace], [privilege gating][privilege])

<!-- References -->

[concepts]: ./concepts.md
[eventspace]: ./concepts.md#event-space-and-tracepoints
[privilege]: ./concepts.md#privilege-gating
[linux]: ./linux-perf-events.md
[linux-trace]: ./linux-perf-events.md#event-space-and-tracing-perf-type-tracepoint-perf-sample-raw
[elfutils]: ./elfutils.md
[libnuma]: ./libnuma.md
[precise]: ./precise-sampling.md
[naming]: ./event-naming.md
[baseline]: ./sparkles-baseline.md
[lte-home]: https://git.kernel.org/pub/scm/libs/libtrace/libtraceevent.git/
[lte-src]: https://git.kernel.org/pub/scm/libs/libtrace/libtraceevent.git/tree/
