# Meson (Python generator, Ninja executor)

Meson is a **generator**, not an engine: it evaluates a non-Turing-complete `meson.build` into
one static task description (`build.ninja`) plus a JSON projection of that description, then
delegates every scheduling, dirty-check and parallelism decision to Ninja. Its engine
contribution is the _shape_ of the description it emits, and the loop that re-emits it.

**Last reviewed:** November 3, 2026

| Field                 | Value                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | `Python` ≥ 3.10 front end; emits `Ninja` (default), `vs*`/`xcode`, or nothing (`none` backend)                                                                                      |
| License               | Apache-2.0 ([`COPYING`][copying]; `SPDX-License-Identifier` headers on every module)                                                                                                |
| Repository            | [`mesonbuild/meson`][repo]                                                                                                                                                          |
| Documentation         | [mesonbuild.com][docs]; in-tree manuals under `docs/markdown/`                                                                                                                      |
| Category              | Native build system / meta-build (generator); engine companion to [Meson (monorepo-tooling)][mono-meson]                                                                            |
| Clone (pinned)        | `$REPOS/build-systems-research/src/meson` @ `27f69b22e5fe403d3ec5788216adaa85046d0e8f` (2026-10-30)                                                                                 |
| Scheduler × rebuilder | **No cell of its own**; `Meson + Ninja` occupies the paper's `Ninja` cell — topological × verifying traces (see below)                                                              |
| Version · tool floor  | `1.12.99` ([`coredata.py`][coredata]); the 1.12.0 notes say "Meson 1.12.0 was released on 10 August 2026" ([notes][notes112]); `Python` 3.10+, Ninja 1.8.2+ ([`README.md`][readme]) |

> [!NOTE]
> **Delta against the workspace page.** [Meson (monorepo-tooling)][mono-meson] covers the
> _workspace_ question: `subprojects/` topology, `.wrap` files, WrapDB, `declare_dependency` as
> an interchange format. This page stays inside the engine: how the graph is emitted, how the
> emitted graph is regenerated, and what the subproject mechanism means as a _dependency model_.

## Overview

### What it solves

A weak DSL interpreted by Python, and a back end that only writes files:

> "It should be noted that after the initial configure step `ninja` is the only command you
> ever need to type to compile. No matter how you alter your source tree (short of moving it
> to a completely new location), Meson will detect the changes and regenerate itself
> accordingly."
>
> — [`docs/markdown/Running-Meson.md`][running-meson]

**The build definition is itself a node in the graph**, and the generator is the build system.

### Design philosophy

Configuration is data, not computation: "The second most important tool, even more important
than the compiler, is the build system. … Those are pretty much universally despised."
([`Design-rationale.md`][rationale]). Its _consumer_ is a separate program — `mintro.py` states
both that boundary and its limit:

> "This is a helper script for IDE developers. It allows you to extract information such as
> list of targets, files, compiler flags, tests and so on. All output is in JSON for simple
> parsing. Currently only works for the Ninja backend."
>
> — [`mesonbuild/mintro.py`][mintro]

## How it works

### Introspection and regeneration

Configuration writes three artefacts. `meson-private/coredata.dat` holds options, machine
files and the meson command; `meson-private/build.dat` is a **pickle of the entire `Build`
object**, reloaded wholesale later ([`build.py`][build-py]); and `meson-info/intro-*.json` is
the _published_ view — one file per `INTRO_TYPES` key, rewritten on every regenerate
([`mintro.py`][mintro]) and consumed by `mcompile.py` ([`mcompile.py`][mcompile]).

Regeneration is a normal edge whose output is the file being read:

```text
rule REGENERATE_BUILD
  command = <meson> --internal regenerate <srcdir> .
  generator = 1
build build.ninja: REGENERATE_BUILD <every meson.build> meson-private/coredata.dat
```

`generator = 1` is Ninja's contract for "this edge writes the manifest you are reading": Ninja
reloads it afterwards. The input list is the definition set — every `meson.build` actually
read (`Interpreter.build_def_files`), the cross and command-line files, and `coredata.dat`:

> "List of all files whose alteration means that the build definition needs to be
> regenerated."
>
> — [`Backend.get_regen_filelist`, `backend/backends.py`][backends-py]

So the graph of tasks and the graph of build definitions are one graph, and that edge's
correctness rests on `mtime` alone — which is why setup writes `coredata.dat` last and worries,
in a comment, that "due to various kernel caches, we cannot guarantee that any time in Python
is exactly in sync with the time that gets applied to any files" ([`msetup.py`][msetup]).
`Backend.check_clock_skew` raises on a future timestamp that would loop the generator forever,
and `build.ninja~` is `os.replace`d atomically.

### The Ninja backend boundary

The backend interface is one method, `generate(capture, vslite_ctx) -> dict | None`, plus
helpers for filenames and install data ([`backends.py`][backends-py]). Everything Meson knows
about execution must fit in that method's output:

| Meson decides (generate time)                  | Ninja decides (build time)                           |
| ---------------------------------------------- | ---------------------------------------------------- |
| Which files are objects; which edge links them | Which edges are dirty, and in what order to run them |
| Command lines, flags, response files           | Parallelism (`-j`), pools, `console` edges           |
| Nothing about dirtiness                        | `mtime`, `restat`, `.ninja_log`, `.ninja_deps`       |

Three seams still leak policy. Header discovery is handed over as `deps = gcc`/`deps = msvc`
plus a `depfile` ([`depfile.py`][depfile]). Rules whose output may not be rewritten get
`restat = 1`, Fortran modules included, because "gfortran does not update the modification time
of `*.mod` files" ([`ninjabackend.py`][ninja-backend]). Every non-build action is a _phony_ edge
in the `console` pool that re-enters the CLI; the `none` backend goes further and emits no rules
at all ([`nonebackend.py`][none-backend]).

### Subprojects as the dependency model

A subproject is not a workspace member with its own graph; it is **an interpreted subtree
folded into the parent's single `build.ninja`**. `Interpreter.do_subproject` resolves a name
through the wrap resolver, dispatches on the resolution _method_ (`meson`, `cmake`, `cargo`),
and runs that project's interpreter in the same process against the parent's `Build`
([`interpreter.py`][interpreter]). Resolution order is what makes it a dependency model:

> "What this declaration means is that first Meson tries to look up the dependency from the
> system (such as by using pkg-config). If it is not available, then it builds subproject
> named `foo` and from that extracts a variable `foo_dep`. … Since they can be used
> interchangeably, the rest of the build definitions do not need to care which one it is."
>
> — [`docs/markdown/Dependencies.md`][deps-doc]

`DependencyFallbacksHolder` implements that choice (system hit, forced fallback, fallback
disallowed, fallback missing) and records `provided_deps` so a subproject can
`meson.override_dependency()` a name ([`dependencyfallbacks.py`][dep-fallbacks]). `Resolver`
supplies the sources — every `subprojects/*.wrap` plus every bare directory there, with
`MESON_PACKAGE_CACHE_DIR` or `subprojects/packagecache` for downloads ([`wrap.py`][wrap-py]).

Verification is the weak point: a wrap file's SHA-256 is stored next to the checkout in
`.meson-subproject-wrap-hash.txt`, and a mismatch only warns — "Subproject {name}'s revision
may be out of date; its wrap file has changed since it was first configured"
([`wrap.py`][wrap-py]). The subproject's sources are then ordinary sources to Ninja, so bumping
a wrap in place can leave stale objects whose rebuild decision belongs to timestamps.

### 1. Task model & scheduling

The model is **applicative** in [concepts.md][concepts] terms: every edge is enumerated while
`meson.build` is interpreted, so the emitted graph is a static DAG. Meson never schedules — no
queue, no ready set. It contributes granularity and throttles: one edge per object file (or per
_unity_ block, `unity_size` default 4), one link edge per target, and pools to cap concurrency —
links in `link_pool` at depth `backend_max_links`, terminal edges in `console` at depth 1.

### 2. Rebuilding & correctness

`Meson + Ninja` lands in **topological × verifying traces**, the cell [concepts.md][concepts]
assigns to `Ninja`, with one footnote: the "trace" holds no hashes.

Ninja's trace is `(mtime, dependency list)` per edge: an edge is dirty when an input is newer
than an output, or when a dependency recorded in `.ninja_deps` changed. `restat = 1` refines
it — after running, Ninja re-checks output mtimes and, if unchanged, does not propagate
dirtiness downstream, a _mechanical_ early cutoff. With no result hash, a content change
reverted with an older timestamp is invisible. Regeneration stacks a second mtime check on top:
`build.ninja` is dirty when any `meson.build` or `coredata.dat` is newer. A failed configure
leaves the previous `build.ninja` intact, and the 1.12 notes add `CACHEDIR.TAG` on setup _and_
regenerate — an admission that the build directory is a cache with no eviction policy of its
own ([notes][notes112]).

### 3. Dependency discovery

Three mechanisms, in increasing lateness:

1. **Declared** — `sources`, `dependencies`, `link_with`, `depends`, `include_directories`
   resolve at generate time into explicit edges.
2. **Compiler-reported** — headers arrive as a `depfile` (`deps = gcc`/`msvc`), or, for MSVC, as
   a `depscan.py` JSON description of C++ module imports/exports in P1689R5 format that
   `depaccumulate.py` folds into a dyndep file.
3. **Scanned then applied** — Fortran module order and C++ modules use Ninja's `dyndep`: Meson
   emits a `depscan`/`depaccumulate` edge whose output is the missing information, and Ninja
   loads it _before_ the affected edges:

> "Use the new Ninja feature for scanning dependencies during build, rather than up front.
> Remove this and all old scanning code once Ninja minimum version is bumped to 1.10."
>
> — [`mesonbuild/backend/ninjabackend.py`][ninja-backend]

The superseded path is instructive: `_scan_fortran_file_deps` regex-scans sources for
`use`/`submodule`/`include` and adds _order-only_ deps, plus a `FORTRAN_DEP_HACK` rule citing a
Ninja mailing-list thread and a GCC bug ([`ninjabackend.py`][ninja-backend]) — discovery by
heuristic text scan, exactly what dyndep replaces. There is no strictness layer: nothing checks
that a declared dependency is used.

### 4. Store & caching

There is **no build-level store**: no action cache, no content-addressed outputs, no remote
cache. The build directory is the store; Ninja's log and deps files are the only persistent build
information. What Meson owns is _compiler-cache plumbing_: ccache, sccache and BuildCache are
detected at configure time and prepended to the compiler command
([`Feature-autodetection.md`][autodetect]). That is a cache _below_ task granularity — it can
skip a compiler invocation, never a link, a `custom_target`, a configure step or a subproject.

### 5. Hermeticity & provenance

Meson has a **logical** sandbox and no process sandbox. The logical one is subproject path
ownership: `include_directories` reaching into another subproject is rejected with
`include_directories sandbox violation!` ([`interpreter.py`][interpreter]). It is a warning, it
constrains paths rather than syscalls, and it isolates neither environment, network nor
filesystem during an action — so no provenance story follows: no action keys, no attestations.
The nearest claims are `meson dist`/`distcheck` and the timestamp-shaping helpers
(`scripts/vcstagger.py`, `scripts/reprotest.py`).

### 6. Distribution

Absent: no remote execution client, no scheduler daemon, no way to send an edge to another
machine — parallelism is a local `-j`, capped per pool. The only distribution-adjacent machinery
is _dependency fetching_: `Resolver` downloads wraps over `https`/`sftp` and applies patches from
`packagefiles/` ([`wrap.py`][wrap-py]).

### 7. Sparkles relevance

For `sparkles:build-primitives.task`, the borrowable idea is the **regeneration edge**, not the
generator: make the description a node in its own graph (manifest as output, definition files as
inputs, atomic replace so a failed regenerate cannot corrupt the running build). A task DAG can
own its definition files without a second scheduler — provided `get_regen_filelist` stays an
explicit, enumerable set and the timestamp comparison carries a clock-skew guard.

The _introspection_ split transfers too: a private pickled model plus a stable JSON projection
that tools consume by name — the shape of a `dub describe`-style interface. What should **not**
be borrowed: `mtime` as the sole dirtiness signal (see [Ninja][ninja]), subproject verification
by warning, and the absence of any action-level cache — a hash-keyed task cache is precisely the
capability [concepts.md][concepts] calls a rebuilder.

## Strengths

- **One graph, one executor.** Definition and task edges share `build.ninja`, so a changed
  `meson.build` re-enters the normal scheduler; atomic replace keeps Ninja's caches consistent.
- **A published model.** `meson-info/intro-*.json` gives IDEs, `meson compile` and third-party
  tools a versioned interface without re-implementing the interpreter.
- **Late-bound edges where needed.** `dyndep` gives C++ modules and Fortran a correct graph
  without an up-front text scan, and the superseded path carries a removal condition.
- **Dependency resolution that stays local.** `dependency(..., fallback:)` makes "system package
  or bundled subproject" one expression with one interface.

## Weaknesses

- **`mtime`, with no hash anywhere.** Reverted content, `touch` and coarse timestamp resolution
  translate into wrong or wasted work; `restat` covers only the timestamp-preserving case.
- **No action cache, no remote execution.** The only cache is a compiler cache Meson merely
  wires up — nothing like [Bazel][bazel]'s action cache or a CAS.
- **No hermeticity.** Commands run with the ambient environment, network and filesystem; the
  "sandbox" is a path-ownership check on `include_directories`.
- **Subproject trust is advisory.** The wrap hash warns instead of failing, and a changed
  subproject rebuilds only if its files' mtimes say so.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                               | Trade-off                                                                                                       |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Generate `build.ninja` instead of scheduling in-process | Ninja is small, fast and portable; Meson stays a configuration program with no daemon                   | Every execution feature Meson lacks is one the backend cannot express; dirtiness policy is fixed by Ninja       |
| Model regeneration as a `generator = 1` edge            | One scheduler; no separate "did the build files change" pass; `ninja` alone suffices after setup        | Regeneration correctness rests on mtimes, and a broken generator edge stalls every edge behind it               |
| Publish `meson-info/intro-*.json` as the tool interface | Consumers get a documented projection; `meson compile` need not know the backend                        | Two representations of one model to keep in sync, and introspection lags what the interpreter can do            |
| Subprojects interpreted inline into the parent graph    | No process or graph boundary, so cross-subproject linking is free and dependency interchange is a value | No isolation, no per-subproject cache key; a subproject edit is just a source edit as far as rebuilds go        |
| `dependency()` with `fallback:` as the resolution order | "System package or vendored copy" is one expression with one interface                                  | The choice is recorded at configure time in `coredata`, so switching forms reconfigures rather than rebuilds    |
| Warn (not fail) on a changed wrap hash                  | Bumping a wrap in place during development must not brick the build directory                           | A silently stale checkout is possible, and nothing downstream can distinguish it from an intentional local edit |

## Sources

- Meson, clone at `$REPOS/build-systems-research/src/meson`, commit
  `27f69b22e5fe403d3ec5788216adaa85046d0e8f` (2026-10-30). Read in full or in part: `README.md`,
  `COPYING`, `mesonbuild/{coredata,msetup,mintro,mcompile,mtest,build,depfile}.py`,
  `mesonbuild/backend/{backends,ninjabackend,nonebackend}.py`, `mesonbuild/wrap/{wrap,__init__}.py`,
  `mesonbuild/interpreter/{interpreter,dependencyfallbacks}.py`, `mesonbuild/scripts/{regen_checker,
depscan,depaccumulate}.py`, `docs/markdown/{Running-Meson,Design-rationale,Dependencies,
Feature-autodetection,Release-notes-for-1.12.0}.md`.
- Classification vocabulary: [Build Systems: Concepts & Vocabulary][concepts] (JFP 2020 spine).
- Sibling pages: [Ninja][ninja] for the executor across the boundary, [GN][gn] for the same split
  from a different DSL, [Bazel][bazel] for the caching/remote-execution counter-example.
- Workspace-side treatment: [Meson (monorepo-tooling)][mono-meson],
  [Monorepo & Workspace Concepts][mono-concepts].

<!-- References -->

[repo]: https://github.com/mesonbuild/meson
[docs]: https://mesonbuild.com/
[readme]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/README.md
[copying]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/COPYING
[coredata]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/coredata.py
[msetup]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/msetup.py
[mintro]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/mintro.py
[mcompile]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/mcompile.py
[build-py]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/build.py
[depfile]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/depfile.py
[backends-py]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/backend/backends.py
[ninja-backend]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/backend/ninjabackend.py
[none-backend]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/backend/nonebackend.py
[wrap-py]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/wrap/wrap.py
[interpreter]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/interpreter/interpreter.py
[dep-fallbacks]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/mesonbuild/interpreter/dependencyfallbacks.py
[running-meson]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Running-Meson.md
[rationale]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Design-rationale.md
[deps-doc]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Dependencies.md
[autodetect]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Feature-autodetection.md
[notes112]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Release-notes-for-1.12.0.md
[concepts]: ./concepts.md
[ninja]: ./ninja.md
[gn]: ./gn.md
[bazel]: ./bazel.md
[mono-meson]: ../monorepo-tooling/meson/
[mono-concepts]: ../monorepo-tooling/concepts.md
