---
status: accepted
owner: sparkles:build-primitives
reviewed: 2026-11-12
---

# Fileset-native workspace, resolution and tasks — Design

## Abstract

`sparkles:build-primitives` answers one question in many places: which files
can a unit of work read? Package selection answers it by directory prefix,
recipe resolution by walking directories, the hidden-edge lint by a second
prefix rule, and `ci` by a hand-written list. This design states the answer
once, as a fileset derived from a package's recipe, and derives the rest from
it: which packages a change affects, which directories a watch covers, what a
compile may read, what a sandbox stages and when a result is still fresh. Task
nodes carry the files they read and write, so the executor can order,
serialize, skip and re-run work without knowing what a task is.

## Introduction

A developer edits one module of a library and wants the smallest correct
reaction: rebuild what read it, re-test what depends on it, and leave the rest
alone. A continuous-integration run wants the same answer from a different
question, the difference between two revisions. A watch mode wants it again,
from file-system events. All three reduce to a relation between units of work
and the files they read.

The repository states that relation several times, and the statements
disagree. Package selection treats a package as its directory, so an edit to a
`README.md` beside a recipe selects that package and everything that depends
on it, while an edit to a source file that another package compiles through a
relative path selects nothing extra. Recipe resolution lists source
directories through an interface of its own, with its own in-memory double,
and produces flat file lists that are stale the moment a file is added. The
build-graph specification already requires every listing to be a fileset
resolution ([BGF5](./SPEC.md#_12-file-system-access)), but says nothing about
what the listed sets mean to selection, to keys, to tasks or to a watch.

The approach is to treat the relation as a value. A package's **input set** is
a fileset, written relative to the repository root, of every file its own
compile can read. It is derived from the recipe alone, without touching the
file system. Everything else is an algorithm over input sets: membership
answers which packages a path concerns, union over a dependency closure gives
what an action may read, resolution through the [capability VFS](../../base/vfs/SPEC.md) gives listings
and content ids, and the directories that resolution enters are the watch
list. An input set is deliberately coarse. The exact files a compile read are
known only after it ran, and the input manifest
([BGK2](./SPEC.md#_5-keys-and-the-input-manifest)) keeps that precision. The
input set is the sound upper bound that is known beforehand.

This design covers the workspace and resolver's types, the affected-set,
invalidation, input-identity and watching algorithms, and the file claims a
task node carries. It does not change what dub agreement means
([invariant 4](./SPEC.md#_1-invariants)), the action key and the manifest
(§5 of the specification), the store, or the Nix backend's derivations. It
adds no watcher to the fileset library, whose
[specification](../filesets/SPEC.md) keeps watching out of scope: the watch
lives in the event loop, and the fileset machine only reports which
directories it listed. A workflow language, persistent scheduler state and a
resident daemon stay out of scope.

Section 1 states the invariants and §2 the vocabulary. Section 3 assesses the
existing modules. Sections 4–7 define the proposed contract: workspace values,
materialization and identity, change and watching, and filesets in the task
model. Section 8 says which principle decided each choice, §9 records the
alternatives rejected, and §10 the prior art. Section 11 is the delivery plan,
§12 the evidence, §13 the amendments other specifications need, and §14 the
owner's decisions on the questions the design left open. The prototype
this design was tested against is
`sparkles.build_primitives.workspace.input_sets`.

## 1. Invariants

1. **The reads relation is stated once.** Which files a package's compile can
   read is one value, its input set. Selection, resolution, the hidden-edge
   lint, action declarations, sandbox staging and watching are derived from
   it and hold no second statement of it.
2. **A declared set is an upper bound; a manifest is the truth.** Every file
   an action read in the worktree lies in its declared read set, or the
   action fails
   ([BGK8](./SPEC.md#_5-keys-and-the-input-manifest)). No result is keyed by
   a declared set where a manifest exists.
3. **Deriving a set reads no file.** An input set is a pure function of recipe
   text, a configuration and a platform. Membership of a path is decided
   without that path existing.
4. **A scan is the authority; a watch is a hint.** A watch narrows which part
   of the tree is scanned again. Losing an event costs a scan, never a stale
   result.
5. **Ownership and reading are different relations.** A file belongs to at
   most one package's directory and may be read by any number of packages.
   Nothing that needs one relation is answered from the other.
6. **A task node states what it reads and writes; it states no identity.**
   Content ids, freshness and cache outcomes are computed from a node's claims
   at run time and travel in events, never in a node or its id.

## 2. Vocabulary

| Term                  | Meaning                                                                                                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Territory**         | The files under a package's directory that no nested package's directory holds. Territories partition the packaged part of the tree. Attribution uses them: reports, pickers, coverage, commit scope |
| **Input set**         | The fileset of every file a package's own compile can read in one configuration: its recipe, its source modules, everything beneath its import and string-import roots, and the files it names       |
| **Sources**           | The subset of an input set that the compile is given as modules: source roots and named files, without excluded ones                                                                                 |
| **Claim**             | A package claims a path when its input set holds it. A path has zero or more claimants                                                                                                               |
| **Reach**             | A start root of a package's input set that lies outside its territory                                                                                                                                |
| **Declared read set** | For an action, the union of the input sets of its package and of every package it depends on, with the workspace inputs. Known before the action runs                                                |
| **Workspace inputs**  | The files every plan depends on: the root recipe, the dependency lockfiles and the other entries of planning's read set ([BGP1](./SPEC.md#_11-public-surface))                                       |
| **Input state**       | What one resolution of a fileset observed: its members with their content ids, the id of their tree, the links crossed, and the directories listed                                                   |
| **Change set**        | A list of paths, each created, modified or removed, with a flag saying whether the source may have missed changes                                                                                    |
| **Write claim**       | A file or a directory tree that a task may create or modify                                                                                                                                          |

A _start root_ is the fileset planner's term
([FSA2](../filesets/SPEC.md#_6-analysis-and-planning-fsa)): a directory that
every member of a fileset lies beneath.

## 3. Assessment of the existing modules

This section describes the tree at revision `5ec7c3ae3`; every `file:line`
names that revision. Paths beginning `bp/` are under
`libs/build-primitives/src/sparkles/build_primitives/`. It is an assessment,
not a contract, and it ages with the code.

Two facts frame it. No command calls the selection planner: `planPackages`,
`selectPackages` and `gitChangesSince` are reached only from their own tests,
and `ci` builds its package lists with a discovery of its own
(`apps/ci/src/dub_deps.d:26-35`). The resolver has one outside consumer, the
agreement oracle (`apps/ci/tools/resolve-oracle.d`). Both layers can change
shape without breaking a shipped command.

### 3.1 `workspace/`

| Module            | Computes                                                                                                                                                                                            | Where it bypasses or duplicates filesets                                                                                                                                                                                                                                                                                                                                                                                                                                                                        | Stays                                                                                                                   |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `package_graph.d` | Package ids, directories, platforms, the in-tree dependencies of one configuration, a topological order (`:257-335`), and the owner of a path (`:189-202`)                                          | `discoverPackages` reads recipes by path through `std.file` (`:351-379`), outside the VFS and with no read set. `owner` is a longest-directory-prefix rule, implemented again in `bp/resolve/hidden_edges.d:134` and, differently, in `apps/ci/src/coverage.d:98-102`. `activeConfiguration` (`:237-248`) picks a configuration by a rule of its own, where `bp/resolve/project.d:553` implements dub's, and the two disagree on optional dependencies                                                          | `PackageId`, the sorted graph, its validation errors, the purity of `buildPackageGraph`                                 |
| `select.d`        | `--from` selectors, change ownership, repository-wide invalidators, the dependency and dependent closures and their reasons (`:283-383`); the changed paths since a revision, from git (`:492-596`) | A changed path seeds its directory's owner (`:329`), so reading is answered from ownership. A deleted path needs a second ownership map from the base revision (`:336-341`) and a `std.file` probe per path (`:600-610`). An invalidator is a path or a prefix (`:33-54`), in a list the consumer maintains by hand (`apps/ci/src/repository_invalidators.d:14-37`). The closure scans every edge per visited package (`:387-417`). `gitChangesSince` starts one `git show` per sub-package recipe (`:568-586`) | The selection algebra, its reasons and errors, `gitGlobMatch` (a selector names a package, not a file), the git queries |

The hand-written invalidator list shows the cost of a second statement. Two of
its entries, `apps/ci/src/commands/` and `apps/ci/src/cli.d`, name paths that
do not exist (`apps/ci/src/repository_invalidators.d:32-33`). Nothing fails,
because nothing derives the list from what planning reads.

Measured over the repository's 73 packages in the test role, with the
prototype:

| Edit                              | Ownership and dependents (`select.d`) | Input sets and dependents |
| --------------------------------- | ------------------------------------- | ------------------------- |
| a module under `libs/dql/src`     | 8 packages                            | 33 packages               |
| `libs/base/README.md`             | 66 packages                           | 0 packages                |
| a module under `libs/base/src`    | 66 packages                           | 66 packages               |
| `docs/specs/ui-app/resilience.md` | 0 packages                            | 0 packages (see BGW11)    |

The first row is unsound: `sparkles:ui`'s tests compile `libs/dql/src`
through `sourcePaths "../dql/src"` (`libs/ui/dub.sdl:76`), so an edit there
changes `ui`'s test binary, and ownership never selects `ui`. The other 24
packages follow from the dependents closure, which treats a package's test
configuration as what its dependents build; BGW12 narrows that. The second
row is wasteful. The fourth is the link case that decision
[D24](./decisions.md#d24-a-test-reads-a-specification-through-a-link-accepted)
records as open.

Three reaches exist in the repository's recipes, all in test configurations:
`ui` into `libs/dql/src`, `profiling-counters` into `libs/test-harness/src`,
and `font-oracle` into `libs/font/test`. Three recipes state a command
(`libs/ui`, `libs/ui-vulkan` and `libs/vulkan-wsi`, each to generate
shaders). One path and one flag are opaque (BGW4), both in
`sparkles:profiling`'s `tracy` and `unittest-tracy` configurations: an import
root and a library directory beneath `$SPARKLES_TRACY_PREFIX`, outside the
repository. The draft found none, because its prototype read only the
configuration the workspace's rule activates.

### 3.2 `resolve/`

| Module                                        | Computes                                                                                  | Where it bypasses or duplicates filesets                                                                                                                                                                                                                                                                                                                                                                                                         | Stays                                                                        |
| --------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------- |
| `driver.d`                                    | The I/O seam: `readText`, `isDirectory`, `exists`, `filesBelow`, `environment` (`:11-31`) | A second virtual file system. It takes absolute paths under ambient authority, where the VFS takes a held handle and a name. `filesBelow` walks with `dirEntries` and follows links (`:65-79`); a walk that throws returns the files found so far as if they were all of them (`:75-77`), where a fileset resolution fails whole. `MemoryDriver` (`:91-150`) duplicates `MemVfs` and tree literals, and its `isDirectory` scans every file       | The environment lookup, as a capability of its own: a variable is not a file |
| `recipe.d`                                    | dub's templates, defaults and per-platform application                                    | `collectFiles` (`:380-411`) is a fileset written as a loop: every file below a root, without hidden components (`:404`), whose base name matches a `std.path.globMatch` pattern (`:406`). `applyTemplate` calls it five times (`:320-331`), for the top level and again for the configuration, for every package of every request, and each call walks the tree again. `fillWithDefaults` probes for `source/`, `src/` and `views/` (`:229-241`) | The template model, dub's merge order, the main-file probe (`:246-258`)      |
| `settings.d`                                  | `BuildSettings`, dub's merge rules                                                        | Source, import and string-import files are flat `string[]` fields (`:90-125`), so a new file changes a resolved value that nothing recomputes. Exclusion is `globMatch` over paths (`:263-267`), a third glob dialect beside `gitGlobMatch` and fileset patterns                                                                                                                                                                                 | Every setting that is not a file list                                        |
| `project.d`                                   | The packages a request reaches and the configuration of each, as dub chooses it (`:553`)  | `Package` and `Project` are classes holding mutable associative arrays (`:63`, `:151`). `loadProject` reads and parses every recipe again for every request (`:246`, `:308`); the oracle's 621 requests parse the same recipes 621 times. `allDeclared` (`:168`) is a third package discovery. Errors are thrown and caught at the boundary (`:42-45`, `configure.d:146-160`)                                                                    | dub's configuration choice, the test-root configuration                      |
| `configure.d`                                 | Resolved settings for every target of a request                                           | `Resolution.environmentInputs` (`:109-115`) is a read set for variables only. The files and listings resolution depended on are not recorded                                                                                                                                                                                                                                                                                                     | dub's configuration steps, variables, the request and target types           |
| `hidden_edges.d`                              | Reaches into another package's directory without a dependency on it                       | It reads each recipe a second time to find line numbers (`:155-174`), re-derives the paths a recipe reaches (`:51-52`) and holds the second ownership rule (`:134`). With input sets, a hidden edge is a reach whose owner is not a dependency: a few lines over data that exists                                                                                                                                                                | The report's shape and wording                                               |
| `registry.d`                                  | The locked registry packages and their source directories                                 | Reads through the driver (`:30`, `:94`)                                                                                                                                                                                                                                                                                                                                                                                                          | The lock model                                                               |
| `libraries.d`, `platform.d`, `dub_versions.d` | `pkg-config` resolution, platform matching, version ranges                                | None. They list no directory                                                                                                                                                                                                                                                                                                                                                                                                                     | Everything                                                                   |

### 3.3 Consumers

`ci` holds a third discovery (`apps/ci/src/dub_deps.d:26-35`) and walks package
directories for `.d` files with `dirEntries`
(`apps/ci/src/app.d:4054-4069`, `:4198-4213`), which reads untracked and
ignored files and build output. About twenty call sites ask git for the
tracked files matching a glob (`app.d:1328`, `:1392`, `:1476`, `:2355`,
`:2421`, `:2519`, `:2658`, `apps/ci/src/fence_audit.d:1466`, and the tools).
`hue`'s pickers and site, and `libs/docs`, already list through
`listRepository`; one branch of `libs/docs/src/sparkles/docs/source_set.d`
(`:343-351`) still lists a directory by hand. `bp/dub_recipe.d` is a fourth reading of
recipes, for `hue` and `dmd-lsp`, and finds a file's recipe by walking up
through `std.file` (`:108-130`).

### 3.4 What filesets lack for this use

The prototype met four gaps. Each is small, and each belongs to the fileset
library.

- **Many sets, one path.** An evaluator answered for its root alone, so asking
  which of 73 sets hold a path meant 73 evaluators or 73 walks. The prototype
  adds `FilesetEvaluator.judge` and `selects`, which answer for every part of
  a fileset after one walk.
- **Evaluation costs the arena, not the expression.** An evaluator visits
  every node up to its root's index and skips the unreachable ones
  (`bp/fileset/value.d:419-450`). In an arena of 73 packages a query costs
  what the root's position costs: in an unoptimized build, 170 µs for a
  package built early and 800 µs for one built late, against 4 ms for one walk
  over the union of all of them. The evaluator needs to iterate its own
  reachable nodes.
- **No identity for an expression.** A `Fileset` is an index into a move-only
  arena (`bp/fileset/value.d:36-42`), and two filesets compare by index. A
  cache keyed by "this set, at this tree" needs a digest of the expression
  that is the same in the next process.
- **No report of the directories listed.** A sink hears the directories that
  hold members, and those selected whole and found empty. A watch needs every
  directory the resolution listed, members or not, and needs to hear of each
  before it is listed (BGW14).

One limit is by design and shapes BGW3: a `gitignored` leaf is empty to a
query that has no resolution to read `.gitignore` files from
(`bp/fileset/value.d:169-186`). Input sets are therefore written with
patterns alone, and never rely on ignore rules to exclude build output.

## 4. Workspace values

The signatures in this and the following sections are proposals unless a
sentence names the prototype. They show shape, not final spelling.

**BGW1: One reading of the recipes.** A run **must** read the root recipe and
each sub-package recipe at most once, through the capability VFS on the
worktree root ([BGF2](./SPEC.md#_12-file-system-access)), into one value. The
package graph, the input sets and recipe resolution **must** be derived from
that value and **must not** read a recipe again. The value carries the read
set of what produced it (BGP1).

```d
struct Workspace
{
    string rootName;         // `sparkles`
    PackageDecl[] packages;  // sorted by id
    ReadSet reads;           // every file read, with its digest (BGP1)
}

struct PackageDecl
{
    PackageId id;
    string directory;        // relative to the worktree root, `/`-separated
    DubManifest recipe;
}

PlanExpected!(Workspace, DiscoveryError) readWorkspace(V, Rights R)(DirRef!(V, R) worktree);
```

`Workspace` is a regular value: it holds no handle, compares by content, and a
test builds one from a tree literal.

_Rationale:_ three discoveries and four recipe readers cannot be kept in
agreement by review. One value that the others take as an argument can.

**BGW2: Territory.** The owner of a path **must** be the package whose
directory is the longest prefix of it at a component boundary, and there
**must** be one implementation of that rule. Ownership answers attribution
only: which package a file is reported under. It **must not** decide what a
change affects (invariant 5).

**BGW3: Input sets.** For a package, a configuration and a platform, the input
set **must** hold exactly the files the following table selects, each pattern
anchored at the worktree root. `D` is the package's directory and `P` a path a
directive states, resolved against `D` with `.` and `..` removed.

| Directive                               | Selects                                                                      | Sources |
| --------------------------------------- | ---------------------------------------------------------------------------- | ------- |
| the recipe                              | `D/dub.sdl`, or the recipe file in the form the package uses                 | no      |
| `sourcePaths P`                         | `P/**/*.d`                                                                   | yes     |
| `cSourcePaths P`                        | `P/**`; the sources are `P/**/*.c` and `P/**/*.i`                            | partly  |
| `sourceFiles P`, `injectSourceFiles P`  | what the glob `P` selects; for a C source, its directory too, whole          | yes     |
| `mainSourceFile P`                      | the file `P`                                                                 | yes     |
| `importPaths P`, `cImportPaths P`       | `P/**`                                                                       | no      |
| `stringImportPaths P`                   | `P/**`                                                                       | no      |
| `extraDependencyFiles P`, `copyFiles P` | what the glob `P` selects                                                    | no      |
| `excludedSourceFiles P`                 | removes what the glob `P` selects from the sources, never from the input set | —       |

A root that a compile searches is taken whole. What a compile may read
beneath an import root is not decided by a file's name: an import finds
`.d`, `.di` and C sources, a string import any file, and an include any
header. A C source also includes from its own directory, and the
preprocessor cannot report a lookup that failed there. The build graph's
conservative key and its Nix sources take the roots whole for the same reason
([BGK6](./SPEC.md#_5-keys-and-the-input-manifest),
[BGN2](./SPEC.md#_10-the-nix-backend)). The sources are narrower: beneath a
source root, a file with a hidden component is not a source, as dub skips it.

The table bounds what the compiler reads through the directives it lists. Two
things reach files that no row covers, and each makes its package opaque
(BGW4):

- **A flag that carries a path:** an import, string-import or include
  directory, a response or configuration file in `dflags`, or a library
  directory in `lflags`, unless a directive already states the same root.
- **A command:** `preGenerateCommands`, `preBuildCommands` and their
  siblings read and write what they like. The build graph replaces them with
  typed generators, whose tool, inputs and outputs are declared
  ([§7 of the specification](./SPEC.md#_7-generators)). A generator's inputs
  then join the input set, its tool's package becomes a dependency for
  selection, and its outputs are write claims (BGW16).

A directive qualified by a platform applies when the platform matches. The
set is the union over the recipe's top level and the selected configuration.
An excluded source file stays in the input set because an import path still
reaches it: a module that is not compiled can be imported.

```d
// Prototype: `inputSets` in workspace/input_sets.d. One set per package and
// configuration the host allows, keyed in `ConfiguredPackage` order.
struct InputSets
{
    ref const(Filesets) sets() const;              // one arena, patterns relative to the root
    ptrdiff_t indexOf(ConfiguredPackage pair) const;
    Fileset inputs(size_t set) const;
    Fileset sources(size_t set) const;             // a subset of `inputs`
    bool isOpaque(size_t set) const;               // an opaque entry concerns it (BGW4)
    Fileset workspace() const;                     // the workspace inputs (BGW12)
    const(string)[] rootsOf(size_t set) const;
    OpaqueDirective[] opaque;
}

InputSets inputSets(const ref PackageGraph graph, scope const(SubPackageRecipe)[] recipes,
    scope const(string)[] hostTokens, in WorkspaceInputs workspace) @safe nothrow;
```

_Detection:_ for every request the agreement oracle runs, the members of
`sources` that exist equal dub's source files, and the members of `inputs`
that exist include dub's source, import and string-import files (BGW8). For
every compile, each worktree path of its manifest, absent candidates
included, is a member of `inputs` of a package in its closure (BGW7).

**BGW4: Derivation is total and probes nothing.** Building an input set
**must not** read the file system and **must not** fail.

- **Defaults are candidates.** Where dub adds `source/` or `src/` when the
  directory exists, and `views/` likewise, the set holds every candidate. A
  directory that does not exist contributes no member, and one created later
  is already a member's parent.
- **Opaque directives are reported.** A path that names a variable other than
  a leading `$PACKAGE_DIR`, that is absolute, that climbs above the root, or
  that is no fileset pattern contributes nothing and is reported with its
  package, directive and value. So is a path-carrying flag or a command
  (BGW3). A command that needs soundness **must** treat a package with an
  opaque directive as claiming every path.

_Rationale:_ a probe makes the set depend on the tree, so creating a
directory would change a value that nothing recomputes. Holding the
candidates states the same fact without the dependency, and covers what the
build-graph specification calls an absent candidate.

**BGW5: One root per set.** A fileset is relative to one root. A package in
the worktree has its input set in the worktree's arena. A registry package's
input set is relative to its pinned source directory, a root of its own
(BGF2). Where that directory is immutable, as a Nix store path is, its
identity is the hash its lockfile pins, with no walk. A source directory that
can be written, such as dub's package cache, is materialized like the
worktree and verified against its pin
([BGR4](./SPEC.md#_2-recipe-resolution)). A claim or a member is therefore a
pair of a root and a path beneath it.

**BGW6: The claim query.** Given a path relative to the worktree root, the
workspace **must** report the packages whose input sets hold it, in package
order, without reading the file system. The path need not exist, so a deleted
file is answered like any other.

```d
// Prototype: `InputSets.eachClaimant`; the sink hears each claiming set.
void eachClaimant(Sink)(scope const(char)[] path, scope Sink sink);
```

The query consults each package's start roots first and evaluates only the
packages with a root above the path. A path beneath no start root costs one
prefix comparison per root and no evaluation.

**BGW7: Declared read sets.** An action's declared read set **must** be the
union of the workspace inputs with the input sets of its package and of every
package its variant depends on, at any distance. The import roots it holds
are the roots [BGK8](./SPEC.md#_5-keys-and-the-input-manifest) names, so
BGK8 becomes a membership test: an action whose manifest lists a file it read
in the worktree that its declared read set does not hold **must** fail, and
its result **must not** be published.

The test covers files read, as BGK8 does. An absent candidate may lie outside
every input set, and one kind always does: the D frontend looks for an
imported module relative to the compiler's working directory before it
searches the import paths, and a compile runs in the repository root
([BGA5](./SPEC.md#_4-the-action-graph)). Those candidates are no part of the
bound. BGW10 accounts for them when a result is reused, and the workspace
inputs (BGW12) hold the paths such a lookup could find, so selection
accounts for them too ([D49](./decisions.md#d49-the-names-at-the-worktree-root-are-a-workspace-input-accepted)).

```d
Fileset declaredReads(ref InputSets inputs, const ref Request request);  // its closure's sets, and the workspace inputs
```

A reach (§2) whose owner is not among the package's dependencies is a hidden
edge ([BGR8](./SPEC.md#_2-recipe-resolution)). The lint is that comparison,
and it holds no path logic of its own.

## 5. Materialization and identity

**BGW8: A listing is a resolution of an input set.** The ordered source,
import and string-import file lists of resolved settings **must** be produced
by resolving the package's filesets with the fileset driver over the worktree
root (BGF5), and **must not** be stored as independent fields that a later
edit can leave stale. Resolution splits in two:

- **Symbolic resolution** turns recipes, a request and a platform into
  settings whose file-valued fields are filesets. It reads recipes, the
  environment and `pkg-config`, and lists nothing. The one probe dub's
  defaults need that is not a candidate set, the main-file search for a
  recipe without configurations, is a VFS lookup recorded in the read set as
  found or absent.
- **Materialization** resolves those filesets into lists and ids.

Dub agreement (invariant 4 of the specification) is checked on the
materialized lists. A dub glob whose meaning no fileset pattern reproduces
exactly is reported as opaque (BGW4), never approximated: `std.path.globMatch`
lets `*` cross a separator, and a fileset pattern does not.

**BGW9: Input state.** Materializing a fileset **must** yield an input state:
the members in path order, each with the content id of the bytes read; the id
of the members' tree; every symbolic link a lookup crossed, with its target;
and every directory the resolution listed.

```d
struct Member { string path; Digest id; }
struct InputState
{
    Digest id;          // of the members' tree
    Member[] members;   // in path order
    LinkRead[] links;
    string[] listed;    // every directory listed, members or not
}

ResolutionResult observe(V, Rights R, Cache, Exec)(DirRef!(V, R) root, ref const Filesets sets,
    Fileset set, ref Cache cache, ref Exec exec, out InputState state);
```

An input state is a regular value. Two states of one set compare by `id`, and
their difference is a merge of two sorted lists:

```d
ChangeSet difference(const ref InputState before, const ref InputState after) @safe pure nothrow;
```

The state's `id` **must** cover what a reader of the members would read: the
members' tree, and for each link crossed, the content id of its target. A
link is a value in the tree, its target text and nothing more
([FSO2](../filesets/SPEC.md#_3-the-file-system-object-vocabulary-fso)), so
the tree id alone does not change when the file a link names does.

One digest cache serves every reader. The subtree cache's fingerprint and
validation rule ([FSC2 and FSC3](../filesets/SPEC.md#_12-the-subtree-cache-fsc))
and the build graph's digest cache
([BGK5](./SPEC.md#_5-keys-and-the-input-manifest)) are one mechanism stated
twice: a tuple of size, device, inode, modification time and change time,
trusted only when older than the recording run by a margin. The statements
differ in two details, which the single statement keeps: BGK5 reads the
recording time from the file system's own clock, which is how a caller
obtains the stamp FSC3 asks for, and BGK5 always hashes a file whose
modification time lies in the future. A file's content **must** be hashed at
most once per run, whichever of the manifest, the state id or a Nix source
needs it. That one digest is BLAKE3
([D48](./decisions.md#d48-one-leaf-digest-blake3-accepted)): each consumer
encodes its own tree over the leaf, and SHA-256 is computed only where an
external format demands it, at export.

**BGW10: The state id is a gate, never a key.** A result **may** be reused
without checking the entries of its manifest that lie in its declared read
set, when the input state id of that set (BGW9) equals the one recorded with
the result and the declared key is the same. The manifest's other entries are
its **residue**, recorded with the result when it is published:

- **Absent candidates outside the set.** Each is checked: it must still be
  absent. A candidate stands for its highest missing ancestor, so the
  working-directory candidates of BGW7 cost one lookup per top-level package
  name.
- **Files under a root the key covers.** The toolchain and a registry source
  held in an immutable store need no check.
- **Files under any other root.** A header that `pkg-config` located in a
  host directory is one. Each is checked as
  [BGK3](./SPEC.md#_5-keys-and-the-input-manifest) checks any entry.

When the ids differ, the manifest decides, exactly as BGK3 states. A
differing id **must not** by itself cause an action to run.

_Rationale:_ every manifest entry inside the declared read set is a member of
it, or a path that would be one, so an unchanged state leaves each of them
unchanged; the residue is what that argument does not reach. The converse
fails by design: an edit to a module that a dependent never imported changes
the set and not the manifest
([BGK4](./SPEC.md#_5-keys-and-the-input-manifest)).

The conservative key of
[BGK6](./SPEC.md#_5-keys-and-the-input-manifest) and the Nix backend's source
inputs ([BGN2](./SPEC.md#_10-the-nix-backend)) are the declared read set's
input state id and its tree. They need no listing code of their own.

**BGW11: Links join the claim index.** When materialization crosses a link
whose target lies in the worktree, the target **must** be recorded as claimed
by every package whose input set holds the link. The claim query (BGW6)
**must** consult those recorded targets after the patterns.

_Rationale:_ `libs/ui-app/spec/resilience.md` links to
`docs/specs/ui-app/resilience.md`. The pattern claims the link, not the
catalog, so an edit to the catalog selects no package (§3.1, fourth row).
Only a resolution knows a link's target.

## 6. Change: affected sets, invalidation and watching

**BGW12: Affected requests.** A **request** is what a command resolves and
builds: a root package, its configuration or test root, and a platform. Its
**closure** is the set of package and configuration pairs its resolution
chose, the root's included (`Resolution.configurations`). Input sets are
keyed by those pairs (BGW3). The requests a change set affects **must** be
those whose closure holds a pair claiming one of its paths. A change to a
workspace input affects every request. A path that no pair claims and that
is no workspace input affects no request. A selection seeded only by such
paths is the empty-selection error the task DAG defines, and it names the
paths.

A pair is affected only through the requests that reach it: a path that only
`ui`'s test configuration claims affects `ui`'s test root and no request that
builds `ui` as a dependency, because none of those closures holds
`ui:unittest`. A command whose query has no request of its own, such as
`--since` with no target, asks over the requests it would make: for `ci`, the
test root of each package `ci --test` runs and each build configuration of
each application. A package is affected when a request rooted at it is
([D47](./decisions.md#d47-an-input-set-follows-the-resolver-s-configurations-accepted)).

```d
struct ConfiguredPackage { uint package_; string configuration; }
struct Request { string name; ConfiguredPackage[] closure; }   // closure sorted, each pair once

// Prototype: `affectedBy` in workspace/input_sets.d.
AffectedRequests affectedBy(ref InputSets inputs, scope const(Request)[] requests,
    scope const(string)[] changed) @safe nothrow;
```

The workspace inputs shrink the hand-written invalidator list to what cannot
be derived. Four kinds of entry make them up:

- **Planning's read set** (BGP1): the root recipe, the lockfiles and whatever
  else planning read. Derived, so it cannot name a path that does not exist.
- **The planning command's own closure:** the command that plans and runs the
  work is itself a package, and a change claimed by its dependency closure
  affects every package. Derived from the package graph.
- **The toolchain's definition:** the files that pin the compiler and the
  shell. No plan reads them, so they stay a fileset the consumer declares.
- **What the compiler's working-directory lookup could find** (BGW7): every D
  or C source directly beneath the worktree root, and everything beneath a
  top-level directory named as the first component of an importable module,
  the toolchain's (`std`, `core`, `etc`, `ldc`) included
  ([D49](./decisions.md#d49-the-names-at-the-worktree-root-are-a-workspace-input-accepted)).
  The names come from the first level of every import root, which
  materialization lists anyway; until it does, the consumer states them.

_Rationale:_ the result is sound and coarse. A dependent reads only some of a
dependency's modules, and which ones is in its manifest. Selection chooses
packages to plan; keys decide what runs.

Closures are what narrow the first row of §3.1: the 24 dependents of `ui` it
counts build `ui` in `library`, and no closure of theirs holds `ui:unittest`,
the pair that claims `libs/dql/src`.

**BGW13: Change sources are interchangeable.** Every source of change
**must** produce the same value, and every consumer **must** accept any
source.

```d
enum ChangeKind : ubyte { modified, created, removed }
struct PathChange { string path; ChangeKind kind; }
struct ChangeSet
{
    PathChange[] paths;  // sorted, each path once
    bool lossy;          // the source may have missed changes
}
```

| Source                | Produces                                        | `lossy`                     |
| --------------------- | ----------------------------------------------- | --------------------------- |
| git, since a revision | committed, staged, unstaged and untracked paths | never, for what git sees    |
| two input states      | `difference(before, after)`                     | never                       |
| a watch               | the paths of a batch of events                  | on overflow or a lost watch |

A consumer given a lossy change set **must** materialize every input set it
depends on again. Git reports no ignored file. An input set that holds
ignored files, such as generated sources, is therefore compared by input
state, whatever git reports. With git as the source, a removed path is claimed by the
current input sets and by those built from the base revision's recipes. No
existence probe is needed, because membership is decided without the file.

**BGW14: The watch list is what the resolution listed.** A watch of a set of
packages **must** cover exactly the directories that materializing their
input sets listed (`InputState.listed`), which the fileset machine reports
([`FSS9`](../filesets/SPEC.md#8-the-scheme-seam-fss)).

- **Watch before list.** A directory **must** be watched before it is listed,
  so that no change falls between the listing and the watch.
- **The watch names the directory listed.** A watch is added by path and a
  listing goes through a handle, so the two can name different directories
  after a rename. The identity of the watched path **must** equal that of the
  handle listed, and a mismatch is a loss.
- **Roots that do not exist.** For a start root that does not exist, such as
  a default directory nobody created, the nearest existing ancestor **must**
  be watched for the creation of the next component.
- **New directories.** An event that names a directory is judged by the
  set's verdict on that directory, never by the claim query, which answers
  for files. A directory whose verdict is not `skip` **must** be watched and
  then resolved.
- **Filtering.** An event that names a file no watched package claims
  **must** be dropped without a system call.
- **Loss.** A queue overflow, a watch the kernel dropped, a watched directory
  that was moved, and a watch the kernel refused for want of capacity
  **must** each yield a lossy change set.

A directory the fileset rules out, such as a package's `docs/` or its test
data, is never listed and so never watched. A recipe that makes a whole
package directory an import root claims everything in it, build output
included, and is listed in full.

**BGW15: A watch mode is a loop of complete runs.** A command in a watch mode
**must** plan, run the executor to completion, wait for a change set, and
repeat. Each run is an ordinary run: when it returns, no task fiber, child
process or channel user remains, as the task DAG requires. State that
outlives a run is data: the workspace, the input sets, the input states and
the store.

Between runs the command does the least that the change set requires:

| Change                                        | Reaction                                                                                      |
| --------------------------------------------- | --------------------------------------------------------------------------------------------- |
| a file of the read set (a recipe, a lockfile) | read it again; derive the workspace, the input sets and the plan again; adjust the watch list |
| a member created or removed                   | list that one directory again; if a `sources` set changed, plan that package's actions again  |
| a member modified                             | `stat` and, if the fingerprint moved, hash that one file; an unchanged id ends the reaction   |
| a lossy change set                            | materialize every watched input set again, through the cache                                  |

Version pruning adds to the last three rows. Its scan of a variant's roots
is part of the variant's key, and the digest of the listing it scanned is
part of the declared key
([BGV1](./SPEC.md#_3-variants), [BGK1](./SPEC.md#_5-keys-and-the-input-manifest)).
A member created or removed under a scanned root therefore plans again every
variant whose scan covers that root. A modified member under one is lexed
again, and plans those variants again only if the identifiers it mentions
changed.

The next run then contains the actions that are stale: those whose declared
read set claims a changed path, less those whose manifest proves the path was
never read, and whatever depends on an action that ran.

### One edit, traced

The command is `ci build --watch :text-lab`. The developer saves
`libs/base/src/sparkles/base/buffer.d`.

**Before the edit.** The command reads 74 recipes once (BGW1) and derives the
input sets of `text-lab` and the packages it depends on: 29 of the
repository's 73 packages, whose sets start at 29 directories. It materializes
them: one `readDir` for each listed directory, one `stat` for each member,
and one read and hash for each member the digest cache does not vouch for.
Measured with the prototype's sets on the review date, that is 138 of the 509
directories beneath those roots and 669 of the 1384 files; the fileset rules
the rest out without listing them. Each of the 138 directories is watched
before it is listed. The build runs, and each compile records its manifest.

**The edit.** The kernel reports a write, or a rename onto the name, in the
watched directory `libs/base/src/sparkles/base`.

1. The path is put to the claim query: `sparkles:base` claims it. No system
   call is made. Had the developer saved `libs/base/README.md`, no package
   would claim the path and the event would end here. An editor's swap file
   beside the module is claimed, because an import root is taken whole; it
   costs one `stat` and one hash, no manifest lists it, and nothing runs.
2. One `stat` of `buffer.d`, on the handle of its directory. The fingerprint
   differs from the recorded one, so the file is opened and hashed once. If
   the id equals the recorded id, as after a save without a change, nothing
   else happens.
3. The id of each directory above it is computed again from recorded
   entries, with no I/O. `base`'s input state has a new id, and so has the
   declared read set of every action whose closure contains `base`. The gate
   (BGW10) is closed for those actions and the manifests decide.
4. `base`'s compile lists the file among its own sources, so its declared
   key changed and it runs. For each other compile in the closure, the
   manifests of its declared key are consulted, most recently used first
   (BGK3). If one matches, which requires that it not list `buffer.d` at its
   old digest, the compile is fresh and does not run. Otherwise it runs. These compiles do not wait for `base`'s: a dependent reads
   sources, not archives.
5. `base`'s archive runs if the compile's outputs changed, the link of
   `text-lab` if an archive it consumes changed, and nothing else.

Had the edit created `libs/base/src/sparkles/base/ring.d`, step 2 would list
the directory again and find a new member of `base`'s sources. `base`'s
compile gains an argument and its declared key changes. So does the declared
key of every variant whose pruning scan covers `base`'s roots, because the
listing it scanned changed (BGV1): those compiles run as well. That cost is
the specification's, and the input sets only make it visible.

Had the kernel's queue overflowed, the change set would be lossy. The command
would materialize all 29 input sets again: 138 `readDir` calls and 669 `stat`
calls, with no file read unless a fingerprint moved.

If a second save arrives while `base`'s compile runs, the watch reports a
path in a running action's declared read set. That is the condition
[BGK7](./SPEC.md#_5-keys-and-the-input-manifest) detects with its stat
check, which stays the authority. The action is not published, and the next
iteration of the loop is the one rerun that BGK7 allows.

## 7. Filesets in the task model

A task node states a kind, an action, a weight and a list of exclusive string
keys (`bp/task/model.d:210-220`, `:291-301`). A task that rewrites a file
claims it by a naming convention, `workspace-write:<path>`
(`bp/task/model.d:251-252`), which the executor compares as text
(`bp/task/executor.d:427-436`). Two tasks that write `docs/` and
`docs/a.md` hold different keys and run together. A node says nothing about
what it reads, so the executor cannot tell whether a task is stale, what a
dry run would touch, or which edge is missing.

**BGW16: File claims.** A task node **must** be able to state the files it
reads and the files it writes.

```d
struct WriteClaim
{
    string path;  // relative to the worktree root
    bool tree;    // the directory `path` and everything beneath it
}

struct FileClaims
{
    Fileset reads;        // a fileset of the graph's arena; `Fileset.init` states nothing
    WriteClaim[] writes;
}

struct TaskNode
{
    // … the existing fields …
    FileClaims files;
}
```

The task graph owns the arena its nodes' read sets are built in, as it owns
the nodes: a handle means something only within its graph, like a task index.
A read claim is any fileset. A write claim is a file or a directory tree,
the two forms an action's declared outputs take
([BGA3](./SPEC.md#_4-the-action-graph)).

A build-graph action's node reads its declared read set (BGW7). A
documentation rewrite reads and writes its file. A node that states nothing
is treated as today: it conflicts with nothing and is never skipped.

**BGW17: Conflicts are derived.** Graph validation **must** decide, for each
pair of nodes with file claims, whether one may write what the other reads or
writes. A write claim conflicts with a fileset unless the fileset's verdict
on the claim's path proves otherwise: `reject` for a file, `skip` for a
tree. The verdict is taken with no facts about the entry, so `undecided`
is a conflict, and a leaf whose answer needs a resolution, as an ignore
scope does, counts as possibly holding the path. A write claim also
conflicts with a fileset that holds a link to its path (BGW11). Two write
claims conflict when one path is the other or lies beneath it.

- **Write and write.** Two nodes whose writes conflict **must not** run at
  the same time. The executor serializes them, as it serializes holders of
  one exclusive key.
- **Read of a write.** A node that reads what another writes **must** be
  ordered with it by a path of edges. Validation rejects a graph in which
  neither precedes the other, naming both nodes and the path. Inferring the
  edge was rejected: it would hide the planner's mistake
  ([T15](../task-dag/decisions.md#t15-an-unordered-read-of-a-write-rejects-the-graph)).

_Rationale:_ the verdicts are proofs in one direction. `skip` and `reject`
show that no member can lie there, so a pair declared conflict-free is. A
pair the evaluator cannot separate is serialized or rejected, which costs
parallelism and never correctness.

Exclusive keys stay for resources that are not files, such as a publication
slot.

**BGW18: Freshness is an event.** A task's identity **must not** contain a
content id (invariant 6;
[OBD2](../observability/SPEC.md#_11-run-records)). When a command enables
freshness for a node, the executor's caller supplies a function from a node
to its input identity, and the executor reports what it decided:

```d
/// The task did not run: a result recorded for the same action and inputs is reused.
struct TaskFresh { TaskIndex task; Digest inputs; }

/// The task runs because of this; `TaskEvent.text` holds the path, when there is one.
struct TaskStale { TaskIndex task; StaleReason reason; }
```

The reasons are those the observability specification records for a miss
([OBA8](../observability/SPEC.md#_4-action-metrics)), with two more for
tasks outside the build graph: no recorded result, and a prerequisite that
ran. A reporter can then say why each task ran, in terms of a path.

For a build-graph action, the input identity is its key and the store decides
(§5 of the specification). For any other task, a command **may** take the
input state id of the node's read set, with the action and its environment,
as the identity of a recorded verdict. That reuse is as sound as the read
claim is
complete, so a command **must not** enable it for a node whose read claim it
cannot justify. A test that reads the network, the kernel or an undeclared
file is such a node ([BGX3](./SPEC.md#_9-test-actions-and-result-reuse)).

**BGW19: One declaration, every enforcer.** The file claims of a node are the
only statement of what its action may touch. Lowering to a Nix derivation
stages the read set's tree (BGN2). A sandbox grants read access to the
directories the read set's resolution listed and to the link targets it
recorded, and write access to the write claims. A dry run prints both. None of these **may** hold a list of its own.

What this buys:

| Consumer        | Without file claims                                        | With them                                                                                  |
| --------------- | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Executor        | Serializes by string equality                              | Serializes by overlap; rejects an unordered read of a write                                |
| Watch mode      | Written once per command, with knowledge of each task kind | One loop: stale nodes are those whose read set claims a changed path, and their dependents |
| Reporters       | "ran"                                                      | "ran: `libs/base/src/…/buffer.d` changed"; "fresh"                                         |
| Dry run         | Argument vectors                                           | Argument vectors, start roots read, paths written                                          |
| Nix and sandbox | A staging list computed by the backend                     | The node's read set                                                                        |

## 8. The principles that decided

The principles are those of the
[Sean Parent catalog](../../../research/sean-parent/index.md).

| Choice                                                                                                                | Principle                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One input set, from which selection, listing, lint, staging and watching derive (inv. 1)                              | [Relationships](../../../research/sean-parent/relationships.md): a relationship that matters is represented once, explicitly. Four implicit copies of "reads" had already drifted apart                                                                 |
| Ownership and reading kept apart (inv. 5, BGW2)                                                                       | Relationships again: ownership is whole and part, a partition; reading is many to many. Modelling the second with the first is the measured error of §3.1                                                                                               |
| `Workspace`, `InputSets`, `InputState`, `ChangeSet` as values; the driver interface and the `Project` classes retired | [Regular types](../../../research/sean-parent/regular-types.md) and [value semantics](../../../research/sean-parent/value-semantics.md): a value can be compared, copied, cached and built in a test. Invalidation becomes the difference of two states |
| A fileset handle in a node, the arena in the graph (BGW16)                                                            | Value semantics at the right whole. The graph is the value; a handle is a part that means nothing alone, as a task index does. The cost is recorded in §9, alternative 5                                                                                |
| Derivation that is pure, total and probes nothing (BGW4)                                                              | [Local reasoning](../../../research/sean-parent/local-reasoning.md): a function of recipe text can be understood and tested without a tree, and nothing far away can invalidate its result                                                              |
| Declared read set as a bound that BGK8 enforces; write claims that validation checks                                  | [Contracts](../../../research/sean-parent/contracts.md): the read set is an action's frame condition, checked after it ran; a write claim is its postcondition                                                                                          |
| Affected set as claim query plus closure; conflict as a verdict; change as a merge                                    | [Algorithms](../../../research/sean-parent/algorithms.md): each replaces a hand-written loop (`select.d:387-417`, `hidden_edges.d:134`, `recipe.d:380-411`) with a named operation over a named structure                                               |
| The start-root index; no string keys for file claims                                                                  | [Data structures](../../../research/sean-parent/data-structures.md): `workspace-write:<path>` is a set of paths encoded in a string, an incidental structure. The index is one chosen for the query it serves                                           |
| A watch mode as a loop of complete runs, fed change sets (BGW15)                                                      | [Concurrency](../../../research/sean-parent/concurrency.md): no state is shared between the watcher and a run. A batch of events is a value handed over between runs                                                                                    |
| One root handle, read-only; claims that a sandbox can enforce (BGW19)                                                 | [Safety](../../../research/sean-parent/safety.md): what code can touch is what it was handed, and the same declaration that plans the work confines it                                                                                                  |

## 9. Alternatives rejected

1. **Filesets as the listing mechanism only.** Replace `filesBelow` with a
   fileset resolution, as BGF5 literally requires, and keep ownership by
   prefix, the invalidator list and flat file lists. Rejected: it leaves the
   four statements of the relation in place, and the first two rows of §3.1
   unchanged.
2. **The input set's tree id as the action key.** One hash of a package's
   files and of its dependencies' files, as task runners for script-based
   monorepos use. Rejected for compiles: an edit to any module of
   `sparkles:base` would rebuild all 66 packages above it, which BGK4
   forbids. Kept as the gate (BGW10), as the conservative key (BGK6), and as
   the identity of tasks that have no manifest (BGW18).
3. **A node per file.** Give each source file its own node and let edges
   carry the precision. Rejected: a D compile takes a package's modules in
   one invocation (BGA2), and the files it reads from elsewhere are known
   only afterwards. The manifest already holds file-level precision where it
   can be known.
4. **Expanded lists in resolved settings and nodes.** Keep resolving globs to
   lists at planning time, as the resolver does. Rejected: a list cannot
   answer for a path that does not exist, which deletion, creation and absent
   candidates all require; it is stale after any addition; and it puts a
   payload proportional to the tree on every node.
5. **Self-contained fileset values.** Make each fileset own its expression,
   so that it copies and compares alone, and drop the arena. This is the more
   regular type. Rejected because evaluation shares one compiled pattern set
   and one state layout across the sets of an arena, which is what lets a
   single walk answer for many sets. The regularity that matters is kept one
   level up, where the arena's owner is the value. An expression digest
   (§3.4) supplies comparison across processes.
6. **The watcher as the authority.** Keep a continuously updated model of the
   tree and trust it. Rejected by the fileset decisions
   ([A9](../filesets/decisions.md)) and by invariant 4: event queues
   overflow, watches are dropped, and a missed event would then be a wrong
   build.
7. **Content ids in nodes or task ids.** Rejected: an id is a fact about a
   moment, a node is a fact about a plan, and OBD2 keeps ids out of task
   identity so that measurements line up across runs.
8. **Filesets on build-graph actions only.** Keep `TaskNode` ignorant and let
   each command hold its own claims. Rejected: the executor would still
   serialize by string, and every watch mode and every freshness check would
   be written per command.
9. **One global evaluator for the claim query.** Evaluate the union of every
   input set per path. Built first, and measured at 4 ms a path in an
   unoptimized build. Rejected for the start-root index, which evaluates only
   the packages that can claim the path.

## 10. Prior art

Every row was read in source, in the clone under `$REPOS` at the revision
named. A path is relative to that clone. What could not be confirmed is said
so.

**Sets as values, and the owners of a changed file.**

| System                 | What the source shows                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Bearing                                                                                                                      |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| Pants (`d3ef404e`)     | A target's sources stay a glob value on the field, and expansion is a separate rule: `HydratedSources` carries both the snapshot and the glob specification (`src/python/pants/engine/target.py:1528-1541`). Owners of changed files are found by ancestor directory and then by matching each candidate's globs in memory (`src/python/pants/engine/internals/graph.py:1236-1324`). The matcher is kept apart from expansion "in order to allow for owners detection of deleted files" (`src/rust/fs/src/glob_matching.rs:321-357`) | The closest precedent for BGW3, BGW6 and BGW8: a symbolic set, a materialized snapshot, and a claim query that needs no file |
| Buck2 (`9b15b7af`)     | `glob()` is expanded in the interpreter against a per-package listing, which is the incremental key (`app/buck2_common/src/package_listing/dice.rs:45-80`). `owner()` takes the enclosing package and compares the path with each target's expanded inputs for equality (`app/buck2_query_impls/src/uquery/environment.rs:349-397`), so a deleted file has no owner                                                                                                                                                                  | What alternative 4 costs: an expanded list cannot answer for a path that no longer exists                                    |
| Bazel (`e36c0dfd`)     | `glob()` returns a list at loading time (`src/main/java/com/google/devtools/build/lib/packages/StarlarkNativeModule.java:96-122`); the pattern survives only as an invalidation key (`…/skyframe/GlobDescriptor.java:36-70`). A file is itself a target, so ownership is a reverse dependency. No command in the tree maps changed files to targets                                                                                                                                                                                  | The same expansion, with the listing dependency made explicit                                                                |
| Nx (`7a0d20e4`)        | A file is assigned to the innermost project root (`packages/nx/src/native/workspace/workspace_files.rs:13-39`), and task inputs are globs filtered within that assignment (`packages/nx/src/native/tasks/hash_planner.rs:1316-1368`). Affected projects were found by root prefix (`packages/nx/src/native/affected/projects/touched_projects.rs:6`); the current default "matches the changed paths against every plan. No project-level prefilter" (`packages/nx/src/project-graph/affected/affected-tasks.ts:234-239`)            | A system that began with ownership by prefix and moved to matching declared inputs, the move BGW12 makes                     |
| Turborepo (`4e3bdf1e`) | A changed file maps to the deepest containing package, and a file in no package selects every package (`crates/turborepo-repository/src/change_mapper/package.rs:83-110`). A newer mode checks "each task's `inputs` globs against a set of changed files" (`crates/turborepo-engine/src/affected.rs:4-5`, `:69`)                                                                                                                                                                                                                    | The same migration; and the over-selection of §3.1's second row, as a default                                                |
| nixpkgs `lib.fileset`  | A fileset is a base path and a lazy tree whose leaves are a whole directory, a file type or nothing; union, intersection and difference recurse over it and stop at a wholly included directory (`lib/fileset/internal.nix`, `README.md`, read in the copy of nixpkgs 26.11 in the Nix store)                                                                                                                                                                                                                                        | The three-valued tree of the fileset evaluator's verdicts                                                                    |

**Declared inputs, observed inputs, and identity.**

| System             | What the source shows                                                                                                                                                                                                                                                                          | Bearing                                                                                                             |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Cargo (`e7155031`) | A compiler unit's inputs come from the compiler's dependency file, and a unit with none is stale (`src/compiler/fingerprint/mod.rs:236-241`, `:961-963`). A build script that has not run yet watches "the whole crate", and afterwards only what it declared (`:1741-1746`, `:1879-1897`)     | Invariant 2's two tiers: a coarse set before the first run, the observed one after                                  |
| Pants              | A process carries its inputs as one digest value (`src/python/pants/engine/process.py:105-116`), and that digest is the root of its cache key (`src/rust/process_execution/src/cache.rs:82-94`)                                                                                                | Alternative 2 where it fits: an action with no manifest                                                             |
| Buck2              | A fingerprinted directory of a command's inputs is built before it runs and is the action digest's input root (`app/buck2_execute/src/execute/request.rs:209-260`, `…/command_executor.rs:210`, `:405-407`)                                                                                    | The declared read set's tree, as BGN2 uses it                                                                       |
| Bazel              | Locally, an order-independent digest of each input's path and metadata is folded with the action key (`…/actions/MetadataDigestUtils.java:54-71`, `…/actions/cache/ActionCache.java:501-517`). Remotely, a tree digest of the inputs is (`…/remote/merkletree/MerkleTree.java:45-47`)          | Two identities for one input set, a flat one and a tree, the leaf one digest and the tree chosen per consumer (D48) |
| Nx, Turborepo      | A task's hash covers the hashes of its input files and of the tasks it depends on (`packages/nx/src/native/tasks/hashers/hash_project_files.rs:36-97`; `crates/turborepo-hash/src/lib.rs:56-84`)                                                                                               | Alternative 2 as a whole design, for tasks whose reads cannot be observed                                           |
| snix castore       | A directory's id is BLAKE3 over a canonical message of three sorted lists (`snix/castore/src/nodes/directory.rs:71-73`). Ingestion takes no filter; the filter is applied a layer above, pruning rejected directories (`snix/glue/src/builtins/import.rs:15-105`)                              | The tree id of BGW9, and selection kept apart from identity                                                         |
| dub (`48a55109`)   | Source paths are expanded with `dirEntries`, dropping hidden entries (`source/dub/recipe/packagerecipe.d:234-300`). The build id hashes settings and no file content (`source/dub/generators/build.d:351-370`), and staleness compares modification times over the expanded lists (`:400-437`) | The lists BGW8 must reproduce, and the behaviour the build graph replaces                                           |

**Watching, and what a change invalidates.**

| System    | What the source shows                                                                                                                                                                                                                                                                                     | Bearing                                                                                 |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Buck2     | A change to a file's contents dirties that file's keys; an entry added or removed also dirties its directory's listing (`app/buck2_common/src/file_ops/io.rs:455-522`). Directory events from the watcher are ignored and recomputed, because the watcher "is not aware of our ignore rules" (`:535-546`) | The rows of BGW15's table, and BGW14's filtering by claims                              |
| Bazel     | A listing is invalidated when an entry's type or existence changes, and by default not when its contents do (`…/skyframe/FileSystemValueCheckerInferringAncestors.java:345-353`)                                                                                                                          | The same distinction                                                                    |
| Pants     | A data-only event invalidates the file; any other event also invalidates its parent directory, and a rescan invalidates everything (`src/rust/watch/src/lib.rs:191-238`)                                                                                                                                  | The same distinction, and the lossy change set                                          |
| Turborepo | A watched change is mapped to packages, each is hashed again, and only a package whose hash differs triggers work, which is then an ordinary run over a pruned graph (`crates/turborepo-package-watcher/src/package_changes_watcher.rs:673-714`, `:1031-1046`; `crates/turborepo-watch/src/lib.rs:1014`)  | BGW15: a watch mode as a loop of complete runs, with the content id as the early cutoff |

**Write claims.**

| System | What the source shows                                                                                                                                                                                                                                             | Bearing                                                |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------ |
| Buck2  | Declared outputs are claimed in a path trie as they are declared; a path already claimed, or a claim beneath or above one, is an error (`app/buck2_build_api/src/actions/registry.rs:71`, `:128-180`)                                                             | BGW16's two forms of write claim, and BGW17's conflict |
| Bazel  | After analysis, outputs are sorted and adjacent pairs checked: "one action generates an artifact whose path is a strict prefix of another artifact's path. Those two artifacts cannot exist simultaneously in the output tree" (`…/actions/Actions.java:319-375`) | The same rule, checked for the whole graph             |
| Pants  | Outputs are captured from a sandbox, and a conflict appears only when digests are merged (`src/rust/fs/src/directory.rs:1036-1048`)                                                                                                                               | What the absence of claims looks like                  |

Not confirmed in source: whether Buck2 keeps a local cache key apart from the
action digest, and whether its output claims are checked across targets.

## 11. Delivery plan

Each milestone leaves `dub test :build-primitives` and `ci`'s build green. A
milestone's gate names the tests that must exist and pass.

| Milestone | Delivers                                                                                                                                                                                                                                                                   | Deletes                                                                                                                                                                                                                                   | Gate                                                                                                                                                                                                                                                         |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| W0        | The prototype: `judge` and `selects`; `readWorkspaceRecipes`; input sets keyed by package and configuration, requests from resolutions (D47), `eachClaimant`, `affectedBy` over requests, the workspace inputs with the working-directory names (D49), `startRoots`        | `packageInputSets`' role rule and `dependencyClosure`                                                                                                                                                                                     | The `input_sets` tests, including one over this repository's resolutions: an edit to `libs/ui/src` affects `text-lab`'s request, one to `libs/dql/src` affects `ui`'s test root and none of `ui`'s dependents                                                |
| W1        | `Workspace` and `readWorkspace` over the VFS, with its read set (BGW1). `discoverPackages`, `ci`'s package lists and `dub_recipe`'s sub-package lookup take it. The evaluator iterates its reachable nodes; an expression digest (§3.4)                                    | `apps/ci/src/dub_deps.d`'s `parseSubPackages`; `discoverPackages`' own reading                                                                                                                                                            | Discovery over a tree literal with no `std.file`; a query benchmark whose cost does not grow with the arena                                                                                                                                                  |
| W2        | Selection by claims (BGW6, BGW12): `selectPackages` seeds claimants; removed paths need no probe and no base ownership map; workspace inputs derived from the read set. The hidden-edge lint as reaches (BGW7). One `owner` (BGW2)                                         | `Invalidator` and `invalidatorFor`; every entry of `apps/ci/src/repository_invalidators.d` but the toolchain's definition, which becomes a declared fileset; `existsInWorktree`; `ownerOf` in `hidden_edges.d`; `ownedBy` in `coverage.d` | The `select` tests, with the three reaches of this repository as fixtures; oracle 13 unchanged; the task-DAG specification's ownership requirement amended (§13)                                                                                             |
| W3        | Symbolic resolution and materialization (BGW8): settings hold filesets; lists come from one resolution per distinct root set, shared across requests. The resolver reads through the VFS. This is the "file access through the VFS" item of the build-graph plan's E2      | `ResolveDriver`, `SystemDriver`, `MemoryDriver`, `collectFiles`; the `Project` and `Package` classes' recipe reading                                                                                                                      | Oracle 1 over the 621 requests with zero new disagreements; a test that adds a file and sees the list change without resolving again; no `std.file` under `resolve/`                                                                                         |
| W4        | Input states and ids (BGW9), the single digest cache, the gate (BGW10) and link claims (BGW11). The machine reports every directory it lists                                                                                                                               | The separate statement of BGK5's cache                                                                                                                                                                                                    | The fileset cache oracle extended to input states; a test in which an edit to a link's target selects the linking package                                                                                                                                    |
| W5        | File claims in the task model (BGW16–BGW19): `FileClaims`, conflict validation, `TaskFresh` and `TaskStale`, claims in dry runs and reporters                                                                                                                              | `rewriteClaim` and the `workspace-write:` convention                                                                                                                                                                                      | Executor tests: overlapping tree and file writes serialize; an unordered read of a write is rejected; a fresh node emits `TaskFresh` and starts no process                                                                                                   |
| W6        | Watching (BGW13–BGW15): a tree watcher in `sparkles:event-horizon` on Linux (inotify), macOS (FSEvents) and Windows (`ReadDirectoryChangesW`), D50, that maps watches to paths, batches events and reports loss; `ci build --watch` and `ci test --watch` as loops of runs | Nothing                                                                                                                                                                                                                                   | A test over a scratch tree for each row of BGW15's table; a forced overflow yields a lossy set and a full materialization; the trace of §6 reproduced, counting `stat` and read calls through a counting VFS; each watcher's tests run on its own host in CI |

W1 and W2 need nothing that is not delivered. W3 is the largest and carries
the dub-agreement risk. W5 does not depend on W3 or W4 and can be taken
earlier if `ci`'s rewriting tasks need it. W6 depends on W4.

## 12. Evidence

The prototype is evidence for the seam, on one host, in an unoptimized build.
It is not acceptance of any requirement.

| Requirement | Status                                                                                                                           | Evidence                                                                                                                                                                                                                                                                |
| ----------- | -------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| BGW1        | partial: the recipes are read once into one value; not through the VFS, and with no read set                                     | `readWorkspaceRecipes` in `libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d`                                                                                                                                                               |
| BGW2        | planned                                                                                                                          | —                                                                                                                                                                                                                                                                       |
| BGW3, BGW4  | partial: one set per package and configuration, with path-carrying flags and commands reported as opaque; no dub oracle yet      | `inputSets` in `libs/build-primitives/src/sparkles/build_primitives/workspace/input_sets.d` and its tests, which find exactly this repository's opaque entries: the shader generators of `ui`, `ui-vulkan` and `vulkan-wsi`, and the Tracy prefix of `profiling` (§3.1) |
| BGW5        | planned                                                                                                                          | —                                                                                                                                                                                                                                                                       |
| BGW6        | partial: no link targets (BGW11)                                                                                                 | `eachClaimant` in `libs/build-primitives/src/sparkles/build_primitives/workspace/input_sets.d`; `judge` and `selects` in `libs/build-primitives/src/sparkles/build_primitives/fileset/value.d`                                                                          |
| BGW7–BGW11  | planned                                                                                                                          | —                                                                                                                                                                                                                                                                       |
| BGW12       | partial: requests come from resolutions and the workspace inputs are modelled; `ci` does not yet build its list of requests (W2) | `requestOf` and `affectedBy` in `libs/build-primitives/src/sparkles/build_primitives/workspace/input_sets.d`, over fixtures, a resolution of a tree literal, and three resolutions of this repository                                                                   |
| BGW13–BGW19 | planned                                                                                                                          | —                                                                                                                                                                                                                                                                       |

The oracles the delivered requirements need:

- **BGW3 and BGW8:** dub, through the existing agreement oracle, on the
  materialized lists of every request in scope.
- **BGW6 and BGW12:** a model that enumerates a tree literal and tests each
  file against each package's patterns one at a time, compared with the
  indexed query.
- **BGW10:** an exhaustive small model: for each single-file edit of a
  fixture tree, the gate reports "unchanged" only when no manifest entry of
  any action changed.
- **BGW14 and BGW15:** a VFS that counts operations, and a scripted event
  source, so that a test states the calls each change is allowed to cost.
- **BGW17:** every pair of claims in a table of fixtures, checked against an
  enumeration of a tree literal: no pair declared conflict-free shares a
  path.

### Review record

One independent review was made of the draft and the prototype, by a reader
given the code and the specifications and no summary of the design. It
checked every `file:line` of §3 and §7 against revision `5ec7c3ae3`,
attacked §§4–7, and made a cold read of the opening.

- **Fixed in the document:** four wrong line ranges; the gate, which was
  unsound for links, for candidates outside the set and for mutable roots
  outside the worktree (BGW9, BGW10); directives, flags and commands the
  input-set table missed (BGW3, BGW4); registry sources that can be written
  (BGW5); the empty-selection error, the toolchain's invalidators and git's
  blindness to ignored files (BGW12, BGW13); directory events, roots that do
  not exist and path-based watches (BGW14); version pruning in the trace
  (BGW15); what a verdict proves (BGW17); what a sandbox grants (BGW19); the
  difference between BGK5 and the subtree cache's rule (BGW9).
- **Fixed in the prototype:** C source directories, globs in `sourceFiles`,
  a package without a recipe, two path-parsing errors.
- **Deferred:** the compiler's working-directory lookup, since decided by
  the owner (D49).
- **Cold read:** the reader restated the problem, approach, scope and
  non-goals correctly, and had to guess "capability VFS", which the
  introduction links.

The repairs were made after the review and are not covered by it.

## 13. Amendments to other specifications

Accepting this design changes these requirements. Each is an amendment to
make in the owning document, not a second statement here, and each is made
by the milestone that delivers the behaviour it states, so that no
specification describes what the code does not yet do.

| Document                                   | Requirement                                             | Change                                                                                                                                                                | Made in                 |
| ------------------------------------------ | ------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
| [Task DAG](../task-dag/SPEC.md)            | TDS6, change ownership by longest directory prefix      | A changed path seeds the requests whose closures claim it (BGW12). Ownership stays for attribution                                                                    | W2                      |
| [Task DAG](../task-dag/SPEC.md)            | TDS2, the configuration whose dependencies are read     | The configurations a request's resolution chose (D47), which also settles optional dependencies as D46 does; a query with no request asks over the command's requests | W2                      |
| [Task DAG](../task-dag/SPEC.md)            | TDM7, exclusive keys as path claims                     | File claims (BGW16, BGW17), with an unordered read of a write rejected (T15); keys stay for resources that are not files                                              | W5                      |
| [`ci` task DAG](../../ci/task-dag/SPEC.md) | CIC5, the invalidator list checked against the read set | The file entries are the read set; the policy entry is the planning command's own closure; the toolchain's definition stays declared (BGW12)                          | W2                      |
| [Build graph](./SPEC.md)                   | BGR8, the hidden-edge lint                              | A reach whose owner is not a dependency (BGW7)                                                                                                                        | W2                      |
| [Build graph](./SPEC.md)                   | BGK2, the manifest's digest                             | BLAKE3 (D48)                                                                                                                                                          | W4                      |
| [Build graph](./SPEC.md)                   | BGK5 and BGF6                                           | One statement with the subtree cache's (BGW9), keeping the clock probe and the future-time rule                                                                       | W4                      |
| [Build graph](./SPEC.md)                   | BGK6, BGK8, BGN2                                        | Restate over the declared read set (BGW7, BGW10)                                                                                                                      | W4                      |
| [Build graph decisions](./decisions.md)    | D24's revisit condition                                 | Met by BGW11                                                                                                                                                          | W4                      |
| [Filesets](../filesets/SPEC.md)            | The stream sink                                         | The machine reports every directory it lists, before listing it: `FSS9`, stated and planned (A26). Watching itself stays out of scope                                 | stated; delivered in W4 |

## 14. Decisions

The design left eight questions to the owner, who answered them on
2026-11-12. Each answer is recorded where it binds, and changes the design
as stated here.

1. **The leaf of the shared cache is BLAKE3**
   ([D48](./decisions.md#d48-one-leaf-digest-blake3-accepted)). A file is
   hashed once; each consumer encodes its own tree over the leaf, and
   SHA-256 is computed only at export (BGW9). W4 moves BGK2.
2. **An input set follows the resolver's configurations**
   ([D47](./decisions.md#d47-an-input-set-follows-the-resolver-s-configurations-accepted)).
   Input sets are keyed by package and configuration, and a request's closure
   is what its resolution chose; a query with no request asks over the
   requests the command makes (BGW12). The workspace's rule and the union
   over every configuration were rejected.
3. **Untracked files are inputs**
   ([D51](./decisions.md#d51-untracked-files-are-inputs-accepted)). An input
   set is resolved from the disk, through the ignore rules; a fileset leaf
   for git's index waits until a check needs it.
4. **A test's run-time inputs stay undeclared for now**
   ([D52](./decisions.md#d52-a-test-s-run-time-inputs-stay-undeclared-for-now-accepted)).
   A test node reads its package's and its closure's input sets, and its
   verdict is not reused outside the Nix sandbox.
5. **Watching covers Linux, macOS and Windows**
   ([D50](./decisions.md#d50-watching-on-linux-macos-and-windows-accepted)),
   with inotify, FSEvents and `ReadDirectoryChangesW` (W6). The periodic
   lossy rescan stays as the fallback for anything else.
6. **An unordered read of a write rejects the graph**
   ([T15](../task-dag/decisions.md#t15-an-unordered-read-of-a-write-rejects-the-graph)),
   as BGW17 states; no edge is inferred.
7. **The fileset machine reports the directories it lists**
   ([A26](../filesets/decisions.md#a26-the-machine-reports-every-directory-it-lists)),
   as `FSS9`; watching stays out of the fileset specification's scope.
8. **The names the compiler's working-directory lookup could find are a
   workspace input**
   ([D49](./decisions.md#d49-the-names-at-the-worktree-root-are-a-workspace-input-accepted)),
   so a new top-level `sparkles/` affects every request and `--since` stays
   sound without a change to the compiler (BGW7, BGW12).
