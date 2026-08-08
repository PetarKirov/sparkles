# `sparkles:fuzzy` — Delivery Plan

_The milestoned companion to [SPEC.md](./SPEC.md). Each milestone is one
reviewable unit — code, tests, and its benchmark gate land together
(performance-test-driven: no kernel merges without its measurement). The
whole plan is hue's picker milestone `F0`
([picker.md](../hue/picker.md) `PKM1`–`PKM5`, `PKQ1`–`PKQ6`, `PKR1`–`PKR3`);
`P0`+ (the picker itself) starts once M3 ships a usable score tier._

## Design invariants (fixed before M0)

1. `@safe pure nothrow @nogc` everywhere; `searchPage`'s abort probe is the
   single sanctioned impurity (SPEC §1).
2. Borrowed spans in, values or caller buffers out; `SmallBuffer` is the
   only container.
3. Explicit outcomes — `MatchKind` names every degradation; no silent zeros.
4. The scalar kernel keeps the log-shift propagation shape so SIMD backends
   are drop-in and parity-testable.
5. Benchmarks state API tier and corpus selectivity; snapshots anchor on
   retired instructions.

## Milestone order

M0 (harness) → M1 (query + glob) → M2 (prefilter) → M3 (kernel, score tier)
→ M4 (positions) → M5 (ranking) → M6 (frecency) → M7 (search driver + docs).
M1 is independent of M2–M4 and may proceed in parallel; everything else is
sequential by data dependency.

## M0 — scaffold and measurement floor

The harness before the first kernel:

- `libs/fuzzy/` package: `dub.sdl` (library + unittest configs per the
  `libs/diff` recipe, `bench` build type), root `dub.sdl` registration,
  `AGENTS.md` table row, nix fileset registration. New files staged before
  any flake-based check.
- `bench/matcher/` package: corpora (the committed `sparkles` listing; the
  seeded `synth-deep`/`synth-wide` generator as a D single-file tool;
  adversarial cases), the **telescope-fzf-native ImportC shim** (single C
  file; the in-process fzf-algorithm reference), `benchCase` matrix over
  corpus × engine.
- First committed `--bench-json` snapshot: the C reference's numbers on this
  hardware — the floor every later gate compares against.

**Gate:** harness runs green in CI; baseline snapshot committed;
`bench-baseline.md` opened with the environment table.

## M1 — query language + glob (SPEC §3, §7)

`query.d` (shape-dispatch grammar, `ParseExpected!Query`, borrowed spans,
`Query` regularity + `opEquals`) and `glob.d` (iterative backtracking
matcher). Tests: grammar cases ported from fff's parser doctests
(`git:modified`, `!*.rs`, `**/*.rs`, `f.d:12:4`, `\*`-escapes, the
lone-path-stays-text rule), the two fixed-bug cases (`status:` empty ⇒
error; `type:` ⇒ error), glob torture set. `@benchmark`: queries/s on a
mixed corpus; glob worst-case row. Satisfies `PKQ1`–`PKQ4` (parser side).

**Gate:** parser allocates nothing (attribute-gated tests); grammar table in
SPEC §3.1 fully covered by tests.

## M2 — subsequence prefilter (SPEC §4.1)

`prefilter.d`: 0/1/2-typo lockstep kernels + generic multi-path, window
trimming, case-pair folding. The LCS oracle as a randomized differential
test (normative contract). `@benchmark`: reject throughput (bytes/s and
candidates/s) on non-matching corpora at 0/1/2 typos; window-trim
effectiveness column.

**Gate:** oracle holds over the fuzzed corpus; 0-typo cost within noise of a
plain subsequence scan.

## M3 — scoring kernel, score tier (SPEC §4.2–4.3)

`score.d`: `Scoring`, `Matcher` (matrices in `unique` `SmallBuffer`s,
never re-zeroed), the substitution SW kernel in log-shift shape, greedy
fallback, `MatchOutcome`/`MatchKind`, `endCol`, score-tier typo
verification. The **golden ranking corpus** lands here and gates every later
change. `@benchmark`: score-only ns/candidate per corpus (matcher reused),
`--perf` instruction counts.

**Gate (the M3 exit gate):** meets or beats telescope-fzf-native on
score-only throughput on ASCII corpora at equal-or-better golden-corpus
ranking; all differential/oracle tests green.

## M4 — positions tier (SPEC §4.4)

Traceback into caller buffers; the shared verification rule (score and
positions accept identical sets — the fff/frizbee divergence fixed);
position-merge helpers. Differential test: every `matched` candidate's
positions re-score to its reported score. `@benchmark`: positions
ns/candidate; the tier-cost ratio documented (the API-tier trap made
measurable).

## M5 — ranking (SPEC §5)

`rank.d`: composite formula, filename ladder, `ScoreBreakdown` by value,
`selectTopK` partial selection with the normative tie-break. Golden corpus
extended with ranking-context cases (frecency/git/distance/combo
interactions). `@benchmark`: rank+select over 100 k scored candidates.
Satisfies `PKR1`, `PKR4` (library side).

## M6 — frecency + combo (SPEC §6)

`frecency.d`: access curve (soft knee), modification curve, fast profile,
bounded `ComboTable`. Pure over explicit `now` — property tests pin the
half-life and retention arithmetic. Satisfies `PKR2`, `PKR3` (in-memory
side; persistence stays in hue per `PKR5`/`PKR6`).

## M7 — search driver, refinement, docs

`search.d`: `searchPage` (cursor, abort probe, partial results),
`Query.refines` with the trailing-negation guard. `@workload` row: one full
page query over `synth-deep` with cache-regime control. Ships the
`docs/libs/fuzzy/` Diátaxis tree (`PKM5`) and the consolidated
`bench-baseline.md` findings.

**Gate:** `nix run .#ci -- --test` green across the repo; hue's `P0` can
consume the library without patches.

## Deferred, recorded so they are not re-derived

- **SIMD backends** (SSE/AVX2/NEON behind the parity seam) — after M7, only
  with M3-style measurements per backend; intra-sequence row-wise only
  (inter-sequence bucketing is the documented dead end).
- **Grapheme-proxy pre-segmentation tier** (nucleo's model) — when a
  consumer needs grapheme-stable positions beyond byte offsets.
- **Bigram content index** (`PKM6`) — grep-source scale only; it is a
  content index, not a path prefilter (the catalog corrects the earlier
  assumption).
- **`type:` constraint semantics** — reserved as a parse error until a real
  extension-mapping design exists.

## Verification

Per milestone: `dub test :fuzzy` (attribute-gated), the differential/oracle
suites, `dub test :fuzzy -b bench -- --bench --perf` with a committed
snapshot when a gate is claimed, and `nix run .#ci -- --test --fail-fast`
repo-wide before merge. Docs changes keep `npm run docs:build` and
`nix run .#ci -- --check-docs-sidebar` green.
