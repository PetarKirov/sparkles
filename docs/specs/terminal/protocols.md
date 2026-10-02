# Terminal protocols (`TPR`)

_**Status:** proposed · **Date:** 2026-10-02 · **Owners:**
`sparkles:terminal-view` (parsing, replies, the events it raises) and
`apps/terminal` (what an event does: a tab title, a notification, a
clipboard write) · **Scope:** the escape sequences a program inside the
terminal may use to talk to it, beyond what the VT engine handles itself._

## Why

libghostty-vt implements the screen. What it leaves to its host is anything
that reaches outside the screen — a title, the working directory, a
notification, the clipboard, the system's colour scheme — and the input side:
how keys and pastes are encoded. Today the host does some of it (the window
title; OSC 10/11/12 colour queries, `osc_query.d`) and drops the rest.

## What the engine provides, verified

Read from the pinned libghostty-vt headers (`0.1.0-dev+4749c4e`,
`include/ghostty/vt/`), not from documentation:

| Facility                                                | Provided as                                                                                                                                                                             | Gap                                                                                                                           |
| ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| OSC 0/2 title                                           | `GHOSTTY_TERMINAL_OPT_TITLE_CHANGED` effect + `GHOSTTY_TERMINAL_DATA_TITLE`                                                                                                             | wired today (`effect_title_changed`); OSC 1 (icon name) has no effect                                                         |
| OSC 7 / OSC 9 / OSC 1337 working directory              | `GHOSTTY_TERMINAL_OPT_PWD_CHANGED`                                                                                                                                                      | not wired                                                                                                                     |
| `CSI ? 996 n` colour-scheme query                       | `GHOSTTY_TERMINAL_OPT_COLOR_SCHEME` callback                                                                                                                                            | wired, answers nothing (`effect_color_scheme`)                                                                                |
| Mode 2031 (scheme reports), mode 2004 (bracketed paste) | `GHOSTTY_MODE_COLOR_SCHEME_REPORT`, `GHOSTTY_MODE_BRACKETED_PASTE`                                                                                                                      | the unsolicited report on a scheme **change** is the host's to send                                                           |
| Default fg/bg/cursor/palette                            | `GHOSTTY_TERMINAL_OPT_COLOR_*`                                                                                                                                                          | OSC 10/11/12 **queries** are dropped by the engine; `osc_query.d` answers them. OSC 4 queries are not answered                |
| Kitty keyboard protocol                                 | the key encoder, `GHOSTTY_KITTY_KEY_*` flags, `ghostty_key_encoder_setopt_from_terminal`                                                                                                | the encoder follows the program's pushed flags; Android's soft-keyboard text bypasses it (`sparkles.android.ime` writes text) |
| Paste encoding and safety                               | `ghostty_paste_encode`, `ghostty_paste_is_safe`                                                                                                                                         | used by `sendPaste`; no confirmation                                                                                          |
| OSC 52, OSC 9 / 99 / 777 notifications, OSC 1           | the standalone OSC parser recognizes them (`GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS`, `…SHOW_DESKTOP_NOTIFICATION`, `…CHANGE_WINDOW_ICON`) but exposes **only** the title string as data | the terminal never surfaces them; the host must parse their payloads itself, as it does colour queries                        |

So most of this page is the host's own scanner and policy; the engine is
extended only if a payload cannot be obtained otherwise (open question 1).

## Authorities

| Protocol                    | Authority (interoperability target)                                                                                       |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| OSC 0/1/2/4/7/8/10/11/12/52 | XTerm Control Sequences (invisible-island.net `ctlseqs`), the edition current at implementation, pinned in `testing.md`   |
| OSC 8                       | the "Hyperlinks in terminal emulators" specification (egmontkob), as implemented by Ghostty                               |
| OSC 99                      | kitty's desktop-notifications protocol (sw.kovidgoyal.net/kitty/desktop-notifications)                                    |
| OSC 9 (bare text), OSC 777  | iTerm2's OSC 9 "post notification"; rxvt-unicode's `notify` extension (`777;notify;title;body`) — as Ghostty accepts them |
| Mode 2031, `CSI ? 996 n`    | Contour's "colour palette update notifications" extension, as Ghostty and kitty implement it                              |
| Kitty keyboard protocol     | sw.kovidgoyal.net/kitty/keyboard-protocol                                                                                 |
| Bracketed paste (2004)      | XTerm ctlseqs                                                                                                             |

`OSC 9;<n>;…` with a numeric first field is ConEmu's family (progress, sleep,
…) and is **not** a notification; the parser already distinguishes them.

## Requirements

### Titles, icons, working directory

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                                      |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------------- |
| `TPR1` | OSC 2 must set the pane's title; OSC 1 its icon string; OSC 0 both. The pane's title and icon label its tab and its split header, and the focused pane's title is the window title (desktop) — [D21](./decisions.md). Today OSC 0/2 reach only the window title.                                                                                                      | partial     | `effect_title_changed`, `CoreState.titleDirty` |
| `TPR2` | Titles and icon strings are attacker-controlled: control characters (C0, C1, DEL) must be removed, a title truncated to 256 bytes at a code-point boundary, an icon to its first grapheme cluster and to at most 2 cells. Violation: a title fixture containing `ESC`, `BEL` or a 1 MiB payload rendering as anything but the sanitized text.                         | not started | proposed `osc_scan`                            |
| `TPR3` | Without an OSC 1 icon, the icon must come from the pane's foreground process name (`tcgetpgrp` on the pty master → its executable name) through a table of Nerd Font icons ([`GLY4`](../design-system/glyphs.md)), and fall back to a generic terminal glyph; on a target without `nerdFont`, to no icon. A user rename pins the title against OSC 0/2 until cleared. | not started | `GLY4`                                         |
| `TPR4` | OSC 7 (`file://host/path`) must update the pane's working directory; a new tab or split opened from that pane starts there, and session restore (`TSS`) records it. A URI whose host is not the local host, or whose path does not exist, is ignored.                                                                                                                 | not started | `GHOSTTY_TERMINAL_OPT_PWD_CHANGED`             |

### Links

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                  |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------- |
| `TPR5` | A link is an OSC 8 hyperlink, else a detected `http(s)://` URL under the point. On a touch screen a tap on a link acts per `links.tap` — `confirm` (default): highlight it and show a bar with the full URI and Open / Copy / Share; `open`: open at once; `off`: the tap falls through to showing the keyboard. `links.longPress` does the same for a long-press, defaulting to `off` (a long-press selects, `TSE1`).                | not started | [D12](./decisions.md)      |
| `TPR6` | **Open** must launch only URIs whose scheme is in the allow-list (`http`, `https`, `mailto`, plus `links.schemes`); any other scheme gets Copy and Share but no Open. On Android a `file:` URI is refused as `termux-open` refuses it ([NOD18](./android.md#android-integration)). The URI shown is the URI opened — never the link text. Violation: an OSC 8 link whose text is `https://a` and URI `javascript:…` opening anything. | not started | [D13](./decisions.md)      |
| `TPR7` | On the desktop, links keep hover underline and pointer shape; Ctrl+click opens through the same allow-list (today it opens any scheme with `xdg-open`/`open`), and a right-click offers the confirm bar's actions. The bindings reference must say Ctrl+click (it says click).                                                                                                                                                        | partial     | `handle_mouse` (`input.d`) |

### Notifications

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status      | Traces to                          |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ---------------------------------- |
| `TPR8`  | OSC 9 (bare text), OSC 777 `notify;title;body` and OSC 99 (kitty, including its multi-chunk `d=0`/`i=` form and the title/body `p=` field) must each yield one notification event carrying the source pane, a title and a body. Payloads are attacker-controlled: controls removed, title capped at 256 and body at 1024 bytes, base64 (`e=1`) decoded only when valid. Unsupported kitty fields (icons, buttons, sounds) are ignored, not errors.                                                     | not started | [D14](./decisions.md)              |
| `TPR9`  | A notification must become a **system notification only if not seen** — the app is in the background, the screen is off, or the source pane is not visible (another tab, a zoomed-out split) — and otherwise a toast on the pane (`notifications.when = unseen`, the default; `always`; `never`). Every notification, shown or not, is appended to the notification log ([`TPG`](./pages.md)).                                                                                                         | not started | [D14](./decisions.md)              |
| `TPR10` | **Android:** a channel `terminal` is created once; a post that fails (permission denied, channel blocked) is a logged warning and the toast still shows. Notifications from one pane replace the previous one from that pane (`tag` = pane id) rather than stacking without limit.                                                                                                                                                                                                                     | not started | proposed `sparkles.android.notify` |
| `TPR11` | **Linux desktop:** notifications go to `org.freedesktop.Notifications` over D-Bus with a default action; **macOS:** a toast and the log until a native path exists (recorded as `partial` until then).                                                                                                                                                                                                                                                                                                 | not started | [D14](./decisions.md)              |
| `TPR12` | **Deep link:** activating a system notification must bring the app forward with the source pane's tab selected and the pane focused; if the pane has closed, the notification log opens with the entry selected. Linux: the D-Bus `ActionInvoked` signal. Android: the tapped intent read on resume — its feasibility without Java is a spike ([D15](./decisions.md)); if it fails, the fallback is: exactly one notification posted while away → focus its pane, otherwise open the notification log. | not started | [D15](./decisions.md)              |

### Colours and the system scheme

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                            | Status      | Traces to                                     |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------------------------- |
| `TPR13` | The terminal must follow the system light/dark setting when `appearance.followSystem` is on (the default unless the Termux layer pins colours, [`TCF3`](./config.md)): on a change, every pane recolours to `appearance.colors.dark` or `.light` (built-in pair by default). Sources: Android `Configuration.uiMode`, read on resume and on configuration change; Linux the XDG desktop portal `org.freedesktop.appearance color-scheme`; macOS the system appearance. | not started | [D16](./decisions.md); `TerminalView.recolor` |
| `TPR14` | `CSI ? 996 n` must be answered `CSI ? 997 ; 1 n` (dark) or `CSI ? 997 ; 2 n` (light) from the scheme in effect; a pane with mode 2031 set must receive that report unsolicited on every change, once per change. Violation: a recording pty seeing no report after a switch, or a report with mode 2031 reset.                                                                                                                                                         | not started | `effect_color_scheme`                         |
| `TPR15` | OSC 10/11/12 queries must be answered with the colours in effect after a scheme change (they are answered today, from the colours at open); OSC 4 queries (`4;n;?`) must be answered for indices 0–255 in the same `rgb:rrrr/gggg/bbbb` form and terminator as the query.                                                                                                                                                                                              | partial     | `osc_query.d`, `OscScanner`                   |

### Input: keys and paste

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                           | Status      | Traces to                                        |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------ |
| `TPR16` | The kitty keyboard protocol must be honoured for every flag a program pushes (disambiguate, report events, alternates, all keys, associated text) for hardware keys on every platform, including key release and repeat where the host reports them. Today the encoder follows the program's flags on the desktop; Android hardware keys are unverified.                                                              | partial     | `ghostty_key_encoder_setopt_from_terminal`       |
| `TPR17` | Android soft-keyboard text, under a pushed kitty mode, must be encoded as a synthetic press+release of the key that produces it where one exists (letters, digits, punctuation on a US layout, Enter, Backspace, Tab), and as associated text otherwise (`©`, emoji) — [D23](./decisions.md). Extra-keys taps are real key events carrying the latched modifiers. Without a pushed mode, today's bytes are unchanged. | not started | `sparkles.android.ime`, `event_map.d`            |
| `TPR18` | Paste — `Ctrl+Shift+V`, the menu's Paste ([`TSE`](./selection.md)), or a host paste event — must be bracketed when mode 2004 is set. C0 controls other than `HT`, `LF`, `CR` are removed, and no byte sequence in the pasted text may end the bracket early (`ESC [ 201 ~` cannot pass through). Violation: a fixture containing `\e[201~rm -rf ~\n` arriving with the bracket closed before `rm`.                    | partial     | `TerminalView.sendPaste`, `ghostty_paste_encode` |
| `TPR19` | Without mode 2004, a paste containing a line break must first show a confirmation with the line count and a preview (`paste.confirm = multiline`, default; `always`; `never`). Cancelling sends nothing.                                                                                                                                                                                                              | not started | [D22](./decisions.md)                            |

### Clipboard (OSC 52)

| ID      | Requirement                                                                                                                                                                                                                                                                                                                            | Status      | Traces to             |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------- |
| `TPR20` | OSC 52 writes (`52;c;<base64>`) must set the system clipboard when `clipboard.osc52.write` is on (default) and show a "Copied by _pane title_" toast; invalid base64 is ignored. A write is capped at 1 MiB decoded; larger is ignored with a logged warning. The payload is never logged.                                             | not started | [D29](./decisions.md) |
| `TPR21` | OSC 52 reads (`52;c;?`) must follow `clipboard.osc52.read`: `ask` (default) shows a confirmation naming the pane — allow once, always for this pane, or deny; `allow` answers; `deny` answers nothing. An unanswered or denied read sends nothing, and the program may block until timing out — the same as a terminal without OSC 52. | not started | [D29](./decisions.md) |

## Open questions

1. **Parse OSC payloads in the host, or extend the engine?** The host already
   runs a streaming OSC scanner for colour queries (`OscScanner`, a 48-byte
   payload). OSC 52 and 99 need far larger payloads, bounded by `TPR8`/`TPR20`.
   Recommendation: grow the host scanner (bounded buffer, chunked base64
   decode), keeping the engine pinned; extending libghostty-vt's C API is the
   fallback if the scanner and the engine ever disagree about sequence
   boundaries. Decide at the start of the protocol milestone.
2. **Mode 2031 report on enable.** Some terminals report the current scheme
   when a program sets 2031; whether Ghostty's engine does, and whether
   programs rely on it, is to be checked against Ghostty's behaviour before
   `TPR14` is implemented.

→ [Overview](./index.md) · [Selection](./selection.md) · [Sessions](./sessions.md)
