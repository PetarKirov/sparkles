# Key and mouse bindings

Everything not listed here is encoded and forwarded to the running
application — including Escape — honoring whatever keyboard modes the
application has enabled.

## Keyboard

The terminal claims a few chords in a pane; everything else is under the
**leader**, `Ctrl+Shift+Space` by default (`lantern.leader`). After the leader,
the key guide lists what follows once `lantern.delayMs` has passed — type
faster and it never appears. On a phone the `MENU` extra key (☰) opens the
guide. In a page or menu, `Escape`, `q` and Back close it and `?` lists its keys.

The table is the binary's own: `terminal config keys` prints it, and a test
keeps this page equal to it.

| Keys                  | Action            | Where           |
| --------------------- | ----------------- | --------------- |
| `Escape`              | close             | a page or menu  |
| `q`                   | close             | a page or menu  |
| `Back`                | close             | a page or menu  |
| `Enter`               | confirm           | a page or menu  |
| `?`                   | key guide         | a page or menu  |
| `Ctrl+Shift+C`        | copy              | a pane          |
| `Ctrl+Shift+V`        | paste             | a pane          |
| `Ctrl+=`              | larger font       | a pane          |
| `Ctrl++`              | larger font       | a pane          |
| `Ctrl+-`              | smaller font      | a pane          |
| `Ctrl+0`              | default font size | a pane          |
| `Leader ?`            | all keys          | a pane          |
| `Ctrl+Shift+T`        | new tab           | a pane          |
| `Ctrl+Shift+P`        | tabs and panes    | a pane          |
| `Ctrl+Shift+W`        | close pane        | a pane          |
| `Ctrl+Shift+PageUp`   | previous tab      | a pane          |
| `Ctrl+Shift+PageDown` | next tab          | a pane          |
| `Leader k`            | toggle extra keys | a pane          |
| `Leader a`            | about             | a pane          |
| `Leader l`            | logs              | a pane          |
| `Leader n`            | notifications     | a pane          |
| `Leader c`            | credits           | a pane          |
| `Leader t n`          | new tab           | a pane          |
| `Leader t t`          | tabs and panes    | a pane          |
| `Leader t x`          | close tab         | a pane          |
| `Leader t 1-9`        | go to tab         | a pane          |
| `Leader p v`          | split right       | a pane          |
| `Leader p s`          | split down        | a pane          |
| `Leader p h`          | focus left        | a pane          |
| `Leader p j`          | focus down        | a pane          |
| `Leader p k`          | focus up          | a pane          |
| `Leader p l`          | focus right       | a pane          |
| `Leader p Shift+H`    | resize left       | a pane          |
| `Leader p Shift+J`    | resize down       | a pane          |
| `Leader p Shift+K`    | resize up         | a pane          |
| `Leader p Shift+L`    | resize right      | a pane          |
| `Leader p z`          | zoom              | a pane          |
| `Leader p x`          | close pane        | a pane          |
| `Enter`               | run again         | the exit prompt |
| `Escape`              | shell here        | the exit prompt |
| `Ctrl+C`              | close pane        | the exit prompt |

Bindings are rebound or removed in the configuration file's `keys` section —
context (`pane`, `overlay`), then a chord path, then a command name or `null`:

```json
{ "keys": { "pane": { "leader e": "toggleExtraKeys", "ctrl+0": null } } }
```

`Ctrl-C`, `Ctrl-Z`, `Ctrl-S`, `Ctrl-Q` and `Ctrl-\` belong to the program and
cannot be bound.

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

The mouse wheel scrolls the viewport three lines per notch through the scrollback
history. When the application has mouse reporting enabled,
wheel events are forwarded to it as button 4/5 presses instead.

A scrollbar appears on the right edge whenever there is scrollback; it widens
on hover and can be clicked or dragged to jump.

### Links

OSC 8 hyperlinks and plain `http://`/`https://` URLs are recognized under the
cursor: hovering underlines the link and switches to a pointing-hand cursor.
**Ctrl+click** opens it with `xdg-open` (`open` on macOS) when its scheme is
`http`, `https`, `mailto` or one listed in `links.schemes`; any other link
opens nothing. A plain click selects, and a right-click on a link offers Copy
and, under More, Open URL. On a touch screen a tap shows the link's full
address with Open, Copy and Share first (`links.tap`).

## Window

- The window is freely resizable; the cell grid recomputes and the
  application is notified on every resize.
- Focus in/out is reported to applications that enable focus events
  (mode 1004).
- The bell (BEL) flashes the window briefly instead of playing a sound.
- The window title follows OSC 0/2 title sequences.
