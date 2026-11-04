# nixception (Rust + Nix)

A Remote Execution API server that turns each incoming build action into a Nix
derivation, builds it through `recursive-nix`, and lets the Nix store deduplicate
the result — a cache bridge between fine-grained action graphs and Nix's
package-level store.

**Last reviewed:** November 2, 2026

| Field          | Value                                                                                                                                                   |
| -------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language       | Rust 2024 (`Cargo.toml`), plus a single-file C++17 builder (`tools/runner/runner.cpp`, 683 lines)                                                       |
| License        | Apache-2.0 source; binary distributions GPL-3.0 because the vendored `nix-compat` (tvix) crate is statically linked — [`README.md`][readme] § Licensing |
| Repository     | [layus/nixception][repo] — a friendly fork of [NativeLink][nativelink]                                                                                  |
| Documentation  | `README.md`, `demo/README.md`, `CHANGELOG.md`; no manual                                                                                                |
| Category       | Nix ecosystem — remote-execution front end, store bridge                                                                                                |
| Clone (pinned) | `$REPOS/build-systems-research/src/nixception` at `0d3fa7bb7140bd97c1a0e08ea5697e34a555747b` (2026-09-27)                                               |
| Version        | `0.6.1` (`Cargo.toml`); `CHANGELOG.md` records `0.6.1` on 2026-09-13                                                                                    |
| Size           | ~65k lines of Rust; the Nix-specific core is `nix_worker.rs` (1,414), `nix_scheduler.rs` (438), `nix_store.rs` (338)                                    |
| Status         | "experimental" — interfaces "are still moving" ([`README.md`][readme]); needs a daemon with `recursive-nix`                                             |

## Overview

### What it solves

> "**nixception** turns ordinary build-tool actions into **Nix builds**, using the
> Nix store as a content-addressed cache. It's a server that speaks the
> [Remote Execution API](https://github.com/bazelbuild/remote-apis) (REAPI) and
> translates each remote action it receives — a single `gcc` invocation sent by
> `recc`, a Bazel rule — into a Nix derivation, and builds it through the
> **recursive-nix** daemon."
>
> — [`README.md`][readme]

Two gaps meet here. A Nix build is coarse-grained — one derivation per package,
with the package's build system invisible to Nix — while Bazel and `recc` produce
fine-grained actions and want a shared cache keyed per action. nixception makes
each action a derivation, so the Nix store becomes the action cache and Nix's
closure, sandbox and GC apply unchanged. The second problem is the name: a Nix
build that dispatches compiles needs a build engine _inside_ a build, so the
setup hook starts the server before `configurePhase` and stops it at exit.

### Design philosophy

> "Because every action is realised as a derivation _from inside a Nix build_,
> the server relies on **recursive-nix**: the ability of a build to talk back to
> the Nix daemon (via `/build/.nix-socket`) and realise further derivations."
>
> — [`README.md`][readme]

nixception deliberately implements almost no build engine: no action graph, no
dirty-bit store, no worker fleet. One REAPI action becomes one derivation, and
the Nix daemon schedules and sandboxes it. The runner is tool-less: everything an
action executes must arrive as a `/nix/store` reference or through
`NIXCEPTION_EXTRA_SANDBOX_PATHS` ([`README.md`][readme]). It is not
import-from-derivation: the nested build happens during a build, through a
daemon socket, not during evaluation.

## How it works

### Topology: five REAPI services over one store

`src/bin/nixception.rs` assembles the server with NativeLink's `topology!` macro
and binds `0.0.0.0:50051`. The stores are `Noop`, `Nix` and an `ExistenceCache`
over the Nix store; the scheduler and core services are:

```rust
schedulers { nix_scheduler = NixProxy { ac_store: void, cas_store: nix_store } }
services {
    cas:       Cas { cas_store: existence_cache },
    ac:        Ac  { ac_store: void, read_only: false },
    execution: Execution { cas_store: nix_store, scheduler: nix_scheduler },
}
```

The action-cache service is backed by `Noop`: nixception never answers
`GetActionResult` from a cache of its own. Reuse comes entirely from the Nix
store — an identical derivation whose output path is already valid is realised
as a fast `AlreadyValid` build.

### Lowering one action to one derivation

`NixWorker::prepare_derivation` ([`nix_worker.rs`][nix-worker]) is the whole
translation:

1. Fetch the REAPI `Command` and unfold the input `Directory` tree from the CAS
   into `PathEntry` records (`path`, store path, digest, executable).
2. Discover `/nix/store/…` references (below) and add them to `input_sources`.
3. Serialise a manifest — inputs, working directory, declared outputs, env,
   argv — into the derivation environment via Nix's `passAsFile`.
4. Make the prebuilt runner the only `input_derivation`, compute
   `hash_derivation_modulo` → `calculate_output_paths("reapi-action")`, upload
   the `.drv` with `AddToStore`, then call `BuildPathsWithResults` on `<drv>!*`.

The result is one derivation with one output (`out`) holding `exitcode`,
`stdout`, `stderr`, the declared outputs under `outputs/`, and a `timing.json`.
Outputs are input-addressed: the key is the derivation hash over the manifest,
the runner `.drv` and the input store paths. The input _files_ are
content-addressed — `NixStore::key_to_store_path` calls
`build_ca_path("reapi-adapted", CAHash::Flat(Sha256(digest)))` — so identical
bytes land at the same store path, and two actions over the same inputs hash to
the same derivation.

### The runner

> "It replaces the previous bash wrapper script for efficiency: instead of
> generating a shell script that spawns mkdir/cp/tree for every input file, this
> program performs the same operations directly via system calls and
> std::filesystem."
>
> — [`tools/runner/runner.cpp`][runner]

The runner reads `$manifestPath`, copies every input from the store into the
build directory (adding the owner-write and executable bits), creates the
declared output parents and `$out/outputs/`, then `fork`s and `execvpe`s the
command with **exactly** the REAPI environment — no inheritance from the builder.
It records the exit code and copies back whatever the command wrote. Missing
declared outputs are skipped, because failing there "would hide" the real exit
code.

### Dependency discovery is a byte scan

An action can carry `/nix/store` references it never declares: a `rules_nixpkgs`
toolchain, a wrapper script, a `pkg-config` file. nixception scans argv,
environment values and the _contents_ of every input file for the literal prefix
`/nix/store/`, caches hits per store path in `ScanCache`, and adds every hit as an
input source. There is no tracing, no depfile parsing and no strict-deps check.

Version 0.6.0 removed the attempt to resolve a discovered path to its deriver,
because the answer depended on which daemon was asked:

> "Every discovered path is now added directly as an input source,
> unconditionally. … but it is deterministic: the same scan of the same
> command/environment always classifies every path the same way, from any
> calling context, with no daemon round-trip (and its host-dependent answer)
> involved at all."
>
> — [`nix_worker.rs`][nix-worker]

Inside a `recursive-nix` sandbox the daemon is Nix's `RestrictedStore`, which
"unconditionally strips the `deriver` field from every `queryPathInfo` reply as
'impure information'". A caller outside the sandbox (`nix develop`) sees real
derivers, so the same action acquired a different derivation shape — and hash —
depending on where it ran. The fix trades precision for stable identity: a path
is a path, never "this build of gcc". `NIXCEPTION_EXTRA_SANDBOX_PATHS` is the
escape hatch, and because those paths join `input_sources` they change the key.

### Scheduling, retries and the daemon pool

`NixScheduler` is a state manager, not a planner. `add_action` registers the
operation and spawns a `tokio` task per action; each worker drives itself through
`Queued → Executing → Completed`. `add_worker` returns `Unimplemented`, so the
execution service is single-node and the real parallelism is the Nix daemon's.
All daemon I/O goes through `NixDaemonConnectionPool`: up to ten lazily opened
async `UnixStream`s, semaphore-bounded, cached for 30 s and reaped every 5 s.
Builds retry up to three times with exponential backoff (2 s, 4 s, 8 s), and
`classify_build_status` treats Nix's `PermanentFailure` as retryable when the
message looks like an OOM or signal kill.

### Maturity signals

`README.md` calls the project experimental and says server topology, the setup
hook contract and the derivation encoding are still moving. `Cargo.toml` is at
`0.6.1`; [`CHANGELOG.md`][changelog] records real fixes (every action once
reported cached because the runner had stopped writing `timing.json`; a
`NIXCEPTION_LOG` precedence bug; the deriver change above). The clone is shallow
— one commit, no tags — so activity shows through the changelog, the demo (a
self-contained flake of `reccStdenv`, Bazel and vanilla builds plus hyperfine
benchmarks) and the tests, not through history.

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix occupies suspending × deep constructive in [concepts][]'s Table 2. nixception
does not add a cell: it is a **key translator**, not a scheduler. One action
arrives with its inputs declared, becomes one leaf derivation, and is handed to a
suspending scheduler whose graph is the store closure. At the action layer the
rebuild check is "is this derivation's output path valid?" — deep constructive
over terminal input hashes, with no early cutoff: output _content_ is never
consulted. The graph above is the client's (Bazel: restarting × constructive),
and nixception preserves one action's identity, not either graph.

### 1. Task model & scheduling

One REAPI action, one derivation. There is no intra-server graph, topological
order or speculation; a `tokio` task per action is spawned immediately, bounded
by the daemon pool. Retries live at the build level (`max_job_retries` is 0).

### 2. Rebuilding & correctness

The dirty check is Nix's: the output path is valid or it is built — minimal per
action, and correct only if the derivation captures every input. Determinism is
assumed, not verified: a nondeterministic command reuses the first result, and
there is no `--check` or output-hash comparison. Identity is the weak point —
`PATH` sentinels and nixpkgs' `-frandom-seed` leak into the environment and
fragment the cache. The 0.6.0 change chose a stable, less precise key over a
context-dependent, more precise one, the right direction for a shared cache.

### 3. Dependency discovery

Hybrid and skewed to declaration: the client declares the input tree, and
nixception adds a textual scan for store references in argv, env and input-file
bytes. The scan fails safe when a path is missed — the sandbox refuses it and the
build fails — but a path assembled at runtime is invisible until then. There is
no tracing and no strict-deps enforcement; over-declaration only costs misses.

### 4. Store & caching

The Nix store is both CAS and action cache: input blobs are CA paths
(`reapi-adapted`), derivations and outputs are input-addressed, and GC/eviction
are Nix's. `NixStore::update` verifies the daemon's returned content address
against the key, with a fallback that tolerates an upload error when the path
already exists. Because the AC service is `Noop`, a client cannot read an
`ActionResult` back; reuse re-realises an already-valid derivation — cheap, but
not the REAPI action-cache contract.

### 5. Hermeticity & provenance

Each action is a normal Nix derivation, so it gets whatever sandbox the daemon is
configured with; nixception adds none. The outer build must carry
`requiredSystemFeatures = [ "recursive-nix" ]`, and the setup hook fails fast if
`/build/.nix-socket` is absent. The runner passes exactly the REAPI environment
to `execvpe` and copies inputs into a writable directory. There is no provenance
or attestation (no SLSA, in-toto or DSSE); the `.drv` is the only record.

### 6. Distribution

Remote from the client's side, local from the server's: gRPC in, one Nix daemon
out. No worker registration, no scheduler sharding, and no remote store backend
in the default build (S3/GCS/Redis/Mongo are opt-in features). Scaling means a
bigger machine or more daemons, not a fleet.

### 7. Sparkles relevance

`sparkles:build-primitives` already models work as a `TaskNode`/`TaskEdge` DAG
with resource claims and typed outcomes. nixception contributes three mechanics
and one warning:

- **A canonical serialised action as the cache key.** The manifest (argv, env,
  working directory, declared outputs, input store paths) _is_ the identity;
  Sparkles could hash one canonical action record instead of paths and mtimes.
- **Prefer stable keys over precise provenance.** The 0.6.0 deriver fix is the
  cleanest example of a cache key that was more accurate and less useful.
- **Per-cost-center accounting.** `nix_stats.rs` splits scanning, preparation,
  upload, execution and collection. Its 300 ms sandbox floor is a heuristic, not
  a measurement — copy the structure, not the constant.
- **Do not copy the byte scan.** Textual `/nix/store` discovery is Nix-specific;
  a general task DAG should declare inputs or trace them, not grep.

## Strengths and weaknesses

- **Action-level granularity on a package-level store.** Each compile gets its
  own derivation and store path, so a shared store deduplicates work across
  projects, not just across builds of one package.
- **Identity is a first-class problem.** The demo diffs the action manifest
  across `nix build` and `nix develop`, and a changelog entry reverts a precision
  feature to keep identity stable.
- **No action-cache service, and single node.** `Ac { ac_store: void }` gives
  clients no `ActionResult` reuse; `add_worker` is unimplemented, so the façade
  does not distribute execution and the default build strips the remote stores.
- **Heuristic discovery, young code.** A computed store path is invisible, the
  workaround is a server-wide environment variable, and the project is
  experimental, shallow-cloned, with regression fixes at the head of its
  changelog.

## Key design decisions and trade-offs

| Decision                                     | Rationale                                                           | Trade-off                                                                      |
| -------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| REAPI façade over Nix, not a new scheduler   | Reuses the store, sandbox, GC, substituters and closure computation | No remote action cache; client-visible semantics are only as rich as the store |
| One derivation per action, runner as builder | Fine granularity without teaching Nix a command language            | One store path per action; every action pays a Nix build invocation            |
| Discovered paths are always `input_sources`  | Identity stable across sandbox boundaries and daemons               | Less precise: content-equal but differently built toolchains alias             |
| Byte scan for `/nix/store` references        | Works with arbitrary tools and no tracer                            | Computed paths are missed; `NIXCEPTION_EXTRA_SANDBOX_PATHS` is a blunt fix     |

## Sources

- [`layus/nixception`][repo] at `0d3fa7bb7140bd97c1a0e08ea5697e34a555747b`,
  clone at `$REPOS/build-systems-research/src/nixception` (shallow, one commit,
  no tags). Opened: `README.md`, `CHANGELOG.md`, `Cargo.toml`, `demo/README.md`,
  `src/bin/nixception.rs`, `nix_worker.rs`, `nix_scheduler.rs`, `nix_store.rs`,
  `nix_daemon_connection.rs`, `nix_stats.rs`, `runner.cpp`, both `tools/` hooks.
- Background: [nix-thesis], [concepts], [bazel], [content-addressing] and its
  [REAPI page][ca-reapi], [nix-flakes].

<!-- References -->

[repo]: https://github.com/layus/nixception
[readme]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/README.md
[changelog]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/CHANGELOG.md
[nix-worker]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/nativelink-scheduler/src/nix_worker.rs
[runner]: https://github.com/layus/nixception/blob/0d3fa7bb7140bd97c1a0e08ea5697e34a555747b/tools/runner/runner.cpp
[nativelink]: https://github.com/TraceMachina/nativelink
[concepts]: ./concepts.md
[nix-thesis]: ./nix-thesis.md
[bazel]: ./bazel.md
[content-addressing]: ../content-addressing/index.md
[ca-reapi]: ../content-addressing/reapi.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/
