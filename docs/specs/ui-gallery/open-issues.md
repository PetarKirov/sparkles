# `apps/ui-gallery` — open issues

Gaps the catalog exposed. Each is a finding about the toolkit or the host, not a
defect in a page — the gallery's job is to make them visible rather than to work
around them.

## `UGL-O1` — a component may supply the frame's theme · closed

`runApp` resolved the theme once, from `--theme`, so a live theme browser was
inexpressible: every slot on every page would resolve against the startup theme
forever, and `RunConfig` is taken `in` by every arm so there was nothing to
mutate.

`sparkles.ui_app.run_app.frameTheme` now probes the component for a `theme`
member and prefers it, in the DbI shape the toolkit already uses for
`isCanvas`'s optional `pushClip`/`rule`. A component without one pays nothing.
Asked after `view`, so a component that changes theme in response to a key
paints the same frame in the theme it just chose.

## `UGL-O2` — the two backends measure text differently · open

`GridCanvas` measures with `codepointWidth` (a wide glyph is two columns);
`RaylibCanvas` advances one column per codepoint, which is what `cellsOf`
computes and what the layout pass therefore uses. Each is right within its own
target and they disagree across targets — the known `LAY5` / `MIG5` item.

The **Text** page shows it outright, with a row of wide glyphs and a note, since
that is the page where a reader would otherwise conclude the toolkit is simply
wrong. Golden snapshots stay narrow-width so the tests are stable. Closes when
the raylib font set's real advance metrics become the width authority.

## `UGL-O3` — a `panel` is not a flow, and reads as though it were · open

`stack`, `panel` and `popup` give every child the container's origin. That is
documented, and this gallery's own `section` helper still drew its caption on
top of its body the first time it was written. A `panel` handed several children
almost always wants an explicit `column` inside it.

Worth considering whether `panel` should flow its children by default and
`stack` remain the overlay — the **Primitives** page states the current
behaviour and asserts it, so a change would be caught either way.

## `UGL-O4` — overflow reclamation shrinks allocations but not what is painted · open

When a column's children do not fit, the engine reclaims the difference by
shrinking allocations. A text run whose allocation shrank still paints its whole
string, so on a short surface the shell's header was drawn _under_ the page, and
on a narrow one three header segments overprinted each other.

Both are avoidable from the application — pin the bands to a fixed height, and
drop header segments by priority as the surface narrows, which is what the shell
now does. But "shrunk" and "clipped" being different things is a sharp edge, and
a caller who has not met it will meet it this way. A `clipX` default on text
whose allocation is below its natural width would remove the class.

## `UGL-O6` — a widget-level bar cannot be sub-cell · open

hue's window draws a ⅓-cell rail that eases open to 1.5 cells. That is sub-cell
geometry, reachable only by driving the canvas directly (`ui_raylib`'s
`scrollbarLayout` / `drawScrollbar`), and the gallery is a pure host consumer
that paints through the widget display list on both targets.

So its bar eases between **one and two whole columns** instead. The value and
the rate are the same — `ScrollView.easeV` at 15/s — but the result is
quantised, so the animation reads as a short delay before the bar widens rather
than as a smooth slide. In the terminal, where the two look identical anyway,
this is strictly better than hue, which does not expand at all.

Closes if the widget level grows a sub-cell width hint, or stays open as the
honest price of never naming a canvas.

## `UGL-O5` — the wheel always scrolls the shell's pane · open

The gallery routes wheel events to the content pane regardless of what is under
the pointer, so the Scrolling page's own viewport is driven by keys only. Doing
better needs the wheel routed by hit target, which is a `Page` hook the catalog
does not yet have. Small, and worth doing when a second page wants it.

## `UGL-O7` — mouse inside a terminal pane · open (narrowed)

`handle_mouse` polls raylib in absolute window coordinates, so an embedded pane
gets no selection and no OSC 8 hover — on either arm. The page says so. Lands
with the mouse-event conversion (`TVW4`'s "when its source swaps"), at which
point the gallery routes `PointerEvent`s inside the pane rect the way it
already routes keys. The clipboard chords (`Ctrl+Shift+C/V`) sit behind the
same conversion: copy needs a selection, and paste needs a clipboard **read**,
which is not a host errand yet.

Scrollback no longer waits on it: the wheel over the pane, `Shift+PgUp`/`PgDn`
in capture, and a bar drawn from the terminal's own numbers all shipped
(`scrollViewport`/`scrollback` on the embedded surface). Only _dragging_ that
bar remains behind the conversion.

## `UGL-O8` — the embedded cell renderer's honest losses · open

`cell_paint.d` paints one `dchar` per cell, so a multi-codepoint grapheme
cluster (emoji ZWJ sequences, combining marks) drops to its base codepoint; and
kitty graphics are disabled in a fontless terminal (`openCore` never wires the
decoder — nothing cell-shaped could paint an image). Both are stated per-cell
fidelity limits of the terminal arm, not of the GPU arm, which carries the full
renderer.

## `UGL-O9` — the TUI arm's pty wake is a fixed idle tick · open

`RunConfig.idleTimeoutMs` is startup-fixed, so the gallery sets a 50 ms tick
unconditionally: every page pays the wake so that a shell's output can appear
without a keypress. A host-level "the component asks for wakeups while it has
background work" errand would confine the cost to the Terminal page; the
event-horizon arm could equally park a fiber on the pty fd itself. Related:
the gallery never skips frames, so an idle visible terminal still repaints —
`decideRedraw` exists and is unit-tested, and folding it into a gallery-level
skip is the follow-up. The `forkpty` under an open io_uring ring (both arms'
event-horizon variants) also deserves a CLOEXEC audit: the child `execv`s
immediately, but the ring fd should not survive into the shell.
