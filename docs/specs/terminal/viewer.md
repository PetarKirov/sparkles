# Opening files in the app: the embedded document viewer (`TDV`)

_**Status:** proposed · **Date:** 2026-10-02 · **Owners:** `apps/terminal`
(routing an open request to a pane); the document-viewer library extracted
from hue ([`UIA14`](../hue/ui-architecture.md)) · **Scope:** what happens when
a program in the terminal asks to open a local file, and the viewer pane that
shows it._

## Why

`xdg-open README.md` on the desktop hands the file to whatever the desktop
associates with it; `termux-open README.md` on Android is refused outright
([NOD18](./android.md#android-integration)), because handing a private file to
another app needs a content provider. Yet the repository already has a
GPU document viewer that renders source code, markdown, DSV tables, ANSI and
images — hue — built on the same toolkit and host as the terminal. Opening a
file it can show **inside** the terminal, as a tab or a split beside the
shell that asked, is both the better experience and, on Android, the only one
that works.

hue's viewer is today application code (`viewer_model.d`, `document.d`,
`gui_preview.d`, and the GPU half of `gui.d`). Embedding it requires the
extraction [`UIA14`](../hue/ui-architecture.md) specifies; the terminal must
not depend on `apps/hue`.

## Requirements

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                       | Status      | Traces to                   |
| ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | --------------------------- |
| `TDV1`  | An **open request** for a local file — `xdg-open`, `termux-open`, `am start -a android.intent.action.VIEW -d file://…`, an OSC 8 `file:` link, or the selection menu's Open — must open the file **inside the app** when the viewer supports its content kind (hue's detection: source by language, markdown, DSV, ANSI, images). Unsupported kinds keep today's behaviour: the desktop's handler, Android's refusal ([NOD18](./android.md#android-integration)). | not started | [D31](./decisions.md)       |
| `TDV2`  | Where it opens is `open.target`: `tab` (default), `splitRight`, `splitDown`, or `external` (always today's behaviour). The new pane is placed relative to the pane whose program made the request, and focused.                                                                                                                                                                                                                                                   | not started | [`TSS8`](./sessions.md)     |
| `TDV3`  | The requesting command must return promptly: status `0` once the pane is open; `1` with a message on stderr for a missing or unreadable file. It must not wait for the pane to close.                                                                                                                                                                                                                                                                             | not started | `classify` (`am_command.d`) |
| `TDV4`  | **Desktop interception:** each session's `PATH` starts with an app-owned directory holding an `xdg-open` that forwards the request to the app over a per-app socket (exported as `SPARKLES_TERMINAL_SOCKET`) and, for anything the app declines, execs the next `xdg-open` on `PATH`. Off with `open.intercept = false`. **Android:** the existing `am` server ([NOD13](./android.md#requirements)) receives the request.                                         | not started | `startAmServer`             |
| `TDV5`  | A viewer pane is a pane like a terminal pane: it takes part in tabs, splits, focus, zoom, close and restore ([`TSS`](./sessions.md)) — restore re-opens the path, or shows a located error if it is gone. Its title is the file name and its icon the content kind's.                                                                                                                                                                                             | not started | `DockLayout`                |
| `TDV6`  | Inside a viewer pane, keys belong to the viewer (there is no program): the document viewer's own bindings — views, wrap, line numbers, search, folding, motion ([`KBD2`](../design-system/keyboard.md)) — with `q`/`Esc` closing the pane ([`KBD1`](../design-system/keyboard.md)). By touch, hue's Android gestures ([`AND6`](../hue/android.md)): drag scroll and fling, pinch zoom, long-press selection, copy.                                                | not started | [`TKM4`](./keymap.md)       |
| `TDV7`  | The viewer follows the terminal's chrome theme ([D17](./decisions.md)) and its light/dark switches ([`TPR13`](./protocols.md)), so a file opened beside a shell matches it.                                                                                                                                                                                                                                                                                       | not started | `Theme.effectivePalette`    |
| `TDV8`  | A file changed on disk while open must be reloaded with the first visible line kept in place (hue's [`NAV5`](../hue/viewer.md)); a deleted file keeps its last content with a banner.                                                                                                                                                                                                                                                                             | not started | `NAV5`                      |
| `TDV9`  | Document content is untrusted: links inside it open through the allow-list ([`TPR6`](./protocols.md)); markdown inclusion is confined ([`VIW7`](../hue/viewer.md)); the viewer never executes anything the document names.                                                                                                                                                                                                                                        | not started | `TPR6`, `VIW7`              |
| `TDV10` | The terminal's own markdown pages — the credits ([`TPG12`](./pages.md)) and anything else the app shows as a document — are rendered by this same viewer, not by a second renderer.                                                                                                                                                                                                                                                                               | not started | [`TPG12`](./pages.md)       |
| `TDV11` | The extraction itself is [`UIA14`](../hue/ui-architecture.md)'s, owned by hue's spec; the terminal consumes the library and adds no viewer code of its own.                                                                                                                                                                                                                                                                                                       | not started | `UIA14`                     |
| `TDV12` | Activating a link to a local file the viewer supports opens it per `open.target` (`TDV2`); a long-press (or right-click) opens a **file card** (mockup L3) naming the file, its directory, its content kind and size, with **New tab**, **Split right**, **Split down** and **Replace pane**, then Copy path, Share and Other app…. Both a tab and a split are first-class (mockups V1 and V2): `open.target` chooses the default, the card the exception.        | open        | [design](./design.md)       |

## Open questions

1. **Grammars on Android.** hue's APK carries every bundled tree-sitter
   grammar; the terminal's does not. Ship all of them (size), a common subset,
   or download on demand? Affects `TDV1`'s "supported" set on Android. Decide
   with the extraction milestone.

→ [Overview](./index.md) · [Sessions](./sessions.md) · [hue `UIA14`](../hue/ui-architecture.md)
