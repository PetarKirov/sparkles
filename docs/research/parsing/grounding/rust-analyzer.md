# Grounding ledger — `rust-analyzer.md`

Claim-by-claim verification of `docs/research/parsing/rust-analyzer.md` against **local** pinned
sources. `$REPOS = /home/petar/code/repos`.

- `$REPOS/rust/rust-analyzer` `3033d4f` (2026-07-02) — `docs/book/src/contributing/{architecture,syntax}.md`, `crates/`, `Cargo.toml`
- `$REPOS/rust/salsa` `9447e2f` (2026-07-02) — `README.md`, `src/{durability,cancelled,cycle}.rs`
- `$REPOS/rust/rowan` `0c1077e` (2025-07-27) — `README.md`, `src/green/node_cache.rs`

Status key: ✓ verified verbatim/exact · ≈ accurate paraphrase / abridged-but-faithful ·
⚠ discrepancy · ◯ opinion/interpretation · 🌐 web/secondary (not locally groundable).

| #   | Claim                                                                                                                                                                                                                                                                     | Type      | Source (local + locator)                                          | Status |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------- | ----------------------------------------------------------------- | ------ |
| 1   | Lossless `rowan` red-green CST; positions/parents computed on the red side                                                                                                                                                                                                | fact      | `syntax.md` (red-green section); rowan `README.md`                | ≈      |
| 2   | Structural sharing: "in `1 + 1`, there will be a _single_ token for `1` with ref count 2" (+ whitespace)                                                                                                                                                                  | QUOTE     | `docs/book/src/contributing/syntax.md:125`                        | ✓      |
| 3   | Memoizing red nodes "more than doubles the memory requirements for fully realized syntax trees"                                                                                                                                                                           | QUOTE     | `syntax.md:311`                                                   | ✓      |
| 4   | Invariant: "even for invalid code, curly braces are always paired correctly"                                                                                                                                                                                              | QUOTE     | `syntax.md:522`                                                   | ✓      |
| 5   | Error-resilient parser: produces a tree for invalid code (IDE contract)                                                                                                                                                                                                   | fact      | `syntax.md` (error-resilience section) + `crates/parser`          | ≈      |
| 5a  | **Load-bearing:** "In practice, incremental reparsing doesn't actually matter much for IDE use-cases, parsing from scratch seems to be fast enough." (RA's own honest note; the spine of the page's Incrementality-model section + `comparison.md`'s "stay batch" lesson) | QUOTE     | `syntax.md:524`                                                   | ✓      |
| 5b  | Durability firewall is concrete: library file text = `Durability::HIGH`, source root = `MEDIUM`/`LOW`                                                                                                                                                                     | fact      | `crates/base-db/src/change.rs:94,98`                              | ✓      |
| 6   | salsa = "A generic framework for on-demand, incrementalized computation"; program = set of queries (inputs vs pure memoized functions)                                                                                                                                    | QUOTE     | salsa `README.md` (tagline + "Key idea")                          | ✓      |
| 7   | salsa extracted from rust-analyzer; both published crates                                                                                                                                                                                                                 | fact      | salsa `README.md`; RA `crates/*` depends on `salsa`               | ✓      |
| 8   | Durability: skip revalidation — "if we know that the only changes were to inputs of low durability … and … the query only used inputs of medium durability or higher, then we can skip that enumeration."                                                                 | QUOTE     | salsa `src/durability.rs`                                         | ✓      |
| 9   | Inputs default `LOW`, interned `NEVER_CHANGE`; hot file = LOW, config/library = higher                                                                                                                                                                                    | fact      | salsa `src/durability.rs` (doc comment)                           | ✓      |
| 10  | Cancellation on pending write: `Cancelled::PendingWrite` = "operating on revision R, but there is a pending write to move to revision R+1"                                                                                                                                | QUOTE     | salsa `src/cancelled.rs`                                          | ✓      |
| 11  | Cycle handling: "if we encounter a cycle … we panic" (default recovery)                                                                                                                                                                                                   | QUOTE≈    | salsa `src/cycle.rs` / README cycle docs                          | ≈      |
| 12  | Green tree is a "DAG, not a tree"; sharing makes many versions cheap                                                                                                                                                                                                      | fact      | `syntax.md` (mirrors Roslyn); rowan `README`                      | ≈      |
| 13  | rowan green-node cache (dedup identical subtrees) → `src/green/node_cache.rs`                                                                                                                                                                                             | fact      | rowan `src/green/node_cache.rs` exists                            | ✓      |
| 14  | "no passes, just queries": name-res/types/diagnostics all queries; lazy & on-demand                                                                                                                                                                                       | fact      | `architecture.md` (crates: `hir`, `ide`, `base-db`)               | ≈      |
| 15  | Parser is hand-written recursive descent producing the CST; salsa sits above                                                                                                                                                                                              | fact      | `crates/parser/src/lib.rs`; `architecture.md`                     | ≈      |
| 16  | "to enable parallel parsing of all files" (design motive)                                                                                                                                                                                                                 | QUOTE     | `architecture.md` / `syntax.md`                                   | ✓      |
| 17  | Key authors: Aleksey Kladov (matklad, creator), Lukas Wirth (Veykril), contributors                                                                                                                                                                                       | fact      | `Cargo.toml` authors = "rust-analyzer team"; creator = 🌐 history | 🌐     |
| 18  | Rolling weekly, unversioned (`< 1.0`); rustup component + VS Code extension                                                                                                                                                                                               | fact      | 🌐 release process; repo has no SemVer tags for the binary        | 🌐     |
| 19  | matklad blog "Three Architectures for a Responsive IDE" (design rationale)                                                                                                                                                                                                | fact      | 🌐 `rust-analyzer.github.io/blog` (external)                      | 🌐     |
| 20  | Incrementality model: token/subtree/query granularity; durability firewalls; cancellation                                                                                                                                                                                 | synthesis | rows 2–11 + theory page                                           | ≈      |
| 21  | Strengths / Weaknesses / trade-off tables                                                                                                                                                                                                                                 | synthesis | derived from verified rows                                        | ◯      |

## Discrepancies

None. Every in-repo blockquote matches the pinned tree verbatim (`syntax.md` :125/:311/:522; salsa
`README`/`durability.rs`/`cancelled.rs`). The `## salsa: the query engine` heading (anchor
`salsa-the-query-engine`) is the link target used by `theory/incremental.md`, `index.md`, `comparison.md`,
`roslyn.md`, and `rustc-queries.md`; the VitePress build resolves it.

## Web-fallback / not-locally-groundable

- **Authorship/creator** (matklad, Veykril) and **origin year 2018** — the pinned `Cargo.toml` lists the
  author only as "rust-analyzer team"; the matklad-as-creator fact is community history (blog/repo log),
  correctly attributed in-text to the project blog.
- **Release cadence** ("weekly, unversioned, `< 1.0`") — the release process, not a tree fact.
- **"Three Architectures for a Responsive IDE"** — an external matklad blog post (title accurate).

## Opinion (◯) — legitimate survey voice

- rust-analyzer is "the reference design for a query-based compiler front-end" (cross-page judgment).
- Strengths/Weaknesses/Key-design-decision tables (row 21).

**Net:** 0 discrepancies. All mechanism quotes (rowan sharing, salsa on-demand/durability/cancellation)
are verbatim-grounded in the pinned trees; authorship, cadence, and the blog title are the only
web-attested items and are flagged as such in-text.
