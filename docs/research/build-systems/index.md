# Build Systems

A breadth-first survey of **build-system engines** — how they schedule tasks,
decide what is dirty, discover dependencies, store and share outputs, sandbox
actions, and distribute work — across the academic literature, twenty industry
rows (sixteen grid engines, one deliberately off-grid system, and three that are
not engines at all), and the Nix ecosystem's experiment with making the build
graph itself dynamic. Fourteen synthesis pages then re-cut the same evidence
along the axes a build-engine designer actually faces: sandbox overhead,
traced dependencies, semantic caching, daemon compilers, CAS eviction,
reproducibility, and cryptographic provenance. The survey informs the
Sparkles task-DAG work in `sparkles:build-primitives` and any future `dub`
build engine.

This is the master index for the build-systems research tree. Each row links
to a deep-dive written against the system's own source tree at a pinned
commit, or the paper's own text; where this index summarizes a system, the
deep-dive is the source of truth. The sibling
[Monorepo & Workspace Tooling][monorepo-index] survey covers thirteen of the
same tools from the workspace/orchestration side; this tree covers their
engines and cross-links rather than repeating that treatment.

This survey answers six questions:

1. **Vocabulary** — what is a scheduler, a rebuilder, a verifying or
   constructive trace, early cutoff, a shallow build? See [concepts].
2. **What the theory says** — which scheduler × rebuilder combinations are
   correct, minimal, cloud-capable, or uninhabited, and what changes when
   dependencies are dynamic? See the Foundations rows below.
3. **How twenty industry rows answer the six spine dimensions** — task model,
   rebuilding, discovery, store, hermeticity, distribution. Three of the rows
   are not engines: GN and Meson generate a Ninja graph, and Boba is an in-tree
   Bazel integration with no standalone repository. See the
   [master catalog](#master-catalog) and its [taxonomies](#taxonomy).
4. **What Nix changes when the graph is a value** — derivations, dynamic
   derivations, and the projects rebuilding Ninja-shaped graphs inside the
   store. See the Nix rows below.
5. **Where the field's open problems sit** — the fourteen theme pages.
6. **What Sparkles should borrow** — the `Sparkles relevance` subsection of
   each deep-dive, gathered in the [comparison][comparison] (the capstone).

> [!NOTE]
> **All waves are complete and reviewed.** The wave plan lives in `PLAN.md`,
> which is excluded from the site build; every row below links a page that
> exists, as its **Status** column records. The [comparison][comparison] is the
> capstone: it re-cuts this evidence into the scheduler × rebuilder grid, the
> consensus standard, the trade-offs, and the delta against the Sparkles task
> DAG. Dates marked `~` are approximate.

**Last reviewed:** November 3, 2026

---

## Master Catalog

**Scheduler** and **Rebuilder** use the [concepts] vocabulary
(`topological`/`restarting`/`suspending` × dirty-bit/verifying/constructive
traces); `—` means the deep-dive declines to classify the system. **Link**
points at the deep-dive; the [taxonomies](#taxonomy) below group these rows by
one axis at a time.

### Foundations (academic literature)

| Subject                             | Venue / year        | One line                                                                              | Status     | Link                                         |
| ----------------------------------- | ------------------- | ------------------------------------------------------------------------------------- | ---------- | -------------------------------------------- |
| Build Systems à la Carte            | ICFP 2018; JFP 2020 | The scheduler × rebuilder design space this catalog is organized by                   | `reviewed` | [à la carte][a-la-carte]                     |
| PIE (Konat et al.)                  | ASE 2018            | Scalable incremental building with dynamic task dependencies                          | `reviewed` | [PIE][pie]                                   |
| Build maintenance (McIntosh et al.) | EMSE 2015           | Large-scale empirics of build-technology choice vs maintenance cost (author preprint) | `reviewed` | [build maintenance][build-maintenance]       |
| Perfect Dependencies (Spall et al.) | OOPSLA 2020         | Speculative script execution with hazard checking (Rattle)                            | `reviewed` | [perfect dependencies][perfect-dependencies] |
| Nix thesis + NixOS (Dolstra et al.) | 2006; JFP 2010      | The purely functional deployment model underneath the Nix store                       | `reviewed` | [Nix thesis][nix-thesis]                     |

### Engines and executors (industry)

| System         | Scheduler                 | Rebuilder                                 | Status                                                                 | Link                 |
| -------------- | ------------------------- | ----------------------------------------- | ---------------------------------------------------------------------- | -------------------- |
| BuildXL        | topological               | verifying traces                          | `reviewed`                                                             | [BuildXL][buildxl]   |
| Bazel          | restarting                | constructive traces                       | `reviewed` (+ [monorepo Bazel][mono-bazel])                            | [Bazel][bazel]       |
| Buck2          | suspending                | verifying traces                          | `reviewed` (+ [monorepo Buck2][mono-buck2])                            | [Buck2][buck2]       |
| build2         | topological (recursive)   | mtime dirty bit + depdb                   | `reviewed`                                                             | [build2][build2]     |
| Please         | suspending                | verifying traces                          | `reviewed` (+ [monorepo Please][mono-please])                          | [Please][please]     |
| Ninja          | topological               | verifying traces (qualified)              | `reviewed` (+ [monorepo Ninja][mono-ninja])                            | [Ninja][ninja]       |
| GNU Make       | topological               | dirty bit                                 | `reviewed` (+ [monorepo Make][mono-make])                              | [GNU Make][gnumake]  |
| redo           | suspending                | verifying step traces                     | `reviewed` (+ [monorepo redo][mono-redo])                              | [redo][redo]         |
| tup            | topological               | dirty bit (observed)                      | `reviewed` (+ [monorepo tup][mono-tup])                                | [tup][tup]           |
| Shake          | suspending                | verifying step traces                     | `reviewed`                                                             | [Shake][shake]       |
| Rattle         | speculative (off-grid)    | constructive in spirit                    | `reviewed`                                                             | [Rattle][rattle]     |
| Earthly        | static DAG (via BuildKit) | constructive traces + auto-skip           | `reviewed` (+ [monorepo Earthly][mono-earthly])                        | [Earthly][earthly]   |
| GN             | not a cell (generator)    | —                                         | `reviewed` (+ [monorepo GN][mono-gn])                                  | [GN][gn]             |
| Meson          | not a cell (generator)    | —                                         | `reviewed` (+ [monorepo Meson][mono-meson])                            | [Meson][meson]       |
| Boba (Fuchsia) | —                         | —                                         | `reviewed` (short page: no standalone repo; in-tree at `build/bazel/`) | [Boba][boba]         |
| Pants v2       | suspending                | verifying step traces                     | `reviewed` (+ [monorepo Pants][mono-pants])                            | [Pants][pants]       |
| Moon           | topological               | constructive (action cache)               | `reviewed` (+ [monorepo moon][mono-moon])                              | [moon][moon]         |
| BitBake        | topological               | signature-stamp dirty bit + sigdata trace | `reviewed`                                                             | [BitBake][bitbake]   |
| sbt            | topological + suspension  | per-invocation dirty bit + action cache   | `reviewed` (+ [monorepo sbt][mono-sbt])                                | [sbt][sbt]           |
| BuildKit       | topological               | constructive traces                       | `reviewed`                                                             | [BuildKit][buildkit] |

### Nix ecosystem

| Subject                 | One line                                                                                   | Status     | Link                                           |
| ----------------------- | ------------------------------------------------------------------------------------------ | ---------- | ---------------------------------------------- |
| nixception              | REAPI actions bridged into `recursive-nix` derivations, deduplicated by the store          | `reviewed` | [nixception][nixception]                       |
| nix-ninja               | Ninja graphs translated edge-by-edge into content-addressed derivations                    | `reviewed` | [nix-ninja][nix-ninja]                         |
| sandstone               | Per-module Haskell derivations emitted by a build (object/interface split)                 | `reviewed` | [sandstone][sandstone]                         |
| drowse                  | `nix-instantiate` + `crate2nix` as build steps emitting derivations                        | `reviewed` | [drowse][drowse]                               |
| dgd                     | Go builds planned from the compiler's dry run via dynamic derivations                      | `reviewed` | [dgd][dgd]                                     |
| nixgg                   | `gcc`/`g++` invocations intercepted into per-invocation derivations                        | `reviewed` | [nixgg][nixgg]                                 |
| nix-cargo-unit          | Cargo unit graph rendered as per-unit Nix derivations                                      | `reviewed` | [nix-cargo-unit][nix-cargo-unit]               |
| MakeNix                 | A `Makefile` expanded into one derivation per object file, mid-build                       | `reviewed` | [MakeNix][makenix]                             |
| Nix dynamic derivations | Zakaria's four posts + RFC 92 + the `NixOS/nix` sources: derivations producing derivations | `reviewed` | [dynamic derivations][nix-dynamic-derivations] |

### Themes (synthesis)

Each page synthesizes across the deep-dives above plus its own primary
sources; claims derived rather than directly sourced are marked
**Catalog inference** on the page itself.

| Theme page                                            | Question it answers                                                                           | Status     |
| ----------------------------------------------------- | --------------------------------------------------------------------------------------------- | ---------- |
| [Sandboxing overheads][sandboxing-overheads]          | What do `ptrace`/`seccomp`, FUSE, namespaces, Landlock, and eBPF cost, and what do they miss? | `reviewed` |
| [Dynamic deps, distributed][dynamic-deps-distributed] | Can dynamically discovered dependencies survive remote execution correctly?                   | `reviewed` |
| [Dependency pruning][dependency-pruning]              | How are strict-deps violations and unused edges found and removed?                            | `reviewed` |
| [Graph auto-generation][graph-autogeneration]         | Can correct build definitions be synthesized from observed execution?                         | `reviewed` |
| [Semantic caching][semantic-caching]                  | When can a cache key ignore bytes — interface hashing and its risks?                          | `reviewed` |
| [Daemon compilers][daemon-compilers]                  | What do long-lived compilers keep in memory, and what must hit disk?                          | `reviewed` |
| [Link-time pruning][link-time-pruning]                | How do mold/`lld`, `--gc-sections`, ICF, and ThinLTO interact with the DAG?                   | `reviewed` |
| [Compile-time execution][compile-time-execution]      | Where do macros, CTFE, and `build.rs` sit relative to the sandbox?                            | `reviewed` |
| [CAS eviction][cas-eviction]                          | What should a content-addressed cache keep, and in what order does it discard?                | `reviewed` |
| [Cross-language DAGs][cross-language-dags]            | What unifies protobuf, FFI, and toolchain transitions in one graph?                           | `reviewed` |
| [Speculative execution][speculative-execution]        | What is shipped speculation (Rattle, dynamic execution) vs literature?                        | `reviewed` |
| [Formal verification][formal-verification]            | What has actually been mechanized about build correctness?                                    | `reviewed` |
| [Reproducibility][reproducibility]                    | Which nondeterminism sources remain, and which tools detect them?                             | `reviewed` |
| [Provenance][provenance]                              | What do engines emit for SLSA/in-toto today — and who signs it?                               | `reviewed` |

---

## Taxonomy

Three re-cuts of the same twenty industry rows, one axis each. The five
foundations are papers _about_ the grid rather than rows in it, and the nine Nix
projects are satellites that add no scheduler or rebuilder of their own
([comparison] §1.2), so neither group is re-cut here. Every placement, and every
qualifier beside it, is the linked page's own classification, stated in its
`Analysis spine` (or its numbered `Task model & scheduling`,
`Rebuilding & correctness`, `Dependency discovery`) sections; the vocabulary is
[concepts] §2–§5. Where a page declines to classify, the qualifier says so
instead of forcing the row into a bucket.

### By scheduler

_Does the engine order a graph it already knows, restart work it could not
finish, or suspend a caller until a late dependency arrives?_

| Scheduler           | What the pages say                                                                   | Systems                                                                                                                                                                                                                       |
| ------------------- | ------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Topological**     | A complete graph, then a ready set, a walk, or dataflow over the edges               | [BuildXL][buildxl], [build2][build2], [Ninja][ninja], [GNU Make][gnumake], [tup][tup], [Moon][moon], [BitBake][bitbake], [Earthly][earthly] (dataflow), [BuildKit][buildkit] (demand-driven dataflow, not a topological sort) |
| **Restarting**      | A function that cannot get a dependency returns, is re-invoked, and repeats its work | [Bazel][bazel], [Boba][boba] (the Bazel half only; the GN/Ninja half is topological)                                                                                                                                          |
| **Suspending**      | A caller blocks and resumes when the dependency arrives; no work is repeated         | [Buck2][buck2], [Please][please], [redo][redo], [Shake][shake], [Pants][pants], [sbt][sbt] (topological `Execute` plus `Left(target)` suspension)                                                                             |
| **Off-grid**        | No key, target or `fetch`; the author's order weakened by speculation                | [Rattle][rattle]                                                                                                                                                                                                              |
| **Not a scheduler** | Builds a description, then exits                                                     | [GN][gn] (task-description compiler), [Meson][meson] (never schedules)                                                                                                                                                        |

Nine topological, two restarting, six suspending, one off-grid, two not
schedulers: twenty rows. The qualifiers that keep a composite off its cell — the
missing second half of Boba, BuildKit's dataflow, sbt's suspension — are argued
on the linked pages.

### By rebuilder

_What does the engine consult to decide a key is current, and what does it keep
for next time?_

| Rebuilder               | What the pages say                                                | Systems                                                                                                                                                                                                                                                                                                                   |
| ----------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Dirty bit**           | One bit or one `mtime` per key; no early cutoff of its own        | [GNU Make][gnumake], [tup][tup] (the read set is the trace), [sbt][sbt] ("no memo yet", once per invocation)                                                                                                                                                                                                              |
| **Verifying traces**    | Recorded dependencies are re-checked; outputs stay where they are | [BuildXL][buildxl], [Buck2][buck2], [build2][build2] (an `mtime` dirty bit refined by `depdb` — its nearest cell), [Please][please], [Ninja][ninja] (command hash; inputs by `mtime`), [redo][redo], [Shake][shake], [Pants][pants], [BitBake][bitbake] (nearest cell; currency is stamp existence, sigdata is the trace) |
| **Constructive traces** | The key maps to a reusable result or snapshot                     | [Bazel][bazel] (constructive in memory, verifying locally), [Boba][boba], [Earthly][earthly] (`--auto-skip`, "a dirty bit in all but name"), [Rattle][rattle] (constructive in spirit), [Moon][moon] (one key; no content early cutoff), [BuildKit][buildkit] (the value is a snapshot)                                   |
| **None (generator)**    | No rebuild decision for build outputs                             | [GN][gn] (only its own regeneration is a dirty bit), [Meson][meson] (delegates to Ninja; the delegated trace "holds no hashes")                                                                                                                                                                                           |

Three dirty-bit systems, nine verifying-trace systems, six constructive-trace
systems, two generators: twenty rows. Composites are placed by the mechanism each
page says decides correctness; sbt's action cache and Earthly's `--auto-skip`
are noted, not promoted to a bucket. Both generators delegate rebuilding to
Ninja, whose cell they inherit in practice without occupying it.

### By dependency discovery

_Where does the edge set come from: the description, the tool's own report, or
observation?_

| Discovery    | What the pages say                                               | Systems                                                                                                                                                                                                                                                            |
| ------------ | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Declared** | The description names inputs and outputs; nothing observes reads | [Bazel][bazel] (two narrow exceptions), [Buck2][buck2], [Please][please], [GNU Make][gnumake], [redo][redo] (at runtime, by the script), [Shake][shake] (by execution), [GN][gn], [Moon][moon], [sbt][sbt], [BuildKit][buildkit], [Earthly][earthly], [Boba][boba] |
| **Inferred** | The engine parses the tool's own output or the source text       | [Ninja][ninja] (`depfile`/`.ninja_deps`, `dyndep`), [build2][build2] (the preprocessed include list), [Meson][meson] (depfile, then `dyndep`), [Pants][pants] (source parsing)                                                                                     |
| **Traced**   | Reads are observed at the syscall boundary and become the graph  | [Rattle][rattle]                                                                                                                                                                                                                                                   |
| **Hybrid**   | Declarations are checked or extended by observation              | [BuildXL][buildxl], [tup][tup], [BitBake][bitbake] (`[file-checksums]` plus the code parser)                                                                                                                                                                       |

Twelve declared, four inferred, one traced, three hybrid: twenty rows.

**Catalog inference:** the four buckets are this catalog's, not the pages':
`compiler-emitted` and `source-parsed` both sit under _inferred_, and _hybrid_
keeps [comparison] §2.3's sense — declarations plus observation — rather than
"any two mechanisms". Two declared rows carry a stated exception: GN records its
own parser's reads, and Earthly expands `COPY` patterns statically. Both stay in
the declared row, noted rather than promoted.

---

## Milestones

When a capability landed, in the words and dates of the deep-dives and papers
on disk. A release date, a paper's venue year, and a document's own date are
each recorded as the page states them; nothing here is inferred from a version
number.

| Date       | Capability milestone                                                                                                                                                                           | Stated in                                          |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------- |
| 2004–2006  | **KDE** moves from Autotools to CMake: the CMake build exists experimentally from late 2004, and the switchover is "the steep slope upwards in CMake and downwards in Autotools in early 2006" | [Build maintenance][build-maintenance]             |
| 2006-01-18 | **Nix** — _The Purely Functional Software Deployment Model_ defended: derivations, the store, and deep constructive traces                                                                     | [Nix thesis][nix-thesis]                           |
| 2010       | **NixOS** — the same model at distribution scale; a 1,036-derivation system graph measured in May 2010                                                                                         | [Nix thesis][nix-thesis]                           |
| 2014       | **CloudMake** (FM 2014) — the earliest verified artifact from a deployed industrial build system, in Dafny                                                                                     | [Formal verification][formal-verification]         |
| 2015       | **Build maintenance** (EMSE 20(6)) — build-technology choice measured against maintenance cost                                                                                                 | [Build maintenance][build-maintenance]             |
| 2015       | **Pluto** (OOPSLA 2015) — the build algorithm PIE implements                                                                                                                                   | [PIE][pie]                                         |
| 2016       | **BuildXL**'s stated motive: an Office-client fork took about 90 hours to build and release to dogfood                                                                                         | [BuildXL][buildxl]                                 |
| 2017-06-28 | **Bazel** `unused_deps` — strict deps introduced so unused edges can be removed                                                                                                                | [Dependency pruning][dependency-pruning]           |
| 2018       | **Build Systems à la Carte** (ICFP 2018) — the scheduler × rebuilder grid this catalog is organized by                                                                                         | [À la carte][a-la-carte]                           |
| 2018       | **PIE** (ASE 2018) — scalable incremental building with dynamic task dependencies (`reqTasks`)                                                                                                 | [PIE][pie]                                         |
| 2019       | **À la carte → Coq** (CoqPL 2019) — the Haskell abstractions translated to Coq, reported as work in progress                                                                                   | [Formal verification][formal-verification]         |
| 2019-02-01 | **Nix RFC 92** — dynamic derivations proposed                                                                                                                                                  | [Nix dynamic derivations][nix-dynamic-derivations] |
| 2019-04-17 | **Rattle 0.1** — the forward, traced model shipped as a tool; `0.2` follows on 2020-05-27                                                                                                      | [Rattle][rattle]                                   |
| 2020       | **À la carte** (JFP 30, e11) — the journal version whose vocabulary every page follows                                                                                                         | [Concepts][concepts]                               |
| 2020       | **Perfect Dependencies** (OOPSLA 2020) — traced dependencies with hazard checking, at 7% Linux / 46% Windows overhead                                                                          | [Perfect dependencies][perfect-dependencies]       |
| 2022       | **Rattle in Agda** — mechanised memoization, hazard checks and speculative reordering                                                                                                          | [Formal verification][formal-verification]         |
| 2022       | **Forward Build Systems, Formally** (CPP 2022) — the forward model proved, not only tested                                                                                                     | [Speculative execution][speculative-execution]     |
| 2022-08-29 | **Fuchsia RFC-0186** reviewed — Bazel adopted (Boba); GN/Ninja stays the outer build during the migration                                                                                      | [Boba][boba]                                       |
| 2022–2026  | **Rust `tracked_env`** tracked since 2022 but still unstable in 2026, so a macro's env and file reads stay outside `rustc`'s dep-info                                                          | [Compile-time execution][compile-time-execution]   |
| 2023-09-20 | **Nix 2.18** ships `builtins.outputOf` — the first shipped surface for dynamic derivations                                                                                                     | [Nix dynamic derivations][nix-dynamic-derivations] |
| 2024–25    | **Nix language in Rocq** — Mininix/NixLang semantics mechanised, as an interpreter rather than a build engine                                                                                  | [Formal verification][formal-verification]         |
| 2025-03-11 | **MakeNix** post published — a `Makefile` expanded into per-object derivations mid-build (clone dated 2025-03-12)                                                                              | [MakeNix][makenix]                                 |
| 2025-07-16 | **Earthly** `v0.8.16`, the final release; Cloud and Satellites shut down the same day                                                                                                          | [Earthly][earthly]                                 |
| 2026-01-19 | **Shake 0.19.9** — the `built`/`changed` verifying trace current at review time                                                                                                                | [Shake][shake]                                     |
| 2026-08-10 | **Meson 1.12.0** — `CACHEDIR.TAG` written on setup _and_ regenerate, treating the build directory as a cache                                                                                   | [Meson][meson]                                     |
| 2026-09-13 | **nixception 0.6.1** — REAPI actions bridged into `recursive-nix` derivations                                                                                                                  | [nixception][nixception]                           |
| ~2027      | **mold** — _A Massively Parallel Linker_ (ASPLOS 2027, a preprint at review time): the linker as the build graph's coarsest task                                                               | [Link-time pruning][link-time-pruning]             |

> [!NOTE]
> `~` marks the one row whose venue has not been held — the mold paper's ASPLOS
> 2027 — and `2022–2026` is an interval the compile-time page states as still
> open. Everything else is a date the cited page prints: a release (`2025-07-16`,
> `2026-01-19`, `2026-08-10`, `2026-09-13`), a venue year, or a document date
> (`2019-02-01`, `2022-08-29`, `2025-03-11`). The tree's own `**Last reviewed:**`
> dates are review dates, not capability dates, and are omitted.

---

## Quick navigation

Five reading paths; each ends at the page where the decision is made.

- **"Give me the vocabulary first."** [Concepts][concepts] §2–§5 → [comparison]
  Part 1 (the grid, and the rows that refuse a cell) → one engine at each end of
  the spectrum: [Shake][shake] (suspending, `built`/`changed`) and [Ninja][ninja]
  (topological, `restat`).
- **"I'm designing the Sparkles task DAG."** [comparison] Part 5 — the delta
  table, row by row — → [Shake][shake] and [BitBake][bitbake] for the cheapest
  rebuilder forms → [Ninja][ninja] (`restat`, `dyndep`, depfiles) for a plan
  that stays static → [BuildXL][buildxl] for declaration versus observation →
  [CAS eviction][cas-eviction] and [provenance] for the two capabilities the
  delta marks absent.
- **"I want the theory, not the tools."** [À la carte][a-la-carte] →
  [concepts] → [PIE][pie] (dynamic dependencies) →
  [Perfect dependencies][perfect-dependencies] (traced dependencies and the
  hazard set) → [Formal verification][formal-verification] (what is actually
  mechanised).
- **"I care about dynamic dependencies and remote execution."**
  [Nix dynamic derivations][nix-dynamic-derivations] →
  [Dynamic deps, distributed][dynamic-deps-distributed] →
  [nix-ninja][nix-ninja] and [dgd][dgd] for the plan-as-artifact pattern →
  [BuildKit][buildkit] (REAPI at the seam).
- **"I want the small, one-shot end."** [GNU Make][gnumake] → [redo][redo] →
  [tup][tup] → [Ninja][ninja] → [comparison] Part 3 (the consensus) and Part 6
  (what it does not settle).

The synthesis pair: **[Concepts][concepts]** defines the vocabulary once;
**[comparison]** is the capstone — the master grid, the six spine dimensions,
the consensus standard, the trade-offs, and the Sparkles delta.

---

## Sources

Primary sources are cloned under `$REPOS/build-systems-research/src/` (33
symlinks to canonical clones, each pinned by 40-char SHA in that tree's
`MANIFEST.md`) and `$REPOS/papers/build-systems/` (7 PDFs with SHA256s in its
`MANIFEST.md`, including one author preprint). Each deep-dive cites the
exact files it opened.

<!-- References -->

[concepts]: ./concepts.md
[comparison]: ./comparison.md
[a-la-carte]: ./a-la-carte.md
[pie]: ./pie.md
[build-maintenance]: ./build-maintenance.md
[perfect-dependencies]: ./perfect-dependencies.md
[nix-thesis]: ./nix-thesis.md
[buildxl]: ./buildxl.md
[build2]: ./build2.md
[shake]: ./shake.md
[rattle]: ./rattle.md
[bitbake]: ./bitbake.md
[buildkit]: ./buildkit.md
[boba]: ./boba.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[please]: ./please.md
[ninja]: ./ninja.md
[gnumake]: ./gnumake.md
[redo]: ./redo.md
[tup]: ./tup.md
[earthly]: ./earthly.md
[gn]: ./gn.md
[meson]: ./meson.md
[pants]: ./pants.md
[moon]: ./moon.md
[sbt]: ./sbt.md
[nixception]: ./nixception.md
[nix-ninja]: ./nix-ninja.md
[sandstone]: ./sandstone.md
[drowse]: ./drowse.md
[dgd]: ./dgd.md
[nixgg]: ./nixgg.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[makenix]: ./makenix.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[dependency-pruning]: ./dependency-pruning.md
[graph-autogeneration]: ./graph-autogeneration.md
[semantic-caching]: ./semantic-caching.md
[daemon-compilers]: ./daemon-compilers.md
[link-time-pruning]: ./link-time-pruning.md
[compile-time-execution]: ./compile-time-execution.md
[cas-eviction]: ./cas-eviction.md
[cross-language-dags]: ./cross-language-dags.md
[speculative-execution]: ./speculative-execution.md
[formal-verification]: ./formal-verification.md
[reproducibility]: ./reproducibility.md
[provenance]: ./provenance.md
[monorepo-index]: ../monorepo-tooling/index.md
[mono-bazel]: ../monorepo-tooling/bazel/
[mono-buck2]: ../monorepo-tooling/buck2/
[mono-please]: ../monorepo-tooling/please/
[mono-ninja]: ../monorepo-tooling/ninja/
[mono-make]: ../monorepo-tooling/make/
[mono-redo]: ../monorepo-tooling/redo/
[mono-tup]: ../monorepo-tooling/tup/
[mono-earthly]: ../monorepo-tooling/earthly/
[mono-gn]: ../monorepo-tooling/gn/
[mono-meson]: ../monorepo-tooling/meson/
[mono-pants]: ../monorepo-tooling/pants/
[mono-moon]: ../monorepo-tooling/moon/
[mono-sbt]: ../monorepo-tooling/sbt/
