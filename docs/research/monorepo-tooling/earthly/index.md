# Earthly (Polyglot / CI)

A container-native build tool whose `Earthfile` reads _"like `Dockerfile` and `Makefile` had a baby"_: every build target runs in a [BuildKit][buildkit] container, targets reference each other's artifacts and images across directories and repositories with a `+target` grammar, and the whole graph is hashed, cached, and executed in parallel — locally or on a remote `Satellite`.

| Field           | Value                                                                                                                                          |
| --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Go (~71% of the engine); Earthfiles are a custom DSL                                                                                           |
| License         | MPL-2.0 (Mozilla Public License 2.0)                                                                                                           |
| Repository      | [`earthly/earthly`][repo]                                                                                                                      |
| Documentation   | [docs.earthly.dev][docs] · [Earthfile reference][earthfile-ref] · [Best practices][best-practices]                                             |
| Category        | Container / CI-Oriented                                                                                                                        |
| Workspace model | **Target graph across many `Earthfile`s** — no workspace-root manifest; topology is the web of `+target` / `./path+target` / remote references |
| First released  | `v0.1.0` line, 2020 (project announced publicly 2020; `v0.5` GA Feb 2021)                                                                      |
| Latest release  | `v0.8.16` (July 16, 2025) — the **final** release                                                                                              |

> **Latest release:** `v0.8.16`, published **July 16, 2025** — the last release.
> Per the [shutdown announcement][shutdown] (April 16, 2025), Earthly Technologies
> _"will no longer be contributing actively to the Earthly open-source project other
> than critical bug fixes,"_ and **Earthly Cloud and Satellites stopped operating on
> July 16, 2025**. `v0.8.16` exists specifically to _"remove all Cloud dependencies,
> commands, and flags as part of the Earthly Cloud shutdown"_ ([`CHANGELOG.md`][changelog]).
> The company pivoted to a proprietary product, **Earthly Lunar**. This survey treats
> Earthly as a **mature, frozen reference design** — its ideas remain influential even
> though the project is no longer developed; the community was asked to _"change the
> name and logo of the project, as well as the name of the CLI command when forking."_

> [!IMPORTANT]
> Earthly is **archived/unmaintained** as of mid-2025. It is included here as a
> _design_ data point — the `+target` cross-`Earthfile` reference model and the
> hash-driven cache-and-parallelize engine are the parts worth studying for `dub`.
> Do not adopt it for new production use without accounting for its frozen status.

---

## Overview

### What it solves

Earthly attacks the same pain as its sibling [Dagger][dagger]: **CI-pipeline drift**,
where a `.github/workflows/*.yml` only runs on the CI provider, can only be debugged by
pushing commits, re-runs the whole world on every change, and re-implements caching
ad-hoc per job. But where Dagger makes the pipeline _"a regular program calling an
API,"_ Earthly keeps a **declarative, file-based DSL** — the `Earthfile` — that is
deliberately a near-superset of `Dockerfile` syntax with `Makefile`-style named targets
layered on top. The positioning line in the [README][repo] is the whole thesis:

> _"Super simple build framework with fast, repeatable builds and an instantly familiar
> syntax – like `Dockerfile` and `Makefile` had a baby."_ — [`earthly/earthly` README][repo]

The promise is **"works on my machine" parity**: because every target executes inside a
container managed by [BuildKit][buildkit] (the solver behind `docker build`), the same
`earthly +test` runs bit-identically on a laptop, in GitHub Actions, and on a remote
runner. Earthly wraps the host's language tooling (`go build`, `npm ci`, `cargo test`,
`dub build`) rather than replacing it — it is an _orchestrator_ of containerized steps,
not a package manager or a compiler.

### Design philosophy

Three commitments, all visible in the syntax, shape everything below:

1. **A target is a containerized recipe with a stable name.** Each named target
   (`build:`, `test:`) is a sequence of `Dockerfile`-like commands (`FROM`, `RUN`,
   `COPY`) executed in an isolated container, invoked from the CLI as `earthly +build`.
   The [Earthfile reference][earthfile-ref] is explicit that the language is
   intentionally familiar: _"Existing `Dockerfile`s can easily be ported to Earthly by
   copying them to an `Earthfile` and tweaking them slightly."_

2. **Targets compose across files and repos by reference.** A target in one `Earthfile`
   pulls an artifact or image from another target — in the same file (`+other`), a
   sibling directory (`./libs/foo+build`), an absolute path, or _another git repository_
   (`github.com/org/repo+target`). This reference web **is** the dependency graph; there
   is no separate workspace manifest enumerating members. This is the mechanism that
   makes Earthly a monorepo tool, and it is the heart of [§1](#_1-workspace-declaration-topology).

3. **The engine hashes, caches, and parallelizes automatically.** Because the substrate
   is BuildKit's content-addressed [LLB][buildkit], _"if an `Earthfile` command is run
   again, and the inputs to that command are the same, then the cache layer is reused"_
   ([Caching in Earthfiles][caching-earthfiles]), and independent targets run
   concurrently with no user annotation.

Within this survey Earthly sits in the **container/CI-oriented** family alongside
[Dagger][dagger] (pipelines-as-code over the same BuildKit substrate) and [Garden][garden]
(Kubernetes-native stack orchestration). It out-scopes the task-runner family
([Task][task], [Just][just], [mise][mise]) by containerizing and caching every step, and
it is orthogonal to the package managers ([Cargo][cargo], [pnpm][pnpm], [dub][d-landscape]):
it resolves no library dependencies and produces no lockfile. For why `dub` has none of
this, see the [D landscape notes][d-landscape].

---

## How it works

### The `Earthfile`: a `VERSION`, a base recipe, and named targets

An `Earthfile` opens with a mandatory `VERSION` (which _"identifies which set of features
to enable"_), then an implicit **base recipe** (commands before the first target, shared
by every target via inheritance), then named targets:

```dockerfile
VERSION 0.8
FROM golang:1.21-alpine3.18
WORKDIR /app

deps:
    COPY go.mod go.sum ./
    RUN go mod download
    SAVE ARTIFACT go.mod AS LOCAL go.mod

build:
    FROM +deps
    COPY main.go .
    RUN go build -o output/server main.go
    SAVE ARTIFACT output/server AS LOCAL build/server

test:
    FROM +deps
    COPY . .
    RUN go test ./...

docker:
    COPY +build/server /usr/bin/server
    ENTRYPOINT ["/usr/bin/server"]
    SAVE IMAGE my-org/server:latest
```

The commands carry their `Dockerfile` meanings, with build-orchestration semantics added
([Earthfile reference][earthfile-ref]):

| Command           | Role                                                                                                                            |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `VERSION`         | Mandatory first line; selects the Earthfile feature set (`0.6`/`0.7`/`0.8`)                                                     |
| `FROM`            | Sets the base image **or inherits another target's environment** (`FROM +deps`, `FROM ./sub+target`, `FROM github.com/x/y+t`)   |
| `RUN`             | Executes a command in a new layer (cached on input hash)                                                                        |
| `COPY`            | Classical form copies from build context; **artifact form** `COPY +build/server .` copies an artifact out of another target     |
| `SAVE ARTIFACT`   | Marks a file as the target's output artifact; `AS LOCAL <path>` writes it to the host (only if reached through a `BUILD` chain) |
| `SAVE IMAGE`      | Tags the current environment as the target's Docker image; `--push` marks it for registry push                                  |
| `BUILD`           | Explicitly invokes another target so its `SAVE`d outputs/pushes are realized (see below)                                        |
| `ARG`             | A build argument with optional default; `--required`/`--global`; overridable from the CLI as `--name=value`                     |
| `IMPORT`          | Aliases an `Earthfile` reference for reuse (`IMPORT ./libs/foo AS foo` → `foo+build`)                                           |
| `FROM DOCKERFILE` | Builds from an existing `Dockerfile` instead of Earthfile commands                                                              |
| `CACHE`           | Declares a persistent cache mountpoint shared across runs of the target (`--sharing locked\|shared\|private`)                   |
| `WAIT`            | Brackets commands that must complete (incl. pushes / local outputs) before the build continues                                  |
| `LOCALLY`         | Runs commands on the host instead of in a container (never cached; only `RUN`/`COPY`/`SAVE ARTIFACT`)                           |

### `+target` references and the implicit DAG

The defining mechanism is the **`+target` reference grammar**. A target is named
`+build`; an artifact it `SAVE`s is `+build/output/server`; and the target reference can
be qualified by location ([Earthfile reference][earthfile-ref]):

```dockerfile
COPY +build/server .                 # artifact from a target in THIS Earthfile
COPY ./libs/parser+build/lib.a .     # artifact from a target in a sibling directory
COPY /abs/path+build/x .             # absolute-path target
FROM github.com/org/utils:v1+image   # target in a REMOTE git repository, pinned to a tag
```

Each such reference is an **edge in the build DAG**. Earthly infers dependency order
from data flow: if `+docker` does `COPY +build/server`, then building `+docker` builds
`+build` first, with no explicit ordering. The best-practices guide states it plainly:

> _"Notice also that in our `+all` target, we no longer have to call both `+dep` and
> `+build`. The system will automatically infer that when building `+build`, `+dep` is
> also required."_ — [Best practices][best-practices]

`BUILD` vs. `FROM`/`COPY` is a subtle but central distinction. `FROM +t` and `COPY +t/a`
**consume** another target's environment or artifact, but they do **not** propagate that
target's _local outputs_ or _pushes_. Only a chain of `BUILD` commands does — the docs
note that _"local artifacts are only saved if they are connected to the initial target
through a chain of `BUILD` commands,"_ and likewise for `SAVE IMAGE`. So a top-level
aggregator target uses `BUILD` to fan out, while leaf targets use `FROM`/`COPY` to wire
data:

```dockerfile
all:
    BUILD +build          # consecutive BUILDs of independent targets run in PARALLEL
    BUILD +test
    BUILD ./libs/parser+build
```

### The engine: BuildKit and LLB

Earthly does not run containers itself. The CLI (`earthly`) talks to a **BuildKit
daemon** — `earthly-buildkitd`, started automatically as a container unless
`--buildkit-host` points at a remote one. Each Earthfile target is compiled into
BuildKit's **Low-Level Build (LLB)** graph and handed to BuildKit's solver, which
executes vertices in parallel and caches them by content hash. This is the same solver
that backs `docker build` and that [Dagger][dagger] also forks — the two tools share a
substrate and diverge only in the authoring surface (declarative DSL vs. SDK code).

The five dimensions below place this model against the rest of the catalog.

### 1. Workspace declaration & topology

Earthly has **no workspace-root manifest**. There is no `[workspace]` table
([Cargo][cargo]), no `pnpm-workspace.yaml` ([pnpm][pnpm]), no `go.work` ([go-work][go-work])
enumerating members, and — by deliberate design — **no way to centralize all build logic
in one file**. The best-practices guide is explicit on both points:

> _"Place lower-level build logic closer to the code that it is building. This can be
> achieved by splitting Earthly builds across multiple `Earthfile`s, and placing some of
> the `Earthfile`s deeper inside the directory structure."_ — [Best practices][best-practices]

> _"Earthly does not support placing all `Earthfile`s in a single directory."_
> — [Best practices][best-practices]

So **topology is emergent from the reference web**, exactly like [Dagger][dagger]'s module
graph. The recommended monorepo layout scatters an `Earthfile` next to each component,
_"with some high-level targets exposed in the root of the repository,"_ and a root
`Earthfile` ties them together with `BUILD ./component+target`. Earthly's own repository
is the canonical example: `Earthfile`s live under `ast/parser`, `buildkitd`, `tests`,
etc., with a main `Earthfile` aggregating them.

Discovery is therefore **by reference, not by glob**: a component is "in the workspace"
once some other target references `./that-component+something`. (Earthly 0.8 added an
experimental `--wildcard-builds` flag so a `BUILD ./services/*+deploy` glob can fan out,
but this is the exception, not the declaration model.)

> [!NOTE]
> The flip side of "no member manifest" is the same as Dagger's: Earthly does not _know_
> your whole repo the way [Nx][nx] or [Bazel][bazel] do. It knows the graph you wired by
> hand with `+target` edges. There is no single source of truth listing the members.

### 2. Dependency handling & isolation

Two notions of "dependency" coexist; keeping them apart is essential:

- **Target dependencies (Earthly's own).** A `+target` / `./path+target` /
  `github.com/...+target` reference is the unit of cross-component dependency. Earthly's
  is unusually strong here: a target reference may point at **another git repository**,
  pinned to a tag, so a build can pull a prebuilt artifact or base image from an upstream
  repo's `Earthfile` without that repo publishing to any registry — Earthly clones and
  builds the referenced target on demand. `IMPORT ./libs/foo AS foo` aliases such a
  reference for reuse. This is the **cross-repo local reference** capability that, in the
  package-manager world, only [Yarn Berry][yarn-berry]'s `workspace:` protocol and Cargo
  `path =` approximate — and Earthly extends it _across repository boundaries_.

- **Language-level dependencies (your app's `npm`/`pip`/`cargo`/`dub` packages).** These
  are **not** Earthly's concern. They are resolved inside a container by the language's
  own tool (`RUN go mod download`, `RUN dub upgrade`). **Isolation is the container
  filesystem itself** — there is no hoisting, no symlinked store, no virtual content-addressed
  package store. Each target sees only what its `COPY` commands and `FROM` base put into
  its container. Package-manager downloads are kept warm across runs with **cache mounts**
  (next section), not a shared on-disk store.

This is the same posture as [Dagger][dagger]: the container boundary _is_ the isolation
model, and the "store" question that dominates the JS/TS tools ([pnpm][pnpm] hard-link
store, [Yarn Berry][yarn-berry] PnP zip store) simply does not arise.

### 3. Task orchestration & scheduling

Orchestration is Earthly's strongest dimension and is **structural** — the DAG falls out
of references rather than being declared in a task list (no `turbo.json` `dependsOn`
[Turborepo][turborepo], no `BUILD` rule graph [Bazel][bazel]):

- **The DAG is implicit from `+target` edges.** Every `FROM`/`COPY`/`BUILD` reference is
  an edge; the solver topologically orders them. The user never writes "X depends on Y" —
  it is encoded in the `COPY +Y/artifact` line.

- **Parallelism is automatic.** _"Multiple consecutive `BUILD` commands execute in
  parallel if targets don't depend on each other,"_ and likewise _"multiple consecutive
  `COPY` commands build referenced targets in parallel"_ ([Earthfile reference][earthfile-ref]).
  Concurrency is a property of the engine, not a `--jobs N` flag (BuildKit's own
  parallelism governs how many vertices run at once). The `WAIT` block is the explicit
  _barrier_ primitive when ordering (e.g. "push the image only after tests pass") must be
  forced.

- **Change detection is input hashing, with an opt-in affected-skip.** By default,
  Earthly does **not** compute an affected set from a git ref (no `--since`/`--affected`
  like [Turborepo][turborepo]/[Nx][nx]). Instead, like [Dagger][dagger], unchanged work is
  skipped _emergently_ via the layer cache — a target whose inputs hash the same replays
  from cache near-instantly. **Auto-skip** (`earthly --auto-skip`, or per-target
  `BUILD --auto-skip`, both experimental) closes the gap explicitly: it hashes _all_
  inputs of a target into a single key and, if unchanged, skips the entire target without
  even consulting the layer cache. It is **all-or-nothing** — _"Either the entire target
  is skipped, or none of it is"_ — and, unlike the layer cache, _"the auto-skip cache is
  global and is stored in a cloud database"_ ([Managing cache][managing-cache]), which is
  why it depended on Earthly Cloud and has caveats around dynamic `ARG`s, dynamic `COPY`
  targets, and unpinned remote references.

### 4. Caching & remote execution

Caching is the engine's reason for existing, and it spans three layers:

- **Layer cache (automatic).** Per-command, content-addressed, exactly like `docker
build`: _"If any file included in a `COPY` changes, then the build will continue from
  that `COPY` command onwards"_ ([Caching in Earthfiles][caching-earthfiles]). Inputs to
  a command are the `ARG` values, the `COPY`'d files, and the command text; change any and
  the layer (and everything after it) re-runs.

- **Cache mounts (explicit).** Two forms keep package-manager state warm:
  `RUN --mount=type=cache` (mounted only for that one `RUN`, **not** persisted into the
  image) and the higher-level **`CACHE`** command (mounted for every following `RUN` in
  the target, contents copied into the final image), with `--sharing locked|shared|private`
  governing concurrent access. These are the BuildKit persistent-cache-dir primitive,
  the same one behind `RUN --mount=type=cache` in a `Dockerfile`.

- **Remote / shared cache (two strategies).** Cache transport across machines/CI runs is
  registry-based: _"Remote caching is made possible by storing intermediate steps of a
  build in a cloud-based Docker registry"_ ([Remote caching][remote-caching-06]).
  - **Inline cache** — _"the easiest to configure … makes use of any image already being
    pushed to the registry"_; enabled with `--ci` or `--use-inline-cache`, written with
    `earthly --ci --push +target`.
  - **Explicit cache** — a dedicated cache image tag:
    `earthly --ci --remote-cache=mycompany/myimage:cache --push +some-target`, with
    `SAVE IMAGE --cache-hint` marking extra targets and `--max-remote-cache` saving _all_
    intermediate steps (_"results in large uploads and is usually not very effective"_).

**Remote execution** is via **Earthly Satellites** — _"remote runners that work
seamlessly with Earthly, using persistent cache to improve build times"_
([Satellites][satellites]). A Satellite is a managed remote BuildKit instance; you select
it with `earthly --sat <name> +target`, `earthly sat launch`, or `EARTHLY_SATELLITE`.
Its decisive advantage over registry caching is that there is no upload/download step:
_"The same cache is used between runs on the same satellite, so parts that haven't changed
do not repeat,"_ and _"most CI build times are improved by 2-20X with Satellites."_

> [!IMPORTANT]
> Satellites and the auto-skip cloud cache were the **commercial** half of Earthly and
> **stopped working on July 16, 2025**. The open-source CLI retains the registry-based
> remote cache (`--remote-cache`, inline cache) and the layer/cache-mount layers, which
> need no Earthly-hosted service — only a Docker registry and (optionally) a self-hosted
> remote BuildKit via `--buildkit-host`.

Earthly does **not** speak the [Remote Execution API (REAPI)][bazel] that
[Bazel][bazel]/[Buck2][buck2] backends like [Buildbarn][buildbarn]/[NativeLink][nativelink]
implement. Its remote story is BuildKit-registry cache transport plus managed-BuildKit
runners (Satellites) — _not_ REAPI-style distributed action farming.

### 5. CLI / UX ergonomics

The command boundary is **target-centric**, and the `+target` grammar that wires the DAG
is the same grammar the CLI uses to launch a build ([`earthly` command reference][earthly-command]):

- **`earthly +target`** runs a target in the local `Earthfile`;
  **`earthly ./path/to/dir+target`** runs one elsewhere (the path must start with `./`,
  `../`, or `/`); **`earthly github.com/org/repo+target`** runs a remote target. This is
  the colon-target analogue — Earthly's `+` plays the role of [Bazel][bazel]'s `:` or a
  package filter, but it selects a _target_, not a package, and the "which component"
  question is answered by the **path you point at**, not a `--filter pkg...` flag.
- **`earthly --artifact ./dir+target/path dest`** extracts a specific artifact;
  **`earthly --image +target`** builds just the image.
- **Build args** pass as `earthly +target --MY_ARG=value` (or via `EARTHLY_BUILD_ARGS`,
  or a `.arg` file), mapping onto the target's `ARG` declarations.
- **`--ci`** is the CI ergonomics shortcut: in target mode it aliases
  `--no-output --strict`; **`--push`** realizes `SAVE IMAGE --push` and `RUN --push`;
  **`-P`/`--allow-privileged`** permits `RUN --privileged`; **`--no-cache`** ignores the
  cache; **`-i`/`--interactive`** drops you into a shell at a failed `RUN` for live
  debugging.
- **`--sat`/`--satellite`** selects a remote runner; **`--buildkit-host`** points at any
  BuildKit daemon; **`--auto-skip`** (experimental) skips unchanged targets.

There is **no `--filter`, `-p`, or `--since`** package-selection vocabulary. The selection
unit is _which target at which path_ you invoke — the inverse of [Turborepo][turborepo] /
[pnpm][pnpm] ergonomics, and a direct consequence of the build graph being a web of
file-path-qualified target references rather than a declared package set. This is the
same trade-off [Dagger][dagger] makes, with Earthly's `+target` being slightly more
filter-like than Dagger's function/path selection because a path can address a whole
subdirectory's `Earthfile`.

---

## Strengths

- **`Dockerfile`/`Makefile` familiarity, zero new programming model.** The DSL is
  instantly readable to anyone who knows `Dockerfile`; existing `Dockerfile`s port over
  almost verbatim. Lower barrier than [Dagger][dagger]'s SDK-code model.
- **Local ≡ CI by construction.** Every target runs in a BuildKit container, so
  `earthly +test` behaves identically on a laptop and in CI — the headline value over
  YAML pipelines and over task runners ([Task][task]/[Just][just]).
- **Cross-`Earthfile` and cross-repo references.** `+target`, `./path+target`, and
  `github.com/org/repo+target` give first-class local-and-remote composition — including
  pulling a prebuilt artifact from another repository's target without publishing it to a
  registry. Stronger than most package managers' `workspace:`/`path =` (which stay
  intra-repo).
- **Automatic hashing, caching, and parallelism.** Inherited from BuildKit/LLB — no
  bespoke task hasher, no `--jobs` tuning; independent `BUILD`s run concurrently for free.
- **Cache mounts keep package managers warm** (`CACHE`, `RUN --mount=type=cache`) without
  a shared on-disk store.
- **Strong remote-cache & remote-runner story** (registry inline/explicit cache;
  Satellites' "cache is always there" 2–20× speedup) — _when the hosted service existed_.

## Weaknesses

- **No longer maintained.** Archived in 2025; Cloud/Satellites/auto-skip cloud cache
  decommissioned July 16, 2025. A frozen design, not a live tool.
- **Not a package manager or build system.** Resolves no library dependencies, emits no
  lockfile, has no workspace-root manifest — orthogonal to [Cargo][cargo]/[dub][d-landscape]/[pnpm][pnpm].
  It offers _orchestration_ patterns, not _manifest_ primitives.
- **No declarative workspace topology.** Structure is hand-wired `+target` edges; there is
  no member glob (only an experimental `--wildcard-builds`), no single "build everything
  that changed" query, and no git-ref affected set (`--since`/`--affected`). Change
  detection is emergent from caching plus opt-in cloud-backed auto-skip.
- **A BuildKit daemon is required.** Every run needs `earthly-buildkitd` (a container) or
  a remote BuildKit — a heavier footprint than a static task runner, and `LOCALLY`
  escapes the container model (and caching) entirely.
- **Best remote features were commercial and are gone.** Satellites and the cloud auto-skip
  cache (the differentiators) are decommissioned; the OSS CLI keeps only registry-based
  remote cache.
- **Everything is a container.** Even trivial steps pay container semantics; tasks that
  want host access must use `LOCALLY`, which never caches.

## Key design decisions and trade-offs

| Decision                                                         | Rationale                                                                                 | Trade-off                                                                                                  |
| ---------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Declarative `Earthfile` DSL (`Dockerfile`+`Makefile`)            | Instantly familiar; `Dockerfile`s port over; lower barrier than pipelines-as-code         | Less expressive than a real language (cf. [Dagger][dagger]); abstraction via `ARG`/`IMPORT`, not functions |
| Topology = web of `+target` references (no workspace root)       | Build logic lives next to code; cross-`Earthfile` and **cross-repo** composition for free | No member-enumerating manifest, no whole-repo view; topology is hand-wired, not globbed                    |
| `BUILD` chains realize outputs; `FROM`/`COPY` only consume       | Separates "wire data into me" from "and also emit this target's artifacts/pushes"         | Subtle footgun: a `COPY +t/a` won't produce `+t`'s `AS LOCAL`/`--push` side effects unless `BUILD`-chained |
| BuildKit/LLB content-addressed DAG as the substrate              | Automatic per-command caching and parallelism come free, identical local↔CI               | A BuildKit daemon must run; everything is a container op, even trivial steps                               |
| Container filesystem as the only isolation (no store/hoisting)   | Reuses Docker isolation; the JS/TS "store" problem never arises                           | Re-resolves language deps per container unless cache-mounted; no shared on-disk package store              |
| Change detection via layer cache + opt-in cloud auto-skip        | Unchanged targets replay near-instantly; auto-skip can skip a whole target                | No git-ref affected query (`--since`/`--affected`); auto-skip needed Earthly Cloud and is now defunct      |
| Remote cache via Docker registry; remote exec via Satellites     | Reuses registry transport; Satellites give "cache always there" 2–20× CI speedup          | Not REAPI; best remote features were commercial and shut down July 2025                                    |
| Target-centric CLI (`earthly ./path+target`), no `--filter`/`-p` | The DAG grammar doubles as the launch grammar; one uniform surface                        | "Which component" is encoded in the path, not a discoverable package-filter flag                           |

---

## Sources

- [`earthly/earthly` — GitHub repository (README, MPL-2.0, Go engine, tagline)][repo]
- [Earthly documentation — docs.earthly.dev][docs]
- [Earthfile reference — `VERSION`/`FROM`/`BUILD`/`COPY`/`SAVE`/`CACHE`/`WAIT`/`LOCALLY`, `+target` grammar][earthfile-ref]
- [Best practices — monorepo/polyrepo layout, splitting Earthfiles, inferred dependencies][best-practices]
- [Caching in Earthfiles — layer cache, input hashing, cache mounts][caching-earthfiles]
- [Managing cache — auto-skip cloud cache, all-or-nothing target skip, limitations][managing-cache]
- [Remote caching (0.6) — inline vs. explicit cache, `--remote-cache`, registry transport][remote-caching-06]
- [Earthly Satellites — managed remote BuildKit runners, persistent shared cache, 2–20× claim][satellites]
- [`earthly` command reference — target/artifact/image invocation, `--ci`, `--push`, `--sat`, `--auto-skip`][earthly-command]
- [A message about Earthly — shutdown announcement, April 16 2025; Cloud off July 16 2025][shutdown]
- [`CHANGELOG.md` — `v0.8.16` (July 16 2025): "Removed all Cloud dependencies …"][changelog]
- [BuildKit — the LLB solver Earthly builds on][buildkit]
- Sibling tools: [Dagger][dagger] · [Garden][garden] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] · [Buck2][buck2] · [Cargo][cargo] · [`go.work`][go-work] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Task][task] · [Just][just] · [mise][mise] · [Buildbarn][buildbarn] · [NativeLink][nativelink]
- D context: [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/earthly/earthly
[docs]: https://docs.earthly.dev/
[earthfile-ref]: https://docs.earthly.dev/docs/earthfile
[best-practices]: https://docs.earthly.dev/docs/guides/best-practices
[caching-earthfiles]: https://docs.earthly.dev/docs/caching/caching-in-earthfiles
[managing-cache]: https://docs.earthly.dev/docs/caching/managing-cache
[remote-caching-06]: https://docs.earthly.dev/earthly-0.6/docs/remote-caching
[satellites]: https://docs.earthly.dev/earthly-cloud/satellites
[earthly-command]: https://docs.earthly.dev/docs/earthly-command
[shutdown]: https://earthly.dev/blog/shutting-down-earthfiles-cloud/
[changelog]: https://github.com/earthly/earthly/blob/6e641c15d3b4d7dd396363b61d2381faa2658f3d/CHANGELOG.md
[buildkit]: https://github.com/moby/buildkit
[dagger]: ../dagger/
[garden]: ../garden/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[yarn-berry]: ../yarn-berry/
[task]: ../task/
[just]: ../just/
[mise]: ../mise/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
