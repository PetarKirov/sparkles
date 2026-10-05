---
status: accepted
owner: sparkles:terminal
reviewed: 2026-10-02
---

# `sparkles:terminal` — Overview

## Abstract

`sparkles:terminal` is the Sparkles terminal emulator as a complete
application on Linux, macOS and Android. Around each terminal pane it provides
what people expect of a modern terminal: configuration editable from inside
the app, commands that can be found by key and by touch, text selection on a
phone, tabs and splits that survive a restart, and a prompt when a program
exits. Programs running inside it can raise notifications, write the clipboard
and follow the system's light or dark scheme, and files they ask to open
appear in a viewer pane beside them. Pages show the build, its licences and
its logs. Every feature exists on every platform, adapted to keyboard or
touch, and the Android app contains no Java.

## Introduction

A terminal emulator is two things: an engine that interprets the bytes
a program writes, and an application around it that people configure,
arrange and talk to. In Sparkles the engine is libghostty-vt, wrapped by the
embeddable `sparkles:terminal-view` component. The same component renders in
a desktop window and in a native Android app that serves as the terminal of
[nix-on-droid](https://github.com/nix-community/nix-on-droid). Without the
obligations specified here, the application around it is a single pane. On
the desktop a handful of command-line flags configure it. On Android,
which has no command line, only the configuration files of Termux, the
Android terminal nix-on-droid used before, configure it, and nothing shows
the version, the licences or what the app logged.

Growing that pane into an application is harder than adding features one by
one. A phone cannot select text, because selection is driven by mouse handling
that touch input bypasses, and it has almost no keys to bind commands to.
On the desktop the keyboard belongs to the program inside the pane, so
every key the terminal claims is one the program loses. The escape sequences
a program uses to reach beyond the screen, such as titles, notifications,
clipboard writes and links, come from untrusted code: a title must not inject
control bytes and a link must not launch an arbitrary scheme. Finally, much
of what is needed already exists in the repository, including the settings
pane of the hue code viewer and the toolkit's key-binding and split layout
machinery, and copying it into the app would fork it.

The specification therefore gives every obligation an owning package. The
component owns what any host would share: the meaning of each escape
sequence, the replies it sends, the events it raises, the selection model,
and restarting a pane's program. The application owns policy, such as what an
event becomes, which keys it claims, and how tabs and splits are arranged.
Shared pieces come from `sparkles:ui`, with hue's settings pane lifted
there so both applications use one copy. One configuration value configures
every platform: the app's own file is read above Termux's files, so an
existing Termux setup keeps working and the app's file wins where both set
a value. On the desktop the application claims only a few Ctrl+Shift chords
and a [_leader_](../../glossary.md#leader), a chord that opens a guide listing every other command,
which a phone user taps instead. Each surface's behaviour is specified in
prose; its layout is chosen from HTML mockups ([design](./design.md)).

This tree covers the application on all three platforms: configuration
and its settings page, the key table and its guide, the about, credits,
log and notification pages, touch selection and password autofill for
prompts such as `sudo`'s, the terminal protocols, the exit prompt, tabs
and splits, and opening files in an embedded document viewer. Restoring
a workspace reopens its tabs and splits with their titles, starting fresh
shells in their last directories; a pane that ran a command reopens at its
exit prompt. The screen semantics themselves belong to libghostty-vt, and
the document viewer is hue's, extracted into a library. Android packaging,
session modes and the nix-on-droid bootstrap are specified on the [Android
page](./android.md). Restoring running processes is a non-goal, because a
process cannot be serialized; so are Java components on Android, session
sharing and remote attach in the style of tmux, plugins, and Play Store
distribution. [Scope](#scope) gives the reason for each.

The [ownership table](#owning-package-per-obligation) maps each obligation
to its package and page. The topic pages, [Configuration](./config.md),
[Keymap](./keymap.md), [Protocols](./protocols.md), [Pages](./pages.md),
[Selection](./selection.md), [Sessions](./sessions.md) and
[Viewer](./viewer.md), each hold their requirements under their own ID
prefixes. [Design](./design.md) registers the mockups and the design-system
rules every surface meets, [Decisions](./decisions.md) records the choices
behind the tree, [Testing](./testing.md) holds the oracles and the evidence
ledger, and the [delivery plan](./PLAN.md) holds milestones and gates.

## Terminology

The terms this specification coins, or uses in a narrower sense than usual,
are defined once in the [glossary](../../glossary.md) and listed here:

<GlossaryList owner="sparkles:terminal" />

It also relies on the [key guide](../../glossary.md#key-guide) of
`sparkles:ui` and the [sparse overlay](../../glossary.md#sparse-overlay) of
hue's configuration.

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

| Obligation                                                             | Owner                                                                          | Page                                |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------- |
| The configuration schema, its layers and the settings page's subject   | `apps/terminal`                                                                | [config](./config.md) `TCF`/`TSP`   |
| The settings pane component (lifted from hue)                          | `sparkles:ui`                                                                  | [config](./config.md) `TSP`         |
| The command table, chords and leader                                   | `apps/terminal`; machinery `sparkles:ui` `KEY`/`LTN`                           | [keymap](./keymap.md) `TKM`         |
| Escape-sequence semantics, replies and events                          | `sparkles:terminal-view`                                                       | [protocols](./protocols.md) `TPR`   |
| What the app does with an event (a notification, a title, a clipboard) | `apps/terminal`                                                                | [protocols](./protocols.md) `TPR`   |
| About, log, notification-log pages                                     | `apps/terminal`; the log ring `sparkles:base`                                  | [pages](./pages.md) `TPG`           |
| Selection model, word/URL expansion                                    | `sparkles:terminal-view`                                                       | [selection](./selection.md) `TSE`   |
| Handles, the menu, autofill                                            | `apps/terminal`; JNI `sparkles:android`                                        | [selection](./selection.md) `TSE`   |
| Opening files in the app; the viewer pane                              | `apps/terminal`; the viewer library (hue [`UIA14`](../hue/ui-architecture.md)) | [viewer](./viewer.md) `TDV`         |
| The credits document and its licence staging                           | `docs/credits/`; the Nix builders                                              | [pages](./pages.md) `TPG12`–`TPG17` |
| Respawn, the pane pool                                                 | `sparkles:terminal-view`                                                       | [sessions](./sessions.md) `TSS`     |
| Exit prompt, tabs, splits, restore                                     | `apps/terminal`; layout `sparkles:ui` `DCK`                                    | [sessions](./sessions.md) `TSS`     |
| Every surface's look                                                   | the chosen mockup; [design system](../design-system/index.md)                  | [design](./design.md)               |

## Pages

The draft [profile extension](./profiles.md),
[configuration source/persistence extension](./profile-config.md), and
[Android development environment contract](../android-dev-env/SPEC.md) specify
cross-platform launch recipes and backend ownership. Their compatibility map
identifies proposed amendments to this accepted baseline; publication does not
claim implementation or acceptance of those amendments.

| Page                         | Owns                                                                                    |
| ---------------------------- | --------------------------------------------------------------------------------------- |
| [Android](./android.md)      | the Android app: packaging, session modes, the bootstrap, Android integration (`NOD`)   |
| [Configuration](./config.md) | `TerminalConfig`, its layers, `config show/write`, the settings page (`TCF`, `TSP`)     |
| [Keymap](./keymap.md)        | the command table, chords, leader, the lantern guide, the MENU key (`TKM`)              |
| [Protocols](./protocols.md)  | titles, links, notifications, colour scheme, kitty keyboard, paste, OSC 52, cwd (`TPR`) |
| [Pages](./pages.md)          | about, credits, logs, notification log (`TPG`)                                          |
| [Selection](./selection.md)  | touch selection, handles, the selection menu, autofill (`TSE`)                          |
| [Sessions](./sessions.md)    | exit prompt, tabs, splits, restore, deep-link focus (`TSS`)                             |
| [Viewer](./viewer.md)        | opening files inside the app; the embedded document viewer (`TDV`)                      |
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
