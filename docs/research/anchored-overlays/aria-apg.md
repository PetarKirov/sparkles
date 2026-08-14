# WAI-ARIA Authoring Practices Guide (HTML / CSS / JavaScript)

APG is the one subject in this catalog that specifies almost nothing about where an overlay goes and almost everything about what it means — roles, focus ownership, dismissal and modality — and ships six reference implementations that place their popups with two hardcoded constant offsets and no collision pass at all.

| Field             | Value                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Language**      | HTML + CSS + JavaScript (mixed ES5 prototype style and ES6 classes); Node + AVA + Selenium for the regression suite                                                                                            |
| **License**       | W3C Software and Document License for the content; the repository's `package.json` declares `"license": "MIT"` for the tooling                                                                                 |
| **Repository**    | [`w3c/aria-practices`][apg-repo]                                                                                                                                                                               |
| **Documentation** | [WAI-ARIA Authoring Practices Guide][apg-docs] — the repository _is_ the documentation, but it also carries runnable example code and a test suite, so this page is **not** a docs-only reading                |
| **Category**      | Web platform / accessibility                                                                                                                                                                                   |
| **Surface model** | in-canvas — every overlay in the corpus is a `position: absolute` DOM element inside the trigger's own containing block. No OS popup, no [top layer](./concepts.md), no `<dialog>`, no Popover API, no portal. |
| **Revision read** | `7e4034b262bc0d25332e330d8a582aaf34113829`                                                                                                                                                                     |

> [!IMPORTANT]
> APG is an **authoring-practices guide**, explicitly non-normative. Where this page
> quotes a pattern's "WAI-ARIA Roles, States, and Properties" list, that is APG's
> authoring guidance — not the WAI-ARIA specification, which is not in this clone.
> The distinction matters most for the tooltip pattern, which additionally carries a
> no-consensus banner.

## Overview

### What it solves

APG answers the questions a canvas toolkit cannot infer from geometry: which surface takes
focus, what an assistive technology sees at the trigger→overlay edge, whether the overlay's
content may be interactive, and what "modal" actually obliges an implementation to do. It
answers them for six overlay-bearing patterns — tooltip, menu/menubar, menu button,
combobox, modal dialog, disclosure — and backs five of them with reference implementations
and a Selenium suite bound to the documentation.

It does **not** answer the placement question. Across the whole corpus there are two
placements: below-start at `top: anchorHeight + gap`, and right-start at
`left: anchorWidth + gap`, each computed once at open time against the anchor's own
containing block and never re-evaluated. There is no collision detection, no flip, no shift,
no [clipping boundary](./concepts.md), no arrow math beyond two CSS triangles, no RTL, and
no scroll or resize tracking anywhere.

### Design philosophy

The philosophy is legible in the tooltip pattern's own status banner, which is the single
most load-bearing sentence about this subject:

> NOTE: This design pattern is work in progress; it does not yet have task force consensus.
>
> — `content/patterns/tooltip/tooltip-pattern.html:23` ([source][tooltip-consensus])

The tooltip pattern has no example — the work is tracked by
[issue 127](https://github.com/w3c/aria-practices/issues/127) at
`tooltip-pattern.html:39` ([source][tooltip-noexample]) — and `role="tooltip"` appears in no
example page in `content/`; the only occurrence in the tree is inside a vendored
`bootstrap.min.js`. The one shipped tooltip-like widget, the toolbar's _popup label_,
deliberately avoids the role entirely.

Where APG _is_ prescriptive it is prescriptive about structure. A submenu's `menu` element
is required to be

> Contained inside the same `menu` element as its parent `menuitem`.
>
> Is the sibling element immediately following its parent `menuitem`.
>
> — `content/patterns/menubar/menu-and-menubar-pattern.html:199-200` ([source][menubar-submenu])

That single requirement forbids portaling a submenu, makes the overlay's identity positional
(`menuitem.nextElementSibling`), and makes ownership and cascade-closing pure ancestry tests
— which is exactly the shape a single-surface toolkit has anyway.

## How it works

Each example is a self-contained controller class plus a stylesheet, with no shared library
and no framework. Opening a menu writes inline styles and one ARIA attribute:

```js
// content/patterns/menubar/examples/js/menubar-navigation.js:430-450 (openPopup)
var popupMenu = menuitem.nextElementSibling;
var rect = menuitem.getBoundingClientRect();
if (this.isPopup[menuId]) {
  // submenu: right-start, 10px gap
  popupMenu.parentNode.style.position = 'relative';
  popupMenu.style.left = rect.width + 10 + 'px';
  popupMenu.style.top = '0px';
} else {
  // root menu: below-start, 8px gap
  popupMenu.style.left = '0px';
  popupMenu.style.top = rect.height + 8 + 'px';
}
popupMenu.style.zIndex = 100;
popupMenu.style.display = 'block';
menuitem.setAttribute('aria-expanded', 'true');
```

Three scalars are read from the anchor in the entire corpus:
`getBoundingClientRect().height`, `.width`, and `domNode.offsetWidth`. There is no
anchor→screen conversion, because the popup is positioned inside the anchor's own
containing block — `menubar-navigation` manufactures one at open time with
`popupMenu.parentNode.style.position = 'relative'`, and the toolbar declares
`button.popup { position: relative }` in CSS ([`toolbar.css:45`][tb-css-popup]).

Cascade-closing is the corpus's one real overlay-tree operation:

```js
// content/patterns/menubar/examples/js/menubar-editor.js:457, :464
doesNotContain(popup, menuitem) {
    if (menuitem) return !popup.nextElementSibling.contains(menuitem);
    return true;
}
closePopupAll(menuitem) {          // close every popup that is NOT an ancestor
    ...                            // of the item about to become active
}
```

Dismissal, focus and modality are then layered on per pattern, each with its own document-level
listeners. The combobox never moves DOM focus; the dialog installs a capture-phase focus trap
and a full-viewport backdrop; the tooltip-like popup label neither focuses nor traps and lives
inside its trigger's DOM subtree.

## The analysis spine

### 1. Anchor model

**Algorithm.** `anchorBox = (anchor.offsetOrigin, anchor.width, anchor.height)` expressed in the
anchor's own containing block; `popupOrigin = anchorBox.origin + constantOffset(kind)`. No
transform into a common or screen space is performed anywhere. Popup identity is positional:
`var popupMenu = menuitem.nextElementSibling` ([`menubar-editor.js:419`][mbe-open]). The
AT-visible edge is `trigger.aria-controls -> popup.id`, and the combobox pattern permits that
reference to name an element that is not visible, so the edge is stable across open and close.

The anchor is always a DOM element — never a rect, a point, a cursor, a text range, a
sub-region or a moving target ([virtual anchor](./concepts.md) has no representation). Trigger
and anchor are never separated, and many-triggers-one-overlay does not occur.

Where APG departs from a plain value it pays for it. `menubar-editor` keys six parallel
per-menu maps by a string derived from `aria-label` via `getIdFromAriaLabel`
([`:249`][mbe-idlabel]) using a **non-global** `.replace(' ', '-')`, so only the first space is
replaced and labels differing only after the first space collide. INFERENCE: this untyped key
appears to be what let commit [`ccfa79e8`][commit-tabindex] pass a DOM node where a `menuId`
string was expected with no error raised — the commit message describes the hover path as
"updating nothing due to erroneously passing in a menu rather than an ID".

**Where the behavior lives.** Per-example JavaScript, inline in each `openPopup()`, plus
`position: relative` in CSS. There is no shared anchor abstraction.

**Degradation.** Survives every degradation axis. No OS window is needed (nothing leaves the
document); no hover is needed (the anchor is static); no sub-cell precision is needed (only
width and height are read); no key release is involved. In a cell grid the one measurement APG
makes is free — the anchor box is already `(row, col, w, h)` at layout time. The one thing to
fix on the way across is APG's stringly identity.

### 2. Placement model

**Algorithm.** `place(anchorBox, kind)`:

```text
menubarChild   -> (x = anchorBox.x,        y = anchorBox.bottom + gap)
submenu        -> (x = anchorBox.right + gap, y = anchorBox.y)
comboboxPopup  -> (x = anchorBox.x,        y = anchorBox.bottom, width = anchorBox.width)
popupLabel     -> (x = anchorBox.centerX - popupWidth/2, y = anchorBox.top - 2.5em)
```

`gap` is a per-widget constant: `8` px for a root menu ([`menubar-navigation.js:449`][mbn-open]),
`-3` px — i.e. a deliberate **overlap** — for the editor menubar
([`menubar-editor.js:427`][mbe-open]), and `10` px for a submenu. The select-only combobox's
listbox is pure CSS, `top: 100%; left: 0; width: 100%; z-index: 100`
([`select-only.css:57-69`][so-css]) — below-start with the width matched to the anchor. The
toolbar popup label is above-centre, `top: -2.5em` ([`toolbar.css:62-65`][tb-css-show]) with a
JavaScript `left` of `-((8 * textLen - anchorWidth) / 2) - 5`.

Absent entirely: preferred/fallback lists, auto placement, [flip, shift, slide, resize](./concepts.md),
viewport padding, custom boundaries, safe-area insets, work areas, multi-monitor, IME or
virtual-keyboard avoidance. RTL and writing modes get nothing — every offset is a physical
`left`/`top`. Logical properties appear once in the repository, in the 2024 disclosure card
(`padding-inline-start`, `border-inline-start`), which is not an anchored overlay.

**Where the behavior lives.** Split arbitrarily between inline JavaScript style writes (menubar,
datepicker) and stylesheets (menu button, select-only, dialog). The same conceptual placement is
expressed both ways in different examples.

**Degradation.** Fully survives: it is already integer arithmetic over an anchor box with no
measurement dependency. Static HTML with no script can express all four cases in CSS alone, and
three of them already are. A soft-keyboard inset has no representation whatsoever — APG has no
viewport-inset concept at all, consistent with touch being out of scope. Multi-monitor and work
areas are meaningless with one surface, which is precisely APG's situation as well.

### 3. Collision & geometry engine

**This dimension is essentially absent, and the absence is the finding.** There is no collision
engine for any popup. The only viewport-overflow test in the corpus is `isElementInView(element)`
([`select-only.js:132`][so-inview]; mirrored as `isOptionInView` in
[`combobox-autocomplete.js:107`][ca-inview]), which compares a bounding rect against
`window.innerHeight`/`innerWidth` — and its only consequence is a
`scrollIntoView({ behavior: 'smooth', block: 'nearest' })` on the **active option**
([`select-only.js:338-339`][so-scroll]). It never repositions the popup.

**Algorithm.** The whole geometry engine is `maintainScrollVisibility(activeElement, scrollParent)`
([`select-only.js:152`][so-maintain]):

```text
if    active.offsetTop < container.scrollTop
      -> scroll to active.offsetTop
elseif active.offsetTop + active.offsetHeight > container.scrollTop + container.offsetHeight
      -> scroll to active.offsetTop - container.offsetHeight + active.offsetHeight
```

Gated by `isScrollable(el) => el.clientHeight < el.scrollHeight`
([`:146`][so-scrollable]). Overflow detection exists only as a boolean gate in front of a
scroll, never in front of a reposition. There is no clipping-ancestor discovery, no
transform/zoom/DPR handling, no top layer, no anchor- or popup-resize response, and no
`ResizeObserver`, `IntersectionObserver`, `requestAnimationFrame` or polling. A popup placed at
open time stays where it was put through any scroll or resize; the only "tracking" is that
placement is recomputed on every open.

One hard geometric obligation _is_ stated: browsers do not scroll `aria-activedescendant`
targets into view the way they do for real focus, so the application must, and APG calls it
"essential to accessibility for people who use a browser's zoom feature"
([`combobox-autocomplete-list.html:135`][cal-scroll]).

**Where the behavior lives.** Two free functions duplicated between `select-only.js` and
`combobox-autocomplete.js`. Nothing framework-level; the browser's layout engine does everything
else implicitly via `position: absolute`.

**Degradation.** What generalizes off the DOM is exactly the part APG implements: the
keep-active-in-view clamp is integer arithmetic over `(item offset, item size, viewport offset,
viewport size)` and works identically in cells. What does not generalize is what APG delegates to
CSS — being clipped by an ancestor's overflow. In a single-surface toolkit that clipping is the
toolkit's own clip stack and must be modelled explicitly rather than inherited. With no script,
the clamp disappears and long popups must simply be short. The "recompute on open, never track"
policy is a good default for an immediate-mode repaint loop, where every frame re-derives
placement anyway.

### 4. Arrow / caret geometry

Exactly one pointer arrow exists in the corpus, on the toolbar popup label, and it is pure CSS
([`toolbar.css:67-89`][tb-css-arrow]): a `::before` (12 px, white) and an `::after` (10 px,
black), both at `top: 100%; left: 50%` with `margin-left` equal to the negative border width,
stacking a larger light triangle behind a smaller dark one to fake a bordered arrow. Both carry
`pointer-events: none` at `:76`, so the arrow — which physically spans the gap between the
label's bottom edge and the button's top edge — is deliberately excluded from hit testing and
cannot serve as a pointer bridge.

**Algorithm.** There is none. The arrow sits at a fixed 50 % of the **popup**, not of the
anchor; that is only correct because the popup is centred on the anchor by JavaScript and
nothing ever shifts it. There is no corner constraint, no hiding when the arrow would overhang,
no detachment, no arrow-size-feeds-offset coupling (the `2.5em` offset and the 10/12 px
triangles are independent constants), and no [transform origin](./concepts.md) derived from the
arrow or the side. Arrow geometry is not data: nothing computes it and nothing reads it.

A second, different "arrow" — the disclosure caret — is also a CSS `::after` border triangle,
and it is the one place a rationale is recorded: the border-triangle technique is chosen "so the
caret is reliably rendered in high contrast mode of operating systems and browsers"
([`disclosure-navigation.html:170`][dn-caret]). That is a state indicator, not a pointer.

**Where the behavior lives.** Stylesheets only. No JavaScript in the corpus touches an arrow.

**Degradation.** With a character cell as the smallest unit an arrow is one cell — `▲ ▼ ◀ ▶`,
or a box-drawing junction (`┬ ┴ ├ ┤`) painted into the overlay's border run so the border
"notches" toward the anchor. The two-tone bordered effect and the sub-cell overhang are
unreproducible and should be dropped rather than approximated. The transferable idea is
`pointer-events: none`: whatever an arrow is, it must not participate in the hit list, or a
pointer resting on it has an ambiguous owner. In a static HTML emit with no measurement, a
centred cell arrow is computable from integer anchor and popup extents at emit time.

### 5. Trigger semantics

Triggers observed across the corpus: `focus` ([`FormatToolbarItem.js:171-177`][fti-focus]),
`mouseover` ([`:185-188`][fti-mouse]), `click`
([`menu-button-actions.js:312`][mb-click]), keydown open keys Enter / Space / ArrowDown /
ArrowUp, typed printable characters (`select-only.js:300-302` calls `updateMenuState(true)`
unconditionally, so typing opens), `pointerover` gated on an **armed** predicate, and
programmatic (`window.openDialog`). Absent: focus-visible distinction, press vs click, long
press, touch, pointer-type distinction, and context-menu invocation — `Shift`+`F10` is named in
the menu pattern's prose ([`:25`][menubar-shiftf10]) and implemented nowhere.

**Algorithm — armed hover.** Hovering a menubar item does nothing until the widget is already
active:

```text
armedHover(item):
    if !(widget.hasFocus || widget.anyPopupOpen) return
    closeAllPopupsNotAncestorOf(item)
    setActive(item)
    if item.hasPopup: open(item)          // zero delay
```

The predicate is `this.isAnyPopupOpen() && this.getMenu(tgt)`
([`menubar-editor.js:699`][mbe-hover]) and `this.hasFocus() || this.isAnyPopupOpen()`
([`menubar-navigation.js:709`][mbn-hover]). Once armed, hover switches instantly with no
[warm-up](./concepts.md).

On combining multiple trigger sources, APG has **no arbitration layer**: every source calls the
same imperative mutators and consistency rests on idempotence guards —
`updateMenuState` early-returns when `this.open === open`
([`select-only.js:377-380`][so-update]); `closePopup` no-ops unless `isOpen()`
([`menu-button-actions.js:157-159`][mb-open]). Where that discipline lapsed, real bugs shipped:
commit [`ccfa79e8`][commit-tabindex] (August 2025) patched three separate open paths — click,
hover, and Enter/Space/Arrow — that each updated a different slice of the roving-tabindex
invariant, leaving multiple items with `tabindex=0`. The message names one race precisely:
focus could arrive "by pressing on it and dragging off it before releasing". The fix was to make
every path call the one mutator that restores all invariants —
`setFocusToMenuitem(menuId, newMenuitem)` ([`menubar-editor.js:143`][mbe-setfocus]), which
cascade-closes, sets the active item, and re-opens the parent chain if the newly active item has
no popup of its own.

**Where the behavior lives.** Per-item DOM event listeners bound in each example's init loop,
plus one document- or window-level capture listener per widget instance for outside dismissal.

**Degradation.** A target that does not surface hover loses armed hover and the popup-label
trigger entirely; only click and keyboard survive, which is exactly what `disclosureMenu.js`
already is (click and keys only, no hover anywhere). No key release is harmless here: every open
path in the corpus is keydown or click. Static HTML with no script leaves `:hover`,
`:focus-within` and `<details>` / `:checked` — enough for the popup label and the disclosure,
not for armed hover (which needs remembered state) nor for typeahead-opens. The transferable
lesson is the 2025 fix itself: funnel every trigger into **one** invariant-restoring transition.

### 6. Timing

Exactly three timing constants govern overlays in the entire corpus:

| Constant | Purpose                                    | Source                                       |
| -------- | ------------------------------------------ | -------------------------------------------- |
| 800 ms   | deferred hide of the toolbar popup label   | [`FormatToolbarItem.js:17`][fti-delay]       |
| 300 ms   | deferred close of the autocomplete listbox | [`combobox-autocomplete.js:565-568`][ca-out] |
| 500 ms   | typeahead buffer reset                     | [`select-only.js:229-238`][so-search]        |

**There is no open delay anywhere.** The tooltip pattern says a tooltip "typically appears after
a small delay" ([`tooltip-pattern.html:28`][tooltip-delay]) and the only implementation shows it
instantly on both focus and `mouseover`. Absent: warm-up, [cool-down / skip-delay](./concepts.md),
instant-subsequent-tooltip, shared delay providers, max display duration, re-entry windows. A
**group singleton** does exist: `showPopupLabel` calls `this.toolbar.hidePopupLabels()` first
([`FormatToolbar.js:348`][ftb-hideall]), so at most one label per toolbar, and traversing the
toolbar therefore slides the single label instantly with focus.

**Algorithm — deadline plus predicate.** The timer is never cancelled. On the leaving event,
record a deadline and do nothing else; at the deadline, evaluate a pure predicate over current
state and close only if it still holds:

```js
// content/patterns/toolbar/examples/js/FormatToolbarItem.js:180-182, :143-147
handleMouseLeave() { this.hasHover = false;
                     setTimeout(this.hidePopupLabel.bind(this), this.popupLabelDelay); }
hidePopupLabel()   { if (this.popupLabelNode && !this.hasHover) { /* hide */ } }

// content/patterns/combobox/examples/js/combobox-autocomplete.js:295-305
close(force) {
    if (force || (!this.comboboxHasVisualFocus &&
                  !this.listboxHasVisualFocus && !this.hasHover)) { /* close */ }
}
```

Re-entry needs no cancellation — it simply makes the predicate false. Only the typeahead buffer
uses a real `clearTimeout` ([`select-only.js:232-238`][so-search]).

Two typeahead regimes coexist: buffered prefix matching with same-letter cycling
(`getIndexByLetter`, [`select-only.js:84`][so-letter]) and a single-character wrap scan with no
buffer at all ([`menubar-editor.js:209`][mbe-firstchar]).

**Where the behavior lives.** Raw `setTimeout` calls inline in per-example event handlers. No
scheduler, no debounce helper, nothing shared.

**Degradation.** Static HTML has no timers: both bridges vanish, which promotes "trigger and
content must be contiguous or DOM-nested" from an optimisation to a hard requirement. On a
frame-stepped canvas a deadline is a frame-time comparison and the predicate is re-evaluated on
the frame that crosses it — so the transition is observable, whereas a cancelled timer's
non-firing is not. The fire-always shape is also a good fit for value semantics: state is one
deadline value plus a pure predicate, with no timer handle to own. A target without a leave
event has no use for either delay.

### 7. Interactive hover

No [safe polygon](./concepts.md), no pointer-bridge geometry, no menu-aim, no diagonal-intent
heuristic, no trajectory model, no interactive border, no debounce — none of it exists anywhere
in the corpus. APG solves trigger→content travel **structurally**.

The toolbar popup label is a DOM **child** of its trigger button
(`<button class="item bold popup"><span class="popup-label">Bold</span></button>`,
[`toolbar.html:59-62`][tb-html]) but is positioned outside the button's box by `top: -2.5em`
against `button.popup { position: relative }`. Because `mouseleave` is defined over the DOM
ancestor chain, entering the geometrically separate label does not leave the button, and
`mouseover` bubbles from the label back to the button, re-running `handleMouseOver` →
`showPopupLabel(); hasHover = true`.

> [!NOTE]
> INFERENCE: where a real pixel gap exists between the label's bottom edge and the button's top
> edge, crossing it would fire `mouseleave`, start the 800 ms timer, and re-entering the label
> would neutralise it through the `!hasHover` re-check — so the bridge would be _temporal_
> where it is not _structural_. This rests on reading the CSS, not on measuring a rendered page.
> What is certain is that the CSS arrow cannot be the bridge: it is removed from hit testing.

The autocomplete combobox reproduces the same effect with listeners rather than containment:
`pointerover` on the listbox and on every option sets `hasHover = true`; `pointerout` schedules
the 300 ms guarded close. Submenu diagonal travel is **unprotected**: `onMenuitemPointerover`
calls `closePopupAll(tgt)` _before_ opening ([`menubar-navigation.js:709`][mbn-hover]), so a
diagonal path from a parent item across a sibling toward the submenu closes the submenu with no
recovery window.

**Algorithm.**

```text
bridge-by-ownership:  if the overlay is a descendant of the trigger in the ownership tree,
                      "leaving the trigger" is defined over the tree, not over geometry
bridge-by-deadline:   on pointer-out set deadline = now + delay and hasHover = false;
                      any pointerover on trigger OR overlay sets hasHover = true;
                      at the deadline, close only if !hasHover
submenu intent:       none — closeAllNotAncestorOf(hovered) runs on every hover
```

**Where the behavior lives.** Half in HTML/CSS structure (the label being a child of the button
is an authoring decision, not code), half in three boolean flags and two `setTimeout` calls per
example.

**Degradation.** The structural bridge costs **zero cells** — it is an ownership relation in the
hit list, not geometry, so a toolkit whose hit list records "this overlay is owned by that
trigger" gets it for free. A geometric bridge costs whatever the gap is. INFERENCE: with a gap
of G cells the dead band spans G rows or columns across the overlay's extent, so any
corridor-based intent scheme has very few cells to work with at the gap sizes APG uses; APG
spends none of those cells and spends 300–800 ms instead. Where hover is served both mechanisms
are available, and the ownership one is preferable because it needs no clock. Where hover is
absent this dimension is void — which is the strongest argument for making hover-travel an
optional capability rather than a core behavior. See [`concepts.md`](./concepts.md) and
[`features-people-forget.md`](./features-people-forget.md) for the geometric alternatives other
subjects implement.

### 8. Dismissal

Escape is universal but bound five different ways, with one portability landmine: `dialog.js`
registers `document.addEventListener('keyup', aria.handleEscape)`
([`:106-114`][dlg-escape]) — **keyup**, not keydown. Other bindings: a `body` keydown registered
once **per toolbar item**, so N identical global listeners all call `toolbar.hidePopupLabels()`
([`FormatToolbarItem.js:151-156`][fti-hideall]); a per-menuitem keydown; a case inside a pure
key mapper ([`select-only.js:37`][so-action]); and a two-stage escalation in the grid combobox
where the first Escape clears the active cell and hides the popup and a later Escape with the
popup already hidden clears the input — via a 1 ms `setTimeout` because "On Firefox, input does
not get cleared here unless wrapped in a setTimeout" ([`grid-combo.js:79-102`][gc-esc]). Escape
scope is always innermost-only.

Outside-pointer dismissal uses **five different events across five examples** for the same
predicate `!widgetRoot.contains(event.target)`: `mousedown`
([`menu-button-actions.js:324`][mb-bg]), `pointerdown` capture
([`menubar-editor.js:36`][mbe-bg]), `pointerup` capture
([`combobox-autocomplete.js:536`][ca-bgup]), `mouseup` capture
([`combobox-datepicker.js:127`][dp-mouseup]) and plain `click`.

Focus-outside dismissal uses `relatedTarget` containment
([`select-only.js:249-253`][so-blur]; `disclosureMenu.js:87-92`) — and that predicate
**replaced** an `ignoreBlur` flag in commit [`164188c4`][commit-scrollbar], because clicking the
listbox's scrollbar blurred the combobox and closed the popup mid-scroll. The now-dead
`this.ignoreBlur = true` writer survives at [`select-only.js:358`][so-ignoreblur] with no reader
anywhere in `content/`.

**Algorithm.**

```text
closeAllExceptAncestors(target):
    for each open popup P: if !subtree(P).contains(target) then close(P)
outside-pointer:  on a document-level (capture) pointer event,
                  if !widgetRoot.contains(event.target) then closeAll()
focus-outside:    on focusout, if !widgetRoot.contains(event.relatedTarget) then close
escape:           close the innermost open surface only; grid-combo escalates on repeat
```

`doesNotContain(popup, item) => !popup.nextElementSibling.contains(item)`
([`menubar-editor.js:457`][mbe-dnc]) is the ancestry test; closing a submenu focuses its parent
item as part of the close. Absent everywhere: dismissal on scroll, on resize, on anchor hidden,
on anchor removed, on navigation, on window or application deactivation, and on touch outside.

**Where the behavior lives.** Document- and window-level listeners registered per widget
instance, plus per-item keydown handlers. There is no shared dismissal router; the same predicate
is re-implemented five times under five different event names.

**Degradation.** Keyup Escape is **impossible without key release**: anyone porting `dialog.js`
to a terminal must move it to keydown — semantically identical here, but a silent break for a
copier. The absence of a pointer [grab](./concepts.md) is not a problem for APG's model, because
outside-detection is a containment test over events the surface already receives; if an event
leaves the surface and never arrives, the overlay simply stays open, which is the safe failure.
A system back key maps naturally onto the same close-innermost rule, and the LIFO dialog stack
gives it the right semantics for free. Static HTML with no script loses every dismissal except
`<details>` / `:checked` toggling and focus-out via `:focus-within`. The transferable core is one
routine — `closeAllExceptAncestors` over the overlay tree — plus **one** canonical outside-pointer
event, not five.

### 9. Focus

APG keeps four regimes deliberately distinct, and this is the dimension it invests in most.

**Tooltip.** Never focused. "Focus stays on the triggering element while the tooltip is
displayed" ([`tooltip-pattern.html:48`][tooltip-focusstays]), and the pattern states —
non-normatively — that

> Tooltip widgets do not receive focus. A hover that contains focusable elements can be made using a non-modal dialog.
>
> — `content/patterns/tooltip/tooltip-pattern.html:31-32` ([source][tooltip-nofocus])

so a hover surface you can click into is a **different widget**, not a configuration of a
tooltip. The named substitute, the non-modal dialog, is referenced three times in the repository
and documented nowhere — no page, no example.

**Menu / menubar.** DOM focus moves into the popup: "When a `menu` opens, or when a `menubar`
receives focus, keyboard focus is placed on the first item"
([`menu-and-menubar-pattern.html:62`][menubar-focusfirst]). Two in-composite strategies are
permitted — a roving `tabindex`, or `aria-activedescendant` on the container
([`:209-210`][menubar-tabindex]) — and the two menu-button examples demonstrate both on the
same widget. Diffing them shows the only differences are: the listener on the container versus
on each item; `item.focus()` plus a `tabIndex` flip
([`menu-button-actions.js:62-71`][mb-roving]) versus `currentMenuitem` plus
`aria-activedescendant` plus a `.focus` class
([`menu-button-actions-active-descendant.js:63-75`][mb-ad]); and explicit `buttonNode.focus()`
restoration in the roving version. All index arithmetic, typeahead and open/close logic is
identical.

**Combobox.** For popups with role `listbox`, `grid` or `tree`, focus never enters the popup:
"When a descendant of a listbox, grid, or tree popup is focused, DOM focus remains on the
combobox and the combobox has `aria-activedescendant` set to a value that refers to the focused
element within the popup" ([`combobox-pattern.html:420`][combobox-focus]). The single documented
exception is a dialog popup: "Unlike other combobox popups, dialogs do not support
`aria-activedescendant` so DOM focus moves into the dialog from the combobox"
([`:395`][combobox-dialog]). The popup and its descendants are excluded from the page `Tab`
sequence ([`:119`][combobox-tabseq]). This arrangement is legal because the
`aria-activedescendant` specification's DOM-relationship restrictions — restated by APG at
[`keyboard-interface-practice.html:364-376`][kbd-domrel] — carry a third condition for a
`combobox`/`textbox`/`searchbox` with `aria-controls`. The implementations model the result as an
application-owned pair of booleans, `comboboxHasVisualFocus` / `listboxHasVisualFocus`
([`combobox-autocomplete.js:164`][ca-vf-combo], [`:172`][ca-vf-list]) — **focus as a value**,
distinct from DOM focus.

**Dialog.** A real trap, built from two mechanisms that neither works without:

> // Bracket the dialog node with two invisible, focusable nodes.
> // While this dialog is open, we use these to make sure that focus never
> // leaves the document even if dialogNode is the first or last node.
>
> — `content/patterns/dialog-modal/examples/js/dialog.js:191-193` ([source][dlg-sentinels])

**Algorithm — direction inference without reading the modifier** ([`:296`][dlg-trap]):

```js
trapFocus(event) {
    if (aria.Utils.IgnoreUtilFocusChanges) return;
    var d = aria.getCurrentDialog();
    if (d.dialogNode.contains(event.target)) { d.lastFocus = event.target; }
    else {
        aria.Utils.focusFirstDescendant(d.dialogNode);
        if (d.lastFocus == document.activeElement)      // we were going backwards
            aria.Utils.focusLastDescendant(d.dialogNode);
        d.lastFocus = document.activeElement;
    }
}
```

`focusFirstDescendant` is a depth-first pre-order walk calling `attemptFocus` on each child
([`:29`][dlg-first]); `attemptFocus` raises a module-global `IgnoreUtilFocusChanges` re-entrancy
flag, calls `focus()` in a `try`/`catch`, and verifies success by comparing
`document.activeElement` ([`:69`][dlg-attempt]) — focusability determined **empirically**, by
trying. Focus restoration is a **required** constructor argument that throws if omitted
([`:173-181`][dlg-required]).

The datepicker dialog rejects the generic trap and hand-wires a cyclic ring instead: each control
maps `Tab` and `Shift`+`Tab` to a named neighbour, e.g. the OK button's `Tab` focuses
`prevYearNode`, closing the ring ([`combobox-datepicker.js:259-270`][dp-ring]). Containment is a
property of the wiring, not of a runtime query. Pointer- versus keyboard-opened focus differences
are not modelled anywhere in the corpus.

**Where the behavior lives.** `dialog.js` / `alertdialog.js` for the trap; per-example
controllers for the menu and combobox regimes; the two in-composite strategies are documented as
step-by-step algorithms in the keyboard-interface practice
([`:296` roving][kbd-roving], [`:325` activedescendant][kbd-ad]).

**Degradation.** With no platform focus at all (a cell grid, a recording canvas, static HTML
without script), the combobox's "visual focus as an owned value" is the one regime that ports
unchanged. The dialog trap's document-level focus listener has no analogue on a canvas: it must
become either an explicit ring — the datepicker's approach, which is allocation-free, a fixed
array of targets plus modular arithmetic — or a containment predicate over the application's own
focus value. The direction-inference trick survives and is valuable where you would rather not
model `Shift` state. Sentinels are unnecessary: with one surface there is nowhere outside for
focus to go. A roving `tabindex` is meaningless without a platform tab order; the active index is
simply state. See [`../../specs/ui/state-machines.md`](../../specs/ui/state-machines.md) for the
toolkit's existing focus machine.

### 10. Layering & portals

**No portal and no top layer, anywhere.** Every overlay is a DOM descendant of its own widget,
positioned `absolute` inside the anchor's containing block; `menubar-navigation` even manufactures
that containing block at open time. No example uses `<dialog>`, the Popover API, or a
render-to-body portal. This is not laziness — the pattern _mandates_ containment for submenus
([`menu-and-menubar-pattern.html:199-200`][menubar-submenu]), and the same page warns that
`aria-owns` reorders the AT reading order for elements that are not DOM children
([`:242`][menubar-ariaowns]). The accessibility contract forbids the portal that DOM toolkits
reach for.

Stacking is three unrelated magic numbers with no discipline: inline `zIndex = 100` set on open
and reset to `0` on close ([`menubar-editor.js:429`][mbe-open]), `zIndex = 2` for the datepicker
dialog ([`combobox-datepicker.js:232`][dp-zindex]), and `z-index: 1` on the dialog backdrop in CSS
([`dialog.css:118`][dlg-css-backdrop]) — the subject of commit [`d0577918`][commit-zindex] whose
entire content was raising it.

Overlay **trees** exist, but only as DOM ancestry: `closePopupAll` plus `doesNotContain` is an
ownership-tree walk written as `!popup.nextElementSibling.contains(candidate)`, and
`closePopout` ([`menubar-navigation.js:459`][mbn-popout]) walks _up_ the chain closing each level
until it reaches a menubar item. Dialogs are the only case with an explicit tree: the LIFO array
`aria.OpenDialogList` ([`dialog.js:85`][dlg-stack]) with `getCurrentDialog` and listener hand-off
between levels ([`:209-214`][dlg-handoff]).

The public-API/implementation-detail split is unusually clear: `aria-expanded`, `aria-haspopup`,
`aria-controls` and `aria-modal` are the contract — what AT consumes and what the regression
suite asserts — while `z-index`, `style.display` and `style.top` are per-example detail that
varies freely.

**Algorithm.** Ownership tree = DOM ancestry. `open(popup)` sets a per-instance z-index and
`display: block`; close resets both. `closeAllExceptAncestors(target)` walks the flat list of
known popups and closes each whose subtree does not contain `target`. Nested modality is a LIFO
stack where only the top element owns the global listeners; push on open, pop on close, re-arm the
new top.

**Where the behavior lives.** Inline style writes in each example's `openPopup`/`closePopup`, plus
one array in `dialog.js` as the only explicit overlay tree. No shared layering service.

**Degradation.** This is the dimension where APG's structure matches a single-surface toolkit most
closely: no top layer, the overlay inside the trigger's subtree, and z-index treated as a per-open
scratch value rather than a global ordering. "Later in the display list" is what `zIndex = 100` on
open approximates. The LIFO dialog stack is the right model for one surface and maps onto a system
back key unchanged. The failure worth not copying is the three unrelated magic depths: the overlay
tree should determine paint order so that no caller ever picks a number. See
[`../../specs/ui/containers.md`](../../specs/ui/containers.md).

### 11. Modality

Modality is defined as a **three-part conjunction**, all of which must hold — the `aria-modal`
bit, real interaction blocking, and visual obscuring:

> Because marking a dialog modal by setting aria-modal to true can prevent users of some assistive technologies from perceiving content outside the dialog, users of those technologies will experience severe negative ramifications if a dialog is marked modal but does not behave as a modal for other users. So, mark a dialog modal **only when both:** 1. Application code prevents all users from interacting in any way with content outside of it. 2. Visual styling obscures the content outside of it.
>
> — `content/patterns/dialog-modal/dialog-modal-pattern.html:145-150` ([source][dialog-modality])

`aria-modal` explicitly replaces the legacy technique of stamping `aria-hidden` on every sibling
subtree, and the note preserves the legacy rules for anyone still doing it
([`:153-156`][dialog-legacy]).

**Algorithm — the observed blocking half** uses neither `inert` nor `aria-hidden`:

```text
modal(open):  push onto aria.OpenDialogList; remove global listeners from the previous top;
              create-or-reuse a full-viewport backdrop element and mark it .active;
              document.body.classList.add('has-dialog')            // scroll lock
              insert two tabindex=0 sentinels around the dialog;
              install the capture-phase focus trap; move focus in
close():      pop; remove sentinels; deactivate backdrop; restore focus to the required
              focusAfterClosed; re-arm the new top's listeners, or unlock scroll if empty
```

The pattern's own framing is that "Windows under a modal dialog are inert"
([`:24-26`][dialog-inert]). The backdrop element is created at open time if absent and the scroll
lock is a class on `document.body` ([`dialog.js:156-171`][dlg-backdrop]); the backdrop is
`position: fixed` with all four insets at `0`
([`dialog.css:110-118`][dlg-css-backdrop]), so it swallows pointer events by covering everything;
the scroll lock is `.has-dialog { overflow: hidden }` ([`:136`][dlg-css-hasdialog]). Keyboard
blocking outside the document is not attempted and could not be. The scrim is **media-gated** —
`background: rgb(0 0 0 / 30%)` only inside `@media screen and (min-width: 640px)`
([`:121-125`][dlg-css-scrim]) — so on compact viewports one of the three required parts is
simply absent.

[Light dismiss](./concepts.md) is **not** implemented for dialogs (clicking the backdrop does
nothing) but _is_ the model for every non-modal popup, via the five outside-pointer handlers.
Modeless-but-focus-containing is named — "unlike most non-modal dialogs, modal dialogs do not
provide means for moving keyboard focus outside the dialog window without closing the dialog"
([`:31`][dialog-nonmodal]) — and never implemented. Passthrough / click-through is never
considered. `inert` appears exactly once in the corpus and not for modality: `details.inert =
isExpanded` on a collapsing disclosure card ([`disclosure-card.js:41`][dc-inert]), so an animating
region stops being interactive while still occupying layout.

**Where the behavior lives.** `dialog.js` for the behavior, `dialog.css` for the backdrop and the
scroll lock; the accessibility bit is authored statically in the example markup.

**Degradation.** With one surface and no pointer grab, requirement (1) is _easier_ than in a DOM:
a full-surface scrim rectangle painted immediately before the dialog absorbs every hit in a
reverse-paint-order hit list, with no z-index, no `position: fixed`, and no sibling able to escape
it. Scroll lock is free — there is no ambient scroller. The accessibility bit has no analogue with
no accessibility API and must degrade to a recorded property that a recording canvas asserts
behaviorally ("the scrim consumed the click"; "Tab did not leave the ring"). A system back key
maps to close-innermost. On static HTML with no script, modality is unachievable and a modal
should emit as inline content rather than a fake overlay.

### 12. Adaptive presentation

Exactly one instance exists, and it lives entirely in CSS. Below 640 px, `[role="dialog"]` is
`min-height: 100vh` with no positioning and **no scrim** — a full-screen sheet
([`dialog.css:5-11`][dlg-css-base]). At 640 px and above the same element becomes
`position: absolute; top: 2rem; left: 50vw; transform: translateX(-50%)` with a `min-width` and a
two-layer box-shadow ([`:13-23`][dlg-css-media]), and the backdrop gains its 30 %-black scrim. The
JavaScript is byte-identical in both cases: `dialog.js` never learns which presentation it is in.
The popover→sheet decision is owned entirely by the **styling layer** and is invisible to the
state machine.

Nothing else adapts: no hover-tooltip→long-press transformation (touch is out of scope), no
teaching tips, no keyboard-driven relocation, no `pointer: coarse` query anywhere in the overlay
CSS. The only other environment-adaptive CSS in the corpus is the 2024 disclosure card, which
reacts to `forced-colors: active` and `prefers-reduced-motion` by swapping custom properties —
again a pure styling-layer decision with no controller involvement.

**Algorithm.** None. The adaptation is a CSS media query swapping the positioning scheme and the
scrim; the controller is not parameterised by presentation at all.

**Degradation.** The transferable answer is _which layer owns the decision_: the layer that owns
pixels, not the machine. That split is more necessary off the web than on it, because a
soft-keyboard inset cannot be expressed by a media query — the backend must pass the inset into
the placement step while the state machine stays identical (see
[`../window-system-integration/index.md`](../window-system-integration/index.md)). On a cell grid,
"compact" is a cell-count threshold and the sheet form is a full-width panel; on a recording
canvas the presentation choice should be an explicit, assertable parameter rather than an ambient
query. Note that APG's own adaptation is untestable by its own suite — no test resizes the
viewport.

### 13. Accessibility

**Tooltip contract.** The pattern's roles/states/properties section is exactly two bullets: the
container has `role="tooltip"`, and the trigger "references the tooltip element with
`aria-describedby`" — not `aria-labelledby` ([`tooltip-pattern.html:57-60`][tooltip-rsp]).
This is authoring guidance, not normative ARIA, and the pattern itself is flagged as lacking task
force consensus with no example.

Two consequences follow from the names-and-descriptions practice. `tooltip` is a
name-from-content role ([`:182`][names-nfc]), so the tooltip's own accessible name is its text,
and via the trigger's `aria-describedby` that text becomes the **trigger's description** — a
two-hop computation. And putting `aria-label` on a tooltip is a documented hazard: the tooltip row
of the naming table warns "Warning! Using `aria-label` or `aria-labelledby` will hide descendant
content from assistive technologies" ([`:1438-1443`][names-tooltip-row]). The same practice twice
criticises the `title` attribute — "not particularly discoverable, and is also not accessible to
visual users without a pointing device" ([`:435`][names-title-435]) and "might not be accessible
to some users, in particular sighted users not using a screen reader and not using a pointing
device that supports hover" ([`:1741`][names-title-1741]).

> [!WARNING]
> **WCAG 2.1 SC 1.4.13's normative text is not in this repository.** APG references the SC exactly
> twice and each reference paraphrases a **different, incomplete subset**. The toolbar example
> claims conformance and lists appears-on-focus-or-hover, "The popup label remains visible when the
> pointer hovers over the label content", and "Pressing `Esc` hides the popup label"
> ([`toolbar.html:171-179`][tb-wcag]). The disclosure navigation example lists only Escape plus
> focus-out and asserts "Implementing this `Esc` behavior is necessary to meet the WCAG 2.1
> 1.4.13" ([`disclosure-navigation.html:163-169`][dn-esc]). Neither states all three requirements.
> For the SC's own wording see [WCAG 2.1 SC 1.4.13][wcag-1413] directly — it is not a claim this
> source tree can support. No test in APG's suite is hover-driven, so the toolbar's conformance
> claim is unverified by APG's own oracle.

**Algorithm — the mechanically derivable half.**

```text
accName(tooltip)       = concatenation of its descendant content       // name-from-content
accDescription(trigger) = accName(target of aria-describedby)
trigger.aria-expanded  = isOpen
trigger.aria-haspopup  = popupKind, unless implicit (listbox is implicit for a combobox)
trigger.aria-controls  = popup.id                    // constant, independent of visibility
dialog.aria-modal      = isModal AND blocking AND obscuring
```

**Other contracts.** Menu/menubar: roles `menu`|`menubar`, items
`menuitem`|`menuitemcheckbox`|`menuitemradio`, parent items carry `aria-haspopup` and
`aria-expanded`, and exactly one of a roving `tabindex` or `aria-activedescendant`. Combobox: role
`combobox` on the input; `aria-controls` to the popup; `aria-expanded` on the input;
`aria-haspopup` only when the popup is not a listbox; `aria-activedescendant` on the input;
`aria-autocomplete` of `none`|`list`|`both`. Dialog: role `dialog`, `aria-modal="true"`, a required
name, and `aria-describedby` discouraged when the content is structurally rich. Disclosure: role
`button` plus `aria-expanded`, with `aria-controls` optional.

**Where the behavior lives.** Pattern prose is the specification; attributes are hand-authored in
each example's markup and hand-maintained by each controller. The regression suite asserts them
(`test/util/assertAriaControls.js`, `assertAriaDescribedby.js`, `assertAriaActivedescendant.js`,
`assertRovingTabindex.js`), and each test is bound to a `data-test-id` row in the example's own
documentation table and fails if that row is missing ([`test/index.js:78-104`][test-index]).

**Degradation.** With no accessibility API none of the attribute plumbing is observable — but the
behavioral half is fully assertable: Escape dismisses; focus never enters a tooltip; the
description text is reachable without hover. The primitive/semantic-component split falls out of
the algorithm above: `aria-expanded`, `aria-haspopup`, `aria-controls` and `aria-modal` are pure
functions of `(isOpen, kind, anchor)` and a positioning primitive can emit all four, while role
choice, name-versus-description, activedescendant-versus-roving, and "may the content be
interactive" belong to the semantic component, because getting them wrong changes _which widget it
is_, not where it is drawn. In a cell grid the toolbar's trick generalises: keep the description
text in the widget's model at all times and let the overlay be a second **paint** of the same
string — then hover-only exposure is structurally impossible. See
[`../../specs/ui/widgets.md`](../../specs/ui/widgets.md) and
[`sparkles-baseline.md`](./sparkles-baseline.md).

### 14. Animation

**This dimension does not apply to APG's overlays, and the absence is the finding.** No anchored
overlay in the corpus animates. Opening is `style.display = 'block'` and closing is `'none'`, or a
class toggle that jumps `top` from `-30000em` to `-2.5em` — deliberately instantaneous, chosen so
the element is never `display: none`, not for motion. No side or align data is exposed to the
styling layer because there is nothing to expose: the side is a compile-time constant per widget
class. No transform origin, no enter/exit choreography, no reposition-during-animation, no spring
model, no arrow animation.

The only motion-aware CSS in the repository is in the 2024 disclosure card, which is not an
anchored overlay. It defines `--transition-duration-snappy` and `--transition-duration-leisurely`
as `0` at the top ([`disclosure-card.css:13-14`][dc-dur]) and raises them only inside
`@media (prefers-reduced-motion: no-preference) and (forced-colors: none)`
([`:24-27`][dc-rm]) — reduced motion as the **default** rather than as an override, which is the
right polarity. Its chevron rotates via `[aria-expanded="true"] svg { rotate: -180deg }`, i.e. the
animation is driven by the ARIA state attribute itself.

**Where the behavior lives.** Nowhere for overlays; entirely in CSS custom properties gated by
media queries for the disclosure card.

**Degradation.** Nothing is lost anywhere, because nothing is present. On a cell grid the available
affordances are per-frame reveal and glyph/colour change, both driven by state rather than by
transform origins; reduced motion becomes a theme flag. INFERENCE: that the reference
implementations of six overlay patterns ship with zero animation suggests animation is not part of
the primitive's contract at all — placement-aware transform origins look like a styling-layer
convenience a canvas toolkit can defer.

### 15. State architecture

Three architectures coexist in one repository, and they are not equally portable.

**(a) Attribute-as-state.** `isOpen(menuitem)` returns
`menuitem.getAttribute('aria-expanded') === 'true'` ([`menubar-editor.js:481`][mbe-isopen]) and,
worse, the datepicker's `isOpen()` returns
`window.getComputedStyle(this.dialogNode).display !== 'none'`
([`combobox-datepicker.js:242`][dp-computed]). The DOM — in the second case the CSSOM — _is_ the
store; there is no model.

**(b) Pure reducer.** `select-only.js` is a genuine one. `getActionFromKey(event, menuOpen)`
([`:37`][so-action]) is a total pure function of key plus modifiers plus open state onto a small
action enum; `getUpdatedIndex(currentIndex, maxIndex, action)` ([`:110`][so-index]) is a pure index
transition using `Math.min`/`Math.max` clamping with a page size of 10;
`getIndexByLetter(options, filter, startIndex)` ([`:84`][so-letter]) is pure, including the
"if the filter is all the same letter, cycle first-letter matches" rule. All DOM mutation is
confined to `onOptionChange` / `selectOption` / `updateMenuState`. The entire widget state is
`{ open, activeIndex, searchString, searchTimeout }` ([`:181-185`][so-state]).

```text
action = f(key, altKey, ctrlKey, metaKey, open)
switch (action):
    First | Last            -> open(true), then fall through to index movement
    Next | Previous
      | PageUp | PageDown   -> activeIndex = clamp(g(activeIndex, maxIndex, action))
    CloseSelect             -> select(activeIndex), then fall through
    Close                   -> open(false)
    Type                    -> open(true); buffer += ch;
                               activeIndex = matchPrefix(buffer, from activeIndex+1, wrapping)
    Open                    -> open(true)
```

Two pure functions, one integer, one bool, one string. Note that `getUpdatedIndex` **clamps** while
the menubar's own movement **wraps** — wrap-versus-clamp is a per-widget policy in this corpus,
not a universal.

**(c) Minimal-state controller.** `disclosureMenu.js` holds the entire open/closed state of an
N-button navigation menubar in one nullable integer, `this.openIndex`
([`:14`][dm-openindex]), and `toggleExpand(index, expanded)` ([`:156-168`][dm-toggle])
recursively closes the previously open index first, making the singleton an invariant of
construction rather than a rule to enforce.

Everything in the corpus is **uncontrolled** — no example accepts an externally owned open flag.
Guards substitute for cancellation throughout. The one structural weakness is identity: the six
parallel per-menu maps keyed by a stringly `getIdFromAriaLabel` value, into which the August 2025
bug delivered a DOM node where a string was expected, silently doing nothing.

**Where the behavior lives.** Entirely per-example. There is no shared state library, no reducer
helper, no controller base class.

**Degradation.** (b) and (c) survive verbatim into a value-semantics, allocation-conscious toolkit
— they are integers, enums and clamps with no DOM reads and no identity beyond an array index.
`getActionFromKey` is exactly the shape of a pure key mapper over a tier-0 input event (see
[`../../specs/ui/input.md`](../../specs/ui/input.md)), and `openIndex : int?` is the entire state
of a menubar. (a) does **not** survive: it inverts the direction of truth, and reading back from a
style system is impossible on a canvas that retains no style. The fix APG never made is a typed
handle per menu instead of a stringly key; array indices give that for free.

### 16. Shared infrastructure

**There is no shared overlay module** — and the corpus documents what happens as a result. The
closest thing to sharing is copy-paste with measured drift: `dialog.js` and `alertdialog.js` both
define `aria.Utils.focusFirstDescendant`, `aria.Utils.attemptFocus`,
`aria.Utils.IgnoreUtilFocusChanges`, `aria.handleEscape` and `aria.Dialog` with identical JSDoc —
and they have diverged on the central question. `dialog.js` keeps a stack,
`aria.OpenDialogList`, with push/pop and listener hand-off between levels; `alertdialog.js` keeps a
single `aria.openedDialog` ([`:150`][adlg-single]). Same names, same comments, two incompatible
modality models. `menubar-editor.js` and `menubar-navigation.js` are near-duplicates that diverge
exactly where the domain demands: navigation adds an `isPopup` classification, a `closePopout`
chain walk, and the right-start submenu branch.

**Algorithm — the factoring test APG accidentally performs.** Take two implementations of the same
widget that differ in exactly one policy — `menu-button-actions.js` (roving `tabindex`) versus
`menu-button-actions-active-descendant.js` (`aria-activedescendant`) — and diff them. Everything
identical is the primitive; the residue is the policy that must be a parameter. Here the residue
is: which listener owns the keys, whether the active item takes real focus, and whether close
restores focus explicitly.

On that evidence, what belongs in one anchored-overlay primitive:

1. the anchor→popup edge and its attribute projection (`expanded` / `haspopup` / `controls`);
2. placement as `(side, align, gap)` against an anchor box;
3. the overlay ownership tree and its one real operation, `closeAllExceptAncestorsOf(target)`;
4. outside-pointer and Escape routing against that tree, innermost-first;
5. an active index with clamped or wrapping movement, plus typeahead;
6. deferred close as deadline plus predicate.

What merely _looks_ common and must stay apart: focus policy (four mutually incompatible answers
over identical geometry); modality; whether the content may be interactive (a tooltip may not, a
non-modal dialog must); whether Escape **reverts a value** or merely closes — the combobox pattern
contrasts navigating a popup and pressing Escape, which "closes the popup or menu without changing
previous input", with a single-select listbox where Escape provides no undo
([`combobox-pattern.html:95-96`][combobox-esc]); and DOM/tree containment, which is normative for
submenus and merely conventional elsewhere. Toast, teaching tip, hovercard, context menu and
popover have no patterns at all here, so this corpus offers no evidence about where they belong.

**Where the behavior lives.** Nowhere. Every example is self-contained by editorial policy — each
page offers a copy-paste and CodePen export ([commit `b28a984e`][commit-codepen]) — a deliberate
trade of DRY for standalone readability, and precisely why the two dialog copies diverged.

**Degradation.** The primitive/policy split above mentions no hover, no key release, no sub-cell
precision and no OS window, so it is target-independent by construction. The four focus policies
collapse differently per target: with no platform focus, "menu moves DOM focus" and "combobox uses
`aria-activedescendant`" become the same application-owned active index, and only the dialog's
containment rule stays a real distinction. That argues for exposing "who owns the active index" and
"is this surface focus-containing" as two orthogonal parameters of one primitive rather than as
four widget types. See [`comparison.md`](./comparison.md) and [`proposal.md`](./proposal.md).

## Strengths

- Separates the semantics a canvas cannot infer (role, name versus description, who takes focus,
  may content be interactive, is it modal) from the geometry it can, and specifies the former in
  detail while barely mentioning the latter — the primitive/component boundary drawn explicitly.
- The submenu containment requirement matches a single-surface toolkit's natural structure: the
  overlay lives in the trigger's subtree, ownership is ancestry, cascade-close is a path test.
- Four focus regimes are kept deliberately distinct and each is justified in prose, which makes
  conflating any two hard to do accidentally.
- `select-only.js` is a genuine pure reducer whose three key functions are total and allocation-free
  over `(key, modifiers, open, index)`.
- `disclosureMenu.js` demonstrates that an entire N-item navigation menubar's overlay state is one
  nullable integer, with the singleton invariant enforced by construction.
- The two menu-button examples form an unintentional controlled experiment isolating focus strategy
  from everything else; diffing them yields the primitive/policy split directly from source.
- Deferred closes use fire-always timers with predicate re-checks rather than cancellation — no
  handles, no leaks, and observable in a frame-stepped canvas.
- Tests are bound to documentation rows and fail when the row is missing; `ariaTest.failing` keeps
  known gaps visible as expected failures rather than silent.
- `pointer-events: none` on the CSS arrow shows deliberate thinking about what participates in hit
  testing versus what is only painted.
- The scrollbar-click fix ([`164188c4`][commit-scrollbar]) replaced an ad-hoc `ignoreBlur` flag with
  a `relatedTarget` containment test — outside-dismissal evaluated against the overlay tree
  including its chrome, not against a raw focus event.

## Weaknesses

- The tooltip pattern lacks task force consensus, has no example, and `role="tooltip"` occurs in no
  example page in the corpus. The subject APG is most often cited for is the one it has not shipped.
- "A hover that contains focusable elements can be made using a non-modal dialog" points at a
  pattern APG does not document — three prose mentions, no page, no example. The hovercard case is
  unresolved here.
- No collision detection of any kind: no flip, shift, clamp or viewport awareness for any popup.
  `isElementInView` exists but only ever triggers a scroll of the active option.
- Five different outside-dismissal events across five examples implementing one predicate — and
  Escape is bound on `keyup` in `dialog.js` but keydown everywhere else.
- No hover-driven test exists in the Selenium suite, so the WCAG 1.4.13 behaviors the toolbar
  example claims are unverified by APG's own oracle.
- Neither reference to SC 1.4.13 states all three of its requirements; each paraphrases a different
  subset.
- The tooltip pattern says a tooltip "typically appears after a small delay"; the only
  implementation shows it instantly on focus and on `mouseover`. Docs contradict source.
- No hover-intent protection anywhere: `closePopupAll(target)` runs before opening on every hover,
  so diagonal travel to a submenu across a sibling closes it with no recovery window.
- Attribute-as-state in two forms, the worse reading back through the CSSOM
  (`window.getComputedStyle(this.dialogNode).display !== 'none'`).
- Per-menu state is keyed by strings derived from `aria-label` with a non-global
  `.replace(' ', '-')`, so only the first space is replaced and labels can collide.
- `dialog.js` and `alertdialog.js` are copy-pasted and have diverged on modality — a LIFO stack in
  one, a single global in the other, under identical names and doc comments.
- Dead code survives fixes: `this.ignoreBlur = true` has had no reader in `content/` since
  [`164188c4`][commit-scrollbar].
- Three unrelated magic z-indexes (100, 2, 1) with no ordering discipline; one commit exists whose
  entire content was raising the backdrop's.
- No RTL or writing-mode support in any anchored overlay — all placement is physical `left`/`top`.
- Touch and mobile are explicitly out of scope ("there is not yet a standardized approach for
  providing touch interactions that work across mobile browsers",
  [`read-me-first-practice.html:82-88`][readme-touch]), leaving every hover-dependent mechanism with
  no stated fallback.
- `closePopup` in `menubar-editor.js` declares `var menu, cmi` and returns `cmi` unassigned on the
  has-popup branch ([`:437-455`][mbe-close]); callers would pass `undefined` into `getMenuId`.
  Unreachable in the shipped markup, but a latent defect for anyone adding a nested submenu there.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                                                                   | Rationale                                                                                                                                                                                                                                                                                                                                                                                                                          | Trade-off                                                                                                                                                                                                                                                                                                                                       |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Ship the tooltip-like widget that carries the WCAG conformance claim as a DOM **child** of its trigger, labelled `popup-label`, with no `role="tooltip"` and no `aria-describedby`, hidden by `top: -30000em` rather than `display: none`. | Because the span lives inside the button, its text contributes to the button's accessible **name** at all times, visible or not; off-screen positioning keeps it in the accessibility tree, so the label survives with no tooltip machinery. DOM containment also makes the popup hoverable for free: `mouseleave` is defined over the ancestor chain, so entering the geometrically separate label never leaves the button.       | It is not a tooltip: no role, no description semantics, and the text is folded into the accessible name whether or not the author wanted a name-plus-description pair. It cannot hold anything the button's name should not contain. And APG's own SC 1.4.13 conformance claim rests on a widget that does not implement APG's tooltip pattern. |
| Make submenu containment normative: a submenu's `menu` must be inside the same `menu` as its parent item and be the sibling immediately following it.                                                                                      | It makes the popup's identity positional (`menuitem.nextElementSibling`), makes ownership and cascade-closing pure ancestry tests, and keeps the AT reading order matching the visual nesting without `aria-owns` fixups — which the pattern's own closing note warns reorder the reading sequence.                                                                                                                                | It forbids portals and therefore forbids escaping a clipping or stacking ancestor — the practical reason DOM toolkits portal at all. APG accepts overflow clipping as the price. For a toolkit with no top layer this constraint is free; for a DOM toolkit it is the one everyone breaks.                                                      |
| Implement deferred closing as a timer that always fires plus a predicate re-checked at fire time, rather than a cancellable timer.                                                                                                         | There is no timer handle to store, invalidate or leak; re-entry is expressed as ordinary state (`hasHover = true`) rather than as a scheduling operation; and the same predicate serves the non-deferred paths via a `force` argument. In the autocomplete combobox the predicate is a three-flag conjunction covering hover and both visual-focus states, so one guard serves pointer travel, keyboard travel and outside clicks. | The timer fires unconditionally, so there is wasted wakeup work; and the predicate must be correct for every state reachable during the delay window. That is exactly the class of defect the `!this.hasHover` guard introduces — a blur while the pointer is still over the button will not hide the label.                                    |
| Keep a combobox's `listbox`/`grid`/`tree` popup unfocused, with DOM focus pinned to the input and `aria-activedescendant` naming the active option — modelled as an application-owned pair of booleans rather than any DOM fact.           | An editable combobox must keep the caret and text editing alive while the user arrows through suggestions; moving DOM focus would break both. The `aria-activedescendant` DOM-relationship rules carry a condition for exactly this case, and the implementation makes "where the visual focus is" an ordinary value — the same thing a canvas toolkit must do, having no DOM focus at all.                                        | The application takes on obligations the browser would otherwise discharge: browsers do not scroll `aria-activedescendant` targets into view, so the app must, and it must draw its own focus ring. It also fails for dialog popups, which cannot use `aria-activedescendant`, so the pattern needs a second, incompatible focus regime.        |
| Implement no hover-intent protection for submenus: on `pointerover`, close every non-ancestor popup immediately, then open the hovered item's popup.                                                                                       | It keeps the state machine trivially consistent — every hover fully restores the invariant "exactly the ancestors of the active item are open" — with no timers, no geometry and no trajectory state. Combined with armed hover, the widget feels responsive and never shows a stale menu.                                                                                                                                         | Diagonal travel from a parent item toward its submenu, crossing a sibling item, closes the submenu you were aiming at with no recovery window. APG ships this in both menubar examples; nothing in the corpus mitigates it and no test covers it.                                                                                               |
| Define modal as a conjunction of three independently-authored things — the `aria-modal` bit, real interaction blocking, and visual obscuring — and warn that setting the bit alone is actively harmful.                                    | `aria-modal` removes the outside world from AT perception. If the outside world is still reachable by everyone else, AT users are strictly worse off than if the bit were absent. Making it a conjunction forces authors to treat the accessibility flag as a consequence of behavior, not a substitute for it.                                                                                                                    | Nothing enforces the conjunction; it is prose. The reference implementation satisfies it with a hand-rolled backdrop, a body scroll-lock class and a focus trap — three unrelated mechanisms a copier can take partially. And the scrim, one of the three, is disabled below 640 px by a media query.                                           |
| Bind every regression test to a `data-test-id` attribute in the example page's own documentation table, and fail the test if that row is missing.                                                                                          | It makes the documented behavior the index of the test suite: you cannot test an undocumented behavior and you cannot silently delete a documented one. `ariaTest.failing` records known-broken behaviors as expected failures that flip red if they start passing, so the promise/implementation gap is tracked.                                                                                                                  | It couples prose editing to test breakage, and it covers only what the tables describe — which is why the suite contains no hover-driven test despite hover being load-bearing for the popup label, the armed menubar and the autocomplete listbox.                                                                                             |

> [!NOTE]
> **Not verified here.** The Selenium/AVA suite was not executed (it needs geckodriver and a
> Firefox binary), so every statement about tests comes from reading test source. No claim is made
> about what a user agent or a shipping screen reader actually produces from this markup, nor about
> whether a real pixel gap exists between the popup label and its button. Coverage was the six named
> patterns plus toolbar, alertdialog, grid-combo and three practices pages; absence claims were
> checked by repository-wide grep over `content/` and `test/`, excluding vendored bundles.

## Sources

- Patterns: [tooltip][tooltip-consensus], [menu and menubar][menubar-submenu],
  [combobox][combobox-focus], [modal dialog][dialog-modality].
- Practices: [keyboard interface][kbd-roving] (roving `tabindex` and `aria-activedescendant`
  algorithms, DOM-relationship restrictions), [names and descriptions][names-nfc],
  [read me first][readme-touch] (the mobile/touch disclaimer).
- Reference implementations: [`menubar-editor.js`][mbe-open], [`menubar-navigation.js`][mbn-open],
  [`menu-button-actions.js`][mb-roving] and
  [`menu-button-actions-active-descendant.js`][mb-ad], [`select-only.js`][so-action],
  [`combobox-autocomplete.js`][ca-close], [`combobox-datepicker.js`][dp-ring],
  [`grid-combo.js`][gc-esc], [`dialog.js`][dlg-trap], [`alertdialog.js`][adlg-single],
  [`disclosureMenu.js`][dm-toggle], [`FormatToolbarItem.js`][fti-delay].
- Stylesheets: [`toolbar.css`][tb-css-arrow], [`dialog.css`][dlg-css-base],
  [`select-only.css`][so-css], [`disclosure-card.css`][dc-dur].
- Regression harness: [`test/index.js`][test-index].
- Commits: [`ccfa79e8`][commit-tabindex] (roving-tabindex race across three open paths),
  [`164188c4`][commit-scrollbar] (scrollbar-click dismissal), [`d0577918`][commit-zindex] (backdrop
  z-index), [`a6f3fbe3`][commit-hoverable] (hover-bridge wording), [`b28a984e`][commit-codepen]
  (per-example copy/CodePen policy).
- External, cited but **not** in this repository: [WCAG 2.1 SC 1.4.13][wcag-1413].

<!-- References -->

[apg-repo]: https://github.com/w3c/aria-practices/tree/7e4034b262bc0d25332e330d8a582aaf34113829
[apg-docs]: https://www.w3.org/WAI/ARIA/apg/
[wcag-1413]: https://www.w3.org/TR/WCAG21/#content-on-hover-or-focus
[tooltip-consensus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L23
[tooltip-delay]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L28
[tooltip-nofocus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L31-L32
[tooltip-noexample]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L39
[tooltip-focusstays]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L48
[tooltip-rsp]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/tooltip/tooltip-pattern.html#L57-L60
[menubar-shiftf10]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/menu-and-menubar-pattern.html#L25
[menubar-focusfirst]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/menu-and-menubar-pattern.html#L62
[menubar-submenu]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/menu-and-menubar-pattern.html#L199-L200
[menubar-tabindex]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/menu-and-menubar-pattern.html#L209-L210
[menubar-ariaowns]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/menu-and-menubar-pattern.html#L242
[combobox-esc]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/combobox-pattern.html#L95-L96
[combobox-tabseq]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/combobox-pattern.html#L119
[combobox-dialog]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/combobox-pattern.html#L395
[combobox-focus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/combobox-pattern.html#L420
[dialog-inert]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/dialog-modal-pattern.html#L24-L26
[dialog-nonmodal]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/dialog-modal-pattern.html#L31
[dialog-modality]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/dialog-modal-pattern.html#L145-L150
[dialog-legacy]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/dialog-modal-pattern.html#L153-L156
[names-nfc]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/names-and-descriptions/names-and-descriptions-practice.html#L182
[names-title-435]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/names-and-descriptions/names-and-descriptions-practice.html#L435
[names-tooltip-row]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/names-and-descriptions/names-and-descriptions-practice.html#L1438-L1443
[names-title-1741]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/names-and-descriptions/names-and-descriptions-practice.html#L1741
[kbd-roving]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/keyboard-interface/keyboard-interface-practice.html#L296
[kbd-ad]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/keyboard-interface/keyboard-interface-practice.html#L325
[kbd-domrel]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/keyboard-interface/keyboard-interface-practice.html#L364-L376
[readme-touch]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/practices/read-me-first/read-me-first-practice.html#L82-L88
[mbe-setfocus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L143
[mbe-firstchar]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L209
[mbe-idlabel]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L249
[mbe-open]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L419-L435
[mbe-close]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L437-L455
[mbe-dnc]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L457-L475
[mbe-isopen]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L481
[mbe-hover]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L699
[mbe-bg]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-editor.js#L36
[mbn-open]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-navigation.js#L430-L450
[mbn-popout]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-navigation.js#L459-L472
[mbn-hover]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menubar/examples/js/menubar-navigation.js#L709-L720
[mb-roving]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menu-button/examples/js/menu-button-actions.js#L62-L71
[mb-open]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menu-button/examples/js/menu-button-actions.js#L152-L162
[mb-click]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menu-button/examples/js/menu-button-actions.js#L312
[mb-bg]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menu-button/examples/js/menu-button-actions.js#L324
[mb-ad]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/menu-button/examples/js/menu-button-actions-active-descendant.js#L63-L75
[so-action]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L37-L80
[so-letter]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L84-L107
[so-index]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L110-L129
[so-inview]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L132
[so-scrollable]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L146
[so-maintain]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L152-L164
[so-state]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L181-L185
[so-search]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L229-L238
[so-blur]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L249-L253
[so-scroll]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L338-L339
[so-ignoreblur]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L358
[so-update]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/select-only.js#L377-L380
[so-css]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/css/select-only.css#L57-L69
[ca-inview]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L107
[ca-close]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L295-L312
[ca-vf-combo]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L164
[ca-vf-list]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L172
[ca-bgup]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L536
[ca-out]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-autocomplete.js#L565-L568
[cal-scroll]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/combobox-autocomplete-list.html#L135-L137
[dp-mouseup]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-datepicker.js#L127
[dp-zindex]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-datepicker.js#L232
[dp-computed]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-datepicker.js#L242
[dp-ring]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/combobox-datepicker.js#L259-L270
[gc-esc]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/combobox/examples/js/grid-combo.js#L79-L102
[dlg-first]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L29-L40
[dlg-attempt]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L69-L82
[dlg-stack]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L85-L92
[dlg-escape]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L106-L114
[dlg-backdrop]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L156-L171
[dlg-required]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L173-L181
[dlg-sentinels]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L191-L205
[dlg-handoff]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L209-L214
[dlg-trap]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/js/dialog.js#L296-L310
[dlg-css-base]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/css/dialog.css#L5-L11
[dlg-css-media]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/css/dialog.css#L13-L23
[dlg-css-backdrop]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/css/dialog.css#L110-L118
[dlg-css-scrim]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/css/dialog.css#L121-L125
[dlg-css-hasdialog]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/dialog-modal/examples/css/dialog.css#L136-L138
[adlg-single]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/alertdialog/examples/js/alertdialog.js#L150
[dm-openindex]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/js/disclosureMenu.js#L14
[dm-toggle]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/js/disclosureMenu.js#L156-L168
[dn-esc]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/disclosure-navigation.html#L163-L169
[dn-caret]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/disclosure-navigation.html#L170
[dc-inert]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/js/disclosure-card.js#L41
[dc-dur]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/css/disclosure-card.css#L13-L14
[dc-rm]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/disclosure/examples/css/disclosure-card.css#L24-L27
[tb-html]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/toolbar.html#L59-L62
[tb-wcag]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/toolbar.html#L171-L179
[tb-css-popup]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/css/toolbar.css#L45-L47
[tb-css-show]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/css/toolbar.css#L62-L65
[tb-css-arrow]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/css/toolbar.css#L67-L89
[fti-delay]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/js/FormatToolbarItem.js#L17
[fti-hideall]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/js/FormatToolbarItem.js#L151-L156
[fti-focus]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/js/FormatToolbarItem.js#L171-L177
[fti-mouse]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/js/FormatToolbarItem.js#L180-L188
[ftb-hideall]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/content/patterns/toolbar/examples/js/FormatToolbar.js#L348
[test-index]: https://github.com/w3c/aria-practices/blob/7e4034b262bc0d25332e330d8a582aaf34113829/test/index.js#L78-L104
[commit-tabindex]: https://github.com/w3c/aria-practices/commit/ccfa79e83452b3513e1a9f05517a7da53695987f
[commit-scrollbar]: https://github.com/w3c/aria-practices/commit/164188c47c4164ee4b8801fcb33f576d872e0861
[commit-zindex]: https://github.com/w3c/aria-practices/commit/d05779184457932110f567d8aeb0f1645917e098
[commit-hoverable]: https://github.com/w3c/aria-practices/commit/a6f3fbe390469ff745a1f346aaaa3fce60f1a1a1
[commit-codepen]: https://github.com/w3c/aria-practices/commit/b28a984eef2669c5809444222babe39c7fe72ca9
