# GN + Ninja (Polyglot (C/C++))

A two-layer build architecture from Google: **`GN`** is a meta-build system that
turns a tree of `BUILD.gn` files into one giant declarative dependency graph, and
**`Ninja`** is the deliberately "dumb", maximally-fast executor that runs that
graph — the generate/execute split that powers Chromium, Fuchsia, V8, Dart, and
Flutter Engine.

| Field           | Value                                                                                                                          |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Language        | `C++` (both `GN` and `Ninja` engines); `GN`'s `BUILD.gn` configuration language is a small dynamically-typed imperative DSL    |
| License         | `GN`: BSD 3-Clause ("Copyright 2015 The Chromium Authors"); `Ninja`: Apache-2.0                                                |
| Repository      | [`gn.googlesource.com/gn`][gn-repo] · [`ninja-build/ninja`][ninja-repo]                                                        |
| Documentation   | [`GN` reference][gn-ref] · [`GN` quick start][gn-quickstart] · [`Ninja` manual][ninja-manual]                                  |
| Category        | Polyglot Build Orchestrator                                                                                                    |
| Workspace model | Single source tree rooted at a `.gn` dotfile; the whole tree is one workspace of `BUILD.gn` packages, sliced per **toolchain** |
| First released  | `Ninja` 2012 (Evan Martin, for Chrome); `GN` 2015 (Brett Wilson, replacing `GYP`)                                              |
| Latest release  | `Ninja` `v1.13.x`; `GN` has **no release versions** — only the sequence of commits on `main`                                   |

> **Latest release (as of June 5, 2026):** `Ninja`'s current line is `1.13.x`
> (which added GNU-Make jobserver support). `GN` is unusual: it _"does not guarantee
> the backwards-compatibility of new versions and has no branches or versioning
> scheme beyond the sequence of commits to the main git branch (which is expected to
> be stable)"_ ([`README.md`][gn-repo]) — you pin a commit hash, not a tag.
> Separately, Google is rolling out **`Siso`**, a Go drop-in replacement for the
> _`Ninja`_ executor with native remote execution, across Chromium/WebRTC during
> 2025–2026; **`GN` stays unchanged** as the generator. See
> [Caching & remote execution](#_4-caching-remote-execution).

---

## Overview

### What it solves

`GN` + `Ninja` solve the **giant multi-language, multi-platform C/C++ repository**
problem: a single tree (Chromium is tens of thousands of source files) that must
build for many targets — Linux, Windows, macOS, Android, iOS, Fuchsia, host vs.
device — from one coherent dependency graph, fast, and _correctly_, with header
inclusion validated against the declared graph. This is the same "one repo, one
graph, build exactly what changed" goal as [Bazel][bazel], [Buck2][buck2], and
[Please][please], but reached from the opposite direction: rather than a hermetic
content-addressed engine with its own package manager, `GN` is a **pure code
generator** that emits files for a separate, minimal executor.

The architecture is a strict two-layer split:

1. **`GN`** parses `BUILD.gn` files (an imperative DSL), resolves the target
   dependency graph, applies per-platform configuration, and **writes out
   `build.ninja` files** — it never compiles anything itself.
2. **`Ninja`** reads those generated files and does nothing but schedule and run
   commands as fast as possible, with `mtime`-based incremental rebuilds.

`Ninja`'s own design statement makes the division explicit ([`Ninja` manual][ninja-manual]):

> _"Where other build systems are high-level languages, Ninja aims to be an
> assembler."_

So `GN` is the "compiler" (the policy, the decisions, the human-facing language)
and `Ninja` is the "assembler" (no policy, no decisions, just execute). Within the
polyglot survey, `GN`+`Ninja` is the **"generator + minimal executor"** data point
— contrast the all-in-one hermetic engines [Bazel][bazel]/[Buck2][buck2] and the
sibling generators `Meson` and `CMake`, which _also_ target `Ninja`
as a backend.

### Design philosophy

Two complementary philosophies stack here. `GN`'s, from its landing page
([`gn.googlesource.com/gn`][gn-home]):

> _"It is designed for large projects and large teams. It scales efficiently to
> many thousands of build files and tens of thousands of source files. … It has a
> focus on correctness. GN checks for the correct dependencies, inputs, and outputs
> to the extent possible."_

`GN`'s README adds a striking, deliberately self-limiting goal — it _wants_ to be
under-powered ([`README.md`][gn-repo]):

> _"GN has the goal of being minimally expressive."_

The rationale is team-scale legibility: direct _"members of a large team (who may
not have much knowledge about the build) down an easy-to-understand, well-lit
path."_ `GN` deliberately lacks the Turing-complete extensibility of [Bazel][bazel]
Starlark rules — there is no user-defined rule type; you compose the built-in
`executable`/`static_library`/`source_set`/`action`/`group` targets.

`Ninja`'s philosophy is the mirror image — be _maximally_ minimal so it can be
maximally fast ([`Ninja` manual][ninja-manual]):

> _"Build systems get slow when they need to make decisions. … when convenience and
> speed are in conflict, prefer speed."_

`Ninja`'s explicit **non-goals** are revealing: _"convenient syntax for writing
build files by hand,"_ _"built-in rules,"_ and _"build-time decision-making ability
such as conditionals or search paths."_ All of that is pushed up into the
generator. The result: `Ninja` files _"shouldn't be hand-written"_ — they are an
intermediate representation, the way object files are.

---

## How it works

### The two-layer pipeline

```bash
# 1. GN reads BUILD.gn + the .gn dotfile, resolves the graph, writes Ninja files
gn gen out/Default

# 2. Ninja executes the generated graph (build.ninja under out/Default)
ninja -C out/Default        # or: ninja -C out/Default //chrome:chrome
```

`gn gen out/Default` _"Generates ninja files from the current tree and puts them in
the given output directory"_ ([`GN` reference][gn-ref]). Each output directory
(`out/Default`, `out/Release`, `out/android`) is an independent build with its own
`args.gn` — `GN` _"supports multiple parallel output directories, each with their
own configuration"_ ([`gn.googlesource.com/gn`][gn-home]). A key ergonomic detail:
the generated graph includes a rule to **regenerate itself**, so after editing a
`BUILD.gn` you just re-run `ninja` and it re-invokes `gn gen` automatically — no
manual regeneration step.

### Targets, configs, and labels

A `BUILD.gn` file declares **targets**. The built-in target types are fixed (you
cannot define new ones):

| Target type                 | Role                                                                           |
| --------------------------- | ------------------------------------------------------------------------------ |
| `executable`                | A linked binary                                                                |
| `static_library`            | A `.a`/`.lib` archive                                                          |
| `shared_library`            | A `.so`/`.dll`/`.dylib`                                                        |
| `source_set`                | A virtual archive — object files grouped without an actual `.a` link step      |
| `group`                     | _"a collection of dependencies that's not compiled or linked"_ (a meta-target) |
| `config`                    | A named bundle of `defines`, `include_dirs`, `cflags`, … applied to targets    |
| `action` / `action_foreach` | An arbitrary script invocation (codegen, the universal escape hatch)           |
| `copy`                      | File copy                                                                      |

A minimal `BUILD.gn` ([`GN` quick start][gn-quickstart]):

```python
# //tutorial/BUILD.gn
executable("tutorial") {
  sources = [
    "tutorial.cc",
  ]
  deps = [
    "//base",
  ]
}
```

Targets are addressed by **labels**. `//` is the source root (the directory holding
the `.gn` dotfile):

```python
//tutorial:tutorial        # target 'tutorial' in package //tutorial
//base                     # shorthand for //base:base (target named like its dir)
:other_target              # a target in the SAME BUILD.gn
//foo:bar(//build/toolchain:host)   # 'bar' built in a SPECIFIC toolchain
```

That last form is the crucial one: **a label carries an optional toolchain
suffix**. The full label syntax is `//path/to/dir:name(//path/to/toolchain:label)`.

### Configs and the propagation model

`GN`'s answer to "how do compile flags flow across the graph" is the `config`
target plus three flavors of dependency edge:

```python
config("my_lib_config") {
  defines = [ "ENABLE_DOOM_MELON" ]
  include_dirs = [ "//third_party/doom_melon" ]
}

static_library("hello") {
  sources = [ "hello.cc" ]
  configs += [ ":my_lib_config" ]          # applies to THIS target
  public_configs = [ ":my_lib_config" ]     # ALSO applies to anything depending on it
}
```

- **`deps`** — _"Private linked dependencies"_; only this target links them.
- **`public_deps`** — _"Declare public dependencies"_; **dependents inherit them
  transitively** (the analogue of CMake's `PUBLIC` linkage). This is how a header
  exposed in your public API forces downstream targets to also see its dependency.
- **`data_deps`** — _"Non-linked dependencies"_; built but not linked, for runtime
  data/test fixtures.

(All quoted from the [`GN` reference][gn-ref].) `public_configs` does the same
upward propagation for compile flags. This declarative propagation is what lets
`GN` _"cleanly express many complicated build variants"_ without per-target flag
duplication.

### Build arguments: `declare_args()` and `args.gn`

Build configuration is parameterized with **build args**, declared with defaults in
`.gn`/`.gni` files and overridden per-output-dir in `args.gn`:

```python
# somewhere in the build config
declare_args() {
  enable_teleporter = true
  is_debug = true
  target_cpu = "x64"
}
```

```python
# out/android/args.gn  (edited via `gn args out/android`)
target_os = "android"
target_cpu = "arm64"
is_debug = false
```

`gn args out/android --list` prints every available arg with its default and
docstring. Args are ordinary global variables, so `BUILD.gn` files branch on them
with plain `if (is_debug) { … }` / `if (is_android) { … }`.

### Ninja's execution model

The generated `build.ninja` has just two primitives ([`Ninja` manual][ninja-manual]):

```ninja
rule cc
  command = gcc $cflags -c $in -o $out
  depfile = $out.d
  deps = gcc

build foo.o: cc foo.c        # an edge: output : rule inputs
```

A `rule` is a command template; a `build` statement is one edge of the DAG
(`outputs : rule explicit_inputs | implicit_inputs || order_only_inputs`). `Ninja`
does **`mtime`-based change detection**: an edge re-runs when an input is newer than
an output, _or when the command line itself changed_ — _"Outputs implicitly depend
on the command line that was used to generate them, which means that changing e.g.
compilation flags will cause the outputs to rebuild."_ Two on-disk databases make
restart cheap: **`.ninja_log`** (command hashes per output) and **`.ninja_deps`**
(compacted header-dependency info). Header dependencies are discovered from the
compiler, not enumerated by hand: `deps = gcc` reads `gcc -MD` depfiles, `deps =
msvc` parses `/showIncludes`. The `restat` attribute (which `GN` sets on `action`s)
re-checks output `mtime` after a command, so a regenerated-but-unchanged output
doesn't needlessly cascade rebuilds downstream.

---

## The five dimensions

### 1. Workspace declaration & topology

- **Root marker, not a member list.** A `GN` workspace is rooted at the **`.gn`
  dotfile**: when `gn` starts it searches the current directory and parents for a
  file named `.gn`, and that file marks the source root (the `//` of all labels).
  There is **no `members = [...]` array** (contrast [Cargo][cargo]'s `[workspace]`
  or [pnpm][pnpm]'s globbed `pnpm-workspace.yaml`). The workspace is the _entire
  tree_ under the root, and topology is implicit: every directory with a `BUILD.gn`
  is a package; targets and their `deps` form one global graph.
- **The `.gn` dotfile is the root config.** It names the `buildconfig` script that
  bootstraps every toolchain, optionally a `root` target/dir, `root_patterns` to
  scope which targets get generated, `check_targets`/`no_check_targets` for header
  checking, `exec_script_allowlist` (which `BUILD.gn` files may shell out at parse
  time), `script_executable` (the Python used for `action`s), and `default_args`.
- **Topology is sliced by _toolchain_, not by member.** This is `GN`'s defining
  structural feature and has no analogue in the package-manager tools. _"All the GN
  files are instantiated separately in each toolchain. Each toolchain can set global
  variables differently, so GN code can use tests like `if (is_kernel)` or
  `if (current_toolchain == some_toolchain)` to behave differently in different
  contexts"_ ([Fuchsia: Introduction to GN][fuchsia-intro]). One `gn gen` can build
  the same `//base` for the host compiler, the device ARM64 compiler, and a kernel
  toolchain simultaneously — the **toolchain is a second axis on every label**.
- **Code sharing via `import()`.** Reusable declarations (configs, templates, arg
  declarations) live in `.gni` files pulled in with `import("//build/foo.gni")` —
  _"Import a file into the current scope."_ `template()` defines reusable macros
  that expand to built-in targets (the closest `GN` gets to user-defined rules,
  short of a true rule type).
- **No multi-root / no nested workspaces.** Unlike [go.work][go-work]'s multi-module
  roots, a `GN` build has exactly one `.gn` root. Vendored third-party code lives in
  subdirectories of the same tree with their own `BUILD.gn` files.

### 2. Dependency handling & isolation

- **No package manager, no resolver, no lockfile.** This is the sharpest contrast
  with every language-package-manager in the survey. `GN` has **no concept of
  fetching, versioning, or resolving external dependencies** — there is no
  `dub.selections.json`/`Cargo.lock`/virtual store equivalent. All code that
  participates in the build must already be present in the source tree (Chromium
  vendors its dependencies via `gclient`/`DEPS`, an _entirely separate_ tool that
  runs before `GN`). `GN` only knows about targets that exist on disk under `//`.
- **Cross-references are just labels — no hoisting, no symlinks.** A library in one
  directory is depended on from another purely by its `//path:target` label. There
  is no hoisted `node_modules` ([npm][npm]), no isolated symlink tree
  ([pnpm][pnpm]), no `workspace:`/`path=` protocol ([yarn-berry][yarn-berry]) —
  because there are no _packages_ in the registry sense, only graph nodes. The
  dependency graph _is_ the cross-reference mechanism, and topological build order
  falls out of it automatically.
- **Isolation is by `config`/visibility, not by sandbox.** `GN` does **not**
  sandbox actions the way [Bazel][bazel]/[Buck2][buck2]/[Please][please] do — there
  are no per-action namespaces, and the input hash is not trustworthy against
  undeclared reads. Instead `GN` enforces graph discipline two ways: **`visibility`**
  (a target lists which labels may depend on it; `gn gen` errors on violations) and
  **`gn check`**, the header-inclusion checker — _"GN's include header checker
  validates that the includes for C-like source files match the build dependency
  graph"_ ([`GN` reference][gn-ref]). Plus `assert_no_deps` lets a target forbid a
  banned dependency anywhere in its transitive closure. These are _correctness_
  tools, not _hermeticity_ tools.
- **`testonly`** marks targets usable only by other `testonly` targets — preventing
  test code from leaking into shipping binaries, checked at `gn gen` time.

### 3. Task orchestration & scheduling

- **`GN` builds the DAG; `Ninja` schedules it.** `GN` resolves the full transitive
  target graph and lowers it to `build.ninja` edges. `Ninja` then constructs its own
  file-level DAG and runs ready edges concurrently — _"Builds are always run in
  parallel, based by default on the number of CPUs your system has"_ (override with
  `-j`) ([`Ninja` manual][ninja-manual]). Since `Ninja` 1.13 it also speaks the GNU
  Make **jobserver** protocol, so nested builds share one global job budget.
- **Change detection: `mtime` + command-line hash (not content hashing).** This is a
  deliberate divergence from the content-addressed engines. `Ninja` rebuilds an edge
  when an input `mtime` is newer than the output, or when the recorded command
  changed (`.ninja_log`). It does **not** hash file contents by default, so a
  touched-but-unchanged file _will_ trigger a rebuild — the speed/correctness trade
  `Ninja` chose (`restat` mitigates the cascade for generators). Header deps come
  from compiler depfiles into `.ninja_deps`, so adding/removing an `#include`
  correctly re-triggers without manual edge edits.
- **Affected-target detection via `gn refs`.** `GN`'s monorepo-slicing primitive is
  `gn refs`, which _"Finds reverse dependencies (which targets reference
  something)"_ ([`GN` reference][gn-ref]). Crucially it accepts **file** inputs:

  ```bash
  # Which targets list this header as a source?
  gn refs out/Default //base/macros.h

  # All targets that depend (directly or transitively) on a changed file:
  gn refs out/Default //base/macros.h --all
  ```

  Feeding a git diff's changed files into `gn refs … --all` yields the set of
  affected targets — the CI pattern
  `ninja -C out $(gn refs out <changed-files> --all)`. This is `GN`'s analogue of
  [Turborepo][turborepo]'s `--filter=...[ref]`
  or [Please][please]'s `plz query changes`, but it is a _graph query you run
  yourself_, not a first-class `--since` flag, and it works off the _generated_
  graph in an out-dir rather than a git revision diff.

- **Rich graph introspection.** `gn desc <out> <target> deps --tree` prints a
  dependency tree; `gn path <out> //a //b` finds dependency paths between two
  targets; `gn ls <out> <pattern>` lists matching targets; `gn outputs` maps a
  target to its output files; `gn desc … defines --blame` traces where a `define`
  came from across `public_configs`.

### 4. Caching & remote execution

- **`GN` itself does no caching and no remote execution — by design.** `GN` is a
  generator; it produces files and exits. There is no build cache, no action cache,
  no REAPI client _in `GN`_. The [`GN` reference][gn-ref] documents none, and that
  is the whole point of the two-layer split.
- **`Ninja`'s "cache" is the incremental out-dir.** Native `Ninja` has no remote or
  shared cache either — its incrementality comes entirely from `mtime` + the
  `.ninja_log`/`.ninja_deps` databases in the output directory. Reusing an out-dir
  across git branches gives fast local rebuilds, but there is no content-addressed
  store and nothing shared between machines out of the box.
- **Remote execution is bolted on at the _command_ level.** Large `GN`+`Ninja`
  shops get caching/RBE by **wrapping the compiler command** that `GN` emits, not by
  any `GN`/`Ninja` feature. In Chromium this is a `gn arg`-controlled **rewrapper**
  prefix in front of `cc`/`cxx`, plus a `reproxy`/`reclient` daemon started around
  the `ninja` invocation, talking the **Remote Execution API (REAPI)** to a backend
  (e.g. an [RBE][bazel] cluster). Because _"GN's language flexibility"_ lets the
  toolchain prepend an arbitrary wrapper, RBE integration is purely a configuration
  choice — neither `GN` nor `Ninja` knows it is happening.

  > [!NOTE]
  > This is the opposite of [Bazel][bazel]/[Buck2][buck2], where remote caching and
  > REAPI execution are _core engine features_ keyed on hermetic input hashes. With
  > `GN`+`Ninja` the engine is cache-agnostic and the org must assemble the RBE
  > stack (reclient/`Goma`-style) themselves.

- **`Siso` is the strategic answer.** Google is migrating the _executor_ (not `GN`)
  from `Ninja` to **`Siso`** — a Go reimplementation that is a _"drop-in replacement
  for Ninja"_ with **native remote execution and remote caching** built in. As of
  2026 Chromium/WebRTC are mid-migration (Android builds began switching in Feb
  2026). The division of labor is preserved: **`GN` still generates the graph**;
  `Siso` replaces `Ninja` to make REAPI caching/execution first-class instead of
  command-wrapped. REAPI servers that `Siso` (and reclient) can target include
  `BuildBuddy`, `Buildbarn`, and `NativeLink`.

### 5. CLI / UX ergonomics

- **Two binaries, two verbs.** The command boundary is `gn` for _generate &
  introspect_ and `ninja` for _build_. There is no single tool: you `gn gen` once
  (and re-run only when adding files), then `ninja -C <out>` to build. `ninja
//chrome:chrome` builds one target; bare `ninja -C out/Default` builds the default
  set.
- **Out-dir is the unit of selection, label is the target.** Unlike the
  `--filter`/`-p` package selectors of [pnpm][pnpm]/[Turborepo][turborepo], `GN`
  selection is _label-based_: `ninja -C out //path:target`. Multiple configurations
  are multiple out-dirs (`out/Debug`, `out/Release`, `out/android`), each fully
  independent — the parallel-output-directories model.
- **`gn` subcommands are the introspection surface.** `gn gen`, `gn args`
  (edit/list build args), `gn desc` (target details: `deps`, `defines`, `sources`,
  `--tree`, `--blame`), `gn refs` (reverse deps / affected targets), `gn path`
  (path between targets), `gn ls` (list targets), `gn outputs` (target→files), `gn
check` (header validation), `gn format` (canonical `BUILD.gn` formatting), `gn
clean`, and `gn meta` (walk the metadata graph). `GN` _"has comprehensive built-in
  help available from the command-line"_ ([`gn.googlesource.com/gn`][gn-home]) —
  `gn help <topic>` documents every function and built-in variable, and the entire
  [reference][gn-ref] is that help concatenated.
- **Toolchain on the label, not a flag.** Targeting a specific platform is
  `ninja //foo:bar(//build/toolchain:android)` or selecting the right out-dir whose
  `args.gn` sets `target_os`/`target_cpu` — the multi-platform story is expressed in
  configuration and labels rather than CLI filter flags.

---

## Strengths

- **Generator/executor separation scales.** Pushing all policy into `GN` and all
  speed into `Ninja` is why Chromium-scale repos (tens of thousands of files) build
  with near-instant incrementality. The same `Ninja` backend is reused by
  `CMake` and `Meson`, proving the executor's generality.
- **First-class multi-platform via toolchains.** One `gn gen` can cross-compile the
  same sources for host + multiple devices/architectures in a single graph — a
  capability the language-package-managers simply don't have.
- **Correctness tooling without a sandbox.** `gn check` (header/include validation),
  `visibility`, `testonly`, and `assert_no_deps` catch dependency errors at generate
  time — strong guard-rails tuned for large teams.
- **Clean, legible, _minimally expressive_ DSL.** `BUILD.gn` is easy for non-experts
  to edit; `gn format` enforces one canonical style; built-in `gn help` is thorough.
- **Powerful graph introspection.** `gn refs`/`desc`/`path`/`ls` make the dependency
  graph queryable for affected-target slicing, blame, and auditing.
- **`Ninja` is tiny, fast, and ubiquitous.** A minimal, well-understood executor with
  reliable depfile-based header tracking and jobserver-aware parallelism.

## Weaknesses

- **No dependency management whatsoever.** No fetch, no version resolution, no
  lockfile — you must vendor everything (Chromium needs `gclient`/`DEPS` as a wholly
  separate layer). There is no answer to [Cargo][cargo]/[uv][uv]-style registry
  dependencies.
- **No built-in caching or remote execution.** Native `Ninja` caches only via the
  local out-dir; RBE must be assembled externally (command-wrapping +
  reclient/`Siso`), unlike the engine-native REAPI of [Bazel][bazel]/[Buck2][buck2].
- **No hermeticity / no content hashing.** `mtime`-based change detection can both
  over-build (touched-but-unchanged files) and, without sandboxing, miss undeclared
  inputs — correctness leans on `gn check` and discipline rather than enforcement.
- **Deliberately limited expressiveness.** No user-defined rule types; `template()`
  - built-in targets only. Complex generation patterns that Starlark expresses
    directly require contortions.
- **No versioning / unstable interface.** `GN` ships no releases — you pin a commit;
  there is no stable API contract beyond "main is expected to be stable."
- **Two-tool, two-step workflow.** `gn gen` then `ninja` is more ceremony than a
  single-binary tool, and the model is squarely C/C++/Rust/ObjC/Swift-centric, not
  general-purpose.

## Key design decisions and trade-offs

| Decision                                                           | Rationale                                                                                           | Trade-off                                                                                            |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| Strict generator (`GN`) / executor (`Ninja`) split                 | Policy lives in a legible DSL; execution is a "dumb", maximally-fast assembler                      | Two binaries, a generate-then-build two-step; the IR (`build.ninja`) is machine-only                 |
| `Ninja` "aims to be an assembler"; speed over convenience          | Instant incremental builds at Chromium scale; minimal, predictable executor                         | `Ninja` files are unwritable by hand; all ergonomics must come from the generator                    |
| `GN` is "minimally expressive" (no user rule types)                | A well-lit path for large teams who don't know the build; legibility and consistency                | Cannot express what Starlark/Buck rules can; complex codegen is awkward                              |
| Workspace = tree under a `.gn` dotfile (no member list)            | Zero ceremony — every `BUILD.gn` dir is a package automatically                                     | No explicit sub-workspace scoping or named member sets; can't partition a repo declaratively         |
| Toolchain as a second axis on every label                          | One `gn gen` cross-compiles the same sources for many platforms in one graph                        | A mental-model cost; the same target exists once per toolchain, multiplying graph nodes              |
| **No** package manager / lockfile / resolver                       | Keeps `GN` a pure generator; deps are whatever is on disk under `//`                                | Needs a wholly separate vendoring tool (`gclient`/`DEPS`); no registry-dependency story              |
| `mtime` + command-hash change detection (not content hashing)      | Fast startup via `.ninja_log`/`.ninja_deps`; no hashing every file                                  | Over-builds on touched-but-unchanged files; not hermetic; relies on `gn check` for input correctness |
| Caching/RBE bolted on by wrapping the compiler command             | Org chooses any REAPI backend without engine lock-in; integration is just a `gn arg`                | No engine-native caching; teams must run reclient/`reproxy`/`Siso` and a CAS cluster themselves      |
| Correctness via `gn check`/`visibility`/`testonly` (not a sandbox) | Catches graph errors at generate time without sandbox overhead                                      | Not hermetic — undeclared reads aren't prevented, only header-include mismatches are flagged         |
| `Siso` replaces the _executor_, not `GN`                           | Adds native remote execution/caching while preserving the generator and the whole `BUILD.gn` corpus | A migration in flight (2025–2026); two executors coexist during the transition                       |

---

## Sources

- [`gn.googlesource.com/gn` — landing page (strengths, projects, parallel out-dirs)][gn-home]
- [`gn.googlesource.com/gn` `README.md` — "minimally expressive", versioning stance][gn-repo]
- [`GN` reference (all built-in help concatenated): targets, `deps`/`public_deps`,
  `gn refs`/`gn check`/`gn desc`, the `.gn` dotfile, toolchains][gn-ref]
- [`GN` quick start — `BUILD.gn` examples, labels, `declare_args`, `gn gen`/`gn args`][gn-quickstart]
- [`Ninja` manual — design goals/non-goals, "aims to be an assembler", rules/build
  statements, `deps`/`depfile`, `restat`, parallelism, jobserver][ninja-manual]
- [Fuchsia — Introduction to GN (per-toolchain instantiation, multi-platform model)][fuchsia-intro]
- [Chromium build instructions / Reclient + Siso remote execution context][chromium-build]
- [`Siso` README — drop-in `Ninja` replacement with native remote execution][siso-readme]
- Sibling deep-dives: [Bazel][bazel] · [Buck2][buck2] · [Please][please] ·
  [Pants][pants] · `Meson` · `CMake` · `Ninja` ·
  [Cargo][cargo] · [Turborepo][turborepo] · [pnpm][pnpm] · [npm][npm] ·
  [Yarn Berry][yarn-berry] · [Go (`go.work`)][go-work] · [uv][uv]; REAPI backends
  `BuildBuddy` / `Buildbarn` / `NativeLink`; the
  umbrella [survey index][umbrella] and the [D async/`dub` landscape][d-landscape]

<!-- References -->

[gn-home]: https://gn.googlesource.com/gn/
[gn-repo]: https://gn.googlesource.com/gn/+/main/README.md
[gn-ref]: https://gn.googlesource.com/gn/+/main/docs/reference.md
[gn-quickstart]: https://gn.googlesource.com/gn/+/main/docs/quick_start.md
[ninja-repo]: https://github.com/ninja-build/ninja
[ninja-manual]: https://ninja-build.org/manual.html
[fuchsia-intro]: https://fuchsia.dev/fuchsia-src/development/build/build_system/intro
[chromium-build]: https://chromium.googlesource.com/chromium/src/+/main/docs/linux/build_instructions.md
[siso-readme]: https://chromium.googlesource.com/infra/infra/+/main/go/src/infra/build/siso/README.md
[bazel]: ../bazel/
[buck2]: ../buck2/
[please]: ../please/
[pants]: ../pants/
[cargo]: ../cargo/
[turborepo]: ../turborepo/
[pnpm]: ../pnpm/
[npm]: ../npm/
[yarn-berry]: ../yarn-berry/
[go-work]: ../go-work/
[uv]: ../uv/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
