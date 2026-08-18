# `hue` lantern — Feature Requirements (the key guide, all interactive backends)

_**Status:** partial — the binding table, the prefix machine, the panel and both
backends shipped (`c19bb926`…`8ec10bee`); the machinery and its `KEY*`/`LTN*`
requirement rows have since **moved to
[`docs/specs/ui/keymap.md`](../ui/keymap.md)** with the extraction into
`sparkles:ui` · **Date:** 2026-08-18 · **Scope:** hue's **key guide** — now the
policy this application feeds the framework's guide: the **binding table**
(`hueBindings`) and the **leader map** it navigates._

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

## The binding table & the guide (`KEY`, `LTN`) — moved

The `KEY1`–`KEY13` and `LTN1`–`LTN17` requirement rows live in
[`docs/specs/ui/keymap.md`](../ui/keymap.md), beside the machinery they
specify (`sparkles.ui.keymap`, `sparkles.ui.lantern`,
`sparkles.ui.components.lantern_view`). Their statuses and shipping history
are preserved there; hue remains the first consumer, and the hue-side
obligations trace back to this application's modules: `hueBindings` is the
one table (`KEY1`), its rows are spelled in normalised form (`KEY8`,
`keymap.tableIsSpelledInNormalisedForm`), and every backend dispatch is a
`final switch` over `Command` (`KEY11`).

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
| `LMP10` | `<leader>vf` toggles the [format preview](./format-preview.md) and `<leader>vF` cycles its formatter; `<`/`>` nudge the ruler while the preview is active (context-gated — `[`/`]` stay set/diff navigation). | full (`ca124bea5`) | [format-preview.md](./format-preview.md)  |

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

The machinery's rows (`sparkles.ui.keymap`/`lantern`/`components.lantern_view`)
are covered in [`../ui/keymap.md`](../ui/keymap.md); this table keeps hue's own.

| Source                     | Key symbols                                                                  | Requirements            |
| -------------------------- | ---------------------------------------------------------------------------- | ----------------------- |
| `apps/hue/src/keymap.d`    | `Command`, `Scope_`, `KeyContext` (the hooks), `hueBindings`, bound wrappers | `KEY1`, `KEY8`, `LMP*`  |
| `apps/hue/src/lantern.d`   | `step` bound to `hueBindings`; hue's policy tests through the machine        | `KEY1`                  |
| `apps/hue/src/gui.d`       | the `final switch` dispatch; the panel paint; `HUE_GUI_LANTERN`              | `KEY11`, `LTN5`         |
| `apps/hue/src/tui.d`       | `handleKey`, `keyContext`, `paintLantern`, `untilLanternShown`               | `KEY11`, `LTN4`, `LTN5` |
| `apps/hue/src/explorer.d`  | `handleKey`, `handleCommand`, `collapseOrUp`                                 | `KEY11`, `LMP6`         |
| `apps/hue/src/workspace.d` | the loop's second deadline; `tickLantern`                                    | `LTN4`                  |

## Relationship to existing specs

| Piece                                             | Role                                                            |
| ------------------------------------------------- | --------------------------------------------------------------- |
| [../ui/keymap.md](../ui/keymap.md)                | the machinery and its `KEY*`/`LTN*` rows, extracted from here   |
| [config.md](./config.md) `CFG6`                   | the rebindable keymap this table finally makes possible         |
| [picker.md](./picker.md)                          | what `<leader>f` / `<leader>/` / `<leader>s` / `<leader>g` open |
| [ui-architecture.md](./ui-architecture.md) `UIA2` | the one-definition-per-visual contract the panel is held to     |
| [android.md](./android.md)                        | why `LTN13` is not optional — no keyboard exists there          |
| [folding.md](./folding.md) `FLD5`                 | the `z` family the prefix machine replaced a frame counter for  |
| [`sparkles:input`](../ui/input.md)                | the `Key`/`Mods`/`KeyEvent` vocabulary a chord is written in    |

→ [Picker requirements](./picker.md) · [Configuration](./config.md) · [Overview](./index.md)
