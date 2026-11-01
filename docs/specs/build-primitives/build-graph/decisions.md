---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. The owner accepted all of them on 2026-11-01, in a design interview
held to rework the `apps/ci` task DAG.

## D1: Own the build instead of isolating dub

**Question.** Concurrent dub builds race, and a dub build cannot reuse another
directory's compiled dependencies. Do we isolate each task, or replace the part
of dub that decides what to build?

**Alternatives.**

- A private `DUB_HOME` and build root per task. Safe, but every dependent
  recompiles its whole dependency closure.
- A prepared, read-only dependency snapshot shared by isolated tasks.
- Resolve recipes ourselves and run the compiler directly.

**Choice.** Resolve recipes ourselves. Recipes stay dub recipes, and dub
remains usable for people, editors and `dmd-lsp`.

**Revisit when** dub gains path-independent build identities and
content-based staleness.

## D2: One graph, two backends

**Choice.** The same action graph runs locally against a shared
content-addressed store, or lowers to Nix derivations. The local backend comes
first, because its keys define what each derivation contains.

**Alternatives rejected.**

- A local backend only: remote builders would need a protocol of our own.
- A Nix backend only: store copies and per-derivation latency on every edit.

## D3: Settings come from our resolver, checked against dub

**Choice.** Interpret `dub.sdl` through `sparkles.wired.sdl`, with
`dub describe`, and dub used as a library, as differential oracles.

**Alternative rejected.** Taking settings from `dub describe` at build time. It
keeps dub's resolver latency and its defects in the build path.

## D4: One compile unit per package variant, with a read manifest

**Choice.** One compiler invocation per variant, as dub does, with `-makedeps`
recording the files it read.

**Alternative.** A per-module mode: finer reuse, but fragile under D's
template-instantiation and `-allinst` rules. It may be added later as a variant
option.

## D5: Two-step keys

**Choice.** A declared key leads to a manifest of the files read, and the
manifest leads to the result key, as in ccache's direct mode.

**Alternative rejected.** Keying on whole dependency packages. Any edit in
`sparkles:base` would then rebuild every dependent.

## D6: SHA-256 and the store location

**Choice.**

- **Digest:** SHA-256, so keys compare directly with Nix's hashes. BLAKE3 may
  later sit behind the same digest type.
- **Store:** `$XDG_CACHE_HOME/sparkles/build`, shared by every worktree.
- **Publication:** atomic.
- **Eviction:** size-bounded LRU.

## D7: Test results are reused only when their inputs are known

**Choice.** A test result is reused only after a run in the Nix sandbox, or
when the test declares its runtime inputs. Otherwise every request runs it.

## D8: Generators are typed nodes

**Choice.** `preGenerateCommands` entries map to typed generator actions. An
unknown command is an error, and staleness flags are dropped.

## D9: Nix derivations without evaluation

**Choice.** Sources enter the store through `nix store add`, as file sets the
build graph computes itself. Derivations are created with
`nix derivation add`, content-addressed where enabled.

**Later.** Evaluating a description of the whole CI pipeline in-process
through `sparkles:nix`, with our own `lib.fileset` primops, is a separate,
later use. It needs a primop wrapper the binding lacks.

## D10: The unittest layout rule

**Question.** Shared dependency libraries are compiled without `-unittest`,
while their test-root consumers import them with `version (unittest)` on. Is
that safe?

**Choice.** Only if no non-`sourceLibrary` package changes an aggregate's
layout under `version (unittest)`. The rule is enforced by a planning lint, and
the repository's existing violations are fixed in the same delivery:
`supervise.Run` and `sampling.TreeSampler` in `sparkles:event-horizon`.

## D11: Toolchain identity off Nix

**Choice.** A store toolchain is identified by its store paths. A host
toolchain is identified by the digests of its compiler, configuration, runtime
libraries and linker, cached by file identity.

## Open questions

- **O1:** which resolved fields `dub describe` cannot show. E0 spike 3
  resolves it, and it blocks oracle 1's completeness.
- **O2:** whether LDC removes every worktree path. E0 spike 1 resolves it, and
  it blocks cross-worktree reuse for the affected variants.
- **O3:** whether DMD variants share across worktrees at all. They do only if
  relative paths alone suffice; E0 spike 1 covers DMD too.
