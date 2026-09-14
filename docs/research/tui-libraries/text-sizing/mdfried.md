# mdfried (Rust)

`mdfried` renders Markdown headings through native OSC text sizing, shaped
images, or ordinary text, exposing the integration costs of each route.

**Last reviewed:** September 14, 2026.

| Field                       | Value                                                                 |
| --------------------------- | --------------------------------------------------------------------- |
| Language                    | Rust, edition 2024                                                    |
| License                     | GPL-3.0-or-later in the [manifest][manifest]; [GPL text][license]     |
| Repository                  | [benjajaja/mdfried][repo]                                             |
| Documentation               | [Repository README][readme]                                           |
| Category                    | Markdown pager; OSC/image/plain heading consumer                      |
| Package version             | `0.22.5` at the inspected revision                                    |
| Revision                    | `27c80b90bd408f60b094e50c09888e22cd444624`                            |
| Commit date                 | September 4, 2026                                                     |
| Main rendering dependencies | Ratatui, `ratatui-image`, `cosmic-text`, in-tree `mdfrier`            |
| Inspection                  | Local pinned source and tests read; tests and terminal probes not run |

## Overview

### What it solves

A Markdown pager benefits from headings that are visibly different in size,
not merely bold or colored. `mdfried` combines that typography with scrolling,
images, search, and link navigation. Its text-sizing implementation is embedded
in a real retained terminal application rather than a standalone OSC demo.
[README][readme], [view][view].

The key finding is that there are **three heading routes**, not one renderer
with interchangeable output encodings. OSC headings use cell-width prewrapping;
image headings use font shaping and raster layout; ordinary headings use a
placeholder representation when there is no font renderer. [Setup][setup],
[section construction][sections], [image shaping][images].

### Design philosophy

The [README][readme] states the distinction plainly:

> Not **bold**, not just _styled_, actually BIGGER, making markdown much more readable in a terminal.

That visual priority explains both the native text path and the willingness to
rasterize headings. It also motivates specialized two-row sections instead of
trying to express every heading as a normal one-row Ratatui span.

The trade-off is that the large-heading path does not automatically inherit
ordinary-text semantics such as inline styling, search matches, or cell-diff
ownership. Those differences must be evaluated separately from screenshots.
See [concepts][concepts] for the separation of appearance, occupancy, and identity.

## How it works

`setup_graphics` asks `ratatui-image::Picker` to discover capabilities, including
text sizing unless configured to ignore it. Text-sizing support returns
`SetupResult::TextSizing` immediately. A halfblock fallback returns `AsciiArt`;
otherwise setup constructs a font renderer. [Setup selection][setup].

The parser and section builder then choose their representations:

```text
text-sizing support -> cell-width prewrap -> Header(text, tier, None)
font renderer       -> HeaderPlaceholder -> shaped image -> Header(..., Some(proto))
no font renderer    -> HeaderPlaceholder remains ordinary text
```

`SectionContent::Header` without an image is painted by `BigText`. A header with
an image uses `ratatui-image::Image`. Ordinary placeholders use `Paragraph`.
The worker asynchronously replaces image-heading placeholders after rasterizing
their content. [Sections][sections], [worker][worker], [view][view].

## Protocol and API

`BigText::new(text, tier, color)` is a small Ratatui widget. It always emits
`s=2`, and selects a fractional numerator and denominator by heading tier.
The source's wire template is:

```text
ESC ] 66 ; s=2:n=numerator:d=denominator:w=width ; chunk ESC \
```

The [ratio table][bigtext] is:

| Heading    | `n/d` | Intended visual scale `2*n/d` | Occupied height |
| ---------- | ----- | ----------------------------- | --------------- |
| H1         | `7/7` | `2`                           | 2 rows          |
| H2         | `5/6` | `5/3`                         | 2 rows          |
| H3         | `3/4` | `3/2`                         | 2 rows          |
| H4         | `2/3` | `4/3`                         | 2 rows          |
| H5         | `3/5` | `6/5`                         | 2 rows          |
| H6 / other | `1/3` | `2/3`                         | 2 rows          |

“Intended” matters for H1: `n=7:d=7` is noncanonical and violates the
[specification's][protocol] requirement that nonzero `d` exceed `n`. A canonical
full-size request would omit the fraction. The source and stored snapshots
establish what is emitted, not which terminals accept that spelling.

No `h` or `v` alignment key is supplied. Fractions alter glyph scale within the
allocated box; they do not reduce its two-row occupancy. The explicit `w`
controls horizontal allocation in units that are then multiplied by `s=2`.

## Measurement and geometry

The [parser's line conversion][lines] duplicates the ratio table and computes
the ordinary-width wrapping budget as `width / 2 * d / n`, with integer
arithmetic in that order. `BigText::size_ratio` contains the same mapping, but
the parser does not call that function. Two copies must therefore stay aligned.

At emission, `unicode_chunks` iterates a `Vec<char>`, not grapheme clusters.
It accumulates `UnicodeWidthChar` values up to denominator `d`; a wide scalar
is always emitted in its own chunk. Full chunks request `w=n`; partial chunks
request `ceil(chunk_width*n/d)`. [Chunking and emission][bigtext].

The prewrap formula and emitted occupancy are not equivalent. Consider H2 in
a 20-column viewport with six CJK scalars of width two each. This arithmetic
counterexample follows directly from the two algorithms:

```text
prewrap budget:       20 / 2 * 6 / 5 = 12 ordinary columns
six wide scalars:     6 * 2 = 12, so the line fits that budget
each emitted chunk:  w = ceil(2 * 5 / 6) = 2
actual requested sum: 6 * (s=2 * w=2) = 24 terminal columns
```

Thus a line admitted for 20 columns requests 24 columns. This is a
**source-derived counterexample**, not a captured terminal failure. Per-chunk
rounding, especially the wide-scalar isolation rule, must be included in the
measurement oracle. A whole-line proportional estimate is insufficient.

The [image path][images] has different geometry: `header_images` uses
`cosmic-text`, `Shaping::Advanced`, pixel width from terminal font metrics, and
a tier factor `(12-tier)/12`. It creates one image per shaped layout run, with
two terminal rows per image. That scale curve is not the OSC ratio table.

## Capability and fallback

The setup query includes configurable timeout and
`ignore_text_sizing_protocol`. A discovered `TextSizingProtocol` capability
selects the native path before font selection, avoiding raster setup when the
terminal can draw sized text itself. [Setup][setup].

That single capability marker is broader than this widget's actual demands:
integer scaling, fractions, explicit width, and their combined behavior. The
local call site does not independently prove each combination, nor validate
H1's equal numerator and denominator. This review did not audit the dependency's
probe implementation or run it against terminals.

Without text sizing, graphics support can select the shaped-image path. Setup
loads bundled and system fonts, attempts terminal-font detection, and can ask
the user to choose a family. This is an image-rendering input, not a guarantee
that native OSC and raster glyphs use identical fonts. [Font setup][setup].

Without that renderer, header placeholders remain ordinary colored text with
hash prefixes. This preserves a readable heading route but does not promise
identical wrapping, typography, selection, or height across all three modes.
[Placeholder construction][sections], [view][view].

## Layout and clipping

`BigText` does not render a normal span into each occupied cell. It constructs
one raw string containing erases, cursor motion, autowrap changes, optional
color, and OSC records. It stores that entire string in the area's first cell
and marks all other cells `CellDiffOption::Skip`. [Widget implementation][bigtext].

The erase sequence clears two rows, moving down and back up before painting.
It disables `DECAWM` with `CSI ? 7 l`; the same function does not restore it.
This is a **raw Ratatui skip hack**, not a backend-supported multicell primitive.
It relies on terminal side effects that the ordinary cell model cannot infer.

`view` only paints completed headings when they are fully visible according to
its two-row guard. Images used for ordinary document pictures have a sliced
scrolling path, but large headings are suppressed at partial visibility rather
than cropped row by row. [View branches][view].

The widget only rejects zero width or zero height. A nonempty one-row area can
still cause the raw sequence to erase and draw two rows, and `area_width` limits
the erases rather than truncating the text. The CJK counterexample shows why
prewrapping cannot substitute for an emission-bound check.

Other bounds deserve validation: the view uses expressions such as
`inner_area.bottom() - 2`, and image sizing multiplies `u16` metrics before
conversion to wider types. These are source-derived small-viewport and large-
dimension risks, not reproduced crashes. [View][view], [image geometry][images].

## Retained state and interaction

The application retains typed sections, their heights, document identity,
scroll position, and interaction state. Its render loop passes buffers to a
render thread and drops intermediate frames rather than accumulating input
behind slow image output. [Section model][document], [render loop][renderer].

That substantial retained application model should not be confused with a
multicell-aware buffer. `Skip` hides covered cells from ordinary diffing, while
the actual erase and paint operations live inside an opaque first-cell symbol.
Correct transitions between old and new occupied rectangles require evidence
beyond equality of those raw symbol strings.

Heading text preserves the raw Markdown inline source. The parser separately
extracts links, but does not convert the heading itself into the same styled
inline spans used for body paragraphs. Emphasis markers and link syntax can
therefore remain in the big text. [Heading parser][markdown].

Extracted heading links are appended as ordinary lines below the heading,
where normal link rendering and interaction can operate. That is a deliberate
semantic split, not clickable regions inside the enlarged heading. [Line conversion][lines].

Search similarly does not cover heading text: `SectionContent::add_search`
only processes `Lines`, with an explicit `TODO: search in headers`. Header-anchor
navigation exists separately in the model and does not close that gap.
[Search implementation][search], [anchor navigation][model].

## Safety and evidence

The OSC writer extends its string directly with input scalars. It does not
enforce escape-code-safe UTF-8 or reject controls that can terminate a payload.
The width-based chunker does not enforce the protocol's 4096-byte payload limit;
arbitrarily many zero-width scalars can accumulate without filling its budget.
[BigText][bigtext], [protocol][protocol].

Color handling also illustrates why raw protocol output needs a typed boundary:
`Color::Indexed` is formatted as `CSI index m`, not the usual indexed-foreground
`CSI 38;5;index m`. This is a source-level encoding discrepancy, not a report of
a tested palette failure. [Color branch][bigtext].

Tests read include `header_wrapping_tier_1`, the application resize/wrapping
assertions, and stored snapshots containing `s=2:n=7:d=7`. They establish intended
section splitting and raw output structure, not terminal interpretation.
[Section test][section-test], [application tests][app-tests], [snapshot][snapshot].

No upstream tests, GUI/terminal screenshots, or adversarial reproductions were
run. [Validation][validation] should require independent occupancy arithmetic,
grapheme preservation, canonical metadata, payload safety, and damage tests
covering resize, removal, movement, and partial visibility.

## Strengths

- Demonstrates native text, shaped image, and ordinary fallback in one pager.
- Selects native sizing before unnecessary font setup and image generation.
- Carries explicit two-row heading sections through scrolling and layout.
- Uses advanced shaping for image headings rather than scalar-width estimates.
- Preserves access to heading links through separate ordinary-text lines.

## Weaknesses

- Prewrap estimates disagree with per-chunk occupancy for wide text.
- Scalar chunks can split graphemes and do not bound payload bytes.
- H1 emits a noncanonical fraction; capability evidence is coarser than usage.
- Opaque raw symbols and skipped cells bypass normal retained-buffer semantics.
- Heading inline styling and search do not match the body-text path.

## Key design decisions and trade-offs

| Decision                            | Rationale                                 | Trade-off                                        |
| ----------------------------------- | ----------------------------------------- | ------------------------------------------------ |
| Prefer OSC over raster headings     | Avoid font setup and image transport      | Depends on combined sizing behavior              |
| Fix occupancy at two rows           | Simplify section heights                  | Small fractions still reserve two rows           |
| Prewrap with a proportional budget  | Reuse ordinary text wrapping              | Misses per-chunk rounding costs                  |
| Isolate wide scalars                | Work around observed terminal behavior    | Loses grapheme guarantees and packing efficiency |
| Put raw output in one buffer cell   | Integrate without a new backend primitive | Diffing cannot understand the covered owners     |
| Put heading links below the heading | Reuse normal interaction machinery        | Visual text and link hit regions diverge         |

The [comparison][comparison] and [Sparkles proposal][proposal] should borrow route
selection and explicit geometry, not the raw-cell transport shortcut.

## Sources

- [README][readme], [manifest][manifest], and [license][license]: identity and intent.
- [Setup][setup], [sections][sections], and [worker][worker]: route selection.
- [BigText][bigtext], [line wrapping][lines], and [image shaping][images]: geometry.
- [View][view], [search][search], and [heading parser][markdown]: integration limits.
- [Protocol specification][protocol]: wire contract, reviewed September 14, 2026.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and
  [Sparkles proposal][proposal]: catalog context and validation obligations.

<!-- References -->

[repo]: https://github.com/benjajaja/mdfried/tree/27c80b90bd408f60b094e50c09888e22cd444624
[manifest]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/Cargo.toml
[license]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/LICENSE
[readme]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/README.md
[setup]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/setup.rs#L50-L179
[bigtext]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/big_text.rs#L6-L136
[sections]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/worker/sections.rs#L70-L102
[worker]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/worker.rs#L140-L220
[lines]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/mdfrier/src/lines.rs#L240-L285
[images]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/document.rs#L733-L824
[view]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/view.rs#L44-L126
[document]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/document.rs#L496-L528
[renderer]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/renderer.rs#L15-L106
[markdown]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/mdfrier/src/markdown.rs#L161-L212
[search]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/document.rs#L513-L528
[model]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/model.rs#L410-L441
[section-test]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/worker/sections.rs#L349-L373
[app-tests]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/main.rs#L760-L830
[snapshot]: https://github.com/benjajaja/mdfried/blob/27c80b90bd408f60b094e50c09888e22cd444624/src/snapshots/mdfried__tests__first%20parse%20done.snap
[protocol]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
