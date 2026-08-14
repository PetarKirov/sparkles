# Neovim floating windows (C core + Lua runtime)

Neovim ships an anchored-overlay primitive that resolves an anchor descriptor to one integer screen cell, clamps the result into the screen, and composites overlapping cell rectangles in `zindex` order — and deliberately stops there, leaving every placement, timing, dismissal and role decision to the caller.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                 |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | C (core) with Lua for runtime policy                                                                                                                                                                                                                                                                                                                                  |
| License           | Apache-2.0, with the Vim license for inherited parts                                                                                                                                                                                                                                                                                                                  |
| Repository        | [`neovim/neovim`][nvim-repo]                                                                                                                                                                                                                                                                                                                                          |
| Documentation     | In-tree help files read at the pinned revision: [`runtime/doc/api.txt`][doc-api], [`runtime/doc/api-ui-events.txt`][ev-floatpos], [`runtime/doc/windows.txt`][doc-windows], [`runtime/doc/options.txt`][doc-winpinned], [`runtime/doc/dev.txt`][doc-dev]                                                                                                              |
| Category          | Terminal / cell grid                                                                                                                                                                                                                                                                                                                                                  |
| Surface model     | Both. The builtin TUI path composites every float into one terminal cell grid ([`src/nvim/ui_compositor.c`][comp-line]); a `ui-multigrid` client instead receives each float as its own grid plus a `win_float_pos` event and may place it itself; and `external=true` promotes the grid to a top-level OS window owned by the client ([`window.c:980`][ui-external]) |
| **Revision read** | `2757f6eef92a99812d5ad12408d03592bd54f10c` — 0.13.0-dev (`CMakeLists.txt:150-153`)                                                                                                                                                                                                                                                                                    |

## Overview

### What it solves

A Neovim float is a full editor window — real buffer, real cursor, real window-local options — that is not a node in the split tree. Its geometry comes from a value-typed `WinConfig` record instead of from the frame layout, and its position on screen is the result of exactly three core operations: resolve the anchor descriptor to a cell, clamp into the screen, composite by `zindex`. Everything an anchored-overlay library normally owns above that line — deciding above versus below, sizing to content, delaying the open, dismissing on outside interaction, distinguishing a tooltip from a menu — is not in the primitive at all.

That makes the subject unusually informative for a toolkit under sparkles' constraints, because it is a widely exercised overlay system that never had an OS popup, a compositor, alpha, sub-cell precision, a pointer grab or a [top layer][concepts] available to it in the first place. Its answers are not degradations of a richer model; they are what the cell grid affords.

### Design philosophy

The mechanism/policy split is stated in code rather than in prose. The generic float's entire collision response is a two-axis clamp — a [shift][concepts], never a [flip][concepts] — and only the horizontal half of it is escapable:

```c
// src/nvim/window.c:947-953 — ui_ext_win_position()
int above_ch = wp->w_config.zindex < kZIndexMessages ? (int)p_ch : 0;
comp_row += grid->comp_row;
comp_col += grid->comp_col;
comp_row = MAX(MIN(comp_row, Rows - wp->w_height_outer - above_ch), 0);
if (!c.fixed || east) {
    comp_col = MAX(MIN(comp_col, Columns - wp->w_width_outer), 0);
}
```

The second commitment is that **requested** geometry and **placed** geometry are different fields, and the codebase says so as a bug-fix comment on the one path that violated it:

> ```c
> // Screen pos 'previewpopup' anchors to (original cursor pos). Separate from WinConfig because
> // win_float_update_preview() re-autosizes as content updates, and re-decides the flip
> // above/below. WinConfig.row/col hold the placed (offset, flipped, clamped) result.
> int w_wantline;
> int w_wantcol;
> ```
>
> — [`src/nvim/buffer_defs.h:1210-1214`][bd-want]

The third is that geometry is published as **data** with two mutually exclusive contracts on the same event. A `ui-multigrid` client may consume the abstract [anchor][concepts] and own collision itself, or consume the pre-resolved screen cell; both are emitted on every reposition:

> ```text
> - Manually - The window should be displayed above another grid
>   `anchor_grid` at the specified position `anchor_row` and
>   `anchor_col`. For the meaning of `anchor` and more details of
>   positioning, see |nvim_open_win()|. NOTE: you have to manually
>   ensure that the window fits the screen, possibly by further
>   reposition it. Ignore `screen_row` and `screen_col` in this case.
> - Let nvim take care of the positioning - You can ignore `anchor`
>   and display the window at `screen_row` and `screen_col`.
> ```
>
> — [`runtime/doc/api-ui-events.txt:641-648`][ev-two-contracts]

> [!NOTE]
> Placement policy proper lives outside the primitive. The canonical implementation is `vim.lsp.util.make_floating_popup_options` in [`runtime/lua/vim/lsp/util.lua:766`][lsp-mfpo] — the helper that LSP hover ([`handlers.lua:419`][h-hover]), signature help ([`handlers.lua:477`][h-sig]) and diagnostic floats ([`_float.lua:250`][diag-open]) all reach through `open_floating_preview`. Three further, mutually inconsistent above/below rules exist inside core, for the three built-in overlays that are not generic floats. See dimensions 2 and 16.

## How it works

**The descriptor.** `WinConfig` ([`src/nvim/buffer_defs.h:1004-1037`][bd-winconfig]) is a flat POD: a `FloatRelative relative`, a `Window window` handle, an `lpos_T bufpos`, `int height, width`, `double row, col`, a `FloatAnchor anchor` (a 2-bit mask, [`buffer_defs.h:956-959`][bd-anchor]), `zindex`, the eight border characters and their highlight ids, title/footer virt-text, and the booleans `external`, `focusable`, `mouse`, `fixed`, `hide`, `noautocmd`. It has a designated-initialiser default, `WIN_CONFIG_INIT`.

**Open and reconfigure.** `nvim_open_win(buf, enter, config)` ([`src/nvim/api/win_config.c:197`][wc-open]) parses the dict into a `WinConfig` and commits it. `nvim_win_set_config` copies the current value, lets `parse_win_config` overwrite only the keys actually present (every field guarded by `HAS_KEY_X`), and commits with `merge_win_config` ([`window.c:848`][w-merge]) — which is a struct assignment plus a manual free of the old title/footer text. On any validation error the parse restores the previous config before returning ([`win_config.c:1508`][wc-restore]), so a rejected reconfigure leaves no partial state.

**Placement.** `win_config_float` ([`winfloat.c:191`][wf-config]) rewrites `cursor`/`mouse` anchors into a frozen `relative=win` offset, derives per-side border thickness, and clamps the _size_. `ui_ext_win_position` ([`window.c:876`][w-uiext]) then resolves the anchor to a cell, applies the corner, clamps the _position_, writes `w_winrow`/`w_wincol`, and hands the rect to the compositor.

```text
nvim_open_win / nvim_win_set_config
  parse_win_config      validate keys over a COPY; restore on failure
  win_config_float      cursor/mouse -> frozen win-relative offset
                        border_adj[] from the edge chars; size clamp
  (mark w_pos_changed)
...next flush...
win_ui_flush            for each window with w_pos_changed:
  ui_ext_win_position   w_pos_changed = false        <- FIRST, so cycles terminate
                        resolve relative base (+ recurse into a dirty anchor win)
                        bufpos -> textpos2screenpos
                        corner -> top-left; clamp; write w_winrow/w_wincol
                        ui_comp_put_grid(...)   or   ui_comp_remove_grid(...) if hide
                        if multigrid: ui_call_win_float_pos(abstract + resolved)
```

**Composition.** `ui_comp_put_grid` ([`ui_compositor.c:140`][comp-put]) inserts or moves the grid in a flat `kvec` of `ScreenGrid *` sorted ascending by `zindex`, decomposes the damage of a move into four rectangles, and recomposes. `compose_line` ([`ui_compositor.c:359`][comp-line]) resolves each output row into runs by scanning the layer array; the blend loop ([`ui_compositor.c:436-458`][comp-blend]) passes each cell of a layer with `blending` set through `hl_blend_attrs` ([`highlight.c:751`][hl-blend]).

## The analysis spine

### 1. Anchor model

Applies. The [anchor][concepts] is a plain record, not an object graph. Six relative bases exist — `editor`, `win`, `cursor`, `mouse`, `tabline`, `laststatus` — but only three of them survive as live anchors.

**Algorithm** (`ui_ext_win_position`, [`window.c:891-953`][w-anchor]):

```text
resolve(cfg) -> cell:
    # at CONFIGURE time only (win_config_float), not per frame:
    if relative == cursor: cfg := {relative:win, win:curwin,
                                   row: cfg.row + curwin.w_wrow,
                                   col: cfg.col + curwin.w_wcol}
    if relative == mouse:  same, over mouse_find_win_inner(mouse_grid, row, col)

    # at FLUSH time:
    row, col := cfg.row, cfg.col                     # doubles
    if relative == win:
        if anchor window is dirty: resolve(anchor window) first   # recursion
        row += parent.grid.row_offset; col += parent.grid.col_offset
        if bufpos.lnum >= 0:
            lnum := min(bufpos.lnum + 1, parent.line_count)
            (trow, tcol) := textpos2screenpos(parent, {lnum, bufpos.col}, local = true)
            row += trow - 1; col += tcol - 1
    elif relative == laststatus: row += Rows - cmdheight - last_stl_height()
    elif relative == tabline:    row += tabline_height()

    comp_row := (int)row - (anchor & South ? height_outer : 0)
    comp_col := (int)col - (anchor & East  ? width_outer  : 0)
```

`cursor` and `mouse` are sugar that snapshots a point once: `win_config_float` rewrites them into `relative=win` plus a frozen offset ([`winfloat.c:204-221`][wf-snapshot]). `laststatus` and `tabline` stay live and are re-derived on every placement ([`window.c:921-925`][w-anchor]). `bufpos` is a text-position anchor resolved through `textpos2screenpos` ([`move.c:1078`][mv-t2s]) — the same routine the editor uses for its own geometry — and it is **additive**: `bufpos` supplies the base cell and `row`/`col` are an offset on top of it, defaulting to `(1, 0)` for north anchors and `(0, 0)` for south ([`win_config.c:1317-1322`][wc-bufpos]):

```c
// src/nvim/api/win_config.c:1317-1322 — parse_win_config()
if (!HAS_KEY_X(config, row)) {
    fconfig->row = (fconfig->anchor & kFloatAnchorSouth) ? 0 : 1;
}
if (!HAS_KEY_X(config, col)) {
    fconfig->col = 0;
}
```

The anchor _corner_ is a 2-bit mask (`kFloatAnchorEast = 1`, `kFloatAnchorSouth = 2`), giving NW/NE/SW/SE — no centre, no edge midpoints, no side-plus-alignment. Trigger and anchor are fully detached: `relative='win', win=X` anchors a float to a window it has no other relationship with, many floats may anchor to one window, and a float may anchor to another float (resolved by recursion, [`window.c:900-905`][w-anchor]). Anchoring to self is rejected ([`win_config.c:1370-1373`][wc-self]).

**Where the behavior lives.** Framework kernel, in C: descriptor parsing in `src/nvim/api/win_config.c`, snapshotting in `src/nvim/winfloat.c`, live resolution in `src/nvim/window.c`, text-position math in `src/nvim/move.c`.

**Degradation.** Everything here is integer-cell arithmetic over a plain value, so no OS window, no hover, no script and no sub-cell precision are required. `relative='mouse'` is the only member that needs a pointer at all, and even where a pointer exists it degrades to a one-shot snapshot. A `bufpos` anchor whose text has scrolled out of view does not vanish: `textpos2screenpos` with `local = true` returns row `0` above the topline and `w_view_height - 1` below the botline ([`move.c:1099-1103`][mv-clamp]), so the overlay pins to the viewport edge. `test/functional/ui/float_spec.lua:11411` ("bufpos out of range") places `bufpos = {3, 3}` in a one-line buffer and still expects a rendered float.

### 2. Placement model

Partial — and the partiality is the finding. The generic primitive has no preferred-placement list, no fallback ordering and no flip. Its whole collision response is the clamp quoted in the Overview, and `fixed` disables only the horizontal half. The documentation scopes `fixed` to NW/SW anchors ("If true when anchor is NW or SW, the float window would be kept fixed even if the window would be truncated", [`win_config.c:137-138`][wc-fixed-doc]), which the guard `if (!c.fixed || east)` honours; but the row clamp on the line above is unconditional, so `fixed` buys an overlay the right to hang off the right edge and never the right to hang off the bottom.

A [safe-area inset][concepts] exists and is selected by stacking band rather than discovered: an overlay below `kZIndexMessages` (200) is kept clear of the command line by `above_ch = cmdheight`; at or above 200 it may cover it ([`window.c:947`][w-clamp], [`winfloat.c:241`][wf-size-clamp]). The same inset is applied to the _size_ clamp, which runs earlier, in `win_config_float` — and only when the UI is not multigrid:

```c
// src/nvim/winfloat.c:240-244 — win_config_float()
if (!ui_has(kUIMultigrid)) {
    wp->w_config.height = MIN(wp->w_config.height, Rows - border_h - above_ch);
    wp->w_config.width  = MIN(wp->w_config.width,  Columns - border_w);
}
```

> [!WARNING]
> That conditional means an identical config produces a different rect on a multigrid GUI than in the builtin TUI. Backend-conditional geometry inside the model layer is the anti-pattern to avoid, not the pattern to copy.

Real auto-placement lives in four places with four different rules. The Lua one that LSP hover, signature help and diagnostics all reach:

```lua
-- runtime/lua/vim/lsp/util.lua:766-812 — make_floating_popup_options (abridged)
lines_above = winline() - 1
lines_below = winheight(0) - lines_above
if anchor_bias == 'below' then
    anchor_below = (lines_below > lines_above) or (height <= lines_below)
elseif anchor_bias == 'above' then
    anchor_below = not ((lines_above > lines_below) or (height <= lines_above))
else
    anchor_below = lines_below > lines_above          -- no fit test at all
end
if anchor_below then anchor = 'N'; height = clamp(height, 0, lines_below - border_h); row = 1
else                 anchor = 'S'; height = clamp(height, 0, lines_above - border_h); row = 0 end
if wincol + width + offset_x <= columns then anchor = anchor .. 'W'; col = 0
else                                          anchor = anchor .. 'E'; col = 1 end
```

The default `'auto'` bias at [`util.lua:795`][lsp-auto] is `anchor_below = lines_below > lines_above` — a majority vote on available space that never asks whether the popup _fits_, followed by a height clamp to the chosen side. So the shared LSP path prefers the roomier side and shrinks, rather than preferring the side that fits and flipping.

The C consumers disagree with it and with each other. `'previewpopup'` is a proper preferred-side-with-fallback ([`winfloat.c:568-570`][wf-preview-flip]):

```c
// src/nvim/winfloat.c:568-570 — win_float_update_preview()
// Prefer below/right; flip only if this side can't fit but the other can.
bool below = space_below >= need_h || space_above < need_h;
bool right = space_right >= need_w || space_left < need_w;
```

`pum_compute_vertical_placement` ([`popupmenu.c:124`][pum-vert]) goes above only when the menu does not fit below _and_ more than half the space is above, then reserves context lines, with its horizontal half in `pum_compute_horizontal_placement` ([`popupmenu.c:223-270`][pum-horiz], which also mirrors placement under `pum_rl`); `pum_adjust_info_position` ([`popupmenu.c:986`][pum-info]) picks right if it fits, else left if it fits, else the larger side, else hides the panel outright below ten cells.

**Where the behavior lives.** Mechanism in the kernel (`window.c`, `winfloat.c`); policy in runtime Lua (`runtime/lua/vim/lsp/util.lua`) and in three special-case C consumers. Nothing in a platform primitive.

**Degradation.** Nothing in this dimension needs an OS window, hover, script or sub-cell precision — it is the dimension that survives a terminal intact. `above_ch` is worth noting as a shape: a bottom viewport inset supplied as an _input_ to the clamp rather than queried by the solver, which is exactly the slot an Android soft-keyboard inset would occupy. See [`../window-system-integration/index.md`][wsi] for where such insets come from on each platform.

### 3. Collision & geometry engine

Partial. Overflow detection is trivial because there is exactly one [clipping boundary][concepts]: the screen. There is **no clipping-ancestor discovery**. A `relative=win` float is not clipped to its anchor window; it renders over sibling splits and is bounded only by `Rows`/`Columns`. `float_spec.lua:1485` ("window position fixed") pins this: a float in a right-hand 20-column split, at `col = 10` and width 15, renders only ten cells with `fixed = true` and shifts to screen column 25 with `fixed = false` — crossing nothing but the screen edge.

There are no transforms, no device pixel ratio and no fractional geometry in the builtin path. `row`/`col` are `double` in the API purely so a multigrid GUI with sub-cell capability can use them; the builtin path casts with `(int)` ([`window.c:945-946`][w-corner]).

> [!NOTE]
> The documentation states that the builtin implementation "will always round down to nearest integer" ([`win_config.c:67`][wc-round]), while the code is a C cast, which truncates toward zero. For a window-relative float at a negative fractional row the two disagree by one cell — an inference from C semantics, not an observed behavior: no test in `float_spec.lua` exercises a negative fractional row, so the divergence appears to be unexercised by the suite.

Tracking is dirty-flag driven, not polled and not per-frame. Any change to a window's topline, botline, leftcol or position calls `win_check_anchored_floats` ([`winfloat.c:323`][wf-check]), which sets `w_pos_changed` on every float whose `config.window` matches; `win_ui_flush` ([`window.c:7904`][w-flush]) then re-resolves only the dirty ones. Anchor-of-anchor chains resolve by recursion, and termination is guaranteed by `wp->w_pos_changed = false;` being the **first statement** of `ui_ext_win_position` ([`window.c:878`][w-uiext]) — so a two-cycle, which the API's self-anchor guard does not prevent, resolves in one bounded pass with stale-but-finite coordinates.

Composition and move damage:

```text
compose_line(row, startcol, endcol):
    col := startcol
    while col < endcol:
        grid := NULL; until := 0
        for g in layers (bottom..top):
            if row outside g's rows, or g.comp_disabled: continue
            if g.comp_col <= col < g.comp_col + width(g):  grid := g; until := right(g)   # overwrite
            elif g.comp_col > col:                          until := min(until, g.comp_col)  # clip run
        until := min(until, endcol)
        copy grid's [col, until) chars + attrs into linebuf
        wide-char fixups (both directions, see dimension 16)
        col := until

move-damage(grid, newrow, newcol, h, w):
    grid.comp_disabled := true            # so it cannot contribute to its own repaint
    compose_area(old.row, newrow, old.col, old.right)            # band above
    if old.col < newcol:      compose_area(clip rows, old.col, newcol)        # left strip
    if newcol + w < old.right: compose_area(clip rows, newcol + w, old.right) # right strip
    compose_area(newrow + h, old.bottom, old.col, old.right)     # band below
    grid.comp_disabled := false
```

Cost is O(layers) per run, with no spatial index ([`ui_compositor.c:384-405`][comp-scan]). Correctness rests on the bottom-to-top iteration order: a higher covering layer overwrites a lower layer's `until`, a higher non-covering layer clamps it — a subtlety no comment explains.

**Where the behavior lives.** Framework kernel: `src/nvim/ui_compositor.c` for composition and damage, `src/nvim/winfloat.c` plus the `src/nvim/move.c` call sites for invalidation, `src/nvim/window.c` for the flush.

**Degradation.** This dimension is already GL-free integer-cell work with no compositor, no top layer and no OS involvement. The one piece that does not generalise downward is the `double` row/col, which exists so a pixel backend can be _more_ precise than the model. The wide-character seam handling is the piece a naive cell toolkit gets wrong, and it is unavoidable at every overlay boundary — see dimension 16.

### 4. Arrow / caret geometry

Not applicable, and the absence is the finding: there is no arrow, beak, caret or tail anywhere in the system. `border_chars[8]` is strictly four corners plus four edges, clockwise from top-left, each validated to occupy at most one display cell ([`win_config.c:1131-1134`][wc-border-cell]), with an empty corner between two present edges rejected outright ([`win_config.c:1147-1153`][wc-corner-valid]). The anchor relationship is communicated by **adjacency alone** — the float sits one row below or above the anchor cell — and by nothing else. No field records which side placement chose, so no drawing layer could consume one.

The nearest machinery in the tree:

```text
border_adj[i] = has_border && border_chars[2*i + 1][0] != NUL      # i = top, right, bottom, left
height_outer  = view_height + border_adj[0] + border_adj[2] + winbar + float_stl
width_outer   = view_width  + border_adj[1] + border_adj[3]

bordertext_col(total, w, align) = align == left   ? 1
                                : align == center ? max((total - w) / 2 + 1, 1)
                                :                   max(total - w + 1, 1)
overflow = text_width - inner_cols
if overflow > 0: emit '<', then skip (overflow + 1) cells from the START of the chunk list
```

- Per-side thickness is **derived** from whether that side's _edge_ character is non-empty ([`winfloat.c:232-238`][wf-adj]), so "no left border" is expressed as an empty string in slot 7 and the content shifts by exactly one cell.
- The `shadow` pseudo-border is `{"", "", " ", " ", " ", " ", " ", ""}` with `FloatShadow`/`FloatShadowThrough` highlights on slots 2–6 ([`win_config.c:1086`][wc-shadow], [`highlight.c:407-421`][hl-shadow]) — a drop shadow implemented as right-and-bottom border cells whose blend lets the background glyph through.
- Content-derived sizing raises the width floor to the title's display width before the max-width clamp, and re-derives the height after treesitter concealment has run ([`util.lua:1381-1450`][lsp-size]).
- Title and footer are the only border decorations, positioned by `get_bordertext_col` ([`grid.c:1131`][grid-btcol]) and left-truncated with a `<` prefix when too long ([`grid.c:1093-1120`][grid-bttrunc]); `float_spec.lua:2343` expects `<stuvwxyz` for a 26-character title in a nine-cell window.

**Where the behavior lives.** Library code inside core: `src/nvim/grid.c` draws, `src/nvim/api/win_config.c` parses and validates ([`parse_border_style`][wc-borderstyle]), `src/nvim/highlight.c` resolves per-slot attributes.

**Degradation.** An arrow on a cell grid would be one glyph in one cell that must be an exact edge cell of the overlay rect, sharing the border run. Neovim declines to build one, which is itself the datapoint: it costs a whole border cell, must be suppressed when the anchor lies outside the overlay's edge span, and forces the placement layer to publish which side won. The transferable idea here is the chrome representation rather than the arrow: an 8-slot char-plus-highlight table in which an empty string means "no side", with per-side thickness falling out of it and the drop shadow arriving free as a blended two-side border.

### 5. Trigger semantics

Partial. For the generic float the only trigger is programmatic: code calls `nvim_open_win`. There is no hover, focus, click, long-press or context-menu trigger in core. Consequently there are no trigger races to arbitrate — creation is one synchronous call — and the multiple-trigger problem is pushed to the caller, where it is solved by **identity** rather than by arbitration:

```lua
-- runtime/lua/vim/lsp/util.lua:1540-1563 — open_floating_preview (abridged)
if opts.focus_id and opts.focusable ~= false and opts.focus then
    if vim.w[current_winnr][opts.focus_id] and is_float(current_winnr) then
        api.nvim_command('wincmd p')           -- re-activation bounces back out
        return
    end
    local win = find_window_by_var(opts.focus_id, bufnr)
    if win and is_float(win) and not pumvisible() then
        api.nvim_set_current_win(win); vim.cmd('stopinsert'); return
    end
end
local existing_float = vim.b[bufnr].lsp_floating_preview
if existing_float and is_float(existing_float) then close(existing_float) end   -- one per buffer
```

That is a singleton/re-entry rule expressed as a window-local variable plus a buffer-local variable, with no controller object ([`util.lua:1540-1563`][lsp-focusid]). `vim.diagnostic` reuses the same mechanism with `focus_id = scope` ([`_float.lua:245-246`][diag-focusid]), so a line-scoped and a cursor-scoped diagnostic float are _different_ singletons.

Pointer-type distinction exists only as the choice between `relative='mouse'` (a pointer-position snapshot) and `relative='cursor'`. Hover exists as an input event at the terminal layer — `'mousemoveevent'` ([`options.lua:6324`][opt-mousemove]) delivers `<MouseMove>` keys into the input queue — but core never consumes them for overlays. Assistive-technology triggers: none.

**Where the behavior lives.** Entirely in runtime Lua (`vim/lsp/util.lua`, `vim/diagnostic/_float.lua`). Core contributes only the storage (window- and buffer-local variables) and the `relative='mouse'` snapshot.

**Degradation.** With no hover on Android and no key release on the TUI, programmatic-only triggering is already the whole model, so nothing is lost. The transferable piece is the identity key: instead of a trigger-to-overlay registry with lifetimes, tag the surface with a caller-chosen id and make "open" idempotent against it. That works in a `@nogc` value-semantics toolkit (the id is a string or an enum) and it works on a script-free HTML target, where the id becomes the `id`/`for` pair of a `:checked` toggle.

### 6. Timing

Partial, and the applicable parts belong to other subsystems. The float primitive has zero timing: no open delay, no close delay, no maximum display duration, no [warm-up][concepts], no [cool-down][concepts], no groups, no shared provider. Two real timers exist elsewhere in the tree and are instructive.

`'updatetime'` plus `CursorHold` is the ecosystem's de-facto hover delay: `input_get` waits `p_ut - cursorhold_time` and posts a `CursorHold` when the wait expires without input ([`os/input.c:117-140`][in-get]). `cursorhold_time` accumulates across polls and is reset only when input actually arrives ([`os/input.c:68`][in-reset]).

The `'autocompletedelay'` option ([`options.lua:274`][opt-acl]) is a real warm-up, and its subtlety is stated in a comment:

```c
// src/nvim/os/input.c:133-140 — input_get()
// Measure the delay from when it was armed (the keystroke), so a
// CursorHold returning in between does not push the popup back.
int64_t wait_time = p_ut - cursorhold_time;
if (delay_pending) {
    int64_t delay_left = p_acl - ins_compl_autocomplete_elapsed();
    wait_time = MIN(MAX(delay_left, 0), wait_time);
}
```

`ins_compl_autocomplete_elapsed` ([`insexpand.c:6401-6404`][in-elapsed]) supplies the elapsed term, so two independent timers are multiplexed onto one blocking-poll deadline by `min()`, and the delay is measured from the **arm instant** rather than restarted per wake. Reconstructed as a machine, that is:

```text
state: Idle | Armed(t_arm) | Shown
Armed records the ABSOLUTE arm instant, never a countdown
each poll: deadline := min over armed timers of (t_arm + delay - now), floored at 0
           an unrelated wake (a redraw, another timer firing) must NOT re-arm
input arriving -> reset the hold accumulator; leave the arm instant alone
Shown -> Idle needs an explicit event; there is no max duration
```

Cool-down and instant-subsequent behavior are absent from the tree.

**Where the behavior lives.** Framework kernel, but in the input loop rather than in overlay code: `src/nvim/os/input.c`, driven by `'updatetime'` and `'autocompletedelay'`. No overlay code participates.

**Degradation.** A script-free HTML target has no timers at all, so any timing must be optional and the surface must be fully correct with every delay at zero. Neovim is accidentally a good model for that: because no delay is baked into the primitive, delay-free is the default and delays are added by the caller. The arm-instant rule also matters on a recording canvas — an assertion of the form "the surface appears at frame N" only holds if the delay is measured from a recorded instant and is not restarted by intervening repaints.

### 7. Interactive hover

Not applicable. There is no hover-intent machinery of any kind: no [safe polygon][concepts], no pointer bridge, no menu-aim, no trajectory heuristic, no interactive-border tolerance, no debounce. There is no travel problem to solve because there is no hover-open — a float is opened by code and stays open until code closes it, so the pointer may leave and return freely.

The one adjacent mechanism is the converse of a safe polygon: `mouse` (defaulting to whatever `focusable` was) makes a surface wholly transparent to hit testing, so the pointer falls through to whatever is behind it.

```c
// src/nvim/mouse.c:1844-1846 — mouse_find_grid_win()
win_T *wp = get_win_by_grid_handle(*gridp);
if (wp && wp->w_grid_alloc.chars
    && !(wp->w_floating && !wp->w_config.mouse)) {
```

Hit testing itself is a reverse-order scan of the layer array ([`ui_compositor.c:312`][comp-hit]):

```text
hit(row, col):
    for i := layers.size - 1 downto 1:                  # topmost first
        g := layers[i]
        if g.mouse_enabled and (row, col) inside g's rect: return g
    return default_grid
```

The tolerance band is exactly zero cells: a surface is hit or it is not, whole-surface, with no partial regions and no time component. Nested surfaces exist (a float anchored to a float) and are ordered by `zindex`, but nothing coordinates their hover.

**Where the behavior lives.** Framework kernel: `src/nvim/ui_compositor.c` and `src/nvim/mouse.c`, with the flag plumbed in `window.c:969` (`w_grid_alloc.mouse_enabled = w_config.mouse`).

**Degradation.** Android has no hover and the TUI has one pointer, so any hover-intent algorithm must either be absent or expressible in whole cells. Neovim's answer — do not build intent, build a per-surface click-through bit — is the one that survives every target unchanged, including static HTML, where it is `pointer-events: none`. What corridor geometry would cost on a cell grid is a question this subject does not answer; see [`./concepts.md`][concepts] and [`./comparison.md`][comparison] for the subjects that do.

### 8. Dismissal

Partial. There is no [grab][concepts] and nothing automatic. A float is a window; it closes when something closes a window. Core provides exactly two overlay-aware dismissal affordances.

```text
:[count]fclose[!]
    arr := [w for w in floats(tabpage) if not w.hide and not w.winpinned]
    qsort(arr, by zindex DESCENDING)              # float_zindex_cmp
    for w in arr:
        if not win_close(w): break
        if not bang and --count == 0: break
```

`:fclose` ([`ex_docmd.c:8146`][ex-fclose] → [`winfloat.c:296`][wf-remove], documented at [`windows.txt:416`][doc-windows]) is genuine topmost-first stack dismissal derived from `zindex` rather than from a parallel stack — and it is bound to no key. Escape does nothing by default. `'winpinned'` ([`options.txt:7787`][doc-winpinned], declared at [`options.lua:11134`][opt-winpinned]) exempts a window from `:only` and `:fclose`, an opt-out from bulk dismissal.

Everything else is caller-built from autocommands. The canonical set is assembled by `close_preview_autocmd` ([`util.lua:1351-1373`][lsp-close]) over a default `close_events` list ([`util.lua:1528`][lsp-events]):

```lua
-- runtime/lua/vim/lsp/util.lua:1351-1373, 1528 — close_preview_autocmd (abridged)
opts.close_events = opts.close_events or { 'CursorMoved', 'CursorMovedI', 'InsertCharPre' }
augroup('nvim.preview_window_' .. winid, { clear = true })   -- one group per float
autocmd('BufLeave', { buffer = ORIGIN_BUF, callback = function()
    vim.schedule(function()
        if vim.bo.filetype ~= 'qf' and current buffer not in {float_buf, origin_buf} then close() end
    end)
end })
autocmd(close_events, { buffer = ORIGIN_BUF, callback = close })
autocmd('WinClosed', { callback = clear b:lsp_floating_preview; return true })  -- self-deleting
```

What is _not_ there is as informative: no close on outside pointer-down, no close on window or application deactivation, no close on scroll (scrolling instead **moves** a `bufpos`-anchored float), no close on resize, no parent-closes-child cascade, and — notably — no close when the anchor window closes. In that case `find_window_by_handle` returns `NULL` and placement silently falls back to editor-relative coordinates ([`window.c:896-900`][w-anchor]). Closing the last non-float while floats remain is special-cased: core closes all floats first, or errors with `E5601` ([`window.c:2815`][w-lastwin]). Each LSP float also installs a buffer-local `q` mapping bound to `<cmd>bdelete<cr>` ([`util.lua:1606-1612`][lsp-qmap]).

**Where the behavior lives.** Core mechanism in `src/nvim/winfloat.c` and `src/nvim/ex_docmd.c`; policy in `runtime/lua/vim/lsp/util.lua`.

**Degradation.** With no grab, dismissal has to be a set of **named events the host already delivers**, which is what nvim builds. Every one of its close events — cursor moved, buffer left, explicit command — exists on a recording canvas and is assertable there. Deriving the dismissal order from `zindex` rather than from a separate stack is the piece worth copying: an Android back key and a TUI Escape can both route to "close the topmost overlay" with no extra state. The buffer-local `q` mapping is the honest terminal answer to Escape: bind dismissal _inside_ the surface, because a global key is unreliable while another surface holds focus.

### 9. Focus

Applies, and the split is the most transferable thing in this dimension: focus is **two independent booleans**. `focusable` (default true) controls keyboard/command focus and window enumeration; `mouse` controls hit testing. Setting `focusable` also assigns `mouse`, and a later `mouse` key overrides ([`win_config.c:1391-1398`][wc-focusmouse]):

```c
// src/nvim/api/win_config.c:1391-1398 — parse_win_config()
if (HAS_KEY_X(config, focusable)) {
    fconfig->focusable = config->focusable;
    fconfig->mouse = config->focusable;
}
if (HAS_KEY_X(config, mouse)) {
    fconfig->mouse = config->mouse;
}
```

All four combinations are reachable and all four are tested (`float_spec.lua:6612-6726`): `focusable=true` focuses on click; `focusable=false, mouse=true` **still** focuses on click, as the API docs state ([`win_config.c:139-141`][wc-focus-doc]); `focusable=false` alone does not; `focusable=true, mouse=false` does not, and the click falls through to the window behind.

Non-focusable and hidden floats are skipped by `CTRL-W w`/`W` traversal in both directions ([`window.c:403-435`][w-traverse]), by `CTRL-W p`, by `:windo` ([`ex_cmds2.c:598`][ex-windo]), by `winnr()` numbering, and as a `:help` target. They are not unreachable, though: `nvim_set_current_win` enters them regardless. So `focusable` is a **traversal property, not access control**.

```text
traversal (CTRL-W w):
    wp := curwin.next
    while wp and wp.floating and (wp.hide or not wp.focusable): wp := wp.next
    if wp == NULL: wp := firstwin              # wraps WITHOUT re-applying the skip predicate
    win_goto(wp)

alt-window on close/move (win_float_find_altwin):
    if float: wp := prevwin if (valid and != win and focusable and not hidden) else firstwin
    else:     wp := winframe_find_altwin(win, &dir)

mouse focus:
    grid := topmost layer with mouse_enabled covering (row, col)   # focusable is NOT consulted
```

There is no [focus scope][concepts], no trap and no containment. Restoration is only the alt-window heuristic `win_float_find_altwin` ([`winfloat.c:401-413`][wf-altwin]). Tooltip, popover, menu and dialog are not distinguished: there is one float kind plus two internal marker kinds (`kWinPreview`, `kWinInfo`) used only to find the singleton. `enter` is a parameter of `nvim_open_win`, so any pointer-versus-keyboard difference is the caller's job; LSP floats always open with `enter = false` and are focused only on a second invocation of the same command, via the `focus_id` bounce of dimension 5.

**Where the behavior lives.** Framework kernel: `src/nvim/window.c` (traversal), `src/nvim/winfloat.c` (alt-window), `src/nvim/mouse.c` (hit testing). The `focusable`/`mouse` coupling is decided at parse time in `src/nvim/api/win_config.c`.

**Degradation.** The two-boolean model needs no OS window, no hover and no key release, and it maps directly onto a reverse-paint-order hit list: `mouse` is "emit a hit entry for this surface at all", `focusable` is "participate in the tab ring". Merging them is the mistake — a tooltip wants neither, a click-through HUD wants focusable-but-not-hittable, and a decorative overlay above a live pane wants hittable-but-not-focusable. The wrap-to-`firstwin` step is a warning worth carrying: a ring that wraps to index 0 without re-applying the skip predicate can land on a skipped element.

### 10. Layering & portals

Applies. The layer model is a single flat `kvec_t(ScreenGrid *) layers`, index 0 pinned to `default_grid`, kept sorted ascending by `zindex`; `comp_index` is the resolved position and **is** the paint order. The public knob is `zindex` (positive int, default 50) plus four documented bands:

```c
// src/nvim/grid_defs.h:10-16
kZIndexDefaultGrid     = 0,
kZIndexFloatDefault    = 50,
kZIndexPopupMenu       = 100,
kZIndexMessages        = 200,
kZIndexCmdlinePopupMenu = 250,
```

`comp_index` is an implementation detail that is nevertheless **published** to external UIs alongside `zindex`, so a GUI can reproduce nvim's exact stacking rather than guessing from `zindex` ([`api-ui-events.txt:652-661`][ev-compindex]). The insertion tie-break ([`ui_compositor.c:181-190`][comp-tiebreak]) is the subtle part:

```c
// src/nvim/ui_compositor.c:181-190 — ui_comp_put_grid()
size_t insert_at = kv_size(layers);
while (insert_at > 0 && kv_A(layers, insert_at - 1)->zindex > grid->zindex) {
    insert_at--;
}
if (curwin && kv_A(layers, insert_at - 1) == &curwin->w_grid_alloc
    && kv_A(layers, insert_at - 1)->zindex == grid->zindex
    && !on_top) {
    insert_at--;
}
```

A new grid goes above everything with `zindex <= its own`, **except** that if the layer immediately below is the current window's grid at equal `zindex`, it is inserted below it — the focused overlay keeps the top of its band. Focus also raises: `ui_comp_grid_cursor_goto` walks the current grid up to the top of its band whenever the cursor enters it ([`ui_compositor.c:282-302`][comp-cursor]) — within the band, never across it.

The re-sort on a `zindex` change is a one-directional bubble ([`ui_compositor.c:109-132`][comp-adjust]), triggered from `ui_ext_win_position` only when the grid is already composited and the `zindex` actually changed:

```text
adjust(idx, raise):                     # zindex changed in place
    if raise: while idx < size - 1 and layer.zindex > layers[idx + 1].zindex: swap up
    else:     while idx > 0        and layer.zindex < layers[idx - 1].zindex: swap down

cursor_goto(grid):
    new := size - 1
    while new > 1 and layers[new].zindex > grid.zindex: new--
    if grid.comp_index < new: raise grid to new
```

There is no overlay tree and no ownership: parenthood exists only as `config.window` for anchoring, and closing an anchor does not close its dependents. `hide = true` removes the grid from `layers` and recomposes the area beneath **without deallocating the grid** ([`window.c:974-979`][w-hide], [`ui_compositor.c:215-239`][comp-remove]) — a cheap show/hide that preserves content and scroll position, used by the completion menu's info panel and by `'previewpopup'`. `external = true` is the one true portal: the grid becomes a real top-level OS window managed by the UI client, incompatible with all positioning keys.

**Where the behavior lives.** Framework kernel, entirely in `src/nvim/ui_compositor.c`. No OS compositor, no stacking contexts. `external` delegates to the client via `ui_call_win_external_pos`.

**Degradation.** This is the dimension that demonstrates a [top layer][concepts] is not required: "front to back equals later in the list" is literally the implementation, since `comp_index` _is_ the paint order. Two rules generalise cleanly: equal-priority ties resolve in favour of the focused surface rather than insertion order, and focusing a surface raises it within its band but never across bands (so a tooltip cannot climb above a modal by being clicked). The `hide` state — out of the layer list, grid retained — is the cheap equivalent of not emitting a surface into the display list while keeping its state, and is cheaper than a visibility flag consulted per cell during paint.

### 11. Modality

Partial. There is no [modality][concepts] primitive: no modal flag, no scrim, no background input blocking, no [light dismiss][concepts], no accessibility modal bit. Every float is modeless. Three adjacent mechanisms stand in.

**Per-surface pointer passthrough.** `mouse = false` removes the surface from the hit scan entirely; there is no "blocked" state, only absence (`mouse.c:1844-1846`, quoted in dimension 7).

**A visual precedence signal expressed as a z-distance, not a boolean.**

```c
// src/nvim/ui.c:709-716 — ui_cursor_is_behind_floatwin()
int crow = curwin->w_winrow + curwin->w_winrow_off + curwin->w_wrow;
int ccol = curwin->w_wincol + curwin->w_wincol_off
           + (curwin->w_p_rl ? curwin->w_view_width - curwin->w_wcol - 1 : curwin->w_wcol);

ScreenGrid *top_grid = ui_comp_get_grid_at_coord(crow, ccol);
return top_grid != &curwin->w_grid_alloc
       && top_grid != &default_grid
       && top_grid->zindex >= curwin->w_grid_alloc.zindex + 50;
```

When true, the UI draws a dimmed cursor shape ([`news.txt:201`][news-zindex]). That `+ 50` constant is the closest thing in the tree to "this surface asserts precedence over what is behind it", and it is a _distance_ rather than a flag.

**A per-surface blend instead of a scrim.** `'winblend'` ([`options.lua:10917`][opt-winblend], applied by [`hl_apply_winblend`][hl-winblend]) blends a float against whatever is behind it, and `'pumblend'` does the same for the completion menu. There is no way to dim the background — only to make the foreground translucent. Keyboard blocking, where wanted, is achieved by focusing the float (`enter = true`) so normal-mode mappings resolve in its buffer: modality by focus, not by capture.

**Where the behavior lives.** Framework kernel: `src/nvim/ui.c`, `src/nvim/ui_compositor.c` (note that [`ui_comp_get_grid_at_coord`][comp-coord] ignores `mouse_enabled` but honours `hide`), `src/nvim/mouse.c`, `src/nvim/highlight.c`.

**Degradation.** Everything here works with one pointer, no key release, no OS window and no compositor. Two shapes generalise: a z-**distance** threshold is a value-typed, assertable substitute for a modal boolean that degrades to "nothing happens" when no surface is above; and "no scrim, only per-surface blend" is the correct terminal answer, because a cell backend cannot dim a background it does not own but can make the overlay translucent against it, per cell, by glyph.

### 12. Adaptive presentation

Partial. There is no compact/regular adaptation and no touch adaptation — there is one presentation. But there is an adaptation axis the subject takes seriously: **the user, not the platform, owns the chrome.**

```text
border resolution order (per float, at open):
    if config.border was given:                      parse it
    elif p_winborder != "" and (wp == NULL or not wp.floating):  parse 'winborder'
    else:                                            no border

parse: a style name -> one of seven 8-char tables
       a string containing ',' -> exactly 8 comma-separated entries
       an array of 1 | 2 | 4 | 8 entries, doubled by memcpy until 8
       each entry is "char" or ["char", "HlGroup"]; each at most one display cell
       reject an empty corner sitting between two present edges
```

`'winborder'` is a global option and `parse_win_config` falls back to it for any float that does not pass `border` explicitly, applying it only at open time and only when the window is not already a float ([`win_config.c:1462-1465`][wc-winborder]). One user setting therefore re-styles every plugin's overlay, and a plugin that hard-codes `border='single'` opts out. The same pattern repeats at three more scales: `'pumborder'` for the completion menu ([`options.lua:6927`][opt-pumborder]), `'previewpopup'` as a `height:N,width:N,border:style` keydict in which an omitted dimension means "derive from content" ([`winfloat.c:586-617`][wf-preview-cfg]), and `style='minimal'` as a named preset that mass-clears `number`, `relativenumber`, `cursorline`, `cursorcolumn`, `spell`, `list`, `foldcolumn`, `colorcolumn` and `statuscolumn`, sets `signcolumn=auto`, and hides the end-of-buffer region via a `fillchars`/`winhighlight` append ([`winfloat.c:120-179`][wf-minimal]).

> [!WARNING]
> `style='minimal'` is applied **once**, after buffer attach, and only on transition ([`win_config.c:334-338`][wc-style]) — it is a one-shot mutation of window options rather than a layered style value. `float_spec.lua` carries three separate regression tests for it leaking into normal windows (`:581`, `:598`). In a value-semantics toolkit the preset should be a value composed at layout time, never a write-back.

**Where the behavior lives.** Split across layers: the default is a global user option read by the kernel at parse time; the override is per-call API; the preset is kernel code. No adaptation happens in the UI client — clients receive already-resolved border cells in the grid.

**Degradation.** A global chrome default plus a per-surface override needs no window system, no script and no measurement, so every target keeps it. For Android, the same slot as `above_ch` is where "the soft keyboard occupies the bottom N rows" belongs — an _input_ to placement supplied by the host and resolved before the clamp, not something the solver discovers. See [`../platform-ui-guidelines/index.md`][pug] for how platforms express those insets.

### 13. Accessibility

Not applicable, and honestly so. Core exposes no accessibility tree, no roles, no description-versus-label distinction, no live regions and no AT integration — not for floats, not for anything. What a terminal can honestly expose is what nvim does expose: characters and attributes in a cell grid, a cursor position, and, for multigrid clients, structural metadata:

```text
win_float_pos(grid, win, anchor, anchor_grid, anchor_row, anchor_col,
              mouse_enabled, zindex, compindex, screen_row, screen_col)
win_hide(grid) / win_close(grid) / win_external_pos(grid, win)
```

The primitive publishes structure as data and delegates semantics to whoever has a tree ([`api-ui-events.txt:637`][ev-floatpos], [`dev.txt:753`][doc-dev]). Nothing distinguishes tooltip from popover from menu from dialog at any level — the completion menu, the message pager, an LSP hover and a user dialog are all `WinConfig` values with different `zindex` — so there is no role to expose even if there were an API.

Two adjacent facts matter downstream. Float content is fully interactive by construction (it is a real editor window with a real buffer), so the "tooltip content must not be interactive" hazard never arises here: there are no tooltips, only miniature editors. And the only concession to "a screen element is obscured" is the dimmed-cursor signal of dimension 11 — a visual hint to the UI, not an announcement.

**Where the behavior lives.** Nowhere in nvim; delegated wholly to the UI client via the multigrid event stream.

**Degradation.** With no OS window there is no accessibility API to talk to, so the primitive's obligation reduces to emitting enough **structure** for a host that has one. Neovim's list is a reasonable minimum for a display-list-carried overlay record: surface identity, anchor identity, anchor corner, stacking order, hit-testability, and the resolved rect. Everything role-shaped belongs to the semantic component above the primitive — this subject demonstrates that a widely used overlay system can ship with no role vocabulary at all, at the cost of every consumer reinventing focus and dismissal policy (dimension 16).

### 14. Animation

Not applicable in core. There is no enter/exit transition, no reduced-motion switch, no [transform origin][concepts] and no per-frame interpolation: a float appears fully formed on the next flush and disappears the same way. The closest thing is `'redrawdebug'=compositor`, which deliberately _slows_ compositing by `'writedelay'` milliseconds per recomposed band so a human can watch the damage regions ([`ui_compositor.c:499-531`][comp-debug]) — a debugging animation, not a presentation one.

The subject nevertheless emits geometry metadata specifically so a client can animate. `win_float_pos` carries the anchor corner, the anchor grid, the anchor row and column (as floats, i.e. sub-cell capable), `zindex`, `compindex` _and_ the resolved screen row and column, and the docs present these as two alternative contracts (quoted in the Overview). A GUI can therefore derive a transform origin from `anchor` — NW/NE/SW/SE names the fixed corner directly — and ease from the anchor cell. `win_viewport`'s `scroll_delta` exists for the same reason, "to implement smooth scrolling" in clients ([`api-ui-events.txt:690-697`][ev-scrolldelta]).

```text
per surface, per flush, emit BOTH:
    abstract: (anchor_corner, anchor_target_id, anchor_row, anchor_col)   # may be fractional, may be off-screen
    resolved: (screen_row, screen_col, zindex, paint_index)               # integer cells, on-screen
a client picks one contract per surface; nvim never assumes which
```

**Where the behavior lives.** Framework kernel emits ([`window.c:960-966`][w-floatpos]); the UI client owns all motion.

**Degradation.** A static HTML target has no script, a TUI has no sub-cell position, and a recording canvas has no time, so animation must be optional and every behavior must be assertable in one frame. The split above is the right shape for that: publish the placement layer's _output_ as a value carrying both the chosen corner and the resolved integer rect. A pixel backend eases from the corner; a cell backend and a script-free HTML emitter ignore it; a test asserts on the rect and the corner without running a frame loop. Emitting the corner as data even where it cannot be used is what makes the pixel backend's animation possible without a second placement pass.

### 15. State architecture

Applies, and this is the dimension that ports most directly. Overlay state is pure value semantics with one owned resource.

```text
reconfigure(win, patch):
    cfg := win.config                            # copy the value
    for each key k present in patch: validate(k); cfg.k := patch.k
    on any failure: cfg := win.config; return error          # transactional restore
    if converting float <-> split: clear_float_config(&cfg, preserve {style, _cmdline_offset})
    merge(&win.config, cfg)                      # free owned text if changed, then *dst = src
    mark dirty bits; placement re-runs at next flush

placement never writes back into cfg; it writes win.w_winrow / win.w_wincol
```

`WinConfig` is flat POD with a designated-initialiser default. `nvim_win_set_config` does `WinConfig fconfig = w->w_config;` then lets `parse_win_config` overwrite only the present keys, then commits ([`win_config.c:756-775`][wc-copy]). Commit is `merge_win_config` ([`window.c:848`][w-merge]): literally `*dst = src` after freeing the old title/footer virt-text when the pointers differ — assignment plus one manual destructor, which is what a D struct with a `SmallBuffer` member would do implicitly. Failure is transactional: on any validation error the parse restores the previous config ([`win_config.c:1508`][wc-restore]). `clear_float_config` is a targeted reset that preserves exactly two fields across a float-to-split conversion ([`window.c:862`][w-clearcfg]).

There is no controller object, no reducer and no state machine — the surface's state _is_ the value plus a handful of dirty bits (`w_pos_changed`, `w_redr_border`, `w_hl_needs_update`). Controlled versus uncontrolled does not arise, because nvim never mutates `w_config.row`/`col` in response to clamping: the clamped result goes to `w_winrow`/`w_wincol`, a separate pair. The one path that broke that rule — `'previewpopup'`, which re-decides its own flip — had to add `w_wantline`/`w_wantcol` to hold the un-placed anchor, and says so in the comment quoted in the Overview.

**Where the behavior lives.** Framework kernel, spread over three files sharing one discipline: `src/nvim/api/win_config.c` (parse/validate), `src/nvim/window.c` (merge/clear), `src/nvim/winfloat.c` (apply).

**Degradation.** A flat POD config, `HAS_KEY`-guarded partial updates over a copy, transactional restore on validation failure, and a strict separation of requested from resolved geometry all work in `@safe @nogc` D with no allocation beyond the owned title/footer text. Two rules stand out: never write the clamped result back into the request, or the overlay cannot be re-placed idempotently when the viewport changes; and make the update a total function of (old value, patch), so a rejected patch is a no-op by construction rather than by unwinding.

### 16. Shared infrastructure

Applies. The factoring is **one primitive, no shared policy** — an anchored, z-ordered, bordered cell rectangle that can hold a buffer — with everything above the rectangle duplicated per consumer. The duplication is countable.

| Concern            | Implementations in this tree                                                                                                        |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| above/below choice | four: `make_floating_popup_options` (Lua), `win_float_update_preview`, `pum_compute_vertical_placement`, `pum_adjust_info_position` |
| left/right choice  | three: the LSP `wincol + width + offset_x <= columns` test, `win_float_update_preview`, `pum_compute_horizontal_placement`          |
| border default     | three: `'winborder'`, `'pumborder'`, `'previewpopup'`'s `border:` key falling back to `'winborder'`                                 |
| content sizing     | two: `_make_floating_popup_size` (Lua), the autosize block in `win_float_update_preview`                                            |
| dismissal helper   | one: `close_preview_autocmd`, used only by the LSP/diagnostic family                                                                |

The completion popup menu — arguably the most overlay-shaped element in the editor — is not a float at all. It is a raw `ScreenGrid` pushed straight into the compositor with a hard-coded `zindex` ([`popupmenu.c:663`][pum-put]), and the message grid is the same. So the pum shares the compositor and the border renderer (it calls `grid_draw_border` with a synthesised `WinConfig`, [`popupmenu.c:689`][pum-border]) but none of the anchor or config machinery.

What genuinely is shared, and correctly so: the compositor (layers, `zindex`, damage, blend, hit test), `grid_draw_border`, the `hide` mechanism, and the `win_float_special(enter, new_buf, kind)` factory that both special popups use to obtain a non-focusable, hidden, `noautocmd`, `style=minimal` scratch float ([`winfloat.c:444`][wf-special]).

```text
what this subject puts in ONE primitive:
    anchor resolution (descriptor -> integer cell), including text-position anchors
    corner selection (which edge the coordinate names)
    the clamp/shift into the surface, with a per-surface opt-out
    z-order insertion with focus-wins tie-break, and focus-raises-within-band
    hit testing by reverse paint order, with a per-surface hittable bit
    chrome as an 8-slot char + highlight table with derived per-side thickness
    show/hide without destroying content

what it leaves APART (and duplicates four ways rather than two):
    the above/below and left/right decision, including its tie-break
    content-derived sizing and max width/height
    the dismissal event set
    singleton / re-entry identity
    whether the surface takes focus on open
```

Two wide-character fixups belong to the shared half and are easy to miss. At every overlay boundary `compose_line` repairs bisected double-width glyphs in **both** directions: if a composed run's first cell is the right half of a wide character it is replaced with a space, and if the cell just past the run is a right half the last copied cell is replaced with a space ([`ui_compositor.c:460-475`][comp-wide]). Without them, an overlay edge landing mid-glyph leaves an orphaned half and desynchronises the row's cell accounting for the rest of the line.

**Where the behavior lives.** Shared: `src/nvim/ui_compositor.c`, `src/nvim/grid.c`, `src/nvim/winfloat.c:win_float_special`. Duplicated: `runtime/lua/vim/lsp/util.lua`, `src/nvim/winfloat.c:win_float_update_preview`, `src/nvim/popupmenu.c` (twice).

**Degradation.** The line this subject draws is target-independent: everything below it is integer-cell arithmetic plus a paint order, all of which works with no OS window, no hover, no script, no key release and no sub-cell precision. Everything above it needs knowledge the primitive cannot have — what the content is, what the trigger was, what should dismiss it. The four divergent above/below rules are the observable cost of not offering at least a **named, selectable policy value** in the config, which a recording canvas could assert on and which a script-free target could resolve at emit time.

## Strengths

- The anchor is a plain comparable POD — six relative bases, a window handle, a text position, two doubles and a 2-bit corner mask — copyable, serialisable, and round-trippable through `nvim_win_get_config` back into `nvim_open_win`.
- `bufpos` is a first-class text-position anchor resolved through the same `textpos2screenpos` the editor uses for its own geometry, and it pins to the viewport edge rather than disappearing when the text scrolls away.
- Four corner anchors make above/below and left/right symmetric with a single small integer offset table, with no size-dependent arithmetic and no rounding.
- Anchor tracking is dirty-flag driven with a recursion guard that clears the flag _before_ recursing, so anchor-of-anchor chains — and cycles the API's self-anchor guard does not catch — resolve in one bounded pass at flush time, with no observers and no polling.
- The compositor is small and correct in the hard cases: four-band damage decomposition on move, double-width glyph repair at every overlap seam in both directions, and a layer ordering that makes the per-run topmost scan correct without a z-buffer.
- Transparency without alpha: glyph-keyed negative space per cell plus memoised attribute-pair blending yields usable translucency and a real drop shadow built from nothing but border cells and colour arithmetic.
- Focus and hit-testing are separate booleans, giving genuine per-surface click-through and a tab ring that skips inert overlays.
- Config updates are transactional patches over a copied value with restore-on-failure: a rejected reconfigure leaves zero partial state.
- Chrome is data — an 8-slot `(char, highlight)` table, clockwise from top-left, with per-side thickness derived from whether that side's edge char is non-empty, plus a global `'winborder'` default every consumer inherits unless it opts out.
- The UI protocol publishes both the abstract anchor and the resolved screen cell on every reposition, plus `zindex` and the exact paint index — enough for a client to reproduce the placement, override it, or animate from the anchor corner.
- Dismissal order is derived from z-order (`:fclose` closes the highest-`zindex` floats first) rather than from a parallel stack that could desynchronise, with `'winpinned'` as the per-surface opt-out.
- `float_spec.lua` is 12,607 lines and pins the edge cases that matter here: fixed-versus-shift, border-inclusive anchoring, `bufpos` out of range, title left-truncation across virt-text chunks, all four `focusable`/`mouse` combinations, and `zindex` reordering.

## Weaknesses

- No flip in the primitive, and the four rules that fill the gap disagree: the LSP `'auto'` bias compares available space without checking whether the popup fits, `'previewpopup'` prefers-with-fallback, the pum requires both "does not fit below" and "more than half the space is above", and the pum info panel picks the larger side and hides below ten cells.
- `fixed` prevents only horizontal truncation: the row clamp at `window.c:950` is unconditional, so a fixed float can never hang off the bottom even though it can hang off the right.
- Fractional `row`/`col` is documented as "round down to nearest integer" but implemented as a C cast, which truncates toward zero; the two appear to diverge by a cell for a window-relative float at a negative fractional row, and no test in the suite exercises that case.
- The size clamp in `win_config_float` is skipped when the UI is multigrid, so an identical config produces a different rect on a GUI than in the TUI — backend-conditional geometry inside the model layer.
- No overlay ownership: closing a float's anchor window does not close the float. `find_window_by_handle` returns `NULL` and placement silently falls back to raw editor-relative coordinates.
- `focusable` also assigns `mouse`, and `focusable=false, mouse=true` still focuses on click — an ordering-dependent coupling that needed its own regression test.
- No roles, no accessibility surface, and no distinction between tooltip, popover, menu and dialog anywhere, so every consumer reinvents focus, dismissal and interactivity policy.
- The completion popup menu is not a float but a raw `ScreenGrid` with a hard-coded `zindex`, so the editor's most overlay-shaped element shares the compositor and the border renderer but none of the anchor or config machinery.
- No timing infrastructure for overlays: the ecosystem's hover delay is `'updatetime'` plus `CursorHold`, a global editor setting that was not designed for it.
- `compose_line` is O(layers) per run with no spatial index, and its correctness depends subtly on the bottom-to-top iteration order in a way no comment explains.
- The requested-versus-placed separation is a convention rather than an invariant: `'previewpopup'` had to add a second anchor pair to the window struct, and only a comment keeps the two in sync.
- Nothing is bound to Escape. Dismissal exists (`:fclose`, `'winpinned'`) but is unbound and undiscoverable; the LSP layer instead installs a buffer-local `q` mapping inside each float.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                      | Rationale                                                                                                                                                                                                                                                                                               | Trade-off                                                                                                                                                                                                                                                                                                                                                      |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core resolves anchors and clamps; core does not flip. Placement policy lives outside the primitive, canonically in Lua.                                                       | Keeps the C primitive total: given a config it always produces a rect, never an error and never a surprise. It also lets a multigrid client override placement entirely, which is why `win_float_pos` carries both the abstract anchor and the resolved cell.                                           | Four incompatible above/below rules exist in one repository with four different tie-breaks, and the shared LSP path — reached by hover, signature help and diagnostics alike — does not test whether the popup fits on the chosen side. Divergent behavior is the direct cost of not shipping a named, selectable policy value.                                |
| Four corner anchors (NW/NE/SW/SE as a 2-bit mask) instead of side plus alignment.                                                                                             | Integer-exact and size-independent: subtracting the outer extent on the flagged axes converts the anchor cell to a top-left with no rounding and no alignment arithmetic. Above-the-text and below-the-text become the same offset table with a different corner, because the corner names the edge.    | Centre alignment is inexpressible; a consumer wanting a centred overlay must compute the column itself from the overlay's own width, reintroducing exactly the size-dependent arithmetic the corner model avoids. Only four of the eight useful attachment points exist — no edge midpoints.                                                                   |
| Two independent booleans for focus (`focusable`) and hit testing (`mouse`), coupled by default but separately settable.                                                       | A surface can be visible-and-inert, visible-and-clickable-but-outside-the-tab-ring, or fully interactive, with no extra concepts. `mouse=false` is genuine click-through: the layer is absent from the hit scan, so the event reaches whatever is behind it.                                            | The coupling is asymmetric and order-dependent: setting `focusable` silently overwrites `mouse`, and `focusable=false, mouse=true` still focuses on click — a combination with its own regression test because it reads as a contradiction. `focusable=false` is a traversal property, not access control: `nvim_set_current_win` enters such a window anyway. |
| Compositing is a flat `zindex`-sorted layer array with per-run topmost resolution, and the resolved paint order (`compindex`) is part of the public UI protocol.              | "Front to back equals later in the array" needs no compositor, no stacking contexts and no ownership tree, and publishing `compindex` lets a GUI reproduce the exact stacking instead of guessing from `zindex`. Ties favour the focused surface; focusing raises within a band but never across bands. | Composition is O(layers) per run with no spatial index — comfortable at this system's handful of layers, less so beyond. And because `compindex` is public, the compositor's internal ordering decisions (the current-window tie-break, the cursor-goto raise) are observable behavior that cannot be changed freely.                                          |
| Transparency is glyph-keyed and per-cell — a blank front cell lets the background glyph through — rather than a channel.                                                      | It is the only definition of "see-through" available when the smallest unit is a character cell with no alpha, and it makes drop shadows expressible as ordinary border cells instead of a separate effect subsystem.                                                                                   | Transparency is all-or-nothing per cell and is decided by content rather than intent: an overlay whose padding happens to be spaces becomes partly see-through whether the author wanted it or not, and U+2800 had to be special-cased because braille-art renderers rely on it reading as blank.                                                              |
| The overlay config is a plain POD value; updates are `HAS_KEY`-guarded patches over a copy, committed by struct assignment, with transactional restore on validation failure. | Makes reconfiguration total and atomic — a rejected patch is a no-op by construction, not by unwinding — and keeps the descriptor comparable, copyable and serialisable, so `nvim_win_get_config` round-trips back into `nvim_open_win`.                                                                | The single owned resource (title/footer virt-text) forces a hand-written merge that frees the old text only when the pointers differ: the one place the value illusion leaks, and where a double-free or a leak is possible in C. A `SmallBuffer` member would remove the hazard in D.                                                                         |
| Requested geometry and placed geometry live in different fields; placement never writes back into the config.                                                                 | Placement must be re-runnable: when the viewport resizes, the anchor scrolls, or the content re-autosizes, the clamp has to start from the original request rather than from the previously clamped result, or the overlay ratchets toward the screen edge.                                             | The rule is only partly enforced. `'previewpopup'` re-decides its own flip and therefore had to add a second anchor pair (`w_wantline`/`w_wantcol`) to the window struct with a comment explaining why `WinConfig.row`/`col` could not be reused. Two places now hold "where this thing is anchored", and only a comment keeps them consistent.                |
| No dismissal, timing, modality, accessibility or animation in the primitive at all.                                                                                           | A float is a window, and window lifetime already has a rich vocabulary (autocommands, `:close`, buffer-locals), so the primitive adds only `:fclose` (topmost by `zindex`) and `'winpinned'`. Consumers assemble the rest from events the host already delivers.                                        | Every consumer reimplements dismissal and they diverge: the LSP set is `CursorMoved`, `CursorMovedI`, `InsertCharPre` plus a scheduled `BufLeave` with a quickfix exception, while the pum info panel just sets `hide=true`, and nothing at all closes a float when its anchor window closes. There is no Escape binding anywhere by default.                  |

## Sources

Primary sources, all read at `2757f6eef92a99812d5ad12408d03592bd54f10c`:

- [`src/nvim/window.c`][w-uiext] — `ui_ext_win_position` (anchor resolution, corner, clamp, `above_ch`, the `win_float_pos` emission, the `hide` branch), `merge_win_config`, `clear_float_config`, `win_ui_flush`, the `CTRL-W w` traversal skip loop, the close-all-floats-before-last-window rule.
- [`src/nvim/winfloat.c`][wf-config] — `win_config_float` (cursor/mouse snapshot, `border_adj` derivation, size clamp), `win_check_anchored_floats`, `float_zindex_cmp` and `win_float_remove`, `win_float_find_altwin`, `win_float_special`, `win_float_update_preview` and `win_previewpopup_config`, `win_set_minimal_style`.
- [`src/nvim/api/win_config.c`][wc-open] — `nvim_open_win`, `parse_win_config` (the `HAS_KEY_X` patch discipline, the transactional restore, the `focusable`/`mouse` coupling, the `'winborder'` fallback, the `bufpos` offset defaults, the self-anchor guard), `parse_border_style` and its validation rules, and the API documentation comments on fractional rounding and on `fixed`.
- [`src/nvim/ui_compositor.c`][comp-line] — `ui_comp_put_grid` (insertion tie-break, four-band move damage), `ui_comp_layers_adjust`, `ui_comp_remove_grid`, `ui_comp_grid_cursor_goto`, `ui_comp_mouse_focus`, `ui_comp_get_grid_at_coord`, `compose_line` (the per-run topmost scan, the blend loop, the double-width fixups), the `redrawdebug` delay.
- [`src/nvim/buffer_defs.h`][bd-winconfig] — the `WinConfig` POD and `WIN_CONFIG_INIT`; `FloatAnchor`'s 2-bit mask; the `w_wantline`/`w_wantcol` comment.
- [`src/nvim/grid_defs.h`][gd-zindex] — the `kZIndex*` bands.
- [`src/nvim/grid.c`][grid-border] — `grid_draw_border`, `get_bordertext_col`, `grid_draw_bordertext` and its left-truncation across virt-text chunks.
- [`src/nvim/highlight.c`][hl-blend] — `hl_blend_attrs`, `hl_apply_winblend`, the shadow-border detection in `update_window_hl`.
- [`src/nvim/mouse.c`][mouse-grid] — `mouse_find_grid_win` and the `mouse=false` passthrough.
- [`src/nvim/move.c`][mv-t2s] — `textpos2screenpos` and its viewport-edge clamping.
- [`src/nvim/ui.c`][ui-behind] — `ui_cursor_is_behind_floatwin` and its `+ 50` z-distance rule.
- [`src/nvim/os/input.c`][in-get] — `input_get`'s two-timer deadline and the arm-instant comment; `reset_cursorhold_wait`.
- [`src/nvim/popupmenu.c`][pum-vert] — `pum_compute_vertical_placement`, `pum_compute_horizontal_placement`, `pum_adjust_info_position`, the raw-`ScreenGrid` push, the synthesised `WinConfig` handed to `grid_draw_border`.
- [`src/nvim/options.lua`][opt-winborder] — `'winborder'`, `'pumborder'`, `'winblend'`, `'winpinned'`, `'mousemoveevent'`, `'autocompletedelay'`.
- [`runtime/lua/vim/lsp/util.lua`][lsp-mfpo] — `make_floating_popup_options`, `_make_floating_popup_size`, `open_floating_preview`'s `focus_id` arbitration and one-float-per-buffer rule, `close_preview_autocmd`, the buffer-local `q` mapping.
- [`runtime/lua/vim/diagnostic/_float.lua`][diag-focusid] — `focus_id = scope`.
- Documentation in-tree: [`runtime/doc/api-ui-events.txt`][ev-floatpos] (the `win_float_pos` dual contract, the `compindex` rendering rules, `scroll_delta`), [`runtime/doc/windows.txt`][doc-windows] (`:fclose`), [`runtime/doc/options.txt`][doc-winpinned] (`'winpinned'`), [`runtime/doc/dev.txt`][doc-dev] (multigrid guidance), [`runtime/doc/news.txt`][news-zindex] (the `zindex`-driven dimmed cursor).
- Tests as behavior pins: [`test/functional/ui/float_spec.lua`][spec-fixed] — "window position fixed" (`:1485`), "bufpos out of range" (`:11411`), the title-truncation expectations (`:2343`), the `focusable`/`mouse` matrix (`:6612-6726`), the `style='minimal'` leak regressions (`:581`, `:598`), the compositor-reallocation test (`:1329`).

> [!IMPORTANT]
> Nothing here was verified by building or running Neovim; every behavioral claim is read from source or from assertions inside `test/functional/ui/float_spec.lua`. The claim that a multigrid client may choose either positioning contract comes from `runtime/doc/api-ui-events.txt` and `runtime/doc/dev.txt`, not from any client's source. The O(layers) characterisation of `compose_line` is read off the loop structure, not measured.

Catalog cross-links: [index][index] · [concepts][concepts] · [comparison][comparison] · [features people forget][forgotten] · [sparkles baseline][baseline] · [proposal][proposal]. Nearest neighbours in this tree: [nui.nvim][nui] and [nvim-completion][nvim-completion] (what plugins build on top of this primitive), [Helix][helix], [Textual][textual], [Ratatui][ratatui], [Notcurses][notcurses], [Turbo Vision][turbo-vision], [tmux popups][tmux-popup] and [Emacs posframe][emacs-posframe] (the other cell-grid answers), [GTK4][gtk4] and [xdg_positioner][xdg-positioner] (the same clamp-versus-flip question with a compositor available). Sibling research trees: [window-system integration][wsi], [platform UI guidelines][pug], [UI layout][ui-layout], [Sean Parent][sean-parent]. Toolkit specs: [`sparkles:ui`][spec-ui], [input][spec-input], [containers][spec-containers], [state machines][spec-stm], [backends][spec-backends], [widgets][spec-widgets].

<!-- References -->

[nvim-repo]: https://github.com/neovim/neovim
[doc-api]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/api.txt
[doc-windows]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/windows.txt#L416-L419
[doc-winpinned]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/options.txt#L7787-L7791
[doc-dev]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/dev.txt#L753-L770
[ev-floatpos]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/api-ui-events.txt#L637
[ev-two-contracts]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/api-ui-events.txt#L641-L648
[ev-compindex]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/api-ui-events.txt#L652-L661
[ev-scrolldelta]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/api-ui-events.txt#L690-L697
[news-zindex]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/doc/news.txt#L201-L202
[w-uiext]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L876-L878
[w-anchor]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L891-L925
[w-corner]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L945-L946
[w-clamp]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L947-L953
[w-floatpos]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L960-L966
[w-hide]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L974-L979
[ui-external]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L980-L982
[w-merge]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L848-L858
[w-clearcfg]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L862-L874
[w-flush]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L7904-L7920
[w-traverse]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L403-L435
[w-lastwin]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/window.c#L2815-L2841
[bd-winconfig]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/buffer_defs.h#L1004-L1037
[bd-anchor]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/buffer_defs.h#L956-L959
[bd-want]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/buffer_defs.h#L1210-L1214
[gd-zindex]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/grid_defs.h#L10-L16
[wf-config]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L191
[wf-snapshot]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L204-L221
[wf-adj]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L232-L238
[wf-size-clamp]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L240-L244
[wf-remove]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L289-L321
[wf-check]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L323-L332
[wf-altwin]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L401-L413
[wf-special]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L444-L502
[wf-preview-flip]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L568-L570
[wf-preview-cfg]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L586-L617
[wf-minimal]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/winfloat.c#L120-L179
[wc-open]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L197
[wc-round]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L64-L67
[wc-fixed-doc]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L137-L138
[wc-focus-doc]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L139-L141
[wc-style]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L334-L338
[wc-copy]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L756-L775
[wc-borderstyle]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1077-L1090
[wc-shadow]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1086
[wc-border-cell]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1131-L1134
[wc-corner-valid]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1147-L1153
[wc-bufpos]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1317-L1322
[wc-self]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1370-L1373
[wc-focusmouse]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1391-L1398
[wc-winborder]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1462-L1465
[wc-restore]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/api/win_config.c#L1507-L1509
[comp-adjust]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L109-L132
[comp-put]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L140-L213
[comp-tiebreak]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L181-L190
[comp-remove]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L215-L239
[comp-cursor]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L282-L302
[comp-hit]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L312-L333
[comp-coord]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L335-L357
[comp-line]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L359-L405
[comp-scan]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L384-L405
[comp-blend]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L436-L458
[comp-wide]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L460-L475
[comp-debug]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui_compositor.c#L499-L531
[grid-border]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/grid.c#L1145
[grid-btcol]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/grid.c#L1131-L1142
[grid-bttrunc]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/grid.c#L1093-L1120
[hl-blend]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/highlight.c#L751-L825
[hl-winblend]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/highlight.c#L352-L361
[hl-shadow]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/highlight.c#L407-L421
[mouse-grid]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/mouse.c#L1838-L1850
[mv-t2s]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/move.c#L1078
[mv-clamp]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/move.c#L1099-L1103
[ui-behind]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ui.c#L699-L716
[in-get]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/os/input.c#L117-L142
[in-reset]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/os/input.c#L68
[in-elapsed]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/insexpand.c#L6401-L6404
[ex-fclose]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ex_docmd.c#L8146-L8149
[ex-windo]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/ex_cmds2.c#L598
[pum-vert]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/popupmenu.c#L124
[pum-horiz]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/popupmenu.c#L223-L270
[pum-put]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/popupmenu.c#L663
[pum-border]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/popupmenu.c#L689
[pum-info]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/popupmenu.c#L986
[opt-acl]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L274
[opt-mousemove]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L6324-L6328
[opt-pumborder]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L6927-L6945
[opt-winblend]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L10917-L10922
[opt-winborder]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L10924-L10952
[opt-winpinned]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/src/nvim/options.lua#L11134
[lsp-mfpo]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L766-L812
[lsp-auto]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L795
[lsp-close]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L1351-L1373
[lsp-size]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L1381-L1450
[lsp-events]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L1528
[lsp-focusid]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L1540-L1563
[lsp-qmap]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/util.lua#L1606-L1612
[h-hover]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/handlers.lua#L419
[h-sig]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/lsp/handlers.lua#L477
[diag-focusid]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/diagnostic/_float.lua#L244-L246
[diag-open]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/runtime/lua/vim/diagnostic/_float.lua#L250
[spec-fixed]: https://github.com/neovim/neovim/blob/2757f6eef92a99812d5ad12408d03592bd54f10c/test/functional/ui/float_spec.lua#L1485-L1560
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forgotten]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[nui]: ./nui.md
[nvim-completion]: ./nvim-completion.md
[helix]: ./helix.md
[textual]: ./textual.md
[ratatui]: ./ratatui.md
[notcurses]: ./notcurses.md
[turbo-vision]: ./turbo-vision.md
[tmux-popup]: ./tmux-popup.md
[emacs-posframe]: ./emacs-posframe.md
[gtk4]: ./gtk4.md
[xdg-positioner]: ./xdg-positioner.md
[wsi]: ../window-system-integration/index.md
[pug]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-stm]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
