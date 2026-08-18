# `hue` lantern — Feature Requirements (the key guide, all interactive backends)

_**Status:** partial — the binding table, the prefix machine, the panel and both
backends shipped (`c19bb926`…`8ec10bee`) · **Date:** 2026-08-07 · **Scope:**
hue's **key guide** — the panel that lights up after a prefix and lists every key
that can follow it — together with the **binding table** it enumerates and the
**leader map** it navigates._

> [!NOTE]
> Inspired by [`folke/which-key.nvim`](https://github.com/folke/which-key.nvim).
> The name and the mechanism are hue's own; what is borrowed is the idea that a
> keymap should be able to explain itself, the delay-then-reveal interaction, and
> the multi-column panel layout. Status legend and ID conventions: see the
> [overview](./index.md).

## Why this exists

hue binds about fifty keys and, until this landed, told you about none of them.
Worse, it described them **three times**:

| Copy                 | Drove                 | Said `g` meant | Said `y` meant     |
| -------------------- | --------------------- | -------------- | ------------------ |
| `keymap.commandFor`  | the GUI               | go-to-line     | toggle ANSI-copy   |
| `tui.handleKey`      | the terminal viewer   | top            | copy the selection |
| `explorer.handleKey` | the terminal explorer | top            | —                  |

Three copies is not a documentation problem; it is a correctness problem, and it
is the same defect [`UIA2`](./ui-architecture.md) records for the two scrollbars
whose thumb formulas scrolled the same document differently. A guide that
describes one of the three would be lying about the other two.

So the guide's prerequisite is not a panel. It is **one policy that can be read
in both directions** — which key does this, and which keys are available.

## Design & rationale

### The policy is a table, not a function (`KEY`)

`commandFor` answered "what does this key do here" and nothing else. Two
consumers need the other direction:

- the guide, which **is** an enumeration of the binding set;
- [configuration](./config.md) (`CFG6`), which says "configuration replaces the
  hardcoded table with a loaded one" — and there was no table to overlay.

So `hueBindings` is an `immutable Binding[]`, `commandFor` is a lookup over it,
and `bindingsAt` is the enumeration. One declaration, read both ways, with
`bindingsAtEnumeratesWhatWouldFire` asserting the two agree at every level of the
tree.

**Ordering is the policy.** Precedence used to live in the shape of an
`if`/`else` chain — a Ctrl chord resolves before the plain letter, an open input
mode claims Enter before anything else, a focused tree claims `j` before the
viewer. That is now `Scope_`, whose declaration order _is_ the resolution order.

> [!IMPORTANT]
> The rewrite was proved, not asserted. The previous chain was kept as a
> `version (unittest)` differential oracle and swept against the whole input
> space — every context × every modifier combination × every key. It caught a
> real regression (`Ctrl-Up` must keep scrolling, because the old Ctrl block
> only guarded `char_` keys) and four bindings added on `main` mid-rebase. It
> was retired in `8e4b0250`, when the policy deliberately began to differ from
> the chain.

### A prefix is a path, not a flag (`LTN1`–`LTN4`)

hue had exactly one prefix, `z`, and it was a `bool` in `KeyContext` plus a
60-frame countdown in the GUI's frame loop. That shape works for one prefix, one
level deep, on the one backend that has frames. It cannot express `<leader>uy`,
it cannot tell the guide _which_ prefix is pending, and its clock does not exist
in a terminal.

`LanternState` holds the pending path instead — at most `maxPathLength` chords in
a `SmallBuffer` — and `step` is a pure function over it.

**The delay is measured in time, not frames.** This is what lets the terminal use
`untilShown` as its poll timeout: a terminal has no frames to count, and its loop
blocks on input, so a panel that appears "after 200 ms" would in fact appear on
the next keystroke — precisely when it is useless.

**The delay is also the whole interaction.** A prefix that opened its panel
instantly would punish anyone who knows the keys; one that never opened would not
be a guide. `zc` typed quickly folds and shows nothing; `z` held for a beat
lights the panel. The same keystrokes teach or get out of the way depending only
on how fast you are.

### One panel, every backend (`LTN5`–`LTN8`)

The panel is a `sparkles:ui` widget tree, so the GUI, the TUI and (for a static
cheat sheet) HTML get one definition rather than three that drift — the
[`UIA2`](./ui-architecture.md) contract. Painting is where these backends have
diverged before, so `tui.lantern.panelPaintsIntoTheCellGrid` reads the cells back
rather than trusting the tree.

Layout is which-key's: pack the items into as many side-by-side columns as the
width affords, filled top-to-bottom, one column at a time. Widening reflows to
more, shorter columns; narrowing collapses toward one.

### The map is the user-facing artefact (`LMP`)

A leader map is memorised, so rearranging it later is a real cost to a user who
has learnt it. The letters the [picker](./picker.md) will claim are therefore
**reserved now** and listed below as `not started`, rather than being assigned to
whatever is convenient today and moved when the picker lands.

## The binding table (`KEY`)

| ID      | Requirement                                                                                                                                                                                                                    | Status            | Traces to                                                    |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | ------------------------------------------------------------ |
| `KEY1`  | hue's keyboard policy must be **one `immutable` table** (`hueBindings`), and every backend must resolve keys through it. No backend may carry a key `switch` of its own.                                                       | full (`e71a9417`) | `keymap.hueBindings`; `gui.d`/`tui.d`/`explorer.d` dispatch  |
| `KEY2`  | `commandFor`/`resolve` must be a **lookup** over that table, walking `Scope_` in declaration order; that order is the resolution precedence, and an active `terminal` scope ends the search whether or not it matched.         | full (`c19bb926`) | `keymap.resolve`; `Scope_`; `terminal`                       |
| `KEY3`  | `bindingsAt` must **enumerate** the bindings reachable in a context under a prefix, in resolution order, with a shadowed duplicate dropped rather than listed twice. Whatever it lists, `resolve` must do.                     | full (`c19bb926`) | `keymap.bindingsAt`; `bindingsAtEnumeratesWhatWouldFire`     |
| `KEY4`  | A binding must state its own **context gate** (`require`/`forbid` over `CtxFlag`) and its **input-mode** requirement, so a caller never post-filters the table.                                                                | full (`c19bb926`) | `Binding.require`/`forbid`/`mode`; `gated`                   |
| `KEY5`  | A chord must carry a three-valued **Shift requirement**. `j` scrolls whether or not Shift is held; `r` refreshes only unshifted and `R` re-roots only shifted. A two-state encoding would depend on table order.               | full (`c19bb926`) | `ShiftReq`; `keymap.shiftIsPartOfTheBinding`                 |
| `KEY6`  | A chord may span a **contiguous code-point range**, so `z1`–`z9` is one row (and one guide item) whose argument is derived from which key landed — the spelling `CFG6` proposes (`"1-9": "foldLevel"`).                        | full (`c19bb926`) | `Chord.chEnd`; `lantern.foldLevelsCarryTheirArgument`        |
| `KEY7`  | Key events must be **normalised once** — a shifted letter arrives as the shifted character from raylib, as a bare capital from a terminal, or as lowercase + Shift from a synthesised event, and all three mean one keystroke. | full (`c19bb926`) | `keymap.normalise`; `shiftedLettersNormaliseAcrossProducers` |
| `KEY8`  | A row must be **spelled in normalised form** — never an uppercase letter, which `normalise` can never produce, so such a row is unreachable. This must be checked, not remembered.                                             | full (`cbec2dbb`) | `keymap.tableIsSpelledInNormalisedForm`                      |
| `KEY9`  | A modifier a chord does **not** name must be ignored, not required absent — `Ctrl-Up` scrolls because `Up` binds scrolling and says nothing about Ctrl. Safe because the `ctrl` scope is terminal.                             | full (`c19bb926`) | `keymap.matches`                                             |
| `KEY10` | Prefix comparison must accept a shift-agnostic row (`acceptsTyped`), while de-duplication stays exact (`sameKey`) — `g` opens a group and `Shift-G` jumps to the bottom, and both must be listed and both reachable.           | full (`8e4b0250`) | `keymap.acceptsTyped`; `lantern.chordOf`                     |
| `KEY11` | Every backend's dispatch must be a **`final switch`** over `Command` with explicit arms — including empty ones — so a new command is a compile error until each backend decides whether it answers it.                         | full (`e71a9417`) | `gui.d`, `tui.handleKey`, `explorer.handleCommand`           |
| `KEY12` | The table must be **overlayable by configuration** (`CFG6`): a user table rebinds individual rows without replacing the rest, and `null` unbinds.                                                                              | not started       | [config.md](./config.md) `CFG6`                              |

## The guide (`LTN`)

| ID      | Requirement                                                                                                                                                                                                                             | Status            | Traces to                                                          |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------------------ |
| `LTN1`  | A **pure state machine** must own the pending key path and whether the panel is showing — no window, no timer, no frame loop — so the whole guide is checkable in a unittest.                                                           | full (`cbec2dbb`) | `lantern.LanternState`/`step`                                      |
| `LTN2`  | A prefix must **descend** rather than execute, and a leaf must execute and end the sequence. A key that names nothing under the prefix must end the sequence **without running** — the "an unrecognised key disarms" rule, stated once. | full (`cbec2dbb`) | `lantern.step`; `unrecognisedKeyEndsTheSequenceWithoutRunning`     |
| `LTN3`  | The machine must distinguish **`unbound`** from **`consumed`**, so a host can tell "the guide declined this" from "the guide handled it"; collapsing them would silently eat every key hue has not bound.                               | full (`cbec2dbb`) | `lantern.StepKind`; `unboundKeysStaySeparateFromConsumedOnes`      |
| `LTN4`  | The panel must appear after a **delay measured in wall time** (default 200 ms), and the machine must report how long remains, so a terminal can use it as a poll timeout and open the panel with no keystroke to wake it.               | full (`8ec10bee`) | `lantern.tick`/`untilShown`; `workspace.d` loop deadline           |
| `LTN5`  | The panel must be a **`sparkles:ui` widget tree**, painted by every interactive backend from one definition (`UIA2`), and must sit over everything else — it is a transient answer, not part of the document.                           | full (`8ec10bee`) | `lantern_view.viewLantern`; `gui.d`, `tui.paintLantern`            |
| `LTN6`  | Items must be packed into as many **side-by-side columns** as the width affords, reflowing on resize; a set larger than the panel must **scroll**, never be silently truncated.                                                         | full (`91054510`) | `lantern_view.packBoxes`/`BoxLayout.capacity`; `boxesFillTheWidth` |
| `LTN7`  | Panel text must be **borrowed from a caller-owned arena**, written in full before any of it is sliced — a growing buffer moves, and a stale slice renders another item's text with nothing to assert against.                           | full (`91054510`) | `lantern_view.LabelArena`; `everyLabelSurvivesTheArenaGrowing`     |
| `LTN8`  | A **prefix node must be visibly marked** (`+name`) so a reader can tell "this runs something" from "this opens a menu" before pressing it.                                                                                              | full (`91054510`) | `lantern_view` group marker; `groupsAreMarkedAndCommandsAreNot`    |
| `LTN9`  | The panel's own keys must be live **only while a sequence is pending**: Escape abandons it, Backspace steps back one level, `Ctrl-D`/`Ctrl-U` scroll. Backspace at rest belongs to the host.                                            | full (`cbec2dbb`) | `lantern.step`; `escapeAndBackspaceNavigateTheSequence`            |
| `LTN10` | **Always-available** bindings must outrank a pending prefix, so a half-typed sequence can never trap the reader in a fullscreen window.                                                                                                 | full (`cbec2dbb`) | `lantern.resolveAlways`; `alwaysBindingsOutrankAPendingPrefix`     |
| `LTN11` | `<leader>?` must show **every binding live in this context** immediately, with no delay — the "I don't know what I'm looking for" door.                                                                                                 | full (`cbec2dbb`) | `Command.lanternAll`; `explicitRequestOpensImmediately`            |
| `LTN12` | The guide must be **inert while a line editor owns the keyboard** — the leader must not open a menu in the middle of a search query.                                                                                                    | full (`cbec2dbb`) | `Scope_.input` terminal; `inputModeKeepsTheGuideOutOfTheWay`       |
| `LTN13` | Panel rows must be **tappable**: a tap activates a binding, a tap on a group drills down, and the platform Back key pops one level — the only way the command surface is reachable on Android, where there is no keyboard.              | not started       | `hitId` plumbing exists; [android.md](./android.md) `AND13`        |
| `LTN14` | **Placement must be configurable** — `classic` (full width, bottom) and `helix` (bordered, bottom-right) — defaulting to `classic`.                                                                                                     | partial           | `lantern_view.Placement` (both defined; only `classic` wired)      |
| `LTN15` | The delay, the leader key, and whether the guide is enabled at all must be **configuration** (`CFG`), not constants.                                                                                                                    | not started       | [config.md](./config.md) `lantern` section                         |
| `LTN16` | An **icon** may be attached to a binding or a group, as which-key does, so a dense panel is scannable by shape as well as by text.                                                                                                      | not started       | proposed `Binding.icon`                                            |
| `LTN17` | The guide must render as a **static HTML cheat sheet** — the same tree through the HTML interpreter — so the keymap is documentable without a screenshot.                                                                               | not started       | `sparkles.ui.interp.html`; `LTN5`                                  |

## The map (`LMP`)

The reviewable source of truth for what hue binds. Non-leader prefixes: `z`
+fold, `g` +goto, `[`/`]` prev/next.

| ID      | Requirement                                                                                                                                                                                                   | Status             | Traces to                                 |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------ | ----------------------------------------- |
| `LMP1`  | The **leader is `<space>`**, because that is the muscle memory the LazyVim-shaped map this is growing into is built on — and the easiest key to hit on a touch keyboard (`LTN13`).                            | full (`cbec2dbb`)  | `keymap.leader`                           |
| `LMP2`  | `<leader>v` +view · `<leader>u` +ui · `<leader>d` +diff · `<leader>e` explorer · `<leader>?` all bindings.                                                                                                    | full (`cbec2dbb`)  | `hueBindings` leader rows                 |
| `LMP3`  | Motions are **vim-correct**: `gg` top, `Shift-G` bottom, `gl` go-to-line, per pane.                                                                                                                           | full (`8e4b0250`)  | `keymap`; `tui.keys.resolvedDivergences…` |
| `LMP4`  | `y` **copies the selection** in every backend; the ANSI-copy _mode_ it displaced is a setting and lives at `<leader>uy`.                                                                                      | full (`8e4b0250`)  | `hueBindings`                             |
| `LMP5`  | `q` **quits** in every backend.                                                                                                                                                                               | full (`8e4b0250`)  | `hueBindings`                             |
| `LMP6`  | `←`/`→` and `PgUp`/`PgDn` are **pane-scoped**: a focused tree navigates its rows, the viewer cycles themes and pages. Theme cycling stays reachable from anywhere via `<leader>ut`.                           | full (`e71a9417`)  | `hueBindings`; `sharedBindingsWork…`      |
| `LMP7`  | `<leader>f` +file/find and `<leader>/` grep are **reserved** for the [picker](./picker.md) and must not be assigned to anything else in the meantime.                                                         | not started        | [picker.md](./picker.md) `PIK`            |
| `LMP8`  | `<leader>s` +search and `<leader>g` +git are likewise reserved for the picker's search and git sources.                                                                                                       | not started        | [picker.md](./picker.md) `PKS`            |
| `LMP9`  | `<leader>o` +overlay is reserved for the [overlay](./overlays.md) kinds (`OVL4`).                                                                                                                             | not started        | [overlays.md](./overlays.md)              |
| `LMP10` | `<leader>vf` toggles the [format preview](./format-preview.md) and `<leader>vF` cycles its formatter; `<`/`>` nudge the ruler while the preview is active (context-gated — `[`/`]` stay set/diff navigation). | full (`0642374c2`) | [format-preview.md](./format-preview.md)  |

## Milestones

| Milestone | Scope                                                                | Status            | Requirements                                 |
| --------- | -------------------------------------------------------------------- | ----------------- | -------------------------------------------- |
| `LT0`     | The binding table; `commandFor` derived from it; the enumeration     | done (`c19bb926`) | `KEY1`–`KEY9`                                |
| `LT1`     | The prefix state machine; `z` as a path; the leader tree             | done (`cbec2dbb`) | `LTN1`–`LTN3`, `LTN9`–`LTN12`, `LMP1`/`LMP2` |
| `LT2`     | The panel as a widget tree; the GUI                                  | done (`91054510`) | `LTN5`–`LTN8`                                |
| `LT3`     | The TUI and explorer routed; the panel in cells; the loop's deadline | done (`8ec10bee`) | `KEY10`–`KEY11`, `LTN4`, `LMP3`–`LMP6`       |
| `LT4`     | Tappable rows; the Android command menu                              | not started       | `LTN13`                                      |
| `LT5`     | Configuration: placement, delay, leader, and the rebindable table    | not started       | `KEY12`, `LTN14`, `LTN15`                    |
| `LT6`     | Icons; the static HTML cheat sheet                                   | not started       | `LTN16`, `LTN17`                             |

## Module coverage (lantern)

| Source                        | Key symbols                                                               | Requirements                  |
| ----------------------------- | ------------------------------------------------------------------------- | ----------------------------- |
| `apps/hue/src/keymap.d`       | `Binding`, `hueBindings`, `Scope_`, `resolve`, `commandFor`, `bindingsAt` | `KEY*`, `LMP*`                |
| `apps/hue/src/lantern.d`      | `LanternState`, `step`, `tick`, `untilShown`, `StepKind`                  | `LTN1`–`LTN4`, `LTN9`–`LTN12` |
| `apps/hue/src/lantern_view.d` | `viewLantern`, `packBoxes`, `BoxLayout`, `LabelArena`, `Placement`        | `LTN5`–`LTN8`, `LTN14`        |
| `apps/hue/src/gui.d`          | the `final switch` dispatch; the panel paint; `HUE_GUI_LANTERN`           | `KEY11`, `LTN5`               |
| `apps/hue/src/tui.d`          | `handleKey`, `keyContext`, `paintLantern`, `untilLanternShown`            | `KEY11`, `LTN4`, `LTN5`       |
| `apps/hue/src/explorer.d`     | `handleKey`, `handleCommand`, `collapseOrUp`                              | `KEY11`, `LMP6`               |
| `apps/hue/src/workspace.d`    | the loop's second deadline; `tickLantern`                                 | `LTN4`                        |

## Relationship to existing specs

| Piece                                             | Role                                                            |
| ------------------------------------------------- | --------------------------------------------------------------- |
| [config.md](./config.md) `CFG6`                   | the rebindable keymap this table finally makes possible         |
| [picker.md](./picker.md)                          | what `<leader>f` / `<leader>/` / `<leader>s` / `<leader>g` open |
| [ui-architecture.md](./ui-architecture.md) `UIA2` | the one-definition-per-visual contract the panel is held to     |
| [android.md](./android.md)                        | why `LTN13` is not optional — no keyboard exists there          |
| [folding.md](./folding.md) `FLD5`                 | the `z` family the prefix machine replaced a frame counter for  |
| [`sparkles:input`](../ui/input.md)                | the `Key`/`Mods`/`KeyEvent` vocabulary a chord is written in    |

→ [Picker requirements](./picker.md) · [Configuration](./config.md) · [Overview](./index.md)
