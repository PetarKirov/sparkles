# Grounding ledger — concepts.md

`concepts.md` is a **glossary**: most of its content is definitional, and its factual claims are
re-verified in the deep-dive that owns each concept. This ledger records the claims that
originate here, plus the one artifact that is genuinely new.

## Verified verbatim (✓)

| Claim                                                                                        | Source                                                                                                      |
| -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| The Hughes / Yelland pretty-printing-vs-code-formatting distinction                          | [`theory-combinators`](./theory-combinators.md) row 6; [`theory-optimality`](./theory-optimality.md) row 29 |
| "documentary structure" / "linguistic structure" / orthogonality                             | [`theory-layout-preserving`](./theory-layout-preserving.md) rows 1–2                                        |
| The `while x >= 0` comment-attachment example                                                | [`theory-layout-preserving`](./theory-layout-preserving.md) row 4                                           |
| The **elastic trivia** definition                                                            | `$REPOS/dotnet/roslyn` `docs/wiki/FAQ.md:308-309`                                                           |
| rust-analyzer's "full-fidelity representation"                                               | `crates/syntax/src/lib.rs:6-7`                                                                              |
| prettier's `fill` definition and the `conditionalGroup` exponential warning                  | `prettier` `commands.md:51-80`                                                                              |
| "The first requirement of Prettier is to output valid code that has the exact same behavior" | `prettier` `docs/rationale.md`                                                                              |
| black's magic-trailing-comma passage                                                         | `black` `docs/the_black_code_style/current_style.md:440-462`                                                |
| ocamlformat's `Unstable`, `max-iters`, and both failure strings                              | `ocamlformat` `lib/Translation_unit.ml` — see [its ledger](./ocamlformat.md)                                |
| The escape-hatch directives table (clang-format, dfmt, sdfmt, black, prettier, rustfmt)      | each verified in the corresponding ledger; `sdfmt` at `$REPOS/dlang/sdc/src/format/parser.d:407`            |
| dart_style's language-version gating                                                         | `dart_style` `CHANGELOG.md:644-648`                                                                         |
| dfmt's `editorconfig.d` + `globmatch_editorconfig.d` = 458 lines                             | measured                                                                                                    |
| clang-format's seven non-whitespace fixers, named                                            | `ls clang/lib/Format/`                                                                                      |

## Originating here — synthesis

| #   | Claim                                                                                | Status | Note                                                                                                                                                                                                                                                                                                                          |
| --- | ------------------------------------------------------------------------------------ | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **The layout-IR cross-naming table** (5 systems × 12 concepts)                       | ◯      | The tree's most-linked artifact. Each _cell_ traces to a verified fact, but the **mapping across columns is entirely the survey's**. The Roslyn and clang-format columns are the weakest — several cells read "(emerges from the search)" / "(emerges from the rule chain)", which is an interpretation, not a correspondence |
| 2   | "The consistent/inconsistent flag was invented three times" (four with swift-format) | ◯      | Each definition verified; the identification is the survey's — flagged consistently in every ledger                                                                                                                                                                                                                           |
| 3   | "Alignment is the primitive everyone had to add"                                     | ◯      | Supported by gofmt/clang-format/prettier evidence; a generalization                                                                                                                                                                                                                                                           |
| 4   | The three answers to attachment (own / attach / never)                               | ◯      | The survey's taxonomy                                                                                                                                                                                                                                                                                                         |
| 5   | The width-model table (bytes / code points / graphemes / display columns)            | ◯      | Standard, but not sourced to any paper here                                                                                                                                                                                                                                                                                   |
| 6   | "Why DMD's AST is the hard case"                                                     | ⚠      | Partly **superseded** by [`dmd-lsp-baseline`](./dmd-lsp-baseline.md): the AST claim stands, but the page should not leave the impression that the _substrate_ lacks a token stream. See D-C1 below                                                                                                                            |
| 7   | The three approximations of semantic preservation                                    | ◯      | The survey's ladder; developed in [`verification`](./verification.md)                                                                                                                                                                                                                                                         |
| 8   | **The landscape-at-a-glance table** (13 systems × 5 axes)                            | ◯⚠     | Cells are filled from the deep-dives; the doc carries a `<sub>` note saying provisional cells are flagged here. Rows for pages with thin ledgers (Roslyn, topiary, swift-format) inherit those ledgers' uncertainty                                                                                                           |

## Discrepancies

- **D-C1 (row 6) — a stale framing.** §3 says "DMD gives a formatter an AST, not a CST, and without
  end positions it cannot even slice the original text for a subtree." The first half is right; the
  second is **contradicted by [`dmd-lsp-baseline`](./dmd-lsp-baseline.md)**, which establishes that
  `Loc.fileOffset()` exists and `Token.ptr` gives exact spans. The sentence should be revised to
  scope the limitation to the AST rather than the substrate.

## Not verified here

- Every concept's implementation — this page defines, the deep-dives verify.
- The `@`-capture semantics in the IR table's topiary-adjacent claims — see
  [`topiary`](./topiary.md) rows 1–3.
