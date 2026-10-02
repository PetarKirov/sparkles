### DMD frontend

| Field          | Value                        |
| -------------- | ---------------------------- |
| Version source | dub package `dmd`            |
| Licence        | `BSL-1.0`                    |
| Home           | https://github.com/dlang/dmd |

The reference D compiler's lexer and parser, from a fork pinned in
`nix/dub-lock.json`. `sparkles:dmd-fmt` formats D with it, which is how hue's
format preview reflows a D file as you drag the ruler; the type overlays
(`sparkles:twoslash-d`) use the same frontend in a separate process.

::: details Licence text

```text
<!-- @include: ../licenses/dmd/LICENSE.txt -->
```

:::
