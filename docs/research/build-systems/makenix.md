# MakeNix (Go + Nix)

A 224-line worked example — not a product — that turns `gcc -MM` depfiles into
one Nix derivation per object file _during_ a Nix build, then hands the generated
graph back to the daemon with `builtins.outputOf`.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                                                                                                       |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language              | Go standard library only (`fmt`, `os`, `path/filepath`, `strings`, `text/template`); Nix in [`default.nix`][default-nix] and [`derivation.gotmpl`][template]; GNU Make and C for the sample |
| License               | MIT ([`LICENSE`][license], "Copyright (c) 2025 Farid Zakaria")                                                                                                                              |
| Repository            | [fzakaria/MakeNix][repo] — the `README.md` defers to the author's companion post for an overview                                                                                            |
| Documentation         | [`README.md`][readme] (38 lines) plus the 2025-03-11 blog post; no manual, no design document                                                                                               |
| Category              | Nix ecosystem — build-graph lowering demonstration, dynamic derivations; siblings [nix-ninja], [nix-cargo-unit], [nixception], [sandstone]                                                  |
| Clone (pinned)        | `$REPOS/build-systems-research/src/makenix` at `5c03fb1fe4d9942fc2cb124d45021c46adf46ef4` (2025-03-12); shallow, **one commit**, **no tags**                                                |
| Size                  | 10 source files, 224 lines (plus `LICENSE`, `.gitignore`): `README.md` 38, `Makefile` 30, `default.nix` 36, `parser/parser.go` 70, `derivation.gotmpl` 29, five C/header files              |
| Version               | none in tree — no release manifest, no version constant                                                                                                                                     |
| Status                | Demonstration; the README pins Nix to commit `d904921` and four experimental features                                                                                                       |
| Scheduler × rebuilder | Nix's cell (suspending × deep constructive) applied to a graph Make discovered — see _Placement_ below                                                                                      |

## Overview

### What it solves

> "This is a demonstratin of the power of _dynamic-derivations_ in Nix leveraged
> to build a C/C++ project via Makefile."
>
> — [`README.md`][readme]

Nix's unit of work is the derivation, so ordinary C/C++ packaging puts the whole
compile in one `mkDerivation` and lets `make` schedule within it; a one-line edit
invalidates the package. A committed per-object expression goes stale, and
import-from-derivation blocks evaluation on a nested `nix build` ([concepts] §2.2).

MakeNix generates the per-object expression _inside a Nix build_, returns its
`.drv` path as that build's output, and lets `builtins.outputOf` continue into
that derivation — no committed generated Nix, no evaluation block. The README is
deliberately narrow: "meant to be an example for others to imitate".

### Design philosophy

> "# n.b. put this at the top so that it's the deafult target. Otherwise the top
> level target gets automatically called by Nix mkDerivation"
>
> — [`Makefile`][makefile]

The build system keeps its own dependency knowledge and Nix becomes the executor.
Make is not reimplemented and the compiler is not wrapped: `gcc -MM` already emits
the graph Make consumes, so the generator only transcribes it — 70 lines and one
template. The price is that the plan has no schema of its own: every transcription
limit (§_Rebuilding & correctness_) is a limit of the build.

## How it works

### Two builds, two graphs

[`default.nix`][default-nix] builds one derivation named `result.drv`. Its `src`
is a `pkgs.lib.fileset` union of `src/*.c`, `src/*.h`, `./parser` and
`./Makefile`, so the planner sees exactly the project. `buildPhase` runs
`make deps` (`gcc -MM` per source, writing `src/*.d`) then
`go run parser/parser.go > derivation.nix`; `installPhase` copies the
`nix-instantiate`-produced `.drv` path into `$out`, so the product is a
_derivation file_. The value is `builtins.outputOf (…).outPath "out"` — build the
derivation named there and return _its_ `out`.

So two layers exist: one outer node gated on
`requiredSystemFeatures = [ "recursive-nix" ]` (its sandbox must reach a daemon
to instantiate), and the inner object DAG the generator emits, which the daemon
realises normally. Make's graph is the _description_; the sample's `all`/`main`
rules exist for use outside Nix and are never invoked here.

### The plan generator: depfile to expression

[`parser/parser.go`][parser-go] globs `src/*.d`, takes each file's first line,
splits on the first `:` and builds a `CompileUnit`: `SrcFile` is the first
dependency's basename, `HeaderDeps` the rest, `ObjFile` the target's basename.
Units go to `text/template` with [`derivation.gotmpl`][template]; no graph
algorithm, no Nix library — the generator writes text for the familiar
`main.o: src/main.c src/hello.h src/world.h` shape.

### The rendered graph

One derivation per object, plus one link step:

```nix
{ pkgs }:
let fs = pkgs.lib.fileset;
  hello.o = pkgs.stdenvNoCC.mkDerivation {
    src = fs.toSource { root = ./src;
      fileset = fs.unions [ ./src/hello.c ./src/hello.h ]; };
    nativeBuildInputs = [ pkgs.gcc ];
    buildPhase = ''gcc -c hello.c -o hello.o'';
    installPhase = ''cp hello.o $out'';
  };
in pkgs.runCommand "result" { nativeBuildInputs = [ pkgs.gcc ]; } ''
  gcc -o main ${hello.o} ${main.o} ${world.o}
  cp main $out
''
```

`fs.toSource` narrows each derivation to the source file and _only the headers
the depfile named_, so the sandbox enforces the declaration (§_Dependency
discovery_). The bindings are dotted — `hello.o = …` in a `let` — which Nix reads
as an attribute path (`LET binds IN_KW`, `binds1: attrpath '=' expr ';'` —
[`parser.y`][nix-parser]), so `${hello.o}` interpolates the derivation's output
path. It works, and it silently makes the basename the attribute key.

### `builtins.outputOf`: an output that is a derivation

Because the planner's output is a `.drv` path, Nix must be told to continue into
it. The primop documents the semantics:

> "If the derivation has a statically-known output path … the output path is
> returned. But if the derivation is content-addressed or if the derivation is
> itself not-statically produced (i.e. is the output of another derivation), an
> input placeholder is returned instead."
>
> — [`src/libexpr/primops.cc`][nix-primops], `prim_outputOf`

The planner declares `outputHashMode = "text"` and `outputHashAlgo = "sha256"`
with no `outputHash`, so its path is unknown at evaluation time and
`builtins.outputOf` yields a placeholder the daemon resolves after building it.
The post puts it plainly — "Nix will realize the output of one derivation is
another derivation and build it as well", "there is no recursive `nix build`"
([post][post]) — no inner build runs; only instantiation happens in the sandbox.

> [!NOTE]
> This repo is **not** a Make-like client of the Nix daemon or store protocol. It
> contains no protocol code: the only store interaction is `nix-instantiate` run
> from `installPhase` inside the `recursive-nix` sandbox, plus the placeholder
> `builtins.outputOf` leaves for the daemon.

## Analysis spine

### Placement in the scheduler × rebuilder grid

Nix occupies suspending × deep constructive in [concepts][]'s Table 2, and both
layers here are that cell: the outer node's `.drv` output is checked by
deep-constructive validity, and the inner object DAG is scheduled by Nix after
Make discovered it statically from depfiles (the `Applicative` shape). Make's own
engine survives only as a `foreach` over `gcc -MM`; what is novel is that the
_graph itself_ is a build product.

### 1. Task model & scheduling

Keys are object paths; values are objects, then the binary. Dependencies are
static and complete before the daemon sees them: every `${hello.o}` is an
input-addressed store path known at instantiation. No dyndep, speculation or
restart — the only dynamic edge is the `outputOf` chain, which is derivation
_discovery_, not dependency discovery inside a running task. Parallelism is
whatever Nix extracts from the object DAG; the planner is a serialisation point.

### 2. Rebuilding & correctness

The dirty check is Nix's: an object derivation is valid or built, keyed by the
input-addressed hash of its source closure, arguments and `nativeBuildInputs`. A
header edit invalidates each object whose depfile listed it, and the link step
reruns — "only `hello.o` gets rebuilt" after editing `hello.c` ([post][post]).
That is granularity, not early cutoff: a semantically irrelevant header edit
still changes the store path, because no output _contents_ are compared
([concepts] §5.4).

Correctness rests entirely on the transcription:

- Only the **first line** of each depfile is read (`lines[0]`), so a list `gcc`
  wraps across lines loses headers. The header is absent from the store path, so
  the compile fails — or, if reached transitively, the edge is silently missing.
- `ObjFile`/`SrcFile` are `filepath.Base` values, so `a/x.c` and `b/x.c` both
  become `x.o` and the `let` binds it twice — a hard error, but only once the
  project grows a second directory; the template also hardcodes `./src/…`
  (system headers are absent from `-MM` and reach objects via the pinned `gcc`).

There is no `--check`, no output comparison, no determinism test. The plan is
recomputed whenever _any_ `.c` or `.h` changes, because the planner's `src` is the
whole fileset: planning is O(project) even when compilation is not.

### 3. Dependency discovery

Inferred from the compiler's own depfile before the expression is rendered — the
source Make reads, which is the point. No tracer, no syscall interception, no
compiler plugin. Strictness is by construction: each `fs.toSource` copy holds the
source plus exactly the named headers, so an undeclared header is _absent_ from
the sandbox and the compile fails, while over-declaration is impossible. The
inverse of a permissive store scan (compare [nixception]).

### 4. Store & caching

The Nix store is the cache; the repo adds none. Objects are input-addressed
`stdenvNoCC.mkDerivation` results, so the link step's interpolations resolve
statically and a binary cache can substitute them. The only content-addressed
artefact is the planner's `.drv` output, hashed as text — "the hashing modes
traditionally done for derivation files" ([post][post]). Absent: eviction,
cache configuration, `nix copy`, any remote cache; the README recommends a
throwaway store (`--store /tmp/dyn-drvs`) instead.

### 5. Hermeticity & provenance

Each layer is a normal derivation and gets whatever sandbox the daemon configures;
the repo adds none. The planner's closure is explicit (`fileset` over sources,
parser and Makefile) and its tools are pinned, though nixpkgs is fetched by a bare
`fetchTarball` with no `sha256` — impure in the sense pure-eval mode rejects.

The capability exception is the design: the planner must instantiate inside its
sandbox, hence `requiredSystemFeatures = [ "recursive-nix" ]` and four
experimental features. A build with daemon access is a different trust boundary.
No attestation exists — `nix derivation show … | jq '.[].inputDrvs'` is the
post's inspection method — so the `.drv` is the only provenance record.

### 6. Distribution

Absent as a design concern: one store under `/tmp`, no remote builders, no REAPI,
no worker fleet. The generated graph could be distributed — it is an ordinary
derivation graph — but nothing configures it; a finding about scope, not a gap.

### 7. Sparkles relevance

`sparkles:build-primitives` models work as a validated in-memory graph of
`TaskNode`/`TaskEdge` with typed actions and resource claims (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`);
its plan is static and cannot grow while running. MakeNix argues for two phases:

- **Plan as a task.** The generator is an ordinary task whose output is a graph
  description, making the plan a cacheable node — exactly the planner here.
- **Declared inputs bound visibility.** The per-object `fileset` makes the cache
  key honest: an undeclared header cannot be read because it is not present.
- **The seam Sparkles lacks.** A finished task cannot emit nodes: a static
  `TaskGraph` would need a planning pass returning a new, validated graph.

## Strengths

- **The smallest honest demonstration of the idea.** 224 lines, no framework —
  `make deps` → depfile → template → `.drv` → `outputOf` in one sitting.
- **Per-object reuse without committing generated Nix.** The plan follows the
  sources; nothing goes stale between a hand-edited expression and the tree.
- **The compiler is the oracle, and the seam is replaceable.** Per-object
  closures double as strict deps (undeclared headers are absent from the store
  path), and NpmNix applies the same depfile-like-to-expression shape to npm.

## Weaknesses

- **A demonstration, not a tool.** One layout, no tests, no version, no CLI, no
  error handling beyond `panic`.
- **Fragile transcription.** First-line-only depfile parsing, basename keys
  (collisions across directories), a hardcoded `src/` prefix.
- **Experimental footing.** A pinned Nix commit (`d904921`), four experimental
  features (`nix-command`, `dynamic-derivations`, `ca-derivations`,
  `recursive-nix`) and a temporary-store workaround ("Here, there be dragons").
- **Planning is O(project) and there is no early cutoff.** Every edit re-runs the
  generator; a comment-only header edit still relinks, and the `.drv` is the only
  record of what was built.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                            | Trade-off                                                                              |
| ---------------------------------------------------- | -------------------------------------------------------------------- | -------------------------------------------------------------------------------------- |
| Generate the graph inside a build, not at evaluation | Evaluation stays non-blocking; no IFD and no committed generated Nix | Needs `recursive-nix` and a daemon inside the sandbox; the plan is a build product     |
| One derivation per object file                       | Object-level reuse across edits and projects                         | Many small derivations; a serialisation point at the planner                           |
| `gcc -MM` depfiles as the graph source               | No new discovery format; reuses what Make already needs              | Bound to depfile syntax and to the parser's shortcuts                                  |
| Per-object `fs.toSource` fileset                     | Source closure equals the declared edges; the sandbox enforces them  | Every header must be named; misses and collisions surface late                         |
| `builtins.outputOf` instead of an inner `nix build`  | The daemon continues into the generated derivation itself            | Experimental feature; opaque failures; store/daemon configuration becomes load-bearing |
| Makefile keeps its own `all`/`main` rules            | The project still builds without Nix                                 | Two execution paths that can drift (`deps` is only first so it becomes the default)    |

## Sources

- [`fzakaria/MakeNix`][repo] at `5c03fb1fe4d9942fc2cb124d45021c46adf46ef4`,
  clone at `$REPOS/build-systems-research/src/makenix` (shallow, one commit, no
  tags). Opened: `README.md`, `Makefile`, `default.nix`, `parser/parser.go`,
  `parser/derivation.gotmpl`, `LICENSE`, `.gitignore`, all five `src/` files.
- `NixOS/nix` at `1ed54a0fd62da96d4f5e9c806555861e46f65341` (read through the
  local clone, which is a fork): `src/libexpr/primops.cc` (`prim_outputOf`) and
  `src/libexpr/parser.y` (`LET binds IN_KW`, `binds1`).
- The author's companion post, `_posts/2025-03-11-nix-dynamic-derivations-a-practical-application.md`
  in [`fzakaria.com`][post] at `e4744a01435947269383d8ee92064ba59b3440a1`,
  linked from the README. Used for observed rebuild behaviour and `.drv` hashing;
  quoted text there is the author's, not the repository's.
- Background: [nix-thesis], [concepts], [nix-ninja], [nix-cargo-unit],
  [nixception], [sandstone], [content-addressing].

<!-- References -->

[repo]: https://github.com/fzakaria/MakeNix
[readme]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/README.md
[makefile]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/Makefile
[default-nix]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/default.nix
[parser-go]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/parser/parser.go
[template]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/parser/derivation.gotmpl
[license]: https://github.com/fzakaria/MakeNix/blob/5c03fb1fe4d9942fc2cb124d45021c46adf46ef4/LICENSE
[nix-primops]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libexpr/primops.cc
[nix-parser]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libexpr/parser.y
[post]: https://github.com/fzakaria/fzakaria.com/blob/e4744a01435947269383d8ee92064ba59b3440a1/_posts/2025-03-11-nix-dynamic-derivations-a-practical-application.md
[concepts]: ./concepts.md
[nix-thesis]: ./nix-thesis.md
[nixception]: ./nixception.md
[nix-ninja]: ./nix-ninja.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[sandstone]: ./sandstone.md
[content-addressing]: ../content-addressing/index.md
