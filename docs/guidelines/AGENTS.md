# Agent Guidelines for Sparkles

Instructions for AI agents working on the `sparkles` codebase. This file is the
single source of truth: the root `AGENTS.md` is a symlink to it, and `CLAUDE.md`
includes it. Keep it accurate — a stale fact here propagates into every agent's work.

## Project Overview

`sparkles` is a D monorepo of CLI/library utilities. The authoritative package
list is the `subPackage` entries in the root `dub.sdl`. **Before working in an
unfamiliar package, read its entry in the [Package Catalog](./packages.md)** —
the detailed descriptions and the module map live there.

| Package                                                                            | One line                                                                     |
| ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `ci`                                                                               | repo CI helper: tests, markdown examples, link/sidebar audits                |
| `hue`                                                                              | syntax-highlighting viewer (ANSI/HTML/`--gui`), diff/PR viewer, APK          |
| `release`                                                                          | tag scanning, bump suggestion, notes, publishing                             |
| `shader-compile`                                                                   | D shaders → SPIR-V → committed GLSL (`libs/ui/src/sparkles/ui/shaders/`)     |
| `terminal`, `terminal-benchmark`                                                   | raylib terminal emulator on libghostty-vt; its render-CPU benchmark          |
| `ui-gallery`, `diagram`                                                            | `sparkles:ui-app` apps: the toolkit catalog; a camera-driven diagram board   |
| `nix-eval`, `twoslash-extract`                                                     | `sparkles:nix` demo; batch D twoslash extractor                              |
| `base`                                                                             | `Buffer`, `@nogc` text, lifetime, logging, `term_caps`, `hw_caps`            |
| `core-cli`                                                                         | argument parsing, help, prompts, process utilities                           |
| `ui`, `ui-app`, `ui-tui`, `ui-raylib`, `ui-sdl3`, `input`, `tui`                   | the one UI stack: toolkit, host, backends, input vocabulary, cell grid       |
| `syntax`, `tree-sitter`, `source-view`, `diff`, `dsv`                              | highlighting, markdown model, code/markdown views, diff and DSV engines      |
| `twoslash`, `twoslash-d`, `twoslash-protocol`, `dmd-lsp`, `dmd-fmt`                | type overlays, the DMD-frontend semantic core, the D formatter               |
| `event-horizon`, `http`                                                            | completion-first event loop with effects; HTTP/1.1 over it                   |
| `wsi`, `vulkan`, `vulkan-wsi`, `raylib-text`, `ghostty`, `terminal-view`, `shader` | windowing, GPU, fonts, VT engine, embeddable terminal, shader vocabulary     |
| `wired`, `reflection`, `metadata`, `dql`, `fuzzy`                                  | serialization, reflection kernel, UDA vocabulary, query engine, fuzzy search |
| `build-primitives`, `code-instrumentation`, `docs`, `nix`, `versions`, `math`      | gitignore/walk/`runGit`, coverage, SSG, Nix C API, versioning, vectors       |
| `test-runner` (+ internal `test-runner-impl`), `test-utils`                        | the unittest runner; test helpers                                            |

Libraries are documented under `docs/libs/<name>/` as a [Diátaxis](https://diataxis.fr/)
tree (`tutorial/`, `how-to/`, `reference/`, `explanation/`); designs live in
`docs/specs/<name>/`. When you add or substantially extend a library, add or
extend its docs there.

## Detailed Guidelines

Cross-cutting guides live in `docs/guidelines/`:

- **[Code Style](./code-style.md)** — module layout, imports, contracts, named arguments, literals
- **[D Style](./dstyle.md)** — broader D style reference
- **[Functional & Declarative Programming](./functional-declarative-programming-guidelines.md)** — range pipelines, UFCS, purity, laziness
- **[Design by Introspection — Intro](./design-by-introspection-00-intro.md)** & **[Guidelines](./design-by-introspection-01-guidelines.md)** — capability traits, optional primitives, shell-with-hooks
- **[Interpolated Expression Sequences](./interpolated-expression-sequences.md)** — IES syntax, metadata, context-aware encoding
- **[DDoc](./ddoc.md)** — documentation comments, sections, macros
- **[Writing Research Docs](./research-docs.md)** — research catalogs, house style, VitePress gotchas
- **[Writing Specification Docs](./spec-docs.md)** — falsifiable contracts, test oracles, delivery gates
- **[Writing Specification Prose](./spec-prose.md)** — front matter, abstract, introduction, timeless prose, the cold read
- **[Cutting a Release](./release.md)** — monorepo versioning, changelog tags, code.dlang.org
- **[Integrating C Libraries (ImportC)](./importc-c-libraries.md)** — ImportC + pkg-config + Nix + dub (`sourceLibrary` gotcha)
- **[Benchmarking & Profiling](./benchmarking-and-profiling.md)** — the measure→profile→fix loop for the terminal renderer
- **[Modern D Language Features](./d-language-features/index.md)** — which 2.060–2.112 features new code should reach for
- **[Composable Memory Allocators](./allocators/index.md)** — `std.experimental.allocator` building blocks and composition
- **Idioms** — [Expected Error Handling](./idioms/expected/index.md), [Forcing Named Arguments](./idioms/forced-named-arguments/index.md)

## Environment, Build & Test

`nix develop` (or `direnv`) puts `dub`, `ldc`, `dmd`, `delta`, and `ci` on
`PATH`. Inside it, invoke `dub` directly for fast iteration:

```bash
dub test :base                         # test a sub-package
dub test :base -- -i "Buffer" -v       # filter by test name; stack traces + durations
dub --root /path/to/worktree test :ui  # another worktree, no cd
dub build :twoslash-extract -b checked # build the way the flake does
```

`nix develop -c <cmd>` is slower and can rebuild `ci`; reserve it for
reproducing CI exactly.

> [!IMPORTANT]
>
> - **`git add` new files before any flake build.** The flake sees tracked files
>   (and edits to them), never untracked ones — a new `dub.sdl` or module
>   "doesn't exist" until staged.
> - **After editing `apps/ci`, run `dub run :ci -- …` or `nix run .#ci -- …`.**
>   The bare `ci` on `PATH` is a Nix-store build and lags behind.

### Dev shells: `default`, `full`, `ci`

All three come from `mkSparklesShell` in `nix/shells/default.nix`. `default` is
quiet (no banner) — the one agents and scripts get via `nix develop -c`; `full`
adds the `figlet` greeting for interactive use; `ci` is the CI floor (no
browser, profilers, corpora, oracle libraries, or pre-commit tooling). `direnv`
picks `${DEV_SHELL:-default}`, settable in a git-ignored `.env`.

Adding a tool means choosing a tier: `ciPackages` is built on every CI run, so
put a tool there only if a CI job runs it; everything else goes in `devPackages`.

### Offline dub

The shells seed DUB's writable source cache from `packages.dub-sources` on entry,
preserving existing versions. After building `.#ci` without entering a shell,
run `nix run --offline .#ci -- --seed-dub-cache` before using plain `dub` offline.
The destination is `$DUB_HOME` or `~/.dub` (custom `settings.json` `dubHome` users
must set `DUB_HOME` explicitly). Only sources are imported, not compiled caches,
settings or local overrides. `ci` retains the Nix source bundle in its runtime
closure and seeds each isolated Markdown example home too.
For offline Markdown/standalone examples, `SPARKLES_CI_OFFLINE=1` adds
`--skip-registry=all` to their DUB commands, suppressing metadata queries and
warnings even when an example has no selections file.

`nix/dub-lock.json` covers application dependencies; `nix/ci-dub-lock.json` adds
example-only packages, including the pinned Eve Git revision. New dependencies
must join the relevant lock to work offline. `sparkles.cachix.org` substitutes
these Nix store objects; it does not implement DUB's registry/Git protocols.

### Flake-input store paths

The dev shell exports every flake input (except `self`) as a store path:
`$SPARKLES_FLAKE_INPUT_<NAME>` (input name uppercased, `-` → `_`, pointing at
the checkout root), and `$SPARKLES_ALL_FLAKE_INPUTS`, a JSON object keyed by
the original input names. Read pinned third-party checkouts through these —
never by scraping `flake.lock`, `dub.selections.json`, or `$DUB_HOME` — and have
the test **assert** the var is set and the path exists.

Derived-package vars (`$SPARKLES_DMD_IMPORT_PATH`, `$SPARKLES_LDC_IMPORT_PATH`,
`$SPARKLES_TS_GRAMMAR_PATH`, `$JSON_TEST_SUITE`) point at linkFarm/applyPatches
outputs instead; their tests **skip** when unset.

### Locating C Headers & System Dependencies

Ask `pkg-config` (`pkg-config --cflags raylib`, `pkg-config --libs vulkan`).
Searching `/nix/store` directly is slow and finds stale or unrelated packages.

### Build types: `debug` to test, `checked` to ship, never `release`

Every in-repo `dub.sdl` and every single-file example's inline recipe declares:

```sdl
buildType "checked" {
    buildOptions "optimize" "inline" "debugInfo"
}
```

| Build type | `assert` | `debug { }` | Use for                                             |
| ---------- | -------- | ----------- | --------------------------------------------------- |
| `debug`    | live     | **on**      | `dub test`, local iteration                         |
| `release`  | **gone** | off         | nothing                                             |
| `checked`  | live     | off         | every nix artifact: apps, examples, the `ci` helper |

- `-release` deletes an assert's whole _expression_, so a call inside one stops
  happening: `assert(!client.connect(addr).hasError)` never connected, and the
  example hung until CI's 20-minute cap. `libs/base/examples/build-mode-probe.d`
  shows what each mode really does.
- `-debug` compiles in `debug { }` blocks — checks too expensive to ship, and
  exactly what tests want.
- `checked` measured ~3% over `release` (`twoslash-extract`) and half of `debug`.
- For a hot path where assertions really cost, apply `-checkaction=halt` to that
  package, with a measurement in hand.

dub resolves `--build=<name>` against the **root** recipe only, which is why
each example repeats the declaration; `apps/ci/tools/add-checked-buildtype.d`
re-applies it idempotently to new packages and examples.

### Scripts are D

Write any script with real logic — parsing, decisions, more than ~5–10 lines —
as D: repo tooling in `apps/ci` (or a small `apps/` sub-package, invoked from
Nix via `lib.getExe`), throwaway work (a table transform, a bulk edit, a repro,
a PTY probe) as a single-file `dub run --single foo.d`. A D script can import
the `sparkles` libraries and graduate into `apps/ci`, a test, or an example.
Shell or inline Nix is for a handful of lines of glue; `python`/`node` for a
genuinely trivial one-liner.

### Test runner (`sparkles:test-runner`)

The project's own runner (silly's successor, same core CLI; `dub test :x -- --help`
lists every flag, [docs](../libs/test-runner/index.md)). Beyond `-i`/`-e`/`-v`/
`-t`/`-l`, it runs special modes selected by marker UDAs from
`sparkles.test_runner.attributes` — `@ctfe`, `@betterC` (`--better-c`), `@wasm`
(`--wasm`), `@benchmark`/`@workload` (`--bench`). Import the attributes
**unconditionally**, never under `version (unittest)`
([reference](../libs/test-runner/reference/attributes.md)). `@ctfe` tests are
evaluated by a separate `-o- -unittest` probe after filtering, so a failing one
cannot break the build, `--help`, or `--list`.

The runner is a thin `sourceLibrary` shim (`sparkles:test-runner`: discovery,
registration, and the attributes) linked across an `extern(C)` seam to the
prebuilt `sparkles:test-runner-impl`. A new sub-package integrates it one of
two ways:

- **Default** — `dependency "sparkles:test-runner" path="../.."` inside
  `configuration "unittest"`; copy the block from `libs/versions`.
- **Cycle-safe** — `base`, `core-cli`, and `test-utils` sit in the impl's
  dependency closure, so they source-include both instead. Only the shim goes
  on the top-level `importPaths` (keeping the impl and its `sparkles:ui` out of
  every consumer's source closure):

  ```sdl
  importPaths "src" "../test-runner/src"
  configuration "unittest" {
      sourcePaths "../test-runner/src" "../test-runner-impl/src"
      importPaths "src" "../test-runner/src" "../test-runner-impl/src"
  }
  ```

> [!WARNING]
> Tests in `package.d` are never discovered — dub's generated test root omits
> it, so such a module runs zero tests and "passes". Keep tests in feature
> modules and `package.d` for `public import`s.

### Run the full CI check locally

```bash
nix run .#ci -- --test --fail-fast                   # dub test, every sub-package
DC=ldc2 nix run .#ci -- --test-sanitize --fail-fast  # Linux: ASan + stackovf
nix run .#ci -- --test-extracted                     # --better-c/--wasm where used
nix run .#ci -- --verify --files README.md           # markdown examples
nix run .#ci -- --check-vcs-urls                     # unpinned GitHub URLs
nix run .#ci -- --check-docs-sidebar                 # sidebar ↔ pages
nix run .#ci -- --check-spec-evidence                # spec evidence cites what exists
nix run .#ci -- --check-blob-paths                   # local only, see below
```

`--check-blob-paths` checks that a SHA-pinned citation names a path that exists
at that SHA (`git cat-file -e` against the upstream clones under `$REPOS`) — the
404 `--check-vcs-urls` cannot see. Uncloned repositories report as unchecked,
so it is neither a hook nor a CI job: run it before publishing a research catalog.

### What the default branch reports

`main` does not re-run CI. `.github/workflows/main-checks.yml` compares the
landed (rebased) tree with the tree the pull request built: equal trees get the
PR's checks mirrored onto the commit; different ones call `ci.yml` as a reusable
workflow. Rehearse it with
`nix run .#ci-minimal -- --mirror-checks --repo PetarKirov/sparkles --sha "$(git rev-parse origin/main)" --dry-run`
(`--ci-stats --merges` measures the split). Before touching the workflows:

- **Jobs that only talk to an API use `.#ci-minimal`** — the same binary without
  the compiler toolchain in its runtime closure (121 MiB vs 2.4 GiB).
  `--test`, `--test-extracted`, and `--example-files` need `.#ci`.
- **Every `ci.yml` job runs on every trigger; select work through the trigger
  list.** A called workflow sees the _caller's_ event (`push` on the rebuild
  path), and the merge-queue run is the only one that sees the batched result —
  an `if:` guard on either silently builds nothing and reports green.
- **The networked link sweep is `link-check.yml`**, nightly, reconciling one
  issue via `ci --report-link-rot`. PRs run `lychee-offline` on the tree and the
  networked check on their own diff.

## Code Style & Idioms

Follow [Code Style](./code-style.md) (module layout, imports, DIP1009
contracts, DIP1030 named arguments) and prefer UFCS range pipelines per the
[functional guidelines](./functional-declarative-programming-guidelines.md).

### Shortened function syntax & imports

Write single-expression functions in the `=>` form:

```d
bool active() const @safe pure nothrow @nogc => _active;
```

A local `import` forces a braced body, so hoist it to a module-level selective
import (`import std.conv : text;`). Keep local imports for already-braced
bodies that scope a heavy dependency. Examples (`libs/*/examples/*.d`) use
module-level selective imports throughout.

### Safety attributes — annotate non-templates, infer on templates

- **Non-templates:** annotate explicitly (`@safe pure nothrow @nogc`; a
  module-level `@safe pure nothrow:` block is fine).
- **Templates** — and anything generic over a caller-supplied `Writer`/`Hook` —
  let attributes infer, so non-`@safe` writers stay accepted. Annotate a
  template only when the attribute is intrinsic (`recycledErrorInstance` is
  deliberately `@system`).
- **`@trusted`** wraps only the unavoidable operation, in a lambda or block —
  never a whole function, never a template. Often it can be sidestepped:
  `char[1] a = c; put(w, a[]);` keeps a writer call `@safe`.

### Preview flags

Each sub-package's `dub.sdl` sets `dflags "-preview=in" "-preview=dip1000"`
(unittest builds add `-checkaction=context -allinst`); the root `dub.sdl` has
none. Some Phobos functions reject `scope` (`std.regex.replaceAll`, reached via
`unstyle`): on "scope parameter may not be returned", relax that one parameter
to `const(char)[]` or pass by value.

### Error handling — `Expected` in `@nogc nothrow` code

`@safe pure nothrow @nogc` code reports errors with
[`expected`](https://github.com/tchaloupka/expected) (`~>0.4.1`): `ok(v)` /
`err!T(e)`, `hasValue`/`hasError`, chained with `map`, `mapError`, `andThen`,
`orElse`. An `Expected` is a range, so `joiner` flattens results and drops
errors. A path that must still throw in `@nogc` uses
`recycledErrorInstance!T("msg")` (`sparkles.base.lifetime`). Full guide:
[Expected Error Handling](./idioms/expected/index.md).

### `@nogc` primitives (and what breaks `@nogc`/`nothrow`)

Use a `sparkles.base.buffer` buffer where `appender` would allocate, and let
the alias state what it may do ([spec](../specs/base/buffer.md)):

| Alias                 | Reach for it when                                                                        |
| --------------------- | ---------------------------------------------------------------------------------------- |
| `UniqueBuffer!(T, N)` | **The default.** One owner; move-only, so growth carries no refcount.                    |
| `SharedBuffer!(T, N)` | Copies genuinely happen (copy-on-write) — naming it claims that something copies.        |
| `InlineBuffer!(T, N)` | The bound is hard and overflow is reported; not an output range — write with `tryWrite`. |
| `HeapBuffer!T`        | An inline array would be dead weight; size it with `reserve`.                            |

Other combinations spell the policy out: `Buffer!(T, N, storage)`.

Format and parse numbers with `sparkles.base.text.writers`/`.readers`; `.text`,
`std.conv`, and `std.format` allocate. `splitter(' ')` and `std.utf` can throw
`UTFException`, so `nothrow @nogc` paths use the `text` package too. Manual
allocation uses `pureMalloc`/`pureFree`; known sizes use static arrays.

### Strings, and the C boundary

**A D API takes `string` or `in char[]`; NUL-termination happens at the C
seam** — `InitWindow(…, title.ptr)` shipped a macOS crash because a D slice
has no terminator. `sparkles.base.text.cstring` has one tool per lifetime:

| Need                                    | Use                                          |
| --------------------------------------- | -------------------------------------------- |
| Hand a C string to a call, nothing more | `toTempStringz`                              |
| The buffer outlives the call (a field)  | `stringz` on it                              |
| Input has a known bound                 | `CString!N` via `toCString` / `tryToCString` |
| Name a literal as a C string            | `cstr!"…"`                                   |
| A pointer arriving _from_ C             | `CStr.fromStringz`                           |
| Append a terminator into a writer       | `writeStringz`                               |

```d
SetWindowTitle(title.toTempStringz.ptr); // temporary lives past the call
```

> [!WARNING]
> Name the _buffer_ (`auto z = s.toTempStringz;`), never its pointer:
> `auto p = s.toTempStringz.ptr;` dangles once the statement ends, and dip1000
> does not catch it. `std.string.toStringz` fits a GC-owned string that must
> outlive the call.

Render plain interpolated text with `writeText` (no markup parsing); reserve
`writeStyled` for `{red …}` style templates — it eats braces in, say, a
filename. Outside `@nogc`, `std.conv.text(i"…")` does the same job. See
[Write `@nogc` text](../libs/base/how-to/write-nogc-text.md).

### Output ranges

Rendering functions take any output range (`ref Writer writer`) rather than
returning a `string`, so callers choose `appender`, a `Buffer`, or a stream.

## Testing

- Follow every public function with a DDoc'd (`///`) unittest.
- Name tests with a string UDA, `@("Module.function.case")`.
- Give every unittest an explicit `@safe` or `@system` (never `@trusted`), plus
  `pure`, `nothrow`, `@nogc` wherever they hold — and check that an accidental
  allocation has not quietly relaxed them.
- Environment-dependent tests (perf counters, root-only interfaces, missing
  toolchains) call `skipTest(reason)` from `sparkles.test_runner.skip`; an early
  `return` counts a degraded environment as a pass.
- Assert rendered text with the helpers, which diff on mismatch and stay
  `@safe pure nothrow @nogc`: `checkWriter!((ref b) => …)("expected")` and
  `checkToString(value, "expected")` from `sparkles.base.buffer`;
  `checkRoundTrip`/`checkRejects`/`checkAscending` from
  `sparkles.versions.testing` for version schemes.
  ([How-to](../libs/base/how-to/test-with-check-helpers.md).)

```d
@("MyType.toString.basic")
@safe pure nothrow @nogc
unittest
{
    import sparkles.base.buffer : checkToString;
    checkToString(MyType(42), "MyType(42)");
}
```

## Examples & Documentation

### Where docs live

Cross-cutting guides in `docs/guidelines/`; per-library Diátaxis docs in
`docs/libs/<name>/`; research catalogs in `docs/research/<topic>/` (follow
[Writing Research Docs](./research-docs.md)); specs in `docs/specs/` (follow
[Writing Specification Docs](./spec-docs.md)).

### The docs sidebar is data

`docs/.vitepress/sidebar.json` (the sidebar tree) and
`docs/.vitepress/docs-config.json` (`srcExclude`) are the single source of
truth, read by `config.mts` as JSON imports, by `ci --check-docs-sidebar`, and
by `ci --audit-fences`. Edit the JSON — `config.mts` only passes it through.

To add a page, add `{ "text": "…", "link": "/route" }` to the right group (a
group is `{ "text", "collapsed": true, "items": [ … ] }`); the link is the route
— leading `/`, no `.md`, `/dir/` for `dir/index.md`. Then run
`ci --check-docs-sidebar`.

The glossary is data too: `docs/.vitepress/glossary.json` (schema:
`sparkles.docs.glossary`) renders the `/glossary` page and every
`<GlossaryList owner="…" />`, and `ci --check-glossary` validates it together
with every docs link into it. Link a term to `…/glossary.md#<id>`; never
redefine it in prose. See
[Writing Specification Prose](./spec-prose.md#link-terms-to-the-glossary).

### Runnable README examples

A new feature gets a runnable README example: a `d` fence holding a dub
single-file program, followed by an ` ```ansi ` fence with its verbatim output
(escape sequences included — colour survives on VitePress and GitHub):

````markdown
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_my_feature"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.my_module;

void main() { /* … */ }
```

```ansi
Expected output here
```
````

`--verify` treats only an output-labelled fence as expected output. The legacy
` ```[Output] ` label still verifies but strips colour; convert any you touch
to `ansi` by regenerating it.

```bash
nix run .#ci -- --verify --files README.md   # check
nix run .#ci -- --update --files README.md   # regenerate the ansi blocks
nix run .#ci -- --files README.md            # just run
```

README examples use `version="*"` (readers copy them), so `dub add-local <repo>`
first to verify against the working tree.

<div v-pre>

### Dynamic output with `<!-- md-example-expected -->`

For timestamps, paths, or durations, place a `<!-- md-example-expected -->`
comment between the code and the `ansi` block. `--verify` matches its pattern
against the **ANSI-stripped** output, with `{{_}}` matching any non-empty text,
while readers see the literal block:

````markdown
<!-- md-example-expected
[ {{_}} | info | {{_}} ]: Server started
-->

```ansi
[ 14:32:01 | info | app.d:12 ]: Server started
```
````

</div>

### In-repo dub dependency paths

Everything inside the repo — `dub.sdl` files, single-file examples, guideline
snippets — depends on siblings through a relative `path=` to the repo root:
`libs/base/dub.sdl` and `docs/guidelines/*.d` use `path="../.."`;
`libs/<lib>/examples/*.d` uses `path="../../.."`. Only `README.md` keeps
`version="*"`.

## Conventions

### Commit messages

Conventional commits, `<type>(<scope>): <description>`. Types: `feat`, `fix`,
`refactor`, `docs`, `build`, `ci`, `test`, `style`, `chore`, `config`; `!` after
the scope marks a breaking change. Wrap the body at 80 columns after a blank line.

Use the most specific scope that is still short and obvious:

| Form                         | Example                                                      |
| ---------------------------- | ------------------------------------------------------------ |
| `{lib}.module`               | `fix(base.buffer): saturate grownCapacity on overflow`       |
| `{pkg}/subdir`               | `feat(core-cli/examples): add animated streaming table demo` |
| `docs(research/{topic})`     | `docs(research/window-system-integration): add NDK example`  |
| whole package, when cohesive | `feat(terminal): implement text selection`                   |
| tool or config area          | `config(lychee): …`, `ci(gh-actions): …`                     |

A bare top-level scope (`base`, `docs`, `nix`, …) fits genuinely cross-cutting
work; `nix` covers both `sparkles:nix` and the flake.

**Backtick `@`-tokens in commit messages, PR/issue text, and comments**
(`` `@safe` ``, `` `@nogc nothrow` ``, `` `@property` ``): GitHub renders a bare
`@name` as a mention of a real account. Backtick `` `#123` `` and SHAs you do
not want cross-linked too. Committed source and Markdown files are unaffected.

### Git hygiene & atomic commits

- **Confirm the branch before any commit, amend, or rebase**; branch off the
  default branch first.
- **Commit at each significant step**, without waiting to be asked. Pushing
  needs an explicit ask — except documentation work, which, once committed,
  validated, and rebased, you push and open as a PR.
- **Each commit is atomic and green** (build + test + lint on its own); tweaks to
  an earlier commit go in as `git commit --fixup=<sha>`. CI builds only a PR's
  tip, so check the rest before pushing a series:
  `nix run .#ci -- --build-each-commit` builds every commit since the merge-base
  with `origin/main` in a scratch worktree (`--base <ref>`, `--packages <name>…`;
  by default `hue`, `ui-gallery` and `diagram`, whose GUI configurations
  `dub test` never compiles).
- **Before opening a PR, rebase onto a fresh `origin/main`** with
  `git rebase --update-refs` (passed explicitly — it keeps a stacked series
  intact), rerun the affected validation, and update a pushed branch with
  `--force-with-lease`.
- **Back up a branch you are about to rewrite with a tag**
  (`git tag backup/<effort>-pre-rebase`): `--update-refs` moves backup
  _branches_ along with the rewrite.
- **At the end of a session, propose tidying the branch** (autosquash fixups,
  every commit green, related commits adjacent, preparation commits — config,
  dependencies, scaffolding — first) and rewrite only once the user agrees.

### Pre-commit hooks (`prek`)

Hooks run on commit and may modify or block it; each bypasses with
`SKIP=<hook> git commit …`. Implement new hook logic in D (see
[Scripts are D](#scripts-are-d)).

- **editorconfig-checker** — 4-space-multiple indentation, DDoc bodies included.
- **prettier** — reformats markdown; re-check tables of literal data afterwards
  (it once turned `5.004_05` into `5.004*05`).
- **verify-md-examples** — runs the example verifier; OOM-prone on large runs.
- **detailed-scope** (`commit-msg`) — flags useless scopes (`wip`, `misc`) and
  suggests a narrower one when the diff is localized.
- **check-vcs-urls** — staged `.md` files must pin `github.com`/
  `raw.githubusercontent.com` URLs to a 40-character SHA (`$`/`%` placeholders
  are skipped).
- **check-docs-sidebar** — whole-tree sidebar ↔ pages check whenever `docs/`
  is staged.
- **check-spec-evidence** — resolves every symbol, file and sub-package a spec's
  evidence column cites, whenever a spec, a D source or a `dub.sdl` is staged.
  Citations stale when it became a gate are listed in
  `docs/specs/evidence-backlog.txt`, which may only shrink: a new unresolved
  citation fails, and so does a listed one that now resolves (delete its line).
  Only rows that claim delivery are checked: a row whose status is
  `not started`, `researched`, `deferred`, `planned`, `proposed` or `open`
  names code it will be, not code that exists. So fix a backlog row by citing what
  satisfies it, or, if it was never delivered, by giving it that status.

## Pitfalls Checklist

- [ ] New files are `git add`ed before a flake build.
- [ ] After editing `apps/ci`, run it via `dub run :ci` / `nix run .#ci`.
- [ ] Tests live in feature modules, never `package.d`.
- [ ] Templates infer attributes; `@trusted` wraps one operation.
- [ ] `nothrow @nogc` paths use the `text` package, not `splitter`/`std.utf`/`std.conv`.
- [ ] D APIs take `string`/`in char[]`; a `toTempStringz` buffer is named, its `.ptr` is not.
- [ ] Example output blocks are ` ```ansi `.
- [ ] Cross-module-but-internal symbols use `package` visibility.
- [ ] Symbols used only as UDAs are camelCase.
- [ ] C headers come from `pkg-config`.
- [ ] Large value types in a unittest (`MatcherWorkspace`, `DqlEngine` scratch, …)
      are heap-owned (`Unique`/`HeapBuffer`): test workers have 512 KiB stacks and
      a 384 KiB watermark fails the test.
- [ ] A git call naming its repository (`-C <dir>`, a `workDir`, a path) goes
      through `runGit` (`sparkles.build_primitives.git_env`). Git exports
      `GIT_DIR` to every child it spawns (rebase exec, hooks, `bisect run`), and
      an inheriting `git init` fixture has twice set `core.bare = true` in this
      repository. Tools that mean the ambient repository (`ci` under a hook,
      `release`) keep inheriting.
- [ ] Dependency version changes update both `dub.selections.json` and
      `nix/dub-lock.json`.
- [ ] After changing `sparkles.ui.effect_shaders` or `libs/ui/shaders/effects.d`,
      regenerate with
      `nix run .#shader-compile -- --package=libs/ui --out=libs/ui/src/sparkles/ui/shaders`
      and commit the result (`--verify` reports staleness). `@compute`
      modules hold no string literals (a test name is one), so their tests live
      in a host-only module.

## Dependencies

D dependencies are pinned in `dub.selections.json` and `nix/dub-lock.json`;
`expected` (`~>0.4.1`) is a runtime dependency of `base` and `versions`. System
tools, `delta` included, come from the flake.
