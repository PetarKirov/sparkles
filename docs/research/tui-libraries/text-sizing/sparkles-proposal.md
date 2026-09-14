# Sparkles Text Sizing Proposal

A research plan for source-mapped, backend-neutral sized text, from base utilities
through markdown headings to receiving terminals and ANSI fences.

**Last reviewed:** September 14, 2026.

> [!IMPORTANT]
> This is **not an accepted specification**. No milestone below is delivered by
> this document. Implementation, API names, defaults, and performance budgets
> require separate acceptance and evidence. The [baseline][baseline] is derived
> from inspected sources; no runtime sizing probes were run for this proposal.

| Property           | Proposed direction                                                    |
| ------------------ | --------------------------------------------------------------------- |
| Primary constraint | Measure, paint, hit-test, and copy from one resolved layout           |
| Initial scope      | Exact integer cell footprints and safe normal-size fallback           |
| Extended scope     | Explicit fraction/width packing; receiving-terminal support           |
| Non-goal           | Bundling bidi, ligatures, or general proportional shaping into sizing |
| Delivery model     | M0 feasibility in parallel; M1 through M6 gated independently         |
| Evidence policy    | Source citations now; independent executable oracles before delivery  |

## Why This Is Cross-Cutting

The [baseline][baseline] identifies two independent problems: emitting sized text
from a widget tree, and interpreting incoming sized text in a terminal emulator.
The second cannot be solved by teaching the first to write OSC 66.

[`TextStyle.fontScale`][style] already exists, but [`Frame`][layout] has no resolved
run geometry, [`buildDisplayList`][display-list] reconstructs one-row advances,
and [`sourceOffsetAt`][state] reconstructs codepoint positions. The host's
[`presentApp`][run-app] uses the default measurer. These seams must change together.

The receiving dependency is not ready merely because it parses the protocol.
At old/pinned Ghostty SHA `4749c4e93731067049bfbf2e4572061cef2bdd17`, the
[stream handler][ghostty-old] leaves `kitty_text_sizing` unimplemented. The newer
inspected SHA `0c2a290d3a3e2a599be3a43435d778a5896667ee` does [the same][ghostty-new].
The [parser][ghostty-parser] says, verbatim:

> We don't currently support encoding this to C in any way.

That requires an early feasibility investigation, not a surprise in the final
terminal milestone. See [Ghostty][ghostty], [kitty][kitty], and [foot][foot] for
the receiving side, and [libvaxis][libvaxis]/[OpenTUI][opentui] for retained output.

## Proposed Contract

### Units, sizes, and fallback

Keep layout coordinates in base cells. Separate requested typography from resolved
advance, occupied rectangle, baseline/alignment, and supported backend capability.
A percentage in `fontScale` is a request, not a measured cell count.

Start with normal size and exact integer scales. For a scale `s`, a simple
grapheme's ordinary cell advance can be multiplied by `s`; the line must reserve
the corresponding integer height. This simple case is not the general formula
for explicit width or fractional packing in [the OSC 66 specification][protocol].

Resolve unsupported sizes to a declared fallback **before layout**, normally
ordinary-size text with semantic emphasis retained. Do not reserve a tall box and
then secretly draw one row, or measure one row and draw large ink over siblings.
Capability or theme changes invalidate resolved layout and source-hit geometry.

Use exact integer/rational arithmetic for protocol dimensions. Validate ranges,
overflow, empty payloads, and maximum footprint before allocating or multiplying.
Reject unsupported requests or resolve them to fallback explicitly; no unchecked
percentage-to-protocol conversion or silent integer truncation.

### Fractions and explicit-width packing

Fractions remain in the plan even if the first enabled rendering tier is integer
only. Record numerator/denominator, integer scale, alignment, and explicit width
separately. Do not reduce them to a float and then round each glyph independently.

An explicit-width or fractionally packed payload is an **atomic layout unit**:
its total advance/footprint belongs to the whole payload. Splitting it into OSC
packets per grapheme, per style span, per diff cell, or per wrap segment can change
packing and therefore changes meaning. Adjacent independently rounded units are
not necessarily equivalent to one packed unit.

M0 must choose an oversize-unit policy: wrap before the unit, clip as a whole,
or resolve a documented fallback and re-layout. Never split the payload silently.
If protocol-size limits force segmentation, expose that as a changed layout
operation and prove equivalence for the permitted subset.

Reserve the complete occupied base-cell rectangle even when fractional ink is
smaller. Define horizontal/vertical alignment within it and source-hit behavior
for padding. Selection may need whole-unit granularity when no exact internal
advance oracle exists; do not invent fractional per-character hit positions.

### Safe payloads and source-byte maps

Keep [`escapeLength`][ansi] as framing. Add semantic recognition of sized payloads
above it so [grapheme iteration][grapheme], [wrapping][base-wrap],
[truncation][width], and [`unstyle`][unstyle] agree about their visible text.
Unknown OSC payloads remain controls, not newly visible labels.

Only validated escape-safe UTF-8 belongs inside an emitted OSC 66 payload.
Handle ESC, BEL, ST, C0/C1 controls, tabs, and newlines explicitly; never embed raw
terminal controls or recursively interpret a payload as arbitrary ANSI.
Emit SGR and OSC 8 state outside packets. Re-establish and close surrounding
state at real run boundaries without changing an atomic packing unit.

Preserve offsets to the original bytes through tokenization, fallback, wrapping,
and truncation. Packet headers/terminators and synthetic ellipses have no source
glyph identity; decoded payload bytes do. Plain export returns text, not protocol
framing. Distinguish this operation from copying the original source verbatim.

Use [wcwidth][wcwidth] and the [validation matrix][validation] as independent
comparisons. A shared bug in width and wrapping is not proof of consistency.

### Theme and style inheritance

Resolve theme defaults, widget style, and rich-span overrides before measurement.
Represent inheritance separately from explicit reset to `100`; do not use
`TextStyle.init` equality as a per-property inheritance mechanism.

An emphasized/link/code span in a heading must not accidentally reset its scale.
Conversely, a fold chip or inline-code policy may intentionally reset size; that
must be expressible without discarding colors, font role, underline, or link ID.
The [theme contract][theme-spec] needs an explicit accepted extension later.

### Shared layout and source interaction

Extend the layout result associated with [`Frame`][layout] to carry resolved runs:
line origins/heights, advances, footprints, style, cluster/source boundaries,
and the clip information required by painting and hit-testing.
The exact representation is open; a second independently measured tree is not.

Reconcile [`cellsOf`][geometry] with grapheme measurement, including normal-size
CJK, combining marks, emoji, and malformed UTF-8 policy. The measurer must accept
resolved style/capability and report height as well as width. Thread it through
[`presentApp`][run-app], recording hosts, and application-owned layout passes.

Make display lists and [`state.d`][state] consume this result. Update
`documentRows`, precise selection, source offsets, link hits, scroll anchors, and
selection rectangles under effective nested clips. Every covered cell resolves
to its owner or an explicit non-content region; continuation rows never duplicate
text in copy output. Preserve synthetic/source distinction for gutters and icons.

## Backend Work

### Retained grid ownership

Preserve the ordinary [`CellT`][cell] fast path with `0/1/2` widths. Investigate a
side arena for exceptional run bytes and metadata, referenced by an owner cell
and its covered continuations. Do not put a large payload into every cell.
Long graphemes must not inherit the current inline-byte truncation behavior.

[`Screen`][render] equality must compare semantic run content and geometry across
frame arenas, not an index or pointer that can be recycled. Include text, scale,
fraction/width packing, alignment, style, links, and footprint. Ordinary frames
must not pay a whole-arena comparison for every unchanged cell.

Compute damage closure over old and new ownership: touching any covered cell
invalidates the relevant owner, and invalidated footprints can intersect other
owners. Close to a fixed point before drawing. Clear stale coverage first with
explicitly positioned, styled ECH or an equivalent verified erase sequence, then
paint surviving/new owners in defined order. Never emit continuation cells as
spaces or repeat their text; that can overwrite the very owner just emitted.

Initially disable hardware-scroll optimization for frames involving sized runs.
Re-enable only after region boundaries, old footprints, exposed rows, and terminal
behavior have independent tests. Partial clips must never emit a whole protocol
object outside the application's clip; choose omission/fallback before layout
where the backend cannot safely represent partial ink.

Apply the resolved model to both [`GridCanvas`][grid-canvas] and the secondary
[`ui/interp/cells.d`][interp-cells] used by `hue --ansi`. One may emit a fresh frame
while the other retains it, but they must not disagree on occupied geometry.

### Raylib and HTML

Use [`drawGrapheme`][draw]'s existing scale capability without globally resizing
`FontSet`. Keep base cell metrics fixed for neighboring text, input, and viewport
size. Add resolved run advances, clipping, baselines, decorations, and background
coverage to [`RaylibCanvas`][raylib-canvas]'s path.

Choose atlas sizing/cache policy with evidence: scaled base atlases may blur;
rasterizing every requested size can explode memory and texture switches.
Bound cached sizes, account for DPI and fallback/bold/italic faces, and preserve
the pending-glyph flush lifecycle in [`FontSet`][font-set].

Audit both [styled HTML][html] and [semantic HTML][html-semantic]. Their `ch`/`lh`
geometry must refer to the intended base context, not multiply dimensions again
under a scaled descendant. Distinguish browser-native reflow from exact cell-layout
export and test each advertised mode. No promise of advanced shaping parity is
made by accepting integer sizing.

### Markdown, terminal, and fences

Add per-heading-level choices to [`MdViewOptions`][markdown], retaining rich
icons, links, emphasis, code, bands, hanging indents, folded faces, and gutters.
Use [Presenterm][presenterm] and [mdfried][mdfried] to evaluate useful defaults;
[Blessed][blessed] illustrates convenience formatting and the risks of
capability gating that does not check the requested feature.

Wire hue through [`settings.d`][settings], [`cli.d`][cli], [`viewer_model.d`][viewer-model],
[`app.d`][hue-app], [`gui.d`][gui], and [`tui.d`][hue-tui]. Resolve persistence,
CLI precedence, live settings invalidation, and disabled/automatic/forced policy.
The viewer's gutter prepass and final layout must share the same measurer.

For incoming VT, extend Ghostty storage and its exposed render-state contract
before consuming metadata in [`TerminalView`][component] and [`core.d`][terminal-core].
Include selection, hover, cursor positions, erase/overwrite, scrolling, resize
reflow, scrollback, dirty closure, and both pixel and [`cell_paint.d`][cell-paint]
renderers. Do not bolt on a parallel OSC parser that bypasses VT state semantics.

For ANSI fences, revise [`gui_ansi.d`][gui-ansi] dimensioning and
[`ansi_model.d`][ansi-model] metadata. Bound rows, columns, payloads, and allocation;
test tall text with no newline and explicit cursor motion. Newline normalization
must not modify an opaque packet. Preserve geometry rather than flattening a
sized owner into ordinary same-style text spans.

Ghostty changes must reach desktop and Android builds through their shared input,
including the Android static archive and ImportC headers. The [Android spec][android]
and [TerminalView contract][terminal-spec] remain constraints on that work.

## Milestones

All rows are proposed, with no delivery status implied. M0's dependency spike runs
in parallel with contract design; later UI milestones need not wait for terminal
implementation if their unsupported-capability behavior is independently correct.

| Stage | Scope                                      | Exit evidence                                                                                              |
| ----- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------- |
| M0    | Contract plus parallel Ghostty feasibility | Accepted units, ownership, payload safety, packing/fallback rules; explicit upstream/patch/no-go decision  |
| M1    | Base semantics and runnable demos          | Width/wrap/truncate/unstyle/source-map fixtures; safe wire output and fallback demos                       |
| M2    | Shared UI geometry and host measurer       | One run-layout authority; source hits, selection, clips, rows, inheritance/reset tests                     |
| M3    | Raylib and gallery                         | Mixed-size rendering, atlas/DPI evidence, gallery parity and normal-text regression gate                   |
| M4    | Retained TUI and probing                   | Capability lifecycle, side-arena equality, damage closure, ECH preclear, continuation and fallback oracles |
| M5    | Source-view and hue                        | Heading options/config through all sinks, rich/folded/gutter source behavior, HTML and secondary cells     |
| M6    | Ghostty, terminal, ANSI fences             | Receiving VT semantics and C metadata, both painters, desktop/Android builds, performance acceptance       |

### M0: Contract and dependency feasibility

Produce a small VT/C-API investigation against both inspected SHAs, not just a
parser unit test. Determine the smallest maintainable Ghostty patch or upstream
path for persistent geometry and render-state exposure. Record whether fractions
are represented faithfully or unavailable. A pin-only update is not an exit gate.

Agree integer limits and ordinary-size fallback first; specify atomic fractions
before enabling them. Record independent expected footprints using [the OSC 66 specification][protocol]
and receiving implementations, with unresolved divergences visible.

### M1-M3: Pure core before backend polish

M1 adds deterministic malformed/control/Unicode fixtures and runnable D demos;
manual terminal output alone is insufficient. M2 eliminates duplicated geometry
walks before M3 enlarges glyphs. Include normal-size behavior so the pre-existing
codepoint/grapheme discrepancy is not hidden beneath the new feature.

M3's gallery should show adjacent normal and tall text, mixed rich spans, CJK,
combining marks, links, clipping, and a deliberately unsupported-size fallback.
Record geometry separately from screenshots: pixels cannot prove copy behavior.

### M4-M5: Terminal output and consumer policy

Probe capabilities through the existing terminal lifecycle, not a competing stdin
reader. Correlate replies, bound timeouts, tolerate multiplexers, and restore
cursor/screen state after probes. Unknown support means fallback before layout;
an explicit user override must state its risk. A terminal name is not a proof.

M4 includes ordinary-to-tall, tall-to-ordinary, deletion, movement, overlapping
owners, style/link-only changes, arena reuse, and clipped updates across rows.
M5 checks hue static `--ansi`, TUI, GUI, and both HTML paths, plus live theme/config
changes while source selection, folds, and scroll anchors are active.

### M6: Receiving and performance acceptance

M6 depends on the M0 feasibility outcome; if blocked, report terminal/fence support
as blocked while keeping widget-output claims scoped. Parser recognition or
successful drawing of hand-authored metadata does not satisfy this milestone.

Test incoming byte streams end to end through VT parsing, storage, render-state
extraction, both painters, copy/selection, erase, resize/reflow, and ANSI fences.
Build desktop and Android dependency paths with matching headers and libraries.

## Tests, Performance, and Open Decisions

Use the [validation matrix][validation] as the detailed checklist. Separate pure
geometry fixtures, independent protocol/VT oracles, recording-canvas assertions,
terminal byte replays, screenshots, and real-terminal capability probes.
Environment-dependent probes must report skips, never masquerade as passes.

Benchmark the current [retained renderer baseline][render-bench] and terminal
idle/render/churn scenarios before implementation. Track ordinary-text frame CPU,
allocations, bytes emitted, dirty-cell amplification, arena memory, texture memory,
atlas reloads, and worst-case large/overlapping runs. Measure debug tests separately
from checked artifacts; do not claim a faster parser from a rendering benchmark.

Set numeric budgets during M0 from repeatable baselines, before selecting a storage
design. Gate each backend at introduction and rerun at M6. Any material ordinary-
text regression needs profiling and explicit acceptance; disabling scrolling is
a known initial cost, not permission to omit scroll-heavy measurements.

| Open decision                     | Risk to resolve before acceptance                                              |
| --------------------------------- | ------------------------------------------------------------------------------ |
| Per-property style representation | Inherit and explicit normal-size reset must remain distinguishable             |
| Packed-unit source hits           | Exact internal advances may be unavailable; define atomic selection            |
| Partial terminal clips            | Protocol output may paint outside the requested region                         |
| Capability changes                | Stale measurements can corrupt input and retained damage                       |
| Side-arena ownership/lifetime     | Recycled IDs can hide content changes or retain excessive memory               |
| Atlas policy                      | Blur versus memory, rasterization latency, and texture churn                   |
| Ghostty maintenance               | Upstream availability versus a carried patch on two platforms                  |
| Heading defaults                  | Useful hierarchy without surprising scroll/copy or unsupported terminals       |
| Advanced shaping                  | Separate bidi/ligature/proportional work must not silently widen this contract |

## Sources

- [Source-derived baseline][baseline] inventories the actual Sparkles integration seams.
- [Concepts][concepts], [comparison][comparison], and [validation][validation] define
  the shared research vocabulary and independent evidence expectations.
- [OSC 66 specification][protocol], [kitty][kitty], [Ghostty][ghostty], [foot][foot],
  [libvaxis][libvaxis], [OpenTUI][opentui], and [wcwidth][wcwidth] inform mechanics.
- [Presenterm][presenterm], [mdfried][mdfried], and [Blessed][blessed] inform consumer
  choices without being accepted Sparkles design contracts.

<!-- References -->

[baseline]: ./sparkles-baseline.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[validation]: ./validation.md
[protocol]: https://github.com/kovidgoyal/kitty/blob/a54b40978533a3e397c09dcd5229de1a08ad43e7/docs/text-sizing-protocol.rst
[kitty]: ./kitty.md
[ghostty]: ./ghostty.md
[foot]: ./foot.md
[libvaxis]: ./libvaxis.md
[opentui]: ./opentui.md
[wcwidth]: ./wcwidth.md
[presenterm]: ./presenterm.md
[mdfried]: ./mdfried.md
[blessed]: ./blessed.md
[ansi]: ../../../../libs/base/src/sparkles/base/text/ansi.d
[grapheme]: ../../../../libs/base/src/sparkles/base/text/grapheme.d
[base-wrap]: ../../../../libs/base/src/sparkles/base/text/wrap.d
[width]: ../../../../libs/base/src/sparkles/base/text/width.d
[unstyle]: ../../../../libs/core-cli/src/sparkles/core_cli/term_unstyle.d
[style]: ../../../../libs/ui/src/sparkles/ui/style.d
[layout]: ../../../../libs/ui/src/sparkles/ui/layout.d
[geometry]: ../../../../libs/ui/src/sparkles/ui/geometry.d
[display-list]: ../../../../libs/ui/src/sparkles/ui/display_list.d
[state]: ../../../../libs/ui/src/sparkles/ui/state.d
[run-app]: ../../../../libs/ui-app/src/sparkles/ui_app/run_app.d
[cell]: ../../../../libs/tui/src/sparkles/tui/cell.d
[render]: ../../../../libs/tui/src/sparkles/tui/render.d
[grid-canvas]: ../../../../libs/ui-tui/src/sparkles/ui_tui/grid_canvas.d
[interp-cells]: ../../../../libs/ui/src/sparkles/ui/interp/cells.d
[raylib-canvas]: ../../../../libs/ui-raylib/src/sparkles/ui_raylib/raylib_canvas.d
[draw]: ../../../../libs/raylib-text/src/sparkles/raylib_text/draw.d
[font-set]: ../../../../libs/raylib-text/src/sparkles/raylib_text/font_set.d
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
[render-bench]: ../../../specs/tui/render-bench-baseline.md
[terminal-spec]: ../../../specs/ui-app/terminal-view.md
[android]: ../../../specs/hue/android.md
[ghostty-old]: https://github.com/ghostty-org/ghostty/blob/4749c4e93731067049bfbf2e4572061cef2bdd17/src/terminal/stream.zig
[ghostty-new]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/stream.zig
[ghostty-parser]: https://github.com/ghostty-org/ghostty/blob/0c2a290d3a3e2a599be3a43435d778a5896667ee/src/terminal/osc/parsers/kitty_text_sizing.zig
