---
status: accepted
owner: sparkles:terminal
reviewed: 2026-10-29
---

# Opening files in the app: the embedded document viewer (`TDV`)

## Introduction

Programs in a terminal ask to open files all the time: `xdg-open README.md`,
a link to a source file in a compiler's output, an OSC 8 `file:` link. On the
desktop the request goes to whatever application the desktop associates with
the file. On Android it fails outright: handing a private file to another app
needs a content provider, which this app cannot have without Java
([NOD18](./android.md#android-integration)).

Sparkles has a document viewer that renders source code, Markdown, tables of
delimiter-separated values, ANSI art and images: hue's, built on the same
toolkit and [application host](../../glossary.md#application-host) as the
terminal. Opening a file it can show inside the terminal, as a tab or a split
beside the shell that asked, is the better experience on the desktop and the
only one that works on Android. That needs the viewer as a library, a way for
a request from any program to reach the app and name the pane that made it,
and a pane that behaves like every other pane.

The viewer therefore lives in `sparkles:doc-view`, extracted from hue
([`UIA14`](../hue/ui-architecture.md)), and the terminal embeds it as a
viewer [pane](../../glossary.md#pane). Open requests are intercepted where
programs make them, by the opener each platform's programs call — `xdg-open`
on Linux and Android, `open` on macOS, and `sparkles-open` everywhere —
placed first on each session's `PATH`. The opener writes the request to its
own terminal as an escape sequence, so the pane whose output carries it is
the pane that asked, and one mechanism serves every platform. Android's
Termux-style `am` requests, which nix-on-droid's tools send to the app's
socket server, arrive there instead, and the app finds their pane from the
requesting process's ancestry. A request opens in the app when the viewer
supports the file's [content kind](../../glossary.md#content-kind);
otherwise the desktop hands it to its default application, and Android
refuses it with a message.

This page covers what happens when a program asks to open a local file, and
the viewer pane that shows it. Routing a request to a pane belongs to
`apps/terminal`; the viewer belongs to `sparkles:doc-view`, whose extraction
is hue's to specify. Opening URLs stays with the platform's browser
([`TPR6`](./protocols.md)); editing files is out of scope, since the viewer
only reads them.

[Requirements](#requirements) holds the obligations and their status;
[Resolved questions](#resolved-questions) records what was settled; the
evidence is in [Testing](./testing.md).

## Requirements

**TDV1: Open in the app.** An open request for a local file **must** open the
file inside the app when the viewer supports its content kind, by hue's
detection: source by language, Markdown, DSV, ANSI and images. An open
request is `xdg-open`, `open` on macOS, `sparkles-open`, `termux-open`, `am
start -a android.intent.action.VIEW -d file://…`, an OSC 5379 sequence
(`TDV15`), an OSC 8 `file:` link, or the selection menu's Open. A file the
viewer does not support goes to the desktop's handler, or is refused on
Android ([NOD18](./android.md#android-integration)).

**TDV2: Where it opens.** `open.target` **must** choose where a file opens:
`tab`, the default, `splitRight`, `splitDown`, or `external`, which always
hands the file to the platform. The new pane is placed relative to the pane
whose program made the request, and focused.

**TDV3: Prompt return.** The requesting command **must** return promptly:
status `0` once the request is made, and `1` with a message on stderr for a
missing or unreadable file, checked where the command runs. It **must not**
wait for the pane to close. A request the app cannot honour once it arrives
(the file went away, the tab limit) says why in a toast.

**TDV4: Interception.** Each session's `PATH` **must** start with an
app-owned directory holding the platform's opener — `xdg-open` on Linux,
`open` on macOS — and `sparkles-open`, and each session **must** have
`SPARKLES_TERMINAL_OPEN=1`. The opener **must** turn exactly one local file
the viewer shows into an open request on its terminal (`TDV15`), and **must**
run the next opener of its name on `PATH` for anything else: flags, several
targets, a URL, a directory, a kind the viewer does not show, no controlling
terminal, or no `SPARKLES_TERMINAL_OPEN`. Android's plain shell gets the
opener as a script under `sparkles-open`, `xdg-open` and `termux-open`.
`open.intercept = false` or `open.target = external` turns this off. On
Android, nix-on-droid's `termux-open` and `am start -a VIEW` go to the `am`
server ([NOD13](./android.md#requirements)), which queues them the same way.

**TDV5: A pane like any other.** A viewer pane **must** take part in tabs,
splits, focus, zoom, close and restore like a terminal pane
([`TSS`](./sessions.md)); restore re-opens the path, or shows a located error
if the file is gone. Its title is the file name and its icon the content
kind's.

**TDV6: Viewer keys and gestures.** Inside a viewer pane, where there is no
program, keys **must** belong to the viewer: its own bindings for views, wrap,
line numbers, search, folding and motion
([`KBD2`](../design-system/keyboard.md)), with `q` and `Esc` closing the pane
([`KBD1`](../design-system/keyboard.md)). By touch it **must** take hue's
Android gestures ([`AND6`](../hue/android.md)): drag to scroll and fling,
pinch to zoom, long-press to select, and copy. The document **must** scroll
between rows ([`SCV12`](../ui/containers.md)): a drag follows the finger, a
wheel notch eases, and a key, a search or a go-to that moves the top row
starts the motion there. A gesture **must** belong to the scroller it began
on ([`SCV12`](../ui/containers.md)): a code block or a table under the pointer
that can move that way keeps it to the end, edge and fling included, else the
document does, so the document and the blocks it carries under the finger
never take one drag in turns. A notch after a pause begins anew, so notch by
notch a block scrolls to its edge and the next notch moves the document
([`COD6`](../hue/viewer.md)). A block scrolls between cells, a drag followed
and a notch eased; a touch drag that sets off sideways scrolls the block. The
pane's overlay bar sits in its right margin, giving the document its last
column back, and can be grabbed ([`SCV13`](../ui/containers.md)).

**TDV7: Matching the terminal.** The viewer **must** follow the terminal's
chrome theme ([D17](./decisions.md)) and its light and dark switches
([`TPR13`](./protocols.md)), so a file opened beside a shell matches it.

**TDV8: Live files.** A file changed on disk while open **must** be reloaded
with its first visible line kept in place (hue's
[`NAV5`](../hue/viewer.md)); a deleted file keeps its last content under a
banner.

**TDV9: Untrusted content.** Document content is untrusted. Links inside it
**must** open through the allow-list ([`TPR6`](./protocols.md)), Markdown
inclusion **must** be confined ([`VIW7`](../hue/viewer.md)), and the viewer
**must never** execute anything the document names.

**TDV10: One renderer.** The terminal's own Markdown pages, the credits
([`TPG12`](./pages.md)) and anything else the app shows as a document,
**must** be rendered by this viewer, not by a second renderer.

**TDV11: No viewer code in the app.** The terminal **must** consume the
viewer library and add no viewer code of its own; the extraction is
[`UIA14`](../hue/ui-architecture.md)'s, owned by hue's specification.

**TDV12: The file card.** Activating a link to a local file the viewer
supports **must** open it per `open.target` (`TDV2`). A long-press or a
right-click **must** open a file card (mockup L3) naming the file, its
directory, its content kind and its size, with **New tab**, **Split right**,
**Split down** and **Replace pane**, then Copy path, Share and Other app….
Both a tab and a split are first-class (mockups V1 and V2): `open.target`
chooses the default and the card the exception.

**TDV13: Reading defaults.** The terminal's viewer **must** open a document
without its line numbers or its code blocks' (`viewer.lineNumbers`,
`viewer.codeLineNumbers`, both off by default; `l` and `c` still toggle
them), and **must** set its prose — paragraphs, headings, list items — in
the interface face, its tables and code in the cell font (design-system D64).

**TDV14: Read with the finger.** A document viewer takes no typing, so on a
touch screen focusing one — a tap on it, a tab or the tree landing on it —
**must** put the soft keyboard away and **must not** raise it, and the
extra-keys row **must** stay hidden while it has the focus, unless the
keyboard is up for a field over it (the key guide's search).

**TDV15: The open request.** A program **may** ask for a file to be opened
by writing `ESC ] 5379 ; open ; <target> ST` to its terminal, `<target>` the
base64 of a path, absolute or relative to the pane's directory, or of a
`file:` URI; BEL ends it as well as ST. The app **must** open it as `TDV1`
and `TDV2` say, beside the pane whose output carried it, resolving a relative
path against the directory OSC 7 last reported ([`TPR4`](./protocols.md)),
else the pane's own. It **must** ignore a target over 2 KiB decoded, one with
a control character or ill-formed UTF-8, any verb but `open`, and every
request while the pane's last OSC 7 names another host: a program over `ssh`
names that host's files, not this one's. It **must** honour at most four
requests per frame, so printing a file full of them opens a few panes, and
**must** neither fetch nor run anything for one (`TDV9`).

### Status

| ID      | Status                                                                                                                                                                                                       | Traces to                                                                                                                                                                                                                                                                       |
| ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TDV1`  | partial (`86421bb68`): `xdg-open`, `open` (macOS), `sparkles-open`, `termux-open`, `am start -a VIEW` and OSC 5379 open in the viewer; an OSC 8 `file:` link and the selection menu's Open do not route here | [D31](./decisions.md); `checkOpen`, `viewKindOf`                                                                                                                                                                                                                                |
| `TDV2`  | full (`86421bb68`)                                                                                                                                                                                           | [`TSS8`](./sessions.md); `Workspace.openDocument`, `placementFor`, `paneOfProcess`                                                                                                                                                                                              |
| `TDV3`  | full                                                                                                                                                                                                         | `decideShim`, `openerScript`, `classify` (`am_command.d`), `awaitOpen`, `WorkspaceHost.openRequested`                                                                                                                                                                           |
| `TDV4`  | full                                                                                                                                                                                                         | `installOpenShim`, `openShim`, `decideShim`, `openerScript`, `startAmServer`                                                                                                                                                                                                    |
| `TDV5`  | partial (`86421bb68`): a viewer pane has no content-kind icon                                                                                                                                                | `DockLayout`, `PaneSpec.document`                                                                                                                                                                                                                                               |
| `TDV6`  | partial (`15bebc650`, `86421bb68`): pinch scales the window's font, and long-press selection and copy are not in the pane                                                                                    | [`TKM4`](./keymap.md); `DocViewPane.key`, `DocViewPane.wheel`, `DocViewPane.animate`, `DocViewPane.barTo`, `DocViewPane.barGeometry`, `DocViewPane.motion`, `DocViewPane.latch`, `ScrollLatch`; `FenceScroll`, `TableScroll`, `TableViewportSpec`; `WorkspaceHost.scrollViewer` |
| `TDV7`  | full (`86421bb68`); Android takes the scheme in effect at start                                                                                                                                              | `Theme.effectivePalette`, `chromeTheme`, `WorkspaceHost.setViewerColors`                                                                                                                                                                                                        |
| `TDV8`  | full (`15bebc650`)                                                                                                                                                                                           | `NAV5`, `DocViewPane.poll`                                                                                                                                                                                                                                                      |
| `TDV9`  | partial (`43860509f`, `15bebc650`): includes are confined, no URL is fetched (`fetchUrl` unset) and nothing is executed; links in the pane cannot be activated, so none reaches the allow-list               | `TPR6`, `VIW7`, `expandIncludes`                                                                                                                                                                                                                                                |
| `TDV10` | full (`86421bb68`)                                                                                                                                                                                           | [`TPG12`](./pages.md); `showCredits`                                                                                                                                                                                                                                            |
| `TDV11` | full (`caacfa304`)                                                                                                                                                                                           | `UIA14`, `sparkles:doc-view`                                                                                                                                                                                                                                                    |
| `TDV12` | open                                                                                                                                                                                                         | [design](./design.md)                                                                                                                                                                                                                                                           |
| `TDV13` | partial: line numbers off by default; the prose stays in the cell font, since Roboto at the interface step read unevenly beside cell-font tables and code, until the design system sets the viewer's type    | `ViewerConfig`, `MdViewOptions.proseRole`, `ViewerModel.proseRole`                                                                                                                                                                                                              |
| `TDV14` | full                                                                                                                                                                                                         | `DroidTerminal.viewerFocused`, `DroidTerminal.onPointer`, `DroidTerminal.geometry`                                                                                                                                                                                              |
| `TDV15` | full                                                                                                                                                                                                         | `parseOpenRequest`, `observeOsc`, `TerminalViewHooks.openRequest`, `namesAnotherHost`, `WorkspaceHost.openRequested`                                                                                                                                                            |

## Resolved questions

1. **Grammars on Android.** hue's APK carries every bundled tree-sitter
   grammar; the terminal's carries a common subset: Markdown, which the
   credits page needs, and the languages a nix-on-droid user opens most. Each
   grammar costs a parser library per ABI. This bounds `TDV1`'s supported set
   on Android ([OQ6](./decisions.md)).

2. **How a request reaches the app.** An escape sequence on the requesting
   program's own terminal, OSC 5379 (`TDV15`), rather than a per-app socket.
   A socket needed a path within each platform's length limit, a peer
   credential call per platform and a walk of the process tree to find the
   pane, and it failed on macOS, where nothing caught `open` anyway; the
   sequence names its pane by arriving in it, works wherever a pty does, and
   keeps the openers platform-specific only in their names. The number is one
   no other terminal or multiplexer assigns.

→ [Overview](./index.md) · [Sessions](./sessions.md) · [hue `UIA14`](../hue/ui-architecture.md)
