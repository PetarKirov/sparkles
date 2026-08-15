# Grounding ledger — prettier.md

Verification against `$REPOS/typescript/prettier` @ `414e453ae9034866d93eea456b430aa52140371b`.

## Verified verbatim (✓)

| Claim                                                                                                                                                                                  | Source                                    |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------- |
| "The first requirement of Prettier is to output valid code that has the exact same behavior as before formatting."                                                                     | `docs/rationale.md`                       |
| The recast-fork / Wadler lineage, and the "measure the IR" paragraph                                                                                                                   | `docs/technical-details.md:6,8`           |
| `MODE_BREAK` / `MODE_FLAT` symbols                                                                                                                                                     | `src/document/printer/printer.js:38,40`   |
| `fits(next, restCommands, remainingWidth, hasLineSuffix, groupModeMap, mustBeFlat)`                                                                                                    | `printer.js:53-60`                        |
| `fill` definition ("not going to break all the separators, just the ones that are at the end of lines")                                                                                | `commands.md:68-80`                       |
| `conditionalGroup` "should be used as **last resort** as it triggers an exponential complexity when nested"                                                                            | `commands.md:51-62`                       |
| `propagateBreaks` marks groups containing `DOC_TYPE_BREAK_PARENT`                                                                                                                      | `src/document/utilities/index.js:145-170` |
| "empty lines are very hard to automatically generate … preserve empty lines the way they were"                                                                                         | `docs/rationale.md`                       |
| `// prettier-ignore` "will exclude the next node in the abstract syntax tree from formatting"                                                                                          | `docs/ignore.md:52`                       |
| The 15 builder filenames                                                                                                                                                               | `ls src/document/builders/`               |
| Line counts: `printer.js` 578, `attach.js` 393, `handle-comments.js` 1,255, `range.js` 269, `indent.js` 184, `src/document/` 2,418, `src/main/` 2,131, `src/language-js/print/` 10,820 | `wc -l`                                   |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                              | Status | Note                                                                                                                                                                                                      |
| --- | ---------------------------------------------------------------------------------- | ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "What it _implements_ … is [Lindig 2000]"                                          | ◯      | The survey's identification. Strongly supported (mode tag, worklist `fits`) but prettier's docs credit Wadler, not Lindig                                                                                 |
| 2   | "**In a reprinting formatter, comments cost two to four times what layout costs**" | ◯      | Arithmetic over verified line counts (578 vs 393+1,255). The _generalization_ to "a reprinting formatter" is the survey's                                                                                 |
| 3   | The `objectWrap` heuristic description                                             | ⚠      | `docs/rationale.md` was read at the `objectWrap` reference; the quoted phrasing about "a newline between the `{` and the first key" comes from the same document but was **not re-verified line-by-line** |
| 4   | "`--debug-check` reparses the output and compares ASTs"                            | ⚠      | The flag exists; its implementation was **not read**                                                                                                                                                      |
| 5   | "`getStringWidth` … accounts for wide characters — a genuine grapheme/width model" | ⚠      | The call site is verified in `fits`; the implementation was not read                                                                                                                                      |
| 6   | "Cursor preservation — a `cursor` builder and `cursorOffset` option exist"         | ⚠      | `builders/cursor.js` exists; the end-to-end behaviour was not verified                                                                                                                                    |
| 7   | "`shouldRemeasure` … because candidate lists break the two-way invariant"          | ◯      | The flag is verified at `printer.js:191,248,256`; the causal attribution is the survey's — same flag as [`theory-combinators`](./theory-combinators.md) row 32                                            |
| 8   | "the most widely deployed formatter in existence"                                  | ◯      | Uncontroversial but unsourced                                                                                                                                                                             |
| 9   | The "What a D formatter should take" section                                       | ◯      | Editorial                                                                                                                                                                                                 |

## Not verified here

- `src/language-js/print/*` (10,820 lines) — none of the per-construct rules were read; the doc
  makes no claims about them beyond size.
- `main/core.js`, `ast-to-doc.js`, `multiparser.js` beyond their existence and line counts.
- The CSS/HTML/Markdown/YAML plugins.
