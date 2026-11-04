# Compile-Time Execution (Theme)

Every build system eventually runs code that is not the build system: an
interpreter inside the compiler, a helper program before the compile, a plugin
loaded into the compiler process, or a graph generator that runs before the graph
exists. These share a name and almost nothing else — in particular they do **not**
share a hermeticity story. The thesis: compile-time execution moves work to a
place the build graph cannot see, so its hermeticity is a property of the
language or of the sandbox, never of the graph.

**Last reviewed:** November 2, 2026

| Field      | Value                                                                                                                         |
| ---------- | ----------------------------------------------------------------------------------------------------------------------------- |
| Category   | Theme — cross-cutting; no single system                                                                                       |
| Question   | What runs at build time besides the declared actions, and what does each position cost in correctness, caching and isolation? |
| Mechanisms | CTFE, `comptime`, string imports, `build.rs`, proc macros, `build.zig`, `exec_script`, `run_command`, IFD, repository rules   |
| Systems    | D (`dmd`/`dub`), Rust (`cargo`/`rustc`), Zig, Bazel, GN, Meson, Nix                                                           |
| Vocabulary | [concepts] — _scheduler_, _rebuilder_, _trace_ and _hermeticity_ are used as defined there, not redefined here                |

## Overview

A static rule can only name inputs it already knows. Generated source,
host-dependent configuration, probing for a library and compile-time-dependent
code all defeat that — and each is easier to express in the language at hand than
as a separate declared tool, giving a spectrum from "the compiler evaluates a
restricted subset of its own language" to "an arbitrary host program runs before
anything is scheduled".

The first camp removes capability until the execution cannot escape:

> "Functions which are both portable and free of global side-effects can be
> executed at compile time."
>
> — D specification, [CTFE][d-ctfe]

> "All function calls cause the compiler to interpret the function at
> compile-time, emitting a compile error if the function tries to do something
> that has global runtime side effects."
>
> — Zig language reference, [`comptime`][zig-langref]

The second keeps the host language and accepts the consequences:

> "Procedural macros run during compilation, and thus have the same resources
> that the compiler has. […] Similarly, file access is the same. Because of this,
> procedural macros have the same security concerns that [Cargo's build
> scripts][cargo-build-scripts] have."
>
> — Rust Reference, [procedural macros][rust-ref-proc]

D and Zig make the _interpreter_ safe and give up arbitrary codegen; Rust makes
codegen arbitrary and gives up the guarantee, delegating containment to whatever
runs `rustc`.

## Five positions, not one feature

| Position                  | Runs where                                    | A graph node?                                    | Examples                                                                       |
| ------------------------- | --------------------------------------------- | ------------------------------------------------ | ------------------------------------------------------------------------------ |
| In-compiler interpreter   | inside the compiler, over a restricted subset | no — inside one compile action                   | D CTFE, Zig `comptime`                                                         |
| Pre-build host program    | separate process, before the dependent action | yes, if the engine models it                     | Cargo `build.rs`, dub `preBuildCommands`                                       |
| Compiler plugin           | host code loaded into the compiler process    | the plugin crate is a dependency; the run is not | Rust procedural macros                                                         |
| Graph/workspace generator | host process before the graph exists          | no — it _is_ the configuration                   | Zig `build.zig`, GN `exec_script`, Meson `run_command`, Bazel repository rules |
| Build during evaluation   | the build engine, while evaluating            | yes — a derivation that blocks evaluation        | Nix import-from-derivation                                                     |

An engine can key, schedule and sandbox a node; it can do none of those to code
inside another node, and it cannot key code that ran before it built the graph.
**Catalog inference:** most "hermetic build" claims concern a position with no
node to attach a key to. In [concepts] terms the first three rows sit _below_ the
scheduler × rebuilder grid — an interpreter is inside the task body (the paper
has no term for it), a build script is a key whose value is a fragment of another
task's description, a plugin is a dependency whose execution is not a key — while
a graph generator makes the task description itself a program and IFD is a
`Monad` dependency discovered during evaluation.

## Rust: `build.rs`, a program that emits part of the task description

Cargo runs `build.rs` before compiling its package, and the script's product is
not a file but **a fragment of the compiler invocation**:

> "Placing a file named `build.rs` in the root of a package will cause Cargo to
> compile that script and execute it just before building the package. […] It
> will then run the script, which may perform any number of tasks."
>
> — Cargo, [Build Scripts][cargo-build-scripts]

The script prints `cargo::rustc-link-lib`, `rustc-link-search`, `rustc-cfg`,
`rustc-env` and `metadata` lines; Cargo turns them into `rustc` arguments and
`DEP_<LINKS>_*` variables for dependents ([cargo-build-scripts]). That is why it
runs _before_ the compile and why its output is not a sibling artifact: it is a
monadic step in the compile task's description.

Cargo's one stated constraint on the script's reach is normative, not enforced:
scripts "should not modify any files outside of that directory" — `OUT_DIR` — and
`OUT_DIR` is not cleaned, so "its contents may persist across rebuilds"
([cargo-build-scripts], [cargo-env]). A text search of Cargo's reference for
"sandbox" returns nothing: the script inherits environment, filesystem and
network, and Cargo documents what it _provides_, not what it _prevents_
([cargo-env]).

Change detection is correspondingly coarse. By default Cargo re-runs the script
"if any of the files in the package changes"; `rerun-if-changed` narrows that to
a path list, but "Cargo only uses the filesystem last-modified 'mtime'
timestamp". `rerun-if-env-changed` covers env reads, with a sharp edge: the
variables are "those received by `cargo` invocations, not those received by the
executable of the build script" ([cargo-build-scripts]) — so a script reading
`$HOME/.config/toolchain` without declaring it is invisible to the rebuilder.

**Granularity.** Cargo's unit graph separates `custom-build` (compile the script)
from `run-custom-build` (run it), and [nix-cargo-unit] makes each its own
derivation so an expensive script is cacheable independently — the best available
treatment of the position: give it a node.

## Rust: procedural macros, host code inside the compiler

A procedural macro is a `proc-macro` crate whose annotated functions the compiler
loads and calls with a token stream; the macro runs in the compiler's process, so
a filesystem sandbox around the action cannot separate its reads from `rustc`'s
([rustc-guide-macro]). The ecosystem knows it:

> "This is a tracking issue for `proc_macro::tracked*`, to allow adding files and
> environment variables to the build system's dependency tracking."
>
> — rust-lang/rust [#99515][proc-tracked]

One rustc contributor describes the status quo as an **"implied (unenforced)
sandbox"**. The feature has been tracked since 2022 and was still unstable in
2026; until it lands, a macro's env and file reads are not in `rustc`'s dep-info,
hence not in Cargo's key. Built-in macros do better — `env!` and `option_env!`
"automatically detect changes and trigger rebuilds" ([cargo-build-scripts]) —
which is exactly the gap: the built-in path is tracked, the plugin path is not.
rust-analyzer and IntelliJ Rust already work with macros through a separate
`rust-analyzer-proc-macro-srv` component ([rustc-guide-build]) — isolation `rustc`
itself does not provide.

**Host/target split.** A macro is a _host_ artifact even when the crate is
cross-compiled: rustc-dev-guide warns that building for another target still
requires host support "if you want the resulting compiler to be able to build
crates that involve proc macros or build scripts" ([rustc-guide-build]).
Compile-time execution therefore introduces a second platform into an otherwise
single-platform graph.

## D: CTFE, a hermetic interpreter, and `import()` as a rooted file read

D's CTFE is the strongest language-level guarantee here. The specification lists
the triggering contexts (`static` initializers, manifest constants, array
dimensions, template value parameters, `static if`, `static foreach`, `static
assert`, `mixin`, `pragma` arguments) and the restrictions that make it safe: the
function's source must be available, so "Functions which exist in the source code
only as `extern` declarations cannot be executed in CTFE"; "Executed expressions
may not reference any global or local static variables"; `asm`, non-portable
casts and union punning are forbidden ([d-ctfe]).

Since every syscall in D bottoms out in an `extern` declaration, **CTFE cannot
perform I/O, read the environment, or open a socket** — not because a sandbox
denies it, but because the interpreter cannot express it. `__ctfe` selects a
different path and is resolved before code generation ([d-ctfe]). CTFE is
therefore invisible to the graph and needs to be: its inputs are the source and
the compiler, already in the compile action's key. Nor is it a code-generation
pipeline — a `mixin` produces source text that never becomes a file, so there is
no artifact to key separately and no generator edge to schedule.

`import("file")` is a different mechanism and should not be conflated with CTFE.
The compiler resolves the path and reads the file:

> "The text contents of the string are interpreted as a file name. The file is
> read, and the exact contents of the file become a string literal. […] Note that
> by default an import expression will not compile unless you pass one or more
> paths via the `-J` switch. […] This is a security feature."
>
> — D specification, [ImportExpression][d-import]

This is the only ecosystem here whose compile-time file read is **rooted by
default**: without `-J` the expression does not compile. The compiler also
reports what it read. `-deps` prints module dependencies including
"imports/file/version/debug/lib", and `-makedeps` emits a Makefile-compatible
rule whose "emitted dependencies are imported modules and imported string files
(via `-J` switch)" ([`cli.d`][dmd-cli]). A build engine consuming `-makedeps`
gets the string-import edges for free.

The hole is the lexer, not the interpreter: `__DATE__`, `__TIME__` and
`__TIMESTAMP__` are "the date of compilation", "the time of compilation" and "the
date and time of compilation" ([d-lex]). Any of them defeats reproducibility, and
no dependency edge can express a clock.

## Zig: `comptime` is hermetic, `build.zig` is not

Zig splits the positions more cleanly than any other ecosystem. `comptime` is an
interpreter with the shape of D's: no extern calls ("it doesn't make sense that a
program could call `exit()` (or any other external function) at compile-time"),
no runtime side effects, a branch quota instead of a timeout ([zig-langref]).
`@embedFile` and `@import` are the compiler's own reads; the path "is absolute or
relative to the current file, just like `@import`" — there is no `-J`-style root
switch, so containment is the build script's job ([zig-langref]). **Catalog
inference:** the `LazyPath` discipline in `std.Build` is what keeps those reads
inside the tree in practice.

`build.zig` is the opposite: a Zig program, compiled and run by the build runner,
with full host authority. The language reference advertises exactly the
capabilities that make it non-hermetic — "Executing build artifacts or
system-installed tools", "Capturing user-configured options" — and `std.Build`
documents the cost on the API itself:

> "This function introduces a system dependency, compromising reproducibility and
> making it more difficult to set up one's computer in order to build the
> project from source."
>
> — `std.Build.addSystemCommand`, [`Build.zig`][zig-build]

The guide repeats it — "system dependencies will make your project harder to
build for your users" — and warns that in-place generation (`UpdateSourceFiles`)
"should not be used during the normal build process", because "it will cause
caching and concurrency bugs" ([zig-buildsys]). The runner hashes its own
configuration, so `build.zig`, `build.zig.zon` and the options are part of the
key, while `--cache-poison` defaults to `pure` ("Avoid false positive cache
hits") for state the hash does not cover ([zig-buildsys]). Unlike Rust, Zig does
not load plugins into the compiler: C translation is a build step
(`b.addTranslateC`, `Step.TranslateC`) that runs clang over headers and emits a
Zig file, so the work has a node, a key and a place to fail
([`TranslateC.zig`][zig-translatec]).

## Configure-time scripts and evaluation-time builds

A graph generator that shells out is the same position as `build.zig`, one level
further from the language. GN's `exec_script` runs during `gn gen`; the evaluator
records its own reads but not the script's, so the script declares them: "a
script's reads are invisible, so `exec_script` takes an explicit
`file_dependencies` list" ([gn] §3, [`function_exec_script.cc`][gn-exec]).
Meson's `run_command` is the same shape with less ceremony — "you may want to get
extra data by running external commands", with an `env:` dictionary and a
`check:` flag ([meson-ext]) — and Meson has no sandbox and no read observation at
configure time ([meson] § Hermeticity & provenance). dub, the tool Sparkles uses,
exposes both hooks:
`preBuildCommands` are "Commands to execute prior to every build", and
`extraDependencyFiles` is "Files to check for rebuild dub project"
([`description.d`][dub-desc]). That last field is the tell: the engine cannot see
what a command read, so the recipe must name it. dub's up-to-date check folds
`sourceFiles`, `importFiles`, `stringImportFiles` and `extraDependencyFiles` into
one mtime comparison ([`build.d`][dub-build]) — a Make-shaped dirty bit over a
declared list, with the same blind spots.

Nix is the only surveyed system whose _evaluation-time_ execution runs inside the
sandbox, because it makes the execution a derivation:

> "When the store path needs to be accessed, evaluation will be paused, the
> corresponding store object realised, and then evaluation resumed."
>
> — Nix manual, [Import From Derivation][nix-ifd]

The price is in the same section: "Evaluation can only finish when all required
store objects are realised. Since the Nix language evaluator is sequential, it
only finds store paths to read from one at a time" ([nix-ifd]). IFD is the mirror
of `build.zig`: both run code to learn the graph, but IFD's code is a hashed,
sandboxed derivation that blocks evaluation, while `build.zig`'s code is an
unhashed host process that _produces_ the graph. Nix lets you forbid it
(`allow-import-from-derivation = false`) and get a complete plan before any
realisation ([nix-ifd]); [nix-dynamic-derivations] covers the successor design.

Bazel's repository rules are the other end: non-hermetic by construction, and
deliberately outside the action sandbox. `repository_ctx` exposes "non-hermetic
functions (finding a binary, executing a binary, creating a file in the repository
or downloading a file from the Internet)" ([bazel-repo]). Bazel bounds the damage
with an explicit re-fetch trigger list — attributes, rule code, `getenv()`/
`environ` variables, `watch`ed paths, `bazel fetch --force` — and nothing else
([bazel-repo]). `genrule` is the in-graph counterpart and is honest: referencing
`PATH` programs "makes the command non-hermetic", and "A genrule command should
not access the network […] though this is not currently enforced"
([bazel-genrule]).

## Hermeticity holes, as documented

"Full" means the mechanism inherits the ambient capability and no document denies
it.

| Ecosystem / position | Environment                     | Filesystem                                               | Network                  | Clock / random       |
| -------------------- | ------------------------------- | -------------------------------------------------------- | ------------------------ | -------------------- |
| Cargo `build.rs`     | full inherited + `CARGO_*`      | full; "should not modify" outside `OUT_DIR` (unverified) | not mentioned            | full                 |
| Rust proc macro      | full (compiler's env)           | full ("file access is the same")                         | compiler's               | full                 |
| D CTFE               | none (no `extern`)              | none                                                     | none                     | none                 |
| D `import("…")`      | none                            | read-only, rooted at `-J`                                | none                     | none                 |
| Zig `comptime`       | none                            | compiler reads `@embedFile`/`@import`                    | none                     | none                 |
| Zig `build.zig`      | full                            | full                                                     | full (package fetch)     | full                 |
| Bazel repo rule      | `getenv`/`environ` only         | declared `watch`ed paths                                 | documented download      | full until re-fetch  |
| Bazel `genrule`      | sanitized `PATH`/`PWD`/`TMPDIR` | sandboxed when the strategy sandboxes                    | "not currently enforced" | full                 |
| GN `exec_script`     | full                            | full, plus declared `file_dependencies`                  | full                     | full                 |
| Meson `run_command`  | `env:` dictionary               | full                                                     | full                     | full                 |
| Nix IFD              | derivation's env                | derivation's sandbox                                     | derivation's sandbox     | derivation's sandbox |

The in-compiler rows are the only ones hermetic _by construction_; every other
row is hermetic only if the surrounding system sandboxes the execution, and most
do not. The network column is where documentation is thinnest: Cargo says
nothing, Bazel says "not currently enforced", and Nix is the only one that can
point at a mechanism.

## What the rebuilder must cover

A compile-time execution is correct to skip only if every input it read is in the
key, and the mechanisms differ in whether they can report those inputs. **D**
reports them: `-makedeps` lists imported modules and string-import files, and dub
separately declares `stringImportFiles` and `extraDependencyFiles` for its mtime
check ([dmd-cli], [dub-build]) — two lists that can disagree. **Rust** reports
built-in reads (`env!`, `include_str!`) through dep-info and build-script reads
through `rerun-if-*`, but only if the author declares them; proc-macro reads are
not reported until `tracked_env`/`tracked_path` stabilize ([proc-tracked]).
**Zig** hashes the build configuration and offers `--cache-poison` for the rest
([zig-buildsys]); **Bazel** re-fetches repository rules only on declared triggers
([bazel-repo]); **Nix** hashes the execution's inputs because the execution is a
derivation, at the cost of blocking evaluation ([nix-ifd]). Bazel states the same
rule from the other side: excluding data from an action key "later resulted in
expensive debugging sessions and bug fixes" ([bazel] §4). Tracing (Rattle, tup)
sidesteps declaration entirely, at the cost of an observation mechanism whose
blind spots are the subject of [sandboxing-overheads] ([perfect-dependencies]).

**Catalog inference:** the failure mode is asymmetric. A _missed_ input produces
a stale artifact that survives until someone cleans; a _spurious_ input only
costs a rebuild. Every ecosystem over-approximates where it can — the whole
package for Cargo's default, the whole source tree for Zig's configuration hash —
and under-approximates exactly where the author was asked to declare.

## Under sandboxing

**Inside a compiler** (proc macro, CTFE) the sandbox sees one process. For CTFE
that is harmless — the interpreter cannot issue a syscall. For a proc macro it
means the sandbox cannot distinguish macro reads from compiler reads, so
tightening it tightens `rustc` too; the IDE workaround (a separate
`proc-macro-srv` server) is the only real boundary in the ecosystem
([rustc-guide-build]).

**Before the compile** (`build.rs`, `preBuildCommands`) is sandboxable as an
ordinary action, and Nix does exactly that by making it a derivation; Cargo does
not. **Before the graph** (`build.zig`, `exec_script`, `run_command`, repository
rules) there is no action to sandbox yet, and sandboxing the generator would also
have to allow package fetching — which is why Zig's runner talks to the network
and why Bazel documents repository rules as non-hermetic ([bazel-repo],
[zig-buildsys]). **Inside evaluation** (IFD) the execution gets the same sandbox
as any derivation, plus `recursive-nix` when the build itself needs a daemon
([nix-dynamic-derivations]).

Two cautions from [sandboxing-overheads] apply. A **policy** mechanism (Landlock,
`seccomp`) can deny an undeclared read, but a denial is not a dependency edge —
the graph learns nothing, so the next build repeats the failure. And an
**observation** mechanism sees the process, not the plugin boundary: `ptrace` on
`rustc` records a proc macro's `open` calls as the compiler's — technically
complete, practically unusable as an edge set.

## Strengths

- **In-language evaluation is the cheapest hermetic codegen there is** — no
  subprocess, sandbox, declaration or separate key.
- **IFD keeps generated build expressions inside the store**, inheriting
  content addressing, sandboxing and cache substitution for the generator step.

## Weaknesses

- **Pure evaluation cannot cross the I/O boundary**: it cannot read an unmapped
  file, probe a library or fetch a schema, while IFD serializes evaluation —
  which is why Nix offers a switch to forbid it.
- **A build script rewrites its consumer's command line.** More expressive than a
  code generator and much harder to key: its output is a set of flags, and
  Cargo's mtime model is all that stands between it and a stale compile.
- **Plugin execution is the weakest position** — all the authority of a build
  script, none of the process boundary, and in Rust no stable dependency tracking
  for its reads.
- **Graph generators are configuration, not work**, so they cannot be cached by
  the graph they produce; the only sound policy is to hash them into every key.
  Zig does, Bazel approximates with re-fetch triggers, GN and Meson leave it to
  the user.

## Key design decisions and trade-offs

| Decision                                    | Rationale                                                     | Trade-off                                                         |
| ------------------------------------------- | ------------------------------------------------------------- | ----------------------------------------------------------------- |
| Restrict the interpreter (D, Zig)           | Hermeticity proved by the language, not configured            | No I/O, no discovery, no arbitrary codegen                        |
| Allow host code (Rust, Zig `build.zig`)     | Any generator works, including C toolchains and network fetch | Hermeticity becomes the caller's problem; keys miss reads         |
| Run the script as its own unit (Nix, Cargo) | Cacheable independently; a node the scheduler can order       | Reimplements the environment the tool expects ([nix-cargo-unit])  |
| Emit flags rather than files (`build.rs`)   | Fits linking and `cfg` into one pre-step                      | Output is not an artifact, so the key must cover the whole script |
| Root compile-time reads (`-J`)              | Path traversal cannot become a build input                    | Every legitimate new read needs a flag change                     |
| Track env/path explicitly (`tracked_env`)   | The compiler can report what a plugin read                    | Still unstable in 2026; plugins keep the unenforced default       |
| Build during evaluation (IFD)               | Execution is sandboxed and hashed like any derivation         | Evaluation blocks; discovery is sequential; nixpkgs rejects it    |
| Re-fetch on declared triggers (Bazel)       | Network and host probing stay out of the action graph         | Undeclared host state is invisible until `--force`                |

## Sparkles relevance

Sparkles is a D monorepo, so it gets the strongest position for free and should
lean on it before reaching for the weakest.

- **CTFE is a codegen tool with no build cost.** `libs/dql`'s `@ctfe` test
  forces schema generation through the interpreter ([`schema_ctfe_test.d`][sparkles-ctfe]);
  `libs/wired` uses `__ctfe` to select a compile-time path in shared code. No
  `build.rs`, sandbox or DAG task is needed — the source is the key.
- **String imports are the only compile-time file read, and they are declared.**
  `libs/twoslash`'s icons, `libs/ui`'s generated shaders and `libs/ui-app`'s
  `resilience.md` are `import()`-ed through `stringImportPaths` ([`icons.d`][sparkles-icons],
  [`ui/dub.sdl`][sparkles-ui-dub], [`ui-app/dub.sdl`][sparkles-ui-app-dub]).
  `dub_manifest` already parses `stringImportPaths` into `DubBuildSettings`
  ([`dub_manifest.d`][sparkles-manifest]); the task DAG does not yet turn those
  paths into input edges.
- **`libs/ui` is the case that will bite.** Its `gpu-effects` configuration runs
  a `preGenerateCommands` step that compiles `effect_shaders.d` through
  `apps/shader-compile` with `--if-stale`, writing GLSL into `generated/shaders`,
  and then puts that directory on the string-import path; the generated files are
  git-ignored ([`ui/dub.sdl`][sparkles-ui-dub]). A DAG that keys the `ui` compile
  without the generator edge compiles against stale or missing shaders — the
  exact "generated input whose generator is not a dep" failure GN makes fatal
  ([gn] §2). `--if-stale` makes it worse: the freshness decision lives inside the
  generator, where no graph can verify it.
- **Use the compiler's list, not a scan.** `dmd -makedeps` already reports
  "imported modules and imported string files (via `-J` switch)" ([dmd-cli]);
  consuming that depfile is cheaper and more precise than re-deriving the import
  graph, and matches [semantic-caching]'s conclusion that a compiler-emitted
  artifact beats a model reimplemented beside it.
- **Keep dub's escape hatch visible.** `preBuildCommands` and
  `extraDependencyFiles` exist because dub cannot observe what a command reads
  ([dub-desc]). If the DAG schedules those commands, it must treat the declared
  file list as the edge set rather than pretending the command is hermetic.
- **Do not copy Rust's position.** A proc-macro-style plugin inside the compiler
  costs the language guarantee, gains nothing over a separate generator step, and
  leaves the rebuilder with no stable way to learn what it read.

## Sources

In-corpus pages synthesized: [concepts] (scheduler × rebuilder grid; Nix as
suspending × deep constructive), [semantic-caching] (CTFE and `import` as inputs
an API hash would have to track), [sandboxing-overheads] (policy versus
observation; a deny is not an edge), [gn] (`exec_script`, `file_dependencies`,
the generated-input check), [meson] (configure-time execution, absent
hermeticity), [nix-dynamic-derivations] (IFD's successor), [nix-cargo-unit]
(`build.rs` as two derivations, `OUT_DIR` emulation), [perfect-dependencies]
(tracing as the alternative to declaration), [bazel] (action keys and hermeticity
tags).

Primary sources: Cargo `71b70c0` ([build scripts][cargo-build-scripts],
[build-script env][cargo-env]); rustc-dev-guide `646dd8e`
([macros][rustc-guide-macro], [building][rustc-guide-build]); Rust Reference
[proc macros][rust-ref-proc]; rust-lang/rust [#99515][proc-tracked]; D
[CTFE][d-ctfe], [ImportExpression][d-import], [special tokens][d-lex]; `dmd`
`e64474a` [`cli.d`][dmd-cli]; `dub` `5efed36` [`description.d`][dub-desc],
[`build.d`][dub-build]; Zig `8e8cf38` ([langref][zig-langref],
[`Build.zig`][zig-build], [`TranslateC.zig`][zig-translatec]) and the [build
system guide][zig-buildsys]; Bazel [repository rules][bazel-repo],
[genrule][bazel-genrule]; Nix [IFD][nix-ifd]; GN `ed7fee0`
[`function_exec_script.cc`][gn-exec]; Meson `27f69b2`
[External commands][meson-ext]; Sparkles [`icons.d`][sparkles-icons],
[`ui/dub.sdl`][sparkles-ui-dub], [`ui-app/dub.sdl`][sparkles-ui-app-dub],
[`schema_ctfe_test.d`][sparkles-ctfe], [`dub_manifest.d`][sparkles-manifest].

<!-- References -->

[concepts]: ./concepts.md
[semantic-caching]: ./semantic-caching.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[gn]: ./gn.md
[meson]: ./meson.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[nix-cargo-unit]: ./nix-cargo-unit.md
[perfect-dependencies]: ./perfect-dependencies.md
[bazel]: ./bazel.md
[cargo-build-scripts]: https://github.com/rust-lang/cargo/blob/71b70c095bb15e278ab9f0f808397c8033079888/src/doc/src/reference/build-scripts.md
[cargo-env]: https://github.com/rust-lang/cargo/blob/71b70c095bb15e278ab9f0f808397c8033079888/src/doc/src/reference/environment-variables.md
[rust-ref-proc]: https://doc.rust-lang.org/reference/procedural-macros.html
[rustc-guide-macro]: https://github.com/rust-lang/rustc-dev-guide/blob/646dd8e7b7d9cbde8662a04ebef6f560c79b6ccb/src/macro-expansion.md
[rustc-guide-build]: https://github.com/rust-lang/rustc-dev-guide/blob/646dd8e7b7d9cbde8662a04ebef6f560c79b6ccb/src/building/how-to-build-and-run.md
[proc-tracked]: https://github.com/rust-lang/rust/issues/99515
[d-ctfe]: https://dlang.org/spec/function.html#interpretation
[d-import]: https://dlang.org/spec/expression.html#ImportExpression
[d-lex]: https://dlang.org/spec/lex.html#special-tokens
[dmd-cli]: https://github.com/dlang/dmd/blob/e64474adc1f30abf7d959f1d96e9191063f5d36b/compiler/src/dmd/cli.d
[dub-desc]: https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/description.d
[dub-build]: https://github.com/dlang/dub/blob/5efed360e1c9342453bc5dd19339c75981526d83/source/dub/generators/build.d
[zig-langref]: https://github.com/ziglang/zig/blob/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/doc/langref.html.in
[zig-build]: https://github.com/ziglang/zig/blob/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build.zig
[zig-translatec]: https://github.com/ziglang/zig/blob/8e8cf3835a96a5c1ab72c1638e82f7a1f5d6032d/lib/std/Build/Step/TranslateC.zig
[zig-buildsys]: https://ziglang.org/learn/build-system/
[bazel-repo]: https://bazel.build/extending/repo
[bazel-genrule]: https://bazel.build/reference/be/general#genrule
[nix-ifd]: https://nix.dev/manual/nix/latest/language/import-from-derivation
[gn-exec]: https://gn.googlesource.com/gn/+/ed7fee04cb30b96ed40ef188acfad5417349e399/src/gn/function_exec_script.cc
[meson-ext]: https://github.com/mesonbuild/meson/blob/27f69b22e5fe403d3ec5788216adaa85046d0e8f/docs/markdown/External-commands.md
[sparkles-icons]: ../../../libs/twoslash/src/sparkles/twoslash/icons.d
[sparkles-ui-dub]: ../../../libs/ui/dub.sdl
[sparkles-ui-app-dub]: ../../../libs/ui-app/dub.sdl
[sparkles-ctfe]: ../../../libs/dql/test/sparkles/dql/schema_ctfe_test.d
[sparkles-manifest]: ../../../libs/build-primitives/src/sparkles/build_primitives/dub_manifest.d
