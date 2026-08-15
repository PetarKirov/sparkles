# Grounding ledger — gofmt.md

Verification against `$REPOS/go/go` @ `015343854b5d9e2829481df30dbcae2ca6682d25`.

## Verified verbatim (✓)

| Claim                                                                                                                                       | Source                          |
| ------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| The full `gofmt` flag list (`-l`, `-w`, `-r`, `-s`, `-d`, `-e`) — **no formatting options**                                                 | `src/cmd/gofmt/gofmt.go:35-40`  |
| `func (p *printer) linebreak(line, min int, ws whiteSpace, newSection bool)` and `n := max(nlimit(line-p.pos.Line), min)`                   | `src/go/printer/nodes.go:45-47` |
| The `whiteSpace` byte constants (`ignore`, `blank`, `vtab`, `newline`, `formfeed`, `indent`, `unindent`)                                    | `src/go/printer/printer.go`     |
| `maxNewlines = 2`, `infinity = 1 << 30`                                                                                                     | `printer.go`                    |
| The `linebreak`/comments `TODO(gri)` comment, quoted in full                                                                                | `nodes.go:35-44`                |
| `text/tabwriter` is imported by `printer.go`                                                                                                | `printer.go:17`                 |
| Line counts (`nodes.go` 2,016; `printer.go` 1,435; `comment.go` 155; `gobuild.go` 170; `gofmt.go` 577; `simplify.go` 169; `rewrite.go` 309) | `wc -l`                         |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                              | Status | Note                                                                                                                                                                   |
| --- | -------------------------------------------------------------------------------------------------- | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "**gofmt cannot make code fit**" / "no column limit anywhere in `go/printer`"                      | ⚠      | A **negative claim**. Supported by the absence of any width constant and by `linebreak`'s signature, but `nodes.go` (2,016 lines) was **read only around `linebreak`** |
| 2   | The elastic-tabstops description (sections, `formfeed` bounding them, widening to the widest cell) | ⚠      | `vtab`/`formfeed` are verified as constants; the _tabwriter semantics_ are general knowledge, not read from `text/tabwriter`                                           |
| 3   | "Nick Gravgaard's elastic tabstops" attribution                                                    | 🌐     | Not sourced from any local artifact                                                                                                                                    |
| 4   | "Comments are held in an `ast.CommentGroup` map and interspersed by position"                      | ⚠      | `setComment` is visible at `nodes.go:63-70`; the full mechanism was not read                                                                                           |
| 5   | "Behaviour on unparseable input: refuses. `go/parser` must succeed."                               | ⚠      | Inferred from the pipeline; `gofmt.go`'s error path not traced                                                                                                         |
| 6   | "Width is counted in **runes** by `tabwriter`"                                                     | 🌐     | Not verified against `text/tabwriter`                                                                                                                                  |
| 7   | "tested against a `testdata/*.golden` corpus"                                                      | ⚠      | Directory not inspected in this pass                                                                                                                                   |
| 8   | "`-r` and `-s` are _refactoring_ switches, off by default"                                         | ✓◯     | Defaults verified in the flag list; the framing as "job three" is the survey's                                                                                         |
| 9   | "the cultural origin of the zero-options formatter"                                                | ◯      | Editorial                                                                                                                                                              |
| 10  | The "Do not take" recommendation about D's grammar                                                 | ◯      | Editorial judgement                                                                                                                                                    |

## Not verified here

- `nodes.go` beyond `linebreak`/`setComment`; `comment.go`; `text/tabwriter` itself.
- Whether gofmt is idempotent (asserted nowhere in the doc, but implied by "tested").
