# drowse (Nix)

A 267-line Nix library that hides the boilerplate of Nix's dynamic derivations: `callPackage`,
`nix-instantiate` and `crate2nix` become build steps that emit a derivation, so package expressions
are evaluated during the build rather than before it.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                                 |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Nix only — 11 `.nix` files, 566 lines including tests and the flake template; 267 lines under `src/`; no compiled code                                                |
| License               | MPL-2.0 ([`LICENSE`][license])                                                                                                                                        |
| Repository            | [figsoda/drowse][repo] — docs: [`README.md`][readme] (175 lines); the source is the reference                                                                         |
| Category              | Nix ecosystem — authoring layer over dynamic derivations, not a build engine                                                                                          |
| Clone (pinned)        | `$REPOS/build-systems-research/src/drowse` at `26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb`; shallow, one commit (author date 2026-10-20), **no tags**; 25 tracked files |
| Dependencies          | `flake-parts`, `haumea` `v0.2.2`, `nixpkgs` (`nixos-unstable`, a branch, not a rev) ([`flake.nix`][flake])                                                            |
| Requires (Nix)        | `ca-derivations`, `dynamic-derivations`, `recursive-nix` ([`README.md`][readme] § Usage)                                                                              |
| Scheduler × rebuilder | Does not occupy a cell — a lowering layer, not a `Build`; see [Placement](#placement-in-the-design-space)                                                             |

## Overview

### What it solves

The complaint is prior and specific: fine-grained dependency caching otherwise needs
import-from-derivation (IFD) or committed generated files.

> "Tools like [crate2nix] allow for the fine-grain caching of dependencies.
> However they rely on either import-from-derivation (IFD),
> which nukes the evaluation time by sequentializing the process,
> or code generation, which clutters git history, and still might have a negative
> impact on evaluation time due to how big some generated files are."
>
> — [`README.md`][readme] § Why

The README's own summary is that dynamic derivations give "the best of both worlds: fine-grained
caching without IFD or code generation", and that drowse "aims to reduce the boilerplate"
([`README.md`][readme] § Why). So it is a **verbosity reduction over an existing experimental
mechanism**: everything it does is expressible by hand as a content-addressed derivation whose
output is a `.drv`, then `builtins.outputOf` to build what that file describes. The library's
contribution is that the pattern becomes one call, keeps `finalAttrs` semantics, and preserves the
wrapped package's name, `meta` and error position.

> [!NOTE]
> drowse does **not** observe the daemon, builds, or store activity: the clone has no `nix-store`
> invocation, no daemon-protocol client, no tracing layer and no scheduler. Its only daemon contact
> is indirect — a builder runs `nix-instantiate` and the daemon accepts the resulting derivation
> because it declares the `recursive-nix` feature — so the observation question this page was
> commissioned with is answered negative.

### Design philosophy

Three traits are visible in source rather than prose. **Stay at expression level**: no helper
language, no new file format — the API is `lib.extendMkDerivation` plumbing. **Do not leak the
wrapper**: `pname`, `version`, `meta` and the user attribute's source position are carried onto the
wrapper, so `nix build` and error messages behave as for an ordinary package. **Accept an attribute
set or a string** for arguments, because the `override { … }`-heavy call sites think in expression
fragments.

## How it works

### The two derivations

`mkDynamicDerivation` ([`src/mkDynamicDerivation.nix`][mkdyn]) is the base of everything else: it
builds with `stdenvNoCC.mkDerivation` and forces the output to be a derivation file by setting
`name = "${name}.drv"`, `__contentAddressed = true`, `outputHashAlgo = "sha256"`,
`outputHashMode = "text"` and `requiredSystemFeatures = [ "recursive-nix" ]`.

`outputHashMode = "text"` is load-bearing — the text method is the dynamic-derivations feature's
entry point ("The use of this method for derivation outputs is part of the
[`dynamic-derivations`][xp-dyn-drv] experimental feature", [`advanced-attributes.md`][adv-attrs]),
and a text content address is `text:sha256:<sha256 hash of file contents>`
([`content-address.hh`][content-address-hh]). The output is one file keyed by its bytes: a `.drv`
whose text _is_ its identity.

`transformDrv` then wraps that in an ordinary derivation whose only job is to point at what the
first describes — `runCommand drv.outName args "ln -s ${builtins.outputOf "${drv}" "out"} $out"`.
`builtins.outputOf` takes a derived path and an output name and yields the derived path of whatever
derivation that output turns out to be ([`primops.cc`][primops], `prim_outputOf`); the user-facing
package is a symlink to the realised inner output, carrying the wrapper's `pname`/`version`/`meta`
and a `passthru.drv` back to the plan.

### `instantiate` and `callPackage`

`instantiate` ([`src/instantiate.nix`][instantiate]) is the general form: `expr` leaves the
derivation arguments (`excludeDrvArgNames`) and travels as a file (`passAsFile =
[ "instantiateExpr" ]`); a build phase runs `drv=$(nix-instantiate - < "$instantiateExprPath")` and
installs the result as `$out`. `installPhase` repeats the `install` that `buildPhase` already did —
harmless, and a prototype tell.

`callPackage` ([`src/callPackage.nix`][callpackage]) layers on it and reproduces `pkgs.callPackage`
shape at build time: the expression evaluates
`(import <nixpkgs> { }).callPackage (builtins.getEnv "callPackageSrc") args`, then applies
`drv.overrideAttrs` to rename the result to `finalAttrs.passthru.outName`. `__mkArgs.nix`
([`src/__mkArgs.nix`][mkargs]) decides how `args` crosses the build boundary: a string is spliced as
`(import (builtins.getEnv …Path))`, an attribute set becomes
`(builtins.fromJSON (builtins.readFile …Path))` over `builtins.toJSON`. `__pathToString.nix`
([`src/__pathToString.nix`][pathtostring]) avoids copying nixpkgs into the store just to name it in
`NIX_PATH`: for a store path that is not a derivation it returns the string with an appended
`{ <path>.path = true; }` context — its comment says "avoid copying stuff to the store when
possible". Because the expression rewrites the generated package's `name`, the README asks users to
repeat the name already in `src`: "It is also recommended to specify a `name`, or `pname` and
`version`, that is the same as the ones provided in `src`" ([`README.md`][readme] § callPackage).

### `crate2nix`

`crate2nix` ([`src/crate2nix.nix`][crate2nix-src]) specializes the pattern to a `Cargo.nix` the
generator writes _inside the sandbox_: a `preBuild` hook appends `crate2nix generate`, then `expr`
does `import ./Cargo.nix args`, applies a user `select` expression (default
`"project: project.rootCrate.build"`), and overrides the name as `callPackage` does.
`dynamicCargoDeps` (default `true`) wraps `rustPlatform.importCargoLock` in a nested `callPackage`
named `cargo-vendor-dir`, so the vendored crate set is itself produced dynamically — the closest
this repo comes to "one derivation per dependency unit".

`passthru.drv` exposes the plan, and `outPos = builtins.unsafeGetAttrPos` records where the user
wrote the naming attribute, which `transformDrv` forwards to `runCommand` as `pos`. The tests assert
`meta.position` and `meta.mainProgram` through a plain `runCommand` ([`tests/default.nix`][tests]) —
unusual care for a wrapper, which usually loses metadata and reports errors from library code.
Nothing else touches the store: no daemon RPC, no `nix-store --query`, no observation, no scheduling.

## Placement in the design space

drowse cannot occupy a cell of the [scheduler × rebuilder grid](./concepts.md#5-the-design-space):
it is not a `Build`, renders no `Store` and makes no up-to-date decision; the system it composes
with is Nix, which the grid places at _suspending × deep constructive_
([concepts §5](./concepts.md#5-the-design-space)). What drowse adds is a change of **phase** — part
of the task description is now produced by a task, the move [Sandstone][sandstone] makes for GHC
modules and [nix-ninja][nix-ninja] for Ninja edges, except those make a _build_ emit derivations
while drowse makes a trivial build emit the derivation evaluation would have produced.
Classification: **no cell of its own; it enriches Nix's cell with a derivation-level dynamic
dependency.**

## 1. Task model & scheduling

One call yields two derivations: the plan producer (`__contentAddressed`, text output) and the
symlink wrapper. The wrapper's `outputOf` reference cannot resolve until the producer is built, so
the inner derivation is a barrier — Nix builds the producer's declared inputs (`nix`, `crate2nix`,
the source tree, `NIX_PATH`'s nixpkgs) in parallel, then serializes; deeper parallelism is lost
because the inner graph's inputs are unknown before then. There is no scheduler logic here: ordering
and substitution are Nix's, and the one decision is to spend an extra derivation moving evaluation
off the top-level evaluation's critical path.

## 2. Rebuilding & correctness

The interesting property is **derivation-level early cutoff**. Because the producer's output is
text-content-addressed, identical generated `.drv` bytes give the identical store path, so a
dependent referencing `outputOf` does not re-key when a plan is regenerated unchanged. Change one
attribute inside the expression and the text, the path and the inner derivation's key all change —
a cache miss with a precise cause. That is [Sandstone][sandstone]'s interface-level cutoff applied
to the plan; below it the inner derivation stays deep constructive, so any changed input re-keys
the whole package.

Three limits:

- **Completeness is the expression's problem.** Whatever the inner expression reads must be a
  declared input of the outer derivation; nothing traces the evaluator.
- **Names are duplicated by hand.** The wrapper takes the caller's `pname`/`version`, the real
  package `src`'s; the README recommends they match and nothing checks it, so drift yields a
  package whose build name disagrees with its inner derivation.
- **Non-determinism is a miss, not a failure.** An equivalent but differently-spelled `.drv`
  re-keys and rebuilds; nothing validates agreement, unlike the crate2nix equivalence test
  ([`testers.testEqualContents`][tests]).

## 3. Dependency discovery

Declared, never traced, not even depfile-assisted: the graph a drowse package presents to Nix is
exactly what the `.drv` says, and nothing can add an edge the evaluator did not name. Its dynamicity
is at the _derivation-construction_ level (the plan is computed late) rather than the
[file-dependency level](./concepts.md#static-versus-dynamic-dependencies) (`need`-style discovery of
names that exist only after a build): drowse defers _which derivation_, Shake and Nix defer _which
files inside a derivation_. Nothing here addresses strict-deps enforcement, unused-dependency
pruning or over-declaration — `src` is usually a whole tree (`fs.toSource`,
[`templates/crate2nix/flake.nix`][template]), so over-declaration is the default.

## 4. Store & caching

The Nix store is the only cache: no action cache, no metadata index, no eviction policy. Two objects
matter — the text-addressed `.drv` (the plan, addressable by content) and the content-addressed
outputs the inner derivation produces; `passthru.drv` is the handle to the first, and
`builtins.outputOf` the only way to chain from a plan to its result. That a `.drv` can be a store
object is the experimental floor: `ca-derivations` for CA outputs, `dynamic-derivations` for the
text method and `outputOf`, `recursive-nix` so a builder may instantiate. The check workflow enables
exactly those and sets `allow-import-from-derivation = false` in the same breath
([`.github/workflows/check.yml`][ci]), so a passing `nix flake check` is the proof of the claim.

## 5. Hermeticity & provenance

Each step is an ordinary derivation, so it gets the daemon's sandbox and no more: narrow `PATH`,
absolute tool paths, no network. But evaluation now runs _inside_ a build, with the store readable,
and `nix-instantiate` there must register a derivation — the reason for `recursive-nix`. That
builder is more privileged than one that writes files, and what a package expression does is no
longer visible at evaluation time, only in the build.

Reproducibility is inherited, not engineered: `.drv` text is deterministic given the expression,
`args` and store paths, and text addressing makes that determinism observable as a map from plan
bytes to path. No `SOURCE_DATE_EPOCH` handling, no attestation, no SLSA or in-toto emission — the
`.drv` text is the whole record.

## 6. Distribution

None of its own, with two frictions. **An extra unit per package**: every wrap adds a plan producer
and a wrapper, so a remote fleet sees roughly twice the nodes, one a trivial `ln -s`. **A machine
feature**: `requiredSystemFeatures = [ "recursive-nix" ]` means builders must advertise it — a fleet
without it refuses the job rather than degrading, the same constraint [nix-ninja][nix-ninja] and
[Sandstone][sandstone] carry. The flake declares four systems while CI covers three;
`x86_64-darwin` is declared but not built ([`flake.nix`][flake], [`check.yml`][ci]).

## Strengths

- **Boilerplate removed at the smallest possible cost** — no binary, no file format, no daemon
  client; 267 lines of Nix behind a `callPackage`-shaped API.
- **Wrapper transparency** — `pname`, `version`, `meta`, `meta.position`, `passthru.drv` and
  `finalAttrs` survive the extra derivation; and the claim is tested, with IFD disabled in CI and
  `testEqualContents` proving the dynamic and static crate2nix paths agree.

## Weaknesses

- **Not an observer** — no daemon protocol, no tracing, no store accounting: answered by an absence.
- **Duplicated identity** — `pname`/`version` restated from `src`, unchecked, and the inner nixpkgs
  fixed by the wrapper's `NIX_PATH`.
- **Prototype signals** — single-commit shallow clone, no tags, an `installPhase` reinstalling its
  own file, `x86_64-darwin` untested, and one ecosystem adapter (`crate2nix`).

## Key design decisions and trade-offs

| Decision                            | Rationale                                                                | Trade-off                                                                        |
| ----------------------------------- | ------------------------------------------------------------------------ | -------------------------------------------------------------------------------- |
| Derivation as a task's output       | Evaluation moves into the build, so caching is per package, not per eval | One extra derivation and a plan-boundary barrier per wrapped package             |
| Text-CA output, never NAR           | The plan's bytes are its identity, giving derivation-level early cutoff  | Needs `dynamic-derivations`; output is one file, not a tree                      |
| A library, not a CLI                | Nothing to install, trust, or keep in sync with Nix                      | No observation, no diagnostics, no plan inspection without building it           |
| `expr`/`args` passed as files       | Expression text stays out of the environment and out of eval time        | Caller restates `pname`/`version`; expression strings are unvalidated Nix code   |
| `import <nixpkgs>` inside the build | One cheap eval per package instead of one expensive top-level eval       | Inner nixpkgs is fixed by the wrapper's `NIX_PATH`, not by the caller's override |
| Wrapper symlink plus `passthru.drv` | `nix build .#pkg` behaves normally and the raw plan stays reachable      | Two names and two derivations to align; `nix-tree` output doubles                |
| Generators run inside the sandbox   | `Cargo.nix` never enters git and needs no IFD                            | Generator failures surface as build errors; a generator change re-keys plans     |

## Sparkles relevance

`sparkles:build-primitives` already models a plan as graph data — `TaskNode`/`TaskEdge` with typed
`EdgeReason`s including `planning`
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`) — but its
DAG is built from `dub.sdl` before any work runs. drowse shows what changes when a node's _output_
is a plan.

- **A plan can be a node, and its identity is its bytes.** A plan node keyed by the text of the
  tasks it declares means an unchanged plan does not invalidate its dependents;
  [concepts](./concepts.md#3-rebuilders) notes deep constructive traces cannot early-cutoff _inside_
  a derivation, so text addressing gives that cutoff at the plan boundary instead.
- **The barrier is a scheduling cost, not a node-type detail.** Put a plan producer into a
  currently-static DAG and the rest of the graph is unknown until it finishes — a suspending
  scheduler, not a topological one, so the plan boundary must be an explicit sync point.
- **Duplicated keys are the failure mode.** "Specify `pname`/`version` the same as `src`" is the same
  hazard as a hand-declared `TaskNode` key: when name and content can drift, a rebuild either
  over-fires or silently matches. A plan node should key on the plan, never on a label.

## Sources

- [`figsoda/drowse`][repo] at `26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb`, clone at
  `$REPOS/build-systems-research/src/drowse`; quotes are verbatim from `README.md` and one comment.
- Read in the clone: `README.md`, `LICENSE`, `default.nix`, `flake.nix`,
  `src/{mkDynamicDerivation,instantiate,callPackage,crate2nix,__mkArgs,__pathToString}.nix`,
  `tests/{default,hello}.nix`, `tests/hello-rs/…`, `templates/crate2nix/flake.nix`,
  `.github/workflows/check.yml`, `.github/dependabot.yml`. `git log` shows one commit and `git tag`
  is empty, so history and release maturity are not assessable from this clone.
- Read in the Nix clone at `1ed54a0fd62da96d4f5e9c806555861e46f65341` (via `git show`):
  [`advanced-attributes.md`][adv-attrs] (`outputHashMode` "text"),
  [`content-address.hh`][content-address-hh] (text content address),
  [`primops.cc`][primops] (`prim_outputOf`).
- Background: [concepts][] (grid placement, early cutoff, static vs dynamic dependencies),
  [nix-thesis][] (derivations and the store), [Sandstone][sandstone] and [nix-ninja][nix-ninja] (the
  same plan-as-output move), [nixception][nixception] (the inverse seam), [content-addressing][] for
  text vs NAR hashing, and [nix-flakes][nix-flakes] for the flake-input side.

<!-- References -->

[repo]: https://github.com/figsoda/drowse
[readme]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/README.md
[license]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/LICENSE
[flake]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/flake.nix
[mkdyn]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/mkDynamicDerivation.nix
[instantiate]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/instantiate.nix
[callpackage]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/callPackage.nix
[crate2nix-src]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/crate2nix.nix
[mkargs]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/__mkArgs.nix
[pathtostring]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/src/__pathToString.nix
[tests]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/tests/default.nix
[template]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/templates/crate2nix/flake.nix
[ci]: https://github.com/figsoda/drowse/blob/26ed5b2bdbae0e8dfed4f306b5a91e240b6951fb/.github/workflows/check.yml
[crate2nix]: https://github.com/nix-community/crate2nix
[xp-dyn-drv]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/development/experimental-features.md
[adv-attrs]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/language/advanced-attributes.md
[content-address-hh]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/include/nix/store/content-address.hh
[primops]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libexpr/primops.cc
[concepts]: ./concepts.md
[nix-thesis]: ./nix-thesis.md
[sandstone]: ./sandstone.md
[nix-ninja]: ./nix-ninja.md
[nixception]: ./nixception.md
[content-addressing]: ../content-addressing/index.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/index.md
