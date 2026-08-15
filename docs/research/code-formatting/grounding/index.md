# Grounding — claim-by-claim verification

Claim-by-claim source verification of every page under `docs/research/code-formatting/`. Each
page has a `<page>.md` ledger; every material assertion is checked against a **local** primary
artifact (a paper in `$REPOS/papers/code-formatting/` or a repo pinned in
[`_sources.md`](./_sources.md)). Web is fallback-only.

> Not published research. Do not link to it from the survey pages.

This tree is internal QA evidence — excluded from the VitePress build (`srcExclude`) and from
lychee (`exclude_path`).

## Status legend

| Mark | Meaning                                                                                    |
| ---- | ------------------------------------------------------------------------------------------ |
| ✓    | verified verbatim / exact against a local artifact                                         |
| ◯    | this survey's synthesis, inference or opinion — defensible, but asserted by no source      |
| ⚠    | caveat: partial verification, a quote altered, or a negative claim from incomplete reading |
| 🌐   | web-fallback or general knowledge; **no local artifact consulted**                         |
| ⇒    | derived: verified in the named sibling ledger, not independently here                      |

**Types:** QUOTE (verbatim text) · code (source excerpt) · fact (measurable) · table (transcribed).

## Per-page ledgers

| Page                          | Ledger                                                    | Notes                                                                                          |
| ----------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `index.md`                    | [page-index](./page-index.md)                             | D-PI1: a source-tree count mismatch                                                            |
| `concepts.md`                 | [concepts](./concepts.md)                                 | D-C1 **fixed**; the IR cross-naming table is the tree's most-linked synthesis                  |
| `theory/index.md`             | [theory-index](./theory-index.md)                         | D-TI1 (Hughes quote is image-only), D-TI3 (two undatable milestones)                           |
| `theory/oppen.md`             | [theory-oppen](./theory-oppen.md)                         | OCR caveats in §§4, 8                                                                          |
| `theory/combinators.md`       | [theory-combinators](./theory-combinators.md)             | **D-C1: `hughes95` has no text layer** — the tree's weakest evidence for its most-reused quote |
| `theory/optimality.md`        | [theory-optimality](./theory-optimality.md)               | D-Op1 (Podkopaev entirely second-hand), D-Op5 (the Knuth–Plass claim is ours)                  |
| `theory/cost-and-search.md`   | [theory-cost-and-search](./theory-cost-and-search.md)     | D-CS1 (scalafmt from a 2016 thesis)                                                            |
| `theory/layout-preserving.md` | [theory-layout-preserving](./theory-layout-preserving.md) | D-LP1 (OCR repairs inside quotes), D-LP3 (the formatter specialization is ours)                |
| `dfmt.md`                     | [dfmt](./dfmt.md)                                         | source-dense; negative claims flagged                                                          |
| `prettier.md`                 | [prettier](./prettier.md)                                 | engine verified; language rules unread                                                         |
| `clang-format.md`             | [clang-format](./clang-format.md)                         | **resolves D-CS4** (12 `Penalty*` options, counted); most of 36,925 lines unread               |
| `rustfmt.md`                  | [rustfmt](./rustfmt.md)                                   | `Design.md` verbatim; the fallback path untraced                                               |
| `gofmt.md`                    | [gofmt](./gofmt.md)                                       | tabwriter semantics are 🌐                                                                     |
| `zig-fmt.md`                  | [zig-fmt](./zig-fmt.md)                                   | the no-width-limit claim is a fully-inspected grep                                             |
| `roslyn.md`                   | [roslyn](./roslyn.md)                                     | ⚠ **least source-verified page in wave 1**                                                     |
| `dart-style.md`               | [dart-style](./dart-style.md)                             | **D-DS1 found and fixed** — an incorrect exclusivity claim                                     |
| `topiary.md`                  | [topiary](./topiary.md)                                   | ⚠ **`topiary-core` not read at all**                                                           |
| `ocamlformat.md`              | [ocamlformat](./ocamlformat.md)                           | verification loop fully verified; `Normalize_std_ast` unread                                   |
| `swift-format.md`             | [swift-format](./swift-format.md)                         | ⚠ one file read; substrate claims are 🌐                                                       |
| `rust-reimplementations.md`   | [rust-reimplementations](./rust-reimplementations.md)     | ⚠ no Rust source read                                                                          |
| `long-tail.md`                | [long-tail](./long-tail.md)                               | **D-LT1: the astyle/uncrustify section is ungrounded**                                         |
| `verification.md`             | [verification](./verification.md)                         | the "only one above tier 4" claim is a broad negative                                          |
| `readability-evidence.md`     | [readability-evidence](./readability-evidence.md)         | both Mi papers 🌐                                                                              |
| `comparison.md`               | [comparison](./comparison.md)                             | aggregation; inherits every upstream caveat                                                    |
| `d-landscape.md`              | [d-landscape](./d-landscape.md)                           | sdfmt verified from source                                                                     |
| `dmd-lsp-baseline.md`         | [dmd-lsp-baseline](./dmd-lsp-baseline.md)                 | ✓ **best-grounded page in the tree**; D-BL1 is the one open risk                               |
| `dmd-fmt-proposal.md`         | [dmd-fmt-proposal](./dmd-fmt-proposal.md)                 | editorial by construction; premises tabulated                                                  |

## What this ledger caught

Recorded because a verification pass that finds nothing is not a verification pass:

1. **D-DS1** — `dart-style.md` claimed memoized sub-solutions were unique in the survey; sdfmt does
   the same. **Fixed.**
2. **D-C1** — `concepts.md` said DMD's substrate lacks offsets, which
   [`dmd-lsp-baseline`](./dmd-lsp-baseline.md) disproved. **Fixed.**
3. **D-CS4** — "~10 `Penalty*` options" was an uncounted estimate; it is 12. **Fixed.**
4. **D-TI2** — the comment word-count claim was made on three greps and overstated as ten papers;
   re-run over all seven held papers it came out _differently_ (APEP engages more than claimed;
   Wadler's and Swierstra & Chitil's hits are acknowledgements). **Fixed, and the corrected finding
   is stronger.**
5. **D-Op3/D-Op4** — two quote divergences in `optimality.md`. **Fixed.**
6. **D-CS5** — an unverified negative ("none cites Yelland") softened to a checkable claim. **Fixed.**

## Known weak points, ranked

1. **The Hughes Remark** ([theory-combinators](./theory-combinators.md) D-C1) — the tree's
   most-reused quote, sourced only from a 130 dpi page rendering. Independently corroborated in
   substance by Yelland's footnote. **Wants a second reader.**
2. **`roslyn.md`, `topiary.md`, `swift-format.md`** — three deep-dives where the engine source was
   not read and the architectural claims are inference.
3. **The astyle/uncrustify section** ([long-tail](./long-tail.md) D-LT1) — clone and verify, or
   delete.
4. **D-BL1** — whether the pinned DMD fork actually compiles the DMDLIB `whitespaceToken` path.
   This is the one open question that could change [the proposal](../dmd-fmt-proposal.md).
5. **Podkopaev & Boulytchev and both Mi papers** — paywalled; used second-hand throughout.
