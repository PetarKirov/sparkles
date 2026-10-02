### FreeType

| Field          | Value                                                                   |
| -------------- | ----------------------------------------------------------------------- |
| Version source | nixpkgs `freetype`                                                      |
| Licence        | `FTL OR GPL-2.0-or-later` (used under `FTL`)                            |
| Home           | https://freetype.org                                                    |
| Ships as       | `libfreetype.a` in the APKs; `-lfreetype2` (pkg-config) on the desktops |
| Notice         | This software is based in part on the work of the FreeType Team.        |

Rasterizes every glyph `sparkles:raylib-text` puts in its atlases: the
terminal's monospace text, hue's code and prose, and the colour emoji
strikes. It opens the bundled fonts on Android, where there is no fontconfig,
and the system's on the desktop.

::: details Licence text (FreeType Project License)

```text
<!-- @include: ../licenses/freetype/docs/FTL.TXT -->
```

:::

::: details Licence overview (`LICENSE.TXT`)

```text
<!-- @include: ../licenses/freetype/LICENSE.TXT -->
```

:::
