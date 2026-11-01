---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# `sparkles:build-primitives` build graph — Specification

## Abstract

The build graph compiles the packages of a dub monorepo directly, without
running dub. Each library is compiled once per distinct configuration, and the
result is reused by every package, test and application that needs it, across
every git worktree on a machine. The graph reads the packages' `dub.sdl` recipes
itself and turns each requested build into compile, archive, link, generator
and test actions. It keys every action by the content of what it reads,
including what it looked for and did not find. The same graph runs on a local
executor with a shared content-addressed cache, or lowers to Nix derivations so
that remote builders and binary caches can execute it.

## Introduction

A Sparkles CI run tests about sixty dub packages and builds a dozen
applications and many examples. Almost all of them depend on the same few
libraries: `sparkles:base`, `sparkles:wired`, `sparkles:event-horizon` and
`sparkles:ui`. A developer typically has several git worktrees of the
repository checked out at once, each holding a nearly identical tree.

dub cannot share that work:

- Its build identifier hashes the absolute paths of a package's sources, so the
  same library under a second worktree, or a second `DUB_HOME`, is compiled
  again.
- Its staleness check compares modification times only, so copied or restored
  trees rebuild needlessly or, worse, skip a needed rebuild.
- Several `dub test` processes sharing one `DUB_HOME` race on its package
  database.

The repository's workarounds show the cost. CI tasks were specified with a
private `DUB_HOME` each, which recompiles `sparkles:base` once per dependent.
The Nix example builder copies every source tree to one fixed path and
flattens every timestamp so that one cache bundle can be reused.

This library takes over the part of dub that decides _what_ to compile and
_whether_ it is already compiled. It resolves each package's recipe into
explicit compiler invocations. It identifies each library build by everything
that changes its object code, which this document calls its
[_variant_](#3-variants). For every compile, it records the exact set of files
the compiler read and the search paths it found empty. An action whose recorded
inputs are unchanged is never repeated, whichever worktree, directory or
machine asks for it. Recipes stay dub recipes: humans, editors and `dmd-lsp`
keep using dub on the same files, and dub itself is the oracle the resolver
must agree with.

The build graph does not download or resolve registry packages; their pinned
sources come from the repository's dub lockfiles. Which packages a command
selects, how tasks are reported and how many run at once belong to the
[task DAG](../task-dag/SPEC.md), whose executor runs this library's actions.
The graph declares test actions and the conditions under which a test result
may be reused, but owns no test policy. A per-module compilation mode, a
remote-execution protocol of its own, and a general workflow language are out
of scope.

Section 1 states the invariants. Sections 2–4 define recipe resolution,
variants and the action graph; §5 the action key and the input manifest; §6 the
shared store; §7 generators; §8 toolchain identity; §9 test actions and result
reuse; §10 the Nix backend; §11 the public surface. Delivery order lives in
[PLAN.md](./PLAN.md), oracles and evidence in [testing.md](./testing.md), and
the choices behind each section in [decisions.md](./decisions.md).

## 1. Invariants

1. **An action is a pure function of its key.** Two actions with equal keys
   produce interchangeable outputs. Anything that can change an output is in
   the key, or the action is not cacheable.
2. **No ambient input.** An action runs with an explicit argument vector,
   working directory, environment and compiler configuration file. It inherits
   nothing its key does not cover.
3. **Outputs do not name their worktree.** No cached output embeds the
   absolute path of the worktree that built it, unless the action's key
   includes that path.
4. **dub agrees.** For every package and request in scope, the resolver's
   settings equal what dub resolves, except where [decisions.md](./decisions.md)
   records an intentional divergence.
5. **Reuse never changes a verdict.** A cache hit and a cold build of the same
   key report the same diagnostics, exit status and outputs.
6. **The source tree is read, never written.** Generated files live in action
   outputs.

## 2. Recipe resolution

A **recipe** is a package's `dub.sdl`, read through `sparkles.wired.sdl`.
Resolution turns a recipe, a selected configuration, a build type and a
platform into **resolved settings**: the ordered source files, import paths,
C import paths, string import paths, versions, debug versions, dflags, lflags,
libraries and target properties that a compiler invocation needs.

The recipes **in scope** are the root recipe's sub-packages and the single-file
packages that `apps/ci` builds (BGR6). Any other `dub.sdl` in the tree is out
of scope until a consumer requests it.

**BGR1: Typed recipe reading.** The resolver **must** read recipes through the
repository's typed SDL schema (`sparkles.build_primitives.dub_manifest`). It
**must** reject a recipe it cannot represent with a diagnostic naming the file,
line and directive. An unrepresentable directive is never ignored.

**BGR2: Supported directives.** Resolution **must** support every directive the
recipes in scope use. A directive outside the supported set is a resolution
error. The supported set **must** contain at least:

- **Package and dependencies:** `name`, `subPackage`, `dependency` (with
  `path`, `version`, `optional` and `default`), `subConfiguration`;
- **Configurations and build types:** `configuration` (with `platforms`), and
  `buildType`, resolved against the request's root recipe, as dub does;
- **Target:** `targetType` (including `sourceLibrary`), `targetName`,
  `targetPath`, `mainSourceFile`, `workingDirectory`;
- **Sources and paths:** `sourcePaths`, `sourceFiles`, `excludedSourceFiles`,
  `importPaths`, `cImportPaths`, `cSourcePaths`, `stringImportPaths`;
- **Settings:** `versions`, `debugVersions`, `dflags`, `lflags`, `libs`,
  `buildRequirements`, `buildOptions`;
- **Generation:** `preGenerateCommands` (§7);
- **Matching:** platform-suffixed forms of every setting above;
- **Variables:** dub's `$PACKAGE_DIR`, `$ROOT_PACKAGE_DIR` and environment
  references in setting values. An environment variable a value names is an
  input of every action whose settings contain it.

Metadata directives (`description`, `authors`, `copyright`, `license`) are
read and ignored. The resolver's E1 gate scans every recipe in scope, and any
directive it finds outside this list is added here before the gate passes.

**BGR3: Inherited settings.** Resolution **must** apply dub's three directions
of inheritance (dub `source/dub/generators/generator.d`, functions
`configureDependencies`, `mergeFromDependent` and `mergeFromDependency`):

- **Down**, from each dependent to every dependency: its versions and debug
  versions, the build options dub classes as inherited, and the dflags dub
  classes as ABI-critical (`-checkaction=`, `-fsanitize=`, `-boundscheck=`,
  `-mcpu=`, `-mattr=`, `-mtriple=` and their kin).
- **Across**, to every target: a `Have_<package>` version for each package and
  direct dependency it incorporates.
- **Up**, from each dependency to its dependents: dflags, versions, debug
  versions, version filters, import, C import and string import paths, and,
  from library targets, libraries, frameworks, lflags and linker files.

Downward versions are pruned per BGV1. A build option selects the divergent
mode of [D13](./decisions.md#d13-prune-downward-inherited-versions-accepted)
instead: a dependent's configuration-level versions and debug versions do not
pass down, and resolution rejects a dependency whose sources test one. Both
modes pass build-type options and ABI-critical flags down, and the mode is
part of every variant key.

**BGR4: Registry packages.** A dependency that is not an in-tree sub-package
**must** resolve to the source the repository's dub lockfiles (`nix/dub-lock.json`
and `nix/ci-dub-lock.json`) pin, verified by the lockfile's hash. With Nix, the
source is a store path fetched by that hash. Without Nix, it is fetched into
the build store (§6) and verified by the same hash. A dependency missing from
the lockfiles is a resolution error, and the resolver never contacts a
registry.

**BGR5: Library resolution.** `libs` entries **must** resolve through
`pkg-config` at planning time, following dub's rule for which target types
receive them.

- **Compile actions:** `--cflags` results become C preprocessor flags of every
  compile action that uses them, as dub does.
- **Link actions:** `--libs` results become link flags of the link actions.
- **Key inputs:** the resolved flags, the digests of the `.pc` files consulted,
  and the libraries the link flags resolve to are inputs of the actions that
  use them. A library that resolves to a store path may be identified by that
  path.

**BGR6: Single-file packages.** A D source file with an embedded `dub.sdl`
recipe (`/+ dub.sdl: … +/`) **must** resolve as a package whose recipe is the
embedded one and whose only source is the file. In-tree dependencies it names
by version, rather than by path, resolve to the in-tree package when the
requester asks for that rewrite, as documentation examples do.

**BGR7: The oracle.** Resolution **must** agree with dub on every resolved field,
for every package and request in scope (see
[testing.md](./testing.md#oracle-1-dub-agreement)). `dub describe` is the first
oracle. Where it does not expose a field, dub used as a library is the second.
A disagreement fails the gate. Accepting one is a decision record, never a
silent exception.

_Rationale:_ an independent resolver is what removes dub's path-hashed and
mtime-based behaviour from the loop, and an oracle is what keeps it from
silently drifting into a different build system.

**BGR8: No hidden source edges.** A package in scope **must not** reach into
another package's directory through `importPaths`, `sourcePaths`,
`stringImportPaths` or `cImportPaths` without a `dependency` on it. The
cycle-safe test-runner integration (AGENTS.md) is the declared exception.
Resolution reports each violation, naming the recipe line and the package
reached.

## 3. Variants

A **variant** is one way of compiling one package. Two builds of a package are
the same variant exactly when they produce interchangeable object code.

**BGV1: The variant key.** A variant **must** be identified by:

- the package;
- its configuration, including one chosen by a consumer's `subConfiguration`;
- its role (BGV2);
- its resolved build options and flags, including coverage instrumentation,
  sanitizers and optimization, after inheritance (BGR3);
- its versions and debug versions after inheritance, with each downward-inherited
  identifier kept only if a source file the variant compiles, or that it reads
  through an import path, mentions that identifier in a `version` or `debug`
  condition;
- the toolchain identity (§8);
- the target platform, including WebAssembly and betterC targets.

Two requests that resolve to equal variant keys **must** share one set of
actions.

_Rationale:_ dub passes a test root's versions down to every dependency, so
without pruning, any root with a configuration-local version forks its whole
dependency closure. An identifier no compiled or imported source mentions
cannot change the object code.

**BGV2: Roles.** A variant has one of these roles:

- **Test root:** the variant a package's unittest binary compiles its own
  sources in. It uses the package's unittest configuration with `-unittest`,
  excludes its `mainSourceFile`, and gets its entry point from a generated
  test-root module (§7), as dub does.
- **Dependency library:** the variant a dependent links against. It uses the
  package's library configuration under the requester's build type, with
  `-unittest` removed, as dub does for every non-root package.
- **Application:** a root compiled for shipping under the `checked` build
  type. Its dependencies are dependency libraries of that build type.

A package that other selected packages depend on is therefore built at least
twice when its tests run: once as a test root and once as a dependency
library. A package nothing selected depends on is built only in its root role.

**BGV3: Source libraries are not compiled alone.** A `sourceLibrary` package
**must** never produce a compile action of its own. Its sources are part of
each consumer's compile and take that consumer's variant, so they compile with
`-unittest` inside a test root. It may own generate actions (§7).

**BGV4: The unittest layout rule.** A package that is compiled as a dependency
library **must not** contain a declaration whose presence, layout or meaning
changes under `version (unittest)`, other than inside `unittest` blocks. The
hazards include:

- an aggregate instance field, virtual method, destructor, postblit or copy
  constructor;
- a field initializer, `enum` member or value, or `alias` target;
- a template whose instances differ between the two builds;
- an import of a package that the library configuration does not depend on.

The same rule applies to a `sourceLibrary` compiled into both a test root and a
dependency library of one binary.

_Rationale:_ `-unittest` turns on `version (unittest)` in every module a test
root imports, including its dependencies' modules. A test root then sees a
different declaration than the dependency library it links against was compiled
with. The linker merges template instances across the two, so even a
template's `version (unittest)` branch leaks into library code.

**BGV5: The layout lint.** Planning **must** report every violation of BGV4 in
the packages it plans, naming the file and line, and **must** fail the plan.
The lint works on the analyzed program (through the DMD frontend), not on
source text.

## 4. The action graph

An **action** is one tool invocation with declared inputs and outputs.

**BGA1: Action kinds.** The graph **must** use exactly these kinds:

- `compile`: one compiler invocation over all of a variant's own modules;
- `archive`: a static library from compile outputs;
- `link`: an executable from objects and archives;
- `generate` (§7);
- `test` (§9).

A kind outside this list is an error.

**BGA2: One compile per variant.** A library or root variant **must** compile
its own modules in one compiler invocation. A dependent's compile reads its
dependencies' sources through import paths; it does not wait for their
archives. A link action waits for the archives it links.

**BGA3: Declared outputs.** Every action **must** declare the outputs it
produces, relative to an action-private output directory on the store's file
system. It **must** fail if it produced an undeclared output, or did not
produce a declared one.

**BGA4: Explicit environment.** Every action **must** run with the environment
its key declares (invariant 2). An ambient `DFLAGS`, `CC`, `NIX_CFLAGS_COMPILE`
or any other variable is not inherited. A caller that wants extra compiler
flags requests them as variant options.

**BGA5: Relocatable invocation.**

- **Working directory:** a compile action **must** run in the repository root,
  passing sources and in-tree paths as root-relative paths.
- **Prefix map:** with a compiler that supports it, the action **must** map the
  absolute repository root to `.` in debug information, `__FILE__`,
  `__FILE_FULL_PATH__` and coverage registration (`--ffile-prefix-map` on
  LDC). Store paths are not remapped: they already name no worktree.
- **Fallback:** with a compiler that cannot map them, the repository root's
  absolute path is part of the action key.

**BGA6: Argument normalization.** Before an action's argument vector enters its
key (§5), the absolute repository root **must** be replaced by a fixed
placeholder, and the action's private output directory by another. No other
argument is rewritten. So a prefix-map argument naming a worktree hashes
equally in every worktree.

**BGA7: Diagnostics are outputs.** An action's standard output, standard error
and exit status **must** be recorded with its outputs and replayed on a cache
hit (invariant 5).

**BGA8: Graph exposure.** The build graph **must** expose its actions as task
nodes with stable ids, typed actions and resource claims, so that the task-DAG
executor can run them (see [task DAG](../task-dag/SPEC.md)). Edges between
actions are ordinary `onSuccess` task edges. The default weights are:

- `compile` 2;
- `archive` 1;
- `link` 2;
- `generate` 1;
- `test` 2, which the test runner's thread count matches.

A `link` action **must** pass its claimed weight as the linker's thread count
(`--threads` on `ld.lld`).

## 5. Keys and the input manifest

Each action has a **key**, a SHA-256 digest that identifies its result. A
compile cannot know its exact inputs until it has run, so compile keys are
computed in two steps, as ccache's direct mode does.

**BGK1: The declared key.** An action's declared key **must** cover:

- the action kind;
- its argument vector, normalized per BGA6;
- its declared environment;
- the toolchain identity (§8);
- the content digests of its declared inputs. For a compile, these are the
  variant's own source files, the recipe files that resolved it and the
  generator outputs it reads. For a link or archive, they are the outputs it
  consumes;
- a format version of this specification's key layout.

**BGK2: The input manifest.** A compile **must** record a **manifest** of
everything the compiler resolved. It lists every file the compiler read, each
as a root-relative or store path with a content digest:

- its own sources;
- the modules it imported;
- its string imports;
- the C headers its ImportC sources included.

It also lists every **absent candidate**: each path the compiler's import or
string-import search probed and found missing before the path it resolved to,
and every path probed by an import that failed.

The manifest comes from the compiler's dependency output. On LDC, that is
`--makedeps` plus the fork's extensions for C headers and absent candidates
([decisions.md](./decisions.md#d12-complete-dependency-output-in-the-ldc-fork)).

**BGK3: Several manifests per declared key.** The store **must** keep, under one
declared key, a bounded list of manifests. Each manifest leads to its own
**result key**: the digest of the declared key and the manifest's entries. A
lookup **must** take the most recently used manifest whose every file entry
matches the current digest and whose every absent candidate is still absent,
and reuse its result. The list's bound is 16 by default, with least recently
used manifests evicted first.

_Rationale:_ two worktrees on different revisions of `sparkles:base` produce the
same declared key for `sparkles:ui`'s compile but different manifests. Both
must stay reusable.

**BGK4: Precision.** Editing a file that no compile read **must not** change that
compile's result key. So editing a module of `sparkles:base` that
`sparkles:ui` never imports does not rebuild `sparkles:ui`'s variants. Creating
a file at an absent candidate's path **must** change the result key.

**BGK5: Digests are cached by identity.** File digests **may** be cached by the
tuple (device, inode, size, modification time, change time). A cached digest
**must not** be trusted if it was recorded within the file system's timestamp
granularity of the file's modification time; such a file is rehashed, as git
treats racily clean entries.

**BGK6: Incomplete dependency output.** If a compile's dependency output is
missing, unparseable, or comes from a compiler that cannot list C headers or
absent candidates, the action **must** key on its declared inputs plus the
digest of the complete file listing of every import, C import and string
import root it searches. It still runs and is reported as conservatively keyed.

## 6. The shared store

**BGS1: One store per machine.** Results **must** live in one store per user and
machine, at `$XDG_CACHE_HOME/sparkles/build` (`~/.cache/sparkles/build` when
unset), shared by every worktree and process.

**BGS2: Atomic publication.** A result **must** become visible only complete.
Its outputs, diagnostics and manifest are written to a private entry under the
store's own staging directory, so that the publishing rename never crosses a
file system. A result is published by one rename to its result key, and a
manifest list is replaced by writing a new list file and renaming it over the
old one. A reader never observes a partial entry.

**BGS3: Concurrent producers.** Two processes **may** compute the same result key
at once. Correctness **must not** depend on a lock: the first rename wins, and
the other producer discards its entry. Concurrent manifest-list updates **may**
lose an entry, which costs only a rebuild. A per-key advisory lock **may**
suppress duplicate work.

**BGS4: Leases and eviction.** The store **must** enforce a configured size
bound, 20 GiB by default, by evicting least-recently-used results.

- **Leases:** a process using a result holds a lease, a file in the entry that
  names the holder's process id and start time. Eviction **must not** remove a
  leased entry whose holder is alive. A lease whose holder is gone is
  reclaimed.
- **Trash first:** eviction first renames an entry into a trash directory, then
  checks its leases, and restores it if one appeared. Lookup leases the entry
  before reading it.
- **Read in place:** outputs are used in place and read-only, and an action
  never writes into a published entry.

**BGS5: Corruption.** An entry whose recorded digests do not match its files
**must** be treated as a miss and removed, with a diagnostic.

**BGS6: Inspection.** The store **must** provide operations to report its size,
list entries by key and age, and collect garbage. `apps/ci` exposes them as
`ci cache` subcommands.

## 7. Generators

A **generator** is a tool the graph runs to produce files that a compile reads:
the shader compiler runs that `preGenerateCommands` declare, and the
test-root module that gives a unittest binary its entry point.

**BGG1: Typed generators.** Each generator **must** be a typed `generate` action
with declared inputs, declared outputs and a tool that is itself built by the
graph. A `preGenerateCommands` entry that the resolver does not recognize as a
known generator is a resolution error, never a shell command.

**BGG2: Generated inputs replace in-tree paths.** A compile that reads generated
files **must** read them from the generator's output directory and **must**
depend on the generator action. Where the recipe names an in-tree output
directory (such as `stringImportPaths "shaders/generated"`), the generator's
output directory replaces that entry in the same position. The replacement is
a recorded divergence from dub
([decisions.md](./decisions.md#d8-generators-are-typed-nodes)).

**BGG3: No staleness flags.** A generator invoked by the graph **must not** decide
staleness itself; the cache decides. Flags such as `--if-stale` and `--changed`
are removed from the invocation. The generator receives its tool paths and
inputs as arguments; it does not call dub or search `PATH` itself.

**BGG4: Generated sources have content-addressed paths.** A generated source
that a compile names as a source file, such as an extracted documentation
example, **must** live at a path derived from its content digest, so that its
path, and with it `__FILE__`, is the same in every run.

## 8. Toolchain identity

**BGT1: Identity.** The toolchain identity **must** cover:

- the D compiler binary and the configuration file it uses, which the action
  passes explicitly (`-conf=` on LDC);
- the druntime and Phobos sources and libraries;
- the C compiler driver that the D compiler invokes for preprocessing and
  linking, the C library, startup objects and system headers;
- the linker;
- every generator tool.

**BGT2: Store toolchains.** When a component resolves into a Nix store path, its
identity **may** be that path's closure of store paths, without reading file
contents. A wrapper script's referenced store paths are part of its closure.

**BGT3: Host toolchains.** Otherwise, a component's identity **must** be the
digests of the files BGT1 lists, found through the compiler's own reported
configuration. It **may** be cached per BGK5.

## 9. Test actions and result reuse

**BGX1: Test actions.** A test action runs a linked test binary with a declared
argument vector, environment and working directory. The working directory is
the requesting worktree's repository root. Its outcome is the binary's exit
status and output. A test binary **must not** run dub. The import paths and
flags that the test runner's compile-time and extracted modes need are passed
to it as arguments, from the variant's resolved settings.

**BGX2: Runtime inputs.** A test action's declared runtime inputs **must**
include:

- the source closure the binary reads at run time, such as fixtures named
  through `__FILE_FULL_PATH__`;
- the toolchain, when the test compiles;
- the flake inputs it reads.

**BGX3: Result reuse.** A test action's result **must not** be reused unless one
of these holds, and otherwise every request runs it:

- **Sandboxed:** it ran in the Nix sandbox (§10), and its key also covers:
  - the kernel release;
  - the CPU model and features;
  - the build system's type.
- **Declared:** the test declares every runtime input it reads, and the key
  covers them.

A test that needs the network is never reused.

_Rationale:_ tests in this repository read the network, the kernel, `/proc`
and flake inputs, and the Nix sandbox isolates none of the kernel's features. A
reused result for an undeclared input reports a pass that was never observed.

## 10. The Nix backend

The Nix backend lowers the same action graph to Nix derivations, so that
`/etc/nix/machines` remote builders, the Nix store and binary caches execute
and share it.

**BGN1: Same graph.** The Nix backend **must** lower the actions §4 defines, with
the same declared keys, argument vectors and declared outputs as the local
backend, normalized per BGA6 with the store's output and input paths as the
placeholders' values.

**BGN2: Sources.** A compile derivation's source inputs **must** be its declared
inputs plus the complete file sets of the import, C import and string import
roots it searches. Each enters the store as a content-addressed path that the
build graph computes itself. Whole-repository source copies are not used.

**BGN3: Derivations without evaluation.** Derivations **must** be created
directly from their description (`nix derivation add`). Nix expression
evaluation is not on the build path.

**BGN4: Content addressing.** Derivations **should** be content-addressed
(`ca-derivations`), so that an unchanged output stops a rebuild of its
dependents. Where that feature is unavailable, the backend **must** fall back to
input-addressed derivations and report it. That is the exception policy for
this recommendation.

**BGN5: Agreement.** For the same declared key and manifest, the local backend
and the Nix backend **must** produce interchangeable outputs. The agreement
oracle in [testing.md](./testing.md#oracle-6-backend-agreement) checks it.

## 11. Public surface

The library exposes these operations, under `sparkles.build_primitives`:

- **resolve:** a recipe, configuration, build type and platform, to resolved
  settings (§2);
- **plan:** a set of requested roots and roles, to a validated action graph
  with variant dedup and the layout lint (§§3–4);
- **key:** an action, to its declared key, and a manifest, to its result key
  (§5);
- **store:** look up, lease, publish, inspect and collect garbage (§6);
- **lower:** an action graph, to task nodes (BGA8) or to Nix derivations
  (§10).

Each operation returns its errors as values. Planning, keying and lowering
perform no I/O beyond reading recipes, digesting files and querying
`pkg-config`, each through an explicit driver.
