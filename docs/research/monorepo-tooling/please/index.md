# Please (Polyglot)

A lightweight, `Go`-implemented incarnation of the `Blaze`/`Bazel`/`Buck` design,
created at fintech firm Thought Machine: a cross-language build orchestrator whose
`BUILD` files — written in a restricted `Python` dialect — turn a whole repository
into one hash-keyed, sandboxed action graph that is parallelized, locally and
remotely cached, and (since `v17`) extended entirely through downloadable language
plugins.

| Field           | Value                                                                                                          |
| --------------- | -------------------------------------------------------------------------------------------------------------- |
| Language        | `Go` (engine, ~86%) + `Starlark`/restricted-`Python` (the `BUILD`/`.build_defs` language)                      |
| License         | Apache-2.0                                                                                                     |
| Repository      | [thought-machine/please][repo]                                                                                 |
| Documentation   | [please.build][docs] · [Lexicon][lexicon] · [Config reference][config]                                         |
| Category        | Polyglot Build Orchestrator                                                                                    |
| Workspace model | Single repo rooted at a `.plzconfig` marker file; the whole tree is one workspace of `BUILD`-file `package`s   |
| First released  | Open-sourced by Thought Machine in late 2017 (born from "an impromptu discussion in a pub one Friday evening") |
| Latest release  | `v17.30.0` (April 21, 2026)                                                                                    |

> **Latest release:** `v17.30.0`, released **April 21, 2026**. The `v17` line is
> significant: it completed the migration begun in `v16` of moving the bundled
> per-language rules (`Go`, `Python`, `Java`, `C++`, …) **out** of the engine and
> into separately-versioned **plugins** fetched as subrepos. As of June 5, 2026 a
> repo therefore declares both an engine version and an explicit set of language
> plugins in `.plzconfig`. Source citations below are against `master`
> ([`thought-machine/please`][repo]) and the official docs at [please.build][docs].

---

## Overview

### What it solves

Please targets the same problem as [Bazel][bazel] and [Buck2][buck2]: **one
repository containing many languages, built and tested as a single coherent
graph**, where a change to a shared `.proto` or library rebuilds exactly the
downstream `Go`, `Python`, and `Java` that depend on it — no more, no less. It was
written at Thought Machine because their codebase spanned _"Javascript, Python,
Java and Go"_ plus other technologies, and invoking a different native build tool
per language ([`go build`][go-work], `mvn`, `pip`, webpack) gave no cross-language
dependency graph, no shared cache, and no single `test` command.

Where Please consciously diverges from Bazel is **weight**. From the project's own
FAQ, the team _"have slightly different goals, specifically we're aiming Please at
being lighter weight"_ than Bazel, while keeping the parts they valued from Buck
(which they used internally) — notably _"test sandboxing"_ and _"a stronger focus
on `BUILD` language correctness."_ The engine is a single statically-linked `Go`
binary (no JVM, no daemon required for small repos), bootstrapped per-repo by a
committed `pleasew` wrapper script that downloads the pinned version on first run —
so a checkout builds with the right `plz` without a global install.

The build model is the canonical content-addressed one: every target declares its
exact `srcs`, `deps`, `outs`, and `cmd`; the engine hashes those inputs; and an
action whose inputs are unchanged is never re-run — its outputs are pulled from a
cache instead, possibly a cache shared by the whole org. Within the polyglot
survey, Please is the **"Bazel, but small and `Go`-native"** data point; contrast
the heavyweight reference [Bazel][bazel] and [Buck2][buck2], the `Python`-rule-set
[Pants][pants], and the schema-first `Moon`.

### Design philosophy

The README's one-sentence positioning ([`thought-machine/please`][repo]):

> _"Please is a cross-language build system with an emphasis on high performance,
> extensibility and reproducibility. It supports many popular languages and can
> automate nearly any aspect of your build process."_

Two deliberate choices follow and shape the whole tool:

1. **`BUILD` files are programs, not data.** The build language is _"a restricted
   subset of Python"_, chosen over XML/JSON because it gives _"more power and (in
   our opinion) a significantly nicer format."_ A `BUILD` file can loop, branch,
   and call shared functions (`subinclude`d from `.build_defs` files) to generate
   targets programmatically — but the dialect is sandboxed (no arbitrary I/O,
   deterministic) so parsing stays a pure function and the graph stays cacheable.
2. **`Go`, for operational lightness.** They chose `Go` because it _"avoided JVM
   startup overhead, Python's threading limitations, and C++'s complexity"_ — the
   binary starts instantly and parallelizes parsing/building across goroutines
   without a persistent server. This is the concrete lever behind the "lighter
   weight than Bazel" goal.

The same language powers built-in and user rules: every `go_binary`, `python_test`,
etc. is itself a function written in the `BUILD` dialect (now shipped in plugins),
so _"built-in rules use the same language as user-defined targets"_ — there is no
privileged native-rule tier as in early Bazel.

---

## How it works

### Repository, packages, and labels

A Please repository is rooted at the **`.plzconfig`** file: _"The `.plzconfig` file
marks the root of a Please repository."_ Any directory containing a `BUILD` file is
a **`package`** — _"analogous to Makefiles in that they define buildable targets
for that directory."_ Targets are addressed by **build labels**:

```bash
//src/core:core        # one target 'core' in package //src/core
//src/core:all         # every target in that package
//src/...              # every target in the package tree (recursive)
:core                  # local reference, same BUILD file
PUBLIC                 # visibility pseudo-label, ~ //...
```

A minimal `genrule` — the universal escape hatch every other rule is built on —
shows the declare-inputs/declare-outputs contract ([build rules docs][build-rules]):

```python
# BUILD
genrule(
    name = "word_count",
    srcs = ["file.txt"],
    outs = ["file.wordcount"],
    cmd = "wc $SRCS > $OUT",
)
```

`$SRCS`, `$OUT`, `$PKG`, `$NAME`, `$TMP_DIR`, `$TOOLS` and friends are the only
environment exposed; host env requires explicit `pass_env`. Cross-target
references in `cmd` use substitutions — `$(location //path:target)`,
`$(exe //path:target)`, `$(hash //path:target)` — so commands never hard-code
paths into `plz-out`.

### Sandboxing and hashing

Each rule runs _"in an isolated temporary directory containing only its declared
inputs"_; with `sandbox = True` the action is additionally placed _"within a
separate network and process namespace"_ (Linux namespaces). This is what makes the
input hash trustworthy: an action cannot read an undeclared file, so its output is
a pure function of `(rule definition hash, source hashes, dependency output
hashes)`. Outputs land in `plz-out/bin/` (binaries) or `plz-out/gen/` (everything
else), and **only declared `outs` survive** — anything else the command writes is
discarded with the sandbox.

### Subincludes and `.build_defs`

Reusable rule logic lives in `.build_defs` files and is pulled in with
**`subinclude`**, the BUILD-language analogue of `import`. Per the lexicon,
`subinclude` _"includes the output of a build target as extra rules in this one"_ —
the contents are merged into the calling module's globals, so the imported
functions are then callable directly. `[Parse] PreloadSubincludes` in `.plzconfig`
preloads a set of these before any `BUILD` file is parsed, giving a repo a shared
prelude of macros.

### Plugins and the `v17` model

Since `v17`, language rule-sets are **plugins** fetched as subrepos. Bootstrapping
a `Go`-aware repo:

```bash
plz init                  # writes .plzconfig + the pleasew wrapper script
plz init plugin go        # adds the Go plugin as a subrepo + [Plugin "go"] config
```

`.plzconfig` then pins the engine version and the plugins together:

```ini
# .plzconfig
[please]
version = 17.30.0

[plugin "go"]
target = //plugins:go
importpath = github.com/thought-machine/example
```

Built-in rules thus version independently of the engine; a repo upgrades `Go`
tooling rules without upgrading `plz` itself.

### The five dimensions

#### 1. Workspace declaration & topology

- **Root marker, not a member list.** A repo is rooted wherever `.plzconfig` lives;
  the workspace is _the entire tree_, discovered by walking it for `BUILD` files.
  There is **no explicit `members`/`packages` array** (contrast [Cargo][cargo]'s
  `[workspace] members = [...]` or [pnpm][pnpm]'s `pnpm-workspace.yaml` globs).
  Topology is implicit: every directory with a `BUILD` file is a package; every
  package's targets form the leaves of one global graph.
- **Discovery is configurable and prunable.** `[Parse] BuildFileName` lets a repo
  rename `BUILD` to anything (_"you could reconfigure them here to be something
  else"_); `[Parse] BlacklistDirs` excludes directories from the recursive search
  (vendored trees, generated dirs).
- **Layered config = layered "workspaces."** `.plzconfig` is merged from up to six
  sources in priority order — `/etc/please/plzconfig`,
  `~/.config/please/plzconfig`, `.plzconfig`, `.plzconfig_<arch>`, `--profile`
  variants, and `.plzconfig.local` (highest) — so machine, user, repo, arch, and
  per-developer overrides compose without editing the committed file.
- **Subrepos = nested/foreign workspaces.** `http_archive`, `github_repo`, and the
  plugin mechanism mount another repo (or a downloaded archive) as a **subrepo**,
  addressed with the triple-slash label syntax
  `///third_party/go/...//pkg:target`. This is the closest Please gets to a
  multi-root workspace: third-party code and language plugins are first-class
  sub-graphs you depend on like any local target.

#### 2. Dependency handling & isolation

- **No hoisting, no symlink store — vendored subrepos.** Please has no concept of a
  hoisted `node_modules` ([npm][npm]) or a content-addressed virtual store
  ([pnpm][pnpm]). Third-party deps are _"a concept called 'subrepos' which allows
  fetching arbitrary dependencies and attaching build rules to them."_ Each foreign
  package becomes a target in a subrepo, isolated by the sandbox at build time.
- **Per-ecosystem fetch rules, all pinned.** Language plugins provide
  `pip_library()` (Python), `maven_jar()` (Java), and `go_module()`/`go_repo`
  (Go). Each _"requires explicit transitive dependency declarations to pin
  dependencies & guarantee reproducibility,"_ and downloads are **SHA256-verified**
  (the `hashes` parameter) — a corrupted or changed artifact fails the build. There
  is no separate top-level lockfile format; the pin _is_ the `BUILD` rule
  (`revision = ...`, `hashes = [...]`), versioned in git.
- **Local cross-references are just labels.** A library in one package is depended
  on from another purely by its `//path:target` label — no `path=`/`workspace:`
  protocol, no publishing step. The dependency graph is the cross-reference
  mechanism; topological build order falls out of it automatically.
- **License gating.** `pip_library`/`maven_jar` auto-detect licenses and check them
  against a configured allowlist — dependency policy enforced at fetch time.

#### 3. Task orchestration & scheduling

- **One global action DAG.** Every target is a node; `srcs`/`deps`/`tools` are
  edges. `plz build //...` resolves the transitive closure, then executes ready
  actions concurrently across a worker pool sized by `[please] NumThreads`
  (default **CPU count + 2**, override `-n/--num_threads`). Parsing is itself
  parallel (goroutines per `BUILD` file).
- **Change detection by input hash, not timestamps.** An action is skipped when its
  computed input hash matches a cached result — _"correctness in cache invalidation
  through dependency hashing rather than timestamps."_ `plz-out` is reused for plain
  incremental builds even with caching off.
- **First-class affected-target queries.** `plz query changes` is the
  CI/monorepo-slicing primitive. From the source ([`src/query/changes.go`][changes]),
  it offers two entry points — `DiffGraphs` (compare two graphs, e.g. across a git
  revision) and `Changes` (a faster current-state-plus-file-list path). It maps a
  changed file to targets by walking up to the nearest package and finding targets
  that claim the file via `HasAbsoluteSource`, compares **rule + source hashes**
  (`targetChanged`) to confirm a real change, then expands to reverse dependencies
  via `FindRevdeps`. A load-bearing comment:

  > _"Note that this is not symmetric; targets that have been removed from 'before'
  > do not appear (because this is designed to be fed into 'plz test' and we can't
  > test targets that no longer exist)."_

  The canonical CI pattern is therefore `plz test $(plz query changes --since <ref>)`
  — build/test only what a diff actually touched, transitively.

- **`plz watch`** re-runs targets on file change for an inner-loop equivalent of
  the affected-target slice.

#### 4. Caching & remote execution

- **Two-tier local + shared cache, all content-addressed.** Caches layer beneath
  `plz-out`. The **directory cache** (`[Cache] Dir`, default `~/.cache/please`) is
  the default, storing artifacts in a local tree that _"allows extremely fast
  rebuilds when swapping between different versions of code (notably git
  branches)."_ Caveat from the docs: it _"is not threadsafe or locked … so sharing
  the same directory between multiple projects is probably a Bad Idea."_
- **HTTP cache for teams.** `[Cache] HttpUrl` points at _"a simple API based on PUT
  and GET to store and retrieve opaque blobs"_ — backed by nginx+WebDAV or CI
  artifact services; `HttpWriteable` controls write-back (read-only by default for
  untrusted clients).
- **Command-driven cache** (`RetrieveCommand`/`StoreCommand`) shells out for
  S3-style backends, streaming tar via stdin/stdout with `CACHE_KEY` in the
  environment. Read-only is configurable; `RetrieveCommand` is mandatory.
- **Artifacts cache only on success** — _"artifacts are only stored in the cache
  after a successful build or test run."_
- **Remote execution via REAPI.** Please speaks the **Remote Execution API**
  (`v2.1`): _"Please makes use of the Remote Execution API to distribute work. This
  is a generic gRPC-based API with a number of options for the server-side."_
  Configured under `[Remote]` (`URL`, `Instance`, `NumExecutors`, `Secure`), it
  works against any REAPI server — `Buildbarn`, `BuildBuddy`, `NativeLink`,
  `BuildGrid` — sharing the same content-addressable
  storage and action cache as Bazel. The `remote_file` rule additionally needs the
  Remote Asset API. The docs are candid that remote execution is _"still
  experimental"_ and _"setting it up can be a reasonable amount of work."_

#### 5. CLI / UX ergonomics

- **Verb + label, with rich wildcards.** The command boundary is uniform:
  `plz build`, `plz test`, `plz run`, `plz cover`, `plz exec` (hermetic-sandbox
  run), `plz watch`, all taking labels with `:all` and `/...` wildcards. `plz run`
  builds-and-executes; `plz test` emits xUnit XML.
- **Label-based language filtering.** `-i/--include` and `-e/--exclude` filter the
  selected set by **labels** (e.g. language tags `go`, `python`, `java`, `cc`),
  with `--exclude` taking priority — so `plz test //... -i go` runs only the `Go`
  tests in the whole tree. This is Please's analogue of [Turborepo][turborepo]'s
  `--filter`/[pnpm][pnpm]'s `-F`, but keyed on graph labels rather than package
  names.
- **`plz query` is the introspection surface.** Subcommands cover the graph:
  `deps`/`reverseDeps`, `changes` (affected targets vs a revision/file set),
  `somepath` (path between two targets), `input`/`output` (transitive files),
  `whatinputs`/`whatoutputs` (file→target mapping), `alltargets`, `graph` (JSON),
  `rules` (machine-readable rule schemas), `print`, and `filter` (apply
  `--include`/`--exclude`).
- **Repo-pinned via `pleasew`.** Because `plz init` commits a `pleasew` wrapper that
  downloads the version named in `.plzconfig`, every contributor and CI runner uses
  the same engine without a global install — a notable ergonomic win over tools
  that assume a system-wide binary.
- **Quality-of-life verbs.** `plz fmt` (buildifier-based `BUILD` formatting),
  `plz init`/`plz init plugin`, `plz update` (self-update to the pinned version),
  `plz op` (re-run the last command), `plz gc` (find unused targets, experimental),
  `-o/--override` for ad-hoc config overrides, and `--profile` for named config
  variants.

---

## Strengths

- **Bazel-class model at a fraction of the weight.** One static `Go` binary, instant
  startup, no mandatory daemon — the content-addressed action graph, sandboxing, and
  REAPI remote execution without the JVM and operational heft of [Bazel][bazel].
- **Programmable but deterministic `BUILD` language.** A restricted `Python` dialect
  loops/branches/factors-out via `subinclude`, yet parses as a pure function so the
  graph stays cacheable — more expressive than declarative TOML/JSON manifests.
- **First-class affected-target slicing.** `plz query changes --since <ref>` feeding
  `plz test` is a built-in, principled CI optimization, computed from real rule and
  source hashes plus reverse-dependency expansion.
- **Self-bootstrapping repos.** The committed `pleasew` wrapper + version pin in
  `.plzconfig` means a clean checkout builds reproducibly with zero global setup.
- **Layered, composable config.** Six-level `.plzconfig` precedence cleanly
  separates machine/user/repo/arch/profile/local overrides.
- **Uniform extension model.** Built-in and user rules use the same language; `v17`
  plugins version language rule-sets independently of the engine.
- **Pinned, hash-verified, license-gated third-party deps** across `Go`/`Python`/
  `Java` via subrepos.

## Weaknesses

- **Smaller ecosystem and integration surface than Bazel/Buck2.** Fewer
  pre-written rules, fewer integrations, a smaller community; remote execution is
  explicitly _"still experimental"_ and fiddly to stand up.
- **No package-manager interop layer.** Unlike language-native tools
  ([Cargo][cargo], [uv][uv], [Go modules][go-work]), adopting Please means writing
  `BUILD` files and re-expressing third-party deps as subrepos — a real migration
  cost; there is no `import the existing manifest` path.
- **Whole-tree workspace, no explicit member curation.** Topology is implicit in
  `BUILD`-file placement; there is no `members` array to scope or partition a repo
  into named sub-workspaces (only `BlacklistDirs` to prune).
- **Directory cache isn't safe to share across projects** (not locked beyond the
  repo lock) — a footgun for multi-checkout setups.
- **Restricted `Python` is still a learning curve**, and a programmable build
  language can hide complexity that pure-data manifests cannot.
- **Single-vendor stewardship.** Primarily driven by Thought Machine; niche outside
  organizations that have adopted it.

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                               | Trade-off                                                                                           |
| ----------------------------------------------------------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| Single `Go` binary, no mandatory daemon (vs Bazel's JVM server)   | Instant startup, easy distribution, "lighter weight" than Bazel                         | Less of a persistent-analysis-cache story than a long-lived server; cold parse each invocation      |
| Repo rooted at a `.plzconfig` marker; whole tree is one workspace | Zero ceremony — no `members` list to maintain; every `BUILD` dir just works             | No explicit sub-workspace scoping; can't easily partition one repo into named member sets           |
| `BUILD` language = restricted `Python` (programs, not data)       | Loops/macros/`subinclude` give power and "a significantly nicer format" than XML/JSON   | A learning curve; programmable builds can hide complexity vs declarative manifests                  |
| Sandboxed actions + input hashing for cache keys                  | Trustworthy, timestamp-free invalidation; aggressive local + remote caching             | Every input must be declared; undeclared-file reads break (intentionally), demanding precise `srcs` |
| Third-party deps as pinned, hash-verified **subrepos**            | Reproducible, license-gated, polyglot dependency fetch with no global package state     | No hoisting/virtual store; must re-express each ecosystem's deps as `BUILD` rules (migration cost)  |
| Language rules as versioned **plugins** (`v17`+)                  | Engine and rule-sets evolve independently; same language for built-in and user rules    | More moving parts to pin; a repo now tracks engine version _and_ a set of plugin versions           |
| REAPI (`v2.1`) for remote cache/execution                         | Reuses the Bazel-ecosystem CAS/action-cache servers (Buildbarn, BuildBuddy, NativeLink) | Remote execution is "still experimental" and "a reasonable amount of work" to configure             |
| `plz query changes --since` as a built-in affected-target slice   | Principled CI optimization from rule+source hashes + reverse-dep expansion              | Asymmetric (removed targets omitted); relies on accurate `srcs` and a clean graph for correctness   |

---

## Sources

- [thought-machine/please — GitHub repository][repo] (README tagline, languages,
  license)
- [please.build — official documentation][docs]
- [Basics: BUILD files, packages, labels, commands][basics]
- [Config reference — `.plzconfig` sections and precedence][config]
- [Caching — directory / HTTP / command-driven caches][cache]
- [Remote execution — REAPI v2.1, `[Remote]` config][remote]
- [How custom build rules work — `genrule`, sandboxing, env vars][build-rules]
- [Third-party dependencies — subrepos, `pip_library`/`maven_jar`/`go_module`][deps]
- [Lexicon — verbatim builtin/rule definitions (`subinclude`, `sandbox`, …)][lexicon]
- [Commands — `plz build/test/run/query`, `--include`/`--exclude`][commands]
- [FAQ — motivation, philosophy, Bazel/Buck comparison, `Go` choice][faq]
- [`src/query/changes.go` — affected-target computation][changes]
- Sibling deep-dives: [Bazel][bazel] · [Buck2][buck2] · [Pants][pants] ·
  [Cargo][cargo] · [Turborepo][turborepo] · [pnpm][pnpm] · [npm][npm] ·
  [Go (`go.work`)][go-work] · [uv][uv]; the umbrella [survey index][umbrella] and
  the [D async/`dub` landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/thought-machine/please
[docs]: https://please.build/
[basics]: https://please.build/basics.html
[config]: https://please.build/config.html
[cache]: https://please.build/cache.html
[remote]: https://please.build/remote_builds.html
[build-rules]: https://please.build/build_rules.html
[deps]: https://please.build/dependencies.html
[lexicon]: https://please.build/lexicon.html
[commands]: https://please.build/commands.html
[faq]: https://please.build/faq.html
[changes]: https://github.com/thought-machine/please/blob/0e61e4eaf5964dd457d1613a3196fb8afcd3ac26/src/query/changes.go
[bazel]: ../bazel/
[buck2]: ../buck2/
[pants]: ../pants/
[cargo]: ../cargo/
[turborepo]: ../turborepo/
[pnpm]: ../pnpm/
[npm]: ../npm/
[go-work]: ../go-work/
[uv]: ../uv/
[umbrella]: ../
[d-landscape]: ../../async-io/d-landscape.md
