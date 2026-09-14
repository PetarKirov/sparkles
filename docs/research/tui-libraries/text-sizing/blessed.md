# Blessed (Python)

Blessed exposes terminal text sizing as a capability-gated string formatter,
delegating horizontal measurement and clipping to [wcwidth][wcwidth-study].

| Field             | Value                                                                  |
| ----------------- | ---------------------------------------------------------------------- |
| Language          | Python                                                                 |
| License           | MIT; verified in [`LICENSE`][license]                                  |
| Repository        | [jquast/blessed, pinned tree][repository]                              |
| Documentation     | [Sizing & Alignment][measuring]                                        |
| Category          | Terminal API, capability probing, OSC 66 emission                      |
| Reviewed revision | `e3a30e235f011421db0dba3b409cf942735dd045`                             |
| Revision date     | September 13, 2026, from local Git commit metadata                     |
| Review date       | September 14, 2026                                                     |
| Source provenance | Local clone at the inspected revision                                  |
| Evidence          | Source and test inspection; runtime import blocked by missing `jinxed` |

**Last reviewed:** September 14, 2026.

## Overview

### What it solves

An application wants a heading larger than ordinary terminal text without
embedding protocol bytes throughout its rendering code. Blessed supplies
[`Terminal.text_sized`][formatter], parameter names for alignment, and a
[`Terminal.does_text_sizing`][probe] capability query. The result is still a
Python string, suitable for composition with the library's other output helpers.

The [measurement documentation][measuring] states:

> This means that blessed can measure, right-align, center, truncate, or word-wrap its own output!

This is the useful integration claim to examine, not a claim that every helper
implements a two-dimensional layout model. The same documentation explicitly
describes vertical sequences as ignored by `Terminal.length`.

### Design philosophy

The [`text_sized` docstring][formatter] promises:

> Returns `text` unchanged when the terminal does not support text sizing, providing
> graceful degradation.

That policy makes unsupported output readable. It does not preserve the sized
run's requested occupancy: plain text and scaled text can need different space.
The application must therefore decide fallback before final layout, rather than
substitute the plain string after allocating a scaled rectangle.

See [concepts][concepts] for the distinction between payload, advance, occupancy,
and glyph size; [comparison][comparison] places this convenience layer beside
protocol implementations and retained UI toolkits.

## How it works

The [`text_sized` implementation][formatter] follows this order:

1. Encode the payload as UTF-8 and reject lengths above 4096 bytes.
2. Reject a payload containing the ESC character.
3. Validate integer alignment codes or translate named alignments.
4. Clear alignment unless `0 < numerator < denominator`.
5. Construct `TextSizingParams` directly from the supplied values.
6. Test the truth value of `does_text_sizing()`.
7. Return plain text if false, otherwise serialize `TextSizing` with BEL termination.

The final operation is a call into [wcwidth's serializer][sizing-source], not a
second Blessed-owned encoder. Non-default metadata fields are colon-separated;
default values disappear from the serialized parameter list.

The [probe][probe] performs three cursor-position queries: a starting position,
one after a width probe, and one after a scale probe. Its two emitted payloads
are exactly these source literals:

```python
'\x1b]66;w=2; \x07'
'\x1b]66;s=2; \x07'
```

These are inspected source excerpts, not commands executed against a terminal.
Each successful feature test requires a horizontal delta of two columns.
The result stores separate `width` and `scale` booleans, then normal completion
overwrites the probe area with ordinary spaces and caches the result.

## Protocol and API

[`text_sized`][formatter] accepts positional `text` and `scale`; width, fractional
numerator and denominator, and both alignments are keyword-only. Documented ranges
are scale 1-7, width 0-7, fraction components 0-15, and alignment 0-2.
Width zero asks the terminal to derive width from the payload.

Vertical names map `top`, `bottom`, and `center` to 0, 1, and 2. Horizontal names
map `left`, `right`, and `center` likewise; both accept `default` as zero.
Integer alignment bounds are checked even if the later fractional-scaling rule
will discard those alignments. Validation also occurs before unsupported-terminal
fallback, so fallback does not bypass payload or alignment errors.

The important asymmetry is that scale, width, numerator, and denominator have
documented ranges but no corresponding range checks here. Direct construction of
[`TextSizingParams`][sizing-source] does not call `from_params`, the parser which
would clamp values or reject them in strict mode.

Despite a tempting "dataclass validation" analogy, this dependency type is
actually a `typing.NamedTuple`. Neither its type annotations nor
`make_sequence()` enforce those numeric ranges. Static inspection therefore
predicts out-of-range metadata can be emitted when capability gating succeeds;
this review did not execute that Blessed call.

## Measurement and geometry

[`Terminal.length`][length] directly calls `wcwidth_width(text)`. For OSC 66,
[wcwidth][sizing-source] returns `scale * width` for positive explicit width,
otherwise `scale * wcswidth(payload)` with a negative payload width replaced by
zero. Fractional parameters and alignment do not shrink that cell count.

This separation is valuable: a smaller glyph inside a reserved cell region is
not a smaller allocation. However, the scalar returned by `length` cannot tell
a caller which rows are occupied or where a baseline lies.

The [probe][probe] is also horizontal-only evidence. It discards the row from
all three cursor reports with `_, col = ...`. A two-column advance after `s=2`
is treated as scale support; it does not independently establish doubled height,
fractional scaling, alignment, or clipping behavior.

The ordinary `Terminal.height` and `Terminal.width` properties describe the
window in cells, as documented in [Sizing & Alignment][measuring]. They do not
turn a formatted text run into a height-bearing layout object. A caller needs
its own reservation for rows below a scaled heading and must not infer that
reservation from a plain width result.

## Capability and fallback

[`TextSizingResult.__bool__`][capabilities] is exactly:

```python
return self.width or self.scale
```

The formatter uses this aggregate truth value rather than checking the feature
requested by its arguments. Thus a width-only result permits a scale request,
and a scale-only result permits an explicit-width request. This is a static
policy mismatch, not a demonstrated failure on a named emulator. Applications
can inspect the two fields themselves before choosing a representation.

The [probe][probe] returns a false result immediately when either the stream is
not a TTY or styling is disabled. A cached result is reused unless `force=True`.
On a fully completed probe, even a negative result is cached. Initial or later
cursor-query timeouts return without populating the cache.

Consequently the docstring's permanently cached behavior has an important
qualification: an unsuccessful query attempt can be repeated by subsequent
formatting calls. The `timeout` is per cursor query, not one total deadline for
the entire three-query operation.

The first formatter call may perform terminal I/O before returning its string.
Blessed explicitly recommends probing during initialization because the spaces
are destructive. This is good documentation of a non-pure API boundary; a host
that owns one event loop should schedule such negotiation deliberately.

## Layout and clipping

[`Terminal.truncate`][formatter] constructs a `Sequence`, whose
[`truncate` implementation][sequences] expands terminal-specific horizontal
movement through `padd()` and delegates to `wcwidth.clip`.
[`Terminal.wrap`][wrap] delegates each logical input line to `wcwidth.wrap`.
The integration is reuse, not an independent geometry oracle.

That matters for explicit-width blocks: the [wcwidth study][wcwidth-study]
demonstrates that partial clipping assigns individual graphemes to explicit
cells even when the whole payload was fitted into one block. It also records
an executed wrapping case whose returned line exceeds its requested width.
Those are observations of the pinned wcwidth dependency studied here, not
executed Blessed integration tests.

Nothing in `text_sized` reserves a widget rectangle, moves subsequent text down
by the run's height, or produces a vertical clipping region. Fractional alignment
changes protocol metadata; it is not alignment of a child in a Blessed layout
tree. The distinction is central to the [Sparkles proposal][proposal].

## Retained state and interaction

The relevant retained state is `_text_sizing_cache`, an attribute on `Terminal`.
It records capability results, not a display list, shaped run, source-to-cell
mapping, or dirty rectangle. `force=True` refreshes detection, but does not
reflow or repaint previously emitted strings.

The sizing API returns no logical identity for a block. There is no sizing-level
hit-test result, selection range, or cursor navigation map in these methods.
A client implementing interactive sized text must retain payload and geometry
separately from the serialized string.

Likewise, repainting a multi-row run needs an application-level invalidation
policy. The probe's own cleanup comment notes that a scaled space can obscure
text on the next row; this is direct source evidence that horizontal advance
alone is not enough to describe the visible effect.

## Safety and evidence

**Payload safety is narrower than the error message.** The [formatter][formatter]
says text must not contain control codes or terminal sequences, but the actual
predicate is `text.find('\x1b')`. BEL, newline, carriage return, and other non-ESC
controls are not rejected by this predicate. BEL is especially significant:
it is the OSC terminator that this very encoder uses, so an embedded BEL can end
the payload early and leave the remainder outside the intended sized block.

This is a static framing risk, not an executed exploit or an emulator conformance
result. Even the unsupported fallback returns the original control-bearing
text, rather than sanitizing it. The UTF-8 byte limit is a real guard, but it is
not a complete safe-payload contract.

**Probe restoration is best-effort.** The [normal cleanup][probe] computes
`max(0, col2 - col0)` and writes that many backspaces, spaces, and backspaces.
Discarding rows means a right-margin wrap invalidates the same-row subtraction;
the function does not move to a reserved probe position first. A timeout after
either write returns before cleanup, and cleanup is not protected by `finally`.
These are source-derived risks of residue and cursor displacement. No live
right-margin or timeout experiment was performed in this review.

The [formatter tests][formatter-tests] inspect named and integer alignments,
fraction-dependent omission, fallback, ESC rejection, and the 4096-byte boundary.
The [autoresponse tests][probe-tests] cover both capabilities, width-only support,
negative detection, all three timeout stages, caching, and cleanup output.
Their supplied reports and mocked locations test implementation behavior; they
do not establish real terminal occupancy or restoration at a wrapped margin.

> [!NOTE]
> These upstream test files were inspected, not run. A read-only Python import
> attempt with `PYTHONDONTWRITEBYTECODE=1` and both pinned checkout roots on
> `PYTHONPATH` failed with `ModuleNotFoundError: No module named 'jinxed'` before
> any Blessed reproduction could execute. No upstream files were changed.

The [validation plan][validation] should keep byte-level encoder checks separate
from terminal response, geometry, and cleanup experiments. A D baseline check
would be complementary evidence, not proof that this Python API was exercised.

## Strengths

- [Named parameters and alignments][formatter] make OSC 66 accessible without hand-built escapes.
- [Separate capability fields][capabilities] expose more information than a single support flag.
- [Plain-text fallback][formatter] preserves readable content when sizing is unavailable.
- [Shared measurement helpers][length] avoid a second Blessed-owned Unicode-width implementation.
- [Probe documentation and tests][probe-tests] make destructive detection and caching visible.

## Weaknesses

- [ESC-only validation][formatter] leaves BEL framing and other control-code holes.
- [Direct parameter construction][sizing-source] bypasses numeric range validation.
- [OR-based gating][capabilities] does not verify the specific requested sizing feature.
- [Column-only probing][probe] cannot establish vertical geometry and has cleanup gaps.
- [Delegated clipping and wrapping][wcwidth-study] inherit assumptions that need independent oracles.

## Key design decisions and trade-offs

| Decision                       | Rationale                                                     | Trade-off                                               |
| ------------------------------ | ------------------------------------------------------------- | ------------------------------------------------------- |
| Return a formatted string      | Compose with existing terminal helpers                        | No retained occupancy or hit-test identity              |
| Probe using cursor deltas      | Observe behavior instead of guessing from terminal names      | Destructive I/O and row-sensitive cleanup               |
| Cache completed detection      | Avoid repeated terminal round trips                           | Requires explicit refresh after environment changes     |
| Gate on width OR scale         | Simple aggregate support check                                | Requested feature may remain unsupported                |
| Clear non-fractional alignment | Avoid meaningless alignment metadata and documented artifacts | Caller intent is normalized before serialization        |
| Delegate to wcwidth            | Share parsing and Unicode measurement                         | Dependency clipping policy becomes application behavior |

## Sources

- [Pinned repository][repository] and [license][license]: identity and redistribution terms.
- [Sizing & Alignment][measuring]: public measurement claims and limitations.
- [Formatter][formatter], [probe][probe], and [capability result][capabilities]: actual API policy.
- [Length][length], [wrapping][wrap], and [sequence truncation][sequences]: dependency integration.
- [wcwidth text-sizing types][sizing-source]: serialization and direct-construction behavior.
- [Formatter tests][formatter-tests] and [autoresponse tests][probe-tests]: inspected, not executed.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and [proposal][proposal]: synthesis.

<!-- References -->

[repository]: https://github.com/jquast/blessed/tree/e3a30e235f011421db0dba3b409cf942735dd045
[license]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/LICENSE
[measuring]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/docs/measuring.rst
[formatter]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/terminal.py#L3729-L3837
[probe]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/terminal.py#L2522-L2572
[capabilities]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/_capabilities.py#L808-L829
[length]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/terminal.py#L3839-L3862
[wrap]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/terminal.py#L3943-L3969
[sequences]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/blessed/sequences.py#L204-L225
[sizing-source]: https://github.com/jquast/wcwidth/blob/17986f51ddea489b1c83bff85169e4521a8fb080/wcwidth/text_sizing.py
[formatter-tests]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/tests/test_text_sizing.py
[probe-tests]: https://github.com/jquast/blessed/blob/e3a30e235f011421db0dba3b409cf942735dd045/tests/test_autoresponses.py#L414-L568
[wcwidth-study]: ./wcwidth.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
