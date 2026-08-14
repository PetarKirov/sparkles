# Emacs posframe + company-mode (Emacs Lisp)

Two halves of one anchored-overlay story welded together in company 1.1.0: `posframe.el` supplies a
child-frame surface whose entire placement policy is a named pure function of a flat measured record,
and company-mode supplies the interaction machine plus a second, surface-free renderer that draws the
same popup by overwriting the host buffer's own displayed text.

| Field         | Value                                                                                                                                                                             |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Emacs Lisp                                                                                                                                                                        |
| License       | GPL-3.0-or-later (posframe ships through GNU ELPA; company-mode is FSF-copyright GPLv3+)                                                                                          |
| Repository    | [`tumashu/posframe`][posframe-repo] + [`company-mode/company-mode`][company-repo]                                                                                                 |
| Documentation | Docstrings only — `posframe-show`'s docstring is the poshandler specification; `company-frontends`' docstring is the frontend-command specification. No separate manual was read. |
| Category      | Terminal / GUI hybrid                                                                                                                                                             |
| Surface model | Both — the same row model is painted either into a real child frame (an OS surface on a graphical display) or spliced into the host buffer's own cell grid                        |
| Revision read | posframe `74c8c56131ed866db47ae4191364b72dd4852456` (v1.5.2); company-mode `1cc907ac9e46ae4209eb5a341131787e0c678406` (1.1.0)                                                     |

> [!IMPORTANT]
> Nothing here was executed. No Emacs was launched, no posframe was displayed, and neither test suite
> was run; every claim below is read from source at those two revisions. posframe carries **no test
> suite** at this revision — only `posframe-benchmark.el` — so its placement arithmetic is pinned by
> no assertion, upstream's or this survey's. Emacs' own C/Lisp primitives (`posn-at-point`,
> `posn-col-row`, `window-text-pixel-size`, `set-frame-position`, `redirect-frame-focus`,
> `tty-child-frames`) were not read; statements about what they do are inferred from how these two
> packages use them and are flagged where that matters.

## Overview

### What it solves

posframe answers one question — _how do I show an arbitrary buffer in a small floating box near a
point in another buffer_ — for a large population of Emacs packages with wildly different placement
wishes. Its answer is not an option surface but a contract: `posframe-show` measures roughly
twenty-five facts about the parent frame, the window, the anchor point, the mouse and the chrome,
packs them into one flat plist, and hands that plist to a _poshandler_, whose docstring states the
whole design:

> POSHANDLER is a function of one argument returning an actual
> position. Its argument is a plist of the following form:

— `posframe.el:193-194` ([`posframe-show` docstring][pf-poshandler-doc]); the plist that follows at
`:196-222` is the complete input vocabulary, all plain numbers and objects, with no callbacks.

company-mode answers the interaction half, and since 1.1.0 ships **two** surfaces over one model. The
default value of `company-frontends` picks `company-childframe-unless-just-one-frontend` when
`window-system` is one of `ns`/`mac`/`w32`/`pgtk` or `emacs-major-version` exceeds 30, and
`company-pseudo-tooltip-unless-just-one-frontend` otherwise ([`company.el:220-226`][co-frontends]).
Below that fork, everything is shared: `company--create-lines` renders the candidate list into
pre-padded, face-propertized strings, and the two frontends either join them with newlines and post
them to `posframe-show`, or splice them into the buffer's own visual lines.

That second path is what makes this subject worth reading for a single-surface toolkit.
`company-pseudo-tooltip-*` is a complete anchored overlay — flip-above, horizontal shift, scroll
offsets, scrollbar thumb, selection, mouse hit testing — implemented with no overlay surface at all:
it reads the visual lines the popup will cover, splices the popup's rows into their middles, blanks
the originals, and puts the whole composited block on one overlay's `before-string`. It is cell
compositing over an existing grid, and it runs on a TTY today.

### Design philosophy

Three commitments recur in both packages.

**Placement is a value transformation, not a protocol.** `posframe-run-poshandler` memoizes its entire
call on structural equality of the input record:

> (if (equal info posframe--last-poshandler-info)
> posframe--last-posframe-pixel-position

— `posframe.el:942-943` ([`posframe-run-poshandler`][pf-run-poshandler]). Recomputation is skipped
because the input compares equal, not because a dirty flag said so.

**Capability is a predicate over values, not a display-type test.** `posframe-workable-p` accepts a
terminal that has child frames:

> (and (>= emacs-major-version 26)
> (not noninteractive)
> (not emacs-basic-display)
> (or (display-graphic-p)
> (featurep 'tty-child-frames))

— `posframe.el:132-139` ([`posframe-workable-p`][pf-workable]). The consumer calls the predicate and
decides; the childframe frontend raises a `user-error` when the answer is no rather than degrading
silently ([`company-childframe.el:219`][cf-frontend]).

**A missing layering primitive is paid for in coordination.** company's in-grid popup has no
[top layer][concepts] to hoist into, so it picks a global integer and documents the arms race:

> ;; Beat outline's folding overlays.
> ;; And Flymake (53). And Flycheck (110).
> (overlay-put ov 'priority 111)

— `company.el:4464-4466` ([`company-pseudo-tooltip-unhide`][co-tooltip-unhide]).

## How it works

The posframe half is a five-stage pipeline, all of it plain data between stages:

```text
posframe-show
  measure  -> info plist (~25 keys: :position :font-height :font-width :posframe-width/-height
                          :parent-frame-width/-height :parent-window-* :mouse-x/-y
                          :mode-line-height :minibuffer-height :header-line-height :tab-line-height …)
  select   -> posframe--get-valid-poshandler   ; :poshandler, else by the TYPE of :position
  run      -> posframe-run-poshandler          ; equal-memo on the whole plist
  resolve  -> posframe--calculate-new-position ; only when :ref-position is present
  apply    -> posframe--set-frame-position     ; guarded; skipped when nothing changed
```

`posframe--get-valid-poshandler` dispatches the default off the anchor's type: an integer buffer
position gets `posframe-poshandler-point-bottom-left-corner`, a cons of two integers gets
`posframe-poshandler-absolute-x-y`, anything else is an error unless the caller supplies a handler
([`posframe.el:953`][pf-valid-poshandler]). Twenty builtin handlers exist across three reference
frames — `frame-*`, `window-*`, `point-*` — and none is long; several are a single literal, such as
`posframe-poshandler-frame-top-right-corner`, whose body is `'(-1 . 0)`
([`posframe.el:1363`, returning at `:1371`][pf-top-right]).

The company half is a command-loop machine plus a row renderer:

```text
post-command  -> arm one-shot idle timer (company-idle-delay)
timer         -> compute candidates -> session record (14 buffer-locals) -> install keymap
frontends     -> company-call-frontends(cmd) for cmd in
                 {show, hide, update, pre-command, post-command, unhide, select-mouse}
company--create-lines(selection, limit) -> (left-margin-size . [row strings])
   childframe frontend : mapconcat rows "\n" -> posframe-show(:poshandler company-childframe-poshandler)
   pseudo-tooltip      : splice rows into the covered visual lines -> one overlay before-string
pre-command   -> uninstall keymap; abort unless company--should-continue(this-command)
```

The in-grid compositor is the interesting one, so here it is at the step level
([`company-pseudo-tooltip-show`][co-tooltip-show] and [`company--replacement-string`][co-replacement]):

```text
1  height = company--pseudo-tooltip-height()        ; SIGNED; negative means above
   if height < 0: row += height - 1                 ; move the start row up
2  move-to-window-line row                          ; returns < row at end-of-buffer -> nl flag
3  company-buffer-lines                             ; ONE entry per SCREEN row; empty string for
                                                    ; each extra visual row a physical line occupies
4  company-plainify                                 ; expand tabs to the next stop using accumulated
                                                    ; display width; fold `line-prefix` into the text
5  pxCol = (col - hscroll) * fontWidth
   if popupPxWidth > windowPxWidth - pxCol: pxCol -= excess          ; horizontal shift
   for each covered line: company-modify-line(old, newRow, pxCol)
       = pixelSubstring(old, 0, pxCol) ++ newRow ++ pixelSubstring(old, pxCol + pixelWidth(newRow))
       = old, UNCHANGED, when newRow is nil
   rows beyond the covered lines: pxCol of blank ++ row
6  terminate each emitted line with a faced newline (`:extend t`)   ; background reaches the edge
7  overlay: before-string = block, display = "", line-prefix = "", priority = 111, window = selected
```

> [!NOTE]
> Step 5's "return `old` unchanged" branch is a deliberate identity preservation, not an optimization:
> the comment at `company.el:4015-4016` says re-deriving an equal line through the pixel-substring path
> re-emits fractional-width padding for double-width characters, which visibly blinks on every
> keystroke even though nothing changed ([`company-modify-line`][co-modify-line]).

The `nl` flag in step 2 is the end-of-buffer answer: when `move-to-window-line` returns less than the
requested row there is no line below to overwrite, so the replacement string is prefixed with a
fabricated `" \n"` whose first character carries a `cursor` text property
([`company.el:4396`][co-tooltip-show], consumed at [`:4121-4128`][co-replacement]). A cell-grid
toolkit meets the same case whenever the anchor sits on the last row: the rows the overlay composites
into have to be synthesised, not assumed.

## The analysis spine

### 1. Anchor model

Both packages reduce the anchor to a plain comparable value and convert it to screen coordinates
_inside_ the placement function rather than at the call site. posframe's `:position` is a loose sum
type: an integer buffer position, a cons of two pixel integers, or some other type for which the
caller must supply a poshandler ([`posframe.el:186-189`][pf-position-doc]). Inside
`posframe-poshandler-point-1` the integer is resolved with `posn-at-point` and then reduced by
subtracting `posn-object-x-y` from `posn-x-y` — a subtraction that exists so the [anchor rect][concepts]
is the character cell rather than a position inside a display-property object, with the comment
citing a flycheck conflict ([`posframe.el:1247-1257`][pf-point-1]).

company's anchor is purer: `company--col-row` yields an integer `(col . row)` cell pair, and the
popup anchors not to point but to the **start of the prefix** —
`company-pseudo-tooltip-show-at-point` subtracts `column-offset` and clamps at zero
([`company.el:4427-4430`][co-show-at-point]). There is one popup per buffer, held in a single
buffer-local overlay variable ([`:4350`][co-tooltip-overlay]), reused by every trigger. The anchor is
re-derived from scratch in every `post-command`; a separate cheap comparable tuple,
`company-pseudo-tooltip-guard` — `(prefix start, beginning-of-visual-line, window-width, (text between
point and the overlay . end-of-line overhang))` — decides whether the geometry actually changed
([`:4482`][co-tooltip-guard]).

Neither package has a [virtual anchor][concepts] or a detached trigger: the anchor is always derived
from point.

**Algorithm.** `anchorCell(point)` takes the **column** from `posn-col-row` and the **row** from
`posn-actual-col-row`, then adds `window-hscroll`, subtracts the line-number margin, and mirrors the
column under RTL ([`company.el:1125-1143`][co-posn-col-row]).
`anchorPixel(point) = (windowInsideLeft + posnX - posnObjectX + xOffset, windowTop + tabLineH +
headerLineH + posnY - posnObjectY + yOffset)`. Popup anchor `= anchorCell - (prefixLength +
leftMarginSize)`, clamped at zero.

**Where the behavior lives.** Library code entirely. The only platform primitives are
`posn-at-point` / `posn-col-row` / `posn-actual-col-row`, which are queries against the last
redisplay.

**Degradation.** The anchor pipeline survives every degradation this survey cares about: it is
integer cells throughout and runs identically with no OS window, no hover and no sub-cell precision.
The only pixel-dependent parts — `posn-object-x-y` and the font height sampled at the anchor —
collapse to a constant line height. With no script, the anchor must be resolved at emit time, which
is what both packages do anyway; neither ever re-measures asynchronously.

### 2. Placement model

posframe enumerates twenty named poshandlers across three reference frames, with centre, top-centre,
bottom-centre and four-corner variants (docstring list at `posframe.el:229-249`, implementations
`:1214-1547`). The result is an `(x . y)` pixel pair in the parent frame's coordinate space, and the
**sign carries the alignment**: a negative coordinate means "measured from the far edge". When a
`refposhandler` is in play, `posframe--calculate-new-position` resolves the negative into an absolute
by adding the parent size and subtracting the popup size ([`posframe.el:965-980`][pf-calc-position]).

> [!NOTE]
> The exact semantics of a negative coordinate passed to Emacs' `set-frame-position` were not
> confirmed against Emacs source; they are inferred from posframe's own handling of the value.

[Flip][concepts] exists in exactly one place. `posframe-poshandler-point-1` computes
`y-bottom = y-top + fontHeightAtAnchor`, then picks `y-top - popupHeight` when
`y-bottom + popupHeight > frameHeight`, with an `upward` variant that inverts the test to prefer
above whenever above fits ([`posframe.el:1260-1266`][pf-point-1]). The cross axis gets clamp only —
`(max 0 (min x (- xmax posframe-width)))` at `:1261`, i.e. [shift][concepts] without flip. There is no
preferred-side list, no fallback ordering and no auto-placement search: a poshandler is one policy,
chosen by name.

Viewport insets are **first-class inputs**, not discoveries: the `frame-bottom-*` handlers subtract
`:mode-line-height` and `:minibuffer-height` as supplied in the info plist
([`posframe.el:1400`][pf-bottom-left] and its neighbours). The one content-aware policy is
`posframe-poshandler-frame-top-left-or-right-other-corner`, which puts the popup on the side of the
frame the current window is _not_ on, deciding by comparing the window's centre to the frame's
([`posframe.el:1373`][pf-other-corner]).

company's placement is a single axis-split policy: vertical is flip (below preferred, above on
overflow), horizontal is shift-and-clamp. `company--pseudo-tooltip-height` returns a **signed** row
count whose sign is the side ([`company.el:4366-4377`][co-tooltip-height]). The horizontal shift
happens in pixels inside `company--replacement-string`: when the popup's pixel width exceeds the
remaining window width, the popup's left pixel column is decremented by the excess
([`:4096-4097`][co-replacement]). RTL is handled — and only handled — by mirroring the column in
`company--posn-col-row`, whose test is marked `:expected-result :failed` on graphical displays and
passing on a TTY ([`test/frontends-tests.el:63-78`][t-rtl]).

Neither package has multi-monitor handling, a work-area concept, safe-area insets, or IME /
virtual-keyboard avoidance. The viewport is the Emacs frame.

**Algorithm.**

```text
posframe point flip:  y = (yBottom + H > frameH) ? yTop - H : yBottom
                      upward variant: y = (yBottom - H > 0) ? yTop - H : yBottom
                      x = clamp(anchorX, 0, frameW - W)

company above/below:  lines = row of point within the window
                      below = windowH - 1 - lines
                      if below < min(company-tooltip-minimum, candidateCount) and lines > below
                          height = -(max 3 (min limit lines))          ; above
                      else
                          height =  (max 3 (min limit below))          ; below
                      side = sign(height); if above, row += height - 1

company horizontal:   pxCol = (col - hscroll) * fontW
                      if popupPxW > windowPxW - pxCol: pxCol -= excess
                      col clamped >= 0
```

**Where the behavior lives.** Pure library code, arithmetic on plain numbers, in both packages.

**Degradation.** company's version is integer cells except for the one pixel shift, which reduces to
a cell shift on a TTY because `company--string-width` already falls back to `string-width` there
([`company.el:3428-3432`][co-string-width]). The `max 3` in the height policy means the popup will
overflow the window bottom rather than fail to appear — a deliberate "accept clipping over no-show"
fallback that a single-surface toolkit needs an explicit answer for. With no script, there is no
flip: the side must be baked at emit time from the anchor row, which is what company computes anyway.
The Android soft-keyboard case maps onto posframe's `:minibuffer-height` / `:mode-line-height`
pattern — an inset passed **in**, never discovered.

### 3. Collision & geometry engine

There is no engine. Neither package has overflow detection as a service, clipping-ancestor discovery,
scroll containers, transforms or observers. Each poshandler open-codes its own comparison against
`:parent-frame-width` / `:parent-frame-height`; company open-codes one comparison against the window
height and one against the window width. Tracking is caller-driven polling through Emacs'
`post-command-hook`: the childframe frontend's `post-command` case simply calls
`company-childframe-show` again — a full re-place on every keystroke
([`company-childframe.el:211-227`][cf-frontend]).

Everything interesting is therefore in the caching, and posframe has four independent memo layers:

1. `posframe-run-poshandler` skips the handler entirely on `(equal info last-info)`
   ([`:942`][pf-run-poshandler]).
2. `posframe--set-frame-position` skips `set-frame-position` when the position **and** the parent size
   **and** — for negative coordinates only — the displayed size are unchanged ([`:987-996`][pf-set-position]).
   The size term is load-bearing: an edge-relative coordinate resolves against the popup's own size,
   so caching on position alone would leave a grown popup mispositioned.
3. `posframe--create-posframe` reuses the child frame unless the **construction** arguments changed,
   comparing a 16-element list by `equal` — and that list includes `(display-graphic-p)` itself, so a
   frame created on a TTY is rebuilt when the same buffer later appears on a graphical frame
   ([`:654-669`][pf-args-list], reuse test at [`:707-713`][pf-reuse]).
4. `posframe--get-font-height` memoizes the font height sampled at the anchor position
   ([`:590`][pf-font-height]).

Overlay lookup is a linear scan of `frame-list` matching a frame parameter
([`posframe--find-existing-posframe`, `:811`][pf-find-existing]) — a filter over all surfaces, not a
tree.

Sub-cell precision is where company does its most unusual work. `company--string-width` is
`ceil(pixelWidth / fontWidth)` on a graphical display and `string-width` on a TTY
([`:3428`][co-string-width]). To make a CJK run that is 3.4 cells wide occupy exactly four cells,
`company--clean-string` counts the rounding error in pixels and appends that many
`ZERO WIDTH NO-BREAK SPACE` characters carrying `display (space :width (errorPixels))` — the sub-cell
error is materialised as an explicit, countable pad character, and the tests pin the exact counts
([`:3948-3985`][co-clean-string]; [`test/frontends-tests.el:310-349`][t-multiwidth]).
`company-safe-pixel-substring` does a pixel-exact cut by walking characters in a reused scratch buffer,
calling `window-text-pixel-size` per character and padding both ends with fractional-width spaces
([`:3435-3506`][co-safe-pixel-substring]) — which is why `company--with-face-remappings` keeps two
scratch buffers permanently alive with the parent's `face-remapping-alist` and display table copied in
([`:3369-3392`][co-face-remappings]).

Three measurement details are worth naming, because each is an off-by-N waiting to happen.
`company--window-width` subtracts the continuation-glyph column when fringes are absent, the
`display-line-numbers` margin, and a display-table newline glyph
([`company.el:4037-4054`][co-window-width]) — each of which silently steals usable columns from the
overflow test. When the anchor's own line wraps, the overlay's start is nudged down one visual line
without rebuilding the popup, and the comment names the trade ("Sleight of hand … don't update the
popup's background. This seems just non-annoying enough to avoid the work required for the latter",
[`:4502-4509`][co-tooltip-frontend]). And under `visual-line-mode`, a space or tab immediately before
the overlay start causes a newline to be prepended to the composited block, because a trailing space
is a wrap opportunity and the popup would otherwise be drawn on the anchor's own visual row
([`:4468-4471`][co-tooltip-unhide]).

posframe ships `posframe-benchmark.el`, which times the fourteen primitives it depends on
(`posn-at-point`, `mouse-position`, `set-frame-parameter`, `redraw-frame`, …)
([`posframe-benchmark.el:34`][pf-benchmark]). No benchmark was run here; its existence is reported as
evidence that the author treated per-keystroke placement cost as the real risk.

**Algorithm.**

```text
cellWidth(s) = graphical ? ceil(pixelWidth(s) / fontWidth) : terminalStringWidth(s)

padding:  for each multibyte run r
              addPixels += fontWidth * cellWidth(r) - pixelWidth(r)
              addLength += cellWidth(r) - charCount(r)
          append addLength U+FEFF characters bearing display width addPixels

reposition guard:
    skip if newPos == lastPos
        and parentSize == lastParentSize
        and (bothCoordsNonNegative or displayedSize == lastDisplayedSize)
```

**Where the behavior lives.** Library code plus one platform primitive
(`window-text-pixel-size` / `buffer-text-pixel-size`, implemented in Emacs' C redisplay).

**Degradation.** On a TTY the whole pixel apparatus collapses to `string-width` and the code still
works: within this subject the pixel path is an _approximation of_ the cell path, not the reverse.
With no sub-cell precision `company--clean-string` becomes a no-op and the pad characters disappear.
With no measurement at emit time, the popup's width must come from the model — max candidate width
clamped by the min/max options — which is exactly what `company--create-lines` computes before any
measurement ([`:4210-4232`][co-create-lines]). There are no observers to lose.

### 4. Arrow / caret geometry

**Not applicable — and the absence is load-bearing rather than an oversight.** Neither package has an
arrow, tail, beak or caret.

posframe's only decoration is a uniform border: `:border-width` / `:border-color` map onto the child
frame's `internal-border-width` and `child-frame-border-width` plus the `child-frame-border` face,
with a comment pointing at Emacs bug#45620 for why two border knobs exist
([`posframe.el:640-650`][pf-border]). On a TTY child frame the border is expressed by **not** setting
`undecorated`, so the terminal frame code draws it in cells
([`:748-750`][pf-undecorated]).

company's pseudo-tooltip has no border at all. It has margins (`company-tooltip-margin`, one column
each side by default) and an optional right-edge scrollbar that is `0.4` of a column on a graphical
display and one full column on a TTY — `company--right-margin` refuses the fractional form unless
`display-graphic-p` ([`company.el:312`][co-scrollbar-width]; [`:4296-4308`][co-right-margin]).

The nearest thing to arrow-geometry-as-data is genuinely useful: `company--create-lines` returns
`(cons left-margin-size lines)` — the popup's **own** left margin width, returned so the caller can
shift the box left by that many columns and land the candidate text exactly on the buffer's prefix
([`:4273-4275`][co-create-lines]). The pseudo-tooltip consumes it as a column count
([`:4416-4421`][co-tooltip-show]); the childframe multiplies it by `default-font-width` and also
subtracts the border width and any `after-string` overlay width at point
([`company-childframe.el:100-108`][cf-margin]). The alignment offset is data, passed out of the
renderer into the placer.

**Algorithm.** No arrow. The alignment substitute is
`popupLeftCol = anchorCol - prefixLength - leftMarginSize`, clamped at zero, where
`leftMarginSize = max(tooltipMargin, max over rows of the formatted margin width)`.

**Where the behavior lives.** The border is a platform concern for posframe (frame parameters) and
absent for company. The alignment offset is library code in both.

**Degradation.** An arrow in a cell grid costs a whole row or column plus a glyph, and neither of
these two overlay systems pays it. The reading for a cell-grid toolkit is that the _alignment offset_
substitutes for the arrow: aligning the popup's content column with the anchor's column reads as
"this belongs to that" without a pointer glyph. Drop shadows and corner radii being unavailable costs
nothing here because neither package uses them; a one-cell border is the whole affordance, and
posframe already treats it as a per-target decision.

### 5. Trigger semantics

posframe has **no trigger semantics at all** — it is a bare imperative `posframe-show` /
`posframe-hide` API with no notion of what caused the show. That separation is itself the finding:
the surface library knows nothing about interaction, so every trigger policy lives in the consumer.

company's triggers are three, none of them hover:

1. an idle timer armed in `post-command-hook` after any command in `company-begin-commands` (the
   self-insert family by default) ([`company.el:2726-2734`][co-post-command]);
2. an explicit command (`company-complete`, `company-manual-begin`);
3. the `company-idle-delay` = `t` synchronous path, gated by `company--should-complete`, which refuses
   when the buffer is read-only, an `overriding-local-map` is active, the user is mid-key-sequence
   (`(keymapp (key-binding (this-command-keys-vector)))`), or a region is active
   ([`:1737-1744`][co-should-complete]).

There is no hover trigger anywhere. The mouse participates only inside an already-open popup, and the
wiring is the race lesson: `[down-mouse-1]`, `[down-mouse-3]`, `[up-mouse-1]` and `[up-mouse-3]` are
all bound to `ignore` in `company-active-map` so neither the press nor the release can move point or
run a foreign command, and only the synthesized `[mouse-1]` / `[mouse-3]` click runs
`company-complete-mouse` / `company-select-mouse` ([`:901-916`][co-active-map]). When the click lands
outside the popup rectangle, `company-select-mouse` aborts **and replays**: it pushes
`this-command-keys` back onto `unread-command-events` and clears them
([`company--unread-this-command-keys`, `:3566-3571`][co-unread-keys]), so the click dismisses the
popup and then does whatever it would otherwise have done.

Multiple triggers cannot race, because there is exactly one event source (the command loop) and one
arming point (`post-command-hook`), and `company-pre-command` cancels any pending timer
unconditionally. Composition races are prevented statically instead: `company-frontends-set` rejects a
value containing two tooltip frontends or two preview frontends, and _reorders_ the list so preview
frontends come last ([`:192-218`][co-frontends-set]).

**Algorithm.**

```text
post-command: if session active            -> recompute
              else if idleDelay is a number and not defining-kbd-macro
                   and shouldBegin(thisCommand)
                                           -> arm one-shot timer(delay) capturing
                                              (buffer, window, modifiedTick, point)
pre-command:  cancel timer
              if not companyKeep(cmd) and not shouldContinue(cmd) -> abort
click:        swallow press and release; act on the synthesized click
              if outside -> abort, then requeue the key sequence
```

**Where the behavior lives.** Library code over one platform primitive: Emacs'
`pre-command-hook` / `post-command-hook` pair.

**Degradation.** With no hover, nothing is lost — company never had a hover trigger. With no key
release the press/release-swallowing trick is unavailable but also unnecessary, since a toolkit that
only sees the click has nothing to swallow. The portable idea is the **replay**: a dismissing click
must be re-delivered to whatever is underneath, or the user pays two clicks. In a single-surface
toolkit with reverse-paint-order hit testing, that means the dismissal path must report "not handled"
after closing, not "handled".

### 6. Timing

Two independent delays on two different surfaces. `company-idle-delay` (0.2 s,
[`company.el:688`][co-idle-delay]) gates the **session**: once it fires, candidates exist and the
inline preview may already be visible. `company-tooltip-idle-delay` (0.5 s,
[`:697`][co-tooltip-idle-delay]) gates the **tooltip surface only**, implemented as a decorator
frontend, `company-pseudo-tooltip-unless-just-one-frontend-with-delay`, that wraps the plain frontend
([`:4566-4591`][co-delay-frontend]).

Its machine: on `pre-command` or `hide`, cancel the pending timer; on `post-command`, if a timer is
already pending **or** the overlay already exists, delegate straight through; otherwise arm a one-shot
that re-enters itself with `post-command`. The subtle branch is at `:4578-4582`: when an inline
preview overlay is currently showing, it does not delegate — it calls `company-call-frontends` with
`pre-command` and `company-tooltip-timer` let-bound to nil (tearing every surface down) and then
`post-command` (rebuilding them), so the preview and the tooltip are re-laid-out together rather than
one on top of a stale other.

Delay coercion is explicit: `company--idle-delay` maps `t`, `0` and `0.0` to `0.01`
([`:2740-2747`][co-idle-delay-fn]) — "instant" still means "next timer tick", never "synchronously
inside `post-command`". `company-idle-delay` may also be a function, evaluated per attempt.

There is no [cool-down][concepts], no skip-delay, no shared provider, no group and no maximum display
duration in company. posframe supplies the two that company lacks: `:timeout` seconds arms
`posframe--run-timeout-timer`, which calls `make-frame-invisible`
([`posframe.el:1029-1042`][pf-timeout]), and `:refresh` seconds arms a repeating timer that re-runs
`posframe--set-frame-size` ([`:916-934`][pf-refresh]) — a max-duration and a poll-for-content-change
respectively, both stored in buffer-local timer variables of the posframe's own buffer.

**Algorithm.** The machine, as extracted from the two files:

```text
states: Idle | Armed(deadline) | SessionOpen
      | SessionOpen+SurfaceArmed(deadline) | SessionOpen+SurfaceVisible

Idle           --commandInBeginSet-->  Armed(now + idleDelay)
Armed          --anyCommand-->         Idle                       (cancel)
Armed          --deadline-->           SessionOpen                (no candidates -> Idle)
SessionOpen    --post-command-->       relayout, if surfaceTimerPending or surfaceVisible
                                       else SurfaceArmed(now + tooltipDelay)
SurfaceArmed   --pre-command | hide--> cancel
any            --disallowedCommand | escape | pointJump--> Idle   (full session reset)
```

The surface timer is a **decorator over** the session machine, not a state inside it.

**Where the behavior lives.** Library code plus Emacs timers.

**Degradation.** With no timers, both delays vanish and with them the entire decorator frontend; what
survives is `SessionOpen` rendered unconditionally, which is the shape of a one-frame headless render.
A recording canvas can assert the machine only if the deadlines are **values** — a deadline field on
the state — rather than live timer objects: company stores a timer object in `company-tooltip-timer`,
and that is precisely the part that would have to become a tick count to be assertable.

### 7. Interactive hover

**Not applicable, and posframe actively defeats hover.** `posframe-mouse-banish-default` tests whether
the OS pointer lies inside the posframe rectangle and, if so, teleports it out with
`set-mouse-pixel-position` — five pixels left of the popup's left edge, or, when the popup is flush at
x = 0, five pixels past its right edge; vertically ten pixels above, or past the bottom, on the same
shape ([`posframe.el:1062-1088`][pf-banish-default]). The docstring calls itself "a hacky fix for the
mouse focus problem". It is a `defcustom` (`posframe-mouse-banish-function`,
[`:53`][pf-banish-custom]) because some consumers need the simpler unconditional variant
([`posframe-mouse-banish-simple`, `:1044`][pf-banish-simple]), and it runs at the end of every
`posframe-show`.

There is no [safe polygon][concepts], no pointer bridge, no menu-aim, no trajectory heuristic, no
interactive border and no submenu in either package. company's entire hover story is one text
property: `mouse-face 'company-tooltip-mouse` applied across each rendered row in
`company-fill-propertize` ([`company.el:3880-3882`][co-fill-propertize]), which makes Emacs'
redisplay highlight the row under the pointer with zero code in company.

Nested surfaces are solved by escaping to the application's own window manager rather than by nesting
overlays: `company-show-doc-buffer` calls `display-buffer` to split a real Emacs window
([`:3573-3586`][co-show-doc]), and `company--electric-do` snapshots `current-window-configuration`
before doing so, restores it in the next `pre-command` unless the command was a scroll, and re-centres
the buffer when the split shrank the window enough that the tooltip would no longer fit below point
([`:3547-3564`][co-electric-do]).

**Algorithm.**

```text
mouse banish:
    if (mx, my) inside [x, x+w] x [y, y+h]
        warp to ( x == 0 ? min(parentW, w + 5) : max(0, x - 5),
                  y == 0 ? min(parentH, h + 10) : max(0, y - 10) )
```

In whole cells, that escape distance is roughly one cell horizontally and one row vertically at
typical glyph advances.

**Where the behavior lives.** posframe library code for the banish; Emacs' redisplay (C) for the hover
highlight, driven by one text property company sets.

**Degradation.** With no hover, nothing is lost: neither package depends on hover for function. With
no native pointer [grab][concepts] the banish trick is unavailable and unnecessary — it exists only
because a child frame is a real window-manager surface that can steal focus on crossing. In one
surface with reverse-paint-order hit testing, "the pointer entered the overlay" is a hit-test result
rather than a platform event, so no bridge or safe polygon is needed for a single non-nested popup;
that cost appears only with submenus, which neither package has.

### 8. Dismissal

company's dismissal is a **whitelist over the command loop**, not a set of event handlers.
`company-pre-command` runs before every command and aborts unless `company--should-continue` says the
command is allowed; `company-continue-commands` defaults to a negative list
(`'(not save-buffer … completion-at-point …)`), so almost everything is allowed, and any command whose
symbol name starts with `company-` is allowed by regexp ([`company.el:1746-1754`][co-should-continue]).
Escape is `ESC ESC ESC` and `C-g`, both bound to `company-abort` ([`:901-904`][co-active-map]). Point
movement is handled by recomputation: `company-post-command` recomputes whenever `(point)` or
`(point-max)` changed and cancels when that yields no candidates
([`:2713-2716`][co-post-command]). There is one defensive branch: when `this-command` is nil in
`post-command` (a `C-g` fired inside somebody else's hook or a quittable timer), the session is
aborted **and** `this-command` is set to `company-abort` so later hooks see a coherent world
([`:2701-2709`][co-post-command]). An outside click dismisses and replays, as in dimension 5. For the
childframe surface, a global `window-configuration-change-hook` compares `(selected-window,
current-buffer)` against the pair recorded on the last frontend call and hides on a mismatch
([`company-childframe.el:264-274`][cf-window-change]).

posframe's mechanism is the surprising one: **dismissal by polled predicate**.
`posframe-hidehandler-daemon` is called unconditionally at load time and installs a 0.5-second
repeating idle timer that walks every frame in `frame-list`; for any frame carrying a
`posframe-hidehandler` frame parameter it calls that function with a two-key plist
(`:posframe-buffer`, `:posframe-parent-buffer`) and hides the frame when it returns non-nil
([`posframe.el:1143-1162`][pf-hidehandler-daemon]). The one builtin predicate,
`posframe-hidehandler-when-buffer-switch`, returns `t` when the recorded parent buffer is live and is
not the current buffer ([`:1166-1174`][pf-hidehandler-switch]). Dismissal policy is therefore a pure
predicate over values evaluated on a tick — the dual of the placement poshandler.

Hiding never destroys: `posframe-hide` makes the frame invisible ([`:1128-1141`][pf-hide]) and frames
are recycled, because — in the docstring's words at `:1199-1200` — deleting and recreating a posframe
is very slow.

**Algorithm.**

```text
company:  on every pre-command
              if not keep(cmd) and session and not allowed(cmd) -> cancel(session)
          cancel = reset 14 session fields in one setq, cancel timer, echo-cancel,
                   exit search mode, frontends('hide), uninstall keymap, run 3 hooks

posframe: every 0.5 s idle
              for f in frame-list
                  if f.hidehandler and f.hidehandler({buffer, parentBuffer}) -> setInvisible(f)
```

**Where the behavior lives.** Library code in both, over the command loop and an idle timer
respectively.

**Degradation.** Both models survive every target here, because neither depends on focus-out, window
deactivation or scroll events: the only two inputs are "what command just ran" and "what does a
predicate say about current state". That is directly implementable on a recording canvas — feed
commands, tick the clock, assert visibility — and an Android back key maps onto the escape binding
with no new machinery. The polled form is a warning as much as a model: a 0.5-second tick means a
posframe can outlive its reason by half a second, which is visible.

### 9. Focus

company achieves full keyboard [modality][concepts] **without moving focus**, by key-routing priority.
`company-emulation-alist` is consed to the front of `emulation-mode-map-alists` — a global list Emacs
consults before every other keymap ([`company.el:1103-1107`][co-ensure-emulation]) — and
`company-install-map` sets its buffer-local binding to `company-active-map` at the end of
`post-command`, while `company-uninstall-map` kills that buffer-local at the start of `pre-command`
([`:1109-1117`][co-install-map]). The popup's keymap is live exactly _between_ commands; point never
leaves the buffer; every key company does not bind falls through to the buffer's own keymap. The
install is skipped for `describe-key` and friends so help still describes the popup's bindings
([`:2694-2699`][co-pre-command]).

posframe, by contrast, has a real surface a window manager can focus, and fights it on three fronts:
the frame is created with `(no-accept-focus . ,(not accept-focus))`
([`posframe.el:731`][pf-no-accept-focus]); `posframe--redirect-posframe-focus` is attached to
`after-focus-change-function` at load time and calls `redirect-frame-focus` back to the parent
whenever the window manager hands focus to a posframe whose buffer did not opt into `:accept-focus`
([`:1571-1584`][pf-redirect-focus]); and the mouse banish prevents the crossing that would cause it.
`:accept-focus` is documented as risky — "be careful, you may face some bugs when set it to non-nil"
([`:349-352`][pf-accept-focus-doc]) — so the focusable variant is second-class.

company-childframe hedges: it installs `company-childframe-buffer-map` (parented to
`company-active-map`) in the child frame's buffer so the same bindings work if focus does land there
([`company-childframe.el:57-63`][cf-buffer-map]), plus a buffer-local `pre-command-hook` that, for any
command other than the two wheel commands, re-selects the parent frame and the parent buffer's window
before the command runs ([`:244-253`][cf-pre-command]).

The tooltip/menu distinction is respected: company's popup is a **menu** (arrow keys select, `RET`
commits, `company-require-match` exists) that is non-focusing, while posframe's frame is a blank
surface that becomes tooltip, popover or dialog purely by what the consumer configures.

**Algorithm.**

```text
modality without focus:
    keep a priority-ordered list of active key routers
    while a session is open: push the overlay's router to the FRONT between commands,
                             pop it before each command dispatches
    a key the router does not bind falls through to the underlying view
    focus, tab order and point are untouched — there is nothing to contain
```

**Where the behavior lives.** company: library code over one global list. posframe: three mechanisms
straddling library code and frame parameters, all of them platform-facing.

**Degradation.** company's model needs nothing from the platform — no focus concept, no OS window, no
tab order — so it is the half of this subject that ports intact to a single-surface cell grid. It also
answers the no-grab problem for keyboards: you do not need to grab, you need to be first in the
routing list, and you must be re-registered every frame so a stale overlay cannot hold the keyboard
hostage. posframe's three-mechanism focus defence is an artifact of having a real OS surface and has
no counterpart when there is only one surface. See also
[`../window-system-integration/index.md`](../window-system-integration/index.md) for the surface side
of that story, and [`./concepts.md`][concepts] for the [focus scope][concepts] vocabulary.

### 10. Layering & portals

The two packages sit on opposite sides of the seam a single-surface toolkit removes.

posframe **delegates layering entirely**: a child frame is a platform surface stacked by Emacs and the
window manager, and posframe never expresses z-order. Its overlay registry is a linear scan of
`frame-list` filtering on the `posframe-buffer` frame parameter (set at
[`:728`][pf-buffer-param]), used by `posframe-hide`, `posframe-refresh`, `posframe-delete-all`
([`:1177`][pf-delete-all]) and `posframe--find-existing-posframe` alike. The public API is
`posframe-show` / `-hide` / `-refresh` / `-delete` / `-delete-all` / `-funcall` plus the poshandler and
hidehandler contracts; the frame object itself is returned and is fair game, and `posframe-funcall`
hands the caller `with-selected-frame` on it ([`:1204-1212`][pf-funcall]) — a leaky boundary. Frame
parameters double as the public metadata store (`posframe-buffer`, `posframe-hidehandler`,
`posframe-parent-buffer`, `last-args`, `existing-posframe`).

company's pseudo-tooltip has **no layering primitive**, and the cost is the priority-111 comment quoted
in the Overview: a global integer priority space forces every participant to know every other
participant's number. Occlusion is not "hide the text underneath" but "replace it": the overlay gets
`display ""` over its own range — chosen over `invisible`, with three debbugs links attached —

> ;; `display' is better than `invisible':
> ;; https://debbugs.gnu.org/18285
> ;; https://debbugs.gnu.org/20847
> ;; https://debbugs.gnu.org/42521

— `company.el:4475-4478` ([`company-pseudo-tooltip-unhide`][co-tooltip-unhide]) — plus
`line-prefix ""` so an inherited prefix cannot shift the popup, `before-string` = the composited block,
and `window` = the selected window so the popup is per-window. Ownership is one buffer-local variable;
there is no overlay tree and no parent/child relationship. The four company surfaces (tooltip, inline
preview, echo area, doc window) are siblings that coordinate only through the ordering rules in
`company-frontends-set` and one hand-written workaround where the preview and tooltip overlays can
start at the same buffer position at end of line (`ptf-workaround`,
[`:4642-4651`][co-preview-show]).

**Algorithm.** Composite into the host grid: read the N visual lines the popup will cover, splice each
popup row into its covered line at the popup's pixel/cell column, blank the originals, and emit the
whole block as one string anchored at the popup's start. Front-to-back is then string order inside
that block — there is no z at all inside the overlay.

**Where the behavior lives.** posframe: the platform (Emacs child frames plus the window manager).
company: library code over one platform property (overlay `priority`, resolved by Emacs' redisplay).

**Degradation.** With no top layer and one surface, company's model _is_ the implementation, and its
priority-111 comment is a concrete argument for "later in the display list wins": a total order
derived from paint order needs no registry and cannot be gamed by a third party's number. The
`display ""` versus `invisible` distinction maps onto a real choice for a cell canvas: an overlay must
**overwrite** the cells it covers rather than mark them skipped, or content reflows underneath it.

### 11. Modality

Both are non-modal in the OS sense, and neither has a scrim, a dim or background blocking.

company is modal for the keyboard and transparent for everything else: the emulation keymap intercepts
the keys it binds (dimension 9) while point, the buffer and every unbound key stay live, and the
allow-list `company-continue-commands` ([`company.el:731-746`][co-continue-commands]) decides which
foreign commands may run without tearing the session down. A finer knob exists: the `company-keep`
symbol property marks commands that must not even trigger the pre/post-command session machinery
([`:2652-2653`][co-keep]), and `company-show-doc-buffer` sets it so opening the doc window does not
count as leaving the popup ([`:3617`][co-show-doc]).

posframe's non-modality is defensive rather than structural: `no-accept-focus`, the focus redirect and
the mouse banish exist precisely because a child frame is by default a first-class surface that
_would_ take pointer and keyboard. The `:accept-focus` argument makes it dialog-like and is documented
as risky.

Passthrough differs sharply. company achieves it exactly — an outside click dismisses and is replayed
to the buffer ([`:3141-3146`][co-select-mouse]) — while posframe cannot, because the child frame
swallows clicks and the banish is the only mitigation. Nothing in either package sets an accessibility
modal bit; there is no such concept in the frame and overlay APIs they use.

**Algorithm.** `modality = (keyRouterPriority, commandAllowList, keepSet)`. No pointer capture, no
background blocking, no scrim. An outside click dismisses the session and requeues the event so the
underlying view still receives it.

**Where the behavior lives.** Library code in both.

**Degradation.** Nothing here needs an OS window, a grab or a compositor. The hazard a single-surface
toolkit inherits from company is that "the popup blocks nothing" means an outside pointer event must be
delivered deliberately once or twice, and that decision belongs in the dismissal contract rather than
in the hit tester. On a TUI with one pointer and no grab, the replay rule is the behaviour that does
not lose a click.

### 12. Adaptive presentation

The same model renders into two structurally different surfaces, and the choice is made in **one
place, at the configuration layer**: the default value of `company-frontends`
([`company.el:220-226`][co-frontends]; recorded as new in 1.1.0 at [`NEWS.md:9`][news]). Everything
below the frontend is shared — `company--create-lines` ([`:4131-4275`][co-create-lines]) yields the
identical list of width-clamped, face-propertized strings; the childframe `mapconcat`s them with
newlines into a buffer ([`company-childframe.el:149-154`][cf-show]) and the pseudo-tooltip splices them
into the host grid.

The leakage is small and instructive. The per-target fudges are five:

| Fudge                                                                                                           | Where                                        |
| --------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| `:width` is `width` when everything fits **or** on a TTY, and `width - 1` only when a graphical display scrolls | [`company-childframe.el:163-168`][cf-width]  |
| the fractional 0.4-column scrollbar is refused unless `display-graphic-p`                                       | [`company.el:4296-4300`][co-right-margin]    |
| the search line adds one column on a TTY                                                                        | [`company.el:4339`][co-search-line]          |
| `company--string-width` switches between ceil-of-pixels and `string-width`                                      | [`company.el:3428-3432`][co-string-width]    |
| the childframe border width is zeroed on a TTY                                                                  | [`company-childframe.el:107-109`][cf-margin] |

Which layer owns the decision: the application's frontend list, i.e. user configuration — not the
renderer and not the geometry. There is a second adaptation, of the surface to the environment rather
than of the model: `posframe-workable-p` is a value predicate the consumer calls, and the childframe
frontend calls it in its `pre-command` case and raises a `user-error` when the answer is no
([`company-childframe.el:218-220`][cf-frontend]), so an unsupported display fails loudly at the
frontend boundary rather than degrading silently. There is no touch adaptation, no long-press, no
compact-size sheet and no teaching tip.

**Algorithm.**

```text
render(model) -> [String]                 ; padded to a computed width, faces embedded
surface A     : join(rows, "\n") -> childFrame(place(info))
surface B     : for each covered visual line i: modifyLine(covered[i], rows[i], pxCol)
                append remaining rows prefixed by pxCol of blank
                emit as one before-string
```

**Where the behavior lives.** The decision is configuration; the renderer is library code; the two
surfaces are two frontend functions.

**Degradation.** This is the subject's demonstration of one-view/N-surfaces parity, and the observed
cost of that parity in a mature codebase is roughly the five fudges above. It also shows where parity
breaks: wherever a _fractional_ unit exists — the 0.4-column scrollbar — the cell target needs a
different **design**, not a scaled one. The Android inset case has no analogue here; posframe's
`:minibuffer-height` inset input is the closest pattern.

### 13. Accessibility

Neither package exposes an accessibility role, and the pseudo-tooltip is adversarial to a naive
reader: it puts `display ""` on a live region of the user's own buffer and paints the popup as that
overlay's `before-string`, so what is on screen is not what the buffer contains at those positions.
The buffer text is intact underneath — the overlay is deleted on hide
([`company.el:4447-4450`][co-tooltip-hide]) — but any consumer reading the _display_ sees the popup in
place of code. There is no ARIA analogue and no accessibility-API hookup in either file.

> [!NOTE]
> **Inference.** The structure suggests that the honest accessible representation for both surfaces is
> the Lisp model rather than either surface: `company-candidates`, `company-selection`,
> `company-common` and `company-prefix` are buffer-local, and the `company-frontends` docstring states
> that "The visualized data is stored in `company-prefix`, `company-candidates`, `company-common`,
> `company-selection`, `company-point` and `company-search-string`"
> ([`company.el:247-249`][co-frontends]) — i.e. the model reads as the published contract and each
> surface as one rendering of it. Whether any assistive tool actually reads those variables was not
> observed.

company does back this up with a non-visual frontend that ships on by default:
`company-echo-metadata-frontend` is the third entry in the default `company-frontends` and writes the
selected candidate's metadata to the echo area. There is no WCAG 1.4.13 analogue to discuss, because
there is no hover; and the popup is unambiguously interactive — a menu with a selection, not a
tooltip — so the "tooltip content may never be interactive" rule does not bind here. posframe
contributes one accessibility-adjacent behaviour: `:cursor` and `:tty-non-selected-cursor` let the
terminal cursor be placed inside a non-selected child frame
([`posframe.el:300-311`][pf-cursor-doc], applied at [`:752`][pf-cursor-param]), which is how a TTY user
can see where the popup's own point is.

**Algorithm.** None. The accessible surface is the model record, published as named variables and
consumed by an echo-area frontend that runs alongside the visual one.

**Where the behavior lives.** Library code; nothing platform-facing exists to hook.

**Degradation.** A cell grid can honestly expose what company exposes: the model as text on a second
channel (a status line or echo region) rendered by a sibling frontend that shares the session state.
That is assertable on a recording canvas, needs no platform tree, and — on the evidence here — is the
claim a cell grid can make truthfully. What the primitive owes is the model record plus the guarantee
that every surface renders the _same_ record; roles, descriptions and live-region semantics belong to
the semantic component rather than to an anchored-overlay primitive.

### 14. Animation

**Not applicable.** There is no animation of any kind, no enter/exit, no [transform origin][concepts]
and no reduced-motion switch — and the reason is visible in the code: both packages treat every frame
of the popup's life as a full recompute plus a same-or-different comparison, so there is no continuous
quantity to animate.

What _is_ present is side metadata, and its shape is the finding. The pseudo-tooltip encodes the
chosen side as the **sign** of `company-height`, stored as an overlay property
([`company.el:4425`][co-tooltip-show]) and read back by three consumers: the redraw guard
(`(>= (* old-height new-height) 0)` — same sign means no re-place needed,
[`:4514-4522`][co-tooltip-frontend]), the hit test ([`:4352-4364`][co-inside-tooltip]) and the
mouse-selection row arithmetic. company-childframe cannot use a sign, because posframe returns only a
position, so it recovers the side by comparing the anchor's absolute y against the returned y and
stashing the answer in a module-level variable, `company-childframe--shown-above`
([`company-childframe.el:88`][cf-shown-above], computed at [`:127-131`][cf-show-at-prefix]).

`company-tooltip-flip-when-above` ([`company.el:322`][co-flip-when-above]) is the one styling decision
that depends on the side, and the two surfaces implement it differently: the pseudo-tooltip reverses
the lines list inside `company--replacement-string` ([`:4082-4083`][co-replacement]), while the
childframe re-erases and re-inserts the buffer contents reversed **after** `posframe-show` has already
run ([`company-childframe.el:183-187`][cf-flip]). That divergence, plus the out-of-band global, is the
smell: the placement call returns a bare `(x . y)` when its callers demonstrably need a placement
_result_.

**Algorithm.** None for animation. Side propagation, as observed: the side is either `sign(height)`
(in-grid path) or recomputed by comparing the anchor's absolute y to the result's y and written to a
module-level variable (child-frame path).

**Where the behavior lives.** Library code in both, and in the childframe's case in a module global.

**Degradation.** Nothing to lose — there is no animation to degrade. The transferable point is the
opposite of animation: because placement is recomputed wholesale on every keystroke, the system needs
a cheap same-or-different test, and both packages build one (the sign comparison plus
`company-pseudo-tooltip-guard`; posframe's `equal` over the info plist). In a value-semantics toolkit
those tests are free, which is a real argument for the approach.

### 15. State architecture

company keeps one flat **session record** in roughly fourteen buffer-local variables, created wholesale
and destroyed wholesale. `company-cancel` resets all of them in a single `setq`, cancels the timer,
exits search mode, calls the frontends with `hide`, uninstalls the keymap and runs three hooks
([`company.el:2594-2626`][co-cancel]) — the session is a value with a constructor and a destructor,
spelled in dynamic scope.

Frontends are pure dispatch functions over a closed seven-symbol vocabulary — `show`, `hide`, `update`,
`pre-command`, `post-command`, `unhide`, `select-mouse` — documented at
[`:227-249`][co-frontends], with `unhide` explicitly explained as "only needed in frontends which hide
their visualizations in `pre-command` for technical reasons". `company-call-frontends` wraps each call
in a `condition-case` that converts a frontend error into a hard error naming the frontend and the
command ([`:1761-1766`][co-call-frontends]). Per-frontend state is one overlay plus properties.
`select-mouse` is the only command with a return-value contract: `company-select-mouse` takes
`cl-some #'identity` over the frontends' results, so the first frontend that claims the click wins and
nil from all of them means "outside, dismiss" ([`:3138-3146`][co-select-mouse]).

Two ambient channels exist and both are workarounds: `company-mouse-event` is a let-bound global that
exists solely to pass one argument into a frontend call ([`:3134-3136`][co-mouse-event]), and
`company-childframe--shown-above` is the module global from dimension 14. Both exist because the
command vocabulary carries no payload and the placement call returns no result record.

posframe is retained-mode and stores state **on the surface**: buffer-locals of the posframe's _own_
buffer (`posframe--frame`, `--last-poshandler-info`, `--last-posframe-pixel-position`, `--last-args`,
`--timeout-timer`, `--refresh-timer`, `--initialized-p`, `--accept-focus`,
[`posframe.el:70-107`][pf-buffer-locals]) plus frame parameters for identity and policy. The comment at
`:698-704` concedes the fragility — other packages can clear those buffer-locals, which is why the
`frame-list` scan exists as a recovery path.

**Algorithm.**

```text
S = {backend, prefix, suffix, candidates, length, cache, predicate,
     common, selection, selectionChanged, manualAction, manualPrefix, pointMax, point}

begin:      S = compute(); install(keymap); frontends('update)
tick(pre):  if not keep(cmd) { frontends('pre-command); if not allowed(cmd) cancel() }
tick(post): if pointMoved recompute; frontends('post-command); if no S arm(timer)
cancel:     S = empty; frontends('hide); uninstall(keymap)
```

**Where the behavior lives.** Library code; the only platform dependencies are the command hooks and
timers.

**Degradation.** Directly portable. Nothing in either state model needs a DOM, a retained widget tree
or heap-allocated event objects: the command vocabulary is an enum, the session is a struct, and the
frontends are functions from `(enum, session)` to side effects on one overlay. The view half is
demonstrably a pure function already — `company--create-lines` is tested by binding the model
variables and comparing the returned strings exactly
([`test/frontends-tests.el:297-388`][t-create-lines]) — and the placement half is
`plist -> (x . y)`. The parts that would **not** survive are the two ambient channels, and both
disappear once commands carry payloads and `place()` returns a record.

### 16. Shared infrastructure

What is genuinely shared between company's two popup surfaces: the row renderer
`company--create-lines` and everything under it (`company-fill-propertize` for per-row faces,
annotation alignment, search highlight and deprecated strike; `company--clean-string` for width
normalisation; `company-space-string` with a precomputed vector of blank strings for common short
lengths); the scroll/offset math, of which there are two interchangeable policies selected by
`company-tooltip-offset-display` — `company-tooltip--lines-update-offset`
([`:3785-3803`][co-lines-offset]) versus `company-tooltip--simple-update-offset`
([`:3805-3810`][co-simple-offset]) — plus `company--scrollbar-bounds`
([`:4277-4282`][co-scrollbar-bounds], unit-tested against seven hand-computed cases at
[`test/frontends-tests.el:532-539`][t-scrollbar]); the width policy (min/max with grow-only hysteresis
under a cap); and the frontend command protocol.

What merely looks common and is deliberately kept apart:

- **the hit test** — in-grid it is arithmetic on `(col, row)` against the overlay's stored column,
  width and height ([`company--inside-tooltip-p`, `:4352-4364`][co-inside-tooltip]); for the child
  frame it is "is the event's window showing the childframe buffer?", with no geometry at all
  ([`company-childframe.el:231-242`][cf-select-mouse]);
- **the flip mechanics** — reverse the list before splicing versus re-insert reversed after the frame
  is already shown;
- **the unit fudges** of dimension 12;
- **the four sibling surfaces** — the tooltip (a menu), the inline preview (ghost text: an overlay with
  `display`/`after-string` and priority 1101, [`:4656-4663`][co-preview-priority]), the echo area, and
  the doc buffer (a real split window with a saved and restored window configuration). company does not
  attempt to unify those four, and the one place two of them interact needs a named workaround
  (`ptf-workaround`, because the preview and tooltip overlays can start at the same buffer position at
  end of line).

posframe factors the other axis: it is a surface with two pluggable policy seams — poshandler for
placement, hidehandler for dismissal — and one escape hatch, `refposhandler`, which replaces the
parent-frame coordinate space with an externally measured origin. The only builtin implementation
shells out to `xwininfo` and parses its output ([`posframe.el:1549-1569`][pf-refposhandler]), and the
docstring says "DO NOT USE UNLESS NECESSARY!!!" ([`:379`][pf-refposhandler-doc]).

**Algorithm.** The observed factoring is `(surface) x (placement policy) x (dismissal policy) x (row
renderer)` — four independently replaceable parts joined by two plain-data contracts (the info plist
in, the `(x . y)` out) and one closed command enum. Hit testing and flip mechanics are not factored.

**Where the behavior lives.** Library code throughout; the platform contributes only the surface.

**Degradation.** Nothing platform-bound in the shared half. The factoring that transfers to a single
anchored-overlay primitive: share the anchor value, the placement function, the dismissal predicate and
the content-measurement/width policy; do **not** share hit testing (it belongs to whatever owns the
display list), the side-specific content transform, or the surface-specific unit fudges. Within this
subject, the four sibling surfaces are the strongest evidence for keeping things apart: a mature system
with a tooltip, a menu, ghost text, a status line and a doc pane unified exactly one thing across them
— the model.

## Strengths

- The poshandler contract is placement as a named function of values: a documented flat record in, a
  position out, chosen by name, defaulted by the anchor's type, and memoized by structural equality on
  the whole input. Twenty implementations, none longer than about fifteen lines.
- `company-pseudo-tooltip` is a complete, mature, unit-tested anchored overlay implemented with no
  overlay surface — flip-above, horizontal shift, scrollbar, scroll offsets, selection and mouse hit
  testing, all in cells over text the popup overwrites.
- Keyboard modality without focus, via a routing-priority map installed between commands: no grab, no
  focus concept, no OS window, and every binding fires on press.
- Viewport insets (mode-line height, minibuffer height, header line, tab line) are **inputs** in the
  placement record rather than facts the placer discovers.
- One row renderer feeding two structurally different surfaces, with the surface chosen in
  configuration; the observed cost of that parity is roughly five width fudges.
- Redraw avoidance by comparable guard values (a tuple, a plist, an args list) rather than dirty bits.
- Sub-cell error is materialised as an explicit pad object so character count, cell count and pixel
  width all agree afterwards — with the exact pad counts pinned by tests.
- Frontends are pure dispatch over a closed seven-symbol vocabulary, with a static uniqueness and
  ordering check on the composition (`company-frontends-set`) instead of runtime coordination.
- Degraded environments are treated as a value question: `posframe-workable-p` is a predicate the
  consumer calls, and the childframe frontend fails loudly at its boundary.
- Real edge cases are covered and tested: wrapped lines, folded overlays, multi-line display
  properties, end of buffer, hscroll, RTL, tabs, CJK and invisible text.

## Weaknesses

- `place()` returns a bare `(x . y)`. Both real consumers need the chosen side, and both invent a side
  channel to get it — an overlay property holding a sign, and a module-level boolean set inside the
  poshandler.
- The documented-pure poshandler contract is violated in practice: `company-childframe-show-at-prefix`
  **mutates** its input plist (`cl-decf (cadr (plist-member info :parent-frame-height))`) to fake a
  smaller viewport so the generic flip test fires early. Nothing in the contract forbids or detects
  this.
- No fallback ordering, no preferred-side list, no auto-placement search. A poshandler is one policy;
  when it does not fit you get clamping or deliberate overflow (`max 3` rows even when fewer are free).
- A global integer priority (111, chosen to beat Flymake's 53 and Flycheck's 110) is a coordination
  failure baked into a constant, and the comment says so.
- Dismissal by 0.5-second polling can leave a posframe visible half a second after its reason is gone,
  and the daemon is started unconditionally at load time whether or not any posframe exists.
- posframe has no tests in the repository at this revision — only a benchmark file — so every
  placement claim about it is read from source rather than from an executable assertion.
- State lives on the surface (buffer-locals of the posframe buffer plus frame parameters), and the code
  concedes other packages can wipe those buffer-locals, requiring a `frame-list` rescan as recovery.
- Sub-cell correctness is bought with per-character redisplay measurements in a loop, in a scratch
  buffer, with the parent's face remappings copied in — expensive enough that two scratch buffers are
  kept alive permanently.
- The two surfaces implement the same user-visible option (`company-tooltip-flip-when-above`) by
  different mechanisms at different times.
- Zero accessibility surface, and the in-grid popup makes the display disagree with the buffer.
- Ambient dynamic scope as an argument channel: `company-mouse-event` exists solely to smuggle one
  value into a frontend call.

## Key design decisions and trade-offs

| Decision                                                                                                                                                          | Rationale                                                                                                                                                                                                                                                                                                              | Trade-off                                                                                                                                                                                                                                                                                                                                                                                                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Placement policy is a named pure function from a documented flat record to a position, selected by name and defaulted by the **type** of the anchor.              | One contract serves consumers with wildly different placement wishes without a combinatorial option surface, and a caller can supply its own handler without patching the library — `company-childframe` does exactly that. The record is plain data, which is what lets `posframe-run-poshandler` memoize on `equal`. | Because the handler receives everything and returns only `(x . y)`, callers needing more than a point invent side channels: the childframe mutates the input plist to fake a viewport and writes the chosen side into a module-level global. The contract is right; the return type is too small.                                                                                                                |
| Draw the popup by **rewriting the host's own text** rather than by acquiring a surface.                                                                           | It works in a terminal, in a remote frame, inside any window — no display server, no compositor, no child-frame support required. Emacs' redisplay does the compositing, and per-cell faces come along in the same string.                                                                                             | It must reimplement everything a display server would have done: visual-line counting, tab expansion, hscroll slicing, fractional-width correction, a hand-chosen global priority number, a `display ""` trick to blank what it covers, and a special case for end of buffer. company 1.1.0 responded by making the child-frame path the default wherever it is available; the in-grid path is now the fallback. |
| Dismissal is a **predicate over values** polled on a 0.5-second idle tick (posframe) and an **allow-list over the command loop** (company) — not event listeners. | Neither package can observe focus-out, scroll or anchor-removal reliably, and both already run inside a command loop that reports what just happened. A predicate and an allow-list are testable and composable, and posframe starts its daemon at load so a consumer only supplies the predicate.                     | Polling costs up to half a second of stale popup; the allow-list matches command names with a regexp anchored on the `company-` prefix, which is fragile; and dismissal cannot be immediate on genuinely external causes.                                                                                                                                                                                        |
| Achieve modality by **key-routing priority**, not by focus.                                                                                                       | The in-grid popup has no window to focus, and taking focus would move point and break the illusion that the user is still typing in the buffer. Pushing an emulation keymap to the front of the dispatch chain between commands gives full keyboard capture with no effect on focus, point, or any unbound key.        | It is a global mutation of a global list; the map must be installed and uninstalled around every single command; interactions with other packages that also front-load emulation maps are unspecified; and it must be exempted for `describe-key` so help does not lie.                                                                                                                                          |
| One row renderer, two surfaces, and the surface chosen by **configuration** at the application layer.                                                             | 1.1.0 needed a real graphical popup without abandoning terminal users. Keeping `company--create-lines` as the single producer of already-padded, already-faced rows made the second surface a small file.                                                                                                              | Parity is not free: five separate width fudges exist for the cell target, and the two surfaces implement flip-when-above by different mechanisms. Anything fractional (the 0.4-column scrollbar) needs a different design on a cell grid, not a scaled one.                                                                                                                                                      |
| Never destroy the surface; hide and reuse it, keyed by an equality check over its construction arguments.                                                         | posframe's own docstring says deleting and recreating a posframe is very slow (`posframe.el:1199-1200`). The frame is found by scanning `frame-list` for a `posframe-buffer` parameter and recreated only when the 16-element args list differs by `equal`.                                                            | State then lives on the surface — buffer-locals of the posframe's own buffer plus frame parameters — and the code openly admits other packages can clear those buffer-locals, which is why the frame-list scan exists as a recovery path.                                                                                                                                                                        |
| An outside click **dismisses and is replayed** to whatever is underneath.                                                                                         | Without a grab the popup cannot swallow the click, and swallowing it would cost the user a second click. `company-select-mouse` returns nil when no frontend claims the event, aborts, and pushes the key sequence back onto `unread-command-events`.                                                                  | Requires the ability to requeue an input event, and makes the dismissal path's return value semantically load-bearing ("not handled" after closing, not "handled"). It also requires binding the raw press and release to `ignore` so the press cannot act before the click is classified — a trick unavailable where there is no button release at all.                                                         |

## Sources

Primary sources, all read at the pinned revisions above:

- [`posframe.el`][pf-repo-file] — `posframe-show` and its docstring specification, the twenty
  poshandlers, `posframe-run-poshandler`, the hidehandler daemon, the mouse banish, the focus redirect,
  the frame reuse and reposition guards.
- [`posframe-benchmark.el`][pf-benchmark] — timings for the fourteen Emacs primitives posframe depends
  on (not executed here).
- [`company.el`][co-repo-file] — the session machine, the frontend command protocol,
  `company--create-lines` and the in-grid compositor, the emulation-keymap modality, the two idle
  delays, the mouse handling.
- [`company-childframe.el`][cf-repo-file] — the second surface: the custom poshandler, the viewport
  mutation, the side recovery, the childframe-local keymap and window-change dismissal.
- [`test/frontends-tests.el`][t-repo-file] — the executable pins for the row renderer, the scrollbar
  bounds, tab handling, folded and multi-line display coverage, RTL and multi-width padding.
- [`NEWS.md`][news] — the 1.1.0 entry recording the childframe frontend becoming the default.

Related pages in this catalog: the [umbrella index][index], the [shared vocabulary][concepts], the
[capstone comparison][comparison], [features people forget][ffpf], the
[sparkles baseline][baseline] and the [proposal][proposal]. The other terminal-grid subjects are
[Neovim floats][neovim], [nui.nvim][nui], [nvim completion menus][nvim-completion],
[Textual][textual], [Ratatui][ratatui], [Helix][helix], [Turbo Vision][turbo-vision],
[Notcurses][notcurses] and [tmux popups][tmux]. For the surface side of posframe's child frames see
[`../window-system-integration/index.md`](../window-system-integration/index.md); for the toolkit this
evidence feeds, see [`../../specs/ui/index.md`](../../specs/ui/index.md),
[`../../specs/ui/input.md`](../../specs/ui/input.md),
[`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md) and
[`../../specs/ui/backends.md`](../../specs/ui/backends.md).

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[ffpf]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[neovim]: ./neovim-floats.md
[nui]: ./nui.md
[nvim-completion]: ./nvim-completion.md
[textual]: ./textual.md
[ratatui]: ./ratatui.md
[helix]: ./helix.md
[turbo-vision]: ./turbo-vision.md
[notcurses]: ./notcurses.md
[tmux]: ./tmux-popup.md
[posframe-repo]: https://github.com/tumashu/posframe/tree/74c8c56131ed866db47ae4191364b72dd4852456
[company-repo]: https://github.com/company-mode/company-mode/tree/1cc907ac9e46ae4209eb5a341131787e0c678406
[pf-repo-file]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el
[co-repo-file]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el
[cf-repo-file]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el
[t-repo-file]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/test/frontends-tests.el
[news]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/NEWS.md#L9
[pf-benchmark]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe-benchmark.el#L34
[pf-banish-custom]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L53
[pf-buffer-locals]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L70
[pf-workable]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L132
[pf-position-doc]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L186
[pf-poshandler-doc]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L193
[pf-cursor-doc]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L300
[pf-accept-focus-doc]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L349
[pf-refposhandler-doc]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L379
[pf-font-height]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L590
[pf-border]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L640
[pf-args-list]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L654
[pf-reuse]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L707
[pf-buffer-param]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L728
[pf-no-accept-focus]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L731
[pf-undecorated]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L748
[pf-cursor-param]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L752
[pf-find-existing]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L811
[pf-refresh]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L916
[pf-run-poshandler]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L937
[pf-valid-poshandler]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L953
[pf-calc-position]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L965
[pf-set-position]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L987
[pf-timeout]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1029
[pf-banish-simple]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1044
[pf-banish-default]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1062
[pf-hide]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1128
[pf-hidehandler-daemon]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1143
[pf-hidehandler-switch]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1166
[pf-delete-all]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1177
[pf-funcall]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1204
[pf-point-1]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1228
[pf-top-right]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1363
[pf-other-corner]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1373
[pf-bottom-left]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1400
[pf-refposhandler]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1549
[pf-redirect-focus]: https://github.com/tumashu/posframe/blob/74c8c56131ed866db47ae4191364b72dd4852456/posframe.el#L1576
[co-frontends-set]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L192
[co-frontends]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L220
[co-scrollbar-width]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L312
[co-flip-when-above]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L322
[co-idle-delay]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L688
[co-tooltip-idle-delay]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L697
[co-continue-commands]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L731
[co-active-map]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L901
[co-ensure-emulation]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1103
[co-install-map]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1109
[co-posn-col-row]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1125
[co-should-complete]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1737
[co-should-continue]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1746
[co-call-frontends]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L1761
[co-cancel]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L2594
[co-keep]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L2652
[co-pre-command]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L2679
[co-post-command]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L2701
[co-idle-delay-fn]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L2740
[co-mouse-event]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3134
[co-select-mouse]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3138
[co-face-remappings]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3369
[co-string-width]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3428
[co-safe-pixel-substring]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3435
[co-electric-do]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3554
[co-unread-keys]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3566
[co-show-doc]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3573
[co-lines-offset]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3785
[co-simple-offset]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3805
[co-fill-propertize]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3880
[co-clean-string]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L3948
[co-modify-line]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4013
[co-window-width]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4037
[co-replacement]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4077
[co-create-lines]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4131
[co-scrollbar-bounds]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4277
[co-right-margin]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4296
[co-search-line]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4339
[co-tooltip-overlay]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4350
[co-inside-tooltip]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4352
[co-tooltip-height]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4366
[co-tooltip-show]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4379
[co-show-at-point]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4427
[co-tooltip-hide]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4447
[co-tooltip-unhide]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4460
[co-tooltip-guard]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4482
[co-tooltip-frontend]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4514
[co-delay-frontend]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4566
[co-preview-show]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4642
[co-preview-priority]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company.el#L4656
[cf-buffer-map]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L57
[cf-shown-above]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L88
[cf-show-at-prefix]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L90
[cf-margin]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L106
[cf-show]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L134
[cf-width]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L163
[cf-flip]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L183
[cf-frontend]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L211
[cf-select-mouse]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L231
[cf-pre-command]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L244
[cf-window-change]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/company-childframe.el#L264
[t-rtl]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/test/frontends-tests.el#L63
[t-create-lines]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/test/frontends-tests.el#L297
[t-multiwidth]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/test/frontends-tests.el#L310
[t-scrollbar]: https://github.com/company-mode/company-mode/blob/1cc907ac9e46ae4209eb5a341131787e0c678406/test/frontends-tests.el#L532
