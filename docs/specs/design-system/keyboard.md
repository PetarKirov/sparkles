---
status: draft
owner: sparkles:ui
reviewed: 2026-10-05
---

# Keyboard vocabulary (`KBD`)

## Abstract

`sparkles:ui` gives every Sparkles application — an application built on
`sparkles:ui` and its host, as opposed to the Sparkles theme — a small shared
set of key bindings: close, help, focus movement, search, motion and text
editing. A user who has learned one application has learned the basics of all
of them. A few reserved chords, such as interrupt and suspend, are never bound.
The set is one table of data, each application declares which of its commands
carry a shared meaning, and a test in each application holds it to the table.

## Introduction

Terminal and window applications in this repository share a keymap engine,
specified by [`KEY1`–`KEY12`](../ui/keymap.md). An engine alone does not make
applications agree: each could bind `q` or `?` to something different, and a
user switching between them would have to relearn the basics every time.

This page adds a vocabulary and a check, not a mechanism.
`sparkles.ui.keymap_universal` holds the universal keys and the reserved chords
as data. An application marks each command that implements a universal meaning,
and its tests compare its keymap with the table. Everything else stays
application policy under [`KEY`](../ui/keymap.md); the vocabulary is
deliberately minimal (D20).

The requirements follow. Delivery state lives in [PLAN.md](./PLAN.md) (M8), and
the choices behind the focus rows and `Ctrl-C` in [decisions.md](./decisions.md)
(D47, D48).

## Contract at a glance

1. The fixed rows mean the same thing in every context of every application; an
   application **may** leave one unbound, never rebind it.
2. `Enter` and `Space` belong to the focused control where it has those
   actions, and to the application otherwise.
3. Reserved chords are never bound; the terminal host owns `Ctrl-C`.
4. Every application tests its keymap against the one table and prints its
   effective table.

## Requirements

| ID     | Requirement                                                                                                                                                                                                                                          | Status      | Traces to                                                                                                                        |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `KBD1` | The **fixed rows** **must** exist in every Sparkles application and mean the same thing in every context; an application **may** leave one unbound where it has no meaning, never rebind it. The **focus rows** belong to the focused control (D47). | full        | `keymap_universal` `firstRebound`; `keymap.universalRowsAndReservedKeys` in hue, ui-gallery and diagram                          |
| `KBD2` | **Motion** rows: a component that scrolls or moves a cursor **must** honour `h j k l` and the arrow keys as synonyms, `g g` / `G` for start/end, `Ctrl-D` / `Ctrl-U` for a half page and `Page Up/Down` for a whole page.                            | partial     | hue `NAV`; `ScrollView`                                                                                                          |
| `KBD3` | A Sparkles application **must not** bind a **reserved key**: `Ctrl-C`, `Ctrl-Z`, `Ctrl-S`/`Ctrl-Q` and `Ctrl-\`. The TUI host **must** quit on `Ctrl-C` itself unless a component holds the keyboard grab (D48).                                     | full        | `keymap_universal` `firstReserved`; `ui_app.tui_loop.ctrlCInterruptsUnlessGrabbed`; ui-gallery's Terminal page grabs             |
| `KBD4` | **Footer hints** **must** render bindings as `key description` pairs joined by `·`, in the guide's normalised key spelling and in resolution order, and **must** change with focus (`bindingsAt`).                                                   | partial     | `lantern.d`; hue status bar                                                                                                      |
| `KBD5` | **Text inputs** **must** honour the Readline subset: `Ctrl-A`/`Ctrl-E`, `Ctrl-U`/`Ctrl-K`, `Ctrl-W` and `Alt-B`/`Alt-F`. `Ctrl-I` and `Ctrl-M` are `Tab` and `Enter` unless `keyRelease` disambiguates them.                                         | not started | `WGT14`; proposed `EDT`                                                                                                          |
| `KBD6` | A Sparkles application **must** ship its **effective table** — universal rows, overlay, and its own — through `--list-keys`.                                                                                                                         | full        | `keymap_universal` `writeKeyTable`; `--list-keys` in hue (overlay included), ui-gallery and diagram; `keymap.listingHasEveryRow` |
| `KBD7` | **Conformance check.** An application **must** mark each command that implements a universal meaning with `@means`, and its tests **must** assert that no row rebinds a fixed key and none binds a reserved one.                                     | full        | `keymap_universal` `firstRebound`, `firstReserved`; `keymap.universalRowsAndReservedKeys`                                        |

**KBD1 notes.** The fixed rows: `q` / `Esc` (and Android's Back) close the
innermost thing, in the order overlay, pane, application; `?` opens the key guide
(the lantern); `Tab` / `Shift-Tab` move focus; `/` starts a search where one
exists. The focus rows: `Enter` activates the focused control and `Space`
toggles it, where it has those actions. With no such control focused, the
application **may** bind them: hue's leader is `Space`, and diagram pans with it.

**KBD2 notes.** Modifiers a binding does not name are ignored (`KEY9`).

**KBD3 notes.** The reserved keys are interrupt (`Ctrl-C`), suspend (`Ctrl-Z`),
flow control (`Ctrl-S`/`Ctrl-Q`) and quit (`Ctrl-\`). A component that holds the
keyboard grab is an embedded shell, which needs `Ctrl-C` itself. A table
containing a reserved key fails the conformance test (`KBD7`).

**KBD4 notes.** The format is the lantern's, so the footer and the guide never
disagree.

**KBD5 notes.** The Readline keys move to the line ends (`Ctrl-A`/`Ctrl-E`), kill
to the start or end (`Ctrl-U`/`Ctrl-K`), kill a word (`Ctrl-W`) and move by word
(`Alt-B`/`Alt-F`). `keyRelease` is the kitty keyboard protocol.

**KBD6 notes.** Because the table is printed from the keymap itself, the guide,
the docs and the binary agree by construction.

**KBD7 notes.** The checks are `firstRebound` and `firstReserved` over the
application's rows. `firstRebound` skips the focus rows, which are checked in
context through `universalMeanings` (D47). Each application tests against the
one table, so the vocabulary cannot drift between applications.

→ [Overview](./index.md) · [Keymap & lantern](../ui/keymap.md)
