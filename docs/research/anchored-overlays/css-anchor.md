# CSS Anchor Positioning (W3C CSS Working Group — Level 1 WD + Level 2 ED)

A pure placement algebra: it defines how an absolutely positioned box derives its
insets, size and alignment from the border box of one or more other boxes — and
deliberately defines nothing else.

| Field             | Value                                                                                                                                                                                                          |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Bikeshed specification source (`.bs`). **Docs-only subject** — the tree read contains spec prose and an explainer, no implementation and no tests                                                              |
| License           | [W3C Software and Document License][w3c-license]                                                                                                                                                               |
| Repository        | [`w3c/csswg-drafts`][repo] — `css-anchor-position-1/Overview.bs`, `css-anchor-position-2/Overview.bs`, `css-anchor-position-1/anchored_container_query.md`                                                     |
| Documentation     | [CSS Anchor Positioning Level 1][ed-1] (Working Draft, Work Status "refining"), [Level 2][ed-2] (Editor's Draft, Work Status "exploring", a delta spec)                                                        |
| Category          | Web platform — specification, not an implementation                                                                                                                                                            |
| Surface model     | In-canvas. Everything renders inside the document; the only "layer" is `css-position-4`'s UA-managed [top layer][concepts], a paint-order set of boxes parented to the root stacking context — not an OS popup |
| **Revision read** | [`6dc15cc9cb15043840eacf081e89f5a666fa7889`][repo-sha]                                                                                                                                                         |

> [!IMPORTANT]
> This page is a **specification reading**, not an implementation reading. No
> browser source and no web-platform tests were consulted; the clone at this SHA
> contains no `css-anchor-position` test directory. Where shipping engines differ
> from this text, the engines were not checked — see [`./blink.md`][blink] for the
> Chromium side. Every "the spec says" below is literally that.

## Overview

### What it solves

The problem the module takes on is narrow and geometric: given a box that is out
of flow, let its insets, its size constraints and its self-alignment be computed
from the [anchor rect][concepts] of some other box, with a declarative,
ordered fallback list for the case where the preferred [placement][concepts]
overflows. Nothing in the module observes input, runs a timer, moves focus,
closes anything, or draws an arrow.

The intro example makes the scope visible in six lines of author CSS — a tooltip
that needs no containing-block gymnastics because it is `position: fixed` and
still resolves its insets from a named anchor:

> ```css
> .tooltip {
>     /* Fixpos means we don't need to worry about
>        containing block relationships;
>        the tooltip can live anywhere in the DOM. */
>     position: fixed;
> ```
>
> — `css-anchor-position-1/Overview.bs:91-94` ([pinned][q-fixpos])

That is also the module's answer to portals: with `position: fixed` plus
`anchor()`, the DOM-containment question that forces other web stacks to
re-parent an overlay simply does not arise (dimension 10).

### Design philosophy

The philosophy shows up as three deliberate refusals.

**Termination over expressiveness.** The set of legal anchors is restricted a
priori, so a cycle cannot be constructed — no cycle detector is needed. The
restriction is not invented for the occasion; it is a restatement of an ordering
the engine already computes:

> The list of conditions below exactly rephrases the stacking context rules into
> just what's relevant for this purpose, ensuring there is no possibility of
> circularity in anchor positioning.
>
> — `css-anchor-position-1/Overview.bs:392-396` ([pinned][q-circularity])

The predicate itself reduces to one phrase — `|possible anchor| is laid out
strictly before |positioned el|` (`Overview.bs:467`, [pinned][q-strictly-before])
— unrolled into containing-block, top-layer and flat-tree clauses.

**A minimal mutable surface.** A fallback candidate may change only geometry:

> Note: The [=accepted @position-try properties=] are the smallest group of
> properties that affect just the size and position of the box itself, without
> otherwise changing its contents or styling. This significantly simplifies the
> implementation of position fallback […]
>
> — `css-anchor-position-1/Overview.bs:1897-1902` ([pinned][q-minimal-props])

**Stability over optimality.** Once a candidate wins, it keeps winning until it
itself overflows:

> Once an option has been chosen, the element keeps those styles until it
> overflows again, even if an earlier (and presumably more desirable) option
> again becomes available without causing overflow.
>
> — `css-anchor-position-1/Overview.bs:1518-1521` ([pinned][q-hysteresis])

And one refusal that is stated at normative strength (an `Advisement`, the
strongest non-normative device Bikeshed offers):

> Advisement: CSS Anchor Positioning does not create, delete, or alter any
> accessibility bindings between elements. Authors must use appropriate markup
> features to control such bindings.
>
> — `css-anchor-position-1/Overview.bs:2476-2477` ([pinned][q-advisement])

## How it works

Four value-typed pieces, one algorithm each.

**1. An anchor is a name, not a handle.** `anchor-name: --foo` marks an element's
principal box as an _anchor box_. The name is a _tree-scoped name_ — an
`(identifier, node-tree root)` pair whose equality is a value comparison
(`css-shadow-1/Overview.bs:865-869`). `position-anchor` names a box's _default
anchor_; `anchor()` may name a different one per function call. Resolution is a
query, re-run per querying box, never a stored pointer.

**2. Placement has two unequal layers.** The coarse layer is `position-area`, a
3×3 grid derived from the anchor and the containing block; selecting a region
_replaces the box's containing block_. The fine layer is `anchor()`, which
returns a `<length>` usable anywhere a length is — inside `calc()`, `min()`,
`max()`.

```css
/* coarse: one canonical pair of keywords */
.tip {
  position-area: block-start span-inline-end;
}

/* fine: a length, so arithmetic composes */
.tip {
  top: calc(anchor(bottom) + 8px);
}
.line {
  bottom: max(anchor(--a1 top), anchor(--a2 top), anchor(--a3 top));
}
```

**3. Fallback is data.** `position-try-fallbacks` names an ordered list whose
entries are either `@position-try` rules (bundles of geometry declarations) or
_try-tactics_ (`flip-block`, `flip-inline`, `flip-start`) that are applied as a
transform over the base styles. `position-try-order: most-height` (and siblings)
pre-sorts the list by resulting available size.

**4. Hiding is a keyword.** `position-visibility: always | [anchor-valid ||
anchor-visible || no-overflow]`, whose initial value is `anchor-visible` — so a
box hides itself by default when its default anchor is clipped away.

The engine side is one loop, `determine position fallback styles`, with a
rect-containment fit predicate and an incumbent skip:

```text
for option in positionOptionsList:
    if option is lastSuccessfulPositionOption: continue     # hysteresis
    styles  := apply(option)
    elRect  := marginBox(abspos, styles)
    cbRect  := insetModifiedContainingBlock(abspos, styles)
    if cbRect was negative-size in either axis and clamped to zero: continue
    if not (elRect subset-of cbRect): continue
    return styles + rememberedScrollOffsets(styles)
return currentStyles                                        # nothing fits
```

— `css-anchor-position-1/Overview.bs:1956-2004` ([pinned][alg-fallback]).

## The analysis spine

### 1. Anchor model

An anchor is a **name with a scope**, and what the name resolves to is a
**rect**. `anchor-name: <dashed-ident>` makes an element an anchor element
(`Overview.bs:202-231`); names need **not** be unique (`:233`). Resolution
(`Overview.bs:398-453`) is: if an _ancestor_ of the querying element satisfies
the conditions, take the nearest such; otherwise take the **last element in tree
order** that satisfies them (`:420-424`) — an ordering rule the changelog records
as changed in December 2025 to match timeline-name lookups (`:2725-2728`).
"Loose" name matching accepts names declared in an ancestor tree; `anchor-scope`
switches selected names to strict same-tree matching (`:276-331`).

The resolved rect is the **border box of the principal box, taken after layout**,
including zoom, relative/sticky offsets and transforms, reduced to "the
axis-aligned bounding rectangle of the anchor box in the coordinate space of the
absolutely positioned element's containing block" (`:161-167`). A fragmented
anchor collapses to the bounding rect of its fragments when the querying box is
outside the fragmentation context (`:173-179`) — there is no per-fragment
placement.

There are **no [virtual anchors][concepts]**: the target "is either an element or
a fully styleable pseudo-element" (`:460-461`), so a point, a caret, a cursor
position or a text range cannot be anchored to. Conversely, one box may reference
**many** anchors at once and combine them arithmetically — the spec's chart
example spans a line across the tallest of three bars with
`max(anchor(--anchor-1 top), …)` (`:1000-1018`). `position-anchor: match-parent`
(`:541-546`) lets a subtree inherit its parent's _resolved_ anchor, which is the
closest the module comes to passing a handle. Implicit anchors are supplied by
the host language — a pseudo-element's implicit anchor is its originating element
(`:597-599`).

**Algorithm.**

```text
resolve(queryEl, spec):
    if spec absent:  return defaultAnchor(queryEl)          # position-anchor
    if spec == auto: return implicitAnchor(queryEl) if acceptable else none
    C := { el : el has anchor-name matching spec, el acceptable-for queryEl }
    if any ancestor of queryEl in C: return nearest such
    return last element of C in tree order, else none
```

**Where the behavior lives.** Style-system name resolution plus layout. There is
no DOM API — no `getAnchor()`; the CSSOM surface is declaration serialization
only (`:2551-2637`).

**Degradation.** This dimension survives every degraded target. A
`(name, scope-root)` pair is a comparable value with no lifetime, and resolution
is a pure query over an already-ordered tree — it needs no OS window, no hover,
no script and no key release. The one part that does not port unchanged is the
_rect_: the spec's is a post-transform floating-point bounding box, whereas a
cell grid has integer rects and no transforms.

### 2. Placement model

Two layers, deliberately unequal.

**Coarse — `position-area`.** Per axis the engine builds four lines
(`Overview.bs:705-716`): the containing block's start edge _or_ the anchor's
start edge if that is further start-ward; the anchor start; the anchor end; the
containing block's end edge _or_ the anchor end if that is further end-ward. A
`<position-area>` value names a contiguous run of tracks per axis
(`span-<side>` = that side's track plus centre; `span-all` = all three). Choosing
a region does not move the box — **it replaces the box's containing block**
(`:685-691`), so `max-height: 100%` and every inset subsequently resolve against
the region.

Side and alignment are therefore **not independent** in this layer: the region
_implies_ the [gravity][concepts]. Centre-only track → `center`; all three tracks
→ `anchor-center`; otherwise align toward the _non-specified_ side track
(`:1280-1292`), with a documented exception when exactly one inset in the axis is
non-`auto`, which then wins and becomes an `unsafe` alignment (`:1294-1297`).

Keyword ambiguity is resolved positionally: an ambiguous keyword takes the axis
the other keyword did not claim, and if both are ambiguous the first is the block
axis (`:804-814`); a single keyword expands to `<kw> span-all` when unambiguous,
else `<kw> <kw>` (`:816-821`). The computed value is a canonical **pair** of
keywords (`:826-832`) — comparable and serializable.

**Fine — `anchor()`.** The grammar is
`anchor(<anchor-name>? && <anchor-side>, <length-percentage>?)`
(`:861-867`). `<anchor-side>` covers `inside`/`outside`,
the physical sides, the logical `start`/`end`/`self-start`/`self-end` family,
`center`, and a raw `<percentage>` that interpolates start→end. `inside` and
`outside` are **relative to the property the function appears in** — the same
token names different edges in `top:` and in `bottom:` (`:895-901`, worked at
`:957-974`). Physical keywords are axis-checked: `anchor(left)` inside `top:` is
an unresolvable function (`:1030-1033`). The logical vocabulary is a three-way
matrix — `start`/`end` resolve against the _containing block's_ writing mode,
`self-*` against the _box's own_, and `x-start`/`y-end` pin the physical axis
while taking direction from writing mode (`:772-782`). RTL and vertical writing
are consequently handled by keyword→edge resolution, never by a runtime mirror
flag.

**Shift is not defined here.** Sliding along the cross axis is inherited wholesale
from `css-align-3`'s default overflow self-alignment for out-of-flow boxes, a
three-step algorithm over an _overflow limit rect_ = the bounding box of the
inset-modified containing block and the original containing block
(`css-align-3/Overview.bs:901-930`). That is why a `position-area: bottom
span-right` popup slides left rather than hanging off the edge
(`Overview.bs:1326-1333`).

**Viewport padding has no dedicated knob.** It is expressed as margins on the
positioned box, or via `env(safe-area-inset-*)` in an inset — and the try-tactic
machinery then rewrites _which_ environment variable is referenced when it flips
the box (dimension 15).

> [!NOTE]
> No IME / virtual-keyboard inset was found: at this SHA, `css-env-1/Overview.bs`
> declares only `safe-area-inset-*` and `viewport-segment-*` (`:104-231`). Whether
> such a variable exists in another specification was not checked.

**Where the behavior lives.** Style value parsing (keyword→axis assignment,
canonical computed pair), the out-of-flow layout algorithm in `css-position-3`
(the inset-modified containing block), and `css-align-3` (safe/unsafe shifting).
Nothing in a widget library.

**Degradation.** Integer-safe and script-free throughout — `position-area` is
exactly a 3×3 integer-cell region selector, and because this is CSS rather than
JS, the entire dimension evaluates on a **no-script** target. The pieces that
need real measurement are `anchor-size()` and the alignment shift, both of which
a cell toolkit already has before paint. With **no sub-cell precision**,
`anchor(50%)` / `center` needs a rounding rule the spec does not supply (it works
in fractional CSS pixels); a cell toolkit must choose floor-or-round once and
apply it everywhere.

### 3. Collision & geometry engine

The overflow test is startlingly small. `el rect` is the box's **margin box**;
`cb rect` is its **inset-modified containing block**; the option succeeds iff the
first is fully contained in the second (`Overview.bs:1970-1985`). Descendant
overflow is explicitly ignored — "only |el|'s own margin box" (`:1995-1997`).
There is **no boundary parameter and no padding parameter**: the
[clipping boundary][concepts] _is_ the inset-modified containing block, and the
author shapes it with insets and `position-area`.

One guard is worth transcribing exactly: if the containing block came out
negative-sized in an axis and was clamped to zero, the option is **rejected
rather than tested**, because otherwise "a zero-size |el rect|" would be
"considered 'inside' a negative-size |cb rect|" and win (`:1974-1981`).

Clipping-ancestor discovery exists only for `position-visibility`, and is defined
by _reference_ to `IntersectionObserver`'s clip set — `clip-path`, `overflow`,
paint containment, clipping to the overflow clip edge — over boxes that are
ancestors of the anchor and descendants of the querying box's containing block,
with a non-zero-intersection requirement for non-zero-area anchors (`:2263-2278`).

**Scroll is the deep part, and it is a compromise.** Because a box may take its
two opposite edges from anchors in _different_ scroll containers, scrolling could
change the box's **size** — which is layout, which cannot run on a compositor
thread (`:1064-1073`). The answer: at an _anchor recalculation point_ (the box
starts generating boxes, or changes fallback), every referenced anchor records a
**remembered scroll offset** = the summed scroll offsets of its scroll-container
ancestors up to the querying box's containing block; thereafter every anchor
reference is computed as if all scrollers sat at their initial position, plus the
remembered offset (`:1150-1184`). All anchors but one are therefore **frozen in
scroll**, and the spec says so plainly: "if any of them are scrolled, the
positioned element will no longer appear to be anchored to them" (`:1191-1194`).
The exception is the default anchor, whose scroll delta is applied _after_ layout
"as if affected by a transform (before any other transforms)" (`:1237-1240`) — a
pure translate that cannot trigger layout. The abstraction is admitted to leak:
`round(anchor(outside), 50px)` distinguishes offsetting the _value_ from
translating the _box_ (`:1249-1259`).

Tracking is **lifecycle-slotted, not polled**: the last-successful-option
recording happens "at the time that ResizeObserver events are determined and
delivered" (`:2050-2051`), and the anchor-clipped check runs after content
relevancy is updated and after `ResizeObserver`s but **before**
`IntersectionObserver`s (`:2280-2285`).

> [!WARNING]
> The scroll-offset snapshot timing is **unspecified** at this revision. A commit
> that defined it (`54fd028ea`) was reverted by `31491a8b4` on 2026-04-28,
> restoring a bare "Issue: Define the precise timing of the snapshot"
> (`Overview.bs:1242-1244`). Transforms are handled only partially: they are
> included in the anchor rect but "may be delayed by a few frames" (`:168-171`),
> and whether to compensate for them is an open issue (`:1185-1187`, `:1246-1247`).

Cost is bounded three ways: an implementation-defined cap on the candidate list
with a spec'd floor ("This limit must be _at least_ five", `:1951-1954`); a hard
"Layout does not 'go backward', in other words" rule (`:2022`) motivated by "At
best, this can result in exponential layout costs; at worst, it's cyclic and will
never settle" (`:2019-2020`); and the incumbent skip.

**Where the behavior lives.** Entirely in the engine kernel: style–layout
interleaving (`:2660-2687`), the out-of-flow layout pass, and rendering-lifecycle
slots shared with `ResizeObserver` / `IntersectionObserver` / `content-visibility`.

**Degradation.** What generalizes off the DOM: the fit predicate (one
rect-contains-rect test against one boundary, no middleware chain); the candidate
loop with an incumbent skip; a single fixed evaluation slot per frame with a
stated order relative to other observers; and the negative-boundary guard. What
does not: the whole remembered-scroll-offset regime is an artifact of a
compositor thread that can translate but cannot lay out — a toolkit that
recomputes its display list every frame has no such thread and should not import
the freeze. Off the DOM there are also no clipping ancestors to discover; the
equivalent question is "is the anchor rect inside the visible pane rect", which
is answerable directly. On a **no-script** target the engine still evaluates all
of it; on a recording canvas every input (anchor rect, boundary rect, candidate
list) is a value, so the dimension is assertable with zero I/O.

### 4. Arrow / caret geometry

**Level 1 has no arrow concept at all** — no `::tether` pseudo-element, no arrow
property, and no exposure of which side was chosen. The Level 2 answer is
indirect: `container-type: anchored` plus `@container anchored(fallback: …)`
makes **the chosen fallback queryable as data**, and the delta spec's own worked
example is precisely an arrow — `position-area: left; position-try-fallbacks:
right;` with `&::before { content: ">" }` overridden inside
`@container anchored(fallback: right)` (`css-anchor-position-2/Overview.bs:155-173`).

What is queried is a **token, not geometry**: either `none`, or a
`<dashed-ident> || <try-tactic>` combination that must match _in order_
("flip-start flip-block is not the same as flip-block flip-start",
`css-anchor-position-2/Overview.bs:140-143`), or a `<position-area-query>` that
matches by _resolved physical_ area — so `block-start` matches an applied `top` in
`horizontal-tb` (`:147-150`) — with an `any` wildcard per axis and a
single-keyword default of `any` rather than `span-all` (`:295-299`).

Two hard limits, both stated in the explainer. A container query cannot restyle
its own container, so **the anchored element cannot react to its own chosen
placement** — only its descendants can (`anchored_container_query.md:139-146`).
And the `::tether` alternative was examined and set aside as "complicated",
specifically because it wants to pull the pseudo's box out as a sibling of its
originating element, which is known to break size container queries (`:148-168`).
There is no arrow-size-feeds-offset mechanism (authors write
`top: calc(anchor(bottom) + 8px)` by hand), no [transform origin][concepts]
derivation, no corner clamping, and no arrow-hiding rule for a too-narrow anchor.

**Algorithm.** None for geometry. The available mechanism is a categorical
read-back:

```text
chosen : none | (name?, tacticSequence) | positionArea
match(query, chosen) :=
    tactic sequences compare by ORDER-SENSITIVE equality
    position-areas compare by RESOLVED PHYSICAL equality, with `any` per axis
```

**Where the behavior lives.** In the Level 2 delta, inside the container-query
engine (which already interleaves style and layout) — not in the anchor engine.
Arrow _rendering_ is entirely author CSS on `::before` / `::after`.

**Degradation.** This is the dimension where a cell grid _helps_: at
one-character resolution an arrow is one cell holding a directional glyph placed
on the border row or column at a clamped offset, so its geometry is two integers
and a side enum — no radius, no shadow, no transform origin to approximate, and
nothing sub-cell to centre. The transferable lesson from the spec is the
**plumbing rather than the drawing**: emit the resolved side and alignment as a
value in the layout result. INFERENCE: sparkles has no rule forbidding an element
from inspecting its own resolved placement, so it need not adopt the web's
container-query indirection — the restriction that forced it exists only because
a CSS container cannot restyle itself. Nothing here depends on hover, script or
key release: arrow selection is a pure function of the resolved placement.

### 5. Trigger semantics

**Absence is the finding.** The module contains no trigger vocabulary of any kind
— no hover, focus, click, press, long-press, context-menu, shortcut or
programmatic show. Placement is a pure function of computed style plus layout,
re-evaluated whenever the engine lays out.

There are exactly two seams where a trigger-owning layer touches it. First, the
**implicit anchor element**: a host language may declare that element X is the
implicit anchor of element Y (`Overview.bs:582-599`), and HTML's popover
attribute does so as a side effect of establishing the invoker relationship — the
spec notes the invoker simultaneously sets `position: fixed`, creates the
anchoring relationship, links the invoker for accessibility and adjusts tab order
(`:115-119`, `:2507-2513`; see [`./popover-api.md`][popover-api]). Second,
`position-anchor: auto` (or an omitted name inside `anchor()`) is how an author
says "whatever the interaction layer decided my anchor is".

Multiple triggers cannot race here, because there is nothing to race over: one
style computation yields one anchor. INFERENCE: the design lesson this suggests
is that a placement primitive should take the anchor as an **input value**
resolved by whoever owns the interaction, and should never observe input itself.

**Where the behavior lives.** Outside the module entirely — HTML
(`popover` / `popovertarget`), CSS selectors (`:hover`, `:focus-within`,
`:checked`), or script.

**Degradation.** Trivially survives every target, because it does not exist —
which is exactly why the module is usable from a **static-HTML, no-script** tier:
a `:hover`-gated popup gets full anchor positioning with zero JavaScript. A
target with **no hover at all** likewise costs this dimension nothing; it costs
everything in the layer above.

### 6. Timing

No delays, [warm-up][concepts], [cool-down][concepts], skip-delay, singletons,
groups, re-entry or maximum durations exist anywhere in the module. The only
"timing" is **rendering-lifecycle ordering**, and it is specified with unusual
care because three observers and one visibility check must agree on an order:
the last-successful-option recording happens at `ResizeObserver` delivery time
and is explicitly aligned with last-remembered-sizes (`Overview.bs:2050-2051`,
`:2066-2067`); the anchor-clipped check runs after content-relevancy update and
after `ResizeObserver`s but before `IntersectionObserver`s, "and may also be
checked at other times to improve responsiveness" (`:2280-2285`).

**Algorithm.** The per-frame ordering the module implies:

```text
1. update content relevancy
2. run ResizeObservers
3. record last successful position option (or clear it, on a
   fallback-sensitive change)
4. evaluate anchor-clipped -> visibility
5. run IntersectionObservers
```

Placement itself is not a state machine at this level; it is re-derived.

**Where the behavior lives.** HTML's update-the-rendering steps, referenced by
the module rather than owned by it.

**Degradation.** With **no timers** nothing is lost, because nothing here is
time-based. The transferable part is the ordering contract, which is fully
assertable on a recording canvas: pin the per-frame order and never resolve
placement twice in a frame. INFERENCE: that even a purely declarative placement
engine needs a _named frame slot_ is suggested by the fact that the one slot the
CSSWG has not managed to name — the scroll snapshot (`:1242-1244`) — is also the
one still carrying an open issue.

### 7. Interactive hover (safe polygon / menu-aim)

**Not applicable.** There is no pointer model, no travel path, no
[safe polygon][concepts], no submenu intent and no debounce; CSS Anchor
Positioning cannot observe the pointer at all.

The nearest adjacent fact is structural rather than behavioural: because the
positioned box may be `position: fixed` and live anywhere in the DOM
(`Overview.bs:91-94`), DOM containment between trigger and overlay is explicitly
_not_ required. INFERENCE: that removes the one hover-bridging affordance a
script-free tier otherwise has — a child of the trigger stays `:hover`-ed — so a
toolkit that keeps overlays in the same widget tree as their trigger retains
something the web platform gave up here.

**Degradation.** INFERENCE, since the spec supplies no algorithm to degrade: with
one pointer and integer cells the anchor→overlay travel problem appears to reduce
to a tolerance _rectangle_ spanning the gap between trigger and surface — an
O(1) rect test rather than a polygon test. The asymmetry across targets matters
more than the algorithm: a target with **no hover** cannot run any of it, so
hover-intent must be a pure enhancement the other targets ignore. See
[`./concepts.md`][concepts] for the vocabulary and
[`./comparison.md`][comparison] for the subjects that do implement it.

### 8. Dismissal

There is no dismissal, but there **is** declarative auto-hiding, and it is on by
default. `position-visibility: always | [anchor-valid || anchor-visible ||
no-overflow]` has **`Initial: anchor-visible`** (`Overview.bs:2221-2229`) — so by
default an anchored box hides itself when its default anchor box is invisible or
clipped away. `anchor-valid` hides when the box references the default anchor but
that anchor cannot be resolved; `no-overflow` hides when the box still overflows
its inset-modified containing block after fallback has run (`:2236-2261`).

The hiding mechanism is `visibility: force-hidden`, which is stronger than
`hidden`: it hides descendants "regardless of their visibility value"
(`css-display-4/Overview.bs:1859-1864`), and invisible boxes "cannot be
interacted with (and behave as if they had `pointer-events: none`), are removed
from navigation (similar to `display: none`), and are also not rendered to
speech" (`css-display-4/Overview.bs:1890-1898`). That combination is what makes
**chained anchors** behave: a popup anchored to a popup whose own anchor scrolled
away hides too, "rather than also floating in a nonsensical location"
(`Overview.bs:2297-2301`).

One scoping subtlety is worth transcribing: the clip test is relative to the
querying box's containing block, so "if an abspos is next to its anchor in the
DOM… it'll remain visible even if its default anchor is scrolled off, since it's
clipped by the same scroller anyway" (`:2288-2291`).

Escape, outside-press, focus-loss, application deactivation, navigation and
parent-closing are all absent; they live in HTML's [light dismiss][concepts]
([`./popover-api.md`][popover-api]).

**Algorithm.**

```text
hidden :=  (anchor-valid  in V and box references default anchor
                          and default anchor unresolved)
        or (anchor-visible in V and (default anchor box is invisible
                          or clippedByInterveningBoxes(anchor, box)))
        or (no-overflow   in V and box still overflows its IMCB after fallback)

clippedByInterveningBoxes(a, p) :=
    a's ink overflow rect is fully clipped by some box that is an ancestor
    of a AND a descendant of containingBlock(p), considering clip-path /
    overflow / paint containment; non-zero-area anchors additionally
    require a non-zero intersection
```

**Where the behavior lives.** Layout plus the visibility computation. Notably the
clip test _reuses_ an existing engine primitive (`IntersectionObserver`'s
clipping model) rather than inventing one.

**Degradation.** Ports cleanly and is fully assertable off-DOM: three boolean
predicates over rects plus one resolution check. On a cell grid "clipped by
intervening boxes" becomes "the anchor's cell rect does not intersect the owning
pane's visible rect", available before paint, and the transitive-hide property
falls out for free if the hide flag propagates down an overlay-ownership tree.

> [!WARNING]
> Hiding here is **not closing**: no state changes, no event fires, and the box
> keeps occupying layout. On a **no-script** target there is also no way to
> re-show after hiding, so an on-by-default `anchor-visible` would be a one-way
> door there. INFERENCE: a toolkit copying this should default to `always` and
> let the caller opt in. (Whether shipping engines actually use `anchor-visible`
> as the initial value was not checked.)

### 9. Focus

**Not applicable, and the module says so at Advisement strength** (`:2476-2477`,
quoted above). It goes further and separates the two relations explicitly: the
visual anchor "might be between an element and its semantic anchor, or it might
connect the element to an ancestor, sibling, or descendant of the semantic
anchor" (`:2485-2488`), and "a design might opt out of a visual anchoring
relationship even while there is a semantic one, or vice versa" (`:2489-2490`).

It names HTML's Popover API as the thing that links invoker→popover and
"automatically adjust[s] tabbing order" (`:2507-2511`), and `aria-details` /
`aria-describedby` plus `role` for the manual case (`:2517-2527`). Tooltip /
popover / menu / dialog distinctions do not appear anywhere in the module — the
placement layer is uniform across all four.

**Where the behavior lives.** HTML (`popover`, `dialog`, `focusgroup`), ARIA, and
the accessibility tree — deliberately not here.

**Degradation.** Nothing to degrade. The finding that transfers is the factoring:
keeping [focus scope][concepts] policy out of the placement primitive is what
lets one placement engine serve a tooltip (no focus), a popover (focus moves, no
trap), a menu (roving tabindex) and a dialog (containment) without a mode flag on
the geometry. See [`./aria-apg.md`][aria-apg] for the pattern-level contracts.

### 10. Layering & portals

The module does not define layering but **depends on it load-bearingly**: the
acceptable-anchor rule is phrased partly in [top layer][concepts] terms — an
anchor qualifies if it shares an original containing block with the positioned
element and is either "in a lower top layer" than it, or in the same top layer
and (not out-of-flow, or earlier in flat-tree order) (`Overview.bs:467-474`). The
top layer is used as an **ordering**, exactly the role paint order plays in a
single-surface toolkit.

In `css-position-4` the top layer is an ordered set whose members "generate boxes
as if they were siblings of the root element", rendered in set order, last on top
(`css-position-4/Overview.bs:136-145`), each a new stacking context parented to
the root stacking context (`:265-268`). The public-API/implementation-detail line
is drawn outright — "The top layer is managed entirely by the user agent; it
cannot be directly manipulated by authors" — and justified by nesting: "nested
invocations of top-layer-using APIs, like a popup within a popup, will display
correctly" (`:166-171`). Other specs are told to use the add / request-removal /
process-removals algorithms rather than touching the set (`:177-190`, `:298-352`).
The `overlay: none | auto` property exists solely to keep an element in the top
layer for the duration of an exit transition (`:385-395`), and the spec
distinguishes "in the top layer" (for manipulation) from "rendered in the top
layer" (for rendering effects) so behaviour does not change based on whether a
transition is running (`:269-293`).

**Portals do not exist as a concept**, because `position: fixed` plus `anchor()`
makes them unnecessary (`Overview.bs:91-94`).

**Algorithm.**

```text
acceptableAnchor(a, p) :=
       a is an element or fully styleable pseudo-element
   and a is in scope for p (anchor-scope)
   and (   (sameOriginalCB(a, p)
            and (lowerTopLayer(a, p)
                 or (sameTopLayer(a, p)
                     and (not abspos(a) or flatTreeOrder(a) < flatTreeOrder(p)))))
        or acceptableAnchor(generatorOfContainingBlock(a), p))
   and (a in skippedContents(E)  ->  p in skippedContents(E))
```

**Where the behavior lives.** `css-position-4` (top layer, `overlay`) plus the
paint/stacking machinery. Anchor positioning only _reads_ the ordering.

**Degradation.** For a toolkit with no OS-level layer this is not a handicap but
the same model: the spec's top layer is itself an ordered set painted last-on-top,
and what a single-surface toolkit gives up is OS-level unclippability and the
`::backdrop` pseudo-element. INFERENCE: the transferable trick is that the
ordering predicate is defined **recursively through the containing-block chain**,
so "may A anchor B" is decidable from an ordering the engine already maintains.
Note the caveat, though — the CSS rule is a _conjunction_ (containing block, top
layer, flat-tree order, skipped contents), and its flat-tree-order clause applies
only between out-of-flow boxes; an in-flow anchor later in tree order is perfectly
acceptable, because in-flow layout precedes out-of-flow layout. A toolkit
transposing it must re-derive the equivalent predicate for its own ordering rather
than copy the clauses. See [`./sparkles-baseline.md`][baseline] and
[`./proposal.md`][proposal] for how that lands here.

### 11. Modality

**Not applicable.** No modal bit, no scrim, no light dismiss, no pointer or
keyboard blocking, no `inert`. The only adjacent behaviour is that an
anchor-hidden box becomes non-interactive and navigation-invisible via
`force-hidden` (`css-display-4/Overview.bs:1890-1898`) — a passthrough effect,
not [modality][concepts]. `::backdrop`, the scrim vehicle, belongs to the top
layer in `css-position-4` (`:256-268`), not to anchor positioning.

**Where the behavior lives.** HTML `dialog` / popover, plus `css-position-4`'s
`::backdrop`.

**Degradation.** Nothing to degrade — but worth recording as a boundary: the
placement primitive stayed clean precisely because modality was never allowed
into it.

### 12. Adaptive presentation

There is no form-factor adaptation here — no popover→sheet, no hover→long-press;
those are host-language decisions. What the module _does_ contain is a sharp
answer to "which layer owns an adaptive relayout", and the answer is a
**restriction**. `@position-try` accepts only inset properties, margin
properties, sizing properties, self-alignment properties, `position-anchor` and
`position-area` (`Overview.bs:1869-1877`), for the reason quoted in the Overview
— the smallest group that changes size and position and nothing else. Anything
richer is explicitly deferred to container queries (`:1906-1910`), which is
exactly what Level 2 then delivers.

Supporting details: `!important` inside `@position-try` invalidates the
individual declaration but not the rule (`:1879-1881`); the options apply in a
dedicated cascade origin, the **Position Fallback Origin**, between the Author
Origin and the Animation Origin (`:1883-1887`), with `revert` behaving as if the
property were in the Author Origin (`:1889-1895`).

The one genuinely adaptive pattern the spec demonstrates is
**scroll-instead-of-move**: pair each side with an `align-self: stretch` variant
and order the list by `most-height`, so the box prefers its natural height on the
roomier side and degrades to filling-and-scrolling there rather than jumping to
the cramped side (`:1729-1765`).

**Algorithm.** Adaptation is a list of named, _type-restricted_ style deltas
applied in a dedicated cascade origin, selected by the fit predicate and an
ordering heuristic. The restriction is what makes it tractable: each candidate is
a bounded set of geometry properties, so trying one costs one trial layout with
no content-reflow risk and no inheritance fallout.

**Where the behavior lives.** The cascade (a new origin) plus layout. Not a
component, not script.

**Degradation.** Transfers almost verbatim: a position option should be a small
**value** (a struct of insets, size constraints, alignment and area), not a
closure or a style sheet, and applying one must be forbidden from changing the
widget's content. A device inset — a notch, or a soft keyboard — then becomes just
another input to the boundary rect, and the sheet-versus-popover decision stays
above the primitive. See [`../platform-ui-guidelines/index.md`][platform-guidelines]
for the OS-level side of that decision.

### 13. Accessibility

Deliberately and completely out of scope, at Advisement strength (`:2476-2477`).
The reasoning is the module's strongest argument for keeping accessibility _out_
of a placement primitive: the visual anchor and the semantic anchor are genuinely
different relations and may point at different elements or exist independently
(`:2485-2490`). It then names the failure mode:

> Without appropriate markup, the elements linked visually have no meaningful DOM
> relationship — which if there is a meaningful relationship, can make them
> difficult or impossible to use in non-visual user agents, like screen readers,
> or in non-graphical navigation modes, such as tab navigation.
>
> — `css-anchor-position-1/Overview.bs:2495-2501` ([pinned][q-a11y-failure])

Positive guidance: use the Popover API, which links invoker, adjusts tab order
and sets the implicit anchor in one move (`:2507-2513`), or `aria-details` /
`aria-describedby` plus `role` (`:2517-2527`) — while cautioning that
"overburdening the page with extra, unnecessary semantic connections can also
make the page difficult to comprehend" (`:2529-2531`). An open issue solicits
better guidance (`:2533-2535`). No `role=tooltip`, no WCAG 1.4.13, no hover-only
hazard discussion and no statement about interactive tooltip content appear —
those belong to ARIA and WCAG ([`./aria-apg.md`][aria-apg]).

One incidental accessibility consequence _does_ live in the geometry:
`force-hidden` removes hidden anchored boxes from navigation and from speech
(`css-display-4/Overview.bs:1890-1898`), so `position-visibility` silently affects
assistive-technology exposure.

**Where the behavior lives.** ARIA and HTML. The CSS module contributes only the
`force-hidden` side effect.

**Degradation.** What belongs to the primitive is nothing but the hidden/visible
bit, because that one _is_ geometry-derived. Role, description-versus-label, tab
order and timing requirements belong to the semantic component. INFERENCE: an
anchored-overlay value should therefore carry a `visible` flag consumed by both
the paint pass and whatever exposure layer exists, and carry no role.

### 14. Animation

Three mechanisms, one of them a warning.

**(a) Resolution at computed-value time.** `anchor()` and `anchor-size()` resolve
via style-and-layout interleaving (`:940-948`, `:1455-1461`, `:2660-2687`), which
the spec says makes transitions and animations "work 'as expected' for all sorts
of possible changes: the anchor box moving, anchor elements being added or
removed from the document, the `anchor-name` property being changed on anchors"
(`:949-955`). Fallback styles are likewise applied through interleaving so they
"affect computed values (and can trigger transitions/etc) even though they depend
on layout and used values" (`:1946-1949`).

**(b) A feedback-loop guard.** Fallback-sensitive changes are evaluated against
the **computed base style**, "i.e. the computed value ignoring any declarations
originating from the Transitions or Animations cascade origins" (`:2038-2040`).
Without it, an in-flight transition on an inset would keep invalidating the
fallback choice that produced it.

**(c) The deferred `position-animation: magic` proposal**, present but commented
out in the source (`:2318-2459`), which diagnoses the underlying problem:

> An absolutely positioned box's position and size are the result of multiple
> properties interacting, and this interaction is non-linear, so smoothly
> animating from one position to another can't be accomplished by animating the
> individual properties independently
>
> — `css-anchor-position-1/Overview.bs:2333-2337` ([pinned][q-anim-problem])

Its fix is to interpolate the **result**: an _overriding position rectangle_
(width, height, x offset, y offset of the margin box), "not observable in any
way" except through `getBoundingClientRect` (`:2341-2347`, `:2370-2371`,
`:2385-2391`), with an explicit demonstration that transitioning
`position-animation` _together with_ `inset` produces a pathology where the
rectangle is "constantly recomputed, triggering fresh transitions every frame"
(`:2418-2428`).

Does the module emit geometry metadata to enable animation? In Level 1, no. In
Level 2 it emits a **categorical** token (which fallback applied) through the
container query, and the explainer lists "Run different animations based on the
position of the anchored element" among the motivating needs
(`anchored_container_query.md:16`). There is no transform-origin derivation, no
side/alignment custom property and no reduced-motion interaction anywhere.

**Algorithm.**

```text
interpolate the RESOLVED rect, not the inputs:
    start (w0,h0,x0,y0) -> end (w1,h1,x1,y1), four lengths interpolated
    independently; to/from 'normal' is discrete (like visibility)
guard:
    compute fallback invalidation from the base style, with the Animation
    and Transition origins removed
```

**Where the behavior lives.** The cascade plus style–layout interleaving plus Web
Animations; the Level 2 read-back lives in the container-query engine.

**Degradation.** Both transferable ideas survive a no-DOM toolkit and are
assertable on a recording canvas: animate the _result rect_ (in integer cells,
interpolate four integers and round once, rather than animating an inset and an
alignment and hoping), and exclude animation-produced values from the input to a
placement re-decision. With **no script** neither applies. With **no sub-cell
precision** rect interpolation quantizes to cell steps — fine for a four-to-eight
frame reveal, poor for a long ease. INFERENCE: prefer a discrete reveal over
motion on a cell target.

### 15. State architecture

Declarative and value-typed, but **not stateless** — and the retained state is
exactly two named items.

**(1) The last successful position option** — the set of accepted-`@position-try`
properties and values the box is currently using. Recorded at `ResizeObserver`
delivery time (`:2049-2068`); _cleared_ when any fallback-sensitive change occurs
— a `position` value / containing-block association / box-generation change, any
`position-try` longhand change, any accepted-`@position-try`-property change, or
any referenced `@position-try` rule being added, removed or mutated
(`:2029-2040`). It is consumed by being **skipped** in the candidate loop
(`:1965`), which is what produces the hysteresis quoted in the Overview: the box
leaves a working option only when that option itself starts overflowing.

**(2) Remembered scroll offsets** — one per anchor reference, captured at anchor
recalculation points. Note the deliberate coupling: a chosen option carries "the
associated set of remembered scroll offsets that were hypothetically calculated
for them" (`:1986-1988`), so item (2) is a _field of_ item (1). And because the
incumbent is skipped, the incumbent's offsets are never refreshed — "stick with
current" is a genuine no-op (`:1999-2003`).

Everything else is re-derived each pass. There is no controlled/uncontrolled
distinction, no reducer, no event stream and no imperative controller: the author
supplies data (a name, a grid region, an ordered option list, an ordering
keyword, a visibility keyword) and the engine supplies a fixed algorithm. The
CSSOM surface is pure declaration serialization (`:2551-2637`) — there is no
`getResolvedPlacement()`.

The **flip** is likewise state-free: `execute a try-tactic` (`:2090-2205`) is a
_transform over a placement value_, not a recomputation from geometry. Given a
direction pair it (1) takes the specified values of the accepted properties, (2)
substitutes `var()` / `env()` — switching direction-associated environment
variables to match the new direction, so `env(safe-area-inset-top)` becomes
`env(safe-area-inset-left)` under a top↔left flip (`:2111-2114`, example at
`:2116-2121`) — (3) swaps values between the paired properties, and (4) fixes up
the swapped values: `<anchor-side>` keywords keep their relative relationship,
percentages complement to `100% − P` for opposing directions, `<self-position>`
alignments rewrite `start`↔`end` while `center` and baselines stay put, and
`position-area` rewrites so the selected tracks keep the same relationship.
Tactics compose **in order**, and the order is semantically significant
(`:1642-1646`; the Level 2 query matches the sequence in order,
`css-anchor-position-2/Overview.bs:140-143`).

**Algorithm.**

```text
state := { lastSuccessful : Option?,
           remembered     : Map<AnchorRef, ScrollOffset> }

per pass:
    if fallbackSensitiveChange(baseStyle): lastSuccessful := null
    chosen := determinePositionFallbackStyles()   # skips lastSuccessful
    lastSuccessful := chosen
```

**Where the behavior lives.** Per-element engine state hanging off the layout
object, with clearly specified capture and invalidation points — not in a
component and not in a store.

**Degradation.** This survives a value-semantics, allocation-conscious toolkit
almost unchanged. The whole retained state is one plain-data struct: a
chosen-option index (or a small copy of the option) plus a tiny fixed-capacity
array — no allocation, no closures, trivially serializable into a recording-canvas
assertion. The invalidation set is a pure predicate over the previous and current
input values. Drop `remembered` entirely (there is no compositor thread to
appease outside a browser) and what is left is one index and one dirty predicate.
Nothing in the dimension is event-driven, so **no script / no hover / no window /
no key release** changes none of it.

### 16. Shared infrastructure

The module factors out exactly one thing — placement — and serves tooltip,
popover, menu/popup-list and non-overlay chart annotations from it with no
per-widget branching. The examples make the range explicit: a tooltip
(`:79-131`), a popover with a five-entry fallback list and
`min-width: anchor-size(width)` (`:1524-1552`), a popup list that picks its side
by available height and degrades to scrolling (`:1723-1766`), min/max annotation
lines across three bar anchors (`:976-1019`), and a box stretched between two
anchors in _different_ scroll containers (a commented example at `:1110-1148`).

What belongs in the one primitive, per this module: (i) the anchor reference and
its resolution rules, (ii) the placement algebra, (iii) the fallback list plus
ordering, fit predicate and hysteresis, (iv) the anchor-derived sizing functions,
(v) the auto-hide conditions. What is kept apart: triggering and the invoker
relationship (host language), accessibility semantics, focus and tab order,
layering (`css-position-4`), dismissal (HTML light dismiss), arrows (nothing in
Level 1; a per-component `::before` driven by a Level 2 container query), and
_reactive restyling based on the chosen placement_, deliberately excluded from
Level 1 and given its own containment-paying mechanism in Level 2. The
`@position-try` property whitelist is the **enforcement mechanism** for that
separation.

Reuse across differently-anchored instances is handled by data rather than by
parameterization:

> If multiple elements want to use the same `@position-try` rules, but relative to
> their own anchor elements, omit the `<anchor-name>` in `anchor()` and specify
> each box's anchor in `position-anchor` instead.
>
> — `css-anchor-position-1/Overview.bs:1912-1915` ([pinned][q-late-bind])

**Algorithm.** None — this is a factoring, not an algorithm. The reuse idiom is:
write option lists anchor-agnostically, and late-bind the anchor per instance.

**Where the behavior lives.** The factoring _is_ the deliverable: one CSS module
for placement, other modules and specifications for every other dimension.

**Degradation.** Directly applicable. INFERENCE: an anchored-overlay primitive
should own dimensions 1, 2, 3, 8, 12 and 15 and nothing else; tooltip, menu,
combobox and context menu differ in trigger, timing, focus, dismissal and roles,
and those must not become flags on the placement value. The anchor-agnostic
option-list idiom means a shared placement policy can be a module-level immutable
value shared by every instance, with the anchor supplied per call — which is what
a value-semantics toolkit wants. See [`./proposal.md`][proposal].

## Level 2, in one paragraph

Level 2 is a delta spec whose single feature is making the chosen fallback
_queryable_: `container-type: anchored` plus `@container anchored(…)`. Exposing
"which fallback won" back into styling reopens the cycle Level 1's rules closed,
and Level 2 pays for it with forced containment — "The `anchored` container-type
applies style containment to the query container"
(`css-anchor-position-2/Overview.bs:60-61`), with the worked cycle (counter →
generated content → in-flow size → anchor position → fallback → counter) spelled
out at `:63-77`. Two limits carry over from the explainer: a container cannot
restyle itself, so the anchored element still cannot react to its own placement
(`anchored_container_query.md:139-146`), and the `::tether` alternative was set
aside as "complicated" (`:148-168`).

> [!NOTE]
> The explainer records that a Chrome prototype implemented an **index-based**
> query syntax while the spec text specifies the **value-based** syntax
> (`anchored_container_query.md:58-79`, `:177-182`). That divergence was not
> verified against any implementation.

## Strengths

- **Termination is structural, not dynamic.** Anchor legality is a predicate over
  an ordering the engine already maintains, so the placement pass is a forward
  sweep that provably terminates (`:455-489`).
- **Placement is a value algebra, not an API.** `anchor()` returns a `<length>`
  usable inside `calc()` / `min()` / `max()`, so multi-anchor placement needs no
  new feature — it falls out of arithmetic (`:976-1019`).
- **`position-area` collapses side + alignment + containing block** into one
  canonical pair of keywords, and makes the region _be_ the containing block, so
  subsequent size constraints (`max-height: 100%`) automatically mean the right
  thing (`:685-691`, `:1280-1297`).
- **Fallback is declarative data** with an explicit ordering heuristic, an
  explicit fit predicate, an explicit hysteresis rule and an explicit invalidation
  set (`:1554-1721`, `:1956-2068`).
- **The mutable surface of a fallback is a whitelist**, with the reasoning written
  down in the spec rather than left to folklore (`:1869-1910`).
- **Direction-tagged environment values participate in flips**
  (`:2111-2121`): viewport insets are typed data, not magic numbers baked into an
  offset.
- **Auto-hiding reuses an existing primitive** (`IntersectionObserver`'s clipping
  model), composes transitively through chained anchors, and carves out the
  same-scroller case so a popup beside its anchor does not blink out
  (`:2263-2302`).
- **The animation section diagnoses the real problem** — a position resulting from
  many interacting properties cannot be animated property-by-property — and
  proposes interpolating the resulting rect instead (`:2333-2347`).
- **Fallback re-evaluation reads the computed base style**, excluding
  animation/transition origins, closing an obvious feedback loop (`:2038-2040`).
- **Costs are bounded and the bounds are stated**: a candidate-list cap with a
  spec'd floor of five, and a hard no-backward-layout rule (`:1951-1954`,
  `:2006-2023`).

## Weaknesses

- **No arrow or tether primitive in Level 1.** The `::tether` alternative was set
  aside as too complicated because pulling the pseudo's box out as a sibling
  breaks size container queries (`anchored_container_query.md:148-168`); the
  shipped workaround is a categorical container query in a delta spec.
- **The anchored element cannot react to its own resolved placement** — only its
  descendants can (`anchored_container_query.md:139-146`). A popup that wants to
  round the corner nearest its anchor needs a wrapper element.
- **No virtual anchors.** No point, cursor, caret or text-range anchoring, and a
  fragmented anchor collapses to a bounding rect rather than offering per-fragment
  placement (`:460-461`, `:173-179`).
- **Scroll fidelity is traded for compositor-thread compatibility.** Every anchor
  except the default one is frozen at its remembered offset, and the spec admits
  the box then "will no longer appear to be anchored to them" (`:1191-1194`).
- **Transforms are half-handled**: included in the anchor rect but possibly
  several frames stale, with compensation still an open issue (`:168-171`,
  `:1185-1187`, `:1246-1247`).
- **The scroll-snapshot timing is unspecified**, after a commit specifying it was
  reverted (`:1242-1244`) — a per-frame ordering question left open in a feature
  already implemented by engines.
- **Anchor-name lookup defaults are a footgun.** Names are not unique and the
  fallback is "last in tree order", so repeated components can silently all
  anchor to the last instance unless `anchor-scope` is used; the spec teaches this
  by showing the bug (`:333-357`) and then leaves an unresolved "Issue: Fix the
  above example, since the use-case is now automatic" beneath it (`:359`).
- **`position-anchor: normal`** (the initial value) means "none if `position-area`
  is `none`, else `auto`" (`:520-525`) — a property whose meaning depends on
  another property, with the changelog noting the initial value may change again
  (`:2743-2747`).
- **`position-visibility` defaults to auto-hiding** (`Initial: anchor-visible`,
  `:2224`), which is surprising for a CSS property and interacts with
  `force-hidden`'s removal from navigation and speech
  (`css-display-4/Overview.bs:1890-1898`). Not verified against implementations.
- **No programmatic read-back of the resolved placement.** CSSOM exposes
  declaration serialization only (`:2551-2637`); the only read-back is the Level 2
  container query, restricted to descendants.
- **The `position-try-final` escape hatch** — what to do when nothing fits, with
  an `always` modifier to defeat the hysteresis — is written but commented out of
  the draft (`:1768-1821`), so the all-options-overflow case currently has one
  behaviour and no author control.
- **Internal documentation drift.** The changelog at `:2712` says `match-parent`
  was added to `position-area`, but it appears on `position-anchor` (`:507`,
  `:541-546`); a second changelog entry at `:2704` reads "anchor-valid (like
  anchor-valid)" where it evidently means `anchor-visible`.

## Obscure capabilities

These feed [`./features-people-forget.md`][forget]; each is a rule whose absence
is a shipped bug.

| Capability                                                                                                                                                               | Failure it prevents                                                                                                                                                                     | Evidence                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| **Skipped-contents symmetry** — an element inside another's skipped contents may anchor only if the positioned element is inside the _same_ skipped leaf                 | Collapsing an ancestor containing both would otherwise make the popup jump to a _different_ matching anchor elsewhere in the document                                                   | `:479-488`                              |
| **Reverse relevance** — being an anchor keeps a `content-visibility: auto` subtree from skipping, with a carve-out so two boxes "can't cyclicly keep each other visible" | An anchor inside a deferred region would otherwise stop being laid out while a visible popup still needs its rect                                                                       | `:601-619`                              |
| **Negative-boundary rejection** — a candidate whose containing block was clamped from negative is rejected, not tested                                                   | A zero-size popup tests as "contained within" a zero-size (formerly negative) boundary and wins — the exact failure a naive `rect.contains(rect)` ships                                 | `:1974-1981`                            |
| **Direction-tagged `env()` substitution during a flip**                                                                                                                  | An inset baked into a placement follows the box to the flipped side and pads the wrong edge — clearing a notch that is no longer there                                                  | `:2107-2121`                            |
| **Percentage complementation on opposing flips** — `anchor(20%)` becomes `anchor(80%)`, while `center` and baselines are left untouched                                  | A box pinned 20% along its anchor lands at 20% from the wrong end after a flip, sliding sideways during what should be a pure mirror                                                    | `:2149-2160`, `:2180-2191`              |
| **The incumbent's remembered offsets are never refreshed**, because the incumbent is skipped                                                                             | Re-testing the current option would refresh its scroll snapshot every frame, so "stay where you are" would silently re-anchor the box each tick                                         | `:1986-1988`, `:1999-2003`              |
| **The anchor-clipped test is scoped** to boxes that are ancestors of the _anchor_ but descendants of the _positioned box's_ containing block                             | A popup inside the same scroller as its anchor would blink out as soon as that scroller moved, though it is clipped by the very same scroller                                           | `:2265-2270`, `:2288-2291`              |
| **`position-area` grid lines clamp outward by the anchor**, so tracks degenerate to zero-size rather than negative                                                       | An anchor partly or wholly outside its containing block otherwise produces inverted regions and negative-width placements                                                               | `:705-720`                              |
| **`force-hidden` hides descendants regardless of their own visibility**, making anchor-driven hiding transitive                                                          | In a chained-anchor layout, hiding only the first box leaves the second "floating in a nonsensical location"                                                                            | `css-display-4:1859-1864`, `:2297-2301` |
| **Try-tactic composition is order-sensitive** — `flip-start flip-block` differs from `flip-block flip-start`                                                             | Treating flips as a commutative set of booleans gives the wrong result for any diagonal composition, and makes two distinct placements indistinguishable to placement-dependent styling | `:1642-1646`, L2 `:140-143`             |
| **`anchor-scope: all`** switches the listed names from loose to strict tree matching and has _no_ effect on implicit anchor elements                                     | A component scoping its anchor names would otherwise sever the host language's invoker→popover implicit anchoring                                                                       | `:298-310`, `:324`                      |

## Key design decisions and trade-offs

| Decision                                                                                                                         | Rationale                                                                                                                                                                                                                                                                                                              | Trade-off                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| An anchor is a **name with a scope**, resolved per query, not a pointer or handle.                                               | Anchoring must work across subtrees and shadow trees, and survive the anchor being added, removed or renamed while transitions keep running (`:949-955`). A tree-scoped name is a comparable value with defined equality (`css-shadow-1:865-869`), so it inherits, serializes and cascades like any other value.       | Every reference costs a lookup with a non-obvious rule — nearest ancestor first, else _last_ match in tree order (`:420-424`), changed as recently as December 2025 (`:2725-2728`). It also forecloses virtual anchors: the target must be an element with a principal box (`:460-461`).                                           |
| Guarantee termination by restricting **which** elements may be anchors, reusing an ordering the engine already computes.         | Stated outright — the conditions "exactly rephrase the stacking context rules… ensuring there is no possibility of circularity" (`:392-396`) — and reinforced by forbidding backward layout, since "at best, this can result in exponential layout costs; at worst, it's cyclic and will never settle" (`:2019-2020`). | Legitimate patterns are rejected: two boxes cannot mutually anchor. And the rule is only as simple as the host layout model — it is a conjunction over containing block, flat-tree order, top layer and skipped contents, so porting means re-deriving an equivalent predicate for another ordering, not transcribing the clauses. |
| Fallbacks are **data** — an ordered list of restricted style bundles — with a deliberately tiny mutable property set.            | Only insets, margins, sizing, self-alignment, `position-anchor` and `position-area` may appear, because that "significantly simplifies the implementation of position fallback" and limits cascade/inheritance interactions (`:1869-1877`, `:1897-1905`). Options live in their own cascade origin (`:1883-1887`).     | Nothing else can change per placement — not the arrow, not a border radius, not a gradient direction — which is the gap that forced the Level 2 container-query feature into existence, and that feature pays for itself with mandatory style containment (L2 `:60-77`).                                                           |
| Prefer positional **stability** over optimality: keep the current option until it actually overflows, by skipping the incumbent. | `:1518-1521` states the policy; the implementation is the one-line skip at `:1965` plus the recording rule at `:2049-2068`, with a precisely enumerated invalidation set (`:2029-2040`) computed from the base style with animation origins excluded.                                                                  | A popup can stay on the "wrong" side long after the good side reopens, with no author control — the `position-try-final … always` escape hatch is commented out of the draft (`:1768-1821`). The state must also be invalidated correctly across four distinct classes of change.                                                  |
| Freeze scroll for every anchor except the default one, and apply the default anchor's scroll delta as a post-layout translate.   | Anchoring opposite edges into different scroll contexts would let a scroll change the box's _size_, i.e. require layout on the compositor thread; freezing all but one reduces the live case to a translation (`:1057-1108`, `:1150-1240`).                                                                            | An acknowledged semantic lie (`:1191-1194`), which additionally leaks under non-linear functions (`:1249-1259`) and whose snapshot timing is still unspecified (`:1242-1244`). A toolkit that repaints from a fresh display list every frame should reject this trade wholesale.                                                   |
| Ship the placement primitive with **no** trigger, timing, focus, dismissal, arrow or accessibility semantics.                    | Placement is genuinely common to tooltip/popover/menu/select/chart annotation; the rest is not. The Advisement at `:2476-2477` refuses to couple visual and semantic anchoring, and `:2485-2490` argues they are independent relations.                                                                                | Authors get a sharp placement engine and no help with the interaction layer, and can trivially build a visually-anchored surface with no semantic relationship — the failure the spec itself warns about (`:2492-2501`). The arrow gap is the most visible consequence.                                                            |

## What this module leaves to somebody else

INFERENCE, and deliberately coarse: this reading did not open any JavaScript
positioning library, so the mapping below is a statement about _this_ spec's
contents, not a claim about any other subject's API. Absorbed into declarative
values and the layout engine: the placement solve (`position-area` + `anchor()`),
offsets (arithmetic over `anchor()`), flipping (try-tactics as style transforms),
auto-placement (`position-try-order: most-*`), anchor-derived sizing
(`anchor-size()` plus `stretch`), hide-when-clipped (`position-visibility`), and
re-evaluation timing (the rendering lifecycle). Sliding is absorbed but lives
_next door_, in `css-align-3`'s overflow-limit-rect algorithm. Left entirely
outside: arrows, virtual/point/cursor anchors, per-fragment selection for wrapped
ranges, a custom boundary or boundary padding (the boundary is always the
inset-modified containing block), a programmatic resolved-placement read (Level 2
only, categorical, descendants only), and every trigger, timer, dismissal, focus
and role concern. For the cross-subject picture see
[`./comparison.md`][comparison] and [`./floating-ui.md`][floating-ui].

## Could not verify

- **No implementation and no tests were read.** This clone is spec source only;
  there is no `css-anchor-position` test directory in the tree at this SHA. Where
  browsers differ from this text, the browsers were not consulted.
- Whether shipping engines use `anchor-visible` as the initial value of
  `position-visibility`, as the draft states (`:2224`), or `always`.
- Whether the April 2026 `anchor-valid` / `anchor-visible` (singular) renaming has
  shipped anywhere, or whether the legacy plural aliases permitted at `:2304-2306`
  are what implementations accept.
- The Level 2 `anchored()` container query's shipping form — the explainer
  describes an index-based prototype against a value-based spec
  (`anchored_container_query.md:58-79`, `:177-182`).
- IME / virtual-keyboard avoidance: no keyboard-inset environment variable was
  found in `css-env-1/Overview.bs` at this SHA (only `safe-area-inset-*` at
  `:104-131` and `viewport-segment-*` at `:177-231`). Whether one exists elsewhere
  was not checked.
- Exact frame-ordering semantics of the scroll snapshot — unspecified in the
  source itself (`:1242-1244`), so there is no answer to verify.
- Interaction with HTML's Popover API implicit-anchor definition: the spec carries
  a TODO placeholder for it (`:589-591`) and the HTML spec is not in this clone
  (see [`./popover-api.md`][popover-api]).
- Real-world cost of the fallback loop in trial layouts per frame: no
  measurements were taken and none appear in the spec beyond the ≥5 candidate
  floor.

## Sources

Primary — all at [`6dc15cc9cb15043840eacf081e89f5a666fa7889`][repo-sha]:

- [`css-anchor-position-1/Overview.bs`][src-1] — the Level 1 Working Draft: anchor
  names and scoping, the acceptable-anchor rule, `position-area`, `anchor()` /
  `anchor-size()`, scroll memory, `@position-try` and the fallback algorithm,
  try-tactics, `position-visibility`, the accessibility Advisement, and the
  commented-out `position-animation` proposal.
- [`css-anchor-position-2/Overview.bs`][src-2] — the Level 2 delta: `container-type:
anchored`, `@container anchored(fallback: …)`, `<position-area-query>`.
- [`css-anchor-position-1/anchored_container_query.md`][src-explainer] — the
  explainer: motivating needs, the rejected `::tether` design, the
  cannot-style-the-container limit, and the prototype/spec syntax divergence.
- [`css-position-4/Overview.bs`][src-pos4] — the top layer, `overlay`,
  `::backdrop`.
- [`css-position-3/Overview.bs`][src-pos3] — the inset-modified containing block.
- [`css-align-3/Overview.bs`][src-align3] — default overflow self-alignment for
  out-of-flow boxes (the slide behaviour anchor positioning inherits).
- [`css-display-4/Overview.bs`][src-display4] — `visibility: force-hidden` and the
  behaviour of invisible boxes.
- [`css-shadow-1/Overview.bs`][src-shadow] — tree-scoped names: the
  `(identifier, root)` equality rule anchor names use.
- [`css-env-1/Overview.bs`][src-env] — `safe-area-inset-*` and
  `viewport-segment-*`.

Sibling pages in this catalog: [index][index] · [concepts][concepts] ·
[comparison][comparison] · [features people forget][forget] ·
[sparkles baseline][baseline] · [proposal][proposal] ·
[Popover API][popover-api] · [Blink][blink] · [Floating UI][floating-ui] ·
[xdg_positioner][xdg] · [GTK4][gtk4] · [ARIA APG][aria-apg]

Related research trees: [window-system integration][wsi] ·
[platform UI guidelines][platform-guidelines] · [UI layout][ui-layout] ·
[Sean Parent][sean-parent]

Toolkit specs: [`sparkles:ui` overview][spec-ui] · [input][spec-input] ·
[containers][spec-containers] · [state machines][spec-state] ·
[backends][spec-backends] · [widgets][spec-widgets]

<!-- References -->

[repo]: https://github.com/w3c/csswg-drafts
[repo-sha]: https://github.com/w3c/csswg-drafts/tree/6dc15cc9cb15043840eacf081e89f5a666fa7889
[w3c-license]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/LICENSE.md
[ed-1]: https://drafts.csswg.org/css-anchor-position-1/
[ed-2]: https://drafts.csswg.org/css-anchor-position-2/
[src-1]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs
[src-2]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-2/Overview.bs
[src-explainer]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/anchored_container_query.md
[src-pos4]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-4/Overview.bs
[src-pos3]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-position-3/Overview.bs
[src-align3]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-align-3/Overview.bs#L901
[src-display4]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-display-4/Overview.bs#L1859
[src-shadow]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-shadow-1/Overview.bs#L865
[src-env]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-env-1/Overview.bs#L104
[q-fixpos]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L91
[q-circularity]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L392
[q-strictly-before]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L467
[q-minimal-props]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1897
[q-hysteresis]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1518
[q-advisement]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2476
[q-a11y-failure]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2495
[q-anim-problem]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L2333
[q-late-bind]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1912
[alg-fallback]: https://github.com/w3c/csswg-drafts/blob/6dc15cc9cb15043840eacf081e89f5a666fa7889/css-anchor-position-1/Overview.bs#L1956
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[forget]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[popover-api]: ./popover-api.md
[blink]: ./blink.md
[floating-ui]: ./floating-ui.md
[xdg]: ./xdg-positioner.md
[gtk4]: ./gtk4.md
[aria-apg]: ./aria-apg.md
[wsi]: ../window-system-integration/index.md
[platform-guidelines]: ../platform-ui-guidelines/index.md
[ui-layout]: ../ui-layout/index.md
[sean-parent]: ../sean-parent/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-state]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
