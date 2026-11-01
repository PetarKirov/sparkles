### expected

| Field          | Value                                  |
| -------------- | -------------------------------------- |
| Version source | flake input `expected-src`             |
| Licence        | `BSL-1.0`                              |
| Home           | https://github.com/tchaloupka/expected |
| Ships as       | `sparkles:base`                        |

The `Expected` result type: how `@nogc nothrow` code across the sparkles
libraries reports an error without throwing — parsers, the event loop, the
configuration readers, the text writers. Nearly every library depends on it.
Vendored into `sparkles:base` as `sparkles.base.expected`; its header names the
upstream revision.

::: details Licence text

```text
<!-- @include: ../licenses/expected/LICENSE -->
```

:::
