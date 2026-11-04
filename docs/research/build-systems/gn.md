# GN (C++ generator)

GN's engine in one sentence: a whole-tree, closed-world evaluator that reads every
`BUILD.gn` into one label-and-toolchain-indexed target graph and **writes** a Ninja
plan — it schedules nothing, caches nothing, and makes no rebuild decision about a
build output, so it occupies no scheduler × rebuilder cell.

**Last reviewed:** November 2, 2026

| Field                 | Value                                                                                                 |
| --------------------- | ----------------------------------------------------------------------------------------------------- |
| Language              | C++ (needs a C++23 compiler); the build DSL is GN's own dynamically-typed language                    |
| License               | BSD 3-Clause (`LICENSE`, "Copyright 2015 The Chromium Authors")                                       |
| Repository            | [`gn.googlesource.com/gn`][repo]; review at `gn-review.googlesource.com`                              |
| Documentation         | [`docs/reference.md`][ref] (all `gn help` concatenated), [`docs/language.md`][lang]                   |
| Category              | Generator / meta-build system; engine companion to [GN (monorepo-tooling)][mono-gn]                   |
| Clone (pinned)        | `$REPOS/build-systems-research/src/gn`                                                                |
| Commit                | `ed7fee04cb30b96ed40ef188acfad5417349e399` (2026-10-30); **the clone has no tags**                    |
| Scheduler × rebuilder | Not a cell: GN emits the task description; run by Ninja it is topological × verifying traces          |
| Output IR             | `build.ninja`, `build.ninja.d`, `build.ninja.stamp`, plus per-toolchain and per-target `.ninja` files |

> [!NOTE]
> **Delta against the workspace page.** [GN (monorepo-tooling)][mono-gn] covers the
> GN + Ninja pair from the workspace side: the `.gn` root marker, `BUILD.gn` targets
> and labels, `configs`/`public_configs` propagation, `declare_args()`/`args.gn`,
> `gn refs` as an affected-target slicer, and the `Siso` migration. This page stays
> inside the generator: the builder's generation bit, toolchain labels, regeneration.

## Overview

### What it solves

Chromium-shaped trees: one tree, tens of thousands of files, a dozen platform
configurations, and mostly non-build-engineers editing `BUILD.gn`. GN answers with a
_compiler_ for build descriptions:

> "GN is a meta-build system that generates build files for
> [Ninja](https://ninja-build.org)."
>
> — [`README.md`][readme]

All policy and human-facing syntax live in GN; scheduling, `mtime` comparison and
parallel dispatch live in Ninja, which the [Ninja manual][ninja-manual] calls an
"assembler". GN never has to be fast at _deciding_, only at _evaluating_.

### Design philosophy

GN is under-powered on purpose:

> "Writing build files should not be a creative endeavour. Ideally two people
> should produce the same buildfile given the same requirements. There should be
> no flexibility unless it's absolutely needed. As many things should be fatal
> errors as possible."
>
> — [`docs/language.md`][lang]

Hence a poor language (no user-defined functions), a **closed, static graph** whose
every edge is declared in the file defining the target, and correctness settled at
generate time: `visibility`, `testonly`, `assert_no_deps` and the generated-input check
fail `gn gen`, header permissions fail `gn check`. The README calls GN "minimally
expressive" and "not easily composable" ([`README.md`][readme]).

## How it works

### The pipeline is a compiler

`gn gen out/Default` is one evaluation and one emission. The **dotfile** (`.gn`, found
walking up from `cwd`) marks the source root and names a required `buildconfig`
([`setup.cc`][setup]). The **loader** evaluates the build config once per toolchain and
loads a `BUILD.gn` at most once per toolchain — the key is literally
`LoadID(file, toolchain_name)` ([`loader.cc`][loader]). The **builder** resolves labels,
propagates `configs` and pushes a `should_generate` bit back through the graph
([`builder.cc`][builder]); as each target _finalizes_, a per-target writer on a worker
thread returns a rule block or writes its own `.ninja` file ([`command_gen.cc`][gen]).
Nothing survives the process: a `gn gen` is a pure function of (tree, `args.gn`, `.gn`,
GN binary). The generation bit is what makes the world closed
([`builder_record.h`][record]):

> "The record's should_generate() flag is set to true to indicate that a
> corresponding Ninja build statement should be generated for the item. By
> default, it is set to true for all targets defined in BUILD.gn files evaluated
> in the default toolchain, and only for targets reachable from the root in other
> toolchains."

### A label is a name plus a toolchain

`Label` is always absolute and always carries a name (`//base` is `//base:base`); a
parenthesised suffix names the toolchain, as in
`//base/test:test_support(//build/toolchain/win:msvc)`, and an absent toolchain means
the current one ([`label.h`][label]).

> "You can have more than one toolchain in use at once in a build and a target can
> exist simultaneously in multiple toolchains. A build file is executed once for
> each toolchain it is referenced in so the GN code can vary all parameters of
> each target (or which targets exist) on a per-toolchain basis."
>
> — [`docs/reference.md`][ref]

A `toolchain()` holds named `tool`s (`cc`, `cxx`, `alink`, `solink`, `link`, `stamp`,
`action`, …), each a command template with `outputs`, `depfile`, `depsformat`,
`restat`, `pool` and `command_launcher`. That table is the task description GN
compiles, and there is no default compiler configuration
([`examples/simple_build`][ex-tc]).

### The generated plan, and the loop back

`build.ninja` is mostly a loader: `ninja_required_version` (default `1.7.2`), pools,
one `subninja` per toolchain with the default first, phony aliases, the implicit
`all`, and the regeneration edge — `build build.ninja.stamp: gn` with `generator = 1`
and `depfile = build.ninja.d`, then `build build.ninja: phony build.ninja.stamp`
([`ninja_build_writer.cc`][nbw]). The indirection exists because Ninja deletes a
depfile-listed output when an edge is interrupted, so `build.ninja` stays a phony.

Regeneration is restartable because `build.ninja.d` is rewritten _first_ with a dummy
dependency — "Write a .d file for the build which references a nonexistent file. This
will make Ninja always mark the build as dirty" ([`commands.cc`][commands]). Per-target
`.ninja` files are compared byte-for-byte and left untouched when equal, while
`build.ninja` is written unconditionally ([`ninja_target_writer.cc`][ntw]), and every
emitted list is sorted.

## Analysis spine

### Placement in the scheduler × rebuilder grid

GN does not occupy a cell in [concepts] §5. That table classifies _engines_ — a
scheduler composed with a rebuilder — and GN is neither: it runs to completion over a
closed graph and exits. It is the **task-description compiler** of the pair
(`Task c k v` → a `build.ninja` plan), so its constraint is `Applicative` in the
[concepts] §1 sense. Its one edge, `build.ninja.stamp: gn` over `build.ninja.d`, is a
plain mtime dirty bit. Run by Ninja the pair lands in topological × verifying traces,
since [concepts] places `Ninja` there on the strength of `.ninja_log`'s command hash.

### 1. Task model & scheduling

- **The task description is the tool table plus the target.** A `static_library` or
  `executable` names sources and deps; the toolchain supplies command, output naming,
  depfile convention, pool and launcher, and the only per-target hook is `action`. Its
  own parallelism is confined to evaluation, overridable with `--threads`
  ([`worker_pool.cc`][pool]).
- **Static dependencies only.** The one dynamic edge is an `action` depfile, which GN
  forwards to Ninja and never interprets — it "should be used only when a target
  depends on files that are not already specified" ([`docs/reference.md`][ref]).

### 2. Rebuilding & correctness

- **No rebuild decision for build outputs.** GN never compares input to output, never
  hashes a source, never reads `.ninja_log`; every invocation re-evaluates the whole
  tree. Its own regeneration is a dirty bit over an _observed_ input set: `build.ninja.d`
  lists every file GN physically opened, plus paths registered by `exec_script`,
  `read_file`, `write_file` and `expand_directory` ([`scheduler.h`][scheduler]).
- **Early cutoff happens twice, by content, never by hash.** Unchanged `.ninja` files
  keep their mtimes, so Ninja's dirty check does not fire; and `restat = 1` on actions
  re-stats the output so an unmoved timestamp does not cascade.
- **Correctness is checked before emission.** Duplicate definitions, unresolvable
  labels, cycles and a generated input whose generator is not a dep are all fatal
  ([`command_gen.cc`][gen]).

### 3. Dependency discovery

- **Declared, with two narrow exceptions.** `sources`, `inputs`, `public`, `data` and
  `deps` are literal lists or filter products; there is no syscall interception, no
  FUSE and no sandbox observation in `src/gn`. Header dependencies come from Ninja
  reading `depfile`/`depsformat` at build time.
- **Observed once, at the parser.** GN's own reads are recorded — the regeneration
  depfile is built from what the evaluator opened — but a script's reads are invisible,
  so `exec_script` takes an explicit `file_dependencies` list
  ([`docs/reference.md`][ref], [`function_exec_script.cc`][exec-script]).
- **Strict-deps pruning is opt-in.** `check_includes_strict` stops public headers from
  including private `deps` and stops dependents reaching a strict target's
  `public_deps` — "they must depend on those targets directly"
  ([`docs/reference.md`][ref]).

### 4. Store & caching

Absent by construction: no CAS, no action cache, no `.ninja_log` reader and no remote
client. The output directory is the cache, Ninja owns its lifetime, and the one
storage-shaped lever is `no_stamp_files`, which swaps stamp nodes for phony rules —
"smaller Ninja build plans" ([`setup.cc`][setup]).

### 5. Hermeticity & provenance

No sandbox, no namespaces, no `ptrace`, no environment scrubbing: `action` commands are
ordinary child processes in the build directory, and an undeclared read simply
succeeds. Hermeticity comes from the declaration side.

| Check                      | Fails at | What it enforces                                             |
| -------------------------- | -------- | ------------------------------------------------------------ |
| `visibility`               | `gn gen` | which labels may depend on this target                       |
| `assert_no_deps`           | `gn gen` | a pattern absent from the whole transitive closure           |
| `testonly`                 | `gn gen` | test-only targets unreachable from production targets        |
| generated-input check      | `gn gen` | a generated file is an input only if its generator is a dep  |
| `gn check` / `gen --check` | check    | an `#include` is reachable via `public_deps`, or is `public` |

The header checker is a reachability query, not an edge comparison: it scans the top of
each C-like source for includes, maps each to the target owning the file, then BFSes
from the including target across `public_deps` only, keeping breadcrumbs so a violation
prints the shortest offending chain ([`header_checker.cc`][hc],
[`command_check.cc`][check]). It is approximate by design — "GN only knows about files
declared in the "sources" and "public" sections of targets"
([`docs/reference.md`][ref]) — with `// nogncheck` as the escape. Provenance: nothing.
No `SLSA` or `in-toto` in the clone; reproducibility exists only as _deterministic
emission_.

### 6. Distribution

Absent from the engine, and the absence has a documented shape: remote execution enters
through the toolchain's `command_launcher` — "The prefix with which to launch the
command (e.g. the path to a Goma or CCache compiler launcher)"
([`docs/reference.md`][ref]). A string in a tool definition: no hash, no action
identity, no protocol.

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a static in-process DAG — GN's shape — so the
borrowings concern validation and emission, not scheduling.

- **Validate the graph before running it.** GN's fatal-batch model is cheaper to adopt
  than an incremental one, and its generated-input rule is one reverse-index pass.
- **Separate "may depend" from "does depend".** `visibility` plus `public` as an include
  allowlist is a two-line policy with disproportionate effect; `public = []` — no
  compile-time deps propagate upward — is its sharpest form, _unlocking_ parallelism.
- **What not to copy.** Per-toolchain instantiation multiplies every node and error by
  the toolchain count; it pays for cross-compiled C++ and would be pure cost in a
  single-target D build.

## Strengths

- **The graph is a value, computed before anything runs.** Cycles, missing labels,
  duplicates and undeclared generated inputs all fail `gn gen` with origins and an
  `a -> b -> a` path.
- **Validation without a sandbox.** `visibility`, `public`, `assert_no_deps`, `testonly`
  and the header checker catch what a hermetic engine would surface as cache misses.
- **Graph queries are first-class.** `desc` (`--tree`, `--blame`), `refs` (reverse deps
  from a file or label), `path`, `ls --as=output`, `outputs`, `meta`, and `analyze` — a
  JSON file-list → affected-targets service.

## Weaknesses

- **No incrementality of its own.** Every `gn gen` re-evaluates the whole tree: seconds
  per `BUILD.gn` edit, paid on every build because Ninja re-invokes it.
- **No content hashing anywhere.** Change detection is mtime in GN and in Ninja; a
  touched-but-identical file costs a full re-evaluation, and nothing keys a cache.
- **No sandbox, hence no read observation.** An `exec_script` that forgets
  `file_dependencies` yields a silently stale `build.ninja`.
- **No versioning and no tags.** The README says GN "has no branches or versioning
  scheme beyond the sequence of commits to the main git branch".

## Key design decisions and trade-offs

| Decision                                           | Rationale                                                              | Trade-off                                                          |
| -------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Generator only; never runs a compile               | All policy in a legible DSL, all speed in a minimal executor           | Two binaries, a generate-then-build step, an IR nobody hand-writes |
| Closed world: every dependency declared in-tree    | The whole graph is checkable before any work starts                    | No registry, resolver or lockfile; vendoring is a separate tool    |
| Toolchain as a second axis on every label          | One evaluation emits host + device + kernel graphs from the same files | Node count and error repetition multiply by toolchain count        |
| Regeneration as an mtime edge over observed inputs | GN knows which files it read, so the depfile is precise for free       | Scripts must self-declare reads; a stale plan is silent            |
| Correctness at generate/check time, not by sandbox | Zero runtime cost, and errors name the offending label chain           | Undeclared reads and unlisted headers stay invisible               |
| `gn check` as a BFS over `public_deps`             | Catches include-graph violations a compiler cannot                     | Approximate: unknown files pass; needs `nogncheck` escapes         |

## Sources

- [`gn.googlesource.com/gn`][repo] at commit
  `ed7fee04cb30b96ed40ef188acfad5417349e399` (2026-10-30), clone at
  `$REPOS/build-systems-research/src/gn`; quotes are verbatim from the cited files.
- Read in the clone: [`README.md`][readme], [`docs/language.md`][lang],
  [`docs/reference.md`][ref]; `setup.cc`, `loader.cc`, `builder.cc`,
  `builder_record.h`, `label.h`, `command_gen.cc`, `ninja_build_writer.cc`,
  `ninja_target_writer.cc`, `commands.cc`, `scheduler.h`, `command_check.cc`,
  `header_checker.cc`, `function_exec_script.cc` (under `src/gn/`), `worker_pool.cc`
  (under `src/util/`), and [`examples/simple_build`][ex-tc].
- Siblings: [concepts], [bazel], [buck2]; workspace views [GN][mono-gn] and
  [Ninja][mono-ninja].

<!-- References -->

[repo]: https://gn.googlesource.com/gn
[readme]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/README.md
[ref]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/docs/reference.md
[lang]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/docs/language.md
[setup]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/setup.cc
[loader]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/loader.cc
[builder]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/builder.cc
[record]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/builder_record.h
[label]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/label.h
[gen]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/command_gen.cc
[nbw]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/ninja_build_writer.cc
[ntw]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/ninja_target_writer.cc
[commands]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/commands.cc
[scheduler]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/scheduler.h
[pool]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/util/worker_pool.cc
[check]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/command_check.cc
[hc]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/header_checker.cc
[exec-script]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/function_exec_script.cc
[ex-tc]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/examples/simple_build/build/toolchain/BUILD.gn
[ninja-manual]: https://ninja-build.org/manual.html
[concepts]: ./concepts.md
[bazel]: ./bazel.md
[buck2]: ./buck2.md
[mono-gn]: ../monorepo-tooling/gn/
[mono-ninja]: ../monorepo-tooling/ninja/
