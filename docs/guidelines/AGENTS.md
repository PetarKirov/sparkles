# Agent Guidelines for Sparkles

Instructions for AI agents working on the `sparkles` codebase. This file is the
single source of truth: the root `AGENTS.md` is a symlink to it, and `CLAUDE.md`
includes it. Keep it accurate — a stale fact here propagates into every agent's work.

## Project Overview

`sparkles` is a D monorepo of CLI/library utilities. The root `dub.sdl` declares
these sub-packages (plus the internal `sparkles:test-runner-impl` implementation
library backing `sparkles:test-runner` — see the runner integration notes below):

| Sub-package                 | Path                      | What it is                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| --------------------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `ci`                        | `apps/ci`                 | Repository CI helper: runs/verifies markdown examples, standalone examples, sub-package tests, and markdown link maintenance                                                                                                                                                                                                                                                                                                                             |
| `release`                   | `apps/release`            | Release automation: scans tags as SemVer, summarizes commits, suggests a bump, gathers notes ($EDITOR or a CLI LLM agent), tags and publishes                                                                                                                                                                                                                                                                                                            |
| `hue`                       | `apps/hue`                | Interactive syntax-highlighting file viewer / live theme previewer over `sparkles:syntax` (ANSI + HTML, plus an optional raylib `--gui` backend behind the `gui` build config, on `sparkles:raylib-text`; `--gui` also renders a render-markdown.nvim-style markdown preview — heading icons, callouts, task lists, box-bordered aligned tables via `sparkles:core-cli` — and native ANSI in ` ```ansi ` fences via an off-screen `sparkles:ghostty` VT) |
| `terminal`                  | `apps/terminal`           | Minimal raylib-based terminal emulator built on `sparkles:ghostty` and `sparkles:raylib-text`                                                                                                                                                                                                                                                                                                                                                            |
| `terminal-benchmark`        | `apps/terminal-benchmark` | Render-CPU benchmark harness for the `terminal` emulator (`/proc` CPU sampling; idle/render/churn scenarios)                                                                                                                                                                                                                                                                                                                                             |
| `sparkles:base`             | `libs/base`               | Allocation-conscious foundation utilities: `SmallBuffer`, lifetime helpers, `@nogc` text readers/writers, terminal styling, styled IES, and logging                                                                                                                                                                                                                                                                                                      |
| `sparkles:build-primitives` | `libs/build-primitives`   | Build-system and VCS primitives: `.gitignore` parsing/matching (nested + ancestor scopes) and a DbI-hook directory walker (`walkGitRepository`)                                                                                                                                                                                                                                                                                                          |
| `sparkles:core-cli`         | `libs/core-cli`           | CLI argument parsing, help formatting, UI components (table/box/header/tree/meter, live region + task list, OSC links, themes), interactive prompts, process utilities, terminal capability probing/unstyle helpers                                                                                                                                                                                                                                      |
| `sparkles:ghostty`          | `libs/ghostty`            | D bindings + ImportC integration layer for `libghostty-vt` (Ghostty's terminal VT engine)                                                                                                                                                                                                                                                                                                                                                                |
| `sparkles:math`             | `libs/math`               | Small math primitives for games/graphics (early stage)                                                                                                                                                                                                                                                                                                                                                                                                   |
| `sparkles:raylib-text`      | `libs/raylib-text`        | Reusable raylib text-rendering core shared by `apps/terminal` and `hue --gui`: a multi-face `FontSet` (real bold/italic variants, on-demand atlas growth, `--font-codepoint-map` routing), `drawGrapheme`/`drawSolid` + a per-run `drawText`, and procedural box-drawing (`drawBox`, so `─│┼╭…` connect across cells instead of using gappy font glyphs)                                                                                                 |
| `sparkles:syntax`           | `libs/syntax`             | Syntax highlighting: engine-agnostic highlight-event stream, scope-compatible label vocabulary, theme layer, ANSI + HTML renderers, tree-sitter precise-mode engine (design: `docs/specs/syntax/`), plus a structural markdown model (`md/model.d`, `extractMarkdown`) for preview renderers                                                                                                                                                             |
| `sparkles:test-runner`      | `libs/test-runner`        | General-purpose `unittest` runner (silly successor): parallel runtime tests plus `@ctfe`, `@betterC`, `@wasm`, and `@benchmark` modes                                                                                                                                                                                                                                                                                                                    |
| `sparkles:test-utils`       | `libs/test-utils`         | Testing helpers: diff tools, temp-filesystem helpers, string helpers                                                                                                                                                                                                                                                                                                                                                                                     |
| `sparkles:tree-sitter`      | `libs/tree-sitter`        | D bindings for the tree-sitter C runtime: ImportC surface, RAII wrappers with `TsError` reporting, grammar dlopen (grammars supplied by the nix `ts-grammars` bundle via `$SPARKLES_TS_GRAMMAR_PATH`)                                                                                                                                                                                                                                                    |
| `sparkles:versions`         | `libs/versions`           | Design-by-Introspection versioning library (SemVer, DMD, CalVer, PyPI, Maven, Deb, …) with VERS/pURL interop                                                                                                                                                                                                                                                                                                                                             |

Each library **should** be documented under `docs/libs/<name>/` as a
[Diátaxis](https://diataxis.fr/) tree (`tutorial/`, `how-to/`, `reference/`,
`explanation/`). Today `sparkles:base`, `sparkles:syntax`,
`sparkles:test-runner`, and `sparkles:versions` are documented
([`docs/libs/base/`](../libs/base/index.md),
[`docs/libs/syntax/`](../libs/syntax/index.md),
[`docs/libs/test-runner/`](../libs/test-runner/index.md),
[`docs/libs/versions/`](../libs/versions/index.md)); `core-cli`, `test-utils`,
`math`, `ghostty`, and `tree-sitter` do not yet have a `docs/libs/<name>/`
tree. When you add or substantially extend a library, add/extend its docs in
that location.

## Detailed Guidelines

Cross-cutting guides live in `docs/guidelines/`:

- **[Code Style](./code-style.md)** — Formatting, naming, module layout, imports
- **[D Style](./dstyle.md)** — Broader D style reference
- **[Functional & Declarative Programming](./functional-declarative-programming-guidelines.md)** — Range pipelines, UFCS, purity, lazy evaluation
- **[Design by Introspection — Intro](./design-by-introspection-00-intro.md)** & **[Guidelines](./design-by-introspection-01-guidelines.md)** — Capability traits, optional primitives, shell-with-hooks pattern
- **[Interpolated Expression Sequences](./interpolated-expression-sequences.md)** — IES syntax, metadata processing, context-aware encoding
- **[DDoc](./ddoc.md)** — Documentation comments, sections, macros, cross-referencing
- **[Writing Research Docs](./research-docs.md)** — Research catalog layout, deep-dive & index skeletons, house style, VitePress gotchas, co-located runnable samples
- **[Cutting a Release](./release.md)** — Single-monorepo versioning, pre-1.0 SemVer, annotated-tag changelog format, publishing to code.dlang.org
- **[Integrating C Libraries (ImportC)](./importc-c-libraries.md)** — Adding a C dependency via ImportC + pkg-config + Nix + dub (`sourceLibrary` gotcha)
- **[Benchmarking & Profiling](./benchmarking-and-profiling.md)** — Measuring the terminal renderer (`terminal-benchmark`, `perf`, `vtebench`/`termbench`); render- vs parse-bound; the measure→profile→fix loop
- **[Modern D Language Features](./d-language-features/index.md)** — Changelog-sourced survey (2.060–2.112) of the language features new code should reach for (plus the few still-legal legacy forms to retire)
- **[Composable Memory Allocators](./allocators/index.md)** — Survey of `std.experimental.allocator`: the capability-by-presence protocol, `make`/`dispose`, building blocks, combinators, and composition patterns — with CI-verified runnable examples
- **Idioms** — [Expected Error Handling](./idioms/expected/index.md), [Forcing Named Arguments](./idioms/forced-named-arguments/index.md)

## Repository Layout

```
sparkles/
├── flake.nix                       # Nix flake (devshell, `ci` package, checks)
├── dub.sdl                         # Root package; declares the 14 sub-packages
├── apps/
│   ├── ci/                         # `ci` helper (executable sub-package)
│   │   ├── src/app.d               # Markdown example runner / verifier, link maintenance
│   │   ├── src/dub_deps.d          # In-tree dependency rewriting helpers
│   │   ├── dub.sdl
│   │   └── dub.selections.json
│   ├── release/                    # release automation helper (executable)
│   │   ├── src/app.d               # CLI + orchestration (stats → bump → notes → stages)
│   │   ├── src/git.d               # git/gh porcelain wrappers
│   │   ├── src/conventional.d      # conventional-commit parsing; bump.d/stages.d policy
│   │   ├── src/agents.d            # CLI LLM-agent registry (PATH-filtered)
│   │   └── src/notes.d             # $EDITOR seeding / comment stripping
│   ├── terminal/                   # raylib-based terminal emulator (executable)
│   │   ├── src/app.d               # Window/render loop, font + PTY setup
│   │   └── src/input.d             # Keyboard/mouse → libghostty-vt encoding
│   └── terminal-benchmark/         # render-CPU benchmark harness (executable)
│       ├── src/app.d               # scenario runner + /proc CPU sampling
│       └── src/bench.d             # testable bench logic
├── libs/
│   ├── base/src/sparkles/base/
│   │   ├── lifetime.d              # recycledInstance / recycledErrorInstance (@nogc throwing)
│   │   ├── logger.d                # CoreLogger, DeltaTimeLogger, Sparkles logging wrappers
│   │   ├── prettyprint.d           # Colorized pretty-printing
│   │   ├── smallbuffer.d           # @nogc dynamic buffer + checkToString/checkWriter test helpers
│   │   ├── source_uri.d            # OSC 8 source-URI hooks (editor links)
│   │   ├── styled_template.d       # IES-based styled text processing
│   │   ├── term_style.d            # Terminal styling/colors
│   │   └── text/                   # @nogc text package: readers.d, writers.d, errors.d, package.d
│   ├── build-primitives/src/sparkles/build_primitives/
│   │   ├── gitignore.d             # .gitignore rule parsing/matching + GitIgnoreStack (nested/ancestor scopes)
│   │   └── dir_walk.d              # DbI-hook directory walker; walkGitRepository / GitRepositoryFilter
│   ├── core-cli/src/sparkles/core_cli/
│   │   ├── args.d                  # CLI argument parsing (@CliOption, parseCliArgs)
│   │   ├── common_dirs.d           # XDG / standard directory lookup
│   │   ├── help_formatting.d       # --help output formatting
│   │   ├── prompts.d               # Interactive prompts (select/confirm/textInput + PromptPolicy)
│   │   ├── process_utils.d         # Process execution + RSS/CPU monitoring
│   │   ├── term_caps.d             # Terminal capability probing (size, tty, colors)
│   │   ├── term_unstyle.d          # Strip ANSI escapes
│   │   └── ui/                     # box, header, table, live, tasklist, progress, meter, tree, layout, theme, osc_link, demo
│   ├── versions/src/sparkles/versions/
│   │   ├── schemes/                # semver.d, dmd.d, calver_*.d, pypi.d, maven.d, deb.d, … + registry.d
│   │   ├── operations.d, ranges.d, parsing.d, traits.d, any.d
│   │   ├── purl.d, vers.d          # pURL / VERS interop
│   │   └── testing.d               # checkRoundTrip / checkRejects / checkAscending
│   ├── test-runner/src/sparkles/test_runner/   # the shim (sourceLibrary, compiled into consumers)
│   │   ├── discovery.d             # compile-time unittest discovery → Test[]
│   │   └── register.d              # extendedModuleUnitTester hook + extern(C) seam
│   ├── test-runner-impl/src/sparkles/test_runner/  # prebuilt impl library (internal)
│   │   ├── runner_impl.d           # extern(C) entry, CLI, mode dispatch
│   │   ├── attributes.d            # @betterC / @ctfe / @wasm / @benchmark marker UDAs
│   │   ├── model.d, filter.d       # Test/TestResult data model; regex include/exclude
│   │   ├── execution.d, reporting.d # parallel execution; styled result rendering
│   │   ├── bench.d                 # benchIter/blackBox, auto-scaling measurement
│   │   ├── extract.d, driver.d     # unittest-body extraction; -betterC/wasm drivers
│   │   └── ctfe_trace.d            # -ftime-trace CTFE cost attribution
│   ├── test-utils/src/sparkles/test_utils/
│   │   └── diff_tools.d, tmpfs.d, string.d, package.d
│   ├── math/src/sparkles/math/     # vector.d, package.d
│   ├── raylib-text/src/sparkles/raylib_text/  # multi-face FontSet (on-demand atlas, real bold/italic) + drawGrapheme/drawSolid/drawText (shared by terminal + hue --gui)
│   └── ghostty/src/sparkles/ghostty/
│       ├── c.c                     # ImportC shim: #include <ghostty/vt.h>
│       └── package.d               # public import sparkles.ghostty.c
├── docs/
│   ├── guidelines/                 # Cross-cutting agent/style guides (this file lives here)
│   ├── libs/<name>/                # Per-library Diátaxis docs (currently: base/, versions/)
│   ├── research/                   # Background research notes
│   ├── specs/                      # Design specs
│   └── overview.md, index.md
└── nix/
    ├── dub-lock.json               # Nix-format lockfile shared by `ci` + examples (buildDubPackage)
    └── shells/default.nix          # Nix dev shell
```

For module-organization and import conventions, see
[Code Style § Module Layout](./code-style.md#module-layout).

## Environment, Build & Test

The repo uses a Nix flake. `nix develop` (or `direnv`) provides the toolchain —
`dub`, `ldc`, `dmd`, `delta`, and the `ci` helper — on `PATH`. Once the toolchain
is available, prefer invoking `dub` **directly** for fast iteration:

```bash
# Build / test a sub-package (run dub directly — fast)
dub build :base
dub build :core-cli
dub test  :base
dub test  :core-cli
dub test  :versions

# Run tests matching / excluding a pattern (sparkles:test-runner; see below)
dub test :base -- -i "SmallBuffer"
dub test :core-cli -- -e "slow"
dub test :core-cli -- -v            # verbose: full stack traces + durations
dub test :core-cli -- -t 1          # single-threaded

# Test a sub-package in another worktree without cd:
dub --root /path/to/worktree test :core-cli
```

`nix develop -c <cmd>` also works but is slower and can trigger a rebuild of the
`ci` package; reserve it for entering the shell or for reproducing CI exactly.

> [!IMPORTANT]
> **The bare `ci` on `PATH` can be stale.** It is a Nix-store wrapper built from
> the flake; after you change `apps/ci`, the `PATH` copy lags behind. Run the
> in-tree version with `dub run :ci -- …` or `nix run .#ci -- …` instead of bare
> `ci`. (This is a real, recurring footgun.)

> [!IMPORTANT]
> **New/untracked files are invisible to `nix develop`/flake builds until you
> `git add` them** (stage — you don't need to commit). The flake evaluates the
> git tree, which includes tracked files and uncommitted edits to them, but not
> untracked files. Symptom: a freshly created `libs/foo/dub.sdl` or new module
> "doesn't exist" / "No package file found". Fix: `git add` it.

> [!NOTE]
> **Substantial scripts and hook logic must be written in D.** Tiny glue
> (a handful of lines to invoke a binary, set up paths, or do trivial
> argument munging) is acceptable as `pkgs.writeShellScript` or inline Nix.
> Any real logic — parsing, non-trivial decisions, more than roughly 5–10
> lines, etc. — belongs in a D program. The canonical place for repo
> tooling is `apps/ci` (or a small dedicated sub-package under `apps/` when
> appropriate). Build it via the flake and invoke it with
> `lib.getExe config.packages.ci` (or the equivalent for other packages)
> from pre-commit hooks and other Nix expressions.
>
> The `detailed-scope` pre-commit hook (commit-msg stage) was originally a
> large inline shell script in `nix/checks/pre-commit.nix`; it has been
> ported to a `--check-commit-scope` subcommand inside the D `ci` tool.

### Test runner (`sparkles:test-runner`)

The project uses its own runner, `sparkles:test-runner` (`libs/test-runner`,
silly's successor — same CLI, documented under
[`docs/libs/test-runner/`](../libs/test-runner/index.md)). Options after `--`:

```
-i, --include       Run tests matching regex
-e, --exclude       Skip tests matching regex
-v, --verbose       Show durations, [file:line] locations, full stack traces
-t, --threads       Number of worker threads (0 = auto)
-l, --list          List discovered tests (with attribute markers)
--no-colors        Disable colored output
--bench             Run @benchmark tests (auto-scaling ns/iter statistics)
--perf              With --bench: hardware perf counters (Linux perf_event)
--perf-scaled       With --perf: keep a multiplexing group; values render as ≈ estimates
--perf-iters=N      With --bench: pin the counting-pass iteration count (reproducible totals)
--syscalls[=LIST]   With --bench: syscalls/iter via perf tracepoints (root-gated)
--metrics=LIST      With --bench: pick metric columns (glob, all, ?/help = list;
                    raw:r<hex> / pfm:<name> add µarch hardware events)
--list-metrics      List available metric columns and exit
--sort-by=KEY       With --bench: sort rows by a metric column (default median/iter)
--group-by=KEYS     With --bench: one table per group of these label keys
--bench-json FILE   With --bench: dump results as JSON (baseline snapshots)
--bench-min-time MS With --bench: per-case measurement budget in ms (default 5)
--better-c          Extract @betterC tests, compile with -betterC, run them
--wasm              Extract @wasm tests, cross-compile to wasm32, run them
--ctfe-trace FILE   Evaluate @ctfe tests under LDC -ftime-trace; per-test cost
--self-test         Also run the runner's own unittests
```

Tests opt into the special modes with marker UDAs from
`sparkles.test_runner.attributes` (`@ctfe`, `@betterC`, `@wasm`,
`@benchmark`); import them **unconditionally**, not under
`version (unittest)` — see the
[attribute reference](../libs/test-runner/reference/attributes.md).
`@ctfe` tests never execute at runtime: after `-i`/`-e` filtering, the
runner CTFE-evaluates the selected ones through a probe compiled with
`-o- -unittest` (semantic analysis only, needs a D compiler on `PATH`), so
filters control which tests execute and a failing `@ctfe` test can't break
the test build, `--help`, or `--list`.

The runner is two packages: `sparkles:test-runner` is a thin `sourceLibrary`
shim (discovery + registration) compiled into each test binary, and
`sparkles:test-runner-impl` is the prebuilt implementation library it links
across an `extern(C)` seam. This keeps a consumer's `dub test` close to a
vanilla build (the heavy modules are compiled once, not per-consumer).

A new sub-package integrates the runner one of two ways:

- **Default (fast path)** — add `dependency "sparkles:test-runner" path="../.."`
  to `configuration "unittest"` (apps use the appropriate relative path). This
  is also the recipe external projects use. Copy the block from `libs/versions`.
- **Cycle-safe path** — `base`, `core-cli`, and `test-utils` are in the impl
  library's dependency closure (dub's cycle detection unions across configs:
  impl → `core-cli` → `test-utils`), so they cannot depend on it. They
  source-include both packages instead:

  ```sdl
  importPaths "src" "../test-runner/src" "../test-runner-impl/src"
  configuration "unittest" {
      sourcePaths "../test-runner/src" "../test-runner-impl/src"
  }
  ```

The `@ctfe`/`@betterC`/`@wasm`/`@benchmark` attributes live in the impl
package. A module that imports them in a non-`unittest` build (e.g. `base`'s
`readers.d`) must put `../test-runner-impl/src` on its top-level `importPaths`.

> [!WARNING]
> **The runner does not discover unittests that live only in `package.d`**
> (same as silly). `dub test` generates a `dub_test_root.d` whose
> `allModules` list excludes `package.d`, so a module whose tests are in
> `package.d` runs **zero** tests (and silently "passes"). Put tests in
> feature modules; keep `package.d` for `public import` re-exports only.

### Run the full CI check locally

```bash
nix run .#ci -- --test --fail-fast       # dub test for every sub-package
nix run .#ci -- --verify --files README.md   # verify markdown examples (see Examples below)
nix run .#ci -- --check-vcs-urls         # audit all tracked markdown for unpinned GitHub URLs
```

### Debugging tips

- `dub test :base -- -v` and `dub test :core-cli -- -v` show full stack traces
  and per-test durations.
- `-i "name"` isolates a single test by its UDA name.
- Ensure `@nogc`/`nothrow` tests actually compile with those attributes (don't
  let an accidental allocation relax them).

## Code Style & Idioms

### Functional style with UFCS

Prefer **functional pipelines** with UFCS over `std.algorithm`/`std.range`:

```d
auto result = items
    .filter!(a => a.isValid)
    .map!(a => a.name)
    .array;
```

See [Functional & Declarative Programming Guidelines](./functional-declarative-programming-guidelines.md).

### Safety attributes — annotate non-templates, infer on templates

Strive for maximum safety, but apply attributes correctly:

- **Non-templated functions:** annotate explicitly, e.g. `@safe pure nothrow @nogc`.
  A module- or scope-level `@safe pure nothrow:` block is fine for plain functions.
- **Templated functions** — and anything generic over a `Writer`, `Hook`, or other
  caller-supplied type — **let the attributes infer**. Forcing `@safe` on such a
  template rejects legitimately non-`@safe` writer/hook types it should accept.
  Reserve explicit attributes on templates for cases where the attribute is
  _intrinsic_ (e.g. `recycledErrorInstance` is deliberately `@system`).
- **Avoid `@trusted` on a whole function — never on a template.** Wrap only the
  unavoidable unsafe operation in a `@trusted` lambda/block, or sidestep it (e.g.
  the array-copy trick `char[1] a = c; put(w, a[]);` keeps a writer call `@safe`).

### Preview flags

Each sub-package's `dub.sdl` enables:

```
dflags "-preview=in" "-preview=dip1000"
```

- `-preview=in` — `in` parameters become `scope const`.
- `-preview=dip1000` — improved scope/lifetime checking for `@safe` code.

Unittest builds additionally pass `-checkaction=context -allinst` (richer assert
messages; instantiate all templates). The root `dub.sdl` has no `dflags` — they're
per-sub-package.

> [!WARNING]
> **`dip1000`/`-preview=in` clash with some Phobos functions that don't accept
> `scope`** (e.g. `std.regex.replaceAll`, reached via `unstyle`). Errors like
> "scope parameter may not be returned" mean you must relax that specific
> parameter — drop `in`/`scope` and use `const(char)[]` or pass by value.

### Error handling — `Expected` in `@nogc nothrow` code

GC exceptions are disallowed in `@safe pure nothrow @nogc` code. Use the
[`expected`](https://github.com/tchaloupka/expected) library (`~>0.4.1`, a runtime
dependency of `base` and `versions`):

- Construct with `ok(value)` / `err!ValType(error)`; check with `hasValue`/`hasError`.
- Transform/chain with `map`, `mapError`, `andThen`, `orElse`, `mapOrElse`.
- `Expected!(T, E)` is a range (a failure is empty, a success yields one element),
  so `joiner` flattens a collection of results, filtering out errors.
- For the rare path that must still `throw` in `@nogc`, use
  `recycledErrorInstance!T("message")` from `sparkles.base.lifetime`.

See **[Expected Error Handling Idioms](./idioms/expected/index.md)** for the full
guide (transform/chain/flatten patterns, Rust ↔ D comparisons, and a cheat sheet).

### `@nogc` primitives (and what breaks `@nogc`/`nothrow`)

- `SmallBuffer!(T, N)` — dynamic array with small-buffer optimization; works as an
  output range. Use it instead of `appender` in `@nogc` code.
- `sparkles.base.text.writers` / `.readers` — `@nogc` integer/float/duration
  formatting and parsing. Prefer these over `.text` / `std.conv` (which GC-allocate)
  and over `std.format` in hot paths.
- `pureMalloc`/`pureFree` from `core.memory` for manual allocation; static arrays
  when the size is known at compile time.

> [!WARNING]
> `splitter(' ')` and `std.utf` operations can throw `UTFException` / allocate,
> breaking `nothrow @nogc`. Use the `text` package primitives in those paths.

```d
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(char, 256) buf;
    buf ~= "Hello";
    buf ~= ' ';
    buf ~= "World";
    assert(buf[] == "Hello World");
}
```

### Contracts (DIP1009)

Use expression-based `in`/`out` contracts for pre/postconditions:

```d
void popBack()
in (_length > 0, "Cannot pop from empty buffer")
{
    _length--;
}
```

See [Code Style § Expression-based contracts](./code-style.md#expression-based-contracts-dip1009).

### Named arguments (DIP1030)

Use named arguments for struct initialization (see
[Code Style § Named arguments](./code-style.md#named-arguments-dip1030)):

```d
auto opts = PrettyPrintOptions!void(
    indentStep: 2,
    maxDepth: 8,
    maxItems: 32,
    softMaxWidth: 80,
    colored: true,
);
```

### Output ranges

Many utilities accept any output range for flexibility:

```d
ref Writer prettyPrint(T, Writer, Hook = void)(
    in T value,
    return ref Writer writer,
    in PrettyPrintOptions!Hook opt = PrettyPrintOptions!Hook()
)
{
    prettyPrintImpl(value, writer, opt, 0);
    return writer;
}

import std.array : appender;
auto w = appender!string;
prettyPrint(myValue, w);
string result = w[];
```

### Compile-time computation & template constraints

```d
// Computed at compile time via CTFE
enum string formatted = "Format me".stylizedTextBuilder(true).bold.underline.blue;

// Constrain templates for type safety
string numToString(T)(T value)
if (__traits(isUnsigned, T))
{ /* ... */ }
```

For capability-detection patterns (traits, optional primitives, fallback paths),
see [Design by Introspection Guidelines](./design-by-introspection-01-guidelines.md).

## Testing

### Placement & coverage

- Every public function should have a unit test following it.
- At minimum, one public/DDoc-ed unit test (`///`) per function.
- Keep tests in feature modules, **not** in `package.d` (see the test-runner
  warning above).
- Environment-dependent tests (perf counters, root-only interfaces, toolchain
  binaries) call `skipTest(reason)` from `sparkles.test_runner.skip` instead
  of returning early — an early `return` counts a degraded environment as a
  pass; a skip renders as a yellow `⊘` line plus an `N skipped` summary
  segment and never fails the run.

### Test attributes

Always give unittests explicit safety attributes:

- Use `@safe` or `@system` — never omit the safety attribute.
- Avoid `@trusted unittest` — tests should verify safety, not bypass it.
- Add `pure`, `nothrow`, `@nogc` whenever possible.

```d
@("SmallBuffer.basic.creation")
@safe pure nothrow @nogc
unittest
{
    SmallBuffer!(int, 4) buf;
    assert(buf.length == 0);
    assert(buf.empty);
}
```

### `@nogc nothrow` testing

- `recycledErrorInstance!T("msg")` throws without GC allocation.
- `SmallBuffer` as an output range instead of `appender`.

```d
@("prettyPrint.integers")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.lifetime : recycledErrorInstance;
    import sparkles.base.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 1024) buf;
    prettyPrint(42, buf);

    if (buf[] != "42")
        throw recycledErrorInstance!AssertError("Mismatch");
}
```

### Reusable check helpers

Prefer the project's helpers over hand-rolled assertions:

- **`checkToString` / `checkWriter`** (`sparkles.base.smallbuffer`) — for types
  exposing `void toString(Writer)(ref Writer w)`. They render into a `SmallBuffer`
  (so the test stays `@safe pure nothrow @nogc`) and report an expected/actual diff
  via a recycled `AssertError` on mismatch.
- **`checkRoundTrip` / `checkRejects` / `checkAscending`** (`sparkles.versions.testing`)
  — for version-scheme parse/format/ordering tests.

```d
@("MyType.toString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.smallbuffer : checkToString;
    checkToString(MyType(42), "MyType(42)");
}
```

(Note: a bare `check` is **not** an importable helper — it appears as an ad-hoc
local function inside some tests. Use the named helpers above.)

### Test naming (string UDAs)

```d
@("ModuleName.functionName.testCase")
@safe pure nothrow @nogc
unittest { /* ... */ }
```

## Examples & Documentation

### Where docs live

- Cross-cutting agent/style guides → `docs/guidelines/`.
- Per-library docs → `docs/libs/<name>/` as a Diátaxis tree
  (`tutorial/`, `how-to/`, `reference/`, `explanation/`). Mirror `libs/<name>/`.
- Background research → `docs/research/<topic>/` as a cross-linked catalog; follow
  [Writing Research Docs](./research-docs.md). Design specs → `docs/specs/`.

### Runnable README examples

When adding a feature, add a runnable example to `README.md` as a dub single-file
program inside a fenced `d` code block:

````markdown
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_my_feature"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.my_module;

void main()
{
    // Example usage
}
```
````

Follow it with a `[Output]`-labelled fenced block showing the expected output:

````markdown
```[Output]
Expected output here
```
````

The `[Output]` label is the **required convention**: `--verify` only treats
`[Output]` fences as expected output (a bare ` ``` ` fence is ignored). It renders
as a labelled "Output" panel under VitePress and as a plain block on GitHub.

### Verifying examples

````bash
# Verify examples match their expected output
nix run .#ci -- --verify --files README.md

# Update output blocks with actual output (golden-snapshot update; writes ```[Output])
nix run .#ci -- --update --files README.md

# Just run examples and display results
nix run .#ci -- --files README.md
````

> [!NOTE]
> README examples keep `version="*"`, which resolves against the registry by
> default. To verify them against your working tree, `dub add-local <repo>` first;
> CI relies on git **tags** so dub can derive a version. (In-repo example/dub files
> instead use a relative `path=` — see the table below.)

<div v-pre>

### Dynamic output with `<!-- md-example-expected -->`

For dynamic output (timestamps, paths, durations), put a `<!-- md-example-expected -->`
HTML-comment directive between the code block and the output block. It holds a
wildcard pattern used by `--verify`, while the literal `[Output]` block is kept for
readers. Use `{{_}}` to match any non-empty text:

````markdown
<!-- md-example-expected
[ {{_}} | info | {{_}} ]: Server started
-->

```[Output]
[ 14:32:01 | info | app.d:12 ]: Server started
```
````

The comment is invisible in rendered markdown, so readers see the nice hardcoded
values while `--verify` uses the wildcard pattern.

</div>

### In-repo dub dependency paths

Files **inside** the repo must reference sibling sub-packages with a relative
`path=` to the repo root, not `version="*"`:

```sdl
dependency "sparkles:core-cli" path="../../.."
```

The `path` value depends on the file's depth relative to the repo root:

| File location                | `path` value |
| ---------------------------- | ------------ |
| `libs/base/dub.sdl`          | `../..`      |
| `libs/base/examples/*.d`     | `../../..`   |
| `libs/core-cli/dub.sdl`      | `../..`      |
| `libs/core-cli/examples/*.d` | `../../..`   |
| `docs/guidelines/*.d`        | `../..`      |

This applies to all in-repo `dub.sdl` configs, single-file example scripts, and
guideline runnable snippets.

**Exception — `README.md`:** README examples are copy-pasted by end users who don't
have the repo layout, so they keep `version="*"`.

## Conventions

### Commit messages

Conventional commits with **detailed scopes when practical**:

```
<type>(<scope>): <description>
```

The parser (`apps/release`) accepts any text between the parentheses; the scope
exists for humans, `git log`, and release-note archaeology. The bump policy only
looks at the _type_ (plus `!` or `BREAKING` footer).

**Prefer the most specific scope that is still short and obvious.** Good patterns:

| Form                             | Example                                                                    | Notes                                                                     |
| -------------------------------- | -------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `docs(research/{topic})`         | `docs(research/window-system-integration): add Android/NDK OS-API example` | Research catalog topic                                                    |
| `docs(guidelines/{area})`        | `docs(guidelines): ...` or `docs(guidelines/code-style): ...`              | Guideline changes                                                         |
| `{lib/app}.module` (or `sub`)    | `fix(base.smallbuffer): saturate grownCapacity on overflow`                | D module or leaf file                                                     |
| `{pkg}/subdir` or `{pkg}.subdir` | `feat(core-cli/examples): add animated streaming drawTable demo`           | Examples or nested area                                                   |
| `pkg.sub.module` (D style)       | `feat(core_cli.ui.table): Use unstyledLength for precise column width`     | Internal module path                                                      |
| short whole-package name         | `feat(terminal): implement text selection`                                 | Acceptable when the package is small / single-file / cohesive at the time |
| tool / config area               | `config(lychee): ...`, `ci(gh-actions): ...`                               | Cross-cutting but named                                                   |

Bare top-level scopes (`base`, `core-cli`, `docs`, `research`, `tui`, `wired`, ...) are fine for genuinely cross-cutting work or early-stage packages. When the diff is localized to one file or subdirectory, a dotted or slashed child scope is better.

- **Type** — one of the following (one example each):

| Type       | Use for                                  | Example                                                                  |
| ---------- | ---------------------------------------- | ------------------------------------------------------------------------ |
| `feat`     | new user-facing capability               | `feat(base.smallbuffer): add SmallBuffer with small-buffer optimization` |
| `fix`      | bug fix                                  | `fix(core-cli): handle empty arrays in prettyPrint`                      |
| `refactor` | behavior-preserving restructuring        | `refactor(ci): extract dub dependency helpers into a testable module`    |
| `docs`     | documentation only                       | `docs(guidelines): document the [Output] example convention`             |
| `build`    | build system / dependencies              | `build(dub): add expected as a runtime dependency of versions`           |
| `ci`       | CI/CD pipelines & tooling                | `ci(gh-actions): add DC (D compiler) dimension to the test matrix`       |
| `test`     | tests only                               | `test(base): add checkWriter for testing writer functions`               |
| `style`    | formatting / renames, no behavior change | `style(core-cli): use kebab-case names for example files`                |
| `chore`    | maintenance (lockfiles, file modes, …)   | `chore(flake.lock): update all flake inputs`                             |
| `config`   | config-file changes                      | `config(editorconfig): disable indent checking for markdown`             |

Append `!` after the scope for a breaking change (e.g. `feat(ci)!: …`).

Wrap the commit message **body** at 80 columns (the subject line stays a single
line). Use a blank line between the subject and the body.

**Backtick `@`-prefixed code tokens (and other auto-linked text).** D attributes
and UDAs — `@safe`, `@nogc`, `@trusted`, `@system`, `@property`, `@CliOption`,
etc. — are inline code, but GitHub renders an un-backticked `@name` in a commit
message, a PR/issue title or body, or any comment as a **mention**: it notifies
(and on merge, permanently credits) whoever owns that handle. `@safe`, `@system`,
and `@property` are all real GitHub accounts, so a bare `nothrow @nogc` pings
strangers and litters the thread. Always wrap them: write `` `@nogc nothrow` ``,
the `` `@safe pure nothrow @nogc` `` order, a `` `@trusted` `` block — never the
bare form. The same applies to anything else GitHub auto-links out of context: a
literal `` `#123` `` (so it isn't turned into an issue/PR reference) or a commit
`` `sha` `` you don't want rendered as a cross-link. This is purely a
commit-message / PR / issue / comment concern — `@`-tokens inside committed
source or Markdown files are not mentions and need no special treatment beyond
the usual code formatting.

### Git hygiene & atomic commits

- **Confirm the current branch before any write/amend/rebase.** A misdirected
  `--amend` silently folds work into the wrong commit. If you're on the default
  branch, create a branch first.
- **Commit as you go — only _pushing_ normally needs to be explicitly asked for.**
  Create a commit at each significant step instead of batching everything at the
  end: a clean, atomic, bisectable series is far easier to build incrementally than
  to reconstruct afterward. Don't wait for permission to commit. The exception is
  documentation-related work: once it is committed, validated, and rebased, push it
  and open the PR without waiting for confirmation.
- **Always rebase on `origin/main` before opening a PR.** Fetch `origin`, rebase the
  completed branch onto the current `origin/main`, resolve conflicts, and rerun the
  affected validation before pushing/opening. If the rebased branch was already
  pushed, update it with `--force-with-lease`, never plain `--force`.
- **Keep commits atomic.** One logical change per commit, and each commit should
  pass build + test + lint _on its own_ so history stays bisectable. Use
  `git commit --fixup=<sha>` for tweaks that belong to an earlier commit instead
  of a fresh "address review" commit.
- **Review the branch at the end of a session** and propose tidying it with an
  interactive rebase (`git rebase -i <base>`) before it merges. Aim for:
  - **Squash fixups** into their targets — `git rebase -i --autosquash <base>`.
  - **Every commit green** — no commit that only builds/tests/lints once a later
    commit lands.
  - **Group commits by area** so related changes are adjacent.
  - **Preparation commits first** — move `.gitignore` edits, dependency
    add/remove/upgrade, config changes, and docs/scaffolding that later commits
    build on to the front of the branch.
  - Present the proposed reordering and rewrite only after the user agrees. Never
    rewrite already-pushed history without `--force-with-lease` and explicit sign-off.

### Pre-commit hooks (`prek`)

See the note in the [Environment, Build & Test](#environment-build--test)
section about implementing substantial hook logic in D rather than large
shell scripts.

Hooks run on commit and will modify or block your changes:

- **editorconfig-checker** enforces 4-space-multiple indentation — including inside
  DDoc comments (e.g. `$(LIST` / `$(ITEM` bodies).
- **prettier** reformats markdown and can corrupt literal text in tables (it has
  turned `5.004_05` into `5.004*05`); double-check tables of literal data after it runs.
- **verify-md-examples** runs the example verifier and is OOM-prone on large runs;
  bypass a single commit with `SKIP=verify-md-examples git commit …` when needed.
- **detailed-scope** (runs at `commit-msg` stage) checks for obviously useless
  scopes (`wip`, `misc`, `update`, …) and suggests more specific scopes for
  localized changes inside large packages (e.g. bare `base` when only
  `base/smallbuffer.d` changed). It is intentionally _not_ a strict enum. See
  the "Commit messages" section above for the intended style. Bypass with
  `SKIP=detailed-scope git commit …` or `git commit --no-verify`.
- **check-vcs-urls** scans staged markdown files for `github.com`/
  `raw.githubusercontent.com` URLs and rejects any that reference a branch or
  tag instead of a 40-character commit SHA (so docs citing external source
  stay pinned to the exact revision they describe). It only runs against
  `.md` files — non-doc files (e.g. `.envrc`, other tag+hash-pinned tool
  fetches) are out of scope. `$` or `%` in the ref position is treated as a
  runtime placeholder and skipped. Bypass with
  `SKIP=check-vcs-urls git commit …` or `git commit --no-verify`; run
  `nix run .#ci -- --check-vcs-urls` to audit all tracked markdown files.

## Pitfalls Checklist

A quick scan of the gotchas above plus a few more:

- [ ] `git add` new files before `nix develop`/flake builds see them.
- [ ] Don't run bare `ci` after editing `apps/ci`; use `dub run :ci -- …` / `nix run .#ci -- …`.
- [ ] Tests in `package.d` don't run under the test runner — move them to feature modules.
- [ ] Don't force `@safe`/`@trusted` on templates; let attributes infer.
- [ ] `dip1000`/`in` can reject `scope` for some Phobos calls — relax to `const(char)[]`.
- [ ] `splitter`/`std.utf`/`.text`/`std.conv` break `nothrow @nogc` — use the `text` package.
- [ ] Example output blocks must be ` ```[Output] `, never bare ` ``` `.
- [ ] Cross-module-but-internal symbols use `package` visibility, not `private`.
- [ ] Symbols used only as UDAs are camelCase (lowercase first letter).
- [ ] Dependency version changes need matching `dub.selections.json` and
      `nix/dub-lock.json` updates.

## Dependencies

- `expected` (`~>0.4.1`) — `Expected!(T, E)` error handling; **runtime** dep of
  `base` and `versions`.
- `sparkles:test-runner` (in-tree) — unittest runner; a thin shim most
  packages pull as a `dependency`, backed by the prebuilt
  `sparkles:test-runner-impl` library (`base`/`core-cli`/`test-utils`
  source-include both — see the integration note above).
- `delta` — diff tool used by test diff output; system dependency via Nix.

D dependencies are managed via `dub.sdl` (pinned in `dub.selections.json` /
`nix/dub-lock.json`); system tools come from the Nix flake.
