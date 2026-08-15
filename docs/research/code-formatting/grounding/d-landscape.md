# Grounding ledger — d-landscape.md

## Verified verbatim (✓)

| Claim                                                                                                                              | Source                                                                                                              |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| All dfmt claims                                                                                                                    | [`dfmt` ledger](./dfmt.md)                                                                                          |
| sdfmt's `Chunk` bitfield, field-by-field, incl. `_startsUnwrappedLine`'s doc comment and "The length of the line in **graphemes**" | `$REPOS/dlang/sdc` @ `611d70ad`, `src/format/chunk.d:1-48`                                                          |
| "This algorithm is exponential in nature, so make sure to stop after some time, even if we haven't found an optimal solution."     | `src/format/writer.d:284-286`                                                                                       |
| `max_attempts`, `isDeadSubTree`, `checkpoints.isRedundant`, `Continuation[RuleValues] pausedExpansions`                            | `writer.d:245-295`                                                                                                  |
| `RuleValues` is a hand-rolled small-size-optimized bitset                                                                          | `src/format/rulevalues.d:1-30`                                                                                      |
| sdfmt file sizes (`parser.d` 3,201; `writer.d` 865; `chunk.d` 600; `span.d` 586; `rulevalues.d` 254; `config.d` 28; total 5,534)   | `wc -l`                                                                                                             |
| `// sdfmt off` is recognized in the parser                                                                                         | `src/format/parser.d:407`                                                                                           |
| `signature_layout.d`'s `SigStage` enum, "try it flat…", injected width measurer, byte-range output                                 | in-repo, quoted in the [D landscape](../d-landscape.md); same source as [SIG1–SIG6](../../../specs/hue/twoslash.md) |
| `prettyprint.d`'s `softMaxWidth = 80` render-then-measure approach                                                                 | in-repo `libs/base/src/sparkles/base/prettyprint.d`                                                                 |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                                        | Status | Note                                                                                                                                             |
| --- | ------------------------------------------------------------------------------------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | "**it has its own 3,201-line parser** written for formatting, so it does not share SDC's compiler front end" | ⚠      | `src/format/parser.d` exists at that size; that SDC's _compiler_ uses a different parser is **inferred from the directory layout**, not verified |
| 2   | "`pausedExpansions` … is dart_style's `SolutionCache` idea, arrived at independently"                        | ◯      | The identification is the survey's; both mechanisms are verified separately                                                                      |
| 3   | "sdfmt … has essentially no adoption outside its own repository"                                             | 🌐     | Unsourced                                                                                                                                        |
| 4   | "hdrgen … prints declarations, not bodies"                                                                   | ⚠      | True of `-H`'s purpose; not verified against `hdrgen.d`                                                                                          |
| 5   | "dfmt counts bytes; sdfmt is the only D tool with a correct width model"                                     | ✓◯     | Both halves verified (dfmt's `tokenLength`, sdfmt's `_length` "in graphemes"); "only" is over the three D tools here                             |
| 6   | The "What a D successor inherits" table                                                                      | ◯      | Editorial                                                                                                                                        |

## Not verified here

- sdfmt's `span.d`, `parser.d`, and the bulk of `writer.d`; how chunks are produced.
- `dmd.hdrgen` itself.
