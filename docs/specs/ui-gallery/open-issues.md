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

## `UGL-O6` — a widget-level bar cannot be sub-cell · closed

hue's window draws a ⅓-cell rail that eases open to 1.5 cells. The widget and
display-list levels now express it as `ScrollbarSpec` → `OpKind.scrollbar`,
carrying content units and a semantic `expandPercent` rather than pixels.
`RaylibCanvas.scrollbar` resolves the continuous device-pixel rail; cell
backends threshold the same value to one or two columns through the shared
fallback.

Closed 2026-08-12: the gallery remains a pure widget consumer while its GUI bar
now has the same continuous rail as hue; its terminal rendering remains the
honest quantised degradation.

One page is the exception that proves the rule: the **Terminal** page's draw
phase is already its own (that is what embedding a terminal means), so on the
GPU arm it paints hue's sub-cell rail — ⅓ cell easing to 1.5 under the pointer
— over its bar's gutter, driven by the same machine the cell bar quantizes.
Every other page stays at whole columns.

## `UGL-O5` — the wheel always scrolls the shell's pane · open (narrowed)

The gallery routes wheel events to the content pane regardless of what is under
the pointer, so the Scrolling page's own viewport is driven by keys only. Doing
better needs the wheel routed by hit target, which is a `Page` hook the catalog
does not yet have. Small, and worth doing when a second page wants it.

Two shell-owned regions have since claimed their own wheel by geometry rather
than by hit target — the terminal pane (via the mirrored pane rect) and the
inspector panel (the surface's rightmost columns). What remains open is the
page-level routing: a page's _own_ viewport still cannot ask for the wheel.

## `UGL-O7` — mouse inside a terminal pane · open (narrowed twice)

The pane's $(B applications) now receive the mouse: `sendPointer`/`sendWheel`
on the embedded surface route the gallery's own `PointerEvent`s — already in
cells, made pane-relative — through the mode-aware pty encoder, which writes
nothing unless the application asked for reporting (so the shell's
click-to-focus and hover keep working under a mouse-less shell prompt).
Verified end to end: an SGR click injected at the outer terminal arrives in
the embedded `cat -v` as the correctly-translated inner report.

What still waits: the $(B emulator-level) mouse — selection, OSC 8 link
hover, the ctrl-click opener — which lives in the whole-surface polled
`handle_mouse` (raylib-absolute), and the clipboard chords behind it (copy
needs a selection; paste needs a clipboard $(B read), not a host errand yet).

Scrollback no longer waits on it at all: the wheel over the pane,
`Shift+PgUp`/`PgDn` in capture, and the bar — the catalog's living
`ScrollView` bar, grabbable and hover-eased — all shipped. The bar's machine
holds no truth: ghostty owns the offset, so each frame the shell applies the
machine's movement as a viewport delta and mirrors the real offset back
(intent measured against last frame's mirror, so a move ghostty made itself
never reads as a drag).

Row hover (the tab list's `✕`) needed bare-motion reporting, which the TUI arm
never requested: `RunConfig.motion` now asks for DEC 1003, at one input event
per pointer move. The mini list's circled numbers are East-Asian-Ambiguous —
one cell here and in most terminals, two under `ambiguous-width=wide`; the
`--term-tab-glyphs` override (or a non-unicode theme) is the out. ㉑–㊿ are
East-Asian-**Wide** outright, which is why the cap must not pass 20 without
widening the mini column.

## `UGL-O10` — a divider drag fixes its flexible neighbour · open

`DockContainer`'s divider drag hands the **before** node the new extent and
lets a fixed follower give up the difference — which is right until the before
node is the _flexible_ one. The gallery's centre pane sits before the
inspector's divider, so the first touch of that divider silently converted it
to a fixed extent and the page stopped following the window. hue never sees
this: its flexible pane is last, so its only divider's before node is the
fixed sidebar.

The shell works around it (`reflexCentre`): after every relayout route it
zeroes the centre's extent back to flexible — the inspector already took its
delta, so the re-arrange reproduces the identical picture. Closes if the drag
learns to leave a flexible before node flexible by assigning the delta to the
fixed neighbour instead.

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
