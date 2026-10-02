### tree-sitter

| Field          | Value                                                           |
| -------------- | --------------------------------------------------------------- |
| Version source | nixpkgs `tree-sitter`                                           |
| Licence        | `MIT`                                                           |
| Home           | https://tree-sitter.github.io                                   |
| Ships as       | `libtree-sitter.a` in the APKs; `-ltree-sitter` on the desktops |

The incremental parser behind hue's syntax highlighting. `sparkles:tree-sitter`
binds its runtime; `sparkles:syntax` runs the grammars below and their
highlight queries over every file hue opens, and the markdown model reads its
structure from the markdown grammars.

::: details Licence text

```text
<!-- @include: ../licenses/tree-sitter/LICENSE -->
```

:::
