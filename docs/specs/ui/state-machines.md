# `sparkles:ui` state machines — Feature Requirements (`STM`)

_**Status:** partial · **Date:** 2026-08-05 · **Scope:** level 1 of the toolkit —
presentation-free behavior: the logic of a widget with no idea how it is drawn._

## Design & rationale

A state machine here is pure logic over abstract input, producing state and
derived geometry in abstract units. It makes no draw calls, knows nothing of
pixels or cells, and is testable in isolation.

The reason to insist on this is empirical. Where behavior has been written per
backend, it has **diverged** — two scrollbars with different thumb-position
formulas scroll the same document differently; one copy affordance flashes its
confirmation on a timer while another holds it until the next event. Each is
locally correct and the product is incoherent, which is the catalog's point that
correctness does not compose, and the interface-honesty rule that a UI must not
report the same state two different ways.

Two shapes recur and are required:

- **Transformations, not mutations.** A machine advances by `step(state, input) →
state`, a pure state transition; the caller assigns the result. Pure queries
  may produce a different result type, and the paint/I/O boundary remains an
  action. Timers are not bare counters decremented at the call site.
- **Modes, not sentinel values.** "Indeterminate" is a state, not a magic number;
  "no selection" is a state, not `-1`.

## Requirements

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                               | Status            | Traces to                                                                                                                                            |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| STM1  | A state machine must be **fully presentation-independent**: pure logic over abstract input producing state plus derived geometry in abstract units, with no draw calls and no device units. `@safe`, ideally `@nogc`, and testable with no canvas.                                                                                                                        | full (`49fa8e50`) | `state.d`                                                                                                                                            |
| STM2  | **Scrollbar** — `(contentExtent, viewportExtent, offset, trackExtent) → (thumbStart, thumbExtent)` plus hover and drag state. One definition, integer-exact, covered by property-based tests asserting the thumb stays within the track at every input.                                                                                                                   | full (`49fa8e50`) | `state.d` `scrollbarThumb`/`ScrollState` (incl. the inverse track-drag mapping)                                                                      |
| STM3  | **Selection** — one Regular value with a normalized anchor/focus invariant, expressed so the standard selection algorithms apply to it. Every backend renders it; none owns it.                                                                                                                                                                                           | full (`49fa8e50`) | `state.d` `Selection!T` (any ordered position type)                                                                                                  |
| STM4  | **Hover** — topmost hit wins; reports whether the hot element changed, so a caller can repaint only on change. Requires hit identity to reach the display list. Identity comes at two granularities: `hitId` **groups** (a whole popup, a whole row), `key` singles out **one element** — a row of markers shares a group, so only `key` can say which one a click meant. | full (`f166e099`) | `state.d` `HoverState` + `hoverTargets` (by `hitId`) / `keyTargets` + `keyAt` (by `key`); [`INP10`](./input.md)                                      |
| STM5  | **Disclosure** — a generic opened/collapsed set over a Regular key, serving **both** tree expand/collapse (keyed by node path) and content folding (keyed by source span). Written once, used by both.                                                                                                                                                                    | full (`49fa8e50`) | `state.d` `DisclosureState!Key` (default polarity + exception set; `zR`/`zM` are O(1) resets)                                                        |
| STM6  | **Timeline** — a small mode machine for transient effects (idle / in / hold / out) advanced by `step(state, dt)`, replacing hand-decremented counters. Backends with no frame clock may collapse it to an event-scoped mode without changing the caller.                                                                                                                  | full (`49fa8e50`) | `state.d` `Timeline` (`holdUntilDismissed` + `dismissed()` is the event-scoped collapse)                                                             |
| STM7  | **Focus** — which element has keyboard focus, with a deterministic traversal order, so keyboard navigation is defined once rather than per backend.                                                                                                                                                                                                                       | full (`49fa8e50`) | `state.d` `FocusState`                                                                                                                               |
| STM8  | **Pane splitter** — a draggable divider between two panes as a value: grab, grab-relative drag with `[min, max]` clamping, release, and a post-resize re-clamp. Unit-agnostic (cells or pixels), so every backend runs the same drag.                                                                                                                                     | full              | `state.d` `SplitState`                                                                                                                               |
| STM9  | **Scrollbar machine** — the whole bar as one value over STM2: axis (vertical/horizontal), the grab-relative interaction (a thumb press grabs in place, a track press jumps, drags move relative to the grab and own the pointer until release), hover, and the wanted pointer shape by axis. Both panes and every backend run this machine; none re-implements a grab.    | full              | `state.d` `ScrollbarState`; consumed by `apps/hue` `tui.d`/`explorer.d`; the machine-driven `scrollbar` component overload ([`WGT10`](./widgets.md)) |
| STM10 | **Press / activation** — a press arms an addressable target, a release **over the same target** activates it, a release elsewhere cancels. Ids are hit ids, so a target cannot be armed by one geometry and activated by another; the activation is transient, consumed by the next press.                                                                                | full              | `state.d` `PressState`; the `actionBar` component ([`WGT15`](./widgets.md) in part)                                                                  |
| STM11 | **Pointer capture** — press owns the drag: the affordance that took the press keeps every motion and the release wherever the pointer strays. `available(id)` asks _may I act?_ (free, or already mine), so a new affordance participates by taking an id rather than by being added to every other affordance's negation chain.                                          | full              | `state.d` `CaptureState`; `apps/hue` `workspace.d`                                                                                                   |
| STM12 | Machines must be **Regular values** — comparable with logically independent copies — so a view's behavior can be snapshotted, replayed and diffed in tests.                                                                                                                                                                                                               | partial           | scalar and immutable-payload machines comply; `DisclosureState.exceptions` still exposes slice aliasing ([`UI-O1`](./open-issues.md#ui-o1))          |

> [!NOTE]
> The machines are shipped and the document/explorer paths consume the shared
> scrollbar, selection, disclosure, timeline and capture definitions. Remaining
> application-owned composition and paint are not second state machines; they are
> tracked as [`HUE-O1`](../hue/open-issues.md#hue-o1) and
> [`HUE-O2`](../hue/open-issues.md#hue-o2).

> [!NOTE]
> `STM5` is one machine serving two features that look unrelated. A tree's
> "which nodes are expanded" and a document's "which regions are folded" are the
> same question over different keys, and implementing them separately would
> reintroduce the divergence `PRN8` forbids.

## Milestones

| Milestone | Scope                                                           | Status                                                                            | Requirements   |
| --------- | --------------------------------------------------------------- | --------------------------------------------------------------------------------- | -------------- |
| S0        | Hover wired to real hit identity                                | full (`f166e099`)                                                                 | `STM4`         |
| S1        | Scrollbar and selection lifted from per-backend implementations | full (`23fab77e`) — one thumb/drag formula and one selection model across TUI+GUI | `STM2`, `STM3` |
| S2        | Disclosure, shared by tree and folding                          | full (`9fc03551`) — consumed by the explorer (tree) and folding (both backends)   | `STM5`         |
| S3        | Timeline, replacing ad-hoc counters                             | full — copied-flash, toast and hover-fade all `Timeline`                          | `STM6`         |
| S4        | Focus and keyboard traversal order                              | partial (`49fa8e50`; keyboard nav wires up in M9)                                 | `STM7`         |

## Module coverage

| Source file                       | Requirements   |
| --------------------------------- | -------------- |
| `libs/ui/src/sparkles/ui/state.d` | `STM1`–`STM12` |

## Relationship to existing specs

| Piece                                          | Role                                                                |
| ---------------------------------------------- | ------------------------------------------------------------------- |
| [input.md](./input.md) `INP`                   | the events these machines consume; `INP10` unblocks `STM4`          |
| [widgets.md](./widgets.md) `WGT`               | the views that render each machine's state                          |
| [layout.md](./layout.md) `LAY7`                | consumes the scroll offset `STM2` owns                              |
| [principles.md](./principles.md) `PRN7`–`PRN9` | the state-transition, shared-semantics and model rules these embody |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Input](./input.md)
