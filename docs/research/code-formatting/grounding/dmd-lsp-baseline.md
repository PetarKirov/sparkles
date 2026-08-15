# Grounding ledger — dmd-lsp-baseline.md

The tree's most consequential page: it reports a substrate finding that **reverses** the
assumption the survey began with. This ledger is correspondingly strict.

Artifacts: `dmd:frontend` @ `ea88375142644d2dc7755089357acdfdd69c6620`, read at
`~/.dub/packages/dmd/ea883751…/dmd/compiler/src/dmd/`; this repo @ `557ccfc1`.

## Verified verbatim (✓)

| #   | Claim                                                                                                                                                                                  | Source                                                                    |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| 1   | `bool commentToken;  // comments are TOK.comment's`                                                                                                                                    | `lexer.d:105`                                                             |
| 2   | `bool whitespaceToken;  // tokenize whitespaces (only for DMDLIB)`                                                                                                                     | `lexer.d:108`                                                             |
| 3   | The DMDLIB constructor with `whitespaceToken`, incl. its `/*** Alternative entry point for DMDLIB, adds whitespaceToken */` comment                                                    | `lexer.d:201-211`                                                         |
| 4   | `whitespaceToken` is actually consulted, emitting `t.value = TOK.whitespace`                                                                                                           | `lexer.d:361-374`                                                         |
| 5   | `TOK.comment` and `TOK.whitespace` are real enum members                                                                                                                               | `tokens.d:60, 253`                                                        |
| 6   | The `Token` struct: `next`, `loc`, `ptr` ("pointer to first character of this token within buffer"), `value`, `blockComment` ("doc comment string prior to this token"), `lineComment` | `tokens.d:643-650`                                                        |
| 7   | `Loc.fileOffset()` exists                                                                                                                                                              | `location.d:136`                                                          |
| 8   | `SourceLoc { filename; line; column; fileOffset; fileContent }`                                                                                                                        | `location.d:246-255`                                                      |
| 9   | `Loc` is internally `private uint index` into a global table (not a `(file,line,col)` triple)                                                                                          | `location.d:34-36`                                                        |
| 10  | `dmd.tokens` is already imported in-repo                                                                                                                                               | `libs/dmd-lsp/src/sparkles/dmd_lsp/visitor.d:96`                          |
| 11  | `dmd:lexer` is already in the link closure                                                                                                                                             | `libs/dmd-lsp/dub.sdl:20-22` (the `Edition` `lflags` workaround names it) |
| 12  | The fork pin and its provenance                                                                                                                                                        | `libs/dmd-lsp/dub.sdl`                                                    |

**Rows 1–11 are the page's headline and every one is a direct quote from a file read this
session.** This is the best-grounded page in the tree.

## Not verbatim — inference or unchecked

| #   | Claim                                                                                               | Status | Note                                                                                                                                                    |
| --- | --------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 13  | "**A full-fidelity D token stream requires no new dependency, no tree-sitter, and no fork change**" | ◯⚠     | Follows from rows 1–11. **Not demonstrated** — no code was written or run. This is precisely what M0's spike must prove                                 |
| 14  | "`whitespaceToken` … (only for DMDLIB)" implies it is _available_ to `dmd-lsp`                      | ⚠      | The comment says DMDLIB; whether the pinned build enables that path was **not checked**. The proposal's "what would make this wrong" section names this |
| 15  | "the next token's `ptr` gives this one's end"                                                       | ◯      | True given a contiguous token stream incl. whitespace tokens; not verified                                                                              |
| 16  | "Q-b … Still open" — node end positions                                                             | ⚠      | **Not inventoried.** The page says so                                                                                                                   |
| 17  | The Q-c comparison table (attachment cost, broken input, literals, verification, D precedent)       | ◯      | Each cell cites a verified deep-dive; the table is the survey's synthesis                                                                               |
| 18  | "**Recommendation: format the token stream**"                                                       | ◯      | The survey's conclusion                                                                                                                                 |
| 19  | The Q-e hard list                                                                                   | ◯      | D language knowledge; **not derived from any artifact**, and not checked against DMD's grammar                                                          |
| 20  | "formatting needs only the lexer for the common path"                                               | ◯      | Inference; contradicted in part by the AST-oracle design, which the same page recommends                                                                |
| 21  | "DMD's AST discards comments … and normalizes literals"                                             | ⚠      | Established in earlier exploration of `libs/dmd-lsp`; **not re-verified against `dmd.frontend` in this pass**                                           |
| 22  | "no `.editorconfig` reader"; "no `TextEdit` machinery"; "no width model"                            | ⚠      | Negative claims about the repo, from the earlier exploration                                                                                            |

## Discrepancies

- **D-BL1 (row 14) — the one thing that could invalidate the headline.** `whitespaceToken` is
  documented "only for DMDLIB". If the pinned fork's build does not compile that path, the
  whitespace half of the finding fails (comments would still work, since `commentToken` is not
  DMDLIB-gated). The doc and [the proposal](../dmd-fmt-proposal.md) both name this; it is M0's
  first task.
- **D-BL2 — this page supersedes earlier framing elsewhere.** [`concepts.md`](./concepts.md) §3
  was revised after this page was written (see that ledger's D-C1). Any _future_ page repeating
  "DMD has no offsets" is wrong and should cite row 7 instead.

## Not verified here

- Anything by execution. **No spike was run.** Every claim is from reading source.
- `libs/dmd-lsp`'s own modules in this pass (rows 21–22 rely on earlier session exploration).
