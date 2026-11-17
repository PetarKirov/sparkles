---
status: draft
owner: sparkles:wired
reviewed: 2026-11-17
---

# `sparkles:wired` — WebAssembly builds

## Abstract

`sparkles:wired` compiled to WebAssembly, for four consumers: Nix
evaluation, which reads every `dub.sdl` in the repository through the
evaluator's `builtins.wasm` instead of regular expressions; a documentation
playground; an npm package for JavaScript and TypeScript tooling; and any
WebAssembly program that depends on the library. One D core does the work,
and each host gets a thin entry layer over it. A Nix evaluation that cannot
run WebAssembly keeps a fallback, and a check holds the two paths to the
same answers.

## Introduction

Sparkles' Nix code needs to know what its dub recipes say. The flake computes
each application's source closure, the components it ships, and the
manifests dub needs on disk by following `dependency`, `subConfiguration`,
`importPaths` and `sourcePaths` through every `dub.sdl` it reaches. It does
this during evaluation, where no D program can run, so
`nix/packages/manifest-graph.nix` reads the recipes with regular expressions
and hand-written brace matching. [Lossless editing §7](../sdl/editing.md#7-migration-coverage)
records that as an accepted exception to SDE9: a construct those readers
misread is a Nix bug, found only when a build goes wrong.

The same parser has three more audiences. The documentation site already
runs Sparkles' D code in the browser, through the WebAssembly modules of
the [toolchain's module contract](../../toolchain/wasm-modules.md), and a
playground for JSON and SDL documents belongs beside the cell explorer and
the table playground. Editors and web tools written in JavaScript want a
parser for `dub.sdl` and `dub.json` that agrees with the one dub-adjacent
Sparkles tools use. And a library that only builds natively cannot be a
dependency of anything that targets WebAssembly.

Some Nix implementations now run WebAssembly during evaluation:
Determinate Nix's `builtins.wasm`, behind the experimental `wasm-builtin`
feature, calls a module with a Nix value and receives one back. Upstream
Nix has the same builtin under review. A prototype on this specification's
branch runs the repository's own `parseDubManifest`, compiled for
`wasm32-unknown-wasip1`, as such a module, and on every recipe in the
repository its answers equal the regular-expression readers'
([§8](#_8-prototype-evidence)).

The approach is one core with per-host entry layers. The core is the
existing D code (the SDL and JSON readers and writers, the typed codecs,
and the dub recipe schema), built for WebAssembly with its runtime.
Each host's entry layer converts between that core's values and the
host's: Nix values through the evaluator's host functions, the shared
memory interface for the site, a JavaScript API for npm. No entry layer
holds parsing or schema logic of its own.

Out of scope: lossless editing, open documents and path selectors (the
SDL editor stays native); typed decoding into schemas other than the dub
recipe; and the Nix readers of single-file examples' embedded recipes
(`example-catalogue.nix`, `android/examples.nix`), which a later slice may
add once the recipe table of WW9 exists. The JSON and SDL parsers' own
correctness is their packages' concern; this specification covers what
building, calling and delivering them as WebAssembly adds. The delivery
order is in [PLAN.md](./PLAN.md); decisions and open questions are in
[§7](#_7-decisions-and-open-questions).

## Contract at a glance

1. One D core; an entry layer converts values and owns no parsing.
2. The Nix module answers with a typed recipe, and reports a bad recipe as
   data, never by aborting evaluation.
3. Each recipe is parsed at most once per evaluation, whichever reader
   parsed it.
4. A Nix without `builtins.wasm` evaluates to the same result through the
   fallback; a check compares the two on every recipe.
5. The module reaches an evaluation without import-from-derivation.

## 1. The core

**WW1: Buildable core.** _(Owner: `sparkles:wired`.)_ The JSON and SDL
document readers and writers, the typed codecs, and the dub recipe schema
(`parseDubManifest`, `parseDubJsonManifest`, `parseEmbeddedDubManifest`)
**must** build for `wasm32-unknown-wasip1` with the toolchain of
[TCW](../../toolchain/wasi.md), with no source change specific to that
target beyond `version (WASI)` entry layers. The recipe schema **must** live
in a package whose dependencies build for that target; today it is a module
of `sparkles:build-primitives`, whose event loop does not ([D3](#d3-where-the-recipe-schema-lives)).

**WW2: Entry layers convert, nothing more.** _(Owner: each entry layer.)_
An entry layer **must** reach every parse, validation, format and typed
decode through the core's public functions; it **must not** match recipe
text, choose defaults, or reimplement a schema rule. A difference between a
module's answer and the native function's on the same input is a defect of
the entry layer or the toolchain.

## 2. The Nix module

The host interface is Determinate Nix's, specified by its manual's
[Wasm host interface](https://github.com/DeterminateSystems/nix-src/blob/abe7d1f4a79effbd33040f10600f68a1b87e3943/doc/manual/source/protocols/wasm.md)
page; this section fixes how Sparkles uses it.

**WW3: Calling convention.** _(Owner: the Nix entry layer.)_ The module
**must** be a WASI command module: the evaluator runs `_start` with the
argument's value identifier in `argv[1]`, and the module returns its result
through `return_to_nix`. It **must** import only `env` host functions and
`wasi_snapshot_preview1`. Its argument is the recipe's text as a Nix string
and, optionally, its file name for diagnostics, as
`{ text; name ? "dub.sdl"; }`; a bare string **must** be accepted as
`{ text = s; }`. The format follows the name, as the schema's `parseDubRecipeText`
reads it: a name ending `.json` is JSON, one ending `.d` a single-file
package's embedded recipe, anything else SDL.

**WW4: Result shape.** _(Owner: the Nix entry layer.)_ A recipe decodes to
`{ recipe = <attrs>; }`, where `<attrs>` mirrors the schema's D aggregates:
an aggregate becomes an attribute set, an array a list, a string a string,
a `bool` a Boolean. Attribute names are the D field names with a trailing
`_` removed (`version_` becomes `version`). A field whose value is empty (an
empty string or list, `false`, or an aggregate whose fields are all empty)
**must** be absent, and a reader takes it with `or` and the empty value.
The schema's catch-all for unknown directives is never emitted: the schema
rejects what it does not name (WW5).

**WW5: Errors are values.** _(Owner: the Nix entry layer.)_ For text the
SDL or JSON reader rejects, or a recipe the schema rejects, the module
**must** return `{ error = { name; line; column; code; message; }; }`:
positions 1-based as the native reader reports them, `code` the
`SdlErrorCode` member's name, and `message` the native rendering without
the `name(line:column): ` prefix the other fields carry. It **must not**
call `panic` or trap. `panic` is reserved for a broken calling convention: a missing or
non-string argument. A caller turns an error into `throw` with the name and
position in the message, so a recipe that dub would reject stops the
evaluation where it is read.

**WW6: No collection.** _(Owner: the Nix entry layer.)_ The evaluator
instantiates a module afresh for every call and drops its memory when the
call returns, so the module **may** run its garbage collector without
collecting (`gcopt=gc:manual`). It **must not** rely on state surviving
between calls.

**WW7: Detection and fallback.** _(Owner: Sparkles' Nix code.)_ The Nix
code **must** use the module when `builtins ? wasm` holds and the regular
expression readers otherwise, choosing once per evaluation. The two paths
**must** yield equal recipe facts (WW9) for every recipe the evaluation
reads; a difference on a repository recipe fails WW10's check. The
fallback stays until the evaluator Sparkles' CI and dev shells run has the
builtin enabled; removing it is a decision of its own, made after that.

**WW8: No import-from-derivation.** _(Owner: Sparkles' Nix code.)_ The
module an evaluation calls **must not** be an output of that evaluation's
own derivations, so evaluation never waits for a build. It arrives as a
pinned module fetched by hash ([D2](#d2-how-the-module-reaches-evaluation));
until the pin exists, the Nix path is enabled only where the module is
supplied explicitly.

## 3. The recipe table

**WW9: One read per recipe.** _(Owner: Sparkles' Nix code.)_ The Nix code
**must** read the recipes through one attribute set built once per
evaluation, keyed by repository-relative directory, whose values are the
recipe facts. Each value is computed lazily, so an evaluation parses only
the recipes it reaches and each at most once. The facts are what the
closure walks consume, the same from either reader:

| Fact             | Meaning                                                                                                                                                                                                        |
| ---------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `subPackages`    | the root's `subPackage` paths, in order (root only)                                                                                                                                                            |
| `configurations` | configuration names, in declaration order                                                                                                                                                                      |
| `edges.<scope>`  | for the preamble and each configuration: in-tree dependency names, `subConfiguration` choices, and the in-tree packages named by `../<name>/src` or `../../libs/<name>/src` in `importPaths` and `sourcePaths` |

Comments are not edges: a dependency quoted in a `//` comment **must not**
appear in the facts. The fileset walk and the shipped-components walk
differ in which scopes they follow, not in how scopes are read.

**WW10: Agreement check.** _(Owner: `sparkles:ci`.)_ A check run by Nix
**must** compute the facts of every recipe the root `dub.sdl` declares with
both readers and fail on any difference, naming the directory. It runs
only where the module can run (WW7, WW8); elsewhere it reports itself as
not run, never as passed. Seeded fixtures on which the readers
`manifest-graph.nix` used before the table were wrong **must** be among its
inputs, and the check **must** confirm that older reader still disagrees
with the module on each, so it is seen to catch what it is for: a
dependency quoted in a `//` comment, and a top-level `dependency` written
after a configuration, which reading the text before the first
`configuration` lost. (A `unittest` configuration that is not last is not
one: both readers stop at it.)

**WW11: Evaluation cost.** _(Owner: Sparkles' Nix code.)_ Reading every
recipe the root declares through the table **must not** take longer with
the module than with the fallback, its compilation cached; and evaluating
every package of the flake through the table **must not** take longer than
through the readers it replaced. [§8](#_8-prototype-evidence) has the
measurements. The whole-flake time is the second clause's and not the
first's because the recipes are a small share of it: its spread between
runs is larger than either reader's cost.

## 4. The documentation playground

**WW12: A site module.** _(Owner: `sparkles:wired`.)_ The playground's
module **must** be a reactor of the [toolchain's module
contract](../../toolchain/wasm-modules.md), sharing its memory interface
(TCM5), its loader (TCM7) and its native agreement check (TCM9), and
exporting parse with diagnostics, canonical format, and typed recipe decode
for JSON and SDL through one export, `spk_wired_run`: it **must** answer a
JSON request `{ op, format, text, name? }` with one JSON response.
`op` `parse` answers `{ tree }`: for JSON the value; for SDL the top-level
tags as `{ name, line, values, attributes, children }`, each value
`{ kind, text }`, `kind` the scalar kind without a trailing `_` and `text`
its canonical SDL spelling. `format` answers `{ text }`: SDL written
canonically, JSON indented by two spaces with members in source order.
`recipe` answers what the Nix module answers for `{ text; name; }` (WW4,
WW5), byte for byte. Text that does not parse answers WW5's `{ error }`; a
request that is not one of these answers `{ fault }`, and the call returns
`-1` only when the response does not fit or a range is invalid (TCM5).

## 5. The npm package

**WW13: One package, two runtimes.** _(Owner: `sparkles:wired`.)_ The npm
package `@sparkles-pkgs/wired` **must** be an ES module with TypeScript
declarations that loads in Node.js and in browsers, exposing parse with
diagnostics, canonical format, typed recipe decode, and the generic
document tree for JSON and SDL. Its module **must** be built from the same
core as WW12's; whether it is the same module is [D6](#d6-the-npm-module).

**WW14: Published from CI.** _(Owner: `sparkles:release`.)_ The package
**must** be published by a release workflow through npm's trusted
publishing (OpenID Connect from GitHub Actions), with provenance, and no
long-lived npm token in the repository's secrets. Its version follows
`sparkles:wired`'s under the monorepo's
[release rules](../../../guidelines/release.md).

## 6. Portability

**WW15: Tested on WebAssembly.** _(Owners: `sparkles:wired`,
`sparkles:dub-manifest`.)_ For each format (JSON and SDL) the document
reader and writer, the typed codec in both directions, and the reporting
of malformed input, and for the recipe schema each recipe form and its
rejections, **must** be exercised by `@wasm` tests that run under the test
runner's `--wasm` mode in CI (`ci --test-extracted`). They are written
against the public API, each importing what it uses, because an extracted
test sees nothing of its module; the rest of the core's tests are not
extracted, and a construct that only they reach is not covered.
The module packages of WW3, WW12 and WW13 **must** be built by
`ci --build-each-commit`, like the modules of TCM2.

## 7. Decisions and open questions

### D1: The target

**Accepted** (prototype evidence, 2026-11-17). Build for
`wasm32-unknown-wasip1` with druntime and Phobos. The schema's decode and
the SDL reader allocate through the garbage collector, so a freestanding
build without the runtime would mean rewriting them; the prototype shows
the runtime costs 0.04 ms a call to start and adds no failure.
Revisit if a consumer needs a module much smaller than about 1.1 MB.

### D2: How the module reaches evaluation

**Accepted: option 1, a pinned module** (owner, 2026-11-17). The module is
a build output, and WW8 forbids building it during the evaluation that
uses it. A pinned module is not only slower when stale: one built before a
schema change rejects a recipe that uses the change, and the evaluation
throws (WW5). So WW10's check **must** run with the pinned module as well
as with the tree's, and a change that makes the pinned module reject or
disagree on a repository recipe **must** move the pin in the same pull
request. The options considered:

1. **A pinned module**, like `nix/test-runner-pin.json`: a revision's
   module, published (a GitHub release asset or the Cachix cache) and
   fetched by hash during evaluation. A check rebuilds the pinned revision
   and requires a byte-identical module. A schema change reaches
   evaluation only when the pin moves.
2. **The module committed** under a generated path, with a check that the
   tree's build reproduces it byte for byte. Simplest to consume; breaks
   the rule TCM3 states for the site's modules, and adds about 1.1 MB per
   change to history.
3. **Import-from-derivation**, accepted for this one case. Rejected once
   for the regular-expression readers' replacement
   ([editing §7](../sdl/editing.md#7-migration-coverage)); evaluation would
   build the module and its toolchain before it can finish.

Option 1 was chosen for evaluation that never waits for a build and a
tree that carries no binary; its cost is the pin's lag, bounded by the
check above. Where the module is published and how the pin is moved are
W4's to settle.

### D3: Where the recipe schema lives

**Accepted: a sub-package of its own** (owner, 2026-11-17).
`dub_manifest.d` depends only on `sparkles:wired` and Phobos, but its
package, `sparkles:build-primitives`, depends on event-horizon, which does
not build for WebAssembly; the prototype compiles the one file directly.
The schema moves to a sub-package, `sparkles:dub-manifest`, depending on
`sparkles:wired` and `sparkles:base` alone, and `build-primitives` depends
on it. The alternative, moving it into `sparkles:wired`, was declined to
keep `wired` free of dub's vocabulary. The module keeps its name,
`sparkles.build_primitives.dub_manifest`: its importers across
`build-primitives` and `apps/ci` read it unchanged, and so does the build
graph's work in progress. The tests that list the repository's recipes
with `runGit` stay in `build-primitives`, in `dub_manifest_corpus.d`.

### D4: The Nix attribute names

**Proposed** (WW4). D field names, trailing `_` dropped, empty fields
absent. The alternative, dub's own directive spellings (`dependency` for
`dependencies`), reads closer to the recipe and further from the D API
that the documentation describes.

### D5: Which evaluator

**Accepted** (owner had no preference; 2026-11-17). Detect and fall back
(WW7) rather than move Sparkles to Determinate Nix or wait for upstream.

### D6: The npm module

**Accepted: the site's module** (2026-11-17). WW12's single request
export carries every operation the package offers, so the package wraps
`spk-wired.wasm` in JavaScript rather than building a module with an
export set of its own; one module is built and checked once (TCM9), and
the site and the package cannot drift apart.

## 8. Prototype evidence

Revision `92a4cfa0e` (branch `feat/wired-wasm-nix`, not merged), in
`libs/build-primitives/nix-wasm`: WW3's calling convention with a bare
string argument, WW4's shape, WW6; errors still `panic` (WW5 unmet).
Determinate Nix 3.24.2 with `wasm-builtin`, x86_64-linux, LDC 1.43 (the
flake's WASI build), `wasm-opt -Oz` from binaryen 133.

| Measurement                                            | Result                                                         |
| ------------------------------------------------------ | -------------------------------------------------------------- |
| Agreement with `manifest-graph.nix` (`agree.nix`)      | all 73 sub-package recipes and the root's `subPackage` list    |
| Module size                                            | 1.12 MB, 250 KB gzipped                                        |
| One call, the repository's recipes (4.1 KB mean)       | 0.294 ms; native `parseDubManifest`, the same inputs: 0.110 ms |
| Of which: instantiation and runtime start              | 0.04 ms                                                        |
| Recipe reads in an evaluation of every flake package   | 4409, about 60 a recipe                                        |
| 60 reads a recipe: regular expressions, as today       | 0.57 s, 97 MB                                                  |
| 60 reads a recipe: the module, each recipe parsed once | 0.11 s, 59 MB                                                  |

Per-call times are the slope between 50 and 200 rounds over the 73
recipes, each round's text varied by a comment so nothing is shared, best
of three. The regular-expression readers would gain from WW9's table too:
one pass over every recipe costs them about 0.02 s, so with the table they
stay faster than the module, and WW11 compares the two paths with the
table in both.

What the prototype does not establish: WW5's error values, WW8's delivery,
the shipped-components walk's facts (it compared only the fileset walk's
edges and the `subPackage` list), JSON recipes, and anything of WW12–WW15.

### Delivered evidence

Determinate Nix 3.24.2 with `wasm-builtin`, x86_64-linux; the module built
by the flake (`dub-manifest-nix-wasm`, 1.21 MB). `nix run .#check-nix-wasm`
runs both checks; CI runs it in the `nix-wasm` job.

| Requirement     | Evidence                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| WW3–WW6         | `dub_manifest_nix.respond.recipe`, `.namesChooseTheFormat`, `.errorsAreValues`, `.faults`, `dub_manifest_nix.toNix.omitsEmptyFields`; `libs/dub-manifest/dub-manifest-nix-wasm/agreement.nix`: the module and the native oracle agree on all 169 tracked `dub.sdl` files (the tree holds no JSON recipe) and 11 fixtures (failures to lex, parse, decode a value, and validate; JSON syntax and schema; embedded and missing recipes)                                                              |
| WW9, WW10       | `libs/dub-manifest/dub-manifest-nix-wasm/facts-agreement.nix`: both readers' facts agree on the root and its 75 sub-package recipes and on 2 seeded fixtures, on each of which the older reader disagrees with the module; `runCheckNixWasm`                                                                                                                                                                                                                                                       |
| WW9 (no change) | every package, check and dev shell evaluates to the same derivation with the table as without it, except the stamped `hue` and `terminal` (whose build-info carries the revision) and `hue-apk-repo` (which hashes the tree); `hue`'s unstamped build is the same store path either way                                                                                                                                                                                                            |
| WW7, WW8, D2    | `nix/nix-wasm-pin.json` pins the module built at `64433fcf7`, published on the orphan branch nix-wasm-modules; `runCheckNixWasm` fetched it as evaluation does, found it equal byte for byte to a rebuild of that revision, and ran both agreement checks with it (181 answers, 79 facts). Evaluating every package, check and dev shell on Determinate Nix with `wasm-builtin`, which compiles and runs the pinned module, gives the same derivations as upstream Nix's regular-expression reader |
| WW12            | `wiredRun` and its `@wasm` tests; `libs/wired/wired-wasm/src/spk_wired_wasm.d`; `ci --check-wasm-modules`: the module and `wiredRun` run natively agree on 11 requests (each operation in each format, errors, a fault, a response too large), 35 of 35 cases with the other modules'; the page `docs/libs/wired/how-to/try-in-the-browser.md`                                                                                                                                                     |
| WW13, D6        | `libs/wired/wired-wasm/npm/index.js` and `index.d.ts` over the same module; its 6 tests (`libs/wired/wired-wasm/npm/test/index.test.mjs`) pass under node in the flake check npm-wired, run by the WebAssembly CI job                                                                                                                                                                                                                                                                              |
| WW14            | `.github/workflows/release.yml`, the npm publishing job (OpenID Connect, provenance, the version from the tag). Not yet run: it needs a release, and the package created and its trusted publisher configured on npmjs.com                                                                                                                                                                                                                                                                         |
| WW15            | `sparkles.wired.wasm_portability`, `sparkles.build_primitives.dub_manifest_wasm` and `spk_wired_wasm`: 4, 3 and 4 `@wasm` tests passing under wasmtime; `wasiPackages` and `defaultEachCommitPackages` (`apps/ci/src/each_commit.d`) hold both modules, so `ci --build-each-commit` builds them for wasm32 at every commit                                                                                                                                                                         |

WW11, best and median of three, every package, check and dev shell of the
flake on x86_64-linux:

| Reader                                     | Whole flake     | Peak RSS | Every recipe through the table |
| ------------------------------------------ | --------------- | -------- | ------------------------------ |
| Before the table (regular expressions)     | 13.62 s (13.90) | 1.74 GB  | —                              |
| The table, regular expressions             | 12.84 s (12.88) | 1.67 GB  | 0.10 s                         |
| The table, regular expressions, `--impure` | 13.27 s (13.56) | 1.67 GB  | —                              |
| The table, the module, `--impure`          | 13.51 s (13.63) | 1.68 GB  | 0.08 s                         |

The module's run needs `--impure` while it is supplied by path; the table
alone is faster with it than with the regular expressions.
