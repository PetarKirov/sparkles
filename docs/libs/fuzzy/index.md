# `sparkles:fuzzy`

`sparkles:fuzzy` is the bounded compute core for interactive file and symbol
pickers. It parses a query into fuzzy terms and metadata constraints, analyzes
Unicode text with source-byte provenance, admits typo-tolerant matches through
an exact witness, ranks them deterministically, and advances immutable corpora
in clock-free chunks.

The library does not read files, clocks, git state, cancellation flags, or an
event loop. Callers provide fixed workspaces and concrete metadata; hue owns
snapshots, scheduling, persistence, and presentation.

## Documentation

- [Tutorial: build a small file search](./tutorial/getting-started.md)
- [How-to: run a chunked, paginated search](./how-to/chunked-search.md)
- [Reference: public API and capacities](./reference/api.md)
- [Explanation: admission, scoring, and ownership](./explanation/design.md)
- [Benchmark baseline and methodology](../../specs/fuzzy/benchmarks.md)

The [specification](../../specs/fuzzy/SPEC.md) is normative and the
[delivery plan](../../specs/fuzzy/PLAN.md) records its verification gates.
