### HarfBuzz

| Field          | Value                                                     |
| -------------- | --------------------------------------------------------- |
| Version source | nixpkgs `harfbuzz`                                        |
| Licence        | `MIT-Modern-Variant`                                      |
| Home           | https://harfbuzz.github.io                                |
| Ships as       | `libharfbuzz.a` in the APKs; `-lharfbuzz` on the desktops |

Shapes text into glyphs for `sparkles:raylib-text`: ligatures in the coding
fonts, combining marks, and the scripts whose letters change shape with their
neighbours. Without it a cluster would be drawn one code point at a time.

::: details Licence text

```text
<!-- @include: ../licenses/harfbuzz/COPYING -->
```

:::
