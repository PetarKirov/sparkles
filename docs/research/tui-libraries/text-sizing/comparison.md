# Text-sizing comparison

The [catalog][catalog] separates protocol producers, text libraries, and terminal
receivers. Comparing them under a single "supports OSC 66" flag hides the most
important architectural boundaries.

**Last reviewed:** September 14, 2026

## At a glance

| Subject                  | Actual capability at inspected revision                | Most useful precedent                                     | Principal limitation                                                        |
| ------------------------ | ------------------------------------------------------ | --------------------------------------------------------- | --------------------------------------------------------------------------- |
| [Kitty][kitty]           | Full receiver with multicells and fractional rendering | Ownership, editing, reflow, selection, independent oracle | Implementation limits and tolerant parsing differ from protocol constraints |
| [Ghostty][ghostty]       | Parser only                                            | Explicit evidence of receiver dependency boundary         | Neither execution nor C multicell metadata                                  |
| [foot][foot]             | Width-only receiver                                    | Whole-payload horizontal storage and reflow               | No enlarged/multirow text                                                   |
| [libvaxis][libvaxis]     | Width and sizing emitter                               | Structured scale fields and independent flags             | Footprint/equality/clipping risks                                           |
| [OpenTUI][opentui]       | Width emitter; scale detection only                    | Shared wrap/measure engine and retained synchronization   | No variable-height text layout                                              |
| [Blessed][blessed]       | Convenience writer and probe                           | Separate width/scale observations                         | Unsafe payload gaps and combined emission gating                            |
| [wcwidth][wcwidth]       | Semantic parsing, width and extraction                 | Printable OSC classification                              | Explicit-width clipping and wrapping gaps                                   |
| [presenterm][presenterm] | Integer-sized document flow                            | Effective size before layout; row heights                 | Incomplete grapheme/payload/clipping guarantees                             |
| [osc66][osc66]           | Font-derived explicit width                            | Allocation from shaping advances                          | Font mismatch, RTL assumptions, no safe fallback                            |
| [mdfried][mdfried]       | Native/image/plain headings                            | Explicit alternate presentation paths                     | Raw escape injection and separate wrap/emission arithmetic                  |

## Per-dimension comparison

### Protocol and API

[Foot][foot] proves that width-only support is a useful implemented subset.
[Ghostty][ghostty] proves that recognizing the OSC command is not executing it.
[OpenTUI][opentui] adds a third boundary: observing terminal scale support does not
mean the toolkit can lay out scaled text. Public capability reporting should name
the layer and operation, not use a broad feature label.

### Measurement and geometry

[Presenterm][presenterm] has the clearest sequential-layout precedent: effective
size influences widths and line heights before painting. [OpenTUI][opentui] shares
wrapping logic between speculative measurement and committed layout, while keeping
their state separate. Sparkles needs both properties plus source-to-geometry data.

[wcwidth][wcwidth] measures horizontal allocation but not occupied height.
[mdfried][mdfried] independently calculates wrap budgets and emitted chunk widths,
which can disagree for CJK. [osc66][osc66] derives advances from one font, but the
receiver may render another font. None justifies deriving layout from ink scale
alone.

### Capability and fallback

[Presenterm][presenterm] demonstrates the architectural benefit of normalizing
unsupported sizes before layout, but the capability result must be reliable:
its combined-displacement probe would misclassify foot's two ordinary spaces as
integer scaling support. This is a source-derived false-positive case, not an
executed probe; the study also documents a title-override fallback exception.
[Blessed][blessed] exposes separate probe results but gates output on their combined
truthiness. [OpenTUI's merged fixes][opentui] show that startup CPRs and loose
coordinate checks produce false positives. Force-off must suppress probing itself.

No surveyed probe should be copied without auditing input ownership, deadlines,
screen edges, unrelated input preservation, partial results, and cleanup.

### Layout and clipping

[Kitty][kitty] provides terminal placement, not a pane-local clipping API.
[Presenterm][presenterm] rejects bottom-overflowing runs; [mdfried][mdfried] avoids
partially visible headings; [OpenTUI][opentui] already rejects partly clipped
ordinary wide graphemes. These support a conservative whole-object clipping policy
for the first Sparkles terminal implementation, not arbitrary partial rendering.

[wcwidth's explicit-width clip][wcwidth] illustrates a different problem: knowing a
block's total width does not identify which substring occupies a selected column.

### Retained state and interaction

[Kitty][kitty] is the reference for two-dimensional ownership and editing.
[Foot][foot] demonstrates a side allocation for uncommon whole-payload text while
keeping ordinary cells compact. [OpenTUI][opentui] distinguishes composition writes
from retained-mirror synchronization. [Libvaxis][libvaxis] shows why scale must be
stored and compared, and why rebuilding skipped coverage only during redraw is
insufficient.

[mdfried][mdfried] places raw commands inside one nominal cell and skips the rest.
That can demonstrate headings but is not an adequate correspondence invariant for
a reusable widget compositor, source selection, or terminal embedding.

### Safety and evidence

Several emitters lack full safe-UTF-8 checks. Scalar-sized chunks do not bound byte
length; zero-width text defeats width-based limits. [Foot's empty-payload fix][foot]
shows the importance of empty-input cases even in receivers.

The [validation ledger][validation] separates byte-level examples, executed library
reproductions, source-inspected tests, and proposed terminal oracles. Agreement
between a writer and a model built from the same helper is not independent proof.

## Consensus and recommended standard

There is no complete cross-project consensus implementation. The evidence supports
these common requirements rather than claiming every subject already meets them:

1. Separate allocation, ink scale, source identity, and cursor position.
2. Treat text-bearing OSC records differently from nonprinting controls.
3. Keep explicit-width payloads atomic unless an internal layout is actually known.
4. Resolve fallback before measurement and wrapping.
5. Keep terminal probing outside pure text writers and inside input ownership.
6. Represent retained ownership across unchanged frames and footprint transitions.
7. Validate complete payloads before emission and preserve grapheme boundaries.

## Architectural trade-offs

| Choice                            | Benefit                                                               | Cost or condition                                                     |
| --------------------------------- | --------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Width-only milestone              | Foot supplies an independent receiver; fixes allocation disagreements | Does not fulfill enlarged-heading goals                               |
| Integer scales first              | Exact base-cell geometry, straightforward line height                 | Fractional ink and packing still need explicit policy                 |
| Shared laid-out runs/clusters     | Paint, selection, wrap and hit testing agree                          | Frame storage and cache invalidation become explicit responsibilities |
| Multicell side arena              | Ordinary cells need not inline large payloads                         | Ownership, equality, copying and lifetime rules must be tested        |
| Whole-object clipping             | Prevents unintended terminal wrapping/scrolling                       | Partially visible text is omitted rather than pixel-scissored         |
| Erase-before-paint damage closure | Correct replacement of intersecting objects                           | More work and output than cell-local diffing                          |
| Upstream Ghostty execution        | One VT owns editing, scrollback and selection                         | Substantial dependency work with desktop/Android packaging            |
| Separate shaping workstream       | Keeps base protocol support lightweight                               | Advanced GPU typography remains a later deliverable                   |

## Sparkles delta

The [baseline][baseline] gives exact source locations; this table summarizes the
distance to the proposed capability, not delivered status.

| Capability                | Current boundary                                               | Proposed change                                                |
| ------------------------- | -------------------------------------------------------------- | -------------------------------------------------------------- |
| Printable OSC payloads    | All escapes treated as zero-width/strippable in relevant paths | Shared semantic text-unit parsing and readable extraction      |
| Safe writer               | No dedicated OSC 66 writer                                     | Validated metadata and bounded payload emission                |
| Sized widget layout       | `fontScale` preserved but fixed-size measurement               | Style-aware shared text geometry and inheritance               |
| Text interaction          | Unit-row/codepoint placement assumptions                       | Reuse cluster/source geometry and effective clips              |
| Retained terminal picture | Horizontal width 0/1/2 cells                                   | Rectangular owners, continuations and damage closure           |
| GPU sizing                | Fixed whole-run drawing despite scalable primitive             | Resolved advances and ink scale; bounded font caches if needed |
| Markdown headings         | Existing rich semantics, no size policy                        | Theme/options-driven sizes across GUI/TUI/ANSI                 |
| Terminal reception        | Ghostty parser-only dependency                                 | VT execution and C metadata before adapter work                |
| ANSI fences               | Fixed cell-to-line projection                                  | Preserve spatial text objects and dimensions                   |

## Sources and next steps

Read the [proposal][proposal] for staged delivery and independent acceptance gates.
The [concepts][concepts] page defines shared terms. Individual studies preserve
revision provenance, quoted evidence, limitations, and upstream issue states.

<!-- References -->

[catalog]: ./index.md
[concepts]: ./concepts.md
[kitty]: ./kitty.md
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
[validation]: ./validation.md
