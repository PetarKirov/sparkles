# `sparkles:input` — Feature Requirements (`INP`)

_**Status:** partial — the vocabulary, the tier ladder and the terminal
adapter are shipped; the GPU adapter and declared target tiers are M7 work ·
**Date:** 2026-07-29 · **Scope:** `libs/input` — the abstract,
capability-tiered input vocabulary shared by every `sparkles:ui` target, and
the contracts backend adapters satisfy._

## Design & rationale

Interaction is the other half of "one definition, three targets", and it is
currently unbuilt. `sparkles:ui` declares pointer, wheel and key event types that
**nothing in the repository ever constructs**. Meanwhile the terminal library has
a complete SGR-mouse and key model the toolkit cannot see, the GPU backend polls
its windowing library directly inside the frame loop, and the HTML target has no
event model at all. The visible consequence is that the shipped hover state
machine has zero consumers and each interactive backend hand-rolls its own
hit-testing.

`sparkles:input` fixes the shape rather than the symptom: **events are values**,
in one vocabulary, in a package both the toolkit and the terminal library can
depend on. Value-based notification is also what the architecture catalog
prescribes over callback webs.

### Why a capability ladder

The three targets are not equally capable, and the binding constraint is
pure-CSS HTML: static output can express hover, focus and toggling with no
script, but cannot express a drag. Rather than let that degrade silently, the
model is **explicitly tiered**, and a widget declares the tier it needs.

| Tier | Interactions                                                    | Served by                                                                                      |
| ---- | --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| 0    | hover, focus, toggle/checked, disclosure                        | **every** target, including pure-CSS HTML (`:hover`, `:focus-within`, `:checked`, `<details>`) |
| 1    | key events, text input, pointer press/release/drag, wheel       | interactive targets (GUI, TUI)                                                                 |
| 2    | sub-cell pointer precision, continuous drag, time-based effects | pixel targets only                                                                             |

This makes the "prefer pure CSS, add script only when unavoidable" rule
**checkable** — the HTML emitter can refuse to silently drop a tier-1
interaction — instead of aspirational.

## Event model (`INP1`–`INP4`)

| ID   | Requirement                                                                                                                                                                                                      | Status            | Traces to                                                                                                          |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------------------------------------------------------ |
| INP1 | Input must be modelled as **values** in a single vocabulary — key with modifiers, text input, pointer press/release/move/drag, wheel, focus change, resize — not as callbacks registered on widgets.             | full (`97f931e5`) | `sparkles.input.events` `Event` (a sum type — no `kind` + dead fields)                                             |
| INP2 | The vocabulary must live in a package depending on **`sparkles:base` only** (plus `sparkles:math` import-only for the position type), so both `sparkles:ui` and `sparkles:tui` can depend on it without a cycle. | full (`97f931e5`) | `libs/input/dub.sdl` (incl. the source-included test-runner recipe)                                                |
| INP3 | The position type must be the **same type** the toolkit's geometry uses, so no conversion is needed at the boundary.                                                                                             | full (`97f931e5`) | `sparkles.input.events` `Point` ≡ `ui.geometry.Point`; positions are 0-based toolkit cells, converted by producers |
| INP4 | Events must be **Regular values** — copyable, comparable — so they can be recorded, replayed and asserted in tests without a live terminal or window.                                                            | full (`97f931e5`) | whole-event equality assertions in `tui/integration.d`                                                             |

## Capability tiers (`INP5`–`INP6`)

| ID   | Requirement                                                                                                                                                                | Status      | Traces to                                                                                                            |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------- |
| INP5 | Every interaction must be classified into **tier 0, 1 or 2**, and a widget must declare the highest tier it requires.                                                      | partial     | `sparkles.input.tier` `InteractionTier`/`tierOf` (`97f931e5`); the widget declaration lands with the M6 widget model |
| INP6 | A target must **declare** which tiers it serves. Emitting a widget that requires a tier above the target's capability must be a reported degradation, never a silent drop. | not started | [backends.md](./backends.md) `TGT5`                                                                                  |

## Adapters (`INP7`–`INP9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                        | Status            | Traces to                                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ---------------------------------------------------------------------------------------------- |
| INP7 | The **terminal** library must decode its wire formats (SGR mouse, key sequences) directly into the shared event vocabulary, retiring its private key/modifier/event types. No separate adapter layer is needed there.                                                                                              | full (`b9aeb102`) | `tui/input.d` (decodes 1-based wire → 0-based `Point`; web-sign wheel deltas incl. horizontal) |
| INP8 | The **GPU** backend must synthesize events from its windowing library's polled state, since that library has no event queue — including press/release edges, drag tracking and wheel deltas.                                                                                                                       | not started       | proposed `ui-raylib` input adapter                                                             |
| INP9 | The GPU backend must hold a **real pointer grab for the duration of a drag**, so motion and release are delivered even over window decorations or outside the window. Passive cursor-confinement modes are insufficient; this is a windowing-system concern owned by the adapter, not by application state checks. | not started       | proposed `ui-raylib` pointer grab                                                              |

> [!IMPORTANT]
> `INP9` is a known open bug, not a hypothetical: without a grab, a drag released
> over a title-bar button activates that button, and a drag leaving the content
> never sees its release. Application-level mitigations were tried and reverted —
> the decisive events happen in the window manager. Because this bug class evades
> in-process tests entirely, its fix must be validated against the end-to-end
> windowing harness, not unit tests.

## Hit testing (`INP10`)

| ID    | Requirement                                                                                                                                                                                                                                       | Status      | Traces to                                                |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------- |
| INP10 | A widget's **hit identity must survive the pipeline** — from the widget, through layout frames, into the display list — so hit testing is done once by the toolkit and every backend consumes the result, instead of each rebuilding its own map. | not started | `widget.d` `hitId`; `layout.d` `Frame`; `display_list.d` |

## Milestones

| Milestone | Scope                                                    | Status                                      | Requirements   |
| --------- | -------------------------------------------------------- | ------------------------------------------- | -------------- |
| N0        | Package + event vocabulary + tier classification         | full (`97f931e5`; widget declaration in M6) | `INP1`–`INP5`  |
| N1        | Terminal decoding retargeted to the shared vocabulary    | full (`b9aeb102`)                           | `INP7`         |
| N2        | Hit identity plumbed through layout and the display list | not started                                 | `INP10`        |
| N3        | GPU adapter: event synthesis + pointer grab              | not started                                 | `INP8`, `INP9` |
| N4        | Declared target tiers, with reported degradation         | not started                                 | `INP6`         |

## Module coverage

| Source file                         | Requirements           |
| ----------------------------------- | ---------------------- |
| `libs/input/src/sparkles/input/`    | `INP1`–`INP6`          |
| `libs/tui/src/sparkles/tui/input.d` | `INP7`                 |
| `libs/ui-raylib/src/`               | `INP8`, `INP9`         |
| `libs/ui/src/sparkles/ui/state.d`   | `INP10` (the consumer) |

## Relationship to existing specs

| Piece                                          | Role in input                                                         |
| ---------------------------------------------- | --------------------------------------------------------------------- |
| [state-machines.md](./state-machines.md) `STM` | the consumers of events — hover, selection, scroll, focus, disclosure |
| [backends.md](./backends.md) `TGT5`            | declared per-target capabilities, of which input tiers are half       |
| [widgets.md](./widgets.md) `WGT`               | where a widget declares its required tier                             |
| End-to-end windowing test harness research     | the validation route for `INP9`                                       |

→ [Overview](./index.md) · [State machines](./state-machines.md) · [Backends](./backends.md)
