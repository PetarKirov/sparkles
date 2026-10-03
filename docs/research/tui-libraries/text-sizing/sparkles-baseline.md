# Sparkles Text Sizing Baseline (D)

Sparkles carries a font-size hint, but does not yet have a shared contract for
text whose painted footprint occupies multiple terminal cells or rows.

**Last reviewed:** September 14, 2026.

| Property           | Baseline                                                                     |
| ------------------ | ---------------------------------------------------------------------------- |
| Language           | D, with Ghostty's Zig implementation behind ImportC                          |
| Category           | Source-derived baseline for the [research proposal][proposal]                |
| Geometry           | Integer UI cells; backend conversion to pixels or terminal cells             |
| Existing size hint | `TextStyle.fontScale`, percentage, default `100`                             |
| Evidence           | Focused source inspection; no runtime probes or benchmarks run for this page |
| Status             | Research, not an accepted specification or delivered sizing feature          |

## Overview

### What the stack solves

The shared pipeline already separates widgets, layout, display-list construction,
and painting. Source identity is independent of presentation in rich spans.
Terminal rendering additionally has a retained grid and a byte-stream diff.
These are useful foundations, but none makes per-run scaling a paint-only change.

The existing [layout implementation][layout] states:

> Every extent is an integer cell

That is the important constraint: larger ink needs a measured footprint, not just
a larger texture rectangle. See [concepts][concepts] for the distinction between
glyph size, advance, occupied cells, line height, and protocol packing.

### Design philosophy

Keep base text processing independent of UI policy; let shared layout own geometry;
let backends realize resolved geometry. A terminal emulator receiving arbitrary VT
bytes is a different consumer from a widget renderer producing those bytes.
The [comparison][comparison] and [validation matrix][validation] keep these claims
separate from visual demonstrations.

## How It Works Today

### Base escape scanning and visible text

[`escapeLength` and `byAnsiToken`][ansi] treat an OSC sequence as one escape span,
through BEL or ST, including its payload. An unterminated string consumes the
remaining input. The scanner intentionally answers framing, not OSC semantics.

[`byGraphemeCluster` and `visibleWidth`][grapheme] use that framing: escape spans
have width zero. Consequently, a well-framed OSC 66 packet's printable payload
currently contributes **zero** visible width. This is source-derived behavior,
not a terminal experiment. OSC 8 works differently because its visible label is
outside the escape; that existing test does not establish OSC 66 support.

[`writeWrappedText`][base-wrap] measures graphemes and preserves SGR and OSC 8
continuity across inserted newlines. [`truncateField`][width] also walks grapheme
clusters. [`unstyle`][unstyle] copies only non-escape tokens, so it drops an OSC 66
payload rather than extracting its text. Changing only `visibleWidth` would leave
wrapping, truncation, and plain-text export inconsistent.

The required delta is a semantic text layer over escape framing: recognized sized
payloads must expose visible text, metadata, and original source-byte positions.
Unknown OSC commands must remain opaque zero-width controls. Source spans must
distinguish packet framing from payload bytes and synthetic output characters.

The [OSC 66 specification][protocol] supplies the wire rules;
[wcwidth][wcwidth] supplies the adjacent width-processing comparison.
Neither licenses executing controls found inside an untrusted text payload.

### UI style transport is ahead of measurement

[`TextStyle` and `Visual`][style] already contain `fontScale = 100`.
[`Ink` and the canvas conversions][canvas] carry it onward, and display-list
tests assert that it survives style resolution. This is transport evidence,
not evidence that any particular painter honors it.

[`CellMeasure`][layout] exposes only `width(text)`. There is no style argument,
resolved fallback, line-height result, or source map in that measurer contract.
`Frame` records `rect`, `lines`, and `spanLines`; wrapped slices are shared with
painting, but their individual advances and vertical footprints are not recorded.

[`buildDisplayList`][display-list] stacks wrapped text with height `1` and row
offset `li`. Rich spans advance by `cellsOf(span.text)` and also receive height
`1`. That independently reconstructs geometry after layout.

Its style fallback is especially relevant to headings: a span inherits the node's
whole `TextStyle` only when `span.textStyle == TextStyle.init`; otherwise the span's
whole style wins. An italic or code span therefore cannot be assumed to inherit
an eventual parent scale merely because it changes only one apparent property.

Theme defaults, node overrides, span inheritance, and an explicit reset to normal
size need distinguishable semantics. The [theme source][theme] and [theme spec][theme-spec]
are integration points, not proof of an existing per-property cascade.

### Codepoints are not graphemes

[`cellsOf`][geometry] counts UTF-8 lead bytes, one per codepoint. It does not
perform terminal grapheme measurement. Its comments describe a single width
authority, but [base grapheme measurement][grapheme] and the [grid adapter][grid-canvas]
have different mechanics. A CJK character, combining sequence, or ZWJ emoji is
enough to make this distinction material even at scale `100`.

The [UI wrapping engine][ui-wrap], display-list offsets, and selection code must
agree on one resolved run layout. Replacing the helper alone would not fix callers
which still step through bytes/codepoints to invert a cell position.

The module documentation in `libs/ui/src/sparkles/ui/geometry.d` explicitly
defers this upgrade to hue's [DEF7][width-deferred] and [FNT6][font-contract].
Those older contracts must be reconciled: shared grapheme geometry is a blocking
prerequisite for layout and selection at **all** sizes, including normal size,
not a separate advanced-shaping dependency. Reuse base grapheme/width primitives
and inventory both width walks and inverse cell-to-source walks before migration.
The existing [LAY5][layout-contract] measurement contract and
[MIG5][migration-contract] migration already require grapheme-correct shared
widths; reconcile their delivery status with this prerequisite rather than
creating a competing width authority.

The [protocol][protocol] distinguishes another boundary: on a capable terminal,
non-ASCII text needs explicit per-grapheme `w` declarations to convey the client's
chosen widths. That is not author-opt-in multi-grapheme packing; each grapheme
remains independently addressable. Without width-protocol support, ordinary
Unicode output cannot promise exact client/terminal width parity. The delivery
plan's M0 gate must declare a mismatch policy and the weaker fallback guarantees,
rather than treating the client's width table as control over the receiving sink.

### Source identity and shared frames

[`documentRows`][state] builds per-visual-row text and source ranges from `Frame`.
It excludes synthetic spans from `sourceText`, which is already the right split
for heading icons, bullets, and gutters. Its wrapped-row walk still uses one row
per line, and `sourceOffsetAt` reconstructs column-to-byte mapping by codepoint
strides. Selection geometry separately computes widths with `cellsOf`.

Sized text needs the resolved run positions in the shared frame result, including
cluster boundaries, source-byte mappings, row coverage, and effective clips.
Otherwise painting, source selection, hover, and copy can disagree even when the
outer widget rectangle is correct. Covered rows must not duplicate copied text.

This affects scroll anchors and gutters too. [Hue's `viewer_model.d`][viewer-model]
derives document rows, fold markers, gutter channels, and source-based anchors
from layout. It has a preliminary content-layout pass before gutter construction.
Both passes must use the same resolved sizing and width policy.

### Host measurement is not automatically injected

[`presentApp`][run-app] currently calls
`layout(snap.tree, Constraints(sz.width, sz.height))` with the default measurer.
The existence of canvas `measure` methods does not wire them into this path.
A host capability must reach layout before frame construction, including recording
and headless hosts, without requiring applications to name a backend.

## Backend Analysis

### Retained TUI

[`GridCanvas`][grid-canvas] paints into [`GridT`][cell], then [`Screen`][render]
diffs that grid against the previous picture. `CellT` stores inline grapheme bytes,
width `0/1/2`, style, and hyperlink identity. Its equality compares those values.
It has neither a multi-row run owner nor an arbitrary rectangular footprint.

The inline byte bound also matters: `setBytes` truncates to `MaxBytes`. The source
calls this acceptable for common scenes; sized payload storage cannot inherit
that assumption and silently cut UTF-8 or a long grapheme cluster.

`Screen` skips ordinary wide-glyph continuations and uses hardware scroll detection
through `scrollOptimize`. Those are one-row cell invariants, not generic guarantees
for a tall OSC 66 owner. A change under an old tall glyph may require repainting
its owner outside the initially dirty cell or row.

The proposed retained extension therefore includes a side arena for exceptional
runs, lead/continuation ownership, content-based equality across frames, and damage
closure over **both old and new** footprints. Reused arena indices are not identity.
It must preclear stale covered cells, potentially with ECH under explicit style and
cursor positioning, before re-emitting owners. It must emit no continuation text.
In particular, a replacement write into an old owner's covered lower row is
displaced past that owner even with DECAWM disabled: positioned/styled ECH must
precede the replacement, not merely follow an absolute cursor move. Producers
must preflight footprints against screen dimensions and active margins because
oversized blocks can be discarded. Resize must recompute fit, clipping, and
damage for exposed old owners and their coverage; prior owners may have been lost.

Hardware scrolling must initially be disabled when relevant old or new frames
contain sized footprints. This is a proposed correctness restriction, not existing
behavior. Compare [libvaxis][libvaxis] and [OpenTUI][opentui]; the
[retained-render benchmark baseline][render-bench] remains a performance guardrail.

### Raylib

[`RaylibCanvas.measure`][raylib-canvas] returns `Size(cellsOf(text), 1)`.
The adapter carries `fontScale` but the current run drawing path does not use it
to establish a larger layout footprint. [`drawText`][draw] places codepoints at
the global `FontSet.cellW` advance and draws at `fonts.size()`.

The lower-level [`drawGrapheme`][draw] already accepts a font size and computes a
texture scale against `font.baseSize`. That is a useful rendering capability,
not complete sized-run support: layout, baseline, routing, clipping, decorations,
and background extent still belong to the caller.

[`FontSet`][font-set] distinguishes logical font size, atlas raster size, and base
cell metrics; it reloads fonts and grows glyph sets through pending requests.
A per-run scale must not call global `reload` to resize the whole application's
grid. Atlas sizing/cache policy needs separate quality and memory evaluation,
including DPI, fallback faces, real bold/italic, and on-demand glyph growth.

### Secondary cells and HTML

[`ui/interp/cells.d`][interp-cells] is another cell renderer, not an alias of the
retained TUI. [Hue's static output paths][hue-app] use `CellGrid`, including markdown
preview for `--ansi`. Updating only `ui-tui` would leave this consumer behind.
Its measurement also advertises height `1` with `cellsOf` width.

The [styled HTML emitter][html] already emits a percentage font size from
`Visual.fontScale`; the [semantic HTML emitter][html-semantic] is a separate path.
Their cell-like dimensions and offsets use `ch`/`lh` (and some `em` spacing).
Those units depend on CSS font context, so nested scaling can accidentally scale
geometry twice. Browser font sizing is not evidence of shared layout parity.

Both emitters need an explicit choice between semantic browser reflow and exact
base-cell placement, with tests for inheritance, clips, and source order.
The [Blessed comparison][blessed] illustrates native OSC 66 formatting with
plain-text fallback, not cell-art enlargement.

## Consumer Analysis

### Source-view headings and hue configuration

[`MdViewOptions` and heading construction][markdown] already provide base style,
theme accents, rich inline content, icons, links, and source-anchored folds.
Headings set bold on `opt.baseStyle`; themed headings create an icon span and a
full-width background band. They do not select a scale per heading level.

The change belongs in source-view options, not a GUI-only heading draw shortcut.
Rich icons, links, emphasis, inline code, hanging indents, folded heading faces,
and appended fold chips all need a deliberate inheritance/reset policy.
Gutter markers must follow visual coverage without becoming part of copied source.

Hue's configuration path includes [`settings.d`][settings], [`cli.d`][cli],
[`viewer_model.d`][viewer-model], [`app.d`][hue-app], [`gui.d`][gui], and
[`tui.d`][hue-tui]. Persisted settings and live changes must invalidate layout,
not merely request repaint. Static ANSI, interactive TUI, GUI, and HTML need
consistent defaults and explicit unsupported-backend fallback.

[Presenterm][presenterm] and [mdfried][mdfried] are consumer comparisons; their
presentation choices inform defaults but do not replace Sparkles source mapping.

### TerminalView is a receiving terminal

[`TerminalView`][component] hosts a Ghostty VT, PTY, resize/reflow, selection,
hover, and redraw decisions. [`core.d`][terminal-core] resolves cell appearance
and paints the pixel terminal at base `cellWidth`/`cellHeight` positions, including
selection/hover inversion and dirty-state clearing.

[`cell_paint.d`][cell-paint] is a second terminal painter for embedded canvases.
It currently emits only `rc.codepoints[0]`; its own documentation identifies loss
of combining marks and ZWJ sequences. Embedded selection and hover inputs are
inert there. A sized-text implementation must address this path explicitly,
not claim terminal-in-terminal support from the pixel renderer alone.

### Ghostty parser support is a blocker, not delivery

The checked Sparkles `flake.lock` pins Ghostty to
`4749c4e93731067049bfbf2e4572061cef2bdd17` (the old/pinned SHA).
Its [OSC 66 parser][ghostty-old-parser] recognizes scale, width, fractions,
alignment, and safe UTF-8 payloads, but says:

> We don't currently support encoding this to C in any way.

More fundamentally, its [stream dispatcher][ghostty-old-stream] groups
`kitty_text_sizing` under `unimplemented OSC callback`. The newer inspected local
checkout, `0c2a290d3a3e2a599be3a43435d778a5896667ee`, retains both the
[parser/C limitation][ghostty-new-parser] and [unimplemented dispatch][ghostty-new-stream].
These are two inspected revisions, not a claim about every future Ghostty build.

Updating the pin alone therefore does not establish VT storage, cursor advance,
erase/overwrite, scrollback, reflow, selection, dirty regions, or render-state C
metadata. The [Ghostty survey][ghostty] tracks that distinction; [kitty][kitty]
and [foot][foot] provide receiving-terminal comparisons.

### ANSI fences and platform dependencies

[`gui_ansi.d`][gui-ansi] feeds fences into an off-screen VT and converts its cells
to [`AnsiSpan`/`AnsiLine`][ansi-model]. Dimensions come from raw byte counts and
newline counts, capped at `4000`; it also translates LF to CRLF. Newline counts
do not reserve tall footprints. Escape byte length is not a layout oracle.

`AnsiSpan` currently carries text, colors, default-color flags, and attributes,
not run dimensions or occupancy. Supporting OSC 66 fences requires a bounded
geometry policy and preservation of sized metadata after decoding, in addition
to a working Ghostty implementation. Protocol payloads must not be rewritten by
blind newline translation.

Desktop `nix/packages/libghostty-vt.nix` and Android
`nix/packages/android/libghostty-vt.nix` both consume the Ghostty input. Any upstream
patch or pin update must build both dependency paths; the [Android contract][android]
and [TerminalView spec][terminal-spec] are existing constraints, not sizing specs.

## Strengths and Weaknesses

- Existing escape framing, grapheme utilities, and source spans provide reusable foundations.
- Shared frames and a backend-neutral host offer a place to centralize resolved geometry.
- Scale metadata already travels through the UI style vocabulary.
- Independent measurement and hit-test reconstruction currently undermine parity.
- Retained grid ownership is one-row oriented; safe tall-footprint damage is new work.
- Receiving-terminal support is blocked below the Sparkles painter, in Ghostty itself.

## Decisions and Remaining Evidence

| Decision to investigate         | Rationale                                              | Cost or unresolved question                        |
| ------------------------------- | ------------------------------------------------------ | -------------------------------------------------- |
| Exact integer footprints first  | Matches cell geometry and makes overlap testable       | Fractions still need an explicit packing contract  |
| Fallback before layout          | Keeps painting and input in the same coordinate system | Capability changes invalidate cached layout        |
| Shared source-mapped run layout | Avoids three independent width walks                   | Extra metadata and lifetime design                 |
| Exceptional side arena          | Preserves ordinary-cell density                        | Equality and damage cannot depend on arena indices |
| Separate advanced shaping       | Scaling is not bidi, ligatures, or proportional layout | Some typography remains deliberately unsupported   |

No runtime result is claimed here. The [proposal][proposal] schedules contract
tests, runnable demos, receiving-terminal probes, and performance gates rather
than treating the presence of source identifiers as a passing integration test.

## Sources

- Primary Sparkles sources: [base framing][ansi], [layout][layout], [state][state],
  [retained rendering][render], [Raylib drawing][draw], and [terminal core][terminal-core].
- Dependency evidence: pinned and newer Ghostty [dispatch][ghostty-old-stream]
  [revisions][ghostty-new-stream], inspected rather than executed.
- Context: [concepts][concepts], [comparison][comparison], [validation][validation],
  and the [proposed milestones][proposal].

<!-- References -->

[proposal]: ./sparkles-proposal.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[protocol]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[wcwidth]: ./wcwidth.md
[kitty]: ./kitty.md
[ghostty]: ./ghostty.md
[foot]: ./foot.md
[libvaxis]: ./libvaxis.md
[opentui]: ./opentui.md
[blessed]: ./blessed.md
[presenterm]: ./presenterm.md
[mdfried]: ./mdfried.md
[ansi]: ../../../../libs/base/src/sparkles/base/text/ansi.d
[grapheme]: ../../../../libs/base/src/sparkles/base/text/grapheme.d
[base-wrap]: ../../../../libs/base/src/sparkles/base/text/wrap.d
[width]: ../../../../libs/base/src/sparkles/base/text/width.d
[unstyle]: ../../../../libs/core-cli/src/sparkles/core_cli/term_unstyle.d
[style]: ../../../../libs/ui/src/sparkles/ui/style.d
[canvas]: ../../../../libs/ui/src/sparkles/ui/canvas.d
[theme]: ../../../../libs/ui/src/sparkles/ui/theme.d
[layout]: ../../../../libs/ui/src/sparkles/ui/layout.d
[geometry]: ../../../../libs/ui/src/sparkles/ui/geometry.d
[ui-wrap]: ../../../../libs/ui/src/sparkles/ui/wrap.d
[display-list]: ../../../../libs/ui/src/sparkles/ui/display_list.d
[state]: ../../../../libs/ui/src/sparkles/ui/state.d
[run-app]: ../../../../libs/ui-app/src/sparkles/ui_app/run_app.d
[grid-canvas]: ../../../../libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d
[cell]: ../../../../libs/tui/src/sparkles/tui/cell.d
[render]: ../../../../libs/tui/src/sparkles/tui/render.d
[raylib-canvas]: ../../../../libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d
[draw]: ../../../../libs/raylib-text/src/sparkles/raylib_text/draw.d
[font-set]: ../../../../libs/raylib-text/src/sparkles/raylib_text/font_set.d
[interp-cells]: ../../../../libs/ui/src/sparkles/ui/interp/cells.d
[html]: ../../../../libs/ui/src/sparkles/ui/interp/html.d
[html-semantic]: ../../../../libs/ui/src/sparkles/ui/interp/html_semantic.d
[markdown]: ../../../../libs/source-view/src/sparkles/source_view/markdown.d
[settings]: ../../../../apps/hue/src/settings.d
[cli]: ../../../../apps/hue/src/cli.d
[viewer-model]: ../../../../apps/hue/src/viewer_model.d
[hue-app]: ../../../../apps/hue/src/app.d
[gui]: ../../../../apps/hue/src/gui.d
[hue-tui]: ../../../../apps/hue/src/tui.d
[component]: ../../../../libs/terminal-view/src/sparkles/terminal_view/component.d
[terminal-core]: ../../../../libs/terminal-view/src/sparkles/terminal_view/core.d
[cell-paint]: ../../../../libs/terminal-view/src/sparkles/terminal_view/cell_paint.d
[gui-ansi]: ../../../../apps/hue/src/gui_ansi.d
[ansi-model]: ../../../../apps/hue/src/ansi_model.d
[theme-spec]: ../../../specs/ui/theme.md
[width-deferred]: ../../../specs/hue/feature-requirements.md
[font-contract]: ../../../specs/hue/gui.md#font-fnt
[layout-contract]: ../../../specs/ui/layout.md
[migration-contract]: ../../../specs/ui/migration.md
[render-bench]: ../../../specs/tui/render-bench-baseline.md
[terminal-spec]: ../../../specs/ui-app/terminal-view.md
[android]: ../../../specs/hue/android.md
[ghostty-old-parser]: https://github.com/ghostty-org/ghostty/blob/4749c4e93731067049bfbf2e4572061cef2bdd17/src/terminal/osc/parsers/kitty_text_sizing.zig
[ghostty-old-stream]: https://github.com/ghostty-org/ghostty/blob/4749c4e93731067049bfbf2e4572061cef2bdd17/src/terminal/stream.zig
[ghostty-new-parser]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/osc/parsers/kitty_text_sizing.zig
[ghostty-new-stream]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/stream.zig
