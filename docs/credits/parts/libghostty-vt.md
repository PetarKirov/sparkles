### libghostty-vt

| Field          | Value                                                         |
| -------------- | ------------------------------------------------------------- |
| Version source | flake input `ghostty`                                         |
| Licence        | `MIT`                                                         |
| Home           | https://ghostty.org                                           |
| Ships as       | `libghostty-vt.a` in the APKs; `-lghostty-vt` on the desktops |

Ghostty's terminal core, built as a library. In `sparkles:terminal` it parses
every byte a program writes to the terminal and holds the screen — the grid,
the scrollback, the modes and the cursor that `sparkles:terminal-view` draws.
hue runs a second, off-screen instance to decode the escape sequences in
`ansi` code blocks, so a coloured example renders as it would in a terminal.
Both reach it through `sparkles:ghostty`.

::: details Licence text

```text
<!-- @include: ../licenses/libghostty-vt/LICENSE -->
```

:::
