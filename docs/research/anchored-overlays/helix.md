# Helix (Rust / terminal editor)

Helix places every anchored overlay with one ~60-line integer-cell function that
re-runs from scratch on every frame, stacks them in a flat `Vec` of full-screen
self-clipping painters, and resolves the one real multi-surface conflict by
testing predicted rectangles and destroying the loser.

| Field         | Value                                                                                                               |
| ------------- | ------------------------------------------------------------------------------------------------------------------- |
| Language      | Rust                                                                                                                |
| License       | MPL-2.0                                                                                                             |
| Repository    | [`helix-editor/helix`][helix-repo]                                                                                  |
| Documentation | [docs.helix-editor.com][helix-docs] (user manual; the overlay machinery is undocumented and was read from source)   |
| Category      | Terminal / cell grid                                                                                                |
| Surface model | in-canvas — one `helix-tui` cell `Buffer`, no OS popup, no compositor surface, no [top layer][concepts], no z-index |
| Revision read | `14d6bc0febed9c692048271a8ae2362ac969c6e0` (release 25.7.1)                                                         |

> [!NOTE]
> Every claim below is read from source at the pinned revision. Helix was not run,
> and the repository contains no tests for popup placement, menu sizing, or the
> completion/signature-help collision logic — the only geometry tests are `Rect`'s
> own clip/area tests ([`helix-view/src/graphics.rs:775`][graphics-tests]). Edge
> cases named here were derived by reading the arithmetic, not by executing it.

## Overview

### What it solves

Helix is a modal terminal editor whose LSP surfaces — completion menu, completion
documentation, signature help, hover, code actions, DAP variables, `:sh` output,
and an invalid-regex toast — all need to appear next to the text cursor without
covering the line being edited. It solves that with a single generic shell,
`Popup<T>` ([`helix-term/src/ui/popup.rs:32`][popup-struct]), whose entire state is
an optional [anchor][concepts] point, the last painted rect, a scroll counter and
four construction-time booleans.

There is no OS window anywhere in the overlay path. Every layer paints into the
same `helix-tui` cell `Buffer`, and the `Compositor`
([`helix-term/src/compositor.rs:78`][compositor-struct]) is a
`Vec<Box<dyn Component>>` rendered bottom-up with each layer handed the **full**
screen rect and expected to clip itself by arithmetic
([compositor.rs:184][compositor-render]).

### Design philosophy

The philosophy is arithmetic over machinery. There is no layout engine, no
observer, no invalidation graph and no cache: `Popup::render_info`
([popup.rs:126][popup-render-info]) recomputes the anchor, the side, the size
budget and the final rect from scratch on every paint. [Flip][concepts] is a
two-line `match` on a fixed six-row threshold; [shift][concepts] is one `if` that
preserves a two-column right gutter; overflow becomes scroll, never re-placement.

The whole flip algorithm reads:

> ```rust
> // if there's a orientation preference, use that
> // if we're on the top part of the screen, do below
> // if we're on the bottom part, do above
> let can_put_below = viewport.height > rel_y + MIN_HEIGHT;
> let can_put_above = rel_y.checked_sub(MIN_HEIGHT).is_some();
> let final_pos = match self.position_bias {
>     Open::Below => match can_put_below {
>         true => Open::Below,
>         false => Open::Above,
>     },
>     Open::Above => match can_put_above {
>         true => Open::Above,
>         false => Open::Below,
>     },
> };
> ```
>
> — [`helix-term/src/ui/popup.rs:152-166`][popup-flip]

The fallback is unconditional: a `Below`-biased popup with fewer than six rows
below flips `Above` even when there are also fewer than six rows above. There is
no second-chance re-check and no "pick the larger side" scoring, and `MIN_HEIGHT`
is a global constant unrelated to the content's actual height
([popup.rs:18][popup-consts]).

The second philosophical commitment is that **placement is a query, not a side
effect of paint**. `Popup::area(viewport, editor)` ([popup.rs:122][popup-area])
calls the same `render_info` and returns just the rect, which is how helix predicts
collisions before drawing anything.

## How it works

The frame driver is `Application::render` ([application.rs:261][app-render]): it
autoresizes the terminal, builds one `Context` (with `scroll: None`), calls
`Compositor::render(area, surface, cx)`, asks the compositor for the cursor, resets
the per-frame cursor cache, and hands the result to `Terminal::draw`
([helix-tui/src/terminal.rs:186][terminal-draw]), which emits the frame through a
front/back `Buffer` pair swapped after each draw
([terminal.rs:219-221][terminal-draw]).

`Popup::render` ([popup.rs:317][popup-render]) then does five things in order:

```text
1. RenderInfo { area, child_height, render_borders, is_menu } := render_info(viewport, editor)
2. self.area := area                       # recorded for the next frame's hit test
3. surface.clear_with(area, background)    # ui.menu (fallback ui.text) if is_menu, else ui.popup
4. if render_borders: inner := area.inner(Margin::all(1)); Block::bordered().render(area)
5. scroll := clamp(scroll_half_pages * (inner.height/2), 0, child_height - inner.height)
   cx.scroll := Some(scroll); contents.render(inner, surface, cx)
```

The parent/child seam is one method, `Component::required_size((max_w, max_h)) -> Option<(u16,u16)>`,
whose doc comment explicitly permits a child to return a size **larger** than the
budget so the parent can convert the excess into scroll
([compositor.rs:60-67][compositor-required-size]). `Popup` panics if the child does
not implement it ([popup.rs:182][popup-measure]).

Events run the mirror image. `Compositor::handle_event`
([compositor.rs:144][compositor-handle-event]) walks the layer vector **in
reverse**, and the return type is the load-bearing invention:

```rust
pub type Callback = Box<dyn FnOnce(&mut Compositor, &mut Context)>;

// Cursive-inspired
pub enum EventResult {
    Ignored(Option<Callback>),
    Consumed(Option<Callback>),
}
```

`Ignored(Some(cb))` means "I want to be destroyed, but I did **not** handle this
event" — the callback is collected, `consumed` stays false, and propagation
continues to the layer below ([compositor.rs:159-179][compositor-propagate]). All
callbacks run **after** the loop, so stack mutation can never invalidate the
iteration.

## The analysis spine

### 1. Anchor model

The anchor is one value: `Option<Position>`, where `Position { row, col }` is an
absolute 0-based screen cell ([popup.rs:33][popup-struct]; the builder's doc at
[popup.rs:59][popup-position] states it is the position of the information being
referred to, not the popup's own corner). It is `Copy` and comparable — a plain
value, not a handle, an element reference or a callback. There is exactly one
anchor kind: a point. No [anchor rect][concepts], no text ranges, no multi-rect
(an LSP range that wraps across lines is never used as an anchor), no
[virtual anchor][concepts], and no detached trigger/anchor split.

Anchor-to-screen conversion happens once, outside the popup, in `Editor::cursor`
([helix-view/src/editor.rs:2424][editor-cursor]): it takes the primary selection's
cursor, calls `view.screen_coords_at_pos`, and adds the view's inner-area origin.
The result is memoised for the frame in a `Cell`-based `CursorCache`
([editor.rs:2678][editor-cursorcache]) that `Application::render` resets after each
draw ([application.rs:288][app-cursor]).

The anchor is re-read every frame but carries **hysteresis**: the previous value is
kept whenever the screen row is unchanged ([popup.rs:128-135][popup-anchor-hysteresis]).
A popup therefore follows vertical cursor movement immediately and ignores
horizontal movement entirely until the row changes. Signature help goes further and
inherits the _previous popup instance's_ anchor across a full rebuild —
`.position(old_popup.and_then(|p| p.get_position()))`
([handlers/signature_help.rs:270][sig-position-inherit]).

Second-order anchoring exists but is not expressed as an anchor: the completion
documentation panel anchors to `self.popup.area(...)`, a `Rect`
([ui/completion.rs:533][completion-popup-area]), and in its fallback branch to
`max(cursor_row, menu.bottom())` — an obstacle set rather than an anchor.

**Algorithm.**

```text
anchor := editor.cursor().0 or Position(0, 0)
if stored.is_some() and stored.row == anchor.row:
    anchor := stored                 # freeze the column while on the same row
else:
    stored := anchor                 # re-anchor when the row changes
```

The store lives inside the popup (`self.position`) and is mutated during the
geometry query.

**Where the behavior lives.** Library code only: the `Popup.position` field, resolved
through `Editor::cursor` plus `CursorCache` in `helix-view`. No platform primitive
and no accessibility API is involved.

**Degradation.** The anchor is already integer cells in a single surface, so it needs
no OS window, no sub-cell precision and no hover — the anchor is the text cursor, not
the pointer. The failure mode worth naming: when the anchor cannot be resolved,
`render_info` does `editor.cursor().0.unwrap_or_default()`
([popup.rs:127][popup-render-info]), so it silently becomes cell `(0,0)` and the popup
teleports to the top-left corner instead of closing. (That `Editor::cursor` returns
`None` specifically when the cursor is scrolled out of view is an inference from
`CursorCache` delegating to `view.screen_coords_at_pos`; `screen_coords_at_pos`
itself was not read.)

### 2. Placement model

Two sides only — `Open::Above` / `Open::Below`
([helix-term/src/commands.rs:3817][open-enum], an enum reused from the editor's
line-open command). There is no left or right side, no alignment axis, no
preferred-placement list and no auto-placement scoring. Horizontal placement is
fixed: the popup's left edge equals the anchor column, always, and can only be
shifted left — never flipped, never centred. In [concepts.md][concepts] terms, the
side axis supports flip and the edge axis supports shift, and nothing supports
[slide or resize][concepts] as a distinct step.

The vertical decision is the six-row availability test above. Crucially the
threshold is a constant, not the measured content height, because measurement
happens _after_ the side is chosen ([popup.rs:182][popup-measure]): the chosen side
determines the height budget handed to `required_size`
([popup.rs:168-179][popup-budget] — `rel_y` above, `viewport.height -sat (1 + rel_y)`
below, then capped at `MAX_HEIGHT` and reduced by the border). This is
decide-then-measure, not measure-then-decide.

Viewport padding is asymmetric and hard-coded: two columns on the right
(`viewport.width <= rel_x + width + 2`, [popup.rs:196][popup-shift]), zero on the
left, zero top, zero bottom. The horizontal push is a pure clamp of `x` plus a width
truncation — a popup wider than `viewport.width - 2` is truncated, never wrapped and
never horizontally scrolled.

Vertically there is no shift at all, only clamping through the rect construction
([popup.rs:201-211][popup-rect]): `Above` ends at `position.row` exclusive, `Below`
starts at `position.row + 1`. **The anchor row is never covered**, and the invariant
is enforced structurally — the height is computed as `position.row - rel_y` (above)
or `y_max - rel_y` (below) rather than by a check that a later clamp could bypass.

There is no RTL handling, no writing modes and no bidi awareness; no custom
[clipping boundary][concepts] (the boundary is always the whole compositor `Rect`,
which is always the terminal); no safe-area insets, work areas or multi-monitor
notion. Size caps: `MAX_HEIGHT` 26 and `MAX_WIDTH` 120
([popup.rs:19-20][popup-consts]); menus additionally cap at 10 rows
([menu.rs:156][menu-cap]); the completion documentation band caps at 15 rows
([completion.rs:567][completion-doc-cap]); hover clamps its text width into
`[10, 120]` ([ui/lsp/hover.rs:110-111][hover-width]).

**Algorithm.** See the `Popup::render_info` reproduction under **Named algorithms**
below for the exact arithmetic.

**Where the behavior lives.** Entirely inside `Popup::render_info`
([popup.rs:126-218][popup-render-info]), about 60 lines. Nothing in `helix-view`,
nothing in `helix-tui`. Its only external inputs are `Editor::cursor`,
`editor.menu_border()` / `editor.popup_border()`
([helix-view/src/editor.rs:1474][editor-border-getters]) and the child's
`required_size`.

**Degradation.** This dimension ports unchanged: it needs no OS window (it is viewport
arithmetic), no hover, no script, no sub-cell precision (all `u16` saturating
arithmetic) and no key release.

> [!WARNING]
> `render_info` mixes `viewport.height` ([popup.rs:155][popup-flip]) with
> `viewport.bottom()` ([popup.rs:208][popup-rect]). Those are equivalent only while
> `viewport.y == 0`. A caller that wanted to express an inset viewport — an Android
> soft-keyboard inset, reserved chrome — by passing a shrunken `Rect` would hit that
> inconsistency. The `viewport: Rect` parameter is otherwise exactly the right seam.

### 3. Collision & geometry engine

There is no engine. There is `Rect` ([helix-view/src/graphics.rs:118][graphics-rect])
— four `u16`s with `Copy + Hash + Eq` — and a per-frame recompute. `Rect`'s whole
vocabulary is `left/right/top/bottom` (saturating), `clip_left/right/top/bottom`
(the `clip_left`/`clip_top` variants clamp so the origin can never pass the far edge,
[graphics.rs:164][graphics-clip]), `inner(Margin)` which returns `Rect::default()`
rather than an inverted rect when the margin exceeds the size
([graphics.rs:212][graphics-inner]), `union`, `intersection` (saturating, so a
disjoint pair yields a zero-size rect, [graphics.rs:250][graphics-intersection]) and
`intersects` ([graphics.rs:273][graphics-intersects]).

Overflow detection is not a separate pass — the rect construction _is_ the
[constraint adjustment][concepts]. Clipping-ancestor discovery does not exist,
because there is exactly one clipping ancestor: the terminal. Scroll containers do
not exist either; the document view scrolls, but the popup is re-anchored from
`Editor::cursor` each frame, so it tracks by recomputation. No transforms, no zoom,
no device pixel ratio, no fractional coordinates.

Tracking is frame-callback-only and unconditional. `render_info` runs inside
`render` every frame; `Completion::render` then calls `self.popup.area(area, cx.editor)`
([completion.rs:533][completion-popup-area]), running it a **second** time in the
same frame; `set_completion` and the signature-help intersection test each run it
again outside paint. Note that `area()` takes `&mut self` and mutates
`self.position` — the geometry query is not pure.

Measurement cost is worse than it looks. `Menu::required_size` guards on
`viewport != self.viewport || self.recalculate` ([menu.rs:327-333][menu-required-size]),
but `self.viewport` is assigned only in the struct literal inside `Menu::new`
([menu.rs:61][menu-new]) and is never updated by `recalculate_size` — so the memo
never hits and every measure re-runs `recalculate_size`, which calls
`option.format(&editor_data)` for **every** option to compute per-column widths
([menu.rs:137-167][menu-recalc]). With the double call per frame that is two passes
over the whole option list per frame. `Markdown` re-parses its source in both
`required_size` ([markdown.rs:382][markdown-required-size]) and `render`
([markdown.rs:369][markdown-render]).

Two different measuring algorithms coexist. `Paragraph::required_size`
([helix-tui/src/widgets/paragraph.rs:131][paragraph-required-size]) runs the real
`WordWrapper` and is exact. `ui::text::required_size`
([helix-term/src/ui/text.rs:53][text-required-size]) is a heuristic —
`height += 1; if content_width > max { height += content_width / max }` — which
neither word-wraps nor handles exact multiples, and it is what sizes `Markdown` and
`Hover`. So a popup containing markdown is measured by an estimate and painted by a
different wrapper.

**Algorithm.** Per frame, per popup: `rect := f(cursor, viewport, child.required_size(budget))`.
Between two popups: `a.intersects(b)` implies one of them is destroyed. Clipping:
every write goes through `Buffer[(x, y)]`, whose `index_of` carries a
`debug_assert!` for in-bounds coordinates
([helix-tui/src/buffer.rs:272][buffer-index-of]) — so an out-of-bounds placement is
a debug panic, not a clip, and correctness rests entirely on the placement
arithmetic.

**Where the behavior lives.** `Rect` in `helix-view/src/graphics.rs` (a value type with
no behaviour beyond arithmetic); the recompute in `Popup::render_info`; the frame
driver in `helix-term/src/application.rs`.

**Degradation.** This ports completely. Nothing here depends on the DOM, on layout
observers or on GPU state, and it is `u16` saturating arithmetic throughout. Three
things would have to change on the way across: make `area()` pure (helix's takes
`&mut self`), give the measure step a memo that actually works, and pick one wrap
algorithm for both measure and paint.

### 4. Arrow / caret geometry

Not applicable, and the absence is deliberate enough to be a finding. Helix has no
arrow, caret, tail, beak or notch on any overlay. The frame is `Block::bordered()`
painted over the whole rect when `popup-border` / `menu-border` is enabled
([popup.rs:340][popup-borders-render]; the config default is `none`,
[helix-view/src/editor.rs:1232][editor-popup-border-default]), and it carries no
directional information. No geometry metadata about the chosen side leaves the
popup: `RenderInfo` is `{ area, child_height, render_borders, is_menu }`
([popup.rs:22][popup-renderinfo]), consumed privately inside `render`, and
`final_pos` is a local that never escapes.

The substitute for an arrow is the placement invariant itself: the popup abuts the
anchor row with zero offset, so adjacency is the only pointing cue. There _is_ one
directional-glyph mechanism in the codebase, and it belongs to a non-overlay
feature — inline diagnostics draw box-drawing connectors (`┘ ┌ └ ├ ┴ ─ │`) from the
diagnostic text back to its column
([ui/text_decorations/diagnostics.rs:68-74][diagnostics-connectors]). That is the
honest cell-grid answer to "what is an arrow when the smallest unit is a cell": a
run of box-drawing cells forming an elbow — and helix spends it only on virtual text
laid out in the document flow, never on a floating popup.

An absence with a reason: with a two-column right-gutter shift and no horizontal
flip or centring, the popup's left edge is usually exactly the anchor column, so an
arrow would sit at offset 0 and carry no information. It appears the arrow only
becomes necessary once alignment and centring are allowed, which helix does not do.

**Algorithm.** None exists. The nearest analogue is `BorderType::line_symbols`, used
directly to draw a one-cell horizontal separator inside a popup
([ui/lsp/signature_help.rs:147][sig-separator], [ui/lsp/hover.rs:89][hover-keys]).

**Where the behavior lives.** Nowhere; border painting is `helix-tui`'s `Block`, and
separator rows are drawn cell-by-cell by the content components.

**Degradation.** Not applicable by absence. The transferable observation for a cell
grid: an arrow costs a whole cell in each dimension and can point in only four
directions at one-cell granularity, so its information content is low; helix spends
the budget on the never-cover-the-anchor-row invariant instead, which is free.

### 5. Trigger semantics

**There is no hover trigger anywhere in helix.** `MouseEventKind::Moved` appears in
exactly one place in `helix-term` — `if event.kind != MouseEventKind::Moved` at
[ui/editor.rs:1207][editorview-mouse-moved], used only to avoid cancelling pending
keys during a drag. No popup, hover card or tooltip is ever opened by pointer
position.

The trigger vocabulary is:

| Trigger                 | Mechanism                                                                                                                                                                                                 |
| ----------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| typed character         | `PostInsertChar` hook fires `trigger_auto_completion` ([handlers/completion.rs:245][handlers-completion-hooks]) and the signature-help trigger-character test ([signature_help.rs:291][sig-trigger-char]) |
| document/selection edit | `DocumentDidChange` / `SelectionDidChange` send `SignatureHelpEvent::ReTrigger` ([signature_help.rs:353][sig-hooks])                                                                                      |
| mode switch             | entering insert mode triggers both; leaving cancels both ([signature_help.rs:331][sig-mode-switch])                                                                                                       |
| explicit command        | `ManualTrigger`, `:lsp-hover`, code actions ([commands/lsp.rs:661][lsp-code-actions])                                                                                                                     |
| programmatic            | `trigger_auto_completion(editor, true)` re-fires right after a completion is accepted ([ui/completion.rs:285][completion-retrigger-sig])                                                                  |

> [!IMPORTANT]
> **Key release events are explicitly discarded even when the terminal reports
> them.** Helix pushes the kitty keyboard-protocol flags
> `DISAMBIGUATE_ESCAPE_CODES | REPORT_ALTERNATE_KEYS`
> ([helix-tui/src/backend/crossterm.rs:184-186][crossterm-kitty]), and then filters
> `KeyEventKind::Release` out at the application boundary, before the compositor
> ever sees it ([application.rs:724-729][app-key-release]). A terminal-first design
> treats press-only as the contract rather than as a limitation to work around.

The auto-trigger predicate is content-based rather than gesture-based: either the
text before the cursor ends with an LSP `trigger_character` (or `/` for path
completion), or the last `completion-trigger-len` characters (default 2) are all
word characters ([handlers/completion.rs:118-170][handlers-completion-trigger]).
Pointer type is never distinguished, touch does not exist, and there is no
AT-driven trigger.

Multiple triggers combine without races by funnelling each feature's events into
one `mpsc` channel owned by a single-threaded `AsyncHook` task
([helix-event/src/debounce.rs:38][debounce-run]). Because the hook is the only
mutator of its own state, "a trigger character cancels the pending auto request"
is a plain field write (`self.task_controller.cancel()`,
[request.rs:102][request-cancel]), not a lock. Staleness is caught by revalidation
at three separate hops instead: the debounce hook compares document/view ids
([request.rs:87][request-fold]), `request_completions` re-checks mode/view/doc and
that the cursor has not moved back before the trigger position
([request.rs:169][request-revalidate]), and `show_completion` re-checks again after
the await ([handlers/completion.rs:96][handlers-completion-show]).

**Algorithm.**

```text
trigger -> send_blocking(tx, Event)          # try_send, then a 10 ms timeout send that
                                             # DROPS the message rather than freeze the editor
       -> single async task folds the event into hook state, returns a new deadline
       -> on deadline, finish_debounce() dispatches onto the editor thread
```

Race-freedom comes from single ownership plus revalidation at every hop, not from
mutexes ([debounce.rs:62][debounce-send]).

**Where the behavior lives.** `helix-event` supplies the `AsyncHook`/debounce
substrate; `helix-term/src/handlers/*` supplies per-feature policy. The `Popup`
itself knows nothing about triggers — it is constructed already open.

**Degradation.** With no hover, nothing is lost, because helix already has no hover
trigger. With no timers (a static-HTML target), the debounce layer disappears and
only "trigger, then immediately open" survives — which is exactly the
`ManualTrigger` path, where `finish_debounce()` is called inline
([request.rs:118][request-manual]); helix keeps a zero-delay path for every feature,
so a timer-free target can reuse it. With no key release: unaffected, since every
trigger here is a key _press_ or a document event.

### 6. Timing

Three independent debouncers, all instances of one trait, `helix_event::AsyncHook`
([debounce.rs:15][debounce-trait]), all with the same shape:
`handle_event(event, current_deadline) -> Option<new_deadline>` plus
`finish_debounce()`. The loop is `tokio::time::timeout_at(deadline, rx.recv())`; a
new event before the deadline replaces or extends it, and a timeout fires
`finish_debounce` and clears the deadline ([debounce.rs:38][debounce-run]).
Returning `None` cancels; returning the received timeout unchanged means "this
event is informational, do not disturb the running timer".

| Delay                                          | Value  | Source                                                                                                                                              |
| ---------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| completion auto-trigger (`completion-timeout`) | 250 ms | [helix-view/src/editor.rs:1200][editor-completion-timeout]                                                                                          |
| completion trigger-char / restart              | 5 ms   | [request.rs:145][request-timeouts] — the comment says the small timeout exists only to coalesce a backlog and macros                                |
| manual completion                              | 0 ms   | [request.rs:118][request-manual] (`finish_debounce()` inline)                                                                                       |
| signature help                                 | 120 ms | [signature_help.rs:32][sig-timeout] — `/// debounce timeout in ms, value taken from VSCode`                                                         |
| completion-item resolve (lazy docs)            | 150 ms | [resolve.rs:127][resolve-debounce]                                                                                                                  |
| multi-server response aggregation              | 100 ms | [request.rs:269][request-aggregate] — after the first server replies, later servers get 100 ms to join the same menu; the rest stream in afterwards |

There is no [warm-up][concepts], no [cool-down][concepts]/skip-delay, no "instant
subsequent tooltip", no shared provider, no group and no maximum display duration —
because there is no hover.

The signature-help hook is the only one with an explicit three-state FSM,
`State::{Open, Closed, Pending}` ([signature_help.rs:24][sig-state]). Its two
non-obvious rules are worth naming: `ReTrigger` is **dropped** when the state is
`Closed`, so a dismissed popup does not resurrect itself on the next keystroke
([signature_help.rs:67][sig-retrigger-closed]); and `RequestComplete` is **ignored**
while `Pending` with a task still running, so a late reply cannot mark the popup
closed after a newer request has already been fired
([signature_help.rs:77][sig-late-reply]).

**Algorithm.** The observed state machine:

```text
states {Closed, Pending, Open}
events {Invoke(manual), Trigger(auto), ReTrigger, Cancel, RequestComplete(open)}

Invoke:          deadline := now                       # fire immediately
Trigger:         deadline := now + T
ReTrigger:       if state == Closed: keep deadline unchanged (drop the event)
                 else:               deadline := now + T
Cancel:          state := Closed; deadline := None
RequestComplete: if state == Pending and task_running: keep deadline
                 else: state := open ? Open : Closed; cancel task
on deadline:     state := Pending; restart task token; dispatch request
```

**Where the behavior lives.** `helix-event/src/debounce.rs` is the substrate; each
`impl AsyncHook` in `helix-term/src/handlers/*` is the policy. The popup itself has
zero timing logic — it is created open and destroyed by someone else.

**Degradation.** With no script and no timers, every delay collapses to 0 and every
machine collapses to `Open | Closed`; helix's own `ManualTrigger` path shows that is
a supported degradation rather than a break. No OS window and no key release are
irrelevant here — timing is entirely application-level. The transferable structure
is the separation: a timing hook owns _whether_ a surface exists, a placement
primitive owns _where_, and they communicate only by construct/destroy.

### 7. Interactive hover

Not applicable, and structurally so. Because there is no hover trigger (dimension
5), there is no trigger-to-content travel problem: no [safe polygon][concepts], no
pointer bridge, no menu-aim, no interactive border, no trajectory heuristic and no
debounce-on-leave. Nested surfaces do exist (the completion menu plus its
documentation panel), but the documentation panel is not reachable by pointer at
all — it is not a `Component`, has no event handler and no id, and is painted inline
([ui/completion.rs:570][completion-doc-paint]).

What helix does with the pointer inside an overlay is narrow and cheap.
`Popup::handle_mouse_event` ([popup.rs:220][popup-mouse]) does a plain rect
containment test against `self.area` — **the rect recorded by the last `render`**
([popup.rs:324][popup-area-assign]) — and consumes only `ScrollUp` / `ScrollDown`,
and only when `has_scrollbar`. Everything else returns `Ignored`.

> [!WARNING]
> `Menu`'s own mouse arm — `Event::Mouse(_) => return EventResult::Consumed(None)`,
> commented "Menu is a modal and should consume mouse events so clicks don't fall
> through to the editor underneath" ([menu.rs:238-241][menu-mouse]) — is unreachable
> whenever the `Menu` is inside a `Popup`, because `Popup::handle_event` intercepts
> `Event::Mouse` before delegating ([popup.rs:262-266][popup-handle-event]). So in
> the shipped completion UI a click neither selects an item nor is swallowed: it
> falls through to the editor, moves the cursor, and the `PostCommand` hook then
> clears the completion. (This is read from the control flow, not instrumented;
> `Menu` is also used outside a `Popup`, inside `Select` — [ui/select.rs:28][select-menu]
> — where the arm _is_ reachable.)

**Algorithm.**

```text
hit := x >= area.left() && x < area.right() && y >= area.top() && y < area.bottom()
```

Note the half-open convention on right/bottom, and that this is evaluated against
the **last painted** rect, not a freshly computed one. The interactive region is
exactly the popup rect with a tolerance of zero cells; there is no one-cell grace
border anywhere.

**Where the behavior lives.** `helix-term/src/ui/popup.rs:220-258` only. There is no
hit-test list, no spatial index and no shared hit-testing service — each component
tests its own last-painted rect.

**Degradation.** Already fully degraded. On a target with no hover this dimension
changes nothing. The property worth preserving: hit-testing against the last painted
rect is sufficient here precisely because placement is deterministic per frame.

### 8. Dismissal

The richest dimension in this subject, spread across three mechanisms.

**(1) `EventResult::Ignored(Some(callback))`.** A component can request its own
removal _while letting the event continue to the layer below_: the callback is
collected, `consumed` stays false, and the loop continues
([compositor.rs:170-172][compositor-propagate]); all callbacks run after the loop
([compositor.rs:177][compositor-callbacks]). That is how `auto_close` works — any
key the content ignores yields `Ignored(Some(close_fn))`
([popup.rs:305][popup-ignored-some]), so the popup vanishes and the keystroke still
reaches the editor. This is [light dismiss][concepts] with two effects and no
[grab][concepts].

**(2) Escape, with an explicit opt-out.** `Popup` consumes `Esc`/`Ctrl-C`, forwards
them to the content, then closes ([popup.rs:285-292][popup-content-first]). But
`ignore_escape_key(true)` makes `Esc` bypass the popup entirely
([popup.rs:273][popup-esc-optout]), which completion
([ui/completion.rs:295][completion-ignore-esc]) and signature help
([signature_help.rs:272][sig-position-inherit]) both use so that one `Esc` closes
the popup _and_ leaves insert mode. The builder's doc comment
([popup.rs:86-92][popup-ignore-esc]) spells out the reasoning: otherwise the user
must press `Esc` twice. Dismissal is deliberately delegated to the mode machine
rather than owned by the surface.

**(3) External hooks.** `OnModeSwitch(Insert -> *)` pushes
`compositor.remove(SignatureHelp::ID)` and `clear_completions`
([signature_help.rs:331][sig-mode-switch], [handlers/completion.rs:245][handlers-completion-hooks]).
`PostCommand` in insert mode clears the completion for any command outside a small
allow-list, and maps `delete_char_backward` to a filter update instead
([handlers/completion.rs:200][handlers-completion-postcommand]).
`CompletionEvent::DeleteText` aborts if the cursor moves back before the trigger
offset ([request.rs:126][request-delete-text]). `update_filter` closes when the
match set empties or a non-word character is typed
([handlers/completion.rs:178][handlers-completion-filter]).

Mouse-outside is handled by `auto_close` popups closing on **any**
`MouseEventKind::Down` — and the `auto_close` test is evaluated **before** the
containment test ([popup.rs:229-236][popup-autoclose-mouse] precedes
[:238][popup-contain]), so clicking _inside_ an auto-close popup also closes it.
Non-`auto_close` popups ignore outside clicks entirely; the click reaches the
editor, moves the cursor, and the `PostCommand` hook does the closing.

Not handled at all: window/app deactivation (`Event::FocusLost` falls into `Popup`'s
catch-all `Ignored(None)` arm at [popup.rs:270][popup-handle-event] and is consumed
by `EditorView` at [ui/editor.rs:1599][editorview-focuslost], so popups survive
terminal focus loss); anchor scrolled out of view (the popup jumps to `(0,0)` rather
than closing — dimension 1); resize (`Event::Resize` is an explicit `TODO`,
[popup.rs:266][popup-resize-todo]); navigation; touch.

> [!WARNING]
> `Menu`'s close callback is `compositor.pop()` ([menu.rs:244-247][menu-close-pop])
> — it pops the **top** layer by position — while `Popup`'s is
> `compositor.remove(self.id)` ([popup.rs:277][popup-close-fn]), which is targeted.
> If anything were ever pushed above a bare `Menu` layer, the wrong layer would be
> destroyed. The type system permits both and they are not equivalent.

**Algorithm.** Per event, top-down over layers: `r := layer.handle_event(e)`; on
`Consumed(cb)` push and stop; on `Ignored(Some(cb))` push and **continue**. After
the loop, run all callbacks in collection order against `&mut Compositor`. Because
callbacks run after propagation, a dismissal and the action that caused it are
always applied in that order, and removal never invalidates the iteration.

**Where the behavior lives.** The `Ignored`/`Consumed` + callback protocol is the
compositor kernel ([compositor.rs:13][compositor-eventresult],
[:144][compositor-handle-event]). Per-surface policy is in `Popup::handle_event`
and the `register_hook!` handlers. `EditorView` additionally owns the completion's
dismissal, because the completion is not a compositor layer
([ui/editor.rs:1502-1540][editorview-completion-events]).

**Degradation.** No key release: unaffected — every dismissal here is a press or an
application event. No OS window: unaffected; there is no app-deactivation dismissal
to lose in the first place. No script: only trigger re-activation and
`<details>`-style toggling would survive; `Esc`, outside-click and hook-driven
dismissal all vanish. On Android the system back key maps naturally onto the `Esc`
arm, and `ignore_escape_key` is the seam that makes it work — the surface must be
able to say "this dismissal key is not mine".

### 9. Focus

Helix has no focus system in the widget sense — no focus ring, no tab order, no
[focus scope][concepts], no restoration. What exists is **cursor ownership**,
resolved by one top-down query: `Compositor::cursor` walks layers in reverse and
returns the first `Some` ([compositor.rs:190][compositor-cursor]). `Popup<T>` does
**not** implement `Component::cursor`, so it inherits the default
`(None, CursorKind::Hidden)` ([compositor.rs:56][compositor-cursor-default]) —
meaning no popup ever takes the terminal cursor. While a completion menu or
signature help is open, the hardware cursor stays in the document text.
`Picker`/`Prompt` do implement `cursor`, which is the tooltip-vs-dialog distinction
expressed as one trait method. (Statements about pickers rest on `Overlay` and
`Component::cursor` usage plus `Compositor::last_picker` handling, not on a full
read of `picker.rs`.)

Keyboard "focus" is expressed as event precedence, and here helix breaks its own
layering: **the completion menu is not a compositor layer**. It is a field on
`EditorView` (`pub(crate) completion: Option<Completion>`,
[ui/editor.rs:43][completion-field]), rendered last inside `EditorView::render`
([ui/editor.rs:1732][editorview-render-completion]) and handed events by hand inside
the insert-mode arm of `EditorView::handle_event`
([ui/editor.rs:1502][editorview-completion-events]). Three consequences: any real
compositor layer paints over the completion menu; the menu receives events only
after every layer above `EditorView` has ignored them; and the intersection test
with signature help has to reach for it via
`compositor.find::<ui::EditorView>().unwrap().completion`
([signature_help.rs:277][sig-intersect]).

Nothing is trapped. `Menu` consumes Up/Down/Tab/Shift-Tab/Ctrl-p/Ctrl-n/PageUp/
PageDown/Enter/Esc/Ctrl-c ([menu.rs:264][menu-keys]) and ignores everything else,
which is what makes typing-while-the-menu-is-open work. `Popup` adds
PageUp/PageDown/Ctrl-u/Ctrl-d for scrolling **only when the content ignored them** —
content-first key resolution, with a comment naming exactly that case
([popup.rs:282-300][popup-content-first]). Those are the same keys `Menu` binds to
item navigation ([menu.rs:282-293][menu-pageup]), which is why asking the child
first — rather than adding a capability flag — lets one shell serve both a
completion menu and a code-lens popup. One deliberate de-conflict: `Menu`
returns `Ignored` for Tab/Shift-Tab when `smart-tab.supersede-menu` is configured,
letting the editor's smart-tab win, with a rueful "(Is there a better way to do
this?)" ([menu.rs:249-262][menu-smart-tab]).

There is one synthetic-event mechanism worth naming. When the completion menu
ignores a key, `EditorView` fabricates an `Enter` key event and feeds it back to
force the menu to validate the current selection, then lets the original key through
to insert mode as well ([ui/editor.rs:1512-1524][editorview-synthetic-enter]) — a
synthetic event used as an imperative command channel.

**Algorithm.** Key routing: `for layer in layers.rev() { if Consumed { break } }`.
Within a `Popup`: contents first, then the popup's own defaults. Cursor ownership:
the first layer from the top whose `cursor()` is `Some`; `Popup` abstains by not
implementing it.

**Where the behavior lives.** `Component::cursor`'s default
([compositor.rs:56][compositor-cursor-default]) plus `Compositor::cursor`
([compositor.rs:190][compositor-cursor]). The absence of an override in `Popup` is
the entire policy.

**Degradation.** No OS window: unaffected — the terminal cursor _is_ the focus
indicator, and abstaining from it is the terminal-native way to say "non-modal". No
script: focus-within could express containment but not abstention. Touch: nothing to
lose, since nothing was trapped.

### 10. Layering & portals

`Compositor { layers: Vec<Box<dyn Component>>, area: Rect, last_picker, full_redraw }`
([compositor.rs:78][compositor-struct]). Render is
`for layer in &mut self.layers { layer.render(area, surface, cx) }` — every layer is
handed the full screen rect and clips itself
([compositor.rs:184][compositor-render]). Events walk
`self.layers.iter_mut().rev()` ([compositor.rs:159][compositor-propagate]).
Front-to-back is literally "later in the vector".

There is no portal, because there is nothing to escape: no clipping ancestor, no
stacking context, no z-index, no [top layer][concepts]. A popup does not live inside
its trigger's subtree; it is pushed onto the root stack by whoever created it — often
from a job callback — and its only link back to the anchor is the `Position` value.

Ownership and identity: `push`, `pop`, `remove(id)` (removes by id from anywhere in
the vector, [compositor.rs:131][compositor-remove]), `replace_or_push(id, layer)`
([compositor.rs:119][compositor-replace-or-push]; overwrites in place through a
downcast, preserving stack position — this is how signature help updates without
flicker), `remove_type::<T>()` ([compositor.rs:205][compositor-remove-type]),
`find::<T>()` ([compositor.rs:139][compositor-find]), `find_id::<T>(id)`.
**Identity is `&'static str` ids plus `std::any::type_name` strings**
([compositor.rs:69][compositor-type-name]). `Popup::id()` returns the id it was
constructed with ([popup.rs:387][popup-id]), and ids are conventionally consts on
the content type (`SignatureHelp::ID`, `Completion::ID`, `Hover::ID`).

The public surface is `Component` (`handle_event` / `render` / `required_size` /
`cursor` / `id` / `type_name`) plus `EventResult` plus `Callback`. The layer vector,
`last_picker` and `full_redraw` are private or `pub(crate)`. Everything a component
may do to the stack it does through a deferred `Callback`, never by holding a
reference — which is what makes removal-during-iteration safe.

The honest caveat: the most-used overlay in the editor (the completion menu) opts
**out** of this stack and lives inside `EditorView`, and the completion's
documentation panel opts out even of `Component`. So the shipped system is a stack
plus two escape hatches.

**Algorithm.** Render bottom-up, full-rect, self-clipping. Events top-down until
`Consumed`, with `Ignored(Some(cb))` side effects accumulated. Mutation only via
deferred callbacks executed after the propagation loop. Identity by `&'static str`
for targeted removal/replacement, by `type_name` string for type-directed lookup.

**Where the behavior lives.** `helix-term/src/compositor.rs` in its entirety (299
lines, including Cursive-derived downcast helpers). Nothing in `helix-view` or
`helix-tui` knows about layers.

**Degradation.** This model requires nothing from any platform: no OS window, no
compositor, no top layer, no grab. The one part that does not port to a
value-semantics toolkit is `Box<dyn Component>` plus `Box<dyn FnOnce>`; the
deferred-mutation _idea_ ports as an enum of stack commands returned from the
handler.

### 11. Modality

[Modality][concepts] is not a property of a surface — it is emergent from what a
component consumes. There is no `modal: bool`, no scrim, no dim, no background
pointer blocking and no accessibility modal bit.

The spectrum actually implemented:

| Degree                        | Mechanism                                                                                                                                            |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| fully passthrough             | `Popup` with `auto_close == false` and content that ignores the key: the event reaches the editor unchanged ([popup.rs:301-310][popup-ignored-some]) |
| passthrough with side effect  | `auto_close == true`: `Ignored(Some(close_fn))` — the popup dies and the event still lands                                                           |
| selectively modal             | `Menu` consumes its navigation keys and ignores the rest, so typing filters while arrows navigate ([menu.rs:264][menu-keys])                         |
| claims-to-be-modal but is not | `Menu`'s `Event::Mouse(_) => Consumed(None)` ([menu.rs:238][menu-mouse]), unreachable under a `Popup`                                                |
| genuinely blocking            | `Picker`/`Prompt` layers, which consume nearly everything and claim the cursor                                                                       |

Light dismiss exists only in the second form. Background _keyboard_ blocking is
per-key, decided by the topmost consumer; background _pointer_ blocking is
essentially absent, because `Popup::handle_mouse_event` returns `Ignored(None)` for
everything except scroll-inside ([popup.rs:243-257][popup-mouse]). A click on a
non-`auto_close` popup passes through to the text underneath and moves the cursor.

The most interesting modality decision is taken _outside_ the surfaces: rather than
let signature help and the completion menu overlap and fight, helix makes them
mutually exclusive by geometry ([signature_help.rs:274][sig-intersect]). That is
modality expressed as an invariant on the display list rather than as an
input-blocking mode.

**Algorithm.** `modality(surface) := the set of events for which handle_event returns Consumed`.
There is no other definition in the system; blocking is per-event-kind and
per-frame, never a global mode bit.

**Where the behavior lives.** Distributed across each component's `handle_event`. The
compositor supplies only the stop-on-`Consumed` rule.

**Degradation.** With no pointer grab: helix has none and never assumed one — every
dismissal is driven by events that _did_ arrive, never by events leaving the
surface. No OS window: nothing to lose. Static HTML: only the CSS-expressible parts
(a `<details>` toggle) survive; per-key modality does not. Android: no scrim to draw
and none expected.

### 12. Adaptive presentation

There is one adaptive decision inside the primitive, and it is made by type-name
string matching:

> ```rust
> let is_menu = self
>     .contents
>     .type_name()
>     .starts_with("helix_term::ui::menu::Menu");
> ```
>
> — [`helix-term/src/ui/popup.rs:137-140`][popup-is-menu]

That selects the background style (`ui.menu`, falling back to `ui.text`, versus
`ui.popup` — [popup.rs:327-335][popup-style]) and which of the two border config
bits applies (`editor.menu_border()` versus `editor.popup_border()`, both derived
from one `popup-border: none|popup|menu|all` enum,
[helix-view/src/editor.rs:1474][editor-border-getters]). So the popup decides its
presentation from the _content's Rust type name_, using a value the language does
not guarantee to be stable. A `TODO: consistently style menu` sits on the very lines
that consume the result ([popup.rs:328][popup-style]).

Borders are additionally suppressed by available space rather than by preference:
`render_borders = render_borders && max_height > 3 && max_width > 3`
([popup.rs:175][popup-border-space]), evaluated **before** the budget shrinks by two
in each axis. Chrome yields to content automatically.

The second adaptive decision is the completion documentation's presentation switch
([ui/completion.rs:534-568][completion-panel-band]): with more than 30 columns free
to the right of the menu it is a **side panel anchored to the menu**; otherwise it
becomes a **full-width band pinned to the top or bottom screen edge**, capped at 15
rows, and suppressed entirely when fewer than two rows are free. Same content, two
fundamentally different presentations, chosen by one width threshold — the terminal
analogue of popover-to-sheet. The decision is made by the _coordinating component_
(`Completion`), not by the primitive and not by the content.

The third is a decision not to use the overlay system at all: inline diagnostics are
virtual text laid into the document flow with box-drawing connectors
([ui/text_decorations/diagnostics.rs][diagnostics-connectors]) rather than popups —
a whole class of anchored information moved out of the overlay system.

There is no touch adaptation, no long-press, no teaching tips and no
keyboard-driven relocation.

**Algorithm.**

```text
presentation := f(content type name, viewport space)

border      := config AND max_height > 3 AND max_width > 3
doc panel   := if viewport.width - menu.right() > 30
                   side panel at (menu.right(), menu.top())
               else
                   full-width band on whichever side of {cursor row} U {menu rect}
                   has more rows, capped at 15, suppressed if <= 1
```

**Where the behavior lives.** Style and border adaptation inside
`Popup::render_info`/`render`; panel-versus-band inside `Completion::render`;
inline-versus-popup diagnostics as a config-level decision in `helix-view`.

**Degradation.** The width-threshold switch survives every constraint — it is integer
arithmetic on the viewport, and needs no hover, no timers and no window. It appears
that an inset-aware target (an Android soft keyboard) would work with the same code
shape provided the inset shrinks the `area` passed in, since the band's `y` is
computed from `area.height`. What should not be copied: deciding presentation from a
runtime type-name string.

### 13. Accessibility

Helix has no accessibility layer. Grepping the tree for AccessKit / a11y /
`accessib*` returns two false positives (a doc comment in `helix-tui/src/text.rs`
and a capability comment in `helix-stdx/src/faccess.rs`). There is no role, no
`aria-*` analogue, no UIA/AT-SPI/VoiceOver/TalkBack bridge, no announcement channel
and no live region.

A terminal grid can honestly expose two things, and helix uses one: the reported
cursor position (`Compositor::cursor` feeding `Terminal::draw(pos, kind)`,
[compositor.rs:190][compositor-cursor], [application.rs:286-291][app-cursor]) and
the painted characters. Screen readers on a terminal track the cursor — so the fact
that `Popup` deliberately abstains from claiming it (dimension 9) means opening a
completion menu or signature help produces no signal an assistive technology can
follow: the caret does not move and no text is inserted at it. That appears to be an
unadvertised consequence of the "popups never take the cursor" rule rather than a
considered trade-off, since no code addresses it either way.

The one deliberate accessibility-adjacent affordance is `CursorKind::Hidden`, whose
comment reads "Hidden cursor, can set cursor position with this to let IME have
correct cursor position" ([helix-view/src/graphics.rs:62][graphics-cursorkind]) —
i.e. move the reported caret without drawing it. That is the primitive an overlay
would need to announce itself in a terminal, and no overlay uses it.

WCAG 1.4.13 (hoverable / dismissible / persistent) is vacuous here: there is no
hover, everything is dismissible by `Esc`, and nothing auto-expires. Tooltip content
interactivity is moot: the only tooltip-like surface (the completion doc panel) is
non-interactive because it is not a `Component`.

**Algorithm.** None — no accessibility tree is built or exposed.

**Where the behavior lives.** Nowhere. The nearest thing to an accessibility contract
is `Component::cursor` returning `(Option<Position>, CursorKind)`.

**Degradation.** The finding _is_ the degradation. For a canvas-first toolkit painting
into one surface with no AT bridge, the only honest exposures are the reported caret
cell, the painted glyphs, and whatever the application writes into the terminal's own
status channels. A primitive would therefore need a "should this surface move the
_reported_ caret?" bit distinct from "should it draw one?" — helix has the second
and not the first.

### 14. Animation

Nothing animates. There is no enter/exit transition, no [transform origin][concepts],
no spring, no reduced-motion setting and no time-varying state on any overlay. A
popup appears fully formed on the first frame after `compositor.push` and disappears
on the frame after `remove`.

Critically for the question "does it emit geometry metadata that would enable
animation": **no**. `render_info` computes `final_pos: Open` and returns
`RenderInfo { area, child_height, render_borders, is_menu }`
([popup.rs:22][popup-renderinfo], [:212][popup-rect]) — the chosen side is dropped
on the floor, and `Popup::area()` exposes only the rect. A caller can learn _where_
the popup is but not _which side it chose_, and has to re-derive it by comparing
`popup_area.top()` with the cursor row — which is literally what `Completion::render`
does (`cursor_pos.min(popup_area.top())`, `cursor_pos.max(popup_area.bottom())`,
[ui/completion.rs:551-554][completion-band-y]). The side is recovered by arithmetic
because it was never published.

The only frame-varying visual is scroll, and that is state, not animation:
`scroll_half_pages` is an integer half-page count clamped at render time once the
content height is known ([popup.rs:345-351][popup-scroll-clamp]).

Redraw is diffed at the cell level by `helix-tui`'s two-buffer swap, so a
hypothetical animation would cost only the changed cells — the substrate would
support it; the design declines.

**Algorithm.** None.

**Where the behavior lives.** Not applicable; the relevant absence is in the
`RenderInfo` / `area()` contract.

**Degradation.** Nothing to lose on any target. The transferable lesson is negative:
if a toolkit ever wants placement-aware presentation — even something as small as a
different border cap glyph for above-versus-below, or an elbow connector — the
placement function must return the chosen side **as data** alongside the rect.
Helix's omission forces every downstream consumer to reverse-engineer the side from
coordinates.

### 15. State architecture

Two clearly separated architectures joined by construct/destroy.

**Surface state is tiny and fully controlled.** `Popup<T>` owns eight fields, of which
only three are mutable state: `position: Option<Position>` (the sticky anchor),
`area: Rect` (the last painted rect, for hit testing) and `scroll_half_pages: usize`.
The rest is construction-time configuration set by a builder chain (`position`,
`position_bias`, `auto_close`, `ignore_escape_key`, `with_scrollbar`, all
`mut self -> Self`, [popup.rs:63-112][popup-scroll-api]). Every derived quantity is
recomputed from scratch each frame; nothing is cached across frames except those
three fields.

**Behaviour state is a set of explicit finite-state machines living outside the
surfaces**, one per feature, each an `AsyncHook` running on its own tokio task and
mutating only its own fields (dimension 6). They talk to the UI exclusively through
`job::dispatch(|editor, compositor| …)` closures that run on the editor thread.
There are no shared locks in the overlay path.

The glue is an event-hook bus — `register_hook!(move |event: &mut PostInsertChar| …)`,
compile-time-typed and synchronous — plus a deferred command channel,
`EventResult::{Ignored,Consumed}(Option<Callback>)` where `Callback` is
`Box<dyn FnOnce(&mut Compositor, &mut Context)>` ([compositor.rs:9][compositor-callback]).

**Algorithm.**

```text
frame:  for each layer: rect := render_info(viewport, cursor, child.required_size(budget))
                        paint; record rect
event:  fold over layers top-down producing (consumed: bool, commands: [Callback])
        then apply commands
async:  per-feature FSM on a channel, producing dispatched closures that push/remove layers
```

**Where the behavior lives.** Surface state in the `Popup`/`Menu` structs; behaviour
state in each `impl AsyncHook` under `helix-term/src/handlers/`; transport in
`helix-event` (channels, hooks, `TaskController`/`TaskHandle` cancellation tokens).

**Degradation.** The geometry half is already assertable headlessly:
`Popup::area(viewport, editor)` computes the exact painted rect **without painting**,
and helix itself relies on that for the intersection tests
([signature_help.rs:282][sig-intersect], [handlers/completion.rs:109][handlers-completion-intersect]).
For a toolkit that must assert behaviour on a recording canvas, that is the
structural property that matters: placement must be a callable function, not a side
effect of paint. The behaviour half needs timers; on a timer-free target the FSMs
collapse to their manual-trigger paths.

Portability to a `@nogc`-leaning, value-semantics toolkit splits the same way. The
geometry half ports essentially verbatim — `Rect`, `Position`, `Open` and
`RenderInfo` are all plain data, the arithmetic is saturating `u16`, and the child
seam `required_size((u16,u16)) -> Option<(u16,u16)>` is a clean introspection hook —
provided `area()` stops mutating `self.position`. The architecture half does not:
`Box<dyn Component>` and `Box<dyn FnOnce>` would need to become sum types, a tagged
`Layer` union and a stack-command enum returned by value from the handler. That
change would also fix the `Menu::pop()` versus `Popup::remove(id)` hazard by
construction.

### 16. Shared infrastructure

The factoring is one `Popup<T>` shell, one `Menu<T>` list widget, and N content
components, with a single method as the seam:
`required_size((max_w, max_h)) -> Option<(u16,u16)>`
([compositor.rs:60-67][compositor-required-size]). `Popup` panics with
`"Component needs required_size implemented in order to be embedded in a popup"`
([popup.rs:182-185][popup-measure]) if the child does not implement it — and since
`Popup` itself does _not_ implement `required_size`, **popups cannot nest**. That is
an enforced, though apparently accidental, constraint.

What is genuinely shared: anchoring, the above/below choice, viewport clamping,
border chrome, background clear, scrollbar rendering plus half-page scroll,
`Esc`/`Ctrl-C` dismissal, auto-close, mouse-scroll and id-based identity. That set
covers `Popup<Hover>`, `Popup<SignatureHelp>`, `Popup<Menu<CompletionItem>>`,
code actions ([commands/lsp.rs:661][lsp-code-actions]), DAP variables, `:sh` output,
and the invalid-regex toast — the last anchored to a _synthetic_ `Position` two rows
above the bottom ([ui/mod.rs:170-176][ui-mod-toast]), which is possible precisely
because the anchor is a plain value.

What looks common and is correctly kept apart: `Overlay<T>`
([ui/overlay.rs:13][overlay-centred]) is a _centred_ container with a
`Box<dyn Fn(Rect) -> Rect>` size function, sharing no code with `Popup` — modal
pickers are not anchored surfaces and helix does not pretend otherwise. `Select<T>`
centres itself and embeds a `Menu` directly, bypassing `Popup`
([ui/select.rs:28][select-menu]). `Info` pins to a screen corner with its own short
arithmetic ([ui/info.rs:8-30][info-corner]). Three placement policies, zero shared
placement code — which is defensible while each is under ten lines.

What is _not_ shared and arguably should be: `Popup` and `Menu` contain two
near-identical scrollbar implementations ([popup.rs:355-384][popup-scrollbar] versus
[menu.rs:395-419][menu-scrollbar], the same `win_height²/len` thumb formula and the
same `▌`/`▐` choice), which is why `with_scrollbar(false)` exists; the file-head
`TODO` admits it ([popup.rs:29-31][popup-todo]). And the completion documentation
panel duplicates clear + border + render inline instead of being a `Popup`
([ui/completion.rs:570-579][completion-doc-paint]) — it had to, because `Popup`
cannot be anchored to a `Rect`, only to a `Position`.

The sibling-coordination story is the sharpest finding: there is **no shared
coordinator**. Signature help and completion each independently call the other's
`area()` and resolve the conflict by destroying one of the two. It is quadratic by
construction and works because n = 2.

**Algorithm.** Shell/content contract: the parent gives `(max_w, max_h)` after
subtracting its own chrome; the child returns its natural size, which _may_ exceed
the budget; the parent clamps the rect and converts the excess into scroll
(`max_offset = child_height - inner.height`, [popup.rs:345][popup-scroll-clamp]).
Sibling coordination: predicted-rect intersection, then destroy.

**Where the behavior lives.** `Component::required_size` is the shared contract,
`Popup<T>` the shared shell, `Menu<T>` plus `menu::Item::format(&Data) -> Row` the
shared list. Everything else is per-feature.

**Degradation.** The measure-with-budget / return-natural-size / parent-converts-
overflow-to-scroll contract needs nothing from any platform and works identically on
a recording canvas. Three things a canvas-first toolkit would need to design
differently: an anchor that can be a rect (so a second-order surface can be a
first-class overlay instead of inline paint), a published "chosen side", and a
sibling-coordination pass that is not pairwise.

## Named algorithms

### `Popup::render_info` — the whole placement algorithm

Reproduced from [popup.rs:126-218][popup-render-info]. All arithmetic is `u16`;
`-sat` marks `saturating_sub`.

```text
pos := editor.cursor().0 or Position(0,0)         # absolute screen cells; (0,0) if off-screen
if self.position is Some(old) and old.row == pos.row:
    pos := old                                    # freeze the column while on the same row
else:
    self.position := Some(pos)                    # re-anchor when the row changes

is_menu := type_name(contents).startsWith("helix_term::ui::menu::Menu")
borders := is_menu ? editor.menu_border() : editor.popup_border()

rel_x := pos.col ; rel_y := pos.row
can_below := viewport.height > rel_y + 6          # MIN_HEIGHT = 6
can_above := rel_y >= 6
side := (bias == Below) ? (can_below ? Below : Above)
                        : (can_above ? Above : Below)     # single unconditional fallback

max_h := (side == Above) ? rel_y : viewport.height -sat (1 + rel_y)
max_h := min(max_h, 26)                           # MAX_HEIGHT
max_w := min(viewport.width -sat 2, 120)          # MAX_WIDTH
borders := borders and max_h > 3 and max_w > 3    # chrome yields to space
if borders: max_w -= 2 ; max_h -= 2

(w, child_h) := contents.required_size((max_w, max_h))    # panics if the child returns None
w := min(w, 120)
h := borders ? min(child_h + 2, 26) : min(child_h, 26)
if borders: w += 2

# horizontal: shift only, never flip; preserve a 2-column right gutter
if viewport.width <= rel_x + w + 2:
    rel_x := viewport.width -sat (w + 2)
    w     := viewport.width -sat (rel_x + 2)

# vertical: clamp only, never shift; the anchor row is never covered
if side == Above:
    rel_y := rel_y -sat h
    area  := Rect(rel_x, rel_y, w, pos.row - rel_y)       # collapses at the top edge
else:
    rel_y := rel_y + 1
    y_max := min(viewport.bottom(), h + rel_y)
    area  := Rect(rel_x, rel_y, w, y_max - rel_y)

return RenderInfo { area, child_h, borders, is_menu }     # NOTE: `side` is not returned
```

Five properties worth naming: (1) decide-then-measure — the side determines the
height budget, so the child never influences the side; (2) `MIN_HEIGHT` is a
constant unrelated to content, so a one-row popup still flips when fewer than six
rows are free; (3) the fallback is unconditional, so with fewer than six rows on
both sides a `Below`-biased popup goes `Above` and can end up zero to two rows tall;
(4) overflow becomes scroll, never re-placement; (5) the only viewport padding is
two columns on the right.

### Second-order anchoring: completion documentation relative to the menu

From [ui/completion.rs:533-568][completion-panel-band], executed inside
`Completion::render` _after_ the menu popup has already painted.

```text
menu       := popup.area(viewport)                 # re-runs the algorithm above (mutating!)
free_right := viewport.width -sat menu.right()

if free_right > 30:
    # SIDE PANEL: anchored to the menu's right edge, top-aligned to the menu
    w := free_right ; h := viewport.height -sat menu.top()
    (rw, rh) := markdown.required_size((w, h))
    doc := Rect(menu.right(), menu.top(), min(rw, w), min(rh, h))
else:
    # FULL-WIDTH BAND: the obstacle is {cursor row} U {menu rect}
    above := min(cursor_row, menu.top()) -sat 1
    below := viewport.height -sat (max(cursor_row, menu.bottom()) + 1)   # +1 padding
    (y, avail) := (below >= above) ? (viewport.height - below, below)    # ties go below
                                   : (0, above)
    if avail <= 1: draw nothing
    doc := Rect(0, y, viewport.width, min(avail, 15))

clear_with(doc, theme["ui.popup"]); if popup_border { Block::bordered().render(doc) }
markdown.render(doc)
```

The band branch abandons anchoring entirely: the surface is pinned to a screen edge
and merely _avoids_ the anchor. The obstacle is a union of a row and a rect expressed
as two `min`/`max` calls, with no rect algebra. Ties go below. Nothing here is a
`Component` — the doc panel has no id, no events and no scroll, and exists only for
the duration of one paint.

### Sibling collision resolution by predicted-rect intersection

Two symmetric call sites, no coordinator.

```text
# opening signature help while a completion menu may exist (signature_help.rs:274-286)
sig := Popup::new(...).position(previous_anchor).position_bias(Above)
if editor_view.completion?.area(size, editor).intersects(sig.area(size, editor)):
    return                                  # the NEWCOMER declines to open
compositor.replace_or_push(SignatureHelp::ID, sig)

# opening a completion menu while signature help may exist (handlers/completion.rs:108-115)
completion_area := editor_view.set_completion(editor, items, trigger.pos, size)
sig_area        := compositor.find_id::<Popup<SignatureHelp>>(SignatureHelp::ID)?.area(size, editor)
if completion_area.intersects(sig_area):
    compositor.remove(SignatureHelp::ID)    # the INCUMBENT is destroyed
```

Both depend on `area()` being callable without painting. `Rect::intersects` is four
comparisons ([graphics.rs:273][graphics-intersects]). The asymmetry is deliberate:
completion outranks signature help. After a completion item is accepted, the callback
re-fires `trigger_signature_help(Automatic)` with the comment "In case the popup was
deleted because of an intersection w/ the auto-complete menu"
([ui/completion.rs:285-290][completion-retrigger-sig]) — the destroyed surface is
resurrected by an explicit retrigger, not by a retained overlay tree.

### Compositor event propagation with deferred stack mutation

From [compositor.rs:144-188][compositor-handle-event].

```text
callbacks := [] ; consumed := false
for layer in layers.reverse():                 # top-down
    match layer.handle_event(e, cx):
        Consumed(Some(cb)) -> callbacks.push(cb); consumed := true; BREAK
        Consumed(None)     ->                    consumed := true; BREAK
        Ignored(Some(cb))  -> callbacks.push(cb)          # continue propagating!
        Ignored(None)      -> ()
for cb in callbacks: cb(&mut self, cx)         # mutate the stack only now
return consumed
```

The `Ignored(Some(cb))` arm separates "I want to die" from "I handled this". It is
how auto-close popups vanish while the keystroke still reaches the editor, and it is
why removal never invalidates the iteration. Callbacks run in collection order —
top-down — so a higher layer's dismissal is applied before a lower layer's.

### Half-page scroll with render-time clamping

From [popup.rs:98-104][popup-scroll-api] and [:345-351][popup-scroll-clamp]. Scroll
is stored as a **count of half-pages**, not a row offset:

```text
scroll_half_page_down: n += 1
scroll_half_page_up:   n := n -sat 1
# at render, once inner.height and child_height are finally known:
max_offset := child_height -sat inner.height
half       := inner.height / 2
scroll     := min(max_offset, n * half)
n          := scroll / half   if half != 0 else n     # write the clamp back
cx.scroll  := Some(scroll)                            # handed to the child via Context
```

Storing half-pages rather than rows means the scroll position rescales automatically
when the popup is resized by a viewport change — the popup keeps "you are three
half-pages down" rather than "you are at row 17". The clamp is written back so
repeated PageDown at the bottom does not accumulate an unbounded counter. The
scrollbar thumb is `ceil(win_height² / len)` clipped to `win_height`, positioned at
`(win_height - thumb) * scroll / max(1, len - win_height)`
([popup.rs:362-364][popup-scrollbar], duplicated at
[menu.rs:399-401][menu-scrollbar]).

> [!WARNING]
> `cx.scroll` is a mutable field on the shared per-frame `Context`, set by
> `Popup::render` before rendering its child and never reset
> ([popup.rs:351][popup-scroll-clamp]); `Markdown::render` reads it
> ([markdown.rs:376][markdown-render]). The `Context` is constructed once per frame
> in `Application::render` ([application.rs:267][app-render]), so a cross-layer leak
> to any component rendered later in the same frame is _inferred_ from that
> structure — no case where it visibly misbehaves was found, and the completion
> event path in `EditorView` builds its own `Context` with `scroll: None`
> ([ui/editor.rs:1505-1509][editorview-completion-events]).

## Strengths

- Placement is a ~60-line total function of (cursor cell, viewport, child
  measurement) with no state, no observers and no platform dependency, compiling to
  integer arithmetic throughout ([popup.rs:126-218][popup-render-info]).
- `Popup::area(viewport, editor)` computes the exact rect the next paint will use
  **without painting**, and helix depends on that for two collision tests and for
  headless size prediction in `set_completion` — placement is a query, not a side
  effect of paint.
- The "anchor row is never covered" invariant is enforced structurally, by computing
  the rect's height as the gap to the anchor row rather than by a post-hoc check
  that a clamp could bypass ([popup.rs:201-211][popup-rect]).
- `EventResult::Ignored(Some(callback))` separates "I want to be destroyed" from "I
  handled this event", with stack mutation deferred until after propagation — light
  dismiss with no grab and no iterator-invalidation hazard
  ([compositor.rs:159-179][compositor-propagate]).
- Overflow becomes scroll rather than re-placement, and the scroll unit is
  half-pages rather than rows, so the persisted position is resize-invariant and is
  re-clamped at render time when the content height is finally known.
- Non-modality is expressed by omission: `Popup` does not implement
  `Component::cursor`, so no overlay steals the caret; the tooltip-versus-dialog
  distinction is one trait method.
- Timing is factored entirely out of the surfaces into per-feature `AsyncHook` state
  machines with explicit states, single-owner mutation and revalidation at every
  hop. The signature-help FSM's two subtle rules — drop `ReTrigger` while `Closed`,
  ignore a late `RequestComplete` while `Pending` — are the kind of thing a naive
  implementation gets wrong ([signature_help.rs:54-99][sig-handle-event]).
- Chrome yields to content: borders are suppressed when `max_height <= 3` or
  `max_width <= 3`, so the primitive degrades to bare content in tight space instead
  of rendering an empty frame ([popup.rs:175][popup-border-space]).
- Every feature has a zero-delay manual path alongside its debounced automatic path
  ([request.rs:118-120][request-manual]) — exactly the shape a timer-free target
  needs to reuse.
- `Rect`'s vocabulary is deliberately total: `clip_left`/`clip_top` clamp the origin
  at the far edge, `inner` returns a zero rect rather than an inverted one, and
  `intersection` saturates — all pinned by edge-case tests
  ([graphics.rs:775-807][graphics-tests]).

## Weaknesses

- An anchor can only be a point, so a surface cannot anchor to another surface. The
  completion documentation panel is therefore not a `Popup`, not a `Component`, and
  has no id, no event handler and no scroll — it is raw `clear_with` +
  `Block::bordered` + `render` inside another component's paint
  ([ui/completion.rs:570-579][completion-doc-paint]).
- The chosen side is computed and discarded; `RenderInfo` and `area()` publish only
  the rect, so downstream code re-derives the side by comparing coordinates
  ([completion.rs:551][completion-band-y]).
- `Popup::area()` takes `&mut self` and mutates the sticky anchor — the geometry
  query is not pure, despite being called from three places that treat it as one
  (including twice per frame inside `Completion::render`).
- `Menu::required_size`'s memo never hits: `self.viewport` is assigned only in
  `Menu::new` ([menu.rs:61][menu-new]) and never by `recalculate_size`, so every
  measure re-runs a pass that calls `Item::format` on every option.
- Measurement and painting use two different wrap algorithms —
  `Paragraph::required_size` runs the real `WordWrapper`
  ([paragraph.rs:131][paragraph-required-size]) while `ui::text::required_size` is a
  `height += width / max` estimate ([text.rs:53][text-required-size]) — and the
  latter sizes every `Markdown`/`Hover` popup that the former then paints.
- `Popup` does not implement `required_size`, so popups cannot nest; a nested one
  would hit the `expect("Component needs required_size implemented…")` panic
  ([popup.rs:182][popup-measure]). The constraint is real but undeclared.
- `is_menu` is decided by a runtime string match on `std::any::type_name`, a value
  Rust does not guarantee to be stable, and it selects both the theme slot and which
  border config applies ([popup.rs:137-146][popup-is-menu]).
- Two near-identical scrollbar implementations with the same thumb formula, worked
  around by a `with_scrollbar(false)` flag; the file-head `TODO` admits the
  duplication ([popup.rs:29-31][popup-todo]).
- `cx.scroll` is a mutable field on the shared per-frame `Context`, set before
  rendering a child and never reset (see the warning above).
- A network request is initiated from inside `render`:
  `self.resolve_handler.ensure_item_resolved(cx.editor, option)` fires
  `completionItem/resolve` during paint
  ([ui/completion.rs:478][completion-resolve-in-render]).
- When the cursor cannot be resolved the anchor silently degrades to cell `(0,0)`
  ([popup.rs:127][popup-render-info]) — the popup teleports to the top-left corner
  instead of closing or hiding.
- `Menu`'s close callback is `compositor.pop()` (positional) while `Popup`'s is
  `compositor.remove(id)` (targeted); if any layer sat above a bare `Menu`, the
  wrong layer would be destroyed ([menu.rs:244-247][menu-close-pop]).
- `Menu`'s "modal" mouse arm is unreachable under a `Popup`, so the shipped
  completion menu cannot be clicked to select and clicks do fall through
  ([menu.rs:238][menu-mouse], [popup.rs:262-266][popup-handle-event]).
- `auto_close` fires on `MouseEventKind::Down` **before** the containment test, so
  clicking _inside_ an auto-close popup dismisses it
  ([popup.rs:229-245][popup-autoclose-mouse]).
- `Event::Resize` is an explicit `TODO` in `Popup::handle_event`
  ([popup.rs:266][popup-resize-todo]), and `Event::FocusLost` is ignored by every
  popup — no overlay closes on terminal focus loss.
- Zero accessibility: no roles, no announcements, and because popups never claim the
  caret, an assistive technology gets no signal when one opens.
- No animation, and no geometry metadata that would enable it; no arrow or caret
  geometry of any kind.

## Key design decisions and trade-offs

| Decision                                                                                                                                                    | Rationale                                                                                                                                                                                                                                                                                                                                                                                           | Trade-off                                                                                                                                                                                                                                                                                                                                                   |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| The anchor is a single `Option<Position>` — one point in absolute screen cells — and nothing else.                                                          | Makes the anchor a plain comparable value that can be stored, inherited across a component rebuild ([signature_help.rs:270][sig-position-inherit]), synthesised from nothing for non-cursor surfaces (the invalid-regex toast anchors at `Position::new(height-2, 0)`, [ui/mod.rs:170-176][ui-mod-toast]) and compared cheaply for the sticky-row heuristic. It keeps the placement function total. | A surface cannot be anchored to another surface. That is why the completion documentation panel could not be a `Popup` and had to be open-coded as clear + border + render inside `Completion::render`, with no id, no events and no scroll — the most consequential limitation in the subject, following directly from the anchor type.                    |
| Choose the side first from a fixed six-row availability test, then measure the content within the budget that side allows.                                  | Breaks the circular dependency between "how tall am I" and "which side do I go on" with zero iteration: one `required_size` call per frame, no re-measure, no second pass. The child is told the real budget rather than an optimistic one.                                                                                                                                                         | `MIN_HEIGHT = 6` has nothing to do with the content, so a two-row popup flips above merely because five rows are free below; and the fallback is unconditional, so with fewer than six rows on both sides a `Below`-biased popup goes `Above` and can end up zero to two rows tall. No "pick the larger side" scoring exists.                               |
| Coordinate sibling surfaces by testing predicted rects for intersection and destroying one, rather than by nesting, re-placing or an overlay tree.          | Requires no shared coordinator, no ownership graph and no re-layout pass — only that placement be queryable without painting. Two lines of policy at each of two call sites replace a subsystem, and the priority is legible: completion outranks signature help.                                                                                                                                   | Information is lost rather than relocated: triggering completion loses signature help entirely, and it returns only because the accept path explicitly re-fires `trigger_signature_help`. The approach is quadratic in surfaces and does not survive n > 2. It also makes "is this surface visible" depend on the geometry of an unrelated surface.         |
| Overlays never claim the terminal cursor: `Popup` simply does not implement `Component::cursor`.                                                            | One omitted method expresses "non-modal, the text is still where you are typing" with no modality flag, no focus stack and no restoration logic. Pickers and prompts, which should own the caret, implement it.                                                                                                                                                                                     | In a terminal the reported caret is the only channel an assistive technology can follow, so opening a completion menu or signature help produces no signal an AT can observe — and helix has no accessibility code to mitigate it. `CursorKind::Hidden` ([graphics.rs:62][graphics-cursorkind]) is the primitive that would fix it, and no overlay uses it. |
| Let a component request its own removal without consuming the event: `EventResult::Ignored(Some(callback))`, with all callbacks executed after propagation. | Solves light dismiss in a no-grab environment: the popup dies and the keystroke still reaches the editor in the same tick, and because stack mutation is deferred past the propagation loop, removal cannot invalidate the iteration. It costs one enum variant.                                                                                                                                    | The callback is `Box<dyn FnOnce(&mut Compositor, &mut Context)>` — arbitrary code with full mutable access to the stack. That is how `Menu` ends up closing itself with the positional `compositor.pop()` while `Popup` uses the targeted `compositor.remove(id)`: the type permits both and they are not equivalent.                                       |
| Recompute placement from scratch every frame inside `render`, with no cache, no invalidation and no observers.                                              | Eliminates a class of stale-geometry bugs and makes "the popup follows the cursor" free. It also makes placement a callable function evaluable outside paint, which the collision tests and headless size prediction depend on.                                                                                                                                                                     | The cost is paid every frame and is not small: `Menu::required_size`'s memo never hits, `Completion::render` runs the whole pipeline twice per frame, and `Markdown` re-parses its source in both `required_size` and `render`. And `area()` takes `&mut self`, so the geometry query mutates the sticky anchor.                                            |
| Decide presentation details (theme slot, which border config applies) by string-matching the child's Rust type name.                                        | Avoided adding a variant or tag to the popup's public API for what was treated as a styling detail; `Component::type_name` already existed for the compositor's type-directed `find`/`remove_type`.                                                                                                                                                                                                 | `std::any::type_name` has no stability guarantee, so a module rename would silently change the rendering of every completion menu. The same string-identity approach in `Compositor::find`/`remove_type` makes component identity untyped throughout, and a `TODO: consistently style menu` sits on the lines consuming the result.                         |

## Sources

Primary sources, all read at `14d6bc0febed9c692048271a8ae2362ac969c6e0`:

- [`helix-term/src/ui/popup.rs`][popup-render-info] — the anchored primitive:
  constants, `RenderInfo`, the builder chain, `render_info`, `handle_mouse_event`,
  `handle_event`, `render`, the scrollbar.
- [`helix-term/src/compositor.rs`][compositor-struct] — the `Component` trait,
  `EventResult`/`Callback`, the layer vector, propagation with deferred mutation,
  `render`, `cursor`, and the id/`type_name` identity helpers.
- [`helix-term/src/ui/menu.rs`][menu-required-size] — the list widget: measurement,
  key bindings, the smart-tab de-conflict, the positional close callback, the second
  scrollbar.
- [`helix-term/src/ui/completion.rs`][completion-panel-band] — second-order
  anchoring, the panel-versus-band switch, the inline documentation paint, the
  signature-help resurrection.
- [`helix-term/src/ui/editor.rs`][editorview-completion-events] — the completion's
  escape from the compositor: the field, the hand-rolled event arm with its
  synthetic `Enter`, and `FocusLost` consumption.
- [`helix-term/src/handlers/signature_help.rs`][sig-handle-event] and
  [`helix-term/src/handlers/completion/request.rs`][request-fold] — the per-feature
  timing state machines, the debounce values, revalidation, and the collision tests.
- [`helix-event/src/debounce.rs`][debounce-run] — the `AsyncHook` substrate.
- [`helix-view/src/graphics.rs`][graphics-rect] — `Rect`, its total clip/inner/
  intersection semantics, `CursorKind`, and the geometry tests.
- [`helix-view/src/editor.rs`][editor-cursor] — `Editor::cursor`, `CursorCache`, and
  the popup/menu border configuration.
- [`helix-term/src/application.rs`][app-render] — the frame driver, cursor
  reporting, and the explicit discard of key-release events.

Related pages: [`./index.md`](./index.md) (umbrella),
[`./concepts.md`][concepts] (shared vocabulary),
[`./comparison.md`](./comparison.md) (capstone),
[`./features-people-forget.md`](./features-people-forget.md),
[`./sparkles-baseline.md`](./sparkles-baseline.md),
[`./proposal.md`](./proposal.md). Nearest siblings in the terminal category:
[`./neovim-floats.md`](./neovim-floats.md),
[`./nvim-completion.md`](./nvim-completion.md), [`./nui.md`](./nui.md),
[`./textual.md`](./textual.md), [`./ratatui.md`](./ratatui.md),
[`./tmux-popup.md`](./tmux-popup.md), [`./notcurses.md`](./notcurses.md),
[`./turbo-vision.md`](./turbo-vision.md),
[`./emacs-posframe.md`](./emacs-posframe.md). Toolkit context:
[`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/containers.md`](../../specs/ui/containers.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md),
[`../../specs/ui/backends.md`](../../specs/ui/backends.md),
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md).

<!-- References -->

[concepts]: ./concepts.md
[helix-repo]: https://github.com/helix-editor/helix
[helix-docs]: https://docs.helix-editor.com/
[popup-consts]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L18
[popup-renderinfo]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L22
[popup-todo]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L29
[popup-struct]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L32
[popup-position]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L59
[popup-ignore-esc]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L86
[popup-scroll-api]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L98
[popup-area]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L122
[popup-render-info]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L126
[popup-anchor-hysteresis]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L128
[popup-is-menu]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L137
[popup-flip]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L152
[popup-budget]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L168
[popup-border-space]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L175
[popup-measure]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L182
[popup-shift]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L196
[popup-rect]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L201
[popup-mouse]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L220
[popup-autoclose-mouse]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L229
[popup-contain]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L238
[popup-handle-event]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L262
[popup-resize-todo]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L266
[popup-esc-optout]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L273
[popup-close-fn]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L277
[popup-content-first]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L282
[popup-ignored-some]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L301
[popup-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L317
[popup-area-assign]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L324
[popup-style]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L327
[popup-borders-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L340
[popup-scroll-clamp]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L345
[popup-scrollbar]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L355
[popup-id]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/popup.rs#L387
[compositor-callback]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L9
[compositor-eventresult]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L13
[compositor-cursor-default]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L56
[compositor-required-size]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L60
[compositor-type-name]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L69
[compositor-struct]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L78
[compositor-replace-or-push]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L119
[compositor-remove]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L131
[compositor-find]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L139
[compositor-handle-event]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L144
[compositor-propagate]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L159
[compositor-callbacks]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L177
[compositor-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L184
[compositor-cursor]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L190
[compositor-remove-type]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/compositor.rs#L205
[menu-new]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L61
[menu-recalc]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L137
[menu-cap]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L156
[menu-mouse]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L238
[menu-close-pop]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L244
[menu-smart-tab]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L249
[menu-keys]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L264
[menu-pageup]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L282
[menu-required-size]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L327
[menu-scrollbar]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/menu.rs#L395
[completion-field]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L43
[editorview-mouse-moved]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L1207
[editorview-completion-events]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L1502
[editorview-synthetic-enter]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L1512
[editorview-focuslost]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L1599
[editorview-render-completion]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/editor.rs#L1732
[completion-retrigger-sig]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L285
[completion-ignore-esc]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L295
[completion-resolve-in-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L478
[completion-popup-area]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L533
[completion-panel-band]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L534
[completion-band-y]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L551
[completion-doc-cap]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L567
[completion-doc-paint]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/completion.rs#L570
[handlers-completion-show]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L96
[handlers-completion-intersect]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L109
[handlers-completion-trigger]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L118
[handlers-completion-filter]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L178
[handlers-completion-postcommand]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L200
[handlers-completion-hooks]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion.rs#L245
[sig-state]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L24
[sig-timeout]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L32
[sig-handle-event]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L54
[sig-retrigger-closed]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L67
[sig-late-reply]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L77
[sig-position-inherit]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L270
[sig-intersect]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L274
[sig-trigger-char]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L291
[sig-mode-switch]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L331
[sig-hooks]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/signature_help.rs#L353
[request-fold]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L87
[request-cancel]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L102
[request-manual]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L118
[request-delete-text]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L126
[request-timeouts]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L135
[request-revalidate]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L169
[request-aggregate]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/request.rs#L269
[resolve-debounce]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/handlers/completion/resolve.rs#L127
[debounce-trait]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-event/src/debounce.rs#L15
[debounce-run]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-event/src/debounce.rs#L38
[debounce-send]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-event/src/debounce.rs#L62
[graphics-cursorkind]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L56
[graphics-rect]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L118
[graphics-clip]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L164
[graphics-inner]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L212
[graphics-intersection]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L250
[graphics-intersects]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L273
[graphics-tests]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/graphics.rs#L775
[editor-completion-timeout]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs#L1200
[editor-popup-border-default]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs#L1232
[editor-border-getters]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs#L1474
[editor-cursor]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs#L2424
[editor-cursorcache]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs#L2678
[app-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/application.rs#L261
[app-cursor]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/application.rs#L286
[app-key-release]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/application.rs#L724
[open-enum]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/commands.rs#L3817
[lsp-code-actions]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/commands/lsp.rs#L661
[ui-mod-toast]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/mod.rs#L170
[text-required-size]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/text.rs#L53
[markdown-render]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/markdown.rs#L369
[markdown-required-size]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/markdown.rs#L382
[overlay-centred]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/overlay.rs#L13
[info-corner]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/info.rs#L8
[select-menu]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/select.rs#L28
[sig-separator]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/lsp/signature_help.rs#L147
[hover-width]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/lsp/hover.rs#L110
[hover-keys]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/lsp/hover.rs#L89
[diagnostics-connectors]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/text_decorations/diagnostics.rs#L68
[paragraph-required-size]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-tui/src/widgets/paragraph.rs#L131
[buffer-index-of]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-tui/src/buffer.rs#L272
[terminal-draw]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-tui/src/terminal.rs#L186
[crossterm-kitty]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-tui/src/backend/crossterm.rs#L184
