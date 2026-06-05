# Composer (PHP)

PHP's de-facto dependency manager: a per-project `composer.json` manifest, a SAT-based resolver ported from openSUSE's `libzypp`, and a `vendor/` install tree with a generated autoloader — with **no native workspace model**, so PHP monorepos are assembled from `path` repositories, the `replace` key, symlinks, and third-party tooling like [`symplify/monorepo-builder`][mrb].

| Field           | Value                                                                                                                  |
| --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Language        | PHP (requires PHP `>= 7.2.5`; Composer is itself written in PHP)                                                       |
| License         | MIT                                                                                                                    |
| Repository      | [composer/composer][repo]                                                                                              |
| Documentation   | [getcomposer.org/doc][docs]                                                                                            |
| Category        | Language Package Manager / Build System                                                                                |
| Workspace model | **None native.** Monorepos are emulated via `path` repositories + `replace` + symlinks (+ external `monorepo-builder`) |
| First released  | March 1, 2012 (development began April 2011)                                                                           |
| Latest release  | `2.10.1`                                                                                                               |

> **Latest release:** `2.10.1` (the `2.10.x` line, June 2026). Composer 2.0 (October 2020) rewrote the resolver/installer for speed and introduced the explicit **repository-priority** model (`canonical`, `exclude`, package filters) that today's monorepo recipes depend on. Composer has **no `--filter`, `-p`, `--workspace`, or `--recursive` flag** — a defining gap versus every JS/TS task orchestrator in this catalog.

---

## Overview

### What it solves

Composer is to PHP what [npm](../npm/) is to Node, [Cargo](../cargo/) is to Rust, or [Poetry](../poetry/) is to Python: a single tool that reads a per-project manifest (`composer.json`), resolves a consistent set of transitive dependencies against a registry ([Packagist][packagist]), writes a `composer.lock` lockfile pinning exact versions, installs everything under `vendor/`, and generates a PSR-4/PSR-0 **autoloader** (`vendor/autoload.php`) so PHP code can `require` it once and have every class lazily loaded by namespace.

What Composer pointedly does **not** solve is the **monorepo**. There is no first-class notion of a "workspace" containing many member packages, no topological build/test pipeline across members, and no caching of per-member task results. Composer's unit of work is _one root package and its dependency closure_. A PHP monorepo — multiple libraries and apps in one git repository, depending on each other locally before any of them is published — is therefore assembled from lower-level primitives that were designed for other purposes:

- **`path` repositories** point Composer at a sibling directory on disk and symlink it into `vendor/`, so an edit to a member library is immediately visible to a dependent app without a publish/`update` cycle.
- **The `replace` key** lets one package declare that it satisfies the requirements of others — the mechanism Symfony uses so that requiring `symfony/symfony` transparently fulfils every `symfony/*` component requirement.
- **Repository priority** (`canonical`, `exclude`, package filters, introduced/formalized in Composer 2) lets the local `path` repository win over Packagist for the in-repo packages.
- **External tooling** — most prominently [`symplify/monorepo-builder`][mrb] — layers the missing workspace ergonomics (merging member manifests into the root, validating version alignment, splitting members out to read-only repos) on top.

### Design philosophy

Composer is deliberately a **dependency manager, not a build system or task runner**. Its [`scripts`][scripts-doc] feature can shell out to test/lint commands, but it has no task DAG, no change detection, and no build cache; PHP is interpreted, so there is usually nothing to "compile". From the schema documentation, the `replace` key — the closest thing Composer has to a monorepo primitive — is described as ([`doc/04-schema.md`][schema-doc]):

> _"This is also useful for packages that contain sub-packages, for example the main symfony/symfony package contains all the Symfony Components which are also available as individual packages. If you require the main package it will automatically fulfill any requirement of one of the individual components, since it replaces them."_

That sentence is the whole monorepo story in one line: Composer never grew a `[workspace]` block (contrast [Cargo](../cargo/) or [`go.work`](../go-work/)); instead the community **repurposed** package-level features (`replace`, `path` repositories) and an external merge tool to approximate one. The resolver itself began life as a port of a Linux package manager's SAT solver — Composer's dependency-solving algorithm "started out as a PHP-based port of openSUSE's `libzypp` SAT solver" ([Composer on Wikipedia][wiki]) — which is why it reasons about a global, flat, conflict-free dependency set rather than per-member dependency trees the way [pnpm](../pnpm/) or [Yarn Berry](../yarn-berry/) do.

> [!NOTE]
> Several of the five research dimensions below have **no native Composer answer**. Where that is the case this deep-dive says so explicitly and documents the community/idiomatic workaround, because the _absence_ of a feature is itself the finding most relevant to a `dub` workspace proposal — `dub` today is in a very similar position (see [the dub baseline](../dub-baseline.md) once authored, and [the D landscape][d-landscape]).

---

## How it works

### The manifest, the lockfile, and the autoloader

A Composer project is rooted at a `composer.json`. The `require` and `require-dev` maps declare dependencies; `require` is _"a map of packages required by this package. The package will not be installed unless those requirements can be met"_ ([`doc/04-schema.md`][schema-doc]), and `require-dev` adds packages _"required for developing this package, or running tests"_ (skipped with `--no-dev`).

```json
{
  "name": "acme/blog-app",
  "type": "project",
  "require": {
    "php": ">=8.2",
    "acme/blog-core": "*"
  },
  "require-dev": {
    "phpunit/phpunit": "^11.0"
  },
  "autoload": {
    "psr-4": { "Acme\\Blog\\": "src/" }
  }
}
```

`composer install` resolves the closure, writes `composer.lock`, installs into `vendor/`, and regenerates `vendor/autoload.php`. The `autoload.psr-4` map binds a namespace prefix to a directory: _"when autoloading a class like `Foo\Bar\Baz` with a namespace prefix `Foo\` pointing to directory `src/`, the autoloader will look for a file named `src/Bar/Baz.php`."_ Critically, **the root package and every installed dependency contribute their `autoload` maps to one merged classmap** — this is how a symlinked monorepo member's classes become loadable from a dependent app with zero extra wiring.

### Resolution: one global, flat, conflict-free set

Composer's resolver (the `Pool`/`Solver` in `src/Composer/DependencyResolver/`) computes a **single flat set** of package versions that satisfies every constraint simultaneously — there is exactly one installed version of any given `vendor/name`. This is the opposite of Node's nested `node_modules` and of the isolated per-package trees that [pnpm](../pnpm/)'s content-addressed store produces. The trade-off (discussed under [Dependency Handling](#2-dependency-handling--isolation)) is that two monorepo members **cannot** depend on conflicting versions of a shared library; the whole repo shares one resolution.

### `path` repositories: the monorepo workhorse

The `repositories` array lets a project add package sources beyond Packagist. The `path` type points at a local directory:

```json
{
  "repositories": [
    {
      "type": "path",
      "url": "../../packages/*",
      "options": {
        "symlink": true
      }
    }
  ],
  "require": {
    "acme/blog-core": "*"
  }
}
```

Behavior, quoted from [`doc/05-repositories.md`][repos-doc]:

> _"The local package will be symlinked if possible, in which case the output in the console will read `Symlinking from ../../packages/my-package`. If symlinking is not possible the package will be copied."_

You can force the strategy: _"Instead of default fallback strategy you can force to use symlink with `"symlink": true` or mirroring with `"symlink": false` option."_ The URL supports globs — _"Repository paths can also contain wildcards like `*` and `?`"_ — which is the closest Composer comes to a glob-based **member discovery** mechanism (see [Workspace Declaration](#1-workspace-declaration--topology)).

Version derivation for a `path` package follows a hierarchy: _"the version may be inferred by the branch or tag that is currently checked out. Otherwise, the version should be explicitly defined in the package's `composer.json` file. If the version cannot be resolved by these means, it is assumed to be `dev-master`."_ In practice monorepo members are required with `"*"` or `"*@dev"` so the symlinked working copy always satisfies the constraint.

### Repository priority: making local win over Packagist

By default every repository is **canonical** — _"as soon as a package is found in one, Composer stops looking in other repositories"_ ([`doc/05-repositories.md`][repos-doc]) — and custom repositories are consulted before Packagist because they appear first in the array. The [repository-priorities article][priorities-doc] formalizes two knobs that monorepos rely on:

- **`"canonical": false`** makes Composer _"keep looking in other repositories, even if that repository contains a given package"_ — used when a local repo should _supplement_ rather than shadow Packagist.
- **`"exclude"`** removes specific packages from a repository's catalogue, e.g. excluding the in-repo packages from Packagist so the `path` repository is the only source:

```json
{
  "repositories": [
    { "type": "path", "url": "packages/*" },
    {
      "type": "composer",
      "url": "https://packagist.org",
      "exclude": ["acme/blog-core", "acme/blog-api"]
    }
  ]
}
```

The companion **package filters** (`only` / `exclude`) restrict which packages a repository may serve at all: _"You can also filter packages which a repository will be able to load, either by selecting which ones you want, or by excluding those you do not want."_

### `replace`: sub-package provisioning

`replace` is _"a map of packages that are replaced by this package"_ ([`doc/04-schema.md`][schema-doc]). In a monorepo it is used (notably by `monorepo-builder`, below) so the **root** package replaces every internal member at the exact same version, short-circuiting Packagist lookups for in-repo names. The docs warn: _"You should then typically only replace using `self.version` as a version constraint, to make sure the main package only replaces the sub-packages of that exact version."_

### `scripts`: the only "task" mechanism

Composer's [`scripts`][scripts-doc] map binds named events (lifecycle hooks like `post-install-cmd`, `post-update-cmd`, and arbitrary user-named scripts) to PHP callbacks or shell commands, run via `composer run-script <name>` (alias `composer run`, or just `composer <name>`):

```json
{
  "scripts": {
    "test": "phpunit",
    "lint": "php-cs-fixer fix --dry-run",
    "ci": ["@lint", "@test"]
  }
}
```

This is a flat list of commands, **not a DAG**: `@lint`/`@test` references run sequentially in declared order with no dependency graph, no parallelism, no change detection, and no caching of results. There is no built-in way to run `test` across every member of a monorepo — that requires shelling out to a loop or to `monorepo-builder`/a [Task runner](../task/).

### `monorepo-builder`: the community workspace layer

Because Composer ships no workspace model, the de-facto standard is [`symplify/monorepo-builder`][mrb], _"a set of tools for managing PHP monorepos: merging `composer.json` files, validating package versions, releasing with automation, and more."_ Its core commands fill Composer's gaps:

| Command                | What it does                                                                                       |
| ---------------------- | -------------------------------------------------------------------------------------------------- |
| `merge`                | Merges every member `composer.json` `require`/`require-dev`/`autoload` into the root manifest      |
| `validate`             | _"Checks that all packages use the same version for shared dependencies"_ (version alignment)      |
| `bump-interdependency` | _"Updates mutual dependencies between packages to a given version"_                                |
| `release`              | _"Automates the release process: bumping dependencies, tagging, pushing, and updating changelogs"_ |

By default _"`monorepo-builder merge` writes a `replace` section into the root `composer.json` listing every internal package at `self.version`"_ — exactly the `replace` + `self.version` pattern the schema docs recommend. Splitting members back out to individual read-only repositories (so consumers can `composer require acme/blog-core` from Packagist) is delegated to the [`symplify/github-action-monorepo-split`][split] GitHub Action.

---

## The five dimensions

### 1. Workspace Declaration & Topology

**No native workspace declaration.** Composer has no `[workspace]` table, no `members`/`packages` array, and no virtual-root concept analogous to [Cargo](../cargo/)'s `[workspace]`, [pnpm](../pnpm/)'s `pnpm-workspace.yaml`, or [`go.work`](../go-work/). A monorepo is **discovered indirectly** by a glob in a `path` repository URL:

```json
{ "repositories": [{ "type": "path", "url": "packages/*" }] }
```

That glob is the entire topology mechanism: Composer reads each matched subdirectory's `composer.json`, takes its declared `name`, and makes it installable. There is no exclusion list, no nested-workspace inheritance, and no distinction between a "root package workspace" and a "virtual workspace" — the root `composer.json` is always itself an installable package. `monorepo-builder` adds a `packageDirectories()` configuration (in `monorepo-builder.php`) to enumerate member globs for its `merge`/`validate` commands, but Composer proper never sees that file.

> [!WARNING]
> Because the glob is evaluated relative to the root and members are plain `path` entries, **there is no canonical "list the members" command in Composer itself.** Tooling and CI scripts re-derive the member set from the glob or from `monorepo-builder` configuration — a recurring source of drift this catalog's [comparison](../comparison.md) flags as the baseline failure mode that a native `dub` `[workspace]` block should fix.

### 2. Dependency Handling & Isolation

Composer uses a **single global, flat, hoisted resolution**: exactly one version of any package across the whole project, installed under one shared `vendor/`. There is **no isolation** between monorepo members — they share the one `vendor/` and the one merged autoloader — which is the opposite of [pnpm](../pnpm/)'s strict, content-addressed, per-package symlink trees or [Yarn Berry](../yarn-berry/)'s Plug'n'Play.

Cross-member local references are expressed with **`path` repositories + symlinks**: member `acme/blog-app` does `require: { "acme/blog-core": "*" }`, and the `path` repository symlinks `packages/blog-core` into `vendor/acme/blog-core`. Edits to the library are seen immediately (no `update` needed) precisely because the symlink _is_ the source tree. This is Composer's analogue of Yarn's [`workspace:` protocol](../yarn-berry/) — but spelled out per-member, manually, with a glob and a version constraint, rather than as a first-class `workspace:*` resolver protocol.

The consequence of the flat model: two members **cannot** depend on conflicting versions of a shared third-party library — the resolver must find one version that satisfies both. This is simultaneously a strength (guaranteed single version, no diamond duplication) and a hard constraint (no per-member version divergence), and it is exactly what `monorepo-builder validate` exists to police.

### 3. Task Orchestration & Scheduling

**No task DAG, no scheduler, no change detection.** Composer's only task surface is [`scripts`][scripts-doc], a flat ordered list run sequentially per event. There is:

- **No dependency graph between tasks** (script `@a` then `@b` is ordering, not a DAG).
- **No concurrency** — scripts run one after another in one process.
- **No input hashing or affected-detection** — Composer never asks "which members changed since `HEAD~1`"; it has no `--since`, no content hashing of task inputs, and no notion of a per-member task at all.
- **No "run X across all members"** primitive (contrast [`yarn workspaces foreach`](../yarn-berry/) or [Nx](../nx/)/[Turborepo](../turborepo/) target graphs).

Monorepo task orchestration is therefore **out of scope for Composer** and is handled by a separate layer: a shell loop over the member glob, a [Makefile](../make/) / [`just`](../just/) / [Task](../task/) recipe set, or `monorepo-builder` for the manifest-merge/release pipeline specifically. This is the single largest delta between Composer and the JS/TS orchestrators in this survey.

### 4. Caching & Remote Execution

Composer has **no build cache and no remote execution** — and this is by design, because **PHP is interpreted**: there is no compiled artifact to cache or to execute remotely. What Composer _does_ cache is **package downloads and metadata**:

- A local **files cache** of downloaded dist archives (`~/.cache/composer/files/`) and a **repo metadata cache** (`~/.cache/composer/repo/`), so re-installs and cross-project installs avoid re-fetching from Packagist/dist URLs.
- `composer.lock` provides **reproducibility** (pin exact versions), but it is a lockfile, not a task-result cache.

There is **no REAPI / remote-execution backend, no remote build cache** (contrast [Bazel](../bazel/)/[Buck2](../buck2/) with [BuildBuddy](../buildbuddy/)/[NativeLink](../nativelink/), or [Turborepo](../turborepo/)'s remote cache). The "build" of a monorepo member is, at most, regenerating the autoloader (`composer dump-autoload --optimize` builds a classmap), which is fast and uncached. For a `dub` proposal the lesson is narrow: Composer demonstrates a robust **download/metadata** cache and lockfile-based reproducibility, but contributes nothing on **task-output** caching.

### 5. CLI / UX Ergonomics

Composer's CLI is **whole-project, not member-scoped**. The core verbs are `composer install`, `composer update [vendor/package]`, `composer require "vendor/pkg:^2.0"`, `composer remove`, and `composer run-script <name>` (alias `composer run` / `composer <name>`). Crucially, per the [CLI docs][cli-doc]:

- There is **no `--filter`, no `-p`/`--package` target selector, no `--workspace`, no `--recursive`, and no `--since`** — none of the member-slicing ergonomics that define [pnpm](../pnpm/) (`--filter`), [Turborepo](../turborepo/) (`--filter`, `--since`), [Nx](../nx/) (`affected`), or [Yarn Berry](../yarn-berry/) (`workspaces foreach`).
- The only "selection" available is **glob string matching on package names** for a few read/maintenance commands: `composer update "vendor/*"`, `composer reinstall "acme/*"`, `composer show "monolog/*"`. These match _installed package names_, not _monorepo members as task targets_.

So a developer in a Composer monorepo runs `composer install` once at the root (resolving every symlinked member together) and then drives per-member tasks through an **external** loop or runner. There is no colon-syntax `:target`, no `-p app`, no topological broadcast. The command boundary stops at "resolve and install the closure"; everything monorepo-shaped lives above the CLI.

---

## Strengths

- **Ubiquitous and battle-tested** — the universal PHP dependency manager; every framework (Symfony, Laravel, Drupal) is Composer-native, and Packagist is a mature registry.
- **Correct, single-version resolution** — the SAT-based solver guarantees a flat, conflict-free dependency set, eliminating diamond duplication and "which copy am I loading?" ambiguity.
- **Zero-friction local development of members** — `path` repositories with symlinks make edits to a monorepo library instantly visible to dependents without a publish/`update` cycle.
- **Powerful repository-priority controls** — `canonical`, `exclude`, and package `only`/`exclude` filters give precise control over local-vs-remote sourcing, enough to build a working monorepo.
- **Merged autoloader across all packages** — root + dependencies + symlinked members all contribute to one PSR-4 classmap, so cross-member imports need no extra configuration.
- **Reproducible installs** — `composer.lock` plus a robust download/metadata cache.

## Weaknesses

- **No native workspace model at all** — no `[workspace]` block, no member array, no virtual root; the monorepo is reconstructed from `path` repositories + `replace` + a glob, with no canonical "list members" command.
- **No task DAG, concurrency, or change detection** — `scripts` is a flat sequential list; "run tests across all members" and "only what changed since `HEAD~1`" are entirely out of scope.
- **No build/test result caching or remote execution** — only download/metadata caching (mitigated by PHP being interpreted, but a hard ceiling for orchestration).
- **No member-slicing CLI** — no `--filter`/`-p`/`--since`/`--recursive`; member-scoped work needs an external loop or [Task](../task/)/[just](../just/)/[Make](../make/).
- **Flat resolution forbids per-member version divergence** — two members cannot use conflicting versions of a shared dependency.
- **Reliance on third-party glue** — robust PHP monorepos effectively require [`symplify/monorepo-builder`][mrb] plus a split action, none of it official.

## Key design decisions and trade-offs

| Decision                                                       | Rationale                                                                            | Trade-off                                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| Dependency manager, not a build system                         | PHP is interpreted; the hard problem is resolution + autoloading, not compilation    | No task DAG, no caching of task output, no orchestration — all pushed to external tools          |
| Single flat, hoisted resolution (one version per package)      | SAT solver (libzypp port) guarantees a conflict-free set; no diamond duplication     | Monorepo members cannot diverge on a shared dependency's version; whole repo shares resolution   |
| No native workspace; reuse `path` repos + `replace` + symlinks | Avoids a new manifest concept; reuses package-level features already in the resolver | Topology is implicit (a glob); no member registry, no member-aware CLI; needs `monorepo-builder` |
| Symlink `path` packages into `vendor/`                         | Instant local feedback on member edits without publish/`update`                      | Symlink/copy divergence across OSes; `replace` can short-circuit the symlink if misconfigured    |
| Repository priority via `canonical` / `exclude` / filters      | Precise, explicit control of local-vs-Packagist sourcing for in-repo names           | Verbose, per-package configuration; easy to misorder and accidentally shadow or duplicate        |
| `scripts` as flat ordered command lists                        | Simple, dependency-free hook mechanism for lint/test/release                         | No DAG, no parallelism, no change detection, no cross-member broadcast                           |
| Lockfile + download/metadata cache (no task cache)             | Reproducible installs and fast re-fetch across projects                              | Nothing accelerates repeated _builds/tests_; no remote cache or REAPI                            |

---

## Sources

- [composer/composer — GitHub repository][repo] (resolver lives in `src/Composer/DependencyResolver/`)
- [Composer documentation — getcomposer.org/doc][docs]
- [`doc/04-schema.md` — `replace`, `require`, `require-dev`, `version`, `autoload`, `scripts`][schema-doc]
- [`doc/05-repositories.md` — `path` repositories, symlink option, wildcards, canonical lookup][repos-doc]
- [`doc/articles/repository-priorities.md` — `canonical`, `exclude`, package filters][priorities-doc]
- [`doc/articles/scripts.md` — named events and `run-script`][scripts-doc]
- [`doc/03-cli.md` — command-line interface (no workspace/filter flags)][cli-doc]
- [Composer issue #9368 — "How to prefer local path package with canonical over remote Packagist in Composer 2?"][issue9368]
- [`symplify/monorepo-builder` — community monorepo tooling (merge/validate/release)][mrb]
- [`symplify/github-action-monorepo-split` — splitting members to read-only repos][split]
- [Composer (software) — Wikipedia (history, libzypp SAT-solver lineage)][wiki]
- [Packagist — the default Composer registry][packagist]
- Sibling deep-dives: [Cargo](../cargo/) · [npm](../npm/) · [pnpm](../pnpm/) · [Yarn Berry](../yarn-berry/) · [go-work](../go-work/) · [Poetry](../poetry/) · [Nx](../nx/) · [Turborepo](../turborepo/) · [Task](../task/) · [just](../just/) · [Make](../make/) · [Bazel](../bazel/) · [Buck2](../buck2/) · [BuildBuddy](../buildbuddy/) · [NativeLink](../nativelink/) · [comparison](../comparison.md) · [dub baseline](../dub-baseline.md) · [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/composer/composer
[docs]: https://getcomposer.org/doc/
[schema-doc]: https://getcomposer.org/doc/04-schema.md
[repos-doc]: https://getcomposer.org/doc/05-repositories.md
[priorities-doc]: https://getcomposer.org/doc/articles/repository-priorities.md
[scripts-doc]: https://getcomposer.org/doc/articles/scripts.md
[cli-doc]: https://getcomposer.org/doc/03-cli.md
[issue9368]: https://github.com/composer/composer/issues/9368
[mrb]: https://github.com/symplify/monorepo-builder
[split]: https://github.com/symplify/github-action-monorepo-split
[wiki]: https://en.wikipedia.org/wiki/Composer_(software)
[packagist]: https://packagist.org/
[d-landscape]: ../../async-io/d-landscape.md
