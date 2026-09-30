# UTF and terminal-text benchmark matrix

Standalone D package using `sparkles:test-runner`. Nothing here adds a foreign
runtime dependency to `sparkles:base`. The default configuration measures native
Sparkles and an independent, byte-at-a-time scalar D reference. The primary
competitive configuration adds real simdutf calls through a separately compiled
C++ `extern "C"` shim. Optional Rust sources add simdutf8 and xutf; they are not
mock implementations and are not required for the simdutf matrix.

Measured results and remaining leaders are recorded in
[the SIMD Unicode performance report](../../../../docs/research/simd-unicode/performance.md).
The commands below reproduce the comparison; results depend on the host.

## Build the simdutf shim separately

Run from the Sparkles repository root, with a local simdutf clone. The researched
revision is [`cf8715fad4d55c87aad3006a9a82531f740605b8`](https://github.com/simdutf/simdutf/tree/cf8715fad4d55c87aad3006a9a82531f740605b8).
Use that revision for reproducible comparisons; do not reset an existing clone
containing someone else's changes. All compiled foreign artifacts stay outside
this repository.

```sh
export REPOS="${REPOS:-/home/petar/code/repos}"
export UTF_BENCH_SHIM_DIR="$(mktemp -d /tmp/sparkles-utf-shim.XXXXXX)"
SIMDUTF_REVISION=$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPOS/cpp/simdutf" rev-parse HEAD)
printf 'simdutf revision: %s\n' "$SIMDUTF_REVISION"
c++ --version
c++ -std=c++17 -O3 -DNDEBUG -fPIC \
  -I"$REPOS/cpp/simdutf/include" -I"$REPOS/cpp/simdutf/src" \
  -c "$REPOS/cpp/simdutf/src/simdutf.cpp" \
  -o "$UTF_BENCH_SHIM_DIR/simdutf.o"
c++ -std=c++17 -O3 -DNDEBUG -fPIC \
  -I"$REPOS/cpp/simdutf/include" \
  "-DUTF_BENCH_SIMDUTF_REVISION=\"$SIMDUTF_REVISION\"" \
  -c libs/base/bench/utf/shims/simdutf.cpp \
  -o "$UTF_BENCH_SHIM_DIR/shim.o"
ar rcs "$UTF_BENCH_SHIM_DIR/libutf-bench-simdutf.a" \
  "$UTF_BENCH_SHIM_DIR/simdutf.o" "$UTF_BENCH_SHIM_DIR/shim.o"
```

The C++ build uses upstream ISA-specific implementations and runtime dispatch,
not a guessed AVX2 implementation. Each simdutf row records the actual active
implementation name after dispatch warmup and the revision supplied above.
D's `bench` build uses LDC `-O3 -mcpu=native`; record compiler versions, flags,
CPU, affinity, governor, and worktree revision with saved results. The manifest
selects the runner implementation's `benchmark` configuration (`-singleobj` on
LDC) to avoid duplicate nested reporting symbols in separate compilation.

## Correctness sweep, then measurement

```sh
dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest-simdutf -- -i 'utf\.correctness$'

dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest-simdutf -- --bench \
  -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-min-time=20 \
  --bench-json=/tmp/sparkles-base-utf-before.json
```

Add `--perf` if Linux hardware counters are available. After implementation
changes, rerun the identical command with
`--bench-json=/tmp/sparkles-base-utf-after.json`. Keep the baseline JSON before
changing the implementation. For a quick representative subset:

```sh
UTF_BENCH_CORPORA='ascii/4096,two-byte/4096,cjk/4096,supplementary/4096,mixed/4096,grapheme/4096' \
  dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest-simdutf -- --bench \
  -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-json=/tmp/sparkles-base-utf-subset.json
```

`UTF_BENCH_CORPORA` is a comma-separated list of **name prefixes**.
`UTF_BENCH_ENGINES` is a comma-separated list of **exact names**:
`scalar-d,sparkles,simdutf,simdutf8,xutf`. Unset means every compiled-in row.
Do not filter the correctness sweep if claiming the full matrix passed.
To run without foreign libraries, use `-c unittest` and omit shim setup.
The test filter intentionally excludes dependency-package tests.

## What is measured and checked

- **`utf.offset`:** first byte of the first ill-formed UTF-8 sequence, or input
  length. A malformed continuation reports its sequence's lead, not the
  continuation byte. Sparkles `indexOfInvalidUtf8`, independent scalar D, and
  simdutf `validate_utf8_with_errors` share this contract. Rust's optional
  `simdutf8::compat` reports `valid_up_to()` with the same prefix semantics.
- **`utf.boolean`:** RFC 3629 validity only. Sparkles uses `validateUtf8`, backed
  by its exact-offset primitive; simdutf uses the separate `validate_utf8`
  Boolean API. Optional simdutf8 uses `basic`, whose full-scan contract differs
  from its error-reporting `compat` API. A faster Boolean row is not evidence
  that exact offsets are equally fast; invalid inputs also expose early-exit
  versus whole-input behavior.
- **`utf.to16` / `utf.to8`:** validating UTF-8 ↔ UTF-16 conversion into
  preallocated caller buffers, preserving embedded NUL. Every successful
  iteration verifies the entire output, exact count, independent reference
  checksum, and output guards **outside timing**. Invalid iterations verify
  rejection and source offset; native/scalar rows additionally check the entire
  destination remained unchanged. The D reference validates/sizes before
  writing, independent of Sparkles' decoder and implementation.
- **`utf.display`:** visible width and complete UTF-8 cluster-end offset arrays
  for hand-specified printable fixtures: ASCII, two-byte Latin/Greek, CJK,
  supplementary emoji, mixed scripts, combining marks, ZWJ emoji, and regional
  indicator flags. Expected widths and boundaries are fixture constants,
  constructed before timing. The default field contains Sparkles only; the
  optional real xutf adapter provides a competitor for this matched subset.
  Sparkles segmentation also computes its cluster width metadata, so this is a
  consumer-operation comparison, not an isolated UAX #29 implementation race.

Buffers, fixtures, expected conversions, dispatch warmup, provenance strings,
and row-owned state are allocated before timing. `blackBox` covers inputs and
outputs. Retained runner callbacks are bound class methods, avoiding DIP1000
stack-delegate lifetimes. `benchCase` verifies each timed invocation afterward.
Inputs under 256 bytes use a labelled **64-operation batch** to amortize per-call
clock overhead; large inputs use one operation. Time and counters per row are
per **batch**, while the B/s metric includes all input bytes in the batch. Divide
ns/batch by `batch` to obtain ns/operation. The correctness check examines the
final output of the batch. No allocation, checksum scan, reference work, or
fixture construction occurs in the measured caller-buffer body.

The deterministic validation/transcoding field includes exact byte lengths
0, 1, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65, 127, 128, 129, 4096, and 65536,
with ASCII tails rather than splitting valid multibyte sequences. Invalid
corpora cover stray continuations, overlongs, surrogates, out-of-range scalars,
wrong continuations, truncation, and every byte of CJK/supplementary sequences
placed around block boundaries. UTF-16 failures include lone high and low
surrogates at the same boundary offsets.

## Semantic limits

**Conversion contracts are deliberately not equal.** Sparkles and the scalar D
reference accept bounded destinations and guarantee fail-before-write for
malformed input or insufficient capacity. simdutf's selected APIs require a
sufficiently large caller buffer and may write a prefix before detecting an
error; the shim has no capacity parameter. Buffers here satisfy worst-case
capacity (UTF-8 bytes for UTF-16; three bytes per UTF-16 unit for UTF-8), with
additional guard elements. Never call the foreign adapter with undersized
storage. Capacity-failure performance is not compared, and a simdutf win does
not imply the stronger bounded transaction contract has equal cost.

Native D calls can inline; the separately compiled C ABI shim adds a foreign
call boundary and runtime dispatch. This overhead is especially relevant to
short inputs; it is labelled, not subtracted. Corpora are reused, output
verification warms caches between timed calls, and results describe this
hot/reused-input scenario, not cold cache or every workload. Empty rows have
zero-byte throughput. No row proves universal “fastest” status.

Display fixtures exclude ANSI, controls, pathological clusters over Sparkles'
32-codepoint window, malformed UTF-8, ambiguous-width policies, noncharacters,
and known cross-library width disagreements. xutf uses Unicode 17; Sparkles
uses its terminal width tables with Phobos segmentation. Agreement on these
fixtures does not establish equivalence across Unicode versions, all UAX #29
rules, ANSI parsing, or terminal policies. `analysis.d` normalization, folding,
word boundaries, stopwords, and malformed-byte provenance are a materially
larger contract and are intentionally not disguised as a width/segmentation
benchmark.

## Optional real Rust static library

Sources live in `shims/rust/`. The path dependencies deliberately name local
clones, not mutable registry releases:

- [simdutf8 `641d57f313df57354246d2b68d4778c092e076c3`](https://github.com/rusticstuff/simdutf8/tree/641d57f313df57354246d2b68d4778c092e076c3)
  at `/home/petar/code/repos/rust/simdutf8`.
- [xutf `9bb347af041369a68a4effd1ca85c6d2f9b4e17b`](https://github.com/can1357/xutf/tree/9bb347af041369a68a4effd1ca85c6d2f9b4e17b)
  at `/home/petar/code/repos/rust/xutf`.

Check the actual revisions before building; row labels assume those pins. xutf
requires a real nightly toolchain (`portable_simd`). If that toolchain is absent,
run the simdutf field above; do not replace xutf with a scalar stand-in. The Rust
shim allocates no output and writes caller-provided cluster boundaries.

```sh
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPOS/rust/simdutf8" rev-parse HEAD
env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPOS/rust/xutf" rev-parse HEAD
rustup run nightly rustc --version
export CARGO_TARGET_DIR="$(mktemp -d /tmp/sparkles-utf-rust.XXXXXX)"
RUSTFLAGS="-C target-cpu=native" rustup run nightly cargo build --release --locked \
  --manifest-path libs/base/bench/utf/shims/rust/Cargo.toml
export UTF_BENCH_RUST_DIR="$CARGO_TARGET_DIR/release"
dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest-foreign -- -i 'utf\.correctness$'
dub test --root=libs/base/bench/utf --compiler=ldc2 -b bench \
  -c unittest-foreign -- --bench \
  -i 'utf\.(offset|boolean|to16|to8|display)$' \
  --group-by=operation,corpus --bench-json=/tmp/sparkles-base-utf-foreign.json
```

Rust and C++ compiler flags differ; preserve them alongside results rather than
interpreting the matrix as equal code-generation backends. The Cargo command
creates its normal dependency lockfile on first execution; keep it with a
published run's provenance. No Rust transcoding fallback is presented as xutf:
xutf's permissive transcoder is not the strict validation contract measured here.
