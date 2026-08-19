# `hue` — Open implementation issues

_Companion to the [`hue` feature specification](./index.md). The normative
requirements remain in the feature specs; this page records concrete
implementation gaps that those requirements already decide but this docs-only
consistency pass does not fix. Close an entry only after the implementation
lands, its requirement status is reconciled, and the closing commit is recorded._

## HUE-O1 — GUI view state still has several peer owners {#hue-o1}

**Status:** open. **Requirements:** [`UIA5`](./ui-architecture.md#hues-consumption-uia),
[`MIG9`](../ui/migration.md), `PRN1`, `PRN7`.

`ViewerModel` is the document-pipeline Whole, but `runGui` still owns mutable
`Panes`, `InputState`, `Flashes`, `HoverPopup`, `ResizeDebounce` and
`SelectionDrag` peers beside it. Nested functions capture and mutate several of
those values. The state is grouped better than the original free-local frame
loop, but there is still no object representing the GUI view state as a whole and
no single transition surface over it.

The implementation must introduce one GUI-state aggregate that owns those
groups, including `ViewerModel`, and expose state changes as methods or pure
transitions. Window/font handles, native-input translation and the final paint
action remain host resources outside the value. Close this issue when the frame
loop has no peer semantic-state locals or mutating closures and the aggregate's
transitions are unit-tested without a window.

## HUE-O2 — hue still hand-paints backend-specific chrome {#hue-o2}

**Status:** open. **Requirements:** [`UIA2`, `UIA4`](./ui-architecture.md#hues-consumption-uia),
`WGT7+`.

The document views are widget trees, but hue still owns paired GUI/TUI paint
sites for roughly six chrome concepts. The live census and pairings stay in
[UI architecture](./ui-architecture.md); this entry records the implementation
gap rather than duplicating that volatile inventory.

`PRN8` permits adapters to paint and measure differently. It does not make
application-owned duplicate painters acceptable: hue's own `UIA2` requires each
remaining concept to become one toolkit widget view. Close this issue when the
inventory is empty, every replacement deletes both predecessors in the same
change, and the cross-backend parity goldens remain green.

## HUE-O3 — Drags can lose release or activate window decorations {#hue-o3}

**Status:** open, blocked by [`UI-O3`](../ui/open-issues.md#ui-o3).
**Requirements:** `INP9`; hue GUI drag/selection requirements.

On GNOME/Wayland through XWayland, a GUI drag released over a title-bar control
can activate that control, and a drag leaving the content can lose its release.
The cause and fix belong to the shared window/input backend and also affect
`apps/terminal`, so [`UI-O3`](../ui/open-issues.md#ui-o3) is the canonical
technical record. Close this consumer issue when that backend issue is closed and
hue's end-to-end drag-over-decoration case passes.

## HUE-O4 — Android 16 enforces edge-to-edge, and the toolbar does not handle insets {#hue-o4}

**Status:** open, latent — introduced by targeting API 36, not yet observed on a
device. **Requirements:** [`AND6`](./android.md) (touch toolbar),
[`FDR4`](./fdroid.md) (declared API levels). **Feeds:** the planned mobile UI
redesign.

Targeting API 36 opts hue into Android 16 enforcing edge-to-edge display. Android
15 still honoured `windowOptOutEdgeToEdgeEnforcement`; Android 16 ignores it, so
there is no way to decline. The app's surface now extends under the system bars.

hue paints a five-segment toolbar along the bottom edge (`◀ thm`, `thm ▶`,
`view`, `tree`, `ln №`, plus `copy` while a selection is live). Nothing in the
GUI reads window insets, so on an Android 16 device with gesture navigation that
row is expected to sit partly beneath the navigation bar — cosmetically wrong,
and the hit targets harder or impossible to reach. The top edge has the same
exposure wherever content runs under the status bar.

This is deliberately **not** fixed by adding an inset fudge to the current
toolbar. Insets are a layout input the toolkit does not model at all today: they
belong beside the existing cell geometry as a safe-area the layout pass honours,
so every Android surface (toolbar, tree pane, future chrome) gets them from one
place rather than each hand-correcting. That is redesign-shaped work, which is
why it is recorded here rather than patched.

Close this issue when the toolkit carries a safe-area/inset concept through
layout, hue's Android surfaces derive their placement from it, and the toolbar
is confirmed reachable on an Android 16 device with gesture navigation — the
emulator's default configuration included.

## HUE-O5 — The widget-HTML interpreter cannot lay out positioned stacks {#hue-o5}

`sparkles.ui.interp.html`'s `writeWidgetHtmlPage` renders widget trees as
document flow, which is correct for the diff view's row/column trees but
falls apart on the unified table component's widget view: `buildTableWidgets`
emits a **fixed-size `stack` of absolutely positioned runs** (core-geometry
placement — the shape rowspans and vanishing rules require), and the flow
renderer scatters every run onto its own line. hue's DSV `--html` arm hit
this and was rerouted to the semantic `MdDoc → HTML` emitter (a real
`<table>`, which `DSG6` wanted anyway), so no shipped surface renders a
table through the widget-HTML path today — but any future consumer that
hands `writeWidgetHtmlPage` a tree containing a table (a diff with an
embedded markdown-preview table, a twoslash doc popup with one) will
reproduce it.

Close this when the HTML interpreter maps a fixed-size stack to a
`position: relative` container and its positioned children to
`position: absolute` offsets (the cell/em grid the page already uses), with
a table-bearing tree in its round-trip tests.
