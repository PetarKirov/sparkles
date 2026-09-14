# wcwidth (Python)

wcwidth treats OSC 66 as visible, measurable text rather than disposable escape
decoration, but its clipping and wrapping paths expose different block models.

| Field             | Value                                                                          |
| ----------------- | ------------------------------------------------------------------------------ |
| Language          | Python                                                                         |
| License           | MIT, with the additional Markus Kuhn permission notice in [`LICENSE`][license] |
| Repository        | [jquast/wcwidth, pinned tree][repository]                                      |
| Documentation     | [README][readme] and [text-sizing module documentation][sizing]                |
| Category          | Unicode and terminal-sequence measurement, clipping, wrapping                  |
| Reviewed revision | `17986f51ddea489b1c83bff85169e4521a8fb080`                                     |
| Revision date     | August 28, 2026, from local Git commit metadata                                |
| Review date       | September 14, 2026                                                             |
| Source provenance | Local clone at the inspected revision                                          |
| Evidence          | Source and test inspection plus read-only Python API reproductions             |

**Last reviewed:** September 14, 2026.

## Overview

### What it solves

The [README][readme] positions the library directly:

> This library is mainly for CLI/TUI programs that carefully produce output for Terminals.

Counting code points is insufficient for terminal layout: combining characters,
wide characters, grapheme clusters, and terminal sequences all disturb that
correspondence. OSC 66 introduces another case: a control sequence can carry
visible text and explicitly assign its occupied width.

The library therefore exposes both ordinary Unicode width functions and a
sequence-aware `width`, alongside `clip`, `wrap`, and `strip_sequences`.
[Blessed][blessed] consumes those facilities rather than reimplementing them.

### Design philosophy

The [`TextSizing` class][sizing] describes its scope precisely:

> Basic horizontal width measurement for kitty text sizing protocol.

That qualifier is important. Parsed scale and alignment metadata are not a
two-dimensional scene model. A useful horizontal estimator can coexist with
missing vertical layout, and correct width arithmetic does not automatically
make a partial text-block rewrite faithful.

Use [concepts][concepts] for advance versus occupancy and [comparison][comparison]
for the distinction between a string utility, terminal renderer, and retained
widget system.

## How it works

[`TEXT_SIZING_PATTERN`][escapes] recognizes the ESC-prefixed form with either BEL
or ESC-backslash termination. Its groups capture metadata, payload, and the
original terminator. Metadata cannot contain semicolon, BEL, or ESC; payload
cannot contain BEL or ESC, but can contain semicolons and other controls.

[`TextSizingParams.from_params`][sizing] parses colon-separated `key=value`
fields into a `NamedTuple`. `TextSizing.from_match` adds the payload and terminator.
`make_sequence()` emits known non-default fields in mapping order, so parsing
and re-emission normalize metadata rather than preserve the original bytes.

The [`width` scanner][width-source] handles OSC 66 before treating ordinary escape
sequences as zero-width. It constructs a `TextSizing`, adds `display_width()` to
the current column, and updates the maximum extent. This makes surrounding
horizontal cursor movement part of the outer measurement without interpreting
the payload as a nested terminal command stream.

The source's complete width decision is compact:

```python
if self.params.width > 0:
    return self.params.scale * self.params.width
w = wcswidth(self.text, ambiguous_width=ambiguous_width)
if w < 0:
    w = 0
return self.params.scale * w
```

This is an inspected excerpt from [`display_width`][sizing], not a substitute
implementation. The executed examples below call the actual pinned package.

## Protocol and API

The [field mapping][sizing] bounds `s` to 1-7, `w` to 0-7, `n` and `d` to 0-15,
and `v` and `h` to 0-2. Defaults are scale one and zero for the other fields.
In ordinary parse mode, numeric values are clamped; unknown keys and malformed
parts are ignored. A non-integer occurrence does not update its field, so an
earlier valid duplicate remains in effect rather than being reset.

With `control_codes='strict'`, missing equals signs, unknown fields, non-integers,
and out-of-range values raise `ValueError`. This is parameter validation, not
an assertion that every payload is printable or the terminal supports OSC 66.
Direct `TextSizingParams(...)` construction bypasses that parser entirely.

Semantic text extraction is deliberately different from generic sequence
iteration. [`strip_sequences`][extraction] first replaces recognized OSC 66 with
its payload, then removes ordinary sequences. By contrast, `iter_sequences`
yields a whole OSC 66 as a sequence token with `is_seq=True`.

That difference is essential for preserving readable content in a plain-text
conversion. It is also a trap for callers that assume discarding every
`is_seq=True` token is equivalent to calling `strip_sequences`: visible OSC 66
payloads disappear under the former algorithm.

## Measurement and geometry

With explicit `w > 0`, width is assigned to the whole payload independently of
its number of graphemes. The [tests][tests] deliberately include `anything` in
`s=2:w=3`, measuring six cells, and an empty payload with positive width.
Without explicit width, ordinary payload width is multiplied by integer scale.

The [module documentation][sizing] states:

> Numerator, denominator, and alignment codes and values are parsed but otherwise ignored
> and have no effect on measurements made in this library.

Fractions therefore do not shrink occupancy. For `s=2:w=3:n=1:d=2`, this revision
returns six cells, not three; the executed check below confirms that arithmetic.
The fraction describes glyph sizing within an allocation, not allocation removal.

`display_width` accepts `ambiguous_width`, but does not forward a terminal-profile
argument to its inner `wcswidth`. Partial auto-width clipping instead calls
`width(grapheme, term_program=...)`. This is a source-level policy asymmetry worth
testing with profile-sensitive graphemes; no such mismatch was reproduced here.

No result includes row count, baseline, vertical alignment offset, or a rectangle.
Even a scale-seven block produces an integer horizontal extent. A consumer that
needs vertical geometry must retain and interpret the parameters independently.

## Capability and fallback

Neither [`TextSizing`][sizing] nor the OSC 66 branch of [`width`][width-source]
queries a terminal. Measurement describes the encoded intent, not proof that a
particular output stream will honor it. The `term_program` width-correction
facility is not OSC 66 negotiation.

`control_codes='ignore'` strips sequences through the semantic extraction path
and measures the payload without its scale or explicit width. The [tests][tests]
assert this distinction for both terminators. It is a useful plain-text metric,
but is not by itself a renderer fallback: callers must also emit plain text.

Likewise, permissive parsing should not be confused with capability fallback.
Clamping an illegal width to seven normalizes the library's model; it does not
establish how a terminal interprets the original unmodified byte string.
For negotiated output, [Blessed][blessed] adds a separate probing layer.

## Layout and clipping

The shared [`_text_sizing_clip` helper][clip-source] preserves a wholly visible
block and advances past a wholly invisible block. For partial overlap, it
decomposes the payload into synthetic units, then emits surviving complete units
inside a newly serialized OSC 66. Partial units become one-cell fill characters.

For automatic width, each unit is a grapheme whose measured width is multiplied
by scale. For explicit width, however, the helper takes at most `w` graphemes,
assigns each exactly `s` cells, and pads missing graphemes with empty units.
It reconstructs `w` from the number of surviving units.

That invents a per-grapheme mapping absent from the whole-block width contract.
Two counterexamples expose the difference:

- `w=2;ABCD` assigns two cells to all four letters, but clipping either half emits only `A` or `B`.
- `w=4;X` assigns four cells to one payload, but clipping its leftmost cell resizes `X` to width one; the remaining three cells become an empty payload.

The actual returned strings for both cases were reproduced below. Whether a
specific terminal paints the original fitted block in a particular pixel pattern
was not tested. The finding is that the rewrite assumes ownership of cells by
graphemes which the input did not supply. An atomic-block clipping policy would
instead preserve only complete blocks or replace partial overlap with fill;
pixel-faithful partial clipping would need renderer support.

Wrapping has a separate inconsistency. [`SequenceTextWrapper._width`][wrap-source]
uses semantic `width`, but `_split` hides OSC 66 payloads inside opaque sequence
tokens. `_strip_sequences` drops them, unlike public `strip_sequences`.
`_find_break_position` skips `ZERO_WIDTH_PATTERN` matches without adding width,
and that generic pattern includes OSC 66. Whole-chunk measurement and long-word
breaking consequently disagree about the same block's width.

The reproduced `wrap(block + 'X', 2)` case returns one line of measured width
three, even though the block itself fits the requested width of two. This is
not merely the unavoidable overflow of a single unsplittable oversized glyph.
There is a valid boundary before `X`, but the break-position scan ignores the
block's two-cell cost.

## Retained state and interaction

The sizing objects retain parameters, payload, and terminator, not a persistent
screen identity. [`clip`][clip-source] has transient cell and style bookkeeping
for its painter path, and [`wrap`][wrap-source] tracks hyperlink state across
lines. Neither is a retained model of a multi-row sized-text block.

There is no sizing-level selection mapping, hit-testing API, baseline alignment,
or damage tracking. A returned clipped string is a newly authored protocol
message, not a view onto an original block with stable source coordinates.
This distinction matters when borrowing the parser for the [Sparkles proposal][proposal].

## Safety and evidence

The [pattern][escapes] excludes ESC and BEL inside matched payloads, but permits
other controls. In auto-width mode, a negative `wcswidth` result becomes zero
for the entire payload. The [tests][tests] explicitly accept an inner `\x01`
with measured width zero even under `control_codes='strict'`. Strict metadata
handling is therefore not a general safe-payload validator.

The direct serializer also accepts whatever text and terminator its object holds;
it does not impose Blessed's 4096-byte guard. Treat it as serialization of trusted
structured input, not a sanitizing boundary for untrusted terminal content.

**Executed evidence, September 14, 2026:** these minimal commands ran from the
Sparkles workspace with Python 3 and the pinned checkout on `PYTHONPATH`.
`PYTHONDONTWRITEBYTECODE=1` prevented bytecode writes; no upstream files changed.
The printed strings use `repr`, so no OSC payload was rendered to the terminal.

For reproduction, set `WCWIDTH_CHECKOUT` to the absolute path of a clean checkout
at the inspected revision. Run outside any other `wcwidth` source directory;
the required variable prevents silently falling back to an installed package.

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${WCWIDTH_CHECKOUT:?Set WCWIDTH_CHECKOUT to the pinned source checkout}" python3 -c 'from wcwidth import width, clip, wrap, strip_sequences; s="\x1b]66;w=2;ABCD\x07"; print(width(s), repr(strip_sequences(s)), repr(clip(s, 0, 1)), repr(clip(s, 1, 2))); print(repr(wrap(s + "X", 2)))'
```

```text
2 'ABCD' '\x1b]66;w=1;A\x07' '\x1b]66;w=1;B\x07'
['\x1b]66;w=2;ABCD\x07X']
```

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="${WCWIDTH_CHECKOUT:?Set WCWIDTH_CHECKOUT to the pinned source checkout}" python3 -c 'from wcwidth import width, clip, wrap; s="\x1b]66;w=4;X\x07"; print(repr(clip(s, 0, 1)), repr(clip(s, 1, 4))); s="\x1b]66;s=2:w=3:n=1:d=2;ABC\x07"; print(width(s)); s="\x1b]66;w=2;ABCD\x07"; print([width(line) for line in wrap(s + "X", 2)])'
```

```text
'\x1b]66;w=1;X\x07' '\x1b]66;w=3;\x07'
6
[3]
```

The [upstream tests][tests] were inspected, not run. They cover parser modes,
round trips with both terminators, fractions, semantic stripping, and clipping
on simple and cursor-movement painter paths. Many clipping expectations encode
the same synthetic-unit policy; passing them would not independently prove it
matches terminal rendering. These commands are manual reproductions, not
CI-registered examples. The [validation plan][validation] separates these levels.

## Strengths

- [Semantic extraction][extraction] preserves visible OSC 66 payloads in plain text.
- [Width arithmetic][sizing] separates fractional glyph size from cell allocation.
- [Strict and permissive parsing][sizing] give callers explicit metadata policy choices.
- [Shared clipping logic][clip-source] handles whole visibility, fill, and both scanner paths.
- [Focused source tests][tests] make parser normalization and clipping assumptions inspectable.

## Weaknesses

- [Explicit-width partial clipping][clip-source] invents a grapheme-to-cell mapping for fitted blocks.
- [Wrapping][wrap-source] combines semantic measurement with zero-width opaque-sequence breaking.
- [Direct construction][sizing] is not a validated safe-payload boundary.
- [Horizontal-only results][sizing] cannot allocate or clip multi-row text correctly on their own.
- [Internal policy reuse][tests] needs terminal or independent block-model evidence, not just round trips.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                        | Trade-off                                                |
| ------------------------------------------- | ------------------------------------------------ | -------------------------------------------------------- |
| Special-case OSC 66 in width and stripping  | It carries visible content                       | Generic sequence consumers still need updating           |
| Ignore fractions for cell count             | Preserve allocation independently of glyph size  | No glyph bounds or alignment geometry returned           |
| Normalize metadata when parsing             | Tolerate malformed input or reject it explicitly | Re-emission is not byte-preserving                       |
| Decompose partial blocks into units         | Reuse cell clipping and fill logic               | Explicit-width mapping is not implied by protocol intent |
| Keep escape sequences opaque while wrapping | Avoid cutting escape syntax                      | Positive-width blocks are skipped by the break scanner   |
| Return strings and scalar widths            | Lightweight composition by callers               | Interaction and vertical layout remain outside the API   |

## Sources

- [Pinned repository][repository], [README][readme], and [license][license]: identity and scope.
- [Text-sizing types and arithmetic][sizing]: parser, serializer, and width rules.
- [Escape patterns][escapes] and [semantic extraction][extraction]: token versus payload handling.
- [Width scanner][width-source], [clipping][clip-source], and [wrapping][wrap-source]: integration paths.
- [Text-sizing tests][tests]: inspected policy examples, not executed suite results.
- [Blessed][blessed], [concepts][concepts], [comparison][comparison], [validation][validation], and [proposal][proposal]: related analysis.

<!-- References -->

[repository]: https://github.com/jquast/wcwidth/tree/17986f51ddea489b1c83bff85169e4521a8fb080
[license]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/LICENSE
[readme]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/README.rst
[sizing]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/text_sizing.py
[escapes]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/escape_sequences.py#L17-L29
[extraction]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/escape_sequences.py#L145-L194
[width-source]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/_width.py
[clip-source]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/_clip.py
[wrap-source]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/textwrap.py
[tests]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/tests/test_text_sizing.py
[blessed]: ./blessed.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
