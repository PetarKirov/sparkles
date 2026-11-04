# nix-cargo-unit (Rust + Nix)

Reads Cargo's own compile plan and renders one Nix derivation per compilation unit — a translator from Cargo's scheduling world into Nix's, at unit granularity rather than workspace granularity.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                                       |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Rust 2024 (`edition = "2024"`, [`Cargo.toml`][cargo-toml]) plus the generated-Nix template; ~8.3k lines of Rust, ~2.2k of hand-written Nix                                  |
| License               | MIT (`license = "MIT"`, [`Cargo.toml`][cargo-toml])                                                                                                                         |
| Repository            | [wyattgill9/nix-cargo-unit][repo] — docs are the in-tree [`README.md`][readme] (a 20-section internals manual) and two `research/*.md` comparison docs                      |
| Category              | Nix ecosystem — Cargo-plan lowering; engine [nix-thesis], store [content-addressing], sibling lowering [nix-ninja], alternative produced executor [nixception]              |
| Clone (pinned)        | `$REPOS/build-systems-research/src/nix-cargo-unit` at `355648f33b07209a5566a3a592e2edbe49303c1e`; shallow clone, **one commit**, no tags reachable (author date 2026-08-05) |
| Version in tree       | `0.1.0`, `publish = false` ([`Cargo.toml`][cargo-toml]); no release artifact in the tree                                                                                    |
| Size                  | 92 tracked files; `src/render.rs` 6406 lines (README: "~3700 lines of logic + ~2700 of tests"), `templates/units.nix.in` 873, `src/model.rs` 943                            |
| Scheduler × rebuilder | Suspending × deep constructive (Nix's cell), at **compilation-unit** granularity — see _Placement_ below                                                                    |

## Overview

### What it solves

Nix's unit of work is the derivation; Cargo's is the `cargo build` invocation. The conventional bridge collapses the whole workspace, or a whole dependency tier, into one derivation and lets Cargo schedule inside it — which is precisely why a one-line edit can invalidate the world.

> "Most Rust-on-Nix tooling bridges these by making the whole workspace (or a whole dependency tier) a single derivation and letting Cargo do the scheduling inside it. This project takes the other route: it replays Cargo's dependency resolution _outside_ the build, then emits one `stdenv.mkDerivation` per unit that calls `rustc` directly. Nix becomes the build scheduler; Cargo is only consulted for planning."
>
> — [`README.md`][readme] § preamble

The unit is Cargo's, not the crate's: a library, its `build.rs` compile, that build script's run, each test target, each proc-macro and each binary are separate derivations, and a crate needed at two feature sets is two units.

> "The consequence is granularity. Editing one crate rebuilds that crate's units and their dependents — not the workspace. It also means this tool has to reimplement, faithfully, every piece of environment Cargo normally supplies to `rustc` and to `build.rs`. Most of the code is exactly that reimplementation."
>
> — [`README.md`][readme] § preamble

That second sentence is the honest summary of the tree: the interesting engineering is not the graph translation but the Cargo-compatibility bodies the translation obliges.

### Design philosophy

The governing bet is **fidelity over interface stability**: take the plan from the tool that owns the semantics, even though the interface is unstable, rather than re-deriving features and `cfg()` from `Cargo.lock` in Nix.

> "**crate2nix buys stability of _interface_ at the cost of fidelity of _result_. nix-cargo-unit buys fidelity at the cost of interface stability.**"
>
> — [`research/comparison.md`][comparison] § 3

Three commitments follow, and every section below is one of them. **Replay, do not reimplement, planning** — `cargo build --unit-graph -Z unstable-options` resolves features, profiles, `cfg()`, platform and edges, and the renderer transcribes them into hashes and `rustc` argv without re-resolving anything. **One derivation per unit, build script split out** — Cargo's `custom-build` and `run-custom-build` modes become two derivations, so an expensive `build.rs` is cacheable independently of the crate it configures. **Emulate exactly what Cargo would have exported** — `CARGO_CFG_*`, `CARGO_MANIFEST_LINKS`, a writable `CARGO_MANIFEST_DIR`, an `OUT_DIR` nested two levels deep, and `DEP_<LINKS>_*` all exist because a specific crate panics or miscompiles without them.

## How it works

### Pipeline

```text
Cargo.lock ──> vendorDir  (one derivation per crate tarball)
src ──> plannerSource ──┐
                        ├─> cargo build --unit-graph  ──> unitGraphJson
                        │        (per cargoTargets entry, merged)
                        └──────────────────────────────> nix-cargo-unit render
                                                                  │
                                                            units.nix
                                                                  │ IFD: import
                                              one derivation per compile unit
```

Four subcommands ([`src/main.rs`][main-rs]): `render`, `merge`, `scan-panics`, `nextest-metadata`. `render` is pure over `(unit-graph JSON, Cargo.lock, filesystem layout)` — it reads manifests and source trees for scoping, and performs no build and no network resolution. `merge` folds several unit graphs into one, deduplicating by identity hash and recording each input's roots as a `root_sets` entry that the rendered file exposes as `targetSets`.

### Planning in a content-stubbed tree

The most instructive detail is not the graph but the _input_ to the graph. `plannerSource` copies manifests verbatim and replaces every other file with an empty stub at its exact relative path:

> "Cargo's planning phase (`cargo build --unit-graph`) resolves the workspace from manifest CONTENTS (Cargo.toml, Cargo.lock, the in-tree cargo config) plus target discovery by file EXISTENCE (src/lib.rs, src/main.rs, src/bin/*.rs, tests/, benches/, build.rs); it never reads a target file's contents and runs no build script or proc macro."
>
> — [`nix/graph.nix`][graph-nix] `plannerSource`

So the plan has two input tiers: a manifest slice that changes rarely, and a path list that changes only when files appear or disappear. A body edit leaves both byte-identical and the whole-workspace resolve never re-runs ([`bench/nix-cargo-unit/README.md`][bench-readme]). Measured staging ([`BENCH_BASE.md`][bench-base] § 4): `plannerSource` 8.9 s, the cargo plan 0.50 s, the render 0.76 s — about 1 s on the common body-only edit, against a ~211 s cold build.

### Unit identity

`Unit::identity_hash` ([`src/model.rs`][model-rs]) feeds a canonical byte stream into SHA-256 and keeps 8 bytes as 16 hex characters ([`src/hash.rs`][hash-rs]). The string becomes three things at once: the Nix attribute name, `rustc -C metadata=<hash>`, and `-C extra-filename=-<hash>` so artifacts of same-named crates coexist in one `-L` directory.

The hash covers package identity, target name and edition, **sorted** crate types and features, the full profile, lint rustflags, check-cfg args, mode, platform, `is_std`, the target's test/doctest/doc booleans, then **sorted** dependency edges encoded as `extern_crate_name:public:noprelude:<dep hash>`, then an optional `--toolchain-id` salt. Two choices stand out. Edge attributes, not just dependency hashes, keep a unit that renames a dependency via `extern_crate_name` distinct — `merge` has a regression test for the collision this prevents. And `path+` ids collapse to `path#<name>@<version>`, dropping the absolute directory, so two checkouts of one workspace at different store paths hash identically (pinned by `path_package_identity_ignores_absolute_source_roots`). Because the toolchain id is the basename of the toolchain store path ([`nix/default.nix`][default-nix]), a compiler move invalidates the graph instead of silently reusing incompatible rlibs.

### Source scoping, and the two promotions

Each unit gets a `SourceEntry` for the narrowest store path that can hold its inputs ([`src/render.rs`][render-rs]): `Workspace` (a package directory), `WorkspaceClosure` (workspace root filtered to listed subtrees), `VendorPackage`, `VendorClosure`. Two triggers promote a package to a closure. Symlinks pointing outside the package but inside the workspace/vendor boundary are added as roots and walked; a symlink _escaping_ the boundary is a hard error, because Nix could not reproduce it. And `.rs` files are scanned textually for `include!`, `include_bytes!`, `include_str!`, with plain and raw literals resolved relative to the file and `concat!("dir/", …)` contributing its leading literal. The scan does not parse Rust, so it can match inside a comment — harmless, since a missing directory just drops out at the Nix filter. Computed arguments such as `env!("OUT_DIR")` are skipped on purpose: they resolve to build-script output, not source.

### Remapping, and why a path is a cache key

Every unit emits `--remap-path-prefix` for its own source and for `ruststd`, unconditionally:

> "Derived from the package name and version rather than the source store name so it stays readable in a backtrace and, more importantly, so it is a pure function of the graph: relocating a source (a rename, a filter change, a different but identical checkout) no longer perturbs the bytes of the rlib that quotes it, which is exactly the early cutoff content addressing is for."
>
> — [`src/render.rs`][render-rs] `source_remap_prefix`

Without it, every `panic!`, `unwrap`, `assert` and `#[track_caller]` site bakes a `/nix/store/…` path into the artifact as string data that no `strip` removes, and Nix's reference scanner pins the whole source derivation — and, via one monomorphized std generic, the ~1.9 GiB toolchain — into the binary's runtime closure. Measured result: rust-analyzer's binary closure is 91.6 MiB over two store paths ([`BENCH_BASE.md`][bench-base] § 10).

### Build scripts as a separate, emulated world

`prepare_graph` pairs each `custom-build` unit with its `run-custom-build` and records the run's other run-dependencies, which is how `DEP_*` metadata propagates between scripts. The run derivation reconstructs what Cargo would have provided: a **writable copy** of the package source as `CARGO_MANIFEST_DIR` (scripts mutate it), `OUT_DIR` at `$(mktemp -d)/build/out` — nested two levels because `rusty_v8` locks at `OUT_DIR/../../v8.fslock` — `CARGO_CFG_*` synthesized by running `rustc --print cfg --target "$TARGET"` and comma-joining repeated keys, `CARGO_MANIFEST_LINKS` because `ring` panics without it, and a `CARGO_HOME` shim for build scripts that shell out to `cargo metadata` (`cbindgen` is the curated example). Directives are then demultiplexed: `cargo:` lines become `rustc-cfg`/`rustc-link-*`/`rustc-env` files, `warning=` goes to stderr, and `rerun-if-changed`/`rerun-if-env-changed` are **dropped**, because Nix owns invalidation.

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix occupies the suspending × deep constructive cell ([concepts][] § 5). nix-cargo-unit adds no cell: it is a **generator**, with no scheduler of its own, and everything it emits runs on Nix's engine. After planning the graph is static (`Applicative` in the paper's sense); the `Monad`-shaped part — feature resolution, target discovery — already happened inside Cargo before the renderer saw anything.

One contrast with [nix-ninja][] is worth recording. nix-ninja must generate derivations in explicit topological order, because a consumer's `.drv` embeds its producer's `.drv` path. Here the output is a Nix `rec` attrset ([`templates/units.nix.in`][template]): a dependent's `units.<key>` reference is a lazy binding, so instantiation order falls out of evaluation and no topological sort exists in the renderer at all. The ordering constraint moved from the generator into the language.

### 1. Task model & scheduling

The task description is Cargo's compile plan, one invocation per `cargoTargets` entry (for example `[["--workspace"] ["--workspace" "--tests"]]`), run concurrently and merged. Renderer output is a _function_ over `pkgs`, `rustToolchain`, `src`, `workspaceRoot` and a large seam of optional overrides — nothing about nixpkgs, `rustPlatform` or a flake layout is baked in.

Roots are lazy: selecting `binaries.rust-analyzer` builds one derivation and its dependencies, never the other 45 roots. Two exceptions are shared-IFD discovery: `tests.<target>.cases` and `doctests.<target>.cases` force one manifest derivation for the whole graph.

Scheduling is Nix's, and its shape dominates the measurements: a 21-unit critical path is 115.6 s, **55 % of wall clock**, against a theoretical 3.25× speedup and a measured 1.51× on ten cores ([`BENCH_BASE.md`][bench-base] § 5) — and four `(max-jobs, cores)` combinations all land within 3 %, so scheduler tuning is not the lever (§ 9). The cause is structural: a Nix derivation is atomic, so a dependent cannot start on `--emit=metadata` the way Cargo unblocks one. The repo names splitting each unit into metadata and codegen derivations as the fix and leaves it unmeasured.

### 2. Rebuilding & correctness

The dirty check is Nix's: a derivation whose output is realised is skipped, and identity is the derivation hash over the unit hash, the scoped source and the toolchain. This is a **deep constructive** key — terminal inputs only — so early cutoff does not exist by default, and a rebuilt intermediate is always re-derived.

Content addressing is the escape hatch, and the code is candid about its ceiling:

> "Why content-address: it buys "early cutoff" — when a crate is rebuilt but its output is byte-identical, Nix reuses the existing path and dependents are not re-derived. How often that fires is bounded by rustc itself: a crate's rmeta is oversensitive (a comment / private-body / formatting change still changes it, forcing reverse-dependency rebuilds), and link targets (bins/cdylibs) always relink when any transitive rlib changed because rlibs aren't byte-stable under `-C incremental`."
>
> — [`src/render.rs`][render-rs] `append_content_addressing`

Note the default drift: the _CLI_ flag is opt-in, but `buildWorkspace` defaults `contentAddressed ? true` ([`nix/workspace.nix`][workspace-nix]) and the benchmarks set it false. README § 9's "opt-in" describes the renderer, not the library.

Addressing is deliberately non-uniform. Libraries and binaries may be CA; tests and benchmarks are always input-addressed, because they are leaves that buy no early cutoff and only inherit floating-realisation fragility (a stale or GC'd realisation resurfaces as a silent "N dependencies failed", `NixOS/nix#15649`); build-script runs are always input-addressed:

> "A build script may persist _arbitrary_ files in OUT_DIR — compiled `.o`/`.a`, but also generated Rust sources, C headers, bindings, and codegen metadata — and we cannot prove all of it is byte-reproducible."
>
> — [`src/render.rs`][render-rs] `render_build_script_run_derivation`

That is the most transferable correctness argument in the repo: CA is a claim about determinism, so it belongs only where determinism is believable.

**Granularity vs crane-style.** The repo makes exactly two claims about the crane/naersk two-derivation model (`deps` blob + crate), both in its own comparison docs and neither measured here: that per-crate granularity is what distinguishes crate2nix-class tools from that model ([`research/crate2nix.md`][crate2nix-doc] § 2), and that the model

> "sidesteps the per-derivation tax that both of these tools pay."
>
> — [`research/comparison.md`][comparison] § 10

The supporting measurement is indirect but strong: ~175 ms of Nix scaffolding per derivation, ~56 s over 320 units, ~27 % of a cold build, with a 0.73 s median unit — so "the median unit spends more time in Nix scaffolding than in compilation" ([`BENCH_BASE.md`][bench-base] § 8). Granularity also bounds _what_ rebuilds without shortening the chain: a `stdx` edit (deepest crate, 30 reverse-deps) rebuilds 31 of 320 units, 9.7 %, and still costs 127 s — 60 % of a cold build — because those units _are_ the critical path. Against plain `cargo --offline` the tool is 2.62× slower cold and 0.69× on a no-op (§ 7), and against Buck2 + reindeer it wins the cold build but loses every incremental case ([`bench/comparison.md`][bench-comparison]). "Fewer rebuilds" and "faster rebuild" are different measurements.

### 3. Dependency discovery

There is no discovery in the traced sense: the dependency list _is_ the unit graph, with features, `cfg()`, platform and profile already resolved by the planner. No depfiles, no `#include` scanning, no syscall interception, no strict-deps enforcement — the entire crate2nix drift class is structurally absent rather than patched ([`research/comparison.md`][comparison] § 3). The one scanner in the tree (`extract_include_macro_paths`) feeds _source scoping_, not edges, and the one place the tool executes to learn something is the build-script run, whose stdout directives are parsed into per-unit files.

Units then talk to each other through a small on-disk contract: `$out/nix-support/extern-path` holds the absolute artifact path, written by probing a fixed candidate list and read with `$(cat …)`, so platform extension logic exists in exactly one place.

### 4. Store & caching

The Nix store is the cache: no action cache, no metadata table, no eviction policy of its own. Two store-layout decisions matter. Every external crate is its **own** derivation — a `fetchurl` of the `.crate` tarball, unpacked, with a `.cargo-checksum.json` ([`nix/vendor.nix`][vendor-nix]) — so a unit depends on its own tarball rather than the aggregate vendor tree; `vendorDir` is only a `linkFarm` for the two consumers that need a directory. And because those vendor nodes are forced during evaluation (IFD), they flip `allowSubstitutes` back on: without it, an evaluating machine must build them even when a binary cache has them.

The test surface is where cache policy becomes explicit: one IFD lists every test target rather than one per binary, and each per-test leaf sets `allowSubstitutes = false; preferLocalBuild = true`, because substituting an empty marker directory costs a narinfo round-trip per leaf against every configured substituter.

### 5. Hermeticity & provenance

Each unit is a normal derivation, so it inherits the daemon's sandbox and nothing more. The declared environment is narrow (toolchain, encoded input lists, per-package env), external crates compile under `--cap-lints warn` so upstream churn cannot break a workspace lint gate, and `pureBuild` disables the four quality gates (clippy, audit, machete, unused-deps) for graphs whose native counterpart already ran them ([`nix/policy.nix`][policy-nix]).

The holes are documented rather than hidden, and they are of three kinds. **Curated allowlists** — `CARGO_INVOKING_BUILD_DEPS` is `["cbindgen"]`; a build script that shells out to `cargo metadata` without that marker dies on DNS inside the sandbox, and the fix is a source edit; `PANIC_SINKS` in the panic-freedom scan is likewise explicitly incomplete. **Over-approximating scans** — the textual `include!` scan widens keys, which costs misses but not correctness. **Deliberate non-fidelity** — `.cargo/config.toml` rustflags are ignored unless `cargoConfigRustflags` is set, `[env]` and `cfg(...)` sections are not honoured, and `rerun-if-changed` is dropped.

Provenance is the `.drv` and nothing else: no SLSA level, no in-toto link metadata, no DSSE. The build-id note policy (`sha1` over the linked output, on by default for ELF) is about symbolization, not attestation. One caveat governs every number here: the benchmarks run with `sandbox = false` on `aarch64-darwin`, so the measured per-derivation overhead is a floor, not a ceiling.

### 6. Distribution

None of its own. Remote execution would be Nix's (`--builders` or an REAPI gateway) and the tool assumes one local daemon; what it buys is _scheduling_ granularity, so independent units become independently substitutable. Its one distribution-shaped cost is IFD: the unit graph cannot exist before a derivation runs, so evaluation blocks on it, and nixpkgs will not accept an IFD package.

**Dynamic derivations: absent, deliberately.** The repo contains no reference to RFC 92, to `dyndep`, to `.drv.drv`, or to `builtins.outputOf` — the only output addressing it uses is content addressing. Its answer to "the graph is discovered by running a tool" is the pre-RFC-92 one: build the graph at _evaluation_ time. A dynamic-derivation encoding would instead make cargo's planning a derivation whose output is `units.nix`, letting Nix schedule planning and building in one graph and removing the IFD. That is the move [nix-ninja][] makes for header discovery, one level down; this repo's IFD is the same problem at graph scale.

### 7. Sparkles relevance

`sparkles:build-primitives` models work as `TaskNode`/`TaskEdge` with semantic `TaskId`s, `EdgeCondition`/`EdgeReason`, `ResourceClaim`s and typed outcomes (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`), and the spec is explicit that

> "Distributed admission across several executor fibers, persistent scheduler state and a workflow file format are out of scope."
>
> — `docs/specs/build-primitives/task-dag/SPEC.md` § preamble

So the delta is not granularity — the task DAG is already finer than a Cargo unit — it is _keying_. Sparkles has no store and no rebuild test: every admitted task runs, and `TaskId` is semantic but not a function of its inputs. nix-cargo-unit contributes four mechanics. **Ask the planner, do not re-derive the plan** — the unit graph exists because Cargo already knows features, `cfg()` and target discovery; Sparkles' analogue is `dub.sdl`/package discovery, and the day it grows a cache the key should come from the planner's own resolution, not a parallel reimplementation. **A key is a function of inputs and of nothing else about location** — collapsing `path+` ids and deriving remap prefixes from package identity are the same idea twice: the store path must not leak into identity, or nothing caches across checkouts. **Two-tier planning inputs** — the manifest-slice-versus-body-stub split is directly transplantable to `ci`'s planning phase. **Be selective about what you claim is deterministic** — CA for rlibs, input addressing for build-script runs and test leaves, is a policy a future Sparkles store should copy; `SandboxPolicy.taskDirectory` today is isolation-by-directory, not a determinism claim.

What Sparkles keeps that Nix cannot express: edges carry `EdgeReason`, and outcomes carry `SkipReason`/`CancelReason`. A derivation graph records _that_ a dependency exists, never why.

## Strengths

- **Fidelity by construction.** Features, `cfg()`, platform, profile and edges arrive pre-resolved; the crate2nix drift class is absent, not worked around.
- **Per-unit granularity with real numbers behind it** — 320 units for rust-analyzer, a 31-unit rebuild on a `stdx` edit, and a published breakdown of where the time goes rather than a claim that granularity pays.
- **Closure hygiene that configuration cannot buy.** The dual `--remap-path-prefix` is the difference between a 91.6 MiB binary closure and one that drags its toolchain along.
- **Honest, load-bearing comments.** CA's limits, the `OUT_DIR` nesting, the `CARGO_CFG_*` comma-join, the darwin orphan-output precheck — each names the crate or issue that forced it.
- **A real policy surface** (per-package clippy, unused-crate-deps, panic freedom, coverage, per-`#[test]` leaves) rather than a builder wrapper.

## Weaknesses

- **Nightly-shaped interface, stable-shaped toolchain.** `--unit-graph` is `-Z unstable-options`; the planner sets `RUSTC_BOOTSTRAP=1`, and `model.rs` carries lenient `Lto`/`DebugInfo`/`Strip` deserializers plus `UnitMode::Other(String)` because Cargo has spelled the same fields several ways. The repo's own docs disagree on the consequence: `research/comparison.md` § 9's maturity table says "nightly required", while § 3 and `nix/default.nix` argue a stable toolchain is enough _because_ the planner bootstraps.
- **IFD by construction** — evaluation blocks on planning, `overrideAttrs` cannot propagate through it, and nixpkgs will not take it.
- **Slow where it matters.** 2.62× slower than plain cargo cold, 1.65–1.96× slower on every incremental case measured, and it loses every incremental case to Buck2.
- **No eval-level tests.** 55 tests, all textual assertions on emitted Nix, and the repo documents a live bug only an eval test would catch: `checkedRoots` joins entries with a space, so `[ withPolicyChecks units."…" ]` is a two-element list instead of an application (`render.rs:3131`; `render_panic_freedom_check` gets the same construct right).
- **Bus factor one** — a single-author repo whose `Cargo.toml` sets `publish = false`, plus a hand-maintained allowlist in the hermeticity path.

## Key design decisions and trade-offs

| Decision                                      | Rationale                                                     | Trade-off                                                           |
| --------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------- |
| Cargo unit graph as the input IR              | Planning semantics stay Cargo's; drift class disappears       | Unstable `-Z` interface; lenient deserialization forever            |
| One derivation per unit (not per crate)       | Build scripts and test targets cache independently            | Per-derivation tax ~27 % of cold build; 320 derivations to schedule |
| Derivation per `#[test]` case                 | A failing test does not rebuild its binary's other cases      | Thousands of leaves; needs `allowSubstitutes = false` to stay sane  |
| Plan in a content-stubbed `plannerSource`     | Body edits skip the whole-workspace resolve                   | Another derivation to explain; symlinked manifests mis-plan         |
| `--remap-path-prefix` on every driver         | Keeps store hashes out of artifacts and closures              | Backtraces show `/build/<crate>-<ver>`; coverage must un-remap      |
| CA only for libs/bins, never build scripts    | CA is a determinism claim; `OUT_DIR` content cannot be proven | Early cutoff forfeited exactly where scripts are expensive          |
| Reimplement Cargo's build-script environment  | Fidelity for `ring`, `rusty_v8`, `libm`, `cbindgen`           | ~3700 lines of emulation, each tied to one crate's assumptions      |
| Curated allowlists for cargo-invoking scripts | Avoid wiring a vendored registry into every run               | A new crate that shells out to cargo fails on DNS until patched     |
| IFD instead of a committed `units.nix`        | No 2.6 MB generated file to regenerate and review             | Evaluation serializes; nixpkgs-incompatible; `overrideAttrs` breaks |

## Sources

- [`wyattgill9/nix-cargo-unit`][repo] at `355648f33b07209a5566a3a592e2edbe49303c1e`, clone at `$REPOS/build-systems-research/src/nix-cargo-unit`; all quotes verbatim from the cited files.
- Read in the clone: `README.md`; `research/{comparison,crate2nix}.md`; `bench/{README,comparison}.md`, `bench/nix-cargo-unit/{README,BENCH_BASE}.md`; `Cargo.toml`, `.gitmodules`; `nix/{default,graph,workspace,vendor,policy}.nix`; `templates/units.nix.in`; `src/{main,model,render,hash}.rs`.
- Background: [concepts], [nix-thesis], [nix-ninja], [nixception], [sandstone], [Ninja][ninja], [Buck2][buck2], [content-addressing], [nix-flakes], [Cargo workspace model][cargo-workspace].
- Numbers are the repo's own, single machine, `aarch64-darwin`, `sandbox = false`, CA off; the repo itself marks repeats as ±20 % in [`bench/comparison.md`][bench-comparison].

<!-- References -->

[repo]: https://github.com/wyattgill9/nix-cargo-unit
[readme]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/README.md
[comparison]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/research/comparison.md
[crate2nix-doc]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/research/crate2nix.md
[bench-comparison]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/bench/comparison.md
[bench-base]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/bench/nix-cargo-unit/BENCH_BASE.md
[bench-readme]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/bench/nix-cargo-unit/README.md
[cargo-toml]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/Cargo.toml
[graph-nix]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/nix/graph.nix
[default-nix]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/nix/default.nix
[workspace-nix]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/nix/workspace.nix
[vendor-nix]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/nix/vendor.nix
[policy-nix]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/nix/policy.nix
[template]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/templates/units.nix.in
[model-rs]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/src/model.rs
[render-rs]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/src/render.rs
[main-rs]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/src/main.rs
[hash-rs]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/src/hash.rs
[concepts]: ./concepts.md
[nix-thesis]: ./nix-thesis.md
[nix-ninja]: ./nix-ninja.md
[nixception]: ./nixception.md
[sandstone]: ./sandstone.md
[ninja]: ./ninja.md
[buck2]: ./buck2.md
[content-addressing]: ../content-addressing/index.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/
[cargo-workspace]: ../monorepo-tooling/cargo/
