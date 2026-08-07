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

| Id      | Requirement                                                                                                                                                   | Status |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------ |
| `UGL1`  | The application names no canvas, window or terminal; it is a component run by `runApp`.                                                                       | full   |
| `UGL2`  | One `view` serves the terminal, the window and the recording host — no per-backend branch in a page.                                                          | full   |
| `UGL3`  | A page is a pure view over one state value: `uint view(ref Builder, in GalleryState)`.                                                                        | full   |
| `UGL4`  | The catalog is a flat table, so the test sweep iterates every page without naming one.                                                                        | full   |
| `UGL5`  | Every page builds and lays out at 80×24, 120×40 and 40×10.                                                                                                    | full   |
| `UGL6`  | Nothing crosses the surface edge unless a `clipX` ancestor put it there.                                                                                      | full   |
| `UGL7`  | The shell's three bands tile the surface vertically at every size.                                                                                            | full   |
| `UGL8`  | Every affordance is reachable from the keyboard; the pointer is an addition, never a requirement.                                                             | full   |
| `UGL9`  | A page owns keys only in the content region, and never `Tab`, `q` or `Esc`.                                                                                   | full   |
| `UGL10` | Hit rects come from the frames the painter used (`IXR27`), asserted on the shell's chrome and on a page's.                                                    | full   |
| `UGL11` | The theme is per frame, so selecting one repaints the whole application rather than a preview pane.                                                           | full   |
| `UGL12` | Coverage is asserted against the enums: every `WidgetKind`, `Slot`, `BorderStyle`, `UnderlineStyle`, `TrackSpec.Kind`, `TextWrap` and `Guide` has a specimen. | full   |
| `UGL13` | A frame can be rendered with no terminal and no display (`--render` / `--render-plain`).                                                                      | full   |
| `UGL14` | An animation asks for one frame at a time and stops asking; a target with no frame clock is never woken by one.                                               | full   |
| `UGL15` | The sidebar yields its width below a 60-column surface and is restorable with a key.                                                                          | full   |
| `UGL16` | Every scrollbar is a `ScrollView`: grabbable, capture-arbitrated, hover-expanding, and eased — never a drawn thumb over a bare offset.                        | full   |

## Shape

```
apps/ui-gallery/src/
├── app.d        # main(): CLI, RunConfig, runApp
├── compat.d     # TEMPORARY: local stand-in for sparkles.ui_app.run_app
├── gallery.d    # the component — view/handle member templates, shell chrome
├── state.d      # GalleryState: every machine the shell owns
├── registry.d   # the Page table, and the catalog sweep
├── kit.d        # the small view vocabulary the pages are written in
├── scrollbars.d # driving a ScrollView: grab, capture, ease, and the widget
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
