# Grounding ledger — Literals, strings & data embedding

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

| #   | Claim (short)                                           | Type    | Versions claimed | Source                                                           | Status |
| --- | ------------------------------------------------------- | ------- | ---------------- | ---------------------------------------------------------------- | ------ |
| 1   | Interpolated Expression Sequences                       | fact    | [2.108]          | `2.108.0.dd` § `dmd.ies`                                         | ✓      |
| 2   | IES guide cross-link                                    | opinion | —                | navigation                                                       | ◯      |
| 3   | Hex strings deprecated as string                        | fact    | [2.079]          | `2.079.0.dd` (hex string deprecation path)                       | ≈      |
| 4   | Hex strings error as string                             | fact    | [2.086]          | `2.086.0.dd` (hex string error)                                  | ✓      |
| 5   | Hex strings convert to integer arrays                   | fact    | [2.108]          | `2.108.0.dd` § `dmd.hexstring-cast`                              | ✓      |
| 6   | `import()` treated as hex strings                       | fact    | [2.110]          | `2.110.0.dd` § `dmd.import-exp-hexstring`                        | ✓      |
| 7   | `__FUNCTION__` / `__PRETTY_FUNCTION__` / `__MODULE__`   | fact    | [2.063]          | `2.063.dd` § `prettyfunc`                                        | ✓      |
| 8   | `__FILE_FULL_PATH__`                                    | fact    | [2.072]          | `2.072.0.dd` § `__FILE_FULL_PATH__`                              | ✓      |
| 9   | Source-location defaults at call site robustly          | fact    | [2.108]          | `2.108.0.dd` § `dmd.default-init`                                | ✓      |
| 10  | Unicode directionality overrides banned (Trojan Source) | fact    | [2.101]          | `2.101.0.dd` § `dmd.unicode-directionality`                      | ✓      |
| 11  | `#ident` inside `q{…}` deprecated                       | fact    | [2.103]          | `2.103.0.dd` BUGZILLA 23792 / token-string preprocessor warnings | ≈      |
| 12  | `0b`/`0x` without digits error                          | fact    | [2.087]          | `2.087.0.dd` invalid integer literal examples                    | ✓      |
