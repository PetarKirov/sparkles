---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# `sparkles:build-primitives` build graph — Specification

## Abstract

The build graph compiles the packages of a dub monorepo directly, without
running dub, so that each library is compiled once per distinct configuration
and its result is reused by every package, test and application that needs it,
across every git worktree on a machine. It reads the packages' `dub.sdl`
recipes itself, turns each requested build into a graph of compile, archive,
link and generator actions, and keys every action by the content of what it
actually reads. The same graph runs on a local executor with a shared
content-addressed cache, or lowers to Nix derivations so that remote builders
and binary caches can execute it.

## Introduction

A Sparkles CI run tests about sixty dub packages and builds a dozen
applications and many examples. Almost all of them depend on the same few
libraries: `sparkles:base`, `sparkles:wired`, `sparkles:event-horizon` and
`sparkles:ui`. A developer typically has several git worktrees of the
repository checked out at once, each holding a nearly identical tree.

dub cannot share that work. Its build identifier hashes the absolute paths of a
package's sources, so the same library under a second worktree, or a second
`DUB_HOME`, is compiled again. Its staleness check compares modification times
only, so copied or restored trees rebuild or, worse, skip a needed rebuild.
Running several `dub test` processes against one `DUB_HOME` races on its
package database. The workarounds in this repository show the cost: CI tasks
were specified with a private `DUB_HOME` each, which recompiles `sparkles:base`
once per dependent, and the Nix example builder copies every source tree to one
fixed path and flattens every timestamp so that one cache bundle can be reused.

This library takes over the part of dub that decides _what_ to compile and
_whether_ it is already compiled. It resolves each package's recipe into
explicit compiler invocations; identifies each library build by everything that
changes its object code, called its _variant_; and records, for every compile,
the exact set of files the compiler read. An action whose recorded inputs are
unchanged is never repeated, whichever worktree, directory or machine asks for
it. Recipes stay dub recipes: humans, editors and `dmd-lsp` keep using dub on
the same files, and dub itself is the oracle that the resolver must agree
with.

The build graph does not resolve or download registry packages; their pinned
sources arrive as immutable store paths from the repository's dub lockfile. It
does not decide which packages a command selects, how tasks are reported, or
how many run at once: those belong to the [task DAG](../task-dag/SPEC.md),
whose executor runs this library's actions. It does not run tests itself
beyond declaring test actions and the conditions under which a test result may
be reused. A per-module compilation mode, a remote-execution protocol of its
own, and a general workflow language are out of scope.

Section 1 states the invariants. Sections 2–4 define recipe resolution,
variants and the action graph; §5 the action key and the input manifest; §6
the shared cache; §7 generators; §8 toolchain identity; §9 test actions and
result reuse; §10 the Nix backend. Delivery order lives in [PLAN.md](./PLAN.md),
oracles and evidence in [testing.md](./testing.md), and the choices behind
each section in [decisions.md](./decisions.md).

## 1. Invariants

1. **An action is a pure function of its key.** Two actions with equal keys
   produce interchangeable outputs. Anything that can change an output is in
   the key, or the action is not cacheable.
2. **No ambient input.** An action runs with an explicit argument vector,
   working directory and environment. It inherits no environment variable,
   current directory or user configuration file that its key does not cover.
3. **Outputs do not name their worktree.** No cached output embeds the
   absolute path of the worktree that built it, unless the variant's key
   includes that path.
4. **dub agrees.** For every package in the repository and every variant the
   repository's commands request, the resolver's settings equal what dub
   resolves for the same request, except where [decisions.md](./decisions.md)
   records an intentional divergence.
5. **Reuse never changes a verdict.** A cache hit and a cold build of the same
   key report the same diagnostics, exit status and outputs.
6. **Recipes are read, never written.** The build graph changes no file under
   the source tree; generated files live in action outputs.

## 2. Recipe resolution

A **recipe** is a package's `dub.sdl`, read through `sparkles.wired.sdl`.
Resolution turns a recipe, a selected configuration, a build type and a
platform into **resolved settings**: the ordered lists of source files, import
paths, string import paths, versions, debug versions, dflags, lflags, libraries
and target properties that a compiler invocation needs.

**BGR1: Typed recipe reading.** The resolver **must** read recipes through the
repository's typed SDL schema (`sparkles.build_primitives.dub_manifest`) and
**must** reject a recipe it cannot represent with a diagnostic naming the file,
line and directive. An unrepresentable directive is never ignored.

**BGR2: Supported directives.** Resolution **must** support every directive the
repository's recipes use: `configuration`, `subConfiguration`, `buildType`
(resolved against the root recipe of the request, as dub does),
platform-suffixed settings, `targetType` including `sourceLibrary`,
`sourcePaths`, `sourceFiles`, `excludedSourceFiles`, `importPaths`,
`stringImportPaths`, `versions`, `debugVersions`, `dflags`, `lflags`, `libs`,
`buildRequirements`, `buildOptions` and `preGenerateCommands` (§7). A
directive outside this list is a resolution error until this section lists
it.

**BGR3: Settings from dependencies.** A package's resolved settings **must**
include what dub contributes from its dependencies, in dub's order: their
import and string import paths, their versions, and, at link time, their
libraries, lflags and archives.

**BGR4: Registry packages.** A dependency that is not an in-tree sub-package
**must** resolve to the source path the repository's dub lockfile pins, as an
immutable store path. A dependency missing from the lockfile is a resolution
error. The resolver never contacts a registry.

**BGR5: Library resolution.** `libs` entries **must** resolve through
`pkg-config` at planning time. The resolved flags and the digests of the
`.pc` files consulted are inputs of every link action that uses them.

**BGR6: Single-file packages.** A D source file with an embedded `dub.sdl`
recipe (`/+ dub.sdl: … +/`) **must** resolve as a package whose recipe is the
embedded one and whose only source is the file. In-tree dependencies it names
by version, rather than by path, resolve to the in-tree package when the
requester asks for that rewrite, as documentation examples do.

**BGR7: The oracle.** Resolution **must** agree with dub on every field §2
defines, for every package and every variant the repository requests (see
[testing.md](./testing.md#oracle-1-dub-agreement)). `dub describe` is the first
oracle. Where it does not expose a field, dub used as a library is the second.
A disagreement fails the gate. Accepting one is a decision record, never a
silent exception.

_Rationale:_ an independent resolver is what removes dub's path-hashed and
mtime-based behaviour from the loop, and an oracle is what keeps it from
silently drifting into a different build system.

## 3. Variants

A **variant** is one way of compiling one package. Two builds of a package are
the same variant exactly when they produce interchangeable object code.

**BGV1: The variant key.** A variant **must** be identified by:

- the package;
- its configuration, including one chosen by a consumer's `subConfiguration`;
- its resolved build options and flags, including coverage instrumentation,
  sanitizers and optimization;
- whether it is compiled as a test root (`-unittest`) or as a dependency;
- the toolchain identity (§8);
- the target platform, including WebAssembly and betterC targets;
- the settings it inherits from its own dependencies (BGR3).

Two requests that resolve to equal variant keys **must** share one set of
actions.

**BGV2: Roles.** A **test root** is the variant a package's unittest binary
compiles its own sources in: its unittest configuration, with `-unittest`. A
**dependency library** is the variant a dependent links against: its library
configuration under the requester's build type, with `-unittest` removed, as
dub does for every non-root package. An **application** variant is a root
compiled for shipping, under the `checked` build type, and its dependencies
are dependency libraries of that build type.

So a package that other selected packages depend on is built at least twice
when its tests run: once as a test root and once as a dependency library. A
package nothing selected depends on is built only in its root role.

**BGV3: Source libraries are not nodes.** A `sourceLibrary` package **must**
never produce an action of its own. Its sources are part of each consumer's
compile and take that consumer's variant, so they compile with `-unittest`
inside a test root.

**BGV4: Unittest layout rule.** A non-`sourceLibrary` package **must not**
declare an aggregate instance field under `version (unittest)`.

_Rationale:_ `-unittest` enables `version (unittest)` in every module a test
root imports, including its dependencies' modules. If such a field exists, the
test root sees a different layout of that aggregate than the dependency library
it links against was compiled with. This is undefined behaviour that no choice
of variant can repair.

**BGV5: The layout lint.** Planning **must** report every violation of BGV4 in
the packages it plans, naming the file and line, and **must** fail the plan.

## 4. The action graph

An **action** is one tool invocation with declared inputs and outputs.

**BGA1: Action kinds.** The graph **must** use exactly these kinds: `compile`
(one compiler invocation over all of a variant's own modules), `archive`
(a static library from compile outputs), `link` (an executable from objects
and archives), `generate` (§7) and `test` (§9). A kind outside this list is
an error.

**BGA2: One compile per variant.** A library or root variant **must** compile
its own modules in one compiler invocation. A dependent's compile reads its
dependencies' sources through import paths; it does not wait for their
archives. A link action waits for the archives it links.

**BGA3: Declared outputs.** Every action **must** declare the outputs it
produces, relative to an action-private output directory, and **must** fail if
it produced an undeclared output, or did not produce a declared one.

**BGA4: Explicit environment.** Every action **must** run with the environment
its key declares (invariant 2). An ambient `DFLAGS` is not inherited; a caller
that wants extra compiler flags requests them as variant options.

**BGA5: Relocatable invocation.** A compile action **must** run with the
repository root as its working directory and pass sources as root-relative
paths. With a compiler that supports it, it also **must** map the absolute
repository root and the store prefix out of debug information and `__FILE__`
(`--ffile-prefix-map` on LDC). With a compiler that cannot, the repository
root's absolute path is part of the action key (invariant 3).

**BGA6: Diagnostics are outputs.** An action's standard output, standard error
and exit status **must** be recorded with its outputs and replayed on a cache
hit (invariant 5).

**BGA7: Graph exposure.** The build graph **must** expose its actions as task
nodes with stable ids, typed actions and resource claims, so that the task DAG
executor can run them (see [task DAG](../task-dag/SPEC.md)). Edges between
actions are ordinary `onSuccess` task edges.

## 5. Keys and the input manifest

Each action has a **key**, a SHA-256 digest that identifies its result. A
compile cannot know its exact inputs until it has run, so compile keys are
computed in two steps, as ccache's direct mode does.

**BGK1: The declared key.** An action's declared key **must** cover:

- the action kind;
- its argument vector, after BGA5's normalization;
- its declared environment;
- the toolchain identity (§8);
- the content digests of its declared inputs: for a compile, the variant's own
  source files and the recipe files that resolved it; for a link or archive,
  the outputs it consumes;
- a format version of this specification's key layout.

**BGK2: The input manifest.** A compile **must** record a **manifest** of every
file the compiler read: its own sources, imported modules, string imports and
ImportC headers, each as a root-relative or store path with a content digest.
The manifest is taken from the compiler's dependency output (`--makedeps` plus
`--deps` for string imports on LDC) and is stored under the declared key.

**BGK3: The result key.** A compile's result key **must** be the digest of its
declared key and its manifest's entries. A lookup by declared key **must**
check each manifest entry's current digest and **must** reuse the result only
when every entry matches.

**BGK4: Precision.** Editing a file that no compile read **must not** change
that compile's result key. So editing a module of `sparkles:base` that
`sparkles:ui` never imports does not rebuild `sparkles:ui`'s variants.

**BGK5: Digests are cached by identity.** File digests **may** be cached by
(device, inode, size, modification time, change time). A file whose identity
matches but whose content differs is a cache defect that the digest audit in
[testing.md](./testing.md#oracle-4-digest-audit) detects.

**BGK6: Unknown read sets are uncacheable.** If a compile's dependency output
is missing or unparseable, the action **must** run, report the condition, and
store no result.

## 6. The shared cache

**BGS1: One store per machine.** Results **must** live in one store per user
and machine, at `$XDG_CACHE_HOME/sparkles/build` (`~/.cache/sparkles/build`
when unset), shared by every worktree and process.

**BGS2: Atomic publication.** A result **must** become visible only complete:
outputs, diagnostics and manifest are written to a private temporary entry and
published by one rename. A reader never observes a partial entry.

**BGS3: Concurrent producers.** Two processes **may** compute the same key at
once. Correctness **must not** depend on a lock: the first rename wins, and the
other producer discards its entry. A per-key advisory lock **may** suppress the
duplicate work.

**BGS4: Bounded size.** The store **must** enforce a configured size bound,
20 GiB by default, by evicting least-recently-used entries. Eviction **must
not** remove an entry that a running build has looked up and not yet released.

**BGS5: Corruption.** An entry whose recorded digests do not match its files
**must** be treated as a miss and removed, with a diagnostic.

**BGS6: Inspection.** The store **must** provide operations to report its size,
list entries by key and age, and collect garbage; `apps/ci` exposes them as
`ci cache` subcommands.

## 7. Generators

A **generator** is a tool run during planning or building that produces files
a compile reads. In this repository the generators are the shader compiler
runs that `preGenerateCommands` declare.

**BGG1: Typed generators.** Each generator **must** be a typed `generate`
action with declared inputs, declared outputs and a tool that is itself built
by the graph. A `preGenerateCommands` entry that the resolver does not
recognize as a known generator is a resolution error, never a shell command.

**BGG2: Generated inputs.** A compile that reads generated files **must** read
them from the generator's outputs, through an import or string import path,
and **must** depend on the generator action.

**BGG3: No staleness flags.** A generator invoked by the graph **must not**
decide staleness itself; the cache decides. Flags such as `--if-stale` are
removed from the invocation.

## 8. Toolchain identity

**BGT1: Identity.** The toolchain identity **must** cover the compiler binary,
its configuration file, the druntime and Phobos sources and libraries it
uses, and the linker it invokes.

**BGT2: Store toolchains.** When the compiler resolves into a Nix store path,
its identity **may** be the set of store paths involved, without reading file
contents.

**BGT3: Host toolchains.** Otherwise, the identity **must** be the digests of
the files BGT1 lists, found through the compiler's own reported configuration.
It **may** be cached by the identity tuple of BGK5.

## 9. Test actions and result reuse

**BGX1: Test actions.** A test action runs a linked test binary with a declared
argument vector, environment and working directory. Its outcome is the binary's
exit status and output.

**BGX2: Results are not reused by default.** A test action's result **must not**
be reused unless one of these holds:

- it ran in the Nix sandbox (§10), whose inputs are the derivation's inputs;
- the test declares every runtime input it reads, and the key covers them.

Otherwise every request runs the test.

_Rationale:_ tests in this repository read the network, the kernel, `/proc` and
flake inputs. A reused result for an undeclared input reports a pass that was
never observed.

## 10. The Nix backend

The Nix backend lowers the same action graph to Nix derivations, so that
`/etc/nix/machines` remote builders, the Nix store and binary caches execute
and share it.

**BGN1: Same graph.** The Nix backend **must** lower the actions §4 defines,
with the same keys, argument vectors and declared outputs as the local
backend.

**BGN2: Sources.** Each action's source inputs **must** enter the store as
content-addressed paths that the build graph computes itself, by adding the
exact file set the action reads. Whole-repository source copies are not used.

**BGN3: Derivations without evaluation.** Derivations **must** be created
directly from their description (`nix derivation add`). Nix expression
evaluation is not on the build path.

**BGN4: Content addressing.** Derivations **should** be content-addressed
(`ca-derivations`), so that an unchanged output stops a rebuild of its
dependents. Where that feature is unavailable, the backend **must** fall back to
input-addressed derivations and report it. That is the exception policy for
this recommendation.

**BGN5: Agreement.** For the same key, the local backend and the Nix backend
**must** produce interchangeable outputs. The agreement oracle in
[testing.md](./testing.md#oracle-6-backend-agreement) checks it.

## 11. Public surface

The library exposes these operations, under `sparkles.build_primitives`:

- **resolve:** a recipe, configuration, build type and platform, to resolved
  settings (§2);
- **plan:** a set of requested roots and roles, to a validated action graph
  with variant dedup and the layout lint (§§3–4);
- **key:** an action, to its declared key, and a manifest, to its result key
  (§5);
- **store:** look up, publish, inspect and collect garbage (§6);
- **lower:** an action graph, to task nodes (BGA7) or to Nix derivations
  (§10).

Each operation returns its errors as values. Planning, keying and lowering
perform no I/O beyond reading recipes, digesting files and querying
`pkg-config`, each through an explicit driver.
