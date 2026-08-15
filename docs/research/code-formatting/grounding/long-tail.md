# Grounding ledger — long-tail.md

## Verified verbatim (✓)

| Claim                                                                                                                                                                                                      | Source                                                                                                   |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| The magic-trailing-comma passage in full                                                                                                                                                                   | `$REPOS/python/black` @ `74371e20`, `docs/the_black_code_style/current_style.md:440-462`                 |
| The calendar-year stability policy, the `--preview`/`--unstable` exemption, and the comment-removal admission                                                                                              | `docs/the_black_code_style/index.md:30-49`                                                               |
| `FMT_OFF = {"# fmt: off", "# fmt:off", "# yapf: disable"}`                                                                                                                                                 | `src/black/comments.py:27`                                                                               |
| The google-java-format pipeline comment ("`JavaInputAstVisitor` outputs a sequence of `Op`s using `OpsBuilder`. This linear sequence is then transformed by `DocBuilder` into a tree-structured `Doc`.")   | `$REPOS/java/google-java-format` @ `b291d957`, `core/src/main/java/com/google/googlejavaformat/Doc.java` |
| The gjf `core/` file list (`Doc.java`, `DocBuilder.java`, `OpsBuilder.java`, `Op.java`, `OpenOp.java`, `CloseOp.java`, `CommentsHelper.java`, `Indent.java`, `Newlines.java`, `Input.java`, `Output.java`) | `ls`                                                                                                     |
| gjf's README ("reformats Java source code to comply with Google Java Style")                                                                                                                               | `README.md`                                                                                              |
| All scalafmt quotes                                                                                                                                                                                        | `$PAPERS/geirsson-2016-…pdf` — see [`theory-cost-and-search`](./theory-cost-and-search.md)               |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                                                  | Status | Note                                                                                                                                                                                          |
| --- | ---------------------------------------------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "black … Layout: greedy, AST-based, combinator-adjacent"                                                               | 🌐     | **No black source was read** beyond `comments.py`'s `FMT_OFF` set                                                                                                                             |
| 2   | "Zero style options" for gjf                                                                                           | 🌐     | Not verified                                                                                                                                                                                  |
| 3   | "gjf … `CommentsHelper`, `Newlines`, `Indent`, and an `Input`/`Output` split that keeps the original text addressable" | ⚠      | File names verified; the `Input`/`Output` characterization is inferred                                                                                                                        |
| 4   | "**The whole astyle / uncrustify section**"                                                                            | 🌐     | **Neither tool is cloned.** Every claim — no parsing, option explosion, "several hundred options", no correctness argument — is general knowledge. The doc carries a `> [!WARNING]` saying so |
| 5   | "four independent arrivals" at the one-bit author signal                                                               | ◯      | The survey's count across zig/black/topiary/swift-format, each verified on its own page                                                                                                       |
| 6   | The "What a D formatter should take" table                                                                             | ◯      | Editorial                                                                                                                                                                                     |

## Discrepancies

- **D-LT1 (row 4).** The astyle/uncrustify section is the least-grounded prose in the published
  tree. It is flagged in-doc. **Either clone both and verify, or delete the section** — the survey
  loses little without it, since its content is a negative comparison.

## Not verified here

- black's formatter source; gjf's `Doc.java` beyond its header comment; scalafmt's current source
  (see [`theory-cost-and-search`](./theory-cost-and-search.md) D-CS1).
