/++
A minimal app-owned event loop (spec §3.2 — the library-core shape: the
application drives the loop; an MVU overlay is a future option).

$(LREF runApp) wires the three layers — the $(REF Terminal, sparkles,tui,terminal)
backend, the $(REF PosixEvents, sparkles,tui,input) reader, and a
$(REF Grid, sparkles,tui,cell) painted each frame — into an immediate-mode loop:
resize the grid to the terminal, let the app repaint it, diff-flush it, then block
for the next event. Because the frame is cell-diffed, repainting the whole grid
every event still emits only the cells that changed (wrapped in one
synchronized-output frame), so there is no flicker and no manual damage tracking.

Posix-only (it drives the Posix backend + reader).
+/
module sparkles.tui.app;

version (Posix):

import sparkles.base.term_caps : TermSize;
import sparkles.tui.cell : Grid;
import sparkles.tui.input : Event, EventKind, PosixEvents;
import sparkles.tui.terminal : Terminal, TerminalOptions;

/// Drive a full-screen application until it asks to quit.
///
/// Each iteration: the grid is resized to the terminal and cleared, `present` (an
/// immediate-mode paint — draw the whole frame from current state) fills it, the
/// backend diff-flushes it, then the loop blocks for one event and passes it to
/// `handle`, which returns `false` to quit. Resize and EOF are handled by the
/// loop (the grid reflows automatically; a resize is still delivered to `handle`
/// so the app can react). Returns without doing anything if stdin isn't a tty.
void runApp(scope void delegate(ref Grid, TermSize) present,
    scope bool delegate(in Event) handle,
    TerminalOptions opts = TerminalOptions()) @system
{
    auto term = Terminal.open(opts);
    if (!term.active)
        return;
    scope (exit) term.close();

    auto events = PosixEvents.start();

    Grid grid;
    for (;;)
    {
        const sz = term.size();
        grid.resize(sz.width, sz.height); // reflow + clear; Screen full-repaints on a size change
        present(grid, sz);
        term.draw(grid);

        const ev = events.next();
        if (ev.kind == EventKind.eof)
            break;
        if (ev.kind == EventKind.resize)
            continue; // next iteration re-measures + reflows
        if (!handle(ev))
            break;
    }
}
