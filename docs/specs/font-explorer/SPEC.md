---
status: accepted
owner: sparkles:font-explorer
reviewed: 2026-10-06
---

# `font-explorer` — Specification

## Abstract

`font-explorer` is a font inspector, previewer and comparator for Linux and
macOS that runs both as a window and inside a terminal. It shows a font file's
tables, features, axes, glyphs, metrics and character coverage, renders it at
any size and variation, and compares several fonts side by side. Its
particular subject is programming fonts: whether their ligatures keep a
terminal's character grid intact, how complete their icon and box-drawing
coverage is, and how they look running a real shell. A `font-explorer
inspect` command prints the same report without a window, as text or JSON, or
as a CSS `@font-face` rule ready to paste into a stylesheet.

## 1. Introduction

People choose fonts by looking at them, and they diagnose fonts by looking
inside them. Designers use font managers to browse and preview what is
installed, browser-based inspectors to see the tables and features of a single
file, and comparison sites to set candidates side by side. Programmers choosing
a font for a terminal or an editor ask further questions none of these answer
directly. Do the font's programming ligatures still line up on a character
grid? Does it cover the Nerd Font icon ranges a shell prompt uses? Do
box-drawing characters join without gaps between cells? What does it look like
running an actual shell?

Answering those questions needs more than a preview. It needs the font's own
data: its advances, its shaping behaviour on code, its coverage by named
range. The tools that expose font internals run in a browser and stop at one
file. The tools that manage a library treat fonts as pictures. None of them
runs in a terminal at all, where a programmer choosing a terminal font
already works.

This application is built on `sparkles:font`, which parses fonts, shapes and
rasterizes text, and builds a catalog of fonts; on `sparkles:text-layout`,
which composes specimen text into lines; and on the `sparkles:ui` toolkit,
whose single view description runs both as a window and in a terminal. Every
rendered [specimen](../../glossary.md#specimen) is a bitmap the font library produces in the font being
examined, and the toolkit shows it as an image. In a terminal, specimens
therefore appear in the candidate font, never in the terminal's own font. A
terminal that speaks the kitty graphics protocol displays the same specimens
as the window; any other terminal shows a labelled placeholder in their place,
and every non-pictorial view works unchanged. The live-terminal check runs a
shell in an emulator embedded in the explorer and drawn in the candidate font.
Inspection reads the font library's typed tables directly, so the explorer,
the `inspect` command and the library agree by construction.

The explorer does not manage fonts: it does not install, activate, tag, sync
or download them, and it reads no online catalog. It suggests no pairings. It
does not edit or convert fonts. Windows and Android are outside this
specification. Font parsing, shaping and rasterization belong to
[`sparkles:font`](../font/SPEC.md); Unicode analysis belongs to
[`sparkles:base`](../base/text/SPEC.md); composing specimen text into lines,
with its bidirectional order, script runs and wrapping, belongs to
[`sparkles:text-layout`](../text-layout/SPEC.md). This document states only
what the application requires of them.

Section 2 states the contract at a glance, section 3 its invariants as
requirements, and section 4 the command line. Section 5 covers sources,
section 6 specimens, section 7 programming-font checks, section 8
inspection and persistence, and section 9 how panes share the screen at
different widths. The visual design chosen for each surface, and the mockups
it was chosen from, are recorded in [`design.md`](./design.md).
[`PLAN.md`](./PLAN.md) orders delivery against the font library's milestones.

### Terminology

The terms this specification coins are defined in the
[glossary](../../glossary.md); the font terms it relies on, such as face and
instance, belong to [`sparkles:font`](../font/SPEC.md).

<GlossaryList owner="sparkles:font-explorer" />

### Where it sits among existing tools

| Capability                                                              | Typical of    | In scope |
| ----------------------------------------------------------------------- | ------------- | -------- |
| Custom preview text, size, waterfall, all styles of a family            | all tools     | yes      |
| OpenType feature list with live toggles                                 | inspectors    | yes      |
| Variable-axis sliders and named instances                               | all tools     | yes      |
| Glyph map with names, codepoints and hover                              | inspectors    | yes      |
| Vertical-metrics and advance reports, raw table listing                 | inspectors    | yes      |
| Language and Unicode-block coverage                                     | inspectors    | yes      |
| Two to five faces side by side with synced text and metric annotation   | comparators   | yes      |
| CSS export of `@font-face`, feature and variation settings              | inspectors    | yes      |
| A headless command-line inspector with JSON output                      | one inspector | yes      |
| Ligatures on code, cell-grid audit, Nerd Font coverage, a live terminal | none          | yes      |
| Tags, collections, smart filters                                        | managers      | no       |
| Font activation, design-tool plugins                                    | managers      | no       |
| Online catalogs, sync, teams                                            | managers      | no       |
| Pairing suggestions                                                     | pairing sites | no       |

## 2. The contract at a glance

1. **No backend names.** The application never refers to a particular window
   or terminal backend; `sparkles:ui-app` chooses one.
2. **Specimens are images.** Every rendered specimen reaches the screen as one
   image per block, rasterized by the font library into pixels the application
   owns.
3. **Work only on change.** A specimen is rendered again only when one of its
   inputs changes.
4. **Hostile files are contained.** A malformed font shows its error and never
   affects other fonts or the application.
5. **A testable frame loop.** All behaviour is reachable through the
   toolkit's recording host, without a window or a terminal.
6. **Text is composed by text-layout.** Specimen text is laid out by
   `sparkles:text-layout` over the examined face alone; the explorer has no
   text-composition logic of its own.

## 3. Invariants

**FXP1: No backend names.** No module under `apps/font-explorer/` **may**
import `sparkles.ui_raylib`, `sparkles.ui_tui`, `sparkles.tui` or `raylib`.

_Rationale:_ The same check holds for `apps/diagram`, and it is what keeps the
window and the terminal one application rather than two.

**FXP2: Specimens are images.** Every rendered specimen **must** reach the
screen as one image operation per block, from pixels the font library
rasterized into storage the application owns and registered in its image
registry. Where the target cannot show images, the placeholder that replaces a
specimen **must** name the face and the specimen it stands for.

**FXP3: Work only on change.** A specimen **must** be rasterized again, and
its registry entry replaced, only when its text, face, instance, size,
features or block extent change.

_Rationale:_ The toolkit uploads an image only when its registry entry
changes, so a frame with no change costs no rasterization and no upload, in
the window and over the kitty protocol alike.

**FXP4: Contained failure.** Opening a malformed font **must** show the
library's error for that face and leave every other face and the application
usable.

**FXP5: Testable frame loop.** All behaviour **must** live outside the
entry-point module and be exercised through the toolkit's recording host.

## 4. Command line

**FXP6: Explorer.** `font-explorer [paths…]` **must** open the explorer on
the given files and directories in addition to the configured sources, and
accept the shared window, font and backend flags of `sparkles:ui-app`.

**FXP7: Inspect.** `font-explorer inspect FILE [--index N] [--json | --css]`
**must** print a report and exit without opening a window. The default output
is a readable report. `--json` is the `sparkles:wired` serialization of the
parsed model. `--css` is an `@font-face` rule plus `font-feature-settings` and
`font-variation-settings` for every feature and named instance.

**FXP8: Exit status.** `inspect` **must** exit 0 on success, 1 when the file
is not a readable font, and 2 on a usage error. On status 1 it prints the
library's error kind, table and offset. It **must not** print a partial JSON
document.

**FXP9: Stable JSON.** The JSON document **must** carry a top-level `schema`
integer. Fields **may** be added under the same schema; renaming or removing a
field **must** increment it.

The report covers the font library's [inspection requirements](../font/SPEC.md)
and the research catalog's [inspector list](../../research/font-libraries/comparison.md#rq5-what-an-inspector-must-expose).

## 5. Sources and library

**FXP10: Sources.** The library view **must** list installed fonts, the
bundled font directory, configured directories, and paths given on the
command line, each face labelled with its source. The bundled directory is
always present, so a first launch is never empty.

**FXP11: Families.** Faces **must** group into families by typographic family
name, `name` ID 16, falling back to ID 1. A family lists its styles by weight,
then width, then slope.

**FXP12: Filtering.** A fuzzy filter over family and style names **must** use
`sparkles:fuzzy`. Facets **must** filter by measured monospace spacing,
variable, italic, colour, and coverage of a chosen script or of the Nerd Font
ranges.

**FXP13: Broken faces stay visible.** A face that fails to open **must**
remain listed, marked with its error, and selectable, so its error and its
readable tables can be inspected.

**FXP28: Source navigator.** A navigator **must** list the sources of
`FXP10` as a tree with a face count on every node, followed by saved filters
for the `FXP12` facets and a list of scripts. Selecting a node **must**
restrict the family list to that node's faces.

_Rationale:_ Every surveyed font manager separates where fonts come from from
the fonts themselves. A single mixed list stops working once a user has more
than a few hundred families.

**FXP29: Family rows.** Each family list row **must** show the family's name,
style count, source and capability marks, and a sample rendered in that
family's own face. One sample text and one sample size apply to every row. A
names-only density **must** be available, showing each row without its
sample.

_Rationale:_ Rendering every family's sample is how a reader scans a library
by eye; one shared sample keeps the rows comparable.

## 6. Specimens

**FXP35: Specimen composition.** Every text specimen **must** be composed into
lines by `sparkles:text-layout` in physical mode, over a fallback chain that
holds only the face under examination, with the policy that reports a missing
glyph as that face's `.notdef`. The explorer **must not** itemize, reorder,
wrap or shape text itself. The glyph map (`FXP18`) draws glyphs by ID and is
not a text specimen.

_Rationale:_ Text-layout owns bidirectional order, script runs and contextual
line composition, so a right-to-left or mixed-script specimen is correct only
through it, and an explorer-local path would be a second owner to remove later
([`TL-016`](../text-layout/SPEC.md#_5-contextual-composition)). Fallback to
another face would hide exactly the gaps in coverage a specimen exists to show.

**FXP14: Preview.** Custom text **must** render at a chosen pixel size, line
height and colour pair, shaped with the selected features and instance.

**FXP15: Waterfall.** The same text **must** render at each size of a
configured list.

**FXP16: Styles.** Every style of the selected family, or every named
instance of a variable face, **must** render one line each.

**FXP17: Code.** A code sample highlighted by `sparkles:syntax` **must**
render with a toggle that shapes it with `calt` and `liga` on or off.

**FXP18: Glyph map.** Every glyph **must** render in a grid. Hovering or
focusing a cell **must** show its ID, name, codepoints, advance and bounds.
The grid is one image, hit-tested by the application.

**FXP19: Compare.** Two to five faces **must** render side by side with
shared text, size and features, each annotated with baseline, x-height, cap
height, ascender and descender.

**FXP30: Compare modes.** Comparison **must** offer three modes over the same
faces, text, size and features. _Cards_ sets faces side by side for reading
along a line. _Rows_ stacks one line per face for reading down a column.
_Overlay_ superimposes two faces' glyph outlines, distinguished by line style
as well as colour. Switching modes **must** keep the faces, text, size and
features.

_Rationale:_ Cards and rows compare runs of text in the two reading
directions; only an overlay shows how individual glyphs differ.

## 7. Programming-font checks

**FXP20: Cell-grid audit.** The [cell-grid audit](../../glossary.md#cell-grid-audit) **must** list every glyph whose
advance differs from the face's cell advance, and every ligature that changes
the number of glyphs, with the characters involved.

_Rationale:_ A terminal may place glyph _i_ of a run in cell _i_ only on an
audited fast path; every other run uses the shaped positions and source spans
([`FTA16`](../font/SPEC.md#_15-consumers)). The audit tells a user which text
in a face takes that path. Both bundled programming fonts keep one glyph per
character on the 160 measured ligature sequences
([`FTX7`](../font/decisions.md#ftx7-ligatures-keep-one-glyph-per-cell-their-ink-crosses-cells)).

**FXP21: Nerd Font coverage.** The explorer **must** report coverage of the
Powerline, Powerline Extra, Devicons, Font Awesome, Material Design,
Codicons, Octicons and Weather ranges, as counts and as a glyph strip.

**FXP22: Disambiguation strip.** The groups `0O`, `1lI|`, `rn` beside `m`,
`;:`, `{}()[]` and `` `'" `` **must** render large.

**FXP23: Seam check.** A grid of box-drawing, block and Powerline glyphs
**must** render on exact cell boundaries, so gaps between cells are visible.

**FXP24: Live terminal.** A shell **must** run in a `sparkles:terminal-view`
pane painted in the selected face at the chosen size.

**FXP34: Unflagged overlaps.** The explorer **must** list the glyphs whose
outline data does not flag overlapping contours but whose coverage at 24 pixels
per em changes by more than 32 of 255 when rendered as the union of their
contours, each with the size of that change.

_Rationale:_ Such glyphs render with darker edges where their contours overlap,
here and in FreeType-based renderers, because the library unions only flagged
glyphs ([`FTX9`](../font/decisions.md#ftx9-flatten-to-0-02-px-render-the-union-of-flagged-glyphs)).
The fix belongs in the font: set the flag or remove the overlaps. Noto Sans
Arabic, a bundled fallback face, had 428 such glyphs when measured on
2026-10-04.

**FXP31: Checks as a dock.** The checks of `FXP17`, `FXP20`–`FXP24` and `FXP34`
**must** be panes of a `sparkles:ui` dock container. The user **may** split,
stack, resize, close and re-add them. The arrangement **must** persist and be
restored on the next launch, and a reset **must** restore the default
arrangement.

_Rationale:_ Which checks matter differs per user and per font. The dock
already provides splits, tabbed groups, drag-to-redock and a serializable
layout, so the dashboard reuses it rather than inventing one.

## 8. Inspector and persistence

**FXP25: Inspector views.** Info, metrics, features, axes, coverage and
tables views **must** present the same data as `inspect` for the selected
face.

**FXP26: Live controls.** Toggling a feature or moving an axis **must**
re-render every visible specimen of that face within the frame budget that
typing in the preview meets.

**FXP27: Persistence.** Preview text, sizes, waterfall steps, extra font
directories and the last selection **must** persist in a `sparkles:wired`
JSON file in the user's configuration directory. An unreadable file **must**
be reported and replaced by defaults, never be fatal.

## 9. Layout across widths

The explorer's panes are the source navigator, the family list, the specimen
area and the inspector. Which of them share the screen depends on the width
of the window or terminal, measured in the user interface's cells, so one
rule serves both targets and scales with the interface font.

**FXP32: Width classes.** The layout is chosen by [width class](../../glossary.md#width-class). At 150 cells or more, all four panes **must** be
shown side by side. From 100 to 149 cells, the navigator **must** fold into a
source picker at the top of the family list, and the inspector **must**
become an overlay. Below 100 cells, only the specimen area **must** be shown,
and both the family list and the inspector **must** become overlays.

**FXP33: Overlays.** An overlay **must** open and close from a visible control
and from a key: `[` for the family list and `]` for the inspector. An open
overlay **must** cover the specimen area without changing its layout, and
`Esc` **must** close it. Crossing a width class **must** keep the selection,
the active tab and the specimen settings.

_Rationale:_ Overlaying rather than reflowing keeps a specimen at the size the
user chose, which is the subject of the application.
