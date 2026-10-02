### Noto Sans

| Field          | Value                                               |
| -------------- | --------------------------------------------------- |
| Version source | nixpkgs `noto-fonts`                                |
| Licence        | `OFL-1.1`                                           |
| Home           | https://notofonts.github.io                         |
| Ships as       | `NotoSans*.ttf`; `NotoSans*.otf`; `pkgs.noto-fonts` |

One regular face per script, so text in a writing system the monospace faces
do not cover — Arabic, Devanagari, Thai, Georgian and the rest — renders
instead of falling to boxes. `sparkles:raylib-text` picks the face per cluster
from the coverage sidecars the build writes beside each font.

::: details Licence text

```text
<!-- @include: ../licenses/noto-sans/fonts/LICENSE -->
```

:::
