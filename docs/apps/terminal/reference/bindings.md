# Key and mouse bindings

Bindings are fixed (there is no configuration file). Everything not listed
here is encoded and forwarded to the running application — including Escape —
honoring whatever keyboard modes the application has enabled.

## Keyboard

| Shortcut        | Action                              |
| --------------- | ----------------------------------- |
| Ctrl+Shift+C    | Copy the selection to the clipboard |
| Ctrl+Shift+V    | Paste from the clipboard            |
| Ctrl+= / Ctrl++ | Increase font size                  |
| Ctrl+-          | Decrease font size                  |

Font-size changes reload every loaded face at the new size and resize the
cell grid to fit the window (the application is notified via `TIOCSWINSZ`,
like a window resize).

## Mouse

### Selection

| Gesture           | Action                                                  |
| ----------------- | ------------------------------------------------------- |
| Left drag         | Select text                                             |
| Alt + left drag   | Rectangular (block) selection                           |
| Shift + left drag | Select even when the application has captured the mouse |

Selected text renders inverted; copy it with Ctrl+Shift+C. When a TUI
application enables mouse reporting (vim, tmux, htop, …), mouse events are
forwarded to it instead — hold Shift to bypass that and select locally.

### Scrolling

The mouse wheel scrolls the viewport three lines per notch through up to
1000 lines of scrollback. When the application has mouse reporting enabled,
wheel events are forwarded to it as button 4/5 presses instead.

A scrollbar appears on the right edge whenever there is scrollback; it widens
on hover and can be clicked or dragged to jump.

### Links

OSC 8 hyperlinks and plain `http://`/`https://` URLs are recognized under the
cursor: hovering underlines the link and switches to a pointing-hand cursor,
and a left click opens it with `xdg-open`.

## Window

- The window is freely resizable; the cell grid recomputes and the
  application is notified on every resize.
- Focus in/out is reported to applications that enable focus events
  (mode 1004).
- The bell (BEL) flashes the window briefly instead of playing a sound.
- The window title follows OSC 0/2 title sequences.
