---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Terminal protocols (`TPR`)

## Introduction

Programs reach beyond the terminal's screen through escape sequences. A shell
reports its working directory, an editor sets the window title, a long build
raises a desktop notification when it finishes, `tmux` and `vim` copy text to
the system clipboard, and a theme-aware program asks whether the system is in
light or dark mode. Keys and pastes travel the other way, encoded so the
program can tell them apart.

The terminal's VT engine, libghostty-vt, interprets the screen, but most of
these sequences reach outside it and are left to the host. Their payloads
come from untrusted code: a program may be a remote host over `ssh`, so a
title must not smuggle control bytes, a link must not launch an arbitrary
scheme, a paste must not end its bracket early, and a clipboard read must not
leak what the user copied elsewhere. The protocols themselves come from
several terminals, each with its own reference, and they disagree in detail.

The host therefore scans the sequences the engine does not expose, applies a
policy to each, and names one authority per protocol as its
interoperability target. Parsing, replies and the events a pane raises belong
to `sparkles:terminal-view`, so any embedder gets the same protocol
behaviour; what an event becomes, such as a tab title, a system notification
or a clipboard write, belongs to `apps/terminal`.

This page covers titles and icons, the working directory, links,
notifications, the colour scheme, the encoding of keys and pastes, and OSC 52
clipboard access. The screen semantics are libghostty-vt's and are out of
scope, including every sequence the engine handles itself; keys are encoded
by the engine's key encoder, configured by the host. The selection menu's
Paste is [Selection](./selection.md)'s until it reaches the encoder.

[What the engine provides](#what-the-engine-provides) separates the engine's
part from the host's; [Authorities](#authorities) names the reference for
each protocol, whose pinned editions are in [Testing](./testing.md);
[Requirements](#requirements) holds the obligations and their status; [The
embedder's API](#the-embedder-s-api) lists what an embedder wires.

## What the engine provides

Read from the pinned libghostty-vt headers (`0.1.0-dev+4749c4e`,
`include/ghostty/vt/`), not from its documentation:

| Facility                                                | Provided as                                                                                                                                                                             | Left to the host                                                     |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| OSC 0/2 title                                           | `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` effect + `GHOSTTY_TERMINAL_DATA_TITLE`                                                                                                             | OSC 1 (icon name), which has no effect                               |
| OSC 7 / OSC 9 / OSC 1337 working directory              | `GHOSTTY_TERMINAL_OPT_PWD_CHANGED`                                                                                                                                                      | validating the path                                                  |
| `CSI ? 996 n` colour-scheme query                       | `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME` callback                                                                                                                                            | the answer                                                           |
| Mode 2031 (scheme reports), mode 2004 (bracketed paste) | `GHOSTTY_MODE_COLOR_SCHEME_REPORT`, `GHOSTTY_MODE_BRACKETED_PASTE`                                                                                                                      | the unsolicited report on a scheme change                            |
| Default fg/bg/cursor/palette                            | `GHOSTTY_TERMINAL_OPT_COLOR_*`                                                                                                                                                          | OSC 4/10/11/12 queries, which the engine drops                       |
| Kitty keyboard protocol                                 | the key encoder, `GHOSTTY_KITTY_KEY_*` flags, `ghostty_key_encoder_setopt_from_terminal`                                                                                                | Android's soft-keyboard text, which arrives as text rather than keys |
| Paste encoding and safety                               | `ghostty_paste_encode`, `ghostty_paste_is_safe`                                                                                                                                         | the confirmation                                                     |
| OSC 52, OSC 9 / 99 / 777 notifications, OSC 1           | the standalone OSC parser recognizes them (`GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS`, `…SHOW_DESKTOP_NOTIFICATION`, `…CHANGE_WINDOW_ICON`) but exposes **only** the title string as data | parsing every payload, as for the colour queries                     |

Most of this page is therefore the host's own scanner and policy. The engine
is extended only if a payload cannot be obtained otherwise
([resolved question 1](#resolved-questions)).

## Authorities

| Protocol                    | Authority (interoperability target)                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| OSC 0/1/2/4/7/8/10/11/12/52 | XTerm Control Sequences (`ctlseqs`)                                                                                      |
| OSC 8                       | the "Hyperlinks in terminal emulators" specification (egmontkob), as Ghostty implements it                               |
| OSC 99                      | kitty's desktop-notifications protocol                                                                                   |
| OSC 9 (bare text), OSC 777  | iTerm2's OSC 9 "post notification"; rxvt-unicode's `notify` extension (`777;notify;title;body`), as Ghostty accepts them |
| Mode 2031, `CSI ? 996 n`    | Contour's colour-palette update notifications, as Ghostty and kitty implement them                                       |
| Kitty keyboard protocol     | kitty's keyboard protocol                                                                                                |
| Bracketed paste (2004)      | XTerm Control Sequences                                                                                                  |

[Testing](./testing.md#protocol-authorities-pinned) pins the edition of each.
`OSC 9;<n>;…` with a numeric first field is ConEmu's family (progress, sleep
and others) and is **not** a notification.

## Requirements

### Titles, icons, working directory

**TPR1: Titles.** OSC 2 **must** set the [pane](../../glossary.md#pane)'s
title, OSC 1 its icon string, and OSC 0 both. The title and icon label the
pane's tab and its header, and on the desktop the focused pane's title is the
window title ([D21](./decisions.md)). The library reports both through
`TerminalViewHooks`; the application sets the window title.

**TPR2: Sanitized titles.** Titles and icon strings are attacker-controlled.
Control characters (C0, C1, DEL) **must** be removed, a title **must** be
truncated to 256 bytes at a code-point boundary, and an icon to its first
grapheme cluster and at most 2 cells. Violation: a title fixture containing
`ESC`, `BEL` or a 1 MiB payload rendering as anything but the sanitized text.

**TPR3: Process icons.** Without an OSC 1 icon, the icon **must** come from
the name of the pane's foreground process (`tcgetpgrp` on the pty master,
then its executable's name) through a table of Nerd Font icons
([`GLY4`](../design-system/glyphs.md)), falling back to a generic terminal
glyph, and to no icon on a target without `nerdFont`. A user rename pins the
title against OSC 0 and 2 until it is cleared.

**TPR4: Working directory.** OSC 7 (`file://host/path`) **must** update the
pane's working directory. A new tab or split opened from that pane starts
there, and session restore ([`TSS14`](./sessions.md)) records it. A URI whose
host is not the local host, or whose path does not exist, is ignored.

### Links

**TPR5: What a link is.** A link **must** be an OSC 8 hyperlink, or else a
detected `http(s)://` URL under the point. On a touch screen a tap on a link
acts per `links.tap`: `confirm`, the default, highlights it and shows a card
with the full URI and Open, Copy and Share; `open` opens it at once; `off`
lets the tap fall through to showing the keyboard. `links.longPress` does the
same for a long-press and defaults to `off`, so that a long-press selects
([`TSE1`](./selection.md)).

**TPR6: The allow-list.** Open **must** launch only URIs whose scheme is in
the allow-list: `http`, `https`, `mailto`, plus `links.schemes`. Any other
scheme gets Copy and Share but no Open. On Android a `file:` URI the viewer
cannot show is refused, as `termux-open` refuses it
([NOD18](./android.md#android-integration)). The URI shown is the URI
opened, never the link text. Violation: an OSC 8 link whose text is
`https://a` and whose URI is `javascript:…` opening anything.

**TPR7: Desktop links.** On the desktop, a link **must** show a hover
underline and pointer shape. Ctrl+click opens it through the same
allow-list, and a right-click offers the confirm card's actions. The
bindings reference documents Ctrl+click.

### Notifications

**TPR8: Notification events.** OSC 9 (bare text), OSC 777
`notify;title;body` and OSC 99 **must** each yield one notification event
carrying the source pane, a title and a body. OSC 99 includes kitty's
multi-chunk form (`d=0`, `i=`) and its `p=` title and body fields. Payloads
are attacker-controlled: controls are removed, the title is capped at 256
bytes and the body at 1024, and base64 (`e=1`) is decoded only when valid.
Kitty fields this terminal does not support (icons, buttons, sounds) are
ignored, not errors.

**TPR9: Unseen notifications only.** A notification **must** become a
system notification only when it would otherwise go unseen: the app is in
the background, the screen is off, or the source pane is not visible (another
tab, or a split hidden by a zoomed pane). Otherwise it is a toast on the
pane. That is `notifications.when = unseen`, the default; `always` and
`never` are the alternatives. Every notification, shown or not, is appended
to the notification log ([`TPG9`](./pages.md)).

**TPR10: Android notifications.** On Android, a channel named `terminal`
**must** be created once, and a post that fails because the permission was
denied or the channel blocked is a logged warning while the toast still
shows. A notification from a pane **must** replace the previous one from the
same pane (`tag` = pane id) rather than stacking without limit.

**TPR11: Desktop notifications.** On Linux, notifications **must** go to
`org.freedesktop.Notifications` over D-Bus with a default action. On macOS
they **must** go to the system's notification centre.

**TPR12: Deep link.** Activating a system notification **must** bring the
app forward with the source pane's tab selected and the pane focused; if the
pane has closed, the notification log opens with its entry selected. Linux
reports the activation through the D-Bus `ActionInvoked` signal. On Android,
where reading the tapped intent needs Java ([D15](./decisions.md)), the app
infers the tap on resume: when exactly one of the notifications it posted has
gone, that one names the pane; when several have, the notification log opens.

### Colours and the system scheme

**TPR13: Following the system.** When `appearance.followSystem` is on, the
terminal **must** follow the system's light or dark setting: on a change,
every pane recolours to `appearance.colors.dark` or `.light`, a built-in pair
by default. The setting is on unless the Termux layer pins the colours
([`TCF3`](./config.md)). The sources are Android's `Configuration.uiMode`,
the XDG desktop portal's `org.freedesktop.appearance color-scheme` on Linux,
and the system appearance on macOS.

**TPR14: Scheme reports.** `CSI ? 996 n` **must** be answered with
`CSI ? 997 ; 1 n` (dark) or `CSI ? 997 ; 2 n` (light) from the scheme in
effect. A pane with mode 2031 set **must** receive that report unsolicited
once per change, and no report when the mode is set. Violation: a recording
pty seeing no report after a switch, or a report with mode 2031 reset.

**TPR15: Colour queries.** OSC 10, 11 and 12 queries **must** be answered
with the colours in effect after a scheme change, and OSC 4 queries
(`4;n;?`) for indices 0–255, in the same `rgb:rrrr/gggg/bbbb` form and with
the same terminator as the query.

### Input: keys and paste

**TPR16: Kitty keyboard protocol.** The kitty keyboard protocol **must** be
honoured for hardware keys on every platform, for every flag a program
pushes: disambiguate, report events, alternates, all keys and associated
text, including key release and repeat where the host reports them.

**TPR17: Soft-keyboard text.** Under a pushed kitty mode, Android
soft-keyboard text **must** be encoded as a synthetic press and release of
the key that produces it where one exists (letters, digits, punctuation on a
US layout, Enter, Backspace, Tab), and as associated text otherwise (`©`,
emoji); see [D23](./decisions.md). Taps on the extra-keys row are real key
events carrying the latched modifiers. Without a pushed mode the bytes are
those of plain text.

**TPR18: Bracketed paste.** A paste, whether from `Ctrl+Shift+V`, the
selection menu's Paste ([`TSE5`](./selection.md)) or a host paste event,
**must** be bracketed when mode 2004 is set. C0 controls other than `HT`,
`LF` and `CR` are removed, and no byte sequence in the pasted text may end the
bracket early. Violation: a fixture containing `\e[201~rm -rf ~\n` arriving
with the bracket closed before `rm`.

**TPR19: Multi-line paste guard.** Without mode 2004, a paste containing a
line break **must** first show a confirmation with the line count and a
preview (`paste.confirm = multiline`, the default; `always`; `never`).
Cancelling sends nothing.

### Clipboard (OSC 52)

**TPR20: Clipboard writes.** An OSC 52 write (`52;c;<base64>`) **must** set
the system clipboard when `clipboard.osc52.write` is on, as it is by default,
and show a "Copied by _pane title_" toast. Invalid base64 is ignored. A write
is capped at 1 MiB decoded; a larger one is ignored with a logged warning. The
payload is never logged.

**TPR21: Clipboard reads.** An OSC 52 read (`52;c;?`) **must** follow
`clipboard.osc52.read`: `ask`, the default, shows a confirmation naming the
pane, with allow once, always for this pane, or deny; `allow` answers; `deny`
answers nothing. An unanswered or denied read sends nothing, and the program
may block until it times out, as it would with a terminal without OSC 52.

_Rationale:_ The clipboard holds whatever the user copied anywhere, often a
password; a program on a remote host must not read it without consent.

### Status

| ID      | Status                                                                                                                                    | Traces to                                                                                                                                 |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `TPR1`  | full                                                                                                                                      | `effect_title_changed`, `TerminalView.deliverEvents`, `TerminalViewHooks`, `WorkspaceHost.paneTitle`, `treeTabs`                          |
| `TPR2`  | full                                                                                                                                      | `sanitizeTitle`, `sanitizeIcon`, `protocol_oracle.d`                                                                                      |
| `TPR3`  | partial: the icon table is hand-picked from Nerd Fonts 3.4.0, not generated by `GLY4`                                                     | `foregroundProcess`, `iconForProcess`, `TerminalView.icon`, `TerminalView.rename`                                                         |
| `TPR4`  | full                                                                                                                                      | `effect_pwd_changed`, `parseWorkingDirectory`, `TerminalView.cwd`, `WorkspaceHost.refreshCwds`                                            |
| `TPR5`  | full                                                                                                                                      | `WorkspaceHost.tapLink`, `LinkConfirm`, `TerminalView.linkAt`                                                                             |
| `TPR6`  | full                                                                                                                                      | `canOpen`, `LinkConfirm`, `WorkspaceHost.open`                                                                                            |
| `TPR7`  | full                                                                                                                                      | `handle_mouse` (`input.d`), `TerminalViewHooks.openLink`, `WorkspaceHost.open`                                                            |
| `TPR8`  | full                                                                                                                                      | `parseNotification`, `KittyNotifyAssembler`, `observeOsc`                                                                                 |
| `TPR9`  | full                                                                                                                                      | `routeNotification`, `TerminalView.setSeen`, `NotificationLog`, `DesktopIntegration.notify`, `DroidPlatform.notifyHook`, `Surfaces.toast` |
| `TPR10` | full                                                                                                                                      | `sparkles.android.notify` (`createChannel`, `post`); `DroidPlatform.notifyHook`                                                           |
| `TPR11` | partial: Linux posts through a native D-Bus client ([D43](./decisions.md)); macOS has no system notification path ([D14](./decisions.md)) | `DesktopBus.post`, `notifyBody`, `DesktopIntegration.notify`                                                                              |
| `TPR12` | full                                                                                                                                      | `DesktopBus.takeActivation`, `raiseWindow`, `deepLinkOnResume`, `activeTags`, [D15](./decisions.md)                                       |
| `TPR13` | partial: Linux and Android follow the system; macOS does not                                                                              | `TerminalView.setColorScheme`, `DesktopBus.takeScheme`, `DesktopIntegration.tick`, `sparkles.android.system_scheme`, `activeScheme`       |
| `TPR14` | full                                                                                                                                      | `effect_color_scheme`, `schemeInEffect`, `TerminalView.setColorScheme`                                                                    |
| `TPR15` | full                                                                                                                                      | `replyColorQuery`, `OscScanner`, `TerminalView.setColorScheme`                                                                            |
| `TPR16` | partial: the desktop is verified against the protocol's fixtures; Android hardware keys are not verified on a device                      | `ghostty_key_encoder_setopt_from_terminal`, `TerminalView.sendKey`                                                                        |
| `TPR17` | partial: verified on the recording pty, not with a soft keyboard on a device                                                              | `softKeyPress`, `kittyTextEvent`, `isDetachedText`                                                                                        |
| `TPR18` | full                                                                                                                                      | `stripPasteControls`, `TerminalView.sendPaste`, `ghostty_paste_encode`                                                                    |
| `TPR19` | full                                                                                                                                      | `PasteConfirm`, `TerminalView.confirmPaste`, `placeOne`                                                                                   |
| `TPR20` | full                                                                                                                                      | `WorkspaceHost.create` (`clipboardWrite`), `Surfaces.toast`                                                                               |
| `TPR21` | full                                                                                                                                      | `ClipboardRead`, `TerminalView.answerClipboardRead`                                                                                       |

## Resolved questions

1. **Parse OSC payloads in the host, or extend the engine?** In the host.
   `OscScanner`'s cap follows the command: 4096 bytes, 8192 for an OSC 99
   chunk, and the base64 of 1 MiB for OSC 52. `sparkles.terminal_view.osc_scan`
   parses the payloads, and the engine stays pinned. Extending libghostty-vt's
   C API remains the fallback if the scanner and the engine ever disagree
   about where a sequence ends.
2. **Mode 2031 report on enable?** No report on enable. Contour's extension
   sends the report "only … when the palette has been updated"; Ghostty sends
   one only on a theme change (`colorSchemeReportLocked`, unforced); and
   libghostty-vt sends nothing when 2031 is set, as the recording pty shows
   ([Testing](./testing.md)).

## The embedder's API

What `apps/terminal`, or any embedder, wires, all on `TerminalViewOptions` and
`TerminalView` in `sparkles:terminal-view`:

- **Policy:** `opts.policy` (`ProtocolPolicy`) carries `notifyWhen`
  (`notifications.when`), `pasteConfirm` (`paste.confirm`), `osc52Write` and
  `osc52Read` (`clipboard.osc52.*`); `opts.nerdFont` enables process icons.
- **Hooks:** `opts.hooks` (`TerminalViewHooks`), called from
  `TerminalView.deliverEvents` after `pump`: `titleChanged`, `iconChanged`,
  `cwdChanged`, `notify(notification, route)`, `clipboardWrite`,
  `clipboardReadRequest` (answered by `answerClipboardRead`), `clipboardText`,
  `pasteConfirm` (answered by `confirmPaste`) and `tabTitle`.
- **State the embedder keeps current:** `setSeen` (whether the pane is
  visible), `setColorScheme(scheme, colours)` on a system switch, and
  `rename`/`clearRename`.
- **The log:** `opts.notificationLog`, one `NotificationLog` shared by the
  application's panes; a pane without one keeps its own.

→ [Overview](./index.md) · [Selection](./selection.md) · [Sessions](./sessions.md)
