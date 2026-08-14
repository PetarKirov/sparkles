# nui.nvim (Lua / Neovim)

A component library for Neovim floating windows whose entire contribution to this survey is a
_declarative cell-geometry vocabulary_ — `{relative, position, size, anchor, border}` normalized
by one function — deliberately paired with the total absence of a collision engine, because the
host clips, converts and dismisses on its behalf.

| Field         | Value                                                                                                                                                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Lua (Neovim runtime)                                                                                                                                                                                                            |
| License       | MIT                                                                                                                                                                                                                             |
| Repository    | [`MunifTanjim/nui.nvim`][repo]                                                                                                                                                                                                  |
| Documentation | In-repo `README.md` per component; a GitHub wiki exists but was **not** consulted — every claim below is an implementation reading                                                                                              |
| Category      | Terminal / cell grid                                                                                                                                                                                                            |
| Surface model | in-canvas. Every nui overlay is a Neovim floating window, and Neovim's own compositor merges them into one terminal cell grid. There is no OS popup, no per-overlay OS surface, and no sub-cell precision anywhere in the stack |
| Revision read | `de740991c12411b663994b2860f1a4fd0937c130` (2 commits past tag `0.4.0`)                                                                                                                                                         |

> [!NOTE]
> The repository's own test suite was not executed here: `tests/init.lua` `packadd`s
> `plenary.nvim` from `.tests/site` plus a vendored patch (`scripts/plenary-353.patch`), neither
> present in the read-only clone. Runtime observations below come from targeted probes written
> against the library under `nvim --headless -l`, with `nvim_command("redraw")` stubbed out
> (headless Neovim segfaulted on `redraw` with a second float attached). Numbers reported as
> "verified" are `nvim_win_get_config` readings and function return values, not observed pixels.

## Overview

### What it solves

nui.nvim wraps Neovim's `nvim_open_win` in a component set: `Popup` (a window + buffer with an
optional border), `Menu` and `Input` (both `Popup` subclasses), `Split`, and `Layout` — a
flexbox-ish box tree that drives many `Popup`s from one invisible container float. The problem it
actually solves is not placement but _vocabulary_: turning a pile of imperative window calls into
a single plain record where `position` and `size` each accept an integer cell count, a percentage
string, a decimal in `(0,1)`, or a `{row,col}` / `{width,height}` table, and `relative` accepts
`editor | win | cursor | buf` with an optional target window id or buffer position. Everything
normalizes into one internal record that is then handed to the host.

The single most consequential line in the library is in `lua/nui/layout/utils.lua:41`, inside
`mod.calculate_window_position` — a percentage position is a fraction of the **free space**, not
of the container:

```lua
row = math.floor((container.size.height - size.height) * r.value)
```

`position = "50%"` therefore _centres_ the overlay and `"100%"` puts its bottom-right corner at the
container's bottom-right. The README documents only that "position is calculated from the top-left
corner" and never states this. Verified at the pinned revision: container 100x40, size 40x10,
`"50%"` returns `row = 15, col = 30`.

### Design philosophy

The philosophy is delegation. nui computes _numbers in cells_ and nothing else. It never reads the
cursor for [placement][concepts], never measures the screen for overflow, never flips, shifts or
clamps, never installs a timer, and contains no pointer or hover code at all — `grep` over `lua/`
for `mouse`, `hover` or `nvim_input_mouse` returns zero hits, and the only occurrence of the word
"mouse" in the repository is README prose describing what `focusable = false` prevents.
Anchor-to-screen conversion (cursor position, buffer position through scroll and wrapping,
off-screen clipping, stacking at equal `zindex`) is Neovim's job. Dismissal policy is the
_caller's_ job, wired through `popup:on(event.BufLeave, …)` — the README's canonical snippet at
`README.md:139`. The library's own automatic lifecycle is two autocommands: `QuitPre → unmount`
and `WinClosed → hide`.

The most instructive consequence of that delegation is the border. Neovim's native `border=`
cannot carry padding or per-side titles, so nui splits into a **simple** border (delegated to the
host, drawn _outside_ the window rect) and a **complex** border (a second, unfocusable float
underneath, whose buffer nui fills with hand-composed box-drawing lines, with the popup re-parented
inside it). The mode is derived, not configured — `border.lua:469` picks `complex` as soon as
`text` or `padding` is requested. That split, and the fact that the two halves use _different box
models_, is where nearly every surprising behavior in this codebase lives.

## How it works

A mount is three phases: normalize the spec, resolve it against a container, hand the numbers to
the host.

```text
Popup(opts)            -- merge_default_options: relative="win", enter=false, zindex=50
  update_layout_config -- layout/utils.lua:125  spec -> {relative, win, bufpos, position, size}
  Border(popup)        -- derive simple|complex; 8-slot char map; size_delta
popup:mount()
  border:mount()       -- complex only: a second float, focusable=false, same zindex
  _open_window()       -- nvim_open_win(bufnr, enter, win_config)
  adjust_popup_win_config -- complex only: re-parent the popup INSIDE the border window
```

`update_layout_config` is the whole resolver, and it is shared: `Popup:update_layout`
(`popup/init.lua:388`) and `Layout:update` (`layout/init.lua:438`) both call it against
differently-shaped `internal` tables. It normalizes `relative` through `parse_relative`, recomputes
`container_info`, resolves `size` and then `position` through `calculate_window_size` /
`calculate_window_position`, and finally asserts all three are present, erroring with
`missing layout config: …` otherwise.

`parse_relative` (`layout/utils.lua:103`) collapses four anchor kinds into three fields. Note that
`buf` is not a distinct kind internally — it becomes `relative = "win"` plus
`bufpos = {row, col}`, and `get_container_info` (`layout/utils.lua:79`) re-derives the label `buf`
from the presence of `bufpos`.

The border's box model is two lines, `border.lua:346-347` inside `calculate_position`:

```lua
position.col = position.col - math.floor(border._.size_delta.width / 2 + 0.5)
position.row = position.row - math.floor(border._.size_delta.height / 2 + 0.5)
```

The border window is **centred** on the popup's rect by half the total size delta (round-half-up)
rather than offset by the actual top/left thickness. That is correct only when the border is
symmetric on both axes. With `padding = {top = 4, bottom = 0}` the content lands two rows below
where it was asked for — verified at the pinned revision: requested row 10 gives border row 7 plus
an inner offset of 5, so content at row 12.

The border _content_ is composed by `calculate_buf_edge_line` (`border.lua:169`) as
`left ++ mid^leftgap ++ content ++ mid^rightgap ++ right`, with corner fallbacks
(`border.lua:176-178`): an empty corner char degrades to the horizontal edge char, and if that is
also empty, to the vertical side char.

```lua
if left_char:content() == "" then
    left_char = Text(mid_char:content() == "" and char["left"] or mid_char)
end
```

Erasing a side is therefore also a _layout_ operation, not only a paint one: `calculate_size_delta`
(`border.lua:282`) charges one cell per non-empty side, so the delta drops by exactly one when a
side is blanked.

`Layout` (`layout/float.lua:72 mod.process`) is a single-pass linear box flow: children are laid
along `box.dir` accumulating a running cursor, then a second pass distributes leftover space to
`grow` children as `floor(remaining / total_grow_factor) * child.grow`. Cost is O(children) per
pass, two passes, all integer. The layout engine drives its children through the same public
`set_layout` entry point an application would use (`layout/float.lua:102`), so there is one code
path where percentages, deltas and clamps get applied.

## The analysis spine

### 1. Anchor model

Four anchor kinds, all one plain record: `{ type = "editor"|"win"|"cursor"|"buf", winid?, position? }`
(`layout/utils.lua:10`). Only the `editor` and `win` cases are a rect; `cursor` and `buf` are
**symbolic** anchors that nui never resolves — it hands the token to `nvim_open_win` and the host
converts it at open time, including scroll, wrapping and folds for `bufpos`. nui reads
`nvim_win_get_cursor` nowhere in the placement path; the one call is in `Input` for caret
_restoration_ (`input/init.lua:135`). Commit `3dc46d7` made the cursor anchor **late-bound** rather
than captured: `relative.type == "cursor"` stores window id `0`, i.e. "whatever window is current
at layout time", resolved in `get_container_info`. `relative = "cursor"` is therefore a moving
anchor implemented with no tracking code at all — the host re-anchors it every redraw. There is no
text-range or multi-rect anchor, no [virtual anchor][concepts], no detached trigger, and no
many-triggers-one-overlay notion.

**Algorithm.** `parse_relative(relative, fallback_winid)`: `winid := relative.winid ?? fallback_winid`;
if `type == "buf"` return `{relative = "win", win = winid, bufpos = {position.row, position.col}}`,
else `{relative = type, win = winid}`. `update_layout_config` chooses `fallback_winid` as the
existing `internal.position.win`, else `0` when the type is `cursor`, else the current window, and
projects into the window config: `win_config.relative`, `win_config.win` (only when
`relative == "win"`), `win_config.bufpos`.

**Where it lives.** Normalization in library code (`layout/utils.lua`); anchor-to-screen conversion
in the host. Nothing anchor-related is in the paint path.

**Degradation.** Nothing degrades. The record is integer cells plus a symbolic token, computed with
no measurement, no hover, no script and no key release; sub-cell precision never existed. A toolkit
with no window server must supply the two conversions Neovim supplies here — caret-to-cell and
document-position-to-cell — but each is one pure function over knowledge the toolkit already owns.
INFERENCE: the anchor record appears to be a plain comparable value (a flat table of a string, an
integer and two integers) — nothing in the anchor path holds a handle or a closure — which is the
property a value-semantics port would want; the structure suggests it, though Lua tables are of
course reference values in the host language.

### 2. Placement model

Placement is **absolute**, not relational. There are no sides, no alignment, no preferred list, no
fallback ordering, no [flip, shift or slide][concepts], no viewport padding, no safe area, no
multi-monitor and no IME avoidance. The vocabulary is exactly three things: `position` = `{row, col}`
offsets in cells from the container origin (or from the cursor/buffer point); `size` =
`{width, height}` in the same forms; and `anchor` = which _corner_ of the overlay lands on
`position` (`"NW"|"NE"|"SW"|"SE"`), which `popup/init.lua:112` passes straight through to the host
without either geometry function consulting it.

Two undocumented behaviors matter. First, a percentage position is a fraction of the free space
(above), so `"50%"` centres and `"0%"` is top-left. Second, `parse_number_input`
(`utils/init.lua:58`) treats **any** number strictly between 0 and 1 as a percentage — for
position as well as size, where the README documents the rule only for size. So `position = 0.999`
is 99.9% of the free space while `position = 1` is literal cell 1: a hard discontinuity at 1.0.
Percentage positions are rejected by an `assert` when `relative` is `buf` or `cursor`
(`layout/utils.lua:34`), because free space is undefined against a point anchor; percentage _sizes_
are still allowed there and resolve against the window size. RTL and writing modes do not exist.

There is no clamping whatsoever. Verified at the pinned revision: `position = "200%"` yields row 60
in a 40-line editor, `size = "200%"` yields a 200x80 window in a 100x40 editor, and
`position = {row = -5, col = -5}` passes through unchanged.

**Algorithm.** `calculate_window_size(size, container)`: per axis, `parse_number_input(v)` gives
`{value, is_percentage}` where `is_percentage` is "string ends with `%`" or `0 < number < 1`; if a
percentage, `floor(container_axis * value)`, else `value`.
`calculate_window_position(position, size, container)`: if a percentage,
`floor((container_axis - size_axis) * value)`, else `value`. No min, no max, no fit test.

**Where it lives.** Library code: `layout/utils.lua` (`calculate_window_position` /
`calculate_window_size`) and `utils/init.lua` (`parse_number_input`, `normalize_dimension`).
Everything after that is the host's.

**Degradation.** This dimension survives its substrate best precisely because it never depended on
it: two integer formulas over `(container, size, spec)`, with no hover, no script, no timers and no
sub-cell arithmetic. The absence is the lesson — a toolkit that ships only this vocabulary has no
answer when the overlay does not fit, and nui's answer is "the host clips it". A surface-owning
toolkit has no host to defer to, so the [constraint-adjustment][concepts] step nui skipped is
exactly the piece it would have to add.

### 3. Collision & geometry engine

There is no collision engine: no overflow detection, no [clipping-boundary][concepts] discovery, no
transforms or DPR (a cell grid has neither), no observers and no polling. What exists instead is a
narrow **reflow trigger with dependency tracking**, and it is the cleverest thing in the file.
`update_layout_config` recomputes size only if the caller passed a new size **or** the container
size changed **and** the stored size spec actually contains a percentage string — the predicates
being `mod.size.contains_percentage_string` (`layout/utils.lua:216`) and its position twin
(`:222`). An explicit `{width = 40}` therefore survives a resize untouched, while `"80%"` is
re-resolved.

> [!WARNING]
> The predicate tests `type(v) == "string"`, so a decimal `0.8` — which `parse_number_input`
> _does_ treat as a percentage — is not recognized as container-dependent and will not reflow.
> That is a genuine inconsistency at the pinned revision, and it is the direct cost of overloading
> one scalar with a magnitude-dependent meaning.

The reflow is caller-pumped: nothing subscribes to `VimResized`, and the caller must invoke
`popup:update_layout()` (which is what the test at `tests/nui/popup/init_spec.lua:840` does).

**Algorithm.** `update_layout_config(internal, config)`: normalize options; if `options.relative`,
re-derive `internal.position` and project `relative`/`win`/`bufpos`. Record
`prev := internal.container_info.size`; recompute `container_info`;
`changed := not size.are_same(new, prev)`. Recompute size iff `options.size` or
(`changed` and the stored size spec contains a percentage string); recompute position by the same
rule, independently. Then assert all three fields are present.

**Where it lives.** Entirely library code (`layout/utils.lua:125`, `layout/float.lua:72`). Actual
clipping and off-screen behavior live in Neovim's compositor and are never modelled by nui.

**Degradation.** The reflow-trigger idea generalizes with nothing lost: keep the **spec** alongside
the **resolved** value and re-resolve only when the spec is relative and the container changed. It
needs no observers, no script and no timers — a frame-loop toolkit gets it by comparing last
frame's container size — and it is assertable on a recording canvas because it is a pure decision
over two values. What does not generalize is the absence of collision handling: nui can omit it
only because a host clips for it.

### 4. Arrow / caret geometry

Not applicable — nui has no arrow, beak, tail or caret concept anywhere; a grep for those terms
returns nothing. The absence is itself the finding for a cell toolkit. In a grid whose smallest
unit is one character cell, an arrow degenerates to a single glyph on the border line, and nui's
border machinery already provides exactly that substrate without calling it an arrow:
`internal.char` is an 8-slot map of `NuiText` values (`border.lua:12` `index_name`), each replaceable
individually and each carrying its own highlight group, and the border line is composed as
`left ++ mid^leftgap ++ content ++ mid^rightgap ++ right`. Placing a `┬` or `▲` at a computed cell
offset on the top edge is a one-line change to the same generator that draws the title — that is,
arrow geometry on a grid is data (a char plus an offset), not paint code.

nui also demonstrates the second half of the problem: an arrow must feed the size delta, and
`calculate_size_delta` (`border.lua:282`) already models exactly that shape — one cell per
non-empty side. An arrow occupying a border cell would cost zero extra size; an arrow drawn
_outside_ the frame would need a delta of one.

**Algorithm.** None exists. The nearest generator is `calculate_buf_edge_line`:
`max_width := size.width - left:width() - right:width()`; content is `max_width` spaces when the mid
char has zero width, else the title; truncate to `max_width`; split the leftover into
`(lgap, rgap)` by alignment via `_.calculate_gap_width` (`utils/init.lua:264`), where `left` gives
`(0, gap)`, `center` gives `(floor(gap/2), ceil(gap/2))` and `right` gives `(gap, 0)`.

**Where it lives.** Nowhere. Were it to exist it would belong in `popup/border.lua` beside the title
generator.

**Degradation.** Everything an arrow needs here survives every degradation: one glyph at one integer
cell offset, chosen at build time, with no hover, no script, no timers and no sub-cell placement.
The only thing genuinely lost on a grid is pointing at a sub-cell position — an arrow can only
point at a column — so the rounding rule must belong to the placement algorithm rather than to the
paint step.

### 5. Trigger semantics

Not applicable — there are no triggers. An overlay exists because the application called
`Popup(opts)` and then `popup:mount()`. There is no hover, no focus trigger, no click, no
long-press, no context-menu gesture, no pointer-type distinction and no assistive-technology path.
Because there is exactly one trigger (an imperative call), the "multiple triggers racing" problem
does not arise here — but nui does hit the adjacent problem, host-provoked re-entrancy, and solves
it with a flag rather than a state machine: every lifecycle method opens with
`if self._.loading … return` and sets `_.loading = true` for its duration
(`popup/init.lua:207, 257, 273, 311`). That is how `mount` during `unmount`, or a `hide` fired from
the very `WinClosed` autocommand that `hide` itself provokes, is stopped from recursing.

**Algorithm.** None; `mount()` / `show()` / `hide()` / `unmount()` _are_ the API. The guard is:
enter, return early if `_.loading` or already in the target state; set `_.loading := true`; perform
host effects; clear `_.loading`; set `_.mounted`.

**Where it lives.** Application code. The library exposes `popup:map(mode, key, handler)`
(buffer-local keymaps, `popup/init.lua:336`) and `popup:on(event, handler)` (buffer-local
autocommands, `:358`) as the seams through which an application wires its own triggers.

**Degradation.** There is nothing to degrade — and that is the reason nui behaves identically on a
tty, over SSH and inside another terminal: by refusing to own triggers it never depended on hover,
key release or a pointer capability tier. The transferable rule for a toolkit that _does_ own
triggers is that the trigger tier should be an explicit input (tier-0 = programmatic only) rather
than a runtime discovery, since only an input is assertable.

### 6. Timing

Not applicable — the library contains no timers. A grep over `lua/` for `uv.new_timer`,
`vim.defer_fn` and `timer` returns zero hits, so there is no open delay, no [warm-up or
cool-down][concepts], no skip-delay, no singleton/group provider, no maximum display duration and
no neighbour traversal. The only asynchrony is `vim.schedule`, used for **correctness** rather than
policy, in four places: deferring `unmount` out of a `QuitPre` autocommand (`popup/init.lua:218`);
deferring `Input`'s caret patch and its `on_submit` / `on_close` callbacks until after the mode
change settles (`input/init.lua:149`); a scheduled window-focus dance working around
`neovim/neovim#18925` for nested float positions (`layout/init.lua:42`); and the deferred
`make_default_prepare_node` in `Menu` (commit `49182fa`). Each is "run after the host finishes the
current event" — a one-frame deferral, not a delay.

**Algorithm.** None. What the omission implies is a three-state lifecycle: `unmounted`,
`mounted+visible`, `mounted+hidden`, with `_.mounted` distinguishing "hidden but alive" (buffer
kept, window closed) from "destroyed" (buffer deleted). That distinction is what makes `hide`/`show`
cheap and content-preserving — `tests/nui/popup/init_spec.lua:1099` asserts buffer content survives
a hide/show round trip.

**Where it lives.** Nowhere as policy; the four `vim.schedule` calls are library code but are
event-ordering fixes.

**Degradation.** An overlay stack with no timers loses nothing on a static-HTML target (which has no
timers) and nothing on a recording canvas (every transition is a direct call and therefore
assertable). nui is a clean existence proof that hover-delay policy is _separable_ from the
geometry primitive: mount/show/hide/unmount are pure state transitions and any delay is the
caller's.

### 7. Interactive hover

Not applicable — no [safe polygon][concepts], no pointer bridge, no menu-aim, no tolerance region,
no trajectory heuristic, no debounce. The library has no pointer at all.

There _is_ a travel problem in nui's world, and it is solved structurally rather than
geometrically. With a complex border the popup is re-parented **inside** the border window —
`adjust_popup_win_config` (`border.lua:351`) rewrites `popup.win_config` to
`relative = "win", win = border.winid`, with `row`/`col` set to the inset, under the comment
`-- relative to the border window` at `:393`. "Moving from the frame to the content" is therefore a
containment relation, not a distance. The nested case is `Layout`: a container float at `zindex`
49 holds child popups positioned `relative = "win"` to it; each child's border is likewise
`relative = "win"` to the container, and the child's content is `relative = "win"` to its own
border. Verified at the pinned revision: a layout container at editor `(2,3)` sized 40x20; a child
border at win `(0,0)` sized 40x10; the child content at win `(1,1)` sized 38x8. That three-level
parenting chain is nui's entire answer to nesting, and `tests/nui/layout/init_spec.lua:43` pins it.

**Algorithm.** None. Cost of the containment approach in cells: zero — no region is computed, and a
point is inside the content iff it is inside the child window, which the host resolves. For
comparison, a whole-cell corridor between a trigger and an overlay would be at most three
axis-aligned integer rects (trigger, overlay, and the corridor between); nui's evidence is that the
corridor can instead be made _structural_ — make the gap part of a parent surface — after which it
costs nothing.

**Degradation.** On a target with one pointer and no key release, and on Android with no hover at
all, every hover-bridge algorithm is dead weight. The structural answer (nest the surfaces so the
gap belongs to a parent) is the one that survives all of the degradations, because containment is
decided by the same rect arithmetic that already produced the layout.

### 8. Dismissal

nui ships almost no dismissal policy, and says so by example: the README's canonical snippet
(`README.md:139`) is `popup:on(event.BufLeave, function() popup:unmount() end)`. "Close when focus
leaves" is three lines of user code, not a feature.

What the library does automatically is two defensive things. `QuitPre` on the popup's buffer
schedules `unmount` (`popup/init.lua:215`), so `:q` inside an overlay tears it down. `WinClosed` on
the popup's own window id calls `hide` (`popup/init.lua:222-243`) — registered from inside a
`BufWinEnter` handler, because that is when the window id becomes known. That second registration
carries a hazard the author documented in place: two popups sharing one buffer both receive
`BufWinEnter` when either is shown, so the handler guards on `self.winid`, and a `@todo` admits
duplicate `WinClosed` registrations are not de-duplicated. `Layout` adds `BufWipeout`/`QuitPre` on
any child to unmount the whole layout (`layout/init.lua:95`) and `WinClosed` on a child to hide it
(`:117`), with `nested = true` (commit `fc59553`) so the cascade of child closes actually fires.
`Menu` is the only component with a key-driven close: `close = {"<Esc>", "<C-c>"}`
(`menu/init.lua:28`), bound buffer-locally with `nowait`.

There is no click-outside, no pointer-down/up identity test, no application-deactivation cause, no
scroll-dismiss, no anchor-hidden or anchor-removed detection, and no Escape handling in `Popup`
itself. "Close on any outside interaction" in a modal editor is answered by the editor's own
modality: leaving the overlay means leaving its buffer, which raises `BufLeave`, and the
application closes on that.

**Algorithm.** `mount()`: create the augroups `hide` and `unmount`; `autocmd QuitPre buffer=bufnr →
schedule(unmount)`; `autocmd BufWinEnter buffer=bufnr → if self.winid then autocmd WinClosed
pattern=tostring(winid) nested → hide()`. `hide()`: delete the `hide` augroup first — so the
`WinClosed` it is about to cause cannot re-enter — then close the border window and the popup
window. `unmount()`: delete both augroups, unmount the border, destroy the buffer, close the window.

**Where it lives.** Library code registers the two lifecycle autocommands; **policy** lives in
application code via `popup:on`. The event source is the host's autocommand system.

**Degradation.** The decomposition survives everything, because it reduces dismissal to "a set of
named reasons the surface owner can raise" rather than "pointer events outside a native
[grab][concepts]". Note what nui gets for free that a single-surface toolkit does not: focus-leave
is delivered by the host. With no OS window and no pointer grab, an in-canvas toolkit must
synthesize the equivalent causes itself — pointer-down outside the overlay's rect in the
last-painted frame, focus moved outside, anchor scrolled off the surface, a platform back key — and
must raise them at explicit points in the frame loop so that a recording canvas can assert them.

### 9. Focus

Focus is two booleans. `enter` (default `false`, `popup/init.lua:35`) decides whether
`nvim_open_win` moves the cursor into the overlay. `focusable` has no nui default at all —
`popup/init.lua:120` passes `options.focusable` straight through, so `nil` reaches Neovim's own
default — and, when false, keeps the window out of window-command and mouse focus cycling. The
border window is **always** `focusable = false` (`border.lua:488`), which is the correct instinct:
decoration must never be a tab stop. The `Layout` container float is likewise `focusable = false`
with `winblend = 100` and `border = "none"` (`layout/init.lua:196-203`) — a pure coordinate space,
deliberately invisible and unfocusable.

There is no [focus scope][concepts], no trap, no tab order, no nested scopes and no restoration —
with one instructive exception. `Input` restores the **caret**, not the focus, and does so as an
explicit correction for a modal-editor artifact: leaving insert mode moves the cursor one column
left, so `patch_cursor_position` (`input/init.lua:12`) nudges it back, reading the target from
`internal.container_info.winid` _before_ unmounting and applying it inside a `vim.schedule`. The
tooltip / popover / menu / dialog distinction is not modelled: `Menu` differs from `Popup` only by
`enter = true`, `cursorline = true`, `zindex = 60` and four keymaps (`menu/init.lua:256-268`).

**Algorithm.** `Popup`: `winid := nvim_open_win(bufnr, _.win_enter, win_config)` — `enter` is a
constructor argument, not a post-hoc focus call. `Input`: on `BufWinEnter`, schedule
`nvim_set_current_win(self.winid)` and `startinsert!`; on unmount, capture the target cursor and
mode from the container window, then schedule `stopinsert`, `patch_cursor_position`, and the
`on_submit`/`on_close` callback.

**Where it lives.** Library code for the two flags and the caret patch; the host owns focus itself
and the entire modal-mode concept.

**Degradation.** `focusable` as a per-surface boolean, and "decoration is never focusable", both
survive with no OS window and no key release, because they are properties of a derived hit/focus
list evaluated at build time. What does not survive is the reliance on the host to define "focus
left": a single-surface toolkit must own a focus cursor over its own widget tree, and the
tooltip-versus-popover-versus-menu-versus-dialog distinction that nui never makes has to be
reintroduced as differing focus _policies_ over one geometry primitive.

### 10. Layering & portals

Layering is a single integer `zindex` handed to the host: `Popup` defaults to 50
(`popup/init.lua:36`), `Menu` to 60 (`menu/init.lua:267`, changed in `abb0662` precisely so a menu
sits above a popup), and the `Layout` container to 49 (`layout/init.lua:199`) so it is always
beneath its children.

The interesting change is commit `a2bc1e9`: the border window now takes
`zindex = self.popup.win_config.zindex` — the **same** value as the popup, not one less. With equal
`zindex` Neovim orders by creation, and nui creates the border first (`self.border:mount()` before
`self:_open_window()`, `popup/init.lua:245-251`), i.e. "later opened is in front". That is a
display-list order rule expressed through a window manager.

There is no portal, no [top layer][concepts], no root overlay container and no stacking context:
every overlay is a sibling float in one flat compositor space, and nesting is achieved by relative
parenting (the child is `relative = "win"` to the container's window id) rather than by an overlay
tree. The public surface is `zindex` plus `popup.winid` / `popup.bufnr` / `popup.border.winid` /
`popup.border.bufnr`; the border's second window and buffer, the `win_config` table, the
re-parenting and `_.size_delta` are all marked private (`---@field private _`) yet are read by
`layout/float.lua` and by the test suite, so the private/public line is porous exactly where the
geometry contract lives. A `Layout` child must already be a `Popup` or `Split` instance —
`Layout.Box` errors with `unsupported component` otherwise (`layout/init.lua:518`) — so ownership
is by reference, and `process_box_change` (`float.lua:208`) diffs the previous and current box
trees by component id to mount/show/hide the delta.

**Algorithm.** Layering order is `(zindex, creation order)`. Nesting:
`child.win_config.relative := "win"`, `child.win_config.win := parent.winid`, and the child's
`row`/`col` become offsets within the parent. `process_box_change(curr, prev)`: collect
`id → component` for both; for ids in `curr \ prev` call `show()` or `mount()`; for ids in
`prev \ curr` call `hide()`.

**Where it lives.** Library code chooses the integers and the parenting; the host resolves overlap,
clipping and equal-`zindex` ties.

**Degradation.** With no top layer and no compositor, the `zindex` integer collapses into a position
in the display list, and nui's own equal-`zindex`-plus-creation-order rule _is_ that same rule, so
the model transfers directly — replace the integer with a stable sort key over the derived overlay
list, where the ordering guarantee becomes explicit rather than resting on a host tie-break. The
parenting trick (child coordinates relative to the parent's rect) also transfers and is cheaper than
a portal: an overlay is a rect plus a parent id, resolved by one accumulation walk.

> [!NOTE]
> Neovim's tie-break rule for equal-`zindex` floats was not verified against Neovim's source in
> this read. "Later-created wins" is an inference from nui's border-then-content ordering plus the
> stated intent of commit `a2bc1e9`; the sibling deep-dive [`./neovim-floats.md`](./neovim-floats.md)
> is the place to check it.

### 11. Modality

nui models no [modality][concepts]: no modal flag, no [light dismiss][concepts], no scrim, no
background blocking, no accessibility modal bit. It does not need one, and the reason is the
sharpest cross-target lesson in this subject: in a modal editor, modality already exists at the
host level. Keys go to the focused buffer, and nui's keymaps are **buffer-local**
(`nvim_buf_set_keymap`, `utils/keymap.lua:112`), so a `Menu`'s `j` / `k` / `<CR>` / `<Esc>` bindings
exist only while the menu's buffer is current. That is the equivalent of a keyboard grab, achieved
with no grab machinery and no cleanup risk — the bindings die with the buffer.

Pointer blocking is approximated only by `focusable = false`, which prevents mouse focus for that
window but intercepts nothing. Click-through is not expressible except via the `Layout` container's
`winblend = 100` (visually transparent, still a window). There is no notion of a background surface
being inert.

**Algorithm.** None; modality is emergent — (focused buffer) x (buffer-local keymaps) yields a
keyboard-modal surface. `Menu:mount` binds `focus_next` / `focus_prev` / `close` / `submit` with
`{noremap = true, nowait = true}` on `self.bufnr` (`menu/init.lua:331-345`); `nowait` matters
because it stops the host waiting for a longer mapping that starts with the same key.

**Where it lives.** The host (focus plus buffer-local mapping resolution). The library only chooses
which keys to bind and to which buffer.

**Degradation.** Buffer-local keymaps map onto per-surface key handlers scoped to the focused
overlay, and that survives every degradation including no key release (bindings fire on press) and
no pointer grab (keyboard modality never needed one). What does not transfer is relying on the host
for _pointer_ modality: with no grab, a single-surface toolkit must decide inertness itself, which
in a reverse-paint-order hit list means "a modal overlay's rect swallows hits, and hits outside it
are consumed as a dismissal cause rather than delivered".

### 12. Adaptive presentation

Not applicable in the form factor sense: there is no compact/regular idiom, no touch fallback, no
teaching tip and no keyboard-driven relocation. There is exactly one capability decision in the
library and it concerns the **substrate**, not the form factor. `_.get_default_winborder()`
(`utils/init.lua:373`, commit `118a12f`) returns `"none"` on Neovim below 0.11 and otherwise reads
the host's `winborder` option; `Border:set_style` (`border.lua:677`) maps the literal style name
`"default"` through it and then upgrades `"none"` to `"single"` when the border is complex, because
a complex border with no characters is meaningless.

A parallel capability split exists for the API surface: `_.feature.lua_keymap` / `lua_autocmd` /
`v0_10` / `v0_11` select between `nvim_buf_set_keymap` callbacks and a `<cmd>lua …<CR>` string
trampoline with a per-buffer handler registry (`utils/keymap.lua:51`), and between
`nvim_create_autocmd` and generated `:autocmd` strings (`utils/autocmd.lua:314`). Those detections
are computed **once at module load** into a plain table (`utils/init.lua:7`), not per call.

**Algorithm.** `get_default_winborder()`: if the host is below 0.11 return `"none"`; else read
`winborder` and return `"none"` when it is empty. `set_style("default")`: resolve through that; if
the result is `"none"` and the border type is complex, upgrade to `"single"`.

**Where it lives.** Library code, with the decision at the component layer. Worth noting: nui defers
the default _look_ to the user's editor setting rather than inventing one.

**Degradation.** The pattern that transfers is "resolve capability once, into a value, at
construction" rather than "probe at paint time". A toolkit's equivalent inputs — no hover on a
touch target, no script in static HTML, a soft-keyboard inset — should be constructor inputs of the
same shape, because that is the form a recording canvas can assert.

### 13. Accessibility

Not applicable as a layer: there is none, and a grep for `accessib`, `aria` or `role` across `lua/`
returns nothing. Neovim exposes no accessibility tree, so the honest answer for a terminal grid is
that the only semantics reaching an assistive technology are the characters actually written into
the grid and the highlight groups attached to them.

nui takes that seriously in one respect: it names its highlight groups after the platform's own
float semantics. Border characters default to `FloatBorder` (`normalize_char_map`,
`border.lua:49`) and border title text to `FloatTitle` (`normalize_border_text`, `:77`), so a
screen-scraping or theming consumer sees "this run is a frame" and "this run is a title" rather
than anonymous glyphs. Per-character and per-title-chunk overrides are supported — `(char, hl)`
tuples, `NuiText` and `NuiLine` — which is genuinely a semantic channel: a line of
`Text("a", "NuiTestA")`, `Text("-")`, `Text("b", "NuiTestB")` renders three separately marked runs
on the border line (`tests/nui/popup/border_spec.lua:548`). Nothing marks an overlay as a dialog, a
menu as a listbox, or a title as a label; a `Menu`'s "selection" is the cursor line plus
`cursorline`, a visual convention only.

**Algorithm.** `normalize_char_map(char)`: for each of the 8 slots, a string becomes
`Text(s, "FloatBorder")`; a `{char, hl}` tuple becomes `Text(char, hl or "FloatBorder")`; an
existing `NuiText` has its `extmark.hl_group` defaulted to `FloatBorder`.
`normalize_border_text(text)`: a string becomes `Text(s, "FloatTitle")`; a `NuiText`/`NuiLine` has
each chunk's extmark deep-extended with `hl_group = "FloatTitle"` under a **keep** merge, so an
existing group wins.

**Where it lives.** Library code for the naming; the host renders. There is no assistive-technology
API anywhere in the stack.

**Degradation.** This is the floor for a cell target generally: what a grid can honestly expose is
the text, its position, and a semantic style slot. The transferable rule is that the semantic slot
must be assigned at **normalization** time — one place, one documented default, a keep-not-force
merge — rather than at paint time, so the same tree can be re-emitted to a channel that does have
semantics. On this evidence the geometry primitive owns the rect, the frame slot, the title slot
and their runs; role, selection state and the label/description distinction belong to a semantic
component, and nui is not the poorer as a geometry primitive for modelling none of them.

### 14. Animation

Not applicable: no transitions, no enter/exit, no reduced-motion handling, no timers to drive any
of it. Reposition is a single synchronous `nvim_win_set_config` followed by `nvim_command("redraw")`
(`border.lua:604-626`, `popup/init.lua:394-401`). The one interesting detail there is a workaround,
not an animation: `update_layout` temporarily blanks `win_config.style` before calling
`nvim_win_set_config` and restores it afterwards, citing `neovim/neovim#20370`, because passing
`style = "minimal"` to `set_config` re-applies option defaults.

On whether geometry metadata is emitted for a styling layer: nui does keep a complete, readable
geometry record — `popup._.position` (resolved row/col plus `relative`, `win` and `bufpos`),
`popup._.size`, `popup._.container_info`, `border._.size_delta`, `border._.position`,
`border._.size` — but it is marked private, it exists for the layout engine, and no side or
alignment token is ever derived, because placement has no sides to name. Rich geometry data, none of
it shaped for animation or for a [transform origin][concepts].

**Algorithm.** None. Reposition: recompute `internal.size` and `internal.position`; write
`win_config.{width, height, row, col}`; if a window exists call `nvim_win_set_config`; re-render the
border lines; re-run `adjust_popup_win_config`; redraw.

**Where it lives.** Repositioning is library code; painting is the host's.

**Degradation.** Nothing is lost, because nothing exists. The lesson is negative and precise: if
placement never names a side, the styling layer has no transform origin to receive. A toolkit that
wants animation must emit the chosen side and alignment as data from the placement step — which is
an argument for placement returning a decision record rather than only a rect.

### 15. State architecture

Classic mutable OO. A vendored middleclass (`lua/nui/object/init.lua`, whose first line records
`-- source: https://github.com/kikito/middleclass`) gives `Popup:extend("NuiMenu")` with `super`,
and every instance carries one private mutable table `self._` holding the id, the layout spec, the
resolved position and size, `container_info`, `win_config`, augroup names, and two lifecycle
booleans. There is no reducer, no finite-state-machine runtime, no event bus and no
controlled/uncontrolled distinction; state changes are direct field writes, and `self.win_config` is
deliberately an **alias** of `self._.win_config` (`popup/init.lua:131`), so the object is a live
handle onto the config it will hand to the host.

The lifecycle is a hand-rolled three-state machine implemented as two booleans: `_.mounted` (buffer
alive) and `_.loading` (a transition in flight, guarding re-entrancy from autocommands the
transition itself provokes), yielding `unmounted`, `mounted+visible` and `mounted+hidden`. The
border is a child object holding a back-reference to its popup (`self.popup = popup`,
`border.lua:458`) and it **mutates** the popup's `win_config` from `adjust_popup_win_config` — a
bidirectional coupling that is the main obstacle to a value-semantics port.

**Algorithm.** State is `{mounted: bool, loading: bool}`. Every transition:
`if _.loading or <already in target state> then return end; _.loading := true; <host effects>;
_.loading := false; _.mounted := target`. `show()` upgrades to `mount()` when not mounted (commit
`ecd77d8`), so `show` is idempotent and total. `Layout` mirrors the same pattern at the tree level,
recursing over the box.

**Where it lives.** Library code: `object/init.lua` (class system), `popup/init.lua` (flags and
transitions), `layout/init.lua` (the tree-level mirror).

**Degradation.** The two-boolean guard is a workaround for _host-provoked_ re-entrancy — the
`WinClosed` fired by the very close that `hide()` performs. A toolkit that owns its surface has no
such re-entrancy and can drop the latch entirely, which is the point: this state machine is smaller
than it looks, and the part with real content is the `visible` / `hidden-but-alive` / `destroyed`
distinction, mapping to "in the overlay list / retained but not emitted / dropped". What would
survive a value-semantics port: the geometry vocabulary and all of `layout/utils.lua` (pure
functions over plain records), the size/position spec records, the 8-slot border char map and
`size_delta`. What would not: the popup/border back-reference, the `win_config` alias, the
augroup-name strings used as host handles, and the imperative mount/hide/show/unmount methods, which
would be re-expressed as a rebuild of the overlay list each frame.

### 16. Shared infrastructure

Factoring is by inheritance plus one shared free function. `Popup` is the base; `Menu` and `Input`
are `Popup:extend(...)` and add only what is theirs. `Menu` adds an intrinsic-size computation (the
widest item's display width clamped by `min_width`/`max_width`, the item count clamped by
`min_height`/`max_height`, `menu/init.lua:250-253`), a `NuiTree` render, four keymaps, and
separator/skip logic. `Input` forces `size.height = 1`, sets `buftype = "prompt"`, adds prompt
callbacks and the caret patch. Neither overrides geometry.

The genuinely shared piece is `layout_utils.update_layout_config(internal, config)` — one function
owning the whole spec-to-resolved pipeline, called by both `Popup` (`popup/init.lua:388`) and
`Layout` (`layout/init.lua:438`) against differently-shaped `internal` tables. Against that,
`split/utils.lua` is a deliberately **separate** twin: splits have a different vocabulary (position
is a side, size is one dimension) and a different container, whose editor height is corrected for
`cmdheight`, `laststatus` and `showtabline` (`split/utils.lua:82-89`). That refusal to unify is the
important judgement call — the author kept two placement models rather than producing a union type
with half the fields meaningless in each case.

On this subject's evidence, what belongs in one primitive is: the relative/position/size
normalization, percentage resolution, the container-changed reflow trigger, the 8-slot border char
map with its size delta, and the edge-line/title generator. What merely looks common and stayed
apart: intrinsic sizing (menu-specific), selection and keymaps (menu-specific), the prompt lifecycle
and caret restoration (input-specific), and the split geometry vocabulary. A wart on the other side:
`border._.size_delta` is reached into from `layout/float.lua:58,63`, so the border's private field
is de facto part of the layout engine's contract.

**Algorithm.** `Popup:update_layout(config)` calls `update_layout_config(self._, config)`, then
`border:_relayout()`, then `nvim_win_set_config` when a window exists. `Layout:update(config)` calls
`update_layout_config(self._.float, config)`, then `_process_layout()`, then
`float_layout.process(box)`, which for each leaf child calls
`component:set_layout({size = inner, relative = {type = "win", winid = container}, position = …})` —
re-entering `Popup:update_layout`. The layout engine drives components through the same public entry
point an application would use.

**Where it lives.** Library code: `layout/utils.lua` (the shared engine), `popup/init.lua` (base
class), `menu/init.lua` and `input/init.lua` (thin subclasses), `split/utils.lua` (the deliberate
non-sharing).

**Degradation.** The reusable core is one function over plain records plus one border generator, and
it survives every degradation because it touches nothing but integers and text. The composition rule
is the transferable part: the layout engine talks to children through the same declarative spec an
application uses, so there is one code path and one place where percentages, deltas and clamps are
applied.

## Strengths

- A deliberate cell-geometry vocabulary — `{relative, position, size, anchor}` where every scalar
  accepts cells, a percentage string, a decimal fraction, or a per-axis table — normalized in one
  function (`update_layout_config`) that both the component and the layout engine call.
- The percentage-dependency reflow trigger: store the spec beside the resolved value and re-resolve
  only when the spec is relative **and** the container size actually changed. An observer-free,
  timer-free invalidation rule that maps cleanly onto a frame loop.
- A reusable border decomposition: an 8-slot char map (corners plus edges) with per-slot highlight,
  a per-side thickness derived as `(char non-empty ? 1 : 0) + padding`, and a title generator that
  shares one alignment helper with the menu separator. Erasing a side is a layout operation, not
  only a paint one.
- Display-width-correct text handling: `NuiText` caches both byte length and `nvim_strwidth` cells
  (`text/init.lua:27`); truncation binary-searches on display width and appends an ellipsis
  (`utils/init.lua:207-258`); the menu clamps intrinsic width by the widest item's cell width.
  Verified CJK-correct — `max_width = 11` produced `中文长度测…`, eleven cells.
- Corner and edge fallback chains (empty corner to horizontal edge char to vertical side char) keep
  partial frames coherent, and the test suite pins all eight single-empty-slot cases as literal
  expected grids (`tests/nui/popup/border_spec.lua:963-1030`).
- Cheap declarative defaults: a 1- or 2-element border list expands by modular repetition into the
  full 8 slots, so "one char everywhere" and "corners versus edges" are free without a special case.
- Refuses scope creep in the places where a geometry primitive should: no timers, no pointer, no
  dismissal policy, no animation — which is exactly why the geometry core is small enough to lift
  out whole.
- A clean three-state lifecycle where `hide` preserves the buffer, `show` upgrades to `mount` when
  needed, and one re-entrancy latch survives host-provoked recursion.
- Tests assert literal cell grids (`"╭──top───╮"`) rather than internal fields — the assertion style
  a recording canvas enables, and the only style that catches border arithmetic errors.

## Weaknesses

- The border box model centres the frame on the content rect (`position -= round(delta/2)`) instead
  of offsetting by the actual top/left thickness, so any asymmetric border or padding silently
  **displaces** the content. Verified: `padding = {top = 4, bottom = 0}` moves it two rows down,
  `{top = 0, bottom = 4}` two rows up, and an empty `top` char at position 0 puts the border window
  at row -1, col -1.
- The same centring makes `anchor` wrong for every corner but `NW` when a complex border is used.
  With `anchor = "SE"` at `(20,60)`, the border window is anchored `SE` at `(19,59)` with the
  content inset `(1,1)` inside it. INFERENCE: from those window configs the content's `SE` corner
  lands two cells off; the painted cells were not observed, so the visual offset is derived from the
  configs plus the arithmetic rather than from a screenshot. The `anchor` tests only assert that the
  field was copied, never the resulting geometry.
- Three different footprints for the same declarative input: a standalone simple border is
  content-box with the frame drawn outside the rect (verified — a popup at row 15 with a rounded
  border stays at row 15); a standalone complex border expands outward, centred; inside a `Layout` a
  complex-bordered child gets border-box treatment while a simple-bordered child sits at the box
  origin with its native border spilling one cell above and left of the box.
- No clamping anywhere. `position = "200%"` gives row 60 in a 40-line editor; `size = "200%"` gives
  a 200x80 window in a 100x40 editor; negative positions pass through. There is no minimum size
  either — a zero-size popup with a complex border fails inside `nvim_open_win` with
  `'width' key must be a positive Integer`.
- The one degenerate-size guard (`layout/float.lua:61-66`) covers **height** only, and repairs it by
  growing the **outer** box — which overflows the container and pushes the next sibling outside it
  (verified: a 3-row container with a child of size 1 positions the sibling at row 3). A too-narrow
  box instead crashes in `_.truncate_nui_line` with
  `attempt to index local 'last_part' (a nil value)` (`utils/init.lua:243`), because a negative
  `max_width` walks off the front of the run list.
- Cell arithmetic conflates character count with display width in the border fill: gaps are measured
  in cells but filled with `string.rep(char, gap)` (`border.lua:202`), so a double-width border char
  doubles the edge line. Verified: a border whose `bottom` char is a double-width block produced a
  bottom line of display width 14 inside an 8-cell-wide frame. `calculate_size_delta` likewise
  charges one cell per side regardless of the char's real width.
- The percentage-dependency tracker tests `type(v) == "string"`, so a decimal fraction — which the
  parser does treat as a percentage — is not recognized as container-dependent and will not reflow
  on a resize.
- `position` percentage semantics (a fraction of free space, so `"50%"` centres) are undocumented;
  the README says only that position is calculated from the top-left corner. Documentation and
  source disagree by omission on the most-used option in the library.
- Bidirectional coupling between `Popup` and `Border`: the border holds a back-reference and mutates
  `popup.win_config` (`anchor`, `relative`, `win`, `row`, `col`) from `adjust_popup_win_config`, and
  `self.win_config` is a live alias of `self._.win_config`. Nothing here is a value.
- `border._.size_delta` is declared private yet read by `layout/float.lua` and by the tests — the
  private/public boundary is porous exactly where the geometry contract lives.
- No accessibility surface of any kind, and no role distinction between popup, menu, listbox and
  dialog — a `Menu` is a `Popup` with `cursorline` and four keymaps.
- The layout test helper compares row against `size_delta.width` and col against `size_delta.height`
  (`tests/nui/layout/init_spec.lua:59-60`) — the axes are swapped. It passes only because both
  deltas are usually equal, so the assertion is not testing what it claims.

> [!IMPORTANT]
> Several of nui's omissions are **host-subsidised**, not simplifications available to any toolkit.
> It can skip collision, clamping, constraint adjustment and dismissal only because Neovim clips its
> floats, delivers `BufLeave`, and owns modality. An in-canvas toolkit that paints into one surface
> with no host must own the fit step, the clamp, and an explicit set of named dismissal causes.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                                        | Rationale                                                                                                                                                                                                                                                                                                                                              | Trade-off                                                                                                                                                                                                                                                                                                                                                                                 |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Geometry is a declarative spec normalized once into a plain record, and every consumer — application, `Popup`, `Menu`, `Input` and the `Layout` engine — goes through the same entry point (`update_layout_config`).            | There is exactly one place where `relative`/`position`/`size` become numbers, so percentage semantics, the reflow trigger and the error messages exist once. The layout engine drives children by calling their public `set_layout`, not by poking internals, so a component behaves identically whether an application or a layout positions it.      | The record is untyped and overloaded — one scalar means cells or a fraction depending on magnitude — so the predicate deciding whether to re-resolve on a container change tests `type(v) == "string"` and silently misses decimal fractions. A sum type over the scalar would have made the same design airtight.                                                                        |
| Split the border into a "simple" mode delegated to the host and a "complex" mode implemented as a second, unfocusable window whose buffer nui paints itself, chosen automatically by whether `text` or `padding` was requested. | The host's native border cannot express padding or per-side titles. Rather than reimplement borders always, nui pays for the extra window only when the extra capability is asked for, and the mode is derived rather than configured (`border.lua:469-473`).                                                                                          | The two modes use different box models and the difference leaks: three different footprints for the same declarative input (standalone simple, standalone complex, and inside a `Layout`).                                                                                                                                                                                                |
| Own no dismissal policy. Register only two defensive autocommands (`QuitPre → unmount`, `WinClosed → hide`) and document `popup:on(event.BufLeave, …)` as the way to close.                                                     | In a modal editor the host already delivers a precise, cheap "the user went elsewhere" signal, and different applications want different policies — a menu closes on Escape, a preview closes on cursor move, a persistent panel never closes. Hard-coding one would be wrong for most callers.                                                        | Every consumer reimplements dismissal, inconsistently; there is no click-outside, no anchor-hidden and no anchor-removed handling at all; and the one automatic path carries its own bug comment — two popups sharing a buffer both receive `BufWinEnter`, so the `WinClosed` registration is guarded on `self.winid` and a `@todo` admits duplicate registrations are not de-duplicated. |
| Never resolve the cursor or buffer anchor: store the symbolic token and let the host convert it at open time, late-binding even the window (`winid 0` = whatever is current).                                                   | The host already knows scroll offsets, wrapped lines, virtual text and folds; recomputing that in the library would be duplicative and wrong the moment any of them changes. Commit `3dc46d7` deliberately made the cursor case late-bound rather than captured.                                                                                       | nui cannot reason about where the overlay will actually land, which forecloses every collision behavior — no flip, no shift, no fit check — and makes `relative = "cursor"` non-deterministic with respect to which window is current when layout runs. A toolkit that owns its surface cannot make this trade: it has no host to defer to.                                               |
| Layering is a single integer plus creation order, with the border window sharing the popup's `zindex` rather than sitting one below it (commit `a2bc1e9`).                                                                      | Equal-`zindex` ties are broken by creation order, and nui always creates the border before the content, so the content is reliably in front without burning a z-level. A caller who bumps a popup's `zindex` also moves its frame, which the previous scheme (border at `zindex - 1`) did not guarantee against a neighbour at the intermediate value. | Correctness then depends on a host tie-break rule that nui does not document and this read did not verify against Neovim's source. Expressed as a display list the same guarantee is explicit and free: emit the frame, then the content.                                                                                                                                                 |
| Refuse to unify float geometry with split geometry, keeping `layout/utils.lua` and `split/utils.lua` as parallel twins.                                                                                                         | Splits have a different vocabulary (position is a side, size is one dimension) and a different container — the editor height must be corrected for `cmdheight`, `laststatus` and `showtabline`. Forcing them behind one abstraction would produce a union type with half the fields meaningless in each case.                                          | `normalize_dimension`, the relative parsing and the container lookup are duplicated in shape and can drift — they already differ, since the split path corrects the editor container size and the float path does not. The reading this supports is that the genuinely shared thing was the **scalar resolution**, not the placement model.                                               |

## Sources

Primary sources, all read at `de740991c12411b663994b2860f1a4fd0937c130`:

- [`lua/nui/layout/utils.lua`][layout-utils] — `parse_relative` (`:103`), `get_container_info`
  (`:79`), `calculate_window_position` (`:30`, free-space percentage at `:41`),
  `calculate_window_size` (`:64`), `update_layout_config` (`:125`), `contains_percentage_string`
  (`:216`, `:222`).
- [`lua/nui/popup/border.lua`][border] — `to_border_map` (`:25`, modular expansion at `:30-31`),
  `normalize_char_map` (`:49`), `normalize_border_text` (`:77`), `calculate_buf_edge_line` (`:169`,
  corner fallback `:176-178`, gap fill `:202`), `calculate_size_delta` (`:282`), `calculate_position`
  (`:344`, the centring at `:346-347`), `adjust_popup_win_config` (`:351`), `focusable`/`zindex`
  (`:488-489`), `set_style` (`:677`).
- [`lua/nui/popup/init.lua`][popup] — defaults (`:35-36`), `win_config` alias (`:131`), `mount`
  (`:202`), the `_.loading` guard (`:207`), the two lifecycle autocommands (`:215`, `:222-243`),
  border-before-content ordering (`:245-251`), `hide`/`show` (`:257`, `:273`), `map`/`on` (`:336`,
  `:358`), `update_layout` (`:388-401`).
- [`lua/nui/layout/float.lua`][float] — `get_child_size` (`:35`, the height-only repair at `:61-66`),
  `process` (`:72`), child `set_layout` (`:102`), the grow pass (`:128`), `process_box_change`
  (`:208`).
- [`lua/nui/layout/init.lua`][layout] — the `vim.schedule` workaround for `neovim/neovim#18925`
  (`:42`), `BufWipeout`/`QuitPre` (`:95`), `WinClosed nested` (`:117`), the invisible container
  (`:196-203`), `Layout:update` (`:438`), `unsupported component` (`:518`).
- [`lua/nui/utils/init.lua`][utils] — the load-time feature table (`:7`), `parse_number_input`
  (`:58`), `normalize_dimension` (`:188`), truncation (`:207-258`), `calculate_gap_width` (`:264`),
  `get_default_winborder` (`:373`).
- [`lua/nui/menu/init.lua`][menu] — `default_keymap.close` (`:28`), `default_should_skip_item`
  (`:52`), `make_default_prepare_node` (`:58`), `focus_item` (`:150`), `Popup:extend` (`:209`),
  intrinsic size (`:250-253`), popup defaults (`:256-268`), keymaps (`:331-345`).
- [`lua/nui/input/init.lua`][input] — `patch_cursor_position` (`:12`), `unmount` capture-then-schedule
  (`:134-158`).
- [`lua/nui/utils/keymap.lua`][keymap] — the `lua_keymap` vs `<cmd>lua` trampoline (`:51`),
  `keymap.set` (`:83`), `nvim_buf_set_keymap` (`:112`).
- [`lua/nui/utils/autocmd.lua`][autocmd] — the dual `nvim_create_autocmd` / `:autocmd` path (`:314`).
- [`lua/nui/split/utils.lua`][split-utils] — the deliberately separate split twin (`:123`) and its
  container correction for `cmdheight`/`laststatus`/`showtabline` (`:82-89`).
- [`lua/nui/object/init.lua`][object] — the vendored middleclass attribution (`:1`).
- [`lua/nui/text/init.lua`][text] — `Text:set` caching byte length and `nvim_strwidth` (`:27`).
- Tests: [`tests/nui/popup/init_spec.lua`][popup-spec] (`:840` reflow, `:869` free-space assertion,
  `:1073` shared buffer, `:1099` content survives hide/show, `:1150` `show` mounts),
  [`tests/nui/popup/border_spec.lua`][border-spec] (`:548` per-run title highlights, `:618` winblend
  inheritance, `:841` title before `Layout` mount, `:963-1030` the empty-char grids),
  [`tests/nui/layout/init_spec.lua`][layout-spec] (`:43` the parenting chain, `:59-60` the
  axes-swapped helper), [`tests/nui/layout/utils_spec.lua`][layout-utils-spec] (`:13` `type=buf`).
- [`README.md`][readme] — the `event.BufLeave` dismissal recipe (`:139`).

Related pages in this catalog: [`./index.md`](./index.md), [`./concepts.md`](./concepts.md),
[`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md), [`./proposal.md`](./proposal.md). Nearest
siblings: [`./neovim-floats.md`](./neovim-floats.md) (the host nui delegates to),
[`./nvim-completion.md`](./nvim-completion.md), [`./textual.md`](./textual.md),
[`./notcurses.md`](./notcurses.md), [`./turbo-vision.md`](./turbo-vision.md),
[`./ratatui.md`](./ratatui.md), [`./tmux-popup.md`](./tmux-popup.md),
[`./emacs-posframe.md`](./emacs-posframe.md), [`./helix.md`](./helix.md). Sibling research trees:
[`../ui-layout/index.md`](../ui-layout/index.md),
[`../window-system-integration/index.md`](../window-system-integration/index.md),
[`../platform-ui-guidelines/index.md`](../platform-ui-guidelines/index.md),
[`../sean-parent/index.md`](../sean-parent/index.md). Toolkit specs:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md),
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md).

<!-- References -->

[repo]: https://github.com/MunifTanjim/nui.nvim/tree/de740991c12411b663994b2860f1a4fd0937c130
[concepts]: ./concepts.md
[layout-utils]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/layout/utils.lua#L30
[border]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/popup/border.lua#L344
[popup]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/popup/init.lua#L202
[float]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/layout/float.lua#L72
[layout]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/layout/init.lua#L196
[utils]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/utils/init.lua#L58
[menu]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/menu/init.lua#L250
[input]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/input/init.lua#L12
[keymap]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/utils/keymap.lua#L112
[autocmd]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/utils/autocmd.lua#L314
[split-utils]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/split/utils.lua#L82
[object]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/object/init.lua#L1
[text]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/lua/nui/text/init.lua#L27
[popup-spec]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/tests/nui/popup/init_spec.lua#L840
[border-spec]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/tests/nui/popup/border_spec.lua#L963
[layout-spec]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/tests/nui/layout/init_spec.lua#L43
[layout-utils-spec]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/tests/nui/layout/utils_spec.lua#L13
[readme]: https://github.com/MunifTanjim/nui.nvim/blob/de740991c12411b663994b2860f1a4fd0937c130/README.md#L139
