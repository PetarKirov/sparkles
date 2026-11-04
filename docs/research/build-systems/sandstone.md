# Sandstone (Haskell + Nix)

Compiles each Haskell module as its own content-addressed Nix derivation — two outputs per module,
`object` and `interface` — and lets a _build_ emit the per-module derivation graph, so the unit of
caching drops from package to module while Nix keeps ownership of scheduling, sandboxing and sharing.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                          |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Haskell (`cabal-version: 3.0`, `base ^>=4.18.2.1`), plus Nix for packaging and the build fixture                                                               |
| License               | BSD-3-Clause (`LICENSE`; `license: BSD-3-Clause` in [`sandstone.cabal`][cabal])                                                                                |
| Repository            | [obsidiansystems/sandstone][repo] — Obsidian Systems                                                                                                           |
| Documentation         | `README.md` only; [`CHANGELOG.md`][changelog] is a `YYYY-mm-dd` stub                                                                                           |
| Category              | Nix ecosystem — store-granularity lowering for a compiler; engine [nix-thesis], neighbours [nix-ninja] and [nixception]                                        |
| Clone (pinned)        | `$REPOS/build-systems-research/src/sandstone` at `d37daed607bba504be05f732b21b9a03a8f012a3` (2026-06-19); shallow, **one commit**, **no tags**                 |
| Version / status      | `0.1.0.0` ([`sandstone.cabal`][cabal]); 464 lines of library Haskell, 125 in two demos, 39 of example sources; the README's "early prototype"                  |
| Pinned dependencies   | Nix from `master` (`b4bea576…`), an `hnix-store` fork on branch `derivation-work` (`7a4aef8c…`), `nixpkgs` `release-24.11` (`8840c8cd…`) — `dep/*/github.json` |
| Scheduler × rebuilder | Suspending × deep constructive (Nix's cell), with the derivation _set_ produced at build time — see placement                                                  |

## Overview

### What it solves

> "Nix builds a Haskell package as a single derivation: GHC compiles the whole package at once, and
> the smallest source change invalidates the entire build. Cabal's incremental rebuilds soften this
> locally, but that work is invisible to Nix and unshared between machines and CI."
>
> — [`README.md`][readme] § Why

Nix's unit is the package; GHC's is the module, and Cabal knows the module graph while Nix cannot see
it. Sandstone moves that graph across the boundary: "changing one module rebuilds one module, not the
world" ([`README.md`][readme]).

### Design philosophy

The README calls the tool "glue between two existing mechanisms" ([`README.md`][readme] § How it
works): GHC's `-M` dependency dump and Nix's dynamic derivations. No part of GHC is replaced, no Nix
expression is evaluated. Derivations are **data** — `hnix-store`'s `System.Nix.Derivation` types
injected through `nix derivation add`'s JSON interface ([`WriteDerivation.hs`][write-drv],
[`NixCLI.hs`][nixcli], [`derivation-add.md`][nix-deriv-add]).

## How it works

### From `ghc -M` to a module graph

`ghc -M` emits a Makefile whose rules are `.o`/`.o-boot` targets over `.hs`/`.hs-boot` sources and
`.hi`/`.hi-boot` prerequisites. [`GhcMakefile/Parse.hs`][parse-hs] is a line-oriented parser for
exactly that shape — `T.breakOn " : "`, then an extension whitelist on both sides — accumulating
errors in an `ErrorForest` (`Data.Validation`) instead of failing at the first bad line. `.o` and
`.o-boot` targets become `Module False`/`Module True`; `.hi`/`.hi-boot` prerequisites become edges;
source-file prerequisites are dropped, because the file enters its own compile derivation directly:

> "Mere source file dep, which we don't track as a dep since it is conditional"
>
> — [`GhcMakefile/Parse.hs`][parse-hs] `recordModule`

Mutual recursion is handled by **splitting the node**, not by special-casing the scheduler: a module
with an `hs-boot` file is two vertices — `Module True` (produces `.hi-boot` and a mostly-fake
`.o-boot`) and `Module False` (produces `.hi`/`.o`) — so a `SOURCE` import points at the boot vertex,
which sits strictly earlier. The bundled `example/` exercises it: `X` imports `D`, `D` imports `B`,
and `B` imports `X {-# SOURCE #-}`, acyclic only because `X.hs-boot` is its own vertex
([`example/X.hs-boot`][example-boot]); `.o-boot` is skipped at link time because it is empty.

### One compile derivation per module

[`WriteDerivation.hs`][write-drv] walks `reverseTopSort graph` — dependencies first — memoising each
module's `.drv` path in a `StateT DrvMemo`, because a dependent's input list embeds its producer's
derivation path. A missing memo entry is a hard failure (every `Map.lookup` must return `Just`), which
makes the topological order load-bearing rather than decorative.

```text
name    compile-<Module.Name>
outputs object, interface        (both content-addressed: NAR, SHA-256)
inputs  <source>.hs, ghc^out, bash^out, coreutils^out, lndir^out,
        <dep>.drv^interface …    (one per import)
builder ${bash}/bin/bash
args    -c "set -xeu; mkdir -p $object/… $interface/…; lndir ${dep}/interface $interface …;
            ${ghc}/bin/ghc -c <source> -o $object/… -ohi $interface/… -hidir $interface"
env     object, interface (placeholders), PATH=${coreutils}/bin
```

Three details carry the design:

- **Only interfaces are edges.** A compile node depends on its imports' `interface` outputs, never
  their `object` outputs, so it never waits for code generation it will not consume.
- **The interface output is a tree, not a file.** Each dependency's interface output is `lndir`ed into
  the module's own `$interface` before GHC runs, so the output holds the module's `.hi` **plus
  symlinks** to every import's interface path; its NAR hash covers the interface closure.
- **The toolchain is a derived path.** `PathCtx` holds `ghc`, `bash`, `coreutils` and `lndir` as
  `SingleDerivedPath`, so they are referenced as `<drv>^out`; `demo-ca` instantiates the last three and
  never builds them, realising only the `ghc` it must run.

`platform` is the literal `"x86_64-linux"` in both builders ([`WriteDerivation.hs`][write-drv]) while
[`release.nix`][release-nix] enumerates `x86_64-linux` and `aarch64-darwin`: the library
cross-compiles, the derivations it emits declare one platform — matching the README's "assumes Linux
(`x86_64-linux`)".

One further derivation takes every object output in the graph and runs `ghc -o $out` over downstream
placeholders for them, skipping `.o-boot`. It depends on all vertices, not on `Main`'s reachability
closure — correct here, wasteful for a library, and where a real driver would prune.

### The graph as a build product

`demo-dyn-drv` is the same pipeline with one difference: it runs _inside_ a Nix build, reads `ghc`,
`sources`, `NIX_BUILD_TOP` and `out` from the environment, runs `ghc -M` into the build directory, and
`copyFile`s the final `.drv` into `$out` ([`demo-dyn-drv.hs`][demo-dyn]). The enclosing derivation is
text-content-addressed, so its output _is_ the derivation file:

```nix
requiredSystemFeatures = [ "recursive-nix" ];
__contentAddressed = true; outputHashMode = "text"; outputHashAlgo = "sha256";
dyn-drvs-test-res = builtins.outputOf dyn-drvs-test.outPath "out";   # default.nix
```

`builtins.outputOf` turns a derivation whose output is a `.drv` into a buildable target; the primop's
own documentation states the nested-selection rule Sandstone relies on ("If the derivation is
produced by a derivation, you must explicitly select `drv.outPath`. This primop can be chained
arbitrarily deeply" — [`src/libexpr/primops.cc`][nix-primops] at `1ed54a0`), and Nix's functional
test records why the outer derivation must be text-hashed: the outer build "refer[s] to the path of
the drv file", not to any output of it ([`build-built-drv.sh`][nix-dyn-test]).

The three toolchain paths arrive as `<drvPath>!out` strings built from
`builtins.unsafeDiscardOutputDependency`, beside a "`# TODO should use ^`" note
([`default.nix`][default-nix]); `ghc` alone is a realised `outPath`, because the generator runs it
immediately — "Different because we need ot use right away" ([`demo-dyn-drv.hs`][demo-dyn], typo in
the original).

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix is suspending × deep constructive ([concepts][] §5); Sandstone adds no scheduler and no rebuilder,
so it inherits that cell. Its contribution is upstream of the grid: it changes the **granularity of a
key** from package to module and produces the key set from a build rather than from evaluation.

### 1. Task model & scheduling

The task description is GHC's Makefile: static, applicative, flattened by the compiler before
Sandstone sees it. Generation is a single-threaded topological walk with memoisation; execution is
entirely Nix's, so parallelism across independent modules comes from the daemon's build slots. There
is no `-j`, no pools, no speculation, and no per-target selection: the link derivation consumes every
vertex. "Dynamic" means the derivation _set_ is a build product, not that edges appear mid-build — the
graph is fixed before the first compile derivation is written, hence no `dyndep`-style patch
(contrast [nix-ninja][]).

### 2. Rebuilding & correctness

The dirty check is Nix's: a realised output is reused; a changed key yields a new derivation. Both
compile outputs are floating content-addressed (`ContentAddressMethod_NixArchive`, SHA-256), so a
module's path is a function of its bytes, and an implementation-only edit that leaves `.hi`
byte-identical presents dependents with the same interface path — the GHC-level early-cutoff
condition, visible to the store because the interface is its own artifact. Two honest limits: the
consumer embeds an input _placeholder_ derived from the producer's `.drv`, so a producer input change
re-keys dependents even when the realised interface is unchanged (whether Nix then elides the rebuild
is untested here); and a floating CA output has no declared hash to check against — its path is
computed from the bytes _after_ the build — so nondeterminism surfaces as a cache miss, not a failure.

Correctness rests on `ghc -M` being complete, and nothing verifies it: no strace, no FUSE, no
declared-inputs check, no fallback over-approximation as in [nix-ninja][]'s read-the-build-dir rule.
An under-declared input fails as a sandbox compile error, not a wrong cache hit.

### 3. Dependency discovery

Compiler depfile, nothing else. `ghc -M` is a whole-tree pass over the sources that must run before any
derivation can be keyed, and it runs uncached — `demo-ca` re-runs it every invocation, writing
`example/Makefile` into the source tree, an artifact git-ignored under "`# GHC -M makes these`". The
parse admits only the extensions `ghc -M` emits today; `Module`'s `TODO backpack sigs` marks the known
hole ([`GhcMakefile/Graph.hs`][graph-hs]). Same trade as `gcc -MD` depfiles: exact at the compiler's own
notion of an import, with discovery paid up front and outside the cache.

### 4. Store & caching

The Nix store is the cache: no action cache, no metadata index, no eviction policy of its own. Every
module source is `nix store add`ed as its own content-addressed object, so source bytes are part of
each compile key; `.drv` files are uploaded as JSON; sharing is whatever `--substituters` provides.
`demo-ca` builds into a scratch store at `/tmp/sand` (`storePath` is a constant) while store paths are
composed with `storeDir = def`, so the store root appears in two places and the demos are wired to one
store at a time ([`demo-ca.hs`][demo-ca]). The boundary to Nix is a shell: `nix store add`,
`nix derivation add` and `nix build <drv>^*` are separate `process` calls, derivations travelling as
JSON on stdin, and [`cabal.project`][cabal-project] pulls the `hnix-store` fork for `hnix-store-core`
and `hnix-store-json` only. The module header records why:

> "For now, we \"shell out\" using the Nix CLI, but for better performance, we should probably
> instead directly use the daemon protocol as implemented in 'hnix-store-remote'. … We would have
> done that right away, but there are some regression on the WIP PR of 'hnix-store' we are currently
> using."
>
> — [`Sandstone/NixCLI.hs`][nixcli]

### 5. Hermeticity & provenance

Each compile and link is an ordinary derivation, so it gets the daemon's sandbox and no more: a narrow
environment (`PATH` = coreutils, placeholder env vars), an absolute toolchain, and no C compiler or
binutils in the declared inputs. The _generator_ is where hermeticity thins out. `demo-ca` runs in
the ambient shell, reads the working tree, writes `Makefile` back into it, and shells out to `nix`;
`demo-dyn-drv` runs the same code inside a `recursive-nix` build, so the builder talks to the daemon
and writes to the store. That is the trust price of producing a derivation from a build: the producer
is a privileged builder, and what it hands back is opaque bytes until the daemon parses them. No
SLSA, in-toto or DSSE emission; the `.drv` is the record.

### 6. Distribution

None of its own: the per-module derivations are exactly the units a substituter or `--builders` fleet
distributes, so the win is that the _cache_ key is now a module. The constraint is ecosystem-wide:
every client and daemon in the path needs `ca-derivations`, `dynamic-derivations` and (for the
in-build generator) `recursive-nix` — at this pin, Nix from `master` and a fork of `hnix-store`.

### 7. Sparkles relevance

`sparkles:build-primitives` models work as `TaskNode`/`TaskEdge` with typed `EdgeReason`s, including
`planning` (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`),
and has no notion of a key, a store, or an artifact-level edge. Sandstone contributes three mechanics:

- **Edge on the narrowest artifact.** A dependent needs import/interface data, not the object file.
  Sandstone makes that an explicit `interface` output and the only edge — the store-level counterpart
  of a D build depending on `.di` files or an ABI digest: a `TaskEdge` could carry _which_ output of
  the prerequisite the dependent consumes.
- **A plan can be a node's output.** Sparkles already has `planning` edges; Sandstone shows the store
  mechanics once the planner is itself a task — the plan is text-content-addressed and the consumer
  selects an output of it, which also makes a plan-producing node a real barrier.
- **Depfile discovery as its own cached task.** Sandstone pays a full `ghc -M` every run because the
  depfile is not a node; making it one with its own key (for D, the compiler's dependency dump) turns
  a whole-tree preprocess pass into a cache hit — [nix-ninja][]'s "generation is O(graph) per
  invocation and uncached" again.

## Strengths

- **The right unit, made real** — module-grained CA derivations, and `hs-boot` cycles split into
  nodes rather than worked around in the scheduler.
- **No Nix evaluation in the loop** — typed Haskell derivations injected as JSON; the toolchain named as
  a derived path, not built first.
- **A complete dynamic-derivation demonstration** — `recursive-nix` build, text-hashed `.drv` output
  and `builtins.outputOf` chaining in one `default.nix`.

## Weaknesses

- **Prototype, and says so**: one commit in the clone, no tags, no test suite, a `YYYY-mm-dd`
  changelog, and a README calling it "not for production builds".
- **Unreleased-Nix floor** — `ca-derivations`, `dynamic-derivations`, `recursive-nix`, a WIP
  `hnix-store` fork, and one process spawn per derivation while the daemon client is blocked.
- **Discovery is uncached and textual** — a full `ghc -M` per invocation, a parser keyed to the exact
  Makefile shape GHC emits, no Backpack, nothing checking the declaration was complete.
- **Hard-coded platform and single store** — `"x86_64-linux"` in the emitted derivations and `/tmp/sand`
  in the demo; the link step covers every vertex, not the target's closure.

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                     | Trade-off                                                                   |
| ----------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------- |
| Module as the derivation unit             | The smallest unit GHC can compile and reuse                   | Store paths and daemon round-trips grow by orders of magnitude              |
| Separate `object` and `interface` outputs | Dependents consume only the contract, never the code          | Each interface output is a tree with symlinked deps; key covers the closure |
| Interface-only dependency edges           | Early cutoff becomes possible at the `.hi` boundary           | Placeholder re-keying still follows the producer's `.drv`                   |
| `ghc -M` instead of tracing               | Exact by the compiler's own rules, no syscall layer           | Whole-tree preprocess pass before any work, uncached                        |
| `hs-boot` as a distinct vertex            | Keeps the graph acyclic without scheduler support             | `.o-boot` special cases leak into the link step                             |
| The graph produced by a build             | The plan itself becomes cacheable and shareable               | Needs `recursive-nix`; the generator holds store-write trust                |
| Text-hashed outer derivation              | A `.drv` is just bytes, so the output can _be_ the derivation | Opaque to evaluation; chains only through `builtins.outputOf`               |

## Sources

- [`obsidiansystems/sandstone`][repo] at `d37daed607bba504be05f732b21b9a03a8f012a3`, clone at
  `$REPOS/build-systems-research/src/sandstone`; quotes are verbatim from the cited files, including
  the demo's own "`ot`" typo.
- Read in the clone: `README.md`, `CHANGELOG.md`, `sandstone.cabal`, `cabal.project`, `.gitignore`,
  `default.nix`, `release.nix`, `src/Sandstone/{Error,NixCLI,WriteDerivation}.hs`,
  `src/Sandstone/GhcMakefile/{Graph,Parse}.hs`, `src-bin/{demo-ca,demo-dyn-drv}.hs`,
  `example/{A,B,C,D,Main,X}.hs`, `example/X.hs-boot`, `dep/{nix,hnix-store,nixpkgs}/github.json`.
- Read in the Nix clone at `1ed54a0fd62da96d4f5e9c806555861e46f65341` (via `git show`):
  `src/nix/derivation-add.md`, `src/libexpr/primops.cc` (`prim_outputOf`) and
  `tests/functional/dyn-drv/build-built-drv.sh`; the README's `nix.dev` link names a page absent from
  that tree, so no claim here rests on it.
- Background: [concepts][] (grid placement, early cutoff), [nix-thesis][] (derivations, the store),
  [nix-ninja][] and [nixception][] (the same move for other seams), [à la carte][a-la-carte] (deep
  constructive traces), [content-addressing][], [nix-flakes][] for the workspace side.

<!-- References -->

[repo]: https://github.com/obsidiansystems/sandstone
[readme]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/README.md
[changelog]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/CHANGELOG.md
[cabal]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/sandstone.cabal
[cabal-project]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/cabal.project
[default-nix]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/default.nix
[release-nix]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/release.nix
[write-drv]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src/Sandstone/WriteDerivation.hs
[nixcli]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src/Sandstone/NixCLI.hs
[parse-hs]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src/Sandstone/GhcMakefile/Parse.hs
[graph-hs]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src/Sandstone/GhcMakefile/Graph.hs
[demo-ca]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src-bin/demo-ca.hs
[demo-dyn]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/src-bin/demo-dyn-drv.hs
[example-boot]: https://github.com/obsidiansystems/sandstone/blob/d37daed607bba504be05f732b21b9a03a8f012a3/example/X.hs-boot
[nix-primops]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libexpr/primops.cc
[nix-dyn-test]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/tests/functional/dyn-drv/build-built-drv.sh
[nix-deriv-add]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/nix/derivation-add.md
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[nix-thesis]: ./nix-thesis.md
[nix-ninja]: ./nix-ninja.md
[nixception]: ./nixception.md
[content-addressing]: ../content-addressing/index.md
[nix-flakes]: ../monorepo-tooling/nix-flakes/
