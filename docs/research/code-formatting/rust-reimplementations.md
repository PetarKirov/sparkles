# The Rust Reimplementation Wave — dprint, Biome, ruff-format

Three projects that reimplemented existing formatters in Rust: **dprint** (a plugin host with a
[Wadler-style][combinators] IR), **Biome** (a prettier-compatible JS/CSS/JSON/GraphQL formatter),
and **ruff-format** (a black-compatible Python formatter). Their layout algorithms are not new —
all three are `Doc`-IR combinator engines. What is new, and what earns them a place in this
survey, is the **engineering discipline of reimplementing a formatter compatibly**: a published,
CI-gated _numeric_ compatibility metric, and a stability harness that names the three ways a
formatter goes wrong.

That methodology transfers directly to [a D formatter measured against dfmt][proposal].

|              |                                                                                            |
| ------------ | ------------------------------------------------------------------------------------------ |
| **dprint**   | [`dprint/dprint`][dprint-repo] @ `350f31d7` — plugin host, WASM plugins, incremental cache |
| **Biome**    | [`biomejs/biome`][biome-repo] @ `3e8c4887` — `biome_formatter` + 9 language crates         |
| **ruff**     | [`astral-sh/ruff`][ruff-repo] @ `3b067a16` — `ruff_formatter` + `ruff_python_formatter`    |
| **Category** | AST · combinator `Doc` IR · compatibility-driven                                           |

---

## Why one page

All three share an architecture that is already covered: an AST is converted to a `Doc`-like IR
(`ruff_formatter`'s `format_element`, `biome_formatter`'s equivalent) with `group`, `indent`,
`soft_line_break`, `line_suffix` and friends, and rendered by a greedy [Lindig-style][combinators]
printer. Reading all three separately would repeat [the prettier deep-dive][prettier] three times.

Their genuine contribution is on a different axis, and it is one no other system in this survey
publishes.

---

## The compatibility metric

ruff's formatter states its goal as compatibility, not improvement:

> "The goal of our formatter is to be compatible with Black except for rare edge cases"
> — [`crates/ruff_python_formatter/CONTRIBUTING.md`][ruff-contributing]

and then makes that goal **measurable, continuously**:

> "**Ecosystem checks** `scripts/formatter_ecosystem_checks.sh` runs Black compatibility and
> stability checks on a number of selected projects. It will print the **similarity index, the
> percentage of lines that remains unchanged between Black's formatting and our formatting**. You
> could compute it as the number of neutral lines in a diff divided by the neutral plus the
> removed lines. We run this script in CI … **You should ensure that your changes don't decrease
> the similarity index.**" — [`CONTRIBUTING.md`][ruff-contributing]

Three properties make this worth copying:

1. **It is a single number**, so it can be a CI gate and a review criterion ("don't decrease it")
   rather than a judgement call.
2. **Its definition is published**: neutral lines ÷ (neutral + removed). Not "we compared some
   files" — an arithmetic anyone can reproduce.
3. **It runs against real projects**, not a fixture corpus, so it measures the code people
   actually have.

The snapshot discipline is the complement: ruff copied Black's test corpus, and "whenever we have
no more differences on a Black input file, **the snapshot is deleted**". The test suite shrinks as
compatibility improves — remaining snapshots _are_ the remaining incompatibilities.

## The stability harness

The same script checks three failure modes, and the enumeration is the useful part:

> "The stability checks catch for three common problems: **The second formatting pass looks
> different than the first** (formatter instability or lack of idempotency), **printing invalid
> syntax** (e.g. missing parentheses around multiline expressions) and **panics** (mostly in debug
> assertions)." — [`CONTRIBUTING.md`][ruff-contributing]

Mapped onto [the concepts vocabulary][concepts-idem]: idempotence, semantic preservation, and
crash-freedom — checked over an ecosystem corpus on every change. This is
[ocamlformat's runtime discipline][ocamlformat] moved into CI, and it is a cheaper way to get
most of the same assurance.

## What else these projects contribute

- **dprint: plugins as WASM.** Formatters are `.wasm` modules the host loads, so a plugin need not
  be written in Rust and the host need not know the language. dprint also ships an **incremental
  cache** keyed on file content + config, so a repeat run over an unchanged repository does
  almost nothing — the only caching story in this survey.
- **Biome: one IR, nine languages.** `biome_formatter` plus `biome_{js,css,json,html,markdown,
yaml,graphql,grit}_formatter` — the same evidence [prettier][prettier] provides for the
  reusability of a `Doc` IR, reproduced independently.
- **Both: performance as the product.** Neither claims better _layout_; they claim the same layout,
  faster. That is only a coherent product claim because the compatibility metric exists to back it.

---

## 1–6, briefly (the spine)

1. **Input model & fidelity** — AST plus comment attachment, as [prettier][prettier]. All three
   refuse unparseable input. ruff additionally checks that its own output reparses.
2. **Layout IR & break decision** — [combinator `group`/flat, greedy][combinators]; hard line
   width.
3. **Alignment, indentation & vertical rhythm** — inherited from the formatter being cloned.
4. **Comments, trivia & preservation** — the expensive part, again: matching another formatter's
   comment placement is where the residual similarity-index gap lives.
5. **Configurability** — deliberately matching the original's small surface (ruff ≈ black's).
   dprint is the outlier: config is per-plugin, in `dprint.json`.
6. **Integration surface** — whole document; `--check`; dprint adds the incremental cache. No edit
   output, no range formatting, no cursor.

---

## Strengths

- **Compatibility as a measured, gated number** — the single most transferable practice here.
- **A named, checkable stability triad**: idempotence, valid output, no panics.
- **Shrinking snapshot corpus** as an honest progress signal.
- **Ecosystem-scale corpora** rather than fixtures.
- **dprint's incremental cache** and **WASM plugin boundary**.
- **Independent confirmation** that a `Doc` IR generalizes across languages.

## Weaknesses

- **No algorithmic contribution.** These are ports; the layout ceiling is the original's.
- **Compatibility is a cage.** Bugs in the original must be reproduced, and improvements are
  incompatibilities by definition.
- **Whole-document output**, no LSP-grade integration.
- **The similarity index is line-based**, so it under-weights a single catastrophic layout change
  and over-weights whitespace-only churn.

---

## Key design decisions and trade-offs

| Decision                                               | Rationale                                             | Trade-off                                                              |
| ------------------------------------------------------ | ----------------------------------------------------- | ---------------------------------------------------------------------- |
| **Target byte-compatibility with an incumbent**        | Users can switch without a repo-wide diff             | The incumbent's bugs become requirements; improvements are regressions |
| **Publish a similarity index and gate CI on it**       | Turns "compatible" into a reviewable number           | Line-based, so it measures diff size rather than severity              |
| **Delete snapshots once they match**                   | The remaining corpus _is_ the remaining work          | Loses regression coverage for cases already fixed                      |
| **Check idempotence + valid syntax + panics together** | The three ways a formatter fails in the field         | Ecosystem runs are slow; they gate CI rather than local iteration      |
| **dprint: WASM plugin boundary**                       | Plugins in any language; host stays language-agnostic | Serialization overhead at the boundary; debugging across it is harder  |
| **dprint: content+config-keyed incremental cache**     | Repeat runs over a large repo become free             | Cache invalidation must track config precisely or output goes stale    |
| **Rewrite in Rust for speed**                          | Formatting is on the save path and the CI path        | A second implementation to keep in sync with a moving target           |

---

## What a D formatter should take

**Take the methodology wholesale.** [The proposal][proposal]'s M8 is exactly this:

- Format Phobos, druntime and this repository with both dfmt and the new formatter; publish the
  **similarity index** with ruff's published definition, and gate CI on not decreasing it.
- Run the **stability triad** on every change: format twice and compare; reparse and check
  token/AST equality; assert no crashes.
- **Delete fixtures as they converge**, so the remaining corpus is the remaining disagreement.

This is how "we replaced dfmt" becomes a claim with a number attached rather than an assertion —
and it is worth adopting even if the D formatter deliberately _diverges_ from dfmt, because then
the index measures the size of the deliberate divergence.

**Take, if the tool ever gets slow:** dprint's content-keyed incremental cache.

---

## Sources

- [`astral-sh/ruff`][ruff-repo] @ `3b067a163e58614fd022c24f1274404a0f386179`:
  `crates/ruff_formatter/src/` (`builders.rs`, `format_element/`, `formatter.rs`, `group_id.rs`),
  `crates/ruff_python_formatter/CONTRIBUTING.md`, `docs/formatter.md`, `docs/formatter/black.md`
- [`biomejs/biome`][biome-repo] @ `3e8c4887c4ef87df45f56aafa4fbc5f497dae42f`:
  `crates/biome_formatter` + nine `biome_*_formatter` crates
- [`dprint/dprint`][dprint-repo] @ `350f31d737b4f1ebb9bafdd9eecbfb1d0a427eec`: `crates/core`,
  `crates/dprint`

**Related deep-dives in this tree:**
[Combinators][combinators] · [Verification][verification] · [prettier][prettier] ·
[ocamlformat][ocamlformat] · [Long tail][long-tail] · [Comparison][comparison] ·
[The proposal][proposal]

<!-- References -->

[ruff-repo]: https://github.com/astral-sh/ruff/tree/3b067a163e58614fd022c24f1274404a0f386179
[ruff-contributing]: https://github.com/astral-sh/ruff/blob/3b067a163e58614fd022c24f1274404a0f386179/crates/ruff_python_formatter/CONTRIBUTING.md
[biome-repo]: https://github.com/biomejs/biome/tree/3e8c4887c4ef87df45f56aafa4fbc5f497dae42f
[dprint-repo]: https://github.com/dprint/dprint/tree/350f31d737b4f1ebb9bafdd9eecbfb1d0a427eec
[combinators]: ./theory/combinators.md
[concepts]: ./concepts.md
[concepts-idem]: ./concepts.md#7-idempotence-stability-convergence
[verification]: ./verification.md
[comparison]: ./comparison.md
[proposal]: ./dmd-fmt-proposal.md
[prettier]: ./prettier.md
[ocamlformat]: ./ocamlformat.md
[long-tail]: ./long-tail.md
