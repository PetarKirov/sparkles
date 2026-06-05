# CMake (C/C++/native)

A cross-platform _meta-build_ system: CMake reads `CMakeLists.txt` files written in the CMake language and **generates** native build files (Ninja, Make, Visual Studio, Xcode) — it has no first-class "workspace" concept, so multi-package C/C++ trees are assembled from `add_subdirectory`, `FetchContent`, `ExternalProject`, and `CMakePresets.json` rather than a declared member set.

| Field           | Value                                                                                                                                                                                                                                  |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | C++ (the tool); the CMake scripting language (for `CMakeLists.txt`)                                                                                                                                                                    |
| License         | BSD-3-Clause (OSI-approved)                                                                                                                                                                                                            |
| Repository      | [Kitware/CMake][repo] · upstream [gitlab.kitware.com/cmake/cmake][gitlab]                                                                                                                                                              |
| Documentation   | [cmake.org/cmake/help/latest][docs] · [Using Dependencies Guide][deps-guide]                                                                                                                                                           |
| Category        | Native Build System                                                                                                                                                                                                                    |
| Workspace model | **None native.** Single directory tree rooted at one `CMakeLists.txt`; multi-package via `add_subdirectory` aggregation, `FetchContent`/`ExternalProject` for external trees, and `CMakePresets.json` for build/test/workflow profiles |
| First released  | 2000 (Kitware, for the Visible Human / Insight Toolkit projects)                                                                                                                                                                       |
| Latest release  | `4.3.3`                                                                                                                                                                                                                                |

> **Latest release:** `4.3.3` (released May 21, 2026; the `4.3.x` series shipped first-class [Common Package Specification (CPS)][cps-kitware] import/export, build profiling, and schema **version 11** for `CMakePresets.json`). CMake dropped the `2.x`/`3.x` numbering to `4.0` in early 2025; the `cmake-presets(7)` schema and the `cmake --workflow` driver are the closest thing CMake has to a workspace-orchestration surface. See [CLI / UX ergonomics](#cli-ux-ergonomics).

---

## Overview

### What it solves

CMake's job is **build-system generation, not build execution**. You describe _targets_ (`add_library`, `add_executable`), their _sources_, their _usage requirements_ (include dirs, compile definitions, link libraries — propagated via `PUBLIC`/`PRIVATE`/`INTERFACE` on `target_*` commands), and CMake emits a native build for whichever _generator_ you pick (`Ninja`, `Unix Makefiles`, `Visual Studio 17 2022`, `Xcode`). The actual compile/link is then run by that backend — Ninja, Make, MSBuild — not by CMake itself. This two-phase split (**configure** → generate, then **build**) is the defining fact about CMake and the reason its "workspace story" looks unlike a package manager's: there is no resolver, no lockfile, and no manifest array of members.

A C/C++ "monorepo" under CMake is therefore not a _declared_ workspace but an _assembled_ one. A single root `CMakeLists.txt` calls `project()` once and then **pulls every sub-component into one configure/build graph** with `add_subdirectory()`. Every target across every subdirectory lands in **one** target dependency graph, one build tree, and one `compile_commands.json`. Where Cargo (see [../cargo/](../cargo/)) has `[workspace] members = […]` and a virtual root, CMake has a procedural script that `add_subdirectory`s its way down a tree. The unit of cross-package reference is a **target name** (`target_link_libraries(app PRIVATE mylib)`), resolved by CMake's in-process namespace, not a version range.

### Design philosophy

CMake is a _generator_ first and an aggregator second. Its dependency story is built around making external content **part of the same configure step** rather than orchestrating sub-builds. From the actual `FetchContent` module ([`Modules/FetchContent.cmake`][fc-module], `.rst` header):

> _"This module enables populating content at configure time via any method supported by the `ExternalProject` module. Whereas `ExternalProject_Add` downloads at build time, the `FetchContent` module makes content available immediately, allowing the configure step to use the content in commands like `add_subdirectory`, `include` or `file` operations. … Content population details should be defined separately from the command that performs the actual population. This separation ensures that all the dependency details are defined before anything might try to use them to populate content. This is particularly important in more complex project hierarchies where dependencies may be shared between multiple projects."_

Three consequences flow from this, and they define CMake's place in this survey:

1. **One configure, one graph.** `add_subdirectory()` and `FetchContent_MakeAvailable()` both _splice another project's targets into the current build_. There is no isolation boundary: a `FetchContent`ed dependency's targets are visible to, and link directly against, the consuming targets — a deliberate contrast with the isolated symlink trees of [pnpm](../pnpm/) or the content-addressed sandboxes of [Bazel](../bazel/).
2. **"First to declare, wins."** Because everything is one namespace, shared transitive dependencies are de-duplicated by _declaration order_, not by a version solver: _"The first details to be declared for a given dependency take precedence, regardless of where in the project hierarchy that occurs"_ ([`FetchContent`][fc-docs]). This is CMake's substitute for dependency hoisting.
3. **Profiles, not members.** What CMake added to standardize multi-configuration developer workflows is **`CMakePresets.json`** — named `configurePresets`/`buildPresets`/`testPresets`/`packagePresets`/`workflowPresets` — and the `cmake --workflow` driver to chain them. This is a UX layer over the single project, not a declaration of multiple sibling packages.

CMake sits in the "Native Build System" family alongside [Meson][meson-slug-note], SCons, Waf, and the generator it most often drives, Ninja. Among _polyglot_ engines it is the closest mainstream analogue to [GN](../gn/) (also a Ninja-generating meta-build, with a stricter, non-Turing-complete language). For the D-language framing of why a generator-style model maps poorly onto a package manager like `dub`, see [d-landscape][d-landscape].

---

## How it works

### Targets, usage requirements, and the configure→build split

A minimal library + executable in one tree:

```cmake
# libs/mylib/CMakeLists.txt
add_library(mylib STATIC src/mylib.c)
target_include_directories(mylib PUBLIC include)   # propagated to consumers
target_compile_features(mylib PUBLIC c_std_11)
```

```cmake
# apps/app/CMakeLists.txt
add_executable(app src/main.c)
target_link_libraries(app PRIVATE mylib)           # cross-package ref = a target name
```

The `PUBLIC`/`PRIVATE`/`INTERFACE` keywords on `target_link_libraries` and `target_include_directories` are CMake's **usage-requirement** system: `PUBLIC` requirements propagate to anything that links the target; `PRIVATE` stay local; `INTERFACE` apply only to consumers. This is how a library's include paths and compile flags flow to dependents _without_ a manifest — it is encoded in the target graph itself.

Invoking CMake is two phases:

```bash
cmake -S . -B build -G Ninja          # CONFIGURE: run the CMakeLists, generate build.ninja
cmake --build build --parallel        # BUILD: hand off to Ninja, which runs the compiles
ctest --test-dir build -j8            # TEST: run the registered tests
```

The configure step writes a `CMakeCache.txt` (the persisted cache of `option()`/`-D` variables) and a `compile_commands.json` (if `CMAKE_EXPORT_COMPILE_COMMANDS=ON`) covering **every** target in the tree.

### `add_subdirectory`: the monorepo aggregator

The canonical "monorepo" idiom is a root `CMakeLists.txt` that conditionally `add_subdirectory`s each component. This real example is [`clay/CMakeLists.txt`][clay-cmake] from the [Clay] layout library, which aggregates a library plus ~15 example sub-projects:

```cmake
# clay/CMakeLists.txt (abridged, verbatim)
cmake_minimum_required(VERSION 3.27)
project(clay)

option(CLAY_INCLUDE_ALL_EXAMPLES "Build all examples" ON)
option(CLAY_INCLUDE_RAYLIB_EXAMPLES "Build raylib examples" OFF)

if(CLAY_INCLUDE_ALL_EXAMPLES OR CLAY_INCLUDE_CPP_EXAMPLE)
  add_subdirectory("examples/cpp-project-example")
endif()
if(CLAY_INCLUDE_ALL_EXAMPLES OR CLAY_INCLUDE_RAYLIB_EXAMPLES)
  add_subdirectory("examples/raylib-multi-context")
  add_subdirectory("examples/raylib-transitions")
endif()
```

Each `add_subdirectory` pulls that directory's `CMakeLists.txt` into the **same** configure run, so its targets (`clay_examples_raylib_transitions`, …) join the one global target graph. The `option()` gates are CMake's hand-rolled equivalent of a `--filter`: members are included/excluded by cache variables, evaluated at configure time, not by a workspace member list.

### `FetchContent`: external trees spliced into the build

For dependencies that live outside the tree, `FetchContent` downloads them **at configure time** and (optionally) `add_subdirectory`s them into the same build. Real example, [`clay/examples/raylib-transitions/CMakeLists.txt`][clay-raylib]:

```cmake
# clay/examples/raylib-transitions/CMakeLists.txt (verbatim)
include(FetchContent)
FetchContent_Declare(
    raylib
    GIT_REPOSITORY "https://github.com/raysan5/raylib.git"
    GIT_TAG "5.5"
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(raylib)              # clones + add_subdirectory(raylib)

add_executable(clay_examples_raylib_transitions main.c)
target_link_libraries(clay_examples_raylib_transitions PUBLIC raylib)   # links raylib's target
```

`FetchContent_MakeAvailable(raylib)` _"will also add them to the main build, if possible, so that the main build can use the populated projects' targets"_ ([`FetchContent`][fc-docs]). After it returns, `raylib` is an ordinary target you can `target_link_libraries` against — no separate install, no version resolution, just a target in the same graph. Compare `ExternalProject`, which keeps the dependency as a **build-time sub-build** behind an opaque install prefix (used for cross-toolchain or non-CMake deps).

### `CMakePresets.json`: named profiles + `cmake --workflow`

`CMakePresets.json` (schema version 11 as of CMake `4.3`) standardizes the configure/build/test invocations a project supports. It has five preset arrays — `configurePresets`, `buildPresets`, `testPresets`, `packagePresets`, `workflowPresets` — and supports `inherits` (within a file/its includes) and `include` (other preset files). A `CMakeUserPresets.json` _implicitly includes_ `CMakePresets.json` for personal overrides. Excerpt adapted from [`llvm/CMakePresets.json`][llvm-presets]:

```json
{
  "version": 11,
  "configurePresets": [
    {
      "name": "llvm-export-compile-commands",
      "hidden": true,
      "cacheVariables": { "CMAKE_EXPORT_COMPILE_COMMANDS": true }
    },
    {
      "name": "release",
      "inherits": ["llvm-export-compile-commands"],
      "generator": "Ninja",
      "binaryDir": "${sourceDir}/build/release",
      "cacheVariables": { "CMAKE_BUILD_TYPE": "Release" }
    }
  ],
  "buildPresets": [{ "name": "release", "configurePreset": "release" }],
  "testPresets": [{ "name": "release", "configurePreset": "release" }],
  "workflowPresets": [
    {
      "name": "release",
      "steps": [
        { "type": "configure", "name": "release" },
        { "type": "build", "name": "release" },
        { "type": "test", "name": "release" }
      ]
    }
  ]
}
```

```bash
cmake --workflow --preset release      # runs configure → build → test in one driver call
```

`cmake --workflow --preset <name>` is the **closest CMake comes to a task pipeline**: it sequences the configure/build/test steps of a single project. It is not a topological multi-package scheduler — there is no notion of "build member A before member B" beyond the implicit ordering inside the one target graph.

---

## Workspace declaration and topology

**CMake has no workspace declaration.** There is no `members` array, no glob of sub-packages, no virtual root, and no separate "workspace manifest" distinct from a package manifest. The discovery model is **procedural and single-rooted**:

- **One `project()` per configure.** The root `CMakeLists.txt` calls `project(name)` exactly once (sub-projects _may_ call `project()` again, mostly for `ExternalProject`-style independence, but the dominant idiom is a single top-level `project()`). The "workspace" is whatever that one script reaches via `add_subdirectory()`.
- **Aggregation, not enumeration.** Sub-packages are discovered by **executing `add_subdirectory()` calls** — frequently guarded by `option()` flags (as in [`clay/CMakeLists.txt`][clay-cmake]) or computed with `file(GLOB …)`/`foreach()`. There is no declarative member set the tool reads ahead of time; the topology is whatever the script builds at configure time.
- **No multi-root standard.** CMake natively assumes a single source tree. Multi-root support (multiple independent top-level `CMakeLists.txt`) lives in **IDE tooling**, not core CMake: Visual Studio uses a `CMakeWorkspaceSettings.json` and VS Code's CMake Tools extension adds _"CMake: Configure All Projects"_ / _"Build All Projects"_ commands — both external to the `cmake` CLI. The `cmake-presets(7)` schema has **no `workspacePresets`**.

> [!IMPORTANT]
> The takeaway for `dub`: CMake demonstrates the _aggregation_ model (one root that pulls members into one graph) without any of the _declarative_ machinery — no member globs, no virtual workspace, no exclusion list. Everything a workspace would declare statically, CMake computes procedurally at configure time. This is maximally flexible and minimally introspectable: you cannot ask CMake "what are the members?" without running the configure step.

## Dependency handling and isolation

CMake's model is **maximal sharing, zero isolation** — the opposite end of the spectrum from [pnpm](../pnpm/)'s isolated symlink store or [Bazel](../bazel/)'s sandboxes.

- **Internal cross-references are target names.** Member A depends on member B by writing `target_link_libraries(A PRIVATE B)` — where `B` is a target already defined elsewhere in the same configure run. No path, no version, no manifest: just an identifier resolved in CMake's global target namespace. Namespaced aliases (`add_library(Foo::bar ALIAS bar)`) and `EXPORT` sets make this robust across `find_package` boundaries.
- **External dependencies, three tiers.**
  - `find_package(Foo)` — locate an _already-installed_ package via its `FooConfig.cmake` (or, since CMake `4.3`, a [Common Package Specification][cps-kitware] `.cps` JSON file). System-level, no fetching.
  - `FetchContent` — clone/download **at configure time** and splice into the same build (one graph; targets directly linkable). This is the de-facto "vendored-source dependency" mechanism.
  - `ExternalProject` — clone/build **at build time** as an isolated sub-build behind an install prefix; the only tier that offers real isolation (separate toolchain, separate build tree), at the cost of an opaque boundary.
- **No hoisting, no lockfile — "first to declare, wins."** With `FetchContent`, a diamond where two members both want `zlib` is resolved by _declaration order_: the first `FetchContent_Declare(zlib …)` reached wins, and later declarations are ignored. There is no SAT/PubGrub solver and no `dub.selections.json`-style lock; reproducibility relies on pinned `GIT_TAG`/`URL_HASH` values in each `FetchContent_Declare`.
- **Dependency providers** (`cmake_language(SET_DEPENDENCY_PROVIDER …)`) let a _user_ (e.g. [vcpkg], Conan) intercept every `find_package`/`FetchContent_MakeAvailable` and substitute a managed package — the official seam through which external package managers integrate. `OVERRIDE_FIND_PACKAGE` makes a `FetchContent`ed dependency satisfy later `find_package(Foo)` calls. These are the closest CMake gets to a unified resolution policy, and they are opt-in glue, not a built-in resolver.

> [!NOTE]
> Because `FetchContent` _adds the dependency's targets to the main build_, a CMake "monorepo" and its `FetchContent`ed externals share **one** build tree and **one** set of compile flags. This eliminates the redundant-compilation problem `dub` has with `path=` cross-refs — but only because CMake refuses to isolate anything. It is hoisting taken to its logical extreme: a single flat target namespace.

## Task orchestration and scheduling

CMake's orchestration is **delegated to the generated backend**, and its "DAG" is a _target_ DAG, not a _task_ DAG.

- **The build DAG is the target graph.** Every `add_executable`/`add_library` and the `target_link_libraries` edges between them form a dependency graph. CMake topologically encodes this into the generated `build.ninja` (or Makefiles), and **Ninja/Make does the scheduling** — including all parallelism. CMake itself never compiles anything.
- **Concurrency is the backend's.** `cmake --build build --parallel [N]` (or `-j N`) forwards a job count to Ninja/Make, which run independent compile/link legs concurrently. Ninja's scheduler, not CMake, decides ordering and parallelism; CMake's contribution is the correctly-ordered graph.
- **Change detection is the backend's, and it is timestamp-based.** Ninja and Make rebuild based on **file modification times and a recorded command line** (Ninja additionally hashes the command in its `.ninja_log`). This is _not_ content-addressed input hashing of the kind [Turborepo](../turborepo/), [Nx](../nx/), or [Bazel](../bazel/) use; there is no per-target cache key, no "affected-since-git-ref" computation, and no remote cache in core CMake. Touching a header re-triggers everything that includes it (tracked via compiler-emitted depfiles), but moving the tree or changing an unrelated env var can over- or under-rebuild.
- **No affected-detection.** CMake has no `--since <git-ref>` and no concept of "members impacted by this change." The granularity of incrementality is whatever the backend's mtime tracking provides over the single, flat target graph. `ctest` can _filter_ tests (`-R`, `-E`, `-L`) but does not compute a change-impacted subset.
- **`cmake --workflow` is sequencing, not a scheduler.** It runs the ordered steps of one workflow preset (configure → build → test → package). There is no cross-package topological loop à la [`yarn workspaces foreach`](../yarn-berry/) — the only ordering CMake knows is inside the one target graph.

> [!WARNING]
> CMake's reliance on the backend for change detection means it has **no build/test caching of its own** and **no remote execution**. The incrementality story is entirely "Ninja/Make + mtimes." For content-hashed or remote-cached native builds, teams reach for [Bazel](../bazel/)/[Buck2](../buck2/) or bolt `ccache`/`sccache` underneath the compiler — not anything CMake provides.

## Caching and remote execution

- **No native build/test cache.** Core CMake has no content-addressed action cache, no `--cache` flag, and no per-target cache keys. Incremental rebuilds come solely from the generated backend's timestamp tracking (Ninja `.ninja_log`, Make rules). Re-configuring from scratch into a fresh `binaryDir` rebuilds everything.
- **No remote execution / no REAPI.** CMake implements **none** of the Remote Execution API (REAPI). It cannot dispatch compiles to a build farm or fetch action results from a shared cache. This is the single starkest gap versus the polyglot engines in this survey ([Bazel](../bazel/), [Buck2](../buck2/), [Pants](../pants/)) and the JS orchestrators ([Turborepo](../turborepo/), [Nx](../nx/)).
- **Caching is bolted on underneath.** The community pattern is `RULE_LAUNCH_COMPILE`/`CMAKE_<LANG>_COMPILER_LAUNCHER=ccache` (or `sccache`), which inserts a **compiler cache** _below_ CMake. With `sccache` configured against an S3/Redis backend you get a _shared compile cache_, and `sccache --dist` adds _distributed compilation_ — but this is the launcher's machinery, entirely transparent to CMake, which neither knows nor coordinates it.
- **CTest dashboards are reporting, not caching.** CTest can submit build/test results to a CDash dashboard (`ctest -D Experimental`), and CMake `4.3` added build profiling. These are observability features; they do not cache or skip work.

> [!NOTE]
> Net: CMake is a _graph generator_ with **no caching layer of its own**. Where this survey's cache-centric tools key tasks by hashed inputs and share results remotely, CMake leaves all of that to (a) the backend's mtime incrementality and (b) an optional compiler-launcher cache. A `dub` workspace feature that wants content-hashed task caching cannot borrow it from CMake — only the negative lesson that delegating caching entirely to the backend forecloses cross-machine reuse.

## CLI / UX ergonomics

The command boundary is **mode-flag-driven on the `cmake`/`ctest` binaries**, with `--preset` as the named-profile selector and `--target` for targeted builds:

| Goal                 | Invocation                                                 | Notes                                                           |
| -------------------- | ---------------------------------------------------------- | --------------------------------------------------------------- |
| Configure (generate) | `cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release`  | `-S` source, `-B` build dir, `-G` generator, `-D` cache vars    |
| Configure via preset | `cmake --preset release`                                   | Pulls generator/`binaryDir`/cache vars from `CMakePresets.json` |
| Build everything     | `cmake --build build --parallel 8`                         | Forwards `-j8` to Ninja/Make                                    |
| Build **one** target | `cmake --build build --target mylib` (`-t mylib`)          | The "targeted" filter — by target name                          |
| Build via preset     | `cmake --build --preset release`                           | Build settings from `buildPresets`                              |
| Run the workflow     | `cmake --workflow --preset release`                        | Sequences configure → build → test → package                    |
| List presets         | `cmake --list-presets` · `cmake --workflow --list-presets` | Discoverability of named profiles                               |
| Test                 | `ctest --test-dir build -j8 --preset release`              | `--test-dir` avoids `cd`ing into the build dir (CMake `4.3`+)   |
| Filter tests         | `ctest -R '^unit_' -E slow -L integration`                 | Regex include `-R`, exclude `-E`, label `-L`                    |
| Install              | `cmake --install build --prefix /opt/app`                  | Runs the generated install rules                                |

Observations against this survey's filter-ergonomics axis:

- **The "filter" is the target name.** `cmake --build build --target mylib` is CMake's `-p`/`--filter`; there is no member-scoped flag because there are no members — only targets in the one graph. Building "just the backend" means knowing and naming the backend's target(s).
- **`--preset` is the closest thing to a workspace selector**, but it selects a _configuration profile_ of the single project, not a sub-package. `inherits`/`include` give it composition; `CMakeUserPresets.json` gives per-developer overrides. It is excellent UX for "here are the supported build configurations" and poor UX for "operate on member X."
- **No `--since`, no recursion flags.** Nothing in the CMake/CTest CLI computes a git-diff-impacted set or walks a member sub-graph (`--from`/`--recursive` in Yarn terms). The only graph traversal is the implicit target-dependency ordering the backend performs.
- **Generator choice is a first-class flag.** `-G Ninja` vs `-G "Unix Makefiles"` vs `-G "Visual Studio 17 2022"` — the meta-build identity. Multi-config generators add `--config Release` at build time; single-config generators bake `CMAKE_BUILD_TYPE` at configure time.

---

## Strengths

- **Ubiquitous and portable.** The de-facto standard for C/C++; generates for Ninja, Make, Visual Studio, and Xcode from one `CMakeLists.txt`, across Linux/macOS/Windows.
- **One graph, one `compile_commands.json`.** Aggregating an entire tree with `add_subdirectory` yields a single target graph, single build tree, and single compile-commands database — clangd/IDE tooling "just works" across the whole monorepo.
- **`FetchContent` makes source dependencies trivial.** Pinned `GIT_TAG` + `FetchContent_MakeAvailable` vendors a dependency's _targets_ directly into your build, no install step, no separate version solve.
- **Usage requirements propagate correctly.** `PUBLIC`/`PRIVATE`/`INTERFACE` on `target_*` commands give transitive include/flag/link propagation without a manifest — modern "target-based" CMake is genuinely composable.
- **`CMakePresets.json` standardizes invocations.** Named, inheritable, shareable build/test/workflow profiles, with `--list-presets` for discoverability and `cmake --workflow` to chain them.
- **First-class package-manager seams.** Dependency providers (`SET_DEPENDENCY_PROVIDER`), `OVERRIDE_FIND_PACKAGE`, and CPS (`4.3`) let vcpkg/Conan/CPS integrate cleanly.

## Weaknesses

- **No workspace concept whatsoever.** No member declaration, no virtual root, no glob, no exclusion list, no multi-root in the core CLI; topology is procedurally computed at configure time and not introspectable.
- **No caching of its own.** No content-addressed action cache, no per-target cache keys; incrementality is entirely the backend's mtime tracking, and a fresh build dir rebuilds everything.
- **No remote execution / no REAPI.** Cannot dispatch to or fetch from a build farm; distributed/shared caching requires an external compiler launcher (`sccache`/`ccache`).
- **No affected-detection.** No `--since <ref>`, no impacted-member computation; the only "filter" is naming targets.
- **Resolution is "first-declared-wins."** `FetchContent` diamonds are resolved by declaration order, not a version solver; reproducibility hinges on hand-pinned tags/hashes with no lockfile.
- **Turing-complete configure language.** `CMakeLists.txt` is imperative and stateful (cache variables, global properties, directory scoping), making large trees hard to reason about — the very property [GN](../gn/) and [Bazel](../bazel/) reject by using a restricted language.
- **Two-phase mental model.** The configure/build split and "you generate a build, you don't run one" trips up newcomers and complicates any caching/affected story.

## Key design decisions and trade-offs

| Decision                                                            | Rationale                                                                                        | Trade-off                                                                                               |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Meta-build (generate native files) rather than run the build itself | Portability: one description targets Ninja, Make, MSBuild, Xcode across all OSes                 | Caching/scheduling/parallelism are the backend's; CMake owns no cache and no remote execution           |
| No workspace primitive; aggregate via `add_subdirectory`            | Maximal flexibility — any tree shape, computed procedurally; one graph + one compile-commands db | No declarative member set, no virtual root, no introspection; "filter" is just naming a target          |
| `FetchContent` splices deps into the **same** build                 | Source dependencies become ordinary linkable targets; no install/version-solve round-trip        | Zero isolation; shared global target namespace; diamonds resolved by declaration order, not a solver    |
| "First to declare, wins" instead of a version resolver              | Simple, deterministic given pinned tags; no SAT/PubGrub machinery in the build tool              | No lockfile, no conflict detection; reproducibility depends entirely on hand-pinned `GIT_TAG`/hashes    |
| Turing-complete imperative configure language                       | Express arbitrary platform/feature logic (`if`, `foreach`, `option`, `file(GLOB)`)               | Hard to analyze statically; large trees become stateful and order-dependent (cf. [GN](../gn/)'s ban)    |
| Caching delegated to the generator + optional `ccache`/`sccache`    | Keeps CMake a pure graph generator; lets users choose any compiler-cache backend underneath      | No native, no per-target, no remote cache; cross-machine reuse needs external, CMake-opaque tooling     |
| `CMakePresets.json` profiles instead of workspace members           | Standardize/share the _configurations_ a project supports; composable via `inherits`/`include`   | Profiles describe one project's build modes, not sibling packages; `cmake --workflow` ≠ topo scheduler  |
| Dependency providers / CPS as integration seams                     | Let vcpkg/Conan/CPS own resolution without CMake reinventing a package manager                   | Real multi-package resolution lives _outside_ CMake; without them you are back to "first-declared-wins" |

---

## Sources

- [Kitware/CMake — GitHub mirror][repo] · [upstream GitLab][gitlab]
- [CMake documentation (latest, 4.3.3)][docs]
- [`cmake(1)` manual — `--build`, `--workflow`, `--preset`, `--install`][cmake1]
- [`cmake-presets(7)` — `configurePresets`/`buildPresets`/`testPresets`/`packagePresets`/`workflowPresets`, schema v11][presets-manual]
- [`FetchContent` module documentation — "first to declare, wins", `OVERRIDE_FIND_PACKAGE`][fc-docs]
- [`Modules/FetchContent.cmake` — verbatim `.rst` header (configure-time population)][fc-module]
- [Using Dependencies Guide][deps-guide]
- [CMake 4.3 release notes — CPS, build profiling, presets v11][rel-43]
- [Common Package Specification is Out the Gate (Kitware)][cps-kitware]
- [Licensing for CMake (BSD-3-Clause)][license]
- Real-world configs: [`clay/CMakeLists.txt`][clay-cmake] · [`clay/examples/raylib-transitions/CMakeLists.txt`][clay-raylib] · [`llvm/CMakePresets.json`][llvm-presets]
- Sibling deep-dives: [GN][gn-slug] · [Bazel][bazel-slug] · [Buck2][buck2-slug] · [Cargo][cargo-slug] · [pnpm][pnpm-slug] · [Turborepo][turbo-slug] · [Nx][nx-slug] · [Yarn Berry][yarn-slug] · [Pants][pants-slug] · the [umbrella catalog][umbrella] · D-language framing in [d-landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/Kitware/CMake
[gitlab]: https://gitlab.kitware.com/cmake/cmake
[docs]: https://cmake.org/cmake/help/latest/
[cmake1]: https://cmake.org/cmake/help/latest/manual/cmake.1.html
[presets-manual]: https://cmake.org/cmake/help/latest/manual/cmake-presets.7.html
[fc-docs]: https://cmake.org/cmake/help/latest/module/FetchContent.html
[fc-module]: https://gitlab.kitware.com/cmake/cmake/-/blob/master/Modules/FetchContent.cmake
[deps-guide]: https://cmake.org/cmake/help/latest/guide/using-dependencies/index.html
[rel-43]: https://cmake.org/cmake/help/latest/release/4.3.html
[cps-kitware]: https://www.kitware.com/common-package-specification-is-out-the-gate/
[license]: https://cmake.org/licensing/
[clay-cmake]: https://github.com/nicbarker/clay/blob/main/CMakeLists.txt
[clay-raylib]: https://github.com/nicbarker/clay/blob/main/examples/raylib-transitions/CMakeLists.txt
[llvm-presets]: https://github.com/llvm/llvm-project/blob/main/llvm/CMakePresets.json
[Clay]: https://github.com/nicbarker/clay
[vcpkg]: https://github.com/microsoft/vcpkg
[meson-slug-note]: https://mesonbuild.com/
[gn-slug]: ../gn/
[bazel-slug]: ../bazel/
[buck2-slug]: ../buck2/
[cargo-slug]: ../cargo/
[pnpm-slug]: ../pnpm/
[turbo-slug]: ../turborepo/
[nx-slug]: ../nx/
[yarn-slug]: ../yarn-berry/
[pants-slug]: ../pants/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
