# OpenTUI (Zig / TypeScript)

Production explicit-width emission, unused scale detection, and a documented
upstream history show why capability discovery and grapheme ownership are part
of text sizing rather than peripheral terminal compatibility work.

**Last reviewed:** September 14, 2026.

| Field              | Value                                                                                |
| ------------------ | ------------------------------------------------------------------------------------ |
| Language           | Zig native core; TypeScript, React, and Solid application surfaces                   |
| License            | MIT, copyright 2025 opentui; verified in [LICENSE][license]                          |
| Repository         | [anomalyco/opentui][repo]                                                            |
| Documentation      | [Pinned README][readme] and [official documentation][docs]                           |
| Category           | Retained terminal UI with flexbox layout and native cell rendering                   |
| Revision inspected | `ac753b48d386707a931dcf881d0741905b64b4f9`                                           |
| Native source root | `packages/native/src`, not historical `packages/core/src/zig`                        |
| Production sizing  | OSC 66 explicit width; `scaled_text` detected/exported but not consumed by rendering |
| Evidence level     | Local source inspection plus read-only GitHub issue/PR inspection                    |

## Overview

### What it solves

OpenTUI connects application-level boxes, text, inputs, and scrolling to a native
renderer. For this survey its important problem is reconciling a retained cell
buffer's chosen grapheme widths with terminal behavior. If those disagree, later
text, cursor placement, and damage tracking can all drift.

OSC 66 explicit width makes the terminal use the renderer's chosen advance for
selected grapheme output. It does not, by itself, provide larger headings,
fractional font sizes, or multi-row glyph allocation. The inspected renderer
consumes `explicit_width`; `scaled_text` appears in discovery, tests, and the
exported capability structure, but not as a production scaling decision.

This is a deliberately narrower classification than "supports the text-sizing
protocol". The [concepts][concepts] distinguish forced advance from visual scale;
the [libvaxis study][libvaxis] demonstrates an implementation that actually emits
scale parameters. Both are relevant precedents, but they establish different things.

### Design philosophy

The [README][readme] states, verbatim:

> OpenTUI is a library to build terminal user interfaces.

Its application model is summarized by another exact README statement:

> You arrange boxes and text with flexbox.

The resulting separation is useful: application layout produces cell geometry,
while native rendering translates it into terminal operations. Explicit width
belongs at that translation boundary, where a chosen advance is already known.
Visual scale would also have to participate earlier in measurement and layout.

The README identifies `@opentui/native` as the private workspace containing Zig
implementation, tests, and benchmarks. Historical issue bodies cite the former
native location. All source citations below use the current pinned paths rather
than copying those obsolete paths into new full-SHA links.

## How it works

The inspected source path separates discovery, buffer geometry, and emission:

1. [`Terminal.queryTerminalSend`][terminal] sends cursor and capability queries.
2. `processCapabilityResponse` attributes ordered reports to the width probes.
3. [`grapheme.zig`][grapheme] encodes pooled grapheme starts and continuation extents.
4. [`renderer.zig`][renderer] obtains the chosen width from the encoded right extent.
5. [`ANSI.explicitWidthOutput`][ansi] wraps the grapheme when the capability is enabled.
6. The renderer synchronizes the current buffer for the next incremental frame.

The production encoder is this exact excerpt from [`ansi.zig`][ansi]:

```zig
pub fn explicitWidthOutput(writer: anytype, width: u32, text: []const u8) AnsiError!void {
    writer.print("\x1b]66;w={d};{s}\x1b\\", .{ width, text }) catch return AnsiError.WriteFailed;
}
```

There is no `s`, `n`, `d`, or alignment parameter in this function. The same file
defines `scaledTextQuery` with `s=2`, but that is a discovery probe, not evidence
that application text is emitted at scale 2. Capability inventory and feature
implementation must be audited separately.

In the ordinary diff branch, pooled grapheme bytes come from `self.pool.get(gid)`;
`gp.charRightExtent(cell.char) + 1` supplies `graphemeWidth`. With explicit width
disabled, the renderer writes the bytes directly and can reposition the cursor
to the expected next cell. Continuation cells themselves emit no glyph bytes.

The current renderer has three `explicitWidthOutput` call sites, including text
replay associated with image rendering. Older issue descriptions refer to two.
That count drift is a concrete reason to inspect the pinned tree rather than
treat an older proposed patch as an exhaustive map of the current implementation.

## Protocol and API

[`Terminal.Capabilities`][terminal] defaults `explicit_width` and `scaled_text`
to false. [`lib.zig`][ffi] exports both capability fields across the native API.
This exposes observed terminal support without proving that every exported
capability has a corresponding public renderable feature.

Production OSC 66 output is a width instruction attached to a pooled grapheme,
not an arbitrary styled run and not a font-size property. The renderer's ordinary
ASCII/codepoint branches do not all pass through this wrapper. "Every character
is wrapped" would be an inaccurate summary of the inspected dispatch.

The allocation width and the semantic kind of the payload are independent.
Kitty Unicode image placeholders can arrive through the same grapheme path as
ordinary text, yet their terminal interpretation depends on remaining ordinary
placeholder cells. [Issue #1300][issue1300] and [PR #1301][pr1301] address that
specific conflict, not general absence of native image support.

The inspected renderer also contains a distinct `CHAR_FLAG_IMAGE` path and image
placement/replay logic. Do not conflate native image objects with an application
supplying U+10EEEE as text. The latter is precisely the inter-protocol boundary
that the still-open placeholder report describes.

## Measurement and geometry

The [grapheme representation][grapheme] packs start and continuation tags with
left/right extents. Each extent is two bits; `packGraphemeStart` caps the stored
right extent rather than assuming every logical grapheme fits indefinitely.
The source comment explicitly notes that `wcwidth` clusters such as ZWJ families
can have a wider logical display width than the four-cell encoded span.

This is a representation boundary, not a general claim that all text measurement
is capped at four columns. [`text-buffer.zig`][textbuffer] owns text measurement,
and [`text-buffer-view.zig`][view] owns wrapping/view geometry. The packed screen
cell and the logical text model answer different questions.

| Quantity                  | Inspected owner                         | Relevance to sizing                               |
| ------------------------- | --------------------------------------- | ------------------------------------------------- |
| Text width policy         | `Terminal` Unicode capability/overrides | Selects the interpretation used for graphemes     |
| Logical text measurement  | `TextBuffer`                            | Supplies widths before terminal serialization     |
| Viewport and wrapping     | `TextBufferView`                        | Maps text to visible lines/cells                  |
| Encoded screen span       | Grapheme start/continuation extents     | Drives retained buffer ownership and output width |
| Explicit terminal advance | `ANSI.explicitWidthOutput`              | Requests agreement with the encoded width         |
| Multi-row visual scale    | No consuming renderer path found        | Discovery alone supplies no geometry contract     |

A Sparkles design should name these quantities separately. Multiplying the
encoder's `w` cannot substitute for changing measurement, row allocation, and
selection mapping. Likewise, blindly enlarging a compact extent field does not
define what happens when a new footprint intersects an existing one.

## Capability and fallback

The [current query block][terminal] sets
`explicit_width_probe_reports_pending = 2`, sends a home/width-space/DSR sequence,
then a home/scaled-space/DSR sequence. The response handler consumes the startup
cursor report separately through an `if`/`else if` structure.

For the first pending probe it requires row 1, column 2. For the second it requires
row 1, column 3; that reply enables both explicit width and scaled text. Larger
columns are not stronger evidence. They can be evidence that unsupported control
payload was printed literally, which was the central false-positive mechanism
reported in [issue #1383][issue1383].

The accepted fix is [PR #1384][pr1384], merged August 23, 2026. It uses the bounded
two-report counter visible in the pinned source. The more general FIFO proposal
in [PR #1385][pr1385] was closed without merge. Its design is relevant research,
but attributing that implementation to current OpenTUI would be incorrect.

[`OPENTUI_FORCE_EXPLICIT_WIDTH` handling][terminal] recognizes `true`/`1` and
`false`/`0`. The false branch disables explicit width and sets
`skip_explicit_width_query`, suppressing both OSC 66 probes. Arbitrary strings
such as `off` do not select that branch. Force-on enables width without promising
that a terminal really implements it.

[PR #605][pr605], merged February 2, 2026, introduced the compatibility opt-out
for older terminals displaying query artifacts. Suppressing only production
output is insufficient if the probe itself is visibly harmful. The native code
now reads an environment map; historical reports recommend setting the override
before process start rather than assuming a JS environment mutation reaches it.

The ordinary fallback writes grapheme bytes and may explicitly reposition the
cursor. This preserves a cell-layout strategy without requiring OSC 66. It does
not manufacture missing terminal glyph support, nor establish that all complex
clusters will look identical across terminals.

## Layout and clipping

The retained buffer's start/continuation representation already treats wide text
as more than independent character cells. [`buffer.zig`][buffer] draws text views
with selection support; the [renderer][renderer] skips continuation output and
synchronizes changed cells without ordinary span cleanup during the diff pass.
These are foundational responsibilities for any later multi-row scaling design.

[PR #791][pr791], still open at review, proposes span-preserving translucent
overlays: preserve wide non-emoji text under fills, substitute `[]` for certain
emoji-like spans, and use clipped perimeter handling for box edges. It also
discusses buffered ancestors and stale tint. Those are proposal claims, not
merged guarantees of the pinned implementation.

The design problem is transferable even without adopting that patch: clipping
or tinting one cell of a multi-cell glyph cannot always be modeled as independent
cell replacement. A layout can be geometrically valid while a compositing step
destroys the glyph whose ownership crosses its boundary.

The open [placeholder fix][pr1301] offers a different exception: do not wrap
graphemes beginning with U+10EEEE, including those carrying placement diacritics.
The report's terminal captures belong to its author; this review did not repeat
them. Inspection does confirm unconditional wrapping within the current pooled
grapheme branches when explicit width is enabled.

## Retained state and interaction

The ordinary renderer calls `currentRenderBuffer.syncCell` after output. Its
comment explains why normal span cleanup is inappropriate during a left-to-right
diff: it would destroy continuation cells written by an earlier iteration.
Thus synchronization order is part of rendering correctness, not bookkeeping.

[PR #876][pr876], closed without merge, proposes clearing stale continuation
cells before synchronizing a wide start, and only on the non-OSC-66 path. The
reported scenario replaces narrow text with a wider grapheme, after which
premature continuation synchronization can hide still-visible terminal content
from the diff. This is a useful test case, not evidence that this patch landed.

The [text view][view] and [editor view][editor] keep selection and viewport state
in the text subsystem. A future scale API would need an explicit mapping from
pointer cells and visual cursor positions back to logical text. Detecting
`scaled_text` supplies none of that mapping by itself.

The lesson for the [Sparkles proposal][proposal] is to retain placement ownership
and invalidate old and new footprints before committing a new terminal image.
Test incremental rendering against a fresh full repaint, especially across
width changes, overlays, clipping boundaries, and backend fallback transitions.

## Safety and evidence

The source and upstream states were inspected on September 14, 2026. GitHub
issue/PR pages are mutable evidence; their status below is dated, unlike the
full-SHA source citations. No upstream test suite, PTY reproduction, or real
terminal experiment was run for this page.

| Upstream item                        | State at review            | What it establishes                                            |
| ------------------------------------ | -------------------------- | -------------------------------------------------------------- |
| [#605][pr605]                        | Merged February 2, 2026    | Query-suppressing explicit-width opt-out accepted              |
| [#1383][issue1383]                   | Closed issue               | Historical false-positive report, not current handler behavior |
| [#1384][pr1384]                      | Merged August 23, 2026     | Exact ordered probe response checks accepted                   |
| [#1300][issue1300] / [#1301][pr1301] | Open issue / open PR       | Placeholder incompatibility report and proposed exclusion      |
| [#791][pr791]                        | Open PR                    | Proposed span-aware translucent overlay handling               |
| [#1385][pr1385]                      | Closed, unmerged           | General cursor-request FIFO alternative, not shipped mechanism |
| [#1430][pr1430]                      | Closed, unmerged           | Outstanding-probe registry proposal, not current API contract  |
| [#876][pr876]                        | Closed, unmerged           | Continuation-clearing proposal and historical reproduction     |
| [#1406][pr1406]                      | Closed, unmerged; disputed | Ghostty blacklist proposal, not established diagnosis          |

[#1430][pr1430] argues for making capability mutation depend on an outstanding
probe registry rather than response shape. Its modified-F3 scenario was written
against earlier permissive detection. The current exact-column/count checks
must be accounted for before claiming that scenario still reproduces. The
general provenance principle remains useful without reviving an obsolete bug claim.

[#1406][pr1406] proposed disabling OSC 66 after identifying Ghostty. A maintainer
[explicitly disputed the diagnosis and regression][ghostty-dispute]. This survey
does not adopt the PR's terminal-support claim or recommend its blacklist.
Conflicting upstream testimony is a reason to seek independent terminal evidence,
not to turn an unmerged workaround into a compatibility rule.

The [native tests][terminaltests] contain startup-report separation, exact ordered
probe acceptance, and echoed-payload rejection cases. Reading those tests is
evidence of intended coverage, not a passing test result from this review.
The [validation plan][validation] should add lost/reordered replies, colliding
input during discovery, opt-out behavior, and full-versus-incremental frame oracles.

## Strengths

- Explicit-width output has a concrete production consumer and ordinary-text fallback.
- Current detection correlates two probes and requires exact expected geometry.
- The opt-out suppresses potentially harmful queries as well as width emission.
- Grapheme extents and continuations make multi-cell ownership inspectable.
- Upstream reports expose distinct discovery, serialization, and damage problems.

## Weaknesses

- `scaled_text` discovery/export is not a user-facing visual scaling implementation.
- Pooled text wrapping does not distinguish Unicode image placeholders at the inspected sites.
- Compact span geometry must not be mistaken for unrestricted logical text width.
- Overlay and continuation proposals cannot be cited as merged correctness guarantees.
- Mutable reports and disputed terminal diagnoses need independent reproduction.

## Key design decisions and trade-offs

| Decision                          | Rationale                                  | Trade-off                                                  |
| --------------------------------- | ------------------------------------------ | ---------------------------------------------------------- |
| Enforce width at native emission  | Align terminal advance with retained cells | Payload semantics can conflict with other protocols        |
| Export detected scale support     | Preserve capability information            | Consumers can mistake detection for implemented typography |
| Count the two width-probe replies | Small, targeted correlation fix            | Not a general outstanding-request registry                 |
| Require exact cursor geometry     | Reject echoed payload false positives      | Missing or ambiguous replies still need an evidence policy |
| Suppress probes on force-off      | Avoid artifacts even during startup        | Override must reach the native environment configuration   |
| Encode start/continuation extents | Compact multi-cell representation          | Damage and clipping must honor the whole span              |

The [comparison][comparison] should record explicit-width production support,
unused scale detection, and the current probe fix separately. Combining them into
one feature checkmark loses the most useful engineering evidence.

## Sources

- [README][readme] and [LICENSE][license]: metadata and verified quotations.
- [`terminal.zig`][terminal], [`ansi.zig`][ansi], and [`lib.zig`][ffi]: probing and API boundary.
- [`renderer.zig`][renderer], [`grapheme.zig`][grapheme], and [`buffer.zig`][buffer]: output and spans.
- [Text buffer][textbuffer], [text view][view], [editor view][editor], and [native tests][terminaltests].
- The dated upstream-state table above distinguishes accepted fixes from proposals.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and [Sparkles proposal][proposal].

<!-- References -->

[repo]: https://github.com/anomalyco/opentui
[docs]: https://opentui.com/docs
[readme]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/README.md
[license]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/LICENSE
[terminal]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/terminal.zig
[ansi]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/ansi.zig
[ffi]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/lib.zig
[renderer]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/renderer.zig
[grapheme]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/grapheme.zig
[buffer]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/buffer.zig
[textbuffer]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/text-buffer.zig
[view]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/text-buffer-view.zig
[editor]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/editor-view.zig
[terminaltests]: https://github.com/anomalyco/opentui/blob/ac753b48d386707a931dcf881d0741905b64b4f9/packages/native/src/tests/terminal_test.zig
[pr605]: https://github.com/anomalyco/opentui/pull/605
[issue1383]: https://github.com/anomalyco/opentui/issues/1383
[pr1384]: https://github.com/anomalyco/opentui/pull/1384
[issue1300]: https://github.com/anomalyco/opentui/issues/1300
[pr1301]: https://github.com/anomalyco/opentui/pull/1301
[pr791]: https://github.com/anomalyco/opentui/pull/791
[pr1385]: https://github.com/anomalyco/opentui/pull/1385
[pr1430]: https://github.com/anomalyco/opentui/pull/1430
[pr876]: https://github.com/anomalyco/opentui/pull/876
[pr1406]: https://github.com/anomalyco/opentui/pull/1406
[ghostty-dispute]: https://github.com/anomalyco/opentui/pull/1406#issuecomment-5384302025
[libvaxis]: ./libvaxis.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
