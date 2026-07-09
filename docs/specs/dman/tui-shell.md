# `sparkles:dman` — TUI Shell

_The interactive terminal UI — the biggest net-new piece of v1 (P2). Grounded in
the sparkles `tui-libraries` + `ui-layout` research, which explicitly recommends
a from-scratch immediate-mode framework, and in the prior-art interaction model.
For where this sits, see [Architecture § TUI shell](./architecture.md#the-tui-shell--the-biggest-net-new-piece);
for the data it renders, see [VCS backend](./vcs-backend.md)._

## Design center (adopted from the research)

The sparkles TUI/layout research already picks a direction, and dman adopts it as
its first consumer:

- **Immediate-mode, built from scratch in D** — the app rebuilds the frame each
  tick; the framework diffs and flushes. A C binding would forfeit `@nogc` / UFCS
  / CTFE, and the research shows the whole thing is a few thousand lines.
- **Double-buffer + cell-level diff** — render into a flat cell `Buffer`, diff
  against the previous frame, emit only changed cells. Reuses the existing `@nogc`
  grapheme/width/ANSI engine.
- **Box-flow layout, not a constraint solver** — Ratatui-style `Rect` splitting +
  i3-style `splith`/`splitv`/`tabbed` modes, borrowing Taffy's
  `Length`/`Percent`/`Auto`/`Fr` sizing vocabulary. A constraint solver
  (Cassowary/Kiwi) solves cross-hierarchy alignment dman does not need.
- **Does not own the event loop** — dman drives it (on `event-horizon`; see below).

## `sparkles:tui` — the framework ([D10](./DECISIONS.md))

A new package, phased; dman v1 needs Phases 1–3. It builds on `core-cli`'s
existing `@nogc` grapheme/width renderers (the one-shot `drawTree`/`drawTable`/
`wrap` are adapted to target a cell `Buffer` instead of a string — immediate-mode
is their natural extension).

```d
struct Cell   { SmallBuffer!(char, 8) grapheme; CellStyle style; Color fg, bg; }
struct Buffer { Cell[] cells; ushort cols, rows; }        // flat grid, SmallBuffer-backed

struct Terminal(Backend) {                                // Backend = ANSI writer / test sink
    Buffer current, previous;
    void draw(scope void delegate(ref Buffer) render) {
        render(current);
        current.diffFlush(previous, backend);             // emit only changed cells
        swap(current, previous);
    }
}

// Widgets are a compile-time contract (static dispatch, no vtables), DbI-extended.
enum isWidget(T) = is(typeof((T w, Rect area, ref Buffer b) => w.render(area, b)));
// optional refinements: isStatefulWidget!T, hasScrollable!T, hasFocusable!T
```

**Widget state is three-layer** (from the tree-view case study): immutable data,
a separate `State` (selection / opened set / scroll offset), and a renderer.
`flatten` is a pure free function over flat, index-based nodes:

```d
struct TreeNode  { string label; int parent, firstChild, nextSibling; }  // cache-friendly, @nogc
struct TreeState { bool[NodeId] opened; NodeId selected; size_t scroll; }
auto flatten(scope const TreeNode[] nodes, scope const TreeState st);     // → range of (depth, NodeId)
```

`List`/`Table` carry `ListState`/`TableState` (selected + offset); a `Viewport`
handles scroll. Layout is box-flow combinators (`vBox`/`hBox`/`split` with
`Length`/`Min`/`Ratio`).

## The dman shell — interaction model

State adapts the prior art, with its implicit flag-cascade promoted to an explicit
priority-ordered `InputMode`:

```d
enum InputMode { normal, search, confirm, help }          // priority: help > confirm > search > normal

struct DmanTui {
    TreeState        tree;         // repos → worktrees → branches
    size_t           cursor;       // into the FILTERED view
    bool[BranchId]   marks;        // multi-select, indexes the BASE list
    size_t           scroll;
    ushort           viewportH;    // written by the renderer, read by scroll math next frame
    FilterMode       filter;
    SortMode         sort;
    SearchState      search;       // query + caret + autocomplete
    InputMode        mode;
    ActionLogEntry[] log;          // dry-run / delete results
    bool             quit;
}
```

**Screen regions** (a dynamic vertical layout so optional bars collapse):
header → optional search bar → optional filter tabs → content (the repo/worktree/
branch tree + a detail pane, e.g. a 70/30 split) → optional action log → footer;
modals (confirm, help) `Clear` a centered rect and render on top. The cursor row
and marked rows are highlighted; scrolling is edge-triggered off `viewportH`.

**Keymap** (per-mode tables, adapting the prior art): `j`/`k` + arrows navigate,
`Space` marks, `a` select-all-safe, `c` clear, `f` toggle force, `d` toggle
dry-run, `s` cycle sort, `Tab`/`1`–`4` filter, `/` search, `Enter` confirm,
`?` help, `q`/`Esc` quit/back.

## Destructive-op safety & selection

- **Confirm contract** — a destructive action shows the count, the first N names
  then "and X more", the **exact command** that will run (safe vs force variant),
  and a warning line if any selection is unmerged — not a bare y/n.
- **Dry-run** flows through the _same_ select → confirm → execute path (only the
  terminal step differs — log "would …" vs run), available as a flag and a runtime
  toggle so preview and real execution can't diverge.
- **Action log** — batch ops continue on error, recording each item's
  success/failure + reason with running counts, with optional export to a file.
- **Undo** — the action log offers undo of a delete (backed by the recorded ref
  state; a genuine one-command undo on jj — [D8](./DECISIONS.md)).
- **Stable-identity selection** — the marked set is tracked by stable identity
  (branch name / id), never by visible row index, so re-filtering/sorting can't
  corrupt it; the selectable set is **mode-gated** (selected / selectable /
  disabled-needs-force / protected-no-checkbox) and "select all" operates only on
  the currently-selectable subset.

## Event loop on `event-horizon`

The loop is driven by `event-horizon`'s `runOnce`, **not** a blocking poll — the
dman-specific improvement over the prior art:

```d
// schematic — the loop multiplexes input, timers, resize, and async completions
env.run((ref Sched s) {
    // stdin readable via the ring → decode keys/mouse → tui.dispatch(ev)
    // SIGWINCH via signals → tui.relayout()
    // concurrent git / scan / PR / watch completions feed tui state
    // redraw on: input | resize | state change | a capped tick, then diff+flush
});
```

Because async work runs _on the same loop_, the UI stays responsive while
branches load, a scan runs, or PR status is fetched — none of it blocks the
frame. Setup/teardown bracket the loop (raw-mode + alternate-screen enter/exit;
`SIGWINCH` → resize → relayout; a single `quit` flag exits).

## Phasing (dman-relevant)

- **P2a** — `sparkles:tui` core: `Cell`/`Buffer`/`Backend`/`Terminal`
  double-buffer + cell-diff, and the box-flow layout combinators.
- **P2b** — core widgets: `List`+`ListState`, `Table`+`TableState`,
  `Tree`+`TreeState`, `Viewport`, `Paragraph` — adapting the existing one-shot
  renderers to write into a `Buffer`.
- **P2c** — the dman shell: app state, `InputMode`, keymap, panes, and modals on
  the `event-horizon` loop; the branch-management UX (classification, multi-select
  safe/force delete, dry-run, action log, filter/sort/search).
- **Deferred** — an optional MVU overlay (pure `update` + a message `SumType`) and
  reactive/incremental rendering as optimizations; mouse; the Kitty keyboard
  protocol. The research keeps immediate-mode the core and these as opt-in layers.
