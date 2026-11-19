# Overlay anchors and placement

`sparkles.ui.overlay` places a popup, a tooltip or a menu against what it
belongs to ([popup spec](../../../specs/ui/popup.md), milestone V0). An
`Anchor` names the target, `resolveAnchor` finds it in a laid-out frame, and
`place` decides where the overlay goes, returning the whole decision.

## Anchors (`sparkles.ui.overlay.anchor`)

| Symbol                                     | Meaning                                                                                                      |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `Anchor.ofRect(r)`                         | A rect in the overlay's coordinate space                                                                     |
| `Anchor.ofKey(key)`                        | The widget whose `Widget.key` is `key`; re-resolved every frame (`Tracking.live`)                            |
| `Anchor.atPoint(p)`                        | One cell — a pointer or a caret — as a 1×1 rect; latched by default                                          |
| `Anchor.ofText(start, end)`                | The first row source bytes `[start, end)` cover; latched by default                                          |
| `Anchor.atCorner(c)`                       | A corner cell of the surface                                                                                 |
| `anchor.avoiding(r)`                       | The same anchor, with a rect the overlay must keep clear                                                     |
| `resolveAnchor(anchor, surface, tree, fs)` | The `ResolvedAnchor` one frame gives: `rect`, the `visible` part and a verdict; the request is never written |
| `AnchorVerdict`                            | `visible`, `clipped` (a viewport cuts it), `hidden` (laid out, scrolled away), `gone` (not drawn)            |
| `resolveKey(tree, frames, key)`            | A key anchor through the same clip chain the display list scissors with                                      |
| `anchorLive(anchor, keyTargets)`           | Whether a key anchor still names a drawn widget                                                              |

## Placement (`sparkles.ui.overlay.place`)

`place(request, boundary)` is `@safe pure nothrow @nogc` and total. The
boundary is a parameter; `boundaryOf(surface, insets)` is the default one, the
surface less its viewport insets (a safe area, the soft keyboard).

| `PlaceRequest` field       | Meaning                                                                           |
| -------------------------- | --------------------------------------------------------------------------------- |
| `anchor`                   | The resolved anchor rect, in the boundary's space                                 |
| `content`                  | The overlay's size, or the most it may grow to                                    |
| `side`, `alignment`        | The side of the anchor asked for, and the gravity along its edge                  |
| `gap`, `shift`             | Cells between anchor and overlay, and along the edge                              |
| `adjust`                   | `Adjust` bits: `flip`, `slide`, `resize` (the default) and opt-in `overlap`       |
| `flipRule`                 | `lessBad` (flip when the other side overhangs less) or `onlyIfFits`               |
| `minSize`                  | The resize floor, `popupMinWidth` × `popupMinHeight` by default                   |
| `keepLastSide`, `lastSide` | The side the last accepted placement used, so an overlay does not swap needlessly |
| `arrow`                    | Report an arrow cell                                                              |
| `arrowClearance`           | Cells the arrow needs between anchor and overlay, added to `gap` with `arrow`     |
| `anchorClip`               | The anchor's clip, read only for the anchor-hidden verdict                        |

The adjustments run flip, then slide, then resize. A slide stops at the
boundary, never at `0`, and an overlay larger than the boundary pins its start
edge.

| `OverlayGeometry` field | Meaning                                                                   |
| ----------------------- | ------------------------------------------------------------------------- |
| `rect`                  | Where the overlay goes                                                    |
| `side`, `alignment`     | What they resolved to                                                     |
| `fit`                   | `fits`, `adjusted`, or `refused` — no allowed adjustment brings it inside |
| `fired`                 | The `Adjust` bits that changed the placement                              |
| `hasArrow`, `arrow`     | The arrow cell along the edge, from `rect`'s start, kept off the corners  |
| `arrowCentred`          | Whether the arrow reaches the anchor's centre                             |
| `room`                  | The room on the resolved side: the budget to lay the content out in       |
| `anchorLocal`           | The anchor in the overlay's own cells                                     |
| `overhang`              | How far the asked-for placement overhung each side                        |
| `anchorHidden`          | The anchor is wholly outside `anchorClip`                                 |

## The overlay layer (`sparkles.ui.overlay.arena`)

A `WidgetKind.popup` node that is not the tree's root is an overlay. It is
written as a child of the node it hangs off, and `Widget.overlay` (an
`OverlaySpec`) says where it goes and what it paints over. Layout takes it out
of its parent's flow and places it against the parent's rect, inside the
root's rect. The display list paints it after the flow and outside every
ancestor's clip, and the hit and key targets list it last, so it wins the
cells it covers.

| `OverlaySpec` field      | Meaning                                                                      |
| ------------------------ | ---------------------------------------------------------------------------- |
| `band`                   | `OverlayBand`: `adorn`, `popup` (the default), `hint` or `notify`            |
| `side`, `alignment`      | As in `PlaceRequest`                                                         |
| `gap`, `shift`, `adjust` | ditto                                                                        |
| `flipRule`               | ditto                                                                        |
| `cover`                  | Take the anchor's rect itself — an adornment, such as the dock's drop hint   |
| `hasAnchor`, `anchor`    | Anchor to a rect in the parent's own cells instead of to the whole parent    |
| `closing`                | Animating out: it still paints, and neither it nor anything in it takes hits |

Bands paint in that order; within a band, overlays paint in tree order. An
overlay nested in another takes the higher of the two bands, so it never paints
below its parent. An overlay is open for a frame when its node is in that
frame's tree and visible, and its anchor has not scrolled out of view
(`Frame.overlayHidden`). A view closes an overlay by no longer building it.

| Symbol                            | Meaning                                                                      |
| --------------------------------- | ---------------------------------------------------------------------------- |
| `overlayArena(tree, frames, g)`   | The frame's `OverlayArena`: its open overlays in paint order, generation `g` |
| `OverlayArena.at(p)`              | The topmost overlay under `p` that takes hits — the routing rung             |
| `OverlayArena.idOf(key)`          | This frame's `OverlayId` for the overlay keyed `key`                         |
| `OverlayArena.isOpen(id)`         | Whether `id` is from this frame: a handle kept from an earlier one is not    |
| `OverlayArena.isWithin(a, c)`     | Whether `c` is `a` or nested in it                                           |
| `OverlayArena.topmost(band)`      | The last-painted overlay in `band`                                           |
| `eachOverlay!visit(tree, frames)` | The paint order every walk shares                                            |
| `maxOverlays`                     | 16: the arena's capacity; past it, `overflowed` is set                       |

```d
const menu = b.add(Widget(kind: WidgetKind.popup, slot: Slot.surface,
    paintBackground: true, overlay: OverlaySpec(side: Side.bottom, gap: 0),
    children: [items]));
const button = b.add(Widget(kind: WidgetKind.row, children: [label, menu]));
```

## Arrows (`sparkles.ui.overlay.arrow`)

A box draws its arrow from `Decoration.arrow`, `arrowOffset` (the cell along
the edge, from its start) and `arrowEdge` (the edge it pokes out of). Every
canvas — the cell grid, the terminal grid, raylib, Vulkan — and the HTML
emitter take the cell from one function, so they agree on it.

| Symbol                             | Meaning                                                                              |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| `arrowCell(edge, offset, w, h)`    | The `ArrowCell`: the edge, the cell along it clamped off both corners, and `visible` |
| `facingEdge(side)`                 | The overlay edge facing an anchor it was placed on `side` of                         |
| `arrowNotch(edge)`, `arrowNotchAt` | The box-drawing notch a cell target draws, and the cell it goes in                   |

An edge shorter than three cells draws no arrow: clamped, it would land on a
corner.

To size content to the side it lands on, ask once with the content's bound,
lay out within `room`, then ask again with the measured size and
`keepLastSide: true, lastSide: first.side`.

```d
const at = place(PlaceRequest(anchor: caretCell, content: popup.size, gap: 1),
    boundaryOf(pane, softKeyboard));
paintAt(at.rect.origin);
```
