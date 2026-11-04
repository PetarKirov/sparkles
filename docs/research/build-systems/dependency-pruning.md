# Dependency Pruning (Theme)

Every edge in a build graph is a bet. **Pruning** settles those bets: it removes
an edge a target does not need, promotes one it needs but never declared, or
narrows an edge to the files an action actually read. It mirrors tracing — tracing
finds edges nobody wrote down, pruning deletes edges somebody did — and the two
meet in compiler depfiles, which are traces consumed specifically to prune.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                                      |
| ---------- | ---------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                    |
| Question   | Which declared edges are load-bearing, and what does removing the rest cost?                               |
| Operations | strict-deps enforcement, unused-declared audit, per-action/header refinement, reachability pruning         |
| Systems    | Bazel, Buck2, GN, Ninja, build2, tup, Please, Maven, Nix                                                   |
| Vocabulary | [concepts] — this page does not redefine _scheduler_, _rebuilder_, _trace_, _minimality_ or _early cutoff_ |

> [!NOTE]
> This page is about removing **dependency edges**. It does not cover link-time
> dead stripping or identical-code folding, which prune symbols inside a linked
> artifact, nor the tracing mechanisms that create edges in the first place.

## Overview

### What it solves

**Under-declaration** — using a header, class or crate without naming its target
— is a correctness bug hidden by a permissive classpath or a shared include
directory. **Over-declaration** — listing a dependency nothing in the target uses
— is a performance bug hidden by the fact that a build never complains about
unused edges. Rattle's abstract names both:

> "Most build scripts have both too few dependencies (leading to incorrect build
> outputs) and too many dependencies (leading to excessive rebuilds and reduced
> parallelism)."
>
> — Rattle abstract, quoted in [perfect-dependencies] §1

The fixes are not symmetric. A missing edge must be made loud, because a build
that succeeds without it is evidence of nothing; an extra edge must be made
visible, and removal is safe only once every other user of the target declares
its own direct edge — the reason Bazel's strict deps was introduced, "the ability
to remove unused dependencies" ([bazel-blog]). An audit without strictness can
break a downstream target; strictness without an audit leaves the graph too wide.

### Design philosophy

The commitments are: make the missing edge loud (Bazel's plugin, GN's checker,
tup's fatal undeclared read), make the extra edge visible (Bazel's `unused_deps`,
Maven's `dependency:analyze`, Buck2's Rust lint), and refine to what was read.

> "When every file includes what it uses, then it is possible to edit any file
> and remove unused headers, without fear of accidentally breaking the upwards
> dependencies of that file."
>
> — IWYU [`README.md`][iwyu]

## How it works — four pruning acts

| Act         | Question                                       | Finds                 | Systems                                     | Output                            |
| ----------- | ---------------------------------------------- | --------------------- | ------------------------------------------- | --------------------------------- |
| **Enforce** | Is every used symbol from a direct dependency? | a missing direct edge | Bazel (Java, C++ `layering_check`), GN, tup | compile/check error, with a fix   |
| **Audit**   | Was a declared dependency ever consulted?      | an extra direct edge  | Bazel, Buck2 (Rust), Maven                  | report, lint, or `buildozer` text |
| **Refine**  | Which inputs did this action actually read?    | extra per-file edges  | Bazel, Buck2, build2, Ninja, tup            | skipped action, smaller input set |
| **Drop**    | Is this node reachable from the request?       | extra nodes           | Please (`plz export`)                       | omitted target                    |

The first two acts operate on the declared target graph, the third on the action
graph after execution, the fourth on reachability. A depfile is not "strict
deps": it records what happened, not what should have been declared.

### 1. Enforce: make the direct edge mandatory

**Bazel, Java.** `--strict_java_deps` is the documented switch: "javac checks for
missing direct dependencies. Java targets must explicitly declare all directly
used targets as dependencies" ([`user-manual.mdx`][bazel-user-manual]). Values are
`off`, `warn` and `default`/`strict`/`error`, strict by default. Bazel passes the
whole transitive classpath to `javac`, so a symbol available transitively still
compiles; it then marks which jars are indirect. `StrictJavaDepsPlugin` walks the
attributed AST, names the missing target and emits a `buildozer 'add deps …'` fix
([`StrictJavaDepsPlugin.java`][bazel-sjd-plugin]). Dagger's `ComponentProcessor`
and Hilt's `RootProcessor` are hard-coded exemptions for generated code.

**Bazel, C++.** `layering_check` "enforces that targets only include headers
provided by their direct dependencies"; it works "on Linux with `clang` as the
compiler" and depends on module maps
([`bazel-and-cpp.mdx`][bazel-cpp], [`CppRuleClasses.java`][bazel-cpp-rules]).

**GN.** `gn check` scans the top of each C-like source and follows the declared
graph; `check_includes_strict` adds that dependents "cannot transitively include
headers from this target's `public_deps` (they must depend on those targets
directly)" ([`reference.md`][gn-reference]). Its error says "Please depend
directly on the destination target" and recommends strict checking "to ensure a
correct build graph" ([`header_checker.cc`][gn-header-checker]). It does not run
the preprocessor, so conditional includes are a blind spot; `nogncheck`,
`check_includes = false` and `allow_circular_includes_from` are the escape
hatches ([gn] §3).

**tup and Nix.** tup fails a generated read without a declared link, so the edge
set is whatever the process touched ([tup] §3). Nix fails an undeclared store
path by absence; `makenix` narrows the unit to "source plus exactly the named
headers" ([makenix] §3), while stock Nix's unit is the derivation's source
closure ([nix-thesis] §3). **Catalog inference:** Nix is strict at derivation
granularity, so over-declaration costs a cache miss, not correctness.

### 2. Audit: make the extra edge visible

**Bazel's two generations.** The original `unused_deps` (Go, in `buildtools`)
builds each Java target, reads `Foo.jdeps` and `Foo.jar-2.params`, finds direct
dependencies that never contributed a symbol, and prints Buildozer commands
([`unused_deps.go`][buildtools-unused-deps-go]); an entry commented "runtime"
moves to `runtime_deps`, and the usage warns "Note these may be used at run time"
([`unused_deps/README.md`][buildtools-unused-deps-readme]). The newer
`--experimental_check_unused_deps` lives in the Java builder and emits an
`[unused-deps]` message plus `buildozer 'remove deps …'`; the test suite drives it
via `java_package_configuration(unused_deps = "error")`, skips when released
`java_tools` lacks the flag, and disables it for external repositories
([`bazel_java_test.sh`][bazel-java-test]).

**Buck2, Rust.** Buck2 wires rustc's `unused_crate_dependencies` behind
`report_unused_deps` (default `False`), passing
`--json=unused-externs-silent -Wunused-crate-dependencies`;
`rustc_action.py` maps diagnostics back to BUCK entries for autofix
([`build.bzl`][buck2-rust-build], [`rustc_action.py`][buck2-rustc-action]).

**Maven.** `dependency:analyze` classifies "used and declared; used and
undeclared; unused and declared" ([`analyze-mojo.html`][maven-analyze]). It is
bytecode-based: `usedDependencies` overrides "incomplete result caused by
bytecode-level analysis", reflection-loaded deps are ignored, and
`ignoreNonCompile`/`ignoreUnusedRuntime` exclude scopes; `failOnWarning` defaults
to `false` ([`analyze-mojo.html`][maven-analyze]).

**Buildozer is the fixer.** It rewrites BUILD files in place, batches commands per
file and runs files in parallel ([`buildozer/README.md`][buildtools-buildozer]).

**Absences, catalog inference:** a tree-wide search finds no unused-dependency
analyzer in Please, and GN's checker asks whether an include is legally reachable,
not whether a declared target was ever included ([please] §3; [gn] §3).

### 3. Refine: tie the edge to what was read

A target edge says "`A` may use anything `B` exports"; if `A` uses one of forty
headers, a change to the other thirty-nine rebuilds it.

> "Dep files are used to make dependencies finer grained than what exists in the
> target graph, but they're not a substitute for avoiding unused dependencies."
>
> — Buck2 [`dep_files.md`][buck2-dep-files]

**Buck2.** Tag the covered inputs and the dep-file output, pass the tag to
`ctx.actions.run(..., dep_files = {...})`, and write one used path per line. On
invalidation, Buck2 reuses the result when every changed input is outside the
recorded set. Dep files are lazy, optionally covering (a subset is fine, but
every used input in it must appear), and daemon-scoped (flushed on restart, with
remote dep files keyed by VCS revision). The failure direction: "If you fail to
report some inputs you used, then your command will not re-run when they change,
and you'll get stale output" ([buck2] §3).

**Bazel.** C++ `.d` files are the same idea: "the compiler tells which header
files were used after the fact, and in order to avoid the embarrassment of having
worse incrementality than Make, Bazel makes use of this fact"
([`codebase.mdx`][bazel-codebase]). It also states the risk: "This can result in
incorrect incremental builds if a used input is reported as unused." Starlark
actions declare the set with `unused_inputs_list=`
([`StarlarkAction.java`][bazel-starlark-action]). The include scanner is the
pre-execution half, registering only headers mentioned in `#include` because "we
don't need to send every file to remote executors" and overestimating rather than
implementing a full preprocessor; the option is "hard-wired to 'false' in Bazel
and is only used at Google" ([bazel-codebase]).

**build2, Ninja, tup.** build2's `depdb` replays a recorded toolchain, option and
header list; a mismatch forces re-preprocess, and a header it did not report never
becomes an edge ([build2] §3). Mapping headers back to targets costs up to "50% of
an up-to-date check time on some projects" ([`compile-rule.cxx`][build2-compile-rule]).
Ninja reads depfiles into `.ninja_deps`; `-t missingdeps` diagnoses the
generated-file subset without failing ([ninja] §3). tup makes the read set the
graph, so "the graph prunes itself with no `makedepend` pass and no stale header
edge" ([tup] §3).

**IWYU and GN.** IWYU prunes `#include` lines with `fix_includes.py` and
`// IWYU pragma: keep`, but calls itself "experimental software" ([iwyu]). GN
prunes at declaration time: only headers reached through public dependency paths
may be included, which stops a transitive include becoming load-bearing
([gn] §3).

### 4. Drop: remove nodes that are not reachable

Please's `plz export` trims the exported package to what the requested targets
reach, and `--notrim` disables it ([`commands.html`][please-commands]).

## What pruning buys, as published

| Claim                                                                                      | Where it is stated                             | Evidence                  |
| ------------------------------------------------------------------------------------------ | ---------------------------------------------- | ------------------------- |
| Too many dependencies cause "excessive rebuilds and reduced parallelism"                   | Rattle abstract, via [perfect-dependencies] §1 | qualitative, no number    |
| Google's builds "started to slow down" and are "now much faster" after strict deps         | Bazel [`dependencies.mdx`][bazel-deps-doc]     | retrospective, no number  |
| Strict checking lets dependents "compile without waiting for this target's private `deps`" | GN [`reference.md`][gn-reference]              | mechanism, no measurement |
| Dep files "skip recompilation steps in C++ when an unused header changed"                  | Buck2 [`dep_files.md`][buck2-dep-files]        | mechanism, no measurement |
| Include scanning means "we don't need to send every file to remote executors"              | Bazel [`codebase.mdx`][bazel-codebase]         | mechanism, no measurement |

The only cost figures are adoption costs: strict transitive dependencies at
Google were "a multiyear effort" and made build files "more verbose"
([bazel-deps-doc]); Maven's `failOnWarning` default of `false` expresses the same
trade-off as a default ([maven-analyze]). No reviewed source measures pruning's
critical-path or percentage gain.

## Graph-concurrency effects, only as sourced

Two statements are direct. Rattle's abstract says too many dependencies lead to
"reduced parallelism" ([perfect-dependencies] §1); GN's reference says strict
headers let dependents "compile without waiting for this target's private `deps`"
([gn-reference]).

**Catalog inference:** deleting a precedence edge can only relax a fixed schedule,
but the realized makespan gain depends on the critical path, admission policy and
cache locality; no reviewed source publishes that decomposition. Strict deps can
also _add_ edges, so pruning is not monotonically graph-narrowing. The invariant
is that the edges left are real, not that there are fewer of them.

## Correctness risks

| Risk                                          | Mechanism                                                                                                     | Source                                       |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | -------------------------------------------- |
| An audit deletes a runtime-only dependency    | compile-time analysis cannot see reflection, service loaders or `Class.forName`                               | [buildtools-unused-deps-go]; [maven-analyze] |
| Bytecode analysis is incomplete               | Maven works "at bytecode level"; `usedDependencies` overrides its result                                      | [maven-analyze]                              |
| Annotation processors generate undeclared use | Bazel exempts Dagger's `ComponentProcessor` and Hilt's `RootProcessor`                                        | [bazel-sjd-plugin]                           |
| A depfile under-reports inputs                | "you'll get stale output" if a used input is missing from the recorded set                                    | [buck2-dep-files]                            |
| A `.d` file over-reports an input as unused   | Bazel: "This can result in incorrect incremental builds if a used input is reported as unused"                | [bazel-codebase]                             |
| A header checker cannot see the preprocessor  | GN: "GN does not run the preprocessor so will not understand conditional includes"                            | [gn-reference]                               |
| Escape hatches weaken the invariant           | `nogncheck`, `check_includes = false`, `allow_circular_includes_from` (GN); regex exclusions (tup)            | [gn-reference]; [tup] §3                     |
| Ignoring a dependency is dangerous            | tup: "You should only ignore dependencies with extreme caution. It is trivial to cause tup to fail to update" | [`tup.1`][tup-manual]                        |

**Catalog inference — under-pruning is safe; over-pruning is silent.** The audit
reasons from absence of a symbol in one compile, so a dependency used only through
configuration, reflection, a generated accessor or a non-default variant looks
unused. Bazel's `runtime_deps` move and Maven's reflection allowlist are the
documented repairs; neither generalizes. The false-positive cost compounds:
Maven leaves the check off by default, Buck2's `report_unused_deps` is `False`,
and Bazel's in-compiler check is `experimental`.

## Where the catalog's systems stand

| System | Strictness check                                | Unused-declared audit                     | Header/action refinement                     | Reachability pruning |
| ------ | ----------------------------------------------- | ----------------------------------------- | -------------------------------------------- | -------------------- |
| Bazel  | Java default; C++ `layering_check` opt-in       | Java: `unused_deps` and in-compiler check | C++ `.d`; `unused_inputs_list`; include scan | `buildozer remove`   |
| Buck2  | none documented in the reviewed tree            | Rust `report_unused_deps`, opt-in         | dep files                                    | none                 |
| GN     | `check_includes` / `check_includes_strict`      | none                                      | declaration-time header ownership            | none                 |
| Ninja  | `-t missingdeps` (diagnostic only)              | none                                      | depfile → `.ninja_deps`                      | none                 |
| build2 | none                                            | none                                      | `depdb` header list                          | none                 |
| tup    | observed reads; undeclared generated reads fail | none                                      | read set (`normal_link`)                     | none                 |
| Please | none                                            | none                                      | none                                         | `plz export` trim    |
| Maven  | none (compiler-level)                           | `dependency:analyze`                      | none                                         | none                 |
| Nix    | yes, at derivation granularity                  | none                                      | none                                         | store closure        |

## Strengths and weaknesses

- **Strict deps turns a global question into a local one.** "Can this dependency
  be removed?" no longer requires every transitive user of the target; the direct
  user must declare itself ([bazel-blog]).
- **The fix is part of the diagnostic.** Bazel emits the exact `buildozer add` or
  `remove` command, so error and repair are one artifact ([bazel-dep-module]).
- **Header/action refinement captures rebuild wins without touching build files**
  ([buck2-dep-files], [bazel-codebase]).
- **Enforcement is language-specific and audits are runtime-blind.** Java needs a
  compiler plugin, C++ Clang module maps, GN a source scanner, Nix a sandbox; the
  escape hatches are blind spots, and adoption is expensive ([bazel-deps-doc]).

## Key design decisions and trade-offs

| Decision                                       | Rationale                                                     | Trade-off                                                          |
| ---------------------------------------------- | ------------------------------------------------------------- | ------------------------------------------------------------------ |
| Enforce in the compiler, not in a graph pass   | Only the compiler knows which symbol came from which artifact | A plugin per language; generated code needs exemptions             |
| Emit a `buildozer` command from the diagnostic | The fix is mechanical and batchable                           | Tool output becomes part of the user interface, and can drift      |
| Audit declared deps separately from enforcing  | Unused deps are a performance problem, not a correctness one  | An audit without strictness can break downstream users             |
| Record a per-action read set after execution   | The compiler knows better than any include scanner            | Under-reporting is silent; storage is daemon-local unless uploaded |
| Keep declared dependencies authoritative       | Scheduling, sandboxing and remote execution consume one graph | Real edges the author forgot remain invisible to the engine        |

## Sparkles relevance

`sparkles.build_primitives.workspace.package_graph` builds the package graph from
declarations only: each package's in-tree dependencies come from its top level and
active configuration, optional inactive dependencies are left out, and unknown
dependencies, self-dependencies and cycles are validated
(`libs/build-primitives/src/sparkles/build_primitives/workspace/package_graph.d`).
The graph builder does not compare those edges with the modules a package
imports, and `sparkles.build_primitives.task` carries the edge reason
`packageDependency` without a verifier
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
An over-declared `dub.sdl` dependency is therefore a real scheduling edge, and an
under-declared one is invisible to the DAG.

The cheap port is the audit, not a tracer:

- **An import-versus-`dub.sdl` audit** would find declared in-tree dependencies
  no module imports. D's module imports make this syntactic, so it needs no
  symbol attribution; **catalog inference:** it would still miss `static this`,
  `mixin` and runtime-only uses, so it should report, not fail.
- **A strict-deps analogue** would flag an import of an in-tree module whose
  package is not a direct dependency — Bazel's SJD and GN's checker at module
  granularity.
- **Header-level refinement does not port yet**, because `dub` owns compilation
  and no Sparkles action records a read set. A future action that emits a compiler
  dependency report could reuse Buck2's rule: tag inputs, record the used subset,
  and skip a re-run when only the rest changed.

## Sources

**Pages synthesized.** [concepts] (declared versus recorded discovery),
[perfect-dependencies] §1/§5, [bazel] §3, [buck2] §3, [gn] §3, [ninja] §3,
[build2] §3, [tup] §3, [please] §3, [makenix] §3, [nix-thesis] §3.

**Primary sources.** Clones under `$REPOS/build-systems-research/src/` at manifest
SHAs, plus external sources fetched directly.

- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`: [`user-manual.mdx`][bazel-user-manual],
  [`dependencies.mdx`][bazel-deps-doc], [`codebase.mdx`][bazel-codebase],
  [`bazel-and-cpp.mdx`][bazel-cpp], [`StrictJavaDepsPlugin.java`][bazel-sjd-plugin],
  [`DependencyModule.java`][bazel-dep-module], [`CppRuleClasses.java`][bazel-cpp-rules],
  [`StarlarkAction.java`][bazel-starlark-action], [`bazel_java_test.sh`][bazel-java-test].
- Buildtools: [`unused_deps/README.md`][buildtools-unused-deps-readme] and
  [`buildozer/README.md`][buildtools-buildozer] at `82285db8e1af42013d863701e44735b1e07bdefe`;
  [`unused_deps.go`][buildtools-unused-deps-go] at the blog's pinned `799e5306`.
- Buck2 `08b403b138373f506de90d15370162677526e388`: [`dep_files.md`][buck2-dep-files],
  [`build.bzl`][buck2-rust-build], [`rustc_action.py`][buck2-rustc-action].
- GN `ed7fee04cb30b96ed40ef188acfad5417349e399`: [`reference.md`][gn-reference],
  [`header_checker.cc`][gn-header-checker]. Ninja `a7d7504e98d07f05a60f37411206907c00cb4ef7`:
  [`manual.asciidoc`][ninja-manual].
- build2 `adf7693d8521dff4c08d53889a43a173d76d6357`: [`compile-rule.cxx`][build2-compile-rule].
  tup `c6f565e216a0820e39d65fa84ddaf830be03a476`: [`tup.1`][tup-manual].
- Please `d7bea3388e4ddd311891d8ccccd2c53caae724cd`: [`commands.html`][please-commands].
- Maven Dependency Plugin 3.11.0: [`dependency:analyze`][maven-analyze]. IWYU
  `2412f05ba5dc4216d6d7c5d0d436fd2d688bb00a`: [`README.md`][iwyu].

<!-- References -->

[concepts]: ./concepts.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[gn]: ./gn.md
[ninja]: ./ninja.md
[build2]: ./build2.md
[tup]: ./tup.md
[please]: ./please.md
[makenix]: ./makenix.md
[nix-thesis]: ./nix-thesis.md
[perfect-dependencies]: ./perfect-dependencies.md
[bazel-blog]: https://blog.bazel.build/2017/06/28/sjd-unused_deps.html
[bazel-user-manual]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/docs/user-manual.mdx
[bazel-deps-doc]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/basics/dependencies.mdx
[bazel-codebase]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/contribute/codebase.mdx
[bazel-cpp]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/docs/bazel-and-cpp.mdx
[bazel-sjd-plugin]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/java_tools/buildjar/java/com/google/devtools/build/buildjar/javac/plugins/dependency/StrictJavaDepsPlugin.java
[bazel-dep-module]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/java_tools/buildjar/java/com/google/devtools/build/buildjar/javac/plugins/dependency/DependencyModule.java
[bazel-starlark-action]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/analysis/actions/StarlarkAction.java
[bazel-cpp-rules]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/main/java/com/google/devtools/build/lib/rules/cpp/CppRuleClasses.java
[bazel-java-test]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/src/test/shell/bazel/bazel_java_test.sh
[buildtools-unused-deps-readme]: https://github.com/bazelbuild/buildtools/blob/82285db8e1af42013d863701e44735b1e07bdefe/unused_deps/README.md
[buildtools-buildozer]: https://github.com/bazelbuild/buildtools/blob/82285db8e1af42013d863701e44735b1e07bdefe/buildozer/README.md
[buildtools-unused-deps-go]: https://github.com/bazelbuild/buildtools/blob/799e530642bac55de7e76728fa0c3161484899f6/unused_deps/unused_deps.go
[buck2-dep-files]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/docs/rule_authors/dep_files.md
[buck2-rust-build]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/prelude/rust/build.bzl
[buck2-rustc-action]: https://github.com/meta/buck2/blob/08b403b138373f506de90d15370162677526e388/prelude/rust/tools/rustc_action.py
[gn-reference]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/docs/reference.md
[gn-header-checker]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/header_checker.cc
[ninja-manual]: https://github.com/ninja-build/ninja/blob/a7d7504e98d07f05a60f37411206907c00cb4ef7/doc/manual.asciidoc
[build2-compile-rule]: https://github.com/build2/build2/blob/adf7693d8521dff4c08d53889a43a173d76d6357/libbuild2/cc/compile-rule.cxx
[tup-manual]: https://github.com/gittup/tup/blob/c6f565e216a0820e39d65fa84ddaf830be03a476/tup.1
[please-commands]: https://github.com/thought-machine/please/blob/d7bea3388e4ddd311891d8ccccd2c53caae724cd/docs/commands.html
[maven-analyze]: https://maven.apache.org/plugins/maven-dependency-plugin/analyze-mojo.html
[iwyu]: https://github.com/include-what-you-use/include-what-you-use/blob/2412f05ba5dc4216d6d7c5d0d436fd2d688bb00a/README.md
