# CLI reference

```
terminal [options] [-- command [args...]]
```

With no command, the login shell (`$SHELL`) runs interactively. With a
command, the shell runs it via `-c` and exits when it finishes. A leading
`--` separator is accepted and stripped; options after it — including the
command's own flags — are passed through untouched.

When invoking through dub, remember dub consumes the first `--`:
`dub run :terminal -- --font-size 14 -- vim file`.

## Options

| Option                             | Default           | Description                                                            |
| ---------------------------------- | ----------------- | ---------------------------------------------------------------------- |
| `--font`, `-f`                     | `monospace`       | Font file path or fontconfig name (resolved with `fc-match`)           |
| `--font-size`, `-s`                | `13`              | Font size in points (converted to pixels at 96 DPI)                    |
| `--window-width`                   | `100`             | Initial window width in columns                                        |
| `--window-height`                  | `30`              | Initial window height in rows                                          |
| `--scrollback-limit`               | `infinite`        | Maximum number of lines to keep in scrollback (0 to disable)           |
| `--font-codepoint-map`             | —                 | Render codepoint ranges from a specific font (repeatable); see below   |
| `--ui-font`                        | the desktop's¹    | The chrome's proportional face (tabs, buttons, menus); `none` keeps the cell font; see below |
| `--exit-behavior`                  | `hold-on-failure` | What to do when the child exits; see below                             |
| `--debug-take-screenshot-and-exit` | off               | Take a screenshot after ~2 seconds and exit (used by tests/benchmarks) |
| `--help`, `-h`                     | —                 | Show usage                                                             |

¹ On the native window; see [`--ui-font`](#ui-font).

## `--exit-behavior` {#exit-behavior}

Controls what happens when the child process (the shell or command) exits:

| Value             | Behavior                                                                       |
| ----------------- | ------------------------------------------------------------------------------ |
| `close`           | Close the window immediately (the xterm/Ghostty default)                       |
| `hold-on-failure` | **Default.** Close on a clean exit (status 0); stay open when the child failed |
| `hold`            | Stay open until the window is closed manually                                  |
| `wait-for-key`    | Stay open until any key is pressed                                             |

While held open, the final output remains scrollable and a banner shows
`[process exited with status N]`.

## `--ui-font` {#ui-font}

The face the chrome draws its words in — tab titles, buttons, menus, labels —
while the panes keep the cell font: a path, a family name, or a comma-separated
preference list (the first installed family wins); `none` draws the chrome in
the cell font too. Unset, the native (Vulkan) window takes the desktop's
interface font (GNOME's `org.gnome.desktop.interface font-name`, through the
settings portal) and follows it when the desktop changes it; where the desktop
names none, and in the raylib window, which reads no desktop settings, it is
the first installed of Inter, Adwaita Sans, Cantarell, Noto Sans, Roboto,
DejaVu Sans and the like. Chrome
text follows the terminal's font size, its x-height matched to the cell font's.
The option is shared with every `sparkles:ui-app` application; it is a flag
only, not a configuration key.

```sh
terminal --ui-font "Inter"
```

## `--font-codepoint-map` {#font-codepoint-map}

Routes specific codepoints to a dedicated font, overriding the primary and
styled faces (mirrors Ghostty's `font-codepoint-map`). Each entry is
`<ranges>=<family>`, where ranges is a comma-separated list of `U+XXXX`
codepoints or `U+XXXX-U+YYYY` ranges:

```bash
terminal --font-codepoint-map 'U+2295,U+2300-U+237F=Uiua386'
```

The option is repeatable (up to 8 entries); the first entry claiming a
codepoint wins. The family is resolved with `fc-match` and the entry is
dropped — falling back to the normal font chain — if fontconfig doesn't
actually have that family installed, rather than silently substituting a
different font.

## Environment

| Variable                      | Effect                                                                                      |
| ----------------------------- | ------------------------------------------------------------------------------------------- |
| `SHELL`                       | The shell to spawn (falls back to the passwd entry, then `/bin/sh`)                         |
| `TERM`                        | Set to `xterm-256color` for the child                                                       |
| `SPARKLES_BENCH_FORCE_REDRAW` | When set, redraws every frame (disables dirty-frame skipping); used by `terminal-benchmark` |
