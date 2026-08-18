# `sparkles:fuzzy` benchmark baseline

_Recorded 2026-08-14 from the F0 working tree based on `e0df6b19`._

This is the first lifecycle-aware local baseline, not a portable performance
claim. Run it with:

```console
dub test :fuzzy -b bench -- --bench
```

The benchmark build uses release mode, optimization, inlining, `-O3`, and
`-mcpu=native`. This run used LDC 1.41.0 (DMD 2.111.0, LLVM 18.1.8), Linux
6.18.26, and an AMD Ryzen 9 7940HX. Frequency scaling and normal workstation
noise were enabled.

| Benchmark                      | Construction boundary                                     | Median |
| ------------------------------ | --------------------------------------------------------- | -----: |
| parse + analyze + glob compile | included; interactive code-path query                     | 3.5 µs |
| glob execution                 | compiled program excluded; one path                       | 2.7 µs |
| match score + positions        | parsed query/workspace construction excluded; one path    | 3.8 µs |
| top-K generation               | reset included; 64 offers, 20 retained/paged              | 1.2 µs |
| one-candidate generation       | parse, accumulator reset, search, rank, and page included | 6.1 µs |

Each row alternates an input or iteration order at runtime and asserts a valid
result, preventing the optimizer from timing only a constant validation path.
The benchmark metadata printed by the runner records `profile`, `tier`,
`corpus`, and `construction` for comparisons.

## Comparison policy

Store future snapshots with compiler, CPU, ISA, build flags, corpus identity,
and sample distribution. A designated-runner regression is actionable only
when it exceeds 5% and a 95% confidence interval excludes zero for wall time,
retired instructions, or cache misses. A `-mcpu=native` snapshot never gates a
different ISA.

An fzf-algorithm C comparison is informational and valid only for the shared
ASCII, `maxTypos = 0`, score-only workload with equal construction and output
work. Ranking-quality gates remain exact D-side admitted sets, scores,
positions, pages, and generation state transitions; different acceptance
semantics cannot be called equal work.
