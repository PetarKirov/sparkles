# Keymap & lantern — Feature Requirements (the binding table and the key guide)

_**Status:** partial — the table vocabulary, the resolution machinery, the
prefix machine and the panel shipped (built in `apps/hue` as `c19bb926`…
`8ec10bee`, extracted here behaviour-identically) · **Date:** 2026-08-18 ·
**Scope:** the toolkit's **keyboard-policy layer** — bindings as data, the
resolution algorithms that read them in both directions, and **lantern**, the
which-key-style guide that lights up after a prefix._

> [!NOTE]
> Inspired by [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim).
> The `KEY*` and `LTN*` requirement rows below **moved from
> [`docs/specs/hue/lantern.md`](../hue/lantern.md)** with the machinery they
> specify; their statuses and history are preserved, and hue remains the first
> consumer (its policy — the leader map — stays specced there as `LMP*`).
> Status legend and ID conventions: see the [overview](./index.md).

## Why this lives in the toolkit

An application's keyboard policy used to be an `if`/`else` chain in a frame
loop: untestable by construction, unreadable by any guide, and impossible to
overlay with configuration. hue solved this for itself — one `immutable`
table, read forwards by `resolve` and backwards by `bindingsAt`, driving a
pure prefix machine and one panel for every backend. But the machinery was
welded to hue's payload types, and the next applications (`ui-gallery`,
`diagram`) hand-roll the same routing today, describing their keymaps two and
three times over.

So the machinery is the framework's, and the payloads are the application's:

- the app declares a **command enum** (`Cmd.init` means "not bound"), a
  **scope enum** whose declaration order is the resolution precedence, a
  **context type** carrying the policy hooks, and the **table**;
- the framework owns the vocabulary (`Chord`, `ShiftReq`), the normalisation,
  the matching rules, the resolution algorithms, the prefix machine, and the
  panel.

Two marker UDAs on the scope enum's members carry what an `if` chain
expressed by `return`ing: `@terminalScope` (an active scope ends resolution
whether or not it matched) and `@hidesLaterScopes` (while reachable, nothing
below it may be listed). Four optional members on the context type —
`reachable`/`scopeActive`/`bits`/`editing` — are discovered by introspection
with safe defaults, so a bare context still resolves a flat table.

## The binding table (`KEY`)

| ID      | Requirement                                                                                                                                                                                                                                                                                                     | Status            | Traces to                                                                                          |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | -------------------------------------------------------------------------------------------------- |
| `KEY1`  | An application's keyboard policy must be **one `immutable` table**, and every backend must resolve keys through it. No backend may carry a key `switch` of its own.                                                                                                                                             | full (`e71a9417`) | `keymap.hueBindings`; hue's `gui.d`/`tui.d`/`explorer.d` dispatch                                  |
| `KEY2`  | `commandFor`/`resolve` must be a **lookup** over that table, walking the scope enum in declaration order; that order is the resolution precedence, and an active `@terminalScope` ends the search whether or not it matched.                                                                                    | full (`c19bb926`) | `sparkles.ui.keymap.resolve`; `terminalScope`                                                      |
| `KEY3`  | `bindingsAt` must **enumerate** the bindings reachable in a context under a prefix, in resolution order, with a shadowed duplicate dropped rather than listed twice. Whatever it lists, `resolve` must do.                                                                                                      | full (`c19bb926`) | `sparkles.ui.keymap.bindingsAt`; `ui.keymap.bindingsAtEnumeratesWhatWouldFire`                     |
| `KEY4`  | A binding must state its own **context gate** (`require`/`forbid` bits) and its **input-mode** requirement, so a caller never post-filters the table.                                                                                                                                                           | full (`c19bb926`) | `Binding.require`/`forbid`/`mode`; `gated`                                                         |
| `KEY5`  | A chord must carry a three-valued **Shift requirement**. `j` scrolls whether or not Shift is held; `r` refreshes only unshifted and `R` re-roots only shifted. A two-state encoding would depend on table order.                                                                                                | full (`c19bb926`) | `ShiftReq`; hue's `keymap.shiftIsPartOfTheBinding`                                                 |
| `KEY6`  | A chord may span a **contiguous code-point range**, so `z1`–`z9` is one row (and one guide item) whose argument is derived from which key landed.                                                                                                                                                               | full (`c19bb926`) | `Chord.chEnd`; `ui.keymap.groupsDescendAndRangesCarryTheArgument`                                  |
| `KEY7`  | Key events must be **normalised once** — a shifted letter arrives as the shifted character from raylib, as a bare capital from a terminal, or as lowercase + Shift from a synthesised event, and all three mean one keystroke.                                                                                  | full (`c19bb926`) | `sparkles.ui.keymap.normalise`; `ui.keymap.shiftedLettersNormaliseAcrossProducers`                 |
| `KEY8`  | A row must be **spelled in normalised form** — never an uppercase letter, which `normalise` can never produce, so such a row is unreachable. This must be checked, not remembered.                                                                                                                              | full (`cbec2dbb`) | hue's `keymap.tableIsSpelledInNormalisedForm`                                                      |
| `KEY9`  | A modifier a chord does **not** name must be ignored, not required absent — `Ctrl-Up` scrolls because `Up` binds scrolling and says nothing about Ctrl. Safe because a Ctrl-chord scope is `@terminalScope`.                                                                                                    | full (`c19bb926`) | `sparkles.ui.keymap.matches`                                                                       |
| `KEY10` | Prefix comparison must accept a shift-agnostic row (`acceptsTyped`), while de-duplication stays exact (`sameKey`) — `g` opens a group and `Shift-G` jumps to the bottom, and both must be listed and both reachable.                                                                                            | full (`8e4b0250`) | `sparkles.ui.keymap.acceptsTyped`; `sparkles.ui.lantern.chordOf`                                   |
| `KEY11` | Every backend's dispatch must be a **`final switch`** over the command enum with explicit arms — including empty ones — so a new command is a compile error until each backend decides whether it answers it.                                                                                                   | full (`e71a9417`) | hue's `gui.d`, `tui.handleKey`, `explorer.handleCommand`                                           |
| `KEY12` | The table must be **overlayable by configuration**: a user table rebinds individual rows without replacing the rest, and `null` unbinds.                                                                                                                                                                        | not started       | [hue config.md](../hue/config.md) `CFG6`                                                           |
| `KEY13` | The machinery must be **application-agnostic**: `Binding!(Cmd, Scope)` over the app's enums, every entry point taking the table as a parameter, the context hooks optional with safe defaults, and "open the guide" expressed as table data (`Binding.reveal`) rather than a command the machine knows by name. | full              | `sparkles.ui.keymap`; `ui.keymap.hooksAreOptional`; `ui.lantern.revealRowOpensThePanelImmediately` |

## The guide (`LTN`)

| ID      | Requirement                                                                                                                                                                                                                             | Status            | Traces to                                                                                       |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------------------------------------------------------------- |
| `LTN1`  | A **pure state machine** must own the pending key path and whether the panel is showing — no window, no timer, no frame loop — so the whole guide is checkable in a unittest.                                                           | full (`cbec2dbb`) | `sparkles.ui.lantern.LanternState`/`step`                                                       |
| `LTN2`  | A prefix must **descend** rather than execute, and a leaf must execute and end the sequence. A key that names nothing under the prefix must end the sequence **without running** — the "an unrecognised key disarms" rule, stated once. | full (`cbec2dbb`) | `step`; `ui.lantern.unrecognisedKeyEndsTheSequenceWithoutRunning`                               |
| `LTN3`  | The machine must distinguish **`unbound`** from **`consumed`**, so a host can tell "the guide declined this" from "the guide handled it"; collapsing them would silently eat every key the app has not bound.                           | full (`cbec2dbb`) | `StepKind`; `ui.lantern.unboundKeysStaySeparateFromConsumedOnes`                                |
| `LTN4`  | The panel must appear after a **delay measured in wall time** (default 200 ms), and the machine must report how long remains, so a terminal can use it as a poll timeout and open the panel with no keystroke to wake it.               | full (`8ec10bee`) | `tick`/`untilShown`; hue `workspace.d` loop deadline                                            |
| `LTN5`  | The panel must be a **`sparkles:ui` widget tree**, painted by every interactive backend from one definition (`UIA2`), and must sit over everything else — it is a transient answer, not part of the document.                           | full (`8ec10bee`) | `components.lantern_view.viewLantern`; hue `gui.d`, `tui.paintLantern`                          |
| `LTN6`  | Items must be packed into as many **side-by-side columns** as the width affords, reflowing on resize; a set larger than the panel must **scroll**, never be silently truncated.                                                         | full (`91054510`) | `packBoxes`/`BoxLayout.capacity`; `ui.lantern_view.boxesFillTheWidth`                           |
| `LTN7`  | Panel text must be **borrowed from a caller-owned arena**, written in full before any of it is sliced — a growing buffer moves, and a stale slice renders another item's text with nothing to assert against.                           | full (`91054510`) | `LabelArena`; `ui.lantern_view.everyLabelSurvivesTheArenaGrowing`                               |
| `LTN8`  | A **prefix node must be visibly marked** (`+name`) so a reader can tell "this runs something" from "this opens a menu" before pressing it.                                                                                              | full (`91054510`) | group marker; `ui.lantern_view.groupsAreMarkedAndCommandsAreNot`                                |
| `LTN9`  | The panel's own keys must be live **only while a sequence is pending**: Escape abandons it, Backspace steps back one level, `Ctrl-D`/`Ctrl-U` scroll. Backspace at rest belongs to the host.                                            | full (`cbec2dbb`) | `step`; hue's `lantern.escapeAndBackspaceNavigateTheSequence`                                   |
| `LTN10` | **Always-available** bindings (the first-declared scope) must outrank a pending prefix, so a half-typed sequence can never trap the reader in a fullscreen window.                                                                      | full (`cbec2dbb`) | `resolveAlways`; `ui.lantern.alwaysBindingsOutrankAPendingPrefix`                               |
| `LTN11` | A designated binding (hue: `<leader>?`) must show **every binding live in this context** immediately, with no delay — the "I don't know what I'm looking for" door. The row carries it (`Binding.reveal`); the machine consumes it.     | full (`cbec2dbb`) | `Binding.reveal`; `ui.lantern.revealRowOpensThePanelImmediately`                                |
| `LTN12` | The guide must be **inert while a line editor owns the keyboard** — a leader must not open a menu in the middle of a search query.                                                                                                      | full (`cbec2dbb`) | `@terminalScope @hidesLaterScopes` input scopes; `ui.lantern.inputModeKeepsTheGuideOutOfTheWay` |
| `LTN13` | Panel rows must be **tappable**: a tap activates a binding, a tap on a group drills down, and the platform Back key pops one level — the only way the command surface is reachable on Android, where there is no keyboard.              | not started       | `hitId` plumbing exists; [hue android.md](../hue/android.md) `AND13`                            |
| `LTN14` | **Placement must be configurable** — `classic` (full width, bottom) and `helix` (bordered, bottom-right) — defaulting to `classic`.                                                                                                     | partial           | `Placement` (both defined; only `classic` wired)                                                |
| `LTN15` | The delay, the leader key, and whether the guide is enabled at all must be **application configuration**, not constants. (The machine already takes the delay and the table as parameters.)                                             | not started       | [hue config.md](../hue/config.md) `lantern` section                                             |
| `LTN16` | An **icon** may be attached to a binding or a group, as which-key does, so a dense panel is scannable by shape as well as by text.                                                                                                      | not started       | proposed `Binding.icon`                                                                         |
| `LTN17` | The guide must render as a **static HTML cheat sheet** — the same tree through the HTML interpreter — so a keymap is documentable without a screenshot.                                                                                 | not started       | `sparkles.ui.interp.html`; `LTN5`                                                               |

## Focus & routing (`FOC`)

The values of the input-routing chain — the pieces every app hand-rolled as
booleans and statement order. The chain, extending `DCK13` from pointers to
keys: **grab → modal / focused scopes (the context's `reachable` hook) →
keymap/lantern → app fallback**.

| ID     | Requirement                                                                                                                                                                                                                                             | Status                                                                          | Traces to                                                                                  |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `FOC1` | Element focus traversal must have an **edge-aware form** ([popup.md `MDL5`](./popup.md)): the same walk as `FocusState.next`/`previous`, reporting "the edge was reached, leave this order" instead of wrapping — what a spliced or nested order needs. | full                                                                            | `sparkles.ui.focus.move`; `ui.focus.moveReportsTheEdgeInsteadOfWrapping`                   |
| `FOC2` | **Scope-level keyboard focus** must be a value over the app's own scope enum — the thing the context's `reachable` hook reads — with deterministic, wrapping cycling over a caller-supplied pane order.                                                 | full                                                                            | `sparkles.ui.focus.ScopeFocus`; `ui.focus.scopeFocusCyclesTheSuppliedOrder`                |
| `FOC3` | **Exclusive keyboard capture** must be a value: an addressable owner, release chords and a pass-through allowlist as `Chord` tables (not hand-written predicates), and verdicts a host switches on before anything else sees the key.                   | full                                                                            | `sparkles.ui.focus.KeyGrab`/`checkGrab`; `ui.focus.grabRoutesReleaseAndPassthroughByChord` |
| `FOC4` | **Modality is context gating, not a mechanism**: a modal surface is a context in which `reachable` answers `false` for everything below its scopes — so the table, the guide, and the router agree about what is live without a second filter.          | partial — hue adopts it (picker + inspector scopes); ui-gallery's shell is next | hue `KeyContext.reachable`; [popup.md `LYR11`](./popup.md)                                 |

## Module coverage

| Source                                              | Key symbols                                                                                                | Requirements                                |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| `libs/ui/src/sparkles/ui/keymap.d`                  | `Binding`, `Chord`, `ShiftReq`, `terminalScope`, `hidesLaterScopes`, `resolve`, `commandFor`, `bindingsAt` | `KEY2`–`KEY10`, `KEY13`                     |
| `libs/ui/src/sparkles/ui/lantern.d`                 | `LanternState`, `step`, `tick`, `untilShown`, `StepKind`                                                   | `LTN1`–`LTN4`, `LTN9`–`LTN12`               |
| `libs/ui/src/sparkles/ui/components/lantern_view.d` | `viewLantern`, `packBoxes`, `BoxLayout`, `LabelArena`, `Placement`                                         | `LTN5`–`LTN8`, `LTN14`                      |
| `apps/hue/src/keymap.d`                             | `Command`, `Scope_`, `KeyContext` (the hooks), `hueBindings`, the bound wrappers                           | `KEY1`, `KEY8`; [`LMP*`](../hue/lantern.md) |
| `apps/hue/src/lantern.d`                            | `step` bound to `hueBindings`; hue's policy tests through the machine                                      | `KEY1`                                      |

## Relationship to existing specs

| Piece                                                      | Role                                                                                       |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [hue lantern.md](../hue/lantern.md)                        | the first consumer's policy: the leader map (`LMP`), the delivery milestones (`LT0`–`LT6`) |
| [input](./input.md)                                        | the `Key`/`Mods`/`KeyEvent` vocabulary a chord is written in                               |
| [state machines](./state-machines.md) `STM7`               | the focus machine a scope's `reachable` hook will read once routing is framework-owned     |
| [anchored overlays](./popup.md) `LYR11`                    | the top-layer key-routing rung this layer's router work will fill                          |
| [hue config.md](../hue/config.md) `CFG6`                   | the loaded-table overlay `KEY12` awaits                                                    |
| [hue ui-architecture.md](../hue/ui-architecture.md) `UIA2` | the one-definition-per-visual contract the panel is held to                                |

→ [Overview](./index.md) · [State machines](./state-machines.md) · [hue lantern](../hue/lantern.md)
