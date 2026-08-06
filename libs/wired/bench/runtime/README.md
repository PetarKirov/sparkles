# `runtime-bench` — runtime JSON benchmark for `sparkles:wired`

Step 1 of replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser: measure the field. The benchmark is a set of
`@benchmark` unittests driven by `sparkles:test-runner`'s `benchCase` —
engines × datasets × ops, one row per case.

| Ecosystem | Engines                                                | Integration      |
| --------- | ------------------------------------------------------ | ---------------- |
| D         | `std.json` (baseline), `mir-ion`, `asdf`, `jsoniopipe` | dub dependencies |
| D (SUT)   | `wired`                                                | in-tree          |
| C/C++     | yyjson, simdjson, rapidjson                            | nix-built shims  |
| Rust      | serde_json, simd-json, sonic-rs                        | nix-built shims  |

The default unittest configuration builds the D field. Use
`-c unittest-foreign` inside the devshell for the full competitive matrix.
Historical findings and every accepted/rejected optimization are recorded in
[`docs/specs/wired/bench-baseline.md`](../../../../docs/specs/wired/bench-baseline.md).

## Running

From the devshell (which provides the corpora as `$WIRED_BENCH_DATA`):

```sh
cd libs/wired/bench/runtime

# Canonical run: release codegen tuned to the host CPU (-mcpu=native).
dub test -b bench -- --bench --perf --group-by=dataset,operation

# Full competitive field (nix-built foreign shims):
dub test -b bench -c unittest-foreign -- \
    --bench --perf --bench-min-time=2000 --group-by=dataset,operation

# Useful subsets while iterating:
dub test -b bench -- --bench -i 'wired\.serialize'      # one op
WIRED_BENCH_ENGINES=asdf,std.json \
WIRED_BENCH_DATASETS=twitter \
dub test -b bench -- --bench                            # engine/dataset subset

# Sustained record stream (external corpus; see Datasets):
WIRED_BENCH_EXTERNAL_DATA=/data/wired-json \
WIRED_BENCH_DATASETS=wikidata,cloudtrail \
dub test -b bench -- --bench -i 'wired\.parse-stream' \
    --group-by=dataset,operation

# Machine-readable dump (see Recorded results below):
dub test -b bench -- --bench --perf --bench-min-time=2000 \
    --bench-json=results/$(date -I)-<host>-$WIRED_BENCH_ISA.json
```

Each op is its own `@benchmark` test (`wired.parse`, `wired.parse-stream`,
`wired.validate`, `wired.serialize`, `wired.decode`), so the runner's
`-i`/`-e` select ops. Engines and datasets subset via the
`$WIRED_BENCH_ENGINES` / `$WIRED_BENCH_DATASETS` comma lists. An empty engine
list means every compiled engine; an empty dataset list means the six bundled,
reproducible datasets. The large external corpora must be named explicitly.

Numbers from non-release builds are meaningless; the runner prints a loud
warning under `--bench` when built with asserts enabled. `dub test` without
`-b bench` is a debug build — use it for correctness only.

## Op semantics

Engines advertise capabilities through design-by-introspection traits
(`src/sparkles/wired_bench/traits.d`); each engine gets only the rows its
adapter supports.

| Op             | Contract                                                                                                                                                                                                                 |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `parse`        | immutable input → the engine's document. Any copy or padding the engine requires happens **inside** the timed region — the honest immutable-input service contract. The document is released untimed between iterations. |
| `parse-stream` | NDJSON, or Wikidata's one-entity-per-line array → parse and release each record. Line framing is timed; structural parity is checked untimed once. Reports both B/s and documents/s.                                     |
| `parse-insitu` | destructive in-place variants; the engine's scratch copy of the input is made inside the timed region. (No D engine reaches it today.)                                                                                   |
| `serialize`    | a pre-parsed document (untimed `setup`) → minified JSON string, timed. Throughput is normalized over the engine's own output bytes.                                                                                      |
| `validate`     | raw bytes → well-formedness verdict, materializing nothing. Only engines with a genuinely cheaper-than-parse path get a row (jsoniopipe's tokenizer drain today) — for the rest it would equal `parse`.                  |
| `decode`       | raw bytes → a shared partial Twitter struct — the typed-deserialization pipeline (`twitter.json` only). This is the op closest to wired's real workload.                                                                 |

## Hardware counters

Pass the runner's `--perf` for a per-row hardware-counter view (IPC,
instructions/iter, branch/cache miss rates): the runner opens one
`perf_event` group, gives every case a dedicated counting pass bracketed by
`ENABLE`/`DISABLE` ioctls (so the ns/iter medians are never perturbed),
scales by the pass's own multiplex ratio, and drops the LLC pair when
calibration shows the group would multiplex. `--syscalls` and the tier-0
`/proc` counters (`--metrics=syscr,cache-hit,…`) work too — see the
[test-runner docs](../../../../docs/libs/test-runner/how-to/benchmark.md).

For instruction attribution, record one wired row and demangle the D symbols:

```sh
WIRED_BENCH_ENGINES=wired-native WIRED_BENCH_DATASETS=mesh \
perf record -e instructions:u -o /tmp/wired-instructions.data -- \
    build/wired-runtime-bench-test-unittest-foreign \
    --bench -i 'wired\.parse$' --bench-min-time=3000 --no-colors

perf report -i /tmp/wired-instructions.data --stdio --no-children \
    --percent-limit=1 | ddemangle
```

Compare engines within one snapshot: yyjson wall time has moved by 10–15%
between otherwise identical runs on the benchmark host. Retired instructions
are the stable cross-run diagnostic, but throughput remains the acceptance
gate. If a median is unexpectedly slow while its own minimum is normal, rerun
the row—the engine set can perturb allocator/cache state enough to make a row
bimodal.

## Verification

Every op verifies itself once, in its untimed `after`, against the
`std.json` reference for its dataset:

- `parse` / `parse-insitu` — the parsed document must reproduce the
  reference **fingerprint** (counts of every value kind, array/object sizes,
  decoded string/key bytes, and the sum of all numbers at 1e-9 relative
  tolerance);
- `parse-stream` — every physical record contributes to one aggregate
  reference fingerprint and the document count/byte-rate metrics;
- `serialize` — the engine's own output is re-fingerprinted through the
  reference parser (structural, format-independent), so wrong _or invalid_
  output is caught (this gate currently flags jsoniopipe: its serialized
  twitter/github_events output is rejected by `std.json` — an isolated error
  row, not a competitive B/s figure);
- `validate` — a bool-returning validate must accept the (valid) corpus; a
  void one signals rejection by throwing, which error-rows on its own;
- `decode` — the decoded Twitter stats must match the reference extraction.

A mismatch turns that one case into an error row (the matrix continues) and
fails the run's exit status — an engine that parses _differently_ must never
look _faster_. A registration-time crash (engine constructor, sizing probe)
is likewise isolated into a per-case error row.

## ISA policy

The bench is built by dub outside the nix sandbox and uses `-mcpu=native`
(the `bench` build type: `unittests releaseMode optimize inline` + `-O3
-allinst`). Note vs the old executable harness: `-enable-cross-module-inlining`
is off (mir-ion's `-unittest` + release build culls template symbols under
it), a known ~15% delta on wired's number-heavy hot loops — compare new
numbers only against baselines regenerated under this build type. The
devshell still exports `$WIRED_BENCH_ISA` (the foreign-engine preset name)
for results-file naming.

Both configurations use context-checking assertions and the toolchain's static
default libraries; foreign shims may still introduce their own shared runtime
dependencies.

## Manifest notes

`dub.sdl` is deliberately terse; these four properties are not obvious from
reading it, and each has bitten before:

- **`configuration "unittest"` is empty but load-bearing.** `dub test` builds
  the _first_ configuration, not one matched by name, so the empty block is
  what keeps the default off-nix (D-engine) field. Delete it and plain
  `dub test` silently starts building `unittest-foreign`, which needs the nix
  shims.
- **`buildOptions "unittests"` in the `bench` build type is what registers
  tests.** Without it `dub test -b bench` builds and runs successfully having
  discovered _zero_ tests — it does not fail, it just measures nothing.
- **Cross-module inlining rides on `subConfiguration "sparkles:wired"
"library-inline"`, not on the build type.** That scoping is the point:
  build-type flags propagate to every dependency, and mir-ion's
  `-unittest` + release build culls a template-nested symbol its own inlined
  code references. For codegen A/B runs override the sub-configuration
  instead — `--override-config sparkles:wired/library` for stock, or
  `.../library-singleobj`; the parity matrix lives in `libs/wired/dub.sdl`.
- **An engine's `versions` gate also controls its UDA.** `twitter.d` gates
  each engine's "ignore unknown keys" attribute on the same version
  identifier, so clearing one `versions` line disables that engine without
  leaving a dangling import; its `dependency` line can then go too.

## Recorded results

Baseline snapshots live under `results/`, named `<date>-<host>-<isa>.json`.
New snapshots come from the runner's `--bench-json` (see Running above);
`--bench-min-time=2000` restores the old harness's 2 s per-case budget —
short budgets under-report allocation-heavy paths. Old → new field mapping:
`engine` → `name`; `dataset`/`op` → `labels.*`; `iters` → `samples`;
`mbPerSec` → `metrics["B/s"] / 1e6`; raw perf totals → per-iteration catalog
cells (`ipc`, `instr`, …). The findings note that reads the recorded
snapshots is
[`docs/specs/wired/bench-baseline.md`](../../../../docs/specs/wired/bench-baseline.md).

The snapshot writer does not emit repository-canonical JSON: keys may be in
insertion order and large integral metrics may use exponent notation. Before
committing a new result, sort its keys, use plain decimal notation for those
metrics, retain the trailing newline, and reparse/compare the normalized file
to ensure formatting did not change its data. Both `prettier` and the
`pretty-format-json` commit hook must accept the result.

## Generated single-TU oracle

`wired-inline` is an opt-in code-generation oracle: it builds a generated
single-translation-unit copy of the parser and verifies that its structural
fingerprint agrees with `wired-native`. Regenerate the copy whenever a module
on the wired parse path or its base float-conversion dependency changes:

```sh
cd libs/wired/bench/runtime
dub run --single tools/gen-wired-inline.d
```

Its equivalence unittest is part of the ordinary runtime-benchmark test suite.
For a measured native/oracle comparison, additionally enable
`--d-version=BenchWiredInline`; keep that engine out of normal matrices because
its second retained document changes the allocator regime of neighboring rows.

## Datasets

The normal matrix is fetched by hash in `nix/packages/wired-bench-data.nix`;
the files are never copied into Git:

| selector        | file                 | shape                                       |
| --------------- | -------------------- | ------------------------------------------- |
| `twitter`       | `twitter.json`       | 632 KB, string-heavy API response           |
| `citm_catalog`  | `citm_catalog.json`  | 1.7 MB, structure-heavy catalog             |
| `canada`        | `canada.json`        | 2.2 MB, float-heavy coordinate arrays       |
| `github_events` | `github_events.json` | 65 KB, small string-heavy document          |
| `mesh`          | `mesh.json`          | 724 KB, compact mesh / dense numeric arrays |
| `mesh_pretty`   | `mesh.pretty.json`   | 1.58 MB, the same mesh with whitespace      |

The first three come from
[nativejson-benchmark](https://github.com/miloyip/nativejson-benchmark/tree/478d5727c2a4048e835a29c65adecc7d795360d5);
GitHub events and both mesh forms come from
[simdjson's pre-corpus-removal tree](https://github.com/simdjson/simdjson/tree/19c3b1315a2a6b8ab0a6b7335bb97269cbd0a448/jsonexamples).
The compact and pretty mesh pair isolates whitespace skipping without changing
the data.

Large or account-specific datasets are opt-in. Put these exact filenames in
one directory, export that directory as `$WIRED_BENCH_EXTERNAL_DATA`, and name
the selectors in `$WIRED_BENCH_DATASETS`:

| selector        | file                   | framing / benchmark op                                                   |
| --------------- | ---------------------- | ------------------------------------------------------------------------ |
| `wikidata`      | `wikidata.json`        | top-level array, one entity per physical line; `parse-stream`            |
| `osm`           | `osm.json`             | one Overpass/OSM JSON document; `parse`                                  |
| `cloudtrail`    | `cloudtrail.ndjson`    | one compact CloudTrail log-file object per line; `parse-stream`          |
| `elasticsearch` | `elasticsearch.ndjson` | Bulk API actions/sources or log records, one JSON value per line; stream |

External files are read through a read-only memory map. They do not incur a
second heap-sized input copy, and record streams release each parsed document
before advancing. This is important for Wikidata-scale runs: resident input
pages and the parser's live document allocation remain distinguishable in an
external RSS profiler.

### Preparing external corpora

- **Wikidata:** use the official [entity dump directory](https://dumps.wikimedia.org/wikidatawiki/entities/).
  The recommended `latest-all.json.bz2` expands to a single array with one
  entity per line, exactly the framing the harness expects. For example,
  `lbzip2 -dc latest-all.json.bz2 > "$WIRED_BENCH_EXTERNAL_DATA/wikidata.json"`.
  The dump is enormous; a dated dump is preferable when publishing results.
- **OpenStreetMap:** request JSON from the [Overpass API](https://wiki.openstreetmap.org/wiki/Overpass_API/Overpass_QL)
  (`[out:json]`) and save the complete response as `osm.json`. Include geometry
  (`out geom`) when the goal is a high-density coordinate workload, and use a dated
  query/bounding box in any published benchmark so the input is reproducible.
- **CloudTrail:** [AWS delivers](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-examples.html)
  gzip-compressed JSON documents whose root has a `Records` array. Compact each
  decompressed log file to one physical line (for example with `jq -c .`) and
  concatenate those lines into `cloudtrail.ndjson`. Do not put one `Records`
  element per line unless that is the service contract being measured.
- **Elasticsearch/log aggregation:** copy a real [Bulk API NDJSON](https://www.elastic.co/guide/en/elasticsearch/reference/current/docs-bulk.html)
  body or NDJSON export to `elasticsearch.ndjson`. Every non-empty line must
  independently be valid JSON; the final newline is optional to the harness.

`wired.parse-stream` folds every record into a `std.json` structural fingerprint
once outside timing. The reference pass collects in bounded batches and returns
unused GC pages before measurement, so it does not leave a dump-sized reference
tree behind. Malformed normalization or a parser that silently skips data fails
the row instead of producing a throughput number.

## Conformance corpora

Speed inputs and rejection inputs stay separate. `dub test :wired -- -i
'conformance\.'` runs both pinned robustness suites when inside the devshell:

- nst/JSONTestSuite: all `y_*` inputs accepted, all `n_*` rejected, `i_*`
  allowed either verdict but never a crash;
- nativejson-benchmark: JSON_checker `pass*`/`fail*` expectations plus all 27
  roundtrip inputs. Its two `_EXCLUDE` files remain excluded because one
  forbids top-level scalars (valid since RFC 7159) and the other imposes an
  unspecified nesting limit.

Outside the devshell, point `$JSON_TEST_SUITE` and
`$NATIVEJSON_TEST_SUITE` at checkouts of those repositories. Missing suite
variables produce an explicit skip rather than making ordinary package tests
depend on Nix.
