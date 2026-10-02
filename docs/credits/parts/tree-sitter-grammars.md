### tree-sitter grammars

| Field          | Value                                                   |
| -------------- | ------------------------------------------------------- |
| Version source | grammar bundle `ts-grammars`                            |
| Licence        | per grammar, listed with each text below (mostly `MIT`) |
| Home           | https://tree-sitter.github.io/tree-sitter/#parsers      |
| Ships as       | `ts-grammars`                                           |

The language grammars hue highlights with — one parser per language, listed
in `nix/packages/ts-grammar-languages.nix`, with the highlight queries that
come with them. Most are the nixpkgs builds; a few are pinned upstream
checkouts, and the D and SDLang grammars are maintained alongside this
project. Some languages take their queries from nvim-treesitter. hue loads
them as shared libraries on Android and from the bundle on the desktop;
`sparkles:terminal`'s document viewer uses the same bundle on the desktop and
a common subset of it in its APK (markdown, D, C, Bash, Nix, JSON, YAML, TOML
and Python).

::: details Licence texts, one per grammar

```text
<!-- @include: ../licenses/tree-sitter-grammars/LICENSES.txt -->
```

:::
