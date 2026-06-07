# Agent Guidelines for Sparkles

Instructions for AI agents working on the `sparkles` codebase. This file is the
single source of truth: the root `AGENTS.md` is a symlink to it, and `CLAUDE.md`
includes it. Keep it accurate — a stale fact here propagates into every agent's work.

## Project Overview

`sparkles` is a D monorepo of CLI/library utilities. The root `dub.sdl` declares
five sub-packages:

| Sub-package           | Path              | What it is                                                                                                                                                 |
| --------------------- | ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sparkles:core-cli`   | `libs/core-cli`   | Terminal styling, pretty-printing, UI components (table/box/header/OSC links), logger, `SmallBuffer`, text readers/writers, process utils, CLI arg parsing |
| `sparkles:versions`   | `libs/versions`   | Design-by-Introspection versioning library (SemVer, DMD, CalVer, PyPI, Maven, Deb, …) with VERS/pURL interop                                               |
| `sparkles:test-utils` | `libs/test-utils` | Testing helpers: diff tools, temp-filesystem helpers, string helpers                                                                                       |
| `sparkles:math`       | `libs/math`       | Small math primitives for games/graphics (early stage)                                                                                                     |
| `ci`                  | `apps/ci`         | Repository CI helper: runs/verifies markdown examples, standalone examples, sub-package tests, and markdown link maintenance                               |

Each library **should** be documented under `docs/libs/<name>/` as a
[Diátaxis](https://diataxis.fr/) tree (`tutorial/`, `how-to/`, `reference/`,
`explanation/`). Today only `sparkles:versions` is fully documented
([`docs/libs/versions/`](../libs/versions/index.md)); `core-cli`, `test-utils`,
and `math` do not yet have a `docs/libs/<name>/` tree. When you add or substantially
extend a library, add/extend its docs in that location.

## Detailed Guidelines

Cross-cutting guides live in `docs/guidelines/`:

- **[Code Style](./code-style.md)** — Formatting, naming, module layout, imports
- **[D Style](./dstyle.md)** — Broader D style reference
- **[Functional & Declarative Programming](./functional-declarative-programming-guidelines.md)** — Range pipelines, UFCS, purity, lazy evaluation
- **[Design by Introspection — Intro](./design-by-introspection-00-intro.md)** & **[Guidelines](./design-by-introspection-01-guidelines.md)** — Capability traits, optional primitives, shell-with-hooks pattern
- **[Interpolated Expression Sequences](./interpolated-expression-sequences.md)** — IES syntax, metadata processing, context-aware encoding
- **[DDoc](./ddoc.md)** — Documentation comments, sections, macros, cross-referencing
- **[Writing Research Docs](./research-docs.md)** — Research catalog layout, deep-dive & index skeletons, house style, VitePress gotchas, co-located runnable samples
- **Idioms** — [Expected Error Handling](./idioms/expected/index.md), [Forcing Named Arguments](./idioms/forced-named-arguments/index.md)

## Repository Layout

```
sparkles/
├── flake.nix                       # Nix flake (devshell, `ci` package, checks)
├── dub.sdl                         # Root package; declares the 5 sub-packages
├── apps/
│   └── ci/                         # `ci` helper (executable sub-package)
│       ├── src/app.d               # Markdown example runner / verifier, link maintenance
│       ├── src/dub_deps.d          # In-tree dependency rewriting helpers
│       ├── dub.sdl
│       └── dub.selections.json
├── libs/
│   ├── core-cli/src/sparkles/core_cli/
│   │   ├── args.d                  # CLI argument parsing (@CliOption, parseCliArgs)
│   │   ├── common_dirs.d           # XDG / standard directory lookup
│   │   ├── help_formatting.d       # --help output formatting
│   │   ├── lifetime.d              # recycledInstance / recycledErrorInstance (@nogc throwing)
│   │   ├── logger.d                # Delta-time-prefixed logger
│   │   ├── prettyprint.d           # Colorized pretty-printing
│   │   ├── process_utils.d         # Process execution + RSS/CPU monitoring
│   │   ├── smallbuffer.d           # @nogc dynamic buffer + checkToString/checkWriter test helpers
│   │   ├── source_uri.d            # OSC 8 source-URI hooks (editor links)
│   │   ├── styled_template.d       # IES-based styled text processing
│   │   ├── term_size.d             # Terminal size detection
│   │   ├── term_style.d            # Terminal styling/colors
│   │   ├── term_unstyle.d          # Strip ANSI escapes
│   │   ├── text/                   # @nogc text package: readers.d, writers.d, errors.d, package.d
│   │   └── ui/                     # box.d, header.d, table.d, osc_link.d, demo.d
│   ├── versions/src/sparkles/versions/
│   │   ├── schemes/                # semver.d, dmd.d, calver_*.d, pypi.d, maven.d, deb.d, … + registry.d
│   │   ├── operations.d, ranges.d, parsing.d, traits.d, any.d
│   │   ├── purl.d, vers.d          # pURL / VERS interop
│   │   └── testing.d               # checkRoundTrip / checkRejects / checkAscending
│   ├── test-utils/src/sparkles/test_utils/
│   │   └── diff_tools.d, tmpfs.d, string.d, package.d
│   └── math/src/sparkles/math/     # vector.d, package.d
├── docs/
│   ├── guidelines/                 # Cross-cutting agent/style guides (this file lives here)
│   ├── libs/<name>/                # Per-library Diátaxis docs (currently: versions/)
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
dub build :core-cli
dub test  :core-cli
dub test  :versions

# Run tests matching / excluding a pattern (silly runner; see options below)
dub test :core-cli -- -i "SmallBuffer"
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

### Test runner (silly)

The project uses the `silly` test runner (`~>1.1.1`). Options after `--`:

```
-i, --include    Run tests matching regex
-e, --exclude    Skip tests matching regex
-v, --verbose    Show full stack traces and durations
-t, --threads    Number of worker threads (0 = auto)
--no-colours     Disable colored output
```

> [!WARNING]
> **silly does not discover unittests that live only in `package.d`.** `dub test`
> generates a `dub_test_root.d` whose `allModules` list excludes `package.d`, so a
> module whose tests are in `package.d` runs **zero** tests (and silently
> "passes"). Put tests in feature modules; keep `package.d` for `public import`
> re-exports only.

### Run the full CI check locally

```bash
nix run .#ci -- --test --fail-fast       # dub test for every sub-package
nix run .#ci -- --verify --files README.md   # verify markdown examples (see Examples below)
```

### Debugging tips

- `dub test :core-cli -- -v` shows full stack traces and per-test durations.
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
[`expected`](https://github.com/tchaloupka/expected) library (`~>0.4.0`, a runtime
dependency of `core-cli` and `versions`):

- Construct with `ok(value)` / `err!ValType(error)`; check with `hasValue`/`hasError`.
- Transform/chain with `map`, `mapError`, `andThen`, `orElse`, `mapOrElse`.
- `Expected!(T, E)` is a range (a failure is empty, a success yields one element),
  so `joiner` flattens a collection of results, filtering out errors.
- For the rare path that must still `throw` in `@nogc`, use
  `recycledErrorInstance!T("message")` from `sparkles.core_cli.lifetime`.

See **[Expected Error Handling Idioms](./idioms/expected/index.md)** for the full
guide (transform/chain/flatten patterns, Rust ↔ D comparisons, and a cheat sheet).

### `@nogc` primitives (and what breaks `@nogc`/`nothrow`)

- `SmallBuffer!(T, N)` — dynamic array with small-buffer optimization; works as an
  output range. Use it instead of `appender` in `@nogc` code.
- `sparkles.core_cli.text.writers` / `.readers` — `@nogc` integer/float/duration
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
    useColors: true,
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
- Keep tests in feature modules, **not** in `package.d` (see the silly warning above).

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
    import sparkles.core_cli.lifetime : recycledErrorInstance;
    import sparkles.core_cli.smallbuffer : SmallBuffer;

    SmallBuffer!(char, 1024) buf;
    prettyPrint(42, buf);

    if (buf[] != "42")
        throw recycledErrorInstance!AssertError("Mismatch");
}
```

### Reusable check helpers

Prefer the project's helpers over hand-rolled assertions:

- **`checkToString` / `checkWriter`** (`sparkles.core_cli.smallbuffer`) — for types
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
    import sparkles.core_cli.smallbuffer : checkToString;
    checkToString(MyType(42), "MyType(42)");
}
```

(Note: a bare `check` is **not** an importable helper — it appears as an ad-hoc
local function inside some tests. Use the named helpers above.)

### Test naming (silly UDAs)

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
| `libs/core-cli/dub.sdl`      | `../..`      |
| `libs/core-cli/examples/*.d` | `../../..`   |
| `docs/guidelines/*.d`        | `../..`      |

This applies to all in-repo `dub.sdl` configs, single-file example scripts, and
guideline runnable snippets.

**Exception — `README.md`:** README examples are copy-pasted by end users who don't
have the repo layout, so they keep `version="*"`.

## Conventions

### Commit messages

Conventional commits: `<type>(<scope>): <description>` (lowercase description).

- **Scope** = a sub-package (`core-cli`, `versions`, `math`, `test-utils`, `ci`) or
  an area (`nix`, `dub`, `guidelines`, `gh-actions`, `docs`, `research`).
- **Type** — one of the following (one example each):

| Type       | Use for                                  | Example                                                               |
| ---------- | ---------------------------------------- | --------------------------------------------------------------------- |
| `feat`     | new user-facing capability               | `feat(core-cli): add SmallBuffer with small-buffer optimization`      |
| `fix`      | bug fix                                  | `fix(core-cli): handle empty arrays in prettyPrint`                   |
| `refactor` | behavior-preserving restructuring        | `refactor(ci): extract dub dependency helpers into a testable module` |
| `docs`     | documentation only                       | `docs(guidelines): document the [Output] example convention`          |
| `build`    | build system / dependencies              | `build(dub): add expected as a runtime dependency of versions`        |
| `ci`       | CI/CD pipelines & tooling                | `ci(gh-actions): add DC (D compiler) dimension to the test matrix`    |
| `test`     | tests only                               | `test(core-cli): add checkWriter for testing writer functions`        |
| `style`    | formatting / renames, no behavior change | `style(core-cli): use kebab-case names for example files`             |
| `chore`    | maintenance (lockfiles, file modes, …)   | `chore(flake.lock): update all flake inputs`                          |
| `config`   | config-file changes                      | `config(editorconfig): disable indent checking for markdown`          |

Append `!` after the scope for a breaking change (e.g. `feat(ci)!: …`).

Wrap the commit message **body** at 80 columns (the subject line stays a single
line). Use a blank line between the subject and the body.

### Git hygiene & atomic commits

- **Confirm the current branch before any write/amend/rebase.** A misdirected
  `--amend` silently folds work into the wrong commit. If you're on the default
  branch, create a branch first.
- **Commit as you go — only _pushing_ needs to be explicitly asked for.** Create a
  commit at each significant step instead of batching everything at the end: a
  clean, atomic, bisectable series is far easier to build incrementally than to
  reconstruct afterward. Don't wait for permission to commit; do wait for it to push.
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

Hooks run on commit and will modify or block your changes:

- **editorconfig-checker** enforces 4-space-multiple indentation — including inside
  DDoc comments (e.g. `$(LIST` / `$(ITEM` bodies).
- **prettier** reformats markdown and can corrupt literal text in tables (it has
  turned `5.004_05` into `5.004*05`); double-check tables of literal data after it runs.
- **verify-md-examples** runs the example verifier and is OOM-prone on large runs;
  bypass a single commit with `SKIP=verify-md-examples git commit …` when needed.

## Pitfalls Checklist

A quick scan of the gotchas above plus a few more:

- [ ] `git add` new files before `nix develop`/flake builds see them.
- [ ] Don't run bare `ci` after editing `apps/ci`; use `dub run :ci -- …` / `nix run .#ci -- …`.
- [ ] Tests in `package.d` don't run under silly — move them to feature modules.
- [ ] Don't force `@safe`/`@trusted` on templates; let attributes infer.
- [ ] `dip1000`/`in` can reject `scope` for some Phobos calls — relax to `const(char)[]`.
- [ ] `splitter`/`std.utf`/`.text`/`std.conv` break `nothrow @nogc` — use the `text` package.
- [ ] Example output blocks must be ` ```[Output] `, never bare ` ``` `.
- [ ] Cross-module-but-internal symbols use `package` visibility, not `private`.
- [ ] Symbols used only as UDAs are camelCase (lowercase first letter).
- [ ] `expected` is pinned to 0.4.0; the upstream fix is untagged, so `dub upgrade` is a no-op.

## Dependencies

- `expected` (`~>0.4.0`) — `Expected!(T, E)` error handling; **runtime** dep of
  `core-cli` and `versions`.
- `silly` (`~>1.1.1`) — unittest runner; dev/configuration dependency.
- `delta` — diff tool used by test diff output; system dependency via Nix.

D dependencies are managed via `dub.sdl` (pinned in `dub.selections.json` /
`nix/dub-lock.json`); system tools come from the Nix flake.
