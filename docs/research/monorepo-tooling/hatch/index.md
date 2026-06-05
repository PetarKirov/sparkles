# Hatch (Python)

A `pyproject.toml`-centric, PyPA-published Python project manager built around **isolated, matrix-expanding environments** — with a freshly added (`1.16.0`, Cargo-inspired) **workspace environment** that installs several local packages editable into one shared environment, but still no shared lockfile or cross-package task DAG.

| Field           | Value                                                                                                                                     |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| Language        | Python (CLI written in Python; `hatchling` is the PEP 517 build backend)                                                                  |
| License         | MIT                                                                                                                                       |
| Repository      | [pypa/hatch][repo]                                                                                                                        |
| Documentation   | [hatch.pypa.io][docs]                                                                                                                     |
| Category        | Python Package Manager                                                                                                                    |
| Workspace model | **Environment-scoped.** Per-project `pyproject.toml`; a `workspace.members` list installs siblings editable into one env (since `1.16.0`) |
| First released  | `1.0.0` — April 28, 2022 (the "v1 complete rewrite"; the original `hatch` predates it)                                                    |
| Latest release  | `1.17.0` — May 31, 2026                                                                                                                   |

> **Latest release:** `1.17.0` (2026-05-31). The headline monorepo development is `1.16.0` (2025-11-26), whose [changelog][history] reads, verbatim: _"Support for workspaces inspired by Cargo Workspaces."_ `1.16.4` (2026-02-23) followed with _"Fixes workspace member detection to properly handle shared path prefixes."_ The build backend [`hatchling`][hatchling] versions independently. Unlike [`uv`][uv]'s `[tool.uv.workspace]`, Hatch's workspace is **per-environment**, not a top-level topology, and there is still **no shared lockfile** and **no cross-package task DAG** (see below).

---

## Overview

### What it solves

Hatch is the [PyPA][pypa]'s "batteries-included" project manager: one tool that scaffolds a project, manages **multiple isolated environments** per project, runs scripts/tests across a **version matrix**, builds wheels/sdists via its own backend ([`hatchling`][hatchling]), bumps versions, and publishes to PyPI. From the project landing page ([hatch.pypa.io][docs]):

> _"Hatch is a modern, extensible Python project manager."_

Where [`poetry`][poetry] centers on **one project's** dependency graph + lockfile + venv, and [`uv`][uv] centers on a fast Rust resolver with a first-class `[tool.uv.workspace]`, Hatch's organizing primitive is the **environment**. A single project routinely defines many of them — `default`, `test`, `docs`, `lint` — each an isolated virtual env with its own dependencies and named **scripts**, and each optionally **matrixed** across Python versions and arbitrary variables. This is `tox`-style multi-environment testing folded into the package manager itself, with no separate `tox.ini`.

The monorepo story, historically, was the same as Poetry's: a tree of independent projects glued by relative `path` dependencies. That changed in `1.16.0` with the **workspace environment** — a way to declare a set of local member packages that all install **editable** into one shared environment.

### Design philosophy

Hatch's philosophy is **environment-first and standards-forward**. Configuration lives in PEP 621 `[project]` metadata plus a `[tool.hatch.*]` namespace (or a standalone `hatch.toml`), and the build backend [`hatchling`][hatchling] is a strict PEP 517 backend that can be used on its own by projects that never touch the `hatch` CLI. Environments are the spine; from the [environments docs][envdoc], verbatim:

> _"Environments are designed to allow for isolated workspaces for testing, building documentation, or anything else projects need."_

Three consequences shape the rest of the tool:

1. **The environment, not the project, is the unit of action.** Almost every verb (`hatch run`, `hatch test`, `hatch shell`) operates _in an environment_; `hatch run <env>:<script>` is the canonical form. _"Unless an environment is chosen explicitly, Hatch will use the `default` environment."_ ([environments docs][envdoc]).
2. **The matrix replaces a separate test-orchestration tool.** A `[[tool.hatch.envs.<name>.matrix]]` table multiplies one environment into the Cartesian product of its variables — _"the product of each variable combination being its own environment"_ ([advanced env docs][advenv]) — giving tox-like multi-version testing natively.
3. **Workspaces are an extension of environments, not a top-level topology.** The `1.16.0` workspace lives _inside_ an environment config (`[tool.hatch.envs.default] workspace.members = [...]`), modeled explicitly on Cargo. Per the [workspace how-to][wsdoc]: _"Workspace environments allow you to manage multiple related packages within a single environment. This is useful for monorepos or projects with multiple interdependent packages."_

> [!NOTE]
> Hatch shares this survey's **Python Package Manager** category with [`uv`][uv] and [`poetry`][poetry]. Of the three, [`uv`][uv] has the most complete workspace (top-level topology + shared `uv.lock`), [`poetry`][poetry] has none (the [cautionary baseline][poetry]), and Hatch now sits in between: a real, Cargo-inspired member primitive, but scoped to an environment and **without** a unified lockfile or topological task routing. Compare with the JS managers ([`pnpm`][pnpm], [`npm`][npm], [`yarn-berry`][yarn-berry], [`bun`][bun]) — all of which ship a workspace primitive — and with [`cargo`][cargo]'s `[workspace]` table, the design Hatch's `1.16.0` explicitly borrows from.

---

## How it works

### The project triad: `pyproject.toml` + `hatchling` + environments

A Hatch project is a directory with one `pyproject.toml`. Metadata is PEP 621; the build backend is declared in `[build-system]`; Hatch-specific knobs live under `[tool.hatch]`:

```toml
# pyproject.toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "my-service"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = ["httpx>=0.27", "pydantic>=2.7"]

[project.optional-dependencies]
dev = ["mypy", "ruff"]
```

[`hatchling`][hatchling] is shipped as a **separate package** and is a PEP 517-compliant backend that reads PEP 621 metadata from `[project]`; it can be used as the `build-backend` of projects that never invoke the `hatch` CLI at all. Dynamic versioning is configured under `[tool.hatch.version]` with a `source` (the default `regex` source reads a `path` to a file; the `hatch-vcs` plugin derives the version from Git tags):

```toml
[tool.hatch.version]
path = "src/my_service/__about__.py"
```

### Environments, dependencies, and scripts

The defining feature. Each `[tool.hatch.envs.<name>]` table declares an isolated virtual environment (`type = "virtual"` is the default implementation; a `uv`-backed installer is supported) with its own `dependencies`, `features` (which PEP 621 extras to install), `env-vars`, and named **scripts**:

```toml
[tool.hatch.envs.test]
dependencies = ["pytest", "pytest-cov"]

[tool.hatch.envs.test.scripts]
run = "pytest {args:--cov=my_service --cov-report=term-missing}"

[tool.hatch.envs.lint]
detached = true                       # do NOT install the project itself
dependencies = ["ruff", "mypy"]

[tool.hatch.envs.lint.scripts]
all = ["ruff check .", "mypy src"]    # a list = run sequentially
```

`hatch run test:run` executes the `run` script in the `test` environment, creating/syncing the env on demand. `detached = true` decouples a tool env (linters, docs) from the project so it is never installed as a dependency. Scripts can reference other scripts and accept `{args}` placeholders; a list value runs steps sequentially.

### The environment matrix

A `[[tool.hatch.envs.<name>.matrix]]` array-of-tables multiplies one environment definition into the **Cartesian product** of its variables ([advanced env docs][advenv]):

```toml
[[tool.hatch.envs.test.matrix]]
python = ["3.10", "3.11", "3.12"]
version = ["42", "3.14"]
```

This generates six concrete environments — `test.py3.10-42`, `test.py3.10-3.14`, `test.py3.11-42`, …. Per the docs, _"If the variables `py` or `python` are specified, then they will rank first in the product result and will be prefixed by `py` if the value is not."_ Running `hatch run test:run` against the **root** environment name fans the script out across **all** generated variants. An `[tool.hatch.envs.test.overrides]` table conditionally tweaks options per matrix value (e.g. add a feature only when a variable equals a given value). This is the tox replacement: multi-Python testing without a second config file.

### Workspace environments (`1.16.0`+)

The monorepo primitive. A `workspace.members` list inside an environment installs each listed local package **editable** into that one shared environment ([workspace how-to][wsdoc]):

```toml
[tool.hatch.envs.default]
workspace.members = [
    "packages/core",
    "packages/utils",
    "packages/cli",
]
```

Verbatim from the docs: _"Workspace members are automatically installed as editable packages in the environment."_ Members support three forms — explicit paths, glob discovery, and objects carrying selected extras:

```toml
[tool.hatch.envs.default]
workspace.members = [
    {path = "packages/core",  features = ["dev"]},
    {path = "packages/utils", features = ["test", "docs"]},
    "packages/cli",
]
workspace.exclude  = ["packages/experimental*"]   # prune glob matches
workspace.parallel = true                          # parallel dependency resolution
```

`workspace.members = ["packages/*"]` discovers members by glob; `workspace.exclude` prunes matches; `workspace.parallel = true` _"enables parallel dependency resolution for faster environment setup."_ Because all members are installed editable into **one** env, an import of a sibling resolves live against its source — the cross-package code-sharing that Poetry can only achieve through hand-written `path = "../sibling"` `develop = true` edges. Different environments may compose different member sets (e.g. `unit-tests` vs `integration-tests` vs `docs`), and the matrix composes with workspaces for multi-Python workspace testing.

> [!NOTE]
> The `1.16.0` changelog attributes the design to Cargo (_"inspired by Cargo Workspaces"_), and the shape rhymes with [`cargo`][cargo]'s `members`/`exclude` and [`uv`][uv]'s `[tool.uv.workspace] members`. The crucial difference: in Cargo and `uv` the workspace is a **top-level** declaration that also unifies the lockfile and resolution; in Hatch it is **scoped to an environment** and unifies only the _editable install set_ of that env — there is no workspace-wide lock.

---

## Workspace Declaration & Topology

Hatch has **two** ways a multi-package tree is described, and they sit at different levels:

- **Per-project, always:** every package is its own `pyproject.toml` with its own `[build-system]`. There is no top-level root manifest that enumerates the tree the way [`cargo`][cargo]'s `[workspace] members` or [`pnpm`][pnpm]'s `pnpm-workspace.yaml` does. Discovery, in this sense, is "wherever you point an environment."
- **Per-environment workspace (`1.16.0`+):** a `workspace.members` array _inside_ an environment table. Members are declared explicitly, by **glob** (`"packages/*"`), or as `{path, features}` objects, with `workspace.exclude` to prune glob matches:

  ```toml
  [tool.hatch.envs.default]
  workspace.members = ["packages/*"]
  workspace.exclude = ["packages/experimental*"]
  ```

The topology is therefore **environment-relative**, not project-global. The same tree can present different member sets to different environments. This is more expressive than [`poetry`][poetry] (which has _no_ member concept) but less of a single source of truth than [`cargo`][cargo]/[`uv`][uv], where one `[workspace]`/`[tool.uv.workspace]` block defines _the_ workspace for the whole tree and drives resolution and locking.

> [!IMPORTANT]
> For the proposed `dub` `[workspace]` block, Hatch is the "member list, no shared lock" data point. It proves the **glob + explicit + exclude** member-declaration pattern (also seen in [`cargo`][cargo], [`uv`][uv], [`pnpm`][pnpm]) is the cross-ecosystem consensus, while cautioning that scoping members to an _environment_ rather than the _root_ forfeits a single workspace-wide resolution.

---

## Dependency Handling & Isolation

### Isolation is per-environment, not per-project or content-addressed

Hatch's isolation unit is the **environment** — a virtual env per `[tool.hatch.envs.<name>]` (and per matrix cell). A project with `default`, `test`, `docs`, and a matrixed `test` over three Pythons materializes many venvs. There is **no hoisting** (cf. [`npm`][npm]/[`yarn-berry`][yarn-berry] classic), **no global hard-linked content-addressed store** (cf. [`pnpm`][pnpm], [`uv`][uv]), and **no virtual-store symlink tree** (cf. [`yarn-berry`][yarn-berry] PnP). Each environment installs its dependency closure into its own venv; the same dependency across two environments is installed twice. (When the `uv` installer backend is enabled, `uv`'s download cache reduces _fetch_ cost, but the install targets are still distinct venvs.)

### Cross-package local references

Two mechanisms, depending on whether you use the workspace primitive:

1. **Workspace members (editable, `1.16.0`+).** Listing a sibling in `workspace.members` installs it editable into the shared environment, so imports resolve live against its source — no per-edge `path=` wiring, no reinstall on edit. This is the closest Hatch analogue to [`yarn-berry`][yarn-berry]'s `workspace:` protocol or [`cargo`][cargo]'s intra-workspace `path` resolution.
2. **Relative `path` dependencies (pre-workspace, still valid).** As in [`poetry`][poetry], a member can depend on a sibling via a PEP 508 / direct-reference `path` dependency in its own metadata, declared per edge by hand.

The key gap versus [`cargo`][cargo]/[`uv`][uv]: workspace members are installed editable, but **resolution is still per-package**. Each member's `pyproject.toml` resolves its own dependencies; Hatch does **not** compute one unified resolution across all members, and there is **no shared lockfile** to pin that unified graph. Hatch ships **no lockfile at all** in its core — reproducibility relies on the underlying installer (e.g. `pip`/`uv`) and pinned constraints, not a `hatch.lock`. So a workspace shares an _editable install set_ but not a _resolved, locked graph_, leaving version-drift between members possible.

> [!WARNING]
> No core lockfile is Hatch's largest reproducibility gap relative to its category peers. [`poetry`][poetry] has `poetry.lock`; [`uv`][uv] has `uv.lock` (workspace-wide). Hatch leaves locking to plugins/installers, so a workspace's members can resolve incompatible versions of a shared upstream with nothing in the core tool to detect or prevent it.

---

## Task Orchestration & Scheduling

Hatch **does** run tasks, but its model is **scripts-within-environments**, not a cross-package target DAG:

- **Scripts as the task unit.** `[tool.hatch.envs.<env>.scripts]` defines named commands; `hatch run <env>:<script>` executes one. A script whose value is a **list** runs steps **sequentially**; scripts may invoke other scripts. This is a per-environment command runner, comparable to npm `scripts`, not a build graph.
- **Matrix fan-out is the only built-in "many".** Running a script against a matrixed environment fans it across all generated variants (the Cartesian product), filterable with `-i/--include`, `-x/--exclude`, and `-f/--filter` ([CLI reference][cli]): _"an environment must match all of the included variables to be selected while matching any of the excluded variables will prevent selection."_ `hatch test -p/--parallel` runs the matrix's test variants in parallel. This is **environment** parallelism, not dependency-graph scheduling.
- **No cross-package task DAG.** There is no notion of "build member A before its dependent member B," no topological ordering of workspace members, and no broadcast verb like [`yarn-berry`][yarn-berry]'s `yarn workspaces foreach`. A workspace shares an install set; it does not give you `hatch run --workspace test` that walks members in dependency order.
- **No change detection / affected-detection.** There is **no input hashing**, **no `--since <ref>` git-diff slicing**, and **no impacted-downstream computation** (contrast [`turborepo`][turborepo], [`nx`][nx], [`bazel`][bazel]). Hatch re-runs what you ask it to run.

The only graphs Hatch reasons about are (a) per-package dependency resolution for a single env's install, and (b) the matrix product. To orchestrate work _across_ members topologically you reach for an external runner — [`make`][make], [`just`][just], [`task`][task], or a polyglot orchestrator like [`turborepo`][turborepo]/[`nx`][nx] driving `hatch` invocations.

> [!NOTE]
> Even with the `1.16.0` workspace, Hatch is an _environment_ orchestrator, not a _workspace_ orchestrator: it co-installs members but does not schedule per-member tasks in dependency order. This is exactly the "uncoordinated testing scripts across packages" gap the `dub` proposal targets with a topological execution loop.

---

## Caching & Remote Execution

Hatch's caching is **environment and download caching**, not build/test-output caching, and there is **no remote execution**:

- **Environment reuse.** Created environments persist under Hatch's data directory and are reused across invocations; Hatch resyncs an env only when its declared dependencies change (re-resolving on the next shell/command). `hatch env prune` clears them. This caches _the materialized env_, not task outputs.
- **Download/installer cache.** Wheels/metadata are cached by the underlying installer (`pip`, or `uv` when the `uv` backend is enabled — inheriting `uv`'s content-addressed download cache). This is a _fetch_ cache.
- **No task-output cache.** There is nothing analogous to [`turborepo`][turborepo]'s `.turbo`, [`gradle`][gradle]'s build cache, or [`bazel`][bazel]'s action cache. A re-run of `hatch test` re-executes the tests.
- **No REAPI / remote execution.** Hatch has no Remote Execution API client and no remote-cache backend; there is no integration with [`buildbuddy`][buildbuddy], [`buildbarn`][buildbarn], or [`nativelink`][nativelink].
- **No content-addressed install store.** Installs land in per-environment venvs, not a global hard-linked CAS like [`pnpm`][pnpm]/[`uv`][uv], so disk usage scales with `(environments × dependencies)` — amplified by the matrix.

In short: Hatch caches _materialized environments_ and _downloads_, and caches **nothing about what it builds or tests**.

---

## CLI / UX Ergonomics

The command boundary is the **environment**, addressed by name; the matrix adds variable-selection flags. From the [CLI reference][cli]:

```bash
hatch run test:run                 # run the `run` script in the `test` env
hatch run lint:all                 # run the `all` script in the `lint` env
hatch run +py=3.12 test:run        # matrix-select via +/- prefixes
hatch -e docs run serve            # -e/--env chooses the environment globally
hatch shell                        # enter a shell in the default env
hatch env show                     # show available environments + matrices
hatch env run -i py=3.11 test:run  # include matrix variable py=3.11
hatch env run -x version=3.14 ...  # exclude a matrix variable
hatch env run -f '<json>' ...      # --filter: JSON env selection
hatch env prune                    # remove all environments
hatch test -a                      # run ALL matrix test environments
hatch test -py 3.11 -p             # test on 3.11, in parallel
hatch build                        # build wheel + sdist via hatchling
hatch version minor                # bump the version
hatch publish                      # upload to PyPI
```

The dimensions of selection are **environment** (`-e/--env`, or the `<env>:` prefix on `run`) and **matrix variable** (`-i/--include`, `-x/--exclude`, `-f/--filter`, `+var=val` / `-var=val` prefixes, and `hatch test --py`). What is conspicuously **absent** is any **cross-package** selector:

- **No `-p/--package` member selector.** (Hatch's root `-p/--project` selects _one whole project_ by name, not a member within a workspace, and operates on one project at a time.)
- **No `--filter` over members** (its `-f/--filter` selects _environments_ by JSON, not packages).
- **No `:target` colon syntax for members, no `--recursive`/`--from` sub-graph traversal, no `--since <ref>`** affected slicing.

So the matrix CLI is genuinely well-designed for _one project's_ version/variable axes, but — like [`poetry`][poetry]'s `--with`/`--without`/`--only` — it does **not** generalize to "run this across the workspace's members in dependency order." A workspace installs members together; the CLI still drives _environments_, not _members_.

> [!IMPORTANT]
> For the `dub` proposal, Hatch contributes the **matrix-filter** ergonomics (`-i`/`-x` include/exclude over variable axes) as a model for slicing a fan-out, while standing as evidence that an _environment_-scoped workspace, lacking member-targeting verbs (`dub run -p <member>`, `dub test --workspace`, `dub build --since <ref>`), still leaves the cross-package coordination problem unsolved. Those verbs map onto [`yarn-berry`][yarn-berry], [`cargo`][cargo], and [`turborepo`][turborepo], not Hatch.

---

## Strengths

- **Environment-first model is genuinely powerful** — many isolated, named, scripted environments per project, with `detached` tool envs and `features`-driven extras.
- **Built-in matrix testing** replaces `tox`: `[[…matrix]]` over Python versions and arbitrary variables, with `-i`/`-x`/`-f` selection and `hatch test -p` parallelism.
- **PyPA-published and standards-forward** — PEP 621 metadata, PEP 517 builds via the standalone `hatchling` backend, usable independently of the CLI.
- **Cargo-inspired workspace (`1.16.0`)** brings real, glob-discoverable, editable member installs — a first-class step beyond Poetry's hand-wired `path` deps.
- **`workspace.exclude` + `workspace.parallel`** give ergonomic, fast member composition; different environments can compose different member sets.
- **`uv`-backed installer option** makes environment creation fast and shares `uv`'s download cache.
- **Extensible plugin system** (build hooks, version sources like `hatch-vcs`, environment plugins).

## Weaknesses

- **No core lockfile** — the biggest reproducibility gap versus [`poetry`][poetry] (`poetry.lock`) and [`uv`][uv] (`uv.lock`); locking is delegated to installers/plugins.
- **Workspace resolution is still per-member** — co-installed editable, but no unified workspace-wide resolution, so version drift between members is unprevented.
- **Workspace is environment-scoped, not a top-level topology** — no single project-global source of truth like `[workspace]`/`[tool.uv.workspace]`.
- **No cross-package task DAG, no topological ordering, no `foreach`-style broadcast** — cross-member orchestration needs an external runner.
- **No affected-detection / `--since` slicing / input hashing.**
- **No build/test output cache and no remote execution** — caching is env + download only.
- **Per-environment venvs duplicate dependencies** — disk usage scales with `environments × deps`, amplified by the matrix; no content-addressed store.
- **The workspace primitive is very new** (`1.16.0`, late 2025) and still maturing (e.g. the `1.16.4` member-detection fix).

---

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                                 | Trade-off                                                                                   |
| ----------------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| Environment is the primary unit (not the project)                 | Many isolated, scripted contexts per project; tool envs, docs envs, test envs             | Verbs target environments, not packages; per-env venvs duplicate shared deps                |
| Built-in matrix (`[[…matrix]]`) instead of an external `tox`      | Native multi-Python / multi-variable testing with `-i`/`-x`/`-f` selection                | Combinatorial venv explosion (one per cell); disk + setup cost scale with the product       |
| Workspace scoped to an environment (`1.16.0`, Cargo-inspired)     | Reuses the env model; different envs can compose different member sets; editable installs | Not a top-level topology; no workspace-wide resolution or lock; resolution stays per-member |
| No core lockfile                                                  | Keeps Hatch thin; delegates locking to `pip`/`uv`/plugins                                 | Reproducibility weaker than `poetry`/`uv`; member version drift undetected                  |
| `hatchling` as a standalone PEP 517 backend                       | Build backend usable without the CLI; clean separation of build vs. workflow              | Two release cadences; build config split across `[build-system]` and `[tool.hatch]`         |
| Scripts (lists run sequentially) as the task model                | Simple, discoverable per-env command aliases; npm-like                                    | No dependency DAG, no topological ordering, no affected-detection across members            |
| `-i`/`-x`/`-f` select matrix _variables_, not workspace _members_ | Precise slicing of a single project's matrix fan-out                                      | No member-targeting verbs (`-p <member>`, `--since`, `:target`) for the workspace           |
| Env + download caching only; no task-output cache, no remote exec | Reuse materialized envs and downloads; stay a package manager, not a build engine         | Re-runs re-execute work; no `.turbo`/action cache; no REAPI backend                         |

---

## Sources

- [pypa/hatch — GitHub repository][repo]
- [Hatch documentation home — "a modern, extensible Python project manager"][docs]
- [Environments — "isolated workspaces for testing, building documentation…"][envdoc]
- [Advanced environment configuration — the matrix product, overrides, naming][advenv]
- [How to configure workspace environments — `workspace.members`, glob, `exclude`, `parallel`, editable installs][wsdoc]
- [Hatch history (changelog) — `1.16.0` "Support for workspaces inspired by Cargo Workspaces"; `1.16.4` member-detection fix; `1.17.0`][history]
- [CLI reference — `hatch run`/`env run`/`test`, `-e`/`-i`/`-x`/`-f`, matrix selection][cli]
- [`hatchling` — the standalone PEP 517 build backend][hatchling]
- [Versioning — `[tool.hatch.version]`, `regex`/`hatch-vcs` sources][versioning]
- [Python Packaging Authority (PyPA)][pypa]
- [PEP 621 — project metadata in `pyproject.toml`][pep621]
- Related deep-dives: [`uv`][uv] · [`poetry`][poetry] · [`pnpm`][pnpm] · [`npm`][npm] · [`yarn-berry`][yarn-berry] · [`bun`][bun] · [`cargo`][cargo] · [`go-work`][go-work] · [`turborepo`][turborepo] · [`nx`][nx] · [`bazel`][bazel] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/pypa/hatch
[docs]: https://hatch.pypa.io/latest/
[envdoc]: https://hatch.pypa.io/latest/environment/
[advenv]: https://hatch.pypa.io/latest/config/environment/advanced/
[wsdoc]: https://hatch.pypa.io/latest/how-to/environment/workspace/
[history]: https://hatch.pypa.io/dev/history/hatch/
[cli]: https://hatch.pypa.io/latest/cli/reference/
[hatchling]: https://pypi.org/project/hatchling/
[versioning]: https://hatch.pypa.io/latest/version/
[pypa]: https://www.pypa.io/
[pep621]: https://peps.python.org/pep-0621/
[uv]: ../uv/
[poetry]: ../poetry/
[pnpm]: ../pnpm/
[npm]: ../npm/
[yarn-berry]: ../yarn-berry/
[bun]: ../bun/
[cargo]: ../cargo/
[go-work]: ../go-work/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[gradle]: ../gradle/
[make]: ../make/
[just]: ../just/
[task]: ../task/
[buildbuddy]: ../buildbuddy/
[buildbarn]: ../buildbarn/
[nativelink]: ../nativelink/
[d-landscape]: ../../async-io/d-landscape.md
