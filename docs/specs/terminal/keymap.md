# Keymap and the key guide (`TKM`)

_**Status:** proposed · **Date:** 2026-10-02 · **Owner:** `apps/terminal`
(its command table and policy); machinery `sparkles:ui`
([`KEY`/`LTN`](../ui/keymap.md)) · **Scope:** which keys the terminal claims
for itself, how the rest reach the program, and how its commands are
discovered — by keyboard and by touch._

## Why

A terminal's keys belong to the program inside it. Today the application
claims four chords in a hand-written `if` chain (`TerminalView.onKey`:
Ctrl+Shift+C/V, Ctrl+=/−); everything this tree adds — tabs, splits, the
settings, about and log pages — needs commands, and a phone has no keys to
bind them to at all.

The machinery exists: `sparkles.ui.keymap` (a binding table read both ways),
`sparkles.ui.lantern` (the prefix machine with a delayed guide) and
`lantern_view` (the panel). The terminal supplies a table, as hue and diagram
do. What is new is the **division of the keyboard** between the program and
the terminal ([D18](./decisions.md)).

## Design

**In a pane,** a key is the program's unless it is one of:

| Chord                          | Command                       |
| ------------------------------ | ----------------------------- |
| `Ctrl+Shift+C` / `+V`          | copy / paste                  |
| `Ctrl+Shift+T`                 | new tab                       |
| `Ctrl+Shift+W`                 | close pane                    |
| `Ctrl+Shift+PgUp` / `+PgDn`    | previous / next tab           |
| `Ctrl+=` / `Ctrl+−` / `Ctrl+0` | font larger / smaller / reset |
| leader (`Ctrl+Shift+Space`)    | open the guide at the root    |

These are the chords kitty and Ghostty use, so muscle memory carries over. The
leader opens the [lantern](../hue/lantern.md) guide; everything else —
splits, focus movement, zoom, rename, the pages — sits under it, discoverable
rather than memorised:

```text
<leader> t  +tab     n new · x close · r rename · 1-9 go to
<leader> p  +pane    v split right · s split down · h/j/k/l focus · z zoom · x close
<leader> s  settings
<leader> a  about
<leader> l  logs
<leader> n  notifications
<leader> k  toggle extra keys     (Android)
```

The letters are the proposal; the table is reviewable in the spec, and a user
overlays it (`keys`, as hue's `CFG6`).

**In an overlay** (settings, about, logs, notifications, a menu, the exit
prompt), the design system's universal rows hold
([`KBD1`](../design-system/keyboard.md)): `q`/`Esc` close the innermost,
`?` opens the guide, `Tab` cycles, `Enter` activates, `/` searches where there
is a list.

**On a touch screen,** the guide is the command surface: an extra-keys token
`MENU` opens it at the root, and its rows are tappable.

## Requirements

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                   | Status      | Traces to                                  |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------ |
| `TKM1` | The terminal's commands must be one `immutable Binding[]` table over a command enum and a scope enum (`sparkles.ui.keymap`), resolved through `resolve` and enumerated by `bindingsAt`; no key may be handled by a separate `if`. The four chords `onKey` handles today move into it. Violation: a chord that fires but is absent from `bindingsAt`'s enumeration (the `KEY` agreement test). | not started | `sparkles.ui.keymap`; `TerminalView.onKey` |
| `TKM2` | In the pane scope, only the chords above and the leader are claimed; every other key event, `Esc` included, must reach the program through the key encoder unchanged. Violation: a key outside the table that the program does not receive (a sweep over the encoder's key set with a recording pty).                                                                                         | not started | `event_map.d`                              |
| `TKM3` | The table must not bind `Ctrl-C`, `Ctrl-Z`, `Ctrl-S`, `Ctrl-Q` or `Ctrl-\` in any scope ([`KBD3`](../design-system/keyboard.md)); a static test over the table fails if it does. Within the exit prompt, `Ctrl+C` is the prompt's own key only while the pane has no program (`TSS2`).                                                                                                        | not started | `KBD3`                                     |
| `TKM4` | Scopes, in resolution order: the overlays (settings, about, logs, notifications, menu, exit prompt — each terminal and hiding later scopes), the workspace, the pane. An open overlay receives every key except the leader; closing it returns focus to the pane that had it.                                                                                                                 | not started | `@terminalScope`, `@hidesLaterScopes`      |
| `TKM5` | The leader opens the lantern guide at the root after the configured delay (`lantern.delayMs`; zero shows it at once); a known path typed faster runs without showing it. The leader chord is configurable (`lantern.leader`); a chord that collides with `TKM3` is refused with a located config warning.                                                                                     | not started | `sparkles.ui.lantern` `step`, `untilShown` |
| `TKM6` | The guide's rows must be tappable and the platform Back must pop one level (closing at the root) — the toolkit's [`LTN13`](../ui/keymap.md), delivered for this consumer.                                                                                                                                                                                                                     | not started | `lantern_view` `hitBase`                   |
| `TKM7` | The extra-keys syntax gains a `MENU` token that opens the guide at the root; the default layout includes it. Unknown tokens keep their Termux meaning (literal text).                                                                                                                                                                                                                         | not started | `extraKey`                                 |
| `TKM8` | User overlays (`keys` in the config) rebind or unbind (`null`) rows by command name and scope, as hue's `CFG6`; the guide shows the merged table. A binding that names an unknown command or an unparsable chord is a located warning, not a crash.                                                                                                                                           | not started | hue `keymap_config`                        |
| `TKM9` | `docs/apps/terminal/reference/bindings.md` must list the effective default table, generated from or checked against `bindingsAt` ([`KBD6`](../design-system/keyboard.md)), so the docs and the binary agree.                                                                                                                                                                                  | not started | `bindingsAt`                               |

→ [Overview](./index.md) · [`KEY`/`LTN`](../ui/keymap.md) · [Keyboard vocabulary](../design-system/keyboard.md)
