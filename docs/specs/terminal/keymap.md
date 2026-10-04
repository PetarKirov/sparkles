---
status: accepted
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Keymap and the key guide (`TKM`)

## Introduction

A terminal's keys belong to the program running in it. An editor, a shell or
a pager reads Ctrl, Alt and function keys as commands of its own, so every key
the terminal claims is one that program loses. Yet the terminal has commands
of its own: tabs, splits, focus, zoom, and the settings, about, log and
notification pages. On a phone there are almost no keys to bind them to.

The gap is between claiming enough keys to be usable and few enough to stay
out of the program's way, and between keyboard and touch. A long list of
claimed chords collides with programs; commands without chords are
undiscoverable; and a touch user has neither chords nor a keyboard shortcut
reference to read.

The terminal claims only the few chords kitty and Ghostty users already know,
plus one [leader](../../glossary.md#leader) chord. The leader opens a
[key guide](../../glossary.md#key-guide) that lists every other command and
descends into groups, so commands are discovered by browsing, not memorised.
On a touch screen the same guide is the command surface: its rows are tapped,
and it is reached from the [extra-keys row](../../glossary.md#extra-keys-row)
or the [opener](../../glossary.md#opener). All of it is one binding table,
read both ways: to resolve a key, and to list what a key would do.

This page specifies which keys the terminal claims, how every other key
reaches the program, and how commands are found. The binding machinery, the
prefix machine and its panel belong to `sparkles:ui`
([`KEY`/`LTN`](../ui/keymap.md)); the table and the division of the keyboard
belong to `apps/terminal` ([D18](./decisions.md)). How keys are encoded for
the program, including the kitty keyboard protocol, is in
[Protocols](./protocols.md); editing bindings is the settings page's
([`TSP8`](./config.md)). Key bindings inside the document viewer are the
viewer's ([`TDV6`](./viewer.md)).

[Design](#design) shows the division of the keyboard; [Requirements](#requirements)
holds the obligations and their status; the evidence is in
[Testing](./testing.md).

## Design

**In a pane,** a key is the program's unless it is one of these:

| Chord                                                    | Command                       |
| -------------------------------------------------------- | ----------------------------- |
| `Ctrl+Shift+C` / `+V`                                    | copy / paste                  |
| `Ctrl+Shift+T`                                           | new tab                       |
| `Ctrl+Shift+P`                                           | the tree of tabs and panes    |
| `Ctrl+Shift+W`                                           | close pane                    |
| `Ctrl+Shift+PgUp` / `+PgDn`                              | previous / next tab           |
| `Ctrl+=` / `Ctrl+−` / `Ctrl+0`                           | font larger / smaller / reset |
| leader (`Ctrl+Shift+Space`; `Ctrl+Alt+Space` on Android) | open the guide at the root    |

These are the chords kitty and Ghostty use, so muscle memory carries over.
Everything else sits under the leader, discoverable rather than memorised:

```text
<leader> t  +tab     n new · t tabs and panes · x close · 1-9 go to
<leader> p  +pane    v split right · s split down · h/j/k/l focus
                     · H/J/K/L resize · z zoom · x close
<leader> s  settings
<leader> a  about
<leader> c  credits
<leader> l  logs
<leader> n  notifications
<leader> k  toggle extra keys
<leader> ?  all keys
```

A user overlays this table through the `keys` setting, as hue's `CFG6` does.

**Over a [surface](../../glossary.md#surface)** (a page, a menu, a
confirmation), the design system's universal keys hold
([`KBD1`](../design-system/keyboard.md)): `q` and `Esc` close the innermost,
`?` opens the guide, `Tab` cycles, `Enter` activates, and `/` searches where
there is a list.

**On a touch screen,** the guide is the command surface: the extra-keys row's
`MENU` key and the opener's `⋯` button open it at the root, and its rows are
tappable.

## Requirements

**TKM1: One table.** The terminal's commands **must** be one
`immutable Binding[]` table over a command enum and a scope enum
(`sparkles.ui.keymap`), resolved through `resolve` and enumerated by
`bindingsAt`. No key **may** be handled outside the table. Violation: a chord
that fires but is absent from `bindingsAt`'s enumeration, which the `KEY`
agreement test catches.

**TKM2: Every other key reaches the program.** In a pane, the terminal
**must** claim only the chords above and the leader; every other key event,
`Esc` included, **must** reach the program through the key encoder unchanged.
Violation: a key outside the table that the program does not receive, found
by a sweep over the encoder's key set with a recording pty.

**TKM3: Reserved chords.** The table **must not** bind `Ctrl+C`, `Ctrl+Z`,
`Ctrl+S`, `Ctrl+Q` or `Ctrl+\` in any scope
([`KBD3`](../design-system/keyboard.md)); a static test over the table fails
if it does. The one exception is the exit prompt's `Ctrl+C`, which closes a
pane that no longer runs a program (`TSS2`).

**TKM4: Scopes.** Keys **must** resolve through three scopes, in order. An
open surface comes first; it is modal and hides the scopes after it, so it
receives every key except the leader, and closing it returns focus to the
pane that had it. The focused pane's [exit prompt](../../glossary.md#exit-prompt)
comes next; it claims Enter, `Esc` and `Ctrl+C`, and the pane's chords and
the leader still work beneath it. The pane comes last.

**TKM5: The leader.** The leader **must** open the key guide at the root
after the configured delay (`lantern.delayMs`; zero shows it at once), and a
known key path typed faster **must** run without showing it. The leader chord
is configurable (`lantern.leader`); a chord that collides with `TKM3` is
refused with a located configuration warning.

**TKM6: The touch guide.** The guide's rows **must** be tappable, and the
platform Back **must** pop one level, closing the guide at the root: the
toolkit's [`LTN13`](../ui/keymap.md), delivered for this consumer. The guide
shows its path as tappable breadcrumbs (← · leader › group). It offers a
search across every command at every level, whose results show their full
key path and are ranked by `sparkles:fuzzy`, and it lists recently used
commands. Layout (mockup K3): the breadcrumbs on top, then the commands or
search results, then the recent commands, and the search field at the bottom,
just above the extra keys.

_Rationale:_ Navigation sits first, where the eye starts; the search field
sits within reach of the thumb that types into it.

**TKM7: The MENU key.** The extra-keys syntax **must** accept a `MENU` token
that opens the guide at the root, and the default layout **must** include it.
Unknown tokens keep their Termux meaning, which is literal text.

**TKM8: User overlays.** The `keys` setting **must** rebind, or unbind with
`null`, rows by command name and scope, as hue's `CFG6` does, and the guide
**must** show the merged table. A binding that names an unknown command or an
unparsable chord is a located warning, not a crash.

**TKM9: The bindings reference.** `docs/apps/terminal/reference/bindings.md`
**must** list the effective default table, generated from or checked against
`bindingsAt` ([`KBD6`](../design-system/keyboard.md)), so that the docs and
the binary agree.

**TKM10: The leader per platform.** `lantern.leader` **must** default to
`Ctrl+Alt+Space` on Android and `Ctrl+Shift+Space` elsewhere
([D45](./decisions.md)). Violation: the default leader reaching the input
method instead of the app.

_Rationale:_ Android takes `Ctrl+Shift+Space` from a hardware keyboard to
switch the keyboard layout, so the desktop's leader never reaches an Android
app.

### Status

| ID      | Status                                                                                                                                 | Traces to                                                           |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| `TKM1`  | full                                                                                                                                   | `defaultBindings`, `terminalBindings`, `KeyRouter`; `builtinChords` |
| `TKM2`  | partial: swept over the router, every named key and printable under every modifier set; the recording-pty half of the sweep is not run | `claimsExactly`, `everyUnclaimedKeyReachesTheProgram`               |
| `TKM3`  | full                                                                                                                                   | `reservedChords`, `isReserved`, `reservedChordsAreNeverBound`       |
| `TKM4`  | full                                                                                                                                   | `TermScope`, `TermContext`, `Surfaces.key`                          |
| `TKM5`  | full                                                                                                                                   | `leaderChord`, `KeyRouter.tick`, `untilShown`                       |
| `TKM6`  | full                                                                                                                                   | `TouchGuide`, `fuzzyScore`, `DroidTerminal.pressExtraKey`           |
| `TKM7`  | full                                                                                                                                   | `ExtraKeyKind.menu`, `defaultExtraKeysSpec`                         |
| `TKM8`  | full                                                                                                                                   | `applyKeysOverlay`, `KeysConfig`                                    |
| `TKM9`  | full                                                                                                                                   | `bindingsMarkdown`, `bindingsMarkdown.matchesTheReference`          |
| `TKM10` | full                                                                                                                                   | `defaultLeader`, `androidLeader`, `LanternConfig.leader`            |

→ [Overview](./index.md) · [`KEY`/`LTN`](../ui/keymap.md) · [Keyboard vocabulary](../design-system/keyboard.md)
