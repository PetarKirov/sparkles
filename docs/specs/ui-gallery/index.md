# `apps/ui-gallery` — the toolkit's catalog

**Status:** implemented (M0–M7) · **Requirement ids:** `UGL*`

> [!NOTE]
> Not to be confused with [hue's gallery](../hue/gallery.md) (`GAL*`/`GNV*`),
> which browses a set of **source files**. This one browses the **toolkit**.

## Why

`sparkles:ui` had no showcase. Ten widget kinds, a layout engine, thirty-four
semantic slots, thirty-six themes, a component set and fifteen interaction
machines, and the only way to see any of it was to read a unit test. There was
also no artifact that demonstrated the backend-neutrality claim by _running the
same code_ in a terminal and in a window — `apps/hue` exercises a narrow slice
and, at the time this was written, still carried its own private frame loops.

`apps/ui-gallery` answers both. It is a Flutter-Gallery-shaped catalog written
as a `sparkles:ui-app` **component**, so it is simultaneously the toolkit's
documentation, its cross-backend parity check, and the host contract's first
real consumer.

## Requirements

| Id      | Requirement                                                                                                                                                                                                                                 | Status |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `UGL1`  | The application names no canvas, window or terminal; it is a component run by `runApp`.                                                                                                                                                     | full   |
| `UGL2`  | One `view` serves the terminal, the window and the recording host — no per-backend branch in a page.                                                                                                                                        | full   |
| `UGL3`  | A page is a pure view over one state value: `uint view(ref Builder, in GalleryState)`.                                                                                                                                                      | full   |
| `UGL4`  | The catalog is a flat table, so the test sweep iterates every page without naming one.                                                                                                                                                      | full   |
| `UGL5`  | Every page builds and lays out at 80×24, 120×40 and 40×10.                                                                                                                                                                                  | full   |
| `UGL6`  | Nothing crosses the surface edge unless a `clipX` ancestor put it there.                                                                                                                                                                    | full   |
| `UGL7`  | The shell's three bands tile the surface vertically at every size.                                                                                                                                                                          | full   |
| `UGL8`  | Every affordance is reachable from the keyboard; the pointer is an addition, never a requirement.                                                                                                                                           | full   |
| `UGL9`  | A page owns keys only in the content region, and never `Tab`, `q` or `Esc`.                                                                                                                                                                 | full   |
| `UGL10` | Hit rects come from the frames the painter used (`IXR27`), asserted on the shell's chrome and on a page's.                                                                                                                                  | full   |
| `UGL11` | The theme is per frame, so selecting one repaints the whole application rather than a preview pane.                                                                                                                                         | full   |
| `UGL12` | Coverage is asserted against the enums: every `WidgetKind`, `Slot`, `BorderStyle`, `UnderlineStyle`, `TrackSpec.Kind`, `TextWrap` and `Guide` has a specimen.                                                                               | full   |
| `UGL13` | A frame can be rendered with no terminal and no display (`--render` / `--render-plain`).                                                                                                                                                    | full   |
| `UGL14` | An animation asks for one frame at a time and stops asking; a target with no frame clock is never woken by one.                                                                                                                             | full   |
| `UGL15` | The sidebar yields its width below a 60-column surface and is restorable with a key.                                                                                                                                                        | full   |
| `UGL16` | Every scrollbar is a `ScrollView`: grabbable, capture-arbitrated, hover-expanding, and eased — never a drawn thumb over a bare offset.                                                                                                      | full   |
| `UGL17` | The Terminal page embeds `sparkles:terminal-view` (`TVW7`): tabs of real shells, the pane a keyed box sized by layout and painted in the draw phase — `paintPane` on the GPU arm, the cell renderer through `isCanvas` on the terminal arm. | full   |
| `UGL18` | With a terminal focused, every key — releases included — forwards to the pty; the release chord (`Ctrl+]` / `` Ctrl+` ``) is the one reserved binding, and a completed press outside the page's chrome also returns the keyboard.           | full   |
| `UGL19` | Tab identity is minted once: closing a tab never renumbers another's hit id. The exit policy is a toggle — clean exits auto-close, failures hold with the code in the label, `hold: all` keeps everything.                                  | full   |
| `UGL20` | No automated test forks a shell: spawning is main-enabled only, so recorded scripts assert on the request flags and the model, and the pty path is verified live.                                                                           | full   |
| `UGL21` | The inspector is a shell panel, not a page: toggled with `\|` beside any page, it dumps the **showing** page at the width it is actually laid out at, scrolls independently, and yields below the width that can carry it.                  | full   |

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

Each of the last three is now an assertion; the first is a unit test in the
backend that owns the arithmetic.

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
