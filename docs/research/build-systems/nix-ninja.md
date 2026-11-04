# nix-ninja (Rust + Nix)

nix-ninja reads a generated `build.ninja` and emits one Nix derivation per build edge, then
hands the graph to Nix — a translator from Ninja's mtime world into Nix's content-addressed one,
so a Meson or CMake build inherits per-file cache entries and Nix's sandbox without either
project growing a Nix backend.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                                               |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Rust 2021 workspace, four crates under `crates/*` ([`Cargo.toml`][cargo-root]); Nix for packaging/tests                                                                             |
| License               | MIT (`README.md` § License; `license = "MIT"` in the crate manifests)                                                                                                               |
| Repository            | [pdtpartners/nix-ninja][repo] — docs: `README.md`, [`docs/design.md`][design], [`docs/dynamic-derivations.md`][dyn-drv], [`docs/dynamic-deps.md`][dyn-deps], [`docs/todo.md`][todo] |
| Category              | Nix ecosystem — build-graph lowering; engine [nix-thesis], store [content-addressing], opposite direction [nixception], lowered executor [Ninja][ninja]                             |
| Clone (pinned)        | `$REPOS/build-systems-research/src/nix-ninja` at `9a07e673db62566766f6cab1d846530048946a70`; shallow, one commit (author date 2026-05-07), **no tags**                              |
| Version in tree       | `0.1.0` ([`Cargo.toml`][cargo-root]); README plans `0.1.0` correctness, `0.2.0` performance                                                                                         |
| Size                  | ~3.6k lines of Rust — `nix-ninja` (1.8k, `task.rs` alone 971), `deps-infer` (969), `nix-ninja-task` (472), `nix-builder-rpc-client` (306)                                           |
| Scheduler × rebuilder | Topological × deep constructive, **split across two programs** — see placement below                                                                                                |

## Overview

### What it solves

> "Parses `ninja.build` files and generates a derivation per compilation unit.
> … Stores build inputs & outputs in content-addressed derivations for granular
> and Nix-native incrementality."
>
> — [`README.md`][readme] § Key features

Nix's unit of work is the package — one derivation per Meson `project()`, whole compile
inside — while Ninja's unit is the edge. Lowering that unit into Nix's store makes the build
system visible to the cache: a header edit rebuilds one object, not a package.

### Design philosophy

The bet is **Ninja as a lingua franca** rather than per-system backends:

> "since dynamic derivations is somewhat complicated to get right for arbitrary build
> graphs, I think it'll be wise to standardize on a common format like Ninja build files.
> We won't repeat the work for each build system."
>
> — [`docs/design.md`][design] § preamble

The second tenet is that the command is opaque: rewriting `$in`/`$out` to store paths failed
on manifests that hard-code paths inside `COMMAND`, so "the command contents should be
treated as a black box" ([`docs/design.md`][design] § Handling inputs & outputs). Inputs are
symlinked into a recreated tree and outputs copied out afterwards — what
[`nix-ninja-task`][trip-main] exists for.

## How it works

### Manifest to derivation graph

`crates/nix-ninja` parses the manifest with the `n2` crate (a git dependency, so its parser
is outside the clone), then walks the target's closure with a readiness machine `Unneeded →
Want → Ready → Running → Done` ([`build.rs`][build-rs]), reporting cycles against the DFS
stack. Generation must be topological:

> "Nix derivations depending on the output of other derivations need to be generated in
> topological order. This is the same as how `ninja` and `n2` work so `nix-ninja` just
> follows `n2`'s implementation."
>
> — [`docs/design.md`][design] § Topological order

The reason is structural: a consumer's derivation embeds its producer's `.drv` path, directly
or inside a `nix-computed-output:` placeholder, so the producer must exist first. The pass is
not scheduling work — it is resolving names.

### One edge, one derivation

`build_task_derivation` ([`task.rs`][task-rs]) emits a derivation whose builder is
`<store>/bin/nix-ninja-task` and whose single argument is the _unmodified_ Ninja command line;
everything else travels in the environment — `NIX_NINJA_INPUTS` (`path:build_path:rel_path`
records, sorted for determinism), `NIX_NINJA_OUTPUTS` (one `placeholder:build_path` per
output), the propagated `NIX_CFLAGS_COMPILE*` / `NIX_LDFLAGS*` / `NIX_*_WRAPPER*` variables,
and a `PATH` holding `cc`, `coreutils`, `patchelf` plus the store path of the command's head
word when it resolves to one.

Every Ninja output is a **floating content-addressed** output
(`DerivationOutput::CAFloating(…NixArchive(SHA256))`), named after the output path with `/`
replaced by `-`, because a derivation output name cannot contain a slash. The unit is the
_edge_, not the output: a rule with two outputs is one derivation with two CA outputs.

`nix-ninja-task` ([`main.rs`][trip-main]) symlinks each input into `--build-dir` at its
original relative path, runs `/bin/sh -c <cmdline>`, `patchelf`s the RPATH of every ELF
`ET_EXEC`/`ET_DYN` output so libraries resolve to store paths rather than to symlinked inputs
([`patchelf.rs`][patchelf]), and copies outputs to their placeholders — because "ninja build
rules can have implicit outputs that we have no way of knowing"
([`nix-ninja-task/src/main.rs`][trip-main]).

**Interactive** mode emits the derivations, `BuildPaths` them and symlinks results into the
working tree (`local.rs`), so `meson compile` behaves like Ninja. **Inside a derivation**,
[`mkMesonPackage`][mk-meson] makes the outer derivation content-addressed with `outputHashMode
= "text"`, runs `nix-ninja ${target}`, and renames the produced `.drv` via `SubmitOutput`, so
`passthru.target = builtins.outputOf ninjaDrv.outPath normalizedTarget` is buildable; `stdenv`
needs `out = "/nonexistent"`, since `genericBuild` assumes `$out` is set.

### Dynamic task derivations, in place of `dyndep`

For `deps = gcc` edges whose inputs are outputs of other derivations, the header set is
unknowable at generation time, so the task is wrapped in a second derivation that scans first
and emits the real one ([`dynamic-deps.md`][dyn-deps], [`dynamic_task.rs`][dyn-task]):

```text
generated.c.drv            # produces generated.c
generated.c.o.drv.drv      # runs `nix-ninja -t dynamic-task <drv.json>`
  out -> generated.c.o.drv # text-CA output: the updated derivation
generated.c.o.drv          # compiles, now with config.h as an input
main.drv                   # links, via `…drv.drv^out^main.p-generated.c.o`
```

The wrapper copies `$src` into `$NIX_BUILD_TOP/source`, reads the encoded inputs, scans
includes, inserts discoveries into the inner derivation's `inputs` and `NIX_NINJA_INPUTS`,
writes it to the store and `SubmitOutput`s it; Nix then builds the inner derivation as if the
header had been declared all along.

The clone contains no reference to Ninja's `dyndep`; this is the substitute. `dyndep` patches
the running graph when its producer finishes, under an invariant that the patch may not cause
cycles ([ninja][] § `dyndep`); nix-ninja instead produces a _new derivation_ whose identity
already includes the discovered headers. Ninja buys first-build correctness by mutating the
graph, nix-ninja by making the graph an output — hence the nested syntax
`nix build <drv>^foo.drv^bar.drv^out` ([dyn-drv][]).

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix is suspending × deep constructive ([concepts][] §5); Ninja is topological × verifying
traces. nix-ninja occupies no new cell: it **splits generation from execution**. Generation is
topological because derivation names must be resolved in order; execution is Nix's. Its
contribution is at the seam — the suspending scheduler's unit is lowered from "package" to
"compile edge", and dynamic dependencies are recovered without leaving the constructive model.

### 1. Task model & scheduling

The task description is the manifest: static, applicative dependencies, already flattened by the
generator. Generation parallelism is one thread per ready edge, unbounded — `-j` and `-l` are
parsed and never read ([`cli.rs`][cli-rs]), because nothing executes here. Only the first target
is honoured (`targets.first()`; phony aggregation is a TODO), and `-t restat|clean|…` is ignored.

### 2. Rebuilding & correctness

The dirty check is Nix's: a derivation whose outputs are realised is skipped. Because outputs
are `CAFloating`, a realised path is a function of its content, so a recompile producing
identical bytes realises the same path and every dependent is still valid — early cutoff
recovered through content addressing rather than through a trace of intermediate hashes. The
price mirrors JFP §5.4: the intermediate cannot be skipped, since its path is unknown until
built, so a shallow build is impossible.

Correctness rests on the declaration being complete, and it is knowingly over-complete in two
places — every regular file in the build directory is uploaded and added to _every_ task:

> "Build systems like Meson may generate files via `configure_file` that are not
> listed as implicit inputs in the build.ninja file. So we must read the build
> directory and consider them implict inputs for all tasks."
>
> — [`task.rs`][task-rs] `read_build_dir`

and every discovered wrapper store path is an `inputSrc` of every task. Keys widen, but builds stay
correct when the scanner misses; determinism is assumed, never verified.

### 3. Dependency discovery

Four sources, weakest last: declared Ninja edges (explicit, implicit, order-only); absolute
store paths textually scanned from the command line and wrapper variables; `which` resolution
of the head word; and, for `deps = gcc`, a regex BFS over `#include` lines. The scanner is
deliberately not a preprocessor:

> "(2) is 6x faster than (1) as of writing this, but it's not preprocessor aware
> and miss computed includes, etc."
>
> — [`docs/design.md`][design] § Header files

`deps-infer` holds both implementations — a `gcc -MD` depfile runner and the scanner — but the
build path calls only `retrieve_c_includes`; the depfile path is exercised by that crate's own
`--mode correctness|benchmark` CLI. Over-approximation is safe (a header included under
`#ifdef` is still declared); a computed `#include` is missed, and the failure mode is a sandbox
compile error, not a wrong cache hit — no tracing, no strict-deps enforcement. Two identity fixes
sit beside this: `-frandom-seed` is stripped from `NIX_CFLAGS_COMPILE*` and replaced by
`sha256(cmdline)[..16]` per task, because "this will be different every time breaking
incrementality" ([`task.rs`][task-rs]); and absolute build-dir prefixes in the command line are
rewritten to relative ones.

### 4. Store & caching

The Nix store _is_ the cache: no action cache, no metadata table, no eviction policy of its own
— GC is the daemon's, and the repo's `gc.yml` only collects its CI binary cache. Identity per
edge is the derivation hash over the command line, the encoded input set, the propagated wrapper
environment, the CA output names and the builder closure. `.drv` files are uploaded as text-CA
objects, which is what lets a derivation be another derivation's output at all ([dyn-drv][] §
placeholders). Daemon traffic goes through one pooled worker-protocol client
([`nix-builder-rpc-client`][rpc-client]); inside a `builder-rpc-v0` sandbox the allowlist is
`Add{ToStore,ToStoreNar,TextToStore}` plus `SubmitOutput`, so uploaded `.drv` bytes are cached in
memory and `BuildPaths` is used only outside the sandbox.

### 5. Hermeticity & provenance

Each edge is a normal derivation, so it gets the daemon's sandbox and nothing more. The declared
environment is narrow (`PATH` to four store paths, wrapper variables, the encoded lists) and the
builder execs `/bin/sh -c`, resolved inside the sandbox. Two leaks: the _choice_ of toolchain
comes from `which` against the ambient `PATH`, and the whole wrapper environment is copied in —
both recorded in the key, so they cost misses rather than correctness. There is no SLSA, in-toto
or DSSE emission; the `.drv` is the only record, and a good one.

### 6. Distribution

None of its own; remote execution would be Nix's (`--builders` or an REAPI gateway), and the tool
assumes one local daemon. What it buys is _scheduling_ granularity: independent compile edges
become independent derivations, so Nix's parallelism and any substituter see per-object work. See
[nixception][] and [BuildKit][buildkit] for the same move with different seams.

### 7. Sparkles relevance

`sparkles:build-primitives` already models work as `TaskNode`/`TaskEdge` with `ResourceClaim`s
and typed outcomes (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
nix-ninja contributes three mechanics:

- **Separate lowering from execution.** nix-ninja writes derivations and never builds; the
  executor decides what runs. A Sparkles DAG could expose a "materialise keys" phase whose only
  contract is well-formed keys — and, unlike this tool, declare precise inputs instead of copying
  a wrapper environment and a whole build directory into every task.
- **Topological order falls out of key resolution**, not out of a scheduler requirement: once a
  consumer's key embeds its producer's key, the order is forced.
- **Dynamic dependencies as a node, not a graph edit.** Let a node's _key_ be produced by another
  node instead of mutating the DAG mid-run — the constructive analogue of Ninja's `dyndep`.

## Strengths

- **Ninja's unit inside Nix's store** — per-edge derivations, CA outputs, Nix's sandbox and GC,
  plus a `NINJA=`-compatible CLI (`--version` pinned at `1.8.2`) as the adoption strategy.
- **Dynamic dependencies without IFD and without graph mutation** — a clean encoding of
  "discover, then build" in a constructive world, dogfooded on Nix itself and six offline-VM
  NixOS tests ([`nix-build.nix`][nixos-test]).

## Weaknesses

- **Unreleased Nix is a hard floor**: `dynamic-derivations`, `ca-derivations`, `recursive-nix`
  and (at this head) `builder-rpc-v0`; the README warns it "depends on experimental features
  from an unreleased version of Nix".
- **Generation is O(graph) per invocation and uncached** — "~2 minutes" for Nix itself
  ([design][] § Two modes) — so the incremental win starts only after the derivation layer
  exists; benchmarks are open TODOs ([`docs/todo.md`][todo]).
- **Over-declaration blunts granularity**, and the scanner — regex, not preprocessor — is the
  correctness weak point, with the robust depfile alternative unwired from the build path.
- **Docs drift**: [`CONTRIBUTING.md`][contributing] still lists `nix-libstore` and `nix-tool`
  crates that no longer exist (Nix data types now come from `harmonia`).

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                        | Trade-off                                                                 |
| ----------------------------------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------- |
| Ninja manifest as the IR                  | One adapter per build system instead of a backend per system     | Inherits Ninja's static graph; `dyndep` and pools out of reach            |
| One derivation per edge, CA outputs       | Compile-unit granularity; identical bytes realise the same path  | A daemon round-trip and store path per edge; no shallow build             |
| Command treated as a black box            | Real manifests hard-code paths inside `COMMAND`                  | Inputs reconstructed by symlink; outputs copied out afterwards            |
| `nix-ninja-task` as a Rust builder        | No `stdenv` dependency; full control of the sandbox environment  | A second binary that must be in every task's closure                      |
| Discover headers instead of asking gcc    | gcc's depfile does not exist before the first build in a sandbox | Regex over-approximates and misses computed includes                      |
| Two-phase dynamic task derivation         | Discovery expressed as a derivation, not a graph edit            | An extra derivation and scan per generated-input compile                  |
| Propagate `NIX_CFLAGS_COMPILE*` wholesale | The compiler wrapper keeps working without re-deriving it        | Ambient shell state enters every key; `-frandom-seed` must be patched out |

## Sources

- [`pdtpartners/nix-ninja`][repo] at `9a07e673db62566766f6cab1d846530048946a70`, clone at
  `$REPOS/build-systems-research/src/nix-ninja`; quotes are verbatim from the cited files.
- Read in the clone: `README.md`, `docs/{design,dynamic-derivations,dynamic-deps,todo,conventions}.md`,
  `CONTRIBUTING.md`, `Cargo.toml`, `flake.nix`; `crates/nix-ninja/src/{build,task,cli,local,lib,main}.rs`,
  `crates/nix-ninja/src/subtool/dynamic_task.rs`, `crates/nix-ninja-task/src/{main,derived_file,patchelf}.rs`,
  `crates/deps-infer/src/{main,c_include_parser,gcc_depfile,gcc_depfile_parser,gcc_include_parser}.rs`,
  `crates/nix-builder-rpc-client/src/lib.rs`, `modules/flake/pkgs/mkMesonPackage/default.nix`,
  `modules/flake/{overlays,packages,checks}.nix`, `modules/flake/examples/nix/default.nix`,
  `modules/flake/examples/dynamic-deps/{meson.build,generate.sh,main.cpp}`,
  `modules/nixos/tests/{nix-build,nix-build-dynamic-deps}.nix`, `.github/workflows/{ci,gc}.yml`.
- Background: [concepts], [nix-thesis], [nixception], [Ninja][ninja], [content-addressing] and
  its [REAPI page][ca-reapi], [nix-flakes].

<!-- References -->

[repo]: https://github.com/pdtpartners/nix-ninja
[readme]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/README.md
[design]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/docs/design.md
[dyn-drv]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/docs/dynamic-derivations.md
[dyn-deps]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/docs/dynamic-deps.md
[todo]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/docs/todo.md
[contributing]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/CONTRIBUTING.md
[cargo-root]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/Cargo.toml
[build-rs]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja/src/build.rs
[task-rs]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja/src/task.rs
[cli-rs]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja/src/cli.rs
[dyn-task]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja/src/subtool/dynamic_task.rs
[trip-main]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja-task/src/main.rs
[patchelf]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-ninja-task/src/patchelf.rs
[rpc-client]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/crates/nix-builder-rpc-client/src/lib.rs
[mk-meson]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/modules/flake/pkgs/mkMesonPackage/default.nix
[nixos-test]: https://github.com/pdtpartners/nix-ninja/blob/9a07e673db62566766f6cab1d846530048946a70/modules/nixos/tests/nix-build.nix
[concepts]: ./concepts.md
[nix-thesis]: ./nix-thesis.md
[nixception]: ./nixception.md
[ninja]: ./ninja.md
[buildkit]: ./buildkit.md
[content-addressing]: ../content-addressing/index.md
[ca-reapi]: ../content-addressing/reapi.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/
