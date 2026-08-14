# Proposal — an anchored-overlay primitive for `sparkles:ui`

The bridge from the catalog into the specification. Everything upstream of this page
describes what other systems do; this page says what `sparkles:ui` should do, and —
paragraph by paragraph — which part is a **finding** (something the survey observed in a
primary source) and which is a **recommendation** (a judgement made here, which a
reviewer may overturn without touching the evidence).

The framing question every recommendation must answer:

> What is the state of the art in anchored-overlay systems, and which of it survives on a
> toolkit that renders every overlay inside **one surface**, in **integer cells**, on
> targets that variously lack hover, key releases, scripting, and an OS window?

**Last reviewed:** August 14, 2026

> [!IMPORTANT]
> **Reading convention.** Every section is split into **Findings** (evidence, cited) and
> **Recommendation** (judgement, arguable). Where a sentence inside a Findings block is an
> inference rather than an observation it is marked _INFERENCE_. Claims are quoted in the
> narrowed form the adversarial verification pass left them in — see
> [`./index.md`](./index.md) for the verdict ledger. Prefer "the subjects examined" to
> "every subject"; the survey covers 38 subjects, not the field.

> [!NOTE]
> Related trees, linked rather than restated:
> [window-system-integration](../window-system-integration/index.md) for `xdg_popup` grabs
> versus X11 override-redirect and the in-canvas fork,
> [ui-layout](../ui-layout/index.md) for the box-flow model placement sits beside,
> [platform-ui-guidelines](../platform-ui-guidelines/index.md) for the appearance side, and
> [sean-parent](../sean-parent/index.md) for the value-semantics and local-reasoning
> principles `PRN1`–`PRN12` are drawn from.

---

## 1. The recommended primitive architecture

### 1.1 Findings

The corpus answers the packaging question five different ways, and the split between
"shared" and "per-surface" is far more stable than the packaging
([`./comparison.md`](./comparison.md), [`./features-people-forget.md`](./features-people-forget.md)):

| Packaging                                             | Subjects                                                                 | What it costs                                                                                                                     |
| ----------------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------- |
| N orthogonal mechanism packages                       | [radix], [floating-ui], [zag], [react-aria], [angular-cdk]               | duplicated geometry across packages (Radix ships `isPointInPolygon` byte-for-byte in two packages)                                |
| one shared parameterised solve + thin policy wrappers | [base-ui], [floating-vue], blink.cmp ([nvim-completion]), [avalonia]     | the second attempt by the authors of the first; the shape most portable to cells                                                  |
| one base class, differentiation by subclass           | [qt-quick-controls], [ariakit], [winui], [uno], [slint]                  | the awkward consumers bypass the base entirely (WinUI's `ToolTip` and `TeachingTip` both leave `FlyoutBase`)                      |
| nearly-empty surface + a pure placement value fn      | [compose], [xdg-positioner], [gtk4], [flutter], [helix], [neovim-floats] | the unification is **subsidised** by a window manager the toolkit does not have                                                   |
| share the transport, share no policy                  | [qt-widgets], [tmux-popup], [gpui], [aria-apg], [ratatui]                | five placement ladders in Qt Widgets, four flip rules in Neovim, two drifted 190-line copies in tmux, three duplicated `Element`s |

The **split** is near-unanimous among the subjects that discuss it. **IN** the shared core:
an anchor value, a placement solve whose result reports the resolved side and the arrow, an
ordered layer registry with parent links and a cascade operation, and a reason-tagged
dismissal channel. **OUT**: focus policy, timing and hover intent, item
collections/typeahead/selection, content typing, modality-as-a-mode, roles, and any exotic
placement mode.

Two findings bound how large the sparkles primitive may be:

- **Compose's eight-surfaces-on-one-`Popup` unification is subsidised.** Every Compose
  `Popup` is a real `WindowManager` child window, so z-order, per-window outside-touch and
  focusability come free, and the whole policy surface is five booleans
  ([`PopupProperties`][compose-popup]). Sparkles has no such subsidy: no top layer, no
  compositor, no grab (`UI-O3`), hit order == reverse paint order. What Compose delegates
  downward, sparkles must own. Compose's own cascading-menu **sample** is the proof of what
  falls out — the menu tree, hover-open and cascade dismissal are application code
  ([`MenuSamples.kt`][compose-menusamples]).
- **Zag's inverted dependency pair** is the sharpest evidence the core is two halves rather
  than one monolith: `@zag-js/toast` depends on `dismissable` and **not** `popper`;
  `@zag-js/tooltip` depends on `popper` and **not** `dismissable` ([zag]). Two surfaces each
  take exactly one half.

Sparkles' own baseline is the "share the transport, share no policy" outcome in miniature
([`./sparkles-baseline.md`](./sparkles-baseline.md)): `clampOrigin`
(`libs/twoslash/src/sparkles/twoslash/render_widgets.d:430`) is one axis, one direction,
against one scalar extent, called from three sites that disagree on the boundary
(`apps/hue/src/gui.d:2900` an anchor-relative pixel edge; `apps/hue/src/tui.d:654` the pane
width; `apps/hue/src/twoslash_tui.d:267` the whole grid), on the vertical offset (`+0`,
`+2`, `+1`) and on whether they clip at all. That is `PRN8` violated by three applications
that each guessed at a behaviour the toolkit does not define.

### 1.2 Recommendation

**Five pieces, one new module family `libs/ui/src/sparkles/ui/overlay/`, sized between
Compose's `Popup` and a React overlay stack.**

| #    | Piece                                       | Shape                                                                            | Why it is in the primitive                                                                                     |
| ---- | ------------------------------------------- | -------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `P1` | `place()` + `Placement` / `OverlayGeometry` | one `@safe pure nothrow @nogc` function over Regular values                      | the toolkit owns no definition today; three applications each wrote one                                        |
| `P2` | `Anchor` / `AnchorRect` + `resolveAnchor`   | a closed sum over producers `state.d` already has                                | keeps the primitive count at one — a dock hint, a hover popup, a context menu and a toast are one type         |
| `P3` | `AnchoredOverlayController`                 | a flat, frame-built arena with a parent index and four bands                     | fills `DCK13`'s empty top-layers rung; nothing else can supply ordering, cascade or outside-hit classification |
| `P4` | `DismissPolicy` + `DismissReason`           | a flags word ANDed with a router-offered cause, plus a closed reason enum        | `isDismiss` (`INP13`) already unifies Escape and the Android back key; the rest is one pure evaluator          |
| `P5` | `TriggerPolicy` + `resolveTriggers`         | a declaration plus a capability resolution, in `ScrollbarState.expanded`'s shape | `TGT5` requires degradation to be **declared**, not silent; this is what retires `IXR26`                       |

**Explicitly out of the primitive**, each with its witness: focus _behaviour_ (no subject
examined applies the same focus behaviour to tooltip + menu + dialog — `D16.C1`, narrowed:
a shared _implementation_ behind a policy value is normal practice, so the spec must forbid
a shared **default**, not a shared implementation); timing machines and hover intent
(availability differs per target — React Aria's `useTooltipTriggerState` is reused verbatim
by `usePreviewTrigger` with different constants, so the machine belongs to "hover-opened
surface", not to "tooltip"); item collections, selection and typeahead (`WGT13`'s job);
content typing; modality as a mode rather than a hit-list filter; roles; the toast
queue/priority/collapse-to-icon (the `NTF` machine over `Timeline`/`STM6`); and
item-aligned `Select` placement, which four independent codebases escaped their shared
solver for and which must therefore be a strategy that computes its own rect, never a flag
on `place()`.

**One structural rule the whole architecture rests on**: the overlay's content is
**authored as a child of its anchor** and only its **emission** is hoisted. That is
Flutter's `OverlayPortal` split with the reparenting removed, and it is exactly Textual's
triple — order reset, clip reset, extent exclusion. Declaration-in-tree is the only shape
that also serves the static-HTML target, where `:hover` / `:focus-within` cannot cross a
hoist and where [aria-apg] makes submenu **containment** mandatory. A portal-based design
(Flutter, Radix, CDK, Ariakit) cannot serve HTML from the same declaration.

---

## 2. Resolving the architectural tension: named bands versus a precedence byte

### 2.1 The two proposals, side by side

The layering analysis and the shared-infrastructure analysis reached the same shape in
incompatible spellings, and the catalog must pick one.

| Axis       | Layering proposal                                         | Shared-infrastructure proposal     |
| ---------- | --------------------------------------------------------- | ---------------------------------- |
| Ordering   | `enum OverlayBand : ubyte { adorn, popup, hint, notify }` | `ubyte precedence` on the record   |
| Identity   | `struct OverlayId { uint index; uint gen; }`              | `size_t id`, `size_t parentId`     |
| Who picks  | the toolkit (a closed vocabulary)                         | the caller (an open integer space) |
| Cross-band | focus raises **within** a band, never across              | unspecified                        |

### 2.2 Findings

- A small fixed ladder of named bands, ordered by construction, with focus raising only
  within a band, is **the convergent choice among the in-surface subjects examined**:
  [imgui] has two layers, [textual] three system layers above whatever the app names,
  [uno] four root z constants, [avalonia] five private consts, [neovim-floats] three
  documented bands over a default of 50 with `ui_comp_grid_cursor_goto` raising only
  within a band (`D10.C5`, narrowed). The narrowing matters and is recorded here: **Neovim
  and GPUI, both cell/canvas subjects, do expose a per-overlay integer**, and Avalonia and
  GPUI both needed rungs (light-dismiss, text-selector) beyond a naive four.
- The failure mode of an **open** integer space is documented twice inside this corpus, both
  times in single-surface systems: company-mode picks overlay priority `111` with the
  comment "Beat outline's folding overlays. And Flymake (53). And Flycheck (110)"
  ([emacs-posframe]) — a number that is a guess about strangers and rots the moment anyone
  raises theirs; and [aria-apg] ships three unrelated magic depths across three examples
  (`zIndex = 100`, `zIndex = 2`, `z-index: 1`). nvim-cmp's documentation panel sits at 50
  while its menu sits at 1001, silently resolving overlaps in the menu's favour, documented
  nowhere ([nvim-completion]).
- A hint coexisting with a menu is a real requirement, and [popover-api]/[blink] solved it
  by adding a **second ordered list** (`showing hint popover list`) plus a hint-stack parent
  and a stack-position offset — not by deepening a tree. That is bands, arrived at from the
  other direction.
- Identity: sparkles' arena is **frame-built**, and events route against the last painted
  frame's hit data by construction (baseline `B0.5`). [slint] uses a monotonic `NonZeroU32`;
  [imgui] deliberately never recycles popup window names (`##Popup_%08x`, with the comment
  "No recycling, so we can close/open during the same frame"). Both are answers to the same
  hazard: a recycled slot index makes a stale handle indistinguishable from a live one.

### 2.3 Decision — take the closed four-band enum and the generational `OverlayId`

**Recommendation.** Adopt the layering proposal in full. Do not merge the two.

```d
enum OverlayBand : ubyte { adorn, popup, hint, notify }
struct OverlayId { uint slot; uint gen; }
```

Four reasons, in decreasing strength:

1. **A closed enum makes the rotting number unrepresentable.** The two cautionary tales in
   the corpus are both single-surface systems — precisely sparkles' situation — and both
   failed the same way: a caller picked an integer relative to strangers. A `ubyte
precedence` field re-opens exactly that space. `OverlayBand` costs nothing at runtime
   (it _is_ a `ubyte`) while removing the choice from the caller.
2. **The bands are not arbitrary; each already has a waiting consumer.** `adorn` carries
   `DCK5`'s finished-but-homeless `dockHint` (`libs/ui/src/sparkles/ui/dock.d:983`,
   `components/chrome.d:382`). `popup` carries menus, dropdowns and context menus and is the
   **only** band that participates in the dismissal stack. `hint` is HTML's separate hint
   list — tooltips and hovercards, never a dismissal parent, never focusable. `notify` is
   `WGT16`/`DEF10`'s toasts, which [react-aria] documents must stay visible, focusable and
   clickable while a modal is open — the exact opposite of every anchored overlay's contract.
   A byte cannot express "this rung is not a dismissal parent"; an enum with documented rungs
   can.
3. **Generational ids answer a hazard sparkles has and `size_t` does not address.** A bare
   `size_t` id is either a slot index (recycled, so a one-frame-stale handle silently names a
   different overlay — and baseline `B0.5` guarantees exactly one frame of staleness) or a
   monotonic counter (correct, but forces a scan to reach the slot). `{slot, gen}` is both:
   O(1) slot access plus staleness detection, in the same 8 bytes a `size_t` occupies on a
   64-bit target, and Regular (`PRN6`) either way.
4. **Widening later is source-compatible; narrowing is not.** `OverlayBand : ubyte` can gain
   a rung; a published `ubyte precedence` cannot be taken away.

**The refutation condition, stated so it stays checkable.** If a real consumer needs two
overlays in the **same** band, simultaneously visible, overlapping, in an order that is not
open order — the `NTF7` notifier stack is the case to check — the answer is Notcurses'
two-argument `moveAbove(id, target)` / `moveBelow(id, target)` with a null sentinel for "the
far end" ([notcurses]), **not** an integer priority. The `parentId` link survives the
decision unchanged; it is orthogonal to the ordering question and both proposals wanted it.

---

## 3. The API sketch — a straw man to be challenged

> [!WARNING]
> **This is a straw man, not a target.** It exists so a reviewer has something concrete to
> attack; the field names are the argument, not the spelling. Section 3.8 lists the places
> where the author already believes it is wrong. Nothing here has been compiled.

> [!NOTE]
> `Point` and `Size` are `Vector`-backed unions, so a **named-field read is not available in
> CTFE** (`libs/ui/src/sparkles/ui/geometry.d:34-40`). Everything below can therefore be
> `@safe pure nothrow @nogc` and property-tested at runtime (`PRN11`), but `place()` cannot
> be a `@ctfe` test while it reads `.x` / `.width`. Do not write a requirement promising
> compile-time placement.

### 3.1 `Anchor` and `AnchorRect`

```d
/// Which producer resolves this anchor, and therefore which fields carry meaning.
enum AnchorKind : ubyte
{
    key,        /// a `Widget.key`, resolved through `keyTargets` (clip-aware)
    rect,       /// a caller-computed cell rect (`dockHintRect` has no widget behind it)
    point,      /// a pointer or caret cell, materialised as a 1x1 rect
    textRange,  /// a byte range, resolved through `selectionRects`
    corner,     /// a boundary corner — the notifier / toast variant
}

/// Is the anchor re-resolved every frame, or frozen at open?
enum AnchorTracking : ubyte { live, latched }

/// The placement INPUT. Regular: total `==`, independent copies, no handle, no closure.
struct Anchor
{
    AnchorKind      kind;
    size_t          key;              /// `kind == key`
    Rect            rect;             /// `kind == rect | point`
    size_t          srcLo, srcHi;     /// `kind == textRange`
    Corner          corner;           /// `kind == corner`
    Rect            avoid;            /// ImGui `r_avoid` / WinUI `ExclusionRect`; empty = none
    AnchorTracking  tracking = AnchorTracking.latched;
}

/// The RESOLVED anchor. A separate type, because the request must never be written back to.
struct AnchorRect
{
    enum maxRows = 4;

    Rect            primary;          /// the rect `place()` solves against
    Rect[maxRows]   rows;             /// per-row rects for a wrapped text range
    ubyte           rowCount;
    Rect            covered;          /// union of `rows` — the hover corridor's anchor half
    bool            clipped;          /// the anchor's clip stack left nothing visible
    bool            live;             /// the anchor resolved at all this frame
}

AnchorRect resolveAnchor(
    in Anchor a, in WidgetTree tree, in Frame[] frames) @safe pure nothrow;
```

**Evidence that selected this shape.** The anchor reduces to a Regular rect-plus-gravity
value at the placement seam in every subject examined — [xdg-positioner] makes the copy
normative ("the compositor makes a copy of the rules … can be destroyed or reused"),
[avalonia]'s `PopupPositionerParameters` is literally a `record struct`, [gtk4]'s
`gdk_popup_layout_equal` compares ten POD fields, and [ratatui]'s `Rect` derives
`Copy + Eq + Hash` and is used as an LRU key (`D1.C1`, narrowed). The narrowing to record:
handles are used beyond re-measurement for **boundary derivation** ([floating-ui]'s
`contextElement` reaching `getClippingRect`) and **anchor liveness** ([ariakit]'s
`isConnected` guard, [blink]'s `WeakMember implicit_anchor_`, [uno]'s weak `Target`) — each
needs an explicit value-shaped substitute here, which is why `boundary` is a `place()`
parameter and `live` is a field.

A point anchor is `1×1`, never `0×0`: [avalonia] writes exactly `new Rect(position, new
Size(1, 1))` for `PlacementMode.Pointer`, and where arrow geometry participates in a
cross-axis clamp a small anchor can invert the interval (`D1.C8`, narrowed — react-aria's
`clamp` then silently returns `max`), so the arrow math must **assert** `min <= max` rather
than rely on a clamp.

`corner` is the single decision that keeps the primitive count at one. Three independent
witnesses place a screen-anchored surface through the same engine: [base-ui]'s
`ToastPositioner` calls the same `useAnchorPositioning` as Tooltip and Menu; [angular-cdk]
attaches a `GlobalPositionStrategy` through the same `OverlayRef` as a connected dropdown;
[helix]'s "invalid regex" notification is a `Popup` at a synthetic position two rows above
the bottom.

**Repo-side prerequisite (a finding, not a preference).** `keyedRects`
(`libs/ui/src/sparkles/ui/state.d:504`) and `selectionRects` (`:415`) do **not** apply the
clip stack while `hoverTargets` (`:64`) and `keyTargets` (`:105`) do, so an anchor resolved
through either of the first two yields a full rect for a widget scrolled out of its viewport
(`D1.C3`, upheld with correction). A clipped **keyed** producer already exists (`keyTargets`);
what is genuinely missing is a clipped `selectionRects` and an explicit hidden/clipped
**flag**, because `keyTargets` returns only the visible intersection and drops fully-clipped
entries, so it cannot distinguish "scrolled out" from "gone".

### 3.2 `Placement` (the request) and `OverlayGeometry` (the result)

```d
enum Side  : ubyte { top, bottom, left, right }
enum Align : ubyte { start, center, end }
enum Fit   : ubyte { exact, flipped, slid, shrunk, overflowing, refused }

/// What the caller ASKS for. Never overwritten by the solver (`D15.C6`).
struct Placement
{
    Side  side       = Side.bottom;
    Align align_     = Align.center;
    int   sideOffset;        /// cells along the side axis
    int   alignOffset;       /// cells along the edge axis
    int   arrowClearance;    /// 0 or 1 cells, decided BEFORE layout
    int   minWidth, maxWidth;
    int   minHeight, maxHeight;
    CollisionPolicy collide;
}

/// What the solver REPORTS. A separate field on the record, never aliased with the request.
struct OverlayGeometry
{
    Rect   rect;             /// resolved, integer cells, already clamped
    Side   side;             /// post-flip edge of the ANCHOR we attached to
    Align  align_;           /// post-flip start | center | end
    Fit    fit;              /// including `refused` — we are the host, nobody clips for us
    Adjust applied;          /// which adjustments actually fired
    int    arrowCell;        /// overlay-local cell along `side`'s edge
    bool   arrowCentred;     /// false => the arrow could not reach the anchor's centre cell
    Size   available;        /// room actually left at this side
    Rect   anchorLocal;      /// anchor rect in overlay-local cells (the transform origin)
    Insets adjusted;         /// per-side shift/clamp deltas, in cells
    bool   anchorHidden;     /// the anchor left its clip — a HIDE verdict, not a close
}
```

**Evidence.** `place()` must return the resolved side and the arrow cell alongside the rect,
because a cell backend picks the border cap and the arrow glyph from the side at paint time
and the HTML emitter picks them at emit time with no later measurement pass (`D2.C5`,
narrowed). Among the subjects examined that need the resolved side for anything, every one
whose result **discards** it either pays to recover it — [compose] with a downcast plus a
one-frame-late coordinate comparison plus a duplicated clamp; [wpf] re-deriving the direction
as two `BitVector32` bits; [gpui] reinventing `flip_left`/`y_flipped` at three call sites;
blink.cmp duplicating the identical derivation at two sites — or forecloses the feature
entirely ([avalonia]'s `void Update`, [slint]'s fixed-only `place_popup`, [qt-quick-controls])
(`D4.C5` / `D14.C8`, both narrowed). Only company-mode exhibits a **verified drift** between
two such re-derivations; the rest are cost, not divergence, and the recommendation rests on
the cost.

Sparkles is the sharpest case in the corpus, because the datum already exists with nothing
producing it: `BoxStyle.arrow` / `arrowOffset` (`style.d:156-157`) and `Decoration.arrow` /
`arrowOffset` (`:177-178`) are documented "backends place it", and consequently **all four**
canvases hard-code the arrow to the top edge — `grid_canvas.d:371-372`, `cells.d:346-347`,
`html.d:227+250`, `raylib_canvas.d:329-347` (`D14.C1`, upheld with correction). Two live
defects follow and must be retired by this work: the raylib backend places the arrow one
cell left of both cell backends (`D4.C2`), and **nothing in `sparkles:ui` clamps
`arrowOffset` against the box extent**, so `arrowOffset >= width - 2` unconditionally
overwrites the corner glyph (`D4.C3`).

### 3.3 `CollisionPolicy`

```d
enum Adjust : ubyte
{
    none    = 0,
    flipX   = 1 << 0, flipY   = 1 << 1,
    slideX  = 1 << 2, slideY  = 1 << 3,
    resizeX = 1 << 4, resizeY = 1 << 5,
}

enum FlipAcceptance : ubyte { revertUnlessFree, lessBadWins }
enum OverflowPin    : ubyte { startEdge, endEdge }

struct CollisionPolicy
{
    Adjust         adjust     = Adjust.flipY | Adjust.slideX | Adjust.resizeY;
    FlipAcceptance acceptance = FlipAcceptance.revertUnlessFree;
    OverflowPin    pin        = OverflowPin.startEdge;
    bool           sideAxisSlide;   /// Ariakit `overlap`; opt-in, defaults off
}

/// Two named module-level presets, in Base UI's style — never per-widget flag soup.
immutable CollisionPolicy dropdownCollision = CollisionPolicy(
    adjust: Adjust.slideX | Adjust.resizeY);         /// height-capped: never flip the axis
immutable CollisionPolicy popupCollision = CollisionPolicy(
    adjust: Adjust.flipY | Adjust.slideX | Adjust.resizeY);
```

**Evidence.** The six-bit adjust mask is [gtk4]'s `GdkAnchorHints`, which is also
[xdg-positioner]'s `constraint_adjustment`; keeping `Placement`+`CollisionPolicy`
structurally isomorphic to `(anchor rect, anchor, gravity, adjustment bitmask, offset)` is
cheap insurance for a future native-windowing backend. Flip on the side axis and slide on the
edge axis is the rule for overlays that must stay visibly attached; every subject examined
that permits side-axis shift makes it **opt-in** ([ariakit] `overlap`, [base-ui]
`shift.crossAxis`, Apple's `canOverlapSourceViewRect`) — and deliberate side-axis overlap is
nonetheless a shipped policy for menu cascades ([imgui] overlaps by `ItemInnerSpacing` "to
convey the relative depth of each menu"; [turbo-vision]'s diagonal submenu) (`D2.C2`,
narrowed — the original "sliding on the side axis is a defect" overreached).

`FlipAcceptance` is a genuine, verified fork: [gtk4] accepts a flip when it is _less bad_,
[xdg-positioner] reverts unless the flipped position is _fully unconstrained_, and the two
rules produce observably different placements with the subsequent slide pinning them to
opposite edges (`D2.C7`, upheld with correction — and note the divergence is between GTK's
**non-Wayland** backends and the protocol, i.e. observable inside one toolkit). Making it a
field rather than a hard-coded rule is what keeps a future `xdg_popup` backend honest.

`OverflowPin.startEdge` is the majority rule among the shift-style implementations
([textual]'s `translate_inside`, react-aria's `getDelta`, [gpui]'s right-then-left clamp,
and sparkles' own `clampOrigin`) — but it is a **choice, not a consensus**: Avalonia pins the
end edge and Compose centres (`D3.C5`, narrowed).

### 3.4 `AnchoredOverlayController`

```d
enum OverlayScope : ubyte { surface, container }
enum HitBehavior  : ubyte { normal, blockPointer, blockPointerExceptWheel }

/// Everything the caller declares about one overlay. Regular; no callbacks.
struct OverlaySpec
{
    OverlayBand   band  = OverlayBand.popup;
    OverlayScope  scope_ = OverlayScope.surface;
    Anchor        anchor;
    Placement     placement;
    TriggerPolicy trigger;
    DismissPolicy dismiss;
    FocusPolicy   focus;
    HoverPolicy   hover;
    HitBehavior   hit = HitBehavior.normal;
    bool          grab;   /// immutable after open — xdg's `invalid_grab` rule
}

struct OverlayRecord
{
    OverlayId       id, parent;    /// `parent.gen == 0` => root-owned
    OverlaySpec     spec;
    OverlayGeometry resolved;
    Side            lastGoodSide;  /// hysteresis input, an explicit field not a hidden memo
    OpenCause       cause;
    DismissReason   closing;       /// != none while closing
    Timeline        life;          /// STM6, composed
    size_t          anchorHit, triggerHit, focusReturn;
    uint            openedFrame;   /// one-frame outside-dismiss exemption
}

struct AnchoredOverlayController
{
    SmallBuffer!(OverlayRecord, 8) open;  /// index order == paint order == reverse hit order
    uint   nextGen = 1;
    int    warmUntilMs;   /// the shared cool-down arbiter, ONE integer
    size_t pressAnchor;   /// the two-phase outside test's armed group

@safe pure nothrow @nogc:
    bool      isOpen(OverlayId) const;
    size_t    indexOf(OverlayId) const;
    OverlayId topmost(OverlayBand) const;
    bool      isWithin(OverlayId maybeAncestor, OverlayId candidate) const;
    OverlayId topmostAncestor(in WidgetTree t, size_t candidateWidget) const;
}

/// The transition, split in two so a veto needs no duplicated transition table.
Plan plan(in AnchoredOverlayController c, in Event e,
          scope const HoverTarget[] hits, in OverlayEnvironment env) @safe pure nothrow @nogc;
AnchoredOverlayController apply  (in AnchoredOverlayController c, in Plan p, in OverlayEnvironment env);
AnchoredOverlayController stepped(in AnchoredOverlayController c, int dtMs);
```

**Evidence.** Openness is **membership**, not a per-record boolean: the subjects that get
nesting and LIFO dismissal right own one ordered collection ([imgui]'s two stacks, HTML's
popover stacks, [slint]'s `active_popups`, [headlessui]'s stack machine), and the subjects
keeping only a per-overlay boolean with no ordered collection ([tippy], [floating-vue])
reconstruct ordering ad hoc (`D15.C4`, narrowed — whether openness is _also_ stored per
record is orthogonal; ImGui and Slint drop it, HTML and Headless UI keep both).

The ancestor relation is a **query over list order**, never a stored tree. [popover-api]
states the mechanism outright: the parent popover must be strictly earlier in the list, which
"allows for the construction of a well-formed tree from the (possibly cyclic) graph of
connections". Cascading dismissal is a **truncation** at an index computed by an ancestry
predicate — `hide popover stack until` slices, [imgui]'s `ClosePopupToLevel` is literally
`OpenPopupStack.resize(remaining)`, react-aria's `expandedKeysStack` is `slice(0, level)`.

`parentId` is **in** the primitive, against [angular-cdk]'s nine-year practice, because CDK's
flat array is only viable where the host supplies containment/invocation ancestry: Blink
computes popover ancestors over DOM edges that already exist, and Radix/Base UI resolve
"inside" by DOM containment. A sparkles display list has neither relation (`D16.C5`,
narrowed — zag's counter-position is on record: it reports its shared layer stack cannot
express ownership and pushes submenu trees to the application).

`plan`/`apply` is Flutter's request/commit split reduced to values, and it follows an
in-tree precedent exactly: `libs/ui/src/sparkles/ui/dock.d:826` already declares
`struct Route` as "One routing decision — a value, so routing is testable without panes."
_INFERENCE:_ a value-shaped plan is a better veto than a cancelable event object here — no
allocation, no listener bookkeeping, and the plan is assertable on the recording canvas
**without being applied**. The stronger form of that claim ("returning effects as values
eliminates the re-entrancy apparatus by construction, and the inversion is mechanical") was
**refuted**: [turbo-vision]'s `TMenuView::execute` opens submenus through a blocking
`execView` whose return value is consumed in the same loop iteration, and converting that is
a redesign, not a mechanical inversion.

### 3.5 `TriggerPolicy` and `HoverPolicy`

```d
struct TriggerPolicy   /// a DECLARATION, in the style of `BoxStyle.arrow`
{
    bool hover, focusVisible, activate, longPress, contextMenu;
}

struct TriggerPlan { TriggerPolicy served, dropped, substituted; }

/// `ScrollbarState.expanded(caps)`'s shape, one dimension over (`state.d:834`).
TriggerPlan resolveTriggers(in TriggerPolicy want, in InputCapabilities caps)
    @safe pure nothrow @nogc;

enum OpenCause       : ubyte { none, programmatic, hover, focusVisible, activate, longPress, contextMenu }
enum TriggerPriority : ubyte { background, sustained, deliberate }
TriggerPriority priorityOf(OpenCause) @safe pure nothrow @nogc;

struct HoverPolicy
{
    bool hoverable;        /// contributes a hit entry at all (false for a tooltip)
    int  gapCells;         /// 0 = zero-gap contact, and the default
    int  openMs, closeMs;  /// warm-up / cool-down
    int  warmFloorMs, skipMs;
    bool requireRest;      /// id-stability gate, not a pixel threshold
    bool corridor;         /// emit a corridor hit entry while a bridge is armed
    bool intentLatch;      /// submenu direction latch; requires a motion stream
}
```

**Evidence.** `TriggerPolicy` has no precedent in the repo and is justified under `PRN8`
because it is a **declaration, not a behaviour** — nothing in the toolkit currently lets a
component say which trigger it wants. Its shape comes from React Aria's
`trigger ∈ {press, longPress, contextMenu}` and Flutter's `TooltipTriggerMode`; the idea that
a target simply **omits rows it cannot serve** is [floating-vue]'s `SHOW_EVENT_MAP` /
`HIDE_EVENT_MAP`.

`resolveTriggers` is the mechanism that retires `IXR26`. Note two verified constraints on its
rules. **Long-press cannot be the default hover substitute**: `tierOf(GestureEvent) ==
precise` exceeds `cellPointer.tier == interactive`, and `TuiHost.frameSeconds() => 0` leaves
no clock for a hold (`D12.C1`, narrowed — the terminal declares `hover: true`, so the
substitution rule never fires there anyway); and a toolkit default of long-press would
collide with a gesture hue has already spent on the only target that needs a substitute —
on Android `longPress` starts a text selection (`D12.C4`, upheld). **Tap-to-pin is the only
substitution expressible on all three live targets**, because the terminal decodes SGR-1006
release, raylib derives press/release edges, and the Android recognizer emits a tap as
press+release (`D12.C2`, upheld with correction).

Two claims here were **refuted** and are not restated as requirements: that `INP16` costs the
primitive exactly one trigger (it costs the whole release-edge key family, and lone-modifier
gestures such as WPF's Alt/F10-up have **no** press-edge alternative), and that a single
`OpenCause` enum suffices to derive every cross-trigger suppression rule (it subsumes the
open-time readers but not time-scoped suppression, close-cause suppression while shut, or
pointer-down-derived focus suppression).

`gapCells = 0` as the default for a hoverable overlay is the [uno] / [qt-quick-controls] /
[imgui] / [notcurses] / [tmux-popup] / hue consensus, and it is the cheapest possible answer
to the whole travel problem: with a zero-cell corridor there is nothing to cross. hue's GUI
already ships the correct answer for the anchor→overlay half — zero-gap placement plus a
zero-tolerance containment test against the last-painted rect — and its defects are that it
is per-application, GUI-only, outside the shared hit list, and expressed in pixels
(`D7.C6`, upheld with correction).

### 3.6 `DismissPolicy` and `FocusPolicy`

```d
enum DismissOn : ushort
{
    nothing     = 0,
    closeRequest      = 1 << 0,  /// `isDismiss` — Escape and the Android back key (INP13)
    pressOutside      = 1 << 1,
    releaseOutside    = 1 << 2,
    outsideAnchor     = 1 << 3,
    triggerReactivate = 1 << 4,
    focusOutside      = 1 << 5,
    surfaceBlur       = 1 << 6,  /// NOT detectable on the TUI today
    anchorGone        = 1 << 7,  /// mandatory: bypasses the policy word
    anchorClipped     = 1 << 8,  /// HIDES, does not close
    unplaceable       = 1 << 9,
    resize            = 1 << 10,
    scroll            = 1 << 11,
    siblingOpened     = 1 << 12,
    cascade           = 1 << 13,
}

enum DismissReason : ubyte
{
    none, programmatic, closeRequest, pressOutside, releaseOutside, outsideAnchor,
    triggerReactivate, focusOutside, surfaceBlur, anchorGone, anchorClipped,
    unplaceable, resize, scroll, siblingOpened, cascade, parentClosed, timeout,
}

struct DismissPolicy
{
    DismissOn on;
    size_t    group;        /// Flutter's `groupId`: a menu chain is ONE dismiss target
    bool      passThrough;  /// does the dismissing press also reach what it hit?
}

DismissReason wouldDismiss(in DismissPolicy p, DismissCause cause, in DismissFacts f)
    @safe pure nothrow @nogc;

enum Containment : ubyte { none, inline_, contain, modal }

struct FocusPolicy
{
    Containment containment = Containment.none;
    bool takesKeys;         /// truncate the ordered key chain here
    bool suppressInitial;   /// set for touch and for `OpenCause.longPress`
    bool restoreOnClose = true;
}
```

**Evidence.** Policy-as-flags ANDed with a router-offered cause is **shipped**, in [qt-quick-controls]'s
`tryClose`, with Escape tested against the same flags value in a separate handler. The
narrowing the verification forced is load-bearing: the evaluator's inputs must **also** include
latched press-phase state and per-pointer-type thresholds, and a separate class of
**mandatory** causes (anchor removed, unplaceable) must bypass the policy word entirely
(`D8.C1`, narrowed).

`PressState` (`STM10`) already implements the two-phase outside-dismiss identity test —
`released(hitId) => activated iff hitId == armed` is exactly Blink's `sameTarget` — but it
needs its **own instance keyed by surface/group id**, because `activated` is transient and
there is a single `armed` slot; sharing the button-activation instance would let an
in-overlay button press disarm the overlay's outside test (`D8.C2`, upheld with correction).

Two dismissal causes must degrade explicitly on the TUI, and the precise scope matters:
what the terminal cannot detect is **window/app deactivation** and **the pointer leaving the
terminal window**. Hover-exit _between targets inside the grid_ is fully detectable under
mode 1002/1003 and must **not** be declared unavailable (`D8.C4`, upheld with correction).

`Containment` is a four-value enum on the spec rather than four widget types (WinUI's lesson:
copy the booleans, not four control types). The corresponding new derivation, `focusTargets`,
is genuinely new because **sparkles has no toolkit-owned focus order at all** — `FocusState`
is one `size_t focused` traversed only over a caller-supplied `scope const size_t[] order`,
and the only order array in the repo is hand-written in a gallery page (`D9.C1`, upheld with
correction). Restoration must be guarded by "is focus still inside the closing overlay", with
six independent instances in the corpus ([blink], [popover-api], [angular-cdk], [wpf],
[textual], [react-aria]) (`D9.C8`, upheld with correction).

The claim that `INP16` costs the focus dimension nothing was **refuted**: GTK's press/release
focus-visible pair and WPF's Alt/F10-on-key-up entry into menu mode are real casualties and
must be rebound to key-down.

### 3.7 `OverlayEnvironment`

```d
/// Facts about the world, supplied by the HOST. The solver queries nothing.
struct OverlayEnvironment
{
    Rect              surface;        /// the whole cell surface
    Insets            viewportInsets; /// safe area + soft keyboard + reserved chrome
    Rect              scope_;         /// this overlay's scope: surface, or a container box
    InputCapabilities caps;           /// `TGT5` / `INP14`
    int               nowMs;          /// wall time, for deadlines (NOT rendered dt)
    uint              frame;
    bool              reducedMotion;  /// a Config/theme INPUT, never discovered
    bool              unicode;        /// `sparkles.base.term_caps`, for the arrow glyph
}

Rect boundaryOf(in OverlayEnvironment env) @safe pure nothrow @nogc
    => env.scope_.intersection(env.surface.deflate(env.viewportInsets));
```

**Evidence.** Placement's coordinate space and boundary must be explicit **parameters**, not
derived inside the solver: the three in-repo `clampOrigin` call sites disagree on unit (pixels
versus cells), on boundary (anchor-relative pixel edge / pane width / whole grid) and on
clipping, and [compose] — which derives the boundary — carries an open bug for exactly that
mismatch (`b/256233441`), with [xdg-positioner] the second witness by omission, never defining
the usable work area at all (`D1.C7`, upheld with correction). The default boundary is the
**surface deflated by viewport insets**, not the anchor's clipping ancestor; the clipping
ancestor governs only the `anchorHidden` verdict. That is the settled answer among the
in-canvas subjects examined ([gpui], [flutter], [textual], Neovim's screen clamp, CDK's
report-only booleans) and explicitly **not** the DOM default (`D3.C3`, upheld with correction).

The soft-keyboard / cutout inset must be an explicit input folded into the boundary before
placement, and two mature toolkits model the inset and then keep it out of popup placement:
[slint] computes `safe_area_inset()` and applies it to the window item but hands `place_popup`
a clip region of the full window size; [imgui] documents `WorkInsetMin/Max` as iOS
`safeAreaInsets` / Android `DisplayCutout` but `GetPopupAllowedExtentRect` deliberately uses
`GetMainRect` (`D12.C8`, upheld with correction). [gtk4]'s Android backend gets it right by
construction: the toplevel subtracts `systemBars | displayCutout | ime` insets from the
measured size, so the IME inset is an input to placement rather than a discovery.

Reduced motion is not uniformly discoverable across sparkles' targets and must be a
Config/theme **input** — with one exception worth exploiting: static HTML can emit both
branches under `@media (prefers-reduced-motion)` and let the viewer's CSS engine choose
(deferred resolution, not build-time discovery). No subject examined reads reduced motion in
its overlay path at all (`D14.C7`, upheld with correction).

### 3.8 Where this straw man is already wrong

Attack these first.

- **`AnchorRect.rows` as a fixed `Rect[4]`** is arbitrary. The multi-rect anchor is a
  **latent** requirement, not a live one: hue's two TUI call sites keep only `rs[0]`, but a
  hover anchor is a single space-free identifier and the wrap engine never splits a word, so
  the discard is currently harmless (`D1.C5`, narrowed). The right capacity — and whether
  rows belong in `AnchorRect` at all rather than in a text-range strategy above it — is
  undecided.
- **`OverlaySpec` bundles seven policies into one struct.** Zag's inverted dependency pair is
  the argument that tooltip and toast want disjoint halves; a single struct means every
  overlay pays for every policy's fields. A split into `{geometry, behaviour}` sub-structs is
  plausible and untested here.
- **`plan`/`apply` returns `AnchoredOverlayController` by value.** With
  `SmallBuffer!(OverlayRecord, 8)` and `OverlayRecord` this wide, the copy is not free. The
  alternative — `apply` taking `ref` — costs the "assertable without being applied" property
  that motivated the split.
- **`HoverPolicy` mixes a capability bit (`hoverable`), geometry (`gapCells`) and timing
  (`openMs`).** The timing half arguably belongs to the `DwellState` machine (§4) and not to
  the spec at all.
- **`OverlayEnvironment.nowMs` is wall time while `Timeline` consumes rendered `dt`.** Two
  clocks in one design is a smell; §4.7 argues it is forced, but that argument is the weakest
  in this document.
- **`grab` is declared and unenforceable.** It is future-proofing for a backend that does not
  exist. A reviewer may reasonably say: delete it until the native-windowing layer lands.

---

## 4. The proposed state machines

### 4.0 The composition budget

`PRN8` forbids a second definition of a behaviour the toolkit already owns. The budget below
is therefore stated as _what is composed_ versus _what is genuinely new_.

| Existing machine        | What it supplies to the overlay primitive                                                | Changed?                                                                               |
| ----------------------- | ---------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| `HoverState` (`STM4`)   | `hot` (topmost-hit-wins over the flat list) — the hover trigger and the "inside" test    | no, for positional routing; **yes** for modality (a `HitBehavior` field on the target) |
| `Timeline` (`STM6`)     | fade-in / hold / fade-out, `holdUntilDismissed`, `dismissed()`; the exit-animation clock | no (see §4.7 for why the warm-up may **not** live here)                                |
| `FocusState` (`STM7`)   | the focus ring over a caller-supplied order; `focusReturn`                               | no — but a new `focusTargets` derivation and a `focusOrder` splice sit above it        |
| `PressState` (`STM10`)  | trigger activation, item arming, and the two-phase outside-press identity test           | no — but dismissal needs its **own instance** keyed by group id                        |
| `CaptureState`(`STM11`) | press-and-drag menu traversal; the drag-out exemption from every outside cause           | no — its documented no-transfer rule is load-bearing and must not gain a priority      |

### 4.1 Tooltip

```
        hot == anchor                   now >= deadline
  idle ─────────────► warming ───────────────────────────► shown
   ▲                    │                                    │
   │  hot != anchor     │  isDismiss | press | key | scroll  │  hot leaves group
   └────────────────────┴────────────────────────────────────┴──► cooling ──► idle
                                                                      │  (sets warmUntilMs)
                                                             re-entry └──► shown
```

- **Composes** `HoverState` (the `hot` id), `PressState` (the tap route), `Timeline` (fade and
  `holdUntilDismissed`). **New**: `DwellState` (§4.7) and the two-integer `DwellGroup`.
- **Guards.** Every deadline is absolute — `armedAtMs + delay`, measured from the arm instant,
  never recomputed as `now + delay`. Re-arming on a changed `hot` id **is** the rest gate: id
  stability, not a pixel threshold, which is unit-free and exact in cells. `skipMs == 0` must
  **statically disable** warmth rather than arm a zero-length timer — Radix shipped that bug
  (`#3873`) and fixed it with early returns in both provider callbacks (`D6.C7`, upheld with
  correction; note WPF is **not** the mirror bug — it already disables structurally, and its
  override is deliberate).
- **A tooltip contributes no hit entry** (`hoverable = false`), so hover passes through it and
  `PressState` never arms on it. Its content should additionally be non-interactive **by
  type** — text, not a `WidgetTree`. [aria-apg] states non-normatively that tooltips do not
  receive focus and names the substitute in the same breath ("a hover that contains focusable
  elements can be made using a non-modal dialog"), and three implementations enforce it
  structurally: [imgui]'s `ImGuiWindowFlags_NoInputs`, [headlessui]'s panel tag, [react-aria]'s
  separate `role='dialog'` component (`D13.C5`, upheld with correction).
- **WCAG 1.4.13 Persistent is a defaults trap, not a live bug.** `Timeline.Config` defaults to
  `holdMs = 1200` with `holdUntilDismissed = false` (`state.d:1206-1208`), so a hover- or
  focus-triggered overlay taking the **default** config on a frame-clocked backend would
  self-close in 1.2 s — shorter than any max-display duration in the survey. No surface in the
  tree does this today: every call site sets an explicit config, and hue's popup already pins
  `holdUntilDismissed: true` (`gui.d:2935`) (`D13.C3`, narrowed). _RECOMMENDATION:_ the
  primitive must pin `holdUntilDismissed: true` for every hover- or focus-triggered surface and
  make a finite `holdMs` unreachable there, so the trap cannot be re-entered by the next
  consumer.
- **Touch collapse.** `caps.hover == false` ⇒ `resolveTriggers` moves `hover` to
  `substituted` and `activate` takes over: tap-to-pin over `PressState`, `openMs` statically
  0, `warming` unreachable, `cooling` unreachable, `holdUntilDismissed` pinned. `suppressInitial`
  focus is set so the Android soft keyboard is not provoked — three independent implementations
  suppress initial focus on touch ([headlessui] drops the initial-focus bit,
  [base-ui] focuses the popup container itself naming Android, [compose] adds
  `FLAG_NOT_FOCUSABLE` for editable anchors). The substituted gesture must be **published** —
  as a readable resolution value and as an accessible description — or it becomes a silent
  product hole; suppression alone is correct only when the content survives elsewhere
  (`D12.C10`, upheld with correction).
- **Tier-0 collapse (static HTML).** `openMs` becomes `transition-delay` on the `:hover` rule
  and `closeMs` becomes `transition-delay` on the base rule — independently, with mid-delay
  cancellation free because the property reverts. This requires switching
  `.spk-hit:hover>.spk-reveal{display:block}` (`interp/html_semantic.d:58`) to
  `visibility`/`opacity`, since `display` is not transitionable (`D6.C6`, narrowed).
  **Honestly absent**: warmth, rest, instant-swap, the singleton and max-duration. Emit one
  precomputed state and report the drop under `TGT5`.

### 4.2 Popover

```
  idle ──activate (PressState)──► open ──wouldDismiss(...)──► closing ──Timeline idle──► idle
                                   ▲ │
                        re-open ───┘ └─── triggerReactivate
```

- **Composes** `PressState` (open and `triggerReactivate`), `FocusState` (`Containment.contain`),
  `Timeline` (the closing phase), `CaptureState` (drag-out exemption). **New**: only the
  arena membership and `wouldDismiss`.
- **Guards.** `openedFrame` exempts an overlay opened this frame from outside-dismissal for
  exactly one frame — floating-vue's `$_showFrameLocked`, and the honest fix for baseline
  `B0.5` (events route against the last painted frame, so an overlay's hit rect is one frame
  stale **by construction**). The outside test is two-phase over the popover's **own**
  `PressState` instance: press-in / release-out must not dismiss.
- **Dismissal and consumption are independent.** The corpus splits on the default: [compose]
  delivers the dismissing tap when the popup is non-focusable and swallows it when focusable
  (both pinned in one test), [avalonia] re-raises the event on a re-hit-test, [tmux-popup]
  drops it outright. _INFERENCE (well supported, not sourced):_ because sparkles routes its own
  events, this must be an explicit per-overlay value — `DismissPolicy.passThrough`
  (`D11.C6`, upheld with correction).
- **Touch collapse.** None needed: press exists on every live target. Only `suppressInitial`
  changes.
- **Tier-0 collapse.** `<details>` / `<summary>` is the one tier-0 spelling of a real toggle,
  giving exactly one dismissal cause — `triggerReactivate` — plus hover-exit for the hover
  variant (`D8.C6`, narrowed). No outside-press, no Escape, no cascade. `html_semantic.d`
  already carries a `details.spk-disclosure>summary` CSS rule even though nothing emits
  `<details>`, so the vocabulary is unused rather than absent (`D11.C7`, upheld with correction).

### 4.3 HoverCard

The tooltip machine with three fields flipped, plus one geometric addition.

- `hoverable = true`, `gapCells = 0`, `Containment.inline_` — the overlay's ids are spliced
  into the tab order immediately **after its trigger's** id, which is what lets an overlay be
  appended last (as the no-top-layer constraint requires) without breaking Tab.
- The "inside" test widens from `hot == anchor` to `groupOf(hot) == myGroup`, where the group's
  region is the union of its rects. That is the generalisation of hue's `HoverPopup.hotPopup`
  (`apps/hue/src/gui_state.d:318`) — a `PixelRect` kept purely so "the pointer leaves a shifted
  popup the moment it moves onto it" — into the shared hit list.
- **When `gapCells > 0`**, arm a corridor: while a bridge is live, the overlay contributes
  **one extra `HoverTarget`** covering the corridor cells carrying the overlay's own `hitId`.
  `HoverState.update` already takes the last match, so the corridor needs no new predicate and
  no motion history. This is the `PRN8`-respecting move — the corridor is data in a list the
  toolkit already walks, not a second routing rule — and it is the only technique in the
  dimension that also survives tier-0 HTML, as a transparent padding band.
- **Touch collapse.** A hovercard on a hoverless target **is a popover**, which is also what
  the accessibility contract says: a hover surface containing focusable content is a different
  widget, not a tooltip configuration. `resolveTriggers` performs the substitution; nothing
  else changes.
- **Tier-0 collapse.** The overlay must be emitted as a DOM **descendant** of its trigger, with
  `:hover` / `:focus-within` holding it open and `gapCells = 0`. A hoisted emission breaks it
  outright — the same containment [aria-apg] independently makes mandatory for submenus.

### 4.4 Menu with submenu

```
  closed ──deliberate cause──► open(root) ──hover on item i (armed only)──► retarget(i)
                                   │                                          │
                                   │  key: right / Enter, or hover + delay     ▼
                                   │                                    open(child, parent: root)
                                   │  isDismiss / outside press / cascade      │
                                   └──────────────────────────────────────────┘
                                          closeAllExceptAncestorsOf(target)
```

- **Composes** `PressState` (arm on press, activate on release over the same target),
  `CaptureState` (a press-and-drag traversal takes the capture with the **root** overlay's id,
  so the whole cascade is one gesture owner), `FocusState` (item traversal over the overlay's
  own id slice — there is **no** separate roving-focus machine), `HoverState`, and the arena's
  `parentId`. **New**: `closeAllExceptAncestorsOf`, which [aria-apg] names as the tree's one
  real operation.
- **Menus deliberately do not use `DwellState`.** Adopt [turbo-vision]'s `autoSelect` — a
  sticky mode bit set by the opening gesture and cleared by the close — plus its
  `lastTargetItem` re-entry memo as a `suppressedId` cleared when the hovered id changes. Zero
  clock, so menu traversal survives both the clockless TUI and the HTML target, which the
  tooltip warm-up cannot. Two mechanisms, correctly, because menu traversal is gated by
  **mode** and tooltip traversal by **recency**.
- **Armed-hover is a rule of the primitive, not of the app**: hover may **switch** the open
  overlay within a group but may not **open** the first one. Make the switch a distinct
  `retarget(newAnchor)` transition, never close+open, or `Timeline` restarts and the surface
  flashes — Base UI and Zag independently reached the same conclusion.
- **Cascading dismissal is a truncation with a re-check.** [popover-api] re-reads the
  (possibly changed) list after hiding the slice, because a handler may have **shown**
  something during the hide, with a spec note that user agents are encouraged to warn. ImGui
  matches the truncation half but has no re-check; Qt bounds its loop at 1024 iterations.
  _INFERENCE:_ a **frame-built** arena dissolves the re-check — a reopen during dismissal
  simply appears in the next frame's arena — which is the single strongest reason to make the
  arena a frame-built value rather than a mutated retained structure (`D10.C10`, narrowed).
- **Submenu aim** is the one place a corridor earns its keep, and it is **advanced**, not v1:
  it must be a declared capability, because `RunConfig.motion` and `TerminalOptions.motion`
  both default to `false`, so a TUI host that has not opted into bare-motion reporting has no
  motion stream at all — only two applications plus one example opt in today (`D7.C5`, upheld
  with correction).
- **Touch collapse.** Hover switching is absent, so every level opens by tap; the corridor is
  never instantiated. **No subject in the corpus computes hover intent for touch** — most
  switch the machinery off at the source ([react-aria]'s touch early return, [floating-ui]'s
  gate, [uno]'s mouse-only gate, [base-ui]'s trigger check), [blink] is inert only as a side
  effect of requiring a known mouse position, and [compose] dispatches on pointer type with a
  touch fallback in the same expression (`D7.C8`, upheld with correction). Cascade dismissal
  and the arena are unaffected.
- **Tier-0 collapse.** Nested `<details>` gives disclosure but no cascade, no topmost query and
  no cross-overlay ordering. Apple's HIG rule "never display multiple popovers or cascading
  hierarchies" should become a **hard constraint on the HTML target** rather than a guideline:
  one level only.

### 4.5 The one genuinely new machine, and its `PRN8` justification

`DwellState` (proposed `STM12`) — **existence over wall time, not rendered time**.

```d
struct DwellState { Phase p; size_t armedId; int armedAtMs; }
enum   Phase { idle, warming, open, closing }
struct DwellGroup { size_t openId; int warmUntilMs; }   // the whole cross-instance protocol
```

`PRN8` demands that this not be a second definition of `Timeline`. It is not, on three
independent grounds, all verified in source (`D6.C3`, upheld with correction):

1. `Timeline.fadeIn` already reports `visible() == true` (`state.d:1245`), so a "warming"
   overlay composed from `STM6` would enter the display **and** hit lists.
2. `dismissed()` from `fadeIn` returns `Timeline(fadeOut, 0)` whenever `cfg.fadeOutMs > 0`, and
   `alphaPercent` at elapsed 0 is 100 — so a cancelled warm-up plays a **full-opacity**
   fade-out instead of vanishing.
3. On the TUI `stepped` is never driven, because `TuiHost.frameSeconds()` returns a hard-coded
   `0` (`tui_loop.d:109`), so anything advanced by rendered `dt` is frozen there.

That third point is also why `OverlayEnvironment` carries `nowMs` (wall time) beside
`Timeline`'s rendered `dt`, and it is the weakest joint in this proposal. The deadline **ask**
needs no new host API: `HostState.wakeIn(Duration)` (`HST16`) is re-armed per frame, keeping
the soonest, honoured by both terminal arms and subsumed by pacing on the GPU arm, and recorded
per frame. But it is only half a deadline machine — **no host exposes `now`**, and `record.d`
explicitly does not simulate time, so the instant must be an **injected parameter** and the
recorder can assert only that the right deadline was **armed**, not that it fired (`D6.C2`,
narrowed). That is the whole reason `nowMs` is a field of the environment rather than something
the machine reads.

The shared cool-down is **two integers on an arbiter, with no per-widget state**: six
independent lineages converged on it (WPF/Avalonia, WinUI, Qt, GTK, React Aria, Radix/Ariakit,
Floating UI/Base UI), and the derived-from-live-state variants ([flutter], [zag]) are strictly
weaker because they cannot express "the last one closed 200 ms ago" (`D6.C4`, narrowed).

---

## 5. The geometry pipeline

### 5.1 Findings — the canonical ordering, and where the evidence contradicts it

The ordering most of the corpus implies is Floating UI's middleware chain: measure anchor →
measure content → candidates → base placement → offset → clip measurement → flip → shift →
size → arrow → visibility → emit. Four subjects order it differently, and one of them
documents why.

- **The ordering contract in Floating UI is enforced by nothing.** "`offset` before `shift`,
  `size` after `flip`, `arrow` near the end, `hide` last — all documentation. A wrong order
  produces a subtly wrong position with no error." `size()` must run **after** `flip` to see
  the final placement, but its `reset` re-enters `flip` with `flip`'s overflow accumulator
  already populated, because `middlewareData` is never cleared across a reset. _INFERENCE
  (from reading `computePosition` together with `flip`; no test found and none constructed):_
  a `size()`-driven reset can therefore change `flip`'s fallback choice. That is the documented
  reason the canonical order is not free — it buys correctness with a restart protocol.
- **[gtk4] and [xdg-positioner] fix the precedence in the value, not in a chain**: flip →
  slide → resize, in that order, documented in `gdkpopuplayout.h` and enforced by ordering in
  the solver. Resize is **last** in both. _RECOMMENDATION:_ adopt that precedence, which means
  `Palette.popupMinWidth`'s doc comment ("wider than this shifts the popup instead of
  shrinking it further", `style.d:233`) is stating the opposite precedence and must be
  reworded — shift first, then shrink, floored at `popupMinWidth`.
- **Where the chosen side determines the size budget, the side must be decided first, from a
  size BOUND rather than a measured size** — [helix]'s height budget, [base-ui]'s
  `--available-height` dropdowns, [gpui]'s aside. Most subjects examined instead measure first
  and then place, several with no second pass and no stability hack ([gtk4], [slint],
  [textual], [flutter]) (`D2.C6`, narrowed). The recommendation to decide-then-measure is a
  sparkles-specific judgement, argued below.
- **Clip measurement is not a pipeline step here.** Sparkles must not reproduce [floating-ui]'s
  three-required-method measurement `Platform`; `layout()` **is** the measurement and it is not
  abstract (`D3.C9`, upheld with correction). `getClippingRect`'s work is already done: the
  clip stack is threaded to every node by `childClipOf` (`layout.d:560`) and collapsed to one
  `Rect`.
- **`anchorHidden` is available before placement, not after it.** It is
  `anchor.intersection(anchorClip).empty` over a value that already exists. [css-anchor] makes
  `anchors-visible` the _initial_ value of `position-visibility`, and the hide-versus-fit split
  is stated by the CSS Anchor Positioning spec itself rather than read out of Blink
  (`D3.C3`, corrected).
- **The arrow is an input to the fit test, not a terminal step.** [winui]'s `TeachingTip` needs
  a tail, `FlyoutBase`'s fit test has no notion of an arrow inset, and `TeachingTip` therefore
  reimplements placement, fallback ordering, RTL mapping and light dismiss from scratch. Its
  main-axis cost is a 0-or-1-cell constant known before layout.
- **The pipeline runs once per frame inside the existing pass.** Anchored-overlay placement can
  be a single pure function of already-measured values, run in the same frame pass that
  `layout()` produced them in — today between `layout()` and `buildDisplayList` at every hue
  site — with no observer machinery, **provided** the max-size clamp stays derived from
  (anchor, boundary) alone, as `effectivePopupWidth` already is (`D3.C1`, upheld with
  correction). That deletes [floating-ui]'s 264-line `autoUpdate` outright.

### 5.2 Recommendation — the challenged ordering

```
 0. resolveAnchor            -> AnchorRect { primary, rows, clipped, live }
                                anchorHidden is KNOWN HERE, not at the end
 1. boundaryOf(env)          -> Rect        (a parameter; nothing is queried)
 2. chooseSide(bounds)       -> (Side, Size budget)      arrowClearance participates
 3. layout(content, budget)  -> Size        the toolkit's own measurement pass
 4. base placement + offset  -> anchor edge x gravity, then sideOffset/alignOffset
 5. flip   (side axis)       -> acceptance rule is an explicit CollisionPolicy field
 6. shift  (edge axis)       -> start edge pinned when the overlay exceeds the boundary
 7. resize (last)            -> floored at popupMinWidth / popupMinHeight
 8. arrow cell               -> from the already-shifted rect; clamp asserts min <= max
 9. emit OverlayGeometry     -> rect, side, align, fit, applied, arrowCell, available, ...
```

Five deliberate departures from the canonical order, each with its reason:

| Departure                                                       | Why                                                                                                                                                                                     |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Content measurement moves after side selection** (2 before 3) | sparkles' pipeline is `view → layout → buildDisplayList → paint`; the side determines the budget handed to `layout`, so deciding from a measured size decides from a size it constrains |
| **Clip measurement deleted**                                    | the boundary is a value and `childClipOf` already collapsed the clip chain; there is nothing to measure                                                                                 |
| **Visibility hoisted to step 0**                                | `anchorHidden` is a property of the anchor and its clip, not of the placement result                                                                                                    |
| **Arrow appears twice** (clearance at 2, cell at 8)             | its cost is a placement input; its position is a placement output. WinUI forked an engine for want of the first half                                                                    |
| **`size` keeps its post-`flip` position but loses the restart** | a toolkit that owns layout returns a size **constraint** and re-runs layout, instead of Floating UI's mutate-then-remeasure-then-reset round trip                                       |

**One-frame correctness is a spec obligation, not an aspiration.** A `--render` / recording
golden paints exactly one frame and would expose ImGui's one-frame-invisible popup if
`place()` ever needed a second measurement. Assert it there.

### 5.3 What `place()` must return

**Findings.** Returning only an offset is the named anti-pattern, and [compose] prices it:
`caretX` disagrees with its own `abovePositioning` by `anchorLeft` in the left-collision branch
— `caretX(200f, 1000, Rect(left=10, right=30))` yields 10 where 20 is correct — and the
disagreement is untested. Both functions do share the same extent, so the phase-1
boundary-mismatch explanation is **wrong**; the divergence is arithmetic, not a boundary bug
(`D4.C8`, upheld with correction). Downstream, discarding the side costs re-derivation in every
subject examined with a side-dependent consumer, and where the re-derivations are written
independently they diverge (only company-mode exhibits a **verified** drift).

**Recommendation.** Return `OverlayGeometry` (§3.2) — the full decision record, not a rect and
not an offset. Every field is an integer or a small enum the solver computes anyway, so
emitting it is free; the **discard** is the mistake. Two fields earn special mention:

- `fit`, including `refused`. We are the host; there is nobody to clip for us, and `refused` is
  real on a 40×10 terminal. [winui]'s `TeachingTip` ships exactly that outcome
  (`if (tipDoesNotFit) IsOpen(false)`).
- `arrowCentred`. In cells the caret must be **exact**, not tolerant: a caret one cell off names
  a different character. Whether that argues for suppressing rather than clamping is a
  **judgement, not a finding** — the strong form of that claim was downgraded to an explicit
  inference, because **no cell-grid subject in the corpus has an anchor-pointing caret at
  all**. The mature cell-grid overlays examined ([helix], [neovim-floats], blink.cmp,
  [notcurses], [tmux-popup], [ratatui], [textual]'s tooltip, [turbo-vision]) buy the
  relationship with contact, a reserved cell or column identity instead. The px corpus splits:
  five subjects suppress ([floating-ui]'s `centerOffset` residual, [radix]'s `shouldHideArrow`,
  [floating-vue]'s `arrowOverflow`, [flutter]'s too-narrow drop, [winui]'s
  `TailVisibility.Collapsed`) and four clamp without reporting ([react-aria], [zag], [ariakit],
  [gtk4]).

---

## 6. The platform-adapter surface

### 6.1 Findings — the two strongest witnesses, and a third

- **[avalonia]: four members.** `IManagedPopupPositionerPopup` exposes exactly `Screens`,
  `ParentClientAreaScreenGeometry`, `Scaling`, and `MoveAndResize(devicePoint, virtualSize)`.
  Everything the engine knows about the world arrives through those four; everything it decides
  leaves through the last. That is why `OverlayPopupHost` can implement it by reporting a single
  synthetic "screen" equal to the overlay `Canvas` deflated by the safe-area padding,
  `Scaling => 1`, and `MoveAndResize` = `Canvas.SetLeft/SetTop` — **the engine cannot tell an
  in-window `Canvas` from a 4K monitor**.
- **[floating-ui]: three required methods.** `getElementRects`, `getClippingRect`,
  `getDimensions`, plus optional refinements. The seam is real, proven three times: the DOM
  adapter (~1500 lines of browser archaeology), `@floating-ui/react-native` (106 lines over
  `View.measure` — a genuine asynchronous measurement path, not a no-op), and a canvas driver
  whose entire platform is three inline functions including `getElementRects: (data) => data`.
- **[gtk4]: one interface, two substrates.** `GdkPopup` is normally a real compositor surface,
  but the **Android backend implements the identical interface as an in-window child View**
  clipped to the parent surface rect; the same `GdkPopupLayout` value and the same in-process
  solver serve both. On Android the bounds become `{0, 0, parent.width, parent.height}` and the
  IME inset is subtracted upstream.

The verified conclusion for sparkles is that the measurement seam **must not be reproduced**:
Floating UI abstracts measurement only because it cannot see the DOM, while sparkles'
measurement is synchronous, in-process and already done by `layout()` (`D3.C9`, upheld with
correction). And a top layer requires **no new backend capability**: `isCanvas!T` is unchanged
and `RaylibCanvas`, `GridCanvas` and `RecordingCanvas` need no new operation, because the
clip pair is already an optional introspected capability and ops appended after the root walk's
balanced pops land unclipped. The toolkit-side work is display-list emission, hit-target
derivation, and the **layout** walk — natural-size accumulation plus `place()`, i.e. flow
exclusion, not merely extent (`D10.C1`, narrowed).

### 6.2 Recommendation — one value plus two optional hooks

**What a backend must supply is _facts_, not _operations_.** The adapter is
`OverlayEnvironment` (§3.7): six values a host already knows. That is Avalonia's discipline —
deflate in the adapter, so the solver never learns about insets — and it is strictly smaller
than Floating UI's `Platform`, correctly, because our measurement is not abstract.

On top of that, a **capability-by-presence** seam in the repo's design-by-introspection style —
two optional primitives, each defaulted when absent:

```d
/// Optional. Absent  => boundary = boundaryOf(env).
Rect boundaryFor(in OverlaySpec spec, in OverlayEnvironment env);

/// Optional. Absent  => the toolkit emits the solved rect into the display list.
void present(in Placement request, in AnchorRect anchor, in OverlayGeometry solved);
```

### 6.3 Testing the adapter against four targets

| Target                             | `OverlayEnvironment` fields                                                                           | `boundaryFor`                                | `present`                                                     | Verdict                        |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------- | ------------------------------ |
| **Cell grid** (`GridCanvas`)       | `surface` = grid; insets = reserved chrome / pane divider; `caps = cellPointer`; `unicode` probed     | absent (default)                             | absent (default)                                              | **served by the value alone**  |
| **In-window GPU** (`RaylibCanvas`) | `surface` = window in cells; insets = safe area (Android cutout + IME); `caps = mouse` or `touch`     | absent                                       | absent — scaling to pixels happens **after** placement        | **served by the value alone**  |
| **Static HTML** (`interp/html.d`)  | `surface` = an **assumed** grid at emit time; `caps = staticPointer`; `reducedMotion` deferred to CSS | **required** — the nearest clipping ancestor | absent, but placement is **frozen** and must be declared so   | needs one hook + a declaration |
| **Hypothetical `xdg_popup`**       | `surface` = parent window geometry; insets from the compositor                                        | absent                                       | **required** — hand the compositor the positioner, not a rect | needs the other hook           |

**The two failures are real and opposite, so the adapter must split.**

- **Static HTML cannot hoist.** `interp/html.d` emits the **widget tree** structurally as
  nested divs with `overflow:hidden` written from node clip fields, and recurses over
  `node.children` — structure, not a display list — so the compositor-time clip reset does not
  exist there; and tier-0 requires the overlay to remain a DOM descendant of its trigger,
  because `:hover` / `:focus-within` / `<details>` cannot reach a hoisted element (`D10.C2`,
  narrowed). Therefore on HTML an overlay's clipping ancestor **is** the boundary, and
  cross-target parity is bought by **choosing the boundary**, not by pretending the escape
  happened. That is `boundaryFor`'s entire reason to exist. The refutation condition is worth
  recording: a tier-0 CSS mechanism letting a hoisted element respond to a distant trigger's
  `:hover` — `:has()` plus a sibling selector is the candidate — would weaken this to "no
  clipping ancestor may sit between them".
- **A native positioner wants the value, not the answer.** xdg's model is that the client sends
  the **rules** and the compositor solves; if sparkles solves first, a real `xdg_popup` gets a
  pre-flipped rect and loses compositor-side reposition. `present` is the escape, and it is
  cheap **only if** `Placement` + `CollisionPolicy` stay structurally isomorphic to
  `(anchor rect, anchor, gravity, constraint-adjustment bitmask, offset)` — which §3.3 arranges
  deliberately. [gtk4] is the proof it is enough: the same `GdkPopupLayout` value serves
  `GtkPopover`, `GtkTooltipWindow` **and** `GtkTextHandle`, the last supplying no anchor hints
  at all because flipping a caret handle would be wrong.

**Publish intent, not mechanism.** The public value says `OverlayScope.surface` and a band; it
never says "windowed". [winui] and [avalonia] both choose their host **per open**
(`SetIsWindowedIfNeeded` re-evaluated every time; `CreatePopupHost`) and both keep the choice
internal — so an eventual `xdg_popup` backend satisfies `OverlayScope.surface` with a real
grabbing popup and the same `place()` result, with no public-API change. See
[window-system-integration](../window-system-integration/index.md) for what such a backend
would have to negotiate.

---

## 7. Prioritization

Judged on **UX impact × implementation cost × how many of our five targets can serve it**
(TUI, GUI, static HTML, Android, recording).

### must-have v1

| Item                                                                     | Targets | Impact / cost                                                          | Justification                                                                                        |
| ------------------------------------------------------------------------ | ------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `place()` + `Placement` / `OverlayGeometry` / `CollisionPolicy`          | 5/5     | high / low — one pure function over types `geometry.d` already has     | retires the three-call-site `PRN8` violation; nothing else in this list can be built without it      |
| `Anchor` / `AnchorRect` + a clip-aware resolver                          | 5/5     | high / low — every producer exists in `state.d`                        | keeps the primitive count at one across hover popup, dock hint, context menu and toast               |
| `OverlayEnvironment` + `boundaryOf` including viewport insets            | 5/5     | high / low                                                             | the only place Android's soft keyboard can enter as an **input**; deletes the three-boundary defect  |
| The arena, `parentId`, and the three resets (order, clip, extent)        | 4/5     | high / medium — three `if` branches in `libs/ui`, zero backend surface | fills `DCK13`'s empty top-layers rung; HTML is the exception and gets `boundaryFor` instead          |
| Arrow side + cell in the result; `Visual.arrowSide`; fix the two defects | 5/5     | medium / low                                                           | four canvases hard-code the top edge; `arrowOffset` is unclamped against the box today               |
| `DismissPolicy` / `DismissReason` (with `closeRequest` over `isDismiss`) | 4/5     | high / low — `INP13` already unifies Escape and the Android back key   | dismissal must be a **value** or it is not assertable on the recording canvas                        |
| `TriggerPolicy` + `resolveTriggers`                                      | 5/5     | high / low — `ScrollbarState.expanded`'s exact shape                   | retires `IXR26` **by construction**; `TGT5` requires declared, not silent, degradation               |
| `HoverPolicy.hoverable` + `gapCells = 0` default                         | 5/5     | high / trivial                                                         | with a zero-cell corridor the entire travel problem does not arise                                   |
| Pin `holdUntilDismissed` for hover/focus surfaces                        | 5/5     | high / trivial                                                         | `Timeline`'s 1200 ms default is a live WCAG 1.4.13 Persistent violation for any composed overlay     |
| A `ui-gallery` popup page rendered through `--render`                    | 5/5     | medium / low                                                           | the cross-backend proof; `HUE_GUI_HOVER` exists today only because overlays are unreachable in tests |

### important v2

| Item                                                          | Targets | Justification                                                                                                         |
| ------------------------------------------------------------- | ------- | --------------------------------------------------------------------------------------------------------------------- |
| `DwellState` + `DwellGroup` (warm-up, cool-down, rest)        | 3/5     | GUI + Android + recording; the TUI needs a frame clock first (`frameSeconds() => 0`), HTML gets the CSS approximation |
| `focusTargets` + the `focusOrder` splice + `FocusPolicy`      | 4/5     | no toolkit-owned focus order exists at all today; HTML gets the splice at **emit** time and never claims focus        |
| Keyboard routing at the `DCK13` rung (first refusal)          | 4/5     | the rung routes only pointers today; unbound keys must fall **through**, per company-mode, helix, tmux and GTK        |
| `closeAllExceptAncestorsOf` and the cascade                   | 4/5     | one truncation over the flat list; needed the moment a second overlay can be open                                     |
| Modality: `HitBehavior` on the derived targets + `Slot.scrim` | 4/5     | a ~4-line cut in the hit walk — but it must also cover `keyTargets`/`keyAt`, not `HoverState.update` alone (`D11.C3`) |
| `OpenCause` + `TriggerPriority`                               | 5/5     | selects the anchor kind, the initial focus and the delay; three values suffice for every conflict examined            |
| A foreground treatment for the scrim on cell canvases         | 2/5     | `fillRect` blends only the background, so a scrim leaves glyphs at full brightness on TUI while dimming on GUI/HTML   |

### advanced

| Item                                                       | Targets   | Justification                                                                                                                                       |
| ---------------------------------------------------------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hover corridor entry + `safeArea` hull                     | 2/5       | GUI + recording; TUI only where the host opted into bare-motion reporting, and never on Android                                                     |
| `PointerIntent` direction latch for submenus               | 2/5       | keep the failure **counter**, drop the angular test; the latch still needs a zero-delta guard in cells (`D7.C4`)                                    |
| `Anchor.avoid` / sibling disjointness as a placement input | 4/5       | with no z to hide behind, blink.cmp's policy is the only one that ports — but GPUI's evidence says mutual avoidance is a layer **on** the primitive |
| `AnchorTracking.live`                                      | 4/5       | latched is the right default; helix ships live with row hysteresis, so the field is justified, the default is not                                   |
| `revealedExtent` — a discrete reveal projection for cells  | 2/5       | `alphaPercent` is GUI-only; an N-row menu gets N steps, and the recording canvas asserts an integer                                                 |
| `present` hook / native positioner path                    | 0/5 today | pure future-proofing; costs nothing while `Placement` stays xdg-isomorphic                                                                          |
| Item-aligned `Select` placement                            | 4/5       | **outside** the primitive: four independent codebases escaped their shared solver for exactly this case                                             |

### not worth it here

| Item                                                 | Why not                                                                                                                                                                                                                           |
| ---------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A true safe **polygon**                              | at the corridor sizes the corpus's defaults produce (0 or 1 cells) it has no gap cells to classify; the strong claim that a rect is always equivalent was **refuted**, so keep the hull only where the corridor is genuinely wide |
| Floating UI's `requireIntent` velocity gate          | unrepresentable: `PointerEvent.pos` is cell-quantized at the input boundary                                                                                                                                                       |
| Portals, z-index, stacking contexts, `Portal` widget | there is nothing to escape; every one exists to compensate for a substrate sparkles lacks                                                                                                                                         |
| A per-overlay visibility flag                        | the paint walk and the hit walk would each have to honour it and one of them will forget                                                                                                                                          |
| The `aria-hidden` / `inert` / refcount apparatus     | no sparkles backend emits any ARIA/role/UIA today, and accessibility is an explicit non-goal in the TUI spec                                                                                                                      |
| A nested event loop for modality                     | the one mechanism in the dimension that must not port                                                                                                                                                                             |
| Observer / `autoUpdate` machinery                    | re-running `place()` in `layout()` is free and correct; 264 lines saved                                                                                                                                                           |
| Per-event pointer-type dispatch                      | not expressible today — `PointerEvent` carries no device kind and `pointerId` is hard-coded 0 by the raylib gesture arm (`D12.C5`, upheld). Declare it target-level via `InputCapabilities` instead                               |
| Long-press as the toolkit's default hover substitute | hue has already spent that gesture on Android text selection (`D12.C4`, upheld)                                                                                                                                                   |
| Discovering reduced motion                           | make it a Config/theme input; only static HTML can defer the choice, and it does so through `@media`                                                                                                                              |

---

## 8. Open questions

- **Identity across a rebuilt frame.** `hitId` is an author-supplied `Widget` field, not a
  toolkit-generated identity, and every current consumer derives it from a domain index. So
  frame-to-frame stability is an authoring **convention** the spec must state, not a property
  the toolkit guarantees (`D8.C5`, upheld with correction). Does `OverlayId` derive from the
  anchor's `key` plus the band (ImGui's `parentWindow.GetID(str_id)` idea), or from an
  application-owned slot?
- **`Widget.key` scope.** `key` also addresses `ElementStore`, and CSS's own motivating example
  shows what unscoped names do to N repeated components. A resolver adopting `keyAt`'s
  last-in-paint-order-wins would reproduce that collision; `keyedRects`/`keyTargets` return
  **all** matches, so nearest-ancestor or explicit ambiguity are both available (`D1.C6`,
  upheld with correction). Pick one before `Anchor.key` ships.
- **Does the ScrollView derive its content extent from a union of child frames?** The
  extent-exclusion reset is only load-bearing if it does; if extent comes from an explicit
  content size, one of the three resets disappears.
- **`OverlayScope.container`: discovered or declared?** Avalonia walks ancestors for a declaring
  layer manager; Flutter forces a submenu to inherit its root anchor's choice. The forcing rule
  is needed either way.
- **How deep may nesting go, and is the cap a static array bound (keeping the arena `@nogc` and
  `SmallBuffer`-sized) or a runtime assert?** GPUI asserts depth < 10; Qt bounds its close loop
  at 1024.
- **Does the recording canvas need to observe the arena, or only the emitted display list?** If
  assertions want "this overlay is a child of that one", the arena must be reachable from the
  recording target.
- **Is `WidgetKind.popup` retired or kept as a pure look?** Today it is `panel` + shadow — a
  name promising behaviour it does not have — and the shadow is dropped outright on TUI anyway.

---

## Sources

Every subject deep-dive in this catalog, and its pinned revision, is listed in
[`./index.md`](./index.md); the per-dimension analyses and the adversarial verification
verdicts are summarised there too. The repository-side baseline this proposal argues against
is [`./sparkles-baseline.md`](./sparkles-baseline.md), and the cross-subject synthesis is
[`./comparison.md`](./comparison.md) with [`./concepts.md`](./concepts.md) for the vocabulary
and [`./features-people-forget.md`](./features-people-forget.md) for the long tail.

Repository specifications this proposal is written against:
[`principles.md`](../../specs/ui/principles.md) (`PRN1`–`PRN12`),
[`state-machines.md`](../../specs/ui/state-machines.md) (`STM1`–`STM13`),
[`input.md`](../../specs/ui/input.md) (`INP*`, the tier ladder, the hit-testing model),
[`containers.md`](../../specs/ui/containers.md) (`DCK5`, `DCK13`),
[`backends.md`](../../specs/ui/backends.md) (`TGT5` and the degradation inventory),
[`widgets.md`](../../specs/ui/widgets.md) (`WGT7`, `WGT16`) and
[`theme.md`](../../specs/ui/theme.md).

<!-- References -->

[angular-cdk]: ./angular-cdk.md
[aria-apg]: ./aria-apg.md
[ariakit]: ./ariakit.md
[avalonia]: ./avalonia.md
[base-ui]: ./base-ui.md
[blink]: ./blink.md
[compose]: ./compose.md
[css-anchor]: ./css-anchor.md
[emacs-posframe]: ./emacs-posframe.md
[floating-ui]: ./floating-ui.md
[floating-vue]: ./floating-vue.md
[flutter]: ./flutter.md
[gpui]: ./gpui.md
[gtk4]: ./gtk4.md
[headlessui]: ./headlessui.md
[helix]: ./helix.md
[imgui]: ./imgui.md
[neovim-floats]: ./neovim-floats.md
[notcurses]: ./notcurses.md
[nvim-completion]: ./nvim-completion.md
[popover-api]: ./popover-api.md
[qt-quick-controls]: ./qt-quick-controls.md
[qt-widgets]: ./qt-widgets.md
[radix]: ./radix.md
[ratatui]: ./ratatui.md
[react-aria]: ./react-aria.md
[slint]: ./slint.md
[textual]: ./textual.md
[tippy]: ./tippy.md
[tmux-popup]: ./tmux-popup.md
[turbo-vision]: ./turbo-vision.md
[uno]: ./uno.md
[winui]: ./winui.md
[wpf]: ./wpf.md
[xdg-positioner]: ./xdg-positioner.md
[zag]: ./zag.md
[compose-popup]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/ui/ui/src/commonMain/kotlin/androidx/compose/ui/window/Popup.kt#L45
[compose-menusamples]: https://github.com/androidx/androidx/blob/268d841a45644cadf438fc335c793869728449ec/compose/material3/material3/samples/src/main/java/androidx/compose/material3/samples/MenuSamples.kt#L369
