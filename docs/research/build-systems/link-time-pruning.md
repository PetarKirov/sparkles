# Link-Time Pruning (Theme)

Linking is the build graph's coarsest task and its last: one action consumes every
object file a target needs and produces one artifact. Link-time pruning attacks what
that action _keeps_ (unreferenced sections, duplicate functions, archive members nothing
referenced, libraries nothing used) and what it must _redo_ when a single object
changes — bytes and load time on one side, the edit–compile–debug loop on the other.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                                           |
| ---------- | --------------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                         |
| Question   | What can a linker discard, what does discarding cost, and what can a build DAG observe of the decision?         |
| Mechanisms | parallel full link, lazy archive extraction, section GC, ICF, ThinLTO index/backends, partial link, link groups |
| Systems    | mold, LLVM `lld`, GNU `ld`/`ar`, MSVC `link`, ThinLTO, Bazel, Buck2, Meson/Ninja                                |
| Vocabulary | [concepts] — _early cutoff_, _trace_, _minimality_; edge pruning is [dependency-pruning]                        |

> [!NOTE]
> This page is the complement of what [dependency-pruning] excludes: pruning **inside**
> a linked artifact — sections, symbols, members, libraries — not edges between
> targets. A linker can shrink its output without changing one edge of the build
> graph, and that asymmetry is the theme.

## Overview

### What it solves

A link's input is a target's transitive object set and its output is one binary, so
its cost scales with program size rather than edit size: "Despite decades of
engineering effort, link times remain a significant bottleneck in the
edit-compile-debug cycle, particularly for large C++ programs. Existing linkers
exploit limited parallelism, leaving most CPU cores idle" ([mold-paper] abstract).

The rebuild side is worse at the artifact boundary. In a Nix/Cargo planner's words,
"link targets (bins/cdylibs) always relink when any transitive rlib changed because
rlibs aren't byte-stable under `-C incremental`" ([`src/render.rs`][cargo-unit-render],
quoted in [nix-cargo-unit] §2). Every object is an input, and early cutoff fires only if
the completed link reproduces its predecessor byte for byte.

### Design philosophy

Three commitments, in tension:

- **Make the full link fast enough that decomposition is unnecessary.** mold says
  so about the standard workaround of splitting into shared libraries: "By making
  multi-gigabyte full links complete in a few seconds, mold makes such
  link-time-driven decomposition less compelling" ([mold-paper] §10).
- **Decompose the link so a scheduler can see it.** ThinLTO turns one link into an
  index step plus one backend per module — why Buck2 lists "Distributed ThinLTO,
  where the index file says what the dependencies are" as a dynamic-dependency use
  case ([buck2-dyndeps]).
- **Cut inside the action and accept that the graph cannot see it.** `--gc-sections`
  and ICF come from the linker's own reachability analysis; no system here learns
  which symbols survived. The linker already computes a symbol-level dependency answer
  the graph does not have — and it can print that answer.

## How it works — six levers, one observer

| Lever                  | Mechanism                              | Granularity     | What the build DAG sees                     |
| ---------------------- | -------------------------------------- | --------------- | ------------------------------------------- |
| Full-link speed        | threads across every pass (mold, lld)  | intra-action    | nothing — same edge, same inputs            |
| Lazy extraction        | archives, `lld --start-lib`            | member / symbol | nothing; reportable with `--why-extract`    |
| Section GC             | `--gc-sections` mark-sweep from roots  | section         | nothing; smaller artifact                   |
| Identical code folding | ICF equivalence classes                | symbol address  | nothing; changes function identity          |
| Split link             | ThinLTO index + per-module backends    | module          | one edge becomes `1 + N`, inputs discovered |
| Partitioning           | `ld -r`, shared libraries, link groups | subtree         | a changed graph shape                       |

### 1. Parallel full link

mold parallelizes the whole pipeline, including passes linkers traditionally keep
serial (parsing, symbol resolution, archive processing): "By default, `mold` uses as
many threads as the number of cores or 32, whichever is smaller. It is capped at 32
because `mold` doesn't scale well beyond that point" ([mold-man]) — and the cap is in
the driver too, `available_parallelism().min(32)` ([`elf/driver.rs`][mold-driver]).
`lld` exposes the same knob: `--threads`, "Number of threads. '1' disables
multi-threading. By default all available hardware threads are used"
([`lld/ELF/Options.td`][lld-options]).

A link action is therefore itself a parallel region: scheduling several links
multiplies threads, not just processes. Meson carries a separate cap for it —
"`backend_max_links` can be set to limit the number of processes that ninja will use
to link" ([meson-build-options]; [meson]) — and memory scales with concurrency: "If
you execute N instances of `mold` concurrently, it could require N times the time and
N times the memory" ([mold-man], `MOLD_JOBS`). **Catalog inference:** Sparkles does
have a resource vocabulary — `ResourceClaim` with `jobsWeight`, `exclusiveKeys` and a
`--jobs` capacity — but it counts executor slots, not threads: a `TaskKind.build` node
weighing 2 may spawn a 32-thread linker inside those two slots, and `memoryHintBytes`
is documented as "a planning and reporting hint, not a second scheduler"
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`). Two such nodes can run together and each open 32
threads — the oversubscription `MOLD_JOBS` exists to prevent.

### 2. Lazy member extraction, and the report the graph never reads

Archive semantics are the original symbol-level pruning rule: members are "included
in the output only if they define a symbol referenced by another included file" (mold
paper §2.4, [mold-paper]). `lld` generalizes that to loose objects: with `--start-lib`,
"The specified objects are treated as if they were members of an archive the name of
which has been placed at the location of `--start-lib`" ([ld-man]). Bazel turns it on
by default through a hidden flag, `--start_end_lib`, `defaultValue = "true"`
([`CppOptions.java`][bazel-cpp-options]).

The linker can also report what it did — the part an engine could consume.
`--print-archive-stats=` writes `members`, `extracted` and `archive` columns;
`--why-extract=` writes `reference`, `extracted` and `symbol`;
`--why-live` reports a chain of references preventing GC. Headers are in
[`lld/ELF/Driver.cpp`][lld-driver], help texts in [`lld/ELF/Options.td`][lld-options].
This is a _post-hoc_ trace at symbol granularity: which declared inputs mattered, not
which declared edge was unnecessary.

### 3. Dead sections: `--gc-sections`

The mechanism is a mark-sweep over sections with relocations as edges — "Naturally
the feature is implemented as a mark-sweep garbage collector"
([`lld/ELF/MarkLive.cpp`][lld-marklive]). Roots are the whole question: "The section
containing the entry symbol and all sections containing symbols undefined on the
command-line will be kept… Note that when building shared libraries, the linker must
assume that any visible symbol is referenced" (GNU `ld` manual, [ld-man]). So a
shared-library link gets almost no GC benefit by construction, and a partial link has
no entry point: "the root of symbols kept must be explicitly specified either by one
of the options `--entry`, `--undefined`, or `--gc-keep-exported`" ([ld-man]).

Defaults are not interchangeable: `lld` 13 made the aggressive behaviour default, GNU
`ld` 2.37 made it opt-in ("GNU ld 2.37 added `-z start-stop-gc`… ld.lld 13.0.0
defaults to `-z start-stop-gc` and supports `-z nostart-stop-gc` to switch to the
conservative behavior", [lld-start-stop-gc]). The trap for a build system that thinks
it pruned safely: "On ELF targets, `__attribute__((used))` prevents compiler
discarding, but does not affect linker `--gc-sections`" ([lld-start-stop-gc]).
`SHF_GNU_RETAIN` and `__attribute__((retain))` are what survive GC.

### 4. Identical code folding

ICF merges read-only sections with equal flags, contents and relocations, where "two
relocations are considered the same if they have the same relocation types, values,
and if they point to the same sections _in terms of ICF_" — a recursive
equivalence, not a byte comparison ([`lld/ELF/ICF.cpp`][lld-icf]). `lld` defaults to
`--icf=none`; `--icf=all` and `--icf=safe` are opt-in ([lld-options]).

Folding changes semantics in exactly one documented place: "It is guaranteed in C
and C++ that two pointers pointing to two different functions will never be equal,
but `--icf=all` breaks that assumption as two identical functions have the same
address after merging" ([mold-man]). The safe variant needs compiler cooperation:
"`--icf=safe` needs to be used with a compiler that supports the `.llvm_addrsig`
section… Since GCC does not support it yet, you cannot use `--icf=safe` with GCC"
([mold-man]).

### 5. Splitting the link: ThinLTO, partial link, shared libraries

ThinLTO is the only mechanism here that changes the _shape_ of the graph rather than
the contents of one node: "During the link step, only the summaries are read and
merged into a combined summary index… all transformations, including function
importing, occur later when the modules are optimized in fully parallel backends"
(Clang [`ThinLTO.md`][thinlto-doc]).

`lld` exposes the boundary as `--thinlto-index-only` plus per-module knobs
(`--thinlto-jobs` defaults to `--threads`), and can distribute the backends itself:
"If specified, ThinLTO backend compilations will be distributed"
(`--thinlto-distributor`, [lld-options]). Backends are cached per module and pruned
against a documented default of 75 % of free disk ([thinlto-doc]).

Bazel shows what an engine must add — the per-module inputs are unknown at analysis
time: "The LTO indexing step takes all bitcode `.o` files and decides which other
`.o` file symbols can be imported/inlined. The additional input files for each
backend action are then written to an imports file. Therefore, these new inputs must
be discovered here by subsetting the imports paths from the set of all bitcode
artifacts, before executing the backend action" ([`LtoBackendAction.java`][bazel-lto-backend]).
Buck2 reaches the same shape through `ctx.actions.dynamic_output` ([buck2-dyndeps]);
`LtoMode` keeps `none`, `fat`, `monolithic` and `thin` as distinct build modes
([`prelude/linking/lto.bzl`][buck2-lto]).

The pre-LTO version of the same decomposition is partial linking — `ld -r` produces
"relocatable output… This is often called partial linking" ([ld-man]) — and the coarse
version is shared libraries or Buck2's link groups, which "partition a binary's native
dependencies into separate shared libraries" ([buck2-link-groups]). mold prices the
trade: "The split comes at the cost of larger binaries, slower loading, and added build
and code complexity" ([mold-paper] §10). **Catalog inference:** none of the reviewed
systems documents `ld -r` as a scheduler-visible subtree node.

## What it buys, as published

| Claim                                                     | Number                            | Source                |
| --------------------------------------------------------- | --------------------------------- | --------------------- |
| mold vs `lld`, median over nine large programs (Aug 2026) | 4.9× faster                       | [mold-readme]         |
| mold vs `lld` across the paper's workloads                | 2.4–16.1×; up to 112× vs GNU `ld` | [mold-paper] abstract |
| Chromium 145 debug link, 64-core Threadripper             | 16.64 s (`lld`) → 1.65 s (mold)   | [mold-readme] table   |
| Firefox debug per-pass totals                             | 4.43 s (`lld`) → 0.90 s (mold)    | [mold-paper] Table 9  |
| Section GC pass, same workload                            | 0.85 s serial (`lld`) → 0.06 s    | [mold-paper] Table 9  |
| Pass-level speedup at the default 32 threads              | 5–29× per pass                    | [mold-paper] §7.4     |
| ThinLTO cache pruning default                             | 75 % of available disk            | [thinlto-doc]         |

Not published anywhere reviewed: the effect of link-time pruning on a build DAG's
critical path. **Catalog inference:** the graph-level gain of GC or ICF is bounded by
how often a link is on the critical path — and neither removes an edge, so neither can
unblock a dependent earlier.

## Analysis spine

| Spine dimension          | What a link contributes to it                                                                                                      |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| Task model & scheduling  | One topological action; intra-link parallelism is invisible, so link-heavy graphs need an explicit cap ([mold-man] `MOLD_JOBS`)    |
| Rebuilding & correctness | A sink that any object change re-runs ([nix-cargo-unit] §2); early cutoff is sound only if the link is deterministic ([concepts])  |
| Dependency discovery     | The linker learns symbol-level dependencies during extraction and GC and can publish them; no reviewed engine feeds them back      |
| Store & caching          | ThinLTO caches backend objects per module ([thinlto-doc]); whole-link caching needs every object in the key                        |
| Hermeticity & provenance | Outputs embed `RPATH`/`RUNPATH`, how Nix finds _retained_ dependencies ([nix-thesis] §5.2.3); thin archives are not self-contained |
| Distribution             | The ThinLTO index/backend split, `--thinlto-distributor` and Buck2's planner; a monolithic link is one indivisible remote action   |

In [concepts]' grid a link is neither scheduler nor rebuilder: it is one task body
whose cost every cell pays. The grid touches it only at early cutoff — whether a
re-link that reproduces its output stops propagation — and that answer belongs to the
rebuilder's trace, not to the linker.

## Interaction with build-DAG granularity

**A link's key is its entire input set.** Meson emits "one link edge per target"
([meson] "Task model & scheduling"), so touching any object marks the link dirty;
Ninja recovers early cutoff only through `restat`, an mtime proxy for value equality
([ninja] §2), and Bazel keys the action on its declared inputs ([bazel]).
Determinism makes the stronger version available: "the same inputs, command-line
options, and linker version always produce a bit-identical binary" ([mold-paper] §4.11;
[mold-man]). **Catalog inference:** with that guarantee an engine may hash the link
output and cut off downstream packaging without `restat`'s proxy.

**Symbol pruning does not shrink the graph.** GC and ICF run inside the action; the
declared inputs, edges and schedule are unchanged. They reduce artifact size, page
faults and downstream link inputs — never node count.

**Thin archives break the "hash the input file" assumption.** GNU `ar` documents
that a thin archive "contains a symbol index and references to the original copies of
the member files of the archive… The paths to the elements of the archive are stored
relative to the archive itself" ([Introduction][ar-thin]). Three hazards, the last as
catalog inference: the archive is not self-contained, so remote execution must ship
the members too; moving it breaks the recorded relative paths; and a member changing
does not change the archive's bytes, so a key over the archive alone misses the real
input — precisely the "hash what the consumer consumes" rule [semantic-caching]
states.

**Splitting the link is the only lever that changes granularity.** A ThinLTO index
action's output is a summary; each backend then depends on it _and_ on a per-module
imports list discovered after indexing ([bazel-lto-backend]). That is a dynamic
dependency at the link boundary — the shape [dynamic-deps-distributed] catalogues for
`dyndep` and Nix — except the discovery record is an ordinary file the engine must
parse. Buck2's `dynamic_output` does that ([buck2-dyndeps]).

**The runtime edge is not the build edge.** macOS `-dead_strip_dylibs` can drop an
unused dylib from the load commands, but "`isReferenced()` is currently computed before
dead code stripping, so references from dead code keep a dylib alive" — a limit `lld`
shares with ld64 ([`lld/MachO/Writer.cpp`][lld-macho-writer]). Pruning a runtime edge
does not remove the build edge, and Nix's `references` scan exists because link-time
knowledge of runtime references is incomplete ([nix-thesis] §5.2.3).

## Correctness risks

| Risk                                        | Mechanism                                                                             | Source               |
| ------------------------------------------- | ------------------------------------------------------------------------------------- | -------------------- |
| GC drops a section reached only at runtime  | roots are entry, `--undefined`, dynamic refs; runtime-only refs invisible (inference) | [ld-man]             |
| `used` is not enough                        | "does not affect linker `--gc-sections`"                                              | [lld-start-stop-gc]  |
| Same flags, different binaries              | `lld` defaults to `-z start-stop-gc`; GNU `ld` needs it explicit                      | [lld-start-stop-gc]  |
| Partial link has no implicit roots          | GC on `-r` needs `--entry`/`--undefined`/`--gc-keep-exported`                         | [ld-man]             |
| ICF breaks function-pointer identity        | `--icf=all` merges distinct functions to one address                                  | [mold-man]           |
| Safe ICF is compiler-dependent              | needs `.llvm_addrsig`; GCC cannot use it                                              | [mold-man]           |
| Thin archive hides member changes           | stores paths, not contents                                                            | [ar-thin]; inference |
| Distributed ThinLTO reads undeclared inputs | per-module imports are discovered after indexing                                      | [bazel-lto-backend]  |
| Parallelism changes corner-case semantics   | "which definition prevails" in `-start-group` corner cases                            | [mold-paper] §2.3    |
| Incremental linking defeats pruning         | a full link is forced by `/OPT:REF` or `/OPT:ICF`                                     | [msvc-incremental]   |

The asymmetry mirrors [dependency-pruning]: keeping too much is a size and speed
problem; dropping one needed symbol is a runtime failure no build system sees. So
every default is conservative — GC off in `lld`, ICF `none`, visible symbols rooted
in shared libraries, dead-code references keeping dylibs alive.

## Incremental linking, as documented

The other answer is to patch the previous output. MSVC's `/INCREMENTAL` is the most
fully documented instance: an incrementally linked image "Is larger… because of
padding of code and data… May contain jump thunks to handle relocation of functions to
new addresses" ([msvc-incremental]). The same page names what forces a full link —
including `/OPT:REF` and `/OPT:ICF` — and warns "To ensure that your final release
build does not contain padding or thunks, link your program non-incrementally".
**Catalog inference:** padding is what makes symbol-level incremental linking
possible, and stripping it to prune is what makes it impossible.

mold chooses the other side deliberately: "Incremental linking takes a different route
to fast turnaround… mold instead focuses on full-link speed… many common changes still
force a full relink. For example, gold falls back to a full link when a function
definition is removed or preallocated patch space runs out" ([mold-paper] §10). `lld`'s
ELF driver exposes no incremental-link option ([lld-options]); Mach-O's "incremental
LTO cache" is a backend cache, not an incremental link ([lld-macho-options]).

## Strengths and weaknesses

- **Strengths — a full link is a pure function of its inputs**, so a fast full link
  composes with hashing, early cutoff and remote execution ([mold-paper] §4.11).
- **Strengths — the linker's symbol-level report is free evidence.** `--why-extract`,
  `--print-archive-stats` and `--why-live` answer "which declared input mattered"
  without tracing syscalls ([lld-options], [lld-driver]).
- **Weaknesses — pruning is invisible to the graph, tool-dependent and silent when
  wrong.** Roots differ between GNU `ld` and `lld`, `used` does not protect a symbol,
  and an unsafe ICF fold fails at runtime ([lld-start-stop-gc], [mold-man]).
- **Weaknesses — every granularity gain moves work elsewhere.** ThinLTO adds index and
  per-module actions plus a cache; shared libraries add runtime edges and load cost
  ([thinlto-doc], [mold-paper] §10).

## Key design decisions and trade-offs

| Decision                                 | Rationale                                               | Trade-off                                                         |
| ---------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------------------- |
| Parallelize a full link, do not patch it | No bookkeeping, no fallback, deterministic output       | Peak memory and cores per link; a bad edit still links everything |
| Leave GC and ICF off by default          | Unreachable-to-the-linker is not unreachable-at-runtime | Pruning needs per-project flags and an audit                      |
| Extract archive members lazily           | Only members resolving a reference are pulled in        | Thin archives hide member changes; extraction is not a build edge |
| Root GC explicitly on partial links      | There is no entry symbol                                | `ld -r` needs `--entry`/`--undefined` bookkeeping                 |
| Split at module granularity (ThinLTO)    | Backends are independent, parallel and cacheable        | Index + imports discovery; a dynamic dependency the engine reads  |
| Partition into shared libraries          | A change relinks one small library                      | Larger artifacts, slower loading, more runtime edges              |

## Sparkles relevance

`sparkles.build_primitives.task` models a package build as one opaque node:
`TaskKind.build` is "`dub build` of a package" (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`). The link
is inside the action, along with compilation; the DAG cannot schedule it, cache it, or
see it fail separately. Two facts bound what is worth doing:

- **The package graph is declaration-only.** `package_graph.d` builds edges from "the
  in-tree dependencies its active configuration declares"
  (`libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d`), and `EdgeReason.packageDependency` is
  "the dependent package depends on the prerequisite" (`model.d`).
- **The linker is chosen by the toolchain.** The dev shell provides `lld-sparkles` and
  notes that a link through it "records the store paths of its `-L` libraries as RUNPATH
  entries" ([`nix/d-toolchain.nix`][sparkles-toolchain]), so link output depends on
  store layout, not just object bytes.

Three ports, in ascending cost. **Measure before modelling:** a link action passing
`--print-archive-stats=` and `--why-extract=` would report, per executable, which
archive members were extracted — for a `dub` build linking one `lib*.a` per package, a
direct audit of over-declared `dub.sdl` dependencies, at symbol granularity and with no
tracer ([dependency-pruning]'s audit). **Split compile from link only when
objects are reusable:** today one `dub build` node does both, and splitting it without
object-level reuse would double the command count and change nothing about
invalidation; the ThinLTO index/backend shape ([bazel-lto-backend]) is the later
model. **Give a link node the right claim when it becomes one:** `ResourceClaim` already
carries `jobsWeight` and `exclusiveKeys`, so the decision is whether a link's weight
should reflect the linker's own thread count or whether links should serialize on one
exclusive key — the Meson/mold lesson that N concurrent links cost N× memory
([meson-build-options], [mold-man]).

One thing not to port: link-time pruning as a **substitute** for edge pruning.
`--gc-sections` and ICF will shrink a Sparkles binary once flags are wired through
`lflags`/`ldc2.conf`, but they remove no package edge and unblock no dependent earlier
— that work stays in [dependency-pruning] and [semantic-caching].

## Sources

In-corpus pages synthesized: [concepts] (early cutoff), [dependency-pruning] (the
scope note this fills), [semantic-caching] ("hash what the consumer consumes"),
[ninja] (`restat` as an mtime proxy), [meson] (`link_pool`), [bazel] (action keys),
[buck2] (`dynamic_output`, `LtoMode`), [nix-cargo-unit] (link sinks),
[nix-thesis] (embedded paths, retained-dependency scan),
[dynamic-deps-distributed] (ThinLTO index).

Primary sources, opened at these pinned revisions:

- mold `331ac663668dc0b1f4949403854613b9b1913025`: [`README.md`][mold-readme],
  [`docs/mold.md`][mold-man], [`elf/driver.rs`][mold-driver]. At this SHA the clone is
  the Rust implementation ("mold is written in Rust and built with Cargo"), so the
  driver is `.rs`; the manual and benchmark table are the project's own.
- mold paper, _mold: A Massively Parallel Linker_ (ASPLOS 2027),
  [arXiv 2608.23228][mold-paper] — abstract, §2.3, §2.4, §4.5–4.6, §4.11, §7.4–7.5,
  §10; read as HTML, not PDF.
- LLVM `275dcf288790e62c922d50926e78755ab8aa19fe`:
  [`lld/ELF/Options.td`][lld-options], [`lld/ELF/Driver.cpp`][lld-driver],
  [`lld/ELF/MarkLive.cpp`][lld-marklive], [`lld/ELF/ICF.cpp`][lld-icf],
  [`lld/docs/ELF/start-stop-gc.md`][lld-start-stop-gc],
  [`lld/MachO/Options.td`][lld-macho-options],
  [`lld/MachO/Writer.cpp`][lld-macho-writer], [`clang/docs/ThinLTO.md`][thinlto-doc].
- GNU binutils manuals (online): [`ld` options][ld-man] (`--gc-sections`,
  `--relocatable`, `--start-lib`), [`ar` introduction][ar-thin].
- Microsoft Learn [`/INCREMENTAL`][msvc-incremental].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`:
  [`LtoBackendAction.java`][bazel-lto-backend], [`CppOptions.java`][bazel-cpp-options].
  Buck2 `08b403b138373f506de90d15370162677526e388`:
  [`dynamic_dependencies.md`][buck2-dyndeps], [`lto.bzl`][buck2-lto],
  [`link_groups_explained.md`][buck2-link-groups]. Meson
  `27f69b22e5fe403d3ec5788216adaa85046d0e8f`: [`Build-options.md`][meson-build-options].

Unverified: no reviewed source measures the makespan effect of link-time pruning on a
graph, so every graph-level statement is catalog inference. The mold paper is a
preprint for a 2027 venue; its numbers are quoted, not reproduced. The binutils manual
has no commit, so it is cited by section.

<!-- References -->

[concepts]: ./concepts.md
[dependency-pruning]: ./dependency-pruning.md
[semantic-caching]: ./semantic-caching.md
[ninja]: ./ninja.md
[meson]: ./meson.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[nix-thesis]: ./nix-thesis.md
[dynamic-deps-distributed]: ./dynamic-deps-distributed.md
[sparkles-toolchain]: ../../../nix/d-toolchain.nix
[mold-readme]: https://github.com/rui314/mold/blob/331ac663668dc0b1f4949403854613b9b1913025/README.md
[mold-man]: https://github.com/rui314/mold/blob/331ac663668dc0b1f4949403854613b9b1913025/docs/mold.md
[mold-driver]: https://github.com/rui314/mold/blob/331ac663668dc0b1f4949403854613b9b1913025/elf/driver.rs
[mold-paper]: https://arxiv.org/abs/2608.23228
[lld-options]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/ELF/Options.td
[lld-driver]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/ELF/Driver.cpp
[lld-marklive]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/ELF/MarkLive.cpp
[lld-icf]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/ELF/ICF.cpp
[lld-start-stop-gc]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/docs/ELF/start-stop-gc.md
[lld-macho-options]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/MachO/Options.td
[lld-macho-writer]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/lld/MachO/Writer.cpp
[thinlto-doc]: https://github.com/llvm/llvm-project/blob/275dcf288790e62c922d50926e78755ab8aa19fe/clang/docs/ThinLTO.md
[ld-man]: https://sourceware.org/binutils/docs/ld/Options.html
[ar-thin]: https://sourceware.org/binutils/docs/binutils/ar.html
[msvc-incremental]: https://learn.microsoft.com/en-us/cpp/build/reference/incremental-link-incrementally?view=msvc-170
[bazel-lto-backend]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/cpp/LtoBackendAction.java
[bazel-cpp-options]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/cpp/CppOptions.java
[buck2-dyndeps]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rule_authors/dynamic_dependencies.md
[buck2-lto]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/prelude/linking/lto.bzl
[buck2-link-groups]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/prelude/linking/link_groups_explained.md
[meson-build-options]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/Build-options.md
[cargo-unit-render]: https://github.com/wyattgill9/nix-cargo-unit/blob/355648f33b07209a5566a3a592e2edbe49303c1e/src/render.rs
