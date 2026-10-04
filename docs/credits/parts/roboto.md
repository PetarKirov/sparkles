### Roboto

| Field          | Value                                           |
| -------------- | ----------------------------------------------- |
| Version source | flake input `roboto-src`                        |
| Licence        | `OFL-1.1`                                       |
| Home           | https://github.com/googlefonts/roboto-3-classic |
| Ships as       | `Roboto-*.ttf`; `pkgs.roboto`                   |

The interface face: the terminal's own chrome — page titles, rows, chips and
buttons — in its regular and bold weights, at the design system's type scale.
The terminal for Android bundles it, since the phone's own faces are variable
fonts its renderer cannot draw in bold; the desktop prefers the system's
interface font and falls back to it. The faces come from nixpkgs' `roboto`
release build; the licence comes from the same release's source.

::: details Licence text

```text
<!-- @include: ../licenses/roboto/OFL.txt -->
```

:::
