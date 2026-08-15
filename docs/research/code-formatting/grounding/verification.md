# Grounding ledger — verification.md

## Verified verbatim (✓)

| Claim                                                                                            | Source                                                                 |
| ------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------- |
| ocamlformat's five-step loop, `max-iters` default 10, `.unequal-ast` dumps, both failure strings | [`ocamlformat` ledger](./ocamlformat.md)                               |
| ruff's three stability checks and the similarity-index definition                                | [`rust-reimplementations` ledger](./rust-reimplementations.md)         |
| dfmt's "Make backups of your files or use source control"                                        | `dfmt` `README.md`                                                     |
| de Jonge & Visser's Correctness and Preservation equations and the lens laws                     | [`theory-layout-preserving`](./theory-layout-preserving.md) rows 17–19 |
| prettier's "exact same behavior" requirement                                                     | `prettier` `docs/rationale.md`                                         |
| black's comment-removal admission                                                                | `black` `docs/the_black_code_style/index.md`                           |
| rustfmt's `--error-on-unformatted` and `missed_spans.rs`                                         | [`rustfmt` ledger](./rustfmt.md) rows 1–2, 8 (both ⚠ there)            |

## Originating here — synthesis

| #   | Claim                                                                                        | Status | Note                                                                                                                                                                                                                                                                             |
| --- | -------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **The seven-tier ladder**                                                                    | ◯      | The survey's ranking. The tiers are a useful ordering, not a standard                                                                                                                                                                                                            |
| 2   | "**Nobody is above tier 7, and only one system is above tier 4**"                            | ◯⚠     | A **negative claim over 13 systems**, several of whose test infrastructure was not examined. It is the page's headline and it is the least verifiable thing on it                                                                                                                |
| 3   | The per-system verification table                                                            | ⚠      | Rows for dart_style ("format-twice test"), topiary ("idempotence in its own tests"), zig ("test suite"), gofmt ("golden corpus") are **🌐 in their own ledgers** — test suites were not inspected. The dfmt row (**none at all**) is a negative claim from reading all 9 modules |
| 4   | "Tier 3 is the sweet spot for D, and it is unusually cheap here"                             | ◯      | Rests on [`dmd-lsp-baseline`](./dmd-lsp-baseline.md)'s lexer finding, which is verified                                                                                                                                                                                          |
| 5   | The six-step recommended stack                                                               | ◯      | Editorial; each step cites a verified precedent                                                                                                                                                                                                                                  |
| 6   | "D has exactly OCaml's hazard"                                                               | ◯      | The ddoc half is verified in the baseline; the parallel is the survey's                                                                                                                                                                                                          |
| 7   | "Preservation … is exactly right, unweakened, for the regions a formatter declines to touch" | ◯      | The survey's specialization — same claim as [`theory-layout-preserving`](./theory-layout-preserving.md) D-LP3, and it is load-bearing in two places now                                                                                                                          |

## Not verified here

- Any project's test suite. Rows in the table marked from "tests" are documentation claims or
  inference, not inspection.
- Whether token-equality-modulo-whitespace actually catches what the page claims it catches for D.
  **Untested** — it is a recommendation, and M1's job is to test it.
