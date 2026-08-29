/**
The anchored-overlay primitive: the one surface that is positioned relative to
something else and painted above it.

Tooltip, popover, hovercard, dropdown, menu, context menu, combobox surface,
teaching tip, the dock hint and the screen-anchored notifier are all $(B one)
value with different policy — never N widget types (`POP1`). The base-class
shape is rejected on the catalog's evidence that its awkward consumers bypass
the base entirely: WinUI's `ToolTip` and `TeachingTip` both leave `FlyoutBase`.

The shared core is exactly four things, and the split between them and the
per-surface half is far more stable across the corpus than the packaging is
(`POP2`):

$(LIST
    * $(MREF sparkles,ui,overlay,anchor) — the anchor value and its resolution
    * $(MREF sparkles,ui,overlay,place) — the placement solve and its result
    * $(MREF sparkles,ui,overlay,arena) — the ordered top layer and its bands
)

$(B Out) of the primitive, deliberately: focus behaviour defaults, timing
machines, item collections, typeahead and selection, content typing, roles,
modality-as-a-mode, and every exotic placement mode. Zag's inverted dependency
pair is the sharpest evidence the core is two halves rather than one monolith —
its toast package depends on the dismissal layer and $(I not) the positioner,
its tooltip package on the positioner and $(I not) the dismissal layer.

One structural rule the whole architecture rests on: an overlay's content is
$(B authored as a child of its anchor), and only its $(I emission) is hoisted
(`POP3`). That is Flutter's `OverlayPortal` split with the reparenting removed,
and it is the only shape that also serves the static-HTML target, where
`:hover`/`:focus-within` cannot cross a hoist.

Spec: `docs/specs/ui/popup.md`.

$(B Re-exports only.) No unittest may live here — `dub test` generates an
`allModules` list that excludes `package.d`, so a test written in this file
would silently never run.

This module re-exports the overlay vocabulary and nothing else: the geometry
every signature here is written in ($(MREF sparkles,ui,geometry)) stays a
separate import, as it is for the rest of the toolkit. A consumer that wants
everything at once imports $(MREF sparkles,ui), which gathers both.
*/
module sparkles.ui.overlay;

public import sparkles.ui.overlay.anchor;
public import sparkles.ui.overlay.place;
public import sparkles.ui.overlay.arena;
