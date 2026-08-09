# ui-gallery

A browsable catalog of the [`sparkles:ui`](../../libs/ui/) toolkit — the widget
kinds, the layout vocabulary, the thirty-six built-in themes, the component set
and the interaction machines — running **in a terminal and in a window from one
`view`**.

```bash
dub run :ui-gallery                 # a window if there is a display, else the terminal
dub run :ui-gallery -- --tui        # force the terminal
dub run :ui-gallery -- --gui        # force the window
dub run :ui-gallery -- --list-pages # the catalog, no backend needed
```

It is the toolkit's showcase and its proving ground at once. The application is
a **component** — a struct with `view` and `handle` member templates, run by
`sparkles:ui-app`'s `runApp` — so it names no canvas, no window and no terminal,
and every page is a pure view over one state value. Where the two backends
disagree about anything, the gallery is where you find out.

## The catalog

| Page           | What it shows                                                                      |
| -------------- | ---------------------------------------------------------------------------------- |
| **Welcome**    | the backend that opened, the surface size, and which input tiers the target serves |
| **Primitives** | one specimen per `WidgetKind`, including the three containers that are not flows   |
| **Layout**     | `SizeSpec`, alignment, gap, padding and visibility as live knobs                   |
| **Tracks**     | the CSS-Grid subset resolved live, as both numbers and bars                        |
| **Text**       | the three wrap strategies at one column, and `cellsOf` beside a byte count         |
| **Themes**     | all thirty-six built-ins; selecting one repaints the whole window                  |
| **Slots**      | every one of the thirty-four semantic roles, resolved against the live theme       |
| **Decoration** | box and text chrome, and what a cell grid can actually express                     |
| **Components** | `headerBar`, `tabStrip`, `actionBar`, `gutter`, `scrollbar`, `scrollView`          |
| **Tree**       | the data / interaction / view split, one tree rendered twice                       |
| **Scrolling**  | the one thumb formula, at three offsets, beside the numbers it produced            |
| **State**      | a tile per interaction machine, each printing its own current value                |
| **Split**      | a draggable divider whose grab is relative, and the pointer shape that follows it  |
| **Terminal**   | real shells in VSCode-style tabs — `sparkles:terminal-view` embedded as a widget   |
| **Inspector**  | `dumpTree` of the page you were last looking at                                    |

## Driving it

Everything is reachable from the keyboard, because a terminal without mouse
reporting must still be fully navigable.

| Key                     | Does                                                           |
| ----------------------- | -------------------------------------------------------------- |
| `↑` `↓` / `j` `k`       | move within the focused region                                 |
| `←` `→`                 | previous / next page                                           |
| `Tab`                   | switch between the page list and the page                      |
| `Enter` / `Space`       | move to the page                                               |
| `1`…`9`, `0`            | jump to a page                                                 |
| `PgUp` / `PgDn`         | scroll the page; `Home` / `End` for its ends                   |
| `[` / `]`               | previous / next theme                                          |
| `\`                     | show the page list on a narrow terminal                        |
| `?`                     | every binding, including the showing page's own                |
| `q` / `Esc`             | quit                                                           |
| `Ctrl+]` / `` Ctrl+` `` | give the keyboard back to the gallery, from a focused terminal |

With the keyboard in the page (`Tab`), the page gets first refusal on each key —
which is how the Tree page owns the arrows without the page list losing them.
`Tab`, `q` and `Esc` are never a page's to take. The status bar lists whatever
the showing page has claimed.

The one inversion is a **focused terminal** (the Terminal page, `⏎` or a click
on the pane): then every key — `q`, `Tab`, arrows, `Ctrl+C`, releases included —
belongs to the shell inside it, and the gallery reserves only the release chord
and the scrollback keys (`Shift+PgUp`/`PgDn`). The Terminal page spawns real
shells (`n` or the `+ new` button, up to eight tabs in a bordered table beside
the pane — selection by background and bold, a close `✕` revealed on hover; on
a narrow surface the table becomes a one-cell column of circled numbers whose
hovered cell _is_ the close button, selection there being `h`/`l`'s job, and
`--term-tab-glyphs` restyles the numbers), renders them through the GPU
per-cell renderer in a window and through the cell renderer in a terminal — a
terminal in a terminal —
and applies a VSCode-shaped exit policy: a clean `exit` closes its own tab, a
failure holds the tab with the code in its label, and `e` (`hold: all`) keeps
everything. The wheel over the pane walks the scrollback, and its bar is the
catalog's living scrollbar — grab the thumb, jump on the track, watch it widen
under the pointer — over the terminal's own numbers. Applications that ask for
mouse reporting (vim, htop) get the pointer too, pane-relative through the
mode-aware encoder; a forwarded click also focuses the pane. Emulator-level
mouse — selection, link hover — still waits on the mouse-event conversion.

Mouse, where the target has one: click a page or a theme, press a tab or an
action segment, drag the split divider, and **grab a scrollbar** — a press on
the track jumps the thumb there, a press on the thumb grabs it in place, and
the drag then follows wherever the pointer goes until you let go. The bar
widens while the pointer rests on it; on a target with no frame clock it widens
at once, and on one with no pointer at all it is permanently wide.

## Rendering a frame without opening anything

```bash
dub run :ui-gallery -- --render --page themes --keys ']]' --window-width 100
dub run :ui-gallery -- --render-plain --page primitives > frame.txt
```

`--render` paints one frame through the same `view` the real loop calls and
writes it to stdout as ANSI; `--render-plain` writes the glyphs alone, which is
the form a layout regression is legible in. Both need no terminal and no
display, which is also how the catalog's own tests look at it.

It paints through the **terminal's own canvas**, not a lookalike. An earlier
version used a second cell canvas that had drifted from it, so `--render` showed
dashed borders and accent bars the live `--tui` did not — a headless render of a
different painter than the one that runs is worse than no render at all. A
parity test in `sparkles:ui-tui` now holds the two canvases to the same picture.

## Specification

The traceable requirement inventory is the
[ui-gallery spec](../../specs/ui-gallery/); known gaps are in its
[open issues](../../specs/ui-gallery/open-issues.md).
