# `sparkles:ui` state machines — Feature Requirements (`STM`)

_**Status:** partial · **Date:** 2026-07-29 · **Scope:** level 1 of the toolkit —
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
state`, a pure function; the caller assigns the result. Timers are not bare
  counters decremented at the call site.
- **Modes, not sentinel values.** "Indeterminate" is a state, not a magic number;
  "no selection" is a state, not `-1`.

## Requirements

| ID   | Requirement                                                                                                                                                                                                                                              | Status            | Traces to                                                                                     |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | --------------------------------------------------------------------------------------------- |
| STM1 | A state machine must be **fully presentation-independent**: pure logic over abstract input producing state plus derived geometry in abstract units, with no draw calls and no device units. `@safe`, ideally `@nogc`, and testable with no canvas.       | full (`49fa8e50`) | `state.d`                                                                                     |
| STM2 | **Scrollbar** — `(contentExtent, viewportExtent, offset, trackExtent) → (thumbStart, thumbExtent)` plus hover and drag state. One definition, integer-exact, covered by property-based tests asserting the thumb stays within the track at every input.  | full (`49fa8e50`) | `state.d` `scrollbarThumb`/`ScrollState` (incl. the inverse track-drag mapping)               |
| STM3 | **Selection** — one Regular value with a normalized anchor/focus invariant, expressed so the standard selection algorithms apply to it. Every backend renders it; none owns it.                                                                          | full (`49fa8e50`) | `state.d` `Selection!T` (any ordered position type)                                           |
| STM4 | **Hover** — topmost hit wins; reports whether the hot element changed, so a caller can repaint only on change. Requires hit identity to reach the display list.                                                                                          | full (`f166e099`) | `state.d` `HoverState` + `hoverTargets`; [`INP10`](./input.md)                                |
| STM5 | **Disclosure** — a generic opened/collapsed set over a Regular key, serving **both** tree expand/collapse (keyed by node path) and content folding (keyed by source span). Written once, used by both.                                                   | full (`49fa8e50`) | `state.d` `DisclosureState!Key` (default polarity + exception set; `zR`/`zM` are O(1) resets) |
| STM6 | **Timeline** — a small mode machine for transient effects (idle / in / hold / out) advanced by `step(state, dt)`, replacing hand-decremented counters. Backends with no frame clock may collapse it to an event-scoped mode without changing the caller. | full (`49fa8e50`) | `state.d` `Timeline` (`holdUntilDismissed` + `dismissed()` is the event-scoped collapse)      |
| STM7 | **Focus** — which element has keyboard focus, with a deterministic traversal order, so keyboard navigation is defined once rather than per backend.                                                                                                      | full (`49fa8e50`) | `state.d` `FocusState`                                                                        |
| STM8 | **Pane splitter** — a draggable divider between two panes as a value: grab, grab-relative drag with `[min, max]` clamping, release, and a post-resize re-clamp. Unit-agnostic (cells or pixels), so every backend runs the same drag.                    | full              | `state.d` `SplitState`                                                                        |
| STM8 | Machines must be **Regular values** — copyable, comparable — so a view's behavior can be snapshotted, replayed and diffed in tests.                                                                                                                      | full (`49fa8e50`) | every machine; snapshot/replay asserted in the disclosure test                                |

> [!NOTE]
> The machines are shipped; their **per-backend counterparts still stand** until
> the hue chrome port (M9) replaces them — the two scrollbar formulas, the three
> selection models, the four bare timers. Each machine's first consumer migration
> is that milestone's work; until then the divergence is contained, not removed.

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

| Source file                       | Requirements  |
| --------------------------------- | ------------- |
| `libs/ui/src/sparkles/ui/state.d` | `STM1`–`STM8` |

## Relationship to existing specs

| Piece                                          | Role                                                       |
| ---------------------------------------------- | ---------------------------------------------------------- |
| [input.md](./input.md) `INP`                   | the events these machines consume; `INP10` unblocks `STM4` |
| [widgets.md](./widgets.md) `WGT`               | the views that render each machine's state                 |
| [layout.md](./layout.md) `LAY7`                | consumes the scroll offset `STM2` owns                     |
| [principles.md](./principles.md) `PRN7`–`PRN9` | the transformation and property-model rules these embody   |

→ [Overview](./index.md) · [Widgets](./widgets.md) · [Input](./input.md)
