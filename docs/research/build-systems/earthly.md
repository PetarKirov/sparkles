# Earthly (Go)

A `Dockerfile`-shaped frontend that lowers each `Earthfile` target into a
[BuildKit][buildkit] LLB graph, inheriting its content-addressed cache and
parallel solver, plus a whole-target "already ran" key. Frozen since July 2025.

| Field         | Value                                                                                                       |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| Language      | Go (`go 1.21` module [`go.mod`][gomod]); `Earthfile` is a custom DSL parsed by the in-tree `ast` package    |
| License       | MPL-2.0 (`LICENSE`)                                                                                         |
| Repository    | [`earthly/earthly`][repo]; docs in-tree under [`docs/`][caching-doc]                                        |
| Documentation | `docs/` (also published as `docs.earthly.dev`)                                                              |
| Category      | Container / CI-oriented — a BuildKit frontend, not a package manager                                        |
| Clone SHA     | `996e152f54aed191800168b4db20c47f923b716d` (HEAD; README carries the unmaintained notice)                   |
| Release state | `v0.8.16` (2025-07-16) — the final release, which stripped the Cloud features ([`CHANGELOG.md`][changelog]) |

**Last reviewed:** November 2, 2026

> [!WARNING]
> The project is **unmaintained**. Its README opens with _"Earthly Technologies
> has ended active maintenance of the Earthly open-source project, and Earthly
> Cloud (including Satellites) was shut down on July 16th, 2025."_ It names a
> community fork, EarthBuild. Everything below reads the pinned commit as a
> design data point, not as a tool to adopt.

## Overview

### What it solves

Earthly targets the gap between a language's tooling and a CI provider's YAML:
builds run in containers, are described by one file per component, and are
cached and parallelized by the engine rather than by hand-tuned jobs. Its
dependency model is declared, never observed:

> "Earthly executes builds in containers, where execution is isolated. The
> dependencies of the build are explicitly specified in the build definition,
> thus making the build self-sufficient."
>
> — [`README.md`][readme]

That places Earthly opposite BuildXL and Rattle here: declared-only, like
[BuildKit][buildkit].

### Design philosophy

The DSL is a build-graph language — statements map one-to-one onto LLB ops, so
the graph exists before execution and BuildKit can key it. Containers are the
isolation unit (no syscall interposer), and caching is layered by granularity:
per-command layers, cache mounts, then a coarse opt-in whole-target hash.

## How it works

### Lowering: `Earthfile` → `pllb.State` → LLB protobuf

`ast` parses the file into `spec.Earthfile`; `Interpreter.Run` walks the base
recipe and the selected target's statements, calling one `Converter` method per
command ([`interpreter.go`][interpreter]). The converter is a mutable per-target
accumulator — `MainState`, `ArtifactsState`, `MainImage`, `VarCollection` — in
[`states.go`][states]:

| Statement      | Lowering effect                                                                        |
| -------------- | -------------------------------------------------------------------------------------- |
| `FROM image`   | `MainState` becomes a new `pllb.Image` state                                           |
| `FROM +target` | the dependency's `SingleTarget.MainState` is **assigned** to this target's `MainState` |
| `RUN`          | appends `state.Run(runOpts...).Root()` to `MainState`                                  |
| `BUILD +t`     | converts `+t` as its own target; async when arguments are statically known             |

`FROM +target` is the structural trick: inheritance is a pointer handoff, not a
merge — _"Pass on dep state over to this state."_ ([`converter.go`][converter]).
`HasDangling` records whether non-`SAVE` commands follow the first `SAVE`, or
whether the target was reached through `BUILD` rather than `COPY`/`FROM`
([`states.go`][states]) — the encoding of "consume" vs. "realize".

BuildKit's `llb.State` is not goroutine-safe, so concurrent lowering goes through
a wrapper that serialises every interaction behind one mutex:

> "Package pllb is a wrapper around llb, which makes it compatible with
> concurrent code. The standard BuildKit llb package does not allow llb.State to
> be used from different goroutines."
>
> — [`util/llbutil/pllb/state.go`][pllb]

`global.conversion_parallelism` bounds that work ([`build_cmd.go`][build-cmd]);
duplicate targets are deduplicated by a hash of `(target, platform,
allow-privileged, build args)` ([`visited-upfront-hash.go`][visited-upfront]).
`StateToRef` then marshals the state and calls `gwClient.Solve` — after which
scheduling and caching are BuildKit's ([`statetoref.go`][statetoref]).

**Conversion can execute.** `IF` with a shell expression calls
`Converter.RunExitCode`, which builds a transient state, solves it, and reads the
exit code before choosing the branch ([`interpreter.go`][interpreter],
[`converter.go`][converter]). Graph construction is _staged_: some of the shape
is decided by work already performed.

### Auto-skip: one hash over a target's whole input closure

`--auto-skip` (and per-`BUILD` `--auto-skip`) is Earthly's addition above
BuildKit's cache. `inputgraph.HashTarget` walks the target and every target it
references, hashing each statement's name and JSON-marshalled arguments — so an
`ARG` default or `RUN` string change is visible
([`loader_hashing.go`][loader-hashing]) — and every file a classical `COPY`
expands to, by **name, size and content** ([`hasher.go`][hasher]), not mtime or
mode. Remote targets must be pinned to a full SHA or `tags/…`
([`hash.go`][input-hash]); dynamic constructs are an **error**, not an
over-approximation ([`loader.go`][input-loader]). The hash is looked up in a
`BuildkitSkipper` (`Exists`/`Add`); the recorded target name additionally carries
local git metadata, and the docs describe the store as a global cloud database:

> "Unlike layer caching, auto-skip is an all-or-nothing type of cache. Either
> the entire target is skipped, or none of it is. This is because Earthly does
> not know which parts of the target are affected by the change."
>
> — [`docs/caching/caching-in-earthfiles.md`][caching-doc]

At this commit that documentation is stale: with Cloud removed, the only
implementation is a local BoltDB opened from `--auto-skip-db-path`, and an empty
path returns `nil`, disabling the feature
([`buildkitskipper_create.go`][skip-create], [`local.go`][skip-local]).
`cmd/earthly/subcmd/` has no satellite subcommand either, yet
[`docs/remote-runners.md`][remote-doc] still advertises Satellites.

## Analysis spine

**Static DAG × constructive traces**, with a second, coarser rebuilder bolted
on. The DAG half matches BuildKit and therefore the cell [concepts] names
`CloudBuild`: every edge is declared before execution, and the "scheduler" is
demand-driven dataflow rather than a topological sort. The rebuilder is a
constructive trace — a key over a normalized op plus its inputs, whose value is a
real snapshot. `--auto-skip` is a different key at a different granularity: one
bit per _target_, derived by hashing its declared closure. Concepts' grid allows
one rebuilder per key; Earthly composes two, and the coarse one is a dirty bit in
all but name. Staged `IF` execution is a twist the paper's three schedulers do
not name.

### 1. Task model & scheduling

The task is a **target** — `(Earthfile path, target name, build args, platform)`
— whose body is a straight-line statement sequence. Dependencies are the
`FROM`/`COPY`/`BUILD` references met while interpreting it, so the graph is
static but _discovered by walking the DSL_, not by running steps. Independent
`BUILD`s lower asynchronously (`BuildAsync`) under the semaphore, then BuildKit
schedules the vertices; `WAIT` blocks are explicit barriers. The graph's shape is
the schedule.

### 2. Rebuilding & correctness

Two hash-based levels. **Per command**, BuildKit reuses a layer when the op's
inputs match (`ARG` values, `COPY`'d content, command text), with early cutoff
inherited from its key structure; `--no-cache` bypasses it. **Per target**,
`--auto-skip` answers "has this exact closure already succeeded?" — a hit skips
the target without consulting the layer cache, a miss falls back to normal reuse.

The split is the weakness as well as the idea. The target key hashes content but
ignores mode, ownership and mtime, so a `chmod +x` without a content change can
pass the skip; dynamic constructs are refused rather than approximated.
Minimality is exact in the BuildKit direction and all-or-nothing in the skip
direction. Correctness rests entirely on declaration — an undeclared input is
invisible and no output is verified.

### 3. Dependency discovery

Declared, with two qualifications. Classical `COPY` patterns are expanded at
hash time by the auto-skip loader (`expandCopyFiles`, no `**` support) — static
expansion, not observation. Nothing intercepts syscalls, so a `RUN` reading an
undeclared file or fetching over the network produces a cache entry BuildKit
cannot distinguish from a sound one. `LOCALLY` steps sit outside both tiers.

### 4. Store & caching

Earthly owns no store. Layers, snapshots and the content store belong to the
BuildKit daemon (`earthly-buildkitd`, started as a container); export and import
are BuildKit's registry mechanisms, selected by `--remote-cache`,
`--use-inline-cache` and `--save-inline-cache` ([`global.go`][flags]). Cache
mounts (`CACHE`, `RUN --mount=type=cache`) are the exception: persistent
directories outside the key — right for package managers, wrong for
reproducibility. The only datastore Earthly adds is the auto-skip key/value store.

### 5. Hermeticity & provenance

Hermeticity is the container: namespaces, an image filesystem built by declared
copies, secrets as BuildKit secret mounts. The engine learns nothing from that
isolation, so an undeclared read yields a silently unsound cache entry. A search
outside vendored dependencies finds no provenance, attestation, SLSA or SBOM
code. `LOCALLY` is the sanctioned hole.

### 6. Distribution

Present as _remote daemon_, absent as _remote execution protocol_. The CLI can
point at any BuildKit over `--buildkit-host`, and cache travels through a
registry; before the shutdown, Satellites were managed BuildKit instances.
No REAPI client exists in the tree, so Earthly never dispatched individual actions
to workers — it moved the whole solve plus its cache, and that service is gone.

### 7. Sparkles relevance

- **Compile the recipe, don't interpret it at run time.** `earthfile2llb` is the
  cleanest example here of turning a per-project script into a task DAG with
  engine-owned keys. A `dub`-side equivalent — parse the recipe, emit a
  `TaskDag`, let the executor key it — is the structural lesson for
  `sparkles.build_primitives.task`.
- **Two key tiers, coarse above fine.** A whole-target content hash answers "was
  this affected?" cheaply, which is what a monorepo filter wants; per-task keys
  still decide reuse. Earthly's mistake is that the tiers are disconnected.
- **Refuse to guess, and hash content.** A dynamic `COPY` source or uninferable
  `IF` becomes a hard error under `--auto-skip`; `HashFile` reads bytes, the small
  copyable piece (extend it to mode).
- **Do not copy** the container-per-step cost, the daemon dependency, or a cloud
  key store.

### Delta from the monorepo-tooling page

[The monorepo deep-dive][mono-earthly] covers `+target` topology, cross-repo
references, container-as-isolation, CLI ergonomics and the shutdown. This page
adds the engine view: the `Earthfile`→`LLB` lowering, the auto-skip key's
composition, and its post-shutdown local BoltDB. Where they disagree, the clone
wins.

## Strengths

- **A small, legible lowering.** One statement, one op, and the `Converter`
  state is the whole IR; cache and parallelism come from BuildKit, so Earthly
  never re-implements a scheduler or a content store.
- **Content-addressed target keys.** `--auto-skip` hashes file _contents_ and
  refuses what it cannot resolve — the right conservative posture.
- **`--strict` is a real policy switch** ([`builder.go`][builder]), and the DSL
  distinguishes consuming (`COPY`/`FROM`) from realizing (`BUILD`).

## Weaknesses

- **No observation, so an unsound cache is undetectable.** Undeclared inputs,
  network reads and host state produce entries the engine cannot question.
- **Two disconnected cache tiers.** Auto-skip is opt-in, all-or-nothing, and
  post-shutdown needs a local database path; the layer cache cannot use it.
- **The target key is incomplete.** Name, size and bytes — no mode, ownership or
  mtime — so metadata-only changes can slip past a skip.
- **Conversion performs work.** `IF` solves a transient state to pick a branch,
  so building the graph can cost as much as building. The project is also
  unmaintained, with drifted docs and a mandatory BuildKit daemon.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                      | Trade-off                                                              |
| --------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `Earthfile` DSL lowered to BuildKit LLB       | Reuse a mature solver, cache and content store                 | No engine of its own; semantics must be expressible as ops             |
| `FROM +target` assigns the dependency's state | Inheritance is cheap; the chain is shared, not merged          | Downstream ops extend the same chain; a tail change invalidates it all |
| Declared dependencies only                    | Simple, portable, no tracing overhead                          | Undeclared inputs cache silently; `--strict` is policy, not proof      |
| Per-command layer keys from the op            | Fine-grained reuse and early cutoff, free from BuildKit        | Coarse changes re-run later commands until the cache catches           |
| Whole-target hash for `--auto-skip`           | Cheap "was this target affected?" for monorepos                | All-or-nothing, extra pass, rejects dynamic constructs                 |
| Auto-skip separate from the layer cache       | Skip avoids even the solve; fallback keeps normal builds green | Two mental models; the coarse tier cannot narrow the fine one          |
| Containers as the only isolation              | Strong isolation without an interposer or per-access cost      | No input observation; host access needs `LOCALLY`, which never caches  |

## Sources

- [`earthly/earthly`][repo] at commit
  `996e152f54aed191800168b4db20c47f923b716d` (clone at
  `$REPOS/build-systems-research/src/earthly`); every quote is verbatim from the
  file cited beside it, opened at that SHA.
- Lowering and repository state: [`README.md`][readme],
  [`CHANGELOG.md`][changelog], [`interpreter.go`][interpreter],
  [`converter.go`][converter], [`earthfile2llb.go`][e2l-entry],
  [`states.go`][states], [`visited-upfront-hash.go`][visited-upfront],
  [`pllb/state.go`][pllb], [`statetoref.go`][statetoref],
  [`global.go`][flags], [`builder.go`][builder], [`remote-runners.md`][remote-doc].
- Auto-skip: [`inputgraph/hash.go`][input-hash], [`loader.go`][input-loader],
  [`loader_hashing.go`][loader-hashing], [`hasher.go`][hasher],
  [`local.go`][skip-local], [`buildkitskipper_create.go`][skip-create],
  [`build_cmd.go`][build-cmd], [`detectgit.go`][gitutil],
  [`caching-in-earthfiles.md`][caching-doc], [`go.mod`][gomod].
- Sibling pages: [concepts] for scheduler × rebuilder vocabulary and Table 2,
  [BuildKit][buildkit] for the solver this frontend emits into,
  [the monorepo deep-dive][mono-earthly] for workspace and CLI treatment.

<!-- References -->

[repo]: https://github.com/earthly/earthly
[readme]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/README.md
[changelog]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/CHANGELOG.md
[gomod]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/go.mod
[interpreter]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/earthfile2llb/interpreter.go
[converter]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/earthfile2llb/converter.go
[e2l-entry]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/earthfile2llb/earthfile2llb.go
[states]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/states/states.go
[visited-upfront]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/states/visited-upfront-hash.go
[pllb]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/util/llbutil/pllb/state.go
[statetoref]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/util/llbutil/statetoref.go
[input-hash]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/inputgraph/hash.go
[input-loader]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/inputgraph/loader.go
[loader-hashing]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/inputgraph/loader_hashing.go
[hasher]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/util/buildkitskipper/hasher/hasher.go
[skip-local]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/util/buildkitskipper/local.go
[skip-create]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/cmd/earthly/bk/buildkitskipper_create.go
[build-cmd]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/cmd/earthly/subcmd/build_cmd.go
[flags]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/cmd/earthly/flag/global.go
[builder]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/builder/builder.go
[caching-doc]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/docs/caching/caching-in-earthfiles.md
[remote-doc]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/docs/remote-runners.md
[gitutil]: https://github.com/earthly/earthly/blob/996e152f54aed191800168b4db20c47f923b716d/util/gitutil/detectgit.go
[concepts]: ./concepts.md
[buildkit]: ./buildkit.md
[mono-earthly]: ../monorepo-tooling/earthly/
