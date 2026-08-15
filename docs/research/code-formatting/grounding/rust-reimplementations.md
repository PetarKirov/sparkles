# Grounding ledger — rust-reimplementations.md

Verification against `$REPOS/rust/ruff` @ `3b067a163e58614fd022c24f1274404a0f386179`,
`$REPOS/rust/biome` @ `3e8c4887c4ef87df45f56aafa4fbc5f497dae42f`,
`$REPOS/rust/dprint` @ `350f31d737b4f1ebb9bafdd9eecbfb1d0a427eec` (all **depth-1**).

## Verified verbatim (✓)

| Claim                                                                                                                                             | Source                                                  |
| ------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------- |
| "The goal of our formatter is to be compatible with Black except for rare edge cases"                                                             | `ruff` `crates/ruff_python_formatter/CONTRIBUTING.md:3` |
| The **similarity index** paragraph in full, incl. its arithmetic and "You should ensure that your changes don't decrease the similarity index."   | `CONTRIBUTING.md:88-96`                                 |
| The **three stability checks** ("second formatting pass looks different", "printing invalid syntax", "panics")                                    | `CONTRIBUTING.md:96-99`                                 |
| "We have copied the majority of tests over from Black … Whenever we have no more differences on a Black input file, **the snapshot is deleted**." | `CONTRIBUTING.md:84-86`                                 |
| `crates/ruff_formatter/src/` file list (`builders.rs`, `format_element/`, `formatter.rs`, `group_id.rs`, `buffer.rs`, …)                          | `ls`                                                    |
| Biome's nine `biome_*_formatter` crates + `biome_formatter`                                                                                       | `ls crates/ \| grep formatter`                          |
| dprint's `crates/` list (`core`, `dprint`, `test-plugin`, …)                                                                                      | `ls`                                                    |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                                | Status | Note                                                                                                     |
| --- | ---------------------------------------------------------------------------------------------------- | ------ | -------------------------------------------------------------------------------------------------------- |
| 1   | "all three are `Doc`-IR combinator engines" with `group`, `indent`, `soft_line_break`, `line_suffix` | ⚠      | **Inferred from `builders.rs` / `format_element` existing.** No Rust source in any of the three was read |
| 2   | "**dprint: plugins as WASM**" and the **incremental cache** keyed on content + config                | 🌐     | Documented behaviour of dprint; **not verified in this repo**                                            |
| 3   | "Biome: one IR, nine languages"                                                                      | ✓◯     | The nine crates are verified; that they share one IR is inferred from `biome_formatter`'s existence      |
| 4   | "Neither claims better _layout_; they claim the same layout, faster"                                 | ◯      | Editorial characterization; ruff's compatibility goal is verified, the performance framing is not quoted |
| 5   | "All three refuse unparseable input"                                                                 | 🌐     | Not verified                                                                                             |
| 6   | "ruff additionally checks that its own output reparses"                                              | ✓      | Implied by the "printing invalid syntax" stability check (verified)                                      |
| 7   | "matching another formatter's comment placement is where the residual similarity-index gap lives"    | ◯      | Plausible and unsourced                                                                                  |
| 8   | "**The similarity index is line-based**, so it under-weights a single catastrophic layout change"    | ◯      | Follows from the verified definition; the judgement is the survey's                                      |
| 9   | The M8 recommendation                                                                                | ◯      | Editorial — but built directly on the verified methodology                                               |

## Not verified here

- **No Rust source was read in any of the three projects.** This page is grounded almost entirely
  in one CONTRIBUTING.md, which is fine for its thesis (the methodology) and thin for its
  architecture claims (row 1).
- `docs/formatter.md` and `docs/formatter/black.md` in ruff were located but not read.
