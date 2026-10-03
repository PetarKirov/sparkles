---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Sessions: the exit prompt, tabs, splits and restore (`TSS`)

## Introduction

People keep several programs open in one terminal window: an editor, a build,
a server's log, a shell. Desktop terminals arrange them in tabs and splits; on
a phone, where the screen holds one program comfortably, the same arrangement
must stay reachable without a mouse or many keys. Programs also end, and when
one does, the user wants to know how it ended and what to do next, not to
lose the window it ran in.

A terminal that closes a pane the moment its program exits hides a failure
behind a vanished window; one that keeps a dead pane with no way out leaves
clutter. An arrangement of tabs and splits that is lost on every restart
costs the user its rebuilding, yet running processes cannot be saved and
restored.

The terminal answers both with one structure, the
[workspace](../../glossary.md#workspace): an ordered list of tabs, each a
split layout of [panes](../../glossary.md#pane), saved on every structural
change and reopened at the next start with fresh shells in the panes' last
directories. A pane whose program ends shows the
[exit prompt](../../glossary.md#exit-prompt), modelled on zellij's: the last
screen stays, the status says how the program ended, and Enter re-runs the
command, Esc starts a shell, and Ctrl+C closes the pane. A pane's directory
is the one its shell last reported (OSC 7, [`TPR4`](./protocols.md)), which
not every shell reports. A tree of tabs and panes, opened
from an [opener](../../glossary.md#opener) suited to the screen, makes the
arrangement navigable by touch.

This page covers what happens when a program ends and how many programs one
window holds. Respawning a pane and the pane pool belong to
`sparkles:terminal-view`; the workspace, the prompt, the tree and restore
belong to `apps/terminal`; the split-and-tab layout is `sparkles:ui`'s dock
([`DCK`](../ui/containers.md)). Restoring running processes is out of scope,
because a process cannot be serialized; so are detaching, session sharing and
remote attach in the style of tmux. Viewer panes take part in all of this as
[Viewer](./viewer.md) specifies.

The requirements follow in three groups, the exit prompt, tabs and splits,
and the opener, with one [status](#status) table; the evidence is in
[Testing](./testing.md).

## The exit prompt (`TSS1`–`TSS5`)

**TSS1: Exit policy.** `behaviour.onExit` **must** decide what a pane does
when its program exits: `promptOnFailure`, the default, closes it on status 0
and shows the prompt otherwise; `prompt` always shows it; `close` always
closes; `hold` keeps the screen with a status line and no actions. A pane
whose program was given explicitly (`terminal -- cmd`, a "run command" pane)
always shows the prompt, as in zellij. A death by signal counts as a failure.

**TSS2: The prompt.** The prompt **must** be a banner across the bottom of
the pane (mockup E1) that keeps the program's last screen and scrollback above
it. It shows the exit status or the signal, with a status mark that is not
colour alone ([`ACC3`](../design-system/SPEC.md)), and the command, truncated
to one line. Activating the status line expands it to the full command, its
working directory and its start and end times, scrolling when longer than the
space, and a second activation collapses it. Three actions follow: **Enter**
re-runs the same command with the same arguments, environment and directory;
**Esc** starts the user's shell in the pane's last directory; **Ctrl+C**
closes the pane. On touch the three are buttons.

**TSS3: Respawn in place.** Re-run and shell **must** replace the pane's
process in place (`TerminalView.respawn`). The pane keeps its id, title pin,
position and scrollback, with a separator line marking the boundary, and the
VT state is reset. A respawn that fails to start keeps the prompt and shows
the error.

**TSS4: The user's shell.** "The user's shell" **must** be `$SHELL`, then the
passwd entry, then `/bin/sh` on the desktop. On Android it is the session's
own command: nix-on-droid's `login` in bootstrap mode and `/system/bin/sh` in
plain mode ([NOD4, NOD7](./android.md#requirements)). The handoff from the
installer to the login ([D4](./android.md#decisions)) is a respawn of the
same pane.

**TSS5: The last pane.** Closing the last pane **must** quit the app. On
Android that also ends the process, with `exit(0)` after `runApp` returns.

## Tabs and splits (`TSS6`–`TSS12`)

**TSS6: The workspace.** The workspace **must** be an ordered list of tabs,
each a `DockLayout` of panes ([`DCK1`](../ui/containers.md)). A pane is a
`TerminalView` owned by a pool whose slots are pinned on the heap. The limits
are 32 tabs and 16 panes per tab, and a command that would exceed one is
refused with a toast.

_Rationale:_ A view cannot move once created, because its VT callbacks hold
its address.

**TSS7: Background panes run.** Every live pane **must** be pumped every
frame, visible or not, so a background tab's program keeps running and its
output keeps draining ([NOD9](./android.md#requirements)'s rule, per pane).

**TSS8: Commands.** The workspace **must** offer these commands: new tab,
close tab, next and previous tab, go to tab N, rename tab, split right, split
down, focus left, right, up and down, close pane, zoom pane (toggle filling
the tab), and resize the focused split. New panes start in the focused pane's
directory ([`TPR4`](./protocols.md)).

**TSS9: Input routing.** Input routing **must** be the container's
([`DCK13`](../ui/containers.md)): keys go to the focused pane, and a pointer
event goes to the pane under it, translated to pane-local coordinates. A tap
or click on a pane focuses it.

**TSS10: Dividers.** Dragging a divider **must** resize the split (`DCK3`).
Each pane is resized in whole cells, and its program is notified once per
settled size, not once per frame of the drag.

**TSS11: Pane chrome.** The focused pane **must** be visible without colour
([`ACC4`](../design-system/SPEC.md)) under every `ui.paneChrome`
([`TCF13`](./config.md)). `reveal`, the default, draws no chrome: it marks the
focused pane with an accent corner and shows a pane's header (title,
directory, split, zoom, close) while it is hovered on the desktop, or after a
tap on it until the next tap elsewhere on touch. `header` draws a one-line
header on every pane, bold on the focused one. `framed` draws a rounded frame
with the title set in its border, heavier on the focused one (mockup E).

**TSS12: The tree.** Tabs and their panes **must** form one tree (mockup E).
Each tab shows its icon ([`TPR1`](./protocols.md)), title, pane count and an
unseen-notification mark, and expands to its panes, each with its icon, title,
directory and a failed exit shown as such. The current tab and the focused
pane are marked. A search field filters tabs and panes by title, program and
directory, ranked by `sparkles:fuzzy`, and opens matching tabs to show their
matches. Choosing an entry selects that tab, focuses that pane, and closes the
tree where it was an overlay.

## Opening, restoring and focusing (`TSS13`–`TSS16`)

**TSS13: Opening the tree.** The tree **must** open as `ui.tabsOpener`
([`TCF12`](./config.md)) says. A `pill` names the current tab, its position
and its unseen count, and a tap on it opens the tree as a floating panel below
it. A `rail` is a narrow column of tab icons, a new-tab button and a tree
button, and a tap slides the full tree out beside it. The tree **never** opens
on an edge swipe, which belongs to the system Back gesture, and tabs are not
switched by swiping. The tree's search sits at the bottom of the panel on
touch, within reach of the keyboard, and at the top on the desktop. A tap
outside, Back or `Esc` closes it. Splits come from the pane header's actions,
the key guide and the MENU key, and in portrait a zoomed pane is the usual
way to read one of several splits.

**TSS14: Restore.** When `behaviour.restore` is on, as it is by default, the
workspace **must** be saved on every structural change and on going to the
background: the tabs, their layouts, and each pane's title pin, icon,
directory and command. The next start re-creates it with fresh shells in
those directories, and a pane that ran an explicit command comes back at its
exit prompt (`TSS2`) instead of running it again. A layout that fails to load
is discarded with a logged warning.

**TSS15: Focus from outside.** An operation naming a pane, such as a
notification's deep link ([`TPR12`](./protocols.md)) or an entry in the
notification log ([`TPG10`](./pages.md)), **must** select the pane's tab,
un-zoom another zoomed pane if needed, and focus it.

**TSS16: The guide from the opener.** On a touch screen the opener **must**
carry a `⋯` button, under `☰` on the rail and at the end of the pill's band,
whose tap opens the touch guide ([`TKM6`](./keymap.md)) whether or not the
extra-keys row is shown ([D46](./decisions.md)). Violation: no touch route to
the guide while the row is hidden.

_Rationale:_ A tablet with a keyboard cover hides the extra-keys row, and with
it the MENU key, so the opener is the one control always on screen.

## Status

| ID      | Status                                                                                                                                                                                 | Traces to                                                                                                     |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `TSS1`  | full                                                                                                                                                                                   | `exitActionFor`, `WorkspaceHost.applyExits`                                                                   |
| `TSS2`  | partial: a long command wraps and scrolls under the wheel; scrolling it by touch has not been seen on a device                                                                         | `exitBanner`, `commandLines`, `WorkspaceHost.scrollBanner`, `WorkspaceHost.tap`, `CoreState.embedderOwnsExit` |
| `TSS3`  | full                                                                                                                                                                                   | `TerminalView.respawn`, `respawnRunsTheProgramAgainInPlace`                                                   |
| `TSS4`  | partial: the installer hands over to the login by respawning the pane, which has not been seen on the phone                                                                            | `DroidTerminal.view`, `configureSession`                                                                      |
| `TSS5`  | full                                                                                                                                                                                   | `Workspace.empty`, `DesktopTerminal.view`                                                                     |
| `TSS6`  | full                                                                                                                                                                                   | `Workspace`, `TerminalPool`, `maxTabs`, `maxPanesPerTab`                                                      |
| `TSS7`  | full                                                                                                                                                                                   | `WorkspaceHost.frame`                                                                                         |
| `TSS8`  | partial: renaming a tab has no command, for want of a text field                                                                                                                       | `WorkspaceHost.run`, `Workspace.split`, `Workspace.focusToward`, `Workspace.resizeToward`                     |
| `TSS9`  | full                                                                                                                                                                                   | `handle_mouse` (pane origin), `WorkspaceHost.paneAt`, `DroidTerminal.onPointer`                               |
| `TSS10` | full                                                                                                                                                                                   | `Workspace.resizeSplit`, `Workspace.moveDivider`, `WorkspaceHost.dragDivider`, `WorkspaceHost.touchDivider`   |
| `TSS11` | partial: the reveal toolbar's split always splits right                                                                                                                                | `paneBoxes`, `paneHeader`, `paneFrame`, `paneToolbar`, `WorkspaceHost.placeChrome`                            |
| `TSS12` | full                                                                                                                                                                                   | `TabTree`, `WorkspaceHost.treeTabs`                                                                           |
| `TSS13` | full                                                                                                                                                                                   | `pillBand`, `rail`, `usesPill`, `WorkspaceHost.toggleTree`                                                    |
| `TSS14` | partial: on the phone a pane comes back in its directory only when the shell reports it with OSC 7, which nix-on-droid's bash does not, and proot hides a guest's `chdir` from `/proc` | `saved`, `restored`, `WorkspaceHost.restore`, `WorkspaceHost.refreshCwds`                                     |
| `TSS15` | full                                                                                                                                                                                   | `Workspace.focusPane`, `DesktopIntegration.tick`, `DroidPlatform.focusPane`, `NotificationPage.openEntry`     |
| `TSS16` | full                                                                                                                                                                                   | `OpenerHit.guide`, `rail`, `pillBand`, `WorkspaceHost.takeGuideRequest`                                       |

→ [Overview](./index.md) · [Containers `DCK`](../ui/containers.md) · [Keymap](./keymap.md)
