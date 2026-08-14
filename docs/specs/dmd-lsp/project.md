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

## Discovery (`PRJ1`-`PRJ3`, `PRJ17`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status            | Traces to                                                             |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------- | --------------------------------------------------------------------- |
| PRJ1  | The project is the **nearest enclosing recipe**: walk up from the file to the first `dub.sdl`/`dub.json`, so in a monorepo a file under `libs/base/src` belongs to `libs/base`, not to the root package. A file inside no project is not an error.                                                                                                                                                                                                                                                                                   | full (`95a85f51`) | `findDubRecipe`                                                       |
| PRJ2  | Build settings come from **`dub describe`**, never from reading the recipe: dependency resolution, path dependencies, sub-packages, platform blocks and configuration inheritance stay dub's job. (One carve-out: subpackage **names** are read from the recipe for the `PRJ7` none-target fallback — dub offers no way to list them — but their settings still come from `dub describe --root=… :name`.)                                                                                                                            | full (`95a85f51`) | `describeDubProject`                                                  |
| PRJ3  | The **configuration** and **build type** are selectable, and both default to dub's own defaults — the settings a plain `dub build` would use. The compiler need not be pinned: `--compiler=` only changes the flag spelling, and both spellings parse.                                                                                                                                                                                                                                                                               | full (`95a85f51`) | `DubQuery`                                                            |
| PRJ17 | A **single-file package** — a `.d` program whose recipe rides in a leading `/+ dub.sdl: … +/` comment — is its own project, described with `dub describe --single <file>` rather than by climbing past it. A `libs/x/examples/*.d` sample routinely depends on packages `libs/x/dub.sdl` never mentions; resolving it to the enclosing library reports every symbol from those as `unable to read module`. The multi-package fallbacks (`PRJ7`) do not apply: such a recipe declares no subpackages and no `unittest` configuration. | full              | `isSingleFileDubPackage`; `dubRecipeFor`; test `project.singleFile.*` |

## Translation to `AnalyzerConfig` (`PRJ4`-`PRJ6`, `PRJ18`)

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                               | Status            | Traces to                                               |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------------------------------- |
| PRJ4  | The compiler-formatted settings line maps onto the analyzer's knobs: `-I` to import paths, `-J` to string-import paths, `-version=`/`-d-version=` to version identifiers, `-debug=`/`-d-debug=` to debug identifiers, everything else to dflags, where `applyDflags` keeps the subset it understands. Quoted paths survive.                                                                                                                                                               | full (`95a85f51`) | `parseDubBuildSettings`                                 |
| PRJ5  | Precedence is **caller, then project, then environment**: an explicit `--import`/`--dflags` stays ahead of the project's settings in the search order, and the runtime tail comes last.                                                                                                                                                                                                                                                                                                   | full (`95a85f51`) | `applyDubContext`; `runFile`                            |
| PRJ6  | The frontend-matched druntime/phobos paths (`BLD3`) are **appended, never substituted**. dub reports a project's own sources and its dependencies; it knows nothing about the runtime the analysis needs, and no project path can stand in for `object.d`.                                                                                                                                                                                                                                | full (`95a85f51`) | `DubProject.withRuntimeImports`                         |
| PRJ18 | A `libs` entry is resolved through **`pkg-config --cflags`** into `-P`-prefixed dflags, the same thing dub's generator does at build time and `describe` never does — `--data=libs` gives the bare names, `--data=dflags` has no `-P` in it. Without it an ImportC dependency analyzes as a few hundred undefined identifiers (`COR7` is the other half). Costs one extra `dub describe` on the settings path, memoized with the rest (`PRJ8`) and skipped when there is no `pkg-config`. | full              | `pkgConfigPreprocessorFlags`; `describedPkgConfigFlags` |

## Failure, caching, latency (`PRJ7`-`PRJ9`)

| ID                             | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Status                 | Traces to                                              |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------- | ------------------------------------------------------ |
| PRJ7                           | A dub that fails (no dub on `PATH`, unresolvable dependencies, an unknown configuration) leaves a **reason** on the result, and a consumer that asked for project context surfaces it instead of analyzing without: a payload full of `unable to read module` nodes reads as a defect in the user's code. A root package that has **no describable target** — `targetType "none"` (dub itself asserts, e.g. dlang/dmd) or a sourceless monorepo umbrella — falls back to the recipe's subpackages: each candidate is described as `--root=… :name` (never `name:sub`, which hits dub's global registry) and the one whose described `sourceFiles` contain the file wins; no owner leaves the candidate list on `.error`. | full (`95a85f51` + P1) | `describeOwningSubpackage`; tests `project.fallback.*` |
| PRJ8                           | Results are **memoized per recipe, resolved subpackage, and query** (configuration, build type, compiler) — the subpackage dimension keeps one file's none-target fallback from poisoning its siblings — so a batch or a viewer pays discovery once per (project, subpackage) rather than once per file; `clearDubProjectCache` drops it when a recipe changes.                                                                                                                                                                                                                                                                                                                                                          | full (`95a85f51`)      | `dubProjectFor`                                        |
| PRJ9 (see also the note below) | Discovery must never stall an interactive frame. Today the call is **synchronous** (0.04 s for a plain package, 0.5 s with a git dependency) with no timeout; an interactive consumer needs it off the render path, with a deadline.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     | partial                | the async/deadline half is unbuilt                     |

## Extractor surface (`PRJ10`-`PRJ11`)

| ID    | Requirement                                                                                                                                                                                                                                                                                       | Status            | Traces to                       |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ------------------------------- |
| PRJ10 | `twoslash-extract --dub` analyzes the input in its project's context; `--dub-config`/`--dub-build` select a configuration or build type. It is **off by default**, so a standalone sample is never influenced by a project that happens to contain it — the golden corpus lives inside this repo. | full (`59e623ff`) | `apps/twoslash-extract`; `EXT6` |
| PRJ11 | Directory mode forwards the flags to every child process, preserving one analysis per process (`EXT2`).                                                                                                                                                                                           | full (`59e623ff`) | `runDirectory`                  |

## Viewer surface (`PRJ12`-`PRJ16`)

The consumer this milestone exists for: opening a `.d` file in `apps/hue` and
seeing real types and real doc comments.

Shipped shape (P5): `apps/hue/src/live_types.d` owns one
`twoslash-extract --dub --serve --quiet` child per open document
(`LiveTypesSession` over `sparkles.core_cli.process_utils.ResidentProcess`).
Its first stdout line is the lazy payload — attached to the document, so every
hover span underlines immediately — and pointing at (GUI) or opening the popup
of (TUI) a lazy span sends `{"tip": <node>}` for that node alone. hue's own
requirements are `LIV1`-`LIV5` in
[`docs/specs/hue/twoslash.md`](../hue/twoslash.md).

| ID    | Requirement                                                                                                                                                                                                                                                                                     | Status       | Traces to                                                                                                                                                       |
| ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PRJ12 | Opening a `.d` file **triggers discovery once**, on first open, keyed by project root and off the render path (`PRJ9`); every later file in the same project reuses it.                                                                                                                         | full (P5)    | `apps/hue/src/live_types.d`; `gui.startLive` / `workspace.startLive`; hue `LIV1`                                                                                |
| PRJ13 | hue must **not link `sparkles:dmd-lsp`**. DMD-as-a-library is one analysis per process (`COR2`/`EXT2`) and a viewer is long-lived, so live analysis is a `twoslash-extract` **subprocess** per file whose payload feeds the existing twoslash overlay. This is a constraint, not a convenience. | full (P5)    | `LiveTypesSession` over `ResidentProcess`; `apps/hue/dub.json` has no analyzer dependency; hue `LIV5`                                                           |
| PRJ14 | The resulting overlay attaches to the open document — hover types plus the ddoc body and tag chips — and re-extracts when the file changes on disk.                                                                                                                                             | partial (P5) | attach + on-demand tips ship (hue `LIV1`/`LIV2`); re-opening the file re-extracts, but nothing **watches** it yet                                               |
| PRJ15 | Degradation is visible but never fatal: a file outside any project still analyzes with the environment defaults, and a describe failure is a dismissible notice, never a modal error and never a blank view.                                                                                    | full (P5)    | one-line notice (`takeLiveNotice`, printed after the alt screen is restored); a lazy popup renders empty, never blank-screens; hue `LIV4`                       |
| PRJ16 | Per-file payloads are cached alongside the project context, so navigating back to a file is instant.                                                                                                                                                                                            | partial (P5) | in-memory per session: the payload lives with the open document and each node's tip is fetched at most once; navigating away drops it (no cross-document cache) |

## Known limitations

- **Discovery is memoized per child, not per project.** `PRJ8`'s cache lives in
  the analyzing process, and the viewer starts one process per open document
  (`PRJ13` leaves it no choice), so opening a second file in the same project
  re-runs `dub describe` in the new child rather than reusing the first one's
  result. It costs the `PRJ9` figures (0.04 s–0.5 s) per open, off the render
  path. A shared context — a describe cache the viewer passes down, or one
  resident oracle per project — is the follow-up.
- **Sub-packages declared inline.** A file under a directory whose package is
  declared as a `subPackage` block in the parent recipe (rather than by its own
  `dub.sdl`) resolves to the parent, so the described settings are the parent's.
  Selecting `dub describe :sub` from the file path is unbuilt.
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

## Measured performance (2026-07-30, `expressionsem.d` — 20k lines)

| Measurement                                      | Value                                       |
| ------------------------------------------------ | ------------------------------------------- |
| Parse + full semantic (whole `dmd.*` closure)    | 0.74 s                                      |
| One positional `tipAt`                           | 3.9 ms (cold) / 0.6 ms (serve, warm caches) |
| Eager pipeline, per-occurrence `tipAt` (pre-L22) | 175.8 s                                     |
| Eager pipeline, single-walk collector (L22)      | **5.8 s**, 37,297 nodes, 275 MB peak        |
| Eager payload (L25 slim encoding)                | 10.1 MB raw / 767 KB gzipped                |
| Lazy payload                                     | 6.7 MB raw / 465 KB gzipped                 |

CDN/static guidance: static pages always bundle **eager** payloads (the
collector makes heavy files practical); gzip does the heavy lifting. The
lazy form exists for live sessions, not for static serving. No hover cap is
warranted at these sizes; revisit only if a page bundles many heavy files.
