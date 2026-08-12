# Modern D Language Features — grounding ledger

> Not published. Do not link to it from the guide.

Claim-by-claim source verification of
`docs/guidelines/d-language-features/index.md` against the local `dlang.org`
changelog tree pinned in [`_sources.md`](./_sources.md).

Primary: `$REPOS/dlang/dlang.org` @ `351dd6d91bfed604b473c4dedd4b5fdf262c3629`
(reviewed 2026-08-12). Guide ceiling remains **2.112**.

## Status legend

| Mark | Meaning                                                                                              |
| ---- | ---------------------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact (locator recorded)                                         |
| `≈`  | Accurate paraphrase / abridged-but-faithful (not a fake quote)                                       |
| `⚠`  | Discrepancy — wrong, misattributed, or fabricated; correction recorded **and** applied to `index.md` |
| `◯`  | Not changelog-groundable — editorial, Sparkles policy, or primary unobtainable (fallback named)      |
| `🌐` | Web-only fallback (use sparingly; prefer local `.dd`)                                                |

**Types:** `quote` · `fact` · `figure` · `behavior` · `exposition` · `opinion`.

## Per-ledger index

| Ledger                                         | Covers                                | Rows (approx) | ⚠   | Status  |
| ---------------------------------------------- | ------------------------------------- | ------------- | --- | ------- |
| [quick-ref.md](./quick-ref.md)                 | Master “features to reach for” table  | 37            | 0   | ✅ done |
| [milestones.md](./milestones.md)               | Milestones table (date + landmark)    | 17            | 0   | ✅ done |
| [compiler-switches.md](./compiler-switches.md) | Preview defaults + switch list        | 34            | 0   | ✅ done |
| [memory-safety.md](./memory-safety.md)         | `@safe` / `scope` arc                 | 27            | 1   | ✅ done |
| [functions.md](./functions.md)                 | Functions, parameters & contracts     | 27            | 1   | ✅ done |
| [declarations.md](./declarations.md)           | Declarations & modules                | 19            | 0   | ✅ done |
| [construction.md](./construction.md)           | Construction, copy, move, destruction | 20            | 0   | ✅ done |
| [nogc-betterc.md](./nogc-betterc.md)           | `@nogc`, BetterC, GC-free errors      | 16            | 0   | ✅ done |
| [templates.md](./templates.md)                 | Templates & compile-time + `__traits` | 39            | 0   | ✅ done |
| [literals.md](./literals.md)                   | Literals, strings & data embedding    | 12            | 0   | ✅ done |
| [aggregates.md](./aggregates.md)               | Aggregates, operators & collections   | 18            | 0   | ✅ done |
| [shared.md](./shared.md)                       | `shared` & atomics                    | 10            | 0   | ✅ done |
| [interop.md](./interop.md)                     | C / C++ / Objective-C                 | 25            | 0   | ✅ done |
| [legacy.md](./legacy.md)                       | “Write X instead of Y” table          | 8             | 0   | ✅ done |

## Master discrepancy register

| #   | Ledger        | Claim                                                         | Correction                                                               | Source                                            | Fixed? |
| --- | ------------- | ------------------------------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------------------- | ------ |
| R1  | functions     | Defaulted params after template variadics **[2.078]/[2.079]** | Feature lands only in **[2.079]** (`default_after_variadic`); drop 2.078 | `changelog/2.079.0.dd` § `default_after_variadic` | ✓      |
| R2  | memory-safety | Slicing a static array is `@system` **[2.074]**               | Fixed in **[2.073]** as BUGZILLA 8838                                    | `changelog/2.073.0.dd:199`                        | ✓      |

### Notes (not ⚠)

| Note | Detail                                                                                                                                                                                                                                                              |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| N1   | **Named arguments [2.103]/[2.108]** — no 2.103 changelog TOC entry; dmd git proves implementation in `v2.103.0`; documentation changelog at `2.108.0.dd` § `dmd.named-arguments`. Guide wording “implemented … completed & documented” is fair → ledger `≈`, not ⚠. |
| N2   | **Early releases (≤2.062)** — UDA / `alias Name = Type` appear only sparsely (COMMENT / next-release “newly introduced”) → `≈`.                                                                                                                                     |
| N3   | **Policy rows** (`-preview=in`, `dip1000`, annotate-non-templates, Expected toolkit, test-runner package.d) → `◯` against Sparkles AGENTS / `dub.sdl`.                                                                                                              |
| N4   | **DIP1003 `body`→`do` at [2.075]** — not a clear TOC bullet in sparse `2.075.0.dd`; confirmed by `2.078.0.dd` § `body` stating DIP1003 was added in 2.075.0 → `≈`.                                                                                                  |

## Close-out checklist

- [x] Touched version stamps / DIP ids / preview boundaries have ledger rows
- [x] Multi-hop claims list both ends (where claimed)
- [x] Discrepancy rows applied to `index.md` (`Fixed?` ✓)
- [x] No published link into `grounding/` or `AGENTS.md`
- [x] `_sources.md` records full pin SHA and secondaries
- [x] `**Last reviewed:**` updated (August 12, 2026)
- [x] Added missing `[2.073]` reference link for R2 fix
