# redo (Minimalist)

Daniel J. Bernstein's minimalist build-system design — _"do"_ scripts that build
one target each and declare their prerequisites **dynamically at runtime** via
`redo-ifchange`, recorded in a persistent `.redo` database — realized in
Avery Pennarun's [`apenwarr/redo`][repo] implementation, which adds parallel
builds, content checksums, and a GNU-Make-compatible jobserver.

| Field           | Value                                                                                                                 |
| --------------- | --------------------------------------------------------------------------------------------------------------------- |
| Language        | Python (the reference `apenwarr/redo`; bootstrapped by a pure-`sh` `do` script); design is language-agnostic          |
| License         | Apache-2.0 (`apenwarr/redo`); djb's original design notes are an informal public specification, not code              |
| Repository      | [apenwarr/redo][repo] (reference impl) · [djb's design notes][djb] (`cr.yp.to/redo.html`)                             |
| Documentation   | [redo.readthedocs.io][docs] · [`docs/` in-tree][docsdir]                                                              |
| Category        | Minimalist / Research                                                                                                 |
| Workspace model | **None.** A "project" is a directory tree of `.do` scripts; recursion across directories is the only composition unit |
| First released  | djb's design notes, **circa 2003**; `apenwarr/redo` first public commits **December 2010**                            |
| Latest release  | `apenwarr/redo` tag **`redo-0.42`** (last commit **July 28, 2021**; repo last pushed Nov 2023)                        |

> **Latest release:** `apenwarr/redo` is tagged through `redo-0.42`, with the most
> recent commit on **July 28, 2021** and the repository last touched in **November
> 2023** — a mature, low-churn codebase rather than an abandoned one. It is "_currently
> written in python for easier experimentation, but the plan is to eventually
> migrate it to plain C_" ([README][repo]); that C port has not landed as of June 5, 2026. Several independent implementations exist (the minimalist `redo-sh`, Jonathan
> de Boyne Pollard's C `redo`, `aquaratixc/redo` in D, `mildred/redo`); this deep-dive
> tracks the **design** and the `apenwarr/redo` reference, the most feature-complete.

---

## Overview

### What it solves

redo answers the same question as [Make][make] — _which derived files are stale,
and what command rebuilds them?_ — but inverts Make's two foundational choices:

1. **Dependencies are discovered dynamically, not declared statically.** A Make
   rule lists its prerequisites _ahead of time_ in the `Makefile`. A redo target
   is built by running a shell script that **calls `redo-ifchange` on whatever it
   actually reads**, possibly _after_ producing output — so the dependency graph is
   a byproduct of running the build, never a hand-maintained parallel structure.
2. **There is no top-level ruleset.** Each target `foo` is built by a `foo.do`
   script (or a `default.<ext>.do` template); the script is an ordinary shell
   program executed top-to-bottom, not a clause matched out of an orderless global
   rulebase. This is what lets redo "_support recursion and full dependency
   information simultaneously_" — Make's recursion (the "Recursive Make Considered
   Harmful" problem) loses cross-directory dependency edges, but redo's `.redo`
   database is global so a cross-directory `redo-ifchange ../lib/foo.o` is a
   first-class edge.

The design originates with **Daniel J. Bernstein** (qmail, djbdns), who posted
terse notes titled _"Rebuilding target files when source files have changed"_ but
never released an implementation. From the `apenwarr/redo` introduction
([`docs/index.md`][docsindex]):

> _"The original design for redo comes from Daniel J. Bernstein… He posted some
> terse notes… However, djb never released his version, so other people have
> implemented their own variants based on his published specification."_

The key conceptual move, in Avery Pennarun's words from the same docs:

> _"you don't actually care what the dependencies are_ before _you build the
> target. If the target doesn't exist, you obviously need to build it."_

> [!NOTE]
> redo is in the **Minimalist / Research** category alongside [tup][tup]. Like
> [Make][make], it is a polyglot _target_ engine with **no package manager, no
> lockfile, no workspace/member model, and no remote cache**. Its relevance to a
> `dub` workspace proposal is narrow but sharp: it is the cleanest existing answer
> to _"how do you record an exact, minimal, content-addressed dependency set without
> a human writing it down"_ — directly applicable to incremental and affected-target
> detection (see [Task orchestration](#task-orchestration--scheduling)).

### Design philosophy

From the reference implementation's tagline ([README][repo]): redo is _"Smaller,
easier, more powerful, and more reliable than `make`."_ The introduction expands
the thesis ([`docs/index.md`][docsindex]):

> _"it can do everything `make` can do, but the implementation is vastly simpler,
> the syntax is cleaner, and you have even more flexibility without resorting to
> ugly hacks."_

Pennarun's original announcement frames the four wins concretely
([apenwarr.ca, 2010][blog]):

> _"it can do everything make can do; with no baked-in assumptions about what
> you're building; with much less code; with much greater parallelism; with
> finer-grained dependencies… while supporting recursion and full dependency
> information simultaneously (no Recursive Make Considered Harmful crap)… you can
> checksum your targets instead of using timestamps."_

Three consequences shape the whole tool:

1. **A dependency declaration is just another shell command.** `redo-ifchange foo`
   means _"build `foo`; and if `foo` (or anything `foo` itself depends on) ever
   changes, mark the current target dirty."_ There is no separate dependency syntax.
2. **Build scripts are linear and modular.** Each `.do` file is read top-to-bottom
   like any script, so it is debuggable with ordinary shell tooling — unlike a
   makefile, which is a declarative ruleset whose evaluation order is implicit.
3. **Targets are produced atomically.** A `.do` script writes to a temporary file
   (`$3`) or stdout, _never_ to the real target; redo renames it into place only on
   a zero exit code, so an interrupted build never leaves a corrupt, falsely-fresh
   target.

---

## How it works

### `.do` scripts and the three arguments

To build target `foo`, redo looks for `foo.do`; failing that, it walks up
directories trying `default.<ext>.do` templates (e.g. `default.o.do`,
`default.do`). Whatever script it finds is run with **three positional
arguments** ([FAQ § Semantics][faqsem]):

| Arg  | Meaning                                                                                                         |
| ---- | --------------------------------------------------------------------------------------------------------------- |
| `$1` | the **target** name (e.g. `chicken.a.b.c`)                                                                      |
| `$2` | the **basename** — the target minus the extension the `default.*.do` matched (e.g. `chicken.a.b` for a `.c.do`) |
| `$3` | a **temporary output file**, atomically renamed to `$1` iff the script exits `0`                                |

The atomicity contract is strict: _"Only write to `$3` or stdout, never to `$1`."_
Stdout is captured and redirected into `$3` by default, so a script can be a single
pipeline. The reference docs concede the ergonomic cost ([FAQ § Semantics][faqsem]):

> _"Isn't it confusing to capture stdout by default? Yes, it is."_

— status messages must therefore go to **stderr**.

A canonical C-compilation template, `default.o.do`, shows the dynamic-dependency
idiom — build the source, compile, then declare the discovered headers
([`redo-ifchange(1)`][ifchange]):

```bash
# default.o.do  — builds any  *.o  target
redo-ifchange $2.c
gcc -o $3 -c $2.c \
    -MMD -MF $2.deps      # gcc emits the header list as a side effect
read DEPS <$2.deps
redo-ifchange ${DEPS#*:}  # declare those headers as dependencies, AFTER compiling
```

The `gcc -MMD` line is the whole point: the _exact_ set of `#include`d headers is
learned from the compiler that actually read them, then fed straight into
`redo-ifchange`. No human maintains a `foo.o: foo.h bar.h` line. This is djb's
"honest" dependency principle; his own `dhcpd.do` sketch is the same shape
([djb's notes][djb]):

```bash
redo-ifchange cc dhcpd.deps
redo-ifchange `cat dhcpd.deps`
./cc -o dhcpd `cat dhcpd.deps`
```

### The dependency primitives

redo's entire dependency vocabulary is four small commands a `.do` script invokes:

| Command            | Meaning                                                                                                                                |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------- |
| `redo-ifchange X…` | Build each `X`; record a dependency on it. If any `X` (or its transitive deps) later changes, the current target becomes dirty.        |
| `redo-ifcreate X…` | Record that the current target must rebuild **if** `X` (which must _not_ exist now) is ever created — captures negative/glob deps.     |
| `redo-always`      | Mark the current target as always-dirty (rebuilt at most once per `redo` session).                                                     |
| `redo-stamp`       | Read stdin and record its **checksum**; the target is "changed" only if that content checksum differs — overrides timestamp staleness. |

`redo-ifchange` is the workhorse, defined crisply ([`docs/index.md`][docsindex]):

> _"build each of my arguments. If any of them or their dependencies ever change,
> then I need to run the_ current script _over again."_

`redo-ifcreate` handles the case Make cannot express cleanly — _"the current target
must be rebuilt if the given source files (which must not yet exist) get created"_
([`redo-ifcreate(1)`][ifcreate]) — e.g. a `default.o.do` records `redo-ifcreate
foo.o.do` so that adding a more-specific rule later invalidates the target.

### The `.redo` database and atomic rebuild

Recorded dependencies are persisted in a per-project **`.redo` database**
([`docs/index.md`][docsindex]):

> _"Dependencies are tracked in a persistent `.redo` database so that redo can check
> them later. If a file needs to be rebuilt, it re-executes the whatever.do script
> and regenerates the dependencies. If a file doesn't need to be rebuilt, redo
> figures that out just using its persistent `.redo` database, without re-running
> the script. And it can do that check just once right at the start of your project
> build, which is really fast."_

So a no-op build is a single fast pass over the database — redo does **not** re-run
any `.do` script to decide freshness, only to _produce_ a stale target. Each rebuild
writes `$3` and is committed by an atomic `rename(2)`, so a crash mid-build leaves
the previous good target intact and still marked stale.

### Change detection: timestamps **and** checksums

By default redo uses file metadata (mtime/size/inode — "resilient timestamps"),
but `redo-stamp` upgrades any target to **content-addressed** staleness. The
worked example is a `./configure` output ([FAQ § Semantics][faqsem]): after
generating `config.h`, the `.do` script pipes the outputs through `redo-stamp`, so
downstream targets rebuild only if _"the contents of `config.h`, `configure`, or
`Makefile` are different than they were before"_ — a regenerated-but-identical
`config.h` does **not** cascade a rebuild. This is the same content-hash idea that
[Bazel][bazel], [Turborepo][turborepo], and [Nx][nx] later made central, expressed
as one optional shell command.

### Parallelism: a GNU-Make-compatible jobserver

The reference implementation runs builds in parallel with `redo -j<N>`. Crucially,
its jobserver is **wire-compatible with GNU Make's** ([FAQ § Parallel builds][faqpar]):

> _"redo (and GNU make) use the `MAKEFLAGS` environment variable to pass information
> about the parallel build environment from one process to the next… Inside
> `MAKEFLAGS` is a string that looks like either `--jobserver-auth=X,Y` or
> `--jobserver-fds=X,Y`, depending on the version of make."_

Because the token-passing protocol matches Make's, a redo build can `make subproj`
or a Make build can recurse into redo, and the two **share the same pool of `-j`
tokens** — no double-counting of CPUs across the boundary. redo also _"maintains
global locks across all its instances, so… no two instances will try to build
`subproj` at the same time."_ Parallelism is only exploited when a single
`redo-ifchange` is handed multiple targets at once, so the idiom is to batch
(`xargs redo-ifchange`) rather than loop ([`redo-ifchange(1)`][ifchange]).

---

## Per-tool analysis (the five dimensions)

### Workspace declaration & topology

**There is no workspace concept** — this is the defining trait of the Minimalist /
Research category. redo has no manifest, no `members = [...]` glob, no
root-marker file enumerating sub-packages. The unit of composition is the
**directory tree of `.do` files**: a target is a path, and a "sub-project" is just
a subdirectory you can name in a `redo-ifchange` (or recurse into).

What redo _does_ provide, and Make notably lacks, is **coherent cross-directory
builds**. From the semantics FAQ ([FAQ § Semantics][faqsem]):

> _"When running any `.do` file, redo makes sure its current directory is set to the
> directory where the `.do` file is located."_

Running `redo ../utils/foo.o` finds and runs `../utils/default.o.do` _in that
directory_, and the resulting dependency edge is recorded in the **single global
`.redo` database** at the project root — so a top-level target can depend on a
target three directories down without the "Recursive Make Considered Harmful"
loss of dependency information. That global database is the closest redo comes to a
"workspace": it is an implicit, discovered topology rather than a declared one.
Contrast [Cargo][cargo]'s explicit `[workspace] members`, [go-work][go-work]'s
`go.work`, or [pnpm][pnpm]'s `pnpm-workspace.yaml`: redo declares **nothing**.

### Dependency handling & isolation

redo has **no package-dependency model whatsoever** — no fetching, version
resolution, hoisting, symlink trees, virtual store, or lockfile. It deals only in
**file/target dependencies**, and those are its signature feature: declared
**dynamically at build time** rather than statically, and recorded with full
transitivity in `.redo`. The relevant axes:

- **Discovery, not declaration.** Headers, generated sources, and tool inputs are
  fed to `redo-ifchange` by the build commands that read them (`gcc -MMD`,
  `cat foo.deps`), so the recorded set is _exactly_ what was used — "honest"
  dependencies in djb's terms.
- **Negative dependencies** via `redo-ifcreate` capture "rebuild if this file
  appears" (e.g. a more-specific `.do` overriding a `default.*.do`), an edge most
  build tools cannot express.
- **No isolation primitive.** Unlike [pnpm][pnpm]'s isolated symlink trees,
  [Yarn Berry][yarn-berry]'s PnP, or [Bazel][bazel]'s sandbox, redo runs `.do`
  scripts in the real working directory with full filesystem access. Hermeticity is
  the user's responsibility; nothing prevents a script from reading an undeclared
  file (an "underspecified dependency"), the classic correctness hole that sandboxed
  engines close.

For language-package resolution (the job a `dub` workspace needs), redo contributes
**nothing directly** — but its dynamic-dependency-capture pattern is exactly how a
resolver _could_ record the precise inputs of each member's build.

### Task orchestration & scheduling

redo **is** a task-DAG engine — that is its core. The DAG is implicit in the
`redo-ifchange` calls and materialized in `.redo`:

- **DAG construction is lazy and dynamic.** The graph is built by _running_ the
  scripts; there is no parse-time graph. A target's prerequisites are known only
  after its `.do` has run once, then cached.
- **Change detection** is the database scan described above: a single fast pass
  over `.redo` at the start of a build decides every target's freshness without
  re-executing scripts, using mtime by default and content checksums where
  `redo-stamp` is used. This is structurally the same "input hash → skip" model as
  [Turborepo][turborepo]/[Nx][nx], minus the remote cache.
- **Concurrent execution** via the GNU-Make-compatible jobserver (`-j<N>`), with
  global inter-instance locks preventing duplicate builds of a shared target across
  recursive invocations.
- **No "affected since git ref" feature.** redo has no notion of a VCS diff or an
  `--affected`/`--since` selector; "what changed" is answered purely by the
  filesystem/checksum state in `.redo`. (Compare [Nx][nx]'s `affected`,
  [Turborepo][turborepo]'s `--filter=...[ref]`, [Bazel][bazel]'s query-based
  affected-target computation — redo has none of these.)

### Caching & remote execution

- **Local incremental cache: yes**, in the form of the `.redo` database plus the
  already-built targets on disk. A clean rebuild reuses every up-to-date target;
  `redo-stamp` makes that reuse content-addressed rather than timestamp-based.
- **Shared/remote build cache: no.** There is no content-addressed CAS, no
  cache-key upload/download, and **no REAPI / remote-execution backend**. redo
  never offers an artifact built on machine A to machine B. This is the sharpest
  contrast with [Bazel][bazel] + [Buildbarn][buildbarn]/[NativeLink][nativelink],
  [Turborepo][turborepo]'s Remote Cache, or [Buck2][buck2]. redo's caching is
  strictly a single-machine incrementality mechanism.

In the survey's taxonomy redo sits with [Make][make] and [tup][tup] as
**local-incremental-only**: real, correct, minimal incremental builds, but nothing
distributed.

### CLI / UX ergonomics

The command surface is deliberately tiny — a handful of verbs, no flag-heavy filter
language:

| Command                                    | Role                                                                                         |
| ------------------------------------------ | -------------------------------------------------------------------------------------------- |
| `redo [targets…]`                          | Force-build the named targets (default target: `all`, i.e. run `all.do`). No target ⇒ `all`. |
| `redo-ifchange X…`                         | Build + depend (used _inside_ `.do` scripts, the primary developer-facing verb).             |
| `redo-ifcreate X…`                         | Depend-on-creation (inside `.do`).                                                           |
| `redo-always` / `redo-stamp`               | Force-dirty / checksum-stamp the current target (inside `.do`).                              |
| `redo -j<N>`                               | Parallelism degree (jobserver tokens).                                                       |
| `redo-targets`, `redo-sources`, `redo-ood` | Introspection: list known targets / sources / out-of-date targets.                           |

The "command boundary" is unusual: there are **no `--filter`, `-p <pkg>`, `:target`,
or `--since` selectors** like [Turborepo][turborepo] (`--filter`), [pnpm][pnpm]
(`--filter`), [Cargo][cargo] (`-p`), or [Bazel][bazel] (`//pkg:target` labels).
You select work by **naming target files/paths** (`redo path/to/foo.o`), and you
slice a sub-graph by depending on a coarser target. The ergonomic trade is radical
simplicity (the whole CLI fits on a card; `redo-ifchange` is the one verb you learn)
against the absence of any package- or change-set-oriented selection. For a
`dub`-style "test only the affected members" workflow, redo offers a _mechanism_
(precise recorded deps) but no _UX_ (no member or ref selectors).

---

## Strengths

- **Honest, exact, minimal dependencies for free.** `redo-ifchange` records exactly
  the inputs a build touched (e.g. real header lists from `gcc -MMD`), eliminating
  the hand-maintained, perpetually-stale prerequisite lists that plague makefiles.
- **Recursion _with_ full dependency information.** The global `.redo` database makes
  cross-directory edges first-class, structurally avoiding "Recursive Make Considered
  Harmful."
- **Linear, debuggable build scripts.** Each `.do` is an ordinary shell program run
  top-to-bottom — no implicit-ordering ruleset, debuggable with `set -x`, any
  language via a shebang.
- **Atomic, crash-safe rebuilds.** Write-to-`$3`-then-`rename` guarantees a target is
  never left half-written and falsely fresh.
- **Optional content-checksum staleness** (`redo-stamp`) avoids needless rebuild
  cascades from regenerated-but-identical files — the idea CI-era tools later
  centralized.
- **Tiny, comprehensible core.** The whole semantic model is four shell verbs plus a
  database; the reference implementation is small Python intended to become small C.
- **Polyglot and dependency-free at runtime.** Like [Make][make], it orchestrates any
  toolchain and needs only a POSIX shell to bootstrap (`./do`).
- **GNU-Make-compatible jobserver** lets redo and Make recurse into each other while
  sharing one `-j` token pool.

## Weaknesses

- **No workspace/package model.** No members, no manifest, no version resolution, no
  lockfile — orthogonal to the package-management half of a monorepo tool.
- **No remote/shared cache and no remote execution.** Single-machine incrementality
  only; nothing like REAPI, a CAS, or [Turborepo][turborepo]/[Bazel][bazel] remote
  caching.
- **No affected-set / `--since` / filter UX.** Selection is by target path only;
  there is no git-diff-driven or package-scoped slicing.
- **Hermeticity is unenforced.** Scripts run in the live filesystem; an undeclared
  read silently underspecifies the graph, with no sandbox to catch it (cf.
  [Bazel][bazel], [tup][tup]'s FUSE/`ptrace` enforcement).
- **`stdout`-capture-by-default is a footgun** — its own docs call it confusing; a
  stray `echo` corrupts the target.
- **Fragmented ecosystem, no canonical binary.** Many partial implementations of an
  informal spec; djb never shipped one, and the reference Python is low-churn with an
  unrealized C port.
- **Shell-centric.** `.do` scripts are typically `sh`; expressing rich build logic
  means more shell than some teams want, and Windows support is second-class.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                    | Trade-off                                                                                       |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Dynamic, runtime-discovered dependencies (`redo-ifchange`)      | Records the _exact_ inputs a build touched; no hand-maintained prerequisite lists            | The graph is unknown until a target builds once; a missed `redo-ifchange` silently under-tracks |
| One `.do` script per target (vs. a global ruleset)              | Linear, debuggable, polyglot scripts; recursion keeps full dependency info                   | More files than a single `Makefile`; logic is spread across many small scripts                  |
| Global `.redo` database across directories                      | First-class cross-directory edges — no "Recursive Make Considered Harmful"                   | A hidden stateful store; correctness depends on its integrity, not a readable manifest          |
| Atomic write-to-`$3`-then-`rename`                              | Crash-safe; interrupted builds never leave a falsely-fresh target                            | The "never write `$1`, capture stdout" rule is unintuitive and easy to violate                  |
| Optional checksum staleness (`redo-stamp`) over mtime           | Avoids rebuild cascades from regenerated-identical files; content-addressed where it matters | Opt-in per target; default mtime model can still over-rebuild                                   |
| GNU-Make-compatible jobserver (`MAKEFLAGS`, `--jobserver-auth`) | redo ⇄ Make can recurse into each other and share one `-j` pool                              | Inherits Make's pipe-token protocol quirks; no richer scheduling than token count               |
| No package manager / no remote cache (minimalist scope)         | Tiny, comprehensible, polyglot core that does one thing well                                 | Must be paired with a real package manager and CI cache for monorepo-scale work                 |
| Informal spec, multiple implementations                         | Anyone can implement djb's small design; ideas spread widely                                 | No canonical binary; behavioral drift between implementations; ecosystem fragmentation          |

---

## What `dub` can borrow

redo contributes **mechanism, not workspace UX**. Two ideas transfer cleanly to the
[`dub` workspace proposal][d-landscape]:

1. **Dynamic, recorded build inputs as the basis for incrementality.** Rather than a
   human declaring which files a member's build reads, `dub` could record the actual
   inputs of each member's compilation (sources, imports, generated files) — redo's
   `redo-ifchange`-after-the-fact idiom — and key incremental/affected decisions on
   that recorded set in a per-workspace database analogous to `.redo`.
2. **Content-checksum staleness (`redo-stamp`) over pure timestamps.** A `dub`
   workspace that hashes member outputs can skip downstream recompilation when a
   regenerated artifact is byte-identical — the cheap correctness win redo exposes as
   one command and CI-era tools later made central.

What redo deliberately omits — workspace declaration, package resolution, a shared
lockfile, a remote cache, and member/ref-scoped CLI selection — is precisely the
surface the `dub` proposal must source from the explicit-workspace tools
([Cargo][cargo], [pnpm][pnpm], [go-work][go-work]) and the cache/orchestration tools
([Turborepo][turborepo], [Nx][nx], [Bazel][bazel]) instead.

---

## Sources

- [apenwarr/redo — GitHub repository (reference implementation, README, tagline,
  Apache-2.0)][repo]
- [djb's original design notes — "Rebuilding target files when source files have
  changed" (`cr.yp.to/redo.html`)][djb]
- [redo documentation — readthedocs.io][docs] · [in-tree `docs/`][docsdir]
- [`docs/index.md` — introduction, `redo-ifchange` definition, `.redo` database][docsindex]
- [`redo-ifchange(1)` — `default.o.do` example, batching for parallelism][ifchange]
- [`redo-ifcreate(1)` — negative/creation dependencies][ifcreate]
- [FAQ § Semantics — `$1/$2/$3`, atomic rebuild, `default.*.do`, `redo-stamp`,
  cross-directory builds][faqsem]
- [FAQ § Parallel builds — GNU-Make-compatible jobserver, `MAKEFLAGS`, global locks][faqpar]
- [Avery Pennarun, "The only build system that might someday replace make…"
  (apenwarr.ca, 2010)][blog]
- Sibling tools: [Make][make] · [tup][tup] · [Cargo][cargo] · [pnpm][pnpm] ·
  [go-work][go-work] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] ·
  [Buck2][buck2] · [Buildbarn][buildbarn] · [NativeLink][nativelink] ·
  [Yarn Berry][yarn-berry]; `dub` context: [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/apenwarr/redo
[djb]: https://cr.yp.to/redo.html
[docs]: https://redo.readthedocs.io/en/latest/
[docsdir]: https://github.com/apenwarr/redo/tree/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs
[docsindex]: https://github.com/apenwarr/redo/blob/7f00abc36be15f398fa3ecf9f4e5283509c34a00/docs/index.md
[ifchange]: https://redo.readthedocs.io/en/latest/redo-ifchange/
[ifcreate]: https://redo.readthedocs.io/en/latest/redo-ifcreate/
[faqsem]: https://redo.readthedocs.io/en/latest/FAQSemantics/
[faqpar]: https://redo.readthedocs.io/en/latest/FAQParallel/
[blog]: https://apenwarr.ca/log/20101214
[make]: ../make/
[tup]: ../tup/
[cargo]: ../cargo/
[pnpm]: ../pnpm/
[go-work]: ../go-work/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[yarn-berry]: ../yarn-berry/
[d-landscape]: ../../async-io/d-landscape.md
