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

| Oracle                   | Covers                             |
| ------------------------ | ---------------------------------- |
| 1. dub agreement         | BGR1–BGR7, BGV1–BGV2, invariant 4  |
| 2. build equivalence     | BGA1–BGA4, BGA7, BGV1–BGV3         |
| 3. manifest completeness | BGK2–BGK4, BGK6                    |
| 4. digest audit          | BGK5, BGK7, BGS6                   |
| 5. relocation            | BGA5–BGA6, BGG4, invariant 3       |
| 6. backend agreement     | BGN1, BGN5                         |
| 7. concurrency           | BGS1–BGS4                          |
| 8. layout lint           | BGV4–BGV5                          |
| 9. key sensitivity       | BGK1, BGK9, BGA4, BGA10, BGT1–BGT3 |
| 10. generators           | BGG1–BGG3, BGG5–BGG6               |
| 11. test actions         | BGX1–BGX3                          |
| 12. Nix inputs           | BGN2–BGN4                          |
| 13. hidden edges         | BGR8, BGK8                         |
| 14. task exposure        | BGA8, invariant 7                  |
| 15. pinned test runner   | BGT4                               |
| 16. publication faults   | BGA7, BGA9, BGS2, BGS6             |
| 17. store lifecycle      | BGS1, BGS5, BGS7, BGS10            |
| 18. miss explanation     | BGS8                               |
| 19. determinism check    | BGS9                               |
| 20. planning read set    | BGP1                               |

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
   check separately that no source of the variant mentions any of them. Until
   pruning lands (E2), E1 compares unpruned, faithful settings, so this step
   removes nothing.

**Falsifying scenarios:**

- one fixture recipe per supported directive;
- a platform-suffixed setting that applies on one platform only;
- a `subConfiguration` chosen two levels down;
- a `sourceLibrary` folded into two consumers;
- a build type defined only in the root recipe;
- a root version mentioned by a dependency, which must survive pruning;
- a root version mentioned by no dependency, which must be pruned;
- a root version mentioned only in a `.txt` file under a dependency's string
  import root, which must survive pruning;
- a dependency with a string literal holding `version (` and an inherited
  identifier it never names, which must keep every inherited identifier and
  be reported;
- `isVersion!"Apple"` and `isVersion!"unittest"`, which must pass the lint,
  and `isVersion!"SomeConfigVersion"` outside a `unittest` block, which must
  fail planning with its location;
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
3. Corrupt a store entry three ways: truncate a declared output, which the
   next lookup must detect by its size; delete one, which the next lookup must
   detect by its absence; and flip a byte without changing the size, which a
   lookup with the hash-sample fraction set to one, and `ci cache verify`,
   must detect. Each detected entry must be removed and rebuilt.
4. **The clock:** on a file system whose clock is set apart from the host's
   (a network mount, or a FUSE mount that adds an offset), repeat step 1. The
   rehash must still happen. Set a file's modification time in the future:
   every read must rehash it and report it.
5. **A mid-compile edit (BGK7, proposed):** run a compile whose compiler is
   wrapped to pause after reading a fixture module, rewrite that module during
   the pause, then let it finish. The edit must be detected. Under remedy (a)
   the result must not be in the store and the run must report
   `unstable input`; under remedy (b) the published result must equal a cold
   build of the edited tree.

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
4. **The losing producer (BGS3):** two processes compute one compile key with
   a wrapped compiler that appends a counter to its object, so their outputs
   differ, and each links a test binary from it. The loser must report the
   action as nondeterministic, naming the key and the object. Both links must
   consume the winner's object, so both link keys are equal and name bytes
   the store holds.
5. **Lookup at admission (BGS4):** plan a graph, publish one of its compiles
   from another process before the executor admits it, then run. The compile
   must hit.

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

**Search inputs (BGK9):**

- Create a `.pc` file for a library in a `PKG_CONFIG_PATH` directory searched
  before the one that held it, and a library file in an `-L` directory
  searched before the one that held it. Each must change the keys of the
  actions using that query or link.
- A `pragma(lib, "z")` in a linked module: creating `libz` earlier on the
  search order must change the link key.

**Format version (BGK1):** change the manifest extraction's version alone. Every
compile's result key must change.

**Early cutoff (BGA10):** edit a comment in a `sparkles:base` module without
moving any line. The compiles that read it rerun; every archive, link and test
key downstream must be unchanged. `ar tv` on each archive must show zero
timestamps, owners and groups, and no archive may be thin.

**Environment probes (BGA4):**

- Put a recording `cc` and `ld` first on the executor's own `PATH`. No action
  may call them, and every compile and link must run the absolute driver and
  linker its toolchain identity names.
- Set `DFLAGS`, `CC` and `NIX_CFLAGS_COMPILE` in the executor's environment.
  No key and no output may change.
- Compile a D module and an ImportC source that embed `__DATE__`, `__TIME__`
  and `__TIMESTAMP__`, on two days with the fixture files' modification times
  changed. The outputs must be byte-identical.

### Oracle 10: generators

**Method:**

1. Edit a shader source. Its generate action and the compiles that read its
   outputs must rerun, and nothing else.
2. Leave stale files in the in-tree generated directory. The compile must
   read the generator's outputs instead.
3. Check the generator's invocation contains no staleness flag and no `dub`
   call.
4. **Imports (BGG5):** edit a D module that a shader module imports, without
   touching the shader module. The generate action must rerun; editing a
   module it does not import must not rerun it.
5. **Host tools (BGG6):** plan a WebAssembly variant that reads generated
   files. Its generator's tool must be planned as a host application
   variant.

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
4. **Narrowing (BGN2):** with a manifest that resolved `m` to `b/m.d` under
   `-Ia -Ib` in the local store, create `a/m.d`. The backend must not narrow,
   and the build must compile `a/m.d`. With an unchanged tree, a narrowed
   build must be rebuilt with full roots if its dependency output names a file
   outside its inputs. No narrowed derivation's output may reach the binary
   cache the run pushes to.

### Oracle 13: hidden edges

**Method:** a fixture recipe with `importPaths "../other/src"` and no
`dependency` must be reported, with its recipe line. So must the cycle-safe
packages' source includes of the test runner, since BGR8 and D15 allow no
exception, until E1a removes them.

**Execution-time reaches (BGK8):** a fixture package's ImportC source with
`#include "../other/include/x.h"`, where `other` is a package it does not
depend on, must fail the compile, naming the header and `other`, and leave no
result in the store. The same include through a declared dependency's C import
root must pass.

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

**Edges are not inputs (invariant 7):** plan a package's coverage fallback
(the plain compile behind an `onFailure` edge) and the same package's plain
test. The plain compile must have one key in both graphs, and one result
serves both.

### Oracle 16: publication faults

**Source of truth:** BGA9's table of which endings publish, applied to injected
endings whose cause the test controls.

**Method:**

1. A fixture module with a type error: the first compile must publish a
   failed result. A second run, and a run in a second worktree, must not
   execute the compile and must print the same diagnostics and exit status.
2. A failing test: its result must not be in the store, and the next request
   must run it.
3. End a compile by `SIGKILL`, by its timeout, and by a fail-fast
   cancellation. None may leave a result, and the next run must compile.
4. A wrapped compiler that exits zero without writing its object: the action
   must fail and publish nothing.
5. Make publication fail: a full file system (a small loop-mounted store), a
   read-only `results/`, and a rename that fails. The action's outcome and the
   run's verdict must equal those of a run whose publication succeeded, and
   each failure must be reported.
6. Cut power to a virtual machine between a publishing rename and the next
   write, then look the key up after reboot. The entry must be complete or
   absent.

### Oracle 17: store lifecycle

**Method:** run a store with small bounds, a few MiB of results and a few KiB
of records, against a scripted sequence of publications, lookups and leases.

1. **Recency:** publish A then B, create a lease on A, end it, and exceed the
   bound. B must be evicted before A. Changing A's access time must not change
   the order.
2. **Off the publish path:** a publication that crosses the bound must
   complete before eviction starts, and eviction must stop at 90 % of the
   bound.
3. **Leased overshoot:** hold leases on more than the bound. Nothing leased
   may be evicted, the overshoot must be reported, and eviction must resume
   when the leases end.
4. **Digest records:** evict an archive whose link result survives, then
   request the link. The link must hit without rebuilding the archive. Then
   request a test of a new binary that links the archive: the archive must
   rebuild, with the digests its record holds.
5. **Separate bounds:** publish results until the results bound evicts. No
   manifest list or record may be evicted for it. Fill the records bound with
   manifest lists: lists whose results are gone must go first.
6. **Operations (BGS7):** remove by key, task, package and toolchain identity,
   each against a store holding entries of two packages and two toolchains.
   Exactly the named entries must move to `trash/`. Replace a result: the new
   entry must be published and the old one must be in `trash/`.
7. **`CACHEDIR.TAG`:** the store's top directory and `ci`'s `runs/` directory
   must each hold a tag file whose signature line the specification defines.
8. **Format versions (BGS10):** run two builds of the graph with different
   layout versions on one machine. Each must use its own `v<N>/` directory.
   Write an entry with an unknown format version: lookup must miss and leave it
   in place. Garbage collection must remove an older layout's directory only
   when no lease in it is live.

### Oracle 18: miss explanation

**Source of truth:** the substitution that oracle 9 made, which the test knows.

**Method:** for each substitution of oracle 9, look the affected action up
after a run that published it. The miss must be classed `declared` and must
name the substituted component, and only that one. Then:

- edit a file a manifest lists: the miss must be classed `manifest` and must
  name that file;
- create a file at an absent candidate: it must be classed `manifest` and must
  name that path;
- evict the result and its record: it must be classed `evicted`.

`ci cache explain <task>` must print the same classification and execute
nothing. A redacted environment value in a fixture action must appear in the
stored preimage only as its digest.

### Oracle 19: determinism check

**Source of truth:** fixture actions whose determinism the test controls.

**Method:**

1. A deterministic compile: the check must pass, and the private store must be
   gone afterwards. The shared store must hold no new entry, and the run must
   push nothing to a binary cache.
2. A compile through a wrapper that writes the time into its object: the check
   must fail, name the key and the object, and remove the published result.
3. A compile whose published result was planted with different bytes under
   the right key: the check must fail, which shows it executes the action
   rather than reading the store. With lookup re-enabled in the check, the
   same fixture passes, which is the revert check.
4. The sample (CIC13): for a fixed commit id and plan, the sampled actions
   must be the same on two runs, and must differ for another commit id.

### Oracle 20: planning read set

**Source of truth:** the system call trace of planning.

**Method:**

1. Plan the repository's test selection under
   `strace -f -e trace=%file`. Every file planning opened and every failed
   lookup must be in the read set, and so must every environment variable the
   planner's driver read.
2. Edit a sample of files outside the read set, one at a time, and re-plan.
   No such edit may change the plan.
3. **CIC5:** every path in the read set outside package directories must lie
   under one of `ci`'s invalidators. Remove an invalidator from the list: the
   check must fail, naming a path it covered.

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

| Directive or form                                                               | Used by                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| DUB variable `$ARCH` (in `dflags`)                                              | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                         |
| DUB variable `$DC` (in `preGenerateCommands`)                                   | registry: `dmd:lexer`                                                                                                                                                                                                                                                                               |
| DUB variable `$DUB_EXE` (in `preGenerateCommands`)                              | registry: `dmd:lexer`                                                                                                                                                                                                                                                                               |
| DUB variable `$DUB` (in `configuration/preGenerateCommands`)                    | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                 |
| DUB variable `$PACKAGE_DIR` (in `configuration/preGenerateCommands`)            | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                 |
| DUB variable `$PACKAGE_DIR` (in `dflags`)                                       | single-file example: `valgrind-attribution.d`, `valgrind-client-requests.d`, `valgrind-memcheck-catch.d`                                                                                                                                                                                            |
| DUB variable `${PACKAGE_DIR}` (in `preGenerateCommands`)                        | registry: `dmd:lexer`                                                                                                                                                                                                                                                                               |
| `authors`                                                                       | 65 in-repo: `sparkles`, `sparkles:android`, `sparkles:appearance`, …; 6 registry: `bolts`, `dmd`, `eve`, …                                                                                                                                                                                          |
| `buildType/buildOptions`                                                        | all 69 in-repo; registry: `optional`; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                          |
| `buildType/buildOptions` value `coverageCTFE`                                   | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType/buildOptions` value `coverage`                                       | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType/buildOptions` value `debugInfo`                                      | all 69 in-repo; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                                |
| `buildType/buildOptions` value `debugMode`                                      | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType/buildOptions` value `inline`                                         | all 69 in-repo; registry: `optional`; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                          |
| `buildType/buildOptions` value `optimize`                                       | all 69 in-repo; registry: `optional`; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                          |
| `buildType/buildOptions` value `releaseMode`                                    | all 69 in-repo; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                   |
| `buildType/buildOptions` value `unittests`                                      | all 69 in-repo; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                   |
| `buildType/dflags@platform`                                                     | all 69 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                         |
| `buildType/dflags`                                                              | all 69 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                         |
| `buildType/lflags@platform`                                                     | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType/lflags`                                                              | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType`                                                                     | all 69 in-repo; registry: `optional`; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                          |
| `buildType` named `bench-static`                                                | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `bench-unchecked`                                             | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `bench`                                                       | all 69 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                         |
| `buildType` named `checked`                                                     | all 69 in-repo; 204 single-file example: `agent-tooling.d`, `batched-submission.d`, `binfmt-magic-match.d`, …; 45 Markdown example: `README.md:129`, `README.md:78`, `binary-formats/asn1.md:220`, …                                                                                                |
| `buildType` named `unittest-checked`                                            | in-repo: `sparkles:dmd-fmt`                                                                                                                                                                                                                                                                         |
| `buildType` named `unittest-cov-ctfe`                                           | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `unittest-cov`                                                | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `unittest-debug`                                              | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `unittest-release`                                            | registry: `optional`                                                                                                                                                                                                                                                                                |
| `buildType` named `unittest`                                                    | all 69 in-repo                                                                                                                                                                                                                                                                                      |
| `buildType` named `wasm-lto`                                                    | in-repo: `sparkles:table-wasm`, `sparkles:text-wasm`                                                                                                                                                                                                                                                |
| `configuration/buildRequirements`                                               | in-repo: `sparkles:base`, `sparkles:event-horizon-sys`                                                                                                                                                                                                                                              |
| `configuration/buildRequirements` value `disallowDeprecations`                  | in-repo: `sparkles:base`, `sparkles:event-horizon-sys`                                                                                                                                                                                                                                              |
| `configuration/cImportPaths`                                                    | in-repo: `sparkles:profiling`                                                                                                                                                                                                                                                                       |
| `configuration/dependency@path`                                                 | 58 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:build-primitives`, …; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                  |
| `configuration/dependency@version`                                              | in-repo: `sparkles:raylib-text`, `sparkles:terminal`, `sparkles:terminal-view`                                                                                                                                                                                                                      |
| `configuration/dependency`                                                      | 58 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:build-primitives`, …; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                  |
| `configuration/dflags@platform`                                                 | in-repo: `sparkles:table-wasm`, `sparkles:text-conformance`, `sparkles:text-wasm`, `sparkles:wired`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                    |
| `configuration/dflags`                                                          | 64 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; registry: `optional`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                        |
| `configuration/excludedSourceFiles`                                             | 15 in-repo: `sparkles:build-primitives`, `sparkles:diagram`, `sparkles:hue`, …                                                                                                                                                                                                                      |
| `configuration/importPaths@platform`                                            | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                         |
| `configuration/importPaths`                                                     | 22 in-repo: `sparkles:android`, `sparkles:base`, `sparkles:ci`, …; registry: `optional`                                                                                                                                                                                                             |
| `configuration/lflags@platform`                                                 | in-repo: `sparkles:base`, `sparkles:fuzzy`, `sparkles:table-wasm`, `sparkles:text-wasm`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                |
| `configuration/lflags`                                                          | 5 in-repo: `sparkles:base`, `sparkles:fuzzy`, `sparkles:profiling`, …; registry: `raylib-d`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                            |
| `configuration/libs@platform`                                                   | in-repo: `sparkles:event-horizon`, `sparkles:wsi`                                                                                                                                                                                                                                                   |
| `configuration/libs`                                                            | 9 in-repo: `sparkles:event-horizon`, `sparkles:font`, `sparkles:font-oracle`, …; registry: `raylib-d`                                                                                                                                                                                               |
| `configuration/mainSourceFile`                                                  | in-repo: `sparkles:text-lab`                                                                                                                                                                                                                                                                        |
| `configuration/platforms`                                                       | in-repo: `sparkles:event-horizon`, `sparkles:terminal`, `sparkles:text-lab`, `sparkles:wsi`                                                                                                                                                                                                         |
| `configuration/platforms` value `android`                                       | in-repo: `sparkles:event-horizon`, `sparkles:terminal`, `sparkles:text-lab`, `sparkles:wsi`                                                                                                                                                                                                         |
| `configuration/preGenerateCommands`                                             | in-repo: `sparkles:ui`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                 |
| `configuration/sourceFiles@platform`                                            | in-repo: `sparkles:android`, `sparkles:wsi`                                                                                                                                                                                                                                                         |
| `configuration/sourceFiles`                                                     | in-repo: `sparkles:android`, `sparkles:font-oracle`, `sparkles:raylib-text`, `sparkles:wsi`                                                                                                                                                                                                         |
| `configuration/sourcePaths`                                                     | 22 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:core-cli`, …; registry: `eve`, `optional`                                                                                                                                                                                                     |
| `configuration/stringImportPaths`                                               | in-repo: `sparkles:ui`, `sparkles:ui-app`, `sparkles:vulkan-wsi`                                                                                                                                                                                                                                    |
| `configuration/subConfiguration`                                                | 12 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:doc-view`, …; single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, `fiber-echo.d`                                                                                                                 |
| `configuration/targetName`                                                      | 5 in-repo: `sparkles:dmd-fmt`, `sparkles:table-wasm`, `sparkles:terminal`, …                                                                                                                                                                                                                        |
| `configuration/targetType`                                                      | 68 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; registry: `bolts`, `eve`, `optional`, `raylib-d`; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                      |
| `configuration/targetType` value `dynamicLibrary`                               | in-repo: `sparkles:hue`, `sparkles:terminal`, `sparkles:text-lab`                                                                                                                                                                                                                                   |
| `configuration/targetType` value `executable`                                   | 15 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:dmd-fmt`, …; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                                                                             |
| `configuration/targetType` value `library`                                      | 52 in-repo: `sparkles:appearance`, `sparkles:base`, `sparkles:build-primitives`, …; registry: `bolts`, `eve`, `optional`, `raylib-d`                                                                                                                                                                |
| `configuration/targetType` value `sourceLibrary`                                | 19 in-repo: `sparkles:android`, `sparkles:doc-view`, `sparkles:docs`, …                                                                                                                                                                                                                             |
| `configuration/versions`                                                        | 15 in-repo: `sparkles:base`, `sparkles:dmd-fmt`, `sparkles:event-horizon`, …; registry: `raylib-d`                                                                                                                                                                                                  |
| `configuration`                                                                 | 68 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; registry: `bolts`, `eve`, `optional`, `raylib-d`; 5 single-file example: `batched-submission.d`, `cross-thread-wake.d`, `cross-worker-channel.d`, …                                                                      |
| `configuration` named `unittest`                                                | 68 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; registry: `eve`, `optional`, `raylib-d`; single-file example: `ratatui-colors-rgb.d`                                                                                                                                     |
| `copyright`                                                                     | 55 in-repo: `sparkles`, `sparkles:appearance`, `sparkles:base`, …; 6 registry: `bolts`, `dmd`, `eve`, …                                                                                                                                                                                             |
| `debugVersions`                                                                 | single-file example: `valgrind-client-requests.d`                                                                                                                                                                                                                                                   |
| `dependency@path`                                                               | 54 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; 5 registry: `eve:bench`, `eve:dedis`, `eve:httpc`, …; 157 single-file example: `agent-tooling.d`, `async-cancel.d`, `batched-submission.d`, …; Markdown example: `goldens/code-tall.md:6`                                |
| `dependency@platform`                                                           | in-repo: `sparkles:appearance`; registry: `eve:tls`                                                                                                                                                                                                                                                 |
| `dependency@repository`                                                         | in-repo: `sparkles:dmd-fmt`, `sparkles:dmd-lsp`; 10 single-file example: `eve_channel.d`, `eve_concurrency.d`, `eve_deadline.d`, …                                                                                                                                                                  |
| `dependency@version`                                                            | in-repo: `sparkles:dmd-fmt`, `sparkles:dmd-lsp`, `sparkles:wired`; 5 registry: `dmd`, `dmd:frontend`, `dmd:lexer`, …; 70 single-file example: `ec_channel.d`, `ec_concurrency.d`, `ec_deadline.d`, …; 119 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                    |
| `dependency`                                                                    | 54 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; 11 registry: `dmd`, `dmd:frontend`, `dmd:lexer`, …; 217 single-file example: `agent-tooling.d`, `async-cancel.d`, `batched-submission.d`, …; 120 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …  |
| `dependency` as a version string                                                | registry: `optional`, `raylib-d:install`                                                                                                                                                                                                                                                            |
| `description`                                                                   | 68 in-repo: `sparkles`, `sparkles:android`, `sparkles:appearance`, …; 11 registry: `bolts`, `dmd`, `eve`, …                                                                                                                                                                                         |
| `dflags@platform`                                                               | all 69 in-repo; registry: `dmd:compiler`; 9 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                                            |
| `dflags`                                                                        | all 69 in-repo; registry: `dmd:compiler`; 52 single-file example: `app-probe.d`, `asan-global-overflow.d`, `asan-heap-uaf.d`, …; 5 Markdown example: `base/buffer.md:241`, `base/buffer.md:294`, `explanation/buffer.md:177`, …                                                                     |
| `excludedSourceFiles`                                                           | in-repo: `sparkles:font-oracle`, `sparkles:profiling`; registry: `dmd:frontend`, `raylib-d`                                                                                                                                                                                                         |
| `importPaths`                                                                   | 43 in-repo: `sparkles:appearance`, `sparkles:base`, `sparkles:build-primitives`, …; 13 registry: `bolts`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                         |
| `lflags@platform`                                                               | in-repo: `sparkles:wsi`                                                                                                                                                                                                                                                                             |
| `lflags`                                                                        | in-repo: `sparkles:wsi`; single-file example: `elf-note-buildid.d`                                                                                                                                                                                                                                  |
| `libs@platform`                                                                 | in-repo: `sparkles:android`, `sparkles:wsi`; 6 registry: `eve`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                                                         |
| `libs`                                                                          | 10 in-repo: `sparkles:android`, `sparkles:font-oracle`, `sparkles:ghostty`, …; 7 registry: `eve`, `eve:bench`, `eve:dedis`, …; 7 single-file example: `harfbuzz-shape-features.d`, `ligature-cells.d`, `outline-sink-raster.d`, …                                                                   |
| `license`                                                                       | all 69 in-repo; 6 registry: `bolts`, `dmd`, `eve`, …                                                                                                                                                                                                                                                |
| `mainSourceFile`                                                                | 6 in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:nix-eval`, …                                                                                                                                                                                                                                    |
| `name`                                                                          | all 69 in-repo; all 16 registry; all 290 single-file example; all 185 Markdown example                                                                                                                                                                                                              |
| `platforms`                                                                     | 201 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                                                                                                                              |
| `platforms` value `linux`                                                       | 190 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                                                                                                                              |
| `platforms` value `osx`                                                         | 11 single-file example: `batched-submission.d`, `contributor-probe.d`, `cross-thread-wake.d`, …                                                                                                                                                                                                     |
| `platforms` value `posix`                                                       | 5 single-file example: `color-scheme-probe.d`, `component-walk.d`, `fd-remove-tree.d`, …                                                                                                                                                                                                            |
| `preGenerateCommands@platform`                                                  | registry: `dmd:compiler`                                                                                                                                                                                                                                                                            |
| `preGenerateCommands`                                                           | registry: `dmd:compiler`, `dmd:lexer`                                                                                                                                                                                                                                                               |
| `sourceFiles`                                                                   | in-repo: `sparkles:ghostty`; registry: `dmd:lexer`, `dmd:parser`                                                                                                                                                                                                                                    |
| `sourcePaths`                                                                   | 10 in-repo: `sparkles:dql`, `sparkles:input`, `sparkles:metadata`, …; 14 registry: `bolts`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                                       |
| `stringImportPaths`                                                             | 5 in-repo: `sparkles:hue`, `sparkles:twoslash`, `sparkles:ui-gallery`, …; registry: `dmd:compiler`, `dmd:frontend`, `dmd:lexer`                                                                                                                                                                     |
| `subConfiguration`                                                              | in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:ui-gallery`, `sparkles:ui-vulkan`                                                                                                                                                                                                                 |
| `subPackage` as a path                                                          | in-repo: `sparkles`; registry: `eve`, `raylib-d`                                                                                                                                                                                                                                                    |
| `subPackage` as an inline block                                                 | registry: `dmd`                                                                                                                                                                                                                                                                                     |
| `targetName`                                                                    | 9 in-repo: `sparkles:ci`, `sparkles:hue`, `sparkles:nix-eval`, …; 5 registry: `dmd:compiler`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                           |
| `targetPath`                                                                    | all 69 in-repo; registry: `bolts`, `optional`; 174 single-file example: `affine-transform.d`, `agent-tooling.d`, `app-probe.d`, …; Markdown example: `goldens/code-tall.md:6`                                                                                                                       |
| `targetType`                                                                    | 31 in-repo: `sparkles:base`, `sparkles:ci`, `sparkles:code-instrumentation`, …; 13 registry: `dmd`, `dmd:compiler`, `dmd:frontend`, …                                                                                                                                                               |
| `targetType` value `executable`                                                 | 12 in-repo: `sparkles:ci`, `sparkles:diagram`, `sparkles:hue`, …; 5 registry: `dmd:compiler`, `eve:bench`, `eve:dedis`, …                                                                                                                                                                           |
| `targetType` value `library`                                                    | 15 in-repo: `sparkles:base`, `sparkles:code-instrumentation`, `sparkles:core-cli`, …; 7 registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`, …                                                                                                                                                      |
| `targetType` value `none`                                                       | registry: `dmd`                                                                                                                                                                                                                                                                                     |
| `targetType` value `sourceLibrary`                                              | in-repo: `sparkles:test-runner`, `sparkles:ui-raylib`, `sparkles:ui-vulkan`, `sparkles:vulkan-wsi`                                                                                                                                                                                                  |
| `toolchainRequirements@dub`                                                     | registry: `dmd`                                                                                                                                                                                                                                                                                     |
| `toolchainRequirements@frontend`                                                | 8 Markdown example: `move-semantics/index.md:158`, `move-semantics/index.md:274`, `move-semantics/index.md:333`, …                                                                                                                                                                                  |
| `toolchainRequirements`                                                         | registry: `dmd`; 8 Markdown example: `move-semantics/index.md:158`, `move-semantics/index.md:274`, `move-semantics/index.md:333`, …                                                                                                                                                                 |
| `version`                                                                       | registry: `bolts`, `optional`, `raylib-d`                                                                                                                                                                                                                                                           |
| `versions`                                                                      | registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`, `dmd:root`                                                                                                                                                                                                                                     |
| dependency on a sibling by `:name`                                              | registry: `dmd`                                                                                                                                                                                                                                                                                     |
| dependency on a sub-package by `pkg:name`                                       | 66 in-repo: `sparkles:android`, `sparkles:appearance`, `sparkles:base`, …; registry: `dmd:frontend`, `dmd:lexer`, `dmd:parser`; 137 single-file example: `agent-tooling.d`, `async-cancel.d`, `batched-submission.d`, …; 120 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, … |
| dependency version spec `*`                                                     | registry: `dmd`, `dmd:frontend`, `dmd:lexer`, `dmd:parser`; 119 Markdown example: `README.md:129`, `README.md:179`, `README.md:221`, …                                                                                                                                                              |
| dependency version spec `~>x`                                                   | in-repo: `sparkles:raylib-text`, `sparkles:terminal`, `sparkles:terminal-view`, `sparkles:wired`; registry: `eve:tls`, `optional`, `raylib-d:install`                                                                                                                                               |
| dependency version spec exact `x.y.z`                                           | in-repo: `sparkles:dmd-fmt`, `sparkles:dmd-lsp`; registry: `raylib-d:install`; 70 single-file example: `ec_channel.d`, `ec_concurrency.d`, `ec_deadline.d`, …                                                                                                                                       |
| empty `sourcePaths`                                                             | registry: `dmd:lexer`, `dmd:parser`                                                                                                                                                                                                                                                                 |
| environment variable `$SPARKLES_ANDROID_MIN_SDK` (in `dflags`)                  | in-repo: `sparkles:android`                                                                                                                                                                                                                                                                         |
| environment variable `$SPARKLES_TRACY_PREFIX` (in `configuration/cImportPaths`) | in-repo: `sparkles:profiling`                                                                                                                                                                                                                                                                       |
| environment variable `$SPARKLES_TRACY_PREFIX` (in `configuration/lflags`)       | in-repo: `sparkles:profiling`                                                                                                                                                                                                                                                                       |
| glob in `configuration/excludedSourceFiles`                                     | in-repo: `sparkles:hue`, `sparkles:terminal-view`, `sparkles:wsi`                                                                                                                                                                                                                                   |
| glob in `excludedSourceFiles`                                                   | registry: `dmd:frontend`                                                                                                                                                                                                                                                                            |
| platform as a JSON key suffix                                                   | registry: `optional`, `raylib-d`, `raylib-d:install`                                                                                                                                                                                                                                                |
| platform as an SDL `platform` attribute                                         | all 69 in-repo; 7 registry: `dmd:compiler`, `eve`, `eve:bench`, …; 10 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                  |
| platform specifier `android`                                                    | 5 in-repo: `sparkles:android`, `sparkles:event-horizon`, `sparkles:terminal`, …                                                                                                                                                                                                                     |
| platform specifier `ldc`                                                        | all 69 in-repo; registry: `optional`; 10 single-file example: `asan-global-overflow.d`, `asan-heap-uaf.d`, `asan-report-capture.d`, …                                                                                                                                                               |
| platform specifier `linux,freebsd`                                              | registry: `eve:tls`                                                                                                                                                                                                                                                                                 |
| platform specifier `linux-dmd`                                                  | all 69 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                         |
| platform specifier `linux-ldc`                                                  | all 69 in-repo; single-file example: `ratatui-colors-rgb.d`                                                                                                                                                                                                                                         |
| platform specifier `linux`                                                      | 5 in-repo: `sparkles:appearance`, `sparkles:base`, `sparkles:event-horizon`, …; registry: `raylib-d`; 190 single-file example: `agent-tooling.d`, `app-probe.d`, `asan-global-overflow.d`, …                                                                                                        |
| platform specifier `osx`                                                        | in-repo: `sparkles:wsi`; registry: `raylib-d`; 11 single-file example: `batched-submission.d`, `contributor-probe.d`, `cross-thread-wake.d`, …                                                                                                                                                      |
| platform specifier `posix`                                                      | registry: `dmd:compiler`, `raylib-d`, `raylib-d:install`; 5 single-file example: `color-scheme-probe.d`, `component-walk.d`, `fd-remove-tree.d`, …                                                                                                                                                  |
| platform specifier `wasi`                                                       | in-repo: `sparkles:table-wasm`, `sparkles:text-wasm`                                                                                                                                                                                                                                                |
| platform specifier `windows`                                                    | in-repo: `sparkles:wsi`; 7 registry: `dmd:compiler`, `eve`, `eve:bench`, …                                                                                                                                                                                                                          |
| recipe as `dub.json`                                                            | registry: `bolts`, `optional`, `raylib-d`, `raylib-d:install`                                                                                                                                                                                                                                       |
| variable escape `$$`                                                            | registry: `raylib-d`                                                                                                                                                                                                                                                                                |

## Evidence ledger

| Requirement | Status                                                                                                                       | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| ----------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BGR1        | verified                                                                                                                     | `parseDubManifest` and `parseDubJsonManifest` in `libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d`, whose tests decode every tracked recipe and every locked registry recipe strictly and reject unknown directives with their line                                                                                                                                                                                                                                                        |
| BGR2        | verified                                                                                                                     | oracle 1 over the 621 requests in scope (`apps/ci/tools/resolve-oracle.d`), zero unaccepted disagreements; the vocabulary table above, regenerated                                                                                                                                                                                                                                                                                                                                                            |
| BGR3        | verified                                                                                                                     | `resolve` in `libs/build-primitives/src/sparkles/build_primitives/resolve/configure.d` and its tests; oracle 1 on every target                                                                                                                                                                                                                                                                                                                                                                                |
| BGR4        | partial: with Nix only; the fetch without Nix is E3's                                                                        | `readDubLocks` and `nixRegistrySources` in `libs/build-primitives/src/sparkles/build_primitives/resolve/registry.d`, and the lock-against-recipe check in `libs/build-primitives/src/sparkles/build_primitives/resolve/project.d`                                                                                                                                                                                                                                                                             |
| BGR5        | verified                                                                                                                     | `resolveLibraries` in `libs/build-primitives/src/sparkles/build_primitives/resolve/libraries.d`; oracle 1's resolved libraries, lflags and dflags against dub's final step (D20)                                                                                                                                                                                                                                                                                                                              |
| BGR6        | verified                                                                                                                     | `loadSingleFileProject` in `libs/build-primitives/src/sparkles/build_primitives/resolve/project.d`; oracle 1 over the examples `ci --example-files` runs and the fences `ci --verify` runs, the comparison snippets apart (D25, proposed)                                                                                                                                                                                                                                                                     |
| BGR7        | verified                                                                                                                     | `apps/ci/tools/resolve-oracle.d` and `apps/ci/tools/dub-resolve-probe.d`: 621 requests, 3651 targets, zero unaccepted disagreements, 52 accepted (D22), 94 refused by both                                                                                                                                                                                                                                                                                                                                    |
| BGR8        | partial: reported; the test-runner source includes remain until E1a, and `ui-app`'s specification reach until D24 is decided | `hiddenEdges` in `libs/build-primitives/src/sparkles/build_primitives/resolve/hidden_edges.d`; the `sparkles:math` dependencies and the DQL test moved into `libs/dql/test`                                                                                                                                                                                                                                                                                                                                   |
| BGV1–BGV5   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGA1–BGA4   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGA5        | partial: oracle 5 steps 1 and 3 by hand, with no build-graph keys (step 2's keys, steps 4 and 5)                             | E0 spike 1 (D18): LDC `8d5c3c8887` with `--ffile-prefix-map=<root>=.`, the `unittest` build type plus `-g`, `-cov` and `-checkaction=context`; `sparkles:base`, `sparkles:event-horizon` and `sparkles:ui` byte-identical across two worktrees and naming neither; test binaries built in one run from the other after the fixes in `libs/base/src/sparkles/base/source_uri.d`, `libs/wired/src/sparkles/wired/sdl/conformance.d` and `apps/shader-compile/src/toolchain_tests.d`; DMD's outputs differ (D19) |
| BGA6–BGA8   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGK1–BGK6   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGS1–BGS7   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGG1–BGG4   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGT1–BGT4   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGX1–BGX3   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| BGN1–BGN5   | unverified                                                                                                                   | —                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
