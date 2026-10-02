### raylib

| Field          | Value                                                 |
| -------------- | ----------------------------------------------------- |
| Version source | nixpkgs `raylib`                                      |
| Licence        | `Zlib`                                                |
| Home           | https://www.raylib.com                                |
| Ships as       | `libraylib.a` in the APKs; `-lraylib` on the desktops |

The window, the OpenGL context, input and the frame loop of every graphical
sparkles application. `sparkles:ui-raylib` draws the toolkit's frames with it,
`sparkles:raylib-text` uploads glyph atlases through it, and on Android its
native-activity platform layer is how `sparkles:terminal` and hue get a
surface and touch events at all. raylib carries small single-header libraries
of its own (stb, rlgl), covered by the same licence.

::: details Licence text

```text
<!-- @include: ../licenses/raylib/LICENSE -->
```

:::
