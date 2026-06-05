# tup (Minimalist)

Mike Shal's file-based build system that takes _"a list of file changes and a
directed acyclic graph (DAG)"_ and processes only the affected slice of the
graph — capturing each command's real reads and writes at runtime (via FUSE /
`LD_PRELOAD` / a syscall sandbox) so the dependency graph is **discovered, not
declared** — and which the accompanying paper proves can update in time
_logarithmic_ in the number of changes rather than linear in project size.

| Field           | Value                                                                                                                                                                                                                                            |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Language        | C (90.8% of the repo); a small Lua interpreter is vendored for `run`-scripts and Lua Tupfiles                                                                                                                                                    |
| License         | GPL-2.0                                                                                                                                                                                                                                          |
| Repository      | [gittup/tup][repo] (canonical: [gittup.org][home])                                                                                                                                                                                               |
| Documentation   | [tup manual][manual] · [tup(1) manpage][manpage] · [Build System Rules and Algorithms (paper)][paper]                                                                                                                                            |
| Category        | Minimalist / Research                                                                                                                                                                                                                            |
| Workspace model | **None in the package-manager sense.** A "project" is one directory tree rooted at a `.tup` database; `Tupfile`s per directory feed one global DAG; `<group>`s and `{bin}`s give cross-directory edges; **variants** give out-of-tree build dirs |
| First released  | First public commits **December 2009**; the design paper is dated **2009**                                                                                                                                                                       |
| Latest release  | `v0.8` (tagged **March 31, 2024**); previous line `v0.7.11` (**May 2021**)                                                                                                                                                                       |

> **Latest release:** `v0.8` (March 31, 2024) is the current tag; the repository
> remains actively maintained (last pushed March 2026, ~1.3k stars). `v0.8`'s
> headline change was replacing the FUSE-overlay variant mechanism with a path
> -rewriting scheme so [**explicit variants**](#workspace-declaration--topology)
> work on platforms without FUSE (Windows) and play nicely with debuggers
> ([Explicit Variants][variants]). tup is a single C binary (`© 2008–2024 Mike
Shal`); there is no separate package registry — it is a **build** tool, not a
> dependency manager, which colors every dimension below.

---

## Overview

### What it solves

tup answers the same question as [Make][make] — _which derived files are stale,
and what command rebuilds them?_ — but rejects Make's core scaling assumption.
A Make build, to decide what to do, must `stat()` **every** file in the tree and
re-read **every** rule: its cost is `O(n)` in the size of the project, paid on
every invocation even for a one-character edit. The manual's companion paper
([_Build System Rules and Algorithms_][paper], Shal 2009) calls this an **alpha**
build system and shows it cannot scale:

> _"the `timestamp()` function is called for every file in the build tree … For
> thousands or millions of files it can no longer be considered an insignificant
> amount of time to read all of those directory entries."_

tup is a **beta** build system: it takes _as input_ the **list of files that
changed** (from a filesystem scan, or for free from its inotify `monitor`), and
walks **only the partial DAG reachable from those changes**. For the common case
of editing a handful of files, _"we can assume that the input file list is a
constant `O(1)` size with respect to the project size,"_ so an update touches
work proportional to the change, not to the repository. The paper's central
claim is that this partial DAG is **still correct** — every node that must be
visited is visited — and that tup handles file additions and deletions in
**`O(log n)`** time, _"optimal"_ in at least one case ([home][home]).

Three rules the paper demands of any correct build system — and which frame the
whole design — are:

1. **Scalability** — work is _"proportionate to the changes required."_
2. **Correctness** — undoing a change returns the tree to its previous state.
3. **Usability** — _"there should only be one command to update the system."_

That single command is `tup`.

### Design philosophy

tup has **no domain-specific knowledge** — it is not a C build system, not a JS
build system, just a DAG executor. From the [manual][manual]:

> _"Tup has no domain specific knowledge. You must tell tup how to build your
> program, such as by saying that all .c files are converted to .o files by using
> gcc. This is done by writing one or more Tupfiles."_

The defining design choice is the **direction of the dependency arrows**, stated
(tongue firmly in cheek) on the [home page][home]:

> _"In a typical build system, the dependency arrows go down … In tup, the arrows
> go up. This is obviously true because it rhymes."_

Concretely: a conventional build asks _"to build this target, what inputs do I
need?"_ and recurses downward. tup instead records, for each command it ran,
_"these are the files it actually read and wrote,"_ and propagates **upward** from
a changed input to the commands that consumed it. Because the edges are observed
empirically rather than declared, the graph is always exactly right — there are no
missing `#include` edges, no forgotten prerequisites, the classic _"Recursive Make
Considered Harmful"_ failure mode. tup _enforces_ this: a command that reads a
generated file it did not declare as an input, or writes a file it did not declare
as an output, is a hard **error**, not a silent stale-graph bug.

Within this survey tup is the **minimalist / research** data point that takes
correctness-by-observation to its logical end, a sibling in spirit to djb/Pennarun
[redo][redo] (which discovers dependencies _dynamically at runtime_ too, but by
explicit `redo-ifchange` calls rather than syscall interception) and a sharp
contrast to the heavyweight hermetic engines [Bazel][bazel] / [Buck2][buck2]
(which achieve correctness by _declaring and sandboxing_ everything up front). For
the `dub` framing see the [D landscape][d-landscape] note.

---

## How it works

### The tup hierarchy and the `.tup` database

A tup project is the directory tree rooted where `tup init` (or an empty
`Tupfile.ini`) creates a **`.tup` directory**. Everything below that root is the
**"tup hierarchy."** The `.tup` directory holds an **SQLite** database that
persists the entire DAG — file nodes, command nodes, the edges between them, and
the parsed state of every `Tupfile` — so that successive runs never re-derive what
hasn't changed. From the [manual][manual]: tup uses _"its own dynamic database,
which is maintained in the `.tup` directory located at the root of the project."_

`tup` can be invoked from **anywhere** inside the hierarchy and always updates the
whole graph (or just the requested outputs); it walks up to find the `.tup`
directory. If several `Tupfile.ini` files exist on the path, _"the one highest up
the tree will be chosen,"_ pinning the root unambiguously.

### Tupfiles: the `:`-rule pipeline

You describe build steps with `:`-rules in a `Tupfile`. The grammar is a small
pipeline DSL ([manual][manual]):

```bash
# : [foreach] [inputs] [ | order-only-inputs ] |> command |> [outputs] [ | extra-outputs ] [<group>] [{bin}]
: foreach *.c |> gcc -c %f -o %o |> %B.o
```

- `foreach` runs the command **once per input**; without it, all inputs feed a
  single command (e.g. the final link).
- `%f` expands to the input filename(s) with path, `%o` to the output(s), `%B` to
  the basename with directory **and** extension stripped (`src/foo.c` → `foo`),
  `%e` to the extension in a `foreach` rule.
- `^ CC %f^` after `|>` is a **pretty-print** label, so the terminal shows
  `CC foo.c` instead of the full `gcc` line.

Three kinds of variable cover three scopes:

```bash
CFLAGS = -Wall                       # $-variable: substituted immediately
!cc = |> gcc -c %f -o %o |>          # !-macro: a reusable rule template
&libdir = src/lib                    # &-variable: path resolved relative to use site
: foreach *.c |> !cc |> %B.o         # invoking the macro
```

A `$-variable` whose name starts with `CONFIG_` is automatically promoted to the
`@(...)` config-variable of the same name (minus the prefix), tying Tupfiles to
the `tup.config` mechanism used by variants (below).

### Capturing dependencies: syscall interception, not declaration

The pivotal mechanism is that **tup observes what each command actually does**
rather than trusting what you declared. When tup runs a command it intercepts the
command's file accesses and checks them against the declared inputs/outputs
([manual][manual]):

> _"The command is allowed to read from any file specified as an input or
> order-only input, as well as any other file in the tup hierarchy that is not the
> output of another command."_

and enforces, on completion:

> _"Any files opened for reading that were generated from another command but not
> specified as inputs are reported as errors. Similarly, any files opened for
> writing that are not specified as outputs are reported as errors."_

The interception substrate is platform-dependent — tup ships three bootstrap
paths (`bootstrap.sh`, `bootstrap-ldpreload.sh`, `bootstrap-nofuse.sh`):

| Platform / mode       | Mechanism                                                                                                             |
| --------------------- | --------------------------------------------------------------------------------------------------------------------- |
| Linux/macOS (default) | A **FUSE** filesystem proxies the working directory; every `open`/`read`/`write` is recorded as an edge               |
| Linux without FUSE    | An `LD_PRELOAD` shim wrapping libc file syscalls                                                                      |
| `updater.full_deps=1` | Track reads/writes **outside** the tup hierarchy too — needs a **`chroot`** (suid-root binary) or **user namespaces** |

> [!NOTE]
> _"In Linux and OSX, using full dependencies requires that the tup binary is suid
> as root so that it can run sub-processes in a chroot environment. Alternatively
> on Linux, if your kernel supports user namespaces, then you don't need to make
> the binary suid."_ By default (`updater.full_deps=0`) tup only tracks
> dependencies **within** the hierarchy — system headers like `/usr/include/...`
> are not graphed unless full-deps is on.

Because the captured `#include` edges are real, an edit to a header automatically,
and minimally, rebuilds exactly the objects that included it — with no
`gcc -M`/`makedepend` pre-pass (the `O(n)` _"alpha"_ tax tup exists to avoid).

### Updating: scan (or `monitor`) → partial DAG → execute

```bash
tup                 # update everything reachable from changed files
tup path/to/out.o   # partial: update only the requested output(s)
tup monitor         # inotify watcher: feeds the change-list with zero scan cost
tup -j8             # cap parallelism at 8 (default = number of CPUs)
```

By default tup _"determines [the changed file list] by scanning the filesystem and
checking modification times."_ The `monitor` (Linux inotify; macOS FSEvents)
removes even that: _"with the monitor running, `tup` does not need to do the
initial scan, and can start constructing the build graph immediately."_ The
manual notes the scan time it eliminates _"is approximately equal to the time you
would save by running the monitor"_ — i.e. the scan is the residual `O(n)` cost,
and the monitor makes the whole pipeline beta/sublinear end-to-end.

Given the change-list, tup loads the affected sub-DAG from SQLite, topologically
orders the command nodes, and runs independent legs concurrently up to `-jN`. A
partial invocation (`tup foo.o`) can be run from anywhere and _"will always update
the requested output."_

---

## Workspace Declaration & Topology

**There is no multi-package "workspace" concept** — tup builds a single project
tree, not a graph of independently-versioned packages with their own manifests.
The analog of "topology" here is how one project's many directories compose into
one DAG:

- **Discovery is implicit and recursive.** The `.tup` root anchors the hierarchy;
  every `Tupfile` found beneath it contributes rules. There is no `members = [...]`
  array (cf. [Cargo][cargo]) and no glob list (cf. [pnpm][pnpm]) — the directory
  tree _is_ the membership list. Subdirectories with no `Tupfile` simply
  contribute no rules.
- **`Tuprules.tup` gives hierarchical inheritance.** Shared variables/macros are
  factored into `Tuprules.tup` files: _"The first `Tuprules.tup` file is read at
  the top of the tup hierarchy, followed by the next subdirectory, and so on
  through to the `Tuprules.tup` file in the current directory."_ This is the
  closest thing to workspace-level shared config — root-down cascade, nearest wins
  — comparable to a root `Tuprules` defining `CFLAGS` once for every member.
- **`$(TUP_CWD)`** is set to the path of the directory being parsed relative to
  the current `Tupfile`, so inherited rules can resolve sibling paths correctly
  regardless of where they are `include`d.

**Variants** are tup's out-of-tree-build feature and the nearest neighbor to a
"workspace declaration." You declare one **`tup.config`** per build variant; in
`v0.8` each variant materializes as its own build directory holding the outputs,
keeping the source tree clean and letting multiple configurations coexist:

```bash
mkdir build-default
touch build-default/tup.config       # empty config = default build
tup                                  # updates ALL variants at once
tup build-default                    # ...or just one variant
```

```ini
# build-debug/tup.config
CONFIG_DEBUG=y
```

```bash
# Tupfile — branch on the variant's config
ifeq (@(DEBUG),y)
CFLAGS += -g -O0
endif
```

`@(DEBUG)` reads the `CONFIG_DEBUG` value; `$(TUP_VARIANTDIR)` points at the
variant's mirror of the current directory. Editing one shared source _"will cause
it to be re-compiled for each variant,"_ and deleting a variant is just removing
its directory. This is a build-matrix mechanism (debug/release/cross), **not** a
local-package linking mechanism.

## Dependency Handling & Isolation

This dimension largely **does not apply** in the package-manager sense, and saying
so is itself a finding for the `dub` comparison: tup has **no dependency
resolver, no lockfile, no registry, no version solving, and no hoisting/symlink/
virtual-store machinery**. It does not fetch, version, or deduplicate third-party
packages — that is out of scope by design. What tup _does_ manage is the
**file-level** dependency graph _inside_ one project:

- **Edges are content/observation-based.** A rebuild fires because a file a
  command provably read changed — not because a declared version constraint moved.
  With `db.sync` on, the SQLite DAG is _"always consistent"_ across crashes.
- **Cross-directory edges** are first-class (unlike recursive Make), via two
  constructs:
  - **`{bin}`** collects outputs into a named bucket for reuse: _"Outputs can be
    grouped into a bin using the `{bin}` syntax. A later rule can use `{bin}` as an
    input to use all of the files in that bin."_
  - **`<group>`** provides **order-only** dependencies _across directories_ —
    tup's mechanism for "build library A before app B that links it":

    ```bash
    # ./submodules/sm1/Tupfile  — publish objects into a directory-scoped group
    : foo.c |> gcc -c %f -o %o |> %B.o ../<submodgroup>

    # ./project/Tupfile  — consume the group as an order-only input
    : baz.c | ../submodules/<submodgroup> |> gcc -c %f -o %o |> %B.o
    ```

    Per the manual: _"Groups allow for order-only dependencies between folders.
    Note that groups are directory specific, however, so when referring to a group
    you must specify the path."_ Listing `<submodgroup>` as an order-only input
    _"will build the submodules before attempting to build the entire project."_

So tup's notion of "isolation" is the **chroot/user-namespace full-deps sandbox**
that bounds what a command may touch — a _correctness_ guarantee, not a
node_modules-style dependency-isolation tree.

## Task Orchestration & Scheduling

This is tup's core competency and where it outshines its category peers.

- **It is a real task DAG.** Commands are nodes; observed file reads/writes are
  edges. tup _"takes as input a list of file changes and a directed acyclic graph
  (DAG), then processes the DAG to execute the appropriate commands required to
  update dependent files."_
- **Change detection is the input, not a phase.** Unlike content-hash-and-compare
  orchestrators ([Turborepo][turborepo], [Nx][nx], [Bazel][bazel]) that hash
  inputs to decide what is stale, tup is _driven by_ the change-list (from scan or
  inotify `monitor`) and only loads the reachable sub-DAG from SQLite — the
  **beta** algorithm. Adds/deletes are `O(log n)`; an edit touches `O(changes)`
  work, not `O(project)`.
- **Concurrent execution** respects the DAG: `tup -jN` _"will run up to N jobs in
  parallel, subject to the constraints of the DAG,"_ defaulting to the CPU count.
- **Partial / sliced builds** are native: `tup out1 out2 ...` updates only those
  outputs and their prerequisites; with no args the whole project updates. This is
  the equivalent of a `--filter`/target slice, expressed as **output paths**
  rather than package names.
- **`tup generate`** flattens the DAG into a standalone shell script —
  `tup generate build.sh` — for CI environments where FUSE/namespaces are
  unavailable, trading incrementality for portability.
- **`tup todo`** prints the next steps the updater _would_ run; **`tup graph`**
  emits Graphviz; **`tup refactor`** parses all Tupfiles and validates them
  _without_ executing — a dry-run lint of the rule structure.

## Caching & Remote Execution

**None.** tup has **no build cache** (local or remote) and **no remote-execution /
REAPI backend**. This is the sharpest line between tup and the cache-centric tools
in this survey ([Turborepo][turborepo], [Nx][nx], [Bazel][bazel], [Buck2][buck2],
and the REAPI backends [Buildbarn][buildbarn] / [BuildBuddy][buildbuddy] /
[NativeLink][nativelink]):

- tup's optimization is **avoiding work**, not **reusing prior work**. It never
  rebuilds an output whose inputs are unchanged because the DAG says so — but if an
  input _did_ change, it re-runs the command locally; there is no content-addressed
  store keyed on `(command, inputs)` to fetch a prior result from, and no way for a
  second machine or a CI runner to import a colleague's compiled objects.
- There is no notion of a hermetic action whose output is cacheable across hosts;
  the full-deps sandbox bounds inputs for _correctness_, not for cache-key
  derivation.
- The closest thing to cross-machine reuse is `tup generate`'s standalone script,
  which is the _opposite_ trade-off — a full rebuild with no graph at all.

For the `dub` proposal this places tup firmly on the "minimal, single-host,
incremental-only" end of the spectrum: excellent local edit/build latency, zero
distributed-cache story.

## CLI / UX Ergonomics

tup's UX embodies its third rule — _"there should only be one command to update
the system."_ The command boundary is:

- **Global trigger:** bare `tup` (from anywhere in the hierarchy) updates
  everything affected — including **all variants** at once. There is no
  `--workspace`/`--all` flag because "all" is the default.
- **Targeted slice by output path:** `tup path/to/foo.o` (or `tup build-debug` for
  one variant) narrows to specific outputs/variants. The selector is a **file/dir
  path**, not a `-p package` name or `--filter pattern` — fitting a tool with no
  package identity.
- **`-jN`** caps parallelism; default is the CPU count.
- A small, verb-named subcommand set rather than a flag soup:

  | Command           | Purpose                                            |
  | ----------------- | -------------------------------------------------- |
  | `tup init`        | Create the `.tup` database at the project root     |
  | `tup` / `tup upd` | Update outputs from the DAG (the one command)      |
  | `tup monitor`     | Start the inotify/FSEvents watcher (skip the scan) |
  | `tup variant`     | Create build variants from `tup.config` files      |
  | `tup generate`    | Emit a standalone build shell script for CI        |
  | `tup graph`       | Output the DAG in Graphviz (`--dirs`, `--ghosts`)  |
  | `tup todo`        | Show what the next update would do                 |
  | `tup refactor`    | Parse/validate Tupfiles without executing          |
  | `tup compiledb`   | Emit `compile_commands.json` for editors/clangd    |
  | `tup options`     | Show configuration                                 |

- **`run ./script args`** inside a `Tupfile` lets an external script _emit_
  `:`-rules on stdout (_"Tup will then treat this as if a Tupfile was written"_),
  for generated rules — with the guardrail that _"the script cannot `readdir()` on
  any directory other than the directory of the Tupfile"_ (keeps generation
  deterministic and graph-safe).

The ergonomic philosophy is **stay out of the way**: _"stay focused on your
project rather than on your build system"_ ([home][home]).

---

## Strengths

- **Provably scalable incrementality.** The beta-algorithm `O(changes)` / `O(log
n)` updates make edit/compile cycles independent of repo size — the whole reason
  tup exists, and demonstrated at scale ([building mozilla-central][mozilla]).
- **Correct-by-construction graph.** Syscall-level capture of real reads/writes
  means no missing `#include` edges and no stale-rebuild class of bugs; undeclared
  access is a hard error, not silent corruption.
- **Genuinely cross-directory.** `<group>` / `{bin}` give first-class inter-folder
  ordering, sidestepping _"Recursive Make Considered Harmful"_ entirely.
- **Tiny, fast, dependency-light.** One small C binary; near-instant updates;
  `monitor` removes even the scan cost.
- **Clean out-of-tree variants** keep debug/release/cross builds isolated from a
  pristine source tree, all rebuilt by one `tup`.
- **Editor-friendly** via `tup compiledb` (`compile_commands.json`) and
  `tup graph`.

## Weaknesses

- **Not a package/dependency manager.** No registry, resolver, lockfile, version
  solving, or third-party fetching — orthogonal to what `dub`/[Cargo][cargo]/
  [npm][npm] do. You bring your own dependency story.
- **No caching, local or remote; no REAPI.** Cannot reuse another machine's or a
  prior CI run's build outputs — a hard ceiling versus [Bazel][bazel]/[Buck2][buck2]
  - [Buildbarn][buildbarn]/[NativeLink][nativelink].
- **No workspace/multi-package model.** One project tree, one `.tup` root; it does
  not orchestrate independently-versioned sub-packages the way a monorepo package
  manager does.
- **Platform/permission friction.** Full external-dependency tracking needs FUSE,
  a suid-root binary, or user namespaces — awkward in locked-down CI; `tup
generate` is the fallback but discards incrementality.
- **Manual, low-level rules.** No language plugins or auto-detected toolchains; you
  hand-write every `gcc`/link rule (or generate them with `run`).
- **Niche ecosystem.** Small community relative to Make/CMake/Bazel; few
  integrations.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                              | Trade-off                                                                                         |
| ----------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Beta algorithm: consume a change-list, walk only the partial DAG  | `O(changes)`/`O(log n)` updates independent of project size — the paper's whole thesis | Needs a persistent SQLite DAG and (ideally) a `monitor`; a bare `tup` still pays an `O(n)` scan   |
| Discover dependencies by intercepting real file accesses          | Graph is always correct — no missing `#include`s, no manual prerequisite upkeep        | Requires FUSE / `LD_PRELOAD` / chroot / user-namespaces; harder to run in restricted environments |
| Undeclared read/write of a generated file is a hard error         | Forces the declared graph to match reality; eliminates the stale-graph bug class       | Stricter authoring; tools that touch surprise files must be declared or sandboxed via full-deps   |
| No build cache, local or remote; no REAPI                         | Keeps the tool tiny and single-host; "avoid work" rather than "reuse work"             | No cross-machine/CI artifact reuse; loses to cache-centric engines on cold/distributed builds     |
| No dependency manager (no registry/lockfile/resolver)             | Stays a pure DAG executor with one job, done well                                      | Must be paired with an external package manager; no version/monorepo-package story                |
| `<group>` / `{bin}` for cross-directory edges (vs recursive Make) | First-class inter-folder ordering in one global DAG; no lost edges                     | Groups are path-specific and order-only; coarser than per-file edges within a directory           |
| Out-of-tree **variants** via `tup.config` + `@(VAR)`              | Clean debug/release/cross matrix from a pristine source tree, all built by one `tup`   | A build-matrix tool, not local-package linking; shared sources recompile once per variant         |
| One command (`tup`) does everything                               | Usability rule: minimal cognitive surface; run it from anywhere                        | Few knobs; advanced selection is by output **path**, not package name or `--filter`               |

---

## Sources

- [gittup/tup — GitHub repository (README, GPL-2.0, C, tags `v0.8`/`v0.7.x`)][repo]
- [gittup.org — home page ("arrows go up", "it is very fast", Mike Shal
  © 2008–2024)][home]
- [tup manual — Tupfiles, `:`-rules, `Tuprules.tup`, `<group>`/`{bin}`, `.tup`
  SQLite db, full-deps chroot, variants, `tup generate`, `-jN`][manual]
- [tup(1) manpage — subcommand reference, scan-vs-monitor][manpage]
- [Explicit Variants — the `v0.8` non-FUSE variant mechanism, `$(TUP_VARIANTDIR)`][variants]
- [Mike Shal, _Build System Rules and Algorithms_ (2009) — alpha vs beta build
  systems, `O(n)` vs `O(log n)`, the three rules, the "optimal" claim][paper]
- [_Build System Rules and Algorithms_ — Embedded Artistry summary of the
  alpha/beta distinction and three rules][ea]
- [Building mozilla-central with tup (gittup blog, 2013) — scale demonstration][mozilla]
- Sibling tools: [redo][redo] · [Make][make] · [Cargo][cargo] · [npm][npm] ·
  [pnpm][pnpm] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] ·
  [Buck2][buck2] · [Buildbarn][buildbarn] · [BuildBuddy][buildbuddy] ·
  [NativeLink][nativelink]; `dub` context: [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/gittup/tup
[home]: https://gittup.org/tup/
[manual]: https://gittup.org/tup/manual.html
[manpage]: https://man.archlinux.org/man/tup.1.en
[variants]: https://gittup.org/tup/ex_explicit_variants.html
[paper]: https://gittup.org/tup/build_system_rules_and_algorithms.pdf
[ea]: https://embeddedartistry.com/blog/2017/04/17/build-system-rules-and-algorithms/
[mozilla]: https://gittup.org/blog/2013/08/4-building-mozilla-central-with-tup/
[redo]: ../redo/
[make]: ../make/
[cargo]: ../cargo/
[npm]: ../npm/
[pnpm]: ../pnpm/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
