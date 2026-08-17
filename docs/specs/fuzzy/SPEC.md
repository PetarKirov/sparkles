# `sparkles:fuzzy` — Specification

_**Status:** F0 implemented and verified · **Date:** 2026-08-17_

_Normative at the contract level. Delivery order and gates live in
[PLAN.md](./PLAN.md); hue's host-side lifecycle is specified in
[picker.md](../hue/picker.md). The evidence base is the
[fuzzy-matching research catalog](../../research/fuzzy-matching/index.md)._

## 1. Purpose and invariants

`sparkles:fuzzy` is the allocation-free compute core behind interactive
candidate pickers: it analyzes query and candidate text, parses constraints,
performs typo-tolerant fuzzy admission and scoring, ranks matches, keeps bounded
history models, and advances searches in deterministic chunks.

The library depends only on `sparkles:base` and `expected`. It reads no clock,
filesystem, git repository, global cancellation flag, or event loop.

The following invariants are normative:

1. All shipped fuzzy entry points and both built-in text profiles are
   `@safe pure nothrow @nogc`. The underlying public base analyzer carries the
   same attributes; the fuzzy package does not invoke a caller callback.
2. A hot operation performs no allocation of any kind. Storage comes from
   fixed-capacity, caller-owned workspaces; `@nogc` is necessary but is not used
   as proof of allocation freedom.
3. Input text is borrowed. Output is a value or is written to caller-owned
   storage. A query or corpus snapshot must outlive every operation borrowing
   it.
4. Every public value is either valid by construction or validated by an
   operation returning an explicit error. Public assertions do not reject
   caller-controlled data.
5. Admission and highlighting have one exact authority: the canonical bounded
   needle-deletion witness. Smith-Waterman contributes ranking quality only.
6. Every ordering is total and independent of enumeration order, hash seeds,
   worker scheduling, floating-point behavior, and implicit time.
7. Compile-time capacities are hard bounds. Runtime limits may reduce, never
   exceed, them. No input is truncated silently.

## 2. Text model and capacities

### 2.1 Analyzed units

Matching operates on `TextUnit`, not UTF-8 bytes:

```d
struct TextUnit
{
    uint value;          // Unicode scalar, or opaqueByteBase + original byte
    uint sourceStart;    // inclusive byte offset in the borrowed source
    uint sourceEnd;      // exclusive byte offset
    TextUnitFlags flags; // source case, word start, or opaque byte
}
```

Normalization expansions share their source byte interval. Composition uses
the union of all contributing intervals. Removed marks and stopwords emit no
unit. Each malformed UTF-8 byte emits one distinct opaque unit; opaque units
never case-fold or combine with Unicode scalars.

`sparkles.base.text.analysis` supplies streaming decomposition, canonical-order
sorting, composition, simple and full case folding, mark classification, and
word segmentation over caller-owned storage. A normalization segment longer
than its workspace returns `segmentTooLong`.

### 2.2 Profiles

The first release ships two immutable profile values:

- `codePath`: NFC, symbols preserved, no accent or stopword removal, smart
  case. A lowercase-only cased query uses Unicode simple folding; a query with
  an uppercase cased scalar compares case-sensitively. Candidate analysis uses
  the mode chosen by the query.
- `generalLanguage`: NFKC, Unicode full case fold, accent-mark removal, Unicode
  word segmentation, and an optional immutable caller-provided stopword
  lexicon. The default lexicon is empty.

The base analysis API is public so later packages can produce locale-aware ICU
or CJK/bigram indexes before entering the fuzzy core. Those adapters are not
dependencies of `sparkles:fuzzy`, and no purity claim is made for them.

### 2.3 Compile-time and runtime bounds

`DefaultFuzzyCaps` is the compile-time template value used by the default
instantiation. Callers may provide a compatible capacity type:

| Capacity                       | Default |
| ------------------------------ | ------: |
| analyzed query units           |     256 |
| query source bytes             |   4,096 |
| analyzed candidate units       |   4,096 |
| candidate source bytes         |   4,096 |
| Smith-Waterman candidate units |   1,024 |
| fuzzy parts                    |       8 |
| constraints                    |      16 |
| glob instructions              |     512 |
| glob class ranges              |     128 |
| returned position ranges       |     256 |

`FuzzyLimits` is validated once and may lower these capacities. Emitting more
analyzed units than a limit returns `queryTooComplex` or
`candidateTooComplex`; a source exceeding the byte limit returns
`candidateTooLong`. The default values are tuning parameters: changing them
requires a benchmark record and a specification change.

Default `QueryStorage` and `ConstraintWorkspace` values each carry a
compile-time 128 KiB ceiling; `MatcherWorkspace` carries a one-MiB ceiling.
Static assertions make a capacity/layout change that crosses those budgets a
build failure. Value construction itself allocates nothing and therefore has
no hidden allocation-failure outcome; callers choose where those regular
values live.

## 3. Query language

### 3.1 Lexing and escaping

ASCII whitespace separates tokens outside double quotes. Quotes may occur
within a token. Backslash quotes the following byte both inside and outside a
quoted region; `\\`, `\"`, `\ `, and `\*` therefore decode to one literal
byte. A trailing backslash or unclosed quote is an error. Query text stores a
borrowed raw span plus a decoding cursor, so unescaping does not allocate.

After lexical decoding, each token uses the first matching rule:

| Form                                             | Meaning                                                       |
| ------------------------------------------------ | ------------------------------------------------------------- |
| `ext:V`                                          | extension constraint                                          |
| `path:V`                                         | whole-path suffix constraint, beginning on a segment boundary |
| `seg:V`                                          | path-segment constraint                                       |
| `glob:V`                                         | compiled glob constraint                                      |
| `git:V`, `status:V`, `st:V`, `g:V`               | git-status constraint                                         |
| `*.V` with no glob metacharacter in `V`          | legacy extension constraint                                   |
| leading or trailing unescaped separator          | legacy segment constraint                                     |
| token containing an unescaped glob metacharacter | legacy glob constraint                                        |
| everything else                                  | fuzzy part                                                    |

An initial unescaped `!` negates a constraint after redispatch. It does not
negate ordinary fuzzy text; `!!foo` is fuzzy text. `type:` is reserved and is
always an error.

Git values are `modified`, `untracked`, `staged`, `ignored`, and `clean`.
Case-insensitive unique non-empty prefixes are accepted; ambiguous or empty
values are errors. A candidate may carry multiple status bits.

The final fuzzy token may end in `:line`, `:line:column`,
`:l1:c1-l2:c2`, or `(line,column)`. Decimal overflow is an error. A Windows
drive colon is never a location separator. A single path-shaped fuzzy token
remains fuzzy unless it has an explicit prefix or legacy leading/trailing
separator.

### 3.2 Semantics

- Positive extension constraints form one OR bucket.
- Every negated extension is an independent exclusion.
- Every other constraint is ANDed, with source-order short-circuiting.
- Every fuzzy part of at least two analyzed units is required independently;
  the candidate order of the parts is unrestricted.
- A shorter part is ignored and counted in `QueryDiagnostics.droppedParts`.
- An empty or constraint-only query admits every constraint-satisfying
  candidate and uses history-only ranking.
- `path:` and segment matching use the selected `PathFlavor`; Unix and Windows
  separators are not guessed from the host platform.

`QueryStorage!(Caps)` owns fixed arrays of parsed descriptors and one flattened
compiled-glob arena; its text spans borrow the original query bytes.
`QueryView` is the read-only API name for that regular by-value storage.
Parsing returns `FuzzyExpected!(QueryStorage!Caps)`. A malformed or
combined-arena-overflowing glob is rejected during parse, never recompiled per
candidate or deferred until evaluation.

`CandidateView` contains a stable 128-bit `CandidateId`, borrowed path,
validated filename byte offset, `PathFlavor`, git-status bits, and a caller
supplied recency key. Constraint evaluation returns
`FuzzyExpected!bool` and never asks a callback for metadata.
IDs are unique within one candidate snapshot and remain stable when discovery
or worker order changes.

Query-language extension, segment, and suffix constraints compare ASCII
letters case-insensitively, treat non-ASCII bytes exactly, and equate `/` with
`\` only for Windows paths. Query globs normalize Unicode with the code-path
profile and use Unicode simple folding. Public `compileGlob` additionally lets
the caller request case-sensitive matching.

## 4. Exact admission and positions

### 4.1 Typo model

Typos are needle-side deletions. For a part with `n >= 2` analyzed units, the
derived budget is:

```text
min(configuredMaximum, n - 1, max(1, floor(n / 4)))
```

An explicitly configured zero remains zero. A part is admitted exactly when
`LCS(part, candidate) + budget >= n`.

### 4.2 Cursor DP

The implementation maintains `budget + 1` prefix cursors. For each candidate
unit it:

1. snapshots all cursors;
2. closes needle-deletion transitions from lower to higher budgets;
3. advances a cursor at most once on the candidate unit when its next needle
   unit matches; and
4. retains the farthest prefix for dominated states.

The optimized algorithm must be differential-tested against a conventional
LCS table. Its actual complexity is `O(candidateUnits * (budget + 1))`, plus
text analysis. No complexity claim may replace `candidateUnits` with the
smaller returned scoring window.

### 4.3 Canonical witness

An admitted part has one canonical witness, ordered by:

1. fewest needle deletions;
2. earliest final candidate unit; and
3. lexicographically earliest candidate source-byte positions.

The cursor pass records one bounded predecessor per candidate/budget state;
a backward reconstruction produces the witness. It supplies the
scoring window, first/end positions, filename containment, and highlights.
Endpoint deletions therefore cannot create a reversed or non-conservative
window.

`positions` reruns the exact witness pass and emits sorted byte ranges. Ranges
that overlap or touch are merged. If caller storage is too small it returns
`outputFull` and the required count; it never emits a partial success.

Multiple-part admission ANDs the parts. Their score is the floor of the
arithmetic mean of part scores; their positions are the sorted union of
canonical witness ranges.

## 5. Ranking score

### 5.1 Matcher workspace and arithmetic

`MatcherWorkspace!(Caps)` is caller-owned and exclusive to one invocation at a
time. Independent workers use independent workspaces. It stores analyzed
units, cursor/predecessor state, and fixed rolling score rows; it stores no
full score matrix and no match-mask matrix.

Every candidate reinitializes structural row/column zero. No recurrence reads
outside the active row range. Score cells are `uint`; recurrence and rank
intermediates are signed 64-bit. `validateScoring` proves the configured
worst-case score fits before matching.

### 5.2 Smith-Waterman tier

Candidates within `maxDpUnits` use affine-gap Smith-Waterman with substitution
over the canonical witness window. Smith-Waterman cannot change admission.
Default constants are:

```text
match 12; mismatch 6; gap-open 5; gap-extend 1; prefix 12;
delimiter 4; camel boundary 8; matching case 4; exact 8
```

Delimiter and camel boundaries are recognized for every query. Matching-case
points depend on original-case equality. Smart-case affects equality, not
whether a camel boundary exists. Ties choose the earliest ending unit.

Candidates above `maxDpUnits` use `matchedFallback`: the canonical witness is
scored directly with the same match, boundary, case, and affine-gap constants.
It has exact positions represented as `size_t` byte offsets within the
validated source-byte capacity. Every admitted
fuzzy match has a positive base score.

`MatchOutcome` distinguishes `matched`, `matchedFallback`, `rejected`, and
`noFuzzyTerms`; the surrounding `FuzzyExpected` carries every capacity or
configuration error. An error or fallback is never represented by a zero
score.

## 6. Composite ranking and top-K

All percentage terms multiply before division, use signed 64-bit values, and
round toward zero:

```text
total = base
      + base * frecencyPoints / 100
      + base * 15 / 100                         when git-modified
      + directoryDistance                       clamped to [-20, 0]
      + filenameBonus
      - base * 25 / 100                         when current file
      + comboBoost
      + pathAlignmentBonus
```

Filename bonus is the first applicable item:

- analyzed filename equals the query: `base * 40 / 100`;
- every witness range is in the filename: `min(base * 40 / 100, 30)`;
- filename is one of `mod.rs`, `index.ts`, `index.js`, `__init__.py`,
  `main.go`, `main.rs`, `main.c`, `main.cpp`, or `app.d`: `base * 5 / 100`.

Path alignment applies only to a query containing a separator. It is
`base * commonSuffixUnits / queryPathUnits` when the analyzed common suffix is
longer than ten units and covers at least 30% of the query. Directory distance
is candidate-directory depth plus current-directory depth minus twice their
common-prefix depth, negated and clamped; `directoryDistance` implements that
calculation, including Windows separator and ASCII case behavior.

For an empty or constraint-only query, `base`-scaled terms are replaced by
`accessPoints + modificationPoints + comboBoost`.

Each result contains a by-value `ScoreBreakdown` naming every term and the
`MatchKind`. The total order is:

1. total descending;
2. recency key descending; and
3. `CandidateId` ascending.

`TopK!(Capacity)` is a min-heap retaining checked `offset + limit` best
results in `O(N log K)`. Finalization deterministically insertion-sorts the
bounded retained prefix in `O(K²)` and returns the requested page. Overflow or
capacity excess is an explicit error. Partial searches keep one heap per generation and publish a
monotonic accumulator revision; visible rows are the globally best rows among
all candidates examined so far. Revision exhaustion is an explicit arithmetic
error rather than an unchecked wrap.

## 7. Bounded history models

History keys are caller-supplied stable IDs, never borrowed strings.

`FrecencyTable!(MaxFiles, MaxStamps = 128)` maintains stamps newest-first,
accepts out-of-order inserts, clamps future ages to zero, prunes expired data,
and deterministically evicts the least-recently-used file with `CandidateId` as
the tie-break. The default file capacity is 4,096.

Access decay uses a committed Q16 hourly lookup/interpolation table and integer
square root, not `libm`. Profiles are ten-day half-life/30-day retention and
three-day half-life/seven-day retention. The soft knee is linear through ten,
then `10 + floor(sqrt(excess))`. APIs accepting a profile return
`FuzzyExpected`; an invalid public enum value is an explicit
`invalidConfiguration` error.

Modification points linearly interpolate the knots `(16, 2 minutes)`,
`(8, 15 minutes)`, `(4, 1 hour)`, `(2, 1 day)`, `(1, 1 week)`, then zero.

`ComboTable!(MaxEntries)` maps `(ProjectId, QueryId)` to one
`(CandidateId, openCount, lastOpened)` value. Reopening increments a saturating
counter; a different candidate replaces it. Full tables use deterministic LRU
eviction. The default capacity is 1,024. Boost is `count * 5` below
`minComboCount`, otherwise `count * comboMultiplier`, with validated bounds.

Persistence is a hue responsibility. The serialized format is versioned and
size-bounded, encodes arbitrary path/query bytes, resolves fresh runtime IDs on
load, ignores malformed or missing entries, and is replaced atomically.

## 8. Glob automaton

Globs compile once into a bounded Thompson NFA. Supported syntax is `*` within a
segment, `**` across segments, `?`, positive/negative classes, and brace
alternation. Empty alternatives, unclosed constructs, invalid ranges, and a
program or combined query arena exceeding the instruction/range limits is a
parse error. Query escaping is preserved into glob compilation, so `\*` is a
literal asterisk.

Matching uses two fixed state bitsets and costs
`O(programInstructions * pathUnits)` in the worst case. It neither recurses nor
expands brace products. Case and path-separator behavior come from the selected
profile and `PathFlavor`.

## 9. Incremental search

`searchChunk` is pure and clock-free. A call is bounded by both
`maxCandidates` and `maxAnalyzedUnits`, writes through a concrete fixed-capacity
accumulator, and returns `exhausted` or `workLimit`; invalid configuration,
capacity, arithmetic, and cursor conditions are explicit errors.

`SearchCursor` contains corpus snapshot ID, query generation, next corpus
offset, sink epoch, and accumulator revision. A mismatched or out-of-range
cursor is rejected. A candidate snapshot and query arena remain immutable and
pinned until all operations borrowing them finish.

`QueryView.refines(previous)` is a conservative signal: it is true only when
profile, path flavor, constraints and part count/order are unchanged, every
old ASCII part is an exact prefix of the corresponding new part, and no
effective typo budget increases. A host may rescore a retained survivor set
and then scan the unexamined tail only when that survivor set is complete. A
bounded survivor buffer that overflowed—or a host, such as hue P0, that does
not retain one—must restart from the full corpus. False negatives only cost
work; they never change results.

Clock deadlines, cancellation atomics, worker submission, and stale-result
rejection belong to hue. Hue compares a monotonically increasing generation
between candidate-sized pure calls and uses release publication/acquire reads.

## 10. Public surface

The package module re-exports these areas:

| Area     | Principal symbols                                                                                      |
| -------- | ------------------------------------------------------------------------------------------------------ |
| Analysis | `AnalysisProfile`, `TextUnit`, `AnalysisWorkspace`, `analyzeText`                                      |
| Query    | `QueryStorage`, `QueryView`, `FuzzyError`, `parseQuery`, `CandidateView`, `evaluateConstraints`        |
| Glob     | `GlobProgram`, `GlobProgramView`, `GlobMatchWorkspace`, `compileGlob`, `globMatch`                     |
| Match    | `DefaultFuzzyCaps`, `FuzzyLimits`, `Scoring`, `MatcherWorkspace`, `MatchOutcome`, `match`, `positions` |
| Rank     | `RankContext`, `ScoreBreakdown`, `RankedResult`, `rank`, `TopK`                                        |
| History  | `StableId`, `FrecencyTable`, `ComboTable`, `accessScore`, `modificationScore`                          |
| Search   | `SearchCursor`, `SearchLimits`, `SearchStatus`, `SearchAccumulator`, `searchChunk`                     |

The [API reference](../../libs/fuzzy/reference/api.md) documents ownership,
errors, attributes, complexity, and capacities for these entry points. Public
functions return values or `Expected`-family results; public caller data is
never guarded only by an `in` contract.

## 11. Performance and verification contract

The committed F0 baseline covers parse/analyze/glob compilation,
fresh-generation setup, workspace-reused score/positions, glob execution, and
rank/top-K. Every row states profile, API tier, corpus, and whether construction
is included; the measured rows and exact command live in
[benchmarks.md](./benchmarks.md). Host cancellation latency and a complete
multi-candidate picker frame are host benchmarks, not silently inferred from a
score-only row.

Correctness fixtures include Unicode normalization and malformed UTF-8,
adversarial glob/query inputs, fallback-sized paths, exhaustive short-alphabet
admission/witness oracles, every pagination/permutation of a bounded set, and
generation/refinement protocols. Large-corpus performance runs additionally
identify this repository, deterministic deep/wide corpora, or a real repository
by generator parameters or revision hash; they are performance evidence, not a
substitute for the exact small oracles.

Snapshots are partitioned by compiler, CPU, and ISA. On the designated runner,
a regression above 5% is rejected when a 95% confidence interval excludes zero
for wall time, retired instructions, or cache misses. `-mcpu=native` snapshots
are evidence, not portable truth.

The C fzf-algorithm comparator is used only for equal-work ASCII,
`maxTypos = 0`, score-only measurements and is informational. Correctness gates
assert exact admitted sets, exact score breakdowns, positions, total order, and
state transitions.

Allocation freedom is structural (fixed arrays and no allocator dependency),
compile-time attributed, and checked by the release allocation gate; `@nogc`
alone is not treated as proof.

## 12. Review remediation index

The numbered findings in this directory's `adversarial-review.md` remain the
reproduction record. Their normative resolutions are:

| Findings                     | Resolution sections                                                   |
| ---------------------------- | --------------------------------------------------------------------- |
| 1, 7, 9, 28, 43, 49          | exact admission and canonical witness (§4)                            |
| 2, 3, 17, 33, 38             | refinement, cursor, and generation protocol (§9)                      |
| 4, 10, 12–14, 31, 37, 39, 40 | rolling workspace, wide offsets, fallback, and bounds (§2, §5)        |
| 5, 18, 34, 48                | immutable snapshots and stable bounded IDs (§3, §7, §9)               |
| 6, 11, 29, 32, 35, 36, 41    | complete arithmetic, ranking, and heap selection (§6–§7)              |
| 8, 16, 21, 22, 42            | complete grammar and constraint semantics (§3)                        |
| 15                           | Unicode units and invalid-byte provenance (§2)                        |
| 19, 20                       | bounded pure chunks plus host scheduler (§9; picker `PIK5`–`PIK8`)    |
| 23–27                        | concrete validated APIs and conditional attribute policy (§1–§3, §10) |
| 30                           | bounded NFA glob engine (§8)                                          |
| 44–47                        | lifecycle, portability, equal-work, and corpus gates (§11)            |
| 50–51                        | milestone ownership and gates ([PLAN.md](./PLAN.md))                  |
