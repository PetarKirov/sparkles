---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. Records marked **accepted** were accepted by the owner: D1–D17 on
2026-11-01, in a design interview to rework the `apps/ci` task DAG;
D18–D21, the E0 spike results, on 2026-11-02; and D22–D25, from E1, on
2026-11-06. The records from D30 on answer a review of the
[build-systems catalog](../../../research/build-systems/index.md), and those
marked accepted were accepted on 2026-11-06. D44, routing the graph's file
access through the capability VFS, was accepted on 2026-11-07. Records marked
**proposed** await the owner's decision.

## D1: Own the build instead of isolating dub (accepted)

**Question.** Concurrent dub builds race, and a dub build cannot reuse another
directory's compiled dependencies. Do we isolate each task, or replace the part
of dub that decides what to build?

**Alternatives.**

- A private `DUB_HOME` and build root per task. Safe, but every dependent
  recompiles its whole dependency closure.
- A prepared, read-only dependency snapshot shared by isolated tasks.
- Resolve recipes ourselves and run the compiler directly.

**Choice.** Resolve recipes ourselves. Recipes stay dub recipes, and dub
remains usable for people, editors and `dmd-lsp`.

**Revisit when** dub gains path-independent build identities and content-based
staleness.

## D2: One graph, two backends (accepted)

**Question.** Who executes an action?

**Alternatives.**

- The local executor only, against our own store. Remote builders would then
  need a protocol of our own.
- Nix only: store copies and per-derivation latency on every edit.
- One graph lowered to either.

**Choice.** One graph, two backends, the local one first, because its keys
define what each derivation contains.

**Revisit when** the Nix backend's per-action overhead is measured below the
local backend's on the edit loop. E4's gate takes that measurement.

## D3: Settings from our resolver, checked against dub (accepted)

**Question.** Where do resolved build settings come from?

**Alternatives.**

- `dub describe` at build time: keeps dub's latency and defects in the build
  path.
- Our resolver alone: drifts without a check.
- Our resolver, with dub as a differential oracle.

**Choice.** Our resolver, through `sparkles.wired.sdl`. `dub describe` and dub
used as a library are the oracles.

**Revisit when** the oracle has had no disagreement for a release and dub's
pinned version is frozen.

## D4: One compile unit per package variant, with a read manifest (accepted)

**Question.** What is a compile unit?

**Alternatives.**

- One per package variant, as dub does.
- One per D module: finer reuse, but fragile under D's template-instantiation
  and `-allinst` rules, and more total work.

**Choice.** One compiler invocation per variant, with its dependency output
recording what it read.

**Revisit when** a per-module mode is measured to win on the edit loop. It
would then be added as a variant option.

**Open question.** Whether dependents should key on generated interfaces
(`.di`), so that a body-only edit stops at the dependency's compile, is open:
[D35](#d35-no-interface-cutoff-between-compiles-accepted) declines it until M12
measures the cost.

## D5: Two-step keys with several manifests per declared key (accepted)

**Question.** How do keys reflect inputs that are known only after compiling?

**Alternatives.**

- Keying on whole dependency packages: any edit in `sparkles:base` rebuilds
  every dependent.
- One manifest per declared key: worktrees on different revisions evict each
  other's manifests.
- ccache's direct mode, with a bounded list of manifests per declared key.

**Choice.** The direct mode: a declared key, then a list of manifests, then
result keys.

**Revisit when** profiling shows the manifest checks dominate lookup time.

## D6: SHA-256 and the store location (accepted)

**Question.** Which digest, and where does the store live?

**Alternatives.** BLAKE3, which is faster but needs a binding; SHA-256; a store
per worktree; one per machine.

**Choice.**

- **Digest:** SHA-256 for file contents and keys. Nix's flat and recursive
  content addressing use the same algorithm: a flat path derives from the
  file's SHA-256, while a recursive path needs a NAR hash over its file set,
  which the build graph computes itself. Store-path names and action keys
  are not comparable, and need not be.
- **Store:** one per user and machine, at `$XDG_CACHE_HOME/sparkles/build`.
- **Publication:** atomic.
- **Eviction:** size-bounded LRU.

**Revisit when** hashing shows up in profiles. BLAKE3 can then sit behind the
same digest type.

## D7: Test results are reused only when their inputs are known (accepted)

**Question.** May a passing test be skipped because an identical binary passed
before?

**Alternatives.** Never; by default; on request.

**Choice.** Only when it ran in the Nix sandbox, with the kernel, CPU and system
in its key, or when it declares every runtime input. Otherwise every request
runs it.

**Revisit when** tests declare their runtime inputs throughout the repository.
The planned route is to record them instead
([D42](#d42-test-reuse-through-recorded-runtime-inputs-accepted)).

## D8: Generators are typed nodes (accepted)

**Question.** How do `preGenerateCommands` run?

**Alternatives.** Run the command string as dub does; model it as a typed
action.

**Choice.** A typed generator action:

- An unknown command is an error.
- Staleness flags are dropped.
- The generator's output directory replaces the recipe's in-tree output path.
  This is an intentional divergence from dub, which reads the in-tree
  directory.

**Revisit when** a generator cannot declare its outputs.

## D9: Nix derivations without evaluation (accepted)

**Question.** How does the Nix backend create derivations?

**Alternatives.**

- Generated Nix expressions, evaluated on every build.
- In-process evaluation through `sparkles:nix`, with our own `lib.fileset`
  primops.
- Derivations created directly.

**Choice.** Sources enter the store as file sets the build graph computes
itself. Derivations are created with `nix derivation add`, content-addressed
where enabled.

**Later.** Evaluating a description of the whole CI pipeline in-process through
`sparkles:nix` is a separate use. It needs a primop wrapper the binding lacks.

## D10: The unittest layout rule (accepted)

**Question.** Dependency libraries are compiled without `-unittest`, while the
test roots that consume them import their modules with `version (unittest)`
on. Is that safe?

**Choice.** Only if `version (unittest)` changes nothing a dependent can observe:
visible declarations, aggregate members, template bodies and the bodies of
functions a dependent compiles. Private, non-template helpers that only the
module's unittests use are exempt. A planning lint over the parsed modules
enforces this. `supervise.Run` and `sampling.TreeSampler` are already fixed;
the lint's first run lists the rest, and they are fixed before it gates.

**Revisit when** D gains a way to compile a library's test-only declarations
out of its importers.

## D11: Toolchain identity off Nix (accepted)

**Question.** How is a toolchain identified on a host without Nix?

**Alternatives.** Require Nix; hash the host toolchain's files.

**Choice.** A store toolchain is identified by its store-path closure, wrapper
scripts included. A host toolchain is identified by the digests of its compiler,
configuration, runtime, C driver, libc and linker, cached by file identity.

## D12: Complete dependency output in the LDC fork (accepted)

**Question.** LDC's `--makedeps` lists string imports, but not the headers its C
preprocessor reads, nor the import candidates it probed and found absent. How
does the manifest become complete?

**Alternatives.**

- Run the C preprocessor's dependency pass separately, and accept missing
  negative inputs.
- Key conservatively on whole import roots.
- Extend the compiler.

**Choice.** Extend our LDC fork:

- C headers in `--makedeps`;
- an opt-in output of absent candidates;
- coverage registration that honours the prefix map.

The owner directs that the fork may be changed freely to advance reproducible
incremental builds. A compiler without these extensions falls back to BGK6's
conservative key.

**Revisit when** the extensions are upstreamed, or a rebase of the fork drops
them.

## D13: Prune downward-inherited versions (accepted)

**Question.** dub passes a root's versions down to every dependency, so a root
with a configuration-local version forks its whole dependency closure. How
much of that does a variant key keep?

**Alternatives.**

- **Faithful:** keep every inherited version in the key; little sharing.
- **Diverge:** never pass configuration-level versions down, and lint against
  dependencies that test them.
- **Pruned faithful:** keep an inherited version only where a compiled or
  imported source mentions it.

**Choice.** Pruned faithful, the default. A build option selects the divergent
mode instead, in which configuration-level versions and debug versions never
pass down and the lint rejects a dependency that tests one; build-type options
and ABI-critical flags pass down in both modes. Separately, the repository moves `-checkaction=context`
from each `configuration "unittest"` into the managed `unittest` build type, so
the flag is uniform and forks nothing.

**Revisit when** a version is found that affects code without being named in a
`version` or `debug` condition, for example through a string mixin. That
pattern exists: `sparkles.base.meta.isVersion`
(`libs/base/src/sparkles/base/meta.d:9`) builds its condition in a `mixin`.
[D34](#d34-pruning-sees-string-imports-and-mixed-in-conditions-accepted)
closes the hole without reversing this choice.

## D14: Relocation maps the root to `.` (accepted)

**Question.** How do outputs avoid naming their worktree, given that 53 uses of
`__FILE_FULL_PATH__` open fixtures at run time?

**Alternatives.**

- Map the root to `.`, run test actions in their worktree's root, and make
  `sparkles.base.source_uri` handle relative paths.
- Map debug information only, and key test roots on their worktree.

**Choice.** Map to `.`. It is the only choice under which a test root built in
one worktree runs correctly in another. The E0 relocation spike checks all
uses.

## D15: No hidden source edges (accepted)

**Question.** `libs/ui`, `libs/tui` and `libs/wsi` compile or import other
packages' sources through `importPaths`/`sourcePaths` without a `dependency`.
So selection misses them, and the build graph cannot share those packages'
variants.

**Alternatives.** Derive package edges from such paths; forbid them with a
lint; both.

**Choice.** Forbid them, with BGR8, with no exception: D16 removes the reason the
test-runner integration needed one.

- **Real dependencies:** the recipes gain real dependencies, such as
  `core-cli`, `input`, `tui`, `ui` and `wsi` on `math`.
- **Test-only reaches:** a reach that only a unittest configuration makes, such
  as `tree-sitter`'s tests compiling `syntax`, whose dependency would close a
  cycle, is resolved by moving those tests into the package that can depend on
  both.

## Open questions

None remain from E0:

- **O1:** which resolved fields `dub describe` cannot show. Resolved by D20.
- **O2:** whether LDC removes every worktree path. Resolved by D18: it does.
- **O3:** whether DMD variants share across worktrees at all. Resolved by D19:
  they do not.

## D16: The test runner's implementation is pinned and prebuilt (superseded)

**Superseded** by the test runner's out-of-process model: decisions TRD1 and
TRD9 and requirement TRM8, in `docs/specs/test-runner/`. The runner runs as a
separate process that test binaries talk to through the shim, so no test
binary links its implementation. The pin covers only the standalone runner
that plain `dub test` uses, and a test action's key covers the runner core
inside the `ci` build that runs it (BGT1). The record below was accepted on
2026-11-01 and is kept as history.

**Question.** The test runner's implementation depends on `sparkles:ui` and much
of the repository, while every package's tests depend on the runner. So the
packages in its closure source-include it, a hidden-edge exception that
hides those packages from selection and from sharing.

**Alternatives.**

- Keep the cycle-safe source includes.
- Build the implementation from the working tree as a separate root.
- Build it from a pinned, recent revision of `main`, like a bootstrap
  compiler.

**Choice.** Build it from a pinned revision of this repository, bumped as often
as needed.

- **The seam:** the shim talks to the implementation across an `extern(C)`
  seam, so the shim stays an in-tree `sourceLibrary` and links the pinned,
  prebuilt library.
- **Delivery:** the flake exposes that library, and its import directory, to
  the dev shell and to the build graph as a toolchain component (BGT4).
- **Plain dub:** plain `dub test` links the same library through the shim's
  recipe.

**Revisit when** the runner's implementation sheds its dependencies on the
rest of the repository.

## D17: Library targets see their own C headers (accepted)

**Question.** dub runs `pkg-config` only for executable and dynamic-library
targets. Library targets with ImportC sources compiled only because the Nix dev
shell's ambient `NIX_CFLAGS_COMPILE` put the headers on the C search path,
which BGA4 forbids.

**Choice.** A library target's compiles also receive the `--cflags` of its own
`libs`. This is a recorded divergence from dub, so oracle 1 excludes these
flags from its comparison.

**Revisit when** dub resolves `pkg-config` for library targets.

## D18: LDC relocates with the root mapped to `.` (accepted)

**Question.** E0 spike 1 (O2): with root-relative sources and a prefix map, do
LDC's objects, archives and test binaries name no worktree, and do the
repository's uses of `__FILE_FULL_PATH__` still work?

**Result.** They name none, with the map `--ffile-prefix-map=<root>=.`.

- **Byte-identical outputs:** `sparkles:base`, `sparkles:event-horizon` and
  `sparkles:ui` were each built as a test root with its dependency libraries,
  one compile per target from `dub describe`, with the `unittest` build type
  plus `-g`, `-cov` and `-checkaction=context`, in two worktrees at different
  paths. Their 12, 330 and 246 objects, archives and test binaries were
  byte-identical, and none contained either worktree's path.
- **The map's form:** LDC rejects an empty replacement, so
  `--ffile-prefix-map=<root>/=` is an error. A build that accepts it still
  leaves the debug information's compilation directory absolute, because the
  working directory has no trailing separator to match. Mapping `<root>` to `.`
  maps that directory too. BGA5 now says so.
- **The environment:** the dev shell's `NIX_LDFLAGS` carries
  `-rpath <worktree>/outputs/out/lib`, which puts the worktree into every test
  binary's run path. BGA4 already keeps it out of actions; this is the
  variable that breaks byte identity when it leaks.
- **Generated sources:** dub's test main lives in its cache, under a path
  derived from the package's location. The spike wrote it to a root-relative
  path. A generated source compiled from outside the root names that directory
  in the outputs, so the graph writes generated sources where a map covers
  them.
- **Running elsewhere:** a test binary built in one worktree ran in the other's
  root. Only `sparkles.base.source_uri` failed (fixed, below). One
  `sparkles:event-horizon` sampling test failed under load and passed alone.

**`__FILE_FULL_PATH__`.** Each of the 52 uses in `libs` and `apps` (53 lines,
one a comment) was classified. Then the 19 packages with a use ran `dub test`
from their worktree's root through a compiler that adds the map. Apart from
the three breaking uses below, every test passed. Each package that skipped a
test skipped the same tests in an unmapped run.

| Use                                                                                                      | Count | Mapped                                 |
| -------------------------------------------------------------------------------------------------------- | ----- | -------------------------------------- |
| Reads a fixture, golden or corpus, or runs `git`/`dub` in the working directory                          | 38    | works                                  |
| Probes for the source tree and skips without it                                                          | 7     | works (same skips)                     |
| A tool or benchmark run with `dub run`, outside test actions                                             | 4     | works only from the root               |
| Names the checkout to a process with another working directory (`wired`'s conformance, `shader-compile`) | 2     | breaks: 1 and 21 tests                 |
| Needs an absolute path (`sparkles.base.source_uri`)                                                      | 1     | breaks: `base`'s tests fail to compile |

No test changes its working directory. `terminal-view` and `event-horizon` set
one only for the children they spawn.

**Choice.** Keep D14's map, spelled `--ffile-prefix-map=<root>=.`. The three
breaking uses are fixed instead of keying their variants on the root:

- **`source_uri`:** `resolveSourcePath` keeps a relocated build's relative
  path relative, and `absoluteSourcePath` completes it with the working
  directory at run time. The OSC 8 hooks complete a relative compile-time
  location around the scheme's compile-time prefix and suffix, so they stay
  `@nogc`.
- **The two tests:** they make the checkout's path absolute before they hand
  it to a process or a recipe elsewhere.

Each fix comes with a test that fails in a relocated build of the code before
it. With the fixes, the test binaries of `sparkles:base`, `sparkles:wired` and
`sparkles:shader-compile` were built in one worktree under the map and run from
the other's root, and all their tests passed: 984, 275 and 35.

**Revisit when** LDC's map gains a form that drops the root without a `./`
prefix and still maps the compilation directory.

## D19: DMD variants key on the root (accepted)

**Question.** E0 spike 1 (O3): do relative paths alone make DMD's outputs
independent of the worktree?

**Result.** No. DMD has no prefix map. `sparkles:base` with its dependencies,
compiled with DMD 2.112.1 from root-relative paths in two worktrees, gave
different archives each time:

- **Plain, and with `-cov`:** the one `__FILE_FULL_PATH__` default argument
  (`source_uri`) embeds the absolute path.
- **With `-g`:** every object's compilation directory is the absolute working
  directory, 7,090 occurrences in that archive.

The `unittest` and `checked` build types both turn debug information on.

**Choice.** Every DMD variant takes BGA5's fallback: the repository root's
absolute path is part of its key. DMD variants share within a worktree, never
across worktrees.

**Revisit when** DMD gains a prefix map for debug information and
`__FILE_FULL_PATH__`.

## D20: dub's final step is the oracle's second source (accepted)

**Question.** E0 spike 3 (O1): which resolved fields does `dub describe` not
show, and can the pinned dub be linked to obtain them?

**Result.**

- **What `dub describe` covers:** each target's build settings as dub's
  generator leaves them, after per-package settings, version inheritance,
  sourceLibrary merging and the build type. That covers:
  - source files, and import, C import and string import paths;
  - versions, debug versions, dflags, lflags, and libs by name;
  - build options and requirements;
  - each package's configuration, and the target's type and name.
- **What it cannot show:** everything the compiler's `prepareBuildSettings`
  and `setTarget` compute after that point:
  - the `pkg-config --libs` and `--cflags` results: the `-L`/`-l` link flags
    and the `-P` C preprocessor flags;
  - that a library target drops its `libs` (D17);
  - the flags that build options and versions become;
  - the target flags (`-lib -oq -cleanup-obj`, `-of`);
  - `-relocation-model=pic`, `-vcolumns`, and the compiler's environment;
  - the dependency libraries added to an executable's link;
  - command-line build options other than `lowmem`.
- **The pinned dub as a library:** it links from source:
  - the source is the flake's `dub-sdl-src` input, at the revision the dev
    shell's `dub` is built from;
  - it is compiled with `-i`, and `DubUseCurl` set so that it compiles;
    nothing is downloaded.
- **The probe:** `apps/ci/tools/dub-resolve-probe.d` resolves a package
  offline through a `ProjectGenerator` subclass and applies dub's own final
  step to every target. It sets `GeneratorSettings.cache` itself, because dub
  keeps its cache path package-private.

**Choice.** Oracle 1 compares fields before library resolution with
`dub describe`, and the rest with that final step called as a library. The
flake's `dub-sdl-src` input and the dev shell's `dub` are bumped together.

**Revisit when** `dub describe` reports compiler-ready settings.

## D21: BGR2's supported set is the scanned vocabulary (accepted)

**Question.** E0 spike 4: which directives, attributes, forms and variable
references do the recipes in scope use?

**Result.** `apps/ci/tools/scan-recipe-vocabulary.d` scanned 556 recipes, and
every one parsed, under the `sdlDubRecipe` profile or as JSON:

- the root `dub.sdl` and its 63 sub-packages;
- the 8 packages the two DUB locks pin, with their 11 sub-packages, from the
  flake's `dub-sources`;
- the 289 single-file examples `ci --example-files` runs;
- the 184 single-file programs in tracked Markdown fences.

The vocabulary is in [testing.md](./testing.md#the-recipe-vocabulary).

- **Used beyond BGR2's list:**
  - `preGenerateCommands`: in-repo inside configurations, and in the
    registry's dmd sub-packages;
  - `mainSourceFile`, `debugVersions` and `buildRequirements`;
  - `buildOptions` values, `betterC` among them;
  - `targetType "none"` and `"dynamicLibrary"`;
  - `toolchainRequirements` with `dub` and `frontend`;
  - configuration-level `platforms`;
  - version ranges;
  - a comma-separated platform specifier (`linux,freebsd`).
- **Not used, of BGR2's list:**
  - `dependency`'s `optional` and `default` attributes;
  - the variables `$ROOT_PACKAGE_DIR`, `$<NAME>_PACKAGE_DIR`, `$PLATFORM`,
    `$PLATFORM_POSIX` and `$BUILD_TYPE`.

  They stay supported, as dub defines them, but only oracle 1's fixtures
  exercise them.

- **Environment:** one recipe names an environment variable:
  `$SPARKLES_ANDROID_MIN_SDK`, in `sparkles:android`'s dflags.
- **Globs:** they appear only in `excludedSourceFiles`.

**Choice.** BGR2's supported set is the table, plus BGR2's named items.

**Revisit when** a recipe in scope adopts a directive the table lacks: rerun
the scan, and BGR2's resolution error names it first.

## D22: Resolved paths are normalized (accepted)

**Question.** dub joins a recipe's relative path to its package directory and
keeps the result as written, so `libs/x/../y/src` and `libs/y/src` are two
entries of an import path list. Does the resolver reproduce the spelling?

**Alternatives.** Keep dub's spellings; normalize every path the resolver
joins.

**Choice.** Normalize. A spelling is no input of a compile, and relocation
(D14) needs one spelling per directory. A list then holds the directory once,
where dub may hold it twice: oracle 1 accepts exactly that difference, a
resolver list equal to dub's with its repeats removed.

**Revisit when** a compiler is found to treat two spellings of one directory
differently.

## D23: Behaviour copied from dub (accepted)

**Question.** Oracle 1's independence holds only where the resolver is not a
copy of dub. Which parts are copies?

**Result.** These follow dub's source at the pinned revision, so a defect
there is shared:

- the build-setting merge rules (`BuildSettings.add…`), the option tables and
  `extractBuildOptions` of DMD and LDC, and `enforceBuildRequirements`;
- `getPlatformSettings` and `collectFiles`, `fillWithDefaults`, and
  `getBuildSettings`;
- configuration selection (`getPackageConfigs`) and the topological order;
- `configurePackages`, `mergeFromDependent`, `mergeFromDependency` and
  `filterABICriticalFlags`, the build types (`addBuildTypeSettings`), and
  `addTestRunnerConfiguration`;
- `processVars`, `getVariable` and `expandVars`;
- `resolveLibs` and `applyPkgConfigCFlags`;
- `matchesSpecification`, `VersionRange.fromString` and its version bumps,
  and `checkPlatform`.

They include dub's quirks, kept so that the two agree:

- a platform-qualified setting's groups apply in D associative-array order,
  which the resolver reproduces by grouping into the same kind of array;
- a configuration's `targetType` replaces the top level's even when the
  configuration states none;
- `dependency`'s `platform` attribute and the top-level `platforms` are
  ignored by resolution (`ci` still reads the latter to skip an example);
- a comma-separated platform specifier (`linux,freebsd`) matches no platform;
- a source path naming a variable lists no files.

**Choice.** Keep the copies, and test each through oracle 1's fixtures and
the resolver's own unit tests, which state the expected result independently
of dub's code.

**Revisit when** a disagreement traces to one of these copies.

## D24: A test reads a specification through a link (accepted)

**Question.** `sparkles:ui-app`'s unittest configuration string-imported
`docs/specs/ui-app/resilience.md` through `stringImportPaths
"../../docs/specs/ui-app"`, so that its tests check the scenarios the
specification lists. That directory belongs to no sub-package. BGR8 reports
the reach. How does a test read a specification?

**Alternatives.**

- **A link in the package:** `libs/ui-app/spec/resilience.md` is a committed
  relative symlink to the catalog, and the configuration imports `spec`.
- **A specification package:** `docs/specs/ui-app/dub.sdl` declares a
  `sourceLibrary` that owns the directory, and the unittest configuration
  depends on it.
- **Move the catalog** into `libs/ui-app/` and include it from the
  specification page.

**Choice.** A link in the package, which the owner preferred, because the
catalog stays where the specifications live. Each of its consequences was
checked:

- **The resolver and BGR8:** paths are normalized lexically (D22), so
  `spec` is inside the package, and oracle 13 reports nothing for
  `ui-app`. oracle 1 agrees with dub on the request.
- **dub:** it follows the link. `resilience.catalogMatchesTheSuite` reads
  the catalog through it and passes.
- **Nix:** the flake's source keeps the link as a symlink, and it resolves
  inside the copied tree.
- **Windows:** without `core.symlinks`, Git checks the link out as a text
  file that holds the target path. ui-app's suite is not in the Windows leg
  (`ci/test-windows.sh`), and the tree already holds two such links.
- **The docs build:** the catalog has not moved, so the page is unchanged.

The specification package was rejected: `ci --test` names a sub-package
after its directory, so a package in `docs/specs/ui-app` would run as
`ui-app` a second time, and a source library with no sources cannot be the
root of `dub test`.

The link has one known limit: package selection maps an edit by its path,
so an edit to the catalog itself selects no package, as before.

**Revisit when** ui-app's suite joins the Windows leg, or selection learns
to map a link's target to the package that holds the link.

## D25: The migration comparison snippets (accepted)

**Question.** `ci --example-files` runs
`docs/libs/event-horizon/tutorial/snippets/`, 70 of whose programs depend on
other event loops: vibe-core, eventcore, libasync and Photon from the
registry, and Collie, Kiss and Hunt by `path` into `snippets/.deps/`, which
`apps/ci/tools/prepare-event-horizon-comparisons.d` clones and patches before
the run. Neither DUB lock pins any of them, so BGR4 makes each a resolution
error, and dub, offline, cannot resolve them either. Oracle 1 counts the 70
as refused by both. Are they in scope?

**Alternatives.**

- **Pin them:** add the registry packages and their dependencies to
  `nix/ci-dub-lock.json`, and the three patched checkouts to the flake as
  pinned, patched sources, so that the resolver and an offline dub resolve
  them.
- **Leave them out of scope:** BGR6's single-file packages are those whose
  dependencies the locks pin; the comparison suite keeps running through dub,
  online, until it is pinned.

**Choice.** Leave them out of scope for E1, and pin them when
`ci --example-files` moves onto the build graph. They compare other
libraries' behaviour; none is a dependency of this repository's packages.

**Revisit when** `ci --example-files` moves onto the build graph, or a
comparison snippet's dependency becomes a dependency of a package in scope.

## D30: Deterministic build failures are cached (accepted)

**Question.** BGA7 replays an action's diagnostics on a hit. Is a failing
action's result published at all, and which failures count?

**Alternatives.**

- Publish only successes. Simple, and an edit changes the key anyway.
- Publish every action that exited on its own, tests included.
- Publish compile, archive and link actions that exited on their own, with any
  status; never a test; never an action ended from outside.

**Evidence.** sbt stores a `CachedCompileFailure`
([sbt](../../../research/build-systems/sbt.md)). moon reuses only results that
exited zero and refuses one with missing outputs
([moon](../../../research/build-systems/moon.md)). Rattle discards the failures
of speculative commands ([rattle](../../../research/build-systems/rattle.md)).

**Choice.** The third (BGA9). A compile, archive or link that exits with a
non-zero status is published, and a hit replays its diagnostics and exit
status: a broken worktree switched back and forth, or a second worktree at the
same broken revision, does not recompile the failure. A test failure is never
published. Nothing is published after a signal, a timeout or a cancellation,
because the cause is outside the key.

**Trade-offs.** A failure's manifest is what the compiler read before it
stopped, which is all its diagnostics can depend on. A compiler that writes no
dependency output on failure keys it conservatively (BGK6).

**Revisit when** a replayed failure is found that a cold build of the same key
does not reproduce.

## D31: A source edited during a compile (accepted)

**Question.** A manifest digests each file after the compiler has read it. If
an editor saves a module while a 30–60 s compile runs, the manifest pairs the
new digest with object code built from the old content, and every worktree
reuses that result until it is evicted. How is the edit detected, and what
happens to the result?

**Alternatives.**

- **(a) Check, and don't publish.** Record the inputs' state before the
  compile, check it after, and on a conflict use the outputs for this run
  without publishing them.
- **(b) Rerun until stable.** Run the action again until a run sees no change.
- **(c) Snapshot first.** Ingest the inputs into content-addressed storage,
  hashing while copying, and compile from a view materialized from it. D's
  read set is unknown before the compile, so this stages whole import roots.

**Evidence.** A survey of eighteen tools, read in their sources, sorts them
into families:

- **Hash before, check after, refuse to publish:** Bazel's
  `--guard_against_concurrent_changes` compares a stat proxy (ctime, mtime,
  inode) after execution, rehashes when only ctime changed, and skips the
  upload while keeping the outputs. Its local action cache has no such
  check, which a revert of the edit can exploit. ccache refuses to store when
  an input's times are within 100 ms of the invocation's wall-clock start,
  which leaves a window of that size plus the clock's granularity.
- **Start time on the file system's clock:** Ninja records the time of a file
  written when the command starts, and Zig stats a freshly written probe file
  ([ninja](../../../research/build-systems/ninja.md)).
- **Hash after:** Rattle hashes reads after the command, so an ordinary edit,
  with no revert, leaves a stale result that the next run treats as fresh
  ([rattle](../../../research/build-systems/rattle.md)). A manifest built from
  the compiler's dependency output, digested afterwards, is in this family.
- **The reader reports its digests:** rustc emits the checksums of the bytes
  it read for Cargo's `-Z checksum-freshness`, which makes the record
  consistent by construction.
- **Snapshot first:** Nix builds, Pants and BuildKit read only an ingested
  snapshot, and are safe where ingest hashes in the same pass as the copy
  ([pants](../../../research/build-systems/pants.md),
  [buildkit](../../../research/build-systems/buildkit.md)).
- **No guard:** Turborepo, Nx, Gradle, Buck2 and BuildXL can store, and some
  push, a result under a key that does not describe what the step read
  ([buck2](../../../research/build-systems/buck2.md),
  [buildxl](../../../research/build-systems/buildxl.md)).

**Choice.** (a), as BGK7 states, with (c) as the precondition for sharing
(BGS11):

- **Before:** a stat proxy and digest for every file the previous manifest
  predicts, and a start time from a probe file on the file system's clock.
- **After:** a changed proxy of a predicted file is a conflict, after a rehash
  when only ctime changed; a newly read file with a time at or after the probe
  is a conflict.
- **On a conflict:** the outputs serve this run, and nothing reaches the local
  or any other store, so the next run redoes the action. This is Bazel's
  guard, extended to the local store.
- **Compiler digests:** the LDC fork's dependency output gains a digest of the
  bytes read per file (BGK2), which turns the check into a consistency check.
- **No rerun loop:** rerunning until stable livelocks under an editor's
  autosave. A watch mode may rerun once.
- **Sharing:** a result reaches a shared or remote cache only if it was built
  from a snapshot. The Nix backend's staged store paths are one.

**Trade-offs.** An edit that keeps a file's size within one timestamp tick
escapes the stat check; compiler-reported digests and snapshots close it. A
conflicting run pays for one uncached compile in the next run.

**Revisit when** the local backend gains a remote cache, which then needs
snapshot ingest (BGS11), or when compiling from a snapshot is measured cheap
enough to use locally too.

## D32: Nix input narrowing is kept, constrained (accepted)

**Question.** BGN2 lets the Nix backend narrow a compile's inputs to a manifest
the local store holds. D searches import roots in order, so a file created
earlier on the search path shadows the module the manifest resolved instead of
failing. A narrowed build that omits it succeeds with the wrong module, and
nothing triggers BGN2's retry. Keep narrowing, constrain it, or drop it?

**Alternatives.**

- Drop narrowing: every compile derivation takes its whole roots.
- Keep it as written.
- Keep it, constrained.

**Evidence.** nix-ninja's argument for narrowing is that "the failure mode is a
sandbox compile error, not a wrong cache hit"
([nix-ninja](../../../research/build-systems/nix-ninja.md)), which ordered
search paths break. A discovery record must hold "every input the consumer
will read, including absent-path probes and environment/toolchain facts"
([dynamic-deps-distributed](../../../research/build-systems/dynamic-deps-distributed.md)).
nixception chose "a stable, less precise key over a context-dependent, more
precise one" for a shared cache
([nixception](../../../research/build-systems/nixception.md)).

**Choice.** Keep it, constrained (BGN2): narrow only while every absent
candidate of the manifest is still absent; require the narrowed build's
dependency output to list only files among its inputs, and only absent
candidates that the full roots lack too, or rerun with the full roots; never
push a narrowed derivation to a shared store. The second half of the check is
the one that can fail: inside the sandbox nothing outside the inputs exists to
be read, but a probe can find absent a module the full roots hold.

**Trade-offs.** A narrowed derivation's identity depends on the local store's
history, so it is a local accelerator only. Remote builders and binary caches
see full-root derivations.

**Revisit when** E4 measures how often narrowing applies and what it saves.

## D33: Sandboxed tests record the machine they ran on (accepted)

**Question.** As first written, BGX3 let a sandboxed test's result be reused if
its key covered the kernel release, the CPU and the system type. Nix picks the builder after
the derivation's hash is fixed, so a derivation cannot name the kernel of a
machine not yet chosen. How is a reused result bound to a machine?

**Alternatives.**

- Put the facts in the derivation, through a per-kernel
  `requiredSystemFeatures` tag on each builder.
- Record the facts the test observed in its output, and compare them on reuse.
- A check in the staging helper that refuses to run on a mismatched machine.

**Evidence.** "The hook is policy-free"
([nix-thesis](../../../research/build-systems/nix-thesis.md)), and nixception
does not match action properties against workers
([nixception](../../../research/build-systems/nixception.md)).

**Choice.** Record and compare (BGX3). The test's output holds the kernel
release, CPU model and features, and system type it observed. A reuse
compares them with the machine the test would otherwise run on, and a mismatch
reruns the test without reuse.

**Trade-offs.** A per-kernel feature tag would split the builder pool on every
kernel update. Comparing on reuse costs one read of the output.

**Revisit when** Nix can match derivations to builders by machine facts.

## D34: Pruning sees string imports and mixed-in conditions (accepted)

**Question.** D13 prunes an inherited version that no scanned D file mentions.
A `mixin` makes a condition no file spells out, and a string-imported file can
hold one too. `sparkles.base.meta.isVersion` builds `version (…)` in a `mixin`
from its argument, so the first `isVersion!"<a configuration version>"` would
give a silent wrong hit. Extend the scan, forbid the pattern, or both?

**Alternatives.**

- Scan more: string import roots, and literals that could become conditions.
- Forbid the pattern with a lint.
- Both.

**Evidence.** "a `mixin` produces source text that never becomes a file"
([compile-time-execution](../../../research/build-systems/compile-time-execution.md)).
Bazel, on leaving data out of keys: "every time we've done that, it later
resulted in expensive debugging sessions and bug fixes"
([bazel](../../../research/build-systems/bazel.md)).

**Choice.** Both (BGV1):

- Files under string import roots are scanned as text, whatever their
  extension.
- A `mixin` whose literal arguments, joined, contain `version (` or
  `debug (` makes the variant keep every inherited identifier, and is
  reported. So does a manifest constant initialized with such literals,
  because a constant can carry them to a `mixin` elsewhere. Joining the
  arguments catches a condition split across literals.
- `isVersion`'s own literal is exempt, so the rule does not disable pruning
  for every package that imports `sparkles.base`. Instead a lint fails
  planning on an `isVersion` argument, outside a `unittest` block, that is not
  a predefined version identifier. Every such use in the repository names
  `Apple`. `meta.d`'s own test probes a made-up identifier inside a `unittest`
  block, which compiles only in `sparkles:base`'s test root.

**Trade-offs.**

- **False positives:** a constant such as a formatter's test fixture
  (`sparkles.dmd_fmt.loc_inventory`) keeps its variant's inherited
  identifiers too. Planning reports each one, so such a variant can be fixed
  or accepted knowingly.
- **Ordinary literals are not scanned:** a literal passed to a function, such
  as the DMD frontend's header generator writing `"version ("`, does not
  trigger the rule. Scanning every literal would turn pruning off for every
  variant that imports the frontend.
- **The residual gap:** a CTFE function that assembles a condition from
  literals in its body, for a `mixin` elsewhere, is not seen. The lint covers
  `isVersion`; another such function needs a lint of its own.

**Revisit when** the reported literals cost measurable sharing.

## D35: No interface cutoff between compiles (accepted)

**Question.** BGA2 makes a compile read its dependencies' sources, so a
compile never cuts off another: any edit to a module that a dependent imports
recompiles the dependent, even when only a function body changed. Should
compiles key on generated interface files (`.di`) instead?

**Alternatives.**

- Key dependents on each dependency's `.di` files, generated by a compile.
- Keep reading sources (BGA2), with cutoff only at archives and links
  (BGA10).

**Evidence.** A `.di` still holds template, `auto` and inline bodies, so the
cutoff is partial. Compiling against interfaces changes inlining and makes a
dependent wait for its dependencies' compiles, which BGA2 avoids. Bazel's
interface jars come with the caveat "but error messages can be different"
([semantic-caching](../../../research/build-systems/semantic-caching.md)),
which conflicts with invariant 5.

**Choice.** No interface cutoff. This stays an open question under D4.

**Revisit when** M12 measures how many dependent compiles a body-only edit
triggers, split by whether the edit moved lines.

## D36: The determinism check runs on every CI run (accepted)

**Question.** Invariant 1 assumes each action is deterministic, and the shared
store trusts the first result published for a key. Nothing checks the
assumption. Is the check an opt-in tool, a nightly sampled job, or part of
every CI run?

**Alternatives.**

- An opt-in tool: `ci cache verify --rerun`, run when someone suspects a
  result.
- A nightly job over a sample, once a binary cache shares results.
- A sampled check in every CI run.

**Evidence.** "a determinism check must run cold and unshared, or it tests the
cache", and "Caches hide the defect they are meant to expose"
([reproducibility](../../../research/build-systems/reproducibility.md)). "a
disconnected non-deterministic build can poison a cache until a clean rebuild"
([perfect-dependencies](../../../research/build-systems/perfect-dependencies.md)).

**Choice.** Every CI run (CIC13), through BGS9's check:

- **Cold:** each sampled action runs with its own lookup bypassed, on the
  bytes its published result was keyed on.
- **Unshared:** its outputs go to a private, empty store that is discarded
  afterwards, and never to the shared store or a binary cache.
- **The sample:** four compiles and four other cacheable actions, ordered by
  the digest of the commit id and the result key. The sample rotates with each
  commit and is the same for a rerun of one commit.
- **A difference** fails the run and removes the suspect result.

**Trade-offs.** Up to eight extra actions per run, possibly compiles of
`sparkles:ui`. They run beside the run's tests, after the builds
that produced their inputs. The check sees nondeterminism within one machine
only; a difference between machines needs a shared cache to compare against.

**Revisit when** the check costs more than a few percent of a CI run's wall
time, or a binary cache shares results between machines, which adds the
cross-machine comparison.

## D37: Planning records its read set (accepted)

**Question.** Every run plans from scratch: it resolves every recipe, lexes
every scanned source, runs the layout lint and queries `pkg-config`. Record
what planning reads, memoize it, or neither?

**Alternatives.**

- Neither.
- Record the read set, and use it to check what decides re-planning.
- Record it and memoize content-keyed planning results.

**Evidence.** PIE's no-change build costs 3.3 s against 0.00001 s for
change-driven traversal, "while the Pluto algorithm still needs to check the
entire dependency graph" ([pie](../../../research/build-systems/pie.md)). GN's
regeneration records every file it opened
([gn](../../../research/build-systems/gn.md)), and BuildXL caches its graph
([buildxl](../../../research/build-systems/buildxl.md)).

**Choice.** Record the read set in E2 (BGP1), and check `ci`'s hand-written
invalidator list (CIC5) against it. A content-keyed memo is added only if
no-op planning of the repository's test selection takes more than about one
second. A memo is not persistent scheduler state, which the task DAG excludes.

**Revisit when** a measurement of no-op planning exceeds one second.

## D38: Plain LRU, touched at lease creation (accepted)

**Question.** BGS5 evicts least recently used results, but does not say what
refreshes recency, nor whether several worktrees need a retention policy
beyond it.

**Alternatives.**

- File access times.
- An explicit touch when a lease is created.
- A retention policy that reads every active worktree's graph, so no worktree
  evicts another's working set.

**Evidence.** An access time "is more likely to be externally modified and may
be unavailable on some filesystems", and "a small AC can starve while the CAS
is idle" ([cas-eviction](../../../research/build-systems/cas-eviction.md)).

**Choice.** Plain LRU, with recency refreshed when a lease is created (BGS4).
Manifest lists, digest records and preimages have a bound of their own.

**Revisit when** two active worktrees are seen evicting each other's results.

## D39: A spike on write and network isolation (accepted)

**Question.** Invariant 6 says the source tree is read and never written, and
BGX3 never reuses a test that needs the network. Nothing enforces either. Test
actions run in the worktree's root (BGX1), and some write there: goldens, and
`git init` fixtures. A test that rewrites a file under a string import root
while a compile reads it is a read-after-write hazard that BGK7 would catch in
effect but not name. Should local actions run isolated?

**Alternatives.**

- No isolation: rely on BGA3's private outputs and on review.
- Landlock rules that make the tree read-only and only the action's output
  and task directories writable, and a network namespace without interfaces.
- Tracing writes under `strace` as a lint, or exclusive claims over a root
  that compiles reading it also claim.

**Evidence.** "a policy mechanism is not an observation mechanism"
([sandboxing-overheads](../../../research/build-systems/sandboxing-overheads.md)).
Rattle's rules, "Never write to the same file twice. Never read then write.",
hold between our actions only if writes are confined
([rattle](../../../research/build-systems/rattle.md)).

**Choice.** An E3 spike, framed as isolation and not as a dependency oracle.
Manifests remain the record of what an action read.

- **Question:** can Landlock confine every compile, archive, link and generate
  action's writes to its private directories, and an unshared network
  namespace remove the network, on the kernels CI and developers run, at a
  cost below the noise of a compile?
- **Tests:** list every test action that writes into the tree, and decide for
  each between moving the write into its task directory, a write lint under
  `strace`, and an exclusive claim over the root it writes.
- **Decision criterion:** if the cost is within noise and the kernel supports
  it, local build actions run confined and a violation fails the action;
  otherwise the spike's measurements are recorded and the lint is used.

**Revisit when** the spike's result is recorded here.

## D40: Toolchain store paths are remapped (accepted)

**Question.** Objects record the store paths of druntime and Phobos sources in
debug information and in `__FILE__`, through Phobos' `assert` messages and
templates instantiated in our compiles. Each binary then references the whole
toolchain in its Nix closure. Remap them?

**Alternatives.**

- Leave them: the paths name no worktree, so keys are unaffected.
- Strip debug information from shipped binaries, which leaves `__FILE__`.
- Remap the toolchain's paths to a fixed prefix through the LDC fork's prefix
  map, in our compiles and in the toolchain's own druntime and Phobos.

**Evidence.** nix-cargo-unit measured the same effect in Rust: a store path
baked into one monomorphized standard-library generic pins a ~1.9 GiB
toolchain into a binary's closure
([nix-cargo-unit](../../../research/build-systems/nix-cargo-unit.md)). The
repository's Nix packages already map druntime's and Phobos' assertion paths
out of the store, through `ldc.reproducible`
(`nix/packages/wasm-modules.nix` says so); the build graph's actions do not
go through it.

**Choice.** Remap (BGA11), measuring the closure size of the repository's
shipped applications before and after.

**Trade-offs.** A debugger no longer finds druntime and Phobos sources by the
recorded path, and needs a source-path substitution.

**Revisit when** the measurement shows no closure gain, or the toolchain's
sources are shipped beside its libraries anyway.

## D41: Per-shard recompiles before shared results (accepted)

**Question.** CI splits its work across jobs, and each job's machine has its
own store. Until results are shared between machines, every shard recompiles
`sparkles:base` and the other common libraries. Work around it, or accept it?

**Alternatives.**

- Share one store between a workflow's jobs, through the CI provider's cache.
- Accept the recompiles until a binary cache shares results.

**Evidence.** moon's shards repeat work "and only the cache dedupes them"
([moon](../../../research/build-systems/moon.md)).

**Choice.** Accept per-shard recompiles until Cachix shares results through
the Nix backend (E4).

**Revisit when** the recompiles dominate a shard's wall time, or E4 lands.

## D42: Test reuse through recorded runtime inputs (accepted)

**Question.** D7 reuses a test result only in the Nix sandbox or when the test
declares every runtime input. Declaring inputs by hand throughout the
repository is unlikely. What is the planned route to reuse outside the
sandbox?

**Alternatives.**

- Hand-written declarations of runtime inputs.
- Record what each test run read, the environment variables it consulted and
  the files it opened or probed, as `go test` does, and key the result on the
  recording.

**Evidence.** `go test` caches a result keyed on a log of the environment
variables and files the test read
([semantic-caching](../../../research/build-systems/semantic-caching.md)).

**Choice.** Recording is the planned route for D7's revisit. No result is
reused through it until an oracle proves the recording complete: every file a
test opens under `strace` appears in its recording, as oracle 3 does for
compiles.

**The oracle.** It compares the read set the runner core records with a static
scan of the package's sources: string literals and `buildPath` segments that
name tracked paths. A statically named path that is in neither the declared
inputs nor the recorded set is a finding. A declared input that nothing names
or reads is stale. The scan is a second source independent of the recording;
its tokenizer and matcher come from `apps/ci/src/test_reads.d` on PR #633's
branch, ported once BGX2 gives runtime inputs a home
([D43](#d43-amendments-from-the-nix-generated-ci-pr-accepted)).

**Revisit when** that oracle passes for the repository's tests.

## D43: Amendments from the Nix-generated CI PR (accepted)

**Question.** PR #633 generates the repository's workflows from Nix, keys
every CI task by its unit's source closure, skips a task whose key already
passed, and shards tests longest first. Its build reuse is coarser than the
build graph's keys, and its test reuse lets one runner skip a test another
runner passed, which D7 rejects. Land it, or take its ideas into these
specifications?

**Alternatives.**

- Land the PR whole, then migrate its pipeline at M7, M12 and M13.
- Take its best ideas as requirements, and close it.

**Choice.** The owner accepted five amendments on 2026-11-06, and the PR is
closed as a reference:

- **Placements** (CIC14): `ci pipeline` maps one graph onto provider jobs,
  with shards packed longest first by recorded wall times. The PR's static
  shards and hand-measured weights become data from run records.
- **Shared verdicts** (BGX4): its stamp mechanism, kept within D7: only for
  results BGX3 lets be reused, keyed on the observed machine and runner
  image, and published by a credentialed run whose gating checks passed. It
  is how test results come to be shared before E4 (D41).
- **The recorded-inputs oracle** (D42): its static test-reads scan becomes
  the oracle's second source.
- **No `--since` on CI** (CIC15): keys, not diffs, decide reuse there.
- **Observability:** a task skipped by a shared verdict carries the
  publishing run's record id (OD16, in the observability specification), and
  the determinism check is exempt from every result memo (CIC13).

**Trade-offs.** The PR's generated workflows and store-path steps are not
taken now; they return at M13, built from `--list-placements`, when the
workflow shape stops changing.

**Revisit when** M13 generates the workflows.

## D44: The build graph reaches files through the VFS (accepted)

**Question.** The build graph reads recipes, scans and digests sources, probes
for absent files and writes a shared store. The E1 resolver and the
repository's walkers do this with `std.file` on path strings. Should the graph
keep paths, or use the repository's capability VFS, whose specification the
owner has accepted?

**Alternatives.**

- Keep paths, and confine them by checking prefixes after the fact.
- Route every operation through the VFS, on a fixed set of roots, with
  listings as fileset resolutions.

**Choice.** Route it through the VFS, accepted by the owner on 2026-11-07
(§12, BGF1–BGF6). All I/O goes through `sparkles.base.vfs` and its
event-horizon backends, and the fileset effort resumes as the graph's
file-system layer.

- **Planning** runs over the backend its caller supplies, so its tests plan
  fixture trees on `MemVfs` with no temporary directories, and the executor
  runs the same code on `RingVfs`.
- **The worktree** is a read-only root opened with `symlinks = beneath`, so
  D24's committed link resolves and a link out of the tree fails planning.
  The fileset specification's FSD6 gains that policy as a consumer's choice.
- **The store** uses `renameAt`, `writeFileAtomic` and `removeTree` beneath
  its own root, and refuses links.
- **Listings** are fileset resolutions (BGF5), so the graph's E2 needs the
  filesets' M1–M3, and M5 for listing digests.
- **The VFS** gains the file identity and change time in its `Stat` (VFO6),
  which BGK5's cache and BGK7's stat proxies need, before E3.

**Trade-offs.** The E1 resolver moves off `std.file` in E2, and the
repository's old walkers (`dir_walk`, `glob_walk`) are not used by the graph;
filesets' M9 retires them. Processes an action starts still read paths: the
manifest, BGK8 and the D39 isolation spike cover them, not the VFS.

**Revisit when** a VFS backend cannot answer an operation the graph needs on
a supported platform.
