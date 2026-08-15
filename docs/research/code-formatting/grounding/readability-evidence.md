# Grounding ledger — readability-evidence.md

## Verified verbatim (✓)

| Claim                                                                                                                                                                                                           | Source                                            |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| "comments, in of themselves, are less important than simple blank lines to local judgments of readability"                                                                                                      | `buse-weimer-2010-…tse.pdf` Abstract (txt L15-16) |
| "80% effective, and better than a human on average"; the three quality correlations; "over 2.2 million lines of code"                                                                                           | Abstract (txt L10-14)                             |
| "the importance of character count per line suggests that languages should favor the use of constructs … that encourage short lines"                                                                            | §6 (txt L713-718)                                 |
| "the length of identifier names constitutes almost no influence on readability (0% relative predictive power)"                                                                                                  | §6 (txt L726-730)                                 |
| **The descriptive-not-prescriptive caveat**, quoted in full incl. the five-blank-lines example                                                                                                                  | §6 (txt L731-742)                                 |
| "we caution that this data may only be truly relevant to our annotators"                                                                                                                                        | §6 (txt L714-718)                                 |
| The feature list includes line length, identifier length, indentation, `# blank lines`                                                                                                                          | §-table (txt L345-362)                            |
| Posnett's "simple, intuitive theory of readability, based on size and code entropy … much sparser, yet statistically significant"                                                                               | `posnett-2011-…msr.pdf` Abstract                  |
| Scalabrino's "take into account only structural aspects and visual nuances of source code, such as line length and alignment of characters"; "600 code snippets … 5K+ people"; "20 software systems … 3M lines" | `scalabrino-2018-…jsep.pdf` Summary               |

## Originating here — synthesis

| #   | Claim                                                                                                               | Status | Note                                                                                                                                            |
| --- | ------------------------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | "**each successive paper moves further away from layout**"                                                          | ◯      | The survey's reading of the four-paper trajectory. Well supported by rows above but asserted by no author                                       |
| 2   | The scope-warning box (snippet counts, "not one of them is an experiment in which formatting was varied")           | ◯⚠     | The counts are verified. The **negative claim** ("not one … varied formatting") is over four papers, two of which (Mi ×2) **were not obtained** |
| 3   | "**Blank lines beat comments** … is the single most formatter-relevant empirical result in the survey"              | ◯      | The quote is verbatim; the superlative is editorial                                                                                             |
| 4   | "That chain … is two correlations deep, over observational data, with no intervention at either step"               | ◯      | Methodological reading; correct as far as the abstracts go, but the papers' methods sections were **not read**                                  |
| 5   | The "what the evidence supports / does not support" lists                                                           | ◯      | The page's purpose, and entirely editorial                                                                                                      |
| 6   | "a formatter's justification is _consistency and the elimination of style debate_ … not measured readability gains" | ◯      | The survey's conclusion                                                                                                                         |
| 7   | Buse & Weimer's per-feature predictive powers beyond the two quoted                                                 | 🌐     | The feature table was located but **not transcribed**; only the two §6 discussion results are used                                              |

## Not verified here

- Posnett's and Scalabrino's methods, models and results beyond their abstracts.
- **Both Mi papers** — paywalled; see [`_sources.md`](./_sources.md).
- Whether Buse & Weimer's annotator pool (students) generalizes. Named as a caveat by the authors,
  not analysed here.
