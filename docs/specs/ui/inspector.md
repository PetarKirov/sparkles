# `sparkles:ui` inspector — Feature Requirements (`INS`)

_**Status:** partial · **Date:** 2026-08-11 · **Scope:** the generic
**inspector component** (`components/inspector.d`) — an interactive tree of
nodes over a **subject**, with a details pane for the selected node and a
selection contract that lets the host highlight the selected node's extent in
the subject — plus its adapters, starting with the toolkit's own widget tree._

## Design & rationale

Every structure inspector shares one shape: Chromium's Elements panel, Visual
Studio's Live Visual Tree, and neovim's `:InspectTree` are each a **tree pane
beside a subject**, where moving through the tree highlights the corresponding
extent in the subject, selecting a node answers questions about it, and the
whole thing is a debugging aid that must never perturb what it inspects. The
component states that shape once; everything subject-specific is an
**adapter**:

- The **tree** is the shared interactive component
  ([`VMD7`](./widgets.md)) — cursor, disclosure, viewport, filter — over a
  `TreeData` whose node type carries the view's DbI capabilities (`label`,
  `slot`, `badge`, …). The inspector adds no second tree.
- The **selection contract** is one value: the host reads the tree's selected
  node and asks its adapter what **extent** it covers — a layout rect for a
  widget tree, a byte range for a syntax tree. The component never learns what
  an extent is; the host interprets it (tint a rect, tint a source range).
- The **details pane** is an adapter capability by presence: an adapter with
  `details(node)` gets a pane; one without simply has none (neovim parity —
  its inspector is tree-only, the details riding in each line).
- The **header** carries a title and host-supplied **toggle actions** as data
  (label + active + hit id) — hover-sync on/off, anonymous nodes, whatever
  the host binds — so the panel's chrome needs no per-host view code.
- The **sync contract** is bidirectional and host-owned: subject position →
  tree selection (hover-driven where a pointer exists, else the host's
  position idiom), and tree selection → subject extent highlight, with
  scroll-follow **only when the extent is fully off-screen** (the detail that
  makes neovim's panel pleasant instead of jumpy).

The **north star** is DevTools-grade genericity: a user should eventually be
able to build an inspector over any tree-shaped third-party system (an HTML
app, a scene graph, a remote process). What that adds is an **asynchronous /
remote node provider**; v1 is deliberately synchronous and in-process, with
the lazy-children seam ([`VMD5`](./widgets.md)) as the named extension point —
the API must not bake in "the whole tree is in memory" beyond that seam.

**Deferred by decision:** the _inspect-from-context-menu_ entry (right-click /
long-press a position in a subject → "Inspect node") waits on the
anchored-overlay primitive (`docs/specs/ui/popup.md`, in research); until it
lands, hosts bind inspect-at-position through their keymaps.

## Requirements (`INS`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                      | Status                                                                                                                                                                                                             | Traces to                                                                  |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------- |
| INS1 | The inspector must be **one component** — header (title + host-supplied toggle actions as data) · the shared interactive tree (`VMD7`) · an optional details pane — rendered as a fixed-width, clip-guarded column an embedding pane can host.                                                                   | full (`72765ef6`)                                                                                                                                                                                                  | `components/inspector.d` `inspectorView`, `InspectorAction`                |
| INS2 | The **selection contract** must be adapter-defined: the host reads the selected tree node and resolves its **extent** through the adapter; the component itself never names an extent type — that is what lets one component serve layout rects and byte ranges alike.                                           | full (`72765ef6`)                                                                                                                                                                                                  | `WidgetInspect.extentOf` (rect); a syntax adapter's byte range (hue `TSI`) |
| INS3 | The **details pane** must be an adapter capability **by presence** (`details(node)` → key/value rows), never a required interface; a tree-only adapter renders a tree-only panel.                                                                                                                                | full (`72765ef6`)                                                                                                                                                                                                  | `DetailRow`; `WidgetInspect.details`                                       |
| INS4 | A **widget-tree adapter** must ship with the toolkit, so any `sparkles:ui` application can inspect its own laid-out widget tree — kind + key labels, resolved-size badges, details (kind/rect/text/key/hit/slot) answered from the **same frames the subject painted with**.                                     | full (`72765ef6`) — the gallery's `\|` panel is the first mount (`756e4643`)                                                                                                                                       | `inspectWidgets`, `WidgetInspectNode`; `apps/ui-gallery/src/inspector.d`   |
| INS5 | A **plain-text target** must render the same flattened rows as guide-railed indented text (logging, goldens, non-interactive sinks); an adapter may define a richer serialization of its own (the tree-sitter inspector emits neovim-compatible query syntax).                                                   | full (`72765ef6`)                                                                                                                                                                                                  | `writeTreeText` / `treeText`; hue `TSI`'s S-expression emitter (planned)   |
| INS6 | The **sync contract**: while an inspector is open, subject position drives tree selection (pointer hover where one exists, else the host's position idiom), toggleable from the header; tree selection drives an extent highlight in the subject, scroll-following **only when the extent is fully off-screen**. | full (`8dc7128c`) — hue's tree-sitter inspector: hover-driven on both backends (dedup per pointer move, the `[sync]` chip disables), extent tint + off-screen-only scroll-follow via the viewer's identity channel | host wiring over `INS1`/`INS2`; hue `foldAtCursor` idiom                   |
| INS7 | **Inspect-from-context-menu**: with the inspector closed, a context action on a subject position opens it and reveals the node at that position.                                                                                                                                                                 | deferred — waits on the anchored-overlay primitive (`popup.md`, in research); keymap-bound inspect lands first                                                                                                     | future `popup.md` menu; host keymaps                                       |
| INS8 | The node-provider seam must admit **asynchronous / remote subjects** (DevTools over another process) without changing consumers; v1 is synchronous and in-process by decision, with lazy children (`VMD5`) as the extension point.                                                                               | researched — a design constraint on `INS1`–`INS3`, not yet an implementation                                                                                                                                       | `VMD5` lazy provider; future remote adapter                                |

## Milestones

| Milestone | Scope                                                                                            | Status            | Requirements  |
| --------- | ------------------------------------------------------------------------------------------------ | ----------------- | ------------- |
| N0        | The component + the widget-tree adapter + the gallery panel mount                                | full (`756e4643`) | `INS1`–`INS5` |
| N1        | The sync contract, proven by hue's tree-sitter inspector (`TSI` / [`TVU2`](../hue/tree-view.md)) | not started       | `INS6`        |
| N2        | Context-menu entry (after the anchored-overlay primitive)                                        | deferred          | `INS7`        |
| N3        | Async/remote provider                                                                            | deferred          | `INS8`        |

## Module coverage

| Source file                                      | Requirements                                                |
| ------------------------------------------------ | ----------------------------------------------------------- |
| `libs/ui/src/sparkles/ui/components/inspector.d` | `INS1`–`INS5`                                               |
| `apps/ui-gallery/src/inspector.d`                | the first mount (`INS4`); [`UGL21`](../ui-gallery/index.md) |

## Relationship to existing specs

| Piece                                            | Role                                                                 |
| ------------------------------------------------ | -------------------------------------------------------------------- |
| [widgets.md](./widgets.md) `WGT12`/`VMD1`–`VMD7` | the tree component the inspector composes                            |
| [hue tree-view.md](../hue/tree-view.md) `TVU2`   | the tree-sitter inspector — the component's second adapter           |
| [hue overlays.md](../hue/overlays.md) `TSI`      | what that adapter must show (node type, field, extent, S-expression) |
| `popup.md` _(in research)_                       | the anchored-overlay primitive behind `INS7`'s context menu          |
| [ui-gallery](../ui-gallery/index.md) `UGL21`     | the shell panel hosting the first mount                              |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Containers](./containers.md)
