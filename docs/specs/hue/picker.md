# `hue` picker — Feature Requirements (fuzzy finding, all interactive backends)

_**Status:** design · **Date:** 2026-08-07 · **Scope:** hue's **picker** — the
fuzzy finder behind `<leader>f`, `<leader>s`, `<leader>g` and `<leader>/`
([lantern `LMP7`/`LMP8`](./lantern.md)) — its query language, its sources, its
ranking, and the `sparkles:fuzzy` engine underneath._

> [!NOTE]
> Everything here is **forward-looking design**; no picker code exists on any
> branch. The [lantern](./lantern.md) map already reserves the letters this
> claims, so landing it rearranges nothing a user has learnt. Status legend and
> ID conventions: see the [overview](./index.md).

## Design & rationale

### Why hue needs one at all

hue can already open a file, walk a directory ([`TVU1`](./tree-view.md)) and
search **within** a document ([`FND`](./gui.md)). What it cannot do is answer
"where is the thing called roughly _this_" without you knowing where it lives —
which is most of what using a code viewer consists of.

The reference points are
[`ibhagwan/fzf-lua`](https://github.com/ibhagwan/fzf-lua) and
[`folke/snacks.nvim`](https://github.com/folke/snacks.nvim)'s picker for the
_shape_ (`finder → matcher → list → preview → actions`, plus layouts and
`resume`), and [`dmtrKovalenko/fff`](https://github.com/dmtrKovalenko/fff) for
the _engine_.

### Why the engine is written, not linked (`PKM`)

`fff` is a resident file-search engine — it keeps an index and a content cache
warm in one long-lived process, and on a 500k-file checkout that is the
difference between seconds per `rg` spawn and single-digit milliseconds per
query. It ships a stable C ABI, and hue already binds C libraries this way twice
(`sparkles:ghostty` wraps a **Zig** library; `sparkles:tree-sitter` a C one).

Binding it was considered and rejected, for the same reason
[`sparkles:diff`](./diff-view.md) was written rather than bound: hue's engines
are things this repository owns, unit-tests, and benchmarks. A Rust cdylib plus
LMDB in the closure would also have to cross-compile for **both** Android ABIs,
where hue's build is nix-native and Gradle-free ([`android.md`](./android.md)).

What is taken instead is fff's **design**, which is readable and portable:

| Borrowed                        | From                                        |
| ------------------------------- | ------------------------------------------- |
| the composite ranking formula   | `fff-core/src/score.rs`                     |
| the query constraint language   | `fff-query-parser`                          |
| frecency with exponential decay | `fff-core/src/dbs/frecency.rs`              |
| budget + abort + cursor paging  | `fff-core/src/grep/types.rs`                |
| three grep modes with fallback  | `fff-core/src/grep/`                        |
| arena-chunked path storage      | `FileItem` — already sparkles' own doctrine |

### The query is a language, not a pattern (`PKQ`)

fzf's pattern mods (`'exact`, `^prefix`, `suffix$`, `!inverse`) are a filter over
strings. fff's query is a filter over **files**, which is what a code viewer
actually has: `git:modified src/**/*.rs !src/**/mod.rs user controller` is one
query, splitting into constraints plus a fuzzy remainder.

hue can satisfy those constraints today — it already has git status
(`git_status.d`) and a `.gitignore`-aware walker
(`sparkles:build-primitives`) — so the language costs a parser, not a subsystem.

### Ranking is not matching (`PKR`)

A matcher answers "does this candidate contain the query"; a picker has to answer
"which of these forty do you mean". fff's formula, portable as arithmetic:

```
total = base(fuzzy score)
      + frecency_boost      base·frecency/100
      + git_status_boost    base·15%  when modified
      + distance_penalty    relative to the current file's directory
      + filename_bonus      base·40% exact filename
                          | ≤30, quality-scaled, for a fuzzy filename match
                          | base·5%  special entry-point file (mod.rs / index.ts …)
      + current_file_penalty  −base/4
      + combo_match_boost   this query previously opened this file
      + path_alignment      suffix overlap, when the query contains "/"
```

Every term is returned as a **breakdown**, not just a total, so the ranking is
inspectable rather than a black box that "feels wrong" — fff's `:FFFDebug` idea,
and the same instinct as [`hue config show`](./config.md) `CFG10`.

### Interactivity is a budget, not a promise (`PIK5`)

A grep over a large repository cannot block a frame, and hue's loops are
synchronous. fff's answer is the right one and is already the shape hue's diff
work needs ([`NFR8`](./feature-requirements.md)): every search takes a **time
budget**, an **abort flag** and a resumable **file offset**, and returns partial
results plus where to continue.

The fan-out runs on `sparkles:event-horizon`'s `cpuBound` `WorkStealingPool` —
the ring-less, plain-thread mode that
[beats rayon on `polyglot-walks`](../event-horizon/benchmarks.md) (1.16× on a
real 325k-entry tree, 4.26× on dense ones, 55 futex calls against
`std.parallelism`'s 10 632). Reusing it means the picker inherits a walker that
has already been measured against the best in the field.

> [!WARNING]
> `WorkStealingPool.start` can fail — the walker benchmark prints
> `SKIP: io_uring unavailable` — and its availability on Android and macOS is
> unverified. `cpuBound` skips the ring, but the picker must fall back to a
> synchronous budget-stepped walk rather than lose the feature.

## The component (`PIK`)

| ID     | Requirement                                                                                                                                                                                                  | Status      | Traces to                                       |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ----------------------------------------------- |
| `PIK1` | A **picker** must present a prompt, a ranked result list, and an optional preview, over any source — one component, many sources, in the shape fzf-lua and snacks.picker share.                              | not started | proposed `apps/hue/src/picker.d`                |
| `PIK2` | Its state must be a **presentation-free value** — the prompt line editor (`LineEditState`), the scored items, the selection and the scroll offset — testable with no canvas, like every other `STM` machine. | not started | `sparkles.ui.state.LineEditState`/`ScrollState` |
| `PIK3` | The view must be a **`sparkles:ui` widget tree**, painted by GUI and TUI from one definition (`UIA2`) — the contract [lantern `LTN5`](./lantern.md) is already held to.                                      | not started | proposed `picker_view.d`                        |
| `PIK4` | A **source** must be a DbI seam: anything that can produce items incrementally is a source, and adding one must not touch the component.                                                                     | not started | proposed `Finder` seam                          |
| `PIK5` | Every search must take a **time budget**, an **abort flag** and a resumable **file offset**, and return partial results with a continuation cursor — so a large repository never blocks a frame.             | not started | `SearchOptions`/`SearchResult`                  |
| `PIK6` | Results must be written into a **caller-owned sink**, and paths held in one contiguous arena with a filename offset, so a query costs no allocation beyond the arena's growth.                               | not started | `SmallBuffer`; fff's `FileItem` shape           |
| `PIK7` | Re-running a query must **cancel** in-flight work rather than racing it — a generation counter the workers check.                                                                                            | not started | proposed generation counter                     |
| `PIK8` | The picker must **degrade** to a synchronous budget-stepped walk when the work-stealing pool cannot start, rather than being unavailable.                                                                    | not started | `WorkStealingPool.start` failure path           |
| `PIK9` | `resume` must reopen the last picker with its query and selection intact.                                                                                                                                    | not started | proposed session store                          |

## The query language (`PKQ`)

| ID     | Requirement                                                                                                                                                      | Status      | Traces to                          |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------- |
| `PKQ1` | A query must split into **constraints** plus a fuzzy remainder, in one pass, with every span **borrowed** from the input so parsing allocates nothing.           | not started | proposed `sparkles.fuzzy.query`    |
| `PKQ2` | Constraints must cover `*.ext`, a **glob**, a path segment, a file path suffix, and `git:<status>` (`modified`/`staged`/`untracked`/`ignored`).                  | not started | `git_status.d` supplies the status |
| `PKQ3` | Any constraint must be **negatable** (`!test/`, `!*.rs`), with a minimum length on text exclusions so operators like `!=` are not mistaken for one.              | not started | fff's rule                         |
| `PKQ4` | A trailing **`:line[:col]`** must parse as a location, so pasting `src/app.d:120` from a compiler diagnostic opens where it points.                              | not started | fff's `Location`                   |
| `PKQ5` | The matcher must be **typo-resistant**, not merely subsequence-based — a transposition or a dropped character must still rank, which is the difference from fzf. | not started | `sparkles.fuzzy.score`             |
| `PKQ6` | Match **positions** must be returned so the list can highlight what matched.                                                                                     | not started | `sparkles.fuzzy.score`             |

## Ranking (`PKR`)

| ID     | Requirement                                                                                                                                                                                                      | Status      | Traces to                       |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------- |
| `PKR1` | Results must be ranked by the **composite formula** above — a fuzzy base plus frecency, git status, path distance, filename quality and path alignment — not by match score alone.                               | not started | `sparkles.fuzzy.rank`           |
| `PKR2` | **Frecency** must decay exponentially (a 10-day half-life over a 30-day window, capped at 128 timestamps per file), so recently and repeatedly opened files rank above cold ones.                                | not started | `sparkles.fuzzy.frecency`       |
| `PKR3` | A **query-history combo boost** must rank a file the same query previously opened.                                                                                                                               | not started | `sparkles.fuzzy.frecency`       |
| `PKR4` | Every result must carry its **score breakdown**, and a debug toggle must show it — a ranking nobody can inspect is one nobody can fix.                                                                           | not started | proposed `Score` struct         |
| `PKR5` | Frecency and query history must **persist** through the [configuration](./config.md) layer's state directory, not a second storage mechanism, and must never make hue fail to start.                             | not started | `sparkles:wired`; `common_dirs` |
| `PKR6` | The persistence read/write is the one place `@nogc` is not required (it is startup/shutdown I/O, the [`NFR1`](./feature-requirements.md) carve-out); the in-memory table and every scoring path must be `@nogc`. | not started | `NFR1`                          |

## Sources (`PKS`)

Each row is one `<leader>` binding. The map reserves them all today.

| ID      | Source         | Key          | Requirement                                                                                                         | Status      |
| ------- | -------------- | ------------ | ------------------------------------------------------------------------------------------------------------------- | ----------- |
| `PKS1`  | files          | `<leader>ff` | The `.gitignore`-aware walk, fanned out on the `cpuBound` pool, honouring the tree pane's include/exclude globs.    | not started |
| `PKS2`  | grep           | `<leader>/`  | Content search in three modes — plain, regex, fuzzy — auto-detected, falling back to fuzzy on zero hits.            | not started |
| `PKS3`  | recent         | `<leader>fr` | Frecency-ordered previously opened documents (`PKR2`).                                                              | not started |
| `PKS4`  | open documents | `<leader>,`  | The current `SourceSet` ([`SRC6`](./feature-requirements.md)) — the substrate the [tab view](./tab-view.md) shares. | not started |
| `PKS5`  | git status     | `<leader>gs` | Changed files, from the existing cache rather than a new `git` invocation.                                          | not started |
| `PKS6`  | git commits    | `<leader>gc` | Commits, opening the revision as a [diff session](./diff-view.md).                                                  | not started |
| `PKS7`  | themes         | `<leader>st` | The built-in theme list ([`THM2`](./feature-requirements.md)), applying live as the selection moves.                | not started |
| `PKS8`  | lines          | `<leader>sl` | Lines of the current document — the in-document search, as a picker.                                                | not started |
| `PKS9`  | keymaps        | `<leader>sk` | `hueBindings` itself. Free once the table exists ([`KEY3`](./lantern.md)), and the honest test of `PIK4`.           | not started |
| `PKS10` | git files      | `<leader>fg` | Tracked files only, skipping the walk where a repository can answer faster.                                         | not started |

## Layout & actions (`PKL`)

| ID     | Requirement                                                                                                                                                    | Status      | Traces to                      |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------ |
| `PKL1` | Layouts must be selectable: `default` (list + preview side by side), `vscode` (a centred dropdown, no preview), `select` (small, for a short list).            | not started | snacks.picker's presets        |
| `PKL2` | The **preview** must reuse `DocumentPipeline.load` and `ViewerModel` — the picker introduces no second rendering path.                                         | not started | `document.d`; `viewer_model.d` |
| `PKL3` | Actions must be **bindings in the one table** ([`KEY1`](./lantern.md)), so the guide lists what a picker's keys do exactly as it lists everything else.        | not started | `hueBindings` picker scope     |
| `PKL4` | Rows must be **tappable**, and the prompt must accept the soft keyboard, so the picker is usable on Android where the leader menu is the only command surface. | not started | [android.md](./android.md)     |
| `PKL5` | `<S-Tab>` must cycle the grep mode, with the active mode shown; a single-mode configuration must hide the indicator.                                           | not started | fff.nvim's affordance          |
| `PKL6` | A grep result must classify **definition lines** (`struct`/`fn`/`class`/`def`/`impl`), so a definition can be ranked and marked above a mention.               | not started | fff's classifier               |

## `sparkles:fuzzy` (`PKM`)

A new library — `libs/fuzzy` — because the matcher is a self-contained, testable,
benchmarkable engine with no dependency on hue, exactly as `sparkles:diff` is.

| ID     | Requirement                                                                                                                                                        | Status      | Traces to                      |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | ------------------------------ |
| `PKM1` | The library must be **100% `@safe pure nothrow @nogc`**, with `SmallBuffer` as its only dynamic container and `Expected` for errors — no exceptions.               | not started | `libs/fuzzy`                   |
| `PKM2` | Its unittests must carry those attributes **explicitly**, so an accidental allocation is a compile error rather than a review note.                                | not started | the repo's existing idiom      |
| `PKM3` | Every returned span must **borrow** from the caller's input; the library must own no string.                                                                       | not started | `PKQ1`                         |
| `PKM4` | Scoring must be **benchmarked** (`@benchmark`) from the first commit, since a picker's whole value is that it answers within a frame.                              | not started | `libs/fuzzy/bench`             |
| `PKM5` | It must ship a `docs/libs/fuzzy/` Diátaxis tree, as `AGENTS.md` requires of a new library.                                                                         | not started | `docs/libs/fuzzy/`             |
| `PKM6` | A **bigram prefilter** should narrow candidates before content scoring, once the grep source's scale justifies it. Deferred, and recorded so it is not re-derived. | not started | fff's `index/bigram_filter.rs` |

## Milestones

| Milestone | Scope                                                                 | Requirements                   |
| --------- | --------------------------------------------------------------------- | ------------------------------ |
| `F0`      | `sparkles:fuzzy` — query parser, scoring, ranking, glob               | `PKM1`–`PKM5`, `PKQ*`, `PKR1`  |
| `P0`      | The picker state machine, the `Finder` seam, and the **files** source | `PIK1`–`PIK8`, `PKS1`          |
| `P1`      | The view, both backends, and the layouts                              | `PIK3`, `PKL1`                 |
| `P2`      | The preview pane                                                      | `PKL2`                         |
| `P3`      | Frecency + query-history persistence; the **recent** source           | `PKR2`–`PKR6`, `PKS3`          |
| `P4`      | The **grep** source: three modes, the definition classifier           | `PKS2`, `PKL5`, `PKL6`         |
| `P5`      | The remaining sources, actions, and `resume`                          | `PKS4`–`PKS10`, `PKL3`, `PIK9` |
| `P6`      | Touch: tappable rows and the soft keyboard                            | `PKL4`                         |

## Module coverage (proposed)

No code on any branch yet.

| Source (proposed)                | Requirements                   |
| -------------------------------- | ------------------------------ |
| `libs/fuzzy/src/sparkles/fuzzy/` | `PKM*`, `PKQ*`, `PKR1`–`PKR3`  |
| `apps/hue/src/picker.d`          | `PIK1`, `PIK2`, `PIK5`–`PIK9`  |
| `apps/hue/src/picker_sources.d`  | `PIK4`, `PKS*`                 |
| `apps/hue/src/picker_view.d`     | `PIK3`, `PKL1`, `PKL4`         |
| `apps/hue/src/keymap.d`          | `PKL3` (the picker's bindings) |

## Relationship to existing specs

| Piece                                                       | Role                                                                   |
| ----------------------------------------------------------- | ---------------------------------------------------------------------- |
| [lantern.md](./lantern.md) `LMP7`/`LMP8`                    | the reserved keys this opens, and the table its actions join           |
| [tree-view.md](./tree-view.md) `TVU1`                       | the explorer this complements — browse there, find here                |
| [feature-requirements.md](./feature-requirements.md) `SRC6` | the document set `PKS4` picks from                                     |
| [diff-view.md](./diff-view.md)                              | what `PKS6` opens, and the `NFR8` budget this shares                   |
| [config.md](./config.md)                                    | where the frecency store and the picker's defaults live                |
| [`sparkles:event-horizon`](../event-horizon/benchmarks.md)  | the measured work-stealing walker the file and grep sources fan out on |
| `sparkles:build-primitives`                                 | the `.gitignore`-aware walk `PKS1` reuses                              |

→ [Lantern requirements](./lantern.md) · [Tree / DAG view](./tree-view.md) · [Overview](./index.md)
