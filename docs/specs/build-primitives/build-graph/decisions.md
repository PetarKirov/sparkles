---
status: draft
owner: sparkles:build-primitives
reviewed: 2026-11-01
---

# Build graph — Decisions

Each record states its question, the alternatives, the choice and when to
revisit it. Records marked **accepted** were accepted by the owner on
2026-11-01, in a design interview to rework the `apps/ci` task DAG. Records
marked **proposed** await the owner's decision.

## D1: Own the build instead of isolating dub (accepted)

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

**Revisit when** dub gains path-independent build identities and content-based
staleness.

## D2: One graph, two backends (accepted)

**Question.** Who executes an action?

**Alternatives.**

- The local executor only, against our own store. Remote builders would then
  need a protocol of our own.
- Nix only: store copies and per-derivation latency on every edit.
- One graph lowered to either.

**Choice.** One graph, two backends, the local one first, because its keys
define what each derivation contains.

**Revisit when** the Nix backend's per-action overhead is measured below the
local backend's on the edit loop.

## D3: Settings from our resolver, checked against dub (accepted)

**Question.** Where do resolved build settings come from?

**Alternatives.**

- `dub describe` at build time: keeps dub's latency and defects in the build
  path.
- Our resolver alone: drifts without a check.
- Our resolver, with dub as a differential oracle.

**Choice.** Our resolver, through `sparkles.wired.sdl`. `dub describe` and dub
used as a library are the oracles.

**Revisit when** the oracle has had no disagreement for a release and dub's
pinned version is frozen.

## D4: One compile unit per package variant, with a read manifest (accepted)

**Question.** What is a compile unit?

**Alternatives.**

- One per package variant, as dub does.
- One per D module: finer reuse, but fragile under D's template-instantiation
  and `-allinst` rules, and more total work.

**Choice.** One compiler invocation per variant, with its dependency output
recording what it read.

**Revisit when** a per-module mode is measured to win on the edit loop. It
would then be added as a variant option.

## D5: Two-step keys with several manifests per declared key (accepted)

**Question.** How do keys reflect inputs that are known only after compiling?

**Alternatives.**

- Keying on whole dependency packages: any edit in `sparkles:base` rebuilds
  every dependent.
- One manifest per declared key: worktrees on different revisions evict each
  other's manifests.
- ccache's direct mode, with a bounded list of manifests per declared key.

**Choice.** The direct mode: a declared key, then a list of manifests, then
result keys.

**Revisit when** profiling shows the manifest checks dominate lookup time.

## D6: SHA-256 and the store location (accepted)

**Question.** Which digest, and where does the store live?

**Alternatives.** BLAKE3, which is faster but needs a binding; SHA-256; a store
per worktree; one per machine.

**Choice.**

- **Digest:** SHA-256 for file contents and keys. Nix's flat and recursive
  content addressing is computed from the same SHA-256, which keeps the Nix
  backend's source inputs cheap to derive. Store-path names and action keys
  are not comparable, and need not be.
- **Store:** one per user and machine, at `$XDG_CACHE_HOME/sparkles/build`.
- **Publication:** atomic.
- **Eviction:** size-bounded LRU.

**Revisit when** hashing shows up in profiles. BLAKE3 can then sit behind the
same digest type.

## D7: Test results are reused only when their inputs are known (accepted)

**Question.** May a passing test be skipped because an identical binary passed
before?

**Alternatives.** Never; by default; on request.

**Choice.** Only when it ran in the Nix sandbox, with the kernel, CPU and system
in its key, or when it declares every runtime input. Otherwise every request
runs it.

**Revisit when** tests declare their runtime inputs throughout the repository.

## D8: Generators are typed nodes (accepted)

**Question.** How do `preGenerateCommands` run?

**Alternatives.** Run the command string as dub does; model it as a typed
action.

**Choice.** A typed generator action:

- An unknown command is an error.
- Staleness flags are dropped.
- The generator's output directory replaces the recipe's in-tree output path.
  This is an intentional divergence from dub, which reads the in-tree
  directory.

**Revisit when** a generator cannot declare its outputs.

## D9: Nix derivations without evaluation (accepted)

**Question.** How does the Nix backend create derivations?

**Alternatives.**

- Generated Nix expressions, evaluated on every build.
- In-process evaluation through `sparkles:nix`, with our own `lib.fileset`
  primops.
- Derivations created directly.

**Choice.** Sources enter the store as file sets the build graph computes
itself. Derivations are created with `nix derivation add`, content-addressed
where enabled.

**Later.** Evaluating a description of the whole CI pipeline in-process through
`sparkles:nix` is a separate use. It needs a primop wrapper the binding lacks.

## D10: The unittest layout rule (accepted)

**Question.** Dependency libraries are compiled without `-unittest`, while the
test roots that consume them import their modules with `version (unittest)`
on. Is that safe?

**Choice.** Only if no declaration's presence, layout or meaning in a dependency
library changes under `version (unittest)`. A semantic planning lint enforces
this. The repository's known violations, in `supervise.Run` and
`sampling.TreeSampler`, are fixed.

**Revisit when** D gains a way to compile a library's test-only declarations
out of its importers.

## D11: Toolchain identity off Nix (accepted)

**Choice.** A store toolchain is identified by its store-path closure, wrapper
scripts included. A host toolchain is identified by the digests of its compiler,
configuration, runtime, C driver, libc and linker, cached by file identity.

## D12: Complete dependency output in the LDC fork (accepted)

**Question.** LDC's `--makedeps` lists string imports, but not the headers its C
preprocessor reads, nor the import candidates it probed and found absent. How
does the manifest become complete?

**Alternatives.**

- Run the C preprocessor's dependency pass separately, and accept missing
  negative inputs.
- Key conservatively on whole import roots.
- Extend the compiler.

**Choice.** Extend our LDC fork:

- C headers in `--makedeps`;
- an opt-in output of absent candidates;
- coverage registration that honours the prefix map.

The owner directs that the fork may be changed freely to advance reproducible
incremental builds. A compiler without these extensions falls back to BGK6's
conservative key.

**Revisit when** the extensions are upstreamed, or a rebase of the fork drops
them.

## D13: Prune downward-inherited versions (proposed)

**Question.** dub passes a root's versions down to every dependency, so a root
with a configuration-local version forks its whole dependency closure. How
much of that does a variant key keep?

**Alternatives.**

- **Faithful:** keep every inherited version in the key; little sharing.
- **Diverge:** never pass configuration-level versions down, and lint against
  dependencies that test them.
- **Pruned faithful:** keep an inherited version only where a compiled or
  imported source mentions it.

**Choice.** Pruned faithful. Separately, the repository moves `-checkaction=context`
from each `configuration "unittest"` into the managed `unittest` build type, so
the flag is uniform and forks nothing.

**Revisit when** a version is found that affects code without being named in a
`version` or `debug` condition, for example through a string mixin.

## D14: Relocation maps the root to `.` (proposed)

**Question.** How do outputs avoid naming their worktree, given that 53 uses of
`__FILE_FULL_PATH__` open fixtures at run time?

**Alternatives.**

- Map the root to `.`, run test actions in their worktree's root, and make
  `sparkles.base.source_uri` handle relative paths.
- Map debug information only, and key test roots on their worktree.

**Choice.** Map to `.`. It is the only choice under which a test root built in
one worktree runs correctly in another. The E0 relocation spike checks all
uses.

## D15: No hidden source edges (proposed)

**Question.** `libs/ui`, `libs/tui` and `libs/wsi` compile or import other
packages' sources through `importPaths`/`sourcePaths` without a `dependency`.
So selection misses them, and the build graph cannot share those packages'
variants.

**Alternatives.** Derive package edges from such paths; forbid them with a
lint; both.

**Choice.** Forbid them, with BGR8. The recipes gain real dependencies. The
cycle-safe test-runner integration remains the declared exception.

## Open questions

- **O1:** which resolved fields `dub describe` cannot show. E0 spike 3 resolves
  it. It blocks oracle 1's completeness.
- **O2:** whether LDC removes every worktree path. E0 spike 1 resolves it. It
  blocks cross-worktree reuse for the affected variants.
- **O3:** whether DMD variants share across worktrees at all. They do only if
  relative paths alone suffice; E0 spike 1 covers DMD too.
