# `sparkles:ui` editor — Feature Requirements (editable text component)

_**Status:** planned · **Date:** 2026-08-05 · **Scope:** the toolkit's
**editable-text component** — a presentation-free editing state machine, an
edit-aware layout, and an editor widget across GUI / TUI (HTML is read-only by
doctrine) — the missing capability behind hue's diff **write wave**
([`UIA9`](../hue/ui-architecture.md)): inline diff editing
([`DST5`](../hue/diff-view.md)), the comment composer and suggestion authoring
([`DCM3`](../hue/diff-view.md)), and conflict resolution
([`CFV4`](../hue/diff-view.md))._

> [!NOTE]
> Forward-looking — every row is `not started`. Status legend and IDs: see the
> [overview](./index.md). This spec exists because the write wave's
> requirements all bottom out here: hue's only text input today is the
> single-line incremental-search field, hand-rolled per backend.

## Design & rationale

### Bounded editing surfaces, not an editor app

hue's GUI spec declares the viewer "deliberately not a text editor" — and that
doctrine survives, refined: hue does not become an editor _application_ (no
buffer list, no file-save workflow as the primary activity, no LSP editing
loop). What the diff write wave needs is **bounded editing surfaces**: one
editable pane inside a diff, a comment composer, a conflict-result pane. The
component is sized to that: a self-contained editable region over a supplied
string, returning the edited value to its consumer — never an app shell.

### The three levels, applied

Per the toolkit doctrine ([feature-requirements](./feature-requirements.md)),
the component splits across the levels so every backend runs the same editing
logic:

- **Level 1 — the editing state machine** (`EDT`): a pure value
  (`EditorState`) advanced by `step(state, EditCommand) → state`. No draw
  calls, no device units, no clipboard I/O — testable with strings alone.
- **Level 2 — edit-aware layout**: the wrapped-line layout consumes the
  buffer and cursor and yields caret/selection geometry in abstract units.
- **Level 3 — the editor widget** (`EDR`): `view(state) → Widget`, painted by
  the existing canvases; cursor blink rides the `Timeline` machine
  ([`STM6`](./state-machines.md)).

### Buffer representation: lines first, ropes never (yet)

The consumers are bounded surfaces — a hunk's worth of lines, a comment, a
conflict region — not 100 MB files, and the diff consumer re-reads the full
text after every debounce anyway ([`NFR8`](../hue/feature-requirements.md)).
So v1 is an **array of lines** with copy-on-edit of the touched line: simple,
`@safe`, trivially diffable. A gap buffer / rope is explicitly deferred until
a consumer demonstrates the need; the `EditorState` API hides the
representation so the upgrade is internal.

### Input honesty per backend

Typed characters already reach the toolkit: `RaylibEvents` drains
`GetCharPressed` into the `sparkles:input` event vocabulary, and the TUI
decoder delivers text the same way. What no backend has is **composition**:
desktop IME (raylib exposes no composition events — a known engine
limitation) and the Android soft keyboard. The spec keeps v1 honest — direct
input + clipboard paste everywhere — and stages composition as its own
researched milestones rather than pretending `GetCharPressed` is an IME.

## The editing model (`EDT`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                     | Status      | Traces to                                                |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------- |
| EDT1 | **`EditorState` is a Regular value**: the buffer (lines), cursor, selection ([`STM3`](./state-machines.md) `Selection` over text positions), and undo history — advanced only by `step(state, EditCommand) → state`, pure and presentation-free ([`STM1`](./state-machines.md) discipline).                                                     | not started | proposed `sparkles.ui.state` editor machine              |
| EDT2 | The **`EditCommand` vocabulary** covers insert-text, delete (backspace/forward/word/line), newline, cursor movement (char/word/line/home/end/document, with and without selection extension), select-all, and replace-range — named by effect, so hue's `keymap.Command` and config bindings ([`CFG6`](../hue/config.md)) map onto it directly. | not started | proposed `EditCommand`; `keymap.d` `input` context       |
| EDT3 | **Cursor movement is grapheme-aware**: char-wise motion and deletion operate on grapheme clusters (the toolkit's existing segmentation), never splitting a cluster; word motion uses word-boundary rules consistent with the diff word tokenizer.                                                                                               | not started | existing grapheme segmentation; `sparkles:diff` tokens   |
| EDT4 | **Undo/redo** is an operation log with inverse ops: consecutive typing coalesces into one undo unit (broken by cursor moves, deletes, or a pause), and undo restores the selection as well as the text.                                                                                                                                         | not started | proposed op log                                          |
| EDT5 | **Single-line mode is the same machine** (newline rejected or submit-mapped): the incremental-search field and the future config/text prompts become consumers, retiring the per-backend hand-rolled input.                                                                                                                                     | not started | `FND` search field ([gui.md](../hue/gui.md)) unified     |
| EDT6 | **Read-only spans**: a consumer may mark regions immutable (conflict markers while picking, the non-worktree side context in a suggestion editor); edit commands touching them are rejected as a no-op with a signal the widget can flash — never silent corruption.                                                                            | not started | proposed protected ranges; [`CFV4`](../hue/diff-view.md) |
| EDT7 | The machine is **`@safe`** and allocation-disciplined (copy-on-edit of touched lines); property tests hold the invariants: cursor always on a grapheme boundary, selection normalized, undo→redo round-trips the state.                                                                                                                         | not started | proposed unittests                                       |

## Text input & composition (`EDI`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                             | Status      | Traces to                                                      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------- |
| EDI1 | **Direct input everywhere first**: typed characters arrive through the existing `sparkles:input` event stream (GUI: the `RaylibEvents` `GetCharPressed` drain; TUI: the wire decoder) and clipboard **paste** inserts at the cursor — the v1 input story on every backend.                                                              | not started | `ui_raylib/events.d`; `sparkles:tui` decoding; clipboard seams |
| EDI2 | **Focus routes input**: while an editor has focus ([`STM7`](./state-machines.md)), text events go to it and the app keymap sees only the keys the editor declines (Esc, the submit chord) — the existing `input` key context, formalized.                                                                                               | not started | `FocusState`; `keymap.d` contexts                              |
| EDI3 | **Desktop IME composition** — raylib exposes no composition events, so CJK and dead-key input cannot compose in-window today. Researched: candidate routes (platform IME hooks beside raylib's window, an SDL-backed events adapter, or upstream raylib work) with the interim story documented: paste works, direct Latin input works. | not started | researched; risk recorded                                      |
| EDI4 | **Android soft keyboard**: focusing an editor shows the soft keyboard (`ANativeActivity` soft-input), losing focus hides it; its key/text events join the same input stream. Until then Android editing surfaces stay disabled (the [diff-view backend matrix](../hue/diff-view.md) "later").                                           | not started | [`AND12`](../hue/android.md); NativeActivity soft input        |
| EDI5 | Degradation is explicit: a backend without a capability (no clipboard, no soft keyboard) disables the affected affordance with an in-band notice — never a dead control.                                                                                                                                                                | not started | capability gates ([`TCP1`](../hue/tui.md) analog)              |

## The editor widget (`EDR`)

| ID   | Requirement                                                                                                                                                                                                                                                                                          | Status      | Traces to                                                                                |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------- |
| EDR1 | An **editor widget** renders the buffer through the standard pipeline (`view → layout → display list → paint`) on GUI and TUI; the caret is a themed slot, blinking via [`STM6`](./state-machines.md) `Timeline`; selection renders through the standard selection tint.                             | not started | proposed `sparkles.ui.components.editor`                                                 |
| EDR2 | **Edit-aware wrapping**: the wrapped layout updates for the edited line without global relayout where possible; caret geometry comes from the layout (never re-derived per backend), and the viewport **follows the caret** (the `ensure_in_viewport` policy).                                       | not started | layout integration; [research: scm-record](../../research/diff-review/git-branchless.md) |
| EDR3 | **Highlight composition**: an editable region may carry syntax highlighting; re-highlight runs debounced off the edit stream (the [`NFR8`](../hue/feature-requirements.md) budget) and never blocks the keystroke echo — plain-text echo first, styled swap after (the render-then-restyle pattern). | not started | `sparkles:syntax` re-run; [research: gitui](../../research/diff-review/gitui.md)         |
| EDR4 | **Change surface**: the widget's consumer receives the edited text and a changed-range signal on every step, so hue's diff pane re-diffs ([`DST5`](../hue/diff-view.md)) and the composer validates without polling.                                                                                 | not started | proposed change events                                                                   |
| EDR5 | Visible **mode marking**: an editable region is visually distinct from read-only content (a themed slot — border/background), and read-only spans within it (`EDT6`) are marked; parity across GUI and TUI.                                                                                          | not started | `Slot`/`Palette`                                                                         |

## Consumers (`EDU`)

| ID   | Consumer                                                                                                                                                         | Status      | Traces to                           |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------------- |
| EDU1 | **Diff inline editing** — the worktree side of a diff pane ([`DST5`](../hue/diff-view.md)); explicit save; live re-diff via `EDR4`.                              | not started | [diff-view.md](../hue/diff-view.md) |
| EDU2 | **Comment composer & suggestions** — multi-line comment authoring and the suggestion mini-editor over the anchored lines ([`DCM3`](../hue/diff-view.md)).        | not started | [diff-view.md](../hue/diff-view.md) |
| EDU3 | **Conflict resolution** — free editing of the conflict result with the markers as read-only spans while picking ([`CFV4`](../hue/diff-view.md), `EDT6`).         | not started | [diff-view.md](../hue/diff-view.md) |
| EDU4 | **Search-field unification** — the incremental-search input becomes the single-line mode (`EDT5`), one machine on both backends instead of two hand-rolled ones. | not started | `gui.d`/`tui.d` search input        |

## Milestones

| Milestone | Scope                                                                                                                               | Status      | Requirements                  |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------- | ----------- | ----------------------------- |
| E0        | `EditorState` core: buffer + cursor + selection + `EditCommand` + undo, property-tested; single-line mode; search-field unification | not started | `EDT1`–`EDT5`, `EDT7`, `EDU4` |
| E1        | The editor widget on GUI + TUI: caret/selection rendering, edit-aware wrap, viewport follow, change surface, focus routing          | not started | `EDR1`–`EDR5`, `EDI1`, `EDI2` |
| E2        | Write-wave consumers: diff inline editing, comment composer, conflict result (unblocks diff-view `W1`/`W2`)                         | not started | `EDU1`–`EDU3`, `EDT6`         |
| E3        | Android soft keyboard                                                                                                               | not started | `EDI4`                        |
| E4        | Desktop IME composition (researched → design)                                                                                       | not started | `EDI3`                        |

## Relationship to existing specs

| Piece                                                                | Role                                                      |
| -------------------------------------------------------------------- | --------------------------------------------------------- |
| [state-machines.md](./state-machines.md) `STM1`/`STM3`/`STM6`/`STM7` | the discipline and the machines the editor composes with  |
| [input.md](./input.md)                                               | the event vocabulary the editor consumes                  |
| [widgets.md](./widgets.md)                                           | the view-model/view split the widget follows              |
| [hue diff-view.md](../hue/diff-view.md) `DST5`/`DCM3`/`CFV4`         | the write wave this unblocks (`W1` is gated on E1/E2)     |
| [hue ui-architecture.md](../hue/ui-architecture.md) `UIA9`           | hue's consumption requirement pointing here               |
| [hue android.md](../hue/android.md) `AND12`                          | the touch/soft-keyboard phasing                           |
| [hue config.md](../hue/config.md) `CFG6`                             | rebindable `EditCommand` bindings via the `input` context |

→ [Overview](./index.md) · [State machines](./state-machines.md) · [Widgets](./widgets.md) · [hue diff & PR view](../hue/diff-view.md)
