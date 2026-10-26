### libxcb

| Field          | Value                                                                                           |
| -------------- | ----------------------------------------------------------------------------------------------- |
| Version source | nixpkgs `libxcb`                                                                                |
| Licence        | `X11`                                                                                           |
| Home           | https://xcb.freedesktop.org                                                                     |
| Ships as       | `-lxcb`, `-lxcb-xkb`, `-lxcb-xtest`, `-lxcb-xinput`, `-lxcb-xfixes` on Linux, on the native arm |

The X protocol C binding. `sparkles:wsi` opens the terminal's window on an X
server with it, and uses its extensions for the keyboard (XKB), raw and
precise pointer input (XInput), the clipboard's selection ownership (XFixes)
and its own input tests (XTEST).

::: details Licence text

```text
<!-- @include: ../licenses/libxcb/COPYING -->
```

:::
