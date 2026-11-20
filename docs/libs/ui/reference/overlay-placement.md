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

To size content to the side it lands on, ask once with the content's bound,
lay out within `room`, then ask again with the measured size and
`keepLastSide: true, lastSide: first.side`.

```d
const at = place(PlaceRequest(anchor: caretCell, content: popup.size, gap: 1),
    boundaryOf(pane, softKeyboard));
paintAt(at.rect.origin);
```
