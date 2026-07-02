# Grounding ledger — `rustc-queries.md`

Claim-by-claim verification of `docs/research/parsing/rustc-queries.md` against the **local** pinned
`$REPOS/rust/rustc-dev-guide` `646dd8e` (2026-07-01). `$REPOS = /home/petar/code/repos`.
Primary chapters: `src/query.md`, `src/queries/incremental-compilation.md`,
`src/queries/incremental-compilation-in-detail.md`, `src/overview.md`.

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase / abridged-but-faithful ·
⚠ discrepancy · ◯ opinion/interpretation · 🌐 web/secondary (not locally groundable).

| #   | Claim                                                                                                                                                                | Type       | Source (local + locator)                                             | Status |
| --- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------- | ------ |
| 1   | "Instead of entirely independent passes (parsing, type-checking, etc.), a set of function-like queries compute information about the input source."                  | QUOTE      | `src/query.md`                                                       | ✓      |
| 2   | `type_of` example: given a `DefId`, computes the type of that item                                                                                                   | fact       | `src/query.md`                                                       | ✓      |
| 3   | "Query execution is memoized. The first time you invoke a query, it will go do the computation, but the next time, the result is returned from a hashtable."         | QUOTE      | `src/query.md`                                                       | ✓      |
| 4   | Top-level `compile` query demands from the end "further and further back until we wind up doing the actual parsing"                                                  | QUOTE      | `src/query.md`                                                       | ✓      |
| 5   | Providers: cache miss → provider fn; `Providers`/`ExternProviders` macro-generated function tables (plain structs of fn pointers, not traits); local vs extern crate | fact/QUOTE | `src/query.md` §"Providers"                                          | ✓      |
| 6   | "what determines the crate that a query is targeting is not the _kind_ of query, but the _key_."                                                                     | QUOTE      | `src/query.md`                                                       | ✓      |
| 7   | Incrementality is "in essence, a surprisingly simple extension to the overall query system."                                                                         | QUOTE      | `src/queries/incremental-compilation.md:3-4` (line-wrapped)          | ✓      |
| 8   | The basic algorithm is the **red-green** algorithm; save query results + the query DAG each run                                                                      | fact/QUOTE | `incremental-compilation.md:9-17`                                    | ✓      |
| 9   | Query colored **red** = result changed this compile; **green** = same as previous                                                                                    | QUOTE      | `incremental-compilation.md` §"basic algorithm"                      | ✓      |
| 10  | Early cutoff: a change that yields the same fingerprint stops propagating; projection queries "act as a 'firewall', shielding their dependents"                      | QUOTE      | `incremental-compilation-in-detail.md:479`                           | ✓      |
| 11  | Overhead of the on-disk scheme "is a few percent of total compilation time."                                                                                         | QUOTE      | `incremental-compilation-in-detail.md:544`                           | ✓      |
| 12  | Without early cutoff a downstream tool "has to rewrite each file entirely in each compilation session."                                                              | QUOTE      | `incremental-compilation-in-detail.md:543`                           | ✓      |
| 13  | On-disk cache persists results **across** compiler sessions (not a live edit tree)                                                                                   | fact       | `incremental-compilation.md`; `incremental-compilation-in-detail.md` | ✓      |
| 14  | Fingerprints compare outputs for change detection (the early-cutoff test)                                                                                            | fact       | `incremental-compilation-in-detail.md` (fingerprint discussion)      | ≈      |
| 15  | Invoked via `TyCtxt` method per query (`tcx.type_of(def_id)`)                                                                                                        | fact       | `src/query.md` §"Invoking queries"                                   | ✓      |
| 16  | **Honest scope:** parsing itself is NOT query-driven / NOT incremental; front-end lexer/parser is batch hand-written RD                                              | fact       | `src/query.md` (queries start from AST/HIR); framing                 | ≈      |
| 17  | `IntValue(x)` 1000→2000 example: a change that need not invalidate dependents (early cutoff)                                                                         | fact       | `incremental-compilation-in-detail.md` (worked example)              | ≈      |
| 18  | Contrast: rustc reuses on-disk results across runs vs tree-sitter live-edit vs rust-analyzer in-memory salsa                                                         | interp     | cross-page synthesis                                                 | ◯      |
| 19  | red-green algorithm noted as salsa-like (`[^salsa]` footnote)                                                                                                        | fact       | `incremental-compilation.md:9` `[^salsa]`                            | ✓      |
| 20  | Design traces to Niko Matsakis's on-demand/incremental design doc; incremental default for debug builds since 2016                                                   | fact       | 🌐 `nikomatsakis/...` design doc + Rust blog 2016 (external)         | 🌐     |
| 21  | License dual MIT/Apache-2.0; repo `rust-lang/rust`, guide `rust-lang/rustc-dev-guide`                                                                                | fact       | rustc-dev-guide standard licensing; 🌐 for the exact SPDX            | 🌐     |
| 22  | Strengths / Weaknesses / trade-off tables                                                                                                                            | synthesis  | derived from verified rows                                           | ◯      |

## Discrepancies

None. Notably, the quote "a surprisingly simple extension to the overall query system" (page lines 100, 190) **is** verbatim — it is line-wrapped in the source (`incremental-compilation.md:3-4`: "…is, in
essence, a surprisingly\nsimple extension to the overall query system."), so a single-line grep misses
it; confirmed present. All other in-guide quotes match verbatim.

## Web-fallback / not-locally-groundable

- **Attribution & dates** — Niko Matsakis as query/red-green designer, the on-demand design doc, and the
  "incremental default since the 2016 announcement" are external (design doc repo + Rust blog), correctly
  linked in-text as `[design-doc]` / `[announce]`, not asserted from the pinned guide.
- **License SPDX** (MIT/Apache-2.0) — standard for `rust-lang/rust` but taken from the ecosystem, not a
  file in the pinned dev-guide.

## Opinion (◯) — legitimate survey voice

- rustc is "the purest query-based-compiler exemplar" and "the direct answer to query-based compiler
  design" (positioning).
- The cross-system contrast (row 18) and Strengths/Weaknesses/trade-off tables (row 22).

**Net:** 0 discrepancies (the one at-risk quote is a false alarm from source line-wrapping — verified
present at `incremental-compilation.md:3-4`). All mechanism quotes (demand-driven/memoized, providers,
red-green, firewall, few-percent) are verbatim-grounded; only author attribution and the license SPDX
are web-attested.
