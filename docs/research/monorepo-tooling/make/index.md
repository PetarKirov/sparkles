# Make (Polyglot)

The original Unix dependency engine: a tab-sensitive DSL in which a _target_
depends on _prerequisites_ and is rebuilt when any prerequisite's
last-modification time is newer — the 1976 ancestor of every tool in this survey,
still the lowest-common-denominator polyglot task runner, but one with **no**
workspace concept, **no** package resolver, and **no** cache beyond file `mtime`.

| Field           | Value                                                                                                            |
| --------------- | ---------------------------------------------------------------------------------------------------------------- |
| Language        | C (GNU Make); the build DSL is the makefile language itself                                                      |
| License         | GPL-3.0-or-later (GNU Make); the POSIX `make` interface is a standard, not a codebase                            |
| Repository      | [github.com/mirror/make][repo] (GNU Make, the dominant implementation)                                           |
| Documentation   | [GNU Make Manual][manual] · [POSIX `make` (IEEE Std 1003.1-2024)][posix]                                         |
| Category        | Generic Task Runner                                                                                              |
| Workspace model | **None.** A "monorepo" is either one whole-project makefile or a tree of makefiles glued by **recursive `make`** |
| First released  | Stuart Feldman's original `make`, Bell Labs, **1976**; GNU Make, **1988**                                        |
| Latest release  | GNU Make **`4.4.1`** (Feb 26, 2023)                                                                              |

> **Latest release:** GNU Make `4.4.1`, published **February 26, 2023** — a
> bug-fix release over `4.4` (October 31, 2022). The `4.4` line added the `.WAIT`
> ordering target, **grouped targets** (`&:`), the `--shuffle` build-order fuzzer,
> a FIFO-based jobserver, and the `--jobserver-style` selector (see
> [Task orchestration & scheduling](#task-orchestration--scheduling)). There has
> been no `4.5` as of June 5, 2026. Source citations below are against the GNU
> Make `4.4.1` manual (`make.info`) shipped in this environment's Nix store, and
> against the POSIX standard.

---

## Overview

### What it solves

Make answers exactly one question, and answers it well: _given a set of files
derived from other files, which derived files are stale, and what commands
rebuild them?_ From the GNU Make manual's opening ([`make.info` § Overview][manual]):

> _"The `make` utility automatically determines which pieces of a large program
> need to be recompiled, and issues commands to recompile them. … Indeed, `make`
> is not limited to programs. You can use it to describe any task where some files
> must be updated automatically from others whenever the others change."_

That last sentence is why Make sits in the **generic task runner** family
alongside [Task][task], [just][just], and [mise][mise]: it orchestrates _commands_
keyed on _files_, with no language assumptions. The compiler can be `cc`, `dmd`,
`tsc`, `cargo`, or a shell one-liner — Make only cares that a recipe turns
prerequisites into a target. This polyglot indifference, plus near-universal
availability (`make` ships in every Unix base system and POSIX mandates it), is
why heterogeneous monorepos still reach for a top-level `Makefile` as the
common entry point even when each member has its own native build tool.

But Make's data model stops far short of a workspace tool. It has, by design:

- **No package resolver and no lockfile** — Make never fetches, version-resolves,
  hoists, or isolates dependencies. Those are the job of the language managers
  ([Cargo][cargo], [uv][uv], [pnpm][pnpm], `dub`) that a recipe _invokes_.
- **No workspace/member model** — there is no `[workspace]` block, no
  `members = [...]` glob, no project graph. A target is a filename; a "project"
  is a directory you `cd` into and run `make` again.
- **No content-addressed cache and no remote execution** — staleness is decided
  purely by comparing file `mtime`s. There is no artifact store, no REAPI client,
  no shared team cache (see [Caching & remote execution](#caching--remote-execution)).

In this survey Make is the **baseline data point**: the tool every newer entrant
defines itself _against_. [Task][task] is "Make's two good ideas in declarative
YAML with content hashing"; [Bazel][bazel] is "Make with hermetic sandboxed
actions and a remote CAS"; [Ninja][ninja] is "Make's executor without the DSL";
[redo][redo] and [tup][tup] are "Make's dependency model rebuilt for correctness
and speed." Understanding what Make _doesn't_ do is the frame for the entire
catalog.

### Design philosophy

Three commitments, all visible in the manual and unchanged since 1976, shape
everything:

1. **Files are the unit; `mtime` is the truth.** A target is a path on disk; a
   target is out of date when a prerequisite is newer ([`make.info` §
   Rules][manual]):

   > _"if any prerequisite is newer than the target, then the target is
   > considered out-of-date and must be rebuilt."_

   This is the entire change-detection model: no content hashing, no input
   capture, no command-line tracking. It is cheap (one `stat` per file) and
   language-agnostic, but it is also the source of every Make correctness pitfall
   — an edit that doesn't bump `mtime`, a clock skew, a changed compiler flag, an
   undeclared header all produce a wrong answer.

2. **Declarative dependency, imperative recipe.** The _what-depends-on-what_ is a
   declarative DAG of `target: prerequisites` rules; the _how-to-build_ is an
   imperative block of shell commands (the **recipe**). Make's value is the graph
   walk; the recipe is opaque shell it does not understand. This split is
   inherited by every successor: [Task][task]'s `deps` vs `cmds`, [Ninja][ninja]'s
   `build` edges vs `rule` commands, even [Bazel][bazel]'s rule graph vs action
   commands.

3. **Composition by re-invocation, not by a project model.** Make's only answer
   to "many sub-projects" is to run _itself_ as a recipe — **recursive `make`**
   ([`make.info` § Recursion][manual]):

   > _"Recursive use of `make` means using `make` as a command in a makefile.
   > This technique is useful when you want separate makefiles for various
   > subsystems that compose a larger system."_

   There is no other topology primitive. This is the design decision that makes
   Make _not_ a monorepo tool — and the one Peter Miller's famous 1997 paper
   _["Recursive Make Considered Harmful"][rmch]_ attacks head-on (see
   [Workspace declaration & topology](#workspace-declaration--topology)).

Within this survey Make is the canonical _"`mtime`-only, no-workspace, polyglot
ancestor"_ entry: compare it against its declarative descendant [Task][task]
(content fingerprints, YAML, `includes` namespaces), the executor-only
[Ninja][ninja] (no DSL, generated by [Meson][meson]/[CMake][cmake]/[GN][gn]), and
the correctness-first redesigns [redo][redo] and [tup][tup].

---

## How it works

A makefile is a list of **rules**. Each rule names a **target**, its
**prerequisites**, and a tab-indented **recipe**:

```makefile
# Makefile
CC      := cc
CFLAGS  := -O2 -Wall

app: main.o util.o          # target: prerequisites
	$(CC) $(CFLAGS) -o $@ $^   # recipe (MUST start with a TAB)

main.o: main.c util.h       # main.o is stale if main.c or util.h is newer
	$(CC) $(CFLAGS) -c main.c

util.o: util.c util.h
	$(CC) $(CFLAGS) -c util.c

.PHONY: clean
clean:
	rm -f app *.o
```

Running `make app` (or just `make`, which builds the **first** target — the
_default goal_) makes Make:

1. **Read** the makefile, building an in-memory database of rules, variables, and
   the dependency DAG. The makefile name is found by a fixed search:
   `GNUmakefile`, then `makefile`, then `Makefile` ([`make.info` § Makefile
   Names][manual]) — there is no project-config discovery beyond this.
2. **Walk** the DAG bottom-up from the requested goal, `stat`-ing each file.
3. **Rebuild** any target whose recipe exists and whose target is missing or older
   than a prerequisite, running the recipe through `/bin/sh`.

The recipe's leading character must be a literal **tab** — the single most
infamous syntax wart in computing, preserved for backward compatibility (GNU Make
later added the `.RECIPEPREFIX` variable to override it).

### Automatic variables and pattern rules

Make's terseness comes from **automatic variables** (`$@` = target, `$^` = all
prerequisites, `$<` = first prerequisite, `$*` = pattern stem) and **pattern
rules** that generalize over filenames:

```makefile
# One rule that compiles ANY .c into a .o (% is the stem wildcard)
%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@
```

GNU Make ships a database of **implicit rules** (e.g. how to make `.o` from `.c`,
`.c` from `.y`) so a trivial `Makefile` can be empty of recipes entirely. `VPATH`
and `vpath` add search directories so prerequisites can live in sibling trees.

### Including other makefiles

The `include` directive splices another makefile into the current one
([`make.info` § Include][manual]):

> _"The `include` directive tells `make` to suspend reading the current makefile
> and read one or more other makefiles before continuing."_

```makefile
include config.mk                # textual splice; one flat namespace
include $(wildcard libs/*/rules.mk)
```

Crucially, `include` is a **textual merge into a single flat namespace**, not a
namespaced import like [Task][task]'s `includes:`. Every variable and target from
every included file lands in one global scope; name collisions silently clobber.
The environment variable `MAKEFILES` does the same thing implicitly for every
`make` invocation. This flat-merge model is what makes _non-recursive_
whole-project Make (one logical makefile assembled from `include`d fragments) the
correctness-preserving alternative to recursive `make` — at the cost of one giant
namespace.

---

## Workspace declaration & topology

**Make has no workspace, project, or member concept whatsoever** — and stating
that plainly is the central fact about it for this survey. There is no manifest
that enumerates sub-packages, no glob of members, no project graph, no metadata
per member. A directory is a "project" only by the convention that it contains a
`Makefile`. Discovery of the makefile itself is the fixed three-name search
(`GNUmakefile` / `makefile` / `Makefile`) plus the `-f`/`--file` override; nothing
scans the tree for members.

There are exactly two ways to express a multi-directory codebase, and the choice
between them is the most consequential decision a Make-based monorepo makes:

### 1. Recursive `make` (the traditional topology)

A top-level `Makefile` invokes `make` again in each sub-directory, almost always
through the special `$(MAKE)` variable and the `-C` directory flag
([`make.info` § Recursion][manual]):

```makefile
# top-level Makefile — recursive topology
SUBDIRS := libs/core libs/util apps/cli apps/server

.PHONY: all $(SUBDIRS)
all: $(SUBDIRS)

$(SUBDIRS):
	$(MAKE) -C $@        # equivalently: cd $@ && $(MAKE)

# express an INTER-member edge by ordering the sub-makes:
apps/cli apps/server: libs/core libs/util
```

The manual mandates the `$(MAKE)` variable rather than a literal `make` so the
same binary, flags, and **jobserver** (below) propagate to children
([`make.info` § MAKE Variable][manual]):

> _"Recursive `make` commands should always use the variable `MAKE`, not the
> explicit command name `make` … If you use a special version of `make` to run the
> top-level makefile, the same special version will be executed for recursive
> invocations."_

This is the closest Make gets to a "workspace": a hand-maintained `SUBDIRS` list
and hand-written ordering edges between directories. It is **structurally the same
shape** as [Task][task]'s `includes` + `deps` glue, [Lerna][lerna]'s original
`lerna run` fan-out, and the `for member in ...; do` loops people write around
[Cargo][cargo] before discovering `--workspace`.

### 2. Whole-project (non-recursive) `make`

The alternative — argued in Peter Miller's _["Recursive Make Considered
Harmful"][rmch]_ — is to `include` every member's rule fragment into **one** logical
makefile so Make sees the **complete** DAG at once:

```makefile
# top-level Makefile — non-recursive / whole-project topology
include libs/core/module.mk
include libs/util/module.mk
include apps/cli/module.mk
include apps/server/module.mk
# now `make` has the entire cross-member graph and can build/parallelize correctly
```

Miller's thesis, verbatim from the paper:

> _"The problems with recursive make are many … the make program is being denied
> vital information necessary to build a correct dependency graph. … The solution
> is to use a single Makefile for the entire project."_

The trade-off is stark and is the heart of why Make is _not_ a monorepo tool:

> [!IMPORTANT]
> **Recursive Make builds an _incomplete_ DAG; whole-project Make builds an
> _unmaintainable flat namespace_.** Recursive `make` partitions the graph across
> invocations, so a sub-`make` cannot know that a file in _another_ subtree
> changed — it produces fast-but-wrong incremental builds (the classic "works
> after `make clean`, broken otherwise" symptom). Whole-project `make` fixes
> correctness by giving Make the entire DAG, but because `include` merges into one
> **flat global namespace**, every member must prefix its variables/targets to
> avoid collisions, and the single makefile becomes a sprawling, tightly-coupled
> artifact. **Neither option is a workspace model** — one trades correctness for
> structure, the other structure for correctness. A real workspace tool
> ([Cargo][cargo], [pnpm][pnpm], [moon][moon]) gives you both: per-member manifests
> _and_ one coherent cross-member graph.

> [!NOTE]
> There is no glob-based member discovery in either mode. `include $(wildcard
libs/*/module.mk)` can _approximate_ "find every member," but the matched files
> are still merged into one namespace, and adding a member still means the fragment
> must exist and follow the prefixing convention. Contrast [Cargo][cargo]'s
> `members = ["libs/*"]`, [pnpm][pnpm]'s `packages:` globs, or [Bazel][bazel]'s
> recursive `BUILD`-file discovery — none of which Make has.

---

## Dependency handling & isolation

This dimension **barely applies**, and the honest answer for a generic task runner
is to say so. Make does not resolve packages, has no lockfile, performs no
hoisting, builds no symlink tree, and maintains no virtual store. Its "dependency"
is a _file-level_ prerequisite edge inside one makefile, not a _package-level_
dependency between versioned components.

- **Package installation is a delegated recipe.** A member's rule shells out to
  the native manager — `cargo fetch`, `npm ci`, `uv sync`, `go mod download`,
  `dub upgrade`. Make's only contribution is to **order** these and **skip** them
  when a sentinel file (e.g. `node_modules/.stamp`) is newer than the manifest.
  The isolation model is whatever the underlying manager provides; Make adds
  nothing.

- **There is no `workspace:`-protocol equivalent.** Make has no notion of one
  member depending on a sibling member's _package_. A cross-member relationship is
  expressed as a **file or order edge** — "build `libcore.a` before linking
  `app`" — not a package edge:

  ```makefile
  apps/cli/cli: libs/core/libcore.a   # a FILE prerequisite across members
  	$(CC) -o $@ apps/cli/main.o -Llibs/core -lcore
  ```

  Whether `apps/cli` actually _links against_ `libcore.a` is the toolchain's
  concern; Make only guarantees the archive exists and is current before the link
  recipe runs. In recursive mode even that guarantee weakens to "the sub-`make`
  for `libs/core` ran first," with no file-level cross-checking.

- **Variable inheritance is the only "config inheritance."** Variables set in an
  outer makefile, and any listed in `export`, propagate to recipes and (via the
  environment and `MAKEFLAGS`) to recursive sub-`make`s. This is a lightweight
  echo of the centralized-config story [Cargo][cargo]'s `[workspace.package]`
  inheritance provides — but for **shell/Make variables**, not dependency versions.
  There is nothing like a `[workspace.dependencies]` registry to eliminate version
  drift.

> [!WARNING]
> **`mtime` staleness silently breaks across undeclared inputs.** Because Make's
> only correctness signal is file modification time, an input that is _not_ listed
> as a prerequisite (a changed `CFLAGS`, a header reached transitively, a tool
> upgrade) does **not** invalidate the target. The standard mitigation — compiler
> `-MMD` auto-dependency generation `include`d back into the makefile — patches the
> header case but not flags or tool versions. This is precisely the correctness
> ceiling that content-hashing tools ([Task][task], [Turborepo][turborepo]) and
> hermetic tools ([Bazel][bazel], [Buck2][buck2]) were built to raise.

---

## Task orchestration & scheduling

This is where Make is genuinely strong, and where its descendants inherit the most.

**The DAG.** Make compiles the requested goal plus its transitive prerequisites
into a directed acyclic graph and walks it bottom-up. Cycles are detected and
warned. A target with a recipe but no file (a **phony target**) is the idiom for
"a task, not a file" ([`make.info` § Phony Targets][manual]):

> _"A phony target is one that is not really the name of a file; rather it is just
> a name for a recipe to be executed when you make an explicit request. … to
> improve performance."_

Phony targets (`.PHONY: all test clean install`) are how Make expresses pure
tasks — the `build`/`test`/`lint` verbs that a monorepo runner needs — without a
real output file.

**Concurrency — `-j` and the jobserver.** Make parallelizes the DAG with `-j`/`--jobs`
([`make.info` § Parallel Execution][manual]):

> _"the `-j` or `--jobs` option tells `make` to execute many recipes
> simultaneously. … If the `-j` option is followed by an integer, this is the
> number of recipes to execute at once; this is called the number of `job
slots`."_

The subtle, important part for a monorepo is that parallelism must be **bounded
across recursive `make` invocations** — otherwise a recursive build with `make -j`
would spawn `N × M` jobs. GNU Make solves this with the **jobserver**: the
top-level `make` holds a pool of job tokens and shares them with sub-`make`s
through an inherited pipe ([`make.info` § POSIX Jobserver][manual]):

> _"on systems that support it, GNU `make` will create a named pipe and use that
> for the jobserver. … To access the jobserver you should open the named pipe path
> and read/write to it … `--jobserver-auth=fifo:PATH`."_

A child must acquire a token before starting a job and return it on completion, so
the _whole_ recursive tree respects a single global `-j` limit. GNU Make `4.4`
added the FIFO-based jobserver (over the older anonymous-pipe `R,W` form) and the
`--jobserver-style` selector; third-party tools ([Ninja][ninja], Rust's `cargo`,
Cargo's `jobserver` crate) can join the same pool, making Make's jobserver a
**de-facto cross-tool parallelism protocol** — a notable bit of interop the rest
of the survey lacks.

GNU Make `4.4` also added two ordering primitives:

| Primitive             | Form            | Effect                                                                                  |
| --------------------- | --------------- | --------------------------------------------------------------------------------------- |
| **`.WAIT`**           | between prereqs | Wait for everything to the left of `.WAIT` before starting anything to the right        |
| **Grouped targets**   | `a b &: c`      | One recipe invocation produces _all_ listed targets (correct under `-j`)                |
| **Order-only prereq** | `t: \| dir`     | Must exist first, but its `mtime` does **not** make `t` stale (e.g. `mkdir` of outdirs) |
| **`--shuffle`**       | CLI flag        | Randomize goal/prereq order to fuzz-test parallel-build correctness                     |

**Change detection.** As established, the _only_ change signal is `mtime`. There
is **no content hashing**, **no command-line tracking**, and — critically for a
monorepo — **no Git-aware affected-detection**. There is nothing like
[Turborepo][turborepo]'s / [Nx][nx]'s / [moon][moon]'s `--affected <ref>` that
computes "which members changed since `main`." Restricting a build to "what
changed" is whatever `mtime` happens to imply, which on a fresh `git clone` (all
files same `mtime`-ish, no outputs present) means **rebuild everything**.

> [!IMPORTANT]
> **Recursive `make` degrades the DAG; this is the orchestration cost, not just a
> topology one.** Because each sub-`make` sees only its own slice of the graph, the
> top-level `make` cannot parallelize _across_ members optimally, cannot detect
> that a leaf in one subtree invalidates a target in another, and serializes at
> directory boundaries. Miller's paper frames this as Make being "denied vital
> information" — the scheduler is only as good as the DAG it is given, and
> recursion hands it a deliberately incomplete one.

---

## Caching & remote execution

Make's "cache" is **the filesystem itself**, and nothing more:

- **The cache _is_ the output tree + `mtime`.** Make never stores a separate
  fingerprint, never archives outputs, never replays them. On an incremental run it
  compares `mtime`s and skips recipes whose targets are already newer than their
  prerequisites; the "cached" artifact is simply the file left on disk from last
  time. There is no digest of inputs, so a cache "hit" is "the output file exists
  and is newer," which is both cheaper and far weaker than the content-addressed
  caches elsewhere in this survey.

- **No remote cache, no REAPI, no remote execution.** Make has **zero** of the
  remote-build machinery that defines the heavyweight engines. There is no
  content-addressable store, no [Remote Execution API][reapi] client, no
  shared-team cache, no [BuildBuddy][buildbuddy]/[Buildbarn][buildbarn]/[NativeLink][nativelink]
  backend. Contrast [Bazel][bazel]/[Buck2][buck2] (CAS + REAPI + remote workers),
  [Turborepo][turborepo]/[moon][moon] (remote artifact replay), or even
  [Task][task] (which at least content-fingerprints locally). Make does none of it.

- **No artifact replay on a fresh checkout.** Because the only state is the output
  tree, a fresh `git clone` (or a CI runner that doesn't persist the workspace) has
  no outputs and no `mtime` history, so **every target rebuilds**. Make's
  incrementality is real on a warm working tree and evaporates completely in
  ephemeral CI — the same fate as [Task][task], but worse, because Make can't even
  hash-skip an unchanged-but-rebuilt file.

> [!NOTE]
> Teams that want cross-machine caching on top of Make bolt on an external layer:
> `ccache`/`sccache` for the compiler step, a CI artifact cache keyed on source
> hashes, or `remake`/`makepp` variants — or they migrate the outer loop to a tool
> that caches by content ([Task][task], [Turborepo][turborepo], [moon][moon]) or by
> hermetic action hash ([Bazel][bazel], [Buck2][buck2]). Make's lack of a content
> cache is the single biggest reason large monorepos outgrow it.

---

## CLI / UX ergonomics

Make's command boundary is `make [options] [target...] [VAR=value...]`. Like
[Task][task], there is no global-vs-targeted split to learn: you name the
target(s) you want, and pass overrides as trailing `VAR=value` pairs (which take
precedence over makefile assignments).

| Invocation                      | Meaning                                                                             |
| ------------------------------- | ----------------------------------------------------------------------------------- |
| `make`                          | Build the **default goal** (the first target in the makefile)                       |
| `make test`                     | Build the `test` target (and its prerequisites)                                     |
| `make build test`               | Build `build` then `test` — **left-to-right**, serialized unless under `-j`         |
| `make CFLAGS=-g app`            | Override the `CFLAGS` variable for this run (command-line vars win)                 |
| `make -j 8`                     | Run up to 8 recipes in parallel (the jobserver bounds recursion to this total)      |
| `make -j`                       | Unlimited parallelism (no job-slot cap)                                             |
| `make -C libs/core`             | Change to `libs/core` first, then build (the recursive-member selector)             |
| `make -f build.mk`              | Use `build.mk` instead of the default makefile-name search                          |
| `make -n` / `--dry-run`         | Print the recipes without running them                                              |
| `make -k` / `--keep-going`      | Keep building unrelated targets after one fails (CI-friendly)                       |
| `make -B` / `--always-make`     | Ignore `mtime`; unconditionally rebuild every target                                |
| `make -q` / `--question`        | Exit non-zero if the goal is **not** up to date; no execution (a CI freshness gate) |
| `make -w` / `--print-directory` | Print "Entering/Leaving directory" — essential for reading recursive logs           |
| `make -O` / `--output-sync`     | Group each recipe's output so parallel logs aren't interleaved                      |

The **member selector** for a monorepo is `-C <dir>` (change directory) — the same
flag the recursive-`make` recipe uses internally. This is as close as Make comes to
a project filter, and it is purely directory-positional: there is **no**
`--filter <glob>`, **no** `-p <package>` package selector, **no**
`--affected`/`--since` graph slicing. To "test everything," you write a phony
aggregator target (`test: libs/core.test apps/cli.test ...`) by hand, or loop over
`$(SUBDIRS)`. Compare [Turborepo][turborepo]'s `--filter`, [pnpm][pnpm]'s
`--filter`, [Cargo][cargo]'s `-p`/`--workspace`, or [moon][moon]'s `:task`
broadcast — none of which Make offers.

> [!NOTE]
> Make's ergonomic win is the inverse of its limits: a contributor needs to learn
> almost nothing beyond `make` and `make <target>`, and `make` is _already
> installed everywhere_. For small projects and as the universal "front door" of a
> polyglot monorepo (one `Makefile` whose targets delegate to each member's real
> tool), that ubiquity is the feature. For large graphs the absence of
> `--filter`/`--affected`, content caching, and a workspace model is exactly where
> teams graduate to the tools surveyed alongside it.

---

## Strengths

- **Ubiquity and zero install.** `make` is in every Unix base system, mandated by
  POSIX, and pre-installed on essentially every developer and CI machine — no
  bootstrap, no runtime, no plugins. It is the universal lowest common denominator.
- **Truly polyglot by construction.** A recipe is opaque shell, so any compiler or
  tool in any language coexists with no language assumptions — the natural fit for
  a heterogeneous monorepo's _outer_ loop.
- **A real, parallel DAG.** Targets, prerequisites, `-j` parallelism, and a
  jobserver that bounds concurrency even across recursive invocations — a genuine
  scheduling engine that newer tools imitate.
- **Cross-tool jobserver interop.** The GNU Make jobserver is a de-facto protocol
  other build tools ([Ninja][ninja], `cargo`) join, sharing one global `-j` budget.
- **Terse, powerful core.** Pattern rules, automatic variables, implicit-rule
  database, `VPATH`, `include`, order-only prerequisites, and (in `4.4`) grouped
  targets and `.WAIT` express a lot in very little text.
- **Stable and minimal.** A makefile written in 1990 still runs; the surface area
  is small and the behavior is predictable.

## Weaknesses

- **No workspace model at all.** No member manifest, no glob discovery, no project
  graph, no per-member metadata — only directories with `Makefile`s glued by
  recursion or flat `include`.
- **`mtime`-only change detection.** No content hashing, no command-line/flag
  tracking, no Git affected-detection; undeclared inputs silently produce stale
  builds, and a fresh checkout rebuilds everything.
- **No package resolution, lockfile, or isolation.** Everything package-related is
  delegated to native managers; cross-member links are file/order edges, not
  package edges; there is no `workspace:`-protocol and no version-drift control.
- **No caching beyond the output tree; no remote execution.** No content cache, no
  artifact replay, no REAPI, no remote workers — incrementality vanishes in
  ephemeral CI.
- **Recursive `make` is correctness-hostile.** It hands Make an incomplete DAG
  ([Miller, _RMCH_][rmch]), causing wrong incremental builds and serialized
  directory boundaries; the fix (whole-project `make`) trades it for one
  unmaintainable flat namespace.
- **No graph-filtering ergonomics.** No `--filter`/`-p`/`--affected`; member
  selection is positional `-C <dir>` plus hand-written aggregator targets.
- **Syntax footguns.** Tab-sensitive recipes, `$`-escaping (`$$` for shell `$`),
  recursive vs simple variable expansion (`=` vs `:=`), and per-line subshells are
  perennial sources of subtle bugs.

## Key design decisions and trade-offs

| Decision                                                     | Rationale                                                                            | Trade-off                                                                                           |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Files-as-units, `mtime`-as-truth change detection            | One `stat` per file; trivially cheap, language-agnostic, no extra state              | No content/flag/tool tracking; undeclared inputs go stale silently; fresh checkout rebuilds all     |
| Declarative DAG + opaque imperative shell recipes            | Make orchestrates; the shell does the work, so any language/tool plugs in            | Make can't reason about recipe contents; no hermeticity; correctness is the recipe author's problem |
| Composition by recursive `make` (no project model)           | Reuses the one primitive — `make` — for "a sub-project"; keeps the core tiny         | Incomplete DAG ([RMCH][rmch]): wrong incrementals, serialized boundaries, no cross-member view      |
| `include` is a flat textual merge (the non-recursive fix)    | Gives Make the _whole_ DAG → correct, parallelizable whole-project builds            | One global namespace; members must prefix everything; the makefile becomes a sprawling monolith     |
| `-j` parallelism bounded by an inheritable jobserver         | One global job budget even across recursion; other tools can join the pool           | Jobserver setup is subtle (FIFO vs pipe); a non-cooperating tool over-subscribes the machine        |
| Tab-significant recipe syntax (kept since 1976)              | Backward compatibility with every makefile ever written                              | The classic "missing separator" footgun; needed `.RECIPEPREFIX` as an escape hatch                  |
| No package resolver / lockfile (delegate to native managers) | Stays a runner; polyglot by construction; nothing to resolve or version              | No unified lockfile, no isolation, no `workspace:`-protocol; version drift is the user's problem    |
| No cache beyond the filesystem; no remote execution          | Tiny, dependency-free, nothing to run or operate                                     | No artifact replay, no remote/shared cache, no REAPI; incrementality lost on ephemeral CI           |
| Positional `-C <dir>` selection (no `--filter`/`--affected`) | Trivial mental model; `make` + `make <target>` is the whole UX, installed everywhere | Doesn't scale to large graphs; "build what changed" / subset selection is hand-built                |

---

## Sources

- [GNU Make Manual (`make.info`, 4.4.1)][manual] — Overview, Rules/`mtime`, Recursion, `MAKE` variable, Parallel Execution, POSIX Jobserver, Phony Targets, Include, Makefile Names (all verbatim quotes above are from this manual)
- [GNU Make git repository (Savannah)][repo] — the dominant implementation; GPL-3.0-or-later, written in C
- [POSIX `make` (IEEE Std 1003.1-2024)][posix] — the standardized `make` interface Make conforms to
- [Peter Miller, _"Recursive Make Considered Harmful"_ (AUUG, 1997)][rmch] — the canonical critique of recursive `make` as a topology (incomplete-DAG argument; whole-project solution)
- [GNU Make 4.4 release announcement][rel44] — `.WAIT`, grouped targets (`&:`), `--shuffle`, FIFO jobserver, `--jobserver-style`
- [GNU Make 4.4.1 release announcement][rel441] — bug-fix release (Feb 26, 2023)
- [Multiple Targets (GNU Make manual)][multitargets] — grouped-target (`&:`) semantics
- Related: [Task][task] · [just][just] · [mise][mise] · [Ninja][ninja] · [Meson][meson] · [CMake][cmake] · [GN][gn] · [redo][redo] · [tup][tup] · [moon][moon] · [Turborepo][turborepo] · [Nx][nx] · [Lerna][lerna] · [Bazel][bazel] · [Buck2][buck2] · [Cargo][cargo] · [uv][uv] · [pnpm][pnpm] · [BuildBuddy][buildbuddy] · [Buildbarn][buildbarn] · [NativeLink][nativelink] · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/mirror/make
[manual]: https://www.gnu.org/software/make/manual/make.html
[posix]: https://pubs.opengroup.org/onlinepubs/9799919799/utilities/make.html
[rmch]: https://aegis.sourceforge.net/auug97.pdf
[rel44]: https://lists.gnu.org/archive/html/info-gnu/2022-10/msg00008.html
[rel441]: https://lists.gnu.org/archive/html/info-gnu/2023-02/msg00011.html
[multitargets]: https://www.gnu.org/software/make/manual/html_node/Multiple-Targets.html
[reapi]: https://github.com/bazelbuild/remote-apis
[task]: ../task/
[just]: ../just/
[mise]: ../mise/
[ninja]: ../ninja/
[meson]: ../meson/
[cmake]: ../cmake/
[gn]: ../gn/
[redo]: ../redo/
[tup]: ../tup/
[moon]: ../moon/
[turborepo]: ../turborepo/
[nx]: ../nx/
[lerna]: ../lerna/
[bazel]: ../bazel/
[buck2]: ../buck2/
[cargo]: ../cargo/
[uv]: ../uv/
[pnpm]: ../pnpm/
[buildbuddy]: ../buildbuddy/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
