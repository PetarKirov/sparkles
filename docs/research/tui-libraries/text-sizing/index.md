# Text sizing in terminal interfaces

This catalog surveys native text sizing from wire encoding through application
layout and terminal execution. It informs Sparkles without declaring an accepted
API or claiming that protocol support has been implemented.

This survey answers five questions:

1. What do size, explicit width, fractional scale, and occupied cells mean?
   See [concepts][concepts] and [Kitty][kitty].
2. Which receivers execute the protocol? See [Kitty][kitty], [foot][foot], and
   [Ghostty][ghostty].
3. How do libraries measure, wrap, negotiate, and retain sized text? See
   [wcwidth][wcwidth], [Blessed][blessed], [libvaxis][libvaxis], and [OpenTUI][opentui].
4. How do applications turn Markdown or shaped text into terminal output? See
   [presenterm][presenterm], [mdfried][mdfried], and [osc66][osc66].
5. What must change in Sparkles, and how could correctness be demonstrated? See
   the [baseline][baseline], [proposal][proposal], and [validation ledger][validation].

**Last reviewed:** September 14, 2026

## Master catalog

These are inspected local snapshots, not claims about current upstream tips.
Each deep-dive records the complete revision, license, source quotations, and
evidence limitations. Source inspection is not equivalent to executing tests.

| Subject    | Category                | Observed sizing boundary                                                   | Link                |
| ---------- | ----------------------- | -------------------------------------------------------------------------- | ------------------- |
| Kitty      | Terminal and protocol   | Executes rectangular multicells, fractions, editing and reflow             | [Study][kitty]      |
| Ghostty    | Terminal / VT library   | Parses OSC 66; execution remains unimplemented in both inspected revisions | [Study][ghostty]    |
| foot       | Terminal                | Executes explicit width; scaling deliberately out of scope                 | [Study][foot]       |
| libvaxis   | TUI library             | Emits width, integer scale and fractions; retained-state risks             | [Study][libvaxis]   |
| OpenTUI    | TUI library             | Emits explicit width; detects scale without scaled widget layout           | [Study][opentui]    |
| Blessed    | Python terminal library | Constructs sized text and probes support; validation/fallback gaps         | [Study][blessed]    |
| wcwidth    | Python text library     | Parses, measures and extracts payloads; clipping/wrapping limitations      | [Study][wcwidth]    |
| presenterm | Markdown presentation   | Capability-normalized integer-sized text layout                            | [Study][presenterm] |
| osc66      | Shaping CLI             | Font-derived explicit width, not enlarged text                             | [Study][osc66]      |
| mdfried    | Markdown viewer         | Native sized, rasterized, and plain heading paths                          | [Study][mdfried]    |

## Taxonomy

### By responsibility

| Responsibility                            | Subjects                                         |
| ----------------------------------------- | ------------------------------------------------ |
| Define and execute terminal semantics     | [Kitty][kitty], [foot][foot], [Ghostty][ghostty] |
| Parse or construct text-bearing sequences | [wcwidth][wcwidth], [Blessed][blessed]           |
| Retain and diff a terminal picture        | [libvaxis][libvaxis], [OpenTUI][opentui]         |
| Choose document typography                | [presenterm][presenterm], [mdfried][mdfried]     |
| Derive allocation from a chosen font      | [osc66][osc66]                                   |

### By geometry

| Geometry model                             | Evidence                                 |
| ------------------------------------------ | ---------------------------------------- |
| Rectangular object ownership               | [Kitty][kitty]                           |
| Horizontal explicit-width object           | [foot][foot]                             |
| Ordinary wide-grapheme retained spans      | [OpenTUI][opentui]                       |
| Scaled placement with incomplete ownership | [libvaxis][libvaxis], [mdfried][mdfried] |
| Height-aware sequential text flow          | [presenterm][presenterm]                 |
| Scalar horizontal measurement              | [wcwidth][wcwidth], [Blessed][blessed]   |

## Milestones

Dates describe the cited event, not when every downstream acquired the feature.

| Date               | Event                                         | Evidence                                                   |
| ------------------ | --------------------------------------------- | ---------------------------------------------------------- |
| February 6, 2025   | foot merges width-only OSC 66                 | [foot upstream history][foot]                              |
| March 8, 2025      | Kitty 0.40 introduces multiple-sized text     | [Kitty changelog][kitty-introduction]                      |
| January 15, 2026   | Ghostty lands OSC 66 parsing, not execution   | [Ghostty introduction commit][ghostty-parser-introduction] |
| February 2, 2026   | OpenTUI fixes force-off still issuing probes  | [OpenTUI upstream history][opentui]                        |
| June 12, 2026      | foot fixes empty-payload out-of-bounds access | [foot safety evidence][foot]                               |
| August 23, 2026    | OpenTUI fixes cursor-report attribution       | [OpenTUI upstream history][opentui]                        |
| September 14, 2026 | Survey confirms Ghostty still lacks execution | [Ghostty snapshot][ghostty]                                |

## Reading paths

- **Implementing the Sparkles feature:** [concepts][concepts], [comparison][comparison],
  [baseline][baseline], [proposal][proposal], [validation][validation].
- **Writing a terminal encoder:** [Kitty][kitty], [wcwidth][wcwidth],
  [Blessed][blessed], then [validation][validation].
- **Designing a retained renderer:** [Kitty][kitty], [foot][foot],
  [OpenTUI][opentui], [libvaxis][libvaxis].
- **Rendering Markdown headings:** [presenterm][presenterm], [mdfried][mdfried],
  then the [Sparkles proposal][proposal].
- **Considering shaping dependencies:** [osc66][osc66] and [concepts][concepts].

## Sources

- [Protocol and shared vocabulary][concepts].
- [Cross-subject comparison and evidence limits][comparison].
- [Broader TUI library catalog][parent] and [existing backend-seam study][seam].

<!-- References -->

[concepts]: ./concepts.md
[kitty]: ./kitty.md
[kitty-introduction]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/changelog.rst#L1196-L1206
[ghostty-parser-introduction]: https://github.com/ghostty-org/ghostty/commit/916b99df7c65b79ed8970d12f7bad06c67bc77c4
[ghostty]: ./ghostty.md
[foot]: ./foot.md
[libvaxis]: ./libvaxis.md
[opentui]: ./opentui.md
[blessed]: ./blessed.md
[wcwidth]: ./wcwidth.md
[presenterm]: ./presenterm.md
[osc66]: ./osc66.md
[mdfried]: ./mdfried.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./sparkles-proposal.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[parent]: ../index.md
[seam]: ../../ui-backend-seam/libvaxis.md
