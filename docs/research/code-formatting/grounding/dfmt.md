# Grounding ledger — dfmt.md

Verification of `docs/research/code-formatting/dfmt.md` against
`$REPOS/dlang/dlang-community/dfmt` @ `c65d1c8a9cd2d784ded4cc7517c2cdd42c0c5c76`.

This page is unusually source-dense: the `format()` pipeline, the `ASTInformation` fields, the
cost constants and both caps are quoted verbatim from files read in full. Rows below record the
**exceptions** — anything not a direct quote — plus a summary of what was verified.

## Verified verbatim (✓)

| Claim                                                                                                                        | Source                                                                                         |
| ---------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| The `format()` pipeline excerpt (lex twice, parse, visit, format tokens)                                                     | `src/dfmt/formatter.d`, `format()`                                                             |
| "Returns: `true` if the formatting succeeded … **This function can return `true` if parsing failed.**"                       | `formatter.d`, `format()` doc comment                                                          |
| `stringBehavior = StringBehavior.source`, `whitespaceBehavior = WhitespaceBehavior.skip` (both lexer configs)                | `formatter.d`                                                                                  |
| The three quoted `ASTInformation` field doc comments; `cleanup()` "Sorts the arrays so that binary search will work on them" | `src/dfmt/ast_info.d:33-77`                                                                    |
| The ~24 array names listed                                                                                                   | `ast_info.d:41-67`                                                                             |
| `if (currentIs(tok!"comment")) formatComment();`; "The comment appears on its own line, keep it there."                      | `formatter.d:225-227, 608`                                                                     |
| `void formatComment() { if (commentText(index) == "dfmt off")`                                                               | `formatter.d:479-481`                                                                          |
| Cost constants, caps, `opEquals`/`toHash`                                                                                    | `src/dfmt/wrapping.d` — see [`theory-cost-and-search`](./theory-cost-and-search.md) rows 13–20 |
| README quotes ("beta quality…", "no way of knowing that 'getopt' is special", EditorConfig)                                  | `README.md:72-84` and the disable-formatting example                                           |
| Config option names and defaults (`dfmt_brace_style = allman`, `dfmt_soft_max_line_length = 80`, …)                          | `src/dfmt/config.d:34-93`                                                                      |
| Line counts (4,618 total; 2,402 / 503 / 375 / 333 / 243 / 239 / 219 / 182 / 122)                                             | `wc -l src/dfmt/*.d`                                                                           |
| `editorconfig.d` + `globmatch_editorconfig.d` = 458 lines ≈ 10%                                                              | measured                                                                                       |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                           | Status | Note                                                                                                                        |
| --- | ----------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------- |
| 1   | "the AST is consumed by a visitor … and then **discarded**"                                     | ◯      | True of the data flow in `format()`; the word "discarded" is the doc's                                                      |
| 2   | "**the hardest problem in the survey disappears if the formatter's input is a token stream**"   | ◯      | The survey's thesis. Supported by dfmt + [clang-format](./clang-format.md) + [topiary](./topiary.md); asserted by no source |
| 3   | "A D formatter on `sparkles:dmd-lsp` could populate exactly such a table"                       | ◯      | Forward-looking; see [`dmd-lsp-baseline`](./dmd-lsp-baseline.md)                                                            |
| 4   | "no equivalence checker, no idempotence harness, and no `--check` semantics beyond exit status" | ⚠      | A **negative claim** from reading the 9 modules and `main.d`. Not exhaustively verified against the test suite              |
| 5   | "`tokenLength` … in **bytes/characters**, with no grapheme or East-Asian width model"           | ⚠      | Read from `tokens.d`'s signature and use; the _absence_ of a width model is inferred, not quoted                            |
| 6   | "No range formatting. No `--lines`, no `--offset`/`--length`"                                   | ⚠      | From `main.d`'s option handling; negative claim                                                                             |
| 7   | "dfmt cannot exhibit the pathological pauses scalafmt documents"                                | ◯      | Follows from the unconditional caps; not measured                                                                           |
| 8   | "the smallest complete formatter in this survey" (metadata table)                               | ✓◯     | True across the 13 surveyed systems as measured; a comparative claim over this survey's scope only                          |
| 9   | The "What a D successor should take, and leave" section                                         | ◯      | Entirely editorial                                                                                                          |

## Not verified here

- `formatter.d`'s 2,402 lines were **read selectively** (the pipeline, comment handling, the
  `dfmt off` scan). The bulk of the token-by-token spacing state machine was not audited.
- `libdparse` itself (26,652 vendored lines).
- Whether dfmt's caps bite in practice on real D code. **No measurement was performed** — this is
  the same open question flagged in [`theory-cost-and-search`](./theory-cost-and-search.md).
