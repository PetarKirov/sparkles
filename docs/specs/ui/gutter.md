# `sparkles:ui` gutter channels — Feature Requirements (`GUT`)

_**Status:** active · **Date:** 2026-08-19 · **Scope:** the per-line chrome
left of a document — line numbers, coverage counts, fold arrows, diff markers,
blame — as one model in `sparkles.ui.components.gutter`, and the composition
that puts it beside the content rather than inside it._

> [!NOTE]
> **A word about the word.** "Gutter" means two unrelated things in this
> repository. Here it is the strip of chrome left of a document. In the
> [popup research](../../research/anchored-overlays/features-people-forget.md)
> and in every popup library it surveys, `gutter` is the offset between an
> anchor and the panel floating beside it (Ariakit's `gutter`, Zag's
> `gutter: 0`). Neither name is going to move, so they are disambiguated by
> spec: `GUT*` is this one.

## Why this spec exists

The same concept was implemented five times, none sharing code:

| Where                            | Mechanism before                                            |
| -------------------------------- | ----------------------------------------------------------- |
| GUI line numbers (`NUM1`–`NUM3`) | painted outside the widget tree, in a pixel band of its own |
| GUI fold arrows (`FLD5`)         | painted at `treePx() + 2`, with a pixel-range hit test      |
| TUI line numbers                 | **absent entirely** — the TUI had never met `NUM1`          |
| Diff old/new + marker (`DVM5`)   | hand-padded strings prefixed into each row                  |
| Coverage counts (`OVL7`/`COV2`)  | a `gutterSpan` prefixed into each code row                  |

Two costs followed, and the second is the reason this is a spec rather than a
refactor.

**Chrome inside the row displaces the code.** Every decoration positioned by a
_source column_ — a hover underline, an error squiggle, a below-line caret —
then has to be told how far the code was pushed right. `663618293` threaded
that as a `columnOffset` parameter through `sparkles:twoslash`'s
`decorateCodeRow` and `buildBelowBlock`. It worked, and it was the wrong shape:
`libs/syntax` and `libs/twoslash` were doing layout arithmetic for a caller's
chrome. Underlines landing one gutter-width right of their identifiers was the
symptom that surfaced it.

**Chrome outside the tree exists only on one backend.** The GUI's line numbers
and fold arrows were raylib draw calls, so the TUI had neither, the ANSI and
HTML writers had neither, and each new channel meant new painting and a new hit
test per backend.

## Design & rationale

### The gutter is layout

A channel is a column of fixed-width cells and nothing more. Put it in a
sibling widget and the layout engine does the offsetting: the code row's frame
starts past the strips, a `stack` child inherits its parent's origin
(`sparkles.ui.layout.place`), and a decoration lands on its token with no offset
to pass. `columnOffset` is deleted rather than threaded correctly, and the
producers stop knowing that gutters exist.

### Composed after layout, not during

The unit cannot be the source line. `NUM1` numbers by _physical_ line on the
_first visual row_ of a wrapped one, and a markdown preview's rows are not one
per source line at all — a wrapped paragraph is two rows, a heading is one, a
blank source line is none. Which visual row carries which source line is only
knowable once the document is laid out.

So composition is two passes: lay the document out alone at the content width,
read its rows back (`DocRow.srcStart`), fill the channels from them, re-root the
same arena around it, lay out again. Sibling columns are correct _here_ for the
same reason they are wrong before layout — the rows already exist, so nothing
can drift.

### Reserve, never reflow

A channel's width comes from the file, never from the data it happens to hold.
This is partly the async-arrival problem the research names ("layout stability
under async arrival"): a coverage artifact is read after the first paint, live
types a second later, and a gutter that sizes itself to its content widens when
the data lands, sliding every line of code sideways under the reader. It is also
structural — pass one lays out at the content width, so the chrome's width has
to be known before any cell exists.

### Lanes and one shared slot

Most channels are lanes and never contend: line numbers and coverage counts each
own a strip. Icons are not. A breakpoint, a fold arrow, a diagnostic badge and a
bookmark all want the same one cell, and a flat list of channels gives each of
them a lane — which converts contention into width consumption, exactly the
failure the research's "slot contention" note predicts. They share a strip
instead, and the strip carries an explicit priority order.

### Budget by dropping strips, not by narrowing them

A gutter has no natural stopping width; a blame lane roughly doubles the three
that exist. When the reserved channels exceed their budget the lowest-priority
ones are switched **off**. A channel narrowed below its content lies — a line
number cut to two digits reads as a different line, a truncated hash resolves to
a different commit — and both look exactly like the truth. A missing column does
not.

## Requirements

| ID    | Requirement                                                                                                                                                                                                                                                                                     | Status                | Traces to                                                                        |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- | -------------------------------------------------------------------------------- |
| GUT1  | Per-line chrome must be a **`GutterChannel`** — a stable `id`, an `enabled` flag, a width in cells, and cells of `(text, slot, background, hitId)` — placed as a sibling of the content. No producer may offset content by a chrome width, and no `columnOffset`-shaped parameter may reappear. | shipped (`6cb7deaef`) | `sparkles.ui.components.gutter`; `columnOffset` deleted in `c90f8f1fe`           |
| GUT2  | A cell must own its text **inline**, so rebuilding a document's chrome on every reflow allocates nothing. Building a channel must be `@nogc`.                                                                                                                                                   | shipped (`6cb7deaef`) | `SmallBuffer!(char, gutterCellInline)`; `buildingAChannelAllocatesNothing`       |
| GUT3  | Channels must compose **after layout**, one cell per _visual row_ — a wrapped line numbered on its first row only (`NUM1`), a row with no source identity numbering nothing rather than inheriting a neighbour.                                                                                 | shipped (`715bc5075`) | `withGutterColumns`; `ViewerModel.gutter` two-pass                               |
| GUT4  | A channel's width must be **reserved** from the file, never derived from the data, so a late-arriving artifact never widens the gutter under the reader.                                                                                                                                        | shipped (`85dcc4cec`) | `ViewerModel.reservedChannels`; coverage reserves `maxCountWidth`                |
| GUT5  | Every channel must be **toggleable by `id`**. A disabled channel must contribute no width and emit no widget — it must not render an empty lane.                                                                                                                                                | shipped (`eb4df89c0`) | `GutterChannel.enabled`; `GutterSelection.parse`; `disabledChannelsLeaveNoStrip` |
| GUT6  | Icon providers must share **one merged slot** resolved by an explicit priority order, not a lane each; the winning provider must take the cell's `hitId` with it, so whoever owns the pixels owns the click.                                                                                    | shipped (`b41d21488`) | `mergedCells`/`IconClaim`; folds are its only provider (`9f2dfc8ae`)             |
| GUT7  | The gutter must be **budgeted** against the pane, and an over-budget gutter must drop whole channels lowest-priority-first. A channel must never be narrowed below its content.                                                                                                                 | shipped (`1f86bc3e9`) | `withinBudget`; hue budgets at a third of the pane                               |
| GUT8  | Chrome must be excluded from **content search and copy**: `DocRow.text` is the full rendering, `DocRow.sourceText` the identity-bearing spans only, and search reads the latter by default.                                                                                                     | shipped (`6bb2f93c7`) | `documentRows`; `sourceTextExcludesChrome`                                       |
| GUT9  | A channel's cells must be addressable by its `id`, so a **selection** names channels rather than growing one flag per strip, and a later **per-channel search scope** (search one channel, several, or channels + content) is a filter over the existing model rather than a new one.           | partial (`eb4df89c0`) | `--gutter all/none/<names>`, `<leader>vg`; no search scope yet                   |
| GUT10 | The chrome must not scroll sideways with the content. A host that pans one display list takes the line numbers off the left edge with the code; the horizontal camera splits at the pinned width instead, and the pointer mapping splits with it.                                               | shipped (`22a0ab764`) | `ViewerModel.pinnedCols`; `contentColOf`; two paint passes per host              |

## Open questions

- **Colour collision.** Coverage red/green and diff red/green want the same
  semantics in the same strip, and neither is colourblind-safe. Untouched, and
  the one cross-cutting problem from the research this model does not address at
  all — it decides _which_ strip renders, never what colour it is.
- **Per-channel search scope** (`GUT9`) is a seam, not a feature: channels are
  addressable by `id` and `--gutter` selects them by name, but nothing yet
  offers to search one channel rather than the content.
- **Not everything is a line decoration.** Multi-range, cross-file, ordered
  objects (taint paths, sanitizer origin↔fault pairs) cannot be expressed as
  `(row, cell)` at all. The channel model is deliberately not the answer to
  those; see [`OVL1`](../hue/overlays.md).

### Resolved since the first draft

- **Horizontal scroll** now pins the chrome (`GUT10`). Both hosts split the
  horizontal camera at `pinnedCols` rather than panning one display list, so a
  wide table scrolls under a gutter that stays put. It also fixed a bug the
  document tint had all along: it never subtracted the horizontal offset, so
  every selection and search tint sat under the wrong columns once scrolled.
- **Per-datum staleness** landed as re-anchoring ([`COV5`](../hue/overlays.md)),
  which is a stronger answer than marking. A `.lst` records the source it
  counted, so lines that survived an edit keep their counters at their new
  numbers and only the ones that changed lose theirs. The research asked for
  staleness in the decoration type; the evidence in the artifact allowed
  something better — most of the decorations stop being stale at all.

## Who traces here

| Spec                                      | Requirements                     |
| ----------------------------------------- | -------------------------------- |
| [hue `--gui`](../hue/gui.md) line numbers | `NUM1`, `NUM2`, `NUM3`           |
| [hue folding](../hue/folding.md)          | `FLD5` (the gutter fold marker)  |
| [hue overlays](../hue/overlays.md)        | `OVL7`, `COV2`                   |
| [hue diff view](../hue/diff-view.md)      | `DVM5` (old/new/marker channels) |
