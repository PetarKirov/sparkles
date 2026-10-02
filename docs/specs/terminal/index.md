# `sparkles:terminal` — Overview

_**Status:** proposed (Stage 0: specification; layout open pending mockups) ·
**Date:** 2026-10-02 · **Owners:** `apps/terminal` (the application, its
pages and its policy), `sparkles:terminal-view` (the emulator component and
its protocol surface), `sparkles:ui` (the shared components it lifts),
`sparkles:android` (JNI plumbing), `sparkles:base` (logging) · **Scope:** the
terminal as an application on the desktop and on Android — configuration and
its settings page, the key table and its guide, the about, log and
notification pages, touch selection, the terminal protocols an application
inside it may use, the exit prompt, tabs and splits._

## Why

The terminal runs on Linux, macOS and Android ([the Android
spec](./android.md)), but as an application it is one pane and a command line:

- **It cannot be configured from inside.** On the desktop the configuration is
  a handful of flags; on Android there is no command line, so it is
  `~/.termux/*` or nothing. Nothing shows the version, the licences, or what
  the app logged.
- **On a phone it cannot select text.** Selection, copy and link hover live in
  the polled mouse path (`handle_mouse`), which Android disables
  (`TerminalViewOptions.pollMouse`); a long-press is ignored.
- **A program's exit ends the app** (or holds a banner), with no way to run the
  command again or drop to a shell.
- **One session.** `TerminalView` already supports many instances (ui-gallery's
  `TerminalStore` hosts eight), but the application shows one.
- **Programs cannot talk to it.** Titles reach the window but not a tab;
  notifications (OSC 9/99/777), clipboard writes (OSC 52), colour-scheme
  reports (mode 2031) and the icon name (OSC 1) are dropped.

## Scope

**In scope:** everything in the pages below, on Linux, macOS and Android,
except where a row names a platform.

**Non-goals** (each with its reason):

| Not here                                     | Why                                                                                                                                        |
| -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| Java on Android (an `ActionMode`, a service) | [Android `D2`](./android.md#decisions): no DEX. Menus are drawn natively ([D6](./decisions.md)); a notification tap uses framework classes |
| Restoring running processes                  | A process cannot be serialized; the layout, titles and directories can ([`TSS`](./sessions.md))                                            |
| Session sharing, detaching, remote attach    | zellij/tmux's server model; out of scope until a consumer needs it                                                                         |
| A plugin system                              | No consumer                                                                                                                                |
| Play Store                                   | `targetSdk 28` ([NOD3](./android.md#requirements))                                                                                         |

## Owning package per obligation

| Obligation                                                             | Owner                                                         | Page                              |
| ---------------------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------- |
| The configuration schema, its layers and the settings page's subject   | `apps/terminal`                                               | [config](./config.md) `TCF`/`TSP` |
| The settings pane component (lifted from hue)                          | `sparkles:ui`                                                 | [config](./config.md) `TSP`       |
| The command table, chords and leader                                   | `apps/terminal`; machinery `sparkles:ui` `KEY`/`LTN`          | [keymap](./keymap.md) `TKM`       |
| Escape-sequence semantics, replies and events                          | `sparkles:terminal-view`                                      | [protocols](./protocols.md) `TPR` |
| What the app does with an event (a notification, a title, a clipboard) | `apps/terminal`                                               | [protocols](./protocols.md) `TPR` |
| About, log, notification-log pages                                     | `apps/terminal`; the log ring `sparkles:base`                 | [pages](./pages.md) `TPG`         |
| Selection model, word/URL expansion                                    | `sparkles:terminal-view`                                      | [selection](./selection.md) `TSE` |
| Handles, the menu, autofill                                            | `apps/terminal`; JNI `sparkles:android`                       | [selection](./selection.md) `TSE` |
| Respawn, the pane pool                                                 | `sparkles:terminal-view`                                      | [sessions](./sessions.md) `TSS`   |
| Exit prompt, tabs, splits, restore                                     | `apps/terminal`; layout `sparkles:ui` `DCK`                   | [sessions](./sessions.md) `TSS`   |
| Every surface's look                                                   | the chosen mockup; [design system](../design-system/index.md) | [design](./design.md)             |

## Pages

| Page                         | Owns                                                                                    |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| [Android](./android.md)      | the Android app: packaging, session modes, the bootstrap, Android integration (`NOD`)   |
| [Configuration](./config.md) | `TerminalConfig`, its layers, `config show/write`, the settings page (`TCF`, `TSP`)     |
| [Keymap](./keymap.md)        | the command table, chords, leader, the lantern guide, the MENU key (`TKM`)              |
| [Protocols](./protocols.md)  | titles, links, notifications, colour scheme, kitty keyboard, paste, OSC 52, cwd (`TPR`) |
| [Pages](./pages.md)          | about, logs, notification log (`TPG`)                                                   |
| [Selection](./selection.md)  | touch selection, handles, the selection menu, autofill (`TSE`)                          |
| [Sessions](./sessions.md)    | exit prompt, tabs, splits, restore, deep-link focus (`TSS`)                             |
| [Design](./design.md)        | the mockup register and the design-system rules every surface meets                     |
| [Decisions](./decisions.md)  | D6 onward (Android's D1–D5 stay on its page)                                            |
| [Delivery plan](./PLAN.md)   | milestones, gates, exclusions                                                           |
| [Testing](./testing.md)      | oracles and the evidence ledger                                                         |

**Status legend** (requirement rows): `not started` · `partial` (names what is
missing) · ``full (`sha`)`` · `open` — the row's **layout** waits on a chosen
mockup ([D10](./decisions.md)); its behaviour is agreed. Evidence uses
`unverified` / `partial` / `verified` per [the spec
guideline](../../guidelines/spec-docs.md#keep-evidence-scoped-and-honest).
Rows trace to the design (`Traces to`) until delivered; only delivered rows
are checked by `ci --check-spec-evidence`.
