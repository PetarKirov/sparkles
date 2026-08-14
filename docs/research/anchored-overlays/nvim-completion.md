# nvim-cmp and blink.cmp — completion menu & documentation placement (Lua / Neovim)

Two mature completion engines solve the same anchored-overlay problem — put a list next
to a text range, then put a documentation panel next to the list — on a pure integer
cell grid with no pointer, no hover, no focus transfer and no animation, and they
disagree on almost every structural choice.

| Field             | Value                                                                                                                                                                                                                      |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Lua (blink.cmp also ships a Rust fuzzy matcher, which contributes nothing to placement)                                                                                                                                    |
| License           | MIT (blink.cmp, © 2024 Liam Dyer) / MIT (nvim-cmp, © 2021 hrsh7th)                                                                                                                                                         |
| Repository        | [Saghen/blink.cmp][repo-blink] (primary) and [hrsh7th/nvim-cmp][repo-cmp] (comparison); [neovim/neovim][repo-nvim] read to corroborate platform behaviour                                                                  |
| Documentation     | In-tree only for this reading: `CHANGELOG.md`, the `config/` modules' LuaLS annotations, and source comments. No user-facing docs site was consulted — see the caveat below.                                               |
| Category          | Terminal / cell grid                                                                                                                                                                                                       |
| Surface model     | Both — see the surface-model note below                                                                                                                                                                                    |
| **Revision read** | blink.cmp [`8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526`][pin-blink] (2026-08-08); nvim-cmp [`2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3`][pin-cmp] (2026-07-10); neovim [`2757f6eef92a99812d5ad12408d03592bd54f10c`][pin-nvim] |

Neovim floating windows are in-canvas cell overlays: neovim's own compositor merges
every float into one terminal grid, and there is no OS popup anywhere in the stack
(see [`./neovim-floats.md`][nvim-floats] for the platform half). From a plugin's side,
however, a float behaves like an opaque popup handle: the plugin supplies a rect plus a
`zindex` and cannot paint into, across, or through the result. That split is exactly why
these two projects are worth reading together with [`./nui.md`][nui] and
[`./helix.md`][helix] — same substrate, three different divisions of labour.

> [!NOTE]
> This page is a source reading, not a runtime observation. Nothing was executed:
> neither neovim nor either plugin was run, and no profiling was done. Every arithmetic
> consequence stated below (the border double-counts, the `max_height` result, the cost
> of per-keystroke measurement) is derived by reading code at the pinned revisions.
> blink.cmp's `doc/` directory (panvimdoc output) and both projects' published
> documentation sites were not read, so "undocumented" here means "not explained in the
> source tree", not "not explained anywhere".

> [!WARNING]
> blink.cmp `HEAD` at the pinned SHA is roughly five months past its last `CHANGELOG.md`
> entry (v1.10.0), and the repository advertises a forthcoming 2.0 that may restructure
> `lua/blink/cmp/lib/window/`. Behaviour described here is `HEAD`'s, not any released
> version's. nvim-cmp carries no release tags in-tree (`scm-1`, rolling).

---

## Overview

### What it solves

Both projects must place a list of completion candidates so that it reads as belonging
to the word being typed, keep it there while the user keeps typing, and then place a
second, larger surface — the documentation panel — next to the first without covering
either the list or the line being edited. They must do this on a grid whose smallest
unit is one cell, with no pointer events reaching the overlay, no focus ever leaving the
editing buffer, and a re-placement budget of one keystroke.

The two answers are structurally opposite, and both are informative.

nvim-cmp computes everything up front in absolute screen coordinates
(`relative='editor'`) and reduces the anchor to a plain four-integer rect that the
documentation view consumes without knowing where it came from. Placement is a
straight-line sequence of comparisons: prefer below, flip above on a hardcoded
minimum-height test, then a separate horizontal right-align pass; the documentation view
prefers right, flips left, and closes if neither side fits.

blink.cmp makes the overlay tree explicit and relative. The menu is cursor-relative; the
documentation window is anchored to _the menu window_ (`relative='win', win=menu_winnr`)
— a genuine [second-order anchor][concepts] — and the signature window is anchored to
the menu as well. Placement is a small solver: build a per-direction
`{vertical, horizontal}` free-space table, stable-sort a caller-supplied priority list
with a three-tier comparator, take the head, clamp, and return `nil` — meaning "close
the window" — when nothing fits.

### Design philosophy

blink's shared window library states its own first principle in a comment: the platform's
position query is not trusted, so the anchor is a value the library computes rather than
a handle it interrogates.

```lua
-- lua/blink/cmp/lib/window/init.lua:380-382
function win:get_direction_with_window_constraints(anchor_win, direction_priority, desired_min_size)
  -- nvim.win_get_position doesn't return the correct position most of the time
  -- so we calculate the position ourselves
```

The second principle is that a placement that cannot be satisfied is a dismissal, not a
clip. Every solver in blink returns `nil` and every caller closes; nvim-cmp reaches the
same conclusion by a different route, and states it in three lines when neither side of
the menu has room for the documentation panel:

```lua
-- lua/cmp/view/docs_view.lua:93-98
  elseif left_space >= width then
    col = left_col
    left = true
  else
    return self:close()
  end
```

The third — visible only by comparison — is that blink factors a real shared placement
primitive and nvim-cmp does not. blink's `blink.cmp.Window` serves three surfaces (menu,
documentation, signature) and holds all the geometry; nvim-cmp's `cmp.Window` shares
options, borders, content height and a scrollbar but no placement logic at all, and its
two surfaces consequently ship inconsistent policies (the menu shrinks to fit, the docs
panel closes; the menu reserves an edge cell, the docs panel does not; the menu defaults
to `zindex = 1001`, the docs panel to `50`).

---

## How it works

### blink: three surfaces, one solver, three policy sets

`lua/blink/cmp/lib/window/init.lua` is a ~500-line `blink.cmp.Window` type constructed
from a `WindowOptions` value. It owns open/close, content measurement, size fitting,
border accounting, the anchor-space query, two direction solvers, a scrollbar, the
cursorline priority workaround, and the command-line redraw coalescer. Above it sit three
policy modules of 200–280 lines each:

| Surface       | Anchor                                   | Priority list                                                       | Desired minimum   | Delay                             |
| ------------- | ---------------------------------------- | ------------------------------------------------------------------- | ----------------- | --------------------------------- |
| menu          | `relative='cursor'` (text-range aligned) | `{'s','n'}`, or a function                                          | `max_height = 10` | `auto_show_delay_ms = 0`          |
| documentation | `relative='win'` on the menu             | `menu_north = {'e','w','n','s'}` / `menu_south = {'e','w','s','n'}` | `50 × 10`         | `500` first show, `50` while open |
| signature     | `relative='win'` on the menu             | one forced direction, opposite the menu (or the built-in pum)       | inherits          | none                              |

Read the documentation priority pair carefully: the child's fallback ordering _differs
depending on which side the parent landed on_, and in both cases the last two entries are
ordered so the child prefers the side away from the cursor.

### nvim-cmp: two views, two independent placers, one anchor value

`custom_entries_view.open` and `docs_view.open` each compute their geometry from scratch.
What connects them is a plain value: `custom_entries_view.info()`
(`lua/cmp/view/custom_entries_view.lua:328`) returns
`{row, col, width, height, inner_*, border_info, scrollable, scrollbar_offset}` derived
from the window's _stored style_, and `docs_view.open(entry, view, bottom_up)` consumes
only `view.row/col/width/height` plus one boolean. The same rect shape is produced by
`native_entries_view.info()` (`:99-101`) from vim's built-in C popup menu via
`vim.fn.pum_getpos()`. Two unrelated anchor producers, one consumer, no shared type.

### The re-placement loop

There is no observer, no polling and no frame callback in either project. blink re-places
from exactly three editor autocmds — `CursorMovedI`, `WinScrolled`, `WinResized`
(`lua/blink/cmp/completion/windows/menu/init.lua:70`) — plus an emitter cascade
(`position_update_emitter` → the children re-place; `close_emitter` → the children
close). nvim-cmp does less: it recomputes inside `open()`, and `view.on_entry_change` is
`async.throttle(…, 20)` (`lua/cmp/view.lua:284`, closing at `:314`), so during fast typing
the docs window is re-placed at most fifty times a second.

---

## The analysis spine

### 1. Anchor model

The two projects sit at opposite ends of the design space.

nvim-cmp's anchor is a **plain comparable value** — four integers plus one boolean. The
boolean is the anchor's own resolved side (`bottom_up`), passed explicitly to the child
(`lua/cmp/view.lua:195-196`). blink's anchor is a **live handle**:
`get_direction_with_window_constraints(anchor_win, …)` takes a `blink.cmp.Window` and
re-queries `nvim_win_get_config()`, the window position, the border size, the height and
the width on every call — then rebuilds a rect anyway, because the platform's stored
config addresses the window's _text area_, not its outer rect.

Four anchor kinds are actually in use: a cursor point (blink's menu); a **text-range
start** — both projects align the menu to the first column of the matched keyword rather
than to the cursor, so the menu does not slide sideways as you type; **another overlay**
(blink's documentation and signature windows); and a **synthetic screen point** for
command-line mode, supplied by a user-configurable function so external UI plugins can
declare where the command line actually is.

Anchor→screen conversion is **not live for the primary anchor**. Verified in the neovim
tree: `nvim_open_win` with `relative='cursor'` is rewritten _once_ into `relative='win'`
plus the cursor's current `w_wrow`/`w_wcol` (`src/nvim/winfloat.c:204-209`). The menu is
therefore a snapshot of the cursor at open time, and blink must re-run
`menu.update_position()` from autocmds to keep it glued. The docs→menu link, by contrast,
_is_ live: `relative='win'` floats are marked for re-layout when the parent moves
(`win_check_anchored_floats`, `src/nvim/winfloat.c:323-331`). blink's overlay tree thus
has a live second edge on top of a snapshotted first edge.

Many triggers, one popup: implicitly yes. One singleton menu window and one singleton
docs window per plugin, module-level, reused across every completion context;
`docs.shown_item` is the identity key that decides whether to re-render the buffer.

**Algorithm** — blink's anchor rect derivation (`lib/window/init.lua:383-420`):

```text
cfg = nvim_win_get_config(anchor)
if   cfg.relative == 'win':    base = win_get_position(cfg.win); row = cfg.row + base[1] + 1; col = cfg.col + base[2] + 1
elif cfg.relative == 'editor': row = cfg.row + 1; col = cfg.col + 1
else: assert-fail
if col + cfg.width > columns: col = columns - cfg.width      # keep the anchor on screen first
anchor_col = floor(col - border.left);  anchor_row = floor(row - border.top)   # outer, 1-based
anchor_w   = inner_w + border.horizontal; anchor_h = inner_h + border.vertical
```

**Where it lives.** Library code entirely. Neither project delegates anchoring to the
platform beyond `relative='cursor'|'win'|'editor'`; neovim's compositor owns only the
final rect→grid mapping and the parent-moved invalidation.

**Degradation.** Survives everything. Four integers plus an enum side is the whole
anchor; it needs no OS window, no hover, no script, no sub-cell precision and no key
release. nvim-cmp demonstrates that the value form works across two unrelated producers,
one of which is a C popup the plugin cannot touch. The only thing lost without a platform
window is the automatic re-anchoring of `relative='win'` children — which a toolkit that
rebuilds its display list every frame gets for free.

### 2. Placement model

Sides are cardinal only: blink uses the literal characters `'n'`/`'s'`/`'e'`/`'w'`;
nvim-cmp uses two independent booleans (`bottom_up`, `left`). Neither tree contains a
start/end logical axis, an RTL concept, writing modes, safe-area insets, multi-monitor
handling, or IME avoidance — a grep for `rtl` returns nothing in either.

**Preferred lists are data** in blink and are the core of its API:
`completion.menu.direction_priority` defaults to `{'s','n'}`
(`config/completion/menu.lua:34`), and the documentation window's is the parent-side-keyed
pair at `config/completion/documentation.lua:63-66`. A priority list may also be a
**function**, re-evaluated on every selection change
(`completion/windows/menu/init.lua:149-152`, added for issues 2000 and 1801) — and only
when it is a function, so the common static case pays nothing.

nvim-cmp has no priority list. It has `view.entries.vertical_positioning` ∈
`{'below','above','auto'}` (default `'below'`, `config/default.lua:102`) and hardcoded
branches. One oddity: `'auto'` places the menu **above** when the cursor is in the **top**
half of the screen (`is_in_top_half` at `custom_entries_view.lua:199`, used as a positive
term in `should_position_above` at `:200`) — the inverse of a free-space heuristic. The
introducing commit `5124cdd` says "'above' works best with `vim.opt.scrolloff = 999`",
i.e. the mode targets a pinned-centre cursor. _This reads as a stability heuristic (keep
the menu in a predictable screen region) rather than a fit heuristic — that reading is an
inference; nothing in the tree documents the intent._

Flip, shift and shrink all appear, in different places:

- **blink menu** — flip only (`n`↔`s`), then shrink height to the winning side's free
  space. Never shifts vertically. Horizontally it neither flips nor shifts: `col` is
  whatever the keyword alignment says, and `lib/window/init.lua:174` carries a literal
  `-- TODO: never go above the screen width and height` admitting the gap.
- **nvim-cmp menu** — flip vertically; horizontally it **shifts** (right-aligns to
  `columns - width - border - 1`) and only then shrinks if the shift pushed `col`
  negative. The horizontal pass is gated on the anchor being in the right half _and_ the
  remaining width being insufficient, so a wide menu at column 5 of an 80-column screen is
  left to overflow the right edge.
- **nvim-cmp docs** — flip only (right↔left); never shifts, never shrinks horizontally.
  It closes instead.
- **blink docs** — flip across four sides, then shrink both width and height to the
  winning direction's constraints, then close if the residue is smaller than the border.

**Viewport padding**: nvim-cmp reserves exactly one cell at the right edge
(`custom_entries_view.lua:213`) and one line at the bottom (`utils/window.lua:85`). blink
reserves none. **Clipping boundary**: always the whole editor grid (`vim.o.lines` /
`vim.o.columns`). Neither clips to the current split — a float may and does spill over
neighbouring windows.

**Algorithm** — nvim-cmp's menu placement (`custom_entries_view.lua:179-217`), the
compact version of the whole model:

```text
H = (max_height or pumheight) or #entries;  H = min(H, #entries)
row, col = screen_cursor.row, screen_cursor.col - keyword_delta - 1
bo_r = border.top + border.bottom;  bo_c = border.left + border.right
cant_bottom = lines - row - bo_r <= min(10, H)
cant_top    = row - bo_r         <= min(10, H)
above = cant_bottom or (prefers_above and not cant_top) or (prefers_auto and cursor_in_top_half)
if above: H = min(H, row - 1); row = row - H - bo_r - 1; if row < 0: H += row
if floor(cols*0.5) <= col + bo_c and cols - col - bo_c <= W:
    W = min(W, cols - 1); col = cols - W - bo_c - 1; if col < 0: W += col
open(relative='editor', row=max(0,row), col=max(0,col+col_offset), W, H)   # refuses if W<1 or H<1
```

**Where it lives.** Library code. Neovim contributes clamp-free rect placement and an
implicit "a float may hang off the grid" policy. One platform appearance setting does feed
the geometry budget: `vim.o.winborder` is read as the default border in both trees
(`lib/window/utils.lua:6`; `lua/cmp/config/window.lua:17`).

**Degradation.** Fully portable — integer arithmetic over (viewport, anchor rect, desired
size, priority list). No hover, no script, no OS window and no key release is involved.
Without script (a static HTML target) you lose the solver but not the model: one side must
be baked at emit time and clipping accepted. The soft-keyboard case is already solved in
shape by the injected command-line origin: the viewport origin is an input, not a probe.

### 3. Collision & geometry engine

Overflow detection is pure arithmetic against `vim.o.lines` / `vim.o.columns`. There is no
clipping-ancestor discovery because there are no ancestors — floats are siblings in one
compositor. Scroll containers are irrelevant: the menu's own scroll is internal
(`topline`) and does not move the window.

**The measure/place ordering is a hard dependency and both projects are bitten by it.**
blink's sequence is `update_size()` (fit to content, clamped by min/max) → read
`get_height()`/`get_width()` → solve direction → `set_height()`/`set_width()` →
`set_win_config()`. The solver's `max_height`/`max_width` are therefore the _current
realised outer size_, not the desired size: placement is measured against a window that
already exists. nvim-cmp cannot even do that for the scrollbar — whether a window needs
one depends on its realised inner height, which changes its effective width by one cell,
which shifts a **left**-placed window by one cell:

```lua
-- lua/cmp/view/docs_view.lua:117-121
  -- Correct left-col for scrollbar existence.
  if left then
    style.col = col - self.window:info().scrollbar_offset - documentation.col_offset
    self.window:open(style)
  end
```

Two window creations for one placement.

**Three border double-counts** are readable in blink's constraint table
(`lib/window/init.lua:421-441`): the `s` constraint adds `anchor_border_size.vertical` to a
height that `get_height()` already included; the `e` constraint subtracts
`anchor_border_size.right` from a width that `get_width()` already included; and the `w`
constraint _adds_ `anchor_border_size.left` to the space left of the anchor's outer left
edge. _Reading the arithmetic, the first two make the solver conservative (it under-reports
space and may flip earlier than necessary) and the third is permissive (it lets the docs
window overlap the menu's left border column by one cell). Those consequences are derived,
not observed._ None of the three is covered by a test.

A fourth conflation is user-visible: **`max_height` is compared against outer heights.**
`update_size()` caps the _inner_ height at `max_height`; `get_height()` adds the border;
the solver then computes `min(get_height(), distance, max_height)` and subtracts the border
again. Reading that chain, a bordered menu configured with `max_height = 10` yields eight
visible rows — the border is budgeted _inside_ the cap, not added on top of it. Commit
`9446f50` ("fix: pick menu direction based on max height") introduced `max_height` into
that expression; before it the sort key was the window's own height, so a direction with 40
free lines beat one with 12 when only 10 were wanted.

**Stable sort as the engine.** Both of blink's solvers express "honour the author's order
unless it does not fit" as a stable sort whose comparator returns `0` for ties. blink calls
`vim.fn.sort` — documented stable at `runtime/doc/vimfn.txt:10686` ("The sort is stable,
items which compare equal …") — at exactly the two direction-solving sites, and
`table.sort` (unstable) elsewhere in the tree. No comment explains the distinction; whether
the choice is deliberate could not be established from the tree.

No transforms, no zoom, no device pixel ratio, no fractional cells — except one telling
line: nvim-cmp's `set_style` does `math.ceil` on width and height
(`utils/window.lua:93-94`) with the comment that GUI clients may return fractional bounds
but integer bounds are needed to open the window. Even there the fractional input is
rounded _at the boundary_ and the placement arithmetic stays integral.

**Algorithm** — blink's three-tier direction comparator
(`lib/window/init.lua:445-479`), the most transferable artefact in either repository:

```text
constraints[dir] = { vertical: free_cells, horizontal: free_cells }   # per side, see dimension 2
desired          = { width: 50, height: 10 }                         # config, per overlay

cmp(a, b):
    fits_a = desired.h <= constraints[a].vertical and desired.w <= constraints[a].horizontal
    fits_b = same for b
    if fits_a and fits_b: return 0        # tie -> the STABLE sort keeps the author's order
    if fits_a: return -1
    if fits_b: return  1
    return compare_desc( min(max_height, constraints[a].vertical, constraints[a].horizontal),
                         min(max_height, constraints[b].vertical, constraints[b].horizontal) )

dir = stable_sort(priority, cmp)[0]
H = min(max_height, constraints[dir].vertical);   if H <= border.vertical:   return NONE
W = min(max_width,  constraints[dir].horizontal); if W <= border.horizontal: return NONE
return { dir, width: W - border.horizontal, height: H - border.vertical }
```

The wart worth not copying is in tier 3: the key clamps a term containing `horizontal` by
`max_height`, collapsing the two axes into one scalar.

**Cost.** The solver is `O(k log k)` over `k ≤ 4` directions. The expensive part is
measurement, not arithmetic: `get_content_width()` iterates every buffer line calling
`strwidth` (`lib/window/init.lua:263`), `get_content_height()` calls
`nvim_win_text_height` under a `--- TODO: fix nvim_win_text_height`, and nvim-cmp's
`get_content_height()` re-wraps every line when `wrap` is set (`utils/window.lua:316-331`).
Both run on every keystroke; no profiling was done here, so the cost is read from the loops
rather than measured.

**Where it lives.** Library code. The only platform participation is neovim's refusal to
open a window narrower or shorter than one cell (`utils/window.lua:116-118`, which
nvim-cmp turns into a silent no-menu at `custom_entries_view.lua:246-248`) and its
re-layout of `relative='win'` children.

**Degradation.** The solver is fully portable: integers in, integers out. What does _not_
survive is the measure-then-place ordering — both projects rely on opening, measuring and
re-opening. A `view → layout → buildDisplayList → paint` pipeline measures content in the
layout pass and places in the same pass, which removes nvim-cmp's two-pass scrollbar hack
outright. With no script the solver cannot run at all and one side must be baked; with no
OS window nothing changes, because the arithmetic never needed one.

### 4. Arrow / caret geometry

Absent from both trees, and the absence is the finding. Neither plugin draws a tail, beak,
notch or connector; there is no arrow concept, no [transform origin][concepts], no
side-derived offset. Three mechanisms stand in for it.

1. **Adjacency is the arrow.** The overlay is placed flush against what it describes:
   `row = 1` is the very next line below the cursor, `row = -(H + border.vertical)` the
   very last line above it, and the docs panel's `col = menu_width + menu_border.right` is
   the column immediately right of the menu's outer edge. Zero gap; the relationship is
   carried entirely by contact.
2. **The one-cell gap is a negative arrow.** The only place a gap is deliberately inserted
   is where an overlay would otherwise cross the cursor row — the `±1` in the `n`/`s`
   entries of blink's positions table (`completion/windows/documentation.lua:204` and
   `:208`). The grid's unit of "pointing" is not a glyph but the presence or absence of one
   reserved cell.
3. **Alignment is the arrow.** Both projects align the menu's first _content_ column
   (border excluded) to the first character of the keyword being matched. The column
   correspondence between the typed prefix and the menu's labels _is_ the pointer — which
   is why both compute the offset from raw buffer text rather than from screen position.

**Algorithm** — the column-identity rule that replaces the caret:

```text
align_offset = strdisplaywidth(line[0 .. keyword_start-1]) - cursor_virtual_col
content_col  = align_offset - renderer.alignment_start_col(component)
outer_col    = content_col - border.left
```

`alignment_start_col` (`completion/windows/render/init.lua:158`) is the column of a named
draw component — the `label` column by default, not the icon column — inside the menu's
own row layout, so the label lines up with the typed text.

**Where it lives.** Library code; the renderer bridges its row-layout model into the
placement math. Nothing platform-side.

**Degradation.** Nothing to degrade. Contact, a reserved cell and column identity all work
with no OS window, no hover, no script, no sub-cell precision and no key release, and all
three survive to a static HTML target. On this subject's evidence, a cell-grid arrow
primitive is an optional one-cell gap flag plus an align-to-column integer, not a glyph.
[`./features-people-forget.md`][forget] carries the cross-subject version of that claim.

### 5. Trigger semantics

**No pointer triggers at all.** `lua/` in nvim-cmp has zero matches for `mouse`; blink has
two, one an unrelated comment and one `focusable = false` on a scrollbar float
(`lib/window/scrollbar/win.lua:84`). No hover, no click, no long press, no context menu, no
pointer-type distinction, no assistive-technology path. That makes this subject an unusually
clean read on what an anchored overlay needs when hover does not exist.

**The trigger vocabulary is text state, not input device.** blink's trigger
(`completion/trigger/init.lua`) dispatches on: a character inserted; that character being a
source-declared trigger character; backspace; backspace into a keyword; backspace after
entering insert mode; backspace after an accept; cursor moved; insert mode entered; and an
explicit programmatic `show()`. Each has its own enable flag and each carries a
`trigger_kind` tag (`'keyword'`, `'trigger_character'`, `'prefetch'`, manual) down into the
context — so the trigger's identity is preserved into the state, which is how the menu
later decides whether auto-show applies.

**Race combination** is handled by giving the context a monotonically increasing `id` plus
a cursor position and keying the pending show timer on the composite:

```lua
-- lua/blink/cmp/completion/windows/menu/init.lua:178-181
  local timer_key = string.format('%d|%d|%d', context.id, context.pos.row, context.pos.col)
  if menu.auto_show.timer:is_active() and menu.auto_show.timer_key == timer_key then return end
```

A second trigger with the same key does not restart the timer, so repeated identical
triggers cannot starve the delay; a different key overwrites and restarts. blink's own code
records that this is not sufficient — an explicit `TODO` at `:183-186` documents a surviving
race (timer fires → schedules the callback → `reset_auto_show()` stops the timer → the
already-scheduled callback runs anyway).

**A programmatic trigger needs a different policy**, and blink implements that by _mutating
the policy_: `menu.force_auto_show()` replaces `auto_show.enabled` / `auto_show.delay_ms`
with constant functions, and `reset_auto_show()` rebuilds them from config when the menu
closes. The comment calls it a `HACK` because the trigger source is not threaded through the
show event — even though `auto_show.enabled(context, items)` already receives the context
that carries `trigger_kind`.

nvim-cmp's equivalent surface is `cmp.complete()`, `cmp.scroll_docs(delta)`
(`lua/cmp/init.lua:203`), `cmp.open_docs()` (`:218`) and `cmp.close_docs()` (`:228`) — all
keyboard or programmatic. Its docs window carries a pinned bit
(`view.is_docs_view_pinned`, `lua/cmp/view.lua:188`) so an explicitly opened panel survives
selection changes that would otherwise leave it closed.

**Algorithm** — the show-trigger dedup (`completion/windows/menu/init.lua:159-196`):

```text
enabled = auto_show.enabled(context, items)          # boolean or user fn(ctx, items)
if not enabled: return
delay = max(0, auto_show.delay_ms(context, items) - (now - context.timestamp))
if delay == 0: stop_timer(); open(); place(); return
key = f"{context.id}|{context.pos.row}|{context.pos.col}"
if timer.active and timer.key == key: return         # idempotent re-trigger
timer.key = key
timer.start(delay, once, schedule_wrap(open; place))
```

**Where it lives.** Library code over neovim autocmds (`InsertCharPre`, `TextChangedI`,
`CursorMoved(I)`, `InsertEnter`, `ModeChanged`, `BufLeave`, `CompleteChanged`), normalised
into a plugin-level vocabulary by `lib/buffer_events.lua`, `lib/cmdline_events.lua` and
`lib/term_events.lua`. That normalisation layer exists precisely because three input
contexts must produce the same trigger vocabulary.

**Degradation.** This dimension is already the degraded case and it works: with no hover,
no key release and no pointer, blink still supports six distinct show conditions, because
each is a predicate over (text before cursor, previous event, cursor delta) rather than over
an input device. A static HTML target loses all of it — the triggers are timers and text
mutations — and the honest tier-0 fallback there is `:focus-within` on a container meaning
"menu open".

### 6. Timing

blink implements a warm-up / skip-delay machine in a cell grid, with three delays and one
budget subtraction.

- `completion.menu.auto_show_delay_ms` = `0` (menu, first show).
- `completion.documentation.auto_show_delay_ms` = `500`
  (`config/completion/documentation.lua:38`).
- `completion.documentation.update_delay_ms` = `50` — the delay used when the item changes
  _while the panel is already open_.

The skip-delay branch is one `if` (`completion/windows/documentation.lua:45-56`): if the
docs window is open use the 50 ms update delay, else if auto-show is on use the 500 ms
initial delay. The first docs panel costs half a second of dwell; every subsequent
arrow-key move re-renders in 50 ms — the classic "instant subsequent tooltips" behaviour,
expressed without a group abstraction because there is exactly one docs window.

**The floor is enforced by the config validator**, not by documentation:

```lua
-- lua/blink/cmp/config/completion/documentation.lua:39-45
  update_delay_ms = {
    50,
    config.types.validator(
      'number >= 50 (lower causes lag)',
      function(delay) return type(delay) == 'number' and delay >= 50 end
    ),
  },
```

**The delay budget is measured from the trigger, not from content arrival**
(`completion/windows/menu/init.lua:167`):

```lua
  local delay_ms = math.max(0, auto_show_delay_ms - (vim.uv.now() - context.timestamp))
```

`context.timestamp` is when the keystroke created the context, not when the async source
answered. If an LSP took 400 ms and the configured delay is 500 ms, the menu appears 100 ms
later, not 500.

> [!IMPORTANT]
> The 0 ms case oscillated in history and the scar is still in the file. Commit `5beb962`
> ("always defer menu display through event loop … the immediate execution path bypassed
> event loop batching, causing visual artifacts") deleted the synchronous fast path and left
> the comment "note we should use timer, even for 0ms, to prevent synchronous geometry
> races". Commit `11a8888` ("fix: race with no auto show delay") put the fast path back and
> left the contradicting comment in place directly beneath it, so `HEAD` contains a 0 ms
> synchronous open sitting under a comment saying not to do that. Both orderings are broken
> in different ways; the underlying defect is that the timer has no cancellation token.

nvim-cmp's timing is a single 20 ms throttle on `view.on_entry_change` plus a resolve dedup
— no warm-up, no skip-delay, no cool-down. Absent from both trees: maximum display
duration, re-entry grace, neighbour traversal, and any close delay at all. Closes are
immediate and unconditional (`nvim_win_close(id, true)`).

**Algorithm** — the state machine as it should be, reconstructed from what blink gets right
and what it gets wrong:

```text
states: Idle -> Pending(deadline, key) -> Open(item) -> Idle
inputs: Trigger(key, kind, t0), ContentReady(items), Select(item), Dismiss(reason), Tick(now)

on Trigger(k, kind, t0) in Idle:
    delay    = policy(kind, is_open = false)      # 500 for docs, 0 for menu
    deadline = t0 + delay                         # NOT now + delay: budget from the trigger
    if deadline <= now: -> Open  else: -> Pending(deadline, k)
on Trigger(k, ...)  in Pending(d, k):  ignore     # idempotent; do not restart
on Trigger(k', ...) in Pending(d, k):  -> Pending(recompute, k')
on Select(item) in Open:
    deadline = now + policy(kind, is_open = true) # the 50 ms skip-delay branch
on Dismiss in any: cancel by BUMPING A GENERATION COUNTER, never by stopping a timer
on Tick(now >= deadline) in Pending(d, k) with generation unchanged: -> Open
```

**Where it lives.** Library code (`blink.lib.timer` wrapping `uv_timer_t`, plus
`vim.schedule_wrap` to hop back to the main loop). The libuv timer and neovim's scheduler
are the only platform pieces; the policy is entirely blink's.

**Degradation.** Timers are the one thing here that does not survive to a static HTML
target: with no script there is no warm-up, no skip-delay and no budget subtraction — tier-0
CSS can express "shown while hovered or focused" and nothing about _when_. On TUI, GUI,
Android and a recording backend, timers exist and the whole machine ports. For a recording
canvas the machine is only assertable if time is _injected_ (a `now` parameter, as in the
`Tick` input above); blink reads `vim.uv.now()` inline and is correspondingly untestable.

### 7. Interactive hover

Wholly absent, and that is a high-value negative result for a toolkit whose Android target
has no hover at all.

There is no trigger→content travel because the pointer never enters the overlay: no
[safe polygon][concepts], no pointer bridge, no menu-aim heuristic, no interactive border,
no trajectory prediction, no hover debounce. Both projects have submenu-shaped structure
(menu → documentation → scrollbar) and needed none of it, because traversal from the menu
into the documentation is not spatial — it is a **keybinding**. `cmp.scroll_docs(delta)` in
nvim-cmp and `scroll_documentation_up`/`_down` onto `docs.scroll_up`/`scroll_down` in blink
scroll the child _remotely_, from a keymap that is active while the parent has logical
focus. Nothing crosses the gap because nothing needs to. The cost in whole cells is zero:
the overlays are flush (dimension 4), and the one deliberate gap — the reserved cursor row
— is never traversed by a pointer.

The nearest thing to a spatial-intent heuristic in either tree is blink's `scrolloff = 2`
(`config/completion/menu.lua:29`), which keeps two rows of context above and below the
selected row. That is intent about the content, not about a pointer.

**One real nested-surface problem does exist**, and it is solved geometrically rather than
with hover logic. Three sibling overlays (menu, documentation, signature) must not overlap,
and blink solves that by _removing a direction from the priority list_:

```lua
-- lua/blink/cmp/completion/windows/documentation.lua:165-171
  local signature = require('blink.cmp.signature.window')
  if signature.win and signature.win:is_open() then
    direction_priority = vim.tbl_filter(
      function(dir) return dir ~= (menu_win_is_up and 's' or 'n') end,
      direction_priority
    )
  end
```

Occupancy is expressed as a subtraction from the candidate set, not as a collision
rectangle.

**Algorithm** — sibling avoidance, the whole rule:

```text
candidates = priority_list_for(parent_side)
for each other open sibling S anchored to the same parent:
    candidates = candidates \ { side_occupied_by(S) }
solve(candidates)
```

Cost: `O(siblings)` set subtraction over a ≤4-element list. Zero cells of tolerance, zero
timers.

**Where it lives.** Library code — and awkwardly: `documentation.lua` reaches into
`blink.cmp.signature.window` at call time, a hard module dependency between two peer
overlays rather than a shared occupancy registry.

**Degradation.** Nothing to degrade. This dimension shows that a shipped anchored-overlay
system can carry zero hover machinery when traversal into a child surface is a keybinding
rather than a pointer journey. A target with no hover loses nothing here, and neither does
one without keyboard key-release edges: remote scroll and set subtraction need neither.

### 8. Dismissal

Dismissal is a fan-out from one authority plus a set of geometric self-closes, and the
split between the two is the interesting part.

**Authority-driven** (blink's `completion/trigger/init.lua`): `trigger.hide()` fires on
insert-leave (`:154`), on command-line leave (`:165`), on terminal leave (`:175`), when the
built-in popup menu becomes visible (`:156`, and defensively again at `:235`), and when no
trigger condition matches after a text change (`:140`). `Ctrl-C` is handled separately
because it does not fire `InsertLeave`; Escape is a keymap, not an autocmd.

**Cascade**: `menu.close_emitter` → `docs.close()`
(`completion/windows/documentation.lua:43`). The parent closing closes the child, and that
is the only ownership link — there is no overlay-tree object, just an event emitter per
lifecycle transition, each mirrored to a public autocmd (`BlinkCmpMenuOpen`,
`BlinkCmpMenuClose`, `BlinkCmpMenuPositionUpdate`, `menu/init.lua:65-67`).

**Geometric self-close — failure to place is a dismissal.** Both solvers return
`nil`/close rather than clipping: blink's menu at `menu/init.lua:232-236`, its docs at
`documentation.lua:179-183`, its signature window likewise; nvim-cmp's docs view at
`docs_view.lua:96-97`; and nvim-cmp's window layer silently refuses to open below one cell
in either axis (`utils/window.lua:116-118`), with the caller bailing on the nil handle
(`custom_entries_view.lua:246-248`). Because re-placement runs on `CursorMovedI`,
`WinScrolled` and `WinResized`, a running overlay **dismisses itself** when the viewport
shrinks past its minimum. "Anchor scrolled out of view" and "window resized too small" are
not special cases; they are the ordinary placement path returning nothing.

**Dismissal is also a content decision**: blink's docs closes when the resolved item has
neither `documentation` nor `detail` (`documentation.lua:72-75`) and when the item is nil or
the menu is not open (`:60`); nvim-cmp's closes when the entry yields zero document lines or
the computed size is degenerate.

Absent from both: click-outside, pointer-down-versus-up identity, focus-outside,
window/application deactivation, navigation, touch-outside — all pointer or OS concepts
with no analogue here. Scroll dismisses only indirectly (`WinScrolled` → re-place →
possibly no fit). There is no fade and no close delay.

**Algorithm** — placement-as-dismissal:

```text
on (trigger | cursor_moved | scrolled | resized | selection_changed):
    if not open: return
    resize_to_content()
    pos = solve_direction(...)          # returns NONE when the residue <= border
    if pos is NONE: close(); return     # <-- dismissal
    apply(pos)
    emit position_update                # children re-place, or close themselves
```

**Where it lives.** Library code. Neovim contributes the autocmd sources and the hard
refusal to open sub-1×1 windows.

**Degradation.** All of it survives every constrained target, because none of it is
pointer- or focus-based. Android's system back key maps naturally onto the same
`trigger.hide()` authority. The re-place-or-close rule is especially valuable when the
viewport inset changes (a soft keyboard opening): the overlay that no longer fits dismisses
itself rather than being drawn under the keyboard. On a recording backend every one of
these is assertable, because each is a pure function from (viewport, anchor, content size)
to open/closed.

### 9. Focus

**The overlay is never focused.** Every window in both projects is opened with
`enter = false` — `nvim.open_win(self:get_buf(), false, {…})` at
`lib/window/init.lua:122`, `vim.api.nvim_open_win(self:get_buffer(), false, s)` at
`lua/cmp/utils/window.lua:125`. Keyboard focus stays in the editing buffer for the entire
lifetime of the menu, the documentation panel and the signature panel.

Consequently there is no initial focus, no autofocus, no restoration, no
[focus scope][concepts] or trap, no containment, no tab order and no escape-of-focus.
"Selection" in the menu is **not focus** — it is a cursor position inside the menu's buffer,
set remotely from a keymap bound in the _editing_ buffer:

```lua
-- lua/blink/cmp/completion/windows/menu/init.lua:144-152
function menu.set_selected_item_idx(idx)
  menu.win:set_option_value('cursorline', idx ~= nil)
  menu.selected_item_idx = idx
  if menu.win:is_open() then menu.win:set_cursor({ idx or 1, 0 }) end
  if type(config.direction_priority) == 'function' then menu.update_position() end
end
```

Note the last line: selection can change geometry, but only when the priority list is a
function.

Painting that selection needed a workaround worth knowing for any theme layer. Neovim draws
`CursorLine` _below_ other highlights unless it carries a foreground colour
(`lib/window/cursor_line.lua:4-8`), so blink re-implements the selection background as an
ephemeral extmark at priority 10000 through a decoration provider and exposes
`draw.cursorline_priority` (`config/completion/menu.lua:61`) so item-kind highlights at
20000 can beat it. **Selection painting is a priority problem, not a focus problem.**

**Focusability is separate from focus**, and blink allows the former: `focusable` is left at
its default for the menu, docs and signature windows, while the scrollbar gutter and thumb
are explicitly `focusable = false` (`lib/window/scrollbar/win.lua:84`). So `<C-w>w` can
reach the docs panel to read it, but nothing focuses it automatically.

Keeping the four roles distinct, as this subject models them:

| Role    | This subject's instance | Properties                                                                            |
| ------- | ----------------------- | ------------------------------------------------------------------------------------- |
| tooltip | documentation panel     | never focused, never interactive, content-only, dismisses with the parent             |
| menu    | the completion list     | never focused, but owns a selection driven by remote keys; selection is state         |
| popover | signature help          | never focused, remotely scrollable, coexists with the menu by geometric exclusion     |
| dialog  | —                       | does not exist in either tree; neither project ever takes focus, and nothing is modal |

**Where it lives.** Library code plus one platform primitive: the `enter` argument to
`nvim_open_win`. The absence of focus is a one-argument decision, repeated in both projects.

**Degradation.** Survives everything. With no OS window there is no window focus to take;
without keyboard key-release edges a focus trap cannot be escaped reliably; on Android there
is no keyboard focus at all until the soft keyboard appears. A never-focused overlay whose
selection is remote state is the portable design, and both of these implementations
converged on it.

### 10. Layering & portals

Neovim provides a genuine [top layer][concepts] — floats are composited above the editor
grid by `zindex` (`float_zindex_cmp`, `src/nvim/winfloat.c:289`) — and the two projects use
it very differently, which is what makes this dimension informative for a toolkit that has
no top layer at all.

**blink** gives every window the same `zindex = 1001`, hardcoded at the single
`nvim.open_win` call site (`lib/window/init.lua:129`), with no per-window override anywhere
in the config surface. Ordering among menu, docs and signature is therefore undefined by `z`
and **defined by geometry** — they are placed so as never to overlap (opposite sides of the
menu; a direction removed from the candidate list when a sibling occupies it). The only
`z`-ordering blink relies on is scrollbar-relative: gutter at parent+1, thumb at parent+2
(`lib/window/scrollbar/geometry.lua:89-93`). `z` is used for decoration-on-a-surface, never
for surface-versus-surface.

**nvim-cmp** relies on `z`. Completion defaults to `zindex = 1001`
(`custom_entries_view.lua:241`); documentation defaults to `documentation.zindex or 50`
(`docs_view.lua:113`) — eighteen layers below the menu, so an overlap resolves in the menu's
favour. That is a real semantic difference from blink and it is not explained in the tree;
only the `window.bordered()` preset raises a surface to 1001.

**Overlay trees and ownership.** There is no tree object in either codebase. blink expresses
the tree as three emitters on the parent that children subscribe to at module load, plus a
direct `require` from child to parent for geometry — `documentation.lua` requires `menu`,
`signature/window.lua` requires `menu`, and `documentation.lua` requires
`signature.window` lazily to dodge a cycle. The ownership graph is implicit in the module
graph. nvim-cmp keeps ownership explicit in one place: `cmp.view` owns
`custom_entries_view`, `docs_view` and `ghost_text_view`, every close path closes all three
(`lua/cmp/view.lua:152`), and the child never reaches back — the parent _pushes_ the anchor
rect down.

**Public API versus implementation detail.** blink publishes the emitters as autocmd names,
publishes the direction-priority lists, and publishes a `draw(opts)` hook that receives the
live `blink.cmp.Window` object (`documentation.lua:92-102`), leaking `set_height`,
`set_width`, `set_win_config` and the whole geometry surface into user configuration. A
content hook should receive a size budget, not a placer.

**Portals / clipping escape**: nothing to escape. A float is never clipped by another
window; it can and does hang off the editor grid edge.

**Degradation.** blink's policy ports to a single-surface toolkit unchanged: with no top
layer, no `z` and no stacking context, "later in the display list" is enough _provided_ the
placer guarantees disjointness among siblings. nvim-cmp's policy does not port — it depends
on a real `z` comparison to resolve overlaps its placer permits. The lesson is direct:
sibling occupancy must be an **input to placement** (a set of already-claimed sides or
rects), not a rendering-time tie-break.

### 11. Modality

**Every surface is non-modal, and not even light-dismiss.** There is no modal mode anywhere
in either tree: no scrim, no dim, no background pointer blocking, no background keyboard
blocking, no accessibility modal bit, no [light dismiss][concepts] region.

The reason is structural and worth naming: **keyboard input is never routed to the
overlay.** Keys are bound in the editing buffer and act on the overlay by proxy
(`menu.set_selected_item_idx`, `docs.scroll_up`/`scroll_down`). Since the overlay never
receives input, there is nothing to block and no mode to enter. Modality is a routing
question, and these systems answer it by never changing the route.

What does exist is soft exclusivity by deference to a _foreign_ overlay. When vim's own
popup menu becomes visible, both plugins get out of the way: nvim-cmp closes its custom view
on `CompleteChanged` while `pumvisible() == 1` (`custom_entries_view.lua:48-55`) and gates
`custom_entries_view.ready()` on `pumvisible() == 0` (`:116-118`); blink hides everything on
the same signal (`trigger/init.lua:156`, `:235`), and its changelog records the rule extended
to all its windows. blink's signature window goes further and reads the foreign menu's
geometry via `vim.fn.pum_getpos()`, pinning itself to the opposite side of the cursor
(`signature/window.lua:145-150`). A competing overlay is treated as an occupancy constraint
plus an exclusivity claim — never as a modality.

**Passthrough**: a float always eats the cells it covers. There is no click-through and no
partial transparency beyond `winblend`, a per-window blend percentage (0 by default in both)
that is purely cosmetic — it does not affect hit testing, because there is no hit testing.

The one thing resembling a mode is blink's `auto_wrap.disable()` / `restore()` around the
menu's lifetime (`menu/init.lua:125`, `:140`), which suppresses the `t`/`c` `formatoptions`
so text auto-wrapping cannot corrupt preview-undo while the menu is open: a global editor
setting saved and restored across an overlay's lifetime, entirely invisible on screen.

**Algorithm** — exclusivity by deference:

```text
on foreign_overlay_visible: hide_all_own_overlays()
gate any open on: not foreign_overlay_visible
when coexisting with a foreign overlay whose rect is queryable (pum_getpos):
    treat it as an occupied side and place on the opposite side of the cursor
```

No scrim, no input capture, no `z`-based blocking.

**Where it lives.** Library code plus the `CompleteChanged` autocmd and the
`pumvisible()` / `pum_getpos()` builtins. Neovim offers no modality for floats at all — a
float cannot capture input; you can only enter it as a window.

**Degradation.** Trivially portable, because "non-modal, no input routing to the overlay"
needs nothing from the platform. The interesting transfer is negative: without a native
pointer [grab][concepts], light-dismiss-on-click-outside cannot be implemented reliably —
and this subject is a complete, widely used overlay system that never needed it. Dismissal
here is driven by state transitions (dimension 8), not by outside clicks. On a recording
backend, non-modality means every frame is fully determined by state, with no capture to
model.

### 12. Adaptive presentation

There is no touch/compact/sheet adaptation — no touch target exists — but there _is_ a
real, load-bearing adaptation across three **input contexts**: buffer, command line and
terminal. The layer that owns each decision is unusually clear.

Command-line mode is a different coordinate universe and every layer participates:

- **Anchor** (owned by config, injected). `get_cursor_screen_position()` branches on mode
  `'c'` and derives all four edge distances from `config.cmdline_position()`, a
  user-supplied function (`lib/window/init.lua:283-298`). The default is
  `{lines - cmdheight, 0}` with a `vim.g.ui_cmdline_pos` override for external UIs.
- **Placement** (owned by the placer). The menu switches from `relative='cursor'` to
  `relative='editor'` and composes the origin manually
  (`completion/windows/menu/init.lua:245-251`). Note the `math.max(…, 0)` on `col` — the
  only left-edge clamp in blink's entire placement path, and it exists only on this branch.
- **Solver** (owned by the placer). `get_direction_with_window_constraints` substitutes
  `cursor_screen_row = vim.o.lines - 1` in command-line mode (`lib/window/init.lua:415`).
- **Paint** (owned by the window library). The command line does not redraw automatically,
  so every geometry mutation queues a coalesced redraw guarded by a `redraw_queued` flag
  (`lib/window/init.lua:484`), with a second copy of the same guard for the scrollbar floats
  (`lib/window/scrollbar/win.lua:99-110`). nvim-cmp does the same, less carefully
  (`utils/window.lua:201-205`).
- **Content** (owned by the feature). Ghost text is unsupported in command-line mode without
  an external UI plugin.

So the answer to "which layer owns the decision" is: the anchor layer owns the origin and
delegates it to configuration, the placer owns the coordinate space, and the backend owns
the flush policy. No single layer adapts; each has a branch, and the branch predicate
(`get_mode().mode == 'c'`) is re-tested independently in five files. That duplication is the
cost of not modelling the context as a value.

Terminal mode is a third context with its own event source (`lib/term_events.lua`) feeding
the identical trigger vocabulary. There are no teaching tips, no keyboard-driven relocation,
no reduced-motion switch (see dimension 14) and no density switch. Border style adapts to a
platform preference (`vim.o.winborder`), and that changes the geometry budget — an
appearance setting with placement consequences.

**Algorithm** — context-conditional anchoring:

```text
origin(mode)           = mode == 'c' ? config.cmdline_position()      # injected, overridable
                                     : screenpos(win, cursor_line, cursor_col)
space(mode)            = distances from origin to the four viewport edges
coordinate_space(mode) = mode == 'c' ? absolute('editor') : relative('cursor')
flush(mode)            = mode == 'c' ? coalesced_explicit_redraw : implicit
```

**Where it lives.** Library code, with the crucial hook delegated to user configuration so
external UI plugins can relocate the anchor.

**Degradation.** The injected-origin pattern is exactly right for a constrained target: a
soft-keyboard inset should be a value handed to the placer the way `cmdline_position()` is,
with the four edge distances recomputed from it — no probing, no discovery. The
coalesced-flush guard maps onto "one repaint per frame regardless of how many geometry
mutations occurred", which an immediate-mode GUI backend and a recording backend both want.
What does not port is the five-way duplicated mode test; carry the context as one value
through layout instead.

### 13. Accessibility

Nothing. Neither tree contains an accessibility affordance: no role, no label, no description
association, no live region, no announcement, no timing accommodation. Grepping both `lua/`
trees for role/aria/announce/accessib returns zero hits. The overlays are ordinary neovim
buffers in ordinary floating windows; a screen reader driving the terminal sees only the
composited cells.

This is less negligence than the absence of a channel: neovim exposes no accessibility tree,
so there is nothing for a library to populate. It does mean this subject cannot inform the
"native accessibility trees" half of the dimension at all — see [`./aria-apg.md`][apg] and
[`./react-aria.md`][react-aria] for that.

What _is_ honestly exposed, and what a terminal grid can genuinely offer, shows up in what
these projects publish:

- **Semantic surface identity via `filetype`.** Every overlay buffer gets a stable,
  documented filetype — `blink-cmp-menu` (`menu/init.lua:51`), `blink-cmp-documentation`
  (`documentation.lua:36`), `blink-cmp-signature`; `cmp_menu` and `cmp_docs`
  (`custom_entries_view.lua:40`, `docs_view.lua:20`). This is the ecosystem's actual role
  vocabulary: other plugins and user autocmds key off it to identify "this window is a
  completion menu".
- **Lifecycle events on a public bus.** `BlinkCmpMenuOpen` / `BlinkCmpMenuClose` /
  `BlinkCmpMenuPositionUpdate` are real autocmd events any other tool can observe — the
  closest thing to a notification channel available, and a good model: the primitive emits
  open/close/moved with the resolved geometry, and a semantic component decides what it
  means.
- **Semantic highlight groups rather than colours.** `BlinkCmpMenu`, `BlinkCmpMenuBorder`,
  `BlinkCmpMenuSelection`, `BlinkCmpDoc`, `BlinkCmpDocBorder`, `BlinkCmpDocSeparator`,
  `BlinkCmpSignatureHelpActiveParameter`, `BlinkCmpScrollBarThumb`/`Gutter` — the surface
  names its parts and the theme resolves them.

**Can tooltip content ever be interactive?** In this subject, no, and the separation is
enforced structurally: the docs panel has no selection, no cursorline and no keymaps of its
own, only remote scroll. The menu has a selection but no focus. The distinction between "a
surface you can act on" and "a surface you can only read" is carried by _which remote
operations exist_, not by a role bit.

**Where it lives.** Nowhere — a genuine platform-level absence, not a library omission.

**Degradation.** Already fully degraded. What a cell grid can honestly expose is a stable
kind name per surface, open/close/moved events carrying the resolved rect and side, and named
theme slots per part. What it cannot honestly expose is a role tree, a description
association or a hover-timing accommodation, and pretending otherwise would be worse than the
honest gap.

### 14. Animation

No animation of any kind, in either project, anywhere: no enter/exit transition, no fade, no
slide, no spring, no reposition tween, no reduced-motion switch. Windows appear and vanish in
one frame, and geometry changes are applied instantly via `nvim_win_set_config`.

_Why: on a cell grid the smallest positional step is one whole cell, so a transition would be
a visible jump sequence rather than motion, and an overlay that re-places on every keystroke
would still be animating in when the next keystroke re-placed it. That reading — that the
absence is deliberate rather than an oversight — is an inference; neither tree states it._

**Does the placement result carry the metadata a styling layer would need to animate?** Yes,
and that is the interesting part. blink's direction solver returns
`{ width, height, direction }` (`lib/window/init.lua:476-479`), and `direction` is precisely
the side datum a styling layer would use as a transform origin. blink also exposes the
resolved side to a second consumer at runtime: both the documentation window
(`documentation.lua:160`) and the signature window (`signature/window.lua:140`) read the
menu's resolved side back out by comparing coordinates, and branch their own placement on it.
nvim-cmp passes the same datum explicitly, as the `bottom_up` boolean argument
(`lua/cmp/view.lua:195-196`, consumed at `docs_view.lua:29` and `:100`).

So the resolved side _is_ data and _is_ consumed downstream — by the placer rather than by a
renderer. Both implementations needed the parent's resolved side as an input to something
else; one made it an explicit parameter and the other re-derives it, with the re-derivation
appearing inconsistent between two call sites (see the caveat in dimension 15).

**Algorithm** — n/a. The transferable artefact is the placement result shape:

```text
PlacementResult = { side: N|S|E|W, width: cells, height: cells }   (blink)
PlacementResult = { rect, bottom_up: bool }                        (nvim-cmp, pushed to the child)
```

**Where it lives.** Nowhere; neovim offers no float animation primitive, so nothing was
declined.

**Degradation.** Nothing to degrade. Worth recording as a constraint discovery: on a cell grid
with per-keystroke re-placement, animation is not merely unavailable — on the reading above it
is undesirable, and both implementations shipped without it. The practical consequence is that
the placement result should still expose side and alignment (cheap, and useful to children and
themes) even on a target that will never animate on them.

### 15. State architecture

Neither project uses a reducer or a formal state machine. Both are imperative controllers over
module-level singletons, with blink adding an event-emitter bus.

**blink**: `menu`, `docs` and `signature` are module-level tables created at require time, one
`blink.cmp.Window` each. Mutable fields include `menu.items`, `menu.context`,
`menu.selected_item_idx`, `menu.auto_show.{enabled, delay_ms, timer, timer_key}`,
`docs.shown_item`, `signature.context` and `win.{id, buf, redraw_queued}`. Transitions are
method calls with side effects; there is no state enum and no illegal-state check.
`menu.force_auto_show()` mutates the _policy functions themselves_ and `reset_auto_show()`
rebuilds them from config — behaviour stored as swappable closures in mutable fields.

**nvim-cmp**: `cmp.view` owns three view objects; each holds `entries`, `offset`, `active`,
`column_width`, `bottom_up`, `prefix`. Placement state is stored as the window's `style` table
and read back through `info()` (`utils/window.lua:232`) — the anchor rect is derived from
stored style rather than from the platform, which is why `info()` works even when the window is
closed.

**Would this survive a non-DOM, value-semantics, `@nogc`-leaning toolkit?** The placement half
yes, the lifecycle half no.

Survives cleanly (pure functions of plain data, integer arithmetic over ≤10 values): the
direction solver; the position table; border budgeting; scrollbar thumb geometry; the
alignment-column computation; `clamped_to_menu()`; the ±1 cursor-row reservation. A fixed-size
`Placement` struct covers the whole return surface, and the priority list is at most four enum
values in a static array.

Does not survive: module-level singletons holding live handles; policy stored as swappable
closures (these want to be a timing-policy **value** selected by trigger kind); timer
cancellation by "stop the timer" (blink's documented race — a generation counter compared
inside the callback fixes it, is allocation-free, and needs no cancellation API); child→parent
`require` for geometry (invert to parent-pushes-rect, which nvim-cmp already does); and reading
`vim.uv.now()` inline instead of taking `now` as a parameter.

Both projects are **uncontrolled** — the overlay owns its own open/closed state and there is no
way for a caller to drive it declaratively; blink's `is_menu_visible()` /
`is_documentation_visible()` are read-only probes. For a `view() → layout()` toolkit the natural
inversion is that the application owns the request, `layout()` runs the solver, and "could not
place" comes back as a value the application can observe — which turns blink's
`if not pos then close() end` from a side effect into a pure result.

**Algorithm** — the state shape that survives, distilled from both:

```d
struct AnchoredOverlayState
{
    bool  open;
    Rect  anchor;          // 4 ints; the only link to the trigger
    Side  resolvedSide;    // output of the last solve; input to children
    uint  generation;      // epoch for timer cancellation (fixes blink's documented race)
    Instant triggeredAt;   // for the budget-from-trigger delay rule
    ItemId shownContent;   // blink's docs.shown_item: skip re-render when unchanged
}
// solve(viewport, anchor, border, desiredMin, priority, contentSize) -> Option!Placement  (pure)
// place(parentPlacement, childSize, gapRule) -> Point                                     (pure)
```

> [!WARNING]
> "Is the parent above the cursor" is derived two different ways in blink.
> `documentation.lua:160` compares the menu's raw window-relative row against `winline()`;
> `lib/window/init.lua:415-416` compares a screen-converted anchor row against `winline()`,
> which is window-relative. _Reading those two expressions, they would disagree in a split
> that is not at the top of the screen, and the docs solver would then pick the wrong vertical
> constraints. This is an inference: no such scenario was constructed or run, and some other
> invariant may make the two agree in practice._

**Where it lives.** Library code entirely; `vim.schedule` and `uv_timer_t` are the only
external state machines involved.

**Degradation.** The pure half survives every target including a recording backend — which is
the whole point of extracting it. The impure half is where both projects' known defects live
(the documented timer race, the two side derivations, the inline clock). A value-semantics
rewrite is not a compromise here; it removes the defects.

### 16. Shared infrastructure

blink factors a real shared primitive and nvim-cmp factors a smaller one; comparing what each
chose to share is this subject's clearest answer to "what truly belongs in one anchored-overlay
type".

blink's `blink.cmp.Window` (`lib/window/init.lua`, ~500 lines) is used by three surfaces and
provides: construction from a `WindowOptions` value; open/close; content measurement
(`get_content_width`, `get_content_height`); size fitting (`update_size`); **border
accounting** (`get_border_size`, `expand_border_chars`, and outer-inclusive
`get_height`/`get_width`); the anchor-space query (`get_cursor_screen_position`); the two
direction solvers; a scrollbar; the cursorline priority workaround; and the command-line redraw
coalescer. Everything above that seam is 200–280 lines per surface and is almost entirely
policy: which priority list, which anchor, which delays, which siblings to avoid.

nvim-cmp's `cmp.Window` (`utils/window.lua`, 333 lines) shares options, open/close/update,
border info, content height, a scrollbar and `info()` — but **no placement logic**.
`custom_entries_view.open` and `docs_view.open` each compute geometry from scratch with
duplicated border arithmetic, and that duplication is why the two surfaces ship inconsistent
policies.

**What belongs in one primitive, on this evidence:**

1. The anchor rect and its conversion to available-space-per-side. Both projects need it for
   every surface, and nvim-cmp shows it can be a plain value shared across unrelated producers.
2. The direction solver: priority list + desired minimum + stable sort + clamp + a "none"
   result. Three blink surfaces use it unchanged with different priority lists.
3. **Border budgeting.** Not obvious, and the most duplicated concept in both trees: the
   cyclic eight-character border expansion (blink's `expand_border_chars` at
   `lib/window/init.lua:237` is a literal port — the comment says "based on nvim-cmp"), the
   inner/outer conversion, and the rule that a visible scrollbar forces the right border to at
   least one cell (`:231`). Borders are a placement input, not a paint detail.
4. Content measurement → desired size, wrap-aware.
5. Scrollbar geometry (thumb height and offset from content height, inner height, topline).
6. The lifecycle event bus carrying open/close/position-changed **with the resolved geometry**.

**What merely looks common and must stay apart:** timing (the menu's budget-from-trigger, 0 ms
policy and the docs panel's 500/50 ms policy share no code and should not); the priority list
itself (menu = vertical only; docs = four-way and parent-side-dependent; signature = one forced
direction); sibling avoidance (product knowledge — but the primitive should _accept_ an
occupied-sides set so it has somewhere to go); content rendering (blink correctly splits
`lib/window/docs.lua`, shared by the docs and signature surfaces, from `lib/window/init.lua`);
the `draw` hook's argument (blink hands out the live window — the one seam drawn in the wrong
place); and selection, which only the menu has and which is not overlay infrastructure.

**Algorithm** — the seam that works, as blink draws it:

```text
SHARED (one type):  options -> { measure content, fit size, budget border, query anchor space,
                                 solve direction from a priority list, clamp, scrollbar, emit events }
PER-SURFACE:        { which anchor, which priority list, which desired minimum, which delays,
                      which siblings to exclude, what to render }

Three call sites of ONE solver:
    menu:      get_vertical_direction_and_height({'s','n'}, max_height = 10)
    signature: get_vertical_direction_and_height(opposite_of(menu_side or pum_side), max_height)
    docs:      get_direction_with_window_constraints(menu_win,
                   (menu_up ? {e,w,n,s} : {e,w,s,n}) minus signature_side,
                   { width: 50, height: 10 })
```

**Where it lives.** Library code. `blink.lib` (timer, list utilities, an nvim API wrapper) sits
beneath it, and that API wrapper makes every geometry call interceptable — the closest either
project comes to testability.

**Degradation.** The whole factoring ports. The shared half is pure integer geometry; the
per-surface half is policy data (a priority array, two integers, a delay pair) that can be a
compile-time-known value. The one adjustment a single-surface toolkit must make is to add
**occupied sides / already-claimed rects** as a solver input, because with no top layer sibling
disjointness must be guaranteed by placement rather than by `z` (dimension 10).

---

## Strengths

- The direction solver is genuinely reusable and _is_ reused: one function, three surfaces,
  differing only in the priority list, the desired minimum and the anchor. A clear
  demonstration that anchored-overlay placement is one primitive plus per-surface policy data.
- Desired-minimum size as a first-class tier in the comparator. "Which side has the most room"
  is the wrong question; "which sides are adequate, and among those which did the author
  prefer" is the right one, and blink encodes exactly that in three comparator branches.
- A working, shipped second-order anchor — including cross-axis alignment that flips based on
  the _parent's_ resolved side, and a one-cell gap reserved for the anchor row when the child
  must cross the parent — in roughly 25 lines.
- Anchor-as-plain-value proven across unrelated producers: nvim-cmp's `docs_view` consumes the
  same `{row, col, width, height}` rect whether it came from nvim-cmp's own float or from vim's
  built-in C popup menu via `pum_getpos()`.
- Failure to place is modelled as a value (`nil` / close), not as clipping. Combined with
  re-placement on cursor/scroll/resize, "anchor off-screen", "viewport too small" and "content
  too big" all fall out of one code path.
- Border budgeting treated as placement input, not paint detail: an outer/inner distinction
  throughout, a cyclic eight-character border expansion, and the rule that a visible scrollbar
  forces the right border to at least one cell so the width budget stays honest.
- The show delay is charged against the trigger timestamp, so async content latency spends the
  user's patience budget instead of adding to it.
- A two-delay warm-up machine (500 ms initial, 50 ms while already open) with the short delay
  enforced by a config validator rather than by documentation.
- Sibling avoidance as candidate-set subtraction over four enum values — cheaper and more
  predictable than rectangle intersection, and the approach that still works when there is no
  `z`-order to fall back on.
- A deliberate stable sort (`vim.fn.sort`, not `table.sort`) so a comparator returning 0 means
  "keep the author's preference".
- The anchor origin injected as a function (`cmdline_position`) so an external UI can relocate
  it — the shape a soft-keyboard inset wants.
- Text-range alignment computed from the raw text model rather than the painted surface,
  explicitly so that inline decorations (ghost text) cannot shift the overlay.
- Coalesced explicit redraw with a queued flag for the context where the platform does not
  repaint on its own: one flush per scheduler tick regardless of how many geometry mutations
  occurred.

## Weaknesses

- **Zero tests for any of this geometry.** blink.cmp's tree contains no test or spec file at
  all; nvim-cmp's specs cover `utils` modules (api, async, binary, feedkeys, keymap, misc, str)
  and none of the view layer. Every defect below is a pure function of integers.
- Three border double-counts in blink's constraint table (`lib/window/init.lua:421-441`), as
  read: `s` adds the anchor's vertical border twice, `e` subtracts the anchor's right border
  twice, and `w` adds the anchor's left border to space that already excludes it — permitting a
  one-cell overlap.
- `max_height` silently means "including border": a bordered menu configured to 10 shows eight
  rows, on the reading of `update_size` → `get_height` → solver given in dimension 3.
- The tier-3 comparator key is `min(max_height, vertical, horizontal)` — a height cap applied
  to a term containing a width. The two axes collapse into one scalar for the "nothing fits"
  fallback.
- Two inconsistent derivations of "is the parent above the cursor" (dimension 15) — an
  inference from reading, not a runtime observation.
- A documented, unfixed timer-cancellation race, in a `TODO` block written by the author.
  Fixable with a generation counter; not fixed.
- A contradiction left in the file: the 0 ms synchronous open path was deleted in `5beb962` and
  restored in `11a8888`, leaving the "we should use timer, even for 0ms" comment sitting
  directly above the code that does exactly that.
- blink never clamps the menu horizontally in buffer mode. There is a literal
  `-- TODO: never go above the screen width and height` in the window library, and the only
  left-edge clamp lives on the command-line branch. A long keyword near the right edge pushes
  the menu off-screen.
- nvim-cmp's `'auto'` vertical mode places the menu above when the cursor is in the top half —
  the inverse of a free-space heuristic. The introducing commit explains it targets
  `scrolloff=999`; nothing in the tree documents that for users.
- nvim-cmp duplicates all border arithmetic between `custom_entries_view` and `docs_view`
  because there is no shared placer, and the two surfaces consequently have inconsistent
  policies (menu shrinks / docs closes; menu reserves an edge cell / docs does not; menu
  `z=1001` / docs `z=50`).
- Measurement requires realisation: nvim-cmp must open the docs window, ask whether it became
  scrollable, and re-open it one cell left. Two window creations for one placement.
- blink's per-keystroke placement path re-measures content by iterating every buffer line with
  `strwidth`, and nvim-cmp re-wraps every line when `wrap` is on; a
  `--- TODO: fix nvim_win_text_height` is left in place. Read from the loops, not profiled.
- The public `draw` hook hands user configuration the live `Window` object, exporting
  `set_height` / `set_width` / `set_win_config` and the whole geometry surface as public API.
- Ownership is expressed as a module graph, with `documentation` requiring `signature` lazily
  to dodge a cycle. There is no overlay-tree object and no ordering guarantee among emitter
  subscribers.
- Time is read inline (`vim.uv.now()`) rather than passed in — the single change that would
  make the whole timing dimension assertable.
- No accessibility of any kind in either tree. Partly a platform absence, but nothing is offered
  even at the level of a documented semantic contract.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                            | Rationale                                                                                                                                                                                                                                                                                       | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| blink anchors the documentation window to the **menu window** (`relative='win'`) — a true second-order anchor — while nvim-cmp places both absolutely and merely passes the parent's rect down as a value.          | blink gets automatic re-anchoring free: neovim re-lays-out `relative='win'` children when the parent moves, so the docs panel follows the menu with no explicit coupling, and the child's arithmetic is small offsets from the parent's own frame.                                              | The child must then reverse-engineer the parent's **outer** frame from a config that addresses the parent's **text** area, which is where blink's border double-counts and its two side derivations live. nvim-cmp's absolute placement has none of those (one coordinate system) but must re-place the child explicitly on every parent move and duplicates the border arithmetic per view. For a toolkit that rebuilds the display list per frame, nvim-cmp's model wins. |
| **Failure to place is a dismissal, never a clip.** Every blink solver returns `nil` and the caller closes; nvim-cmp's docs view closes when neither side fits and its window layer refuses to open below 1×1.       | On a cell grid a clipped overlay is unreadable and an overlapping one destroys the text being edited. Refusing to show is better than showing something wrong, and it makes "anchor scrolled off screen", "viewport shrank" and "content too large" collapse into the ordinary placement path.  | An overlay can vanish under conditions the user does not understand — blink's docs panel disappears when the menu is tall and the terminal is narrow, with no indication why. A toolkit should surface **why** placement failed as part of the result value, so a caller can degrade deliberately (shrink, inline, badge) instead of silently losing the surface.                                                                                                           |
| blink gives every surface the same `zindex` (1001) and guarantees non-overlap geometrically; nvim-cmp grades `zindex` (menu 1001, docs 50) and lets overlaps resolve by layer.                                      | blink's placer already knows which sides are taken (it removes the signature's side from the docs' candidate list), so `z` never has to arbitrate; constant `z` also keeps the whole plugin at one level relative to other plugins' floats.                                                     | blink's approach requires sibling occupancy to be an explicit solver input, and blink implements that with a hard cross-module `require`. nvim-cmp's is looser but produces a surprising default (docs eighteen layers below the menu, unexplained in-tree). For a single-surface toolkit blink's discipline is the one that works, and "already-claimed sides" must be a first-class solver parameter rather than a module dependency.                                     |
| **The overlay is never focused.** Selection inside the menu is remote cursor state driven by keymaps bound in the editing buffer; the documentation panel is scrolled remotely and has no input of its own.         | Text editing must continue while the overlay is up, so taking focus is impossible. Making selection remote also means the menu needs no keymap layer, no focus trap, no restoration and no tab order — the entire focus dimension evaporates.                                                   | Everything the overlay can do must be enumerated as a remote command, which is a larger public API than "focus it and let it handle keys", and the overlay can never host arbitrary interactive content. For targets with no keyboard focus (Android) or no keyboard key-release edge, that is the right trade, and both implementations made it independently.                                                                                                             |
| Preference ordering is expressed as a **stable sort** whose comparator returns 0 for "both acceptable", rather than as a first-fit scan over the priority list.                                                     | It composes two rules in one pass: honour the author's order among all candidates meeting the desired minimum, and fall back to most-space among those that do not. A first-fit scan cannot express the fallback without a second pass.                                                         | It is silently wrong with an unstable sort — a real hazard, since blink uses `table.sort` elsewhere and `vim.fn.sort` only here, with no comment saying why. An insertion sort over a four-element static array is stable by construction and allocation-free; the comparator is the part worth copying, not the sort call.                                                                                                                                                 |
| Neither project tests any placement geometry.                                                                                                                                                                       | The geometry is entangled with a live editor: it reads `vim.o.lines`/`columns`, `screenpos()`, `winline()`, `getcurpos()`, `nvim_win_get_config()` and `vim.uv.now()` inline, and it writes by opening real windows. Testing it would require a headless harness or an inversion of every read. | The cost is visible in the code: three border double-counts, a `max_height` that silently includes the border, an `'auto'` mode that prefers the side with less space, a documented-but-unfixed race, and two derivations of one predicate. Make `solve()` take `(viewport, anchorRect, borders, desiredMin, priority, contentSize, now)` and return a value, and the whole dimension becomes table-driven.                                                                 |
| blink's documentation delay policy has a config-validated floor (`update_delay_ms >= 50`, rejected with "lower causes lag"), and the show delay is measured from the trigger timestamp rather than content arrival. | Both encode a real cost model: re-rendering markdown on every arrow-key press is expensive, and a user who already waited 400 ms for an LSP should not wait another 500. Validating the timing policy rather than documenting it prevents a class of "my editor is laggy" reports.              | The floor is a magic number with no measurement in the tree, and the trigger-timestamp rule means a very slow source produces an instant, jarring popup rather than a settled one. Both are worth copying; the second should probably be clamped by a small minimum visible delay so the overlay never appears in the same frame as a burst of arriving content.                                                                                                            |

---

## Sources

Primary sources, all read at the revisions pinned in the metadata table above.

- blink.cmp — the shared window primitive: [`lua/blink/cmp/lib/window/init.lua`][b-win]
  (`update_size` `:166`, border budgeting `:199-233`, `expand_border_chars` `:237`,
  `get_content_width` `:263`, `get_cursor_screen_position` `:283`,
  [`get_vertical_direction_and_height` `:355`][b-win-vert],
  [`get_direction_with_window_constraints` `:378`][b-win-solver],
  [`direction_constraints` `:421`][b-win-constraints],
  [the three-tier comparator `:445`][b-win-cmp], [`redraw_if_needed` `:484`][b-win-redraw]).
- blink.cmp — the menu surface:
  [`lua/blink/cmp/completion/windows/menu/init.lua`][b-menu] (emitters `:65`, autocmds `:70`,
  [`set_selected_item_idx` `:144`][b-menu-select],
  [`queue_auto_show` `:159`][b-menu-autoshow], [`update_position` `:225`][b-menu-position]).
- blink.cmp — the documentation surface:
  [`lua/blink/cmp/completion/windows/documentation.lua`][b-docs]
  ([`auto_show_item` `:45`][b-docs-delay], [signature-side removal `:165`][b-docs-sig],
  [`clamped_to_menu` and the positions table `:192-218`][b-docs-positions]).
- blink.cmp — configuration as policy data:
  [`lua/blink/cmp/config/completion/menu.lua`][b-cfg-menu] (`max_height` `:21`,
  `scrolloff` `:29`, `direction_priority` `:34`, `cmdline_position` `:40`,
  `cursorline_priority` `:61`) and
  [`lua/blink/cmp/config/completion/documentation.lua`][b-cfg-docs]
  (`auto_show_delay_ms` `:38`, the `update_delay_ms` validator `:39-45`,
  `desired_min_width`/`desired_min_height` `:56-57`, the parent-side-keyed priority pair
  `:63-66`).
- blink.cmp — supporting mechanics: [`lib/window/cursor_line.lua`][b-cursorline] (the
  `CursorLine` priority explanation), [`lib/window/scrollbar/win.lua`][b-sbar-win]
  (`focusable = false` `:84`, the second redraw guard `:99-110`),
  [`lib/window/scrollbar/geometry.lua`][b-sbar-geom] (thumb geometry, `z+1`/`z+2`),
  [`completion/trigger/init.lua`][b-trigger] (hide authority `:140-175`, `pumvisible` `:156`
  and `:235`), [`completion/windows/render/init.lua`][b-render]
  (`get_alignment_start_col` `:158`), [`signature/window.lua`][b-sig] (`pum_getpos`
  occupancy `:145-150`).
- nvim-cmp — the menu view:
  [`lua/cmp/view/custom_entries_view.lua`][c-entries] (`DEFAULT_HEIGHT = 10` `:11`,
  `CompleteChanged` close `:48`, [keyword alignment `:184-189`][c-entries-align],
  [`should_position_above` and the horizontal pass `:195-217`][c-entries-place],
  `zindex` `:241`, the nil-handle bail `:246`, `info()` `:328`).
- nvim-cmp — the documentation view: [`lua/cmp/view/docs_view.lua`][c-docs]
  (`docs_view.open(self, e, view, bottom_up)` `:29`, [close-as-fallback `:96`][c-docs-close],
  bottom-up row `:100`, `zindex or 50` `:113`,
  [the two-pass scrollbar correction `:117`][c-docs-sbar]).
- nvim-cmp — the shared window utilities: [`lua/cmp/utils/window.lua`][c-window]
  (bottom-edge clamp `:85`, `math.ceil` on fractional GUI bounds `:93`, the sub-1×1 refusal
  `:116`, `nvim_open_win(buf, false, s)` `:125`, `info()` `:232`, `get_border_info` `:260`,
  wrap-aware `get_content_height` `:316`), plus [`lua/cmp/view.lua`][c-view]
  (`view.close` `:152`, `open_docs` `:187`, `bottom_up` pushed to the child `:195`,
  `async.throttle(…, 20)` `:284`), [`lua/cmp/init.lua`][c-init] (`scroll_docs` `:203`,
  `open_docs` `:218`) and [`lua/cmp/view/native_entries_view.lua`][c-native]
  (`pum_getpos` `:101`).
- Neovim, read to corroborate platform behaviour: [`src/nvim/winfloat.c`][n-winfloat]
  (the `relative='cursor'` one-time rewrite `:204-209`, `float_zindex_cmp` `:289`,
  `win_check_anchored_floats` `:323`) and [`runtime/doc/vimfn.txt`][n-vimfn] (`sort()` is
  documented stable, `:10686`).

Related pages in this catalog: [`./index.md`][index] for the umbrella,
[`./concepts.md`][concepts] for the shared vocabulary, [`./comparison.md`][comparison] for the
capstone, [`./features-people-forget.md`][forget] for the obscure-capability register,
[`./sparkles-baseline.md`][baseline] and [`./proposal.md`][proposal] for what this evidence is
for. Same-substrate siblings: [`./neovim-floats.md`][nvim-floats], [`./nui.md`][nui],
[`./helix.md`][helix], [`./textual.md`][textual], [`./ratatui.md`][ratatui],
[`./notcurses.md`][notcurses], [`./tmux-popup.md`][tmux], [`./turbo-vision.md`][tvision],
[`./emacs-posframe.md`][posframe]. Adjacent research trees:
[window-system integration][wsi], [platform UI guidelines][pug], [UI layout][ui-layout].
Toolkit specs this feeds: [`../../specs/ui/index.md`][spec-ui],
[`../../specs/ui/input.md`][spec-input], [`../../specs/ui/containers.md`][spec-containers],
[`../../specs/ui/state-machines.md`][spec-stm], [`../../specs/ui/backends.md`][spec-backends],
[`../../specs/ui/widgets.md`][spec-widgets].

<!-- References -->

[repo-blink]: https://github.com/Saghen/blink.cmp
[repo-cmp]: https://github.com/hrsh7th/nvim-cmp
[repo-nvim]: https://github.com/neovim/neovim
[pin-blink]: https://github.com/Saghen/blink.cmp/tree/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526
[pin-cmp]: https://github.com/hrsh7th/nvim-cmp/tree/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3
[pin-nvim]: https://github.com/neovim/neovim/tree/2757f6eef92a99812d5ad12408d03592bd54f10c
[b-win]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L62
[b-win-vert]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L355
[b-win-solver]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L378
[b-win-constraints]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L421
[b-win-cmp]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L445
[b-win-redraw]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/init.lua#L484
[b-menu]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L65
[b-menu-select]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L144
[b-menu-autoshow]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L159
[b-menu-position]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/menu/init.lua#L225
[b-docs]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/documentation.lua#L36
[b-docs-delay]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/documentation.lua#L45
[b-docs-sig]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/documentation.lua#L165
[b-docs-positions]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/documentation.lua#L192
[b-cfg-menu]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/config/completion/menu.lua#L21
[b-cfg-docs]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/config/completion/documentation.lua#L38
[b-cursorline]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/cursor_line.lua#L4
[b-sbar-win]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/scrollbar/win.lua#L84
[b-sbar-geom]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/lib/window/scrollbar/geometry.lua#L65
[b-trigger]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/trigger/init.lua#L154
[b-render]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/completion/windows/render/init.lua#L158
[b-sig]: https://github.com/Saghen/blink.cmp/blob/8ca29c2eb34f5ce4770bffc0d62e6f636a4e8526/lua/blink/cmp/signature/window.lua#L140
[c-entries]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/custom_entries_view.lua#L11
[c-entries-align]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/custom_entries_view.lua#L184
[c-entries-place]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/custom_entries_view.lua#L195
[c-docs]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/docs_view.lua#L29
[c-docs-close]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/docs_view.lua#L96
[c-docs-sbar]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/docs_view.lua#L117
[c-window]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/utils/window.lua#L85
[c-view]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view.lua#L152
[c-init]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/init.lua#L203
[c-native]: https://github.com/hrsh7th/nvim-cmp/blob/2ffe79f1f021def8dd1fcd81deb16f1bb0d989f3/lua/cmp/view/native_entries_view.lua#L99
[n-winfloat]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L204
[n-vimfn]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/vimfn.txt#L10686
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[nvim-floats]: ./neovim-floats.md
[nui]: ./nui.md
[helix]: ./helix.md
[textual]: ./textual.md
[ratatui]: ./ratatui.md
[notcurses]: ./notcurses.md
[tmux]: ./tmux-popup.md
[tvision]: ./turbo-vision.md
[posframe]: ./emacs-posframe.md
[apg]: ./aria-apg.md
[react-aria]: ./react-aria.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
