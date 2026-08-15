# Grounding ledger — dmd-fmt-proposal.md

A **proposal**, not a survey page: it is editorial by construction. This ledger records which of
its premises are verified and which are judgement, so a reader can tell them apart.

## Verified premises

| Premise                                                                                          | Where verified                                                                      |
| ------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------- |
| DMD's lexer emits comments and whitespace as tokens, with buffer pointers and `Loc.fileOffset()` | [`dmd-lsp-baseline`](./dmd-lsp-baseline.md) rows 1–11                               |
| A token spine removes the comment-attachment problem                                             | [`dfmt`](./dfmt.md), [`clang-format`](./clang-format.md), [`topiary`](./topiary.md) |
| Reprinting formatters spend 2–4× on comments what they spend on layout                           | [`prettier`](./prettier.md) (578 vs 1,648), [`rustfmt`](./rustfmt.md) (2,149)       |
| Token-stream formatters format unparseable input                                                 | [`dfmt`](./dfmt.md) (`format()`'s doc comment), [`clang-format`](./clang-format.md) |
| Every search formatter caps itself silently                                                      | [`theory-cost-and-search`](./theory-cost-and-search.md) — six instances             |
| Edits-not-documents is what enables range/on-type/cursor                                         | [`clang-format`](./clang-format.md), [`roslyn`](./roslyn.md)                        |
| Wadler's lazy form is exponential in a strict language                                           | [`theory-combinators`](./theory-combinators.md) row 21                              |
| ruff's similarity-index methodology, verbatim                                                    | [`rust-reimplementations`](./rust-reimplementations.md)                             |
| ocamlformat's verification loop, verbatim                                                        | [`ocamlformat`](./ocamlformat.md)                                                   |
| Blank lines have empirical support; most style options do not                                    | [`readability-evidence`](./readability-evidence.md)                                 |
| dart_style's memoized hoisting and pinning                                                       | [`dart-style`](./dart-style.md)                                                     |
| dfmt's `.editorconfig` surface is the migration constraint                                       | [`dfmt`](./dfmt.md)                                                                 |

## Judgement, not evidence

| #   | Claim                                      | Note                                                                                                                                                   |
| --- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | The **milestone ordering** M0–M9           | Entirely the survey's. The one ordering claim with an argument behind it is M1-before-M2 (verifier before printer), borrowed from ocamlformat's design |
| 2   | "p95 < 30 ms for 2 kLOC"                   | **A proposed number with no measurement behind it.** Stated as a proposal, to be set in M0                                                             |
| 3   | Q-e's hard list                            | D language knowledge; not derived from a grammar or a corpus                                                                                           |
| 4   | "greedy first, search behind a flag at M9" | Follows from the incompleteness-budget evidence, but the _sequencing_ is a judgement                                                                   |
| 5   | The non-goals                              | Editorial                                                                                                                                              |
| 6   | "What would make this proposal wrong"      | The survey's own risk analysis; the first item (row D-BL1 in [the baseline ledger](./dmd-lsp-baseline.md)) is the real one                             |

## Not verified

- **Nothing in this document has been implemented or measured.** It is a research conclusion. The
  spec it feeds belongs in `docs/specs/dmd-fmt/` and should be written after M0.
