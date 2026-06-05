# Poetry (Python)

A `pyproject.toml`-centric dependency manager, build backend, and virtual-environment manager for Python that locks one project at a time — with **no native workspace concept**, so monorepos are assembled from relative `path` dependencies, dependency groups, and third-party plugins.

| Field           | Value                                                                                           |
| --------------- | ----------------------------------------------------------------------------------------------- |
| Language        | Python (CLI written in Python; `poetry-core` is the PEP 517 build backend)                      |
| License         | MIT                                                                                             |
| Repository      | [python-poetry/poetry][repo]                                                                    |
| Documentation   | [python-poetry.org/docs][docs]                                                                  |
| Category        | Python Package Manager                                                                          |
| Workspace model | **None native.** Per-project `pyproject.toml` + relative `path` deps; plugins for monorepo glue |
| First released  | `0.1.0` — February 2018                                                                         |
| Latest release  | `2.4.1` — May 9, 2026                                                                           |

> **Latest release:** `2.4.1` (2026-05-09). The `2.x` line (since `2.0.0`, 2025-01-05) pivoted Poetry onto the **PEP 621 `[project]` table** as the primary metadata source, demoting the historical `[tool.poetry]` table. Per the [CHANGELOG][changelog], `2.2.0` (2025-09-14) added **PEP 735 `[dependency-groups]`** support and `2.3.0` (2026-01-18) added `pylock.toml` export. None of these releases added a `workspace` primitive — Poetry remains a single-project tool by design.

---

## Overview

### What it solves

Poetry consolidates what was historically a scattered toolchain — `setup.py`, `requirements.txt`, `setup.cfg`, `MANIFEST.in`, and `Pipfile` — into one declarative `pyproject.toml`, and pairs it with a **lockfile** (`poetry.lock`) and a **per-project virtual environment**. From the project [README][readme]:

> _"Poetry helps you declare, manage and install dependencies of Python projects, ensuring you have the right stack everywhere."_

The value proposition is _deterministic, reproducible installs_. The first `poetry install` resolves the dependency graph and, per the [Basic usage docs][basic-usage], _"writes all the packages and their exact versions that it downloaded to the `poetry.lock` file, locking the project to those specific versions."_ Thereafter every machine installs from the pinned lockfile so that _"your CI server, production machines, other developers in your team, everything and everyone runs on the same dependencies."_

Crucially, Poetry's _unit of management is one project_. There is exactly one `pyproject.toml`, one `poetry.lock`, and one virtual environment per project. This is the central tension for monorepos: Poetry has no concept of a multi-package workspace, a root manifest grouping members, a shared lockfile across packages, or a topological build loop. The Python equivalent of those features — if you want them — comes from [`uv`][uv] (which _does_ ship a native `[tool.uv.workspace]`), not from Poetry.

### Design philosophy

Poetry's resolver is a **PubGrub** implementation, originally extracted as the standalone [`mixology`][mixology] library and now vendored in-tree at `src/poetry/mixology/version_solver.py` ([source][solver]). PubGrub is a conflict-driven version-solving algorithm shared today by Poetry, `uv`, Cargo, Swift Package Manager, Hex, and Bundler; its hallmark is producing _human-readable_ conflict explanations instead of an opaque "no solution".

The philosophy is **strict, deterministic, application-grade dependency management for one project**, prioritizing correctness of the resolved graph over flexibility of layout. That deliberate narrowness is exactly why monorepos feel bolted-on: Poetry never set out to be a build orchestrator. The official [monorepo feature request (#6850)][issue6850] remains open with `status/triage`, and the recommended pattern there is still _path dependencies combined with Poetry's group feature_ — not a workspace engine.

> [!NOTE]
> Poetry occupies the same category as [`uv`][uv] and [`hatch`][hatch] in this survey. Among the three, only `uv` offers a first-class workspace; Poetry and `hatch` both treat the monorepo as an assembly of independent projects. Compare with the JS package managers ([`pnpm`][pnpm], [`npm`][npm], [`yarn-berry`][yarn-berry]), which _all_ ship a workspace primitive, and with [`cargo`][cargo]'s `[workspace]` table — the design Poetry conspicuously lacks.

---

## How it works

### The single-project triad: `pyproject.toml`, `poetry.lock`, venv

A Poetry project is a directory with one `pyproject.toml`. Since `2.0.0` the canonical form uses the PEP 621 `[project]` table for metadata and main dependencies, with a residual `[tool.poetry]` table for Poetry-specific knobs (dependency groups, `package-mode`, relative `path` deps, sources):

```toml
# pyproject.toml (Poetry 2.x, PEP 621 style)
[project]
name = "my-service"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
    "httpx>=0.27",
    "pydantic>=2.7",
]

[tool.poetry]
package-mode = true          # default; false ⇒ application, not a distributable library

[build-system]
requires = ["poetry-core>=2.0"]
build-backend = "poetry.core.masonry.api"
```

`poetry install` resolves this graph with PubGrub, writes pinned versions to `poetry.lock`, creates a virtual environment (by default under `{cache-dir}/virtualenvs`, or in-project as `.venv` when configured), and installs into it. `poetry lock` re-resolves without installing; `poetry run <cmd>` and `poetry shell` execute inside that venv.

### Library vs. application: `package-mode`

Poetry decides whether to _build_ a project from the `package-mode` key ([pyproject docs][pyproject]):

> _"Whether Poetry operates in package mode (default) or not."_

In the default **package mode** the project is a distributable library (`poetry build` produces a wheel/sdist). Setting `package-mode = false` marks it an **application** that is never built or published — only its dependencies are managed. In a monorepo, shared `libs/*` are package-mode `true` and deployable `apps/*` are typically `package-mode = false`. This is the closest analogue Poetry has to Cargo's _root-package-vs-virtual-workspace_ distinction — but it is per-project metadata, not a topology declaration.

### Building distributions: `packages` / `include` / `from`

A package-mode project declares what lands in the wheel via `[tool.poetry] packages`/`include`, where each entry names a package and, optionally, a `from` source directory ([pyproject docs][pyproject]). Critically, includes must live **under the project root** — the constraint that breaks naive monorepo code-sharing (see [Dependency Handling](#dependency-handling--isolation)).

---

## Workspace Declaration & Topology

**Poetry has no workspace declaration.** There is no root manifest, no `members` array, no glob discovery, and no virtual root. The [CLI docs][cli] expose no `workspace`, `foreach`, `--filter`, `--recursive`, or `-p/--package` surface; from the [Basic usage docs][basic-usage] Poetry is _"a per-project tool with one configuration file per project."_ A "monorepo" is therefore _just a directory tree of independent Poetry projects_, each with its own `pyproject.toml`, `poetry.lock`, and venv:

```text
monorepo/
├── libs/
│   ├── core/
│   │   ├── pyproject.toml      # package-mode = true (a library)
│   │   └── poetry.lock         # its OWN lockfile
│   └── client/
│       ├── pyproject.toml
│       └── poetry.lock
└── apps/
    └── api/
        ├── pyproject.toml      # package-mode = false (an application)
        └── poetry.lock         # ALSO its own lockfile
```

Nothing ties these together at the Poetry level. There is no command to enumerate members, and each subtree resolves and locks in isolation. Topology, if it exists at all, is implied solely by the `path` dependencies one project declares on another (below) — there is no first-class graph the tool reasons about across the tree.

> [!IMPORTANT]
> This is the defining gap versus [`cargo`][cargo] (`[workspace] members = [...]`), [`pnpm`][pnpm] (`pnpm-workspace.yaml` globs), [`go-work`][go-work] (`go.work` `use` directives), and even Poetry's own ecosystem sibling [`uv`][uv] (`[tool.uv.workspace] members = ["libs/*"]`). For the proposed `dub` `[workspace]` block, Poetry is the _cautionary baseline_ — the cost of having **no** topology primitive.

---

## Dependency Handling & Isolation

### Per-project isolation via virtual environments

Isolation in Poetry is **per-project venv**, not hoisting or a content-addressed store. Each project gets its own virtual environment; there is no shared `node_modules`-style hoist and no global hard-linked store like [`pnpm`][pnpm]'s or [`uv`][uv]'s cache-backed installs. Two projects in the same tree that both depend on `httpx` install it twice, into two separate venvs, resolved independently against two separate lockfiles — the principal source of _version drift_ across a Poetry monorepo.

### Cross-package local references: relative `path` dependencies

The only mechanism for one local package to depend on a sibling is a **`path` dependency**, declared in `[tool.poetry.dependencies]` (relative paths are _only_ allowed there, not in the PEP 621 `[project]` table). From the [Dependency specification docs][depspec], verbatim:

> _"To depend on a library located in a local directory or file, you can use the `path` property:"_
>
> ```toml
> [tool.poetry.dependencies]
> # directory
> my-package = { path = "../my-package/", develop = true }
>
> # file
> my-package = { path = "../my-package/dist/my-package-0.1.0.tar.gz" }
> ```

`develop = true` installs the sibling **editable** (a `.pth`/symlink into the source tree) so edits are picked up live — the functional equivalent of Yarn's `workspace:` protocol or Cargo's intra-workspace path resolution, but declared by hand, per-edge, with a brittle relative path.

> [!WARNING]
> The PEP 621 `[project]` table **cannot** express relative paths. Per the docs, _"In the `project` section, you can only use absolute paths"_ via PEP 508 URLs (`my-package @ file:///absolute/path/...`). Absolute paths are non-portable across machines, so monorepo cross-refs are effectively _trapped_ in the legacy `[tool.poetry.dependencies]` table — a real friction point in the `2.x` PEP 621 migration.

### Dependency groups (organization within a project, not across projects)

Poetry's [dependency groups][managing] (`[tool.poetry.group.<name>.dependencies]`, plus PEP 735 `[dependency-groups]` since `2.2.0`) organize _one project's_ dependencies — `test`, `docs`, etc. — selectable with `--with` / `--without` / `--only`. The #6850 pattern co-opts groups to stage local `path` deps, but groups are explicitly _intra-project_: per the docs, they _"must only contain dependencies you need in your development process."_ They are not a cross-package topology.

### The build-time path-rewriting problem (and plugins)

`path` deps with `develop = true` work for _local development_ but **break on publish/Docker**: a built wheel cannot carry a `../sibling` reference, and Poetry forbids includes outside the project root. The [`poetry-multiproject-plugin`][multiproject] exists precisely to paper over this, introducing a `build-project` command that, per its docs, addresses that _"Poetry does not allow package includes outside of the project root."_ It works by:

1. copying the project to a temp dir,
2. collecting relative includes (`include = "foo/bar", from = "../../shared"`),
3. copying the shared source in,
4. rewriting `pyproject.toml` with adjusted paths,
5. running `poetry build`, then copying `dist/` back.

A sibling [`poetry-monorepo-dependency-plugin`][monodepplugin] instead _rewrites relative `path` deps into pinned version deps_ at build/publish time. That these are _third-party plugins_, not core features, is itself the headline finding: Poetry's monorepo story is community-patched, not designed.

---

## Task Orchestration & Scheduling

**There is no task DAG, no scheduler, and no change detection.** Poetry is not a task runner. `poetry run <cmd>` executes a single command in one project's venv ([CLI docs][cli]); `poetry build`, `poetry lock`, and `poetry install` each operate on **one** project. There is:

- **no** `foreach`-style broadcast across packages (contrast [`yarn-berry`][yarn-berry]'s `yarn workspaces foreach`),
- **no** topological build ordering of local libraries before dependents,
- **no** input hashing / affected-detection / `--since <ref>` slicing (contrast [`turborepo`][turborepo], [`nx`][nx], [`bazel`][bazel]),
- **no** concurrency across members.

The only graph Poetry computes is the _package dependency graph for resolution_ inside one project (PubGrub), surfaced read-only by `poetry show --tree`. To orchestrate work across a Poetry monorepo you reach for an _external_ runner — [`make`][make], [`just`][just], [`task`][task], or a JS-side orchestrator like [`turborepo`][turborepo]/[`nx`][nx] driving `poetry` invocations — exactly the "uncoordinated testing scripts" problem the `dub` proposal aims to eliminate.

> [!NOTE]
> A common production setup wires Poetry as the _per-package_ dependency/build tool underneath a polyglot orchestrator: the orchestrator owns the DAG, caching, and affected-detection; Poetry owns resolution and the venv. Poetry deliberately stays out of that layer.

---

## Caching & Remote Execution

Poetry's caching is **download/artifact caching for resolution**, not build/test output caching, and there is **no remote execution**:

- **Package cache.** Downloaded wheels/sdists and HTTP metadata are cached under `{cache-dir}` (`poetry cache list` / `poetry cache clear`), so re-resolving or re-installing avoids re-downloading. This is a _fetch_ cache.
- **Lockfile as the reproducibility mechanism.** Determinism comes from `poetry.lock` pinning exact versions, not from a content-addressed build cache. `2.0.0` added _locked markers_ and an `installer.re-resolve` option (default `true`) so installs can skip re-resolution when the lock is current.
- **No task-output cache.** Because there are no tasks (above), there is nothing analogous to [`turborepo`][turborepo]'s `.turbo`, [`gradle`][gradle]'s build cache, or [`bazel`][bazel]'s action cache.
- **No REAPI / remote execution.** Poetry has no remote-cache backend and no Remote Execution API client; there is no integration with [`buildbuddy`][buildbuddy], [`buildbarn`][buildbarn], or [`nativelink`][nativelink].
- **No content-addressed install store.** Unlike [`pnpm`][pnpm] / [`uv`][uv], installs go into per-project venvs rather than a global hard-linked CAS, so disk usage scales with `(projects × dependencies)`.

In short, Poetry caches _what it downloads_, reproducibly pins _what it resolves_, and caches **nothing about what it builds or tests** — because it builds and tests nothing across a workspace.

---

## CLI / UX Ergonomics

The command boundary is **always a single project** — there are no target-selection flags because there are no multiple targets. From the [CLI docs][cli], the relevant filtering knobs are all _intra-project group selection_:

```bash
poetry install                      # resolve + install THIS project into its venv
poetry install --with docs          # include an optional dependency group
poetry install --without test       # exclude a group (--without beats --with)
poetry install --only main          # only the named group(s)
poetry install --sync               # prune anything not in the lock (was --remove-untracked)
poetry install --no-root            # install deps but not the project itself
poetry add httpx@^0.27              # add a dependency to THIS project
poetry add ../libs/core --editable  # add a sibling as an editable path dep
poetry lock                         # re-resolve THIS project's lock
poetry build                        # build THIS project's wheel/sdist
poetry run pytest                   # run a command in THIS project's venv
poetry env use 3.12                 # select the interpreter for THIS project's venv
```

There is **no** `--filter`, **no** `-p/--package`, **no** `:target` colon syntax, **no** `--recursive`/`--from`, and **no** `--since <ref>`. To "run tests everywhere" you script a shell loop over subdirectories invoking `poetry run pytest` in each — which is precisely the manual coordination modern workspace tools eliminate. The `--with` / `--without` / `--only` triad is genuinely well-designed for _one project's_ dimensions, but it does not generalize to _across projects_.

> [!IMPORTANT]
> For the `dub` proposal, Poetry's CLI is the "before" picture: clean and ergonomic _within_ a package, but with **zero** cross-package verbs. The proposed `dub run -p <member>`, `dub test --workspace`, and `dub build --since <ref>` have no Poetry analogue — they map instead onto [`yarn-berry`][yarn-berry], [`cargo`][cargo], and [`turborepo`][turborepo].

---

## Strengths

- **Best-in-class single-project ergonomics.** One `pyproject.toml`, one lockfile, one venv; `add`/`remove`/`install`/`lock`/`run` are crisp and discoverable.
- **PubGrub resolver with readable conflict explanations** — among the strongest error messages in Python packaging.
- **Deterministic, reproducible installs** via `poetry.lock`, locked markers, and `--sync` pruning.
- **Standards-forward (`2.x`):** PEP 621 `[project]`, PEP 735 dependency groups, PEP 517 builds via `poetry-core`, `pylock.toml` export.
- **`develop = true` editable path deps** make _local_ sibling development immediate (live edits, no reinstall).
- **`package-mode = false`** cleanly distinguishes deployable applications from publishable libraries.

## Weaknesses

- **No native workspace at all** — no root manifest, no member discovery, no shared lockfile, no topology.
- **Version drift across the tree:** each project resolves and locks independently; the same dependency is pinned and installed N times.
- **No task DAG, no orchestration, no affected-detection, no concurrency** — cross-package work needs an external runner.
- **No build/test output caching and no remote execution.** Caching is download-only.
- **Cross-package refs are brittle:** relative `path` deps live only in the legacy `[tool.poetry.dependencies]` table (PEP 621 forbids relative paths), and `path` deps don't survive `build`/publish without a plugin.
- **Monorepo support is community-plugin territory** (`poetry-multiproject-plugin`, `poetry-monorepo-dependency-plugin`), not a core, supported design.
- **The official monorepo issue (#6850) is unresolved**, sitting in `status/triage` with no roadmap commitment.

---

## Key design decisions and trade-offs

| Decision                                                          | Rationale                                                                             | Trade-off                                                                                                 |
| ----------------------------------------------------------------- | ------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| One project = one `pyproject.toml` + one `poetry.lock` + one venv | Simple, deterministic, reproducible per-project installs; small mental model          | No cross-project topology; version drift; per-project venv duplication of shared deps                     |
| PubGrub (`mixology`) resolver                                     | Correct, conflict-driven solving with human-readable failure explanations             | Slower than native-code solvers like `uv`'s Rust PubGrub on large graphs                                  |
| Cross-package refs via relative `path` deps (`develop = true`)    | Reuses ordinary dependency syntax; editable installs give live local development      | Per-edge, hand-maintained relative paths; only valid in legacy `[tool.poetry]`; breaks on `build`/publish |
| Dependency **groups** instead of workspaces                       | Organizes a project's own dev/test/docs deps with clean `--with`/`--without`/`--only` | Intra-project only; co-opting them for monorepo staging is a workaround, not a topology                   |
| `package-mode` flag (library vs. application)                     | Lets applications skip build/publish while still managing deps                        | It is per-project metadata, not a workspace root/virtual-root distinction                                 |
| No task runner / no DAG / no output cache                         | Keeps Poetry focused on dependency management and packaging only                      | Forces an external orchestrator (`make`/`just`/`turborepo`) for any cross-package build/test              |
| Monorepo glue left to third-party plugins                         | Keeps the core small; lets the ecosystem experiment (`build-project`, dep rewriting)  | Fragmented, unsupported UX; behavior varies by plugin; the official issue stays unresolved                |
| PEP 621 `[project]` as primary metadata (`2.x`)                   | Standards alignment with the broader Python packaging ecosystem                       | Relative `path` deps regressed to a legacy table; absolute-only PEP 508 file URLs are non-portable        |

---

## Sources

- [python-poetry/poetry — GitHub repository][repo]
- [Poetry documentation home][docs]
- [Poetry `README.md` — "Poetry helps you declare, manage and install dependencies…"][readme]
- [Basic usage — venv, `poetry.lock`, reproducibility][basic-usage]
- [The `pyproject.toml` file — `package-mode`, `packages`/`include`/`from`, `[project]` vs `[tool.poetry]`][pyproject]
- [Dependency specification — `path` deps, `develop = true`, relative-vs-absolute][depspec]
- [Managing dependencies — dependency groups, PEP 735][managing]
- [Commands (CLI reference) — `install`/`add`/`lock`/`build`/`run`, group flags][cli]
- [CHANGELOG — `2.0.0` PEP 621, `2.2.0` PEP 735, `2.3.0` `pylock.toml`, `2.4.1`][changelog]
- [Monorepo support using groups and path dependencies — issue #6850 (open, `status/triage`)][issue6850]
- [`src/poetry/mixology/version_solver.py` — vendored PubGrub solver][solver]
- [`sdispater/mixology` — standalone PubGrub library][mixology]
- [`poetry-multiproject-plugin` — `build-project`, includes outside project root][multiproject]
- [`poetry-monorepo-dependency-plugin` — rewrite path deps to pinned versions][monodepplugin]
- Related deep-dives: [`uv`][uv] · [`hatch`][hatch] · [`pnpm`][pnpm] · [`npm`][npm] · [`yarn-berry`][yarn-berry] · [`cargo`][cargo] · [`go-work`][go-work] · [`turborepo`][turborepo] · [`nx`][nx] · [`bazel`][bazel] · [the D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/python-poetry/poetry
[docs]: https://python-poetry.org/docs/
[readme]: https://github.com/python-poetry/poetry/blob/main/README.md
[basic-usage]: https://python-poetry.org/docs/basic-usage/
[pyproject]: https://python-poetry.org/docs/pyproject/
[depspec]: https://python-poetry.org/docs/dependency-specification/
[managing]: https://python-poetry.org/docs/managing-dependencies/
[cli]: https://python-poetry.org/docs/cli/
[changelog]: https://github.com/python-poetry/poetry/blob/main/CHANGELOG.md
[issue6850]: https://github.com/python-poetry/poetry/issues/6850
[solver]: https://github.com/python-poetry/poetry/blob/master/src/poetry/mixology/version_solver.py
[mixology]: https://github.com/sdispater/mixology
[multiproject]: https://pypi.org/project/poetry-multiproject-plugin/
[monodepplugin]: https://pypi.org/project/poetry-monorepo-dependency-plugin/
[uv]: ../uv/
[hatch]: ../hatch/
[pnpm]: ../pnpm/
[npm]: ../npm/
[yarn-berry]: ../yarn-berry/
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
