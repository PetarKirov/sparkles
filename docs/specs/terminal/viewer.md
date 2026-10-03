---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
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
programs make them: an `xdg-open` on the desktop that forwards to the app,
and the `am` server on Android. A request opens in the app when the viewer
supports the file's [content kind](../../glossary.md#content-kind), and falls
through to the platform otherwise.

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
request is `xdg-open`, `termux-open`, `am start -a android.intent.action.VIEW
-d file://…`, an OSC 8 `file:` link, or the selection menu's Open. A file the
viewer does not support goes to the desktop's handler, or is refused on
Android ([NOD18](./android.md#android-integration)).

**TDV2: Where it opens.** `open.target` **must** choose where a file opens:
`tab`, the default, `splitRight`, `splitDown`, or `external`, which always
hands the file to the platform. The new pane is placed relative to the pane
whose program made the request, and focused.

**TDV3: Prompt return.** The requesting command **must** return promptly:
status `0` once the pane is open, and `1` with a message on stderr for a
missing or unreadable file. It **must not** wait for the pane to close.

**TDV4: Interception.** On the desktop, each session's `PATH` **must** start
with an app-owned directory holding an `xdg-open` that forwards the request to
the app over a per-app socket, exported as `SPARKLES_TERMINAL_SOCKET`, and
that runs the next `xdg-open` on `PATH` for anything the app declines.
`open.intercept = false` turns this off. On Android the `am` server
([NOD13](./android.md#requirements)) receives the request.

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
pinch to zoom, long-press to select, and copy.

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

### Status

| ID      | Status                                                                                                                                                                                         | Traces to                                                                          |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `TDV1`  | partial (`89cb5b577`): `xdg-open`, `termux-open` and `am start -a VIEW` open in the viewer; an OSC 8 `file:` link and the selection menu's Open do not route here                              | [D31](./decisions.md); `checkOpen`, `viewKindOf`                                   |
| `TDV2`  | full (`89cb5b577`)                                                                                                                                                                             | [`TSS8`](./sessions.md); `Workspace.openDocument`, `placementFor`, `paneOfProcess` |
| `TDV3`  | full (`89cb5b577`)                                                                                                                                                                             | `classify` (`am_command.d`), `awaitOpen`                                           |
| `TDV4`  | full (`89cb5b577`)                                                                                                                                                                             | `installOpenShim`, `xdgOpenShim`, `startOpenServer`, `startAmServer`               |
| `TDV5`  | partial (`89cb5b577`): a viewer pane has no content-kind icon                                                                                                                                  | `DockLayout`, `PaneSpec.document`                                                  |
| `TDV6`  | partial (`bfd6c4cda`, `89cb5b577`): pinch scales the window's font, and long-press selection and copy are not in the pane                                                                      | [`TKM4`](./keymap.md); `DocViewPane.key`                                           |
| `TDV7`  | full (`89cb5b577`); Android takes the scheme in effect at start                                                                                                                                | `Theme.effectivePalette`, `chromeTheme`, `WorkspaceHost.setViewerColors`           |
| `TDV8`  | full (`bfd6c4cda`)                                                                                                                                                                             | `NAV5`, `DocViewPane.poll`                                                         |
| `TDV9`  | partial (`4c6da7840`, `bfd6c4cda`): includes are confined, no URL is fetched (`fetchUrl` unset) and nothing is executed; links in the pane cannot be activated, so none reaches the allow-list | `TPR6`, `VIW7`, `expandIncludes`                                                   |
| `TDV10` | full (`89cb5b577`)                                                                                                                                                                             | [`TPG12`](./pages.md); `showCredits`                                               |
| `TDV11` | full (`9509bdf9e`)                                                                                                                                                                             | `UIA14`, `sparkles:doc-view`                                                       |
| `TDV12` | open                                                                                                                                                                                           | [design](./design.md)                                                              |

## Resolved questions

1. **Grammars on Android.** hue's APK carries every bundled tree-sitter
   grammar; the terminal's carries a common subset: Markdown, which the
   credits page needs, and the languages a nix-on-droid user opens most. Each
   grammar costs a parser library per ABI. This bounds `TDV1`'s supported set
   on Android ([OQ6](./decisions.md)).

→ [Overview](./index.md) · [Sessions](./sessions.md) · [hue `UIA14`](../hue/ui-architecture.md)
