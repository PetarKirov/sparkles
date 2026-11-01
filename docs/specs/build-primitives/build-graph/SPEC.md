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

A **recipe** is a package's `dub.sdl`, read through `sparkles.wired.sdl`, or a
registry package's `dub.json`. Resolution turns a recipe, a selected
configuration, a build type and a platform into **resolved settings**: the
ordered source files, import paths, C import paths, string import paths,
versions, debug versions, dflags, lflags, libraries and target properties that
a compiler invocation needs.

The recipes **in scope** are the root recipe's sub-packages, the registry
packages they depend on, and the single-file packages that `apps/ci` builds
(BGR6). Any other recipe in the tree is out of scope until a consumer requests
it. The reference semantics are dub's, at the revision the flake pins.

**BGR1: Typed recipe reading.** The resolver **must** read recipes through the
repository's typed schema (`sparkles.build_primitives.dub_manifest`), from SDL
and from JSON. It **must** reject a directive the schema does not name, with a
diagnostic naming the file, line and directive. dub's `x:` extension tags are
the only directives that are read and ignored.

**BGR2: Supported directives.** Resolution **must** support every directive,
attribute and form the recipes in scope use. A directive outside the supported
set is a resolution error. The supported set is listed in
[testing.md](./testing.md#the-recipe-vocabulary), generated by scanning the
recipes in scope and checked by oracle 1. It includes at least:

- the package, dependency and sub-package forms: inline `subPackage` blocks,
  the `:name` shorthand, and `dependency` with its `path`, `version`,
  `repository`, `optional`, `default` and `platform` attributes;
- configurations, top-level `platforms`, build types resolved against the
  request's root recipe, and `toolchainRequirements`;
- every build setting, each with dub's platform matching (the `platform`
  attribute in SDL, the name suffix in JSON);
- an empty `sourcePaths`, and dub's glob forms in file lists;
- dub's variables (`$PACKAGE_DIR`, `$ROOT_PACKAGE_DIR`, `$<NAME>_PACKAGE_DIR`,
  `$ARCH`, `$PLATFORM`, `$PLATFORM_POSIX`, `$BUILD_TYPE`, `$DUB`, `$DUB_EXE`,
  `$DC`, `${…}` and `$$`), and environment references. An environment variable
  a value names is an input of every action whose settings contain it.

**BGR3: dub's configuration steps.** Resolution **must** reproduce the steps of
dub's `ProjectGenerator.configurePackages`, in dub's order:

1. **Collect targets.** A `sourceLibrary` dependency is folded into each
   consumer, merging all of its settings, and a non-executable target drops
   its `mainSourceFile` from its sources.
2. **Down:** from each dependent to every dependency, its versions and debug
   versions, the build options dub classes as inherited, and the dflags dub
   classes as ABI-critical (`filterABICriticalFlags`).
3. **Across:** a `Have_<package>` version, its name sanitized as dub does, for
   each package a target incorporates and each direct dependency.
4. **Up:** from each dependency to its dependents, dflags, versions (so
   `Have_` versions reach every transitive dependent), debug versions, version
   filters, import, C import and string import paths, injected source files,
   and, from library targets, libraries, frameworks, lflags and linker files.
5. **Override string imports** from dependents, as dub does.
6. **Build type:** add the build type's settings to every target, remove the
   `unittests` option from non-root targets, and extract build options from
   the dflags.

Downward versions are pruned per BGV1. A build option selects the divergent
mode of [D13](./decisions.md#d13-prune-downward-inherited-versions-accepted)
instead: a dependent's configuration-level versions and debug versions do not
pass down, and resolution rejects a dependency whose sources test one. Both
modes pass build-type options and ABI-critical flags down, and the mode is part
of every variant key.

**BGR4: Registry packages.** A dependency that is not an in-tree sub-package
**must** resolve to the source the repository's dub lockfiles
(`nix/dub-lock.json` and `nix/ci-dub-lock.json`) pin:

- **With Nix:** the source is a store path fetched by the lockfile's hash.
- **Without Nix:** it is fetched by the lockfile's URL into the build store
  (§6) and verified by the lockfile's hash. An archive is checked against its
  flat SHA-256, and a git checkout against its NAR hash, which the build graph
  computes itself.

A dependency missing from the lockfiles is a resolution error. The resolver
never resolves a version against a registry.

**BGR5: Library resolution.** `libs` entries **must** resolve through
`pkg-config` at planning time, with dub's rules: the `lib<name>` fallback, the
split of the results into compiler and linker flags, and the `-P` prefixing of
preprocessor flags.

- **Executable and dynamic-library targets:** these receive the results, as
  dub gives them.
- **Library targets:** these also receive the `--cflags` results of their own
  `libs` for their compiles. dub gives them none, and the divergence is
  recorded in
  [decisions.md](./decisions.md#d17-library-targets-see-their-own-c-headers).

The resolved flags, the digests of the `.pc` files consulted, and the libraries
the link flags resolve to are inputs of the actions that use them. A library
that resolves to a store path may be identified by that path.

**BGR6: Single-file packages.** A D source file with an embedded `dub.sdl`
recipe (`/+ dub.sdl: … +/`) **must** resolve as a package whose recipe is the
embedded one and whose only source is the file. In-tree dependencies it names
by version, rather than by path, resolve to the in-tree package when the
requester asks for that rewrite, as documentation examples do.

**BGR7: The oracle.** Resolution **must** agree with dub on every resolved field,
for every package and request in scope (see
[testing.md](./testing.md#oracle-1-dub-agreement)). Fields before library
resolution are compared with `dub describe`. Fields after it, and anything else
`dub describe` does not expose, are compared with dub used as a library. A
disagreement fails the gate. Accepting one is a decision record, never a silent
exception.

_Rationale:_ an independent resolver is what removes dub's path-hashed and
mtime-based behaviour from the loop, and an oracle is what keeps it from
silently drifting into a different build system.

**BGR8: No hidden source edges.** A package in scope **must not** reach into
another package's directory through `importPaths`, `sourcePaths`, `sourceFiles`,
`stringImportPaths`, `cImportPaths` or `cSourcePaths` without a `dependency` on
it, in any configuration. Resolution reports each violation, naming the recipe
line and the package reached. There is no exception: the test runner's
implementation is a pinned, prebuilt component (BGT1), so no package
source-includes it.

## 3. Variants

A **variant** is one way of compiling one package. Two builds of a package are
the same variant exactly when they produce interchangeable object code.

**BGV1: The variant key.** A variant **must** be identified by:

- the package;
- its configuration, including one chosen by a consumer's `subConfiguration`;
- its role (BGV2);
- its resolved build options and flags, including coverage instrumentation,
  sanitizers and optimization, after inheritance (BGR3);
- its versions and debug versions after inheritance, pruned as below;
- the inheritance mode (BGR3);
- the toolchain identity (§8);
- the target platform, including WebAssembly and betterC targets.

Two requests that resolve to equal variant keys **must** share one set of
actions.

**Pruning.** A downward-inherited version or debug identifier **must** be kept
only if it is **mentioned** by a D source file under one of the variant's
source, import or string import roots. Mentioned means it appears in a
`version (…)` or `debug (…)` condition, or in a `version = …` or `debug = …`
assignment.

- **Scanned at plan time:** the scan runs during planning, over the files
  present then, and the digest of the scanned file listing is part of the
  declared key (BGK1). A new file that mentions an identifier therefore
  re-plans the variant.
- **Generated roots:** a root filled by a generator (§7) is not scanned. A
  variant with such a root keeps every inherited identifier.

_Rationale:_ dub passes a test root's versions down to every dependency, so
without pruning, any root with a configuration-local version forks its whole
dependency closure. Version identifiers are module-local in D, so an identifier
no file the compile can reach mentions cannot change the object code.

**BGV2: Roles.** A variant has one of these roles:

- **Test root:** the variant a package's unittest binary compiles its own
  sources in, using its unittest configuration with `-unittest`.
  - **Custom runner:** if that configuration's target type is `executable`,
    the configuration is a custom test runner. Its `mainSourceFile` is kept and
    no test-root module is generated.
  - **Generated entry point:** otherwise its `mainSourceFile` is excluded, and
    a generated test-root module (§7) gives the binary its entry point. The
    module imports the package's own sources only, with no `sourceLibrary`
    files, skipping every `package.d` and the `mainSourceFile`. It names each
    module by its parsed `module` declaration, as dub does.
- **Dependency library:** the variant a dependent links against. It uses the
  package's library configuration under the requester's build type, with
  `-unittest` removed, as dub does for every non-root package.
- **Application:** a root compiled for shipping, with dependency libraries of
  the same build type.

A package that other selected packages depend on is therefore built at least
twice when its tests run: once as a test root and once as a dependency
library. A package nothing selected depends on is built only in its root role.

**BGV3: Source libraries are not compiled alone.** A `sourceLibrary` package
**must** never produce a compile action of its own. Its sources are part of
each consumer's compile and take that consumer's variant, so they compile with
`-unittest` inside a test root. It may own generate actions (§7).

**BGV4: The unittest layout rule.** In a package compiled as a dependency
library, `version (unittest)` **must not** change anything a dependent's
compile or link can observe, outside `unittest` blocks. That covers:

- a declaration visible outside its module (`public`, `package` or
  `protected`), at any level;
- an aggregate member of any visibility: a field, field initializer, virtual
  method, destructor, postblit or copy constructor;
- an `enum` member or value, or an `alias` target;
- any `version (unittest)` inside a template, or inside the body of a function
  whose body a dependent compiles: an `auto`-returning or attribute-inferred
  function, or one marked `pragma(inline, true)`;
- a module-scope import of a package that the library configuration does not
  depend on.

A `private`, non-template, module-level declaration that only the module's own
`unittest` blocks use is exempt. The rule also applies to a `sourceLibrary`
compiled into both a test root and a dependency library of one binary.

_Rationale:_ `-unittest` turns on `version (unittest)` in every module a test
root imports, including its dependencies' modules. A test root then sees a
different declaration, layout, mangled attribute set or template instance
than the dependency library it links against was compiled with. The linker
merges template instances across the two, so a template's test-only branch
also leaks into library code.

**BGV5: The layout lint.** Planning **must** report every violation of BGV4 in
the packages it plans, naming the file and line, and **must** fail the plan.
The lint works on the parsed module before conditional compilation is
resolved, so it sees both branches of every `version (unittest)` and every
uninstantiated template body.

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
system. A declared output is a file or a directory tree; a generator whose
file names depend on its inputs declares its output directory. The action
**must** fail if it produced an output outside its declarations, or did not
produce a declared one.

**BGA4: Explicit environment.** Every action **must** run with the environment
its key declares (invariant 2). An ambient `DFLAGS`, `CC`, `NIX_CFLAGS_COMPILE`
or any other variable is not inherited. A caller that wants extra compiler
flags requests them as variant options.

**BGA5: Relocatable invocation.**

- **Working directory:** a compile action **must** run in the repository root,
  passing sources and in-tree paths as root-relative paths.
- **Prefix map:** with a compiler that supports it, the action **must** map the
  absolute repository root, with its trailing separator, to the empty string in
  debug information, `__FILE__`, `__FILE_FULL_PATH__`, coverage registration
  and the C preprocessor's output (`--ffile-prefix-map=<root>/=` on LDC). So
  every in-tree path the outputs record is root-relative, such as
  `libs/base/src/…`. Store paths are not remapped: they already name no
  worktree.
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
- `test` 2.

A `test` action **must** pass its claimed weight as the test runner's
maximum thread count, and a `link` action as the linker's thread count
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
  variant's own source files, the recipe files that resolved it, the generator
  outputs it reads, and the digest of the file listing that version pruning
  scanned (BGV1). For a link or archive, they are the outputs it consumes;
- a format version of this specification's key layout.

**BGK2: The input manifest.** A compile **must** record a **manifest** of
everything the compiler resolved. It lists every file the compiler read, each
as a root-relative or store path with a content digest:

- its own sources;
- the modules it imported;
- its string imports;
- the C headers its ImportC sources included.

It also lists every **absent candidate**: each path the compiler's D import,
string import or C include search probed and found missing before the path it
resolved to, and every path probed by a lookup that failed. An absent
candidate also stands for each missing parent directory on its path.

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
**must not** be trusted when the file's modification or change time is not
older than the time the digest was recorded, minus two seconds; such a file is
rehashed. This is git's rule for racily clean index entries, with a margin
that covers coarse kernel timestamps.

**BGK6: Incomplete dependency output.** If a compile's dependency output is
missing, unparseable, or comes from a compiler that cannot list C headers or
absent candidates, the action **must** key on its declared inputs plus the
paths and content digests of every file under every import, C import and
string import root it searches. Its result is published under that key and
reported as conservatively keyed.

## 6. The shared store

The store's layout is:

| Directory                 | Holds                                             |
| ------------------------- | ------------------------------------------------- |
| `<store>/results/<key>/`  | a published result: outputs, diagnostics, digests |
| `<store>/manifests/<key>` | the manifest list of a declared key               |
| `<store>/leases/<key>/`   | one lease file per process using a result         |
| `<store>/staging/`        | entries being written                             |
| `<store>/trash/`          | entries being evicted or discarded                |

**BGS1: One store per machine.** Results **must** live in one store per user and
machine, at `$XDG_CACHE_HOME/sparkles/build` (`~/.cache/sparkles/build` when
unset), shared by every worktree and process.

**BGS2: Atomic publication.** A result **must** become visible only complete.

- **Staging:** its outputs, diagnostics and manifest are written to a private
  entry under `staging/`, so the publishing rename never crosses a file system.
- **Results:** a result is published by one rename to `results/<key>`.
- **Manifest lists:** a manifest list is replaced by writing a new list file and
  renaming it over the old one.

A reader never observes a partial entry.

**BGS3: Concurrent producers.** Two processes **may** compute the same result key
at once. Correctness **must not** depend on a lock: the first rename wins, and
the other producer moves its entry to `trash/`. Concurrent manifest-list
updates **may** lose an entry, which costs only a rebuild. A per-key advisory
lock **may** suppress duplicate work.

**BGS4: Leases.** A process **must** lease every result it looks up or
publishes, and **must** hold the lease until its run ends.

- **Lease files:** a lease is a file under `leases/<key>/`, named by the
  holder's process id and start time. A lease whose holder is gone is
  reclaimed.
- **Lookup:** lookup creates the lease, then checks that `results/<key>`
  exists, then reads it. A missing entry is a miss.
- **Read only:** outputs are read in place, and no process writes into
  `results/`.

**BGS5: Eviction.** The store **must** enforce a configured size bound, 20 GiB
by default, by evicting least-recently-used results. An eviction:

1. skips a result with a live lease;
2. renames the result into `trash/` under a unique name;
3. checks the leases again, and renames the result back if one appeared;
4. discards it instead if its key has been republished meanwhile.

Garbage collection removes `trash/` and stale `staging/` entries.

**BGS6: Corruption.** An entry whose recorded digests do not match its files
**must** be treated as a miss. It is renamed into `trash/` before it is
deleted, so a concurrent publisher never meets a half-deleted directory, and
a diagnostic is reported.

**BGS7: Inspection.** The store **must** provide operations to report its size,
list entries by key and age, and collect garbage. `apps/ci` exposes them as
`ci cache` subcommands.

## 7. Generators

A **generator** is a tool the graph runs to produce files that a compile
reads. There are three kinds:

- **The shader compiler**, run as `preGenerateCommands` declare.
- **A single-file D program** that a `preGenerateCommands` entry runs through
  dub: the `dmd` registry package's `config.d` is one.
- **The test-root module**, generated in-process (BGV2).

**BGG1: Typed generators.** Each generator **must** be a typed `generate`
action with declared inputs and declared outputs. Its tool is built by the
graph, except an in-process generator, which has none. A `preGenerateCommands`
entry that the resolver does not recognize as one of these kinds is a
resolution error, never a shell command.

**BGG2: Generated inputs replace in-tree paths.** A compile that reads generated
files **must** read them from the generator's output directory and **must**
depend on the generator action. Where the recipe names an in-tree output
directory (such as `stringImportPaths "generated/shaders"`), the generator's
output directory replaces that entry in the same position. The replacement is
a recorded divergence from dub
([decisions.md](./decisions.md#d8-generators-are-typed-nodes)).

**BGG3: Generators take explicit inputs.** A generator invoked by the graph
**must not** decide staleness itself; the cache decides. It receives its
sources, import paths, output directory and tool paths as arguments, and it
does not call dub or search `PATH`. The shader compiler gains a direct
invocation mode for this, and its own specification
([shaders build](../../shaders/build.md)) is amended with it.

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
- every generator tool;
- the **pinned test runner**: the test runner's implementation, built from a
  pinned revision of this repository rather than from the working tree
  ([decisions.md](./decisions.md#d16-the-test-runner-implementation-is-pinned-and-prebuilt)).

**BGT2: Store toolchains.** When a component resolves into a Nix store path, its
identity **may** be that path's closure of store paths, without reading file
contents. A wrapper script's referenced store paths are part of its closure.

**BGT3: Host toolchains.** Otherwise, a component's identity **must** be the
digests of the files BGT1 lists, found through the compiler's own reported
configuration. It **may** be cached per BGK5.

**BGT4: The pinned test runner.** Every test root **must** link the pinned test
runner's prebuilt library and compile against its import directory. The
test-runner shim, `sparkles:test-runner`, stays an in-tree `sourceLibrary` that
every package depends on through an ordinary `dependency`. A change to the
working tree's test-runner implementation affects only that package's own
tests until the pin is bumped.

## 9. Test actions and result reuse

**BGX1: Test actions.** A test action runs a linked test binary with a declared
argument vector, environment and working directory.

- **Working directory:** the requesting worktree's repository root, whatever
  the recipe's `workingDirectory` says. That directive governs only the run
  actions of applications and examples.
- **Outcome:** the binary's exit status and output.
- **No dub:** a test binary **must not** run dub, and the test runner
  **must not** fall back to it. The import paths, string import paths, dflags
  and versions that its compile-time and extracted modes need are passed to it
  as arguments, from the variant's resolved settings, together with a working
  directory for its probe files inside the task's directory.

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
backend.

- **Staging helper:** each derivation's builder is a small, deterministic
  staging helper. It copies or hard-links each store input, never symlinks it,
  to its repository-relative path under a private root directory.
- **The argument vector:** the helper then runs the action's normalized
  argument vector there, with the private root in the root placeholder's place
  (BGA6). So the recorded paths are root-relative, exactly as in the local
  backend.

**BGN2: Sources.** A compile derivation's source inputs **must** be its declared
inputs plus the complete file sets of the import, C import and string import
roots it searches. Each enters the store as a content-addressed path that the
build graph computes itself. Whole-repository source copies are not used.

An edit to any file under a searched root therefore re-runs the compiles that
search it, unlike the local backend's manifest check (BGK4). A backend **may**
narrow the inputs to a manifest that the local store already holds for the same
declared key, and retry with the full roots if that build fails.

**BGN3: Derivations without evaluation.** Derivations **must** be created
directly from their description (`nix derivation add`). Nix expression
evaluation is not on the build path.

**BGN4: Content addressing.** Derivations **should** be content-addressed
(`ca-derivations`), so that a compile whose output is unchanged stops the
rebuild of the archives and links that consume it. Where that feature is
unavailable, the backend **must** fall back to input-addressed derivations and
report it. That is the exception policy for this recommendation.

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

Each operation returns its errors as values. Planning and keying read recipes,
lex source files for version pruning and the layout lint, digest files and
query `pkg-config`, each through an explicit driver. They perform no other
I/O.
