# Readability Evidence — What the Empirical Literature Does and Does Not Support

Four papers, fifteen years, and one uncomfortable conclusion for anyone hoping the science will
settle a formatting argument: **the code-readability literature is descriptive and correlational,
it is dominated by non-whitespace features, and its own authors explicitly disclaim the
prescriptive use a formatter designer would want to make of it.**

That is worth knowing precisely rather than vaguely, because "studies show" is a common move in
style debates and the studies mostly do not show it.

**Last reviewed:** August 15, 2026

> [!IMPORTANT]
> **Scope warning.** These are correlational models fit to human ratings of small snippets
> (Buse & Weimer: ~100 snippets, 120 annotators; Scalabrino: 600+ snippets, 5K+ raters). They
> predict _judgments_, not comprehension, defect rates, or productivity — except through further
> correlations. Not one of them is an experiment in which formatting was varied and an outcome
> measured. Nothing on this page can settle whether a D formatter should wrap at 80 or 100
> columns, and this page is here partly to say so.

---

## The lineage

| Paper                                                 | Contribution                                                                                                                       | Whitespace features?                                                       |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| **[Buse & Weimer 2010][buse]** (TSE 36(4))            | The founding model: ~25 local features → logistic regression on human ratings; "80% effective, and better than a human on average" | **Yes** — line length, indentation, blank lines are all in the feature set |
| **[Posnett, Hindle & Devanbu 2011][posnett]** (MSR)   | A _simpler_ model: size + Halstead + code entropy, "much sparser, yet statistically significant"                                   | **No** — the sparse model discards them                                    |
| **[Scalabrino et al. 2018][scalabrino]** (JSEP 30(6)) | Adds **textual** features (identifiers, comments as natural language); combined model beats all prior                              | **No** — argues prior models over-weight "visual nuances"                  |
| **Mi et al. 2018 / 2022**                             | Deep-learning classifiers over code images / visual+semantic+structural representations                                            | Indirectly (visual input)                                                  |

The trajectory is the finding: **each successive paper moves further away from layout.** Posnett
shows a model with no whitespace features at all does nearly as well; Scalabrino frames the prior
work's whitespace attention as a limitation:

> "the models proposed to estimate code readability take into account only structural aspects and
> visual nuances of source code, such as line length and alignment of characters. In this paper we
> extend our previous work in which we use **textual features**…" — [Scalabrino et al. 2018][scalabrino], Summary

---

## What Buse & Weimer actually found about formatting

This is the only paper of the four with load-bearing layout features, so it is the only one that
can say anything about formatting. Three results, stated carefully.

**1. Blank lines beat comments.** The abstract's closing sentence:

> "our data suggests that **comments, in of themselves, are less important than simple blank lines**
> to local judgments of readability." — [Buse & Weimer 2010][buse], Abstract

This is the single most formatter-relevant empirical result in the survey. Blank-line policy is
something every formatter already has ([gofmt][gofmt]'s `maxNewlines = 2`, [dfmt][dfmt]'s
`doubleNewlineLocations`, [prettier][prettier]'s "preserve empty lines the way they were"), and it
is usually treated as a triviality. The data says it is not.

**2. Line length matters, and has language-design implications.**

> "the importance of character count per line suggests that languages should favor the use of
> constructs … that encourage short lines" — [Buse & Weimer 2010][buse], §6

Which is at least evidence that a column limit is measuring _something_ real — the thing
[gofmt][gofmt] and [zig fmt][zig-fmt] decline to manage.

**3. Identifier length does not matter.**

> "we found that the length of identifier names constitutes almost no influence on readability
> (0% relative predictive power). This observation fails to support the common belief that
> 'single-character identifiers … [make the] … maintenance task much harder'"
> — [Buse & Weimer 2010][buse], §6

Not a formatting result, but a useful calibration on how much folklore this literature overturns.

---

## The caveat that governs the whole page

Buse & Weimer state the limitation themselves, and it is fatal to the naive use of their model:

> "our model of readability is **descriptive rather than normative or prescriptive**. That is,
> while it can be used to predict human readability judgments for existing software, **it cannot
> be directly interpreted to prescribe changes that will improve readability**. For example, while
> 'average number of blank lines' is a powerful feature in our metric that is positively
> correlated with high readability, **merely inserting five blank lines after every existing line
> of code need not improve human judgments** of that code's readability."
> — [Buse & Weimer 2010][buse], §6

And, on generality:

> "we caution that this data may only be truly relevant to our annotators; it should not be
> interpreted to represent a comprehensive or universal model for readability."

A formatter _is_ an instrument that mechanically applies changes to maximize a layout property.
The one thing the authors say you must not do with the model is exactly what a formatter does with
it. Any argument of the form "the literature shows formatters should do X" is unsupported unless
X was varied experimentally — and in this literature, nothing was.

---

## The downstream quality correlations

Buse & Weimer's second contribution is a correlation between their readability metric and
"three measures of software quality: code changes, automated defect reports, and defect log
messages", measured "on over 2.2 million lines of code, as well as longitudinally". Scalabrino
replicate the FindBugs-warning correlation "on 20 software systems, for a total of 3M lines of
code" and find their more accurate model predicts warnings better.

That chain — layout features → readability score → defect warnings — is the strongest available
argument that formatting has any downstream effect at all. It is also two correlations deep, over
observational data, with no intervention at either step. It supports "readable code and buggy code
differ measurably"; it does not support "reformatting reduces defects".

---

## What this means for a D formatter

**What the evidence supports:**

- **Take blank-line policy seriously.** It is the one layout feature with a direct, quoted
  empirical result behind it, and it is cheap. Preserve author intent where possible
  ([prettier][prettier]'s rule) and normalize runs ([gofmt][gofmt]'s `maxNewlines`), rather than
  treating blank lines as noise.
- **A column limit is defensible.** Line length is a real predictor. This is a point against
  [gofmt][gofmt]'s and [zig fmt][zig-fmt]'s no-width-limit position for D.

**What the evidence does not support, and should not be cited for:**

- Any specific column limit. No study varied it.
- Brace style, space-after-keyword, alignment, or any other style option in
  [dfmt's config surface][dfmt].
- The claim that formatting reduces defects.
- The claim that a formatter improves comprehension.

**The honest framing for [the proposal][proposal]:** a formatter's justification is
_consistency and the elimination of style debate_ — [gofmt][gofmt]'s and
[prettier][prettier]'s actual argument — not measured readability gains. The evidence base for the
latter does not exist, and this page exists so the survey does not pretend otherwise.

---

## Sources

- Raymond P. L. Buse & Westley Weimer, _Learning a Metric for Code Readability_, IEEE TSE 36(4),
  2010, pp. 546–558. [`buse-weimer-2010-…-tse.pdf`][buse]
- Daryl Posnett, Abram Hindle & Premkumar Devanbu, _A Simpler Model of Software Readability_,
  MSR 2011, pp. 73–82. [`posnett-2011-…-msr.pdf`][posnett]
- Simone Scalabrino, Mario Linares-Vásquez, Rocco Oliveto & Denys Poshyvanyk, _A comprehensive
  model for code readability_, JSEP 30(6), 2018. [`scalabrino-2018-…-jsep.pdf`][scalabrino]
- Qing Mi et al. — **the two Mi papers are paywalled and were not obtained.** The author set named
  in this survey's brief (Mi, Keung, Xiao, Mensah, Gao) matches _Improving code readability
  classification using convolutional neural networks_ (IST, 2018); the 2022 JSS paper _Towards
  using visual, semantic and structural features to improve code readability classification_ is by
  Mi, Hao, Ou & Ma. A related, obtainable paper by the same group is archived as
  `mi-2021-data-augmentation-code-readability-ist.pdf`. All claims about this line are 🌐.

**Related deep-dives in this tree:**
[Concepts][concepts] · [Comparison][comparison] · [gofmt][gofmt] · [prettier][prettier] ·
[dfmt][dfmt] · [The proposal][proposal]

<!-- References -->

[buse]: https://web.archive.org/web/2020id_/https://web.eecs.umich.edu/~weimerw/p/weimer-tse2010-readability-preprint.pdf
[posnett]: http://softwareprocess.ca/pubs/posnett2011MSR-readability.pdf
[scalabrino]: https://sscalabrino.github.io/files/2018/JSEP2018AComprehensiveModel.pdf
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md
[gofmt]: ./gofmt.md
[prettier]: ./prettier.md
[dfmt]: ./dfmt.md
[zig-fmt]: ./zig-fmt.md
