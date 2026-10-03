---
status: accepted
owner: sparkles:ui-gallery
---

# `apps/ui-gallery` — the toolkit's catalog

## Abstract

`sparkles:ui-gallery` is the browsable catalog of the Sparkles user-interface
toolkit: one interactive application with a page for every widget kind, layout
rule, visual role, theme, component and interaction behavior the toolkit
offers. The same pages run unchanged in a terminal and in a desktop window, so
the catalog doubles as a side-by-side check that both targets draw the toolkit
alike. Its tests sweep every page at several surface sizes and fail when the
toolkit gains a vocabulary item the catalog does not display, which keeps the
catalog complete as the toolkit grows.

## Introduction

The [`sparkles:ui`](../ui/index.md) toolkit lets an application describe its
interface once and paint it in a terminal or a window. It offers widget kinds,
a layout engine, named visual roles called [slots](../../glossary.md#slot),
dozens of built-in themes, reusable components, and interaction machines. An
interaction machine is a small immutable state value that one input step
advances, such as a press that activates only on release over the same target.
Without a catalog, the only way to see any of this is to read a unit test, and
a newcomer choosing between two widgets has no picture to compare.

The toolkit's central promise, that one description serves every target, is
also the hardest to see. Backend-neutral tests check the data the toolkit
produces, meaning the layout and the list of drawing operations, but not the
picture each backend paints from it. Two border styles drawn identically, an
edge drawn across its box, or a glyph measured at different widths on two
targets passes every such test, yet is obvious on screen. Larger applications,
such as the hue code viewer, exercise only the slice of the toolkit they use, so
most of it has no running consumer at all.

The gallery is an ordinary application written against the
[application host](../../glossary.md#application-host). It is a _component_: a
value that presents its state and handles events, with no knowledge of which
backend runs it. Each page is a pure view over one state value, and the catalog
is a flat table of pages rather than code that names them, so a test can visit
every page without knowing what it shows. Each page also asserts completeness
against the enumerations that define the toolkit vocabulary it catalogs, so an
addition to the toolkit that the gallery does not show fails a test instead of
going unseen. The same pages run under the host's
[recording target](../../glossary.md#recording-target) in unit tests, render a
single frame to text with no terminal or display, and are walked live in both
backends. The automated sweep is backend-neutral, so the comparison between
backends is that live walk, and a divergence it finds becomes an open issue.

This specification covers the gallery's shell: navigation, keyboard and pointer
routing, the panes that tile its body, and the inspector panel. It also covers
the page contract, the coverage the tests assert, and the Terminal page, whose
live shell sessions are spawned only by the running application, never by a
test. How widgets, layout and themes behave belongs to
`sparkles:ui`, and the frame loop and backend selection to `sparkles:ui-app`.
When a page exposes a gap in either, the gallery records it as an open issue
against the owner rather than working around it in the page. Terminal emulation
belongs to `sparkles:terminal-view`, which the Terminal page only embeds. This
catalog is also distinct from [hue's gallery](../hue/gallery.md), which browses
a set of source files rather than the toolkit.

[Requirements](#requirements) lists the gallery's obligations under `UGL` ids.
[Shape](#shape) describes the source layout and how a page plugs into the
shell. [Coverage the catalog asserts](#coverage-the-catalog-asserts) explains
the test sweep, and [What the catalog has already
caught](#what-the-catalog-has-already-caught) lists the toolkit defects it
exposed. [Verification](#verification) gives the commands and the walk through
both backends that precedes a change. [Open issues](./open-issues.md) tracks
the toolkit and host gaps the gallery found, under `UGL-O` ids, and the
[user guide](../../apps/ui-gallery/index.md) describes running the gallery and
its pages.

## Requirements

| Id      | Requirement                                                                                                                                                                                                                                                                                                                                                             | Status |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `UGL1`  | The application names no canvas, window or terminal; it is a component run by `runApp`.                                                                                                                                                                                                                                                                                 | full   |
| `UGL2`  | One `view` serves the terminal, the window and the recording host — no per-backend branch in a page.                                                                                                                                                                                                                                                                    | full   |
| `UGL3`  | A page is a pure view over one state value: `uint view(ref Builder, in GalleryState)`.                                                                                                                                                                                                                                                                                  | full   |
| `UGL4`  | The catalog is a flat table, so the test sweep iterates every page without naming one.                                                                                                                                                                                                                                                                                  | full   |
| `UGL5`  | Every page builds and lays out at 80×24, 120×40 and 40×10.                                                                                                                                                                                                                                                                                                              | full   |
| `UGL6`  | Nothing crosses the surface edge unless a `clipX` ancestor put it there.                                                                                                                                                                                                                                                                                                | full   |
| `UGL7`  | The shell's three bands tile the surface vertically at every size.                                                                                                                                                                                                                                                                                                      | full   |
| `UGL8`  | Every affordance is reachable from the keyboard; the pointer is an addition, never a requirement.                                                                                                                                                                                                                                                                       | full   |
| `UGL9`  | A page owns keys only in the content region, and never `Tab`, `q` or `Esc`.                                                                                                                                                                                                                                                                                             | full   |
| `UGL10` | Hit rects come from the frames the painter used (`IXR27`), asserted on the shell's chrome and on a page's.                                                                                                                                                                                                                                                              | full   |
| `UGL11` | The theme is per frame, so selecting one repaints the whole application rather than a preview pane.                                                                                                                                                                                                                                                                     | full   |
| `UGL12` | Coverage is asserted against the enums: every `WidgetKind`, `Slot`, `BorderStyle`, `UnderlineStyle`, `TrackSpec.Kind`, `TextWrap` and `Guide` has a specimen.                                                                                                                                                                                                           | full   |
| `UGL13` | A frame can be rendered with no terminal and no display (`--render` / `--render-plain`).                                                                                                                                                                                                                                                                                | full   |
| `UGL14` | An animation asks for one frame at a time and stops asking; a target with no frame clock is never woken by one.                                                                                                                                                                                                                                                         | full   |
| `UGL15` | The sidebar yields its width below a 60-column surface and is restorable with a key.                                                                                                                                                                                                                                                                                    | full   |
| `UGL16` | Every scrollbar is a `ScrollView`: grabbable, capture-arbitrated, hover-expanding, and eased — never a drawn thumb over a bare offset.                                                                                                                                                                                                                                  | full   |
| `UGL17` | The Terminal page embeds `sparkles:terminal-view` (`TVW7`): tabs of real shells, the pane a keyed box sized by layout and painted in the draw phase — `paintPane` on the GPU arm, the cell renderer through `isCanvas` on the terminal arm.                                                                                                                             | full   |
| `UGL18` | With a terminal focused, every key — releases included — forwards to the pty; the release chord (`Ctrl+]` / `` Ctrl+` ``) is the one reserved binding, and a completed press outside the page's chrome also returns the keyboard.                                                                                                                                       | full   |
| `UGL19` | Tab identity is minted once: closing a tab never renumbers another's hit id. The exit policy is a toggle — clean exits auto-close, failures hold with the code in the label, `hold: all` keeps everything.                                                                                                                                                              | full   |
| `UGL20` | No automated test forks a shell: spawning is main-enabled only, so recorded scripts assert on the request flags and the model, and the pty path is verified live.                                                                                                                                                                                                       | full   |
| `UGL21` | The inspector is a shell panel, not a page: toggled with `\|` beside any page, it inspects the **showing** page at the width it is actually laid out at — the generic [inspector component](../ui/inspector.md) over the widget-tree adapter (collapsible rows, click-selection, a details pane) — scrolls independently, and yields below the width that can carry it. | full   |
| `UGL22` | The body band's three panes tile through `sparkles.ui.components.dock` (`DCK1`/`DCK3`): both seams are draggable dividers with per-pane floors and surface-derived ceilings, the arranged widths are mirrored into the state the pure views read, and a hidden pane returns at its dragged width.                                                                       | full   |
| `UGL23` | A terminal pane rides the ring (`TVW8`) and the timed wake is asked per frame (`HST16`) for the panes it does not carry, so a catalog with no terminal open parks on input alone.                                                                                                                                                                                       | full   |

## Shape

```
apps/ui-gallery/src/
├── app.d        # main(): CLI, RunConfig, runApp
├── gallery.d    # the component — view/handle member templates, shell chrome
├── state.d      # GalleryState: every machine the shell owns
├── registry.d   # the Page table, and the catalog sweep
├── kit.d        # the small view vocabulary the pages are written in
├── inspector.d  # the dumpTree side panel (`|`), a shell region not a page
├── scrollbars.d # driving a ScrollView: grab, capture, ease, and the widget
├── term_store.d # the Terminal page's heap-pinned TerminalView instances
├── render.d     # one frame to ANSI or glyphs, no backend
└── pages/       # one module per catalog entry
```

`Page` carries a `view`, an optional `onKey` and an optional `onActivate`. The
shell offers a key to the showing page only while the keyboard is in the content
region, and only after taking the bindings that must always work; it offers a
completed press's hit id the same way, after routing its own chrome. That is the
whole extension mechanism — the shell imports no page to find out what it is
showing.

## Coverage the catalog asserts

The sweep is the reason the registry is a table rather than a switch. For every
page, at three surfaces: it builds, it lays out, it does not overflow sideways,
and it renders something recognisable. On top of that, each page asserts
completeness against the enum it catalogs — so a widget kind or a slot added to
the toolkit and not to the gallery **fails a test** rather than quietly going
undisplayed.

## What the catalog has already caught

The strongest argument for the app is the list of defects that existed before it
and were invisible without it.

- **There were two cell canvases, and they disagreed.** `CellGrid` and
  `sparkles:ui-tui`'s `GridCanvas` each hand-rolled the same glyph decisions, so
  fixing one left the other alone — and `--render`, which used the first, showed
  a picture the live terminal did not produce. The decisions now live in one
  place, `--render` paints through the terminal's actual canvas, and a parity
  test holds the two to the same output. This one was found by the fix for the
  next item appearing to work and not working.
- **The cell grid drew `solid`, `dashed` and `dotted` borders identically.** Box
  drawing carries dash runs in both axes (`╌ ┈` and `╎ ┊`); the interpreter used
  `─`/`│` for all three, so two thirds of the vocabulary was invisible in a
  terminal — and a dotted hover underline looked solid. The page shows the three
  side by side, which is one picture repeated if they do not differ.
- **A single-side accent dropped entirely in the terminal.** The left bar an
  error line wears was documented as having "no cell analog", but the
  eighth-blocks give it three weights. It now survives, which also gives hue's
  terminal markdown preview the blockquote bars and its twoslash overlay the
  severity accents it previously only had in a window.
- **`ui-raylib` drew every square-cornered border wrong.** The two vertical
  edges were computed with the horizontal axis' argument order, so a box's left
  border drew as a bar _across_ the box and its right border as a bar poking out
  beside it. Every backend-neutral test passed — the display list was right and
  the cell grid drew the box correctly — because the defect lived inside a
  `@system` function that needs a window to run. The Decoration page shows eight
  bordered boxes side by side, which is a picture nobody can misread. Fixed by
  extracting `borderEdges` as pure arithmetic with tests.
- **The shell's header was drawn under the page** on a surface shorter than the
  sidebar's natural height, because the root column reclaimed the header's row.
- **Three header segments overprinted** on a narrow surface, because overflow
  reclamation shrinks a text run's allocation without clipping what it paints.
- **The gallery's own `section` helper drew its caption on top of its body**,
  because `panel` is not a flow.
- **The tab list truncated labels by bytes, not cells.** The active tab's
  "▸ " marker spends 4 bytes on 2 cells, so its label lost extra characters —
  and a multibyte OSC title could be sliced mid code point, poisoning the tree
  with invalid UTF-8. `sparkles:base` has carried a grapheme-safe
  `truncateField` all along; the list now uses it, and a test pins valid UTF-8,
  the cell budget, and the ellipsis.
- **`grow` inside the shell's scroll viewport collapses to natural width.**
  The viewport lays its child out at the child's own width, so a `grow` pane
  has nothing to expand into and quietly becomes as wide as the longest label
  beside it — found live as a terminal that refused to widen with its window,
  at exactly the width of its own hint line. Pages size widths from state
  (`fixed`), as their heights always did.

- **Every pty master leaked into the next tab's shell.** `forkpty` returns a
  plain master, so opening a second terminal in one process handed its child a
  copy of the first's — `5 -> /dev/ptmx` in the second shell's own
  `/proc/self/fd`. An unrelated shell could read and write another tab's
  terminal, and, because a hangup waits for the **last** master to close,
  closing the first tab would not have hung up the shell inside it. Only a
  multi-terminal embedder could expose this; `apps/terminal` opens one. The
  master is `FD_CLOEXEC` now (`UGL-O9`'s audit).

Each of the last three is now an assertion; the first is a unit test in the
backend that owns the arithmetic. The pty leak is verified the way it was
found — the spawned shell listing its own descriptors.

## Verification

```bash
dub build :ui-gallery
dub test  :ui-gallery
nix build .#ui-gallery
dub run   :ui-gallery -- --tui
dub run   :ui-gallery -- --gui
```

Before a change lands, walk every page in **both** backends and record any
divergence as an open issue rather than working around it in a page.
