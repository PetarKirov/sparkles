---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Testing and evidence

This page names the oracle for each obligation in [SPEC.md](./SPEC.md), the
falsifying scenarios that check it, and the evidence recorded so far. An oracle
is the source of the expected result. Each one is chosen to be independent of
the code under test.

| Oracle                   | Covers                            |
| ------------------------ | --------------------------------- |
| 1. dub agreement         | BGR1–BGR7, BGV1–BGV2, invariant 4 |
| 2. build equivalence     | BGA1–BGA4, BGA7, BGV1–BGV3        |
| 3. manifest completeness | BGK2–BGK4, BGK6                   |
| 4. digest audit          | BGK5, BGS6                        |
| 5. relocation            | BGA5–BGA6, BGG4, invariant 3      |
| 6. backend agreement     | BGN1, BGN5                        |
| 7. concurrency           | BGS1–BGS5, BGS7                   |
| 8. layout lint           | BGV4–BGV5                         |
| 9. key sensitivity       | BGK1, BGT1–BGT3                   |
| 10. generators           | BGG1–BGG3                         |
| 11. test actions         | BGX1–BGX3                         |
| 12. Nix inputs           | BGN2–BGN4                         |
| 13. hidden edges         | BGR8                              |
| 14. task exposure        | BGA8                              |
| 15. pinned test runner   | BGT4                              |

## Oracles

### Oracle 1: dub agreement

**Source of truth:** dub, at the revision the flake pins.

**Method:**

1. List every request the repository's commands make for every package in
   scope: test root, dependency library under the `unittest` and `checked`
   build types, application, and each `subConfiguration` a consumer selects.
2. For each, run `dub describe` with the same root, configuration, build type
   and compiler. Where `dub describe` omits a field, obtain dub's resolved
   build settings for the same request by using dub as a library.
3. Compare every resolved field: source files, import, C import and string
   import paths, versions, debug versions, dflags, lflags, libs, target type and
   target name. Compare ordered lists in order and sets as sets. Fields before
   library resolution are compared with `dub describe`; fields after it, such as
   `pkg-config` results, with dub's own `prepareBuildSettings`, called as a
   library.
4. Remove from dub's side the downward-inherited versions that BGV1 prunes, and
   check separately that no source of the variant mentions any of them.

**Falsifying scenarios:**

- one fixture recipe per supported directive;
- a platform-suffixed setting that applies on one platform only;
- a `subConfiguration` chosen two levels down;
- a `sourceLibrary` folded into two consumers;
- a build type defined only in the root recipe;
- a root version mentioned by a dependency, which must survive pruning;
- a root version mentioned by no dependency, which must be pruned;
- an ABI-critical dflag in a root's configuration, which must reach every
  dependency;
- an unsupported directive, which must fail with its location.

**Independence:** dub's resolver is a separate implementation. A shared defect
is possible only for behaviour copied from dub's source, and each such copy is
noted in [decisions.md](./decisions.md).

**Gate:** zero unaccepted disagreements across the repository.

### Oracle 2: build equivalence

**Source of truth:** a dub build of the same request.

**Method:** for each package, build its test root and run the test binary once
through the build graph and once through `dub test`.

**Expected:** the same test names, verdicts and exit status. Binary identity is
not required, because dub orders objects differently.

**Falsifying scenarios:**

- a test that inspects a dependency's version identifier;
- a test that reads a string import;
- a test whose dependency is a `sourceLibrary`;
- an application package whose `mainSourceFile` must be excluded from its test
  root.

### Oracle 3: manifest completeness

**Source of truth:** the compiler's system call trace.

**Method:**

1. On Linux, run each compile under `strace -f -e trace=%file`.
2. Collect every file the compiler or its C preprocessor opened for reading,
   and every lookup that failed with `ENOENT` under an import, C import or
   string import root. A failed lookup of a missing directory is satisfied by
   any absent candidate beneath it.
3. The opened files, excluding the toolchain files BGT1 covers, must be a
   subset of the manifest's file entries. The failed lookups that precede a
   successful resolution must be a subset of its absent candidates.

**Mutation scenarios:**

- editing a file in the manifest changes the result key;
- editing a file of a dependency that the compile did not read does not;
- editing a string import, or an ImportC header two includes deep, changes it;
- creating `a/m.d` when `-Ia -Ib` resolved `m` to `b/m.d` changes it;
- creating a `.di` beside a `.d`, or a `package.d`, changes it;
- creating the module a failed `__traits(compiles, { import opt; })` probed
  changes it.

**Gate:** zero opened files missing from manifests and zero preceding failed
lookups missing from absent candidates, across the repository's compiles.

### Oracle 4: digest audit

**Method:**

1. Rewrite a file while keeping its size and modification time, including a
   rewrite within the file system's timestamp granularity of its digest
   record. The next lookup must rehash it.
2. Force a digest cache hit, then audit it by rehashing.
3. Corrupt a store entry. The next lookup must remove it.

### Oracle 5: relocation

**Method:**

1. Build the same variant in two worktrees at different absolute paths.
2. With LDC, the declared and result keys must be equal and the outputs
   byte-identical. Neither worktree's absolute path may appear in the outputs,
   coverage registrations included.
3. Run the test binary built in worktree A from worktree B. It must pass, and
   every fixture it opens through `__FILE_FULL_PATH__` must be B's.
4. With a compiler that has no prefix map, the keys must differ by the root
   path.
5. Two runs of `ci docs verify` on unchanged examples must produce equal
   result keys for every example compile.

### Oracle 6: backend agreement

**Method:** build a set of variants through both backends, and compare the
outputs for each declared key and manifest.

**Expected:** byte-identical outputs where the action is deterministic. Where
it is not, test binaries that pass and fail identically, with each
nondeterministic action listed with its cause.

### Oracle 7: concurrency

**Method:**

1. Run N processes computing the same keys, with random delays before
   publication, from worktrees on different file systems.
2. Kill a producer between its write and its rename.
3. Run garbage collection concurrently with builds that hold leases, and kill
   a lease holder.

**Expected:**

- every reader sees either no entry or a complete one;
- no publication crosses a file system;
- the killed producer leaves only a staging entry, which garbage collection
  removes;
- eviction never removes an entry whose lease holder is alive, and reclaims the
  lease of a dead one;
- two worktrees alternating between two manifests of one declared key both
  keep hitting.

### Oracle 8: layout lint

**Method:** plant one instance of each BGV4 hazard in a fixture library:

- a field;
- a virtual method;
- a destructor;
- an `enum` value;
- a template with a `version (unittest)` branch;
- an import of a test-only package.

Each must fail planning with its location. Moving the same declaration inside
a `unittest` block must pass.

**Revert check:** with the lint disabled, the field fixture plans and links,
and its test binary misreads the aggregate.

### Oracle 9: key sensitivity

**Method:** for each component of the declared key (BGK1) and each component
BGT1 lists, substitute a variant of it: another argument, environment entry or
recipe file; another compiler build, configuration file, C driver wrapper,
linker or generator binary; another pinned test runner. Every affected key must
change, and no unaffected one may.

### Oracle 10: generators

**Method:**

1. Edit a shader source. Its generate action and the compiles that read its
   outputs must rerun, and nothing else.
2. Leave stale files in the in-tree generated directory. The compile must
   read the generator's outputs instead.
3. Check the generator's invocation contains no staleness flag and no `dub`
   call.

### Oracle 11: test actions

**Method:**

1. Put a `dub` on the test binary's `PATH` that records any call and fails.
   No test binary may call it, and the compile-time-probe and extracted modes
   must still find their import paths and flags.
2. A test that declares no runtime inputs must run on every request.
3. With the Nix backend (E4), a sandboxed result's key must change with the
   kernel release and the CPU model.

### Oracle 12: Nix inputs

**Method:**

1. A cold Nix build of a compile, with no prior manifest, must succeed.
2. After an edit adds a new import within the declared roots, the rebuilt
   derivation must still succeed.
3. A derivation's input set must not contain files outside its declared
   inputs and roots.

### Oracle 13: hidden edges

**Method:** a fixture recipe with `importPaths "../other/src"` and no
`dependency` must be reported. The cycle-safe test-runner integration must
not be.

### Oracle 15: pinned test runner

**Method:**

1. Change the working tree's test-runner implementation. Only that package's
   own test root may rebuild, and every other test binary must still link the
   pinned library.
2. Bump the pin. Every test root's key must change.

### Oracle 14: task exposure

**Method:** plan the same request twice. The task ids, claims and edges must be
identical. Every action edge must be `onSuccess`, and a link's argument vector
must carry its claimed thread count.

## The recipe vocabulary

BGR2's supported set is the vocabulary of the recipes in scope. E0's directive
scan writes it here, one row per directive, attribute, form or variable
reference with the recipes that use each, and oracle 1 checks each row. The
recipes are the root `dub.sdl` and its sub-packages, the packages
`nix/dub-lock.json` and `nix/ci-dub-lock.json` pin, the single-file examples
`ci --example-files` runs, and the single-file programs in tracked Markdown
files' `d` fences. A JSON key is listed under its SDL name, and a JSON platform
suffix as a platform specifier. A nested directive is written as its path
(`configuration/dflags`), an attribute as `directive@attribute`. Regenerate
the table from the repository root, in the dev shell:

```bash
dub run --single apps/ci/tools/scan-recipe-vocabulary.d
```

| Directive or form                                                    | Used by                                                                                                                                                                                                                                                                                                                 |
| -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DUB variable `$ARCH` (in `dflags`)                                   | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                                             |
| DUB variable `$DC` (in `preGenerateCommands`)                        | registry: `dmd:lexer`                                                                                                                                                                                                                                                                                                   |
| DUB variable `$DUB_EXE` (in `preGenerateCommands`)                   | registry: `dmd:lexer`                                                                                                                                                                                                                                                                                                   |
| DUB variable `$DUB` (in `configuration/preGenerateCommands`)         | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                                     |
| DUB variable `$PACKAGE_DIR` (in `configuration/preGenerateCommands`) | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                                     |
| DUB variable `$PACKAGE_DIR` (in `dflags`)                            | single-file example: `valgrind-attribution.d`, `valgrind-client-requests.d`, `valgrind-memcheck-catch.d`                                                                                                                                                                                                                |
| DUB variable `${PACKAGE_DIR}` (in `preGenerateCommands`)             | registry: `dmd:lexer`                                                                                                                                                                                                                                                                                                   |
| `authors`                                                            | 60 in-repo: `sparkles`, `sparkles:android`, `sparkles:base`, …; 9 registry: `bolts`, `dmd`, `during`, …                                                                                                                                                                                                                 |
| `buildType/buildOptions`                                             | all 64 in-repo; registry: `optional`; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                              |
| `buildType/buildOptions` value `coverageCTFE`                        | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType/buildOptions` value `coverage`                            | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType/buildOptions` value `debugInfo`                           | all 64 in-repo; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                                                    |
| `buildType/buildOptions` value `debugMode`                           | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType/buildOptions` value `inline`                              | all 64 in-repo; registry: `optional`; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                              |
| `buildType/buildOptions` value `optimize`                            | all 64 in-repo; registry: `optional`; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                              |
| `buildType/buildOptions` value `releaseMode`                         | all 64 in-repo; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                       |
| `buildType/buildOptions` value `unittests`                           | all 64 in-repo; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                       |
| `buildType/dflags@platform`                                          | all 64 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                                             |
| `buildType/dflags`                                                   | all 64 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                                             |
| `buildType/lflags@platform`                                          | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType/lflags`                                                   | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType`                                                          | all 64 in-repo; registry: `optional`; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                              |
| `buildType` named `bench-static`                                     | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `bench-unchecked`                                  | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `bench`                                            | all 64 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                                             |
| `buildType` named `checked`                                          | all 64 in-repo; 203 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 44 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                                                    |
| `buildType` named `unittest-checked`                                 | in-repo: `sparkles:dmd-fmt`                                                                                                                                                                                                                                                                                             |
| `buildType` named `unittest-cov-ctfe`                                | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `unittest-cov`                                     | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `unittest-debug`                                   | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `unittest-release`                                 | registry: `optional`                                                                                                                                                                                                                                                                                                    |
| `buildType` named `unittest`                                         | all 64 in-repo                                                                                                                                                                                                                                                                                                          |
| `buildType` named `wasm-lto`                                         | in-repo: `sparkles:table-wasm`, `sparkles:text-wasm`                                                                                                                                                                                                                                                                    |
| `configuration/buildOptions`                                         | registry: `during`, `expected`                                                                                                                                                                                                                                                                                          |
| `configuration/buildOptions` value `betterC`                         | registry: `during`, `expected`                                                                                                                                                                                                                                                                                          |
| `configuration/buildRequirements`                                    | in-repo: `sparkles:base`, `sparkles:event-horizon-sys`                                                                                                                                                                                                                                                                  |
| `configuration/buildRequirements` value `disallowDeprecations`       | in-repo: `sparkles:base`, `sparkles:event-horizon-sys`                                                                                                                                                                                                                                                                  |
| `configuration/dependency@path`                                      | 54 in-repo: `sparkles:android`, `sparkles:build-primitives`, `sparkles:ci`, …; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                              |
| `configuration/dependency@version`                                   | in-repo: `sparkles:raylib-text`, `sparkles:terminal`, `sparkles:terminal-view`                                                                                                                                                                                                                                          |
| `configuration/dependency`                                           | 54 in-repo: `sparkles:android`, `sparkles:build-primitives`, `sparkles:ci`, …; registry: `during`, `expected`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                              |
| `configuration/dependency` as a version string                       | registry: `during`, `expected`                                                                                                                                                                                                                                                                                          |
| `configuration/dflags@platform`                                      | in-repo: `sparkles:table-wasm`, `sparkles:text-conformance`, `sparkles:text-wasm`, `sparkles:wired`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                        |
| `configuration/dflags`                                               | 59 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                      |
| `configuration/excludedSourceFiles`                                  | 15 in-repo: `sparkles:build-primitives`, `sparkles:diagram`, `sparkles:hue`, …; registry: `during`                                                                                                                                                                                                                      |
| `configuration/importPaths@platform`                                 | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                                             |
| `configuration/importPaths`                                          | 21 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:ci`, …; registry: `during`, `expected`, `optional`                                                                                                                                                                                                           |
| `configuration/lflags@platform`                                      | in-repo: `sparkles:base`, `sparkles:fuzzy`, `sparkles:table-wasm`, `sparkles:text-wasm`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                    |
| `configuration/lflags`                                               | in-repo: `sparkles:base`, `sparkles:fuzzy`, `sparkles:table-wasm`, `sparkles:text-wasm`; registry: `raylib-d`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                              |
| `configuration/libs@platform`                                        | in-repo: `sparkles:event-horizon`, `sparkles:wsi`                                                                                                                                                                                                                                                                       |
| `configuration/libs`                                                 | 8 in-repo: `sparkles:event-horizon`, `sparkles:font`, `sparkles:font-oracle`, …; registry: `raylib-d`                                                                                                                                                                                                                   |
| `configuration/mainSourceFile`                                       | in-repo: `sparkles:text-lab`                                                                                                                                                                                                                                                                                            |
| `configuration/platforms`                                            | in-repo: `sparkles:event-horizon`, `sparkles:terminal`, `sparkles:text-lab`, `sparkles:wsi`                                                                                                                                                                                                                             |
| `configuration/platforms` value `android`                            | in-repo: `sparkles:event-horizon`, `sparkles:terminal`, `sparkles:text-lab`, `sparkles:wsi`                                                                                                                                                                                                                             |
| `configuration/preGenerateCommands`                                  | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                                     |
| `configuration/sourceFiles@platform`                                 | in-repo: `sparkles:android`, `sparkles:wsi`                                                                                                                                                                                                                                                                             |
| `configuration/sourceFiles`                                          | in-repo: `sparkles:android`, `sparkles:font-oracle`, `sparkles:raylib-text`, `sparkles:wsi`                                                                                                                                                                                                                             |
| `configuration/sourcePaths`                                          | 21 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:core-cli`, …; registry: `during`, `eve`, `expected`, `optional`                                                                                                                                                                                                   |
| `configuration/stringImportPaths`                                    | in-repo: `sparkles:ui`, `sparkles:ui-app`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                                        |
| `configuration/subConfiguration`                                     | 12 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:doc-view`, …; single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, `fiber-echo.d`                                                                                                                                     |
| `configuration/targetName`                                           | 5 in-repo: `sparkles:dmd-fmt`, `sparkles:table-wasm`, `sparkles:terminal`, …; registry: `during`                                                                                                                                                                                                                        |
| `configuration/targetType`                                           | 63 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; 7 registry: `bolts`, `during`, `eve`, …; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                                             |
| `configuration/targetType` value `dynamicLibrary`                    | in-repo: `sparkles:hue`, `sparkles:terminal`, `sparkles:text-lab`                                                                                                                                                                                                                                                       |
| `configuration/targetType` value `executable`                        | 15 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:dmd-fmt`, …; registry: `during`, `expected`; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                                                                 |
| `configuration/targetType` value `library`                           | 47 in-repo: `sparkles:base`, `sparkles:build-primitives`, `sparkles:ci`, …; 6 registry: `bolts`, `during`, `eve`, …                                                                                                                                                                                                     |
| `configuration/targetType` value `sourceLibrary`                     | 19 in-repo: `sparkles:android`, `sparkles:doc-view`, `sparkles:docs`, …; registry: `silly`                                                                                                                                                                                                                              |
| `configuration/versions`                                             | 13 in-repo: `sparkles:base`, `sparkles:dmd-fmt`, `sparkles:event-horizon`, …; registry: `raylib-d`                                                                                                                                                                                                                      |
| `configuration`                                                      | 63 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; 7 registry: `bolts`, `during`, `eve`, …; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                                             |
| `configuration` named `unittest`                                     | 63 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; 5 registry: `during`, `eve`, `expected`, …; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                |
| `copyright`                                                          | 50 in-repo: `sparkles`, `sparkles:base`, `sparkles:build-primitives`, …; 9 registry: `bolts`, `dmd`, `during`, …                                                                                                                                                                                                        |
| `debugVersions`                                                      | single-file example: `valgrind-client-requests.d`                                                                                                                                                                                                                                                                       |
| `dependency@path`                                                    | 50 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; 5 registry: `eve:bench`, `eve:dedis`, `eve:httpc`, …; 116 single-file example: `agent-tooling.d`, `batched-submission.d`, `box.d`, …; Markdown example: `goldens/code-tall.md:6`                                                       |
| `dependency@platform`                                                | in-repo: `sparkles:event-horizon`; registry: `eve:tls`                                                                                                                                                                                                                                                                  |
| `dependency@repository`                                              | in-repo: `sparkles:dmd-fmt`, `sparkles:dmd-lsp`; 10 single-file example: `eve_channel.d`, `eve_concurrency.d`, `eve_deadline.d`, …                                                                                                                                                                                      |
| `dependency@version`                                                 | 31 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:code-instrumentation`, …; 5 registry: `dmd`, `dmd:frontend`, `dmd:lexer`, …; 111 single-file example: `async-cancel.d`, `clock-min-timeout.d`, `cqe-mixed.d`, …; 118 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                       |
| `dependency`                                                         | 56 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; 11 registry: `dmd`, `dmd:frontend`, `dmd:lexer`, …; 217 single-file example: `agent-tooling.d`, `async-cancel.d`, `batched-submission.d`, …; 119 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                |
| `dependency` as a version string                                     | registry: `optional`, `raylib-d:install`                                                                                                                                                                                                                                                                                |
| `description`                                                        | 63 in-repo: `sparkles`, `sparkles:android`, `sparkles:base`, …; 14 registry: `bolts`, `dmd`, `during`, …                                                                                                                                                                                                                |
| `dflags@platform`                                                    | all 64 in-repo; registry: `dmd:compiler`; 9 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                                                                |
| `dflags`                                                             | all 64 in-repo; registry: `dmd:compiler`; 52 single-file example: `app-probe.d`, `asan-global-overflow.d`, `asan-heap-uaf.d`, …; 5 Markdown example: `base/buffer.md:241`, `base/buffer.md:294`, `explanation/buffer.md:177`, …                                                                                         |
| `excludedSourceFiles`                                                | in-repo: `sparkles:font-oracle`; registry: `dmd:frontend`, `raylib-d`                                                                                                                                                                                                                                                   |
| `homepage`                                                           | registry: `during`                                                                                                                                                                                                                                                                                                      |
| `importPaths`                                                        | 38 in-repo: `sparkles:base`, `sparkles:build-primitives`, `sparkles:code-instrumentation`, …; 16 registry: `bolts`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                                   |
| `lflags@platform`                                                    | in-repo: `sparkles:wsi`                                                                                                                                                                                                                                                                                                 |
| `lflags`                                                             | in-repo: `sparkles:wsi`; single-file example: `elf-note-buildid.d`                                                                                                                                                                                                                                                      |
| `libs@platform`                                                      | in-repo: `sparkles:android`, `sparkles:wsi`; 6 registry: `eve`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                                                                             |
| `libs`                                                               | 10 in-repo: `sparkles:android`, `sparkles:font-oracle`, `sparkles:ghostty`, …; 7 registry: `eve`, `eve:bench`, `eve:dedis`, …; 7 single-file example: `harfbuzz-shape-features.d`, `ligature-cells.d`, `outline-sink-raster.d`, …                                                                                       |
| `license`                                                            | all 64 in-repo; 9 registry: `bolts`, `dmd`, `during`, …                                                                                                                                                                                                                                                                 |
| `mainSourceFile`                                                     | 6 in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:nix-eval`, …                                                                                                                                                                                                                                                        |
| `name`                                                               | all 64 in-repo; all 19 registry; all 289 single-file example; all 184 Markdown example                                                                                                                                                                                                                                  |
| `platforms`                                                          | 200 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                                                                                                                                                  |
| `platforms` value `linux`                                            | 190 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                                                                                                                                                  |
| `platforms` value `osx`                                              | 11 single-file example: `batched-submission.d`, `contributor-probe.d`, `cross-thread-wake.d`, …                                                                                                                                                                                                                         |
| `platforms` value `posix`                                            | single-file example: `color-scheme-probe.d`, `component-walk.d`, `fd-remove-tree.d`, `kdeglobals-appearance.d`                                                                                                                                                                                                          |
| `preGenerateCommands@platform`                                       | registry: `dmd:compiler`                                                                                                                                                                                                                                                                                                |
| `preGenerateCommands`                                                | registry: `dmd:compiler`, `dmd:lexer`                                                                                                                                                                                                                                                                                   |
| `sourceFiles`                                                        | in-repo: `sparkles:ghostty`; registry: `dmd:lexer`, `dmd:parser`, `silly`                                                                                                                                                                                                                                               |
| `sourcePaths`                                                        | 9 in-repo: `sparkles:dql`, `sparkles:input`, `sparkles:metadata`, …; 16 registry: `bolts`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                                                            |
| `stringImportPaths`                                                  | 5 in-repo: `sparkles:hue`, `sparkles:twoslash`, `sparkles:ui-gallery`, …; registry: `dmd:compiler`, `dmd:frontend`, `dmd:lexer`                                                                                                                                                                                         |
| `subConfiguration`                                                   | in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:ui-gallery`, `sparkles:ui-vulkan`                                                                                                                                                                                                                                     |
| `subPackage` as a path                                               | in-repo: `sparkles`; registry: `eve`, `raylib-d`                                                                                                                                                                                                                                                                        |
| `subPackage` as an inline block                                      | registry: `dmd`                                                                                                                                                                                                                                                                                                         |
| `targetName`                                                         | 9 in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:nix-eval`, …; 5 registry: `dmd:compiler`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                                               |
| `targetPath`                                                         | all 64 in-repo; registry: `bolts`, `during`, `optional`; 173 single-file example: `affine-transform.d`, `agent-tooling.d`, `app-probe.d`, …; Markdown example: `goldens/code-tall.md:6`                                                                                                                                 |
| `targetType`                                                         | 31 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:code-instrumentation`, …; 15 registry: `dmd`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                                                   |
| `targetType` value `executable`                                      | 12 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:hue`, …; 5 registry: `dmd:compiler`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                                               |
| `targetType` value `library`                                         | 15 in-repo: `sparkles:base`, `sparkles:code-instrumentation`, `sparkles:core-cli`, …; 8 registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`, …                                                                                                                                                                          |
| `targetType` value `none`                                            | registry: `dmd`                                                                                                                                                                                                                                                                                                         |
| `targetType` value `sourceLibrary`                                   | in-repo: `sparkles:test-runner`, `sparkles:ui-raylib`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`; registry: `silly`                                                                                                                                                                                                   |
| `toolchainRequirements@dub`                                          | registry: `dmd`                                                                                                                                                                                                                                                                                                         |
| `toolchainRequirements@frontend`                                     | 8 Markdown example: `move-semantics/index.md:158`, `move-semantics/index.md:274`, `move-semantics/index.md:333`, …                                                                                                                                                                                                      |
| `toolchainRequirements`                                              | registry: `dmd`; 8 Markdown example: `move-semantics/index.md:158`, `move-semantics/index.md:274`, `move-semantics/index.md:333`, …                                                                                                                                                                                     |
| `version`                                                            | 6 registry: `bolts`, `during`, `expected`, …                                                                                                                                                                                                                                                                            |
| `versions`                                                           | registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`, `dmd:root`                                                                                                                                                                                                                                                         |
| dependency on a sibling by `:name`                                   | registry: `dmd`                                                                                                                                                                                                                                                                                                         |
| dependency on a sub-package by `pkg:name`                            | 61 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:build-primitives`, …; registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`; 96 single-file example: `agent-tooling.d`, `batched-submission.d`, `box.d`, …; 111 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                         |
| dependency version spec `*`                                          | registry: `dmd`, `dmd:frontend`, `dmd:lexer`, `dmd:parser`; 110 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                                                                                                                                                                                  |
| dependency version spec `~>x`                                        | 30 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:code-instrumentation`, …; registry: `eve:tls`, `optional`, `raylib-d:install`; 41 single-file example: `async-cancel.d`, `clock-min-timeout.d`, `cqe-mixed.d`, …; 8 Markdown example: `expected/index.md:150`, `expected/index.md:227`, `expected/index.md:23`, … |
| dependency version spec exact `x.y.z`                                | in-repo: `sparkles:dmd-fmt`, `sparkles:dmd-lsp`; registry: `raylib-d:install`; 70 single-file example: `ec_channel.d`, `ec_concurrency.d`, `ec_deadline.d`, …                                                                                                                                                           |
| dependency version spec range `>=x <y`                               | registry: `during`, `expected`                                                                                                                                                                                                                                                                                          |
| empty `sourcePaths`                                                  | registry: `dmd:lexer`, `dmd:parser`                                                                                                                                                                                                                                                                                     |
| environment variable `$SPARKLES_ANDROID_MIN_SDK` (in `dflags`)       | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                                             |
| glob in `configuration/excludedSourceFiles`                          | in-repo: `sparkles:hue`, `sparkles:terminal-view`, `sparkles:wsi`                                                                                                                                                                                                                                                       |
| glob in `excludedSourceFiles`                                        | registry: `dmd:frontend`                                                                                                                                                                                                                                                                                                |
| platform as a JSON key suffix                                        | registry: `optional`, `raylib-d`, `raylib-d:install`                                                                                                                                                                                                                                                                    |
| platform as an SDL `platform` attribute                              | all 64 in-repo; 7 registry: `dmd:compiler`, `eve`, `eve:bench`, …; 10 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                                      |
| platform specifier `android`                                         | 5 in-repo: `sparkles:android`, `sparkles:event-horizon`, `sparkles:terminal`, …                                                                                                                                                                                                                                         |
| platform specifier `ldc`                                             | all 64 in-repo; registry: `optional`; 10 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                                                                   |
| platform specifier `linux,freebsd`                                   | registry: `eve:tls`                                                                                                                                                                                                                                                                                                     |
| platform specifier `linux-dmd`                                       | all 64 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                                             |
| platform specifier `linux-ldc`                                       | all 64 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                                             |
| platform specifier `linux`                                           | in-repo: `sparkles:base`, `sparkles:event-horizon`, `sparkles:fuzzy`, `sparkles:wsi`; registry: `raylib-d`; 190 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                                      |
| platform specifier `osx`                                             | in-repo: `sparkles:wsi`; registry: `raylib-d`; 11 single-file example: `batched-submission.d`, `contributor-probe.d`, `cross-thread-wake.d`, …                                                                                                                                                                          |
| platform specifier `posix`                                           | registry: `dmd:compiler`, `raylib-d`, `raylib-d:install`; single-file example: `color-scheme-probe.d`, `component-walk.d`, `fd-remove-tree.d`, `kdeglobals-appearance.d`                                                                                                                                                |
| platform specifier `wasi`                                            | in-repo: `sparkles:table-wasm`, `sparkles:text-wasm`                                                                                                                                                                                                                                                                    |
| platform specifier `windows`                                         | in-repo: `sparkles:wsi`; 7 registry: `dmd:compiler`, `eve`, `eve:bench`, …                                                                                                                                                                                                                                              |
| recipe as `dub.json`                                                 | 7 registry: `bolts`, `during`, `expected`, …                                                                                                                                                                                                                                                                            |
| variable escape `$$`                                                 | registry: `raylib-d`                                                                                                                                                                                                                                                                                                    |

## Evidence ledger

| Requirement | Status                                                                                           | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BGR1–BGR8   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGV1–BGV5   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGA1–BGA4   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGA5        | partial: oracle 5 steps 1 and 3 by hand, with no build-graph keys (step 2's keys, steps 4 and 5) | E0 spike 1 (D18): LDC `8d5c3c8887` with `--ffile-prefix-map=<root>=.`, the `unittest` build type plus `-g`, `-cov` and `-checkaction=context`; `sparkles:base`, `sparkles:event-horizon` and `sparkles:ui` byte-identical across two worktrees and naming neither; test binaries built in one run from the other after the fixes in `libs/base/src/sparkles/base/source_uri.d`, `libs/wired/src/sparkles/wired/sdl/conformance.d` and `apps/shader-compile/src/toolchain_tests.d`; DMD's outputs differ (D19) |
| BGA6–BGA8   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGK1–BGK6   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGS1–BGS7   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGG1–BGG4   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGT1–BGT4   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGX1–BGX3   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGN1–BGN5   | unverified                                                                                       | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
