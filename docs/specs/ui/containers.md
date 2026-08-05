# `sparkles:ui` containers — Feature Requirements (`SCV`, `DCK`)

_**Status:** proposed · **Date:** 2026-08-05 · **Scope:** the container tier —
the `ScrollView` that encapsulates scrolling, and the single-window docking
container that encapsulates pane composition (splits, tabbed groups,
drag-to-redock, focus, capture)._

## Why this spec exists

The [interaction review](./interaction-review.md) diagnosed the disease —
behavior written per host diverges — and Phase B treated it machine by
machine: one scrollbar machine (`STM9`), one capture model (`STM11`), one
pointer-shape decision, one press protocol (`STM10`). Every one of those
landed, and yet composing them is still the application's job: hue wires
four `ScrollbarState` machines, four hover-expand easings, offset syncing,
overflow measurement, wheel routing, capture ids and hit zones — twice,
once per host. The M15 state hoist made that wiring visible as value types
(`Panes`, `InputState`), which is exactly how it became obvious that the
values belong to a component, not to the app.

The verdict (user directive, 2026-08-05): **the toolkit has machines but no
containers.** A mature UI framework gives the application a `ScrollView`
and a dock layout — the application declares content and panes; the
container owns the interaction. This spec defines those two containers.

## Prior art

The dock container targets the class of:

| Framework                          | Platform | What it demonstrates                                                                                      |
| ---------------------------------- | -------- | --------------------------------------------------------------------------------------------------------- |
| Dockview, FlexLayout, GoldenLayout | Web      | full IDE-style docking as a serializable layout tree of splits + tabbed groups, drag-to-redock with hints |
| `QMainWindow` / `QDockWidget`      | Qt       | edge-anchored tool panes around a central widget; capture and cursor owned by the framework               |
| AvalonDock, `DockPanel`            | WPF      | the layout-model/view split (`LayoutRoot` vs templated chrome); XML layout persistence                    |
| DockFX, `SplitPane`                | JavaFX   | tabbed splitting; dock-indicator overlay during a drag                                                    |
| GridStack.js, react-grid-layout    | Web      | (contrast) dashboard tile grids — a different model; **not** this spec's target                           |

Two ideas are common to every serious implementation and are load-bearing
here:

1. **The layout is a value** — a tree of splitters and tabbed groups that
   serializes, diffs and round-trips (GoldenLayout's config, AvalonDock's
   `LayoutRoot`, Dockview's `toJSON`). Chrome and interaction derive from
   it; they never own it.
2. **The container owns the pointer** — capture, dock hints, cursor shapes
   and divider drags are framework code. An application adding a pane
   writes zero interaction logic (`QDockWidget`'s contract).

Deliberately **out of scope** (confirmed): floating OS windows /
multi-window docking. The layout model reserves a slot for a floating
group so the door stays open, but no milestone below builds one.

## Design & rationale

Containers follow the toolkit's existing split — a presentation-free
**view model** (the layout value + the composed STM machines) and a
**view** (widget subtrees per pane region, chrome from the existing
component catalog: `headerBar`, `actionBar`-style tab strips, `scrollbar`).
Both hue hosts consume `sparkles:input` events since `UIA7`/`UIA8`, so a
container handles semantic events **once**. Backend adapters still translate
native input, measure and paint in their own device units (cells vs px) behind
the established seams (`WGT10` cell scrollbar /
`ui_raylib.drawScrollbar`; `GridCanvas` / `RaylibCanvas`).

Nothing below invents a new state machine: the containers **compose**
`STM7` (focus), `STM8` (splitter), `STM9` (scrollbar), `STM10` (press),
`STM11` (capture) and the `wantedPointerShape` decision. What is new is
the ownership boundary: the machines move inside, and the application
stops being able to forget one.

## ScrollView (`SCV`)

| ID   | Requirement                                                                                                                                                                                                                                                                                      | Status                                                                                                                                                                                                                                                                                         | Traces to                                                                         |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| SCV1 | Scrolling must be one **value** — both axes' `STM9` machines, the scroll offsets, and (for px backends) the hover-expand easings — owned by a `ScrollView`, not assembled per pane. The application reads offsets out; it never runs a grab.                                                     | partial — `ViewerModel.scroll` / `ExplorerTui.scroll`: both backends step the model-owned value (old names live on as ref accessors); the M18 element-store identity (`SCV5`) is separate                                                                                                      | `Panes.docSb/treeVSb` + 4 anims in hue `gui.d` are the state this absorbs         |
| SCV2 | The ScrollView must own **overflow**: given content and viewport extents it decides per axis whether a bar exists, its thumb geometry (`STM2`), and clamping — the one place `offset ∈ [0, content − viewport]` is enforced.                                                                     | partial — `stepV`/`stepH` clamp and drop dormant axes; the overflow _decision_ (`hOverflows`) still reads model fields                                                                                                                                                                         | `ViewerModel.hOverflows` / explorer `measureContent` unify here                   |
| SCV3 | The ScrollView must **handle events**: wheel steps (already cells, `INP12`) scroll it; bar presses/drags run the `STM9` grab through a container-issued capture id (`STM11`); hover expands only on targets that declare hover (`InputCapabilities`, `IXB10`).                                   | partial — the GUI grabs run through `stepV`/`stepH` + container-issued STM11 ids and `easeV`/`easeH` respect `InputCapabilities`; the TUI grabs still transition the machines directly (its capture is workspace-owned — threads through with `C-2a`), and wheel application remains host-side | the four per-pane grab/hit blocks in `gui.d`; `workspace.d`'s wheel/`sb` handling |
| SCV4 | The ScrollView must be **unit-agnostic** (cells or pixels — the track parameter defines the space) and paint through the existing per-backend renderings: the `WGT10` cell component and the `ui_raylib` px twin. One state, two honest drawings; colors from the palette `track`/`thumb` slots. | full — one state, the `WGT10` cell component and the `ui_raylib` px twin (B-1) both draw it; palette `track`/`thumb` colors                                                                                                                                                                    | B-1's painter unification becomes the container's paint path                      |
| SCV5 | Scroll state must survive rebuilds by **element identity** (`WGT5` keys / element store), so a pane's offset persists across view rebuilds without the application shepherding it.                                                                                                               | not started                                                                                                                                                                                                                                                                                    | `ElementStore`; today hue re-syncs offsets manually per frame                     |
| SCV6 | The ScrollView must report a wanted **pointer shape** for its current state (axis resize shapes while hovering/dragging a bar), consumed by the host's one shape write.                                                                                                                          | partial — `ScrollView.shape()` shipped; the hosts still compose shapes via `wantedPointerShape` over the machines                                                                                                                                                                              | `wantedPointerShape` grows a ScrollView-aware overload (or consumes its state)    |

## Dock container (`DCK`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status      | Traces to                                                                  |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------------------------------------------------------------- |
| DCK1  | The workspace layout must be a **Regular value**: a flat-arena tree (`WGT1` discipline) of **splits** (row/column with weights) and **tabbed groups** (ordered pane ids + active tab), with panes as leaves addressed by stable ids. Copy, compare, snapshot.                                                                                                                                                                                          | partial — `DockLayout` (flat arena, deep-copying, extent constraints, visibility) + `dockFrames`; tabbed groups join at `C-2b` | supersedes `workspace.d` + `gui.d` pane composition                        |
| DCK2  | The layout value must **serialize and restore** (via `sparkles:wired`), so a session's arrangement round-trips — the GoldenLayout/AvalonDock persistence contract. Restoring against a changed pane set must degrade by dropping unknown ids, never by failing.                                                                                                                                                                                        | not started — the value is serialization-ready (plain data, deep copy); `C-2c` | hue `--tree-width` becomes a seeded layout; `CFG` spec integration later   |
| DCK3  | Every split divider runs the **`STM8`** machine with the container translating pointer positions to the divider's axis and units; a divider drag owns the pointer via **`STM11`** ids the container issues. Applications add panes, never divider logic.                                                                                                                                                                                               | full — `DockContainer` runs STM8 per divider under an STM11 id; a drag redistributes between its two neighbours only | `workspace.d` divider block; `gui.d` `capDivider` block                    |
| DCK4  | Tabbed groups render a **tab strip** whose hit test derives from the same laid-out frames as its paint (the `IXB9`/`actionBar` lesson), with press-arms/release-activates semantics (`STM10`). Middle-click / a close affordance may close a closable pane.                                                                                                                                                                                            | not started | `actionBar` + `PressState` generalize                                      |
| DCK5  | **Drag-to-redock**: dragging a tab (or a group's header) beyond a threshold enters a dock drag that shows **hint zones** (center = stack into the group; N/S/E/W = split that group) and previews the drop; release applies it as a pure `layout → layout` transformation. No floating OS windows — a drag is always a re-dock.                                                                                                                        | not started | new; the layout transformation must be a tested pure function              |
| DCK6  | **Focus** is container-owned (`STM7` + click-to-focus): one focused pane, stamped into each pane's chrome (`Slot.chromeFocused` band, bold title — the established look), with a deterministic traversal order for keyboard focus cycling.                                                                                                                                                                                                             | partial — container-owned `focused`, click-to-focus and `focusNext` traversal; TUI adopted, GUI at `C-2a`-GUI | `workspace.d` focus stamping; `gui.d` `pn.treeFocused` branches            |
| DCK7  | **Wheel routing** is container-owned: a wheel event goes to the pane under the pointer, regardless of focus.                                                                                                                                                                                                                                                                                                                                           | partial — a wheel routes under the pointer, falling back to the focused pane over chrome; TUI adopted | the twice-written pane-under-cursor blocks                                 |
| DCK8  | **Pointer capture** is container-owned: the container runs the one `STM11` value, issues ids to its own affordances (dividers, tab drags, pane scrollviews) and to pane-local draggables via the pane interface, and clears on release. A new affordance takes an id; it cannot join a negation chain because none exists.                                                                                                                             | partial — the container owns the one `CaptureState` and issues pane/divider ids; TUI adopted, the GUI keeps its own ids until `C-2a`-GUI | `InputState.capture` moves inside                                          |
| DCK9  | The container reports the one wanted **pointer shape** per frame — composed from its dividers, tab drags and the focused ScrollViews — and the host writes it once (OSC 22 / raylib cursor).                                                                                                                                                                                                                                                           | partial — `shape(paneGrab, paneHover)` composes dividers with host-supplied pane shapes at the established precedence; TUI adopted | `wantedPointerShape` becomes the container's composition                   |
| DCK10 | Pane **chrome** (header bar with title/center/trailing text, the focus band) comes from the shared components; a pane supplies content and metadata (title, closable, min sizes), never chrome painting.                                                                                                                                                                                                                                               | not started | `drawChromeBar` / TUI `headerBar` calls unify                              |
| DCK11 | A pane's **content contract** is the existing pane shape: `view → WidgetTree` (or a paint callback during migration), `bool handle(Event)` for pane-local input after the container has routed and translated coordinates to pane-local space, plus declared capabilities/min-extent.                                                                                                                                                                  | partial — panes receive routed, translated events via `Route`; constraints live on the layout node, not yet on a pane contract | `PreviewTui`/`ExplorerTui` already fit; GUI panes converge during adoption |
| DCK12 | The container must degrade to **tier-0 targets**: with no pointer at all, splits render at their stored weights, tab switching and focus cycling work from keys alone; drag-only affordances (redock) are simply absent, not broken.                                                                                                                                                                                                                   | not started | `InteractionTier` ladder; HTML target eventually                           |
| DCK13 | **Routing precedence is fixed and container-owned**: pointer capture (`STM11`) first, then the gesture owner mid-recognition, then top layers (popups/overlays, tested front-to-back), then the **positional query** — a pure function over the frame's derived hit data (reverse paint order / culled frame-tree descent). Events route against the **last painted frame's** hit data. See the [hit-testing model](./input.md#the-hit-testing-model). | partial — the precedence is `DockContainer.handle`; TUI adopted, GUI at `C-2a`-GUI | `INP10`                                                                    |

## Milestones

| Milestone | Content                                                                                            | Requirements                           |
| --------- | -------------------------------------------------------------------------------------------------- | -------------------------------------- |
| C-1       | `ScrollView` state + events + both paint paths; hue's four bar sites adopt (doc + tree, GUI + TUI) | `SCV1`–`SCV6`                          |
| C-2a      | Layout value + splits (no tabs yet): both hue hosts' two-pane workspace runs on the container      | `DCK1`–`DCK3`, `DCK6`–`DCK11`, `DCK13` |
| C-2b      | Tabbed groups + tab strips; hue's document set becomes a tabbed group                              | `DCK4`                                 |
| C-2c      | Drag-to-redock with hint zones; layout persistence                                                 | `DCK5`, `DCK2`                         |
| C-2d      | Tier-0 degradation audit                                                                           | `DCK12`                                |

Sequenced ScrollView-first because the dock's panes contain ScrollViews,
and because C-1 alone already deletes the largest duplicated wiring in
hue. The M18 reducer work (see the hue MVU plan) lands **on** these
containers: the application model drives `{layout, per-pane state}` values
instead of hand-wired machines.

## Traces

| Code                                              | Spec                   |
| ------------------------------------------------- | ---------------------- |
| `libs/ui/src/sparkles/ui/state.d` (STM7–11)       | composed, not replaced |
| `libs/ui/src/sparkles/ui/components/` (new files) | `SCV`, `DCK`           |
| `apps/hue/src/workspace.d`, `apps/hue/src/gui.d`  | adoption sites         |
