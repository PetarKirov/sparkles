# API reference

Import `sparkles.fuzzy` for the complete surface or one feature module.

| Module    | Main symbols                                                                                             |
| --------- | -------------------------------------------------------------------------------------------------------- |
| `common`  | `DefaultFuzzyCaps`, `FuzzyLimits`, stable IDs, `CandidateView`, `FuzzyError`                             |
| `query`   | `QueryStorage`, `QueryText`, `parseQuery`, `refines`, constraints and locations                          |
| `glob`    | `GlobProgram`, `GlobProgramView`, `GlobMatchWorkspace`, `compileGlob`, `compileGlobDecoded`, `globMatch` |
| `match`   | `Scoring`, `MatchConfig`, `MatcherWorkspace`, `MatchOutcome`, `match`, `positions`                       |
| `rank`    | `RankContext`, `ScoreBreakdown`, `RankedResult`, `directoryDistance`, `rank`, `TopK`                     |
| `history` | `accessScore`, `modificationScore`, `FrecencyTable`, `ComboTable`                                        |
| `search`  | `CandidateSnapshot`, `SearchCursor`, `SearchAccumulator`, `searchChunk`                                  |

Default hard capacities are 256 analyzed query units, 4,096 analyzed candidate
units/source bytes, 1,024 score-DP candidate units, eight fuzzy parts, sixteen
constraints, a combined query arena of 512 glob instructions and 128 class
ranges, 256 returned ranges, and six needle deletions. `FuzzyLimits` may lower
these values; exceeding a compile-time or runtime bound is an explicit error
and never truncates input.

Hot entry points are `@safe pure nothrow @nogc`. Storage is embedded in caller
workspaces. Narrow private/package `@trusted` DIP1000 lifetime bridges back the
public `@safe` slice accessors; no query or result owns an input string.
On Linux, `dub test :fuzzy --config=allocation-audit` calibrates linker wraps
for `malloc`, `calloc`, and `realloc`, then verifies zero libc and GC allocation
calls across one complete parse/search/rank/page/history path.

The principal call shapes are:

```d
FuzzyExpected!(QueryStorage!Caps) parseQuery(Caps)(
    return scope const(char)[] source, QueryParseOptions options);

FuzzyExpected!bool evaluateConstraints(Caps)(
    in QueryStorage!Caps query, in CandidateView candidate,
    ref ConstraintWorkspace!Caps workspace, FuzzyLimits limits);

FuzzyExpected!MatchOutcome match(Caps)(
    in QueryStorage!Caps query, in CandidateView candidate,
    MatchConfig config, Scoring scoring, FuzzyLimits limits,
    ref MatcherWorkspace!Caps workspace);

FuzzyExpected!SearchStatus searchChunk(Caps, size_t Capacity)(
    in QueryStorage!Caps query, in CandidateSnapshot snapshot,
    SearchCursor cursor, SearchLimits work, MatchConfig matchConfig,
    Scoring scoring, FuzzyLimits fuzzyLimits,
    ref SearchAccumulator!Capacity accumulator,
    ref MatcherWorkspace!Caps matcher,
    ref ConstraintWorkspace!Caps constraints);
```

`match` costs `O(candidateUnits * (maxTypos + 1))` for exact admission plus
`O(queryUnits * maxDpUnits)` for bounded scoring per effective fuzzy part.
`TopK.offer` is `O(log K)` and `TopK.page` is a deterministic `O(K²)` copy and
insertion sort over the compile-time-bounded retained prefix. Glob execution is
`O(programInstructions * pathUnits)`.

Glob constraints compile during `parseQuery` into the query's fixed arena.
Evaluation borrows a `GlobProgramView`, so a candidate never reparses or
recompiles the pattern.

`positions` reports `outputFull` with the required count in `error.offset` and
does not return partial success. Candidate and cursor validation similarly use
`Expected` values rather than assertions over caller data.

`accessScore`, `FrecencyTable.record`, `score`, and `prune` return
`FuzzyExpected` so even a cast-invalid `AccessDecayProfile` is reported as
`invalidConfiguration`. Candidate path flavor, git-status bits, filename
offset, query profile, scoring values, runtime limits, and pagination overflow
are likewise validated at public boundaries.
