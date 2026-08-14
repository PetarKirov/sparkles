# Apple — UIKit / AppKit / SwiftUI / TipKit (Swift, Objective-C)

Nine overlapping anchored-overlay primitives across four frameworks that share a content model and an eligibility engine but never share an anchor, a placement policy, or a dismissal API — read entirely from published documentation, because none of it ships source.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                                           |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language          | Swift / Objective-C (framework implementation not public)                                                                                                                                                                                                                                                                                                                                                       |
| License           | Proprietary, Apple. No source available under any license.                                                                                                                                                                                                                                                                                                                                                      |
| Repository        | None. There is no public source repository for UIKit, AppKit, SwiftUI or TipKit.                                                                                                                                                                                                                                                                                                                                |
| Documentation     | [`developer.apple.com/documentation`][apple-docs] (UIKit, AppKit, SwiftUI, TipKit reference) plus the [Human Interface Guidelines][hig-popovers]                                                                                                                                                                                                                                                                |
| Category          | Platform UI frameworks, desktop and mobile (closed source)                                                                                                                                                                                                                                                                                                                                                      |
| Surface model     | Both. AppKit's `NSPopover` and `NSMenu` are separate OS surfaces — a popover can be promoted into a real `NSWindow`, and a menu can be popped up in screen coordinates with no owning window at all — while UIKit's `UIPopoverPresentationController` is an in-window presentation-controller overlay and `UIContextMenuInteraction` is a system-managed presentation whose surface is never handed to the app. |
| **Revision read** | **`docs-only — no public source`.** Reference pages as published August 2026; symbols carry availability from iOS 8 / macOS 10.7 through iOS 26 / macOS 26.                                                                                                                                                                                                                                                     |

> [!IMPORTANT]
> **This entry is docs-only.** No Apple UI framework source was read, because none is public. Every statement below is read off `developer.apple.com` reference pages and the Human Interface Guidelines. There are no file paths and no line numbers to cite, and nothing here is an implementation reading. Where a mechanism is famous but undocumented — menu tracking geometry, tooltip delay constants, the "sloppy" submenu triangle — it is recorded as unverified rather than reconstructed from behaviour.

## Overview

### What it solves

Apple does not ship one anchored-overlay primitive; it ships at least nine that overlap. `NSPopover`, `NSMenu`, `NSView.toolTip` / `NSTrackingArea`, `UIPopoverPresentationController`, `UIContextMenuInteraction`, `UIEditMenuInteraction`, `UIToolTipInteraction`, SwiftUI's `.popover` / `.help`, and TipKit each solve a slice of "show this content next to that thing": inspectors and colour pickers (popover), command lists (menu), hover help (tooltip), touch-and-hold action sheets with a morphing preview (context menu), selection-attached commands (edit menu), and one-time teaching tips (TipKit).

The interesting structural fact is which pieces are shared. `UIMenu` / `UIMenuElement` is a single content model behind context menus, edit menus, button menus and the Mac Catalyst menu bar; the edit-menu delegate even hands the app the _system's_ suggested actions to merge, via `editMenuInteraction(_:menuFor:suggestedActions:)` [[uieditmenuinteractiondelegate]]. Anchoring, by contrast, is re-declared from scratch in every primitive: a positioning rect inside a positioning view, a source view plus source rect, a source _item_, an `NSEvent`, an `NSPoint` in view-or-screen space, a delegate-returned target rect, or a SwiftUI `Anchor` token. Dismissal is likewise re-invented four times.

### Design philosophy

Three ideas recur, and each is stated as a value rather than as behaviour.

**Dismissal policy is one enum on the surface.** `NSPopover.behavior` is `applicationDefined` / `transient` / `semitransient`, and the middle-and-third cases differ in _scope_, not in strength. From the `semitransient` case page [[nspopover-behavior-semitransient]]:

> The system will close the popover when the user interacts with user interface elements in the window containing the popover's positioning view.

Note the predicate: the user "interacts with user interface elements", not "presses outside". The policy is evaluated against a hit-tested target, which is why Apple never has to specify a pointer-down-versus-pointer-up-versus-click rule.

**Modality is an allow-list over hit testing, not an input grab.** From `UIPopoverPresentationController.passthroughViews` [[uipopover-passthroughviews]]:

> When a popover is active, interactions with other views are normally disabled until the popover is dismissed. Assigning an array of UIView objects to this property causes UIKit to continue dispatching touch event to the views you specified.

**Framework-observed anchors and app-pushed anchors are explicitly different things.** From `NSPopover.positioningRect` [[nspopover-positioningrect]]:

> Popovers are positioned relative to a positioning view and are automatically moved when the location or size of the positioning view changes. Sometimes it is desirable to position popovers relative to a rectangle within the positioning view. In this case, you must update the positioningRect property whenever this rectangle changes.

A view-level [anchor rect][concepts] is watched for you; a sub-region of a view is not. Any toolkit with sub-widget anchors inherits exactly that split.

The stack's weakest documented area is precisely the area a toolkit designer most needs: no published collision algorithm, no published [placement][concepts] fallback order, no published hover timings, and no interactive-hover vocabulary at all.

## How it works

The three frameworks answer the same question at three different layers, and the layer is the interesting part.

**AppKit — an object with delegate hooks.** A popover is an `NSPopover` instance you configure and show; the anchor is `(positioningView, positioningRect, preferredEdge)`.

```swift
// AppKit: anchor = view + rect-in-view + one preferred edge.
popover.behavior = .semitransient          // dismissal policy is a value
popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
```

Showing is idempotent-with-retarget rather than an error, and a dead anchor is a silent no-op — from `show(relativeTo:of:preferredEdge:)` [[nspopover-show]]: "If the popover is already being shown, this method updates the anchored view, rectangle, and preferred edge. If the positioning view is not visible, this method does nothing."

**AppKit menus — a synchronous, modal call.** `NSMenu.popUp(positioning:at:in:)` returns `Bool`, tracking inside `RunLoop.Mode.eventTracking` for the duration. Two rare anchor modes are folded into one signature [[nsmenu-popup]]:

> If item is nil, the menu is positioned such that the top left of the menu content frame is at the given location. If view is nil, the location is interpreted in the screen coordinate system. This allows you to pop up a menu disconnected from any window.

**UIKit — a presentation controller you never construct.** `UIPopoverPresentationController` is created by UIKit when a view controller is presented with `.popover`; the app configures it and the _adaptivity_ layer above it may replace the whole surface form.

```swift
// UIKit: anchor = source view + rect, or a source ITEM (bar button, toolbar item).
let pc = vc.popoverPresentationController!
pc.sourceItem = barButtonItem                  // virtual anchor: no rect until resolved
pc.permittedArrowDirections = [.up, .down]     // a permitted SET, not an ordered list
pc.popoverLayoutMargins = UIEdgeInsets(...)    // viewport padding, default 10pt/edge
pc.canOverlapSourceViewRect = false            // may the overlay cover its anchor?
pc.passthroughViews = [toolbar]                // modality with holes
```

**SwiftUI — a deferred, comparable anchor token.** `PopoverAttachmentAnchor` is `.rect(Anchor<CGRect>.Source)` or `.point(UnitPoint)`, where `Anchor<Value>` is "an opaque value derived from an anchor source and a particular view", conforming to `Equatable`, `Hashable` and `Sendable`, and resolved by subscripting a `GeometryProxy` later [[swiftui-anchor]].

**TipKit — eligibility as data, surface rented.** A `Tip` is a struct of `rules` and `options`; the presentation types are thin wrappers over the existing surfaces (`TipNSPopover` is documented as "a subclass of NSPopover that displays a popover tip"; `TipUIPopoverViewController` is presented "using UIPopoverPresentationController") [[tipkit]].

The resolution pipeline, as documented (policy inside each stage is not published):

```text
anchor description  ->  rect in a chosen coordinate space  ->  placement  ->  surface
  view+rect              via the view/window/screen chain      (private)     popover
  sourceItem             via the item's resolved frame                       sheet
  NSPoint (view|screen)  identity, or screen space                           fullScreenCover
  Anchor<CGRect>         GeometryProxy subscript                             menu / edit menu
  delegate targetRect    pulled on demand
```

> [!WARNING]
> **What documentation cannot tell you here.** The internal placement algorithm of all three frameworks is unpublished: the order in which sides are tried, whether shift-along-the-edge precedes flip, how ties break, and what tracking costs. Tooltip delay constants are unpublished. The `NSMenu` submenu-tracking heuristic is undocumented in the reference pages. `UIPopoverBackgroundViewMethods`' three members (`arrowHeight()`, `arrowBase()`, `contentViewInsets()`) are required by the class overview but their abstracts did not resolve on the pages read; `arrowOffset` and `arrowDirection` did. No Apple statement about WCAG 1.4.13, VoiceOver overlay timing, or screen-reader dismissal behaviour was found.

## The analysis spine

### 1. Anchor model

Six mutually incompatible anchor representations, and the differences are the finding.

- **`NSPopover`** — `(positioningView: NSView, positioningRect: NSRect, preferredEdge: NSRectEdge)`. An empty rect means "use the view's bounds". View movement is tracked automatically, a sub-rect is not [[nspopover-positioningrect]]. The anchor holds an object reference, so it is not a value.
- **`NSMenu.popUp(positioning:at:in:)`** — an `NSPoint` in a view's coordinates, or in _screen_ coordinates when `view` is `nil`: a true [virtual anchor][concepts]. The optional positioning `NSMenuItem` is an interior-alignment anchor — that item's top-left lands on the point, so a pop-up button opens with the selected row under the cursor [[nsmenu-popup]].
- **`NSMenu.popUpContextMenu(_:with:for:)`** — the anchor is derived from an `NSEvent`, i.e. a cursor anchor.
- **UIKit** — `sourceView` + `sourceRect`, or `sourceItem`, typed as the protocol `UIPopoverPresentationControllerSourceItem` (`UIBarButtonItem`, `NSToolbarItem`): a virtual anchor with no rect until the item resolves one. iOS 26 changes the semantics outright — "In iOS 18 and earlier, the popover's arrow points to the specified item. In iOS 26 and later, the popover animates from and replaces the specified item" [[uipopover-sourceitem]]. Anchoring became morphing.
- **`UIEditMenuInteraction`** — the anchor is a _delegate callback_, `editMenuInteraction(_:targetRectFor:)`, re-queried on `updateVisibleMenuPosition(animated:)`: a pull-model anchor for a moving text selection. It returns one `CGRect`; no multi-rect union anchor for a wrapped selection is documented [[uieditmenuinteractiondelegate]].
- **`UIContextMenuInteraction`** — trigger, anchor and preview are fully detached. The menu is configured at a touch location while the highlighted content is described by a separate `UITargetedPreview` whose `UIPreviewTarget` carries `(container, center, transform)`, and `retargetedPreview(with:)` can move it mid-flight [[uitargetedpreview]].
- **SwiftUI** — `PopoverAttachmentAnchor` over `Anchor<Value>`, an `Equatable`/`Hashable`/`Sendable` opaque token produced during layout and converted to a rect only when subscripted through a `GeometryProxy`. `anchorPreference(key:value:transform:)` propagates such tokens up the view tree as ordinary preference values [[swiftui-anchorpreference]].

**Algorithm.** Documented resolution is `anchor -> rect in a chosen coordinate space -> placement`. AppKit: `rect := positioningRect.isEmpty ? positioningView.bounds : positioningRect`, converted through the view/window/screen chain and recomputed when the positioning view's frame changes. UIKit: `rect := sourceRect in sourceView`, or the frame the `sourceItem` reports; on an interface change UIKit computes a _new_ proposed `(rect, containerView)` pair and offers both to the delegate before using them. SwiftUI: the token is deferred, so the same anchor yields different rects in different coordinate spaces without the producer knowing about the consumer.

**Where it lives.** AppKit: `NSPopover` plus `NSView` geometry, framework-side. UIKit: `UIPopoverPresentationController`, a `UIPresentationController` subclass owned by UIKit's presentation machinery, with the anchor protocol public. SwiftUI: the layout/preference system — `Anchor` is produced by the layout pass and consumed by `GeometryProxy`, i.e. it lives in the toolkit's own geometry kernel and not in a window server.

**Degradation.** SwiftUI's `Anchor` is the representation that survives every constraint in [`sparkles-baseline.md`][baseline]: a comparable, hashable value needing no OS window, no script, no hover and no sub-cell precision. `NSPopover`'s view-reference anchor does not survive, since it presumes retained objects and an object-identity coordinate chain. The two that transfer best to a cell grid are `NSMenu`'s "point, possibly screen-space, optionally aligned by an interior item" and `UIEditMenuInteraction`'s pull-model `targetRectFor` callback — both are integral and neither needs a window. UIKit's answer to a dead anchor (a silent no-op) is directly assertable on a recording canvas: the display list simply contains no overlay.

### 2. Placement model

Apple publishes the _inputs_ to placement and almost none of the policy. Side selection is expressed three different ways:

| Framework | Side input                                          | Shape                                                              |
| --------- | --------------------------------------------------- | ------------------------------------------------------------------ |
| AppKit    | `preferredEdge: NSRectEdge`                         | one physical edge (`minX`/`maxX`/`minY`/`maxY`)                    |
| UIKit     | `permittedArrowDirections: UIPopoverArrowDirection` | an `OptionSet` of `up`/`down`/`left`/`right`/`any`, default `.any` |
| SwiftUI   | `arrowEdge: Edge?`                                  | one optional edge; `nil` means "the system allowing any"           |

A permitted _set_ is not an ordered preference list: an app cannot express "prefer top, then right, then bottom". There is no fallback-ordering API anywhere in the stack. UIKit does report the outcome back as `arrowDirection` (including an `.unknown` case), so the resolved side is readable even though the policy is not [[uipopoverarrowdirection]].

Viewport padding is `popoverLayoutMargins: UIEdgeInsets`, default 10 points per edge, measured from _screen_ edges "relative to the current device orientation" — the documentation warns at length that device orientation is not interface orientation — with the status bar auto-subtracted so apps must not double-count it [[uipopover-layoutmargins]]. A custom [clipping boundary][concepts] exists only for menus: `NSMenuDelegate.confinementRect(for:on:)` returns a screen-coordinate rect _per `NSScreen`_, so multi-monitor is a first-class parameter, and it is explicitly advisory [[nsmenu-confinementrect]]:

> If you return NSZeroRect, or if the delegate doesn't implement this method, the menu will be confined to the bounds appropriate for the given screen. The returned rect may not be honored in all cases, for example, if it would force the menu to be too small.

Overlap policy is one boolean: `canOverlapSourceViewRect`, default `false`, meaning the overlay is pushed rather than allowed to cover its own anchor unless the app opts in "when space is constrained" [[uipopover-canoverlap]]. Soft-keyboard avoidance is a documented reposition trigger rather than a discovered inset [[uipopover-willreposition]]:

> The popover presentation controller calls this method in response to interface changes that require a new size for the popover. For example, UIKit calls this method when the popover must be resized to make room for the keyboard. You can use this method to obtain the new size of the popover and optionally to make changes to the proposed view and rectangle.

Directional vocabulary is physical throughout (`minX`/`maxX`, left/right), so RTL mirroring is left to the app even though `NSMenu` carries a `userInterfaceLayoutDirection`.

**Algorithm.** Documented behaviour only: propose a placement from the anchor rect and the permitted sides; constrain to screen bounds minus `popoverLayoutMargins` minus the status bar, or to `confinementRect` for menus; if the result would cover the anchor and `canOverlapSourceViewRect` is `false`, prefer another arrangement rather than overlap; on an interface change recompute `(rect, containerView)` and offer both to the delegate before committing; if the constraint would make the surface unusably small, discard the constraint (menus only). The order in which sides are tried, and whether [slide][concepts] precedes [flip][concepts], is not published for any of the three frameworks.

**Where it lives.** UIKit: inside `UIPopoverPresentationController`, with three declarative seams (`permittedArrowDirections`, `popoverLayoutMargins`, `canOverlapSourceViewRect`) and one imperative override (`willRepositionPopoverTo:in:`). AppKit menus: menu tracking, with `confinementRect` as the only seam, evaluated per screen. AppKit popovers: no placement seam at all beyond `preferredEdge`. SwiftUI: a pass-through to the platform presentation — `arrowEdge` was not even wired up on iOS until 18.1 (see Weaknesses).

**Degradation.** Everything Apple exposes here is integral: a permitted-side set, an insets rectangle, an overlap boolean and a boundary rect are all whole-cell values on a grid, and none of them needs sub-cell precision. The keyboard case is the transferable one — Apple treats it as a _reposition event carrying a new rect_, which is the shape an Android soft-keyboard inset wants (a placement input, not a discovery). With no script, none of this can run at emit time, so the honest static-HTML degradation is to bake one side and accept clipping; Apple's own five years of an ignored `arrowEdge` is evidence that a preferred side quietly not being honoured is survivable. Multi-monitor and work areas have no cell-grid analogue: the surface _is_ the work area.

### 3. Collision and geometry engine

The engine is closed. Apple publishes no algorithm, no cost, and no tracking strategy. What the documentation does establish is the _contract_:

1. Tracking is automatic for view-level anchors — the `NSPopover` overview states the system "moves the popover whenever its positioning view moves" — and manual for sub-rect anchors [[nspopover]].
2. UIKit exposes no observer at all, only a single reposition callback fired on "interface changes that require a new size", naming rotation and the keyboard as examples. The app therefore sees discrete reposition events, never a continuous tracking loop.
3. AppKit has a documented clipping-ancestor concept, but only for _hover_: `NSTrackingArea.Options.inVisibleRect` means tracking occurs "only in the visible rectangle of the view — in other words, that region of the tracking rectangle that is unobscured", and the area is "automatically synchronized with changes in the view's visible area" [[nstrackingarea]]. That is clip discovery offered as a framework service. It is _an inference_, not an observation, that the same machinery backs popover placement; nothing published says so.
4. Anchor-resize and overlay-resize go down the same reposition path, since the trigger is described as "interface changes that require a new size".
5. Menu sizing is exposed: `NSMenu.size` and `NSMenu.minimumWidth` "in screen coordinates", and `update()` "sizes the menu to fit its current menu items if necessary" — measurement is an explicit, callable pass rather than a hidden one [[nsmenu]].
6. Nothing in the documentation read mentions transforms, zoom, device pixel ratio, or fractional-pixel placement for popovers.

**Algorithm.** Not published. The observable contract is: an anchor-moved or interface-changed signal triggers a recompute, which proposes `(rect, container)`, which the delegate may rewrite, which is then committed. `NSMenu.update()` shows Apple separating "refresh content and remeasure" from "place".

**Where it lives.** The framework kernel — AppKit's view geometry and menu tracking, UIKit's presentation controller. `NSTrackingArea` is notable for putting clip discovery in the _view_ layer and handing clients a synchronized rect rather than a query API.

**Degradation.** What generalizes off the native substrate is the shape of the contract, not the arithmetic: recompute on a discrete signal rather than by polling (in an immediate-mode toolkit that signal is "a new frame was laid out", which is free); offer the recomputed geometry to the owner before committing it, so that `(proposedRect, anchorRect) -> finalRect` stays a pure function that a recording canvas can assert; and treat measurement as an explicit pass, as `NSMenu.update()` does. With integer cells and one surface, collision reduces to clamping against the surface rect minus a viewport-padding inset — which loses nothing Apple documents, because Apple documents no more than that. Clip-ancestor discovery has an analogue (the overlay must escape a scroll pane) but with no [top layer][concepts] the escape is "paint later in the display list", not "reparent"; see [`../../specs/ui/containers.md`][spec-containers].

### 4. Arrow / caret geometry

UIKit treats arrow geometry as data and hands it to the app; AppKit hides it completely. The UIKit model has three parts: `permittedArrowDirections` as input; `arrowDirection` as readable output, with an explicit `.unknown` case; and a chrome contract in which `popoverBackgroundViewClass` takes a `UIPopoverBackgroundView` subclass onto which UIKit _pushes_ `arrowOffset` and `arrowDirection`, with the values changing while the popover is on screen so the setters must call `setNeedsLayout()` [[uipopoverbackgroundview]]. The offset itself [[uipopoverbackgroundview-arrowoffset]]:

> Offsets are always specified relative to the center of your view object. Adding the offset value to the center value of the given axis yields the required location for the arrow. Thus, for an arrow pointing up or down, a negative offset moves the arrow toward the left edge of the view.

That reduces the entire corner-constraint problem to one signed scalar plus a side, recomputed live as the overlay shifts. Apple also forbids the chrome from drawing its own shadow ("The popover controller adds a shadow to the popover for you") and requires stretchable images so that resize animates smoothly. `NSPopover`, by contrast, exposes no arrow API whatsoever — no size, no offset, no hide, no direction readback; the arrow is a pure consequence of `preferredEdge`. SwiftUI exposes only `arrowEdge: Edge?`. Detachment removes the arrow implicitly, because a detached popover becomes a window.

**Algorithm.** `arrow := (side: resolvedDirection, offset: signedScalar)`; the arrow's position along the edge is the edge centre plus the offset, clamped by the framework so it stays inside the chrome's corner radius. The chrome subclass converts `(side, offset)` into its own layout and supplies arrow height, arrow base and content insets _back_ to UIKit through `UIPopoverBackgroundViewMethods`, so arrow size feeds the content inset rather than being derived from it.

**Where it lives.** The UIKit framework computes it; the app-supplied `UIPopoverBackgroundView` subclass consumes it. Deliberately two-way: framework gives `(direction, offset)`, chrome gives `(arrow height, arrow base, content insets)`. AppKit keeps both halves private.

**Degradation.** On a cell grid an arrow is one character in one cell — `▲ ▼ ◀ ▶`, or a `┬`/`┴`/`├`/`┤` tee spliced into the border run — and Apple's representation survives exactly: `(side, signed offset in cells from the edge midpoint)` is an integer pair, clamped so the arrow never lands on a corner cell. The "arrow height feeds the content inset" rule collapses to nothing on a grid, because the arrow lives _in_ the border row and costs zero extra rows; that is a simplification rather than a loss. With no sub-cell precision the offset quantizes and the arrow may be up to half a cell off the true anchor centre, which is the same class of error Apple's own corner clamping already accepts. With no script, the side must be baked at emit time. One case Apple does not model at all and a cell toolkit should: `side == none`, for a clamped overlay whose arrow would otherwise leave the box.

### 5. Trigger semantics

Apple's rule is that the _primitive_ owns the gesture and the _app_ owns the intent. `UIContextMenuInteraction` "tracks Force Touch gestures on devices that support 3D Touch, and long-press gestures on devices that don't support it" — capability-selected and undeclarable [[uicontextmenuinteraction]]. `UIEditMenuInteraction` goes further and lets the input method choose the _presentation_: "For touch interactions, the actions display in an editing menu. When responding to a secondary click on devices with pointer-based input, the actions display in a context menu" [[uieditmenuinteraction]]. Pointer-type distinction is internal to the primitive, not an app-visible branch.

Hover triggers are separate primitives. `NSView.toolTip` covers a whole view; `addToolTip(_:owner:userData:)` registers a sub-rect with a lazy owner-supplied string and returns a `ToolTipTag`, so one view can carry many trigger rects sharing one surface [[nsview-tooltip]]. Both sit on `NSTrackingArea`, whose `Options` encode activation scope as a four-way choice (`activeWhenFirstResponder`, `activeInKeyWindow`, `activeInActiveApp`, `activeAlways`) plus `enabledDuringMouseDrag` [[nstrackingarea]]. `UIToolTipInteraction` is hover-only, and its documented touch behaviour is to not exist [[uitooltipinteraction]]:

> Tooltips appear when your app runs in macOS or visionOS. To show a tooltip in macOS, your app must be an iPhone or iPad app running on a Mac with Apple silicon, or built with Mac Catalyst.

`NSPopover.show(...)` and `NSMenu.popUp(...)` have no built-in trigger at all: they are pure imperative presentations. Assistive-technology-initiated display is not documented for any of them.

How multiple triggers avoid racing differs by framework. AppKit's answer is a **modal event loop**: `popUp(positioning:at:in:)` is synchronous and returns `true` "if menu tracking ended because an item was selected, and `false` if menu tracking was cancelled for any reason", with `RunLoop.Mode.eventTracking` documented as "the mode set when tracking events modally, such as a mouse-dragging loop" [[runloop-eventtracking]]. While a menu tracks, a second trigger cannot fire. UIKit's answer is different — interactions attach to views via `addInteraction(_:)` and arbitration happens in the gesture-recognizer system, which is not documented at the popover level.

**Algorithm.** `gesture := f(deviceCapability, inputMethod)` inside the primitive; `presentation := g(inputMethod)` for edit menus; hover is `NSTrackingArea` enter/exit/moved events scoped by an activation predicate. Race avoidance is structural on AppKit (a blocking call with a `Bool` result) and undocumented on UIKit.

**Where it lives.** AppKit: menu tracking plus the Foundation run loop. `NSTrackingArea` belongs to the _view_, not the window, "so you can add and remove tracking rectangles without needing to worry if the view has been added to a window". UIKit: `UIInteraction` objects attached to views, over the gesture layer.

**Degradation.** The blocking-call model — "was an item chosen?" as the return value — is the most portable race answer here: a menu run becomes a function that owns the event stream until it yields a selection, which a recording canvas can drive with a scripted event list. On a terminal, keyboard press-and-hold is unavailable (there is no key-release capability), so any trigger that needs a held _key_ is gone; pointer press and release are distinct capabilities that the terminal does serve over SGR-1006, so a pointer long-press is not blocked by the same limit — see [`../../specs/ui/input.md`][spec-input] and [`sparkles-baseline.md`][baseline]. With no hover (Android) every hover trigger must be reclassified, and Apple's documented answer is to show nothing rather than to invent a long-press tooltip. With no script, only `:hover`, `:focus-within`, `:checked` and `<details>` remain, which maps onto Apple's tooltip, focus ring and disclosure. The `NSTrackingArea` pattern of many sub-rect triggers over one surface, with content supplied lazily by owner and tag, is directly implementable as `rectId -> contentProvider` over a flat hit list.

### 6. Timing

For tooltips and menus, Apple publishes no timing at all: no initial delay, no close delay, no [warm-up][concepts] window, no "instant subsequent tooltip" rule, no maximum display duration. `NSView.toolTip`'s entire documented semantics are that assigning a value causes the tooltip to be displayed for the view. The delay exists and is unspecified. That absence is itself a finding: the most imitated hover behaviour in desktop UI is undocumented by the vendor that popularized it.

TipKit is the exception, and it publishes a complete model — for teaching tips only. `Tips.configure([.displayFrequency(...)])` sets a **global cooldown** shared by all tips (`immediate` (default), `hourly`, `daily`, `weekly`, `monthly`); if a tip is displayed under `.daily`, "no new tips will be shown for at least 24 hours". Two refinements make it a state machine rather than a timer: "Display frequency only applies to tips that have not appeared. Previously displayed tips will still appear if their display rules are satisfied" — the cooldown gates _first_ appearances only — and a per-tip `IgnoresDisplayFrequency` opt-out [[tipkit-displayfrequency]]. Per-tip limits are `MaxDisplayCount` and `MaxDisplayDuration`, the latter cumulative across launches with an explicit anti-flicker floor [[tipkit-maxdisplayduration]]:

> This is a cumulative value; if a tip specifies a 2 minute maximum display duration and is displayed for 1 minute on Monday and 1 minute on Tuesday it will be automatically invalidated and no longer appear. Tip views have a minimum display duration of 60 seconds before they can be automatically invalidated by MaxDisplayDuration in order to avoid appearing and disappearing too quickly.

`TipGroup` is the shared-provider case: a set of tips presented one at a time, with priority `.firstAvailable` (default) or `.ordered` [[tipkit-tipgroup]]. Event donations are bounded — "by default events only query their most recent 1000 donations" [[tipkit-event]].

**Algorithm.** The state machine TipKit implies is `Ineligible -> Eligible -> Displaying -> Dismissed -> Invalidated(reason)`, with transitions pure over rules evaluated against parameters and a bounded event log, a global cooldown clock, per-tip counters and per-tip cumulative display time — everything persisted. Two clocks, not one: a _group_ clock gating first appearances and a _per-surface_ clock enforcing cumulative duration with a minimum-visible floor. For hover tooltips the corresponding machine is not published anywhere in the stack.

**Where it lives.** TipKit: an eligibility engine backed by a persistent datastore (`Tips.ConfigurationOption.datastoreLocation`, plus an optional `cloudKitContainer` for cross-device sync) — timing state is durable and syncable, entirely outside the view layer. Tooltip and menu timing: framework internals, unpublished.

**Degradation.** With no timers (static HTML) all of this is gone; the honest tier-0 form is a CSS `transition-delay`, which is a delay but not a state machine, and TipKit-style eligibility must be resolved at emit time into "render the tip or don't". Timing is fully assertable headlessly _if_ the clock is an injected value rather than a wall clock — which is exactly how TipKit is shaped, since its rules read stored counters and timestamps rather than live timers. The 60-second anti-flicker floor generalizes to any target: never let a computed policy remove a surface faster than a human can read it. The 1000-donation cap is the right shape for an allocation-conscious toolkit — an eligibility log should be a bounded ring buffer, not an unbounded history.

### 7. Interactive hover (safe polygon / menu-aim)

**Not applicable as documented, and the absence is the finding.** No [safe polygon][concepts], pointer-bridge, diagonal-intent, menu-aim, trajectory, interactive-border or debounce vocabulary appears on any AppKit, UIKit or SwiftUI reference page read for this entry. AppKit's submenu tracking is widely observed to tolerate diagonal travel toward a submenu — the classic "sloppy" triangle — but that behaviour is not described in the reference documentation, so it is recorded here as unverified rather than as a mechanism.

Structurally, Apple can afford the silence: menu tracking runs inside the framework's modal event loop, so the app never sees the intermediate mouse-moved events, and there is no app-visible surface for the heuristic to be exposed through. The only related documented facts are two. First, `NSTrackingArea` gives raw enter/exit/moved with an activation scope and an explicit hazard flag for the ambiguous initial-position case [[nstrackingarea-assumeinside]]:

> The first event is generated when the cursor leaves the tracking area, regardless if the cursor is inside the area when the NSTrackingArea is added to a view. […] Generally, you do not want to request this behavior.

Second, trigger-to-content travel is a non-problem for `NSPopover` precisely because a `transient` popover closes on interaction _outside_ the popover, not on pointer exit — hover is not its dismissal signal at all.

**Algorithm.** None is published. The nearest documented primitive is `NSTrackingArea`'s enter/exit bookkeeping, whose stated edge case is what to do when a tracking area is installed under an already-present cursor.

**Where it lives.** Inside AppKit's menu tracking loop, unpublished. Nothing at the app-visible layer.

**Degradation.** Because Apple specifies nothing here, a cell-grid toolkit has to specify it itself; what follows is _this page's suggestion_, not a reading of Apple. A whole-cell corridor between the trigger and the overlay, plus a grace counter measured in frames rather than milliseconds (a terminal has no reliable sub-frame clock), is the cheapest shape that fits an integer grid and one pointer. Whether a rectangular corridor is behaviourally equivalent to a polygonal one at cell resolution is a question this page cannot answer from Apple's documentation, and is argued in [`concepts.md`][concepts] and [`comparison.md`][comparison] against subjects that publish their geometry. Two hard target constraints frame the budget regardless: bare-motion pointer reporting is not on by default on a terminal, so hover intent must be a declared capability rather than an assumed one, and on Android there is no hover to have intent about. On static HTML, pure-CSS hover bridging requires the overlay to be a DOM descendant of the trigger with no gap, which is a real constraint on the placement layer (a zero-cell offset, or a transparent bridge row).

### 8. Dismissal

`NSPopover.behavior` is the headline: an entire dismissal policy collapsed into one enum value stored on the surface, defaulting to `applicationDefined` [[nspopover-behavior]].

| Case                 | Documented meaning                                                                                                         |
| -------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| `applicationDefined` | "Your application assumes responsibility for closing the popover" — no automatic dismissal                                 |
| `transient`          | the system closes it "when the user interacts with a user interface element outside the popover"                           |
| `semitransient`      | the system closes it on interaction "with user interface elements in the window containing the popover's positioning view" |

The trigger word in both automatic cases is "interacts with a user interface element", not "presses outside": the policy is expressed against hit-tested targets, not raw event phases. Two close paths carry different authority — `close()` "forces the popover to close without consulting its delegate", while `performClose(_:)` "attempts to close" and runs `popoverShouldClose(_:)`, which "allows a delegate to override a close request" [[nspopoverdelegate]]. The reason is carried as data in the `willCloseNotification` user info: `NSPopover.CloseReason` is `.standard` or `.detachToWindow`, so "closing because I am becoming a window" is distinguishable from a real dismissal [[nspopover-closereason]].

Menus dismiss via `cancelTracking()` and `cancelTrackingWithoutAnimation()` — the latter existing precisely for the "dismiss without the exit animation" case — and `popUp` returns `false` when tracking "was cancelled for any reason". UIKit _removed_ the veto: `popoverPresentationControllerShouldDismissPopover(_:)` and its did-dismiss counterpart are both deprecated [[uipopoverdelegate]]. `UIContextMenuInteraction.dismissMenu()` and `UIEditMenuInteraction.dismissMenu()` are the imperative paths. The HIG treats unintended dismissal as expected and demands robustness: "Always save changes when a nonmodal popover closes unintentionally", and "Allow single-gesture switching" — closing one popover and opening another must cost one gesture, not two [[hig-popovers]].

**Algorithm.** The policy is an enum on the surface; on each user interaction the framework classifies the interaction's target as inside-popover, inside-anchor-window, or elsewhere, and compares against the policy; if it dismisses, the veto hook runs (AppKit only), then `willClose` posts with a reason, the surface animates out, and `didClose` posts. Detachment is modelled as a close-with-reason followed by a window appearing, not as a mode change on the same object.

**Where it lives.** The AppKit framework, with two app seams — the `behavior` value and the should-close delegate. On UIKit it lives in the presentation controller, with the veto seam deliberately deprecated away and dismissal authority moved up to `UIAdaptivePresentationControllerDelegate` and the presented controller's own modal-in-presentation flag.

**Degradation.** This dimension is pure policy over already-routed events, so it survives every substrate here essentially unchanged. A dismissal policy value with a _containment scope_ (`manual`, `light dismiss`, `light dismiss within node N`) is a plain comparable value, and classification is "which node did the last event hit, and is it a descendant of the overlay or of the anchor's scope?" — answerable from a flat hit list with no OS involvement. The AppKit split between `close()` and `performClose(_:)` is worth copying verbatim. Reason-tagged closes are what make a headless target useful: assert not only that the overlay disappeared but _why_. On Android the system back key is another reason; on a terminal, Escape is. Two dismissal causes are genuinely undetectable on a terminal backend as it stands — surface blur (window or app deactivation) and the pointer leaving the terminal window entirely — so a policy naming them must degrade; hover-exit _between targets inside the grid_ remains detectable under mouse-motion reporting.

### 9. Focus

Apple documents focus for menus and for accessibility modality, and barely at all for popovers. The tooltip / popover / menu / dialog distinction is maintained where it matters most — the accessibility role vocabulary. `NSAccessibility.Role` contains separate roles for `.helpTag`, `.popover`, `.menu`, `.menuItem`, `.menuBar`, `.menuButton`, `.sheet` and `.window`: a tooltip is never modelled as a small popover [[nsaccessibility-role]].

Menus own keyboard focus by construction: tracking is a modal run-loop mode, `highlightedItem` is exposed as state, `menu(_:willHighlight:)` fires as the user navigates (with an explicit `nil` case for "highlight nothing"), and `performKeyEquivalent(with:)` plus `menuHasKeyEquivalent(_:for:target:action:)` route keystrokes into the menu [[nsmenudelegate]]. Popover focus policy is not documented at all — nothing states whether a popover's content becomes first responder, whether focus is trapped or merely contained, or what happens to focus on dismissal. Modality for assistive technology is a separate explicit bit (`accessibilityViewIsModal` in UIKit, `AccessibilityTraits.isModal` in SwiftUI) rather than a consequence of visual modality [[swiftui-ismodal]]. Tooltips are non-interactive _by typing_: `NSView.toolTip` and `UIToolTipInteraction` take a `String`, never a view, so there is no API by which tooltip content could contain a control.

**Algorithm.** Menus: a modal tracking loop owns the keyboard, and highlight is a single-selection cursor over items with a will-highlight notification. Popovers: not documented. Accessibility modality: a boolean on a container view that hides sibling subtrees from the accessibility tree.

**Where it lives.** Menus: menu tracking plus the responder chain. Accessibility modality: the accessibility layer, deliberately separate from the input layer, so an app can be visually non-modal and AT-modal or the reverse.

**Degradation.** The structural rule transfers cheaply and exactly: _tooltip content is a string, not a tree_. Typing tooltip content as text and popover content as a widget tree answers "can a tooltip be interactive" in the type system on every target, including static HTML where a hover surface can never be reached by keyboard. Menus keeping keyboard focus works on a terminal, since highlight moves on key _press_ and no key release is needed; the modal-tracking framing means a menu can own the key stream until it returns, which a recording canvas can drive. Popover focus is where a toolkit must go beyond Apple: with no OS window and no pointer grab, containment has to be implemented in the toolkit's own [focus scope][concepts] — and there is no toolkit-owned focus order to splice into today (see [`sparkles-baseline.md`][baseline] and [`../../specs/ui/state-machines.md`][spec-machines]). The accessibility modal bit has no honest terminal analogue and belongs in metadata (dimension 13).

### 10. Layering and portals

AppKit's overlays are OS surfaces and Apple exposes that fact as public API. A popover can be **promoted into a window**: `popoverShouldDetach(_:)` authorizes it, `detachableWindow(for:)` lets the app return _its own_ `NSWindow` to become the detached surface, `isDetached` reports whether the window created by detachment was automatically created (and its discussion notes the property "does not apply when detaching a popover results in a window returned by `detachableWindow(for:)`"), and `popoverDidDetach(_:)` fires when a popover has been released while implicitly detached [[nspopoverdelegate], [nspopover-isdetached]]. The close notification then carries `CloseReason.detachToWindow`. The popover-to-window transition is therefore a documented, app-overridable, reason-tagged state change.

`NSMenu` goes the other way: popping up with `view == nil` interprets the location in screen coordinates, giving "a menu disconnected from any window" — a surface with no owning window at all. UIKit hides the surface entirely: `UIPopoverPresentationController` is a presentation controller and the app never touches a window; the only exposed piece is chrome (`popoverBackgroundViewClass`, `backgroundColor`). `UIContextMenuInteraction` exposes nothing — "UIKit manages all menu-related interactions and reports the selected action, if any, back to your app".

Ownership _trees_ appear in exactly one place: `NSMenu.supermenu`, `setSubmenu(_:for:)`, and `isTornOff` ("whether the menu is offscreen or attached to another menu"). The HIG forbids overlay stacking outright: "Never display multiple popovers or cascading hierarchies", "Nothing should display over a popover except alerts" [[hig-popovers]], and for menus, "restrict them to a single level" of submenu [[hig-menus]].

**Algorithm.** Detachment: on drag, ask the delegate whether to detach; if so, either auto-create a window or adopt the delegate-returned `NSWindow`; post `willClose` with reason `.detachToWindow`; the content view controller migrates. Menus: a submenu tree with `supermenu` back-pointers, where a torn-off menu is one whose attachment to its supermenu has been severed.

**Where it lives.** AppKit: the window server, deliberately surfaced to the app. UIKit: the presentation-controller layer, deliberately hidden. The public-versus-private split is therefore a per-framework _policy_ choice rather than a technical necessity — the same capability is API on one platform and invisible on the other.

**Degradation.** With no top layer, no compositor and no z-index, the AppKit half is unavailable and the UIKit half is the model: the surface is an implementation detail, the app declares content and anchoring only, and "front" means "later in the display list". Two things still transfer. First, the **overlay tree with parent/child ownership** (`NSMenu.supermenu`) is needed regardless of substrate — closing a parent must close its children, and a child opening must not dismiss its parent — and it is a pure data structure. Second, detach-to-window has an honest degraded form: promote the overlay into a docked pane inside the same surface, same content, different placement policy, reason-tagged transition. On static HTML there are no layers at all and the overlay is a positioned descendant of its trigger, where the HIG's "never cascade popovers" reads as a hard constraint rather than a guideline.

### 11. Modality

Apple models modality on **three independent axes**, and keeping them independent is the lesson.

1. **Input blocking with an allow-list.** `passthroughViews` names background views that keep receiving touches while an otherwise-blocking popover is up [[uipopover-passthroughviews]]. Note the default: a UIKit popover _is_ input-modal, and non-modality is granted per view. That is what a toolbar-anchored inspector needs — keep the toolbar live, block the canvas.
2. **Modality as a property of the chosen appearance.** `UIContextMenuInteraction.appearance` is readable and its cases are `.rich` ("A modal menu with an optional preview"), `.compact` ("A nonmodal, compact menu with no preview") and `.unknown` ("No menu appearance") [[uicontextmenu-appearance]]. The system chooses the appearance from context; modality follows, and the app can read which it got.
3. **Dismissal scope as a third axis.** `semitransient` bounds light dismiss to the anchor's window while leaving the rest of the app live.

Nothing in the popover documentation mentions a scrim or a dimming layer: `UIPopoverPresentationController.backgroundColor` is the colour of the popover's own backdrop view, not a page-covering scrim. The accessibility modal bit is a fourth, orthogonal switch.

**Algorithm.** On hit test: if the popover is presented and the hit view is neither a descendant of the popover nor a member of `passthroughViews`, swallow the event (and, per policy, dismiss). Keyboard blocking is not documented separately — `passthroughViews` speaks only of touch events. For AppKit menus, modality is total for the duration of tracking because the run loop is in event-tracking mode.

**Where it lives.** UIKit implements the block as a view participating in hit testing, i.e. modality is a hit-test filter _in library code_, not an OS input grab. AppKit menus use the run loop. Accessibility modality lives in the accessibility tree, separately from both.

**Degradation.** This is the best-fitting dimension in the subject for a toolkit that owns its own hit testing, precisely because Apple implements it as a filter rather than as a grab: after the overlay's entry in a reverse-paint-order walk, stop, except for node ids in an explicit passthrough set. That is O(1) extra state, needs no OS window and no pointer grab, and is assertable headlessly — feed a click at a background cell and assert whether it was swallowed or delivered. A hit-test filter is the form that survives the absence of a native pointer grab; whether anything is _lost_ relative to a grab is argued in [`comparison.md`][comparison] against subjects that have one. The scrim is optional and must degrade on cell backends, where filling a rect blends the cell background but leaves glyph foregrounds untouched, so a dimming pass needs an explicit foreground treatment for parity. On static HTML, modality is unenforceable and should degrade to non-modal, documented as such.

### 12. Adaptive presentation

This is the subject's signature contribution, and Apple is unusually explicit about _which layer owns the decision_: the adaptivity layer of the presentation system — neither the popover nor the app. `UIPopoverPresentationControllerDelegate` inherits from `UIAdaptivePresentationControllerDelegate`, and `UIPopoverPresentationController` carries `adaptiveSheetPresentationController`, "the sheet presentation controller the popover adapts to in compact size classes", as an always-present property you configure in advance — the sheet counterpart exists whether or not adaptation happens [[uipopover-adaptivesheet]].

In SwiftUI the rule is stated with two different targets [[swiftui-popover]]:

> On iPhone, popovers adapt into sheets. In vertically compact environments, such as iPhone in landscape orientation, a popover presentation automatically adapts to appear as a full-screen cover. Use the presentationCompactAdaptation(\_:) or presentationCompactAdaptation(horizontal:vertical:) modifier to override this behavior.

The opt-out is `PresentationAdaptation` — `automatic`, `none`, `popover`, `sheet`, `fullScreenCover` — where `none` is documented as "Don't adapt for the size class, if possible" (note the hedge), with a per-axis variant. Crucially the modifier is applied **inside the presented content**, so the preference travels through the environment with the content rather than being an argument at the call site [[swiftui-presentationcompactadaptation]]. The HIG reinforces it from the design side: "Avoid displaying popovers in compact views… for compact views, present information in full-screen modal views (sheets) instead" [[hig-popovers]].

Hover-to-touch adaptation, by contrast, is documented _not_ to exist. `UIToolTipInteraction` simply does not display on touch platforms, and SwiftUI's `.help(_:)` "configures the view's accessibility hint and its help tag (also called a tooltip) in macOS or visionOS" — the touch degradation of a tooltip is an accessibility hint, not a long press [[swiftui-help]]. Teaching tips are the separate answer for touch discovery (dimension 16). Keyboard-driven relocation is a reposition, not an adaptation (dimension 2).

**Algorithm.** `adaptation := f(horizontalSizeClass, verticalSizeClass, appPreferenceFromEnvironment)`, with the documented default mapping for a popover being regular → popover, horizontally compact → sheet, vertically compact → full-screen cover. The preference is read from the environment of the _presented content_, so the same content adapts identically wherever it is presented from. On resolution a different presentation controller drives the surface; the content is unchanged.

**Where it lives.** UIKit: `UIAdaptivePresentationControllerDelegate` plus the presentation-controller hierarchy, a framework layer _above_ any individual overlay type. SwiftUI: the environment, written by a modifier on the content and read by the presentation machinery.

**Degradation.** The layering answer is the transferable part: the overlay primitive should not decide its own surface form. A host-level policy mapping `(requestedForm, surfaceSize, targetCapabilities) -> actualForm` handles an 80×24 terminal where a 40-cell-wide popover cannot be anchored and must become a centred panel, an Android surface whose usable viewport halves when the soft keyboard opens (the vertically-compact case exactly), and a static HTML emit with no measurement at all, where adaptation must be resolved at build time from a declared surface size. Apple's hover-to-touch _non_-adaptation is equally a directive: do not invent a long-press tooltip for a touch target — degrade the content to a description attached to the widget (dimension 13) and use an explicit teaching-tip surface when discovery matters. Long press in particular is not a free slot: on an Android target it may already be spent on text selection.

### 13. Accessibility

Apple's assistive-technology vocabulary keeps every overlay kind distinct — `.helpTag`, `.popover`, `.menu`, `.menuItem`, `.menuBar`, `.menuButton`, `.sheet` and `.window` are separate roles — so a tooltip is never a small popover in the accessibility tree [[nsaccessibility-role]]. Modality is a dedicated orthogonal bit set by the app independently of visual modality.

The clearest primitive-level binding is SwiftUI's `.help(_:)`: one call "configures the view's accessibility hint and its help tag (also called a tooltip) in macOS or visionOS" [[swiftui-help]]. The same string is the hover affordance _and_ the accessible description, so the two cannot drift, and on platforms with no hover only the accessible half remains. Typing tooltip content as `String` rather than a view makes "may tooltip content be interactive" answerable as _never_.

The HIG constrains tooltip content hard: "Limit content to 60–75 characters maximum; use sentence fragments and omit articles", "Explain the action the control initiates. Begin with a verb", "Avoid repeating the control's name" [[hig-offering-help]]. For context menus it states discoverability as a requirement — context menus are hidden by default, "so people might not know it's there", and therefore "Always make context menu items available in the main interface too" [[hig-context-menus]].

> [!NOTE]
> No Apple statement about WCAG 1.4.13 (hoverable / dismissible / persistent), VoiceOver tooltip timing, or screen-reader-specific overlay timing was found on the pages read. The WCAG side of this dimension is covered by [`aria-apg.md`][aria-apg], not here.

**Algorithm.** Less an algorithm than a typing discipline: `(content: String)` plus `(role: one of a closed set)` plus `(isModal: Bool)` attached to the surface, with the role driving the shape of the accessibility tree and the modal bit pruning sibling subtrees from it.

**Where it lives.** The accessibility layer (`NSAccessibility` / `UIAccessibility`), separate from the input and layout layers. SwiftUI's `.help` is the one place the binding is made in the widget layer, which is why it cannot drift.

**Degradation.** What belongs to the _primitive_: the role tag, the modal bit, and the guarantee that a hover-only surface's content is also reachable as a non-hover description. What belongs to a semantic component instead: menu-item semantics, listbox/combobox active-descendant relationships, dialog labelling. What a terminal cell grid can honestly expose is essentially nothing structural — there is no accessibility tree behind a grid, so a terminal overlay is, to a screen reader, whatever characters the terminal emits. The honest posture is therefore threefold: never make information tooltip-only, enforced by keeping tooltip content a plain string that is also attached to the widget as a description; emit the role and modal bit into the display list as metadata so an HTML backend can render real ARIA and a recording canvas can assert them even though a terminal drops them; and adopt the HIG's 60–75 character cap as a hard budget, because on a 40-cell-wide surface a 200-character tooltip is unrenderable anyway. Apple's "duplicate every context-menu action in the main interface" rule deserves to be a documented requirement of any context-menu component, since on a target with no hover and on a target with no script the context menu may be entirely unreachable.

### 14. Animation

Apple emits geometry metadata specifically so that animation can be placement-aware, and emits it as values.

- **Transform origin from the arrow.** `UIPopoverBackgroundView` receives `arrowDirection` and `arrowOffset`, both of which "can change while your popover is on the screen", so the chrome re-lays-out as the popover shifts; `arrowDirection` is also readable from the presentation controller after presentation, giving the app the resolved side for its own animation [[uipopoverbackgroundview]].
- **The context-menu preview is an explicit geometry value type.** `UITargetedPreview` bundles the view, `UIPreviewParameters{visiblePath, shadowPath, backgroundColor}` and `UIPreviewTarget{container, center, transform}` — a complete description of what morphs, from where, clipped to what shape — and `retargetedPreview(with:)` produces the same preview against a different container, so the morph target is retargetable mid-interaction. Highlight and dismissal previews are requested by _separate_ delegate callbacks, so enter and exit geometry are independently specified [[uitargetedpreview], [uicontextmenudelegate]].
- **Animator protocols** let the app add work to the system transition (`UIContextMenuInteractionAnimating`, `UIContextMenuInteractionCommitAnimating`, `UIEditMenuInteractionAnimating`).
- **The chrome contract encodes an animation constraint into the drawing model.** Popover backgrounds must be built from stretchable resizable images, because "the popover is animated into place (and may require animated transitions), using images is the only way to ensure that the animations are smooth and not jittery"; the chrome must not draw its own shadow, since the framework adds one.
- **AppKit's entire animation API is one boolean**, `NSPopover.animates`.
- **Reduced motion is an environment value**, `accessibilityReduceMotion`: "If this property's value is true, UI should avoid large animations, especially those that simulate the third dimension" [[swiftui-reducemotion]].

**Algorithm.** Reposition during animation is data-driven: the framework keeps pushing new `(arrowDirection, arrowOffset)` onto the chrome while it is on screen and the chrome responds with `setNeedsLayout()`, so layout is re-driven mid-animation rather than the animation being cancelled and restarted. The preview morph interpolates the source view's snapshot, clipped to `visiblePath`, from its live position to the target's centre within the target's container under the target's transform.

**Where it lives.** The UIKit framework drives; app-supplied chrome and animator blocks participate. The metadata is genuinely public API rather than an internal detail, which is what makes it usable evidence.

**Degradation.** The transferable core is the _metadata_, not the motion: an anchored overlay should publish `(resolvedSide, arrowOffsetInCells, anchorRect, overlayRect)` into the display list, because that quadruple is what any animation layer — and every headless assertion — actually needs. On a terminal there is no enter/exit animation worth having (no shadow, no radius, repainting a box is instant), so the metadata's value there is purely assertional; on an immediate-mode GPU backend the same quadruple drives a scale-from-anchor-corner transform for free; on static HTML the resolved side can be baked into a CSS class so that a [transform origin][concepts] is correct with no script. Reduced motion cannot be discovered uniformly across such targets and must be a theme or host input, matching Apple's environment-value placement — with static HTML the one exception, since an emitter can emit both branches under a `prefers-reduced-motion` media query and let the viewer's CSS engine choose.

### 15. State architecture

Three architectures live side by side, and their portability differs sharply.

**`NSPopover` — imperative object plus delegate plus notifications.** State is a handful of properties (`isShown`, `isDetached`, `behavior`, `contentSize`, `positioningRect`); lifecycle is four notifications (will-show, did-show, will-close, did-close) with a reason in the user info; the only decision hooks are boolean delegate returns plus one object-returning hook. No state machine, no reducer. Openness is uncontrolled: the popover owns its own shown/hidden state.

**UIKit — a presentation controller you do not create.** "In nearly all cases, you use this class as-is and don't create instances of it directly. UIKit creates an instance of this class automatically" [[uipopover-pc]]. Behaviour attaches to views as `UIInteraction` objects rather than being a property of a widget.

**TipKit — declarative, value-semantics, and the outlier.** A `Tip` is a struct whose entire eligibility is data: `rules` built by the `#Rule` macro over `@Parameter`-tracked app state and over donated `Event` counts, plus `options`. Status is exposed as an `AsyncStream<Status>` and a derived boolean stream; presentation is a _separate_ view that merely observes. Persistence is explicit and configurable, donations are bounded, and invalidation is a reasoned terminal transition — `invalidate(reason:)` with an `InvalidationReason`, plus `resetEligibility()` [[tipkit-tip]].

SwiftUI popovers are _controlled_ in the React sense: `.popover(isPresented:)` and `.popover(item:)`, where changing `item` "dismisses the currently presented popover and replaces it with a new popover using the same process" [[swiftui-popover-item]].

**Algorithm.** TipKit's is the one worth transcribing: eligibility is the conjunction of all rules evaluated over parameters and a bounded event log, the frequency gate against the last first-appearance, the display-count limit, the cumulative-duration limit, and not-invalidated. Everything on the right-hand side is plain data; the only impurities are the clock and the store, both injected.

**Where it lives.** `NSPopover`: an AppKit object. UIKit: the presentation-controller hierarchy plus interaction objects on views. TipKit: an eligibility engine over a persistent datastore, with the view layer as a pure observer.

**Degradation.** TipKit's architecture survives a non-DOM, allocation-conscious, value-semantics toolkit almost entirely — rules as data, a bounded event ring, an injected clock, a serializable store, and a derived boolean the view reads, none of which allocates in the steady state. SwiftUI's controlled bindings survive too, and are the right default when a recording target must be able to _set_ and _assert_ overlay state, because the whole state then lives in the application's own value tree. `NSPopover`'s delegate-and-notification architecture does not survive: object identity, optional-protocol dispatch and user-info dictionaries are all things a value-semantics toolkit should refuse. The single most portable structural idea across all three is the **reason-tagged terminal transition** (`CloseReason`, `InvalidationReason`): every disappearance carries _why_, which is what lets a headless target assert behaviour rather than pixels. One caution for such a design: the requested anchor geometry and the resolved placement must occupy different fields, or the request is destroyed by its own answer.

### 16. Shared infrastructure

Apple's factoring is the opposite of a single unified `AnchoredOverlay`, and the split it chose is instructive: **content is shared, anchoring is not, eligibility is a separate layer that rents the existing surfaces.**

Shared: `UIMenu` / `UIMenuElement` is one content model behind context menus, edit menus, button menus and the Catalyst menu bar, and the edit-menu delegate speaks it fluently enough to hand the app the system's own suggested actions to merge. Not shared: every primitive re-invents anchoring (positioning rect plus view, source view plus rect, source item, an event, a point in view-or-screen space, a delegate-returned target rect, a SwiftUI anchor token) and every one re-invents dismissal (a behaviour enum, a deprecated delegate veto, `cancelTracking`, `dismissMenu`). Not shared _and deliberately so_: tooltips take a string and never a view; menus have items and a highlight cursor; popovers host an arbitrary view controller.

TipKit shows the clean seam. A teaching tip is not a new surface — `TipNSPopover` is "a subclass of NSPopover that displays a popover tip", `TipUIPopoverViewController` is presented "using UIPopoverPresentationController", and `.popoverTip(_:arrowEdge:action:)` sits on SwiftUI's popover [[tipkit], [tipkit-tipuipopoverviewcontroller]]. What TipKit adds is only eligibility, a content shape (title / message / image / actions), and a store. Meanwhile the HIG independently forbids the composition a unified primitive would tempt you into: never cascade popovers, nothing over a popover except alerts, and menus restricted to a single level of submenu.

**Algorithm.** Not an algorithm but a factoring: `[content model] × [anchor description] × [presentation controller] × [eligibility engine]`, where only the first and the last are genuinely reused across kinds.

**Where it lives.** The content model in UIKit's `UIMenu` family; presentation in per-kind controllers and interactions; eligibility in TipKit; anchoring nowhere central.

**Degradation.** Read as advice for one primitive on one surface, the honest split is that the shared core should own exactly the substrate that is identical across kinds — the anchor value, the placement solve (permitted sides, viewport inset, overlap flag, flip and slide over integer cells, with the resolved side and arrow offset as _outputs_), the layering/ownership tree where a parent closes its children and a child does not dismiss its parent, the dismissal policy value with a reason-tagged terminal transition, and the modality hit-list filter with a passthrough allow-list. What merely _looks_ common and should stay apart, on Apple's evidence: content typing (string versus items-with-a-cursor versus a widget tree — collapsing these makes tooltips interactive and menus unnavigable); trigger semantics, whose availability differs per target; focus policy (a menu owns the key stream, a tooltip must never take focus, a popover contains without trapping); and timing, where TipKit's persistent cumulative eligibility and a per-frame hover warm-up are demonstrably different subsystems. Adaptive form selection belongs to the host, above the primitive (dimension 12). Follow TipKit exactly on the last point: build a teaching-tip layer as eligibility-over-data that _rents_ the anchored overlay, never as a new overlay kind. See [`proposal.md`][proposal] for how this factoring is taken up.

## Strengths

- Dismissal policy is a single comparable enum on the surface, and one of its cases scopes light dismiss to the anchor's containing window rather than to "anywhere outside".
- `passthroughViews` expresses modality as an allow-list over hit testing: a blocking popover with named still-live background views, implemented in library code rather than as an OS input grab, and therefore reproducible on a toolkit with no pointer grab.
- Arrow geometry is genuinely data — a direction plus a signed offset from the edge midpoint — pushed live onto app-supplied chrome, re-pushed as the overlay shifts, and readable from the presentation controller for the app's own animation.
- SwiftUI's `Anchor` is an opaque `Equatable`/`Hashable`/`Sendable` token resolved later against a chosen coordinate space, and `anchorPreference` propagates it up the tree as ordinary data — an existence proof that an anchor can be a plain comparable value.
- TipKit separates _eligibility_ (declarative rules over parameters and a bounded event log, persisted, with cumulative duration limits and an anti-flicker floor) from _anchoring_ (it rents the existing popover surfaces).
- Adaptive presentation is owned by an explicit adaptivity layer, with a per-axis override that travels with the presented content, so the same overlay adapts identically from every entry point.
- Reason-tagged terminal transitions (`NSPopover.CloseReason`, TipKit's `InvalidationReason`) make "why did it go away" data rather than inference.
- Menus are presented as a synchronous call returning whether an item was chosen, inside a modal event-tracking run-loop mode — a structural rather than heuristic answer to trigger races.
- The accessibility role vocabulary keeps help tag, popover, menu, menu item and sheet as distinct roles.
- Tooltip content is typed as a `String`, never a view, so "may a tooltip be interactive" is answered by the type system on every platform.
- `confinementRect(for:on:)` is a custom placement boundary that is explicitly advisory, with the override condition named ("if it would force the menu to be too small") — a mature answer to an over-constrained solve.
- Soft-keyboard avoidance is a first-class reposition callback offering the app a rewritable rect _and_ a rewritable container view, so the anchor itself can be retargeted at reposition time.
- `canOverlapSourceViewRect` makes "may the overlay cover its own anchor" an explicit, default-`false` policy rather than an emergent accident.
- A popover can be promoted into a real window, with the app supplying the `NSWindow`, and the transition is reason-tagged.

## Weaknesses

- No public source at all. Apple documents inputs and outcomes while keeping placement, collision, timing and tracking policy private — the opposite of what a toolkit designer needs.
- No fallback ordering anywhere: UIKit takes a permitted _set_ of arrow directions, AppKit one preferred edge, SwiftUI one optional edge. "Prefer top, then right, then bottom" is inexpressible in all three.
- SwiftUI's `arrowEdge` was silently ignored on iOS until 18.1 and is now gated on which SDK the app linked against — a placement parameter that did nothing for five years, with no diagnostic.
- Zero documented tooltip timing: no initial delay, no close delay, no warm-up, no [cool-down][concepts], no maximum duration.
- No interactive-hover vocabulary at all on the pages read: no safe polygon, no pointer bridge, no menu aim, no trajectory, no debounce.
- Six incompatible anchor representations across the primitives, with no shared anchor type and no documented conversion story between them.
- No multi-rect anchor: `UIEditMenuInteraction`, the one text-selection overlay, returns a single `CGRect`, so a selection spanning wrapped lines has no documented union-of-rects anchoring model.
- UIKit removed the dismissal veto while AppKit kept `popoverShouldClose(_:)`: the two frameworks disagree on whether an app may refuse a dismissal.
- Popover focus policy is undocumented — nothing states whether a popover takes first responder, whether focus is trapped or merely contained, or what happens to focus on dismissal.
- Directional vocabulary is physical rather than logical throughout, so RTL mirroring is left to the app even though `NSMenu` carries a layout-direction property.
- `popoverLayoutMargins` is specified relative to _device_ orientation while the interface may be in a different orientation, and the documentation spends a paragraph warning about it.
- Adaptation is invisible at the call site: on iPhone a `.popover` produces a sheet and silently discards the attachment anchor and arrow edge, and the opt-out is documented with a hedge ("if possible").
- Nine overlapping primitives with no shared anchoring, placement or dismissal substrate; knowledge of one transfers poorly to the next.
- No documented WCAG 1.4.13 posture and no screen-reader timing guidance for any overlay.
- `NSPopover` exposes no arrow API whatsoever — no size, no offset, no direction readback, no hide — so a macOS app cannot align an arrow or animate from it, while the iOS equivalent can.

## Key design decisions and trade-offs

| Decision                                                                                                                                                                                    | Rationale                                                                                                                                                                                                                                                                                                                                                                   | Trade-off                                                                                                                                                                                                                                                                                                                |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Encode the whole dismissal policy as one enum on the surface, with a case that scopes light dismiss to a container, rather than as a set of independent booleans.                           | Dismissal rules interact; a boolean bag admits contradictory combinations and forces every consumer to re-derive the intent. One value is comparable, storable and explainable, and the scoped case expresses the real requirement "this inspector should survive me clicking another window of my own app".                                                                | A closed enum cannot express policies Apple did not foresee — no close-on-scroll, no close-on-anchor-hidden, no per-event-phase choice — so anything unusual falls off the cliff into `applicationDefined`, where the app implements everything by hand.                                                                 |
| Make modality an allow-list over hit testing rather than an input grab or a boolean.                                                                                                        | It is implementable purely in library code, it degrades gracefully, and it expresses the genuinely useful middle state — a blocking surface with a few live background controls — that neither "modal" nor "non-modal" can express.                                                                                                                                         | The app must enumerate passthrough views by identity and keep the list correct as the UI changes; a stale entry silently either blocks a control or leaks input past a surface meant to be modal. It also covers pointer input only — the documentation does not say how keyboard input is partitioned.                  |
| Do not unify tooltip, popover, menu, context menu, edit menu and teaching tip into one primitive; unify only the content model and layer eligibility on top of the existing surfaces.       | The kinds differ in the dimensions that matter — content typing, trigger availability per device, focus ownership, and timing subsystem — so a single primitive would either over-constrain (a tooltip that can hold a button) or under-constrain (a menu without a highlight cursor). Reusing the surface while separating eligibility is what let TipKit ship additively. | Enormous duplication in the parts that really are common: six anchor representations, four dismissal APIs, and placement policy re-implemented per primitive with no shared, documented fallback ordering. Learning `UIPopoverPresentationController` teaches almost nothing transferable about `UIEditMenuInteraction`. |
| Publish the resolved arrow geometry as mutable data pushed onto app-supplied chrome, while keeping the placement algorithm that produced it entirely private.                               | Apps need the outcome to draw chrome and to animate from the right origin; they do not need — and Apple does not want them depending on — the policy. Pushing the values and requiring `setNeedsLayout()` on change keeps chrome correct through repositions without the app observing anything.                                                                            | Because the policy is private and the side input is a permitted _set_ rather than an ordered list, an app can neither express "prefer top, then right" nor predict or test placement. `arrowEdge` being silently ignored on iOS for five years is the direct consequence of that opacity.                                |
| Let the adaptivity layer — not the overlay and not the call site — choose whether a popover is a popover, a sheet or a full-screen cover, and let the presented content carry the override. | Size-class adaptation is a property of the environment the content lands in, not of the button that opened it, so putting the override on the content makes the same overlay behave consistently from every entry point and makes the default correct for apps that never think about it.                                                                                   | Adaptation is invisible at the call site: a `.popover` on iPhone produces a sheet, which surprises developers and means the anchor, the arrow edge and the placement inputs are all silently discarded. The opt-out is even hedged — `PresentationAdaptation.none` is "Don't adapt for the size class, if possible".     |
| Run menus inside a modal event-tracking run loop and expose presentation as a synchronous call returning whether an item was chosen.                                                        | It makes trigger races structurally impossible, keeps intermediate tracking events — including whatever submenu-aim heuristic exists — entirely inside the framework, and gives the caller a trivially usable result value.                                                                                                                                                 | It is hostile to a single-threaded frame loop and to modern concurrency: the app's own loop stops while the menu is up, timers in other run-loop modes do not fire, and the pattern cannot be reproduced in an immediate-mode or async architecture without reinventing it as a state machine.                           |
| Give hover-only affordances no touch fallback: `UIToolTipInteraction` does not appear on touch platforms, and `.help(_:)` degrades to an accessibility hint.                                | An automatic long-press-for-tooltip would collide with the long-press context-menu trigger and would train users to press-and-wait on every control. Degrading to the accessibility channel keeps the information reachable without inventing a gesture.                                                                                                                    | Sighted touch users lose the information entirely, with no diagnostic — a tooltip that never appears looks identical to a tooltip that was never set. It also pushes discovery onto an entirely separate framework with its own store, configuration call and eligibility model.                                         |
| Make teaching-tip eligibility persistent, cumulative and syncable rather than session-local.                                                                                                | A tip that reappears on every launch is worse than no tip; correctness requires remembering across launches and, ideally, across devices. Bounding the donation query at 1000 keeps evaluation cheap regardless of how long the app has been installed.                                                                                                                     | An overlay framework now owns durable user state, a configuration step that must run before anything displays, a failure mode when it does not, and a testing burden — which is why TipKit ships explicit testing utilities and a `resetEligibility()` escape hatch.                                                     |

## Sources

All sources are published documentation. No implementation was read; there is none to read.

**AppKit reference** — [`NSPopover`][nspopover] (overview, `animates`, `close()` versus `performClose(_:)`, `isShown`, notifications), [`positioningRect`][nspopover-positioningrect], [`show(relativeTo:of:preferredEdge:)`][nspopover-show], [`NSPopover.Behavior`][nspopover-behavior] and its [`semitransient`][nspopover-behavior-semitransient] case, [`CloseReason`][nspopover-closereason], [`isDetached`][nspopover-isdetached], [`NSPopoverDelegate`][nspopoverdelegate], [`NSMenu`][nsmenu] (`update()`, `size`, `minimumWidth`, `supermenu`, `isTornOff`, `cancelTracking`), [`popUp(positioning:at:in:)`][nsmenu-popup], [`NSMenuDelegate`][nsmenudelegate], [`confinementRect(for:on:)`][nsmenu-confinementrect], [`NSView.toolTip`][nsview-tooltip], [`NSTrackingArea`][nstrackingarea] and [`Options.assumeInside`][nstrackingarea-assumeinside], [`NSAccessibility.Role`][nsaccessibility-role], [`RunLoop.Mode.eventTracking`][runloop-eventtracking].

**UIKit reference** — [`UIPopoverPresentationController`][uipopover-pc], [`passthroughViews`][uipopover-passthroughviews], [`sourceItem`][uipopover-sourceitem], [`permittedArrowDirections`][uipopover-permittedarrowdirections], [`UIPopoverArrowDirection`][uipopoverarrowdirection], [`popoverLayoutMargins`][uipopover-layoutmargins], [`canOverlapSourceViewRect`][uipopover-canoverlap], [`adaptiveSheetPresentationController`][uipopover-adaptivesheet], [`UIPopoverPresentationControllerDelegate`][uipopoverdelegate] and its [reposition callback][uipopover-willreposition], [`UIPopoverBackgroundView`][uipopoverbackgroundview] and [`arrowOffset`][uipopoverbackgroundview-arrowoffset], [`UIContextMenuInteraction`][uicontextmenuinteraction] and [`appearance`][uicontextmenu-appearance], [`UIContextMenuInteractionDelegate`][uicontextmenudelegate], [`UIEditMenuInteraction`][uieditmenuinteraction] and [its delegate][uieditmenuinteractiondelegate], [`UIToolTipInteraction`][uitooltipinteraction], [`UITargetedPreview`][uitargetedpreview].

**SwiftUI reference** — [`.popover(isPresented:attachmentAnchor:arrowEdge:content:)`][swiftui-popover], [the `item:` overload][swiftui-popover-item], [`Anchor`][swiftui-anchor], [`PopoverAttachmentAnchor`][swiftui-popoverattachmentanchor], [`anchorPreference(key:value:transform:)`][swiftui-anchorpreference], [`PresentationAdaptation`][swiftui-presentationadaptation], [`presentationCompactAdaptation(_:)`][swiftui-presentationcompactadaptation], [`.help(_:)`][swiftui-help], [`AccessibilityTraits.isModal`][swiftui-ismodal], [`accessibilityReduceMotion`][swiftui-reducemotion].

**TipKit reference** — [framework overview][tipkit], [`Tip`][tipkit-tip], [`Tips.Rule`][tipkit-rule], [`Tips.Event`][tipkit-event], [`MaxDisplayDuration`][tipkit-maxdisplayduration], [`displayFrequency(_:)`][tipkit-displayfrequency], [`TipGroup`][tipkit-tipgroup], [`TipUIPopoverViewController`][tipkit-tipuipopoverviewcontroller].

**Human Interface Guidelines** — [Popovers][hig-popovers], [Menus][hig-menus], [Context menus][hig-context-menus], [Offering help][hig-offering-help].

**Within this catalog** — [index][index], [shared vocabulary][concepts], [capstone comparison][comparison], [features people forget][features-forgotten], [the sparkles baseline][baseline], [the proposal][proposal], and the sibling reading of the W3C patterns in [`aria-apg.md`][aria-apg]. Related trees: [window-system integration][r-wsi], [platform UI guidelines][r-guidelines], [UI layout][r-layout]. Toolkit specs: [`ui/index.md`][spec-ui], [`ui/input.md`][spec-input], [`ui/containers.md`][spec-containers], [`ui/state-machines.md`][spec-machines], [`ui/backends.md`][spec-backends], [`ui/widgets.md`][spec-widgets].

<!-- References -->

[apple-docs]: https://developer.apple.com/documentation
[nspopover]: https://developer.apple.com/documentation/appkit/nspopover
[nspopover-positioningrect]: https://developer.apple.com/documentation/appkit/nspopover/positioningrect
[nspopover-show]: https://developer.apple.com/documentation/appkit/nspopover/show(relativeto:of:preferrededge:)
[nspopover-behavior]: https://developer.apple.com/documentation/appkit/nspopover/behavior-swift.enum
[nspopover-behavior-semitransient]: https://developer.apple.com/documentation/appkit/nspopover/behavior-swift.enum/semitransient
[nspopover-closereason]: https://developer.apple.com/documentation/appkit/nspopover/closereason
[nspopover-isdetached]: https://developer.apple.com/documentation/appkit/nspopover/isdetached
[nspopoverdelegate]: https://developer.apple.com/documentation/appkit/nspopoverdelegate
[nsmenu]: https://developer.apple.com/documentation/appkit/nsmenu
[nsmenu-popup]: https://developer.apple.com/documentation/appkit/nsmenu/popup(positioning:at:in:)
[nsmenudelegate]: https://developer.apple.com/documentation/appkit/nsmenudelegate
[nsmenu-confinementrect]: https://developer.apple.com/documentation/appkit/nsmenudelegate/confinementrect(for:on:)
[nsview-tooltip]: https://developer.apple.com/documentation/appkit/nsview/tooltip
[nstrackingarea]: https://developer.apple.com/documentation/appkit/nstrackingarea
[nstrackingarea-assumeinside]: https://developer.apple.com/documentation/appkit/nstrackingarea/options-swift.struct/assumeinside
[nsaccessibility-role]: https://developer.apple.com/documentation/appkit/nsaccessibility/role
[runloop-eventtracking]: https://developer.apple.com/documentation/foundation/runloop/mode/eventtracking
[uipopover-pc]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller
[uipopover-passthroughviews]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/passthroughviews
[uipopover-sourceitem]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/sourceitem
[uipopover-permittedarrowdirections]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/permittedarrowdirections
[uipopoverarrowdirection]: https://developer.apple.com/documentation/uikit/uipopoverarrowdirection
[uipopover-layoutmargins]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/popoverlayoutmargins
[uipopover-canoverlap]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/canoverlapsourceviewrect
[uipopover-adaptivesheet]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontroller/adaptivesheetpresentationcontroller
[uipopoverdelegate]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontrollerdelegate
[uipopover-willreposition]: https://developer.apple.com/documentation/uikit/uipopoverpresentationcontrollerdelegate/popoverpresentationcontroller(_:willrepositionpopoverto:in:)
[uipopoverbackgroundview]: https://developer.apple.com/documentation/uikit/uipopoverbackgroundview
[uipopoverbackgroundview-arrowoffset]: https://developer.apple.com/documentation/uikit/uipopoverbackgroundview/arrowoffset
[uicontextmenuinteraction]: https://developer.apple.com/documentation/uikit/uicontextmenuinteraction
[uicontextmenu-appearance]: https://developer.apple.com/documentation/uikit/uicontextmenuinteraction/appearance
[uicontextmenudelegate]: https://developer.apple.com/documentation/uikit/uicontextmenuinteractiondelegate
[uieditmenuinteraction]: https://developer.apple.com/documentation/uikit/uieditmenuinteraction
[uieditmenuinteractiondelegate]: https://developer.apple.com/documentation/uikit/uieditmenuinteractiondelegate
[uitooltipinteraction]: https://developer.apple.com/documentation/uikit/uitooltipinteraction
[uitargetedpreview]: https://developer.apple.com/documentation/uikit/uitargetedpreview
[swiftui-popover]: https://developer.apple.com/documentation/swiftui/view/popover(ispresented:attachmentanchor:arrowedge:content:)
[swiftui-popover-item]: https://developer.apple.com/documentation/swiftui/view/popover(item:attachmentanchor:arrowedge:content:)
[swiftui-anchor]: https://developer.apple.com/documentation/swiftui/anchor
[swiftui-popoverattachmentanchor]: https://developer.apple.com/documentation/swiftui/popoverattachmentanchor
[swiftui-anchorpreference]: https://developer.apple.com/documentation/swiftui/view/anchorpreference(key:value:transform:)
[swiftui-presentationadaptation]: https://developer.apple.com/documentation/swiftui/presentationadaptation
[swiftui-presentationcompactadaptation]: https://developer.apple.com/documentation/swiftui/view/presentationcompactadaptation(_:)
[swiftui-help]: https://developer.apple.com/documentation/swiftui/view/help(_:)
[swiftui-ismodal]: https://developer.apple.com/documentation/swiftui/accessibilitytraits/ismodal
[swiftui-reducemotion]: https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion
[tipkit]: https://developer.apple.com/documentation/tipkit
[tipkit-tip]: https://developer.apple.com/documentation/tipkit/tip
[tipkit-rule]: https://developer.apple.com/documentation/tipkit/tips/rule
[tipkit-event]: https://developer.apple.com/documentation/tipkit/tips/event
[tipkit-maxdisplayduration]: https://developer.apple.com/documentation/tipkit/tips/maxdisplayduration
[tipkit-displayfrequency]: https://developer.apple.com/documentation/tipkit/tips/configurationoption/displayfrequency(_:)
[tipkit-tipgroup]: https://developer.apple.com/documentation/tipkit/tipgroup
[tipkit-tipuipopoverviewcontroller]: https://developer.apple.com/documentation/tipkit/tipuipopoverviewcontroller
[hig-popovers]: https://developer.apple.com/design/human-interface-guidelines/popovers
[hig-menus]: https://developer.apple.com/design/human-interface-guidelines/menus
[hig-context-menus]: https://developer.apple.com/design/human-interface-guidelines/context-menus
[hig-offering-help]: https://developer.apple.com/design/human-interface-guidelines/offering-help
[index]: ./index.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[features-forgotten]: ./features-people-forget.md
[baseline]: ./sparkles-baseline.md
[proposal]: ./proposal.md
[aria-apg]: ./aria-apg.md
[r-wsi]: ../window-system-integration/index.md
[r-guidelines]: ../platform-ui-guidelines/index.md
[r-layout]: ../ui-layout/index.md
[spec-ui]: ../../specs/ui/index.md
[spec-input]: ../../specs/ui/input.md
[spec-containers]: ../../specs/ui/containers.md
[spec-machines]: ../../specs/ui/state-machines.md
[spec-backends]: ../../specs/ui/backends.md
[spec-widgets]: ../../specs/ui/widgets.md
