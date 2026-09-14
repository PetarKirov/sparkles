# foot (C / Wayland)

foot implements the width-only subset of OSC 66 by reusing composed-character storage, deliberately excluding font scaling and multiline characters.

| Field              | Value                                                                        |
| ------------------ | ---------------------------------------------------------------------------- |
| Language           | C; Wayland terminal with `fcft` text rasterization                           |
| License            | MIT, verified in [`LICENSE`][license]                                        |
| Repository         | [dnkl/foot][repo]                                                            |
| Documentation      | [Pinned README][readme] and [changelog][changelog]                           |
| Category           | Width-only terminal implementation                                           |
| Inspected revision | `2705e36f0ecf3ef50c13b41165de852f134859d6`                                   |
| Revision date      | September 10, 2026                                                           |
| Width support      | PR 1927 manually merged February 6, 2025; listed in the 1.21.0 changelog     |
| Evidence           | Source and upstream issue inspection; no terminal or upstream tests executed |

**Last reviewed:** September 14, 2026

## Overview

### What it solves

foot accepts an application-assigned number of columns for a text payload.
This addresses disagreement about Unicode or private-use character widths
without requiring multiple font sizes or objects spanning several rows.
The distinction is intentional: the [changelog][changelog] describes support
as `w`, width, only, and the [handler][osc] implements that subset.

The protocol remains useful in this reduced form. A terminal application can
reserve a known number of columns for an emoji or icon without predicting
foot's grapheme-width policy. It does not gain superscripts, headline scale,
or a general text-fitting engine. See [concepts][concepts] for the distinction
between cell allocation and glyph ink, and [comparison][comparison] for the
cross-terminal capability matrix.

### Design philosophy

The [README][readme] positions foot with this verified verbatim sentence:

> The fast, lightweight and minimalistic Wayland terminal emulator.

The sizing boundary is not merely an inference from that positioning. In
[issue 2252][scope-issue], the maintainer states:

> Foot already implements the width-part of the protocol. The scaling part is out of scope for foot.

That issue was closed on January 3, 2026. A later comment points to the merged
implementation and the specification's express permission for width-only
support. Closed here means the requested scaling is outside scope, not that
full text sizing was delivered.

## How it works

[`osc_dispatch`][osc] routes command 66 to `kitty_text_size`. The handler
splits metadata from text at the first semicolon, rejects absent or empty
text, converts it to `char32_t`, and scans colon-separated parameters.
Only `w` changes the requested geometry.

When `w=0`, the handler passes each decoded code point to
`term_process_and_print_non_ascii`. Its own comment explains that ordinary
processing is sufficient because no other text-sizing parameters are supported
([handler][osc]).

When `w` is nonzero, the entire payload becomes a composed character. The
handler computes a key, performs a collision-aware lookup including forced
width, and either reuses an entry or records the text and width in a new
[`struct composed`][composed]. It then calls [`term_print`][terminal] with
the composed-character identifier and the requested width.

The ordinary print path stores the identifier in the first cell and emits
`CELL_SPACER` continuation cells. This reuses existing multi-column machinery
instead of introducing Kitty-style vertical multicell offsets. The
[implementation PR][pr] explicitly identifies that reuse as its main refactoring.

```text
OSC 66 ; w=3 ; abc ST
  -> one composed-character entry containing abc
  -> one leading cell plus two spacer cells
  -> three-column allocation, one row, no font scaling
```

This is explanatory notation, not an executed terminal trace.

## Protocol and API

The [handler][osc] accepts `w` values up to seven through `strtoul`, checks
conversion errors and trailing input, and ignores invalid values with a log
message. Malformed parameter tokens are skipped. `s`, `n`, `d`, and `v` have
explicit unsupported-parameter warnings; `h` has no action in the switch.
None of these keys enables scaling or alignment.

This parser is tolerant rather than a canonical grammar validator. Repeated
valid `w` parameters replace the previously selected width. Its use of C
numeric conversion is not a specification of the strings a portable encoder
should emit. A strict producer should use one valid decimal value, known keys,
and bounded safe UTF-8, rather than exploit accepted variants.

`w=0` does not mean zero occupied columns. It asks for ordinary processing,
including whatever segmentation and width rules foot normally uses. Nonzero
`w` applies to **all text in the payload**, not separately to each code point
([handler][osc], [protocol][spec]).

The [PR discussion][pr] uses a six-character ASCII payload assigned six columns
to illustrate the consequence: it behaves as one six-column character for
overwrite and reflow purposes. Grouping an entire word is therefore not a
semantically neutral compression of six independent characters.

## Measurement and geometry

The handler calculates both the sum and maximum of code-point widths, then
selects among `GRAPHEME_WIDTH_WCSWIDTH`, `GRAPHEME_WIDTH_MAX`, and
`GRAPHEME_WIDTH_DOUBLE`. In the explicit-width path, the assigned width wins
over that calculation; for `w=0`, execution has already returned through the
ordinary text path ([handler][osc]).

[`struct composed`][composed] distinguishes `width` from `forced_width`.
Keeping the override separate matters when additional combining code points
arrive later: ordinary recomputation must not silently replace the client's
allocation. The combining path preserves an existing forced width and uses
it when deciding occupied columns ([terminal implementation][terminal]).

The [renderer][render] also chooses the forced allocation when available.
With grapheme shaping enabled and available, it invokes
`fcft_rasterize_grapheme_utf32`; otherwise it follows character rasterization
and combining-character rendering paths. An explicit width is consequently
not a promise of identical shaping under all configurations.

On the shaped path, the renderer limits the number of emitted glyphs to the
forced width. That is not a proportional scale-to-fit operation, nor does it
prove that glyph pixels stay inside the allocated cells. Occupancy, glyph
count, glyph advance, and ink bounds remain different measurements
([renderer][render]).

The protocol's **4096-byte payload ceiling** is a transport requirement,
not a promise about arbitrary composed-text storage. `kitty_text_size` has
no local 4096-byte check; `struct composed.count` is an eight-bit field.
These observations require separate boundary tests, not a claim that every
protocol-valid payload is retained losslessly ([handler][osc], [storage][composed]).
Kitty's separate 24-code-point cap is not foot's limit ([Kitty study][kitty]).

## Capability and fallback

foot is evidence that width and scale need separate capability states.
The [protocol][spec] explicitly permits width-only implementation, and
[issue 2252][scope-issue] confirms that this is foot's maintained scope.
Do not equate recognition of OSC 66 with support for `s`, `n`, or `d`.

The [specified probe][spec] compares cursor positions around an explicit-width
space and then a scaled space. On a width-only implementation, the first
request can demonstrate the override while the second cannot demonstrate
two-column scaling. Because foot processes unsupported-scale text normally
when `w=0`, that second space can still advance by one ordinary column.
Detection must test the expected displacement, not merely whether it changed.

That is a source-derived prediction, not a probe executed in this survey.
Session setup must also account for wrapping, screen damage, delayed replies,
and terminal multiplexers. The [validation plan][validation] should test the
partial-support case explicitly.

For a scalable heading, fallback means ordinary-sized layout and output,
not simply sending `s=2` and keeping a two-row allocation in the application.
For a width-sensitive icon, `w` remains useful independently. The
[Sparkles proposal][proposal] should preserve that distinction at the capability
and layout boundaries.

## Layout and clipping

[`term_print`][terminal] performs normal line-wrap processing, insertion,
cell writes, and cursor advancement. With automatic margins enabled, a
multi-column object that exceeds the remaining columns causes padding with
spacers and a wrap before placement. The allocation is still one row tall.
Kitty's lower-row skipping rules therefore have no counterpart to apply here.

The [PR][pr] records a reflow concern about objects wider than the window and
a temporary minimum-width adjustment during development. That historical
TODO is not asserted here as the current minimum window width. It is evidence
that widening the range of atomic objects affects reflow assumptions even
without vertical scaling.

Current rendering explicitly separates cell width from render width.
When `tweak.overflowing_glyphs` is enabled and another column exists, glyph
ink may extend rightward beyond the assigned cells, up to one additional
cell's width. The renderer marks affected cells unconfined for later cleanup
and installs a Pixman clip using that render width and one cell's height
([renderer][render]).

Thus a correct cursor displacement does not establish strict clipping.
Forcing a wide-looking glyph into one cell can preserve the application grid
while ink overlaps subsequent text. The [PR's variation-selector discussion][pr]
documents precisely that distinction.

[Issue 2015][bleeding-issue], **open** at review time, proposes removing font
bleeding to reduce complexity and improve rendering performance. It discusses
private-use glyphs, italic overhang, and explicit width as an alternative for
icons. Subsequent comments report that many commonly used fonts bleed.
This is an unresolved design discussion, not a landed removal or a benchmark
result established by this survey.

## Retained state and interaction

The composed table retains decoded text, its key, computed width, and forced
width; the screen retains an identifier plus spacer cells. Reusing that model
avoids a parallel text-sizing object store, but also imports its atomicity
into editing and reflow ([storage][composed], [handler][osc], [PR][pr]).

The [PR][pr] discusses splitting a base emoji and variation selector across
two requests. The later selector can alter graphical presentation while the
forced allocation remains one cell. Its comments also distinguish a terminal
cursor from an application's software cursor and explain why continuation
positions do not represent independent code points.

Those comments are historical observations, not current cursor-conformance
tests. The general lesson survives: cell ownership, textual positions, and
the glyph's visual extent need separate mappings. A width-only implementation
does not eliminate interaction questions; it reduces them to a one-row object.

[`term_print`][terminal] applies current graphics attributes and OSC 8 URI
ranges while emitting the object. That integration supports treating sizing
as part of normal text placement, rather than as an image overlay detached
from terminal text state.

## Safety and evidence

[Issue 2364][empty-issue] reported an empty-payload heap out-of-bounds read in
foot 1.27.0. An explicit nonzero width with no text reached code that used
`len - 1` and `wchars[len - 1]`; with length zero, the unsigned subtraction
underflowed. The report includes an AddressSanitizer diagnostic.

The issue was **closed June 12, 2026**, and the inspected [handler][osc] now
returns when `text[0] == '\0'`, before conversion and composed lookup. The
[changelog][changelog] lists the zero-length crash fix. This is fixed history,
not a claim that the inspected revision still has that reported defect.

The lesson is broader than one parser: a legal-looking width does not prove a
nonempty text sequence, and a maximum-length check does not protect a minimum
length precondition. Empty payload, malformed conversion, long composed
sequences, and repeated-key parsing belong in independent boundary cases.

| Upstream item                | Verified status at review                             | Interpretation                                                |
| ---------------------------- | ----------------------------------------------------- | ------------------------------------------------------------- |
| [PR 1927][pr]                | Manually merged February 6, 2025                      | Width-only implementation, despite the historical `WIP` title |
| [Issue 2252][scope-issue]    | Closed January 3, 2026                                | Scaling explicitly out of scope                               |
| [Issue 2364][empty-issue]    | Closed June 12, 2026; fix visible in inspected source | Historical empty-text memory-safety defect fixed              |
| [Issue 2015][bleeding-issue] | Open                                                  | Proposed bleeding-policy change remains unresolved            |

> [!NOTE]
> Source and issue reports were inspected; no upstream tests, reproducer,
> sanitizer, font comparison, or terminal capability probe was executed for
> this page. The issue's sanitizer output is upstream evidence, not our result.

## Strengths

- Width agreement is useful without the complexity of multiline font scaling.
- Existing composed-character and spacer machinery provides the storage path.
- Forced and calculated widths remain distinct in retained state.
- The maintained scope and historical defects are explicitly documented upstream.
- MIT licensing provides a permissive implementation-reference option ([license][license]).

## Weaknesses

- No integer or fractional font scaling, vertical alignment, or tall objects.
- Allocation can be correct while glyphs bleed into neighboring cells.
- A multi-character payload becomes an atomic composed object, affecting edits.
- Tolerant parsing and compact retained counters need separate boundary validation.
- Source inspection alone does not establish runtime clipping or reflow conformance.

## Key design decisions and trade-offs

| Decision                            | Rationale                                          | Trade-off                                                  |
| ----------------------------------- | -------------------------------------------------- | ---------------------------------------------------------- |
| Implement only `w`                  | Solve allocation disagreement within project scope | Typography must fall back to normal size                   |
| Reuse composed characters           | Share storage and multi-column printing            | Payload grouping changes editing and reflow granularity    |
| Preserve `forced_width` separately  | Keep client allocation through composition         | Graphical presentation can diverge from that allocation    |
| Treat `w=0` as ordinary input       | No other sizing parameters need applying           | Unsupported scale requests still print ordinary-sized text |
| Permit optional rightward bleeding  | Accommodate glyph overhang                         | Damage and clipping extend beyond logical cells            |
| Reject empty text before conversion | Protect composed lookup's nonempty precondition    | Empty requests perform no placement                        |

## Sources

- [README][readme], [license][license], and [changelog][changelog]: scope, licensing, and release evidence.
- [OSC handler][osc], [composed storage][composed], and [terminal printing][terminal]: width override and retained state.
- [Renderer][render]: shaping, forced allocation, clipping, and bleeding cleanup.
- [PR 1927][pr]: merged implementation rationale and interaction discussion.
- [Issues 2252][scope-issue], [2364][empty-issue], and [2015][bleeding-issue]: scope, fixed safety history, and open rendering-policy question.

<!-- References -->

[repo]: https://codeberg.org/dnkl/foot
[license]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/LICENSE
[readme]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/README.md
[changelog]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/CHANGELOG.md
[osc]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/osc.c
[composed]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/composed.h
[terminal]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/terminal.c
[render]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/render.c
[pr]: https://codeberg.org/dnkl/foot/pulls/1927
[scope-issue]: https://codeberg.org/dnkl/foot/issues/2252
[empty-issue]: https://codeberg.org/dnkl/foot/issues/2364
[bleeding-issue]: https://codeberg.org/dnkl/foot/issues/2015
[spec]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[kitty]: ./kitty.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
