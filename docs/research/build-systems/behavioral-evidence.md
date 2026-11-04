# Build Systems: Behavioral Evidence

Small adversarial builds test whether a research classification predicts an
engine's behavior. The [experiment runner][runner] invokes installed GNU Make
and Ninja on the same two-action graph, records every executed action, and
asserts the resulting artifact bytes. These observations concern the supplied
rules and configurations; they do not establish performance, hermeticity, or
correctness for arbitrary projects.

**Last reviewed:** November 4, 2026

## Experiment design

Each scenario starts in a fresh temporary directory with the graph
`source → generated → final`. The generator takes the first line of `source`
and writes `generated` only when its bytes change. The consumer prefixes those
bytes with `compiled:`. An optional file, deliberately omitted from both
manifests, overrides the generator's input when present. Each worker appends
its action name to a separate execution log.

The Make rules use ordinary file prerequisites. Ninja uses ordinary explicit
inputs with `restat = 1` on the generator. Both run with `-j1`. The initial
source timestamp is thirty seconds in the past. The unchanged-output mutation
sets it one second ahead of the clock, ensuring it exceeds the output and
Ninja's recorded build timestamp without sleeping. GNU Make's resulting clock
skew warning is not a measured result. Every assertion checks action executions
and final bytes; successful process exit alone is insufficient.

The expected results are executable assertions in the runner. They derive
from the mechanisms described in the [GNU Make][make] and [Ninja][ninja]
deep-dives. The command log supplies the execution oracle independently of
the engines' progress messages. After each incremental build the runner copies
the mutated inputs to a separate directory and directly executes both workers
without an engine or retained state. It asserts that this fresh evaluation
produces `compiled:alpha`, or `compiled:beta` when the source or optional
override contains `beta`. This checks incremental behavior against execution
of the actions; it does not independently validate the worker functions.

## Scenarios

| Scenario                      | Mutation after initial build                                              | Question                                                              |
| ----------------------------- | ------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| No-op                         | None                                                                      | Does retained state avoid both actions?                               |
| Unchanged generated output    | Add an ignored second line and advance the source timestamp               | Does the consumer run when the generator preserves its output?        |
| Preserved timestamp           | Replace `alpha` with `beta`, restoring the source timestamp exactly       | Does the engine notice changed bytes without a timestamp change?      |
| Missing output                | Delete `generated`, retaining all metadata                                | Does the engine recreate the intermediate and update its consumer?    |
| Changed command               | Change the generator command argument from `generate-v1` to `generate-v2` | Does command identity participate in the rebuild decision?            |
| Untracked negative dependency | Create `optional` containing `beta`                                       | Does an undeclared failed probe become visible when the file appears? |

The last scenario intentionally violates dependency completeness. A stale
result demonstrates the limitation of these declarations; it does not show
an engine violating its documented contract. The preserved-timestamp scenario
similarly isolates a known limitation of timestamp-based input checking.

## Observed results

On November 4, 2026, all twelve scenario assertions passed on Linux with GNU
Make 4.4.1 and Ninja `1.14.0.git`, built from the [pinned source][ninja-source].
These are separate observations from the cited source inspections, not a
claim that the installed GNU Make matches the deep-dive's pinned revision.

| Scenario                      | GNU Make actions    | Ninja actions                   | Final artifact   | Fresh evaluation |
| ----------------------------- | ------------------- | ------------------------------- | ---------------- | ---------------- |
| No-op                         | None                | None                            | `compiled:alpha` | `compiled:alpha` |
| Unchanged generated output    | Generator           | Generator                       | `compiled:alpha` | `compiled:alpha` |
| Preserved timestamp           | None                | None                            | `compiled:alpha` | `compiled:beta`  |
| Missing output                | Generator, consumer | Generator, consumer             | `compiled:alpha` | `compiled:alpha` |
| Changed command               | None                | Generator with changed argument | `compiled:alpha` | `compiled:alpha` |
| Untracked negative dependency | None                | None                            | `compiled:alpha` | `compiled:beta`  |

GNU Make skips the consumer when this generator preserves its output
timestamp. That observation qualifies a simple reading of the paper's
dirty-bit/no-early-cutoff cell: the recipe's output-preservation behavior
matters. Ninja's command change reruns the generator, while `restat` prevents
its unchanged output from invalidating the consumer. Both retained stale
artifacts in the two scenarios that conceal input changes from these rules.

## Reproduction

Run from the repository root inside the development shell:

```bash
dub run --single docs/research/build-systems/examples/rebuild-behavior.d --skip-registry=all
```

The runner prints the installed engine versions and one row per checked
scenario. Missing engines produce an explicit `SKIP:` line; an assertion
failure is a failed experiment. The repository's `ci --example-files`
selection includes the runner. Ninja must be available on `PATH` to exercise
its rows; a successful Make run does not imply Ninja was tested.

For source-matched Ninja observations, build the [catalog's pinned
revision][ninja-source] in a separate temporary checkout using its upstream
bootstrap instructions, then prepend that checkout to `PATH`. Do not modify
the canonical research clone.

## Limits and follow-up experiments

The suite does not exercise a content-addressed action cache, verifying step
traces, dynamic graph extension, interrupted metadata writes, remote execution,
or concurrent builds. It cannot validate a theorem about those mechanisms.
The action commands are D subprocesses rather than compilers, so no conclusion
about compiler dependency-dump cost follows.

The highest-value extensions are a content-based rebuilder for comparison,
a generated depfile whose selected dependency changes between runs, and a
cache entry whose referenced output blob has been evicted. Each extension
needs a separately stated expected execution trace and fresh-result oracle.
Only after those are in place does timing the same scenarios answer a useful
performance question.

## Sources

- [Runner source][runner]: manifests, actions, mutations, assertions, and
  environment detection used by the experiment.
- [GNU Make deep-dive][make] and [Ninja deep-dive][ninja]: the source-grounded
  descriptions the experiment tests.

<!-- References -->

[runner]: ./examples/rebuild-behavior.d
[make]: ./gnumake.md
[ninja]: ./ninja.md
[ninja-source]: https://github.com/ninja-build/ninja/tree/a7d7504e98d07f05a60f37411206907c00cb4ef7
