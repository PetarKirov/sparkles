### HarfBuzz

| Field          | Value                                                     |
| -------------- | --------------------------------------------------------- |
| Version source | flake input `harfbuzz-src` (14.6.0, with one patch)       |
| Licence        | `MIT-Modern-Variant`                                      |
| Home           | https://harfbuzz.github.io                                |
| Ships as       | `libharfbuzz.a` in the APKs; `-lharfbuzz` on the desktops |

Shapes text into glyphs for `sparkles:raylib-text`: ligatures in the coding
fonts, combining marks, and the scripts whose letters change shape with their
neighbours. Without it a cluster would be drawn one code point at a time.

The release is pinned for `sparkles:font`, whose Unicode tables must match
it, and carries one patch: a run that spends HarfBuzz's operation budget is
reported as unfinished rather than returned as shaped.

::: details Licence text

```text
<!-- @include: ../licenses/harfbuzz/COPYING -->
```

:::
