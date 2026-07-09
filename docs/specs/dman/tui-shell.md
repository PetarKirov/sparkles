# `sparkles:dman` — TUI Shell

_The interactive terminal UI — the biggest net-new piece of v1 (P2). Built on the
sparkles `tui-libraries` + `ui-layout` research (a from-scratch cell-diff renderer
with box-flow layout) and an **MVU / Elm core** ([D10](./DECISIONS.md)). For where
this sits, see [Architecture § TUI shell](./architecture.md#the-tui-shell--the-biggest-net-new-piece);
for the data it renders, see [VCS backend](./vcs-backend.md)._

## Design center

- **MVU core, built from scratch in D** ([D10](./DECISIONS.md)) — the shell is a
  `Model` (immutable state), a `Msg` sum type (every input / resize / async
  completion), a **pure `update(Model, Msg) → Model`**, and a **pure
  `view(Model) → Buffer`**. The runtime renders `view`, waits for an event, maps
  it to a `Msg`, and folds it in. Pure `update`/`view` make the whole shell
  **unit-testable** — drive a `Msg` sequence, assert on the `Model` or the frame —
  matching dman's capability/test-double posture.
- **Immediate-mode, cell-diff rendering** — `view` rebuilds the frame each tick
  into a flat cell `Buffer`; the framework diffs against the previous frame and
  flushes only changed cells. Reuses the existing `@nogc` grapheme/width/ANSI
  engine.
- **Box-flow layout, not a constraint solver** — Ratatui-style `Rect` splitting +
  i3-style `splith`/`splitv`/`tabbed` modes, borrowing Taffy's
  `Length`/`Percent`/`Auto`/`Fr` sizing vocabulary. A constraint solver
  (Cassowary/Kiwi) solves cross-hierarchy alignment dman does not need.
- **Does not own the event loop** — dman drives it (on `event-horizon`; see
  below), feeding events in as `Msg`s.

## `sparkles:tui` — the render substrate

A new package, phased; dman v1 needs Phases 1–3. The MVU core sits on a cell-diff
render substrate that reuses `core-cli`'s `@nogc` grapheme/width renderers (the
one-shot `drawTree`/`drawTable`/`wrap` are adapted to target a cell `Buffer`
instead of a string — a `view` is their natural home).

```d
struct Cell   { SmallBuffer!(char, 8) grapheme; CellStyle style; Color fg, bg; }
struct Buffer { Cell[] cells; ushort cols, rows; }        // flat grid, SmallBuffer-backed

struct Terminal(Backend) {                                // Backend = ANSI writer / test sink
    Buffer current, previous;
    void draw(scope void delegate(ref Buffer) render) {   // render = a view(model) call
        render(current);
        current.diffFlush(previous, backend);             // emit only changed cells
        swap(current, previous);
    }
}

// Widgets are a compile-time contract (static dispatch, no vtables), DbI-extended.
enum isWidget(T) = is(typeof((T w, Rect area, ref Buffer b) => w.render(area, b)));
// optional refinements: isStatefulWidget!T, hasScrollable!T, hasFocusable!T
```

**Widget state is three-layer** (from the tree-view case study): immutable data, a
separate `State` (selection / opened set / scroll offset), and a renderer. Under
MVU the `State` structs live **inside the `Model`**; `flatten` is a pure free
function over flat, index-based nodes:

```d
struct TreeNode  { string label; int parent, firstChild, nextSibling; }  // cache-friendly, @nogc
struct TreeState { bool[NodeId] opened; NodeId selected; size_t scroll; }
auto flatten(scope const TreeNode[] nodes, scope const TreeState st);     // → range of (depth, NodeId)
```

`List`/`Table` carry `ListState`/`TableState` (selected + offset); a `Viewport`
handles scroll. Layout is box-flow combinators (`vBox`/`hBox`/`split` with
`Length`/`Min`/`Ratio`).

## The dman shell — MVU

The shell is a `Model`, a `Msg` sum type, a pure `update`, and a pure `view`:

```d
struct Model {
    TreeState        tree;         // repos → worktrees → branches (widget states live here)
    size_t           cursor;       // into the FILTERED view
    bool[BranchId]   marks;        // multi-select, indexes the BASE list
    ushort           viewportH;    // reported back by view, read by update next frame
    FilterMode       filter;
    SortMode         sort;
    SearchState      search;       // query + caret + autocomplete
    InputMode        mode;         // normal | search | confirm | help (a field, not a cascade)
    ActionLogEntry[] log;          // dry-run / delete results
    bool             quit;
}

// every input, resize, and async completion is a message
alias Msg = SumType!(Key, Resize, BranchesLoaded, ScanDone, PrFetched, Tick /*, … */);

Model update(Model m, Msg msg);          // pure; dispatches on m.mode
void  view(in Model m, return ref Buffer b);  // pure render of the model to the frame
```

`update` is where the interaction lives: it dispatches on `mode` (so a key means
different things in `normal` vs `search` vs a `confirm` modal), transitions the
model, and folds in async results (`BranchesLoaded`, `ScanDone`, `PrFetched`)
without a separate code path.

**`view` — screen regions** (a dynamic vertical layout so optional bars collapse):
header → optional search bar → optional filter tabs → content (the repo/worktree/
branch tree + a detail pane, e.g. a 70/30 split) → optional action log → footer;
modals (confirm, help) `Clear` a centered rect and render on top. The cursor row
and marked rows are highlighted; scrolling is edge-triggered off `viewportH`.

**Keymap** (a key `Msg` is interpreted per `mode` in `update`): `j`/`k` + arrows
navigate, `Space` marks, `a` select-all-safe, `c` clear, `f` toggle force, `d`
toggle dry-run, `s` cycle sort, `Tab`/`1`–`4` filter, `/` search, `Enter` confirm,
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

## Interaction polish

- **Search** is a real cursor-editable (multibyte-safe) text field with a
  scrollable autocomplete dropdown ("N more above/below", auto-scroll to the
  selection, auto-quote values containing spaces), driving an **extensible
  `@field:value` query grammar** (`@author:`, `@status:`, `@pr:`, a `me` sentinel;
  free text + field filters combine) — not a hardcoded author special-case.
- **Dual-binding keymap** — every action bound both vim-style and standard
  (`j`/`k` + arrows, `g`/`G`, `Ctrl-U`/`Ctrl-D`, `/` for search); collisions are
  reassigned deliberately.
- **State-aware footer** — the hint bar shows only currently-actionable keys and
  highlights active toggles (force / dry-run) and feature-gated hints.
- **Edge-only scrolling** — the cursor moves within the window; the list scrolls
  only at the edges (off `viewportH`), never re-centering on each move.
- **Robust lifecycle** — guaranteed raw-mode / alt-screen restore even on panic,
  with the scriptable CLI as the escape hatch; a central **semantic color theme**
  (role → color: accent / warning / danger / current / selected / success) defined
  once in `sparkles:tui` and shared.

## Event loop on `event-horizon`

The MVU runtime is driven by `event-horizon`'s `runOnce`, **not** a blocking
poll — the dman-specific improvement over the prior art:

```d
// schematic — the loop turns inputs, timers, resize, and async completions into Msgs
env.run((ref Sched s) {
    // stdin readable via the ring → decode keys/mouse → Msg
    // SIGWINCH via signals → Resize Msg;  concurrent git/scan/PR/watch → *Loaded Msgs
    // model = update(model, msg);  then draw(view(model)) → diff + flush
});
```

Because async work runs _on the same loop_ and arrives as ordinary `Msg`s, the UI
stays responsive while branches load, a scan runs, or PR status is fetched — none
of it blocks the frame, and there is no separate async-vs-input path. Setup/
teardown bracket the loop (raw-mode + alternate-screen enter/exit; `SIGWINCH` →
resize; `model.quit` exits).

## Phasing (dman-relevant)

- **P2a** — `sparkles:tui` render substrate: `Cell`/`Buffer`/`Backend`/`Terminal`
  double-buffer + cell-diff, and the box-flow layout combinators.
- **P2b** — core widgets: `List`+`ListState`, `Table`+`TableState`,
  `Tree`+`TreeState`, `Viewport`, `Paragraph` — adapting the existing one-shot
  renderers to write into a `Buffer`.
- **P2c** — the dman shell as **MVU**: the `Model`, the `Msg` sum type, pure
  `update`/`view`, panes, and modals on the `event-horizon` loop; the
  branch-management UX (classification, multi-select safe/force delete, dry-run,
  action log, filter/sort/search).
- **Deferred** — reactive/incremental rendering (partial `view` recompute) as an
  optimization; mouse; the Kitty keyboard protocol.
