# osc66 (Rust)

`osc66` is a small shaping-aware text filter that assigns explicit terminal cell
widths to clusters without requesting enlarged text.

**Last reviewed:** September 14, 2026.

| Field           | Value                                                            |
| --------------- | ---------------------------------------------------------------- |
| Language        | Rust, edition 2024                                               |
| License         | MIT; [manifest][manifest] and [license text][license]            |
| Repository      | [santhoshtr/osc66][repo]                                         |
| Documentation   | [Repository README][readme]                                      |
| Category        | Command-line filter; shaping-derived explicit-width producer     |
| Package version | `0.1.0` at the inspected revision                                |
| Revision        | `f7dd62e695372142f9b5a633f9afbbac369e7e15`                       |
| Commit date     | March 27, 2026                                                   |
| Dependencies    | `harfbuzz_rs` and `fontconfig-rs`                                |
| Inspection      | Local pinned source read; no upstream test or terminal execution |

## Overview

### What it solves

Unicode scalar widths do not necessarily describe the advance of shaped text.
Complex-script shaping can combine several input code points, change contextual
forms, and assign advances that a scalar-width sum does not predict. The filter
tries to make the application the authority for occupied columns by emitting
`w` metadata for each shaping cluster. [README][readme], [implementation][source].

This is the width-coordination use of the [text-sizing protocol][protocol], not
a Markdown-heading implementation. It sends neither `s` nor fractional scaling
keys. The default scale is one, so an explicit width should not be described
as a request for double-height or otherwise enlarged text.

Compare [Presenterm][presenterm] for scale-aware slide layout and
[mdfried][mdfried] for semantic heading routes. The [concepts][concepts] page
separates explicit occupancy, glyph advance, and font scale.

### Design philosophy

The [README][readme] describes the intended pipeline:

> `osc66` shapes input text with HarfBuzz, groups glyphs into clusters, computes each cluster's real advance width in cells, and emits an OSC 66 escape sequence per cluster carrying that width.

That is a useful statement of intent, not proof of universally accurate cell
measurement. The actual measurement is relative to one selected font's `0`
advance, rounded upward and capped at seven cells. The terminal may use a
different font, fallback face, or shaping context. [Source][source].

The design favors a short, inspectable pipeline over terminal integration. There
is no capability manager, layout tree, retained surface, or safe-output layer
hidden behind the CLI. Those absences are material to deciding what to borrow.

## How it works

The complete implementation is in [src/main.rs][source]. The major steps are:

1. Read an optional font-family argument, defaulting to `monospace`.
2. Ask Fontconfig for one matching file and load face index zero.
3. Shape the literal string `"0"` and take the first glyph's `x_advance`.
4. Read standard input as UTF-8 lines and shape each whole line.
5. Group adjacent glyph records with equal HarfBuzz cluster offsets.
6. Sum each group's advances and recover an input substring from its offsets.
7. Round the advance ratio upward, clamp it, and emit an OSC record.

The output template is exactly the width-only form:

```text
ESC ] 66 ; w=cells ; text BEL
```

The implementation's central arithmetic is:

```rust
let cells = ((advance as f64) / (ref_advance as f64)).ceil() as i32;
let cells = cells.clamp(0, 7);
```

These excerpts describe source, not execution results. `cells == 0` suppresses
the cluster entirely; each input line ends with an output newline. Empty lines
and shaping results with no glyphs also emit a newline. [Processing loop][process].

## Protocol and API

The public surface is the executable: optional font name, standard input, and
standard output. The [manifest][manifest] declares a binary package with the
two font-related dependencies. There is no exported library contract for a
prepared run, a safe payload, or an independently inspectable layout plan.

Internally, `process_line` accepts a borrowed string, a `Font`, the reference
advance, and a generic `Write` output. That separation makes the transform easy
to inspect, but the function returns no structured error. Output operations
use `unwrap`, so a failed write is a panic rather than a recoverable result.
[Processing loop][process].

`w` is clamped to the protocol's legal width range. Zero is never emitted:
the filter skips such clusters instead of requesting terminal-calculated width.
Nonzero widths are emitted without `s`, `n`, `d`, `h`, or `v`.

For scale one, each emitted record requests one row and `w` columns. The
terminal is still responsible for drawing the enclosed text inside that box.
If the glyphs do not fit, the [protocol][protocol] permits implementation choices
such as truncation or shrinking; an explicit box is not a glyph-fit guarantee.

## Measurement and geometry

The reference glyph is the character **zero**, not glyph ID zero or an empty
glyph. `reference_advance` shapes `"0"` and indexes the first glyph position.
This establishes a font-unit ratio without querying the terminal's pixel cell
size. [Reference measurement][reference].

Only one font is selected. The source uses `Face::from_file(path, 0)` and one
`Font`; it does not build fallback runs or synchronize that face with the
terminal's font configuration. Matching a family name is therefore an input
assumption, not a verified terminal metric contract. [Startup][startup].

Each line is shaped as a whole buffer before advances are collected. That can
capture contextual shaping during measurement. However, output consists of
separate text records, not the shaped glyph IDs and positions. It does not
transmit the full-line shaping result to the terminal.

HarfBuzz clusters are byte-offset groupings, not necessarily Unicode extended
grapheme clusters. The README's user-facing grapheme language should not obscure
the implementation's actual grouping criterion: adjacent equal `info.cluster`
values in glyph-output order. [Cluster grouping][clusters].

Rounding is per cluster. The sum of upward-rounded ratios can exceed an
upward-rounded total line advance, while clamping a large cluster to seven can
understate its estimated width. Neither behavior is a neutral conversion from
font units to terminal cells; both are layout policy.

There is no explicit check that the reference advance is positive or nonzero.
The floating-point division and cast are not a meaningful error-reporting
policy for an unusable reference metric. This is a source-derived robustness
gap; no unusual-font case was run.

## Capability and fallback

The filter never queries terminal support, checks whether stdout is a terminal,
or chooses an ordinary-text fallback. Every nonempty accepted cluster goes
through the OSC writer. [Startup][startup], [processing loop][process].

This is especially significant for OSC: an unsupported terminal may consume an
unrecognized control string without displaying its payload. “It remains UTF-8
inside the escape sequence” is not a portable fallback argument.

The [protocol][protocol] permits width-only implementations and describes cursor
position probes for width and scale. A consumer borrowing this technique should
probe the width capability it actually needs, rather than requiring enlargement
or inferring support from a font being installed.

Font lookup failure prints a diagnostic and exits with status one. Input errors
also report a diagnostic and exit. These are operational failures, not rendering
fallbacks; there is no second route that preserves the input as ordinary text.
[Startup][startup].

## Layout and clipping

The program preserves input line boundaries only in the sense that it emits
one newline per line read. It does not preserve a missing final newline, and
the line reader is not a byte-for-byte transport for arbitrary input.
[Input loop][startup].

There is no viewport width, wrapping algorithm, right-edge clipping, or vertical
budget in `process_line`. The terminal receives a stream of multicell records
and applies its own wrapping and overwrite rules. A caller cannot infer that
an input line fits a particular pane merely because each record has `w <= 7`.

More importantly, substring recovery assumes cluster offsets increase. For each
group, the code sets `start` to the current offset and `end` to the next group's
offset, or the input length for the last group. [Substring reconstruction][slicing].

Right-to-left shaping can produce decreasing cluster offsets. In that case,
`line_bytes[start..end.min(input_len)]` can have a start greater than its end.
The `start >= input_len` guard does not reject that ordering, and
`from_utf8(...).unwrap_or("")` runs only after the slice has been constructed.

> [!WARNING]
> The decreasing-cluster/RTL hazard is derived from the slice construction.
> It was not reproduced in this review. Handling direction requires a correct
> mapping from shaping clusters to logical source ranges, not just reversing
> the emitted text or suppressing UTF-8 errors.

## Retained state and interaction

The retained state is a font and one reference advance. A line's glyph result
and cluster vector are temporary. There is no scene, owner map, previous frame,
selection state, search index, cursor-navigation model, or resize invalidation.
[Complete implementation][source].

That is appropriate for a filter, but means it is not evidence that explicit
width alone integrates into a retained TUI. A widget host still needs the same
occupancy to drive wrapping, clipping, hit testing, and old-content erasure.

Skipping zero-width groups also matters for source identity. The code drops
their text rather than explicitly attaching it to another emitted owner. Whether
that changes a particular sequence depends on shaping and grouping, but the
filter cannot be assumed to preserve every source scalar. [Processing loop][process].

For the [Sparkles proposal][proposal], the transferable idea is an explicit
measured-width run. The CLI's font assumptions and temporary vectors are not a
ready-made retained text representation.

## Safety and evidence

The writer interpolates recovered input text directly between OSC metadata and
BEL. There is no dedicated escape-code-safe UTF-8 encoder, control rejection,
or payload-byte limiter. Shaping text is not sanitizing terminal controls.
[Emission][slicing], [protocol contract][protocol].

The seven-cell clamp is a bound on requested geometry, not on payload bytes.
A cluster can contain many code points; neither the input line nor recovered
cluster is checked against the protocol's 4096-byte text limit.

Other source-derived risks are the unchecked first reference glyph access,
unvalidated reference advance, increasing-offset assumption, and panic-on-write
behavior. These describe visible checks that are absent, not demonstrated
security exploits or failures on a particular installed font.

The implementation contains no unit-test module. The README provides examples
and illustrative width claims, but they were not run here and are not independent
Unicode or terminal oracles. The review read the full 104-line implementation,
manifest, README, and license at the pinned revision.

Validation should cover logical/visual cluster order, zero-width input retention,
missing glyphs and fallback fonts, broken pipes, embedded OSC terminators, long
combining sequences, and unsupported terminals. The [validation plan][validation]
should keep those obligations separate from the README's accuracy claims.

## Strengths

- Demonstrates the protocol's useful width-only mode without conflating it with scale.
- Shapes a whole input line before collecting cluster advances.
- Makes reference measurement, rounding, and emitted widths easy to audit.
- Needs no image transport or raster cache for its output.
- Keeps font-unit measurement independent of absolute pixel size.

## Weaknesses

- One selected font and the `0` advance are not verified terminal metrics.
- Substring recovery assumes increasing cluster offsets and is unsafe for that assumption's failure.
- Zero-width groups are discarded, and large widths are silently capped.
- There is no capability negotiation, ordinary-text fallback, or pane layout.
- Raw payload emission has neither a safety policy nor a byte bound.

## Key design decisions and trade-offs

| Decision                  | Rationale                                  | Trade-off                                         |
| ------------------------- | ------------------------------------------ | ------------------------------------------------- |
| Emit only `w`             | Coordinate occupied columns                | Does not provide enlarged typography              |
| Shape whole lines         | Capture shaping context during measurement | Per-record terminal shaping may differ            |
| Normalize by `0` advance  | Avoid absolute pixel metrics               | Requires a suitable and matching font             |
| Round each cluster upward | Avoid fractional column requests           | Accumulated width can grow                        |
| Clamp to seven cells      | Stay inside the wire width range           | Wide clusters lose their measured requirement     |
| Stream without probing    | Keep a simple filter interface             | Caller must supply capability and fallback policy |

The [comparison][comparison] should classify this as a measurement experiment
and width producer, not as a safe, direction-complete text-sizing library.

## Sources

- [README][readme]: motivation, verified quote, and documented algorithm.
- [Manifest][manifest] and [license][license]: identity and dependency metadata.
- [Complete implementation][source]: measurement, grouping, emission, and CLI.
- [Protocol specification][protocol]: width/scale separation and payload contract,
  reviewed September 14, 2026.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and
  [Sparkles proposal][proposal]: terminology and design follow-up.

<!-- References -->

[repo]: https://github.com/santhoshtr/osc66/tree/f7dd62e695372142f9b5a633f9afbbac369e7e15
[manifest]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/Cargo.toml
[license]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/LICENSE
[readme]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/README.md
[source]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs
[reference]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs#L7-L11
[process]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs#L13-L74
[clusters]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs#L19-L42
[slicing]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs#L44-L70
[startup]: https://github.com/santhoshtr/osc66/blob/f7dd62e695372142f9b5a633f9afbbac369e7e15/src/main.rs#L76-L104
[protocol]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
[presenterm]: ./presenterm.md
[mdfried]: ./mdfried.md
