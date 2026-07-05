# `runtime-bench` — runtime JSON benchmark for `sparkles:wired`

Step 1 of replacing `std.json` inside `sparkles:wired` with a
state-of-the-art JSON parser: measure the field. A D harness benchmarks JSON
engines across four ecosystems over the canonical corpora, with every foreign
engine reached through `extern(C)`:

| Ecosystem | Engines                                                | Integration                                               |
| --------- | ------------------------------------------------------ | --------------------------------------------------------- |
| D         | `std.json` (baseline), `mir-ion`, `asdf`, `jsoniopipe` | dub dependencies                                          |
| C         | `yyjson`                                               | ImportC binding (`bindings/yyjson`), ISA-preset nix build |
| C++       | `simdjson` (DOM + On-Demand), `rapidjson`              | `extern "C"` shim (`shims/cpp`), nix-built                |
| Rust      | `serde_json`, `simd-json`, `sonic-rs`                  | `staticlib` shim crate (`shims/rust`), nix-built          |

## Running

From the devshell (which provides the corpora as `$WIRED_BENCH_DATA` and the
nix-built shims on the pkg-config path):

```sh
cd libs/wired/bench/runtime

# Canonical run: release codegen tuned to the host CPU (-mcpu=native).
dub run -b bench

# Useful filters while iterating:
dub run -b bench -- --datasets=twitter --engines=std.json,yyjson --ops=parse
dub run -b bench -c d-only            # D engines only; no native libs needed
dub run -b bench -- --json=out.json   # machine-readable dump (via wired itself)
```

Numbers from non-release builds are meaningless; the harness prints a loud
warning when built with asserts enabled.

## Op semantics

Engines advertise capabilities through design-by-introspection traits
(`src/sparkles/wired_bench/traits.d`); each engine gets only the rows its
adapter supports.

| Op             | Contract                                                                                                                                                                                                                                                                                                       |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `parse`        | immutable input → the engine's document. Any copy or padding the engine requires happens **inside** the timed region (simd-json's `&mut` copy, yyjson's internal copy, simdjson's padded buffer) — the honest immutable-input service contract. The document is released untimed between iterations.           |
| `parse-insitu` | destructive in-place variants (yyjson `YYJSON_READ_INSITU`, rapidjson `ParseInsitu`); the engine's scratch copy of the input is made inside the timed region.                                                                                                                                                  |
| `serialize`    | a pre-parsed document (untimed) → minified JSON string, timed. Throughput is normalized over the engine's own output bytes.                                                                                                                                                                                    |
| `validate`     | raw bytes → well-formedness verdict, materializing nothing. Only engines with a genuinely cheaper-than-parse path get a row (rapidjson SAX null-handler, serde/sonic `IgnoredAny`, simd-json `to_tape`, simdjson On-Demand structural skip, jsoniopipe tokenizer drain) — for the rest it would equal `parse`. |
| `decode`       | raw bytes → a shared partial Twitter struct — the typed-deserialization pipeline (`twitter.json` only). This is the op closest to wired's real workload.                                                                                                                                                       |

## Verification

Before an engine is timed on a dataset, it must reproduce the `std.json`
reference **fingerprint** (counts of every value kind, array/object sizes,
decoded string/key bytes, and the sum of all numbers at 1e-9 relative
tolerance). A mismatch fails the engine's rows and the process exit status —
an engine that parses _differently_ must never look _faster_.

## ISA policy

The D side (harness + D engines) is built by dub outside the nix sandbox and
uses `-mcpu=native` (the `bench` build type). The nix-built foreign engines
cannot use `native` (sandbox purity), so they come in ISA-preset variants —
`x86-64-v2` (baseline), `x86-64-v4`, `apple-m1` — and the devshell picks the
best preset the host supports at shell entry (exported as
`$WIRED_BENCH_ISA`, stamped into every report). simdjson intentionally stays
the generic nixpkgs build: it dispatches to AVX-512-tier kernels at runtime.

## Recorded results

Baseline snapshots live under `results/` (`--json` dumps, named
`<date>-<host>-<isa>.json`); the findings note that reads them is
[`docs/specs/wired/bench-baseline.md`](../../../../docs/specs/wired/bench-baseline.md).

## Datasets

Pinned by `nix/packages/wired-bench-data.nix` (never committed):
`twitter.json` (632 KB, string-heavy), `citm_catalog.json` (1.7 MB,
structure-heavy), `canada.json` (2.2 MB, float-heavy) from
nativejson-benchmark, and `github_events.json` (65 KB, small-document
regime) from simdjson. `--data-dir` points the harness elsewhere.
