# `sparkles:fuzzy` — Specification

_Normative at the contract level: it fixes the library's invariants, algorithms,
constants, and public surface, while leaving code-level layout to
implementation. Delivery order and per-milestone gates live in
[PLAN.md](./PLAN.md). The evidence base is the
[fuzzy-matching research catalog](../../research/fuzzy-matching/index.md); the
consuming feature is [hue's picker](../hue/picker.md) (`DEF23`/`DEF24`), whose
`PKQ`/`PKR`/`PKM` requirement rows this document traces inline._

**The library does not exist yet.** Every section describes a target; the
**(target — Mn)** markers name the [PLAN](./PLAN.md) milestone that ships it.

## 1. Overview

`sparkles:fuzzy` is a fuzzy-search engine library: a constraint query
language, a typo-tolerant matcher, a composite ranking formula, frecency and
query-history models, and a glob matcher — the compute core behind hue's
picker (`<leader>ff`, `<leader>/`), usable by any tool that ranks candidates
against keystrokes.

It is a **port of the [fff](../../research/fuzzy-matching/fff.md) engine's
algorithms** — whose matcher is
[frizbee](../../research/fuzzy-matching/frizbee.md) (Smith-Waterman with
substitution, the only design in the surveyed field with native typo
tolerance) — with the defects recorded in the research catalog fixed rather
than reproduced, and the host-integration contract informed by
[nucleo/Helix](../../research/fuzzy-matching/helix-integration.md) and
[snacks.picker](../../research/fuzzy-matching/snacks-picker.md).

Four invariants govern every section below:

1. **`@safe pure nothrow @nogc` throughout** (`PKM1`). `SmallBuffer` is the
   only dynamic container; errors are `Expected`-family values, never
   exceptions. The single sanctioned impurity is the batch driver's
   cancellation probe (§8), which is still `@safe nothrow @nogc`. Unittests
   carry the attributes explicitly, so an accidental allocation is a compile
   error (`PKM2`).
2. **The library owns no string** (`PKM3`, `PKQ1`). Queries, candidate paths,
   and every returned span borrow from caller-owned memory; match positions
   land in caller-supplied buffers.
3. **Deterministic and inspectable.** Same inputs ⇒ same ranking, with a
   per-result score breakdown (`PKR4`) and a total tie-break order — no
   dependence on iteration order, clocks, or hash seeds. Time enters only as
   explicit parameters.
4. **Complexity is part of the contract.** Every public entry point's
   documentation states its complexity and its hard budget; degradations
   (greedy fallback, truncation) are explicit, distinguishable outcomes —
   never a silent `score = 0`.

Dependencies: `sparkles:base` and `expected` — nothing else. The library
never touches threads, event loops, or the filesystem; parallel fan-out,
streaming, and persistence belong to the host (§8, §6.3).

## 2. Package and module layout

**(target — M0)**

```
libs/fuzzy/
├── dub.sdl                     # library + unittest configs, `bench` build type
├── src/sparkles/fuzzy/
│   ├── query.d                 # §3 — constraint grammar, Query, parseQuery
│   ├── prefilter.d             # §4.1 — subsequence prefilter, typo budgets
│   ├── score.d                 # §4.2–4.4 — Scoring, Matcher, kernel, positions
│   ├── rank.d                  # §5 — composite formula, breakdown, top-K
│   ├── frecency.d              # §6 — decay curves, combo boost (in-memory)
│   ├── glob.d                  # §7 — backtracking glob matcher
│   └── search.d                # §8 — budgeted batch driver, refinement probe
└── bench/matcher/              # §9 — bench harness package (corpora, foreign shim)
```

Module boundaries follow the data: `query` produces values `search` consumes;
`prefilter`/`score` know nothing about ranking; `rank` consumes match results
plus caller-supplied context and knows nothing about matching internals.

## 3. The query language

**(target — M1)**

One pass splits a query into **constraints plus a fuzzy remainder**, every
span borrowing the input (`PKQ1`). The grammar is fff's **shape-based
first-byte dispatch** — no `ext:`/`path:` prefix vocabulary to memorize —
with the two recorded parser bugs fixed.

### 3.1 Grammar

Tokens split on whitespace (no quoting). Per-token dispatch, first match
wins:

| Shape                           | Constraint        | Notes                                                                                                                                                           |
| ------------------------------- | ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `\…`                            | none — fuzzy text | backslash bypass; the `\` is retained in the fuzzy text                                                                                                         |
| `*.X` (no wildcard in `X`)      | extension         | `*.a.b` is extension `a.b`; a wildcard in `X` demotes to glob (`PKQ2`)                                                                                          |
| `!T`                            | negation of `T`   | `T` re-dispatched; negated _text_ requires ≥ 3 bytes and ≥ 1 alphanumeric, so `!=`/`!!` stay literal (`PKQ3`)                                                   |
| `/seg` or `seg/`                | path segment      | leading/trailing slashes trimmed; multi-segment (`a/b`) supported                                                                                               |
| contains `*` `?` `[` `{`        | glob              | evaluated by §7 (`PKQ2`)                                                                                                                                        |
| `git:V` `status:V` `st:V` `g:V` | git status        | `V` prefix-matches `modified` → `untracked` → `staged` → `clean` in that order; **empty or ambiguous-invalid `V` is a parse error**, not `modified` (fixes fff) |
| anything else                   | none — fuzzy text |                                                                                                                                                                 |

- **`type:` is not implemented** — in fff it is a silent no-op whose negation
  filters out everything; this grammar rejects the token shape as a parse
  error so the mistake is visible, reserving the name.
- A trailing `:line`, `:line:col`, `:l1:c1-l2:c2`, or `(line,col)` on the
  last fuzzy token parses as a **location** (`PKQ4`), so pasting
  `src/app.d:120` from a compiler diagnostic opens where it points.
- A single token that merely _looks_ like a path stays fuzzy text (fff's
  `treat_lone_path_as_text`), so `src/app` filters nothing away.
- Constraint semantics at evaluation time: extension constraints **OR**;
  all others **AND** in source order with short-circuit; fuzzy parts under
  2 bytes are dropped.

### 3.2 Types and parsing

Hand-rolled on `sparkles.base.text.readers` primitives in the
`parseSemVerShaped` style — advance-on-success over `const(char)[]`,
returning `ParseExpected!Query` (`sparkles.base.text.errors`; codes stay
mechanical — `unexpectedCharacter` at an offset with a literal context, no
fuzzy-specific enum members). The
[`sparkles:parsing` proposal](../parsing/index.md) is deliberately not a
dependency: a ~10-production flat grammar is the hand-written-RD case its
own plan defers to, and this parser can later become that proposal's
first-client evidence.

```d
enum ConstraintKind : ubyte { extension, glob, pathSegment, filePath, gitStatus, text }
enum GitStatusFilter : ubyte { modified, untracked, staged, clean }

struct Constraint
{
    ConstraintKind kind;
    bool negated;
    GitStatusFilter status;     // meaningful for kind == gitStatus
    const(char)[] value;        // borrowed from the query source
}

struct Query
{
    SmallBuffer!(Constraint, 8) constraints;
    SmallBuffer!(const(char)[], 4) fuzzyParts;  // borrowed spans
    Location location;                          // kind == none when absent
    // opEquals: value equality over span *contents*, not pointers
}

ParseExpected!Query parseQuery(return scope const(char)[] source);
```

`Query` is a **regular value**: copyable (`SmallBuffer` CoW), equality
compares span contents, `Query.init` is the valid empty query. Because its
spans borrow `source`, its lifetime is tied to the caller's buffer —
`dip1000` annotations enforce this; a host that mutates its query line
reparses (§8). `parseQuery` is the library's single **wide-contract**
boundary: arbitrary keystrokes in, `Query` or positioned error out; every
`Query` in existence is well-formed, so all downstream functions assume
validity via `in`-contracts rather than re-validating.

## 4. The matcher

The two-stage fff/frizbee design: a cheap prefilter that decides the
schedule, and a Smith-Waterman kernel that runs only on survivors.

### 4.1 The subsequence prefilter

**(target — M2)**

A greedy in-order subsequence scan over case-folded byte pairs: for each
needle byte, a precomputed `(orig, flipped)` pair; per haystack chunk an
occurrence mask (`orig == b || flipped == b`), the needle cursor advancing
_within_ the chunk by clearing consumed low bits
(`m & !(hit ^ (hit − 1))`) — so cost is per-chunk, not per-needle-byte.
Output is `(matched, window)` where the window is conservative
(start = first occurrence of the first needle byte, end = last occurrence
of the last); the kernel runs only inside it.

**Typo budgets** (`PKQ5`): the typo model is **needle-side deletion** —
a candidate passes iff an ordered alignment exists after deleting at most
`maxTypos` needle bytes. Normative oracle, enforced by randomized
differential tests: `lcs(needle, haystack) + maxTypos >= needle.length`.
Budgets 0, 1, and 2 get dedicated kernels running `budget + 1` greedy
cursors in lockstep (cursor _i_ = "has skipped _i_ needle bytes"); larger
budgets share a generic multi-path variant with reused cursor state. The
default budget is fff's query-derived formula:
`(effectiveQuery.length / 4).clamp(2, 6)`, host-overridable. `maxTypos = 0`
must cost exactly what a no-typo matcher costs — the budget lives here, not
in the DP.

Frizbee's recorded Unicode-path bug (chunk masks not reloaded per needle
char, a false-negative contract violation) is fixed by construction: every
variant computes the char mask fresh per needle position.

### 4.2 The scoring kernel

**(target — M3)**

Affine-gap Smith-Waterman **with substitution** — true local alignment, so
a wrong or dropped character degrades the score instead of eliminating the
candidate. Constants are fff/frizbee's, carried in a runtime value so tuning
is data, not a rebuild:

```d
struct Scoring
{
    ushort matchScore = 12;
    ushort mismatchPenalty = 6;
    ushort gapOpenPenalty = 5;
    ushort gapExtendPenalty = 1;
    ushort prefixBonus = 12;          // haystack byte 0 only
    ushort delimiterBonus = 4;        // first byte after a delimiter
    ushort capitalizationBonus = 4;   // upper after lower (camelCase)
    ushort matchingCaseBonus = 4;     // needle/haystack case agreement
    ushort exactMatchBonus = 8;       // whole-string byte equality
}
```

There is deliberately **no consecutive-run bonus**: a run pays no gap
penalties while a scatter pays `open + n·extend` per break, so
consecutiveness is rewarded emergently — this is what keeps the recurrence
optimal-substructure-clean (the flaw
[fzf's chunk bonus introduces](../../research/fuzzy-matching/fzf.md)).
The substitution transition is branch-free: the diagonal always pays
`mismatchPenalty` and a match refunds it plus bonuses, all scores saturating
at zero. Only the final needle row feeds the maximum, so a score always
means "whole needle consumed (modulo budgeted typos)". Delimiters are
"not a letter, not a digit, ASCII"; smart-case is fff's **score-only**
model: matching is always case-insensitive, and a query containing an
uppercase letter doubles `capitalizationBonus` to 8 and enables
`matchingCaseBonus`, while an all-lowercase query zeroes both.

The scalar kernel keeps frizbee's **log-shift horizontal-gap propagation
shape** (resolve diagonal/vertical dependencies elementwise, then a
`log2(width)`-stage shift-and-decay prefix max for the horizontal one)
rather than a serial left-to-right pass — so SIMD backends drop in behind a
DbI seam later **without changing output**. Backend parity is a normative
test obligation from M3 on: every backend must produce bit-identical scores
on the differential corpus. The fzf/nucleo constant family
(16/−3/−1, boundary-white 10, camel 5) is the documented alternative — kept
as a benchmark comparator, not implemented.

### 4.3 Memory and budgets

**(target — M3)**

Two matrices — scores and match masks — with a fixed 1024-column stride,
allocated once at `Matcher` construction into `SmallBuffer` storage and
**never re-zeroed between candidates** (row 0 and column 0 are structurally
zero and never written). Candidate paths longer than 1024 bytes take a
linear greedy fallback; needle length is capped so the maximum possible
score fits `ushort` (~3,639 bytes at default constants — an error outcome,
not an assert). Complexity: `O(needleLen × window/width)` vector-shaped
steps on the prefilter-trimmed window, hard-bounded by the stride; the
prefilter is `O(window)`.

Every outcome is explicit (invariant 4):

```d
enum MatchKind : ubyte
{
    matched,          // scored by the full kernel
    matchedGreedy,    // haystack > 1024 bytes: linear fallback scored it
    rejected,         // prefilter: no alignment within the typo budget
    needleTooLong,    // needle exceeds the score-width cap
}

struct MatchOutcome { MatchKind kind; ushort score; ushort endCol; }
```

`matchedGreedy` replaces frizbee's silent `score = 0`; hosts may rank such
candidates last or surface the degradation, but the library never conflates
"long path" with "no match".

### 4.4 Match positions

**(target — M4)**

Two tiers, and — the spec decision fixing the fff/frizbee divergence — **one
verification rule shared by both**:

- **Score tier** (`score`): `MatchOutcome` only. `endCol` (the maximizing
  final-row column, ties resolved leftmost) is included because ranking's
  filename placement needs it cheaply.
- **Positions tier** (`positions`): full traceback into a caller-supplied
  `SmallBuffer` of byte offsets (`PKQ6`), priority Match → Mismatch → Left →
  Up, positions merged into ranges by the caller.

The typo budget is **verified once, on both tiers**: the score tier counts
typos during a single cheap final-row backwalk (bounded by the window) so
that `score` and `positions` accept exactly the same candidate set. fff
ships the divergence (`match_list` never verifies; `match_list_indices`
rejects) — a documented safe-but-incorrect outcome this port does not
reproduce.

Positions are byte offsets into the candidate. Candidates are matched as
UTF-8 bytes (the fff model — no transcode, no normalization); hosts that
render cells convert byte offsets through `sparkles:base`'s segmentation.
A nucleo-style pre-segmented grapheme-proxy tier is recorded as future work
in [PLAN.md](./PLAN.md), not a v1 obligation — hue's corpus is file paths.

## 5. Ranking

**(target — M5)**

fff's composite formula (`PKR1`), ported with its constants, over the
matcher's base score. All inputs arrive in a caller-built context — the
library reads no git state, no clock, no filesystem:

```d
struct RankContext
{
    const(char)[] currentFile;      // relative path; empty = none
    int frecencyScore;              // §6, 0 when absent
    bool gitModified;
    int comboOpenCount;             // §6.3, 0 when absent
    int comboMultiplier = 100;
    int minComboCount = 3;
}
```

```text
total = base                                       (matcher score)
      + base · frecencyScore / 100                 (+1 % per point, PKR2 feeds this)
      + base · 15 / 100                            when gitModified
      + distancePenalty                            0 … −20, path-depth walk vs currentFile
      + filenameBonus                              ladder below
      − base / 4                                   when the candidate IS currentFile
      + comboBoost                                 §6.3 (PKR3)
      + pathAlignmentBonus                         only when the query contains a separator:
                                                   common case-insensitive suffix > 10 bytes
                                                   covering ≥ 30 % of the needle ⇒ base · coverage%
```

Filename ladder (placement via `endCol`, `matchStart ≈ endCol − needleLen + 1`):
exact filename (case-insensitive, equal lengths) ⇒ `base/5·2` (40 %); fuzzy
match landing in the filename ⇒ `min(base/6, 30)`, quality-scaled on the
fallback pass; an entry-point filename (`mod.rs`, `index.ts`,
`__init__.py`, `main.go`, `app.d`, …) ⇒ `base·5 %`.

Every result carries the breakdown **by value** (`PKR4`):

```d
struct ScoreBreakdown
{
    int total, base, filenameBonus, frecencyBoost, gitStatusBoost,
        distancePenalty, currentFilePenalty, comboBoost, pathAlignmentBonus;
    MatchKind matchKind;
}
```

**Top-K** is partial selection, not a full sort: when
`offset + limit < matched/2`, select the boundary
(`topN`-style, Hoare partition over `(score, tieBreak)`), then sort only the
page. Tie-break order is **total** and normative: score descending, then
caller-supplied recency key descending, then candidate index ascending —
so equal-score results are stable across runs and machines.

## 6. Frecency and query history

**(target — M6)**

In-memory models only — `@nogc`, pure over explicit `now` parameters.
Persistence is **out of scope** (`PKR5`/`PKR6`): hue's config layer owns the
state directory and the load/save I/O under its documented startup/shutdown
GC carve-out; this library defines the table types and their update/read
functions.

### 6.1 Access frecency (`PKR2`)

Per file: a chronological buffer of access timestamps, ≤ 128 stamps, 30-day
retention enforced on insert. Score = `Σ exp(−λ · daysAgo)` over the window,
`λ = ln 2 / 10` (10-day half-life), newest-first with early exit, then a
soft knee: linear to 10, `10 + sqrt(excess)` above (practical max ≈ 21). A
fast profile (`λ = ln 2 / 3`, 7-day window) is selectable per read for
burst-style usage. snacks.picker's deadline-timestamp encoding
(store `now + ln(s)/λ`, no rewrite pass) is recorded as the
considered-and-declined alternative: a single scalar per path cannot feed
the per-stamp window, the profile switch, or honest retention.

### 6.2 Modification recency

Gated on `gitModified`; piecewise-linear points over
`(16, 2 min) (8, 15 min) (4, 1 h) (2, 1 d) (1, 1 w)`, zero past a week.
Both scores enter ranking as +1 % of base per point via
`RankContext.frecencyScore`.

### 6.3 Query→file combo boost (`PKR3`)

Keyed by `(project, query)` → exactly one `(file, openCount, lastOpened)`
entry: re-opening the same file increments the count; a different file
replaces the entry. Boost: `openCount ≥ minComboCount` ⇒
`openCount × comboMultiplier`; below ⇒ `openCount × 5`. One table read per
search (never per candidate). Unlike fff's unbounded LMDB store, the
in-memory table is **bounded** (LRU over entries; cap host-configured) so
the host's persisted snapshot cannot grow without limit.

## 7. Glob matching

**(target — M1, with `query.d`)**

A backtracking matcher over spans — `*` (within a segment), `**` (across
segments), `?`, `[…]`/`[!…]` classes, `{a,b}` alternation — iterative
two-pointer backtracking (no recursion, no allocation), case-sensitivity a
parameter. Complexity documented as O(pattern × path) worst case with the
standard single-star linear fast path. Extension constraints compile to a
suffix test, not a glob.

## 8. Incremental search support

**(target — M7)**

What the library provides for a host's tick/generation loop — the loop
itself (threads, pools, frames) lives in the application; hue's is specified
in [picker.md](../hue/picker.md) `PIK4`–`PIK8`.

> [!NOTE]
> **Provenance honesty:** fff's fuzzy path has no budget, abort, or cursor —
> those exist only in its grep engine (poll every Nth item; honor abort only
> after ≥ 2 matches). This section is therefore new design informed by that
> shape and by the nucleo/snacks host contracts, not a port.

- **Refinement probe.** `Query.refines(in Query prev)` — true when this
  query extends `prev` such that the match set can only shrink (every fuzzy
  part extended or equal, constraints unchanged, and — the guard both
  nucleo and snacks converged on — **no trailing negated constraint**).
  Hosts use it to rescore only previous survivors on append instead of the
  full corpus.
- **Budgeted batch driver.** One page of work over a caller-supplied
  candidate range into a caller-owned sink:

  ```d
  struct SearchOptions
  {
      size_t offset;                  // resume cursor
      size_t pageLimit;               // max results to emit
      size_t probeEvery = 64;         // cancellation-check granularity
      const(shared bool)* abort;      // null = never
  }
  struct SearchStatus { size_t nextOffset; size_t matched; bool exhausted; }
  ```

  The driver scores candidates `offset..`, probing `*abort` every
  `probeEvery` items, and returns partial results with a resume cursor —
  `@safe nothrow @nogc`, the one sanctioned impurity (invariant 1). Time
  budgets are the host's concern: it sizes pages and checks its own clock
  between calls, so the library stays clock-free and deterministic.

- **Positions at render time.** Following both surveyed hosts, positions are
  _not_ emitted by the batch driver; hosts call the positions tier (§4.4)
  per visible row.

## 9. Performance contract

**(target — M0 scaffolding; gates per milestone in [PLAN.md](./PLAN.md))**

Performance-test-driven: the bench harness and corpora land **before** the
first kernel (M0), every performance-critical component ships `@benchmark`
coverage in the same milestone as its code (`PKM4`), and findings accumulate
in a committed `bench-baseline.md` modeled on
[wired's](../wired/bench-baseline.md).

### 9.1 Harness

`sparkles:test-runner` `--bench --perf`: `benchIter` for the ns-scale
kernels, `benchCase` matrices per corpus × engine (varying state captured by
value — registration is deferred), `blackBox` on inputs and results,
`--bench-json` snapshots committed under `bench/matcher/results/`.
Cross-run comparisons anchor on **retired instructions**; wall-clock ratios
are read within one snapshot only. The `bench` build type follows the repo
recipe (`unittests releaseMode optimize inline` + `-mcpu=native -O3
-allinst` on LDC).

### 9.2 Corpora

Committed or deterministically generated — no network, no host variance:

- **`sparkles`** — this repository's tracked-file list (small, real,
  committed as a fixture).
- **`synth-deep` / `synth-wide`** — a seeded generator (D single-file tool)
  producing nixpkgs-scale path corpora (~100 k paths) matching measured
  depth/length distributions; byte-identical across runs by construction.
- **Adversarial** — long paths (> 1024 bytes, the greedy cliff), high
  match-density needles, worst-case backtracking globs, typo-heavy queries.

Every benchmark row states its **API tier** (score-only vs positions;
matcher reused) and the corpus **selectivity** as a percentage — the two
omissions the [benchmark-methodology
record](../../research/fuzzy-matching/comparison.md) shows invalidate most
published comparisons.

### 9.3 Reference engines and targets

- **telescope-fzf-native** (C, single file) builds into the bench harness
  via ImportC as the in-process fzf-algorithm proxy, ASCII corpora only.
  **Exit gate (M3):** the scalar D kernel meets or beats it on score-only
  throughput at equal-or-better ranking quality on the golden corpus.
- **fzf** baseline out-of-process via its shipped
  `--filter <q> --bench 10s --threads 1` (documented procedure; reference
  point: 139 ms / 1.4 M paths / 12.79 % selectivity, single-threaded).
- **Published anchors** for orientation, not gates: nucleo-matcher
  ≈ 78 ns/candidate (95 k × 37-char corpus, 2018 laptop); frizbee
  ≈ 16 ns/candidate sequential SIMD (1.4 M × 67-char, Zen 5). The scalar
  target sits between them; SIMD backends are a measured follow-up, and the
  layout (§4.3) is vectorization-ready from day one.

### 9.4 Quality gates

Wall-clock is necessary, not sufficient (`safety composes; correctness does
not`): a **golden ranking corpus** — fixed paths, queries, and expected
orderings, including every worked example in the research catalog (the
`xf foo` optimality case, camel/snake balance, typo cases) — is a normal
unittest from M3 on, so a "faster" kernel that ranks worse fails CI, not
review.

## 10. Public API surface

**(target — accumulates M1–M7)**

| Area      | Symbols                                                                                               |
| --------- | ----------------------------------------------------------------------------------------------------- |
| Query     | `Query`, `Constraint`, `ConstraintKind`, `GitStatusFilter`, `Location`, `parseQuery`, `Query.refines` |
| Matching  | `Scoring`, `MatchConfig`, `Matcher`, `MatchOutcome`, `MatchKind`                                      |
| Positions | `Matcher.positions` (caller-buffer sink)                                                              |
| Ranking   | `RankContext`, `ScoreBreakdown`, `rank`, `selectTopK`                                                 |
| Frecency  | `FrecencyTable`, `accessScore`, `modificationScore`, `ComboTable`, `comboBoost`                       |
| Glob      | `globMatch`                                                                                           |
| Search    | `SearchOptions`, `SearchStatus`, `searchPage`                                                         |

**Attribute policy (normative).** Every public symbol is
`@safe pure nothrow @nogc`, with exactly one exception: `searchPage` is
`@safe nothrow @nogc` (impure — it reads the caller's shared abort flag).
Templated entry points (sinks, resolvers) let attributes infer, per the repo
guideline; no public symbol is `@trusted`, and internal `@trusted` blocks
wrap single operations only.

**Memory management (normative).** All owned state lives in `SmallBuffer`
(matcher matrices `unique`, result sets CoW). Every input is borrowed
(`scope`/`in`); every output is a value or lands in a caller-supplied
buffer; `dip1000` enforces the borrows. Construction is the only allocation
site per object; per-candidate and per-keystroke paths allocate nothing.

**Contracts (normative).** `parseQuery` is the wide boundary; everything
downstream carries expression-based `in`-contracts (DIP1009) asserting
validity — live in `checked` builds, so violations surface in shipped
artifacts too.
