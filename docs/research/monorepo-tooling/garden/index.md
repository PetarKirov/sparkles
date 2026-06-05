# Garden (Polyglot / CI)

A Kubernetes-native development and CI automation tool: you describe every part of
your system — builds, deploys, tests, and ad-hoc runs — as declarative `Build`,
`Deploy`, `Test`, and `Run` _actions_ in `garden.yml` files (spread across the repo
and even across repositories), and Garden assembles them into a dependency-aware
**Stack Graph** that it executes with graph-aware, version-hashed result caching so
the same image is never built twice and the same test never re-runs twice.

| Field           | Value                                                                                                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | TypeScript (~97% of `garden-io/garden`); Garden Core ships as a standalone binary                                                                                           |
| License         | Mozilla Public License 2.0 (`MPL-2.0`)                                                                                                                                      |
| Repository      | [`garden-io/garden`][repo]                                                                                                                                                  |
| Documentation   | [docs.garden.io][docs] · [Stack Graph][stackgraph] · [Graph execution internals][graphexec]                                                                                 |
| Category        | Container / CI-Oriented                                                                                                                                                     |
| Workspace model | **Action graph (Stack Graph)** — config files scanned repo-wide (and across remote sources) into one graph of `Build`/`Deploy`/`Test`/`Run` actions; no single member array |
| First released  | `0.1`, 2018 (open-sourced); the action-based `garden.io/v2` model is the `0.13`+ "Bonsai/Acorn" line                                                                        |
| Latest release  | `0.14.20` (February 27, 2026)                                                                                                                                               |

> **Latest release:** `0.14.20`, published February 27, 2026. The current config
> schema is `apiVersion: garden.io/v2`. Garden's pivot from the older _modules +
> services/tasks/tests_ model (`0.12` "Acorn") to the flat **action** model
> (`Build`/`Deploy`/`Test`/`Run`, `0.13` "Bonsai" onward) is the most important recent
> change — this deep-dive describes the action model. Garden Core is _"a standalone
> binary that can run from CI or from a developer's machine"_ ([repo][repo]); the
> optional [Garden Cloud][cloud] layer adds the [Remote Container Builder][rcb] and
> team-wide test/run caches.

> [!IMPORTANT]
> This is `garden-io/garden`, the Kubernetes development/CI automation tool — **not**
> any of the unrelated "garden" projects (gardening games, the `gardener` Kubernetes
> cluster-management project, etc.). Within this survey it is the
> **Kubernetes-native** sibling of the container/CI tools [Dagger][dagger] (a
> GraphQL/BuildKit pipeline engine) and [Earthly][earthly] (a `Dockerfile`-derived
> target DSL).

---

## Overview

### What it solves

Like its category siblings [Dagger][dagger] and [Earthly][earthly], Garden is **not**
a package manager or a language build system. It does not resolve library
dependencies, produce a lockfile, install a `node_modules`, or compile your code
directly — it sits one level up, orchestrating the _builds, deploys, and tests_ of a
multi-component system. Where Garden differs from Dagger and Earthly is its center of
gravity: it is **Kubernetes-native**. Its reason for existing is to make a
production-like Kubernetes environment cheap to spin up on demand and identical across
a developer laptop, CI, and production. The README states the scope plainly:

> _"Automation for Kubernetes development and testing. Spin up production-like
> environments for development, testing, and CI on demand. Use the same configuration
> and workflows at every step of the process. Speed up your builds and test runs via
> shared result caching."_ — [`garden-io/garden` README][repo]

The pain it targets is the **dev/CI/prod configuration triplication** common to
Kubernetes shops: a `docker-compose.yml` for local dev, a pile of `Dockerfile`s and
`kubectl`/`helm` invocations wired into a CI YAML, and a third set of manifests for
production — three descriptions of one system that drift apart. Garden replaces that
with a single declarative description (the Stack Graph) that is _"portable"_ across
environments, plus an engine that caches builds and test results so large stacks
stay fast. Self-described:

> _"Garden is a DevOps automation tool for developing and testing Kubernetes apps
> faster."_ — [What is Garden][what]

### Design philosophy

The core idea is the **Stack Graph**: a single dependency-aware graph that ties
together every action needed to build, deploy, and test the whole system, collected
from config scattered across the repo (and across repos) rather than centralized.

> _"Garden collects all of these descriptions, even across multiple repositories,
> into the Stack Graph—an executable blueprint for going from zero to a running system
> in a single command."_ — [What is Garden][what]

Three consequences flow from this and shape everything below:

1. **Everything is an action of one of four kinds.** A unit of work is a `Build`,
   `Deploy`, `Test`, or `Run` action declared in YAML. _"Each of the four action
   kinds (Build, Deploy, Test, Run) has a corresponding command that you can run with
   the Garden CLI"_ ([What is Garden][what]). The graph's edges are dependencies
   between actions, written as `<kind>.<name>` strings.
2. **The graph is version-hashed, so caching is dependency-aware.** Garden computes a
   _Garden version_ for every action from its source files, configuration, **and the
   versions of its upstream dependencies**. Because of this, _"the same image never
   needs to be built twice or the same test run twice"_ ([What is Garden][what]) — a
   test re-runs only if its own sources or an upstream dependency changed.
3. **Pluggable execution, Kubernetes-first.** _How_ an action runs is delegated to a
   plugin. The `kubernetes`/`local-kubernetes` plugins are the flagship (build images,
   apply manifests, run pods); `container`, `exec`, `helm`, `terraform`, and `pulumi`
   plugins cover the rest. The graph is plugin-agnostic; the plugins make it concrete.

Within this survey Garden is the canonical **Kubernetes-native container/CI** data
point; compare it with [Dagger][dagger] (pipelines as code over a BuildKit/GraphQL
DAG, no workspace manifest) and [Earthly][earthly] (`Earthfile` targets), and with the
heavyweight polyglot engines [Bazel][bazel]/[Buck2][buck2] whose action graph + remote
caching it echoes at a much higher, container-shaped granularity. For why `dub` has no
analogue of any of this, see the [D landscape notes][d-landscape].

---

## How it works

A Garden project is a tree of YAML config files. One file declares the **project**
(`kind: Project`); the rest declare **actions** (`kind: Build`/`Deploy`/`Test`/`Run`),
which Garden discovers by scanning the repository.

### The project config and config discovery

A project is rooted by a `project.garden.yml` (any `*.garden.yml` / `garden.yml`
works) at the repo root:

```yaml
apiVersion: garden.io/v2
kind: Project
name: my-project
environments:
  - name: dev
  - name: ci
providers:
  - name: local-kubernetes
    environments: [dev]
  - name: kubernetes
    environments: [ci]
    context: my-ctx
```

Garden then **scans the repository for action configs**. They need not live in one
file: _"These actions can be spread across the repo in their own config files, often
located next to the thing they describe"_ ([Basics][basics]). Crucially, discovery is
**not** a member array — there is no `members = ["libs/*"]` glob enumerating
sub-packages the way [Cargo][cargo]'s `[workspace]`, [`go.work`][go-work], or
[pnpm][pnpm]'s `pnpm-workspace.yaml` have one. Garden _"is very flexible and will work
with whatever structure you currently have. It even works across git repositories!"_
([Basics][basics]) — the topology is the **graph of actions it finds**, not a declared
list of directories.

### Actions and the `<kind>.<name>` dependency grammar

An action declares its kind, a plugin `type`, a `name` unique within its kind, and its
`dependencies`. A container `Build`:

```yaml
kind: Build
type: container
name: api
include:
  - 'src/**/*'
  - 'Dockerfile'
spec:
  dockerfile: Dockerfile
```

A `Deploy` that depends on that build and on a database deploy, and a `Test` that
depends on the deploy being up:

```yaml
kind: Deploy
type: kubernetes
name: api
dependencies: [build.api, deploy.db]
---
kind: Test
type: container
name: api-integ
build: api
dependencies: [deploy.api]
spec:
  args: ['npm', 'run', 'test:integ']
```

Dependencies are the literal strings `build.api`, `deploy.db`, `deploy.api` — _"a
`<kind>.<name>` string, where kind is one of build, deploy, run or test"_. Actions can
also reference each other's **outputs** via template strings such as
`${actions.build.api.outputs.deployment-image-name}`, and Garden _"automatically
detects"_ those implicit references during preprocessing and adds the corresponding
graph edges ([Graph execution][graphexec]). Because tests are first-class graph nodes,
Garden _"will re-run the test if any of the upstream services under test are
modified"_ ([What is Garden][what]) — and only then.

### The `GraphSolver`: from config to executed graph

Internally the engine is the **`GraphSolver`**, organized as _"Solver > Nodes >
Tasks"_ ([Graph execution][graphexec]). Each action becomes a task of one of four
classes — **`BuildTask`**, **`DeployTask`**, **`TestTask`**, **`RunTask`** — plus
internal `ResolveActionTask`/`ResolveProviderTask` tasks that resolve config and
provider state first. The solver wraps each task in a node and executes:

| Node type         | Runs                          | Purpose                                    |
| ----------------- | ----------------------------- | ------------------------------------------ |
| `RequestTaskNode` | (root)                        | A task the user requested on the CLI       |
| `StatusTaskNode`  | the task's `getStatus` method | "Is an up-to-date result already present?" |
| `ProcessTaskNode` | the task's `process` method   | Actually build / deploy / test / run       |

The defining mechanism is the **`getStatus` / `process` split**. Before doing any
work, the solver runs `getStatus`:

> _"If an up-to-date result is available, the `getStatus` method will return a status
> with `state: 'ready'`, which indicates to the solver that the task doesn't need to be
> processed."_ — [Graph execution][graphexec]

That is the cache check, and it is **dependency-aware** because _"the action version
is calculated in a dependency-aware fashion"_ ([Graph execution][graphexec]). The
execution flow is explicitly:

1. wrap tasks in nodes;
2. **skip nodes whose `getStatus` reports `ready`**;
3. build a dependency graph from the pending nodes;
4. process leaf nodes **up to a concurrency limit**;
5. mark nodes complete and save results.

Dependencies come in two flavors: **status dependencies**
(`resolveStatusDependencies`, needed before a status check — e.g. an action must be
resolved before its status is known) and **process dependencies**
(`resolveProcessDependencies`, needed before execution), following the principle to
_"use the cheapest / least processed type of task that's required to satisfy the
dependency"_ ([Graph execution][graphexec]). The solver's `loop`/`ensurePendingNodes`
mutate the active node set in **synchronous** code _"by design — by only updating the
active nodes in synchronous code, we prevent race conditions"_ ([Graph
execution][graphexec]).

The five dimensions below locate this model relative to the rest of the catalog.

### 1. Workspace declaration & topology

Garden has **no member-enumerating workspace root**. There is no glob array of
sub-packages; the project config (`kind: Project`) declares environments and providers,
not members. Instead, **topology is the discovered action graph**: Garden scans the
repository for `*.garden.yml` files, reads every `Build`/`Deploy`/`Test`/`Run` action,
and wires them together by their `<kind>.<name>` dependency strings and implicit
output references into the **Stack Graph**.

Two properties make this distinctive among the catalog:

- **Co-located, scattered config.** Action configs _"can be spread across the repo in
  their own config files, often located next to the thing they describe"_
  ([Basics][basics]). A monorepo's structure is implicit in _where the configs are_ and
  _how they depend on each other_, not in a central manifest.
- **Cross-repository projects via remote sources.** Garden explicitly supports a
  project whose components live in **different git repositories**: _"It even works
  across git repositories! You can e.g. have your service source code in one repo and
  manifests in another"_ ([Basics][basics]). A project lists **remote sources** —
  each a `name` plus a `repositoryUrl` pinned with a `#branch-or-tag` suffix — and
  Garden clones them into one logical Stack Graph. The `garden link source` /
  `garden link action` commands swap a remote source for a local checkout so you can
  edit it in place ([Remote sources][remotesources]).

```yaml
# Project config — pulling in components from other repositories
kind: Project
name: my-project
sources:
  - name: web-services
    repositoryUrl: https://github.com/org/web-services.git#main
  - name: db-services
    repositoryUrl: https://github.com/org/db-services.git#v1.2.0
```

> [!NOTE]
> This is the opposite end of the spectrum from a [`go.work`][go-work] `use` list or a
> [Cargo][cargo] `members` glob. Garden does not declare a closed set of members; it
> _discovers_ actions wherever their configs are and unifies them — including across
> repos — into one graph. The trade-off is that "what is in my workspace?" has no
> single-file answer; you read the graph (`garden get graph`, `garden summary`).

### 2. Dependency handling & isolation

Two dependency notions coexist and must not be conflated:

- **Action dependencies (Garden's own).** The `dependencies: [build.api, deploy.db]`
  edges and implicit `${actions.*.outputs.*}` references that define graph order.
  These are the only "dependencies" Garden itself resolves — between _actions_, not
  between library packages.
- **Language/library dependencies (your app's).** Garden does **not** resolve these.
  Your `npm`/`pip`/`go`/`cargo` packages are installed _inside_ the build, by whatever
  tool the `Dockerfile` or build action invokes. Isolation is therefore the
  **container/Kubernetes boundary**, not a hoisted `node_modules`, an isolated symlink
  tree ([pnpm][pnpm]), or a virtual content-addressed store ([Yarn Berry][yarn-berry]).
  There is no equivalent of Yarn's `workspace:` protocol _for libraries_ — the
  "local-first cross-reference" Garden offers is between **actions** (one action
  depending on another, or a remote source linked to a local path), not between
  versioned packages.

**Build isolation** is configurable per the `kubernetes` plugin's `buildMode`. By
default the local Docker daemon builds images; you can instead build _in the cluster_
to share caches across the team:

> _"By default your local Docker daemon is used, but you can set it to
> `cluster-buildkit` or `kaniko` to sync files to the cluster, and build container
> images there. This removes the need to run Docker locally, and allows you to share
> layer and image caches between multiple developers, as well as between your
> development and CI workflows."_ — [In-cluster building][incluster]

| `buildMode`        | What it does                                                     | Cache sharing                         |
| ------------------ | ---------------------------------------------------------------- | ------------------------------------- |
| `local-docker`     | Build with the local Docker daemon, then push to the registry    | Local only                            |
| `cluster-buildkit` | One BuildKit deployment per project namespace, builds in-cluster | Shared across devs + CI (recommended) |
| `kaniko`           | One Kaniko pod per build, in-cluster                             | Shared via registry/layer cache       |

### 3. Task orchestration & scheduling

Orchestration is Garden's strongest dimension, and it is genuinely **graph-structured**
(unlike [Dagger][dagger], where the DAG is implicit in data flow, or a `turbo.json`
task list). The Stack Graph **is** the task DAG:

- **Explicit, typed DAG.** Every action is a node; every `dependencies` entry and
  every `${actions.*}` output reference is an edge. The `GraphSolver` topologically
  orders them and _"processes leaf nodes up to a concurrency limit"_ — concurrent
  execution of independent legs is built in, bounded by a configurable parallelism
  cap ([Graph execution][graphexec]).
- **Change detection via version hashing, not git-diff.** Garden computes a _Garden
  version_ for each action: _"these are the Garden versions that are computed for each
  action in the Stack Graph at runtime, based on source files and configuration for
  each action"_ ([FAQ][faq]), folding in upstream dependency versions. A `Deploy`'s
  version can differ from its `Build`'s because _"the Deploy's version also factors in
  the runtime configuration for that deploy, which often differs between
  environments"_ ([FAQ][faq]). `include`/`exclude` globs on an action scope exactly
  which files feed its hash, so unrelated edits don't bust it.
- **Status-first execution = affected-detection emerges from caching.** Because every
  task runs `getStatus` before `process`, a `garden deploy` or `garden test` over the
  whole graph **skips** every action whose version already has a `ready` result. There
  is no separate `--affected`/`--since <ref>` git query ([Turborepo][turborepo],
  [Nx][nx]); the "affected set" is whatever the version hash says is stale. This is the
  same emergent-affected property [Dagger][dagger] gets from content-addressing, but
  driven by an explicit, inspectable action-version rather than opaque op hashes.

### 4. Caching & remote execution

Caching is, again, the point — and it operates at several layers:

- **Result caching (intrinsic).** Build, deploy, test, and run results are cached by
  Garden version. _"Garden caches test results and only re-runs the test if the module
  the test belongs to, or upstream dependents, have changed"_ — so _"the same image
  never needs to be built twice or the same test run twice"_ ([What is Garden][what]).
- **Image-layer caching.** Builds reuse Docker/BuildKit layer caches; with
  `cluster-buildkit`/`kaniko` those layer caches live _in the cluster_ and are shared
  across the whole team and CI.
- **Remote Container Builder (Garden Cloud).** The optional managed builder offloads
  builds to remote compute with a persistent NVMe layer cache: _"Each built layer of
  your Dockerfile is stored on low-latency, high-throughput NVMe storage so that your
  entire team can benefit from shared build caches"_ ([Remote Container Builder][rcb]).
  It _"is enabled by default once you've logged in, so no further configuration is
  required,"_ and can be scoped per environment under the `container` provider:

  ```yaml
  providers:
    - name: container
      environments: [remote-dev, ci]
      gardenContainerBuilder:
        enabled: true
  ```

- **Team-wide test/run caches.** Historically the status/result cache for kubernetes
  test and run actions lived in cluster `ConfigMap`s, which _"could not be shared"_
  across clusters and grew unwieldy. Garden Cloud moved this to a hosted store so
  test/run caches are **shared across clusters** ([Cloud announcement][cloud]).

> [!NOTE]
> Garden's remote story is **shared layer/result caching plus a managed remote
> builder**, not the [Remote Execution API (REAPI)][bazel] that
> [Bazel][bazel]/[Buck2][buck2] backends like [Buildbarn][buildbarn] and
> [NativeLink][nativelink] speak. Like [Dagger][dagger], Garden farms _container
> builds_ and caches _action results_; it does not farm arbitrary fine-grained actions
> to a content-addressed REAPI cluster. The granularity is the whole `Build`/`Test`,
> not a single compiler invocation.

### 5. CLI / UX ergonomics

The command boundary is **action-kind-centric**: each of the four kinds has a verb,
and you select _which actions of that kind_ by name (or run all of them).

- **Per-kind verbs.** `garden build`, `garden deploy`, `garden test`, `garden run` —
  each builds/deploys/tests/runs **all** actions of that kind (in dependency order) if
  given no names, or a subset if named: `garden deploy api web`, `garden build api`,
  `garden test api-integ -i` ([Using the CLI][cli]). Dependencies of the selected
  actions are pulled in automatically (a `deploy` first runs the builds it needs).
- **Name-based selection, not `--filter`/`-p`/`:target`.** Selection is positional
  action names, optionally with glob patterns over names, rather than a
  package-filter flag. There is no `--since <git-ref>` affected query; the
  status-cache makes a full-graph run skip unchanged work instead.
- **Sub-graph control flags.** `--skip <names>` excludes specific actions;
  `--skip-dependencies` runs only the named actions without their deploy/test/run
  dependencies; `--with-dependants` additionally processes the **downstream**
  dependents of the selected actions (_"useful when you know you need to redeploy
  dependants"_) ([Commands][commands]).
- **Environment/namespace targeting.** `--env <namespace>.<environment>` (e.g.
  `garden deploy --env my-ns.dev`) selects which environment's providers and config
  apply — the axis Garden uses where other tools use package filters.
- **The interactive dev console.** `garden dev` opens an interactive console in which
  you _"execute Garden commands in interactive mode, like build, deploy, run, test,"_
  with **sync mode** live-syncing file changes into running deploys for _"blazing fast
  feedback while developing"_ ([What is Garden][what], [Commands][commands]).

```bash
# Deploy two specific services into the dev environment, with their dependencies:
garden deploy api web --env local.dev

# Run all tests, skipping a slow one; reuse cached results for unchanged actions:
garden test --skip api-e2e

# Open the interactive dev console with live-sync into running deploys:
garden dev
```

There is **no `--filter pkg...` / `-p` / `:target` / `--since`** vocabulary. The
selection unit is _which named actions of which kind_, plus the **environment** axis —
a direct consequence of the action-kind model and of caching (not a git query) being
the mechanism that bounds work to what actually changed.

---

## Strengths

- **Dev ≡ CI ≡ prod by construction.** One declarative Stack Graph drives every
  environment; sync mode plus on-demand production-like Kubernetes environments
  collapse the dev/CI/prod config triplication that plagues Kubernetes shops.
- **Explicit, typed, dependency-aware graph.** Unlike [Dagger][dagger]'s implicit
  data-flow DAG, the action graph is declared and inspectable, with first-class
  `Build`/`Deploy`/`Test`/`Run` semantics and `getStatus`-driven skipping.
- **Graph-aware, version-hashed caching.** Action versions fold in upstream
  dependencies, so builds and tests never repeat needlessly — emergent
  affected-detection without a git-diff query, plus team-shared in-cluster layer
  caches and a managed NVMe-backed remote builder.
- **Config can be scattered and cross-repo.** Actions live next to what they describe,
  and **remote sources** unify multiple git repositories into one Stack Graph — a
  reach no member-array workspace tool offers.
- **Pluggable execution.** `kubernetes`/`helm`/`terraform`/`pulumi`/`exec`/`container`
  plugins mean the same graph orchestrates infra, container builds, and tests.
- **Tests as graph citizens.** Integration tests can declare `dependencies` on
  deploys, so Garden brings up exactly the stack a test needs and caches its result.

## Weaknesses

- **Not a package manager or build system.** No library-dependency resolution, no
  lockfile, no workspace member manifest — orthogonal to [Cargo][cargo]/[dub][d-landscape]/[pnpm][pnpm].
  For `dub`'s workspace problem it offers an _orchestration/caching_ model, not
  manifest primitives.
- **Kubernetes-centric gravity.** The flagship value (in-cluster builds, sync mode,
  production-like envs) assumes Kubernetes; outside a cluster you fall back to the
  generic `exec`/`container` plugins and lose much of the appeal.
- **No declarative member set / no `--since`.** "What's in the workspace" has no
  single-file answer (you query the graph), and there is no git-ref affected query —
  change scoping is the version hash, which is powerful but less explicit.
- **Remote cache ≠ REAPI.** Caching is shared layers + hosted result caches + a
  managed builder, not a distributed REAPI action farm like
  [Bazel][bazel]/[Buck2][buck2] backends.
- **Best caching/builder features are Garden Cloud.** The Remote Container Builder and
  cross-cluster team test/run caches live behind the hosted Garden Cloud (with a
  metered free tier); the open-source Core caches locally/in-cluster.
- **YAML at scale.** Large projects accumulate many `garden.yml` files and a powerful
  but intricate templating engine; `garden summary` exists specifically to diagnose
  slow init on projects with _"lots of actions and modules and/or lots of files."_

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                                       | Trade-off                                                                                         |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Four action kinds (`Build`/`Deploy`/`Test`/`Run`) as the graph | First-class, typed verbs map cleanly to CLI commands and to `getStatus`/`process` semantics     | A new concept to learn; everything must be shoehorned into one of four kinds                      |
| Config discovered repo-wide (vs a member array)                | Configs live next to what they describe; works with any layout, even across git repos           | No single-file "what's in my workspace"; topology must be queried (`get graph`/`summary`)         |
| Cross-repo **remote sources** unified into one Stack Graph     | A project can span many repositories (code here, manifests there) yet build/test as one system  | Extra clone/version-pinning machinery; harder to reason about than an in-tree member list         |
| `getStatus` before `process`, version-hashed dependency-aware  | Affected work emerges from caching; the same image/test never repeats; no git-diff query needed | "What will run" is computed from version hashes, not an explicit `--since` set — less transparent |
| Pluggable execution, Kubernetes-first                          | One graph orchestrates infra (`terraform`/`pulumi`), builds (`container`), and tests (`exec`)   | Greatest value assumes Kubernetes; off-cluster usage loses sync mode and in-cluster caching       |
| In-cluster build modes (`cluster-buildkit`/`kaniko`)           | Share layer/image caches across the team and CI without a local Docker daemon                   | Requires cluster build infrastructure; build resource limits become a cluster-capacity concern    |
| Remote Container Builder + hosted caches via **Garden Cloud**  | NVMe-backed shared layer cache and cross-cluster test/run caches accelerate teams               | Best caching is a hosted (metered) service, not pure OSS; another dependency/login                |
| Name-based, per-kind CLI selection (no `--filter`/`:target`)   | A uniform `verb [names] --env` surface generated from the action kinds                          | No package-filter (`--filter`/`-p`) or `--since` selection vocabulary                             |

---

## Sources

- [`garden-io/garden` — GitHub repository (README, `MPL-2.0`, TypeScript)][repo]
- [Garden documentation — docs.garden.io][docs]
- [What is Garden — Stack Graph, action kinds, caching, sync mode][what]
- [Garden basics — config discovery, cross-repo, actions & dependencies][basics]
- [Graph execution internals — `GraphSolver`, `getStatus`/`process`, task types][graphexec]
- [The Stack Graph (terminology)][stackgraph]
- [Using the CLI — per-kind verbs, action-name selection][cli]
- [Commands reference — `--skip`, `--skip-dependencies`, `--with-dependants`, `dev`][commands]
- [Remote sources — multi-repository projects, `garden link`][remotesources]
- [In-cluster building — `buildMode` `local-docker`/`cluster-buildkit`/`kaniko`][incluster]
- [Remote Container Builder — NVMe layer cache, `gardenContainerBuilder`][rcb]
- [Garden Cloud — team-wide test/run caches (vs cluster `ConfigMap`s)][cloud]
- [FAQ — Garden version computation, `.garden` directory][faq]
- Sibling tools: [Dagger][dagger] · [Earthly][earthly] · [Turborepo][turborepo] · [Nx][nx] · [Bazel][bazel] · [Buck2][buck2] · [Cargo][cargo] · [`go.work`][go-work] · [pnpm][pnpm] · [Yarn Berry][yarn-berry] · [Task][task] · [Just][just] · [mise][mise] · [Buildbarn][buildbarn] · [NativeLink][nativelink]
- D context: [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/garden-io/garden
[docs]: https://docs.garden.io/
[what]: https://docs.garden.io/overview/what-is-garden
[basics]: https://docs.garden.io/getting-started/basics
[graphexec]: https://docs.garden.io/contributing-to-garden/graph-execution
[stackgraph]: https://docs.garden.io/acorn-0.12/basics/stack-graph
[cli]: https://docs.garden.io/guides/using-the-cli
[commands]: https://docs.garden.io/reference/commands
[remotesources]: https://web.archive.org/web/20250614105358/https://docs.garden.io/advanced/using-remote-sources
[incluster]: https://docs.garden.io/using-garden-with/containers/building-containers
[rcb]: https://docs.garden.io/features/remote-container-builder
[cloud]: https://docs.garden.io/misc/cloud-announcement
[faq]: https://docs.garden.io/misc/faq
[dagger]: ../dagger/
[earthly]: ../earthly/
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
