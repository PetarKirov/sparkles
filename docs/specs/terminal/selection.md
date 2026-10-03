---
status: draft
owner: sparkles:terminal
reviewed: 2026-10-03
---

# Selection, the selection menu and autofill (`TSE`)

## Introduction

On a desktop, terminal text is selected with the mouse: drag to select, Alt
for a rectangle, a shortcut to copy. A phone has no mouse and no pointer
hover, so terminals there, Termux among them, use the touch idiom instead: a
long-press selects a word, handles drag its ends, and a menu offers what to
do with the text. Phones also lack a convenient way to type a long password
into a `sudo` or `ssh` prompt, which Termux solves by letting a password
manager fill it.

Touch and mouse disagree on almost everything except the selection itself:
where it starts and ends, whether it is a stream or a rectangle, and what text
it holds. If each input path keeps its own selection, the two drift, and the
same anchors copy different text. A menu drawn over the terminal must also
never hide the very text it acts on, though a phone screen leaves little room
beside it.

The selection is therefore a model in the embeddable component, independent
of the input that drives it: two grid points in screen-plus-scrollback
coordinates, a shape, and operations to select at a point by character, word,
URL or line, move either end, select all, and read the text. The desktop's
mouse path and the touch path both drive that one model. The menu is placed
by rules that keep the selection, its handles, the soft keyboard and the
[extra-keys row](../../glossary.md#extra-keys-row) uncovered, and falls back to
a sheet that scrolls the selection into view when no other placement works.

This page covers selecting, copying and acting on terminal text by touch and
by mouse, and filling a password into the terminal from a password manager.
The selection model belongs to `sparkles:terminal-view`; the handles, the
menu and the gestures to `apps/terminal`; sharing and autofill to
`sparkles:android`. A native Android text-selection `ActionMode` is out of
scope, because it needs Java ([D6](./decisions.md)); the menu is drawn by the
app. Which menu style is shown is configured by [`TCF11`](./config.md); what
a link tap does is [`TPR5`](./protocols.md)'s.

[Requirements](#requirements) holds the obligations and their status;
[Open questions](#open-questions) lists what is unsettled; the evidence is in
[Testing](./testing.md).

## Requirements

**TSE1: Long-press selects a word.** A long-press on the terminal **must**
select the word under the point, or a whole URL when the point is inside one,
and show both handles and the menu; a long-press on a link while
`links.longPress` is set is the link card's instead ([`TPR5`](./protocols.md)).
A word is a run of letters, digits and `_-./~:@%+`, so a path or a URL is one
word. A long-press on blank cells selects nothing and shows the menu with
Paste only.

**TSE2: One model.** The selection model **must** live in
`sparkles:terminal-view`, with the operations select-at(point, granularity),
set-end(which, point), select-all, clear and text, used by both the desktop
mouse path and touch. A block selection's text is the rectangle's rows joined
by `\n`; a stream's joins soft-wrapped rows without a newline. Violation: the
desktop and touch paths producing different text for the same anchors.

**TSE3: Handles.** Two handles **must** mark the selection's ends. Dragging
one moves that end cell by cell, and the ends may cross, swapping roles.
Dragging a handle within one cell of the pane's top or bottom edge scrolls
the scrollback at a rate proportional to the overshoot, bounded; under
reduced motion ([`ACC5`](../design-system/SPEC.md)) it steps a row at a time.
A handle's touch target is at least 48 dp, larger than its drawing.

**TSE4: Gestures around a selection.** While a selection is shown, a
one-finger drag that starts on a handle **must** move it and never scroll; a
drag elsewhere scrolls and keeps the selection; a tap elsewhere clears it.
Output that scrolls the selected text away keeps the selection on its text,
since it is anchored in scrollback coordinates, and clearing the screen or
the scrollback clears it.

**TSE5: The menu.** The menu **must** be, by `ui.selectionMenu`
([`TCF11`](./config.md)), a bottom sheet over the pane (mockup S2), an
anchored card (B1) or a compact pill of icons (B4). It shows a line saying
what is selected, then a horizontally swipeable action row: Copy, Paste,
Select all, Share, Find (search the scrollback for the selected text), Run
(in a new pane) and more, ending in **More**, which lists the rest. The row is
sized so its last visible item is cut off at the edge, with an edge fade and
no scrollbar, so it reads as scrollable without a page indicator. Open URL
appears when the selection is, or contains exactly one, link, opened through
[`TPR6`](./protocols.md)'s allow-list. Share is Android `ACTION_SEND` text,
and Autofill password (`TSE8`) is a full-width row below. An item that cannot
act is hidden, not disabled. Copy clears the selection and confirms with a
toast. Labels follow `ui.buttonLabels` ([`TCF9`](./config.md)).

**TSE6: Placement.** A card or pill **must** sit above the selection, flip
below it when there is no room, and slide horizontally to stay inside the
pane, and it **must never** cover the selected text, its handles, the soft
keyboard or the extra-keys row (mockups B1, B4). When no position satisfies
that, as for a selection taller than the room around it, that occurrence is
shown as the sheet instead (B3). A sheet **must not** hide the selection
either: when it would, the pane scrolls its content up until the selection's
end and its handle sit above the sheet, and a transient note says so (B2,
B3); dismissing the menu restores the scroll position. Back, `Esc`, a tap
outside or a scroll dismisses the menu and keeps the selection, and the press
that dismisses does not reach the terminal. A placement test covers the flip,
the slide, the keyboard inset and both fallbacks.

**TSE7: The desktop.** On the desktop, a drag **must** select, Alt **must**
make the selection a rectangle, and Shift **must** bypass the program's mouse
reporting, all over the model. A double-click selects a word and a
triple-click a line. A right-click opens a context menu at the selection
(mockup X1): Copy, Paste and Select all, then Find in scrollback and Run in a
new pane, then More, each with its icon and shortcut, without Share or
Autofill.

**TSE8: Autofill password.** On Android, Autofill password **must** be shown
only when `AutofillManager.isEnabled()` holds and the hidden input field
exists. Activating it switches the field to a password input with the
`password` autofill hint and requests autofill for it. The value the service
fills is written to the pty as typed text and then cleared from the field,
and the field returns to its normal mode. Cancelling sends nothing, and a
request still open when the terminal's echo returns is cancelled.

**TSE9: The secret stays in the pty.** The autofilled value **must** reach
only the pty: never the IME diff, which would send backspaces for the
sentinel run, the log, the screen oracle's `keys.txt`, the clipboard or the
notification log. Violation: a fake service filling a marker, then a search
for it in each.

**TSE10: The Autofill chip.** An Autofill chip **must** be offered above the
keyboard while the focused pane's pty has `ECHO` off and `ICANON` on, which is
how a program reads a password (`sudo`, `ssh`, `gpg`). The pty is checked with
`tcgetattr` on the master at most once per frame, and only while the soft
keyboard is shown. The chip disappears when echo returns.

### Status

| ID      | Status                                                                                                                                                                                                           | Traces to                                                                                                     |
| ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `TSE1`  | full                                                                                                                                                                                                             | `SelectionUi.longPress`, `selectAt`, `spanAt`, `wordSpan`, `urlSpan`, `tapLink`                               |
| `TSE2`  | full                                                                                                                                                                                                             | `selectAt`, `moveEnd`, `withSelectionText` (`selection.d`); `handle_mouse` (`input.d`)                        |
| `TSE3`  | full                                                                                                                                                                                                             | `handlesOf`, `edgeScroll`, `SelectionUi.contact`, `animationsRemoved`, `DroidPlatform.reducedMotion`          |
| `TSE4`  | full                                                                                                                                                                                                             | `SelectionUi.tap`, `SelectionUi.wheel`, `selectionEmptied`, `bounds`                                          |
| `TSE5`  | full                                                                                                                                                                                                             | `ActionMenu`, `touchActions`, `singleLink`, `findSelection`, `runInNewPane`                                   |
| `TSE6`  | full; the pill is host-tested only                                                                                                                                                                               | `placeCard`, `liftFor`, `ActionMenu.placeIn`, `liftContent`                                                   |
| `TSE7`  | full                                                                                                                                                                                                             | `desktopActions`, `SelectionUi.rightClick`, `shortcutsFrom`; `handle_mouse` (`input.d`)                       |
| `TSE8`  | full                                                                                                                                                                                                             | `autofillAvailable`, `requestPasswordAutofill`, `cancelPasswordAutofill`, `takeAutofilled`; `installImeField` |
| `TSE9`  | partial: on the device a fake fill of a marker reached the pty but not the log file, `keys.txt` or logcat, and the IME diff sent no backspaces; no test searches the ring, the clipboard or the notification log | `autofillOwnsField`, `fakeAutofill`; `ime_diff.d`                                                             |
| `TSE10` | full                                                                                                                                                                                                             | `AutofillChip`, `chipShown`, `ptyReading`                                                                     |

## Open questions

1. **Autofill services that draw a dropdown.** Autofill services anchor their
   dropdown to the requesting view, and the hidden field is 1×1 and
   transparent. Google's service offers its passwords as inline suggestions in
   the keyboard's strip, which does not depend on the field's size
   ([Testing](./testing.md)); a service that draws a dropdown instead is
   untried. If such a service shows nothing, the field is sized to the
   selection's or the cursor row's rectangle while the request is open.
   Affects `TSE8`.
2. **Adopting `POP`.** The toolkit's anchored-overlay primitive
   ([`POP`](../ui/popup.md)) does not exist yet, so the menu is placed by a
   local function that follows its contracts: a text-range anchor
   ([`ANC1`](../ui/popup.md)), flip-then-slide with the start edge pinned
   (`PLC5`–`PLC8`), the soft keyboard and the extra-keys row as boundary
   insets (`PLC14`), the last side as an input (`PLC13`), and dismissal with a
   reason, where Esc and Back are one cause (`DSM2`, `DSM3`). Whether the
   menu moves onto `POP`, and when, is decided with `POP`'s delivery.

→ [Overview](./index.md) · [Protocols](./protocols.md) · [Anchored overlays](../ui/popup.md)
