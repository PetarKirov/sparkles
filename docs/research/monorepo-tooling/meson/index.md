# Meson (C/C++/native)

A fast, batteries-included native build system whose monorepo story is the
**subproject** — any Meson (or CMake, or Cargo) project nested under
`subprojects/`, wired in by a small `.wrap` manifest and stitched into one
`build.ninja` graph that a separate executor (`ninja`) runs.

| Field           | Value                                                                                                                        |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Language        | `Python` (≥ 3.10); generated build graph is consumed by `Ninja` (C++), `Visual Studio`, or `Xcode` backends                  |
| License         | Apache-2.0 (`mesonbuild/coredata.py`: `license = Apache License, Version 2.0`)                                               |
| Repository      | [`mesonbuild/meson`][repo]                                                                                                   |
| Documentation   | [`mesonbuild.com`][docs] · [Subprojects][subprojects-doc] · [Wrap manual][wrap-doc]                                          |
| Category        | Native Build System                                                                                                          |
| Workspace model | **Root project + nested `subprojects/`**: one root `meson.build` plus per-dependency `subprojects/<name>/` trees and `.wrap` |
| First released  | `0.1.0`, March 2013 (Jussi Pakkanen)                                                                                         |
| Latest release  | `1.11.1`, April 21, 2026 (`1.12.0` in development; `master` is `1.11.99`)                                                    |

> **Latest release (as of June 5, 2026):** `1.11.1` (April 21, 2026), per
> [PyPI][pypi]. Releases cadence is roughly quarterly minor versions (`1.10.0`
> Dec 2025, `1.11.0` Apr 2026) with patch releases between. The mechanics below
> are quoted from the `master` checkout at commit `546e47e` (self-reported
> version `1.11.99`); behavior matches the `1.11.x` line. Meson requires
> `Python ≥ 3.10` and (for the default backend) `Ninja ≥ 1.8.2`.

---

## Overview

### What it solves

Meson targets the **multiplatform native build** problem: one source tree that
must compile correctly and quickly across GCC/Clang/MSVC, across Linux/macOS/
Windows/cross-compiled targets, in many languages (C, C++, D, Rust, Fortran,
Vala, C#, Objective-C, CUDA, …), without the developer hand-writing the brittle,
Turing-complete recipes that `Make`, `Autotools`, and to a lesser extent
[`CMake`][cmake] demand. Its pitch is explicitly about _developer time_ — quoting
the project home page:

> _"every moment a developer spends writing or debugging build definitions is a
> second wasted. So is every second spent waiting for the build system to
> actually start compiling code."_ ([`mesonbuild.com`][docs])

Architecturally Meson is a **two-layer, generate-then-execute** system, the same
split that powers [`GN` + `Ninja`][gn]: the `meson` front end (Python) reads a
**non-Turing-complete** `meson.build` DSL, resolves the full target graph, and
**writes a `build.ninja`** file; the back end (`Ninja` by default, or
`vs2010`…`vs2026`/`xcode`) is a dumb, fast executor that schedules and runs the
compile/link commands. Meson itself never compiles anything.

The monorepo dimension is the **subproject**: Meson can take "any other Meson
project and make it a part of your build" so it "becomes a transparent part of
the project" ([`Subprojects.md`][subprojects-doc]). A root project declares a
dependency, and a one-page `.wrap` manifest under `subprojects/` tells Meson
where to fetch it; the subproject's own `meson.build` is interpreted inline, its
targets fold into the parent's single Ninja graph, and a `dependency()` lookup
resolves either to a system library or transparently to the bundled subproject.
This is Meson's answer to the same need that [`Cargo` workspaces][cargo] and
[`go.work`][go-work] address — local cross-references plus unified builds — but
reached from the C/C++ "vendored dependency" tradition rather than a package
registry.

### Design philosophy

Three principles shape the whole system and its monorepo behavior:

1. **A declarative, non-Turing-complete DSL.** `meson.build` is interpreted by a
   restricted interpreter (`mesonbuild/interpreterbase/`) with no user-defined
   functions, no unbounded loops, and no arbitrary I/O — deliberately, so the
   build description stays analyzable and fast to evaluate. Configuration is data,
   not a program.
2. **Generate, then execute.** The Python front end produces a static
   `build.ninja`; correctness and incrementality are the executor's job. This
   keeps Meson's hot path (re-running an existing build) at native `ninja` speed
   while Meson re-runs only when a `meson.build` changes.
3. **"Do the right thing" defaults.** Out-of-source builds, automatic dependency
   discovery (`pkg-config`, CMake config, system probes), unity builds, install
   layouts, `ccache`/`sccache` auto-detection, and reproducible cross-compilation
   are all built in, so a small `meson.build` gets a correct build without
   boilerplate.

Within this survey Meson is the canonical _native build system with an
integrated, vendoring-based workspace model_. Compare it against
[`CMake`][cmake] (which reaches subprojects via `add_subdirectory` /
`FetchContent` and `find_package`), against [`GN` + `Ninja`][gn] (same
generate/execute split, but no package fetcher and a Chromium-specific niche),
and against the registry-driven [`Cargo`][cargo] / [`go.work`][go-work] models.
For the D-language context this research feeds, see [the D landscape][d-landscape].

---

## How it works

### The front end: interpret `meson.build`, emit `build.ninja`

A build is a two-step lifecycle on the command line:

```bash
meson setup builddir        # interpret meson.build(s) → write builddir/build.ninja
meson compile -C builddir   # invoke ninja (or the chosen backend) to build
meson test    -C builddir   # run the registered test() targets
meson install -C builddir   # stage the install() outputs
```

`meson setup` instantiates an `Interpreter` (`mesonbuild/interpreter/
interpreter.py`) that walks the AST of the root `meson.build`, evaluating
`project()`, `executable()`, `library()`, `dependency()`, `subproject()`,
`test()`, `install_*()` and friends into an in-memory `Build` object. The chosen
**backend** (default `NinjaBackend`, `mesonbuild/backend/ninjabackend.py`) then
serializes that `Build` into `build.ninja`. The DSL is intentionally restricted —
there are no user functions and no general loops — which is what lets the whole
graph be materialized in one evaluation pass.

A minimal root `meson.build` that consumes a subproject:

```meson
project('app', 'c', version : '1.0.0')

# Resolve `zlib`: a system pkg-config dependency if present, otherwise the
# subprojects/zlib/ fallback declared in subprojects/zlib.wrap.
zlib_dep = dependency('zlib', fallback : ['zlib', 'zlib_dep'])

executable('app', 'main.c', dependencies : zlib_dep, install : true)
test('smoke', executable('t', 'test.c'))
```

### 1. Workspace declaration & topology

Meson has **no separate workspace manifest**. The "workspace" is implicit: a
**root `meson.build`** plus a conventional `subprojects/` directory beside it.
Topology is discovered two ways, both rooted at that directory (whose name is
configurable per project via the `subproject_dir` kwarg of `project()`,
default `'subprojects'`):

- **`.wrap` files** — `subprojects/<name>.wrap`, an INI manifest naming where to
  fetch the dependency.
- **Bare directories** — any directory directly under `subprojects/` that is not
  a `packagecache`/`packagefiles` overlay is treated as an already-vendored
  subproject even with no `.wrap`.

The `Resolver.load_wraps` method (`mesonbuild/wrap/wrap.py`) is the discovery
loop — it `os.walk`s `subprojects/` once, registering every `*.wrap` and then
every non-ignored directory as a `PackageDefinition`:

```python
# mesonbuild/wrap/wrap.py — Resolver.load_wraps (abridged)
root, dirs, files = next(os.walk(self.subdir_root))
for i in files:
    if not i.endswith('.wrap'):
        continue
    wrap = PackageDefinition.from_wrap_file(os.path.join(self.subdir_root, i), self.subproject)
    self.wraps[wrap.name] = wrap
# Add dummy package definition for directories not associated with a wrap file.
ignore_dirs = {'packagecache', 'packagefiles'}
for wrap in self.wraps.values():
    ignore_dirs |= {wrap.directory, wrap.name}
for i in dirs:
    if i in ignore_dirs:
        continue
    wrap = PackageDefinition.from_directory(os.path.join(self.subdir_root, i))
    self.wraps[wrap.name] = wrap
```

There is **no glob/array membership list** (unlike [`Cargo`][cargo]'s
`members = ["libs/*"]` or [`pnpm`][pnpm]'s `packages:`). Membership is
**lazy and demand-driven**: a subproject only enters the graph when the root (or
another subproject) actually calls `subproject('name')` or hits its `fallback`.
A subproject can itself have a `subprojects/` directory, so the topology is a
**recursive tree**; recursion is guarded (`do_subproject` raises
`InvalidCode: Recursive include of subprojects` on a cycle in the
`subproject_stack`). Crucially, nested wraps are **promoted**: a grandchild's
`.wrap` is hoisted into the top-level `subprojects/` so the whole tree shares one
flat namespace of subproject directories (the `wrap-redirect` type and
`load_and_merge`/`merge_wraps` implement this; `--wrap-mode=nopromote` disables
it).

> [!NOTE]
> Because membership is demand-driven, Meson never builds a subproject the root
> does not reference. This is closer to [`go.work`][go-work]'s "only what's
> imported" than to a virtual workspace that enumerates every member up front.

The four `.wrap` source types are `wrap-file` (download + extract a tarball),
`wrap-git`, `wrap-hg`, `wrap-svn`, plus the `wrap-redirect` indirection. A
`wrap-git` example:

```ini
[wrap-git]
directory = zlib
url = https://github.com/madler/zlib.git
revision = v1.3.1
depth = 1

[provide]
zlib = zlib_dep
```

### 2. Dependency handling & isolation

Meson's model is **vendoring into an isolated source subtree**, not hoisting or a
content-addressed store. Each subproject is fetched into its own
`subprojects/<directory>/` and built **in-tree** from source as part of the
parent build — there is no global package cache shared across projects (only a
per-build `subprojects/packagecache/` for downloaded archives).

The pivotal abstraction is the **`[provide]` section** of a `.wrap`, which maps
**`dependency()` names to subproject variables**. This is what makes a subproject
a transparent fallback. The `Resolver` builds a `provided_deps` lookup table from
every wrap's `[provide]` block (`parse_provide_section`); when a `dependency('X')`
call cannot find `X` on the system, `DependencyFallbacksHolder`
(`mesonbuild/interpreter/dependencyfallbacks.py`) consults that table, configures
the providing subproject, and returns the variable named there (e.g. `zlib_dep`)
as if it were a system dependency. So the **same `dependency('zlib')` call**
resolves to a system `libz` on one machine and to the bundled subproject on
another, with no code change — Meson's equivalent of a local cross-reference
([Yarn's `workspace:` protocol][yarn-berry], [`Cargo`'s path deps][cargo]).

The fallback decision is governed by **`WrapMode`** (`mesonbuild/wrap/__init__.py`),
a five-valued policy:

| `WrapMode`      | Effect                                                                          |
| --------------- | ------------------------------------------------------------------------------- |
| `default`       | Download wraps for both `subproject()` calls and `dependency()` fallbacks       |
| `nofallback`    | Never download a wrap to satisfy a `dependency()` _fallback_                    |
| `nodownload`    | Never download a wrap for **any** `subproject()` call (use only vendored trees) |
| `forcefallback` | Ignore system deps; always use the subproject fallback (test the bundled build) |
| `nopromote`     | Do not hoist nested subprojects' wraps to the top level                         |

Isolation is **per-build-directory and per-subproject option namespace**: each
subproject is interpreted with `self.build.copy()` (a fresh `Build` whose target
lists are shared upward) and its options live under a `subproject` key, so a
parent can force `default_library=static` on just the fallback
(`forced_options` in `do_subproject`) without touching its own settings. There is
**no lockfile** in the [`Cargo`][cargo]/[`uv`][uv] sense for Meson-native wraps:
the `revision`/hash in each `.wrap` _is_ the pin, and
`.meson-subproject-wrap-hash.txt` records the wrap-file SHA-256 so
`meson subprojects update` can detect drift. (Meson _does_ read a `Cargo.lock`
when consuming Cargo subprojects, via `mesonbuild/cargo/`.)

> [!IMPORTANT]
> A consequence of in-tree, from-source vendoring: there is **no cross-project
> reuse** of a built subproject. If two sibling projects both vendor `zlib`, each
> builds its own copy in its own `builddir`. Meson optimizes _within_ one build
> tree, not across many — contrast the content-addressed sharing of
> [`Bazel`][bazel]/[`pnpm`][pnpm].

### 3. Task orchestration & scheduling

Meson splits orchestration cleanly: **the front end builds the DAG; `Ninja`
schedules and runs it.** During `setup`, the interpreter produces a complete
target graph — every `executable`/`library`/`custom_target`/`generator` becomes a
`NinjaBuildElement` with explicit inputs, outputs, and `order-only` dependencies —
and `NinjaBackend.generate` writes it all into `build.ninja`. Subproject targets
are emitted into the **same** file, so cross-subproject ordering is just ordinary
graph edges; there is no separate "topological foreach" loop because the whole
monorepo is one graph by the time `ninja` runs.

Concurrency and change-detection are `Ninja`'s job:

- **Parallelism** — `ninja` runs the graph with `-j` worker parallelism
  automatically; `meson compile -j N` / `meson test -j N` forward the job count.
- **Change detection** — `ninja` rebuilds a target when an input's `mtime` is
  newer than the output (it stores command lines and a build log in
  `.ninja_log`/`.ninja_deps` to also rebuild on command-line or header changes).
  This is **timestamp + depfile** based, _not_ content hashing — there is no
  input-hash/affected-target computation across Git refs the way
  [`Nx`][nx]/[`Turborepo`][turborepo] do.
- **Header-accurate incrementality** — for C/C++ Meson emits compiler `depfile`s,
  and for languages with module ordering (Fortran, C++20 modules) it generates a
  **`dyndep`** scanner target so `ninja` learns inter-object ordering at build
  time:

  ```python
  # mesonbuild/backend/ninjabackend.py
  self.ninja_has_dyndeps = mesonlib.version_compare(self.ninja_version, '>=1.10.0')
  # ...
  def should_use_dyndeps_for_target(self, target): ...
  #   emits a `depscan` rule whose output is a .dd dyndep file consumed by ninja
  ```

- **Auto-reconfigure** — Meson injects a `REGENERATE_BUILD` rule so that editing
  any `meson.build` makes `ninja` re-invoke `meson setup --reconfigure` before
  building, keeping the generated graph in sync.

For the test phase, `meson test` (`mesonbuild/mtest.py`) is an **`asyncio`-driven
parallel test harness** independent of the build graph: it runs registered
`test()` targets concurrently (`-j`, default = CPU count), understands result
**protocols** (`exitcode`, `tap`, `gtest`, `rust`), supports `--repeat`,
`--suite`/`--no-suite` filtering, timeouts, and test setups (wrappers like
`valgrind`). So the orchestration story is: one static build DAG executed by
`ninja`, plus a separate async runner for tests.

### 4. Caching & remote execution

This is Meson's thinnest dimension by design. Meson has **no native build cache
and no remote-execution / REAPI** support; it **delegates** both downward:

- **Incremental local "cache"** is just `ninja`'s `mtime`/depfile incrementality
  in the build directory — rebuild only what changed since last time. There is no
  cross-invocation, content-addressed action cache and no `--since <ref>`
  affected-target slicing.
- **Compiler-level caching** is delegated to **`ccache`/`sccache`**, which Meson
  **auto-detects and prepends** to compile commands (`mesonbuild/envconfig.py`:
  `detect_sccache()` then `detect_ccache()`; "Sccache is 'newer' so it is assumed
  that people would prefer it by default"). `sccache` is itself capable of a
  shared/remote object cache (S3, Redis, GCS), so _that_ is where any "remote
  caching" lives — outside Meson.
- **No REAPI back end.** Unlike [`Bazel`][bazel]/[`Buck2`][buck2]/[`Pants`][pants]
  (or the remote-execution backends `BuildBuddy`/`Buildbarn`/`NativeLink`),
  Meson actions are not hermetic content-addressed
  actions and cannot be farmed out to a remote cluster. Distribution, if any, is
  again `distcc`/`sccache` at the compiler layer.

> [!WARNING]
> If you need a shared/remote build cache or affected-only CI runs across a large
> monorepo, Meson does **not** provide them. The pragmatic combination is
> `meson` + `ninja` + `sccache` (shared object cache) and a CI script that scopes
> what to build. The content-addressed, remotely-cached action graph is the
> domain of the polyglot engines in this survey.

### 5. CLI / UX ergonomics

Meson's command boundary is **verb-first subcommands operating on a build
directory**, not per-target broadcast flags:

| Command                          | Role                                                                     |
| -------------------------------- | ------------------------------------------------------------------------ |
| `meson setup builddir`           | Configure: interpret `meson.build`(s), resolve wraps, emit `build.ninja` |
| `meson compile -C builddir`      | Build (backend-agnostic wrapper over `ninja`/MSBuild/`xcodebuild`)       |
| `meson test -C builddir`         | Run registered tests (parallel; `--suite`, `--repeat`, `--gdb`)          |
| `meson install -C builddir`      | Stage install outputs                                                    |
| `meson configure builddir -Dk=v` | Re-tune options without re-running the whole front end                   |
| `meson subprojects <sub-cmd>`    | Manage the subproject/workspace tree (see below)                         |
| `meson wrap <sub-cmd>`           | Interact with WrapDB (`install`/`search`/`update`/`info`)                |
| `meson devenv -C builddir`       | Spawn a shell with the build's env (uninstalled binaries on `PATH`)      |

Target **slicing** is mostly positional: `meson compile -C builddir foo bar`
builds named targets; `ninja foo:` / `ninja -C builddir <target>` works directly.
Tests are sliced with **`--suite`/`--no-suite`** and by name, not a `--filter`
glob. There is no `-p <package>` / `--filter <pattern>` / `--since <ref>`
vocabulary like [`pnpm`][pnpm]/[`Nx`][nx]/[`Turborepo`][turborepo] — the unit of
selection is the _target_ within the single graph, or the _suite_ for tests.

The dedicated **workspace verb is `meson subprojects`** (`mesonbuild/
msubprojects.py`), and it _does_ provide the "do X across every member" loop that
the build graph otherwise makes unnecessary. Its subcommands run across all
subprojects **in parallel via a `ThreadPoolExecutor`** (`-j/--num-processes`):

| `meson subprojects …` | Effect                                                                  |
| --------------------- | ----------------------------------------------------------------------- |
| `download`            | Fetch all subprojects (even unused ones) without configuring            |
| `update`              | Update each subproject from its `.wrap` (git pull/checkout, re-extract) |
| `checkout <branch>`   | `git checkout` a branch in every git subproject                         |
| `foreach <cmd> …`     | Run an arbitrary command in **each** subproject directory               |
| `purge`               | Remove wrap-based subproject artifacts (clean the vendored trees)       |
| `packagefiles`        | Manage the `packagefiles/` patch overlay                                |

`meson subprojects foreach git status` is the closest analogue to
[`yarn workspaces foreach`][yarn-berry] / [`pnpm -r exec`][pnpm], but it operates
on the **source/VCS** layer (keeping vendored checkouts in sync), because the
**build** layer is already unified into one Ninja graph and needs no per-member
fan-out.

---

## Strengths

- **Fast configure + fast incremental builds.** The restricted DSL evaluates in
  one pass; `ninja` gives near-optimal incremental rebuilds and parallelism for
  free. "Time waiting for the build system" is the explicit thing minimized.
- **Transparent, low-ceremony subprojects.** A `.wrap` plus `[provide]` makes a
  bundled dependency indistinguishable from a system one at the `dependency()`
  call site; the same build works on a machine with the system lib and one
  without.
- **Demand-driven, recursive topology with wrap promotion.** No membership list
  to maintain; nested dependencies are hoisted to one flat `subprojects/`
  namespace so a deep tree shares one copy of each transitive dependency.
- **Polyglot and cross-build native.** C/C++/D/Rust/Fortran/Vala/CUDA/… plus
  first-class cross-compilation (machine files), unity builds, and automatic
  `pkg-config`/CMake dependency discovery.
- **Multiple back ends from one description.** The same `meson.build` emits
  `Ninja`, Visual Studio, or Xcode projects.
- **Parallel subproject maintenance.** `meson subprojects` (update/foreach/
  checkout) handles the VCS side of a vendored monorepo with thread-pool
  concurrency.
- **Genuine WrapDB ecosystem.** A curated registry of ready-made `.wrap`s for
  common C/C++ libraries, installable with `meson wrap install`.

## Weaknesses

- **No build/test caching beyond `ninja` mtime; no remote execution.** No
  content-addressed action cache, no REAPI, no `--since <ref>` affected slicing —
  these live in `sccache` or a CI script, not Meson.
- **No cross-project artifact reuse.** Each build tree vendors and rebuilds its
  own copy of every subproject; two sibling repos sharing `zlib` build it twice.
- **No lockfile for native wraps.** Pins live inline in each `.wrap` (revision +
  wrap hash); there is no single resolved manifest unifying the whole tree (only
  `Cargo.lock` is read for Cargo subprojects).
- **Vendoring-centric, not registry-centric.** The model assumes you fetch and
  build dependencies from source into your tree; it is not a package manager for
  consuming prebuilt binary artifacts.
- **Mixed-build-system subprojects are best-effort.** Only Meson subprojects are
  guaranteed; CMake subprojects are "supported but not guaranteed to work," and
  arbitrary build systems are out of scope.
- **Filter ergonomics are thin.** Selection is by target name or test suite;
  there is no rich `--filter`/`-p`/`--scope` package-selection grammar.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                          | Trade-off                                                                                       |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Generate `build.ninja`, let `ninja` execute                    | Keep the front end analyzable and the hot path at native executor speed            | Caching/scheduling capabilities are bounded by the executor (mtime, no remote, no action cache) |
| Non-Turing-complete declarative DSL                            | Whole graph materializes in one pass; builds stay fast and predictable             | Some builds need `custom_target`/scripts to express logic the DSL forbids                       |
| Subprojects = in-tree, from-source vendoring                   | Works without a package manager; bundled deps build identically everywhere         | No cross-project reuse; each build tree recompiles its own copy of every subproject             |
| `[provide]` maps `dependency()` names to subproject variables  | Same `dependency('X')` resolves to system lib _or_ bundled fallback transparently  | A `.wrap` author must declare the provide map correctly or the fallback won't trigger           |
| Demand-driven topology (no membership array)                   | Zero membership boilerplate; only referenced subprojects build                     | No up-front "all members" view; tooling/CI must discover the tree itself                        |
| Wrap promotion (hoist nested wraps to top level)               | Deep dependency trees share one flat namespace and one copy of each transitive dep | Surprising hoisting/diamond resolution; mitigated/disabled by `--wrap-mode=nopromote`           |
| Pins live inline in each `.wrap` (no unified lockfile)         | Simple, file-local, reviewable; hash file detects drift                            | No single resolved view of the whole tree; weaker reproducibility guarantees than a lockfile    |
| Delegate caching to `ccache`/`sccache`, distribution to them   | Reuse mature tools; keep Meson's core small                                        | No first-party shared cache/remote-execution; cross-machine speedups are opt-in and external    |
| `meson subprojects foreach`/`update` over VCS, not build graph | Build layer is already one graph; only source/VCS sync needs a per-member loop     | The "workspace command" operates on checkouts, not on builds; no topological build broadcast    |

---

## Sources

- [`mesonbuild/meson` — GitHub repository][repo] (source for all quoted file paths; `master` @ `546e47e`, v`1.11.99`)
- [`mesonbuild.com` — official documentation & design statement][docs]
- [`Subprojects.md` — subproject model, transparency, wrap modes][subprojects-doc]
- [`Wrap-dependency-system-manual.md` — `.wrap` format, `[provide]`, WrapDB][wrap-doc]
- [`mesonbuild/wrap/wrap.py` — `Resolver`, `PackageDefinition`, discovery & promotion][wrap-src]
- [`mesonbuild/interpreter/interpreter.py` — `do_subproject`, recursion guard, option forcing][interp-src]
- [`mesonbuild/interpreter/dependencyfallbacks.py` — `dependency()` → subproject fallback][fallback-src]
- [`mesonbuild/backend/ninjabackend.py` — `build.ninja` generation, `dyndep`, reconfigure][ninja-src]
- [`mesonbuild/msubprojects.py` — parallel `subprojects` subcommands][msub-src]
- [`mesonbuild/mtest.py` — `asyncio` parallel test harness][mtest-src]
- [`meson` on PyPI — release history][pypi]
- Sibling tools: [`CMake`][cmake] · [`GN` + `Ninja`][gn] · [`Cargo`][cargo] · [`go.work`][go-work] · [`pnpm`][pnpm] · [`Yarn Berry`][yarn-berry] · [`uv`][uv] · [`Nx`][nx] · [`Turborepo`][turborepo] · [`Bazel`][bazel] · [`Buck2`][buck2] · [`Pants`][pants] · remote backends `BuildBuddy` / `Buildbarn` / `NativeLink` · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/mesonbuild/meson
[docs]: https://mesonbuild.com/
[subprojects-doc]: https://mesonbuild.com/Subprojects.html
[wrap-doc]: https://mesonbuild.com/Wrap-dependency-system-manual.html
[pypi]: https://pypi.org/project/meson/
[wrap-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/wrap/wrap.py
[interp-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/interpreter/interpreter.py
[fallback-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/interpreter/dependencyfallbacks.py
[ninja-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/backend/ninjabackend.py
[msub-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/msubprojects.py
[mtest-src]: https://github.com/mesonbuild/meson/blob/master/mesonbuild/mtest.py
[cmake]: ../cmake/
[gn]: ../gn/
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[uv]: ../uv/
[nx]: ../nx/
[turborepo]: ../turborepo/
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[d-landscape]: ../../async-io/d-landscape.md
