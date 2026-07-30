# Dub-project context (`PRJ`)

_**Status:** in progress · **Date:** 2026-07-30 · **Scope:** analyzing files
that belong to a real project — `sparkles.dmd_lsp.project`, the
`twoslash-extract --dub` surface, and the hue viewer path that will consume
them._

Everything the backend shipped so far analyzes a **sample**: a self-contained
buffer whose only context is `$SPARKLES_DMD_IMPORT_PATH` plus whatever
`// @import:`/`// @dflags:` it declares. A file from a real project is not
self-contained. It imports its siblings, it is compiled behind version
identifiers, and it may need string-import paths — all of which live in the
project's build recipe. Without them the analysis is not merely less precise,
it is **wrong in a way that looks like a source defect**: every sibling import
becomes an `unable to read module` error node in the payload.

The recipe is not parsed here. `dub describe` is asked, because dub owns
dependency resolution, sub-packages, path dependencies, platform blocks and
configuration inheritance, and any second implementation of that would drift.

Status legend and ID conventions: [hue spec](../hue/index.md#status-scheme).

## What it buys, measured

Extraction over two files of this repo, with and without the project context
(`hover` nodes / `error` nodes):

| File                                       | Bare analysis | With project context | The errors were                    |
| ------------------------------------------ | ------------- | -------------------- | ---------------------------------- |
| `libs/base/src/sparkles/base/text/width.d` | 242 / 11      | 281 / 0              | `unable to read module` (siblings) |
| `libs/dmd-lsp/src/sparkles/dmd_lsp/ddoc.d` | 362 / 24      | 762 / 0              | the whole `dmd.*` frontend surface |

`ddoc.d` is the extreme case and the reason the feature exists: its imports
resolve only through the frontend's own `-I`/`-J` paths, and its sources only
have meaning behind `LanguageServer`, `NoBackend` and `MARS` — twelve version
identifiers that no file-local directive would ever carry, and that dub already
knows.

## Discovery (`PRJ1`-`PRJ3`)

| ID   | Requirement                                                                                                                                                                                                                                            | Status            | Traces to            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | -------------------- |
| PRJ1 | The project is the **nearest enclosing recipe**: walk up from the file to the first `dub.sdl`/`dub.json`, so in a monorepo a file under `libs/base/src` belongs to `libs/base`, not to the root package. A file inside no project is not an error.     | full (`95a85f51`) | `findDubRecipe`      |
| PRJ2 | Build settings come from **`dub describe`**, never from reading the recipe: dependency resolution, path dependencies, sub-packages, platform blocks and configuration inheritance stay dub's job.                                                      | full (`95a85f51`) | `describeDubProject` |
| PRJ3 | The **configuration** and **build type** are selectable, and both default to dub's own defaults — the settings a plain `dub build` would use. The compiler need not be pinned: `--compiler=` only changes the flag spelling, and both spellings parse. | full (`95a85f51`) | `DubQuery`           |

## Translation to `AnalyzerConfig` (`PRJ4`-`PRJ6`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                 | Status            | Traces to                       |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------- |
| PRJ4 | The compiler-formatted settings line maps onto the analyzer's knobs: `-I` to import paths, `-J` to string-import paths, `-version=`/`-d-version=` to version identifiers, `-debug=`/`-d-debug=` to debug identifiers, everything else to dflags, where `applyDflags` keeps the subset it understands. Quoted paths survive. | full (`95a85f51`) | `parseDubBuildSettings`         |
| PRJ5 | Precedence is **caller, then project, then environment**: an explicit `--import`/`--dflags` stays ahead of the project's settings in the search order, and the runtime tail comes last.                                                                                                                                     | full (`95a85f51`) | `applyDubContext`; `runFile`    |
| PRJ6 | The frontend-matched druntime/phobos paths (`BLD3`) are **appended, never substituted**. dub reports a project's own sources and its dependencies; it knows nothing about the runtime the analysis needs, and no project path can stand in for `object.d`.                                                                  | full (`95a85f51`) | `DubProject.withRuntimeImports` |

## Failure, caching, latency (`PRJ7`-`PRJ9`)

| ID   | Requirement                                                                                                                                                                                                                                                                                               | Status            | Traces to                          |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ---------------------------------- |
| PRJ7 | A dub that fails (no dub on `PATH`, unresolvable dependencies, an unknown configuration) leaves a **reason** on the result, and a consumer that asked for project context surfaces it instead of analyzing without: a payload full of `unable to read module` nodes reads as a defect in the user's code. | full (`95a85f51`) | `DubProject.error`/`usable`        |
| PRJ8 | Results are **memoized per recipe and query** (configuration, build type, compiler), so a batch or a viewer pays discovery once per project rather than once per file; `clearDubProjectCache` drops it when a recipe changes.                                                                             | full (`95a85f51`) | `dubProjectFor`                    |
| PRJ9 | Discovery must never stall an interactive frame. Today the call is **synchronous** (0.04 s for a plain package, 0.5 s with a git dependency) with no timeout; an interactive consumer needs it off the render path, with a deadline.                                                                      | partial           | the async/deadline half is unbuilt |

## Extractor surface (`PRJ10`-`PRJ11`)

| ID    | Requirement                                                                                                                                                                                                                                                                                       | Status            | Traces to                       |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------- |
| PRJ10 | `twoslash-extract --dub` analyzes the input in its project's context; `--dub-config`/`--dub-build` select a configuration or build type. It is **off by default**, so a standalone sample is never influenced by a project that happens to contain it — the golden corpus lives inside this repo. | full (`59e623ff`) | `apps/twoslash-extract`; `EXT6` |
| PRJ11 | Directory mode forwards the flags to every child process, preserving one analysis per process (`EXT2`).                                                                                                                                                                                           | full (`59e623ff`) | `runDirectory`                  |

## Viewer surface (`PRJ12`-`PRJ16`)

The consumer this milestone exists for: opening a `.d` file in `apps/hue` and
seeing real types and real doc comments.

| ID    | Requirement                                                                                                                                                                                                                                                                                     | Status      | Traces to                            |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------ |
| PRJ12 | Opening a `.d` file **triggers discovery once**, on first open, keyed by project root and off the render path (`PRJ9`); every later file in the same project reuses it.                                                                                                                         | not started | `PRJ8`; hue's document-open path     |
| PRJ13 | hue must **not link `sparkles:dmd-lsp`**. DMD-as-a-library is one analysis per process (`COR2`/`EXT2`) and a viewer is long-lived, so live analysis is a `twoslash-extract` **subprocess** per file whose payload feeds the existing twoslash overlay. This is a constraint, not a convenience. | not started | `COR2`, `EXT2`; `--overlay twoslash` |
| PRJ14 | The resulting overlay attaches to the open document — hover types plus the ddoc body and tag chips — and re-extracts when the file changes on disk.                                                                                                                                             | not started | hue `TWH*`; `DOC2`                   |
| PRJ15 | Degradation is visible but never fatal: a file outside any project still analyzes with the environment defaults, and a describe failure is a dismissible notice, never a modal error and never a blank view.                                                                                    | not started | `PRJ7`; hue notifier spec            |
| PRJ16 | Per-file payloads are cached alongside the project context, so navigating back to a file is instant.                                                                                                                                                                                            | not started | `PRJ8`                               |

## Known limitations

- **Sub-packages declared inline.** A file under a directory whose package is
  declared as a `subPackage` block in the parent recipe (rather than by its own
  `dub.sdl`) resolves to the parent, so the described settings are the parent's.
  Selecting `dub describe :sub` from the file path is unbuilt.
- **Single-file recipes.** A `#!/usr/bin/env dub` program with an embedded
  `dub.sdl` comment is not a directory-level recipe, so the walk finds whatever
  project encloses it, or nothing.
- **`unittest` sources.** A file that only compiles under
  `configuration "unittest"` needs `--dub-build unittest` (or the equivalent
  configuration); nothing infers that from the file's contents.
- **Quoting.** The settings line is split on whitespace honoring double quotes.
  A path containing a quote character would not round-trip.

## Non-goals

- **Build systems other than dub** (meson, make, hand-rolled). The seam is
  `AnalyzerConfig`, so another provider can be added beside this one; none is
  planned.
- **Building anything.** Discovery never compiles, fetches on purpose, or
  writes to the project; it reads settings and stops.
- **Watching recipes.** Invalidation is a call (`clearDubProjectCache`), not a
  file watcher.

→ [Overview](./index.md) · [Feature requirements](./feature-requirements.md) ·
[DDoc test plan](./ddoc.md) · [hue twoslash surface](../hue/twoslash.md)
