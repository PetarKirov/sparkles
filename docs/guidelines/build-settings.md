# Build settings: experiments and policy

**Measured:** October 21–22, 2026. Baseline: `f71a5bffe`.

Forced compilation of `versions` and its 13 dependency archives falls from
**39.97 s to 32.31 s (19.2%)**, with suite execution and DUB setup excluded.
The selected test policy reduces a warm `wired` root rebuild from **23.89 s to
20.12 s (15.8%)**, and `versions` from **3.83 s to 3.58 s (6.5%)**. These totals
include compilation and linking, not test execution or DUB setup. Full debug
information remains available through `-b unittest-debug`.

Root totals above are sums of the separately measured compile/link medians;
individual paired samples are retained in the results JSON.

The apparent fastest linker is **not** the fastest working project-wide default:
raw lld omits Nix runtime search paths, and wrapped lld is slower than gold.
Blanket single-object compilation and static-runtime/linker changes also regress
a real JSON workload. Defaults retain **gold + shared Phobos/druntime**;
benchmarks select `-O3` and native CPU targeting. Static runtime is an explicit
alternative, not a universal speed improvement.

## Questions and experiment plan

This investigation separates three objectives: compile/link latency for `dub
test`, throughput of optimized benchmarks, and consistent settings in standalone
and monorepo DUB recipes. Test-suite execution is not a build-time metric.

The starting evidence is the compiler/linker investigation in
`ndslice-vs-hand-written-c-gist/REPORT-FULL.md`, sections 9 and “Build
configurations”. Its results are hypotheses, not Sparkles measurements:

- Compare ordinary template emission with LDC's `linkonce-templates`,
  `singleobj`, and removal of `allinst` or debug information.
- Compare bfd, gold, lld, mold and Wild on the **same precompiled objects**, with
  shared and static Phobos/druntime. Static here does not mean static libc.
- Compare benchmark runtime with static/shared runtime, bounds checks,
  generic/native CPU targeting, optimization levels and ThinLTO.
- Preserve debug-mode checks and assertions in normal tests, and assertion-enabled
  `checked` shipping builds. Treat benchmark builds as a separate policy.
- Apply only measured, working choices. Record failures rather than omitting them.

## Protocol and environment

The harness captures actual compiler and linker commands from a successful
`dub test --force --verbose -- --help`. It replays the root compilation and
link separately, outside DUB and without executing the suite. Dependencies and
filesystem caches are warm. These are **root rebuild** measurements, not clean
dependency builds or no-op DUB invocations. Each experiment writes its command,
exit status and output; failed commands are not timing wins.

The separate graph-replay mode additionally recompiles every captured dependency
archive before the root and final link. It retains compiler-invoked archiving
inside the compilation sum, but excludes DUB setup, package downloads and suite
execution. It is still a warm-filesystem experiment, not a cold-cache benchmark.

Variants rotate order between rounds. Runtime measurements use the project's
benchmark runner, separate process invocations pinned to CPU 4, and retain
machine-readable output. Build commands are not CPU-pinned: their normal compiler
and linker parallelism is part of the measured configuration. No other study build
or benchmark runs concurrently.

| Component    | Measured environment                                                               |
| ------------ | ---------------------------------------------------------------------------------- |
| Host         | AMD Ryzen 9 7940HX, 16 cores / 32 logical CPUs, 64 MiB L3                          |
| OS           | Linux x86-64, Nix development toolchain                                            |
| LDC          | 1.42.0, DMD frontend 2.112.1, LLVM 18.1.8                                          |
| DUB          | Installed executable reports 1.42.0-beta.1                                         |
| Linkers      | GNU gold/bfd, lld 21.1.8, mold 2.42.0, Wild 0.7.0                                  |
| CPU controls | Runtime pinned to CPU 4; boost remains enabled                                     |
| Sampling     | Three compilation rounds; five native links; five paired final runtime invocations |

The 32 samples inside a benchmark invocation are **not** counted as 32
independent process invocations. Runtime tables summarize per-invocation medians;
overlapping spreads are not advertised as reliable small wins. The machine was
not an isolated performance lab: warm caches and paired controls reduce noise,
but do not establish cold-cache, other-machine or other-compiler results.

## Build-time results

### Initial debug-build screening

`versions`, three warm root rebuilds per condition; medians in milliseconds:

| Root compile setting                  | Compile | Link |
| ------------------------------------- | ------: | ---: |
| Existing settings                     |    3549 |  277 |
| Remove inherited `linkonce-templates` |    3567 |  283 |
| Add `singleobj`                       |    3599 |  279 |
| Remove `allinst`                      |    3549 |  274 |
| Remove full debug information         |    3126 |  267 |

The template-emission change is not the 4× win from the input report: these
are unoptimized test builds, not optimized ndslice instantiations. Dropping
debug information is faster, but loses diagnostics; it is a screening result,
not sufficient evidence to change the default.

The larger `wired` root gives the following medians (three builds each):

| Root compile setting                  | Compile (ms) | Link (ms) |
| ------------------------------------- | -----------: | --------: |
| Existing settings                     |        23436 |       456 |
| Remove inherited `linkonce-templates` |        26127 |       565 |
| Add `singleobj`                       |        23550 |       446 |
| Remove `allinst`                      |        23524 |       449 |
| Remove full debug information         |        17214 |       370 |
| Line-table-only debug information     |        20079 |       394 |

`linkonce-templates` is worth about 10% on this root, and line tables save about
14% of compilation versus full debug information. These gains do not include
any change in suite execution time.

### Linker and runtime-library matrix

Same `wired` object and dependency archives, five links per condition; median
whole-link wall time in milliseconds:

| Linker   | Shared Phobos/druntime | Static Phobos/druntime |
| -------- | ---------------------: | ---------------------: |
| bfd      |                   1463 |                   1854 |
| gold     |                    386 |                    459 |
| lld      |                **151** |                **174** |
| mold     |                   1072 |                   1382 |
| Wild 0.7 |                    715 |                    719 |

These numbers include LDC, the C driver and Nix wrappers, **not just the linker
algorithm**. The executable's `.comment` section confirms lld/mold/Wild identity;
`ldd` confirms the requested shared/static default-runtime selection. This
machine's real project link is unlike the tiny link in the input report: Wild
does not win here. Both versions and wrapper costs matter.

A follow-up varied native linker thread counts (five links each). lld with one
thread took 190 ms and four threads 152 ms; mold took 835/843 ms; Wild took
724/706 ms. No thread-count override improves on lld's ordinary invocation, so
none belongs in the default policy.

**Integration reverses the provisional lld choice.** The raw lld binary does not
perform the Nix wrapper's runtime-path discovery: the `ci` test executable linked,
then failed to load `libtree-sitter.so.0.26`. A follow-up using the pinned
`llvmPackages.bintools` wrapper produced runnable linkage but took **705 ms**
(five links: 713, 705, 694, 702, 707), versus gold's 386 ms on the same large
object. Thus the raw 151 ms result is not the project-wide winner. This is the
same class of driver/wrapper measurement trap highlighted in the input report.
The final default stays gold rather than adding a slower wrapper or manually
hard-coding every external library's runtime path.

### Selected default test build

| Root       | Baseline compile + link (ms) | Selected compile + link (ms) | Reduction |
| ---------- | ---------------------------: | ---------------------------: | --------: |
| `versions` |                   3549 + 277 |                   3367 + 210 |      6.5% |
| `wired`    |                  23436 + 456 |                  19740 + 376 |     15.8% |

The selected build retains `debugMode`, unittests, assertions and the existing
package-specific assertion/instantiation settings. LDC uses line tables rather
than full variable/type debug information. A separate exception probe confirms
that the **caller frame**, not just the exception's own source location, retains
its file and line. Full debugger locals/types require `unittest-debug`.

### Forced dependency-graph rebuild

The `versions` graph includes 13 dependency archives, the root compilation and
the final link. Three paired rounds alternate baseline/selected order. Every
compiler command runs again: this is not a no-op cache hit or just root editing.
Source/filesystem caches remain warm.

| Phase                                         | Baseline median (s) | Selected median (s) |
| --------------------------------------------- | ------------------: | ------------------: |
| All compilation, including archive production |              39.973 |              32.312 |
| Final link                                    |               0.341 |               0.239 |
| Per-round compile + link total                |              40.314 |              32.558 |

The compilation reduction is **19.2%**; total compile/link latency improves
**19.2%**. All six final graph replays succeed. Representative compilation components:

| Component             | Baseline (s) | Selected (s) |
| --------------------- | -----------: | -----------: |
| `base` library        |        9.639 |        8.555 |
| `wired` library       |        4.201 |        3.907 |
| `ui` library          |        9.717 |        8.795 |
| Runner implementation |       10.459 |        5.342 |
| `versions` root       |        3.606 |        3.379 |

The runner comparison changes scoped single-object codegen and debug information
together; it does not separate their contributions. The whole-graph improvement
should not be attributed to a single template flag: the existing root already
inherited linkonce behavior.

## Benchmark-runtime results

### One-variable CSV screening

Root-only flag screening, dependencies fixed. Three invocations, each with 32
samples; times are medians of invocation medians in microseconds:

| Variant                               | Parse 1k rows | Parse 10k rows | Sniff 100 rows | Compile / link (ms) |
| ------------------------------------- | ------------: | -------------: | -------------: | ------------------: |
| Existing native `-O3`, shared runtime |         45.33 |         452.88 |          35.74 |          4901 / 136 |
| Static runtime                        |         45.32 |         447.89 |          35.61 |          5025 / 201 |
| Bounds checks off                     |         45.26 |         452.82 |          35.00 |          5269 / 135 |
| Generic CPU                           |         52.31 |         509.84 |          41.70 |          4844 / 131 |
| `-O2`                                 |         50.92 |         511.99 |          39.58 |          4825 / 136 |
| Assertions enabled                    |         49.64 |         495.37 |          39.08 |          4939 / 132 |
| Root ThinLTO + lld                    |         66.80 |         630.55 |          50.72 |          3854 / 975 |

Native targeting and `-O3` materially beat their alternatives on these workloads.
Assertion-enabled measurements remain available, but are a different policy.
Bounds-check removal does not establish a useful win, so it is **not** selected.
ThinLTO here is a **root-bitcode/native-dependency** experiment, not whole-program
LTO; it does not reproduce the input report's link failure, but its runtime is
worse. No claim about fully rebuilt whole-program LTO follows from this result.

Removing `linkonce-templates` from the root alone compiled in 6341 ms but failed
all three links, with missing `Buffer`, allocator and `Nullable` instantiations.
It is a rejected **mixed-emission** configuration, not evidence that every
consistent non-linkonce build must fail. No runtime number is assigned to it.

### Whole-build candidates: the regression that changed the choice

All benchmark binaries use identical sources and input datasets. Five paired
process invocations, 32 samples per invocation, CPU 4; no build runs concurrently.
`std.json` is a useful second implementation because it exercises Phobos code
and allocation behavior beyond wired's hot loops.

| Candidate, `std.json` / `canada` serialize    | Baseline (ms) | Candidate (ms) | Decision                                     |
| --------------------------------------------- | ------------: | -------------: | -------------------------------------------- |
| Blanket `singleobj`, static runtime, lld      |         20.76 |          25.26 | Reject: ~22% slower                          |
| Same compiler policy, shared runtime, lld     |         20.74 |          30.49 | Reject: shared runtime alone does not fix it |
| Package-scoped emission, static runtime, gold |         21.10 |          24.99 | Reject as default: ~18% slower               |
| Package-scoped emission, shared runtime, gold |         20.89 |          21.08 | Retain: invocation spreads overlap           |

The last candidate is the selected **performance-first `bench-unchecked`**
policy. Some representative rows
from its paired comparison:

| Engine / dataset / operation       | Baseline (µs) | Selected (µs) |
| ---------------------------------- | ------------: | ------------: |
| wired-native / twitter / parse     |        170.57 |        170.00 |
| wired-native / twitter / serialize |        399.06 |        399.15 |
| wired-native / canada / parse      |       1434.80 |       1429.59 |
| wired-native / canada / serialize  |       2581.03 |       2586.97 |
| std.json / twitter / parse         |       4130.13 |       4165.49 |
| std.json / canada / parse          |      28410.10 |      28579.60 |

These are **performance preserved**, not a claimed sub-percent speedup. The
static alternative improved `std.json`'s `canada` parse (28.76 → 25.50 ms), but
lost on serialization. That is why `bench-static` is available for explicitly
measured workloads rather than imposed on every benchmark.

A final rebuild of the accepted CSV policy also preserves performance (five
paired invocations; microseconds):

| CSV workload   | Baseline | Accepted |
| -------------- | -------: | -------: |
| Parse 1k rows  |    46.64 |    44.58 |
| Parse 10k rows |   451.84 |   448.27 |
| Sniff 100 rows |    35.76 |    35.57 |

Invocation spreads overlap; these small differences are not the basis for a
universal runtime-speedup claim.

With ordinary multi-object libraries, lld also exposed duplicate strong nested
UI helpers (`dtcg.colorValue.comp`) that gold did not pull into this executable.
Changing archive extraction/linker semantics and blanket object granularity is
not an innocent latency-only change. The runner's known nested-helper workaround
is scoped to **the runner implementation**, not every dependency. No assertion
or UI algorithm was rewritten to make a particular linker win.

## Selected settings and exceptions

All **150 tracked `dub.sdl` files** contain the same generated build-type block,
including standalone benchmarks, bindings, research examples and the root recipe.
DUB resolves custom build types from the selected root, so defining them only in
the monorepo root would not standardize standalone invocations.

| Build type                          | Purpose / policy                                                                                                                |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `unittest`                          | Ordinary `dub test`: debug checks, assertions, LDC line tables; existing package template policies; Linux shared runtime + gold |
| `unittest-debug`                    | Same test policy with full debug information                                                                                    |
| `unittest-cov`, `unittest-cov-ctfe` | Same test/link policy while preserving DUB's ordinary/CTFE coverage options                                                     |
| `checked`                           | Shipping: optimized, inlined, debug information, assertions live; no native CPU requirement                                     |
| `bench`                             | Optimized measurement with ordinary-function assertions retained; required for assertion-dependent workloads                    |
| `bench-unchecked`                   | Performance-first measurement: unittests + release-mode optimization, LDC native `-O3`; Linux shared runtime + gold             |
| `bench-static`                      | Performance-first benchmark variant with static Phobos/druntime; measure before choosing it                                     |

Important boundaries:

- **Tests and shipping are not release builds.** `bench-unchecked` and `bench-static` can remove assertions
  in ordinary functions; it is not a correctness gate or a deployment artifact.
- **Assertion-dependent setup remains supported.** The fuzzy benchmark's setup
  and timed closures contain required calls inside assertions. `bench` therefore
  retains assertions; `bench-unchecked` is explicit rather than silently breaking
  those workloads. The wired Nix wrapper selects `bench-unchecked`, preserving
  its existing measurement protocol. Experiments originally captured with the
  old assertion-disabled `bench` name use the same flags as this new type.
- **DMD keeps shared Phobos + gold on Linux.** An attempted lld switch built
  `versions`, but its executable could not locate `libphobos2.so.0.112`. Keeping
  gold preserves the Nix wrapper's working runtime-library search behavior.
  DMD does not receive LDC-only flags or line-table defaults.
- **Custom calibration types remain explicit exceptions.** `bench-plain` in the
  event-loop suite and `unittest-checked` in the formatter retain their original
  optimization policy and shared/gold linkage. The conformance application's
  `offline` configuration keeps its DMD-specific link settings.
- **Retain package-specific template-emission settings.** An attempted blanket
  unittest `linkonce-templates` policy crashed LDC compiling mir-ion with
  `Type Expression not implemented: __error`. Removing that blanket flag made
  the standalone wired debug build/list work. The final common unittest policy
  changes debug-information generation, **not** every dependency's template
  linkage. `base` and
  `event-horizon-sys` already enable linkonce; wired's `library-inline` retains
  its measured CMI/linkonce pairing. They are explicit compatibility/codegen
  exceptions, not silently erased to imitate the input report. Benchmarks here
  are **not claimed to be linkonce-free**.
- **Keep CMI scoped.** Do not propagate it through benchmark build types to
  mir-ion; the existing wired recipe documents that frontend incompatibility.
- **`allinst`/context-assert configuration exceptions remain local.** In
  particular, the DMD-frontend family deliberately omits flags that break its
  dependency build. The common unittest build type does not force them globally.
- Linux linker switches are compiler/OS gated. Other platforms retain their
  native linkers; those platforms were not benchmarked here.
- Inline single-file recipes are outside the requested `dub.sdl` migration.
  Their existing `checked` shipping declaration remains unchanged.

## Reproduction and limitations

### Correctness validation

| Check                                                       | Result                                                         |
| ----------------------------------------------------------- | -------------------------------------------------------------- |
| Repository suite, `ci --test --no-coverage --fail-fast`     | **58/58 packages passed**                                      |
| `versions` with DMD, including DMD-selected probes          | 167 passed                                                     |
| `versions` with `unittest-debug`                            | 167 passed                                                     |
| `versions` with ordinary coverage                           | 167 passed                                                     |
| Assertion-dependent fuzzy `bench` setup and timed cases     | All five cases completed without row errors                    |
| Original `nix run .#wired-bench -- --light --list-datasets` | All ten light datasets listed                                  |
| Standalone wired debug build/list, including mir-ion        | Built and listed tests after removing blanket template linkage |
| Line-table exception probe                                  | Caller function, file and line retained                        |
| Shipping-mode CI helper, `dub build :ci -b checked`         | Built successfully                                             |

The compiler-compatibility, coverage and fuzzy checks used isolated temporary
build outputs. Their execution times are correctness evidence, **not** part of
the build-time or performance-selection tables.

### Repeating the measurements

The canonical source is
[`standardize-build-settings.d`](../../apps/ci/tools/standardize-build-settings.d).
Regeneration is idempotent and has unit tests. `--check` reports drift without
editing package-specific settings:

```bash
dub run --single apps/ci/tools/standardize-build-settings.d -- --check
```

The measurement tool is
[`build-settings-bench.d`](../../apps/ci/tools/build-settings-bench.d). Compile it
once outside measured intervals, then capture and replay from the **same working
directory**, in the same Nix development shell. Use fresh output directories so appended samples are not mixed:

```bash
dmd apps/ci/tools/build-settings-bench.d -of=/tmp/opencode/build-settings-bench
dub test :wired --force --verbose -- --help > /tmp/opencode/wired-capture.txt 2>&1
/tmp/opencode/build-settings-bench /tmp/opencode/wired-capture.txt /tmp/opencode/wired-compile compile 3
/tmp/opencode/build-settings-bench /tmp/opencode/wired-capture.txt /tmp/opencode/wired-link link 5
/tmp/opencode/build-settings-bench --check-debug-info /tmp/opencode/debug-probe
```

To compare forced dependency rebuilds, capture both configurations using
`--force --verbose`, then replay the full graphs in alternating order:

```bash
/tmp/opencode/build-settings-bench --compare-graph BASELINE_CAPTURE SELECTED_CAPTURE \
  /tmp/opencode/graph-comparison 3
```

Graph mode writes the captured DUB cache paths. Run it only after other builds
have stopped; do not race it against builds using those caches.

For Wild, set `BUILD_STUDY_WILD_DIR` to a directory containing an `ld` symlink
to the chosen Wild executable. The harness uses the C driver's `-B` option;
not every GCC version accepts `-fuse-ld=wild`. It records executable linker
identity with `readelf` and runtime dependencies with `ldd`.

For one-variable optimized screening, capture a successful `-b bench-unchecked`
build and use the harness's `bench` mode. For final whole-build comparisons, preserve each executable
after rebuilding its **entire dependency configuration**, then alternate runs:

```bash
WIRED_BENCH_DATASETS=twitter,canada WIRED_BENCH_ENGINES=wired-native,std.json \
  /tmp/opencode/build-settings-bench --compare /tmp/opencode/wired-pair BASELINE SELECTED 5 \
  --bench --bench-min-time=10
```

Retained build samples and per-invocation benchmark rows are in
[`build-settings-results.json`](./build-settings-results.json). Groups ending
`final`, `final-shared`, and `gold-static` include **rejected candidates**;
`wired-gold-shared` is the accepted JSON comparison. `versions-graph-final` and
groups ending `accepted-final` contain the final test-build measurements;
`dsv-accepted` contains the accepted CSV measurements. Earlier `accepted` and
`versions-graph` groups precede the final template-scope compatibility correction.
The original experiment
directory also retains each compiler/linker command, diagnostic, `.comment`,
`ldd` output and complete runner report. Timed `@workload` windows incidentally
executed by the CSV module were not used to select flags.

Limits: no cold filesystem/package-download or whole-monorepo clean-build
claims, no test-suite-runtime optimization, no cross-platform measurements, no
fully static libc experiment, and no exhaustive whole-program LTO/PGO search.
“Best” means the fastest **working measured policy** at the stated objective,
not proof of a global optimum for every workload or machine. Rebaseline published
benchmark numbers after changing build policy.

## Primary sources

- [DUB applies the root build type to targets](https://github.com/dlang/dub/blob/b1497860edf19f77093ee3ce42e97a2b5d8c08b0/source/dub/project.d#L969-L994),
  removing the unittest option for dependencies. Build-type flags are therefore
  the appropriate scope for test-only compiler policy across the dependency graph.
- [DUB merges package/build settings](https://github.com/dlang/dub/blob/b1497860edf19f77093ee3ce42e97a2b5d8c08b0/source/dub/package_.d).
  Configuration flags append; an empty configuration cannot erase a global flag.
- [LDC's template-linkage options](https://github.com/ldc-developers/ldc/blob/3d5bafdf0e6f0d4619f04baad80d2b8afb6ba8ad/driver/cl_options.cpp#L554-L563).
  `linkonce-templates` is an opt-in linkage policy, not a boolean with a supported
  `=false` inverse in LDC 1.42.
- [LDC's GCC-driver linker integration](https://github.com/ldc-developers/ldc/blob/3d5bafdf0e6f0d4619f04baad80d2b8afb6ba8ad/driver/linker-gcc.cpp).
  Linker selection, default-runtime linkage and LTO are separate choices.
- [DUB build types](https://dub.pm/dub-reference/buildtypes/) and
  [platform selectors](https://dub.pm/dub-reference/platform_specifications/).

The DUB source above is release 1.42.0, a close-version reference rather than a
claim to be the exact source of the installed beta executable. Experimental
commands use the installed binaries and validate actual behavior.
