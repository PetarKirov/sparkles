# dgd (Go + Nix)

A Go build split into one Nix derivation per `go build` action by parsing the
compiler's dry run — a language-specific generator that lets dynamic derivations
extend Nix's plan from inside a build rather than blocking evaluation.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                        |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Go 1.25.5 ([`process-build/go.mod`][go-mod]); Nix for packaging and the two front ends                                                       |
| License               | MIT                                                                                                                                          |
| Repository            | [dnr/dgd][repo] — David Reiss                                                                                                                |
| Documentation         | [`README.md`][readme] and a scratch [`notes`][notes] file; no manual                                                                         |
| Category              | Nix ecosystem — language-specific graph generator for dynamic derivations; neighbours [nix-ninja], [sandstone], [drowse]                     |
| Clone (pinned)        | `$REPOS/build-systems-research/src/dgd` at `9a5a72b530f412c8e470cdf2b308c0ba88145d73` (2026-02-02); shallow, **one commit**, **no tags**     |
| Status                | One "import working code" commit; 707 lines of Go, 111 of shell, plus Nix glue; README lists limitations; experimental Nix features required |
| Scheduler × rebuilder | Suspending × deep constructive — Nix's cell, with the derivation _set_ produced at build time; dgd adds no scheduler (see placement)         |

## Overview

### What it solves

> "This is a build system for Go binaries in Nix using dynamic derivations.
> Dynamic derivations are an experimental Nix feature that allows Nix to extend
> its build plan as it's building, which allows for very fine-grained
> derivations, which we can use for better build caching."
>
> — [`README.md`][readme]

`go build` is a black box: it schedules compilation, packing, cgo and linking
itself and keeps a cache invisible to Nix, while Nix's unit is a package or module,
so one edit invalidates the whole package. Reimplementing Go — what `rules_go` does
— is impractical outside Bazel ([`README.md`][readme] § design); dgd asks Go what
it would do and transcribes the answer into derivations.

### Design philosophy

> "The “trick”—you might say gross hack, and you'd be right—is to run `go build -n`
> to output a script of what `go` will do, and then parse it and process it into
> Nix derivations."
>
> — [`README.md`][readme] § design

The dry run is a task description in the sense of [concepts][]: `mkdir`, `cd`,
`cat >importcfg`, `compile`, `pack`, `gcc` and `link` commands grouped by Go's
scratch directories. dgd rewrites their paths and emits one derivation per group;
there is no tracer, so correctness rests on the dry run being faithful. The same
generator feeds either execution model — the README calls dynamic derivations
"mostly just a ‘better IFD’ that doesn't block evaluation", with "most of the
code … the same" ([`README.md`][readme] § dynamic derivations vs IFD).

## How it works

### A dry run is the task description

`script/build-n.sh` runs `go build -n`, captures stderr in `$TMPDIR/build-n` and
hands it to `process-build` ([`build-n.sh`][build-n]). [`parser.go`][parser-go]
treats `# ` as a title, `mkdir -p $WORK/bNNN` as an action boundary, `cd` as a
directory change and `cat >file << 'EOF'` as a heredoc (Go writes `importcfg` that
way); other lines go through `shlex.Split`. It records the `...-go-...` store path,
rejects two Go packages, and keys an action by its `$WORK` name with `/exe`
rewritten to `-bin`, so the entry is expected to be `b001-bin` ([`graph.go`][graph-go]).

### From commands to a dependency graph

[`graph.go`][graph-go] makes three passes. **Outputs:** `-o`/`>`/`mv` targets
under the action's own `$WORK`. **Dependencies:** arguments containing
`$WORK/<other-id>/<file>`, plus `packagefile` lines inside `importcfg` heredocs,
since a compile consumes imports through `importcfg`, not argv. **Pruning:** each
dependency's used file is recorded and outputs are trimmed to those, except
`-bin` actions; `mkdir` and `rm` are skipped. The result is a compiler-emitted
trace at command granularity: what Go printed is an edge, and nothing else
appears later.

### Rewriting commands into derivations

[`generator.go`][generator-go] sorts actions topologically and emits
`runCommand "dgd-<title>" { inherit env; } ''…''` per action. A project path
becomes a narrow store copy of just that path — "re-copy just this directory to
the store, just regular files, so that we have the narrowest-possible dependency
on source changes" ([`generator.go`][generator-go]). The Go path becomes `${go}`,
the action's scratch directory `$TMPDIR`, another action's `$WORK` reference
`${bNNN}` (or a subpath), and module-cache paths per-module store paths. `go tool
buildid`/`-buildid` are dropped because "these are changing and messing up our
caching"; `pack` comes from a prebuilt `cached_tools` derivation; `mkdir`, `rm`
and `cd` are swallowed; `-trimpath`/`echo` and `-ldflags=` need quoting hacks the
source calls "really hacky" and "even hackier". The expression ends `in b001-bin`;
`TODO: always b001?` records that the entry point is assumed, not computed.

### Two front ends, one generator

Both take the same arguments and script; only the timing differs.

**Dynamic mode** ([`dyn.nix`][dyn]) wraps it in a text-content-addressed
`dgd-<module>-bin.drv` requiring `recursive-nix`; inside, `nix-instantiate` writes
the generated `.drv` to `$out`, and `builtins.outputOf dynDrv.outPath "out"` names
the target. Nix learns the actions mid-build. The author's own comments ask
`__contentAddressed = true; # why is this needed???` and `# needed to depend on a
dynamic derivation?` ([`dyn.nix`][dyn]).

**IFD mode** ([`ifd.nix`][ifd]) replaces both `outputOf`s with `import`s: a
`runCommandLocal` writes `dgd-split-deps.nix`, evaluation imports it, a
`runCommand` writes `dgd-drv.nix`, and evaluation imports that. The same graph
appears but evaluation blocks; `$out`'s suffix selects which file to copy.
`getModule.nix` only derives the name from `go.mod`/`subPackage`.

### Third-party modules as per-module FODs

A `vendorHash` buys one FOD running `go mod download` ([`download.sh`][download]),
keeping expanded modules and `pkg/mod/cache` metadata but deleting zips, locks and
`list` files. [`split.sh`][split] tars each `pkg/mod/<module>@<version>`, hashes it
with `nix-hash --type sha256` and emits a recursive `runCommandLocal`;
`dgd-joined-deps` symlinks them back. [`graph.go`][graph-go]'s `loadDepMap` maps
each to its store path. Adding or removing a dependency re-downloads the vendor set
but rebuilds no unaffected module; the README points at `gomod2nix` for
per-module FODs ([`README.md`][readme] § limitations).

### Maturity signals

The clone is one commit, `import working code`, no tags. The README calls it "a
crazy gross hack that's inherently kinda fragile" and "slower than a plain Go
build. Something like 1.5×. All that sandboxing…" ([`README.md`][readme] §
limitations); [`notes`][notes] lists differential builds, tests, private Git,
`ldflags`, stripping and `patchelf` as future work. Offset: [`vmtest.nix`][vmtest]
boots a VM with substituters disabled and builds both modes; examples cover cgo,
no-cgo, dependencies, multiple packages and `subPackage`.

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix is **suspending × deep constructive** in [concepts][]'s Table 2; dgd adds no
cell. It is a **task-description generator**: its output is ordinary Nix
derivations, scheduled and rebuilt by output-path validity over terminal input
hashes. What is unusual is _when_ the set exists — the generated `.drv` is a build
product, so Nix's plan is extended mid-build rather than at evaluation. Within dgd
the graph is static (`go build -n` prints every edge before any compile), so this
is plan production at build time, not edge discovery: the distinction [sandstone][]
makes, opposite in direction from [nix-ninja][]'s manifest lowering.

### 1. Task model & scheduling

The task is a `$WORK/bNNN` action holding one or more commands. Generation is a
static single-threaded topological walk; execution is Nix's, so independent package
compiles run in parallel according to the daemon's build slots. There is no `-j`,
pool, priority, speculation or per-target selection, and the emitted expression
always returns `b001-bin` ([`generator.go`][generator-go]). Dynamic derivations
change when the scheduler learns the tasks, not how it orders them.

### 2. Rebuilding & correctness

The dirty check is Nix's. Generated actions are **input-addressed** `runCommand`s,
so paths depend on the rewritten command, source copies, dependency outputs and
toolchain — deep constructive over terminal inputs with no early cutoff: an upstream
byte change re-keys every dependent even if export data is identical. The design
buys package-level reuse, not interface-level cutoff.

Correctness rests on three choices. **Narrow copies** re-add only the path an action
names, keeping unrelated edits out of its key. **Nondeterminism removal** strips the
build id and redirects `GOCACHE` to a per-derivation `$TMPDIR`. **One trusted
premise** — that `go build -n` lists every input — is unverified: no tracing,
depfile cross-check, differential build test ([`notes`][notes] lists one) or
declared-input audit. Under-declaration fails in the sandbox rather than producing a
wrong hit; over-declaration costs hits. The per-module FODs get content identity
from NAR hashes; action derivations do not.

### 3. Dependency discovery

Discovery is **compiler-inferred, not traced**: the dry run supplies commands and
`importcfg` package edges. Both are complete relative to Go's scheduler if the
parser handles every shape Go emits; the parser is narrow (heredocs, `mkdir`/`cd`,
`-o`/`>`/`mv`, `packagefile`), with `os.Stat` its only heuristic
([`graph.go`][graph-go]). There is no strict-deps, unused-declared pruning or
runtime tracing; splitting `vendorHash` does not detect an unimported module.
Versus [perfect-dependencies][] tracing, this is cheaper and assumes the compiler
tells the truth parseably.

### 4. Store & caching

The Nix store is the only cache: no action cache, metadata index or eviction policy
of dgd's own. Source paths, per-module FODs, input-addressed actions and a text-CA
`.drv` live there; sharing is whatever substituters and the daemon provide.
Cross-machine reuse needs the same command, source hashes, toolchain and dependency
outputs. Narrow copies and module splits help, but there is no dgd cache or remote
protocol; a [REAPI][content-addressing] front end would sit above Nix.

### 5. Hermeticity & provenance

Each action is an ordinary derivation, getting the daemon's sandbox and no more.
The environment is caller `env` plus builder defaults; `GOPROXY=off` and
`GOTOOLCHAIN=local` prevent fetches and toolchain downloads ([`dyn.nix`][dyn]); the
toolchain and modules are store paths; cgo uses `runCommandCC` when `CGO_ENABLED`
is `1`. The weak point is the **generator**: `build-n.sh` runs under
`recursive-nix`, executes `go build -n` and `nix-instantiate`, and writes a `.drv`
to the store. That builder is privileged, with the text hash as the only integrity
check. No SLSA, in-toto or DSSE; the `.drv` is the record, and caller `env` is not
purity-checked.

### 6. Distribution

No protocol of its own. Every action is a normal derivation, so a builder fleet or
substituter can distribute it once it exists; the sharing unit is the action, not
the module. Constraints are ecosystem-wide: clients and daemons need
`dynamic-derivations`, `ca-derivations` and `recursive-nix`; `innerNix` defaults to
`pkgs.nixVersions.nix_2_32` ("use nix 2.32.5 or higher for best results",
[`dyn.nix`][dyn]); [`vmtest.nix`][vmtest] enables exactly those. IFD distributes the
same derivations but blocks evaluation; dynamic mode is friendlier, since the plan
is produced by a schedulable build and only the `.drv` must reach the scheduler.

### 7. Sparkles relevance

`sparkles:build-primitives` models work as `TaskNode`/`TaskEdge` with typed
`EdgeReason`s, including `planning`
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
dgd is a planning step that emits a whole graph. Three mechanics transfer:

- **A plan can be a task output.** The `.nix`/`.drv` is a real artifact with its
  own key and selected output, so a `planning` edge could point at it rather than an
  in-memory decision — the shape [sandstone][] and [drowse][] use.
- **Narrow inputs at task granularity.** Copying only the path an action reads turns
  a package graph into per-package reuse; a `TaskNode` could carry its narrow input
  roots.
- **A canonical action record as identity.** Rewritten argv, cwd, env, outputs and
  input store paths are the key; Sparkles has stable `TaskId`s but no content key
  over the action.

Do not copy the parser or uncached generation: dgd runs `go build -n` before any
action can be keyed, and re-runs it per generation. A general DAG should take edge
data from a compiler depfile or declared interface and cache generation.

## Strengths and weaknesses

- **Fine-grained Go caching without reimplementing Go.** The dry run keeps dgd
  aligned with new Go versions, unlike a rules_go-scale port; an offline
  [`vmtest.nix`][vmtest] exercises both modes.
- **Two execution models from one generator.** Dynamic derivations avoid blocking
  evaluation; IFD is the fallback, differing only in whether a `.nix` or `.drv` is
  copied.
- **Real dependency granularity.** The module cache is split per module and sources
  per path, so unrelated edits do not re-key the world.
- **Honest scope, but the parser is the boundary.** The README limitations, `notes`
  TODO list and "why is this needed???" comments make the edges visible; yet
  `go build -n` is unstable, so heredocs, quoting and `-buildid` are special cases
  and a new output shape can silently drop an edge.
- **No early cutoff, monolithic `vendorHash`.** Input-addressed actions re-key
  dependents even with identical export data, and one dependency change re-downloads
  the vendor set.
- **Missing `buildGoModule` surface.** No `ldflags`, `nativeBuildInputs`, module
  root, metadata, stripping, `patchelf` or tests; the binary is a single store file
  without `/bin`.
- **Slower and immature.** ~1.5× a plain build, one commit, no tags, an unstable
  nixpkgs pin, a default Nix version chosen by comment, and an experimental
  interface that may change.

## Key design decisions and trade-offs

| Decision                                         | Rationale                                                        | Trade-off                                                              |
| ------------------------------------------------ | ---------------------------------------------------------------- | ---------------------------------------------------------------------- |
| Parse `go build -n` instead of reimplementing Go | Aligned with Go by construction; no rules_go-scale port          | Undocumented output shape; quoting and heredoc heuristics              |
| One derivation per `$WORK` action                | Package-level cache entries and per-action store paths           | Many store paths and daemon round-trips; ~1.5× slower than plain build |
| Generate the plan inside a build (dynamic mode)  | Extends Nix's plan without blocking evaluation; shareable `.drv` | Requires `recursive-nix`; the generator holds store-write trust        |
| Text-content-addressed outer derivation          | The output can _be_ a `.drv`, selected with `builtins.outputOf`  | Experimental interface; the "why is this needed???" comments           |
| Split the module cache into per-module FODs      | Adding a dependency does not rebuild unrelated modules           | One `vendorHash` still re-downloads everything; an extra split build   |
| Narrow source copies via `builtins.path`         | Only the path an action reads enters its key                     | More store objects, and a filter limited to regular files              |

## Sources

- [`dnr/dgd`][repo] at `9a5a72b530f412c8e470cdf2b308c0ba88145d73`, clone at
  `$REPOS/build-systems-research/src/dgd`; shallow, one commit, no tags. Quotes are
  verbatim from the cited files.
- Read: `README.md`, `notes`, `LICENSE`, `default.nix`, `dyn.nix`, `ifd.nix`,
  `getModule.nix`, `shell.nix`, `vmtest.nix`, `.envrc`, `process-build/*.go` with
  `package.nix` and `go.mod`, `script/*.sh`, and the `examples/` modules.
- Background: [concepts][], [nix-thesis][], [nix-ninja][], [sandstone][], [drowse][]
  and [content-addressing][].

<!-- References -->

[repo]: https://github.com/dnr/dgd
[readme]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/README.md
[notes]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/notes
[go-mod]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/process-build/go.mod
[dyn]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/dyn.nix
[ifd]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/ifd.nix
[vmtest]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/vmtest.nix
[graph-go]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/process-build/graph.go
[parser-go]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/process-build/parser.go
[generator-go]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/process-build/generator.go
[build-n]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/script/build-n.sh
[download]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/script/download.sh
[split]: https://github.com/dnr/dgd/blob/9a5a72b530f412c8e470cdf2b308c0ba88145d73/script/split.sh
[concepts]: ./concepts.md
[perfect-dependencies]: ./perfect-dependencies.md
[nix-thesis]: ./nix-thesis.md
[nix-ninja]: ./nix-ninja.md
[sandstone]: ./sandstone.md
[drowse]: ./drowse.md
[content-addressing]: ../content-addressing/index.md
