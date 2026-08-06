# `sparkles:input` — Feature Requirements (`INP`)

_**Status:** partial — the vocabulary, tier ladder, terminal/GPU adapters and
input capability declarations are shipped; widget tier declarations and the
native pointer grab remain open · **Date:** 2026-08-05 · **Scope:** `libs/input` — the abstract,
capability-tiered input vocabulary shared by every `sparkles:ui` target, and
the contracts backend adapters satisfy._

## Design & rationale

Interaction is the other half of "one definition, three targets". It previously
diverged: the terminal had a private SGR-mouse/key model, the GPU host polled its
windowing library directly inside the frame loop, and each interactive backend
hand-rolled hit testing. The shared vocabulary and adapters now translate both
native sources into the same values; the remaining target differences are
declared capabilities, not competing semantic models.

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

| ID   | Requirement                                                                                                                                                                | Status  | Traces to                                                                                                                                                  |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| INP5 | Every interaction must be classified into **tier 0, 1 or 2**, and a widget must declare the highest tier it requires.                                                      | partial | `sparkles.input.tier` `InteractionTier`/`tierOf` (`97f931e5`); the widget declaration lands with the M6 widget model                                       |
| INP6 | A target must **declare** which tiers it serves. Emitting a widget that requires a tier above the target's capability must be a reported degradation, never a silent drop. | partial | `InputCapabilities` is exposed by the terminal/GPU adapters (`IXB10`); widget-side tier declaration/reporting remains [`INP5`](#capability-tiers-inp5inp6) |

## Adapters (`INP7`–`INP9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                        | Status                        | Traces to                                                                                      |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------- | ---------------------------------------------------------------------------------------------- |
| INP7 | The **terminal** library must decode its wire formats (SGR mouse, key sequences) directly into the shared event vocabulary, retiring its private key/modifier/event types. No separate adapter layer is needed there.                                                                                              | full (`b9aeb102`)             | `tui/input.d` (decodes 1-based wire → 0-based `Point`; web-sign wheel deltas incl. horizontal) |
| INP8 | The **GPU** backend must synthesize events from its windowing library's polled state, since that library has no event queue — including press/release edges, drag tracking and wheel deltas.                                                                                                                       | full (`bbf85c7c`, `8837f3e9`) | `ui_raylib.events` `RaylibEvents` (mouse, touch and hardware-key synthesis)                    |
| INP9 | The GPU backend must hold a **real pointer grab for the duration of a drag**, so motion and release are delivered even over window decorations or outside the window. Passive cursor-confinement modes are insufficient; this is a windowing-system concern owned by the adapter, not by application state checks. | not started                   | [`UI-O3`](./open-issues.md#ui-o3)                                                              |

> [!IMPORTANT]
> `INP9` is a known open bug, not a hypothetical: without a grab, a drag released
> over a title-bar button activates that button, and a drag leaving the content
> never sees its release. Application-level mitigations were tried and reverted —
> the decisive events happen in the window manager. Because this bug class evades
> in-process tests entirely, its fix must be validated against the end-to-end
> windowing harness, not unit tests.

## Event detail (`INP11`–`INP14`)

These four shipped with the vocabulary but were never recorded here; the rows are
written from the implementations and their commits, not proposed.

| ID    | Requirement                                                                                                                                                                                                                                                         | Status            | Traces to                                                                    |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------------------------------------------------------- |
| INP11 | A pointer event must carry a **pointer identity**, so multi-touch is expressible in the shared vocabulary at all. Everything above the gesture layer stays single-pointer by construction: a recognizer owns the ids and hands onward only the primary contact.     | full (`401cfba4`) | `sparkles.input.events` `PointerEvent.pointerId`                             |
| INP12 | Wheel deltas must be **cells to scroll, applied by the producer** — never a raw notch count a consumer multiplies again. This is what lets a notchless producer (a touch drag, a pixel-precise trackpad) participate in the same event.                             | full (`d4f531bb`) | `sparkles.input.events` `WheelEvent`, `linesPerNotch`, `precise`             |
| INP13 | The platform spellings of **"go back / dismiss"** must be one equivalence in the vocabulary. The framework owns the equivalence; the application owns the chain it triggers.                                                                                        | full (`401cfba4`) | `sparkles.input.events` `isDismiss` (escape ≡ the Android system back key)   |
| INP14 | A target must declare its **pointer affordances as independent axes** — hover, sub-cell precision, simultaneous contacts — separately from the tier ladder, because touch serves a higher tier than a terminal while lacking hover, which no `<=` test can express. | full (`ed198ddf`) | `sparkles.input.capability` `InputCapabilities` and its four target profiles |

> [!NOTE]
> The touch recognizer (`sparkles.input.gesture`, `2ea120fe`) cites requirement
> IDs `GST1`–`GST5` that exist in no specification page. Recording them is a
> separate reconciliation, not part of this tree.

## Key levels and the per-frame fold (`INP15`–`INP17`)

Proposed. Required by the [application host](../ui-app/index.md) and by migrating
`apps/terminal` onto it — see [P0.3](../ui-app/PLAN.md#phase-0).

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status            | Traces to                                                     |
| ----- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------- |
| INP15 | A key event must carry its **action** (press, repeat, release), the **layout-independent unshifted code point**, and the **text that keystroke produced** — the last **stored inline, not borrowed**, so an event stays a value that can be recorded now and asserted on later ([`INP4`](#event-model-inp1inp4)); modifiers must include the platform "super". A terminal emulator's encoder pairs a key with its text, and a detached text event cannot express that. | full (`9f0ca9ad`) | `sparkles.input.events` `KeyEvent`, `Mods`, `maxKeyText`      |
| INP16 | A target must **declare whether it can report a key release** at all — a terminal cannot. A held-key interaction must consult that declaration and offer another route, rather than working on one target and silently failing on another ([`TGT5`](./backends.md)). The declaration defaults to **absent**, unlike the other capability axes.                                                                                                                         | full (`9f0ca9ad`) | `sparkles.input.capability` `InputCapabilities.keyRelease`    |
| INP17 | The **per-frame fold** — edges versus levels, wheel accumulation, gesture anchors — belongs to this package, not to an application. It must cover every pointer button, modifier level and (where `INP16` allows) held keys, and stay **unit-agnostic**: positions pass through in the producer's own unit.                                                                                                                                                            | full (`12d17717`) | `sparkles.input.frame` (`apps/hue/src/frame_input.d` deleted) |

> [!IMPORTANT]
> `INP15`–`INP17` are additive: the new key fields are **appended**, so every
> existing construction and helper keeps compiling. The fold already existed as a
> pure, tested function inside `apps/hue`, so `INP17` was a move plus a
> generalization, not a new design.
>
> **`INP16` defaults to _absent_, not to the desktop answer**, which is the one
> place these rows say something different from the other capability axes. A key
> release is an **extra event**, not a refinement of a press: a consumer that
> switches on the key alone reads a release as a second press. Defaulting the
> declaration to `true` would therefore have changed what every existing consumer
> sees the moment a producer started synthesizing releases. Undeclared means
> "presses only" — what every producer reported before this existed — and a target
> opts in by declaring it _and_ emitting them.
>
> The same hazard is why `isDismiss` ignores releases: an application that
> dismisses on Escape would otherwise dismiss twice per keystroke, closing a popup
> and then quitting.
>
> **`INP15`'s text is stored inline, not borrowed.** A slice into the producer's
> per-frame buffer would cost the vocabulary [`INP4`](#event-model-inp1inp4) — an
> event you can record and replay cannot hold a pointer with a shorter life than
> itself — and it makes the sum type's assignment `@system` under `dip1000`, which
> would strand every `@safe` consumer. One keystroke is one code point; the cap
> (`maxKeyText`) covers a dead-key or IME composition and truncates beyond.

## Hit testing (`INP10`)

| ID    | Requirement                                                                                                                                                                                                                                       | Status  | Traces to                                                                                                                                                                                                     |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| INP10 | A widget's **hit identity must survive the pipeline** — from the widget, through layout frames, into the display list — so hit testing is done once by the toolkit and every backend consumes the result, instead of each rebuilding its own map. | partial | `state.d` `hoverTargets`/`keyTargets` (`f166e099`) are visibility- and clip-aware and consumed by the shared document tree; non-widget pane/chrome routing remains until the container tier owns it (`DCK13`) |

### The hit-testing model

Positional hit-testing is a **pure query over per-frame derived data**:
the flat hit list (`hoverTargets`/`keyTargets`) scanned in reverse paint
order, or equivalently a culled top-down frame-tree descent. The rules:

- **Hit geometry is derived, never registered.** Hit rects come from the
  same laid-out frames as the paint, computed as a by-product of display-
  list emission with visibility and clips applied — one source, so paint
  and hit cannot drift (the `IXR27` invariant).
- **Hit order is reverse paint order.** Stacking is hierarchical and the
  display list is its ground truth; there is no separate z coordinate.
  Topmost-wins falls out of iterating the list backwards.
- **Targets are indices** (hit ids), not pointers — Regular, lifetime-free,
  assertable in tests.
- **Out-of-bounds content is a top layer.** Popups and overlays, which
  escape their parent's bounds, keep explicit rects and are tested before
  the tree/list, front to back.
- **Events route against the last painted frame's data** — the layout the
  user saw — never against a mid-rebuild state.
- **Positional hits are the last resort in routing precedence**: pointer
  capture (`STM11`) first, then the gesture owner, then top layers, then
  the positional query (see [containers](./containers.md) `DCK13`).
- **Scaling escalation is bounded**: if a profile ever shows the query hot
  (a canvas with ~10⁴+ simultaneously visible targets), the escalation is
  a bucketed uniform grid built from the same derived list, behind the
  same pure query function — an implementation detail, not an
  architecture.

## Milestones

| Milestone | Scope                                                    | Status                                                                        | Requirements    |
| --------- | -------------------------------------------------------- | ----------------------------------------------------------------------------- | --------------- |
| N0        | Package + event vocabulary + tier classification         | full (`97f931e5`; widget declaration in M6)                                   | `INP1`–`INP5`   |
| N1        | Terminal decoding retargeted to the shared vocabulary    | full (`b9aeb102`)                                                             | `INP7`          |
| N2        | Hit identity plumbed through layout and the display list | partial (`f166e099`; shared document consumes it, container routing remains)  | `INP10`         |
| N3        | GPU adapter: event synthesis + pointer grab              | partial (`INP8` full; pointer grab remains [`UI-O3`](./open-issues.md#ui-o3)) | `INP8`, `INP9`  |
| N4        | Declared target tiers, with reported degradation         | partial (`IXB10`; widget declaration/reporting remains)                       | `INP6`          |
| N5        | Key levels, richer key identity, and the per-frame fold  | not started ([P0.3](../ui-app/PLAN.md#phase-0))                               | `INP15`–`INP17` |

## Module coverage

| Source file                                         | Requirements                   |
| --------------------------------------------------- | ------------------------------ |
| `libs/input/src/sparkles/input/`                    | `INP1`–`INP6`, `INP11`–`INP16` |
| `libs/tui/src/sparkles/tui/input.d`                 | `INP7`                         |
| `libs/ui-raylib/src/`                               | `INP8`, `INP9`                 |
| `libs/ui/src/sparkles/ui/state.d`                   | `INP10` (the consumer)         |
| `libs/input/src/sparkles/input/frame.d` _(planned)_ | `INP17`                        |

## Relationship to existing specs

| Piece                                                                                                 | Role in input                                                         |
| ----------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| [state-machines.md](./state-machines.md) `STM`                                                        | the consumers of events — hover, selection, scroll, focus, disclosure |
| [backends.md](./backends.md) `TGT5`                                                                   | declared per-target capabilities, of which input tiers are half       |
| [widgets.md](./widgets.md) `WGT`                                                                      | where a widget declares its required tier                             |
| [ui-app](../ui-app/index.md) `HST`                                                                    | the host that drains these events and folds them per frame (`INP17`)  |
| [End-to-end windowing test harness research](../../research/window-system-integration/e2e-testing.md) | the validation route for `INP9` / [`UI-O3`](./open-issues.md#ui-o3)   |

→ [Overview](./index.md) · [State machines](./state-machines.md) · [Backends](./backends.md)
