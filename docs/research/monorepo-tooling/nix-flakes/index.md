# Nix (flakes) (Polyglot glue)

A purely-functional, content-addressed build/package system whose _flake_ layer
turns any directory with a `flake.nix` into a hermetic, lock-pinned, composable
unit — making Nix the polyglot "glue" that pins, fetches, and wires together
multi-language monorepos that individual ecosystem tools (`cargo`, `npm`, `dub`)
can only see one slice of.

| Field           | Value                                                                                                        |
| --------------- | ------------------------------------------------------------------------------------------------------------ |
| Language        | C++ (evaluator/store, ~C++23); the Nix expression language for flake manifests                               |
| License         | LGPL-2.1-or-later                                                                                            |
| Repository      | [NixOS/nix][repo]                                                                                            |
| Documentation   | [Nix Reference Manual — `nix flake`][flake-md] · [nix.dev flakes guide][nixdev]                              |
| Category        | Polyglot Glue                                                                                                |
| Workspace model | Virtual graph of _flakes_: each `flake.nix` is a node; `inputs` are typed edges; a `flake.lock` pins the DAG |
| First released  | Flakes: Nix `2.4` (Nov 2021, [RFC 49][rfc49]); still gated behind the `flakes` experimental feature          |
| Latest release  | Nix `2.34.7` (2026-05-04); local checkout analysed here is `2.35.0`-dev on `master`                          |

> **Latest release:** upstream `Nix 2.34.7` (2026-05-04). Flakes are still
> formally an [_experimental feature_][xp] — `flakes` must be enabled in
> `nix.conf` or via `--extra-experimental-features 'nix-command flakes'`. The
> notable forks **Lix** (`2.94.0`) and **Determinate Nix** (`3.13.x`, tracking
> upstream `2.32.4`) ship the same flake schema (lock-file `version 7`). All
> source citations below are to the upstream `master` tree (`Nix 2.35.0`-dev,
> commit `41b28ad2e`) at [`src/libflake/`][libflake].

---

## Overview

### What it solves

Every language ecosystem ships its own package manager — `cargo` for Rust, `npm`
for JS, `pip`/`uv` for Python, `dub` for D — and each is blind to the others. A
real monorepo is usually polyglot: a Rust service, a TypeScript frontend, a D
CLI, plus the C libraries and system toolchains they all link against. No single
language tool can declare, pin, and reproducibly fetch _that_ whole graph. Nix
flakes do.

A **flake** is, per the manual, _"a filesystem tree (typically fetched from a Git
repository or a tarball) that contains a file named `flake.nix` in the root
directory"_ ([`src/nix/flake.md`][flake-md]). `flake.nix` declares two things:
`inputs` (typed references to _other_ flakes or raw source trees — pinned by
content hash) and `outputs` (a pure function from the realised inputs to an
attribute set of packages, dev shells, checks, NixOS modules, apps, …). Because
inputs are content-addressed and recorded in a machine-generated `flake.lock`,
**the entire transitive dependency graph is reproducible bit-for-bit** across
machines, with no ambient state.

Within this catalog Nix occupies a different layer than the language-native
tools. [`cargo`][cargo] resolves a Rust crate graph; [`go-work`][go-work]
stitches Go modules; [`pnpm`][pnpm] hoists a JS store. Nix sits _above_ all of
them: a flake input can be a nixpkgs snapshot, a pinned C library, a sibling
flake in the same repo, or a non-flake tarball, and the `outputs` function can
invoke any of those language tools inside a hermetic sandbox. It is the closest
thing the field has to a **universal, content-addressed lockfile + task graph for
arbitrary languages** — at the cost of requiring everything to be expressed in
the Nix language. Compare its all-encompassing-engine ambition with
[`bazel`][bazel] and [`buck2`][buck2] (which also model a polyglot, hermetic,
cached build DAG, but with their own non-purely-functional rule languages).

### Design philosophy

Flakes formalise three older Nix conventions — pinning inputs, a standard output
schema, and a discoverable entry point — into one composable unit. The manual's
own framing ([`src/nix/flake.md`][flake-md]):

> _"Flakes are the unit for packaging Nix code in a reproducible and discoverable
> way. They can have dependencies on other flakes, making it possible to have
> multi-repository Nix projects."_

Three consequences follow, and they shape the whole model:

1. **Inputs are pinned, not ranged.** Unlike SemVer constraint solvers
   ([`cargo`][cargo], [`npm`][npm]), a flake input resolves to an _exact_ locked
   revision plus a `narHash` of the fetched tree. There is no version solver and
   no "compatible range" — _"Inputs specified in `flake.nix` are typically
   'unlocked' … To ensure reproducibility, Nix will automatically generate and
   use a lock file called `flake.lock`"_ ([`flake.md`][flake-md]). The lock is a
   graph, not a flat list.

2. **`outputs` is a pure function.** It receives the _realised_ inputs (each with
   an `outPath` in the content-addressed store) and returns data — derivations,
   modules, shells. Evaluation is lazy and side-effect-free; the only impurity
   (fetching) is pushed to the edges and recorded in the lock.

3. **One standard output schema → discoverability.** `packages.<system>.<name>`,
   `devShells.<system>.<name>`, `checks.<system>.<name>`, `apps.<system>.<name>`
   ([`src/nix/flake-check.md`][check-md]) give the CLI a uniform place to look, so
   `nix build .#foo`, `nix run`, `nix develop`, and `nix flake check` work on
   _any_ flake without per-project configuration.

Nix is the polyglot data point in this survey the way [`bazel`][bazel] is the
polyglot orchestrator: both subordinate every language's native tool to a single
hermetic graph. For the D-specific stakes of all this, see the
[D async/build landscape][d-landscape]; the [`dub` baseline][dub-baseline] notes
that Sparkles itself is already built with a Nix flake.

---

## Core concepts and types

| Concept            | Type / file                                                | Role                                                                        |
| ------------------ | ---------------------------------------------------------- | --------------------------------------------------------------------------- |
| Flake reference    | `FlakeRef` ([`flakeref.cc`][flakeref])                     | A typed, parseable locator: `github:`, `git+`, `path:`, `tarball:`, …       |
| Indirect ref       | `type = "indirect"`                                        | Symbolic name resolved through the [flake registry][registry]               |
| Parsed flake       | `Flake` ([`flake.hh`][flakehh])                            | `originalRef` → `resolvedRef` → `lockedRef`, plus `inputs`, `config`        |
| Parsed input       | `FlakeInput` ([`flake.hh`][flakehh])                       | One `inputs.<id>` entry: a `ref`, an `isFlake` flag, `follows`, `overrides` |
| Lock graph         | `LockFile` / `Node` ([`lockfile.cc`][lockfile])            | The DAG written to `flake.lock`; `version 7`                                |
| Locked whole flake | `LockedFlake` ([`flake.hh`][flakehh])                      | `Flake` + `LockFile` + per-node `SourcePath`s + a `Fingerprint`             |
| Lock options       | `LockFlags` ([`flake.hh`][flakehh])                        | `recreateLockFile`, `updateLockFile`, `inputOverrides`, `inputUpdates`, …   |
| Lock algorithm     | `lockFlake` → `computeLocks` ([`flake.cc`][flake])         | Recursive topological resolution of the input graph                         |
| Output evaluator   | `callFlake` + [`call-flake.nix`][callflake]                | Lazily ties locked nodes into the `self`/`inputs` arguments of `outputs`    |
| Eval cache key     | `Fingerprint` (`Hash`) ([`flake.cc`][flake])               | Memoises evaluation per locked-flake + subdir + lock-file hash              |
| CLI installable    | `InstallableFlake` ([`installable-flake.cc`][installable]) | `flakeref#attrpath` → an output attribute to build/run                      |

---

## How it works

### A flake manifest

`flake.nix` is an attribute set with `description`, `inputs`, and `outputs`
([`flake.md`][flake-md]):

```nix
{
  description = "A flake for building Hello World";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-20.03";

  outputs = { self, nixpkgs }: {
    packages.x86_64-linux.default =
      with import nixpkgs { system = "x86_64-linux"; };
      stdenv.mkDerivation {
        name = "hello";
        src = self;
        buildPhase = "gcc -o hello ./hello.c";
        installPhase = "mkdir -p $out/bin; install -t $out/bin hello";
      };
  };
}
```

`outputs` is a function: its argument set is _"the outputs of each of the input
flakes keyed by their identifier"_, plus the special `self` input that refers to
_this_ flake's own outputs and source tree ([`flake.md`][flake-md]). The schema
of the returned set is conventional — `nix flake check` enforces that
`packages.<system>.<name>`, `devShells.<system>.<name>`, `checks.<system>.<name>`
and friends are derivations of the right kind ([`flake-check.md`][check-md]).

### Flake references: the typed locator

Every input and every CLI target is a `FlakeRef`, with both an attribute-set form
and a URL-like shorthand. The `type` discriminator drives a corresponding
fetcher ([`flake.md`][flake-md], [`flakeref.cc`][flakeref]):

| `type`                 | URL-like example                              | Fetched as                             |
| ---------------------- | --------------------------------------------- | -------------------------------------- |
| `indirect`             | `nixpkgs`, `nixpkgs/nixos-unstable`           | registry lookup → another ref          |
| `path`                 | `path:../lib`, `./sub/dir`                    | a local directory (no history)         |
| `git`                  | `git+https://example.org/repo?ref=main&rev=…` | a Git working tree / remote            |
| `github`               | `github:NixOS/nixpkgs/<rev-or-ref>`           | a GitHub **tarball** (no full history) |
| `gitlab` / `sourcehut` | `gitlab:veloren/veloren`                      | host-specific tarball                  |
| `tarball` / `file`     | `https://…/archive.tar.gz`                    | a content tree, hashed by `narHash`    |

The `github:` fetcher is the canonical optimisation: _"These are downloaded as
tarball archives, rather than through Git. This is often much faster and uses
less disk space since it doesn't require fetching the entire history"_
([`flake.md`][flake-md]). The relative `path:`/`./` form is what lets one repo's
flake depend on a **sibling flake in the same tree** — the monorepo cross-ref
primitive (see [Workspace declaration](#workspace-declaration--topology)).

### The lock file: a graph isomorphic to the dependency graph

`flake.lock` is JSON, currently `version 7` ([`lockfile.cc`][lockfile], where
`json["version"] = 7` and the reader rejects anything `< 5` or `> 7`). It is, per
the manual, _"a graph structure isomorphic to the graph of dependencies of the
root flake. Each node in the graph (except the root node) maps the (usually)
unlocked input specifications in `flake.nix` to locked input specifications"_
([`flake.md`][flake-md]):

```json
{
  "version": 7,
  "root": "n1",
  "nodes": {
    "n1": { "inputs": { "nixpkgs": "n2", "grcov": "n4" } },
    "n2": {
      "inputs": {},
      "locked": {
        "owner": "edolstra",
        "repo": "nixpkgs",
        "rev": "7f8d4b088e2df7fdb6b513bc2d6941f1d422a013",
        "type": "github",
        "lastModified": 1580555482,
        "narHash": "sha256-OnpEWzNxF/AU4KlqBXM2s5PWvfI5/BS6xQrPvkF5tO8="
      },
      "original": { "id": "nixpkgs", "type": "indirect" }
    }
  }
}
```

Each non-root node carries three keys: `original` (the unlocked spec from
`flake.nix`), `locked` (the resolved `fetchTree` args including `rev` and
`narHash`), and `inputs` (outgoing edges to other node labels). The graph form is
deliberate — it lets two flakes reference each other (a **cycle**), and it
de-duplicates shared transitive inputs into a single node. The root node omits
`original`/`locked` _"because we cannot record the commit hash or content hash of
the root flake, since modifying `flake.lock` will invalidate these"_
([`flake.md`][flake-md]).

> [!NOTE]
> `narHash` is what makes the lock substitutable from a binary cache: it lets Nix
> compute the store path of an input tree without re-fetching, and the other
> recorded attributes (`lastModified`, `revCount`) supply data not encoded in the
> store path. See [Caching](#caching--remote-execution).

### Resolving the lock: `computeLocks`

`lockFlake` ([`flake.cc`][flake]) drives lock generation through a single
recursive closure, `computeLocks`, that walks the input graph node-by-node. Its
signature captures the algorithm: it carries the inputs of the current node, the
target lock `Node`, the path of this node in the lock graph, the _old_ node (so
unchanged locks can be **copied verbatim** rather than re-fetched), and a
`followsPrefix` for resolving `follows`:

```cpp
// src/libflake/flake.cc — the recursive locker (signature, abridged)
std::function<void(
    const FlakeInputs & flakeInputs,
    ref<Node> node,
    const InputAttrPath & inputAttrPathPrefix,
    std::shared_ptr<const Node> oldNode,   // copy locks from here if unchanged
    const InputAttrPath & followsPrefix,
    const SourcePath & sourcePath,
    bool trustLock)>
    computeLocks;
```

For each input the closure: (1) collects ancestor **overrides**
(`inputs.nixops.inputs.nixpkgs.url = …`); (2) defers **`follows`** (a symbolic
edge to another node — it _"may refer to an input path we haven't processed
yet"_); (3) if there is no `ref`, synthesises an `indirect` ref to be resolved in
the registry; and (4) otherwise fetches/resolves the input, recursing into _its_
`flake.nix` inputs. Crucially, if the old lock already pins this input and the
spec is unchanged, the existing lock is reused, so `nix build` on an unchanged
tree fetches nothing.

### Evaluating outputs: `call-flake.nix`

Once the lock graph exists, `callFlake` hands it to a small Nix bootstrap script,
[`call-flake.nix`][callflake], which lazily reconstructs the `self`/`inputs`
arguments. It is the heart of the model and worth reading in full; the recursive
core:

```nix
# src/libflake/call-flake.nix (abridged)
allNodes = mapAttrs (
  key: node:
  let
    sourceInfo = if hasOverride then overrides.${key}.sourceInfo
                 else if isRelative then parentNode.sourceInfo      # path: sibling
                 else fetchTreeFinal (node.info or {} // removeAttrs node.locked ["dir"]);

    flake = import (outPath + "/flake.nix");

    # Tie each input id to the already-resolved result of its target node:
    inputs = mapAttrs (inputName: inputSpec: allNodes.${resolveInput inputSpec}.result)
               (node.inputs or {});

    # Call this flake's own outputs, threading `self`:
    outputs = flake.outputs (inputs // { self = result; });

    result = outputs // sourceInfo // { inherit outPath inputs outputs sourceInfo; _type = "flake"; };
  in { inherit result outPath sourceInfo; }
) lockFile.nodes;
in allNodes.${lockFile.root}.result
```

Three things stand out. First, the whole thing is one `mapAttrs` over the lock
graph with a `let`-bound `result` referenced inside `inputs` — Nix's laziness
turns the static graph into **demand-driven topological evaluation**: a node's
`outputs` is forced only when something pulls on it, and `self = result` closes
the self-reference. Second, `resolveInput` chases `follows` edges (`["dwarffs"
"nixpkgs"]`) back through the root. Third, `isRelative` `path:` inputs reuse the
**parent's** `sourceInfo` and append a subpath — that is exactly how a sibling
flake in the same repo is wired without re-fetching anything.

### CLI resolution: `flakeref#attrpath`

On the command line a target is `<flakeref>#<attrpath>`. `InstallableFlake`
([`installable-flake.cc`][installable]) locks the flake, opens its eval cache,
and walks the attribute path; if the fragment is empty it tries a list of default
prefixes ([`installables.cc`][installables]):

```cpp
// src/libcmd/installables.cc — default attr paths / prefixes (abridged)
Strings getDefaultFlakeAttrPaths()      // bare `nix build .`
{ return {"packages." + thisSystem + ".default", "defaultPackage." + thisSystem}; }

Strings getDefaultFlakeAttrPathPrefixes() // `nix build .#hello`
{ return { "packages." + thisSystem + ".", /* … */ }; }
```

So `nix build .#hello` becomes `packages.<system>.hello`, and a bare `nix build`
resolves `packages.<system>.default` — the uniform schema doing the navigation.

---

## Workspace declaration & topology

Nix has **no `[workspace]` block, no `members` glob, and no monorepo concept in
the manifest.** Topology is expressed entirely through the `inputs` graph: a
monorepo is modelled as one root flake whose `inputs` point at the constituent
flakes — including sibling directories in the _same_ repository via relative
`path:` (or `git+file:`) references.

```nix
# Root flake.nix of a polyglot monorepo (illustrative)
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    # Sibling flakes in the same tree — the cross-ref primitive:
    core-cli.url = "path:./libs/core-cli";
    backend.url  = "path:./apps/backend";
    backend.inputs.nixpkgs.follows = "nixpkgs";   # dedupe transitive nixpkgs
  };
  outputs = { self, nixpkgs, core-cli, backend }: { /* compose them */ };
}
```

Discovery semantics ([`flake.md`][flake-md]):

- **No globbing.** Members are enumerated explicitly under `inputs`; there is no
  `members = ["libs/*"]` array as in [`cargo`][cargo] or [`pnpm`][pnpm]. (Some
  community frameworks — `flake-parts`, `flake-utils` — add ergonomic
  module/`eachSystem` sugar _on top_, but the core has no native member glob.)
- **Relative `path:` is the local cross-ref.** _"a `flake.nix` in the root of a
  tree can use `path:./foo` to access the flake in subdirectory `foo`, but
  `path:../bar` is illegal"_ — relative path inputs must stay inside the same
  tree, and a relative-path node reuses the parent's fetched `sourceInfo`
  ([`call-flake.nix`][callflake]).
- **Upward `flake.nix` search.** Given a path with no `flake.nix`, Nix searches
  upward _"until it finds … the Git repository root, or the filesystem root, or a
  folder on a different mount point"_ — so `.` resolves to the enclosing flake.
- **Sub-directory flakes.** The `dir=` parameter _"enables having multiple flakes
  in a repository or tarball"_; the `subdir` is appended to the fetched
  `outPath`.

> [!IMPORTANT]
> This is a fundamentally different topology model than the rest of the catalog.
> Where [`go-work`][go-work], [`cargo`][cargo] and [`pnpm`][pnpm] have a
> dedicated _root manifest that lists members_, Nix has a **single uniform node
> type (the flake) recursively composed by typed references**. Every member is a
> first-class flake in its own right — there is no privileged "virtual root."

## Dependency handling & isolation

Isolation in Nix is total and predates flakes: every build output lives at a
**content-addressed store path** `/nix/store/<hash>-<name>`, where the hash
derives from all build inputs. There is no hoisting, no symlink tree to
de-duplicate, and no shared mutable `node_modules`/`target` — two flakes that
depend on different `nixpkgs` revisions get two distinct store paths and never
collide. This is a stronger isolation guarantee than the
[virtual-store][pnpm] / [hoisting][npm] schemes of the JS world.

Flake-level dependency handling adds three operators on top of the input graph
([`flake.md`][flake-md]):

- **`follows` — deduplication.** `inputs.nixops.inputs.nixpkgs.follows =
"nixpkgs"` rewrites a transitive input to point at an existing node, collapsing
  N copies of nixpkgs into one. _"The value of the `follows` attribute is a
  `/`-separated sequence of input names denoting the path of inputs to be
  followed from the root flake."_ This is the flake analogue of a workspace
  catalog/inheritance — one pinned `nixpkgs`, referenced everywhere.
- **Transitive override.** `inputs.nixops.inputs.nixpkgs.url = …` replaces a
  dependency's dependency outright. `computeLocks` records these in an `overrides`
  map keyed by the full input attr-path ([`flake.cc`][flake]).
- **Non-flake inputs.** `inputs.grcov = { …; flake = false; }` pins a raw source
  tree (no `flake.nix`) as a content-addressed input — how a Nix flake pins a
  plain C library, a vendored blob, or another language's repo.

Cross-workspace local references are the relative `path:` inputs described above:
a member flake is depended on by store-path identity, not by publishing to a
registry. The lock pins each by `narHash`, so the local graph is as reproducible
as the remote one.

## Task orchestration & scheduling

Flakes do not have a _task pipeline_ in the [`turborepo`][turborepo]/[`nx`][nx]
sense (named tasks with `dependsOn` edges). Instead, the **task DAG _is_ the
derivation graph**, one layer below flakes, and it is the oldest part of Nix:

- **The DAG.** Every `mkDerivation` (and thus every package, dev shell, or
  `checks.<system>.<name>`) is a node; its `inputDrvs` are edges. Nix computes
  this graph by lazily evaluating the flake `outputs`, then realises it.
- **Change detection by input hashing.** A derivation's store path is a hash of
  _all_ its inputs (sources, dependencies, builder, env). If nothing in that
  closure changed, the output already exists in the store and is **not rebuilt** —
  this is content-addressed change detection, equivalent in spirit to
  [`turborepo`][turborepo]'s input hashing but applied to the whole build graph,
  not just declared task inputs.
- **Concurrent execution.** The builder schedules independent derivations in
  parallel up to `--max-jobs N` (local) and `--cores N` (per-build), and can
  offload to remote builders (`--builders`) — a distributed build scheduler.
- **`nix flake check` as the aggregate task.** It evaluates the flake and builds
  every `checks.<system>.<name>` derivation ([`flake-check.md`][check-md]) — the
  closest flake-level analogue to "run all the monorepo's tests," with parallel
  per-check scheduling and `--keep-going` to collect all failures.

What flakes lack relative to dedicated orchestrators: there is no notion of
_affected-since-a-git-ref_ selection at the flake layer (you express that by
which derivations you ask to build), and no per-task input/output declaration
distinct from the derivation graph. The trade is that Nix's change detection is
sound by construction (it hashes the real closure), where a `turbo`/`nx` task
graph relies on the user declaring `inputs`/`outputs` correctly.

## Caching & remote execution

This is Nix's deepest strength, and it operates at two layers:

1. **The content-addressed store as a local cache.** A realised derivation is
   keyed by the hash of its full input closure; rebuilding is a store lookup. The
   flake **evaluation** layer is cached separately by a `Fingerprint`
   ([`flake.cc`][flake]):

   ```cpp
   // src/libflake/flake.cc — LockedFlake::getFingerprint (abridged)
   auto fingerprint = flake.lockedRef.input.getFingerprint(store);
   *fingerprint += fmt(";%s;%s", flake.lockedRef.subdir, lockFile);
   // … plus revCount / lastModified when they affect evaluation
   ```

   Because the fingerprint folds in the locked ref, the subdir, and the full lock
   file, an unchanged locked flake reuses its cached evaluation — so repeated
   `nix build`/`nix flake show` on a pinned tree skip both fetching _and_
   re-evaluation.

2. **Binary caches as remote build caches.** Any store path can be pushed to /
   pulled from a **binary cache** (`cache.nixos.org`, an S3 bucket, a
   self-hosted [Attic]/Cachix, or any HTTP store). Before building, Nix queries
   substituters and **downloads the prebuilt output** if its hash is present —
   exactly the remote-cache hit that [`turborepo`][turborepo] and [`bazel`][bazel]
   provide, but for arbitrary builds and shared across an entire organisation or
   the public. The flake lock's `narHash` is what lets an _input tree_ also be
   substituted from a cache without re-fetching ([`flake.md`][flake-md]).

3. **Remote / distributed execution.** Nix's `--builders` mechanism farms
   individual derivations out to remote machines (including cross-architecture
   builders), and the [Hydra] CI system is a flake-aware distributed build farm.
   This is Nix's own protocol rather than the Bazel **REAPI** that
   [`buildbarn`][buildbarn] / [`buildbuddy`][buildbuddy] / [`nativelink`][nativelink]
   implement — Nix predates and sits orthogonal to REAPI — but it delivers the
   same remote-execution + shared-cache outcome.

> [!NOTE]
> The crucial difference from a per-language cache: Nix's cache key is the
> _entire_ build closure including the C toolchain, libc, and every transitive
> dependency. A cache hit is therefore an exact-environment hit, not "same
> package version, maybe different system libraries."

## CLI / UX ergonomics

The flake CLI is the `nix` "new CLI" (also experimental: `nix-command`). The
command boundary is **a flake reference plus a `#`-fragment attribute path**,
with sensible defaults filled from the standard output schema:

```bash
nix build .#core-cli            # build packages.<system>.core-cli of the local flake
nix build                       # … .default (getDefaultFlakeAttrPaths)
nix run .#backend -- --serve    # run apps.<system>.backend
nix develop .#core-cli          # enter that package's dev shell
nix flake show                  # tree of all outputs (the schema, rendered)
nix flake check                 # evaluate + build every checks.<system>.<name>
nix flake metadata              # resolved/locked URL + the input tree
nix build github:NixOS/nixpkgs#hello   # a remote flake, no checkout
```

Lock-file ergonomics are a small, sharp command family ([`flake-update.md`][update-md]):

| Command                              | Effect                                                          |
| ------------------------------------ | --------------------------------------------------------------- |
| `nix flake lock`                     | create/extend the lock; **never** changes already-locked inputs |
| `nix flake update`                   | re-lock **all** inputs from scratch                             |
| `nix flake update nixpkgs`           | update **only** the named input(s) — _targeted_ slicing         |
| `nix flake update --flake ~/other`   | operate on a flake in another directory                         |
| `nix build … --override-input X ref` | one-shot input substitution without touching the lock           |

> [!NOTE]
> `nix flake update <input>` _"takes a list of names of inputs to update as its
> positional arguments"_ ([`flake-update.md`][update-md]) — this is the flake
> analogue of [`cargo update -p <crate>`][cargo] / `pnpm --filter`: targeted
> re-locking of one member's pin without disturbing the rest of the graph.

The ergonomic cost is the **fragment vs. flake-ref split** (`.#attr` everywhere),
the requirement to enable two experimental features, and the fact that the unit
of selection is an _output attribute_, not a "package by name with a filter
flag." There is no `--filter`/`-p`/`--since` family; selection happens by which
attribute path (and thus which sub-flake or sub-derivation) you name.

---

## Strengths

- **True polyglot reproducibility.** One lock file pins a Rust crate snapshot, a
  C library, a nixpkgs revision, and sibling flakes — by content hash, across
  machines — which no single-language tool can do.
- **Total isolation, no hoisting.** Content-addressed store paths eliminate the
  shared-mutable-`node_modules`/`target` class of bugs outright; conflicting
  dependency versions simply get distinct paths.
- **Best-in-class caching.** Local store + organisation/public binary caches give
  exact-environment cache hits for arbitrary builds, plus separate evaluation
  caching via the locked-flake `Fingerprint`.
- **Sound change detection.** The rebuild decision is a hash of the real build
  closure, not a user-declared task input list, so it cannot silently miss a
  dependency.
- **Uniform discoverable schema.** `packages`/`devShells`/`checks`/`apps` let
  `nix build`/`run`/`develop`/`flake check` work on any flake with no config.
- **Composable graph with `follows`/overrides.** Transitive dedup and override
  give precise control over a large, shared dependency graph.
- **Distributed/remote builds** via `--builders` and Hydra, plus cross-arch
  remote builders.

## Weaknesses

- **The Nix language is the price of admission.** Everything — manifest, build
  rules, glue — is written in a lazy purely-functional DSL with a famously steep
  learning curve, unfamiliar to most ecosystem developers.
- **Still "experimental."** Flakes have shipped in production for years but remain
  gated behind the `flakes` + `nix-command` experimental features
  ([`experimental-features.cc`][xp]); the surface can still change.
- **No native workspace/member globbing.** Monorepo members are enumerated by
  hand under `inputs`; there is no `members = ["libs/*"]`, and the relative-path
  cross-ref discipline (`path:./foo` only, never `../`) is restrictive.
- **No task-pipeline layer.** No named tasks with `dependsOn`, no `--filter`,
  no _affected-since-`HEAD~1`_ selection at the flake layer; you express slicing
  by which attribute path you build.
- **Pinned, not ranged.** No SemVer solver — updates are wholesale or
  per-input re-locks, which is reproducible but can mean coarse, manual bumps.
- **Operational weight.** A populated `/nix/store`, the daemon, and binary-cache
  configuration are heavier than dropping a `package.json` into a repo.
- **Fragmented governance.** Upstream Nix, **Lix**, and **Determinate Nix** are
  three implementations of the same flake schema — convergent today, but a
  long-term coordination risk.

## Key design decisions and trade-offs

| Decision                                                | Rationale                                                                                | Trade-off                                                                                  |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Topology via a typed `inputs` graph (no `[workspace]`)  | One uniform node type (the flake) composes recursively; remote + local treated alike     | No member globbing; monorepo members listed by hand; relative-path cross-refs are limited  |
| Pin inputs to exact rev + `narHash` (no version solver) | Bit-for-bit reproducibility; lock is substitutable from a cache                          | No "compatible range" resolution; updates are wholesale or per-input, sometimes coarse     |
| Lock file as a graph isomorphic to the dep graph        | De-dupes shared transitive inputs; supports cycles; `follows` rewrites edges cheaply     | More complex than a flat list; the graph/`follows` semantics confuse newcomers             |
| `outputs` is a pure lazy function over realised inputs  | Demand-driven topological evaluation; side-effect-free; cacheable by `Fingerprint`       | Requires expressing everything in the Nix language; debugging laziness is hard             |
| Content-addressed store, no hoisting                    | Total isolation; conflicting versions coexist; exact-environment cache hits              | A large `/nix/store` and daemon; disk-heavy vs. a hoisted symlink tree                     |
| Caching at the build closure, not the package version   | Cache hits include the toolchain/libc — genuinely reproducible across machines           | Larger cache keys; a toolchain bump invalidates everything downstream                      |
| Flakes gated behind an experimental feature             | Lets the schema stabilise (lock `version 7`) before a stability commitment               | Years of "experimental" friction; every invocation needs the feature flags enabled         |
| CLI selects by `#attrpath`, not `--filter`/`-p`         | The uniform output schema _is_ the addressing scheme; remote and local targets identical | No affected-detection / `--since`; coarser than a dedicated task orchestrator's filter set |

---

## What `dub` could borrow

- **A content-hash-pinned, graph-shaped lock file.** `flake.lock`'s `original` →
  `locked` (`rev` + `narHash`) per node, isomorphic to the dependency graph, is a
  far stronger reproducibility story than `dub.selections.json`'s flat
  version map. A `dub` workspace lock that records resolved commits/hashes and
  de-duplicates shared transitive deps would pin a whole monorepo exactly.
- **`follows`-style transitive dedup.** Letting a `dub` workspace force every
  member's transitive `vibe-d` (etc.) to one pinned node — the flake `follows`
  operator — directly addresses the version-drift the proposal targets, without a
  central `[workspace.dependencies]` solver.
- **Relative-path local cross-refs as a first-class, lockable input.** Nix's
  `path:./libs/core-cli` (reusing the parent's fetched tree, pinned by `narHash`)
  is exactly the local-first cross-reference `dub` wants instead of bare relative
  `path=` overrides — depend on a neighbour by identity and lock it.
- **Evaluation caching keyed by a fingerprint of the locked inputs.** Nix's
  `LockedFlake::getFingerprint` (locked ref + subdir + lock hash) shows how to
  skip re-resolution/re-evaluation when the lock is unchanged — a cheap win for
  repeated `dub build`/`dub test` across a large workspace.

---

## Sources

- [NixOS/nix — GitHub repository][repo]
- [`src/nix/flake.md` — flake references, `flake.nix` schema, lock-file format (verbatim quotes above)][flake-md]
- [`src/libflake/flake.cc` — `lockFlake`/`computeLocks`, the recursive locker; `getFingerprint`][flake]
- [`src/libflake/call-flake.nix` — lazy recursive output evaluation, `self`/`inputs` wiring][callflake]
- [`src/libflake/lockfile.cc` — `flake.lock` `version 7` read/write][lockfile]
- [`src/libflake/flakeref.cc` — `FlakeRef` parsing][flakeref]
- [`src/libflake/include/nix/flake/flake.hh` — `Flake`, `FlakeInput`, `LockFlags`, `LockedFlake`][flakehh]
- [`src/libcmd/installable-flake.cc` + `installables.cc` — `flakeref#attrpath`, default attr paths/prefixes][installable]
- [`src/nix/flake-check.md` — output schema enforced by `nix flake check`][check-md]
- [`src/nix/flake-update.md` — targeted vs. wholesale re-locking][update-md]
- [`src/libutil/experimental-features.cc` — the `flakes` experimental feature gate][xp]
- [RFC 49 — Flakes (the design RFC)][rfc49]
- [nix.dev — Flakes guide][nixdev]
- Sibling deep-dives: [`cargo`][cargo] · [`go-work`][go-work] · [`pnpm`][pnpm] · [`npm`][npm] · [`turborepo`][turborepo] · [`nx`][nx] · [`bazel`][bazel] · [`buck2`][buck2] · [`buildbarn`][buildbarn] · [`buildbuddy`][buildbuddy] · [`nativelink`][nativelink] · the [`dub` baseline][dub-baseline] · the [D landscape][d-landscape]

<!-- References -->

[repo]: https://github.com/NixOS/nix
[libflake]: https://github.com/NixOS/nix/tree/master/src/libflake
[flake-md]: https://github.com/NixOS/nix/blob/master/src/nix/flake.md
[flake]: https://github.com/NixOS/nix/blob/master/src/libflake/flake.cc
[callflake]: https://github.com/NixOS/nix/blob/master/src/libflake/call-flake.nix
[lockfile]: https://github.com/NixOS/nix/blob/master/src/libflake/lockfile.cc
[flakeref]: https://github.com/NixOS/nix/blob/master/src/libflake/flakeref.cc
[flakehh]: https://github.com/NixOS/nix/blob/master/src/libflake/include/nix/flake/flake.hh
[installable]: https://github.com/NixOS/nix/blob/master/src/libcmd/installable-flake.cc
[installables]: https://github.com/NixOS/nix/blob/master/src/libcmd/installables.cc
[check-md]: https://github.com/NixOS/nix/blob/master/src/nix/flake-check.md
[update-md]: https://github.com/NixOS/nix/blob/master/src/nix/flake-update.md
[xp]: https://github.com/NixOS/nix/blob/master/src/libutil/experimental-features.cc
[registry]: https://nix.dev/manual/nix/latest/command-ref/new-cli/nix3-registry
[rfc49]: https://github.com/NixOS/rfcs/pull/49
[nixdev]: https://nix.dev/concepts/flakes.html
[Attic]: https://github.com/zhaofengli/attic
[Hydra]: https://github.com/NixOS/hydra
[cargo]: ../cargo/
[go-work]: ../go-work/
[pnpm]: ../pnpm/
[npm]: ../npm/
[turborepo]: ../turborepo/
[nx]: ../nx/
[bazel]: ../bazel/
[buck2]: ../buck2/
[buildbarn]: ../buildbarn/
[buildbuddy]: ../buildbuddy/
[nativelink]: ../nativelink/
[dub-baseline]: ../dub-baseline.md
[d-landscape]: ../../async-io/d-landscape.md
