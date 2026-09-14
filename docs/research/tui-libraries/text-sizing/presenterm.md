# Presenterm (Rust)

Presenterm integrates terminal text scaling into a Markdown slide renderer, rather
than treating enlarged text as an escape sequence added after layout.

**Last reviewed:** September 14, 2026.

| Field           | Value                                                                |
| --------------- | -------------------------------------------------------------------- |
| Language        | Rust, edition 2021                                                   |
| License         | BSD-2-Clause; [manifest][manifest] and [license text][license]       |
| Repository      | [mfontanini/presenterm][repo]                                        |
| Documentation   | [Repository README][readme]                                          |
| Category        | Markdown presentation application; native terminal text scaling      |
| Package version | `0.16.1` at the inspected revision, not a release-date claim         |
| Revision        | `5f8add11a24af9d257fd18da48c8004dd9c516f8`                           |
| Commit date     | May 22, 2026                                                         |
| Inspection      | Local checkout at the revision above; source and tests read, not run |

## Overview

### What it solves

Slide titles, body text, lists, and code need different visual emphasis without
abandoning the terminal's cell grid. Presenterm combines theme-selected sizes,
slide commands, wrapping, alignment, and row advancement in one rendering path.
The relevant distinction is between a requested size and the size used to lay
out a slide on the current terminal. [Theme normalization][theme] and the
[presentation builder][builder] resolve much of that distinction before drawing.

This is application-level prior art, not a reusable widget API. The useful
comparison with [mdfried][mdfried] is how early terminal-dependent geometry enters
the pipeline. The contrast with [osc66][osc66] is that Presenterm enlarges text,
whereas that filter supplies explicit cluster widths without setting a scale.

### Design philosophy

The [README][readme] lists the feature with a deliberate qualification:

> Font sizes for terminals that support them.

The implementation makes that qualification concrete: theme sizes become `1`
when scaling is unsupported, and supported theme sizes are clamped to `1..=7`.
This is progressive enhancement at style construction, not merely suppression
of OSC bytes at the last moment. [ThemeOptions][theme] is the key evidence.

That architectural direction is valuable even though not every path has the
same guard. In particular, direct slide-title overrides deserve a separate
audit; the emitter is not itself a capability or validation boundary.

## How it works

The source pipeline is:

```text
terminal query -> ThemeOptions -> cleaned theme / slide style
Markdown -> styled Line -> WeightedLine -> TextDrawer
TextStyle::apply -> FontSizedStr -> terminal output
```

`ThemeOptions::adjust_font_size` normalizes theme inputs. The builder applies
theme styles and the effective slide size before constructing `WeightedLine`.
That line records scaled width and maximum run height. `TextDrawer` then wraps
against the available columns and moves down by that height on continuation
lines. [Theme][theme], [builder][builder], [weighted text][weighted], [drawer][drawer].

The final [formatter][style] uses these wire forms; this is descriptive notation,
not a tested terminal transcript:

```text
ordinary:        text
integer scale:   ESC ] 66 ; s=size ; text ESC \
fractional:      ESC ] 66 ; n=numerator:d=denominator ; text ESC \
```

SGR styling is composed around the sized payload through `StyledContent`.
Superscript can request fractional sizing, or substitute Unicode superscript
characters when that facility is unavailable. The formatter sends no explicit
`w`, so the terminal remains responsible for splitting text into scaled cells.

## Protocol and API

`TextStyle` carries a size alongside bold, italic, color, and other attributes.
`FontSizedStr` is an internal formatting adapter, not a protocol object with
validated payload length, segmentation, and occupied bounds. For `Scaled(0 | 1)`
it prints ordinary text; larger values produce `s=...`. [Style implementation][style].

The application supports a slide command such as:

```markdown
<!-- font_size: 2 -->
```

The [command handler][commands] rejects `0` and values above `7`. The
[builder][builder] normally obtains its effective value from `slide_font_size`,
which returns `1` when scaling is unsupported. This differs from accepting an
arbitrary integer in the output formatter and hoping the terminal repairs it.

Theme entries for slide titles and `h1` through `h6` have separate styles.
There is **no mandatory H1-to-H6 size staircase**: the heading builder selects
the corresponding theme entry, and H1 can optionally become a slide title.
Slide-wide size overrides can also supersede those choices. [Heading builder][headings].

The catalog's [concepts][concepts] separates semantic heading level, requested
font scale, and actual cell occupancy; Presenterm should be read in those terms.

## Measurement and geometry

`WeightedLine::from(Vec<Text>)` first merges consecutive equal-style runs. Its
width is the sum of each run's `UnicodeWidthStr` width multiplied by its size,
and its `font_size` is the maximum size across runs, with a minimum of one.
The source explicitly documents that accessor as the line's height. [Weighted text][weighted].

The wrapping representation is related but not identical: `WeightedText` builds
byte and width accumulators by iterating Rust `char` values and applying
`UnicodeWidthChar`. `WeightedTextRef` uses these accumulators to split and measure
substrings. Thus whole-string measurement and scalar-prefix measurement are
two different algorithms within the same path.

This distinction matters for combining sequences and emoji. Multiplying a
Unicode width by an integer is not glyph shaping, and scalar-safe byte offsets
are not automatically grapheme-safe break points. This is a source-derived
measurement risk, not a claim that a particular terminal rendering was reproduced.

The [printer][printer] tracks `current_row_height`, takes the maximum printed
style size, and consumes that height when moving to the next line. Wrapped
continuations explicitly move by `WeightedLine::font_size`. These are real
vertical layout provisions, not just bigger glyphs painted over single-row text.

Fractional superscript is less fully reflected in that geometry: `apply` can
change the emitted fraction without replacing the weighted line's integer-size
measurement. That can be conservative, but it is not a general fractional
measurement model. [Style][style], [weighted text][weighted].

## Capability and fallback

`TerminalCapabilities` separates `font_size` and `fractional_font_size`. Its
probe enters the alternate screen, moves to `(0, 0)`, emits a size-two space
and a half-size space, and reads the resulting cursor column. It interprets
columns `1`, `2`, and `3` as fractional-only, integer-only, and both,
respectively. [Probe][caps].

That interpretation is ambiguous when unsupported sizing requests print their
payload normally. The inspected [foot handler][foot-handler] does exactly that
for both requests: two ordinary spaces advance to column `2`, which Presenterm
would classify as integer scaling support. This is a source-derived false-positive
case, not a probe executed in this review. The combined displacement also does
not independently prove fractional ink rendering.

Theme normalization and `slide_font_size` are strong examples of resolving
fallback **before measurement**. If only output were downgraded, wrapping and
row placement would still reserve enlarged space for ordinary text.

There is an important qualification: `push_slide_title` reads
`slide_state.font_size` directly and applies it to the title style. That does
not call `slide_font_size`. Since the command handler stores the requested
value, this path is a source-derived exception to a blanket claim that all
unsupported-terminal sizes are normalized. [Headings][headings], [commands][commands].

`TextStyle::apply` consults fractional support for superscript, but its integer
formatter does not recheck `font_size`. Caller discipline remains necessary.
Neither that exception nor the probe's behavior was exercised in this review.

## Layout and clipping

`TextDrawer::new` reserves prefix and right-padding columns using saturating
subtraction. It can return `TerminalTooSmall` rather than blindly printing into
a very small area. The wrapping loop can repeat a list prefix or fill its area
with scaled spaces on continuation lines. [TextDrawer][drawer].

The [layout helper][layout] computes alignment from terminal columns and margins.
The [render engine][engine] also has optional overflow validation for block
lines. These checks are useful, but do not establish arbitrary rectangular
clipping of multicell text.

`word_split_at_length` divides by style size and forces the resulting budget to
at least one. That favors progress when a word is longer than the available
width. It is not proof that every returned piece fits a sub-scale viewport.
Likewise, byte boundaries derived from scalars can split a visual grapheme.
[Weighted text][weighted].

The [printer][printer] suppresses a run whose scaled height crosses the bottom
and tracks row height for printed runs. This is terminal-output management, not an
owner-aware clip operation that preserves only a visible fragment of a glyph.
See [validation][validation] for the distinction between bounds accounting and
terminal overwrite behavior.

## Retained state and interaction

The builder retains slides as chunks of render operations, including weighted
text and explicit line breaks. Slide navigation, pauses, and reload are the
application's interaction model; the README documents these facilities.
[Builder][builder], [README][readme].

That is not the same as retaining a multicell owner map in a cell-diff buffer.
The size-aware text path is expressed as commands sent through `TerminalIo`,
with cursor and row-height bookkeeping in the printer. It does not expose
per-grapheme hit testing or a reusable selection geometry API.

The useful transfer to the [Sparkles proposal][proposal] is the ordering:
resolve presentation policy, measure the resolved text, then emit it. Adopting
that ordering does not require adopting the slideshow's navigation model or
assuming its command stream solves retained-cell invalidation.

## Safety and evidence

The output boundary inserts `contents` directly into OSC. It does not visibly
encode escape-code-safe UTF-8, reject embedded control terminators, or partition
payloads at the protocol's 4096-byte text limit. Wrapping by columns is not a
byte-length bound, especially for zero-width sequences. [Formatter][style],
[protocol][protocol].

Consequently, this is **not a safe-emitter reference implementation**. The
absence of checks at this boundary is verified in source; exploitability through
every Markdown input path is not established here. Rust memory safety and OSC
payload safety are different claims.

Tests read include `font_size_split` in weighted text, sized-prefix continuation
tests in the drawer, and heading-size builder tests. They provide evidence of
intended scaled wrapping and title behavior, not terminal conformance results.
[Weighted tests][weighted-tests], [drawer tests][drawer-tests], [heading tests][heading-tests].

No upstream tests, terminal probes, or adversarial payload reproductions were
run for this review. Open validation cases include grapheme boundaries, a
viewport narrower than one scaled cell, oversized UTF-8 payloads, unsupported
title overrides, and overwriting only the lower row of enlarged text.

## Strengths

- Effective theme size enters the line model before wrapping and placement.
- Width, continuation height, prefixes, and printer row advancement know scale.
- Integer and fractional support are represented separately.
- Heading roles remain theme policy rather than a hard-coded size hierarchy.
- Source-level tests cover several scaled wrapping and heading cases.

## Weaknesses

- Direct title overrides qualify the otherwise strong early-fallback story.
- Scalar-prefix wrapping is not a shaping or grapheme-preservation contract.
- Fractional emission does not have a matching general fractional layout model.
- Raw OSC payload construction lacks a dedicated safe, bounded encoder.
- Command-stream bookkeeping is not reusable retained multicell ownership.

## Key design decisions and trade-offs

| Decision                         | Rationale                                | Trade-off                                                |
| -------------------------------- | ---------------------------------------- | -------------------------------------------------------- |
| Normalize theme scale early      | Keep ordinary fallback geometry coherent | All alternate style paths must honor the same policy     |
| Use integer weighted cell widths | Reuse terminal-column layout             | Does not model shaping or every grapheme sequence        |
| Track maximum line height        | Keep following rows clear                | Mixed-size lines reserve the tallest run's height        |
| Let themes choose heading sizes  | Preserve presentation author control     | No universal semantic heading-to-scale mapping           |
| Omit explicit `w`                | Keep emission simple                     | Terminal Unicode segmentation still determines occupancy |
| Emit through `Display`           | Compose with existing styling            | Safety and byte bounds remain outside the formatter      |

The [comparison][comparison] should credit early geometry integration while
keeping the safe-emitter, fallback-path, and Unicode qualifications visible.

## Sources

- [Manifest][manifest] and [license][license]: identity and licensing.
- [README][readme]: positioning, quoted feature, and interaction features.
- [Theme normalization][theme], [builder][builder], and [headings][headings].
- [Weighted text][weighted], [drawer][drawer], [printer][printer], and [layout][layout].
- [Capabilities][caps] and [formatter][style]: probe and wire boundary.
- [Protocol specification][protocol]: external contract, reviewed September 14, 2026.
- [Concepts][concepts], [comparison][comparison], [validation][validation], and
  [Sparkles proposal][proposal]: catalog context and follow-up obligations.

<!-- References -->

[repo]: https://github.com/mfontanini/presenterm/tree/5f8add11a24af9d257fd18da48c8004dd9c516f8
[manifest]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/Cargo.toml
[license]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/LICENSE
[readme]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/README.md
[theme]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/theme/clean.rs#L23-L32
[builder]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/presentation/builder/mod.rs#L492-L580
[commands]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/presentation/builder/comment.rs#L97-L102
[headings]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/presentation/builder/heading.rs#L9-L76
[weighted]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/markdown/text.rs#L18-L250
[style]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/markdown/text_style.rs#L141-L276
[caps]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/terminal/capabilities.rs#L74-L100
[foot-handler]: https://codeberg.org/dnkl/foot/src/commit/2705e36f0ecf3ef50c13b41165de852f134859d6/osc.c#L1187-L1208
[drawer]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/render/text.rs#L27-L160
[printer]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/terminal/printer.rs#L120-L159
[layout]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/render/layout.rs#L10-L69
[engine]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/render/engine.rs#L317-L345
[weighted-tests]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/markdown/text.rs#L307-L314
[drawer-tests]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/render/text.rs#L330-L378
[heading-tests]: https://github.com/mfontanini/presenterm/blob/5f8add11a24af9d257fd18da48c8004dd9c516f8/src/presentation/builder/heading.rs#L241-L261
[protocol]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[proposal]: ./sparkles-proposal.md
[mdfried]: ./mdfried.md
[osc66]: ./osc66.md
