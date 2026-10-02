### libpng

| Field          | Value                    |
| -------------- | ------------------------ |
| Version source | nixpkgs `libpng`         |
| Licence        | `libpng-2.0`             |
| Home           | https://www.libpng.org   |
| Ships as       | `libpng16.a` in the APKs |

Linked into the Android builds of FreeType, which needs it to decode the PNG
bitmaps Noto Color Emoji stores its glyphs as. On the desktop FreeType links
the system's copy.

::: details Licence text

```text
<!-- @include: ../licenses/libpng/LICENSE -->
```

:::
