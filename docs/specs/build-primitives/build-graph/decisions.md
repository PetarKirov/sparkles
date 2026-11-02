---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. Records marked **accepted** were accepted by the owner on
2026-11-01, in a design interview to rework the `apps/ci` task DAG. Records
marked **proposed** await the owner's decision.

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
local backend's on the edit loop.

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
`version` or `debug` condition, for example through a string mixin.

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

## D16: The test runner's implementation is pinned and prebuilt (accepted)

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

## D18: LDC relocates with the root mapped to `.` (proposed)

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

## D19: DMD variants key on the root (proposed)

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

## D20: dub's final step is the oracle's second source (proposed)

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

## D21: BGR2's supported set is the scanned vocabulary (proposed)

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
