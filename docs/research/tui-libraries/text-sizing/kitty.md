# Kitty (C / Python / Terminal Protocols)

Kitty's text-sizing protocol makes cell occupancy explicit while retaining the terminal grid, and its implementation demonstrates the consequences throughout the screen model.

| Field                 | Value                                                                              |
| --------------------- | ---------------------------------------------------------------------------------- |
| Language              | C screen and rendering core; Python orchestration and tests                        |
| License               | GPLv3, verified in [`LICENSE`][license] and the [`multicell.py` header][tests]     |
| Repository            | [kovidgoyal/kitty][repo]                                                           |
| Documentation         | [Pinned text-sizing specification][spec]                                           |
| Category              | Protocol originator and full multicell implementation                              |
| Inspected revision    | `a54b40978533a3e397c09dcd5229de1a08ad43e7`                                         |
| Revision date         | September 14, 2026                                                                 |
| Protocol introduction | Kitty 0.40.0, according to the specification's `versionadded` annotation           |
| Evidence              | Source inspection and upstream test inspection; tests not executed for this survey |

**Last reviewed:** September 14, 2026

## Overview

### What it solves

Terminal applications traditionally predict occupancy using their own Unicode
tables while the terminal independently segments and measures the same bytes.
Version skew, variation selectors, combining sequences, and private-use glyphs
can make those predictions disagree. Kitty moves the authoritative allocation
decision to the application when it supplies an explicit width. The same
protocol also permits headlines, superscripts, and other sizes inside an
otherwise unchanged grid ([specification][spec]).

These are separable benefits. An application can use `w` to stabilize geometry
without asking for larger fonts. Conversely, `s` with `w=0` scales text while
leaving segmentation and natural-width calculation to the terminal. The
[concepts][concepts] distinguish allocation from ink; the [comparison][comparison]
places Kitty beside partial and parser-only implementations.

### Design philosophy

The specification states the ownership change directly:

> The client becomes responsible for doing whatever level of
> grapheme segmentation it is comfortable with using whatever Unicode database is
> at its disposal and then it can transmit the segmented string to the terminal
> with the appropriate `w` values so that the terminal renders the text in the
> exact number of cells the client expects.

This is verbatim prose from the [specification][spec], with its reStructuredText
inline-code markup rendered as Markdown. It promises agreement about cells,
not identical glyph rasterization. The document explicitly allows the terminal
to truncate or downsize text that does not fit an application-specified block.

## How it works

The input path goes from OSC dispatch in [`vt-parser.c`][vt-parser] through
[`parse_multicell_code`][parser] to
[`screen_handle_multicell_command`][screen]. The screen handler decodes the
payload, constructs multicell metadata, and chooses one of two paths:

1. Nonzero `w`: store the payload as one fixed-width multicell object.
2. Zero `w`: segment text, calculate each segment's natural width, and place
   separate scaled objects with `natural_width` recorded.

[`CPUCell`][line] stores the width, scale, fractional-scale parameters,
alignment, and offsets `x` and `y` within the object. The fixed-width placement
loop writes metadata into every occupied cell, applies current graphics
attributes, marks affected lines dirty, and advances the cursor horizontally.
This is screen state, not an escape sequence saved beside ordinary text.

The wire shape below is explanatory notation, not an executed example:

```text
ESC ] 66 ; s=2:w=3:n=1:d=2:v=2:h=2 ; abc ESC \
```

It allocates six columns by two rows. Fractional scale affects the rendered
font inside that rectangle, not the rectangle's dimensions ([specification][spec]).

## Protocol and API

OSC 66 contains colon-separated `key=value` metadata, a semicolon, and
escape-code-safe UTF-8 text. It terminates with `BEL` or `ST` (`0x1b 0x5c`).
The protocol text uses a build-time placeholder for the OSC number in some
examples; the implementation dispatches the text-size command ([parser][parser],
[OSC dispatch][vt-parser]).

| Key      | Protocol domain        | Meaning                                                                |
| -------- | ---------------------- | ---------------------------------------------------------------------- |
| `s`      | 1 through 7; default 1 | Integer scale and allocated row count                                  |
| `w`      | 0 through 7; default 0 | Explicit width in scaled cells; zero selects natural segmentation      |
| `n`, `d` | 0 through 15           | Fractional font scale; a nonzero denominator must exceed the numerator |
| `v`      | 0, 1, 2                | Top, bottom, centered fractional render area                           |
| `h`      | 0, 1, 2                | Left, right, centered fractional render area                           |

The generated parser rejects unknown keys, missing equals signs, invalid
integer syntax, and malformed separators. It parses unsigned values before
the screen handler clamps them to its bit-field ranges; scale is at least one.
Therefore parser acceptance, internal representability, and the specification's
canonical domain are not identical ([parser][parser], [screen handler][screen]).

A Sparkles encoder should emit canonical values rather than depend on this
normalization. That recommendation is a design inference, not a claim that
Kitty rejects every noncanonical input. In particular, the two-bit alignment
storage is not evidence that alignment value 3 is a portable protocol value.

## Measurement and geometry

For explicit width, allocation is `(s * w, s)` base cells and cursor advance is
`s * w` columns in the same row. Ordinary cursor motion remains measured in
single base cells, including positions inside a multicell. For `w=0`, each
natural-width segment gets its own scaled allocation ([specification][spec]).

Fractional scale changes font size within the allocation. Alignment positions
the fractional render area inside the full area; it is not a paragraph
alignment API. A half-sized glyph can still occupy one full cell, and fitting
two characters in that cell requires grouping them with explicit `w`.

The font size is relative to the user's base font size. A later base-size
change scales the text accordingly, subject to fitting adjustments. Applications
should consequently retain semantic scale and allocation, not bake the
terminal's current point size into their layout ([specification][spec]).

Two limits must not be conflated:

- The protocol permits at most **4096 payload bytes per escape sequence**.
- Kitty caps stored text at **24 code points per cell object** through
  `MAX_NUM_CODEPOINTS_PER_CELL`, including the fixed-width multicell path
  ([cell definition][line], [placement code][screen]).

A short UTF-8 payload can exceed the latter limit; a valid 4096-byte payload
does not imply lossless storage in one explicit-width object. Conversely,
natural-width text can be split into many objects. Transport chunking and
segmentation must be treated as separate operations in the
[Sparkles proposal][proposal].

## Capability and fallback

The [specified probe][spec] uses three cursor-position reports: one before
output, one after an explicit-width space (`w=2`), and one after a scaled space
(`s=2`). A two-column displacement in the respective step detects the width
and scale capabilities independently. One OSC number is not one boolean feature.

The probe writes to the screen. It needs space, response correlation, a timeout,
and cleanup; those operational requirements are application responsibilities,
not supplied by the protocol's short recipe. Avoid right-edge wrapping and
scrolling when interpreting displacement. See [validation][validation] for the
probe and fallback test boundary.

An unsupported terminal may discard the entire OSC, including its text.
Consequently, unconditional OSC emission is not a plain-text fallback. Choose
ordinary output before encoding when support is absent or unknown. Width-only
support should enable explicit occupancy without enabling scaled layout.

## Layout and clipping

The [specification][spec] discards a block larger than the screen in either
dimension. With wrapping enabled, an object that does not fit the remaining
columns moves to the next line. With wrapping disabled, the cursor backs up
far enough to fit it. Kitty's placement code additionally checks the available
scrolling-region height and scrolls when vertical space below the cursor is
insufficient ([screen implementation][screen]).

Normal drawing has asymmetric overlap rules: overwriting the top-left cell
erases the object; overwriting another cell in its top row replaces the object
with spaces. Drawing into a lower row instead skips past its occupied cells,
independently of `DECAWM`. Combining-character handling precedes ordinary
overwrite behavior ([specification][spec], [screen implementation][screen]).

**Erasure is not drawing spaces.** `ECH` erases any multicell intersecting the
requested range, including an intersection with a lower row. `EL` and `ED`
similarly remove intersecting objects. A renderer that clears a dirty lower-row
rectangle by printing spaces can therefore get a different result from one
using `ECH` ([editing rules][spec], [erase tests][tests]).

`ICH` and `DCH` erase affected multiline objects and single-line objects split
by edit boundaries. `IL` and `DL` also need object-aware handling at row and
screen boundaries. A toolkit cannot implement scalable text solely in its
text painter while leaving all clearing and shifting operations unchanged.

The upstream [tests][tests] inspect rewrap across changed widths, cursor
association with content, objects spanning history and visible rows, and loss
of objects that no longer fit. Alternate-screen resize is separately tested
without rewrap. These are inspected behavioral oracles, not results produced
by this survey.

## Retained state and interaction

[`CPUCell`][line] is statically asserted to be 12 bytes and carries both object
geometry and text-cache identity; [`GPUCell`][line] separately carries graphics
attributes and sprite identity. Continuation positions can recover the
object's origin from their offsets. Full support thus has a representation
cost even when the original escape has long since been consumed.

The fixed-width placement path preserves current hyperlink identity and
graphics attributes across the occupied rectangle ([screen implementation][screen]).
The implication for a retained toolkit is that style, hit testing, and damage
must refer to a shared object extent rather than unrelated decorative cells.

Selection tests start or end inside continuation cells, inspect selection masks,
and compare plain and ANSI text extraction. Selecting a lower-row portion can
select the entire multicell and extract its text once. ANSI extraction retains
OSC sizing information; plain extraction returns text without duplicating
continuations ([selection cases][tests]).

These tests supply a stronger oracle than a screenshot: a screenshot can show
large ink while hiding broken copy behavior, cursor recovery, or stale
continuation state. The [validation plan][validation] should keep these outputs
independent rather than reduce them to a single visual success criterion.

## Safety and evidence

The inspected [test file][tests] includes a regression for a natural-width
grapheme longer than a temporary `ListOfChars` buffer. Accumulation formerly
overflowed before the later 24-code-point storage cap could protect anything.
The current [handler][screen] grows the accumulator before appending. Tests
use both a long first cluster and a still longer subsequent cluster.

That case demonstrates why a storage cap is not an input-validation strategy.
Bounds are needed during decoding and accumulation, before truncation, and
again when converting geometry to screen indices. A canonical producer should
also reject controls and split payloads without breaking UTF-8 or graphemes.

The same file includes an overlay-line regression for an uninitialized
line-buffer view. Its relevance is structural: ordinary overlay drawing now
touches multicell metadata, so introducing the feature enlarges the set of
paths whose screen invariants matter ([regression test][tests]).

> [!IMPORTANT]
> All upstream tests cited here were source-inspected, not executed. Kitty is
> a behavioral reference, not a source implementation to copy into Sparkles:
> its implementation and tests carry GPLv3 notices. Derive independent tests
> from the protocol and observed contracts; do not transplant their source.

## Strengths

- Explicit width eliminates a class of client/terminal allocation disagreements.
- Allocation and fractional ink scale are separately specified.
- The screen model covers editing, history, rewrap, selection, and serialization.
- Upstream tests expose cell metadata and cursor state, not only rendered pixels.
- Width and scale can be probed independently ([specification][spec], [tests][tests]).

## Weaknesses

- Full support changes many retained-screen operations, not just font selection.
- Lower-row drawing and erasure differ, complicating partial repaint strategies.
- A 4096-byte legal payload can exceed the 24-code-point storage limit per object.
- Exact fitting and rasterization remain terminal-dependent.
- GPLv3 source cannot be treated as a permissively licensed implementation donor.

## Key design decisions and trade-offs

| Decision                                | Rationale                                                | Trade-off                                               |
| --------------------------------------- | -------------------------------------------------------- | ------------------------------------------------------- |
| Keep the base grid                      | Preserve existing cursor and editing controls            | Scaled text needs explicit continuation geometry        |
| Let `w` assign occupancy                | Remove Unicode-width coordination from the wire contract | Applications own segmentation and sensible chunk sizes  |
| Keep fractional scale inside allocation | Permit small text without fractional cursor cells        | Ink bounds and layout bounds diverge                    |
| Skip lower rows during drawing          | Allow text to flow around tall objects                   | Clearing by spaces is not equivalent to `ECH`           |
| Track geometry in cells                 | Support reflow, selection, and object-aware edits        | More state and more invariants in ordinary screen paths |
| Cap stored code points                  | Bound per-object retained text                           | Transport-valid input may be truncated                  |

## Sources

- [Text-sizing specification][spec]: wire contract, geometry, capability probe, and editing semantics.
- [Generated parser][parser] and [OSC dispatch][vt-parser]: syntax and integration boundary.
- [Screen implementation][screen] and [cell representation][line]: normalization, storage, and placement.
- [Multicell tests][tests]: source-inspected drawing, erasure, resize, selection, and safety oracles.
- [License][license]: source-reuse boundary.

<!-- References -->

[repo]: https://github.com/kovidgoyal/kitty
[license]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/LICENSE
[spec]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[parser]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/parse-multicell-command.h
[vt-parser]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/vt-parser.c
[screen]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/screen.c
[line]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty/line.h
[tests]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/kitty_tests/multicell.py
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
